{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Typed execution seam for the Bootstrap Broker.
--
-- The HTTP method and exact registered path select a closed GADT constructor.
-- Body-bearing routes are decoded by 'Protocol'; bodyless routes never acquire
-- a synthetic JSON value.  Preparation resolves only route-specific durable
-- evidence and constructs the corresponding 'BrokerProgram'.  Admission and
-- execution then carry the same nominally indexed 'CapabilityRef'.
--
-- Physical effects are injected through closed GADTs.  There is deliberately
-- no generic Vault path, object-store key, executable, command, or payload
-- constructor.  Every constructor that can mutate Vault contains a fresh
-- 'BootstrapVaultEffectPermit'.  Durable writes are made only through
-- 'BootstrapStoreBoundary', whose mutation fields require a
-- 'BootstrapStoreMutationPermit'.
module Prodbox.Bootstrap.Broker.Engine
  ( -- * Construction
    BrokerEngine
  , BrokerEngineBoundary (..)
  , BrokerProgramEvidenceBoundary (..)
  , mkBrokerEngine
  , EngineBoundaryError (..)
  , BrokerEngineError (..)

    -- * Strict route decoding and typed preparation
  , SomeDecodedBrokerCall
  , decodeBrokerCall
  , decodedBrokerRoute
  , SomePreparedBrokerCall
  , prepareBrokerCall
  , preparedBrokerRoute
  , preparedBrokerCapabilityOp
  , preparedBrokerCapabilityDigest

    -- * Same-reference admission and execution
  , SomeAdmittedBrokerCall
  , admitBrokerCall
  , admittedBrokerRoute
  , admittedBrokerCapabilityOp
  , admittedBrokerCapabilityDigest
  , EngineExecutionContext
  , mkEngineExecutionContext
  , executeBrokerCall

    -- * Closed physical boundary
  , BrokerPhysicalCall (..)
  , BrokerSecretWorkerBoundary (..)
  , physicalCallCapabilityOp
  , physicalCallVaultEffect
  , physicalCallSecretWorkerOperation
  , BrokerLocalCall (..)
  , BrokerInMemoryCall (..)
  , BrokerInMemoryBoundary (..)
  , RootInitCallOutcome (..)
  , RootInitRecoveryObservation (..)
  , RootInitCryptoParameters (..)
  , EngineFenceUseObservation (..)

    -- * Typed responses
  , BrokerResponse (..)
  , SomeBrokerResponse
  , brokerResponseRoute
  , encodeBrokerResponse
  , encodeSomeBrokerResponse
  )
where

import Control.Monad (unless, void, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Custody
  ( ChildCustodyCommand (..)
  , ChildCustodyPhase (..)
  , ChildCustodyPlan (..)
  , ChildCustodyState (..)
  , ChildRecoveryCommand (..)
  , ChildRecoveryPlan (..)
  , ChildRecoveryState (..)
  , CustodyDisposition (..)
  , RootInitCommand (..)
  , RootInitPhase (..)
  , RootInitPlan (..)
  , RootInitState (..)
  , applyChildCustodyCommand
  , applyChildRecoveryCommand
  , applyRootInitCommand
  , newChildCustodyState
  , newChildRecoveryState
  , newRootInitState
  , planChildCustody
  , planChildRecovery
  , planRootInit
  , restartChildRecovery
  )
import Prodbox.Bootstrap.Broker.EngineSecretWorker
  ( EngineSecretWorkerBoundary
  , EngineSecretWorkerError
  , driveSecretWorker
  , reconcileAuthoritativeSecretWorkerResult
  )
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapFenceStoreObservation (..)
  , BootstrapFenceUseRefusal
  , BootstrapLeaseObservation
  , BootstrapSessionFence
  , BootstrapStoreMutation (..)
  , BootstrapStoreMutationPermit
  , BootstrapVaultEffect (..)
  , BootstrapVaultEffectPermit
  , authorizeBootstrapStoreMutation
  , authorizeBootstrapVaultEffect
  , bootstrapFenceActionDigest
  , bootstrapFenceGeneration
  , bootstrapFenceGenerationValue
  , bootstrapFenceRequestDigest
  , bootstrapFenceStorageGeneration
  , vaultEffectPermitActionDigest
  )
import Prodbox.Bootstrap.Broker.Model
  ( PostUnsealHandoffCommand (..)
  , PostUnsealHandoffPlan (..)
  , PostUnsealHandoffState (..)
  , ProvisionerSessionCommand (..)
  , ProvisionerSessionPlan (..)
  , ProvisionerSessionState
  , RootSessionBinding (..)
  , RootSessionCommand (..)
  , RootSessionCompletion (..)
  , RootSessionPlan (..)
  , RootSessionState (..)
  , applyPostUnsealHandoffCommand
  , applyProvisionerSessionCommand
  , applyRootSessionCommand
  , newPostUnsealHandoffState
  , newProvisionerSessionState
  , newRootSessionState
  , planPostUnsealHandoff
  , planProvisionerSession
  , planRootSession
  , restartRootSession
  )
import Prodbox.Bootstrap.Broker.PgpBoundary
  ( GeneratedChildRecoveryCiphertext
  , GeneratedChildRecoveryPublicKey
  , GeneratedChildRecoveryWorkflow (..)
  , GeneratedRootCiphertext
  , GeneratedRootPublicKey
  , GeneratedRootWorkflow (..)
  , PgpBoundary (..)
  , PgpBoundaryError
  , PreparedInitRecipients
  , preparedInitBurnPublicKeyBase64
  , preparedInitRecipientShareCount
  , preparedInitRecipientThreshold
  , preparedInitRecoveryRecipient
  , preparedInitVerifiedBurnRecipient
  , preparedRecoveryEnvelope
  , verifiedBurnRecipientFingerprint
  , verifiedBurnRecipientPublicKeyDigest
  )
import Prodbox.Bootstrap.Broker.Program
  ( BootstrapMutationReceipt (..)
  , BootstrapStatus (..)
  , BrokerCapabilityRefs
  , BrokerProgram (..)
  , PkiIssueRequest
  , VaultPkiStatus (..)
  , brokerProgramCapabilityRef
  )
import Prodbox.Bootstrap.Broker.Protocol
  ( BrokerActionRequest
  , BrokerControllerRequest
  , BrokerProtocolError (..)
  , brokerActionDigest
  , brokerActionStorageGeneration
  , brokerControllerRequestAction
  , brokerControllerRequestPkiIssue
  , decodeBrokerControllerRequest
  )
import Prodbox.Bootstrap.Broker.Request
  ( RequestDigest
  , requestDigestForBytes
  )
import Prodbox.Bootstrap.Broker.Routes
  ( BrokerBodyRequirement (..)
  , BrokerHttpMethod
  , BrokerRoute (..)
  , brokerRouteBodyRequirement
  , brokerRouteForPath
  , brokerRouteForRequest
  , brokerRouteIsMutation
  )
import Prodbox.Bootstrap.Broker.SecretWorker
  ( ExecutedSecretWorker
  , RawSecretWorkerReceipt
  , RunningSecretWorker
  , SecretWorkerDurableResult
  , SecretWorkerEffectPermit
  , SecretWorkerInterruption (..)
  , SecretWorkerOperation (..)
  , SecretWorkerReceipt
  , ambiguousInitializationWorkerResult
  , durableEncryptedInitialization
  , durableFinalizedInitialization
  , durableInitializationIsAmbiguous
  , durablePreparedInitialization
  , durableResumedInitialization
  , durableTransitRotationResult
  , durableUnlockRotationResult
  , durableUnsealResult
  , encryptedInitializationWorkerResult
  , finalizedInitializationWorkerResult
  , finishSecretWorkerExecution
  , preparedInitializationWorkerResult
  , resumedInitializationWorkerResult
  , secretWorkerReceiptOperation
  , transitRotationWorkerResult
  , unlockRotationWorkerResult
  , unsealWorkerResult
  )
import Prodbox.Bootstrap.Broker.Settings (CompiledBurnRecipient)
import Prodbox.Bootstrap.Broker.Settings qualified as Settings
import Prodbox.Bootstrap.Broker.StoreBoundary
  ( BootstrapStoreBoundary (..)
  , StoreBoundaryError
  , StoreReadBack (..)
  , StoreVersion
  , StoreWriteResult (..)
  )
import Prodbox.Bootstrap.Broker.Types
  ( AccessorAbsenceAttestation
  , ArtifactDigest
  , BaselineReadBackReceipt
  , BootstrapSchemaVersion
  , ChildAttestation
  , ChildCustodyBinding (..)
  , ChildEncryptedReceipt (..)
  , ChildRecoveryConsumptionObservation
  , ChildRecoveryConsumptionStatus (..)
  , ChildRecoveryDelivery (..)
  , DeliveryNonce
  , EncryptedInitResponseReceipt
  , FinalUnlockBundle
  , InitAmbiguity
  , ParentCustodyAcknowledgement (..)
  , PostUnsealConsumer (..)
  , PostUnsealHandoffReceipt
  , PreparedInitEnvelope
  , PristineResetProof
  , PristineStorageProof
  , ProvisionerLoginReceipt
  , RecoveryCustodyReceipt
  , RootAccessorInventory
  , RootInitBinding (..)
  , RootPolicyAccessor
  , RootSessionId
  , VaultStorageGeneration
  , ambiguousInitBinding
  , baselineReadBackDigest
  , baselineReadBackSessionId
  , baselineReadBackStorageGeneration
  , childRecoveryConsumptionObservationMatches
  , childRecoveryDeliveryDigest
  , childRecoveryDeliveryNonce
  , encryptedResponseBinding
  , encryptedResponseRecipientCommitment
  , encryptedResponseSchemaVersion
  , finalUnlockBundleBinding
  , finalUnlockBundleSchemaVersion
  , finalUnlockBundleShareCount
  , finalUnlockBundleThreshold
  , initRecipientBurnPublicKeyDigest
  , initRecipientShareCount
  , initRecipientThreshold
  , mkRootAccessorInventory
  , postUnsealHandoffConsumer
  , postUnsealHandoffGeneration
  , preparedInitBinding
  , preparedInitEnvelopeDigest
  , preparedInitRecipientCommitment
  , preparedInitSchemaVersion
  , pristineStorageBinding
  , recoveryCustodyAcknowledgementDigest
  , recoveryCustodyBinding
  , renderArtifactDigest
  , renderBurnRecipientFingerprint
  , renderDeliveryNonce
  , renderRootSessionId
  , renderVaultStorageGeneration
  , resetAmbiguousBinding
  )
import Prodbox.ControlPlane.AuthorityClock (AuthorityClockObservation)
import Prodbox.ControlPlane.CapabilityKind
  ( CapabilityKind (..)
  , CapabilityOp
  )
import Prodbox.ControlPlane.CapabilityRef
  ( CapabilityRef
  , refCapabilityOp
  , refCoordinateDigest
  )
import Prodbox.ControlPlane.Coordinate (CoordinateDigest)
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  )

-- | A boundary failure retains the important retry distinction.  No variant
-- can carry a physical path, command, object coordinate, or secret value.
data EngineBoundaryError
  = EngineBoundaryUnavailable !Text
  | EngineBoundaryRefused !Text
  | EngineBoundaryAmbiguous !Text
  deriving stock (Eq, Show)

data BrokerEngineError
  = EngineUnknownRoute
  | EngineWrongMethod !BrokerRoute
  | EngineBodyRequired !BrokerRoute
  | EngineBodyForbidden !BrokerRoute
  | EngineProtocolRefused !BrokerProtocolError
  | EngineProgramEvidenceRefused !EngineBoundaryError
  | EngineEvidenceGenerationMismatch !BrokerRoute
  | EngineCapabilityAdmissionRefused !EngineBoundaryError
  | EngineCapabilityExecutionRefused !EngineBoundaryError
  | EngineFenceAcquireRefused !EngineBoundaryError
  | EngineFenceBindingMismatch
  | EngineFenceUseRefused !BootstrapFenceUseRefusal
  | EngineSecretWorkerRefused !(EngineSecretWorkerError EngineBoundaryError)
  | EngineSecretWorkerBoundaryUnavailable
  | EngineSecretWorkerCallMismatch
  | EnginePgpBoundaryRefused !PgpBoundaryError
  | EnginePgpBoundaryUnavailable
  | EngineGeneratedRootScopeLost
  | EnginePhysicalCallRefused !EngineBoundaryError
  | EngineStoreRefused !StoreBoundaryError
  | EngineStoreReadBackMismatch
  | EngineStoreVersionConflict
  | EngineCustodyTransitionRefused !Text
  | EngineCustodyPlanLimitExceeded
  | EngineInitializationAmbiguous !InitAmbiguity
  | EngineMutationReceiptMismatch
  | EngineResponseEvidenceMismatch !BrokerRoute
  deriving stock (Eq, Show)

-- Decoding ----------------------------------------------------------------

data DecodedBrokerCall (operation :: CapabilityKind) result where
  DecodedHealth
    :: !RequestDigest
    -> DecodedBrokerCall 'VaultBootstrapObserve Bool
  DecodedReadiness
    :: !RequestDigest
    -> DecodedBrokerCall 'VaultBootstrapObserve Bool
  DecodedVaultStatus
    :: !RequestDigest
    -> DecodedBrokerCall 'VaultBootstrapObserve BootstrapStatus
  DecodedVaultInitialize
    :: !RequestDigest
    -> !BrokerActionRequest
    -> DecodedBrokerCall 'VaultBootstrapMutate RecoveryCustodyReceipt
  DecodedVaultUnseal
    :: !RequestDigest
    -> !BrokerActionRequest
    -> DecodedBrokerCall 'VaultBootstrapMutate BootstrapMutationReceipt
  DecodedVaultSeal
    :: !RequestDigest
    -> !BrokerActionRequest
    -> DecodedBrokerCall 'VaultBootstrapMutate BootstrapMutationReceipt
  DecodedVaultRotateUnlockBundle
    :: !RequestDigest
    -> !BrokerActionRequest
    -> DecodedBrokerCall 'VaultBootstrapMutate BootstrapMutationReceipt
  DecodedVaultRotateTransitKey
    :: !RequestDigest
    -> !BrokerActionRequest
    -> DecodedBrokerCall 'VaultBootstrapMutate BootstrapMutationReceipt
  DecodedVaultBaselineReconcile
    :: !RequestDigest
    -> !BrokerActionRequest
    -> DecodedBrokerCall 'VaultBaselineReconcile BaselineReadBackReceipt
  DecodedVaultPkiStatus
    :: !RequestDigest
    -> DecodedBrokerCall 'VaultPkiOperate VaultPkiStatus
  DecodedVaultPkiIssueTestCertificate
    :: !RequestDigest
    -> !BrokerActionRequest
    -> !PkiIssueRequest
    -> DecodedBrokerCall 'VaultPkiOperate BootstrapMutationReceipt
  DecodedVaultResetAmbiguousInitialization
    :: !RequestDigest
    -> !BrokerActionRequest
    -> DecodedBrokerCall 'VaultBootstrapMutate BootstrapMutationReceipt
  DecodedChildCustodyCommit
    :: !RequestDigest
    -> !BrokerActionRequest
    -> DecodedBrokerCall 'VaultBootstrapMutate ParentCustodyAcknowledgement
  DecodedChildRecoveryDeliver
    :: !RequestDigest
    -> !BrokerActionRequest
    -> DecodedBrokerCall 'VaultBootstrapMutate ChildRecoveryDelivery
  DecodedChildRecoveryObserve
    :: !RequestDigest
    -> !BrokerActionRequest
    -> DecodedBrokerCall 'VaultBootstrapObserve (Maybe ChildRecoveryDelivery)

data SomeDecodedBrokerCall where
  SomeDecodedBrokerCall :: DecodedBrokerCall operation result -> SomeDecodedBrokerCall

decodedBrokerRoute :: SomeDecodedBrokerCall -> BrokerRoute
decodedBrokerRoute (SomeDecodedBrokerCall call) = decodedRoute call

decodeBrokerCall
  :: BrokerHttpMethod
  -> String
  -> ByteString
  -> Either BrokerEngineError SomeDecodedBrokerCall
decodeBrokerCall method path body = do
  route <- case brokerRouteForRequest method path of
    Just matched -> Right matched
    Nothing -> case brokerRouteForPath path of
      Just methodMismatch -> Left (EngineWrongMethod methodMismatch)
      Nothing -> Left EngineUnknownRoute
  controllerRequest <- decodeRouteBody route body
  decodedCallForRoute route (requestDigestForBytes body) controllerRequest

decodeRouteBody
  :: BrokerRoute
  -> ByteString
  -> Either BrokerEngineError (Maybe BrokerControllerRequest)
decodeRouteBody route body = case brokerRouteBodyRequirement route of
  BrokerBodyForbidden
    | ByteString.null body -> Right Nothing
    | otherwise -> Left (EngineBodyForbidden route)
  BrokerBodyRequired
    | ByteString.null body -> Left (EngineBodyRequired route)
    | otherwise ->
        Just
          <$> either
            (Left . EngineProtocolRefused)
            Right
            (decodeBrokerControllerRequest route body)

decodedCallForRoute
  :: BrokerRoute
  -> RequestDigest
  -> Maybe BrokerControllerRequest
  -> Either BrokerEngineError SomeDecodedBrokerCall
decodedCallForRoute route requestDigest controllerRequest =
  case (route, controllerRequest) of
    (BrokerHealth, Nothing) -> Right (SomeDecodedBrokerCall (DecodedHealth requestDigest))
    (BrokerReadiness, Nothing) -> Right (SomeDecodedBrokerCall (DecodedReadiness requestDigest))
    (BrokerVaultStatus, Nothing) -> Right (SomeDecodedBrokerCall (DecodedVaultStatus requestDigest))
    (BrokerVaultInitialize, Just request) ->
      Right
        ( SomeDecodedBrokerCall
            (DecodedVaultInitialize requestDigest (brokerControllerRequestAction request))
        )
    (BrokerVaultUnseal, Just request) ->
      Right
        ( SomeDecodedBrokerCall
            (DecodedVaultUnseal requestDigest (brokerControllerRequestAction request))
        )
    (BrokerVaultSeal, Just request) ->
      Right
        ( SomeDecodedBrokerCall
            (DecodedVaultSeal requestDigest (brokerControllerRequestAction request))
        )
    (BrokerVaultRotateUnlockBundle, Just request) ->
      Right
        ( SomeDecodedBrokerCall
            (DecodedVaultRotateUnlockBundle requestDigest (brokerControllerRequestAction request))
        )
    (BrokerVaultRotateTransitKey, Just request) ->
      Right
        ( SomeDecodedBrokerCall
            (DecodedVaultRotateTransitKey requestDigest (brokerControllerRequestAction request))
        )
    (BrokerVaultBaselineReconcile, Just request) ->
      Right
        ( SomeDecodedBrokerCall
            (DecodedVaultBaselineReconcile requestDigest (brokerControllerRequestAction request))
        )
    (BrokerVaultPkiStatus, Nothing) ->
      Right (SomeDecodedBrokerCall (DecodedVaultPkiStatus requestDigest))
    (BrokerVaultPkiIssueTestCertificate, Just request) ->
      case brokerControllerRequestPkiIssue request of
        Just issueRequest ->
          Right
            ( SomeDecodedBrokerCall
                ( DecodedVaultPkiIssueTestCertificate
                    requestDigest
                    (brokerControllerRequestAction request)
                    issueRequest
                )
            )
        Nothing -> Left (EngineProtocolRefused BrokerProtocolPkiFieldsRequired)
    (BrokerVaultResetAmbiguousInitialization, Just request) ->
      Right
        ( SomeDecodedBrokerCall
            ( DecodedVaultResetAmbiguousInitialization
                requestDigest
                (brokerControllerRequestAction request)
            )
        )
    (BrokerChildCustodyCommit, Just request) ->
      Right
        ( SomeDecodedBrokerCall
            (DecodedChildCustodyCommit requestDigest (brokerControllerRequestAction request))
        )
    (BrokerChildRecoveryDeliver, Just request) ->
      Right
        ( SomeDecodedBrokerCall
            (DecodedChildRecoveryDeliver requestDigest (brokerControllerRequestAction request))
        )
    (BrokerChildRecoveryObserve, Just request) ->
      Right
        ( SomeDecodedBrokerCall
            (DecodedChildRecoveryObserve requestDigest (brokerControllerRequestAction request))
        )
    (_, Nothing) -> Left (EngineBodyRequired route)
    (_, Just _) -> Left (EngineBodyForbidden route)

decodedRoute :: DecodedBrokerCall operation result -> BrokerRoute
decodedRoute call = case call of
  DecodedHealth _ -> BrokerHealth
  DecodedReadiness _ -> BrokerReadiness
  DecodedVaultStatus _ -> BrokerVaultStatus
  DecodedVaultInitialize _ _ -> BrokerVaultInitialize
  DecodedVaultUnseal _ _ -> BrokerVaultUnseal
  DecodedVaultSeal _ _ -> BrokerVaultSeal
  DecodedVaultRotateUnlockBundle _ _ -> BrokerVaultRotateUnlockBundle
  DecodedVaultRotateTransitKey _ _ -> BrokerVaultRotateTransitKey
  DecodedVaultBaselineReconcile _ _ -> BrokerVaultBaselineReconcile
  DecodedVaultPkiStatus _ -> BrokerVaultPkiStatus
  DecodedVaultPkiIssueTestCertificate {} -> BrokerVaultPkiIssueTestCertificate
  DecodedVaultResetAmbiguousInitialization _ _ ->
    BrokerVaultResetAmbiguousInitialization
  DecodedChildCustodyCommit _ _ -> BrokerChildCustodyCommit
  DecodedChildRecoveryDeliver _ _ -> BrokerChildRecoveryDeliver
  DecodedChildRecoveryObserve _ _ -> BrokerChildRecoveryObserve

