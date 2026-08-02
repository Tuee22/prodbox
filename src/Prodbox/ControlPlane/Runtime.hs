{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

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
  )
where

import Control.Concurrent (forkFinally)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (forever, void)
import Crypto.Random (getRandomBytes)
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Dhall qualified
import GHC.Generics (Generic)
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)
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
import Prodbox.ControlPlane.BootstrapHandoffEndpoint
  ( bootstrapHandoffAuthenticatedHandler
  , vaultBootstrapHandoffRepository
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerService)
  , callerPrincipalCode
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
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleOperationSubmit, ProviderWorkApply)
  , routesForRole
  )
import Prodbox.ControlPlane.Server
  ( ControlPlaneFramingError
  , ControlPlaneFramingProgress (..)
  , RoleInterpreter
  , controlPlaneMaximumBodyBytes
  , finishControlPlaneRequestFraming
  , inspectControlPlaneRequestFraming
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
  ( targetMaterialObservationAuthenticatedHandler
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
import Prodbox.Http.Client (defaultHttpConfig)
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
  -> IO (Either Text (RoleInterpreter IO))
lifecycleAuthorityRuntimeInterpreter vaultConfig vaultSession trustRegistry clientSigner store coordinates registeredAgentIdentity = do
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
                (inClusterAuthorityReady store)
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
                  (inClusterAuthorityReady store)
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
                  (inClusterAuthorityReady store)
                  currentAuthorityTime
                  awsAdminRepositoryResolver
                  awsAdminTargetLifecycle
                  manifestSigner
                  providerHandler
              adminActionHandler =
                adminActionAuthenticatedHandler
                  adminActionEndpointMaximumBytes
                  (inClusterAuthorityReady store)
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
                  (vaultBootstrapHandoffRepository vaultSession)
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
                            (inClusterAuthorityReady store)
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
                  , federationRegistrationBoundaryReady = inClusterAuthorityReady store
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
            ( installAuthenticatedRuntimeInterpreter
                LifecycleAuthorityRuntime
                runtimeInputs
                authenticatedHandler
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
  "http://authority-backup.authority-backup.svc.cluster.local:8600"

providerWorkerServiceEndpoint :: Text
providerWorkerServiceEndpoint =
  "http://provider-worker.provider-worker.svc.cluster.local:8600"

lifecycleAuthorityServiceEndpoint :: Text
lifecycleAuthorityServiceEndpoint =
  "http://lifecycle-authority.lifecycle-authority.svc.cluster.local:8600"

lifecycleAuthorityTargetControllerTokenFile :: FilePath
lifecycleAuthorityTargetControllerTokenFile =
  "/var/run/secrets/prodbox-target-controller/token"

targetSecretAgentServiceEndpoint :: Text
targetSecretAgentServiceEndpoint =
  "http://target-secret-agent.target-secret-agent.svc.cluster.local:8600"

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
  -> RoleInterpreter IO
authorityBackupRuntimeInterpreter binding =
  authorityBackupInterpreter
    controlPlaneMaximumBodyBytes
    (authorityBackupAdapterReady binding)
    (authorityBackupRepository binding)

tlsRetentionRuntimeInterpreter
  :: DedicatedAdapterBinding 'TlsRetentionAdapter
  -> RoleInterpreter IO
tlsRetentionRuntimeInterpreter binding =
  tlsRetentionInterpreter
    controlPlaneMaximumBodyBytes
    (tlsRetentionAdapterReady binding)
    (tlsRetentionRepository binding)

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
              , "LISTENER=0.0.0.0:8600"
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
                  Right interpreter -> runControlPlaneServer role interpreter
    (AuthorityBackupRuntime, ValidatedAuthorityBackupStore storeConfig) -> do
      bindingResult <- newAuthorityBackupAdapterBinding vaultSession storeConfig
      case bindingResult of
        Left _ -> pure (ExitFailure 1)
        Right binding ->
          runAuthenticatedContextFree
            authentication
            (authorityBackupRuntimeInterpreter binding)
            largeAuthenticatedFrameMaximumBytes
            standardAuthenticatedResponseMaximumBytes
            standardReplayCapacity
            standardReplayMaximumEncodedBytes
    (TlsRetentionRuntime, ValidatedTlsRetentionStore storeConfig) -> do
      bindingResult <- newTlsRetentionAdapterBinding vaultSession storeConfig
      case bindingResult of
        Left _ -> pure (ExitFailure 1)
        Right binding ->
          runAuthenticatedContextFree
            authentication
            (tlsRetentionRuntimeInterpreter binding)
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
        Right handler ->
          runAuthenticatedHandler
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
        Right handler ->
          runAuthenticatedHandler
            authentication
            handler
            standardAuthenticatedFrameMaximumBytes
            standardAuthenticatedResponseMaximumBytes
            standardReplayCapacity
            standardReplayMaximumEncodedBytes
    _ -> pure (ExitFailure 1)

  runAuthenticatedContextFree
    authentication
    inner
    frameMaximum
    responseMaximum
    replayCapacity
    replayMaximumEncoded =
      runAuthenticatedHandler
        authentication
        (contextFreeAuthenticatedRoleHandler inner)
        frameMaximum
        responseMaximum
        replayCapacity
        replayMaximumEncoded

  runAuthenticatedHandler
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
        Right interpreter -> runControlPlaneServer role interpreter

-- | Complete Provider Worker production composition. The outer request is
-- authenticated as Lifecycle Authority; the independently signed inner intent
-- is then checked against the same pinned Authority Transit generation before
-- a rank-2 session reads the one Provider credential object.
providerWorkerRuntimeHandler
  :: VaultSession
  -> Text
  -> RouteTrustRegistry
  -> RequestSigningCapability IO
  -> Either Text (AuthenticatedRoleHandler IO)
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
          (providerProductionNarrowSession vaultSession authorityTransport)
          providerProductionCapabilities
      fallback =
        AuthenticatedRoleHandler
          { authenticatedHandlerReadyz = do
              trusted <- acceptedAuthority
              providerReady <- providerProductionReady vaultSession
              pure (either (const False) (const providerReady) trusted)
          , authenticatedHandlerHandle = \_ _ _ -> pure Nothing
          }
  Right
    ( providerWorkerExecutionAuthenticatedHandler
        providerCommittedIntentMaximumEncodedBytes
        boundary
        fallback
    )

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
  -> IO (Either Text (AuthenticatedRoleHandler IO))
targetSecretAgentRuntimeHandler vaultConfig vaultSession clusterId agentIdentity clientSigner =
  case (buildBoundaries, targetOneShotRuntimeBoundary) of
    (Left detail, _) -> pure (Left detail)
    (_, Left detail) -> pure (Left detail)
    (Right (registry, inventory, custody), Right oneShotBoundary) -> do
      let signer = vaultAuthorityManifestSigner vaultSession
      signerResult <- readAuthorityManifestPublicKey signer
      pure $ do
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
                (vaultTargetMaterialRepository vaultSession)
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
  targetOneShotRuntimeBoundary = do
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
        , targetOneShotOperationBoundaryReady = do
            observedTime <- currentAuthorityTime
            projectedJwt <-
              readProjectedServiceAccountJwt
                targetSecretControllerAuditorTokenFile
            pure
              ( either (const False) (const True) observedTime
                  && either (const False) (const True) projectedJwt
              )
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
  -> Either Text (RoleInterpreter IO)
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
        authenticatedHandler =
          inner
            { authenticatedHandlerReadyz = do
                innerReady <- authenticatedHandlerReadyz inner
                epochReady <- readRetainedAuthorityEpoch vaultSession
                replayReady <- readRequestReplayProjection replayRepository
                pure
                  ( innerReady
                      && either (const False) (const True) epochReady
                      && either (const False) (const True) replayReady
                  )
            }
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
    mapLeft
      (Text.pack . show)
      (installAuthenticatedRuntimeInterpreter role runtimeInputs authenticatedHandler)

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

runControlPlaneServer
  :: RuntimeRole
  -> RoleInterpreter IO
  -> IO ExitCode
runControlPlaneServer role interpreter =
  withSocketsDo $
    bracket open close $ \listener ->
      forever $ do
        (client, _) <- accept listener
        void $ forkFinally (serve role client) (const (close client))
 where
  open = do
    listener <- socket AF_INET Stream defaultProtocol
    setSocketOption listener ReuseAddr 1
    bind listener (SockAddrInet 8600 (tupleToHostAddress (0, 0, 0, 0)))
    listen listener 32
    pure listener
  serve activeRole client = do
    framed <- receiveControlPlaneRequest client
    case framed of
      Left _ -> sendAll client (renderHttpResponse 400 "bad-request\n")
      Right request -> do
        (status, body) <- serveControlPlaneRequest interpreter activeRole request
        sendAll client (renderHttpResponse status body)
