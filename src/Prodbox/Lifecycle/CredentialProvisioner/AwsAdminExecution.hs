{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Native IAM/S3 execution for a verified AWS-admin permit.  The caller must
-- first durably prepare the exact selected Target outbox; that observation is
-- threaded linearly into delivery, so the worker cannot choose a cluster,
-- Agent, target, generation, or receipt digest at execution time.
module Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( PreparedCredentialTargetObservation
  , mkPreparedCredentialTargetObservation
  , preparedCredentialTargetOwnerNonce
  , preparedCredentialTargetFence
  , preparedCredentialTargetSelectedAgent
  , preparedCredentialTargetId
  , preparedCredentialTargetGeneration
  , preparedCredentialTargetRequestDigest
  , preparedCredentialTargetReceiptDigest
  , preparedCredentialTargetPlanBinding
  , preparedCredentialTargetDeadline
  , AwsAdminIamBoundary
  , mkAwsAdminIamBoundary
  , productionAwsAdminIamBoundary
  , AwsAdminTargetObservationCause (..)
  , allAwsAdminTargetObservationCauses
  , renderAwsAdminTargetObservationCause
  , AwsAdminTargetIntentIssueCause (..)
  , allAwsAdminTargetIntentIssueCauses
  , renderAwsAdminTargetIntentIssueCause
  , AwsAdminTargetWorkerCause (..)
  , AwsAdminTargetWorkerObservationCause (..)
  , allAwsAdminTargetWorkerObservationCauses
  , classifyAwsAdminTargetWorkerObservationFailure
  , renderAwsAdminTargetWorkerObservationCause
  , allAwsAdminTargetWorkerCauses
  , renderAwsAdminTargetWorkerCause
  , AwsAdminTargetDeliveryCause (..)
  , allAwsAdminTargetDeliveryCauses
  , renderAwsAdminTargetDeliveryCause
  , AwsAdminRecoveryRemintCause (..)
  , allAwsAdminRecoveryRemintCauses
  , renderAwsAdminRecoveryRemintCause
  , AwsAdminDeliveryBoundary (..)
  , mkAwsAdminDeliveryBoundary
  , AwsAdminExecutionJournalBoundary
  , mkAwsAdminExecutionJournalBoundary
  , AwsAdminWorkerReceipt
  , AwsAdminWorkerReceiptKind (..)
  , awsAdminWorkerReceiptKind
  , awsAdminWorkerReceiptPermitId
  , awsAdminWorkerReceiptRequestDigest
  , awsAdminWorkerReceiptTarget
  , awsAdminWorkerReceiptGeneration
  , awsAdminWorkerReceiptTargetReadBack
  , encodeAwsAdminWorkerReceipt
  , decodeAwsAdminWorkerReceipt
  , encodeAwsAdminWorkerReceiptTextEnvelope
  , decodeAwsAdminWorkerReceiptTextEnvelope
  , AwsAdminWorkerReceiptCaptureSize (..)
  , AwsAdminWorkerReceiptDecodeCause (..)
  , AwsAdminWorkerReceiptEnvelopeDecodeCause (..)
  , AwsAdminWorkerReceiptTerminalEnding (..)
  , AwsAdminWorkerReceiptLineTopology (..)
  , AwsAdminWorkerReceiptEnvelopeLineDisposition (..)
  , AwsAdminWorkerReceiptPrefixLineDisposition (..)
  , AwsAdminWorkerExecutionCause (..)
  , allAwsAdminWorkerExecutionCauses
  , AwsAdminWorkerSessionClosureCause (..)
  , AwsAdminWorkerActionProgress (..)
  , AwsAdminWorkerJournalUnavailableCause (..)
  , allAwsAdminWorkerJournalUnavailableCauses
  , allAwsAdminWorkerSessionClosureCauses
  , classifyAwsAdminWorkerJournalUnavailable
  , AwsAdminWorkerTerminalCause (..)
  , AwsAdminWorkerTerminalLineDisposition (..)
  , allAwsAdminWorkerTerminalCauses
  , AwsAdminWorkerReceiptTransportObservation
  , classifyAwsAdminWorkerReceiptTransport
  , renderAwsAdminWorkerReceiptCaptureSize
  , renderAwsAdminWorkerReceiptDecodeCause
  , renderAwsAdminWorkerReceiptEnvelopeDecodeCause
  , renderAwsAdminWorkerReceiptTerminalEnding
  , renderAwsAdminWorkerReceiptLineTopology
  , renderAwsAdminWorkerReceiptEnvelopeLineDisposition
  , renderAwsAdminWorkerReceiptPrefixLineDisposition
  , renderAwsAdminWorkerExecutionCause
  , renderAwsAdminWorkerJournalUnavailableCause
  , renderAwsAdminWorkerSessionClosureCause
  , renderAwsAdminWorkerTerminalCause
  , renderAwsAdminWorkerTerminalLineDisposition
  , renderAwsAdminWorkerReceiptTransportObservation
  , validateAwsAdminWorkerReceiptForPermit
  , executeAwsAdminPermit
  , AwsAdminExecutionError (..)
  , classifyAwsAdminExecutionError
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (foldM, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.List (sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16, Word8)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRolePlainResponseObservation
  , allAuthenticatedRolePlainResponseObservations
  , renderAuthenticatedRolePlainResponseObservation
  )
import Prodbox.ControlPlane.TargetAuthorityTrust
  ( TargetAuthorityTrustBoundaryCause
  , allTargetAuthorityTrustBoundaryCauses
  , renderTargetAuthorityTrustBoundaryCause
  )
import Prodbox.ControlPlane.TargetMaterialClient
  ( TargetMaterialClientCause
  , allTargetMaterialClientCauses
  , renderTargetMaterialClientCause
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (..)
  , TargetSecretId (..)
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentRolloutObservationCause
  , allTargetAgentRolloutObservationCauses
  , renderTargetAgentRolloutObservationCause
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerReceipt
  , decodeTargetWorkerReceipt
  , encodeTargetWorkerReceipt
  , targetWorkerReceiptGeneration
  , targetWorkerReceiptTarget
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecutionJournal
  ( AwsAdminExecutionEvent (..)
  , AwsAdminExecutionJournal
  , AwsAdminExecutionPhase (..)
  , awsAdminExecutionJournalPermit
  , awsAdminExecutionJournalPhase
  , stepAwsAdminExecutionJournal
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( SignedAwsAdminPermit
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentCredentialClass
  , awsAdminPermitIntentDeadline
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentIamParameters
  , awsAdminPermitIntentPermitId
  , awsAdminPermitIntentPlanBinding
  , awsAdminPermitIntentPreparedTarget
  , awsAdminPermitIntentRequestDigest
  , credentialIamParametersRegion
  , signedAwsAdminPermitIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.Execution
  ( AccessKeyInventoryObservation (..)
  , AwsAccessKeyCreateAmbiguityCause (..)
  , AwsAccessKeyCreateResult (..)
  , CredentialRevocationRefusal (..)
  , ProvisionedAccessKeyId
  , RevokedIdentityObservation (..)
  , RevokedTargetObservation (..)
  , decideCredentialRevocationReadBack
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , OperatorMaterialAction (..)
  , OperatorMaterialIngressSchema (AwsAdminProvisioningIngress)
  , awsCredentialDescriptor
  , awsCredentialDescriptorTarget
  , operatorMaterialPermitIdText
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( PreparedCredentialTargetObservation
  , mkPreparedCredentialTargetObservation
  , preparedCredentialTargetDeadline
  , preparedCredentialTargetFence
  , preparedCredentialTargetGeneration
  , preparedCredentialTargetId
  , preparedCredentialTargetOwnerNonce
  , preparedCredentialTargetPlanBinding
  , preparedCredentialTargetReceiptDigest
  , preparedCredentialTargetRequestDigest
  , preparedCredentialTargetSelectedAgent
  )
import Prodbox.Lifecycle.CredentialProvisioner.ProductionIam
  ( ProductionIamErrorCause (ProductionIamErrorUnclassified)
  , ProductionIamSession
  , allProductionIamErrorCauses
  , classifyProductionIamError
  , createProductionAccessKey
  , deleteProductionAccessKey
  , destroyProductionIamIdentity
  , ensureProductionIamPrerequisites
  , observeProductionAccessKeyInventory
  , observeProductionIamFamilyAbsent
  , productionIamJointAuthorization
  , renderProductionIamErrorCause
  , waitProductionIamVisibilityGrace
  )
import Prodbox.Lifecycle.CredentialProvisioner.TargetMaterial
  ( CreatedAwsAccessKey
  , ProvisionedTargetMaterial
  , TargetMaterialValueError
  , deriveSesSmtpSource
  , mkAwsCredentialMaterial
  )
import Prodbox.Lifecycle.Lease (authorityTimeMicros)
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , targetValueDigestText
  )

data AwsAdminIamBoundary m = AwsAdminIamBoundary
  { internalEnsureIamPrerequisites :: m (Either ProductionIamErrorCause ())
  , internalObserveIamKeys :: m AccessKeyInventoryObservation
  , internalDeleteIamKey :: ProvisionedAccessKeyId -> m (Either Text ())
  , internalCreateIamKey :: m AwsAccessKeyCreateResult
  , internalDestroyIamIdentity :: m (Either Text ())
  , internalObserveIamIdentityAbsent :: m (Either Text Bool)
  , internalWaitIamVisibilityGrace :: m (Either Text ())
  }

mkAwsAdminIamBoundary
  :: (Functor m)
  => m (Either Text ())
  -> m AccessKeyInventoryObservation
  -> (ProvisionedAccessKeyId -> m (Either Text ()))
  -> m AwsAccessKeyCreateResult
  -> m (Either Text ())
  -> m (Either Text Bool)
  -> m (Either Text ())
  -> AwsAdminIamBoundary m
mkAwsAdminIamBoundary ensurePrerequisites observeKeysAction deleteKey createKey destroyIdentity observeIdentityAbsent waitVisibility =
  AwsAdminIamBoundary
    { internalEnsureIamPrerequisites = do
        either
          (const (Left ProductionIamErrorUnclassified))
          Right
          <$> ensurePrerequisites
    , internalObserveIamKeys = observeKeysAction
    , internalDeleteIamKey = deleteKey
    , internalCreateIamKey = createKey
    , internalDestroyIamIdentity = destroyIdentity
    , internalObserveIamIdentityAbsent = observeIdentityAbsent
    , internalWaitIamVisibilityGrace = waitVisibility
    }

productionAwsAdminIamBoundary :: ProductionIamSession -> AwsAdminIamBoundary IO
productionAwsAdminIamBoundary session =
  AwsAdminIamBoundary
    { internalEnsureIamPrerequisites =
        either (Left . classifyProductionIamError) Right
          <$> ensureProductionIamPrerequisites session
    , internalObserveIamKeys = observeProductionAccessKeyInventory session
    , internalDeleteIamKey = deleteProductionAccessKey session
    , internalCreateIamKey = createProductionAccessKey session
    , -- Sprint 7.36: both arms decide through the joint family disposition, so
      -- "the destroy returned" and "the family is gone" are no longer the same
      -- answer. A partial destroy refuses here naming every surviving member.
      internalDestroyIamIdentity = case productionIamJointAuthorization session of
        Left err -> pure (Left (boundedShow err))
        Right authorization ->
          either (Left . boundedShow) (const (Right ()))
            <$> destroyProductionIamIdentity authorization session
    , internalObserveIamIdentityAbsent = case productionIamJointAuthorization session of
        Left err -> pure (Left (boundedShow err))
        Right authorization -> do
          result <- observeProductionIamFamilyAbsent authorization session
          pure $ case result of
            Left err -> Left (boundedShow err)
            Right _ -> Right True
    , internalWaitIamVisibilityGrace = waitProductionIamVisibilityGrace
    }

-- | Closed observation failures shared by the direct Target Agent and the
-- retained SES custody branch. No transport, Vault, or delivery detail is
-- representable in a worker terminal receipt.
data AwsAdminTargetObservationCause
  = AwsAdminTargetObservationPermitSubstitution
  | AwsAdminTargetObservationClient !TargetMaterialClientCause
  | AwsAdminTargetObservationGenerationAdvanced
  | AwsAdminTargetObservationReceiptInvalid
  | AwsAdminTargetObservationRetainedGenerationMismatch
  | AwsAdminTargetObservationRetainedCorrupt
  | AwsAdminTargetObservationRetainedDigestMismatch
  | AwsAdminTargetObservationRetainedUnobservable
  | AwsAdminTargetObservationRetainedDeliveryFailed
  deriving stock (Eq, Show)

allAwsAdminTargetObservationCauses :: [AwsAdminTargetObservationCause]
allAwsAdminTargetObservationCauses =
  [AwsAdminTargetObservationPermitSubstitution]
    <> fmap AwsAdminTargetObservationClient allTargetMaterialClientCauses
    <> [ AwsAdminTargetObservationGenerationAdvanced
       , AwsAdminTargetObservationReceiptInvalid
       , AwsAdminTargetObservationRetainedGenerationMismatch
       , AwsAdminTargetObservationRetainedCorrupt
       , AwsAdminTargetObservationRetainedDigestMismatch
       , AwsAdminTargetObservationRetainedUnobservable
       , AwsAdminTargetObservationRetainedDeliveryFailed
       ]

renderAwsAdminTargetObservationCause :: AwsAdminTargetObservationCause -> Text
renderAwsAdminTargetObservationCause cause = case cause of
  AwsAdminTargetObservationPermitSubstitution -> "permit-substitution"
  AwsAdminTargetObservationClient clientCause ->
    "client/" <> renderTargetMaterialClientCause clientCause
  AwsAdminTargetObservationGenerationAdvanced -> "generation-advanced"
  AwsAdminTargetObservationReceiptInvalid -> "receipt-invalid"
  AwsAdminTargetObservationRetainedGenerationMismatch ->
    "retained/generation-mismatch"
  AwsAdminTargetObservationRetainedCorrupt -> "retained/corrupt"
  AwsAdminTargetObservationRetainedDigestMismatch -> "retained/digest-mismatch"
  AwsAdminTargetObservationRetainedUnobservable -> "retained/unobservable"
  AwsAdminTargetObservationRetainedDeliveryFailed -> "retained/delivery-failed"

-- | Closed response-side causes for the initial Authority Target-intent call.
-- Raw status numbers, response text, transport detail, and retained values do
-- not cross this diagnostic boundary.
data AwsAdminTargetIntentIssueCause
  = AwsAdminTargetIntentTransportFailed
  | AwsAdminTargetIntentResponseInvalid
  | AwsAdminTargetIntentAuthenticatedResponseInvalid
      !AuthenticatedRolePlainResponseObservation
  | AwsAdminTargetIntentHttpBadRequest
  | AwsAdminTargetIntentHttpUnauthorized
  | AwsAdminTargetIntentHttpForbidden
  | AwsAdminTargetIntentHttpNotFound
  | AwsAdminTargetIntentHttpConflict
  | AwsAdminTargetIntentHttpTooManyRequests
  | AwsAdminTargetIntentHttpServerError
  | AwsAdminTargetIntentHttpOther
  | AwsAdminTargetIntentRefusedAgentIdentityInvalid
  | AwsAdminTargetIntentRefusedGenerationInvalid
  | AwsAdminTargetIntentRefusedReceiptDigestInvalid
  | AwsAdminTargetIntentRefusedCallerForbidden
  | AwsAdminTargetIntentRefusedSignerRotated
  | AwsAdminTargetIntentRefusedTargetUnregistered
  | AwsAdminTargetIntentRefusedTargetMismatch
  | AwsAdminTargetIntentRefusedAgentIdentityMismatch
  | AwsAdminTargetIntentRefusedNotPrepared
  | AwsAdminTargetIntentRefusedGenerationMismatch
  | AwsAdminTargetIntentRefusedReceiptDigestMismatch
  | AwsAdminTargetIntentRefusedDeadlineReached
  | AwsAdminTargetIntentRefusedValueInvalid
  | AwsAdminTargetIntentRefusedSignatureInvalid
  | AwsAdminTargetIntentRefusedTrustReadBackMismatch
  | AwsAdminTargetIntentRefusedOther
  | AwsAdminTargetIntentUnavailablePreparedIntent
  | AwsAdminTargetIntentUnavailableClock
  | AwsAdminTargetIntentUnavailableEpoch
  | AwsAdminTargetIntentUnavailableSigner
  | AwsAdminTargetIntentUnavailableTrustInstall !TargetAuthorityTrustBoundaryCause
  | AwsAdminTargetIntentUnavailableOther
  | AwsAdminTargetIntentSignedIntentInvalid
  | AwsAdminTargetIntentTrustRecordInvalid
  | AwsAdminTargetIntentExecutionPermitInvalid
  deriving stock (Eq, Show)

allAwsAdminTargetIntentIssueCauses :: [AwsAdminTargetIntentIssueCause]
allAwsAdminTargetIntentIssueCauses =
  [ AwsAdminTargetIntentTransportFailed
  , AwsAdminTargetIntentResponseInvalid
  ]
    <> fmap
      AwsAdminTargetIntentAuthenticatedResponseInvalid
      allAuthenticatedRolePlainResponseObservations
    <> [ AwsAdminTargetIntentHttpBadRequest
       , AwsAdminTargetIntentHttpUnauthorized
       , AwsAdminTargetIntentHttpForbidden
       , AwsAdminTargetIntentHttpNotFound
       , AwsAdminTargetIntentHttpConflict
       , AwsAdminTargetIntentHttpTooManyRequests
       , AwsAdminTargetIntentHttpServerError
       , AwsAdminTargetIntentHttpOther
       , AwsAdminTargetIntentRefusedAgentIdentityInvalid
       , AwsAdminTargetIntentRefusedGenerationInvalid
       , AwsAdminTargetIntentRefusedReceiptDigestInvalid
       , AwsAdminTargetIntentRefusedCallerForbidden
       , AwsAdminTargetIntentRefusedSignerRotated
       , AwsAdminTargetIntentRefusedTargetUnregistered
       , AwsAdminTargetIntentRefusedTargetMismatch
       , AwsAdminTargetIntentRefusedAgentIdentityMismatch
       , AwsAdminTargetIntentRefusedNotPrepared
       , AwsAdminTargetIntentRefusedGenerationMismatch
       , AwsAdminTargetIntentRefusedReceiptDigestMismatch
       , AwsAdminTargetIntentRefusedDeadlineReached
       , AwsAdminTargetIntentRefusedValueInvalid
       , AwsAdminTargetIntentRefusedSignatureInvalid
       , AwsAdminTargetIntentRefusedTrustReadBackMismatch
       , AwsAdminTargetIntentRefusedOther
       , AwsAdminTargetIntentUnavailablePreparedIntent
       , AwsAdminTargetIntentUnavailableClock
       , AwsAdminTargetIntentUnavailableEpoch
       , AwsAdminTargetIntentUnavailableSigner
       ]
    <> fmap
      AwsAdminTargetIntentUnavailableTrustInstall
      allTargetAuthorityTrustBoundaryCauses
    <> [ AwsAdminTargetIntentUnavailableOther
       , AwsAdminTargetIntentSignedIntentInvalid
       , AwsAdminTargetIntentTrustRecordInvalid
       , AwsAdminTargetIntentExecutionPermitInvalid
       ]

renderAwsAdminTargetIntentIssueCause :: AwsAdminTargetIntentIssueCause -> Text
renderAwsAdminTargetIntentIssueCause cause = case cause of
  AwsAdminTargetIntentTransportFailed -> "transport-failed"
  AwsAdminTargetIntentResponseInvalid -> "response-invalid"
  AwsAdminTargetIntentAuthenticatedResponseInvalid observation ->
    "authenticated-response-invalid/"
      <> renderAuthenticatedRolePlainResponseObservation observation
  AwsAdminTargetIntentHttpBadRequest -> "http/bad-request"
  AwsAdminTargetIntentHttpUnauthorized -> "http/unauthorized"
  AwsAdminTargetIntentHttpForbidden -> "http/forbidden"
  AwsAdminTargetIntentHttpNotFound -> "http/not-found"
  AwsAdminTargetIntentHttpConflict -> "http/conflict"
  AwsAdminTargetIntentHttpTooManyRequests -> "http/too-many-requests"
  AwsAdminTargetIntentHttpServerError -> "http/server-error"
  AwsAdminTargetIntentHttpOther -> "http/other"
  AwsAdminTargetIntentRefusedAgentIdentityInvalid -> "refused/agent-identity-invalid"
  AwsAdminTargetIntentRefusedGenerationInvalid -> "refused/generation-invalid"
  AwsAdminTargetIntentRefusedReceiptDigestInvalid -> "refused/receipt-digest-invalid"
  AwsAdminTargetIntentRefusedCallerForbidden -> "refused/caller-forbidden"
  AwsAdminTargetIntentRefusedSignerRotated -> "refused/signer-rotated"
  AwsAdminTargetIntentRefusedTargetUnregistered -> "refused/target-unregistered"
  AwsAdminTargetIntentRefusedTargetMismatch -> "refused/target-mismatch"
  AwsAdminTargetIntentRefusedAgentIdentityMismatch -> "refused/agent-identity-mismatch"
  AwsAdminTargetIntentRefusedNotPrepared -> "refused/not-prepared"
  AwsAdminTargetIntentRefusedGenerationMismatch -> "refused/generation-mismatch"
  AwsAdminTargetIntentRefusedReceiptDigestMismatch -> "refused/receipt-digest-mismatch"
  AwsAdminTargetIntentRefusedDeadlineReached -> "refused/deadline-reached"
  AwsAdminTargetIntentRefusedValueInvalid -> "refused/value-invalid"
  AwsAdminTargetIntentRefusedSignatureInvalid -> "refused/signature-invalid"
  AwsAdminTargetIntentRefusedTrustReadBackMismatch -> "refused/trust-read-back-mismatch"
  AwsAdminTargetIntentRefusedOther -> "refused/other"
  AwsAdminTargetIntentUnavailablePreparedIntent -> "unavailable/prepared-intent"
  AwsAdminTargetIntentUnavailableClock -> "unavailable/clock"
  AwsAdminTargetIntentUnavailableEpoch -> "unavailable/epoch"
  AwsAdminTargetIntentUnavailableSigner -> "unavailable/signer"
  AwsAdminTargetIntentUnavailableTrustInstall trust ->
    "unavailable/trust-install/" <> renderTargetAuthorityTrustBoundaryCause trust
  AwsAdminTargetIntentUnavailableOther -> "unavailable/other"
  AwsAdminTargetIntentSignedIntentInvalid -> "signed-intent-invalid"
  AwsAdminTargetIntentTrustRecordInvalid -> "trust-record-invalid"
  AwsAdminTargetIntentExecutionPermitInvalid -> "execution-permit-invalid"

-- | The closed coordinator stage reached after successful Target-intent
-- issuance. Nested text and identity-bearing errors are erased.
data AwsAdminTargetWorkerObservationCause
  = AwsAdminTargetWorkerObservationPodKubernetesExit
  | AwsAdminTargetWorkerObservationPodListInvalid
  | AwsAdminTargetWorkerObservationMultiplePods
  | AwsAdminTargetWorkerObservationJobLabelMismatch
  | AwsAdminTargetWorkerObservationControllingJobUidInvalid
  | AwsAdminTargetWorkerObservationContainerMissing
  | AwsAdminTargetWorkerObservationDeclaredImageEmpty
  | AwsAdminTargetWorkerObservationContainerStatusMissing
  | AwsAdminTargetWorkerObservationRuntimeImageIdentityInvalid
  | AwsAdminTargetWorkerObservationImageDigestMismatch
  | AwsAdminTargetWorkerObservationAnnotationMismatch
  | AwsAdminTargetWorkerObservationServiceAccountKubernetesExit
  | AwsAdminTargetWorkerObservationServiceAccountResponseInvalid
  | AwsAdminTargetWorkerObservationServiceAccountNameMismatch
  | AwsAdminTargetWorkerObservationServiceAccountNamespaceMismatch
  | AwsAdminTargetWorkerObservationServiceAccountUidInvalid
  | AwsAdminTargetWorkerObservationOther
  deriving stock (Eq, Show, Enum, Bounded)

allAwsAdminTargetWorkerObservationCauses :: [AwsAdminTargetWorkerObservationCause]
allAwsAdminTargetWorkerObservationCauses = [minBound .. maxBound]

classifyAwsAdminTargetWorkerObservationFailure
  :: Text -> AwsAdminTargetWorkerObservationCause
classifyAwsAdminTargetWorkerObservationFailure detail
  | "Target worker Pod annotation mismatch:" `Text.isPrefixOf` detail =
      AwsAdminTargetWorkerObservationAnnotationMismatch
  | otherwise = case detail of
      "Target worker Job Pod is not observable" ->
        AwsAdminTargetWorkerObservationPodKubernetesExit
      "Kubernetes Target worker Pod-list response is invalid" ->
        AwsAdminTargetWorkerObservationPodListInvalid
      "Target worker Job has multiple Pods" ->
        AwsAdminTargetWorkerObservationMultiplePods
      "Target worker Pod Job label mismatch" ->
        AwsAdminTargetWorkerObservationJobLabelMismatch
      "Target worker Pod has no unique controlling Job UID" ->
        AwsAdminTargetWorkerObservationControllingJobUidInvalid
      "Target worker container is missing" ->
        AwsAdminTargetWorkerObservationContainerMissing
      "Target worker declared image is empty" ->
        AwsAdminTargetWorkerObservationDeclaredImageEmpty
      "Target worker container status is missing" ->
        AwsAdminTargetWorkerObservationContainerStatusMissing
      "Target worker runtime image identity is invalid" ->
        AwsAdminTargetWorkerObservationRuntimeImageIdentityInvalid
      "Target worker image digest mismatch" ->
        AwsAdminTargetWorkerObservationImageDigestMismatch
      "Target worker ServiceAccount is not observable" ->
        AwsAdminTargetWorkerObservationServiceAccountKubernetesExit
      "Kubernetes Target worker ServiceAccount response is invalid" ->
        AwsAdminTargetWorkerObservationServiceAccountResponseInvalid
      "Target worker ServiceAccount name mismatch" ->
        AwsAdminTargetWorkerObservationServiceAccountNameMismatch
      "Target worker ServiceAccount namespace mismatch" ->
        AwsAdminTargetWorkerObservationServiceAccountNamespaceMismatch
      "Target worker ServiceAccount UID is invalid" ->
        AwsAdminTargetWorkerObservationServiceAccountUidInvalid
      _ -> AwsAdminTargetWorkerObservationOther

renderAwsAdminTargetWorkerObservationCause
  :: AwsAdminTargetWorkerObservationCause -> Text
renderAwsAdminTargetWorkerObservationCause cause = case cause of
  AwsAdminTargetWorkerObservationPodKubernetesExit -> "pod-kubernetes-exit"
  AwsAdminTargetWorkerObservationPodListInvalid -> "pod-list-invalid"
  AwsAdminTargetWorkerObservationMultiplePods -> "multiple-pods"
  AwsAdminTargetWorkerObservationJobLabelMismatch -> "job-label-mismatch"
  AwsAdminTargetWorkerObservationControllingJobUidInvalid -> "controlling-job-uid-invalid"
  AwsAdminTargetWorkerObservationContainerMissing -> "container-missing"
  AwsAdminTargetWorkerObservationDeclaredImageEmpty -> "declared-image-empty"
  AwsAdminTargetWorkerObservationContainerStatusMissing -> "container-status-missing"
  AwsAdminTargetWorkerObservationRuntimeImageIdentityInvalid -> "runtime-image-identity-invalid"
  AwsAdminTargetWorkerObservationImageDigestMismatch -> "image-digest-mismatch"
  AwsAdminTargetWorkerObservationAnnotationMismatch -> "annotation-mismatch"
  AwsAdminTargetWorkerObservationServiceAccountKubernetesExit ->
    "service-account-kubernetes-exit"
  AwsAdminTargetWorkerObservationServiceAccountResponseInvalid ->
    "service-account-response-invalid"
  AwsAdminTargetWorkerObservationServiceAccountNameMismatch -> "service-account-name-mismatch"
  AwsAdminTargetWorkerObservationServiceAccountNamespaceMismatch ->
    "service-account-namespace-mismatch"
  AwsAdminTargetWorkerObservationServiceAccountUidInvalid -> "service-account-uid-invalid"
  AwsAdminTargetWorkerObservationOther -> "other"

data AwsAdminTargetWorkerCause
  = AwsAdminTargetWorkerAgentIdentityUnavailable !TargetAgentRolloutObservationCause
  | AwsAdminTargetWorkerAgentIdentityMismatch
  | AwsAdminTargetWorkerIntentRejected
  | AwsAdminTargetWorkerCreateFailed
  | AwsAdminTargetWorkerObservationFailed !AwsAdminTargetWorkerObservationCause
  | AwsAdminTargetWorkerWorkloadAbsent
  | AwsAdminTargetWorkerCleanupBindingInvalid
  | AwsAdminTargetWorkerAttestationFailed
  | AwsAdminTargetWorkerSessionPrepareFailed
  | AwsAdminTargetWorkerPermitUnavailable
  | AwsAdminTargetWorkerPermitRejected
  | AwsAdminTargetWorkerPermitBindingMismatch
  | AwsAdminTargetWorkerFrameRejected
  | AwsAdminTargetWorkerAttachFailed
  | AwsAdminTargetWorkerProvisionalRejected
  | AwsAdminTargetWorkerReceiptBindingMismatch
  | AwsAdminTargetWorkerSessionActivateFailed
  | AwsAdminTargetWorkerMaterializationRefused
  | AwsAdminTargetWorkerSessionCleanupFailed
  | AwsAdminTargetWorkerDeleteFailed
  | AwsAdminTargetWorkerAbsenceUnobservable
  | AwsAdminTargetWorkerStillPresent
  | AwsAdminTargetWorkerUnhandledException
  deriving stock (Eq, Show)

allAwsAdminTargetWorkerCauses :: [AwsAdminTargetWorkerCause]
allAwsAdminTargetWorkerCauses =
  fmap AwsAdminTargetWorkerAgentIdentityUnavailable allTargetAgentRolloutObservationCauses
    <> [ AwsAdminTargetWorkerAgentIdentityMismatch
       , AwsAdminTargetWorkerIntentRejected
       , AwsAdminTargetWorkerCreateFailed
       ]
    <> fmap
      AwsAdminTargetWorkerObservationFailed
      allAwsAdminTargetWorkerObservationCauses
    <> [ AwsAdminTargetWorkerWorkloadAbsent
       , AwsAdminTargetWorkerCleanupBindingInvalid
       , AwsAdminTargetWorkerAttestationFailed
       , AwsAdminTargetWorkerSessionPrepareFailed
       , AwsAdminTargetWorkerPermitUnavailable
       , AwsAdminTargetWorkerPermitRejected
       , AwsAdminTargetWorkerPermitBindingMismatch
       , AwsAdminTargetWorkerFrameRejected
       , AwsAdminTargetWorkerAttachFailed
       , AwsAdminTargetWorkerProvisionalRejected
       , AwsAdminTargetWorkerReceiptBindingMismatch
       , AwsAdminTargetWorkerSessionActivateFailed
       , AwsAdminTargetWorkerMaterializationRefused
       , AwsAdminTargetWorkerSessionCleanupFailed
       , AwsAdminTargetWorkerDeleteFailed
       , AwsAdminTargetWorkerAbsenceUnobservable
       , AwsAdminTargetWorkerStillPresent
       , AwsAdminTargetWorkerUnhandledException
       ]

renderAwsAdminTargetWorkerCause :: AwsAdminTargetWorkerCause -> Text
renderAwsAdminTargetWorkerCause cause = case cause of
  AwsAdminTargetWorkerAgentIdentityUnavailable observationCause ->
    "agent-identity-unavailable/"
      <> renderTargetAgentRolloutObservationCause observationCause
  AwsAdminTargetWorkerAgentIdentityMismatch -> "agent-identity-mismatch"
  AwsAdminTargetWorkerIntentRejected -> "intent-rejected"
  AwsAdminTargetWorkerCreateFailed -> "create-failed"
  AwsAdminTargetWorkerObservationFailed observationCause ->
    "observation-failed/" <> renderAwsAdminTargetWorkerObservationCause observationCause
  AwsAdminTargetWorkerWorkloadAbsent -> "workload-absent"
  AwsAdminTargetWorkerCleanupBindingInvalid -> "cleanup-binding-invalid"
  AwsAdminTargetWorkerAttestationFailed -> "attestation-failed"
  AwsAdminTargetWorkerSessionPrepareFailed -> "session-prepare-failed"
  AwsAdminTargetWorkerPermitUnavailable -> "permit-unavailable"
  AwsAdminTargetWorkerPermitRejected -> "permit-rejected"
  AwsAdminTargetWorkerPermitBindingMismatch -> "permit-binding-mismatch"
  AwsAdminTargetWorkerFrameRejected -> "frame-rejected"
  AwsAdminTargetWorkerAttachFailed -> "attach-failed"
  AwsAdminTargetWorkerProvisionalRejected -> "provisional-rejected"
  AwsAdminTargetWorkerReceiptBindingMismatch -> "receipt-binding-mismatch"
  AwsAdminTargetWorkerSessionActivateFailed -> "session-activate-failed"
  AwsAdminTargetWorkerMaterializationRefused -> "materialization-refused"
  AwsAdminTargetWorkerSessionCleanupFailed -> "session-cleanup-failed"
  AwsAdminTargetWorkerDeleteFailed -> "delete-failed"
  AwsAdminTargetWorkerAbsenceUnobservable -> "absence-unobservable"
  AwsAdminTargetWorkerStillPresent -> "still-present"
  AwsAdminTargetWorkerUnhandledException -> "unhandled-exception"

-- | Exhaustive value-free projection of every production direct-delivery
-- entrance and the two closed workflow families below it.
data AwsAdminTargetDeliveryCause
  = AwsAdminTargetDeliveryUnclassified
  | AwsAdminTargetDeliveryPermitSubstitution
  | AwsAdminTargetDeliveryPayloadInvalid
  | AwsAdminTargetDeliveryPreparedTargetMismatch
  | AwsAdminTargetDeliveryPayloadTargetMismatch
  | AwsAdminTargetDeliveryRetainedTargetRequired
  | AwsAdminTargetDeliveryRevokeRejected
  | AwsAdminTargetDeliverySchemaUnavailable
  | AwsAdminTargetDeliverySchemaMismatch
  | AwsAdminTargetDeliveryImageInvalid
  | AwsAdminTargetDeliveryTimeUnavailable
  | AwsAdminTargetDeliveryControllerTokenUnavailable
  | AwsAdminTargetDeliveryAuditorLoginUnavailable
  | AwsAdminTargetDeliveryAuditorLoginInvalid
  | AwsAdminTargetDeliveryIntentIssue !AwsAdminTargetIntentIssueCause
  | AwsAdminTargetDeliveryWorker !AwsAdminTargetWorkerCause
  | AwsAdminTargetDeliveryRetainedCustody
  deriving stock (Eq, Show)

allAwsAdminTargetDeliveryCauses :: [AwsAdminTargetDeliveryCause]
allAwsAdminTargetDeliveryCauses =
  [ AwsAdminTargetDeliveryUnclassified
  , AwsAdminTargetDeliveryPermitSubstitution
  , AwsAdminTargetDeliveryPayloadInvalid
  , AwsAdminTargetDeliveryPreparedTargetMismatch
  , AwsAdminTargetDeliveryPayloadTargetMismatch
  , AwsAdminTargetDeliveryRetainedTargetRequired
  , AwsAdminTargetDeliveryRevokeRejected
  , AwsAdminTargetDeliverySchemaUnavailable
  , AwsAdminTargetDeliverySchemaMismatch
  , AwsAdminTargetDeliveryImageInvalid
  , AwsAdminTargetDeliveryTimeUnavailable
  , AwsAdminTargetDeliveryControllerTokenUnavailable
  , AwsAdminTargetDeliveryAuditorLoginUnavailable
  , AwsAdminTargetDeliveryAuditorLoginInvalid
  ]
    <> fmap AwsAdminTargetDeliveryIntentIssue allAwsAdminTargetIntentIssueCauses
    <> fmap AwsAdminTargetDeliveryWorker allAwsAdminTargetWorkerCauses
    <> [AwsAdminTargetDeliveryRetainedCustody]

renderAwsAdminTargetDeliveryCause :: AwsAdminTargetDeliveryCause -> Text
renderAwsAdminTargetDeliveryCause cause = case cause of
  AwsAdminTargetDeliveryUnclassified -> "unclassified"
  AwsAdminTargetDeliveryPermitSubstitution -> "permit-substitution"
  AwsAdminTargetDeliveryPayloadInvalid -> "payload-invalid"
  AwsAdminTargetDeliveryPreparedTargetMismatch -> "prepared-target-mismatch"
  AwsAdminTargetDeliveryPayloadTargetMismatch -> "payload-target-mismatch"
  AwsAdminTargetDeliveryRetainedTargetRequired -> "retained-target-required"
  AwsAdminTargetDeliveryRevokeRejected -> "revoke-rejected"
  AwsAdminTargetDeliverySchemaUnavailable -> "schema-unavailable"
  AwsAdminTargetDeliverySchemaMismatch -> "schema-mismatch"
  AwsAdminTargetDeliveryImageInvalid -> "image-invalid"
  AwsAdminTargetDeliveryTimeUnavailable -> "time-unavailable"
  AwsAdminTargetDeliveryControllerTokenUnavailable -> "controller-token-unavailable"
  AwsAdminTargetDeliveryAuditorLoginUnavailable -> "auditor-login-unavailable"
  AwsAdminTargetDeliveryAuditorLoginInvalid -> "auditor-login-invalid"
  AwsAdminTargetDeliveryIntentIssue intentCause ->
    "intent/" <> renderAwsAdminTargetIntentIssueCause intentCause
  AwsAdminTargetDeliveryWorker workerCause ->
    "worker/" <> renderAwsAdminTargetWorkerCause workerCause
  AwsAdminTargetDeliveryRetainedCustody -> "retained-custody"

data AwsAdminDeliveryBoundary m = AwsAdminDeliveryBoundary
  { internalDeliverCredentialTarget
      :: PreparedCredentialTargetObservation
      -> SignedAwsAdminPermit
      -> ProvisionedTargetMaterial 'AwsAdminProvisioningIngress
      -> m (Either AwsAdminTargetDeliveryCause TargetWorkerReceipt)
  , internalRevokeCredentialTarget
      :: PreparedCredentialTargetObservation
      -> SignedAwsAdminPermit
      -> m (Either Text Text)
  , internalObserveCredentialTarget
      :: PreparedCredentialTargetObservation
      -> SignedAwsAdminPermit
      -> m (Either AwsAdminTargetObservationCause (Maybe TargetWorkerReceipt))
  }

mkAwsAdminDeliveryBoundary
  :: ( PreparedCredentialTargetObservation
       -> SignedAwsAdminPermit
       -> ProvisionedTargetMaterial 'AwsAdminProvisioningIngress
       -> m (Either AwsAdminTargetDeliveryCause TargetWorkerReceipt)
     )
  -> ( PreparedCredentialTargetObservation
       -> SignedAwsAdminPermit
       -> m (Either Text Text)
     )
  -> ( PreparedCredentialTargetObservation
       -> SignedAwsAdminPermit
       -> m (Either AwsAdminTargetObservationCause (Maybe TargetWorkerReceipt))
     )
  -> AwsAdminDeliveryBoundary m
mkAwsAdminDeliveryBoundary = AwsAdminDeliveryBoundary

data AwsAdminExecutionJournalBoundary m = AwsAdminExecutionJournalBoundary
  { internalReadExecutionJournal
      :: m (Either Text AwsAdminExecutionJournal)
  , internalCommitExecutionJournal
      :: AwsAdminExecutionJournal
      -> AwsAdminExecutionJournal
      -> m (Either Text AwsAdminExecutionJournal)
  }

mkAwsAdminExecutionJournalBoundary
  :: m (Either Text AwsAdminExecutionJournal)
  -> ( AwsAdminExecutionJournal
       -> AwsAdminExecutionJournal
       -> m (Either Text AwsAdminExecutionJournal)
     )
  -> AwsAdminExecutionJournalBoundary m
mkAwsAdminExecutionJournalBoundary = AwsAdminExecutionJournalBoundary

data AwsAdminWorkerReceiptKind
  = AwsAdminInstalled
  | AwsAdminRevoked
  deriving stock (Eq, Show, Enum, Bounded)

data AwsAdminWorkerReceipt = AwsAdminWorkerReceipt
  { internalAwsAdminWorkerReceiptKind :: !AwsAdminWorkerReceiptKind
  , internalAwsAdminWorkerReceiptPermitId :: !Text
  , internalAwsAdminWorkerReceiptRequestDigest :: !TargetValueDigest
  , internalAwsAdminWorkerReceiptTarget :: !TargetSecretId
  , internalAwsAdminWorkerReceiptGeneration :: !CredentialGeneration
  , internalAwsAdminWorkerReceiptTargetReadBack :: !ByteString
  }
  deriving stock (Eq, Show)

data WireAwsAdminWorkerReceipt = WireAwsAdminWorkerReceipt
  { wireWorkerReceiptVersion :: !Word16
  , wireWorkerReceiptKind :: !Word8
  , wireWorkerReceiptPermitId :: !Text
  , wireWorkerReceiptRequestDigest :: !Text
  , wireWorkerReceiptTarget :: !TargetSecretId
  , wireWorkerReceiptGeneration :: !Natural
  , wireWorkerReceiptTargetReadBack :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

awsAdminWorkerReceiptVersion :: Word16
awsAdminWorkerReceiptVersion = 1

awsAdminWorkerReceiptMaximumBytes :: Int
awsAdminWorkerReceiptMaximumBytes = 32 * 1024

awsAdminWorkerReceiptKind :: AwsAdminWorkerReceipt -> AwsAdminWorkerReceiptKind
awsAdminWorkerReceiptKind = internalAwsAdminWorkerReceiptKind

awsAdminWorkerReceiptPermitId :: AwsAdminWorkerReceipt -> Text
awsAdminWorkerReceiptPermitId = internalAwsAdminWorkerReceiptPermitId

awsAdminWorkerReceiptRequestDigest :: AwsAdminWorkerReceipt -> TargetValueDigest
awsAdminWorkerReceiptRequestDigest = internalAwsAdminWorkerReceiptRequestDigest

awsAdminWorkerReceiptTarget :: AwsAdminWorkerReceipt -> TargetSecretId
awsAdminWorkerReceiptTarget = internalAwsAdminWorkerReceiptTarget

awsAdminWorkerReceiptGeneration :: AwsAdminWorkerReceipt -> CredentialGeneration
awsAdminWorkerReceiptGeneration = internalAwsAdminWorkerReceiptGeneration

awsAdminWorkerReceiptTargetReadBack :: AwsAdminWorkerReceipt -> ByteString
awsAdminWorkerReceiptTargetReadBack = internalAwsAdminWorkerReceiptTargetReadBack

encodeAwsAdminWorkerReceipt :: AwsAdminWorkerReceipt -> ByteString
encodeAwsAdminWorkerReceipt = LazyByteString.toStrict . serialise . receiptToWire

decodeAwsAdminWorkerReceipt
  :: ByteString -> Either AwsAdminExecutionError AwsAdminWorkerReceipt
decodeAwsAdminWorkerReceipt bytes = do
  when
    (ByteString.length bytes > awsAdminWorkerReceiptMaximumBytes)
    ( Left
        ( AwsAdminWorkerReceiptTooLarge
            (ByteString.length bytes)
            awsAdminWorkerReceiptMaximumBytes
        )
    )
  wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Left _ -> Left AwsAdminWorkerReceiptDecodeFailed
    Right value -> Right value
  unless
    (wireWorkerReceiptVersion wire == awsAdminWorkerReceiptVersion)
    (Left (AwsAdminWorkerReceiptUnsupportedVersion (wireWorkerReceiptVersion wire)))
  receipt <- receiptFromWire wire
  unless
    (encodeAwsAdminWorkerReceipt receipt == bytes)
    (Left AwsAdminWorkerReceiptNonCanonical)
  pure receipt

-- | Canonical ASCII armor for the line-oriented Kubernetes Pod-log fallback.
-- The inner receipt remains the sole semantic wire value and is still checked
-- by 'decodeAwsAdminWorkerReceipt' after the envelope is removed.
encodeAwsAdminWorkerReceiptTextEnvelope :: AwsAdminWorkerReceipt -> ByteString
encodeAwsAdminWorkerReceiptTextEnvelope receipt =
  awsAdminWorkerReceiptTextEnvelopePrefix
    <> Base64.encode (encodeAwsAdminWorkerReceipt receipt)

decodeAwsAdminWorkerReceiptTextEnvelope
  :: ByteString -> Either AwsAdminWorkerReceiptEnvelopeDecodeCause ByteString
decodeAwsAdminWorkerReceiptTextEnvelope bytes
  | ByteString.null bytes = Left AwsAdminWorkerReceiptEnvelopeDecodeInvalid
  | ByteString.length bytes > awsAdminWorkerReceiptTextEnvelopeMaximumBytes =
      Left AwsAdminWorkerReceiptEnvelopeDecodeTooLarge
  | otherwise = do
      encoded <-
        maybe
          (Left AwsAdminWorkerReceiptEnvelopeDecodeInvalid)
          Right
          (ByteString.stripPrefix awsAdminWorkerReceiptTextEnvelopePrefix bytes)
      decoded <-
        either
          (const (Left AwsAdminWorkerReceiptEnvelopeDecodeInvalid))
          Right
          (Base64.decode encoded)
      unless
        (Base64.encode decoded == encoded)
        (Left AwsAdminWorkerReceiptEnvelopeDecodeNonCanonical)
      pure decoded

awsAdminWorkerReceiptTextEnvelopeMaximumBytes :: Int
awsAdminWorkerReceiptTextEnvelopeMaximumBytes =
  ByteString.length awsAdminWorkerReceiptTextEnvelopePrefix
    + 4 * ((awsAdminWorkerReceiptMaximumBytes + 2) `div` 3)

awsAdminWorkerReceiptTextEnvelopePrefix :: ByteString
awsAdminWorkerReceiptTextEnvelopePrefix =
  "prodbox-aws-admin-worker-receipt-v1:"

-- | Value-free classification of the bounded stdout captured from one
-- credential worker.  These constructors deliberately describe only the
-- transport shape and decoder disposition; they cannot carry receipt bytes,
-- byte counts, versions, or credential-derived values.
data AwsAdminWorkerReceiptCaptureSize
  = AwsAdminWorkerReceiptCaptureEmpty
  | AwsAdminWorkerReceiptCaptureWithinBound
  | AwsAdminWorkerReceiptCaptureOversize
  deriving stock (Eq, Show, Enum, Bounded)

data AwsAdminWorkerReceiptDecodeCause
  = AwsAdminWorkerReceiptDecodeCanonical
  | AwsAdminWorkerReceiptDecodeTooLarge
  | AwsAdminWorkerReceiptDecodeMalformed
  | AwsAdminWorkerReceiptDecodeUnsupportedVersion
  | AwsAdminWorkerReceiptDecodeNonCanonical
  | AwsAdminWorkerReceiptDecodeInvalid
  deriving stock (Eq, Show, Enum, Bounded)

data AwsAdminWorkerReceiptEnvelopeDecodeCause
  = AwsAdminWorkerReceiptEnvelopeDecodeCanonical
  | AwsAdminWorkerReceiptEnvelopeDecodeTooLarge
  | AwsAdminWorkerReceiptEnvelopeDecodeInvalid
  | AwsAdminWorkerReceiptEnvelopeDecodeNonCanonical
  deriving stock (Eq, Show, Enum, Bounded)

data AwsAdminWorkerReceiptTerminalEnding
  = AwsAdminWorkerReceiptTerminalEndingAbsent
  | AwsAdminWorkerReceiptTerminalEndingLf
  | AwsAdminWorkerReceiptTerminalEndingCrlf
  deriving stock (Eq, Show, Enum, Bounded)

data AwsAdminWorkerReceiptLineTopology
  = AwsAdminWorkerReceiptLinesEmpty
  | AwsAdminWorkerReceiptLinesSingle
  | AwsAdminWorkerReceiptLinesMultiple
  deriving stock (Eq, Show, Enum, Bounded)

data AwsAdminWorkerReceiptEnvelopeLineDisposition
  = AwsAdminWorkerReceiptEnvelopeLinesNone
  | AwsAdminWorkerReceiptEnvelopeLineUnique
  | AwsAdminWorkerReceiptEnvelopeLinesAmbiguous
  deriving stock (Eq, Show, Enum, Bounded)

data AwsAdminWorkerReceiptPrefixLineDisposition
  = AwsAdminWorkerReceiptPrefixLinesNone
  | AwsAdminWorkerReceiptPrefixLineUnique
  | AwsAdminWorkerReceiptPrefixLinesAmbiguous
  deriving stock (Eq, Show, Enum, Bounded)

-- | Closed, value-free causes emitted by the worker on its sole terminal
-- refusal line. Payload-bearing worker errors collapse to their constructor;
-- no sizes, codec versions, exception text, or credential-derived value can
-- cross this diagnostic boundary.
data AwsAdminWorkerExecutionCause
  = AwsAdminWorkerExecutionUnclassified
  | AwsAdminWorkerExecutionPreparedTargetInvalid
  | AwsAdminWorkerExecutionPreparedTargetMismatch
  | AwsAdminWorkerExecutionPrepareTargetFailed
  | AwsAdminWorkerExecutionJournalUnavailable
  | AwsAdminWorkerExecutionJournalPermitMismatch
  | AwsAdminWorkerExecutionJournalTransitionRejected
  | AwsAdminWorkerExecutionJournalCommitFailed
  | AwsAdminWorkerExecutionJournalReadBackMismatch
  | AwsAdminWorkerExecutionTransitionLimitReached
  | AwsAdminWorkerExecutionIamPrerequisiteFailed !ProductionIamErrorCause
  | AwsAdminWorkerExecutionInventoryUnobservable
  | AwsAdminWorkerExecutionInventoryOverBound
  | AwsAdminWorkerExecutionInstallRequiresEmptyInventory
  | AwsAdminWorkerExecutionDeleteKeyFailed
  | AwsAdminWorkerExecutionCreateKeyFailed
  | AwsAdminWorkerExecutionCreatedKeyNotReadBack
  | AwsAdminWorkerExecutionVisibilityWaitFailed
  | AwsAdminWorkerExecutionStableAbsenceNotProven
  | AwsAdminWorkerExecutionRecoveryRemintAmbiguous !AwsAdminRecoveryRemintCause
  | AwsAdminWorkerExecutionMaterialInvalid
  | AwsAdminWorkerExecutionTargetDeliveryFailed !AwsAdminTargetDeliveryCause
  | AwsAdminWorkerExecutionTargetObservationUnobservable !AwsAdminTargetObservationCause
  | AwsAdminWorkerExecutionTargetReceiptMismatch
  | AwsAdminWorkerExecutionTargetRevocationFailed
  | AwsAdminWorkerExecutionTargetRevocationUnobservable
  | AwsAdminWorkerExecutionTargetGenerationStillPresent
  | AwsAdminWorkerExecutionRevocationNotReadBack
  | AwsAdminWorkerExecutionIdentityDestroyFailed
  | AwsAdminWorkerExecutionIdentityAbsenceUnobservable
  | AwsAdminWorkerExecutionIdentityStillPresent
  | AwsAdminWorkerExecutionReceiptTooLarge
  | AwsAdminWorkerExecutionReceiptDecodeFailed
  | AwsAdminWorkerExecutionReceiptUnsupportedVersion
  | AwsAdminWorkerExecutionReceiptNonCanonical
  | AwsAdminWorkerExecutionReceiptInvalid
  deriving stock (Eq, Show)

allAwsAdminWorkerExecutionCauses :: [AwsAdminWorkerExecutionCause]
allAwsAdminWorkerExecutionCauses =
  [ AwsAdminWorkerExecutionUnclassified
  , AwsAdminWorkerExecutionPreparedTargetInvalid
  , AwsAdminWorkerExecutionPreparedTargetMismatch
  , AwsAdminWorkerExecutionPrepareTargetFailed
  , AwsAdminWorkerExecutionJournalUnavailable
  , AwsAdminWorkerExecutionJournalPermitMismatch
  , AwsAdminWorkerExecutionJournalTransitionRejected
  , AwsAdminWorkerExecutionJournalCommitFailed
  , AwsAdminWorkerExecutionJournalReadBackMismatch
  , AwsAdminWorkerExecutionTransitionLimitReached
  ]
    <> fmap AwsAdminWorkerExecutionIamPrerequisiteFailed allProductionIamErrorCauses
    <> [ AwsAdminWorkerExecutionInventoryUnobservable
       , AwsAdminWorkerExecutionInventoryOverBound
       , AwsAdminWorkerExecutionInstallRequiresEmptyInventory
       , AwsAdminWorkerExecutionDeleteKeyFailed
       , AwsAdminWorkerExecutionCreateKeyFailed
       , AwsAdminWorkerExecutionCreatedKeyNotReadBack
       , AwsAdminWorkerExecutionVisibilityWaitFailed
       , AwsAdminWorkerExecutionStableAbsenceNotProven
       ]
    <> fmap
      AwsAdminWorkerExecutionRecoveryRemintAmbiguous
      allAwsAdminRecoveryRemintCauses
    <> [AwsAdminWorkerExecutionMaterialInvalid]
    <> fmap
      AwsAdminWorkerExecutionTargetDeliveryFailed
      allAwsAdminTargetDeliveryCauses
    <> fmap
      AwsAdminWorkerExecutionTargetObservationUnobservable
      allAwsAdminTargetObservationCauses
    <> [ AwsAdminWorkerExecutionTargetReceiptMismatch
       , AwsAdminWorkerExecutionTargetRevocationFailed
       , AwsAdminWorkerExecutionTargetRevocationUnobservable
       , AwsAdminWorkerExecutionTargetGenerationStillPresent
       , AwsAdminWorkerExecutionRevocationNotReadBack
       , AwsAdminWorkerExecutionIdentityDestroyFailed
       , AwsAdminWorkerExecutionIdentityAbsenceUnobservable
       , AwsAdminWorkerExecutionIdentityStillPresent
       , AwsAdminWorkerExecutionReceiptTooLarge
       , AwsAdminWorkerExecutionReceiptDecodeFailed
       , AwsAdminWorkerExecutionReceiptUnsupportedVersion
       , AwsAdminWorkerExecutionReceiptNonCanonical
       , AwsAdminWorkerExecutionReceiptInvalid
       ]

data AwsAdminWorkerTerminalCause
  = AwsAdminWorkerTerminalDeliveryCompositionUnavailable
  | AwsAdminWorkerTerminalStdinReadFailed
  | AwsAdminWorkerTerminalStdinTooLarge
  | AwsAdminWorkerTerminalFrameRejected
  | AwsAdminWorkerTerminalPodIdentityReadFailed
  | AwsAdminWorkerTerminalPodIdentityInvalid
  | AwsAdminWorkerTerminalPodIdentityMismatch
  | AwsAdminWorkerTerminalPermitMetadataMismatch
  | AwsAdminWorkerTerminalModeMismatch
  | AwsAdminWorkerTerminalProjectedIdentityMismatch
  | AwsAdminWorkerTerminalClockUnavailable
  | AwsAdminWorkerTerminalVaultLoginUnavailable
  | AwsAdminWorkerTerminalAuthorityKeyUnavailable
  | AwsAdminWorkerTerminalPermitRejected
  | AwsAdminWorkerTerminalIamProgramInvalid
  | AwsAdminWorkerTerminalIamSessionUnavailable
  | AwsAdminWorkerTerminalExecutionFailed !AwsAdminWorkerExecutionCause
  | AwsAdminWorkerTerminalSessionRevocationFailed !AwsAdminWorkerSessionClosureCause
  | AwsAdminWorkerTerminalCompletionUnavailable
  | AwsAdminWorkerTerminalUnhandledException
  deriving stock (Eq, Show)

allAwsAdminWorkerTerminalCauses :: [AwsAdminWorkerTerminalCause]
allAwsAdminWorkerTerminalCauses =
  [ AwsAdminWorkerTerminalDeliveryCompositionUnavailable
  , AwsAdminWorkerTerminalStdinReadFailed
  , AwsAdminWorkerTerminalStdinTooLarge
  , AwsAdminWorkerTerminalFrameRejected
  , AwsAdminWorkerTerminalPodIdentityReadFailed
  , AwsAdminWorkerTerminalPodIdentityInvalid
  , AwsAdminWorkerTerminalPodIdentityMismatch
  , AwsAdminWorkerTerminalPermitMetadataMismatch
  , AwsAdminWorkerTerminalModeMismatch
  , AwsAdminWorkerTerminalProjectedIdentityMismatch
  , AwsAdminWorkerTerminalClockUnavailable
  , AwsAdminWorkerTerminalVaultLoginUnavailable
  , AwsAdminWorkerTerminalAuthorityKeyUnavailable
  , AwsAdminWorkerTerminalPermitRejected
  , AwsAdminWorkerTerminalIamProgramInvalid
  , AwsAdminWorkerTerminalIamSessionUnavailable
  ]
    <> fmap
      AwsAdminWorkerTerminalExecutionFailed
      allAwsAdminWorkerExecutionCauses
    <> fmap
      AwsAdminWorkerTerminalSessionRevocationFailed
      allAwsAdminWorkerSessionClosureCauses
    <> [ AwsAdminWorkerTerminalCompletionUnavailable
       , AwsAdminWorkerTerminalUnhandledException
       ]

-- | Value-free terminal location for a refused AWS-admin service-session
-- closure. Provider text, token/accessor values, and journal identifiers never
-- enter this vocabulary.
data AwsAdminWorkerSessionClosureCause
  = AwsAdminWorkerSessionClosureBindingAllocationFailed
  | AwsAdminWorkerSessionClosureAuditorLoginFailed
  | AwsAdminWorkerSessionClosureAuditorLeaseInsufficient
  | AwsAdminWorkerSessionClosureAuditorRoleCleanupFailed
  | AwsAdminWorkerSessionClosureJournalCommitFailed
  | AwsAdminWorkerSessionClosureAcquisitionJournalUnavailable
      !AwsAdminWorkerJournalUnavailableCause
  | AwsAdminWorkerSessionClosureFinalizationJournalUnavailable
      !AwsAdminWorkerJournalUnavailableCause
  | AwsAdminWorkerSessionClosureBindingRoleMismatch
  | AwsAdminWorkerSessionClosureRoleOccupied
  | AwsAdminWorkerSessionClosureBindingInvalid
  | AwsAdminWorkerSessionClosurePrecleanIdentityInvalid
  | AwsAdminWorkerSessionClosurePrecleanObservationFailed
  | AwsAdminWorkerSessionClosurePrecleanClassificationFailed
  | AwsAdminWorkerSessionClosurePrecleanVisibilityWaitFailed
  | AwsAdminWorkerSessionClosurePrecleanStableAbsenceFailed
  | AwsAdminWorkerSessionClosureLoginAmbiguityCleaned
  | AwsAdminWorkerSessionClosureCleanupIdentityInvalid
  | AwsAdminWorkerSessionClosureCleanupObservationFailed
  | AwsAdminWorkerSessionClosureCleanupClassificationFailed
  | AwsAdminWorkerSessionClosureCleanupVisibilityWaitFailed
  | AwsAdminWorkerSessionClosureCleanupStableAbsenceFailed
  | AwsAdminWorkerSessionClosureCleanupThrew
  | AwsAdminWorkerSessionClosureCleanupJournalCommitFailed
  | AwsAdminWorkerSessionClosureAbsenceUnproven
  deriving stock (Eq, Show)

data AwsAdminWorkerActionProgress
  = AwsAdminWorkerActionNotStarted
  | AwsAdminWorkerActionAttempted
  deriving stock (Eq, Show)

-- | Closed projection of the retained-journal error text. The Vault client
-- still retains bounded detail internally for control flow, but no response
-- body, URL, journal coordinate, or token-adjacent value can enter a worker
-- terminal.
data AwsAdminWorkerJournalUnavailableCause
  = AwsAdminWorkerJournalAuthenticationRejected
  | AwsAdminWorkerJournalAuthorizationRejected
  | AwsAdminWorkerJournalNotFound
  | AwsAdminWorkerJournalTimeout
  | AwsAdminWorkerJournalTransportFailed
  | AwsAdminWorkerJournalDecodeFailed
  | AwsAdminWorkerJournalInvalid
  | AwsAdminWorkerJournalOther
  deriving stock (Bounded, Enum, Eq, Show)

allAwsAdminWorkerJournalUnavailableCauses
  :: [AwsAdminWorkerJournalUnavailableCause]
allAwsAdminWorkerJournalUnavailableCauses = [minBound .. maxBound]

classifyAwsAdminWorkerJournalUnavailable
  :: AwsAdminWorkerActionProgress
  -> Text
  -> AwsAdminWorkerSessionClosureCause
classifyAwsAdminWorkerJournalUnavailable progress detail = case progress of
  AwsAdminWorkerActionNotStarted ->
    AwsAdminWorkerSessionClosureAcquisitionJournalUnavailable cause
  AwsAdminWorkerActionAttempted ->
    AwsAdminWorkerSessionClosureFinalizationJournalUnavailable cause
 where
  cause
    | "HTTP 403 response:" `Text.isPrefixOf` detail
        && "invalid token" `Text.isInfixOf` Text.toLower detail =
        AwsAdminWorkerJournalAuthenticationRejected
    | "HTTP 403 response:" `Text.isPrefixOf` detail =
        AwsAdminWorkerJournalAuthorizationRejected
    | "HTTP 404 response:" `Text.isPrefixOf` detail =
        AwsAdminWorkerJournalNotFound
    | "HTTP timeout:" `Text.isPrefixOf` detail =
        AwsAdminWorkerJournalTimeout
    | "HTTP connection failure:" `Text.isPrefixOf` detail =
        AwsAdminWorkerJournalTransportFailed
    | "HTTP response decode error:" `Text.isPrefixOf` detail =
        AwsAdminWorkerJournalDecodeFailed
    | any (`Text.isPrefixOf` detail) invalidPrefixes =
        AwsAdminWorkerJournalInvalid
    | otherwise = AwsAdminWorkerJournalOther
  invalidPrefixes =
    [ "service-session journal fields are invalid"
    , "service-session journal base64 is invalid"
    , "service-session journal role mismatch"
    ]

allAwsAdminWorkerSessionClosureCauses :: [AwsAdminWorkerSessionClosureCause]
allAwsAdminWorkerSessionClosureCauses =
  [ AwsAdminWorkerSessionClosureBindingAllocationFailed
  , AwsAdminWorkerSessionClosureAuditorLoginFailed
  , AwsAdminWorkerSessionClosureAuditorLeaseInsufficient
  , AwsAdminWorkerSessionClosureAuditorRoleCleanupFailed
  , AwsAdminWorkerSessionClosureJournalCommitFailed
  , AwsAdminWorkerSessionClosureBindingRoleMismatch
  , AwsAdminWorkerSessionClosureRoleOccupied
  , AwsAdminWorkerSessionClosureBindingInvalid
  , AwsAdminWorkerSessionClosurePrecleanIdentityInvalid
  , AwsAdminWorkerSessionClosurePrecleanObservationFailed
  , AwsAdminWorkerSessionClosurePrecleanClassificationFailed
  , AwsAdminWorkerSessionClosurePrecleanVisibilityWaitFailed
  , AwsAdminWorkerSessionClosurePrecleanStableAbsenceFailed
  , AwsAdminWorkerSessionClosureLoginAmbiguityCleaned
  , AwsAdminWorkerSessionClosureCleanupIdentityInvalid
  , AwsAdminWorkerSessionClosureCleanupObservationFailed
  , AwsAdminWorkerSessionClosureCleanupClassificationFailed
  , AwsAdminWorkerSessionClosureCleanupVisibilityWaitFailed
  , AwsAdminWorkerSessionClosureCleanupStableAbsenceFailed
  , AwsAdminWorkerSessionClosureCleanupThrew
  , AwsAdminWorkerSessionClosureCleanupJournalCommitFailed
  , AwsAdminWorkerSessionClosureAbsenceUnproven
  ]
    <> fmap
      AwsAdminWorkerSessionClosureAcquisitionJournalUnavailable
      allAwsAdminWorkerJournalUnavailableCauses
    <> fmap
      AwsAdminWorkerSessionClosureFinalizationJournalUnavailable
      allAwsAdminWorkerJournalUnavailableCauses

data AwsAdminWorkerTerminalLineDisposition
  = AwsAdminWorkerTerminalLineNone
  | AwsAdminWorkerTerminalLineUnique !AwsAdminWorkerTerminalCause
  | AwsAdminWorkerTerminalLineUnrecognized
  | AwsAdminWorkerTerminalLinesAmbiguous
  deriving stock (Eq, Show)

data AwsAdminWorkerReceiptTransportObservation
  = AwsAdminWorkerReceiptTransportObservation
  { internalAwsAdminWorkerReceiptCaptureSize
      :: !AwsAdminWorkerReceiptCaptureSize
  , internalAwsAdminWorkerReceiptRawDecodeCause
      :: !AwsAdminWorkerReceiptDecodeCause
  , internalAwsAdminWorkerReceiptRawEnvelopeDecodeCause
      :: !AwsAdminWorkerReceiptEnvelopeDecodeCause
  , internalAwsAdminWorkerReceiptTerminalEnding
      :: !AwsAdminWorkerReceiptTerminalEnding
  , internalAwsAdminWorkerReceiptWithoutTerminalEndingDecodeCause
      :: !(Maybe AwsAdminWorkerReceiptDecodeCause)
  , internalAwsAdminWorkerReceiptWithoutTerminalEndingEnvelopeDecodeCause
      :: !(Maybe AwsAdminWorkerReceiptEnvelopeDecodeCause)
  , internalAwsAdminWorkerReceiptLineTopology
      :: !AwsAdminWorkerReceiptLineTopology
  , internalAwsAdminWorkerReceiptEnvelopeLineDisposition
      :: !AwsAdminWorkerReceiptEnvelopeLineDisposition
  , internalAwsAdminWorkerReceiptPrefixLineDisposition
      :: !AwsAdminWorkerReceiptPrefixLineDisposition
  , internalAwsAdminWorkerTerminalLineDisposition
      :: !AwsAdminWorkerTerminalLineDisposition
  }
  deriving stock (Eq, Show)

classifyAwsAdminWorkerReceiptTransport
  :: ByteString -> AwsAdminWorkerReceiptTransportObservation
classifyAwsAdminWorkerReceiptTransport bytes =
  AwsAdminWorkerReceiptTransportObservation
    { internalAwsAdminWorkerReceiptCaptureSize = captureSize
    , internalAwsAdminWorkerReceiptRawDecodeCause = decodeCause bytes
    , internalAwsAdminWorkerReceiptRawEnvelopeDecodeCause = envelopeDecodeCause bytes
    , internalAwsAdminWorkerReceiptTerminalEnding = terminalEnding
    , internalAwsAdminWorkerReceiptWithoutTerminalEndingDecodeCause =
        decodeCause <$> withoutTerminalEnding
    , internalAwsAdminWorkerReceiptWithoutTerminalEndingEnvelopeDecodeCause =
        envelopeDecodeCause <$> withoutTerminalEnding
    , internalAwsAdminWorkerReceiptLineTopology = lineTopology
    , internalAwsAdminWorkerReceiptEnvelopeLineDisposition = envelopeLineDisposition
    , internalAwsAdminWorkerReceiptPrefixLineDisposition = prefixLineDisposition
    , internalAwsAdminWorkerTerminalLineDisposition = terminalLineDisposition
    }
 where
  captureSize
    | ByteString.null bytes = AwsAdminWorkerReceiptCaptureEmpty
    | ByteString.length bytes > awsAdminWorkerReceiptTextEnvelopeMaximumBytes =
        AwsAdminWorkerReceiptCaptureOversize
    | otherwise = AwsAdminWorkerReceiptCaptureWithinBound
  (terminalEnding, withoutTerminalEnding)
    | ByteString.isSuffixOf "\r\n" bytes =
        ( AwsAdminWorkerReceiptTerminalEndingCrlf
        , Just (ByteString.dropEnd 2 bytes)
        )
    | ByteString.isSuffixOf "\n" bytes =
        ( AwsAdminWorkerReceiptTerminalEndingLf
        , Just (ByteString.dropEnd 1 bytes)
        )
    | otherwise = (AwsAdminWorkerReceiptTerminalEndingAbsent, Nothing)
  linePayload = fromMaybe bytes withoutTerminalEnding
  linesInPayload
    | ByteString.null linePayload = []
    | otherwise = ByteString.split 10 linePayload
  lineTopology = case linesInPayload of
    [] -> AwsAdminWorkerReceiptLinesEmpty
    [_] -> AwsAdminWorkerReceiptLinesSingle
    _ -> AwsAdminWorkerReceiptLinesMultiple
  envelopeLineDisposition =
    case filter isCanonicalReceiptEnvelope linesInPayload of
      [] -> AwsAdminWorkerReceiptEnvelopeLinesNone
      [_] -> AwsAdminWorkerReceiptEnvelopeLineUnique
      _ -> AwsAdminWorkerReceiptEnvelopeLinesAmbiguous
  prefixLineDisposition =
    case filter (ByteString.isPrefixOf awsAdminWorkerReceiptTextEnvelopePrefix) linesInPayload of
      [] -> AwsAdminWorkerReceiptPrefixLinesNone
      [_] -> AwsAdminWorkerReceiptPrefixLineUnique
      _ -> AwsAdminWorkerReceiptPrefixLinesAmbiguous
  terminalLineDisposition =
    case filter (ByteString.isPrefixOf awsAdminWorkerTerminalLinePrefix) linesInPayload of
      [] -> AwsAdminWorkerTerminalLineNone
      [line] ->
        maybe
          AwsAdminWorkerTerminalLineUnrecognized
          AwsAdminWorkerTerminalLineUnique
          (decodeAwsAdminWorkerTerminalLine line)
      _ -> AwsAdminWorkerTerminalLinesAmbiguous

renderAwsAdminWorkerReceiptCaptureSize
  :: AwsAdminWorkerReceiptCaptureSize -> Text
renderAwsAdminWorkerReceiptCaptureSize captureSize = case captureSize of
  AwsAdminWorkerReceiptCaptureEmpty -> "empty"
  AwsAdminWorkerReceiptCaptureWithinBound -> "within-bound"
  AwsAdminWorkerReceiptCaptureOversize -> "oversize"

renderAwsAdminWorkerReceiptDecodeCause
  :: AwsAdminWorkerReceiptDecodeCause -> Text
renderAwsAdminWorkerReceiptDecodeCause cause = case cause of
  AwsAdminWorkerReceiptDecodeCanonical -> "canonical"
  AwsAdminWorkerReceiptDecodeTooLarge -> "too-large"
  AwsAdminWorkerReceiptDecodeMalformed -> "decode-failed"
  AwsAdminWorkerReceiptDecodeUnsupportedVersion -> "unsupported-version"
  AwsAdminWorkerReceiptDecodeNonCanonical -> "non-canonical"
  AwsAdminWorkerReceiptDecodeInvalid -> "invalid"

renderAwsAdminWorkerReceiptEnvelopeDecodeCause
  :: AwsAdminWorkerReceiptEnvelopeDecodeCause -> Text
renderAwsAdminWorkerReceiptEnvelopeDecodeCause cause = case cause of
  AwsAdminWorkerReceiptEnvelopeDecodeCanonical -> "canonical"
  AwsAdminWorkerReceiptEnvelopeDecodeTooLarge -> "too-large"
  AwsAdminWorkerReceiptEnvelopeDecodeInvalid -> "invalid"
  AwsAdminWorkerReceiptEnvelopeDecodeNonCanonical -> "non-canonical"

renderAwsAdminWorkerReceiptTerminalEnding
  :: AwsAdminWorkerReceiptTerminalEnding -> Text
renderAwsAdminWorkerReceiptTerminalEnding ending = case ending of
  AwsAdminWorkerReceiptTerminalEndingAbsent -> "absent"
  AwsAdminWorkerReceiptTerminalEndingLf -> "lf"
  AwsAdminWorkerReceiptTerminalEndingCrlf -> "crlf"

renderAwsAdminWorkerReceiptLineTopology
  :: AwsAdminWorkerReceiptLineTopology -> Text
renderAwsAdminWorkerReceiptLineTopology topology = case topology of
  AwsAdminWorkerReceiptLinesEmpty -> "empty"
  AwsAdminWorkerReceiptLinesSingle -> "single"
  AwsAdminWorkerReceiptLinesMultiple -> "multiple"

renderAwsAdminWorkerReceiptEnvelopeLineDisposition
  :: AwsAdminWorkerReceiptEnvelopeLineDisposition -> Text
renderAwsAdminWorkerReceiptEnvelopeLineDisposition disposition = case disposition of
  AwsAdminWorkerReceiptEnvelopeLinesNone -> "none"
  AwsAdminWorkerReceiptEnvelopeLineUnique -> "unique"
  AwsAdminWorkerReceiptEnvelopeLinesAmbiguous -> "ambiguous"

renderAwsAdminWorkerReceiptPrefixLineDisposition
  :: AwsAdminWorkerReceiptPrefixLineDisposition -> Text
renderAwsAdminWorkerReceiptPrefixLineDisposition disposition = case disposition of
  AwsAdminWorkerReceiptPrefixLinesNone -> "none"
  AwsAdminWorkerReceiptPrefixLineUnique -> "unique"
  AwsAdminWorkerReceiptPrefixLinesAmbiguous -> "ambiguous"

renderAwsAdminWorkerExecutionCause :: AwsAdminWorkerExecutionCause -> Text
renderAwsAdminWorkerExecutionCause cause = case cause of
  AwsAdminWorkerExecutionUnclassified -> "unclassified"
  AwsAdminWorkerExecutionPreparedTargetInvalid -> "prepared-target-invalid"
  AwsAdminWorkerExecutionPreparedTargetMismatch -> "prepared-target-mismatch"
  AwsAdminWorkerExecutionPrepareTargetFailed -> "prepare-target-failed"
  AwsAdminWorkerExecutionJournalUnavailable -> "journal-unavailable"
  AwsAdminWorkerExecutionJournalPermitMismatch -> "journal-permit-mismatch"
  AwsAdminWorkerExecutionJournalTransitionRejected -> "journal-transition-rejected"
  AwsAdminWorkerExecutionJournalCommitFailed -> "journal-commit-failed"
  AwsAdminWorkerExecutionJournalReadBackMismatch -> "journal-read-back-mismatch"
  AwsAdminWorkerExecutionTransitionLimitReached -> "transition-limit-reached"
  AwsAdminWorkerExecutionIamPrerequisiteFailed prerequisiteCause ->
    "iam-prerequisite-failed/"
      <> renderProductionIamErrorCause prerequisiteCause
  AwsAdminWorkerExecutionInventoryUnobservable -> "inventory-unobservable"
  AwsAdminWorkerExecutionInventoryOverBound -> "inventory-over-bound"
  AwsAdminWorkerExecutionInstallRequiresEmptyInventory -> "install-requires-empty-inventory"
  AwsAdminWorkerExecutionDeleteKeyFailed -> "delete-key-failed"
  AwsAdminWorkerExecutionCreateKeyFailed -> "create-key-failed"
  AwsAdminWorkerExecutionCreatedKeyNotReadBack -> "created-key-not-read-back"
  AwsAdminWorkerExecutionVisibilityWaitFailed -> "visibility-wait-failed"
  AwsAdminWorkerExecutionStableAbsenceNotProven -> "stable-absence-not-proven"
  AwsAdminWorkerExecutionRecoveryRemintAmbiguous remintCause ->
    "recovery-remint-ambiguous/" <> renderAwsAdminRecoveryRemintCause remintCause
  AwsAdminWorkerExecutionMaterialInvalid -> "material-invalid"
  AwsAdminWorkerExecutionTargetDeliveryFailed deliveryCause ->
    "target-delivery-failed/" <> renderAwsAdminTargetDeliveryCause deliveryCause
  AwsAdminWorkerExecutionTargetObservationUnobservable observationCause ->
    "target-observation-unobservable/"
      <> renderAwsAdminTargetObservationCause observationCause
  AwsAdminWorkerExecutionTargetReceiptMismatch -> "target-receipt-mismatch"
  AwsAdminWorkerExecutionTargetRevocationFailed -> "target-revocation-failed"
  AwsAdminWorkerExecutionTargetRevocationUnobservable -> "target-revocation-unobservable"
  AwsAdminWorkerExecutionTargetGenerationStillPresent -> "target-generation-still-present"
  AwsAdminWorkerExecutionRevocationNotReadBack -> "revocation-not-read-back"
  AwsAdminWorkerExecutionIdentityDestroyFailed -> "identity-destroy-failed"
  AwsAdminWorkerExecutionIdentityAbsenceUnobservable -> "identity-absence-unobservable"
  AwsAdminWorkerExecutionIdentityStillPresent -> "identity-still-present"
  AwsAdminWorkerExecutionReceiptTooLarge -> "receipt-too-large"
  AwsAdminWorkerExecutionReceiptDecodeFailed -> "receipt-decode-failed"
  AwsAdminWorkerExecutionReceiptUnsupportedVersion -> "receipt-unsupported-version"
  AwsAdminWorkerExecutionReceiptNonCanonical -> "receipt-non-canonical"
  AwsAdminWorkerExecutionReceiptInvalid -> "receipt-invalid"

renderAwsAdminWorkerTerminalCause :: AwsAdminWorkerTerminalCause -> Text
renderAwsAdminWorkerTerminalCause cause = case cause of
  AwsAdminWorkerTerminalDeliveryCompositionUnavailable -> "delivery-composition-unavailable"
  AwsAdminWorkerTerminalStdinReadFailed -> "stdin-read-failed"
  AwsAdminWorkerTerminalStdinTooLarge -> "stdin-too-large"
  AwsAdminWorkerTerminalFrameRejected -> "frame-rejected"
  AwsAdminWorkerTerminalPodIdentityReadFailed -> "pod-identity-read-failed"
  AwsAdminWorkerTerminalPodIdentityInvalid -> "pod-identity-invalid"
  AwsAdminWorkerTerminalPodIdentityMismatch -> "pod-identity-mismatch"
  AwsAdminWorkerTerminalPermitMetadataMismatch -> "permit-metadata-mismatch"
  AwsAdminWorkerTerminalModeMismatch -> "mode-mismatch"
  AwsAdminWorkerTerminalProjectedIdentityMismatch -> "projected-identity-mismatch"
  AwsAdminWorkerTerminalClockUnavailable -> "clock-unavailable"
  AwsAdminWorkerTerminalVaultLoginUnavailable -> "vault-login-unavailable"
  AwsAdminWorkerTerminalAuthorityKeyUnavailable -> "authority-key-unavailable"
  AwsAdminWorkerTerminalPermitRejected -> "permit-rejected"
  AwsAdminWorkerTerminalIamProgramInvalid -> "iam-program-invalid"
  AwsAdminWorkerTerminalIamSessionUnavailable -> "iam-session-unavailable"
  AwsAdminWorkerTerminalExecutionFailed executionCause ->
    "execution-failed/" <> renderAwsAdminWorkerExecutionCause executionCause
  AwsAdminWorkerTerminalSessionRevocationFailed sessionCause ->
    "session-revocation-failed/" <> renderAwsAdminWorkerSessionClosureCause sessionCause
  AwsAdminWorkerTerminalCompletionUnavailable -> "completion-unavailable"
  AwsAdminWorkerTerminalUnhandledException -> "unhandled-exception"

renderAwsAdminWorkerSessionClosureCause :: AwsAdminWorkerSessionClosureCause -> Text
renderAwsAdminWorkerSessionClosureCause cause = case cause of
  AwsAdminWorkerSessionClosureBindingAllocationFailed -> "binding-allocation-failed"
  AwsAdminWorkerSessionClosureAuditorLoginFailed -> "auditor-login-failed"
  AwsAdminWorkerSessionClosureAuditorLeaseInsufficient -> "auditor-lease-insufficient"
  AwsAdminWorkerSessionClosureAuditorRoleCleanupFailed -> "auditor-role-cleanup-failed"
  AwsAdminWorkerSessionClosureJournalCommitFailed -> "journal-commit-failed"
  AwsAdminWorkerSessionClosureAcquisitionJournalUnavailable journalCause ->
    "acquisition/journal-unavailable/"
      <> renderAwsAdminWorkerJournalUnavailableCause journalCause
  AwsAdminWorkerSessionClosureFinalizationJournalUnavailable journalCause ->
    "finalization/journal-unavailable/"
      <> renderAwsAdminWorkerJournalUnavailableCause journalCause
  AwsAdminWorkerSessionClosureBindingRoleMismatch -> "binding-role-mismatch"
  AwsAdminWorkerSessionClosureRoleOccupied -> "role-occupied"
  AwsAdminWorkerSessionClosureBindingInvalid -> "binding-invalid"
  AwsAdminWorkerSessionClosurePrecleanIdentityInvalid -> "preclean/identity-invalid"
  AwsAdminWorkerSessionClosurePrecleanObservationFailed -> "preclean/observation-failed"
  AwsAdminWorkerSessionClosurePrecleanClassificationFailed -> "preclean/classification-failed"
  AwsAdminWorkerSessionClosurePrecleanVisibilityWaitFailed -> "preclean/visibility-wait-failed"
  AwsAdminWorkerSessionClosurePrecleanStableAbsenceFailed -> "preclean/stable-absence-failed"
  AwsAdminWorkerSessionClosureLoginAmbiguityCleaned -> "login-ambiguity-cleaned"
  AwsAdminWorkerSessionClosureCleanupIdentityInvalid -> "cleanup/identity-invalid"
  AwsAdminWorkerSessionClosureCleanupObservationFailed -> "cleanup/observation-failed"
  AwsAdminWorkerSessionClosureCleanupClassificationFailed -> "cleanup/classification-failed"
  AwsAdminWorkerSessionClosureCleanupVisibilityWaitFailed -> "cleanup/visibility-wait-failed"
  AwsAdminWorkerSessionClosureCleanupStableAbsenceFailed -> "cleanup/stable-absence-failed"
  AwsAdminWorkerSessionClosureCleanupThrew -> "cleanup/threw"
  AwsAdminWorkerSessionClosureCleanupJournalCommitFailed -> "cleanup/journal-commit-failed"
  AwsAdminWorkerSessionClosureAbsenceUnproven -> "absence-unproven"

renderAwsAdminWorkerJournalUnavailableCause
  :: AwsAdminWorkerJournalUnavailableCause -> Text
renderAwsAdminWorkerJournalUnavailableCause cause = case cause of
  AwsAdminWorkerJournalAuthenticationRejected -> "authentication-rejected"
  AwsAdminWorkerJournalAuthorizationRejected -> "authorization-rejected"
  AwsAdminWorkerJournalNotFound -> "not-found"
  AwsAdminWorkerJournalTimeout -> "timeout"
  AwsAdminWorkerJournalTransportFailed -> "transport-failed"
  AwsAdminWorkerJournalDecodeFailed -> "decode-failed"
  AwsAdminWorkerJournalInvalid -> "invalid"
  AwsAdminWorkerJournalOther -> "other"

renderAwsAdminWorkerTerminalLineDisposition
  :: AwsAdminWorkerTerminalLineDisposition -> Text
renderAwsAdminWorkerTerminalLineDisposition disposition = case disposition of
  AwsAdminWorkerTerminalLineNone -> "none"
  AwsAdminWorkerTerminalLineUnique cause -> renderAwsAdminWorkerTerminalCause cause
  AwsAdminWorkerTerminalLineUnrecognized -> "unrecognized"
  AwsAdminWorkerTerminalLinesAmbiguous -> "ambiguous"

renderAwsAdminWorkerReceiptTransportObservation
  :: AwsAdminWorkerReceiptTransportObservation -> Text
renderAwsAdminWorkerReceiptTransportObservation observation =
  Text.intercalate
    "/"
    [ "size="
        <> renderAwsAdminWorkerReceiptCaptureSize
          (internalAwsAdminWorkerReceiptCaptureSize observation)
    , "raw="
        <> renderAwsAdminWorkerReceiptDecodeCause
          (internalAwsAdminWorkerReceiptRawDecodeCause observation)
    , "raw-envelope="
        <> renderAwsAdminWorkerReceiptEnvelopeDecodeCause
          (internalAwsAdminWorkerReceiptRawEnvelopeDecodeCause observation)
    , "terminal-ending="
        <> renderAwsAdminWorkerReceiptTerminalEnding
          (internalAwsAdminWorkerReceiptTerminalEnding observation)
    , "without-terminal-ending="
        <> maybe
          "not-applicable"
          renderAwsAdminWorkerReceiptDecodeCause
          (internalAwsAdminWorkerReceiptWithoutTerminalEndingDecodeCause observation)
    , "without-terminal-ending-envelope="
        <> maybe
          "not-applicable"
          renderAwsAdminWorkerReceiptEnvelopeDecodeCause
          (internalAwsAdminWorkerReceiptWithoutTerminalEndingEnvelopeDecodeCause observation)
    , "line-topology="
        <> renderAwsAdminWorkerReceiptLineTopology
          (internalAwsAdminWorkerReceiptLineTopology observation)
    , "receipt-envelope-lines="
        <> renderAwsAdminWorkerReceiptEnvelopeLineDisposition
          (internalAwsAdminWorkerReceiptEnvelopeLineDisposition observation)
    , "receipt-prefix-lines="
        <> renderAwsAdminWorkerReceiptPrefixLineDisposition
          (internalAwsAdminWorkerReceiptPrefixLineDisposition observation)
    , "worker-terminal-line="
        <> renderAwsAdminWorkerTerminalLineDisposition
          (internalAwsAdminWorkerTerminalLineDisposition observation)
    ]

awsAdminWorkerTerminalLinePrefix :: ByteString
awsAdminWorkerTerminalLinePrefix = "AWS-admin credential worker refused: "

decodeAwsAdminWorkerTerminalLine :: ByteString -> Maybe AwsAdminWorkerTerminalCause
decodeAwsAdminWorkerTerminalLine line = do
  renderedCause <- ByteString.stripPrefix awsAdminWorkerTerminalLinePrefix line
  case [ cause
       | cause <- allAwsAdminWorkerTerminalCauses
       , TextEncoding.encodeUtf8 (renderAwsAdminWorkerTerminalCause cause) == renderedCause
       ] of
    [cause] -> Just cause
    _ -> Nothing

decodeCause :: ByteString -> AwsAdminWorkerReceiptDecodeCause
decodeCause bytes = case decodeAwsAdminWorkerReceipt bytes of
  Right _ -> AwsAdminWorkerReceiptDecodeCanonical
  Left (AwsAdminWorkerReceiptTooLarge _ _) -> AwsAdminWorkerReceiptDecodeTooLarge
  Left AwsAdminWorkerReceiptDecodeFailed -> AwsAdminWorkerReceiptDecodeMalformed
  Left (AwsAdminWorkerReceiptUnsupportedVersion _) ->
    AwsAdminWorkerReceiptDecodeUnsupportedVersion
  Left AwsAdminWorkerReceiptNonCanonical -> AwsAdminWorkerReceiptDecodeNonCanonical
  -- The receipt decoder's wire-to-domain validation can reuse more specific
  -- execution errors.  At this diagnostic boundary they are all the same
  -- value-free semantic-invalid disposition.
  Left _ -> AwsAdminWorkerReceiptDecodeInvalid

envelopeDecodeCause :: ByteString -> AwsAdminWorkerReceiptEnvelopeDecodeCause
envelopeDecodeCause bytes =
  case decodeAwsAdminWorkerReceiptTextEnvelope bytes of
    Right _ -> AwsAdminWorkerReceiptEnvelopeDecodeCanonical
    Left cause -> cause

isCanonicalReceiptEnvelope :: ByteString -> Bool
isCanonicalReceiptEnvelope line =
  case decodeAwsAdminWorkerReceiptTextEnvelope line of
    Left _ -> False
    Right receiptBytes -> case decodeAwsAdminWorkerReceipt receiptBytes of
      Left _ -> False
      Right _ -> True

executeAwsAdminPermit
  :: (Monad m)
  => AwsAdminExecutionJournalBoundary m
  -> AwsAdminIamBoundary m
  -> AwsAdminDeliveryBoundary m
  -> SignedAwsAdminPermit
  -> m (Either AwsAdminExecutionError AwsAdminWorkerReceipt)
executeAwsAdminPermit journalBoundary iam delivery permit = do
  observed <- internalReadExecutionJournal journalBoundary
  case observed of
    Left detail -> pure (Left (AwsAdminExecutionJournalUnavailable detail))
    Right journal
      | awsAdminExecutionJournalPermit journal /= permit ->
          pure (Left AwsAdminExecutionJournalPermitMismatch)
      | otherwise -> driveExecution (32 :: Int) journal
 where
  intent = signedAwsAdminPermitIntent permit
  prepared = awsAdminPermitIntentPreparedTarget intent
  expectedTarget = targetForClass (awsAdminPermitIntentCredentialClass intent)

  driveExecution remaining journal
    | remaining <= 0 = pure (Left AwsAdminExecutionTransitionLimitReached)
    | otherwise = case validatePreparedTarget permit expectedTarget prepared of
        Left err -> pure (Left err)
        Right () -> case awsAdminExecutionJournalPhase journal of
          AwsAdminExecutionComplete receiptBytes ->
            pure $ do
              receipt <- decodeAwsAdminWorkerReceipt receiptBytes
              validateWorkerReceiptForPermit permit prepared receipt
              Right receipt
          AwsAdminExecutionIntentCommitted recoveryUsed ->
            case awsAdminPermitIntentAction intent of
              RevokeOperatorMaterial -> do
                result <- revokeIdentity iam delivery permit prepared
                case result of
                  Left err -> pure (Left err)
                  Right receipt -> completeJournal remaining journal receipt
              action -> do
                prerequisites <- internalEnsureIamPrerequisites iam
                case prerequisites of
                  Left detail -> pure (Left (AwsAdminIamPrerequisiteFailed detail))
                  Right () -> do
                    inventory <- observeKeys iam
                    case inventory of
                      Left err -> pure (Left err)
                      Right keys -> case action of
                        InstallOperatorMaterial
                          | null keys -> prepareAttempt remaining journal [] recoveryUsed
                          | recoveryUsed ->
                              requireCleanup
                                remaining
                                journal
                                recoveryUsed
                                AwsAdminRecoveryRemintIntentInventoryNotEmpty
                          | otherwise -> pure (Left AwsAdminInstallRequiresEmptyInventory)
                        RotateOperatorMaterial
                          | recoveryUsed && null keys ->
                              prepareAttempt remaining journal [] recoveryUsed
                          | not recoveryUsed && length keys <= 1 ->
                              prepareAttempt remaining journal keys recoveryUsed
                          | otherwise ->
                              requireCleanup
                                remaining
                                journal
                                recoveryUsed
                                AwsAdminRecoveryRemintIntentInventoryNotEmpty
          AwsAdminExecutionCreateAttemptPrepared predecessors recoveryUsed ->
            resumePreparedAttempt remaining journal predecessors recoveryUsed
          AwsAdminExecutionKeyCreated keyId predecessors recoveryUsed ->
            resolveCreatedKey remaining journal keyId predecessors recoveryUsed Nothing
          AwsAdminExecutionTargetCommitted keyId predecessors targetReceipt _ ->
            finishCommittedTarget remaining journal keyId predecessors targetReceipt
          AwsAdminExecutionCleanupRequired recoveryUsed -> do
            cleaned <- cleanAndProveStableAbsence iam cleanupRoundMaximum
            case cleaned of
              Left err -> pure (Left err)
              Right () -> do
                next <- commitJournalEvent journal (CommitAwsAdminStableCleanup recoveryUsed)
                either (pure . Left) (driveExecution (remaining - 1)) next
          AwsAdminExecutionCleanupProven recoveryUsed
            | recoveryUsed ->
                pure (Left (AwsAdminRecoveryRemintAmbiguous AwsAdminRecoveryRemintJournalResumed))
            | otherwise -> do
                next <- commitJournalEvent journal RestartAwsAdminAfterCleanup
                either (pure . Left) (driveExecution (remaining - 1)) next

  prepareAttempt remaining journal predecessors recoveryUsed = do
    next <-
      commitJournalEvent
        journal
        (CommitAwsAdminCreateAttempt predecessors recoveryUsed)
    either (pure . Left) (driveExecution (remaining - 1)) next

  resumePreparedAttempt remaining journal predecessors recoveryUsed = do
    first <- observeKeys iam
    case first of
      Left err -> pure (Left err)
      Right keys
        | keys == sort predecessors -> do
            waited <- internalWaitIamVisibilityGrace iam
            case waited of
              Left detail -> pure (Left (AwsAdminVisibilityWaitFailed detail))
              Right () -> do
                stable <- observeKeys iam
                case stable of
                  Left err -> pure (Left err)
                  Right confirmed
                    | confirmed == sort predecessors ->
                        createForPreparedAttempt remaining journal predecessors recoveryUsed
                    | otherwise ->
                        classifyPreparedInventory remaining journal predecessors recoveryUsed confirmed
        | otherwise ->
            classifyPreparedInventory remaining journal predecessors recoveryUsed keys

  classifyPreparedInventory remaining journal predecessors recoveryUsed keys =
    case [key | key <- keys, key `notElem` predecessors] of
      [created]
        | all (`elem` keys) predecessors
            && length keys == length predecessors + 1 -> do
            next <-
              commitJournalEvent
                journal
                (CommitAwsAdminCreatedKey created predecessors recoveryUsed)
            either (pure . Left) (driveExecution (remaining - 1)) next
      _ ->
        requireCleanup
          remaining
          journal
          recoveryUsed
          AwsAdminRecoveryRemintPreparedInventoryDiverged

  createForPreparedAttempt remaining journal predecessors recoveryUsed = do
    created <- internalCreateIamKey iam
    case created of
      AwsAccessKeyCreateFailed detail -> pure (Left (AwsAdminCreateKeyFailed detail))
      AwsAccessKeyCreateResponseLost ambiguity ->
        requireCleanup
          remaining
          journal
          recoveryUsed
          (recoveryRemintCauseForCreateAmbiguity ambiguity)
      AwsAccessKeyCreated keyId material
        | keyId `elem` predecessors ->
            requireCleanup
              remaining
              journal
              recoveryUsed
              AwsAdminRecoveryRemintCreatedKeyPredecessorCollision
        | otherwise -> do
            next <-
              commitJournalEvent
                journal
                (CommitAwsAdminCreatedKey keyId predecessors recoveryUsed)
            case next of
              Left err -> pure (Left err)
              Right createdJournal ->
                resolveCreatedKey
                  (remaining - 1)
                  createdJournal
                  keyId
                  predecessors
                  recoveryUsed
                  (Just material)

  resolveCreatedKey remaining journal keyId predecessors recoveryUsed maybeMaterial = do
    observedTarget <- internalObserveCredentialTarget delivery prepared permit
    case observedTarget of
      Left cause -> pure (Left (AwsAdminTargetObservationUnobservable cause))
      Right (Just targetReceipt) -> commitObservedTarget targetReceipt
      Right Nothing -> case maybeMaterial of
        Nothing ->
          requireCleanup
            remaining
            journal
            recoveryUsed
            AwsAdminRecoveryRemintCreatedMaterialUnavailable
        Just material -> case materialForPermit permit material of
          Left _ ->
            requireCleanup
              remaining
              journal
              recoveryUsed
              AwsAdminRecoveryRemintMaterialInvalid
          Right targetMaterial -> do
            delivered <-
              internalDeliverCredentialTarget delivery prepared permit targetMaterial
            case delivered of
              Right targetReceipt -> commitObservedTarget targetReceipt
              Left deliveryCause -> do
                readBack <- internalObserveCredentialTarget delivery prepared permit
                case readBack of
                  Left cause ->
                    pure (Left (AwsAdminTargetObservationUnobservable cause))
                  Right (Just targetReceipt) -> commitObservedTarget targetReceipt
                  Right Nothing ->
                    requireCleanup
                      remaining
                      journal
                      recoveryUsed
                      (AwsAdminRecoveryRemintTargetDeliveryFailed deliveryCause)
   where
    commitObservedTarget targetReceipt = case validateTargetReceipt permit prepared targetReceipt of
      Left _ ->
        requireCleanup
          remaining
          journal
          recoveryUsed
          AwsAdminRecoveryRemintTargetReceiptMismatch
      Right () -> do
        next <-
          commitJournalEvent
            journal
            ( CommitAwsAdminTargetReceipt
                keyId
                predecessors
                targetReceipt
                recoveryUsed
            )
        either (pure . Left) (driveExecution (remaining - 1)) next

  finishCommittedTarget remaining journal keyId predecessors targetReceipt = do
    deleted <- deletePredecessors keyId predecessors
    case deleted of
      Left err -> pure (Left err)
      Right () -> do
        observed <- observeExpectedKeys iam [keyId]
        case observed of
          Left err -> pure (Left err)
          Right () ->
            completeJournal remaining journal (installedReceipt permit prepared targetReceipt)

  deletePredecessors keyId =
    foldM
      (deletePredecessor keyId)
      (Right ())
  deletePredecessor keyId result predecessor = case result of
    Left err -> pure (Left err)
    Right ()
      | predecessor == keyId -> pure (Right ())
      | otherwise -> do
          deleted <- internalDeleteIamKey iam predecessor
          pure (either (Left . AwsAdminDeleteKeyFailed) Right deleted)

  requireCleanup remaining journal recoveryUsed cause = do
    next <-
      commitJournalEvent journal (RequireAwsAdminStableCleanup recoveryUsed)
    case next of
      Left err -> pure (Left err)
      Right cleanupJournal -> do
        result <- driveExecution (remaining - 1) cleanupJournal
        pure $ case result of
          Left (AwsAdminRecoveryRemintAmbiguous AwsAdminRecoveryRemintJournalResumed) ->
            Left (AwsAdminRecoveryRemintAmbiguous cause)
          _ -> result

  completeJournal remaining journal receipt = do
    next <-
      commitJournalEvent
        journal
        (CompleteAwsAdminExecution (encodeAwsAdminWorkerReceipt receipt))
    either (pure . Left) (driveExecution (remaining - 1)) next

  commitJournalEvent journal event = case stepAwsAdminExecutionJournal event journal of
    Left err -> pure (Left (AwsAdminExecutionJournalTransitionRejected (Text.pack (show err))))
    Right expected -> do
      committed <-
        internalCommitExecutionJournal journalBoundary journal expected
      pure $ case committed of
        Left detail -> Left (AwsAdminExecutionJournalCommitFailed detail)
        Right readBack
          | readBack == expected -> Right readBack
          | otherwise -> Left AwsAdminExecutionJournalReadBackMismatch

-- | Revoke one credential identity, reading __both__ absences back.
--
-- Sprint 4.85 (2026-08-18): the revoke response used to be the only evidence
-- that the target generation was gone.  @internalRevokeCredentialTarget@
-- returns the worker's own claim about work it just performed, and a claim is
-- not a read-back — which is what
-- @CanonicalTargetRevocationReadBackUnavailable@ named.  The target is now
-- re-observed through the same boundary the delivery path already uses to
-- distinguish present from absent, and a still-present generation is a
-- refusal rather than a successful revocation.
--
-- The two absences are then bound by 'mkOperatorMaterialRevocationReadBack',
-- the smart constructor the pure provisioner algebra already uses, so
-- \"revocation read-back\" has one definition across both paths instead of one
-- per path.  It refuses unless the external identity and the target generation
-- are __both__ independently observed absent, so neither half can stand in for
-- the other.
--
-- Ordering is deliberate: the target generation is revoked and read back
-- before the IAM identity is destroyed.  A run that fails in between leaves an
-- identity with no usable material rather than material with no identity to
-- revoke it under.
revokeIdentity
  :: (Monad m)
  => AwsAdminIamBoundary m
  -> AwsAdminDeliveryBoundary m
  -> SignedAwsAdminPermit
  -> PreparedCredentialTargetObservation
  -> m (Either AwsAdminExecutionError AwsAdminWorkerReceipt)
revokeIdentity iam delivery permit prepared = do
  targetResult <- internalRevokeCredentialTarget delivery prepared permit
  case targetResult of
    Left detail -> pure (Left (AwsAdminTargetRevocationFailed detail))
    Right evidence -> do
      observedTarget <- internalObserveCredentialTarget delivery prepared permit
      case observedTarget of
        Left cause ->
          pure
            ( decide
                evidence
                RevokedTargetUnobservable
                RevokedIdentityNotReached
                (Just (renderAwsAdminTargetObservationCause cause))
            )
        Right (Just _) ->
          pure
            ( decide
                evidence
                RevokedTargetStillPresent
                RevokedIdentityNotReached
                Nothing
            )
        Right Nothing -> do
          destroyed <- internalDestroyIamIdentity iam
          case destroyed of
            Left detail -> pure (Left (AwsAdminIdentityDestroyFailed detail))
            Right () -> do
              absent <- internalObserveIamIdentityAbsent iam
              pure $ case absent of
                Left detail ->
                  decide
                    evidence
                    RevokedTargetAbsent
                    RevokedIdentityUnobservable
                    (Just detail)
                Right False ->
                  decide
                    evidence
                    RevokedTargetAbsent
                    RevokedIdentityStillPresent
                    Nothing
                Right True ->
                  decide evidence RevokedTargetAbsent RevokedIdentityAbsent Nothing
 where
  -- Both outcomes come from the canonical decision rather than from local
  -- guards, so this path and the pure provisioner algebra cannot drift apart
  -- about what a revocation read-back is.
  decide evidence targetObservation identityObservation detail =
    case decideCredentialRevocationReadBack
      (awsCredentialDescriptorTarget (awsCredentialDescriptor credentialClass))
      (preparedCredentialTargetGeneration prepared)
      targetObservation
      identityObservation of
      Left refusal -> Left (revocationRefusalError refusal detail)
      Right _ ->
        Right
          AwsAdminWorkerReceipt
            { internalAwsAdminWorkerReceiptKind = AwsAdminRevoked
            , internalAwsAdminWorkerReceiptPermitId = permitIdText permit
            , internalAwsAdminWorkerReceiptRequestDigest = permitRequestDigest permit
            , internalAwsAdminWorkerReceiptTarget = preparedCredentialTargetId prepared
            , internalAwsAdminWorkerReceiptGeneration =
                preparedCredentialTargetGeneration prepared
            , internalAwsAdminWorkerReceiptTargetReadBack =
                LazyByteString.toStrict (serialise evidence)
            }

  credentialClass =
    awsAdminPermitIntentCredentialClass (signedAwsAdminPermitIntent permit)

-- | Total over the canonical refusals.  The optional detail is the boundary
-- text for the two unobservable arms; the others carry no boundary message
-- because nothing failed to answer.
revocationRefusalError
  :: CredentialRevocationRefusal -> Maybe Text -> AwsAdminExecutionError
revocationRefusalError refusal detail = case refusal of
  RevocationTargetUnobservable ->
    AwsAdminTargetRevocationUnobservable (fromMaybe "" detail)
  RevocationTargetStillPresent -> AwsAdminTargetGenerationStillPresent
  RevocationIdentityNotReached -> AwsAdminTargetGenerationStillPresent
  RevocationIdentityUnobservable ->
    AwsAdminIdentityAbsenceUnobservable (fromMaybe "" detail)
  RevocationIdentityStillPresent -> AwsAdminIdentityStillPresent
  RevocationNotBound -> AwsAdminRevocationNotReadBack

materialForPermit
  :: SignedAwsAdminPermit
  -> CreatedAwsAccessKey
  -> Either
       TargetMaterialValueError
       (ProvisionedTargetMaterial 'AwsAdminProvisioningIngress)
materialForPermit permit created = case credentialClass of
  SesSmtpRetainedCustodyCredential -> deriveSesSmtpSource region generation created
  _ -> mkAwsCredentialMaterial credentialClass region generation created
 where
  intent = signedAwsAdminPermitIntent permit
  credentialClass = awsAdminPermitIntentCredentialClass intent
  generation = awsAdminPermitIntentGeneration intent
  region = credentialIamParametersRegion (awsAdminPermitIntentIamParameters intent)

validatePreparedTarget
  :: SignedAwsAdminPermit
  -> TargetSecretId
  -> PreparedCredentialTargetObservation
  -> Either AwsAdminExecutionError ()
validatePreparedTarget permit expectedTarget prepared = do
  unless
    ( prepared == awsAdminPermitIntentPreparedTarget intent
        && preparedCredentialTargetId prepared == expectedTarget
        && preparedCredentialTargetGeneration prepared
          == awsAdminPermitIntentGeneration intent
        && preparedCredentialTargetRequestDigest prepared
          == awsAdminPermitIntentRequestDigest intent
        && preparedCredentialTargetPlanBinding prepared
          == awsAdminPermitIntentPlanBinding intent
        && authorityTimeMicros (preparedCredentialTargetDeadline prepared)
          == authorityTimeMicros (awsAdminPermitIntentDeadline intent)
        && preparedCredentialTargetFence prepared > 0
    )
    (Left AwsAdminPreparedTargetMismatch)
 where
  intent = signedAwsAdminPermitIntent permit

validateTargetReceipt
  :: SignedAwsAdminPermit
  -> PreparedCredentialTargetObservation
  -> TargetWorkerReceipt
  -> Either AwsAdminExecutionError ()
validateTargetReceipt _ prepared receipt =
  unless
    ( targetWorkerReceiptTarget receipt == preparedCredentialTargetId prepared
        && targetWorkerReceiptGeneration receipt
          == preparedCredentialTargetGeneration prepared
    )
    (Left AwsAdminTargetReceiptMismatch)

installedReceipt
  :: SignedAwsAdminPermit
  -> PreparedCredentialTargetObservation
  -> TargetWorkerReceipt
  -> AwsAdminWorkerReceipt
installedReceipt permit prepared targetReceipt =
  AwsAdminWorkerReceipt
    { internalAwsAdminWorkerReceiptKind = AwsAdminInstalled
    , internalAwsAdminWorkerReceiptPermitId = permitIdText permit
    , internalAwsAdminWorkerReceiptRequestDigest = permitRequestDigest permit
    , internalAwsAdminWorkerReceiptTarget = preparedCredentialTargetId prepared
    , internalAwsAdminWorkerReceiptGeneration = preparedCredentialTargetGeneration prepared
    , internalAwsAdminWorkerReceiptTargetReadBack = encodeTargetWorkerReceipt targetReceipt
    }

validateWorkerReceiptForPermit
  :: SignedAwsAdminPermit
  -> PreparedCredentialTargetObservation
  -> AwsAdminWorkerReceipt
  -> Either AwsAdminExecutionError ()
validateWorkerReceiptForPermit permit prepared receipt = do
  unless
    ( awsAdminWorkerReceiptPermitId receipt == permitIdText permit
        && awsAdminWorkerReceiptRequestDigest receipt == permitRequestDigest permit
        && awsAdminWorkerReceiptTarget receipt == preparedCredentialTargetId prepared
        && awsAdminWorkerReceiptGeneration receipt
          == preparedCredentialTargetGeneration prepared
        && not (ByteString.null (awsAdminWorkerReceiptTargetReadBack receipt))
    )
    (Left AwsAdminWorkerReceiptInvalid)
  case awsAdminWorkerReceiptKind receipt of
    AwsAdminInstalled -> do
      targetReceipt <-
        either
          (const (Left AwsAdminWorkerReceiptInvalid))
          Right
          (decodeTargetWorkerReceipt (awsAdminWorkerReceiptTargetReadBack receipt))
      validateTargetReceipt permit prepared targetReceipt
    AwsAdminRevoked -> pure ()

-- | Authority-side terminal validation.  The exact prepared outbox is part of
-- the signed permit, so a worker cannot substitute a caller-supplied target
-- observation while committing its receipt.
validateAwsAdminWorkerReceiptForPermit
  :: SignedAwsAdminPermit
  -> AwsAdminWorkerReceipt
  -> Either AwsAdminExecutionError ()
validateAwsAdminWorkerReceiptForPermit permit =
  validateWorkerReceiptForPermit permit prepared
 where
  prepared =
    awsAdminPermitIntentPreparedTarget (signedAwsAdminPermitIntent permit)

cleanAndProveStableAbsence
  :: (Monad m)
  => AwsAdminIamBoundary m
  -> Int
  -> m (Either AwsAdminExecutionError ())
cleanAndProveStableAbsence iam rounds
  | rounds <= 0 = pure (Left AwsAdminStableAbsenceNotProven)
  | otherwise = do
      observed <- observeKeys iam
      case observed of
        Left err -> pure (Left err)
        Right keys -> do
          deleted <- deleteAll keys
          case deleted of
            Left err -> pure (Left err)
            Right () -> do
              waited <- internalWaitIamVisibilityGrace iam
              case waited of
                Left detail -> pure (Left (AwsAdminVisibilityWaitFailed detail))
                Right () -> do
                  next <- observeKeys iam
                  case next of
                    Left err -> pure (Left err)
                    Right [] -> pure (Right ())
                    Right _ -> cleanAndProveStableAbsence iam (rounds - 1)
 where
  deleteAll =
    foldM
      deleteOne
      (Right ())
  deleteOne result key = case result of
    Left err -> pure (Left err)
    Right () -> do
      deleted <- internalDeleteIamKey iam key
      pure (either (Left . AwsAdminDeleteKeyFailed) Right deleted)

observeExpectedKeys
  :: (Monad m)
  => AwsAdminIamBoundary m
  -> [ProvisionedAccessKeyId]
  -> m (Either AwsAdminExecutionError ())
observeExpectedKeys iam expected = do
  observed <- observeKeys iam
  pure $ do
    actual <- observed
    unless (actual == sort expected) (Left AwsAdminCreatedKeyNotReadBack)

observeKeys
  :: (Monad m)
  => AwsAdminIamBoundary m
  -> m (Either AwsAdminExecutionError [ProvisionedAccessKeyId])
observeKeys iam = do
  observed <- internalObserveIamKeys iam
  pure $ case observed of
    AccessKeyInventoryObserved keys -> Right (sort keys)
    AccessKeyInventoryUnobservable detail -> Left (AwsAdminInventoryUnobservable detail)
    AccessKeyInventoryOverBound count -> Left (AwsAdminInventoryOverBound count)

targetForClass :: AwsCredentialClass -> TargetSecretId
targetForClass credentialClass = case credentialClass of
  LifecycleProviderCredential -> TargetAwsCredential AwsLifecycleProvider
  AuthorityBackupStoreCredential -> TargetAwsCredential AwsAuthorityBackupStore
  TlsRetentionStoreCredential -> TargetAwsCredential AwsTlsRetentionStore
  GatewayDnsCredential -> TargetAwsCredential AwsGatewayDns
  HomeCertManagerDns01Credential -> TargetAwsCredential AwsHomeCertManagerDns01
  AwsRunCertManagerDns01Credential -> TargetAwsCredential AwsRunCertManagerDns01
  SesSmtpRetainedCustodyCredential -> TargetSesSmtp

permitIdText :: SignedAwsAdminPermit -> Text
permitIdText =
  operatorMaterialPermitIdText
    . awsAdminPermitIntentPermitId
    . signedAwsAdminPermitIntent

permitRequestDigest :: SignedAwsAdminPermit -> TargetValueDigest
permitRequestDigest =
  awsAdminPermitIntentRequestDigest . signedAwsAdminPermitIntent

receiptToWire :: AwsAdminWorkerReceipt -> WireAwsAdminWorkerReceipt
receiptToWire receipt =
  WireAwsAdminWorkerReceipt
    { wireWorkerReceiptVersion = awsAdminWorkerReceiptVersion
    , wireWorkerReceiptKind = fromIntegral (fromEnum (awsAdminWorkerReceiptKind receipt) + 1)
    , wireWorkerReceiptPermitId = awsAdminWorkerReceiptPermitId receipt
    , wireWorkerReceiptRequestDigest =
        targetValueDigestText (awsAdminWorkerReceiptRequestDigest receipt)
    , wireWorkerReceiptTarget = awsAdminWorkerReceiptTarget receipt
    , wireWorkerReceiptGeneration =
        credentialGenerationValue (awsAdminWorkerReceiptGeneration receipt)
    , wireWorkerReceiptTargetReadBack = awsAdminWorkerReceiptTargetReadBack receipt
    }

receiptFromWire
  :: WireAwsAdminWorkerReceipt -> Either AwsAdminExecutionError AwsAdminWorkerReceipt
receiptFromWire wire = do
  kind <- case wireWorkerReceiptKind wire of
    1 -> Right AwsAdminInstalled
    2 -> Right AwsAdminRevoked
    _ -> Left AwsAdminWorkerReceiptInvalid
  permitId <- validateIdentity "permit-id" 160 (wireWorkerReceiptPermitId wire)
  requestDigest <-
    either
      (const (Left AwsAdminWorkerReceiptInvalid))
      Right
      (mkTargetValueDigest (wireWorkerReceiptRequestDigest wire))
  generation <-
    either
      (const (Left AwsAdminWorkerReceiptInvalid))
      Right
      (mkCredentialGeneration (wireWorkerReceiptGeneration wire))
  when
    (ByteString.null (wireWorkerReceiptTargetReadBack wire))
    (Left AwsAdminWorkerReceiptInvalid)
  case kind of
    AwsAdminInstalled -> do
      targetReceipt <-
        either
          (const (Left AwsAdminWorkerReceiptInvalid))
          Right
          (decodeTargetWorkerReceipt (wireWorkerReceiptTargetReadBack wire))
      unless
        ( targetWorkerReceiptTarget targetReceipt == wireWorkerReceiptTarget wire
            && targetWorkerReceiptGeneration targetReceipt == generation
        )
        (Left AwsAdminWorkerReceiptInvalid)
    AwsAdminRevoked -> pure ()
  pure
    AwsAdminWorkerReceipt
      { internalAwsAdminWorkerReceiptKind = kind
      , internalAwsAdminWorkerReceiptPermitId = permitId
      , internalAwsAdminWorkerReceiptRequestDigest = requestDigest
      , internalAwsAdminWorkerReceiptTarget = wireWorkerReceiptTarget wire
      , internalAwsAdminWorkerReceiptGeneration = generation
      , internalAwsAdminWorkerReceiptTargetReadBack = wireWorkerReceiptTargetReadBack wire
      }

cleanupRoundMaximum :: Int
cleanupRoundMaximum = 4

validateIdentity
  :: Text -> Int -> Text -> Either AwsAdminExecutionError Text
validateIdentity _ maximumLength raw
  | Text.null value = Left AwsAdminPreparedTargetInvalid
  | Text.length value > maximumLength = Left AwsAdminPreparedTargetInvalid
  | Text.any (\character -> isControl character || isSpace character) value =
      Left AwsAdminPreparedTargetInvalid
  | otherwise = Right value
 where
  value = Text.strip raw

boundedShow :: (Show value) => value -> Text
boundedShow = Text.take 256 . Text.pack . show

data AwsAdminRecoveryRemintCause
  = AwsAdminRecoveryRemintJournalResumed
  | AwsAdminRecoveryRemintIntentInventoryNotEmpty
  | AwsAdminRecoveryRemintPreparedInventoryDiverged
  | AwsAdminRecoveryRemintCreateDispatchAmbiguous
  | AwsAdminRecoveryRemintCreateLostResult
  | AwsAdminRecoveryRemintCreatedKeyPredecessorCollision
  | AwsAdminRecoveryRemintCreatedMaterialUnavailable
  | AwsAdminRecoveryRemintMaterialInvalid
  | AwsAdminRecoveryRemintTargetDeliveryFailed !AwsAdminTargetDeliveryCause
  | AwsAdminRecoveryRemintTargetReceiptMismatch
  deriving stock (Eq, Show)

allAwsAdminRecoveryRemintCauses :: [AwsAdminRecoveryRemintCause]
allAwsAdminRecoveryRemintCauses =
  [ AwsAdminRecoveryRemintJournalResumed
  , AwsAdminRecoveryRemintIntentInventoryNotEmpty
  , AwsAdminRecoveryRemintPreparedInventoryDiverged
  , AwsAdminRecoveryRemintCreateDispatchAmbiguous
  , AwsAdminRecoveryRemintCreateLostResult
  , AwsAdminRecoveryRemintCreatedKeyPredecessorCollision
  , AwsAdminRecoveryRemintCreatedMaterialUnavailable
  , AwsAdminRecoveryRemintMaterialInvalid
  ]
    <> fmap AwsAdminRecoveryRemintTargetDeliveryFailed allAwsAdminTargetDeliveryCauses
    <> [AwsAdminRecoveryRemintTargetReceiptMismatch]

renderAwsAdminRecoveryRemintCause :: AwsAdminRecoveryRemintCause -> Text
renderAwsAdminRecoveryRemintCause cause = case cause of
  AwsAdminRecoveryRemintJournalResumed -> "journal-resumed"
  AwsAdminRecoveryRemintIntentInventoryNotEmpty -> "intent-inventory-not-empty"
  AwsAdminRecoveryRemintPreparedInventoryDiverged -> "prepared-inventory-diverged"
  AwsAdminRecoveryRemintCreateDispatchAmbiguous -> "create/dispatch-ambiguous"
  AwsAdminRecoveryRemintCreateLostResult -> "create/lost-result"
  AwsAdminRecoveryRemintCreatedKeyPredecessorCollision -> "created-key-predecessor-collision"
  AwsAdminRecoveryRemintCreatedMaterialUnavailable -> "created-material-unavailable"
  AwsAdminRecoveryRemintMaterialInvalid -> "material-invalid"
  AwsAdminRecoveryRemintTargetDeliveryFailed deliveryCause ->
    "target-delivery-failed/" <> renderAwsAdminTargetDeliveryCause deliveryCause
  AwsAdminRecoveryRemintTargetReceiptMismatch -> "target-receipt-mismatch"

recoveryRemintCauseForCreateAmbiguity
  :: AwsAccessKeyCreateAmbiguityCause -> AwsAdminRecoveryRemintCause
recoveryRemintCauseForCreateAmbiguity ambiguity = case ambiguity of
  AwsAccessKeyCreateDispatchAmbiguous -> AwsAdminRecoveryRemintCreateDispatchAmbiguous
  AwsAccessKeyCreateLostResult -> AwsAdminRecoveryRemintCreateLostResult

data AwsAdminExecutionError
  = AwsAdminPreparedTargetInvalid
  | AwsAdminPreparedTargetMismatch
  | AwsAdminPrepareTargetFailed !Text
  | AwsAdminExecutionJournalUnavailable !Text
  | AwsAdminExecutionJournalPermitMismatch
  | AwsAdminExecutionJournalTransitionRejected !Text
  | AwsAdminExecutionJournalCommitFailed !Text
  | AwsAdminExecutionJournalReadBackMismatch
  | AwsAdminExecutionTransitionLimitReached
  | AwsAdminIamPrerequisiteFailed !ProductionIamErrorCause
  | AwsAdminInventoryUnobservable !Text
  | AwsAdminInventoryOverBound !Int
  | AwsAdminInstallRequiresEmptyInventory
  | AwsAdminDeleteKeyFailed !Text
  | AwsAdminCreateKeyFailed !Text
  | AwsAdminCreatedKeyNotReadBack
  | AwsAdminVisibilityWaitFailed !Text
  | AwsAdminStableAbsenceNotProven
  | AwsAdminRecoveryRemintAmbiguous !AwsAdminRecoveryRemintCause
  | AwsAdminMaterialInvalid !TargetMaterialValueError
  | AwsAdminTargetDeliveryFailed !AwsAdminTargetDeliveryCause
  | AwsAdminTargetObservationUnobservable !AwsAdminTargetObservationCause
  | AwsAdminTargetReceiptMismatch
  | AwsAdminTargetRevocationFailed !Text
  | -- | Sprint 4.85: the revoked target generation could not be re-observed,
    -- so the revocation has no independent read-back.
    AwsAdminTargetRevocationUnobservable !Text
  | -- | Sprint 4.85: the target generation is still present after a revoke
    -- the worker reported as applied.
    AwsAdminTargetGenerationStillPresent
  | -- | Sprint 4.85: both absences were observed but the canonical revocation
    -- read-back refused to bind them.  Unreachable while both are @True@;
    -- mapped rather than assumed so the binding stays load-bearing.
    AwsAdminRevocationNotReadBack
  | AwsAdminIdentityDestroyFailed !Text
  | AwsAdminIdentityAbsenceUnobservable !Text
  | AwsAdminIdentityStillPresent
  | AwsAdminWorkerReceiptTooLarge !Int !Int
  | AwsAdminWorkerReceiptDecodeFailed
  | AwsAdminWorkerReceiptUnsupportedVersion !Word16
  | AwsAdminWorkerReceiptNonCanonical
  | AwsAdminWorkerReceiptInvalid
  deriving stock (Eq, Show)

classifyAwsAdminExecutionError :: AwsAdminExecutionError -> AwsAdminWorkerExecutionCause
classifyAwsAdminExecutionError err = case err of
  AwsAdminPreparedTargetInvalid -> AwsAdminWorkerExecutionPreparedTargetInvalid
  AwsAdminPreparedTargetMismatch -> AwsAdminWorkerExecutionPreparedTargetMismatch
  AwsAdminPrepareTargetFailed _ -> AwsAdminWorkerExecutionPrepareTargetFailed
  AwsAdminExecutionJournalUnavailable _ -> AwsAdminWorkerExecutionJournalUnavailable
  AwsAdminExecutionJournalPermitMismatch -> AwsAdminWorkerExecutionJournalPermitMismatch
  AwsAdminExecutionJournalTransitionRejected _ ->
    AwsAdminWorkerExecutionJournalTransitionRejected
  AwsAdminExecutionJournalCommitFailed _ -> AwsAdminWorkerExecutionJournalCommitFailed
  AwsAdminExecutionJournalReadBackMismatch -> AwsAdminWorkerExecutionJournalReadBackMismatch
  AwsAdminExecutionTransitionLimitReached -> AwsAdminWorkerExecutionTransitionLimitReached
  AwsAdminIamPrerequisiteFailed cause -> AwsAdminWorkerExecutionIamPrerequisiteFailed cause
  AwsAdminInventoryUnobservable _ -> AwsAdminWorkerExecutionInventoryUnobservable
  AwsAdminInventoryOverBound _ -> AwsAdminWorkerExecutionInventoryOverBound
  AwsAdminInstallRequiresEmptyInventory -> AwsAdminWorkerExecutionInstallRequiresEmptyInventory
  AwsAdminDeleteKeyFailed _ -> AwsAdminWorkerExecutionDeleteKeyFailed
  AwsAdminCreateKeyFailed _ -> AwsAdminWorkerExecutionCreateKeyFailed
  AwsAdminCreatedKeyNotReadBack -> AwsAdminWorkerExecutionCreatedKeyNotReadBack
  AwsAdminVisibilityWaitFailed _ -> AwsAdminWorkerExecutionVisibilityWaitFailed
  AwsAdminStableAbsenceNotProven -> AwsAdminWorkerExecutionStableAbsenceNotProven
  AwsAdminRecoveryRemintAmbiguous cause -> AwsAdminWorkerExecutionRecoveryRemintAmbiguous cause
  AwsAdminMaterialInvalid _ -> AwsAdminWorkerExecutionMaterialInvalid
  AwsAdminTargetDeliveryFailed cause -> AwsAdminWorkerExecutionTargetDeliveryFailed cause
  AwsAdminTargetObservationUnobservable cause ->
    AwsAdminWorkerExecutionTargetObservationUnobservable cause
  AwsAdminTargetReceiptMismatch -> AwsAdminWorkerExecutionTargetReceiptMismatch
  AwsAdminTargetRevocationFailed _ -> AwsAdminWorkerExecutionTargetRevocationFailed
  AwsAdminTargetRevocationUnobservable _ ->
    AwsAdminWorkerExecutionTargetRevocationUnobservable
  AwsAdminTargetGenerationStillPresent -> AwsAdminWorkerExecutionTargetGenerationStillPresent
  AwsAdminRevocationNotReadBack -> AwsAdminWorkerExecutionRevocationNotReadBack
  AwsAdminIdentityDestroyFailed _ -> AwsAdminWorkerExecutionIdentityDestroyFailed
  AwsAdminIdentityAbsenceUnobservable _ ->
    AwsAdminWorkerExecutionIdentityAbsenceUnobservable
  AwsAdminIdentityStillPresent -> AwsAdminWorkerExecutionIdentityStillPresent
  AwsAdminWorkerReceiptTooLarge _ _ -> AwsAdminWorkerExecutionReceiptTooLarge
  AwsAdminWorkerReceiptDecodeFailed -> AwsAdminWorkerExecutionReceiptDecodeFailed
  AwsAdminWorkerReceiptUnsupportedVersion _ -> AwsAdminWorkerExecutionReceiptUnsupportedVersion
  AwsAdminWorkerReceiptNonCanonical -> AwsAdminWorkerExecutionReceiptNonCanonical
  AwsAdminWorkerReceiptInvalid -> AwsAdminWorkerExecutionReceiptInvalid