decodedRequestDigest :: DecodedBrokerCall operation result -> RequestDigest
decodedRequestDigest call = case call of
  DecodedHealth digest -> digest
  DecodedReadiness digest -> digest
  DecodedVaultStatus digest -> digest
  DecodedVaultInitialize digest _ -> digest
  DecodedVaultUnseal digest _ -> digest
  DecodedVaultSeal digest _ -> digest
  DecodedVaultRotateUnlockBundle digest _ -> digest
  DecodedVaultRotateTransitKey digest _ -> digest
  DecodedVaultBaselineReconcile digest _ -> digest
  DecodedVaultPkiStatus digest -> digest
  DecodedVaultPkiIssueTestCertificate digest _ _ -> digest
  DecodedVaultResetAmbiguousInitialization digest _ -> digest
  DecodedChildCustodyCommit digest _ -> digest
  DecodedChildRecoveryDeliver digest _ -> digest
  DecodedChildRecoveryObserve digest _ -> digest

decodedAction
  :: DecodedBrokerCall operation result -> Maybe BrokerActionRequest
decodedAction call = case call of
  DecodedHealth _ -> Nothing
  DecodedReadiness _ -> Nothing
  DecodedVaultStatus _ -> Nothing
  DecodedVaultInitialize _ action -> Just action
  DecodedVaultUnseal _ action -> Just action
  DecodedVaultSeal _ action -> Just action
  DecodedVaultRotateUnlockBundle _ action -> Just action
  DecodedVaultRotateTransitKey _ action -> Just action
  DecodedVaultBaselineReconcile _ action -> Just action
  DecodedVaultPkiStatus _ -> Nothing
  DecodedVaultPkiIssueTestCertificate _ action _ -> Just action
  DecodedVaultResetAmbiguousInitialization _ action -> Just action
  DecodedChildCustodyCommit _ action -> Just action
  DecodedChildRecoveryDeliver _ action -> Just action
  DecodedChildRecoveryObserve _ action -> Just action

-- Preparation -------------------------------------------------------------

-- | Exact durable evidence resolvers.  The action digest selects a previously
-- planned, secret-free operation record; callers cannot supply evidence in the
-- controller JSON.  Separate fields keep one route from asking for another
-- route's evidence and leave no generic store lookup escape.
data BrokerProgramEvidenceBoundary m = BrokerProgramEvidenceBoundary
  { resolvePristineStorageProof
      :: BrokerActionRequest
      -> m (Either EngineBoundaryError PristineStorageProof)
  , resolveUnsealRecoveryCustody
      :: BrokerActionRequest
      -> m (Either EngineBoundaryError RecoveryCustodyReceipt)
  , resolveUnlockRotationCustody
      :: BrokerActionRequest
      -> m (Either EngineBoundaryError RecoveryCustodyReceipt)
  , resolveBaselineCustodyAndSession
      :: BrokerActionRequest
      -> m (Either EngineBoundaryError (RecoveryCustodyReceipt, RootSessionId))
  , resolveAmbiguousResetEvidence
      :: BrokerActionRequest
      -> m (Either EngineBoundaryError (InitAmbiguity, PristineResetProof))
  , resolveChildCustodyBinding
      :: BrokerActionRequest
      -> m (Either EngineBoundaryError ChildCustodyBinding)
  , resolveChildRecoveryDeliveryEvidence
      :: BrokerActionRequest
      -> m (Either EngineBoundaryError (ChildCustodyBinding, DeliveryNonce, ChildAttestation))
  , resolveChildRecoveryObservation
      :: BrokerActionRequest
      -> m (Either EngineBoundaryError (ChildCustodyBinding, DeliveryNonce))
  }

data PreparedExecution (operation :: CapabilityKind) result where
  ExecuteHealth
    :: PreparedExecution 'VaultBootstrapObserve Bool
  ExecuteReadiness
    :: PreparedExecution 'VaultBootstrapObserve Bool
  ExecuteVaultStatus
    :: PreparedExecution 'VaultBootstrapObserve BootstrapStatus
  ExecuteVaultInitialize
    :: !PristineStorageProof
    -> PreparedExecution 'VaultBootstrapMutate RecoveryCustodyReceipt
  ExecuteVaultUnseal
    :: !RecoveryCustodyReceipt
    -> PreparedExecution 'VaultBootstrapMutate BootstrapMutationReceipt
  ExecuteVaultSeal
    :: PreparedExecution 'VaultBootstrapMutate BootstrapMutationReceipt
  ExecuteVaultRotateUnlockBundle
    :: !RecoveryCustodyReceipt
    -> PreparedExecution 'VaultBootstrapMutate BootstrapMutationReceipt
  ExecuteVaultRotateTransitKey
    :: PreparedExecution 'VaultBootstrapMutate BootstrapMutationReceipt
  ExecuteVaultBaselineReconcile
    :: !RootSessionId
    -> !RecoveryCustodyReceipt
    -> PreparedExecution 'VaultBaselineReconcile BaselineReadBackReceipt
  ExecuteVaultPkiStatus
    :: PreparedExecution 'VaultPkiOperate VaultPkiStatus
  ExecuteVaultPkiIssueTestCertificate
    :: !PkiIssueRequest
    -> PreparedExecution 'VaultPkiOperate BootstrapMutationReceipt
  ExecuteVaultResetAmbiguousInitialization
    :: !InitAmbiguity
    -> !PristineResetProof
    -> PreparedExecution 'VaultBootstrapMutate BootstrapMutationReceipt
  ExecuteChildCustodyCommit
    :: !ChildCustodyBinding
    -> PreparedExecution 'VaultBootstrapMutate ParentCustodyAcknowledgement
  ExecuteChildRecoveryDeliver
    :: !ChildCustodyBinding
    -> !DeliveryNonce
    -> !ChildAttestation
    -> PreparedExecution 'VaultBootstrapMutate ChildRecoveryDelivery
  ExecuteChildRecoveryObserve
    :: !ChildCustodyBinding
    -> !DeliveryNonce
    -> PreparedExecution 'VaultBootstrapObserve (Maybe ChildRecoveryDelivery)

data PreparedBrokerCall (operation :: CapabilityKind) result
  = PreparedBrokerCall
      !BrokerRoute
      !RequestDigest
      !(Maybe BrokerActionRequest)
      !(BrokerProgram operation result)
      !(CapabilityRef operation)
      !(PreparedExecution operation result)

data SomePreparedBrokerCall where
  SomePreparedBrokerCall
    :: PreparedBrokerCall operation result
    -> SomePreparedBrokerCall

preparedBrokerRoute :: SomePreparedBrokerCall -> BrokerRoute
preparedBrokerRoute (SomePreparedBrokerCall prepared) = preparedRoute prepared

preparedBrokerCapabilityOp :: SomePreparedBrokerCall -> CapabilityOp
preparedBrokerCapabilityOp (SomePreparedBrokerCall prepared) =
  refCapabilityOp (preparedReference prepared)

preparedBrokerCapabilityDigest :: SomePreparedBrokerCall -> CoordinateDigest
preparedBrokerCapabilityDigest (SomePreparedBrokerCall prepared) =
  refCoordinateDigest (preparedReference prepared)

prepareBrokerCall
  :: (Monad m)
  => BrokerEngine m
  -> SomeDecodedBrokerCall
  -> m (Either BrokerEngineError SomePreparedBrokerCall)
prepareBrokerCall engine (SomeDecodedBrokerCall decoded) = do
  prepared <- prepareDecodedCall engine decoded
  pure (SomePreparedBrokerCall <$> prepared)

prepareDecodedCall
  :: (Monad m)
  => BrokerEngine m
  -> DecodedBrokerCall operation result
  -> m (Either BrokerEngineError (PreparedBrokerCall operation result))
prepareDecodedCall engine decoded = case decoded of
  DecodedHealth _ -> pure (Right (makePrepared engine decoded ObserveBrokerHealth ExecuteHealth))
  DecodedReadiness _ -> pure (Right (makePrepared engine decoded ObserveBrokerReadiness ExecuteReadiness))
  DecodedVaultStatus _ -> pure (Right (makePrepared engine decoded ObserveBootstrapStatus ExecuteVaultStatus))
  DecodedVaultInitialize _ action -> do
    evidence <- resolve (resolvePristineStorageProof evidenceBoundary action)
    pure $ do
      proof <- evidence
      requireRootGeneration route action (pristineStorageBinding proof)
      Right (makePrepared engine decoded (InitializeVault proof) (ExecuteVaultInitialize proof))
  DecodedVaultUnseal _ action -> do
    evidence <- resolve (resolveUnsealRecoveryCustody evidenceBoundary action)
    pure $ do
      custody <- evidence
      requireRootGeneration route action (recoveryCustodyBinding custody)
      Right (makePrepared engine decoded (UnsealVault custody) (ExecuteVaultUnseal custody))
  DecodedVaultSeal _ _ -> pure (Right (makePrepared engine decoded SealVault ExecuteVaultSeal))
  DecodedVaultRotateUnlockBundle _ action -> do
    evidence <- resolve (resolveUnlockRotationCustody evidenceBoundary action)
    pure $ do
      custody <- evidence
      requireRootGeneration route action (recoveryCustodyBinding custody)
      Right
        ( makePrepared
            engine
            decoded
            (RotateUnlockBundle custody)
            (ExecuteVaultRotateUnlockBundle custody)
        )
  DecodedVaultRotateTransitKey _ _ ->
    pure (Right (makePrepared engine decoded RotateTransitKey ExecuteVaultRotateTransitKey))
  DecodedVaultBaselineReconcile _ action -> do
    evidence <- resolve (resolveBaselineCustodyAndSession evidenceBoundary action)
    pure $ do
      (custody, sessionId) <- evidence
      requireRootGeneration route action (recoveryCustodyBinding custody)
      Right
        ( makePrepared
            engine
            decoded
            (ReconcileAllowlistedBaseline custody)
            (ExecuteVaultBaselineReconcile sessionId custody)
        )
  DecodedVaultPkiStatus _ ->
    pure (Right (makePrepared engine decoded ObserveVaultPkiStatus ExecuteVaultPkiStatus))
  DecodedVaultPkiIssueTestCertificate _ _ issueRequest ->
    pure
      ( Right
          ( makePrepared
              engine
              decoded
              (IssueVaultPkiTestCertificate issueRequest)
              (ExecuteVaultPkiIssueTestCertificate issueRequest)
          )
      )
  DecodedVaultResetAmbiguousInitialization _ action -> do
    evidence <- resolve (resolveAmbiguousResetEvidence evidenceBoundary action)
    pure $ do
      (ambiguity, resetProof) <- evidence
      requireRootGeneration route action (ambiguousInitBinding ambiguity)
      when
        (resetAmbiguousBinding resetProof /= ambiguousInitBinding ambiguity)
        (Left (EngineResponseEvidenceMismatch route))
      Right
        ( makePrepared
            engine
            decoded
            (ResetAmbiguousInitialization ambiguity resetProof)
            (ExecuteVaultResetAmbiguousInitialization ambiguity resetProof)
        )
  DecodedChildCustodyCommit _ action -> do
    evidence <- resolve (resolveChildCustodyBinding evidenceBoundary action)
    pure $ do
      binding <- evidence
      requireChildGeneration route action binding
      Right
        ( makePrepared
            engine
            decoded
            (CommitChildCustody binding)
            (ExecuteChildCustodyCommit binding)
        )
  DecodedChildRecoveryDeliver _ action -> do
    evidence <- resolve (resolveChildRecoveryDeliveryEvidence evidenceBoundary action)
    pure $ do
      (binding, nonce, attestation) <- evidence
      requireChildGeneration route action binding
      Right
        ( makePrepared
            engine
            decoded
            (DeliverChildRecovery binding nonce attestation)
            (ExecuteChildRecoveryDeliver binding nonce attestation)
        )
  DecodedChildRecoveryObserve _ action -> do
    evidence <- resolve (resolveChildRecoveryObservation evidenceBoundary action)
    pure $ do
      (binding, nonce) <- evidence
      requireChildGeneration route action binding
      Right
        ( makePrepared
            engine
            decoded
            (ObserveChildRecoveryDelivery binding nonce)
            (ExecuteChildRecoveryObserve binding nonce)
        )
 where
  route = decodedRoute decoded
  evidenceBoundary = engineEvidenceBoundary (brokerEngineBoundary engine)

  resolve action = do
    outcome <- action
    pure (either (Left . EngineProgramEvidenceRefused) Right outcome)

makePrepared
  :: BrokerEngine m
  -> DecodedBrokerCall decodedOperation decodedResult
  -> BrokerProgram operation result
  -> PreparedExecution operation result
  -> PreparedBrokerCall operation result
makePrepared engine decoded program execution =
  PreparedBrokerCall
    (decodedRoute decoded)
    (decodedRequestDigest decoded)
    (decodedAction decoded)
    program
    (brokerProgramCapabilityRef (brokerEngineCapabilityRefs engine) program)
    execution

requireRootGeneration
  :: BrokerRoute
  -> BrokerActionRequest
  -> RootInitBinding
  -> Either BrokerEngineError ()
requireRootGeneration route action binding =
  when
    (rootInitStorageGeneration binding /= brokerActionStorageGeneration action)
    (Left (EngineEvidenceGenerationMismatch route))

requireChildGeneration
  :: BrokerRoute
  -> BrokerActionRequest
  -> ChildCustodyBinding
  -> Either BrokerEngineError ()
requireChildGeneration route action binding =
  when
    (childCustodyStorageGeneration binding /= brokerActionStorageGeneration action)
    (Left (EngineEvidenceGenerationMismatch route))

preparedRoute :: PreparedBrokerCall operation result -> BrokerRoute
preparedRoute (PreparedBrokerCall route _ _ _ _ _) = route

preparedRequestDigest
  :: PreparedBrokerCall operation result -> RequestDigest
preparedRequestDigest (PreparedBrokerCall _ digest _ _ _ _) = digest

preparedAction
  :: PreparedBrokerCall operation result -> Maybe BrokerActionRequest
preparedAction (PreparedBrokerCall _ _ action _ _ _) = action

preparedProgram
  :: PreparedBrokerCall operation result -> BrokerProgram operation result
preparedProgram (PreparedBrokerCall _ _ _ program _ _) = program

preparedReference
  :: PreparedBrokerCall operation result -> CapabilityRef operation
preparedReference (PreparedBrokerCall _ _ _ _ reference _) = reference

preparedExecution
  :: PreparedBrokerCall operation result -> PreparedExecution operation result
preparedExecution (PreparedBrokerCall _ _ _ _ _ execution) = execution

-- Admission and closed boundaries ----------------------------------------

-- | Fresh observations used by the engine itself to mint a one-attempt
-- permit.  An interpreter supplies raw observations only; it cannot construct
-- either opaque permit.
data EngineFenceUseObservation = EngineFenceUseObservation
  { engineFenceMonotonicNow :: !MonotonicInstant
  , engineFenceAuthorityClock :: !AuthorityClockObservation
  , engineFenceStoreObservation :: !BootstrapFenceStoreObservation
  , engineFenceLeaseObservation :: !BootstrapLeaseObservation
  }
  deriving stock (Eq, Show)

-- | Result of the one non-idempotent Vault initialization attempt.  The
-- ambiguous constructor records a known applied call without pretending the
-- lost response is a failure that can be retried.
data RootInitCallOutcome
  = RootInitEncryptedResponse !EncryptedInitResponseReceipt
  | RootInitAppliedWithoutResponse
  deriving stock (Eq, Show)

-- | Recovery observation for a journal already in the in-flight phase after
-- process loss.  It either recovers the exact encrypted receipt or makes the
-- ambiguity explicit; there is no "assume absent and retry" constructor.
data RootInitRecoveryObservation
  = RootInitRecoveredResponse !EncryptedInitResponseReceipt
  | RootInitRecoveredAmbiguity
  deriving stock (Eq, Show)

-- | Secret-free configuration committed before recovery-recipient
-- preparation.  The compiled burn recipient contains public material and
-- audited pins only; no corresponding private-key type exists.
data RootInitCryptoParameters = RootInitCryptoParameters
  { rootInitCryptoSchemaVersion :: !BootstrapSchemaVersion
  , rootInitCryptoCompiledBurnRecipient :: !CompiledBurnRecipient
  , rootInitCryptoShareCount :: !Natural
  , rootInitCryptoThreshold :: !Natural
  , rootInitCryptoEnvelopeDigest :: !ArtifactDigest
  }
  deriving stock (Eq, Show)

-- | The complete physical vocabulary.  All Vault-mutating constructors carry
-- their exact fresh permit; every secret-bearing operation and initialization
-- stage additionally projects to 'SecretWorkerOperation'.
data BrokerPhysicalCall (operation :: CapabilityKind) result where
  PhysicalHealth
    :: CapabilityRef 'VaultBootstrapObserve
    -> BrokerPhysicalCall 'VaultBootstrapObserve Bool
  PhysicalReadiness
    :: CapabilityRef 'VaultBootstrapObserve
    -> BrokerPhysicalCall 'VaultBootstrapObserve Bool
  PhysicalObserveVaultStatus
    :: CapabilityRef 'VaultBootstrapObserve
    -> BrokerPhysicalCall 'VaultBootstrapObserve BootstrapStatus
  PhysicalPrepareRootInitRecipients
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> PristineStorageProof
    -> RootInitCryptoParameters
    -> BrokerPhysicalCall 'VaultBootstrapMutate PreparedInitRecipients
  PhysicalResumeRootInitRecipients
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> PreparedInitEnvelope
    -> CompiledBurnRecipient
    -> BrokerPhysicalCall 'VaultBootstrapMutate PreparedInitRecipients
  PhysicalInitializeVault
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> PreparedInitRecipients
    -> BrokerPhysicalCall 'VaultBootstrapMutate RootInitCallOutcome
  PhysicalSealFinalUnlockBundle
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> PreparedInitRecipients
    -> EncryptedInitResponseReceipt
    -> BrokerPhysicalCall 'VaultBootstrapMutate FinalUnlockBundle
  PhysicalUnsealVault
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> RecoveryCustodyReceipt
    -> BrokerPhysicalCall 'VaultBootstrapMutate BootstrapMutationReceipt
  PhysicalSealVault
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> BrokerPhysicalCall 'VaultBootstrapMutate BootstrapMutationReceipt
  PhysicalRotateUnlockBundle
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> RecoveryCustodyReceipt
    -> BrokerPhysicalCall 'VaultBootstrapMutate BootstrapMutationReceipt
  PhysicalRotateTransitKey
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> BrokerPhysicalCall 'VaultBootstrapMutate BootstrapMutationReceipt
  PhysicalResetAmbiguousInitialization
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> InitAmbiguity
    -> PristineResetProof
    -> BrokerPhysicalCall 'VaultBootstrapMutate PristineResetProof
  PhysicalCancelIncompleteGenerateRoot
    :: CapabilityRef 'VaultBaselineReconcile
    -> BootstrapVaultEffectPermit
    -> RootSessionBinding
    -> BrokerPhysicalCall 'VaultBaselineReconcile ()
  PhysicalInventoryRootAccessors
    :: CapabilityRef 'VaultBaselineReconcile
    -> BootstrapVaultEffectPermit
    -> VaultStorageGeneration
    -> BrokerPhysicalCall 'VaultBaselineReconcile RootAccessorInventory
  PhysicalRevokeRootAccessor
    :: CapabilityRef 'VaultBaselineReconcile
    -> BootstrapVaultEffectPermit
    -> RootPolicyAccessor
    -> BrokerPhysicalCall 'VaultBaselineReconcile ()
  PhysicalProveRootAccessorsAbsent
    :: CapabilityRef 'VaultBaselineReconcile
    -> BootstrapVaultEffectPermit
    -> RootAccessorInventory
    -> BrokerPhysicalCall 'VaultBaselineReconcile AccessorAbsenceAttestation
  PhysicalStartGenerateRoot
    :: CapabilityRef 'VaultBaselineReconcile
    -> BootstrapVaultEffectPermit
    -> RootSessionBinding
    -> GeneratedRootPublicKey
    -> BrokerPhysicalCall 'VaultBaselineReconcile ()
  PhysicalAwaitGeneratedRootCiphertext
    :: CapabilityRef 'VaultBaselineReconcile
    -> BootstrapVaultEffectPermit
    -> RootSessionBinding
    -> BrokerPhysicalCall 'VaultBaselineReconcile GeneratedRootCiphertext
  PhysicalLoginProvisioner
    :: CapabilityRef 'VaultBaselineReconcile
    -> BootstrapVaultEffectPermit
    -> VaultStorageGeneration
    -> BrokerPhysicalCall 'VaultBaselineReconcile ProvisionerLoginReceipt
  PhysicalApplyProvisionerBaseline
    :: CapabilityRef 'VaultBaselineReconcile
    -> BootstrapVaultEffectPermit
    -> ProvisionerLoginReceipt
    -> BrokerPhysicalCall 'VaultBaselineReconcile ()
  PhysicalReadBackProvisionerBaseline
    :: CapabilityRef 'VaultBaselineReconcile
    -> BootstrapVaultEffectPermit
    -> ProvisionerLoginReceipt
    -> BrokerPhysicalCall 'VaultBaselineReconcile BaselineReadBackReceipt
  PhysicalObservePostUnsealConsumer
    :: CapabilityRef 'VaultBootstrapMutate
    -> RootInitBinding
    -> PostUnsealConsumer
    -> BrokerPhysicalCall 'VaultBootstrapMutate (Maybe PostUnsealHandoffReceipt)
  PhysicalObserveVaultPkiStatus
    :: CapabilityRef 'VaultPkiOperate
    -> BrokerPhysicalCall 'VaultPkiOperate VaultPkiStatus
  PhysicalIssueVaultPkiTestCertificate
    :: CapabilityRef 'VaultPkiOperate
    -> BootstrapVaultEffectPermit
    -> PkiIssueRequest
    -> BrokerPhysicalCall 'VaultPkiOperate BootstrapMutationReceipt
  PhysicalCommitParentCustody
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> ChildEncryptedReceipt
    -> BrokerPhysicalCall 'VaultBootstrapMutate ParentCustodyAcknowledgement
  PhysicalObserveChildRecoveryConsumption
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> ChildRecoveryDelivery
    -> BrokerPhysicalCall 'VaultBootstrapMutate ChildRecoveryConsumptionObservation
  PhysicalConsumeChildRecovery
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> ChildRecoveryDelivery
    -> BrokerPhysicalCall 'VaultBootstrapMutate ChildRecoveryConsumptionObservation
  PhysicalCancelChildIncompleteGenerateRoot
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> ChildRecoveryDelivery
    -> BrokerPhysicalCall 'VaultBootstrapMutate ()
  PhysicalInventoryChildRootAccessors
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> ChildCustodyBinding
    -> BrokerPhysicalCall 'VaultBootstrapMutate RootAccessorInventory
  PhysicalRevokeChildRootAccessor
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> RootPolicyAccessor
    -> BrokerPhysicalCall 'VaultBootstrapMutate ()
  PhysicalProveChildRootAccessorsAbsent
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> RootAccessorInventory
    -> BrokerPhysicalCall 'VaultBootstrapMutate AccessorAbsenceAttestation
  PhysicalStartChildGenerateRoot
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> ChildRecoveryDelivery
    -> GeneratedChildRecoveryPublicKey
    -> BrokerPhysicalCall 'VaultBootstrapMutate ()
  PhysicalAwaitChildGeneratedRootCiphertext
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> ChildRecoveryDelivery
    -> BrokerPhysicalCall 'VaultBootstrapMutate GeneratedChildRecoveryCiphertext

