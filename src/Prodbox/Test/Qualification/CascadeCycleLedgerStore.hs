{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The cycle ledger's one file, and the only code that writes it.
--
-- The file lives under @.test-data/@, which git ignores, so appending a record
-- never changes the source identity it records. A read verifies the whole chain
-- and refuses a broken or malformed file; nothing here repairs a ledger in
-- place, because a repaired record is no longer evidence of anything. The
-- recovery for a ledger that must be abandoned is to delete the file, which
-- restarts the count of qualifying cycles at zero.
module Prodbox.Test.Qualification.CascadeCycleLedgerStore
  ( LedgerStoreError (..)
  , renderLedgerStoreError
  , cycleLedgerPath
  , readCycleLedger
  , appendCycleRecord
  )
where

import Control.Exception (IOException, bracket, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Test.Qualification.CascadeCycleLedger
  ( CycleLedger
  , LedgerEntry (..)
  , LedgerRecord
  , LedgerRefusal (..)
  , appendRecord
  , emptyCycleLedger
  , ledgerTip
  , parseCycleLedger
  , renderLedgerRefusal
  )
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (AppendMode), hFlush, withBinaryFile)
import System.IO.Error (isDoesNotExistError)
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (ReadOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  )
import System.Posix.Unistd (fileSynchronise)

data LedgerStoreError
  = -- | The file exists and could not be read, which is not the same as absent.
    LedgerStoreUnreadable !FilePath !String
  | LedgerStoreRefused !LedgerRefusal
  | LedgerStoreWriteFailed !FilePath !String
  | -- | After an append, the file's tip is not the entry that was written.
    LedgerStoreReadBackDisagrees
  deriving (Eq, Show)

renderLedgerStoreError :: LedgerStoreError -> String
renderLedgerStoreError err = case err of
  LedgerStoreUnreadable path detail ->
    "could not read the cycle ledger " ++ path ++ ": " ++ detail
  LedgerStoreRefused refusal ->
    "the cycle ledger is refused: "
      ++ Text.unpack (renderLedgerRefusal refusal)
      ++ ". It is never repaired in place; delete the file only to abandon the count and restart it at zero."
  LedgerStoreWriteFailed path detail ->
    "could not append to the cycle ledger " ++ path ++ ": " ++ detail
  LedgerStoreReadBackDisagrees ->
    "the cycle ledger read back is not what was written"

-- | One ledger per repository, beside the artifacts it counts.
cycleLedgerPath :: FilePath -> FilePath
cycleLedgerPath repoRoot =
  repoRoot </> ".test-data" </> "qualification" </> "cascade-cycles.ledger"

-- | The verified ledger, or the empty one when the file does not exist. An
-- unreadable file is an error and never an empty ledger.
readCycleLedger :: FilePath -> IO (Either LedgerStoreError CycleLedger)
readCycleLedger path = do
  read' <- try (ByteString.readFile path)
  pure $ case read' of
    Left (err :: IOException)
      | isDoesNotExistError err -> Right emptyCycleLedger
      | otherwise -> Left (LedgerStoreUnreadable path (show err))
    Right bytes -> decodeLedger bytes

decodeLedger :: ByteString -> Either LedgerStoreError CycleLedger
decodeLedger bytes = case TextEncoding.decodeUtf8' bytes of
  Left _ -> Left (LedgerStoreRefused (malformed "the file is not UTF-8"))
  Right text
    | endsWithNewline bytes || Text.null text -> refused (parseCycleLedger text)
    | otherwise -> Left (LedgerStoreRefused (malformed "the file does not end with a newline"))
 where
  refused = either (Left . LedgerStoreRefused) Right
  malformed = LedgerEntryMalformed 0
  endsWithNewline raw = not (ByteString.null raw) && ByteString.last raw == 10

-- | Read, verify, append exactly one line, make it durable, and read back.
--
-- The record is written before the caller acts on it, so a @Begun@ is on disk
-- before the candidate it announces runs. A caller that cannot append does not
-- run the candidate.
appendCycleRecord :: FilePath -> LedgerRecord -> IO (Either LedgerStoreError LedgerEntry)
appendCycleRecord path record = do
  createDirectoryIfMissing True (takeDirectory path)
  current <- readCycleLedger path
  case current of
    Left err -> pure (Left err)
    Right ledger -> case appendRecord ledger record of
      Left refusal -> pure (Left (LedgerStoreRefused refusal))
      Right (_, entry) -> do
        written <- try (writeLine entry)
        case written of
          Left (err :: IOException) -> pure (Left (LedgerStoreWriteFailed path (show err)))
          Right () -> do
            readBack <- readCycleLedger path
            pure $ case readBack of
              Left err -> Left err
              Right after
                | ledgerTip after == entryDigest entry -> Right entry
                | otherwise -> Left LedgerStoreReadBackDisagrees
 where
  writeLine entry = do
    withBinaryFile path AppendMode $ \handle -> do
      ByteString.hPut handle (TextEncoding.encodeUtf8 (entryLine entry <> "\n"))
      hFlush handle
    synchronise path ReadOnly False
    synchronise (takeDirectory path) ReadOnly True

  synchronise target mode isDirectory =
    bracket
      (openFd target mode defaultFileFlags {directory = isDirectory, cloexec = True})
      closeFd
      fileSynchronise
