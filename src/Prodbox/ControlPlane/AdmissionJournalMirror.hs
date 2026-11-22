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

import Control.Exception (IOException, try)
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
import System.Directory (doesFileExist, renameFile)
import System.FilePath ((</>))

-- | The volume the Authority chart mounts for its journal.
journalMountDirectory :: FilePath
journalMountDirectory = "/var/lib/prodbox/lifecycle-authority-journal"

mirrorPath, genesisPath :: FilePath -> FilePath
mirrorPath directory = directory </> "admission.json"
genesisPath directory = directory </> "genesis.json"

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
    try (ByteString.writeFile temporary bytes >> renameFile temporary path)
      :: IO (Either IOException ())
  pure (either (Left . ("journal mirror write failed: " ++) . take 120 . show) Right written)

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
        let operations = observedOperations (ledgerJournalObservation (authorityAggregateSubmissionLedger aggregate))
        mirrored <- atomicWrite (mirrorPath directory) (renderMirror operations)
        case mirrored of
          Left failure -> pure (Left (Text.pack failure))
          Right () -> compareAndSwapAuthorityAdmission repository expected aggregate
    }

-- | Write the genesis record once, and backfill the mirror from the committed
-- aggregate when one already exists, so the volume starts consistent with the
-- store.
initialiseJournalMirror
  :: FilePath
  -> AuthorityAdmissionRepository IO revision
  -> IO (Either String ())
initialiseJournalMirror directory repository = do
  snapshot <- readAuthorityAdmission repository
  case snapshot of
    Left failure -> pure (Left ("the committed admission could not be read: " ++ Text.unpack failure))
    Right observed -> do
      let operations =
            observedOperations
              ( ledgerJournalObservation
                  (authorityAggregateSubmissionLedger (authorityAdmissionSnapshotState observed))
              )
      mirrored <- atomicWrite (mirrorPath directory) (renderMirror operations)
      case mirrored of
        Left failure -> pure (Left failure)
        Right () -> do
          present <- doesFileExist (genesisPath directory)
          if present then pure (Right ()) else atomicWrite (genesisPath directory) "genesis\n"

-- | Read the mirror as an admission observation. Without the genesis record the
-- journal is unobservable (never initialized by this Authority), not empty.
observeJournalMirror :: FilePath -> IO JournalObservation
observeJournalMirror directory = do
  genesis <- try (doesFileExist (genesisPath directory)) :: IO (Either IOException Bool)
  case genesis of
    Left failure -> pure (JournalUnobservable (Text.pack ("journal unreadable: " ++ take 80 (show failure))))
    Right False -> pure (JournalUnobservable "the journal was never initialized by this Authority")
    Right True -> do
      contents <-
        try (ByteString.readFile (mirrorPath directory)) :: IO (Either IOException ByteString.ByteString)
      pure $ case contents of
        Left _ -> JournalUnobservable "the journal mirror is missing although the journal was initialized"
        Right bytes ->
          maybe
            (JournalUnobservable "the journal mirror could not be decoded")
            JournalRead
            (parseMirror bytes)
