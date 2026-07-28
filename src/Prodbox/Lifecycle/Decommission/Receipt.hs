{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 4.50: the fsync-ordered durable barrier for the decommission receipt —
-- the only new effectful primitive of the protocol.
--
-- 'appendReceiptFrame' writes one length-delimited frame record, fsyncs the file,
-- then fsyncs the parent directory, so a committed frame (and, on first creation,
-- the directory entry) is durable before the runner performs the external effect
-- the frame authorises. 'reopenReceipt' reads the receipt, computes the pure
-- longest-valid-prefix recovery ('Prodbox.Lifecycle.Decommission.Journal'), and —
-- only for a torn final record — truncates the file back to the last valid frame
-- and fsyncs, so resumption appends cleanly after the recovered prefix. A fully
-- written but corrupt frame, a chain break, or a manifest mismatch is returned
-- as a refusal and the file is left untouched: committed history is never
-- silently rewritten.
module Prodbox.Lifecycle.Decommission.Receipt
  ( ReceiptReopen (..)
  , appendReceiptFrame
  , reopenReceipt
  )
where

import Codec.Serialise (Serialise)
import Control.Exception (IOException, bracket, try)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Prodbox.Lifecycle.Decommission.Frame (DecommissionFrame, FrameDigest)
import Prodbox.Lifecycle.Decommission.Journal
  ( ReceiptRecovery (recoveredFrames, recoveredValidBytes, recoveryOutcome)
  , RecoveryOutcome (RecoveryTruncatableTorn)
  , encodeRecord
  , recoverReceipt
  )
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory)
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFdSize, unionFileModes)
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (ReadOnly, WriteOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  )
import System.Posix.IO.ByteString qualified as PosixBS
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)

-- | The result of reopening a receipt file: the recovered valid prefix, its
-- recovery classification, and — when a torn tail was truncated — the byte length
-- the file was truncated to.
data ReceiptReopen payload = ReceiptReopen
  { reopenFrames :: ![DecommissionFrame payload]
  , reopenOutcome :: !RecoveryOutcome
  , reopenTruncatedTo :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

receiptFileMode :: FileMode
receiptFileMode = ownerReadMode `unionFileModes` ownerWriteMode

-- | Append one frame durably: write the length-delimited record, fsync the file,
-- then fsync the parent directory.
appendReceiptFrame
  :: (Serialise payload)
  => FilePath
  -> DecommissionFrame payload
  -> IO ()
appendReceiptFrame path frame = do
  bracket
    ( openFd
        path
        WriteOnly
        defaultFileFlags
          { append = True
          , creat = Just receiptFileMode
          , nofollow = True
          , cloexec = True
          }
    )
    safeCloseFd
    ( \fd -> do
        writeAll fd (encodeRecord frame)
        fileSynchronise fd
    )
  syncDirectory (takeDirectory path)

-- | Reopen a receipt for recovery. A missing file is an empty (complete) receipt.
-- A torn final record is truncated away and the file fsynced; every other defect
-- is returned untouched.
reopenReceipt
  :: (Serialise payload)
  => Int
  -> FrameDigest
  -> FilePath
  -> IO (ReceiptReopen payload)
reopenReceipt maximumFrameBytes expectedManifest path = do
  exists <- doesFileExist path
  bytes <- if exists then ByteString.readFile path else pure ByteString.empty
  let recovery = recoverReceipt maximumFrameBytes expectedManifest bytes
  truncatedTo <- case recoveryOutcome recovery of
    RecoveryTruncatableTorn -> do
      truncateToValidPrefix path (recoveredValidBytes recovery)
      syncDirectory (takeDirectory path)
      pure (Just (recoveredValidBytes recovery))
    _ -> pure Nothing
  pure
    ReceiptReopen
      { reopenFrames = recoveredFrames recovery
      , reopenOutcome = recoveryOutcome recovery
      , reopenTruncatedTo = truncatedTo
      }

truncateToValidPrefix :: FilePath -> Int -> IO ()
truncateToValidPrefix path validBytes =
  bracket
    (openFd path WriteOnly defaultFileFlags {nofollow = True, cloexec = True})
    safeCloseFd
    ( \fd -> do
        setFdSize fd (fromIntegral validBytes)
        fileSynchronise fd
    )

syncDirectory :: FilePath -> IO ()
syncDirectory directory =
  bracket
    ( openFd
        directory
        ReadOnly
        defaultFileFlags {directory = True, nofollow = True, cloexec = True}
    )
    safeCloseFd
    fileSynchronise

writeAll :: Fd -> ByteString -> IO ()
writeAll _ bytes | ByteString.null bytes = pure ()
writeAll fd bytes = do
  written <- PosixBS.fdWrite fd bytes
  let count = fromIntegral written
  if count <= 0
    then fail "decommission receipt write made no progress"
    else writeAll fd (ByteString.drop count bytes)

safeCloseFd :: Fd -> IO ()
safeCloseFd fd = void (try (closeFd fd) :: IO (Either IOException ()))