physicalCallCapabilityOp
  :: BrokerPhysicalCall operation result -> CapabilityOp
physicalCallCapabilityOp call = case call of
  PhysicalHealth reference -> refCapabilityOp reference
  PhysicalReadiness reference -> refCapabilityOp reference
  PhysicalObserveVaultStatus reference -> refCapabilityOp reference
  PhysicalPrepareRootInitRecipients reference _ _ _ -> refCapabilityOp reference
  PhysicalResumeRootInitRecipients reference _ _ _ -> refCapabilityOp reference
  PhysicalInitializeVault reference _ _ -> refCapabilityOp reference
  PhysicalSealFinalUnlockBundle reference _ _ _ -> refCapabilityOp reference
  PhysicalUnsealVault reference _ _ -> refCapabilityOp reference
  PhysicalSealVault reference _ -> refCapabilityOp reference
  PhysicalRotateUnlockBundle reference _ _ -> refCapabilityOp reference
  PhysicalRotateTransitKey reference _ -> refCapabilityOp reference
  PhysicalResetAmbiguousInitialization reference _ _ _ -> refCapabilityOp reference
  PhysicalCancelIncompleteGenerateRoot reference _ _ -> refCapabilityOp reference
  PhysicalInventoryRootAccessors reference _ _ -> refCapabilityOp reference
  PhysicalRevokeRootAccessor reference _ _ -> refCapabilityOp reference
  PhysicalProveRootAccessorsAbsent reference _ _ -> refCapabilityOp reference
  PhysicalStartGenerateRoot reference _ _ _ -> refCapabilityOp reference
  PhysicalAwaitGeneratedRootCiphertext reference _ _ -> refCapabilityOp reference
  PhysicalLoginProvisioner reference _ _ -> refCapabilityOp reference
  PhysicalApplyProvisionerBaseline reference _ _ -> refCapabilityOp reference
  PhysicalReadBackProvisionerBaseline reference _ _ -> refCapabilityOp reference
  PhysicalObservePostUnsealConsumer reference _ _ -> refCapabilityOp reference
  PhysicalObserveVaultPkiStatus reference -> refCapabilityOp reference
  PhysicalIssueVaultPkiTestCertificate reference _ _ -> refCapabilityOp reference
  PhysicalCommitParentCustody reference _ _ -> refCapabilityOp reference
  PhysicalObserveChildRecoveryConsumption reference _ _ -> refCapabilityOp reference
  PhysicalConsumeChildRecovery reference _ _ -> refCapabilityOp reference
  PhysicalCancelChildIncompleteGenerateRoot reference _ _ -> refCapabilityOp reference
  PhysicalInventoryChildRootAccessors reference _ _ -> refCapabilityOp reference
  PhysicalRevokeChildRootAccessor reference _ _ -> refCapabilityOp reference
  PhysicalProveChildRootAccessorsAbsent reference _ _ -> refCapabilityOp reference
  PhysicalStartChildGenerateRoot reference _ _ _ -> refCapabilityOp reference
  PhysicalAwaitChildGeneratedRootCiphertext reference _ _ -> refCapabilityOp reference

physicalCallVaultEffect
  :: BrokerPhysicalCall operation result -> Maybe BootstrapVaultEffect
physicalCallVaultEffect call = case call of
  PhysicalHealth _ -> Nothing
  PhysicalReadiness _ -> Nothing
  PhysicalObserveVaultStatus _ -> Nothing
  PhysicalPrepareRootInitRecipients {} -> Just BootstrapVaultInitialize
  PhysicalResumeRootInitRecipients {} -> Just BootstrapVaultInitialize
  PhysicalInitializeVault {} -> Just BootstrapVaultInitialize
  PhysicalSealFinalUnlockBundle {} -> Just BootstrapVaultInitialize
  PhysicalUnsealVault {} -> Just BootstrapVaultSubmitUnsealShare
  PhysicalSealVault _ _ -> Just BootstrapVaultSeal
  PhysicalRotateUnlockBundle {} -> Just BootstrapVaultRotateUnlockBundle
  PhysicalRotateTransitKey _ _ -> Just BootstrapVaultRotateTransitKey
  PhysicalResetAmbiguousInitialization {} ->
    Just BootstrapVaultResetAmbiguousInitialization
  PhysicalCancelIncompleteGenerateRoot {} -> Just BootstrapVaultCancelGenerateRoot
  PhysicalInventoryRootAccessors {} -> Just BootstrapVaultInventoryRootAccessors
  PhysicalRevokeRootAccessor {} -> Just BootstrapVaultRevokeRootAccessor
  PhysicalProveRootAccessorsAbsent {} -> Just BootstrapVaultInventoryRootAccessors
  PhysicalStartGenerateRoot {} -> Just BootstrapVaultStartGenerateRoot
  PhysicalAwaitGeneratedRootCiphertext {} -> Just BootstrapVaultSubmitGenerateRootShare
  PhysicalLoginProvisioner {} -> Just BootstrapVaultLoginProvisioner
  PhysicalApplyProvisionerBaseline {} -> Just BootstrapVaultApplyBaseline
  PhysicalReadBackProvisionerBaseline {} -> Just BootstrapVaultReadBackBaseline
  PhysicalObservePostUnsealConsumer {} -> Nothing
  PhysicalObserveVaultPkiStatus _ -> Nothing
  PhysicalIssueVaultPkiTestCertificate {} -> Just BootstrapVaultIssueTestCertificate
  PhysicalCommitParentCustody {} -> Just BootstrapVaultCommitChildCustody
  PhysicalObserveChildRecoveryConsumption {} ->
    Just BootstrapVaultConsumeChildRecovery
  PhysicalConsumeChildRecovery {} -> Just BootstrapVaultConsumeChildRecovery
  PhysicalCancelChildIncompleteGenerateRoot {} -> Just BootstrapVaultCancelGenerateRoot
  PhysicalInventoryChildRootAccessors {} -> Just BootstrapVaultInventoryRootAccessors
  PhysicalRevokeChildRootAccessor {} -> Just BootstrapVaultRevokeRootAccessor
  PhysicalProveChildRootAccessorsAbsent {} -> Just BootstrapVaultInventoryRootAccessors
  PhysicalStartChildGenerateRoot {} -> Just BootstrapVaultStartGenerateRoot
  PhysicalAwaitChildGeneratedRootCiphertext {} -> Just BootstrapVaultSubmitGenerateRootShare

physicalCallSecretWorkerOperation
  :: BrokerPhysicalCall operation result -> Maybe SecretWorkerOperation
physicalCallSecretWorkerOperation call = case call of
  PhysicalPrepareRootInitRecipients {} -> Just SecretWorkerPrepareInitialization
  PhysicalResumeRootInitRecipients {} -> Just SecretWorkerResumeInitialization
  PhysicalInitializeVault {} -> Just SecretWorkerInitialize
  PhysicalSealFinalUnlockBundle {} -> Just SecretWorkerFinalizeInitialization
  PhysicalUnsealVault {} -> Just SecretWorkerUnseal
  PhysicalRotateUnlockBundle {} -> Just SecretWorkerRotateUnlockBundle
  PhysicalRotateTransitKey {} -> Just SecretWorkerRotateTransitKey
  _ -> Nothing

-- | Non-Vault exact boundary operations.  These constructors contain only
-- typed custody artifacts; no byte-returning crypto or generic store operation
-- is available to the controller.
data BrokerLocalCall result where
  LocalRecoverRootInitCall
    :: RootInitBinding
    -> BrokerLocalCall RootInitRecoveryObservation
  LocalAcknowledgeRecoveryCustody
    :: FinalUnlockBundle
    -> BrokerLocalCall RecoveryCustodyReceipt
  LocalCaptureChildEncryptedReceipt
    :: ChildCustodyBinding
    -> BrokerLocalCall ChildEncryptedReceipt
  LocalPrepareChildRecoveryDelivery
    :: ChildCustodyBinding
    -> DeliveryNonce
    -> ChildAttestation
    -> BrokerLocalCall ChildRecoveryDelivery

-- | Closed deterministic execution vocabulary used by loopback fixtures.
--
-- This is deliberately not a generic "return a result" escape hatch.  It
-- repeats the complete Broker route algebra, carries the same nominal
-- capability reference as the prepared program, and requires a freshly
-- authorized Vault or store permit for every mutating constructor.  The
-- production boundary leaves this interpreter absent and therefore executes
-- the physical custody drivers below.
data BrokerInMemoryCall (operation :: CapabilityKind) result where
  InMemoryHealth
    :: CapabilityRef 'VaultBootstrapObserve
    -> BrokerInMemoryCall 'VaultBootstrapObserve Bool
  InMemoryReadiness
    :: CapabilityRef 'VaultBootstrapObserve
    -> BrokerInMemoryCall 'VaultBootstrapObserve Bool
  InMemoryVaultStatus
    :: CapabilityRef 'VaultBootstrapObserve
    -> BrokerInMemoryCall 'VaultBootstrapObserve BootstrapStatus
  InMemoryVaultInitialize
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> PristineStorageProof
    -> BrokerInMemoryCall 'VaultBootstrapMutate RecoveryCustodyReceipt
  InMemoryVaultUnseal
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> RecoveryCustodyReceipt
    -> BrokerInMemoryCall 'VaultBootstrapMutate BootstrapMutationReceipt
  InMemoryVaultSeal
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> BrokerInMemoryCall 'VaultBootstrapMutate BootstrapMutationReceipt
  InMemoryVaultRotateUnlockBundle
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> RecoveryCustodyReceipt
    -> BrokerInMemoryCall 'VaultBootstrapMutate BootstrapMutationReceipt
  InMemoryVaultRotateTransitKey
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> BrokerInMemoryCall 'VaultBootstrapMutate BootstrapMutationReceipt
  InMemoryVaultBaselineReconcile
    :: CapabilityRef 'VaultBaselineReconcile
    -> BootstrapVaultEffectPermit
    -> RootSessionId
    -> RecoveryCustodyReceipt
    -> BrokerInMemoryCall 'VaultBaselineReconcile BaselineReadBackReceipt
  InMemoryVaultPkiStatus
    :: CapabilityRef 'VaultPkiOperate
    -> BrokerInMemoryCall 'VaultPkiOperate VaultPkiStatus
  InMemoryVaultPkiIssueTestCertificate
    :: CapabilityRef 'VaultPkiOperate
    -> BootstrapVaultEffectPermit
    -> PkiIssueRequest
    -> BrokerInMemoryCall 'VaultPkiOperate BootstrapMutationReceipt
  InMemoryVaultResetAmbiguousInitialization
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapStoreMutationPermit
    -> InitAmbiguity
    -> PristineResetProof
    -> BrokerInMemoryCall 'VaultBootstrapMutate BootstrapMutationReceipt
  InMemoryChildCustodyCommit
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapVaultEffectPermit
    -> ChildCustodyBinding
    -> BrokerInMemoryCall 'VaultBootstrapMutate ParentCustodyAcknowledgement
  InMemoryChildRecoveryDeliver
    :: CapabilityRef 'VaultBootstrapMutate
    -> BootstrapStoreMutationPermit
    -> ChildCustodyBinding
    -> DeliveryNonce
    -> ChildAttestation
    -> BrokerInMemoryCall 'VaultBootstrapMutate ChildRecoveryDelivery
  InMemoryChildRecoveryObserve
    :: CapabilityRef 'VaultBootstrapObserve
    -> ChildCustodyBinding
    -> DeliveryNonce
    -> BrokerInMemoryCall 'VaultBootstrapObserve (Maybe ChildRecoveryDelivery)

newtype BrokerInMemoryBoundary m = BrokerInMemoryBoundary
  { runBrokerInMemoryCall
      :: forall operation result
       . BrokerInMemoryCall operation result
      -> m (Either EngineBoundaryError result)
  }

-- | Composition boundary for the four operations whose secret ingress is
-- isolated in an attested, one-shot worker.  The physical call remains in the
-- same closed algebra, while the runner must consume the worker state produced
-- only after attestation and fresh fence authorization. The driver persists a
-- closed encrypted/sealed result with the exact receipt before cleanup; there
-- is deliberately no physical or volatile recovery callback.
data BrokerSecretWorkerBoundary m = BrokerSecretWorkerBoundary
  { brokerSecretWorkerDriverBoundary
      :: !(EngineSecretWorkerBoundary m EngineBoundaryError)
  , runBrokerSecretWorkerPhysicalCall
      :: forall scope operation result
       . SecretWorkerEffectPermit
      -> RunningSecretWorker scope
      %1 -> BrokerPhysicalCall operation result
      -> m
           ( Either
               EngineBoundaryError
               (ExecutedSecretWorker, RawSecretWorkerReceipt, result)
           )
  }

-- | All dependencies needed by the engine.  The rank-2 admission and begin
-- hooks see the same indexed reference and program stored in the private
-- prepared call.  A hook returns only a verdict; it cannot substitute another
-- reference into the admitted value.
data BrokerEngineBoundary m = BrokerEngineBoundary
  { engineEvidenceBoundary :: BrokerProgramEvidenceBoundary m
  , engineResolveRootInitCryptoParameters
      :: PristineStorageProof
      -> m (Either EngineBoundaryError RootInitCryptoParameters)
  , engineAdmitCapability
      :: forall operation result
       . CapabilityRef operation
      -> BrokerProgram operation result
      -> m (Either EngineBoundaryError ())
  , engineBeginCapabilityExecution
      :: forall operation result
       . CapabilityRef operation
      -> BrokerProgram operation result
      -> m (Either EngineBoundaryError ())
  , engineAcquireMutationFence
      :: forall operation
       . CapabilityRef operation
      -> BrokerRoute
      -> BrokerActionRequest
      -> RequestDigest
      -> Deadline
      -> m (Either EngineBoundaryError BootstrapSessionFence)
  , engineObserveFenceUse
      :: BootstrapSessionFence
      -> m (Either EngineBoundaryError EngineFenceUseObservation)
  , engineReleaseMutationFence
      :: BootstrapStoreMutationPermit
      -> BootstrapSessionFence
      -> m (Either EngineBoundaryError BootstrapFenceStoreObservation)
  , engineRunPhysicalCall
      :: forall operation result
       . BrokerPhysicalCall operation result
      -> m (Either EngineBoundaryError result)
  , engineRunLocalCall
      :: forall result
       . BrokerLocalCall result
      -> m (Either EngineBoundaryError result)
  , engineSecretWorkerBoundary :: Maybe (BrokerSecretWorkerBoundary m)
  , enginePgpBoundary :: Maybe (PgpBoundary m)
  , engineInMemoryBoundary :: Maybe (BrokerInMemoryBoundary m)
  , engineStoreBoundary :: BootstrapStoreBoundary m
  }

data BrokerEngine m = BrokerEngine
  { brokerEngineCapabilityRefs :: !BrokerCapabilityRefs
  , brokerEnginePlanLimit :: !Natural
  , brokerEngineBoundary :: !(BrokerEngineBoundary m)
  }

mkBrokerEngine
  :: BrokerCapabilityRefs
  -> Natural
  -> BrokerEngineBoundary m
  -> Either String (BrokerEngine m)
mkBrokerEngine capabilityRefs planLimit boundary
  | planLimit == 0 = Left "Bootstrap Broker engine plan limit must be positive"
  | planLimit > 256 = Left "Bootstrap Broker engine plan limit must not exceed 256"
  | otherwise = Right (BrokerEngine capabilityRefs planLimit boundary)

data AdmittedBrokerCall (operation :: CapabilityKind) result
  = AdmittedBrokerCall !(PreparedBrokerCall operation result)

data SomeAdmittedBrokerCall where
  SomeAdmittedBrokerCall
    :: AdmittedBrokerCall operation result
    -> SomeAdmittedBrokerCall

admitBrokerCall
  :: (Monad m)
  => BrokerEngine m
  -> SomePreparedBrokerCall
  -> m (Either BrokerEngineError SomeAdmittedBrokerCall)
admitBrokerCall engine (SomePreparedBrokerCall prepared) = do
  outcome <-
    engineAdmitCapability
      (brokerEngineBoundary engine)
      (preparedReference prepared)
      (preparedProgram prepared)
  pure $ case outcome of
    Left failure -> Left (EngineCapabilityAdmissionRefused failure)
    Right () -> Right (SomeAdmittedBrokerCall (AdmittedBrokerCall prepared))

admittedBrokerRoute :: SomeAdmittedBrokerCall -> BrokerRoute
admittedBrokerRoute (SomeAdmittedBrokerCall (AdmittedBrokerCall prepared)) =
  preparedRoute prepared

admittedBrokerCapabilityOp :: SomeAdmittedBrokerCall -> CapabilityOp
admittedBrokerCapabilityOp (SomeAdmittedBrokerCall (AdmittedBrokerCall prepared)) =
  refCapabilityOp (preparedReference prepared)

admittedBrokerCapabilityDigest :: SomeAdmittedBrokerCall -> CoordinateDigest
admittedBrokerCapabilityDigest (SomeAdmittedBrokerCall (AdmittedBrokerCall prepared)) =
  refCoordinateDigest (preparedReference prepared)

newtype EngineExecutionContext = EngineExecutionContext
  { engineExecutionDeadline :: Deadline
  }

mkEngineExecutionContext :: Deadline -> EngineExecutionContext
mkEngineExecutionContext = EngineExecutionContext

-- Responses ---------------------------------------------------------------

data BrokerResponse result where
  BrokerHealthResponse :: !Bool -> BrokerResponse Bool
  BrokerReadinessResponse :: !Bool -> BrokerResponse Bool
  BrokerVaultStatusResponse
    :: !BootstrapStatus -> BrokerResponse BootstrapStatus
  BrokerVaultInitializeResponse
    :: !RecoveryCustodyReceipt -> BrokerResponse RecoveryCustodyReceipt
  BrokerVaultUnsealResponse
    :: !BootstrapMutationReceipt -> BrokerResponse BootstrapMutationReceipt
  BrokerVaultSealResponse
    :: !BootstrapMutationReceipt -> BrokerResponse BootstrapMutationReceipt
  BrokerVaultRotateUnlockBundleResponse
    :: !BootstrapMutationReceipt -> BrokerResponse BootstrapMutationReceipt
  BrokerVaultRotateTransitKeyResponse
    :: !BootstrapMutationReceipt -> BrokerResponse BootstrapMutationReceipt
  BrokerVaultBaselineResponse
    :: !BaselineReadBackReceipt -> BrokerResponse BaselineReadBackReceipt
  BrokerVaultPkiStatusResponse
    :: !VaultPkiStatus -> BrokerResponse VaultPkiStatus
  BrokerVaultPkiIssueResponse
    :: !BootstrapMutationReceipt -> BrokerResponse BootstrapMutationReceipt
  BrokerVaultResetAmbiguityResponse
    :: !BootstrapMutationReceipt -> BrokerResponse BootstrapMutationReceipt
  BrokerChildCustodyResponse
    :: !ParentCustodyAcknowledgement
    -> BrokerResponse ParentCustodyAcknowledgement
  BrokerChildRecoveryDeliverResponse
    :: !ChildRecoveryDelivery -> BrokerResponse ChildRecoveryDelivery
  BrokerChildRecoveryObserveResponse
    :: !(Maybe ChildRecoveryDelivery)
    -> BrokerResponse (Maybe ChildRecoveryDelivery)

data SomeBrokerResponse where
  SomeBrokerResponse :: BrokerResponse result -> SomeBrokerResponse

