{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}

-- | Deterministic in-memory Bootstrap Broker boundaries for exhaustive unit
-- and real-loopback fixtures.  The fake does not pretend to perform crypto:
-- opaque values are deterministic outputs of the already-typed boundary, and
-- all root/child durable transitions are driven through the production custody
-- folds.
module Prodbox.Bootstrap.Broker.Fake
  ( FakeBrokerState (..)
  , FakeStoreState (..)
  , FakeCrashStage (..)
  , FakeCrashPoint (..)
  , FakeBrokerFailure (..)
  , FakeBrokerAction (..)
  , FakeBrokerInjectedCrash (..)
  , FakeBrokerSnapshot (..)
  , FakeBroker
  , newFakeBroker
  , newFakeBrokerInState
  , setFakeBrokerState
  , readFakeBrokerSnapshot
  , readFakeBrokerActions
  , clearFakeBrokerActions
  , injectFakeCrashOnce
  , clearFakeCrashes
  , fakeBrokerTransportCredentialHeaderValue
  , fakeBrokerActionRequestFor
  , fakeBrokerRequestBodyFor
  , fakeBrokerActionDigest
  , fakeBrokerActionBinding
  , fakeBrokerAuthenticator
  , fakeBrokerInterpreter
  )
where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception (Exception, throwIO)
import Control.Monad (foldM)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Custody
  ( ChildCustodyCommand (..)
  , ChildCustodyPhase (..)
  , ChildCustodyState (..)
  , ChildRecoveryCommand (..)
  , ChildRecoveryPhase (..)
  , ChildRecoveryState (..)
  , RootInitCommand (..)
  , RootInitPhase (..)
  , RootInitState (..)
  , applyChildCustodyCommand
  , applyChildRecoveryCommand
  , applyRootInitCommand
  , childCustodyIsComplete
  , newChildCustodyState
  , newChildRecoveryState
  , newRootInitState
  , rootInitIsAmbiguous
  , rootInitIsComplete
  )
import Prodbox.Bootstrap.Broker.Engine
  ( BrokerEngine
  , BrokerEngineBoundary (..)
  , BrokerEngineError (..)
  , BrokerInMemoryBoundary (..)
  , BrokerInMemoryCall (..)
  , BrokerProgramEvidenceBoundary (..)
  , EngineBoundaryError (..)
  , EngineFenceUseObservation (..)
  , mkBrokerEngine
  )
import Prodbox.Bootstrap.Broker.EngineAdapter (runEngineBrokerRequest)
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapFenceStoreObservation (..)
  , BootstrapLeaseObservation (..)
  , BootstrapSessionFence
  , bootstrapFenceGeneration
  , bootstrapFenceGenerationValue
  , bootstrapLeaseBindingForFence
  , reloadBootstrapSessionFence
  , storeMutationPermitActionDigest
  , vaultEffectPermitActionDigest
  )
import Prodbox.Bootstrap.Broker.Model
  ( VaultSealObservation (..)
  , VaultSealPhase (..)
  , VaultSealState (..)
  , newVaultSealState
  , observeVaultSeal
  , vaultSealIsUnsealed
  )
import Prodbox.Bootstrap.Broker.Program
  ( BootstrapMutationReceipt (..)
  , BootstrapStatus (..)
  , BrokerCapabilityRefs
  , PkiIssueRequest
  , VaultPkiStatus (..)
  , mkBrokerCapabilityRefs
  , mkPkiIssueRequest
  )
import Prodbox.Bootstrap.Broker.Protocol
  ( BrokerActionRequest
  , BrokerControllerRequest
  , BrokerProtocolError (..)
  , brokerActionDigest
  , brokerActionStorageGeneration
  , brokerControllerRequestAction
  , brokerRouteOperationName
  , decodeBrokerControllerRequest
  , encodeBrokerControllerRequest
  , mkBrokerActionRequest
  , mkBrokerControllerRequest
  , mkBrokerPkiControllerRequest
  )
import Prodbox.Bootstrap.Broker.Request
  ( RequestDigest
  , renderRequestDigest
  , requestDigestForBytes
  )
import Prodbox.Bootstrap.Broker.Routes
  ( BrokerBodyRequirement (..)
  , BrokerRoute (..)
  , brokerRouteBodyRequirement
  )
import Prodbox.Bootstrap.Broker.Server
  ( BrokerAuthenticationFailure (..)
  , BrokerAuthenticationRequest (..)
  , BrokerAuthenticator (..)
  , BrokerInterpreter (..)
  , BrokerReply
  , BrokerReplyStatus (..)
  , BrokerRequestBody
  , brokerRequestAuthentication
  , mkBrokerReply
  , withBrokerRequestBody
  , withBrokerTransportCredential
  )
import Prodbox.Bootstrap.Broker.StoreBoundary
  ( BootstrapStoreBoundary (..)
  , unavailableBootstrapStoreBoundary
  )
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , BootstrapTransactionId
  , BurnTokenCiphertext
  , ChildAttestation
  , ChildCustodyBinding (..)
  , ChildRecoveryConsumptionStatus (..)
  , ChildRecoveryDelivery
  , CustodyGeneration
  , DeliveryNonce
  , EncryptedChildRecoveryPayload
  , EncryptedInitResponseReceipt
  , FinalUnlockBundle
  , FinalUnlockBundlePayload
  , ParentCustodyAcknowledgement
  , PasswordAeadCiphertext
  , PgpEncryptedShare
  , PreparedInitEnvelope
  , PristineResetProof
  , PristineStorageProof
  , RecoveredUnsealShare
  , RecoveryCustodyReceipt
  , RecoveryRecipientFingerprint
  , RootInitBinding (..)
  , RootSessionId
  , SealedRecoveryRecipientPrivateKey
  , VaultStorageGeneration
  , mkArtifactDigest
  , mkBaselineReadBackReceipt
  , mkBaselineStateAbsence
  , mkBootstrapSchemaVersion
  , mkBootstrapTransactionId
  , mkBurnRecipientFingerprint
  , mkBurnTokenCiphertext
  , mkChildAttestation
  , mkChildEncryptedReceipt
  , mkChildId
  , mkChildRecoveryConsumptionObservation
  , mkChildRecoveryDelivery
  , mkCustodyGeneration
  , mkDeliveryNonce
  , mkDurableInitResponseAbsence
  , mkEncryptedChildRecoveryPayload
  , mkEncryptedInitResponseReceipt
  , mkEstablishedStateAbsence
  , mkFinalUnlockBundle
  , mkFinalUnlockBundlePayload
  , mkInitRecipientCommitment
  , mkParentCustodyAcknowledgement
  , mkPasswordAeadCiphertext
  , mkPgpEncryptedShare
  , mkPreparedInitEnvelope
  , mkPristineResetProof
  , mkPristineStorageProof
  , mkRecoveredUnsealShare
  , mkRecoveryCustodyReceipt
  , mkRecoveryRecipientFingerprint
  , mkRootSessionId
  , mkSealedRecoveryRecipientPrivateKey
  , mkVaultStorageGeneration
  , pristineStorageBinding
  , recoveryCustodyBinding
  , renderArtifactDigest
  , requiredRootBaselineTargets
  )
import Prodbox.ControlPlane.AuthorityClock
  ( AuthorityClockObservation (..)
  , clockUncertaintyFromMicros
  )
import Prodbox.ControlPlane.Coordinate
  ( CapabilityCoordinate
  , mkAuthorityScope
  , mkCapabilityEndpoint
  , mkCoordinate
  , mkLogicalName
  , mkServiceIdentity
  )
import Prodbox.ControlPlane.Deadline
  ( RemainingDuration (..)
  , deadlineAtOffset
  , monotonicInstantFromMicros
  )
