{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module CredentialProvisionerAwsAdminAuthority
  ( credentialProvisionerAwsAdminAuthoritySuite
  )
where

import Codec.Serialise (Serialise, serialise)
import Control.Exception (AsyncException (ThreadKilled), throwIO, try)
import Control.Monad (forM_, void)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.Bifunctor (first)
import Data.ByteArray qualified as ByteArray
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Data.Word (Word16, Word8)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Options.Applicative
  ( ParserResult (Success)
  , defaultPrefs
  , execParserPure
  )
import Prodbox.Aws.Native.Wire
  ( AwsClientError (AwsServiceError, AwsTransportError)
  , AwsServiceFault (..)
  )
import Prodbox.CLI.Parser (parserInfo)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  , AuthenticatedRolePlainResponseCause (AuthenticatedRoleReplayUnavailable)
  , AuthenticatedRolePlainResponseObservation (..)
  , allAuthenticatedRolePlainResponseCauses
  , allAuthenticatedRolePlainResponseObservations
  , authenticatedRolePlainResponse
  , classifyAuthenticatedRolePlainResponse
  , renderAuthenticatedRolePlainResponseObservation
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError (AuthenticatedClientTransportFailed)
  )
import Prodbox.ControlPlane.AuthenticationRegistry (callerMayCallRoute)
import Prodbox.ControlPlane.AuthorityBackupReconcileProduction
  ( GenesisAwsAdminIntentParameters (..)
  )
import Prodbox.ControlPlane.AwsAdminAuthorizedRecoveryProduction
  ( classifyAwsAdminAttemptResourceHttpStatus
  , classifyAwsAdminRecoveryJournalObservation
  , fixedAwsAdminAttestedRecoveryRegression
  , fixedAwsAdminCredentialQuiescenceRegression
  )
import Prodbox.ControlPlane.AwsAdminPreparedTargetProduction
  ( AwsAdminPreparedTargetLifecycle (..)
  , AwsAdminPreparedTargetOutboxDecision (..)
  , AwsAdminPreparedTargetPrepareCause (..)
  , FirstReconcileContinuation (..)
  , allAwsAdminPreparedTargetPrepareCauses
  , awsAdminPreparedTargetPrepareError
  , awsAdminPreparedTargetPrepareErrorCause
  , decideAwsAdminPreparedTargetOutbox
  , ensureGenesisFirstReconcileJournal
  , publishAwsAdminPreparedTarget
  , renderAwsAdminPrepareAuthorityPhaseDiagnostic
  , renderAwsAdminPreparedTargetOutboxDiagnostic
  , renderAwsAdminPreparedTargetPrepareCause
  )
import Prodbox.ControlPlane.AwsAdminProvisionerClient
  ( AwsAdminPreparedProvisioning (..)
  , AwsAdminProvisionerClient
  , AwsAdminProvisionerClientError
    ( AwsAdminProvisionerClientRefused
    , AwsAdminProvisionerClientUnavailable
    , AwsAdminProvisionerClientUnexpectedResponse
    )
  , mkAwsAdminProvisionerClient
  , observeAwsAdminFirstReconcile
  , observeAwsAdminProviderCredentialRecoveryView
  )
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( AwsAdminFirstReconcileProjection (..)
  , AwsAdminPodObservation (..)
  , AwsAdminProviderCredentialBoundary (..)
  , AwsAdminProvisionerChallenge (..)
  , AwsAdminProvisionerObservation (..)
  , AwsAdminProvisionerPhase
    ( AwsAdminProvisionerAuthorized
    , AwsAdminProvisionerCompleted
    , AwsAdminProvisionerPrepared
    )
  , AwsAdminProvisionerRequest (..)
  , AwsAdminProvisionerResponse (..)
  , awsAdminProvisionerAuthenticatedHandler
  , awsAdminProvisionerResponseMaximumBytes
  )
import Prodbox.ControlPlane.AwsAdminTargetRevokeClient
  ( AwsAdminTargetRevokeClientError (..)
  , decodeAwsAdminTargetRevokeResponse
  )
import Prodbox.ControlPlane.AwsAdminTargetRevokeEndpoint
  ( AwsAdminTargetRevokeRefusal (..)
  , AwsAdminTargetRevokeRequest (..)
  , AwsAdminTargetRevokeResponse (..)
  , AwsAdminTargetRevokeVerification (..)
  , awsAdminTargetRevokeAuthenticatedHandler
  , awsAdminTargetRevokeRequest
  , mkAwsAdminTargetRevokeBoundary
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal
      ( CallerCredentialProvisioner
      , CallerCredentialProvisionerCompletion
      , CallerOperatorCli
      )
  , allCallerPrincipals
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneClientError (ControlPlaneTransportFailed)
  , ControlPlaneResponse (..)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (ControlPlaneRequestInvalid)
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.RoleReadiness (noRoleReadinessContribution)
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleAwsAdminProvisioner, TargetAwsAdminCredentialRevoke)
  )
import Prodbox.ControlPlane.TargetAuthorityTrust
  ( allTargetAuthorityTrustBoundaryCauses
  , allTargetAuthorityTrustObservationCauses
  , renderTargetAuthorityTrustBoundaryCause
  , renderTargetAuthorityTrustObservationCause
  )
import Prodbox.ControlPlane.TargetAuthorityTrustClient
  ( TargetAuthorityTrustClientError (..)
  , classifyTargetAuthorityTrustClientError
  , decodeTargetAuthorityTrustClientResponse
  )
import Prodbox.ControlPlane.TargetAuthorityTrustEndpoint
  ( classifyTargetAuthorityTrustObservationFailure
  )
import Prodbox.ControlPlane.TargetIntentAuthorityClient
  ( TargetIntentAuthorityClientError (..)
  )
import Prodbox.ControlPlane.TargetMaterialClient
  ( TargetMaterialClientError (..)
  , allTargetMaterialClientCauses
  , classifyTargetMaterialClientError
  , decodeTargetMaterialClientResponse
  , renderTargetMaterialClientCause
  )
import Prodbox.ControlPlane.TargetMaterialEndpoint (TargetMaterialObservation (..))
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity
      ( AwsAuthorityBackupStore
      , AwsLifecycleProvider
      , AwsRunCertManagerDns01
      , AwsTlsRetentionStore
      )
  , TargetSecretId (TargetAwsCredential)
  )
import Prodbox.ControlPlane.TargetMaterializationProduction
  ( classifyAwsAdminTargetReadBack
  , classifyTargetIntentIssueError
  , classifyTargetWorkerError
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  , TargetAgentRolloutObservationCause (TargetAgentRolloutKubeconfigUnavailable)
  , mkTargetAgentIdentity
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerReceipt
  , encodeTargetWorkerReceipt
  , mkTargetWorkerReceiptProjection
  )
import Prodbox.ControlPlane.TargetSecretWorkerCoordinator
  ( TargetWorkerCoordinatorError (..)
  )
import Prodbox.Http.Client (HttpError (..))
import Prodbox.Http.ReplyStatus (ReplyStatus (..), replyStatusCode)
import Prodbox.Lib.ChartPlatform
  ( KubernetesApiEgressCoordinate (..)
  )
