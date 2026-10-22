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
  , QualificationResumeSnapshot
  , mkQualificationResumeSnapshot
  , qualificationResumeBegun
  , qualificationResumeImages
  , qualificationResumeSnapshotPath
  , persistQualificationResumeSnapshot
  , observeQualificationResumeSnapshot
  )
where

import Control.Exception (IOException, bracket, finally, mask, throwIO, try)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.Char (isControl)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Test.Qualification.CascadeCycleArtifact
  ( CycleLabel
  , componentImageInventoryDigests
  , cycleLabelText
  )
import Prodbox.Test.Qualification.CascadeCycleIdentity
  ( CycleIdentityParts (partsComponentImages)
  )
import Prodbox.Test.Qualification.CascadeCycleLedger
  ( BegunRecord (..)
  , CycleLedger
  , LedgerEntry (..)
  , LedgerRecord (..)
  , LedgerRefusal (..)
  , appendRecord
  , emptyCycleLedger
  , ledgerEntries
  , ledgerTip
  , parseCycleLedger
  , renderLedgerRefusal
  )
import System.Directory (createDirectoryIfMissing, removeFile)
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (AppendMode), hClose, hFlush, openBinaryTempFile, withBinaryFile)
import System.IO.Error (isDoesNotExistError, isEOFError)
import System.Posix.Files (createLink, fileMode, fileOwner, fileSize, getFdStatus, isRegularFile)
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (ReadOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  )
import System.Posix.IO.ByteString qualified as PosixByteString
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

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

-- | Pre-uninstall capture for one qualification label. It stores the actual
-- named image inventory beside the exact Begin identity, never reconstructed
-- names or a subsequently observed cluster. It carries no credential material.
data QualificationResumeSnapshot = QualificationResumeSnapshot
  { qualificationResumeBegun :: !BegunRecord
  , qualificationResumeImages :: ![Text]
  }
  deriving (Eq, Show)

maximumQualificationResumeSnapshotBytes :: Int
maximumQualificationResumeSnapshotBytes = 512 * 1024

mkQualificationResumeSnapshot
  :: BegunRecord -> [Text] -> Either String QualificationResumeSnapshot
mkQualificationResumeSnapshot begun images = do
  _ <-
    first
      (Text.unpack . renderLedgerRefusal)
      (appendRecord emptyCycleLedger (RecordCycleBegun begun))
  if null images
    || length images > 256
    || any (\line -> Text.length line > 4096 || Text.any isControl line) images
    then Left "the qualification resume image inventory is empty or exceeds its bounds"
    else Right ()
  digests <- first show (componentImageInventoryDigests images)
  if nub (sort digests) == partsComponentImages (begunParts begun)
    then Right (QualificationResumeSnapshot begun images)
    else Left "the named image inventory differs from the recorded Begin identity"

qualificationResumeSnapshotPath :: FilePath -> CycleLabel -> FilePath
qualificationResumeSnapshotPath repoRoot label =
  repoRoot </> ".test-data" </> "qualification" </> Text.unpack (cycleLabelText label) <> ".resume-v1"

encodeQualificationResumeSnapshot :: QualificationResumeSnapshot -> Either String ByteString
encodeQualificationResumeSnapshot snapshot = do
  let begun = qualificationResumeBegun snapshot
  _ <- mkQualificationResumeSnapshot begun (qualificationResumeImages snapshot)
  (_, entry) <-
    first
      (Text.unpack . renderLedgerRefusal)
      (appendRecord emptyCycleLedger (RecordCycleBegun begun))
  let bytes =
        TextEncoding.encodeUtf8 . Text.unlines $
          [ "qualification-resume/v1"
          , "begun="
              <> TextEncoding.decodeUtf8 (Base64.encode (TextEncoding.encodeUtf8 (entryLine entry <> "\n")))
          ]
            ++ map ("image=" <>) (qualificationResumeImages snapshot)
  if ByteString.length bytes <= maximumQualificationResumeSnapshotBytes
    then Right bytes
    else Left "the qualification resume snapshot exceeds its encoded bound"