brokerResponseRoute :: BrokerResponse result -> BrokerRoute
brokerResponseRoute response = case response of
  BrokerHealthResponse _ -> BrokerHealth
  BrokerReadinessResponse _ -> BrokerReadiness
  BrokerVaultStatusResponse _ -> BrokerVaultStatus
  BrokerVaultInitializeResponse _ -> BrokerVaultInitialize
  BrokerVaultUnsealResponse _ -> BrokerVaultUnseal
  BrokerVaultSealResponse _ -> BrokerVaultSeal
  BrokerVaultRotateUnlockBundleResponse _ -> BrokerVaultRotateUnlockBundle
  BrokerVaultRotateTransitKeyResponse _ -> BrokerVaultRotateTransitKey
  BrokerVaultBaselineResponse _ -> BrokerVaultBaselineReconcile
  BrokerVaultPkiStatusResponse _ -> BrokerVaultPkiStatus
  BrokerVaultPkiIssueResponse _ -> BrokerVaultPkiIssueTestCertificate
  BrokerVaultResetAmbiguityResponse _ -> BrokerVaultResetAmbiguousInitialization
  BrokerChildCustodyResponse _ -> BrokerChildCustodyCommit
  BrokerChildRecoveryDeliverResponse _ -> BrokerChildRecoveryDeliver
  BrokerChildRecoveryObserveResponse _ -> BrokerChildRecoveryObserve

encodeSomeBrokerResponse :: SomeBrokerResponse -> ByteString
encodeSomeBrokerResponse (SomeBrokerResponse response) = encodeBrokerResponse response

encodeBrokerResponse :: BrokerResponse result -> ByteString
encodeBrokerResponse = LazyByteString.toStrict . encode . responseObject
 where
  responseObject :: BrokerResponse responseResult -> Value
  responseObject response = case response of
    BrokerHealthResponse healthy ->
      object ["operation" .= ("health" :: Text), "healthy" .= healthy]
    BrokerReadinessResponse ready ->
      object ["operation" .= ("readiness" :: Text), "ready" .= ready]
    BrokerVaultStatusResponse status ->
      object
        [ "operation" .= ("vault_status" :: Text)
        , "initialized" .= bootstrapStatusInitialized status
        , "sealed" .= bootstrapStatusSealed status
        , "recovery_custody_durable"
            .= bootstrapStatusRecoveryCustodyDurable status
        , "initialization_ambiguous"
            .= bootstrapStatusInitializationAmbiguous status
        , "root_session_active" .= bootstrapStatusRootSessionActive status
        , "handoff_observed" .= bootstrapStatusHandoffObserved status
        ]
    BrokerVaultInitializeResponse receipt ->
      object
        [ "operation" .= ("vault_initialize" :: Text)
        , "storage_generation"
            .= renderVaultStorageGeneration
              (rootInitStorageGeneration (recoveryCustodyBinding receipt))
        , "recovery_custody_digest"
            .= renderArtifactDigest (recoveryCustodyAcknowledgementDigest receipt)
        ]
    BrokerVaultUnsealResponse receipt ->
      mutationObject "vault_unseal" receipt
    BrokerVaultSealResponse receipt ->
      mutationObject "vault_seal" receipt
    BrokerVaultRotateUnlockBundleResponse receipt ->
      mutationObject "vault_rotate_unlock_bundle" receipt
    BrokerVaultRotateTransitKeyResponse receipt ->
      mutationObject "vault_rotate_transit_key" receipt
    BrokerVaultBaselineResponse receipt ->
      object
        [ "operation" .= ("vault_baseline_reconcile" :: Text)
        , "storage_generation"
            .= renderVaultStorageGeneration (baselineReadBackStorageGeneration receipt)
        , "root_session_id" .= renderRootSessionId (baselineReadBackSessionId receipt)
        , "read_back_digest" .= renderArtifactDigest (baselineReadBackDigest receipt)
        ]
    BrokerVaultPkiStatusResponse status ->
      object
        [ "operation" .= ("vault_pki_status" :: Text)
        , "status" .= pkiStatusText status
        ]
    BrokerVaultPkiIssueResponse receipt ->
      mutationObject "vault_pki_issue_test_certificate" receipt
    BrokerVaultResetAmbiguityResponse receipt ->
      mutationObject "vault_reset_ambiguous_initialization" receipt
    BrokerChildCustodyResponse acknowledgement ->
      object
        [ "operation" .= ("child_custody_commit" :: Text)
        , "storage_generation"
            .= renderVaultStorageGeneration
              ( childCustodyStorageGeneration
                  (parentCustodyAcknowledgedBinding acknowledgement)
              )
        , "acknowledgement_digest"
            .= renderArtifactDigest (parentCustodyAcknowledgementDigest acknowledgement)
        ]
    BrokerChildRecoveryDeliverResponse delivery ->
      childDeliveryObject "child_recovery_deliver" delivery
    BrokerChildRecoveryObserveResponse Nothing ->
      object
        [ "operation" .= ("child_recovery_observe" :: Text)
        , "available" .= False
        ]
    BrokerChildRecoveryObserveResponse (Just delivery) ->
      childDeliveryObject "child_recovery_observe" delivery

  mutationObject :: Text -> BootstrapMutationReceipt -> Value
  mutationObject operation receipt =
    object
      [ "operation" .= (operation :: Text)
      , "changed" .= bootstrapMutationChanged receipt
      , "mutation_digest"
          .= renderArtifactDigest (bootstrapMutationDigest receipt)
      ]

  childDeliveryObject :: Text -> ChildRecoveryDelivery -> Value
  childDeliveryObject operation delivery =
    object
      [ "operation" .= (operation :: Text)
      , "available" .= True
      , "storage_generation"
          .= renderVaultStorageGeneration
            (childCustodyStorageGeneration (childRecoveryDeliveryBinding delivery))
      , "delivery_nonce" .= renderDeliveryNonce (childRecoveryDeliveryNonce delivery)
      , "delivery_digest"
          .= renderArtifactDigest (childRecoveryDeliveryDigest delivery)
      ]

  pkiStatusText :: VaultPkiStatus -> Text
  pkiStatusText status = case status of
    VaultPkiBaselineAbsent -> ("absent" :: Text)
    VaultPkiBaselineReady -> "ready"

-- Execution ---------------------------------------------------------------

executeBrokerCall
  :: (Monad m)
  => BrokerEngine m
  -> EngineExecutionContext
  -> SomeAdmittedBrokerCall
  -> m (Either BrokerEngineError SomeBrokerResponse)
executeBrokerCall engine context (SomeAdmittedBrokerCall (AdmittedBrokerCall prepared)) = do
  outcome <-
    executePrepared engine context prepared
  pure (SomeBrokerResponse <$> outcome)

executePrepared
  :: (Monad m)
  => BrokerEngine m
  -> EngineExecutionContext
  -> PreparedBrokerCall operation result
  -> m (Either BrokerEngineError (BrokerResponse result))
executePrepared engine context prepared = do
  beginOutcome <-
    engineBeginCapabilityExecution
      boundary
      (preparedReference prepared)
      (preparedProgram prepared)
  case beginOutcome of
    Left failure -> pure (Left (EngineCapabilityExecutionRefused failure))
    Right () -> case (brokerRouteIsMutation route, preparedAction prepared) of
      (False, _) -> executeWithAttempt Nothing
      (True, Just action) -> do
        storageObservation <- observePreparedStorage engine prepared action
        case storageObservation of
          Left failure -> pure (Left failure)
          Right () -> do
            acquired <-
              engineAcquireMutationFence
                boundary
                (preparedReference prepared)
                route
                action
                (preparedRequestDigest prepared)
                (engineExecutionDeadline context)
            case acquired of
              Left failure -> pure (Left (EngineFenceAcquireRefused failure))
              Right fence
                | fenceMatchesPrepared prepared action fence ->
                    executeWithAttempt (Just (MutationAttempt fence (engineExecutionDeadline context)))
                | otherwise -> pure (Left EngineFenceBindingMismatch)
      (True, Nothing) -> pure (Left EngineFenceBindingMismatch)
 where
  boundary = brokerEngineBoundary engine
  route = preparedRoute prepared

  executeWithAttempt attempt = do
    outcome <-
      executePreparedPlan engine attempt prepared
    case (attempt, outcome) of
      (Just mutationAttempt, Right response) -> do
        released <- releaseMutationFence engine mutationAttempt
        pure (response <$ released)
      (Just mutationAttempt, Left ambiguity@(EngineInitializationAmbiguous _)) -> do
        -- The init journal has already durably latched the applied-without-
        -- response ambiguity.  Retaining the unrelated request fence would
        -- deadlock the separately bound pristine-reset action until expiry;
        -- release only after that durable terminal transition is confirmed.
        released <- releaseMutationFence engine mutationAttempt
        pure $ case released of
          Left failure -> Left failure
          Right () -> Left ambiguity
      _ -> pure outcome

observePreparedStorage
  :: (Monad m)
  => BrokerEngine m
  -> PreparedBrokerCall operation result
  -> BrokerActionRequest
  -> m (Either BrokerEngineError ())
observePreparedStorage engine prepared action = do
  observed <-
    observeVaultStorageGeneration
      (engineStoreBoundary (brokerEngineBoundary engine))
  pure $ do
    binding <- either (Left . EngineStoreRefused) Right observed
    when
      (rootInitStorageGeneration binding /= brokerActionStorageGeneration action)
      (Left (EngineEvidenceGenerationMismatch (preparedRoute prepared)))
    validateExactBinding binding (preparedExecution prepared)
 where
  validateExactBinding
    :: RootInitBinding
    -> PreparedExecution preparedOperation preparedResult
    -> Either BrokerEngineError ()
  validateExactBinding observed execution = case execution of
    ExecuteVaultInitialize proof ->
      requireBinding observed (pristineStorageBinding proof)
    ExecuteVaultUnseal custody ->
      requireBinding observed (recoveryCustodyBinding custody)
    ExecuteVaultRotateUnlockBundle custody ->
      requireBinding observed (recoveryCustodyBinding custody)
    ExecuteVaultBaselineReconcile _ custody ->
      requireBinding observed (recoveryCustodyBinding custody)
    ExecuteVaultResetAmbiguousInitialization ambiguity _ ->
      requireBinding observed (ambiguousInitBinding ambiguity)
    _ -> Right ()

  requireBinding observed expected =
    when
      (observed /= expected)
      (Left (EngineResponseEvidenceMismatch (preparedRoute prepared)))

data MutationAttempt = MutationAttempt
  { mutationAttemptFence :: !BootstrapSessionFence
  , mutationAttemptRequestDeadline :: !Deadline
  }

fenceMatchesPrepared
  :: PreparedBrokerCall operation result
  -> BrokerActionRequest
  -> BootstrapSessionFence
  -> Bool
fenceMatchesPrepared prepared action fence =
  bootstrapFenceActionDigest fence == brokerActionDigest action
    && bootstrapFenceRequestDigest fence == preparedRequestDigest prepared
    && bootstrapFenceStorageGeneration fence == brokerActionStorageGeneration action

authorizeVaultCall
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> BootstrapVaultEffect
  -> m (Either BrokerEngineError BootstrapVaultEffectPermit)
authorizeVaultCall engine attempt effect = do
  observed <-
    engineObserveFenceUse (brokerEngineBoundary engine) (mutationAttemptFence attempt)
  pure $ do
    EngineFenceUseObservation
      { engineFenceMonotonicNow
      , engineFenceAuthorityClock
      , engineFenceStoreObservation
      , engineFenceLeaseObservation
      } <-
      either (Left . EngineFenceAcquireRefused) Right observed
    either
      (Left . EngineFenceUseRefused)
      Right
      ( authorizeBootstrapVaultEffect
          engineFenceMonotonicNow
          (mutationAttemptRequestDeadline attempt)
          engineFenceAuthorityClock
          (mutationAttemptFence attempt)
          engineFenceStoreObservation
          engineFenceLeaseObservation
          effect
      )

authorizeStoreCall
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> BootstrapStoreMutation
  -> m (Either BrokerEngineError BootstrapStoreMutationPermit)
authorizeStoreCall engine attempt mutation = do
  observed <-
    engineObserveFenceUse (brokerEngineBoundary engine) (mutationAttemptFence attempt)
  pure $ do
    EngineFenceUseObservation
      { engineFenceMonotonicNow
      , engineFenceAuthorityClock
      , engineFenceStoreObservation
      , engineFenceLeaseObservation
      } <-
      either (Left . EngineFenceAcquireRefused) Right observed
    either
      (Left . EngineFenceUseRefused)
      Right
      ( authorizeBootstrapStoreMutation
          engineFenceMonotonicNow
          (mutationAttemptRequestDeadline attempt)
          engineFenceAuthorityClock
          (mutationAttemptFence attempt)
          engineFenceStoreObservation
          engineFenceLeaseObservation
          mutation
      )

releaseMutationFence
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> m (Either BrokerEngineError ())
releaseMutationFence engine attempt = do
  authorized <-
    authorizeStoreCall engine attempt BootstrapStoreReleaseSessionFence
  case authorized of
    Left failure -> pure (Left failure)
    Right permit -> do
      released <-
        engineReleaseMutationFence
          (brokerEngineBoundary engine)
          permit
          (mutationAttemptFence attempt)
      pure $ do
        observation <- either (Left . EngineFenceAcquireRefused) Right released
        let expectedFloor =
              bootstrapFenceGenerationValue
                (bootstrapFenceGeneration (mutationAttemptFence attempt))
        case observation of
          -- A successful release retains the generation as an ABA floor.
          -- Other observations are never accepted as "probably released".
          BootstrapFenceStoreVacant floorValue
            | floorValue == expectedFloor -> Right ()
          _ -> Left EngineStoreReadBackMismatch

executeInMemoryPreparedPlan
  :: forall m operation result
   . (Monad m)
  => BrokerEngine m
  -> BrokerInMemoryBoundary m
  -> Maybe MutationAttempt
  -> PreparedBrokerCall operation result
  -> m (Either BrokerEngineError (BrokerResponse result))
executeInMemoryPreparedPlan engine boundary attempt prepared =
  case preparedExecution prepared of
    ExecuteHealth ->
      fmap BrokerHealthResponse
        <$> runInMemory boundary (InMemoryHealth reference)
    ExecuteReadiness ->
      fmap BrokerReadinessResponse
        <$> runInMemory boundary (InMemoryReadiness reference)
    ExecuteVaultStatus ->
      fmap BrokerVaultStatusResponse
        <$> runInMemory boundary (InMemoryVaultStatus reference)
    ExecuteVaultInitialize proof ->
      withMutationAttempt attempt $ \mutationAttempt -> do
        result <-
          runAuthorizedInMemoryVault
            engine
            boundary
            mutationAttempt
            BootstrapVaultInitialize
            (\permit -> InMemoryVaultInitialize reference permit proof)
        pure $ do
          receipt <- result
          when
            (recoveryCustodyBinding receipt /= pristineStorageBinding proof)
            (Left (EngineResponseEvidenceMismatch BrokerVaultInitialize))
          Right (BrokerVaultInitializeResponse receipt)
    ExecuteVaultUnseal custody ->
      executeMutation
        BootstrapVaultSubmitUnsealShare
        (\permit -> InMemoryVaultUnseal reference permit custody)
        BrokerVaultUnsealResponse
    ExecuteVaultSeal ->
      executeMutation
        BootstrapVaultSeal
        (InMemoryVaultSeal reference)
        BrokerVaultSealResponse
    ExecuteVaultRotateUnlockBundle custody ->
      executeMutation
        BootstrapVaultRotateUnlockBundle
        (\permit -> InMemoryVaultRotateUnlockBundle reference permit custody)
        BrokerVaultRotateUnlockBundleResponse
    ExecuteVaultRotateTransitKey ->
      executeMutation
        BootstrapVaultRotateTransitKey
        (InMemoryVaultRotateTransitKey reference)
        BrokerVaultRotateTransitKeyResponse
    ExecuteVaultBaselineReconcile sessionId custody ->
      withMutationAttempt attempt $ \mutationAttempt -> do
        result <-
          runAuthorizedInMemoryVault
            engine
            boundary
            mutationAttempt
            BootstrapVaultApplyBaseline
            ( \permit ->
                InMemoryVaultBaselineReconcile
                  reference
                  permit
                  sessionId
                  custody
            )
        pure $ do
          receipt <- result
          when
            ( baselineReadBackSessionId receipt /= sessionId
                || baselineReadBackStorageGeneration receipt
                  /= rootInitStorageGeneration (recoveryCustodyBinding custody)
            )
            (Left (EngineResponseEvidenceMismatch BrokerVaultBaselineReconcile))
          Right (BrokerVaultBaselineResponse receipt)
    ExecuteVaultPkiStatus ->
      fmap BrokerVaultPkiStatusResponse
        <$> runInMemory boundary (InMemoryVaultPkiStatus reference)
    ExecuteVaultPkiIssueTestCertificate request ->
      executeMutation
        BootstrapVaultIssueTestCertificate
        (\permit -> InMemoryVaultPkiIssueTestCertificate reference permit request)
        BrokerVaultPkiIssueResponse
    ExecuteVaultResetAmbiguousInitialization ambiguity resetProof ->
      withMutationAttempt attempt $ \mutationAttempt -> do
        result <-
          runAuthorizedInMemoryStore
            engine
            boundary
            mutationAttempt
            BootstrapStoreCasRootInitJournal
            ( \permit ->
                InMemoryVaultResetAmbiguousInitialization
                  reference
                  permit
                  ambiguity
                  resetProof
            )
        pure $ do
          receipt <- result
          validateMutationReceipt prepared receipt
          Right (BrokerVaultResetAmbiguityResponse receipt)
    ExecuteChildCustodyCommit binding ->
      withMutationAttempt attempt $ \mutationAttempt -> do
        result <-
          runAuthorizedInMemoryVault
            engine
            boundary
            mutationAttempt
            BootstrapVaultCommitChildCustody
            (\permit -> InMemoryChildCustodyCommit reference permit binding)
        pure $ do
          acknowledgement <- result
          when
            (parentCustodyAcknowledgedBinding acknowledgement /= binding)
            (Left (EngineResponseEvidenceMismatch BrokerChildCustodyCommit))
          Right (BrokerChildCustodyResponse acknowledgement)
    ExecuteChildRecoveryDeliver binding nonce attestation ->
      withMutationAttempt attempt $ \mutationAttempt -> do
        result <-
          runAuthorizedInMemoryStore
            engine
            boundary
            mutationAttempt
            BootstrapStoreCreateChildRecoveryDelivery
            ( \permit ->
                InMemoryChildRecoveryDeliver
                  reference
                  permit
                  binding
                  nonce
                  attestation
            )
        pure $ do
          delivery <- result
          unless
            (deliveryMatches binding nonce attestation delivery)
            (Left (EngineResponseEvidenceMismatch BrokerChildRecoveryDeliver))
          Right (BrokerChildRecoveryDeliverResponse delivery)
    ExecuteChildRecoveryObserve binding nonce -> do
      result <-
        runInMemory
          boundary
          (InMemoryChildRecoveryObserve reference binding nonce)
      pure $ do
        observed <- result
        case observed of
          Just delivery
            | childRecoveryDeliveryBinding delivery /= binding
                || childRecoveryDeliveryNonce delivery /= nonce ->
                Left (EngineResponseEvidenceMismatch BrokerChildRecoveryObserve)
          _ -> Right (BrokerChildRecoveryObserveResponse observed)
 where
  reference = preparedReference prepared

  executeMutation
    :: BootstrapVaultEffect
    -> ( BootstrapVaultEffectPermit
         -> BrokerInMemoryCall mutationOperation BootstrapMutationReceipt
       )
    -> (BootstrapMutationReceipt -> BrokerResponse BootstrapMutationReceipt)
    -> m (Either BrokerEngineError (BrokerResponse BootstrapMutationReceipt))
  executeMutation effect buildCall wrap =
    withMutationAttempt attempt $ \mutationAttempt -> do
      result <-
        runAuthorizedInMemoryVault
          engine
          boundary
          mutationAttempt
          effect
          buildCall
      pure $ do
        receipt <- result
        validateMutationReceipt prepared receipt
        Right (wrap receipt)

runInMemory
  :: (Monad m)
  => BrokerInMemoryBoundary m
  -> BrokerInMemoryCall operation result
  -> m (Either BrokerEngineError result)
runInMemory boundary call = do
  outcome <- runBrokerInMemoryCall boundary call
  pure (either (Left . EnginePhysicalCallRefused) Right outcome)

runAuthorizedInMemoryVault
  :: (Monad m)
  => BrokerEngine m
  -> BrokerInMemoryBoundary m
  -> MutationAttempt
  -> BootstrapVaultEffect
  -> (BootstrapVaultEffectPermit -> BrokerInMemoryCall operation result)
  -> m (Either BrokerEngineError result)
runAuthorizedInMemoryVault engine boundary attempt effect buildCall = do
  authorized <- authorizeVaultCall engine attempt effect
  case authorized of
    Left failure -> pure (Left failure)
    Right permit -> runInMemory boundary (buildCall permit)

runAuthorizedInMemoryStore
  :: (Monad m)
  => BrokerEngine m
  -> BrokerInMemoryBoundary m
  -> MutationAttempt
  -> BootstrapStoreMutation
  -> (BootstrapStoreMutationPermit -> BrokerInMemoryCall operation result)
  -> m (Either BrokerEngineError result)
runAuthorizedInMemoryStore engine boundary attempt mutation buildCall = do
  authorized <- authorizeStoreCall engine attempt mutation
  case authorized of
    Left failure -> pure (Left failure)
    Right permit -> runInMemory boundary (buildCall permit)

executePreparedPlan
  :: (Monad m)
  => BrokerEngine m
  -> Maybe MutationAttempt
  -> PreparedBrokerCall operation result
  -> m (Either BrokerEngineError (BrokerResponse result))
