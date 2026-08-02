{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 7.14: decrypt-to-scratch Pulumi backend interposition.
--
-- Pulumi works against a temporary @file://@ backend while persistent state is
-- stored as a Model-B logical object in MinIO. The production resolver obtains
-- the object-store cipher/HMAC inputs from Vault; tests use the explicit hook
-- seam below.
module Prodbox.Pulumi.EncryptedBackend
  ( CheckpointObservability (..)
  , EncryptedBackendError (..)
  , EncryptedBackendHooks (..)
  , LegacyPulumiBackend (..)
  , PulumiScratch (..)
  , PulumiStackRef (..)
  , classifyCheckpointBytes
  , collectScratchCheckpoint
  , canonicalizeLegacyPulumiCheckpoint
  , exportLegacyPulumiCheckpoint
  , fileBackendEnvironment
  , hydrateScratchCheckpoint
  , observeStackCheckpoint
  , observeStackCheckpointAuthenticated
  , observeStackCheckpointWith
  , pruneLogicalPulumiStack
  , removeLegacyPulumiStack
  , renderCheckpointObservability
  , renderEncryptedBackendError
  , stackCheckpointPath
  , withAuthenticatedFencedDecryptedStackEnvironment
  , withAuthenticatedDecryptedStackEnvironment
  , withAuthenticatedObservedDecryptedStackEnvironment
  , withDecryptedStack
  , withDecryptedStackEnvironment
  , withFencedDecryptedStackEnvironment
  , withMigratedDecryptedStackEnvironment
  , withDecryptedStackWith
  )
where

import Control.Exception (IOException, bracket, try)
import Control.Monad qualified
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (Object), eitherDecodeStrict')
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char (isSpace, toLower)
import Data.List (isInfixOf)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric (showHex)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AuthorityOperationClient
  ( AuthorityOperationAdmission (..)
  , AuthorityOperationClient (..)
  , lifecycleAuthorityOperationClientAuthenticated
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( LifecycleAuthorityAuthentication
  , renderLifecycleAuthorityAuthenticationError
  , withLifecycleAuthorityAuthenticatedTransport
  )
import Prodbox.ControlPlane.PulumiCheckpointClient
  ( PulumiCheckpointAuthority (..)
  , lifecycleAuthorityPulumiCheckpointAuthenticated
  )
import Prodbox.ControlPlane.PulumiCheckpointEndpoint
  ( PulumiCheckpointObservation (..)
  , PulumiCheckpointPublicationResult (..)
  , PulumiCheckpointRetirementResult (..)
  )
import Prodbox.Infra.MinioBackend
  ( pulumiBackendLoginTimeoutSeconds
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , mkClientSubmissionKey
  )
import Prodbox.Lifecycle.Authority.Submission
  ( OperationId
  , RequestDigest (RequestDigest)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ChartLifetime, ClusterRetained)
  )
import Prodbox.Lifecycle.Lease
  ( FencedCommitPermit
  , modelBLeaseGuardFromPermit
  )
import Prodbox.Lifecycle.PulumiCheckpoint
  ( CanonicalPulumiCheckpoint
  , PulumiCheckpointDigest
  , PulumiCheckpointPayloadKind
    ( PulumiFileBackendCheckpoint
    , PulumiLegacyExportCheckpoint
    )
  , RegisteredPulumiCheckpoint
  , canonicalPulumiCheckpointBytes
  , canonicalPulumiCheckpointDigest
  , decodeCanonicalPulumiCheckpoint
  , pulumiCheckpointDigestText
  , pulumiCheckpointMaximumBytes
  , registeredPulumiCheckpointFor
  , registeredPulumiCheckpointName
  )
import Prodbox.Result (Result (..))
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import Prodbox.Vault.Gate
  ( VaultGateOutcome (..)
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getTemporaryDirectory
  , removeFile
  )
import System.Exit (ExitCode (..))
import System.FilePath
  ( takeDirectory
  , (</>)
  )
import System.IO (Handle, hClose, openTempFile)
import System.IO.Temp (withSystemTempDirectory, withTempDirectory)

data PulumiStackRef = PulumiStackRef
  { pulumiProjectName :: Text
  , pulumiStackName :: Text
  }
  deriving (Eq, Show)

data PulumiScratch = PulumiScratch
  { pulumiScratchRoot :: FilePath
  , pulumiScratchBackendUrl :: String
  , pulumiScratchCheckpointPath :: FilePath
  }
  deriving (Eq, Show)

data LegacyPulumiBackend = LegacyPulumiBackend
  { legacyPulumiProjectDir :: FilePath
  , legacyPulumiEnvironment :: [(String, String)]
  , legacyPulumiStackName :: Text
  }
  deriving (Eq, Show)

data EncryptedBackendError
  = EncryptedBackendVaultRefused String
  | EncryptedBackendLoadFailed String
  | EncryptedBackendHydrateFailed String
  | EncryptedBackendActionFailed String
  | EncryptedBackendCollectFailed String
  | EncryptedBackendStoreFailed String
  | EncryptedBackendDeleteFailed String
  | EncryptedBackendLegacyDeleteFailed String
  deriving (Eq, Show)

renderEncryptedBackendError :: EncryptedBackendError -> String
renderEncryptedBackendError err = case err of
  EncryptedBackendVaultRefused detail -> detail
  EncryptedBackendLoadFailed detail -> "failed to load encrypted Pulumi checkpoint: " ++ detail
  EncryptedBackendHydrateFailed detail -> "failed to hydrate Pulumi scratch backend: " ++ detail
  EncryptedBackendActionFailed detail -> detail
  EncryptedBackendCollectFailed detail -> "failed to collect Pulumi scratch checkpoint: " ++ detail
  EncryptedBackendStoreFailed detail -> "failed to store encrypted Pulumi checkpoint: " ++ detail
  EncryptedBackendDeleteFailed detail -> "failed to delete encrypted Pulumi checkpoint: " ++ detail
  EncryptedBackendLegacyDeleteFailed detail ->
    "failed to delete legacy Pulumi checkpoint after encrypted migration: " ++ detail

data EncryptedBackendHooks a = EncryptedBackendHooks
  { encryptedBackendGate :: IO VaultGateOutcome
  , encryptedBackendLoad :: PulumiStackRef -> IO (Either String (Maybe ByteString))
  , encryptedBackendLoadLegacy :: PulumiStackRef -> IO (Either String (Maybe ByteString))
  , encryptedBackendStore :: PulumiStackRef -> ByteString -> IO (Either String ())
  , encryptedBackendDelete :: PulumiStackRef -> IO (Either String ())
  , encryptedBackendDeleteLegacy :: PulumiStackRef -> IO (Either String ())
  , encryptedBackendWithScratch
      :: PulumiStackRef
      -> (PulumiScratch -> IO (Either EncryptedBackendError a))
      -> IO (Either EncryptedBackendError a)
  }

data LoadedCheckpoint = LoadedCheckpoint
  { loadedCheckpointBytes :: Maybe ByteString
  , loadedCheckpointFromLegacy :: Bool
  }

data AuthorityCheckpointClients = AuthorityCheckpointClients
  { authorityOperationClient :: !(AuthorityOperationClient IO)
  , authorityCheckpointClient :: !(PulumiCheckpointAuthority IO)
  , authorityCheckpointRegistration :: !RegisteredPulumiCheckpoint
  }

data AuthorityLoadedCheckpoint = AuthorityLoadedCheckpoint
  { authorityLoadedBytes :: !(Maybe ByteString)
  , authorityLoadedExpectedDigest :: !(Maybe PulumiCheckpointDigest)
  , authorityLoadedFromLegacy :: !Bool
  }

-- | Sprint 7.21: the observability classes of a per-run Pulumi
-- checkpoint, applying the
-- @documents\/engineering\/lifecycle_reconciliation_doctrine.md § 3.1@
-- soundness invariant to the encrypted-checkpoint backend. A destructive
-- teardown must distinguish "nothing to destroy" (absent\/empty) from
-- "cannot observe" (corrupt) so it never silently skips a possibly-live
-- stack, and never hard-fails on a genuinely-absent one.
--
--   * 'CheckpointAbsent' — the encrypted checkpoint object is missing
--     (@NoSuchKey@\/@Nothing@ loaded): the stack was never created or was
--     already destroyed. Positive evidence of @Absent@ — nothing to
--     destroy. This is the home-substrate case (the per-run AWS stacks
--     are never provisioned on home).
--   * 'CheckpointEmpty' — the object exists but is zero-length\/all
--     whitespace (the @"unexpected end of JSON input"@ failure mode when
--     Pulumi loads it). No stack state — also nothing to destroy.
--   * 'CheckpointCorrupt' — the object is non-empty but does not parse as
--     JSON. The carried 'String' is the parser detail. This is the
--     "cannot observe" class: a corrupt checkpoint may hide live
--     resources, so callers must REFUSE rather than skip.
--   * 'CheckpointPresent' — the object is non-empty and parses as a JSON
--     value: a real checkpoint to destroy.
data CheckpointObservability
  = CheckpointAbsent
  | CheckpointEmpty
  | CheckpointCorrupt !String
  | CheckpointPresent
  deriving (Eq, Show)

-- | Pure classifier (Sprint 7.21): map the loaded encrypted-checkpoint
-- bytes onto a 'CheckpointObservability'. The argument is exactly what
-- the backend load returns — @Nothing@ for an absent object, @Just bytes@
-- for a present one (which may be empty or corrupt). Kept pure so the
-- absent\/empty\/corrupt\/present discrimination is unit-testable without
-- a live MinIO\/Vault round-trip; the IO wrapper ('observeStackCheckpoint')
-- only fetches the bytes and hands them here.
--
-- The empty case is matched precisely on zero-length-or-whitespace bytes,
-- so it is distinguishable from a non-empty-but-unparseable blob: only
-- 'CheckpointAbsent' and 'CheckpointEmpty' are "nothing to destroy".
classifyCheckpointBytes :: Maybe ByteString -> CheckpointObservability
classifyCheckpointBytes Nothing = CheckpointAbsent
classifyCheckpointBytes (Just bytes)
  | BS8.all isSpace bytes = CheckpointEmpty
  | otherwise =
      case eitherDecodeStrict' bytes :: Either String Value of
        Right _ -> CheckpointPresent
        Left detail -> CheckpointCorrupt detail

-- | Operator-visible rendering of a 'CheckpointObservability'.
renderCheckpointObservability :: CheckpointObservability -> String
renderCheckpointObservability observability = case observability of
  CheckpointAbsent -> "absent"
  CheckpointEmpty -> "empty (zero-length checkpoint object)"
  CheckpointCorrupt detail -> "corrupt (" ++ detail ++ ")"
  CheckpointPresent -> "present"

withDecryptedStack
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> PulumiStackRef
  -> (PulumiScratch -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withDecryptedStack authentication _repoRoot stackRef action =
  withAuthorityCheckpointTransport authentication stackRef $ \clients ->
    withAuthorityCheckpointStack clients Nothing True (pure (Right ())) stackRef action

withDecryptedStackEnvironment
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> PulumiStackRef
  -> [(String, String)]
  -> ([(String, String)] -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withDecryptedStackEnvironment authentication repoRoot stackRef environment action =
  withDecryptedStack authentication repoRoot stackRef $ \scratch ->
    action (fileBackendEnvironment scratch environment)

-- | Provider-Worker production entrypoint.  The outbound Authority transport
-- is already authenticated as the Provider service; no host-side operator
-- authentication or repository-root discovery participates in checkpoint
-- hydration/publication.
withAuthenticatedDecryptedStackEnvironment
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> PulumiStackRef
  -> [(String, String)]
  -> ([(String, String)] -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withAuthenticatedDecryptedStackEnvironment transport stackRef environment action =
  case authorityCheckpointClients transport stackRef of
    Left detail -> pure (Left (EncryptedBackendLoadFailed detail))
    Right clients ->
      withAuthorityCheckpointStack
        clients
        Nothing
        True
        (pure (Right ()))
        stackRef
        (\scratch -> action (fileBackendEnvironment scratch environment))

-- | Read-only Provider observation over an Authority-backed checkpoint.  It
-- hydrates RAM scratch and runs the exact observer but never collects,
-- publishes, or retires a checkpoint.
withAuthenticatedObservedDecryptedStackEnvironment
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> PulumiStackRef
  -> [(String, String)]
  -> ([(String, String)] -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withAuthenticatedObservedDecryptedStackEnvironment transport stackRef environment action =
  case authorityCheckpointClients transport stackRef of
    Left detail -> pure (Left (EncryptedBackendLoadFailed detail))
    Right clients -> do
      loaded <- loadAuthorityCheckpoint clients Nothing
      case loaded of
        Left detail -> pure (Left (EncryptedBackendLoadFailed detail))
        Right checkpoint ->
          withRamScratch stackRef $ \scratch -> do
            hydrated <- hydrateScratchCheckpoint scratch (authorityLoadedBytes checkpoint)
            case hydrated of
              Left detail -> pure (Left (EncryptedBackendHydrateFailed detail))
              Right () -> do
                result <- action (fileBackendEnvironment scratch environment)
                pure (either (Left . EncryptedBackendActionFailed) Right result)

-- | Desired-present retained-stack variant over the caller-bound Authority
-- clients.  The caller's lease proof is revalidated immediately before the
-- Authority mutation; the checkpoint route then enforces the exact predecessor
-- digest CAS and registered stack identity.  A desired-present action may not
-- retire its checkpoint.
withAuthenticatedFencedDecryptedStackEnvironment
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> Maybe LegacyPulumiBackend
  -> PulumiStackRef
  -> [(String, String)]
  -> IO (Either String FencedCommitPermit)
  -> ([(String, String)] -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withAuthenticatedFencedDecryptedStackEnvironment transport maybeLegacy stackRef environment authorizeCommit action =
  case authorityCheckpointClients transport stackRef of
    Left detail -> pure (Left (EncryptedBackendLoadFailed detail))
    Right clients ->
      withAuthorityCheckpointStack
        clients
        maybeLegacy
        False
        ( do
            authorization <- authorizeCommit
            pure (Control.Monad.void authorization)
        )
        stackRef
        (\scratch -> action (fileBackendEnvironment scratch environment))

-- | Fenced variant for a long-lived desired-present transaction. The
-- checkpoint is loaded and conditionally replaced through the same retained
-- Model-B authority as the lease. Immediately before the checkpoint CAS the
-- caller revalidates current lease ownership; a stale writer therefore cannot
-- commit over a successor's checkpoint version.
withFencedDecryptedStackEnvironment
  :: ModelBCasAdapter 'ChartLifetime IO ByteString
  -> ModelBObjectCoordinate 'ChartLifetime
  -> ModelBObjectCoordinate 'ClusterRetained
  -> Maybe LegacyPulumiBackend
  -> PulumiStackRef
  -> [(String, String)]
  -> IO (Either String FencedCommitPermit)
  -> ([(String, String)] -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withFencedDecryptedStackEnvironment adapter coordinate leaseCoordinate maybeLegacy stackRef environment authorizeCommit action = do
  loadedResult <- loadFencedCheckpoint adapter coordinate maybeLegacy stackRef
  case loadedResult of
    Left err -> pure (Left (EncryptedBackendLoadFailed err))
    Right loaded ->
      withRamScratch stackRef $ \scratch -> do
        hydrateResult <- hydrateScratchCheckpoint scratch (fencedLoadedBytes loaded)
        case hydrateResult of
          Left err -> pure (Left (EncryptedBackendHydrateFailed err))
          Right () -> do
            actionResult <- action (fileBackendEnvironment scratch environment)
            collectResult <- collectScratchCheckpoint scratch
            case collectResult of
              Left err -> pure (Left (EncryptedBackendCollectFailed err))
              Right Nothing ->
                pure
                  ( Left
                      ( EncryptedBackendStoreFailed
                          "fenced desired-present reconcile produced no checkpoint; conditional delete is not permitted"
                      )
                  )
              Right (Just bytes) -> do
                authorization <- authorizeCommit
                case authorization of
                  Left err ->
                    pure
                      ( Left
                          ( EncryptedBackendStoreFailed
                              ("fenced checkpoint commit refused: " ++ err)
                          )
                      )
                  Right permit -> do
                    let guard = modelBLeaseGuardFromPermit leaseCoordinate permit
                    storeResult <-
                      modelBCompareAndSwap
                        adapter
                        ( case fencedLoadedVersion loaded of
                            Nothing -> ModelBInitializeGuarded coordinate guard bytes
                            Just version -> ModelBReplaceGuarded coordinate version guard bytes
                        )
                    case storeResult of
                      ModelBCasApplied _ _ ->
                        finalizeFencedAction
                          maybeLegacy
                          stackRef
                          (fencedLoadedFromLegacy loaded)
                          actionResult
                      ModelBCasConflict _ ->
                        pure
                          ( Left
                              ( EncryptedBackendStoreFailed
                                  "fenced checkpoint CAS conflicted with a newer authority version"
                              )
                          )
                      ModelBCasRefusedCorrupt detail ->
                        pure (Left (EncryptedBackendStoreFailed (Text.unpack detail)))
                      ModelBCasEndpointUnready detail ->
                        pure (Left (EncryptedBackendStoreFailed (Text.unpack detail)))
                      ModelBCasUnobservable detail ->
                        pure (Left (EncryptedBackendStoreFailed (Text.unpack detail)))

withMigratedDecryptedStackEnvironment
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> PulumiStackRef
  -> LegacyPulumiBackend
  -> [(String, String)]
  -> ([(String, String)] -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withMigratedDecryptedStackEnvironment authentication repoRoot stackRef legacy environment action =
  withDecryptedStackMigrating authentication repoRoot stackRef legacy $ \scratch ->
    action (fileBackendEnvironment scratch environment)

withDecryptedStackMigrating
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> PulumiStackRef
  -> LegacyPulumiBackend
  -> (PulumiScratch -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withDecryptedStackMigrating authentication _repoRoot stackRef legacy action =
  withAuthorityCheckpointTransport authentication stackRef $ \clients ->
    withAuthorityCheckpointStack clients (Just legacy) True (pure (Right ())) stackRef action

data FencedLoadedCheckpoint = FencedLoadedCheckpoint
  { fencedLoadedBytes :: !(Maybe ByteString)
  , fencedLoadedVersion :: !(Maybe ModelBObjectVersion)
  , fencedLoadedFromLegacy :: !Bool
  }

loadFencedCheckpoint
  :: ModelBCasAdapter 'ChartLifetime IO ByteString
  -> ModelBObjectCoordinate 'ChartLifetime
  -> Maybe LegacyPulumiBackend
  -> PulumiStackRef
  -> IO (Either String FencedLoadedCheckpoint)
loadFencedCheckpoint adapter coordinate maybeLegacy _stackRef = do
  observation <- modelBObserve adapter coordinate
  case observation of
    ModelBMissing -> loadLegacy Nothing
    ModelBCorrupt detail -> pure (Left ("fenced checkpoint is corrupt: " ++ Text.unpack detail))
    ModelBEndpointUnready detail -> pure (Left (Text.unpack detail))
    ModelBUnobservable detail -> pure (Left (Text.unpack detail))
    ModelBObserved version bytes
      | checkpointBytesUsable bytes ->
          pure
            ( Right
                FencedLoadedCheckpoint
                  { fencedLoadedBytes = Just bytes
                  , fencedLoadedVersion = Just version
                  , fencedLoadedFromLegacy = False
                  }
            )
      | otherwise -> loadLegacy (Just version)
 where
  loadLegacy expectedVersion =
    case maybeLegacy of
      Nothing ->
        pure
          ( Right
              FencedLoadedCheckpoint
                { fencedLoadedBytes = Nothing
                , fencedLoadedVersion = expectedVersion
                , fencedLoadedFromLegacy = False
                }
          )
      Just legacy -> do
        legacyResult <- exportLegacyPulumiCheckpoint legacy
        pure $ case legacyResult of
          Left err -> Left err
          Right bytes ->
            Right
              FencedLoadedCheckpoint
                { fencedLoadedBytes = bytes
                , fencedLoadedVersion = expectedVersion
                , fencedLoadedFromLegacy = maybe False (const True) bytes
                }

finalizeFencedAction
  :: Maybe LegacyPulumiBackend
  -> PulumiStackRef
  -> Bool
  -> Either String a
  -> IO (Either EncryptedBackendError a)
finalizeFencedAction maybeLegacy _stackRef migratedFromLegacy actionResult =
  case actionResult of
    Left err -> pure (Left (EncryptedBackendActionFailed err))
    Right value
      | not migratedFromLegacy -> pure (Right value)
      | otherwise ->
          case maybeLegacy of
            Nothing ->
              pure
                ( Left
                    ( EncryptedBackendLegacyDeleteFailed
                        "fenced checkpoint recorded legacy migration without a legacy backend"
                    )
                )
            Just legacy -> do
              deleteResult <- removeLegacyPulumiStack legacy
              pure $ case deleteResult of
                Left err -> Left (EncryptedBackendLegacyDeleteFailed err)
                Right () -> Right value

withAuthorityCheckpointTransport
  :: LifecycleAuthorityAuthentication
  -> PulumiStackRef
  -> (AuthorityCheckpointClients -> IO (Either EncryptedBackendError a))
  -> IO (Either EncryptedBackendError a)
withAuthorityCheckpointTransport authentication stackRef action = do
  transported <-
    withLifecycleAuthorityAuthenticatedTransport
      authentication
      (runWithCheckpointClients stackRef action)
  pure $ case transported of
    Left err ->
      Left
        ( EncryptedBackendLoadFailed
            (renderLifecycleAuthorityAuthenticationError err)
        )
    Right result -> result

runWithCheckpointClients
  :: PulumiStackRef
  -> (AuthorityCheckpointClients -> IO (Either EncryptedBackendError a))
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> IO (Either EncryptedBackendError a)
runWithCheckpointClients stackRef action transport =
  case authorityCheckpointClients transport stackRef of
    Left detail -> pure (Left (EncryptedBackendLoadFailed detail))
    Right clients -> action clients

authorityCheckpointClients
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> PulumiStackRef
  -> Either String AuthorityCheckpointClients
authorityCheckpointClients transport stackRef = do
  registered <-
    mapLeft
      (\err -> "Pulumi checkpoint coordinates are not registered: " ++ show err)
      ( registeredPulumiCheckpointFor
          (pulumiProjectName stackRef)
          (pulumiStackName stackRef)
      )
  Right
    AuthorityCheckpointClients
      { authorityOperationClient =
          lifecycleAuthorityOperationClientAuthenticated transport
      , authorityCheckpointClient =
          lifecycleAuthorityPulumiCheckpointAuthenticated transport registered
      , authorityCheckpointRegistration = registered
      }

withAuthorityCheckpointStack
  :: AuthorityCheckpointClients
  -> Maybe LegacyPulumiBackend
  -> Bool
  -> IO (Either String ())
  -> PulumiStackRef
  -> (PulumiScratch -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withAuthorityCheckpointStack clients maybeLegacy allowRetirement authorizeCommit stackRef action = do
  loadedResult <- loadAuthorityCheckpoint clients maybeLegacy
  case loadedResult of
    Left detail -> pure (Left (EncryptedBackendLoadFailed detail))
    Right loaded ->
      withRamScratch stackRef $ \scratch -> do
        hydrateResult <- hydrateScratchCheckpoint scratch (authorityLoadedBytes loaded)
        case hydrateResult of
          Left detail -> pure (Left (EncryptedBackendHydrateFailed detail))
          Right () -> do
            actionResult <- action scratch
            collected <- collectScratchCheckpoint scratch
            case collected of
              Left detail -> pure (Left (EncryptedBackendCollectFailed detail))
              Right Nothing
                | not allowRetirement ->
                    pure
                      ( Left
                          ( EncryptedBackendStoreFailed
                              "fenced desired-present reconcile produced no checkpoint; Authority retirement is not permitted"
                          )
                      )
              Right checkpointBytes -> do
                authorized <- authorizeCommit
                case authorized of
                  Left detail ->
                    pure
                      ( Left
                          ( EncryptedBackendStoreFailed
                              ("checkpoint commit refused: " ++ detail)
                          )
                      )
                  Right () -> do
                    persisted <-
                      persistAuthorityCheckpoint
                        clients
                        (authorityLoadedExpectedDigest loaded)
                        checkpointBytes
                    case persisted of
                      Left detail -> pure (Left (EncryptedBackendStoreFailed detail))
                      Right () ->
                        finalizeAuthorityAction
                          maybeLegacy
                          (authorityLoadedFromLegacy loaded)
                          actionResult

loadAuthorityCheckpoint
  :: AuthorityCheckpointClients
  -> Maybe LegacyPulumiBackend
  -> IO (Either String AuthorityLoadedCheckpoint)
loadAuthorityCheckpoint clients maybeLegacy = do
  observed <-
    retryAuthorityCall
      "observe registered Pulumi checkpoint"
      authorityClientRetryAttempts
      (observePulumiCheckpoint (authorityCheckpointClient clients))
  case observed of
    Left detail -> pure (Left detail)
    Right observation -> case observation of
      PulumiCheckpointMissing -> loadLegacyCheckpoint maybeLegacy Nothing
      PulumiCheckpointCurrent checkpoint ->
        pure
          ( Right
              AuthorityLoadedCheckpoint
                { authorityLoadedBytes =
                    Just (canonicalPulumiCheckpointBytes checkpoint)
                , authorityLoadedExpectedDigest =
                    Just (canonicalPulumiCheckpointDigest checkpoint)
                , authorityLoadedFromLegacy = False
                }
          )
      PulumiCheckpointCorrupt detail ->
        pure (Left ("Lifecycle Authority checkpoint is corrupt: " ++ Text.unpack detail))
      PulumiCheckpointCorruptAt _ detail ->
        pure (Left ("Lifecycle Authority checkpoint is corrupt: " ++ Text.unpack detail))
      PulumiCheckpointEndpointUnready detail ->
        pure (Left ("Lifecycle Authority checkpoint endpoint is not ready: " ++ Text.unpack detail))
      PulumiCheckpointUnobservable detail ->
        pure (Left ("Lifecycle Authority checkpoint is unobservable: " ++ Text.unpack detail))

loadLegacyCheckpoint
  :: Maybe LegacyPulumiBackend
  -> Maybe PulumiCheckpointDigest
  -> IO (Either String AuthorityLoadedCheckpoint)
loadLegacyCheckpoint maybeLegacy expected = case maybeLegacy of
  Nothing -> pure (Right (emptyAuthorityLoaded expected))
  Just legacy -> do
    loaded <- exportLegacyPulumiCheckpoint legacy
    pure $ do
      bytes <- loaded
      Right
        AuthorityLoadedCheckpoint
          { authorityLoadedBytes = bytes
          , authorityLoadedExpectedDigest = expected
          , authorityLoadedFromLegacy = maybe False (const True) bytes
          }

emptyAuthorityLoaded :: Maybe PulumiCheckpointDigest -> AuthorityLoadedCheckpoint
emptyAuthorityLoaded expected =
  AuthorityLoadedCheckpoint
    { authorityLoadedBytes = Nothing
    , authorityLoadedExpectedDigest = expected
    , authorityLoadedFromLegacy = False
    }

persistAuthorityCheckpoint
  :: AuthorityCheckpointClients
  -> Maybe PulumiCheckpointDigest
  -> Maybe ByteString
  -> IO (Either String ())
persistAuthorityCheckpoint clients expected maybeBytes = case maybeBytes of
  Nothing -> retireAuthorityCheckpoint clients expected
  Just bytes ->
    case decodeCanonicalPulumiCheckpoint
      (Set.singleton PulumiFileBackendCheckpoint)
      pulumiCheckpointMaximumBytes
      bytes of
      Left detail ->
        pure
          ( Left
              ( "refusing to publish a non-canonical Pulumi file-backend checkpoint: "
                  ++ show detail
              )
          )
      Right checkpoint -> publishAuthorityCheckpoint clients expected checkpoint

publishAuthorityCheckpoint
  :: AuthorityCheckpointClients
  -> Maybe PulumiCheckpointDigest
  -> CanonicalPulumiCheckpoint
  -> IO (Either String ())
publishAuthorityCheckpoint clients expected checkpoint = do
  let candidate = canonicalPulumiCheckpointDigest checkpoint
  operationResult <-
    submitCheckpointOperation clients "publish" expected (Just candidate)
  case operationResult of
    Left detail -> pure (Left detail)
    Right operation -> do
      published <-
        retryAuthorityCall
          "publish registered Pulumi checkpoint"
          authorityClientRetryAttempts
          ( publishPulumiCheckpoint
              (authorityCheckpointClient clients)
              operation
              expected
              checkpoint
          )
      pure $ do
        result <- published
        case result of
          PulumiCheckpointPublished actual
            | actual == candidate -> Right ()
            | otherwise -> Left "Lifecycle Authority published a different checkpoint digest"
          PulumiCheckpointAlreadyCurrent actual
            | actual == candidate -> Right ()
            | otherwise -> Left "Lifecycle Authority reported a different current checkpoint digest"
          PulumiCheckpointPublicationConflict observation ->
            Left
              ( "Lifecycle Authority checkpoint publication conflicted with "
                  ++ checkpointObservationToken observation
              )
          PulumiCheckpointPublicationRefused detail -> Left (Text.unpack detail)
          PulumiCheckpointPublicationUnavailable detail -> Left (Text.unpack detail)

retireAuthorityCheckpoint
  :: AuthorityCheckpointClients
  -> Maybe PulumiCheckpointDigest
  -> IO (Either String ())
retireAuthorityCheckpoint clients expected = do
  operationResult <- submitCheckpointOperation clients "retire" expected Nothing
  case operationResult of
    Left detail -> pure (Left detail)
    Right operation -> do
      retired <-
        retryAuthorityCall
          "retire registered Pulumi checkpoint"
          authorityClientRetryAttempts
          ( retirePulumiCheckpoint
              (authorityCheckpointClient clients)
              operation
              expected
          )
      pure $ do
        result <- retired
        case result of
          PulumiCheckpointAlreadyAbsent -> Right ()
          PulumiCheckpointRetiredAndReadBack -> Right ()
          PulumiCheckpointRetirementRefused observation ->
            Left
              ( "Lifecycle Authority checkpoint retirement conflicted with "
                  ++ checkpointObservationToken observation
              )
          PulumiCheckpointRetirementUnavailable detail -> Left (Text.unpack detail)

submitCheckpointOperation
  :: AuthorityCheckpointClients
  -> Text
  -> Maybe PulumiCheckpointDigest
  -> Maybe PulumiCheckpointDigest
  -> IO (Either String OperationId)
submitCheckpointOperation clients kind expected candidate =
  case checkpointOperationIdentity
    (authorityCheckpointRegistration clients)
    kind
    expected
    candidate of
    Left detail -> pure (Left detail)
    Right (submissionKey, requestDigest) -> do
      admitted <-
        retryAuthorityCall
          "submit registered checkpoint operation"
          authorityClientRetryAttempts
          ( submitAuthorityOperation
              (authorityOperationClient clients)
              submissionKey
              requestDigest
          )
      pure $ do
        admission <- admitted
        Right $ case admission of
          AuthorityOperationAdmissionAccepted operation -> operation
          AuthorityOperationAdmissionDuplicate operation -> operation

checkpointOperationIdentity
  :: RegisteredPulumiCheckpoint
  -> Text
  -> Maybe PulumiCheckpointDigest
  -> Maybe PulumiCheckpointDigest
  -> Either String (ClientSubmissionKey, RequestDigest)
checkpointOperationIdentity registered kind expected candidate = do
  let fingerprint =
        sha256Hex
          ( TextEncoding.encodeUtf8
              ( Text.intercalate
                  "\NUL"
                  [ "pulumi-checkpoint-operation-v1"
                  , registeredPulumiCheckpointName registered
                  , kind
                  , maybe "absent" pulumiCheckpointDigestText expected
                  , maybe "absent" pulumiCheckpointDigestText candidate
                  ]
              )
          )
  submissionKey <-
    mapLeft
      (\err -> "construct stable checkpoint submission key: " ++ show err)
      (mkClientSubmissionKey ("pulumi-checkpoint-v1-" <> fingerprint))
  Right (submissionKey, RequestDigest ("sha256-" <> fingerprint))

retryAuthorityCall
  :: (Show err)
  => String
  -> Int
  -> IO (Either err value)
  -> IO (Either String value)
retryAuthorityCall label maximumAttempts call = go maximumAttempts
 where
  go remaining = do
    attempted <- call
    case attempted of
      Right value -> pure (Right value)
      Left err
        | remaining > 1 -> go (remaining - 1)
        | otherwise -> pure (Left (label ++ " failed after bounded retry: " ++ show err))

authorityClientRetryAttempts :: Int
authorityClientRetryAttempts = 3

checkpointObservationToken :: PulumiCheckpointObservation -> String
checkpointObservationToken observation = case observation of
  PulumiCheckpointMissing -> "an absent checkpoint"
  PulumiCheckpointCurrent _ -> "a different current checkpoint"
  PulumiCheckpointCorrupt _ -> "a corrupt checkpoint"
  PulumiCheckpointCorruptAt _ _ -> "a corrupt checkpoint"
  PulumiCheckpointEndpointUnready _ -> "an endpoint-unready checkpoint"
  PulumiCheckpointUnobservable _ -> "an unobservable checkpoint"

finalizeAuthorityAction
  :: Maybe LegacyPulumiBackend
  -> Bool
  -> Either String a
  -> IO (Either EncryptedBackendError a)
finalizeAuthorityAction maybeLegacy migratedFromLegacy actionResult =
  case actionResult of
    Left detail -> pure (Left (EncryptedBackendActionFailed detail))
    Right value
      | not migratedFromLegacy -> pure (Right value)
      | otherwise -> case maybeLegacy of
          Nothing ->
            pure
              ( Left
                  ( EncryptedBackendLegacyDeleteFailed
                      "checkpoint recorded a legacy migration without a legacy backend"
                  )
              )
          Just legacy -> do
            deleted <- removeLegacyPulumiStack legacy
            pure $ case deleted of
              Left detail -> Left (EncryptedBackendLegacyDeleteFailed detail)
              Right () -> Right value

sha256Hex :: ByteString -> Text
sha256Hex = Text.pack . concatMap byteHex . BS.unpack . SHA256.hash
 where
  byteHex byte =
    let rendered = showHex byte ""
     in if length rendered == 1 then '0' : rendered else rendered

withDecryptedStackWith
  :: EncryptedBackendHooks a
  -> PulumiStackRef
  -> (PulumiScratch -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withDecryptedStackWith hooks stackRef action = do
  gateResult <- encryptedBackendGate hooks
  case gateResult of
    VaultGateRefuse message -> pure (Left (EncryptedBackendVaultRefused message))
    VaultGateProceed -> do
      loadResult <- loadHydratableCheckpoint hooks stackRef
      case loadResult of
        Left err -> pure (Left (EncryptedBackendLoadFailed err))
        Right loaded ->
          encryptedBackendWithScratch hooks stackRef $ \scratch -> do
            hydrateResult <- hydrateScratchCheckpoint scratch (loadedCheckpointBytes loaded)
            case hydrateResult of
              Left err -> pure (Left (EncryptedBackendHydrateFailed err))
              Right () -> do
                actionResult <- action scratch
                collectResult <- collectScratchCheckpoint scratch
                case collectResult of
                  Left err -> pure (Left (EncryptedBackendCollectFailed err))
                  Right Nothing -> do
                    deleteResult <- encryptedBackendDelete hooks stackRef
                    case deleteResult of
                      Left err -> pure (Left (EncryptedBackendDeleteFailed err))
                      Right () ->
                        finalizeAction hooks stackRef (loadedCheckpointFromLegacy loaded) actionResult
                  Right (Just bytes) -> do
                    storeResult <- encryptedBackendStore hooks stackRef bytes
                    case storeResult of
                      Left err -> pure (Left (EncryptedBackendStoreFailed err))
                      Right () ->
                        finalizeAction hooks stackRef (loadedCheckpointFromLegacy loaded) actionResult

-- | Sprint 7.21: read-only observability query for a per-run stack's
-- encrypted checkpoint. Production entry point used by the residue path
-- ('Prodbox.Infra.StackOutputs.observeEncryptedStackCheckpoint') so the
-- per-run destroy can fail-close on a corrupt checkpoint and skip cleanly
-- on an absent\/empty one — *without* hydrating scratch, running Pulumi,
-- or re-storing the object (it must not mutate teardown state just to
-- observe it). Resolves the same Vault-backed material as
-- 'withDecryptedStack', then classifies the loaded bytes purely.
-- Observation uses the same caller-bound Authority client as mutation. A
-- transport failure remains fail-closed; callers cannot recover by selecting
-- or reading an underlying object-store coordinate.
observeStackCheckpoint
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> PulumiStackRef
  -> IO (Either EncryptedBackendError CheckpointObservability)
observeStackCheckpoint authentication _repoRoot stackRef =
  withAuthorityCheckpointTransport authentication stackRef observeWithClients
 where
  observeWithClients = observeAuthorityCheckpointObservability

observeStackCheckpointAuthenticated
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> PulumiStackRef
  -> IO (Either EncryptedBackendError CheckpointObservability)
observeStackCheckpointAuthenticated transport stackRef =
  case authorityCheckpointClients transport stackRef of
    Left detail -> pure (Left (EncryptedBackendLoadFailed detail))
    Right clients -> observeAuthorityCheckpointObservability clients

observeAuthorityCheckpointObservability
  :: AuthorityCheckpointClients
  -> IO (Either EncryptedBackendError CheckpointObservability)
observeAuthorityCheckpointObservability clients = do
  observed <-
    retryAuthorityCall
      "observe registered Pulumi checkpoint"
      authorityClientRetryAttempts
      (observePulumiCheckpoint (authorityCheckpointClient clients))
  pure $ case observed of
    Left detail -> Left (EncryptedBackendLoadFailed detail)
    Right PulumiCheckpointMissing -> Right CheckpointAbsent
    Right (PulumiCheckpointCurrent checkpoint) ->
      Right
        ( classifyCheckpointBytes
            (Just (canonicalPulumiCheckpointBytes checkpoint))
        )
    Right (PulumiCheckpointCorrupt detail) ->
      Right (CheckpointCorrupt (Text.unpack detail))
    Right (PulumiCheckpointCorruptAt _ detail) ->
      Right (CheckpointCorrupt (Text.unpack detail))
    Right (PulumiCheckpointEndpointUnready detail) ->
      Left
        ( EncryptedBackendLoadFailed
            ("Lifecycle Authority checkpoint endpoint is not ready: " ++ Text.unpack detail)
        )
    Right (PulumiCheckpointUnobservable detail) ->
      Left
        ( EncryptedBackendLoadFailed
            ("Lifecycle Authority checkpoint is unobservable: " ++ Text.unpack detail)
        )

-- | Retire one per-run stack's registered checkpoint through the Lifecycle
-- Authority. The predecessor digest is re-observed immediately before the
-- retirement operation is admitted, so prune cannot become an arbitrary blob
-- deletion or race a successor publication.
-- This is the prune primitive behind
-- @prodbox aws stack \<stack> prune-corrupt-checkpoint@; the caller
-- ('Prodbox.Lifecycle.LiveResidue.pruneCorruptPerRunCheckpoint') first
-- observes the checkpoint and only invokes this for a genuinely-corrupt
-- (non-empty, unparseable) or empty checkpoint — never for a present one,
-- which would orphan live AWS resources.
pruneLogicalPulumiStack
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> PulumiStackRef
  -> IO (Either EncryptedBackendError ())
pruneLogicalPulumiStack authentication _repoRoot stackRef =
  withAuthorityCheckpointTransport authentication stackRef $ \clients -> do
    observed <-
      retryAuthorityCall
        "observe checkpoint before retirement"
        authorityClientRetryAttempts
        (observePulumiCheckpoint (authorityCheckpointClient clients))
    case observed of
      Left detail -> pure (Left (EncryptedBackendDeleteFailed detail))
      Right PulumiCheckpointMissing -> pure (Right ())
      Right (PulumiCheckpointCorruptAt digest _) -> do
        retired <- retireAuthorityCheckpoint clients (Just digest)
        pure (mapLeft EncryptedBackendDeleteFailed retired)
      Right (PulumiCheckpointCorrupt _) ->
        pure
          ( Left
              ( EncryptedBackendDeleteFailed
                  "corrupt checkpoint observation did not carry its Authority predecessor digest"
              )
          )
      Right (PulumiCheckpointCurrent _) ->
        pure
          ( Left
              ( EncryptedBackendDeleteFailed
                  "refusing to prune a valid current Pulumi checkpoint"
              )
          )
      Right (PulumiCheckpointEndpointUnready detail) ->
        pure (Left (EncryptedBackendDeleteFailed (Text.unpack detail)))
      Right (PulumiCheckpointUnobservable detail) ->
        pure (Left (EncryptedBackendDeleteFailed (Text.unpack detail)))

-- | Hooks-driven read-only observability query (testable seam). Runs the
-- Vault gate, loads the encrypted-or-legacy checkpoint bytes, and applies
-- the pure 'classifyCheckpointBytes'. No scratch hydration, no Pulumi
-- subprocess, no store\/delete — so observing a stack never mutates its
-- backend state.
observeStackCheckpointWith
  :: EncryptedBackendHooks a
  -> PulumiStackRef
  -> IO (Either EncryptedBackendError CheckpointObservability)
observeStackCheckpointWith hooks stackRef = do
  gateResult <- encryptedBackendGate hooks
  case gateResult of
    VaultGateRefuse message -> pure (Left (EncryptedBackendVaultRefused message))
    VaultGateProceed -> do
      loadResult <- loadEncryptedOrLegacyCheckpoint hooks stackRef
      pure $ case loadResult of
        Left err -> Left (EncryptedBackendLoadFailed err)
        Right loaded -> Right (classifyCheckpointBytes (loadedCheckpointBytes loaded))

-- | OBSERVE-path load: return the raw Model-B object as-loaded (so the residue
-- observation can classify it as Empty/Corrupt/Present via
-- 'classifyCheckpointBytes'); fall back to the legacy backend only when the
-- Model-B object is positively ABSENT. Does NOT fall back on a present-but-
-- unusable object — observation must report the object's true state.
loadEncryptedOrLegacyCheckpoint
  :: EncryptedBackendHooks a -> PulumiStackRef -> IO (Either String LoadedCheckpoint)
loadEncryptedOrLegacyCheckpoint = loadEncryptedOrLegacyCheckpointWith False

-- | HYDRATE-path load: as above, but ALSO fall back to the legacy backend when
-- the Model-B object is present-but-UNUSABLE — blank
-- (zero-length / all whitespace, the Sprint 7.21 `CheckpointEmpty` case),
-- non-blank-but-unparseable (`CheckpointCorrupt`, e.g. a truncated JSON left by
-- an interrupted store), or in the @pulumi stack export@ wire format rather than
-- the file-backend on-disk format ('checkpointBytesUsable'). Raw-hydrating such
-- an object onto the scratch state path makes pulumi fail with
-- @failed to load checkpoint: unexpected end of JSON input@. For aws-ses this
-- recovers the real state from the legacy S3 backend (so the S3 → Model-B migrate
-- can complete); for stacks whose legacy also yields nothing it produces a clean
-- fresh scratch (fresh up) rather than a truncated-checkpoint crash. (Recovery
-- semantics for the reconcile LOAD path — distinct from the per-run DESTROY gate,
-- which fail-closed REFUSES on corrupt per §3.1, since destroying-on-cannot-observe
-- is the unsafe direction; and distinct from the observe path above, which must
-- report the object's true classification.)
loadHydratableCheckpoint
  :: EncryptedBackendHooks a -> PulumiStackRef -> IO (Either String LoadedCheckpoint)
loadHydratableCheckpoint = loadEncryptedOrLegacyCheckpointWith True

loadEncryptedOrLegacyCheckpointWith
  :: Bool -> EncryptedBackendHooks a -> PulumiStackRef -> IO (Either String LoadedCheckpoint)
loadEncryptedOrLegacyCheckpointWith fallbackOnUnusable hooks stackRef = do
  encryptedResult <- encryptedBackendLoad hooks stackRef
  case encryptedResult of
    Left err -> pure (Left err)
    Right (Just checkpoint)
      | not fallbackOnUnusable || checkpointBytesUsable checkpoint ->
          pure
            ( Right
                LoadedCheckpoint
                  { loadedCheckpointBytes = Just checkpoint
                  , loadedCheckpointFromLegacy = False
                  }
            )
    _ -> do
      legacyResult <- encryptedBackendLoadLegacy hooks stackRef
      pure $ case legacyResult of
        Left err -> Left err
        Right checkpoint ->
          Right
            LoadedCheckpoint
              { loadedCheckpointBytes = checkpoint
              , loadedCheckpointFromLegacy = maybe False (const True) checkpoint
              }

-- | Sprint 7.23: a Model-B object is a usable checkpoint to RAW-HYDRATE onto
-- the scratch file-backend state path iff it is (a) 'CheckpointPresent'
-- (non-blank, decodes as JSON) AND (b) in the file-backend on-disk format
-- ('collectScratchCheckpoint' round-trips that format), NOT the
-- @pulumi stack export@ wire format. A first-touch legacy migration that
-- stored the @{ "version", "deployment" }@ EXPORT format (rather than the
-- @{ "version", "checkpoint" }@ on-disk format) leaves a Model-B object that
-- decodes fine as JSON but makes @pulumi up@ fail with
-- @failed to load checkpoint: unexpected end of JSON input@ when raw-written to
-- the state path. Treating such a foreign-format object as unusable makes
-- 'loadEncryptedOrLegacyCheckpoint' fall back (to the legacy backend, or to a
-- clean fresh scratch that the ensure cycle re-imports from live resources),
-- and the subsequent 'collectScratchCheckpoint' re-stores the correct on-disk
-- format — self-healing the object.
checkpointBytesUsable :: ByteString -> Bool
checkpointBytesUsable bytes = case classifyCheckpointBytes (Just bytes) of
  CheckpointPresent -> not (isPulumiExportFormat bytes)
  _ -> False

-- | True when the bytes are a top-level JSON object carrying a @deployment@ key
-- but no @checkpoint@ key — the signature of the @pulumi stack export@ wire
-- format, distinct from the file-backend on-disk @checkpoint@ wrapper.
isPulumiExportFormat :: ByteString -> Bool
isPulumiExportFormat bytes =
  case eitherDecodeStrict' bytes :: Either String Value of
    Right (Object o) -> KeyMap.member "deployment" o && not (KeyMap.member "checkpoint" o)
    _ -> False

finalizeAction
  :: EncryptedBackendHooks a
  -> PulumiStackRef
  -> Bool
  -> Either String a
  -> IO (Either EncryptedBackendError a)
finalizeAction hooks stackRef migratedFromLegacy actionResult =
  case actionResult of
    Left err -> pure (Left (EncryptedBackendActionFailed err))
    Right value ->
      if not migratedFromLegacy
        then pure (Right value)
        else do
          deleteLegacyResult <- encryptedBackendDeleteLegacy hooks stackRef
          pure $ case deleteLegacyResult of
            Left err -> Left (EncryptedBackendLegacyDeleteFailed err)
            Right () -> Right value

hydrateScratchCheckpoint :: PulumiScratch -> Maybe ByteString -> IO (Either String ())
hydrateScratchCheckpoint scratch checkpoint = do
  let path = pulumiScratchCheckpointPath scratch
  tryWrite path checkpoint

collectScratchCheckpoint :: PulumiScratch -> IO (Either String (Maybe ByteString))
collectScratchCheckpoint scratch = do
  exists <- doesFileExist (pulumiScratchCheckpointPath scratch)
  if not exists
    then pure (Right Nothing)
    else do
      readResult <- tryRead (pulumiScratchCheckpointPath scratch)
      pure (Just <$> readResult)

-- | Convert the exact bounded @pulumi stack export@ bytes obtained by the
-- one-shot Admin Action Runner into the normal file-backend checkpoint shape.
-- Conversion happens in fresh RAM scratch and requires no AWS or retained-store
-- credential.  The Lifecycle Authority can therefore publish only bytes whose
-- raw source digest was verified against the signed permit, without acquiring
-- the legacy backend credential itself.
canonicalizeLegacyPulumiCheckpoint
  :: LegacyPulumiBackend
  -> PulumiStackRef
  -> ByteString
  -> IO (Either EncryptedBackendError CanonicalPulumiCheckpoint)
canonicalizeLegacyPulumiCheckpoint legacy stackRef sourceBytes =
  case decodeCanonicalPulumiCheckpoint
    (Set.singleton PulumiLegacyExportCheckpoint)
    pulumiCheckpointMaximumBytes
    sourceBytes of
    Left err -> pure (Left (EncryptedBackendHydrateFailed (show err)))
    Right canonicalSource ->
      withRamScratch stackRef $ \scratch -> do
        let importPath = pulumiScratchRoot scratch </> "legacy-export.json"
            scratchLegacy =
              legacy
                { legacyPulumiEnvironment =
                    fileBackendEnvironment scratch (legacyPulumiEnvironment legacy)
                }
        written <-
          tryWrite importPath (Just (canonicalPulumiCheckpointBytes canonicalSource))
        case written of
          Left detail -> pure (Left (EncryptedBackendHydrateFailed detail))
          Right () -> do
            loggedIn <-
              runLegacyPulumiExit
                "pulumi login against migration scratch backend"
                scratchLegacy
                ["login", pulumiScratchBackendUrl scratch]
            case loggedIn of
              Left detail -> pure (Left (EncryptedBackendHydrateFailed detail))
              Right _ -> do
                initialized <-
                  runLegacyPulumiExit
                    "pulumi stack init in migration scratch backend"
                    scratchLegacy
                    ["stack", "init", Text.unpack (pulumiStackName stackRef)]
                case initialized of
                  Left detail -> pure (Left (EncryptedBackendHydrateFailed detail))
                  Right _ -> do
                    imported <-
                      runLegacyPulumiExit
                        "pulumi stack import into migration scratch backend"
                        scratchLegacy
                        [ "stack"
                        , "import"
                        , "--stack"
                        , Text.unpack (pulumiStackName stackRef)
                        , "--file"
                        , importPath
                        ]
                    case imported of
                      Left detail -> pure (Left (EncryptedBackendHydrateFailed detail))
                      Right _ -> do
                        collected <- collectScratchCheckpoint scratch
                        pure $ case collected of
                          Left detail -> Left (EncryptedBackendCollectFailed detail)
                          Right Nothing ->
                            Left
                              ( EncryptedBackendCollectFailed
                                  "legacy import produced no file-backend checkpoint"
                              )
                          Right (Just bytes) ->
                            mapLeft
                              (EncryptedBackendCollectFailed . show)
                              ( decodeCanonicalPulumiCheckpoint
                                  (Set.singleton PulumiFileBackendCheckpoint)
                                  pulumiCheckpointMaximumBytes
                                  bytes
                              )

stackCheckpointPath :: FilePath -> PulumiStackRef -> FilePath
stackCheckpointPath scratchRoot stackRef =
  scratchRoot
    </> ".pulumi"
    </> "stacks"
    </> Text.unpack (pulumiProjectName stackRef)
    </> Text.unpack (pulumiStackName stackRef)
    ++ ".json"

fileBackendEnvironment :: PulumiScratch -> [(String, String)] -> [(String, String)]
fileBackendEnvironment scratch =
  upsert "PULUMI_BACKEND_URL" (pulumiScratchBackendUrl scratch)
    -- The scratch @file://@ backend must carry an EMPTY config passphrase, not
    -- a stripped one: a stack config (@Pulumi.\<stack>.yaml@) that carries an
    -- @encryptionsalt@ — today only @aws-ses@ — forces pulumi to initialize its
    -- passphrase secrets manager while loading the stack configuration, and a
    -- bare strip yields @get stack secrets manager: passphrase must be set@
    -- (the failure that blocked the @aws-ses@ S3 → Model-B migrate reconcile).
    -- The salt was generated under the empty passphrase
    -- (@pulumiSesAdminBaseEnv@ sets @PULUMI_CONFIG_PASSPHRASE = ""@), so "" both
    -- satisfies the must-be-set check and correctly decrypts. We still strip any
    -- INHERITED (legacy-S3-backend) passphrase first, then set the empty value,
    -- so a mismatched value can never leak into the scratch backend. Stacks
    -- without an @encryptionsalt@ (the per-run stacks) ignore it.
    . upsert "PULUMI_CONFIG_PASSPHRASE" ""
    . filter ((`notElem` removedBackendKeys) . fst)
 where
  removedBackendKeys =
    [ "AWS_ACCESS_KEY_ID"
    , "AWS_SECRET_ACCESS_KEY"
    , "AWS_SESSION_TOKEN"
    , "AWS_REGION"
    , "AWS_DEFAULT_REGION"
    , "PULUMI_CONFIG_PASSPHRASE"
    ]

exportLegacyPulumiCheckpoint :: LegacyPulumiBackend -> IO (Either String (Maybe ByteString))
exportLegacyPulumiCheckpoint legacy =
  case legacyBackendUrl legacy of
    Left err -> pure (Left err)
    Right backendUrl -> do
      loginResult <-
        runLegacyPulumiExit
          "pulumi login against legacy backend"
          legacy
          ["login", backendUrl]
      case loginResult of
        Left err -> pure (Left err)
        Right _ -> do
          selectResult <-
            runLegacyPulumi legacy ["stack", "select", Text.unpack (legacyPulumiStackName legacy)]
          case selectResult of
            Left err -> pure (Left err)
            Right selectOutput ->
              case processExitCode selectOutput of
                ExitSuccess ->
                  bracket openCheckpointTemp removeCheckpointTemp $ \(path, handle) -> do
                    _ <- try (hClose handle) :: IO (Either IOException ())
                    exportResult <-
                      runLegacyPulumiExit
                        "pulumi stack export from legacy backend"
                        legacy
                        [ "stack"
                        , "export"
                        , "--stack"
                        , Text.unpack (legacyPulumiStackName legacy)
                        , "--file"
                        , path
                        ]
                    case exportResult of
                      Left err -> pure (Left err)
                      Right _ -> fmap Just <$> tryRead path
                ExitFailure _
                  | isMissingPulumiStackError
                      (Text.unpack (legacyPulumiStackName legacy))
                      (renderProcessDetail selectOutput) ->
                      pure (Right Nothing)
                  | otherwise ->
                      pure
                        ( Left
                            ( "pulumi stack select against legacy backend failed: "
                                ++ renderProcessDetail selectOutput
                            )
                        )

removeLegacyPulumiStack :: LegacyPulumiBackend -> IO (Either String ())
removeLegacyPulumiStack legacy =
  case legacyBackendUrl legacy of
    Left err -> pure (Left err)
    Right backendUrl -> do
      loginResult <-
        runLegacyPulumiExit
          "pulumi login against legacy backend"
          legacy
          ["login", backendUrl]
      case loginResult of
        Left err -> pure (Left err)
        Right _ -> do
          removeResult <-
            runLegacyPulumi
              legacy
              [ "stack"
              , "rm"
              , "--yes"
              , "--remove-backups"
              , "--force"
              , Text.unpack (legacyPulumiStackName legacy)
              ]
          pure $ case removeResult of
            Left err -> Left err
            Right output ->
              case processExitCode output of
                ExitSuccess -> Right ()
                ExitFailure _
                  | isMissingPulumiStackError
                      (Text.unpack (legacyPulumiStackName legacy))
                      (renderProcessDetail output) ->
                      Right ()
                  | otherwise ->
                      Left
                        ( "pulumi stack rm against legacy backend failed: "
                            ++ renderProcessDetail output
                        )

legacyBackendUrl :: LegacyPulumiBackend -> Either String String
legacyBackendUrl legacy =
  case lookup "PULUMI_BACKEND_URL" (legacyPulumiEnvironment legacy) of
    Just value | not (null (trim value)) -> Right value
    _ -> Left "legacy Pulumi backend environment is missing PULUMI_BACKEND_URL"

runLegacyPulumiExit
  :: String -> LegacyPulumiBackend -> [String] -> IO (Either String ProcessOutput)
runLegacyPulumiExit label legacy arguments = do
  outputResult <- runLegacyPulumi legacy arguments
  pure $ case outputResult of
    Left err -> Left err
    Right output ->
      case processExitCode output of
        ExitSuccess -> Right output
        ExitFailure 124
          | isPulumiLoginCommand arguments ->
              Left
                ( "timed out after "
                    ++ show pulumiBackendLoginTimeoutSeconds
                    ++ " seconds while running `pulumi login` against the legacy backend"
                )
        ExitFailure _ -> Left (label ++ " failed: " ++ renderProcessDetail output)

runLegacyPulumi :: LegacyPulumiBackend -> [String] -> IO (Either String ProcessOutput)
runLegacyPulumi legacy arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath =
            if isPulumiLoginCommand arguments
              then "timeout"
              else "pulumi"
        , subprocessArguments =
            if isPulumiLoginCommand arguments
              then
                [ "--kill-after=10s"
                , show pulumiBackendLoginTimeoutSeconds
                , "pulumi"
                ]
                  ++ arguments
                  ++ ["--non-interactive"]
              else arguments
        , subprocessEnvironment = Just (legacyPulumiEnvironment legacy)
        , subprocessWorkingDirectory = Just (legacyPulumiProjectDir legacy)
        }
  pure $ case result of
    Failure err -> Left err
    Success output -> Right output

isPulumiLoginCommand :: [String] -> Bool
isPulumiLoginCommand arguments =
  case arguments of
    "login" : _ -> True
    _ -> False

isMissingPulumiStackError :: String -> String -> Bool
isMissingPulumiStackError stackName detail =
  let lowered = map toLower detail
      loweredStackName = map toLower stackName
   in "no stack named" `isInfixOf` lowered
        && loweredStackName `isInfixOf` lowered
        && "found" `isInfixOf` lowered

renderProcessDetail :: ProcessOutput -> String
renderProcessDetail output =
  case filter (not . null) [trim (processStderr output), trim (processStdout output)] of
    [] -> "subprocess exited without output"
    rendered -> foldr1 (\left right -> left ++ " | " ++ right) rendered

openCheckpointTemp :: IO (FilePath, Handle)
openCheckpointTemp = do
  parent <- getTemporaryDirectory
  openTempFile parent "prodbox-pulumi-legacy-export.json"

removeCheckpointTemp :: (FilePath, Handle) -> IO ()
removeCheckpointTemp (path, handle) = do
  _ <- try (hClose handle) :: IO (Either IOException ())
  _ <- try (removeFile path) :: IO (Either IOException ())
  pure ()

withRamScratch
  :: PulumiStackRef
  -> (PulumiScratch -> IO (Either EncryptedBackendError a))
  -> IO (Either EncryptedBackendError a)
withRamScratch stackRef action = do
  shmExists <- doesDirectoryExist "/dev/shm"
  let runWith parent = withTempDirectory parent "prodbox-pulumi-" (action . scratchAt)
      scratchAt root =
        PulumiScratch
          { pulumiScratchRoot = root
          , pulumiScratchBackendUrl = "file://" ++ root
          , pulumiScratchCheckpointPath = stackCheckpointPath root stackRef
          }
  if shmExists
    then runWith "/dev/shm"
    else withSystemTempDirectory "prodbox-pulumi-" (action . scratchAt)

tryWrite :: FilePath -> Maybe ByteString -> IO (Either String ())
tryWrite path Nothing = do
  createDirectoryIfMissing True (takeDirectory path)
  pure (Right ())
tryWrite path (Just bytes) = do
  tryIo $ do
    createDirectoryIfMissing True (takeDirectory path)
    BS.writeFile path bytes

tryRead :: FilePath -> IO (Either String ByteString)
tryRead path = tryIo (BS.readFile path)

tryIo :: IO a -> IO (Either String a)
tryIo action = do
  result <- try action
  pure $ case result of
    Left (err :: IOException) -> Left (show err)
    Right value -> Right value

upsert :: String -> String -> [(String, String)] -> [(String, String)]
upsert key value environment =
  (key, value) : filter ((/= key) . fst) environment

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f value = case value of
  Left err -> Left (f err)
  Right ok -> Right ok

trim :: String -> String
trim = reverse . dropWhile (\c -> c == '\n' || c == '\r' || c == ' ') . reverse
