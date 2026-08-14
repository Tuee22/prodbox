{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- | Executable boundary for the physically separated control-plane roles. The
-- Lifecycle Authority, Authority Backup Adapter, and TLS Retention Adapter install
-- their production retained-store interpreters and signed-S3 readiness probes.
-- Roles whose production composition has not landed remain explicitly fail-closed.
module Prodbox.ControlPlane.Runtime
  ( ControlPlaneConfig (..)
  , ControlPlaneAuthenticationWire (..)
  , ControlPlaneTrustedCallerWire (..)
  , ControlPlaneRoleStore (..)
  , PrimaryStoreWire (..)
  , AuthorityBackupStoreWire (..)
  , TlsRetentionStoreWire (..)
  , ValidatedRoleStore (..)
  , ControlPlaneConfigError (..)
  , AuthenticatedRuntimeInputs (..)
  , AuthenticatedRuntimeInstallError (..)
  , AuthenticatedRuntimeProvisioningGap (..)
  , installAuthenticatedRuntimeInterpreter
  , LifecycleAuthorityCoordinates (..)
  , AuthorityStartupMode (..)
  , authorityStartupModeFromRegistration
  , lifecycleAuthoritySubmissionCapacity
  , lifecycleAuthorityRetainedSubmissionCapacity
  , registeredClientTableFromTrustRegistry
  , validateControlPlaneConfig
  , mkLifecycleAuthorityCoordinates
  , lifecycleAuthorityRuntimeInterpreter
  , authorityBackupRuntimeInterpreter
  , tlsRetentionRuntimeInterpreter
  , receiveControlPlaneRequest
  , runControlPlaneRole
  , serveControlPlaneConnection
  , controlPlaneCapacityInputs
  , controlPlaneCapacityPlan
  , controlPlaneRequestBudget
  , refuseControlPlaneConnection
  )
where

import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.STM
  ( TBQueue
  , TVar
  , atomically
  , modifyTVar'
  , newTBQueueIO
  , newTVarIO
  , readTBQueue
  , readTVar
  , stateTVar
  , writeTBQueue
  , writeTVar
  )
import Control.Exception
  ( SomeAsyncException
  , SomeException
  , bracket
  , finally
  , fromException
  , mask
  , throwIO
  , try
  )
import Control.Monad (forever, replicateM, void)
import Crypto.Random (getRandomBytes)
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Dhall qualified
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Generics (Generic)
import Network.Socket
import Network.Socket.ByteString (recv)
import Numeric.Natural (Natural)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Bootstrap.Broker.Types (renderArtifactDigest)
import Prodbox.CLI.Command
  ( ControlPlaneLaunchOptions (..)
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.ControlPlane.AdminActionAuthorityExecutionEndpoint
  ( AdminActionAuthorityExecutionBoundary (..)
  , AdminLegacyDestinationBoundary (..)
  , AdminLegacyDestinationObservation (..)
  , AdminLegacyDestinationPublication (..)
  , adminActionAuthorityExecutionMaximumBytes
  , adminActionEffectMaximumEncodedBytes
  , adminActionEffectStateCodec
  , modelBAdminActionEffectRepository
  )
import Prodbox.ControlPlane.AdminActionEndpoint
  ( adminActionAuthenticatedHandler
  , adminActionEndpointMaximumBytes
  )
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  , AuthenticatedRoleProviders (..)
  , contextFreeAuthenticatedRoleHandler
  )
import Prodbox.ControlPlane.AuthenticatedRuntime
  ( AuthenticatedRuntimeInputs (..)
  , AuthenticatedRuntimeInstallError (..)
  , AuthenticatedRuntimeProvisioningGap (..)
  , ControlPlaneAuthenticationConfigError
  , ControlPlaneAuthenticationWire (..)
  , ControlPlaneTrustedCallerWire (..)
  , ValidatedAuthenticationTopology
  , installAuthenticatedRuntimeInterpreter
  , resolveRouteTrustRegistryWith
  , validateControlPlaneAuthenticationWire
  , validatedAuthenticationSigningKeyRef
  , validatedAuthenticationSigningPrincipal
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedServerProviders (..)
  , RouteTrustRegistry
  , mkAuthenticatedClientTransport
  , mkAuthenticatedTransportBounds
  , routeTrustRegistryKeysFor
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( targetSecretControllerAuditorVaultRole
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (readAuthorityAdmission)
  , AuthorityAdmissionSnapshot (authorityAdmissionSnapshotState)
  , AuthorityOperationSubmitResult (..)
  , authorityAdmissionMaximumEncodedBytes
  , authorityAdmissionMigrationImportApplicator
  , authorityAdmissionStateCodecWithRegisteredClients
  , modelBAuthorityAdmissionRepository
  , serveAuthorityOperationSubmit
  )
import Prodbox.ControlPlane.AuthorityBackupAdapter
  ( authorityBackupAdapterReady
  , authorityBackupRepository
  )
import Prodbox.ControlPlane.AuthorityBackupClient
  ( AuthorityCheckpointBackupClient (copyCheckpointBackup)
  , authorityAggregateBackupClientWithTransport
  , authorityCheckpointBackupClient
  , authorityCheckpointBackupMaximumResponseBytes
  )
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupReceipt (..)
  , authorityBackupDigestText
  )
import Prodbox.ControlPlane.AuthorityProviderEndpoint
  ( AuthorityProviderDispatchBoundary (..)
  , authorityProviderDispatchAuthenticatedHandler
  )
import Prodbox.ControlPlane.AwsAdminPreparedTargetProduction
  ( productionAwsAdminPreparedTargetLifecycle
  )
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( awsAdminProvisionerAuthenticatedHandler
  , awsAdminProvisionerMaximumBytes
  )
import Prodbox.ControlPlane.BootstrapCustodyClient qualified as BootstrapCustody
import Prodbox.ControlPlane.BootstrapCustodyEndpoint (observeTargetChildCustodyDependency)
import Prodbox.ControlPlane.BootstrapHandoffEndpoint
  ( bootstrapHandoffAuthenticatedHandler
  , observeBootstrapHandoffDependency
  , vaultBootstrapHandoffRepository
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerService)
  , callerPrincipalCode
  )
import Prodbox.ControlPlane.Capacity
  ( AdmissionDecision (AdmissionAdmit, AdmissionRejected)
  , AdmissionQueue
  , AdmissionRequest (AdmissionRequest)
  , RawServiceCapacityPlan (..)
  , RejectionReason (RejectedDeadlineUnmeetable, RejectedSaturated)
  , RequestId (RequestId)
  , ServiceCapacityPlan
  , ServiceCapacityPlanError
  , admit
  , completeService
  , emptyAdmissionQueue
  , mkServiceCapacityPlan
  , serviceCapacityQueueCapacity
  , serviceCapacityWorkerCount
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunRepositoryProvider (..)
  )
import Prodbox.ControlPlane.Client
  ( mkAuthorityBackupEndpoint
  , mkLifecycleAuthorityEndpoint
  , mkProviderWorkerEndpoint
  , mkTargetSecretAgentEndpoint
  , newControlPlaneClient
  )
import Prodbox.ControlPlane.ConfigBackupClient (configBackupClient)
import Prodbox.ControlPlane.ConfigEndpoint
  ( aggregateConfigAuthorityRepository
  )
import Prodbox.ControlPlane.ConfigPayload
  ( productionConfigPayloadCompiler
  )
import Prodbox.ControlPlane.ConfigProductionStore
  ( productionConfigBlobStore
  )
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.Coordinate qualified as Coordinate
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , DeadlineObservation (DeadlineExpired, DeadlineOpen)
  , MonotonicInstant
  , RemainingDuration (RemainingDuration)
  , deadlineAtOffset
  , deadlineObservation
  , monotonicInstantFromMicros
  , monotonicInstantMicros
  )
import Prodbox.ControlPlane.DecommissionClient
  ( requestTargetDecommissionInventory
  )
import Prodbox.ControlPlane.DecommissionProduction
  ( authorityDecommissionRepositories
  )
import Prodbox.ControlPlane.DedicatedAdapterStore
  ( AuthorityBackupStoreConfig
  , DedicatedAdapterBinding
  , DedicatedAdapterKind (AuthorityBackupAdapter, TlsRetentionAdapter)
  , DedicatedAdapterStoreError
  , TlsRetentionStoreConfig
  , mkAuthorityBackupStoreConfig
  , mkTlsRetentionStoreConfig
  , newAuthorityBackupAdapterBinding
  , newTlsRetentionAdapterBinding
  )
import Prodbox.ControlPlane.ExternalMaterialIngressEndpoint
  ( externalMaterialIngressAuthenticatedHandler
  , externalMaterialIngressMaximumEncodedBytes
  , modelBExternalMaterialIngressRepository
  )
import Prodbox.ControlPlane.FederationRegistrationEndpoint
  ( FederationRegistrationBoundary (..)
  , federationRegistrationAuthenticatedHandler
  , federationRegistrationMaximumBytes
  , federationRegistrationStateCodec
  , modelBFederationRegistrationRepository
  )
import Prodbox.ControlPlane.InClusterAuthorityStore
  ( InClusterAuthorityStore
  , InClusterAuthorityStoreConfig
  , InClusterAuthorityStoreConfigError
  , inClusterAuthorityCheckpointAuthority
  , inClusterAuthorityModelBCasAdapter
  , inClusterAuthorityReady
  , inClusterAuthorityTransport
  , mkInClusterAuthorityStoreConfig
  , newInClusterAuthorityStore
  )
import Prodbox.ControlPlane.Interpreter (realMonotonicNow)
import Prodbox.ControlPlane.ListenPort
  ( controlPlaneClusterServiceUrlText
  , controlPlaneListenPort
  , controlPlaneListenPortNumber
  )
import Prodbox.ControlPlane.ProjectionImportEndpoint
  ( mkProjectionImportHandlerWithApplicator
  , resolvingProjectionImportHandler
  )
import Prodbox.ControlPlane.ProjectionImportRegistration
  ( productionProjectionImportFromRegistration
  , projectionImportRegistrationCoordinate
  , projectionImportRegistrationLeaseKey
  , projectionImportRegistrationModelBCodec
  )
import Prodbox.ControlPlane.ProviderProduction
  ( providerProductionCapabilities
  , providerProductionNarrowSession
  , providerProductionReady
  )
import Prodbox.ControlPlane.ProviderWorkerClient
  ( dispatchProviderCommittedIntent
  , providerWorkerExecutionAuthenticatedHandler
  , providerWorkerResponseMaximumBytes
  )
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderWorkerTrustRepository (..)
  , mkAcceptedProviderAuthority
  , mkProviderIntentPublicKey
  , mkProviderIssuerKeyGeneration
  , mkProviderWorkerExecutionBoundary
  , providerCommittedIntentMaximumEncodedBytes
  )
import Prodbox.ControlPlane.PulumiCheckpointEndpoint
  ( PulumiCheckpointMutationTicket (..)
  , PulumiCheckpointObservation (..)
  , PulumiCheckpointPublicationResult (..)
  , PulumiCheckpointRepository (..)
  , mkPulumiCheckpointHandler
  )
import Prodbox.ControlPlane.PulumiCheckpointProductionStore
  ( productionPulumiCheckpointBlobStore
  )
import Prodbox.ControlPlane.PulumiCheckpointRepository
  ( aggregatePulumiCheckpointRepository
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestSigningCapability
  , VerifiedCallerSlot
  , signingKeyGenerationValue
  , trustedRequestCallerPrincipal
  , trustedRequestGeneration
  , trustedRequestPublicKeyBytes
  )
import Prodbox.ControlPlane.RequestReplay
  ( ReplayAttemptId
  , RequestReplayRepository (readRequestReplayProjection)
  , initialRequestReplayProjection
  , mkReplayAttemptId
  , mkReplayCasAttempts
  , mkRequestReplayLimits
  , modelBRequestReplayRepository
  , requestReplayCodec
  )
import Prodbox.ControlPlane.RetainedAuthentication
  ( authorityAdmissionWithRetainedEpoch
  , authorityAuthenticationEpoch
  , readRetainedAuthorityEpoch
  , vaultRequestReplayRepository
  )
import Prodbox.ControlPlane.RetainedMaterialDeliveryCoordinator
  ( coordinateRetainedMaterialDelivery
  , ensureRetainedMaterialCurrentSource
  , retainedDeliveryRequestTarget
  )
import Prodbox.ControlPlane.RetainedMaterialDeliveryEndpoint
  ( RetainedMaterialDeliveryBoundary (..)
  , retainedMaterialDeliveryAuthenticatedHandler
  )
import Prodbox.ControlPlane.RetainedMaterialDeliveryProduction
  ( productionRetainedMaterialDeliveryWithKeyPair
  , retainedMaterialDeliveryTargetReceipt
  )
import Prodbox.ControlPlane.RetainedMaterialRepository
  ( modelBRetainedMaterialRepository
  , retainedMaterialModelBCodec
  )
import Prodbox.ControlPlane.RetainedSesLeaseEndpoint
  ( mkRetainedSesLeaseHandler
  , resolvingRetainedSesLeaseHandler
  , retainedSesLeaseModelBCodec
  )
import Prodbox.ControlPlane.RoleInterpreters
  ( LifecycleAuthorityDecommissionInputs
      ( LifecycleAuthorityDecommissionProvisioned
      )
  , TargetSecretAgentDecommissionInputs
    ( TargetSecretAgentDecommissionProvisioned
    )
  , authorityBackupInterpreter
  , lifecycleAuthorityAdminActionExecutionAuthenticatedHandler
  , lifecycleAuthorityAdmissionAuthenticatedHandler
  , lifecycleAuthorityDecommissionAuthenticatedHandler
  , lifecycleAuthorityTlsRetentionAuthenticatedHandler
  , targetSecretAgentAdminActionAuthenticatedHandler
  , targetSecretAgentDecommissionAuthenticatedHandler
  , tlsRetentionInterpreter
  )
import Prodbox.ControlPlane.RoleReadiness
  ( RoleDependencyObservation (RoleDependencyReady, RoleDependencyUnavailable)
  , controlPlaneRoleReadinessSchedule
  , layerRoleReadinessSource
  , noRoleReadinessContribution
  , roleDependencyFromOutcome
  )
import Prodbox.ControlPlane.RoleReadinessObserver
  ( RoleReadinessObserver
  , newRoleReadinessObserver
  , roleReadinessObserverSource
  , withRoleReadinessObservers
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleOperationSubmit, ProviderWorkApply)
  , routesForRole
  )
import Prodbox.ControlPlane.Server
  ( ControlPlaneFramingError
  , ControlPlaneFramingProgress (..)
  , RoleInterpreter (interpreterReadiness)
  , RoleReadinessResolver
  , controlPlaneMaximumBodyBytes
  , finishControlPlaneRequestFraming
  , inspectControlPlaneRequestFraming
  , mkRoleReadinessResolver
  , renderHttpResponse
  , serveControlPlaneRequest
  )
import Prodbox.ControlPlane.TargetAuthorityTrustClient
  ( targetAuthorityTrustClient
  )
import Prodbox.ControlPlane.TargetAuthorityTrustEndpoint
  ( targetAuthorityTrustAuthenticatedHandler
  , vaultTargetAuthorityTrustRepository
  )
import Prodbox.ControlPlane.TargetIntentAuthorityClient
  ( requestTargetCommittedIntent
  , targetIntentAuthorityClient
  )
import Prodbox.ControlPlane.TargetIntentAuthorityEndpoint
  ( targetIntentIssueAuthenticatedHandler
  )
import Prodbox.ControlPlane.TargetIntentAuthorityProduction
  ( productionTargetIntentIssuerBoundary
  )
import Prodbox.ControlPlane.TargetMaterialClient
  ( observeRegisteredTargetMaterial
  , targetMaterialClient
  , targetWorkerReceiptFromMaterialObservation
  )
import Prodbox.ControlPlane.TargetMaterialEndpoint
  ( observeVaultTargetMaterialDependencies
  , targetMaterialObservationAuthenticatedHandler
  , vaultTargetMaterialRepository
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId
      ( TargetAcmeEab
      , TargetFederationCustody
      , TargetPublicEdgeTls
      , TargetSesSmtp
      )
  , compiledTargetSecretSink
  )
import Prodbox.ControlPlane.TargetMaterializationProduction
  ( productionTargetMaterializationBoundary
  )