executePreparedPlan engine attempt prepared =
  case engineInMemoryBoundary (brokerEngineBoundary engine) of
    Just boundary -> executeInMemoryPreparedPlan engine boundary attempt prepared
    Nothing -> executePhysicalPreparedPlan engine attempt prepared

executePhysicalPreparedPlan
  :: (Monad m)
  => BrokerEngine m
  -> Maybe MutationAttempt
  -> PreparedBrokerCall operation result
  -> m (Either BrokerEngineError (BrokerResponse result))
executePhysicalPreparedPlan engine attempt prepared =
  case preparedExecution prepared of
    ExecuteHealth -> do
      result <- runPhysical engine (PhysicalHealth reference)
      pure (BrokerHealthResponse <$> result)
    ExecuteReadiness -> do
      result <- runPhysical engine (PhysicalReadiness reference)
      pure (BrokerReadinessResponse <$> result)
    ExecuteVaultStatus -> do
      result <- runPhysical engine (PhysicalObserveVaultStatus reference)
      pure (BrokerVaultStatusResponse <$> result)
    ExecuteVaultInitialize proof ->
      withMutationAttempt attempt $ \mutationAttempt -> do
        result <- driveRootInitialization engine mutationAttempt reference proof
        pure (BrokerVaultInitializeResponse <$> result)
    ExecuteVaultUnseal custody ->
      withMutationAttempt attempt $ \mutationAttempt -> do
        result <-
          runAuthorizedSecretWorkerPhysical
            engine
            mutationAttempt
            BootstrapVaultSubmitUnsealShare
            (\permit -> PhysicalUnsealVault reference permit custody)
        case result >>= \receipt -> validateMutationReceipt prepared receipt >> Right receipt of
          Left failure -> pure (Left failure)
          Right receipt -> do
            handoff <-
              drivePostUnsealHandoff
                engine
                mutationAttempt
                reference
                (recoveryCustodyBinding custody)
            pure (BrokerVaultUnsealResponse receipt <$ handoff)
    ExecuteVaultSeal ->
      withMutationAttempt attempt $ \mutationAttempt -> do
        result <-
          runAuthorizedPhysical
            engine
            mutationAttempt
            BootstrapVaultSeal
            (PhysicalSealVault reference)
        pure $ do
          receipt <- result
          validateMutationReceipt prepared receipt
          Right (BrokerVaultSealResponse receipt)
    ExecuteVaultRotateUnlockBundle custody ->
      withMutationAttempt attempt $ \mutationAttempt -> do
        result <-
          runAuthorizedSecretWorkerPhysical
            engine
            mutationAttempt
            BootstrapVaultRotateUnlockBundle
            (\permit -> PhysicalRotateUnlockBundle reference permit custody)
        pure $ do
          receipt <- result
          validateMutationReceipt prepared receipt
          Right (BrokerVaultRotateUnlockBundleResponse receipt)
    ExecuteVaultRotateTransitKey ->
      withMutationAttempt attempt $ \mutationAttempt -> do
        result <-
          runAuthorizedSecretWorkerPhysical
            engine
            mutationAttempt
            BootstrapVaultRotateTransitKey
            (PhysicalRotateTransitKey reference)
        pure $ do
          receipt <- result
          validateMutationReceipt prepared receipt
          Right (BrokerVaultRotateTransitKeyResponse receipt)
    ExecuteVaultBaselineReconcile sessionId custody ->
      withMutationAttempt attempt $ \mutationAttempt -> do
        handoff <-
          requireObservedPostUnsealHandoff
            engine
            (recoveryCustodyBinding custody)
        case handoff of
          Left failure -> pure (Left failure)
          Right () -> do
            result <-
              driveRootSession engine mutationAttempt reference sessionId custody
            pure (BrokerVaultBaselineResponse <$> result)
    ExecuteVaultPkiStatus -> do
      result <- runPhysical engine (PhysicalObserveVaultPkiStatus reference)
      pure (BrokerVaultPkiStatusResponse <$> result)
    ExecuteVaultPkiIssueTestCertificate request ->
      withMutationAttempt attempt $ \mutationAttempt -> do
        result <-
          runAuthorizedPhysical
            engine
            mutationAttempt
            BootstrapVaultIssueTestCertificate
            (\permit -> PhysicalIssueVaultPkiTestCertificate reference permit request)
        pure $ do
          receipt <- result
          validateMutationReceipt prepared receipt
          Right (BrokerVaultPkiIssueResponse receipt)
    ExecuteVaultResetAmbiguousInitialization ambiguity resetProof ->
      withMutationAttempt attempt $ \mutationAttempt -> do
        let preparedDigest = preparedActionDigest prepared
        case preparedDigest of
          Nothing -> pure (Left EngineFenceBindingMismatch)
          Just actionDigest -> do
            result <-
              resetAmbiguousInitialization
                engine
                mutationAttempt
                reference
                ambiguity
                resetProof
                actionDigest
            pure (BrokerVaultResetAmbiguityResponse <$> result)
    ExecuteChildCustodyCommit binding ->
      withMutationAttempt attempt $ \mutationAttempt -> do
        result <- driveChildCustody engine mutationAttempt reference binding
        pure (BrokerChildCustodyResponse <$> result)
    ExecuteChildRecoveryDeliver binding nonce attestation ->
      withMutationAttempt attempt $ \mutationAttempt -> do
        result <-
          prepareChildRecoveryDelivery
            engine
            mutationAttempt
            reference
            binding
            nonce
            attestation
        pure (BrokerChildRecoveryDeliverResponse <$> result)
    ExecuteChildRecoveryObserve binding nonce -> do
      result <- observeChildRecoveryDelivery engine binding nonce
      pure (BrokerChildRecoveryObserveResponse <$> result)
 where
  reference = preparedReference prepared

withMutationAttempt
  :: (Applicative m)
  => Maybe MutationAttempt
  -> (MutationAttempt -> m (Either BrokerEngineError result))
  -> m (Either BrokerEngineError result)
withMutationAttempt attempt continue = case attempt of
  Just mutationAttempt -> continue mutationAttempt
  Nothing -> pure (Left EngineFenceBindingMismatch)

runPhysical
  :: (Monad m)
  => BrokerEngine m
  -> BrokerPhysicalCall operation result
  -> m (Either BrokerEngineError result)
runPhysical engine call = do
  outcome <- engineRunPhysicalCall (brokerEngineBoundary engine) call
  pure (either (Left . EnginePhysicalCallRefused) Right outcome)

runLocal
  :: (Monad m)
  => BrokerEngine m
  -> BrokerLocalCall result
  -> m (Either BrokerEngineError result)
runLocal engine call = do
  outcome <- engineRunLocalCall (brokerEngineBoundary engine) call
  pure (either (Left . EnginePhysicalCallRefused) Right outcome)

runAuthorizedPhysical
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> BootstrapVaultEffect
  -> (BootstrapVaultEffectPermit -> BrokerPhysicalCall operation result)
  -> m (Either BrokerEngineError result)
runAuthorizedPhysical engine attempt effect buildCall = do
  authorized <- authorizeVaultCall engine attempt effect
  case authorized of
    Left failure -> pure (Left failure)
    Right permit -> runPhysical engine (buildCall permit)

runAuthorizedSecretWorkerPhysical
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> BootstrapVaultEffect
  -> (BootstrapVaultEffectPermit -> BrokerPhysicalCall operation result)
  -> m (Either BrokerEngineError result)
runAuthorizedSecretWorkerPhysical engine attempt effect buildCall = do
  authorized <- authorizeVaultCall engine attempt effect
  case authorized of
    Left failure -> pure (Left failure)
    Right permit ->
      let call = buildCall permit
       in case ( physicalCallVaultEffect call
               , physicalCallSecretWorkerOperation call
               , engineSecretWorkerBoundary (brokerEngineBoundary engine)
               ) of
            (Just observedEffect, Just operation, Just workerBoundary)
              | observedEffect == effect -> do
                  driven <-
                    driveSecretWorker
                      (brokerSecretWorkerDriverBoundary workerBoundary)
                      SecretWorkerControllerRestarted
                      operation
                      (mutationAttemptFence attempt)
                      ( do
                          reauthorized <- authorizeVaultCall engine attempt effect
                          pure $ case reauthorized of
                            Left _ ->
                              Left
                                ( EngineBoundaryRefused
                                    "fresh secret-worker fence authorization refused"
                                )
                            Right physicalPermit -> Right physicalPermit
                      )
                      ( \physicalPermit workerPermit running ->
                          let physicalCall = buildCall physicalPermit
                           in if physicalCallVaultEffect physicalCall == Just effect
                                && physicalCallSecretWorkerOperation physicalCall
                                  == Just operation
                                then case workerBoundary of
                                  BrokerSecretWorkerBoundary
                                    { runBrokerSecretWorkerPhysicalCall =
                                      runPhysicalWorker
                                    } ->
                                      runPhysicalWorker
                                        workerPermit
                                        running
                                        physicalCall
                                else
                                  finishSecretWorkerExecution
                                    workerPermit
                                    ( pure
                                        ( Left
                                            ( EngineBoundaryRefused
                                                "secret-worker physical call binding changed"
                                            )
                                        )
                                    )
                                    running
                      )
                      (encodeSecretWorkerPhysicalResult call)
                      ( \receipt durableResult ->
                          pure
                            ( decodeSecretWorkerPhysicalResult
                                call
                                receipt
                                durableResult
                            )
                      )
                  pure $ case driven of
                    Left failure -> Left (EngineSecretWorkerRefused failure)
                    Right (_, result) -> Right result
            (Just observedEffect, Just _, Nothing)
              | observedEffect == effect ->
                  pure (Left EngineSecretWorkerBoundaryUnavailable)
            _ -> pure (Left EngineSecretWorkerCallMismatch)

-- | Close every worker result over the exact physical call before the
-- receipt/result pair can enter the fixed durable checkpoint. No plaintext
-- password, recovered share, generated token, or ingress capability is a
-- member of 'SecretWorkerDurableResult'.
encodeSecretWorkerPhysicalResult
  :: BrokerPhysicalCall operation result
  -> result
  -> Either EngineBoundaryError SecretWorkerDurableResult
encodeSecretWorkerPhysicalResult call result = case call of
  PhysicalPrepareRootInitRecipients _ _ proof parameters -> do
    _ <- either (const resultMismatch) Right (validateRecipients proof parameters result)
    Right (preparedInitializationWorkerResult result)
  PhysicalResumeRootInitRecipients _ _ envelope compiledBurn -> do
    requireWorkerResult
      ( preparedRecoveryEnvelope (preparedInitRecoveryRecipient result)
          == envelope
          && compiledBurnMatches compiledBurn result
      )
    Right (resumedInitializationWorkerResult result)
  PhysicalInitializeVault _ _ recipients -> case result of
    RootInitEncryptedResponse receipt -> do
      let envelope =
            preparedRecoveryEnvelope (preparedInitRecoveryRecipient recipients)
      requireWorkerResult
        ( encryptedResponseBinding receipt == preparedInitBinding envelope
            && encryptedResponseSchemaVersion receipt
              == preparedInitSchemaVersion envelope
            && encryptedResponseRecipientCommitment receipt
              == preparedInitRecipientCommitment envelope
        )
      Right (encryptedInitializationWorkerResult receipt)
    RootInitAppliedWithoutResponse ->
      Right ambiguousInitializationWorkerResult
  PhysicalSealFinalUnlockBundle _ _ recipients response -> do
    let envelope =
          preparedRecoveryEnvelope (preparedInitRecoveryRecipient recipients)
        commitment = encryptedResponseRecipientCommitment response
    requireWorkerResult
      ( preparedInitBinding envelope == encryptedResponseBinding response
          && preparedInitSchemaVersion envelope
            == encryptedResponseSchemaVersion response
          && preparedInitRecipientCommitment envelope == commitment
          && finalUnlockBundleBinding result == encryptedResponseBinding response
          && finalUnlockBundleSchemaVersion result
            == encryptedResponseSchemaVersion response
          && finalUnlockBundleShareCount result
            == initRecipientShareCount commitment
          && finalUnlockBundleThreshold result
            == initRecipientThreshold commitment
      )
    Right (finalizedInitializationWorkerResult result)
  PhysicalUnsealVault _ permit _ -> do
    requireMutationResult permit result
    Right (unsealWorkerResult result)
  PhysicalRotateUnlockBundle _ permit _ -> do
    requireMutationResult permit result
    Right (unlockRotationWorkerResult result)
  PhysicalRotateTransitKey _ permit -> do
    requireMutationResult permit result
    Right (transitRotationWorkerResult result)
  _ -> resultMismatch
 where
  resultMismatch =
    Left (EngineBoundaryRefused "secret-worker durable result binding mismatch")

  requireWorkerResult condition = unless condition resultMismatch

  requireMutationResult permit receipt =
    requireWorkerResult
      ( bootstrapMutationDigest receipt
          == vaultEffectPermitActionDigest permit
      )

-- | Decode only the result retained with this exact worker receipt. The
-- operation constructor is checked first, then the full call-specific encoder
-- is rerun so stale proof/schema/commitment/fence bindings cannot be relabelled
-- during restart.
decodeSecretWorkerPhysicalResult
  :: BrokerPhysicalCall operation result
  -> SecretWorkerReceipt
  -> SecretWorkerDurableResult
  -> Either EngineBoundaryError result
decodeSecretWorkerPhysicalResult call receipt durableResult = do
  case physicalCallSecretWorkerOperation call of
    Just expectedOperation ->
      requireResult
        (secretWorkerReceiptOperation receipt == expectedOperation)
    Nothing -> resultMismatch
  decoded <- case call of
    PhysicalPrepareRootInitRecipients {} ->
      requireProjection (durablePreparedInitialization durableResult)
    PhysicalResumeRootInitRecipients {} ->
      requireProjection (durableResumedInitialization durableResult)
    PhysicalInitializeVault {}
      | durableInitializationIsAmbiguous durableResult ->
          Right RootInitAppliedWithoutResponse
      | otherwise ->
          RootInitEncryptedResponse
            <$> requireProjection
              (durableEncryptedInitialization durableResult)
    PhysicalSealFinalUnlockBundle {} ->
      requireProjection (durableFinalizedInitialization durableResult)
    PhysicalUnsealVault {} ->
      requireProjection (durableUnsealResult durableResult)
    PhysicalRotateUnlockBundle {} ->
      requireProjection (durableUnlockRotationResult durableResult)
    PhysicalRotateTransitKey {} ->
      requireProjection (durableTransitRotationResult durableResult)
    _ -> resultMismatch
  encoded <- encodeSecretWorkerPhysicalResult call decoded
  requireResult (encoded == durableResult)
  Right decoded
 where
  resultMismatch =
    Left (EngineBoundaryRefused "secret-worker durable result recovery mismatch")
  requireResult condition = unless condition resultMismatch
  requireProjection = maybe resultMismatch Right

compiledBurnMatches
  :: CompiledBurnRecipient -> PreparedInitRecipients -> Bool
compiledBurnMatches compiled recipients =
  preparedInitBurnPublicKeyBase64 recipients
    == Settings.burnRecipientPublicKeyBase64 compiled
    && Text.toCaseFold
      ( renderBurnRecipientFingerprint
          (verifiedBurnRecipientFingerprint verified)
      )
      == Text.toCaseFold
        ( Settings.unBurnRecipientFingerprint
            (Settings.burnRecipientFingerprint compiled)
        )
    && Text.toLower
      (renderArtifactDigest (verifiedBurnRecipientPublicKeyDigest verified))
      == compiledDigest
    && Text.toLower
      ( renderArtifactDigest
          ( initRecipientBurnPublicKeyDigest
              ( preparedInitRecipientCommitment
                  (preparedRecoveryEnvelope (preparedInitRecoveryRecipient recipients))
              )
          )
      )
      == compiledDigest
 where
  verified = preparedInitVerifiedBurnRecipient recipients
  configuredDigest =
    Text.toLower
      ( Settings.unBurnRecipientPublicKeyDigest
          (Settings.burnRecipientPublicKeyDigest compiled)
      )
  compiledDigest =
    maybe configuredDigest id (Text.stripPrefix "sha256:" configuredDigest)

preparedActionDigest
  :: PreparedBrokerCall operation result -> Maybe ArtifactDigest
preparedActionDigest = fmap brokerActionDigest . preparedAction

validateMutationReceipt
  :: PreparedBrokerCall operation result
  -> BootstrapMutationReceipt
  -> Either BrokerEngineError ()
validateMutationReceipt prepared receipt =
  case preparedActionDigest prepared of
    Nothing -> Left EngineMutationReceiptMismatch
    Just expectedDigest ->
      when
        (bootstrapMutationDigest receipt /= expectedDigest)
        (Left EngineMutationReceiptMismatch)

-- Store helpers -----------------------------------------------------------

writeResultVersion
  :: (Eq value)
  => value
  -> StoreWriteResult value
  -> Either BrokerEngineError StoreVersion
writeResultVersion expected result = case result of
  StoreWriteApplied version _ observed
    | observed == expected -> Right version
    | otherwise -> Left EngineStoreReadBackMismatch
  StoreWriteConflict (StoreObjectPresent version _ observed)
    | observed == expected -> Right version
    | otherwise -> Left EngineStoreVersionConflict
  StoreWriteConflict StoreObjectAbsent -> Left EngineStoreVersionConflict

storeReadResult
  :: Either StoreBoundaryError value -> Either BrokerEngineError value
storeReadResult = either (Left . EngineStoreRefused) Right

withStorePermit
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> BootstrapStoreMutation
  -> (BootstrapStoreMutationPermit -> m (Either StoreBoundaryError result))
  -> m (Either BrokerEngineError result)
withStorePermit engine attempt mutation action = do
  authorized <- authorizeStoreCall engine attempt mutation
  case authorized of
    Left failure -> pure (Left failure)
    Right permit -> storeReadResult <$> action permit

-- Post-unseal handoff -----------------------------------------------------

drivePostUnsealHandoff
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> CapabilityRef 'VaultBootstrapMutate
  -> RootInitBinding
  -> m (Either BrokerEngineError PostUnsealHandoffReceipt)
drivePostUnsealHandoff engine attempt reference binding = do
  loaded <- loadOrCreatePostUnsealHandoff engine attempt binding
  case loaded of
    Left failure -> pure (Left failure)
    Right (version, state) -> handoffLoop 0 version state
 where
  limit = brokerEnginePlanLimit engine

  handoffLoop steps version state
    | steps >= limit = pure (Left EngineCustodyPlanLimitExceeded)
    | otherwise = case planPostUnsealHandoff state of
        PostUnsealHandoffPlanArmObservation generation
          | generation /= rootInitStorageGeneration binding ->
              pure (Left (EngineResponseEvidenceMismatch BrokerVaultUnseal))
          | otherwise ->
              advanceHandoff
                steps
                version
                state
                ArmPostUnsealHandoffObservation
        PostUnsealHandoffPlanObserveConsumer generation consumer
          | generation /= rootInitStorageGeneration binding ->
              pure (Left (EngineResponseEvidenceMismatch BrokerVaultUnseal))
          | otherwise -> do
              observed <-
                runPhysical
                  engine
                  (PhysicalObservePostUnsealConsumer reference binding consumer)
              case observed of
                Left failure -> pure (Left failure)
                Right Nothing ->
                  pure
                    ( Left
                        ( EnginePhysicalCallRefused
                            (EngineBoundaryUnavailable "post-unseal consumer is not observed")
                        )
                    )
                Right (Just receipt)
                  | postUnsealHandoffGeneration receipt == generation
                      && postUnsealHandoffConsumer receipt == consumer ->
                      advanceHandoff
                        steps
                        version
                        state
                        (ConfirmPostUnsealHandoffObserved receipt)
                  | otherwise ->
                      pure (Left (EngineResponseEvidenceMismatch BrokerVaultUnseal))
        PostUnsealHandoffPlanComplete receipt
          | postUnsealHandoffGeneration receipt
              == rootInitStorageGeneration binding
              && postUnsealHandoffConsumer receipt
                == PostUnsealLifecycleAuthority ->
              pure (Right receipt)
          | otherwise ->
              pure (Left (EngineResponseEvidenceMismatch BrokerVaultUnseal))

  advanceHandoff steps version state command =
    case applyPostUnsealHandoffCommand state command of
      Left failure ->
        pure (Left (EngineCustodyTransitionRefused (Text.pack (show failure))))
      Right nextState -> do
        persisted <-
          persistPostUnsealHandoff
            engine
            attempt
            version
            nextState
        case persisted of
          Left failure -> pure (Left failure)
          Right nextVersion ->
            handoffLoop (steps + 1) nextVersion nextState

loadOrCreatePostUnsealHandoff
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> RootInitBinding
  -> m (Either BrokerEngineError (StoreVersion, PostUnsealHandoffState))
loadOrCreatePostUnsealHandoff engine attempt binding = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
      state = newPostUnsealHandoffState (rootInitStorageGeneration binding)
  loaded <- readPostUnsealHandoff store binding
  case storeReadResult loaded of
    Left failure -> pure (Left failure)
    Right (StoreObjectPresent version _ observed)
      | postUnsealHandoffStateGeneration observed
          == rootInitStorageGeneration binding ->
          pure (Right (version, observed))
      | otherwise -> pure (Left EngineStoreReadBackMismatch)
    Right StoreObjectAbsent -> do
      created <-
        withStorePermit
          engine
          attempt
          BootstrapStoreCreatePostUnsealHandoff
          (\permit -> createPostUnsealHandoff store permit state)
      pure $ do
        result <- created
        version <- writeResultVersion state result
        Right (version, state)