import Prodbox.Lifecycle.Authority.Genesis (GenesisPlan (..))
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch (ProviderCredentialRecoveryView (..))
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAuthority
  ( AwsAdminAttemptJournalObservation (..)
  , AwsAdminAttemptResourceObservation (..)
  , AwsAdminAuthorityAuthorizationError (..)
  , AwsAdminAuthorityRepository (..)
  , AwsAdminAuthorityRepositoryError (..)
  , AwsAdminAuthoritySnapshot (..)
  , AwsAdminAuthorityState (..)
  , AwsAdminAuthorityStateError (..)
  , AwsAdminAuthorizedRecoveryError (..)
  , AwsAdminPreparedTargetBoundary (..)
  , AwsAdminRecoveryCleanupPhase (..)
  , attestAwsAdminAuthority
  , authorizeAwsAdminAttestation
  , awsAdminPreparedRenewalBindingsMatch
  , bindAwsAdminAuthorizedRecoveryIntent
  , bindAwsAdminPreparedRenewalIntent
  , commitAwsAdminAttested
  , commitAwsAdminCompleted
  , commitAwsAdminPrepared
  , commitAwsAdminPreparedAuthorizedRecovery
  , commitAwsAdminPreparedRenewal
  , decodeAwsAdminAuthorityState
  , encodeAwsAdminAuthorityState
  , initialAwsAdminAuthorityState
  , prepareAwsAdminAuthority
  , prepareAwsAdminAuthorityAuthorizedRecovery
  , prepareAwsAdminAuthorityRenewal
  , proveAwsAdminAuthorizedRecovery
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminCoordinator
  ( AwsAdminCoordinatorError (..)
  , AwsAdminKubernetesBoundary (..)
  , coordinateAwsAdminProvisioning
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminExecutionError (..)
  , AwsAdminInstallAttempt (..)
  , AwsAdminInstallInventory (..)
  , AwsAdminInstallInventoryDecision (..)
  , AwsAdminInstallPlanBinding (..)
  , AwsAdminRecoveryRemintCause (..)
  , AwsAdminTargetDeliveryCause (..)
  , AwsAdminTargetObservationCause (..)
  , AwsAdminWorkerActionProgress (..)
  , AwsAdminWorkerJournalUnavailableCause (..)
  , AwsAdminWorkerReceipt
  , AwsAdminWorkerReceiptCaptureSize
  , AwsAdminWorkerReceiptDecodeCause
  , AwsAdminWorkerReceiptEnvelopeDecodeCause (..)
  , AwsAdminWorkerReceiptEnvelopeLineDisposition
  , AwsAdminWorkerReceiptKind (AwsAdminRevoked)
  , AwsAdminWorkerReceiptLineTopology
  , AwsAdminWorkerReceiptPrefixLineDisposition
  , AwsAdminWorkerReceiptTerminalEnding
  , AwsAdminWorkerSessionClosureCause (..)
  , AwsAdminWorkerTerminalLineDisposition (..)
  , allAwsAdminRecoveryRemintCauses
  , allAwsAdminTargetDeliveryCauses
  , allAwsAdminTargetObservationCauses
  , allAwsAdminTargetWorkerObservationCauses
  , allAwsAdminWorkerExecutionCauses
  , allAwsAdminWorkerJournalUnavailableCauses
  , allAwsAdminWorkerSessionClosureCauses
  , allAwsAdminWorkerTerminalCauses
  , awsAdminWorkerReceiptGeneration
  , awsAdminWorkerReceiptKind
  , classifyAwsAdminExecutionError
  , classifyAwsAdminTargetWorkerObservationFailure
  , classifyAwsAdminWorkerJournalUnavailable
  , classifyAwsAdminWorkerReceiptTransport
  , decideAwsAdminInstallInventory
  , decodeAwsAdminWorkerReceipt
  , decodeAwsAdminWorkerReceiptTextEnvelope
  , encodeAwsAdminWorkerReceipt
  , encodeAwsAdminWorkerReceiptTextEnvelope
  , executeAwsAdminPermit
  , mkAwsAdminDeliveryBoundary
  , mkAwsAdminExecutionJournalBoundary
  , mkAwsAdminIamBoundary
  , renderAwsAdminRecoveryRemintCause
  , renderAwsAdminTargetDeliveryCause
  , renderAwsAdminTargetIntentIssueCause
  , renderAwsAdminTargetObservationCause
  , renderAwsAdminTargetWorkerCause
  , renderAwsAdminTargetWorkerObservationCause
  , renderAwsAdminWorkerExecutionCause
  , renderAwsAdminWorkerJournalUnavailableCause
  , renderAwsAdminWorkerReceiptCaptureSize
  , renderAwsAdminWorkerReceiptDecodeCause
  , renderAwsAdminWorkerReceiptEnvelopeDecodeCause
  , renderAwsAdminWorkerReceiptEnvelopeLineDisposition
  , renderAwsAdminWorkerReceiptLineTopology
  , renderAwsAdminWorkerReceiptPrefixLineDisposition
  , renderAwsAdminWorkerReceiptTerminalEnding
  , renderAwsAdminWorkerReceiptTransportObservation
  , renderAwsAdminWorkerSessionClosureCause
  , renderAwsAdminWorkerTerminalCause
  , renderAwsAdminWorkerTerminalLineDisposition
  , validateAwsAdminWorkerReceiptForPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecutionJournal
  ( AwsAdminExecutionEvent (..)
  , AwsAdminExecutionJournal
  , AwsAdminExecutionJournalError (AwsAdminExecutionTransitionRefused)
  , AwsAdminExecutionPhase (..)
  , awsAdminExecutionJournalPhase
  , initialAwsAdminExecutionJournal
  , stepAwsAdminExecutionJournal
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecutionVault
  ( AwsAdminExecutionJournalObservationCause (..)
  , AwsAdminExecutionJournalPhaseCause (..)
  , AwsAdminExecutionJournalRecoveryFlag (..)
  , AwsAdminExecutionJournalRecoveryObservation (..)
  , fixedAwsAdminCompletedExecutionRegression
  , renderAwsAdminExecutionJournalObservationCause
  , renderAwsAdminExecutionJournalRecoveryObservation
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminKubernetes
  ( AwsAdminKubernetesError (..)
  , AwsAdminPodConvergence (..)
  , AwsAdminWorkerReceiptCaptureSource
  , awaitAwsAdminPodObservationWith
  , decodeAwsAdminWorkerReceiptCapture
  , mkAwsAdminJobResources
  , recoverEmptyAwsAdminWorkerReceiptCaptureWith
  , renderAwsAdminJob
  , renderAwsAdminWorkerReceiptCaptureSource
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminCleanupRecoveryProgram (..)
  , AwsAdminJobBinding
  , AwsAdminPermitError (AwsAdminPermitJobBindingMismatch, AwsAdminPermitKindMismatch)
  , AwsAdminPermitIntent
  , AwsAdminPermitKind (..)
  , CredentialIamParameters
  , SignedAwsAdminPermit
  , awsAdminGenesisKindMatches
  , awsAdminJobNameForPermit
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentAuthorityEndpoint
  , awsAdminPermitIntentAuthorityScope
  , awsAdminPermitIntentCleanupPredecessor
  , awsAdminPermitIntentDeadline
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentIamParameters
  , awsAdminPermitIntentImageDigest
  , awsAdminPermitIntentKind
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentPermitId
  , awsAdminPermitIntentPlanBinding
  , awsAdminPermitIntentPreparedTarget
  , awsAdminPermitIntentRequestDigest
  , awsAdminPermitIntentTarget
  , awsAdminWorkerServiceAccount
  , bindAwsAdminPermitIntentCleanupRecovery
  , bindAwsAdminPermitIntentPreparedTarget
  , decodeSignedAwsAdminPermit
  , encodeAwsAdminPermitIntent
  , encodeSignedAwsAdminPermit
  , mkAuthorityBackupIamParameters
  , mkAwsAdminJobBinding
  , mkAwsRunDns01IamParameters
  , mkGenesisAwsAdminPermitIntent
  , mkLifecycleProviderIamParameters
  , mkNormalAwsAdminPermitIntent
  , mkSomeSignedAwsAdminPermit
  , mkTlsRetentionIamParameters
  , rebindAwsAdminPermitIntentPreparedTarget
  , renewAwsAdminProviderPermitIntent
  , signedAwsAdminPermitBinding
  , signedAwsAdminPermitIntent
  , withSomeSignedAwsAdminPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.Execution
  ( AccessKeyInventoryObservation (..)
  , AwsAccessKeyCreateResult (..)
  , ProvisionedAccessKeyId
  , mkProvisionedAccessKeyId
  )
import Prodbox.Lifecycle.CredentialProvisioner.FirstReconcileJournal
  ( FirstReconcileJournal
  , firstReconcileJournalPlan
  , initialFirstReconcileJournal
  )
import Prodbox.Lifecycle.CredentialProvisioner.HarnessCredential
  ( HarnessCredentialLineage
  , HarnessCredentialResolution (..)
  , HarnessCredentialResolutionError (..)
  , HarnessCredentialSlot (..)
  , confirmHarnessCredentialOutcome
  , confirmHarnessCredentialRevocation
  , harnessCredentialConfirmationGeneration
  , harnessCredentialRevocationEpochReceipt
  , harnessCredentialRevocationOperationId
  , harnessCredentialRevocationReceipt
  , harnessCredentialSlotOperationId
  , harnessCredentialSlotScope
  , mkHarnessCredentialLineage
  , reconcileFirstReconcileProviderRecovery
  , resolveHarnessCredentialSlot
  , resolveHarnessCredentialSubmission
  , resumePendingHarnessCredentialOperation
  )
import Prodbox.Lifecycle.CredentialProvisioner.ImageIdentity
  ( credentialProvisionerRuntimeManifestDigest
  )
import Prodbox.Lifecycle.CredentialProvisioner.KubernetesJob
  ( CredentialProvisionerJobConnection (..)
  , credentialProvisionerKubectlArguments
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , FirstReconcilePermitBinding
  , FirstReconcilePlanAction (..)
  , OperatorMaterialAction (..)
  , OperatorMaterialIngressSchema (AwsAdminProvisioningIngress)
  , OperatorMaterialPermit
  , OperatorMaterialRequest
  , defaultFirstReconcileProvisioningPlan
  , firstReconcilePlanDeadline
  , firstReconcilePlanDigest
  , firstReconcilePlanMemberDigest
  , firstReconcilePlanMemberIndex
  , firstReconcilePlanMembers
  , initialFirstReconcileCursor
  , mkAwsOperatorMaterialRequest
  , mkFirstReconcilePermitBinding
  , mkFirstReconcileProvisioningPlan
  , mkGenesisBackupPermit
  , mkOperatorMaterialOperationId
  , mkOperatorMaterialPermit
  , mkOperatorMaterialPermitId
  , operatorMaterialOperationIdText
  , operatorMaterialPermitIdText
  , operatorMaterialPermitPlanBinding
  , operatorMaterialPermitRequestDigest
  , operatorMaterialRequestDigest
  , withGenesisBackupOperatorPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( PreparedCredentialTargetObservation
  , encodePreparedCredentialTargetObservation
  , mkPreparedCredentialTargetObservation
  , preparedCredentialTargetFence
  , preparedCredentialTargetGeneration
  , preparedCredentialTargetId
  , preparedCredentialTargetOwnerNonce
  , preparedCredentialTargetPlanBinding
  , preparedCredentialTargetReceiptDigest
  , preparedCredentialTargetRequestDigest
  , preparedCredentialTargetSelectedAgent
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTargetOutbox
  ( PreparedCredentialTargetOutbox
  , PreparedCredentialTargetOutboxError (PreparedCredentialTargetOutboxReceiptInvalid)
  , decodePreparedCredentialTargetOutbox
  , encodePreparedCredentialTargetOutbox
  , mkPreparedCredentialTargetOutbox
  , preparedCredentialTargetOutboxCanonicalIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.ProductionIam
  ( ProductionIamAwsClientCause
  , ProductionIamAwsOperationCause
  , ProductionIamError (..)
  , ProductionIamErrorCause (ProductionIamErrorUnclassified)
  , ProductionIamTrustPolicyMismatchCause (..)
  , allProductionIamErrorCauses
  , allProductionIamRoleReadBackCauses
  , classifyProductionIamError
  , classifyProductionIamTrustPolicyMismatch
  , renderProductionIamAwsClientCause
  , renderProductionIamAwsOperationCause
  , renderProductionIamErrorCause
  , renderProductionIamRoleReadBackCause
  , renderProductionIamTrustPolicyMismatchCause
  , trustPoliciesEqual
  )
import Prodbox.Lifecycle.CredentialProvisioner.RuntimeSecurity
  ( credentialProvisionerKubernetesApiVolume
  , credentialProvisionerKubernetesApiVolumeMount
  , credentialProvisionerPodSecurityContext
  )
import Prodbox.Lifecycle.CredentialProvisioner.Substrate
  ( CredentialProvisionerSubstrateBoundary (..)
  , CredentialProvisionerSubstrateError (..)
  , credentialProvisionerSubstrateManifest
  , credentialProvisionerSubstrateMatches
  , credentialProvisionerSubstrateObjectCount
  , reconcileCredentialProvisionerSubstrate
  )
import Prodbox.Lifecycle.CredentialProvisioner.TargetMaterial
  ( mkCreatedAwsAccessKey
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (..)
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( ManifestPublicKey
  , mkManifestPublicKey
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , targetValueDigestText
  )
import Prodbox.Settings (Credentials (..))
import Prodbox.Vault.Session
  ( VaultSessionError (VaultSessionForbidden)
  , VaultSessionOperationError (..)
  )
import TestSupport

addServerGeneration :: Aeson.Value -> Aeson.Value
addServerGeneration (Aeson.Object fields) =
  Aeson.Object (AesonKeyMap.mapWithKey addMetadataGeneration fields)
 where
  addMetadataGeneration "metadata" (Aeson.Object metadata) =
    Aeson.Object (AesonKeyMap.insert "generation" (Aeson.Number 1) metadata)
  addMetadataGeneration _ value = addServerGeneration value
addServerGeneration (Aeson.Array values) =
  Aeson.Array (fmap addServerGeneration values)
addServerGeneration value = value

omitEmptyArrays :: Aeson.Value -> Aeson.Value
omitEmptyArrays (Aeson.Object fields) =
  Aeson.Object (AesonKeyMap.mapMaybe omitEmptyArray fields)
 where
  omitEmptyArray (Aeson.Array values)
    | null values = Nothing
  omitEmptyArray value = Just (omitEmptyArrays value)
omitEmptyArrays (Aeson.Array values) = Aeson.Array (fmap omitEmptyArrays values)
omitEmptyArrays value = value

jobPodSecurityContext :: Aeson.Value -> Maybe Aeson.Value
jobPodSecurityContext (Aeson.Object root) = do
  Aeson.Object spec <- AesonKeyMap.lookup "spec" root
  Aeson.Object template <- AesonKeyMap.lookup "template" spec
  Aeson.Object podSpec <- AesonKeyMap.lookup "spec" template
  AesonKeyMap.lookup "securityContext" podSpec
jobPodSecurityContext _ = Nothing

jobContainerImage :: Aeson.Value -> Maybe Text
jobContainerImage (Aeson.Object root) = do
  Aeson.Object spec <- AesonKeyMap.lookup "spec" root
  Aeson.Object template <- AesonKeyMap.lookup "template" spec
  Aeson.Object podSpec <- AesonKeyMap.lookup "spec" template
  Aeson.Array containers <- AesonKeyMap.lookup "containers" podSpec
  Aeson.Object container <- containers Vector.!? 0
  Aeson.String image <- AesonKeyMap.lookup "image" container
  pure image
jobContainerImage _ = Nothing

jobContainerArguments :: Aeson.Value -> Maybe [Text]
jobContainerArguments (Aeson.Object root) = do
  Aeson.Object spec <- AesonKeyMap.lookup "spec" root
  Aeson.Object template <- AesonKeyMap.lookup "template" spec
  Aeson.Object podSpec <- AesonKeyMap.lookup "spec" template
  Aeson.Array containers <- AesonKeyMap.lookup "containers" podSpec
  Aeson.Object container <- containers Vector.!? 0
  Aeson.Array arguments <- AesonKeyMap.lookup "args" container
  traverse argumentText (Vector.toList arguments)
 where
  argumentText (Aeson.String value) = Just value
  argumentText _ = Nothing
jobContainerArguments _ = Nothing

namedManifestObject :: Text -> Aeson.Value -> Maybe Aeson.Value
namedManifestObject expected (Aeson.Object root) = do
  Aeson.Array items <- AesonKeyMap.lookup "items" root
  let hasName (Aeson.Object item) = do
        Aeson.Object metadata <- AesonKeyMap.lookup "metadata" item
        Aeson.String name <- AesonKeyMap.lookup "name" metadata
        pure (name == expected)
      hasName _ = Nothing
  case filter (maybe False id . hasName) (Vector.toList items) of
    [item] -> Just item
    _ -> Nothing
namedManifestObject _ _ = Nothing

credentialProvisionerAwsAdminAuthoritySuite :: SuiteBuilder ()
credentialProvisionerAwsAdminAuthoritySuite =
  describe "AWS-admin Credential Provisioner Authority" $ do
    awsAdminRevocationOrderCases
    awsAdminTargetAgentRevocationCases
    harnessCredentialLineageCases
    workerReceiptActionCases
    forM_
      [ (ProviderCredentialRecoveryIdle, True)
      , (ProviderCredentialRecoveryPending "credential/exact-operation", True)
      , (ProviderCredentialRecoveryServing 6 (Text.replicate 64 "a"), True)
      , (ProviderCredentialRecoveryRetired 6 (Text.replicate 64 "b"), True)
      , (ProviderCredentialRecoveryClosed, True)
      , (ProviderCredentialRecoveryRevoked, True)
      , (ProviderCredentialRecoveryRecorded 6, True)
      , (ProviderCredentialRecoveryRecorded 0, False)
      , (ProviderCredentialRecoveryServing 0 (Text.replicate 64 "a"), False)
      , (ProviderCredentialRecoveryRetired 0 (Text.replicate 64 "a"), False)
      , (ProviderCredentialRecoveryRetired 6 "malformed scope", False)
      , (ProviderCredentialRecoveryPending "malformed operation", False)
      ]
      $ \(view, valid) ->
        it ("validates non-authorizing retained credential metadata: " <> show view) $ do
          let client = mkAwsAdminProvisionerClient $ \request -> pure $ case request of
                ObserveAwsAdminProviderCredentialRecovery -> Right (AwsAdminProviderCredentialRecoveryObserved view)
                _ -> Right (AwsAdminProvisioningRefused "unexpected request")
          answer <- observeAwsAdminProviderCredentialRecoveryView client
          case (valid, answer) of
            (True, Right actual) -> actual `shouldBe` view
            (False, Left _) -> pure ()
            _ -> expectationFailure (show answer)
    it "proves legacy credential quiescence only from complete bounded namespace inventories" $ do
      assertions <- fixedAwsAdminCredentialQuiescenceRegression
      forM_ assertions $ \(name, passed) ->
        if passed then pure () else expectationFailure (Text.unpack name)
    it "Sprint 2.109 renders the closed non-secret execution substrate" $ do
      let rendered =
            LazyByteString.toStrict
              (Aeson.encode fixtureCredentialProvisionerSubstrateManifest)
      credentialProvisionerSubstrateObjectCount `shouldBe` 9
      forM_
        [ "\"kind\":\"Namespace\""
        , "\"kind\":\"ServiceAccount\""
        , "\"kind\":\"Role\""
        , "\"kind\":\"RoleBinding\""
        , "\"kind\":\"NetworkPolicy\""
        , "prodbox-credential-provisioner"
        , "prodbox-external-material-ingress"
        , "prodbox-control-plane-operator"
        , "prodbox-control-plane-test-harness"
        , "prodbox-credential-provisioner-authority-observer"
        , "prodbox-lifecycle-authority"
        , "pods/attach"
        , "\"resources\":[\"pods/log\"],\"verbs\":[\"get\"]"
        , "aws-admin"
        , "external-acme-eab"
        ]
        (\needle -> rendered `shouldSatisfy` ByteString.isInfixOf needle)
      rendered `shouldSatisfy` (not . ByteString.isInfixOf "\"resources\":[\"secrets\"]")
      rendered `shouldSatisfy` (not . ByteString.isInfixOf "\"resources\":[\"configmaps\"]")
      rendered `shouldSatisfy` (not . ByteString.isInfixOf "\"kind\":\"Pod\"")
      let authorityObserver =
            LazyByteString.toStrict
              . Aeson.encode
              . maybe (error "missing Authority observer Role") id
              $ namedManifestObject
                "prodbox-credential-provisioner-authority-observer"
                fixtureCredentialProvisionerSubstrateManifest
      authorityObserver
        `shouldSatisfy` ByteString.isInfixOf
          "\"resources\":[\"jobs\"],\"verbs\":[\"get\",\"list\"]"
      authorityObserver
        `shouldSatisfy` ByteString.isInfixOf
          "\"resources\":[\"pods\"],\"verbs\":[\"get\",\"list\"]"
      forM_ ["create", "delete", "patch", "update", "watch", "pods/attach", "pods/log"] $ \verb ->
        authorityObserver
          `shouldSatisfy` (not . ByteString.isInfixOf (TextEncoding.encodeUtf8 verb))
      credentialProvisionerSubstrateMatches
        fixtureCredentialProvisionerSubstrateManifest
        (omitEmptyArrays (addServerGeneration fixtureCredentialProvisionerSubstrateManifest))
        `shouldBe` True
      credentialProvisionerSubstrateMatches
        fixtureCredentialProvisionerSubstrateManifest
        ( Aeson.object
            [ "apiVersion" Aeson..= ("v1" :: Text)
            , "kind" Aeson..= ("List" :: Text)
            , "items" Aeson..= ([] :: [Aeson.Value])
            ]
        )
        `shouldBe` False

    it "Sprint 2.116 binds AWS-admin Kubernetes API egress to the observed post-DNAT coordinate" $ do
      let rendered =
            LazyByteString.toStrict
              (Aeson.encode fixtureCredentialProvisionerSubstrateManifest)
      rendered `shouldSatisfy` ByteString.isInfixOf "192.0.2.10/32"
      rendered `shouldSatisfy` ByteString.isInfixOf "\"port\":6443"

    it "Sprint 2.109 accepts only exact independent read-back and recovers apply response loss" $ do
      traceRef <- newIORef ([] :: [Text])
      let boundary applyResult observationResult =
            CredentialProvisionerSubstrateBoundary
              { applyCredentialProvisionerSubstrate = \_ -> do
                  modifyIORef' traceRef (<> ["apply"])
                  pure applyResult
              , observeCredentialProvisionerSubstrate = \_ -> do
                  modifyIORef' traceRef (<> ["observe"])
                  pure observationResult
              }
      reconcileCredentialProvisionerSubstrate
        fixtureKubernetesApiEgressCoordinate
        (boundary (Left "response lost") (Right True))
        `shouldReturn` Right ()
      readIORef traceRef `shouldReturn` ["apply", "observe"]
      writeIORef traceRef []
      reconcileCredentialProvisionerSubstrate
        fixtureKubernetesApiEgressCoordinate
        (boundary (Right ()) (Right False))
        `shouldReturn` Left CredentialProvisionerSubstrateDrifted
      readIORef traceRef `shouldReturn` ["apply", "observe"]
      reconcileCredentialProvisionerSubstrate
        fixtureKubernetesApiEgressCoordinate
        (boundary (Right ()) (Left "API unavailable"))
        `shouldReturn` Left
          (CredentialProvisionerSubstrateObservationUnavailable "API unavailable")

    it "Sprint 2.109 binds every Job operation to the authorized controller subject" $ do
      let connection =
            CredentialProvisionerJobConnection
              { credentialProvisionerJobEnvironment = Nothing
              , credentialProvisionerJobWorkingDirectory = "/repo"
              , credentialProvisionerJobControllerSubject =
                  Just "system:serviceaccount:bootstrap-broker:prodbox-control-plane-operator"
              }
      credentialProvisionerKubectlArguments connection ["create", "--filename=-"]
        `shouldBe` [ "--as=system:serviceaccount:bootstrap-broker:prodbox-control-plane-operator"
                   , "--namespace"
                   , "credential-provisioner"
                   , "create"
                   , "--filename=-"
                   ]

    it "round-trips each durable pre-authorization state canonically" $ do
      let preparedState =
            must (commitAwsAdminPrepared permitIntent initialAwsAdminAuthorityState)
          attestedState = must (commitAwsAdminAttested jobBinding preparedState)
      decodeAwsAdminAuthorityState (encodeAwsAdminAuthorityState preparedState)
        `shouldBe` Right preparedState
      decodeAwsAdminAuthorityState (encodeAwsAdminAuthorityState attestedState)
        `shouldBe` Right attestedState

    it "binds immutable worker image identity into both intent and attestation" $ do
      mkAwsAdminJobBinding
        permitIntent
        (awsAdminJobNameForPermit (awsAdminPermitIntentPermitId permitIntent))
        "job-uid-1"
        "credential-provisioner-pod-1"
        "pod-uid-1"
        otherImageDigest
        awsAdminWorkerServiceAccount
        "service-account-uid-1"
        heartbeat
        `shouldBe` Left AwsAdminPermitJobBindingMismatch

    it "refuses preparation unless the retained Target outbox is re-observed exactly" $ do
      (repository, stateRef) <- freshRepository False
      let boundary =
            AwsAdminPreparedTargetBoundary
              (const (pure (Right mismatchedPreparedTarget)))
      prepareAwsAdminAuthority repository boundary permitIntent
        `shouldReturn` Left AwsAdminAuthorityPreparedTargetMismatch
      (snd <$> readIORef stateRef) `shouldReturn` initialAwsAdminAuthorityState

    it "accepts a lost CAS response only after exact retained readback" $ do
      (repository, stateRef) <- freshRepository True
      prepareAwsAdminAuthority repository exactPreparedBoundary permitIntent
        `shouldReturn` Right (AwsAdminAuthorityPrepared permitIntent)
      (snd <$> readIORef stateRef)
        `shouldReturn` AwsAdminAuthorityPrepared permitIntent

    it "rejects divergent attestation replay" $ do
      (repository, _) <- freshRepository False
      _ <- prepareAwsAdminAuthority repository exactPreparedBoundary permitIntent
      attestAwsAdminAuthority repository jobBinding
        `shouldReturn` Right (AwsAdminAuthorityAttested permitIntent jobBinding)
      attestAwsAdminAuthority repository divergentJobBinding
        `shouldReturn` Left
          ( AwsAdminAuthorityRepositoryStateRejected
              AwsAdminAuthorityTransitionConflict
          )

    it "requires a fresh heartbeat and a generation-stable Transit signature" $ do
      let attested = AwsAdminAuthorityAttested permitIntent jobBinding
      authorizeAwsAdminAttestation authoritySigner (authorityTimeFromMicros 31000002) attested
        `shouldReturn` Left AwsAdminAuthorityAuthorizationAttestationStale
      authorizeAwsAdminAttestation generationDriftSigner signingTime attested
        `shouldReturn` Left
          (AwsAdminAuthorityAuthorizationSignerGenerationChanged 7 8)
      authorized <- authorizeAwsAdminAttestation authoritySigner signingTime attested
      authorized `shouldSatisfy` either (const False) (const True)

    it "keeps delivery, completion, and operator preparation authority disjoint" $ do
      (repository, _) <- freshRepository False
      let handler =
            awsAdminProvisionerAuthenticatedHandler
              (256 * 1024)
              fixtureReadyRoleReadinessSource
              (pure (Right signingTime))
              (const (Right repository))
              exactPreparedLifecycle
              fixtureProviderCredentialBoundary
              authoritySigner
              emptyHandler
          delivery = verifiedCallerSlotFixture CallerCredentialProvisioner 1
          completion = verifiedCallerSlotFixture CallerCredentialProvisionerCompletion 1
          operator = verifiedCallerSlotFixture CallerOperatorCli 1
          prepareBody =
            LazyByteString.toStrict
              ( encodeControlPlaneRequest
                  ( PrepareAwsAdminProvisioning
                      (encodePermitIntent permitIntent)
                  )
              )
          completeBody =
            LazyByteString.toStrict
              (encodeControlPlaneRequest (CompleteAwsAdminProvisioning operationId "bad" "bad"))
      deliveryPrepareResult <-
        authenticatedHandlerHandle
          handler
          delivery
          LifecycleAwsAdminProvisioner
          prepareBody
      fmap fst deliveryPrepareResult `shouldBe` Just ReplyForbidden
      completionPrepareResult <-
        authenticatedHandlerHandle
          handler
          completion
          LifecycleAwsAdminProvisioner
          prepareBody
      fmap fst completionPrepareResult `shouldBe` Just ReplyForbidden
      operatorCompleteResult <-
        authenticatedHandlerHandle
          handler
          operator
          LifecycleAwsAdminProvisioner
          completeBody
      fmap fst operatorCompleteResult `shouldBe` Just ReplyForbidden
      deliveryCompleteResult <-
        authenticatedHandlerHandle
          handler
          delivery
          LifecycleAwsAdminProvisioner
          completeBody
      fmap fst deliveryCompleteResult `shouldBe` Just ReplyForbidden
      completionResult <-
        authenticatedHandlerHandle
          handler
          completion
          LifecycleAwsAdminProvisioner
          completeBody
      fmap fst completionResult `shouldBe` Just ReplyConflict

    forM_ [False, True] $ \providerUnavailable ->
      forM_ [False, True] $ \journalUnavailable ->
        it
          ( "settles first-reconcile only after independent serving proof: "
              <> show (providerUnavailable, journalUnavailable)
          )
          $ do
            events <- newIORef ([] :: [Text])
            (repository, _) <- freshRepository False
            let lifecycle =
                  exactPreparedLifecycle
                    { settleAwsAdminFirstReconcileRecovery = do
                        modifyIORef' events (<> ["journal"])
                        pure (if journalUnavailable then Left "journal unavailable" else Right ())
                    }
                provider =
                  fixtureProviderCredentialBoundary
                    { confirmAwsAdminProviderCredentialServing = do
                        modifyIORef' events (<> ["provider"])
                        pure (if providerUnavailable then Left "Agent unavailable" else Right ())
                    }
                handler =
                  awsAdminProvisionerAuthenticatedHandler
                    (256 * 1024)
                    fixtureReadyRoleReadinessSource
                    (pure (Right (authorityTimeFromMicros 1000000)))
                    (const (Right repository))
                    lifecycle
                    provider
                    authoritySigner
                    emptyHandler
                body = LazyByteString.toStrict (encodeControlPlaneRequest SettleAwsAdminFirstReconcileRecovery)
            response <-
              authenticatedHandlerHandle
                handler
                (verifiedCallerSlotFixture CallerOperatorCli 1)
                LifecycleAwsAdminProvisioner
                body
            fmap fst response
              `shouldBe` Just (if providerUnavailable || journalUnavailable then ReplyServiceUnavailable else ReplyOk)
            readIORef events
              `shouldReturn` if providerUnavailable then ["provider"] else ["provider", "journal"]

    it "replays an exact completed operation without deadline-gated target preparation" $ do
      permit <- authorizedPermitFor permitIntent
      let receipt = must (decodeAwsAdminWorkerReceipt (installedWorkerReceiptBytes permitIntent))
      (repository, stateRef) <- freshRepository False
      writeIORef stateRef (1, AwsAdminAuthorityCompleted permit receipt)
      events <- newIORef ([] :: [Text])
      let lifecycle =
            exactPreparedLifecycle
              { recordAwsAdminPrepareAuthorityPhase = \_ ->
                  modifyIORef' events (<> ["phase"])
              , prepareAndReadBackAwsAdminPreparedTarget = \_ _ -> do
                  modifyIORef' events (<> ["target-prepare"])
                  pure (Left (awsAdminPreparedTargetPrepareError AwsAdminPreparedTargetDeadlineExpired "expired"))
              }
          handler =
            awsAdminProvisionerAuthenticatedHandler
              (256 * 1024)
              fixtureReadyRoleReadinessSource
              (pure (Left "completed replay must not read Authority time"))
              (const (Right repository))
              lifecycle
              fixtureProviderCredentialBoundary
              authoritySigner
              emptyHandler
          body =
            LazyByteString.toStrict
              ( encodeControlPlaneRequest
                  (PrepareAwsAdminProvisioning (encodePermitIntent permitIntent))
              )
      response <-
        authenticatedHandlerHandle
          handler
          (verifiedCallerSlotFixture CallerOperatorCli 1)
          LifecycleAwsAdminProvisioner
          body
      case response of
        Nothing -> expectationFailure "AWS-admin route was not handled"
        Just (status, responseBody) -> do
          status `shouldBe` ReplyOk
          decodeControlPlaneResponse
            awsAdminProvisionerResponseMaximumBytes
            (LazyByteString.fromStrict responseBody)
            `shouldBe` Right (AwsAdminProvisioningPrepared coordinatorChallenge)
      readIORef events `shouldReturn` ["phase"]

    forM_ [False, True] $ \prepareReplay ->
      it
        ( "AWS-ADMIN-COMPLETION-JOURNAL-REPLAY-2026-10-21: refuses completed replay before journal confirmation; prepare="
            <> show prepareReplay
        )
        $ do
          permit <- authorizedPermitFor permitIntent
          world <- newScriptedAwsAdminWorld (initialAwsAdminExecutionJournal permit) [] Nothing
          executed <-
            runScriptedAwsAdminPermit
              world
              permit
              (scriptedTargetReceipt "vault:v1:journal-replay" permitIntent)
          let receipt = must executed
          (repository, state) <- freshRepository False
          writeIORef state (0, AwsAdminAuthorityCompleted permit receipt)
          journalReads <- newIORef (0 :: Int)
          settlements <- newIORef (0 :: Int)
          let lifecycle =
                exactPreparedLifecycle
                  { commitAwsAdminFirstReconcileReceipt = \_ _ -> do
                      modifyIORef' journalReads (+ 1)
                      pure (Left "fixture first-reconcile journal unavailable")
                  }
              boundary =
                fixtureProviderCredentialBoundary
                  { settleAwsAdminProviderCredential = \_ -> do
                      modifyIORef' settlements (+ 1)
                      pure (Right ())
                  }
              handler =
                awsAdminProvisionerAuthenticatedHandler
                  (256 * 1024)
                  fixtureReadyRoleReadinessSource
                  (pure (Left "completed replay must not renew"))
                  (const (Right repository))
                  lifecycle
                  boundary
                  authoritySigner
                  emptyHandler
              operation = operatorMaterialOperationIdText (awsAdminPermitIntentOperationId permitIntent)
              request =
                if prepareReplay
                  then PrepareAwsAdminProvisioning (encodePermitIntent permitIntent)
                  else ObserveAwsAdminProvisioning operation
              body = LazyByteString.toStrict (encodeControlPlaneRequest request)
          forM_ [False, True] $ \_ -> do
            response <-
              authenticatedHandlerHandle
                handler
                (verifiedCallerSlotFixture CallerOperatorCli 1)
                LifecycleAwsAdminProvisioner
                body
            fmap fst response `shouldBe` Just ReplyServiceUnavailable
          metadata <-
            authenticatedHandlerHandle
              handler
              (verifiedCallerSlotFixture CallerOperatorCli 1)
              LifecycleAwsAdminProvisioner
              (LazyByteString.toStrict (encodeControlPlaneRequest (ObserveAwsAdminProvisioningMetadata operation)))
          case metadata of
            Just (ReplyOk, bytes) -> case decodeControlPlaneResponse (256 * 1024) (LazyByteString.fromStrict bytes) of
              Right (AwsAdminProvisioningObserved observed) -> awsAdminObservedPhase observed `shouldBe` AwsAdminProvisionerCompleted
              other -> expectationFailure (show other)
            other -> expectationFailure (show other)
          readIORef journalReads `shouldReturn` 2
          readIORef settlements `shouldReturn` 0
          readIORef state `shouldReturn` (0, AwsAdminAuthorityCompleted permit receipt)

    it "Sprint 6.5 validates the closed expired-attestation recovery matrix" $ do
      let retained = permitIntent
          binding = renewalJobBinding retained
          replacement =
            must
              ( renewAwsAdminProviderPermitIntent
                  (authorityTimeFromMicros 120000000)
                  imageDigest
                  targetAgent
                  retained
              )
          cases =
            must
              ( fixedAwsAdminAttestedRecoveryRegression
                  (authorityTimeFromMicros 60000000)
                  retained
                  binding
                  replacement
              )
      length cases `shouldBe` 16
      forM_ cases $ \(name, passed) ->
        if passed then pure () else expectationFailure (Text.unpack name)

    forM_
      [ AwsAdminAuthorizedRecoveryJobPresent
      , AwsAdminAuthorizedRecoveryJobUnobservable
      , AwsAdminAuthorizedRecoveryPodPresent
      , AwsAdminAuthorizedRecoveryPodUnobservable
      ]
      $ \cause ->
        it ("Sprint 6.5 refuses expired attestation before target publication: " <> show cause) $ do
          let retained = permitIntent
              binding = renewalJobBinding retained
              replacement =
                must
                  ( renewAwsAdminProviderPermitIntent
                      (authorityTimeFromMicros 120000000)
                      imageDigest
                      targetAgent
                      retained
                  )
              current = AwsAdminAuthorityAttested retained binding
          (repository, state) <- freshRepository False
          writeIORef state (0, current)
          events <- newIORef ([] :: [Text])
          let lifecycle =
                exactPreparedLifecycle
                  { proveAwsAdminAttestedAttemptRecovery = \now observedIntent observedBinding -> do
                      now `shouldBe` authorityTimeFromMicros 60000000
                      observedIntent `shouldBe` retained
                      observedBinding `shouldBe` binding
                      modifyIORef' events (<> ["absence-proof"])
                      pure (Left cause)
                  , prepareAndReadBackAwsAdminPreparedTarget = \_ _ -> do
                      modifyIORef' events (<> ["target-prepare"])
                      pure (Right replacement)
                  }
              handler =
                awsAdminProvisionerAuthenticatedHandler
                  (256 * 1024)
                  fixtureReadyRoleReadinessSource
                  (pure (Right (authorityTimeFromMicros 60000000)))
                  (const (Right repository))
                  lifecycle
                  fixtureProviderCredentialBoundary
                  authoritySigner
                  emptyHandler
              body =
                LazyByteString.toStrict
                  (encodeControlPlaneRequest (PrepareAwsAdminProvisioning (encodePermitIntent replacement)))
          response <-
            authenticatedHandlerHandle
              handler
              (verifiedCallerSlotFixture CallerOperatorCli 1)
              LifecycleAwsAdminProvisioner
              body
          fmap fst response `shouldBe` Just ReplyServiceUnavailable
          readIORef state `shouldReturn` (0, current)
          readIORef events `shouldReturn` ["absence-proof"]

    it "Sprint 6.5 independently confirms completed worker journals without repeating the worker" $ do
      permit <- authorizedPermitFor permitIntent
      firstWorld <- newScriptedAwsAdminWorld (initialAwsAdminExecutionJournal permit) [] Nothing
      changedWorld <- newScriptedAwsAdminWorld (initialAwsAdminExecutionJournal permit) [] Nothing
      firstResult <-
        runScriptedAwsAdminPermit
          firstWorld
          permit
          (scriptedTargetReceipt "vault:v1:journal-first" permitIntent)
      changedResult <-
        runScriptedAwsAdminPermit
          changedWorld
          permit
          (scriptedTargetReceipt "vault:v1:journal-changed" permitIntent)
      firstResult `shouldSatisfy` either (const False) (const True)
      changedResult `shouldSatisfy` either (const False) (const True)
      completed <- readIORef (scriptedWorldJournal firstWorld)
      changed <- readIORef (scriptedWorldJournal changedWorld)
      let assertions = must (fixedAwsAdminCompletedExecutionRegression permit completed changed)
      length assertions `shouldBe` 7
      forM_ assertions $ \(name, passed) ->
        if passed then pure () else expectationFailure (Text.unpack name)
      foreignPermit <- authorizedPermitFor revocationPermitIntent
      fixedAwsAdminCompletedExecutionRegression foreignPermit completed changed
        `shouldSatisfy` either (const True) (const False)

    forM_
      [ JournalComplete
      , JournalMissing
      , JournalUnavailable
      , JournalForeignReceipt
      , JournalAdmissionUnavailable
      ]
      $ \scenario ->
        it ("Sprint 6.5 observes journal completion through the actual outbox endpoint: " <> show scenario) $ do
          permit <- authorizedPermitFor permitIntent
          world <- newScriptedAwsAdminWorld (initialAwsAdminExecutionJournal permit) [] Nothing
          executed <-
            runScriptedAwsAdminPermit
              world
              permit
              (scriptedTargetReceipt "vault:v1:journal-endpoint" permitIntent)
          let receipt = must executed
              wrongReceipt = must (decodeAwsAdminWorkerReceipt (workerReceiptBytesForKind permitIntent 2))
          (repository, state) <- freshRepository False
          writeIORef state (0, AwsAdminAuthorityAuthorized permit)
          events <- newIORef ([] :: [Text])
          let lifecycle =
                exactPreparedLifecycle
                  { observeAwsAdminCompletedWorkerReceipt = \selected -> do
                      selected `shouldBe` permit
                      modifyIORef' events (<> ["worker-journal"])
                      pure $ case scenario of
                        JournalComplete -> Right (Just receipt)
                        JournalAdmissionUnavailable -> Right (Just receipt)
                        JournalMissing -> Right Nothing
                        JournalUnavailable -> Left "fixture journal unavailable"
                        JournalForeignReceipt -> Right (Just wrongReceipt)
                  , commitAwsAdminFirstReconcileReceipt = \_ _ -> do
                      modifyIORef' events (<> ["first-reconcile"])
                      pure (Right ())
                  }
              boundary =
                fixtureProviderCredentialBoundary
                  { settleAwsAdminProviderCredential = \_ -> do
                      modifyIORef' events (<> ["provider-settle"])
                      pure $ case scenario of
                        JournalAdmissionUnavailable -> Left "fixture admission unavailable"
                        _ -> Right ()
                  }
              handler =
                awsAdminProvisionerAuthenticatedHandler
                  (256 * 1024)
                  fixtureReadyRoleReadinessSource
                  (pure (Left "journal replay must not renew the permit"))
                  (const (Right repository))
                  lifecycle
                  boundary
                  authoritySigner
                  emptyHandler
              operation = operatorMaterialOperationIdText (awsAdminPermitIntentOperationId permitIntent)
              body = LazyByteString.toStrict (encodeControlPlaneRequest (ObserveAwsAdminProvisioning operation))
              expectedStatus = case scenario of
                JournalComplete -> ReplyOk
                JournalMissing -> ReplyOk
                JournalUnavailable -> ReplyServiceUnavailable
                JournalForeignReceipt -> ReplyConflict
                JournalAdmissionUnavailable -> ReplyServiceUnavailable
              completed = scenario == JournalComplete || scenario == JournalAdmissionUnavailable
          response <-
            authenticatedHandlerHandle
              handler
              (verifiedCallerSlotFixture CallerOperatorCli 1)
              LifecycleAwsAdminProvisioner
              body
          fmap fst response `shouldBe` Just expectedStatus
          (snd <$> readIORef state)
            `shouldReturn` if completed then AwsAdminAuthorityCompleted permit receipt else AwsAdminAuthorityAuthorized permit
          readIORef events
            `shouldReturn` if completed then ["worker-journal", "first-reconcile", "provider-settle"] else ["worker-journal"]
          case (scenario, response) of
            (JournalComplete, Just (_, payload)) ->
              case decodeControlPlaneResponse
                awsAdminProvisionerResponseMaximumBytes
                (LazyByteString.fromStrict payload) of
                Right (AwsAdminProvisioningObserved observed) -> do
                  awsAdminObservedPhase observed `shouldBe` AwsAdminProvisionerCompleted
                  awsAdminObservedReceipt observed `shouldBe` Just (encodeAwsAdminWorkerReceipt receipt)
                _ -> expectationFailure "completed journal was not exposed as the exact completed operation"
            _ -> pure ()

    it "Sprint 2.106 renders every prepared-target failure as one unique closed payload-free cause" $ do
      map fst preparedTargetCauseLabels
        `shouldBe` allAwsAdminPreparedTargetPrepareCauses
      let rendered = map (renderAwsAdminPreparedTargetPrepareCause . fst) preparedTargetCauseLabels
      rendered `shouldBe` map snd preparedTargetCauseLabels
      length (nub rendered) `shouldBe` length rendered

    it "Sprint 2.106 projects the exact unavailable cause without exposing private failure detail" $ do
      forM_ preparedTargetCauseLabels $ \(cause, label) -> do
        firstResponse <- preparedTargetFailureResponse cause "private detail one"
        secondResponse <- preparedTargetFailureResponse cause "different private detail two"
        let expected =
              ( ReplyServiceUnavailable
              , Right (AwsAdminProvisioningUnavailable ("prepared-target/" <> label))
              )
        firstResponse `shouldBe` expected
        secondResponse `shouldBe` expected

    it "Sprint 2.107 initializes once and adopts the retained deadline on retry" $ do
      journalState <- newIORef Nothing
      writeCount <- newIORef 0
      let firstDeadline = authorityTimeFromMicros 60000000
          retryDeadline = authorityTimeFromMicros 120000000
          expected =
            initialFirstReconcileJournal
              (defaultFirstReconcileProvisioningPlan firstDeadline)
          adapter = retainedJournalAdapter journalState writeCount
      ensureGenesisFirstReconcileJournal adapter retainedJournalCoordinate firstDeadline
        `shouldReturn` Right expected
      readIORef writeCount `shouldReturn` 1
      retryResult <-
        ensureGenesisFirstReconcileJournal adapter retainedJournalCoordinate retryDeadline
      retryResult `shouldBe` Right expected
      ( firstReconcilePlanDeadline
          . firstReconcileJournalPlan
          <$> retryResult
        )
        `shouldBe` Right firstDeadline
      readIORef writeCount `shouldReturn` 1

    it "Sprint 2.107 refuses retained structural drift without attempting a write" $ do
      let retainedDeadline = authorityTimeFromMicros 60000000
          driftPlan =
            must
              ( mkFirstReconcileProvisioningPlan
                  retainedDeadline
                  [ EstablishAuthorityBackupMember
                  , ProvisionAwsCredentialMember LifecycleProviderCredential
                  ]
              )
          driftJournal = initialFirstReconcileJournal driftPlan
      journalState <- newIORef (Just (retainedJournalVersion, driftJournal))
      writeCount <- newIORef 0
      result <-
        ensureGenesisFirstReconcileJournal
          (retainedJournalAdapter journalState writeCount)
          retainedJournalCoordinate
          (authorityTimeFromMicros 120000000)
      first awsAdminPreparedTargetPrepareErrorCause result
        `shouldBe` Left AwsAdminPreparedTargetJournalPlanMismatch
      readIORef journalState
        `shouldReturn` Just (retainedJournalVersion, driftJournal)
      readIORef writeCount `shouldReturn` 0

    it "Sprint 2.108 renews only an expired immutable-equivalent prepared attempt" $ do
      let retained = renewalIntentAt renewalOldDeadline imageDigest targetAgent "home"
          replacement =
            renewalIntentAt renewalNewDeadline otherImageDigest renewalTargetAgent "home"
          drifted =
            renewalIntentAt renewalNewDeadline otherImageDigest renewalTargetAgent "other-home"
          prepared = AwsAdminAuthorityPrepared retained
          attested = must (commitAwsAdminAttested (renewalJobBinding retained) prepared)
      commitAwsAdminPreparedRenewal renewalNow retained replacement prepared
        `shouldBe` Right (AwsAdminAuthorityPrepared replacement)
      commitAwsAdminPreparedRenewal
        renewalNow
        retained
        replacement
        (AwsAdminAuthorityPrepared replacement)
        `shouldBe` Right (AwsAdminAuthorityPrepared replacement)
      commitAwsAdminPreparedRenewal
        (authorityTimeFromMicros 5000000)
        retained
        replacement
        prepared
        `shouldBe` Left AwsAdminAuthorityRenewalDeadlineInvalid
      commitAwsAdminPreparedRenewal renewalNow retained drifted prepared
        `shouldBe` Left AwsAdminAuthorityRenewalBindingMismatch
      commitAwsAdminPreparedRenewal renewalNow retained replacement initialAwsAdminAuthorityState
        `shouldBe` Left AwsAdminAuthorityRenewalNotPrepared
      commitAwsAdminPreparedRenewal renewalNow retained replacement attested
        `shouldBe` Left AwsAdminAuthorityRenewalNotPrepared

    it "Sprint 2.108 orders renewal outbox read-back before state CAS and recovers response loss" $ do
      let retained = renewalIntentAt renewalOldDeadline imageDigest targetAgent "home"
          replacement =
            renewalIntentAt renewalNewDeadline otherImageDigest renewalTargetAgent "home"
      events <- newIORef []
      stateRef <- newIORef (0 :: Int, AwsAdminAuthorityPrepared retained)
      let repository = renewalRepository events stateRef
          boundary =
            AwsAdminPreparedTargetBoundary $ \intent -> do
              modifyIORef' events (<> ["outbox-readback"])
              pure (Right (awsAdminPermitIntentPreparedTarget intent))
      prepareAwsAdminAuthorityRenewal
        repository
        boundary
        renewalNow
        retained
        replacement
        `shouldReturn` Right (AwsAdminAuthorityPrepared replacement)
      readIORef events `shouldReturn` ["outbox-readback", "state-cas"]
      (snd <$> readIORef stateRef)
        `shouldReturn` AwsAdminAuthorityPrepared replacement

    it "Sprint 2.114 recovers only an expired binding-equivalent outbox one renewal ahead" $ do
      let canonicalAt activeDeadline activeImage selectedAgent scope =
            must
              ( bindAwsAdminPermitIntentPreparedTarget
                  Nothing
                  (Just renewalPlanBinding)
                  activeDeadline
                  "owner-nonce-1"
                  1
                  selectedAgent
                  (renewalIntentAt activeDeadline activeImage selectedAgent scope)
              )
          retained = canonicalAt renewalOldDeadline imageDigest targetAgent "home"
          outboxAheadIntent =
            canonicalAt renewalNewDeadline otherImageDigest renewalTargetAgent "home"
          nextDeadline = authorityTimeFromMicros 60000000
          desired = canonicalAt nextDeadline imageDigest targetAgent "home"
          retainedPrepared = awsAdminPermitIntentPreparedTarget retained
          outboxAhead = awsAdminPermitIntentPreparedTarget outboxAheadIntent
          desiredPrepared = awsAdminPermitIntentPreparedTarget desired
          retainedCanonicalOutbox = must (mkPreparedCredentialTargetOutbox retained)
          outboxAheadCanonical = must (mkPreparedCredentialTargetOutbox outboxAheadIntent)
          desiredCanonicalOutbox = must (mkPreparedCredentialTargetOutbox desired)
          legacyOutbox =
            must
              . decodePreparedCredentialTargetOutbox
              . encodePreparedCredentialTargetObservation
          afterOutboxExpiry = authorityTimeFromMicros 50000000
          beforeOutboxExpiry = authorityTimeFromMicros 30000000
          preparedWith owner fence selected target activeGeneration request receipt plan activeDeadline =
            must
              ( mkPreparedCredentialTargetObservation
                  owner
                  fence
                  selected
                  target
                  activeGeneration
                  request
                  receipt
                  plan
                  activeDeadline
              )
          rebuild base =
            preparedWith
              (preparedCredentialTargetOwnerNonce base)
              (preparedCredentialTargetFence base)
              (preparedCredentialTargetSelectedAgent base)
          drifted =
            [ preparedWith
                "different-owner"
                (preparedCredentialTargetFence outboxAhead)
                (preparedCredentialTargetSelectedAgent outboxAhead)
                (preparedCredentialTargetId outboxAhead)
                (preparedCredentialTargetGeneration outboxAhead)
                (preparedCredentialTargetRequestDigest outboxAhead)
                (preparedCredentialTargetReceiptDigest outboxAhead)
                (preparedCredentialTargetPlanBinding outboxAhead)
                renewalNewDeadline
            , preparedWith
                (preparedCredentialTargetOwnerNonce outboxAhead)
                2
                (preparedCredentialTargetSelectedAgent outboxAhead)
                (preparedCredentialTargetId outboxAhead)
                (preparedCredentialTargetGeneration outboxAhead)
                (preparedCredentialTargetRequestDigest outboxAhead)
                (preparedCredentialTargetReceiptDigest outboxAhead)
                (preparedCredentialTargetPlanBinding outboxAhead)
                renewalNewDeadline
            , rebuild
                outboxAhead
                (TargetAwsCredential AwsAuthorityBackupStore)
                (preparedCredentialTargetGeneration outboxAhead)
                (preparedCredentialTargetRequestDigest outboxAhead)
                (preparedCredentialTargetReceiptDigest outboxAhead)
                (preparedCredentialTargetPlanBinding outboxAhead)
                renewalNewDeadline
            , rebuild
                outboxAhead
                (preparedCredentialTargetId outboxAhead)
                (must (mkCredentialGeneration 99))
                (preparedCredentialTargetRequestDigest outboxAhead)
                (preparedCredentialTargetReceiptDigest outboxAhead)
                (preparedCredentialTargetPlanBinding outboxAhead)
                renewalNewDeadline
            , rebuild
                outboxAhead
                (preparedCredentialTargetId outboxAhead)
                (preparedCredentialTargetGeneration outboxAhead)
                (must (mkTargetValueDigest (Text.replicate 64 "c")))
                (preparedCredentialTargetReceiptDigest outboxAhead)
                (preparedCredentialTargetPlanBinding outboxAhead)
                renewalNewDeadline
            , rebuild
                outboxAhead
                (preparedCredentialTargetId outboxAhead)
                (preparedCredentialTargetGeneration outboxAhead)
                (preparedCredentialTargetRequestDigest outboxAhead)
                (preparedCredentialTargetReceiptDigest outboxAhead)
                Nothing
                renewalNewDeadline
            ]
          equalDeadlineSuccessor =
            awsAdminPermitIntentPreparedTarget
              (canonicalAt renewalOldDeadline otherImageDigest renewalTargetAgent "home")
          backwardDeadlineSuccessor =
            awsAdminPermitIntentPreparedTarget
              ( canonicalAt
                  (authorityTimeFromMicros 5000000)
                  otherImageDigest
                  renewalTargetAgent
                  "home"
              )
          activeScopeDrift =
            must
              ( mkPreparedCredentialTargetOutbox
                  (canonicalAt renewalNewDeadline otherImageDigest renewalTargetAgent "other-home")
              )
          invalidReceiptPrepared =
            rebuild
              outboxAhead
              (preparedCredentialTargetId outboxAhead)
              (preparedCredentialTargetGeneration outboxAhead)
              (preparedCredentialTargetRequestDigest outboxAhead)
              (must (mkTargetValueDigest (Text.replicate 64 "d")))
              (preparedCredentialTargetPlanBinding outboxAhead)
              renewalNewDeadline
          invalidReceiptIntent =
            must
              ( rebindAwsAdminPermitIntentPreparedTarget
                  invalidReceiptPrepared
                  outboxAheadIntent
              )
      preparedCredentialTargetReceiptDigest outboxAhead
        `shouldNotBe` preparedCredentialTargetReceiptDigest retainedPrepared
      decodePreparedCredentialTargetOutbox
        (encodePreparedCredentialTargetOutbox outboxAheadCanonical)
        `shouldBe` Right outboxAheadCanonical
      mkPreparedCredentialTargetOutbox invalidReceiptIntent
        `shouldBe` Left PreparedCredentialTargetOutboxReceiptInvalid
      decideAwsAdminPreparedTargetOutbox
        (Just (afterOutboxExpiry, retained))
        desired
        outboxAheadCanonical
        `shouldBe` AwsAdminPreparedTargetOutboxReplace
      decideAwsAdminPreparedTargetOutbox
        (Just (afterOutboxExpiry, retained))
        desired
        (legacyOutbox outboxAhead)
        `shouldBe` AwsAdminPreparedTargetOutboxReplace
      decideAwsAdminPreparedTargetOutbox
        (Just (afterOutboxExpiry, retained))
        desired
        desiredCanonicalOutbox
        `shouldBe` AwsAdminPreparedTargetOutboxExact
      decideAwsAdminPreparedTargetOutbox
        (Just (afterOutboxExpiry, retained))
        desired
        (legacyOutbox desiredPrepared)
        `shouldBe` AwsAdminPreparedTargetOutboxReplace
      decideAwsAdminPreparedTargetOutbox
        (Just (afterOutboxExpiry, retained))
        desired
        retainedCanonicalOutbox
        `shouldBe` AwsAdminPreparedTargetOutboxReplace
      forM_
        ( equalDeadlineSuccessor
            : backwardDeadlineSuccessor
            : drifted
        )
        ( \candidate ->
            decideAwsAdminPreparedTargetOutbox
              (Just (afterOutboxExpiry, retained))
              desired
              (legacyOutbox candidate)
              `shouldBe` AwsAdminPreparedTargetOutboxReject
        )
      decideAwsAdminPreparedTargetOutbox
        (Just (beforeOutboxExpiry, retained))
        desired
        outboxAheadCanonical
        `shouldBe` AwsAdminPreparedTargetOutboxReject
      decideAwsAdminPreparedTargetOutbox
        (Just (afterOutboxExpiry, retained))
        desired
        activeScopeDrift
        `shouldBe` AwsAdminPreparedTargetOutboxReject
      renderAwsAdminPreparedTargetOutboxDiagnostic
        (Just (beforeOutboxExpiry, retained))
        (legacyOutbox outboxAhead)
        `shouldBe` "prepared-target/outbox/divergent schema=legacy owner=match fence=match target=match generation=match request=match plan=match deadline=forward-active canonical-bindings=legacy-unavailable"
      renderAwsAdminPreparedTargetOutboxDiagnostic
        (Just (afterOutboxExpiry, retained))
        activeScopeDrift
        `shouldBe` "prepared-target/outbox/divergent schema=current owner=match fence=match target=match generation=match request=match plan=match deadline=forward-expired canonical-bindings=mismatch"

    it "Sprint 2.114 migrates an interrupted legacy outbox before the Authority renewal CAS" $ do
      let canonicalAt activeDeadline activeImage selectedAgent =
            must
              ( bindAwsAdminPermitIntentPreparedTarget
                  Nothing
                  (Just renewalPlanBinding)
                  activeDeadline
                  "owner-nonce-1"
                  1
                  selectedAgent
                  (renewalIntentAt activeDeadline activeImage selectedAgent "home")
              )
          retained = canonicalAt renewalOldDeadline imageDigest targetAgent
          outboxAheadIntent =
            canonicalAt renewalNewDeadline otherImageDigest renewalTargetAgent
          desired =
            canonicalAt (authorityTimeFromMicros 60000000) imageDigest targetAgent
          legacyAhead =
            must
              ( decodePreparedCredentialTargetOutbox
                  ( encodePreparedCredentialTargetObservation
                      (awsAdminPermitIntentPreparedTarget outboxAheadIntent)
                  )
              )
          initialVersion = must (mkModelBObjectVersion "prepared-v1")
          replacementVersion = must (mkModelBObjectVersion "prepared-v2")
          authority =
            must
              ( mkLongLivedCheckpointAuthority
                  "home-authority"
                  "prodbox-retained"
                  "authority"
                  "secret/lifecycle"
              )
      events <- newIORef []
      outboxState <- newIORef (initialVersion, legacyAhead)
      authorityState <- newIORef (0 :: Int, AwsAdminAuthorityPrepared retained)
      let outboxAdapter = interruptedOutboxAdapter events replacementVersion outboxState
          repository = renewalRepository events authorityState
          boundary =
            AwsAdminPreparedTargetBoundary $ \intent ->
              first (Text.pack . show)
                <$> publishAwsAdminPreparedTarget
                  authority
                  outboxAdapter
                  ( Just
                      ( authorityTimeFromMicros 50000000
                      , retained
                      )
                  )
                  intent
      prepareAwsAdminAuthorityRenewal
        repository
        boundary
        (authorityTimeFromMicros 50000000)
        retained
        desired
        `shouldReturn` Right (AwsAdminAuthorityPrepared desired)
      readIORef events `shouldReturn` ["outbox-cas", "state-cas"]
      (_, migrated) <- readIORef outboxState
      preparedCredentialTargetOutboxCanonicalIntent migrated
        `shouldBe` Just desired

    it "Sprint 2.115 reports every retained Authority phase without retained values" $ do
      map renderAwsAdminPrepareAuthorityPhaseDiagnostic [minBound .. maxBound]
        `shouldBe` [ "aws-admin/prepare authority-phase=vacant"
                   , "aws-admin/prepare authority-phase=prepared"
                   , "aws-admin/prepare authority-phase=attested"
                   , "aws-admin/prepare authority-phase=authorized"
                   , "aws-admin/prepare authority-phase=completed"
                   ]
      map
        renderAwsAdminExecutionJournalObservationCause
        ([minBound .. maxBound] :: [AwsAdminExecutionJournalObservationCause])
        `shouldBe` [ "absent"
                   , "present"
                   , "session-acquisition/sealed"
                   , "session-acquisition/forbidden"
                   , "session-acquisition/unavailable"
                   , "session-relogin/sealed"
                   , "session-relogin/forbidden"
                   , "session-relogin/unavailable"
                   , "request/unauthorized"
                   , "request/client-failure"
                   , "request/server-failure"
                   , "request/unexpected-status"
                   , "request/connection-failure"
                   , "request/timeout"
                   , "request/decode-failure"
                   ]
      let initial = AwsAdminExecutionInitialAttempt
          remint = AwsAdminExecutionRemintUsed
          recoveryObservations =
            [ AwsAdminExecutionJournalRecoveryAbsent
            , AwsAdminExecutionJournalRecoveryPresent
                (AwsAdminExecutionJournalIntentCommitted initial)
            , AwsAdminExecutionJournalRecoveryPresent
                (AwsAdminExecutionJournalIntentCommitted remint)
            , AwsAdminExecutionJournalRecoveryPresent
                (AwsAdminExecutionJournalCreateAttemptPrepared initial)
            , AwsAdminExecutionJournalRecoveryPresent
                (AwsAdminExecutionJournalCreateAttemptPrepared remint)
            , AwsAdminExecutionJournalRecoveryPresent
                (AwsAdminExecutionJournalKeyCreated initial)
            , AwsAdminExecutionJournalRecoveryPresent
                (AwsAdminExecutionJournalKeyCreated remint)
            , AwsAdminExecutionJournalRecoveryPresent
                (AwsAdminExecutionJournalTargetCommitted initial)
            , AwsAdminExecutionJournalRecoveryPresent
                (AwsAdminExecutionJournalTargetCommitted remint)
            , AwsAdminExecutionJournalRecoveryPresent
                (AwsAdminExecutionJournalCleanupRequired initial)
            , AwsAdminExecutionJournalRecoveryPresent
                (AwsAdminExecutionJournalCleanupRequired remint)
            , AwsAdminExecutionJournalRecoveryPresent
                (AwsAdminExecutionJournalCleanupProven initial)
            , AwsAdminExecutionJournalRecoveryPresent
                (AwsAdminExecutionJournalCleanupProven remint)
            , AwsAdminExecutionJournalRecoveryPresent AwsAdminExecutionJournalComplete
            , AwsAdminExecutionJournalRecoveryPermitMismatch
            , AwsAdminExecutionJournalRecoveryInvalid
            , AwsAdminExecutionJournalRecoveryUnobservable
                AwsAdminExecutionJournalRequestTimeout
            ]
      map
        renderAwsAdminExecutionJournalRecoveryObservation
        recoveryObservations
        `shouldBe` [ "absent"
                   , "present/intent-committed/initial-attempt"
                   , "present/intent-committed/remint-used"
                   , "present/create-attempt-prepared/initial-attempt"
                   , "present/create-attempt-prepared/remint-used"
                   , "present/key-created/initial-attempt"
                   , "present/key-created/remint-used"
                   , "present/target-committed/initial-attempt"
                   , "present/target-committed/remint-used"
                   , "present/cleanup-required/initial-attempt"
                   , "present/cleanup-required/remint-used"
                   , "present/cleanup-proven/initial-attempt"
                   , "present/cleanup-proven/remint-used"
                   , "present/complete"
                   , "present/permit-mismatch"
                   , "present/invalid"
                   , "unobservable/request/timeout"
                   ]
      map classifyAwsAdminRecoveryJournalObservation recoveryObservations
        `shouldBe` [ AwsAdminAttemptJournalAbsent
                   , AwsAdminAttemptJournalInitialIntentCommitted
                   , AwsAdminAttemptJournalCleanupContinuation
                       AwsAdminRecoveryIntentCommittedRemintUsed
                   , AwsAdminAttemptJournalCleanupContinuation
                       AwsAdminRecoveryCreateAttemptPreparedInitial
                   , AwsAdminAttemptJournalCleanupContinuation
                       AwsAdminRecoveryCreateAttemptPreparedRemintUsed
                   , AwsAdminAttemptJournalCleanupContinuation
                       AwsAdminRecoveryKeyCreatedInitial
                   , AwsAdminAttemptJournalCleanupContinuation
                       AwsAdminRecoveryKeyCreatedRemintUsed
                   , AwsAdminAttemptJournalPresent
                   , AwsAdminAttemptJournalPresent
                   , AwsAdminAttemptJournalCleanupContinuation
                       AwsAdminRecoveryCleanupRequiredInitial
                   , AwsAdminAttemptJournalCleanupContinuation
                       AwsAdminRecoveryCleanupRequiredRemintUsed
                   , AwsAdminAttemptJournalCleanupContinuation
                       AwsAdminRecoveryCleanupProvenInitial
                   , AwsAdminAttemptJournalCleanupContinuation
                       AwsAdminRecoveryCleanupProvenRemintUsed
                   , AwsAdminAttemptJournalPresent
                   , AwsAdminAttemptJournalPresent
                   , AwsAdminAttemptJournalPresent
                   , AwsAdminAttemptJournalUnobservable
                   ]

    it "Sprint 2.116 separates journal refusal before and after the worker action" $ do
      let privateDetails =
            [
              ( "HTTP 403 response: invalid token private-a"
              , AwsAdminWorkerJournalAuthenticationRejected
              )
            ,
              ( "HTTP 403 response: permission denied private-b"
              , AwsAdminWorkerJournalAuthorizationRejected
              )
            , ("HTTP 404 response: private-c", AwsAdminWorkerJournalNotFound)
            , ("HTTP timeout: private-d", AwsAdminWorkerJournalTimeout)
            , ("HTTP connection failure: private-e", AwsAdminWorkerJournalTransportFailed)
            , ("HTTP response decode error: private-f", AwsAdminWorkerJournalDecodeFailed)
            , ("service-session journal base64 is invalid", AwsAdminWorkerJournalInvalid)
            , ("private-g", AwsAdminWorkerJournalOther)
            ]
      map
        (\(detail, _) -> classifyAwsAdminWorkerJournalUnavailable AwsAdminWorkerActionNotStarted detail)
        privateDetails
        `shouldBe` fmap
          (AwsAdminWorkerSessionClosureAcquisitionJournalUnavailable . snd)
          privateDetails
      map
        (\(detail, _) -> classifyAwsAdminWorkerJournalUnavailable AwsAdminWorkerActionAttempted detail)
        privateDetails
        `shouldBe` fmap
          (AwsAdminWorkerSessionClosureFinalizationJournalUnavailable . snd)
          privateDetails

    it "Sprint 2.116 classifies worker receipt transport without values or byte counts" $ do
      let canonical = canonicalRevokedWorkerReceiptBytes
          envelope =
            encodeAwsAdminWorkerReceiptTextEnvelope
              (must (decodeAwsAdminWorkerReceipt canonical))
          classify =
            renderAwsAdminWorkerReceiptTransportObservation
              . classifyAwsAdminWorkerReceiptTransport
          prerequisiteCauseTokens =
            renderProductionIamErrorCause <$> allProductionIamErrorCauses
          targetObservationCauseTokens =
            ("target-observation-unobservable/" <>)
              . renderAwsAdminTargetObservationCause
              <$> allAwsAdminTargetObservationCauses
          targetDeliveryCauseTokens =
            renderAwsAdminTargetDeliveryCause <$> allAwsAdminTargetDeliveryCauses
          recoveryRemintCauseTokens =
            ("recovery-remint-ambiguous/" <>)
              . renderAwsAdminRecoveryRemintCause
              <$> allAwsAdminRecoveryRemintCauses
          executionCauseTokens =
            [ "unclassified"
            , "prepared-target-invalid"
            , "prepared-target-mismatch"
            , "prepare-target-failed"
            , "journal-unavailable"
            , "journal-permit-mismatch"
            , "journal-transition-rejected"
            , "journal-commit-failed"
            , "journal-read-back-mismatch"
            , "transition-limit-reached"
            ]
              <> fmap ("iam-prerequisite-failed/" <>) prerequisiteCauseTokens
              <> [ "inventory-unobservable"
                 , "inventory-over-bound"
                 , "install-requires-empty-inventory"
                 , "delete-key-failed"
                 , "create-key-failed"
                 , "created-key-not-read-back"
                 , "visibility-wait-failed"
                 , "stable-absence-not-proven"
                 ]
              <> recoveryRemintCauseTokens
              <> ["material-invalid"]
              <> fmap ("target-delivery-failed/" <>) targetDeliveryCauseTokens
              <> targetObservationCauseTokens
              <> [ "target-receipt-mismatch"
                 , "target-revocation-failed"
                 , "target-revocation-unobservable"
                 , "target-generation-still-present"
                 , "revocation-not-read-back"
                 , "identity-destroy-failed"
                 , "identity-absence-unobservable"
                 , "identity-still-present"
                 , "receipt-too-large"
                 , "receipt-decode-failed"
                 , "receipt-unsupported-version"
                 , "receipt-non-canonical"
                 , "receipt-invalid"
                 ]
      map
        renderAwsAdminWorkerReceiptCaptureSize
        ([minBound .. maxBound] :: [AwsAdminWorkerReceiptCaptureSize])
        `shouldBe` ["empty", "within-bound", "oversize"]
      map
        renderAwsAdminWorkerReceiptDecodeCause
        ([minBound .. maxBound] :: [AwsAdminWorkerReceiptDecodeCause])
        `shouldBe` [ "canonical"
                   , "too-large"
                   , "decode-failed"
                   , "unsupported-version"
                   , "non-canonical"
                   , "invalid"
                   ]
      map
        renderAwsAdminWorkerReceiptEnvelopeDecodeCause
        ([minBound .. maxBound] :: [AwsAdminWorkerReceiptEnvelopeDecodeCause])
        `shouldBe` ["canonical", "too-large", "invalid", "non-canonical"]
      map
        renderAwsAdminWorkerReceiptTerminalEnding
        ([minBound .. maxBound] :: [AwsAdminWorkerReceiptTerminalEnding])
        `shouldBe` ["absent", "lf", "crlf"]
      map
        renderAwsAdminWorkerReceiptLineTopology
        ([minBound .. maxBound] :: [AwsAdminWorkerReceiptLineTopology])
        `shouldBe` ["empty", "single", "multiple"]
      map
        renderAwsAdminWorkerReceiptEnvelopeLineDisposition
        ([minBound .. maxBound] :: [AwsAdminWorkerReceiptEnvelopeLineDisposition])
        `shouldBe` ["none", "unique", "ambiguous"]
      map
        renderAwsAdminWorkerReceiptPrefixLineDisposition
        ([minBound .. maxBound] :: [AwsAdminWorkerReceiptPrefixLineDisposition])
        `shouldBe` ["none", "unique", "ambiguous"]
      map
        renderAwsAdminWorkerExecutionCause
        allAwsAdminWorkerExecutionCauses
        `shouldBe` executionCauseTokens
      let sessionClosureCauseTokens =
            [ "binding-allocation-failed"
            , "auditor-login-failed"
            , "auditor-lease-insufficient"
            , "auditor-role-cleanup-failed"
            , "journal-commit-failed"
            , "binding-role-mismatch"
            , "role-occupied"
            , "binding-invalid"
            , "preclean/identity-invalid"
            , "preclean/observation-failed"
            , "preclean/classification-failed"
            , "preclean/visibility-wait-failed"
            , "preclean/stable-absence-failed"
            , "login-ambiguity-cleaned"
            , "cleanup/identity-invalid"
            , "cleanup/observation-failed"
            , "cleanup/classification-failed"
            , "cleanup/visibility-wait-failed"
            , "cleanup/stable-absence-failed"
            , "cleanup/threw"
            , "cleanup/journal-commit-failed"
            , "absence-unproven"
            ]
              <> fmap
                ("acquisition/journal-unavailable/" <>)
                journalCauseTokens
              <> fmap
                ("finalization/journal-unavailable/" <>)
                journalCauseTokens
          journalCauseTokens =
            renderAwsAdminWorkerJournalUnavailableCause
              <$> allAwsAdminWorkerJournalUnavailableCauses
      map
        renderAwsAdminWorkerSessionClosureCause
        allAwsAdminWorkerSessionClosureCauses
        `shouldBe` sessionClosureCauseTokens
      map
        renderAwsAdminWorkerTerminalCause
        allAwsAdminWorkerTerminalCauses
        `shouldBe` ( [ "delivery-composition-unavailable"
                     , "stdin-read-failed"
                     , "stdin-too-large"
                     , "frame-rejected"
                     , "pod-identity-read-failed"
                     , "pod-identity-invalid"
                     , "pod-identity-mismatch"
                     , "permit-metadata-mismatch"
                     , "mode-mismatch"
                     , "projected-identity-mismatch"
                     , "clock-unavailable"
                     , "vault-login-unavailable"
                     , "authority-key-unavailable"
                     , "permit-rejected"
                     , "iam-program-invalid"
                     , "iam-session-unavailable"
                     ]
                       <> fmap ("execution-failed/" <>) executionCauseTokens
                       <> fmap
                         ("session-revocation-failed/" <>)
                         sessionClosureCauseTokens
                       <> [ "completion-unavailable"
                          , "unhandled-exception"
                          ]
                   )
      classify canonical
        `shouldBe` "size=within-bound/raw=canonical/raw-envelope=invalid/terminal-ending=absent/without-terminal-ending=not-applicable/without-terminal-ending-envelope=not-applicable/line-topology=single/receipt-envelope-lines=none/receipt-prefix-lines=none/worker-terminal-line=none"
      classify ByteString.empty
        `shouldBe` "size=empty/raw=decode-failed/raw-envelope=invalid/terminal-ending=absent/without-terminal-ending=not-applicable/without-terminal-ending-envelope=not-applicable/line-topology=empty/receipt-envelope-lines=none/receipt-prefix-lines=none/worker-terminal-line=none"
      classify (ByteString.singleton 255)
        `shouldBe` "size=within-bound/raw=decode-failed/raw-envelope=invalid/terminal-ending=absent/without-terminal-ending=not-applicable/without-terminal-ending-envelope=not-applicable/line-topology=single/receipt-envelope-lines=none/receipt-prefix-lines=none/worker-terminal-line=none"
      classify (ByteString.replicate (64 * 1024) 0)
        `shouldBe` "size=oversize/raw=too-large/raw-envelope=too-large/terminal-ending=absent/without-terminal-ending=not-applicable/without-terminal-ending-envelope=not-applicable/line-topology=single/receipt-envelope-lines=none/receipt-prefix-lines=none/worker-terminal-line=none"
      classify (canonical <> "\n")
        `shouldBe` "size=within-bound/raw=non-canonical/raw-envelope=invalid/terminal-ending=lf/without-terminal-ending=canonical/without-terminal-ending-envelope=invalid/line-topology=single/receipt-envelope-lines=none/receipt-prefix-lines=none/worker-terminal-line=none"
      classify (canonical <> "\r\n")
        `shouldBe` "size=within-bound/raw=non-canonical/raw-envelope=invalid/terminal-ending=crlf/without-terminal-ending=canonical/without-terminal-ending-envelope=invalid/line-topology=single/receipt-envelope-lines=none/receipt-prefix-lines=none/worker-terminal-line=none"
      classify (canonical <> "x")
        `shouldBe` "size=within-bound/raw=non-canonical/raw-envelope=invalid/terminal-ending=absent/without-terminal-ending=not-applicable/without-terminal-ending-envelope=not-applicable/line-topology=single/receipt-envelope-lines=none/receipt-prefix-lines=none/worker-terminal-line=none"
      classify (wireWorkerReceiptFixtureBytes 2 2)
        `shouldBe` "size=within-bound/raw=unsupported-version/raw-envelope=invalid/terminal-ending=absent/without-terminal-ending=not-applicable/without-terminal-ending-envelope=not-applicable/line-topology=single/receipt-envelope-lines=none/receipt-prefix-lines=none/worker-terminal-line=none"
      classify (wireWorkerReceiptFixtureBytes 1 0)
        `shouldBe` "size=within-bound/raw=invalid/raw-envelope=invalid/terminal-ending=absent/without-terminal-ending=not-applicable/without-terminal-ending-envelope=not-applicable/line-topology=single/receipt-envelope-lines=none/receipt-prefix-lines=none/worker-terminal-line=none"
      let lineDispositionSuffix topology envelopeDisposition prefixDisposition terminalDisposition =
            Text.intercalate
              "/"
              [ "line-topology=" <> topology
              , "receipt-envelope-lines=" <> envelopeDisposition
              , "receipt-prefix-lines=" <> prefixDisposition
              , "worker-terminal-line=" <> terminalDisposition
              ]
      classify (envelope <> "\n")
        `shouldSatisfy` (Text.isSuffixOf (lineDispositionSuffix "single" "unique" "unique" "none"))
      classify ("diagnostic\n" <> envelope <> "\n")
        `shouldSatisfy` (Text.isSuffixOf (lineDispositionSuffix "multiple" "unique" "unique" "none"))
      classify (envelope <> "\n" <> envelope <> "\n")
        `shouldSatisfy` (Text.isSuffixOf (lineDispositionSuffix "multiple" "ambiguous" "ambiguous" "none"))
      classify "prodbox-aws-admin-worker-receipt-v1:not-base64\n"
        `shouldSatisfy` (Text.isSuffixOf (lineDispositionSuffix "single" "none" "unique" "none"))
      classify
        "AWS-admin credential worker refused: execution-failed/iam-prerequisite-failed/unclassified\n"
        `shouldSatisfy` ( Text.isSuffixOf
                            (lineDispositionSuffix "single" "none" "none" "execution-failed/iam-prerequisite-failed/unclassified")
                        )
      classify "AWS-admin credential worker refused: future-cause\n"
        `shouldSatisfy` (Text.isSuffixOf (lineDispositionSuffix "single" "none" "none" "unrecognized"))
      classify
        ( "AWS-admin credential worker refused: execution-failed/iam-prerequisite-failed/unclassified\n"
            <> "AWS-admin credential worker refused: permit-rejected\n"
        )
        `shouldSatisfy` (Text.isSuffixOf (lineDispositionSuffix "multiple" "none" "none" "ambiguous"))
      renderAwsAdminWorkerTerminalLineDisposition AwsAdminWorkerTerminalLineNone
        `shouldBe` "none"

    it "Sprint 2.116 removes payloads from closed worker execution causes" $ do
      let classifyExecution =
            renderAwsAdminWorkerExecutionCause . classifyAwsAdminExecutionError
      classifyExecution (AwsAdminExecutionJournalUnavailable "boundary-secret-a")
        `shouldBe` "journal-unavailable"
      classifyExecution (AwsAdminExecutionJournalUnavailable "boundary-secret-b")
        `shouldBe` "journal-unavailable"
      classifyExecution (AwsAdminIamPrerequisiteFailed ProductionIamErrorUnclassified)
        `shouldBe` "iam-prerequisite-failed/unclassified"
      classifyExecution (AwsAdminInventoryOverBound 99)
        `shouldBe` "inventory-over-bound"
      let deliveryCauseTokens =
            renderAwsAdminTargetDeliveryCause <$> allAwsAdminTargetDeliveryCauses
      length deliveryCauseTokens `shouldBe` length (nub deliveryCauseTokens)
      map renderAwsAdminRecoveryRemintCause allAwsAdminRecoveryRemintCauses
        `shouldBe` ( [ "journal-resumed"
                     , "intent-inventory-not-empty"
                     , "prepared-inventory-diverged"
                     , "create/dispatch-ambiguous"
                     , "create/lost-result"
                     , "created-key-predecessor-collision"
                     , "created-material-unavailable"
                     , "material-invalid"
                     ]
                       <> fmap ("target-delivery-failed/" <>) deliveryCauseTokens
                       <> [ "target-receipt-mismatch"
                          , "target-holds-predecessor-material"
                          ]
                   )
      classifyExecution
        (AwsAdminRecoveryRemintAmbiguous AwsAdminRecoveryRemintCreateDispatchAmbiguous)
        `shouldBe` "recovery-remint-ambiguous/create/dispatch-ambiguous"
      classifyExecution
        (AwsAdminRecoveryRemintAmbiguous AwsAdminRecoveryRemintCreateLostResult)
        `shouldBe` "recovery-remint-ambiguous/create/lost-result"
      classifyExecution (AwsAdminTargetDeliveryFailed AwsAdminTargetDeliveryPermitSubstitution)
        `shouldBe` "target-delivery-failed/permit-substitution"
      renderAwsAdminTargetIntentIssueCause
        (classifyTargetIntentIssueError (TargetIntentAuthorityUnavailable "prepared-intent-unavailable"))
        `shouldBe` "unavailable/prepared-intent"
      renderAwsAdminTargetIntentIssueCause
        (classifyTargetIntentIssueError (TargetIntentAuthorityUnavailable "private-detail-a"))
        `shouldBe` "unavailable/other"
      renderAwsAdminTargetIntentIssueCause
        (classifyTargetIntentIssueError (TargetIntentAuthorityUnavailable "private-detail-b"))
        `shouldBe` "unavailable/other"
      renderAwsAdminTargetWorkerCause
        (classifyTargetWorkerError (TargetWorkerCoordinatorCreateFailed "private-detail"))
        `shouldBe` "create-failed"
      let observationDetails =
            [ ("Target worker Job Pod is not observable", "pod-kubernetes-exit")
            , ("Kubernetes Target worker Pod-list response is invalid", "pod-list-invalid")
            , ("Target worker Job has multiple Pods", "multiple-pods")
            , ("Target worker Pod Job label mismatch", "job-label-mismatch")
            ,
              ( "Target worker Pod has no unique controlling Job UID"
              , "controlling-job-uid-invalid"
              )
            , ("Target worker container is missing", "container-missing")
            , ("Target worker declared image is empty", "declared-image-empty")
            , ("Target worker container status is missing", "container-status-missing")
            ,
              ( "Target worker runtime image identity is invalid"
              , "runtime-image-identity-invalid"
              )
            , ("Target worker image digest mismatch", "image-digest-mismatch")
            ,
              ( "Target worker Pod annotation mismatch: private-annotation-name"
              , "annotation-mismatch"
              )
            ,
              ( "Target worker ServiceAccount is not observable"
              , "service-account-kubernetes-exit"
              )
            ,
              ( "Kubernetes Target worker ServiceAccount response is invalid"
              , "service-account-response-invalid"
              )
            ,
              ( "Target worker ServiceAccount name mismatch"
              , "service-account-name-mismatch"
              )
            ,
              ( "Target worker ServiceAccount namespace mismatch"
              , "service-account-namespace-mismatch"
              )
            ,
              ( "Target worker ServiceAccount UID is invalid"
              , "service-account-uid-invalid"
              )
            , ("private-observation-detail", "other")
            ]
          classifyObservation =
            renderAwsAdminTargetWorkerObservationCause
              . classifyAwsAdminTargetWorkerObservationFailure
          observationTokens =
            renderAwsAdminTargetWorkerObservationCause
              <$> allAwsAdminTargetWorkerObservationCauses
      length observationTokens `shouldBe` length (nub observationTokens)
      (classifyObservation . fst <$> observationDetails)
        `shouldBe` (snd <$> observationDetails)
      classifyObservation "private-observation-detail-a" `shouldBe` "other"
      classifyObservation "private-observation-detail-b" `shouldBe` "other"
      renderAwsAdminTargetWorkerCause
        ( classifyTargetWorkerError
            (TargetWorkerCoordinatorObservationFailed "Target worker image digest mismatch")
        )
        `shouldBe` "observation-failed/image-digest-mismatch"
      renderAwsAdminTargetWorkerCause
        ( classifyTargetWorkerError
            ( TargetWorkerCoordinatorAgentIdentityUnavailable
                TargetAgentRolloutKubeconfigUnavailable
            )
        )
        `shouldBe` "agent-identity-unavailable/kubeconfig-unavailable"

    it "Sprint 2.116 classifies Target observation failures without payloads" $ do
      let causeTokens = renderTargetMaterialClientCause <$> allTargetMaterialClientCauses
          forbiddenWith detail =
            TargetMaterialClientTransportFailed
              ( AuthenticatedClientTransportFailed
                  (ControlPlaneTransportFailed (HttpStatus 403 detail))
              )
          classifyClient =
            renderTargetMaterialClientCause . classifyTargetMaterialClientError
      causeTokens `shouldSatisfy` (not . null)
      length causeTokens `shouldBe` length (nub causeTokens)
      classifyClient (forbiddenWith "target-response-secret-a")
        `shouldBe` "authenticated/transport/http/status/forbidden"
      classifyClient (forbiddenWith "target-response-secret-b")
        `shouldBe` "authenticated/transport/http/status/forbidden"
      classifyClient (TargetMaterialClientRemoteRefused "request-codec-rejected")
        `shouldBe` "remote-refusal/request-codec-rejected"
      classifyClient (TargetMaterialClientRemoteRefused "target-metadata-unavailable")
        `shouldBe` "remote-refusal/target-metadata-unavailable"
      classifyClient (TargetMaterialClientRemoteRefused "boundary-secret")
        `shouldBe` "remote-refusal/other"
      ( renderAwsAdminWorkerExecutionCause
          . classifyAwsAdminExecutionError
          $ AwsAdminTargetObservationUnobservable
            ( AwsAdminTargetObservationClient
                ( classifyTargetMaterialClientError
                    (forbiddenWith "worker-terminal-secret")
                )
            )
        )
        `shouldBe` "target-observation-unobservable/client/authenticated/transport/http/status/forbidden"

    it "Sprints 2.122 and 2.124 classify codec-invalid Target responses without payloads" $ do
      let statusCases =
            [ (400, "bad-request")
            , (401, "unauthorized")
            , (403, "forbidden")
            , (404, "not-found")
            , (409, "conflict")
            , (429, "too-many-requests")
            , (418, "other-client")
            , (500, "server/other")
            , (599, "server/other")
            , (0, "other")
            , (200, "other")
            , (600, "other")
            ]
          classifyInvalid status privateBody =
            case decodeTargetMaterialClientResponse
              (ControlPlaneResponse status privateBody) of
              Left err ->
                renderTargetMaterialClientCause
                  (classifyTargetMaterialClientError err)
              Right _ -> error "invalid Target response unexpectedly decoded"
      forM_ statusCases $ \(status, expected) ->
        classifyInvalid status "private-response-a"
          `shouldBe` ("response-codec/invalid/status/" <> expected)
      classifyInvalid 409 "private-response-a"
        `shouldBe` classifyInvalid 409 "different-private-response-b"
      renderTargetMaterialClientCause
        ( classifyTargetMaterialClientError
            (TargetMaterialClientResponseInvalid ControlPlaneRequestInvalid)
        )
        `shouldBe` "response-codec/invalid"

    it "Sprint 2.124 classifies only exact authenticated-role plaintext response pairs" $ do
      let observationTokens =
            renderAuthenticatedRolePlainResponseObservation
              <$> allAuthenticatedRolePlainResponseObservations
          classifyPair status body =
            classifyAuthenticatedRolePlainResponse (replyStatusCode status) body
          wrongStatus status
            | replyStatusCode status == 500 = 503
            | otherwise = 500
      length observationTokens `shouldBe` length (nub observationTokens)
      forM_ allAuthenticatedRolePlainResponseCauses $ \cause -> do
        let (status, body) = authenticatedRolePlainResponse cause
            known = AuthenticatedRolePlainResponseKnown cause
        classifyPair status body `shouldBe` known
        classifyAuthenticatedRolePlainResponse
          (wrongStatus status)
          body
          `shouldBe` AuthenticatedRolePlainResponseOther
        classifyPair status ("private-prefix" <> body)
          `shouldBe` AuthenticatedRolePlainResponseOther
        classifyPair status (body <> "private-suffix")
          `shouldBe` AuthenticatedRolePlainResponseOther
        let code = replyStatusCode status
        if code >= 500 && code < 600
          then case decodeTargetMaterialClientResponse
            (ControlPlaneResponse code body) of
            Left err ->
              renderTargetMaterialClientCause
                (classifyTargetMaterialClientError err)
                `shouldBe` ( "response-codec/invalid/status/server/"
                               <> renderAuthenticatedRolePlainResponseObservation known
                           )
            Right _ -> error "authenticated-role plaintext unexpectedly decoded"
          else pure ()
      classifyAuthenticatedRolePlainResponse 503 "private-server-response-a"
        `shouldBe` AuthenticatedRolePlainResponseOther
      classifyAuthenticatedRolePlainResponse 503 "different-private-server-response-b"
        `shouldBe` AuthenticatedRolePlainResponseOther

    it "Sprint 2.116 classifies Target trust installation without payloads" $ do
      let causeTokens =
            renderTargetAuthorityTrustBoundaryCause
              <$> allTargetAuthorityTrustBoundaryCauses
          observationTokens =
            renderTargetAuthorityTrustObservationCause
              <$> allTargetAuthorityTrustObservationCauses
          classifyTrust =
            renderTargetAuthorityTrustBoundaryCause
              . classifyTargetAuthorityTrustClientError
          classifyObservation =
            renderTargetAuthorityTrustObservationCause
              . classifyTargetAuthorityTrustObservationFailure
      causeTokens `shouldSatisfy` (not . null)
      length causeTokens `shouldBe` length (nub causeTokens)
      observationTokens `shouldSatisfy` (not . null)
      length observationTokens `shouldBe` length (nub observationTokens)
      classifyTrust
        (TargetAuthorityTrustClientUnavailable "trust-observation-unavailable")
        `shouldBe` "unavailable/observation/other"
      classifyTrust
        ( TargetAuthorityTrustClientUnavailable
            "trust-observation-unavailable/request/forbidden"
        )
        `shouldBe` "unavailable/observation/request/forbidden"
      classifyTrust
        ( TargetAuthorityTrustClientUnavailable
            "trust-observation-unavailable/private-detail"
        )
        `shouldBe` "unavailable/observation/other"
      classifyTrust
        (TargetAuthorityTrustClientUnavailable "trust-cas-unavailable")
        `shouldBe` "unavailable/cas"
      classifyTrust (TargetAuthorityTrustClientUnavailable "private-detail-a")
        `shouldBe` "unavailable/other"
      classifyTrust (TargetAuthorityTrustClientUnavailable "private-detail-b")
        `shouldBe` "unavailable/other"
      classifyTrust (TargetAuthorityTrustClientRefused "private-detail-a")
        `shouldBe` "refused/other"
      classifyTrust (TargetAuthorityTrustClientRefused "private-detail-b")
        `shouldBe` "refused/other"
      let classifyInvalidResponse status body =
            case decodeTargetAuthorityTrustClientResponse
              (ControlPlaneResponse status body) of
              Left err -> classifyTrust err
              Right _ -> error "invalid Target trust response unexpectedly decoded"
          (serverStatus, serverBody) =
            authenticatedRolePlainResponse AuthenticatedRoleReplayUnavailable
      classifyInvalidResponse 409 "private-client-response"
        `shouldBe` "client/response-codec/invalid/status/conflict"
      classifyInvalidResponse (replyStatusCode serverStatus) serverBody
        `shouldBe` "client/response-codec/invalid/status/server/replay-unavailable"
      classifyInvalidResponse (replyStatusCode serverStatus) "private-server-response"
        `shouldBe` "client/response-codec/invalid/status/server/other"
      classifyObservation
        (VaultSessionRequestFailed (HttpStatus 403 "private-vault-body-a"))
        `shouldBe` "request/forbidden"
      classifyObservation
        (VaultSessionRequestFailed (HttpStatus 403 "private-vault-body-b"))
        `shouldBe` "request/forbidden"
      classifyObservation
        ( VaultSessionAcquisitionFailed
            (VaultSessionForbidden "private-login-body")
        )
        `shouldBe` "session-acquisition/forbidden"
      renderAwsAdminTargetIntentIssueCause
        ( classifyTargetIntentIssueError
            ( TargetIntentAuthorityUnavailable
                "target-trust-install-unavailable/unavailable/observation/request/forbidden"
            )
        )
        `shouldBe` "unavailable/trust-install/unavailable/observation/request/forbidden"

    it "Sprint 2.116 removes payloads from exhaustive IAM prerequisite causes" $ do
      let operationTokens =
            renderProductionIamAwsOperationCause
              <$> ([minBound .. maxBound] :: [ProductionIamAwsOperationCause])
          clientTokens =
            renderProductionIamAwsClientCause
              <$> ([minBound .. maxBound] :: [ProductionIamAwsClientCause])
          causeTokens = renderProductionIamErrorCause <$> allProductionIamErrorCauses
      operationTokens
        `shouldBe` [ "observe-lifecycle-role"
                   , "create-lifecycle-role"
                   , "update-lifecycle-role-trust"
                   , "read-back-lifecycle-role"
                   , "install-lifecycle-role-policy"
                   , "read-back-lifecycle-role-policy"
                   , "observe-required-bucket"
                   , "observe-bucket"
                   , "create-long-lived-bucket"
                   , "read-back-created-bucket"
                   , "harden-bucket"
                   , "read-back-bucket-hardening"
                   , "tag-user"
                   , "read-back-user-tags"
                   , "observe-user"
                   , "observe-raced-user"
                   , "create-iam-user"
                   , "install-user-policy"
                   , "read-back-user-policy"
                   , "unknown"
                   ]
      clientTokens
        `shouldBe` [ "signing-failure"
                   , "transport-failure"
                   , "service/access-denied"
                   , "service/invalid-client-token"
                   , "service/signature-mismatch"
                   , "service/expired-token"
                   , "service/invalid-token"
                   , "service/no-such-entity"
                   , "service/entity-already-exists"
                   , "service/concurrent-modification"
                   , "service/invalid-input"
                   , "service/limit-exceeded"
                   , "service/malformed-policy-document"
                   , "service/throttled"
                   , "service/other-client"
                   , "service/server"
                   , "service/unexpected-status"
                   , "response-parse-failure"
                   , "ambiguous/dispatch"
                   , "ambiguous/lost-result"
                   ]
      nub causeTokens `shouldBe` causeTokens
      classifyProductionIamError
        (ProductionIamAwsFailed "observe IAM user" (AwsTransportError "secret-a"))
        `shouldBe` classifyProductionIamError
          (ProductionIamAwsFailed "observe IAM user" (AwsTransportError "secret-b"))
      renderProductionIamErrorCause
        ( classifyProductionIamError
            (ProductionIamAwsFailed "observe IAM user" (AwsTransportError "secret-a"))
        )
        `shouldBe` "aws/observe-user/transport-failure"
      let invalidTokenFault message requestId =
            AwsServiceFault
              { awsFaultHttpStatus = 403
              , awsFaultCode = "InvalidClientTokenId"
              , awsFaultMessage = message
              , awsFaultRequestId = requestId
              }
      classifyProductionIamError
        ( ProductionIamAwsFailed
            "observe IAM user"
            (AwsServiceError (invalidTokenFault "secret-a" (Just "request-a")))
        )
        `shouldBe` classifyProductionIamError
          ( ProductionIamAwsFailed
              "observe IAM user"
              (AwsServiceError (invalidTokenFault "secret-b" (Just "request-b")))
          )
      renderProductionIamErrorCause
        ( classifyProductionIamError
            ( ProductionIamAwsFailed
                "observe IAM user"
                (AwsServiceError (invalidTokenFault "secret-a" (Just "request-a")))
            )
        )
        `shouldBe` "aws/observe-user/service/invalid-client-token"
      renderProductionIamErrorCause
        ( classifyProductionIamError
            ( ProductionIamAwsFailed
                "unregistered stage"
                (AwsServiceError (AwsServiceFault 418 "UnknownClientFault" "secret" Nothing))
            )
        )
        `shouldBe` "aws/unknown/service/other-client"

    it "Sprint 2.118 classifies only documented CreateRole client faults" $ do
      let documentedCreateRoleClientFaults =
            [ (409, "ConcurrentModification", "service/concurrent-modification")
            , (400, "InvalidInput", "service/invalid-input")
            , (409, "LimitExceeded", "service/limit-exceeded")
            , (400, "MalformedPolicyDocument", "service/malformed-policy-document")
            ]
      forM_ documentedCreateRoleClientFaults $ \(status, code, expectedToken) -> do
        let createRoleFault message requestId =
              ProductionIamAwsFailed
                "create Lifecycle-provider role"
                ( AwsServiceError
                    AwsServiceFault
                      { awsFaultHttpStatus = status
                      , awsFaultCode = code
                      , awsFaultMessage = message
                      , awsFaultRequestId = requestId
                      }
                )
        classifyProductionIamError (createRoleFault "secret-a" (Just "request-a"))
          `shouldBe` classifyProductionIamError
            (createRoleFault "secret-b" (Just "request-b"))
        renderProductionIamErrorCause
          (classifyProductionIamError (createRoleFault "secret-a" (Just "request-a")))
          `shouldBe` ("aws/create-lifecycle-role/" <> expectedToken)

    it "Sprint 2.119 classifies every role read-back mismatch without values" $ do
      let causes = allProductionIamRoleReadBackCauses
          tokens = renderProductionIamRoleReadBackCause <$> causes
      tokens
        `shouldBe` [ "absent"
                   , "name-mismatch"
                   , "arn-mismatch"
                   , "trust-policy-mismatch/invalid"
                   , "trust-policy-mismatch/iam-singleton-equivalent"
                   , "trust-policy-mismatch/other"
                   ]
      nub tokens `shouldBe` tokens
      ( renderProductionIamErrorCause
          . classifyProductionIamError
          . ProductionIamRoleReadBackMismatch
          <$> causes
        )
        `shouldBe` (("role-read-back-mismatch/" <>) <$> tokens)

    it "Sprint 2.120 classifies only IAM singleton policy shapes" $ do
      let mismatchCauses = [minBound .. maxBound] :: [ProductionIamTrustPolicyMismatchCause]
          mismatchTokens = renderProductionIamTrustPolicyMismatchCause <$> mismatchCauses
          authoredA =
            "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"private-a\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::111111111111:user/private-a\"},\"Action\":[\"sts:AssumeRole\"]}]}"
          observedA =
            "{\"Version\":\"2012-10-17\",\"Statement\":{\"Sid\":\"private-a\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":[\"arn:aws:iam::111111111111:user/private-a\"]},\"Action\":\"sts:AssumeRole\"}}"
          authoredB =
            "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"private-b\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::222222222222:user/private-b\"},\"Action\":[\"sts:AssumeRole\"]}]}"
          observedB =
            "{\"Version\":\"2012-10-17\",\"Statement\":{\"Sid\":\"private-b\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":[\"arn:aws:iam::222222222222:user/private-b\"]},\"Action\":\"sts:AssumeRole\"}}"
      mismatchTokens `shouldBe` ["invalid", "iam-singleton-equivalent", "other"]
      nub mismatchTokens `shouldBe` mismatchTokens
      classifyProductionIamTrustPolicyMismatch observedA authoredA
        `shouldBe` ProductionIamTrustPolicyIamSingletonEquivalent
      classifyProductionIamTrustPolicyMismatch observedB authoredB
        `shouldBe` ProductionIamTrustPolicyIamSingletonEquivalent
      classifyProductionIamTrustPolicyMismatch "not-json-a" authoredA
        `shouldBe` classifyProductionIamTrustPolicyMismatch "not-json-b" authoredB
      classifyProductionIamTrustPolicyMismatch
        (Text.replace "sts:AssumeRole" "sts:TagSession" observedA)
        authoredA
        `shouldBe` ProductionIamTrustPolicyOther

    it "Sprint 2.121 admits only documented IAM singleton trust-policy forms" $ do
      let authored =
            "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"private-a\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::111111111111:user/private-a\"},\"Action\":[\"sts:AssumeRole\"]}]}"
          actionSingleton =
            "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"private-a\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::111111111111:user/private-a\"},\"Action\":\"sts:AssumeRole\"}]}"
          statementSingleton =
            "{\"Version\":\"2012-10-17\",\"Statement\":{\"Sid\":\"private-a\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::111111111111:user/private-a\"},\"Action\":[\"sts:AssumeRole\"]}}"
          principalSingleton =
            "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"private-a\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":[\"arn:aws:iam::111111111111:user/private-a\"]},\"Action\":[\"sts:AssumeRole\"]}]}"
          mixedSingletons =
            "{\"Version\":\"2012-10-17\",\"Statement\":{\"Sid\":\"private-a\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":[\"arn:aws:iam::111111111111:user/private-a\"]},\"Action\":\"sts:AssumeRole\"}}"
          refused =
            [ "not-json"
            , Text.replace "sts:AssumeRole" "sts:TagSession" actionSingleton
            , Text.replace "111111111111" "222222222222" principalSingleton
            , "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
            , Text.replace "2012-10-17" "2008-10-17" authored
            , "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"private-a\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::111111111111:user/private-a\"},\"Action\":[\"sts:AssumeRole\"]}],\"PrivateExtra\":true}"
            ]
      forM_
        [authored, actionSingleton, statementSingleton, principalSingleton, mixedSingletons]
        (\observed -> trustPoliciesEqual observed authored `shouldBe` True)
      forM_ refused (\observed -> trustPoliciesEqual observed authored `shouldBe` False)

    it "Sprint 2.116 reads the exact Pod log only after a successful empty attach" $ do
      fallbackEvents <- newIORef ([] :: [Text])
      let canonical = canonicalRevokedWorkerReceiptBytes
          fallback result = do
            modifyIORef' fallbackEvents (<> ["pod-log"])
            pure result
      map
        renderAwsAdminWorkerReceiptCaptureSource
        ([minBound .. maxBound] :: [AwsAdminWorkerReceiptCaptureSource])
        `shouldBe` ["attach", "pod-log"]
      recoverEmptyAwsAdminWorkerReceiptCaptureWith
        canonical
        (fallback (Just "must-not-replace"))
        `shouldReturn` (minBound, canonical)
      readIORef fallbackEvents `shouldReturn` []
      recoverEmptyAwsAdminWorkerReceiptCaptureWith
        ByteString.empty
        (fallback (Just canonical))
        `shouldReturn` (maxBound, canonical)
      recoverEmptyAwsAdminWorkerReceiptCaptureWith
        ByteString.empty
        (fallback Nothing)
        `shouldReturn` (minBound, ByteString.empty)
      readIORef fallbackEvents `shouldReturn` ["pod-log", "pod-log"]

    it "Sprint 2.116 admits only exact source-specific text envelopes after the live log failure" $ do
      let canonical = canonicalRevokedWorkerReceiptBytes
          envelope =
            encodeAwsAdminWorkerReceiptTextEnvelope
              (must (decodeAwsAdminWorkerReceipt canonical))
      decodeAwsAdminWorkerReceiptTextEnvelope envelope `shouldBe` Right canonical
      decodeAwsAdminWorkerReceiptTextEnvelope ByteString.empty
        `shouldBe` Left AwsAdminWorkerReceiptEnvelopeDecodeInvalid
      decodeAwsAdminWorkerReceiptCapture minBound canonical `shouldBe` Nothing
      decodeAwsAdminWorkerReceiptCapture minBound envelope `shouldBe` Nothing
      decodeAwsAdminWorkerReceiptCapture minBound ("\n" <> envelope) `shouldBe` Just canonical
      decodeAwsAdminWorkerReceiptCapture minBound (envelope <> "\n") `shouldBe` Nothing
      decodeAwsAdminWorkerReceiptCapture maxBound (envelope <> "\n") `shouldBe` Just canonical
      decodeAwsAdminWorkerReceiptCapture maxBound ("diagnostic" <> envelope <> "\n")
        `shouldBe` Nothing
      decodeAwsAdminWorkerReceiptCapture maxBound ("diagnostic\n" <> envelope <> "\n")
        `shouldBe` Just canonical
      decodeAwsAdminWorkerReceiptCapture maxBound (envelope <> "\n" <> envelope <> "\n")
        `shouldBe` Nothing
      decodeAwsAdminWorkerReceiptCapture maxBound envelope `shouldBe` Nothing
      decodeAwsAdminWorkerReceiptCapture maxBound (envelope <> "\r\n") `shouldBe` Nothing
      decodeAwsAdminWorkerReceiptCapture maxBound (envelope <> "\n\n") `shouldBe` Nothing
      decodeAwsAdminWorkerReceiptCapture maxBound (canonical <> "\n") `shouldBe` Nothing

    it
      "Sprint 2.116 admits only exact no-effect or pre-target cleanup continuations for an expired Authorized attempt"
      $ do
        let retained = renewalIntentAt renewalOldDeadline imageDigest targetAgent "home"
            prepared = AwsAdminAuthorityPrepared retained
            attested = must (commitAwsAdminAttested (renewalJobBinding retained) prepared)
        permit <- authorizedPermitFor retained
        let authorized = AwsAdminAuthorityAuthorized permit
            proveAt now state job pod journal =
              proveAwsAdminAuthorizedRecovery now state job pod journal
            isProof = either (const False) (const True)
            cleanupObservations =
              AwsAdminAttemptJournalCleanupContinuation <$> [minBound .. maxBound]
            admissibleJournals =
              [ AwsAdminAttemptJournalAbsent
              , AwsAdminAttemptJournalInitialIntentCommitted
              ]
                <> cleanupObservations
            refusedJournals =
              [ AwsAdminAttemptJournalPresent
              , AwsAdminAttemptJournalUnobservable
              ]
        forM_
          admissibleJournals
          ( \journal ->
              proveAt
                renewalNow
                authorized
                AwsAdminAttemptResourceAbsent
                AwsAdminAttemptResourceAbsent
                journal
                `shouldSatisfy` isProof
          )
        forM_
          [ (job, pod, journal)
          | job <- [minBound .. maxBound]
          , pod <- [minBound .. maxBound]
          , journal <- admissibleJournals <> refusedJournals
          , job /= AwsAdminAttemptResourceAbsent
              || pod /= AwsAdminAttemptResourceAbsent
              || journal `elem` refusedJournals
          ]
          ( \(job, pod, journal) ->
              proveAt renewalNow authorized job pod journal
                `shouldSatisfy` either (const True) (const False)
          )
        proveAt
          (authorityTimeFromMicros 5000000)
          authorized
          AwsAdminAttemptResourceAbsent
          AwsAdminAttemptResourceAbsent
          AwsAdminAttemptJournalAbsent
          `shouldBe` Left AwsAdminAuthorizedRecoveryDeadlineActive
        forM_
          [ initialAwsAdminAuthorityState
          , prepared
          , attested
          ]
          ( \state ->
              proveAt
                renewalNow
                state
                AwsAdminAttemptResourceAbsent
                AwsAdminAttemptResourceAbsent
                AwsAdminAttemptJournalAbsent
                `shouldBe` Left AwsAdminAuthorizedRecoveryNotAuthorized
          )
        classifyAwsAdminAttemptResourceHttpStatus 404
          `shouldBe` AwsAdminAttemptResourceAbsent
        classifyAwsAdminAttemptResourceHttpStatus 200
          `shouldBe` AwsAdminAttemptResourcePresent
        forM_ [0, 201, 401, 403, 500] $ \status ->
          classifyAwsAdminAttemptResourceHttpStatus status
            `shouldBe` AwsAdminAttemptResourceUnobservable

    it
      "FIRST-RECONCILE-DETERMINISTIC-IDENTITY-NONEMPTY-INVENTORY-2026-09-07 scopes initial cleanup to plan ownership"
      $ do
        let digest = must (mkTargetValueDigest (Text.replicate 64 "a"))
            genesis = GenesisBackupKind digest
        [ decideAwsAdminInstallInventory
            genesis
            AwsAdminInstallWithFirstReconcileBinding
            AwsAdminInstallInitialAttempt
            AwsAdminInstallInventoryNonempty
          , decideAwsAdminInstallInventory
              NormalOperatorMaterialKind
              AwsAdminInstallWithoutPlanBinding
              AwsAdminInstallInitialAttempt
              AwsAdminInstallInventoryNonempty
          , decideAwsAdminInstallInventory
              NormalOperatorMaterialKind
              AwsAdminInstallWithFirstReconcileBinding
              AwsAdminInstallInitialAttempt
              AwsAdminInstallInventoryNonempty
          , decideAwsAdminInstallInventory
              NormalOperatorMaterialKind
              AwsAdminInstallWithFirstReconcileBinding
              AwsAdminInstallRemintAttempt
              AwsAdminInstallInventoryNonempty
          , decideAwsAdminInstallInventory
              genesis
              AwsAdminInstallWithFirstReconcileBinding
              AwsAdminInstallInitialAttempt
              AwsAdminInstallInventoryEmpty
          ]
          `shouldBe` [ AwsAdminInstallRequireCleanup
                     , AwsAdminInstallRefuseNonempty
                     , AwsAdminInstallRequireCleanup
                     , AwsAdminInstallRefuseRemint
                     , AwsAdminInstallProceed
                     ]

    it "Sprint 2.116 binds cleanup continuation to its predecessor and starts before remint" $ do
      let retained = renewalIntentAt renewalOldDeadline imageDigest targetAgent "home"
          replacement =
            renewalIntentAt renewalNewDeadline otherImageDigest renewalTargetAgent "home"
          canonicalizeAt activeDeadline selectedAgent intent =
            must
              ( bindAwsAdminPermitIntentPreparedTarget
                  Nothing
                  (Just renewalPlanBinding)
                  activeDeadline
                  "owner-nonce-1"
                  1
                  selectedAgent
                  intent
              )
          canonicalize = canonicalizeAt renewalNewDeadline renewalTargetAgent
      predecessorPermit <- authorizedPermitFor retained
      let authorized = AwsAdminAuthorityAuthorized predecessorPermit
          cleanupProof =
            must
              ( proveAwsAdminAuthorizedRecovery
                  renewalNow
                  authorized
                  AwsAdminAttemptResourceAbsent
                  AwsAdminAttemptResourceAbsent
                  ( AwsAdminAttemptJournalCleanupContinuation
                      AwsAdminRecoveryKeyCreatedRemintUsed
                  )
              )
          noEffectProof =
            must
              ( proveAwsAdminAuthorizedRecovery
                  renewalNow
                  authorized
                  AwsAdminAttemptResourceAbsent
                  AwsAdminAttemptResourceAbsent
                  AwsAdminAttemptJournalInitialIntentCommitted
              )
          cleanupIntent =
            canonicalize
              (must (bindAwsAdminAuthorizedRecoveryIntent cleanupProof replacement))
          bogusIntent =
            canonicalize
              ( must
                  ( bindAwsAdminPermitIntentCleanupRecovery
                      (awsAdminPermitIntentKind retained)
                      (must (mkTargetValueDigest (Text.replicate 64 "e")))
                      replacement
                  )
              )
          nextDeadline = authorityTimeFromMicros 60000000
          nextCleanupIntent =
            canonicalizeAt
              nextDeadline
              targetAgent
              ( must
                  ( bindAwsAdminAuthorizedRecoveryIntent
                      cleanupProof
                      (renewalIntentAt nextDeadline imageDigest targetAgent "home")
                  )
              )
          afterCleanupOutboxExpiry = authorityTimeFromMicros 50000000
      awsAdminPermitIntentCleanupPredecessor cleanupIntent
        `shouldSatisfy` maybe False (const True)
      commitAwsAdminPreparedAuthorizedRecovery cleanupProof cleanupIntent authorized
        `shouldBe` Right (AwsAdminAuthorityPrepared cleanupIntent)
      commitAwsAdminPreparedAuthorizedRecovery cleanupProof replacement authorized
        `shouldBe` Left AwsAdminAuthorityRenewalBindingMismatch
      commitAwsAdminPreparedAuthorizedRecovery noEffectProof cleanupIntent authorized
        `shouldBe` Left AwsAdminAuthorityRenewalBindingMismatch
      bindAwsAdminPreparedRenewalIntent cleanupIntent bogusIntent
        `shouldBe` Left
          (AwsAdminAuthorityIntentInvalid AwsAdminPermitKindMismatch)
      decideAwsAdminPreparedTargetOutbox
        (Just (afterCleanupOutboxExpiry, retained))
        nextCleanupIntent
        (must (mkPreparedCredentialTargetOutbox cleanupIntent))
        `shouldBe` AwsAdminPreparedTargetOutboxReplace
      decideAwsAdminPreparedTargetOutbox
        (Just (afterCleanupOutboxExpiry, retained))
        nextCleanupIntent
        (must (mkPreparedCredentialTargetOutbox bogusIntent))
        `shouldBe` AwsAdminPreparedTargetOutboxReject
      cleanupPermit <- authorizedPermitFor cleanupIntent
      let initialJournal = initialAwsAdminExecutionJournal cleanupPermit
      awsAdminExecutionJournalPhase initialJournal
        `shouldBe` AwsAdminExecutionCleanupRequired False
      stepAwsAdminExecutionJournal RestartAwsAdminAfterCleanup initialJournal
        `shouldBe` Left AwsAdminExecutionTransitionRefused
      let cleanupProven =
            must
              ( stepAwsAdminExecutionJournal
                  (CommitAwsAdminStableCleanup False)
                  initialJournal
              )
          restarted =
            must
              ( stepAwsAdminExecutionJournal
                  RestartAwsAdminAfterCleanup
                  cleanupProven
              )
      awsAdminExecutionJournalPhase cleanupProven
        `shouldBe` AwsAdminExecutionCleanupProven False
      awsAdminExecutionJournalPhase restarted
        `shouldBe` AwsAdminExecutionIntentCommitted True

    it
      "FIRST-RECONCILE-DETERMINISTIC-IDENTITY-NONEMPTY-INVENTORY-2026-09-07 admits only exact plan-bound initial cleanup"
      $ do
        let genesisPlan = GenesisPlan "genesis-plan-digest" "authority-backup-store/home"
            retainedFirstPlan = defaultFirstReconcileProvisioningPlan renewalOldDeadline
            retainedMember = case firstReconcilePlanMembers retainedFirstPlan of
              member : _ -> member
              [] -> error "compiled first-reconcile plan has no genesis member"
            retainedPlanBinding =
              mkFirstReconcilePermitBinding
                (firstReconcilePlanDigest retainedFirstPlan)
                (firstReconcilePlanMemberIndex retainedMember)
                (firstReconcilePlanMemberDigest retainedMember)
                Nothing
            canonicalize activeDeadline selectedAgent intent =
              must
                ( bindAwsAdminPermitIntentPreparedTarget
                    (Just (genesisPlan, retainedMember))
                    (Just retainedPlanBinding)
                    activeDeadline
                    "owner-nonce-1"
                    1
                    selectedAgent
                    intent
                )
            genesisIntentAt activeDeadline selectedAgent =
              canonicalize activeDeadline selectedAgent rawIntent
             where
              callerPlan = defaultFirstReconcileProvisioningPlan activeDeadline
              genesisPermit =
                must
                  ( mkGenesisBackupPermit
                      genesisPlan
                      callerPlan
                      (initialFirstReconcileCursor callerPlan)
                      (must (mkOperatorMaterialPermitId "permit-authority-test"))
                      (must (mkOperatorMaterialOperationId operationId))
                      generation
                      activeDeadline
                      "operator-signature"
                  )
              rawIntent =
                withGenesisBackupOperatorPermit genesisPermit $ \genesisOperatorPermit ->
                  let prepared =
                        must
                          ( mkPreparedCredentialTargetObservation
                              "owner-nonce-1"
                              1
                              selectedAgent
                              (TargetAwsCredential AwsAuthorityBackupStore)
                              generation
                              (operatorMaterialPermitRequestDigest genesisOperatorPermit)
                              receiptDigest
                              (operatorMaterialPermitPlanBinding genesisOperatorPermit)
                              activeDeadline
                          )
                   in must
                        ( mkGenesisAwsAdminPermitIntent
                            genesisPermit
                            ( must
                                ( mkAuthorityBackupIamParameters
                                    (fixtureAwsRegion FixtureUsWest2)
                                    "prodbox-retained"
                                    ["authority-backup-store/home"]
                                )
                            )
                            imageDigest
                            "home"
                            "http://lifecycle-authority.lifecycle-authority.svc:8600"
                            prepared
                        )
            retained = genesisIntentAt renewalOldDeadline targetAgent
            replacement = genesisIntentAt renewalNewDeadline renewalTargetAgent
        predecessorPermit <- authorizedPermitFor retained
        normalPermit <-
          authorizedPermitFor
            (renewalIntentAt renewalOldDeadline imageDigest targetAgent "home")
        unboundNormalPermit <-
          authorizedPermitFor
            (postFirstReconcileRenewalIntentAt renewalOldDeadline imageDigest targetAgent "home")
        let genesisJournal = initialAwsAdminExecutionJournal predecessorPermit
            normalJournal = initialAwsAdminExecutionJournal normalPermit
            unboundNormalJournal = initialAwsAdminExecutionJournal unboundNormalPermit
            genesisCleanup =
              stepAwsAdminExecutionJournal
                (RequireAwsAdminStableCleanup False)
                genesisJournal
        (awsAdminExecutionJournalPhase <$> genesisCleanup)
          `shouldBe` Right (AwsAdminExecutionCleanupRequired False)
        ( awsAdminExecutionJournalPhase
            <$> stepAwsAdminExecutionJournal
              (RequireAwsAdminStableCleanup False)
              normalJournal
          )
          `shouldBe` Right (AwsAdminExecutionCleanupRequired False)
        stepAwsAdminExecutionJournal
          (RequireAwsAdminStableCleanup False)
          unboundNormalJournal
          `shouldBe` Left AwsAdminExecutionTransitionRefused
        stepAwsAdminExecutionJournal
          (RequireAwsAdminStableCleanup True)
          genesisJournal
          `shouldBe` Left AwsAdminExecutionTransitionRefused
        let authorized = AwsAdminAuthorityAuthorized predecessorPermit
            cleanupProof =
              must
                ( proveAwsAdminAuthorizedRecovery
                    renewalNow
                    authorized
                    AwsAdminAttemptResourceAbsent
                    AwsAdminAttemptResourceAbsent
                    ( AwsAdminAttemptJournalCleanupContinuation
                        AwsAdminRecoveryKeyCreatedRemintUsed
                    )
                )
            noEffectProof =
              must
                ( proveAwsAdminAuthorizedRecovery
                    renewalNow
                    authorized
                    AwsAdminAttemptResourceAbsent
                    AwsAdminAttemptResourceAbsent
                    AwsAdminAttemptJournalAbsent
                )
            cleanupIntent =
              canonicalize
                renewalNewDeadline
                renewalTargetAgent
                (must (bindAwsAdminAuthorizedRecoveryIntent cleanupProof replacement))
            cleanupIsGenesis = case awsAdminPermitIntentKind cleanupIntent of
              CleanupRecoveryKind (GenesisBackupCleanupProgram _) _ -> True
              _ -> False
        cleanupIsGenesis `shouldBe` True
        awsAdminGenesisKindMatches genesisPlan retainedMember cleanupIntent `shouldBe` True
        bindAwsAdminAuthorizedRecoveryIntent noEffectProof replacement
          `shouldBe` Right replacement
        commitAwsAdminPreparedAuthorizedRecovery cleanupProof cleanupIntent authorized
          `shouldBe` Right (AwsAdminAuthorityPrepared cleanupIntent)
        cleanupPermit <- authorizedPermitFor cleanupIntent
        let cleanupPermitRoundTrips =
              case decodeSignedAwsAdminPermit (encodeSignedAwsAdminPermit cleanupPermit) of
                Left _ -> False
                Right somePermit -> withSomeSignedAwsAdminPermit somePermit (== cleanupPermit)
        cleanupPermitRoundTrips `shouldBe` True
        awsAdminExecutionJournalPhase (initialAwsAdminExecutionJournal cleanupPermit)
          `shouldBe` AwsAdminExecutionCleanupRequired False

    it "Sprint 2.115 preserves outbox-before-state order and exact CAS response-loss recovery" $ do
      let retained = renewalIntentAt renewalOldDeadline imageDigest targetAgent "home"
          replacement =
            renewalIntentAt renewalNewDeadline otherImageDigest renewalTargetAgent "home"
          drifted =
            renewalIntentAt renewalNewDeadline otherImageDigest renewalTargetAgent "other-home"
      permit <- authorizedPermitFor retained
      let authorized = AwsAdminAuthorityAuthorized permit
          proof =
            must
              ( proveAwsAdminAuthorizedRecovery
                  renewalNow
                  authorized
                  AwsAdminAttemptResourceAbsent
                  AwsAdminAttemptResourceAbsent
                  AwsAdminAttemptJournalAbsent
              )
          intentProof =
            must
              ( proveAwsAdminAuthorizedRecovery
                  renewalNow
                  authorized
                  AwsAdminAttemptResourceAbsent
                  AwsAdminAttemptResourceAbsent
                  AwsAdminAttemptJournalInitialIntentCommitted
              )
      commitAwsAdminPreparedAuthorizedRecovery proof replacement authorized
        `shouldBe` Right (AwsAdminAuthorityPrepared replacement)
      commitAwsAdminPreparedAuthorizedRecovery intentProof replacement authorized
        `shouldBe` Right (AwsAdminAuthorityPrepared replacement)
      commitAwsAdminPreparedAuthorizedRecovery
        proof
        replacement
        (AwsAdminAuthorityPrepared replacement)
        `shouldBe` Right (AwsAdminAuthorityPrepared replacement)
      commitAwsAdminPreparedAuthorizedRecovery proof drifted authorized
        `shouldBe` Left AwsAdminAuthorityRenewalBindingMismatch
      events <- newIORef []
      stateRef <- newIORef (0 :: Int, authorized)
      let repository = renewalRepository events stateRef
          boundary =
            AwsAdminPreparedTargetBoundary $ \intent -> do
              modifyIORef' events (<> ["outbox-readback"])
              pure (Right (awsAdminPermitIntentPreparedTarget intent))
      prepareAwsAdminAuthorityAuthorizedRecovery
        repository
        boundary
        proof
        replacement
        `shouldReturn` Right (AwsAdminAuthorityPrepared replacement)
      readIORef events `shouldReturn` ["outbox-readback", "state-cas"]
      (snd <$> readIORef stateRef)
        `shouldReturn` AwsAdminAuthorityPrepared replacement

    it "AWS-ADMIN-AUTHORIZED-CLEANUP-PROVEN-STATE-TRANSITION-REJECTED-2026-09-06" $ do
      let retained =
            postFirstReconcileRenewalIntentAt
              renewalOldDeadline
              imageDigest
              targetAgent
              "home"
          replacement =
            postFirstReconcileRenewalIntentAt
              renewalNewDeadline
              otherImageDigest
              renewalTargetAgent
              "home"
          canonicalizeWithoutPlanBinding intent =
            must
              ( bindAwsAdminPermitIntentPreparedTarget
                  Nothing
                  Nothing
                  renewalNewDeadline
                  "owner-nonce-1"
                  1
                  renewalTargetAgent
                  intent
              )
      predecessorPermit <- authorizedPermitFor retained
      let authorized = AwsAdminAuthorityAuthorized predecessorPermit
          cleanupProof =
            must
              ( proveAwsAdminAuthorizedRecovery
                  renewalNow
                  authorized
                  AwsAdminAttemptResourceAbsent
                  AwsAdminAttemptResourceAbsent
                  ( AwsAdminAttemptJournalCleanupContinuation
                      AwsAdminRecoveryCleanupProvenRemintUsed
                  )
              )
          cleanupIntent =
            canonicalizeWithoutPlanBinding
              (must (bindAwsAdminAuthorizedRecoveryIntent cleanupProof replacement))
      awsAdminPermitIntentPlanBinding retained `shouldBe` Nothing
      awsAdminPermitIntentPlanBinding cleanupIntent `shouldBe` Nothing
      commitAwsAdminPreparedAuthorizedRecovery cleanupProof cleanupIntent authorized
        `shouldBe` Right (AwsAdminAuthorityPrepared cleanupIntent)
      events <- newIORef []
      stateRef <- newIORef (0 :: Int, authorized)
      let repository = renewalRepository events stateRef
          boundary =
            AwsAdminPreparedTargetBoundary $ \intent -> do
              modifyIORef' events (<> ["outbox-readback"])
              pure (Right (awsAdminPermitIntentPreparedTarget intent))
      prepareAwsAdminAuthorityAuthorizedRecovery
        repository
        boundary
        cleanupProof
        cleanupIntent
        `shouldReturn` Right (AwsAdminAuthorityPrepared cleanupIntent)
      readIORef events `shouldReturn` ["outbox-readback", "state-cas"]
      (snd <$> readIORef stateRef)
        `shouldReturn` AwsAdminAuthorityPrepared cleanupIntent

      firstReconcilePermit <-
        authorizedPermitFor
          (renewalIntentAt renewalOldDeadline imageDigest targetAgent "home")
      let firstReconcileAuthorized = AwsAdminAuthorityAuthorized firstReconcilePermit
          firstReconcileProof =
            must
              ( proveAwsAdminAuthorizedRecovery
                  renewalNow
                  firstReconcileAuthorized
                  AwsAdminAttemptResourceAbsent
                  AwsAdminAttemptResourceAbsent
                  ( AwsAdminAttemptJournalCleanupContinuation
                      AwsAdminRecoveryCleanupProvenRemintUsed
                  )
              )
          missingFirstReconcileBinding =
            canonicalizeWithoutPlanBinding
              (must (bindAwsAdminAuthorizedRecoveryIntent firstReconcileProof replacement))
      commitAwsAdminPreparedAuthorizedRecovery
        firstReconcileProof
        missingFirstReconcileBinding
        firstReconcileAuthorized
        `shouldBe` Left AwsAdminAuthorityRenewalBindingMismatch

    it "Sprint 2.116 invokes the exact recovery observer before outbox and Authority transitions" $ do
      let retained = renewalIntentAt renewalOldDeadline imageDigest targetAgent "home"
          replacement =
            renewalIntentAt renewalNewDeadline otherImageDigest renewalTargetAgent "home"
      permit <- authorizedPermitFor retained
      let authorized = AwsAdminAuthorityAuthorized permit
          proof =
            must
              ( proveAwsAdminAuthorizedRecovery
                  renewalNow
                  authorized
                  AwsAdminAttemptResourceAbsent
                  AwsAdminAttemptResourceAbsent
                  AwsAdminAttemptJournalInitialIntentCommitted
              )
      events <- newIORef []
      stateRef <- newIORef (0 :: Int, authorized)
      let repository = renewalRepository events stateRef
          lifecycle =
            exactPreparedLifecycle
              { proveAwsAdminAuthorizedAttemptRecovery = \now suppliedPermit -> do
                  modifyIORef' events (<> ["recovery-proof"])
                  now `shouldBe` renewalNow
                  suppliedPermit `shouldBe` permit
                  pure (Right proof)
              , prepareAndReadBackAwsAdminPreparedTarget = \renewal _ -> do
                  modifyIORef' events (<> ["outbox-cas-readback"])
                  renewal `shouldBe` Just (renewalNow, retained)
                  pure (Right replacement)
              , reobserveRetainedAwsAdminPreparedTarget = \intent -> do
                  modifyIORef' events (<> ["outbox-independent-readback"])
                  pure (Right (awsAdminPermitIntentPreparedTarget intent))
              }
          handler =
            awsAdminProvisionerAuthenticatedHandler
              (256 * 1024)
              fixtureReadyRoleReadinessSource
              (pure (Right renewalNow))
              (const (Right repository))
              lifecycle
              fixtureProviderCredentialBoundary
              authoritySigner
              emptyHandler
          body =
            LazyByteString.toStrict
              ( encodeControlPlaneRequest
                  (PrepareAwsAdminProvisioning (encodePermitIntent replacement))
              )
      response <-
        authenticatedHandlerHandle
          handler
          (verifiedCallerSlotFixture CallerOperatorCli 1)
          LifecycleAwsAdminProvisioner
          body
      fmap fst response `shouldBe` Just ReplyOk
      readIORef events
        `shouldReturn` [ "recovery-proof"
                       , "outbox-cas-readback"
                       , "outbox-independent-readback"
                       , "state-cas"
                       ]
      (snd <$> readIORef stateRef)
        `shouldReturn` AwsAdminAuthorityPrepared replacement

    it "projects the exact retained next member through the closed client" $ do
      let projection =
            AwsAdminFirstReconcileProjection
              { awsAdminFirstReconcileClass = LifecycleProviderCredential
              , awsAdminFirstReconcileMemberIndex = 1
              , awsAdminFirstReconcileMemberDigest = Text.replicate 64 "e"
              , awsAdminFirstReconcileDeadlineMicros = authorityTimeMicros deadline
              }
          client = mkAwsAdminProvisionerClient $ \request -> pure $ case request of
            ObserveAwsAdminFirstReconcile ->
              Right (AwsAdminFirstReconcileObserved (Just projection))
            _ -> Right (AwsAdminProvisioningRefused "unexpected request")
      observeAwsAdminFirstReconcile client `shouldReturn` Right (Just projection)

    it "serves the retained continuation only through the authenticated endpoint" $ do
      let continuation =
            FirstReconcileContinuation
              { firstReconcileContinuationClass = LifecycleProviderCredential
              , firstReconcileContinuationMemberIndex = 1
              , firstReconcileContinuationMemberDigest = Text.replicate 64 "e"
              , firstReconcileContinuationDeadline = deadline
              }
          lifecycle =
            exactPreparedLifecycle
              { observeAwsAdminFirstReconcileContinuation =
                  pure (Right (Just continuation))
              }
          handler =
            awsAdminProvisionerAuthenticatedHandler
              (256 * 1024)
              fixtureReadyRoleReadinessSource
              (pure (Right signingTime))
              (const (Left "repository must not be selected for continuation observation"))
              lifecycle
              fixtureProviderCredentialBoundary
              authoritySigner
              emptyHandler
          requestBody =
            LazyByteString.toStrict
              (encodeControlPlaneRequest ObserveAwsAdminFirstReconcile)
          expected =
            AwsAdminFirstReconcileObserved
              ( Just
                  AwsAdminFirstReconcileProjection
                    { awsAdminFirstReconcileClass = LifecycleProviderCredential
                    , awsAdminFirstReconcileMemberIndex = 1
                    , awsAdminFirstReconcileMemberDigest = Text.replicate 64 "e"
                    , awsAdminFirstReconcileDeadlineMicros = authorityTimeMicros deadline
                    }
              )
      response <-
        authenticatedHandlerHandle
          handler
          (verifiedCallerSlotFixture CallerOperatorCli 1)
          LifecycleAwsAdminProvisioner
          requestBody
      case response of
        Just (ReplyOk, body) ->
          decodeControlPlaneResponse
            awsAdminProvisionerResponseMaximumBytes
            (LazyByteString.fromStrict body)
            `shouldBe` Right expected
        other -> expectationFailure ("expected continuation response, got " ++ show other)

    it "always cleans a prepared Job when creation throws synchronously" $ do
      events <- newIORef ([] :: [Text])
      outcome <-
        coordinateAwsAdminProvisioning
          preparedOnlyClient
          (throwingCoordinatorKubernetes events (throwIO (userError "create failed")))
          adminCredentials
          permitIntent
      outcome `shouldBe` Left AwsAdminCoordinatorUnhandledException
      readIORef events `shouldReturn` ["delete", "absence"]

    it "Sprint 2.123 samples a fresh exact heartbeat for every sequential Job attempt" $ do
      heartbeatSource <- newIORef [1000000, 32000000]
      events <- newIORef ([] :: [(Text, Natural)])
      let record label sampled = modifyIORef' events (<> [(label, sampled)])
          acquire = do
            pending <- readIORef heartbeatSource
            case pending of
              [] -> pure (Left "fixture heartbeat source exhausted")
              sampled : remaining -> do
                writeIORef heartbeatSource remaining
                record "acquire" sampled
                pure (Right sampled)
          boundary =
            AwsAdminKubernetesBoundary
              { acquireAwsAdminJobHeartbeat = acquire
              , createAwsAdminJob = \sampled _ ->
                  record "create" sampled >> pure (Left "stop after create")
              , observeAwsAdminJob = \sampled _ ->
                  record "observe" sampled >> pure (Right Nothing)
              , attachAwsAdminWorker = \_ _ -> pure (Left "must not attach")
              , deleteAwsAdminJob = \sampled _ _ ->
                  record "delete" sampled >> pure (Right ())
              , observeAwsAdminJobAbsent = \_ _ ->
                  record "absence" 0 >> pure (Right True)
              }
          runAttempt =
            coordinateAwsAdminProvisioning
              preparedOnlyClient
              boundary
              adminCredentials
              permitIntent
      sequence [runAttempt, runAttempt]
        `shouldReturn` replicate 2 (Left (AwsAdminCoordinatorCreateFailed "stop after create"))
      readIORef events
        `shouldReturn` [ ("acquire", 1000000)
                       , ("create", 1000000)
                       , ("observe", 1000000)
                       , ("delete", 1000000)
                       , ("absence", 0)
                       , ("acquire", 32000000)
                       , ("create", 32000000)
                       , ("observe", 32000000)
                       , ("delete", 32000000)
                       , ("absence", 0)
                       ]

    it "Sprint 2.123 refuses clock failure before Job creation or cleanup" $ do
      events <- newIORef ([] :: [Text])
      let boundary =
            (throwingCoordinatorKubernetes events (pure (Right ())))
              { acquireAwsAdminJobHeartbeat = pure (Left "clock unavailable")
              }
      coordinateAwsAdminProvisioning
        preparedOnlyClient
        boundary
        adminCredentials
        permitIntent
        `shouldReturn` Left (AwsAdminCoordinatorHeartbeatUnavailable "clock unavailable")
      readIORef events `shouldReturn` []

    it "Sprint 2.123 cleans completed recovery with the signed heartbeat without resampling" $ do
      permit <- authorizedPermitFor permitIntent
      events <- newIORef ([] :: [(Text, Natural)])
      let receiptBytes = installedWorkerReceiptBytes permitIntent
          client =
            mkAwsAdminProvisionerClient $ \request -> pure $ case request of
              PrepareAwsAdminProvisioning _ ->
                Right (AwsAdminProvisioningPrepared coordinatorChallenge)
              ObserveAwsAdminProvisioning _ ->
                Right
                  ( AwsAdminProvisioningObserved
                      AwsAdminProvisionerObservation
                        { awsAdminObservedChallenge = coordinatorChallenge
                        , awsAdminObservedPhase = AwsAdminProvisionerCompleted
                        , awsAdminObservedPermit = Just (encodeSignedAwsAdminPermit permit)
                        , awsAdminObservedReceipt = Just receiptBytes
                        }
                  )
              _ -> Left AwsAdminProvisionerClientUnexpectedResponse
          boundary =
            AwsAdminKubernetesBoundary
              { acquireAwsAdminJobHeartbeat = do
                  modifyIORef' events (<> [("unexpected-acquire", 0)])
                  pure (Left "must not resample")
              , createAwsAdminJob = \_ _ -> pure (Left "must not create")
              , observeAwsAdminJob = \_ _ -> pure (Left "must not observe")
              , attachAwsAdminWorker = \_ _ -> pure (Left "must not attach")
              , deleteAwsAdminJob = \sampled _ _ ->
                  modifyIORef' events (<> [("delete", sampled)]) >> pure (Right ())
              , observeAwsAdminJobAbsent = \_ _ ->
                  modifyIORef' events (<> [("absence", 0)]) >> pure (Right True)
              }
      result <- coordinateAwsAdminProvisioning client boundary adminCredentials permitIntent
      result `shouldSatisfy` either (const False) (const True)
      readIORef events `shouldReturn` [("delete", 2000000), ("absence", 0)]

    it "cleans a prepared Job and rethrows cancellation during creation" $ do
      events <- newIORef ([] :: [Text])
      outcome <-
        try
          ( coordinateAwsAdminProvisioning
              preparedOnlyClient
              (throwingCoordinatorKubernetes events (throwIO ThreadKilled))
              adminCredentials
              permitIntent
          )
          :: IO
               ( Either
                   AsyncException
                   (Either AwsAdminCoordinatorError AwsAdminWorkerReceipt)
               )
      outcome `shouldBe` Left ThreadKilled
      readIORef events `shouldReturn` ["delete", "absence"]

    it "accepts a lost delete response only after positive absence" $ do
      events <- newIORef ([] :: [Text])
      let base =
            throwingCoordinatorKubernetes
              events
              (throwIO (userError "create failed"))
          responseLost =
            base
              { deleteAwsAdminJob = \_ _ _ ->
                  writeIORef events ["delete"] >> pure (Left "response lost")
              }
      outcome <-
        coordinateAwsAdminProvisioning
          preparedOnlyClient
          responseLost
          adminCredentials
          permitIntent
      outcome `shouldBe` Left AwsAdminCoordinatorUnhandledException
      readIORef events `shouldReturn` ["delete", "absence"]

    it "Sprint 2.111 waits only through a bounded exact Pod convergence" $ do
      let exactObservation =
            AwsAdminPodObservation
              { awsAdminObservedJobName = "job"
              , awsAdminObservedJobUid = "job-uid"
              , awsAdminObservedPodName = "pod"
              , awsAdminObservedPodUid = "pod-uid"
              , awsAdminObservedImageDigest = imageDigest
              , awsAdminObservedServiceAccount = awsAdminWorkerServiceAccount
              , awsAdminObservedServiceAccountUid = "service-account-uid"
              , awsAdminObservedHeartbeatMicros = 1000000
              }
      observations <-
        newIORef
          [ Right AwsAdminPodTransitional
          , Right AwsAdminPodTransitional
          , Right (AwsAdminPodReady exactObservation)
          ]
      waits <- newIORef (0 :: Int)
      awaitAwsAdminPodObservationWith
        4
        (modifyIORef' waits (+ 1))
        (popPodConvergence observations)
        `shouldReturn` Right (Just exactObservation)
      readIORef waits `shouldReturn` 2

      immediateWaits <- newIORef (0 :: Int)
      awaitAwsAdminPodObservationWith
        4
        (modifyIORef' immediateWaits (+ 1))
        (pure (Right AwsAdminPodAbsent))
        `shouldReturn` Right Nothing
      awaitAwsAdminPodObservationWith
        4
        (modifyIORef' immediateWaits (+ 1))
        (pure (Left (AwsAdminKubernetesObservationFailed "identity drift")))
        `shouldReturn` Left (AwsAdminKubernetesObservationFailed "identity drift")
      readIORef immediateWaits `shouldReturn` 0

      exhaustedWaits <- newIORef (0 :: Int)
      awaitAwsAdminPodObservationWith
        3
        (modifyIORef' exhaustedWaits (+ 1))
        (pure (Right AwsAdminPodTransitional))
        `shouldReturn` Left
          ( AwsAdminKubernetesObservationFailed
              "exact Pod did not become ready before the observation budget expired"
          )
      readIORef exhaustedWaits `shouldReturn` 2

    it "Sprint 2.116 renders an AWS-only Kubernetes API identity without administrator material" $ do
      let executionImage = "127.0.0.1:30080/prodbox/prodbox-runtime:prodbox-test"
          targetWorkerRepository = "127.0.0.1:30080/prodbox/prodbox-runtime"
          resources = must (mkAwsAdminJobResources "250m" "256Mi")
          prepared = AwsAdminPreparedProvisioning permitIntent coordinatorChallenge
          manifest =
            renderAwsAdminJob
              executionImage
              resources
              1000000
              prepared
          rendered =
            LazyByteString.toStrict
              . Aeson.encode
              <$> manifest
      fmap jobPodSecurityContext manifest
        `shouldBe` Right (Just credentialProvisionerPodSecurityContext)
      fmap jobContainerImage manifest
        `shouldBe` Right (Just executionImage)
      fmap jobContainerArguments manifest
        `shouldBe` Right (Just (expectedAwsAdminWorkerArguments targetWorkerRepository))
      case manifest of
        Right job ->
          case jobContainerArguments job of
            Just arguments ->
              case execParserPure defaultPrefs parserInfo (fmap Text.unpack arguments <> ["--dry-run"]) of
                Success _ -> pure ()
                _ -> expectationFailure "native AWS-admin Job argv did not satisfy the closed parser"
            Nothing -> expectationFailure "native AWS-admin Job did not render string arguments"
        Left _ -> expectationFailure "native AWS-admin Job did not render"
      rendered `shouldSatisfy` either (const False) (ByteString.isInfixOf "\"--mode\",\"normal\"")
      rendered
        `shouldSatisfy` either (const False) (ByteString.isInfixOf (TextEncoding.encodeUtf8 imageDigest))
      -- Leak canary (vault_doctrine.md §20.4): assert the absence of the fixture's
      -- own values, not of a vendor prefix. A prefix assertion weakens silently as
      -- fixtures stop imitating credentials; this one fails whatever the fixture is.
      rendered
        `shouldSatisfy` either
          (const False)
          (not . ByteString.isInfixOf (TextEncoding.encodeUtf8 (access_key_id adminCredentials)))
      rendered
        `shouldSatisfy` either
          (const False)
          (not . ByteString.isInfixOf (TextEncoding.encodeUtf8 (secret_access_key adminCredentials)))
      rendered `shouldSatisfy` either (const False) (not . ByteString.isInfixOf "secret_access_key")
      rendered
        `shouldSatisfy` either
          (const False)
          (ByteString.isInfixOf "/var/run/secrets/kubernetes.io/serviceaccount")
      rendered
        `shouldSatisfy` either
          (const False)
          (ByteString.isInfixOf "kube-root-ca.crt")
      rendered
        `shouldSatisfy` either
          (const False)
          (ByteString.isInfixOf "metadata.namespace")
      rendered
        `shouldSatisfy` either
          (const False)
          (ByteString.isInfixOf "\"ephemeral-storage\":\"256Mi\"")
      credentialProvisionerKubernetesApiVolumeMount
        `shouldBe` Aeson.object
          [ "name" Aeson..= ("kubernetes-api-identity" :: Text)
          , "mountPath"
              Aeson..= ("/var/run/secrets/kubernetes.io/serviceaccount" :: Text)
          , "readOnly" Aeson..= True
          ]
      LazyByteString.toStrict (Aeson.encode credentialProvisionerKubernetesApiVolume)
        `shouldSatisfy` ByteString.isInfixOf "\"serviceAccountToken\":{\"expirationSeconds\":600,\"path\":\"token\"}"
      chart <- readFile "charts/credential-provisioner/templates/job.yaml"
      chart `shouldContain` "runAsUser: 65532"
      chart `shouldContain` "runAsGroup: 65532"
      chart `shouldContain` "fsGroup: 65532"
      chart `shouldContain` "fsGroupChangePolicy: OnRootMismatch"
      chart `shouldContain` "mountPath: /var/run/secrets/kubernetes.io/serviceaccount"
      chart `shouldContain` "name: kube-root-ca.crt"
      chart `shouldContain` "fieldPath: metadata.namespace"

    it "Sprint 2.113 refuses invalid execution-image input before rendering a Job" $ do
      let resources = must (mkAwsAdminJobResources "250m" "256Mi")
          prepared = AwsAdminPreparedProvisioning permitIntent coordinatorChallenge
      renderAwsAdminJob "" resources 1000000 prepared
        `shouldBe` Left (AwsAdminKubernetesRenderInvalid "execution image reference is invalid")
      renderAwsAdminJob
        ("127.0.0.1:30080/prodbox/prodbox-runtime@" <> imageDigest)
        resources
        1000000
        prepared
        `shouldBe` Left (AwsAdminKubernetesRenderInvalid "execution image reference is invalid")

    it "Sprint 2.112 accepts only exact canonical runtime-manifest identity forms" $ do
      let repository = "127.0.0.1:30080/prodbox/prodbox-runtime"
      credentialProvisionerRuntimeManifestDigest imageDigest
        `shouldBe` Just imageDigest
      credentialProvisionerRuntimeManifestDigest ("containerd://" <> imageDigest)
        `shouldBe` Just imageDigest
      credentialProvisionerRuntimeManifestDigest (repository <> "@" <> imageDigest)
        `shouldBe` Just imageDigest
      credentialProvisionerRuntimeManifestDigest
        ("docker-pullable://" <> repository <> "@" <> imageDigest)
        `shouldBe` Just imageDigest
      credentialProvisionerRuntimeManifestDigest (repository <> "@" <> otherImageDigest)
        `shouldBe` Just otherImageDigest
      credentialProvisionerRuntimeManifestDigest (repository <> "@@" <> imageDigest)
        `shouldBe` Nothing
      credentialProvisionerRuntimeManifestDigest ("@" <> imageDigest)
        `shouldBe` Nothing
      credentialProvisionerRuntimeManifestDigest (Text.toUpper imageDigest)
        `shouldBe` Nothing

    it
      "Sprint 4.108 refuses by name when a key this call minted finds the Target already holding the generation"
      $ do
        permit <- authorizedPermitFor permitIntent
        let predecessorReceipt = scriptedTargetReceipt "vault:v1:predecessor-commitment" permitIntent
            ownReceipt = scriptedTargetReceipt "vault:v1:own-commitment" permitIntent
        world <-
          newScriptedAwsAdminWorld
            (initialAwsAdminExecutionJournal permit)
            []
            (Just predecessorReceipt)
        outcome <- runScriptedAwsAdminPermit world permit ownReceipt
        void outcome
          `shouldBe` Left
            ( AwsAdminRecoveryRemintAmbiguous
                AwsAdminRecoveryRemintTargetHoldsPredecessorMaterial
            )
        -- The Target is exactly what the dead attempt left: nothing was delivered
        -- over it and no receipt of the new key was committed in its place.
        readIORef (scriptedWorldTarget world) >>= (`shouldBe` Just predecessorReceipt)
        effects <- readIORef (scriptedWorldLog world)
        filter (== "deliver") effects `shouldBe` []
        -- Every key the refusing attempts minted was deleted again.
        readIORef (scriptedWorldKeys world) >>= (`shouldBe` [])
        length (filter (== "create-key") effects)
          `shouldBe` length (filter (== "delete-key") effects)
        phase <- awsAdminExecutionJournalPhase <$> readIORef (scriptedWorldJournal world)
        phase `shouldBe` AwsAdminExecutionCleanupProven True

    it "Sprint 4.108 still delivers and commits when the Target does not hold the generation" $ do
      permit <- authorizedPermitFor permitIntent
      let ownReceipt = scriptedTargetReceipt "vault:v1:own-commitment" permitIntent
      world <-
        newScriptedAwsAdminWorld (initialAwsAdminExecutionJournal permit) [] Nothing
      outcome <- runScriptedAwsAdminPermit world permit ownReceipt
      void outcome `shouldBe` Right ()
      effects <- readIORef (scriptedWorldLog world)
      filter (== "deliver") effects `shouldBe` ["deliver"]
      length (filter (== "create-key") effects) `shouldBe` 1
      keys <- readIORef (scriptedWorldKeys world)
      length keys `shouldBe` 1
      readIORef (scriptedWorldTarget world) >>= (`shouldBe` Just ownReceipt)

    it "Sprint 4.108 refuses a resumed remint that finds the Target holding the generation" $ do
      permit <- authorizedPermitFor permitIntent
      let predecessorReceipt = scriptedTargetReceipt "vault:v1:predecessor-commitment" permitIntent
          ownReceipt = scriptedTargetReceipt "vault:v1:own-commitment" permitIntent
          resumedKey = must (mkProvisionedAccessKeyId "SCRIPTEDKEYREMINT")
          -- A remint attempt whose process died after it minted a key: the
          -- predecessor attempt (now cleaned up) delivered, so the Target holds
          -- its material, and this call cannot tell that from its own delivery.
          remintJournal =
            foldl'
              (\journal event -> must (stepAwsAdminExecutionJournal event journal))
              (initialAwsAdminExecutionJournal permit)
              [ CommitAwsAdminCreateAttempt [] False
              , RequireAwsAdminStableCleanup False
              , CommitAwsAdminStableCleanup False
              , RestartAwsAdminAfterCleanup
              , CommitAwsAdminCreateAttempt [] True
              , CommitAwsAdminCreatedKey resumedKey [] True
              ]
      world <- newScriptedAwsAdminWorld remintJournal [resumedKey] (Just predecessorReceipt)
      outcome <- runScriptedAwsAdminPermit world permit ownReceipt
      void outcome
        `shouldBe` Left
          ( AwsAdminRecoveryRemintAmbiguous
              AwsAdminRecoveryRemintTargetHoldsPredecessorMaterial
          )
      effects <- readIORef (scriptedWorldLog world)
      filter (== "deliver") effects `shouldBe` []
      filter (== "create-key") effects `shouldBe` []
      readIORef (scriptedWorldKeys world) >>= (`shouldBe` [])
      readIORef (scriptedWorldTarget world) >>= (`shouldBe` Just predecessorReceipt)

    it
      "Sprint 4.108 still adopts the Target when an initial attempt is resumed with no material in hand"
      $ do
        permit <- authorizedPermitFor permitIntent
        let ownReceipt = scriptedTargetReceipt "vault:v1:own-commitment" permitIntent
            resumedKey = must (mkProvisionedAccessKeyId "SCRIPTEDKEYRESUMED")
            prepared =
              must
                ( stepAwsAdminExecutionJournal
                    (CommitAwsAdminCreateAttempt [] False)
                    (initialAwsAdminExecutionJournal permit)
                )
            resumed = must (stepAwsAdminExecutionJournal (CommitAwsAdminCreatedKey resumedKey [] False) prepared)
        -- The process that minted the key delivered the material and died before it
        -- committed the receipt; the only way that attempt can finish is to adopt the
        -- Target it wrote.
        world <- newScriptedAwsAdminWorld resumed [resumedKey] (Just ownReceipt)
        outcome <- runScriptedAwsAdminPermit world permit ownReceipt
        void outcome `shouldBe` Right ()
        effects <- readIORef (scriptedWorldLog world)
        filter (== "deliver") effects `shouldBe` []
        filter (== "create-key") effects `shouldBe` []
        readIORef (scriptedWorldKeys world) >>= (`shouldBe` [resumedKey])

data ServingRepairFault
  = ServingRepairNormal
  | ServingRepairCoordinateUnavailable
  | ServingRepairReceiptMismatch
  | ServingRepairAgentUnavailable
  | ServingRepairTargetPresent
  | ServingRepairRepeated
  | ServingRepairInvalidIntent
  | ServingRepairOrdinarySubmission
  deriving (Eq, Show)

-- | Revoke ordering is tested at the production execution algebra's boundary,
-- including every failed IAM gate, rather than through a second implementation.
harnessCredentialLineageCases :: SuiteBuilder ()
harnessCredentialLineageCases = describe "Sprint 5.51 per-invocation credential slots" $ do
  forM_ [False, True] $ \servingMissing ->
    forM_ [False, True] $ \failReplacement ->
      it
        ( "recovers first-reconcile retirement durably; serving missing/retry="
            <> show (servingMissing, failReplacement)
        )
        $ do
          let retired = ProviderCredentialRecoveryRetired 6 (Text.replicate 64 "b")
              initial = if servingMissing then ProviderCredentialRecoveryServing 6 (Text.replicate 64 "a") else retired
          view <- newIORef initial
          target <- newIORef Nothing
          failed <- newIORef False
          events <- newIORef ([] :: [Text])
          submitted <- newIORef []
          let client = mkAwsAdminProvisionerClient call
              call request = case request of
                ObserveAwsAdminProviderCredentialOperation -> pure (Right (AwsAdminProviderCredentialOperationObserved Nothing))
                ObserveAwsAdminProviderCredentialRecovery -> Right . AwsAdminProviderCredentialRecoveryObserved <$> readIORef view
                SettleAwsAdminFirstReconcileRecovery -> do
                  modifyIORef' events (<> ["settle"])
                  pure (Right AwsAdminFirstReconcileRecoverySettled)
                _ -> pure (Left AwsAdminProvisionerClientUnexpectedResponse)
              coordinate intent = do
                modifyIORef' submitted (<> [intent])
                case awsAdminPermitIntentAction intent of
                  RevokeOperatorMaterial -> do
                    (result, _) <- runRevocationScriptFor intent RevocationSucceeds
                    writeIORef view retired
                    writeIORef target Nothing
                    pure (first show result)
                  _ -> do
                    alreadyFailed <- readIORef failed
                    if failReplacement && not alreadyFailed
                      then writeIORef failed True >> pure (Left "replacement interrupted")
                      else do
                        permit <- authorizedPermitFor intent
                        world <- newScriptedAwsAdminWorld (initialAwsAdminExecutionJournal permit) [] Nothing
                        result <- runScriptedAwsAdminPermit world permit (scriptedTargetReceipt "vault:v1:lineage" intent)
                        let metadata =
                              (lineageMetadata 1)
                                { targetMaterialObservedRequestDigest =
                                    targetValueDigestText (awsAdminPermitIntentRequestDigest intent)
                                , targetMaterialObservedActionDigest = targetValueDigestText receiptDigest
                                , targetMaterialObservedPodUid = "credential-provisioner-pod-1"
                                }
                        writeIORef target (Just metadata)
                        writeIORef view (ProviderCredentialRecoveryServing 1 (Text.replicate 64 "c"))
                        pure (first show result)
              run =
                reconcileFirstReconcileProviderRecovery
                  client
                  lineageParameters
                  iamParameters
                  (Right <$> readIORef target)
                  (pure 4000000)
                  coordinate
                  (modifyIORef' events (<> ["members"]) >> pure (Right ()))
          firstResult <- run
          if failReplacement
            then do
              firstResult `shouldBe` Left "replacement interrupted"
              readIORef events `shouldReturn` []
              readIORef view `shouldReturn` retired
              run `shouldReturn` Right ()
            else firstResult `shouldBe` Right ()
          readIORef events `shouldReturn` ["members", "settle"]
          intents <- readIORef submitted
          let installs = filter ((== InstallOperatorMaterial) . awsAdminPermitIntentAction) intents
          length installs `shouldBe` if failReplacement then 2 else 1
          case installs of
            [] -> expectationFailure "first-reconcile recovery submitted no install"
            installed : rest ->
              map awsAdminPermitIntentOperationId rest
                `shouldSatisfy` all (== awsAdminPermitIntentOperationId installed)
          map awsAdminPermitIntentGeneration installs
            `shouldBe` replicate (length installs) (must (mkCredentialGeneration 1))
          length (filter ((== RevokeOperatorMaterial) . awsAdminPermitIntentAction) intents)
            `shouldBe` if servingMissing then 1 else 0
  forM_
    [ ProviderCredentialRecoveryClosed
    , ProviderCredentialRecoveryRevoked
    , ProviderCredentialRecoveryRecorded 6
    , ProviderCredentialRecoveryPending "unresolved"
    ]
    $ \view ->
      it ("refuses closed or still-pending first-reconcile recovery: " <> show view) $ do
        events <- newIORef ([] :: [Text])
        let client = mkAwsAdminProvisionerClient $ \request -> pure $ case request of
              ObserveAwsAdminProviderCredentialOperation -> Right (AwsAdminProviderCredentialOperationObserved Nothing)
              ObserveAwsAdminProviderCredentialRecovery -> Right (AwsAdminProviderCredentialRecoveryObserved view)
              _ -> Left AwsAdminProvisionerClientUnexpectedResponse
        answer <-
          reconcileFirstReconcileProviderRecovery
            client
            lineageParameters
            iamParameters
            (pure (Right Nothing))
            (pure 4000000)
            (\_ -> modifyIORef' events (<> ["coordinate"]) >> pure (Left "unexpected"))
            (modifyIORef' events (<> ["members"]) >> pure (Right ()))
        answer `shouldSatisfy` either (const True) (const False)
        readIORef events `shouldReturn` []
  forM_ [1, 6] $ \retainedGenerationValue ->
    forM_ [False, True] $ \retired ->
      forM_ [HarnessCredentialInstall, HarnessCredentialRevoke] $ \slot ->
        it
          ("uses retained generation for an absent Target: " <> show (retainedGenerationValue, retired, slot))
          $ do
            let view =
                  if retired
                    then ProviderCredentialRecoveryRetired retainedGenerationValue (Text.replicate 64 "a")
                    else ProviderCredentialRecoveryServing retainedGenerationValue (Text.replicate 64 "a")
                client = mkAwsAdminProvisionerClient $ \request -> pure $ case request of
                  ObserveAwsAdminProvisioning _ -> Left (AwsAdminProvisionerClientRefused "operation-not-found")
                  ObserveAwsAdminProviderCredentialRecovery -> Right (AwsAdminProviderCredentialRecoveryObserved view)
                  _ -> Left AwsAdminProvisionerClientUnexpectedResponse
            answer <-
              resolveHarnessCredentialSlot
                client
                lineageParameters
                iamParameters
                lineageFixture
                slot
                Nothing
                4000000
            case (retired, slot, answer) of
              (False, HarnessCredentialInstall, Right (RepairHarnessCredentialTarget intent)) -> do
                awsAdminPermitIntentAction intent `shouldBe` RevokeOperatorMaterial
                credentialGenerationValue (awsAdminPermitIntentGeneration intent) `shouldBe` retainedGenerationValue
                operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent)
                  `shouldNotBe` must (harnessCredentialSlotOperationId lineageFixture HarnessCredentialRevoke)
                operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent)
                  `shouldNotBe` must (harnessCredentialSlotOperationId lineageFixture HarnessCredentialInstall)
              (_, HarnessCredentialRevoke, Right (SubmitHarnessCredentialIntent intent)) -> do
                awsAdminPermitIntentAction intent `shouldBe` RevokeOperatorMaterial
                credentialGenerationValue (awsAdminPermitIntentGeneration intent) `shouldBe` retainedGenerationValue
              (True, HarnessCredentialInstall, Right (SubmitHarnessCredentialIntent intent)) -> do
                awsAdminPermitIntentAction intent `shouldBe` InstallOperatorMaterial
                credentialGenerationValue (awsAdminPermitIntentGeneration intent) `shouldBe` 1
              _ -> expectationFailure (show answer)
  it "changes the serving-repair coordinate across retained lineages and replays the same lineage" $ do
    let resolve scope =
          resolveHarnessCredentialSlot
            ( mkAwsAdminProvisionerClient $ \request -> pure $ case request of
                ObserveAwsAdminProvisioning _ -> Left (AwsAdminProvisionerClientRefused "operation-not-found")
                ObserveAwsAdminProviderCredentialRecovery ->
                  Right
                    (AwsAdminProviderCredentialRecoveryObserved (ProviderCredentialRecoveryServing 1 scope))
                _ -> Left AwsAdminProvisionerClientUnexpectedResponse
            )
            lineageParameters
            iamParameters
            lineageFixture
            HarnessCredentialInstall
            Nothing
            4000000
        operation (Right (RepairHarnessCredentialTarget intent)) = operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent)
        operation other = error (show other)
    originalOperation <- operation <$> resolve (Text.replicate 64 "a")
    replay <- operation <$> resolve (Text.replicate 64 "a")
    successor <- operation <$> resolve (Text.replicate 64 "b")
    replay `shouldBe` originalOperation
    successor `shouldNotBe` originalOperation
  it "proposes a cascade successor without replacing the Authority's predecessor proof" $ do
    let client = mkAwsAdminProvisionerClient $ \request -> pure $ case request of
          ObserveAwsAdminProvisioning _ -> Left (AwsAdminProvisionerClientRefused "operation-not-found")
          ObserveAwsAdminProviderCredentialRecovery -> Right (AwsAdminProviderCredentialRecoveryObserved ProviderCredentialRecoveryRevoked)
          _ -> Left AwsAdminProvisionerClientUnexpectedResponse
    installed <-
      resolveHarnessCredentialSlot
        client
        lineageParameters
        iamParameters
        lineageFixture
        HarnessCredentialInstall
        Nothing
        4000000
    case installed of
      Right (SubmitHarnessCredentialIntent intent) -> do
        awsAdminPermitIntentAction intent `shouldBe` InstallOperatorMaterial
        credentialGenerationValue (awsAdminPermitIntentGeneration intent) `shouldBe` 1
      other -> expectationFailure (show other)
    revoked <-
      resolveHarnessCredentialSlot
        client
        lineageParameters
        iamParameters
        lineageFixture
        HarnessCredentialRevoke
        Nothing
        4000000
    revoked `shouldBe` Left HarnessCredentialAuthorityClosed
  it "permits only the recorded generation's final cascade revoke proposal" $ do
    let client = mkAwsAdminProvisionerClient $ \request -> pure $ case request of
          ObserveAwsAdminProvisioning _ -> Left (AwsAdminProvisionerClientRefused "operation-not-found")
          ObserveAwsAdminProviderCredentialRecovery -> Right (AwsAdminProviderCredentialRecoveryObserved (ProviderCredentialRecoveryRecorded 6))
          _ -> Left AwsAdminProvisionerClientUnexpectedResponse
    proposed <-
      resolveHarnessCredentialSlot
        client
        lineageParameters
        iamParameters
        lineageFixture
        HarnessCredentialRevoke
        Nothing
        4000000
    case proposed of
      Right (SubmitHarnessCredentialIntent intent) -> do
        awsAdminPermitIntentAction intent `shouldBe` RevokeOperatorMaterial
        credentialGenerationValue (awsAdminPermitIntentGeneration intent) `shouldBe` 6
      other -> expectationFailure (show other)
    installed <-
      resolveHarnessCredentialSlot
        client
        lineageParameters
        iamParameters
        lineageFixture
        HarnessCredentialInstall
        Nothing
        4000000
    installed `shouldBe` Left HarnessCredentialAuthorityClosed
  forM_ [ProviderCredentialRecoveryPending "other/exact-operation", ProviderCredentialRecoveryClosed] $ \view ->
    forM_ [HarnessCredentialInstall, HarnessCredentialRevoke] $ \slot ->
      it ("refuses a fresh invocation through occupied or closed admission: " <> show (view, slot)) $ do
        let client = mkAwsAdminProvisionerClient $ \request -> pure $ case request of
              ObserveAwsAdminProvisioning _ -> Left (AwsAdminProvisionerClientRefused "operation-not-found")
              ObserveAwsAdminProviderCredentialRecovery -> Right (AwsAdminProviderCredentialRecoveryObserved view)
              _ -> Left AwsAdminProvisionerClientUnexpectedResponse
        answer <-
          resolveHarnessCredentialSlot
            client
            lineageParameters
            iamParameters
            lineageFixture
            slot
            Nothing
            4000000
        answer `shouldSatisfy` either (const True) (const False)
  forM_
    [ ServingRepairNormal
    , ServingRepairCoordinateUnavailable
    , ServingRepairReceiptMismatch
    , ServingRepairAgentUnavailable
    , ServingRepairTargetPresent
    , ServingRepairRepeated
    , ServingRepairInvalidIntent
    , ServingRepairOrdinarySubmission
    ]
    $ \fault ->
      it
        ("bounds serving credential repair and observes absence before a fresh submission: " <> show fault)
        $ do
          (revokeIntent, _, revokedReceipt) <- completedLineageRevoke
          (installIntent, _, installedReceipt, _) <- completedLineageInstall
          resolves <- newIORef (0 :: Int)
          mutations <- newIORef (0 :: Int)
          observations <- newIORef (0 :: Int)
          let resolve _ = do
                modifyIORef' resolves (+ 1)
                count <- readIORef resolves
                pure
                  ( Right $
                      if fault == ServingRepairOrdinarySubmission
                        then SubmitHarnessCredentialIntent installIntent
                        else
                          if fault == ServingRepairInvalidIntent
                            then RepairHarnessCredentialTarget installIntent
                            else
                              if count == 1 || fault == ServingRepairRepeated
                                then RepairHarnessCredentialTarget revokeIntent
                                else SubmitHarnessCredentialIntent installIntent
                  )
              coordinate _ = do
                modifyIORef' mutations (+ 1)
                pure $ case fault of
                  ServingRepairCoordinateUnavailable -> Left "coordinator unobservable"
                  ServingRepairReceiptMismatch -> Right installedReceipt
                  _ -> Right revokedReceipt
              observe = do
                modifyIORef' observations (+ 1)
                pure $ case fault of
                  ServingRepairAgentUnavailable -> Left "Agent unobservable"
                  ServingRepairTargetPresent -> Right (Just (lineageMetadata 1))
                  _ -> Right Nothing
              ordinary = fault == ServingRepairOrdinarySubmission
              invalid = fault == ServingRepairInvalidIntent
              beforeObserve =
                fault `elem` [ServingRepairCoordinateUnavailable, ServingRepairReceiptMismatch]
                  || invalid
                  || ordinary
          answer <- resolveHarnessCredentialSubmission resolve coordinate observe Nothing
          if fault `elem` [ServingRepairNormal, ServingRepairOrdinarySubmission]
            then answer `shouldBe` Right (SubmitHarnessCredentialIntent installIntent)
            else answer `shouldSatisfy` either (const True) (const False)
          readIORef mutations `shouldReturn` if invalid || ordinary then 0 else 1
          readIORef observations `shouldReturn` if beforeObserve then 0 else 1
          readIORef resolves
            `shouldReturn` if fault `elem` [ServingRepairNormal, ServingRepairRepeated] then 2 else 1
  it "Sprint 6.5 preserves the confirmed fixed-slot revocation receipt" $ do
    (_, _, receipt) <- completedLineageRevoke
    let confirmed = must (confirmHarnessCredentialOutcome receipt Nothing)
        evidence = must (confirmHarnessCredentialRevocation lineageFixture confirmed)
    harnessCredentialRevocationOperationId evidence
      `shouldBe` must (harnessCredentialSlotOperationId lineageFixture HarnessCredentialRevoke)
    harnessCredentialRevocationReceipt evidence `shouldBe` receipt
    -- One digest standing for both observations is refused by the epoch.
    -- The narrowing keeps the actual worker attestation and Agent evidence.
    harnessCredentialRevocationEpochReceipt evidence
      `shouldSatisfy` either (const False) (const True)
    harnessCredentialConfirmationGeneration confirmed
      `shouldBe` credentialGenerationValue (awsAdminWorkerReceiptGeneration receipt)
  it "Sprint 6.5 refuses another invocation's revocation receipt" $ do
    (_, _, receipt) <- completedLineageRevoke
    let confirmed = must (confirmHarnessCredentialOutcome receipt Nothing)
        otherLineage = must (mkHarnessCredentialLineage "all" (ByteString.replicate 32 2))
    confirmHarnessCredentialRevocation otherLineage confirmed
      `shouldBe` Left HarnessCredentialForeignOperation
  it "Sprint 6.5 withholds confirmation while the revoked Target is still observable" $ do
    (_, _, receipt) <- completedLineageRevoke
    confirmHarnessCredentialOutcome receipt (Just (lineageMetadata 1))
      `shouldBe` Left HarnessCredentialRevokedTargetStillPresent
  it "Sprint 6.5 cannot promote an installed confirmation into revocation evidence" $ do
    (_, _, receipt, metadata) <- completedLineageInstall
    let confirmed = must (confirmHarnessCredentialOutcome receipt (Just metadata))
    confirmHarnessCredentialRevocation lineageFixture confirmed
      `shouldBe` Left HarnessCredentialCompletedReceiptKindMismatch
  forM_ [HarnessCredentialInstall, HarnessCredentialRevoke] $ \slot ->
    forM_ [False, True] $ \expired ->
      it
        ("resumes globally reserved " <> show slot <> " before a fresh lineage; expired=" <> show expired)
        $ do
          original <- resolveLineageFixture slot (Just (lineageMetadata 6)) Nothing
          let retained = submittedLineageIntent original
              operation = operatorMaterialOperationIdText (awsAdminPermitIntentOperationId retained)
              observation = lineageObservation AwsAdminProvisionerPrepared retained Nothing Nothing
              parameters = lineageParameters {genesisIntentDeadline = authorityTimeFromMicros 120000000}
              now = if expired then 60000000 else 4000000
              client = mkAwsAdminProvisionerClient $ \request -> pure $ case request of
                ObserveAwsAdminProviderCredentialOperation -> Right (AwsAdminProviderCredentialOperationObserved (Just operation))
                ObserveAwsAdminProvisioning selected | selected == operation -> Right (AwsAdminProvisioningObserved observation)
                _ -> Right (AwsAdminProvisioningRefused "unexpected request")
          seen <- newIORef []
          result <- resumePendingHarnessCredentialOperation client parameters iamParameters Nothing now $ \intent -> do
            modifyIORef' seen (<> [intent])
            pure (Right ())
          result `shouldBe` Right True
          observed <- readIORef seen
          length observed `shouldBe` 1
          forM_ observed $ \intent -> do
            awsAdminPermitIntentOperationId intent `shouldBe` awsAdminPermitIntentOperationId retained
            awsAdminPermitIntentPermitId intent `shouldBe` awsAdminPermitIntentPermitId retained
            awsAdminPermitIntentRequestDigest intent `shouldBe` awsAdminPermitIntentRequestDigest retained
            awsAdminPermitIntentGeneration intent `shouldBe` awsAdminPermitIntentGeneration retained
            awsAdminPermitIntentAction intent `shouldBe` awsAdminPermitIntentAction retained
            awsAdminPermitIntentDeadline intent
              `shouldBe` if expired then genesisIntentDeadline parameters else awsAdminPermitIntentDeadline retained
            awsAdminPreparedRenewalBindingsMatch retained intent `shouldBe` True
  it "does not invoke recovery when the Authority has no reserved credential operation" $ do
    called <- newIORef False
    let client =
          mkAwsAdminProvisionerClient
            (\_ -> pure (Right (AwsAdminProviderCredentialOperationObserved Nothing)))
    result <- resumePendingHarnessCredentialOperation client lineageParameters iamParameters Nothing 4000000 $ \_ -> do
      writeIORef called True
      pure (Right ())
    result `shouldBe` Right False
    readIORef called `shouldReturn` False
  forM_ [False, True] $ \rotating ->
    forM_ [Nothing, Just (lineageMetadata 1)] $ \target ->
      it
        ( "resumes an expired authorized parent through its revoke-only child; rotate="
            <> show rotating
            <> "; target="
            <> show (fmap targetMaterialObservedGeneration target)
        )
        $ do
          original <-
            resolveLineageFixture
              HarnessCredentialInstall
              (if rotating then Just (lineageMetadata 6) else Nothing)
              Nothing
          let retained = submittedLineageIntent original
              operation = operatorMaterialOperationIdText (awsAdminPermitIntentOperationId retained)
              parameters = lineageParameters {genesisIntentDeadline = authorityTimeFromMicros 120000000}
              client = mkAwsAdminProvisionerClient $ \request -> pure $ case request of
                ObserveAwsAdminProviderCredentialOperation -> Right (AwsAdminProviderCredentialOperationObserved (Just operation))
                ObserveAwsAdminProvisioning selected
                  | selected == operation ->
                      Right
                        ( AwsAdminProvisioningObserved
                            (lineageObservation AwsAdminProvisionerAuthorized retained Nothing Nothing)
                        )
                _ -> Right (AwsAdminProvisioningRefused "unexpected request")
          seen <- newIORef []
          result <- resumePendingHarnessCredentialOperation client parameters iamParameters target 60000000 $ \intent -> do
            modifyIORef' seen (<> [intent])
            pure (Right ())
          result `shouldBe` Right True
          observed <- readIORef seen
          length observed `shouldBe` 1
          forM_ observed $ \intent -> do
            awsAdminPermitIntentAction intent `shouldBe` RevokeOperatorMaterial
            awsAdminPermitIntentOperationId intent `shouldNotBe` awsAdminPermitIntentOperationId retained
            credentialGenerationValue (awsAdminPermitIntentGeneration intent)
              `shouldBe` maybe
                (credentialGenerationValue (awsAdminPermitIntentGeneration retained))
                targetMaterialObservedGeneration
                target
            awsAdminPermitIntentIamParameters intent `shouldBe` awsAdminPermitIntentIamParameters retained
            awsAdminPermitIntentAuthorityScope intent `shouldBe` awsAdminPermitIntentAuthorityScope retained
            awsAdminPermitIntentDeadline intent `shouldBe` genesisIntentDeadline parameters
  forM_ [AwsAdminProvisionerAuthorized, AwsAdminProvisionerCompleted] $ \phase ->
    it
      ( "selects cleanup from retained metadata when normal completion cannot confirm its Target: "
          <> show phase
      )
      $ do
        original <- resolveLineageFixture HarnessCredentialInstall (Just (lineageMetadata 6)) Nothing
        let retained = submittedLineageIntent original
            operation = operatorMaterialOperationIdText (awsAdminPermitIntentOperationId retained)
            parameters = lineageParameters {genesisIntentDeadline = authorityTimeFromMicros 120000000}
            client = mkAwsAdminProvisionerClient $ \request -> pure $ case request of
              ObserveAwsAdminProviderCredentialOperation -> Right (AwsAdminProviderCredentialOperationObserved (Just operation))
              ObserveAwsAdminProvisioning _ -> Left (AwsAdminProvisionerClientUnavailable "current Target cannot confirm completion")
              ObserveAwsAdminProvisioningMetadata selected
                | selected == operation ->
                    Right
                      (AwsAdminProvisioningObserved (lineageObservation phase retained Nothing Nothing))
              _ -> Right (AwsAdminProvisioningRefused "unexpected request")
        seen <- newIORef []
        result <- resumePendingHarnessCredentialOperation client parameters iamParameters Nothing 60000000 $ \intent -> do
          modifyIORef' seen (<> [intent])
          pure (Right ())
        result `shouldBe` Right True
        observed <- readIORef seen
        length observed `shouldBe` 1
        forM_ observed $ \intent -> do
          awsAdminPermitIntentAction intent `shouldBe` RevokeOperatorMaterial
          awsAdminPermitIntentOperationId intent `shouldNotBe` awsAdminPermitIntentOperationId retained
          awsAdminPermitIntentGeneration intent `shouldBe` awsAdminPermitIntentGeneration retained
  it "refuses an unobservable reserved operation before the coordinator" $ do
    called <- newIORef False
    let client =
          mkAwsAdminProvisionerClient
            (\_ -> pure (Right (AwsAdminProvisioningUnavailable "fixture unavailable")))
    result <- resumePendingHarnessCredentialOperation client lineageParameters iamParameters Nothing 4000000 $ \_ -> do
      writeIORef called True
      pure (Right ())
    result `shouldSatisfy` either (const True) (const False)
    readIORef called `shouldReturn` False
  it "refuses a neighboring retained operation before the coordinator" $ do
    called <- newIORef False
    let client = mkAwsAdminProvisionerClient $ \request -> pure $ case request of
          ObserveAwsAdminProviderCredentialOperation -> Right (AwsAdminProviderCredentialOperationObserved (Just "fixture/foreign-operation"))
          ObserveAwsAdminProvisioning _ ->
            Right
              ( AwsAdminProvisioningObserved
                  (lineageObservation AwsAdminProvisionerPrepared permitIntent Nothing Nothing)
              )
          _ -> Right (AwsAdminProvisioningRefused "unexpected request")
    result <- resumePendingHarnessCredentialOperation client lineageParameters iamParameters Nothing 4000000 $ \_ -> do
      writeIORef called True
      pure (Right ())
    result `shouldSatisfy` either (const True) (const False)
    readIORef called `shouldReturn` False
  it "preserves recovery failure instead of admitting a fresh lineage" $ do
    original <- resolveLineageFixture HarnessCredentialRevoke Nothing Nothing
    let retained = submittedLineageIntent original
        operation = operatorMaterialOperationIdText (awsAdminPermitIntentOperationId retained)
        client = mkAwsAdminProvisionerClient $ \request -> pure $ case request of
          ObserveAwsAdminProviderCredentialOperation -> Right (AwsAdminProviderCredentialOperationObserved (Just operation))
          ObserveAwsAdminProvisioning _ ->
            Right
              ( AwsAdminProvisioningObserved
                  (lineageObservation AwsAdminProvisionerPrepared retained Nothing Nothing)
              )
          _ -> Right (AwsAdminProvisioningRefused "unexpected request")
    resumePendingHarnessCredentialOperation
      client
      lineageParameters
      iamParameters
      Nothing
      4000000
      (\_ -> pure (Left "fixture coordinator refusal"))
      `shouldReturn` Left "fixture coordinator refusal"
  it "separates invocations, substrates and install/revoke slots" $ do
    let otherNonce = must (mkHarnessCredentialLineage "all" (ByteString.replicate 32 2))
        otherSubstrate = must (mkHarnessCredentialLineage "aws-substrate-all" (ByteString.replicate 32 1))
    harnessCredentialSlotScope lineageFixture HarnessCredentialInstall
      `shouldNotBe` harnessCredentialSlotScope otherNonce HarnessCredentialInstall
    harnessCredentialSlotScope lineageFixture HarnessCredentialInstall
      `shouldNotBe` harnessCredentialSlotScope otherSubstrate HarnessCredentialInstall
    harnessCredentialSlotOperationId lineageFixture HarnessCredentialInstall
      `shouldNotBe` harnessCredentialSlotOperationId lineageFixture HarnessCredentialRevoke
  it "refuses a malformed lineage without effects" $ do
    mkHarnessCredentialLineage "" (ByteString.replicate 32 1)
      `shouldSatisfy` either (const True) (const False)
    mkHarnessCredentialLineage "all" "short nonce" `shouldSatisfy` either (const True) (const False)
  it "installs an absent Target under the fresh invocation slot" $ do
    resolved <- resolveLineageFixture HarnessCredentialInstall Nothing Nothing
    let intent = submittedLineageIntent resolved
    awsAdminPermitIntentAction intent `shouldBe` InstallOperatorMaterial
    credentialGenerationValue (awsAdminPermitIntentGeneration intent) `shouldBe` 1
  it "rotates a present Target without using its generation as the slot index" $ do
    resolved <- resolveLineageFixture HarnessCredentialInstall (Just (lineageMetadata 6)) Nothing
    let intent = submittedLineageIntent resolved
    awsAdminPermitIntentAction intent `shouldBe` RotateOperatorMaterial
    credentialGenerationValue (awsAdminPermitIntentGeneration intent) `shouldBe` 7
    operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent)
      `shouldBe` must (harnessCredentialSlotOperationId lineageFixture HarnessCredentialInstall)
  it "uses the same revoke slot before and after the Target tombstone" $ do
    present <- resolveLineageFixture HarnessCredentialRevoke (Just (lineageMetadata 6)) Nothing
    absent <- resolveLineageFixture HarnessCredentialRevoke Nothing Nothing
    let presentIntent = submittedLineageIntent present
        absentIntent = submittedLineageIntent absent
    awsAdminPermitIntentOperationId presentIntent
      `shouldBe` awsAdminPermitIntentOperationId absentIntent
    credentialGenerationValue (awsAdminPermitIntentGeneration presentIntent) `shouldBe` 6
  it "resumes the retained revoke's actual generation when the Target is absent" $ do
    initialResolution <-
      resolveLineageFixture HarnessCredentialRevoke (Just (lineageMetadata 6)) Nothing
    let intent = submittedLineageIntent initialResolution
    resumed <-
      resolveLineageFixture
        HarnessCredentialRevoke
        Nothing
        (Just (lineageObservation AwsAdminProvisionerPrepared intent Nothing Nothing))
    resumed `shouldBe` Right (SubmitHarnessCredentialIntent intent)
  it "renews an expired revoke without changing its slot or generation" $ do
    initialResolution <-
      resolveLineageFixture HarnessCredentialRevoke (Just (lineageMetadata 6)) Nothing
    let retained = submittedLineageIntent initialResolution
        parameters = lineageParameters {genesisIntentDeadline = authorityTimeFromMicros 120000000}
    renewed <-
      resolveHarnessCredentialSlot
        (lineageClient (Just (lineageObservation AwsAdminProvisionerPrepared retained Nothing Nothing)))
        parameters
        iamParameters
        lineageFixture
        HarnessCredentialRevoke
        Nothing
        60000000
    let intent = submittedLineageIntent renewed
    awsAdminPermitIntentGeneration intent `shouldBe` awsAdminPermitIntentGeneration retained
    awsAdminPermitIntentOperationId intent `shouldBe` awsAdminPermitIntentOperationId retained
    awsAdminPermitIntentDeadline intent `shouldBe` genesisIntentDeadline parameters
  it "rejects a foreign operation returned for the slot" $ do
    resolved <-
      resolveLineageFixture
        HarnessCredentialInstall
        Nothing
        (Just (lineageObservation AwsAdminProvisionerPrepared permitIntent Nothing Nothing))
    resolved `shouldBe` Left HarnessCredentialForeignOperation
  it "rejects a foreign challenge even when its canonical intent matches" $ do
    initialResolution <- resolveLineageFixture HarnessCredentialRevoke Nothing Nothing
    let intent = submittedLineageIntent initialResolution
        observation = lineageObservation AwsAdminProvisionerPrepared intent Nothing Nothing
        foreignObservation =
          observation
            { awsAdminObservedChallenge =
                (awsAdminObservedChallenge observation)
                  { awsAdminChallengeOperationId = "foreign-operation"
                  }
            }
    resolved <- resolveLineageFixture HarnessCredentialRevoke Nothing (Just foreignObservation)
    resolved `shouldBe` Left HarnessCredentialForeignOperation
  it "preserves a Target that advanced beyond an unfinished revoke" $ do
    initialResolution <-
      resolveLineageFixture HarnessCredentialRevoke (Just (lineageMetadata 6)) Nothing
    let intent = submittedLineageIntent initialResolution
    resolved <-
      resolveLineageFixture
        HarnessCredentialRevoke
        (Just (lineageMetadata 7))
        (Just (lineageObservation AwsAdminProvisionerPrepared intent Nothing Nothing))
    resolved `shouldBe` Left HarnessCredentialTargetGenerationMismatch
  it "requires a completed revoke's receipt, and accepts its absent Target" $ do
    (intent, permit, receipt) <- completedLineageRevoke
    resolved <-
      resolveLineageFixture
        HarnessCredentialRevoke
        Nothing
        (Just (lineageObservation AwsAdminProvisionerCompleted intent (Just permit) (Just receipt)))
    resolved `shouldBe` Right (HarnessCredentialRevocationAlreadyProven receipt)
  it "refuses a Target still observable after a completed revoke receipt" $ do
    (intent, permit, receipt) <- completedLineageRevoke
    resolved <-
      resolveLineageFixture
        HarnessCredentialRevoke
        (Just (lineageMetadata 1))
        (Just (lineageObservation AwsAdminProvisionerCompleted intent (Just permit) (Just receipt)))
    resolved `shouldBe` Left HarnessCredentialRevokedTargetStillPresent
  it "refuses a completed operation with no receipt" $ do
    (intent, permit, _) <- completedLineageRevoke
    resolved <-
      resolveLineageFixture
        HarnessCredentialRevoke
        Nothing
        (Just (lineageObservation AwsAdminProvisionerCompleted intent (Just permit) Nothing))
    resolved `shouldBe` Left HarnessCredentialCompletedReceiptInvalid
  it "refuses a completed install receipt in the revoke slot" $ do
    (intent, permit, _) <- completedLineageRevoke
    installedPermit <- authorizedPermitFor permitIntent
    world <- newScriptedAwsAdminWorld (initialAwsAdminExecutionJournal installedPermit) [] Nothing
    installed <-
      runScriptedAwsAdminPermit
        world
        installedPermit
        (scriptedTargetReceipt "vault:v1:lineage" permitIntent)
    resolved <-
      resolveLineageFixture
        HarnessCredentialRevoke
        Nothing
        (Just (lineageObservation AwsAdminProvisionerCompleted intent (Just permit) (Just (must installed))))
    resolved `shouldBe` Left HarnessCredentialCompletedReceiptKindMismatch
  it "never replays a completed install after its Target vanished" $ do
    initial <- resolveLineageFixture HarnessCredentialInstall Nothing Nothing
    let intent = submittedLineageIntent initial
    permit <- authorizedPermitFor intent
    world <- newScriptedAwsAdminWorld (initialAwsAdminExecutionJournal permit) [] Nothing
    installed <-
      runScriptedAwsAdminPermit world permit (scriptedTargetReceipt "vault:v1:lineage" intent)
    resolved <-
      resolveLineageFixture
        HarnessCredentialInstall
        Nothing
        (Just (lineageObservation AwsAdminProvisionerCompleted intent (Just permit) (Just (must installed))))
    resolved `shouldBe` Left HarnessCredentialInstalledTargetMissing
  it "recovers the exact completed install when its Target receipt is still current" $ do
    (intent, permit, receipt, metadata) <- completedLineageInstall
    result <-
      resolveLineageFixture
        HarnessCredentialInstall
        (Just metadata)
        (Just (lineageObservation AwsAdminProvisionerCompleted intent (Just permit) (Just receipt)))
    result `shouldBe` Right (SubmitHarnessCredentialIntent intent)
  it "refuses a different commitment even at the completed install's generation" $ do
    (intent, permit, receipt, metadata) <- completedLineageInstall
    let changed = metadata {targetMaterialObservedCommitment = "vault:v1:foreign"}
    result <-
      resolveLineageFixture
        HarnessCredentialInstall
        (Just changed)
        (Just (lineageObservation AwsAdminProvisionerCompleted intent (Just permit) (Just receipt)))
    result `shouldBe` Left HarnessCredentialTargetGenerationMismatch
  it "refuses another operation's signed permit beside an otherwise valid receipt" $ do
    (intent, _, receipt) <- completedLineageRevoke
    foreignPermit <- authorizedPermitFor revocationPermitIntent
    result <-
      resolveLineageFixture
        HarnessCredentialRevoke
        Nothing
        (Just (lineageObservation AwsAdminProvisionerCompleted intent (Just foreignPermit) (Just receipt)))
    result `shouldBe` Left HarnessCredentialCompletedReceiptInvalid
  it "a new lineage heals an old completed install with an absent Target through a fresh operation" $ do
    prior <- resolveLineageFixture HarnessCredentialInstall Nothing Nothing
    let previous = submittedLineageIntent prior
        freshLineage = must (mkHarnessCredentialLineage "all" (ByteString.replicate 32 3))
    current <-
      resolveHarnessCredentialSlot
        (lineageClient Nothing)
        lineageParameters
        iamParameters
        freshLineage
        HarnessCredentialInstall
        Nothing
        4000000
    awsAdminPermitIntentOperationId (submittedLineageIntent current)
      `shouldNotBe` awsAdminPermitIntentOperationId previous
  it "keeps an unobservable Authority distinct from an absent operation" $ do
    let unavailable = mkAwsAdminProvisionerClient (\_ -> pure (Left AwsAdminProvisionerClientUnexpectedResponse))
    result <-
      resolveHarnessCredentialSlot
        unavailable
        lineageParameters
        iamParameters
        lineageFixture
        HarnessCredentialRevoke
        Nothing
        4000000
    result `shouldBe` Left HarnessCredentialObservationUnavailable

lineageFixture :: HarnessCredentialLineage
lineageFixture = must (mkHarnessCredentialLineage "all" (ByteString.replicate 32 1))

lineageParameters :: GenesisAwsAdminIntentParameters
lineageParameters =
  GenesisAwsAdminIntentParameters
    iamParameters
    imageDigest
    "home"
    "http://lifecycle-authority.lifecycle-authority.svc:8600"
    targetAgent
    deadline

lineageMetadata :: Natural -> TargetMaterialObservation
lineageMetadata value =
  TargetMaterialObservation
    value
    1
    "vault:v1:lineage"
    "lineage-owner"
    1
    (Text.replicate 64 "a")
    (Text.replicate 64 "b")
    "lineage-pod"
    imageDigest

submittedLineageIntent
  :: Either HarnessCredentialResolutionError HarnessCredentialResolution -> AwsAdminPermitIntent
submittedLineageIntent result = case must result of
  SubmitHarnessCredentialIntent intent -> intent
  HarnessCredentialRevocationAlreadyProven _ -> error "expected a submitted lineage intent"
  RepairHarnessCredentialTarget _ -> error "expected an ordinary submitted lineage intent"

resolveLineageFixture
  :: HarnessCredentialSlot
  -> Maybe TargetMaterialObservation
  -> Maybe AwsAdminProvisionerObservation
  -> IO (Either HarnessCredentialResolutionError HarnessCredentialResolution)
resolveLineageFixture slot observed retained =
  resolveHarnessCredentialSlot
    (lineageClient retained)
    lineageParameters
    iamParameters
    lineageFixture
    slot
    observed
    4000000

lineageClient :: Maybe AwsAdminProvisionerObservation -> AwsAdminProvisionerClient IO
lineageClient observed = mkAwsAdminProvisionerClient call
 where
  call request = pure $ case request of
    ObserveAwsAdminProviderCredentialRecovery -> Right (AwsAdminProviderCredentialRecoveryObserved ProviderCredentialRecoveryIdle)
    ObserveAwsAdminProvisioning _ -> case observed of
      Nothing -> Left (AwsAdminProvisionerClientRefused "operation-not-found")
      Just value -> Right (AwsAdminProvisioningObserved value)
    _ -> Left AwsAdminProvisionerClientUnexpectedResponse

lineageObservation
  :: AwsAdminProvisionerPhase
  -> AwsAdminPermitIntent
  -> Maybe SignedAwsAdminPermit
  -> Maybe AwsAdminWorkerReceipt
  -> AwsAdminProvisionerObservation
lineageObservation phase intent permit receipt =
  AwsAdminProvisionerObservation
    { awsAdminObservedChallenge =
        coordinatorChallenge
          { awsAdminChallengeOperationId =
              operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent)
          , awsAdminChallengeCanonicalIntent = encodeAwsAdminPermitIntent intent
          }
    , awsAdminObservedPhase = phase
    , awsAdminObservedPermit = encodeSignedAwsAdminPermit <$> permit
    , awsAdminObservedReceipt = encodeAwsAdminWorkerReceipt <$> receipt
    }

completedLineageRevoke :: IO (AwsAdminPermitIntent, SignedAwsAdminPermit, AwsAdminWorkerReceipt)
completedLineageRevoke = do
  initialResolution <- resolveLineageFixture HarnessCredentialRevoke Nothing Nothing
  let intent = submittedLineageIntent initialResolution
  permit <- authorizedPermitFor intent
  (revoked, _) <- runRevocationScriptFor intent RevocationSucceeds
  pure (intent, permit, must revoked)

completedLineageInstall
  :: IO (AwsAdminPermitIntent, SignedAwsAdminPermit, AwsAdminWorkerReceipt, TargetMaterialObservation)
completedLineageInstall = do
  initial <- resolveLineageFixture HarnessCredentialInstall Nothing Nothing
  let intent = submittedLineageIntent initial
  permit <- authorizedPermitFor intent
  world <- newScriptedAwsAdminWorld (initialAwsAdminExecutionJournal permit) [] Nothing
  installed <-
    runScriptedAwsAdminPermit world permit (scriptedTargetReceipt "vault:v1:lineage" intent)
  let metadata =
        (lineageMetadata (credentialGenerationValue (awsAdminPermitIntentGeneration intent)))
          { targetMaterialObservedRequestDigest =
              targetValueDigestText (awsAdminPermitIntentRequestDigest intent)
          , targetMaterialObservedActionDigest = targetValueDigestText receiptDigest
          , targetMaterialObservedPodUid = "credential-provisioner-pod-1"
          }
  pure (intent, permit, must installed, metadata)

awsAdminTargetAgentRevocationCases :: SuiteBuilder ()
awsAdminTargetAgentRevocationCases = describe "Sprint 5.51 permit-verified Agent revocation" $ do
  it "deletes the exact generation and independently reads metadata absent" $ do
    permit <- authorizedPermitFor revocationPermitIntent
    (result, events) <- runAgentLane permit id id CallerCredentialProvisioner AgentLaneSucceeds
    result `shouldBe` agentLaneAbsent permit
    events `shouldBe` ["metadata-read", "metadata-delete-all-versions", "metadata-read"]
  it "replays an absent generation without another delete" $ do
    permit <- authorizedPermitFor revocationPermitIntent
    (result, events) <- runAgentLane permit id id CallerCredentialProvisioner AgentLaneAlreadyAbsent
    result `shouldBe` agentLaneAbsent permit
    events `shouldBe` ["metadata-read"]
  it "preserves a newer generation" $ do
    permit <- authorizedPermitFor revocationPermitIntent
    (result, events) <- runAgentLane permit id id CallerCredentialProvisioner AgentLaneNewGeneration
    result `shouldBe` AwsAdminTargetRevokeRefused AwsAdminTargetRevokeGenerationRefused
    events `shouldBe` ["metadata-read"]
  mapM_
    agentFaultCase
    [ (AgentLaneReadUnavailable, AwsAdminTargetRevokeUnavailable, ["metadata-read"])
    , (AgentLaneDeleteNotApplied, AwsAdminTargetRevokeUnavailable, mutationTrace)
    , (AgentLaneReadBackUnavailable, AwsAdminTargetRevokeUnavailable, mutationTrace)
    ,
      ( AgentLaneDeleteResponseLost
      , AwsAdminTargetGenerationAbsent 1 "harness-revocation-permit"
      , mutationTrace
      )
    ,
      ( AgentLaneExpiresAfterRead
      , AwsAdminTargetRevokeRefused AwsAdminTargetRevokePermitRefused
      , ["metadata-read"]
      )
    ]
  mapM_
    invalidRequestCase
    [
      ( "different target"
      , \request -> request {awsAdminTargetRevokeTarget = TargetAwsCredential AwsAuthorityBackupStore}
      , AwsAdminTargetRevokeTargetRefused
      )
    ,
      ( "different generation"
      , \request -> request {awsAdminTargetRevokeGeneration = 2}
      , AwsAdminTargetRevokeGenerationRefused
      )
    ,
      ( "different operation"
      , \request -> request {awsAdminTargetRevokeOperation = "foreign-operation"}
      , AwsAdminTargetRevokeOperationRefused
      )
    ,
      ( "different Pod name"
      , \request -> request {awsAdminTargetRevokePodName = "foreign-pod"}
      , AwsAdminTargetRevokePodRefused
      )
    ,
      ( "different Pod UID"
      , \request -> request {awsAdminTargetRevokePodUid = "foreign-uid"}
      , AwsAdminTargetRevokePodRefused
      )
    ,
      ( "invalid permit signature"
      , \request -> request {awsAdminTargetRevokePermit = "invalid signed permit"}
      , AwsAdminTargetRevokePermitRefused
      )
    ]
  mapM_
    invalidTrustCase
    [
      ( "wrong signer generation"
      , \verification -> verification {awsAdminTargetRevokeSignerGeneration = 8}
      , AwsAdminTargetRevokePermitRefused
      )
    ,
      ( "expired permit"
      , \verification -> verification {awsAdminTargetRevokeCurrentTime = pure (Right deadline)}
      , AwsAdminTargetRevokePermitRefused
      )
    ,
      ( "different Agent rollout"
      , \verification -> verification {awsAdminTargetRevokeLocalAgent = renewalTargetAgent}
      , AwsAdminTargetRevokeAgentRefused
      )
    ]
  it "refuses an unavailable clock before metadata access" $ do
    permit <- authorizedPermitFor revocationPermitIntent
    (result, events) <-
      runAgentLane
        permit
        id
        (\verification -> verification {awsAdminTargetRevokeCurrentTime = pure (Left "clock unavailable")})
        CallerCredentialProvisioner
        AgentLaneSucceeds
    result `shouldBe` AwsAdminTargetRevokeUnavailable
    events `shouldBe` []
  it "rejects a well-formed permit with a false Ed25519 signature before Vault" $ do
    permit <- authorizedPermitFor revocationPermitIntent
    let forged =
          withSomeSignedAwsAdminPermit
            ( must
                ( mkSomeSignedAwsAdminPermit
                    7
                    (signedAwsAdminPermitIntent permit)
                    (signedAwsAdminPermitBinding permit)
                    (ByteString.replicate 64 0)
                )
            )
            id
    (result, events) <- runAgentLane forged id id CallerCredentialProvisioner AgentLaneSucceeds
    result `shouldBe` AwsAdminTargetRevokeRefused AwsAdminTargetRevokePermitRefused
    events `shouldBe` []
  it "refuses a valid install permit before metadata access" $ do
    permit <- authorizedPermitFor permitIntent
    (result, events) <- runAgentLane permit id id CallerCredentialProvisioner AgentLaneSucceeds
    result `shouldBe` AwsAdminTargetRevokeRefused AwsAdminTargetRevokeActionRefused
    events `shouldBe` []
  it "refuses a signed LongLived class before metadata access" $ do
    let intent =
          agentLaneIntent
            TlsRetentionStoreCredential
            RotateOperatorMaterial
            (TargetAwsCredential AwsTlsRetentionStore)
            ( must
                ( mkTlsRetentionIamParameters
                    (fixtureAwsRegion FixtureUsEast1)
                    "fixture-tls-retention"
                    ["public-edge-tls/home-local/certificates"]
                )
            )
    permit <- authorizedPermitFor intent
    (result, events) <- runAgentLane permit id id CallerCredentialProvisioner AgentLaneSucceeds
    result `shouldBe` AwsAdminTargetRevokeRefused AwsAdminTargetRevokeClassRefused
    events `shouldBe` []
  it "refuses even a valid RunScoped revoke on this Operational-only lane" $ do
    let intent =
          agentLaneIntent
            AwsRunCertManagerDns01Credential
            RevokeOperatorMaterial
            (TargetAwsCredential AwsRunCertManagerDns01)
            (must (mkAwsRunDns01IamParameters (fixtureAwsRegion FixtureUsEast1) "Z123FIXTURE"))
    permit <- authorizedPermitFor intent
    (result, events) <- runAgentLane permit id id CallerCredentialProvisioner AgentLaneSucceeds
    result `shouldBe` AwsAdminTargetRevokeRefused AwsAdminTargetRevokeClassRefused
    events `shouldBe` []
  it "refuses every other authenticated caller even if the transport topology were widened" $ do
    permit <- authorizedPermitFor revocationPermitIntent
    forM_ (filter (/= CallerCredentialProvisioner) allCallerPrincipals) $ \caller -> do
      (result, events) <- runAgentLane permit id id caller AgentLaneSucceeds
      result `shouldBe` AwsAdminTargetRevokeRefused AwsAdminTargetRevokeCallerRefused
      events `shouldBe` []
  it "admits only the Provisioner principal in the authenticated route topology" $
    forM_ allCallerPrincipals $ \caller ->
      callerMayCallRoute caller TargetAwsAdminCredentialRevoke
        `shouldBe` (caller == CallerCredentialProvisioner)
  it "accepts only a successful response bound to this exact permit and generation" $ do
    permit <- authorizedPermitFor revocationPermitIntent
    let response status value = ControlPlaneResponse status (LazyByteString.toStrict (encodeControlPlaneResponse value))
    decodeAwsAdminTargetRevokeResponse permit (response 200 (agentLaneAbsent permit))
      `shouldBe` Right "aws-admin:harness-revocation-permit:target-absent"
    forM_
      [ response 200 (AwsAdminTargetGenerationAbsent 2 "harness-revocation-permit")
      , response 200 (AwsAdminTargetGenerationAbsent 1 "foreign-permit")
      , response 503 (agentLaneAbsent permit)
      , response 200 AwsAdminTargetRevokeUnavailable
      , ControlPlaneResponse 200 "unrecognised response"
      ]
      $ \invalid ->
        decodeAwsAdminTargetRevokeResponse permit invalid
          `shouldBe` Left AwsAdminTargetRevokeResponseInvalid
  it "never counts a different observed generation as independent revoke absence" $ do
    let metadata value =
          TargetMaterialObservation
            value
            1
            "vault:v1:fixture"
            "owner"
            1
            (Text.replicate 64 "a")
            (Text.replicate 64 "b")
            "pod"
            imageDigest
        target = TargetAwsCredential AwsLifecycleProvider
    forM_
      [(1, AwsAdminTargetObservationGenerationMismatch), (3, AwsAdminTargetObservationGenerationAdvanced)]
      $ \(observed, expected) ->
        classifyAwsAdminTargetReadBack RevokeOperatorMaterial target 2 (metadata observed)
          `shouldBe` Left expected
    classifyAwsAdminTargetReadBack InstallOperatorMaterial target 2 (metadata 1)
      `shouldBe` Right Nothing
 where
  mutationTrace = ["metadata-read", "metadata-delete-all-versions", "metadata-read"]
  agentFaultCase (fault, expected, trace) = it ("handles " ++ show fault ++ " by read-back") $ do
    permit <- authorizedPermitFor revocationPermitIntent
    (result, events) <- runAgentLane permit id id CallerCredentialProvisioner fault
    result `shouldBe` expected
    events `shouldBe` trace
  invalidRequestCase (label, change, expected) = it ("refuses " ++ label ++ " before Vault") $ do
    permit <- authorizedPermitFor revocationPermitIntent
    (result, events) <- runAgentLane permit change id CallerCredentialProvisioner AgentLaneSucceeds
    result `shouldBe` AwsAdminTargetRevokeRefused expected
    events `shouldBe` []
  invalidTrustCase (label, change, expected) = it ("refuses " ++ label ++ " before Vault") $ do
    permit <- authorizedPermitFor revocationPermitIntent
    (result, events) <- runAgentLane permit id change CallerCredentialProvisioner AgentLaneSucceeds
    result `shouldBe` AwsAdminTargetRevokeRefused expected
    events `shouldBe` []

data AgentLaneFault
  = AgentLaneSucceeds
  | AgentLaneAlreadyAbsent
  | AgentLaneNewGeneration
  | AgentLaneReadUnavailable
  | AgentLaneDeleteNotApplied
  | AgentLaneReadBackUnavailable
  | AgentLaneDeleteResponseLost
  | AgentLaneExpiresAfterRead
  deriving (Eq, Show)

runAgentLane
  :: SignedAwsAdminPermit
  -> (AwsAdminTargetRevokeRequest -> AwsAdminTargetRevokeRequest)
  -> (AwsAdminTargetRevokeVerification IO -> AwsAdminTargetRevokeVerification IO)
  -> CallerPrincipal
  -> AgentLaneFault
  -> IO (AwsAdminTargetRevokeResponse, [Text])
runAgentLane permit changeRequest changeVerification caller fault = do
  events <- newIORef []
  present <-
    newIORef
      ( case fault of
          AgentLaneAlreadyAbsent -> Nothing
          AgentLaneNewGeneration -> Just 2
          _ -> Just 1
      )
  expired <- newIORef False
  let note entry = modifyIORef' events (<> [entry])
      readMetadata = do
        note "metadata-read"
        value <- readIORef present
        writeIORef expired True
        pure $ case fault of
          AgentLaneReadUnavailable -> Left "metadata unavailable"
          AgentLaneReadBackUnavailable | value == Nothing -> Left "read-back unavailable"
          _ -> Right value
      destroyMetadata = do
        note "metadata-delete-all-versions"
        case fault of
          AgentLaneDeleteNotApplied -> pure (Left "delete failed")
          _ -> do
            writeIORef present Nothing
            pure (if fault == AgentLaneDeleteResponseLost then Left "response lost" else Right ())
      readClock = do
        hasRead <- readIORef expired
        pure
          ( Right
              (if fault == AgentLaneExpiresAfterRead && hasRead then deadline else authorityTimeFromMicros 4000000)
          )
      verification =
        changeVerification
          AwsAdminTargetRevokeVerification
            { awsAdminTargetRevokeSignerGeneration = 7
            , awsAdminTargetRevokePublicKey = manifestPublicKey
            , awsAdminTargetRevokeCurrentTime = readClock
            , awsAdminTargetRevokeLocalAgent = targetAgent
            }
      inner =
        AuthenticatedRoleHandler
          { authenticatedHandlerReadiness = noRoleReadinessContribution
          , authenticatedHandlerHandle = \_ _ _ -> pure Nothing
          }
      handler =
        awsAdminTargetRevokeAuthenticatedHandler
          verification
          (mkAwsAdminTargetRevokeBoundary readMetadata destroyMetadata)
          inner
  response <-
    authenticatedHandlerHandle
      handler
      (verifiedCallerSlotFixture caller 1)
      TargetAwsAdminCredentialRevoke
      ( LazyByteString.toStrict
          (encodeControlPlaneRequest (changeRequest (awsAdminTargetRevokeRequest permit)))
      )
  let decoded = case response of
        Nothing -> error "Agent revocation route was not handled"
        Just (status, bytes) ->
          let value = must (decodeControlPlaneResponse (64 * 1024) (LazyByteString.fromStrict bytes))
           in if status == agentResponseStatus value
                then value
                else error "Agent response status did not match its body"
  recorded <- readIORef events
  pure (decoded, recorded)
 where
  agentResponseStatus response = case response of
    AwsAdminTargetGenerationAbsent _ _ -> ReplyOk
    AwsAdminTargetRevokeRefused _ -> ReplyForbidden
    AwsAdminTargetRevokeUnavailable -> ReplyServiceUnavailable

agentLaneAbsent :: SignedAwsAdminPermit -> AwsAdminTargetRevokeResponse
agentLaneAbsent permit =
  AwsAdminTargetGenerationAbsent
    (credentialGenerationValue (awsAdminPermitIntentGeneration (signedAwsAdminPermitIntent permit)))
    (operatorMaterialPermitIdText (awsAdminPermitIntentPermitId (signedAwsAdminPermitIntent permit)))

agentLaneIntent
  :: AwsCredentialClass
  -> OperatorMaterialAction
  -> TargetSecretId
  -> CredentialIamParameters
  -> AwsAdminPermitIntent
agentLaneIntent credentialClass action target parameters =
  must
    ( mkNormalAwsAdminPermitIntent
        materialPermit
        parameters
        imageDigest
        "home"
        "http://lifecycle-authority.lifecycle-authority.svc:8600"
        prepared
    )
 where
  request =
    must
      ( mkAwsOperatorMaterialRequest
          credentialClass
          action
          (must (mkOperatorMaterialOperationId "agent-class-fixture"))
          generation
      )
  materialPermit =
    must
      ( mkOperatorMaterialPermit
          (must (mkOperatorMaterialPermitId "agent-class-permit"))
          request
          deadline
          Nothing
          "operator-signature"
      )
  prepared =
    must
      ( mkPreparedCredentialTargetObservation
          "agent-class-owner"
          1
          targetAgent
          target
          generation
          (operatorMaterialRequestDigest request)
          receiptDigest
          Nothing
          deadline
      )

awsAdminRevocationOrderCases :: SuiteBuilder ()
awsAdminRevocationOrderCases = describe "Sprint 5.51 IAM-first credential revocation" $ do
  it "destroys, waits and observes IAM absent before revoking and observing Target absent" $ do
    (result, events) <- runRevocationScript RevocationSucceeds
    fmap awsAdminWorkerReceiptKind result `shouldBe` Right AwsAdminRevoked
    events
      `shouldBe` [ DestroyIamIdentity
                 , WaitIamVisibility
                 , ObserveIamAbsence
                 , RevokeTargetGeneration
                 , ObserveTargetAbsence
                 ]
  mapM_
    failedGateCase
    [ (RevokeDestroyFails, AwsAdminIdentityDestroyFailed "destroy failed", [DestroyIamIdentity])
    ,
      ( RevokeVisibilityFails
      , AwsAdminVisibilityWaitFailed "visibility failed"
      , [DestroyIamIdentity, WaitIamVisibility]
      )
    ,
      ( RevokeIamUnobservable
      , AwsAdminIdentityAbsenceUnobservable "IAM unavailable"
      , [DestroyIamIdentity, WaitIamVisibility, ObserveIamAbsence]
      )
    ,
      ( RevokeIamStillPresent
      , AwsAdminIdentityStillPresent
      , [DestroyIamIdentity, WaitIamVisibility, ObserveIamAbsence]
      )
    ,
      ( RevokeTargetFails
      , AwsAdminTargetRevocationFailed "Target revoke failed"
      , beforeTarget ++ [RevokeTargetGeneration]
      )
    ,
      ( RevokeTargetUnobservable
      , AwsAdminTargetRevocationUnobservable "generation-advanced"
      , beforeTarget ++ [RevokeTargetGeneration, ObserveTargetAbsence]
      )
    ,
      ( RevokeTargetStillPresent
      , AwsAdminTargetGenerationStillPresent
      , beforeTarget ++ [RevokeTargetGeneration, ObserveTargetAbsence]
      )
    ]
  it "rejects every LongLived or retained credential revoke at request construction" $ do
    forM_ [minBound .. maxBound] checkClass
 where
  beforeTarget = [DestroyIamIdentity, WaitIamVisibility, ObserveIamAbsence]
  failedGateCase (fault, expected, expectedEvents) = it ("refuses " ++ show fault ++ " at its exact gate") $ do
    (result, events) <- runRevocationScript fault
    void result `shouldBe` Left expected
    events `shouldBe` expectedEvents
  checkClass credentialClass = do
    let request =
          mkAwsOperatorMaterialRequest
            credentialClass
            RevokeOperatorMaterial
            (must (mkOperatorMaterialOperationId "revoke-class-check"))
            generation
        accepted = either (const False) (const True) request
    accepted
      `shouldBe` (credentialClass `elem` [LifecycleProviderCredential, AwsRunCertManagerDns01Credential])

data RevocationScriptFault
  = RevocationSucceeds
  | RevokeDestroyFails
  | RevokeVisibilityFails
  | RevokeIamUnobservable
  | RevokeIamStillPresent
  | RevokeTargetFails
  | RevokeTargetUnobservable
  | RevokeTargetStillPresent
  deriving (Eq, Show)

data RevocationScriptEvent
  = DestroyIamIdentity
  | WaitIamVisibility
  | ObserveIamAbsence
  | RevokeTargetGeneration
  | ObserveTargetAbsence
  | UnexpectedRevocationEffect
  deriving (Eq, Show)

runRevocationScript
  :: RevocationScriptFault
  -> IO (Either AwsAdminExecutionError AwsAdminWorkerReceipt, [RevocationScriptEvent])
runRevocationScript = runRevocationScriptFor revocationPermitIntent

runRevocationScriptFor
  :: AwsAdminPermitIntent
  -> RevocationScriptFault
  -> IO (Either AwsAdminExecutionError AwsAdminWorkerReceipt, [RevocationScriptEvent])
runRevocationScriptFor intent fault = do
  permit <- authorizedPermitFor intent
  journal <- newIORef (initialAwsAdminExecutionJournal permit)
  events <- newIORef []
  let note entry = modifyIORef' events (<> [entry])
      journalBoundary =
        mkAwsAdminExecutionJournalBoundary
          (Right <$> readIORef journal)
          (\_ expected -> writeIORef journal expected >> pure (Right expected))
      iam =
        mkAwsAdminIamBoundary
          (note UnexpectedRevocationEffect >> pure (Right ()))
          (note UnexpectedRevocationEffect >> pure (AccessKeyInventoryObserved []))
          (\_ -> note UnexpectedRevocationEffect >> pure (Right ()))
          ( note UnexpectedRevocationEffect
              >> pure
                ( AwsAccessKeyCreated
                    (must (mkProvisionedAccessKeyId "REVOCATIONKEY"))
                    (must (mkCreatedAwsAccessKey "REVOCATIONKEY" "fixture-only-secret"))
                )
          )
          ( note DestroyIamIdentity
              >> pure (if fault == RevokeDestroyFails then Left "destroy failed" else Right ())
          )
          ( note ObserveIamAbsence
              >> pure
                ( if fault == RevokeIamUnobservable
                    then Left "IAM unavailable"
                    else Right (fault /= RevokeIamStillPresent)
                )
          )
          ( note WaitIamVisibility
              >> pure (if fault == RevokeVisibilityFails then Left "visibility failed" else Right ())
          )
      revokeTarget _ _ =
        note RevokeTargetGeneration
          >> pure
            (if fault == RevokeTargetFails then Left "Target revoke failed" else Right "Target tombstone receipt")
      observeTarget _ _ = do
        note ObserveTargetAbsence
        pure $ case fault of
          RevokeTargetUnobservable -> Left AwsAdminTargetObservationGenerationAdvanced
          RevokeTargetStillPresent -> Right (Just (scriptedTargetReceipt "vault:v1:retained" intent))
          _ -> Right Nothing
      delivery =
        mkAwsAdminDeliveryBoundary
          (\_ _ _ -> note UnexpectedRevocationEffect >> pure (Left AwsAdminTargetDeliveryRevokeRejected))
          revokeTarget
          observeTarget
  result <- executeAwsAdminPermit journalBoundary iam delivery permit
  recorded <- readIORef events
  pure (result, recorded)

revocationPermitIntent :: AwsAdminPermitIntent
revocationPermitIntent =
  must
    ( mkNormalAwsAdminPermitIntent
        revokePermit
        iamParameters
        imageDigest
        "home"
        "http://lifecycle-authority.lifecycle-authority.svc:8600"
        prepared
    )
 where
  request =
    must
      ( mkAwsOperatorMaterialRequest
          LifecycleProviderCredential
          RevokeOperatorMaterial
          (must (mkOperatorMaterialOperationId "harness-revocation-fixture"))
          generation
      )
  revokePermit =
    must
      ( mkOperatorMaterialPermit
          (must (mkOperatorMaterialPermitId "harness-revocation-permit"))
          request
          deadline
          Nothing
          "operator-signature"
      )
  prepared =
    must
      ( mkPreparedCredentialTargetObservation
          "revoke-owner-nonce"
          1
          targetAgent
          (TargetAwsCredential AwsLifecycleProvider)
          generation
          (operatorMaterialRequestDigest request)
          receiptDigest
          Nothing
          deadline
      )

-- | Sprint 4.108: a scripted world for 'executeAwsAdminPermit': the journal
-- cell, the account's access-key inventory, and the one Target generation the
-- permit installs into. 'scriptedWorldLog' records every effect in order.
data ScriptedAwsAdminWorld = ScriptedAwsAdminWorld
  { scriptedWorldJournal :: !(IORef AwsAdminExecutionJournal)
  , scriptedWorldKeys :: !(IORef [ProvisionedAccessKeyId])
  , scriptedWorldTarget :: !(IORef (Maybe TargetWorkerReceipt))
  , scriptedWorldMinted :: !(IORef Int)
  , scriptedWorldLog :: !(IORef [Text])
  }

newScriptedAwsAdminWorld
  :: AwsAdminExecutionJournal
  -> [ProvisionedAccessKeyId]
  -> Maybe TargetWorkerReceipt
  -> IO ScriptedAwsAdminWorld
newScriptedAwsAdminWorld journal keys target =
  ScriptedAwsAdminWorld
    <$> newIORef journal
    <*> newIORef keys
    <*> newIORef target
    <*> newIORef 0
    <*> newIORef []

scriptedTargetReceipt :: Text -> AwsAdminPermitIntent -> TargetWorkerReceipt
scriptedTargetReceipt commitment intent =
  must
    ( mkTargetWorkerReceiptProjection
        (awsAdminPermitIntentTarget intent)
        (awsAdminPermitIntentGeneration intent)
        1
        commitment
        (awsAdminPermitIntentRequestDigest intent)
        receiptDigest
        "credential-provisioner-pod-1"
        (awsAdminPermitIntentImageDigest intent)
    )

-- | Drive the production execution algebra over the scripted world. A delivery
-- stores and returns @deliveredReceipt@; an observation reports whatever the
-- Target currently holds, whoever wrote it.
runScriptedAwsAdminPermit
  :: ScriptedAwsAdminWorld
  -> SignedAwsAdminPermit
  -> TargetWorkerReceipt
  -> IO (Either AwsAdminExecutionError AwsAdminWorkerReceipt)
runScriptedAwsAdminPermit world permit deliveredReceipt =
  executeAwsAdminPermit journalBoundary iamBoundary deliveryBoundary permit
 where
  record entry = modifyIORef' (scriptedWorldLog world) (<> [entry])
  journalBoundary =
    mkAwsAdminExecutionJournalBoundary
      (Right <$> readIORef (scriptedWorldJournal world))
      ( \current next -> do
          stored <- readIORef (scriptedWorldJournal world)
          if stored == current
            then writeIORef (scriptedWorldJournal world) next >> pure (Right next)
            else pure (Left "scripted journal compare-and-swap conflict")
      )
  iamBoundary =
    mkAwsAdminIamBoundary
      (pure (Right ()))
      (AccessKeyInventoryObserved . sort <$> readIORef (scriptedWorldKeys world))
      ( \keyId -> do
          record "delete-key"
          modifyIORef' (scriptedWorldKeys world) (filter (/= keyId))
          pure (Right ())
      )
      ( do
          minted <- readIORef (scriptedWorldMinted world)
          writeIORef (scriptedWorldMinted world) (minted + 1)
          let raw = "SCRIPTEDKEY" <> Text.pack (show minted)
              keyId = must (mkProvisionedAccessKeyId raw)
          record "create-key"
          modifyIORef' (scriptedWorldKeys world) (<> [keyId])
          pure (AwsAccessKeyCreated keyId (must (mkCreatedAwsAccessKey raw "one-time-secret")))
      )
      (pure (Right ()))
      (pure (Right True))
      (pure (Right ()))
  deliveryBoundary =
    mkAwsAdminDeliveryBoundary
      ( \_ _ _ -> do
          record "deliver"
          writeIORef (scriptedWorldTarget world) (Just deliveredReceipt)
          pure (Right deliveredReceipt)
      )
      (\_ _ -> pure (Right "revoked"))
      ( \_ _ -> do
          record "observe"
          Right <$> readIORef (scriptedWorldTarget world)
      )

workerReceiptActionCases :: SuiteBuilder ()
workerReceiptActionCases =
  describe "Sprint 6.5 receipt kind binds the signed action" $
    forM_ [InstallOperatorMaterial, RotateOperatorMaterial, RevokeOperatorMaterial] actionCases
 where
  actionCases action = forM_ [1, 2] (receiptCase action)
  receiptCase action kind = it (show action ++ " with terminal kind " ++ show kind) $ do
    let intent = receiptActionIntent action
        receipt = must (decodeAwsAdminWorkerReceipt (workerReceiptBytesForKind intent kind))
        expectedKind = case action of
          InstallOperatorMaterial -> 1
          RotateOperatorMaterial -> 1
          RevokeOperatorMaterial -> 2
    permit <- authorizedPermitFor intent
    if kind == expectedKind
      then do
        validateAwsAdminWorkerReceiptForPermit permit receipt `shouldBe` Right ()
        commitAwsAdminCompleted receipt (AwsAdminAuthorityAuthorized permit)
          `shouldBe` Right (AwsAdminAuthorityCompleted permit receipt)
      else do
        validateAwsAdminWorkerReceiptForPermit permit receipt
          `shouldBe` Left AwsAdminWorkerReceiptInvalid
        commitAwsAdminCompleted receipt (AwsAdminAuthorityAuthorized permit)
          `shouldBe` Left (AwsAdminAuthorityReceiptInvalid AwsAdminWorkerReceiptInvalid)

receiptActionIntent :: OperatorMaterialAction -> AwsAdminPermitIntent
receiptActionIntent action =
  must
    ( mkNormalAwsAdminPermitIntent
        permit
        iamParameters
        imageDigest
        "home"
        "http://lifecycle-authority.lifecycle-authority.svc:8600"
        prepared
    )
 where
  request =
    must
      ( mkAwsOperatorMaterialRequest
          LifecycleProviderCredential
          action
          (must (mkOperatorMaterialOperationId "receipt-action-fixture"))
          generation
      )
  permit =
    must
      ( mkOperatorMaterialPermit
          (must (mkOperatorMaterialPermitId "receipt-action-fixture"))
          request
          deadline
          Nothing
          "operator-signature"
      )
  prepared =
    must
      ( mkPreparedCredentialTargetObservation
          "receipt-action-owner"
          1
          targetAgent
          (TargetAwsCredential AwsLifecycleProvider)
          generation
          (operatorMaterialRequestDigest request)
          receiptDigest
          Nothing
          deadline
      )

data WireAwsAdminWorkerReceiptFixture = WireAwsAdminWorkerReceiptFixture
  { fixtureWorkerReceiptVersion :: !Word16
  , fixtureWorkerReceiptKind :: !Word8
  , fixtureWorkerReceiptPermitId :: !Text
  , fixtureWorkerReceiptRequestDigest :: !Text
  , fixtureWorkerReceiptTarget :: !TargetSecretId
  , fixtureWorkerReceiptGeneration :: !Natural
  , fixtureWorkerReceiptTargetReadBack :: !ByteString.ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

canonicalRevokedWorkerReceiptBytes :: ByteString.ByteString
canonicalRevokedWorkerReceiptBytes = wireWorkerReceiptFixtureBytes 1 2

installedWorkerReceiptBytes :: AwsAdminPermitIntent -> ByteString.ByteString
installedWorkerReceiptBytes intent = workerReceiptBytesForKind intent 1

workerReceiptBytesForKind :: AwsAdminPermitIntent -> Word8 -> ByteString.ByteString
workerReceiptBytesForKind intent receiptKind =
  wireWorkerReceiptBytes
    receiptKind
    ( encodeTargetWorkerReceipt
        ( must
            ( mkTargetWorkerReceiptProjection
                (awsAdminPermitIntentTarget intent)
                (awsAdminPermitIntentGeneration intent)
                1
                "vault:v1:fixture-worker-commitment"
                (awsAdminPermitIntentRequestDigest intent)
                receiptDigest
                "credential-provisioner-pod-1"
                (awsAdminPermitIntentImageDigest intent)
            )
        )
    )
 where
  wireWorkerReceiptBytes kind targetReadBack =
    LazyByteString.toStrict
      ( serialise
          WireAwsAdminWorkerReceiptFixture
            { fixtureWorkerReceiptVersion = 1
            , fixtureWorkerReceiptKind = kind
            , fixtureWorkerReceiptPermitId =
                operatorMaterialPermitIdText (awsAdminPermitIntentPermitId intent)
            , fixtureWorkerReceiptRequestDigest =
                targetValueDigestText (awsAdminPermitIntentRequestDigest intent)
            , fixtureWorkerReceiptTarget = awsAdminPermitIntentTarget intent
            , fixtureWorkerReceiptGeneration =
                credentialGenerationValue (awsAdminPermitIntentGeneration intent)
            , fixtureWorkerReceiptTargetReadBack = targetReadBack
            }
      )

wireWorkerReceiptFixtureBytes :: Word16 -> Word8 -> ByteString.ByteString
wireWorkerReceiptFixtureBytes version kind =
  LazyByteString.toStrict
    ( serialise
        WireAwsAdminWorkerReceiptFixture
          { fixtureWorkerReceiptVersion = version
          , fixtureWorkerReceiptKind = kind
          , fixtureWorkerReceiptPermitId = "permit-transport-fixture"
          , fixtureWorkerReceiptRequestDigest = Text.replicate 64 "a"
          , fixtureWorkerReceiptTarget = TargetAwsCredential AwsLifecycleProvider
          , fixtureWorkerReceiptGeneration = 1
          , fixtureWorkerReceiptTargetReadBack = "revoked"
          }
    )

exactPreparedLifecycle :: AwsAdminPreparedTargetLifecycle IO
exactPreparedLifecycle =
  AwsAdminPreparedTargetLifecycle
    { recordAwsAdminPrepareAuthorityPhase = const (pure ())
    , proveAwsAdminAuthorizedAttemptRecovery = \_ _ ->
        pure (Left AwsAdminAuthorizedRecoveryNotAuthorized)
    , observeAwsAdminCompletedWorkerReceipt = \_ -> pure (Right Nothing)
    , proveAwsAdminAttestedAttemptRecovery = \_ _ _ -> pure (Left AwsAdminAuthorizedRecoveryNotAttested)
    , prepareAndReadBackAwsAdminPreparedTarget = \_ -> pure . Right
    , reobserveRetainedAwsAdminPreparedTarget =
        const (pure (Right preparedTarget))
    , commitAwsAdminFirstReconcileReceipt = \_ _ -> pure (Right ())
    , observeAwsAdminFirstReconcileContinuation = pure (Right Nothing)
    , observeAwsAdminFirstReconcileRecoveryPending = pure (Right False)
    , settleAwsAdminFirstReconcileRecovery = pure (Right ())
    }

preparedTargetCauseLabels :: [(AwsAdminPreparedTargetPrepareCause, Text)]
preparedTargetCauseLabels =
  [ (AwsAdminPreparedTargetAuthorityTimeUnavailable, "authority-time")
  , (AwsAdminPreparedTargetInitialAdmissionUnavailable, "admission/initial")
  , (AwsAdminPreparedTargetJournalMissing, "first-reconcile-journal/missing")
  , (AwsAdminPreparedTargetJournalCorrupt, "first-reconcile-journal/corrupt")
  , (AwsAdminPreparedTargetJournalEndpointUnready, "first-reconcile-journal/endpoint-unready")
  , (AwsAdminPreparedTargetJournalUnobservable, "first-reconcile-journal/unobservable")
  , (AwsAdminPreparedTargetJournalPlanMismatch, "first-reconcile-journal/plan-mismatch")
  , (AwsAdminPreparedTargetJournalCursorRejected, "first-reconcile-journal/cursor-rejected")
  , (AwsAdminPreparedTargetJournalMemberMismatch, "first-reconcile-journal/member-mismatch")
  , (AwsAdminPreparedTargetAdmissionStateRejected, "admission/state-rejected")
  , (AwsAdminPreparedTargetDeadlineExpired, "deadline-expired")
  , (AwsAdminPreparedTargetIntentCanonicalizationRejected, "intent-canonicalization")
  , (AwsAdminPreparedTargetConfirmationAdmissionUnavailable, "admission/confirmation")
  , (AwsAdminPreparedTargetAdmissionChanged, "admission/changed")
  , (AwsAdminPreparedTargetCoordinateRejected, "outbox/coordinate-rejected")
  , (AwsAdminPreparedTargetOutboxMissing, "outbox/missing")
  , (AwsAdminPreparedTargetOutboxCorrupt, "outbox/corrupt")
  , (AwsAdminPreparedTargetOutboxEndpointUnready, "outbox/endpoint-unready")
  , (AwsAdminPreparedTargetOutboxUnobservable, "outbox/unobservable")
  , (AwsAdminPreparedTargetOutboxDivergent, "outbox/divergent")
  ]

preparedTargetFailureResponse
  :: AwsAdminPreparedTargetPrepareCause
  -> Text
  -> IO (ReplyStatus, Either Text AwsAdminProvisionerResponse)
preparedTargetFailureResponse cause detail = do
  (repository, _) <- freshRepository False
  let lifecycle =
        exactPreparedLifecycle
          { prepareAndReadBackAwsAdminPreparedTarget =
              \_ _ ->
                ( pure
                    (Left (awsAdminPreparedTargetPrepareError cause detail))
                )
          }
      handler =
        awsAdminProvisionerAuthenticatedHandler
          (256 * 1024)
          fixtureReadyRoleReadinessSource
          (pure (Right signingTime))
          (const (Right repository))
          lifecycle
          fixtureProviderCredentialBoundary
          authoritySigner
          emptyHandler
      body =
        LazyByteString.toStrict
          ( encodeControlPlaneRequest
              (PrepareAwsAdminProvisioning (encodePermitIntent permitIntent))
          )
  response <-
    authenticatedHandlerHandle
      handler
      (verifiedCallerSlotFixture CallerOperatorCli 1)
      LifecycleAwsAdminProvisioner
      body
  case response of
    Nothing -> pure (ReplyNotFound, Left "AWS-admin route was not handled")
    Just (status, responseBody) ->
      pure
        ( status
        , first
            (Text.pack . show)
            ( decodeControlPlaneResponse
                awsAdminProvisionerResponseMaximumBytes
                (LazyByteString.fromStrict responseBody)
            )
        )

freshRepository
  :: Bool
  -> IO
       ( AwsAdminAuthorityRepository IO Int
       , IORef (Int, AwsAdminAuthorityState)
       )
freshRepository loseWriteResponse = do
  stateRef <- newIORef (0, initialAwsAdminAuthorityState)
  let repository =
        AwsAdminAuthorityRepository
          { readAwsAdminAuthority = do
              (revision, state) <- readIORef stateRef
              pure
                ( Right
                    AwsAdminAuthoritySnapshot
                      { awsAdminAuthorityRevision = revision
                      , awsAdminAuthoritySnapshotState = state
                      }
                )
          , compareAndSwapAwsAdminAuthority = \expected next -> do
              (revision, _) <- readIORef stateRef
              if revision /= expected
                then pure (Left "fixture CAS conflict")
                else do
                  writeIORef stateRef (revision + 1, next)
                  pure
                    ( if loseWriteResponse
                        then Left "fixture response lost after commit"
                        else Right ()
                    )
          }
  pure (repository, stateRef)

exactPreparedBoundary :: AwsAdminPreparedTargetBoundary IO
exactPreparedBoundary =
  AwsAdminPreparedTargetBoundary (const (pure (Right preparedTarget)))

emptyHandler :: AuthenticatedRoleHandler IO
emptyHandler =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = fixtureReadyRoleReadinessSource
    , authenticatedHandlerHandle = \_ _ _ -> pure Nothing
    }

permitIntent :: AwsAdminPermitIntent
permitIntent =
  must
    ( mkNormalAwsAdminPermitIntent
        operatorPermit
        iamParameters
        imageDigest
        "home"
        "http://lifecycle-authority.lifecycle-authority.svc:8600"
        preparedTarget
    )

expectedAwsAdminWorkerArguments :: Text -> [Text]
expectedAwsAdminWorkerArguments targetWorkerRepository =
  [ "credential-provisioner"
  , "run"
  , "--ingress-schema"
  , "aws-admin"
  , "--mode"
  , "normal"
  , "--operation-id"
  , operatorMaterialOperationIdText (awsAdminPermitIntentOperationId permitIntent)
  , "--permit-id"
  , operatorMaterialPermitIdText (awsAdminPermitIntentPermitId permitIntent)
  , "--request-digest"
  , targetValueDigestText (awsAdminPermitIntentRequestDigest permitIntent)
  , "--deadline-micros"
  , Text.pack (show (authorityTimeMicros (awsAdminPermitIntentDeadline permitIntent)))
  , "--image-digest"
  , awsAdminPermitIntentImageDigest permitIntent
  , "--target-worker-image-repository"
  , targetWorkerRepository
  , "--authority-scope"
  , awsAdminPermitIntentAuthorityScope permitIntent
  , "--authority-endpoint"
  , awsAdminPermitIntentAuthorityEndpoint permitIntent
  , "--pod-name-file"
  , "/var/run/secrets/prodbox/pod-name"
  , "--pod-uid-file"
  , "/var/run/secrets/prodbox/pod-uid"
  , "--service-account-token-file"
  , "/var/run/secrets/prodbox/token"
  ]

operatorPermit :: OperatorMaterialPermit 'AwsAdminProvisioningIngress
operatorPermit =
  must
    ( mkOperatorMaterialPermit
        (must (mkOperatorMaterialPermitId "permit-authority-test"))
        operatorRequest
        deadline
        Nothing
        "operator-signature"
    )

operatorRequest :: OperatorMaterialRequest 'AwsAdminProvisioningIngress
operatorRequest =
  must
    ( mkAwsOperatorMaterialRequest
        LifecycleProviderCredential
        InstallOperatorMaterial
        (must (mkOperatorMaterialOperationId operationId))
        generation
    )

preparedTarget :: PreparedCredentialTargetObservation
preparedTarget = preparedTargetFor "owner-nonce-1"

mismatchedPreparedTarget :: PreparedCredentialTargetObservation
mismatchedPreparedTarget = preparedTargetFor "owner-nonce-2"

preparedTargetFor :: Text -> PreparedCredentialTargetObservation
preparedTargetFor ownerNonce =
  must
    ( mkPreparedCredentialTargetObservation
        ownerNonce
        1
        targetAgent
        (TargetAwsCredential AwsLifecycleProvider)
        generation
        (operatorMaterialRequestDigest operatorRequest)
        receiptDigest
        Nothing
        deadline
    )

jobBinding :: AwsAdminJobBinding
jobBinding = bindingFor "pod-uid-1"

divergentJobBinding :: AwsAdminJobBinding
divergentJobBinding = bindingFor "pod-uid-2"

bindingFor :: Text -> AwsAdminJobBinding
bindingFor podUid =
  must
    ( mkAwsAdminJobBinding
        permitIntent
        (awsAdminJobNameForPermit (awsAdminPermitIntentPermitId permitIntent))
        "job-uid-1"
        "credential-provisioner-pod-1"
        podUid
        imageDigest
        awsAdminWorkerServiceAccount
        "service-account-uid-1"
        heartbeat
    )

authoritySigner :: AuthorityManifestSigner IO
authoritySigner =
  AuthorityManifestSigner
    { readAuthorityManifestPublicKey = pure (Right (7, manifestPublicKey))
    , signAuthorityManifestPayload = \payload ->
        pure
          ( Right
              ( 7
              , ByteArray.convert
                  (Ed25519.sign signingSecret signingPublic payload)
              )
          )
    }

generationDriftSigner :: AuthorityManifestSigner IO
generationDriftSigner =
  authoritySigner
    { signAuthorityManifestPayload = \payload ->
        pure
          ( Right
              ( 8
              , ByteArray.convert
                  ( Ed25519.sign
                      signingSecret
                      signingPublic
                      payload
                  )
              )
          )
    }

signingSecret :: Ed25519.SecretKey
signingSecret = case Ed25519.secretKey (ByteString.pack [0 .. 31]) of
  CryptoPassed key -> key
  CryptoFailed err -> error (show err)

signingPublic :: Ed25519.PublicKey
signingPublic = Ed25519.toPublic signingSecret

manifestPublicKey :: ManifestPublicKey
manifestPublicKey =
  must (mkManifestPublicKey (ByteArray.convert signingPublic))

iamParameters :: CredentialIamParameters
iamParameters =
  must
    ( mkLifecycleProviderIamParameters
        (fixtureAwsRegion FixtureUsWest2)
        "123456789012"
        "prodbox-provider-role"
    )

targetAgent :: TargetAgentIdentity
targetAgent =
  must
    ( mkTargetAgentIdentity
        ("home@sha256:" <> Text.replicate 64 "a")
    )

renewalTargetAgent :: TargetAgentIdentity
renewalTargetAgent =
  must
    ( mkTargetAgentIdentity
        ("home@sha256:" <> Text.replicate 64 "f")
    )

generation :: CredentialGeneration
generation = must (mkCredentialGeneration 1)

receiptDigest :: TargetValueDigest
receiptDigest = must (mkTargetValueDigest (Text.replicate 64 "b"))

operationId :: Text
operationId = "aws-admin-authority-operation"

imageDigest, otherImageDigest :: Text
imageDigest = "sha256:" <> Text.replicate 64 "c"
otherImageDigest = "sha256:" <> Text.replicate 64 "d"

fixtureKubernetesApiEgressCoordinate :: KubernetesApiEgressCoordinate
fixtureKubernetesApiEgressCoordinate =
  KubernetesApiEgressCoordinate
    { kubernetesApiEgressAddresses = ["192.0.2.10"]
    , kubernetesApiEgressPort = 6443
    }

fixtureCredentialProvisionerSubstrateManifest :: Aeson.Value
fixtureCredentialProvisionerSubstrateManifest =
  credentialProvisionerSubstrateManifest fixtureKubernetesApiEgressCoordinate

heartbeat, signingTime, deadline :: AuthorityTime
heartbeat = authorityTimeFromMicros 1000000
signingTime = authorityTimeFromMicros 1000001
deadline = authorityTimeFromMicros 60000000

renewalOldDeadline, renewalNow, renewalNewDeadline :: AuthorityTime
renewalOldDeadline = authorityTimeFromMicros 10000000
renewalNow = authorityTimeFromMicros 20000000
renewalNewDeadline = authorityTimeFromMicros 40000000

preparedOnlyClient :: AwsAdminProvisionerClient IO
preparedOnlyClient =
  mkAwsAdminProvisionerClient $ \request -> pure $ case request of
    PrepareAwsAdminProvisioning _ -> Right (AwsAdminProvisioningPrepared coordinatorChallenge)
    ObserveAwsAdminProvisioning _ ->
      Right
        ( AwsAdminProvisioningObserved
            AwsAdminProvisionerObservation
              { awsAdminObservedChallenge = coordinatorChallenge
              , awsAdminObservedPhase = AwsAdminProvisionerPrepared
              , awsAdminObservedPermit = Nothing
              , awsAdminObservedReceipt = Nothing
              }
        )
    _ -> Left AwsAdminProvisionerClientUnexpectedResponse

coordinatorChallenge :: AwsAdminProvisionerChallenge
coordinatorChallenge =
  AwsAdminProvisionerChallenge
    { awsAdminChallengeOperationId =
        operatorMaterialOperationIdText (awsAdminPermitIntentOperationId permitIntent)
    , awsAdminChallengePermitId =
        operatorMaterialPermitIdText (awsAdminPermitIntentPermitId permitIntent)
    , awsAdminChallengeRequestDigest =
        targetValueDigestText (awsAdminPermitIntentRequestDigest permitIntent)
    , awsAdminChallengeGeneration =
        credentialGenerationValue (awsAdminPermitIntentGeneration permitIntent)
    , awsAdminChallengeTarget = awsAdminPermitIntentTarget permitIntent
    , awsAdminChallengeJobName = awsAdminJobNameForPermit (awsAdminPermitIntentPermitId permitIntent)
    , awsAdminChallengeImageDigest = awsAdminPermitIntentImageDigest permitIntent
    , awsAdminChallengeServiceAccount = awsAdminWorkerServiceAccount
    , awsAdminChallengeAuthorityScope = awsAdminPermitIntentAuthorityScope permitIntent
    , awsAdminChallengeAuthorityEndpoint = awsAdminPermitIntentAuthorityEndpoint permitIntent
    , awsAdminChallengeDeadlineMicros = authorityTimeMicros (awsAdminPermitIntentDeadline permitIntent)
    , awsAdminChallengeCanonicalIntent = encodeAwsAdminPermitIntent permitIntent
    }

throwingCoordinatorKubernetes
  :: IORef [Text]
  -> IO (Either Text ())
  -> AwsAdminKubernetesBoundary IO
throwingCoordinatorKubernetes events createEffect =
  AwsAdminKubernetesBoundary
    { acquireAwsAdminJobHeartbeat = pure (Right 1000000)
    , createAwsAdminJob = \_ _ -> createEffect
    , observeAwsAdminJob = \_ _ -> pure (Right Nothing)
    , attachAwsAdminWorker = \_ _ -> pure (Left "must not attach")
    , deleteAwsAdminJob = \_ _ _ -> writeIORef events ["delete"] >> pure (Right ())
    , observeAwsAdminJobAbsent = \_ _ -> writeIORef events ["delete", "absence"] >> pure (Right True)
    }

popPodConvergence
  :: IORef [Either AwsAdminKubernetesError AwsAdminPodConvergence]
  -> IO (Either AwsAdminKubernetesError AwsAdminPodConvergence)
popPodConvergence observationsRef = do
  observations <- readIORef observationsRef
  case observations of
    [] -> error "AWS-admin Pod convergence fixture exhausted"
    observation : remaining -> do
      writeIORef observationsRef remaining
      pure observation

-- | Opaque fixture credential (vault_doctrine.md §20.1). Nothing here validates
-- shape — 'validateAdminCredentials' checks only non-emptiness — so both halves
-- are descriptive slugs rather than imitations of production values. The leak
-- canary above asserts their absence from the rendered Job.
adminCredentials :: Credentials
adminCredentials =
  Credentials
    { access_key_id = "fixture-admin-access-key-1"
    , secret_access_key = "fixture-admin-secret-access-key-1"
    , session_token = Nothing
    , region = (fixtureAwsRegion FixtureUsWest2)
    }

encodePermitIntent :: AwsAdminPermitIntent -> ByteString.ByteString
encodePermitIntent = encodeAwsAdminPermitIntent

renewalIntentAt
  :: AuthorityTime
  -> Text
  -> TargetAgentIdentity
  -> Text
  -> AwsAdminPermitIntent
renewalIntentAt activeDeadline activeImage selectedAgent scope =
  must
    ( mkNormalAwsAdminPermitIntent
        renewalOperatorPermit
        iamParameters
        activeImage
        scope
        "http://lifecycle-authority.lifecycle-authority.svc:8600"
        renewalPreparedTarget
    )
 where
  renewalOperatorPermit =
    must
      ( mkOperatorMaterialPermit
          (must (mkOperatorMaterialPermitId "permit-authority-test"))
          operatorRequest
          activeDeadline
          (Just renewalPlanBinding)
          "operator-signature"
      )
  renewalPreparedTarget =
    must
      ( mkPreparedCredentialTargetObservation
          "owner-nonce-1"
          1
          selectedAgent
          (TargetAwsCredential AwsLifecycleProvider)
          generation
          (operatorMaterialRequestDigest operatorRequest)
          receiptDigest
          (Just renewalPlanBinding)
          activeDeadline
      )

postFirstReconcileRenewalIntentAt
  :: AuthorityTime
  -> Text
  -> TargetAgentIdentity
  -> Text
  -> AwsAdminPermitIntent
postFirstReconcileRenewalIntentAt activeDeadline activeImage selectedAgent scope =
  must
    ( mkNormalAwsAdminPermitIntent
        renewalOperatorPermit
        iamParameters
        activeImage
        scope
        "http://lifecycle-authority.lifecycle-authority.svc:8600"
        renewalPreparedTarget
    )
 where
  renewalOperatorPermit =
    must
      ( mkOperatorMaterialPermit
          (must (mkOperatorMaterialPermitId "permit-authority-test"))
          operatorRequest
          activeDeadline
          Nothing
          "operator-signature"
      )
  renewalPreparedTarget =
    must
      ( mkPreparedCredentialTargetObservation
          "owner-nonce-1"
          1
          selectedAgent
          (TargetAwsCredential AwsLifecycleProvider)
          generation
          (operatorMaterialRequestDigest operatorRequest)
          receiptDigest
          Nothing
          activeDeadline
      )

renewalPlanBinding :: FirstReconcilePermitBinding
renewalPlanBinding =
  mkFirstReconcilePermitBinding
    (firstReconcilePlanDigest renewalPlan)
    (firstReconcilePlanMemberIndex renewalMember)
    (firstReconcilePlanMemberDigest renewalMember)
    (Just receiptDigest)
 where
  renewalPlan =
    defaultFirstReconcileProvisioningPlan
      (authorityTimeFromMicros 1000000)
  renewalMember = firstReconcilePlanMembers renewalPlan !! 1

renewalJobBinding :: AwsAdminPermitIntent -> AwsAdminJobBinding
renewalJobBinding intent =
  must
    ( mkAwsAdminJobBinding
        intent
        (awsAdminJobNameForPermit (awsAdminPermitIntentPermitId intent))
        "renewal-job-uid"
        "renewal-pod"
        "renewal-pod-uid"
        (awsAdminPermitIntentImageDigest intent)
        awsAdminWorkerServiceAccount
        "renewal-service-account-uid"
        (authorityTimeFromMicros 2000000)
    )

authorizedPermitFor :: AwsAdminPermitIntent -> IO SignedAwsAdminPermit
authorizedPermitFor intent = do
  let prepared = AwsAdminAuthorityPrepared intent
      attested = must (commitAwsAdminAttested (renewalJobBinding intent) prepared)
  authorized <-
    authorizeAwsAdminAttestation
      authoritySigner
      (authorityTimeFromMicros 3000000)
      attested
  pure $ case authorized of
    Left err -> error (show err)
    Right (_, permit) -> permit

renewalRepository
  :: IORef [Text]
  -> IORef (Int, AwsAdminAuthorityState)
  -> AwsAdminAuthorityRepository IO Int
renewalRepository events stateRef =
  AwsAdminAuthorityRepository
    { readAwsAdminAuthority = do
        (revision, state) <- readIORef stateRef
        pure
          ( Right
              AwsAdminAuthoritySnapshot
                { awsAdminAuthorityRevision = revision
                , awsAdminAuthoritySnapshotState = state
                }
          )
    , compareAndSwapAwsAdminAuthority = \expected next -> do
        (revision, _) <- readIORef stateRef
        if revision /= expected
          then pure (Left "fixture CAS conflict")
          else do
            modifyIORef' events (<> ["state-cas"])
            writeIORef stateRef (revision + 1, next)
            pure (Left "fixture response lost after commit")
    }

interruptedOutboxAdapter
  :: IORef [Text]
  -> ModelBObjectVersion
  -> IORef (ModelBObjectVersion, PreparedCredentialTargetOutbox)
  -> ModelBCasAdapter 'ClusterRetained IO PreparedCredentialTargetOutbox
interruptedOutboxAdapter events replacementVersion stateRef =
  ModelBCasAdapter
    { modelBObserve = \_ -> do
        (version, outbox) <- readIORef stateRef
        pure (ModelBObserved version outbox)
    , modelBCompareAndSwap = \request -> do
        (currentVersion, current) <- readIORef stateRef
        case request of
          ModelBReplace _ expected replacement
            | expected == currentVersion -> do
                modifyIORef' events (<> ["outbox-cas"])
                writeIORef stateRef (replacementVersion, replacement)
                pure (ModelBCasApplied replacementVersion replacement)
            | otherwise ->
                pure (ModelBCasConflict (ModelBObserved currentVersion current))
          ModelBInitialize _ _ ->
            pure (ModelBCasConflict (ModelBObserved currentVersion current))
          ModelBInitializeGuarded {} ->
            pure (ModelBCasRefusedCorrupt "unexpected guarded outbox initialize")
          ModelBReplaceGuarded {} ->
            pure (ModelBCasRefusedCorrupt "unexpected guarded outbox replace")
    }

retainedJournalCoordinate :: ModelBObjectCoordinate 'ClusterRetained
retainedJournalCoordinate =
  must
    ( mkClusterRetainedCoordinate
        ( must
            ( mkLongLivedCheckpointAuthority
                "home-authority"
                "prodbox-retained"
                "authority"
                "secret/lifecycle"
            )
        )
        "credential-provisioner/first-reconcile"
    )

retainedJournalVersion :: ModelBObjectVersion
retainedJournalVersion = must (mkModelBObjectVersion "journal-v1")

retainedJournalAdapter
  :: IORef (Maybe (ModelBObjectVersion, FirstReconcileJournal))
  -> IORef Int
  -> ModelBCasAdapter 'ClusterRetained IO FirstReconcileJournal
retainedJournalAdapter journalState writeCount =
  ModelBCasAdapter
    { modelBObserve = observeRetainedJournal journalState
    , modelBCompareAndSwap = applyRetainedJournalRequest journalState writeCount
    }

observeRetainedJournal
  :: IORef (Maybe (ModelBObjectVersion, FirstReconcileJournal))
  -> ModelBObjectCoordinate 'ClusterRetained
  -> IO (ModelBObservation FirstReconcileJournal)
observeRetainedJournal journalState _ = do
  current <- readIORef journalState
  pure $ case current of
    Nothing -> ModelBMissing
    Just (version, journal) -> ModelBObserved version journal

applyRetainedJournalRequest
  :: IORef (Maybe (ModelBObjectVersion, FirstReconcileJournal))
  -> IORef Int
  -> ModelBCasRequest 'ClusterRetained FirstReconcileJournal
  -> IO (ModelBCasResult FirstReconcileJournal)
applyRetainedJournalRequest journalState writeCount request = case request of
  ModelBInitialize _ journal -> do
    modifyIORef' writeCount (+ 1)
    current <- readIORef journalState
    case current of
      Nothing -> do
        writeIORef journalState (Just (retainedJournalVersion, journal))
        pure (ModelBCasApplied retainedJournalVersion journal)
      Just (version, existing) ->
        pure (ModelBCasConflict (ModelBObserved version existing))
  ModelBReplace {} ->
    pure (ModelBCasRefusedCorrupt "unexpected journal replacement")
  ModelBInitializeGuarded {} ->
    pure (ModelBCasRefusedCorrupt "unexpected guarded journal initialization")
  ModelBReplaceGuarded {} ->
    pure (ModelBCasRefusedCorrupt "unexpected guarded journal replacement")

must :: (Show errorValue) => Either errorValue value -> value
must = either (error . show) id

-- Endpoint unit fixtures isolate the lifecycle interpreter; production captures
-- the actual retained aggregate, completed outbox and authenticated Agent.
fixtureProviderCredentialBoundary :: AwsAdminProviderCredentialBoundary IO
fixtureProviderCredentialBoundary =
  AwsAdminProviderCredentialBoundary
    (\_ -> pure (Right ()))
    (\_ -> pure (Right ()))
    (\_ -> pure (Right ()))
    (pure (Right Nothing))
    (pure (Right ProviderCredentialRecoveryIdle))
    (pure (Right ()))

data JournalCompletionScenario
  = JournalComplete
  | JournalMissing
  | JournalUnavailable
  | JournalForeignReceipt
  | JournalAdmissionUnavailable
  deriving (Eq, Show)