import Prodbox.ControlPlane.TargetOneShotOperationEndpoint
  ( TargetOneShotOperationBoundary (..)
  , targetOneShotOperationAuthenticatedHandler
  )
import Prodbox.ControlPlane.TargetRetainedMaterialRewrapClient
  ( targetRetainedMaterialRewrapClient
  )
import Prodbox.ControlPlane.TargetRetainedMaterialRewrapEndpoint
  ( targetRetainedMaterialRewrapAuthenticatedHandler
  )
import Prodbox.ControlPlane.TargetRetainedMaterialRewrapProduction
  ( productionTargetRetainedMaterialRewrapBoundary
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  , encodeSignedTargetCommittedIntent
  , mkTargetAgentIdentity
  , targetAgentClusterIdentity
  , targetAgentRolloutDigest
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerIngressSchema (..)
  , mkTargetWorkerImageDigest
  )
import Prodbox.ControlPlane.TargetSecretWorkerCoordinator
  ( coordinateTargetOneShotOperation
  )
import Prodbox.ControlPlane.TargetSecretWorkerProduction
  ( TargetWorkerJobConnection (..)
  , targetWorkerControllerAuditOps
  , targetWorkerKubernetesBoundary
  , vaultTargetWorkerRetainedExecutionBoundary
  )
import Prodbox.ControlPlane.TargetSecretWorkerProtocol
  ( targetWorkerOperationInputSchema
  , targetWorkerOperationRequestDigest
  )
import Prodbox.ControlPlane.TlsRetentionAdapter
  ( tlsRetentionAdapterReady
  , tlsRetentionRepository
  )
import Prodbox.ControlPlane.TlsRetentionAuthority
  ( modelBTlsRetentionAuthorityRepository
  , tlsRetentionAuthorityCoordinate
  , tlsRetentionStateCodec
  )
import Prodbox.ControlPlane.TransitRequestAuthentication
  ( resolveTransitPublicGeneration
  , resolveTransitRequestSigningCapability
  , transitAuthenticatedClientProviders
  )
import Prodbox.ControlPlane.TrustedTargetSink
  ( vaultTrustedTargetSink
  )
import Prodbox.ControlPlane.VaultAccessorAudit
  ( isBoundedBatchAuditorLogin
  )
import Prodbox.ControlPlane.VaultSession
  ( ControlPlaneVaultConfig
  , controlPlaneVaultAddress
  , controlPlaneVaultAuthPath
  , mkControlPlaneVaultConfig
  , newControlPlaneVaultSession
  , readProjectedServiceAccountJwt
  )
import Prodbox.Gateway.Logging (field, logError)
import Prodbox.Http.Client (defaultHttpConfig)
import Prodbox.Http.ReplyStatus
  ( ReplyStatus (..)
  , replyStatusCode
  )
import Prodbox.Http.ResponseObligation
  ( ResponseObligation
  , ResponseRefusal (ResponseCancelled, ResponseHandlerFailed)
  , mkResponseObligation
  , renderResponseRefusalReason
  , responseWriteBudgetMicrosDefault
  , withResponseObligation
  )
import Prodbox.Lifecycle.AdminAction.Authority
  ( AdminActionAuthorityBoundary (..)
  , modelBAdminActionAuthorityRepository
  )
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminActionBackupReceipt
  , AdminActionPermitCore
  , adminActionExecutionStateCodec
  , adminActionPermitBackupDigest
  , adminActionPermitBackupPayload
  , mkAdminActionBackupReceipt
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityRegisteredSubmissionDecision (..)
  , initialCleanInstallAuthorityWithRegisteredClients
  , initialMigratingAuthorityWithRegisteredClients
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( RegisteredClientTable
  , RegisteredSubmissionDecision (..)
  , clientPrincipalForCaller
  , mkClientSubmissionKey
  , mkRegisteredClientGeneration
  , mkRegisteredClientSlot
  , mkRegisteredClientSpec
  , mkRegisteredClientTable
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityEpoch
  , authorityEpochValue
  )
import Prodbox.Lifecycle.Authority.ProjectionImport
  ( productionLegacyProjectionSource
  , productionProjectionImportCodecConfig
  , productionProjectionImportTarget
  )
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( SRetainedMaterialSchema (..)
  , retainedMaterialSchemaToken
  , retainedMaterialTargetText
  )