decodeQualificationResumeSnapshot :: ByteString -> Either String QualificationResumeSnapshot
decodeQualificationResumeSnapshot bytes = do
  text <-
    first (const "the qualification resume snapshot is not UTF-8") (TextEncoding.decodeUtf8' bytes)
  (record, images) <- case Text.lines text of
    "qualification-resume/v1" : encoded : rows -> do
      raw <- maybe (Left "missing qualification resume Begin") Right (Text.stripPrefix "begun=" encoded)
      recordBytes <-
        first
          (const "invalid qualification resume Begin base64")
          (Base64.decode (TextEncoding.encodeUtf8 raw))
      ledger <- first renderLedgerStoreError (decodeLedger recordBytes)
      begun <- case map entryRecord (ledgerEntries ledger) of
        [RecordCycleBegun selected] -> Right selected
        _ -> Left "qualification resume snapshot must contain exactly one Begin"
      inventory <-
        mapM (maybe (Left "invalid qualification resume image row") Right . Text.stripPrefix "image=") rows
      Right (begun, inventory)
    _ -> Left "unsupported qualification resume snapshot"
  snapshot <- mkQualificationResumeSnapshot record images
  canonical <- encodeQualificationResumeSnapshot snapshot
  if canonical == bytes then Right snapshot else Left "noncanonical qualification resume snapshot"

-- | Immutable publication followed by an independent bounded read. Even an
-- applied-but-lost publication result succeeds only from those exact bytes.
persistQualificationResumeSnapshot
  :: FilePath -> QualificationResumeSnapshot -> IO (Either String QualificationResumeSnapshot)
persistQualificationResumeSnapshot repoRoot snapshot = case encodeQualificationResumeSnapshot snapshot of
  Left detail -> pure (Left detail)
  Right expected -> do
    let label = begunLabel (qualificationResumeBegun snapshot)
        path = qualificationResumeSnapshotPath repoRoot label
    existing <- observeQualificationResumeSnapshot repoRoot label
    case existing of
      Left detail -> pure (Left detail)
      Right (Just observed)
        | observed == snapshot -> pure (Right observed)
        | otherwise ->
            pure (Left "the qualification resume snapshot conflicts with the stored cycle identity")
      Right Nothing -> do
        attempted <- try (publish path expected) :: IO (Either IOException ())
        observed <- observeQualificationResumeSnapshot repoRoot label
        pure $ case observed of
          Right (Just actual) | actual == snapshot -> Right actual
          Left detail -> Left detail
          _ -> Left (either show (const "the qualification resume snapshot has no exact read-back") attempted)
 where
  publish path bytes = mask $ \restore -> do
    createDirectoryIfMissing True (takeDirectory path)
    (temporary, handle) <- openBinaryTempFile (takeDirectory path) ".qualification-resume.staging"
    let discard = do
          _ <- try (hClose handle) :: IO (Either IOException ())
          _ <- try (removeFile temporary) :: IO (Either IOException ())
          pure ()
    restore
      ( do
          ByteString.hPut handle bytes
          hFlush handle
          hClose handle
          bracket
            (openFd temporary ReadOnly defaultFileFlags {nofollow = True, cloexec = True})
            closeFd
            fileSynchronise
          createLink temporary path
          bracket
            (openFd (takeDirectory path) ReadOnly defaultFileFlags {directory = True, cloexec = True})
            closeFd
            fileSynchronise
      )
      `finally` discard

observeQualificationResumeSnapshot
  :: FilePath -> CycleLabel -> IO (Either String (Maybe QualificationResumeSnapshot))
observeQualificationResumeSnapshot repoRoot label = do
  let path = qualificationResumeSnapshotPath repoRoot label
  result <- try
    $ bracket
      (openFd path ReadOnly defaultFileFlags {nofollow = True, nonBlock = True, cloexec = True})
      closeFd
    $ \fd -> do
      status <- getFdStatus fd
      owner <- getEffectiveUserID
      if not (isRegularFile status)
        || fileMode status `mod` 512 /= 384
        || fileOwner status /= owner
        || fileSize status > fromIntegral maximumQualificationResumeSnapshotBytes
        then pure (Left "the qualification resume snapshot is not a bounded owner-only regular file")
        else do
          bytes <- readBounded fd (maximumQualificationResumeSnapshotBytes + 1) []
          pure $
            if ByteString.length bytes > maximumQualificationResumeSnapshotBytes
              then Left "the qualification resume snapshot exceeds its encoded bound"
              else do
                snapshot <- decodeQualificationResumeSnapshot bytes
                if begunLabel (qualificationResumeBegun snapshot) == label
                  then Right (Just snapshot)
                  else Left "the qualification resume snapshot belongs to another cycle label"
  case result of
    Left (err :: IOException)
      | isDoesNotExistError err -> pure (Right Nothing)
      | otherwise -> pure (Left ("the qualification resume snapshot cannot be read: " <> show err))
    Right value@(Right (Just _)) -> do
      synced <-
        try
          ( bracket
              ( openFd
                  (takeDirectory path)
                  ReadOnly
                  defaultFileFlags {directory = True, nofollow = True, cloexec = True}
              )
              closeFd
              fileSynchronise
          )
          :: IO (Either IOException ())
      pure
        ( either
            (Left . ("the qualification resume snapshot directory is not durable: " <>) . show)
            (const value)
            synced
        )
    Right value -> pure value
 where
  readBounded fd remaining chunks
    | remaining <= 0 = pure (ByteString.concat (reverse chunks))
    | otherwise = do
        attempted <- try (PosixByteString.fdRead fd (fromIntegral (min remaining (64 * 1024))))
        case attempted of
          Left (err :: IOException)
            | isEOFError err -> pure (ByteString.concat (reverse chunks))
            | otherwise -> throwIO err
          Right chunk
            | ByteString.null chunk -> pure (ByteString.concat (reverse chunks))
            | otherwise -> readBounded fd (remaining - ByteString.length chunk) (chunk : chunks)
