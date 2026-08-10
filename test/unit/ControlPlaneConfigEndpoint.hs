{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneConfigEndpoint
  ( controlPlaneConfigEndpointSuite
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString8
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (..)
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.ControlPlane.ConfigEndpoint
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (..)
  , AuthoritySubmissionGateRefusal (..)
  , authorityAggregateConfig
  , initialCleanInstallAuthority
  , stepAuthorityAdmission
  )
import Prodbox.Lifecycle.Authority.BackupRepair
  ( BackupHealth (BackupTemporarilyUnavailable)
  , BackupRepairCommand (AssessBackupHealth)
  )
import Prodbox.Lifecycle.Authority.Config
  ( ConfigDigest (..)
  , ConfigGeneration (..)
  , ConfigReference (..)
  , ConfigSchemaVersion (..)
  , ConfigState (..)
  , InForceConfig (..)
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityGenesisCommand (..)
  , BackupReceipt (..)
  , GenesisPlan (..)
  , TargetAgentGenerationReceipt (..)
  )
import Prodbox.Runtime.Role (RuntimeRole (GatewayRuntime))
import TestSupport

data CasBehavior
  = CasApply
  | CasApplyThenLoseResponse
  | CasReject
  deriving (Eq, Show)

data ConfigFixture = ConfigFixture
  { fixtureRepository :: !(ConfigAuthorityRepository IO)
  , fixtureAggregate :: !(IORef (Word, AuthorityAdmissionAggregate))
  , fixtureBlobs :: !(IORef [(ConfigDigest, ByteString)])
  , fixtureBlobOverride :: !(IORef (Maybe ConfigBlobObservation))
  , fixtureReadFailure :: !(IORef (Maybe Text))
  , fixtureCasBehavior :: !(IORef CasBehavior)
  , fixtureCasCalls :: !(IORef Int)
  , fixtureReplicationCalls :: !(IORef Int)
  }

controlPlaneConfigEndpointSuite :: SuiteBuilder ()
controlPlaneConfigEndpointSuite =
  describe "Sprint 4.50 authority-owned in-force config endpoint" $ do
    it "keeps proposals frozen until both genesis read-backs establish backup" $ do
      fixture <- newConfigFixture frozenAuthority
      response <- proposeAuthorityConfig (fixtureRepository fixture) (seedRequest configV1)
      response `shouldBe` ConfigProposalRefusedByGate AuthorityGenesisFrozen
      readIORef (fixtureReplicationCalls fixture) `shouldReturn` 0
      readIORef (fixtureCasCalls fixture) `shouldReturn` 0

    it "seeds only after genesis, replicates before aggregate CAS, and projects by role" $ do
      fixture <- newConfigFixture openedAuthority
      response <- proposeAuthorityConfig (fixtureRepository fixture) (seedRequest configV1)
      identity <- seededIdentity response
      inForceGeneration identity `shouldBe` ConfigGeneration 1
      readIORef (fixtureReplicationCalls fixture) `shouldReturn` 1
      readIORef (fixtureCasCalls fixture) `shouldReturn` 1
      (_, aggregate) <- readIORef (fixtureAggregate fixture)
      authorityAggregateConfig aggregate `shouldBe` ConfigInForce identity
      observeAuthorityConfig (fixtureRepository fixture) ConfigProjectionGatewayRuntime
        `shouldReturn` ConfigObservationObserved
          ConfigProjection
            { configProjectionIdentity = identity
            , configProjectionScope = ConfigProjectionGatewayRuntime
            , configProjectionBytes = projected ConfigProjectionGatewayRuntime configV1
            }

    it "advances by exact generation and converges after an applied CAS response is lost" $ do
      fixture <- seededFixture
      response2 <-
        proposeAuthorityConfig
          (fixtureRepository fixture)
          (updateRequest 1 configV2)
      identity2 <- advancedIdentity response2
      inForceGeneration identity2 `shouldBe` ConfigGeneration 2
      writeIORef (fixtureCasBehavior fixture) CasApplyThenLoseResponse
      response3 <-
        proposeAuthorityConfig
          (fixtureRepository fixture)
          (updateRequest 2 configV3)
      identity3 <- advancedIdentity response3
      inForceGeneration identity3 `shouldBe` ConfigGeneration 3
      casBeforeReplay <- readIORef (fixtureCasCalls fixture)
      replicationsBeforeReplay <- readIORef (fixtureReplicationCalls fixture)
      replay <-
        proposeAuthorityConfig
          (fixtureRepository fixture)
          (updateRequest 1 configV3)
      replay `shouldBe` ConfigProposalAlreadyCurrent identity3
      readIORef (fixtureCasCalls fixture) `shouldReturn` casBeforeReplay
      readIORef (fixtureReplicationCalls fixture) `shouldReturn` replicationsBeforeReplay

    it "returns the authoritative current projection after a lost aggregate CAS" $ do
      fixture <- seededFixture
      writeIORef (fixtureCasBehavior fixture) CasReject
      response <-
        proposeAuthorityConfig
          (fixtureRepository fixture)
          (updateRequest 1 configV2)
      case response of
        ConfigProposalConflict (ConfigObservationObserved projection) -> do
          inForceGeneration (configProjectionIdentity projection)
            `shouldBe` ConfigGeneration 1
          configProjectionScope projection `shouldBe` ConfigProjectionOperator
          configProjectionBytes projection
            `shouldBe` projected ConfigProjectionOperator configV1
        other -> expectationFailure ("expected config CAS conflict, got " ++ show other)

    it "distinguishes missing, corrupt, and unobservable config state" $ do
      missingFixture <- newConfigFixture openedAuthority
      observeAuthorityConfig (fixtureRepository missingFixture) ConfigProjectionOperator
        `shouldReturn` ConfigObservationMissing
      fixture <- seededFixture
      writeIORef (fixtureBlobs fixture) []
      observeAuthorityConfig (fixtureRepository fixture) ConfigProjectionOperator
        `shouldReturn` ConfigObservationCorrupt
          "Authority config reference names a missing blob"
      writeIORef
        (fixtureBlobOverride fixture)
        (Just (ConfigBlobCorrupt "ciphertext digest mismatch"))
      observeAuthorityConfig (fixtureRepository fixture) ConfigProjectionOperator
        `shouldReturn` ConfigObservationCorrupt "ciphertext digest mismatch"
      writeIORef (fixtureBlobOverride fixture) (Just (ConfigBlobUnobservable "backup unavailable"))
      observeAuthorityConfig (fixtureRepository fixture) ConfigProjectionOperator
        `shouldReturn` ConfigObservationUnobservable "backup unavailable"
      writeIORef (fixtureReadFailure fixture) (Just "aggregate unavailable")
      observeAuthorityConfig (fixtureRepository fixture) ConfigProjectionOperator
        `shouldReturn` ConfigObservationUnobservable "aggregate unavailable"

    it "freezes config CAS during a later backup outage" $ do
      fixture <- seededFixture
      modifyIORef' (fixtureAggregate fixture) $ \(revision, aggregate) ->
        ( revision + 1
        , snd
            ( stepAuthorityAdmission
                aggregate
                (ApplyAuthorityBackupRepair (AssessBackupHealth BackupTemporarilyUnavailable))
            )
        )
      response <-
        proposeAuthorityConfig
          (fixtureRepository fixture)
          (updateRequest 1 configV2)
      response `shouldBe` ConfigProposalRefusedByGate AuthorityBackupRepairFrozen

    it "binds observe projection to the authenticated caller and bars services from proposing" $ do
      calls <- newIORef (0 :: Int)
      let repository =
            ConfigAuthorityRepository
              { observeAuthorityConfig = \scope ->
                  pure
                    ( ConfigObservationObserved
                        ConfigProjection
                          { configProjectionIdentity = identityV1
                          , configProjectionScope = scope
                          , configProjectionBytes = projected scope configV1
                          }
                    )
              , proposeAuthorityConfig = \_ -> do
                  modifyIORef' calls (+ 1)
                  pure (ConfigProposalAlreadyCurrent identityV1)
              }
          gateway = verifiedCallerSlotFixture (CallerService GatewayRuntime) 1
          operator = verifiedCallerSlotFixture CallerOperatorCli 1
      mismatched <-
        serveConfigObserveRequest
          4096
          repository
          gateway
          (encodeControlPlaneRequest (ConfigObserveRequest ConfigProjectionOperator))
      mismatched `shouldBe` ConfigEndpointForbidden
      observed <-
        serveConfigObserveRequest
          4096
          repository
          gateway
          ( encodeControlPlaneRequest
              (ConfigObserveRequest ConfigProjectionGatewayRuntime)
          )
      configEndpointHttpStatus observed `shouldBe` ReplyOk
      forbidden <-
        serveConfigProposeCasRequest
          4096
          repository
          gateway
          (encodeControlPlaneRequest (seedRequest configV1))
      forbidden `shouldBe` ConfigEndpointForbidden
      readIORef calls `shouldReturn` 0
      permitted <-
        serveConfigProposeCasRequest
          4096
          repository
          operator
          (encodeControlPlaneRequest (seedRequest configV1))
      permitted `shouldBe` ConfigEndpointRespond (ConfigProposalAlreadyCurrent identityV1)
      readIORef calls `shouldReturn` 1

    it "rejects empty, oversized, non-canonical, and unsupported-schema proposals before writes" $ do
      fixture <- newConfigFixture openedAuthority
      empty <- proposeAuthorityConfig (fixtureRepository fixture) (seedRequest "")
      empty `shouldBe` ConfigProposalInvalid "config proposal must not be empty"
      oversized <-
        proposeAuthorityConfig
          (fixtureRepository fixture)
          (seedRequest (ByteString8.replicate (configPayloadMaximumBytes + 1) 'x'))
      oversized `shouldBe` ConfigProposalInvalid "config proposal exceeds the compiled bound"
      let nonCanonicalCompiler =
            configCompiler
              { compileCanonicalConfig = \_ -> pure (Right configV1)
              }
          repository =
            aggregateConfigAuthorityRepository
              (admissionRepository fixture)
              (blobStore fixture)
              nonCanonicalCompiler
      nonCanonical <- proposeAuthorityConfig repository (seedRequest "not-canonical")
      nonCanonical `shouldBe` ConfigProposalInvalid "config proposal is not canonical"
      unsupported <-
        proposeAuthorityConfig
          (fixtureRepository fixture)
          (seedRequest configV1) {configProposeSchema = ConfigSchemaVersion 99}
      case unsupported of
        ConfigProposalRefused _ -> pure ()
        other -> expectationFailure ("expected unsupported-schema refusal, got " ++ show other)
      readIORef (fixtureReplicationCalls fixture) `shouldReturn` 0
      readIORef (fixtureCasCalls fixture) `shouldReturn` 0

newConfigFixture :: AuthorityAdmissionAggregate -> IO ConfigFixture
newConfigFixture aggregate = do
  aggregateRef <- newIORef (1, aggregate)
  blobsRef <- newIORef []
  overrideRef <- newIORef Nothing
  readFailureRef <- newIORef Nothing
  casBehaviorRef <- newIORef CasApply
  casCallsRef <- newIORef 0
  replicationCallsRef <- newIORef 0
  let fixture =
        ConfigFixture
          { fixtureRepository =
              aggregateConfigAuthorityRepository
                repository
                store
                configCompiler
          , fixtureAggregate = aggregateRef
          , fixtureBlobs = blobsRef
          , fixtureBlobOverride = overrideRef
          , fixtureReadFailure = readFailureRef
          , fixtureCasBehavior = casBehaviorRef
          , fixtureCasCalls = casCallsRef
          , fixtureReplicationCalls = replicationCallsRef
          }
      repository = admissionRepository fixture
      store = blobStore fixture
  pure fixture

admissionRepository
  :: ConfigFixture
  -> AuthorityAdmissionRepository IO Word
admissionRepository fixture =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = do
        failed <- readIORef (fixtureReadFailure fixture)
        case failed of
          Just detail -> pure (Left detail)
          Nothing -> do
            (revision, aggregate) <- readIORef (fixtureAggregate fixture)
            pure
              ( Right
                  AuthorityAdmissionSnapshot
                    { authorityAdmissionRevision = revision
                    , authorityAdmissionSnapshotState = aggregate
                    }
              )
    , compareAndSwapAuthorityAdmission = \expected next -> do
        modifyIORef' (fixtureCasCalls fixture) (+ 1)
        behavior <- readIORef (fixtureCasBehavior fixture)
        (revision, _current) <- readIORef (fixtureAggregate fixture)
        if expected /= revision
          then pure (Left "stale aggregate revision")
          else case behavior of
            CasReject -> pure (Left "simulated CAS response loss before apply")
            CasApply -> do
              writeIORef (fixtureAggregate fixture) (revision + 1, next)
              pure (Right ())
            CasApplyThenLoseResponse -> do
              writeIORef (fixtureAggregate fixture) (revision + 1, next)
              pure (Left "simulated CAS response loss after apply")
    }