import Prodbox.Lifecycle.Authority.Submission
  ( OperationId
  , RequestDigest (RequestDigest)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError
  , LongLivedCheckpointAuthority
  , ModelBCasAdapter (modelBObserve)
  , ModelBCodec (encodeModelBValue)
  , ModelBObjectCoordinate
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , checkpointAuthorityClusterId
  , checkpointAuthorityObjectBucket
  , mkClusterRetainedCoordinate
  , mkCrossClusterDurableCoordinate
  , mkLongLivedCheckpointAuthority
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAuthority
  ( awsAdminAuthorityStateCodec
  , modelBAwsAdminAuthorityRepository
  )
import Prodbox.Lifecycle.CredentialProvisioner.ExternalIngress
  ( externalMaterialIngressStateCodec
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (readAuthorityManifestPublicKey)
  , vaultAuthorityManifestSigner
  )
import Prodbox.Lifecycle.Decommission.Commit
  ( decommissionManifestCodec
  , modelBDecommissionCommitRepository
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionNode (..)
  , manifestPublicKeyDigest
  , mkDecommissionManifest
  )
import Prodbox.Lifecycle.Decommission.RetainedCustodyTombstone
  ( vaultRetainedCustodyBoundary
  )
import Prodbox.Lifecycle.Decommission.TargetInventory
  ( TargetDecommissionInventory (..)
  , targetDecommissionInventoryBoundary
  )
import Prodbox.Lifecycle.Decommission.TargetTombstone
  ( mkTargetGenerationTombstoneBinding
  , mkTargetGenerationTombstoneRegistry
  , vaultTargetGenerationTombstoneBoundary
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityDurationFromMicros
  , authorityTimeFromMicros
  , authorityTimeMicros
  , defaultSesLeasePolicy
  , mkFencingToken
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( mkProviderRevision
  , mkRegisteredProviderResources
  )
import Prodbox.Lifecycle.PulumiCheckpoint
  ( canonicalPulumiCheckpointDigest
  , pulumiCheckpointDigestText
  , registeredPulumiCheckpointByName
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( mkCredentialGeneration
  , targetValueDigestText
  )
import Prodbox.Pulumi.EncryptedBackend
  ( LegacyPulumiBackend (..)
  , PulumiStackRef (..)
  , canonicalizeLegacyPulumiCheckpoint
  , renderEncryptedBackendError
  )
import Prodbox.Runtime.Role (RuntimeRole (..), runtimeRoleName)
import Prodbox.Test.CleanupRun
  ( CleanupRunIndexRepository (..)
  , CleanupRunRepository (..)
  , cleanupRunIdText
  , cleanupRunIndexCodec
  , cleanupRunStoredCodec
  , modelBCleanupRunIndexRepository
  , modelBCleanupRunRepository
  , replicatedCleanupRunIndexRepository
  , replicatedCleanupRunRepository
  )
import Prodbox.Vault.Client
  ( VaultKubernetesLoginResult (..)
  , vaultKubernetesLoginWithLease
  )
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.Timeout (timeout)

data ControlPlaneConfig = ControlPlaneConfig
  { schema_version :: !Natural
  , runtime_role :: !Text
  , vault_address :: !Text
  , vault_auth_path :: !Text
  , vault_role :: !Text
  , service_account_token_file :: !Text
  , cluster_id :: !Text
  , target_agent_identity :: !Text
  , role_store :: !ControlPlaneRoleStore
  , request_authentication :: !ControlPlaneAuthenticationWire
  }
  deriving (Generic, Show)

instance Dhall.FromDhall ControlPlaneConfig

data PrimaryStoreWire = PrimaryStoreWire
  { primary_endpoint :: !Text
  , primary_bucket :: !Text
  }
  deriving (Generic, Show)

instance Dhall.FromDhall PrimaryStoreWire

data AuthorityBackupStoreWire = AuthorityBackupStoreWire
  { authority_backup_endpoint :: !Text
  , authority_backup_region :: !Text
  , authority_backup_bucket :: !Text
  , authority_backup_prefix :: !Text
  }
  deriving (Generic, Show)

instance Dhall.FromDhall AuthorityBackupStoreWire

data TlsRetentionStoreWire = TlsRetentionStoreWire
  { tls_retention_endpoint :: !Text
  , tls_retention_region :: !Text
  , tls_retention_bucket :: !Text
  , tls_retention_substrate :: !Text
  , tls_retention_scope_key :: !Text
  , tls_retention_prefix :: !Text
  }
  deriving (Generic, Show)

instance Dhall.FromDhall TlsRetentionStoreWire

-- | Closed schema-v7 store choice.  The constructor itself is validated against
-- the executable's selected role before Vault authentication or listener bind;
-- one role therefore cannot substitute another role's bucket/prefix record.
data ControlPlaneRoleStore
  = RoleStoreNone
  | RoleStoreProviderWorker
  | RoleStoreTargetSecretAgent
  | RoleStorePrimary !PrimaryStoreWire
  | RoleStoreAuthorityBackup !AuthorityBackupStoreWire
  | RoleStoreTlsRetention !TlsRetentionStoreWire
  deriving (Generic, Show)

instance Dhall.FromDhall ControlPlaneRoleStore where
  autoWith _ =
    Dhall.genericAutoWith
      Dhall.defaultInterpretOptions
        { Dhall.constructorModifier = stripRoleStorePrefix
        }

stripRoleStorePrefix :: Text -> Text
stripRoleStorePrefix value =
  maybe value id (Text.stripPrefix "RoleStore" value)

data ValidatedRoleStore
  = ValidatedPrimaryStore !InClusterAuthorityStoreConfig
  | ValidatedAuthorityBackupStore !AuthorityBackupStoreConfig
  | ValidatedTlsRetentionStore !TlsRetentionStoreConfig
  | ValidatedProviderWorkerStore
  | ValidatedTargetSecretAgentStore
  | ValidatedNoStore
  deriving (Show)

data ControlPlaneConfigError
  = ControlPlaneConfigVersionUnsupported
  | ControlPlaneConfigRoleMismatch
  | ControlPlaneConfigTargetAgentIdentityInvalid
  | ControlPlaneConfigTargetAgentClusterMismatch
  | ControlPlaneConfigStoreRoleMismatch
  | ControlPlaneConfigAuthenticationInvalid !ControlPlaneAuthenticationConfigError
  | ControlPlaneConfigAuthorityStoreInvalid !InClusterAuthorityStoreConfigError
  | ControlPlaneConfigDedicatedStoreInvalid !DedicatedAdapterStoreError
  deriving (Eq, Show)

data LifecycleAuthorityCoordinates = LifecycleAuthorityCoordinates
  { lifecycleCheckpointAuthority :: !LongLivedCheckpointAuthority
  , lifecycleAuthorityAdmissionCoordinate :: !(ModelBObjectCoordinate 'ClusterRetained)
  , lifecycleAuthorityRequestReplayCoordinate :: !(ModelBObjectCoordinate 'ClusterRetained)
  , lifecycleAuthorityDecommissionManifestCoordinate
      :: !(ModelBObjectCoordinate 'ClusterRetained)
  , lifecycleAuthorityExternalMaterialIngressCoordinate
      :: !(ModelBObjectCoordinate 'ClusterRetained)
  , lifecycleAuthorityFirstReconcileCoordinate
      :: !(ModelBObjectCoordinate 'ClusterRetained)
  , lifecycleAuthorityRetainedSesSmtpCoordinate
      :: !(ModelBObjectCoordinate 'ClusterRetained)
  , lifecycleAuthorityRetainedAcmeEabCoordinate
      :: !(ModelBObjectCoordinate 'ClusterRetained)
  }
  deriving (Eq, Show)

-- | Startup is selected from an authoritative retained registration fact,
-- never from a process default.  A missing registration is the clean-install
-- choreography; an observed registration is an upgrade/import.  Ambiguous or
-- unavailable observations refuse startup rather than guessing which writer
-- owns the epoch.
data AuthorityStartupMode
  = AuthorityCleanInstallStartup
  | AuthorityMigrationStartup
  deriving (Eq, Show)

authorityStartupModeFromRegistration
  :: ModelBObservation registration
  -> Either Text AuthorityStartupMode
authorityStartupModeFromRegistration observation = case observation of
  ModelBMissing -> Right AuthorityCleanInstallStartup
  ModelBObserved {} -> Right AuthorityMigrationStartup
  ModelBCorrupt detail ->
    Left ("projection-import registration is corrupt: " <> detail)
  ModelBEndpointUnready detail ->
    Left ("projection-import registration endpoint is not ready: " <> detail)
  ModelBUnobservable detail ->
    Left ("projection-import registration is unobservable: " <> detail)

lifecycleAuthoritySubmissionCapacity :: Natural
lifecycleAuthoritySubmissionCapacity = 256

lifecycleAuthorityRetainedSubmissionCapacity :: Natural
lifecycleAuthorityRetainedSubmissionCapacity = 1024

-- | Derive the immutable operation-client registry from the exact trust
-- entries on @operations/submit@.  Authentication and admission therefore
-- cannot drift into the prior state where a caller authenticated successfully
-- but every submission was refused because the retained aggregate had been
-- initialized with an empty client table.
registeredClientTableFromTrustRegistry
  :: RouteTrustRegistry -> Either Text RegisteredClientTable
registeredClientTableFromTrustRegistry trustRegistry = do
  specs <- traverse registeredSpec trustedKeys
  if null specs
    then Left "Lifecycle Authority operation-submit trust registry is empty"
    else
      mapLeft
        (Text.pack . show)
        (mkRegisteredClientTable (fromIntegral (length specs)) specs)
 where
  trustedKeys = routeTrustRegistryKeysFor LifecycleOperationSubmit trustRegistry
  registeredSpec trusted = do
    let caller = trustedRequestCallerPrincipal trusted
    slot <-
      mapLeft
        (Text.pack . show)
        (mkRegisteredClientSlot (fromIntegral (callerPrincipalCode caller)))
    generation <-
      mapLeft
        (Text.pack . show)
        ( mkRegisteredClientGeneration
            (signingKeyGenerationValue (trustedRequestGeneration trusted))
        )
    mapLeft
      (Text.pack . show)
      ( mkRegisteredClientSpec
          (clientPrincipalForCaller caller)
          slot
          generation
          lifecycleAuthorityRetainedSubmissionCapacity
      )

mkLifecycleAuthorityCoordinates
  :: InClusterAuthorityStoreConfig
  -> Either AuthorityCoordinateError LifecycleAuthorityCoordinates
mkLifecycleAuthorityCoordinates storeConfig = do
  authority <- inClusterAuthorityCheckpointAuthority storeConfig
  admission <-
    mkClusterRetainedCoordinate authority "authority/admission"
  replay <-
    mkClusterRetainedCoordinate authority "authority/request-replay"
  decommissionManifest <-
    mkClusterRetainedCoordinate authority "authority/decommission-manifest"
  externalMaterialIngress <-
    mkClusterRetainedCoordinate authority "authority/external-material-ingress"
  firstReconcile <-
    mkClusterRetainedCoordinate authority "authority/credential-provisioner/first-reconcile"
  retainedSesSmtp <-
    mkClusterRetainedCoordinate authority "retained-material/custody/ses-smtp-source"
  retainedAcmeEab <-
    mkClusterRetainedCoordinate authority "retained-material/custody/acme-eab-source"
  pure
    LifecycleAuthorityCoordinates
      { lifecycleCheckpointAuthority = authority
      , lifecycleAuthorityAdmissionCoordinate = admission
      , lifecycleAuthorityRequestReplayCoordinate = replay
      , lifecycleAuthorityDecommissionManifestCoordinate = decommissionManifest
      , lifecycleAuthorityExternalMaterialIngressCoordinate = externalMaterialIngress
      , lifecycleAuthorityFirstReconcileCoordinate = firstReconcile
      , lifecycleAuthorityRetainedSesSmtpCoordinate = retainedSesSmtp
      , lifecycleAuthorityRetainedAcmeEabCoordinate = retainedAcmeEab
      }

-- | Complete production composition for the Lifecycle Authority.  Both
-- repositories share the dedicated in-cluster encrypted store but retain exact,
-- distinct @'ClusterRetained'@ coordinates and codecs.  Readiness is the store's
-- signed S3 probe, not socket liveness.
lifecycleAuthorityRuntimeInterpreter
  :: ControlPlaneVaultConfig
  -> VaultSession
  -> RouteTrustRegistry
  -> RequestSigningCapability IO
  -> InClusterAuthorityStore
  -> LifecycleAuthorityCoordinates
  -> TargetAgentIdentity
  -> IO (Either Text (RoleInterpreter IO, RoleReadinessObserver))
lifecycleAuthorityRuntimeInterpreter vaultConfig vaultSession trustRegistry clientSigner store coordinates registeredAgentIdentity = do
  -- Sprint 4.55: five layers of this role's handler stack each took
  -- `inClusterAuthorityReady store` — a signed S3 LIST through the dedicated
  -- principal — and composed them with `&&`, so a single kubelet probe against
  -- a `timeoutSeconds: 1` budget performed five sequential signed LISTs and none
  -- of them short-circuited. The store is one dependency; it is observed once,
  -- in the background, and the four outer layers contribute nothing of their own.
  readinessObserver <-
    newRoleReadinessObserver
      controlPlaneRoleReadinessSchedule
      "lifecycle-authority-dependencies"
      monotonicNowMicros
      ( do
          observed <- inClusterAuthorityReady store
          custodyDependency <- observeTargetChildCustodyDependency vaultSession
          handoffDependency <- observeBootstrapHandoffDependency vaultSession
          pure
            [
              ( "authority-object-store"
              , if observed
                  then RoleDependencyReady
                  else
                    RoleDependencyUnavailable
                      "the retained Authority object store did not answer a signed list"
              )
            , custodyDependency
            , handoffDependency
            ]
      )
  let authorityReadiness = roleReadinessObserverSource readinessObserver
  let registeredClientsResult = registeredClientTableFromTrustRegistry trustRegistry
  initialAdmissionResult <- case registeredClientsResult of
    Left detail -> pure (Left detail)
    Right registeredClients -> resolveInitialAdmission registeredClients
  case do
    registeredClients <- registeredClientsResult
    initialAdmission <- initialAdmissionResult
    authorityScope <-
      mapLeft (Text.pack . show) (mkAuthorityScope (checkpointAuthorityClusterId authority))
    transportBounds <-
      mapLeft
        (Text.pack . show)
        ( mkAuthenticatedTransportBounds
            lifecycleAuthorityAuthenticatedFrameMaximumBytes
            lifecycleAuthorityAuthenticationMetadataMaximumBytes
            lifecycleAuthoritySignedEnvelopeMaximumBytes
        )
    maximumLifetime <-
      mapLeft
        (Text.pack . show)
        (authorityDurationFromMicros lifecycleAuthorityAuthenticationLifetimeMicros)
    replayClockSkew <-
      mapLeft
        (Text.pack . show)
        (authorityDurationFromMicros lifecycleAuthorityReplayClockSkewMicros)
    replayLimits <-
      mapLeft
        (Text.pack . show)
        ( mkRequestReplayLimits
            lifecycleAuthorityReplayCapacity
            lifecycleAuthorityReplayResponseMaximumBytes
            replayClockSkew
        )
    casAttempts <-
      mapLeft (Text.pack . show) (mkReplayCasAttempts lifecycleAuthorityReplayCasAttempts)
    backupEndpoint <-
      mapLeft
        (Text.pack . show)
        (mkAuthorityBackupEndpoint authorityBackupServiceEndpoint)
    backupTransport <-
      mapLeft
        (Text.pack . show)
        ( newControlPlaneClient
            defaultHttpConfig
            authorityCheckpointBackupMaximumResponseBytes
            backupEndpoint
        )
    targetEndpoint <-
      mapLeft
        (Text.pack . show)
        (mkTargetSecretAgentEndpoint targetSecretAgentServiceEndpoint)
    targetClient <-
      mapLeft
        (Text.pack . show)
        ( newControlPlaneClient
            defaultHttpConfig
            targetDecommissionInventoryMaximumResponseBytes
            targetEndpoint
        )
    localAuthorityEndpoint <-
      mapLeft
        (Text.pack . show)
        (mkLifecycleAuthorityEndpoint lifecycleAuthorityServiceEndpoint)
    localAuthorityClient <-
      mapLeft
        (Text.pack . show)
        ( newControlPlaneClient
            defaultHttpConfig
            lifecycleAuthorityAuthenticatedFrameMaximumBytes
            localAuthorityEndpoint
        )
    providerEndpoint <-
      mapLeft
        (Text.pack . show)
        (mkProviderWorkerEndpoint providerWorkerServiceEndpoint)
    providerClient <-
      mapLeft
        (Text.pack . show)
        ( newControlPlaneClient
            defaultHttpConfig
            providerWorkerResponseMaximumBytes
            providerEndpoint
        )
    pure
      ( registeredClients
      , initialAdmission
      , authorityScope
      , transportBounds
      , maximumLifetime
      , replayLimits
      , casAttempts
      , backupTransport
      , targetClient
      , localAuthorityClient
      , providerClient
      ) of
    Left detail -> pure (Left detail)
    Right
      ( registeredClients
        , initialAdmission
        , authorityScope
        , transportBounds
        , maximumLifetime
        , replayLimits
        , casAttempts
        , backupTransport
        , targetClient
        , localAuthorityClient
        , providerClient
        ) -> do
        let admissionCodec =
              authorityAdmissionStateCodecWithRegisteredClients
                authorityAdmissionMaximumEncodedBytes
                lifecycleAuthoritySubmissionCapacity
                lifecycleAuthorityRetainedSubmissionCapacity
                registeredClients
            baseAdmissionRepository =
              modelBAuthorityAdmissionRepository
                initialAdmission
                ( inClusterAuthorityModelBCasAdapter
                    store
                    authority
                    admissionCodec
                )
                (lifecycleAuthorityAdmissionCoordinate coordinates)
            admissionRepository =
              authorityAdmissionWithRetainedEpoch vaultSession baseAdmissionRepository
            replayRepository =
              modelBRequestReplayRepository
                (initialRequestReplayProjection replayLimits)
                ( inClusterAuthorityModelBCasAdapter
                    store
                    authority
                    (requestReplayCodec lifecycleAuthorityReplayMaximumEncodedBytes replayLimits)
                )
                (lifecycleAuthorityRequestReplayCoordinate coordinates)
            runtimeInputs =
              AuthenticatedRuntimeInputs
                LifecycleAuthorityRuntime
                transportBounds
                maximumLifetime
                AuthenticatedRoleProviders
                  { authenticatedRoleServerProviders =
                      AuthenticatedServerProviders
                        { provideAuthenticatedServerScope = pure (Right authorityScope)
                        , provideAuthenticatedServerEpoch =
                            provideAuthenticationAuthorityEpoch admissionRepository
                        , provideAuthenticatedServerTime = currentAuthorityTime
                        , provideAuthenticatedServerTrustRegistry = pure (Right trustRegistry)
                        }
                  , provideAuthenticatedReplayAttempt = freshReplayAttempt
                  }
                casAttempts
                replayLimits
                replayRepository
            checkpointClientProviders =
              transitAuthenticatedClientProviders
                clientSigner
                (pure (Right authorityScope))
                (provideAuthenticationAuthorityEpoch admissionRepository)
                maximumLifetime
            targetTransport =
              mkAuthenticatedClientTransport
                transportBounds
                checkpointClientProviders
                targetClient
            localAuthorityTransport =
              mkAuthenticatedClientTransport
                transportBounds
                checkpointClientProviders
                localAuthorityClient
            providerTransport =
              mkAuthenticatedClientTransport
                transportBounds
                checkpointClientProviders
                providerClient
            backupClient =
              authorityCheckpointBackupClient
                transportBounds
                checkpointClientProviders
                backupTransport
            aggregateBackupClient =
              authorityAggregateBackupClientWithTransport
                ( mkAuthenticatedClientTransport
                    transportBounds
                    checkpointClientProviders
                    backupTransport
                )
            checkpointBlobStore =
              productionPulumiCheckpointBlobStore
                store
                backupClient
            checkpointRepository =
              aggregatePulumiCheckpointRepository
                admissionRepository
                checkpointBlobStore
            configRepository =
              aggregateConfigAuthorityRepository
                admissionRepository
                ( productionConfigBlobStore
                    store
                    ( configBackupClient
                        transportBounds
                        checkpointClientProviders
                        backupTransport
                    )
                )
                productionConfigPayloadCompiler
            cleanupRunProvider =
              CleanupRunRepositoryProvider
                { cleanupRunRepositoryFor = cleanupRunRepositoryForId
                , cleanupRunIndexRepository = cleanupRunIndexRepo
                , cleanupRunAggregateBackup = aggregateBackupClient
                }
            cleanupRunIndexRepo =
              case mkClusterRetainedCoordinate authority "authority/cleanup-runs/index" of
                Left detail ->
                  CleanupRunIndexRepository
                    { readCleanupRunIndex = pure (Left (Text.pack (show detail)))
                    , compareAndSwapCleanupRunIndex = \_ _ -> pure (Left (Text.pack (show detail)))
                    }
                Right coordinate ->
                  replicatedCleanupRunIndexRepository
                    (1024 * 1024)
                    aggregateBackupClient
                    ( modelBCleanupRunIndexRepository
                        ( inClusterAuthorityModelBCasAdapter
                            store
                            authority
                            (cleanupRunIndexCodec (1024 * 1024))
                        )
                        coordinate
                    )
            cleanupRunRepositoryForId runId =
              case mkClusterRetainedCoordinate
                authority
                ("authority/cleanup-runs/" <> cleanupRunIdText runId) of
                Left detail ->
                  CleanupRunRepository
                    { readCleanupRun = pure (Left (Text.pack (show detail)))
                    , compareAndSwapCleanupRun = \_ _ -> pure (Left (Text.pack (show detail)))
                    , compareAndSwapCleanupRunTombstone = \_ _ -> pure (Left (Text.pack (show detail)))
                    }
                Right coordinate ->
                  replicatedCleanupRunRepository
                    (1024 * 1024)
                    aggregateBackupClient
                    ( modelBCleanupRunRepository
                        ( inClusterAuthorityModelBCasAdapter
                            store
                            authority
                            (cleanupRunStoredCodec (1024 * 1024))
                        )
                        coordinate
                    )
            baseAuthenticatedHandler =
              lifecycleAuthorityAdmissionAuthenticatedHandler
                controlPlaneMaximumBodyBytes
                authorityReadiness
                (checkpointAuthorityClusterId authority)
                currentAuthorityTimeMicros
                (first Text.pack . encodeModelBValue admissionCodec)
                admissionRepository
                configRepository
                (projectionImportHandler admissionRepository)
                retainedLeaseHandler
                (mkPulumiCheckpointHandler checkpointRepository)
                cleanupRunProvider
            manifestSigner = vaultAuthorityManifestSigner vaultSession
            externalMaterialRepository =
              modelBExternalMaterialIngressRepository
                ( inClusterAuthorityModelBCasAdapter
                    store
                    authority
                    ( externalMaterialIngressStateCodec
                        externalMaterialIngressMaximumEncodedBytes
                    )
                )
                (lifecycleAuthorityExternalMaterialIngressCoordinate coordinates)
            awsAdminRepositoryResolver operationId = do
              coordinate <-
                mapLeft
                  (Text.pack . show)
                  ( mkClusterRetainedCoordinate
                      authority
                      ("authority/aws-admin/" <> operationId)
                  )
              Right
                ( modelBAwsAdminAuthorityRepository
                    ( inClusterAuthorityModelBCasAdapter
                        store
                        authority
                        awsAdminAuthorityStateCodec
                    )
                    coordinate
                )
            awsAdminTargetLifecycle =
              productionAwsAdminPreparedTargetLifecycle
                store
                authority
                admissionRepository
                (lifecycleAuthorityFirstReconcileCoordinate coordinates)
                registeredAgentIdentity
                currentAuthorityTime
            adminActionRepositoryResolver operationId = do
              coordinate <-
                mapLeft
                  (Text.pack . show)
                  ( mkClusterRetainedCoordinate
                      authority
                      ("authority/admin-actions/" <> operationId)
                  )
              Right
                ( modelBAdminActionAuthorityRepository
                    ( inClusterAuthorityModelBCasAdapter
                        store
                        authority
                        (adminActionExecutionStateCodec adminActionStateMaximumEncodedBytes)
                    )
                    coordinate
                )
            adminActionEffectRepositoryResolver operationId = do
              coordinate <-
                mapLeft
                  (Text.pack . show)
                  ( mkClusterRetainedCoordinate
                      authority
                      ("authority/admin-action-effects/" <> operationId)
                  )
              Right
                ( modelBAdminActionEffectRepository
                    ( inClusterAuthorityModelBCasAdapter
                        store
                        authority
                        ( adminActionEffectStateCodec
                            adminActionEffectMaximumEncodedBytes
                        )
                    )
                    coordinate
                )
            adminActionBoundary =
              AdminActionAuthorityBoundary
                { adminActionAuthorityScope = checkpointAuthorityClusterId authority
                , adminActionAuthorityEndpoint = lifecycleAuthorityServiceEndpoint
                , adminActionAuthorityNow = currentAuthorityTime
                , freshAdminActionNonce = freshAdminActionNonceProduction
                , backupAdminActionPermitCore = backupAdminActionCore backupClient
                , adminActionAuthoritySigner = vaultAuthorityManifestSigner vaultSession
                }
            tlsAuthorityRepositoryResolver slot = do
              coordinate <- tlsRetentionAuthorityCoordinate authority slot
              Right
                ( modelBTlsRetentionAuthorityRepository
                    ( inClusterAuthorityModelBCasAdapter
                        store
                        authority
                        tlsRetentionStateCodec
                    )
                    coordinate
                )
            retainedSesSmtpRepository =
              modelBRetainedMaterialRepository
                ( inClusterAuthorityModelBCasAdapter
                    store
                    authority
                    (retainedMaterialModelBCodec SRetainedSesSmtpMaterial)
                )
                (lifecycleAuthorityRetainedSesSmtpCoordinate coordinates)
            retainedAcmeEabRepository =
              modelBRetainedMaterialRepository
                ( inClusterAuthorityModelBCasAdapter
                    store
                    authority
                    (retainedMaterialModelBCodec SRetainedAcmeEabMaterial)
                )
                (lifecycleAuthorityRetainedAcmeEabCoordinate coordinates)
        synchronized <- readAuthorityAdmission admissionRepository
        signerResult <- readAuthorityManifestPublicKey manifestSigner
        pure $ do
          _ <- synchronized
          (_, manifestPublicKey) <- signerResult
          targetWorkerImage <-
            mapLeft
              ("registered Target Agent rollout is not an image digest: " <>)
              (mkTargetWorkerImageDigest (targetAgentRolloutDigest registeredAgentIdentity))
          let signerDigest = manifestPublicKeyDigest manifestPublicKey
              retainedTargetObserver target = do
                observed <-
                  observeRegisteredTargetMaterial
                    (targetMaterialClient targetTransport)
                    target
                pure $ case observed of
                  Left err -> Left (Text.take 256 (Text.pack (show err)))
                  Right Nothing -> Right Nothing
                  Right (Just metadata) ->
                    Just
                      <$> targetWorkerReceiptFromMaterialObservation target metadata
              retainedTargetBoundary =
                productionTargetMaterializationBoundary
                  (controlPlaneVaultAddress vaultConfig)
                  (controlPlaneVaultAuthPath vaultConfig)
                  targetSecretControllerAuditorVaultRole
                  (readProjectedServiceAccountJwt lifecycleAuthorityTargetControllerTokenFile)
                  TargetWorkerJobConnection
                    { targetWorkerJobEnvironment = Nothing
                    , targetWorkerJobWorkingDirectory = "/opt/build"
                    , targetWorkerJobImageRepository =
                        "127.0.0.1:30080/prodbox/prodbox-runtime"
                    , targetWorkerJobMaximumRuntimeSeconds = 180
                    }
                  (targetIntentAuthorityClient localAuthorityTransport)
                  currentAuthorityTime
              retainedRewrapClient =
                targetRetainedMaterialRewrapClient targetTransport
              retainedDeliveryBoundary =
                RetainedMaterialDeliveryBoundary
                  { deliverRetainedSesSmtp = \now source request ->
                      if retainedMaterialTargetText (retainedDeliveryRequestTarget request)
                        /= targetAgentClusterIdentity registeredAgentIdentity
                        then pure (Left "retained delivery target is not the registered Target Agent")
                        else case mkCrossClusterDurableCoordinate
                          authority
                          ( "retained-material/delivery/"
                              <> retainedMaterialSchemaToken SRetainedSesSmtpMaterial
                              <> "/"
                              <> retainedMaterialTargetText (retainedDeliveryRequestTarget request)
                          ) of
                          Left err -> pure (Left (Text.pack (show err)))
                          Right outboxCoordinate -> do
                            sourceReady <-
                              ensureRetainedMaterialCurrentSource
                                retainedSesSmtpRepository
                                now
                                source
                                request
                            case sourceReady of
                              Left detail -> pure (Left detail)
                              Right () ->
                                coordinateRetainedMaterialDelivery
                                  ( modelBRetainedMaterialRepository
                                      ( inClusterAuthorityModelBCasAdapter
                                          store
                                          authority
                                          (retainedMaterialModelBCodec SRetainedSesSmtpMaterial)
                                      )
                                      outboxCoordinate
                                  )
                                  now
                                  source
                                  request
                                  (\_ -> retainedTargetObserver TargetSesSmtp)
                                  ( \keyPair intent ->
                                      fmap retainedMaterialDeliveryTargetReceipt
                                        <$> productionRetainedMaterialDeliveryWithKeyPair
                                          SRetainedSesSmtpMaterial
                                          retainedTargetBoundary
                                          retainedRewrapClient
                                          registeredAgentIdentity
                                          targetWorkerImage
                                          now
                                          keyPair
                                          source
                                          intent
                                  )
                  , deliverRetainedAcmeEab = \now source request ->
                      if retainedMaterialTargetText (retainedDeliveryRequestTarget request)
                        /= targetAgentClusterIdentity registeredAgentIdentity
                        then pure (Left "retained delivery target is not the registered Target Agent")
                        else case mkCrossClusterDurableCoordinate
                          authority
                          ( "retained-material/delivery/"
                              <> retainedMaterialSchemaToken SRetainedAcmeEabMaterial
                              <> "/"
                              <> retainedMaterialTargetText (retainedDeliveryRequestTarget request)
                          ) of
                          Left err -> pure (Left (Text.pack (show err)))
                          Right outboxCoordinate -> do
                            sourceReady <-
                              ensureRetainedMaterialCurrentSource
                                retainedAcmeEabRepository
                                now
                                source
                                request
                            case sourceReady of
                              Left detail -> pure (Left detail)
                              Right () ->
                                coordinateRetainedMaterialDelivery
                                  ( modelBRetainedMaterialRepository
                                      ( inClusterAuthorityModelBCasAdapter
                                          store
                                          authority
                                          (retainedMaterialModelBCodec SRetainedAcmeEabMaterial)
                                      )
                                      outboxCoordinate
                                  )
                                  now
                                  source
                                  request
                                  (\_ -> retainedTargetObserver TargetAcmeEab)
                                  ( \keyPair intent ->
                                      fmap retainedMaterialDeliveryTargetReceipt
                                        <$> productionRetainedMaterialDeliveryWithKeyPair
                                          SRetainedAcmeEabMaterial
                                          retainedTargetBoundary
                                          retainedRewrapClient
                                          registeredAgentIdentity
                                          targetWorkerImage
                                          now
                                          keyPair
                                          source
                                          intent
                                  )
                  }
              manifestRepository =
                modelBDecommissionCommitRepository
                  ( inClusterAuthorityModelBCasAdapter
                      store
                      authority
                      ( decommissionManifestCodec
                          decommissionManifestMaximumEncodedBytes
                          signerDigest
                      )
                  )
                  (lifecycleAuthorityDecommissionManifestCoordinate coordinates)
              (exportRepository, stopRepository) =
                authorityDecommissionRepositories
                  lifecycleAuthorityDecommissionCasAttempts
                  admissionRepository
                  manifestRepository
                  (discoverProductionDecommissionPlan targetTransport)
              externalMaterialHandler =
                externalMaterialIngressAuthenticatedHandler
                  controlPlaneMaximumBodyBytes
                  lifecycleAuthorityExternalMaterialCasAttempts
                  currentAuthorityTime
                  noRoleReadinessContribution
                  externalMaterialRepository
                  manifestSigner
                  baseAuthenticatedHandler
              providerHandler =
                authorityProviderDispatchAuthenticatedHandler
                  controlPlaneMaximumBodyBytes
                  AuthorityProviderDispatchBoundary
                    { authorityProviderAdmissionRepository = admissionRepository
                    , authorityProviderSigningCapability = clientSigner
                    , authorityProviderNow = currentAuthorityTime
                    , authorityProviderIntentLifetime = maximumLifetime
                    , authorityProviderRevision =
                        pure (mkProviderRevision 1)
                    , authorityProviderWorkerDispatch =
                        fmap (mapLeft (Text.pack . show))
                          . dispatchProviderCommittedIntent providerTransport
                    }
                  externalMaterialHandler
              awsAdminHandler =
                awsAdminProvisionerAuthenticatedHandler
                  awsAdminProvisionerMaximumBytes
                  noRoleReadinessContribution
                  currentAuthorityTime
                  awsAdminRepositoryResolver
                  awsAdminTargetLifecycle
                  manifestSigner
                  providerHandler
              adminActionHandler =
                adminActionAuthenticatedHandler
                  adminActionEndpointMaximumBytes
                  noRoleReadinessContribution
                  adminActionRepositoryResolver
                  adminActionBoundary
                  awsAdminHandler
              adminActionExecutionHandler =
                lifecycleAuthorityAdminActionExecutionAuthenticatedHandler
                  adminActionAuthorityExecutionMaximumBytes
                  ( adminActionExecutionBoundaryForCaller
                      admissionRepository
                      checkpointRepository
                      manifestSigner
                      (checkpointAuthorityClusterId authority)
                  )
                  adminActionEffectRepositoryResolver
                  adminActionRepositoryResolver
                  adminActionHandler
              decommissionHandler =
                lifecycleAuthorityDecommissionAuthenticatedHandler
                  controlPlaneMaximumBodyBytes
                  ( LifecycleAuthorityDecommissionProvisioned
                      exportRepository
                      manifestSigner
                      signerDigest
                      stopRepository
                  )
                  adminActionExecutionHandler
              tlsAuthenticatedHandler =
                lifecycleAuthorityTlsRetentionAuthenticatedHandler
                  controlPlaneMaximumBodyBytes
                  tlsAuthorityRepositoryResolver
                  decommissionHandler
              targetIntentBoundary =
                productionTargetIntentIssuerBoundary
                  store
                  authority
                  registeredAgentIdentity
                  ( fmap
                      (fmap (Coordinate.AuthorityEpoch . authorityEpochValue))
                      (readRetainedAuthorityEpoch vaultSession)
                  )
                  currentAuthorityTime
                  manifestSigner
                  (Text.pack (runtimeRoleName LifecycleAuthorityRuntime))
                  (targetAuthorityTrustClient targetTransport)
              handoffHandler =
                bootstrapHandoffAuthenticatedHandler
                  controlPlaneMaximumBodyBytes
                  (vaultBootstrapHandoffRepository vaultSession noRoleReadinessContribution)
                  tlsAuthenticatedHandler
              federationBoundary =
                FederationRegistrationBoundary
                  { resolveFederationRegistrationRepository = \operationDigest -> do
                      coordinate <-
                        mapLeft
                          (Text.pack . show)
                          ( mkClusterRetainedCoordinate
                              authority
                              ( "authority/federation-registration/"
                                  <> renderArtifactDigest
                                    operationDigest
                              )
                          )
                      Right
                        ( modelBFederationRegistrationRepository
                            ( inClusterAuthorityModelBCasAdapter
                                store
                                authority
                                ( federationRegistrationStateCodec
                                    federationRegistrationMaximumBytes
                                )
                            )
                            coordinate
                            noRoleReadinessContribution
                        )
                  , prepareFederationParentEnvelope = \_ _ ->
                      pure (Left "federation parent-envelope worker is not installed")
                  , completeFederationParentBootstrap = \_ _ ->
                      pure (Left "federation parent bootstrap-custody worker is not installed")
                  , commitFederationRegistrationTarget = \selectedAgent intent ->
                      if selectedAgent /= registeredAgentIdentity
                        then pure (Left "selected parent Target Agent identity differs from the registered rollout")
                        else
                          fmap
                            (mapLeft (Text.pack . show))
                            ( BootstrapCustody.commitChildCustody
                                (BootstrapCustody.bootstrapCustodyClient targetTransport)
                                intent
                            )
                  , federationRegistrationBoundaryReadiness = noRoleReadinessContribution
                  }
              federationHandler =
                federationRegistrationAuthenticatedHandler
                  federationRegistrationMaximumBytes
                  federationBoundary
                  handoffHandler
              retainedDeliveryHandler =
                retainedMaterialDeliveryAuthenticatedHandler
                  controlPlaneMaximumBodyBytes
                  currentAuthorityTime
                  retainedDeliveryBoundary
                  federationHandler
              authenticatedHandler =
                targetIntentIssueAuthenticatedHandler
                  controlPlaneMaximumBodyBytes
                  targetIntentBoundary
                  retainedDeliveryHandler
          mapLeft
            (Text.pack . show)
            ( fmap
                (,readinessObserver)
                ( installAuthenticatedRuntimeInterpreter
                    LifecycleAuthorityRuntime
                    runtimeInputs
                    authenticatedHandler
                )
            )
 where
  authority = lifecycleCheckpointAuthority coordinates
  discoverProductionDecommissionPlan targetTransport = do
    inventoryResult <- requestTargetDecommissionInventory targetTransport
    pure $ do
      inventory <- inventoryResult
      let authorityIdentity = checkpointAuthorityClusterId authority
          targetIdentity = targetDecommissionInventoryReference inventory
      if targetIdentity /= authorityIdentity
        then
          Left
            ( "Target Secret Agent decommission identity mismatch: authority="
                <> authorityIdentity
                <> ", target="
                <> targetIdentity
            )
        else
          mapLeft
            (Text.pack . show)
            ( mkDecommissionManifest
                authorityIdentity
                ( productionDecommissionSingletonPrefix
                    ++ maybe
                      []
                      (\generation -> [TargetGeneration targetIdentity generation])
                      (targetDecommissionInventoryGeneration inventory)
                    ++ productionDecommissionSingletonSuffix
                )
            )
  resolveInitialAdmission registeredClients =
    case projectionImportRegistrationCoordinate authority of
      Left err -> pure (Left (Text.pack (show err)))
      Right registrationCoordinate -> do
        observed <- modelBObserve registrationAdapter registrationCoordinate
        pure $ do
          mode <- authorityStartupModeFromRegistration observed
          mapLeft
            (Text.pack . show)
            ( case mode of
                AuthorityCleanInstallStartup ->
                  initialCleanInstallAuthorityWithRegisteredClients
                    lifecycleAuthoritySubmissionCapacity
                    lifecycleAuthorityRetainedSubmissionCapacity
                    registeredClients
                AuthorityMigrationStartup ->
                  initialMigratingAuthorityWithRegisteredClients
                    lifecycleAuthoritySubmissionCapacity
                    lifecycleAuthorityRetainedSubmissionCapacity
                    registeredClients
            )
  projectionImportHandler admissionRepository =
    resolvingProjectionImportHandler
      (resolveProjectionImportHandler admissionRepository)
  retainedLeaseHandler =
    resolvingRetainedSesLeaseHandler resolveRetainedLeaseHandler
  resolveRetainedLeaseHandler =
    case projectionImportRegistrationCoordinate authority of
      Left err -> pure (Left (Text.pack (show err)))
      Right registrationCoordinate -> do
        registrationObservation <-
          modelBObserve registrationAdapter registrationCoordinate
        pure $ case registrationObservation of
          ModelBMissing ->
            Left "retained SES lease registration is absent"
          ModelBCorrupt detail ->
            Left ("retained SES lease registration is corrupt: " <> detail)
          ModelBEndpointUnready detail ->
            Left ("retained SES lease registration is not ready: " <> detail)
          ModelBUnobservable detail ->
            Left ("retained SES lease registration is unobservable: " <> detail)
          ModelBObserved _ registration ->
            mapLeft
              (Text.pack . show)
              ( mkRetainedSesLeaseHandler
                  controlPlaneMaximumBodyBytes
                  defaultSesLeasePolicy
                  authority
                  (projectionImportRegistrationLeaseKey registration)
                  retainedLeaseAdapter
              )
  resolveProjectionImportHandler admissionRepository =
    case ( projectionImportRegistrationCoordinate authority
         , legacyProjectionAuthority authority
         ) of
      (Left err, _) -> pure (Left (Text.pack (show err)))
      (_, Left err) -> pure (Left (Text.pack (show err)))
      (Right registrationCoordinate, Right legacyAuthority) -> do
        registrationObservation <-
          modelBObserve registrationAdapter registrationCoordinate
        pure $ case registrationObservation of
          ModelBMissing ->
            Left "legacy projection import registration is absent"
          ModelBCorrupt detail ->
            Left ("legacy projection import registration is corrupt: " <> detail)
          ModelBEndpointUnready detail ->
            Left ("legacy projection import registration is not ready: " <> detail)
          ModelBUnobservable detail ->
            Left ("legacy projection import registration is unobservable: " <> detail)
          ModelBObserved _ registration ->
            buildProjectionImportHandler admissionRepository legacyAuthority registration
  registrationAdapter =
    inClusterAuthorityModelBCasAdapter
      store
      authority
      (projectionImportRegistrationModelBCodec (checkpointAuthorityClusterId authority))
  retainedLeaseAdapter =
    inClusterAuthorityModelBCasAdapter
      store
      authority
      (retainedSesLeaseModelBCodec defaultSesLeasePolicy)
  buildProjectionImportHandler admissionRepository legacyAuthority registration = do
    production <-
      mapLeft
        (Text.pack . show)
        ( productionProjectionImportFromRegistration
            legacyAuthority
            authority
            defaultSesLeasePolicy
            registration
        )
    let transport = inClusterAuthorityTransport store
    pure
      ( mkProjectionImportHandlerWithApplicator
          controlPlaneMaximumBodyBytes
          (productionProjectionImportCodecConfig production)
          (authorityAdmissionMigrationImportApplicator admissionRepository)
          (productionLegacyProjectionSource transport production)
          (productionProjectionImportTarget transport production)
      )

adminActionExecutionBoundaryForCaller
  :: AuthorityAdmissionRepository IO revision
  -> PulumiCheckpointRepository IO
  -> AuthorityManifestSigner IO
  -> Text
  -> VerifiedCallerSlot
  -> AdminActionAuthorityExecutionBoundary IO
adminActionExecutionBoundaryForCaller
  admissionRepository
  checkpointRepository
  signer
  authorityScope
  callerSlot =
    AdminActionAuthorityExecutionBoundary
      { adminExecutionAuthoritySigner = signer
      , adminExecutionCurrentTime = currentAuthorityTime
      , adminExecutionLocalAuthorityScope = authorityScope
      , adminExecutionLocalAuthorityEndpoint = lifecycleAuthorityServiceEndpoint
      , adminExecutionLegacyDestination =
          AdminLegacyDestinationBoundary
            { observeAdminLegacyDestination = \_ ->
                observeAdminMigrationCheckpoint checkpointRepository callerSlot
            , publishAdminLegacySource = \_ adminOperationId sourceBytes ->
                publishAdminMigrationCheckpoint
                  admissionRepository
                  checkpointRepository
                  callerSlot
                  adminOperationId
                  sourceBytes
            }
      }

observeAdminMigrationCheckpoint
  :: PulumiCheckpointRepository IO
  -> VerifiedCallerSlot
  -> IO AdminLegacyDestinationObservation
observeAdminMigrationCheckpoint repository callerSlot =
  case registeredPulumiCheckpointByName "aws-ses" of
    Left err -> pure (AdminLegacyDestinationCorrupt (Text.pack (show err)))
    Right registered -> do
      observed <- observeRegisteredPulumiCheckpoint repository callerSlot registered
      pure $ case observed of
        PulumiCheckpointMissing -> AdminLegacyDestinationMissing
        PulumiCheckpointCurrent checkpoint ->
          let digest =
                pulumiCheckpointDigestText (canonicalPulumiCheckpointDigest checkpoint)
           in AdminLegacyDestinationCurrent digest (adminMigrationCheckpointReference digest)
        PulumiCheckpointCorrupt detail -> AdminLegacyDestinationCorrupt detail
        PulumiCheckpointCorruptAt _ detail -> AdminLegacyDestinationCorrupt detail
        PulumiCheckpointEndpointUnready detail ->
          AdminLegacyDestinationUnavailable detail
        PulumiCheckpointUnobservable detail ->
          AdminLegacyDestinationUnavailable detail

publishAdminMigrationCheckpoint
  :: AuthorityAdmissionRepository IO revision
  -> PulumiCheckpointRepository IO
  -> VerifiedCallerSlot
  -> Text
  -> ByteString.ByteString
  -> IO AdminLegacyDestinationPublication
publishAdminMigrationCheckpoint
  admissionRepository
  checkpointRepository
  callerSlot
  adminOperationId
  sourceBytes = do
    environment <- getEnvironment
    canonicalized <-
      canonicalizeLegacyPulumiCheckpoint
        LegacyPulumiBackend
          { legacyPulumiProjectDir = "pulumi/aws-ses"
          , legacyPulumiEnvironment = environment
          , legacyPulumiStackName = "aws-ses"
          }
        (PulumiStackRef "prodbox-aws-ses" "aws-ses")
        sourceBytes
    case canonicalized of
      Left err ->
        pure
          ( AdminLegacyDestinationPublicationRefused
              ("legacy checkpoint conversion refused: " <> Text.pack (renderEncryptedBackendError err))
          )
      Right checkpoint ->
        publishCanonical checkpoint
   where
    publishCanonical checkpoint =
      case registeredPulumiCheckpointByName "aws-ses" of
        Left err ->
          pure (AdminLegacyDestinationPublicationRefused (Text.pack (show err)))
        Right registered -> do
          let candidateDigest = canonicalPulumiCheckpointDigest checkpoint
              candidateText = pulumiCheckpointDigestText candidateDigest
          observed <- observeRegisteredPulumiCheckpoint checkpointRepository callerSlot registered
          case observed of
            PulumiCheckpointCurrent current
              | canonicalPulumiCheckpointDigest current == candidateDigest ->
                  pure
                    ( AdminLegacyDestinationAlreadyCurrent
                        candidateText
                        (adminMigrationCheckpointReference candidateText)
                    )
              | otherwise ->
                  pure
                    ( AdminLegacyDestinationPublicationRefused
                        "registered aws-ses checkpoint already has a different digest"
                    )
            PulumiCheckpointMissing -> do
              admitted <-
                submitAdminMigrationOperation
                  admissionRepository
                  callerSlot
                  adminOperationId
                  candidateText
              case admitted of
                Left detail ->
                  pure (AdminLegacyDestinationPublicationUnavailable detail)
                Right operation -> do
                  published <-
                    publishRegisteredPulumiCheckpoint
                      checkpointRepository
                      callerSlot
                      PulumiCheckpointMutationTicket
                        { pulumiCheckpointTicketOperation = operation
                        , pulumiCheckpointTicketExpectedDigest = Nothing
                        }
                      registered
                      checkpoint
                  pure $ case published of
                    PulumiCheckpointPublished digest ->
                      publicationResult AdminLegacyDestinationPublished digest
                    PulumiCheckpointAlreadyCurrent digest ->
                      publicationResult AdminLegacyDestinationAlreadyCurrent digest
                    PulumiCheckpointPublicationConflict _ ->
                      AdminLegacyDestinationPublicationRefused
                        "registered aws-ses checkpoint publication conflicted"
                    PulumiCheckpointPublicationRefused detail ->
                      AdminLegacyDestinationPublicationRefused detail
                    PulumiCheckpointPublicationUnavailable detail ->
                      AdminLegacyDestinationPublicationUnavailable detail
            PulumiCheckpointCorrupt detail ->
              pure (AdminLegacyDestinationPublicationRefused detail)
            PulumiCheckpointCorruptAt _ detail ->
              pure (AdminLegacyDestinationPublicationRefused detail)
            PulumiCheckpointEndpointUnready detail ->
              pure (AdminLegacyDestinationPublicationUnavailable detail)
            PulumiCheckpointUnobservable detail ->
              pure (AdminLegacyDestinationPublicationUnavailable detail)
    publicationResult constructor digest =
      let digestText = pulumiCheckpointDigestText digest
       in constructor digestText (adminMigrationCheckpointReference digestText)

submitAdminMigrationOperation
  :: AuthorityAdmissionRepository IO revision
  -> VerifiedCallerSlot
  -> Text
  -> Text
  -> IO (Either Text OperationId)
submitAdminMigrationOperation repository callerSlot operationId candidateDigest =
  case mkClientSubmissionKey ("admin-migrate-" <> fingerprint) of
    Left err -> pure (Left (Text.pack (show err)))
    Right submissionKey -> do
      submitted <-
        serveAuthorityOperationSubmit
          repository
          callerSlot
          submissionKey
          (RequestDigest ("sha256-" <> fingerprint))
      pure $ case submitted of
        AuthorityOperationSubmitDecided
          (AuthorityRegisteredSubmissionDecided decision) -> case decision of
            RegisteredSubmissionAccepted operation -> Right operation
            RegisteredSubmissionDuplicate operation -> Right operation
            other -> Left ("admin migration operation refused: " <> Text.pack (show other))
        AuthorityOperationSubmitDecided decision ->
          Left ("admin migration operation refused: " <> Text.pack (show decision))
        AuthorityOperationSubmitReadFailed detail -> Left detail
        AuthorityOperationSubmitWriteFailed detail -> Left detail
        AuthorityOperationSubmitBadRequest _ ->
          Left "admin migration operation identity was rejected"
        AuthorityOperationSubmitInvalidField _ ->
          Left "admin migration operation identity was invalid"
 where
  fingerprint =
    TextEncoding.decodeUtf8
      ( hexSha256
          ( TextEncoding.encodeUtf8
              ( "admin-action-migration-v1\NUL"
                  <> operationId
                  <> "\NUL"
                  <> candidateDigest
              )
          )
      )

adminMigrationCheckpointReference :: Text -> Text
adminMigrationCheckpointReference digest = "aws-ses:sha256-" <> digest

lifecycleAuthorityAuthenticationMetadataMaximumBytes :: Int
lifecycleAuthorityAuthenticationMetadataMaximumBytes = 1024

lifecycleAuthorityAuthenticatedFrameMaximumBytes :: Int
lifecycleAuthorityAuthenticatedFrameMaximumBytes = 100 * 1024 * 1024

lifecycleAuthoritySignedEnvelopeMaximumBytes :: Int
lifecycleAuthoritySignedEnvelopeMaximumBytes =
  lifecycleAuthorityAuthenticatedFrameMaximumBytes - 4096

lifecycleAuthorityAuthenticationLifetimeMicros :: Natural
lifecycleAuthorityAuthenticationLifetimeMicros = 5 * 60 * 1000000

lifecycleAuthorityReplayClockSkewMicros :: Natural
lifecycleAuthorityReplayClockSkewMicros = 60 * 1000000

lifecycleAuthorityReplayCapacity :: Natural
lifecycleAuthorityReplayCapacity = 4

-- Replay stores the bounded response, not the potentially large checkpoint
-- request.  Keeping this limit independent from the request frame prevents a
-- few accepted checkpoint calls from constructing a hundreds-of-megabytes
-- retained replay object.
lifecycleAuthorityReplayResponseMaximumBytes :: Int
lifecycleAuthorityReplayResponseMaximumBytes = 2 * 1024 * 1024

lifecycleAuthorityReplayCasAttempts :: Natural
lifecycleAuthorityReplayCasAttempts = 8

lifecycleAuthorityReplayMaximumEncodedBytes :: Int
lifecycleAuthorityReplayMaximumEncodedBytes = 12 * 1024 * 1024

provideAuthenticationAuthorityEpoch
  :: AuthorityAdmissionRepository IO revision
  -> IO (Either Text AuthorityEpoch)
provideAuthenticationAuthorityEpoch repository = do
  observed <- readAuthorityAdmission repository
  pure $ do
    snapshot <- observed
    Right (authorityAuthenticationEpoch (authorityAdmissionSnapshotState snapshot))

currentAuthorityTime :: IO (Either Text AuthorityTime)
currentAuthorityTime = fmap (fmap authorityTimeFromMicros) currentAuthorityTimeMicros

freshReplayAttempt :: IO (Either Text ReplayAttemptId)
freshReplayAttempt = do
  bytes <- getRandomBytes 32 :: IO ByteString.ByteString
  pure (mapLeft (Text.pack . show) (mkReplayAttemptId bytes))

authorityBackupServiceEndpoint :: Text
authorityBackupServiceEndpoint =
  controlPlaneClusterServiceUrlText "authority-backup" "authority-backup"

providerWorkerServiceEndpoint :: Text
providerWorkerServiceEndpoint =
  controlPlaneClusterServiceUrlText "provider-worker" "provider-worker"

lifecycleAuthorityServiceEndpoint :: Text
lifecycleAuthorityServiceEndpoint =
  controlPlaneClusterServiceUrlText "lifecycle-authority" "lifecycle-authority"

lifecycleAuthorityTargetControllerTokenFile :: FilePath
lifecycleAuthorityTargetControllerTokenFile =
  "/var/run/secrets/prodbox-target-controller/token"

targetSecretAgentServiceEndpoint :: Text
targetSecretAgentServiceEndpoint =
  controlPlaneClusterServiceUrlText "target-secret-agent" "target-secret-agent"

targetDecommissionInventoryMaximumResponseBytes :: Int
targetDecommissionInventoryMaximumResponseBytes = 64 * 1024

decommissionManifestMaximumEncodedBytes :: Int
decommissionManifestMaximumEncodedBytes = 4 * 1024 * 1024

lifecycleAuthorityDecommissionCasAttempts :: Natural
lifecycleAuthorityDecommissionCasAttempts = 8

lifecycleAuthorityExternalMaterialCasAttempts :: Natural
lifecycleAuthorityExternalMaterialCasAttempts = 8

adminActionStateMaximumEncodedBytes :: Int
adminActionStateMaximumEncodedBytes = 256 * 1024

freshAdminActionNonceProduction :: Text -> IO (Either Text Text)
freshAdminActionNonceProduction _operationId = do
  attempted <-
    try (getRandomBytes 32 :: IO ByteString.ByteString)
      :: IO (Either SomeException ByteString.ByteString)
  pure $ case attempted of
    Left _ -> Left "Admin Action nonce source is unavailable"
    Right bytes -> Right (TextEncoding.decodeUtf8 (hexSha256 bytes))

backupAdminActionCore
  :: AuthorityCheckpointBackupClient IO
  -> AdminActionPermitCore
  -> IO (Either Text AdminActionBackupReceipt)
backupAdminActionCore client core = do
  copied <- copyCheckpointBackup client (adminActionPermitBackupPayload core)
  pure $ do
    receipt <- first (Text.pack . show) copied
    let digest = authorityBackupDigestText (authorityBackupReceiptDigest receipt)
        expected = adminActionPermitBackupDigest core
    if digest /= expected
      then Left "Admin Action backup receipt digest does not match the permit core"
      else
        first
          (Text.pack . show)
          ( mkAdminActionBackupReceipt
              core
              ("checkpoint/" <> digest)
              digest
              (authorityBackupReceiptObjectVersion receipt)
          )

productionDecommissionSingletonPrefix :: [DecommissionNode]
productionDecommissionSingletonPrefix =
  [ SesConsumerQuiescence
  , SesProviderStack
  , SesSmtpIam
  ]

productionDecommissionSingletonSuffix :: [DecommissionNode]
productionDecommissionSingletonSuffix =
  [ RetainedCustody
  , TlsRetainedObjects
  , TlsRetentionIdentity
  , BackupObjects
  , BackupPrefixAbsenceProof
  , SharedObjectBucket
  ]

-- | The pre-aggregate projection namespace lives in the same retained MinIO
-- store as the replacement aggregate.  Migration therefore changes only the
-- logical namespace; it must not fabricate a Gateway NodePort coordinate or
-- revive the removed gateway-backed authority transport.
legacyProjectionAuthority
  :: LongLivedCheckpointAuthority
  -> Either AuthorityCoordinateError LongLivedCheckpointAuthority
legacyProjectionAuthority replacement =
  mkLongLivedCheckpointAuthority
    (checkpointAuthorityClusterId replacement)
    (checkpointAuthorityObjectBucket replacement)
    "lifecycle"
    "secret/lifecycle"

currentAuthorityTimeMicros :: IO (Either Text Natural)
currentAuthorityTimeMicros = do
  now <- getCurrentTime
  pure
    ( Right
        ( fromInteger
            (max 0 (floor (utcTimeToPOSIXSeconds now * 1000000) :: Integer))
        )
    )

authorityBackupRuntimeInterpreter
  :: DedicatedAdapterBinding 'AuthorityBackupAdapter
  -> IO (RoleInterpreter IO, RoleReadinessObserver)
authorityBackupRuntimeInterpreter binding = do
  observer <-
    dedicatedAdapterReadinessObserver
      "authority-backup-store"
      (authorityBackupAdapterReady binding)
  pure
    ( authorityBackupInterpreter
        controlPlaneMaximumBodyBytes
        (roleReadinessObserverSource observer)
        (authorityBackupRepository binding)
    , observer
    )

tlsRetentionRuntimeInterpreter
  :: DedicatedAdapterBinding 'TlsRetentionAdapter
  -> IO (RoleInterpreter IO, RoleReadinessObserver)
tlsRetentionRuntimeInterpreter binding = do
  observer <-
    dedicatedAdapterReadinessObserver
      "tls-retention-store"
      (tlsRetentionAdapterReady binding)
  pure
    ( tlsRetentionInterpreter
        controlPlaneMaximumBodyBytes
        (roleReadinessObserverSource observer)
        (tlsRetentionRepository binding)
    , observer
    )

-- | Sprint 4.55: both dedicated adapters answer readiness with one authenticated
-- S3 probe against their own registered prefix. It runs in the background now,
-- and a refusal is a labelled non-terminal observation rather than a bare
-- 'False' the projection cannot describe.
dedicatedAdapterReadinessObserver :: Text -> IO Bool -> IO RoleReadinessObserver
dedicatedAdapterReadinessObserver label observe =
  newRoleReadinessObserver
    controlPlaneRoleReadinessSchedule
    label
    monotonicNowMicros
    ( do
        observed <- observe
        pure
          [
            ( label
            , if observed
                then RoleDependencyReady
                else RoleDependencyUnavailable "the dedicated adapter store did not answer"
            )
          ]
    )

validateControlPlaneConfig
  :: RuntimeRole
  -> ControlPlaneConfig
  -> Either ControlPlaneConfigError ValidatedRoleStore
validateControlPlaneConfig role config
  | schema_version config /= 7 = Left ControlPlaneConfigVersionUnsupported
  | runtime_role config /= Text.pack (runtimeRoleName role) =
      Left ControlPlaneConfigRoleMismatch
  | otherwise = do
      -- Validate the role-owned store before deriving identities from the
      -- shared cluster identifier.  The store is the schema-v7 authority for
      -- whether that identifier is admissible for this runtime role; allowing
      -- the Target Agent projection to fail first hides the exact closed-store
      -- error (for example an empty primary-store cluster id).
      validatedStore <- validateStore role (cluster_id config) (role_store config)
      agentIdentity <-
        mapLeft
          (const ControlPlaneConfigTargetAgentIdentityInvalid)
          (mkTargetAgentIdentity (target_agent_identity config))
      if targetAgentClusterIdentity agentIdentity == Text.strip (cluster_id config)
        then Right ()
        else Left ControlPlaneConfigTargetAgentClusterMismatch
      _ <-
        mapLeft
          ControlPlaneConfigAuthenticationInvalid
          (validateControlPlaneAuthenticationWire role (request_authentication config))
      pure validatedStore

validateStore
  :: RuntimeRole
  -> Text
  -> ControlPlaneRoleStore
  -> Either ControlPlaneConfigError ValidatedRoleStore
validateStore role clusterId store = case (role, store) of
  (LifecycleAuthorityRuntime, RoleStorePrimary wire) ->
    ValidatedPrimaryStore
      <$> mapLeft
        ControlPlaneConfigAuthorityStoreInvalid
        (mkInClusterAuthorityStoreConfig clusterId (primary_endpoint wire) (primary_bucket wire))
  (AuthorityBackupRuntime, RoleStoreAuthorityBackup wire) ->
    ValidatedAuthorityBackupStore
      <$> mapLeft
        ControlPlaneConfigDedicatedStoreInvalid
        ( mkAuthorityBackupStoreConfig
            clusterId
            (authority_backup_endpoint wire)
            (authority_backup_region wire)
            (authority_backup_bucket wire)
            (authority_backup_prefix wire)
        )
  (TlsRetentionRuntime, RoleStoreTlsRetention wire) ->
    ValidatedTlsRetentionStore
      <$> mapLeft
        ControlPlaneConfigDedicatedStoreInvalid
        ( mkTlsRetentionStoreConfig
            clusterId
            (tls_retention_endpoint wire)
            (tls_retention_region wire)
            (tls_retention_bucket wire)
            (tls_retention_substrate wire)
            (tls_retention_scope_key wire)
            (tls_retention_prefix wire)
        )
  (ProviderWorkerRuntime, RoleStoreProviderWorker) -> Right ValidatedProviderWorkerStore
  (TargetSecretAgentRuntime, RoleStoreTargetSecretAgent) -> Right ValidatedTargetSecretAgentStore
  (BootstrapBroker, RoleStoreNone) -> Right ValidatedNoStore
  (GatewayRuntime, RoleStoreNone) -> Right ValidatedNoStore
  _ -> Left ControlPlaneConfigStoreRoleMismatch

-- | Read exactly one bounded HTTP request from a connected socket. Framing is
-- decided by the pure server seam after each fragment; EOF cannot turn an
-- incomplete request into a dispatchable value.
receiveControlPlaneRequest
  :: Socket
  -> IO (Either ControlPlaneFramingError ByteString.ByteString)
receiveControlPlaneRequest client = accumulate mempty
 where
  accumulate received =
    case inspectControlPlaneRequestFraming received of
      Left framingError -> pure (Left framingError)
      Right (ControlPlaneFramingComplete request) -> pure (Right request)
      Right ControlPlaneFramingIncomplete -> do
        chunk <- recv client 4096
        if ByteString.null chunk
          then pure (finishControlPlaneRequestFraming received)
          else accumulate (received <> chunk)

runControlPlaneRole :: RuntimeRole -> ControlPlaneLaunchOptions -> IO ExitCode
runControlPlaneRole role options = do
  decoded <- try (Dhall.inputFile Dhall.auto (controlPlaneConfigPath options))
  case decoded of
    Left (_ :: SomeException) -> pure (ExitFailure 1)
    Right config ->
      case validateControlPlaneConfig role config of
        Left _ -> pure (ExitFailure 1)
        Right validatedStore ->
          case mkControlPlaneVaultConfig
            role
            (vault_address config)
            (vault_auth_path config)
            (vault_role config)
            (Text.unpack (service_account_token_file config)) of
            Left _ ->
              pure (ExitFailure 1)
            Right vaultConfig -> do
              vaultSession <- newControlPlaneVaultSession vaultConfig
              case mkTargetAgentIdentity (target_agent_identity config) of
                Left _ -> pure (ExitFailure 1)
                Right agentIdentity ->
                  runRolePlan
                    role
                    options
                    vaultConfig
                    vaultSession
                    validatedStore
                    (cluster_id config)
                    agentIdentity
                    (mountedAuthenticationProvisioning role (request_authentication config))

mountedAuthenticationProvisioning
  :: RuntimeRole
  -> ControlPlaneAuthenticationWire
  -> Either AuthenticatedRuntimeProvisioningGap ValidatedAuthenticationTopology
mountedAuthenticationProvisioning role wire =
  mapLeft
    (AuthenticatedRuntimeTrustProvisioningInvalid role)
    (validateControlPlaneAuthenticationWire role wire)

data ResolvedAuthenticationProvisioning = ResolvedAuthenticationProvisioning
  { resolvedAuthenticationTrustRegistry :: !RouteTrustRegistry
  , resolvedAuthenticationClientSigner :: !(RequestSigningCapability IO)
  }

resolveMountedAuthenticationProvisioning
  :: VaultSession
  -> ValidatedAuthenticationTopology
  -> IO (Either Text ResolvedAuthenticationProvisioning)
resolveMountedAuthenticationProvisioning vaultSession topology = do
  trustResult <-
    resolveRouteTrustRegistryWith
      (resolveTransitPublicGeneration vaultSession)
      topology
  signerResult <-
    resolveTransitRequestSigningCapability
      vaultSession
      (validatedAuthenticationSigningPrincipal topology)
      (validatedAuthenticationSigningKeyRef topology)
  pure $ do
    trust <- mapLeft (Text.pack . show) trustResult
    signer <- signerResult
    Right
      ResolvedAuthenticationProvisioning
        { resolvedAuthenticationTrustRegistry = trust
        , resolvedAuthenticationClientSigner = signer
        }

runRolePlan
  :: RuntimeRole
  -> ControlPlaneLaunchOptions
  -> ControlPlaneVaultConfig
  -> VaultSession
  -> ValidatedRoleStore
  -> Text
  -> TargetAgentIdentity
  -> Either AuthenticatedRuntimeProvisioningGap ValidatedAuthenticationTopology
  -> IO ExitCode
runRolePlan role options vaultConfig vaultSession validatedStore clusterId agentIdentity authenticationProvisioning =
  runPlanWithOptions
    (controlPlanePlanOptions options)
    ( buildPlan
        ( \() ->
            unlines
              [ "CONTROL_PLANE_ROLE_START_PLAN"
              , "RUNTIME_ROLE=" ++ runtimeRoleName role
              , "CONFIG_PATH=" ++ controlPlaneConfigPath options
              , "CONFIG_SCHEMA_VERSION=7"
              , "CONFIG_RUNTIME_ROLE=" ++ runtimeRoleName role
              , "LISTENER=0.0.0.0:" ++ show controlPlaneListenPort
              , "ROLE_ROUTE_COUNT=" ++ show (length (routesForRole role))
              , "READINESS=" ++ readinessPlan role
              ]
        )
        ()
    )
    ( const
        ( runRoleServer
            role
            vaultConfig
            vaultSession
            validatedStore
            clusterId
            agentIdentity
            authenticationProvisioning
        )
    )
 where
  readinessPlan activeRole = case activeRole of
    LifecycleAuthorityRuntime -> "signed-s3-probe"
    ProviderWorkerRuntime -> "vault-provider-credential-and-sts-probe"
    AuthorityBackupRuntime -> "signed-s3-prefix-probe"
    TlsRetentionRuntime -> "signed-s3-prefix-probe"
    _ -> "fail-closed-until-interpreter-bound"

runRoleServer
  :: RuntimeRole
  -> ControlPlaneVaultConfig
  -> VaultSession
  -> ValidatedRoleStore
  -> Text
  -> TargetAgentIdentity
  -> Either AuthenticatedRuntimeProvisioningGap ValidatedAuthenticationTopology
  -> IO ExitCode
runRoleServer role vaultConfig vaultSession validatedStore clusterId agentIdentity authenticationProvisioning =
  case authenticationProvisioning of
    Left _ -> pure (ExitFailure 1)
    Right topology -> do
      resolved <- resolveMountedAuthenticationProvisioning vaultSession topology
      case resolved of
        Left _ -> pure (ExitFailure 1)
        Right authentication ->
          runResolvedRole authentication
 where
  runResolvedRole authentication = case (role, validatedStore) of
    ( LifecycleAuthorityRuntime
      , ValidatedPrimaryStore storeConfig
      ) -> do
        storeResult <- newInClusterAuthorityStore vaultSession storeConfig
        case storeResult of
          Left _ -> pure (ExitFailure 1)
          Right store ->
            case mkLifecycleAuthorityCoordinates storeConfig of
              Left _ -> pure (ExitFailure 1)
              Right coordinates -> do
                interpreterResult <-
                  lifecycleAuthorityRuntimeInterpreter
                    vaultConfig
                    vaultSession
                    (resolvedAuthenticationTrustRegistry authentication)
                    (resolvedAuthenticationClientSigner authentication)
                    store
                    coordinates
                    agentIdentity
                case interpreterResult of
                  Left _ -> pure (ExitFailure 1)
                  Right (interpreter, readinessObserver) ->
                    withRoleReadinessObservers
                      [readinessObserver]
                      (runControlPlaneServer role interpreter)
    (AuthorityBackupRuntime, ValidatedAuthorityBackupStore storeConfig) -> do
      bindingResult <- newAuthorityBackupAdapterBinding vaultSession storeConfig
      case bindingResult of
        Left _ -> pure (ExitFailure 1)
        Right binding -> do
          (interpreter, readinessObserver) <- authorityBackupRuntimeInterpreter binding
          runAuthenticatedContextFreeObserving
            [readinessObserver]
            authentication
            interpreter
            largeAuthenticatedFrameMaximumBytes
            standardAuthenticatedResponseMaximumBytes
            standardReplayCapacity
            standardReplayMaximumEncodedBytes
    (TlsRetentionRuntime, ValidatedTlsRetentionStore storeConfig) -> do
      bindingResult <- newTlsRetentionAdapterBinding vaultSession storeConfig
      case bindingResult of
        Left _ -> pure (ExitFailure 1)
        Right binding -> do
          (interpreter, readinessObserver) <- tlsRetentionRuntimeInterpreter binding
          runAuthenticatedContextFreeObserving
            [readinessObserver]
            authentication
            interpreter
            standardAuthenticatedFrameMaximumBytes
            standardAuthenticatedResponseMaximumBytes
            standardReplayCapacity
            standardReplayMaximumEncodedBytes
    (ProviderWorkerRuntime, ValidatedProviderWorkerStore) ->
      case providerWorkerRuntimeHandler
        vaultSession
        clusterId
        (resolvedAuthenticationTrustRegistry authentication)
        (resolvedAuthenticationClientSigner authentication) of
        Left _ -> pure (ExitFailure 1)
        Right buildHandler -> do
          (handler, readinessObserver) <- buildHandler
          runAuthenticatedHandlerObserving
            [readinessObserver]
            authentication
            handler
            standardAuthenticatedFrameMaximumBytes
            standardAuthenticatedResponseMaximumBytes
            standardReplayCapacity
            standardReplayMaximumEncodedBytes
    (TargetSecretAgentRuntime, ValidatedTargetSecretAgentStore) -> do
      handlerResult <-
        targetSecretAgentRuntimeHandler
          vaultConfig
          vaultSession
          clusterId
          agentIdentity
          (resolvedAuthenticationClientSigner authentication)
      case handlerResult of
        Left _ -> pure (ExitFailure 1)
        Right (handler, readinessObserver) ->
          runAuthenticatedHandlerObserving
            [readinessObserver]
            authentication
            handler
            standardAuthenticatedFrameMaximumBytes
            standardAuthenticatedResponseMaximumBytes
            standardReplayCapacity
            standardReplayMaximumEncodedBytes
    _ -> pure (ExitFailure 1)

  runAuthenticatedContextFreeObserving
    observers
    authentication
    inner
    frameMaximum
    responseMaximum
    replayCapacity
    replayMaximumEncoded =
      runAuthenticatedHandlerObserving
        observers
        authentication
        (contextFreeAuthenticatedRoleHandler inner)
        frameMaximum
        responseMaximum
        replayCapacity
        replayMaximumEncoded

  -- Sprint 4.55: a role that has migrated its readiness to cached facts passes
  -- the observers that own those facts; they run for exactly the lifetime of
  -- the server. A role still resolving readiness on the request path passes
  -- none, which is the pre-4.55 behaviour unchanged.
  runAuthenticatedHandlerObserving
    observers
    authentication
    handler
    frameMaximum
    responseMaximum
    replayCapacity
    replayMaximumEncoded =
      case installVaultAuthenticatedHandler
        role
        vaultSession
        clusterId
        (resolvedAuthenticationTrustRegistry authentication)
        handler
        frameMaximum
        responseMaximum
        replayCapacity
        replayMaximumEncoded of
        Left _ -> pure (ExitFailure 1)
        Right buildInterpreter -> do
          (interpreter, commonObserver) <- buildInterpreter
          withRoleReadinessObservers
            (commonObserver : observers)
            (runControlPlaneServer role interpreter)

-- | Complete Provider Worker production composition. The outer request is
-- authenticated as Lifecycle Authority; the independently signed inner intent
-- is then checked against the same pinned Authority Transit generation before
-- a rank-2 session reads the one Provider credential object.
providerWorkerRuntimeHandler
  :: VaultSession
  -> Text
  -> RouteTrustRegistry
  -> RequestSigningCapability IO
  -> Either Text (IO (AuthenticatedRoleHandler IO, RoleReadinessObserver))
providerWorkerRuntimeHandler vaultSession clusterId trustRegistry clientSigner = do
  scope <- mapLeft (Text.pack . show) (mkAuthorityScope clusterId)
  transportBounds <-
    mapLeft
      (Text.pack . show)
      ( mkAuthenticatedTransportBounds
          lifecycleAuthorityAuthenticatedFrameMaximumBytes
          lifecycleAuthorityAuthenticationMetadataMaximumBytes
          lifecycleAuthoritySignedEnvelopeMaximumBytes
      )
  maximumLifetime <-
    mapLeft
      (Text.pack . show)
      (authorityDurationFromMicros lifecycleAuthorityAuthenticationLifetimeMicros)
  authorityEndpoint <-
    mapLeft
      (Text.pack . show)
      (mkLifecycleAuthorityEndpoint lifecycleAuthorityServiceEndpoint)
  authorityClient <-
    mapLeft
      (Text.pack . show)
      ( newControlPlaneClient
          defaultHttpConfig
          lifecycleAuthorityAuthenticatedFrameMaximumBytes
          authorityEndpoint
      )
  trustedAuthority <- case routeTrustRegistryKeysFor ProviderWorkApply trustRegistry of
    [trusted]
      | trustedRequestCallerPrincipal trusted
          == CallerService LifecycleAuthorityRuntime ->
          Right trusted
    _ -> Left "Provider Worker requires exactly one Lifecycle Authority trust generation"
  issuerGeneration <-
    mapLeft
      (Text.pack . show)
      ( mkProviderIssuerKeyGeneration
          (signingKeyGenerationValue (trustedRequestGeneration trustedAuthority))
      )
  issuerPublicKey <-
    mapLeft
      (Text.pack . show)
      (mkProviderIntentPublicKey (trustedRequestPublicKeyBytes trustedAuthority))
  revision <- mkProviderRevision 1
  fenceFloor <- mapLeft (Text.pack . show) (mkFencingToken 1)
  let resources =
        mkRegisteredProviderResources
          [ "stack:aws-eks"
          , "stack:aws-eks-subzone"
          , "stack:aws-test"
          , "checkpoint:pulumi-scratch"
          , "ses:sending-identity"
          , "ses:dkim"
          , "ses:dns"
          , "ses:receipt-rules"
          , "ses:capture-bucket"
          , "ebs-reaper:test-scoped"
          , "spot-price:ec2"
          , "operational-identity"
          , "readiness:sts"
          , "readiness:route53"
          , "public-edge:a"
          , "eks-client-auth"
          ]
      authorityTransport =
        mkAuthenticatedClientTransport
          transportBounds
          ( transitAuthenticatedClientProviders
              clientSigner
              (pure (Right scope))
              (readRetainedAuthorityEpoch vaultSession)
              maximumLifetime
          )
          authorityClient
      acceptedAuthority = do
        epochResult <- readRetainedAuthorityEpoch vaultSession
        pure $ do
          epoch <- epochResult
          mapLeft
            (Text.pack . show)
            ( mkAcceptedProviderAuthority
                issuerGeneration
                (Text.pack (runtimeRoleName LifecycleAuthorityRuntime))
                issuerPublicKey
                (Coordinate.AuthorityEpoch (authorityEpochValue epoch))
                fenceFloor
                revision
                resources
            )
      trustRepository =
        ProviderWorkerTrustRepository
          { readAcceptedProviderAuthority = acceptedAuthority
          }
      boundary =
        mkProviderWorkerExecutionBoundary
          trustRepository
          currentAuthorityTime
          ( providerProductionNarrowSession
              vaultSession
              authorityTransport
              (readRetainedAuthorityEpoch vaultSession)
          )
          providerProductionCapabilities
      -- Sprint 4.55: readiness used to read the retained Authority epoch and
      -- then run `providerProductionReady`, which reads the Provider Vault KV
      -- object and shells out to `aws sts get-caller-identity` — inline, on a
      -- `timeoutSeconds: 1` kubelet probe path, and with the two outcomes
      -- collapsed into one `Bool`. Both observations are now one background pass
      -- over a labelled inventory, and the request path reads the latched record
      -- and folds it.
      observePass = do
        trusted <- acceptedAuthority
        providerReady <- providerProductionReady vaultSession
        pure
          [
            ( "accepted-provider-authority"
            , roleDependencyFromOutcome (void trusted)
            )
          ,
            ( "provider-credential-identity"
            , if providerReady
                then RoleDependencyReady
                else
                  RoleDependencyUnavailable
                    "the Provider credential did not complete an STS identity round trip"
            )
          ]
  Right $ do
    observer <-
      newRoleReadinessObserver
        controlPlaneRoleReadinessSchedule
        "provider-worker-dependencies"
        monotonicNowMicros
        observePass
    let fallback =
          AuthenticatedRoleHandler
            { authenticatedHandlerReadiness = roleReadinessObserverSource observer
            , authenticatedHandlerHandle = \_ _ _ -> pure Nothing
            }
    pure
      ( providerWorkerExecutionAuthenticatedHandler
          providerCommittedIntentMaximumEncodedBytes
          boundary
          fallback
      , observer
      )

-- | The monotonic clock a readiness observer stamps with and a readiness
-- projection is evaluated against. One reader, so the observer's stamp and the
-- projection's @now@ cannot come from different clocks.
monotonicNowMicros :: IO Natural
monotonicNowMicros = fmap monotonicInstantMicros realMonotonicNow

-- | The production readiness resolver: one monotonic clock read, one @STM@
-- transaction over the layered facts, and the pure projection. It names no
-- backend, which is the property the seam type now guarantees rather than
-- merely documents.
productionRoleReadinessResolver :: RoleReadinessResolver IO
productionRoleReadinessResolver =
  mkRoleReadinessResolver controlPlaneRoleReadinessSchedule monotonicNowMicros atomically

-- | Production Target Secret Agent binding. Secret-bearing TLS and
-- post-initialization federation operations are authorized by the Lifecycle
-- Authority and attached directly to an exact attested one-shot worker. The
-- standing process retains only metadata, typed results, and cleanup evidence.
targetSecretAgentRuntimeHandler
  :: ControlPlaneVaultConfig
  -> VaultSession
  -> Text
  -> TargetAgentIdentity
  -> RequestSigningCapability IO
  -> IO (Either Text (AuthenticatedRoleHandler IO, RoleReadinessObserver))
targetSecretAgentRuntimeHandler vaultConfig vaultSession clusterId agentIdentity clientSigner = do
  -- Sprint 4.55: the agent's readiness used to run an `allM` over every
  -- registered target — up to 32 sequential Vault KV reads, and `allM`
  -- short-circuits only on failure, so the healthy path was the slowest — plus
  -- an authority clock read and a projected-token read, all inline on a
  -- `timeoutSeconds: 1` probe path. One background pass owns them now, and the
  -- observer is built before the boundaries so its source is the one every
  -- layer reads.
  readinessObserver <-
    newRoleReadinessObserver
      controlPlaneRoleReadinessSchedule
      "target-secret-agent-dependencies"
      monotonicNowMicros
      ( do
          materialDependencies <- observeVaultTargetMaterialDependencies vaultSession
          observedTime <- currentAuthorityTime
          projectedJwt <-
            readProjectedServiceAccountJwt targetSecretControllerAuditorTokenFile
          pure
            ( materialDependencies
                ++ [
                     ( "authority-clock"
                     , roleDependencyFromOutcome (void observedTime)
                     )
                   ,
                     ( "projected-service-account-token"
                     , roleDependencyFromOutcome (void projectedJwt)
                     )
                   ]
            )
      )
  let agentReadiness = roleReadinessObserverSource readinessObserver
  case (buildBoundaries, targetOneShotRuntimeBoundary agentReadiness) of
    (Left detail, _) -> pure (Left detail)
    (_, Left detail) -> pure (Left detail)
    (Right (registry, inventory, custody), Right oneShotBoundary) -> do
      let signer = vaultAuthorityManifestSigner vaultSession
      signerResult <- readAuthorityManifestPublicKey signer
      pure $ fmap (,readinessObserver) $ do
        (_, publicKey) <- signerResult
        let decommissionInputs =
              TargetSecretAgentDecommissionProvisioned
                (manifestPublicKeyDigest publicKey)
                registry
                inventory
                custody
            metadataOnlyFallback =
              targetMaterialObservationAuthenticatedHandler
                controlPlaneMaximumBodyBytes
                (vaultTargetMaterialRepository vaultSession agentReadiness)
            retainedMaterialHandler =
              targetRetainedMaterialRewrapAuthenticatedHandler
                controlPlaneMaximumBodyBytes
                currentAuthorityTime
                ( productionTargetRetainedMaterialRewrapBoundary
                    vaultSession
                    clusterId
                )
                metadataOnlyFallback
            decommissionHandler =
              targetSecretAgentDecommissionAuthenticatedHandler
                controlPlaneMaximumBodyBytes
                decommissionInputs
                retainedMaterialHandler
            adminActionHandler =
              targetSecretAgentAdminActionAuthenticatedHandler
                controlPlaneMaximumBodyBytes
                signer
                currentAuthorityTime
                clusterId
                registry
                custody
                decommissionHandler
            oneShotHandler =
              targetOneShotOperationAuthenticatedHandler
                controlPlaneMaximumBodyBytes
                oneShotBoundary
                adminActionHandler
        Right
          ( targetAuthorityTrustAuthenticatedHandler
              controlPlaneMaximumBodyBytes
              (vaultTargetAuthorityTrustRepository agentIdentity vaultSession)
              oneShotHandler
          )
 where
  targetOneShotRuntimeBoundary oneShotReadiness = do
    scope <- mapLeft (Text.pack . show) (mkAuthorityScope clusterId)
    transportBounds <-
      mapLeft
        (Text.pack . show)
        ( mkAuthenticatedTransportBounds
            lifecycleAuthorityAuthenticatedFrameMaximumBytes
            lifecycleAuthorityAuthenticationMetadataMaximumBytes
            lifecycleAuthoritySignedEnvelopeMaximumBytes
        )
    maximumLifetime <-
      mapLeft
        (Text.pack . show)
        (authorityDurationFromMicros lifecycleAuthorityAuthenticationLifetimeMicros)
    authorityEndpoint <-
      mapLeft
        (Text.pack . show)
        (mkLifecycleAuthorityEndpoint lifecycleAuthorityServiceEndpoint)
    authorityClient <-
      mapLeft
        (Text.pack . show)
        ( newControlPlaneClient
            defaultHttpConfig
            lifecycleAuthorityAuthenticatedFrameMaximumBytes
            authorityEndpoint
        )
    image <-
      mapLeft
        ("registered Target Agent rollout is not an image digest: " <>)
        (mkTargetWorkerImageDigest (targetAgentRolloutDigest agentIdentity))
    generation <-
      mapLeft
        (Text.pack . show)
        (mkCredentialGeneration 1)
    let authorityTransport =
          mkAuthenticatedClientTransport
            transportBounds
            ( transitAuthenticatedClientProviders
                clientSigner
                (pure (Right scope))
                (readRetainedAuthorityEpoch vaultSession)
                maximumLifetime
            )
            authorityClient
        intentClient = targetIntentAuthorityClient authorityTransport
        kubernetesBoundary =
          targetWorkerKubernetesBoundary
            TargetWorkerJobConnection
              { targetWorkerJobEnvironment = Nothing
              , targetWorkerJobWorkingDirectory = "/opt/build"
              , targetWorkerJobImageRepository =
                  "127.0.0.1:30080/prodbox/prodbox-runtime"
              , targetWorkerJobMaximumRuntimeSeconds = 180
              }
        runOperation operation = do
          nowResult <- currentAuthorityTime
          jwtResult <-
            readProjectedServiceAccountJwt
              targetSecretControllerAuditorTokenFile
          case (nowResult, jwtResult) of
            (Left detail, _) -> pure (Left detail)
            (_, Left detail) -> pure (Left detail)
            (Right now, Right jwt) -> do
              auditorResult <-
                vaultKubernetesLoginWithLease
                  (sessionAddress vaultSession)
                  (controlPlaneVaultAuthPath vaultConfig)
                  targetSecretControllerAuditorVaultRole
                  jwt
              case auditorResult of
                Left _ -> pure (Left "Target worker controller auditor login unavailable")
                Right auditor
                  | not (isBoundedBatchAuditorLogin 300 auditor) ->
                      pure (Left "Target worker controller auditor login was not bounded batch")
                  | otherwise -> case operationTarget operation of
                      Left detail -> pure (Left detail)
                      Right target -> do
                        let operationDigest = targetWorkerOperationRequestDigest operation
                            operationSuffix =
                              Text.drop 7 (targetValueDigestText operationDigest)
                            operationIdentity =
                              "target-one-shot-"
                                <> Text.take 32 operationSuffix
                                <> "-"
                                <> Text.pack (show (authorityTimeMicros now))
                        issued <-
                          requestTargetCommittedIntent
                            intentClient
                            target
                            agentIdentity
                            generation
                            operationDigest
                            operationIdentity
                            0
                            operationIdentity
                        case issued of
                          Left err -> pure (Left (Text.pack (show err)))
                          Right (signed, accepted) -> do
                            executionNow <- currentAuthorityTime
                            case executionNow of
                              Left detail -> pure (Left detail)
                              Right verifiedNow ->
                                fmap
                                  (mapLeft (Text.pack . show))
                                  ( coordinateTargetOneShotOperation
                                      kubernetesBoundary
                                      ( vaultTargetWorkerRetainedExecutionBoundary
                                          (sessionAddress vaultSession)
                                          (vaultLoginToken auditor)
                                          ( targetWorkerControllerAuditOps
                                              (sessionAddress vaultSession)
                                              (vaultLoginToken auditor)
                                          )
                                          intentClient
                                      )
                                      accepted
                                      verifiedNow
                                      agentIdentity
                                      target
                                      (targetWorkerOperationInputSchema operation)
                                      image
                                      (encodeSignedTargetCommittedIntent signed)
                                      operation
                                  )
    Right
      TargetOneShotOperationBoundary
        { runTargetOneShotOperation = runOperation
        , -- Sprint 4.55: the authority clock read and the projected
          -- ServiceAccount-token read used to run inline on the probe path,
          -- composed with `&&`. The Target Secret Agent's observer owns both;
          -- see 'observeTargetSecretAgentDependencies'.
          targetOneShotOperationBoundaryReadiness = oneShotReadiness
        }

  operationTarget operation = case targetWorkerOperationInputSchema operation of
    TargetWorkerTlsPrepare -> Right TargetPublicEdgeTls
    TargetWorkerTlsRetain -> Right TargetPublicEdgeTls
    TargetWorkerTlsHomeWrap -> Right TargetPublicEdgeTls
    TargetWorkerTlsHomeRewrap -> Right TargetPublicEdgeTls
    TargetWorkerTlsRestore -> Right TargetPublicEdgeTls
    TargetWorkerTlsVerify -> Right TargetPublicEdgeTls
    TargetWorkerFederationCustodyCommit -> Right TargetFederationCustody
    TargetWorkerFederationRecoveryPrepare -> Right TargetFederationCustody
    TargetWorkerFederationRecoveryObserve -> Right TargetFederationCustody
    TargetWorkerFederationRecoveryCommit -> Right TargetFederationCustody
    TargetWorkerDirectAws -> Left "standing Target operation cannot carry direct material"
    TargetWorkerRewrappedSesSmtp -> Left "standing Target operation cannot carry SES material"
    TargetWorkerRewrappedAcmeEab -> Left "standing Target operation cannot carry EAB material"

  targetSecretControllerAuditorTokenFile =
    "/var/run/secrets/prodbox-target-controller/token"

  buildBoundaries = do
    sink <- compiledTargetSecretSink TargetSesSmtp
    trusted <- vaultTrustedTargetSink vaultSession clusterId sink
    tombstone <-
      vaultTargetGenerationTombstoneBoundary vaultSession clusterId sink
    binding <-
      mapLeft
        (Text.pack . show)
        (mkTargetGenerationTombstoneBinding clusterId tombstone)
    registry <-
      mapLeft
        (Text.pack . show)
        (mkTargetGenerationTombstoneRegistry [binding])
    custody <-
      mapLeft
        (Text.pack . show)
        (vaultRetainedCustodyBoundary vaultSession)
    Right
      ( registry
      , targetDecommissionInventoryBoundary trusted
      , custody
      )

installVaultAuthenticatedHandler
  :: RuntimeRole
  -> VaultSession
  -> Text
  -> RouteTrustRegistry
  -> AuthenticatedRoleHandler IO
  -> Int
  -> Int
  -> Natural
  -> Int
  -> Either Text (IO (RoleInterpreter IO, RoleReadinessObserver))
installVaultAuthenticatedHandler
  role
  vaultSession
  clusterId
  trustRegistry
  inner
  frameMaximum
  responseMaximum
  replayCapacity
  replayMaximumEncoded = do
    scope <- mapLeft (Text.pack . show) (mkAuthorityScope clusterId)
    transportBounds <-
      mapLeft
        (Text.pack . show)
        ( mkAuthenticatedTransportBounds
            frameMaximum
            authenticationMetadataMaximumBytes
            (frameMaximum - 4096)
        )
    maximumLifetime <-
      mapLeft
        (Text.pack . show)
        (authorityDurationFromMicros authenticationLifetimeMicros)
    replayClockSkew <-
      mapLeft
        (Text.pack . show)
        (authorityDurationFromMicros replayClockSkewMicros)
    replayLimits <-
      mapLeft
        (Text.pack . show)
        (mkRequestReplayLimits replayCapacity responseMaximum replayClockSkew)
    casAttempts <-
      mapLeft (Text.pack . show) (mkReplayCasAttempts replayCasAttempts)
    let replayRepository =
          vaultRequestReplayRepository
            vaultSession
            role
            replayMaximumEncoded
            replayLimits
        -- Sprint 4.55: every authenticated role used to add these two backend
        -- reads to its own probe path, composed with `&&` so neither
        -- short-circuited on the other's failure. They are now one background
        -- pass layered over whatever the role itself contributes.
        observeAuthenticatedRuntime = do
          epochObserved <- readRetainedAuthorityEpoch vaultSession
          replayObserved <- readRequestReplayProjection replayRepository
          pure
            [
              ( "retained-authority-epoch"
              , roleDependencyFromOutcome (void epochObserved)
              )
            ,
              ( "request-replay-projection"
              , roleDependencyFromOutcome
                  (either (Left . Text.pack . show) (const (Right ())) replayObserved)
              )
            ]
        runtimeInputs =
          AuthenticatedRuntimeInputs
            role
            transportBounds
            maximumLifetime
            AuthenticatedRoleProviders
              { authenticatedRoleServerProviders =
                  AuthenticatedServerProviders
                    { provideAuthenticatedServerScope = pure (Right scope)
                    , provideAuthenticatedServerEpoch =
                        readRetainedAuthorityEpoch vaultSession
                    , provideAuthenticatedServerTime = currentAuthorityTime
                    , provideAuthenticatedServerTrustRegistry =
                        pure (Right trustRegistry)
                    }
              , provideAuthenticatedReplayAttempt = freshReplayAttempt
              }
            casAttempts
            replayLimits
            replayRepository
    interpreter <-
      mapLeft
        (Text.pack . show)
        (installAuthenticatedRuntimeInterpreter role runtimeInputs inner)
    pure $ do
      observer <-
        newRoleReadinessObserver
          controlPlaneRoleReadinessSchedule
          "authenticated-runtime-dependencies"
          monotonicNowMicros
          observeAuthenticatedRuntime
      pure
        ( interpreter
            { interpreterReadiness =
                layerRoleReadinessSource
                  (roleReadinessObserverSource observer)
                  (interpreterReadiness interpreter)
            }
        , observer
        )

authenticationMetadataMaximumBytes :: Int
authenticationMetadataMaximumBytes = 1024

standardAuthenticatedFrameMaximumBytes :: Int
standardAuthenticatedFrameMaximumBytes = 2 * 1024 * 1024

largeAuthenticatedFrameMaximumBytes :: Int
largeAuthenticatedFrameMaximumBytes = 100 * 1024 * 1024

standardAuthenticatedResponseMaximumBytes :: Int
standardAuthenticatedResponseMaximumBytes = 2 * 1024 * 1024

standardReplayCapacity :: Natural
standardReplayCapacity = 4

standardReplayMaximumEncodedBytes :: Int
standardReplayMaximumEncodedBytes = 12 * 1024 * 1024

authenticationLifetimeMicros :: Natural
authenticationLifetimeMicros = 5 * 60 * 1000000

replayClockSkewMicros :: Natural
replayClockSkewMicros = 60 * 1000000

replayCasAttempts :: Natural
replayCasAttempts = 8

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft convert value = case value of
  Left err -> Left (convert err)
  Right result -> Right result

-- | The control plane's authored service-capacity inputs.
--
-- Sprint 4.68. These are __authored, not measured__, and saying so is the point:
-- @rawServiceTimeMicros@ is the one field
-- [resource_scaling_doctrine.md § 2C](../../../documents/engineering/resource_scaling_doctrine.md)
-- calls uncertified-until-first-profile, and no measured control-plane profile
-- exists. What the plan buys today is not a proven service rate; it is that the
-- concurrency, the queue depth, and the rejection threshold are __finite and
-- stated in one place__, where before they were unstated because there was no
-- bound at all.
--
-- The four numbers are chosen so the lane is not over-committed at the authored
-- rate: @ρ = λS/c = 8 × 0.3 s / 4 = 0.6@ against a @0.7@ ceiling, which
-- 'mkServiceCapacityPlan' checks rather than trusts.
-- Sprint 4.75: @rawServiceTimeMicros@ below is __authored, not measured__.
-- Every other number here is a policy choice and is fine to author; a service
-- time is an observation of the running lane, and no measured control-plane
-- profile exists to compare it against. The bound this plan computes is
-- therefore only as good as that one constant, and saying so here is the
-- correction — the field's own haddock claimed it was measured.
controlPlaneCapacityInputs :: RawServiceCapacityPlan
controlPlaneCapacityInputs =
  RawServiceCapacityPlan
    { rawArrivalPerSecond = 8
    , rawServiceTimeMicros = 300000
    , rawWorkerCount = 4
    , rawQueueCapacity = 32
    , rawRejectionThreshold = 24
    , rawHeadroomPpm = 300000
    }

-- | The compiled plan. @Left@ is unreachable in a built binary because
-- @prodbox dev check@ fails when 'controlPlaneCapacityInputs' does not compile,
-- but the value stays an 'Either' rather than an @error@ so that unreachability
-- is a property of the gate and not an assumption in the runtime.
controlPlaneCapacityPlan :: Either ServiceCapacityPlanError ServiceCapacityPlan
controlPlaneCapacityPlan = mkServiceCapacityPlan controlPlaneCapacityInputs

-- | The absolute budget one accepted connection gets, from the instant it was
-- accepted: read, dispatch, and interpreter together.
--
-- Matches the Bootstrap Broker's production @request_deadline_milliseconds@,
-- deliberately: the two servers admit the same class of large-payload
-- operations, and two different budgets for the same work would be a number
-- nobody could defend.
controlPlaneRequestBudget :: RemainingDuration
controlPlaneRequestBudget = RemainingDuration (300 * 1000 * 1000)

-- | An accepted connection with the instant it was accepted.
--
-- The instant is stamped at @accept@ rather than at dequeue, so queue wait is
-- spent from the caller's budget instead of being invisible to it.
data QueuedControlPlaneConnection = QueuedControlPlaneConnection
  { queuedControlPlaneSocket :: !Socket
  , queuedControlPlaneRequestId :: !RequestId
  , queuedControlPlaneAcceptedAt :: !MonotonicInstant
  }

-- | Sprint 4.68: a bounded accept path with one absolute deadline per request.
--
-- The superseded loop was @forever { accept; forkFinally }@: every accepted
-- connection got its own thread, nothing counted them, and neither the request
-- read nor the interpreter had a deadline — so a stalled peer held a thread
-- indefinitely and arrival rate alone decided in-process concurrency. The
-- kernel backlog (@listen … 32@) bounded /pending/ connections and was
-- sometimes mistaken for a bound on /accepted/ ones; it is not, and that is the
-- distinction this closes.
--
-- __The admission machine is not new; it was unused.__
-- "Prodbox.ControlPlane.Capacity" has held an opaque 'ServiceCapacityPlan' and
-- a pure decide\/evolve 'AdmissionQueue' since Sprint 1.62, with no production
-- consumer on this path. This sprint makes it load-bearing rather than writing
-- a second one.
--
-- Two bounds are deliberately redundant and in the same direction: the
-- 'TBQueue' is sized at the plan's queue capacity, so over-admission is not
-- representable in the carrier, while 'admit' rejects at the lower rejection
-- threshold and says /why/. A bug in the decision cannot unbound the memory.
runControlPlaneServer
  :: RuntimeRole
  -> RoleInterpreter IO
  -> IO ExitCode
runControlPlaneServer role interpreter = case controlPlaneCapacityPlan of
  Left _ -> pure (ExitFailure 1)
  Right plan -> withSocketsDo $
    bracket open close $ \listener -> do
      pending <- newTBQueueIO (serviceCapacityQueueCapacity plan)
      admission <- newTVarIO (emptyAdmissionQueue plan)
      nextRequestId <- newTVarIO (0 :: Natural)
      bracket
        ( replicateM
            (fromIntegral (serviceCapacityWorkerCount plan))
            (async (controlPlaneWorkerLoop role interpreter admission pending))
        )
        (mapM_ cancel)
        (const (forever (acceptOne pending admission nextRequestId listener)))
 where
  open = do
    listener <- socket AF_INET Stream defaultProtocol
    setSocketOption listener ReuseAddr 1
    bind
      listener
      ( SockAddrInet
          controlPlaneListenPortNumber
          (tupleToHostAddress (0, 0, 0, 0))
      )
    listen listener 32
    pure listener

  -- `mask` covers the window between `accept` returning a socket and that
  -- socket being owned by the queue or refused: an asynchronous exception
  -- landing there would leak the descriptor with nothing left holding it.
  acceptOne pending admission nextRequestId listener = mask $ \restore -> do
    (client, _) <- restore (accept listener)
    acceptedAt <- monotonicInstantFromMicros <$> controlPlaneMonotonicMicros
    decision <- atomically $ do
      requestId <- stateTVar nextRequestId (\value -> (RequestId value, value + 1))
      queue <- readTVar admission
      let (verdict, evolved) =
            admit queue (AdmissionRequest requestId controlPlaneRequestBudget)
      case verdict of
        AdmissionAdmit _ -> do
          writeTVar admission evolved
          writeTBQueue
            pending
            QueuedControlPlaneConnection
              { queuedControlPlaneSocket = client
              , queuedControlPlaneRequestId = requestId
              , queuedControlPlaneAcceptedAt = acceptedAt
              }
          pure Nothing
        AdmissionRejected reason -> pure (Just reason)
    case decision of
      Nothing -> pure ()
      -- A refused connection is still an accepted connection and is still owed
      -- a reply, so it goes through the same obligation rather than a raw
      -- write. It is answered on the accept thread under a short write budget:
      -- that serialises refusals, which under saturation is backpressure rather
      -- than a cost, and the alternative — one thread per refusal — is the
      -- unbounded spawn this sprint removes.
      Just reason ->
        restore (refuseControlPlaneConnection role reason client)
          `finally` close client

-- | Take one admitted connection, serve it under its own absolute deadline, and
-- free its server slot however it ends.
controlPlaneWorkerLoop
  :: RuntimeRole
  -> RoleInterpreter IO
  -> TVar AdmissionQueue
  -> TBQueue QueuedControlPlaneConnection
  -> IO ()
controlPlaneWorkerLoop role interpreter admission pending = forever $ do
  queued <- atomically (readTBQueue pending)
  -- `try` keeps a worker alive across a synchronous failure. Without it a
  -- single throw would retire one of a fixed number of servers permanently,
  -- which is a slower version of the unbounded defect: capacity that silently
  -- decays. The connection itself is already answered by the obligation.
  outcome <-
    try
      ( serveControlPlaneConnection
          role
          interpreter
          (deadlineAtOffset (queuedControlPlaneAcceptedAt queued) controlPlaneRequestBudget)
          (queuedControlPlaneSocket queued)
          `finally` do
            close (queuedControlPlaneSocket queued)
            atomically
              ( modifyTVar'
                  admission
                  (completeService (queuedControlPlaneRequestId queued))
              )
      )
      :: IO (Either SomeException ())
  case outcome of
    Right () -> pure ()
    -- Cancellation is the drain path and must not be swallowed into a loop.
    Left err -> case fromException err :: Maybe SomeAsyncException of
      Just _ -> throwIO err
      Nothing -> pure ()

-- | Answer a connection the admission machine refused.
--
-- The two reasons map to different statuses on purpose. Saturation is
-- retryable and says so; an unmeetable deadline is not, because retrying
-- against the same budget produces the same answer. The second arm is
-- unreachable under 'controlPlaneCapacityInputs' — the deepest admissible queue
-- costs about two seconds against a 300-second budget — and it exists because
-- the decision is total, not because it is expected.
refuseControlPlaneConnection :: RuntimeRole -> RejectionReason -> Socket -> IO ()
refuseControlPlaneConnection activeRole reason client =
  withResponseObligation obligation client $ do
    drainBeforeRefusal client
    pure (refusalReply reason)
 where
  obligation =
    mkResponseObligation
      (uncurry renderHttpResponse)
      controlPlaneRefusalReply
      (observeControlPlaneRefusal activeRole)
      controlPlaneRefusalWriteBudgetMicros

  refusalReply value = case value of
    RejectedSaturated _ -> (ReplyTooManyRequests, "control-plane-saturated\n")
    RejectedDeadlineUnmeetable _ _ ->
      (ReplyServiceUnavailable, "control-plane-deadline-unmeetable\n")

-- | The write budget a refusal gets. Short relative to
-- 'responseWriteBudgetMicrosDefault' because it is spent on the accept thread:
-- a wedged peer being refused must not stop the server accepting.
controlPlaneRefusalWriteBudgetMicros :: Int
controlPlaneRefusalWriteBudgetMicros = 250 * 1000

-- | Consume the request a refusal is about to answer without reading.
--
-- Sprint 4.68 found this by testing the path rather than by reasoning about it.
-- @close@ on a socket that still holds unread bytes sends __RST__, and an RST
-- discards what was already written — so the @429@ and the @408@ could be lost
-- precisely because those are the two replies produced /without/ reading the
-- request. That is Sprint 4.60's "accepted a connection and answered nothing"
-- reappearing through the kernel instead of through a @const@.
--
-- The drain is the ordinary bounded reader, so it is bounded in bytes by the
-- framing limits, and it is bounded in time here because a peer that opens a
-- connection and then stalls must not hold the accept thread. Its result is
-- discarded deliberately: the request is refused either way, and parsing it
-- would be work this path exists to avoid.
drainBeforeRefusal :: Socket -> IO ()
drainBeforeRefusal client =
  void
    ( try (timeout controlPlaneRefusalDrainMicros (receiveControlPlaneRequest client))
        :: IO (Either SomeException (Maybe (Either ControlPlaneFramingError ByteString.ByteString)))
    )

-- | How long a refusal will wait for the request it is refusing. Smaller than
-- the write budget: draining is a courtesy that protects the reply, and it must
-- never cost more than the reply itself.
controlPlaneRefusalDrainMicros :: Int
controlPlaneRefusalDrainMicros = 100 * 1000

controlPlaneMonotonicMicros :: IO Natural
controlPlaneMonotonicMicros = fromIntegral . (`div` 1000) <$> getMonotonicTimeNSec

-- | Serve one accepted connection through the response obligation.
--
-- Sprint 4.60 exports this so the answered-or-refused guarantee is testable
-- over a socket pair; it was previously a @where@-closure under a @forever@ loop
-- bound to a fixed port, which made the refusal path unreachable from a test.
--
-- The request read runs __inside__ the obligation on purpose: a socket that
-- throws while being read is exactly as owed a reply as an interpreter that
-- throws, and putting the read outside would leave the gap the Bootstrap
-- Broker still has.
--
-- Sprint 4.68: the read and the dispatch run under the connection's absolute
-- deadline, and __the deadline is enforced inside the handler rather than
-- around the obligation__. That placement is the whole design. A @timeout@
-- wrapped outside would deliver an asynchronous exception into
-- 'withResponseObligation', which answers its cancellation refusal and re-raises
-- — so the caller would receive @503 shutting-down@, and any second write would
-- be a second reply on one connection. Inside, the expiry is an ordinary value
-- and the peer gets exactly one reply that names what happened.
serveControlPlaneConnection
  :: RuntimeRole
  -> RoleInterpreter IO
  -> Deadline
  -> Socket
  -> IO ()
serveControlPlaneConnection activeRole interpreter deadline client =
  withResponseObligation (controlPlaneResponseObligation activeRole) client $ do
    now <- monotonicInstantFromMicros <$> controlPlaneMonotonicMicros
    case deadlineObservation now deadline of
      DeadlineExpired -> do
        drainBeforeRefusal client
        pure controlPlaneDeadlineReply
      DeadlineOpen (RemainingDuration remaining) -> do
        answered <- timeout (controlPlaneTimeoutMicros remaining) served
        pure (fromMaybe controlPlaneDeadlineReply answered)
 where
  served = do
    framed <- receiveControlPlaneRequest client
    case framed of
      Left _ -> pure (ReplyBadRequest, "bad-request\n")
      Right request ->
        serveControlPlaneRequest
          productionRoleReadinessResolver
          interpreter
          activeRole
          request

controlPlaneDeadlineReply :: (ReplyStatus, ByteString.ByteString)
controlPlaneDeadlineReply = (ReplyRequestTimeout, "request-deadline-exceeded\n")

-- | Saturate rather than wrap: a budget wider than 'Int' becomes the widest
-- representable wait, never a negative one.
controlPlaneTimeoutMicros :: Natural -> Int
controlPlaneTimeoutMicros value = fromIntegral (min value (fromIntegral (maxBound :: Int)))

-- | The production obligation. Both refusal statuses are ones
-- 'httpReasonPhrase' already maps, so a refusal renders a complete status line.
--
-- The refusal body carries no exception text. That is a deliberate asymmetry
-- with the integration fixture server, which does carry it: a fixture's job is
-- to name the failure, a production control-plane role's is not to leak it.
--
-- Sprint 4.65: because the body carries nothing, the reason has to go
-- somewhere, and until now it went nowhere — a `500` was the whole surviving
-- record of any handler failure. It is now recorded on the role's own stderr,
-- which is the pod's captured log stream and is not the wire.
controlPlaneResponseObligation
  :: RuntimeRole -> ResponseObligation (ReplyStatus, ByteString.ByteString)
controlPlaneResponseObligation role =
  mkResponseObligation
    (uncurry renderHttpResponse)
    controlPlaneRefusalReply
    (observeControlPlaneRefusal role)
    responseWriteBudgetMicrosDefault

-- | Record a refused control-plane response with its structured reason.
--
-- Sprint 4.65. The status the peer received is included so an operator reading
-- the log can join it to the client's observation, and the role is included
-- because five roles share this implementation and one line of stderr must say
-- which of them refused.
observeControlPlaneRefusal :: RuntimeRole -> ResponseRefusal -> IO ()
observeControlPlaneRefusal role refusal =
  logError
    "control_plane_response_refused"
    [ field "role" (runtimeRoleName role)
    , field "reply_status" (replyStatusCode (fst (controlPlaneRefusalReply refusal)))
    , field "reason" (renderResponseRefusalReason refusal)
    ]

controlPlaneRefusalReply :: ResponseRefusal -> (ReplyStatus, ByteString.ByteString)
controlPlaneRefusalReply refusal = case refusal of
  ResponseHandlerFailed _ -> (ReplyInternalError, "internal-error\n")
  ResponseCancelled _ -> (ReplyServiceUnavailable, "shutting-down\n")
