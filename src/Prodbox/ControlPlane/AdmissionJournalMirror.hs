{-# LANGUAGE OverloadedStrings #-}

-- | The Authority's mounted journal: a write-ahead mirror of the
-- admission-relevant facts of its retained submission ledger, kept on the
-- retained volume so they stay readable while Vault is sealed. Each aggregate
-- commit first writes the mirror derived from the aggregate about to be
-- committed and only then performs the compare-and-swap, so the volume can be
-- ahead of the store (it may show an intent the commit never made, which is
-- conservative) and never behind it. A failed mirror write refuses the commit.
-- A genesis record, written once when the Authority first resolves its store,
-- is the positive evidence that "no operation" means never admitted rather than
-- "journal missing". The mirror holds operation labels and states only.
module Prodbox.ControlPlane.AdmissionJournalMirror
  ( journalMountDirectory
  , mirrorAdmissionRepository
  , initialiseJournalMirror
  , observeJournalMirror
  , renderMirror
  , parseMirror
  ) where

import Control.Exception (IOException, bracket, try)
import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.Lifecycle.AdmissionHistory (JournalObservation (..), OperationState (..))
import Prodbox.Lifecycle.AdmissionLedgerProjection (ledgerJournalObservation)
import Prodbox.Lifecycle.Authority.Admission (authorityAggregateSubmissionLedger)
import System.Directory (createDirectory, doesFileExist, removeDirectory, renameFile)
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (getSymbolicLinkStatus)
import System.Posix.IO (OpenMode (ReadOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.Unistd (fileSynchronise)

-- | The volume the Authority chart mounts for its journal.
journalMountDirectory :: FilePath
journalMountDirectory = "/var/lib/prodbox/lifecycle-authority-journal"

mirrorPath, genesisPath :: FilePath -> FilePath
mirrorPath directory = directory </> "admission.json"
genesisPath directory = directory </> "genesis.json"

writeGuardPath :: FilePath -> FilePath
writeGuardPath directory = directory </> "admission-write-in-progress"

renderMirror :: [(Text, OperationState)] -> ByteString.ByteString
renderMirror operations =
  LazyByteString.toStrict
    ( Aeson.encode
        ( Aeson.object
            [ "schema_version" .= (1 :: Int)
            , "operations"
                .= [ Aeson.object ["operation" .= name, "state" .= stateText state]
                   | (name, state) <- operations
                   ]
            ]
        )
    )
 where
  stateText :: OperationState -> Text
  stateText OperationSettled = "settled"
  stateText OperationUnresolved = "unresolved"

parseMirror :: ByteString.ByteString -> Maybe [(Text, OperationState)]
parseMirror bytes = do
  value <- Aeson.decodeStrict bytes
  AesonTypes.parseMaybe
    ( Aeson.withObject "mirror" $ \object -> do
        version <- object .: "schema_version" :: AesonTypes.Parser Int
        entries <- object .: "operations" :: AesonTypes.Parser [Aeson.Value]
        if version /= 1
          then fail "unsupported"
          else
            mapM
              ( Aeson.withObject "entry" $ \entry -> do
                  name <- entry .: "operation"
                  state <- entry .: "state" :: AesonTypes.Parser Text
                  case state of
                    "settled" -> pure (name, OperationSettled)
                    "unresolved" -> pure (name, OperationUnresolved)
                    _ -> fail "state"
              )
              entries
    )
    value

atomicWrite :: FilePath -> ByteString.ByteString -> IO (Either String ())
atomicWrite path bytes = do
  let temporary = path ++ ".tmp"
  written <-
    try
      ( ByteString.writeFile temporary bytes
          >> syncPath temporary
          >> renameFile temporary path
          >> syncPath (takeDirectory path)
      )
      :: IO (Either IOException ())
  pure (either (Left . ("journal mirror write failed: " ++) . take 120 . show) Right written)

syncPath :: FilePath -> IO ()
syncPath path = bracket (openFd path ReadOnly defaultFileFlags) closeFd fileSynchronise

guardPresent :: FilePath -> IO (Either IOException Bool)
guardPresent directory = do
  result <- try (getSymbolicLinkStatus (writeGuardPath directory))
  pure $ case result of
    Right _ -> Right True
    Left failure | isDoesNotExistError failure -> Right False
    Left failure -> Left failure

observedOperations :: JournalObservation -> [(Text, OperationState)]
observedOperations observation = case observation of
  JournalRead operations -> operations
  _ -> []

-- | Wrap the admission repository so that every commit is preceded by its
-- mirror write.
mirrorAdmissionRepository
  :: FilePath
  -> AuthorityAdmissionRepository IO revision
  -> AuthorityAdmissionRepository IO revision
mirrorAdmissionRepository directory repository =
  repository
    { compareAndSwapAuthorityAdmission = \expected aggregate -> do
        acquired <-
          try (createDirectory (writeGuardPath directory) >> syncPath directory) :: IO (Either IOException ())
        case acquired of
          Left _ -> pure (Left "journal-write-in-progress-or-unavailable")
          Right () -> do
            let operations = observedOperations (ledgerJournalObservation (authorityAggregateSubmissionLedger aggregate))
            mirrored <- atomicWrite (mirrorPath directory) (renderMirror operations)
            case mirrored of
              Left failure -> pure (Left (Text.pack failure))
              Right () -> do
                committed <- compareAndSwapAuthorityAdmission repository expected aggregate
                case committed of
                  Left failure -> pure (Left failure)
                  Right revision -> do
                    removed <-
                      try (removeDirectory (writeGuardPath directory) >> syncPath directory) :: IO (Either IOException ())
                    pure $ case removed of
                      Left _ -> Left "journal-write-guard-removal-failed"
                      Right () -> Right revision
    }

-- | Create a new mirror once. On restart, compare the retained mirror with the
-- committed aggregate; never overwrite a divergent or unreadable mirror, which
-- may contain the only evidence of an interrupted write.
initialiseJournalMirror
  :: FilePath
  -> AuthorityAdmissionRepository IO revision
  -> IO (Either String ())
initialiseJournalMirror directory repository = do
  writing <- guardPresent directory
  snapshot <- case writing of
    Right False -> readAuthorityAdmission repository
    _ -> pure (Left "journal-write-in-progress-or-unobservable")
  case snapshot of
    Left failure -> pure (Left ("the committed admission could not be read: " ++ Text.unpack failure))
    Right observed -> do
      let operations =
            observedOperations
              ( ledgerJournalObservation
                  (authorityAggregateSubmissionLedger (authorityAdmissionSnapshotState observed))
              )
      present <- doesFileExist (genesisPath directory)
      if present
        then do
          retained <- observeJournalMirror directory
          pure $
            if retained == JournalRead operations
              then Right ()
              else Left "the retained journal differs from the committed admission; recovery is required"
        else do
          orphaned <- doesFileExist (mirrorPath directory)
          if orphaned
            then pure (Left "a journal mirror exists without its genesis; recovery is required")
            else do
              mirrored <- atomicWrite (mirrorPath directory) (renderMirror operations)
              case mirrored of
                Left failure -> pure (Left failure)
                Right () -> atomicWrite (genesisPath directory) "genesis\n"

-- | Read the mirror as an admission observation. Without the genesis record the
-- journal is unobservable (never initialized by this Authority), not empty.
observeJournalMirror :: FilePath -> IO JournalObservation
observeJournalMirror directory = do
  writing <- guardPresent directory
  genesis <- try (doesFileExist (genesisPath directory)) :: IO (Either IOException Bool)
  case writing of
    Right False -> observeAfterGuard genesis
    _ -> pure (JournalUnobservable "a journal write is in progress or requires recovery")
 where
  observeAfterGuard genesis = case genesis of
    Left failure -> pure (JournalUnobservable (Text.pack ("journal unreadable: " ++ take 80 (show failure))))
    Right False -> pure (JournalUnobservable "the journal was never initialized by this Authority")
    Right True -> do
      contents <-
        try (ByteString.readFile (mirrorPath directory)) :: IO (Either IOException ByteString.ByteString)
      writingAfter <- guardPresent directory
      pure $
        case writingAfter of
          Right False -> case contents of
            Left _ -> JournalUnobservable "the journal mirror is missing although the journal was initialized"
            Right bytes ->
              maybe
                (JournalUnobservable "the journal mirror could not be decoded")
                JournalRead
                (parseMirror bytes)
          _ -> JournalUnobservable "a journal write is in progress or requires recovery"