blobStore :: ConfigFixture -> ConfigBlobStore IO
blobStore fixture =
  ConfigBlobStore
    { replicateConfigBlob = \digest bytes -> do
        modifyIORef' (fixtureReplicationCalls fixture) (+ 1)
        modifyIORef' (fixtureBlobs fixture) ((digest, bytes) :)
        pure (Right (referenceFor digest))
    , observeConfigBlob = \digest reference -> do
        overridden <- readIORef (fixtureBlobOverride fixture)
        case overridden of
          Just result -> pure result
          Nothing -> do
            blobs <- readIORef (fixtureBlobs fixture)
            pure $ case lookup digest blobs of
              Nothing -> ConfigBlobMissing
              Just bytes
                | reference == referenceFor digest -> ConfigBlobCurrent bytes
                | otherwise -> ConfigBlobCorrupt "reference mismatch"
    }

configCompiler :: ConfigPayloadCompiler IO
configCompiler =
  ConfigPayloadCompiler
    { compileCanonicalConfig = pure . Right
    , compileConfigProjection = \scope bytes ->
        pure (Right (projected scope bytes))
    }

seededFixture :: IO ConfigFixture
seededFixture = do
  fixture <- newConfigFixture openedAuthority
  response <- proposeAuthorityConfig (fixtureRepository fixture) (seedRequest configV1)
  _ <- seededIdentity response
  pure fixture