persistPostUnsealHandoff
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> StoreVersion
  -> PostUnsealHandoffState
  -> m (Either BrokerEngineError StoreVersion)
persistPostUnsealHandoff engine attempt version state = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
  persisted <-
    withStorePermit
      engine
      attempt
      BootstrapStoreCasPostUnsealHandoff
      (\permit -> casPostUnsealHandoff store permit version state)
  pure (persisted >>= writeResultVersion state)

requireObservedPostUnsealHandoff
  :: (Monad m)
  => BrokerEngine m
  -> RootInitBinding
  -> m (Either BrokerEngineError ())
requireObservedPostUnsealHandoff engine binding = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
  observed <- readPostUnsealHandoff store binding
  pure $ case storeReadResult observed of
    Left failure -> Left failure
    Right StoreObjectAbsent -> Left EngineStoreReadBackMismatch
    Right (StoreObjectPresent _ _ state) ->
      case planPostUnsealHandoff state of
        PostUnsealHandoffPlanComplete receipt
          | postUnsealHandoffGeneration receipt
              == rootInitStorageGeneration binding
              && postUnsealHandoffConsumer receipt
                == PostUnsealLifecycleAuthority ->
              Right ()
          | otherwise -> Left EngineStoreReadBackMismatch
        _ -> Left EngineStoreReadBackMismatch

-- Root initialization custody --------------------------------------------