import Prodbox.Lifecycle.Lease
  ( authorityTimeFromMicros
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.TargetCommitIntent (mkCredentialGeneration)

data FakeBrokerState
  = FakeEmpty
  | FakeInitializedSealed
  | FakeUnsealed
  | FakeAmbiguousInitialization
  | FakeCorruptBundle
  | FakeStoreUnavailable
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data FakeStoreState
  = FakeStoreHealthy
  | FakeStoreCorruptBundle
  | FakeStoreOffline
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data FakeCrashStage
  = FakeCrashBeforeEffect
  | FakeCrashAfterEffect
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data FakeCrashPoint = FakeCrashPoint
  { fakeCrashRoute :: !BrokerRoute
  , fakeCrashStage :: !FakeCrashStage
  }
  deriving stock (Eq, Ord, Show)

data FakeBrokerFailure
  = FakeVaultMustBeInitialized
  | FakeVaultMustBeUnsealed
  | FakeInitializationAmbiguous
  | FakeCustodyCorrupt
  | FakeBootstrapStoreUnavailable
  | FakeChildCustodyUnavailable
  | FakeChildRecoveryAlreadyConsumed
  | FakeMalformedRequestMetadata
  | FakeWrongRouteMetadata
  | FakeStorageGenerationMismatch
  | FakeActionBindingMismatch
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data FakeBrokerAction
  = FakeActionStarted !BrokerRoute !FakeBrokerState
  | FakeActionTransitionCommitted !BrokerRoute !FakeBrokerState !FakeBrokerState
  | FakeActionCompleted !BrokerRoute !FakeBrokerState
  | FakeActionRefused !BrokerRoute !FakeBrokerState !FakeBrokerFailure
  | FakeActionCrashInjected !FakeCrashPoint
  deriving stock (Eq, Show)

newtype FakeBrokerInjectedCrash = FakeBrokerInjectedCrash FakeCrashPoint
  deriving stock (Eq, Show)

instance Exception FakeBrokerInjectedCrash

data FakeBrokerSnapshot = FakeBrokerSnapshot
  { fakeSnapshotState :: !FakeBrokerState
  , fakeSnapshotStoreState :: !FakeStoreState
  , fakeSnapshotRootInit :: !RootInitState
  , fakeSnapshotVaultSeal :: !VaultSealState
  , fakeSnapshotBaselineApplied :: !Bool
  , fakeSnapshotChildCustody :: !(Maybe ChildCustodyState)
  , fakeSnapshotChildRecovery :: !(Maybe ChildRecoveryState)
  , fakeSnapshotActions :: ![FakeBrokerAction]
  }
  deriving stock (Eq, Show)

newtype FakeBroker = FakeBroker (TVar FakeBrokerRecord)

data FakeBrokerRecord = FakeBrokerRecord
  { recordStoreState :: !FakeStoreState
  , recordRootInit :: !RootInitState
  , recordVaultSeal :: !VaultSealState
  , recordBaselineApplied :: !Bool
  , recordChildCustody :: !(Maybe ChildCustodyState)
  , recordChildRecovery :: !(Maybe ChildRecoveryState)
  , recordActionsNewestFirst :: ![FakeBrokerAction]
  , recordCrashPoints :: !(Set FakeCrashPoint)
  , recordFenceGenerationFloor :: !Natural
  , recordHeldFence :: !(Maybe BootstrapSessionFence)
  , recordLastReplyStatus :: !(Maybe BrokerReplyStatus)
  }

newFakeBroker :: IO FakeBroker
newFakeBroker = newFakeBrokerInState FakeEmpty

newFakeBrokerInState :: FakeBrokerState -> IO FakeBroker
newFakeBrokerInState initialState =
  FakeBroker <$> newTVarIO (recordForState initialState)

setFakeBrokerState :: FakeBroker -> FakeBrokerState -> IO ()
setFakeBrokerState (FakeBroker stateVariable) state = atomically $ do
  current <- readTVar stateVariable
  let replacement = recordForState state
  writeTVar
    stateVariable
    replacement
      { recordActionsNewestFirst = recordActionsNewestFirst current
      , recordCrashPoints = recordCrashPoints current
      }

readFakeBrokerSnapshot :: FakeBroker -> IO FakeBrokerSnapshot
readFakeBrokerSnapshot (FakeBroker stateVariable) = do
  record <- readTVarIO stateVariable
  pure (snapshotRecord record)

readFakeBrokerActions :: FakeBroker -> IO [FakeBrokerAction]
readFakeBrokerActions broker = fakeSnapshotActions <$> readFakeBrokerSnapshot broker

clearFakeBrokerActions :: FakeBroker -> IO ()
clearFakeBrokerActions (FakeBroker stateVariable) =
  atomically
    ( modifyTVar'
        stateVariable
        (\record -> record {recordActionsNewestFirst = []})
    )

injectFakeCrashOnce :: FakeBroker -> FakeCrashPoint -> IO ()
injectFakeCrashOnce (FakeBroker stateVariable) crashPoint =
  atomically
    ( modifyTVar'
        stateVariable
        ( \record ->
            record
              { recordCrashPoints =
                  Set.insert crashPoint (recordCrashPoints record)
              }
        )
    )

clearFakeCrashes :: FakeBroker -> IO ()
clearFakeCrashes (FakeBroker stateVariable) =
  atomically
    ( modifyTVar'
        stateVariable
        (\record -> record {recordCrashPoints = Set.empty})
    )

fakeBrokerTransportCredentialHeaderValue :: ByteString
fakeBrokerTransportCredentialHeaderValue = "fake-broker-attestation-v1"

-- | Build the exact secret-free action binding the deterministic fake expects
-- for a route in its current storage generation.  This is the composition
-- seam used by real target-client loopback tests.
fakeBrokerActionRequestFor
  :: FakeBroker -> BrokerRoute -> IO BrokerActionRequest
fakeBrokerActionRequestFor (FakeBroker stateVariable) route = do
  record <- readTVarIO stateVariable
  pure
    ( mkBrokerActionRequest
        (vaultSealStorageGeneration (recordVaultSeal record))
        (fakeBrokerActionDigest route)
    )

fakeBrokerRequestBodyFor :: FakeBroker -> BrokerRoute -> IO ByteString
fakeBrokerRequestBodyFor broker route = do
  action <- fakeBrokerActionRequestFor broker route
  pure $ case brokerRouteBodyRequirement route of
    BrokerBodyForbidden -> ""
    BrokerBodyRequired ->
      encodeBrokerControllerRequest (fakeControllerRequest route action)

fakeControllerRequest
  :: BrokerRoute -> BrokerActionRequest -> BrokerControllerRequest
fakeControllerRequest route action = case route of
  BrokerVaultPkiIssueTestCertificate ->
    mkBrokerPkiControllerRequest action fakePkiIssueRequest
  _ ->
    case mkBrokerControllerRequest route action of
      Right request -> request
      Left protocolError ->
        error
          ( "fake attempted to build a body for an incompatible route: "
              ++ show protocolError
          )

fakePkiIssueRequest :: PkiIssueRequest
fakePkiIssueRequest =
  case mkPkiIssueRequest "bootstrap-broker-fake.invalid" 300 of
    Right request -> request
    Left err -> error ("invalid compiled fake PKI request: " ++ err)

fakeBrokerActionDigest :: BrokerRoute -> ArtifactDigest
fakeBrokerActionDigest route =
  case mkArtifactDigest
    ( renderRequestDigest
        ( requestDigestForBytes
            (TextEncoding.encodeUtf8 ("fake-broker-v1:" <> brokerRouteOperationName route))
        )
    ) of
    Right digest -> digest
    Left err -> error ("invalid deterministic fake action digest: " ++ show err)

-- | Compatibility projection retained for existing raw-wire fixtures.  The
-- value is now the canonical validated action digest, not an alternate fake
-- schema field.
fakeBrokerActionBinding :: BrokerRoute -> Text.Text
fakeBrokerActionBinding = renderArtifactDigest . fakeBrokerActionDigest

-- | Test-only authenticator.  It proves that identity is derived by a closed
-- authentication port rather than trusted from the service-identity claim.
fakeBrokerAuthenticator :: BrokerAuthenticator
fakeBrokerAuthenticator = BrokerAuthenticator $ \request ->
  if credentialMatches request
    then pure (Right (authenticationClaimedIdentity request))
    else pure (Left BrokerAuthenticationRejected)
 where
  credentialMatches request =
    withBrokerTransportCredential
      (authenticationCredential request)
      (== fakeBrokerTransportCredentialHeaderValue)

fakeBrokerInterpreter :: FakeBroker -> BrokerInterpreter
fakeBrokerInterpreter broker = case fakeBrokerEngine broker of
  Left _ -> BrokerInterpreter (\_ _ _ -> pure (failureReply FakeCustodyCorrupt))
  Right engine ->
    BrokerInterpreter $ \context route body -> do
      -- Force the authentication projection so an RPC fixture cannot silently
      -- bypass construction of its typed interpreter context.  Probe contexts
      -- remain intentionally unauthenticated.
      began <-
        brokerRequestAuthentication context `seq`
          atomically (beginFakeRoute broker route body)
      decision <- case began of
        FakeBeginDecision immediate -> pure immediate
        FakeBeginContinue beforeState -> do
          outcome <- runEngineBrokerRequest engine context route body
          atomically (finishFakeRoute broker route beforeState outcome)
      case decision of
        FakeReturn reply -> pure reply
        FakeThrow crashPoint -> throwIO (FakeBrokerInjectedCrash crashPoint)

data FakeDecision
  = FakeReturn !BrokerReply
  | FakeThrow !FakeCrashPoint

data FakeBegin
  = FakeBeginDecision !FakeDecision
  | FakeBeginContinue !FakeBrokerState

beginFakeRoute
  :: FakeBroker -> BrokerRoute -> Maybe BrokerRequestBody -> STM FakeBegin
beginFakeRoute (FakeBroker stateVariable) route body = do
  beforeRecord <- readTVar stateVariable
  let beforeState = projectRecordState beforeRecord
      beforePoint = FakeCrashPoint route FakeCrashBeforeEffect
      startedRecord = appendAction (FakeActionStarted route beforeState) beforeRecord
  if Set.member beforePoint (recordCrashPoints beforeRecord)
    then do
      let crashedRecord =
            appendAction
              (FakeActionCrashInjected beforePoint)
              startedRecord
                { recordCrashPoints =
                    Set.delete beforePoint (recordCrashPoints startedRecord)
                }
      writeTVar stateVariable crashedRecord
      pure (FakeBeginDecision (FakeThrow beforePoint))
    else case validateFakeRequestMetadata startedRecord route body of
      Left failure -> do
        let refused = appendAction (FakeActionRefused route beforeState failure) startedRecord
        writeTVar stateVariable refused
        pure (FakeBeginDecision (FakeReturn (failureReply failure)))
      Right () -> do
        writeTVar stateVariable startedRecord {recordLastReplyStatus = Nothing}
        pure (FakeBeginContinue beforeState)

finishFakeRoute
  :: FakeBroker
  -> BrokerRoute
  -> FakeBrokerState
  -> Either BrokerEngineError response
  -> STM FakeDecision
finishFakeRoute (FakeBroker stateVariable) route beforeState outcome = do
  record <- readTVar stateVariable
  case outcome of
    Left engineFailure -> do
      let failure = fakeFailureForEngine engineFailure
          refused =
            appendAction
              (FakeActionRefused route beforeState failure)
              record
                { recordHeldFence = Nothing
                , recordLastReplyStatus = Nothing
                }
      writeTVar stateVariable refused
      pure (FakeReturn (failureReply failure))
    Right _ -> do
      let afterState = projectRecordState record
          afterPoint = FakeCrashPoint route FakeCrashAfterEffect
          replyStatus = fromMaybe BrokerReplyOk (recordLastReplyStatus record)
          committed =
            appendAction
              (FakeActionTransitionCommitted route beforeState afterState)
              record {recordLastReplyStatus = Nothing}
      if Set.member afterPoint (recordCrashPoints committed)
        then do
          let crashedRecord =
                appendAction
                  (FakeActionCrashInjected afterPoint)
                  committed
                    { recordCrashPoints =
                        Set.delete afterPoint (recordCrashPoints committed)
                    }
          writeTVar stateVariable crashedRecord
          pure (FakeThrow afterPoint)
        else do
          let completed = appendAction (FakeActionCompleted route afterState) committed
          writeTVar stateVariable completed
          pure (FakeReturn (stateReply replyStatus afterState))

fakeFailureForEngine :: BrokerEngineError -> FakeBrokerFailure
fakeFailureForEngine engineFailure = case engineFailure of
  EnginePhysicalCallRefused (EngineBoundaryRefused detail) ->
    fakeFailureForName detail
  EngineProgramEvidenceRefused (EngineBoundaryRefused detail) ->
    fakeFailureForName detail
  EngineStoreRefused _ -> FakeBootstrapStoreUnavailable
  EngineInitializationAmbiguous _ -> FakeInitializationAmbiguous
  EngineEvidenceGenerationMismatch _ -> FakeStorageGenerationMismatch
  EngineFenceBindingMismatch -> FakeActionBindingMismatch
  EngineMutationReceiptMismatch -> FakeActionBindingMismatch
  EngineProtocolRefused _ -> FakeMalformedRequestMetadata
  _ -> FakeCustodyCorrupt

fakeFailureForName :: Text.Text -> FakeBrokerFailure
fakeFailureForName detail =
  case filter ((== Text.unpack detail) . fakeFailureName) [minBound .. maxBound] of
    failure : _ -> failure
    [] -> FakeCustodyCorrupt

fakeBrokerEngine :: FakeBroker -> Either String (BrokerEngine IO)
fakeBrokerEngine broker =
  mkBrokerEngine fakeCapabilityRefs 64 (fakeEngineBoundary broker)

fakeCapabilityRefs :: BrokerCapabilityRefs
fakeCapabilityRefs =
  mkBrokerCapabilityRefs
    (fakeCoordinate "observe")
    (fakeCoordinate "mutate")
    (fakeCoordinate "baseline")
    (fakeCoordinate "pki")

fakeCoordinate :: Text.Text -> CapabilityCoordinate
fakeCoordinate logical =
  mkCoordinate
    (must (mkServiceIdentity "bootstrap-broker-fake"))
    (must (mkAuthorityScope "fake/bootstrap"))
    (must (mkCapabilityEndpoint "127.0.0.1:30444"))
    (must (mkLogicalName logical))
    (must (mkCredentialGeneration 1))

fakeEngineBoundary :: FakeBroker -> BrokerEngineBoundary IO
fakeEngineBoundary broker =
  BrokerEngineBoundary
    { engineEvidenceBoundary = fakeEvidenceBoundary broker
    , engineResolveRootInitCryptoParameters =
        \_ -> pure (Left (EngineBoundaryRefused "fake uses its closed in-memory boundary"))
    , engineAdmitCapability = \_ _ -> pure (Right ())
    , engineBeginCapabilityExecution = \_ _ -> pure (Right ())
    , engineAcquireMutationFence =
        \_ _ action requestDigest _ ->
          atomically (acquireFakeFence broker action requestDigest)
    , engineObserveFenceUse = observeFakeFence broker
    , engineReleaseMutationFence = \_ fence -> atomically (releaseFakeFence broker fence)
    , engineRunPhysicalCall =
        \_ -> pure (Left (EngineBoundaryRefused "fake uses its closed in-memory boundary"))
    , engineRunLocalCall =
        \_ -> pure (Left (EngineBoundaryRefused "fake uses its closed in-memory boundary"))
    , engineSecretWorkerBoundary = Nothing
    , enginePgpBoundary = Nothing
    , engineInMemoryBoundary =
        Just (BrokerInMemoryBoundary (runFakeInMemoryCall broker))
    , engineStoreBoundary = fakeEngineStoreBoundary broker
    }

fakeEvidenceBoundary :: FakeBroker -> BrokerProgramEvidenceBoundary IO
fakeEvidenceBoundary broker =
  BrokerProgramEvidenceBoundary
    { resolvePristineStorageProof = \_ ->
        Right . fakePristineForRecord <$> readFakeRecord broker
    , resolveUnsealRecoveryCustody = \_ ->
        fakeRecoveryForRecord <$> readFakeRecord broker
    , resolveUnlockRotationCustody = \_ ->
        fakeRecoveryForRecord <$> readFakeRecord broker
    , resolveBaselineCustodyAndSession = \_ -> do
        recovery <- fakeRecoveryForRecord <$> readFakeRecord broker
        pure (fmap (,fakeRootSessionId) recovery)
    , resolveAmbiguousResetEvidence = \_ -> do
        record <- readFakeRecord broker
        pure $ case rootInitStatePhase (recordRootInit record) of
          RootInitializationAmbiguous ambiguity -> Right (ambiguity, fakeRootResetProof)
          _ -> Left (fakeBoundaryFailure FakeInitializationAmbiguous)
    , resolveChildCustodyBinding = \_ ->
        Right . fakeChildBindingForRecord <$> readFakeRecord broker
    , resolveChildRecoveryDeliveryEvidence = \_ -> do
        record <- readFakeRecord broker
        pure
          ( Right
              ( fakeChildBindingForRecord record
              , fakeDeliveryNonce
              , fakeChildAttestation
              )
          )
    , resolveChildRecoveryObservation = \_ -> do
        record <- readFakeRecord broker
        pure (Right (fakeChildBindingForRecord record, fakeDeliveryNonce))
    }

fakeEngineStoreBoundary :: FakeBroker -> BootstrapStoreBoundary IO
fakeEngineStoreBoundary broker =
  unavailableBootstrapStoreBoundary
    { observeVaultStorageGeneration =
        Right . rootInitStateBinding . recordRootInit <$> readFakeRecord broker
    }

readFakeRecord :: FakeBroker -> IO FakeBrokerRecord
readFakeRecord (FakeBroker stateVariable) = readTVarIO stateVariable

acquireFakeFence
  :: FakeBroker
  -> BrokerActionRequest
  -> RequestDigest
  -> STM (Either EngineBoundaryError BootstrapSessionFence)
acquireFakeFence (FakeBroker stateVariable) action requestDigest = do
  record <- readTVar stateVariable
  case recordHeldFence record of
    Just _ -> pure (Left (EngineBoundaryRefused "fake mutation fence is already held"))
    Nothing ->
      case reloadBootstrapSessionFence
        (recordFenceGenerationFloor record + 1)
        (must (mkOwnerNonce "fake-broker-engine"))
        (brokerActionDigest action)
        requestDigest
        (brokerActionStorageGeneration action)
        1_000_000_000_000 of
        Left err -> pure (Left (EngineBoundaryRefused (Text.pack (show err))))
        Right fence -> do
          writeTVar
            stateVariable
            record
              { recordFenceGenerationFloor = recordFenceGenerationFloor record + 1
              , recordHeldFence = Just fence
              }
          pure (Right fence)

observeFakeFence
  :: FakeBroker
  -> BootstrapSessionFence
  -> IO (Either EngineBoundaryError EngineFenceUseObservation)
observeFakeFence broker fence = do
  record <- readFakeRecord broker
  pure $ case recordHeldFence record of
    Just held
      | held == fence ->
          Right
            EngineFenceUseObservation
              { engineFenceMonotonicNow = monotonicInstantFromMicros 0
              , engineFenceAuthorityClock =
                  AuthorityTimeTrusted
                    (authorityTimeFromMicros 1)
                    (clockUncertaintyFromMicros 0)
              , engineFenceStoreObservation = BootstrapFenceStoreHeld fence
              , engineFenceLeaseObservation =
                  BootstrapLeaseObserved
                    (bootstrapLeaseBindingForFence fence)
                    ( deadlineAtOffset
                        (monotonicInstantFromMicros 0)
                        (RemainingDuration 1_000_000_000_000)
                    )
                    "fake-resource-version"
              }
    _ -> Left (EngineBoundaryRefused "fake mutation fence is not current")

releaseFakeFence
  :: FakeBroker
  -> BootstrapSessionFence
  -> STM (Either EngineBoundaryError BootstrapFenceStoreObservation)
releaseFakeFence (FakeBroker stateVariable) fence = do
  record <- readTVar stateVariable
  case recordHeldFence record of
    Just held
      | held == fence -> do
          let floorValue =
                bootstrapFenceGenerationValue (bootstrapFenceGeneration fence)
          writeTVar stateVariable record {recordHeldFence = Nothing}
          pure (Right (BootstrapFenceStoreVacant floorValue))
    _ -> pure (Left (EngineBoundaryRefused "fake mutation fence release mismatched"))

runFakeInMemoryCall
  :: FakeBroker
  -> BrokerInMemoryCall operation result
  -> IO (Either EngineBoundaryError result)
runFakeInMemoryCall (FakeBroker stateVariable) call = atomically $ do
  record <- readTVar stateVariable
  case applyFakeRoute (fakeInMemoryRoute call) record of
    Left failure -> do
      writeTVar stateVariable record {recordHeldFence = Nothing}
      pure (Left (fakeBoundaryFailure failure))
    Right (afterRecord, replyStatus) ->
      case fakeInMemoryResult call afterRecord replyStatus of
        Left failure -> pure (Left failure)
        Right result -> do
          writeTVar
            stateVariable
            afterRecord {recordLastReplyStatus = Just replyStatus}
          pure (Right result)

fakeInMemoryRoute :: BrokerInMemoryCall operation result -> BrokerRoute
fakeInMemoryRoute call = case call of
  InMemoryHealth _ -> BrokerHealth
  InMemoryReadiness _ -> BrokerReadiness
  InMemoryVaultStatus _ -> BrokerVaultStatus
  InMemoryVaultInitialize {} -> BrokerVaultInitialize
  InMemoryVaultUnseal {} -> BrokerVaultUnseal
  InMemoryVaultSeal {} -> BrokerVaultSeal
  InMemoryVaultRotateUnlockBundle {} -> BrokerVaultRotateUnlockBundle
  InMemoryVaultRotateTransitKey {} -> BrokerVaultRotateTransitKey
  InMemoryVaultBaselineReconcile {} -> BrokerVaultBaselineReconcile
  InMemoryVaultPkiStatus _ -> BrokerVaultPkiStatus
  InMemoryVaultPkiIssueTestCertificate {} -> BrokerVaultPkiIssueTestCertificate
  InMemoryVaultResetAmbiguousInitialization {} ->
    BrokerVaultResetAmbiguousInitialization
  InMemoryChildCustodyCommit {} -> BrokerChildCustodyCommit
  InMemoryChildRecoveryDeliver {} -> BrokerChildRecoveryDeliver
  InMemoryChildRecoveryObserve {} -> BrokerChildRecoveryObserve

fakeInMemoryResult
  :: BrokerInMemoryCall operation result
  -> FakeBrokerRecord
  -> BrokerReplyStatus
  -> Either EngineBoundaryError result
fakeInMemoryResult call record replyStatus = case call of
  InMemoryHealth _ -> Right True
  InMemoryReadiness _ -> Right True
  InMemoryVaultStatus _ -> Right (fakeBootstrapStatus record)
  InMemoryVaultInitialize {} -> fakeRecoveryForRecord record
  InMemoryVaultUnseal _ permit _ ->
    Right (fakeMutationReceipt (vaultEffectPermitActionDigest permit) replyStatus)
  InMemoryVaultSeal _ permit ->
    Right (fakeMutationReceipt (vaultEffectPermitActionDigest permit) replyStatus)
  InMemoryVaultRotateUnlockBundle _ permit _ ->
    Right (fakeMutationReceipt (vaultEffectPermitActionDigest permit) replyStatus)
  InMemoryVaultRotateTransitKey _ permit ->
    Right (fakeMutationReceipt (vaultEffectPermitActionDigest permit) replyStatus)
  InMemoryVaultBaselineReconcile _ _ sessionId custody ->
    mapLeftBoundary
      ( mkBaselineReadBackReceipt
          sessionId
          (rootInitStorageGeneration (recoveryCustodyBinding custody))
          requiredRootBaselineTargets
          (fakeDigest 'd')
      )
  InMemoryVaultPkiStatus _ -> Right VaultPkiBaselineReady
  InMemoryVaultPkiIssueTestCertificate _ permit _ ->
    Right (fakeMutationReceipt (vaultEffectPermitActionDigest permit) replyStatus)
  InMemoryVaultResetAmbiguousInitialization _ permit _ _ ->
    Right (fakeMutationReceipt (storeMutationPermitActionDigest permit) replyStatus)
  InMemoryChildCustodyCommit {} -> fakeParentAcknowledgement record
  InMemoryChildRecoveryDeliver {} -> fakeCurrentDelivery record
  InMemoryChildRecoveryObserve {} -> Just <$> fakeCurrentDelivery record

fakeMutationReceipt
  :: ArtifactDigest -> BrokerReplyStatus -> BootstrapMutationReceipt
fakeMutationReceipt digest replyStatus =
  BootstrapMutationReceipt
    { bootstrapMutationDigest = digest
    , bootstrapMutationChanged = replyStatus == BrokerReplyAccepted
    }

fakeBootstrapStatus :: FakeBrokerRecord -> BootstrapStatus
fakeBootstrapStatus record =
  BootstrapStatus
    { bootstrapStatusInitialized = rootInitIsComplete (recordRootInit record)
    , bootstrapStatusSealed = not (vaultSealIsUnsealed (recordVaultSeal record))
    , bootstrapStatusRecoveryCustodyDurable = rootInitIsComplete (recordRootInit record)
    , bootstrapStatusInitializationAmbiguous = rootInitIsAmbiguous (recordRootInit record)
    , bootstrapStatusRootSessionActive = False
    , bootstrapStatusHandoffObserved = False
    }

fakePristineForRecord :: FakeBrokerRecord -> PristineStorageProof
fakePristineForRecord record = case rootInitStatePhase (recordRootInit record) of
  RootInitPristine proof -> proof
  _
    | rootInitStateBinding (recordRootInit record)
        == pristineStorageBinding fakeReplacementRootProof ->
        fakeReplacementRootProof
    | otherwise -> fakeInitialRootProof

fakeRecoveryForRecord
  :: FakeBrokerRecord -> Either EngineBoundaryError RecoveryCustodyReceipt
fakeRecoveryForRecord record =
  recoveryForState (recordRootInit record)
 where
  recoveryForState state = case rootInitStatePhase state of
    RootRecoveryCustodyDurable _ receipt -> Right receipt
    _ ->
      case completeRootCustody (newRootInitState (fakePristineForRecord record)) of
        Left detail -> Left (EngineBoundaryRefused (Text.pack detail))
        Right completed -> case rootInitStatePhase completed of
          RootRecoveryCustodyDurable _ receipt -> Right receipt
          _ -> Left (EngineBoundaryRefused "fake recovery custody is incomplete")

fakeChildBindingForRecord :: FakeBrokerRecord -> ChildCustodyBinding
fakeChildBindingForRecord record = case recordChildCustody record of
  Just custody -> childCustodyStateBinding custody
  Nothing -> fakeChildBinding (vaultSealStorageGeneration (recordVaultSeal record))

fakeParentAcknowledgement
  :: FakeBrokerRecord -> Either EngineBoundaryError ParentCustodyAcknowledgement
fakeParentAcknowledgement record = case recordChildCustody record of
  Just custody -> case childCustodyStatePhase custody of
    ChildRecoveryCustodyDurable acknowledgement -> Right acknowledgement
    _ -> Left (EngineBoundaryRefused "fake child custody is incomplete")
  Nothing -> Left (fakeBoundaryFailure FakeChildCustodyUnavailable)

fakeCurrentDelivery
  :: FakeBrokerRecord -> Either EngineBoundaryError ChildRecoveryDelivery
fakeCurrentDelivery record = case recordChildRecovery record of
  Just recovery -> case childRecoveryStatePhase recovery of
    ChildRecoveryDeliveryPrepared delivery -> Right delivery
    ChildRecoveryDeliveryConsumed delivery -> Right delivery
    _ -> Left (fakeBoundaryFailure FakeChildRecoveryAlreadyConsumed)
  Nothing -> Left (fakeBoundaryFailure FakeChildCustodyUnavailable)

fakeBoundaryFailure :: FakeBrokerFailure -> EngineBoundaryError
fakeBoundaryFailure = EngineBoundaryRefused . Text.pack . fakeFailureName

mapLeftBoundary :: (Show error) => Either error value -> Either EngineBoundaryError value
mapLeftBoundary = either (Left . EngineBoundaryRefused . Text.pack . show) Right

fakeRootSessionId :: RootSessionId
fakeRootSessionId = must (mkRootSessionId "fake-root-session")

validateFakeRequestMetadata
  :: FakeBrokerRecord
  -> BrokerRoute
  -> Maybe BrokerRequestBody
  -> Either FakeBrokerFailure ()
validateFakeRequestMetadata record route body =
  case brokerRouteBodyRequirement route of
    BrokerBodyForbidden -> case body of
      Nothing -> Right ()
      Just _ -> Left FakeMalformedRequestMetadata
    BrokerBodyRequired -> do
      requestBody <- maybe (Left FakeMalformedRequestMetadata) Right body
      metadata <-
        mapFakeProtocolError
          ( withBrokerRequestBody
              requestBody
              (decodeBrokerControllerRequest route)
          )
      let action = brokerControllerRequestAction metadata
      if brokerActionStorageGeneration action == expectedGeneration
        then Right ()
        else Left FakeStorageGenerationMismatch
      if brokerActionDigest action == fakeBrokerActionDigest route
        then Right ()
        else Left FakeActionBindingMismatch
 where
  expectedGeneration =
    vaultSealStorageGeneration (recordVaultSeal record)

mapFakeProtocolError
  :: Either BrokerProtocolError value -> Either FakeBrokerFailure value
mapFakeProtocolError result = case result of
  Right value -> Right value
  Left BrokerProtocolWrongOperation -> Left FakeWrongRouteMetadata
  Left _ -> Left FakeMalformedRequestMetadata

applyFakeRoute
  :: BrokerRoute
  -> FakeBrokerRecord
  -> Either FakeBrokerFailure (FakeBrokerRecord, BrokerReplyStatus)
applyFakeRoute route record
  | route == BrokerHealth = succeeded BrokerReplyOk record
  | recordStoreState record == FakeStoreOffline =
      Left FakeBootstrapStoreUnavailable
  | recordStoreState record == FakeStoreCorruptBundle =
      case route of
        BrokerVaultStatus -> succeeded BrokerReplyOk record
        _ -> Left FakeCustodyCorrupt
  | otherwise = applyHealthyRoute route record

applyHealthyRoute
  :: BrokerRoute
  -> FakeBrokerRecord
  -> Either FakeBrokerFailure (FakeBrokerRecord, BrokerReplyStatus)
applyHealthyRoute route record = case route of
  BrokerHealth -> succeeded BrokerReplyOk record
  BrokerReadiness
    | rootInitIsAmbiguous (recordRootInit record) -> Left FakeInitializationAmbiguous
    | otherwise -> succeeded BrokerReplyOk record
  BrokerVaultStatus -> succeeded BrokerReplyOk record
  BrokerVaultInitialize -> initializeFakeVault record
  BrokerVaultUnseal -> unsealFakeVault record
  BrokerVaultSeal -> sealFakeVault record
  BrokerVaultRotateUnlockBundle -> requireInitialized record
  BrokerVaultRotateTransitKey -> requireUnsealed record
  BrokerVaultBaselineReconcile -> do
    (ready, _) <- requireUnsealed record
    succeeded BrokerReplyAccepted ready {recordBaselineApplied = True}
  BrokerVaultPkiStatus -> requireUnsealed record
  BrokerVaultPkiIssueTestCertificate -> requireUnsealed record
  BrokerVaultResetAmbiguousInitialization -> resetAmbiguousFakeVault record
  BrokerChildCustodyCommit -> commitFakeChildCustody record
  BrokerChildRecoveryDeliver -> deliverFakeChildRecovery record
  BrokerChildRecoveryObserve -> observeFakeChildRecovery record

initializeFakeVault
  :: FakeBrokerRecord
  -> Either FakeBrokerFailure (FakeBrokerRecord, BrokerReplyStatus)
initializeFakeVault record
  | rootInitIsAmbiguous rootState = Left FakeInitializationAmbiguous
  | rootInitIsComplete rootState = succeeded BrokerReplyOk record
  | otherwise = do
      completedRoot <- mapFoldError (completeRootCustody rootState)
      sealed <-
        mapSealError
          ( observeVaultSeal
              (recordVaultSeal record)
              (ObserveVaultInitializedSealed generation)
          )
      succeeded
        BrokerReplyAccepted
        record
          { recordRootInit = completedRoot
          , recordVaultSeal = sealed
          }
 where
  rootState = recordRootInit record
  generation = vaultSealStorageGeneration (recordVaultSeal record)

unsealFakeVault
  :: FakeBrokerRecord
  -> Either FakeBrokerFailure (FakeBrokerRecord, BrokerReplyStatus)
unsealFakeVault record = do
  (initialized, _) <- requireInitialized record
  let generation = vaultSealStorageGeneration (recordVaultSeal initialized)
  unsealed <-
    mapSealError
      ( observeVaultSeal
          (recordVaultSeal initialized)
          (ObserveVaultInitializedUnsealed generation)
      )
  succeeded BrokerReplyAccepted initialized {recordVaultSeal = unsealed}

sealFakeVault
  :: FakeBrokerRecord
  -> Either FakeBrokerFailure (FakeBrokerRecord, BrokerReplyStatus)
sealFakeVault record = do
  (initialized, _) <- requireInitialized record
  let generation = vaultSealStorageGeneration (recordVaultSeal initialized)
  sealed <-
    mapSealError
      ( observeVaultSeal
          (recordVaultSeal initialized)
          (ObserveVaultInitializedSealed generation)
      )
  succeeded BrokerReplyAccepted initialized {recordVaultSeal = sealed}

resetAmbiguousFakeVault
  :: FakeBrokerRecord
  -> Either FakeBrokerFailure (FakeBrokerRecord, BrokerReplyStatus)
resetAmbiguousFakeVault record
  | not (rootInitIsAmbiguous (recordRootInit record)) = Left FakeInitializationAmbiguous
  | otherwise = do
      resetRoot <-
        mapFoldError
          ( applyRootInitCommand
              (recordRootInit record)
              (ResetAmbiguousRootInitialization fakeRootResetProof)
          )
      let replacementGeneration =
            rootInitStorageGeneration (rootInitStateBinding resetRoot)
          replacementSeal =
            must
              ( observeVaultSeal
                  (newVaultSealState replacementGeneration)
                  (ObserveVaultStorageEmpty replacementGeneration)
              )
      succeeded
        BrokerReplyAccepted
        record
          { recordRootInit = resetRoot
          , recordVaultSeal = replacementSeal
          , recordBaselineApplied = False
          }

requireInitialized
  :: FakeBrokerRecord
  -> Either FakeBrokerFailure (FakeBrokerRecord, BrokerReplyStatus)
requireInitialized record
  | rootInitIsAmbiguous (recordRootInit record) = Left FakeInitializationAmbiguous
  | rootInitIsComplete (recordRootInit record) = succeeded BrokerReplyOk record
  | otherwise = Left FakeVaultMustBeInitialized

requireUnsealed
  :: FakeBrokerRecord
  -> Either FakeBrokerFailure (FakeBrokerRecord, BrokerReplyStatus)
requireUnsealed record = do
  (initialized, _) <- requireInitialized record
  if vaultSealIsUnsealed (recordVaultSeal initialized)
    then succeeded BrokerReplyOk initialized
    else Left FakeVaultMustBeUnsealed

commitFakeChildCustody
  :: FakeBrokerRecord
  -> Either FakeBrokerFailure (FakeBrokerRecord, BrokerReplyStatus)
commitFakeChildCustody record = do
  (initialized, _) <- requireInitialized record
  case recordChildCustody initialized of
    Just custody
      | childCustodyIsComplete custody -> succeeded BrokerReplyOk initialized
    _ -> do
      custody <-
        mapFoldError
          ( completeChildCustody
              (vaultSealStorageGeneration (recordVaultSeal initialized))
          )
      succeeded
        BrokerReplyAccepted
        initialized {recordChildCustody = Just custody}

deliverFakeChildRecovery
  :: FakeBrokerRecord
  -> Either FakeBrokerFailure (FakeBrokerRecord, BrokerReplyStatus)
deliverFakeChildRecovery record = case recordChildCustody record of
  Nothing -> Left FakeChildCustodyUnavailable
  Just custody
    | not (childCustodyIsComplete custody) -> Left FakeChildCustodyUnavailable
    | otherwise -> case recordChildRecovery record of
        Just recovery -> case childRecoveryStatePhase recovery of
          ChildRecoveryAvailable _ -> prepareAndConsume recovery
          _ -> Left FakeChildRecoveryAlreadyConsumed
        Nothing ->
          prepareAndConsume
            (newChildRecoveryState (childCustodyBindingForState custody))
 where
  prepareAndConsume recovery = do
    let delivery = fakeChildRecoveryDelivery (childRecoveryStateBinding recovery)
    prepared <-
      mapFoldError
        (applyChildRecoveryCommand recovery (PrepareChildRecoveryDelivery delivery))
    armed <-
      mapFoldError
        (applyChildRecoveryCommand prepared ArmChildRecoveryDeliveryConsume)
    started <-
      mapFoldError
        (applyChildRecoveryCommand armed RecordChildRecoveryDeliveryConsumeStarted)
    let observation =
          mkChildRecoveryConsumptionObservation
            delivery
            ChildRecoveryConsumptionApplied
            (fakeDigest '9')
    consumed <-
      mapFoldError
        ( applyChildRecoveryCommand
            started
            (ConfirmChildRecoveryDeliveryConsumed observation)
        )
    succeeded
      BrokerReplyAccepted
      record {recordChildRecovery = Just consumed}

observeFakeChildRecovery
  :: FakeBrokerRecord
  -> Either FakeBrokerFailure (FakeBrokerRecord, BrokerReplyStatus)
observeFakeChildRecovery record = case recordChildRecovery record of
  Nothing -> Left FakeChildCustodyUnavailable
  Just _ -> succeeded BrokerReplyOk record

childCustodyBindingForState :: ChildCustodyState -> ChildCustodyBinding
childCustodyBindingForState = childCustodyStateBinding

succeeded
  :: BrokerReplyStatus
  -> FakeBrokerRecord
  -> Either FakeBrokerFailure (FakeBrokerRecord, BrokerReplyStatus)
succeeded status record = Right (record, status)

mapFoldError :: Either errorValue value -> Either FakeBrokerFailure value
mapFoldError = either (const (Left FakeCustodyCorrupt)) Right

mapSealError :: Either errorValue value -> Either FakeBrokerFailure value
mapSealError = either (const (Left FakeCustodyCorrupt)) Right

snapshotRecord :: FakeBrokerRecord -> FakeBrokerSnapshot
snapshotRecord record =
  FakeBrokerSnapshot
    { fakeSnapshotState = projectRecordState record
    , fakeSnapshotStoreState = recordStoreState record
    , fakeSnapshotRootInit = recordRootInit record
    , fakeSnapshotVaultSeal = recordVaultSeal record
    , fakeSnapshotBaselineApplied = recordBaselineApplied record
    , fakeSnapshotChildCustody = recordChildCustody record
    , fakeSnapshotChildRecovery = recordChildRecovery record
    , fakeSnapshotActions = reverse (recordActionsNewestFirst record)
    }

projectRecordState :: FakeBrokerRecord -> FakeBrokerState
projectRecordState record = case recordStoreState record of
  FakeStoreOffline -> FakeStoreUnavailable
  FakeStoreCorruptBundle -> FakeCorruptBundle
  FakeStoreHealthy
    | rootInitIsAmbiguous (recordRootInit record) -> FakeAmbiguousInitialization
    | otherwise -> case vaultSealPhase (recordVaultSeal record) of
        VaultSealUnobserved -> FakeEmpty
        VaultStorageObservedEmpty -> FakeEmpty
        VaultObservedInitializedSealed -> FakeInitializedSealed
        VaultObservedInitializedUnsealed -> FakeUnsealed

appendAction :: FakeBrokerAction -> FakeBrokerRecord -> FakeBrokerRecord
appendAction action record =
  record {recordActionsNewestFirst = action : recordActionsNewestFirst record}

recordForState :: FakeBrokerState -> FakeBrokerRecord
recordForState state =
  FakeBrokerRecord
    { recordStoreState = storeState
    , recordRootInit = rootState
    , recordVaultSeal = sealState
    , recordBaselineApplied = False
    , recordChildCustody = Nothing
    , recordChildRecovery = Nothing
    , recordActionsNewestFirst = []
    , recordCrashPoints = Set.empty
    , recordFenceGenerationFloor = 0
    , recordHeldFence = Nothing
    , recordLastReplyStatus = Nothing
    }
 where
  storeState = case state of
    FakeCorruptBundle -> FakeStoreCorruptBundle
    FakeStoreUnavailable -> FakeStoreOffline
    _ -> FakeStoreHealthy
  rootState = case state of
    FakeEmpty -> fakeInitialRootState
    FakeAmbiguousInitialization -> fakeAmbiguousRootState
    _ -> fakeCompletedRootState
  sealState = case state of
    FakeEmpty -> fakeEmptyVaultSeal
    FakeUnsealed -> fakeUnsealedVaultSeal
    _ -> fakeSealedVaultSeal

stateReply :: BrokerReplyStatus -> FakeBrokerState -> BrokerReply
stateReply status state =
  boundedReply
    status
    (BS8.pack ("{\"state\":\"" ++ fakeStateName state ++ "\"}"))

failureReply :: FakeBrokerFailure -> BrokerReply
failureReply failure =
  boundedReply
    (failureStatus failure)
    (BS8.pack ("{\"error\":\"" ++ fakeFailureName failure ++ "\"}"))

failureStatus :: FakeBrokerFailure -> BrokerReplyStatus
failureStatus failure = case failure of
  FakeBootstrapStoreUnavailable -> BrokerReplyServiceUnavailable
  FakeInitializationAmbiguous -> BrokerReplyConflict
  FakeCustodyCorrupt -> BrokerReplyConflict
  FakeVaultMustBeInitialized -> BrokerReplyConflict
  FakeVaultMustBeUnsealed -> BrokerReplyConflict
  FakeChildCustodyUnavailable -> BrokerReplyConflict
  FakeChildRecoveryAlreadyConsumed -> BrokerReplyConflict
  FakeMalformedRequestMetadata -> BrokerReplyBadRequest
  FakeWrongRouteMetadata -> BrokerReplyBadRequest
  FakeStorageGenerationMismatch -> BrokerReplyConflict
  FakeActionBindingMismatch -> BrokerReplyBadRequest

fakeStateName :: FakeBrokerState -> String
fakeStateName state = case state of
  FakeEmpty -> "empty"
  FakeInitializedSealed -> "initialized_sealed"
  FakeUnsealed -> "unsealed"
  FakeAmbiguousInitialization -> "ambiguous_initialization"
  FakeCorruptBundle -> "corrupt_bundle"
  FakeStoreUnavailable -> "store_unavailable"

fakeFailureName :: FakeBrokerFailure -> String
fakeFailureName failure = case failure of
  FakeVaultMustBeInitialized -> "vault_must_be_initialized"
  FakeVaultMustBeUnsealed -> "vault_must_be_unsealed"
  FakeInitializationAmbiguous -> "initialization_ambiguous"
  FakeCustodyCorrupt -> "custody_corrupt"
  FakeBootstrapStoreUnavailable -> "bootstrap_store_unavailable"
  FakeChildCustodyUnavailable -> "child_custody_unavailable"
  FakeChildRecoveryAlreadyConsumed -> "child_recovery_already_consumed"
  FakeMalformedRequestMetadata -> "malformed_request_metadata"
  FakeWrongRouteMetadata -> "wrong_route_metadata"
  FakeStorageGenerationMismatch -> "storage_generation_mismatch"
  FakeActionBindingMismatch -> "action_binding_mismatch"

boundedReply :: BrokerReplyStatus -> ByteString -> BrokerReply
boundedReply status body = case mkBrokerReply status body of
  Right reply -> reply
  Left _ -> error "deterministic fake reply exceeded the compiled server bound"

-- Deterministic typed artifacts ------------------------------------------------

fakeInitialRootProof :: PristineStorageProof
fakeInitialRootProof = pristineProof "fake-root-init-1" "fake-vault-generation-1" '1'

fakeReplacementRootProof :: PristineStorageProof
fakeReplacementRootProof = pristineProof "fake-root-init-2" "fake-vault-generation-2" '2'

pristineProof :: Text.Text -> Text.Text -> Char -> PristineStorageProof
pristineProof transaction generation digestCharacter =
  mkPristineStorageProof
    RootInitBinding
      { rootInitTransactionId = must (mkBootstrapTransactionId transaction)
      , rootInitStorageGeneration = must (mkVaultStorageGeneration generation)
      }
    (fakeDigest digestCharacter)

fakeInitialRootState :: RootInitState
fakeInitialRootState = newRootInitState fakeInitialRootProof

fakeCompletedRootState :: RootInitState
fakeCompletedRootState = must (completeRootCustody fakeInitialRootState)

fakeAmbiguousRootState :: RootInitState
fakeAmbiguousRootState = must $ do
  let prepared = fakePreparedEnvelope fakeInitialRootProof
  foldM
    applyRootInitCommand
    fakeInitialRootState
    [ PrepareRootInitEnvelope prepared
    , RecordPreparedInitWrite
    , ConfirmPreparedInitReadBack prepared
    , ArmRootVaultInitCall
    , RecordRootVaultInitCallStarted
    , MarkRootInitAppliedWithoutDurableResponse
    ]

fakeRootResetProof :: PristineResetProof
fakeRootResetProof = case rootInitStatePhase fakeAmbiguousRootState of
  RootInitializationAmbiguous ambiguity ->
    let binding = rootInitStateBinding fakeAmbiguousRootState
     in must
          ( mkPristineResetProof
              ambiguity
              fakeReplacementRootProof
              (mkEstablishedStateAbsence binding (fakeDigest '8'))
              (mkDurableInitResponseAbsence binding (fakeDigest '9'))
              (mkBaselineStateAbsence binding (fakeDigest 'a'))
          )
  _ -> error "deterministic ambiguous root fixture did not reach ambiguity"

completeRootCustody :: RootInitState -> Either String RootInitState
completeRootCustody initial = case rootInitStatePhase initial of
  RootInitPristine proof ->
    mapLeftShow
      ( foldM
          applyRootInitCommand
          initial
          (rootCompletionCommands proof)
      )
  _
    | rootInitIsComplete initial -> Right initial
    | otherwise -> Left "root fixture was neither pristine nor complete"

rootCompletionCommands :: PristineStorageProof -> [RootInitCommand]
rootCompletionCommands proof =
  [ PrepareRootInitEnvelope prepared
  , RecordPreparedInitWrite
  , ConfirmPreparedInitReadBack prepared
  , ArmRootVaultInitCall
  , RecordRootVaultInitCallStarted
  , CaptureEncryptedInitResponse response
  , RecordEncryptedInitResponseWrite
  , ConfirmEncryptedInitResponseReadBack response
  , PrepareFinalUnlockBundle bundle
  , RecordFinalUnlockBundlePromotion
  , ConfirmFinalUnlockBundleReadBack bundle
  , ArmPreparedInitDeletion
  , RecordPreparedInitDeletion
  , ConfirmPreparedInitAbsence
  , ArmRecoveryCustodyAcknowledgement
  , ConfirmRecoveryCustody custody
  ]
 where
  prepared = fakePreparedEnvelope proof
  response = fakeEncryptedResponse prepared
  bundle = fakeFinalBundle response
  custody = mkRecoveryCustodyReceipt bundle (fakeDigest '9')

fakePreparedEnvelope :: PristineStorageProof -> PreparedInitEnvelope
fakePreparedEnvelope proof =
  mkPreparedInitEnvelope
    proof
    (must (mkBootstrapSchemaVersion 1))
    fakeSealedRecoveryPrivateKey
    ( must
        ( mkInitRecipientCommitment
            1
            1
            ["ZmFrZS1rZXk="]
            fakeRecoveryFingerprint
            (must (mkBurnRecipientFingerprint (Text.replicate 40 "b")))
            (fakeDigest 'b')
        )
    )
    (fakeDigest '3')

fakeEncryptedResponse :: PreparedInitEnvelope -> EncryptedInitResponseReceipt
fakeEncryptedResponse prepared =
  must
    ( mkEncryptedInitResponseReceipt
        prepared
        [fakeEncryptedShare]
        fakeBurnToken
        (fakeDigest '4')
    )

fakeFinalBundle :: EncryptedInitResponseReceipt -> FinalUnlockBundle
fakeFinalBundle response =
  mkFinalUnlockBundle
    payload
    fakePasswordCiphertext
    (fakeDigest '5')
 where
  payload :: FinalUnlockBundlePayload
  payload = must (mkFinalUnlockBundlePayload response [fakeRecoveredShare])

fakeSealedRecoveryPrivateKey :: SealedRecoveryRecipientPrivateKey
fakeSealedRecoveryPrivateKey =
  must (mkSealedRecoveryRecipientPrivateKey "fake-sealed-recovery-private-key")

fakeRecoveryFingerprint :: RecoveryRecipientFingerprint
fakeRecoveryFingerprint = must (mkRecoveryRecipientFingerprint (hexText 'a'))

fakeEncryptedShare :: PgpEncryptedShare
fakeEncryptedShare = must (mkPgpEncryptedShare "fake-pgp-encrypted-share")

fakeBurnToken :: BurnTokenCiphertext
fakeBurnToken = must (mkBurnTokenCiphertext "fake-burn-token-ciphertext")

fakeRecoveredShare :: RecoveredUnsealShare
fakeRecoveredShare = must (mkRecoveredUnsealShare "fake-recovered-unseal-share")

fakePasswordCiphertext :: PasswordAeadCiphertext
fakePasswordCiphertext = must (mkPasswordAeadCiphertext "fake-password-aead-ciphertext")

fakeEmptyVaultSeal :: VaultSealState
fakeEmptyVaultSeal =
  must
    ( observeVaultSeal
        (newVaultSealState fakeInitialStorageGeneration)
        (ObserveVaultStorageEmpty fakeInitialStorageGeneration)
    )

fakeSealedVaultSeal :: VaultSealState
fakeSealedVaultSeal =
  must
    ( observeVaultSeal
        fakeEmptyVaultSeal
        (ObserveVaultInitializedSealed fakeInitialStorageGeneration)
    )

fakeUnsealedVaultSeal :: VaultSealState
fakeUnsealedVaultSeal =
  must
    ( observeVaultSeal
        fakeSealedVaultSeal
        (ObserveVaultInitializedUnsealed fakeInitialStorageGeneration)
    )

fakeInitialStorageGeneration :: VaultStorageGeneration
fakeInitialStorageGeneration =
  rootInitStorageGeneration (pristineStorageBinding fakeInitialRootProof)

completeChildCustody :: VaultStorageGeneration -> Either String ChildCustodyState
completeChildCustody generation =
  mapLeftShow
    ( foldM
        applyChildCustodyCommand
        (newChildCustodyState binding)
        [ CaptureChildEncryptedReceipt receipt
        , RecordChildLocalReceiptWrite
        , ConfirmChildLocalReceiptReadBack receipt
        , ArmChildParentGenerationCas
        , ConfirmParentCustodyReadBack acknowledgement
        , ArmChildLocalReceiptDeletion
        , RecordChildLocalReceiptDeletion
        , ConfirmChildLocalReceiptAbsence
        , ConfirmChildRecoveryCustodyDurable
        ]
    )
 where
  binding = fakeChildBinding generation
  receipt =
    must
      ( mkChildEncryptedReceipt
          binding
          [fakeEncryptedShare]
          fakeBurnToken
          (fakeDigest '6')
      )
  acknowledgement = mkParentCustodyAcknowledgement receipt (fakeDigest '7')

fakeChildBinding :: VaultStorageGeneration -> ChildCustodyBinding
fakeChildBinding generation =
  ChildCustodyBinding
    { childCustodyChildId = must (mkChildId "fake-child-1")
    , childCustodyStorageGeneration = generation
    , childCustodyGeneration = fakeCustodyGeneration
    , childCustodyTransactionId = fakeChildTransactionId
    }

fakeCustodyGeneration :: CustodyGeneration
fakeCustodyGeneration = must (mkCustodyGeneration 1)

fakeChildTransactionId :: BootstrapTransactionId
fakeChildTransactionId = must (mkBootstrapTransactionId "fake-child-custody-1")

fakeChildRecoveryDelivery :: ChildCustodyBinding -> ChildRecoveryDelivery
fakeChildRecoveryDelivery binding =
  mkChildRecoveryDelivery
    binding
    fakeDeliveryNonce
    fakeChildAttestation
    fakeEncryptedChildPayload
    (fakeDigest '8')

fakeDeliveryNonce :: DeliveryNonce
fakeDeliveryNonce = must (mkDeliveryNonce "fake-delivery-nonce-1")

fakeChildAttestation :: ChildAttestation
fakeChildAttestation = mkChildAttestation (fakeDigest 'c')

fakeEncryptedChildPayload :: EncryptedChildRecoveryPayload
fakeEncryptedChildPayload =
  must (mkEncryptedChildRecoveryPayload "fake-encrypted-child-recovery-payload")

fakeDigest :: Char -> ArtifactDigest
fakeDigest = must . mkArtifactDigest . hexText

hexText :: Char -> Text.Text
hexText character = Text.replicate 64 (Text.singleton character)

must :: (Show errorValue) => Either errorValue value -> value
must result = case result of
  Right value -> value
  Left err -> error ("invalid deterministic Bootstrap Broker fixture: " ++ show err)

mapLeftShow :: (Show errorValue) => Either errorValue value -> Either String value
mapLeftShow = either (Left . show) Right