seededIdentity :: ConfigProposeCasResponse -> IO InForceConfig
seededIdentity response = case response of
  ConfigProposalSeeded identity -> pure identity
  other -> expectationFailure ("expected config seed, got " ++ show other) >> pure identityV1

advancedIdentity :: ConfigProposeCasResponse -> IO InForceConfig
advancedIdentity response = case response of
  ConfigProposalAdvanced identity -> pure identity
  other -> expectationFailure ("expected config advance, got " ++ show other) >> pure identityV1

seedRequest :: ByteString -> ConfigProposeCasRequest
seedRequest bytes =
  ConfigProposeCasRequest
    { configProposeExpectedGeneration = Nothing
    , configProposeSchema = ConfigSchemaVersion 1
    , configProposeCanonicalBytes = bytes
    }

updateRequest :: Integer -> ByteString -> ConfigProposeCasRequest
updateRequest generation bytes =
  ConfigProposeCasRequest
    { configProposeExpectedGeneration = Just (ConfigGeneration (fromInteger generation))
    , configProposeSchema = ConfigSchemaVersion 1
    , configProposeCanonicalBytes = bytes
    }

referenceFor :: ConfigDigest -> ConfigReference
referenceFor (ConfigDigest digest) = ConfigReference digest

projected :: ConfigProjectionScope -> ByteString -> ByteString
projected scope bytes = ByteString8.pack (show scope) <> ":" <> bytes

configV1 :: ByteString
configV1 = "canonical-v1"

configV2 :: ByteString
configV2 = "canonical-v2"

configV3 :: ByteString
configV3 = "canonical-v3"

frozenAuthority :: AuthorityAdmissionAggregate
frozenAuthority = mustRight (initialCleanInstallAuthority 4 8)

openedAuthority :: AuthorityAdmissionAggregate
openedAuthority =
  foldl
    (\aggregate command -> snd (stepAuthorityAdmission aggregate command))
    frozenAuthority
    [ ApplyAuthorityGenesis
        (BeginGenesisEstablishment (GenesisPlan "config-genesis" "backup/config"))
    , ApplyAuthorityGenesis
        (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "target-generation-1"))
    , ApplyAuthorityGenesis
        (ObserveBackupReceipt (BackupReceipt "backup-receipt-1"))
    ]

identityV1 :: InForceConfig
identityV1 =
  InForceConfig
    { inForceGeneration = ConfigGeneration 1
    , inForceSchema = ConfigSchemaVersion 1
    , inForceDigest = ConfigDigest digest64
    , inForceReference = ConfigReference digest64
    }
 where
  digest64 = Text.replicate 64 "a"

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