driveRootInitialization
  :: forall m
   . (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> CapabilityRef 'VaultBootstrapMutate
  -> PristineStorageProof
  -> m (Either BrokerEngineError RecoveryCustodyReceipt)
driveRootInitialization engine attempt reference proof = do
  loaded <- loadOrCreateRootInitJournal engine attempt proof
  case loaded of
    Left failure -> pure (Left failure)
    Right (version, state) -> rootLoop 0 version state
 where
  store = engineStoreBoundary (brokerEngineBoundary engine)
  limit = brokerEnginePlanLimit engine

  rootLoop steps version state
    | steps >= limit = pure (Left EngineCustodyPlanLimitExceeded)
    | otherwise = case planRootInit state of
        RootPlanGenerateAndSealPreparedEnvelope pristine -> do
          generated <-
            prepareRootInitRecipients
              engine
              attempt
              reference
              pristine
          advanceRoot
            steps
            version
            state
            (preparedRecoveryEnvelope . preparedInitRecoveryRecipient <$> generated)
            PrepareRootInitEnvelope
        RootPlanWritePreparedEnvelope prepared -> do
          stored <- createPreparedEnvelope engine attempt prepared
          case stored of
            Left failure -> pure (Left failure)
            Right () -> advanceRoot steps version state (Right ()) (const RecordPreparedInitWrite)
        RootPlanReadBackPreparedEnvelope expected -> do
          observed <- readPreparedInitEnvelope store (preparedInitBinding expected)
          case storeReadResult observed of
            Left failure -> pure (Left failure)
            Right (StoreObjectPresent _ _ actual)
              | actual == expected ->
                  advanceRoot
                    steps
                    version
                    state
                    (Right actual)
                    ConfirmPreparedInitReadBack
              | otherwise -> pure (Left EngineStoreReadBackMismatch)
            Right StoreObjectAbsent -> pure (Left EngineStoreReadBackMismatch)
        RootPlanArmVaultInitCall _ ->
          advanceRoot steps version state (Right ()) (const ArmRootVaultInitCall)
        RootPlanCallVaultInit prepared -> do
          resumed <-
            resumeRootInitRecipients
              engine
              attempt
              reference
              proof
              prepared
          case resumed of
            Left failure -> pure (Left failure)
            Right recipients -> do
              armed <- transitionAndPersistRoot engine attempt version state RecordRootVaultInitCallStarted
              case armed of
                Left failure -> pure (Left failure)
                Right (armedVersion, armedState) -> do
                  called <-
                    runAuthorizedSecretWorkerPhysical
                      engine
                      attempt
                      BootstrapVaultInitialize
                      (\permit -> PhysicalInitializeVault reference permit recipients)
                  case called of
                    Left failure -> pure (Left failure)
                    Right (RootInitEncryptedResponse receipt) -> do
                      advanced <-
                        transitionAndPersistRoot
                          engine
                          attempt
                          armedVersion
                          armedState
                          (CaptureEncryptedInitResponse receipt)
                      continueRoot steps advanced
                    Right RootInitAppliedWithoutResponse ->
                      persistRootAmbiguity armedVersion armedState
        RootPlanAwaitVaultInitResponse binding -> do
          recovered <- runLocal engine (LocalRecoverRootInitCall binding)
          case recovered of
            Left failure -> pure (Left failure)
            Right recoveredResult ->
              case rootInitStatePhase state of
                RootInitCallInFlight prepared ->
                  case authoritativeRootInitWorkerResult
                    prepared
                    recoveredResult of
                    Left failure -> pure (Left failure)
                    Right durableResult ->
                      case engineSecretWorkerBoundary
                        (brokerEngineBoundary engine) of
                        Nothing ->
                          pure (Left EngineSecretWorkerBoundaryUnavailable)
                        Just workerBoundary -> do
                          reconciled <-
                            reconcileAuthoritativeSecretWorkerResult
                              ( brokerSecretWorkerDriverBoundary
                                  workerBoundary
                              )
                              SecretWorkerControllerRestarted
                              SecretWorkerInitialize
                              (mutationAttemptFence attempt)
                              durableResult
                          case reconciled of
                            Left failure ->
                              pure (Left (EngineSecretWorkerRefused failure))
                            Right () -> case recoveredResult of
                              RootInitRecoveredResponse receipt ->
                                advanceRoot
                                  steps
                                  version
                                  state
                                  (Right receipt)
                                  CaptureEncryptedInitResponse
                              RootInitRecoveredAmbiguity ->
                                persistRootAmbiguity version state
                _ ->
                  pure
                    ( Left
                        ( EngineCustodyTransitionRefused
                            "root init recovery outside in-flight phase"
                        )
                    )
        RootPlanWriteEncryptedResponse receipt -> do
          stored <- createEncryptedResponse engine attempt receipt
          case stored of
            Left failure -> pure (Left failure)
            Right () ->
              advanceRoot
                steps
                version
                state
                (Right ())
                (const RecordEncryptedInitResponseWrite)
        RootPlanReadBackEncryptedResponse expected -> do
          observed <- readEncryptedInitResponse store (encryptedResponseBinding expected)
          case storeReadResult observed of
            Left failure -> pure (Left failure)
            Right (StoreObjectPresent _ _ actual)
              | actual == expected ->
                  advanceRoot
                    steps
                    version
                    state
                    (Right actual)
                    ConfirmEncryptedInitResponseReadBack
              | otherwise -> pure (Left EngineStoreReadBackMismatch)
            Right StoreObjectAbsent -> pure (Left EngineStoreReadBackMismatch)
        RootPlanDecryptSharesAndSealFinalBundle receipt -> do
          sealed <-
            sealRootInitFinalUnlockBundle
              engine
              attempt
              reference
              proof
              receipt
          advanceRoot steps version state sealed PrepareFinalUnlockBundle
        RootPlanPromoteFinalBundle bundle -> do
          promoted <- promoteFinalBundle engine attempt state bundle
          case promoted of
            Left failure -> pure (Left failure)
            Right () ->
              advanceRoot
                steps
                version
                state
                (Right ())
                (const RecordFinalUnlockBundlePromotion)
        RootPlanReadBackFinalBundle expected -> do
          observed <- readFinalUnlockBundle store (finalUnlockBundleBinding expected)
          case storeReadResult observed of
            Left failure -> pure (Left failure)
            Right (StoreObjectPresent _ _ actual)
              | actual == expected ->
                  advanceRoot
                    steps
                    version
                    state
                    (Right actual)
                    ConfirmFinalUnlockBundleReadBack
              | otherwise -> pure (Left EngineStoreReadBackMismatch)
            Right StoreObjectAbsent -> pure (Left EngineStoreReadBackMismatch)
        RootPlanDeletePreparedEnvelope prepared ->
          case rootInitStatePhase state of
            RootFinalBundleReadBack {} ->
              advanceRoot
                steps
                version
                state
                (Right ())
                (const ArmPreparedInitDeletion)
            RootPreparedDeletionPending {} -> do
              deleted <- deletePreparedEnvelope engine attempt prepared
              case deleted of
                Left failure -> pure (Left failure)
                Right () ->
                  advanceRoot
                    steps
                    version
                    state
                    (Right ())
                    (const RecordPreparedInitDeletion)
            _ -> pure (Left (EngineCustodyTransitionRefused "unexpected prepared-envelope deletion phase"))
        RootPlanReadBackPreparedAbsence binding -> do
          observed <- readPreparedInitEnvelope store binding
          case storeReadResult observed of
            Left failure -> pure (Left failure)
            Right StoreObjectAbsent ->
              advanceRoot
                steps
                version
                state
                (Right ())
                (const ConfirmPreparedInitAbsence)
            Right StoreObjectPresent {} -> pure (Left EngineStoreReadBackMismatch)
        RootPlanAcknowledgeRecoveryCustody bundle ->
          case rootInitStatePhase state of
            RootPreparedAbsent {} ->
              advanceRoot
                steps
                version
                state
                (Right ())
                (const ArmRecoveryCustodyAcknowledgement)
            RootRecoveryCustodyAcknowledgementPending {} -> do
              acknowledged <- runLocal engine (LocalAcknowledgeRecoveryCustody bundle)
              advanceRoot steps version state acknowledged ConfirmRecoveryCustody
            _ -> pure (Left (EngineCustodyTransitionRefused "unexpected recovery-custody acknowledgement phase"))
        RootPlanAmbiguityRequiresPristineReset ambiguity ->
          pure (Left (EngineInitializationAmbiguous ambiguity))
        RootPlanCancellationLatched _ ->
          pure (Left (EngineCustodyTransitionRefused "root initialization cancellation is latched"))
        RootPlanComplete receipt ->
          if rootInitStorageGeneration (recoveryCustodyBinding receipt)
            == rootInitStorageGeneration (pristineStorageBinding proof)
            then pure (Right receipt)
            else pure (Left (EngineResponseEvidenceMismatch BrokerVaultInitialize))

  advanceRoot
    :: forall value
     . Natural
    -> StoreVersion
    -> RootInitState
    -> Either BrokerEngineError value
    -> (value -> RootInitCommand)
    -> m (Either BrokerEngineError RecoveryCustodyReceipt)
  advanceRoot steps version state result commandFor =
    case result of
      Left failure -> pure (Left failure)
      Right value -> do
        advanced <-
          transitionAndPersistRoot
            engine
            attempt
            version
            state
            (commandFor value)
        continueRoot steps advanced

  continueRoot steps advanced = case advanced of
    Left failure -> pure (Left failure)
    Right (nextVersion, nextState) -> rootLoop (steps + 1) nextVersion nextState

  persistRootAmbiguity version state = do
    advanced <-
      transitionAndPersistRoot
        engine
        attempt
        version
        state
        MarkRootInitAppliedWithoutDurableResponse
    case advanced of
      Left failure -> pure (Left failure)
      Right (_, ambiguousState) -> case rootInitStatePhase ambiguousState of
        RootInitializationAmbiguous ambiguity ->
          pure (Left (EngineInitializationAmbiguous ambiguity))
        _ ->
          pure (Left (EngineCustodyTransitionRefused "ambiguity transition did not produce ambiguous state"))

  authoritativeRootInitWorkerResult prepared recoveredResult =
    case recoveredResult of
      RootInitRecoveredAmbiguity ->
        Right ambiguousInitializationWorkerResult
      RootInitRecoveredResponse receipt
        | encryptedResponseBinding receipt == preparedInitBinding prepared
            && encryptedResponseSchemaVersion receipt
              == preparedInitSchemaVersion prepared
            && encryptedResponseRecipientCommitment receipt
              == preparedInitRecipientCommitment prepared ->
            Right (encryptedInitializationWorkerResult receipt)
        | otherwise ->
            Left (EngineResponseEvidenceMismatch BrokerVaultInitialize)

prepareRootInitRecipients
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> CapabilityRef 'VaultBootstrapMutate
  -> PristineStorageProof
  -> m (Either BrokerEngineError PreparedInitRecipients)
prepareRootInitRecipients engine attempt reference proof = do
  parameters <- resolveRootInitCryptoParameters engine proof
  case parameters of
    Left failure -> pure (Left failure)
    Right resolved -> do
      prepared <-
        runAuthorizedSecretWorkerPhysical
          engine
          attempt
          BootstrapVaultInitialize
          ( \permit ->
              PhysicalPrepareRootInitRecipients
                reference
                permit
                proof
                resolved
          )
      pure (prepared >>= validateRecipients proof resolved)

resumeRootInitRecipients
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> CapabilityRef 'VaultBootstrapMutate
  -> PristineStorageProof
  -> PreparedInitEnvelope
  -> m (Either BrokerEngineError PreparedInitRecipients)
resumeRootInitRecipients engine attempt reference proof prepared = do
  parameters <- resolveRootInitCryptoParameters engine proof
  case parameters of
    Left failure -> pure (Left failure)
    Right resolved -> do
      resumed <-
        runAuthorizedSecretWorkerPhysical
          engine
          attempt
          BootstrapVaultInitialize
          ( \permit ->
              PhysicalResumeRootInitRecipients
                reference
                permit
                prepared
                (rootInitCryptoCompiledBurnRecipient resolved)
          )
      pure $ do
        recipients <- resumed >>= validateRecipients proof resolved
        when
          ( preparedRecoveryEnvelope (preparedInitRecoveryRecipient recipients)
              /= prepared
          )
          (Left (EngineResponseEvidenceMismatch BrokerVaultInitialize))
        Right recipients

sealRootInitFinalUnlockBundle
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> CapabilityRef 'VaultBootstrapMutate
  -> PristineStorageProof
  -> EncryptedInitResponseReceipt
  -> m (Either BrokerEngineError FinalUnlockBundle)
sealRootInitFinalUnlockBundle engine attempt reference proof receipt = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
      binding = encryptedResponseBinding receipt
  observed <- readPreparedInitEnvelope store binding
  case storeReadResult observed of
    Left failure -> pure (Left failure)
    Right StoreObjectAbsent -> pure (Left EngineStoreReadBackMismatch)
    Right (StoreObjectPresent _ _ prepared) -> do
      resumed <-
        resumeRootInitRecipients
          engine
          attempt
          reference
          proof
          prepared
      case resumed of
        Left failure -> pure (Left failure)
        Right recipients -> do
          sealed <-
            runAuthorizedSecretWorkerPhysical
              engine
              attempt
              BootstrapVaultInitialize
              ( \permit ->
                  PhysicalSealFinalUnlockBundle
                    reference
                    permit
                    recipients
                    receipt
              )
          pure $ do
            bundle <- sealed
            when
              (finalUnlockBundleBinding bundle /= binding)
              (Left (EngineResponseEvidenceMismatch BrokerVaultInitialize))
            Right bundle

resolveRootInitCryptoParameters
  :: (Monad m)
  => BrokerEngine m
  -> PristineStorageProof
  -> m (Either BrokerEngineError RootInitCryptoParameters)
resolveRootInitCryptoParameters engine proof = do
  resolved <-
    engineResolveRootInitCryptoParameters
      (brokerEngineBoundary engine)
      proof
  pure (either (Left . EngineProgramEvidenceRefused) Right resolved)

validateRecipients
  :: PristineStorageProof
  -> RootInitCryptoParameters
  -> PreparedInitRecipients
  -> Either BrokerEngineError PreparedInitRecipients
validateRecipients proof parameters recipients = do
  let envelope =
        preparedRecoveryEnvelope (preparedInitRecoveryRecipient recipients)
  when
    (preparedInitBinding envelope /= pristineStorageBinding proof)
    (Left (EngineResponseEvidenceMismatch BrokerVaultInitialize))
  when
    ( preparedInitSchemaVersion envelope
        /= rootInitCryptoSchemaVersion parameters
    )
    (Left (EngineResponseEvidenceMismatch BrokerVaultInitialize))
  when
    ( preparedInitEnvelopeDigest envelope
        /= rootInitCryptoEnvelopeDigest parameters
    )
    (Left (EngineResponseEvidenceMismatch BrokerVaultInitialize))
  when
    (preparedInitRecipientShareCount recipients /= rootInitCryptoShareCount parameters)
    (Left (EngineResponseEvidenceMismatch BrokerVaultInitialize))
  when
    (preparedInitRecipientThreshold recipients /= rootInitCryptoThreshold parameters)
    (Left (EngineResponseEvidenceMismatch BrokerVaultInitialize))
  when
    ( preparedInitBurnPublicKeyBase64 recipients
        /= Settings.burnRecipientPublicKeyBase64
          (rootInitCryptoCompiledBurnRecipient parameters)
    )
    (Left (EngineResponseEvidenceMismatch BrokerVaultInitialize))
  Right recipients

loadOrCreateRootInitJournal
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> PristineStorageProof
  -> m (Either BrokerEngineError (StoreVersion, RootInitState))
loadOrCreateRootInitJournal engine attempt proof = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
      state = newRootInitState proof
      binding = pristineStorageBinding proof
  loaded <- readRootInitJournal store binding
  case storeReadResult loaded of
    Left failure -> pure (Left failure)
    Right (StoreObjectPresent version _ observed)
      | rootInitStateBinding observed == binding -> pure (Right (version, observed))
      | otherwise -> pure (Left EngineStoreReadBackMismatch)
    Right StoreObjectAbsent -> do
      created <-
        withStorePermit
          engine
          attempt
          BootstrapStoreCreateRootInitJournal
          (\permit -> createRootInitJournal store permit state)
      pure $ do
        result <- created
        version <- writeResultVersion state result
        Right (version, state)

transitionAndPersistRoot
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> StoreVersion
  -> RootInitState
  -> RootInitCommand
  -> m (Either BrokerEngineError (StoreVersion, RootInitState))
transitionAndPersistRoot engine attempt version state command =
  case applyRootInitCommand state command of
    Left failure ->
      pure
        ( Left
            (EngineCustodyTransitionRefused (Text.pack (show failure)))
        )
    Right nextState -> do
      let store = engineStoreBoundary (brokerEngineBoundary engine)
      persisted <-
        withStorePermit
          engine
          attempt
          BootstrapStoreCasRootInitJournal
          (\permit -> casRootInitJournal store permit version nextState)
      pure $ do
        result <- persisted
        nextVersion <- writeResultVersion nextState result
        Right (nextVersion, nextState)

createPreparedEnvelope
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> PreparedInitEnvelope
  -> m (Either BrokerEngineError ())
createPreparedEnvelope engine attempt prepared = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
  written <-
    withStorePermit
      engine
      attempt
      BootstrapStoreCreatePreparedInitEnvelope
      (\permit -> createPreparedInitEnvelope store permit prepared)
  pure (void (written >>= writeResultVersion prepared))

createEncryptedResponse
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> EncryptedInitResponseReceipt
  -> m (Either BrokerEngineError ())
createEncryptedResponse engine attempt receipt = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
  written <-
    withStorePermit
      engine
      attempt
      BootstrapStoreCreateEncryptedInitResponse
      (\permit -> createEncryptedInitResponse store permit receipt)
  pure (void (written >>= writeResultVersion receipt))

promoteFinalBundle
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> RootInitState
  -> FinalUnlockBundle
  -> m (Either BrokerEngineError ())
promoteFinalBundle engine attempt state bundle =
  case rootInitStatePhase state of
    RootFinalBundlePromotionPending _ receipt expected
      | expected == bundle -> do
          let store = engineStoreBoundary (brokerEngineBoundary engine)
          written <-
            withStorePermit
              engine
              attempt
              BootstrapStorePromoteFinalUnlockBundle
              (\permit -> promoteFinalUnlockBundle store permit receipt bundle)
          pure (void (written >>= writeResultVersion bundle))
      | otherwise -> pure (Left EngineStoreReadBackMismatch)
    _ -> pure (Left (EngineCustodyTransitionRefused "final-bundle promotion outside pending phase"))

deletePreparedEnvelope
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> PreparedInitEnvelope
  -> m (Either BrokerEngineError ())
deletePreparedEnvelope engine attempt prepared = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
      binding = preparedInitBinding prepared
  observed <- readPreparedInitEnvelope store binding
  case storeReadResult observed of
    Left failure -> pure (Left failure)
    Right StoreObjectAbsent -> pure (Right ())
    Right (StoreObjectPresent version _ actual)
      | actual == prepared ->
          withStorePermit
            engine
            attempt
            BootstrapStoreDeletePreparedInitEnvelope
            (\permit -> deletePreparedInitEnvelope store permit binding version)
      | otherwise -> pure (Left EngineStoreReadBackMismatch)

-- Short-lived root baseline session --------------------------------------

driveRootSession
  :: forall m
   . (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> CapabilityRef 'VaultBaselineReconcile
  -> RootSessionId
  -> RecoveryCustodyReceipt
  -> m (Either BrokerEngineError BaselineReadBackReceipt)
driveRootSession engine attempt reference sessionId custody = do
  loaded <- loadOrCreateRootSessionJournal engine attempt sessionId custody
  case loaded of
    Left failure -> pure (Left failure)
    Right (version, state) -> sessionLoop 0 version state
 where
  limit = brokerEnginePlanLimit engine

  sessionLoop steps version state
    | steps >= limit = pure (Left EngineCustodyPlanLimitExceeded)
    | otherwise = case planRootSession state of
        RootSessionPlanCancelIncompleteGenerateRoot binding ->
          runAndAdvance
            steps
            version
            state
            BootstrapVaultCancelGenerateRoot
            (\permit -> PhysicalCancelIncompleteGenerateRoot reference permit binding)
            (const ConfirmIncompleteGenerateRootCancelled)
        RootSessionPlanInventoryStaleAccessors generation ->
          runAndAdvance
            steps
            version
            state
            BootstrapVaultInventoryRootAccessors
            (\permit -> PhysicalInventoryRootAccessors reference permit generation)
            ConfirmRootAccessorInventory
        RootSessionPlanRevokeStaleAccessor accessor ->
          runAndAdvance
            steps
            version
            state
            BootstrapVaultRevokeRootAccessor
            (\permit -> PhysicalRevokeRootAccessor reference permit accessor)
            (const (ConfirmStaleRootAccessorRevoked accessor))
        RootSessionPlanProveStableAccessorAbsence inventory ->
          runAndAdvance
            steps
            version
            state
            BootstrapVaultInventoryRootAccessors
            (\permit -> PhysicalProveRootAccessorsAbsent reference permit inventory)
            ConfirmStableRootAccessorAbsence
        RootSessionPlanGenerateShortLivedRoot binding ->
          case enginePgpBoundary (brokerEngineBoundary engine) of
            Nothing -> pure (Left EnginePgpBoundaryUnavailable)
            Just pgpBoundary -> do
              scoped <-
                driveGeneratedRootScope
                  engine
                  attempt
                  reference
                  pgpBoundary
                  binding
                  version
                  state
              case scoped of
                Left failure -> pure (Left failure)
                Right (nextVersion, nextState) ->
                  sessionLoop (steps + 8) nextVersion nextState
        RootSessionPlanAwaitGeneratedRootAccessor _ ->
          pure (Left EngineGeneratedRootScopeLost)
        RootSessionPlanJournalGeneratedAccessor _ _ ->
          pure (Left EngineGeneratedRootScopeLost)
        RootSessionPlanArmAllowlistedBaseline _ ->
          pure (Left EngineGeneratedRootScopeLost)
        RootSessionPlanApplyAllowlistedBaseline _ ->
          pure (Left EngineGeneratedRootScopeLost)
        RootSessionPlanReadBackAllowlistedBaseline _ ->
          pure (Left EngineGeneratedRootScopeLost)
        RootSessionPlanArmCurrentRevocation _ ->
          pure (Left EngineGeneratedRootScopeLost)
        RootSessionPlanRevokeCurrentAccessor _ ->
          pure (Left EngineGeneratedRootScopeLost)
        RootSessionPlanArmCurrentAccessorAbsenceCheck _ ->
          advanceSession
            steps
            version
            state
            (Right ())
            (const ArmCurrentRootAccessorAbsenceCheck)
        RootSessionPlanProveCurrentAccessorAbsent accessor ->
          case mkRootAccessorInventory
            (rootInitStorageGeneration (recoveryCustodyBinding custody))
            [accessor] of
            Left failure ->
              pure (Left (EngineCustodyTransitionRefused (Text.pack (show failure))))
            Right proofTarget ->
              runAndAdvance
                steps
                version
                state
                BootstrapVaultInventoryRootAccessors
                ( \permit ->
                    PhysicalProveRootAccessorsAbsent
                      reference
                      permit
                      proofTarget
                )
                ConfirmCurrentRootAccessorAbsent
        RootSessionPlanFinishCancellation attestation ->
          advanceSession
            steps
            version
            state
            (Right attestation)
            (const FinishRootSessionCancellation)
        RootSessionPlanComplete completion ->
          do
            reconciled <-
              driveProvisionerSession
                engine
                attempt
                reference
                completion
            case reconciled of
              Left failure -> pure (Left failure)
              Right receipt -> validateBaselineReceipt receipt
        RootSessionPlanCancelledClean _ ->
          pure (Left (EngineCustodyTransitionRefused "root baseline session is cancelled"))

  runAndAdvance
    :: forall value
     . Natural
    -> StoreVersion
    -> RootSessionState
    -> BootstrapVaultEffect
    -> ( BootstrapVaultEffectPermit
         -> BrokerPhysicalCall 'VaultBaselineReconcile value
       )
    -> (value -> RootSessionCommand)
    -> m (Either BrokerEngineError BaselineReadBackReceipt)
  runAndAdvance steps version state effect buildCall commandFor = do
    result <- runAuthorizedPhysical engine attempt effect buildCall
    advanceSession steps version state result commandFor

  advanceSession
    :: forall value
     . Natural
    -> StoreVersion
    -> RootSessionState
    -> Either BrokerEngineError value
    -> (value -> RootSessionCommand)
    -> m (Either BrokerEngineError BaselineReadBackReceipt)
  advanceSession steps version state result commandFor = case result of
    Left failure -> pure (Left failure)
    Right value -> do
      advanced <-
        transitionAndPersistRootSession
          engine
          attempt
          version
          state
          (commandFor value)
      case advanced of
        Left failure -> pure (Left failure)
        Right (nextVersion, nextState) ->
          sessionLoop (steps + 1) nextVersion nextState

  validateBaselineReceipt receipt
    | baselineReadBackStorageGeneration receipt
        /= rootInitStorageGeneration (recoveryCustodyBinding custody) =
        pure (Left (EngineResponseEvidenceMismatch BrokerVaultBaselineReconcile))
    | otherwise = pure (Right receipt)

driveProvisionerSession
  :: forall m
   . (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> CapabilityRef 'VaultBaselineReconcile
  -> RootSessionCompletion
  -> m (Either BrokerEngineError BaselineReadBackReceipt)
driveProvisionerSession engine attempt reference completion =
  provisionerLoop 0 (newProvisionerSessionState completion)
 where
  limit = brokerEnginePlanLimit engine

  provisionerLoop steps state
    | steps >= limit = pure (Left EngineCustodyPlanLimitExceeded)
    | otherwise = case planProvisionerSession state of
        ProvisionerPlanArmLogin _ ->
          advance steps state ArmProvisionerLogin
        ProvisionerPlanLogin generation -> do
          loggedIn <-
            runAuthorizedPhysical
              engine
              attempt
              BootstrapVaultLoginProvisioner
              (\permit -> PhysicalLoginProvisioner reference permit generation)
          case loggedIn of
            Left failure -> pure (Left failure)
            Right receipt -> advance steps state (ConfirmProvisionerLogin receipt)
        ProvisionerPlanReady receipt -> do
          applied <-
            runAuthorizedPhysical
              engine
              attempt
              BootstrapVaultApplyBaseline
              ( \permit ->
                  PhysicalApplyProvisionerBaseline reference permit receipt
              )
          case applied of
            Left failure -> pure (Left failure)
            Right () -> do
              readBack <-
                runAuthorizedPhysical
                  engine
                  attempt
                  BootstrapVaultReadBackBaseline
                  ( \permit ->
                      PhysicalReadBackProvisionerBaseline
                        reference
                        permit
                        receipt
                  )
              pure $ do
                observed <- readBack
                when
                  (observed /= completedRootBaselineReadBack completion)
                  ( Left
                      ( EngineResponseEvidenceMismatch
                          BrokerVaultBaselineReconcile
                      )
                  )
                Right observed

  advance
    :: Natural
    -> ProvisionerSessionState
    -> ProvisionerSessionCommand
    -> m (Either BrokerEngineError BaselineReadBackReceipt)
  advance steps state command =
    case applyProvisionerSessionCommand state command of
      Left failure ->
        pure
          ( Left
              (EngineCustodyTransitionRefused (Text.pack (show failure)))
          )
      Right nextState -> provisionerLoop (steps + 1) nextState

driveGeneratedRootScope
  :: forall m
   . (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> CapabilityRef 'VaultBaselineReconcile
  -> PgpBoundary m
  -> RootSessionBinding
  -> StoreVersion
  -> RootSessionState
  -> m (Either BrokerEngineError (StoreVersion, RootSessionState))
driveGeneratedRootScope engine attempt reference pgpBoundary binding version state =
  do
    scoped <-
      withGeneratedRootRecipient pgpBoundary $ \publicKey decryptCiphertext ->
        runExceptT $ do
          _ <-
            ExceptT
              ( runAuthorizedPhysical
                  engine
                  attempt
                  BootstrapVaultStartGenerateRoot
                  ( \permit ->
                      PhysicalStartGenerateRoot
                        reference
                        permit
                        binding
                        publicKey
                  )
              )
          (startedVersion, startedState) <-
            ExceptT
              ( transitionAndPersistRootSession
                  engine
                  attempt
                  version
                  state
                  RecordShortLivedRootGenerationStarted
              )
          originatingPermit <-
            ExceptT
              ( authorizeVaultCall
                  engine
                  attempt
                  BootstrapVaultSubmitGenerateRootShare
              )
          ciphertext <-
            ExceptT
              ( runPhysical
                  engine
                  ( PhysicalAwaitGeneratedRootCiphertext
                      reference
                      originatingPermit
                      binding
                  )
              )
          decrypted <-
            lift
              ( decryptCiphertext
                  binding
                  originatingPermit
                  ciphertext
                  ( generatedRootWorkflow
                      engine
                      attempt
                      startedVersion
                      startedState
                  )
              )
          case decrypted of
            Left refusal -> throwE (EnginePgpBoundaryRefused refusal)
            Right result -> ExceptT (pure result)
    pure $ case scoped of
      Left refusal -> Left (EnginePgpBoundaryRefused refusal)
      Right result -> result

generatedRootWorkflow
  :: forall m
   . (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> StoreVersion
  -> RootSessionState
  -> GeneratedRootWorkflow
       m
       BrokerEngineError
       (StoreVersion, RootSessionState)
       (StoreVersion, RootSessionState)
generatedRootWorkflow engine attempt version state =
  GeneratedRootWorkflow
    { rootWorkflowInitialState = (version, state)
    , rootWorkflowAuthorize = authorizeVaultCall engine attempt
    , rootWorkflowAfterAccessor = \current accessor ->
        runExceptT $ do
          captured <- persistPair current (CaptureGeneratedRootAccessor accessor)
          journaled <-
            persistPair captured (ConfirmGeneratedRootAccessorJournaled accessor)
          persistPair journaled ArmAllowlistedBaselineMutation
    , rootWorkflowAfterApply = \current ->
        persistPairEither current RecordAllowlistedBaselineApplied
    , rootWorkflowAfterReadBack = \current readBack ->
        runExceptT $ do
          confirmed <-
            persistPair current (ConfirmAllowlistedBaselineReadBack readBack)
          persistPair confirmed ArmCurrentRootSessionRevocation
    , rootWorkflowAfterRevoke = \current ->
        persistPairEither current ConfirmCurrentRootSessionRevoked
    }
 where
  persist currentVersion currentState command =
    ExceptT
      ( transitionAndPersistRootSession
          engine
          attempt
          currentVersion
          currentState
          command
      )

  persistPair (currentVersion, currentState) =
    persist currentVersion currentState

  persistPairEither current command =
    runExceptT (persistPair current command)

loadOrCreateRootSessionJournal
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> RootSessionId
  -> RecoveryCustodyReceipt
  -> m (Either BrokerEngineError (StoreVersion, RootSessionState))
loadOrCreateRootSessionJournal engine attempt sessionId custody = do
  let generation = rootInitStorageGeneration (recoveryCustodyBinding custody)
      state = newRootSessionState sessionId custody
  loaded <- readRootSessionJournal store generation
  case storeReadResult loaded of
    Left failure -> pure (Left failure)
    Right (StoreObjectPresent version _ observed)
      | rootSessionBindingCustody (rootSessionStateBinding observed) /= custody ->
          pure (Left EngineStoreReadBackMismatch)
      | otherwise ->
          case planRootSession observed of
            RootSessionPlanComplete _ -> pure (Right (version, observed))
            RootSessionPlanCancelledClean _ -> pure (Right (version, observed))
            _
              | rootSessionBindingId (rootSessionStateBinding observed) == sessionId ->
                  pure (Left EngineGeneratedRootScopeLost)
              | otherwise -> restartLoadedRootSession generation version observed
    Right StoreObjectAbsent -> do
      created <-
        withStorePermit
          engine
          attempt
          BootstrapStoreCreateRootSessionJournal
          (\permit -> createRootSessionJournal store permit state)
      pure $ do
        result <- created
        version <- writeResultVersion state result
        Right (version, state)
 where
  store = engineStoreBoundary (brokerEngineBoundary engine)

  restartLoadedRootSession generation version observed =
    case restartRootSession sessionId observed of
      Left failure ->
        pure
          (Left (EngineCustodyTransitionRefused (Text.pack (show failure))))
      Right restarted -> do
        persisted <-
          withStorePermit
            engine
            attempt
            BootstrapStoreCasRootSessionJournal
            (\permit -> casRootSessionJournal store permit version restarted)
        case persisted >>= writeResultVersion restarted of
          Left failure -> pure (Left failure)
          Right restartedVersion -> do
            readBack <- readRootSessionJournal store generation
            pure $ case storeReadResult readBack of
              Right
                ( StoreObjectPresent
                    observedVersion
                    _
                    observedState
                  )
                  | observedVersion == restartedVersion
                      && observedState == restarted ->
                      Right (observedVersion, observedState)
              _ -> Left EngineStoreReadBackMismatch

transitionAndPersistRootSession
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> StoreVersion
  -> RootSessionState
  -> RootSessionCommand
  -> m (Either BrokerEngineError (StoreVersion, RootSessionState))
transitionAndPersistRootSession engine attempt version state command =
  case applyRootSessionCommand state command of
    Left failure ->
      pure
        ( Left
            (EngineCustodyTransitionRefused (Text.pack (show failure)))
        )
    Right nextState -> do
      let store = engineStoreBoundary (brokerEngineBoundary engine)
      persisted <-
        withStorePermit
          engine
          attempt
          BootstrapStoreCasRootSessionJournal
          (\permit -> casRootSessionJournal store permit version nextState)
      pure $ do
        result <- persisted
        nextVersion <- writeResultVersion nextState result
        Right (nextVersion, nextState)

-- Child custody -----------------------------------------------------------

driveChildCustody
  :: forall m
   . (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> CapabilityRef 'VaultBootstrapMutate
  -> ChildCustodyBinding
  -> m (Either BrokerEngineError ParentCustodyAcknowledgement)
driveChildCustody engine attempt reference binding = do
  loaded <- loadOrCreateChildCustodyJournal engine attempt binding
  case loaded of
    Left failure -> pure (Left failure)
    Right (version, state) -> childLoop 0 version state
 where
  store = engineStoreBoundary (brokerEngineBoundary engine)
  limit = brokerEnginePlanLimit engine

  childLoop steps version state
    | steps >= limit = pure (Left EngineCustodyPlanLimitExceeded)
    | otherwise = case planChildCustody state of
        ChildPlanAwaitEncryptedInitResponse expectedBinding -> do
          captured <-
            runLocal engine (LocalCaptureChildEncryptedReceipt expectedBinding)
          advanceChild
            steps
            version
            state
            captured
            CaptureChildEncryptedReceipt
        ChildPlanWriteLocalEncryptedReceipt receipt -> do
          stored <- createChildReceipt engine attempt receipt
          case stored of
            Left failure -> pure (Left failure)
            Right () ->
              advanceChild
                steps
                version
                state
                (Right ())
                (const RecordChildLocalReceiptWrite)
        ChildPlanReadBackLocalEncryptedReceipt expected -> do
          observed <- readChildEncryptedReceipt store binding
          case storeReadResult observed of
            Left failure -> pure (Left failure)
            Right (StoreObjectPresent _ _ actual)
              | actual == expected ->
                  advanceChild
                    steps
                    version
                    state
                    (Right actual)
                    ConfirmChildLocalReceiptReadBack
              | otherwise -> pure (Left EngineStoreReadBackMismatch)
            Right StoreObjectAbsent -> pure (Left EngineStoreReadBackMismatch)
        ChildPlanArmParentGenerationCas _ ->
          advanceChild
            steps
            version
            state
            (Right ())
            (const ArmChildParentGenerationCas)
        ChildPlanParentGenerationCas receipt -> do
          physicalAcknowledgement <-
            runAuthorizedPhysical
              engine
              attempt
              BootstrapVaultCommitChildCustody
              (\permit -> PhysicalCommitParentCustody reference permit receipt)
          case physicalAcknowledgement of
            Left failure -> pure (Left failure)
            Right expectedAcknowledgement -> do
              durableAcknowledgement <-
                commitParentCustody engine attempt receipt
              case durableAcknowledgement of
                Left failure -> pure (Left failure)
                Right acknowledgement
                  | acknowledgement == expectedAcknowledgement ->
                      advanceChild
                        steps
                        version
                        state
                        (Right acknowledgement)
                        ConfirmParentCustodyReadBack
                  | otherwise -> pure (Left EngineStoreReadBackMismatch)
        ChildPlanDeleteLocalEncryptedReceipt acknowledgement ->
          case childCustodyStatePhase state of
            ChildParentCustodyReadBack {} ->
              advanceChild
                steps
                version
                state
                (Right ())
                (const ArmChildLocalReceiptDeletion)
            ChildLocalReceiptDeletionPending {} -> do
              deleted <- deleteChildReceipt engine attempt binding
              case deleted of
                Left failure -> pure (Left failure)
                Right () ->
                  advanceChild
                    steps
                    version
                    state
                    (Right ())
                    (const RecordChildLocalReceiptDeletion)
            _ ->
              pure
                ( Left
                    ( EngineCustodyTransitionRefused
                        ( "unexpected child receipt deletion phase for "
                            <> Text.pack (show acknowledgement)
                        )
                    )
                )
        ChildPlanReadBackLocalReceiptAbsence _ -> do
          observed <- readChildEncryptedReceipt store binding
          case storeReadResult observed of
            Left failure -> pure (Left failure)
            Right StoreObjectAbsent ->
              advanceChild
                steps
                version
                state
                (Right ())
                (const ConfirmChildLocalReceiptAbsence)
            Right StoreObjectPresent {} -> pure (Left EngineStoreReadBackMismatch)
        ChildPlanMarkCustodyDurable _ ->
          advanceChild
            steps
            version
            state
            (Right ())
            (const ConfirmChildRecoveryCustodyDurable)
        ChildPlanCancellationLatched _ ->
          pure (Left (EngineCustodyTransitionRefused "child custody cancellation is latched"))
        ChildPlanCustodyComplete acknowledgement
          | parentCustodyAcknowledgedBinding acknowledgement == binding ->
              pure (Right acknowledgement)
          | otherwise ->
              pure (Left (EngineResponseEvidenceMismatch BrokerChildCustodyCommit))

  advanceChild
    :: forall value
     . Natural
    -> StoreVersion
    -> ChildCustodyState
    -> Either BrokerEngineError value
    -> (value -> ChildCustodyCommand)
    -> m (Either BrokerEngineError ParentCustodyAcknowledgement)
  advanceChild steps version state result commandFor = case result of
    Left failure -> pure (Left failure)
    Right value -> do
      advanced <-
        transitionAndPersistChildCustody
          engine
          attempt
          version
          state
          (commandFor value)
      case advanced of
        Left failure -> pure (Left failure)
        Right (nextVersion, nextState) ->
          childLoop (steps + 1) nextVersion nextState

loadOrCreateChildCustodyJournal
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> ChildCustodyBinding
  -> m (Either BrokerEngineError (StoreVersion, ChildCustodyState))
loadOrCreateChildCustodyJournal engine attempt binding = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
      state = newChildCustodyState binding
  loaded <- readChildCustodyJournal store binding
  case storeReadResult loaded of
    Left failure -> pure (Left failure)
    Right (StoreObjectPresent version _ observed)
      | childCustodyStateBinding observed == binding -> pure (Right (version, observed))
      | otherwise -> pure (Left EngineStoreReadBackMismatch)
    Right StoreObjectAbsent -> do
      created <-
        withStorePermit
          engine
          attempt
          BootstrapStoreCreateChildCustodyJournal
          (\permit -> createChildCustodyJournal store permit state)
      pure $ do
        result <- created
        version <- writeResultVersion state result
        Right (version, state)

transitionAndPersistChildCustody
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> StoreVersion
  -> ChildCustodyState
  -> ChildCustodyCommand
  -> m (Either BrokerEngineError (StoreVersion, ChildCustodyState))
transitionAndPersistChildCustody engine attempt version state command =
  case applyChildCustodyCommand state command of
    Left failure ->
      pure
        ( Left
            (EngineCustodyTransitionRefused (Text.pack (show failure)))
        )
    Right nextState -> do
      let store = engineStoreBoundary (brokerEngineBoundary engine)
      persisted <-
        withStorePermit
          engine
          attempt
          BootstrapStoreCasChildCustodyJournal
          (\permit -> casChildCustodyJournal store permit version nextState)
      pure $ do
        result <- persisted
        nextVersion <- writeResultVersion nextState result
        Right (nextVersion, nextState)

createChildReceipt
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> ChildEncryptedReceipt
  -> m (Either BrokerEngineError ())
createChildReceipt engine attempt receipt = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
  written <-
    withStorePermit
      engine
      attempt
      BootstrapStoreCreateChildEncryptedReceipt
      (\permit -> createChildEncryptedReceipt store permit receipt)
  pure (void (written >>= writeResultVersion receipt))

commitParentCustody
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> ChildEncryptedReceipt
  -> m (Either BrokerEngineError ParentCustodyAcknowledgement)
commitParentCustody engine attempt receipt = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
  committed <-
    withStorePermit
      engine
      attempt
      BootstrapStoreCommitParentCustody
      (\permit -> parentCustodyGenerationCas store permit receipt)
  pure $ do
    result <- committed
    case result of
      StoreWriteApplied _ _ acknowledgement -> Right acknowledgement
      StoreWriteConflict (StoreObjectPresent _ _ acknowledgement) -> Right acknowledgement
      StoreWriteConflict StoreObjectAbsent -> Left EngineStoreVersionConflict

deleteChildReceipt
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> ChildCustodyBinding
  -> m (Either BrokerEngineError ())
deleteChildReceipt engine attempt binding = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
  observed <- readChildEncryptedReceipt store binding
  case storeReadResult observed of
    Left failure -> pure (Left failure)
    Right StoreObjectAbsent -> pure (Right ())
    Right (StoreObjectPresent version _ _) ->
      withStorePermit
        engine
        attempt
        BootstrapStoreDeleteChildEncryptedReceipt
        (\permit -> deleteChildEncryptedReceipt store permit binding version)

-- One-time child recovery delivery ---------------------------------------

prepareChildRecoveryDelivery
  :: forall m
   . (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> CapabilityRef 'VaultBootstrapMutate
  -> ChildCustodyBinding
  -> DeliveryNonce
  -> ChildAttestation
  -> m (Either BrokerEngineError ChildRecoveryDelivery)
prepareChildRecoveryDelivery engine attempt reference binding nonce attestation = do
  loaded <- loadOrCreateChildRecoveryJournal engine attempt binding
  case loaded of
    Left failure -> pure (Left failure)
    Right (version, state) -> recoveryLoop 0 version state
 where
  store = engineStoreBoundary (brokerEngineBoundary engine)
  limit = brokerEnginePlanLimit engine

  recoveryLoop steps version state
    | steps >= limit = pure (Left EngineCustodyPlanLimitExceeded)
    | otherwise = case planChildRecovery state of
        ChildRecoveryPlanAwaitDelivery expectedBinding
          | expectedBinding /= binding ->
              pure (Left (EngineResponseEvidenceMismatch BrokerChildRecoveryDeliver))
          | otherwise -> do
              prepared <-
                runLocal
                  engine
                  (LocalPrepareChildRecoveryDelivery binding nonce attestation)
              case prepared of
                Left failure -> pure (Left failure)
                Right delivery
                  | not (deliveryMatches binding nonce attestation delivery) ->
                      pure (Left (EngineResponseEvidenceMismatch BrokerChildRecoveryDeliver))
                  | otherwise -> do
                      stored <- createRecoveryDelivery engine attempt delivery
                      case stored of
                        Left failure -> pure (Left failure)
                        Right () -> do
                          confirmed <- confirmDeliveryReadBack delivery
                          advanceRecovery
                            steps
                            version
                            state
                            confirmed
                            PrepareChildRecoveryDelivery
        ChildRecoveryPlanArmDeliveryConsume _ ->
          advanceRecovery
            steps
            version
            state
            (Right ())
            (const ArmChildRecoveryDeliveryConsume)
        ChildRecoveryPlanStartDeliveryConsume _ ->
          advanceRecovery
            steps
            version
            state
            (Right ())
            (const RecordChildRecoveryDeliveryConsumeStarted)
        ChildRecoveryPlanReconcileDeliveryConsume delivery -> do
          observed <-
            runAuthorizedPhysical
              engine
              attempt
              BootstrapVaultConsumeChildRecovery
              ( \permit ->
                  PhysicalObserveChildRecoveryConsumption
                    reference
                    permit
                    delivery
              )
          case observed of
            Left failure -> pure (Left failure)
            Right observation
              | childRecoveryConsumptionObservationMatches
                  delivery
                  ChildRecoveryConsumptionApplied
                  observation ->
                  advanceRecovery
                    steps
                    version
                    state
                    (Right observation)
                    ConfirmChildRecoveryDeliveryConsumed
              | childRecoveryConsumptionObservationMatches
                  delivery
                  ChildRecoveryConsumptionNotApplied
                  observation ->
                  case childRecoveryStateDisposition state of
                    CustodyCancellationRequested _ ->
                      pure
                        ( Left
                            ( EngineCustodyTransitionRefused
                                "child recovery consumption cancelled before application"
                            )
                        )
                    CustodyRunning -> do
                      consumed <-
                        runAuthorizedPhysical
                          engine
                          attempt
                          BootstrapVaultConsumeChildRecovery
                          ( \permit ->
                              PhysicalConsumeChildRecovery
                                reference
                                permit
                                delivery
                          )
                      case consumed of
                        Right applied
                          | childRecoveryConsumptionObservationMatches
                              delivery
                              ChildRecoveryConsumptionApplied
                              applied ->
                              advanceRecovery
                                steps
                                version
                                state
                                (Right applied)
                                ConfirmChildRecoveryDeliveryConsumed
                        Right _ -> consumptionMismatch
                        Left failure -> pure (Left failure)
              | otherwise -> consumptionMismatch
        ChildRecoveryPlanArmOrphanCleanup delivery -> do
          deleted <- deleteRecoveryDelivery engine attempt delivery
          case deleted of
            Left failure -> pure (Left failure)
            Right () ->
              advanceRecovery
                steps
                version
                state
                (Right ())
                (const ArmChildRecoveryOrphanCleanup)
        ChildRecoveryPlanCancelIncompleteGenerateRoot delivery ->
          runAndAdvance
            steps
            version
            state
            BootstrapVaultCancelGenerateRoot
            (\permit -> PhysicalCancelChildIncompleteGenerateRoot reference permit delivery)
            (const ConfirmChildRecoveryIncompleteGenerateRootCancelled)
        ChildRecoveryPlanInventoryStaleRootAccessors delivery ->
          runAndAdvance
            steps
            version
            state
            BootstrapVaultInventoryRootAccessors
            ( \permit ->
                PhysicalInventoryChildRootAccessors
                  reference
                  permit
                  (childRecoveryDeliveryBinding delivery)
            )
            ConfirmChildRecoveryRootAccessorInventory
        ChildRecoveryPlanRevokeStaleRootAccessor _ accessor ->
          runAndAdvance
            steps
            version
            state
            BootstrapVaultRevokeRootAccessor
            (\permit -> PhysicalRevokeChildRootAccessor reference permit accessor)
            (const (ConfirmChildRecoveryStaleRootAccessorRevoked accessor))
        ChildRecoveryPlanProveStableRootAccessorAbsence _ inventory ->
          runAndAdvance
            steps
            version
            state
            BootstrapVaultInventoryRootAccessors
            (\permit -> PhysicalProveChildRootAccessorsAbsent reference permit inventory)
            ConfirmChildRecoveryStableRootAccessorAbsence
        ChildRecoveryPlanGenerateShortLivedRoot delivery ->
          case enginePgpBoundary (brokerEngineBoundary engine) of
            Nothing -> pure (Left EnginePgpBoundaryUnavailable)
            Just pgpBoundary -> do
              scoped <-
                driveGeneratedChildRecoveryScope
                  engine
                  attempt
                  reference
                  pgpBoundary
                  delivery
                  version
                  state
              case scoped of
                Left failure -> pure (Left failure)
                Right (nextVersion, nextState) ->
                  recoveryLoop (steps + 8) nextVersion nextState
        ChildRecoveryPlanAwaitGeneratedRootAccessor _ ->
          pure (Left EngineGeneratedRootScopeLost)
        ChildRecoveryPlanJournalRootAccessor _ _ ->
          pure (Left EngineGeneratedRootScopeLost)
        ChildRecoveryPlanArmRepair _ _ ->
          pure (Left EngineGeneratedRootScopeLost)
        ChildRecoveryPlanApplyRepair _ _ ->
          pure (Left EngineGeneratedRootScopeLost)
        ChildRecoveryPlanReadBackRepair _ _ ->
          pure (Left EngineGeneratedRootScopeLost)
        ChildRecoveryPlanArmRootRevocation _ _ ->
          pure (Left EngineGeneratedRootScopeLost)
        ChildRecoveryPlanRevokeRootAccessor _ _ ->
          pure (Left EngineGeneratedRootScopeLost)
        ChildRecoveryPlanArmRootAccessorAbsenceCheck _ _ ->
          advanceRecovery
            steps
            version
            state
            (Right ())
            (const ArmChildRecoveryRootAccessorAbsenceCheck)
        ChildRecoveryPlanProveRootAccessorAbsent delivery accessor ->
          case mkRootAccessorInventory
            ( childCustodyStorageGeneration
                (childRecoveryDeliveryBinding delivery)
            )
            [accessor] of
            Left failure ->
              pure (Left (EngineCustodyTransitionRefused (Text.pack (show failure))))
            Right proofTarget ->
              runAndAdvance
                steps
                version
                state
                BootstrapVaultInventoryRootAccessors
                ( \permit ->
                    PhysicalProveChildRootAccessorsAbsent
                      reference
                      permit
                      proofTarget
                )
                ConfirmChildRecoveryRootAccessorAbsent
        ChildRecoveryPlanCancellationLatched phase ->
          pure (Left (EngineCustodyTransitionRefused (Text.pack phase)))
        ChildRecoveryPlanComplete delivery _ _
          | deliveryMatches binding nonce attestation delivery -> pure (Right delivery)
          | otherwise ->
              pure (Left (EngineResponseEvidenceMismatch BrokerChildRecoveryDeliver))

  consumptionMismatch =
    pure (Left (EngineResponseEvidenceMismatch BrokerChildRecoveryDeliver))

  runAndAdvance
    :: forall value
     . Natural
    -> StoreVersion
    -> ChildRecoveryState
    -> BootstrapVaultEffect
    -> ( BootstrapVaultEffectPermit
         -> BrokerPhysicalCall 'VaultBootstrapMutate value
       )
    -> (value -> ChildRecoveryCommand)
    -> m (Either BrokerEngineError ChildRecoveryDelivery)
  runAndAdvance steps version state effect buildCall commandFor = do
    result <- runAuthorizedPhysical engine attempt effect buildCall
    advanceRecovery steps version state result commandFor

  advanceRecovery
    :: forall value
     . Natural
    -> StoreVersion
    -> ChildRecoveryState
    -> Either BrokerEngineError value
    -> (value -> ChildRecoveryCommand)
    -> m (Either BrokerEngineError ChildRecoveryDelivery)
  advanceRecovery steps version state result commandFor = case result of
    Left failure -> pure (Left failure)
    Right value -> do
      advanced <-
        transitionAndPersistChildRecovery
          engine
          attempt
          version
          state
          (commandFor value)
      case advanced of
        Left failure -> pure (Left failure)
        Right (nextVersion, nextState) ->
          recoveryLoop (steps + 1) nextVersion nextState

  confirmDeliveryReadBack expected = do
    observed <- readChildRecoveryDelivery store binding
    pure $ case storeReadResult observed of
      Left failure -> Left failure
      Right (StoreObjectPresent _ _ actual)
        | actual == expected -> Right actual
        | otherwise -> Left EngineStoreReadBackMismatch
      Right StoreObjectAbsent -> Left EngineStoreReadBackMismatch

driveGeneratedChildRecoveryScope
  :: forall m
   . (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> CapabilityRef 'VaultBootstrapMutate
  -> PgpBoundary m
  -> ChildRecoveryDelivery
  -> StoreVersion
  -> ChildRecoveryState
  -> m (Either BrokerEngineError (StoreVersion, ChildRecoveryState))
driveGeneratedChildRecoveryScope engine attempt reference pgpBoundary delivery version state = do
  scoped <-
    withGeneratedChildRecoveryRecipient pgpBoundary $ \publicKey decryptCiphertext ->
      runExceptT $ do
        _ <-
          ExceptT
            ( runAuthorizedPhysical
                engine
                attempt
                BootstrapVaultStartGenerateRoot
                ( \permit ->
                    PhysicalStartChildGenerateRoot
                      reference
                      permit
                      delivery
                      publicKey
                )
            )
        (startedVersion, startedState) <-
          ExceptT
            ( transitionAndPersistChildRecovery
                engine
                attempt
                version
                state
                RecordChildRecoveryRootGenerationStarted
            )
        originatingPermit <-
          ExceptT
            ( authorizeVaultCall
                engine
                attempt
                BootstrapVaultSubmitGenerateRootShare
            )
        ciphertext <-
          ExceptT
            ( runPhysical
                engine
                ( PhysicalAwaitChildGeneratedRootCiphertext
                    reference
                    originatingPermit
                    delivery
                )
            )
        decrypted <-
          lift
            ( decryptCiphertext
                delivery
                originatingPermit
                ciphertext
                ( generatedChildRecoveryWorkflow
                    engine
                    attempt
                    startedVersion
                    startedState
                )
            )
        case decrypted of
          Left refusal -> throwE (EnginePgpBoundaryRefused refusal)
          Right result -> ExceptT (pure result)
  pure $ case scoped of
    Left refusal -> Left (EnginePgpBoundaryRefused refusal)
    Right result -> result

generatedChildRecoveryWorkflow
  :: forall m
   . (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> StoreVersion
  -> ChildRecoveryState
  -> GeneratedChildRecoveryWorkflow
       m
       BrokerEngineError
       (StoreVersion, ChildRecoveryState)
       (StoreVersion, ChildRecoveryState)
generatedChildRecoveryWorkflow engine attempt version state =
  GeneratedChildRecoveryWorkflow
    { childWorkflowInitialState = (version, state)
    , childWorkflowAuthorize = authorizeVaultCall engine attempt
    , childWorkflowAfterAccessor = \current accessor ->
        runExceptT $ do
          captured <-
            persistPair current (CaptureChildRecoveryRootAccessor accessor)
          journaled <-
            persistPair
              captured
              (ConfirmChildRecoveryRootAccessorJournaled accessor)
          persistPair journaled ArmChildRecoveryRepair
    , childWorkflowAfterApply = \current ->
        persistPairEither current RecordChildRecoveryRepairApplied
    , childWorkflowAfterReadBack = \current readBack ->
        runExceptT $ do
          confirmed <-
            persistPair current (ConfirmChildRecoveryRepairReadBack readBack)
          persistPair confirmed ArmChildRecoveryRootRevocation
    , childWorkflowAfterRevoke = \current ->
        persistPairEither current ConfirmChildRecoveryRootRevoked
    }
 where
  persist currentVersion currentState command =
    ExceptT
      ( transitionAndPersistChildRecovery
          engine
          attempt
          currentVersion
          currentState
          command
      )

  persistPair (currentVersion, currentState) =
    persist currentVersion currentState

  persistPairEither current command =
    runExceptT (persistPair current command)

deliveryMatches
  :: ChildCustodyBinding
  -> DeliveryNonce
  -> ChildAttestation
  -> ChildRecoveryDelivery
  -> Bool
deliveryMatches binding nonce attestation delivery =
  childRecoveryDeliveryBinding delivery == binding
    && childRecoveryDeliveryNonce delivery == nonce
    && childRecoveryDeliveryAttestation delivery == attestation

loadOrCreateChildRecoveryJournal
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> ChildCustodyBinding
  -> m (Either BrokerEngineError (StoreVersion, ChildRecoveryState))
loadOrCreateChildRecoveryJournal engine attempt binding = do
  let state = newChildRecoveryState binding
  loaded <- readChildRecoveryJournal store binding
  case storeReadResult loaded of
    Left failure -> pure (Left failure)
    Right (StoreObjectPresent version _ observed)
      | childRecoveryStateBinding observed == binding ->
          restartLoadedChildRecovery version observed
      | otherwise -> pure (Left EngineStoreReadBackMismatch)
    Right StoreObjectAbsent -> do
      created <-
        withStorePermit
          engine
          attempt
          BootstrapStoreCreateChildRecoveryJournal
          (\permit -> createChildRecoveryJournal store permit state)
      pure $ do
        result <- created
        version <- writeResultVersion state result
        Right (version, state)
 where
  restartLoadedChildRecovery version observed =
    let restarted = restartChildRecovery observed
     in if restarted == observed
          then pure (Right (version, observed))
          else do
            persisted <-
              withStorePermit
                engine
                attempt
                BootstrapStoreCasChildRecoveryJournal
                ( \permit ->
                    casChildRecoveryJournal store permit version restarted
                )
            case persisted >>= writeResultVersion restarted of
              Left failure -> pure (Left failure)
              Right restartedVersion -> do
                readBack <- readChildRecoveryJournal store binding
                pure $ case storeReadResult readBack of
                  Right
                    ( StoreObjectPresent
                        observedVersion
                        _
                        observedState
                      )
                      | observedVersion == restartedVersion
                          && observedState == restarted ->
                          Right (observedVersion, observedState)
                  _ -> Left EngineStoreReadBackMismatch

  store = engineStoreBoundary (brokerEngineBoundary engine)

transitionAndPersistChildRecovery
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> StoreVersion
  -> ChildRecoveryState
  -> ChildRecoveryCommand
  -> m (Either BrokerEngineError (StoreVersion, ChildRecoveryState))
transitionAndPersistChildRecovery engine attempt version state command =
  case applyChildRecoveryCommand state command of
    Left failure ->
      pure
        ( Left
            (EngineCustodyTransitionRefused (Text.pack (show failure)))
        )
    Right nextState -> do
      let store = engineStoreBoundary (brokerEngineBoundary engine)
      persisted <-
        withStorePermit
          engine
          attempt
          BootstrapStoreCasChildRecoveryJournal
          (\permit -> casChildRecoveryJournal store permit version nextState)
      pure $ do
        result <- persisted
        nextVersion <- writeResultVersion nextState result
        Right (nextVersion, nextState)

createRecoveryDelivery
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> ChildRecoveryDelivery
  -> m (Either BrokerEngineError ())
createRecoveryDelivery engine attempt delivery = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
  written <-
    withStorePermit
      engine
      attempt
      BootstrapStoreCreateChildRecoveryDelivery
      (\permit -> createChildRecoveryDelivery store permit delivery)
  pure (void (written >>= writeResultVersion delivery))

deleteRecoveryDelivery
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> ChildRecoveryDelivery
  -> m (Either BrokerEngineError ())
deleteRecoveryDelivery engine attempt expected = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
      binding = childRecoveryDeliveryBinding expected
  observed <- readChildRecoveryDelivery store binding
  case storeReadResult observed of
    Left failure -> pure (Left failure)
    Right StoreObjectAbsent -> pure (Right ())
    Right (StoreObjectPresent version _ actual)
      | actual /= expected -> pure (Left EngineStoreReadBackMismatch)
      | otherwise -> do
          deleted <-
            withStorePermit
              engine
              attempt
              BootstrapStoreDeleteChildRecoveryDelivery
              (\permit -> deleteChildRecoveryDelivery store permit binding version)
          case deleted of
            Left failure -> pure (Left failure)
            Right () -> do
              readBack <- readChildRecoveryDelivery store binding
              pure $ case storeReadResult readBack of
                Left failure -> Left failure
                Right StoreObjectAbsent -> Right ()
                Right StoreObjectPresent {} -> Left EngineStoreReadBackMismatch

observeChildRecoveryDelivery
  :: (Monad m)
  => BrokerEngine m
  -> ChildCustodyBinding
  -> DeliveryNonce
  -> m (Either BrokerEngineError (Maybe ChildRecoveryDelivery))
observeChildRecoveryDelivery engine binding nonce = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
  observed <- readChildRecoveryDelivery store binding
  pure $ case storeReadResult observed of
    Left failure -> Left failure
    Right StoreObjectAbsent -> Right Nothing
    Right (StoreObjectPresent _ _ delivery)
      | childRecoveryDeliveryBinding delivery == binding
          && childRecoveryDeliveryNonce delivery == nonce ->
          Right (Just delivery)
      | otherwise -> Left (EngineResponseEvidenceMismatch BrokerChildRecoveryObserve)

-- Ambiguous initialization reset -----------------------------------------

resetAmbiguousInitialization
  :: (Monad m)
  => BrokerEngine m
  -> MutationAttempt
  -> CapabilityRef 'VaultBootstrapMutate
  -> InitAmbiguity
  -> PristineResetProof
  -> ArtifactDigest
  -> m (Either BrokerEngineError BootstrapMutationReceipt)
resetAmbiguousInitialization engine attempt reference ambiguity resetProof actionDigest = do
  let store = engineStoreBoundary (brokerEngineBoundary engine)
      binding = ambiguousInitBinding ambiguity
  loaded <- readRootInitJournal store binding
  case storeReadResult loaded of
    Left failure -> pure (Left failure)
    Right StoreObjectAbsent -> pure (Left EngineStoreReadBackMismatch)
    Right (StoreObjectPresent version _ state) ->
      case rootInitStatePhase state of
        RootInitializationAmbiguous observed
          | observed == ambiguity -> do
              audited <-
                runAuthorizedPhysical
                  engine
                  attempt
                  BootstrapVaultResetAmbiguousInitialization
                  ( \permit ->
                      PhysicalResetAmbiguousInitialization
                        reference
                        permit
                        ambiguity
                        resetProof
                  )
              case audited of
                Left failure -> pure (Left failure)
                Right confirmedProof
                  | confirmedProof /= resetProof ->
                      pure
                        ( Left
                            ( EngineResponseEvidenceMismatch
                                BrokerVaultResetAmbiguousInitialization
                            )
                        )
                  | otherwise -> do
                      advanced <-
                        transitionAndPersistRoot
                          engine
                          attempt
                          version
                          state
                          (ResetAmbiguousRootInitialization confirmedProof)
                      pure $ case advanced of
                        Left failure -> Left failure
                        Right _ ->
                          Right
                            BootstrapMutationReceipt
                              { bootstrapMutationDigest = actionDigest
                              , bootstrapMutationChanged = True
                              }
          | otherwise ->
              pure (Left (EngineResponseEvidenceMismatch BrokerVaultResetAmbiguousInitialization))
        _ ->
          pure
            ( Left
                (EngineCustodyTransitionRefused "reset requested outside ambiguous initialization")
            )
