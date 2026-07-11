{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Main (main) where

import AwsSesLeaseRole (awsSesLeaseRoleSuite)
import AwsSesLifecycle (awsSesLifecycleSuite)
import AwsSesReadiness (awsSesReadinessSuite)
import AwsSesSmtpKey (awsSesSmtpKeySuite)
import Control.Exception (finally)
import Control.Monad (forM_, when)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Either (isLeft, isRight)
import Data.IORef
  ( modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List
  ( elemIndex
  , find
  , isInfixOf
  , isPrefixOf
  , sort
  )
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import Data.Vector qualified as Vector
import DesiredPresentReconciliation (desiredPresentReconciliationSuite)
import Dhall qualified
import FencedCheckpoint (fencedCheckpointSuite)
import GatewayAuthority (gatewayAuthoritySuite)
import GatewayBounded (gatewayBoundedSuite)
import GatewayContinuity (gatewayContinuitySuite)
import GatewayProbe (gatewayProbeSuite)
import GatewayRuntimeStability (gatewayRuntimeStabilitySuite)
import LifecycleLease (lifecycleLeaseSuite)
import Numeric.Natural (Natural)
import Options.Applicative
  ( ParserResult (..)
  , defaultPrefs
  , execParserPure
  , renderFailure
  )
import Parser (parserSuite)
import Prodbox.App
  ( Env (..)
  , askEnv
  , canRunWithoutRepoRoot
  , runApp
  )
import Prodbox.Aws
  ( AwsSetupInput (..)
  , AwsTeardownInput (..)
  , ConfigSetupInput (..)
  , IamProbe (..)
  , QuotaStatus (..)
  , ResidueError (..)
  , SessionTokenPromptShape (..)
  , SpotPriceRequest (..)
  , VaultProbe (..)
  , awsErrorCodeIsTransient
  , awsRegionQuotaPreflightFromStatuses
  , awsSpotPriceHistoryArgs
  , buildIamPolicyDocument
  , buildIamPolicyDocumentForAccountAndCaptureBucket
  , configFromSetupInput
  , harnessPostflightResiduePolicy
  , longLivedResourceNames
  , operationalAwsConfigResidueFromKey
  , operationalCredentialsClearedDecision
  , operationalIamUserResidueFromExists
  , operationalManagedResources
  , partitionResidueByLifecycle
  , perRunStackNames
  , pulumiDestroyPlanForResidue
  , quotaStatusRegionObservation
  , refineAwsConfigResidueAgainstIamUser
  , renderAwsSetupPlan
  , renderAwsTeardownPlan
  , renderConfigSetupPlan
  , renderPulumiResidueLongLivedRefusal
  , renderPulumiResidueRefusal
  , renderResidueError
  , residueFromProbe
  , sessionTokenPromptShape
  , spotObservationFromAwsSpotPriceHistory
  , spotObservationFromAwsSpotPriceOutput
  )
import Prodbox.AwsEnvironment
  ( awsCliSubprocessEnvironment
  , overlayAwsCredentials
  , sealedAwsEnvironment
  )
import Prodbox.CLI.Charts
  ( renderChartDeletePlan
  , renderChartDeploymentPlan
  )
import Prodbox.CLI.Command
  ( AwsCommand (..)
  , AwsTeardownFlags (..)
  , ChartsCommand (..)
  , CommandRequest (..)
  , ConfigCommand (..)
  , CoverageFlags (..)
  , DaemonLaunchOptions (..)
  , DaemonStatusOptions (..)
  , DnsCommand (..)
  , EdgeCommand (..)
  , FederationRegisterOptions (..)
  , GatewayCommand (..)
  , HostCommand (..)
  , IntegrationSuite (..)
  , K8sCommand (..)
  , NativeCommand (..)
  , NukeOptions (..)
  , PerRunPruneTarget (..)
  , PlanOptions (..)
  , PolicyTier (..)
  , PulumiCommand (..)
  , PulumiResiduePolicy (..)
  , Rke2Command (..)
  , Rke2DeleteFlags (..)
  , TestCommand (..)
  , TestScope (..)
  , VaultCommand (..)
  , WorkloadCommand (..)
  , WorkloadOptions (..)
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.CLI.Docs
  ( renderCommandHelp
  , renderCommandSurfaceMatrix
  , renderCommandSurfaceTopLevel
  )
import Prodbox.CLI.Interactive
  ( InteractiveGuard (..)
  , allowNonTtyInteractiveEnvVar
  , awsCheckQuotasGuard
  , awsRequestQuotasGuard
  , awsSetupGuard
  , awsTeardownGuard
  , chartsDeleteGuard
  , configSetupGuard
  , renderNonTtyError
  )
import Prodbox.CLI.Json (renderCommandJson)
import Prodbox.CLI.Nuke qualified as Nuke
import Prodbox.CLI.Output
  ( ColorMode (..)
  , OutputFormat (..)
  , OutputOptions (..)
  , defaultOutputOptions
  , renderError
  , renderOutput
  )
import Prodbox.CLI.Parser
  ( Options (..)
  , parserInfo
  , validateCommandArgv
  )
import Prodbox.CLI.Pulumi
  ( renderPulumiPlan
  , runPulumiCommandWithGate
  )
import Prodbox.CLI.Rke2
  ( GatewayObjectStoreProbe (..)
  , MinioImageSource (..)
  , OperationalAwsCredentialGate (..)
  , RedirectPolicy (..)
  , RegistryStorageBackend (..)
  , RegistryStorageEdgeReadiness (..)
  , RetainedStorageInventoryEntry (..)
  , acmeClusterIssuerSpec
  , acmeRuntimeManifestWith
  , adminPublicEdgeManifestItems
  , buildNativeDeletePlan
  , buildNativeInstallExecutionPlan
  , cascadeOrderNarration
  , classifyGatewayObjectStoreProbe
  , classifyRegistryStorageEdgeProbe
  , gatewayDaemonDeploymentRefs
  , harborRegistryStorageBackend
  , homeSubstratePlatformComponents
  , hostCapacityCoversPlan
  , inferCascadeSubstrate
  , isMinioSecretKeyArgumentSafe
  , isRetryableHarborPublicationFailure
  , isRetryableHelmFailure
  , isRetryableRoute53CredentialFailure
  , nativeComponentReadinessTarget
  , nativeInstallStepOrder
  , nativeInstallStepOrderRespectsGraph
  , operationalAwsCredentialGateFromResult
  , parseHostCapacityObservation
  , registryConfigYaml
  , renderInotifySysctlDropIn
  , renderMinioChartArgs
  , renderNativeDeletePlan
  , renderNativeInstallPlan
  , renderResourceVectorRuntime
  , renderRke2ResourceGuardrailConfig
  , renderRke2SystemdResourceDropIn
  , retainedStorageInventoryEntries
  , stepsForComponent
  )
import Prodbox.CLI.Spec
  ( ArgumentSpec (..)
  , CommandSpec (..)
  , awsTeardownPolicyFromFlags
  , commandRegistry
  , findCommandSpec
  , leafCommandPaths
  )
import Prodbox.CLI.Tree (renderCommandTree)
import Prodbox.CLI.Vault
  ( HostVaultDirectSeam (..)
  , VaultDaemonProbe (..)
  , VaultLifecycleTransportDecision (..)
  , gatewayAwsVaultFields
  , gatewayProbeFromResult
  , retryDaemonTransient
  , vaultLifecycleTransportDecision
  )
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.RuntimeMemory qualified as RuntimeMemory
import Prodbox.Capacity.Storage qualified as Storage
import Prodbox.Cbor qualified as Cbor
import Prodbox.CheckCode
  ( DoctrineViolation (..)
  , awsCreateProbeVerbs
  , awsCreateSiteViolations
  , awsCreateVerbs
  , destructivePlanOptionsArms
  , doctrineViolationsInPaths
  , extractMarkdownLinkTargets
  , extractStringLiterals
  , generatedSectionsReconcilerViolations
  , iamCreateSiteViolations
  , inlineRetrySubstringListViolations
  , isRelativeLinkTarget
  , listRepoOwnedPaths
  , matchesSprintToken
  , parseGeneratedSectionsField
  , planOptionsHonoredViolations
  , prodboxMarkerKeysPresent
  , pulumiCreateSiteViolations
  , relativeLinkResolves
  , serviceErrorRetryableLiteralViolations
  , stripFencedCodeBlocks
  , stripInlineCodeSpans
  , substrateImagePinningViolations
  )
import Prodbox.CheckCode qualified
import Prodbox.Cluster.Federation
  ( ChildBootstrapCredential (..)
  , ChildIndex (..)
  , ChildInitCustody (..)
  , ChildMetadata (..)
  , FederationWriteAuthority (..)
  , FederationWriteDecision (..)
  , childBootstrapKvLogicalPath
  , childBootstrapKvPath
  , childBootstrapVaultFields
  , childIndexVaultFields
  , childInitKvLogicalPath
  , childInitKvPath
  , childMetadataKvLogicalPath
  , childMetadataKvPath
  , childMetadataVaultFields
  , childRegistrationInitPath
  , childRegistrationMetadataPath
  , childRegistrationPlan
  , childRegistrationTransitKey
  , childRegistrationVaultNamespace
  , childTransitKeyName
  , childTransitSealPolicyDocument
  , childVaultNamespace
  , decodeChildBootstrapCredential
  , decodeChildIndex
  , decodeChildInitCustody
  , decodeChildMetadata
  , decodePayloadJsonField
  , encodeChildBootstrapCredential
  , encodeChildIndex
  , encodeChildInitCustody
  , encodeChildMetadata
  , federationChildrenIndexKvLogicalPath
  , federationChildrenIndexKvPath
  , federationWriteDecision
  , renderChildRegistrationPlan
  , renderFederationWriteBlock
  , upsertChildIndex
  )
import Prodbox.Cluster.Placement qualified as ClusterPlacement
import Prodbox.Cluster.Substrate qualified as ClusterSubstrate
import Prodbox.Cluster.Topology qualified as ClusterTopology
import Prodbox.Config.Basics
  ( ParentRef (..)
  , SealMode (..)
  , UnencryptedBasics (..)
  , basicsFromJson
  , basicsToJson
  , isRootCluster
  , validateBasics
  )
import Prodbox.Config.ComponentGraph
  ( ComponentDependency (..)
  , ComponentGraphError (..)
  , ComponentId (..)
  , ComponentNode (..)
  , EdgeKind (..)
  , ProbeDepth (..)
  , ReadinessProbe (..)
  , componentDagOrder
  , componentDependencyIds
  , componentReconcileOrder
  , defaultComponentGraph
  , lookupComponentNode
  , operatorAvailableGates
  , probeDepth
  , probeSatisfiesBackendWrite
  , validateComponentGraph
  )
import Prodbox.Config.InForce
  ( ConfigSource (..)
  , InForceConfigError (..)
  , RootConfigWriteDecision (..)
  , RootWriteAuthority (..)
  , SeedProposeDecision (..)
  , fetchInForceConfigWith
  , openInForcePayload
  , renderInForcePayload
  , renderRootConfigWriteBlock
  , rootConfigWriteDecision
  , sealInForcePayload
  , seedProposeDecision
  , storeInForceConfigWith
  )
import Prodbox.Config.SchemaDhall
  ( renderConfigTypesDhall
  , renderTestSecretsTypesDhall
  )
import Prodbox.Config.Tier0
  ( ContextKind (..)
  , ProdboxContext (..)
  , ProdboxProjectConfig (..)
  , ProdboxTopology (..)
  , Tier0ParentRef (..)
  , Tier0SealMode (..)
  , Tier0Source (..)
  , daemonConfigMapTier0Path
  , defaultDaemonContext
  , defaultDaemonProjectConfig
  , defaultProjectConfig
  , ensureBasicsFloorAtPath
  , ensureChildBasicsFloorAtPath
  , loadDaemonBinaryContext
  , projectBasics
  , renderProjectConfigDhall
  , tier0CarriesNoSecretValues
  , writeTier0AtPath
  )
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.Crypto.Envelope
  ( DekCipher (..)
  , EnvelopeError (..)
  , insecureLocalDekCipher
  , openEnvelope
  , sealEnvelope
  )
import Prodbox.Daemon.Events qualified as DaemonEvents
import Prodbox.DockerConfig qualified as DockerConfig
import Prodbox.Effect
  ( Effect (..)
  , Validation (..)
  )
import Prodbox.EffectDAG
  ( EffectNode (..)
  , acyclicTopologicalOrder
  , fromRootIds
  , transitiveClosureIds
  )
import Prodbox.EffectInterpreter
  ( InterpreterContext (..)
  , runEffect
  , runEffectDAG
  )
import Prodbox.Error
  ( ErrorKind (..)
  , errorCause
  , errorKind
  , fatalError
  , recoverableError
  )
import Prodbox.Gateway
  ( renderGatewayConfigTemplate
  , renderGatewayStartPlan
  , renderGatewayStatusReport
  )
import Prodbox.Gateway.Client qualified
import Prodbox.Gateway.Daemon
  ( BootstrapVaultRequest (..)
  , BootstrapVaultRequestError (..)
  , BootstrapVaultRotateTransitKeyRequest (..)
  , BootstrapVaultRotateUnlockBundleRequest (..)
  , PulumiObjectRequestError (..)
  , allowedOperatorSecretPaths
  , bootstrapVaultPath
  , bootstrapVaultPkiIssueTestCertPath
  , bootstrapVaultPkiStatusPath
  , bootstrapVaultRequestMaxBytes
  , bootstrapVaultRotateTransitKeyPath
  , bootstrapVaultRotateUnlockBundlePath
  , bootstrapVaultSealPath
  , bootstrapVaultStatusPath
  , daemonBootFieldsChanged
  , decodeBootstrapVaultAuthenticatedRequest
  , decodeBootstrapVaultRequest
  , decodeBootstrapVaultRotateTransitKeyRequest
  , decodeBootstrapVaultRotateUnlockBundleRequest
  , decodeOperatorSecretFields
  , decodePulumiObjectPutRequest
  , decodePulumiObjectRequest
  , operatorSecretJwtHeader
  , operatorSecretLogicalPath
  , operatorSecretRequestMethod
  , operatorWriteRoleName
  , renderBootstrapVaultRequestError
  , renderPulumiObjectRequestError
  , requestBodyBytes
  )
import Prodbox.Gateway.Logging
  ( Severity (..)
  , severityFromLogLevel
  , shouldLogSeverity
  )
import Prodbox.Gateway.ObjectStore
  ( PulumiObjectGetResponse (..)
  , PulumiObjectPutRequest (..)
  , PulumiObjectRequest (..)
  , pulumiObjectGetPath
  , pulumiObjectPutPath
  , pulumiObjectRequestMaxBytes
  , validatePulumiObjectStackName
  )
import Prodbox.Gateway.PortForward qualified as GatewayPortForward
import Prodbox.Gateway.Probe qualified as GatewayProbe
import Prodbox.Gateway.Settings qualified as GatewaySettings
import Prodbox.Gateway.Types
  ( DaemonConfig (..)
  , DnsWriteGate (..)
  , GatewayRule (..)
  , GatewayVaultAuth (..)
  , Orders (..)
  , PeerEndpoint (..)
  , cborPayloadFromJsonValue
  , decodeOrdersCbor
  , encodeOrdersCbor
  , validateDaemonTimingAgainstOrders
  )
import Prodbox.Host
  ( FirewallRuleAction (..)
  , NtpDisposition (..)
  , PortStatus (..)
  , gatewayNodePortFirewallCheckArgs
  , gatewayNodePortFirewallRuleArgs
  , parseTimedatectlNtpDisposition
  , renderFirewallRuleAction
  , renderHostInfoReport
  , renderPortAvailabilityReport
  )
import Prodbox.Host.Ensure qualified as HostEnsure
import Prodbox.Host.Lift
  ( HostDispatch (..)
  , LiftLayer (..)
  , SelfRef (..)
  , clusterFrame
  , foldHostLift
  )
import Prodbox.Host.Lima
  ( defaultLimaVM
  )
import Prodbox.Host.Substrate
  ( HostSubstrate (..)
  , classifyHost
  , hostSubstrateNeedsLift
  )
import Prodbox.Host.Tool
  ( HostTool (..)
  , absExePath
  , hostToolCommandName
  , mkAbsExe
  )
import Prodbox.Host.Wsl2
  ( defaultWsl2VM
  )
import Prodbox.Http.Client qualified
import Prodbox.Infra.AwsEksTestStack qualified as AwsEks
import Prodbox.Infra.AwsProviderCredentials qualified as AwsProviderCredentials
import Prodbox.Infra.AwsSesStack qualified as AwsSesStack
import Prodbox.Infra.AwsTestStack qualified as AwsTest
import Prodbox.Infra.LongLivedPulumiBackend
  ( LongLivedBackendError (..)
  , adminCredentialsConfigured
  , longLivedBackendErrorMessage
  , longLivedPulumiBackendUrl
  , longLivedPulumiBackendUrlEither
  , parseObjectKeysPayload
  , renderDeletePayload
  , renderLongLivedObjectVaultGateBlock
  )
import Prodbox.Infra.MinioBackend
  ( firstReadableKubeconfigCandidate
  , localKubeconfigCandidates
  , minioBackendBucket
  , parseDeletedMinioExportHostPath
  )
import Prodbox.Infra.StackDescriptor qualified as StackDescriptor
import Prodbox.Infra.StackOutputs qualified as StackOutputs
import Prodbox.K8s
  ( parseKubectlObjectNames
  )
import Prodbox.K8s.InCluster qualified as InCluster
import Prodbox.Keycloak.Admin qualified
import Prodbox.Keycloak.CredentialSetupForm
  ( CredentialSetupForm (..)
  , parseCredentialSetupContinuationLink
  , parseCredentialSetupForm
  , renderCredentialSetupFormPost
  )
import Prodbox.Keycloak.Email qualified
import Prodbox.Lib.AwsSubstratePlatform qualified
import Prodbox.Lib.ChartPlatform
  ( ChartDeploymentPlan (..)
  , ChartInstallSnapshot (..)
  , ChartReleasePlan (..)
  , PatroniAuthObservation (..)
  , PatroniResetDecision (..)
  , PublicEdgePreserveOutcome (..)
  , buildChartDeletePlan
  , buildChartDeploymentPlan
  , buildChartDeploymentPlanForSubstrate
  , certManagerAdoptionAnnotations
  , chartReleasesToDeploy
  , classifyPublicEdgePreserve
  , deploymentConditionReportsTrue
  , kubernetesSecretDecodedDataField
  , observePatroniOperatorAvailableWith
  , operatorAvailableTarget
  , operatorGateResult
  , patroniSeedMismatchDecision
  , renderPatroniResetDecision
  , renderPublicEdgePreserveOutcome
  , resolveChartSecrets
  , resolveDependencyOrder
  , retainedPublicEdgeTlsSecretManifest
  , supportedChartNames
  , validateOperatorGatesWith
  )
import Prodbox.Lib.EksContainerdMirror qualified
import Prodbox.Lib.EksCustomImagePush qualified
import Prodbox.Lib.EksImageMirror qualified
import Prodbox.Lib.Storage
  ( ChartStorageBinding (..)
  , ChartStorageSpec (..)
  , StaticEbsVolumeBinding (..)
  , chartEbsStorageManifest
  , retainedStatefulSetPersistentVolumeClaimName
  , retainedStatefulSetPersistentVolumeName
  , storageBinding
  , testManualPvHostRootEnv
  )
import Prodbox.Lifecycle.EbsVolume qualified as EbsVolume
import Prodbox.Lifecycle.FederatedVault
  ( FederatedVaultLifecycle (..)
  , ParentVaultReadiness (..)
  , parentReadinessDecision
  , renderParentReadinessBlock
  , vaultLifecycleFromBasics
  , vaultLifecycleHelmSealArgs
  )
import Prodbox.Lifecycle.K8sDrain
  ( CascadeDecision (..)
  , DrainResult (..)
  , K8sDrainEnv (..)
  , cascadeDecisionFromDrainResult
  , deleteReclaimPersistentVolumeJsonPath
  , deleteReclaimPvcBindings
  )
import Prodbox.Lifecycle.LiveResidue (PerRunResidueStatuses (..))
import Prodbox.Lifecycle.LiveResidue qualified as LiveResidue
import Prodbox.Lifecycle.Preconditions qualified as Preconditions
import Prodbox.Lifecycle.ReadinessObservation
  ( ComponentReadinessTarget (..)
  , ReadinessObservation (..)
  , ReadinessProbeResult (..)
  , observationPollOutcome
  , observeComponentReadiness
  , readinessGateOpen
  , waitForComponentReadiness
  )
import Prodbox.Lifecycle.ResidueStatus qualified as Residue
import Prodbox.Lifecycle.ResourceClass qualified as ResourceClass
import Prodbox.Lifecycle.ResourceRegistry qualified as ResourceRegistry
import Prodbox.Lifecycle.TagSweep qualified as TagSweep
import Prodbox.Minio.EncryptedObject
  ( EncryptedObjectError (..)
  , LogicalObject (..)
  , decodeIndex
  , decoyObjectKeys
  , encodeIndex
  , getLogicalWith
  , objectKeyForOpaqueId
  , opaqueObjectId
  , putLogicalWith
  )
import Prodbox.Minio.ObjectStore
  ( ObjectStoreConfig (..)
  , defaultObjectStoreBucket
  , isNoSuchBucketOutput
  , objectStoreCreateBucketArgs
  , objectStoreHeadBucketArgs
  )
import Prodbox.Minio.RootCredential (minioRootPassword, minioRootUser)
import Prodbox.Naming
  ( boundedResourceName
  , hashSuffix
  , sanitizeResourceName
  )
import Prodbox.Native
  ( commandPrerequisites
  )
import Prodbox.PostgresPlatform
  ( patroniPersistentVolumeClaimName
  , patroniPrimaryServiceName
  , patroniReplicaServiceName
  , patroniStorageSpecs
  )
import Prodbox.Prerequisite
  ( prerequisiteRegistry
  )
import Prodbox.PrerequisiteId
  ( PrerequisiteId (..)
  , prerequisiteIdEngagesIamHarness
  , prerequisiteIdText
  )
import Prodbox.PublicEdge
  ( publicEdgeClusterIssuerName
  , publicEdgeTlsRetentionKey
  )
import Prodbox.Pulsar.Client qualified as PulsarClient
import Prodbox.Pulsar.Codec qualified as PulsarCodec
import Prodbox.Pulsar.Envelope qualified as PulsarEnvelope
import Prodbox.Pulsar.Protocol qualified as PulsarProtocol
import Prodbox.Pulsar.Topic qualified as PulsarTopic
import Prodbox.Pulsar.TopicResidue qualified as PulsarTopicResidue
import Prodbox.Pulumi.EncryptedBackend
  ( CheckpointObservability (..)
  , EncryptedBackendError (..)
  , EncryptedBackendHooks (..)
  , PulumiScratch (..)
  , PulumiStackRef (..)
  , classifyCheckpointBytes
  , fileBackendEnvironment
  , observeStackCheckpointWith
  , renderCheckpointObservability
  , stackCheckpointPath
  , withDaemonFirstFallback
  , withDecryptedStackWith
  )
import Prodbox.Result qualified as Result
import Prodbox.Retry
  ( PollOutcome (..)
  , RetryPolicy (..)
  , pollUntilReady
  , retryDelayMicros
  )
import Prodbox.Scaling.Autoscaler qualified as Autoscaler
import Prodbox.Scaling.Spot qualified as Spot
import Prodbox.Secret.VaultInventory qualified as VaultInventory
import Prodbox.Service
  ( RedisError (..)
  , ServiceError (..)
  , classifyServiceError
  , isRetryableTransientFailure
  , retryServiceAction
  , serviceErrorMessage
  , serviceErrorRetryable
  )
import Prodbox.Ses.SmtpPassword qualified
import Prodbox.Settings
  ( AcmeSection (..)
  , AwsCredentialsRef (..)
  , AwsSubstrateSection (..)
  , ConfigFile (..)
  , Credentials (..)
  , DeploymentSection (..)
  , DomainSection (..)
  , FailoverScenario (..)
  , FixtureId (..)
  , MetallbBgpPeer (..)
  , PulumiStateBackendSection (..)
  , Route53Section (..)
  , RunVariant (..)
  , StorageSection (..)
  , TestBudget (..)
  , TestSuite (..)
  , TestTopology (..)
  , TestTopologyError (..)
  , ValidatedSettings (..)
  , decodeConfigDhallBytes
  , defaultConfigFile
  , defaultTestTopology
  , inForceConfigObjectAbsent
  , loadConfigFileAtPath
  , loadConfigForSettingsWith
  , loadTestTopologyAtPath
  , loadUnencryptedBasicsAtPath
  , renderConfigDhall
  , renderSettingsDisplay
  , validateAndLoadSettingsAtPath
  , validateAwsBootstrapConfig
  , validatePublicEdgeDeployment
  , validateTestTopology
  )
import Prodbox.Settings.SecretRef
  ( SecretRef (..)
  , SecretRefError (..)
  , SecretRefMode (..)
  , VaultSecretRef (..)
  , resolveSecretRef
  , resolveSecretRefWithVault
  , secretRefIsPlaintext
  , validateProductionSecretRef
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , renderSubprocess
  , pattern Subprocess
  )
import Prodbox.Substrate
  ( ElasticScalingBounds (..)
  , ScalingPolicy (..)
  , ScalingPolicyBySubstrate (..)
  , Substrate (..)
  , fixedScalingPolicyBySubstrate
  )
import Prodbox.TestPlan
  ( NativeSuitePlan (..)
  , NativeValidation (..)
  , TestExecutionMode (..)
  , TestExecutionPlan (..)
  , derivedManagedAwsHarnessPolicyTier
  , nativeValidationId
  , retainedSesRequirementForValidations
  , testExecutionPlan
  , validationDeferredPrerequisites
  , validationInitialPrerequisites
  )
import Prodbox.TestRestore
  ( RestoreChart (..)
  , RestoreCyclePlan (..)
  , RestoreCycleStep (..)
  , RetainedSesRequirement (..)
  , buildRestoreCyclePlan
  , gatewayDaemonLivenessPrecondition
  , restoreStepResetsGatewayHealthyWindow
  )
import Prodbox.TestRunner
  ( ClusterEvidence (..)
  , PublicEdgeCertificateFailure (..)
  , TestDeleteTarget (..)
  , TestGate (..)
  , TestRefusal (..)
  , awsPostflightDestroyCommandArgs
  , awsSubstrateBootstrapCommandArgs
  , awsSubstrateBootstrapRestorePlan
  , awsSubstrateBootstrapRestoreSteps
  , clearOperationalCredsAfterPostflight
  , guardTestDelete
  , integrationRunbookCommandArgs
  , publicEdgeCertificateReissueStatusPatch
  , renderTestRefusal
  , supportedRuntimeBootstrapNeedsReconcile
  , supportedRuntimeBootstrapRestorePlan
  , supportedRuntimePostflightRestorePlan
  , testModePreflightAtPath
  , testModePreflightAtPaths
  , testProductionClusterGate
  , testProductionConfigGate
  , testScopeForTopologySuite
  , testTopologyModeGate
  , topologyRunConfig
  , topologyVariantEnvironment
  )
import Prodbox.TestTopology
  ( renderTestTopologyDhall
  )
import Prodbox.TestValidation
  ( DaemonBootstrapAuditInput (..)
  , SealedVaultAuditInput (..)
  , VolumeRebindSnapshot (..)
  , assertInviteOidcClaims
  , daemonBootstrapAuditReport
  , daemonBootstrapForbiddenPatterns
  , defaultDaemonBootstrapAuditInput
  , defaultSealedVaultAuditInput
  , parseVolumeRebindSnapshot
  , renderGatewayValidationConfigDhall
  , resourceGuardrailReport
  , sealedVaultAuditReport
  , sealedVaultForbiddenPatterns
  , sealedVaultHostDiskRoot
  , verifyAwsTestSshReachability
  , volumeRebindReport
  )
import Prodbox.UsersAdmin qualified
import Prodbox.Vault.BootstrapBundle
  ( bootstrapObjectStoreConfig
  , bootstrapUnlockBundleKey
  )
import Prodbox.Vault.Client
  ( BootstrapAction (..)
  , EnableAuthMethodRequest (..)
  , EnableMountRequest (..)
  , InitRequest (..)
  , InitResponse (..)
  , KubernetesAuthConfigRequest (..)
  , KubernetesLoginRequest (..)
  , KubernetesLoginResponse (..)
  , KubernetesRoleRequest (..)
  , KvV2ReadResponse (..)
  , KvV2WriteRequest (..)
  , PkiIssueCertificateRequest (..)
  , PkiIssueCertificateResponse (..)
  , SealStatus (..)
  , TokenCreateRequest (..)
  , TokenCreateResponse (..)
  , TransitEncryptRequest (..)
  , TransitEncryptResponse (..)
  , TransitKeyRequest (..)
  , VaultAddress (..)
  , VaultAuthInfo (..)
  , VaultAuthListing (..)
  , VaultMountInfo (..)
  , VaultMountListing (..)
  , VaultToken (..)
  , WritePolicyRequest (..)
  , bootstrapAction
  , defaultInitRequest
  , initResponseToUnlockBundle
  )
import Prodbox.Vault.Gate
  ( VaultGateDecision (..)
  , VaultGateOutcome (..)
  , renderVaultGateBlock
  , vaultGateDecision
  , vaultGateOutcome
  )
import Prodbox.Vault.Host
  ( AcmeEabFixture (..)
  , TestSecrets (acme_eab)
  , defaultTestSecrets
  , seedAcmeEabFromTestSecrets
  )
import Prodbox.Vault.Orchestration
  ( UnsealOutcome (..)
  , UnsealStep (..)
  , clusterEstablishedMarkerRelPath
  , interpretUnsealProgress
  , planUnseal
  )
import Prodbox.Vault.Reconcile
  ( VaultAuthSpec (..)
  , VaultKubernetesAuthConfigSpec (..)
  , VaultKubernetesRoleSpec (..)
  , VaultMountSpec (..)
  , VaultPolicySpec (..)
  , VaultReconcileAction (..)
  , VaultReconcileError (..)
  , VaultReconcileOps (..)
  , VaultReconcilePlan (..)
  , VaultReconcileStep (..)
  , VaultReconcileTarget (..)
  , VaultTransitKeySpec (..)
  , defaultVaultReconcilePlan
  , operatorWritePolicy
  , runVaultReconcileWith
  )
import Prodbox.Vault.RoleId
  ( VaultRoleId (VaultRoleGatewayDaemon)
  , vaultRoleIdText
  )
import Prodbox.Vault.Seal
  ( ChildSealCustody (..)
  , VaultSealMode (..)
  , childInitCustodyFromInitResponse
  , childInitCustodyVaultFields
  , childSealCustodyFromInitResponse
  , defaultRootShamirSealConfig
  , defaultTransitSealConfig
  , initRequestForSealMode
  , renderVaultSealHcl
  , transitSealPolicyDocument
  )
import Prodbox.Vault.Status
  ( renderSealStatus
  )
import Prodbox.Vault.TransitCipher
  ( vaultTransitDekCipherWith
  )
import Prodbox.Vault.UnlockBundle
  ( UnlockBundle (..)
  , UnlockBundleError (..)
  , decryptUnlockBundle
  , encryptUnlockBundle
  )
import Prodbox.Workload
  ( WorkloadBootConfig (..)
  , WorkloadLiveConfig (..)
  , WorkloadMode (..)
  , runWorkloadCommand
  , workloadBootConfigFromDhall
  , workloadBootFieldsChanged
  , workloadLiveConfigFromDhall
  , workloadLiveConfigFromDhallWith
  )
import Prodbox.Workload.Settings qualified as WorkloadSettings
import RetainedSesPreparation (retainedSesPreparationSuite)
import RetainedSesTargetRecovery (retainedSesTargetRecoverySuite)
import SmtpKeyRepairInterpreter (smtpKeyRepairInterpreterSuite)
import System.Directory
  ( Permissions (..)
  , copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getCurrentDirectory
  , getPermissions
  , getTemporaryDirectory
  , removeFile
  , setPermissions
  )
import System.Environment
  ( getExecutablePath
  , lookupEnv
  , setEnv
  , unsetEnv
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import TargetCommitSmtp (targetCommitSmtpSuite)
import TestSupport

withBinarySiblingTier0 :: String -> IO a -> IO a
withBinarySiblingTier0 contents action = do
  exePath <- getExecutablePath
  let tier0Path = takeDirectory exePath </> "prodbox.dhall"
  previousExists <- doesFileExist tier0Path
  previousContents <-
    case previousExists of
      True -> Just <$> readFile tier0Path
      False -> pure Nothing
  writeFile tier0Path contents
  action `finally` restoreBinarySiblingTier0 tier0Path previousContents

restoreBinarySiblingTier0 :: FilePath -> Maybe String -> IO ()
restoreBinarySiblingTier0 tier0Path previousContents =
  case previousContents of
    Just contents -> writeFile tier0Path contents
    Nothing -> do
      currentExists <- doesFileExist tier0Path
      when currentExists (removeFile tier0Path)

gatewayTier0DhallFromPlan :: ChartDeploymentPlan -> Either String String
gatewayTier0DhallFromPlan plan =
  case filter ((== "gateway") . chartReleasePlanReleaseName) (chartDeploymentPlanReleases plan) of
    [release] -> do
      values <- eitherDecode (BL8.pack (chartReleasePlanValuesJson release)) :: Either String Value
      case values of
        Object payload ->
          case KeyMap.lookup (Key.fromString "tier0") payload of
            Just (Object tier0Payload) ->
              case KeyMap.lookup (Key.fromString "prodboxDhall") tier0Payload of
                Just (String dhall) -> Right (Text.unpack dhall)
                _ -> Left "gateway values tier0.prodboxDhall is missing or not text"
            _ -> Left "gateway values tier0 object is missing"
        _ -> Left "gateway values payload is not an object"
    _ -> Left "deployment plan does not contain exactly one gateway release"

assertMountedGatewayTier0Identity :: String -> Text.Text -> Expectation
assertMountedGatewayTier0Identity rendered expectedIdentity =
  withSystemTempDirectory "prodbox-gateway-mounted-tier0" $ \tmpDir -> do
    let configMapDir = tmpDir </> "gateway-config"
        absentContainerDefault = tmpDir </> "absent-container-default.dhall"
    createDirectoryIfMissing True configMapDir
    writeFile (daemonConfigMapTier0Path configMapDir) rendered
    loaded <- loadDaemonBinaryContext configMapDir absentContainerDefault
    case loaded of
      Left err -> expectationFailure err
      Right (source, projectConfig) -> do
        source `shouldBe` Tier0FromConfigMap (daemonConfigMapTier0Path configMapDir)
        Tier0.context_kind (Tier0.context projectConfig) `shouldBe` Daemon
        Tier0.cluster_id (Tier0.context projectConfig) `shouldBe` expectedIdentity

assertExactlyOne :: (Show a) => [a] -> (a -> Expectation) -> Expectation
assertExactlyOne values assertion =
  case values of
    [value] -> assertion value
    _ -> expectationFailure ("expected exactly one value, got " ++ show values)

-- | Predicate helper for `Either String a` test assertions: passes
-- when the result is `Left msg` and `msg` contains the supplied
-- substring. Lets the `shouldSatisfy` call site stay free of nested
-- case lambdas (forbidden by `haskell-style` linting rules).
leftContains :: String -> Either String a -> Bool
leftContains needle result = case result of
  Left msg -> needle `isInfixOf` msg
  Right _ -> False

lowerString :: String -> String
lowerString = Text.unpack . Text.toLower . Text.pack

allowedRenderedSecretRefConstructors :: [String]
allowedRenderedSecretRefConstructors =
  [ "Config.SecretRef.Vault"
  , "Config.SecretRef.TransitKey"
  , ">.Vault"
  , ">.TransitKey"
  ]

forbiddenRenderedSecretRefConstructors :: [String]
forbiddenRenderedSecretRefConstructors =
  [ "Config.SecretRef.Prompt"
  , "Config.SecretRef.TestPlaintext"
  , ">.Prompt"
  , ">.TestPlaintext"
  , "SecretRefFile"
  ]

assertGeneratedSecretRefArtifact :: (String, Bool, String) -> Expectation
assertGeneratedSecretRefArtifact (artifactName, requiresSecretRef, contents) = do
  let lowered = lowerString contents
      forbiddenPatternHits =
        filter (`isInfixOf` lowered) sealedVaultForbiddenPatterns
      forbiddenConstructorHits =
        filter (`isInfixOf` contents) forbiddenRenderedSecretRefConstructors
      secretRefConstructorRendered =
        any (`isInfixOf` contents) allowedRenderedSecretRefConstructors
  case forbiddenPatternHits ++ forbiddenConstructorHits of
    [] -> pure ()
    hits ->
      expectationFailure
        (artifactName ++ " rendered forbidden secret surface(s): " ++ show hits)
  case (requiresSecretRef, secretRefConstructorRendered) of
    (True, False) ->
      expectationFailure
        (artifactName ++ " did not render a Vault or TransitKey SecretRef constructor")
    _ -> pure ()

-- | Sprint 1.36: a sample unlock bundle + password for the encrypted
-- unlock-bundle round-trip tests.
sampleUnlockBundle :: UnlockBundle
sampleUnlockBundle =
  UnlockBundle
    { unlockBundleClusterId = "cluster-xyz"
    , unlockBundleVaultAddressHint = "https://vault.vault.svc.cluster.local:8200"
    , unlockBundleCreatedAt = "2026-06-12T00:00:00Z"
    , unlockBundleUnsealKeys = ["unseal-share-1", "unseal-share-2", "unseal-share-3"]
    , unlockBundleRecoveryKeys = ["recovery-share-1", "recovery-share-2"]
    , unlockBundleInitialRootToken = "s.rootsecrettoken"
    , unlockBundleFormatVersion = 1
    }

sampleUnlockBundlePassword :: Text.Text
sampleUnlockBundlePassword = "correct horse battery staple"

sampleParentRef :: ParentRef
sampleParentRef =
  ParentRef
    { parentRefClusterId = "prodbox-root"
    , parentRefVaultAddress = "http://10.0.0.1:8200"
    , parentRefTransitKey = "transit/prodbox-child-seal"
    }

-- | Sprint 7.21: build read-only-observability hooks for
-- 'observeStackCheckpointWith'. The Vault gate proceeds and the encrypted
-- load is supplied by the caller; the scratch / store / delete hooks are
-- never exercised by the observe path (it must not mutate backend state),
-- so they are stubbed to fail loudly if accidentally invoked.
observabilityHooks
  :: IO (Either String (Maybe BS.ByteString)) -> EncryptedBackendHooks CheckpointObservability
observabilityHooks loadAction =
  EncryptedBackendHooks
    { encryptedBackendGate = pure VaultGateProceed
    , encryptedBackendLoad = const loadAction
    , encryptedBackendLoadLegacy = const (pure (Right Nothing))
    , encryptedBackendStore = \_ _ -> error "observe path must not store"
    , encryptedBackendDelete = const (error "observe path must not delete")
    , encryptedBackendDeleteLegacy = const (error "observe path must not delete legacy")
    , encryptedBackendWithScratch = \_ _ -> error "observe path must not hydrate scratch"
    }

-- Sprint 1.56 component-graph edge builders (test helpers).
orderingOn :: ComponentId -> ComponentDependency
orderingOn cid = ComponentDependency {dependency_on = cid, dependency_edge = OrderingEdge}

backendWriteOn :: ComponentId -> ComponentDependency
backendWriteOn cid = ComponentDependency {dependency_on = cid, dependency_edge = BackendWriteEdge}

sampleRootBasics :: UnencryptedBasics
sampleRootBasics =
  UnencryptedBasics
    { basicsClusterId = "prodbox-home"
    , basicsVaultAddress = "http://127.0.0.1:31820"
    , basicsSealMode = SealModeShamir
    , basicsParentRef = Nothing
    , basicsFormatVersion = 1
    }

sampleChildBasics :: UnencryptedBasics
sampleChildBasics =
  UnencryptedBasics
    { basicsClusterId = "prodbox-child"
    , basicsVaultAddress = "http://127.0.0.1:31820"
    , basicsSealMode = SealModeTransit
    , basicsParentRef = Just sampleParentRef
    , basicsFormatVersion = 1
    }

-- | Sprint 1.39: a populated Tier-0 binary-context record for the
-- @{ parameters, context, witness }@ tests. The context carries a child-cluster
-- topology so the projected floor exercises the parent-ref arm; the parameters
-- reuse the non-secret defaults (SecretRef.Vault pointers only).
sampleTier0Child :: ProdboxProjectConfig
sampleTier0Child =
  defaultProjectConfig
    { context =
        (context defaultProjectConfig)
          { project = "prodbox"
          , binary = "prodbox"
          , context_kind = HostOrchestrator
          , cluster_id = "prodbox-child"
          , vault_address = "http://127.0.0.1:31820"
          , topology =
              ProdboxTopology
                { seal_mode = Tier0Transit
                , parent_ref =
                    Just
                      Tier0ParentRef
                        { parent_cluster_id = "prodbox-root"
                        , parent_vault_address = "http://10.0.0.1:8200"
                        , parent_transit_key = "transit/prodbox-child-seal"
                        }
                }
          }
    }

runtimeMemoryTestBytes :: RuntimeMemory.MemoryTerm -> Natural -> RuntimeMemory.PositiveBytes
runtimeMemoryTestBytes term value =
  case RuntimeMemory.mkPositiveBytes term value of
    Left err -> error ("invalid runtime-memory test fixture: " ++ show err)
    Right validated -> validated

runtimeMemoryTestInputs
  :: Natural
  -> Natural
  -> RuntimeMemory.RawChildSchedule
  -> RuntimeMemory.RuntimeMemoryInputs
runtimeMemoryTestInputs heapCap containerLimit childSchedule =
  RuntimeMemory.RuntimeMemoryInputs
    { RuntimeMemory.runtimeBoundedApplicationState =
        runtimeMemoryTestBytes RuntimeMemory.BoundedApplicationState 10
    , RuntimeMemory.runtimeBoundedPendingPersistenceState =
        runtimeMemoryTestBytes RuntimeMemory.BoundedPendingPersistenceState 20
    , RuntimeMemory.runtimeInHeapTransportDecodeScratch =
        runtimeMemoryTestBytes RuntimeMemory.InHeapTransportDecodeScratch 30
    , RuntimeMemory.runtimeOtherHeapReserve =
        runtimeMemoryTestBytes RuntimeMemory.OtherHeapReserve 40
    , RuntimeMemory.runtimeHeapCap =
        runtimeMemoryTestBytes RuntimeMemory.HeapCap heapCap
    , RuntimeMemory.runtimeNativeNonHeapReserve =
        runtimeMemoryTestBytes RuntimeMemory.NativeNonHeapReserve 15
    , RuntimeMemory.runtimeRawChildSchedule = childSchedule
    , RuntimeMemory.runtimeKernelCgroupReserve =
        runtimeMemoryTestBytes RuntimeMemory.KernelCgroupReserve 10
    , RuntimeMemory.runtimeSafetyMargin =
        runtimeMemoryTestBytes RuntimeMemory.SafetyMargin 5
    , RuntimeMemory.runtimeContainerMemoryLimit =
        runtimeMemoryTestBytes RuntimeMemory.ContainerMemoryLimit containerLimit
    }

defaultGatewayRuntimeMemoryProfile :: Capacity.RuntimeMemoryProfile
defaultGatewayRuntimeMemoryProfile =
  case Capacity.defaultRuntimeMemoryProfiles of
    [profile] -> profile
    profiles -> error ("expected one default runtime-memory profile, got " ++ show profiles)

main :: IO ()
main = mainWithSuite "prodbox-unit" $ do
  parserSuite
  awsSesLifecycleSuite
  awsSesLeaseRoleSuite
  awsSesReadinessSuite
  awsSesSmtpKeySuite
  desiredPresentReconciliationSuite
  fencedCheckpointSuite
  gatewayAuthoritySuite
  gatewayBoundedSuite
  gatewayContinuitySuite
  gatewayProbeSuite
  gatewayRuntimeStabilitySuite
  lifecycleLeaseSuite
  retainedSesPreparationSuite
  retainedSesTargetRecoverySuite
  smtpKeyRepairInterpreterSuite
  targetCommitSmtpSuite
  describe "vault unlock bundle (Sprint 1.36)" $ do
    it "round-trips through encrypt/decrypt with the same password" $ do
      encrypted <- encryptUnlockBundle sampleUnlockBundlePassword sampleUnlockBundle
      case encrypted of
        Left err -> expectationFailure ("encrypt failed: " ++ show err)
        Right envelope ->
          decryptUnlockBundle sampleUnlockBundlePassword envelope
            `shouldBe` Right sampleUnlockBundle
    it "fails authentication when decrypted with the wrong password" $ do
      encrypted <- encryptUnlockBundle sampleUnlockBundlePassword sampleUnlockBundle
      case encrypted of
        Left err -> expectationFailure ("encrypt failed: " ++ show err)
        Right envelope ->
          decryptUnlockBundle "wrong-password" envelope
            `shouldBe` Left UnlockBundleAuthFailed
    it "rejects a tampered ciphertext envelope" $ do
      encrypted <- encryptUnlockBundle sampleUnlockBundlePassword sampleUnlockBundle
      case encrypted of
        Left err -> expectationFailure ("encrypt failed: " ++ show err)
        Right envelope ->
          decryptUnlockBundle sampleUnlockBundlePassword (BS.snoc envelope 0x21)
            `shouldSatisfy` isLeft
    it "writes an opaque envelope that does not leak the root token in plaintext" $ do
      encrypted <- encryptUnlockBundle sampleUnlockBundlePassword sampleUnlockBundle
      case encrypted of
        Left err -> expectationFailure ("encrypt failed: " ++ show err)
        Right envelope ->
          BS.isInfixOf "s.rootsecrettoken" envelope `shouldBe` False
  describe "vault Tier-1 bootstrap bundle (Sprint 7.19)" $ do
    it "pins the fixed, well-known bootstrap object key (not HMAC-opaque)" $ do
      -- The Tier-1 unlock-bundle object MUST sit at a fixed key a sealed Vault
      -- can find pre-unseal (vault_doctrine.md §6.1, §9), never an opaque
      -- objects/<hmac>.enc name.
      bootstrapUnlockBundleKey `shouldBe` "bootstrap/vault-unlock-bundle.v1"
      Text.isPrefixOf "objects/" bootstrapUnlockBundleKey `shouldBe` False
      Text.isSuffixOf ".enc" bootstrapUnlockBundleKey `shouldBe` False
    it "builds an object-store config carrying the durable bucket + STATIC root credential" $ do
      -- The MinIO access credential is a static constant (operator decision
      -- 2026-06-22); security comes from the bundle's password AEAD seal + Vault
      -- Transit, not from a derived access credential.
      let config = bootstrapObjectStoreConfig 39000
      objectStoreBucket config `shouldBe` defaultObjectStoreBucket
      objectStoreEndpoint config `shouldBe` "http://127.0.0.1:39000"
      objectStoreAccessKey config `shouldBe` minioRootUser
      objectStoreSecretKey config `shouldBe` minioRootPassword
    it "round-trips the bundle bytes through an in-memory store at the fixed key" $ do
      -- A pure stand-in for the MinIO put/get path: store the password-AEAD
      -- envelope at the fixed bootstrap key, read it back, and require byte
      -- equality (no live MinIO needed).
      encrypted <- encryptUnlockBundle sampleUnlockBundlePassword sampleUnlockBundle
      case encrypted of
        Left err -> expectationFailure ("encrypt failed: " ++ show err)
        Right envelope -> do
          let store = Map.singleton bootstrapUnlockBundleKey envelope
          Map.lookup bootstrapUnlockBundleKey store `shouldBe` Just envelope
          -- The bytes recovered from the store still decrypt with the password,
          -- exactly like the host-disk path.
          case Map.lookup bootstrapUnlockBundleKey store of
            Just bytes ->
              decryptUnlockBundle sampleUnlockBundlePassword bytes
                `shouldBe` Right sampleUnlockBundle
            Nothing -> expectationFailure "round-trip lost the bundle object"
  describe "vault client (Sprint 1.36)" $ do
    it "decides initialize when Vault is uninitialized" $ do
      bootstrapAction (SealStatus False True 0 0 0) `shouldBe` BootstrapInitialize
    it "decides unseal when Vault is initialized but sealed" $ do
      bootstrapAction (SealStatus True True 3 5 1) `shouldBe` BootstrapUnseal
    it "decides ready when Vault is initialized and unsealed" $ do
      bootstrapAction (SealStatus True False 3 5 3) `shouldBe` BootstrapReady
    it "decodes a sys/seal-status response" $ do
      let decoded =
            eitherDecode
              "{\"type\":\"shamir\",\"initialized\":true,\"sealed\":false,\"t\":3,\"n\":5,\"progress\":0}"
      decoded `shouldBe` Right (SealStatus True False 3 5 0)
    it "renders Vault seal status as the cluster/edge status line" $ do
      renderSealStatus (SealStatus True False 3 5 0)
        `shouldBe` "Vault: initialized=True, sealed=False, unseal-progress=0/3"
    it "decodes a sys/init response and maps it into an unlock bundle" $ do
      let decoded =
            eitherDecode "{\"keys_base64\":[\"k1\",\"k2\"],\"root_token\":\"s.root\"}"
              :: Either String InitResponse
      case decoded of
        Left err -> expectationFailure ("decode failed: " ++ err)
        Right resp -> do
          initResponseKeysBase64 resp `shouldBe` ["k1", "k2"]
          let bundle =
                initResponseToUnlockBundle
                  "c1"
                  (VaultAddress "http://127.0.0.1:8200")
                  "2026-06-12T00:00:00Z"
                  resp
          unlockBundleUnsealKeys bundle `shouldBe` ["k1", "k2"]
          unlockBundleInitialRootToken bundle `shouldBe` "s.root"
    it "encodes root Shamir init with unseal-key shares" $ do
      BL8.unpack (encode defaultInitRequest)
        `shouldBe` "{\"secret_shares\":5,\"secret_threshold\":3}"
    it "decodes transit auto-unseal init responses with recovery keys only" $ do
      let decoded =
            eitherDecode
              "{\"recovery_keys_base64\":[\"rk1\",\"rk2\"],\"root_token\":\"s.child-root\"}"
              :: Either String InitResponse
      fmap initResponseKeysBase64 decoded `shouldBe` Right []
      fmap initResponseRecoveryKeysBase64 decoded `shouldBe` Right ["rk1", "rk2"]
    it "encodes a KV v2 write body under a top-level data key" $ do
      BL8.unpack (encode (KvV2WriteRequest (Map.fromList [("access_key_id", "AKIA")])))
        `shouldBe` "{\"data\":{\"access_key_id\":\"AKIA\"}}"
    it "decodes a KV v2 read response from the nested data.data object" $ do
      let decoded =
            eitherDecode
              "{\"data\":{\"data\":{\"access_key_id\":\"AKIA\"},\"metadata\":{\"version\":1}}}"
              :: Either String KvV2ReadResponse
      fmap kvV2ReadData decoded `shouldBe` Right (Map.fromList [("access_key_id", "AKIA")])
    it "decodes Vault's wrapped sys/mounts listing response" $ do
      let decoded =
            eitherDecode
              "{\"data\":{\"secret/\":{\"type\":\"kv\",\"options\":{\"version\":\"2\"}}},\"wrap_info\":null}"
              :: Either String VaultMountListing
      fmap unVaultMountListing decoded
        `shouldBe` Right
          ( Map.singleton
              "secret"
              (VaultMountInfo "secret" "kv" (Map.singleton "version" "2"))
          )
    it "decodes Vault's wrapped sys/auth listing response" $ do
      let decoded =
            eitherDecode
              "{\"data\":{\"kubernetes/\":{\"type\":\"kubernetes\"}},\"wrap_info\":null}"
              :: Either String VaultAuthListing
      fmap unVaultAuthListing decoded
        `shouldBe` Right
          (Map.singleton "kubernetes" (VaultAuthInfo "kubernetes" "kubernetes"))
    it "encodes a Transit encrypt request with base64 plaintext" $ do
      BL8.unpack (encode (TransitEncryptRequest "cGxhaW50ZXh0"))
        `shouldBe` "{\"plaintext\":\"cGxhaW50ZXh0\"}"
    it "decodes a Transit encrypt response ciphertext token" $ do
      let decoded =
            eitherDecode "{\"data\":{\"ciphertext\":\"vault:v1:abc123\"}}"
              :: Either String TransitEncryptResponse
      fmap transitCiphertext decoded `shouldBe` Right "vault:v1:abc123"
    it "encodes a secret-engine mount request with KV v2 options" $ do
      let decoded =
            eitherDecode (encode (EnableMountRequest "kv" (Map.singleton "version" "2")))
              :: Either String Value
      decoded
        `shouldBe` Right
          ( object
              [ "type" .= ("kv" :: Text.Text)
              , "options" .= object ["version" .= ("2" :: Text.Text)]
              ]
          )
    it "encodes an auth-method request without mount-only options" $ do
      eitherDecode (encode (EnableAuthMethodRequest "kubernetes"))
        `shouldBe` Right (object ["type" .= ("kubernetes" :: Text.Text)] :: Value)
    it "encodes policy, Transit-key, and Kubernetes-role writes" $ do
      eitherDecode (encode (WritePolicyRequest "path \"secret/*\" { capabilities = [\"read\"] }"))
        `shouldBe` Right
          ( object ["policy" .= ("path \"secret/*\" { capabilities = [\"read\"] }" :: Text.Text)]
              :: Value
          )
      eitherDecode (encode (TransitKeyRequest "aes256-gcm96"))
        `shouldBe` Right (object ["type" .= ("aes256-gcm96" :: Text.Text)] :: Value)
      eitherDecode (encode (KubernetesRoleRequest ["sa"] ["ns"] ["policy"] "1h"))
        `shouldBe` Right
          ( object
              [ "bound_service_account_names" .= ["sa" :: Text.Text]
              , "bound_service_account_namespaces" .= ["ns" :: Text.Text]
              , "token_policies" .= ["policy" :: Text.Text]
              , "token_ttl" .= ("1h" :: Text.Text)
              ]
              :: Value
          )
      eitherDecode (encode (KubernetesAuthConfigRequest "https://kubernetes.default.svc:443"))
        `shouldBe` Right
          ( object
              ["kubernetes_host" .= ("https://kubernetes.default.svc:443" :: Text.Text)]
              :: Value
          )
      eitherDecode (encode (KubernetesLoginRequest "websocket-oidc" "jwt-token"))
        `shouldBe` Right
          ( object
              [ "role" .= ("websocket-oidc" :: Text.Text)
              , "jwt" .= ("jwt-token" :: Text.Text)
              ]
              :: Value
          )
      let decodedLogin =
            eitherDecode "{\"auth\":{\"client_token\":\"s.websocket\"}}"
              :: Either String KubernetesLoginResponse
      fmap kubernetesLoginResponseClientToken decodedLogin `shouldBe` Right "s.websocket"
    it "encodes and decodes a scoped token-create request" $ do
      eitherDecode
        (encode (TokenCreateRequest ["prodbox-child-seal-ns-abc"] "24h" True False))
        `shouldBe` Right
          ( object
              [ "policies" .= ["prodbox-child-seal-ns-abc" :: Text.Text]
              , "ttl" .= ("24h" :: Text.Text)
              , "renewable" .= True
              , "no_parent" .= False
              ]
              :: Value
          )
      let decoded =
            eitherDecode "{\"auth\":{\"client_token\":\"s.child-seal\"}}"
              :: Either String TokenCreateResponse
      fmap tokenCreateClientToken decoded `shouldBe` Right "s.child-seal"
    it "encodes and decodes the PKI issue-test-cert wire shape" $ do
      eitherDecode (encode (PkiIssueCertificateRequest "prodbox-vault-test.internal" "1m"))
        `shouldBe` Right
          ( object
              [ "common_name" .= ("prodbox-vault-test.internal" :: Text.Text)
              , "ttl" .= ("1m" :: Text.Text)
              ]
              :: Value
          )
      let decoded =
            eitherDecode "{\"data\":{\"certificate\":\"-----BEGIN CERTIFICATE-----\\n...\"}}"
              :: Either String PkiIssueCertificateResponse
      fmap pkiIssueCertificatePem decoded `shouldBe` Right "-----BEGIN CERTIFICATE-----\n..."
  describe "vault orchestration (Sprint 1.36)" $ do
    it "plans the remaining unseal key submissions for a sealed Vault" $ do
      planUnseal (SealStatus True True 3 5 0) ["k1", "k2", "k3", "k4", "k5"]
        `shouldBe` Right [UnsealStep 1 "k1", UnsealStep 2 "k2", UnsealStep 3 "k3"]
    it "plans no submissions for an already-unsealed Vault" $ do
      planUnseal (SealStatus True False 3 5 3) ["k1", "k2", "k3"] `shouldBe` Right []
    it "fails the plan when the bundle has no unseal keys" $ do
      planUnseal (SealStatus True True 3 5 0) [] `shouldSatisfy` isLeft
    it "fails the plan when the bundle has too few keys for the threshold" $ do
      planUnseal (SealStatus True True 3 5 1) ["only-one"] `shouldSatisfy` isLeft
    it "reads unseal completion when the post-submission Vault is unsealed" $ do
      interpretUnsealProgress (SealStatus True False 3 5 3) (UnsealStep 3 "k3")
        `shouldBe` UnsealCompleted
    it "reads an unseal advance when the share registered" $ do
      interpretUnsealProgress (SealStatus True True 3 5 2) (UnsealStep 2 "k2")
        `shouldBe` UnsealAdvanced 2
    it "reads an unseal stall when progress did not advance" $ do
      interpretUnsealProgress (SealStatus True True 3 5 1) (UnsealStep 2 "k2")
        `shouldBe` UnsealStalled
    it "resolves the cluster-established marker path (Sprint 7.25: bundle is MinIO-only)" $ do
      clusterEstablishedMarkerRelPath `shouldBe` ".data/prodbox/.cluster-established"
  describe "federated Vault lifecycle (Sprint 4.32)" $ do
    it "classifies root and child basics into the expected lifecycle modes" $ do
      vaultLifecycleFromBasics sampleRootBasics
        `shouldBe` Right (RootVaultLifecycle "prodbox-home" "http://127.0.0.1:31820")
      vaultLifecycleFromBasics sampleChildBasics
        `shouldBe` Right (ChildVaultLifecycle "prodbox-child" "http://127.0.0.1:31820" sampleParentRef)
    it "renders child Transit seal Helm args without a local unseal path" $ do
      let lifecycle = ChildVaultLifecycle "prodbox-child" "http://127.0.0.1:31820" sampleParentRef
      vaultLifecycleHelmSealArgs lifecycle
        `shouldBe` [ "--set"
                   , "seal.mode=transit"
                   , "--set"
                   , "seal.transit.address=http://10.0.0.1:8200"
                   , "--set"
                   , "seal.transit.keyName=prodbox-child-seal"
                   ]
    it "fails child auto-unseal closed when the parent is sealed or unreachable" $ do
      parentReadinessDecision (Right (SealStatus True False 3 5 0)) `shouldBe` ParentVaultReady
      parentReadinessDecision (Right (SealStatus True True 3 5 0)) `shouldBe` ParentVaultSealed
      parentReadinessDecision (Left "connection refused")
        `shouldBe` ParentVaultUnreachable "connection refused"
      renderParentReadinessBlock sampleParentRef ParentVaultReady `shouldBe` Nothing
      renderParentReadinessBlock sampleParentRef ParentVaultSealed
        `shouldBe` Just
          "Blocked: parent Vault prodbox-root is sealed; child auto-unseal cannot proceed. Unseal the parent first."
  describe "vault seal hierarchy (Sprint 3.20)" $ do
    it "maps the root Shamir seal mode to Shamir init shares and no HCL seal stanza" $ do
      let sealMode = VaultSealRootShamir defaultRootShamirSealConfig
      initRequestForSealMode sealMode `shouldBe` defaultInitRequest
      renderVaultSealHcl sealMode `shouldBe` ""
    it "maps a child transit seal to recovery-key init shares" $ do
      let sealConfig =
            defaultTransitSealConfig
              (VaultAddress "https://vault.parent.example:8200")
              "prodbox-child-abcdef"
      encode (initRequestForSealMode (VaultSealChildTransit sealConfig))
        `shouldBe` encode
          ( InitRequest
              { initRequestSecretShares = Nothing
              , initRequestSecretThreshold = Nothing
              , initRequestRecoveryShares = Just 5
              , initRequestRecoveryThreshold = Just 3
              }
          )
    it "renders a child transit seal stanza without embedding the transit token" $ do
      let sealConfig =
            defaultTransitSealConfig
              (VaultAddress "https://vault.parent.example:8200")
              "prodbox-child-abcdef"
          rendered = Text.unpack (renderVaultSealHcl (VaultSealChildTransit sealConfig))
      rendered `shouldContain` "seal \"transit\""
      rendered `shouldContain` "address = \"https://vault.parent.example:8200\""
      rendered `shouldContain` "key_name = \"prodbox-child-abcdef\""
      rendered `shouldContain` "mount_path = \"transit/\""
      rendered `shouldNotContain` "token"
    it "stores child auto-unseal recovery material as parent-owned Vault KV fields" $ do
      let response =
            InitResponse
              { initResponseKeysBase64 = []
              , initResponseRecoveryKeysBase64 = ["rk1", "rk2", "rk3"]
              , initResponseRootToken = "s.child-root"
              }
          custody =
            childInitCustodyFromInitResponse
              "child-prod"
              "prodbox-child-abcdef"
              response
          fields = childInitCustodyVaultFields custody
      childInitRecoveryKeysBase64 custody `shouldBe` ["rk1", "rk2", "rk3"]
      childInitTransitKey custody `shouldBe` "prodbox-child-abcdef"
      childInitRootToken custody `shouldBe` "s.child-root"
      Map.keys fields `shouldBe` ["payload_json"]
      Map.lookup "payload_json" fields `shouldSatisfy` maybe False (Text.isInfixOf "s.child-root")
    it "assembles child metadata and init custody from one init response" $ do
      let response =
            InitResponse
              { initResponseKeysBase64 = []
              , initResponseRecoveryKeysBase64 = ["rk1"]
              , initResponseRootToken = "s.child-root"
              }
          custody =
            childSealCustodyFromInitResponse
              "root"
              "child-prod"
              "https://vault.child-prod.example"
              "ns-opaque"
              "prodbox-child-abcdef"
              response
      childMetadataParentClusterId (childSealCustodyMetadata custody) `shouldBe` "root"
      childMetadataVaultNamespace (childSealCustodyMetadata custody) `shouldBe` "ns-opaque"
      childInitRecoveryKeysBase64 (childSealCustodyInit custody) `shouldBe` ["rk1"]
    it "renders a per-child Transit seal token policy scoped to one key" $ do
      let policy = Text.unpack (transitSealPolicyDocument "prodbox-child-abcdef")
      policy `shouldContain` "path \"transit/encrypt/prodbox-child-abcdef\""
      policy `shouldContain` "path \"transit/decrypt/prodbox-child-abcdef\""
      policy `shouldNotContain` "prodbox-child-*"
  describe "vault reconcile (Sprint 1.36)" $ do
    it "default plan covers the base mounts, auth method, and Transit key domains" $ do
      map vaultMountSpecPath (vaultReconcileMounts defaultVaultReconcilePlan)
        `shouldBe` ["secret", "transit", "pki"]
      map vaultAuthSpecPath (vaultReconcileAuthMethods defaultVaultReconcilePlan)
        `shouldBe` ["kubernetes"]
      map
        ( \spec ->
            ( vaultKubernetesAuthConfigSpecPath spec
            , vaultKubernetesAuthConfigSpecHost spec
            )
        )
        (vaultReconcileKubernetesAuthConfigs defaultVaultReconcilePlan)
        `shouldBe` [("kubernetes", "https://kubernetes.default.svc:443")]
      map vaultTransitKeySpecName (vaultReconcileTransitKeys defaultVaultReconcilePlan)
        `shouldBe` [ "prodbox-active-config"
                   , "prodbox-gateway-state"
                   , "prodbox-pulumi-state"
                   , "prodbox-minio-envelope"
                   , "prodbox-downstream-cluster-config"
                   ]
    it "renders chart-secret Vault inventory as least-privilege KV v2 policy documents" $ do
      case VaultInventory.vaultSecretConsumerByName "keycloak-runtime" of
        Nothing -> expectationFailure "expected keycloak-runtime chart secret consumer"
        Just consumer -> do
          VaultInventory.vaultSecretConsumerKvApiPaths consumer
            `shouldBe` [ "secret/data/keycloak/admin"
                       , "secret/data/keycloak/keycloak-postgres/patroni/app"
                       , "secret/data/keycloak/oidc/vscode"
                       , "secret/data/keycloak/oidc/prodbox-api"
                       , "secret/data/keycloak/oidc/prodbox-websocket"
                       , "secret/data/keycloak/oidc/demo-user"
                       , "secret/data/keycloak/smtp"
                       ]
          Text.unpack (VaultInventory.vaultSecretConsumerPolicyDocument consumer)
            `shouldContain` "path \"secret/data/keycloak/admin\""
          Text.unpack (VaultInventory.vaultSecretConsumerPolicyDocument consumer)
            `shouldNotContain` "secret/metadata/"
      case VaultInventory.vaultSecretConsumerByName "gateway-event-keys" of
        Nothing -> expectationFailure "expected gateway-event-keys chart secret consumer"
        Just consumer ->
          VaultInventory.vaultSecretConsumerKvApiPaths consumer
            `shouldSatisfy` \paths ->
              all
                (`elem` paths)
                [ "secret/data/gateway/gateway/node-a/event-key"
                , "secret/data/gateway/gateway/aws"
                , "secret/data/gateway/gateway/minio"
                ]
    it "covers every chart-secret consumer path with a seed object spec" $ do
      let objectPaths =
            Set.fromList (map VaultInventory.vaultSecretObjectPath VaultInventory.chartVaultSecretObjects)
          consumerPaths =
            Set.fromList
              (concatMap VaultInventory.vaultSecretConsumerKvPaths VaultInventory.chartVaultSecretConsumers)
      consumerPaths `Set.isSubsetOf` objectPaths `shouldBe` True
      case filter
        ((== VaultInventory.VaultSecretPath "secret" "keycloak/admin") . VaultInventory.vaultSecretObjectPath)
        VaultInventory.chartVaultSecretObjects of
        [spec] ->
          VaultInventory.vaultSecretObjectFieldNames spec `shouldBe` ["password"]
        _ -> expectationFailure "expected one keycloak/admin seed object"
    it "keeps externally-owned Vault KV objects out of the automatic seed set" $ do
      let managedPaths =
            Set.fromList
              (map VaultInventory.vaultSecretObjectPath VaultInventory.chartVaultManagedSecretObjects)
      managedPaths
        `shouldSatisfy` Set.member (VaultInventory.VaultSecretPath "secret" "keycloak/admin")
      managedPaths
        `shouldSatisfy` Set.member (VaultInventory.VaultSecretPath "secret" "gateway/gateway/minio")
      managedPaths
        `shouldSatisfy` (not . Set.member (VaultInventory.VaultSecretPath "secret" "keycloak/smtp"))
      managedPaths
        `shouldSatisfy` (not . Set.member (VaultInventory.VaultSecretPath "secret" "gateway/gateway/aws"))
    it "mints a missing Vault KV object once from the seed inventory" $ do
      writesRef <- newIORef []
      let path = VaultInventory.VaultSecretPath "secret" "keycloak/admin"
          spec =
            VaultInventory.VaultSecretObjectSpec
              path
              [ VaultInventory.VaultSecretFieldSpec
                  "password"
                  (VaultInventory.VaultSecretGenerated "keycloak-admin-password")
              ]
          ops =
            VaultInventory.VaultSecretBootstrapOps
              { VaultInventory.vaultSecretBootstrapRead =
                  const (pure (Left (Prodbox.Http.Client.HttpStatus 404 "missing")))
              , VaultInventory.vaultSecretBootstrapWrite = \candidate fields -> do
                  modifyIORef' writesRef (++ [(candidate, fields)])
                  pure (Right ())
              , VaultInventory.vaultSecretBootstrapGenerate =
                  \field -> pure ("generated-" <> VaultInventory.vaultSecretFieldName field)
              }
      result <-
        VaultInventory.runVaultSecretBootstrapWith ops [spec]
      result
        `shouldBe` Right
          [ VaultInventory.VaultSecretBootstrapStep
              path
              VaultInventory.VaultSecretBootstrapCreated
              ["password"]
          ]
      readIORef writesRef
        `shouldReturn` [(path, Map.singleton "password" "generated-password")]
    it "generates MinIO command passwords that cannot be parsed as mc flags" $ do
      value <-
        VaultInventory.generateVaultSecretFieldValue
          ( VaultInventory.VaultSecretFieldSpec
              "rootPassword"
              (VaultInventory.VaultSecretGenerated "minio-root-password")
          )
      isMinioSecretKeyArgumentSafe (Text.unpack value) `shouldBe` True
      isMinioSecretKeyArgumentSafe "-not-safe" `shouldBe` False
      isMinioSecretKeyArgumentSafe "has space" `shouldBe` False
    it "replaces unsafe existing MinIO command passwords during Vault bootstrap" $ do
      writesRef <- newIORef []
      let path = VaultInventory.VaultSecretPath "secret" "minio/root"
          spec =
            VaultInventory.VaultSecretObjectSpec
              path
              [ VaultInventory.VaultSecretFieldSpec
                  "rootUser"
                  (VaultInventory.VaultSecretStatic "prodbox-minio-root")
              , VaultInventory.VaultSecretFieldSpec
                  "rootPassword"
                  (VaultInventory.VaultSecretGenerated "minio-root-password")
              ]
          ops =
            VaultInventory.VaultSecretBootstrapOps
              { VaultInventory.vaultSecretBootstrapRead =
                  const
                    ( pure
                        ( Right
                            ( Map.fromList
                                [ ("rootUser", "prodbox-minio-root")
                                , ("rootPassword", "-unsafe")
                                ]
                            )
                        )
                    )
              , VaultInventory.vaultSecretBootstrapWrite = \candidate fields -> do
                  modifyIORef' writesRef (++ [(candidate, fields)])
                  pure (Right ())
              , VaultInventory.vaultSecretBootstrapGenerate =
                  \field -> pure ("SafeGenerated" <> VaultInventory.vaultSecretFieldName field)
              }
      result <-
        VaultInventory.runVaultSecretBootstrapWith ops [spec]
      result
        `shouldBe` Right
          [ VaultInventory.VaultSecretBootstrapStep
              path
              VaultInventory.VaultSecretBootstrapUpdatedMissingFields
              ["rootPassword"]
          ]
      readIORef writesRef
        `shouldReturn` [
                         ( path
                         , Map.fromList
                             [ ("rootUser", "prodbox-minio-root")
                             , ("rootPassword", "SafeGeneratedrootPassword")
                             ]
                         )
                       ]
    it "declares secret/minio/root.rootPassword as a STATIC field (not generated/derived)" $ do
      -- Operator decision 2026-06-22: the MinIO access credential is STATIC, not
      -- password-derived. The rootPassword field must be the static constant so a
      -- retained MinIO disk always matches Vault across rebuilds, and so the
      -- credential is one MinIO actually accepts.
      let isMinioRoot obj =
            VaultInventory.vaultSecretObjectPath obj
              == VaultInventory.VaultSecretPath "secret" "minio/root"
          rootPasswordSources obj =
            [ VaultInventory.vaultSecretFieldSource f
            | f <- VaultInventory.vaultSecretObjectFields obj
            , VaultInventory.vaultSecretFieldName f == "rootPassword"
            ]
      case filter isMinioRoot VaultInventory.chartVaultManagedSecretObjects of
        [obj] ->
          rootPasswordSources obj
            `shouldBe` [VaultInventory.VaultSecretStatic (Text.pack minioRootPassword)]
        _ -> expectationFailure "expected exactly one secret/minio/root managed object"
    it "preserves existing Vault KV fields and writes only missing generated fields" $ do
      writesRef <- newIORef []
      let path = VaultInventory.VaultSecretPath "secret" "keycloak/keycloak-postgres/patroni/app"
          spec =
            VaultInventory.VaultSecretObjectSpec
              path
              [ VaultInventory.VaultSecretFieldSpec
                  "username"
                  (VaultInventory.VaultSecretStatic "keycloak")
              , VaultInventory.VaultSecretFieldSpec
                  "password"
                  (VaultInventory.VaultSecretGenerated "patroni-password")
              ]
          ops =
            VaultInventory.VaultSecretBootstrapOps
              { VaultInventory.vaultSecretBootstrapRead =
                  const (pure (Right (Map.singleton "username" "keycloak")))
              , VaultInventory.vaultSecretBootstrapWrite = \candidate fields -> do
                  modifyIORef' writesRef (++ [(candidate, fields)])
                  pure (Right ())
              , VaultInventory.vaultSecretBootstrapGenerate =
                  \field -> pure ("generated-" <> VaultInventory.vaultSecretFieldName field)
              }
      result <-
        VaultInventory.runVaultSecretBootstrapWith ops [spec]
      result
        `shouldBe` Right
          [ VaultInventory.VaultSecretBootstrapStep
              path
              VaultInventory.VaultSecretBootstrapUpdatedMissingFields
              ["password"]
          ]
      readIORef writesRef
        `shouldReturn` [
                         ( path
                         , Map.fromList
                             [ ("username", "keycloak")
                             , ("password", "generated-password")
                             ]
                         )
                       ]
    it "refuses to synthesize externally-owned Vault KV fields" $ do
      writesRef <- newIORef []
      let path = VaultInventory.VaultSecretPath "secret" "keycloak/smtp"
          spec =
            VaultInventory.VaultSecretObjectSpec
              path
              [VaultInventory.VaultSecretFieldSpec "host" VaultInventory.VaultSecretExternal]
          ops =
            VaultInventory.VaultSecretBootstrapOps
              { VaultInventory.vaultSecretBootstrapRead = const (pure (Right Map.empty))
              , VaultInventory.vaultSecretBootstrapWrite = \candidate fields -> do
                  modifyIORef' writesRef (++ [(candidate, fields)])
                  pure (Right ())
              , VaultInventory.vaultSecretBootstrapGenerate = const (pure "generated")
              }
      VaultInventory.runVaultSecretBootstrapWith ops [spec]
        `shouldReturn` Left (VaultInventory.VaultSecretBootstrapExternalFieldMissing path "host")
      readIORef writesRef `shouldReturn` []
    it "includes chart-secret policies and Kubernetes roles in the default Vault reconcile plan" $ do
      map vaultPolicySpecName (vaultReconcilePolicies defaultVaultReconcilePlan)
        `shouldSatisfy` \names ->
          all
            (`elem` names)
            [ "keycloak"
            , "vscode-keycloak"
            , "keycloak-smtp"
            , "keycloak-keycloak-postgres-pg"
            , "vscode-keycloak-postgres-pg"
            , "vscode-oidc"
            , "api-oidc"
            , "websocket-oidc"
            , "gateway-gateway"
            , "gateway-minio-bootstrap"
            , "minio"
            ]
      case filter
        ((== "prodbox-federation-custody") . vaultPolicySpecName)
        (vaultReconcilePolicies defaultVaultReconcilePlan) of
        [policy] -> do
          Text.unpack (vaultPolicySpecDocument policy)
            `shouldContain` "path \"transit/encrypt/prodbox-child-*\""
          Text.unpack (vaultPolicySpecDocument policy)
            `shouldContain` "path \"transit/decrypt/prodbox-child-*\""
        _ -> expectationFailure "expected one prodbox-federation-custody Vault policy"
      case filter
        ((== "keycloak-smtp") . vaultKubernetesRoleSpecName)
        (vaultReconcileKubernetesRoles defaultVaultReconcilePlan) of
        [role] -> do
          vaultKubernetesRoleSpecServiceAccounts role `shouldBe` ["keycloak"]
          vaultKubernetesRoleSpecNamespaces role `shouldBe` ["keycloak", "vscode"]
          vaultKubernetesRoleSpecPolicies role `shouldBe` ["keycloak-smtp"]
        _ -> expectationFailure "expected one keycloak-smtp Vault Kubernetes role"
      case filter
        ((== "keycloak-keycloak-postgres-pg") . vaultKubernetesRoleSpecName)
        (vaultReconcileKubernetesRoles defaultVaultReconcilePlan) of
        [role] -> do
          vaultKubernetesRoleSpecServiceAccounts role `shouldBe` ["prodbox-keycloak-pg"]
          vaultKubernetesRoleSpecNamespaces role `shouldBe` ["keycloak"]
          vaultKubernetesRoleSpecPolicies role `shouldBe` ["keycloak-keycloak-postgres-pg"]
        _ -> expectationFailure "expected one keycloak-keycloak-postgres-pg Vault Kubernetes role"
      case filter
        ((== "vscode-oidc") . vaultKubernetesRoleSpecName)
        (vaultReconcileKubernetesRoles defaultVaultReconcilePlan) of
        [role] -> do
          vaultKubernetesRoleSpecServiceAccounts role `shouldBe` ["vscode-oidc-secret-materializer"]
          vaultKubernetesRoleSpecNamespaces role `shouldBe` ["vscode"]
          vaultKubernetesRoleSpecPolicies role `shouldBe` ["vscode-oidc"]
        _ -> expectationFailure "expected one vscode-oidc Vault Kubernetes role"
      case filter
        ((== "gateway-minio-bootstrap") . vaultKubernetesRoleSpecName)
        (vaultReconcileKubernetesRoles defaultVaultReconcilePlan) of
        [role] -> do
          vaultKubernetesRoleSpecServiceAccounts role `shouldBe` ["minio"]
          vaultKubernetesRoleSpecNamespaces role `shouldBe` ["prodbox"]
          vaultKubernetesRoleSpecPolicies role `shouldBe` ["gateway-minio-bootstrap"]
        _ -> expectationFailure "expected one gateway-minio-bootstrap Vault Kubernetes role"
    it "includes automatically managed chart-secret seed objects in the default Vault reconcile plan" $ do
      map VaultInventory.vaultSecretObjectPath (vaultReconcileSecretObjects defaultVaultReconcilePlan)
        `shouldSatisfy` \paths ->
          all
            (`elem` paths)
            [ VaultInventory.VaultSecretPath "secret" "keycloak/admin"
            , VaultInventory.VaultSecretPath "secret" "keycloak/keycloak-postgres/patroni/app"
            , VaultInventory.VaultSecretPath "secret" "gateway/gateway/minio"
            , VaultInventory.VaultSecretPath "secret" "minio/root"
            ]
      map VaultInventory.vaultSecretObjectPath (vaultReconcileSecretObjects defaultVaultReconcilePlan)
        `shouldSatisfy` notElem (VaultInventory.VaultSecretPath "secret" "keycloak/smtp")
      map VaultInventory.vaultSecretObjectPath (vaultReconcileSecretObjects defaultVaultReconcilePlan)
        `shouldSatisfy` notElem (VaultInventory.VaultSecretPath "secret" "gateway/gateway/aws")
    it "accepts the canonical gateway AWS Vault SecretRef declaration" $ do
      let refs =
            AwsCredentialsRef
              { awsCredentialAccessKeyId =
                  SecretRefVault (VaultSecretRef "secret" "gateway/gateway/aws" "access_key_id")
              , awsCredentialSecretAccessKey =
                  SecretRefVault (VaultSecretRef "secret" "gateway/gateway/aws" "secret_access_key")
              , awsCredentialSessionToken = Nothing
              , awsCredentialRegion = "us-east-1"
              }
      gatewayAwsVaultFields refs `shouldBe` Right ()
    it "refuses non-canonical gateway AWS Vault SecretRef declarations" $ do
      let refs =
            AwsCredentialsRef
              { awsCredentialAccessKeyId =
                  SecretRefVault (VaultSecretRef "secret" "gateway/gateway/aws" "access_key_id")
              , awsCredentialSecretAccessKey =
                  SecretRefVault (VaultSecretRef "secret" "wrong/path" "secret_access_key")
              , awsCredentialSessionToken = Nothing
              , awsCredentialRegion = "us-east-1"
              }
      gatewayAwsVaultFields refs
        `shouldBe` Left
          "aws.secret_access_key must reference SecretRef.Vault secret/gateway/gateway/aws#secret_access_key"
    it
      "creates absent mounts, auth methods, Transit keys, and secret objects, then writes policies and roles"
      $ do
        eventsRef <- newIORef []
        let record event =
              modifyIORef' eventsRef (++ [event])
            secretPath = VaultInventory.VaultSecretPath "secret" "keycloak/admin"
            plan =
              VaultReconcilePlan
                { vaultReconcileMounts =
                    [VaultMountSpec "secret" "kv" (Map.singleton "version" "2")]
                , vaultReconcileAuthMethods =
                    [VaultAuthSpec "kubernetes" "kubernetes"]
                , vaultReconcileKubernetesAuthConfigs =
                    [VaultKubernetesAuthConfigSpec "kubernetes" "https://kubernetes.default.svc:443"]
                , vaultReconcileTransitKeys =
                    [VaultTransitKeySpec "prodbox-minio-envelope" "aes256-gcm96"]
                , vaultReconcilePolicies =
                    [VaultPolicySpec "prodbox-gateway" "path \"secret/*\" { capabilities = [\"read\"] }"]
                , vaultReconcileKubernetesRoles =
                    [VaultKubernetesRoleSpec "prodbox-gateway-daemon" ["sa"] ["ns"] ["prodbox-gateway"] "1h"]
                , vaultReconcileSecretObjects =
                    [ VaultInventory.VaultSecretObjectSpec
                        secretPath
                        [ VaultInventory.VaultSecretFieldSpec
                            "password"
                            (VaultInventory.VaultSecretGenerated "keycloak-admin-password")
                        ]
                    ]
                }
            ops =
              VaultReconcileOps
                { vaultOpsListMounts = pure (Right Map.empty)
                , vaultOpsEnableMount = \spec -> do
                    record ("mount:" <> vaultMountSpecPath spec)
                    pure (Right ())
                , vaultOpsListAuthMethods = pure (Right Map.empty)
                , vaultOpsEnableAuthMethod = \spec -> do
                    record ("auth:" <> vaultAuthSpecPath spec)
                    pure (Right ())
                , vaultOpsWriteKubernetesAuthConfig = \spec -> do
                    record ("auth-config:" <> vaultKubernetesAuthConfigSpecPath spec)
                    vaultKubernetesAuthConfigSpecHost spec
                      `shouldBe` "https://kubernetes.default.svc:443"
                    pure (Right ())
                , vaultOpsReadTransitKey =
                    const (pure (Left (Prodbox.Http.Client.HttpStatus 404 "missing")))
                , vaultOpsCreateTransitKey = \spec -> do
                    record ("transit:" <> vaultTransitKeySpecName spec)
                    pure (Right ())
                , vaultOpsWritePolicy = \spec -> do
                    record ("policy:" <> vaultPolicySpecName spec)
                    pure (Right ())
                , vaultOpsWriteKubernetesRole = \spec -> do
                    record ("role:" <> vaultKubernetesRoleSpecName spec)
                    pure (Right ())
                , vaultOpsSecretBootstrap =
                    VaultInventory.VaultSecretBootstrapOps
                      { VaultInventory.vaultSecretBootstrapRead =
                          const (pure (Left (Prodbox.Http.Client.HttpStatus 404 "missing")))
                      , VaultInventory.vaultSecretBootstrapWrite = \path fields -> do
                          record ("secret:" <> VaultInventory.vaultSecretPathName path)
                          fields `shouldBe` Map.singleton "password" "generated-password"
                          pure (Right ())
                      , VaultInventory.vaultSecretBootstrapGenerate =
                          \field -> pure ("generated-" <> VaultInventory.vaultSecretFieldName field)
                      }
                }
        result <- runVaultReconcileWith ops plan
        result
          `shouldBe` Right
            [ VaultReconcileStep VaultReconcileMount "secret" VaultReconcileCreated
            , VaultReconcileStep VaultReconcileAuthMethod "kubernetes" VaultReconcileCreated
            , VaultReconcileStep VaultReconcileKubernetesAuthConfig "kubernetes" VaultReconcileWritten
            , VaultReconcileStep VaultReconcileTransitKey "prodbox-minio-envelope" VaultReconcileCreated
            , VaultReconcileStep VaultReconcilePolicy "prodbox-gateway" VaultReconcileWritten
            , VaultReconcileStep VaultReconcileKubernetesRole "prodbox-gateway-daemon" VaultReconcileWritten
            , VaultReconcileStep VaultReconcileSecretObject "secret/keycloak/admin" VaultReconcileCreated
            ]
        readIORef eventsRef
          `shouldReturn` [ "mount:secret"
                         , "auth:kubernetes"
                         , "auth-config:kubernetes"
                         , "transit:prodbox-minio-envelope"
                         , "policy:prodbox-gateway"
                         , "role:prodbox-gateway-daemon"
                         , "secret:secret/keycloak/admin"
                         ]
    it "fails loud when an existing mount has the wrong type" $ do
      let plan =
            VaultReconcilePlan
              { vaultReconcileMounts =
                  [VaultMountSpec "secret" "kv" (Map.singleton "version" "2")]
              , vaultReconcileAuthMethods = []
              , vaultReconcileKubernetesAuthConfigs = []
              , vaultReconcileTransitKeys = []
              , vaultReconcilePolicies = []
              , vaultReconcileKubernetesRoles = []
              , vaultReconcileSecretObjects = []
              }
          ops =
            VaultReconcileOps
              { vaultOpsListMounts =
                  pure
                    ( Right
                        (Map.singleton "secret" (VaultMountInfo "secret" "generic" Map.empty))
                    )
              , vaultOpsEnableMount = const (pure (Right ()))
              , vaultOpsListAuthMethods = pure (Right Map.empty)
              , vaultOpsEnableAuthMethod = const (pure (Right ()))
              , vaultOpsWriteKubernetesAuthConfig = const (pure (Right ()))
              , vaultOpsReadTransitKey =
                  const (pure (Left (Prodbox.Http.Client.HttpStatus 404 "missing")))
              , vaultOpsCreateTransitKey = const (pure (Right ()))
              , vaultOpsWritePolicy = const (pure (Right ()))
              , vaultOpsWriteKubernetesRole = const (pure (Right ()))
              , vaultOpsSecretBootstrap =
                  VaultInventory.VaultSecretBootstrapOps
                    { VaultInventory.vaultSecretBootstrapRead = const (pure (Right Map.empty))
                    , VaultInventory.vaultSecretBootstrapWrite = \_ _ -> pure (Right ())
                    , VaultInventory.vaultSecretBootstrapGenerate = const (pure "generated")
                    }
              }
      runVaultReconcileWith ops plan
        `shouldReturn` Left (VaultReconcileMountTypeMismatch "secret" "kv" "generic")
  describe "vault gate (Sprint 1.37)" $ do
    it "allows Pulumi when Vault is initialized and unsealed" $ do
      vaultGateDecision (Right (SealStatus True False 3 5 3)) `shouldBe` VaultGateAllow
    it "blocks Pulumi when Vault is sealed" $ do
      vaultGateDecision (Right (SealStatus True True 3 5 0)) `shouldBe` VaultGateBlockSealed
    it "blocks Pulumi when Vault is uninitialized" $ do
      vaultGateDecision (Right (SealStatus False True 0 0 0))
        `shouldBe` VaultGateBlockUninitialized
    it "renders a fail-closed message that starts no Pulumi operation" $ do
      case renderVaultGateBlock (vaultGateDecision (Right (SealStatus True True 3 5 0))) of
        Nothing -> expectationFailure "expected a fail-closed block message"
        Just msg -> do
          msg `shouldContain` "Blocked"
          msg `shouldContain` "No preview/update/destroy was started"
          msg `shouldContain` "prodbox vault unseal"
    it "folds an unsealed Vault into a proceed outcome" $ do
      vaultGateOutcome (Right (SealStatus True False 3 5 3)) `shouldBe` VaultGateProceed
    it "folds a sealed Vault into a refusal that starts no Pulumi op" $ do
      case vaultGateOutcome (Right (SealStatus True True 3 5 0)) of
        VaultGateProceed -> expectationFailure "expected a refusal for a sealed Vault"
        VaultGateRefuse message -> do
          message `shouldContain` "Vault is sealed."
          message `shouldContain` "No preview/update/destroy was started"
    it "folds an uninitialized Vault into a refusal" $ do
      case vaultGateOutcome (Right (SealStatus False True 0 0 0)) of
        VaultGateProceed -> expectationFailure "expected a refusal for an uninitialized Vault"
        VaultGateRefuse message -> message `shouldContain` "Vault is not initialized."
    it "folds an unreachable Vault into a refusal" $ do
      case vaultGateOutcome (Left (Prodbox.Http.Client.HttpConnectionFailure "connection refused")) of
        VaultGateProceed -> expectationFailure "expected a refusal for an unreachable Vault"
        VaultGateRefuse message -> message `shouldContain` "Vault is unreachable"
  describe "Pulumi sealed-Vault gate wiring (Sprint 1.37)" $ do
    it "does not probe Vault for a dry-run Pulumi command" $ do
      gateCalls <- newIORef (0 :: Int)
      exitCode <-
        runPulumiCommandWithGate
          (modifyIORef' gateCalls (+ 1) >> pure (VaultGateRefuse "blocked"))
          "/repo"
          (PulumiEksResources (PlanOptions True Nothing))
      exitCode `shouldBe` ExitSuccess
      readIORef gateCalls `shouldReturn` 0
    it "refuses a real Pulumi apply before any stack action starts when Vault is blocked" $ do
      exitCode <-
        runPulumiCommandWithGate
          (pure (VaultGateRefuse "Blocked: Vault is sealed. No preview/update/destroy was started."))
          "/repo"
          (PulumiEksResources (PlanOptions False Nothing))
      exitCode `shouldBe` ExitFailure 1
  describe "Pulumi encrypted backend interposition (Sprint 7.14)" $ do
    it "refuses before loading or hydrating a checkpoint when Vault is sealed" $ do
      callsRef <- newIORef ([] :: [String])
      let stackRef = PulumiStackRef "aws-eks" "aws-eks"
          hooks =
            EncryptedBackendHooks
              { encryptedBackendGate =
                  pure (VaultGateRefuse "Blocked: Vault is sealed. No preview/update/destroy was started.")
              , encryptedBackendLoad = \_ -> modifyIORef' callsRef (++ ["load"]) >> pure (Right Nothing)
              , encryptedBackendLoadLegacy = \_ ->
                  modifyIORef' callsRef (++ ["load-legacy"]) >> pure (Right Nothing)
              , encryptedBackendStore = \_ _ -> modifyIORef' callsRef (++ ["store"]) >> pure (Right ())
              , encryptedBackendDelete = \_ -> modifyIORef' callsRef (++ ["delete"]) >> pure (Right ())
              , encryptedBackendDeleteLegacy = \_ ->
                  modifyIORef' callsRef (++ ["delete-legacy"]) >> pure (Right ())
              , encryptedBackendWithScratch = \_ _ ->
                  modifyIORef' callsRef (++ ["scratch"]) >> pure (Right ())
              }
      result <-
        withDecryptedStackWith
          hooks
          stackRef
          (\_ -> modifyIORef' callsRef (++ ["action"]) >> pure (Right ()))
      result
        `shouldBe` Left
          (EncryptedBackendVaultRefused "Blocked: Vault is sealed. No preview/update/destroy was started.")
      readIORef callsRef `shouldReturn` []
    it "uses a file backend env, strips raw MinIO/S3 creds, and sets an EMPTY config passphrase" $ do
      let scratch =
            PulumiScratch
              { pulumiScratchRoot = "/dev/shm/prodbox-pulumi-test"
              , pulumiScratchBackendUrl = "file:///dev/shm/prodbox-pulumi-test"
              , pulumiScratchCheckpointPath =
                  "/dev/shm/prodbox-pulumi-test/.pulumi/stacks/aws-eks/aws-eks.json"
              }
          environment =
            fileBackendEnvironment
              scratch
              [ ("AWS_ACCESS_KEY_ID", "minio-root")
              , ("AWS_SECRET_ACCESS_KEY", "minio-secret")
              , ("AWS_REGION", "us-east-1")
              , ("PULUMI_CONFIG_PASSPHRASE", "")
              , ("PRODBOX_PULUMI_AWS_ACCESS_KEY_ID", "provider-key")
              , ("PATH", "/bin")
              ]
      lookup "PULUMI_BACKEND_URL" environment `shouldBe` Just "file:///dev/shm/prodbox-pulumi-test"
      lookup "AWS_ACCESS_KEY_ID" environment `shouldBe` Nothing
      lookup "AWS_SECRET_ACCESS_KEY" environment `shouldBe` Nothing
      -- The scratch backend must carry an EMPTY config passphrase (not a
      -- stripped one) so a stack config bearing an `encryptionsalt` (today only
      -- aws-ses) can initialize its passphrase secrets manager; any inherited
      -- value is stripped first, then re-set to "". Stacks without a salt ignore
      -- it. (Sprint 7.23: fixes `get stack secrets manager: passphrase must be set`.)
      lookup "PULUMI_CONFIG_PASSPHRASE" environment `shouldBe` Just ""
      lookup "PRODBOX_PULUMI_AWS_ACCESS_KEY_ID" environment `shouldBe` Just "provider-key"
      lookup "PATH" environment `shouldBe` Just "/bin"
    it "loads Vault-backed AWS provider credentials without a raw config fallback" $ do
      let vaultCredentials =
            Credentials
              { access_key_id = "vault-access"
              , secret_access_key = "vault-secret"
              , session_token = Just "vault-session"
              , region = "us-west-2"
              }
      result <-
        AwsProviderCredentials.loadPulumiProviderCredentialsWith
          (pure (Right vaultCredentials))
      result `shouldBe` Right vaultCredentials
    it "fails instead of falling back when the Vault provider secret is absent" $ do
      result <-
        AwsProviderCredentials.loadPulumiProviderCredentialsWith
          (pure (Left "secret/gateway/gateway/aws is missing"))
      result `shouldBe` Left "secret/gateway/gateway/aws is missing"
    it "does not fall back when Vault provider credential resolution fails" $ do
      result <-
        AwsProviderCredentials.loadPulumiProviderCredentialsWith
          (pure (Left "Vault provider secret is invalid"))
      result `shouldBe` Left "Vault provider secret is invalid"
    it "uses the Pulumi project name in the scratch checkpoint path" $ do
      let expected =
            "/dev/shm/prodbox-pulumi-test"
              </> ".pulumi"
              </> "stacks"
              </> "prodbox-aws-test"
              </> "aws-test.json"
      stackCheckpointPath
        "/dev/shm/prodbox-pulumi-test"
        (PulumiStackRef "prodbox-aws-test" "aws-test")
        `shouldBe` expected
    it "derives encrypted stack listings from checkpoint presence" $ do
      StackOutputs.stackListFromCheckpointPresence
        (StackOutputs.StackName "aws-test")
        False
        `shouldBe` []
      StackOutputs.stackListFromCheckpointPresence
        (StackOutputs.StackName "aws-test")
        True
        `shouldBe` [ StackOutputs.StackListEntry
                       { StackOutputs.stackListEntryName = "aws-test"
                       , StackOutputs.stackListEntryCurrent = True
                       }
                   ]
    it "hydrates, stores the updated checkpoint, and removes scratch state" $ do
      storedRef <- newIORef ([] :: [(PulumiStackRef, BS.ByteString)])
      deletedRef <- newIORef ([] :: [PulumiStackRef])
      scratchRootRef <- newIORef Nothing
      let stackRef = PulumiStackRef "aws-test" "aws-test"
          hooks =
            EncryptedBackendHooks
              { encryptedBackendGate = pure VaultGateProceed
              , -- A realistic file-backend on-disk checkpoint (valid JSON,
                -- `checkpoint` wrapper) so the Sprint 7.23 hydrate-usability
                -- check accepts it for raw hydration.
                encryptedBackendLoad = const (pure (Right (Just "{\"version\":3,\"checkpoint\":{}}")))
              , encryptedBackendLoadLegacy = const (pure (Right Nothing))
              , encryptedBackendStore = \ref bytes ->
                  modifyIORef' storedRef (++ [(ref, bytes)]) >> pure (Right ())
              , encryptedBackendDelete = \ref -> modifyIORef' deletedRef (++ [ref]) >> pure (Right ())
              , encryptedBackendDeleteLegacy = const (pure (Right ()))
              , encryptedBackendWithScratch = \ref inner ->
                  withSystemTempDirectory "prodbox-pulumi-test" $ \root -> do
                    writeIORef scratchRootRef (Just root)
                    inner
                      PulumiScratch
                        { pulumiScratchRoot = root
                        , pulumiScratchBackendUrl = "file://" ++ root
                        , pulumiScratchCheckpointPath = stackCheckpointPath root ref
                        }
              }
      result <-
        withDecryptedStackWith hooks stackRef $ \scratch -> do
          initial <- BS.readFile (pulumiScratchCheckpointPath scratch)
          initial `shouldBe` "{\"version\":3,\"checkpoint\":{}}"
          BS.writeFile (pulumiScratchCheckpointPath scratch) "new-checkpoint"
          pure (Right ("ok" :: String))
      result `shouldBe` Right "ok"
      readIORef storedRef `shouldReturn` [(stackRef, "new-checkpoint")]
      readIORef deletedRef `shouldReturn` []
      scratchRoot <- readIORef scratchRootRef
      case scratchRoot of
        Nothing -> expectationFailure "expected scratch root to be recorded"
        Just root -> doesDirectoryExist root `shouldReturn` False
    it "migrates a legacy checkpoint and deletes legacy state after encrypted store" $ do
      storedRef <- newIORef ([] :: [(PulumiStackRef, BS.ByteString)])
      deletedEncryptedRef <- newIORef ([] :: [PulumiStackRef])
      deletedLegacyRef <- newIORef ([] :: [PulumiStackRef])
      sawInitialRef <- newIORef Nothing
      scratchRootRef <- newIORef Nothing
      let stackRef = PulumiStackRef "aws-test" "aws-test"
          hooks =
            EncryptedBackendHooks
              { encryptedBackendGate = pure VaultGateProceed
              , encryptedBackendLoad = const (pure (Right Nothing))
              , encryptedBackendLoadLegacy = const (pure (Right (Just "legacy-checkpoint")))
              , encryptedBackendStore = \ref bytes ->
                  modifyIORef' storedRef (++ [(ref, bytes)]) >> pure (Right ())
              , encryptedBackendDelete = \ref ->
                  modifyIORef' deletedEncryptedRef (++ [ref]) >> pure (Right ())
              , encryptedBackendDeleteLegacy = \ref ->
                  modifyIORef' deletedLegacyRef (++ [ref]) >> pure (Right ())
              , encryptedBackendWithScratch = \ref inner ->
                  withSystemTempDirectory "prodbox-pulumi-test" $ \root -> do
                    writeIORef scratchRootRef (Just root)
                    inner
                      PulumiScratch
                        { pulumiScratchRoot = root
                        , pulumiScratchBackendUrl = "file://" ++ root
                        , pulumiScratchCheckpointPath = stackCheckpointPath root ref
                        }
              }
      result <-
        withDecryptedStackWith hooks stackRef $ \scratch -> do
          initial <- BS.readFile (pulumiScratchCheckpointPath scratch)
          writeIORef sawInitialRef (Just initial)
          BS.writeFile (pulumiScratchCheckpointPath scratch) "migrated-checkpoint"
          pure (Right ("migrated" :: String))
      result `shouldBe` Right "migrated"
      readIORef sawInitialRef `shouldReturn` Just "legacy-checkpoint"
      readIORef storedRef `shouldReturn` [(stackRef, "migrated-checkpoint")]
      readIORef deletedEncryptedRef `shouldReturn` []
      readIORef deletedLegacyRef `shouldReturn` [stackRef]
      scratchRoot <- readIORef scratchRootRef
      case scratchRoot of
        Nothing -> expectationFailure "expected scratch root to be recorded"
        Just root -> doesDirectoryExist root `shouldReturn` False
  describe "component dependency/readiness graph (Sprint 1.56)" $ do
    -- M3 ADT ranking: a proxy probe cannot satisfy a backend-write edge; only a
    -- deep round-trip through that exact dependency can.
    it "ranks front-door HTTP and resource-exists probes as proxy" $ do
      probeDepth ProbeFrontDoorHttp `shouldBe` ProxyProbe
      probeDepth ProbeResourceExists `shouldBe` ProxyProbe
    it "ranks rollout, operator-available, and backend round-trip probes as deep" $ do
      probeDepth ProbeServiceActive `shouldBe` DeepProbe
      probeDepth ProbeRolloutComplete `shouldBe` DeepProbe
      probeDepth ProbeOperatorAvailable `shouldBe` DeepProbe
      probeDepth ProbeVaultUnsealed `shouldBe` DeepProbe
      probeDepth (ProbeBackendRoundTrip ComponentMinio) `shouldBe` DeepProbe
    it "a proxy probe cannot satisfy a backend-write edge" $ do
      probeSatisfiesBackendWrite ComponentMinio ProbeFrontDoorHttp `shouldBe` False
      probeSatisfiesBackendWrite ComponentMinio ProbeResourceExists `shouldBe` False
      probeSatisfiesBackendWrite ComponentMinio ProbeServiceActive `shouldBe` False
      probeSatisfiesBackendWrite ComponentMinio ProbeRolloutComplete `shouldBe` False
    it "a deep round-trip satisfies a backend-write edge only through that exact dependency" $ do
      probeSatisfiesBackendWrite ComponentMinio (ProbeBackendRoundTrip ComponentMinio)
        `shouldBe` True
      probeSatisfiesBackendWrite ComponentMinio (ProbeBackendRoundTrip ComponentVaultWorkload)
        `shouldBe` False
    -- Graph-validity rejections.
    it "rejects a cycle" $ do
      let nodes =
            [ ComponentNode ComponentMinio [orderingOn ComponentRegistry] ProbeRolloutComplete
            , ComponentNode
                ComponentRegistry
                [backendWriteOn ComponentMinio]
                (ProbeBackendRoundTrip ComponentMinio)
            ]
      case validateComponentGraph nodes of
        Left (ComponentGraphCycle _) -> pure ()
        other -> expectationFailure ("expected a cycle rejection, got " ++ show other)
    it "rejects a dangling depends_on id" $ do
      let nodes =
            [ComponentNode ComponentRegistry [orderingOn ComponentMinio] ProbeRolloutComplete]
      case validateComponentGraph nodes of
        Left (ComponentGraphDanglingDependency ComponentRegistry ComponentMinio) -> pure ()
        other -> expectationFailure ("expected a dangling-dependency rejection, got " ++ show other)
    it "rejects a backend-write edge whose consumer carries no deep readiness node" $ do
      let nodes =
            [ ComponentNode ComponentMinio [] ProbeRolloutComplete
            , -- Registry claims a backend-write edge onto MinIO but gates on the
              -- shallow front-door probe: the exact motivating race.
              ComponentNode ComponentRegistry [backendWriteOn ComponentMinio] ProbeFrontDoorHttp
            ]
      case validateComponentGraph nodes of
        Left (ComponentGraphBackendEdgeWithoutDeepReadiness ComponentRegistry ComponentMinio _) ->
          pure ()
        other ->
          expectationFailure ("expected a backend-edge-without-deep-readiness rejection, got " ++ show other)
    it "rejects a duplicate component node" $ do
      let nodes =
            [ ComponentNode ComponentMinio [] ProbeRolloutComplete
            , ComponentNode ComponentMinio [] ProbeRolloutComplete
            ]
      validateComponentGraph nodes `shouldBe` Left (ComponentGraphDuplicate ComponentMinio)
    it "projects a well-formed graph to a deterministic dependencies-before-dependents order" $ do
      let nodes =
            [ ComponentNode ComponentMinio [] ProbeRolloutComplete
            , ComponentNode
                ComponentRegistry
                [backendWriteOn ComponentMinio]
                (ProbeBackendRoundTrip ComponentMinio)
            , ComponentNode ComponentChartApi [orderingOn ComponentRegistry] ProbeRolloutComplete
            ]
      case validateComponentGraph nodes of
        Left err -> expectationFailure ("expected a valid graph, got " ++ show err)
        Right dag -> do
          let order = componentReconcileOrder dag
          order `shouldBe` [ComponentMinio, ComponentRegistry, ComponentChartApi]
          -- Deterministic: re-validation yields the identical order.
          fmap componentDagOrder (validateComponentGraph nodes) `shouldBe` Right order
    it "the default bootstrap graph is valid and orders MinIO before the registry" $ do
      case validateComponentGraph defaultComponentGraph of
        Left err -> expectationFailure ("default component graph is invalid: " ++ show err)
        Right dag -> do
          let order = componentReconcileOrder dag
              indexOf cid = length (takeWhile (/= cid) order)
          -- The registry's backend-write dependency on MinIO forces MinIO earlier.
          (indexOf ComponentMinio < indexOf ComponentRegistry) `shouldBe` True
    it "models Vault and the gateway daemon as bounded two-phase nodes" $ do
      case validateComponentGraph defaultComponentGraph of
        Left err -> expectationFailure ("default component graph is invalid: " ++ show err)
        Right dag -> do
          fmap readiness (lookupComponentNode ComponentClusterBase dag)
            `shouldBe` Just ProbeServiceActive
          fmap readiness (lookupComponentNode ComponentVaultWorkload dag)
            `shouldBe` Just ProbeRolloutComplete
          fmap componentDependencyIds (lookupComponentNode ComponentVaultUnsealed dag)
            `shouldBe` Just
              [ ComponentVaultWorkload
              , ComponentGatewayDaemonPreVault
              ]
          fmap readiness (lookupComponentNode ComponentVaultUnsealed dag)
            `shouldBe` Just ProbeVaultUnsealed
          fmap componentDependencyIds (lookupComponentNode ComponentGatewayDaemonPreVault dag)
            `shouldBe` Just
              [ ComponentMinio
              , ComponentCertManager
              , ComponentVaultWorkload
              , ComponentRegistry
              ]
          fmap readiness (lookupComponentNode ComponentGatewayDaemonPreVault dag)
            `shouldBe` Just ProbeRolloutComplete
          fmap componentDependencyIds (lookupComponentNode ComponentGatewayDaemonFull dag)
            `shouldBe` Just
              [ ComponentVaultUnsealed
              , ComponentGatewayDaemonPreVault
              , ComponentMinio
              ]
          fmap readiness (lookupComponentNode ComponentGatewayDaemonFull dag)
            `shouldBe` Just (ProbeBackendRoundTrip ComponentMinio)
    it "declares every registry-backed native platform dependency explicitly" $ do
      case validateComponentGraph defaultComponentGraph of
        Left err -> expectationFailure ("default component graph is invalid: " ++ show err)
        Right dag -> do
          fmap componentDependencyIds (lookupComponentNode ComponentCertManager dag)
            `shouldBe` Just [ComponentClusterBase, ComponentRegistry]
          fmap componentDependencyIds (lookupComponentNode ComponentMetalLB dag)
            `shouldBe` Just
              [ComponentClusterBase, ComponentRegistry, ComponentVaultUnsealed]
          fmap componentDependencyIds (lookupComponentNode ComponentEnvoyGateway dag)
            `shouldBe` Just
              [ComponentClusterBase, ComponentRegistry, ComponentVaultUnsealed]
          fmap componentDependencyIds (lookupComponentNode ComponentPerconaPostgresOperator dag)
            `shouldBe` Just
              [ComponentClusterBase, ComponentRegistry, ComponentVaultUnsealed]
    it "uses the caller tie-break instead of rendered text for independent nodes" $ do
      let adjacency key = lookup key [(1 :: Int, []), (2, [])]
          reverseRender key = show (3 - key)
      acyclicTopologicalOrder reverseRender id adjacency [2, 1]
        `shouldBe` Right [1, 2]
    it "shares the acyclic expansion with the prerequisite DAG (cycle rejection)" $ do
      -- The generic expansion the component graph reuses rejects a back-edge.
      let adjacency k = lookup k [(1 :: Int, [2]), (2, [1])]
      case acyclicTopologicalOrder show id adjacency [1] of
        Left _ -> pure ()
        Right order -> expectationFailure ("expected a cycle rejection, got " ++ show order)
  describe "component readiness observation seam (Sprint 1.59)" $ do
    it "opens the gate only for an affirmative readiness observation" $
      map
        readinessGateOpen
        [ ReadyObserved
        , NotReadyYet "still converging"
        , Unreachable "connection refused"
        ]
        `shouldBe` [True, False, False]
    it "lowers pending and unreachable observations to bounded pending polls" $ do
      observationPollOutcome ReadyObserved `shouldBe` PollReady ()
      observationPollOutcome (NotReadyYet "still converging")
        `shouldBe` PollPending "still converging"
      observationPollOutcome (Unreachable "connection refused")
        `shouldBe` PollPending "unreachable: connection refused"
    it "dispatches every declared readiness probe to its dedicated adapter" $ do
      callsRef <- newIORef ([] :: [String])
      let record label result = do
            modifyIORef' callsRef (++ [label])
            pure result
          probeTargets =
            [
              ( ProbeResourceExists
              , ResourceExistsTarget
                  ComponentRegistry
                  (record "resource" (Right ReadinessProbeReady))
              )
            ,
              ( ProbeFrontDoorHttp
              , FrontDoorHttpTarget
                  ComponentRegistry
                  (record "front-door" (Right ReadinessProbeReady))
              )
            ,
              ( ProbeServiceActive
              , ServiceActiveTarget
                  ComponentClusterBase
                  (record "service" (Right ReadinessProbeReady))
              )
            ,
              ( ProbeRolloutComplete
              , RolloutCompleteTarget
                  ComponentGatewayDaemonPreVault
                  (record "rollout" (Right ReadinessProbeReady))
              )
            ,
              ( ProbeOperatorAvailable
              , OperatorAvailableTarget
                  ComponentPerconaPostgresOperator
                  (record "operator" (Right ReadinessProbeReady))
              )
            ,
              ( ProbeVaultUnsealed
              , VaultUnsealedTarget
                  ComponentVaultUnsealed
                  (record "vault" (Right ReadinessProbeReady))
              )
            ,
              ( ProbeBackendRoundTrip ComponentMinio
              , BackendRoundTripTarget
                  ComponentGatewayDaemonFull
                  ComponentMinio
                  (record "backend:ComponentMinio" (Right ReadinessProbeReady))
              )
            ]
      observations <-
        mapM
          (\(probe, target) -> observeComponentReadiness target probe)
          probeTargets
      observations `shouldBe` replicate (length probeTargets) ReadyObserved
      readIORef callsRef
        `shouldReturn` [ "resource"
                       , "front-door"
                       , "service"
                       , "rollout"
                       , "operator"
                       , "vault"
                       , "backend:ComponentMinio"
                       ]
    it "fails closed when a target does not implement the declared probe" $ do
      let target = RolloutCompleteTarget ComponentRegistry (pure (Right ReadinessProbeReady))
      observation <- observeComponentReadiness target (ProbeBackendRoundTrip ComponentMinio)
      case observation of
        Unreachable detail -> detail `shouldSatisfy` Text.isInfixOf "does not implement"
        other -> expectationFailure ("expected an unreachable mismatch, got " ++ show other)
    it "rejects an incompatible target before entering the poll loop" $ do
      callsRef <- newIORef (0 :: Int)
      let target =
            RolloutCompleteTarget ComponentRegistry $ do
              modifyIORef' callsRef (+ 1)
              pure (Right ReadinessProbeReady)
          policy =
            RetryPolicy
              { retryPolicyMaxAttempts = 3
              , retryPolicyBaseDelayMicros = 0
              , retryPolicyMultiplier = 1
              , retryPolicyMaxDelayMicros = 0
              }
      result <- waitForComponentReadiness policy target (ProbeBackendRoundTrip ComponentMinio)
      result `shouldSatisfy` either (Text.isInfixOf "does not implement") (const False)
      readIORef callsRef `shouldReturn` 0
    it "fails closed when a backend-round-trip target names the wrong backend" $ do
      let target =
            BackendRoundTripTarget
              ComponentRegistry
              ComponentMinio
              (pure (Right ReadinessProbeReady))
      observation <-
        observeComponentReadiness target (ProbeBackendRoundTrip ComponentVaultWorkload)
      case observation of
        Unreachable detail -> detail `shouldSatisfy` Text.isInfixOf "does not implement"
        other -> expectationFailure ("expected an unreachable backend mismatch, got " ++ show other)
    it "preserves authoritative pending and unreachable probe detail" $ do
      let pendingTarget =
            OperatorAvailableTarget
              ComponentPerconaPostgresOperator
              (pure (Right (ReadinessProbePending "Available=False")))
          unreachableTarget =
            VaultUnsealedTarget
              ComponentVaultUnsealed
              (pure (Left "Vault seal-status endpoint refused the connection"))
      observeComponentReadiness pendingTarget ProbeOperatorAvailable
        `shouldReturn` NotReadyYet "Available=False"
      observeComponentReadiness unreachableTarget ProbeVaultUnsealed
        `shouldReturn` Unreachable "Vault seal-status endpoint refused the connection"
    it "retries not-ready and unreachable readings without opening the gate" $ do
      observationsRef <-
        newIORef
          [ Right (ReadinessProbePending "still converging")
          , Left "temporarily unreachable"
          , Right ReadinessProbeReady
          ]
      let observeNext = do
            observations <- readIORef observationsRef
            case observations of
              next : remaining -> writeIORef observationsRef remaining >> pure next
              [] -> pure (Left "observation fixture exhausted")
          target = RolloutCompleteTarget ComponentGatewayDaemonPreVault observeNext
          policy =
            RetryPolicy
              { retryPolicyMaxAttempts = 3
              , retryPolicyBaseDelayMicros = 0
              , retryPolicyMultiplier = 1
              , retryPolicyMaxDelayMicros = 0
              }
      waitForComponentReadiness policy target ProbeRolloutComplete
        `shouldReturn` Right ()
      readIORef observationsRef `shouldReturn` []
    it "fails closed on bounded pending and unreachable exhaustion" $ do
      pendingCallsRef <- newIORef (0 :: Int)
      unreachableCallsRef <- newIORef (0 :: Int)
      let policy =
            RetryPolicy
              { retryPolicyMaxAttempts = 2
              , retryPolicyBaseDelayMicros = 0
              , retryPolicyMultiplier = 1
              , retryPolicyMaxDelayMicros = 0
              }
          pendingTarget =
            RolloutCompleteTarget
              ComponentGatewayDaemonPreVault
              ( do
                  modifyIORef' pendingCallsRef (+ 1)
                  pure (Right (ReadinessProbePending "rollout has 1/3 ready replicas"))
              )
          unreachableTarget =
            VaultUnsealedTarget
              ComponentVaultUnsealed
              ( do
                  modifyIORef' unreachableCallsRef (+ 1)
                  pure (Left "seal-status unreachable")
              )
      waitForComponentReadiness policy pendingTarget ProbeRolloutComplete
        `shouldReturn` Left "rollout has 1/3 ready replicas"
      waitForComponentReadiness policy unreachableTarget ProbeVaultUnsealed
        `shouldReturn` Left "unreachable: seal-status unreachable"
      readIORef pendingCallsRef `shouldReturn` 2
      readIORef unreachableCallsRef `shouldReturn` 2
  describe "graph-sourced chart dependency edges + operator Available gate (Sprint 3.23)" $ do
    -- resolveDependencyOrder now sources chart order from the component graph.
    -- The default graph's chart→chart edges must reproduce today's order exactly.
    it "reproduces the historical chart deploy order from the component graph" $ do
      let order chart = resolveDependencyOrder defaultComponentGraph "." chart
      order "keycloak-postgres" `shouldBe` Right ["keycloak-postgres"]
      order "keycloak" `shouldBe` Right ["keycloak-postgres", "keycloak"]
      order "vscode" `shouldBe` Right ["keycloak-postgres", "keycloak", "vscode"]
      order "redis" `shouldBe` Right ["redis"]
      order "pulsar" `shouldBe` Right ["pulsar"]
      order "api" `shouldBe` Right ["api"]
      order "websocket" `shouldBe` Right ["redis", "websocket"]
      order "gateway" `shouldBe` Right ["pulsar", "gateway"]
    it "rejects a chart dependency cycle sourced from the graph" $ do
      let cyclicGraph =
            [ ComponentNode ComponentChartApi [orderingOn ComponentChartWebsocket] ProbeRolloutComplete
            , ComponentNode ComponentChartWebsocket [orderingOn ComponentChartApi] ProbeRolloutComplete
            ]
      case resolveDependencyOrder cyclicGraph "." "api" of
        Left _ -> pure ()
        Right order -> expectationFailure ("expected a cycle rejection, got " ++ show order)
    -- The Percona/Patroni operator gate is now derived from the graph edge and
    -- gates on Available, not mere presence.
    it "projects the Percona operator gate from the keycloak-postgres graph edge" $ do
      case validateComponentGraph defaultComponentGraph of
        Left err -> expectationFailure ("default graph invalid: " ++ show err)
        Right dag -> do
          operatorAvailableGates dag [ComponentChartKeycloakPostgres]
            `shouldBe` [ComponentPerconaPostgresOperator]
          operatorAvailableGates dag [ComponentChartRedis] `shouldBe` []
    it "the operator gate accepts only a Deployment reporting Available=True" $ do
      deploymentConditionReportsTrue "True" `shouldBe` True
      deploymentConditionReportsTrue "true\n" `shouldBe` True
      deploymentConditionReportsTrue "False" `shouldBe` False
      deploymentConditionReportsTrue "" `shouldBe` False
    it "binds every default-graph operator gate to a production readiness target" $ do
      let expectProductionTarget gate =
            case operatorAvailableTarget gate of
              Left reason -> expectationFailure (Text.unpack reason)
              Right _ -> pure ()
      case validateComponentGraph defaultComponentGraph of
        Left err -> expectationFailure ("default graph invalid: " ++ show err)
        Right dag ->
          forM_
            (operatorAvailableGates dag [ComponentChartKeycloakPostgres])
            expectProductionTarget
    it "fails closed for an existing component with no operator-Available executor" $
      case operatorAvailableTarget ComponentRegistry of
        Left reason ->
          Text.unpack reason
            `shouldContain` "No ProbeOperatorAvailable executor is registered for component `registry`"
        Right _ -> expectationFailure "expected an unbound operator gate to fail closed"
    it "keeps the production operator-target registry free of a wildcard arm" $ do
      repoRoot <- getCurrentDirectory
      source <- readFile (repoRoot </> "src" </> "Prodbox" </> "Lib" </> "ChartPlatform.hs")
      let targetBlock =
            takeWhile
              (not . isPrefixOf "unsupportedOperatorGate ::")
              (dropWhile (not . isInfixOf "operatorAvailableTarget component =") (lines source))
      targetBlock `shouldSatisfy` (not . null)
      unlines targetBlock `shouldNotContain` "_ ->"
    it "routes unreachable operator observations through ChartPlatform and gates closed" $ do
      result <-
        validateOperatorGatesWith
          ( \gate ->
              Right
                ( OperatorAvailableTarget
                    gate
                    (pure (Left "connection refused"))
                )
          )
          [ComponentPerconaPostgresOperator]
      result
        `shouldBe` Left
          "Cannot observe operator readiness for `percona_postgres_operator`: connection refused"
      operatorGateResult ComponentPerconaPostgresOperator ReadyObserved `shouldBe` Right ()
      operatorGateResult
        ComponentPerconaPostgresOperator
        (NotReadyYet "Available=False")
        `shouldBe` Left "Available=False"
    it "classifies the one-shot Percona observation without probing past an absent CRD" $ do
      callsRef <- newIORef ([] :: [[String]])
      result <-
        observePatroniOperatorAvailableWith $ \arguments -> do
          modifyIORef' callsRef (++ [arguments])
          pure (Right (ProcessOutput ExitSuccess "" ""))
      case result of
        Right (ReadinessProbePending detail) ->
          Text.unpack detail `shouldContain` "has not been created yet"
        other -> expectationFailure ("expected pending CRD observation, got " ++ show other)
      calls <- readIORef callsRef
      case calls of
        [arguments] -> ("--ignore-not-found" `elem` arguments) `shouldBe` True
        other -> expectationFailure ("expected one CRD observation, got " ++ show other)
    it "requires the Percona Deployment to report Available=True" $ do
      callsRef <- newIORef (0 :: Int)
      result <-
        observePatroniOperatorAvailableWith $ \_ -> do
          callIndex <- readIORef callsRef
          modifyIORef' callsRef (+ 1)
          pure
            ( Right
                ( if callIndex == 0
                    then
                      ProcessOutput
                        ExitSuccess
                        "customresourcedefinition.apiextensions.k8s.io/perconapgclusters.pgv2.percona.com"
                        ""
                    else ProcessOutput ExitSuccess "True\n" ""
                )
            )
      result `shouldBe` Right ReadinessProbeReady
      readIORef callsRef `shouldReturn` 2
  describe "EffectDAG-driven reconcile ordering + deep registry->MinIO gate (Sprint 4.45)" $ do
    it "derives the complete native component order directly from the validated graph" $ do
      case validateComponentGraph defaultComponentGraph of
        Left err -> expectationFailure ("default component graph is invalid: " ++ show err)
        Right dag -> do
          let derived = nativeInstallStepOrder dag
          derived
            `shouldBe` concatMap stepsForComponent (componentReconcileOrder dag)
          nativeInstallStepOrderRespectsGraph dag derived `shouldBe` Right ()
    it "builds the default execution plan only after its graph and readiness barriers validate" $ do
      case buildNativeInstallExecutionPlan
        "/tmp/prodbox"
        (testValidatedSettings "/tmp/prodbox/.data")
        "machine-id-123"
        "prodbox-123"
        "prodbox-123"
        False of
        Left err -> expectationFailure (Preconditions.errorNarrative err)
        Right _ -> pure ()
    it "fails closed before planning when a valid graph projects a phase regression" $ do
      let baseSettings = testValidatedSettings "/tmp/prodbox/.data"
          baseConfig = validatedConfig baseSettings
          invertPhaseOrder node
            | component_id node == ComponentClusterBase =
                node {depends_on = [orderingOn ComponentMetalLB]}
            | component_id node == ComponentMetalLB = node {depends_on = []}
            | otherwise = node
          invertedSettings =
            baseSettings
              { validatedConfig =
                  baseConfig
                    { components = map invertPhaseOrder (components baseConfig)
                    }
              }
      case buildNativeInstallExecutionPlan
        "/tmp/prodbox"
        invertedSettings
        "machine-id-123"
        "prodbox-123"
        "prodbox-123"
        False of
        Left err -> do
          Preconditions.errorPreconditionLabel err `shouldBe` "nativeInstallGraphOrder"
          Preconditions.errorNarrative err `shouldContain` "phase regression"
          Preconditions.errorNarrative err `shouldContain` "No reconcile mutation was started."
        Right plan -> expectationFailure ("expected a fail-closed plan rejection, got " ++ show plan)
    it "binds every RKE2-owned component group to a production readiness target" $ do
      let settings = testValidatedSettings "/tmp/prodbox/.data"
          expectNativeTarget component =
            case nativeComponentReadinessTarget "/tmp/prodbox" settings component of
              Left reason -> expectationFailure (Text.unpack reason)
              Right _ -> pure ()
      case validateComponentGraph defaultComponentGraph of
        Left err -> expectationFailure ("default component graph is invalid: " ++ show err)
        Right dag ->
          forM_
            [ component
            | component <- componentReconcileOrder dag
            , not (null (stepsForComponent component))
            ]
            expectNativeTarget
    it "keeps both phase step executors total and wildcard-free" $ do
      repoRoot <- getCurrentDirectory
      source <- readFile (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Rke2.hs")
      let sourceLines = lines source
          blockFromTo startMarker endMarker =
            takeWhile
              (not . isInfixOf endMarker)
              (dropWhile (not . isInfixOf startMarker) sourceLines)
          bootstrapBlock = blockFromTo "bootstrapStepAction step =" "The @PhaseSteady@ executor"
          steadyBlock =
            blockFromTo
              "steadyStepAction settings (metallbPool, edgeLbIp) step ="
              "wrongPhaseStep ::"
          containsWildcardArm =
            any (isPrefixOf "_ ->" . dropWhile (== ' '))
      bootstrapBlock `shouldSatisfy` (not . null)
      steadyBlock `shouldSatisfy` (not . null)
      containsWildcardArm bootstrapBlock `shouldBe` False
      containsWildcardArm steadyBlock `shouldBe` False
    it "narrates the deep registry->MinIO gate before the mirror push" $ do
      let steps =
            lines
              ( renderNativeInstallPlan
                  "/tmp/prodbox"
                  (testValidatedSettings "/tmp/prodbox/.data")
                  "machine-id-123"
                  "prodbox-123"
                  "prodbox-123"
                  False
              )
          edgeIndex = elemIndex "STEP=verify_registry_minio_edge" steps
          mirrorIndex = elemIndex "STEP=mirror_cluster_images_once" steps
          registryIndex = elemIndex "STEP=ensure_harbor_registry_runtime" steps
      registryIndex `shouldSatisfy` (`indexPrecedes` edgeIndex)
      edgeIndex `shouldSatisfy` (`indexPrecedes` mirrorIndex)
    -- M3: the deep-gate decision table. Only an upload session (201/202) proves
    -- the registry->MinIO S3 write path; a curl failure is Unreachable (gates
    -- closed), a registry 5xx / front-door 200 is retryable NotReady.
    it "classifies the deep registry->MinIO probe by whether the S3 write edge is proven" $ do
      classifyRegistryStorageEdgeProbe (Right "202") `shouldBe` RegistryEdgeReady
      classifyRegistryStorageEdgeProbe (Right "201") `shouldBe` RegistryEdgeReady
      case classifyRegistryStorageEdgeProbe (Right "500") of
        RegistryEdgeNotReady _ -> pure ()
        other -> expectationFailure ("expected NotReady for 500, got " ++ show other)
      case classifyRegistryStorageEdgeProbe (Right "200") of
        RegistryEdgeNotReady _ -> pure ()
        other -> expectationFailure ("expected NotReady for front-door 200, got " ++ show other)
      case classifyRegistryStorageEdgeProbe (Left "curl: (7) Failed to connect") of
        RegistryEdgeUnreachable _ -> pure ()
        other -> expectationFailure ("expected Unreachable for a curl failure, got " ++ show other)
    -- §4: the retry classifier now treats transient name-resolution failures as
    -- retryable so residual jitter is bounded, not fatal.
    it "classifies transient name-resolution push failures as retryable" $ do
      isRetryableHarborPublicationFailure
        "dial tcp: lookup minio.prodbox.svc.cluster.local: no such host"
        `shouldBe` True
      isRetryableHarborPublicationFailure "temporary failure in name resolution" `shouldBe` True
      isRetryableHarborPublicationFailure "Get \"https://...\": dial tcp 10.0.0.1:443: i/o timeout"
        `shouldBe` True
      isRetryableHarborPublicationFailure "unexpected status from PUT request: 503"
        `shouldBe` True
    it "keeps a genuine authorization failure non-retryable" $
      isRetryableHarborPublicationFailure "401 unauthorized: authentication required" `shouldBe` False
  describe "config unencrypted basics (Sprint 1.38)" $ do
    it "round-trips a root cluster's basics through JSON" $ do
      basicsFromJson (basicsToJson sampleRootBasics) `shouldBe` Right sampleRootBasics
    it "round-trips a child cluster's basics through JSON" $ do
      basicsFromJson (basicsToJson sampleChildBasics) `shouldBe` Right sampleChildBasics
    it "accepts a coherent root (shamir, no parent) basics" $ do
      validateBasics sampleRootBasics `shouldBe` Right ()
    it "accepts a coherent child (transit, parent) basics" $ do
      validateBasics sampleChildBasics `shouldBe` Right ()
    it "rejects a root cluster that carries a parent ref" $ do
      validateBasics (sampleRootBasics {basicsParentRef = Just sampleParentRef})
        `shouldSatisfy` isLeft
    it "rejects a child cluster with no parent ref" $ do
      validateBasics (sampleChildBasics {basicsParentRef = Nothing}) `shouldSatisfy` isLeft
    it "rejects an empty cluster id" $ do
      validateBasics (sampleRootBasics {basicsClusterId = ""}) `shouldSatisfy` isLeft
    it "rejects a non-1 format version" $ do
      validateBasics (sampleRootBasics {basicsFormatVersion = 2}) `shouldSatisfy` isLeft
    it "identifies the root cluster and a child cluster" $ do
      isRootCluster sampleRootBasics `shouldBe` True
      isRootCluster sampleChildBasics `shouldBe` False
    it "projects the floor from prodbox.dhall (the sole floor source)" $
      -- Sprint 7.18: there is no separate prodbox-basics.json. The floor is read
      -- straight off the Tier-0 prodbox.dhall's context; writing the default
      -- root record (prodbox-home, shamir, no parent) yields the root floor.
      withSystemTempDirectory "prodbox-basics" $ \tmpDir -> do
        writeTier0AtPath (tmpDir </> "prodbox.dhall") defaultProjectConfig `shouldReturn` Right ()
        loadUnencryptedBasicsAtPath (tmpDir </> "prodbox.dhall") `shouldReturn` Right sampleRootBasics
    it "fails the floor read when no prodbox.dhall is present" $
      -- A repo with no Tier-0 prodbox.dhall has no floor source, so the read
      -- fails (the seed/propose fallback then takes over upstream).
      withSystemTempDirectory "prodbox-basics" $ \tmpDir -> do
        result <- loadUnencryptedBasicsAtPath (tmpDir </> "prodbox.dhall")
        result `shouldSatisfy` isLeft
  describe "Tier 0 binary-owned prodbox.dhall (Sprint 1.39)" $ do
    it "round-trips: decode . encode == id for the Tier-0 record" $
      withSystemTempDirectory "prodbox-tier0-roundtrip" $ \tmpDir -> do
        -- The schema is emitted from the Haskell record (one typed SoT) via the
        -- same Dhall.inject mechanism; rendering then decoding must yield the
        -- original record back.
        let tier0Path = tmpDir </> "prodbox.dhall"
        writeFile tier0Path (Text.unpack (renderProjectConfigDhall sampleTier0Child))
        decoded <- Dhall.inputFile Dhall.auto tier0Path :: IO ProdboxProjectConfig
        decoded `shouldBe` sampleTier0Child
    it "round-trips: the default Tier-0 record decodes to defaultProjectConfig" $
      withSystemTempDirectory "prodbox-tier0-roundtrip" $ \tmpDir -> do
        let tier0Path = tmpDir </> "prodbox.dhall"
        writeFile tier0Path (Text.unpack (renderProjectConfigDhall defaultProjectConfig))
        decoded <- Dhall.inputFile Dhall.auto tier0Path :: IO ProdboxProjectConfig
        decoded `shouldBe` defaultProjectConfig
    it "projects the floor deterministically from the Tier-0 context" $ do
      -- The floor derivation is a pure function of the Tier-0 context (the
      -- parameters / witness never reach the floor), so it is identical across
      -- repeated projections of the same record.
      projectBasics sampleTier0Child `shouldBe` projectBasics sampleTier0Child
      projectBasics sampleTier0Child
        `shouldBe` UnencryptedBasics
          { basicsClusterId = "prodbox-child"
          , basicsVaultAddress = "http://127.0.0.1:31820"
          , basicsSealMode = SealModeTransit
          , basicsParentRef = Just sampleParentRef
          , basicsFormatVersion = 1
          }
    it "writeTier0 derives a floor that loadUnencryptedBasics reads back" $
      withSystemTempDirectory "prodbox-tier0-write" $ \tmpDir -> do
        writeTier0AtPath (tmpDir </> "prodbox.dhall") sampleTier0Child `shouldReturn` Right ()
        loadUnencryptedBasicsAtPath (tmpDir </> "prodbox.dhall")
          `shouldReturn` Right (projectBasics sampleTier0Child)
  describe "Tier 0 basics-floor self-heal on reconcile (Sprint 1.39 P1)" $ do
    it "missing floor + no prodbox.dhall reconstructs a valid root floor from the known local identity" $
      -- A cluster initialized before 1.39 (or rebuilt against a durable Vault
      -- PV, so `vault init` early-returned) has NO floor and NO prodbox.dhall.
      -- The self-heal must write a coherent root (shamir, no parent) floor from
      -- the default identity, with the caller-supplied Vault address.
      withSystemTempDirectory "prodbox-floor-selfheal-default" $ \tmpDir -> do
        before <- loadUnencryptedBasicsAtPath (tmpDir </> "prodbox.dhall")
        before `shouldSatisfy` isLeft
        ensureBasicsFloorAtPath (tmpDir </> "prodbox.dhall") "http://127.0.0.1:31820"
          `shouldReturn` Right ()
        loaded <- loadUnencryptedBasicsAtPath (tmpDir </> "prodbox.dhall")
        loaded
          `shouldBe` Right
            UnencryptedBasics
              { basicsClusterId = "prodbox-home"
              , basicsVaultAddress = "http://127.0.0.1:31820"
              , basicsSealMode = SealModeShamir
              , basicsParentRef = Nothing
              , basicsFormatVersion = 1
              }
    it "present operator-authored prodbox.dhall IS the floor and self-heal preserves it" $
      -- Sprint 7.18: prodbox.dhall is the SOLE floor source. When the
      -- operator-authored prodbox.dhall exists, the floor loads straight off its
      -- context (matching the operator's binary context), and ensureBasicsFloor
      -- is a no-op that leaves it byte-for-byte untouched — the supplied Vault
      -- address is ignored because the existing floor is already valid.
      withSystemTempDirectory "prodbox-floor-selfheal-tier0" $ \tmpDir -> do
        writeFile (tmpDir </> "prodbox.dhall") (Text.unpack (renderProjectConfigDhall sampleTier0Child))
        before <- loadUnencryptedBasicsAtPath (tmpDir </> "prodbox.dhall")
        before `shouldBe` Right (projectBasics sampleTier0Child)
        let tier0Path = tmpDir </> "prodbox.dhall"
        beforeBytes <- BS.readFile tier0Path
        ensureBasicsFloorAtPath (tmpDir </> "prodbox.dhall") "http://10.0.0.99:8200" `shouldReturn` Right ()
        afterBytes <- BS.readFile tier0Path
        afterBytes `shouldBe` beforeBytes
        loadUnencryptedBasicsAtPath (tmpDir </> "prodbox.dhall")
          `shouldReturn` Right (projectBasics sampleTier0Child)
    it "is a no-op when a valid floor already exists" $
      -- Idempotent: a present, valid prodbox.dhall floor is left byte-for-byte
      -- untouched.
      withSystemTempDirectory "prodbox-floor-selfheal-noop" $ \tmpDir -> do
        writeTier0AtPath (tmpDir </> "prodbox.dhall") sampleTier0Child `shouldReturn` Right ()
        let tier0Path = tmpDir </> "prodbox.dhall"
        before <- BS.readFile tier0Path
        ensureBasicsFloorAtPath (tmpDir </> "prodbox.dhall") "http://10.0.0.99:8200" `shouldReturn` Right ()
        after <- BS.readFile tier0Path
        -- The supplied address (different from the record's) is ignored because
        -- the existing floor is valid: no-op, bytes unchanged.
        after `shouldBe` before
    it "child self-heal reconstructs a coherent transit floor from the supplied identity" $
      -- The child analog: no floor, no prodbox.dhall → reconstruct a transit
      -- (child) floor carrying the supplied parent reference.
      withSystemTempDirectory "prodbox-floor-selfheal-child" $ \tmpDir -> do
        let parentRef =
              Tier0ParentRef
                { parent_cluster_id = "prodbox-root"
                , parent_vault_address = "http://10.0.0.1:8200"
                , parent_transit_key = "transit/prodbox-child-seal"
                }
        ensureChildBasicsFloorAtPath
          (tmpDir </> "prodbox.dhall")
          "prodbox-child"
          "http://127.0.0.1:31820"
          parentRef
          `shouldReturn` Right ()
        loaded <- loadUnencryptedBasicsAtPath (tmpDir </> "prodbox.dhall")
        loaded
          `shouldBe` Right
            UnencryptedBasics
              { basicsClusterId = "prodbox-child"
              , basicsVaultAddress = "http://127.0.0.1:31820"
              , basicsSealMode = SealModeTransit
              , basicsParentRef = Just sampleParentRef
              , basicsFormatVersion = 1
              }
    it "fails LOUD (Left) when the floor write itself fails" $
      -- P2 belt-and-suspenders: a floor write that cannot complete must surface
      -- as a Left, never a silent Right. Force the write to fail by occupying
      -- the prodbox.dhall path with a DIRECTORY so the file write errors.
      withSystemTempDirectory "prodbox-floor-selfheal-fail" $ \tmpDir -> do
        createDirectoryIfMissing True (tmpDir </> "prodbox.dhall")
        result <- ensureBasicsFloorAtPath (tmpDir </> "prodbox.dhall") "http://127.0.0.1:31820"
        result `shouldSatisfy` isLeft
  describe "AWS transient-error classifier (Sprint 7.20 P4)" $ do
    it "classifies well-known throttle / service-unavailable codes as transient" $ do
      awsErrorCodeIsTransient (Just "Throttling") `shouldBe` True
      awsErrorCodeIsTransient (Just "ThrottlingException") `shouldBe` True
      awsErrorCodeIsTransient (Just "RequestLimitExceeded") `shouldBe` True
      awsErrorCodeIsTransient (Just "ServiceUnavailable") `shouldBe` True
    it "treats NoSuchEntity / AccessDenied / no-code as permanent (NOT transient)" $ do
      awsErrorCodeIsTransient (Just "NoSuchEntity") `shouldBe` False
      awsErrorCodeIsTransient (Just "AccessDenied") `shouldBe` False
      awsErrorCodeIsTransient Nothing `shouldBe` False
    it "secret-free guard: a default Tier-0 record carries no secret values" $
      tier0CarriesNoSecretValues defaultProjectConfig `shouldBe` True
    it "secret-free guard: rejects a Tier-0 record with a literal credential" $ do
      let base = Tier0.parameters defaultProjectConfig
          poisonedAws =
            (Tier0.aws base)
              { awsCredentialAccessKeyId = SecretRefTestPlaintext "AKIA-LITERAL-CREDENTIAL"
              }
          -- Construct the poisoned parameters via the explicit constructor so
          -- the shared field labels resolve unambiguously to ProdboxParameters.
          poisonedParams =
            Tier0.ProdboxParameters
              { Tier0.aws = poisonedAws
              , Tier0.route53 = Tier0.route53 base
              , Tier0.aws_substrate = Tier0.aws_substrate base
              , Tier0.ses = Tier0.ses base
              , Tier0.domain = Tier0.domain base
              , Tier0.acme = Tier0.acme base
              , Tier0.deployment = Tier0.deployment base
              , Tier0.capacity = Tier0.capacity base
              , Tier0.cluster_topology = Tier0.cluster_topology base
              , Tier0.storage = Tier0.storage base
              , Tier0.pulumi_state_backend = Tier0.pulumi_state_backend base
              , Tier0.components = Tier0.components base
              }
          poisoned = defaultProjectConfig {parameters = poisonedParams}
      tier0CarriesNoSecretValues poisoned `shouldBe` False
  describe "in-force config object-absent tolerance (Sprint 1.39 follow-up)" $ do
    it "treats an 'in-force config object missing' error as object-absent (seed fallback)" $
      inForceConfigObjectAbsent
        "failed to fetch in-force config envelope: in-force config object missing at objects/abc.enc"
        `shouldBe` True
    it "keeps every other in-force error fail-closed (NOT object-absent)" $ do
      inForceConfigObjectAbsent "Vault is sealed" `shouldBe` False
      inForceConfigObjectAbsent
        "failed to reach in-force config MinIO backend: connection refused"
        `shouldBe` False
      inForceConfigObjectAbsent
        "failed to read secret/minio/root from Vault: 403"
        `shouldBe` False
  describe "Tier 0 in-cluster daemon binary context (Sprint 1.40)" $ do
    it "the daemon default is the Daemon-frame variant of the host default" $ do
      -- The in-cluster default reuses the shared non-secret parameters but
      -- names the gateway daemon frame, so the host CLI and the daemon decode
      -- the same { parameters, context, witness } schema.
      Tier0.context_kind defaultDaemonContext `shouldBe` Daemon
      Tier0.binary defaultDaemonContext `shouldBe` "gateway"
      Tier0.parameters defaultDaemonProjectConfig `shouldBe` Tier0.parameters defaultProjectConfig
    it "the baked-in container default prodbox.dhall decodes to a valid Tier-0 binary context" $
      withSystemTempDirectory "prodbox-tier0-container-default" $ \tmpDir -> do
        -- No ConfigMap mount present: a freshly started container decodes its
        -- baked-in default. Emulate the on-disk container layout and decode it
        -- through the daemon's loader.
        let containerDefault = tmpDir </> "etc-prodbox" </> "prodbox.dhall"
            configMapDir = tmpDir </> "etc-gateway-config"
        createDirectoryIfMissing True (takeDirectory containerDefault)
        createDirectoryIfMissing True configMapDir
        writeFile containerDefault (Text.unpack (renderProjectConfigDhall defaultDaemonProjectConfig))
        result <- loadDaemonBinaryContext configMapDir containerDefault
        case result of
          Left err -> expectationFailure ("expected container default to decode, got: " ++ err)
          Right (source, projectConfig) -> do
            source `shouldBe` Tier0FromContainerDefault containerDefault
            projectConfig `shouldBe` defaultDaemonProjectConfig
            Tier0.context_kind (Tier0.context projectConfig) `shouldBe` Daemon
    it "the decoded daemon Tier-0 context carries no secret values" $
      withSystemTempDirectory "prodbox-tier0-daemon-secretfree" $ \tmpDir -> do
        let containerDefault = tmpDir </> "prodbox.dhall"
            configMapDir = tmpDir </> "no-configmap"
        writeFile containerDefault (Text.unpack (renderProjectConfigDhall defaultDaemonProjectConfig))
        result <- loadDaemonBinaryContext configMapDir containerDefault
        case result of
          Left err -> expectationFailure ("expected decode, got: " ++ err)
          Right (_, projectConfig) ->
            tier0CarriesNoSecretValues projectConfig `shouldBe` True
    it "the ConfigMap-derived Tier 0 overwrites the in-container default" $
      withSystemTempDirectory "prodbox-tier0-overwrite" $ \tmpDir -> do
        -- The baked-in default ships the prodbox-home cluster id; the ConfigMap
        -- supplies a distinct binary context. With both present, the loader
        -- chooses the ConfigMap (overwrite), matching hostbootstrap's per-frame
        -- context-init pattern (config_doctrine.md §0).
        let containerDefault = tmpDir </> "etc-prodbox" </> "prodbox.dhall"
            configMapDir = tmpDir </> "etc-gateway-config"
            overwritten =
              defaultDaemonProjectConfig
                { Tier0.context =
                    (Tier0.context defaultDaemonProjectConfig)
                      { Tier0.cluster_id = "prodbox-configmap-override"
                      }
                }
        createDirectoryIfMissing True (takeDirectory containerDefault)
        createDirectoryIfMissing True configMapDir
        writeFile containerDefault (Text.unpack (renderProjectConfigDhall defaultDaemonProjectConfig))
        writeFile
          (daemonConfigMapTier0Path configMapDir)
          (Text.unpack (renderProjectConfigDhall overwritten))
        result <- loadDaemonBinaryContext configMapDir containerDefault
        case result of
          Left err -> expectationFailure ("expected ConfigMap decode, got: " ++ err)
          Right (source, projectConfig) -> do
            source `shouldBe` Tier0FromConfigMap (daemonConfigMapTier0Path configMapDir)
            projectConfig `shouldBe` overwritten
            Tier0.cluster_id (Tier0.context projectConfig) `shouldBe` "prodbox-configmap-override"
    it "falls back to the compiled-in default when no file is present" $
      withSystemTempDirectory "prodbox-tier0-compiled-fallback" $ \tmpDir -> do
        let configMapDir = tmpDir </> "absent-configmap"
            containerDefault = tmpDir </> "absent-prodbox.dhall"
        result <- loadDaemonBinaryContext configMapDir containerDefault
        result `shouldBe` Right (Tier0FromCompiledDefault, defaultDaemonProjectConfig)
    it "exposes the canonical in-cluster ConfigMap Tier-0 path" $
      -- Sprint 1.49: the baked `/etc/prodbox/prodbox.dhall` container default is
      -- gone (the image generates a binary-sibling default by running the
      -- binary); only the `gateway-config-<nodeId>` ConfigMap override path
      -- remains canonical.
      daemonConfigMapTier0Path "/etc/gateway/config" `shouldBe` "/etc/gateway/config/prodbox.dhall"
  describe "in-force config envelope (Sprint 1.38)" $ do
    it "round-trips the in-force config payload through the envelope" $ do
      let payload = renderInForcePayload defaultConfigFile
      sealed <- sealInForcePayload insecureLocalDekCipher "cluster1" payload
      case sealed of
        Left err -> expectationFailure ("seal failed: " ++ show err)
        Right envelope -> do
          opened <- openInForcePayload insecureLocalDekCipher "cluster1" envelope
          opened `shouldBe` Right payload
    it "fails closed when opened under a different cluster id" $ do
      sealed <- sealInForcePayload insecureLocalDekCipher "cluster1" "in-force-bytes"
      case sealed of
        Left err -> expectationFailure ("seal failed: " ++ show err)
        Right envelope -> do
          opened <- openInForcePayload insecureLocalDekCipher "cluster2" envelope
          opened `shouldSatisfy` isLeft
    it "fails closed on a tampered envelope" $ do
      sealed <- sealInForcePayload insecureLocalDekCipher "cluster1" "in-force-bytes"
      case sealed of
        Left err -> expectationFailure ("seal failed: " ++ show err)
        Right envelope -> do
          opened <- openInForcePayload insecureLocalDekCipher "cluster1" (BS.snoc envelope 0x21)
          opened `shouldSatisfy` isLeft
    it "writes ciphertext that does not leak the config plaintext" $ do
      let payload = renderInForcePayload defaultConfigFile
      sealed <- sealInForcePayload insecureLocalDekCipher "cluster1" payload
      case sealed of
        Left err -> expectationFailure ("seal failed: " ++ show err)
        Right envelope -> BS.isInfixOf "resolvefintech" envelope `shouldBe` False
    it "decodes an in-force Dhall payload through the repository import resolver" $
      withSystemTempDirectory "prodbox-in-force-decode" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        copyFile
          (repoRoot </> "prodbox-config-types.dhall")
          (tmpDir </> "prodbox-config-types.dhall")
        decodeConfigDhallBytes tmpDir (renderInForcePayload roundTripConfigFile)
          `shouldReturn` Right roundTripConfigFile
    it "fetchInForceConfigWith fetches, opens, and decodes the in-force config" $ do
      sealed <-
        sealInForcePayload insecureLocalDekCipher "cluster1" (renderInForcePayload roundTripConfigFile)
      case sealed of
        Left err -> expectationFailure ("seal failed: " ++ show err)
        Right envelope -> do
          result <-
            fetchInForceConfigWith
              (pure (Right envelope))
              insecureLocalDekCipher
              "cluster1"
              ( \payload ->
                  pure
                    ( if payload == renderInForcePayload roundTripConfigFile
                        then Right roundTripConfigFile
                        else Left "unexpected payload"
                    )
              )
          result `shouldBe` Right roundTripConfigFile
    it "fetchInForceConfigWith maps fetch failures without decrypting" $ do
      result <-
        fetchInForceConfigWith
          (pure (Left "minio unavailable"))
          insecureLocalDekCipher
          "cluster1"
          (\_ -> pure (Right roundTripConfigFile))
      result `shouldBe` Left (InForceConfigFetchFailed "minio unavailable")
    it "storeInForceConfigWith seals and stores the in-force config envelope" $ do
      storedRef <- newIORef Nothing
      result <-
        storeInForceConfigWith
          (\envelope -> writeIORef storedRef (Just envelope) >> pure (Right ()))
          insecureLocalDekCipher
          "cluster1"
          roundTripConfigFile
      result `shouldBe` Right ()
      stored <- readIORef storedRef
      case stored of
        Nothing -> expectationFailure "expected an envelope to be stored"
        Just envelope -> do
          opened <- openInForcePayload insecureLocalDekCipher "cluster1" envelope
          opened `shouldBe` Right (renderInForcePayload roundTripConfigFile)
    it "storeInForceConfigWith maps store failures after sealing" $ do
      result <-
        storeInForceConfigWith
          (\_ -> pure (Left "bucket unavailable"))
          insecureLocalDekCipher
          "cluster1"
          roundTripConfigFile
      result `shouldBe` Left (InForceConfigStoreFailed "bucket unavailable")
    -- Sprint 1.42 PART A: the seed -> read round-trip. The seed path
    -- (storeInForceConfigWith) seals + PUTs the operator ConfigFile into a fake
    -- object store; the read path (fetchInForceConfigWith over the same fake
    -- store + decodeConfigDhallBytes) GETs + opens + decodes it back to the
    -- IDENTICAL ConfigFile. A round-trip bug here would make the SSoT object
    -- present-but-undecodable, which the production read path treats as a hard
    -- error (not the absent-fallback), so this guards the load-bearing edge.
    it "seed -> read round-trips the in-force config to the same ConfigFile" $
      withSystemTempDirectory "prodbox-in-force-seed-roundtrip" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        copyFile
          (repoRoot </> "prodbox-config-types.dhall")
          (tmpDir </> "prodbox-config-types.dhall")
        -- The fake MinIO object store: one mutable slot keyed by the opaque key.
        storeRef <- newIORef Nothing
        let put envelope = writeIORef storeRef (Just envelope) >> pure (Right ())
            get = readIORef storeRef
        -- SEED: seal + store the operator config (mirrors the reconcile seed).
        seedResult <-
          storeInForceConfigWith put insecureLocalDekCipher "cluster1" roundTripConfigFile
        seedResult `shouldBe` Right ()
        -- READ: fetch + open + decode through the same store + cipher + decoder
        -- the production read path uses, asserting the SSoT decodes back.
        readResult <-
          fetchInForceConfigWith
            (maybe (Left "in-force config object missing") Right <$> get)
            insecureLocalDekCipher
            "cluster1"
            (decodeConfigDhallBytes tmpDir)
        readResult `shouldBe` Right roundTripConfigFile
    -- Sprint 1.42 PART A: the classification PART A acts on. SSoT-absent +
    -- file-present seeds; both present is a proposed update (NOT seeded by PART
    -- A); SSoT-present (no file) is a no-op. Field semantics are explicit so the
    -- positional-constructor order can never silently invert.
    it "seedProposeDecision drives the PART A seed/no-op classification" $ do
      seedProposeDecision
        ConfigSource {configSourceFilePresent = True, configSourceInForcePresent = False}
        `shouldBe` SeedInForce
      seedProposeDecision
        ConfigSource {configSourceFilePresent = True, configSourceInForcePresent = True}
        `shouldBe` ProposeUpdate
      seedProposeDecision
        ConfigSource {configSourceFilePresent = False, configSourceInForcePresent = True}
        `shouldBe` UseInForceAsIs
      seedProposeDecision
        ConfigSource {configSourceFilePresent = False, configSourceInForcePresent = False}
        `shouldBe` NoConfigAvailable
    -- Sprint 1.42 fix: on first-ever bring-up the `prodbox-state` bucket does not
    -- exist yet, so the seed's presence probe (getObject) must read NoSuchBucket
    -- as ABSENT (-> Right Nothing -> SeedInForce -> the write creates the bucket),
    -- NOT as a hard observe failure that would abort the seal and leave the bucket
    -- forever uncreated. A credential/connection failure must NOT read as absence.
    it "classifies a NoSuchBucket response as object-absent (not a fail-closed error)" $ do
      let withStderr s = ProcessOutput (ExitFailure 1) "" s
      isNoSuchBucketOutput
        ( withStderr
            "An error occurred (NoSuchBucket) when calling the GetObject operation: The specified bucket does not exist"
        )
        `shouldBe` True
      -- A credential failure is indeterminate, NOT absence — stays fail-closed.
      isNoSuchBucketOutput
        ( withStderr
            "An error occurred (InvalidAccessKeyId) when calling the GetObject operation: The Access Key Id you provided does not exist"
        )
        `shouldBe` False
      isNoSuchBucketOutput
        (withStderr "An error occurred (NoSuchKey) when calling the GetObject operation")
        `shouldBe` False
  describe "Dhall schema generated from the Haskell source of truth (Sprint 7.17)" $ do
    it "round-trips: a default config against the GENERATED schema decodes to defaultConfigFile" $
      withSystemTempDirectory "prodbox-schema-roundtrip" $ \tmpDir -> do
        -- Write the schema text generated from the Haskell types (not the
        -- on-disk file), then author a config that imports it and overrides
        -- nothing — it must decode back to `defaultConfigFile`.
        writeFile (tmpDir </> "prodbox-config-types.dhall") (Text.unpack renderConfigTypesDhall)
        writeFile
          (tmpDir </> "prodbox.dhall")
          (wrapTier0 (unlines ["let Config = ./prodbox-config-types.dhall", "in  Config.default"]))
        result <- loadConfigFileAtPath (tmpDir </> "prodbox.dhall")
        result `shouldBe` Right defaultConfigFile
    it "round-trips: a config that overrides via Config::{ ... } + SecretRef.Vault decodes" $
      withSystemTempDirectory "prodbox-schema-roundtrip" $ \tmpDir -> do
        writeFile (tmpDir </> "prodbox-config-types.dhall") (Text.unpack renderConfigTypesDhall)
        -- Exercise the operator-facing affordances the schema must expose:
        -- the `::` completion operator, `Config.default.<section>`, and the
        -- `Config.SecretRef.Vault {...}` constructor.
        writeFile
          (tmpDir </> "prodbox.dhall")
          ( wrapTier0
              ( unlines
                  [ "let Config = ./prodbox-config-types.dhall"
                  , "in  Config::{"
                  , "    , aws = Config.default.aws // {"
                  , "        , access_key_id ="
                  , "            Config.SecretRef.Vault"
                  , "              { mount = \"secret\", path = \"gateway/gateway/aws\", field = \"access_key_id\" }"
                  , "        }"
                  , "    , route53 = { zone_id = \"Z1234567890ABC\" }"
                  , "    }"
                  ]
              )
          )
        result <- loadConfigFileAtPath (tmpDir </> "prodbox.dhall")
        case result of
          Left err -> expectationFailure ("decode failed: " ++ err)
          Right config -> zone_id (route53 config) `shouldBe` "Z1234567890ABC"
    it "round-trips: the in-force payload resolver decodes against the GENERATED schema" $
      withSystemTempDirectory "prodbox-schema-roundtrip" $ \tmpDir -> do
        writeFile (tmpDir </> "prodbox-config-types.dhall") (Text.unpack renderConfigTypesDhall)
        decodeConfigDhallBytes tmpDir (renderInForcePayload roundTripConfigFile)
          `shouldReturn` Right roundTripConfigFile
    it "round-trips: test-secrets against the GENERATED test schema decodes to defaultTestSecrets" $
      withSystemTempDirectory "prodbox-schema-roundtrip" $ \tmpDir -> do
        writeFile (tmpDir </> "test-secrets-types.dhall") (Text.unpack renderTestSecretsTypesDhall)
        writeFile
          (tmpDir </> "test-secrets.dhall")
          (unlines ["let TestSecrets = ./test-secrets-types.dhall", "in  TestSecrets.default"])
        decoded <- Dhall.inputFile Dhall.auto (tmpDir </> "test-secrets.dhall") :: IO TestSecrets
        decoded `shouldBe` defaultTestSecrets
    it "round-trips: a populated acme_eab block decodes through the GENERATED test schema" $
      withSystemTempDirectory "prodbox-schema-roundtrip-eab" $ \tmpDir -> do
        writeFile (tmpDir </> "test-secrets-types.dhall") (Text.unpack renderTestSecretsTypesDhall)
        writeFile
          (tmpDir </> "test-secrets.dhall")
          ( unlines
              [ "let TestSecrets = ./test-secrets-types.dhall"
              , "in  TestSecrets::{"
              , "    , acme_eab ="
              , "        Some { key_id = \"test-eab-key-id\", hmac_key = \"test-eab-hmac-key\" }"
              , "    }"
              ]
          )
        decoded <- Dhall.inputFile Dhall.auto (tmpDir </> "test-secrets.dhall") :: IO TestSecrets
        acme_eab decoded
          `shouldBe` Just (AcmeEabFixture {key_id = "test-eab-key-id", hmac_key = "test-eab-hmac-key"})
    it "drift guard: the committed prodbox-config-types.dhall equals the renderer output" $ do
      repoRoot <- getCurrentDirectory
      onDisk <- readFile (repoRoot </> "prodbox-config-types.dhall")
      onDisk `shouldBe` Text.unpack renderConfigTypesDhall
    it "drift guard: the committed test-secrets-types.dhall equals the renderer output" $ do
      repoRoot <- getCurrentDirectory
      onDisk <- readFile (repoRoot </> "test-secrets-types.dhall")
      onDisk `shouldBe` Text.unpack renderTestSecretsTypesDhall
  describe "ACME EAB seeding from test-secrets.dhall (Sprint 7.18)" $ do
    -- Regression guard for the ordering bug where the in-cluster EAB
    -- materializer Job read an empty `secret/acme/eab#hmac_key` because the
    -- harness seeded it too late. `seedAcmeEabFromTestSecrets` must populate the
    -- Vault object whenever it is invoked (the edge/ACME reconcile now calls it
    -- immediately before applying the materializer manifest), and must be a
    -- no-op when no `test-secrets.dhall` is present.
    let withSeededKvDir body =
          withSystemTempDirectory "prodbox-acme-eab-seed" $ \tmpDir -> do
            let kvDir = tmpDir </> "kv"
            createDirectoryIfMissing True kvDir
            originalKvDir <- lookupEnv "PRODBOX_TEST_HOST_VAULT_KV_DIR"
            let restoreEnv key previous =
                  case previous of
                    Just value -> setEnv key value
                    Nothing -> unsetEnv key
            setEnv "PRODBOX_TEST_HOST_VAULT_KV_DIR" kvDir
            body tmpDir kvDir
              `finally` restoreEnv "PRODBOX_TEST_HOST_VAULT_KV_DIR" originalKvDir
    it "seeds secret/acme/eab key_id + hmac_key from a populated acme_eab block" $
      withSeededKvDir $ \tmpDir kvDir -> do
        writeFile (tmpDir </> "test-secrets-types.dhall") (Text.unpack renderTestSecretsTypesDhall)
        writeFile
          (tmpDir </> "test-secrets.dhall")
          ( unlines
              [ "let TestSecrets = ./test-secrets-types.dhall"
              , "in  TestSecrets::{"
              , "    , acme_eab ="
              , "        Some { key_id = \"seed-eab-key-id\", hmac_key = \"seed-eab-hmac-key\" }"
              , "    }"
              ]
          )
        seedAcmeEabFromTestSecrets tmpDir
        let objectDir = kvDir </> "secret" </> "acme" </> "eab"
        readFile (objectDir </> "key_id") `shouldReturn` "seed-eab-key-id"
        readFile (objectDir </> "hmac_key") `shouldReturn` "seed-eab-hmac-key"
    it "is a no-op when test-secrets.dhall is absent (real operators seed via config setup)" $
      withSeededKvDir $ \tmpDir kvDir -> do
        seedAcmeEabFromTestSecrets tmpDir
        doesFileExist (kvDir </> "secret" </> "acme" </> "eab" </> "hmac_key")
          `shouldReturn` False
    it "is a no-op when the acme_eab block is absent (decodes to None)" $
      withSeededKvDir $ \tmpDir kvDir -> do
        writeFile (tmpDir </> "test-secrets-types.dhall") (Text.unpack renderTestSecretsTypesDhall)
        writeFile
          (tmpDir </> "test-secrets.dhall")
          (unlines ["let TestSecrets = ./test-secrets-types.dhall", "in  TestSecrets.default"])
        seedAcmeEabFromTestSecrets tmpDir
        doesFileExist (kvDir </> "secret" </> "acme" </> "eab" </> "hmac_key")
          `shouldReturn` False
  describe "operator-write gateway daemon endpoint (Sprint 1.44)" $ do
    it "routes only the two allowlisted KV logical paths" $ do
      allowedOperatorSecretPaths `shouldBe` ["acme/eab", "gateway/gateway/aws"]
      operatorSecretLogicalPath "/v1/secret/acme/eab" `shouldBe` Just "acme/eab"
      operatorSecretLogicalPath "/v1/secret/gateway/gateway/aws"
        `shouldBe` Just "gateway/gateway/aws"
    it "rejects non-allowlisted or non-secret paths (handled by the read dispatch)" $ do
      operatorSecretLogicalPath "/v1/secret/keycloak/smtp" `shouldBe` Nothing
      operatorSecretLogicalPath "/v1/secret/" `shouldBe` Nothing
      operatorSecretLogicalPath "/v1/state" `shouldBe` Nothing
      operatorSecretLogicalPath "/healthz" `shouldBe` Nothing
    it "extracts the request method verbatim (uppercase per RFC 7231)" $ do
      operatorSecretRequestMethod (BS8.pack "POST /v1/secret/acme/eab HTTP/1.1\r\n\r\n")
        `shouldBe` "POST"
      operatorSecretRequestMethod (BS8.pack "GET /v1/state HTTP/1.1\r\n\r\n")
        `shouldBe` "GET"
      operatorSecretRequestMethod (BS8.pack "") `shouldBe` "GET"
    it "extracts the operator JWT header case-insensitively, else Nothing" $ do
      operatorSecretJwtHeader
        (BS8.pack "POST /v1/secret/acme/eab HTTP/1.1\r\nX-Prodbox-Operator-Jwt: tok123\r\n\r\n")
        `shouldBe` Just "tok123"
      operatorSecretJwtHeader
        (BS8.pack "POST /v1/secret/acme/eab HTTP/1.1\r\nx-prodbox-operator-jwt:   spaced \r\n\r\n")
        `shouldBe` Just "spaced"
      operatorSecretJwtHeader
        (BS8.pack "POST /v1/secret/acme/eab HTTP/1.1\r\nContent-Type: application/json\r\n\r\n")
        `shouldBe` Nothing
    it "isolates the request body after the blank line" $ do
      requestBodyBytes
        (BS8.pack "POST /v1/secret/acme/eab HTTP/1.1\r\nContent-Length: 9\r\n\r\n{\"k\":\"v\"}")
        `shouldBe` BS8.pack "{\"k\":\"v\"}"
      requestBodyBytes (BS8.pack "POST /x HTTP/1.1\r\n\r\n") `shouldBe` BS.empty
    it "decodes a flat JSON object of string fields, rejecting empty/invalid bodies" $ do
      decodeOperatorSecretFields (BS8.pack "{\"key_id\":\"a\",\"hmac_key\":\"b\"}")
        `shouldBe` Right (Map.fromList [("key_id", "a"), ("hmac_key", "b")])
      decodeOperatorSecretFields (BS8.pack "") `shouldSatisfy` isLeft
      decodeOperatorSecretFields (BS8.pack "not json") `shouldSatisfy` isLeft
    it "names the dedicated operator-write Vault role" $
      operatorWriteRoleName `shouldBe` "prodbox-operator-write"
    it "scopes the operator-write Vault policy to exactly the two KV paths" $ do
      let policy = Text.unpack operatorWritePolicy
      policy `shouldContain` "path \"secret/data/acme/eab\""
      policy `shouldContain` "path \"secret/data/gateway/gateway/aws\""
      policy `shouldContain` "capabilities = [\"create\", \"update\"]"
      policy `shouldNotContain` "transit/"
      policy `shouldNotContain` "secret/data/clusters/"
    it "grants the gateway daemon the Pulumi object-store HMAC and Transit capabilities" $ do
      let gatewayPolicies =
            [ Text.unpack (vaultPolicySpecDocument spec)
            | spec <- vaultReconcilePolicies defaultVaultReconcilePlan
            , vaultPolicySpecName spec == "prodbox-gateway"
            ]
      case gatewayPolicies of
        [policy] -> do
          policy `shouldContain` "path \"secret/data/object-store/hmac\""
          policy `shouldContain` "path \"transit/encrypt/prodbox-pulumi-state\""
          policy `shouldContain` "path \"transit/decrypt/prodbox-pulumi-state\""
        other ->
          expectationFailure ("expected exactly one prodbox-gateway policy, got " ++ show other)
    it "binds the gateway daemon role to BOTH the object-store and event-key policies" $ do
      -- Regression guard for 44e896f: the daemon logs in under role
      -- prodbox-gateway-daemon (charts/gateway/values.yaml vault.role). That role
      -- must carry prodbox-gateway (object-store HMAC read + prodbox-pulumi-state
      -- Transit encrypt/decrypt) AND gateway-gateway (per-node event-key / gateway
      -- aws|minio KV). Missing either 403s the AWS postflight object-store read.
      case [ vaultKubernetesRoleSpecPolicies spec
           | spec <- vaultReconcileKubernetesRoles defaultVaultReconcilePlan
           , vaultKubernetesRoleSpecName spec == vaultRoleIdText VaultRoleGatewayDaemon
           ] of
        [policies] ->
          sort policies `shouldBe` ["gateway-gateway", "prodbox-gateway"]
        other ->
          expectationFailure ("expected exactly one prodbox-gateway-daemon role, got " ++ show other)
    it "builds the operator-secret URL on the loopback gateway endpoint" $ do
      let endpoint = Prodbox.Gateway.Client.hostLoopbackGatewayEndpoint 30443
      Prodbox.Gateway.Client.operatorSecretUrl endpoint "acme/eab"
        `shouldBe` "http://127.0.0.1:30443/v1/secret/acme/eab"
  describe "pre-Vault daemon bootstrap endpoint (Sprint 2.29)" $ do
    let requestFor path method body =
          BS8.pack
            ( method
                ++ " "
                ++ path
                ++ " HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: "
                ++ show (length body)
                ++ "\r\n\r\n"
                ++ body
            )
        bootstrapRequest = requestFor bootstrapVaultPath "POST"
    it "decodes a bounded password-bearing request only with loopback proof" $ do
      decodeBootstrapVaultRequest
        (bootstrapRequest "{\"unlock_password\":\"pw\",\"loopback_nodeport_verified\":true}")
        `shouldBe` Right (BootstrapVaultRequest "pw" True)
      decodeBootstrapVaultRequest
        (bootstrapRequest "{\"unlock_password\":\"pw\",\"loopback_nodeport_verified\":false}")
        `shouldBe` Left BootstrapVaultLoopbackUnverified
    it "rejects unsupported methods, empty passwords, and oversized bodies before actions" $ do
      decodeBootstrapVaultRequest
        (BS8.pack ("GET " ++ bootstrapVaultPath ++ " HTTP/1.1\r\n\r\n"))
        `shouldBe` Left (BootstrapVaultMethodNotAllowed "GET")
      decodeBootstrapVaultRequest
        (bootstrapRequest "{\"unlock_password\":\"   \",\"loopback_nodeport_verified\":true}")
        `shouldBe` Left BootstrapVaultPasswordEmpty
      decodeBootstrapVaultRequest
        (bootstrapRequest (replicate (bootstrapVaultRequestMaxBytes + 1) 'x'))
        `shouldBe` Left (BootstrapVaultRequestTooLarge (bootstrapVaultRequestMaxBytes + 1))
    it "redacts the unlock password in Show and request error rendering" $ do
      show (BootstrapVaultRequest "super-secret-password" True)
        `shouldNotContain` "super-secret-password"
      renderBootstrapVaultRequestError BootstrapVaultLoopbackUnverified
        `shouldNotContain` "super-secret-password"
    it "builds the bootstrap URL on the loopback gateway endpoint" $ do
      let endpoint = Prodbox.Gateway.Client.hostLoopbackGatewayEndpoint 30443
      Prodbox.Gateway.Client.bootstrapVaultUrl endpoint
        `shouldBe` "http://127.0.0.1:30443/v1/bootstrap/vault/ensure"
    it "decodes authenticated daemon lifecycle actions with the same loopback proof" $ do
      decodeBootstrapVaultAuthenticatedRequest
        ( requestFor
            bootstrapVaultSealPath
            "POST"
            "{\"unlock_password\":\"pw\",\"loopback_nodeport_verified\":true}"
        )
        `shouldBe` Right (BootstrapVaultRequest "pw" True)
      decodeBootstrapVaultAuthenticatedRequest
        ( requestFor
            bootstrapVaultPkiStatusPath
            "GET"
            "{\"unlock_password\":\"pw\",\"loopback_nodeport_verified\":true}"
        )
        `shouldBe` Left (BootstrapVaultMethodNotAllowed "GET")
      bootstrapVaultStatusPath `shouldBe` "/v1/bootstrap/vault/status"
      bootstrapVaultPkiIssueTestCertPath `shouldBe` "/v1/bootstrap/vault/pki/issue-test-cert"
    it "decodes bundle and transit rotation requests without showing passwords" $ do
      let rotateBundle =
            decodeBootstrapVaultRotateUnlockBundleRequest
              ( requestFor
                  bootstrapVaultRotateUnlockBundlePath
                  "POST"
                  "{\"unlock_password\":\"old\",\"new_unlock_password\":\"new\",\"loopback_nodeport_verified\":true}"
              )
          rotateTransit =
            decodeBootstrapVaultRotateTransitKeyRequest
              ( requestFor
                  bootstrapVaultRotateTransitKeyPath
                  "POST"
                  "{\"unlock_password\":\"pw\",\"key_name\":\"pulumi\",\"loopback_nodeport_verified\":true}"
              )
      rotateBundle `shouldBe` Right (BootstrapVaultRotateUnlockBundleRequest "old" "new" True)
      rotateTransit `shouldBe` Right (BootstrapVaultRotateTransitKeyRequest "pw" "pulumi" True)
      show (BootstrapVaultRotateUnlockBundleRequest "old-secret" "new-secret" True)
        `shouldNotContain` "old-secret"
      show (BootstrapVaultRotateUnlockBundleRequest "old-secret" "new-secret" True)
        `shouldNotContain` "new-secret"
      show (BootstrapVaultRotateTransitKeyRequest "pw-secret" "pulumi" True)
        `shouldNotContain` "pw-secret"
    it "routes host lifecycle through daemon unless only an explicit test seam is available" $ do
      let refusesDirectHostFallback decision =
            case decision of
              RefuseDirectHostVaultFallback msg ->
                "Refusing direct host Vault/MinIO fallback" `isInfixOf` msg
              _ -> False
      vaultLifecycleTransportDecision VaultDaemonReachable HostVaultDirectSeamAbsent
        `shouldBe` UseDaemonVaultLifecycle
      vaultLifecycleTransportDecision
        (VaultDaemonUnavailable "connection refused")
        HostVaultDirectSeamPresent
        `shouldBe` UseDirectHostVaultTestSeam
      vaultLifecycleTransportDecision
        (VaultDaemonUnavailable "connection refused")
        HostVaultDirectSeamAbsent
        `shouldSatisfy` refusesDirectHostFallback
      gatewayProbeFromResult (Right (object [] :: Value)) `shouldBe` VaultDaemonReachable
      gatewayProbeFromResult
        ( Left
            ( Prodbox.Gateway.Client.GatewayTransport
                (Prodbox.Http.Client.HttpConnectionFailure "connection refused")
            )
            :: Either Prodbox.Gateway.Client.GatewayError Value
        )
        `shouldBe` VaultDaemonUnavailable "connection refused"
      gatewayProbeFromResult
        ( Left
            (Prodbox.Gateway.Client.GatewayTransport (Prodbox.Http.Client.HttpStatus 503 "sealed"))
            :: Either Prodbox.Gateway.Client.GatewayError Value
        )
        `shouldBe` VaultDaemonReachable
  describe "daemon-mediated Vault retry (transient restart bridge)" $ do
    let fastRetryPolicy =
          RetryPolicy
            { retryPolicyMaxAttempts = 4
            , retryPolicyBaseDelayMicros = 1000
            , retryPolicyMultiplier = 1
            , retryPolicyMaxDelayMicros = 1000
            }
    it "gatewayErrorIsTransient: only dropped connections / timeouts are bridgeable transients" $ do
      Prodbox.Gateway.Client.gatewayErrorIsTransient
        ( Prodbox.Gateway.Client.GatewayTransport
            (Prodbox.Http.Client.HttpConnectionFailure "NoResponseDataReceived")
        )
        `shouldBe` True
      Prodbox.Gateway.Client.gatewayErrorIsTransient
        (Prodbox.Gateway.Client.GatewayTransport (Prodbox.Http.Client.HttpTimeout "response timeout"))
        `shouldBe` True
      Prodbox.Gateway.Client.gatewayErrorIsTransient
        (Prodbox.Gateway.Client.GatewayTransport (Prodbox.Http.Client.HttpStatus 500 "boom"))
        `shouldBe` False
      Prodbox.Gateway.Client.gatewayErrorIsTransient (Prodbox.Gateway.Client.GatewayPayload "bad json")
        `shouldBe` False
    it "retryDaemonTransient: bridges a mid-restart NoResponseDataReceived then succeeds" $ do
      callsRef <- newIORef (0 :: Int)
      let action = do
            modifyIORef' callsRef (+ 1)
            n <- readIORef callsRef
            pure $
              if n < 3
                then
                  Left
                    ( Prodbox.Gateway.Client.GatewayTransport
                        (Prodbox.Http.Client.HttpConnectionFailure "NoResponseDataReceived")
                    )
                else Right ("ready" :: String)
      result <- retryDaemonTransient fastRetryPolicy "test" action
      result `shouldBe` Right "ready"
      readIORef callsRef `shouldReturn` 3
    it "retryDaemonTransient: fails fast on a non-transient gateway error (no retry)" $ do
      callsRef <- newIORef (0 :: Int)
      let action = do
            modifyIORef' callsRef (+ 1)
            pure
              ( Left
                  (Prodbox.Gateway.Client.GatewayTransport (Prodbox.Http.Client.HttpStatus 400 "rejected"))
                  :: Either Prodbox.Gateway.Client.GatewayError String
              )
      result <- retryDaemonTransient fastRetryPolicy "test" action
      result
        `shouldBe` Left
          (Prodbox.Gateway.Client.GatewayTransport (Prodbox.Http.Client.HttpStatus 400 "rejected"))
      readIORef callsRef `shouldReturn` 1
    it "retryDaemonTransient: exhausts the attempt budget on a persistent transient" $ do
      callsRef <- newIORef (0 :: Int)
      let action = do
            modifyIORef' callsRef (+ 1)
            pure
              ( Left
                  (Prodbox.Gateway.Client.GatewayTransport (Prodbox.Http.Client.HttpConnectionFailure "down"))
                  :: Either Prodbox.Gateway.Client.GatewayError String
              )
      _ <- retryDaemonTransient fastRetryPolicy "test" action
      readIORef callsRef `shouldReturn` retryPolicyMaxAttempts fastRetryPolicy
    it "retryGatewayTransient (shared): bridges a Connection-refused restart window then succeeds" $ do
      okRef <- newIORef (0 :: Int)
      let okAction = do
            modifyIORef' okRef (+ 1)
            n <- readIORef okRef
            pure $
              if n < 2
                then
                  Left
                    ( Prodbox.Gateway.Client.GatewayTransport
                        (Prodbox.Http.Client.HttpConnectionFailure "Connection refused")
                    )
                else Right ("ok" :: String)
      okResult <- Prodbox.Gateway.Client.retryGatewayTransient fastRetryPolicy okAction
      okResult `shouldBe` Right "ok"
      readIORef okRef `shouldReturn` 2
    it "retryGatewayTransient (shared): fails fast on a non-transient status (no retry)" $ do
      hardRef <- newIORef (0 :: Int)
      let hardAction = do
            modifyIORef' hardRef (+ 1)
            pure
              ( Left
                  (Prodbox.Gateway.Client.GatewayTransport (Prodbox.Http.Client.HttpStatus 409 "conflict"))
                  :: Either Prodbox.Gateway.Client.GatewayError String
              )
      _ <- Prodbox.Gateway.Client.retryGatewayTransient fastRetryPolicy hardAction
      readIORef hardRef `shouldReturn` 1
  describe "daemon Pulumi object-store endpoint (Sprint 7.30)" $ do
    let requestFor path method body =
          BS8.pack
            ( method
                ++ " "
                ++ path
                ++ " HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: "
                ++ show (length body)
                ++ "\r\n\r\n"
                ++ body
            )
        objectRequest = requestFor pulumiObjectGetPath "POST"
    it "decodes bounded get/delete requests only with loopback proof and valid stack names" $ do
      decodePulumiObjectRequest
        (objectRequest "{\"stack\":\"aws-eks-test\",\"loopback_nodeport_verified\":true}")
        `shouldBe` Right (PulumiObjectRequest "aws-eks-test" True)
      decodePulumiObjectRequest
        (objectRequest "{\"stack\":\"aws-eks-test\",\"loopback_nodeport_verified\":false}")
        `shouldBe` Left PulumiObjectLoopbackUnverified
      decodePulumiObjectRequest
        (objectRequest "{\"stack\":\"../aws\",\"loopback_nodeport_verified\":true}")
        `shouldBe` Left
          ( PulumiObjectStackInvalid
              "stack may contain only ASCII letters, digits, '.', '_', and '-'"
          )
      validatePulumiObjectStackName " aws-test "
        `shouldBe` Right "aws-test"
    it "rejects unsupported methods, empty bodies, malformed JSON, and oversized bodies" $ do
      decodePulumiObjectRequest
        (BS8.pack ("GET " ++ pulumiObjectGetPath ++ " HTTP/1.1\r\n\r\n"))
        `shouldBe` Left (PulumiObjectMethodNotAllowed "GET")
      decodePulumiObjectRequest
        (objectRequest "")
        `shouldBe` Left PulumiObjectRequestEmpty
      decodePulumiObjectRequest
        (objectRequest "not json")
        `shouldSatisfy` isLeft
      decodePulumiObjectRequest
        (objectRequest (replicate (pulumiObjectRequestMaxBytes + 1) 'x'))
        `shouldBe` Left (PulumiObjectRequestTooLarge (pulumiObjectRequestMaxBytes + 1))
    it "round-trips put/get JSON while redacting checkpoint bytes from Show" $ do
      let checkpoint = BS8.pack "checkpoint-secret"
          putRequest = PulumiObjectPutRequest "aws-test" checkpoint True
          putWire = requestFor pulumiObjectPutPath "POST" (BL8.unpack (encode putRequest))
      decodePulumiObjectPutRequest putWire `shouldBe` Right putRequest
      show putRequest `shouldNotContain` "checkpoint-secret"
      (eitherDecode (encode PulumiObjectAbsent) :: Either String PulumiObjectGetResponse)
        `shouldBe` Right PulumiObjectAbsent
      ( eitherDecode (encode (PulumiObjectPresent checkpoint))
          :: Either String PulumiObjectGetResponse
        )
        `shouldBe` Right (PulumiObjectPresent checkpoint)
    it "renders request errors without checkpoint material" $ do
      renderPulumiObjectRequestError PulumiObjectLoopbackUnverified
        `shouldContain` "loopback NodePort"
      renderPulumiObjectRequestError PulumiObjectLoopbackUnverified
        `shouldNotContain` "checkpoint-secret"
    it "builds daemon object-store URLs on the loopback gateway endpoint" $ do
      let endpoint = Prodbox.Gateway.Client.hostLoopbackGatewayEndpoint 30443
      Prodbox.Gateway.Client.pulumiObjectGetUrl endpoint
        `shouldBe` "http://127.0.0.1:30443/v1/object-store/pulumi/get"
      Prodbox.Gateway.Client.pulumiObjectPutUrl endpoint
        `shouldBe` "http://127.0.0.1:30443/v1/object-store/pulumi/put"
      Prodbox.Gateway.Client.pulumiObjectDeleteUrl endpoint
        `shouldBe` "http://127.0.0.1:30443/v1/object-store/pulumi/delete"
  describe "Model B object store (Sprint 4.30)" $ do
    it "uses one generic bucket name for object-store and Pulumi backend paths" $ do
      defaultObjectStoreBucket `shouldBe` "prodbox-state"
      minioBackendBucket `shouldBe` defaultObjectStoreBucket
      defaultObjectStoreBucket `shouldNotBe` "prodbox-test-pulumi-backends"
    it "routes gateway MinIO bootstrap to the same generic bucket" $ do
      repoRoot <- getCurrentDirectory
      source <- readFile (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Rke2.hs")
      source `shouldContain` "gatewayMinioBucket = \"prodbox-state\""
      source `shouldContain` "s3:DeleteObject"
      source `shouldNotContain` "gatewayMinioBucket = \"prodbox\""
    it "builds typed bucket lifecycle commands for the object-store bucket" $ do
      objectStoreHeadBucketArgs "http://127.0.0.1:39000" defaultObjectStoreBucket
        `shouldBe` [ "--endpoint-url"
                   , "http://127.0.0.1:39000"
                   , "s3api"
                   , "head-bucket"
                   , "--bucket"
                   , "prodbox-state"
                   ]
      objectStoreCreateBucketArgs "http://127.0.0.1:39000" defaultObjectStoreBucket
        `shouldBe` [ "--endpoint-url"
                   , "http://127.0.0.1:39000"
                   , "s3api"
                   , "create-bucket"
                   , "--bucket"
                   , "prodbox-state"
                   ]
    it "writes prodbox-envelope-v2 with hashed stored AAD, not the cleartext binding" $ do
      envelopeResult <- sealEnvelope insecureLocalDekCipher "cluster1|aws-eks" "secret payload"
      case envelopeResult of
        Left err -> expectationFailure ("seal failed: " ++ show err)
        Right envelope -> do
          BS.isInfixOf "cluster1|aws-eks" envelope `shouldBe` False
          case eitherDecode (BL.fromStrict envelope) of
            Left err -> expectationFailure ("envelope JSON decode failed: " ++ err)
            Right (Object decoded) -> do
              KeyMap.lookup (Key.fromString "format") decoded
                `shouldBe` Just (String "prodbox-envelope-v2")
              KeyMap.lookup (Key.fromString "transit_key") decoded `shouldSatisfy` (/= Nothing)
              KeyMap.lookup (Key.fromString "created_at") decoded `shouldSatisfy` (/= Nothing)
              KeyMap.lookup (Key.fromString "key_version") decoded `shouldSatisfy` (/= Nothing)
            Right _ -> expectationFailure "expected envelope JSON object"
    it "derives deterministic opaque object keys that carry no logical name" $ do
      let firstKey = objectKeyForOpaqueId (opaqueObjectId "vault-hmac-key" LogicalInForceConfig)
          secondKey = objectKeyForOpaqueId (opaqueObjectId "vault-hmac-key" LogicalInForceConfig)
      firstKey `shouldBe` secondKey
      firstKey `shouldSatisfy` Text.isPrefixOf "objects/"
      firstKey `shouldSatisfy` Text.isSuffixOf ".enc"
      Text.unpack firstKey `shouldNotContain` "in-force"
    it "stores and fetches a logical object through injected opaque object IO" $ do
      storeRef <- newIORef Map.empty
      putResult <-
        putLogicalWith
          (\key bytes -> modifyIORef' storeRef (Map.insert key bytes) >> pure (Right ()))
          insecureLocalDekCipher
          "vault-hmac-key"
          "cluster1"
          LogicalInForceConfig
          "in-force payload"
      putResult `shouldBe` Right ()
      let expectedKey = objectKeyForOpaqueId (opaqueObjectId "vault-hmac-key" LogicalInForceConfig)
      stored <- readIORef storeRef
      Map.keys stored `shouldBe` [expectedKey]
      fetchResult <-
        getLogicalWith
          (\key -> pure (Right (Map.lookup key stored)))
          insecureLocalDekCipher
          "vault-hmac-key"
          "cluster1"
          LogicalInForceConfig
      fetchResult `shouldBe` Right "in-force payload"
    it "fails closed when a logical object is opened under the wrong cluster AAD" $ do
      storeRef <- newIORef Map.empty
      putResult <-
        putLogicalWith
          (\key bytes -> modifyIORef' storeRef (Map.insert key bytes) >> pure (Right ()))
          insecureLocalDekCipher
          "vault-hmac-key"
          "cluster1"
          LogicalInForceConfig
          "in-force payload"
      putResult `shouldBe` Right ()
      stored <- readIORef storeRef
      fetchResult <-
        getLogicalWith
          (\key -> pure (Right (Map.lookup key stored)))
          insecureLocalDekCipher
          "vault-hmac-key"
          "cluster2"
          LogicalInForceConfig
      fetchResult `shouldBe` Left (EncryptedObjectOpenFailed EnvelopeAuthFailed)
    it "round-trips a per-run Pulumi stack object across daemon-shape params (host-direct byte-compat)" $ do
      -- The host-direct fallback GET must open an envelope a daemon PUT sealed:
      -- same HMAC key, clusterId, and LogicalPulumiStack name (transit cipher is
      -- fixed here). A clusterId mismatch (AAD) must fail closed.
      storeRef <- newIORef Map.empty
      putResult <-
        putLogicalWith
          (\key bytes -> modifyIORef' storeRef (Map.insert key bytes) >> pure (Right ()))
          insecureLocalDekCipher
          "object-store-hmac"
          "prodbox-home"
          (LogicalPulumiStack "aws-eks-test")
          "{\"version\":3,\"checkpoint\":{}}"
      putResult `shouldBe` Right ()
      stored <- readIORef storeRef
      okResult <-
        getLogicalWith
          (\key -> pure (Right (Map.lookup key stored)))
          insecureLocalDekCipher
          "object-store-hmac"
          "prodbox-home"
          (LogicalPulumiStack "aws-eks-test")
      okResult `shouldBe` Right "{\"version\":3,\"checkpoint\":{}}"
      mismatchResult <-
        getLogicalWith
          (\key -> pure (Right (Map.lookup key stored)))
          insecureLocalDekCipher
          "object-store-hmac"
          "prodbox-other"
          (LogicalPulumiStack "aws-eks-test")
      mismatchResult `shouldBe` Left (EncryptedObjectOpenFailed EnvelopeAuthFailed)
    it "round-trips the Vault-encrypted index payload shape" $ do
      let index = Map.fromList [("objects/opaque.enc", "in-force-config")]
      decodeIndex (encodeIndex index) `shouldBe` Right index
    it "builds a fixed decoy key pool under the opaque object prefix" $ do
      decoyObjectKeys 3
        `shouldBe` [ "objects/decoy-0001.enc"
                   , "objects/decoy-0002.enc"
                   , "objects/decoy-0003.enc"
                   ]
  describe "config seed/propose (Sprint 1.38)" $ do
    it "seeds the in-force SSoT when only the file is present" $ do
      seedProposeDecision (ConfigSource True False) `shouldBe` SeedInForce
    it "treats the file as a proposed update when both are present" $ do
      seedProposeDecision (ConfigSource True True) `shouldBe` ProposeUpdate
    it "uses the in-force SSoT as-is when only it is present" $ do
      seedProposeDecision (ConfigSource False True) `shouldBe` UseInForceAsIs
    it "reports no config available when neither is present" $ do
      seedProposeDecision (ConfigSource False False) `shouldBe` NoConfigAvailable
    it "uses the filesystem config as the first-bring-up seed when not established" $
      withSystemTempDirectory "prodbox-config-loader" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        copyFile
          (repoRoot </> "prodbox-config-types.dhall")
          (tmpDir </> "prodbox-config-types.dhall")
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 (renderConfigDhall roundTripConfigFile))
        -- Pure seed-decode layer (Sprint 1.48): the not-established branch reads
        -- the Tier-0 `parameters` seed via `loadConfigFile`, exercised here
        -- through its path seam (`loadConfigFileAtPath`). The not-established
        -- branch selection itself is covered by the `seedProposeDecision` tests
        -- above; the binary-sibling resolution is proven by the integration suite.
        result <- loadConfigFileAtPath (tmpDir </> "prodbox.dhall")
        result `shouldBe` Right roundTripConfigFile
    it "uses the in-force config loader once the cluster is established" $
      withSystemTempDirectory "prodbox-config-loader" $ \tmpDir -> do
        -- The default Tier-0 record projects to the root floor (prodbox-home,
        -- shamir, no parent) == sampleRootBasics. Sprint 1.42 Part B / Sprint
        -- 7.25: the "established" signal is the presence of the non-secret
        -- cluster-established marker (the bundle itself is now MinIO-only), which
        -- flips the loader from the seed/propose Tier-0 `parameters` read to the
        -- encrypted in-force SSoT.
        withBinarySiblingTier0 (Text.unpack (renderProjectConfigDhall defaultProjectConfig)) $ do
          createDirectoryIfMissing True (takeDirectory (tmpDir </> clusterEstablishedMarkerRelPath))
          writeFile (tmpDir </> clusterEstablishedMarkerRelPath) "established"
          result <-
            loadConfigForSettingsWith
              (\basics -> basics `shouldBe` sampleRootBasics >> pure (Right roundTripConfigFile))
              tmpDir
          result `shouldBe` Right roundTripConfigFile
  describe "root-config write authority (Sprint 1.38)" $ do
    it "blocks a root-cluster config write with no root token" $ do
      rootConfigWriteDecision (RootWriteAuthority True False)
        `shouldBe` RootWriteBlockNoRootToken
    it "renders a fail-closed message for the blocked root write" $ do
      case renderRootConfigWriteBlock (rootConfigWriteDecision (RootWriteAuthority True False)) of
        Nothing -> expectationFailure "expected a fail-closed block message"
        Just msg -> do
          msg `shouldContain` "root"
          msg `shouldContain` "No write was started"
    it "allows a root-cluster config write with a root token" $ do
      rootConfigWriteDecision (RootWriteAuthority True True) `shouldBe` RootWriteAllow
    it "allows a child-cluster config write without a root token" $ do
      rootConfigWriteDecision (RootWriteAuthority False False) `shouldBe` RootWriteAllow
  describe "cluster federation custody (Sprint 2.26)" $ do
    it "derives parent-owned Vault KV paths for child metadata and init custody" $ do
      childMetadataKvPath "Child A" `shouldBe` "secret/data/clusters/child-a/metadata"
      childInitKvPath "Child A" `shouldBe` "secret/data/clusters/child-a/init"
      childMetadataKvLogicalPath "Child A" `shouldBe` "clusters/child-a/metadata"
      childInitKvLogicalPath "Child A" `shouldBe` "clusters/child-a/init"
    it "derives opaque child namespace and Transit key names" $ do
      let plan = childRegistrationPlan "root-owned-federation-key" "child-prod"
          namespace = childRegistrationVaultNamespace plan
          transitKey = childRegistrationTransitKey plan
      childRegistrationMetadataPath plan `shouldBe` "secret/data/clusters/child-prod/metadata"
      childRegistrationInitPath plan `shouldBe` "secret/data/clusters/child-prod/init"
      namespace `shouldSatisfy` Text.isPrefixOf "ns-"
      transitKey `shouldSatisfy` Text.isPrefixOf "prodbox-child-"
      Text.unpack namespace `shouldNotContain` "child-prod"
      Text.unpack transitKey `shouldNotContain` "child-prod"
      childVaultNamespace "root-owned-federation-key" "child-prod" `shouldBe` namespace
      childTransitKeyName "root-owned-federation-key" "child-prod" `shouldBe` transitKey
    it "Sprint 4.33 redacts token-bearing federation Show instances" $ do
      let initCustody =
            ChildInitCustody
              { childInitClusterId = "child-prod"
              , childInitRecoveryKeysBase64 = ["recovery-a"]
              , childInitRootToken = "s.child-root"
              , childInitTransitKey = "prodbox-child-abcd"
              }
          bootstrapCredential =
            ChildBootstrapCredential
              { childBootstrapClusterId = "child-prod"
              , childBootstrapParentVaultAddress = "https://vault.parent.example"
              , childBootstrapTransitKey = "prodbox-child-abcd"
              , childBootstrapVaultNamespace = "ns-abcd"
              , childBootstrapToken = "s.child-transit"
              }
      show initCustody `shouldNotContain` "s.child-root"
      show initCustody `shouldNotContain` "recovery-a"
      show bootstrapCredential `shouldNotContain` "s.child-transit"
      show (VaultToken "s.root") `shouldBe` "VaultToken <redacted>"
    it "round-trips child metadata and init custody through Vault KV JSON payloads" $ do
      let metadata =
            ChildMetadata
              { childMetadataClusterId = "child-prod"
              , childMetadataVaultAddress = "https://vault.child-prod.example"
              , childMetadataTransitKey = "prodbox-child-abcd"
              , childMetadataVaultNamespace = "ns-abcd"
              , childMetadataParentClusterId = "root-prod"
              , childMetadataEndpoints = Map.fromList [("api", "https://api.child-prod.example")]
              , childMetadataKubeconfigReference = Just "vault:secret/clusters/child-prod/kubeconfig"
              , childMetadataAccountId = Just "123456789012"
              , childMetadataPulumiStacks = Map.fromList [("aws-eks", "org/prodbox-child-prod/aws-eks")]
              }
          initCustody =
            ChildInitCustody
              { childInitClusterId = "child-prod"
              , childInitRecoveryKeysBase64 = ["recovery-a", "recovery-b"]
              , childInitRootToken = "s.child-root"
              , childInitTransitKey = "prodbox-child-abcd"
              }
      decodeChildMetadata (encodeChildMetadata metadata) `shouldBe` Right metadata
      decodeChildInitCustody (encodeChildInitCustody initCustody) `shouldBe` Right initCustody
      Map.lookup "payload_json" (childMetadataVaultFields metadata)
        `shouldSatisfy` maybe False (Text.isInfixOf "child-prod")
      Map.lookup "payload_json" (childMetadataVaultFields metadata)
        `shouldSatisfy` maybe False (Text.isInfixOf "kubeconfig_reference")
      childMetadataEndpoints metadata
        `shouldBe` Map.fromList [("api", "https://api.child-prod.example")]
      childMetadataPulumiStacks metadata
        `shouldBe` Map.fromList [("aws-eks", "org/prodbox-child-prod/aws-eks")]
      BS.isInfixOf "s.child-root" (encodeChildMetadata metadata) `shouldBe` False
      BS.isInfixOf "s.child-root" (encodeChildInitCustody initCustody) `shouldBe` True
    it "stores child bootstrap credentials and child indexes as parent Vault KV payloads" $ do
      let credential =
            ChildBootstrapCredential
              { childBootstrapClusterId = "child-prod"
              , childBootstrapParentVaultAddress = "https://vault.parent.example"
              , childBootstrapTransitKey = "prodbox-child-abcd"
              , childBootstrapVaultNamespace = "ns-abcd"
              , childBootstrapToken = "s.child-transit"
              }
          index = upsertChildIndex "child-prod" (ChildIndex ["child-dev"])
      childBootstrapKvPath "Child Prod" `shouldBe` "secret/data/clusters/child-prod/bootstrap"
      childBootstrapKvLogicalPath "Child Prod" `shouldBe` "clusters/child-prod/bootstrap"
      federationChildrenIndexKvPath `shouldBe` "secret/data/clusters/index"
      federationChildrenIndexKvLogicalPath `shouldBe` "clusters/index"
      decodeChildBootstrapCredential (encodeChildBootstrapCredential credential)
        `shouldBe` Right credential
      decodePayloadJsonField decodeChildBootstrapCredential (childBootstrapVaultFields credential)
        `shouldBe` Right credential
      decodeChildIndex (encodeChildIndex index)
        `shouldBe` Right (ChildIndex ["child-dev", "child-prod"])
      decodePayloadJsonField decodeChildIndex (childIndexVaultFields index)
        `shouldBe` Right (ChildIndex ["child-dev", "child-prod"])
    it "keeps unencrypted root basics free of downstream cluster inventory" $ do
      let encodedBasics = basicsToJson sampleRootBasics
      BS.isInfixOf "child-prod" encodedBasics `shouldBe` False
      BS.isInfixOf "initial_root_token" encodedBasics `shouldBe` False
      BS.isInfixOf "recovery_keys_base64" encodedBasics `shouldBe` False
    it "renders a registration surface that is live once child bootstrap inputs are supplied" $ do
      let rendered =
            renderChildRegistrationPlan
              (childRegistrationPlan "root-owned-federation-key" "child-prod")
      rendered `shouldContain` "CLUSTER_FEDERATION_REGISTER_PLAN"
      rendered `shouldContain` "metadata_kv_path=secret/data/clusters/child-prod/metadata"
      rendered `shouldContain` "init_kv_path=secret/data/clusters/child-prod/init"
      rendered `shouldContain` "bootstrap_kv_path=secret/data/clusters/child-prod/bootstrap"
      rendered `shouldContain` "children_index_kv_path=secret/data/clusters/index"
      rendered
        `shouldContain` "apply_status=ready_when_child_vault_address_and_child_kubeconfig_are_supplied"
    it "renders a child seal token policy scoped to one Transit key and one init path" $ do
      let policy = Text.unpack (childTransitSealPolicyDocument "Child A" "prodbox-child-opaque")
      policy `shouldContain` "path \"transit/encrypt/prodbox-child-opaque\""
      policy `shouldContain` "path \"transit/decrypt/prodbox-child-opaque\""
      policy `shouldContain` "path \"secret/data/clusters/child-a/init\""
      policy `shouldNotContain` "clusters/*"
    it "blocks root-cluster federation writes without the root token" $ do
      federationWriteDecision (FederationWriteAuthority True False)
        `shouldBe` FederationWriteBlockNoRootToken
      case renderFederationWriteBlock (federationWriteDecision (FederationWriteAuthority True False)) of
        Nothing -> expectationFailure "expected a fail-closed block message"
        Just msg -> do
          msg `shouldContain` "root Vault token"
          msg `shouldContain` "No child metadata"
    it "allows federation writes once root authority is present, and does not gate child-local reads" $ do
      federationWriteDecision (FederationWriteAuthority True True) `shouldBe` FederationWriteAllow
      federationWriteDecision (FederationWriteAuthority False False) `shouldBe` FederationWriteAllow
  describe "vault envelope (Sprint 3.17)" $ do
    it "round-trips an envelope under the bound AAD" $ do
      sealed <- sealEnvelope insecureLocalDekCipher "cluster1|active-config" "the-secret-bytes"
      case sealed of
        Left err -> expectationFailure ("seal failed: " ++ show err)
        Right envelope -> do
          opened <- openEnvelope insecureLocalDekCipher "cluster1|active-config" envelope
          opened `shouldBe` Right "the-secret-bytes"
    it "fails closed when opened under a different AAD" $ do
      sealed <- sealEnvelope insecureLocalDekCipher "cluster1|active-config" "the-secret-bytes"
      case sealed of
        Left err -> expectationFailure ("seal failed: " ++ show err)
        Right envelope -> do
          opened <- openEnvelope insecureLocalDekCipher "cluster1|WRONG-object" envelope
          opened `shouldBe` Left EnvelopeAuthFailed
    it "rejects a tampered envelope" $ do
      sealed <- sealEnvelope insecureLocalDekCipher "cluster1|active-config" "the-secret-bytes"
      case sealed of
        Left err -> expectationFailure ("seal failed: " ++ show err)
        Right envelope -> do
          opened <- openEnvelope insecureLocalDekCipher "cluster1|active-config" (BS.snoc envelope 0x21)
          opened `shouldSatisfy` isLeft
    it "writes ciphertext that does not leak the plaintext" $ do
      sealed <- sealEnvelope insecureLocalDekCipher "cluster1|active-config" "the-secret-bytes"
      case sealed of
        Left err -> expectationFailure ("seal failed: " ++ show err)
        Right envelope -> BS.isInfixOf "the-secret-bytes" envelope `shouldBe` False
  describe "secret references (Sprint 1.35)" $ do
    it "flags a plaintext literal as plaintext" $ do
      secretRefIsPlaintext (SecretRefTestPlaintext "AKIAEXAMPLE") `shouldBe` True
    it "does not flag a Vault reference as plaintext" $ do
      secretRefIsPlaintext (SecretRefVault (VaultSecretRef "kv" "prodbox/aws/admin" "access_key_id"))
        `shouldBe` False
    it "rejects a plaintext literal in production config" $ do
      validateProductionSecretRef (SecretRefTestPlaintext "AKIAEXAMPLE")
        `shouldBe` Left SecretRefPlaintextInProduction
    it "accepts a Vault reference in production config" $ do
      validateProductionSecretRef (SecretRefVault (VaultSecretRef "kv" "p" "f")) `shouldBe` Right ()
    it "resolves a test-plaintext only in the test harness" $ do
      resolveSecretRef TestHarnessMode (SecretRefTestPlaintext "v") `shouldReturn` Right "v"
    it "refuses to resolve a test-plaintext on the production path" $ do
      resolveSecretRef ProductionMode (SecretRefTestPlaintext "v")
        `shouldReturn` Left SecretRefPlaintextInProduction
    it "fails loud resolving a Vault reference before the read path is wired" $ do
      resolveSecretRef ProductionMode (SecretRefVault (VaultSecretRef "kv" "p" "f"))
        `shouldReturn` Left SecretRefVaultUnavailable
    it "resolves a Vault reference through the injected Vault reader" $ do
      let ref = VaultSecretRef "kv" "prodbox/aws/admin" "access_key_id"
      resolveSecretRefWithVault
        ProductionMode
        ( \candidate -> pure (if candidate == ref then Right "AKIAEXAMPLE" else Left SecretRefVaultFieldMissing)
        )
        (SecretRefVault ref)
        `shouldReturn` Right "AKIAEXAMPLE"
    it "keeps test plaintext rejected even when a Vault reader is available" $ do
      resolveSecretRefWithVault
        ProductionMode
        (\_ -> pure (Right "unused"))
        (SecretRefTestPlaintext "AKIAEXAMPLE")
        `shouldReturn` Left SecretRefPlaintextInProduction
    it "decodes a SecretRef.Vault reference from the Dhall union" $ do
      let expr =
            Text.concat
              [ "< Vault : { mount : Text, path : Text, field : Text }"
              , "| TransitKey : Text"
              , "| Prompt : { name : Text, purpose : Text }"
              , "| TestPlaintext : Text"
              , ">.Vault { mount = \"kv\", path = \"prodbox/aws/admin\", field = \"access_key_id\" }"
              ]
      decoded <- Dhall.input Dhall.auto expr
      decoded `shouldBe` SecretRefVault (VaultSecretRef "kv" "prodbox/aws/admin" "access_key_id")
    it "decodes a SecretRef.TestPlaintext literal from the Dhall union" $ do
      let expr =
            Text.concat
              [ "< Vault : { mount : Text, path : Text, field : Text }"
              , "| TransitKey : Text"
              , "| Prompt : { name : Text, purpose : Text }"
              , "| TestPlaintext : Text"
              , ">.TestPlaintext \"AKIAEXAMPLE\""
              ]
      decoded <- Dhall.input Dhall.auto expr
      decoded `shouldBe` SecretRefTestPlaintext "AKIAEXAMPLE"
  describe "vault Transit DekCipher (Sprint 1.37)" $ do
    it "delegates DEK wrap and unwrap to the supplied Transit functions" $ do
      let cipher =
            vaultTransitDekCipherWith
              (\dek -> pure (Right ("vault:v1:" <> TextEncoding.decodeUtf8 dek)))
              (\wrapped -> pure (Right (TextEncoding.encodeUtf8 (Text.drop 9 wrapped))))
      dekWrap cipher "sample-dek" `shouldReturn` Right "vault:v1:sample-dek"
      dekUnwrap cipher "vault:v1:sample-dek" `shouldReturn` Right "sample-dek"
  describe "CLI parser" $ do
    it "routes config show to the native Haskell command" $ do
      parseArgs ["config", "show", "--show-secrets"]
        `shouldBe` Right (Options False (RunNative (NativeConfig (ConfigShow True))))

    it "routes native host commands through the Haskell runtime" $ do
      parseArgs ["host", "info"]
        `shouldBe` Right (Options False (RunNative (NativeHost HostInfo)))

    it "routes edge status through the native Haskell runtime" $ do
      parseArgs ["edge", "status"]
        `shouldBe` Right (Options False (RunNative (NativeHost (HostPublicEdge SubstrateHomeLocal))))

    it "routes edge status --substrate aws to the AWS-substrate diagnostic" $ do
      parseArgs ["edge", "status", "--substrate", "aws"]
        `shouldBe` Right (Options False (RunNative (NativeHost (HostPublicEdge SubstrateAws))))

    it "routes dns check through the native Haskell runtime" $ do
      parseArgs ["dns", "check"]
        `shouldBe` Right (Options False (RunNative (NativeDns DnsCheck)))

    it "routes gateway status through the native Haskell runtime" $ do
      parseArgs ["gateway", "status", "--config", "/tmp/gateway.json"]
        `shouldBe` Right
          ( Options
              False
              (RunNative (NativeGateway (GatewayStatusCommand (DaemonStatusOptions (Just "/tmp/gateway.json")))))
          )

    it "routes gateway start through the native Haskell runtime" $ do
      parseArgs ["gateway", "start", "--config", "/tmp/gateway.json"]
        `shouldBe` Right
          ( Options
              False
              ( RunNative
                  ( NativeGateway
                      ( GatewayDaemonCommand
                          DaemonLaunchOptions
                            { daemonConfigPath = Just "/tmp/gateway.json"
                            , daemonPlanOptions = PlanOptions False Nothing
                            }
                      )
                  )
              )
          )

    it "routes gateway config-gen through the native Haskell runtime" $ do
      parseArgs ["gateway", "config-gen", "/tmp/gateway.json", "--node-id", "node-a"]
        `shouldBe` Right (Options False (RunNative (NativeGateway (GatewayConfigGen "/tmp/gateway.json" "node-a"))))

    it "routes config setup to the native Haskell runtime" $ do
      parseArgs ["config", "setup"]
        `shouldBe` Right
          (Options False (RunNative (NativeConfig (ConfigSetup (PlanOptions False Nothing)))))

    it "routes aws policy to the native Haskell runtime" $ do
      parseArgs ["aws", "policy", "--tier", "full"]
        `shouldBe` Right (Options False (RunNative (NativeAws (AwsPolicy PolicyFull))))

    it "routes aws setup to the native Haskell runtime" $ do
      parseArgs ["aws", "setup", "--tier", "full"]
        `shouldBe` Right
          ( Options
              False
              (RunNative (NativeAws (AwsSetup PolicyFull (PlanOptions False Nothing))))
          )

    it "routes aws teardown to the native Haskell runtime" $ do
      parseArgs ["aws", "teardown"]
        `shouldBe` Right
          ( Options
              False
              ( RunNative
                  ( NativeAws
                      ( AwsTeardown
                          (PlanOptions False Nothing)
                          (AwsTeardownFlags {teardownResiduePolicy = RefuseOnAnyResidue})
                      )
                  )
              )
          )
    it "routes aws teardown --allow-pulumi-residue with AcceptOrphanResidue policy" $ do
      parseArgs ["aws", "teardown", "--allow-pulumi-residue"]
        `shouldBe` Right
          ( Options
              False
              ( RunNative
                  ( NativeAws
                      ( AwsTeardown
                          (PlanOptions False Nothing)
                          (AwsTeardownFlags {teardownResiduePolicy = AcceptOrphanResidue})
                      )
                  )
              )
          )
    it "routes aws teardown --destroy-pulumi-residue with DestroyPulumiResidueFirst policy" $ do
      parseArgs ["aws", "teardown", "--destroy-pulumi-residue"]
        `shouldBe` Right
          ( Options
              False
              ( RunNative
                  ( NativeAws
                      ( AwsTeardown
                          (PlanOptions False Nothing)
                          (AwsTeardownFlags {teardownResiduePolicy = DestroyPulumiResidueFirst})
                      )
                  )
              )
          )

    it "routes aws check-quotas to the native Haskell runtime" $ do
      parseArgs ["aws", "quotas", "check"]
        `shouldBe` Right (Options False (RunNative (NativeAws AwsCheckQuotas)))

    it "routes aws request-quotas to the native Haskell runtime" $ do
      parseArgs ["aws", "quotas", "request", "--tier", "core"]
        `shouldBe` Right (Options False (RunNative (NativeAws (AwsRequestQuotas PolicyCore))))

    it "routes aws ebs reap-test to the native Haskell runtime" $ do
      parseArgs ["aws", "ebs", "reap-test", "--yes"]
        `shouldBe` Right (Options False (RunNative (NativeAws (AwsReapTestEbs True))))

    it "routes tla-check through the native Haskell runtime" $ do
      parseArgs ["dev", "tla-check"]
        `shouldBe` Right (Options False (RunNative NativeTlaCheck))

    it "routes vault status through the native Haskell runtime" $ do
      parseArgs ["vault", "status"]
        `shouldBe` Right (Options False (RunNative (NativeVault VaultStatus)))

    it "routes vault unseal through the native Haskell runtime" $ do
      parseArgs ["vault", "unseal"]
        `shouldBe` Right (Options False (RunNative (NativeVault VaultUnseal)))

    it "routes vault rotate-transit-key with its key argument" $ do
      parseArgs ["vault", "rotate-transit-key", "prodbox-minio-envelope"]
        `shouldBe` Right
          ( Options
              False
              (RunNative (NativeVault (VaultRotateTransitKey "prodbox-minio-envelope")))
          )

    it "routes vault pki issue-test-cert through the nested pki group" $ do
      parseArgs ["vault", "pki", "issue-test-cert"]
        `shouldBe` Right (Options False (RunNative (NativeVault VaultPkiIssueTestCert)))

    it "routes nuke --dry-run through the native Haskell runtime" $ do
      parseArgs ["nuke", "--dry-run"]
        `shouldBe` Right
          ( Options
              False
              (RunNative (NativeNuke (NukeOptions {nukeDryRun = True, nukePlanFile = Nothing})))
          )

    it "routes plain nuke through the native Haskell runtime" $ do
      parseArgs ["nuke"]
        `shouldBe` Right
          ( Options
              False
              (RunNative (NativeNuke (NukeOptions {nukeDryRun = False, nukePlanFile = Nothing})))
          )

    it "routes cluster commands through the native Haskell runtime" $ do
      parseArgs ["cluster", "delete", "--yes"]
        `shouldBe` Right
          ( Options
              False
              ( RunNative
                  ( NativeRke2
                      ( Rke2Delete
                          ( Rke2DeleteFlags
                              { rke2DeleteYes = True
                              , rke2DeleteCascade = False
                              }
                          )
                          (PlanOptions False Nothing)
                      )
                  )
              )
          )

    it "routes cluster delete --cascade through the native Haskell runtime" $ do
      parseArgs ["cluster", "delete", "--yes", "--cascade"]
        `shouldBe` Right
          ( Options
              False
              ( RunNative
                  ( NativeRke2
                      ( Rke2Delete
                          ( Rke2DeleteFlags
                              { rke2DeleteYes = True
                              , rke2DeleteCascade = True
                              }
                          )
                          (PlanOptions False Nothing)
                      )
                  )
              )
          )

    it "routes cluster federation register through the native Haskell runtime" $ do
      parseArgs ["cluster", "federation", "register", "child-a", "--dry-run"]
        `shouldBe` Right
          ( Options
              False
              ( RunNative
                  ( NativeRke2
                      ( Rke2FederationRegister
                          "child-a"
                          ( FederationRegisterOptions
                              (PlanOptions True Nothing)
                              Nothing
                              Nothing
                              []
                              Nothing
                              Nothing
                              []
                          )
                      )
                  )
              )
          )

    it "routes aws stack commands through the native Haskell runtime" $ do
      parseArgs ["aws", "stack", "test", "reconcile"]
        `shouldBe` Right
          (Options False (RunNative (NativePulumi (PulumiTestResources (PlanOptions False Nothing)))))

      parseArgs ["aws", "stack", "eks", "destroy", "--yes"]
        `shouldBe` Right
          ( Options
              False
              (RunNative (NativePulumi (PulumiEksDestroy True (PlanOptions False Nothing))))
          )

      -- Sprint 7.22: the per-run corrupt-checkpoint prune recovery leaf.
      parseArgs ["aws", "stack", "eks", "prune-corrupt-checkpoint", "--yes"]
        `shouldBe` Right
          ( Options
              False
              (RunNative (NativePulumi (PulumiPruneCorruptCheckpoint PrunePerRunEks True)))
          )

      parseArgs ["aws", "stack", "test", "prune-corrupt-checkpoint"]
        `shouldBe` Right
          ( Options
              False
              (RunNative (NativePulumi (PulumiPruneCorruptCheckpoint PrunePerRunTest False)))
          )

    it "routes charts commands through the native Haskell runtime" $ do
      parseArgs ["charts", "delete", "gateway", "--yes"]
        `shouldBe` Right
          ( Options
              False
              ( RunNative
                  (NativeCharts (ChartsDelete "gateway" SubstrateHomeLocal True (PlanOptions False Nothing)))
              )
          )

    it "routes cluster workload-logs through the Haskell runtime with defaults" $ do
      parseArgs ["cluster", "workload-logs"]
        `shouldBe` Right
          ( Options
              False
              ( RunNative
                  ( NativeK8s
                      ( K8sLogs
                          ["metallb-system", "envoy-gateway-system", "cert-manager", "postgres-operator"]
                          10
                      )
                  )
              )
          )

    it "parses native test-suite ownership with coverage flags" $ do
      parseArgs ["test", "integration", "cli", "--coverage", "--cov-fail-under", "90"]
        `shouldBe` Right
          ( Options
              False
              ( RunNative
                  ( NativeTest
                      ( TestCommand
                          (TestIntegration IntegrationCli)
                          (CoverageFlags True (Just 90))
                          SubstrateHomeLocal
                      )
                  )
              )
          )
      parseArgs ["test", "integration", "pulsar-broker"]
        `shouldBe` Right
          ( Options
              False
              ( RunNative
                  ( NativeTest
                      ( TestCommand
                          (TestIntegration IntegrationPulsarBroker)
                          (CoverageFlags False Nothing)
                          SubstrateHomeLocal
                      )
                  )
              )
          )
      parseArgs ["test", "integration", "daemon-bootstrap"]
        `shouldBe` Right
          ( Options
              False
              ( RunNative
                  ( NativeTest
                      ( TestCommand
                          (TestIntegration IntegrationDaemonBootstrap)
                          (CoverageFlags False Nothing)
                          SubstrateHomeLocal
                      )
                  )
              )
          )

    it "renders the full AWS policy with EKS lifecycle statements" $ do
      case buildIamPolicyDocument PolicyFull of
        Object payload -> do
          case KeyMap.lookup (Key.fromString "Statement") payload of
            Just (Array statements) -> do
              let sids =
                    [ sid
                    | Object statement <- Vector.toList statements
                    , Just (String sid) <- [KeyMap.lookup (Key.fromString "Sid") statement]
                    ]
              sids
                `shouldContain` [ "Ec2TestStackLifecycle"
                                , "IamEksRoleLifecycle"
                                , "EksTestStackLifecycle"
                                , "SesCaptureBucketRead"
                                , "SesCaptureObjectRead"
                                , "SesReadOnly"
                                ]
            _ -> expectationFailure "expected Statement array"
        _ -> expectationFailure "expected policy document object"

    it "installs an account- and capture-qualified bounded SES pre-lease policy" $ do
      let policyResult =
            buildIamPolicyDocumentForAccountAndCaptureBucket
              "123456789012"
              (Just "configured-ses-capture")
              PolicyFull
      case policyResult of
        Left err -> expectationFailure (show err)
        Right policy -> do
          let rendered = encode policy
              renderedText = BL8.unpack rendered
          BL.length rendered `shouldSatisfy` (<= 2048)
          renderedText
            `shouldContain` "arn:aws:iam::123456789012:role/prodbox-ses-lease-session"
          renderedText
            `shouldContain` "arn:aws:iam::123456789012:user/prodbox-ses-smtp"
          renderedText
            `shouldContain` "arn:aws:s3:::configured-ses-capture"
          renderedText `shouldNotContain` "arn:aws:iam::*:role/prodbox-ses-lease-session"

    it "omits capture reads until a valid configured bucket is available" $ do
      case buildIamPolicyDocumentForAccountAndCaptureBucket
        "123456789012"
        Nothing
        PolicyFull of
        Left err -> expectationFailure (show err)
        Right policy -> BL8.unpack (encode policy) `shouldNotContain` "SesCaptureRead"
      buildIamPolicyDocumentForAccountAndCaptureBucket
        "123456789012"
        (Just "Bad_Bucket")
        PolicyFull
        `shouldSatisfy` isLeft

  describe "CLI generated output" $ do
    goldenTest
      "renders the command tree deterministically"
      "test/golden/cli/commands-tree.txt"
      (pure (BL8.pack (renderCommandTree commandRegistry)))

    goldenTest
      "renders the command registry JSON deterministically"
      "test/golden/cli/commands.json"
      (pure (BL8.pack (renderCommandJson commandRegistry)))

    goldenTest
      "renders every leaf help page deterministically"
      "test/golden/cli/help-all.txt"
      (pure (BL8.pack renderAllLeafHelpPages))

  describe "command-surface matrix renderer" $ do
    it "emits the §2 top-level table with a known command row" $ do
      let topLevel = renderCommandSurfaceTopLevel commandRegistry
      topLevel `shouldSatisfy` ("| Command | Kind | Purpose |" `isInfixOf`)
      topLevel `shouldSatisfy` ("| `charts` | Group |" `isInfixOf`)
      topLevel `shouldSatisfy` ("| `nuke` | Command |" `isInfixOf`)

    it "emits a per-group matrix row for a known leaf command" $ do
      renderCommandSurfaceMatrix commandRegistry
        `shouldSatisfy` ("| `prodbox config validate` | none | none |" `isInfixOf`)

    it "renders a positional-argument metavar in the Arguments column" $ do
      let matrix = renderCommandSurfaceMatrix commandRegistry
      matrix `shouldSatisfy` ("| `prodbox charts status` | `CHART` | none |" `isInfixOf`)
      matrix `shouldSatisfy` ("| `prodbox gateway config-gen` | `OUTPUT_PATH` |" `isInfixOf`)

    it "renders a repeatable positional argument with a trailing ellipsis" $ do
      renderCommandSurfaceMatrix commandRegistry
        `shouldSatisfy` ("| `prodbox help` | `COMMAND_PATH...` | none |" `isInfixOf`)

    it "includes every registered leaf command in the generated matrix" $ do
      let matrix = renderCommandSurfaceMatrix commandRegistry
          renderedCommand path = "`prodbox " ++ unwords path ++ "`"
      forM_ leafCommandPaths $ \path ->
        matrix `shouldSatisfy` (renderedCommand path `isInfixOf`)

    it "surfaces the registry commands the hand-doc previously omitted" $ do
      let matrix = renderCommandSurfaceMatrix commandRegistry
      forM_
        [ "prodbox users invite"
        , "prodbox users list"
        , "prodbox users revoke"
        , "prodbox host firewall gateway-unrestrict"
        , "prodbox aws stack aws-ses migrate-backend"
        , "prodbox test integration keycloak-invite"
        ]
        ( \commandText ->
            matrix `shouldSatisfy` (("`" ++ commandText ++ "`") `isInfixOf`)
        )

    it "renders deterministically" $ do
      renderCommandSurfaceTopLevel commandRegistry
        `shouldBe` renderCommandSurfaceTopLevel commandRegistry
      renderCommandSurfaceMatrix commandRegistry
        `shouldBe` renderCommandSurfaceMatrix commandRegistry

  describe "positional-argument CommandSpec field" $ do
    it "records the typed positional argument on a leaf that takes one" $ do
      case findCommandSpec ["charts", "status"] of
        Just spec ->
          map argumentMetavar (arguments spec) `shouldBe` ["CHART"]
        Nothing -> expectationFailure "expected charts status command spec"

    it "marks the help command's positional argument repeatable" $ do
      case findCommandSpec ["help"] of
        Just spec ->
          map argumentRepeatable (arguments spec) `shouldBe` [True]
        Nothing -> expectationFailure "expected help command spec"

    it "leaves option-only leaves with an empty positional-argument list" $ do
      case findCommandSpec ["config", "validate"] of
        Just spec -> arguments spec `shouldBe` []
        Nothing -> expectationFailure "expected config validate command spec"

  describe "plan renderers" $ do
    goldenTest
      "renders the typed registry storage backend deterministically"
      "test/golden/config/registry-config.yaml"
      (pure (BL8.pack (registryConfigYaml harborRegistryStorageBackend)))

    it "renders both explicit registry redirect policies without a driver default" $ do
      registryConfigYaml harborRegistryStorageBackend
        `shouldContain` "  redirect:\n    disable: true"
      registryConfigYaml
        (harborRegistryStorageBackend {registryStorageBackendRedirect = RedirectEnabled})
        `shouldContain` "  redirect:\n    disable: false"

    goldenTest
      "renders the chart deployment plan deterministically"
      "test/golden/plans/chart-deploy-vscode.txt"
      $ do
        result <-
          buildChartDeploymentPlan
            "/tmp/prodbox"
            (testValidatedSettings "/tmp/prodbox/.data")
            "vscode"
            testChartSecrets
            Map.empty
        case result of
          Left err -> fail err
          Right plan -> pure (BL8.pack (renderChartDeploymentPlan plan))

    goldenTest
      "renders the chart deletion plan deterministically"
      "test/golden/plans/chart-delete-vscode.txt"
      $ do
        case buildChartDeletePlan "/tmp/prodbox" (Just (testValidatedSettings "/tmp/prodbox/.data")) "vscode" of
          Left err -> fail err
          Right plan -> pure (BL8.pack (renderChartDeletePlan plan))

    goldenTest
      "renders the pulumi plan deterministically"
      "test/golden/plans/pulumi-eks-resources.txt"
      (pure (BL8.pack (renderPulumiPlan "eks-resources" False)))

    goldenTest
      "renders the aws setup plan deterministically"
      "test/golden/plans/aws-setup.txt"
      (pure (BL8.pack (renderAwsSetupPlan "/tmp/prodbox" sampleAwsSetupInput)))

    goldenTest
      "renders the aws teardown plan deterministically"
      "test/golden/plans/aws-teardown.txt"
      (pure (BL8.pack (renderAwsTeardownPlan "/tmp/prodbox" sampleAwsTeardownInput)))

    goldenTest
      "renders the config setup plan deterministically"
      "test/golden/plans/config-setup.txt"
      (pure (BL8.pack (renderConfigSetupPlan "/tmp/prodbox" sampleConfigSetupInput)))

    it "config generate runs without a repo root; config validate still requires one (Sprint 1.49)" $ do
      -- The in-container image build runs `RUN prodbox config generate` with no
      -- repository present; it must be exempt from the `findRepoRoot` gate
      -- because it writes the binary-sibling config (not a repo-relative path).
      canRunWithoutRepoRoot (NativeConfig ConfigGenerate) `shouldBe` True
      canRunWithoutRepoRoot (NativeConfig ConfigValidate) `shouldBe` False
    it
      "configFromSetupInput fills the operator fields from the input over the base config (Sprint 1.50)"
      $ do
        let built = configFromSetupInput defaultConfigFile sampleConfigSetupInput
        zone_id (route53 built) `shouldBe` "Z1234567890ABC"
        email (acme built) `shouldBe` "ops@resolvefintech.com"
        demo_fqdn (domain built) `shouldBe` "test.resolvefintech.com"
        awsCredentialRegion (aws built)
          `shouldBe` region (configSetupAdminCredentialsInput sampleConfigSetupInput)

    goldenTest
      "renders the gateway start plan deterministically"
      "test/golden/plans/gateway-start.txt"
      $ do
        let configText = renderGatewayConfigTemplate (testValidatedSettings "/tmp/prodbox/.data") "node-a"
        decodeResult <-
          GatewaySettings.decodeDaemonConfigDhallWith
            (const (pure (Right "resolved-secret")))
            (Text.pack configText)
        case decodeResult of
          Left err -> fail err
          Right config ->
            pure (BL8.pack (renderGatewayStartPlan "/tmp/prodbox/gateway.dhall" config))

    it "decodes the gateway-daemon validation config (SecretRef-typed cred fields)" $ do
      -- Sprint 3.18 regression: the gateway-daemon validation config must type
      -- its aws_creds / minio_creds / event_keys credential fields as the
      -- SecretRef union the daemon decoder expects, not Text — otherwise the
      -- in-process decode fails with "Expression doesn't match annotation".
      let configText =
            renderGatewayValidationConfigDhall
              (testValidatedSettings "/tmp/prodbox/.data")
              "node-a"
              "/tmp/prodbox/orders.dhall"
      decodeResult <-
        GatewaySettings.decodeDaemonConfigDhallWith
          (const (pure (Right "resolved-secret")))
          (Text.pack configText)
      case decodeResult of
        Left err -> expectationFailure err
        Right _ -> pure ()

    goldenTest
      "renders the local (no-edge) rke2 reconcile plan deterministically"
      "test/golden/plans/rke2-reconcile.txt"
      ( pure
          ( BL8.pack
              ( renderNativeInstallPlan
                  "/tmp/prodbox"
                  (testValidatedSettings "/tmp/prodbox/.data")
                  "machine-id-123"
                  "prodbox-123"
                  "prodbox-123"
                  False
              )
          )
      )

    goldenTest
      "renders the rke2 reconcile --with-edge plan deterministically"
      "test/golden/plans/rke2-reconcile-with-edge.txt"
      ( pure
          ( BL8.pack
              ( renderNativeInstallPlan
                  "/tmp/prodbox"
                  (testValidatedSettings "/tmp/prodbox/.data")
                  "machine-id-123"
                  "prodbox-123"
                  "prodbox-123"
                  True
              )
          )
      )

    it "orders root Vault bootstrap after the pre-Vault gateway daemon" $ do
      let steps =
            lines
              ( renderNativeInstallPlan
                  "/tmp/prodbox"
                  (testValidatedSettings "/tmp/prodbox/.data")
                  "machine-id-123"
                  "prodbox-123"
                  "prodbox-123"
                  False
              )
          minioIndex = elemIndex "STEP=ensure_minio_runtime_bootstrap" steps
          vaultRuntimeIndex = elemIndex "STEP=ensure_vault_runtime" steps
          certManagerIndex = elemIndex "STEP=ensure_cert_manager_runtime" steps
          gatewayIndex = elemIndex "STEP=ensure_gateway_chart_ready_pre_vault" steps
          lifecycleIndex = elemIndex "STEP=ensure_federated_vault_lifecycle" steps
          steadyGatewayIndex = elemIndex "STEP=ensure_gateway_chart_ready" steps
      minioIndex `shouldSatisfy` (`indexPrecedes` vaultRuntimeIndex)
      vaultRuntimeIndex `shouldSatisfy` (`indexPrecedes` gatewayIndex)
      -- The pre-Vault gateway daemon mounts cert-manager-issued (self-signed) TLS
      -- secrets, so cert-manager must be stood up before it (147215f regression guard).
      certManagerIndex `shouldSatisfy` (`indexPrecedes` gatewayIndex)
      gatewayIndex `shouldSatisfy` (`indexPrecedes` lifecycleIndex)
      lifecycleIndex `shouldSatisfy` (`indexPrecedes` steadyGatewayIndex)

    it "classifies absent operational AWS Vault credentials as a skippable public-edge gate" $ do
      operationalAwsCredentialGateFromResult
        (Left "Vault KV object secret/gateway/gateway/aws missing: HTTP 404 response")
        `shouldBe` OperationalAwsCredentialsAbsent
          "Vault KV object secret/gateway/gateway/aws missing: HTTP 404 response"
      operationalAwsCredentialGateFromResult
        (Left "aws.access_key_id resolved from Vault as empty")
        `shouldBe` OperationalAwsCredentialsAbsent "aws.access_key_id resolved from Vault as empty"
      operationalAwsCredentialGateFromResult
        ( Right
            Credentials
              { access_key_id = ""
              , secret_access_key = "secret"
              , session_token = Nothing
              , region = "us-west-2"
              }
        )
        `shouldBe` OperationalAwsCredentialsAbsent "operational aws.* resolved with an empty field"

    it
      "classifies populated operational AWS Vault credentials as ready and unexpected failures as invalid"
      $ do
        operationalAwsCredentialGateFromResult
          ( Right
              Credentials
                { access_key_id = "access"
                , secret_access_key = "secret"
                , session_token = Nothing
                , region = "us-west-2"
                }
          )
          `shouldBe` OperationalAwsCredentialsReady
        operationalAwsCredentialGateFromResult (Left "Vault TLS handshake failed")
          `shouldBe` OperationalAwsCredentialsInvalid "Vault TLS handshake failed"

    it "renders the inotify sysctl drop-in with raised limits and a managed-by header" $ do
      let dropIn = renderInotifySysctlDropIn
      dropIn `shouldSatisfy` ("fs.inotify.max_user_instances = 8192" `isInfixOf`)
      dropIn `shouldSatisfy` ("fs.inotify.max_user_watches = 1048576" `isInfixOf`)
      dropIn `shouldSatisfy` ("Managed by `prodbox cluster reconcile`" `isInfixOf`)

    it "renders RKE2 kubelet resource guardrails from the capacity resource plan" $ do
      let rendered = renderRke2ResourceGuardrailConfig Capacity.defaultResourcePlan
      rendered `shouldContain` "# Managed by `prodbox cluster reconcile`"
      rendered `shouldContain` "kubelet-arg:"
      rendered `shouldContain` "\"system-reserved=cpu=500m,memory=1024Mi,ephemeral-storage=5120Mi\""
      rendered `shouldContain` "\"kube-reserved=cpu=500m,memory=1024Mi,ephemeral-storage=5120Mi\""
      rendered
        `shouldContain` "\"eviction-hard=memory.available<1024Mi,nodefs.available<10240Mi,imagefs.available<10240Mi\""
      rendered `shouldContain` "\"image-gc-high-threshold=70\""
      rendered `shouldContain` "\"container-log-max-size=50Mi\""

    it "renders a bounded systemd drop-in for the RKE2 service tree" $ do
      let rendered = renderRke2SystemdResourceDropIn Capacity.defaultResourcePlan
      rendered `shouldContain` "[Service]"
      rendered `shouldContain` "CPUAccounting=true"
      rendered `shouldContain` "MemoryAccounting=true"
      rendered `shouldContain` "CPUQuota=100%"
      rendered `shouldContain` "MemoryHigh=2048M"
      rendered `shouldContain` "MemoryMax=3072M"
      rendered `shouldContain` "TasksMax=4096"

    it "parses observed host capacity and refuses hosts below the authored capacity" $ do
      let observedText =
            "milli_cpu=8000,memory_mib=15872,ephemeral_storage_mib=100000,durable_storage_mib=180000"
          smallText =
            "milli_cpu=7000,memory_mib=15872,ephemeral_storage_mib=100000,durable_storage_mib=180000"
      case parseHostCapacityObservation observedText of
        Left err -> expectationFailure err
        Right observed -> do
          renderResourceVectorRuntime observed
            `shouldBe` "cpu=8000m,memory=15872Mi,ephemeral-storage=100000Mi,durable-storage=180000Mi"
          hostCapacityCoversPlan observed Capacity.defaultResourcePlan `shouldBe` True
      case parseHostCapacityObservation smallText of
        Left err -> expectationFailure err
        Right observed ->
          hostCapacityCoversPlan observed Capacity.defaultResourcePlan `shouldBe` False

    it "skips plan application on --dry-run while persisting the rendered plan" $
      withSystemTempDirectory "prodbox-plan-options" $ \tmpDir -> do
        appliedRef <- newIORef False
        let planPath = tmpDir </> "plan.txt"
            plan = buildPlan (\payload -> "PLAN=" ++ payload ++ "\n") ("dry-run" :: String)
        exitCode <-
          runPlanWithOptions
            (PlanOptions True (Just planPath))
            plan
            (\_ -> writeIORef appliedRef True >> pure ExitSuccess)
        exitCode `shouldBe` ExitSuccess
        readIORef appliedRef `shouldReturn` False
        readFile planPath `shouldReturn` "PLAN=dry-run\n"

    it "passes the typed plan payload to the apply boundary when not in dry-run mode" $ do
      payloadRef <- newIORef ""
      exitCode <-
        runPlanWithOptions
          (PlanOptions False Nothing)
          (buildPlan (\payload -> "PLAN=" ++ payload ++ "\n") ("apply" :: String))
          (\payload -> writeIORef payloadRef payload >> pure ExitSuccess)
      exitCode `shouldBe` ExitSuccess
      readIORef payloadRef `shouldReturn` "apply"

  describe "frontend scaffold doctrine" $ do
    it "keeps the Phase 1.1 Haskell frontend scaffold in the repository" $ do
      repoRoot <- getCurrentDirectory
      scaffoldExists <-
        mapM
          (doesFileExist . (repoRoot </>))
          [ "app/prodbox/Main.hs"
          , "src/Prodbox/CLI/Parser.hs"
          , "src/Prodbox/Gateway/Daemon.hs"
          , "prodbox.cabal"
          , "cabal.project"
          , "docker/prodbox.Dockerfile"
          , "test/integration/Main.hs"
          ]

      scaffoldExists `shouldBe` replicate 7 True

    it "keeps cabal.project minimal for nix-style builds" $ do
      repoRoot <- getCurrentDirectory
      cabalProject <- readFile (repoRoot </> "cabal.project")

      cabalProject `shouldContain` "packages: ."
      cabalProject `shouldContain` "with-compiler: ghc-9.12.4"
      cabalProject `shouldContain` "allow-newer: *:base, *:template-haskell"
      cabalProject `shouldNotContain` "builddir:"

    it "builds the single union runtime image under /opt/build" $ do
      repoRoot <- getCurrentDirectory
      dockerfile <- readFile (repoRoot </> "docker" </> "prodbox.Dockerfile")

      dockerfile `shouldContain` "FROM ubuntu:24.04"
      dockerfile `shouldContain` "ARG GHC_VERSION=9.12.4"
      dockerfile `shouldContain` "ARG CABAL_VERSION=3.16.1.0"
      dockerfile `shouldContain` "WORKDIR /opt/build"
      dockerfile `shouldContain` "BOOTSTRAP_HASKELL_MINIMAL=1"
      dockerfile `shouldContain` "ghcup install ghc \"${GHC_VERSION}\""
      dockerfile `shouldContain` "ghcup install cabal \"${CABAL_VERSION}\""
      dockerfile `shouldContain` "cabal build --builddir=.build exe:prodbox"
      dockerfile `shouldContain` "cabal list-bin --builddir=.build exe:prodbox"
      -- Union image: bundles the AWS CLI (gateway shells out to `aws route53`)
      -- and tini (PID 1 for the long-running daemon), keyed by native arch.
      dockerfile `shouldContain` "awscli.amazonaws.com"
      dockerfile `shouldContain` "dpkg --print-architecture"
      dockerfile `shouldContain` "tini"
      -- Bare `prodbox` under tini; each chart supplies its own subcommand via
      -- the pod `args:` (`gateway start` vs `workload start`).
      dockerfile
        `shouldContain` "ENTRYPOINT [\"/usr/bin/tini\", \"--\", \"/usr/local/bin/prodbox\"]"
      -- Basic `docker build` only: no BuildKit frontend pin and no cache/bind
      -- mounts, so the image builds with the daemon's default builder. (No-buildx
      -- on the invocation itself is enforced in test/integration/CliSuite.hs.)
      dockerfile `shouldNotContain` "# syntax="
      dockerfile `shouldNotContain` "--mount="
      dockerfile `shouldNotContain` "type=cache"

    it "keeps the Haskell quality gate on repo-owned formatter and lint inputs" $ do
      repoRoot <- getCurrentDirectory
      checkCode <- readFile (repoRoot </> "src" </> "Prodbox" </> "CheckCode.hs")
      fourmoluConfig <- readFile (repoRoot </> "fourmolu.yaml")
      hlintConfig <- readFile (repoRoot </> ".hlint.yaml")
      editorConfig <- readFile (repoRoot </> ".editorconfig")

      checkCode `shouldContain` "fourmolu"
      checkCode `shouldContain` "hlint"
      checkCode `shouldContain` "--ghc-options=-Werror"
      fourmoluConfig `shouldContain` "indentation: 2"
      fourmoluConfig `shouldContain` "column-limit: 100"
      hlintConfig `shouldContain` "--cpp-simple"
      editorConfig `shouldContain` "indent_style = space"
      editorConfig `shouldContain` "indent_size = 2"

    it "flags unsupported workflow and hook surfaces in the quality gate policy scan" $ do
      doctrineViolationsInPaths
        [".github", ".pre-commit-config.yaml", "hooks/pre-push", "src/Prodbox/Main.hs"]
        `shouldBe` [ ForbiddenWorkflowDirectory ".github"
                   , ForbiddenHookSurface ".pre-commit-config.yaml"
                   , ForbiddenHookSurface "hooks/pre-push"
                   ]

    it "skips retained runtime state roots during doctrine scanning" $
      withSystemTempDirectory "prodbox-check-code" $ \tmpDir -> do
        let runtimeRoot = tmpDir </> ".data"
            workflowRoot = tmpDir </> ".github"
        createDirectoryIfMissing True runtimeRoot
        createDirectoryIfMissing True workflowRoot
        writeFile (workflowRoot </> "workflow.yml") "name: forbidden"

        originalPermissions <- getPermissions runtimeRoot
        let blockedPermissions = originalPermissions {readable = False, searchable = False, writable = False}
        setPermissions runtimeRoot blockedPermissions

        repoPaths <- listRepoOwnedPaths tmpDir `finally` setPermissions runtimeRoot originalPermissions

        repoPaths `shouldContain` [".github"]
        repoPaths `shouldSatisfy` notElem ".data"
        doctrineViolationsInPaths repoPaths `shouldBe` [ForbiddenWorkflowDirectory ".github"]

    it "keeps the gateway chart on repo-rootless startup with Vault-backed gateway secrets" $ do
      -- Sprint 3.18: AWS / MinIO credentials and event keys are direct
      -- SecretRef.Vault values in config.dhall, not Secret-mounted Dhall
      -- fragments.
      repoRoot <- getCurrentDirectory
      deploymentTemplate <-
        readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "deployments.yaml")
      configTemplate <-
        readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "configmap-config.yaml")
      helpersTemplate <-
        readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "_helpers.tpl")
      valuesTemplate <- readFile (repoRoot </> "charts" </> "gateway" </> "values.yaml")
      awsSecretTemplateExists <-
        doesFileExist
          (repoRoot </> "charts" </> "gateway" </> "templates" </> "secret-aws-credentials.yaml")

      deploymentTemplate `shouldContain` "scheme: HTTP"
      deploymentTemplate `shouldNotContain` "scheme: HTTPS"
      deploymentTemplate `shouldNotContain` "/app/prodbox-config.json"
      deploymentTemplate `shouldNotContain` "/etc/gateway/secrets"
      deploymentTemplate `shouldNotContain` "gateway-aws-credentials"
      deploymentTemplate `shouldNotContain` "gateway-minio-creds"
      deploymentTemplate `shouldNotContain` "name: AWS_ACCESS_KEY_ID"
      helpersTemplate `shouldContain` ">.Vault"
      configTemplate `shouldContain` "gateway.secretRefVault"
      configTemplate `shouldContain` "$.Values.vault.paths.aws"
      configTemplate `shouldContain` "$.Values.vault.paths.minio"
      configTemplate `shouldContain` "role = {{ $.Values.vault.role | quote }}"
      configTemplate `shouldNotContain` "lookup \"v1\" \"Secret\""
      configTemplate `shouldNotContain` "Some /etc/gateway/secrets"
      valuesTemplate `shouldContain` "role: prodbox-gateway-daemon"
      valuesTemplate `shouldContain` "aws: gateway/gateway/aws"
      valuesTemplate `shouldContain` "minio: gateway/gateway/minio"
      awsSecretTemplateExists `shouldBe` False

    it "lets AWS SMTP pre-created namespaces be adopted by the gateway release" $ do
      repoRoot <- getCurrentDirectory
      rbacTemplate <-
        readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "rbac.yaml")

      rbacTemplate `shouldContain` "app.kubernetes.io/managed-by: Helm"
      rbacTemplate `shouldContain` "meta.helm.sh/release-name: {{ $.Release.Name | quote }}"
      rbacTemplate `shouldContain` "meta.helm.sh/release-namespace: {{ $.Release.Namespace | quote }}"
      rbacTemplate `shouldContain` "helm.sh/resource-policy: keep"

    it "materializes Patroni credential Secrets from Vault before the Percona CR (Sprint 3.18)" $ do
      repoRoot <- getCurrentDirectory
      let secretsTemplatePath =
            repoRoot </> "charts" </> "keycloak-postgres" </> "templates" </> "00-secrets.yaml"
      secretsTemplateExists <- doesFileExist secretsTemplatePath
      secretsTemplateExists `shouldBe` False
      bootstrapJobTemplate <-
        readFile
          (repoRoot </> "charts" </> "keycloak-postgres" </> "templates" </> "secret-bootstrap-job.yaml")
      bootstrapRbacTemplate <-
        readFile
          (repoRoot </> "charts" </> "keycloak-postgres" </> "templates" </> "secret-bootstrap-rbac.yaml")
      postgresTemplate <-
        readFile (repoRoot </> "charts" </> "keycloak-postgres" </> "templates" </> "postgresql.yaml")
      valuesTemplate <- readFile (repoRoot </> "charts" </> "keycloak-postgres" </> "values.yaml")
      bootstrapJobTemplate `shouldNotContain` "/v1/secret/ensure-namespace"
      bootstrapJobTemplate
        `shouldContain` "serviceAccountName: {{ .Values.secretMaterializer.serviceAccountName | quote }}"
      bootstrapJobTemplate `shouldContain` "vault write -field=token"
      bootstrapJobTemplate `shouldContain` "vault kv get -field=username"
      bootstrapJobTemplate
        `shouldContain` "materialize_pair app {{ .Values.vault.paths.application | quote }}"
      bootstrapJobTemplate `shouldContain` "Content-Type: application/merge-patch+json"
      bootstrapJobTemplate `shouldContain` "/api/v1/namespaces/${POD_NAMESPACE}/secrets/${secret_name}"
      bootstrapJobTemplate `shouldContain` "helm.sh/hook\": pre-install,pre-upgrade"
      bootstrapRbacTemplate `shouldContain` "kind: ServiceAccount"
      bootstrapRbacTemplate `shouldContain` "helm.sh/hook-weight\": \"-20\""
      bootstrapRbacTemplate `shouldContain` "resources: [\"secrets\"]"
      bootstrapRbacTemplate `shouldContain` "verbs: [\"create\"]"
      bootstrapRbacTemplate `shouldContain` "verbs: [\"get\", \"update\", \"patch\"]"
      bootstrapRbacTemplate `shouldContain` "{{ .Values.secrets.application.name | quote }}"
      bootstrapRbacTemplate `shouldContain` "{{ .Values.secrets.superuser.name | quote }}"
      bootstrapRbacTemplate `shouldContain` "{{ .Values.secrets.standby.name | quote }}"
      postgresTemplate `shouldContain` "kind: PerconaPGCluster"
      postgresTemplate `shouldContain` "apiVersion: pgv2.percona.com/v2"
      postgresTemplate `shouldContain` "replicaCertCopy:"
      postgresTemplate `shouldContain` ".Values.resources.replicaCertCopy"
      valuesTemplate `shouldContain` "role: keycloak-keycloak-postgres-pg"
      valuesTemplate `shouldContain` "serviceAccountName: prodbox-keycloak-pg"
      valuesTemplate `shouldContain` "application: keycloak/keycloak-postgres/patroni/app"
      valuesTemplate `shouldNotContain` "password: change-me"

    it "gates Keycloak liveness behind a startup probe during cold restores" $ do
      repoRoot <- getCurrentDirectory
      deploymentTemplate <-
        readFile (repoRoot </> "charts" </> "keycloak" </> "templates" </> "deployment.yaml")

      deploymentTemplate `shouldContain` "progressDeadlineSeconds: 1800"
      deploymentTemplate `shouldContain` "startupProbe:"
      deploymentTemplate
        `shouldContain` "{{- $healthPathPrefix := trimSuffix \"/\" .Values.keycloak.httpRelativePath }}"
      deploymentTemplate
        `shouldContain` "path: {{ printf \"%s/health/ready\" $healthPathPrefix | quote }}"
      deploymentTemplate `shouldContain` "path: {{ printf \"%s/health/live\" $healthPathPrefix | quote }}"
      deploymentTemplate `shouldNotContain` "relativePath"
      deploymentTemplate `shouldContain` "failureThreshold: 60"

    it "pins Vault-auth chart workloads to explicit service accounts (Sprint 3.18)" $ do
      repoRoot <- getCurrentDirectory
      let chartServiceAccounts =
            [ ("api", "deployment.yaml", "api", "serviceAccountName: api")
            ,
              ( "gateway"
              , "deployments.yaml"
              , "prodbox-gateway-daemon"
              , "serviceAccountName: prodbox-gateway-daemon"
              )
            , ("keycloak", "deployment.yaml", "keycloak", "serviceAccountName: keycloak")
            , ("minio", "statefulset.yaml", "minio", "serviceAccountName: minio")
            , ("vault", "statefulset.yaml", "vault", "serviceAccountName: vault")
            , ("vscode", "statefulset.yaml", "vscode", "serviceAccountName: vscode")
            , ("websocket", "deployment.yaml", "websocket", "serviceAccountName: websocket")
            ]
      forM_ chartServiceAccounts $ \(chartName, controllerTemplate, serviceAccountResourceName, serviceAccountName) -> do
        serviceAccountTemplate <-
          readFile (repoRoot </> "charts" </> chartName </> "templates" </> "serviceaccount.yaml")
        controller <-
          readFile (repoRoot </> "charts" </> chartName </> "templates" </> controllerTemplate)
        serviceAccountTemplate `shouldContain` "kind: ServiceAccount"
        serviceAccountTemplate `shouldContain` ("name: " <> serviceAccountResourceName)
        controller `shouldContain` serviceAccountName
      vaultTokenReviewBinding <-
        readFile (repoRoot </> "charts" </> "vault" </> "templates" </> "clusterrolebinding.yaml")
      vaultTokenReviewBinding `shouldContain` "kind: ClusterRoleBinding"
      vaultTokenReviewBinding `shouldContain` "name: system:auth-delegator"
      vaultTokenReviewBinding `shouldContain` "name: vault"

    it "renders Vault root Shamir by default and transit seal only for child clusters (Sprint 3.20)" $ do
      repoRoot <- getCurrentDirectory
      vaultConfigMap <-
        readFile (repoRoot </> "charts" </> "vault" </> "templates" </> "configmap.yaml")
      vaultStatefulSet <-
        readFile (repoRoot </> "charts" </> "vault" </> "templates" </> "statefulset.yaml")
      vaultValues <- readFile (repoRoot </> "charts" </> "vault" </> "values.yaml")

      vaultValues `shouldContain` "mode: shamir"
      vaultValues `shouldContain` "tokenSecretName: vault-transit-seal-token"
      vaultConfigMap `shouldContain` "if eq .Values.seal.mode \"transit\""
      vaultConfigMap `shouldContain` "seal \"transit\""
      vaultConfigMap `shouldContain` "seal.transit.address"
      vaultConfigMap `shouldContain` "seal.transit.keyName"
      vaultConfigMap `shouldNotContain` "VAULT_TOKEN"
      vaultStatefulSet `shouldContain` "name: VAULT_TOKEN"
      vaultStatefulSet `shouldContain` "secretKeyRef:"
      vaultStatefulSet `shouldContain` "seal.transit.tokenSecretName"
      vaultStatefulSet `shouldContain` "seal.transit.tokenSecretKey"

    it "renders the websocket OIDC client secret as a direct Vault SecretRef (Sprint 3.18)" $ do
      repoRoot <- getCurrentDirectory
      websocketConfig <-
        readFile (repoRoot </> "charts" </> "websocket" </> "templates" </> "configmap-config.yaml")
      websocketValues <- readFile (repoRoot </> "charts" </> "websocket" </> "values.yaml")

      websocketConfig `shouldContain` ">.Vault"
      websocketConfig `shouldContain` "secret/data/vscode/oidc/prodbox-websocket"
      websocketConfig `shouldContain` "role = {{ .Values.vault.role | quote }}"
      websocketConfig `shouldNotContain` "lookup \"v1\" \"Secret\""
      websocketValues `shouldContain` "role: websocket-oidc"
      websocketValues `shouldContain` "path: vscode/oidc/prodbox-websocket"

    it "materializes the VS Code SecurityPolicy client Secret from Vault (Sprint 3.18)" $ do
      repoRoot <- getCurrentDirectory
      httpRouteTemplate <-
        readFile (repoRoot </> "charts" </> "vscode" </> "templates" </> "http-route.yaml")
      materializerJob <-
        readFile
          (repoRoot </> "charts" </> "vscode" </> "templates" </> "securitypolicy-client-secret-job.yaml")
      materializerRbac <-
        readFile
          (repoRoot </> "charts" </> "vscode" </> "templates" </> "securitypolicy-client-secret-rbac.yaml")
      vscodeNetworkPolicy <-
        readFile (repoRoot </> "charts" </> "vscode" </> "templates" </> "networkpolicy.yaml")
      vscodeValues <- readFile (repoRoot </> "charts" </> "vscode" </> "values.yaml")

      httpRouteTemplate `shouldContain` "kind: SecurityPolicy"
      httpRouteTemplate `shouldContain` "clientSecret:"
      httpRouteTemplate `shouldNotContain` "lookup \"v1\" \"Secret\""
      httpRouteTemplate `shouldNotContain` "keycloak-oidc-clients"
      httpRouteTemplate `shouldNotContain` "kind: Secret"
      httpRouteTemplate `shouldNotContain` ".Values.oidc.clientSecret"
      materializerJob `shouldContain` "helm.sh/hook\": post-install,post-upgrade"
      materializerJob
        `shouldContain` "serviceAccountName: {{ printf \"%s-secret-materializer\" .Values.oidc.securityPolicyName | quote }}"
      materializerJob `shouldContain` "vault write -field=token"
      materializerJob
        `shouldContain` "vault kv get -field=client_secret secret/{{ .Values.vault.paths.oidcVscode }}"
      materializerJob `shouldContain` "Content-Type: application/merge-patch+json"
      materializerJob `shouldContain` "/api/v1/namespaces/${POD_NAMESPACE}/secrets/${SECRET_NAME}"
      materializerRbac `shouldContain` "kind: Role"
      materializerRbac `shouldContain` "resources: [\"secrets\"]"
      materializerRbac `shouldContain` "verbs: [\"create\"]"
      materializerRbac `shouldContain` "verbs: [\"get\", \"update\", \"patch\"]"
      materializerRbac
        `shouldContain` "{{ printf \"%s-client\" .Values.oidc.securityPolicyName | quote }}"
      vscodeNetworkPolicy `shouldContain` "kubernetes.io/metadata.name: vault"
      vscodeNetworkPolicy `shouldContain` "app.kubernetes.io/name: prodbox-vault"
      vscodeNetworkPolicy `shouldContain` "port: 8200"
      vscodeValues `shouldContain` "role: vscode-oidc"
      vscodeValues `shouldContain` "oidcVscode: vscode/oidc/vscode"
      vscodeValues `shouldContain` "repository: 127.0.0.1:30080/prodbox/curl-mirror"
      vscodeValues `shouldNotContain` "clientSecret: change-me"

    it "materializes Keycloak runtime secrets from Vault before startup (Sprint 3.18)" $ do
      repoRoot <- getCurrentDirectory
      keycloakDeployment <-
        readFile (repoRoot </> "charts" </> "keycloak" </> "templates" </> "deployment.yaml")
      keycloakConfig <-
        readFile (repoRoot </> "charts" </> "keycloak" </> "templates" </> "configmap.yaml")
      keycloakBootstrap <-
        readFile (repoRoot </> "charts" </> "keycloak" </> "templates" </> "secret-bootstrap-job.yaml")
      keycloakSecret <-
        readFile (repoRoot </> "charts" </> "keycloak" </> "templates" </> "secret.yaml")

      keycloakDeployment `shouldContain` "name: vault-secrets"
      keycloakDeployment `shouldContain` "vault write -field=token"
      keycloakDeployment `shouldContain` "secret/{{ .Values.vault.paths.admin }}"
      keycloakDeployment `shouldContain` "secret/{{ .Values.vault.paths.db }}"
      keycloakDeployment `shouldContain` "KEYCLOAK_ADMIN_PASSWORD"
      keycloakDeployment `shouldContain` "KC_DB_PASSWORD"
      keycloakDeployment `shouldNotContain` "secretKeyRef:"
      keycloakConfig `shouldContain` "\"secret\": \"${PRODBOX_VSCODE_CLIENT_SECRET}\""
      keycloakConfig `shouldContain` "\"password\": \"${PRODBOX_SMTP_PASSWORD}\""
      keycloakConfig `shouldNotContain` "lookup \"v1\" \"Secret\""
      keycloakBootstrap `shouldNotContain` "/v1/secret/ensure-namespace"
      keycloakSecret `shouldNotContain` "kind: Secret"

    it
      "injects the static MinIO root credential directly (Sprint 7.25: cluster-only, no Vault init container)"
      $ do
        repoRoot <- getCurrentDirectory
        minioStatefulSet <-
          readFile (repoRoot </> "charts" </> "minio" </> "templates" </> "statefulset.yaml")
        minioSecret <- readFile (repoRoot </> "charts" </> "minio" </> "templates" </> "secret.yaml")

        -- Sprint 7.25: MinIO depends ONLY on the cluster — no Vault init container.
        -- The static root cred is set directly on the container (injected by
        -- renderMinioChartArgs --set rootUser / rootPassword), so MinIO can come up
        -- before Vault to serve the unlock bundle.
        minioStatefulSet `shouldNotContain` "name: vault-secrets"
        minioStatefulSet `shouldNotContain` "vault kv get"
        minioStatefulSet `shouldNotContain` "MINIO_ROOT_USER_FILE"
        minioStatefulSet `shouldNotContain` "MINIO_ROOT_PASSWORD_FILE"
        minioStatefulSet `shouldContain` "name: MINIO_ROOT_USER"
        minioStatefulSet `shouldContain` "name: MINIO_ROOT_PASSWORD"
        minioStatefulSet `shouldContain` ".Values.rootUser"
        minioStatefulSet `shouldContain` ".Values.rootPassword"
        minioStatefulSet `shouldNotContain` "secretKeyRef:"
        minioSecret `shouldNotContain` "randAlphaNum"
        minioSecret `shouldNotContain` "kind: Secret"

    it "pins Vault materializers to fail closed when Vault is sealed (Sprint 3.18)" $ do
      repoRoot <- getCurrentDirectory
      keycloakDeployment <-
        readFile (repoRoot </> "charts" </> "keycloak" </> "templates" </> "deployment.yaml")
      keycloakPostgresJob <-
        readFile
          (repoRoot </> "charts" </> "keycloak-postgres" </> "templates" </> "secret-bootstrap-job.yaml")
      vscodeMaterializerJob <-
        readFile
          (repoRoot </> "charts" </> "vscode" </> "templates" </> "securitypolicy-client-secret-job.yaml")
      -- Sprint 7.25: the MinIO chart no longer has a Vault init container (it uses
      -- the static root cred), so it is excluded from this fail-closed sweep.
      let sectionBetween :: Text.Text -> Text.Text -> String -> String
          sectionBetween start end source =
            let sourceText = Text.pack source
                (_, afterStartWithMarker) = Text.breakOn start sourceText
                afterStart = Text.drop (Text.length start) afterStartWithMarker
                (section, _) = Text.breakOn end afterStart
             in Text.unpack section
          vaultInitSection =
            sectionBetween
              "        - name: vault-secrets"
              "          volumeMounts:"
          workloads =
            [ vaultInitSection keycloakDeployment
            , vaultInitSection keycloakPostgresJob
            , vaultInitSection vscodeMaterializerJob
            ]

      forM_ workloads $ \vaultInit -> do
        vaultInit
          `shouldContain` "set -eu"
        vaultInit
          `shouldContain` "vault write -field=token"
        vaultInit
          `shouldContain` "vault kv get -field="
        vaultInit
          `shouldNotContain` "|| true"
        vaultInit
          `shouldNotContain` "lookup \"v1\" \"Secret\""
        vaultInit
          `shouldNotContain` "randAlphaNum"
        vaultInit
          `shouldNotContain` "secretKeyRef:"
        vaultInit
          `shouldNotContain` "TestPlaintext"

    it "keeps the vscode chart on the supported code-server path-prefix flag" $ do
      repoRoot <- getCurrentDirectory
      deploymentTemplate <-
        readFile (repoRoot </> "charts" </> "vscode" </> "templates" </> "statefulset.yaml")

      deploymentTemplate `shouldContain` "--abs-proxy-base-path"
      deploymentTemplate `shouldNotContain` "--base-path"

    it "keeps AWS validation Pulumi YAML stacks on explicit stack config inputs" $ do
      repoRoot <- getCurrentDirectory
      awsEksMain <- readFile (repoRoot </> "pulumi" </> "aws-eks" </> "Main.yaml")
      awsTestMain <- readFile (repoRoot </> "pulumi" </> "aws-test" </> "Main.yaml")
      pulumiCli <- readFile (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Pulumi.hs")
      awsEksInfra <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "AwsEksTestStack.hs")
      awsTestInfra <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "AwsTestStack.hs")

      doesFileExist (repoRoot </> "pulumi" </> "home" </> "Main.yaml") `shouldReturn` False
      pulumiCli `shouldNotContain` "PulumiUp"
      pulumiCli `shouldNotContain` "PulumiRefresh"
      awsEksMain `shouldContain` "operatorCidr:"
      awsEksMain `shouldContain` "type: string"
      awsEksMain `shouldNotContain` "std:getenv"
      awsEksInfra `shouldContain` "\"config\", \"set\", \"--stack\", awsEksTestStackName"
      awsTestMain `shouldContain` "operatorCidr:"
      awsTestMain `shouldContain` "type: string"
      awsTestMain `shouldContain` "tls:PrivateKey"
      awsTestMain `shouldContain` "ssh_private_key:"
      awsTestMain `shouldNotContain` "std:getenv"
      awsTestInfra `shouldContain` "\"config\", \"set\", \"--stack\", awsTestStackName"

    it "keeps supported per-run AWS stacks on the daemon object-store API" $ do
      repoRoot <- getCurrentDirectory
      encryptedBackend <-
        readFile (repoRoot </> "src" </> "Prodbox" </> "Pulumi" </> "EncryptedBackend.hs")
      perRunStacks <-
        traverse
          ( \path -> do
              source <- readFile (repoRoot </> path)
              pure (path, source)
          )
          [ "src" </> "Prodbox" </> "Infra" </> "AwsEksTestStack.hs"
          , "src" </> "Prodbox" </> "Infra" </> "AwsEksSubzoneStack.hs"
          , "src" </> "Prodbox" </> "Infra" </> "AwsTestStack.hs"
          ]

      encryptedBackend `shouldContain` "GatewayClient.getPulumiObject"
      encryptedBackend `shouldContain` "GatewayClient.putPulumiObject"
      encryptedBackend `shouldContain` "GatewayClient.deletePulumiObject"
      encryptedBackend `shouldNotContain` "withMinioPortForward"
      encryptedBackend `shouldNotContain` "127.0.0.1:39000"
      forM_ perRunStacks $ \(_, source) -> do
        source `shouldContain` "withDecryptedStackEnvironment"
        source `shouldNotContain` "withMinioPortForward"
        source `shouldNotContain` "readMinioCredentials"
        source `shouldNotContain` "ensureMinioBackendBucket"
        source `shouldNotContain` "withMigratedDecryptedStackEnvironment"

    it "treats IAM NoSuchEntity as successful absence during EKS destroy residue checks" $ do
      repoRoot <- getCurrentDirectory
      awsEksInfra <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "AwsEksTestStack.hs")

      awsEksInfra `shouldContain` "\"nosuchentity\""

    it "treats terminated EC2 instances as absent during AWS test destroy residue checks" $ do
      repoRoot <- getCurrentDirectory
      awsTestInfra <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "AwsTestStack.hs")

      awsTestInfra `shouldContain` "instanceDescribeShowsActiveInstance"
      awsTestInfra `shouldContain` "\"terminated\""
      awsTestInfra `shouldContain` "Just _ -> finalizeDestroy repoRoot currentSnapshot"

    it "retries AWS test stack destroy after a Pulumi refresh" $ do
      repoRoot <- getCurrentDirectory
      awsTestInfra <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "AwsTestStack.hs")

      awsTestInfra `shouldContain` "pulumiRefreshEither"
      awsTestInfra `shouldContain` "pulumi destroy failed after refresh"
      awsTestInfra
        `shouldContain` "Right () -> completeDestroy repoRoot projectDir environment currentSnapshot summary"

  describe "test planning" $ do
    it "maps aggregate all to the native ordered validation workflow" $ do
      case testExecutionPlan SubstrateHomeLocal TestAll of
        testPlan -> do
          testPlanLabel testPlan `shouldBe` "all"
          testPlanHaskellSuites testPlan
            `shouldBe` ["test:prodbox-unit", "test:prodbox-integration"]
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "all"
              -- Sprint 5.6: minimal-and-precise per-validation sets aggregate
              -- here in first-occurrence order. The charts-* validations now
              -- contribute the AWS-credential-free public_edge_ready gate
              -- (not the old cluster + aws_credentials + pulumi bundle).
              map prerequisiteIdText (nativeInitialIntegrationGatePrerequisites suitePlan)
                `shouldBe` [ "public_edge_ready"
                           , "tool_curl"
                           , "route53_lifecycle_capable"
                           , "tool_dig"
                           , "aws_iam_harness_ready"
                           , "tool_aws"
                           , "host_substrate_supported"
                           , "tool_docker"
                           , "tool_ctr"
                           , "tool_helm"
                           , "tool_kubectl"
                           , "tool_sudo"
                           , "tool_systemctl"
                           , "settings_object"
                           , "aws_credentials_valid"
                           , "tool_pulumi"
                           , "tool_ssh"
                           , "route53_accessible"
                           ]
              map prerequisiteIdText (nativeDeferredIntegrationGatePrerequisites suitePlan)
                `shouldBe` [ "pulumi_logged_in"
                           , "ses_sending_identity_verified"
                           , "ses_receive_rule_set_active"
                           , "ses_receive_bucket_accessible"
                           ]
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Just PolicyFull
              nativeRequiresIntegrationRunbook suitePlan `shouldBe` True
              nativeRequiresSupportedRuntimeBootstrap suitePlan `shouldBe` True
              nativeRequiresSupportedRuntimePostflight suitePlan `shouldBe` True
              map nativeValidationId (nativeValidations suitePlan)
                `shouldBe` [ "charts-vscode"
                           , "charts-api"
                           , "charts-websocket"
                           , "admin-routes"
                           , "public-dns"
                           , "dns-aws"
                           , "aws-iam"
                           , "aws-eks"
                           , "pulumi"
                           , "ha-rke2-aws"
                           , "gateway-daemon"
                           , "gateway-partition"
                           , "charts-platform"
                           , "resource-guardrails"
                           , "daemon-bootstrap"
                           , "pulsar-broker"
                           , "keycloak-invite"
                           , "charts-storage"
                           , "eks-volume-rebind"
                           , "sealed-vault"
                           , "lifecycle"
                           , "gateway-pods"
                           ]
            DelegatedSuite _ -> expectationFailure "expected native aggregate test plan"

    it "keeps integration-all in the canonical external-proof-first order" $ do
      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationAll) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-all"
              map prerequisiteIdText (nativeInitialIntegrationGatePrerequisites suitePlan)
                `shouldBe` [ "public_edge_ready"
                           , "tool_curl"
                           , "route53_lifecycle_capable"
                           , "tool_dig"
                           , "aws_iam_harness_ready"
                           , "tool_aws"
                           , "host_substrate_supported"
                           , "tool_docker"
                           , "tool_ctr"
                           , "tool_helm"
                           , "tool_kubectl"
                           , "tool_sudo"
                           , "tool_systemctl"
                           , "settings_object"
                           , "aws_credentials_valid"
                           , "tool_pulumi"
                           , "tool_ssh"
                           , "route53_accessible"
                           ]
              map prerequisiteIdText (nativeDeferredIntegrationGatePrerequisites suitePlan)
                `shouldBe` [ "pulumi_logged_in"
                           , "ses_sending_identity_verified"
                           , "ses_receive_rule_set_active"
                           , "ses_receive_bucket_accessible"
                           ]
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Just PolicyFull
              nativeRequiresSupportedRuntimeBootstrap suitePlan `shouldBe` True
              nativeRequiresSupportedRuntimePostflight suitePlan `shouldBe` True
              take 4 (map nativeValidationId (nativeValidations suitePlan))
                `shouldBe` ["charts-vscode", "charts-api", "charts-websocket", "admin-routes"]
              take 7 (dropWhile (/= ValidationChartsPlatform) (nativeValidations suitePlan))
                `shouldBe` [ ValidationChartsPlatform
                           , ValidationResourceGuardrails
                           , ValidationDaemonBootstrap
                           , ValidationPulsarBroker
                           , ValidationKeycloakInvite
                           , ValidationChartsStorage
                           , ValidationEksVolumeRebind
                           ]
              ValidationSealedVault `shouldSatisfy` (`elem` nativeValidations suitePlan)
              take 2 (reverse (nativeValidations suitePlan))
                `shouldBe` [ValidationGatewayPods, ValidationLifecycle]
            DelegatedSuite _ -> expectationFailure "expected native integration-all plan"

    it "builds the canonical restore cycle in one exact order" $ do
      restoreCycleSteps
        (buildRestoreCyclePlan SubstrateHomeLocal SesNotRequired)
        `shouldBe` [ RestoreDeleteChart RestoreChartWebsocket
                   , RestoreDeleteChart RestoreChartApi
                   , RestoreDeleteChart RestoreChartVscode
                   , RestoreDeleteChart RestoreChartGateway
                   , RestoreEnsureGatewayMinioBootstrap
                   , RestoreReconcileChart RestoreChartGateway
                   , RestoreReconcileChart RestoreChartVscode
                   , RestoreReconcileChart RestoreChartApi
                   , RestoreReconcileChart RestoreChartWebsocket
                   , RestoreWaitForPublicEdge
                   ]

    it "marks only compiled gateway rollout steps as healthy-window resets" $ do
      map
        restoreStepResetsGatewayHealthyWindow
        [ RestoreDeleteChart RestoreChartGateway
        , RestoreReconcileChart RestoreChartGateway
        , RestoreDeleteChart RestoreChartVscode
        , RestoreEnsureGatewayMinioBootstrap
        , RestoreWaitForPublicEdge
        ]
        `shouldBe` [True, True, False, False, False]

    it "projects bootstrap and postflight from the shared restore builder modulo retained SES" $ do
      case testExecutionPlan SubstrateHomeLocal TestAll of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              let bootstrapPlan = supportedRuntimeBootstrapRestorePlan suitePlan
                  postflightPlan = supportedRuntimePostflightRestorePlan suitePlan
                  bootstrapSteps = restoreCycleSteps bootstrapPlan
                  postflightSteps = restoreCycleSteps postflightPlan
                  gatewayIndex = elemIndex (RestoreReconcileChart RestoreChartGateway) bootstrapSteps
                  smtpIndex = elemIndex True (map isRetainedSesPreparationStep bootstrapSteps)
                  vscodeIndex = elemIndex (RestoreReconcileChart RestoreChartVscode) bootstrapSteps
              bootstrapPlan
                `shouldBe` buildRestoreCyclePlan SubstrateHomeLocal SesRequired
              postflightPlan
                `shouldBe` buildRestoreCyclePlan SubstrateHomeLocal SesNotRequired
              filter (not . isRetainedSesPreparationStep) bootstrapSteps
                `shouldBe` postflightSteps
              gatewayIndex `shouldSatisfy` (`indexPrecedes` smtpIndex)
              smtpIndex `shouldSatisfy` (`indexPrecedes` vscodeIndex)
            DelegatedSuite _ -> expectationFailure "expected native aggregate test plan"

    it "opens the gateway-daemon SMTP precondition only on a ready round trip" $ do
      let policy =
            RetryPolicy
              { retryPolicyMaxAttempts = 1
              , retryPolicyBaseDelayMicros = 0
              , retryPolicyMultiplier = 1
              , retryPolicyMaxDelayMicros = 0
              }
          precondition =
            gatewayDaemonLivenessPrecondition
              policy
              "127.0.0.1:31234"
              (pure (Right ReadinessProbeReady))
      Preconditions.preconditionCheck precondition `shouldReturn` Right ()

    it "returns a bounded structured SMTP refusal for pending or unreachable daemon observations" $ do
      let policy =
            RetryPolicy
              { retryPolicyMaxAttempts = 1
              , retryPolicyBaseDelayMicros = 0
              , retryPolicyMultiplier = 1
              , retryPolicyMaxDelayMicros = 0
              }
          observations =
            [ Right (ReadinessProbePending "gateway returned 503")
            , Left "Connection refused"
            ]
      forM_ observations $ \observation -> do
        attemptsRef <- newIORef (0 :: Int)
        let observeOnce = modifyIORef' attemptsRef (+ 1) >> pure observation
            precondition =
              gatewayDaemonLivenessPrecondition policy "127.0.0.1:31234" observeOnce
        result <- Preconditions.preconditionCheck precondition
        readIORef attemptsRef `shouldReturn` 1
        case result of
          Right () -> expectationFailure "expected the daemon readiness precondition to fail closed"
          Left err -> do
            Preconditions.errorPreconditionLabel err `shouldBe` "gatewayDaemonObjectStoreReady"
            Preconditions.errorSummaryLine err `shouldContain` "127.0.0.1:31234"
            Preconditions.errorOffendingItems err
              `shouldBe` [("127.0.0.1:31234", "prodbox charts reconcile gateway")]
            Preconditions.errorNarrative err `shouldContain` "No Keycloak SMTP sync was started."

    it "bootstraps the AWS substrate by provisioning per-run stacks before deploying the AWS chart set" $ do
      case testExecutionPlan SubstrateAws TestAll of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              supportedRuntimeBootstrapRestorePlan suitePlan
                `shouldBe` buildRestoreCyclePlan SubstrateHomeLocal SesNotRequired
              awsSubstrateBootstrapRestorePlan suitePlan
                `shouldBe` buildRestoreCyclePlan SubstrateAws SesRequired
              restoreCycleSubstrate (awsSubstrateBootstrapRestorePlan suitePlan)
                `shouldBe` SubstrateAws
              case awsSubstrateBootstrapRestoreSteps suitePlan of
                [ RestoreReconcileChart RestoreChartGateway
                  , RestorePrepareRetainedSes _
                  , RestoreReconcileChart RestoreChartVscode
                  , RestoreReconcileChart RestoreChartApi
                  , RestoreReconcileChart RestoreChartWebsocket
                  ] -> pure ()
                observed ->
                  expectationFailure
                    ("unexpected AWS restore preparation order: " ++ show observed)
              awsSubstrateBootstrapCommandArgs suitePlan
                `shouldBe` [ ["aws", "stack", "aws-subzone", "reconcile"]
                           , ["aws", "stack", "eks", "reconcile"]
                           , ["aws", "stack", "test", "reconcile"]
                           , ["charts", "reconcile", "gateway", "--substrate", "aws"]
                           , ["charts", "reconcile", "vscode", "--substrate", "aws"]
                           , ["charts", "reconcile", "api", "--substrate", "aws"]
                           , ["charts", "reconcile", "websocket", "--substrate", "aws"]
                           ]
            DelegatedSuite _ -> expectationFailure "expected native aggregate test plan"

    it "wraps targeted keycloak-invite on home substrate in the managed IAM harness" $ do
      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationKeycloakInvite) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-keycloak-invite"
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Just PolicyFull
              nativeRequiresSupportedRuntimeBootstrap suitePlan `shouldBe` True
              nativeRequiresSupportedRuntimePostflight suitePlan `shouldBe` False
              retainedSesRequirementForValidations (nativeValidations suitePlan)
                `shouldBe` SesRequired
              integrationRunbookCommandArgs suitePlan `shouldBe` [["cluster", "reconcile", "--with-edge"]]
              awsPostflightDestroyCommandArgs suitePlan `shouldBe` []
            DelegatedSuite _ -> expectationFailure "expected native keycloak-invite plan"

    it "wraps targeted AWS-substrate validations in the managed IAM harness" $ do
      case testExecutionPlan SubstrateAws (TestIntegration IntegrationKeycloakInvite) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-keycloak-invite"
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Just PolicyFull
              nativeRequiresSupportedRuntimeBootstrap suitePlan `shouldBe` True
              nativeRequiresSupportedRuntimePostflight suitePlan `shouldBe` False
              awsPostflightDestroyCommandArgs suitePlan
                `shouldBe` [ ["aws", "stack", "aws-subzone", "destroy", "--yes"]
                           , ["aws", "stack", "eks", "destroy", "--yes"]
                           , ["aws", "stack", "test", "destroy", "--yes"]
                           ]
            DelegatedSuite _ -> expectationFailure "expected native keycloak-invite plan"

      case testExecutionPlan SubstrateAws (TestIntegration IntegrationPublicDns) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-public-dns"
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Just PolicyFull
              awsSubstrateBootstrapRestorePlan suitePlan
                `shouldBe` buildRestoreCyclePlan SubstrateAws SesNotRequired
              awsPostflightDestroyCommandArgs suitePlan `shouldBe` []
            DelegatedSuite _ -> expectationFailure "expected native public-dns plan"

    it "does not repeat rke2 reconcile during supported runtime bootstrap after the runbook reconcile" $ do
      case testExecutionPlan SubstrateAws (TestIntegration IntegrationKeycloakInvite) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeRequiresIntegrationRunbook suitePlan `shouldBe` True
              nativeRequiresSupportedRuntimeBootstrap suitePlan `shouldBe` True
              supportedRuntimeBootstrapNeedsReconcile suitePlan `shouldBe` False
            DelegatedSuite _ -> expectationFailure "expected native keycloak-invite plan"

      let bootstrapWithoutRunbook =
            NativeSuitePlan
              { nativeSuiteId = "synthetic-bootstrap"
              , nativeValidations = []
              , nativeInitialIntegrationGatePrerequisites = []
              , nativeDeferredIntegrationGatePrerequisites = []
              , nativeManagedAwsHarnessPolicyTier = Nothing
              , nativeRequiresIntegrationRunbook = False
              , nativeRequiresSupportedRuntimeBootstrap = True
              , nativeRequiresSupportedRuntimePostflight = False
              , nativeSubstrate = SubstrateHomeLocal
              }
      supportedRuntimeBootstrapNeedsReconcile bootstrapWithoutRunbook `shouldBe` True

    it "auto-destroys per-run stacks for targeted AWS-substrate Pulumi validations" $ do
      case testExecutionPlan SubstrateAws (TestIntegration IntegrationAwsEks) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-aws-eks"
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Just PolicyFull
              nativeRequiresSupportedRuntimeBootstrap suitePlan `shouldBe` False
              awsPostflightDestroyCommandArgs suitePlan
                `shouldBe` [ ["aws", "stack", "aws-subzone", "destroy", "--yes"]
                           , ["aws", "stack", "eks", "destroy", "--yes"]
                           , ["aws", "stack", "test", "destroy", "--yes"]
                           ]
            DelegatedSuite _ -> expectationFailure "expected native aws-eks plan"

      case testExecutionPlan SubstrateAws (TestIntegration IntegrationEksVolumeRebind) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-eks-volume-rebind"
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Just PolicyFull
              nativeValidations suitePlan `shouldBe` [ValidationEksVolumeRebind]
              awsPostflightDestroyCommandArgs suitePlan
                `shouldBe` [ ["aws", "stack", "aws-subzone", "destroy", "--yes"]
                           , ["aws", "stack", "eks", "destroy", "--yes"]
                           , ["aws", "stack", "test", "destroy", "--yes"]
                           ]
            DelegatedSuite _ -> expectationFailure "expected native eks-volume-rebind plan"

    it "maps cluster-backed named suites to native validations plus prerequisites" $ do
      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationAwsEks) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-aws-eks"
              nativeValidations suitePlan `shouldBe` [ValidationAwsEks]
              map prerequisiteIdText (nativeInitialIntegrationGatePrerequisites suitePlan)
                `shouldBe` [ "host_substrate_supported"
                           , "tool_docker"
                           , "tool_ctr"
                           , "tool_helm"
                           , "tool_kubectl"
                           , "tool_sudo"
                           , "tool_systemctl"
                           , "settings_object"
                           , "aws_credentials_valid"
                           , "tool_pulumi"
                           ]
              map prerequisiteIdText (nativeDeferredIntegrationGatePrerequisites suitePlan)
                `shouldBe` ["pulumi_logged_in"]
              nativeRequiresIntegrationRunbook suitePlan `shouldBe` True
            DelegatedSuite _ -> expectationFailure "expected native aws-eks plan"

      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationSealedVault) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-sealed-vault"
              nativeValidations suitePlan `shouldBe` [ValidationSealedVault]
              map prerequisiteIdText (nativeInitialIntegrationGatePrerequisites suitePlan)
                `shouldBe` [ "host_substrate_supported"
                           , "tool_docker"
                           , "tool_ctr"
                           , "tool_helm"
                           , "tool_kubectl"
                           , "tool_sudo"
                           , "tool_systemctl"
                           , "settings_object"
                           ]
              nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Nothing
              nativeRequiresIntegrationRunbook suitePlan `shouldBe` True
              integrationRunbookCommandArgs suitePlan `shouldBe` [["cluster", "reconcile"]]
            DelegatedSuite _ -> expectationFailure "expected native sealed-vault plan"

      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationDaemonBootstrap) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-daemon-bootstrap"
              nativeValidations suitePlan `shouldBe` [ValidationDaemonBootstrap]
              nativeInitialIntegrationGatePrerequisites suitePlan `shouldBe` []
              nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Nothing
              nativeRequiresIntegrationRunbook suitePlan `shouldBe` False
              integrationRunbookCommandArgs suitePlan `shouldBe` []
            DelegatedSuite _ -> expectationFailure "expected native daemon-bootstrap plan"

      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationPulsarBroker) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-pulsar-broker"
              nativeValidations suitePlan `shouldBe` [ValidationPulsarBroker]
              map prerequisiteIdText (nativeInitialIntegrationGatePrerequisites suitePlan)
                `shouldBe` [ "host_substrate_supported"
                           , "tool_docker"
                           , "tool_ctr"
                           , "tool_helm"
                           , "tool_kubectl"
                           , "tool_sudo"
                           , "tool_systemctl"
                           , "settings_object"
                           ]
              nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Nothing
              nativeRequiresIntegrationRunbook suitePlan `shouldBe` False
              integrationRunbookCommandArgs suitePlan `shouldBe` []
            DelegatedSuite _ -> expectationFailure "expected native pulsar-broker plan"

      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationEksVolumeRebind) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-eks-volume-rebind"
              nativeValidations suitePlan `shouldBe` [ValidationEksVolumeRebind]
              map prerequisiteIdText (nativeInitialIntegrationGatePrerequisites suitePlan)
                `shouldBe` [ "host_substrate_supported"
                           , "tool_docker"
                           , "tool_ctr"
                           , "tool_helm"
                           , "tool_kubectl"
                           , "tool_sudo"
                           , "tool_systemctl"
                           , "settings_object"
                           ]
              nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Nothing
              nativeRequiresIntegrationRunbook suitePlan `shouldBe` True
              integrationRunbookCommandArgs suitePlan `shouldBe` [["cluster", "reconcile", "--with-edge"]]
            DelegatedSuite _ -> expectationFailure "expected native eks-volume-rebind plan"

    it "gates AWS-backed named suites on validated access before validation bodies run" $ do
      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationPublicDns) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              map prerequisiteIdText (nativeInitialIntegrationGatePrerequisites suitePlan)
                `shouldBe` ["route53_lifecycle_capable", "tool_dig"]
              nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
            DelegatedSuite _ -> expectationFailure "expected native public-dns plan"

      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationDnsAws) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              map prerequisiteIdText (nativeInitialIntegrationGatePrerequisites suitePlan)
                `shouldBe` ["route53_lifecycle_capable"]
              nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
            DelegatedSuite _ -> expectationFailure "expected native dns-aws plan"

      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationAwsIam) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              map prerequisiteIdText (nativeInitialIntegrationGatePrerequisites suitePlan)
                `shouldBe` ["aws_iam_harness_ready", "tool_aws"]
              nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Just PolicyFull
            DelegatedSuite _ -> expectationFailure "expected native aws-iam plan"

    it "includes curl in the gateway-daemon validation prerequisites" $ do
      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationGatewayDaemon) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              map prerequisiteIdText (nativeInitialIntegrationGatePrerequisites suitePlan)
                `shouldBe` [ "host_substrate_supported"
                           , "tool_docker"
                           , "tool_ctr"
                           , "tool_helm"
                           , "tool_kubectl"
                           , "tool_sudo"
                           , "tool_systemctl"
                           , "settings_object"
                           , "tool_curl"
                           ]
              nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
            DelegatedSuite _ -> expectationFailure "expected native gateway-daemon plan"

    -- Sprint 5.6: the capability-derived IAM-harness tier. The deleted
    -- normalizeManagedAwsHarness substrate=aws blanket override used to
    -- force PolicyFull for ANY non-empty validation set on AWS, including
    -- credential-free ones. The tier now follows declared capabilities.
    it "does NOT acquire the IAM harness for a credential-free validation on the AWS substrate" $ do
      -- gateway-partition is fully in-process and declares NO prerequisites,
      -- so it engages no AWS credentials. On the AWS substrate it must still
      -- get tier Nothing (no harness), pinning the deleted blanket override.
      validationInitialPrerequisites ValidationGatewayPartition `shouldBe` []
      validationDeferredPrerequisites ValidationGatewayPartition `shouldBe` []
      case testExecutionPlan SubstrateAws (TestIntegration IntegrationGatewayPartition) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-gateway-partition"
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Nothing
            DelegatedSuite _ -> expectationFailure "expected native gateway-partition plan"
      -- And on the home substrate it is likewise harness-free.
      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationGatewayPartition) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan ->
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Nothing
            DelegatedSuite _ -> expectationFailure "expected native gateway-partition plan"
      -- Direct derivation: a credential-free validation never engages the
      -- harness regardless of substrate.
      derivedManagedAwsHarnessPolicyTier SubstrateAws [ValidationGatewayPartition]
        `shouldBe` Nothing
      derivedManagedAwsHarnessPolicyTier SubstrateHomeLocal [ValidationGatewayPartition]
        `shouldBe` Nothing

    it "derives the IAM-harness tier from declared capabilities, not a substrate blanket" $ do
      -- A credential-consuming validation (aws-eks needs aws_credentials_valid)
      -- engages the harness ON the AWS substrate (where aws.* is materialized
      -- by the harness) but not on the home substrate (where aws.* is
      -- configured directly).
      derivedManagedAwsHarnessPolicyTier SubstrateAws [ValidationAwsEks]
        `shouldBe` Just PolicyFull
      derivedManagedAwsHarnessPolicyTier SubstrateHomeLocal [ValidationAwsEks]
        `shouldBe` Nothing
      -- aws-iam and keycloak-invite materialize operational credentials
      -- through the harness on EVERY substrate.
      derivedManagedAwsHarnessPolicyTier SubstrateHomeLocal [ValidationAwsIam]
        `shouldBe` Just PolicyFull
      derivedManagedAwsHarnessPolicyTier SubstrateHomeLocal [ValidationKeycloakInvite]
        `shouldBe` Just PolicyFull
      -- eks-volume-rebind owns AWS per-run stack mutation only on the AWS
      -- substrate; the home substrate run is cluster-only.
      derivedManagedAwsHarnessPolicyTier SubstrateAws [ValidationEksVolumeRebind]
        `shouldBe` Just PolicyFull
      derivedManagedAwsHarnessPolicyTier SubstrateHomeLocal [ValidationEksVolumeRebind]
        `shouldBe` Nothing
      -- The deleted blanket override no longer lives in TestPlan: neither
      -- its definition/dispatch nor its substrate=aws blanket match arm.
      -- (The name still appears in a doc comment narrating the deletion,
      -- so target the code constructs, not the bare name.)
      repoRoot <- getCurrentDirectory
      testPlanSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "TestPlan.hs")
      testPlanSource `shouldNotContain` "normalizeManagedAwsHarness ::"
      testPlanSource `shouldNotContain` "normalizeManagedAwsHarness suitePlan"
      testPlanSource `shouldNotContain` "(Nothing, SubstrateAws, _ : _)"

    it "declares exactly the typed prerequisites each validation consumes (minimal-and-precise)" $ do
      -- The public-edge-readiness validations gate on the AWS-credential-free
      -- public_edge_ready node + curl; no cluster/creds/pulumi bundle.
      validationInitialPrerequisites ValidationChartsApi
        `shouldBe` [PublicEdgeReady, ToolCurl]
      validationInitialPrerequisites ValidationChartsWebsocket
        `shouldBe` [PublicEdgeReady, ToolCurl]
      validationDeferredPrerequisites ValidationChartsApi `shouldBe` []
      -- No charts-* validation declares an IAM-harness-engaging prerequisite.
      let chartsValidations =
            [ ValidationChartsVscode
            , ValidationChartsApi
            , ValidationChartsWebsocket
            , ValidationAdminRoutes
            ]
      all
        ( \validation ->
            not
              ( any
                  prerequisiteIdEngagesIamHarness
                  ( validationInitialPrerequisites validation
                      ++ validationDeferredPrerequisites validation
                  )
              )
        )
        chartsValidations
        `shouldBe` True

    it "keeps gateway-partition on a native validation path distinct from tla-check" $ do
      repoRoot <- getCurrentDirectory
      validationSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "TestValidation.hs")

      validationSource `shouldContain` "ValidationGatewayPartition -> runGatewayPartitionValidation"
      validationSource `shouldContain` "FORMAL_MODEL_DELEGATED=false"
      validationSource
        `shouldNotContain` "ValidationGatewayPartition -> runNativeCliCommandForExitCode repoRoot environment [\"tla-check\"]"

    it "routes sealed-vault through a native validation path" $ do
      repoRoot <- getCurrentDirectory
      validationSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "TestValidation.hs")

      validationSource `shouldContain` "ValidationSealedVault -> runSealedVaultValidation"
      nativeValidationId ValidationSealedVault `shouldBe` "sealed-vault"

    it "routes pulsar-broker through a native live broker validation path" $ do
      repoRoot <- getCurrentDirectory
      validationSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "TestValidation.hs")

      validationSource `shouldContain` "ValidationPulsarBroker ->"
      validationSource `shouldContain` "runPulsarBrokerValidation"
      nativeValidationId ValidationPulsarBroker `shouldBe` "pulsar-broker"

    it "Sprint 5.12 routes eks-volume-rebind through a native validation path" $ do
      repoRoot <- getCurrentDirectory
      validationSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "TestValidation.hs")

      validationSource `shouldContain` "ValidationEksVolumeRebind ->"
      validationSource `shouldContain` "runEksVolumeRebindValidation"
      nativeValidationId ValidationEksVolumeRebind `shouldBe` "eks-volume-rebind"

    it "Sprint 5.13 routes resource-guardrails through a native validation path" $ do
      repoRoot <- getCurrentDirectory
      validationSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "TestValidation.hs")

      validationSource `shouldContain` "ValidationResourceGuardrails ->"
      validationSource `shouldContain` "runResourceGuardrailsValidation"
      nativeValidationId ValidationResourceGuardrails `shouldBe` "resource-guardrails"

    it "Sprint 5.14 routes daemon-bootstrap through a native validation path" $ do
      repoRoot <- getCurrentDirectory
      validationSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "TestValidation.hs")

      validationSource `shouldContain` "ValidationDaemonBootstrap ->"
      validationSource `shouldContain` "runDaemonBootstrapValidation"
      nativeValidationId ValidationDaemonBootstrap `shouldBe` "daemon-bootstrap"

    it "Sprint 5.14 accepts only daemon-mediated bootstrap transports" $ do
      case daemonBootstrapAuditReport defaultDaemonBootstrapAuditInput of
        Left err -> expectationFailure err
        Right report -> do
          report `shouldContain` "DAEMON_BOOTSTRAP_VALIDATION"
          report `shouldContain` "DAEMON_AVAILABLE=true"
          report `shouldContain` "/v1/bootstrap/vault/ensure"
          report `shouldContain` "LEGACY_TRANSPORTS=0"
          report `shouldContain` "HOST_ROOT_TOKEN_FALLBACKS=0"
          report `shouldContain` "REDACTION=ok"

    it "Sprint 5.14 rejects legacy MinIO, direct Vault, and root-token fallback traces" $ do
      let minioTrace =
            defaultDaemonBootstrapAuditInput
              { daemonBootstrapObservedTransports =
                  "kubectl port-forward service/minio 39000:9000"
                    : daemonBootstrapObservedTransports defaultDaemonBootstrapAuditInput
              }
          vaultTrace =
            defaultDaemonBootstrapAuditInput
              { daemonBootstrapObservedTransports =
                  "POST http://127.0.0.1:31820/v1/sys/unseal"
                    : daemonBootstrapObservedTransports defaultDaemonBootstrapAuditInput
              }
          rootTokenTrace =
            defaultDaemonBootstrapAuditInput
              { daemonBootstrapObservedOutput =
                  "falling back to host Vault root-token write"
                    : daemonBootstrapObservedOutput defaultDaemonBootstrapAuditInput
              }
      map
        (`elem` daemonBootstrapForbiddenPatterns)
        ["kubectl port-forward", "127.0.0.1:31820", "host root-token"]
        `shouldBe` [True, True, True]
      daemonBootstrapAuditReport minioTrace
        `shouldSatisfy` leftContains "legacy transport"
      daemonBootstrapAuditReport vaultTrace
        `shouldSatisfy` leftContains "legacy transport"
      daemonBootstrapAuditReport rootTokenTrace
        `shouldSatisfy` leftContains "legacy transport"

    it "Sprint 5.14 fails closed on unavailable daemon, missing routes, or leaked secrets" $ do
      let unavailableTrace =
            defaultDaemonBootstrapAuditInput
              { daemonBootstrapDaemonAvailable = False
              }
          missingRouteTrace =
            defaultDaemonBootstrapAuditInput
              { daemonBootstrapRequiredDaemonPaths =
                  "/v1/bootstrap/vault/ensure-missing"
                    : daemonBootstrapRequiredDaemonPaths defaultDaemonBootstrapAuditInput
              }
          leakyTrace =
            defaultDaemonBootstrapAuditInput
              { daemonBootstrapObservedOutput =
                  "vault-unseal-key-1"
                    : daemonBootstrapObservedOutput defaultDaemonBootstrapAuditInput
              }
      daemonBootstrapAuditReport unavailableTrace
        `shouldSatisfy` leftContains "unavailable daemon"
      daemonBootstrapAuditReport missingRouteTrace
        `shouldSatisfy` leftContains "missing daemon routes"
      daemonBootstrapAuditReport leakyTrace
        `shouldSatisfy` leftContains "unredacted secret sample"

    it "Sprint 5.13 validates capped pod resources and namespace guardrail objects" $ do
      case resourceGuardrailReport
        Capacity.defaultResourcePlan
        resourceGuardrailPodsFixture
        resourceGuardrailQuotaFixture
        resourceGuardrailLimitRangeFixture of
        Left err -> expectationFailure err
        Right report -> do
          report `shouldContain` "RESOURCE_GUARDRAILS_VALIDATION"
          report `shouldContain` "PODS_CHECKED=5"
          report `shouldContain` "CONTAINERS_CHECKED=5"
          report `shouldContain` "QUOTA_NAMESPACES=keycloak,vscode,api,websocket,gateway"
          report `shouldContain` "LIMIT_RANGE_NAMESPACES=keycloak,vscode,api,websocket,gateway"
          report `shouldContain` "BESTEFFORT_PODS=0"
          report `shouldContain` "UNCAPPED_CONTAINERS=0"

    it "Sprint 5.13 accepts Kubernetes-canonicalized guardrail quantities" $ do
      case resourceGuardrailReport
        Capacity.defaultResourcePlan
        resourceGuardrailPodsFixture
        resourceGuardrailCanonicalQuotaFixture
        resourceGuardrailCanonicalLimitRangeFixture of
        Left err -> expectationFailure err
        Right report ->
          report `shouldContain` "RESOURCE_GUARDRAILS_VALIDATION"

    it "Sprint 5.13 rejects BestEffort or uncapped pods in resource namespaces" $ do
      let result =
            resourceGuardrailReport
              Capacity.defaultResourcePlan
              resourceGuardrailBadPodsFixture
              resourceGuardrailQuotaFixture
              resourceGuardrailLimitRangeFixture
      result `shouldSatisfy` isLeft
      case result of
        Left err -> do
          err `shouldContain` "pod api/api-0 is BestEffort"
          err `shouldContain` "api/api-0 container api is missing `resources.requests.cpu`"
        Right _ -> expectationFailure "expected resource-guardrails report to reject uncapped pod"

    it "Sprint 5.12 parses retained PV snapshots from Kubernetes JSON" $ do
      let pvJson =
            object
              [ "metadata"
                  .= object
                    ["name" .= ("pv-prodbox-minio-0" :: String)]
              , "spec"
                  .= object
                    [ "claimRef"
                        .= object
                          [ "namespace" .= ("prodbox" :: String)
                          , "name" .= ("data-minio-0" :: String)
                          ]
                    , "csi" .= object ["volumeHandle" .= ("vol-012345" :: String)]
                    ]
              , "status" .= object ["phase" .= ("Bound" :: String)]
              ]

      parseVolumeRebindSnapshot pvJson
        `shouldBe` Right
          VolumeRebindSnapshot
            { volumeRebindSnapshotPersistentVolume = "pv-prodbox-minio-0"
            , volumeRebindSnapshotClaimNamespace = "prodbox"
            , volumeRebindSnapshotPersistentClaim = "data-minio-0"
            , volumeRebindSnapshotPhase = "Bound"
            , volumeRebindSnapshotVolumeHandle = Just "vol-012345"
            }

    it "Sprint 5.12 reports success only when the same PV/PVC/handle keeps the sentinel" $ do
      let before =
            VolumeRebindSnapshot
              { volumeRebindSnapshotPersistentVolume = "pv-prodbox-minio-0"
              , volumeRebindSnapshotClaimNamespace = "prodbox"
              , volumeRebindSnapshotPersistentClaim = "data-minio-0"
              , volumeRebindSnapshotPhase = "Bound"
              , volumeRebindSnapshotVolumeHandle = Just "vol-012345"
              }
          after = before

      volumeRebindReport before after "sentinel" "sentinel"
        `shouldBe` Right
          ( unlines
              [ "VOLUME_REBIND_VALIDATION"
              , "PV=pv-prodbox-minio-0"
              , "PVC=prodbox/data-minio-0"
              , "PHASE_BEFORE=Bound"
              , "PHASE_AFTER=Bound"
              , "VOLUME_HANDLE=vol-012345"
              , "SENTINEL=preserved"
              ]
          )
      volumeRebindReport before after "sentinel" "different"
        `shouldBe` Left "sentinel mismatch: expected `sentinel`, observed `different`"
      volumeRebindReport
        before
        after {volumeRebindSnapshotVolumeHandle = Just "vol-different"}
        "sentinel"
        "sentinel"
        `shouldBe` Left "volume handle mismatch: expected `vol-012345`, observed `vol-different`"

    it "Sprint 5.8 sealed-Vault audit accepts only opaque sealed-state surfaces" $ do
      let audit =
            defaultSealedVaultAuditInput
              { sealedVaultObjectKeys = ["objects/6d1f.enc", "indexes/ab91.enc"]
              , sealedVaultHostDiskEntries =
                  [ ".data/prodbox/minio/0/prodbox-state/objects/6d1f.enc"
                  , ".data/prodbox/minio/0/prodbox-state/indexes/ab91.enc"
                  ]
              , sealedVaultKubernetesObjectNames =
                  [ "secret/vault-transit-seal-token"
                  , "configmap/gateway-config"
                  ]
              , sealedVaultLogLines =
                  [ "vault_status=sealed component=residue-query result=unobservable"
                  , "vault_status=sealed component=long-lived-object result=unobservable"
                  ]
              }

      sealedVaultAuditReport audit
        `shouldBe` Right
          ( unlines
              [ "SEALED_VAULT_AUDIT=pass"
              , "SEALED_VAULT_BUCKETS=1"
              , "SEALED_VAULT_OBJECT_KEYS=2"
              , "SEALED_VAULT_HOST_DISK_ENTRIES=2"
              , "SEALED_VAULT_K8S_OBJECTS=2"
              , "SEALED_VAULT_LOG_LINES=2"
              ]
          )

    it "Sprint 5.8 sealed-Vault audit rejects role names, raw stack keys, and secret literals" $ do
      let leakyAudit =
            defaultSealedVaultAuditInput
              { sealedVaultBucketNames = ["prodbox-state", "prodbox-test-pulumi-backends"]
              , sealedVaultObjectKeys = ["objects/aws-eks.json"]
              , sealedVaultKubernetesObjectNames = ["secret/child-a-kubeconfig"]
              , sealedVaultLogLines = ["client_secret = \"cleartext\""]
              }

      sealedVaultAuditReport leakyAudit
        `shouldBe` Left
          "sealed Vault audit found role-revealing bucket names: [\"prodbox-test-pulumi-backends\"]"

    it "Sprint 5.8 generated Dhall/config artifacts stay SecretRef-only" $ do
      repoRoot <- getCurrentDirectory
      apiChartConfig <-
        readFile (repoRoot </> "charts" </> "api" </> "templates" </> "configmap-config.yaml")
      gatewayChartConfig <-
        readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "configmap-config.yaml")
      gatewayChartHelpers <-
        readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "_helpers.tpl")
      gatewayOrdersConfig <-
        readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "configmap-orders.yaml")
      websocketChartConfig <-
        readFile (repoRoot </> "charts" </> "websocket" </> "templates" </> "configmap-config.yaml")

      let renderedConfigDhall = renderConfigDhall roundTripConfigFile
          renderedInForcePayload =
            Text.unpack (TextEncoding.decodeUtf8 (renderInForcePayload roundTripConfigFile))
          renderedGatewayConfig =
            renderGatewayConfigTemplate (testValidatedSettings "/tmp/prodbox/.data") "node-a"
          gatewayChartArtifact = gatewayChartConfig ++ "\n" ++ gatewayChartHelpers
          artifacts =
            [ ("renderConfigDhall prodbox-config.dhall", True, renderedConfigDhall)
            , ("renderInForcePayload config.dhall", True, renderedInForcePayload)
            , ("gateway config-gen config.dhall", True, renderedGatewayConfig)
            , ("api chart config.dhall template", False, apiChartConfig)
            , ("gateway chart config.dhall template", True, gatewayChartArtifact)
            , ("gateway chart orders.dhall template", False, gatewayOrdersConfig)
            , ("websocket chart config.dhall template", True, websocketChartConfig)
            ]

      forM_ artifacts assertGeneratedSecretRefArtifact

    it "consumes gateway trust material and configured listener hosts in the daemon runtime" $ do
      repoRoot <- getCurrentDirectory
      daemonSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Gateway" </> "Daemon.hs")
      gatewaySource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Gateway.hs")

      daemonSource `shouldContain` "validateDaemonStartupInputs"
      daemonSource `shouldContain` "daemonCertFile"
      daemonSource `shouldContain` "daemonKeyFile"
      daemonSource `shouldContain` "daemonCaFile"
      daemonSource `shouldContain` "peerRestHost localPeer"
      daemonSource `shouldContain` "peerSocketHost localPeer"
      daemonSource `shouldContain` "withListeningSocket \"REST server\""
      daemonSource `shouldContain` "withListeningSocket \"Peer events listener\""
      gatewaySource `shouldContain` "resolveDaemonInputPaths"

    it "keeps charts-vscode on the supported runtime bootstrap path" $ do
      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationChartsVscode) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-charts-vscode"
              nativeValidations suitePlan `shouldBe` [ValidationChartsVscode]
              -- Sprint 5.6: charts-vscode gates on the AWS-credential-free
              -- public_edge_ready node (+ curl for the HTTPS probe), not the
              -- old cluster + aws_credentials + pulumi bundle. No AWS
              -- credentials, no pulumi login.
              map prerequisiteIdText (nativeInitialIntegrationGatePrerequisites suitePlan)
                `shouldBe` ["public_edge_ready", "tool_curl"]
              nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Nothing
              nativeRequiresIntegrationRunbook suitePlan `shouldBe` True
              nativeRequiresSupportedRuntimeBootstrap suitePlan `shouldBe` True
            DelegatedSuite _ -> expectationFailure "expected native charts-vscode plan"

    it "keeps admin-routes on the supported runtime bootstrap path" $ do
      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationAdminRoutes) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-admin-routes"
              nativeValidations suitePlan `shouldBe` [ValidationAdminRoutes]
              -- Sprint 5.6: admin-routes is re-pointed to the
              -- AWS-credential-free public_edge_ready gate as well.
              map prerequisiteIdText (nativeInitialIntegrationGatePrerequisites suitePlan)
                `shouldBe` ["public_edge_ready", "tool_curl"]
              nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Nothing
              nativeRequiresIntegrationRunbook suitePlan `shouldBe` True
              nativeRequiresSupportedRuntimeBootstrap suitePlan `shouldBe` True
            DelegatedSuite _ -> expectationFailure "expected native admin-routes plan"

    it "waits for public-edge readiness during supported runtime restore actions" $ do
      repoRoot <- getCurrentDirectory
      runnerSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "TestRunner.hs")

      runnerSource `shouldContain` "runWaitForPublicEdgeReady"
      runnerSource `shouldContain` "publicEdgeReadyAttempts = 60"
      runnerSource `shouldContain` "publicEdgeReadyDelayMicroseconds = 10000000"
      runnerSource `shouldContain` "publicEdgeCertificateRepairAttempts = 3"
      runnerSource `shouldContain` "Detected failed public-edge certificate issuance"
      runnerSource `shouldContain` "no stale ACME resources remain, triggering immediate reissue"
      runnerSource `shouldContain` "\"certificaterequest,order,challenge\""
      runnerSource `shouldContain` "\"--subresource=status\""
      runnerSource `shouldContain` "Certificate renewal manually triggered by prodbox"
      runnerSource
        `shouldContain` "\"jsonpath={.status.failedIssuanceAttempts}{\\\"|\\\"}{.status.nextPrivateKeySecretName}{\\\"|\\\"}{.metadata.generation}\""

    it "renders a valid public-edge certificate reissue status patch" $ do
      let patch =
            publicEdgeCertificateReissueStatusPatch
              "2026-06-06T18:05:00Z"
              PublicEdgeCertificateFailure
                { publicEdgeFailedIssuanceAttempts = 1
                , publicEdgeNextPrivateKeySecretName = Just "public-edge-tls-next"
                , publicEdgeCertificateObservedGeneration = Just 7
                }
      (eitherDecode (BL8.pack patch) :: Either String Value)
        `shouldSatisfy` isRight
      patch `shouldContain` "\"observedGeneration\":7"
      patch `shouldContain` "Certificate renewal manually triggered by prodbox"

    it "retains the public-edge TLS Secret payload without Kubernetes ownership metadata" $ do
      let sourceSecret =
            object
              [ "apiVersion" .= ("v1" :: String)
              , "kind" .= ("Secret" :: String)
              , "metadata"
                  .= object
                    [ "name" .= ("public-edge-tls" :: String)
                    , "namespace" .= ("vscode" :: String)
                    , "uid" .= ("source-uid" :: String)
                    , "resourceVersion" .= ("123" :: String)
                    , "ownerReferences"
                        .= [ object
                               [ "kind" .= ("Certificate" :: String)
                               , "name" .= ("public-edge-tls" :: String)
                               ]
                           ]
                    ]
              , "type" .= ("kubernetes.io/tls" :: String)
              , "data"
                  .= object
                    [ "tls.crt" .= ("encoded-cert" :: String)
                    , "tls.key" .= ("encoded-key" :: String)
                    ]
              ]
      case retainedPublicEdgeTlsSecretManifest "prodbox" "public-edge-tls-retained" sourceSecret of
        Left err -> expectationFailure err
        Right retainedSecret -> do
          let rendered = BL8.unpack (encode retainedSecret)
          rendered `shouldContain` "public-edge-tls-retained"
          rendered `shouldContain` "encoded-cert"
          rendered `shouldContain` "encoded-key"
          rendered `shouldNotContain` "ownerReferences"
          rendered `shouldNotContain` "resourceVersion"
          rendered `shouldNotContain` "source-uid"

    it "waits for stable Harbor endpoints before lifecycle image reconcile begins" $ do
      repoRoot <- getCurrentDirectory
      rke2Source <- readFile (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Rke2.hs")

      rke2Source `shouldContain` "waitForHarborStableEndpoints repoRoot"
      rke2Source `shouldContain` "harborEndpointStabilitySuccesses = 6"
      rke2Source `shouldContain` "harborEndpointStabilityDelayMicroseconds = 5000000"
      rke2Source `shouldContain` "ensureHarborRegistryStorageBackend repoRoot"
      -- The single-binary registry:2 (no Harbor helm chart) is applied with its
      -- own config.yml selecting the S3 storage driver against the MinIO bucket.
      rke2Source `shouldContain` "registryImage = \"registry:2\""
      rke2Source `shouldContain` "registryConfigYaml"
      rke2Source `shouldContain` "data RegistryStorageBackend = RegistryStorageBackend"
      rke2Source `shouldContain` "registryStorageBackendBucket = harborRegistryStorageBucket"
      -- The S3 storage driver MUST disable blob redirects. registry:2 otherwise
      -- answers blob GET/HEAD with a 307 to a presigned MinIO URL at the
      -- cluster-internal minio.prodbox.svc.cluster.local:9000, which the host-side
      -- mirror push/pull client cannot resolve (host DNS has no *.svc.cluster.local).
      -- The Harbor chart era set imageChartStorage.disableredirect=true; the
      -- registry:2 config.yml must carry the equivalent storage.redirect.disable
      -- stanza. Regression guard for the 80a08e3 migration.
      rke2Source `shouldContain` "registryStorageBackendRedirect = RedirectDisabled"
      rke2Source `shouldNotContain` "persistence.imageChartStorage.type=s3"
      rke2Source `shouldNotContain` "harbor/harbor"
      rke2Source `shouldContain` "mc mb --ignore-existing local/"

    it "Harbor bucket-init uses static MinIO root cred; gateway Job reads Vault (7.25)" $ do
      repoRoot <- getCurrentDirectory
      rke2Source <- readFile (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Rke2.hs")

      rke2Source `shouldContain` "resolveHarborStorageCredentials repoRoot"
      -- The gateway MinIO bootstrap Job runs AFTER Vault init/unseal and still
      -- materializes root creds from Vault via its init container.
      rke2Source `shouldContain` "vault-gateway-minio"
      rke2Source `shouldContain` "vault kv get -field=rootUser secret/minio/root"
      rke2Source `shouldContain` "\"serviceAccountName\" .= minioReleaseName"
      rke2Source `shouldContain` "MINIO_ROOT_USER_FILE"
      rke2Source `shouldContain` "HARBOR_STORAGE_ACCESS_KEY"
      -- The Harbor bucket-init Job runs BEFORE the daemon-mediated Vault init (a
      -- fresh cluster has no unsealed Vault yet, and Vault init itself depends on
      -- Harbor via the gateway image), so it must use the static MinIO root
      -- constant directly instead of a Vault init container.
      rke2Source `shouldContain` "\"value\" .= minioRootUser"
      rke2Source `shouldContain` "\"value\" .= minioRootPassword"
      rke2Source `shouldNotContain` "vault-minio-root"
      rke2Source `shouldNotContain` "readMinioRootCredentials"
      rke2Source `shouldNotContain` "secretKeyRef"

    it "retries transient Harbor publication failures during custom and mirrored image publication" $ do
      repoRoot <- getCurrentDirectory
      rke2Source <- readFile (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Rke2.hs")

      rke2Source `shouldContain` "customImagePushRetryPolicy :: RetryPolicy"
      rke2Source `shouldContain` "retryPolicyMaxAttempts = 3"
      rke2Source `shouldContain` "retryPolicyBaseDelayMicros = 5000000"
      rke2Source `shouldContain` "pushDockerImageWithRetry"
      rke2Source `shouldContain` "isRetryableHarborPublicationFailure"
      rke2Source `shouldContain` "Retrying Harbor publication for "
      rke2Source `shouldContain` "isRetryableTransientFailure"
      rke2Source `shouldContain` "\"unexpected status from put request\""

    it "keeps postgres-operator runtime on explicit Percona chart values" $ do
      repoRoot <- getCurrentDirectory
      rke2Source <- readFile (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Rke2.hs")

      rke2Source `shouldContain` "\"operatorImageRepository\""
      rke2Source `shouldContain` "\"watchAllNamespaces\" .= True"
      rke2Source `shouldContain` "\"disableTelemetry\" .= True"
      rke2Source `shouldContain` "\"fullnameOverride\" .= patroniOperatorDeploymentName"
      rke2Source `shouldNotContain` "removeLegacyTraefikIfPresent"
      rke2Source `shouldNotContain` "removeLegacyPostgresOperatorIfPresent"

    it "checks Pulumi login against the local MinIO backend path" $ do
      repoRoot <- getCurrentDirectory
      interpreterSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "EffectInterpreter.hs")
      minioSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "MinioBackend.hs")

      interpreterSource `shouldContain` "withMinioPortForward"
      interpreterSource `shouldContain` "ensureMinioBackendBucket"
      interpreterSource `shouldContain` "\"login\""
      interpreterSource `shouldContain` "\"--non-interactive\""
      interpreterSource `shouldContain` "PULUMI_BACKEND_URL"
      minioSource `shouldContain` "parseDeletedMinioExportHostPath"
      minioSource `shouldContain` "\"rollout\", \"restart\", \"statefulset/\" ++ minioDeploymentName"

    it "Sprint 3.19: retired master-seed derivation modules and RPCs stay absent" $ do
      repoRoot <- getCurrentDirectory
      let retiredModules =
            [ "src/Prodbox/Secret/Derive.hs"
            , "src/Prodbox/Secret/EnsureNamespace.hs"
            , "src/Prodbox/Secret/GatewayDeriveMode.hs"
            , "src/Prodbox/Secret/HostBootstrap.hs"
            , "src/Prodbox/Secret/Inventory.hs"
            , "src/Prodbox/Secret/MasterSeed.hs"
            , "src/Prodbox/Secret/Wire.hs"
            , "src/Prodbox/TestSeam/GatewayDerive.hs"
            ]
          retiredTokens =
            [ "Prodbox.Secret.Derive"
            , "Prodbox.Secret.EnsureNamespace"
            , "Prodbox.Secret.GatewayDeriveMode"
            , "Prodbox.Secret.HostBootstrap"
            , "Prodbox.Secret.Inventory"
            , "Prodbox.Secret.MasterSeed"
            , "Prodbox.Secret.Wire"
            , "Prodbox.TestSeam.GatewayDerive"
            , "/v1/secret/derive"
            , "/v1/secret/ensure-namespace"
            , "selfBootstrapOwnSecrets"
            , "ensureMasterSeed"
            ]
      forM_ retiredModules $ \path ->
        doesFileExist (repoRoot </> path) `shouldReturn` False
      cabalSource <- readFile (repoRoot </> "prodbox.cabal")
      daemonSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Gateway" </> "Daemon.hs")
      clientSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Gateway" </> "Client.hs")
      checkCodeSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "CheckCode.hs")
      gatewayValues <- readFile (repoRoot </> "charts" </> "gateway" </> "values.yaml")
      gatewayRbac <- readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "rbac.yaml")
      forM_
        [ cabalSource
        , daemonSource
        , clientSource
        , checkCodeSource
        , gatewayValues
        , gatewayRbac
        ]
        ( \source ->
            forM_ retiredTokens $ \token ->
              source `shouldNotContain` token
        )

    it "matches OIDC redirect headers without depending on percent-encoding case" $ do
      repoRoot <- getCurrentDirectory
      validationSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "TestValidation.hs")

      validationSource `shouldContain` "loweredExpectedTexts = map (map toLowerAscii) expectedTexts"
      validationSource `shouldContain` "loweredCombinedOutput = map toLowerAscii combinedOutput"

    it "retries transient websocket route timeouts during managed validation" $ do
      repoRoot <- getCurrentDirectory
      validationSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "TestValidation.hs")

      validationSource `shouldContain` "websocketConnectionAttempts = 4"
      validationSource `shouldContain` "websocketConnectionRetryDelayMicroseconds = 5000000"
      validationSource `shouldContain` "websocketDistinctConnectionRetryDelayMicroseconds = 1000000"
      validationSource `shouldContain` "websocketReceiveRetryDelayMicroseconds = 1000000"
      validationSource `shouldContain` "Waiting for websocket route readiness before retry"
      validationSource `shouldContain` "Waiting for a distinct websocket backend pod before retry."
      validationSource `shouldContain` "Waiting for websocket broadcast delivery before retry"
      validationSource `shouldContain` "shouldRetryTransientWebsocketOpenError"
      validationSource `shouldContain` "shouldRetryTransientWebsocketReceiveError"

    it "decodes websocket and HTTP JSON payloads through UTF-8-safe helpers" $ do
      repoRoot <- getCurrentDirectory
      validationSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "TestValidation.hs")

      validationSource `shouldContain` "decodeJsonTextUtf8"
      validationSource `shouldContain` "decodeJsonStringUtf8"
      validationSource `shouldContain` "BL.fromStrict . TextEncoding.encodeUtf8"

    it "waits for websocket socket readability before parsing frames" $ do
      repoRoot <- getCurrentDirectory
      workloadSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Workload.hs")

      workloadSource `shouldContain` "threadWaitRead"
      workloadSource `shouldContain` "withFdSocket"
      workloadSource `shouldContain` "if BS.null bufferedFrameBytes"
      workloadSource
        `shouldNotContain` "timeout websocketPollDelayMicroseconds (readWebSocketFrame clientSocket frameBuffer)"

    it "preserves websocket bytes buffered behind the HTTP upgrade request" $ do
      repoRoot <- getCurrentDirectory
      workloadSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Workload.hs")

      workloadSource `shouldContain` "Right (request, requestRemainder) ->"
      workloadSource
        `shouldContain` "handleWebsocketUpgrade runtime clientSocket requestRemainder request"
      workloadSource `shouldContain` "parseHttpRequestWithRemainder"
      workloadSource `shouldContain` "frameBuffer <- newIORef initialFrameBytes"

    it "rolls custom-image chart workloads when the local image build changes" $ do
      repoRoot <- getCurrentDirectory
      chartPlatformSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Lib" </> "ChartPlatform.hs")
      apiTemplate <- readFile (repoRoot </> "charts" </> "api" </> "templates" </> "deployment.yaml")
      websocketTemplate <-
        readFile (repoRoot </> "charts" </> "websocket" </> "templates" </> "deployment.yaml")
      gatewayTemplate <-
        readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "deployments.yaml")

      chartPlatformSource `shouldContain` "subprocessPath = \"docker\""
      chartPlatformSource
        `shouldContain` "subprocessArguments = [\"image\", \"inspect\", \"--format\", \"{{.Id}}\", imageRef]"
      chartPlatformSource `shouldContain` "\"prodbox.io/image-build-id\""
      apiTemplate `shouldContain` ".Values.podAnnotations"
      websocketTemplate `shouldContain` ".Values.podAnnotations"
      gatewayTemplate `shouldContain` "$.Values.podAnnotations"

    it "renders API and WebSocket JWT backchannels through Keycloak ReferenceGrants" $ do
      repoRoot <- getCurrentDirectory
      apiTemplate <- readFile (repoRoot </> "charts" </> "api" </> "templates" </> "http-route.yaml")
      websocketTemplate <-
        readFile (repoRoot </> "charts" </> "websocket" </> "templates" </> "http-route.yaml")

      forM_ [apiTemplate, websocketTemplate] $ \template -> do
        template `shouldContain` "kind: ReferenceGrant"
        template `shouldContain` "group: gateway.envoyproxy.io"
        template `shouldContain` "kind: SecurityPolicy"
        template `shouldContain` "namespace: {{ .Release.Namespace | quote }}"
        template `shouldContain` "remoteJWKS:"
        template `shouldContain` "backendRefs:"
        template `shouldContain` "namespace: {{ .Values.jwt.jwksBackend.namespace | quote }}"
        template `shouldContain` "port: {{ .Values.jwt.jwksBackend.servicePort }}"

    it "routes the Keycloak admin API used by operator invites through the auth HTTPRoute" $ do
      repoRoot <- getCurrentDirectory
      keycloakGatewayTemplate <-
        readFile (repoRoot </> "charts" </> "keycloak" </> "templates" </> "gateway.yaml")

      keycloakGatewayTemplate
        `shouldContain` "value: {{ printf \"%s/realms\" .Values.gateway.authPathPrefix | quote }}"
      keycloakGatewayTemplate
        `shouldContain` "value: {{ printf \"%s/admin\" .Values.gateway.authPathPrefix | quote }}"
      keycloakGatewayTemplate
        `shouldContain` "value: {{ printf \"%s/resources\" .Values.gateway.authPathPrefix | quote }}"

    it "routes chart PostgreSQL service calls through the capability boundary" $ do
      repoRoot <- getCurrentDirectory
      chartPlatformSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Lib" </> "ChartPlatform.hs")
      minioSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "MinioBackend.hs")
      serviceSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Service.hs")

      chartPlatformSource `shouldContain` "observePatroniOperatorAvailableWith"
      chartPlatformSource `shouldContain` "result <- runPg arguments"
      chartPlatformSource `shouldContain` "runPgExpectSuccess"
      chartPlatformSource `shouldNotContain` "subprocessPath = \"redis-cli\""
      chartPlatformSource `shouldNotContain` "subprocessPath = \"psql\""
      minioSource `shouldContain` "runMinIOWithEnv"
      minioSource `shouldNotContain` "subprocessPath = \"aws\""
      serviceSource `shouldContain` "instance HasPg IO"
      serviceSource `shouldContain` "instance HasRedis IO"
      serviceSource `shouldContain` "instance HasMinIO IO"

    it "keeps Pulumi AWS provider credentials out of stack-local config" $ do
      repoRoot <- getCurrentDirectory
      eksProgram <- readFile (repoRoot </> "pulumi" </> "aws-eks" </> "Main.yaml")
      testProgram <- readFile (repoRoot </> "pulumi" </> "aws-test" </> "Main.yaml")
      eksStackSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "AwsEksTestStack.hs")
      testStackSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "AwsTestStack.hs")

      eksProgram `shouldContain` "envVarMappings"
      eksProgram `shouldContain` "PRODBOX_PULUMI_AWS_ACCESS_KEY_ID"
      eksProgram `shouldNotContain` "awsAccessKeyId:"
      eksProgram `shouldNotContain` "awsSecretAccessKey:"
      eksProgram `shouldNotContain` "awsSessionToken:"
      testProgram `shouldContain` "envVarMappings"
      testProgram `shouldContain` "PRODBOX_PULUMI_AWS_ACCESS_KEY_ID"
      testProgram `shouldNotContain` "awsAccessKeyId:"
      testProgram `shouldNotContain` "awsSecretAccessKey:"
      testProgram `shouldNotContain` "awsSessionToken:"
      eksStackSource `shouldContain` "PRODBOX_PULUMI_AWS_ACCESS_KEY_ID"
      eksStackSource `shouldNotContain` "clearLegacyAwsProviderConfig"
      eksStackSource `shouldNotContain` "(True, \"awsAccessKeyId\""
      eksStackSource `shouldNotContain` "(True, \"awsSecretAccessKey\""
      eksStackSource `shouldNotContain` "(True, \"awsSessionToken\""
      testStackSource `shouldContain` "PRODBOX_PULUMI_AWS_ACCESS_KEY_ID"
      testStackSource `shouldNotContain` "clearLegacyAwsProviderConfig"
      testStackSource `shouldNotContain` "(True, \"awsAccessKeyId\""
      testStackSource `shouldNotContain` "(True, \"awsSecretAccessKey\""
      testStackSource `shouldNotContain` "(True, \"awsSessionToken\""

    it "keeps integration-cli fully on the Haskell-owned CLI suite" $ do
      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationCli) of
        testPlan -> do
          testPlanHaskellSuites testPlan `shouldBe` ["test:prodbox-integration"]
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-cli"
              nativeValidations suitePlan `shouldBe` []
              nativeInitialIntegrationGatePrerequisites suitePlan `shouldBe` []
              nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
              nativeRequiresIntegrationRunbook suitePlan `shouldBe` False
            DelegatedSuite _ -> expectationFailure "expected native integration-cli plan"

    it "keeps integration-env fully on the Haskell-owned env suite" $ do
      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationEnv) of
        testPlan -> do
          testPlanHaskellSuites testPlan `shouldBe` ["test:prodbox-integration"]
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-env"
              nativeValidations suitePlan `shouldBe` []
              nativeInitialIntegrationGatePrerequisites suitePlan `shouldBe` []
              nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
              nativeRequiresIntegrationRunbook suitePlan `shouldBe` False
            DelegatedSuite _ -> expectationFailure "expected native integration-env plan"

    it "expands prerequisite closures transitively and deterministically" $ do
      transitiveClosureTexts ["tool_systemctl", "supported_ubuntu_2404"]
        `shouldBe` Right ["platform_linux", "supported_ubuntu_2404", "systemd_available", "tool_systemctl"]

  describe "prerequisite registry" $ do
    it "covers the full shared prerequisite inventory" $ do
      sort (map prerequisiteIdText (Map.keys prerequisiteRegistry))
        `shouldBe` sort
          [ "platform_linux"
          , "host_substrate_supported"
          , "systemd_available"
          , "supported_ubuntu_2404"
          , "machine_identity"
          , "tool_curl"
          , "tool_dig"
          , "tool_kubectl"
          , "tool_docker"
          , "tool_ctr"
          , "tool_helm"
          , "tool_sudo"
          , "tool_pulumi"
          , "tool_aws"
          , "tool_ssh"
          , "tool_rke2"
          , "tool_systemctl"
          , "settings_object"
          , "aws_iam_harness_ready"
          , "kubeconfig_exists"
          , "kubeconfig_home_exists"
          , "rke2_config_exists"
          , "aws_credentials_valid"
          , "route53_accessible"
          , "route53_lifecycle_capable"
          , "rke2_installed"
          , "rke2_service_exists"
          , "rke2_service_active"
          , "k8s_cluster_reachable"
          , "pulumi_logged_in"
          , "k8s_ready"
          , "infra_ready"
          , "public_edge_ready"
          , "gateway_daemon_acquire"
          , "ses_sending_identity_verified"
          , "ses_receive_rule_set_active"
          , "ses_receive_bucket_accessible"
          ]

    it "keeps registry keys aligned with effect node ids and descriptions" $ do
      mapM_
        ( \(key, node) -> do
            effectNodeId node `shouldBe` key
            effectNodeDescription node `shouldNotBe` ""
            effectNodeRemedyHint node `shouldNotBe` ""
        )
        (Map.toList prerequisiteRegistry)

    it "keeps every prerequisite reference inside the registry" $ do
      mapM_
        (\node -> all (`Map.member` prerequisiteRegistry) (effectNodePrerequisites node) `shouldBe` True)
        (Map.elems prerequisiteRegistry)

    -- Regression guard (demoted from the authoritative acyclicity gate): acyclicity is now
    -- enforced at construction time in `transitiveClosureIds`/`fromRootIds` (see the
    -- "construction-time acyclicity" group below). This static `hasCycle` scan over the shipped
    -- registry remains as defense-in-depth per prerequisite_dag_system.md §3.
    it "regression guard: the shipped registry has no direct self-reference or dependency cycles" $ do
      all
        (\(key, node) -> key `notElem` effectNodePrerequisites node)
        (Map.toList prerequisiteRegistry)
        `shouldBe` True
      all (not . hasCycle Set.empty) (Map.keys prerequisiteRegistry) `shouldBe` True
      -- The shipped registry must also construct cleanly from every node as a root, since
      -- construction is the authoritative acyclicity gate.
      all
        (\nodeId -> isRightResult (fromRootIds [nodeId] prerequisiteRegistry))
        (Map.keys prerequisiteRegistry)
        `shouldBe` True

    it "keeps the expected dependency chains for infrastructure prerequisites" $ do
      lookupPrereqTexts "aws_credentials_valid"
        `shouldBe` ["settings_object", "tool_aws"]
      lookupPrereqTexts "aws_iam_harness_ready"
        `shouldBe` []
      lookupPrereqTexts "route53_accessible"
        `shouldBe` ["aws_credentials_valid"]
      lookupPrereqTexts "route53_lifecycle_capable"
        `shouldBe` ["route53_accessible"]
      lookupPrereqTexts "rke2_service_exists"
        `shouldBe` ["rke2_installed", "systemd_available", "host_substrate_supported"]
      lookupPrereqTexts "rke2_service_active"
        `shouldBe` ["rke2_service_exists"]
      lookupPrereqTexts "k8s_cluster_reachable"
        `shouldBe` ["tool_kubectl", "kubeconfig_exists", "rke2_service_active"]
      lookupPrereqTexts "pulumi_logged_in"
        `shouldBe` ["tool_pulumi", "k8s_cluster_reachable"]
      lookupPrereqTexts "k8s_ready"
        `shouldBe` ["k8s_cluster_reachable", "rke2_service_active"]
      -- Sprint 5.6: infra_ready keeps the cluster + AWS-credential bundle...
      lookupPrereqTexts "infra_ready"
        `shouldBe` ["k8s_ready", "aws_credentials_valid"]
      -- ...while the new public_edge_ready node depends ONLY on cluster +
      -- chart-platform readiness, NOT on AWS credentials.
      lookupPrereqTexts "public_edge_ready"
        `shouldBe` ["k8s_ready"]
      lookupPrereqTexts "gateway_daemon_acquire"
        `shouldBe` ["platform_linux"]

    it "uses the expected validation and no-op effect shapes" $ do
      lookupPrerequisiteEffect "platform_linux" `shouldBe` Validate RequireLinux
      lookupPrerequisiteEffect "host_substrate_supported"
        `shouldBe` Validate RequireHostSubstrateSupported
      lookupPrerequisiteEffect "systemd_available" `shouldBe` Validate RequireSystemd
      lookupPrerequisiteEffect "supported_ubuntu_2404" `shouldBe` Validate RequireUbuntu2404
      lookupPrerequisiteEffect "machine_identity" `shouldBe` Validate RequireMachineIdentity
      lookupPrerequisiteEffect "tool_curl" `shouldBe` Validate (RequireTool "curl" ["--version"])
      lookupPrerequisiteEffect "tool_dig" `shouldBe` Validate (RequireTool "dig" ["-v"])
      lookupPrerequisiteEffect "tool_kubectl"
        `shouldBe` Validate (RequireTool "kubectl" ["version", "--client=true"])
      lookupPrerequisiteEffect "tool_ctr" `shouldBe` Validate (RequireTool "ctr" ["--help"])
      lookupPrerequisiteEffect "tool_rke2"
        `shouldBe` Validate (RequireTool "/usr/local/bin/rke2" ["--version"])
      lookupPrerequisiteEffect "settings_object" `shouldBe` Validate RequireSettings
      lookupPrerequisiteEffect "aws_iam_harness_ready" `shouldBe` Validate RequireAwsIamHarnessReady
      lookupPrerequisiteEffect "kubeconfig_exists"
        `shouldBe` Validate (RequireFileExists "/etc/rancher/rke2/rke2.yaml")
      lookupPrerequisiteEffect "kubeconfig_home_exists" `shouldBe` Validate RequireHomeKubeconfig
      lookupPrerequisiteEffect "rke2_config_exists"
        `shouldBe` Validate (RequireFileExists "/etc/rancher/rke2/config.yaml")
      lookupPrerequisiteEffect "aws_credentials_valid" `shouldBe` Validate RequireAwsCredentials
      lookupPrerequisiteEffect "route53_accessible" `shouldBe` Validate RequireRoute53Access
      lookupPrerequisiteEffect "route53_lifecycle_capable"
        `shouldBe` Validate RequireRoute53LifecycleCapability
      lookupPrerequisiteEffect "rke2_installed"
        `shouldBe` Validate (RequireFileExists "/usr/local/bin/rke2")
      lookupPrerequisiteEffect "rke2_service_exists"
        `shouldBe` Validate (RequireServiceExists "rke2-server.service")
      lookupPrerequisiteEffect "rke2_service_active"
        `shouldBe` Validate (RequireServiceActive "rke2-server.service")
      lookupPrerequisiteEffect "k8s_cluster_reachable" `shouldBe` Validate RequireKubectlClusterReachable
      lookupPrerequisiteEffect "pulumi_logged_in" `shouldBe` Validate RequirePulumiLogin
      lookupPrerequisiteEffect "k8s_ready" `shouldBe` Noop
      lookupPrerequisiteEffect "infra_ready" `shouldBe` Noop
      lookupPrerequisiteEffect "public_edge_ready" `shouldBe` Noop
      lookupPrerequisiteEffect "gateway_daemon_acquire" `shouldBe` Noop

    it "expands shared prerequisite chains transitively" $ do
      transitiveClosureTexts ["rke2_service_active"]
        `shouldBe` Right
          [ "host_substrate_supported"
          , "platform_linux"
          , "rke2_installed"
          , "rke2_service_active"
          , "rke2_service_exists"
          , "systemd_available"
          ]
      transitiveClosureTexts ["route53_accessible"]
        `shouldBe` Right
          [ "aws_credentials_valid"
          , "route53_accessible"
          , "settings_object"
          , "tool_aws"
          ]
      transitiveClosureTexts ["route53_lifecycle_capable"]
        `shouldBe` Right
          [ "aws_credentials_valid"
          , "route53_accessible"
          , "route53_lifecycle_capable"
          , "settings_object"
          , "tool_aws"
          ]
      transitiveClosureTexts ["pulumi_logged_in"]
        `shouldBe` Right
          [ "host_substrate_supported"
          , "k8s_cluster_reachable"
          , "kubeconfig_exists"
          , "platform_linux"
          , "pulumi_logged_in"
          , "rke2_installed"
          , "rke2_service_active"
          , "rke2_service_exists"
          , "systemd_available"
          , "tool_kubectl"
          , "tool_pulumi"
          ]
      transitiveClosureTexts ["infra_ready"]
        `shouldBe` Right
          [ "aws_credentials_valid"
          , "host_substrate_supported"
          , "infra_ready"
          , "k8s_cluster_reachable"
          , "k8s_ready"
          , "kubeconfig_exists"
          , "platform_linux"
          , "rke2_installed"
          , "rke2_service_active"
          , "rke2_service_exists"
          , "settings_object"
          , "systemd_available"
          , "tool_aws"
          , "tool_kubectl"
          ]
      -- Sprint 5.6: the public_edge_ready closure resolves cluster
      -- readiness WITHOUT pulling in any AWS-credential node.
      transitiveClosureTexts ["public_edge_ready"]
        `shouldBe` Right
          [ "host_substrate_supported"
          , "k8s_cluster_reachable"
          , "k8s_ready"
          , "kubeconfig_exists"
          , "platform_linux"
          , "public_edge_ready"
          , "rke2_installed"
          , "rke2_service_active"
          , "rke2_service_exists"
          , "systemd_available"
          , "tool_kubectl"
          ]

  describe "construction-time acyclicity (Sprint 1.31)" $ do
    -- Sprint 5.6: synthetic registries are built from real 'PrerequisiteId'
    -- constructors with deliberately rewired dependency edges (the
    -- production registry is acyclic, so cyclic shapes are produced by
    -- re-pointing edges, not by inventing string ids).
    it "rejects a back-edge at construction and names the offending nodes" $ do
      -- infra_ready -> k8s_ready -> infra_ready is a back-edge: constructing
      -- from infra_ready must fail, not loop or silently short-circuit on a
      -- visited set.
      let cyclicRegistry =
            Map.fromList
              [ (effectNodeId node, node)
              | node <-
                  [ cycleNode InfraReady [K8sReady]
                  , cycleNode K8sReady [InfraReady]
                  ]
              ]
      transitiveClosureIds [InfraReady] cyclicRegistry
        `shouldBe` Left "Prerequisite cycle detected: infra_ready -> k8s_ready -> infra_ready"
      fromRootIds [InfraReady] cyclicRegistry
        `shouldBe` Left "Prerequisite cycle detected: infra_ready -> k8s_ready -> infra_ready"

    it "rejects a direct self-edge at construction" $ do
      let selfRegistry =
            Map.fromList [(MachineIdentity, cycleNode MachineIdentity [MachineIdentity])]
      transitiveClosureIds [MachineIdentity] selfRegistry
        `shouldBe` Left "Prerequisite cycle detected: machine_identity -> machine_identity"

    it "still constructs a diamond (shared dependency, no cycle) cleanly" $ do
      -- top depends on left and right; both depend on base. A shared dependency is a DAG, not a
      -- cycle, and must construct without a false-positive cycle rejection.
      let diamondRegistry =
            Map.fromList
              [ (effectNodeId node, node)
              | node <-
                  [ cycleNode K8sReady [Rke2Installed, Rke2ServiceExists]
                  , cycleNode Rke2Installed [PlatformLinux]
                  , cycleNode Rke2ServiceExists [PlatformLinux]
                  , cycleNode PlatformLinux []
                  ]
              ]
      fmap (map prerequisiteIdText) (transitiveClosureIds [K8sReady] diamondRegistry)
        `shouldBe` Right
          [ "k8s_ready"
          , "platform_linux"
          , "rke2_installed"
          , "rke2_service_exists"
          ]

    it "still rejects missing node ids at construction" $ do
      -- infra_ready references k8s_ready, but the registry omits k8s_ready.
      let registryWithDangling =
            Map.fromList [(InfraReady, cycleNode InfraReady [K8sReady])]
      transitiveClosureIds [InfraReady] registryWithDangling
        `shouldBe` Left "Missing effect node in registry: k8s_ready"

  describe "collapsed settings node (Sprint 1.31)" $ do
    it "registers the surviving settings_object node" $ do
      Map.member SettingsObject prerequisiteRegistry `shouldBe` True

    it "resolves the closure that previously expanded both settings nodes through the survivor" $ do
      -- Every former dependent of `settings_loaded`/`settings_object` now reaches the single
      -- `settings_object` node; the closure still resolves and contains exactly one settings node.
      case transitiveClosureTexts ["aws_credentials_valid"] of
        Left err -> expectationFailure ("expected acyclic closure, got: " ++ err)
        Right closure -> do
          ("settings_object" `elem` closure) `shouldBe` True
          ("settings_loaded" `elem` closure) `shouldBe` False
      effectNodeEffect (lookupPrerequisiteNode "settings_object")
        `shouldBe` Validate RequireSettings

  describe "interpreter satisfied-node memo (Sprint 1.31)" $ do
    it "evaluates a satisfied prerequisite once per run even across distinct nodes" $
      withSystemTempDirectory "prodbox-prereq-memo" $ \tmpDir -> do
        -- Two distinct nodes carry the SAME effect (an identical counting command). The memo
        -- must let the probe run at most once per interpreter run: the counter file lands at 1,
        -- not 2.
        let counterPath = tmpDir </> "memo-count"
            counterScriptPath = tmpDir </> "increment.sh"
            countingCommand =
              RunCommand
                ( Subprocess
                    "/bin/sh"
                    [counterScriptPath, counterPath]
                    Nothing
                    (Just tmpDir)
                )
            memoRegistry =
              Map.fromList
                [ (effectNodeId node, node)
                | node <-
                    [ effectNode MachineIdentity [] countingCommand
                    , effectNode Rke2Installed [MachineIdentity] countingCommand
                    ]
                ]
        writeFile
          counterScriptPath
          ( unlines
              [ "#!/bin/sh"
              , "count_file=\"$1\""
              , "if [ -f \"$count_file\" ]; then"
              , "  count=$(cat \"$count_file\")"
              , "else"
              , "  count=0"
              , "fi"
              , "count=$((count + 1))"
              , "printf '%s' \"$count\" > \"$count_file\""
              ]
          )
        makeExecutable counterScriptPath
        case fromRootIds [Rke2Installed] memoRegistry of
          Left err -> expectationFailure ("expected acyclic memo DAG, got: " ++ err)
          Right dag -> do
            result <- runEffectDAG (InterpreterContext tmpDir) dag
            result `shouldBe` Result.Success ()
            readFile counterPath `shouldReturn` "1"

  describe "shared runtime helpers" $ do
    it "round-trips the rendered repo-root Dhall config through loadConfigFile" $
      withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        copyFile
          (repoRoot </> "prodbox-config-types.dhall")
          (tmpDir </> "prodbox-config-types.dhall")
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 (renderConfigDhall roundTripConfigFile))

        loadConfigFileAtPath (tmpDir </> "prodbox.dhall") `shouldReturn` Right roundTripConfigFile

    -- Sprint 2.20: the JSON `parseDaemonConfig` round-trip tests are
    -- superseded by the Dhall `decodeDaemonConfigDhall` coverage in the
    -- `Sprint 2.20 daemon Dhall settings` describe block above. The legacy
    -- JSON parser is removed from `Prodbox.Gateway.Types` as Phase 2 closure.

    it "round-trips persisted gateway orders through CBOR" $ do
      decodeOrdersCbor (encodeOrdersCbor sampleOrders)
        `shouldBe` Right sampleOrders

    -- Sprint 4.18: the on-disk snapshot cache is removed; the destroy,
    -- residue-assertion, and substrate-platform install paths now read
    -- the stack snapshot live from the Pulumi backend. These round-trips
    -- exercise the live-output parsers against the flat `Map Text Text`
    -- shape the backend emits (complex outputs as JSON-encoded strings).
    it "round-trips the aws-test snapshot through the live-output parser" $
      AwsTest.parseAwsTestStackFromOutputs sampleAwsTestStackOutputsMap
        `shouldBe` Right sampleAwsTestStackSnapshot

    it "round-trips the aws-eks-test snapshot through the live-output parser" $
      AwsEks.parseAwsEksTestStackFromOutputs sampleAwsEksTestStackOutputsMap
        `shouldBe` Right sampleAwsEksTestStackSnapshot

    it "sanitizes resource names into DNS-1123 labels" $ do
      sanitizeResourceName "Hello, World_123"
        `shouldBe` "hello-world-123"

    it "bounds resource names to 63 characters without losing determinism" $ do
      let longName =
            boundedResourceName
              "prodbox"
              "this-is-a-very-long-component-name-that-needs-truncation"
              "primary"
      Text.length longName `shouldSatisfy` (<= 63)
      Text.unpack longName
        `shouldContain` Text.unpack
          (hashSuffix "prodbox-this-is-a-very-long-component-name-that-needs-truncation-primary")

    it "keeps distinct long resource names collision-resistant" $ do
      let firstName =
            boundedResourceName
              "prodbox"
              "this-is-a-very-long-component-name-that-needs-truncation"
              "primary"
          secondName =
            boundedResourceName
              "prodbox"
              "this-is-a-very-long-component-name-that-needs-truncation"
              "replica"
      firstName `shouldNotBe` secondName

    it "centralizes Patroni service and claim naming helpers" $ do
      patroniPrimaryServiceName "keycloak" `shouldBe` "prodbox-keycloak-pg-ha"
      patroniReplicaServiceName "keycloak" `shouldBe` "prodbox-keycloak-pg-replicas"
      patroniPersistentVolumeClaimName "keycloak" 2
        `shouldBe` "prodbox-keycloak-pg-instance1-2-pgdata"

    it "derives Patroni storage specs from the shared helper surface" $ do
      map chartStorageSpecPersistentVolumeClaimName (patroniStorageSpecs "keycloak")
        `shouldBe` [ "prodbox-keycloak-pg-instance1-0-pgdata"
                   , "prodbox-keycloak-pg-instance1-1-pgdata"
                   , "prodbox-keycloak-pg-instance1-2-pgdata"
                   ]

    it "computes exponential retry delays from a first-class policy" $ do
      let policy =
            RetryPolicy
              { retryPolicyMaxAttempts = 5
              , retryPolicyBaseDelayMicros = 100
              , retryPolicyMultiplier = 2
              , retryPolicyMaxDelayMicros = 1000
              }
      map (retryDelayMicros policy) [0, 1, 2, 3, 4]
        `shouldBe` [100, 200, 400, 800, 1000]

    it "retries retryable service actions through the shared service helper" $ do
      attemptsRef <- newIORef (0 :: Int)
      let policy =
            RetryPolicy
              { retryPolicyMaxAttempts = 3
              , retryPolicyBaseDelayMicros = 0
              , retryPolicyMultiplier = 1
              , retryPolicyMaxDelayMicros = 0
              }
      result <-
        retryServiceAction policy $ do
          modifyIORef' attemptsRef (+ 1)
          attempts <- readIORef attemptsRef
          pure $
            if attempts < 3
              then Left (RedisError (SEConnectionFailed "transient"))
              else Right ("ready" :: String)
      attempts <- readIORef attemptsRef
      result `shouldBe` Right "ready"
      attempts `shouldBe` 3

    it "short-circuits a non-retryable classified service error" $ do
      attemptsRef <- newIORef (0 :: Int)
      let policy =
            RetryPolicy
              { retryPolicyMaxAttempts = 5
              , retryPolicyBaseDelayMicros = 0
              , retryPolicyMultiplier = 1
              , retryPolicyMaxDelayMicros = 0
              }
      result <-
        retryServiceAction policy $ do
          modifyIORef' attemptsRef (+ 1)
          pure (Left (RedisError (SEPermissionDenied "denied")) :: Either RedisError String)
      attempts <- readIORef attemptsRef
      result `shouldBe` Left (RedisError (SEPermissionDenied "denied"))
      attempts `shouldBe` 1

    it "derives ServiceError retryability from the classified constructor" $ do
      map
        serviceErrorRetryable
        [ SEConnectionFailed "x"
        , SETimeout "x"
        , SEConflict "x"
        , SEInternalError "x"
        , SENotFound "x"
        , SEPermissionDenied "x"
        ]
        `shouldBe` [True, True, True, True, False, False]

    it "classifies subprocess spawn failures into retryable vs non-retryable constructors" $ do
      let classify = classifyServiceError . fatalError . Text.pack
      classify "aws: does not exist (No such file or directory)"
        `shouldBe` SENotFound "aws: does not exist (No such file or directory)"
      serviceErrorRetryable (classify "permission denied") `shouldBe` False
      serviceErrorRetryable (classify "kubectl: connection refused") `shouldBe` True
      serviceErrorRetryable (classify "operation timed out") `shouldBe` True
      serviceErrorRetryable (classify "something unexpected went wrong") `shouldBe` True
      serviceErrorMessage (classify "boom") `shouldBe` "boom"

    it "shares name-resolution, connection, HTTP, and timeout retry classes" $ do
      map
        (isRetryableTransientFailure [])
        [ "no such host"
        , "dial tcp 10.0.0.1:443"
        , "lookup minio.prodbox.svc.cluster.local"
        , "name resolution"
        , "connection refused"
        , "connection reset by peer"
        , "upstream returned 503 SERVICE UNAVAILABLE"
        , "context deadline exceeded"
        ]
        `shouldBe` replicate 8 True
      isRetryableTransientFailure [] "401 unauthorized" `shouldBe` False

    it "extends the shared transient classifier with operation-specific fragments" $ do
      isRetryableTransientFailure ["expiredtoken"] "ExpiredToken: retry later" `shouldBe` True
      isRetryableTransientFailure ["failed to fetch"] "failed to fetch chart index" `shouldBe` True

    it "routes Helm DNS and transport failures through the shared retry base" $ do
      let failed detail = ProcessOutput (ExitFailure 1) "" detail
      map
        (isRetryableHelmFailure . failed)
        [ "no such host"
        , "dial tcp 10.0.0.1:443"
        , "lookup charts.example.test"
        , "connection refused"
        , "temporary failure in name resolution"
        , "failed to fetch chart index"
        , "failed to download chart archive"
        ]
        `shouldBe` replicate 7 True
      isRetryableHelmFailure (failed "401 unauthorized") `shouldBe` False

    it "retains Route 53 credential-specific retry extensions" $ do
      let failed detail = ProcessOutput (ExitFailure 1) "" detail
      map
        (isRetryableRoute53CredentialFailure . failed)
        [ "InvalidClientTokenId"
        , "The security token included in the request is invalid"
        , "UnrecognizedClientException"
        , "AccessDenied"
        , "not authorized to perform: route53:ChangeResourceRecordSets"
        , "lookup route53.amazonaws.com: no such host"
        ]
        `shouldBe` replicate 6 True
      isRetryableRoute53CredentialFailure (failed "validation error: malformed zone id")
        `shouldBe` False

    it "needs no retry-classifier lint allowance" $ do
      let inlineClassifier classifierName =
            unlines
              [ classifierName ++ " detail ="
              , "  any (`isInfixOf` detail) [\"connection refused\"]"
              ]
      forM_
        [ "isRetryableRoute53CredentialFailure"
        , "isRetryableHelmFailure"
        , "isRetryableHarborPublicationFailure"
        ]
        ( \classifierName ->
            inlineRetrySubstringListViolations
              "src/Prodbox/CLI/Rke2.hs"
              (inlineClassifier classifierName)
              `shouldNotBe` []
        )
      inlineRetrySubstringListViolations
        "src/Prodbox/Lib/EksImageMirror.hs"
        (inlineClassifier "isRetryableEksImageMirrorFailure")
        `shouldNotBe` []

    it "flags new inline retry-substring classifiers but permits shared-base delegation" $ do
      inlineRetrySubstringListViolations
        "src/Prodbox/Synthetic.hs"
        ( unlines
            [ "isRetryableSyntheticFailure :: String -> Bool"
            , "isRetryableSyntheticFailure detail ="
            , "  any (`isInfixOf` detail)"
            , "    [ \"connection refused\""
            , "    , \"no such host\""
            , "    ]"
            ]
        )
        `shouldNotBe` []
      inlineRetrySubstringListViolations
        "src/Prodbox/Synthetic.hs"
        ( unlines
            [ "retryableSyntheticFragments = [\"connection refused\"]"
            , "isRetryableSyntheticFailure detail ="
            , "  any (`isInfixOf` detail) retryableSyntheticFragments"
            ]
        )
        `shouldNotBe` []
      inlineRetrySubstringListViolations
        "src/Prodbox/Synthetic.hs"
        ( unlines
            [ "isRetryableSyntheticFailure detail ="
            , "  isRetryableTransientFailure [] detail"
            , "    || \"synthetic busy\" `isInfixOf` detail"
            ]
        )
        `shouldNotBe` []
      inlineRetrySubstringListViolations
        "src/Prodbox/CLI/Rke2.hs"
        "isRetryableNewRke2Failure detail = \"busy\" `isInfixOf` detail"
        `shouldNotBe` []
      inlineRetrySubstringListViolations
        "src/Prodbox/Synthetic.hs"
        ( unlines
            [ "isRetryableSyntheticFailure :: String -> Bool"
            , "isRetryableSyntheticFailure ="
            , "  isRetryableTransientFailure [\"synthetic busy\"]"
            ]
        )
        `shouldBe` []
      inlineRetrySubstringListViolations
        "src/Prodbox/Synthetic.hs"
        ( unlines
            [ "isRetryableSyntheticFailure detail ="
            , "  {- `isInfixOf` is forbidden in this classifier. -}"
            , "  isRetryableTransientFailure [\"synthetic busy\"] detail"
            ]
        )
        `shouldBe` []
      inlineRetrySubstringListViolations
        "src/Prodbox/Synthetic.hs"
        ( unlines
            [ "isRetryableSyntheticFailure detail ="
            , "  -- `isInfixOf` must not be implemented here."
            , "  isRetryableTransientFailure [\"synthetic busy\"] detail"
            ]
        )
        `shouldBe` []

    it "polls a readiness predicate until ready without treating pending as failure" $ do
      observationsRef <- newIORef (0 :: Int)
      let policy =
            RetryPolicy
              { retryPolicyMaxAttempts = 5
              , retryPolicyBaseDelayMicros = 0
              , retryPolicyMultiplier = 1
              , retryPolicyMaxDelayMicros = 0
              }
      result <-
        pollUntilReady policy $ do
          modifyIORef' observationsRef (+ 1)
          observations <- readIORef observationsRef
          pure $
            if observations < 3
              then PollPending (Text.pack ("pending after " ++ show observations))
              else PollReady ("ready" :: String)
      observations <- readIORef observationsRef
      result `shouldBe` Right "ready"
      observations `shouldBe` 3

    it "surfaces the last pending detail when the readiness poll times out" $ do
      let policy =
            RetryPolicy
              { retryPolicyMaxAttempts = 2
              , retryPolicyBaseDelayMicros = 0
              , retryPolicyMultiplier = 1
              , retryPolicyMaxDelayMicros = 0
              }
      result <-
        pollUntilReady policy (pure (PollPending "still converging" :: PollOutcome ()))
      result `shouldBe` Left "still converging"

    it "stops the readiness poll immediately on a hard observation failure" $ do
      observationsRef <- newIORef (0 :: Int)
      let policy =
            RetryPolicy
              { retryPolicyMaxAttempts = 5
              , retryPolicyBaseDelayMicros = 0
              , retryPolicyMultiplier = 1
              , retryPolicyMaxDelayMicros = 0
              }
      result <-
        pollUntilReady policy $ do
          modifyIORef' observationsRef (+ 1)
          pure (PollFailed "cannot observe" :: PollOutcome ())
      observations <- readIORef observationsRef
      result `shouldBe` Left "cannot observe"
      observations `shouldBe` 1

    it "flags hand-built ServiceError retryable literals in the doctrine lint" $ do
      serviceErrorRetryableLiteralViolations
        "src/Prodbox/Synthetic.hs"
        "x = ServiceError { serviceErrorMessage = m, serviceErrorRetryable = True }"
        `shouldNotBe` []
      serviceErrorRetryableLiteralViolations
        "src/Prodbox/Synthetic.hs"
        "y = PgError (ServiceError \"boom\" False)"
        `shouldNotBe` []
      serviceErrorRetryableLiteralViolations
        "src/Prodbox/Synthetic.hs"
        "z = classifyServiceError appError"
        `shouldBe` []

    it "filters daemon log severities through the configured log level" $ do
      severityFromLogLevel "debug" `shouldBe` Debug
      severityFromLogLevel "INFO" `shouldBe` Info
      severityFromLogLevel "warning" `shouldBe` Warn
      severityFromLogLevel "error" `shouldBe` Error
      shouldLogSeverity Warn Info `shouldBe` False
      shouldLogSeverity Warn Warn `shouldBe` True
      shouldLogSeverity Warn Error `shouldBe` True

    it "threads one-shot command context through the App environment" $ do
      env <- runApp (Env "/tmp/prodbox") askEnv
      envRepoRoot env `shouldBe` "/tmp/prodbox"

    it "renders typed one-shot output options for plain and JSON output" $ do
      renderOutput defaultOutputOptions "ok" (object ["status" .= ("ok" :: String)])
        `shouldBe` "ok"
      renderOutput
        (OutputOptions OutputJson ColorNever)
        "ok"
        (object ["status" .= ("ok" :: String)])
        `shouldBe` "{\"status\":\"ok\"}"

    it "records, fetches, and marks daemon events by processed_at state" $ do
      store <-
        DaemonEvents.newEventStore
          [ storedDaemonEvent "event-a" 20 Nothing
          , storedDaemonEvent "event-processed" 5 (Just (testUtc 30))
          ]
      DaemonEvents.recordEvent store (storedDaemonEvent "event-b" 10 Nothing)
      DaemonEvents.recordEvent store (storedDaemonEvent "event-b" 10 Nothing)

      initialEvents <- DaemonEvents.fetchUnprocessedEvents store
      map DaemonEvents.eventId initialEvents
        `shouldBe` [DaemonEvents.EventId "event-b", DaemonEvents.EventId "event-a"]

      DaemonEvents.markEventProcessed store (DaemonEvents.EventId "event-b") (testUtc 40)
      remainingEvents <- DaemonEvents.fetchUnprocessedEvents store
      map DaemonEvents.eventId remainingEvents
        `shouldBe` [DaemonEvents.EventId "event-a"]

    it "round-trips durable daemon events through CBOR" $ do
      let event = storedDaemonEvent "event-cbor" 15 Nothing
      DaemonEvents.decodeStoredEventCbor (DaemonEvents.encodeStoredEventCbor event)
        `shouldBe` Right event

    it "markEventProcessed is first-write-wins under the IS-NULL guard" $ do
      store <-
        DaemonEvents.newEventStore
          [storedDaemonEvent "event-x" 10 Nothing]
      -- First processing stamps processed_at.
      DaemonEvents.markEventProcessed store (DaemonEvents.EventId "event-x") (testUtc 100)
      -- A later redelivery of the same event must be a no-op: the IS-NULL guard
      -- finds processed_at already set and leaves the original timestamp.
      DaemonEvents.markEventProcessed store (DaemonEvents.EventId "event-x") (testUtc 999)
      -- The event is no longer unprocessed, and its stamp is the first writer's.
      DaemonEvents.fetchUnprocessedEvents store
        `shouldReturn` []
      processedStamp <- DaemonEvents.lookupProcessedAt store (DaemonEvents.EventId "event-x")
      processedStamp `shouldBe` Just (Just (testUtc 100))

    it "processes unprocessed daemon events once across repeated runs" $ do
      handledRef <- newIORef []
      store <-
        DaemonEvents.newEventStore
          [ storedDaemonEvent "event-a" 20 Nothing
          , storedDaemonEvent "event-b" 10 Nothing
          ]
      let handler =
            DaemonEvents.EventHandler $ \event ->
              modifyIORef' handledRef (DaemonEvents.eventId event :)

      firstCount <- DaemonEvents.processEvents store (pure (testUtc 50)) handler
      secondCount <- DaemonEvents.processEvents store (pure (testUtc 60)) handler
      handled <- readIORef handledRef

      firstCount `shouldBe` 2
      secondCount `shouldBe` 0
      reverse handled
        `shouldBe` [DaemonEvents.EventId "event-b", DaemonEvents.EventId "event-a"]

    it "renders AppError values through the shared CLI output boundary" $ do
      let fatalAppError = fatalError "fatal message"
          recoverableAppError = recoverableError "recoverable message"
      renderError fatalAppError `shouldBe` "fatal message"
      errorKind recoverableAppError `shouldBe` Recoverable
      case errorCause fatalAppError of
        Nothing -> pure ()
        Just _ -> expectationFailure "expected fatalError to omit an exception cause"

    it "renders subprocesses through the shared typed-value boundary" $ do
      let subprocess =
            Subprocess "kubectl" ["get", "pods", "-A"] Nothing (Just "/tmp/prodbox")
      renderSubprocess subprocess `shouldBe` "kubectl get pods -A"

  describe "Pulsar CBOR topic and envelope boundary" $ do
    it "derives Pulsar topic names from validated segments only" $ do
      case (PulsarTopic.mkTenant "prodbox", PulsarTopic.mkNamespace "gateway", PulsarTopic.mkLane "home") of
        (Right tenant, Right namespace, Right lane) ->
          PulsarTopic.renderTopicName
            (PulsarTopic.topicFor tenant namespace PulsarTopic.Reconcile PulsarTopic.Command lane)
            `shouldBe` "persistent://prodbox/gateway/reconcile.command.home"
        _ -> expectationFailure "expected valid Pulsar topic segments"

      PulsarTopic.mkLane "home/local"
        `shouldBe` Left (PulsarTopic.InvalidTopicSegment "lane" "home/local")

    it "round-trips Work envelopes through the CBOR-only Pulsar codec" $ do
      case PulsarTopic.mkLane "home" of
        Left err -> expectationFailure (PulsarTopic.renderTopicError err)
        Right lane -> do
          let payload = Cbor.cborPayloadFromJsonValue (object ["revision" .= (3 :: Int)])
              command =
                PulsarEnvelope.WorkCommand
                  { PulsarEnvelope.wcCallId = PulsarEnvelope.CallId "call-3"
                  , PulsarEnvelope.wcWorkflow = PulsarTopic.Gossip
                  , PulsarEnvelope.wcLane = lane
                  , PulsarEnvelope.wcPayload = payload
                  }
              event =
                PulsarEnvelope.WorkEvent
                  { PulsarEnvelope.weCallId = PulsarEnvelope.CallId "call-3"
                  , PulsarEnvelope.wePayload = PulsarEnvelope.encodeWorkCommand command
                  }
              result =
                PulsarEnvelope.WorkResult
                  { PulsarEnvelope.wrCallId = PulsarEnvelope.CallId "call-3"
                  , PulsarEnvelope.wrStatus = PulsarEnvelope.WorkSucceeded
                  , PulsarEnvelope.wrPayload = payload
                  }

          PulsarEnvelope.decodeWorkCommand (PulsarEnvelope.encodeWorkCommand command)
            `shouldBe` Right command
          PulsarEnvelope.decodeWorkEvent (PulsarEnvelope.encodeWorkEvent event)
            `shouldBe` Right event
          PulsarEnvelope.decodeWorkResult (PulsarEnvelope.encodeWorkResult result)
            `shouldBe` Right result
          PulsarCodec.decodePayload (PulsarCodec.encodePayload event)
            `shouldBe` Right event
          Cbor.cborPayloadBytes (PulsarEnvelope.encodeWorkCommand command)
            `shouldSatisfy` (not . BS.null)

    it "validates client endpoints before opening a broker socket" $ do
      emptyHost <-
        PulsarClient.connect
          PulsarClient.PulsarClientConfig
            { PulsarClient.pulsarClientHost = ""
            , PulsarClient.pulsarClientPort = 6650
            , PulsarClient.pulsarClientName = "unit-test"
            , PulsarClient.pulsarClientLookupStrategy = PulsarClient.FollowBrokerLookupUrl
            }
      case emptyHost of
        Left (PulsarClient.PulsarInvalidEndpoint message) ->
          message `shouldContain` "host"
        Left err -> expectationFailure (PulsarClient.renderPulsarClientError err)
        Right _ -> expectationFailure "expected endpoint validation to fail"

      badPort <-
        PulsarClient.connect
          PulsarClient.PulsarClientConfig
            { PulsarClient.pulsarClientHost = "pulsar.gateway.svc.cluster.local"
            , PulsarClient.pulsarClientPort = 0
            , PulsarClient.pulsarClientName = "unit-test"
            , PulsarClient.pulsarClientLookupStrategy = PulsarClient.FollowBrokerLookupUrl
            }
      case badPort of
        Left (PulsarClient.PulsarInvalidEndpoint message) ->
          message `shouldContain` "port"
        Left err -> expectationFailure (PulsarClient.renderPulsarClientError err)
        Right _ -> expectationFailure "expected endpoint validation to fail"

    it "owns Pulsar native payload framing with metadata and CRC32C validation" $ do
      let payload = Cbor.cborPayloadFromJsonValue (object ["kind" .= ("command" :: Text.Text)])
          metadata =
            PulsarProtocol.MessageMetadata
              { PulsarProtocol.messageMetadataProducerName = "unit-producer"
              , PulsarProtocol.messageMetadataSequenceId = 17
              , PulsarProtocol.messageMetadataPublishTimeMillis = 123456
              }
          frame =
            PulsarProtocol.buildPayloadFrame
              (PulsarProtocol.buildSendCommand 4 17)
              (PulsarProtocol.encodeMessageMetadata metadata)
              payload
          parsed = PulsarProtocol.parseFrameBody (BS.drop 4 frame)
      case parsed of
        Left err -> expectationFailure err
        Right brokerFrame -> do
          PulsarProtocol.brokerFrameCommand brokerFrame
            `shouldBe` PulsarProtocol.BrokerUnsupported 6
          PulsarProtocol.brokerFrameMetadata brokerFrame `shouldBe` Just metadata
          PulsarProtocol.brokerFramePayload brokerFrame `shouldBe` Just payload

      let corrupted = BS.take (BS.length frame - 1) frame <> BS.singleton 0
      PulsarProtocol.parseFrameBody (BS.drop 4 corrupted)
        `shouldBe` Left "Pulsar payload frame CRC32C checksum mismatch."

    it "renders and parses Pulsar broker message identifiers" $ do
      let messageId =
            PulsarProtocol.MessageIdData
              { PulsarProtocol.messageIdLedgerId = 123
              , PulsarProtocol.messageIdEntryId = 456
              , PulsarProtocol.messageIdPartition = Just 0
              , PulsarProtocol.messageIdBatchIndex = Just 2
              }
          rendered = PulsarProtocol.encodeMessageIdText messageId
      rendered `shouldBe` "123:456:0:2"
      PulsarProtocol.decodeMessageIdText rendered `shouldBe` Right messageId
      PulsarProtocol.decodeMessageIdText "123:456:-1"
        `shouldBe` Right
          messageId
            { PulsarProtocol.messageIdPartition = Just (-1)
            , PulsarProtocol.messageIdBatchIndex = Nothing
            }
      PulsarProtocol.decodeMessageIdText "123:abc"
        `shouldBe` Left "Pulsar message id segment is not numeric: abc"

    it "models Pulsar topic discovery as present / absent / unobservable residue" $ do
      case (PulsarTopic.mkTenant "prodbox", PulsarTopic.mkNamespace "gateway", PulsarTopic.mkLane "home") of
        (Right tenant, Right namespace, Right lane) -> do
          let topic =
                PulsarTopic.topicFor tenant namespace PulsarTopic.Gossip PulsarTopic.Event lane
              managed =
                PulsarTopicResidue.ManagedTopic
                  { PulsarTopicResidue.managedTopicName = topic
                  , PulsarTopicResidue.managedTopicRetention =
                      PulsarTopicResidue.RetentionPolicy
                        { PulsarTopicResidue.retentionBacklogBytes = 1024
                        , PulsarTopicResidue.retentionOffloadBytes = 2048
                        }
                  , PulsarTopicResidue.managedTopicClass = ResourceClass.LongLived
                  }
              brokerWith discovery =
                PulsarTopicResidue.PulsarTopicBroker
                  { PulsarTopicResidue.pulsarTopicExists = \_ -> pure discovery
                  , PulsarTopicResidue.pulsarTopicEnsure = \_ -> pure (Right ())
                  , PulsarTopicResidue.pulsarTopicDelete = \_ -> pure (Right ())
                  }

          present <- PulsarTopicResidue.topicDiscover (brokerWith (Right True)) managed
          PulsarTopicResidue.topicResidueStatus present
            `shouldBe` Residue.ResiduePresent
              Residue.ResidueDetails
                { Residue.residueEvidence =
                    "pulsar-topic: persistent://prodbox/gateway/gossip.event.home"
                , Residue.residueStackName = "pulsar-topics-long-lived"
                }

          absent <- PulsarTopicResidue.topicDiscover (brokerWith (Right False)) managed
          PulsarTopicResidue.topicResidueStatus absent `shouldBe` Residue.ResidueAbsent

          unobservable <-
            PulsarTopicResidue.topicDiscover
              (brokerWith (Left (PulsarClient.PulsarBrokerUnreachable "connection refused")))
              managed
          PulsarTopicResidue.topicResidueStatus unobservable
            `shouldBe` Residue.ResidueUnreachable
              ( Residue.ResidueQueryFailed
                  "Pulsar topic broker unobservable: broker unreachable: connection refused"
              )
        _ -> expectationFailure "expected valid Pulsar topic"

    it "registers Pulsar topics as managed resources with typed idempotent destroy" $ do
      case (PulsarTopic.mkTenant "prodbox", PulsarTopic.mkNamespace "gateway", PulsarTopic.mkLane "home") of
        (Right tenant, Right namespace, Right lane) -> do
          deleted <- newIORef ([] :: [Text.Text])
          let topic =
                PulsarTopic.topicFor tenant namespace PulsarTopic.Reconcile PulsarTopic.Command lane
              managed =
                PulsarTopicResidue.ManagedTopic
                  { PulsarTopicResidue.managedTopicName = topic
                  , PulsarTopicResidue.managedTopicRetention =
                      PulsarTopicResidue.RetentionPolicy
                        { PulsarTopicResidue.retentionBacklogBytes = 4096
                        , PulsarTopicResidue.retentionOffloadBytes = 8192
                        }
                  , PulsarTopicResidue.managedTopicClass = ResourceClass.PerRun
                  }
              broker =
                PulsarTopicResidue.PulsarTopicBroker
                  { PulsarTopicResidue.pulsarTopicExists = \_ -> pure (Right True)
                  , PulsarTopicResidue.pulsarTopicEnsure = \_ -> pure (Right ())
                  , PulsarTopicResidue.pulsarTopicDelete = \name -> do
                      modifyIORef' deleted (++ [PulsarTopic.renderTopicName name])
                      pure (Right ())
                  }
              resource = ResourceRegistry.pulsarTopicManagedResource broker managed

          ResourceRegistry.resourceName resource `shouldBe` "pulsar-topics-per-run"
          ResourceRegistry.resourceClass resource `shouldBe` ResourceClass.PerRun
          ResourceRegistry.resourceDestroyCommand resource `shouldBe` "prodbox cluster delete --cascade"
          ResourceRegistry.resourceDestroy resource "/repo" `shouldReturn` ExitSuccess
          readIORef deleted
            `shouldReturn` ["persistent://prodbox/gateway/reconcile.command.home"]
        _ -> expectationFailure "expected valid Pulsar topic"

    it "ensures absent Pulsar topics through the typed broker adapter" $ do
      case (PulsarTopic.mkTenant "prodbox", PulsarTopic.mkNamespace "gateway", PulsarTopic.mkLane "home") of
        (Right tenant, Right namespace, Right lane) -> do
          ensured <- newIORef ([] :: [Text.Text])
          let topic =
                PulsarTopic.topicFor tenant namespace PulsarTopic.Reconcile PulsarTopic.Result lane
              managed =
                PulsarTopicResidue.ManagedTopic
                  { PulsarTopicResidue.managedTopicName = topic
                  , PulsarTopicResidue.managedTopicRetention =
                      PulsarTopicResidue.RetentionPolicy
                        { PulsarTopicResidue.retentionBacklogBytes = 128
                        , PulsarTopicResidue.retentionOffloadBytes = 256
                        }
                  , PulsarTopicResidue.managedTopicClass = ResourceClass.LongLived
                  }
              broker =
                PulsarTopicResidue.PulsarTopicBroker
                  { PulsarTopicResidue.pulsarTopicExists = \_ -> pure (Right False)
                  , PulsarTopicResidue.pulsarTopicEnsure = \name -> do
                      modifyIORef' ensured (++ [PulsarTopic.renderTopicName name])
                      pure (Right ())
                  , PulsarTopicResidue.pulsarTopicDelete = \_ -> pure (Right ())
                  }
          PulsarTopicResidue.ensureTopic broker managed `shouldReturn` Right ()
          readIORef ensured
            `shouldReturn` ["persistent://prodbox/gateway/reconcile.result.home"]
        _ -> expectationFailure "expected valid Pulsar topic"

  describe "native chart platform helpers" $ do
    it "extracts deleted MinIO export host paths from mountinfo" $ do
      parseDeletedMinioExportHostPath
        "14443 14435 8:2 /home/matthewnowak/prodbox/.data/prodbox/minio/0//deleted /export rw,relatime - ext4 /dev/sda2 rw\n"
        `shouldBe` Just "/home/matthewnowak/prodbox/.data/prodbox/minio/0"

      parseDeletedMinioExportHostPath
        "14443 14435 8:2 /home/matthewnowak/prodbox/.data/prodbox/minio/0 /export rw,relatime - ext4 /dev/sda2 rw\n"
        `shouldBe` Nothing

    it "derives deterministic storage bindings" $ do
      let spec =
            ChartStorageSpec
              { chartStorageSpecStatefulSetName = "vscode"
              , chartStorageSpecPersistentVolumeClaimName =
                  retainedStatefulSetPersistentVolumeClaimName "vscode" 0
              , chartStorageSpecStorageSize = "20Gi"
              , chartStorageSpecOrdinal = 0
              , chartStorageSpecClaimSuffix = "data"
              }
          binding = storageBinding "/tmp/prodbox/.data" "vscode" "vscode-release" spec
      chartStorageBindingPersistentVolumeName binding
        `shouldBe` retainedStatefulSetPersistentVolumeName "vscode" "vscode" 0
      chartStorageBindingPersistentVolumeName binding
        `shouldBe` "prodbox-retained-vscode-vscode-0"
      chartStorageBindingPersistentVolumeClaimName binding
        `shouldBe` "data-vscode-0"
      chartStorageBindingHostPath binding
        `shouldBe` "/tmp/prodbox/.data/vscode/vscode/0"

    it "lists supported charts in canonical order" $ do
      supportedChartNames `shouldBe` ["keycloak", "vscode", "api", "websocket", "gateway"]

    it "renders the Pulsar workload chart as a retained gateway dependency" $ do
      result <-
        buildChartDeploymentPlanForSubstrate
          SubstrateAws
          "/tmp/prodbox"
          (testValidatedSettings "/tmp/prodbox/.data")
          "gateway"
          testChartSecrets
          Map.empty
      case result of
        Left err -> expectationFailure err
        Right plan -> do
          map chartReleasePlanReleaseName (chartDeploymentPlanReleases plan)
            `shouldBe` ["pulsar", "gateway"]
          case filter ((== "pulsar") . chartReleasePlanReleaseName) (chartDeploymentPlanReleases plan) of
            [release] -> do
              chartReleasePlanChartDir release `shouldBe` "/tmp/prodbox/charts/pulsar"
              map chartStorageBindingPersistentVolumeClaimName (chartReleasePlanStorageBindings release)
                `shouldBe` ["data-pulsar-0"]
              case eitherDecode (BL8.pack (chartReleasePlanValuesJson release)) :: Either String Value of
                Right (Object payload) -> do
                  case KeyMap.lookup (Key.fromString "image") payload of
                    Just (Object imagePayload) -> do
                      KeyMap.lookup (Key.fromString "repository") imagePayload
                        `shouldBe` Just (String "127.0.0.1:30080/prodbox/pulsar-mirror")
                      KeyMap.lookup (Key.fromString "tag") imagePayload
                        `shouldBe` Just (String "4.0.2")
                    _ -> expectationFailure "expected pulsar image payload"
                  case KeyMap.lookup (Key.fromString "storage") payload of
                    Just (Object storagePayload) -> do
                      KeyMap.lookup (Key.fromString "className") storagePayload
                        `shouldBe` Just (String "manual")
                      KeyMap.lookup (Key.fromString "size") storagePayload
                        `shouldBe` Just (String "20Gi")
                    _ -> expectationFailure "expected pulsar storage payload"
                  case KeyMap.lookup (Key.fromString "pulsar") payload of
                    Just (Object pulsarPayload) ->
                      KeyMap.lookup (Key.fromString "memoryOptions") pulsarPayload
                        `shouldBe` Just (String "-Xms512m -Xmx1024m -XX:MaxDirectMemorySize=512m")
                    _ -> expectationFailure "expected pulsar runtime payload"
                  expectResourceEnvelope
                    payload
                    "pulsar"
                    ("250m", "1024Mi", "1024Mi")
                    ("500m", "2048Mi", "4096Mi")
                Right _ -> expectationFailure "expected pulsar values object"
                Left err -> expectationFailure err
            _ -> expectationFailure "expected one pulsar release"

    it "injects capacity-plan resources and namespace guardrails into chart values" $ do
      result <-
        buildChartDeploymentPlan
          "/tmp/prodbox"
          (testValidatedSettings "/tmp/prodbox/.data")
          "vscode"
          testChartSecrets
          Map.empty
      case result of
        Left err -> expectationFailure err
        Right plan -> do
          let releaseValues =
                Map.fromList
                  [ ( chartReleasePlanReleaseName release
                    , eitherDecode (BL8.pack (chartReleasePlanValuesJson release)) :: Either String Value
                    )
                  | release <- chartDeploymentPlanReleases plan
                  ]
          case Map.lookup "vscode" releaseValues of
            Just (Right (Object payload)) -> do
              expectResourceEnvelope
                payload
                "vscode"
                ("500m", "1024Mi", "1024Mi")
                ("600m", "1280Mi", "2048Mi")
              case KeyMap.lookup (Key.fromString "resourceGuardrails") payload of
                Just (Object guardrailsPayload) -> do
                  KeyMap.lookup (Key.fromString "enabled") guardrailsPayload
                    `shouldBe` Just (Bool True)
                  expectQuotaHard guardrailsPayload "limits.memory" "5216Mi"
                  expectQuotaHard guardrailsPayload "requests.storage" "112640Mi"
                  expectLimitRangeDefault guardrailsPayload "cpu" "600m"
                  expectLimitRangeDefaultRequest guardrailsPayload "memory" "1024Mi"
                _ -> expectationFailure "expected vscode resourceGuardrails payload"
            Just (Right _) -> expectationFailure "expected vscode values object"
            Just (Left err) -> expectationFailure err
            Nothing -> expectationFailure "expected vscode release"
          case Map.lookup "keycloak-postgres" releaseValues of
            Just (Right (Object payload)) -> do
              expectResourceEnvelope
                payload
                "postgres"
                ("250m", "512Mi", "1024Mi")
                ("350m", "768Mi", "2048Mi")
              expectResourceEnvelope
                payload
                "replicaCertCopy"
                ("10m", "16Mi", "32Mi")
                ("25m", "32Mi", "64Mi")
              case KeyMap.lookup (Key.fromString "resourceGuardrails") payload of
                Just (Object guardrailsPayload) ->
                  KeyMap.lookup (Key.fromString "enabled") guardrailsPayload
                    `shouldBe` Just (Bool False)
                _ -> expectationFailure "expected keycloak-postgres resourceGuardrails payload"
            Just (Right _) -> expectationFailure "expected keycloak-postgres values object"
            Just (Left err) -> expectationFailure err
            Nothing -> expectationFailure "expected keycloak-postgres release"

    it "refuses to render chart values when a required workload profile is missing" $ do
      let settings = testValidatedSettings "/tmp/prodbox/.data"
          config = validatedConfig settings
          capacitySection = capacity config
          plan = Capacity.resource_plan capacitySection
          badPlan =
            plan
              { Capacity.workload_profiles =
                  filter
                    ((/= Text.pack "vscode") . Capacity.profile_id)
                    (Capacity.workload_profiles plan)
              }
          badSettings =
            settings
              { validatedConfig =
                  config
                    { capacity =
                        capacitySection
                          { Capacity.resource_plan = badPlan
                          }
                    }
              }
      result <-
        buildChartDeploymentPlan
          "/tmp/prodbox"
          badSettings
          "vscode"
          testChartSecrets
          Map.empty
      result
        `shouldBe` Left "capacity.resource_plan is missing workload profile `vscode`"

    it "builds delete plans in reverse dependency order" $ do
      case buildChartDeletePlan "/tmp/prodbox" Nothing "vscode" of
        Left err -> expectationFailure err
        Right plan -> do
          chartDeploymentPlanRootChart plan `shouldBe` "vscode"
          chartDeploymentPlanNamespace plan `shouldBe` "vscode"
          map chartReleasePlanReleaseName (chartDeploymentPlanReleases plan)
            `shouldBe` ["vscode", "keycloak", "keycloak-postgres"]

    it "renders AWS gateway deployments with the AWS-substrate image tag" $ do
      result <-
        buildChartDeploymentPlanForSubstrate
          SubstrateAws
          "/tmp/prodbox"
          (testValidatedSettings "/tmp/prodbox/.data")
          "gateway"
          testChartSecrets
          Map.empty
      case result of
        Left err -> expectationFailure err
        Right plan ->
          case filter ((== "gateway") . chartReleasePlanReleaseName) (chartDeploymentPlanReleases plan) of
            [release] ->
              case eitherDecode (BL8.pack (chartReleasePlanValuesJson release)) :: Either String Value of
                Right (Object payload) -> do
                  case KeyMap.lookup (Key.fromString "image") payload of
                    Just (Object imagePayload) -> do
                      KeyMap.lookup (Key.fromString "repository") imagePayload
                        `shouldBe` Just (String "127.0.0.1:30080/prodbox/prodbox-runtime")
                      KeyMap.lookup (Key.fromString "tag") imagePayload
                        `shouldBe` Just (String "prodbox-aws-substrate")
                    _ -> expectationFailure "expected gateway image payload"
                  case KeyMap.lookup (Key.fromString "dnsWriteGate") payload of
                    Just (Object dnsPayload) -> do
                      KeyMap.lookup (Key.fromString "enabled") dnsPayload
                        `shouldBe` Just (Bool False)
                      KeyMap.lookup (Key.fromString "zoneId") dnsPayload
                        `shouldBe` Just (String "")
                      KeyMap.lookup (Key.fromString "fqdn") dnsPayload
                        `shouldBe` Just (String "")
                    _ -> expectationFailure "expected gateway dnsWriteGate payload"
                  case KeyMap.lookup (Key.fromString "vault") payload of
                    Just (Object vaultPayload) ->
                      KeyMap.lookup (Key.fromString "role") vaultPayload
                        `shouldBe` Just (String (vaultRoleIdText VaultRoleGatewayDaemon))
                    _ -> expectationFailure "expected gateway vault payload"
                Right _ -> expectationFailure "expected gateway values object"
                Left err -> expectationFailure err
            _ -> expectationFailure "expected one gateway release"

    it "renders distinct attested daemon Tier-0 identities for home and AWS gateways" $ do
      let homeClusterId = "prodbox-home-target"
          homeTier0 =
            defaultProjectConfig
              { context =
                  (context defaultProjectConfig)
                    { cluster_id = homeClusterId
                    }
              }
      withBinarySiblingTier0 (Text.unpack (renderProjectConfigDhall homeTier0)) $ do
        homeResult <-
          buildChartDeploymentPlanForSubstrate
            SubstrateHomeLocal
            "/tmp/prodbox"
            (testValidatedSettings "/tmp/prodbox/.data")
            "gateway"
            testChartSecrets
            Map.empty
        awsResult <-
          buildChartDeploymentPlanForSubstrate
            SubstrateAws
            "/tmp/prodbox"
            (testValidatedSettings "/tmp/prodbox/.data")
            "gateway"
            testChartSecrets
            Map.empty
        case (homeResult, awsResult) of
          (Right homePlan, Right awsPlan) ->
            case (gatewayTier0DhallFromPlan homePlan, gatewayTier0DhallFromPlan awsPlan) of
              (Right homeDhall, Right awsDhall) -> do
                homeDhall `shouldNotBe` awsDhall
                assertMountedGatewayTier0Identity homeDhall homeClusterId
                assertMountedGatewayTier0Identity
                  awsDhall
                  (Text.pack AwsEks.awsEksCanonicalClusterName)
              (Left err, _) -> expectationFailure err
              (_, Left err) -> expectationFailure err
          (Left err, _) -> expectationFailure err
          (_, Left err) -> expectationFailure err

    it "keeps the gateway values render free of a duplicated Vault-role literal" $ do
      repoRoot <- getCurrentDirectory
      chartPlatformSource <-
        readFile (repoRoot </> "src" </> "Prodbox" </> "Lib" </> "ChartPlatform.hs")
      chartPlatformSource `shouldNotContain` "\"prodbox-gateway-daemon\""

    it "renders AWS public-edge workload charts with the AWS-substrate image tag" $ do
      result <-
        buildChartDeploymentPlanForSubstrate
          SubstrateAws
          "/tmp/prodbox"
          (testValidatedSettings "/tmp/prodbox/.data")
          "api"
          testChartSecrets
          Map.empty
      case result of
        Left err -> expectationFailure err
        Right plan ->
          case filter ((== "api") . chartReleasePlanReleaseName) (chartDeploymentPlanReleases plan) of
            [release] ->
              case eitherDecode (BL8.pack (chartReleasePlanValuesJson release)) :: Either String Value of
                Right (Object payload) ->
                  case KeyMap.lookup (Key.fromString "image") payload of
                    Just (Object imagePayload) -> do
                      KeyMap.lookup (Key.fromString "repository") imagePayload
                        `shouldBe` Just (String "127.0.0.1:30080/prodbox/prodbox-runtime")
                      KeyMap.lookup (Key.fromString "tag") imagePayload
                        `shouldBe` Just (String "prodbox-aws-substrate")
                      case KeyMap.lookup (Key.fromString "jwt") payload of
                        Just (Object jwtPayload) -> do
                          KeyMap.lookup (Key.fromString "issuer") jwtPayload
                            `shouldBe` Just (String "https://aws.test.resolvefintech.com/auth/realms/prodbox")
                          KeyMap.lookup (Key.fromString "jwksUri") jwtPayload
                            `shouldBe` Just
                              ( String
                                  "http://keycloak.vscode.svc.cluster.local:8080/auth/realms/prodbox/protocol/openid-connect/certs"
                              )
                          case KeyMap.lookup (Key.fromString "jwksBackend") jwtPayload of
                            Just (Object backendPayload) -> do
                              KeyMap.lookup (Key.fromString "namespace") backendPayload
                                `shouldBe` Just (String "vscode")
                              KeyMap.lookup (Key.fromString "serviceName") backendPayload
                                `shouldBe` Just (String "keycloak")
                              KeyMap.lookup (Key.fromString "servicePort") backendPayload
                                `shouldBe` Just (Number 8080)
                              KeyMap.lookup (Key.fromString "referenceGrantName") backendPayload
                                `shouldBe` Just (String "api-keycloak-jwks")
                            _ -> expectationFailure "expected api jwt jwksBackend payload"
                        _ -> expectationFailure "expected api jwt payload"
                    _ -> expectationFailure "expected api image payload"
                Right _ -> expectationFailure "expected api values object"
                Left err -> expectationFailure err
            _ -> expectationFailure "expected one api release"

    it "renders AWS websocket plans with internal Keycloak JWKS backchannel values" $ do
      result <-
        buildChartDeploymentPlanForSubstrate
          SubstrateAws
          "/tmp/prodbox"
          (testValidatedSettings "/tmp/prodbox/.data")
          "websocket"
          testChartSecrets
          Map.empty
      case result of
        Left err -> expectationFailure err
        Right plan ->
          case filter ((== "websocket") . chartReleasePlanReleaseName) (chartDeploymentPlanReleases plan) of
            [release] ->
              case eitherDecode (BL8.pack (chartReleasePlanValuesJson release)) :: Either String Value of
                Right (Object payload) ->
                  case KeyMap.lookup (Key.fromString "jwt") payload of
                    Just (Object jwtPayload) -> do
                      KeyMap.lookup (Key.fromString "issuer") jwtPayload
                        `shouldBe` Just (String "https://aws.test.resolvefintech.com/auth/realms/prodbox")
                      KeyMap.lookup (Key.fromString "jwksUri") jwtPayload
                        `shouldBe` Just
                          ( String
                              "http://keycloak.vscode.svc.cluster.local:8080/auth/realms/prodbox/protocol/openid-connect/certs"
                          )
                      case KeyMap.lookup (Key.fromString "jwksBackend") jwtPayload of
                        Just (Object backendPayload) -> do
                          KeyMap.lookup (Key.fromString "namespace") backendPayload
                            `shouldBe` Just (String "vscode")
                          KeyMap.lookup (Key.fromString "serviceName") backendPayload
                            `shouldBe` Just (String "keycloak")
                          KeyMap.lookup (Key.fromString "servicePort") backendPayload
                            `shouldBe` Just (Number 8080)
                          KeyMap.lookup (Key.fromString "referenceGrantName") backendPayload
                            `shouldBe` Just (String "websocket-keycloak-jwks")
                        _ -> expectationFailure "expected websocket jwt jwksBackend payload"
                    _ -> expectationFailure "expected websocket jwt payload"
                Right _ -> expectationFailure "expected websocket values object"
                Left err -> expectationFailure err
            _ -> expectationFailure "expected one websocket release"

    it "renders AWS vscode plans with static manual Patroni storage" $ do
      result <-
        buildChartDeploymentPlanForSubstrate
          SubstrateAws
          "/tmp/prodbox"
          (testValidatedSettings "/tmp/prodbox/.data")
          "vscode"
          testChartSecrets
          Map.empty
      case result of
        Left err -> expectationFailure err
        Right plan -> do
          chartDeploymentPlanSubstrate plan `shouldBe` SubstrateAws
          case filter ((== "keycloak-postgres") . chartReleasePlanReleaseName) (chartDeploymentPlanReleases plan) of
            [release] ->
              case eitherDecode (BL8.pack (chartReleasePlanValuesJson release)) :: Either String Value of
                Right (Object payload) ->
                  case KeyMap.lookup (Key.fromString "storage") payload of
                    Just (Object storagePayload) ->
                      KeyMap.lookup (Key.fromString "className") storagePayload
                        `shouldBe` Just (String "manual")
                    _ -> expectationFailure "expected keycloak-postgres storage payload"
                Right _ -> expectationFailure "expected keycloak-postgres values object"
                Left err -> expectationFailure err
            _ -> expectationFailure "expected one keycloak-postgres release"

    it "renders AWS static EBS storage as Retain PVs with CSI volume handles" $ do
      let spec =
            ChartStorageSpec
              { chartStorageSpecStatefulSetName = "vscode"
              , chartStorageSpecPersistentVolumeClaimName =
                  retainedStatefulSetPersistentVolumeClaimName "vscode" 0
              , chartStorageSpecStorageSize = "50Gi"
              , chartStorageSpecOrdinal = 0
              , chartStorageSpecClaimSuffix = "data"
              }
          binding = storageBinding "/tmp/prodbox/.data" "vscode" "vscode" spec
          ebsBinding =
            StaticEbsVolumeBinding
              { staticEbsVolumeBindingPersistentVolumeName =
                  chartStorageBindingPersistentVolumeName binding
              , staticEbsVolumeBindingVolumeHandle = "vol-0123"
              , staticEbsVolumeBindingAvailabilityZone = "us-east-1a"
              }
          manifestJsonResult =
            BL8.unpack . encode <$> chartEbsStorageManifest "vscode" "vscode" [binding] [ebsBinding]
      case manifestJsonResult of
        Left err -> expectationFailure err
        Right manifestJson -> do
          manifestJson `shouldContain` "\"kind\":\"PersistentVolumeClaim\""
          manifestJson `shouldContain` "\"kind\":\"PersistentVolume\""
          manifestJson `shouldContain` "\"storageClassName\":\"manual\""
          manifestJson `shouldContain` "\"name\":\"data-vscode-0\""
          manifestJson `shouldContain` "\"persistentVolumeReclaimPolicy\":\"Retain\""
          manifestJson `shouldContain` "\"driver\":\"ebs.csi.aws.com\""
          manifestJson `shouldContain` "\"volumeHandle\":\"vol-0123\""
          manifestJson `shouldContain` "\"key\":\"topology.ebs.csi.aws.com/zone\""
          manifestJson `shouldContain` "\"values\":[\"us-east-1a\"]"
          manifestJson `shouldContain` "\"volumeName\":\"prodbox-retained-vscode-vscode-0\""
          manifestJson `shouldNotContain` "\"hostPath\""
          manifestJson `shouldNotContain` "\"storageClassName\":\"gp2\""

    it
      "chartReleasesToDeploy deploys missing and non-deployed helm releases"
      $ do
        result <-
          buildChartDeploymentPlan
            "/tmp/prodbox"
            (testValidatedSettings "/tmp/prodbox/.data")
            "vscode"
            testChartSecrets
            Map.empty
        case result of
          Left err -> expectationFailure err
          Right plan -> do
            let names snaps = map chartReleasePlanReleaseName (chartReleasesToDeploy snaps plan)
                snapshot name status = ChartInstallSnapshot name "vscode" status
                present ks = Map.fromList [(k, snapshot k "deployed") | k <- ks]
            -- Nothing installed yet: deploy the whole chart root in order.
            names Map.empty `shouldBe` ["keycloak-postgres", "keycloak", "vscode"]
            -- Fully installed: idempotent no-op.
            names (present ["keycloak-postgres", "keycloak", "vscode"]) `shouldBe` []
            -- Partial rollback (keycloak uninstalled, siblings remain): deploy ONLY
            -- keycloak — the case the old all-or-nothing duplicates guard could
            -- never heal.
            names (present ["keycloak-postgres", "vscode"]) `shouldBe` ["keycloak"]
            -- Failed or interrupted Helm releases are not steady state and must be
            -- repaired by the next reconcile instead of being skipped as present.
            names
              ( Map.fromList
                  [ ("keycloak-postgres", snapshot "keycloak-postgres" "deployed")
                  , ("keycloak", snapshot "keycloak" "failed")
                  , ("vscode", snapshot "vscode" "pending-upgrade")
                  ]
              )
              `shouldBe` ["keycloak", "vscode"]

    it
      "kubernetesSecretDecodedDataField base64-decodes a present field and treats absent data/field as a benign no-op"
      $ do
        let secretJson =
              object
                [ "data"
                    .= object
                      [ "password" .= ("czNjcjN0LVB3IQ==" :: Text.Text)
                      , "username" .= ("a2V5Y2xvYWs=" :: Text.Text)
                      ]
                ]
        -- Present field: decoded to plain text (Percona's generated password is
        -- read out of the operator Secret before being synced into Vault).
        kubernetesSecretDecodedDataField "password" secretJson
          `shouldBe` Right (Just "s3cr3t-Pw!")
        kubernetesSecretDecodedDataField "username" secretJson
          `shouldBe` Right (Just "keycloak")
        -- Field absent from the data map: Nothing, not an error.
        kubernetesSecretDecodedDataField "verifier" secretJson
          `shouldBe` Right Nothing
        -- No data map at all (Secret not yet populated): Nothing, not an error,
        -- so the sync is a no-op on a not-yet-bootstrapped cluster.
        kubernetesSecretDecodedDataField "password" (object ["metadata" .= object []])
          `shouldBe` Right Nothing

    it "builds vscode deployment plans with dependency order and deterministic values" $ do
      result <-
        buildChartDeploymentPlan
          "/tmp/prodbox"
          (testValidatedSettings "/tmp/prodbox/.data")
          "vscode"
          testChartSecrets
          Map.empty
      case result of
        Left err -> expectationFailure err
        Right plan -> do
          chartDeploymentPlanRootChart plan `shouldBe` "vscode"
          chartDeploymentPlanNamespace plan `shouldBe` "vscode"
          chartDeploymentPlanPublicFqdn plan `shouldBe` Just "test.resolvefintech.com"
          map chartReleasePlanReleaseName (chartDeploymentPlanReleases plan)
            `shouldBe` ["keycloak-postgres", "keycloak", "vscode"]

          let releaseValues =
                Map.fromList
                  [ ( chartReleasePlanReleaseName release
                    , eitherDecode (BL8.pack (chartReleasePlanValuesJson release)) :: Either String Value
                    )
                  | release <- chartDeploymentPlanReleases plan
                  ]

          case Map.lookup "keycloak-postgres" releaseValues of
            Just (Right (Object payload)) -> do
              case KeyMap.lookup (Key.fromString "cluster") payload of
                Just (Object clusterPayload) -> do
                  KeyMap.lookup (Key.fromString "name") clusterPayload
                    `shouldBe` Just (String "prodbox-vscode-pg")
                  KeyMap.lookup (Key.fromString "instances") clusterPayload
                    `shouldBe` Just (Number 3)
                  KeyMap.lookup (Key.fromString "crVersion") clusterPayload
                    `shouldBe` Just (String "2.9.0")
                _ -> expectationFailure "expected keycloak-postgres cluster payload"
              case KeyMap.lookup (Key.fromString "image") payload of
                Just (Object imagePayload) -> do
                  case KeyMap.lookup (Key.fromString "postgres") imagePayload of
                    Just (Object postgresImagePayload) -> do
                      KeyMap.lookup (Key.fromString "repository") postgresImagePayload
                        `shouldBe` Just (String "127.0.0.1:30080/prodbox/percona-distribution-postgresql-mirror")
                      KeyMap.lookup (Key.fromString "tag") postgresImagePayload
                        `shouldBe` Just (String "17.9-1")
                    _ -> expectationFailure "expected keycloak-postgres postgres image payload"
                  case KeyMap.lookup (Key.fromString "pgBackRest") imagePayload of
                    Just (Object pgbackrestImagePayload) -> do
                      KeyMap.lookup (Key.fromString "repository") pgbackrestImagePayload
                        `shouldBe` Just (String "127.0.0.1:30080/prodbox/percona-pgbackrest-mirror")
                      KeyMap.lookup (Key.fromString "tag") pgbackrestImagePayload
                        `shouldBe` Just (String "2.58.0-1")
                    _ -> expectationFailure "expected keycloak-postgres pgBackRest image payload"
                  case KeyMap.lookup (Key.fromString "pgBouncer") imagePayload of
                    Just (Object pgbouncerImagePayload) -> do
                      KeyMap.lookup (Key.fromString "repository") pgbouncerImagePayload
                        `shouldBe` Just (String "127.0.0.1:30080/prodbox/percona-pgbouncer-mirror")
                      KeyMap.lookup (Key.fromString "tag") pgbouncerImagePayload
                        `shouldBe` Just (String "1.25.1-1")
                    _ -> expectationFailure "expected keycloak-postgres pgBouncer image payload"
                _ -> expectationFailure "expected keycloak-postgres image payload"
              case KeyMap.lookup (Key.fromString "postgres") payload of
                Just (Object postgresPayload) -> do
                  KeyMap.lookup (Key.fromString "version") postgresPayload
                    `shouldBe` Just (Number 17)
                  KeyMap.lookup (Key.fromString "database") postgresPayload
                    `shouldBe` Just (String "keycloak")
                  KeyMap.lookup (Key.fromString "username") postgresPayload
                    `shouldBe` Just (String "keycloak")
                _ -> expectationFailure "expected keycloak-postgres postgres payload"
              case KeyMap.lookup (Key.fromString "secrets") payload of
                Just (Object secretsPayload) -> do
                  case KeyMap.lookup (Key.fromString "application") secretsPayload of
                    Just (Object applicationPayload) -> do
                      KeyMap.lookup (Key.fromString "name") applicationPayload
                        `shouldBe` Just (String "prodbox-vscode-pg-pguser-keycloak")
                      KeyMap.lookup (Key.fromString "password") applicationPayload
                        `shouldBe` Nothing
                    _ -> expectationFailure "expected keycloak-postgres application secret payload"
                  case KeyMap.lookup (Key.fromString "superuser") secretsPayload of
                    Just (Object superuserPayload) -> do
                      KeyMap.lookup (Key.fromString "name") superuserPayload
                        `shouldBe` Just (String "prodbox-vscode-pg-pguser-postgres")
                      KeyMap.lookup (Key.fromString "password") superuserPayload
                        `shouldBe` Nothing
                    _ -> expectationFailure "expected keycloak-postgres superuser secret payload"
                  case KeyMap.lookup (Key.fromString "standby") secretsPayload of
                    Just (Object standbyPayload) -> do
                      KeyMap.lookup (Key.fromString "name") standbyPayload
                        `shouldBe` Just (String "prodbox-vscode-pg-primaryuser")
                      KeyMap.lookup (Key.fromString "username") standbyPayload
                        `shouldBe` Just (String "primaryuser")
                      KeyMap.lookup (Key.fromString "password") standbyPayload
                        `shouldBe` Nothing
                    _ -> expectationFailure "expected keycloak-postgres standby secret payload"
                _ -> expectationFailure "expected keycloak-postgres secrets payload"
              case KeyMap.lookup (Key.fromString "vault") payload of
                Just (Object vaultPayload) -> do
                  KeyMap.lookup (Key.fromString "role") vaultPayload
                    `shouldBe` Just (String "vscode-keycloak-postgres-pg")
                  case KeyMap.lookup (Key.fromString "paths") vaultPayload of
                    Just (Object pathsPayload) -> do
                      KeyMap.lookup (Key.fromString "application") pathsPayload
                        `shouldBe` Just (String "vscode/keycloak-postgres/patroni/app")
                      KeyMap.lookup (Key.fromString "superuser") pathsPayload
                        `shouldBe` Just (String "vscode/keycloak-postgres/patroni/superuser")
                      KeyMap.lookup (Key.fromString "standby") pathsPayload
                        `shouldBe` Just (String "vscode/keycloak-postgres/patroni/standby")
                    _ -> expectationFailure "expected keycloak-postgres vault paths payload"
                _ -> expectationFailure "expected keycloak-postgres vault payload"
              case KeyMap.lookup (Key.fromString "secretMaterializer") payload of
                Just (Object materializerPayload) -> do
                  KeyMap.lookup (Key.fromString "serviceAccountName") materializerPayload
                    `shouldBe` Just (String "prodbox-vscode-pg")
                  case KeyMap.lookup (Key.fromString "image") materializerPayload of
                    Just (Object imagePayload) -> do
                      KeyMap.lookup (Key.fromString "repository") imagePayload
                        `shouldBe` Just (String "127.0.0.1:30080/prodbox/curl-mirror")
                      KeyMap.lookup (Key.fromString "tag") imagePayload
                        `shouldBe` Just (String "8.11.0")
                    _ -> expectationFailure "expected keycloak-postgres secretMaterializer image payload"
                _ -> expectationFailure "expected keycloak-postgres secretMaterializer payload"
              case KeyMap.lookup (Key.fromString "security") payload of
                Just (Object securityPayload) -> do
                  KeyMap.lookup (Key.fromString "runAsUser") securityPayload
                    `shouldBe` Just (Number 1001)
                  KeyMap.lookup (Key.fromString "runAsGroup") securityPayload
                    `shouldBe` Just (Number 1001)
                  KeyMap.lookup (Key.fromString "fsGroup") securityPayload
                    `shouldBe` Just (Number 1001)
                _ -> expectationFailure "expected keycloak-postgres security payload"
              case KeyMap.lookup (Key.fromString "proxy") payload of
                Just (Object proxyPayload) ->
                  KeyMap.lookup (Key.fromString "pgBouncerReplicas") proxyPayload
                    `shouldBe` Just (Number 0)
                _ -> expectationFailure "expected keycloak-postgres proxy payload"
              case KeyMap.lookup (Key.fromString "backups") payload of
                Just (Object backupsPayload) ->
                  KeyMap.lookup (Key.fromString "enabled") backupsPayload
                    `shouldBe` Just (Bool False)
                _ -> expectationFailure "expected keycloak-postgres security payload"
            _ -> expectationFailure "expected keycloak-postgres values payload"

          case Map.lookup "keycloak" releaseValues of
            Just (Right (Object payload)) -> do
              KeyMap.lookup (Key.fromString "replicaCount") payload `shouldBe` Just (Number 1)
              case KeyMap.lookup (Key.fromString "image") payload of
                Just (Object imagePayload) -> do
                  KeyMap.lookup (Key.fromString "repository") imagePayload
                    `shouldBe` Just (String "127.0.0.1:30080/prodbox/keycloak-mirror")
                  KeyMap.lookup (Key.fromString "tag") imagePayload `shouldBe` Just (String "26.0.0")
                _ -> expectationFailure "expected keycloak image payload"
              case KeyMap.lookup (Key.fromString "postgres") payload of
                Just (Object postgresPayload) -> do
                  KeyMap.lookup (Key.fromString "host") postgresPayload
                    `shouldBe` Just (String "prodbox-vscode-pg-ha.vscode.svc.cluster.local")
                  KeyMap.lookup (Key.fromString "database") postgresPayload `shouldBe` Just (String "keycloak")
                  KeyMap.lookup (Key.fromString "username") postgresPayload `shouldBe` Just (String "keycloak")
                  KeyMap.lookup (Key.fromString "passwordSecretName") postgresPayload
                    `shouldBe` Just (String "prodbox-vscode-pg-pguser-keycloak")
                _ -> expectationFailure "expected keycloak postgres payload"
              case KeyMap.lookup (Key.fromString "keycloak") payload of
                Just (Object keycloakPayload) ->
                  KeyMap.lookup (Key.fromString "publicHost") keycloakPayload
                    `shouldBe` Just (String "test.resolvefintech.com")
                _ -> expectationFailure "expected keycloak runtime payload"
              case KeyMap.lookup (Key.fromString "gateway") payload of
                Just (Object gatewayPayload) -> do
                  KeyMap.lookup (Key.fromString "className") gatewayPayload
                    `shouldBe` Just (String "prodbox-public-edge")
                  KeyMap.lookup (Key.fromString "host") gatewayPayload
                    `shouldBe` Just (String "test.resolvefintech.com")
                  KeyMap.lookup (Key.fromString "httpRedirectListenerName") gatewayPayload
                    `shouldBe` Just (String "http")
                  KeyMap.lookup (Key.fromString "httpRedirectRouteName") gatewayPayload
                    `shouldBe` Just (String "public-edge-http-redirect")
                  KeyMap.lookup (Key.fromString "authPathPrefix") gatewayPayload
                    `shouldBe` Just (String "/auth")
                _ -> expectationFailure "expected keycloak gateway payload"
              case KeyMap.lookup (Key.fromString "oidc") payload of
                Just (Object oidcPayload) -> do
                  KeyMap.lookup (Key.fromString "vscodeClientId") oidcPayload
                    `shouldBe` Just (String "vscode")
                  KeyMap.lookup (Key.fromString "redirectUri") oidcPayload
                    `shouldBe` Just (String "https://test.resolvefintech.com/vscode/oauth2/callback")
                _ -> expectationFailure "expected keycloak oidc payload"
              case KeyMap.lookup (Key.fromString "vault") payload of
                Just (Object vaultPayload) -> do
                  KeyMap.lookup (Key.fromString "role") vaultPayload
                    `shouldBe` Just (String "vscode-keycloak")
                  case KeyMap.lookup (Key.fromString "paths") vaultPayload of
                    Just (Object pathsPayload) -> do
                      KeyMap.lookup (Key.fromString "admin") pathsPayload
                        `shouldBe` Just (String "vscode/keycloak/admin")
                      KeyMap.lookup (Key.fromString "db") pathsPayload
                        `shouldBe` Just (String "vscode/keycloak-postgres/patroni/app")
                      KeyMap.lookup (Key.fromString "oidcWebsocket") pathsPayload
                        `shouldBe` Just (String "vscode/oidc/prodbox-websocket")
                      KeyMap.lookup (Key.fromString "smtp") pathsPayload
                        `shouldBe` Just (String "keycloak/smtp")
                    _ -> expectationFailure "expected keycloak vault paths payload"
                _ -> expectationFailure "expected keycloak vault payload"
            _ -> expectationFailure "expected keycloak values payload"
          case Map.lookup "vscode" releaseValues of
            Just (Right (Object payload)) -> do
              KeyMap.lookup (Key.fromString "replicaCount") payload `shouldBe` Just (Number 1)
              case KeyMap.lookup (Key.fromString "gateway") payload of
                Just (Object gatewayPayload) -> do
                  KeyMap.lookup (Key.fromString "className") gatewayPayload
                    `shouldBe` Just (String "prodbox-public-edge")
                  KeyMap.lookup (Key.fromString "host") gatewayPayload
                    `shouldBe` Just (String "test.resolvefintech.com")
                _ -> expectationFailure "expected vscode gateway payload"
              case KeyMap.lookup (Key.fromString "oidc") payload of
                Just (Object oidcPayload) -> do
                  KeyMap.lookup (Key.fromString "clientId") oidcPayload
                    `shouldBe` Just (String "vscode")
                  -- Sprint 3.18: the chart's hook Job materializes the
                  -- Envoy SecurityPolicy client Secret from Vault, so
                  -- `valuesForVscode` must not emit a plaintext
                  -- `oidc.clientSecret` value.
                  KeyMap.lookup (Key.fromString "clientSecret") oidcPayload
                    `shouldBe` Nothing
                  KeyMap.lookup (Key.fromString "issuer") oidcPayload
                    `shouldBe` Just (String "https://test.resolvefintech.com/auth/realms/prodbox")
                  KeyMap.lookup (Key.fromString "authorizationEndpoint") oidcPayload
                    `shouldBe` Just
                      ( String
                          "https://test.resolvefintech.com/auth/realms/prodbox/protocol/openid-connect/auth"
                      )
                  KeyMap.lookup (Key.fromString "tokenEndpoint") oidcPayload
                    `shouldBe` Just
                      ( String
                          "http://keycloak.vscode.svc.cluster.local:8080/auth/realms/prodbox/protocol/openid-connect/token"
                      )
                  case KeyMap.lookup (Key.fromString "providerBackend") oidcPayload of
                    Just (Object providerBackendPayload) -> do
                      KeyMap.lookup (Key.fromString "serviceName") providerBackendPayload
                        `shouldBe` Just (String "keycloak")
                      KeyMap.lookup (Key.fromString "servicePort") providerBackendPayload
                        `shouldBe` Just (Number 8080)
                    _ -> expectationFailure "expected vscode oidc providerBackend payload"
                _ -> expectationFailure "expected vscode oidc payload"
              case KeyMap.lookup (Key.fromString "vault") payload of
                Just (Object vaultPayload) -> do
                  KeyMap.lookup (Key.fromString "role") vaultPayload
                    `shouldBe` Just (String "vscode-oidc")
                  case KeyMap.lookup (Key.fromString "paths") vaultPayload of
                    Just (Object pathsPayload) ->
                      KeyMap.lookup (Key.fromString "oidcVscode") pathsPayload
                        `shouldBe` Just (String "vscode/oidc/vscode")
                    _ -> expectationFailure "expected vscode vault paths payload"
                _ -> expectationFailure "expected vscode vault payload"
              case KeyMap.lookup (Key.fromString "secretMaterializer") payload of
                Just (Object materializerPayload) ->
                  case KeyMap.lookup (Key.fromString "image") materializerPayload of
                    Just (Object imagePayload) -> do
                      KeyMap.lookup (Key.fromString "repository") imagePayload
                        `shouldBe` Just (String "127.0.0.1:30080/prodbox/curl-mirror")
                      KeyMap.lookup (Key.fromString "tag") imagePayload
                        `shouldBe` Just (String "8.11.0")
                    _ -> expectationFailure "expected vscode materializer image payload"
                _ -> expectationFailure "expected vscode materializer payload"
              case KeyMap.lookup (Key.fromString "vscode") payload of
                Just (Object vscodePayload) ->
                  KeyMap.lookup (Key.fromString "image") vscodePayload
                    `shouldBe` Just (String "127.0.0.1:30080/prodbox/code-server-mirror:4.98.2")
                _ -> expectationFailure "expected vscode image payload"
            _ -> expectationFailure "expected vscode values payload"

          case chartDeploymentPlanReleases plan of
            [keycloakPostgresRelease, _keycloakRelease, vscodeRelease] -> do
              length (chartReleasePlanStorageBindings keycloakPostgresRelease) `shouldBe` 3
              case chartReleasePlanStorageBindings vscodeRelease of
                [binding] ->
                  chartStorageBindingPersistentVolumeName binding
                    `shouldBe` "prodbox-retained-vscode-vscode-0"
                _ -> expectationFailure "expected vscode storage binding"
            [] -> expectationFailure "expected releases in chart deployment plan"
            _ -> expectationFailure "expected keycloak-postgres, keycloak, and vscode releases"

    -- Sprint 3.13 chunks 12 + 14 closed the host-side `.prodbox-state/charts`
    -- chart-secret cache. The two prior tests in this slot exercised the
    -- cache's read/merge + Patroni recovery path against `resolveChartSecrets`
    -- + `mergeChartSecretValues`; both have been deleted. The invariant
    -- they were guarding ("host-side secret state is the source of truth")
    -- is now structurally inverted: Vault KV plus chart-local materializers
    -- are the source of truth. The check below pins that inversion at the
    -- ChartPlatform surface: `resolveChartSecrets` no longer reads or writes
    -- any host-side state.
    it "resolveChartSecrets returns an empty map regardless of repoRoot state (chunks 12 + 14)" $
      withSystemTempDirectory "prodbox-chart-secrets-closure" $ \tempRoot -> do
        let namespaceDir = tempRoot </> ".prodbox-state" </> "vscode"
        createDirectoryIfMissing True namespaceDir
        result <- resolveChartSecrets tempRoot "vscode"
        case result of
          Left err -> expectationFailure err
          Right secrets -> Map.null secrets `shouldBe` True

  describe "native gateway helpers" $ do
    it "renders deterministic gateway status output" $ do
      let payload =
            Object
              ( KeyMap.fromList
                  [ (Key.fromString "node_id", String "node-a")
                  , (Key.fromString "gateway_owner", String "node-a")
                  , (Key.fromString "has_active_claim", Bool True)
                  , (Key.fromString "mesh_peers", Array (Vector.fromList [String "node-b"]))
                  , (Key.fromString "semantic_member_count", Number 2)
                  , (Key.fromString "signed_replay_assertion_count", Number 5)
                  , (Key.fromString "retained_assertion_count", Number 7)
                  , (Key.fromString "retained_assertion_capacity", Number 20)
                  , (Key.fromString "last_public_ip_observed", String "203.0.113.10")
                  , (Key.fromString "last_dns_write_ip", String "203.0.113.10")
                  , (Key.fromString "last_dns_write_at_utc", String "2026-04-06T10:00:00Z")
                  ,
                    ( Key.fromString "dns_write_gate"
                    , Object
                        ( KeyMap.fromList
                            [ (Key.fromString "zone_id", String "Z123")
                            , (Key.fromString "fqdn", String "test.resolvefintech.com")
                            , (Key.fromString "ttl", Number 60)
                            ]
                        )
                    )
                  ,
                    ( Key.fromString "heartbeat_age_seconds"
                    , Object
                        ( KeyMap.fromList
                            [ (Key.fromString "node-a", Number 0.0)
                            , (Key.fromString "node-b", Number 1.5)
                            ]
                        )
                    )
                  ]
              )
      case renderGatewayStatusReport payload of
        Left err -> expectationFailure err
        Right report -> do
          report `shouldContain` "ACTIVE_CLAIM=true"
          report `shouldContain` "DNS_WRITE_GATE=test.resolvefintech.com@Z123 ttl=60"
          report `shouldContain` "HEARTBEAT_NODE_B=1.5"

    it "enforces gateway timing relationships against the orders timeout" $ do
      let invalidConfigDhall =
            Text.pack
              ( unlines
                  ( [ "{ schemaVersion = 1"
                    ]
                      ++ gatewayVaultNoneLines
                      ++ [ ", boot ="
                         , "  { node_id = \"node-a\""
                         , "  , cert_file = \"node-a.crt\""
                         , "  , key_file = \"node-a.key\""
                         , "  , ca_file = \"ca.crt\""
                         , "  , orders_file = \"orders.dhall\""
                         ]
                      ++ gatewayEventKeyTestPlaintextLines "node-a" "REPLACE_WITH_SECRET_KEY"
                      ++ [ "  , dns_write_gate ="
                         , "      None { zone_id : Text, fqdn : Text, ttl : Natural, aws_region : Text }"
                         ]
                      ++ gatewayAwsCredsNoneLines
                      ++ gatewayMinioCredsNoneLines
                      ++ [ "  , minio_endpoint_url = None Text"
                         , "  }"
                         , ", live ="
                         , "  { heartbeat_interval_seconds = 2.0"
                         , "  , reconnect_interval_seconds = 1.0"
                         , "  , sync_interval_seconds = 5.0"
                         , "  , max_clock_skew_seconds = 10.0"
                         , "  , drain_deadline_seconds = Some 30"
                         , "  , log_level = Some \"info\""
                         , "  }"
                         , "}"
                         ]
                  )
              )
          ordersDhall =
            Text.pack
              ( unlines
                  [ "{ version_utc = 1"
                  , ", nodes ="
                  , "  [ { node_id = \"node-a\""
                  , "    , stable_dns_name = \"node-a.example.test\""
                  , "    , rest_host = \"0.0.0.0\""
                  , "    , rest_port = 31001"
                  , "    , socket_host = \"0.0.0.0\""
                  , "    , socket_port = 32001"
                  , "    }"
                  , "  ]"
                  , ", gateway_rule ="
                  , "    { ranked_nodes = [ \"node-a\" ]"
                  , "    , heartbeat_timeout_seconds = 3"
                  , "    }"
                  , "}"
                  ]
              )
      configResult <- GatewaySettings.decodeDaemonConfigDhall invalidConfigDhall
      ordersResult <- GatewaySettings.decodeOrdersDhall ordersDhall
      case (configResult, ordersResult) of
        (Right config, Right orders) ->
          validateDaemonTimingAgainstOrders config orders
            `shouldBe` Left "heartbeat_interval_seconds must be <= heartbeat_timeout_seconds / 2"
        (Left err, _) -> expectationFailure err
        (_, Left err) -> expectationFailure err

    it "renders gateway config templates with dns_write_gate" $
      withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)

        result <- validateAndLoadSettingsAtPath (tmpDir </> "prodbox.dhall") tmpDir

        case result of
          Left err -> expectationFailure err
          Right settings -> do
            decoded <-
              GatewaySettings.decodeDaemonConfigDhallWith
                (const (pure (Right "resolved-secret")))
                (Text.pack (renderGatewayConfigTemplate settings "node-a"))
            case decoded of
              Left err -> expectationFailure err
              Right config ->
                case daemonDnsWriteGate config of
                  Nothing -> expectationFailure "expected Just DnsWriteGate"
                  Just gate -> do
                    case daemonVaultAuth config of
                      Nothing -> expectationFailure "expected gateway Vault auth"
                      Just vaultAuth -> do
                        gatewayVaultAddress vaultAuth `shouldBe` "http://vault.vault.svc.cluster.local:8200"
                        gatewayVaultAuthPath vaultAuth `shouldBe` "kubernetes"
                        gatewayVaultRole vaultAuth `shouldBe` "gateway-gateway"
                        gatewayVaultServiceAccountTokenFile vaultAuth
                          `shouldBe` "/var/run/secrets/kubernetes.io/serviceaccount/token"
                    dnsWriteGateFqdn gate `shouldBe` "test.resolvefintech.com"
                    dnsWriteGateZoneId gate `shouldBe` "Z1234567890ABC"
                    dnsWriteGateTtl gate `shouldBe` 60
                    dnsWriteGateAwsRegion gate `shouldBe` "us-east-1"

    it
      "treats present-but-empty aws_creds as no aws creds on the home substrate (daemonAwsCreds = Nothing)"
      $ do
        -- Resolver simulating the home substrate: the operational `aws.*` block is
        -- unpopulated, so the gateway's `aws_creds` Vault refs (path contains
        -- "aws") resolve EMPTY, while event_keys / minio_creds resolve fine. The
        -- daemon must run WITHOUT aws creds rather than crash-loop on the empty
        -- required field (`aws_creds.access_key_id resolved to an empty value`).
        let homeResolver ref =
              pure . Right $ case ref of
                SecretRefVault vref | Text.isInfixOf "aws" (vaultSecretPath vref) -> ""
                _ -> "resolved-secret"
        decoded <-
          GatewaySettings.decodeDaemonConfigDhallWith
            homeResolver
            (Text.pack (renderGatewayConfigTemplate (testValidatedSettings "/tmp/prodbox/.data") "node-a"))
        case decoded of
          Left err -> expectationFailure err
          Right config ->
            case daemonAwsCreds config of
              Nothing -> pure ()
              Just _ -> expectationFailure "expected daemonAwsCreds = Nothing for empty home-substrate aws creds"

    it
      "treats an ABSENT aws_creds secret (Vault 404 -> field missing) as no aws creds (daemonAwsCreds = Nothing)"
      $ do
        -- Regression: on a fresh Vault during a bare `cluster reconcile` the
        -- operational `aws.*` block is unmaterialized, so
        -- secret/gateway/gateway/aws does not exist yet and its Vault refs 404.
        -- `resolveSecretRefFromVault` maps that 404 to
        -- 'SecretRefVaultFieldMissing'; the daemon must run WITHOUT aws creds
        -- rather than fail the whole config decode and boot degraded pre-Vault
        -- (which failed StepGatewayChartReady's object-store self-heal check and
        -- aborted `prodbox test all`). Companion to the present-but-empty case
        -- above.
        let absentAwsResolver ref =
              pure $ case ref of
                SecretRefVault vref
                  | Text.isInfixOf "aws" (vaultSecretPath vref) ->
                      Left SecretRefVaultFieldMissing
                _ -> Right "resolved-secret"
        decoded <-
          GatewaySettings.decodeDaemonConfigDhallWith
            absentAwsResolver
            (Text.pack (renderGatewayConfigTemplate (testValidatedSettings "/tmp/prodbox/.data") "node-a"))
        case decoded of
          Left err -> expectationFailure err
          Right config ->
            case daemonAwsCreds config of
              Nothing -> pure ()
              Just _ -> expectationFailure "expected daemonAwsCreds = Nothing for absent home-substrate aws creds"

    it "decodes chart-shaped config in pre-Vault mode without resolving SecretRefs" $ do
      decoded <-
        GatewaySettings.decodeDaemonConfigDhallPreVault
          (Text.pack (renderGatewayConfigTemplate (testValidatedSettings "/tmp/prodbox/.data") "node-a"))
      case decoded of
        Left err -> expectationFailure err
        Right config -> do
          daemonEventKeys config `shouldBe` []
          daemonAwsCreds config `shouldBe` Nothing
          daemonMinioCreds config `shouldBe` Nothing
          daemonMinioEndpointUrl config `shouldBe` Nothing
          case daemonVaultAuth config of
            Nothing -> expectationFailure "expected gateway Vault auth"
            Just vaultAuth ->
              gatewayVaultAddress vaultAuth `shouldBe` "http://vault.vault.svc.cluster.local:8200"

  describe "gateway daemon full-mode reconcile (post-Vault pre-Vault-boot fix)" $ do
    it "gatewayDaemonDeploymentRefs targets one Deployment per gateway node" $
      gatewayDaemonDeploymentRefs
        `shouldBe` [ "deployment/gateway-node-a"
                   , "deployment/gateway-node-b"
                   , "deployment/gateway-node-c"
                   ]

    it "classifyGatewayObjectStoreProbe: a reachable object-store (present or absent) is healthy" $ do
      classifyGatewayObjectStoreProbe (Right (Just "checkpoint")) `shouldBe` GatewayObjectStoreHealthy
      classifyGatewayObjectStoreProbe (Right Nothing) `shouldBe` GatewayObjectStoreHealthy

    it "classifyGatewayObjectStoreProbe: a 503 is degraded pre-Vault mode (needs restart)" $
      case classifyGatewayObjectStoreProbe
        ( Left
            ( Prodbox.Gateway.Client.GatewayTransport
                (Prodbox.Http.Client.HttpStatus 503 "daemon MinIO credentials are not configured\n")
            )
        ) of
        GatewayObjectStoreDegraded503 body -> body `shouldContain` "MinIO credentials"
        other -> expectationFailure ("expected GatewayObjectStoreDegraded503, got " ++ show other)

    it "classifyGatewayObjectStoreProbe: other errors are transient (retry, don't restart)" $ do
      case classifyGatewayObjectStoreProbe
        (Left (Prodbox.Gateway.Client.GatewayTransport (Prodbox.Http.Client.HttpConnectionFailure "refused"))) of
        GatewayObjectStoreTransient _ -> pure ()
        other -> expectationFailure ("expected GatewayObjectStoreTransient, got " ++ show other)
      case classifyGatewayObjectStoreProbe
        (Left (Prodbox.Gateway.Client.GatewayTransport (Prodbox.Http.Client.HttpStatus 500 "boom"))) of
        GatewayObjectStoreTransient _ -> pure ()
        other -> expectationFailure ("expected GatewayObjectStoreTransient, got " ++ show other)

    it "daemonBootFieldsChanged: a changed daemonMinioCreds / daemonAwsCreds is a boot change" $ do
      decoded <-
        GatewaySettings.decodeDaemonConfigDhallWith
          (\_ -> pure (Right "resolved-secret"))
          (Text.pack (renderGatewayConfigTemplate (testValidatedSettings "/tmp/prodbox/.data") "node-a"))
      case decoded of
        Left err -> expectationFailure err
        Right config -> do
          daemonBootFieldsChanged config config `shouldBe` False
          daemonBootFieldsChanged config (config {daemonMinioCreds = Nothing}) `shouldBe` True
          daemonBootFieldsChanged config (config {daemonAwsCreds = Nothing}) `shouldBe` True

  describe "Sprint 2.17 Haskell HTTP client" $ do
    it "renders HttpConnectionFailure as a single-line operator-facing string" $
      Prodbox.Http.Client.renderHttpError
        (Prodbox.Http.Client.HttpConnectionFailure "connection refused")
        `shouldBe` "HTTP connection failure: connection refused"

    it "renders HttpTimeout with the underlying reason" $
      Prodbox.Http.Client.renderHttpError
        (Prodbox.Http.Client.HttpTimeout "response timeout")
        `shouldBe` "HTTP timeout: response timeout"

    it "renders HttpStatus with the status code and body" $
      Prodbox.Http.Client.renderHttpError
        (Prodbox.Http.Client.HttpStatus 404 "not found")
        `shouldBe` "HTTP 404 response: not found"

    it "truncates oversized HttpStatus bodies at 200 chars" $
      let longBody = replicate 500 'x'
          rendered =
            Prodbox.Http.Client.renderHttpError
              (Prodbox.Http.Client.HttpStatus 500 longBody)
       in (length rendered <= 250) `shouldBe` True

    it "renders HttpDecode with the decode error" $
      Prodbox.Http.Client.renderHttpError
        (Prodbox.Http.Client.HttpDecode "key not found")
        `shouldBe` "HTTP response decode error: key not found"

    it "defaultHttpConfig uses a 10-second timeout" $
      Prodbox.Http.Client.httpRequestTimeoutMicros Prodbox.Http.Client.defaultHttpConfig
        `shouldBe` (10 * 1000 * 1000 :: Int)

    it "renderGatewayError wraps a transport error" $
      Prodbox.Gateway.Client.renderGatewayError
        ( Prodbox.Gateway.Client.GatewayTransport
            (Prodbox.Http.Client.HttpTimeout "response timeout")
        )
        `shouldBe` "HTTP timeout: response timeout"

    it "renderGatewayError surfaces a payload error" $
      Prodbox.Gateway.Client.renderGatewayError
        (Prodbox.Gateway.Client.GatewayPayload "missing field")
        `shouldBe` "gateway response payload error: missing field"

    it "statusUrl appends /v1/state to the peer REST URL" $
      let endpoint =
            PeerEndpoint
              { peerNodeId = "node-a"
              , peerStableDnsName = "node-a.example"
              , peerRestHost = "192.0.2.10"
              , peerRestPort = 8443
              , peerSocketHost = "192.0.2.10"
              , peerSocketPort = 8444
              }
       in Prodbox.Gateway.Client.statusUrl endpoint
            `shouldBe` "http://192.0.2.10:8443/v1/state"

    it "statusUrl prefers stable DNS name when REST host is 0.0.0.0" $
      let endpoint =
            PeerEndpoint
              { peerNodeId = "node-a"
              , peerStableDnsName = "gateway.svc.cluster.local"
              , peerRestHost = "0.0.0.0"
              , peerRestPort = 8443
              , peerSocketHost = "0.0.0.0"
              , peerSocketPort = 8444
              }
       in Prodbox.Gateway.Client.statusUrl endpoint
            `shouldBe` "http://gateway.svc.cluster.local:8443/v1/state"

  describe "Sprint 2.18 host firewall gateway-restrict" $ do
    it "renders an iptables INPUT-append DROP rule scoped to non-loopback ingress" $
      gatewayNodePortFirewallRuleArgs 30443
        `shouldBe` [ "-A"
                   , "INPUT"
                   , "!"
                   , "-i"
                   , "lo"
                   , "-p"
                   , "tcp"
                   , "--dport"
                   , "30443"
                   , "-j"
                   , "DROP"
                   , "-m"
                   , "comment"
                   , "--comment"
                   , "prodbox-gateway-nodeport-loopback-only"
                   ]

    it "embeds the port number into the rule argv" $
      ("31443" `elem` gatewayNodePortFirewallRuleArgs 31443) `shouldBe` True

    it "always tags the rule with the stable comment for grep + dedup" $
      ( "prodbox-gateway-nodeport-loopback-only"
          `elem` gatewayNodePortFirewallRuleArgs 30443
      )
        `shouldBe` True

    it "check-args use -C and drop the leading -A action" $
      take 2 (gatewayNodePortFirewallCheckArgs 30443) `shouldBe` ["-C", "INPUT"]

    it "check-args otherwise match the install rule shape" $
      drop 1 (gatewayNodePortFirewallCheckArgs 30443)
        `shouldBe` drop 1 (gatewayNodePortFirewallRuleArgs 30443)

    it "FirewallRuleInstalled renders as 'installed' for operator logs" $
      renderFirewallRuleAction FirewallRuleInstalled `shouldBe` "installed"

    it "FirewallRuleAlreadyPresent renders as 'already-present'" $
      renderFirewallRuleAction FirewallRuleAlreadyPresent `shouldBe` "already-present"

  describe "Sprint 2.20 daemon Dhall settings" $ do
    let happyDhall =
          Text.pack
            ( unlines
                ( [ "{ schemaVersion = 1"
                  ]
                    ++ gatewayVaultNoneLines
                    ++ [ ", boot ="
                       , "  { node_id = \"node-a\""
                       , "  , cert_file = \"node-a.crt\""
                       , "  , key_file = \"node-a.key\""
                       , "  , ca_file = \"ca.crt\""
                       , "  , orders_file = \"orders.dhall\""
                       ]
                    ++ gatewayEventKeyTestPlaintextLines "node-a" "abcdef0123456789"
                    ++ [ "  , dns_write_gate ="
                       , "      Some { zone_id = \"Z123\""
                       , "           , fqdn = \"test.example.com\""
                       , "           , ttl = 60"
                       , "           , aws_region = \"us-east-1\""
                       , "           }"
                       ]
                    ++ gatewayAwsCredsNoneLines
                    ++ gatewayMinioCredsNoneLines
                    ++ [ "  , minio_endpoint_url = None Text"
                       , "  }"
                       , ", live ="
                       , "  { heartbeat_interval_seconds = 1.0"
                       , "  , reconnect_interval_seconds = 1.0"
                       , "  , sync_interval_seconds = 5.0"
                       , "  , max_clock_skew_seconds = 10.0"
                       , "  , drain_deadline_seconds = Some 30"
                       , "  , log_level = Some \"info\""
                       , "  }"
                       , "}"
                       ]
                )
            )

    it "decodes a happy-path daemon Dhall config" $ do
      result <- GatewaySettings.decodeDaemonConfigDhall happyDhall
      case result of
        Left err -> expectationFailure err
        Right config -> do
          daemonNodeId config `shouldBe` "node-a"
          daemonCertFile config `shouldBe` "node-a.crt"
          daemonKeyFile config `shouldBe` "node-a.key"
          daemonCaFile config `shouldBe` "ca.crt"
          daemonOrdersFile config `shouldBe` "orders.dhall"
          daemonHeartbeatInterval config `shouldBe` 1.0
          daemonReconnectInterval config `shouldBe` 1.0
          daemonSyncInterval config `shouldBe` 5.0
          daemonMaxClockSkewSeconds config `shouldBe` 10.0
          daemonDrainDeadlineSeconds config `shouldBe` Just 30
          daemonConfigLogLevel config `shouldBe` Just "info"
          daemonEventKeys config `shouldBe` [("node-a", "abcdef0123456789")]

    it "preserves the DnsWriteGate fields through the Dhall decoder" $ do
      result <- GatewaySettings.decodeDaemonConfigDhall happyDhall
      case result of
        Left err -> expectationFailure err
        Right config ->
          case daemonDnsWriteGate config of
            Nothing -> expectationFailure "expected Just DnsWriteGate"
            Just gate -> do
              dnsWriteGateZoneId gate `shouldBe` "Z123"
              dnsWriteGateFqdn gate `shouldBe` "test.example.com"
              dnsWriteGateTtl gate `shouldBe` 60
              dnsWriteGateAwsRegion gate `shouldBe` "us-east-1"

    it "fails fast on a schemaVersion mismatch" $ do
      let mismatched =
            Text.pack
              ( unlines
                  ( [ "{ schemaVersion = 99"
                    ]
                      ++ gatewayVaultNoneLines
                      ++ [ ", boot ="
                         , "  { node_id = \"node-a\""
                         , "  , cert_file = \"a.crt\""
                         , "  , key_file = \"a.key\""
                         , "  , ca_file = \"ca.crt\""
                         , "  , orders_file = \"orders.dhall\""
                         , gatewayEventKeysEmptyLine
                         , "  , dns_write_gate ="
                         , "      None { zone_id : Text"
                         , "           , fqdn : Text"
                         , "           , ttl : Natural"
                         , "           , aws_region : Text"
                         , "           }"
                         ]
                      ++ gatewayAwsCredsNoneLines
                      ++ gatewayMinioCredsNoneLines
                      ++ [ "  , minio_endpoint_url = None Text"
                         , "  }"
                         , ", live ="
                         , "  { heartbeat_interval_seconds = 1.0"
                         , "  , reconnect_interval_seconds = 1.0"
                         , "  , sync_interval_seconds = 5.0"
                         , "  , max_clock_skew_seconds = 10.0"
                         , "  , drain_deadline_seconds = None Natural"
                         , "  , log_level = None Text"
                         , "  }"
                         , "}"
                         ]
                  )
              )
      result <- GatewaySettings.decodeDaemonConfigDhall mismatched
      case result of
        Right _ -> expectationFailure "expected schema-mismatch failure"
        Left err -> err `shouldContain` "config_schema_mismatch"

    it "fails fast when a required boot field is empty" $ do
      let emptyNode =
            Text.pack
              ( unlines
                  ( [ "{ schemaVersion = 1"
                    ]
                      ++ gatewayVaultNoneLines
                      ++ [ ", boot ="
                         , "  { node_id = \"\""
                         , "  , cert_file = \"a.crt\""
                         , "  , key_file = \"a.key\""
                         , "  , ca_file = \"ca.crt\""
                         , "  , orders_file = \"orders.dhall\""
                         , gatewayEventKeysEmptyLine
                         , "  , dns_write_gate ="
                         , "      None { zone_id : Text"
                         , "           , fqdn : Text"
                         , "           , ttl : Natural"
                         , "           , aws_region : Text"
                         , "           }"
                         ]
                      ++ gatewayAwsCredsNoneLines
                      ++ gatewayMinioCredsNoneLines
                      ++ [ "  , minio_endpoint_url = None Text"
                         , "  }"
                         , ", live ="
                         , "  { heartbeat_interval_seconds = 1.0"
                         , "  , reconnect_interval_seconds = 1.0"
                         , "  , sync_interval_seconds = 5.0"
                         , "  , max_clock_skew_seconds = 10.0"
                         , "  , drain_deadline_seconds = None Natural"
                         , "  , log_level = None Text"
                         , "  }"
                         , "}"
                         ]
                  )
              )
      result <- GatewaySettings.decodeDaemonConfigDhall emptyNode
      case result of
        Right _ -> expectationFailure "expected empty-node_id failure"
        Left err -> err `shouldContain` "node_id is required"

    it "fails fast when heartbeat_interval_seconds is zero" $ do
      let zeroHb =
            Text.pack
              ( unlines
                  ( [ "{ schemaVersion = 1"
                    ]
                      ++ gatewayVaultNoneLines
                      ++ [ ", boot ="
                         , "  { node_id = \"node-a\""
                         , "  , cert_file = \"a.crt\""
                         , "  , key_file = \"a.key\""
                         , "  , ca_file = \"ca.crt\""
                         , "  , orders_file = \"orders.dhall\""
                         , gatewayEventKeysEmptyLine
                         , "  , dns_write_gate ="
                         , "      None { zone_id : Text"
                         , "           , fqdn : Text"
                         , "           , ttl : Natural"
                         , "           , aws_region : Text"
                         , "           }"
                         ]
                      ++ gatewayAwsCredsNoneLines
                      ++ gatewayMinioCredsNoneLines
                      ++ [ "  , minio_endpoint_url = None Text"
                         , "  }"
                         , ", live ="
                         , "  { heartbeat_interval_seconds = 0.0"
                         , "  , reconnect_interval_seconds = 1.0"
                         , "  , sync_interval_seconds = 5.0"
                         , "  , max_clock_skew_seconds = 10.0"
                         , "  , drain_deadline_seconds = None Natural"
                         , "  , log_level = None Text"
                         , "  }"
                         , "}"
                         ]
                  )
              )
      result <- GatewaySettings.decodeDaemonConfigDhall zeroHb
      case result of
        Right _ -> expectationFailure "expected positive-heartbeat failure"
        Left err -> err `shouldContain` "heartbeat_interval_seconds must be positive"

    it "dispatches by .dhall extension when loading from a file" $
      withSystemTempDirectory "prodbox-daemon-dhall" $ \tmpDir -> do
        let path = tmpDir </> "config.dhall"
            fileDhall =
              Text.pack
                ( unlines
                    ( [ "{ schemaVersion = 1"
                      ]
                        ++ gatewayVaultNoneLines
                        ++ [ ", boot ="
                           , "  { node_id = \"node-a\""
                           , "  , cert_file = \"node-a.crt\""
                           , "  , key_file = \"node-a.key\""
                           , "  , ca_file = \"ca.crt\""
                           , "  , orders_file = \"orders.dhall\""
                           , gatewayEventKeysEmptyLine
                           , "  , dns_write_gate ="
                           , "      None { zone_id : Text, fqdn : Text, ttl : Natural, aws_region : Text }"
                           ]
                        ++ gatewayAwsCredsNoneLines
                        ++ gatewayMinioCredsNoneLines
                        ++ [ "  , minio_endpoint_url = None Text"
                           , "  }"
                           , ", live ="
                           , "  { heartbeat_interval_seconds = 1.0"
                           , "  , reconnect_interval_seconds = 1.0"
                           , "  , sync_interval_seconds = 5.0"
                           , "  , max_clock_skew_seconds = 10.0"
                           , "  , drain_deadline_seconds = None Natural"
                           , "  , log_level = None Text"
                           , "  }"
                           , "}"
                           ]
                    )
                )
        writeFile path (Text.unpack fileDhall)
        result <- GatewaySettings.loadDaemonConfig path
        case result of
          Left err -> expectationFailure err
          Right config -> daemonNodeId config `shouldBe` "node-a"

  -- Sprint 2.20 closure: the JSON-dispatch fallback test was removed
  -- along with the JSON parser itself.

  describe "Sprint 2.22 gateway orders Dhall decoder" $ do
    it "decodes a happy-path orders Dhall expression" $ do
      let dhallSrc =
            Text.pack
              ( unlines
                  [ "{ version_utc = 1"
                  , ", nodes ="
                  , "  [ { node_id = \"node-a\""
                  , "    , stable_dns_name = \"gateway-node-a.svc\""
                  , "    , rest_host = \"0.0.0.0\""
                  , "    , rest_port = 31001"
                  , "    , socket_host = \"0.0.0.0\""
                  , "    , socket_port = 32001"
                  , "    }"
                  , "  ]"
                  , ", gateway_rule ="
                  , "    { ranked_nodes = [ \"node-a\" ]"
                  , "    , heartbeat_timeout_seconds = 5"
                  , "    }"
                  , "}"
                  ]
              )
      result <- GatewaySettings.decodeOrdersDhall dhallSrc
      case result of
        Left err -> expectationFailure err
        Right orders -> do
          ordersVersionUtc orders `shouldBe` 1
          length (ordersNodes orders) `shouldBe` 1
          rankedNodes (ordersGatewayRule orders) `shouldBe` ["node-a"]
          heartbeatTimeoutSeconds (ordersGatewayRule orders) `shouldBe` 5

    it "rejects orders with duplicate node_id values" $ do
      let dhallSrc =
            Text.pack
              ( unlines
                  [ "{ version_utc = 1"
                  , ", nodes ="
                  , "  [ { node_id = \"dup\""
                  , "    , stable_dns_name = \"a.svc\""
                  , "    , rest_host = \"0.0.0.0\""
                  , "    , rest_port = 31001"
                  , "    , socket_host = \"0.0.0.0\""
                  , "    , socket_port = 32001"
                  , "    }"
                  , "  , { node_id = \"dup\""
                  , "    , stable_dns_name = \"b.svc\""
                  , "    , rest_host = \"0.0.0.0\""
                  , "    , rest_port = 31002"
                  , "    , socket_host = \"0.0.0.0\""
                  , "    , socket_port = 32002"
                  , "    }"
                  , "  ]"
                  , ", gateway_rule ="
                  , "    { ranked_nodes = [ \"dup\" ]"
                  , "    , heartbeat_timeout_seconds = 5"
                  , "    }"
                  , "}"
                  ]
              )
      result <- GatewaySettings.decodeOrdersDhall dhallSrc
      case result of
        Right _ -> expectationFailure "expected duplicate-node_id failure"
        Left err -> err `shouldContain` "must be unique"

    it "rejects ranked_nodes referencing an unknown node_id" $ do
      let dhallSrc =
            Text.pack
              ( unlines
                  [ "{ version_utc = 1"
                  , ", nodes ="
                  , "  [ { node_id = \"node-a\""
                  , "    , stable_dns_name = \"a.svc\""
                  , "    , rest_host = \"0.0.0.0\""
                  , "    , rest_port = 31001"
                  , "    , socket_host = \"0.0.0.0\""
                  , "    , socket_port = 32001"
                  , "    }"
                  , "  ]"
                  , ", gateway_rule ="
                  , "    { ranked_nodes = [ \"unknown\" ]"
                  , "    , heartbeat_timeout_seconds = 5"
                  , "    }"
                  , "}"
                  ]
              )
      result <- GatewaySettings.decodeOrdersDhall dhallSrc
      case result of
        Right _ -> expectationFailure "expected ranked_nodes exact-membership failure"
        Left err -> err `shouldContain` "unique exact permutation"

  describe "Sprint 3.14 workload Dhall settings" $ do
    it "decodes a happy-path api workload Dhall config" $ do
      let dhallSrc =
            Text.pack
              ( unlines
                  [ "{ schemaVersion = 1"
                  , ", mode = < Api | Websocket >.Api"
                  , ", log_level = None Text"
                  , ", workload_port = Some 8080"
                  , ", vault = None"
                  , "    { address : Text"
                  , "    , auth_path : Text"
                  , "    , role : Text"
                  , "    , service_account_token_file : Optional Text"
                  , "    }"
                  , ", redis = None { host : Text, port : Text }"
                  , ", oidc = None"
                  , "    { issuer : Text"
                  , "    , client_id : Text"
                  , "    , client_secret :"
                  , "        < Vault : { mount : Text, path : Text, field : Text }"
                  , "        | TransitKey : Text"
                  , "        | Prompt : { name : Text, purpose : Text }"
                  , "        | TestPlaintext : Text"
                  , "        >"
                  , "    , public_base_url : Text"
                  , "    , token_endpoint : Text"
                  , "    }"
                  , "}"
                  ]
              )
      result <- WorkloadSettings.decodeWorkloadConfigDhall dhallSrc
      case result of
        Left err -> expectationFailure err
        Right dto -> do
          WorkloadSettings.mode dto `shouldBe` WorkloadSettings.Api
          WorkloadSettings.workload_port dto `shouldBe` Just 8080
          WorkloadSettings.redis dto `shouldBe` Nothing

    it "decodes a happy-path websocket workload Dhall config" $ do
      let dhallSrc =
            Text.pack
              ( unlines
                  [ "{ schemaVersion = 1"
                  , ", mode = < Api | Websocket >.Websocket"
                  , ", log_level = Some \"debug\""
                  , ", workload_port = Some 8081"
                  , ", redis = Some { host = \"redis\", port = \"6379\" }"
                  , ", oidc = Some"
                  , "    { issuer = \"https://test.example.com/auth/realms/r\""
                  , "    , client_id = \"prodbox\""
                  , "    , client_secret ="
                  , "        < Vault : { mount : Text, path : Text, field : Text }"
                  , "        | TransitKey : Text"
                  , "        | Prompt : { name : Text, purpose : Text }"
                  , "        | TestPlaintext : Text"
                  , "        >.TestPlaintext \"secret\""
                  , "    , public_base_url = \"https://test.example.com\""
                  , "    , token_endpoint = \"/token\""
                  , "    }"
                  , ", vault = None"
                  , "    { address : Text"
                  , "    , auth_path : Text"
                  , "    , role : Text"
                  , "    , service_account_token_file : Optional Text"
                  , "    }"
                  , "}"
                  ]
              )
      result <- WorkloadSettings.decodeWorkloadConfigDhall dhallSrc
      case result of
        Left err -> expectationFailure err
        Right dto -> do
          WorkloadSettings.mode dto `shouldBe` WorkloadSettings.Websocket
          WorkloadSettings.log_level dto `shouldBe` Just "debug"
          case WorkloadSettings.redis dto of
            Just r -> WorkloadSettings.host r `shouldBe` "redis"
            Nothing -> expectationFailure "expected Some redis config"

    it "fails fast on schemaVersion mismatch" $ do
      let mismatched =
            Text.pack
              ( unlines
                  [ "{ schemaVersion = 99"
                  , ", mode = < Api | Websocket >.Api"
                  , ", log_level = None Text"
                  , ", workload_port = None Natural"
                  , ", vault = None"
                  , "    { address : Text"
                  , "    , auth_path : Text"
                  , "    , role : Text"
                  , "    , service_account_token_file : Optional Text"
                  , "    }"
                  , ", redis = None { host : Text, port : Text }"
                  , ", oidc = None"
                  , "    { issuer : Text"
                  , "    , client_id : Text"
                  , "    , client_secret :"
                  , "        < Vault : { mount : Text, path : Text, field : Text }"
                  , "        | TransitKey : Text"
                  , "        | Prompt : { name : Text, purpose : Text }"
                  , "        | TestPlaintext : Text"
                  , "        >"
                  , "    , public_base_url : Text"
                  , "    , token_endpoint : Text"
                  , "    }"
                  , "}"
                  ]
              )
      result <- WorkloadSettings.decodeWorkloadConfigDhall mismatched
      case result of
        Right _ -> expectationFailure "expected schemaVersion mismatch failure"
        Left err -> err `shouldContain` "config_schema_mismatch"

  describe "Sprint 3.15 workload Boot/Live config split" $ do
    let decodeWorkload src = do
          result <- WorkloadSettings.decodeWorkloadConfigDhall (Text.pack (unlines src))
          case result of
            Left err -> expectationFailure err >> error "unreachable"
            Right dto -> pure dto
        buildLive =
          workloadLiveConfigFromDhallWith (resolveSecretRef TestHarnessMode)
        vaultNone =
          [ ", vault = None"
          , "    { address : Text"
          , "    , auth_path : Text"
          , "    , role : Text"
          , "    , service_account_token_file : Optional Text"
          , "    }"
          ]
        oidcType =
          [ "    { issuer : Text"
          , "    , client_id : Text"
          , "    , client_secret :"
          , "        < Vault : { mount : Text, path : Text, field : Text }"
          , "        | TransitKey : Text"
          , "        | Prompt : { name : Text, purpose : Text }"
          , "        | TestPlaintext : Text"
          , "        >"
          , "    , public_base_url : Text"
          , "    , token_endpoint : Text"
          , "    }"
          ]
        testPlaintextSecret =
          [ "    , client_secret ="
          , "        < Vault : { mount : Text, path : Text, field : Text }"
          , "        | TransitKey : Text"
          , "        | Prompt : { name : Text, purpose : Text }"
          , "        | TestPlaintext : Text"
          , "        >.TestPlaintext \"secret\""
          ]
        apiSrc =
          [ "{ schemaVersion = 1"
          , ", mode = < Api | Websocket >.Api"
          , ", log_level = None Text"
          , ", workload_port = Some 8080"
          ]
            ++ vaultNone
            ++ [ ", redis = None { host : Text, port : Text }"
               , ", oidc = None"
               ]
            ++ oidcType
            ++ [ "}"
               ]
        websocketSrc logLevelLine portLine redisLine =
          [ "{ schemaVersion = 1"
          , ", mode = < Api | Websocket >.Websocket"
          , logLevelLine
          , portLine
          ]
            ++ vaultNone
            ++ [ redisLine
               , ", oidc = Some"
               , "    { issuer = \"https://test.example.com/auth/realms/r\""
               , "    , client_id = \"prodbox\""
               ]
            ++ testPlaintextSecret
            ++ [ "    , public_base_url = \"https://test.example.com\""
               , "    , token_endpoint = \"/token\""
               , "    }"
               , "}"
               ]

    it "classifies mode and port as Boot fields and log_level as a Live field" $ do
      dto <- decodeWorkload apiSrc
      let boot = workloadBootConfigFromDhall dto
      bootMode boot `shouldBe` WorkloadApi
      bootPort boot `shouldBe` 8080
      liveResult <- buildLive (bootMode boot) dto
      case liveResult of
        Left err -> expectationFailure err
        Right live -> do
          liveLogLevel live `shouldBe` "info"
          liveRedisConfig live `shouldBe` Nothing
          liveOidcConfig live `shouldBe` Nothing

    it "defaults the listen port to 8080 when workload_port is None" $ do
      dto <-
        decodeWorkload
          ( [ "{ schemaVersion = 1"
            , ", mode = < Api | Websocket >.Api"
            , ", log_level = None Text"
            , ", workload_port = None Natural"
            ]
              ++ vaultNone
              ++ [ ", redis = None { host : Text, port : Text }"
                 , ", oidc = None"
                 ]
              ++ oidcType
              ++ [ "}"
                 ]
          )
      bootPort (workloadBootConfigFromDhall dto) `shouldBe` 8080

    it "treats a log_level edit as a Live change (no Boot-field change)" $ do
      original <-
        decodeWorkload
          ( websocketSrc
              ", log_level = Some \"info\""
              ", workload_port = Some 8081"
              ", redis = Some { host = \"redis\", port = \"6379\" }"
          )
      edited <-
        decodeWorkload
          ( websocketSrc
              ", log_level = Some \"debug\""
              ", workload_port = Some 8081"
              ", redis = Some { host = \"redis\", port = \"6379\" }"
          )
      workloadBootFieldsChanged
        (workloadBootConfigFromDhall original)
        (workloadBootConfigFromDhall edited)
        `shouldBe` False
      liveResult <- buildLive WorkloadWebsocket edited
      case liveResult of
        Left err -> expectationFailure err
        Right live -> liveLogLevel live `shouldBe` "debug"

    it "treats a Redis-endpoint edit as a Live change (no Boot-field change)" $ do
      original <-
        decodeWorkload
          ( websocketSrc
              ", log_level = Some \"info\""
              ", workload_port = Some 8081"
              ", redis = Some { host = \"redis\", port = \"6379\" }"
          )
      edited <-
        decodeWorkload
          ( websocketSrc
              ", log_level = Some \"info\""
              ", workload_port = Some 8081"
              ", redis = Some { host = \"redis-2\", port = \"6380\" }"
          )
      workloadBootFieldsChanged
        (workloadBootConfigFromDhall original)
        (workloadBootConfigFromDhall edited)
        `shouldBe` False
      originalLiveResult <- buildLive WorkloadWebsocket original
      editedLiveResult <- buildLive WorkloadWebsocket edited
      case (originalLiveResult, editedLiveResult) of
        (Right originalLive, Right editedLive) ->
          liveRedisConfig editedLive `shouldNotBe` liveRedisConfig originalLive
        _ -> expectationFailure "expected both websocket live configs to build"

    it "treats a port edit as a Boot-field change (drain-and-exit)" $ do
      original <-
        decodeWorkload
          ( websocketSrc
              ", log_level = Some \"info\""
              ", workload_port = Some 8081"
              ", redis = Some { host = \"redis\", port = \"6379\" }"
          )
      edited <-
        decodeWorkload
          ( websocketSrc
              ", log_level = Some \"info\""
              ", workload_port = Some 9090"
              ", redis = Some { host = \"redis\", port = \"6379\" }"
          )
      workloadBootFieldsChanged
        (workloadBootConfigFromDhall original)
        (workloadBootConfigFromDhall edited)
        `shouldBe` True

    it "treats a mode edit as a Boot-field change (drain-and-exit)" $ do
      apiDto <- decodeWorkload apiSrc
      websocketDto <-
        decodeWorkload
          ( websocketSrc
              ", log_level = None Text"
              ", workload_port = Some 8080"
              ", redis = Some { host = \"redis\", port = \"6379\" }"
          )
      workloadBootFieldsChanged
        (workloadBootConfigFromDhall apiDto)
        (workloadBootConfigFromDhall websocketDto)
        `shouldBe` True

    it "rejects test plaintext on the default production workload resolver" $ do
      dto <-
        decodeWorkload
          ( websocketSrc
              ", log_level = None Text"
              ", workload_port = Some 8080"
              ", redis = Some { host = \"redis\", port = \"6379\" }"
          )
      liveResult <- workloadLiveConfigFromDhall WorkloadWebsocket dto
      case liveResult of
        Right _ -> expectationFailure "expected production resolver to reject TestPlaintext"
        Left err -> err `shouldContain` "plaintext secret values are forbidden"

    it "fails the live-config build when a websocket config omits redis" $ do
      dto <-
        decodeWorkload
          ( [ "{ schemaVersion = 1"
            , ", mode = < Api | Websocket >.Websocket"
            , ", log_level = None Text"
            , ", workload_port = Some 8081"
            ]
              ++ vaultNone
              ++ [ ", redis = None { host : Text, port : Text }"
                 , ", oidc = Some"
                 , "    { issuer = \"https://test.example.com\""
                 , "    , client_id = \"prodbox\""
                 ]
              ++ testPlaintextSecret
              ++ [ "    , public_base_url = \"https://test.example.com\""
                 , "    , token_endpoint = \"/token\""
                 , "    }"
                 , "}"
                 ]
          )
      liveResult <- buildLive WorkloadWebsocket dto
      case liveResult of
        Right _ -> expectationFailure "expected a structured failure when redis is None"
        Left err -> err `shouldContain` "redis must be Some"

    it "fails fast when the workload binary is started without --config" $ do
      exitCode <- runWorkloadCommand (WorkloadStart (WorkloadOptions {workloadConfigPath = Nothing}))
      exitCode `shouldBe` ExitFailure 1

    it "fails fast when the workload --config path does not exist" $ do
      exitCode <-
        runWorkloadCommand
          (WorkloadStart (WorkloadOptions {workloadConfigPath = Just "/nonexistent/workload/config.dhall"}))
      exitCode `shouldBe` ExitFailure 1

  describe "Sprint 3.13 in-cluster K8s API client pure helpers" $ do
    it "exposes the canonical in-pod ServiceAccount mount paths" $ do
      InCluster.inClusterServiceAccountDir
        `shouldBe` "/var/run/secrets/kubernetes.io/serviceaccount"
      InCluster.inClusterTokenPath
        `shouldBe` "/var/run/secrets/kubernetes.io/serviceaccount/token"
      InCluster.inClusterCaCertPath
        `shouldBe` "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
      InCluster.inClusterNamespacePath
        `shouldBe` "/var/run/secrets/kubernetes.io/serviceaccount/namespace"

    it "secretApiBaseUrl points at the in-cluster kube-apiserver Service" $
      InCluster.secretApiBaseUrl
        `shouldBe` "https://kubernetes.default.svc.cluster.local:443"

    it "secretApiPath renders the namespaced v1.Secret REST path" $ do
      InCluster.secretApiPath "keycloak" "keycloak-runtime"
        `shouldBe` "/api/v1/namespaces/keycloak/secrets/keycloak-runtime"
      InCluster.secretApiPath "default" "prodbox-keycloak-pg-pguser-postgres"
        `shouldBe` "/api/v1/namespaces/default/secrets/prodbox-keycloak-pg-pguser-postgres"

    it "secretManifestJson encodes apiVersion / kind / type / metadata / stringData" $ do
      let manifest =
            InCluster.secretManifestJson
              "keycloak"
              "keycloak-runtime"
              (Map.fromList [("KEYCLOAK_ADMIN_PASSWORD", "secret-value")])
          rendered = BL8.unpack (encode manifest)
      rendered `shouldContain` "\"apiVersion\":\"v1\""
      rendered `shouldContain` "\"kind\":\"Secret\""
      rendered `shouldContain` "\"type\":\"Opaque\""
      rendered `shouldContain` "\"name\":\"keycloak-runtime\""
      rendered `shouldContain` "\"namespace\":\"keycloak\""
      rendered `shouldContain` "\"KEYCLOAK_ADMIN_PASSWORD\":\"secret-value\""

    it "secretManifestStringData emits keys in ascending lexical order (deterministic)" $ do
      let rendered =
            BL8.unpack
              ( encode
                  ( InCluster.secretManifestStringData
                      (Map.fromList [("z", "1"), ("a", "2"), ("m", "3")])
                  )
              )
      rendered `shouldBe` "{\"a\":\"2\",\"m\":\"3\",\"z\":\"1\"}"

    it "secretManifestStringData round-trips with itself (purity invariant)" $ do
      let dataMap = Map.fromList [("user", "alice"), ("pass", "p@ss")]
      InCluster.secretManifestStringData dataMap
        `shouldBe` InCluster.secretManifestStringData dataMap

    it "secretManifestStringData handles an empty stringData map" $ do
      BL8.unpack (encode (InCluster.secretManifestStringData Map.empty))
        `shouldBe` "{}"

  describe "Sprint 4.17 destroy-path credential fallback" $ do
    it "AwsEks.credentialsConfigured rejects creds with an empty access_key_id" $
      let empty =
            Credentials
              { access_key_id = ""
              , secret_access_key = "S"
              , session_token = Nothing
              , region = "us-west-2"
              }
       in AwsEks.credentialsConfigured empty `shouldBe` False

    it "AwsEks.credentialsConfigured rejects creds with an empty secret_access_key" $
      let empty =
            Credentials
              { access_key_id = "A"
              , secret_access_key = ""
              , session_token = Nothing
              , region = "us-west-2"
              }
       in AwsEks.credentialsConfigured empty `shouldBe` False

    it "AwsEks.credentialsConfigured rejects creds with an empty region" $
      let empty =
            Credentials
              { access_key_id = "A"
              , secret_access_key = "S"
              , session_token = Nothing
              , region = ""
              }
       in AwsEks.credentialsConfigured empty `shouldBe` False

    it "AwsEks.credentialsConfigured accepts a fully-populated triple" $
      let full =
            Credentials
              { access_key_id = "A"
              , secret_access_key = "S"
              , session_token = Nothing
              , region = "us-west-2"
              }
       in AwsEks.credentialsConfigured full `shouldBe` True

  describe "Sprint 4.16 ResidueStatus typed predicates" $ do
    it "residuePresentByFileExistence returns ResidueAbsent when the file is missing" $
      Residue.residuePresentByFileExistence "aws-eks" "/some/snapshot.json" False
        `shouldBe` Residue.ResidueAbsent

    it
      "residuePresentByFileExistence returns ResiduePresent with file-existence evidence when the file is present"
      $ Residue.residuePresentByFileExistence "aws-eks" "/some/snapshot.json" True
        `shouldBe` Residue.ResiduePresent
          Residue.ResidueDetails
            { Residue.residueEvidence = "file-existence: /some/snapshot.json"
            , Residue.residueStackName = "aws-eks"
            }

    it "isResidueAbsent is the only constructor that matches absent" $ do
      Residue.isResidueAbsent Residue.ResidueAbsent `shouldBe` True
      Residue.isResidueAbsent (Residue.ResiduePresent residueFixtureDetails) `shouldBe` False
      Residue.isResidueAbsent (Residue.ResidueUnreachable residueFixtureMinioReason) `shouldBe` False

    it "isResiduePresent is the only constructor that matches present" $ do
      Residue.isResiduePresent (Residue.ResiduePresent residueFixtureDetails) `shouldBe` True
      Residue.isResiduePresent Residue.ResidueAbsent `shouldBe` False
      Residue.isResiduePresent (Residue.ResidueUnreachable residueFixtureMinioReason) `shouldBe` False

    it "isResidueUnreachable is the only constructor that matches unreachable" $ do
      Residue.isResidueUnreachable (Residue.ResidueUnreachable residueFixtureMinioReason) `shouldBe` True
      Residue.isResidueUnreachable Residue.ResidueAbsent `shouldBe` False
      Residue.isResidueUnreachable (Residue.ResiduePresent residueFixtureDetails) `shouldBe` False

    it "Sprint 4.20 residueBlocksTeardownGate: present OR unreachable blocks, only absent passes" $ do
      Residue.residueBlocksTeardownGate (Residue.ResidueUnreachable residueFixtureMinioReason)
        `shouldBe` True
      Residue.residueBlocksTeardownGate (Residue.ResidueUnreachable residueFixtureS3Reason)
        `shouldBe` True
      Residue.residueBlocksTeardownGate (Residue.ResiduePresent residueFixtureDetails)
        `shouldBe` True
      Residue.residueBlocksTeardownGate Residue.ResidueAbsent `shouldBe` False

    it "renderResidueStatus produces operator-readable evidence per constructor" $ do
      Residue.renderResidueStatus Residue.ResidueAbsent `shouldBe` "absent"
      Residue.renderResidueStatus (Residue.ResiduePresent residueFixtureDetails)
        `shouldBe` "present (aws-eks; evidence: file-existence: /some/snapshot.json)"
      Residue.renderResidueStatus (Residue.ResidueUnreachable residueFixtureMinioReason)
        `shouldBe` "unreachable (MinIO backend unreachable: connection refused)"

    it "renderResidueUnreachableReason discriminates the four reason constructors" $ do
      Residue.renderResidueUnreachableReason (Residue.ResidueBackendMinioUnreachable "x")
        `shouldBe` "MinIO backend unreachable: x"
      Residue.renderResidueUnreachableReason (Residue.ResidueBackendS3Unreachable "y")
        `shouldBe` "S3 backend unreachable: y"
      Residue.renderResidueUnreachableReason (Residue.ResidueQueryFailed "z")
        `shouldBe` "backend query failed: z"
      Residue.renderResidueUnreachableReason (Residue.ResidueQueryNotImplemented "ev")
        `shouldBe` "source-of-truth query not yet implemented (ev)"

    it "renderResidueDetails includes both stack name and evidence string" $
      Residue.renderResidueDetails residueFixtureDetails
        `shouldBe` "aws-eks; evidence: file-existence: /some/snapshot.json"

    it "ResidueStatus values are Eq-comparable by constructor and payload" $ do
      (Residue.ResidueAbsent == Residue.ResidueAbsent) `shouldBe` True
      (Residue.ResiduePresent residueFixtureDetails == Residue.ResiduePresent residueFixtureDetails)
        `shouldBe` True
      (Residue.ResiduePresent residueFixtureDetails == Residue.ResidueAbsent) `shouldBe` False
      ( Residue.ResidueUnreachable residueFixtureMinioReason
          == Residue.ResidueUnreachable residueFixtureS3Reason
        )
        `shouldBe` False

    it "residueAbsent constructor matches the ResidueAbsent value" $
      Residue.residueAbsent `shouldBe` Residue.ResidueAbsent

  describe "Sprint 4.21 registry per-run reconcile (resourcesToDestroy / pairPerRunResidue)" $ do
    let presentNames eks sub test =
          map
            ResourceRegistry.resourceName
            ( ResourceRegistry.resourcesToDestroy
                (ResourceRegistry.pairPerRunResidue eks sub test)
            )

    it "pairPerRunResidue lists the per-run resources in canonical order" $
      map
        (ResourceRegistry.resourceName . fst)
        (ResourceRegistry.pairPerRunResidue Residue.ResidueAbsent Residue.ResidueAbsent Residue.ResidueAbsent)
        `shouldBe` ["aws-eks", "aws-eks-subzone", "aws-test"]

    it "all-absent destroys nothing (cascade skips per-run destroys)" $
      presentNames Residue.ResidueAbsent Residue.ResidueAbsent Residue.ResidueAbsent `shouldBe` []

    it "all-present destroys every per-run stack in canonical order" $
      presentNames residueFixturePresent residueFixturePresent residueFixturePresent
        `shouldBe` ["aws-eks", "aws-eks-subzone", "aws-test"]

    it "only-middle-present preserves the canonical ordering position" $
      presentNames Residue.ResidueAbsent residueFixturePresent Residue.ResidueAbsent
        `shouldBe` ["aws-eks-subzone"]

    it "only-eks-present destroys only aws-eks" $
      presentNames residueFixturePresent Residue.ResidueAbsent Residue.ResidueAbsent
        `shouldBe` ["aws-eks"]

    it "only-test-present destroys only aws-test" $
      presentNames Residue.ResidueAbsent Residue.ResidueAbsent residueFixturePresent
        `shouldBe` ["aws-test"]

    it "ResidueUnreachable on any per-run stack is skipped (per-run graceful degradation)" $ do
      let minioDown = Residue.ResidueUnreachable residueFixtureMinioReason
      presentNames minioDown minioDown minioDown `shouldBe` []
      presentNames residueFixturePresent minioDown residueFixturePresent
        `shouldBe` ["aws-eks", "aws-test"]

    it "reconcileAbsent destroys present resources in order and stops fast on failure" $ do
      destroyed <- newIORef ([] :: [String])
      let mk name code =
            ResourceRegistry.ManagedResource
              { ResourceRegistry.resourceName = name
              , ResourceRegistry.resourceClass = ResourceClass.PerRun
              , ResourceRegistry.resourceEnsureCommand = Nothing
              , ResourceRegistry.resourceEnsurePresent = Nothing
              , ResourceRegistry.resourceDestroyCommand = "prodbox aws stack " ++ name ++ " destroy --yes"
              , ResourceRegistry.resourceDestroy = \_ -> do
                  modifyIORef' destroyed (++ [name])
                  pure code
              }
          pairs =
            [ (mk "first" ExitSuccess, residueFixturePresent)
            , (mk "skipped-absent" ExitSuccess, Residue.ResidueAbsent)
            , (mk "boom" (ExitFailure 1), residueFixturePresent)
            , (mk "after-failure" ExitSuccess, residueFixturePresent)
            ]
      outcome <- ResourceRegistry.reconcileAbsent "/tmp" pairs
      outcome `shouldBe` ExitFailure 1
      readIORef destroyed `shouldReturn` ["first", "boom"]

  describe "Sprint 4.26 destructive commands route through runPlanWithOptions" $ do
    let defaultFlags =
          Rke2DeleteFlags
            { rke2DeleteYes = True
            , rke2DeleteCascade = False
            }
        cascadeFlags = defaultFlags {rke2DeleteCascade = True}

    it "default-delete plan is a pure local uninstall (no per-run AWS backend interaction)" $ do
      let rendered = renderNativeDeletePlan "/repo" defaultFlags
      rendered `shouldContain` "MODE=default"
      rendered `shouldContain` "STEP=delete_rke2_cluster_substrate"
      rendered `shouldContain` "STEP=render_retained_state_notice"
      -- The default delete no longer queries/gates/destroys the per-run
      -- AWS Pulumi backend; that lives in --cascade only.
      rendered `shouldNotContain` "STEP=per_run_destroy"
      rendered `shouldNotContain` "STEP=refuse_on_live_per_run_residue"
      rendered `shouldNotContain` "ALLOW_PULUMI_RESIDUE"

    it "cascade plan renders the canonical drain-before-destroys narration + every per-run stack" $ do
      let rendered = renderNativeDeletePlan "/repo" cascadeFlags
      rendered `shouldContain` cascadeOrderNarration
      rendered `shouldContain` "STEP=k8s_drain"
      rendered `shouldContain` "STEP=per_run_destroy aws-eks-subzone"
      -- drain step precedes the per-run destroy steps in the rendered plan.
      let planLines = lines rendered
          drainIdx = elemIndex "STEP=k8s_drain" planLines
          destroyIdx = elemIndex "STEP=per_run_destroy aws-eks" planLines
      (drainIdx < destroyIdx) `shouldBe` True
      drainIdx `shouldSatisfy` (/= Nothing)

    it "the cascade per-run sweep lists exactly the per-run Pulumi stack resources in order" $ do
      let registryNames =
            map ResourceRegistry.resourceName ResourceRegistry.perRunManagedResources
          planSteps =
            [ drop (length ("STEP=per_run_destroy " :: String)) line
            | line <- lines (renderNativeDeletePlan "/repo" cascadeFlags)
            , "STEP=per_run_destroy " `isPrefixOf` line
            ]
      planSteps `shouldBe` registryNames
      registryNames `shouldBe` StackDescriptor.perRunStackDescriptorNames

    it "rke2 delete --dry-run renders the plan and performs NO mutation (the core 4.26 fix)" $ do
      -- The audit's #1 bug: `rke2 delete --yes --dry-run` SILENTLY MUTATED.
      -- runPlanWithOptions with dryRun=True must render the destructive plan
      -- and NEVER invoke the apply closure.
      applyCalled <- newIORef False
      let plan = buildNativeDeletePlan "/repo" defaultFlags
      exit <-
        runPlanWithOptions
          PlanOptions {dryRun = True, planFile = Nothing}
          plan
          (\_ -> writeIORef applyCalled True >> pure (ExitFailure 99))
      exit `shouldBe` ExitSuccess
      mutated <- readIORef applyCalled
      mutated `shouldBe` False

    it "rke2 delete --plan-file writes the rendered destructive plan" $ do
      applyCalled <- newIORef False
      tmpDir <- getTemporaryDirectory
      let planPath = tmpDir </> "prodbox-4-26-rke2-delete-plan.txt"
          plan = buildNativeDeletePlan "/repo" cascadeFlags
      _ <-
        runPlanWithOptions
          PlanOptions {dryRun = True, planFile = Just planPath}
          plan
          (\_ -> writeIORef applyCalled True >> pure ExitSuccess)
      written <- readFile planPath
      written `shouldContain` cascadeOrderNarration
      written `shouldContain` "STEP=per_run_destroy aws-eks-subzone"
      readIORef applyCalled `shouldReturn` False

    it "nuke --dry-run renders the plan with a fail-closed step-4 description and does not prompt" $ do
      let plan = Nuke.renderNukePlan "/repo"
      plan `shouldContain` "STEP=4"
      plan `shouldContain` "fail-closed"
      plan `shouldContain` "STEP=5"

  -- Sprint 5.6: the three destructive `--dry-run` goldens (audit V80 found
  -- them missing). Each golden pins the exact planned step list a
  -- destructive path emits WITHOUT executing it (the goldens render the
  -- pure plan renderer, which `rke2 delete --dry-run` / `nuke --dry-run`
  -- route through via runPlanWithOptions; the separate Sprint 4.26 tests
  -- above prove dry-run performs NO mutation). The per-run / long-lived
  -- stack lines are registry-derived, so the golden tracks the
  -- managed-resource registry / StackDescriptor SSoT, and the drift check
  -- below fails if a registered resource is added without updating the
  -- golden.
  describe "Sprint 5.6 destructive dry-run goldens (registry-generated)" $ do
    let destructiveGoldenRepoRoot = "/tmp/prodbox"
        defaultDeleteFlags =
          Rke2DeleteFlags
            { rke2DeleteYes = True
            , rke2DeleteCascade = False
            }
        cascadeDeleteFlags = defaultDeleteFlags {rke2DeleteCascade = True}

    let renderUtf8 = BL.fromStrict . TextEncoding.encodeUtf8 . Text.pack

    goldenTest
      "rke2 delete --dry-run plan"
      "test/golden/destructive/rke2-delete.txt"
      ( pure
          (renderUtf8 (renderNativeDeletePlan destructiveGoldenRepoRoot defaultDeleteFlags))
      )

    goldenTest
      "rke2 delete --cascade --dry-run plan"
      "test/golden/destructive/rke2-delete-cascade.txt"
      ( pure
          (renderUtf8 (renderNativeDeletePlan destructiveGoldenRepoRoot cascadeDeleteFlags))
      )

    goldenTest
      "nuke --dry-run plan"
      "test/golden/destructive/nuke.txt"
      (pure (renderUtf8 (Nuke.renderNukePlan destructiveGoldenRepoRoot)))

    it "the cascade rke2-delete golden names every PerRun registry resource (drift guard)" $ do
      defaultGolden <- readFile "test/golden/destructive/rke2-delete.txt"
      cascadeGolden <- readFile "test/golden/destructive/rke2-delete-cascade.txt"
      let perRunNames = map ResourceRegistry.resourceName ResourceRegistry.perRunManagedResources
      -- The default delete is a pure local uninstall: it has NO per_run_destroy
      -- steps. Only the cascade golden carries the per-run sweep; if a new
      -- PerRun resource is registered without regenerating the cascade golden,
      -- this fails.
      defaultGolden `shouldNotContain` "STEP=per_run_destroy"
      mapM_
        (\name -> cascadeGolden `shouldContain` ("STEP=per_run_destroy " ++ name))
        perRunNames
      perRunNames `shouldBe` StackDescriptor.perRunStackDescriptorNames

    it "the nuke golden names every registry-derived destroy target (drift guard)" $ do
      nukeGolden <- readFile "test/golden/destructive/nuke.txt"
      let perRunNames = map ResourceRegistry.resourceName ResourceRegistry.perRunManagedResources
          longLivedNames = map ResourceRegistry.resourceName ResourceRegistry.longLivedManagedResources
      mapM_
        (\name -> nukeGolden `shouldContain` ("STEP=2 per_run_destroy " ++ name))
        perRunNames
      -- aws-ses long-lived Pulumi destroy command is registry-derived.
      nukeGolden
        `shouldContain` ("STEP=1 " ++ ResourceRegistry.resourceDestroyCommand ResourceRegistry.awsSesPulumiResource)
      mapM_
        (\name -> nukeGolden `shouldContain` ("STEP=4 long_lived_destroy " ++ name))
        longLivedNames

  describe "Sprint 4.26 checkPlanOptionsHonored lint" $ do
    it "fires when Rke2Delete binds its PlanOptions to a _ wildcard" $ do
      let offending = "    Rke2Delete flags _planOptions ->\n      foo\n"
      planOptionsHonoredViolations "src/Prodbox/CLI/Rke2.hs" offending
        `shouldSatisfy` (not . null)

    it "fires when NativeNuke binds its NukeOptions to a _ wildcard" $ do
      let offending = "    NativeNuke _opts -> runNukeCommand repoRoot defaultNukeOptions\n"
      planOptionsHonoredViolations "src/Prodbox/Native.hs" offending
        `shouldSatisfy` (not . null)

    it "is silent when the options field is bound to a real name" $ do
      let honest =
            "    Rke2Delete flags planOptions ->\n"
              ++ "      runPlanWithOptions planOptions plan apply\n"
              ++ "    NativeNuke nukeOptions -> runNukeCommand repoRoot nukeOptions\n"
      planOptionsHonoredViolations "src/Prodbox/CLI/Rke2.hs" honest `shouldBe` []

    it "the live Rke2.hs / Nuke.hs / Native.hs dispatch arms are clean" $ do
      rke2Source <- readFile "src/Prodbox/CLI/Rke2.hs"
      nativeSource <- readFile "src/Prodbox/Native.hs"
      planOptionsHonoredViolations "src/Prodbox/CLI/Rke2.hs" rke2Source `shouldBe` []
      planOptionsHonoredViolations "src/Prodbox/Native.hs" nativeSource `shouldBe` []

    it "covers Rke2Delete and NativeNuke as destructive arms" $
      map fst destructivePlanOptionsArms `shouldBe` ["Rke2Delete", "NativeNuke"]

  describe "Sprint 4.26 nuke step-4 tag sweep is fail-closed" $ do
    it "a non-empty tag sweep aborts nuke (ExitFailure surfaced)" $
      -- abortOrContinue short-circuits on the first ExitFailure: when the
      -- step-4 tag-sweep returns ExitFailure, the bucket-destroy closure
      -- never runs and the failure is returned.
      Nuke.abortOrContinue (ExitFailure 7) (pure ExitSuccess)
        `shouldReturn` ExitFailure 7

    it "a clean tag sweep proceeds to the bucket destroy" $
      Nuke.abortOrContinue ExitSuccess (pure (ExitFailure 5))
        `shouldReturn` ExitFailure 5

  describe "Sprint 4.26 noLiveLongLivedPulumiStacks aws-teardown preflight composition" $ do
    it "the aws teardown default precondition set includes noLiveLongLivedPulumiStacks" $
      -- The operator `aws teardown` default path refuses on a live long-lived
      -- stack via this named precondition. (The per-run refuse-gate was
      -- removed: `cluster delete` is now a pure local uninstall.)
      Preconditions.preconditionLabel (Preconditions.noLiveLongLivedPulumiStacks "/repo")
        `shouldBe` "noLiveLongLivedPulumiStacks"

  describe "DockerConfig: ephemeral docker.io-only pull auth (anonymous registry:2 push)" $ do
    let systemConfig =
          BL8.pack
            "{\"credsStore\":\"desktop\",\"auths\":{\"127.0.0.1:30080\":{\"auth\":\"aGFyYm9y\"},\"https://index.docker.io/v1/\":{\"auth\":\"ZG9ja2Vy\"}}}"
        asObj (Object o) = Just o
        asObj _ = Nothing
        authsOf bytes =
          either (const Nothing) Just (eitherDecode bytes :: Either String Value)
            >>= asObj
            >>= KeyMap.lookup "auths"
            >>= asObj

    it "dockerHubAuthFromConfig keeps ONLY the docker.io entry" $
      fmap KeyMap.keys (DockerConfig.dockerHubAuthFromConfig systemConfig)
        `shouldBe` Just [Key.fromString "https://index.docker.io/v1/"]

    it "dockerHubAuthFromConfig is Nothing when there is no docker.io entry" $
      DockerConfig.dockerHubAuthFromConfig
        (BL8.pack "{\"auths\":{\"127.0.0.1:30080\":{\"auth\":\"aGFyYm9y\"}}}")
        `shouldBe` Nothing

    it "dockerHubAuthFromConfig is Nothing on empty/unparseable input" $ do
      DockerConfig.dockerHubAuthFromConfig "{}" `shouldBe` Nothing
      DockerConfig.dockerHubAuthFromConfig "not json" `shouldBe` Nothing

    it
      "renderEphemeralDockerConfig carries the docker.io auth and NO registry credential, no credsStore"
      $ do
        let rendered =
              DockerConfig.renderEphemeralDockerConfig
                (DockerConfig.dockerHubAuthFromConfig systemConfig)
        case eitherDecode rendered :: Either String Value of
          Right (Object top) -> KeyMap.member "credsStore" top `shouldBe` False
          _ -> expectationFailure "expected a top-level object"
        case authsOf rendered of
          Just auths -> do
            -- Anonymous registry:2 push: no 127.0.0.1:30080 credential is written.
            KeyMap.member (Key.fromString "127.0.0.1:30080") auths `shouldBe` False
            KeyMap.member (Key.fromString "https://index.docker.io/v1/") auths `shouldBe` True
          Nothing -> expectationFailure "expected an auths object"

    it "renderEphemeralDockerConfig with no host login has an empty auths set (anonymous)" $
      fmap KeyMap.keys (authsOf (DockerConfig.renderEphemeralDockerConfig Nothing))
        `shouldBe` Just []

  describe "Sprint 1.52 host-platform DSL" $ do
    it "classifies supported host substrates from OS, architecture, and GPU facts" $ do
      classifyHost "darwin" "arm64" False `shouldBe` Right AppleSilicon
      classifyHost "darwin" "x86_64" False
        `shouldBe` Left "prodbox supports Apple Silicon (arm64) only on macOS"
      classifyHost "linux" "x86_64" False `shouldBe` Right LinuxCpu
      classifyHost "linux" "x86_64" True `shouldBe` Right LinuxGpu
      classifyHost "mingw32" "x86_64" False `shouldBe` Right WindowsCpu
      classifyHost "mingw32" "x86_64" True `shouldBe` Right WindowsGpu
      classifyHost "freebsd" "x86_64" False
        `shouldBe` Left "unsupported host platform: freebsd"

    it "computes the mandatory Linux lift frame for non-Linux cluster tools" $ do
      clusterFrame AppleSilicon `shouldBe` [ViaLimaVM defaultLimaVM]
      clusterFrame WindowsCpu `shouldBe` [ViaWsl2VM defaultWsl2VM]
      clusterFrame WindowsGpu `shouldBe` [ViaWsl2VM defaultWsl2VM]
      clusterFrame LinuxCpu `shouldBe` []
      hostSubstrateNeedsLift AppleSilicon `shouldBe` True
      hostSubstrateNeedsLift LinuxGpu `shouldBe` False

    it "folds lift layers into a concrete self re-invocation" $ do
      foldHostLift (SelfRef "/opt/prodbox/prodbox") [ViaLimaVM defaultLimaVM] ["cluster", "reconcile"]
        `shouldBe` HostDispatch
          "limactl"
          ["shell", "prodbox-ubuntu-2404", "--", "/opt/prodbox/prodbox", "cluster", "reconcile"]

      foldHostLift (SelfRef "/opt/prodbox/prodbox") [ViaWsl2VM defaultWsl2VM] ["cluster", "status"]
        `shouldBe` HostDispatch
          "wsl"
          ["-d", "prodbox-ubuntu-2404", "--", "/opt/prodbox/prodbox", "cluster", "status"]

    it "keeps host tools closed and invocation targets absolute" $ do
      hostToolCommandName Docker `shouldBe` "docker"
      hostToolCommandName Limactl `shouldBe` "limactl"
      fmap absExePath (mkAbsExe "/usr/bin/docker") `shouldBe` Right "/usr/bin/docker"
      mkAbsExe "docker" `shouldBe` Left "not an absolute path: docker"

    it "gates host-frame docker to native Linux substrates" $ do
      DockerConfig.hostFrameDockerSupported LinuxCpu `shouldBe` Right ()
      DockerConfig.hostFrameDockerSupported LinuxGpu `shouldBe` Right ()
      DockerConfig.hostFrameDockerSupported AppleSilicon
        `shouldBe` Left "host-frame docker is unavailable on apple-silicon; descend into the Linux lift frame first"
      DockerConfig.hostFrameDockerSupported WindowsCpu
        `shouldBe` Left "host-frame docker is unavailable on windows-cpu; descend into the Linux lift frame first"

    it "keeps host reconcilers substrate-gated and probe-first" $ do
      HostEnsure.reconcilerApplies HostEnsure.ensureLima AppleSilicon `shouldBe` True
      HostEnsure.reconcilerApplies HostEnsure.ensureLima LinuxCpu `shouldBe` False
      fmap
        (map HostEnsure.hostReconcileStepLabel)
        (HostEnsure.hostReconcilerPlan HostEnsure.ensureLima AppleSilicon)
        `shouldBe` Right ["probe limactl", "install Lima", "verify limactl"]
      HostEnsure.hostReconcilerPlan HostEnsure.ensureWsl2 AppleSilicon
        `shouldBe` Left "wsl2 does not apply to AppleSilicon"

  describe "Sprint 4.37 host-provider VM provisioning and Docker lift frame" $ do
    it "selects the OS-appropriate provider reconciler" $ do
      HostEnsure.hostReconcilerName (HostEnsure.hostProviderReconciler AppleSilicon) `shouldBe` "lima"
      HostEnsure.hostReconcilerName (HostEnsure.hostProviderReconciler WindowsCpu) `shouldBe` "wsl2"
      HostEnsure.hostReconcilerName (HostEnsure.hostProviderReconciler WindowsGpu) `shouldBe` "wsl2"
      HostEnsure.hostReconcilerName (HostEnsure.hostProviderReconciler LinuxCpu) `shouldBe` "incus"
      HostEnsure.hostReconcilerName (HostEnsure.hostProviderReconciler LinuxGpu) `shouldBe` "incus"

    it "makes satisfied providers verified no-ops and missing providers install plans" $ do
      HostEnsure.hostReconcilerDecision
        HostEnsure.ensureLima
        AppleSilicon
        HostEnsure.HostProviderReady
        `shouldBe` Right HostEnsure.HostReconcileNoop
      fmap
        (map HostEnsure.hostReconcileStepLabel)
        ( case HostEnsure.hostReconcilerDecision
            HostEnsure.ensureLima
            AppleSilicon
            HostEnsure.HostProviderMissing of
            Right (HostEnsure.HostReconcileApply steps) -> Right steps
            Right other -> Left ("unexpected decision: " ++ show other)
            Left err -> Left err
        )
        `shouldBe` Right ["probe limactl", "install Lima", "verify limactl"]
      HostEnsure.hostReconcilerDecision
        HostEnsure.ensureWsl2
        WindowsCpu
        (HostEnsure.HostProviderRequiresReboot "restart Windows to finish WSL2")
        `shouldBe` Right (HostEnsure.HostReconcileRebootRequired "restart Windows to finish WSL2")

    it "refuses the wrong provider before any host-provisioning action" $
      HostEnsure.hostReconcilerDecision
        HostEnsure.ensureWsl2
        AppleSilicon
        HostEnsure.HostProviderMissing
        `shouldBe` Left "wsl2 does not apply to AppleSilicon"

    it "dispatches Docker-inward work through the Linux frame for every OS" $ do
      let self = SelfRef "/opt/prodbox/prodbox"
      DockerConfig.dockerLinuxFrameDispatch self LinuxCpu ["cluster", "reconcile"]
        `shouldBe` HostDispatch "/opt/prodbox/prodbox" ["cluster", "reconcile"]
      DockerConfig.dockerLinuxFrameDispatch self AppleSilicon ["cluster", "reconcile"]
        `shouldBe` HostDispatch
          "limactl"
          ["shell", "prodbox-ubuntu-2404", "--", "/opt/prodbox/prodbox", "cluster", "reconcile"]
      DockerConfig.dockerLinuxFrameDispatch self WindowsGpu ["cluster", "reconcile"]
        `shouldBe` HostDispatch
          "wsl"
          ["-d", "prodbox-ubuntu-2404", "--", "/opt/prodbox/prodbox", "cluster", "reconcile"]

  describe "Sprint 1.53 cluster-topology DSL" $ do
    it "declares the default topology as a single-machine rke2 cluster" $ do
      ClusterTopology.clusterType (cluster_topology defaultConfigFile)
        `shouldBe` ClusterTopology.ClusterTypeRke2
      ClusterTopology.validateClusterTopology (cluster_topology defaultConfigFile)
        `shouldBe` Right ()
      ClusterTopology.validateClusterTopology
        (ClusterTopology.mkRke2Topology (ClusterTopology.defaultMachine :| []))
        `shouldBe` Right ()

    it "rejects a worker whose substrate does not match its machine" $
      case ClusterTopology.mkMachineId "linux-a" of
        Left err -> expectationFailure (ClusterTopology.renderTopologyError err)
        Right mid ->
          ClusterTopology.mkMachine
            mid
            ClusterSubstrate.LinuxCpu
            ClusterTopology.ComputeWorker
              { ClusterTopology.worker_substrate = ClusterSubstrate.AppleMetal
              , ClusterTopology.manages_all_local_devices = True
              }
            `shouldBe` Left
              ( ClusterTopology.WorkerSubstrateMismatch
                  ClusterSubstrate.LinuxCpu
                  ClusterSubstrate.AppleMetal
              )

    it "admits EKS only for in-cluster worker substrates" $ do
      fmap ClusterTopology.clusterType (ClusterTopology.mkEksTopology 3 ClusterSubstrate.LinuxCuda)
        `shouldBe` Right ClusterTopology.ClusterTypeEks
      ClusterTopology.mkEksTopology 3 ClusterSubstrate.AppleMetal
        `shouldBe` Left (ClusterTopology.EksHostResidentSubstrate ClusterSubstrate.AppleMetal)

    it "projects placement outcomes by substrate" $ do
      ClusterPlacement.computeWorkerPlacement ClusterSubstrate.LinuxCpu ClusterTopology.defaultMachine
        `shouldBe` ClusterPlacement.PlacementAdmitted
          (ClusterTopology.machine_id ClusterTopology.defaultMachine)
      ClusterPlacement.computeWorkerPlacement ClusterSubstrate.LinuxCuda ClusterTopology.defaultMachine
        `shouldBe` ClusterPlacement.PlacementSubstrateMismatch ClusterSubstrate.LinuxCuda ClusterSubstrate.LinuxCpu

    it "exposes the Dhall cluster-topology contract helpers" $ do
      let expr =
            Text.pack
              ( unlines
                  [ "let Cluster = ./dhall/cluster/Schema.dhall"
                  , ""
                  , "let machine ="
                  , "      { machine_id = \"prodbox-home\""
                  , "      , machine_substrate = Cluster.WorkerSubstrate.LinuxCpu"
                  , "      , compute_worker ="
                  , "          { worker_substrate = Cluster.WorkerSubstrate.LinuxCpu"
                  , "          , manages_all_local_devices = True"
                  , "          }"
                  , "      }"
                  , ""
                  , "in  Cluster.contractOK"
                  , "      (Cluster.ClusterTopology.Rke2 { machines = [ machine ] : List Cluster.Machine })"
                  ]
              )
      Dhall.input Dhall.auto expr `shouldReturn` True

  describe "Sprint 4.38 substrate-typed worker placement and anti-affinity" $ do
    let machine named substrate =
          case ClusterTopology.mkMachineId named of
            Left err -> error (ClusterTopology.renderTopologyError err)
            Right mid ->
              case ClusterTopology.mkMachine
                mid
                substrate
                ClusterTopology.ComputeWorker
                  { ClusterTopology.worker_substrate = substrate
                  , ClusterTopology.manages_all_local_devices = True
                  } of
                Left err -> error (ClusterTopology.renderTopologyError err)
                Right value -> value
        linuxCpu = machine "linux-cpu-a" ClusterSubstrate.LinuxCpu
        linuxCuda = machine "linux-cuda-a" ClusterSubstrate.LinuxCuda

    it "derives one worker per machine with required hostname anti-affinity and maxSurge zero" $
      ClusterPlacement.workerPlacementPlan (ClusterTopology.mkRke2Topology (linuxCpu :| [linuxCuda]))
        `shouldBe` Right
          ( ClusterPlacement.WorkerPlacementPlan
              { ClusterPlacement.workerPlacementClusterType = ClusterTopology.ClusterTypeRke2
              , ClusterPlacement.workerPlacementWorkers =
                  [ ClusterPlacement.WorkerPlacement
                      { ClusterPlacement.workerPlacementMachineId = ClusterTopology.machine_id linuxCpu
                      , ClusterPlacement.workerPlacementSubstrate = ClusterSubstrate.LinuxCpu
                      , ClusterPlacement.workerPlacementAntiAffinity =
                          ClusterPlacement.ComputeWorkerAntiAffinity
                            { ClusterPlacement.workerAntiAffinityTopologyKey = "kubernetes.io/hostname"
                            , ClusterPlacement.workerAntiAffinityMaxWorkersPerMachine = 1
                            , ClusterPlacement.workerRolloutMaxSurge = 0
                            , ClusterPlacement.workerRolloutMaxUnavailable = 1
                            }
                      }
                  , ClusterPlacement.WorkerPlacement
                      { ClusterPlacement.workerPlacementMachineId = ClusterTopology.machine_id linuxCuda
                      , ClusterPlacement.workerPlacementSubstrate = ClusterSubstrate.LinuxCuda
                      , ClusterPlacement.workerPlacementAntiAffinity =
                          ClusterPlacement.computeWorkerAntiAffinity
                      }
                  ]
              }
          )

    it "admits mixed-substrate placement only for rke2" $ do
      ClusterPlacement.ensureMixedSubstrateAdmissible
        ClusterTopology.ClusterTypeRke2
        [ClusterSubstrate.LinuxCpu, ClusterSubstrate.LinuxCuda]
        `shouldBe` Right ()
      ClusterPlacement.ensureMixedSubstrateAdmissible
        ClusterTopology.ClusterTypeKind
        [ClusterSubstrate.LinuxCpu, ClusterSubstrate.LinuxCuda]
        `shouldBe` Left
          ( ClusterPlacement.WorkerPlacementMixedSubstrateRejected
              ClusterTopology.ClusterTypeKind
              [ClusterSubstrate.LinuxCpu, ClusterSubstrate.LinuxCuda]
          )
      ClusterPlacement.ensureMixedSubstrateAdmissible
        ClusterTopology.ClusterTypeEks
        [ClusterSubstrate.LinuxCpu, ClusterSubstrate.LinuxCuda]
        `shouldBe` Left
          ( ClusterPlacement.WorkerPlacementMixedSubstrateRejected
              ClusterTopology.ClusterTypeEks
              [ClusterSubstrate.LinuxCpu, ClusterSubstrate.LinuxCuda]
          )

    it "refuses duplicate machines before rendering anti-affinity" $
      ClusterPlacement.workerPlacementPlan (ClusterTopology.mkRke2Topology (linuxCpu :| [linuxCpu]))
        `shouldBe` Left
          (ClusterPlacement.WorkerPlacementDuplicateMachine (ClusterTopology.machine_id linuxCpu))

    it "refuses a worker whose substrate does not match its machine" $
      case ClusterTopology.mkMachineId "bad-worker" of
        Left err -> expectationFailure (ClusterTopology.renderTopologyError err)
        Right mid ->
          let badMachine =
                ClusterTopology.defaultMachine
                  { ClusterTopology.machine_id = mid
                  , ClusterTopology.machine_substrate = ClusterSubstrate.LinuxCpu
                  , ClusterTopology.compute_worker =
                      ClusterTopology.ComputeWorker
                        { ClusterTopology.worker_substrate = ClusterSubstrate.LinuxCuda
                        , ClusterTopology.manages_all_local_devices = True
                        }
                  }
           in ClusterPlacement.workerPlacementPlan (ClusterTopology.mkRke2Topology (badMachine :| []))
                `shouldBe` Left
                  ( ClusterPlacement.WorkerPlacementWorkerSubstrateMismatch
                      mid
                      ClusterSubstrate.LinuxCuda
                      ClusterSubstrate.LinuxCpu
                  )

  describe "Sprint 1.54 test-topology schema and preflight" $ do
    it "decodes an executable-sibling prodbox.test.dhall through the Settings loader" $
      withSystemTempDirectory "prodbox-test-topology" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        let topologyPath = tmpDir </> "prodbox.test.dhall"
        writeFile topologyPath (testTopologyDhallDocument repoRoot)
        result <- loadTestTopologyAtPath topologyPath
        case result of
          Left err -> expectationFailure err
          Right topology -> do
            topologyFixtures topology `shouldBe` [FixtureAwsAdminForTestSimulation]
            case topologySuites topology of
              [suite] -> do
                suiteName suite `shouldBe` "ha-rke2-aws"
                suiteFixtures suite `shouldBe` [FixtureAwsAdminForTestSimulation]
                case suiteVariants suite of
                  [variant] -> variantFailover variant `shouldBe` Just FailoverLeaderKill
                  _ -> expectationFailure "expected exactly one decoded test variant"
              _ -> expectationFailure "expected exactly one decoded test suite"

    it "rejects a variant whose replica count exceeds its suite budget" $ do
      case topologySuites defaultTestTopology of
        [suite] ->
          case suiteVariants suite of
            [variant] -> do
              let invalid =
                    defaultTestTopology
                      { topologySuites =
                          [ suite
                              { suiteBudget = (suiteBudget suite) {budgetMaxNodes = 1}
                              , suiteVariants = [variant {variantReplicas = 2}]
                              }
                          ]
                      }
              validateTestTopology invalid
                `shouldBe` Left (TestVariantReplicasExceedBudget "unit" 2 1)
            _ -> expectationFailure "defaultTestTopology should have exactly one variant"
        _ -> expectationFailure "defaultTestTopology should have exactly one suite"

    it "exposes the Dhall test-topology contract helpers" $ do
      let expr =
            Text.pack
              ( unlines
                  [ "let TestTopology = ./dhall/TestTopologySchema.dhall"
                  , ""
                  , "in  TestTopology.contractOK"
                  , "      { suites ="
                  , "          [ { name = \"unit\""
                  , "            , variants ="
                  , "                [ { cluster ="
                  , "                      TestTopology.Cluster.ClusterTopology.Rke2"
                  , "                        { machines ="
                  , "                            [ { machine_id = \"prodbox-home\""
                  , "                              , machine_substrate = TestTopology.Cluster.WorkerSubstrate.LinuxCpu"
                  , "                              , compute_worker ="
                  , "                                  { worker_substrate = TestTopology.Cluster.WorkerSubstrate.LinuxCpu"
                  , "                                  , manages_all_local_devices = True"
                  , "                                  }"
                  , "                              }"
                  , "                            ] : List TestTopology.Cluster.Machine"
                  , "                        }"
                  , "                  , replicas = 1"
                  , "                  , failover = None TestTopology.FailoverScenario"
                  , "                  }"
                  , "                ] : List TestTopology.RunVariant"
                  , "            , budget = { max_nodes = 1, wall_clock_seconds = 1800 }"
                  , "            , fixtures = [] : List TestTopology.FixtureId"
                  , "            }"
                  , "          ] : List TestTopology.Suite"
                  , "      , fixtures = [] : List TestTopology.FixtureId"
                  , "      }"
                  ]
              )
      Dhall.input Dhall.auto expr `shouldReturn` True

    it "refuses the test preflight when production prodbox.dhall is present" $ do
      let productionPath = "/tmp/prodbox.dhall"
      testProductionConfigGate productionPath False `shouldBe` TestGateClear
      testProductionConfigGate productionPath True
        `shouldBe` TestGateRefuse (ProductionConfigPresent productionPath)
      testTopologyModeGate productionPath False True `shouldBe` TestGateClear
      testTopologyModeGate productionPath True False `shouldBe` TestGateClear
      testTopologyModeGate productionPath True True
        `shouldBe` TestGateRefuse (ProductionConfigPresent productionPath)
      renderTestRefusal (ProductionConfigPresent productionPath)
        `shouldContain` "production binary-sibling config exists"

    it "checks the preflight through the path-injected filesystem seam" $
      withSystemTempDirectory "prodbox-test-preflight" $ \tmpDir -> do
        let productionPath = tmpDir </> "prodbox.dhall"
            testTopologyPath = tmpDir </> "prodbox.test.dhall"
        testModePreflightAtPath productionPath `shouldReturn` TestGateClear
        testModePreflightAtPaths productionPath testTopologyPath `shouldReturn` TestGateClear
        writeFile productionPath "production config placeholder"
        testModePreflightAtPath productionPath
          `shouldReturn` TestGateRefuse (ProductionConfigPresent productionPath)
        testModePreflightAtPaths productionPath testTopologyPath `shouldReturn` TestGateClear
        writeFile testTopologyPath "test topology placeholder"
        testModePreflightAtPaths productionPath testTopologyPath
          `shouldReturn` TestGateRefuse (ProductionConfigPresent productionPath)

    it "Sprint 5.11 renders the default prodbox.test.dhall from the Haskell topology SSoT" $
      withSystemTempDirectory "prodbox-test-init-render" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        let topologyPath = tmpDir </> "prodbox.test.dhall"
        writeFile
          topologyPath
          (renderTestTopologyDhall (repoRoot </> "dhall" </> "TestTopologySchema.dhall") defaultTestTopology)
        loadTestTopologyAtPath topologyPath `shouldReturn` Right defaultTestTopology

    it "Sprint 5.11 generates per-variant run config with a .test-data manual PV root" $
      withSystemTempDirectory "prodbox-test-topology-config" $ \repoRoot -> do
        let testDataRoot = repoRoot </> ".test-data" </> "unit" </> "variant-1"
            generatedConfig = topologyRunConfig testDataRoot
        manual_pv_host_root (storage generatedConfig) `shouldBe` Text.pack testDataRoot
        renderConfigDhall generatedConfig `shouldContain` testDataRoot
        renderConfigDhall generatedConfig `shouldNotContain` ".data/prodbox"

    it "Sprint 5.11 passes the test data root and coverage flags through the variant environment" $ do
      let environment =
            topologyVariantEnvironment
              "/repo/.test-data/unit/variant-1"
              (CoverageFlags True (Just 80))
              [("PATH", "/bin"), (testManualPvHostRootEnv, "old-root")]
      lookup testManualPvHostRootEnv environment `shouldBe` Just "/repo/.test-data/unit/variant-1"
      lookup "PRODBOX_TEST_COVERAGE" environment `shouldBe` Just "1"
      lookup "PRODBOX_TEST_COVERAGE_FAIL_UNDER" environment `shouldBe` Just "80"
      length (filter ((== testManualPvHostRootEnv) . fst) environment) `shouldBe` 1

    it "Sprint 5.11 repoints the sealed-Vault host audit root under the test data override" $
      withSystemTempDirectory "prodbox-sealed-vault-test-root" $ \repoRoot -> do
        let testRoot = repoRoot </> ".test-data" </> "sealed-vault" </> "variant-1"
            restoreEnv original =
              case original of
                Nothing -> unsetEnv testManualPvHostRootEnv
                Just value -> setEnv testManualPvHostRootEnv value
        original <- lookupEnv testManualPvHostRootEnv
        ( do
            unsetEnv testManualPvHostRootEnv
            sealedVaultHostDiskRoot repoRoot
              `shouldReturn` (repoRoot </> ".data" </> "prodbox" </> "minio" </> "0")
            setEnv testManualPvHostRootEnv testRoot
            sealedVaultHostDiskRoot repoRoot
              `shouldReturn` (testRoot </> "prodbox" </> "minio" </> "0")
          )
          `finally` restoreEnv original

    it "Sprint 5.11 maps authored suite names onto supported test scopes" $ do
      testScopeForTopologySuite "unit" `shouldBe` Right TestUnit
      testScopeForTopologySuite "ha-rke2-aws"
        `shouldBe` Right (TestIntegration IntegrationHaRke2Aws)
      testScopeForTopologySuite "eks-volume-rebind"
        `shouldBe` Right (TestIntegration IntegrationEksVolumeRebind)
      testScopeForTopologySuite "daemon-bootstrap"
        `shouldBe` Right (TestIntegration IntegrationDaemonBootstrap)
      testScopeForTopologySuite "pulsar-broker"
        `shouldBe` Right (TestIntegration IntegrationPulsarBroker)
      testScopeForTopologySuite "unknown"
        `shouldBe` Left "test topology suite `unknown` is not mapped to a supported test scope"

    it "Sprint 5.11 refuses topology commands when a production cluster is running" $
      testProductionClusterGate True
        `shouldBe` TestGateRefuse
          ( ProductionClusterRunning
              ClusterEvidence
                { clusterEvidenceDescription = "RKE2 install marker present"
                }
          )

    it "Sprint 5.11 guardTestDelete admits only generated config, .test-data, and PerRun residue" $
      withSystemTempDirectory "prodbox-test-delete-guard" $ \repoRoot -> do
        let generated = DeleteGeneratedRunConfig (repoRoot </> ".build" </> "prodbox.dhall")
            escapedGenerated = DeleteGeneratedRunConfig (repoRoot </> ".data" </> "prodbox.dhall")
            testData = DeleteThisRunTestData (repoRoot </> ".test-data" </> "unit" </> "variant-1")
            escapedData = DeleteThisRunTestData (repoRoot </> ".test-data" </> ".." </> ".data")
        guardTestDelete repoRoot generated `shouldBe` Right generated
        guardTestDelete repoRoot escapedGenerated
          `shouldBe` Left (TestDeleteOutsideTestData (repoRoot </> ".data" </> "prodbox.dhall"))
        guardTestDelete repoRoot testData `shouldBe` Right testData
        guardTestDelete repoRoot escapedData
          `shouldBe` Left (TestDeleteOutsideTestData (repoRoot </> ".test-data" </> ".." </> ".data"))
        guardTestDelete repoRoot (DeletePerRunResidue "aws-eks")
          `shouldBe` Right (DeletePerRunResidue "aws-eks")
        guardTestDelete repoRoot (DeletePerRunResidue "aws-ses")
          `shouldBe` Left (TestDeleteLongLivedResource "aws-ses")

  describe "Sprint 7.8 operational-resource registry" $ do
    let sampleCreds =
          Credentials
            { access_key_id = "AKIAADMIN"
            , secret_access_key = "admin-secret"
            , session_token = Nothing
            , region = "us-west-2"
            }

    it "operationalIamUserResidueFromExists maps Right True to present" $
      operationalIamUserResidueFromExists (Right True)
        `shouldBe` Residue.ResiduePresent
          Residue.ResidueDetails
            { Residue.residueEvidence = "iam:get-user prodbox"
            , Residue.residueStackName = "operational-iam-user"
            }

    it "operationalIamUserResidueFromExists maps Right False to absent" $
      operationalIamUserResidueFromExists (Right False) `shouldBe` Residue.ResidueAbsent

    it "operationalIamUserResidueFromExists maps Left to unreachable (fail-closed)" $
      operationalIamUserResidueFromExists (Left "boom")
        `shouldBe` Residue.ResidueUnreachable (Residue.ResidueQueryFailed "boom")

    it "operationalAwsConfigResidueFromKey maps a non-empty key to present" $
      operationalAwsConfigResidueFromKey "AKIAOPERATIONAL"
        `shouldBe` Residue.ResiduePresent
          Residue.ResidueDetails
            { Residue.residueEvidence = "aws.access_key_id set in prodbox.dhall"
            , Residue.residueStackName = "operational-aws-config"
            }

    it "operationalAwsConfigResidueFromKey maps an empty key to absent" $
      operationalAwsConfigResidueFromKey "" `shouldBe` Residue.ResidueAbsent

    it "operationalAwsConfigResidueFromKey treats whitespace-only as absent" $
      operationalAwsConfigResidueFromKey "   \t  " `shouldBe` Residue.ResidueAbsent

    it "operationalManagedResources registers the lease role before its trusted user" $
      map ResourceRegistry.resourceName (operationalManagedResources sampleCreds)
        `shouldBe` [ "operational-aws-ses-lease-role"
                   , "operational-iam-user"
                   , "operational-aws-config"
                   ]

    -- Sprint 7.24: the preflight fail-closed-gate refinement.
    it "refine downgrades unreachable aws-config to absent when IAM user is absent" $
      refineAwsConfigResidueAgainstIamUser
        Residue.ResidueAbsent
        (Residue.ResidueUnreachable (Residue.ResidueQueryFailed "vault unreachable"))
        `shouldBe` Residue.ResidueAbsent

    it "refine keeps unreachable aws-config when IAM user is present (fail-closed)" $
      refineAwsConfigResidueAgainstIamUser
        ( Residue.ResiduePresent
            Residue.ResidueDetails
              { Residue.residueEvidence = "iam:get-user prodbox"
              , Residue.residueStackName = "operational-iam-user"
              }
        )
        (Residue.ResidueUnreachable (Residue.ResidueQueryFailed "vault unreachable"))
        `shouldBe` Residue.ResidueUnreachable (Residue.ResidueQueryFailed "vault unreachable")

    it "refine keeps unreachable aws-config when IAM user is unreachable (fail-closed)" $
      refineAwsConfigResidueAgainstIamUser
        (Residue.ResidueUnreachable (Residue.ResidueQueryFailed "iam unreachable"))
        (Residue.ResidueUnreachable (Residue.ResidueQueryFailed "vault unreachable"))
        `shouldBe` Residue.ResidueUnreachable (Residue.ResidueQueryFailed "vault unreachable")

    it "refine leaves a PRESENT aws-config untouched even when the IAM user is absent" $
      refineAwsConfigResidueAgainstIamUser
        Residue.ResidueAbsent
        ( Residue.ResiduePresent
            Residue.ResidueDetails
              { Residue.residueEvidence = "aws.access_key_id set in prodbox.dhall"
              , Residue.residueStackName = "operational-aws-config"
              }
        )
        `shouldBe` Residue.ResiduePresent
          Residue.ResidueDetails
            { Residue.residueEvidence = "aws.access_key_id set in prodbox.dhall"
            , Residue.residueStackName = "operational-aws-config"
            }

    -- Sprint 7.24: the preflight cleared-verification decision core.
    it "clearedDecision: configured creds (Vault reachable) are NOT cleared" $
      operationalCredentialsClearedDecision (Right sampleCreds) (Right False)
        `shouldBe` False

    it "clearedDecision: empty creds (Vault reachable) ARE cleared" $
      operationalCredentialsClearedDecision
        (Right sampleCreds {access_key_id = "", secret_access_key = "", region = ""})
        (Right True)
        `shouldBe` True

    it "clearedDecision: a missing/empty SecretRef error is cleared" $
      operationalCredentialsClearedDecision (Left "operational aws.* is missing") (Right True)
        `shouldBe` True

    it "clearedDecision: Vault down + IAM user absent is cleared (preflight unblock)" $
      operationalCredentialsClearedDecision (Left "vault connection refused") (Right False)
        `shouldBe` True

    it "clearedDecision: Vault down + IAM user present is NOT cleared (fail-closed)" $
      operationalCredentialsClearedDecision (Left "vault connection refused") (Right True)
        `shouldBe` False

    it "clearedDecision: Vault down + IAM user unobservable is NOT cleared (fail-closed)" $
      operationalCredentialsClearedDecision (Left "vault connection refused") (Left "iam unreachable")
        `shouldBe` False

    it "operationalManagedResources entries are all the Operational lifecycle class" $
      all
        ((== ResourceClass.Operational) . ResourceRegistry.resourceClass)
        (operationalManagedResources sampleCreds)
        `shouldBe` True

    it "operationalManagedResources names match the ResourceClass SSoT Operational class" $
      map ResourceRegistry.resourceName (operationalManagedResources sampleCreds)
        `shouldBe` ResourceClass.resourceNamesOfClass ResourceClass.Operational

  describe "Sprint 7.20 teardown-completeness guard (pure residueFromProbe)" $ do
    let cleanIam = IamProbe {iamProbeUserPresent = False, iamProbeAccessKeyIds = []}

    it "all-absent IAM + cleared Vault → complete (Right ())" $
      residueFromProbe cleanIam VaultCredsCleared `shouldBe` Right ()

    it "user-present → residue/fail naming the IAM user" $
      residueFromProbe
        IamProbe {iamProbeUserPresent = True, iamProbeAccessKeyIds = []}
        VaultCredsCleared
        `shouldBe` Left
          ResidueError
            { residueUserLeaked = True
            , residueLeakedKeys = []
            , residueVaultPopulated = False
            }

    it "keys-present → residue/fail naming the leaked keys" $
      residueFromProbe
        IamProbe {iamProbeUserPresent = True, iamProbeAccessKeyIds = ["AKIALEAK"]}
        VaultCredsCleared
        `shouldBe` Left
          ResidueError
            { residueUserLeaked = True
            , residueLeakedKeys = ["AKIALEAK"]
            , residueVaultPopulated = False
            }

    it "Vault-populated → residue/fail naming the Vault cred" $
      residueFromProbe cleanIam VaultCredsPopulated
        `shouldBe` Left
          ResidueError
            { residueUserLeaked = False
            , residueLeakedKeys = []
            , residueVaultPopulated = True
            }

    it "all three leaks at once → residue/fail carrying every leak" $
      residueFromProbe
        IamProbe {iamProbeUserPresent = True, iamProbeAccessKeyIds = ["AKIA1", "AKIA2"]}
        VaultCredsPopulated
        `shouldBe` Left
          ResidueError
            { residueUserLeaked = True
            , residueLeakedKeys = ["AKIA1", "AKIA2"]
            , residueVaultPopulated = True
            }

    it "renderResidueError names the leaked IAM user" $
      let rendered =
            renderResidueError
              ResidueError
                { residueUserLeaked = True
                , residueLeakedKeys = []
                , residueVaultPopulated = False
                }
       in (("`prodbox` IAM user still EXISTS" `isInfixOf` rendered) && ("FAILED" `isInfixOf` rendered))
            `shouldBe` True

    it "renderResidueError names the leaked access keys by id" $
      let rendered =
            renderResidueError
              ResidueError
                { residueUserLeaked = True
                , residueLeakedKeys = ["AKIALEAK"]
                , residueVaultPopulated = False
                }
       in (("access key" `isInfixOf` rendered) && ("AKIALEAK" `isInfixOf` rendered))
            `shouldBe` True

    it "renderResidueError names the populated Vault credential" $
      let rendered =
            renderResidueError
              ResidueError
                { residueUserLeaked = False
                , residueLeakedKeys = []
                , residueVaultPopulated = True
                }
       in ("secret/gateway/gateway/aws" `isInfixOf` rendered) `shouldBe` True

  describe "Sprint 4.17.a canonical cascade phase order" $ do
    it "narration lists drain before per-run destroys (doctrine §5b)" $
      ("drain → per-run destroys" `isInfixOf` cascadeOrderNarration) `shouldBe` True

    it "narration places confirm-MinIO first" $
      ("confirm-MinIO → drain" `isInfixOf` cascadeOrderNarration) `shouldBe` True

    it "narration places uninstall between per-run destroys and sweep" $
      ("per-run destroys → test-EBS reaper → uninstall → sweep" `isInfixOf` cascadeOrderNarration)
        `shouldBe` True

    it "narration places the test-EBS reaper after per-run destroys" $
      ("per-run destroys → test-EBS reaper" `isInfixOf` cascadeOrderNarration) `shouldBe` True

    it "narration does NOT list the pre-Sprint-4.17.a inverted order" $
      ("per-run destroys → drain" `isInfixOf` cascadeOrderNarration) `shouldBe` False

    it "narration is the full canonical cascade phrase" $
      cascadeOrderNarration
        `shouldBe` "rke2 delete --cascade: confirm-MinIO → drain → per-run destroys → test-EBS reaper → uninstall → sweep"

  describe "Sprint 4.17.b cascade substrate inference" $ do
    it "all-absent residue → SubstrateHomeLocal (drain targets local cluster)" $
      inferCascadeSubstrate Residue.ResidueAbsent Residue.ResidueAbsent Residue.ResidueAbsent
        `shouldBe` SubstrateHomeLocal

    it "aws-eks present → SubstrateAws (drain targets EKS)" $
      inferCascadeSubstrate residueFixturePresent Residue.ResidueAbsent Residue.ResidueAbsent
        `shouldBe` SubstrateAws

    it "aws-eks-subzone present → SubstrateAws" $
      inferCascadeSubstrate Residue.ResidueAbsent residueFixturePresent Residue.ResidueAbsent
        `shouldBe` SubstrateAws

    it "aws-test present → SubstrateAws" $
      inferCascadeSubstrate Residue.ResidueAbsent Residue.ResidueAbsent residueFixturePresent
        `shouldBe` SubstrateAws

    it "all-present → SubstrateAws" $
      inferCascadeSubstrate residueFixturePresent residueFixturePresent residueFixturePresent
        `shouldBe` SubstrateAws

    it
      "ResidueUnreachable on every stack → SubstrateHomeLocal (per-run lifecycle class treats unreachable as absent)"
      $ do
        let minioDown = Residue.ResidueUnreachable residueFixtureMinioReason
        inferCascadeSubstrate minioDown minioDown minioDown `shouldBe` SubstrateHomeLocal

  describe "Sprint 4.16 StackOutputs pulumi-shape parsing" $ do
    it "parseListStacksPayload decodes an empty JSON array as no stacks" $
      StackOutputs.parseListStacksPayload "[]" `shouldBe` Right []

    it "parseListStacksPayload decodes a one-stack non-current entry" $ do
      let payload = "[{\"name\":\"aws-eks\",\"current\":false}]"
      StackOutputs.parseListStacksPayload payload
        `shouldBe` Right
          [ StackOutputs.StackListEntry
              { StackOutputs.stackListEntryName = "aws-eks"
              , StackOutputs.stackListEntryCurrent = False
              }
          ]

    it "parseListStacksPayload decodes the current flag when set" $ do
      let payload = "[{\"name\":\"aws-eks\",\"current\":true}]"
      StackOutputs.parseListStacksPayload payload
        `shouldBe` Right
          [ StackOutputs.StackListEntry
              { StackOutputs.stackListEntryName = "aws-eks"
              , StackOutputs.stackListEntryCurrent = True
              }
          ]

    it "parseListStacksPayload ignores entries missing the name field" $ do
      let payload = "[{\"current\":false},{\"name\":\"aws-test\"}]"
      StackOutputs.parseListStacksPayload payload
        `shouldBe` Right
          [ StackOutputs.StackListEntry
              { StackOutputs.stackListEntryName = "aws-test"
              , StackOutputs.stackListEntryCurrent = False
              }
          ]

    it "parseListStacksPayload rejects a non-array root" $
      StackOutputs.parseListStacksPayload "{\"name\":\"aws-eks\"}"
        `shouldBe` Left "pulumi stack ls payload must be a JSON array"

    it "parseListStacksPayload reports JSON-decode failures verbatim" $
      case StackOutputs.parseListStacksPayload "not-json" of
        Left _ -> pure ()
        Right entries -> expectationFailure ("expected decode failure, got " ++ show entries)

    it "stackPresentInList matches the short bare name" $
      StackOutputs.stackPresentInList
        (StackOutputs.StackName "aws-eks")
        [ StackOutputs.StackListEntry
            { StackOutputs.stackListEntryName = "aws-eks"
            , StackOutputs.stackListEntryCurrent = False
            }
        ]
        `shouldBe` True

    it "stackPresentInList matches the qualified organization/project/stack form" $
      StackOutputs.stackPresentInList
        (StackOutputs.StackName "aws-eks")
        [ StackOutputs.StackListEntry
            { StackOutputs.stackListEntryName = "organization/aws-eks/aws-eks"
            , StackOutputs.stackListEntryCurrent = False
            }
        ]
        `shouldBe` True

    it "stackPresentInList returns False when the listing has no matching name" $
      StackOutputs.stackPresentInList
        (StackOutputs.StackName "aws-eks")
        [ StackOutputs.StackListEntry
            { StackOutputs.stackListEntryName = "aws-test"
            , StackOutputs.stackListEntryCurrent = True
            }
        ]
        `shouldBe` False

    it "stackPresentInList does not match when the short name is a prefix substring" $
      StackOutputs.stackPresentInList
        (StackOutputs.StackName "aws-eks")
        [ StackOutputs.StackListEntry
            { StackOutputs.stackListEntryName = "aws-eks-subzone"
            , StackOutputs.stackListEntryCurrent = False
            }
        ]
        `shouldBe` False

    it "parseOutputsPayload decodes an empty object as no outputs" $
      StackOutputs.parseOutputsPayload "{}" `shouldBe` Right Map.empty

    it "parseOutputsPayload decodes string outputs verbatim" $ do
      let payload = "{\"cluster_name\":\"aws-eks-test-cluster\",\"vpc_id\":\"vpc-abc\"}"
      StackOutputs.parseOutputsPayload payload
        `shouldBe` Right
          ( Map.fromList
              [ ("cluster_name", "aws-eks-test-cluster")
              , ("vpc_id", "vpc-abc")
              ]
          )

    it "parseOutputsPayload re-encodes non-string outputs as compact JSON" $ do
      let payload = "{\"subnet_ids\":[\"subnet-a\",\"subnet-b\"]}"
      StackOutputs.parseOutputsPayload payload
        `shouldBe` Right (Map.singleton "subnet_ids" "[\"subnet-a\",\"subnet-b\"]")

    it "parseOutputsPayload decodes null as empty Text" $ do
      let payload = "{\"placeholder\":null}"
      StackOutputs.parseOutputsPayload payload
        `shouldBe` Right (Map.singleton "placeholder" "")

    it "parseOutputsPayload treats a JSON null root as no outputs" $
      StackOutputs.parseOutputsPayload "null" `shouldBe` Right Map.empty

    it "parseOutputsPayload rejects a non-object, non-null root" $
      StackOutputs.parseOutputsPayload "[1,2,3]"
        `shouldBe` Left "pulumi stack output payload must be a JSON object"

    it "renderStackOutputsError discriminates the three failure constructors" $ do
      StackOutputs.renderStackOutputsError (StackOutputs.StackOutputsSubprocessFailed "fork failed")
        `shouldBe` "failed to start `pulumi`: fork failed"
      StackOutputs.renderStackOutputsError (StackOutputs.StackOutputsCommandFailed "denied")
        `shouldBe` "`pulumi` exited non-zero: denied"
      StackOutputs.renderStackOutputsError (StackOutputs.StackOutputsParseFailed "expected value")
        `shouldBe` "failed to parse pulumi JSON output: expected value"

    it "StackName preserves the wrapped Text identity" $
      StackOutputs.unStackName (StackOutputs.StackName "aws-ses") `shouldBe` "aws-ses"

  describe "host-direct residue-read shared fallback (LiveResidue batching)" $ do
    it "isRetryableReadFailure: a degraded-daemon read failure is retry-worthy" $
      LiveResidue.isRetryableReadFailure
        (StackOutputs.StackOutputsCommandFailed "HTTP 503 response: object-store unavailable")
        `shouldBe` True

    it "isRetryableReadFailure: an authoritative bucket-absent message is NOT retry-worthy" $
      LiveResidue.isRetryableReadFailure
        ( StackOutputs.StackOutputsCommandFailed
            "could not list bucket: blob (code=NotFound): NoSuchBucket: The specified bucket does not exist"
        )
        `shouldBe` False

    it "mergeSharedObservation: a non-candidate stack keeps its daemon result unchanged" $ do
      let name = StackOutputs.StackName "aws-eks-test"
          daemonResult = (name, Right CheckpointPresent)
          merged = LiveResidue.mergeSharedObservation [] (Right []) daemonResult
      merged `shouldBe` (name, Right CheckpointPresent)

    it "mergeSharedObservation: a candidate adopts its successful host-direct observation" $ do
      let name = StackOutputs.StackName "aws-eks-test"
          candidates = [(name, "HTTP 503")]
          shared = Right [(name, Right CheckpointPresent)]
          daemonResult = (name, Left (StackOutputs.StackOutputsCommandFailed "HTTP 503"))
      LiveResidue.mergeSharedObservation candidates shared daemonResult
        `shouldBe` (name, Right CheckpointPresent)

    it "mergeSharedObservation: a candidate whose host read also failed stays a combined failure" $ do
      let name = StackOutputs.StackName "aws-eks-test"
          candidates = [(name, "HTTP 503 daemon down")]
          shared = Right [(name, Left "MinIO port-forward failed")]
          daemonResult = (name, Left (StackOutputs.StackOutputsCommandFailed "HTTP 503 daemon down"))
      case LiveResidue.mergeSharedObservation candidates shared daemonResult of
        (n, Left (StackOutputs.StackOutputsCommandFailed detail)) -> do
          n `shouldBe` name
          detail `shouldContain` "HTTP 503 daemon down"
          detail `shouldContain` "MinIO port-forward failed"
        other -> expectationFailure ("expected combined StackOutputsCommandFailed, got " ++ show other)

    it "mergeSharedObservation: an unavailable shared port-forward keeps every candidate fail-closed" $ do
      let name = StackOutputs.StackName "aws-eks-test"
          candidates = [(name, "HTTP 503")]
          shared = Left "host-direct Pulumi fallback: vault sealed"
          daemonResult = (name, Left (StackOutputs.StackOutputsCommandFailed "HTTP 503"))
      case LiveResidue.mergeSharedObservation candidates shared daemonResult of
        (_, Left (StackOutputs.StackOutputsCommandFailed detail)) ->
          detail `shouldContain` "vault sealed"
        other -> expectationFailure ("expected StackOutputsCommandFailed, got " ++ show other)

  describe "Sprint 4.16 LiveResidue error mapping + listing translation" $ do
    it "residueReasonFromMinioError maps subprocess failure to MinIO unreachable" $
      LiveResidue.residueReasonFromMinioError (StackOutputs.StackOutputsSubprocessFailed "fork")
        `shouldBe` Residue.ResidueBackendMinioUnreachable "fork"

    it "residueReasonFromMinioError maps command failure to MinIO unreachable" $
      LiveResidue.residueReasonFromMinioError (StackOutputs.StackOutputsCommandFailed "denied")
        `shouldBe` Residue.ResidueBackendMinioUnreachable "denied"

    it "residueReasonFromMinioError maps parse failure to ResidueQueryFailed" $
      LiveResidue.residueReasonFromMinioError (StackOutputs.StackOutputsParseFailed "bad json")
        `shouldBe` Residue.ResidueQueryFailed "bad json"

    it "residueReasonFromS3Error maps subprocess failure to S3 unreachable" $
      LiveResidue.residueReasonFromS3Error (StackOutputs.StackOutputsSubprocessFailed "fork")
        `shouldBe` Residue.ResidueBackendS3Unreachable "fork"

    it "residueReasonFromS3Error maps command failure to S3 unreachable" $
      LiveResidue.residueReasonFromS3Error (StackOutputs.StackOutputsCommandFailed "expired")
        `shouldBe` Residue.ResidueBackendS3Unreachable "expired"

    it "residueReasonFromS3Error maps parse failure to ResidueQueryFailed" $
      LiveResidue.residueReasonFromS3Error (StackOutputs.StackOutputsParseFailed "bad json")
        `shouldBe` Residue.ResidueQueryFailed "bad json"

    it "residueStatusFromListing returns ResidueAbsent when the stack is not in the listing" $
      LiveResidue.residueStatusFromListing
        "aws-eks-test"
        LiveResidue.residueReasonFromMinioError
        (Right [])
        `shouldBe` Residue.ResidueAbsent

    it "residueStatusFromListing returns ResiduePresent when the stack name matches" $
      let entries =
            [ StackOutputs.StackListEntry
                { StackOutputs.stackListEntryName = "aws-eks-test"
                , StackOutputs.stackListEntryCurrent = True
                }
            ]
          status =
            LiveResidue.residueStatusFromListing
              "aws-eks-test"
              LiveResidue.residueReasonFromMinioError
              (Right entries)
       in case status of
            Residue.ResiduePresent details -> do
              Residue.residueStackName details `shouldBe` "aws-eks-test"
              Residue.residueEvidence details `shouldContain` "Pulumi backend"
            other ->
              expectationFailure
                ("expected ResiduePresent, got: " ++ show other)

    it "residueStatusFromListing matches the qualified org/project/stack form (suffix-aware)" $
      let entries =
            [ StackOutputs.StackListEntry
                { StackOutputs.stackListEntryName = "organization/prodbox-aws-eks-test/aws-eks-test"
                , StackOutputs.stackListEntryCurrent = False
                }
            ]
          status =
            LiveResidue.residueStatusFromListing
              "aws-eks-test"
              LiveResidue.residueReasonFromMinioError
              (Right entries)
       in case status of
            Residue.ResiduePresent _ -> pure ()
            other ->
              expectationFailure
                ("expected ResiduePresent for qualified form, got: " ++ show other)

    it "residueStatusFromListing returns ResidueUnreachable when the backend errors" $
      let err = StackOutputs.StackOutputsCommandFailed "connection refused"
          status =
            LiveResidue.residueStatusFromListing
              "aws-eks-test"
              LiveResidue.residueReasonFromMinioError
              (Left err)
       in status
            `shouldBe` Residue.ResidueUnreachable
              (Residue.ResidueBackendMinioUnreachable "connection refused")

    it "isMissingStateBackendBucketMessage matches Pulumi S3 NoSuchBucket output" $
      LiveResidue.isMissingStateBackendBucketMessage
        "error listing stacks: could not list bucket: blob (code=NotFound): NoSuchBucket:"
        `shouldBe` True

    it "residueStatusFromS3Listing treats a missing long-lived state bucket as absent" $
      let err =
            StackOutputs.StackOutputsCommandFailed
              "error listing stacks: could not list bucket: blob (code=NotFound): NoSuchBucket:"
          status = LiveResidue.residueStatusFromS3Listing "aws-ses" (Left err)
       in status `shouldBe` Residue.ResidueAbsent

    it "residueStatusFromS3Listing keeps non-missing S3 failures fail-closed" $
      let err = StackOutputs.StackOutputsCommandFailed "AccessDenied: denied"
          status = LiveResidue.residueStatusFromS3Listing "aws-ses" (Left err)
       in status
            `shouldBe` Residue.ResidueUnreachable
              (Residue.ResidueBackendS3Unreachable "AccessDenied: denied")

    it "residueStatusFromMinioListing treats a never-created per-run state bucket as absent" $
      -- A 404 NoSuchBucket from the in-cluster MinIO backend means no
      -- per-run stacks were ever provisioned — Absent (nothing to destroy),
      -- NOT Unreachable. (Was the bug that wrongly refused `cluster delete`
      -- on a local cluster.)
      let err =
            StackOutputs.StackOutputsCommandFailed
              "error listing stacks: could not list bucket: blob (code=NotFound): NoSuchBucket: The specified bucket does not exist"
          status = LiveResidue.residueStatusFromMinioListing "aws-eks-test" (Left err)
       in status `shouldBe` Residue.ResidueAbsent

    it "residueStatusFromMinioListing keeps a genuinely-down MinIO backend fail-closed" $
      let err = StackOutputs.StackOutputsCommandFailed "dial tcp 127.0.0.1: connection refused"
          status = LiveResidue.residueStatusFromMinioListing "aws-eks-test" (Left err)
       in status
            `shouldBe` Residue.ResidueUnreachable
              (Residue.ResidueBackendMinioUnreachable "dial tcp 127.0.0.1: connection refused")

    it "Sprint 4.33 gates MinIO residue listings behind sealed Vault readiness" $ do
      let present =
            [ StackOutputs.StackListEntry
                { StackOutputs.stackListEntryName = "aws-eks-test"
                , StackOutputs.stackListEntryCurrent = True
                }
            ]
          sealedPresent =
            LiveResidue.residueStatusFromMinioListingWithVaultGate
              VaultGateBlockSealed
              "aws-eks-test"
              (Right present)
          sealedAbsent =
            LiveResidue.residueStatusFromMinioListingWithVaultGate
              VaultGateBlockSealed
              "aws-eks-test"
              (Right [])
          rendered = Residue.renderResidueStatus sealedPresent
      sealedPresent `shouldBe` sealedAbsent
      rendered `shouldContain` "vault_status=sealed"
      rendered `shouldContain` "result=unobservable"
      rendered `shouldNotContain` "aws-eks"
      rendered `shouldNotContain` "pulumi stack ls"
      LiveResidue.residueStatusFromMinioListingWithVaultGate
        VaultGateAllow
        "aws-eks-test"
        (Right present)
        `shouldSatisfy` Residue.isResiduePresent

    it "Sprint 4.33 gates object listings without leaking real object counts" $ do
      let sealedMany =
            LiveResidue.residueStatusFromObjectListingWithVaultGate
              VaultGateBlockSealed
              "public-edge-tls"
              (Right ["a", "b", "c"])
          sealedEmpty =
            LiveResidue.residueStatusFromObjectListingWithVaultGate
              VaultGateBlockSealed
              "public-edge-tls"
              (Right [])
          rendered = Residue.renderResidueStatus sealedMany
      sealedMany `shouldBe` sealedEmpty
      rendered `shouldContain` "vault_status=sealed"
      rendered `shouldNotContain` "public-edge-tls"
      rendered `shouldNotContain` "3"

    it "canonical stack-name constants match the production names" $ do
      LiveResidue.awsEksTestStackName `shouldBe` "aws-eks-test"
      LiveResidue.awsEksSubzoneStackName `shouldBe` "aws-eks-subzone"
      LiveResidue.awsTestStackName `shouldBe` "aws-test"
      LiveResidue.awsSesStackName `shouldBe` "aws-ses"

  describe "Sprint 7.21 per-run checkpoint observability (corrupt/empty/absent robustness)" $ do
    it "classifyCheckpointBytes: absent object (Nothing) is CheckpointAbsent" $
      classifyCheckpointBytes Nothing `shouldBe` CheckpointAbsent

    it "classifyCheckpointBytes: a zero-byte object is CheckpointEmpty" $
      classifyCheckpointBytes (Just "") `shouldBe` CheckpointEmpty

    it "classifyCheckpointBytes: an all-whitespace object is CheckpointEmpty" $
      classifyCheckpointBytes (Just "  \n\t ") `shouldBe` CheckpointEmpty

    it "classifyCheckpointBytes: a non-empty-unparseable blob is CheckpointCorrupt" $
      case classifyCheckpointBytes (Just "{not valid json") of
        CheckpointCorrupt _ -> pure ()
        other -> expectationFailure ("expected CheckpointCorrupt, got " ++ show other)

    it "classifyCheckpointBytes: a valid JSON checkpoint is CheckpointPresent" $
      classifyCheckpointBytes (Just "{\"version\":3,\"checkpoint\":{}}")
        `shouldBe` CheckpointPresent

    it "residueStatusFromCheckpointObservability: absent → skip (ResidueAbsent)" $
      LiveResidue.residueStatusFromCheckpointObservability "aws-eks-test" CheckpointAbsent
        `shouldBe` Residue.ResidueAbsent

    it "residueStatusFromCheckpointObservability: empty → skip (ResidueAbsent)" $
      LiveResidue.residueStatusFromCheckpointObservability "aws-eks-test" CheckpointEmpty
        `shouldBe` Residue.ResidueAbsent

    it "residueStatusFromCheckpointObservability: present → destroy (ResiduePresent)" $
      LiveResidue.residueStatusFromCheckpointObservability "aws-eks-test" CheckpointPresent
        `shouldSatisfy` Residue.isResiduePresent

    it "residueStatusFromCheckpointObservability: corrupt → refuse (ResidueUnreachable naming stack)" $ do
      let status =
            LiveResidue.residueStatusFromCheckpointObservability
              "aws-eks-test"
              (CheckpointCorrupt "unexpected end of JSON input")
          rendered = Residue.renderResidueStatus status
      status `shouldSatisfy` Residue.isResidueUnreachable
      -- The refusal names the stack and the corruption, so the operator
      -- knows which stack to resolve and that it is a corrupt checkpoint.
      rendered `shouldContain` "corrupt"
      rendered `shouldContain` "aws-eks-test"
      rendered `shouldContain` "unexpected end of JSON input"

    it "residueStatusFromCheckpointObservabilityResult: unreadable MinIO backend → refuse (fail-closed)" $
      -- The `minio` root credential is absent / the port-forward died: a
      -- backend read failure that is NOT a never-created bucket must
      -- fail closed, never silently skip a possibly-live stack.
      let err =
            StackOutputs.StackOutputsCommandFailed
              "kubectl get secret failed for rootUser: secrets \"minio\" not found"
          status = LiveResidue.residueStatusFromCheckpointObservabilityResult "aws-eks-test" (Left err)
       in status `shouldSatisfy` Residue.isResidueUnreachable

    -- Sprint 7.22: the per-run destroy-INVOCATION gate. Pure mapping from a
    -- freshly observed residue status to skip / proceed / refuse, consulted
    -- BEFORE the destroy touches `pulumi stack output` / `pulumi destroy` or
    -- the in-cluster `minio` secret.
    it "perRunDestroyDecisionFromStatus: absent → skip (the home-substrate case)" $
      case LiveResidue.perRunDestroyDecisionFromStatus
        "aws-eks-test"
        "prodbox aws stack eks prune-corrupt-checkpoint --yes"
        Residue.ResidueAbsent of
        LiveResidue.PerRunDestroySkip message -> message `shouldContain` "aws-eks-test"
        other -> expectationFailure ("expected skip, got " ++ show other)

    it "perRunDestroyDecisionFromStatus: present → proceed with the real destroy" $
      LiveResidue.perRunDestroyDecisionFromStatus
        "aws-eks-test"
        "prodbox aws stack eks prune-corrupt-checkpoint --yes"
        (Residue.ResiduePresent (Residue.ResidueDetails "checkpoint decodes" "aws-eks-test"))
        `shouldBe` LiveResidue.PerRunDestroyProceed

    it "perRunDestroyDecisionFromStatus: unreachable (corrupt) → refuse naming the prune recovery" $
      case LiveResidue.perRunDestroyDecisionFromStatus
        "aws-eks-test"
        "prodbox aws stack eks prune-corrupt-checkpoint --yes"
        ( Residue.ResidueUnreachable
            (Residue.ResidueQueryFailed "corrupt (non-empty, unparseable) checkpoint")
        ) of
        LiveResidue.PerRunDestroyRefuse message -> do
          message `shouldContain` "aws-eks-test"
          message `shouldContain` "fail-closed"
          message `shouldContain` "prodbox aws stack eks prune-corrupt-checkpoint --yes"
        other -> expectationFailure ("expected refuse, got " ++ show other)

    it
      "residueStatusFromCheckpointObservabilityResult: never-created state bucket → skip (ResidueAbsent)"
      $
      -- A 404 NoSuchBucket means no per-run stacks were ever provisioned
      -- (the home-substrate case): Absent, not Unreachable.
      let err =
            StackOutputs.StackOutputsCommandFailed
              "error listing stacks: could not list bucket: blob (code=NotFound): NoSuchBucket: The specified bucket does not exist"
          status = LiveResidue.residueStatusFromCheckpointObservabilityResult "aws-eks-test" (Left err)
       in status `shouldBe` Residue.ResidueAbsent

    it "renderCheckpointObservability names the corruption detail" $ do
      renderCheckpointObservability CheckpointAbsent `shouldBe` "absent"
      renderCheckpointObservability CheckpointEmpty `shouldContain` "zero-length"
      renderCheckpointObservability (CheckpointCorrupt "boom") `shouldContain` "boom"
      renderCheckpointObservability CheckpointPresent `shouldBe` "present"

    it
      "observeStackCheckpointWith: empty loaded bytes classify as CheckpointEmpty without hydrating scratch"
      $ do
        let stackRef = PulumiStackRef "prodbox-aws-eks-test" "aws-eks-test"
            hooks = observabilityHooks (pure (Right (Just "")))
        result <- observeStackCheckpointWith hooks stackRef
        result `shouldBe` Right CheckpointEmpty

    it "observeStackCheckpointWith: a non-empty-unparseable blob classifies as CheckpointCorrupt" $ do
      let stackRef = PulumiStackRef "prodbox-aws-eks-test" "aws-eks-test"
          hooks = observabilityHooks (pure (Right (Just "garbage{")))
      result <- observeStackCheckpointWith hooks stackRef
      case result of
        Right (CheckpointCorrupt _) -> pure ()
        other -> expectationFailure ("expected Right (CheckpointCorrupt _), got " ++ show other)

    it "observeStackCheckpointWith: an absent object classifies as CheckpointAbsent" $ do
      let stackRef = PulumiStackRef "prodbox-aws-eks-test" "aws-eks-test"
          hooks = observabilityHooks (pure (Right Nothing))
      result <- observeStackCheckpointWith hooks stackRef
      result `shouldBe` Right CheckpointAbsent

    it "observeStackCheckpointWith: a backend load failure surfaces as EncryptedBackendLoadFailed" $ do
      let stackRef = PulumiStackRef "prodbox-aws-eks-test" "aws-eks-test"
          hooks = observabilityHooks (pure (Left "connection refused"))
      result <- observeStackCheckpointWith hooks stackRef
      result `shouldBe` Left (EncryptedBackendLoadFailed "connection refused")

  describe "host-direct object-store fallback (daemon-first, host-direct on daemon failure)" $ do
    let stackRef = PulumiStackRef "prodbox-aws-eks-test" "aws-eks-test"
        validCheckpoint = "{\"version\":3,\"checkpoint\":{}}" :: BS.ByteString

    it "withDaemonFirstFallback: daemon success short-circuits; host op is NOT called" $ do
      hostCalled <- newIORef False
      let daemonOp = pure (Right (Just validCheckpoint))
          hostOp = writeIORef hostCalled True >> pure (Right (Just ("host-bytes" :: BS.ByteString)))
      result <- withDaemonFirstFallback "load" daemonOp hostOp
      result `shouldBe` Right (Just validCheckpoint)
      readIORef hostCalled `shouldReturn` False

    it "withDaemonFirstFallback: daemon Right Nothing (absent) is an ANSWER; host op is NOT called" $ do
      hostCalled <- newIORef False
      let daemonOp = pure (Right Nothing) :: IO (Either String (Maybe BS.ByteString))
          hostOp = writeIORef hostCalled True >> pure (Right (Just "host-bytes"))
      result <- withDaemonFirstFallback "load" daemonOp hostOp
      result `shouldBe` Right Nothing
      readIORef hostCalled `shouldReturn` False

    it "withDaemonFirstFallback: daemon failure falls back to a successful host op" $ do
      hostCalled <- newIORef False
      let daemonOp = pure (Left "HTTP 503 response: object-store unavailable")
          hostOp = writeIORef hostCalled True >> pure (Right (Just validCheckpoint))
      result <- withDaemonFirstFallback "load" daemonOp hostOp
      result `shouldBe` Right (Just validCheckpoint)
      readIORef hostCalled `shouldReturn` True

    it "withDaemonFirstFallback: both failing yields a combined error naming both" $ do
      let daemonOp = pure (Left "HTTP 503 daemon down") :: IO (Either String (Maybe BS.ByteString))
          hostOp = pure (Left "port-forward to MinIO failed")
      result <- withDaemonFirstFallback "load" daemonOp hostOp
      case result of
        Left detail -> do
          detail `shouldContain` "HTTP 503 daemon down"
          detail `shouldContain` "port-forward to MinIO failed"
        Right _ -> expectationFailure "expected Left when both daemon and host fail"

    it "composite observe: daemon 503, host-direct present -> CheckpointPresent" $ do
      let hooks =
            observabilityHooks
              (withDaemonFirstFallback "load" (pure (Left "HTTP 503")) (pure (Right (Just validCheckpoint))))
      result <- observeStackCheckpointWith hooks stackRef
      result `shouldBe` Right CheckpointPresent

    it "composite observe: daemon 503, host-direct absent -> CheckpointAbsent" $ do
      let hooks =
            observabilityHooks
              (withDaemonFirstFallback "load" (pure (Left "HTTP 503")) (pure (Right Nothing)))
      result <- observeStackCheckpointWith hooks stackRef
      result `shouldBe` Right CheckpointAbsent

    it "composite observe: daemon 503, host-direct corrupt -> CheckpointCorrupt" $ do
      let hooks =
            observabilityHooks
              (withDaemonFirstFallback "load" (pure (Left "HTTP 503")) (pure (Right (Just "garbage{"))))
      result <- observeStackCheckpointWith hooks stackRef
      case result of
        Right (CheckpointCorrupt _) -> pure ()
        other -> expectationFailure ("expected Right (CheckpointCorrupt _), got " ++ show other)

    it "composite observe: daemon 503 + host failure -> EncryptedBackendLoadFailed naming both" $ do
      let hooks =
            observabilityHooks
              ( withDaemonFirstFallback
                  "load"
                  (pure (Left "HTTP 503 daemon down"))
                  (pure (Left "MinIO port-forward failed"))
              )
      result <- observeStackCheckpointWith hooks stackRef
      case result of
        Left (EncryptedBackendLoadFailed detail) -> do
          detail `shouldContain` "HTTP 503 daemon down"
          detail `shouldContain` "MinIO port-forward failed"
        other -> expectationFailure ("expected EncryptedBackendLoadFailed, got " ++ show other)

    it "composite observe: healthy daemon classifies present and never touches host-direct" $ do
      let hooks =
            observabilityHooks
              ( withDaemonFirstFallback
                  "load"
                  (pure (Right (Just validCheckpoint)))
                  (error "host-direct must not be called")
              )
      result <- observeStackCheckpointWith hooks stackRef
      result `shouldBe` Right CheckpointPresent

  describe "Sprint 4.18 live-output parsers for per-run AWS stacks" $ do
    it "parseAwsTestNodesFromOutputs decodes the three-node Pulumi outputs" $ do
      let nodesJson =
            "[ {\"name\":\"aws-test-node-0\""
              ++ ", \"availability_zone\":\"us-east-1a\""
              ++ ", \"instance_id\":\"i-aaaa\""
              ++ ", \"private_ip\":\"10.0.0.10\""
              ++ ", \"public_ip\":\"203.0.113.10\"}"
              ++ ", {\"name\":\"aws-test-node-1\""
              ++ ", \"availability_zone\":\"us-east-1b\""
              ++ ", \"instance_id\":\"i-bbbb\""
              ++ ", \"private_ip\":\"10.0.0.11\""
              ++ ", \"public_ip\":\"203.0.113.11\"}"
              ++ ", {\"name\":\"aws-test-node-2\""
              ++ ", \"availability_zone\":\"us-east-1c\""
              ++ ", \"instance_id\":\"i-cccc\""
              ++ ", \"private_ip\":\"10.0.0.12\""
              ++ ", \"public_ip\":\"203.0.113.12\"} ]"
          outputs = Map.fromList [("nodes", Text.pack nodesJson)]
      case AwsTest.parseAwsTestNodesFromOutputs outputs of
        Left err -> expectationFailure ("expected Right, got Left: " ++ err)
        Right nodes -> do
          length nodes `shouldBe` 3
          map AwsTest.testNodeName nodes
            `shouldBe` ["aws-test-node-0", "aws-test-node-1", "aws-test-node-2"]
          map AwsTest.testNodePublicIp nodes
            `shouldBe` ["203.0.113.10", "203.0.113.11", "203.0.113.12"]

    it "parseAwsTestNodesFromOutputs fails when the 'nodes' field is missing" $
      case AwsTest.parseAwsTestNodesFromOutputs Map.empty of
        Left err -> err `shouldContain` "missing required field 'nodes'"
        Right _ -> expectationFailure "expected Left for missing 'nodes' field"

    it "parseAwsTestNodesFromOutputs fails when the 'nodes' field is not JSON" $ do
      let outputs = Map.fromList [("nodes", Text.pack "not-json")]
      case AwsTest.parseAwsTestNodesFromOutputs outputs of
        Left err -> err `shouldContain` "is not valid JSON"
        Right _ -> expectationFailure "expected Left for non-JSON 'nodes'"

    it "parseAwsTestNodesFromOutputs fails when 'nodes' is not a JSON array" $ do
      let outputs = Map.fromList [("nodes", Text.pack "{\"shape\":\"object\"}")]
      case AwsTest.parseAwsTestNodesFromOutputs outputs of
        Left err -> err `shouldContain` "must be a JSON array"
        Right _ -> expectationFailure "expected Left for non-array 'nodes'"

    it "parseAwsEksTestStackFromOutputs builds an AwsEksTestStackSnapshot from the live outputs map" $ do
      let outputs =
            Map.fromList
              [ ("backend_bucket", "prodbox-state")
              , ("cluster_name", "prodbox-aws-eks-test-cluster")
              , ("cluster_role_name", "prodbox-aws-eks-test-cluster-role")
              , ("node_group_name", "prodbox-aws-eks-test-nodes")
              , ("node_role_name", "prodbox-aws-eks-test-node-role")
              , ("vpc_id", "vpc-123")
              , ("subnet_ids", Text.pack "[\"subnet-aaa\",\"subnet-bbb\"]")
              , ("cluster_security_group_id", "sg-1234")
              , ("cluster_oidc_issuer", "https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE")
              ,
                ( "oidc_provider_arn"
                , "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE"
                )
              , ("aws_lb_controller_policy_arn", "arn:aws:iam::123:policy/lbc")
              , ("aws_lb_controller_role_arn", "arn:aws:iam::123:role/lbc")
              , ("aws_lb_controller_role_name", "prodbox-lbc-role")
              , ("retained_ebs_availability_zone", "us-east-1a")
              ]
      case AwsEks.parseAwsEksTestStackFromOutputs outputs of
        Left err -> expectationFailure ("expected Right, got Left: " ++ err)
        Right snapshot -> do
          AwsEks.eksSnapshotStackName snapshot `shouldBe` "aws-eks-test"
          AwsEks.eksSnapshotClusterName snapshot `shouldBe` "prodbox-aws-eks-test-cluster"
          AwsEks.eksSnapshotVpcId snapshot `shouldBe` "vpc-123"
          AwsEks.eksSnapshotSubnetIds snapshot `shouldBe` ["subnet-aaa", "subnet-bbb"]
          AwsEks.eksSnapshotAwsLbControllerRoleArn snapshot
            `shouldBe` "arn:aws:iam::123:role/lbc"
          AwsEks.eksSnapshotRetainedEbsAvailabilityZone snapshot `shouldBe` "us-east-1a"

    it "parseAwsEksTestStackFromOutputs fails when a required scalar is missing" $ do
      let outputs = Map.fromList [("cluster_name", "x")]
      case AwsEks.parseAwsEksTestStackFromOutputs outputs of
        Left err -> err `shouldContain` "missing required field"
        Right _ -> expectationFailure "expected Left for missing required field"

    it "parseAwsEksTestStackFromOutputs fails when subnet_ids is not a JSON array" $ do
      let outputs =
            Map.fromList
              [ ("backend_bucket", "bucket")
              , ("cluster_name", "cluster")
              , ("cluster_role_name", "role")
              , ("node_group_name", "nodes")
              , ("node_role_name", "node-role")
              , ("vpc_id", "vpc")
              , ("subnet_ids", "not-an-array")
              , ("cluster_security_group_id", "sg")
              , ("cluster_oidc_issuer", "oidc")
              , ("oidc_provider_arn", "arn")
              , ("aws_lb_controller_policy_arn", "policy")
              , ("aws_lb_controller_role_arn", "role-arn")
              , ("aws_lb_controller_role_name", "role-name")
              , ("retained_ebs_availability_zone", "us-east-1a")
              ]
      case AwsEks.parseAwsEksTestStackFromOutputs outputs of
        Left err -> err `shouldContain` "subnet_ids"
        Right _ -> expectationFailure "expected Left for malformed subnet_ids"

  describe "Sprint 4.17 postflight tag sweep wiring" $ do
    it "renderTagSweepRefusal includes the cluster-tagged resource ARN and matched tag" $ do
      let resources =
            [ TagSweep.TaggedResource
                { TagSweep.taggedResourceArn = "arn:aws:ec2:us-east-1:123:vpc/vpc-abc"
                , TagSweep.taggedResourceMatchedTagKey = "kubernetes.io/cluster/aws-eks-test-cluster"
                , TagSweep.taggedResourceMatchedTagValue = "owned"
                }
            ]
          rendered = TagSweep.renderTagSweepRefusal resources
      rendered
        `shouldContain` "arn:aws:ec2:us-east-1:123:vpc/vpc-abc"
      rendered
        `shouldContain` "kubernetes.io/cluster/aws-eks-test-cluster"
      rendered `shouldContain` "Postflight tag sweep refused"

    it "renderTagSweepRefusal renders each resource on its own bullet line" $ do
      let resources =
            [ TagSweep.TaggedResource
                { TagSweep.taggedResourceArn = "arn:aws:s3:::prodbox-leftover"
                , TagSweep.taggedResourceMatchedTagKey = "prodbox.io/managed-by"
                , TagSweep.taggedResourceMatchedTagValue = "prodbox"
                }
            , TagSweep.TaggedResource
                { TagSweep.taggedResourceArn = "arn:aws:iam::123:role/prodbox-residual"
                , TagSweep.taggedResourceMatchedTagKey = "prodbox.io/managed-by"
                , TagSweep.taggedResourceMatchedTagValue = "prodbox"
                }
            ]
          rendered = TagSweep.renderTagSweepRefusal resources
          bulletLines = filter (\line -> take 4 line == "  - ") (lines rendered)
      length bulletLines `shouldBe` 2

  describe "Sprint 7.26 cascade tag sweep carves out retained long-lived shared infra" $ do
    it "carves out the long-lived pulumi_state_backend bucket (role=long-lived-pulumi-state)" $ do
      let stateBucket =
            [ TagSweep.TaggedResource
                "arn:aws:s3:::prodbox-pulumi-state-long-lived"
                "prodbox.io/managed-by"
                "prodbox"
            , TagSweep.TaggedResource
                "arn:aws:s3:::prodbox-pulumi-state-long-lived"
                "prodbox.io/role"
                "long-lived-pulumi-state"
            ]
          (retained, escaped) = TagSweep.partitionRetainedLongLived stateBucket
      escaped `shouldBe` []
      length retained `shouldBe` 2

    it "carves out aws-ses cross-substrate shared resources (substrate=shared)" $ do
      let sesCapture =
            [ TagSweep.TaggedResource "arn:aws:s3:::prodbox-ses-capture" "prodbox.io/managed-by" "prodbox"
            , TagSweep.TaggedResource "arn:aws:s3:::prodbox-ses-capture" "prodbox.io/substrate" "shared"
            ]
      snd (TagSweep.partitionRetainedLongLived sesCapture) `shouldBe` []

    it "still treats a genuine per-run/cluster resource (no long-lived marker) as escaped" $ do
      let escapee =
            [ TagSweep.TaggedResource
                "arn:aws:ec2:us-east-1:123:vpc/vpc-xyz"
                "kubernetes.io/cluster/aws-eks-test-cluster"
                "owned"
            ]
          (retained, escaped) = TagSweep.partitionRetainedLongLived escapee
      retained `shouldBe` []
      escaped `shouldBe` escapee

    it "refuses ONLY on the escapee in a mixed result (retained bucket + stray sharing managed-by)" $ do
      let mixed =
            [ TagSweep.TaggedResource
                "arn:aws:s3:::prodbox-pulumi-state-long-lived"
                "prodbox.io/role"
                "long-lived-pulumi-state"
            , TagSweep.TaggedResource
                "arn:aws:s3:::prodbox-pulumi-state-long-lived"
                "prodbox.io/managed-by"
                "prodbox"
            , TagSweep.TaggedResource "arn:aws:iam::123:role/prodbox-stray" "prodbox.io/managed-by" "prodbox"
            ]
          (_, escaped) = TagSweep.partitionRetainedLongLived mixed
          rendered = TagSweep.renderTagSweepRefusal escaped
      map TagSweep.taggedResourceArn escaped `shouldBe` ["arn:aws:iam::123:role/prodbox-stray"]
      rendered `shouldContain` "prodbox-stray"
      rendered `shouldNotContain` "pulumi-state-long-lived"

    it "renderTagSweepRefusal still emits the header when the list is empty" $ do
      let rendered = TagSweep.renderTagSweepRefusal []
      rendered `shouldContain` "Postflight tag sweep refused"

    it "TagSweepInput record is constructible with all three fields" $ do
      let input =
            TagSweep.TagSweepInput
              { TagSweep.tagSweepEnvironment = [("AWS_REGION", "us-east-1")]
              , TagSweep.tagSweepClusterName = Just "aws-eks-test-cluster"
              , TagSweep.tagSweepWorkingDirectory = Just "/tmp/work"
              }
      TagSweep.tagSweepClusterName input `shouldBe` Just "aws-eks-test-cluster"
      TagSweep.tagSweepWorkingDirectory input `shouldBe` Just "/tmp/work"

  describe "Sprint 7.29 EKS VPC ownership hardening" $ do
    it "tags every VPC-scoped aws-eks Pulumi resource with prodbox ownership" $ do
      repoRoot <- getCurrentDirectory
      eksProgram <- readFile (repoRoot </> "pulumi" </> "aws-eks" </> "Main.yaml")
      mapM_
        (eksProgram `shouldContain`)
        [ unlines
            [ "  vpc:"
            , "    type: aws:ec2:Vpc"
            , "    properties:"
            , "      cidrBlock: \"10.91.0.0/16\""
            , "      enableDnsHostnames: true"
            , "      enableDnsSupport: true"
            , "      tags:"
            , "        Name: ${stackName}-vpc"
            , "        prodbox.io/managed-by: prodbox"
            ]
        , unlines
            [ "  igw:"
            , "    type: aws:ec2:InternetGateway"
            , "    properties:"
            , "      vpcId: ${vpc.id}"
            , "      tags:"
            , "        Name: ${stackName}-igw"
            , "        prodbox.io/managed-by: prodbox"
            ]
        , unlines
            [ "  publicRouteTable:"
            , "    type: aws:ec2:RouteTable"
            , "    properties:"
            , "      vpcId: ${vpc.id}"
            , "      routes:"
            , "        - cidrBlock: \"0.0.0.0/0\""
            , "          gatewayId: ${igw.id}"
            , "      tags:"
            , "        Name: ${stackName}-public-rt"
            , "        prodbox.io/managed-by: prodbox"
            ]
        , unlines
            [ "  publicSubnet0:"
            , "    type: aws:ec2:Subnet"
            , "    properties:"
            , "      vpcId: ${vpc.id}"
            , "      cidrBlock: \"10.91.0.0/24\""
            , "      availabilityZone: ${availabilityZones[0]}"
            , "      mapPublicIpOnLaunch: true"
            , "      tags:"
            , "        Name: ${stackName}-public-subnet-0"
            , "        prodbox.io/managed-by: prodbox"
            , "        kubernetes.io/cluster/${clusterName}: shared"
            , "        kubernetes.io/role/elb: \"1\""
            ]
        , unlines
            [ "  publicSubnet1:"
            , "    type: aws:ec2:Subnet"
            , "    properties:"
            , "      vpcId: ${vpc.id}"
            , "      cidrBlock: \"10.91.1.0/24\""
            , "      availabilityZone: ${availabilityZones[1]}"
            , "      mapPublicIpOnLaunch: true"
            , "      tags:"
            , "        Name: ${stackName}-public-subnet-1"
            , "        prodbox.io/managed-by: prodbox"
            , "        kubernetes.io/cluster/${clusterName}: shared"
            , "        kubernetes.io/role/elb: \"1\""
            ]
        ]

    it "classifies escaped VPC-scoped tag rows as postflight residue" $ do
      let rows =
            [ TagSweep.TaggedResource
                arn
                TagSweep.prodboxManagedByTagKey
                TagSweep.prodboxManagedByTagValue
            | arn <-
                [ "arn:aws:ec2:us-east-1:123:vpc/vpc-xyz"
                , "arn:aws:ec2:us-east-1:123:internet-gateway/igw-xyz"
                , "arn:aws:ec2:us-east-1:123:route-table/rtb-xyz"
                , "arn:aws:ec2:us-east-1:123:subnet/subnet-xyz"
                ]
            ]
          (retained, escaped) = TagSweep.partitionRetainedLongLived rows
          rendered = TagSweep.renderTagSweepRefusal escaped
      retained `shouldBe` []
      escaped `shouldBe` rows
      rendered `shouldContain` "vpc/vpc-xyz"
      rendered `shouldContain` "internet-gateway/igw-xyz"
      rendered `shouldContain` "route-table/rtb-xyz"
      rendered `shouldContain` "subnet/subnet-xyz"

  describe "Sprint 4.39 pre-created EBS volume lifecycle resource" $ do
    it "registers EBS volumes as a LongLived managed resource class" $
      ResourceClass.resourceNamesOfClass ResourceClass.LongLived
        `shouldContain` [EbsVolume.ebsManagedResourceName]

    it "projects deterministic retained PV/PVC inventory with substrate-specific MinIO capacity" $ do
      let expectedMinioHome =
            RetainedStorageInventoryEntry
              { retainedStorageInventoryNamespace = "prodbox"
              , retainedStorageInventoryStatefulSet = "minio"
              , retainedStorageInventoryOrdinal = 0
              , retainedStorageInventoryPersistentVolume =
                  retainedStatefulSetPersistentVolumeName "prodbox" "minio" 0
              , retainedStorageInventoryPersistentClaim =
                  retainedStatefulSetPersistentVolumeClaimName "minio" 0
              , retainedStorageInventoryStorageSize = "20Gi"
              }
          expectedVault =
            RetainedStorageInventoryEntry
              { retainedStorageInventoryNamespace = "vault"
              , retainedStorageInventoryStatefulSet = "vault"
              , retainedStorageInventoryOrdinal = 0
              , retainedStorageInventoryPersistentVolume =
                  retainedStatefulSetPersistentVolumeName "vault" "vault" 0
              , retainedStorageInventoryPersistentClaim =
                  retainedStatefulSetPersistentVolumeClaimName "vault" 0
              , retainedStorageInventoryStorageSize = "1Gi"
              }
          expectedHome = [expectedMinioHome, expectedVault]
          expectedAws = [expectedMinioHome, expectedVault]
      retainedStorageInventoryEntries SubstrateHomeLocal `shouldBe` expectedHome
      retainedStorageInventoryEntries SubstrateAws `shouldBe` expectedAws

    it "builds retained-production describe-volumes filters from the lifecycle tags" $
      EbsVolume.ebsDescribeVolumesArgs EbsVolume.EbsRetainedProduction
        `shouldBe` [ "ec2"
                   , "describe-volumes"
                   , "--output"
                   , "json"
                   , "--filters"
                   , "Name=tag:prodbox.io/managed-by,Values=prodbox"
                   , "Name=tag:prodbox.io/lifecycle,Values=retained-ebs"
                   ]

    it "builds test-scoped describe-volumes filters with the EKS ownership tag" $
      EbsVolume.ebsDescribeVolumesArgs (EbsVolume.EbsPerRunTest "aws-eks-test-cluster")
        `shouldBe` [ "ec2"
                   , "describe-volumes"
                   , "--output"
                   , "json"
                   , "--filters"
                   , "Name=tag:prodbox.io/managed-by,Values=prodbox"
                   , "Name=tag:prodbox.io/lifecycle,Values=per-run-test"
                   , "--filters"
                   , "Name=tag:kubernetes.io/cluster/aws-eks-test-cluster,Values=owned"
                   ]

    it "parses ec2 describe-volumes JSON into typed volume ids and states" $
      EbsVolume.parseDescribeVolumesPayload
        "{\"Volumes\":[{\"VolumeId\":\"vol-0123\",\"State\":\"available\",\"AvailabilityZone\":\"us-east-1a\",\"Tags\":[{\"Key\":\"prodbox.io/persistent-volume\",\"Value\":\"pv-a\"}]},{\"VolumeId\":\"vol-0456\",\"State\":\"in-use\"}]}"
        `shouldBe` Right
          [ EbsVolume.EbsVolume
              { EbsVolume.ebsVolumeId = EbsVolume.EbsVolumeId "vol-0123"
              , EbsVolume.ebsVolumeState = "available"
              , EbsVolume.ebsVolumeAvailabilityZone = Just "us-east-1a"
              , EbsVolume.ebsVolumeTags = [("prodbox.io/persistent-volume", "pv-a")]
              }
          , EbsVolume.EbsVolume
              { EbsVolume.ebsVolumeId = EbsVolume.EbsVolumeId "vol-0456"
              , EbsVolume.ebsVolumeState = "in-use"
              , EbsVolume.ebsVolumeAvailabilityZone = Nothing
              , EbsVolume.ebsVolumeTags = []
              }
          ]

    it "fails clearly when describe-volumes entries omit the volume id" $
      EbsVolume.parseDescribeVolumesPayload "{\"Volumes\":[{\"State\":\"available\"}]}"
        `shouldBe` Left "ec2 describe-volumes entry missing `VolumeId`"

    it "maps EBS discover results to the typed residue status gate" $ do
      EbsVolume.ebsDiscoverResultToResidue (Right [])
        `shouldBe` Residue.ResidueAbsent
      EbsVolume.ebsDiscoverResultToResidue
        ( Right
            [ EbsVolume.EbsVolume
                { EbsVolume.ebsVolumeId = EbsVolume.EbsVolumeId "vol-0123"
                , EbsVolume.ebsVolumeState = "available"
                , EbsVolume.ebsVolumeAvailabilityZone = Just "us-east-1a"
                , EbsVolume.ebsVolumeTags = []
                }
            ]
        )
        `shouldBe` Residue.ResiduePresent
          Residue.ResidueDetails
            { Residue.residueEvidence = "ec2:describe-volumes matched EBS volume(s): vol-0123"
            , Residue.residueStackName = EbsVolume.ebsManagedResourceName
            }
      EbsVolume.ebsDiscoverResultToResidue (Left "access denied")
        `shouldBe` Residue.ResidueUnreachable (Residue.ResidueQueryFailed "access denied")

    it "builds the typed delete-volume command for one EBS volume id" $
      EbsVolume.ebsDeleteVolumeArgs (EbsVolume.EbsVolumeId "vol-0123")
        `shouldBe` ["ec2", "delete-volume", "--volume-id", "vol-0123"]

    it "builds tagged retained create-volume commands for static PV inventory" $ do
      let required =
            EbsVolume.EbsRequiredVolume
              { EbsVolume.ebsRequiredPersistentVolumeName = "prodbox-retained-vscode-vscode-0"
              , EbsVolume.ebsRequiredSizeGiB = 50
              , EbsVolume.ebsRequiredAvailabilityZone = "us-east-1a"
              }
          args = EbsVolume.ebsCreateVolumeArgs required
      args `shouldContain` ["--availability-zone", "us-east-1a"]
      args `shouldContain` ["--size", "50"]
      args `shouldContain` ["--volume-type", "gp3"]
      unwords args `shouldContain` "Key=prodbox.io/lifecycle,Value=retained-ebs"
      unwords args
        `shouldContain` "Key=prodbox.io/persistent-volume,Value=prodbox-retained-vscode-vscode-0"

    it "maps retained EBS volume tags to static CSI volume bindings" $ do
      let required =
            [ EbsVolume.EbsRequiredVolume
                { EbsVolume.ebsRequiredPersistentVolumeName = "prodbox-retained-vscode-vscode-0"
                , EbsVolume.ebsRequiredSizeGiB = 50
                , EbsVolume.ebsRequiredAvailabilityZone = "us-east-1a"
                }
            ]
          discovered =
            [ EbsVolume.EbsVolume
                { EbsVolume.ebsVolumeId = EbsVolume.EbsVolumeId "vol-0123"
                , EbsVolume.ebsVolumeState = "available"
                , EbsVolume.ebsVolumeAvailabilityZone = Just "us-east-1a"
                , EbsVolume.ebsVolumeTags =
                    [ (EbsVolume.ebsPersistentVolumeTagKey, "prodbox-retained-vscode-vscode-0")
                    ]
                }
            ]
      EbsVolume.retainedEbsVolumeBindingsFromDiscovered required discovered
        `shouldBe` Right
          [ StaticEbsVolumeBinding
              { staticEbsVolumeBindingPersistentVolumeName = "prodbox-retained-vscode-vscode-0"
              , staticEbsVolumeBindingVolumeHandle = "vol-0123"
              , staticEbsVolumeBindingAvailabilityZone = "us-east-1a"
              }
          ]

    it "parses Gi storage quantities for retained EBS create plans" $ do
      EbsVolume.parseStorageSizeGiB "20Gi" `shouldBe` Right 20
      EbsVolume.parseStorageSizeGiB "50GiB" `shouldBe` Right 50
      EbsVolume.parseStorageSizeGiB "20Mi" `shouldSatisfy` isLeft

    it "carves retained-production EBS volumes out of cascade tag-sweep failures" $ do
      let rows =
            [ TagSweep.TaggedResource
                "arn:aws:ec2:us-east-1:123:volume/vol-0123"
                "prodbox.io/managed-by"
                "prodbox"
            , TagSweep.TaggedResource
                "arn:aws:ec2:us-east-1:123:volume/vol-0123"
                "prodbox.io/lifecycle"
                "retained-ebs"
            ]
          (retained, escaped) = TagSweep.partitionRetainedLongLived rows
      escaped `shouldBe` []
      retained `shouldBe` rows

    it "partitions test-scoped EBS rows only when the cluster ownership tag is present" $ do
      let ownedArn = "arn:aws:ec2:us-east-1:123:volume/vol-owned"
          missingOwnerArn = "arn:aws:ec2:us-east-1:123:volume/vol-missing-owner"
          rows =
            [ TagSweep.TaggedResource ownedArn "prodbox.io/lifecycle" "per-run-test"
            , TagSweep.TaggedResource ownedArn "kubernetes.io/cluster/aws-eks-test-cluster" "owned"
            , TagSweep.TaggedResource missingOwnerArn "prodbox.io/lifecycle" "per-run-test"
            ]
          partition = TagSweep.partitionEbsTagRows "aws-eks-test-cluster" rows
      map TagSweep.taggedResourceArn (TagSweep.retainedEbsTagRows partition) `shouldBe` []
      map TagSweep.taggedResourceArn (TagSweep.testScopedEbsTagRows partition)
        `shouldBe` [ownedArn, ownedArn]
      map TagSweep.taggedResourceArn (TagSweep.otherEbsTagRows partition)
        `shouldBe` [missingOwnerArn]

  describe "Sprint 4.40 test-scoped EBS reaper" $ do
    it "selects only test-scoped EBS volumes and never retained-production volumes" $ do
      let retainedArn = "arn:aws:ec2:us-east-1:123:volume/vol-retained"
          testArn = "arn:aws:ec2:us-east-1:123:volume/vol-test"
          rows =
            [ TagSweep.TaggedResource retainedArn "prodbox.io/lifecycle" "retained-ebs"
            , TagSweep.TaggedResource retainedArn "prodbox.io/lifecycle" "per-run-test"
            , TagSweep.TaggedResource retainedArn "kubernetes.io/cluster/aws-eks-test-cluster" "owned"
            , TagSweep.TaggedResource testArn "prodbox.io/lifecycle" "per-run-test"
            , TagSweep.TaggedResource testArn "kubernetes.io/cluster/aws-eks-test-cluster" "owned"
            ]
      EbsVolume.testScopedEbsVolumeIdsFromTagRows "aws-eks-test-cluster" rows
        `shouldBe` [EbsVolume.EbsVolumeId "vol-test"]

    it "builds an idempotent no-op plan when no test-scoped volumes are discovered" $ do
      let plan = EbsVolume.testScopedEbsReaperPlan "aws-eks-test-cluster" []
          report =
            EbsVolume.TestEbsReaperReport
              { EbsVolume.testEbsReaperMatchedVolumeIds = EbsVolume.testEbsReaperVolumeIds plan
              , EbsVolume.testEbsReaperDeletedVolumeIds = []
              }
      EbsVolume.testEbsReaperScope plan
        `shouldBe` EbsVolume.EbsPerRunTest "aws-eks-test-cluster"
      EbsVolume.testEbsReaperVolumeIds plan `shouldBe` []
      EbsVolume.renderTestScopedEbsReaperReport report
        `shouldBe` "Test-scoped EBS reaper: clean (no test-scoped EBS volumes matched)."

    it "renders deleted test-scoped volume ids in the reaper report" $ do
      let report =
            EbsVolume.TestEbsReaperReport
              { EbsVolume.testEbsReaperMatchedVolumeIds =
                  [EbsVolume.EbsVolumeId "vol-a", EbsVolume.EbsVolumeId "vol-b"]
              , EbsVolume.testEbsReaperDeletedVolumeIds =
                  [EbsVolume.EbsVolumeId "vol-a", EbsVolume.EbsVolumeId "vol-b"]
              }
      EbsVolume.renderTestScopedEbsReaperReport report
        `shouldContain` "vol-a, vol-b"

  describe "Sprint 3.19 Patroni Vault/pg_authid mismatch loud-failure decision" $ do
    it "proceeds when the Vault-backed password authenticates against pg_authid" $
      patroniSeedMismatchDecision "vscode" "keycloak" PatroniAuthMatches
        `shouldBe` PatroniResetProceed

    it "proceeds when pg_authid cannot be observed (fresh install / transient miss)" $
      patroniSeedMismatchDecision
        "vscode"
        "keycloak"
        (PatroniAuthUnobservable "no Patroni primary Pod found; nothing to probe")
        `shouldBe` PatroniResetProceed

    it "fails loudly on a proven rejection, naming the namespace/role pair and resolution options" $
      case patroniSeedMismatchDecision "vscode" "keycloak" PatroniAuthRejected of
        PatroniResetProceed ->
          expectationFailure "a definite pg_authid rejection must fail loudly, not proceed"
        PatroniResetLoudFailure message -> do
          message `shouldContain` "namespace `vscode`"
          message `shouldContain` "role `keycloak`"
          message `shouldContain` "refuses to silently reset"
          message `shouldContain` "restoring the Vault data / `.data/`"
          message `shouldContain` "wiping"

    it "renderPatroniResetDecision maps proceed to Right and loud failure to Left" $ do
      renderPatroniResetDecision PatroniResetProceed
        `shouldBe` Right ()
      case renderPatroniResetDecision (PatroniResetLoudFailure "boom") of
        Left message -> message `shouldBe` "boom"
        Right () -> expectationFailure "a loud-failure decision must render as Left"

  describe "host NTP disposition" $ do
    it "treats `System clock synchronized: yes` as healthy" $ do
      parseTimedatectlNtpDisposition
        ( unlines
            [ "               Local time: Mon 2026-04-06 10:00:00 UTC"
            , "  System clock synchronized: yes"
            , "                NTP service: active"
            ]
        )
        `shouldBe` NtpSynchronized

    it "fails fast when the system clock is not synchronized" $ do
      parseTimedatectlNtpDisposition
        ( unlines
            [ "               Local time: Mon 2026-04-06 10:00:00 UTC"
            , "  System clock synchronized: no"
            , "                NTP service: inactive"
            ]
        )
        `shouldBe` NtpUnsynced "timedatectl reports system clock not synchronized"

    it "treats the legacy `NTP synchronized` field as unsupported" $ do
      parseTimedatectlNtpDisposition
        ( unlines
            [ "               Local time: Mon 2026-04-06 10:00:00 UTC"
            , "           NTP synchronized: yes"
            , "                NTP service: active"
            ]
        )
        `shouldBe` NtpUnknown "timedatectl output did not include synchronization state"

    it "renders deterministic host info disposition output" $ do
      renderHostInfoReport "Linux test 6.17.0 #1 x86_64 GNU/Linux" NtpSynchronized
        `shouldBe` unlines
          [ "Host info"
          , "UNAME=Linux test 6.17.0 #1 x86_64 GNU/Linux"
          , "NTP_STATUS=synchronized"
          , "NTP_DETAIL=system clock is synchronized to a time source"
          ]

  describe "native host and k8s helpers" $ do
    it "renders deterministic host port availability output" $ do
      renderPortAvailabilityReport
        [ PortStatus 80 True "no listening socket detected"
        , PortStatus 443 False "listening socket detected"
        ]
        `shouldBe` unlines
          [ "Host port check"
          , "PORT=80 AVAILABLE=true DETAIL=no listening socket detected"
          , "PORT=443 AVAILABLE=false DETAIL=listening socket detected"
          , "Ports unavailable: 443"
          , "STATUS=busy"
          ]

    it "parses kubectl object names into a deterministic list" $ do
      parseKubectlObjectNames "pod/alpha\n\npod/bravo\n"
        `shouldBe` ["pod/alpha", "pod/bravo"]

    it
      "prefers the local RKE2 kubeconfig over ambient AWS-substrate KUBECONFIG for MinIO backend access"
      $ localKubeconfigCandidates
        (Just "/home/operator")
        (Just "/tmp/aws-eks-kubeconfig")
        `shouldBe` [ "/etc/rancher/rke2/rke2.yaml"
                   , "/home/operator/.kube/config"
                   , "/tmp/aws-eks-kubeconfig"
                   ]

    it "skips unreadable local kubeconfig candidates before falling back" $
      withSystemTempDirectory "prodbox-kubeconfig-candidates" $ \tmpDir -> do
        let unreadableCandidate = tmpDir </> "rke2.yaml"
            readableCandidate = tmpDir </> "home-kubeconfig.yaml"
        writeFile unreadableCandidate "apiVersion: v1\n"
        writeFile readableCandidate "apiVersion: v1\n"
        originalPermissions <- getPermissions unreadableCandidate
        setPermissions unreadableCandidate originalPermissions {readable = False}
        selectedCandidate <-
          firstReadableKubeconfigCandidate [unreadableCandidate, readableCandidate]
            `finally` setPermissions unreadableCandidate originalPermissions
        selectedCandidate `shouldBe` Just readableCandidate

  describe "container image mapping" $ do
    it "keeps the supported platform image mirrors on explicit Harbor targets" $ do
      mapM_
        (\expectedPair -> ContainerImage.requiredPublicImagePairs `shouldContain` [expectedPair])
        [ ("ghcr.io/coder/code-server:4.98.2", "127.0.0.1:30080/prodbox/code-server-mirror:4.98.2")
        , ("docker.io/curlimages/curl:8.11.0", "127.0.0.1:30080/prodbox/curl-mirror:8.11.0")
        , ("docker.io/envoyproxy/gateway:v1.7.2", "127.0.0.1:30080/prodbox/envoy-gateway-mirror:v1.7.2")
        ,
          ( "docker.io/envoyproxy/envoy:distroless-v1.37.0"
          , "127.0.0.1:30080/prodbox/envoy-proxy-mirror:distroless-v1.37.0"
          )
        ]

    it "maps supported public-image aliases to stable Harbor targets only for mirrored upstreams" $ do
      ContainerImage.harborMirrorTargetForSource "docker.io/percona/percona-postgresql-operator:2.9.0"
        `shouldBe` Just "127.0.0.1:30080/prodbox/percona-postgresql-operator-mirror:2.9.0"
      ContainerImage.harborMirrorTargetForSource "mirror.gcr.io/percona/percona-postgresql-operator:2.9.0"
        `shouldBe` Just "127.0.0.1:30080/prodbox/percona-postgresql-operator-mirror:2.9.0"
      ContainerImage.harborMirrorTargetForSource
        "docker.io/percona/percona-distribution-postgresql:17.9-1"
        `shouldBe` Just "127.0.0.1:30080/prodbox/percona-distribution-postgresql-mirror:17.9-1"
      ContainerImage.harborMirrorTargetForSource
        "mirror.gcr.io/percona/percona-distribution-postgresql:17.9-1"
        `shouldBe` Just "127.0.0.1:30080/prodbox/percona-distribution-postgresql-mirror:17.9-1"
      ContainerImage.harborMirrorTargetForSource "docker.io/percona/percona-pgbackrest:2.58.0-1"
        `shouldBe` Just "127.0.0.1:30080/prodbox/percona-pgbackrest-mirror:2.58.0-1"
      ContainerImage.harborMirrorTargetForSource "docker.io/percona/percona-pgbouncer:1.25.1-1"
        `shouldBe` Just "127.0.0.1:30080/prodbox/percona-pgbouncer-mirror:1.25.1-1"
      ContainerImage.harborMirrorTargetForSource "docker.io/codercom/code-server:4.98.2"
        `shouldBe` Just "127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
      ContainerImage.harborMirrorTargetForSource "docker.io/curlimages/curl:8.11.0"
        `shouldBe` Just "127.0.0.1:30080/prodbox/curl-mirror:8.11.0"
      ContainerImage.harborMirrorTargetForSource "docker.io/envoyproxy/gateway:v1.7.2"
        `shouldBe` Just "127.0.0.1:30080/prodbox/envoy-gateway-mirror:v1.7.2"
      ContainerImage.harborMirrorTargetForSource "mirror.gcr.io/envoyproxy/gateway:v1.7.2"
        `shouldBe` Just "127.0.0.1:30080/prodbox/envoy-gateway-mirror:v1.7.2"
      ContainerImage.harborMirrorTargetForSource "docker.io/envoyproxy/envoy:distroless-v1.37.0"
        `shouldBe` Just "127.0.0.1:30080/prodbox/envoy-proxy-mirror:distroless-v1.37.0"
      ContainerImage.harborMirrorTargetForSource "mirror.gcr.io/envoyproxy/envoy:distroless-v1.37.0"
        `shouldBe` Just "127.0.0.1:30080/prodbox/envoy-proxy-mirror:distroless-v1.37.0"

    it "orders public-image mirror candidates with the discovered source first" $ do
      ContainerImage.harborMirrorSourceCandidates "docker.io/percona/percona-postgresql-operator:2.9.0"
        `shouldBe` Just
          [ "docker.io/percona/percona-postgresql-operator:2.9.0"
          , "mirror.gcr.io/percona/percona-postgresql-operator:2.9.0"
          ]
      ContainerImage.harborMirrorSourceCandidates "docker.io/percona/percona-pgbackrest:2.58.0-1"
        `shouldBe` Just
          [ "docker.io/percona/percona-pgbackrest:2.58.0-1"
          , "mirror.gcr.io/percona/percona-pgbackrest:2.58.0-1"
          ]
      ContainerImage.harborMirrorSourceCandidates "ghcr.io/coder/code-server:4.98.2"
        `shouldBe` Just ["ghcr.io/coder/code-server:4.98.2", "docker.io/codercom/code-server:4.98.2"]
      ContainerImage.harborMirrorSourceCandidates "docker.io/curlimages/curl:8.11.0"
        `shouldBe` Just ["docker.io/curlimages/curl:8.11.0"]
      ContainerImage.harborMirrorSourceCandidates "docker.io/envoyproxy/gateway:v1.7.2"
        `shouldBe` Just
          [ "docker.io/envoyproxy/gateway:v1.7.2"
          , "mirror.gcr.io/envoyproxy/gateway:v1.7.2"
          ]

    it "tracks candidate upstream sets for required public images" $ do
      mapM_
        (\expectedPair -> ContainerImage.requiredPublicImageCandidatePairs `shouldContain` [expectedPair])
        [
          (
            [ "docker.io/percona/percona-distribution-postgresql:17.9-1"
            , "mirror.gcr.io/percona/percona-distribution-postgresql:17.9-1"
            ]
          , "127.0.0.1:30080/prodbox/percona-distribution-postgresql-mirror:17.9-1"
          )
        ,
          (
            [ "docker.io/envoyproxy/gateway:v1.7.2"
            , "mirror.gcr.io/envoyproxy/gateway:v1.7.2"
            ]
          , "127.0.0.1:30080/prodbox/envoy-gateway-mirror:v1.7.2"
          )
        ,
          (
            [ "ghcr.io/coder/code-server:4.98.2"
            , "docker.io/codercom/code-server:4.98.2"
            ]
          , "127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
          )
        ]

  describe "AWS environment helpers" $ do
    let credentialsWithoutSession =
          Credentials
            { access_key_id = "config-access-key"
            , secret_access_key = "config-secret-key"
            , session_token = Nothing
            , region = "us-west-2"
            }
        credentialsWithSession =
          credentialsWithoutSession {session_token = Just "config-session-token"}

    it "replaces ambient AWS auth sources with repo-owned credentials" $ do
      let environment =
            [ ("PATH", "/usr/bin")
            , ("AWS_PROFILE", "default")
            , ("AWS_SHARED_CREDENTIALS_FILE", "/tmp/creds")
            , ("AWS_ACCESS_KEY_ID", "ambient-access-key")
            , ("AWS_SECRET_ACCESS_KEY", "ambient-secret-key")
            , ("AWS_SESSION_TOKEN", "ambient-session-token")
            , ("AWS_SECURITY_TOKEN", "ambient-security-token")
            ]
          updatedEnvironment = overlayAwsCredentials environment credentialsWithoutSession
      lookup "PATH" updatedEnvironment `shouldBe` Just "/usr/bin"
      lookup "AWS_ACCESS_KEY_ID" updatedEnvironment `shouldBe` Just "config-access-key"
      lookup "AWS_SECRET_ACCESS_KEY" updatedEnvironment `shouldBe` Just "config-secret-key"
      lookup "AWS_REGION" updatedEnvironment `shouldBe` Just "us-west-2"
      lookup "AWS_DEFAULT_REGION" updatedEnvironment `shouldBe` Just "us-west-2"
      lookup "AWS_EC2_METADATA_DISABLED" updatedEnvironment `shouldBe` Just "true"
      lookup "AWS_PAGER" updatedEnvironment `shouldBe` Just ""
      lookup "AWS_PROFILE" updatedEnvironment `shouldBe` Nothing
      lookup "AWS_SHARED_CREDENTIALS_FILE" updatedEnvironment `shouldBe` Nothing
      lookup "AWS_SESSION_TOKEN" updatedEnvironment `shouldBe` Nothing
      lookup "AWS_SECURITY_TOKEN" updatedEnvironment `shouldBe` Nothing

    it "projects an explicit session token when the repo config provides one" $ do
      let updatedEnvironment = sealedAwsEnvironment credentialsWithSession
      lookup "AWS_ACCESS_KEY_ID" updatedEnvironment `shouldBe` Just "config-access-key"
      lookup "AWS_SECRET_ACCESS_KEY" updatedEnvironment `shouldBe` Just "config-secret-key"
      lookup "AWS_SESSION_TOKEN" updatedEnvironment `shouldBe` Just "config-session-token"
      lookup "AWS_REGION" updatedEnvironment `shouldBe` Just "us-west-2"
      lookup "AWS_DEFAULT_REGION" updatedEnvironment `shouldBe` Just "us-west-2"

    it "seeds PATH and HOME from the parent environment in the canonical AWS CLI env builder" $ do
      originalPath <- lookupEnv "PATH"
      originalHome <- lookupEnv "HOME"
      setEnv "PATH" "/canary/bin:/usr/bin"
      setEnv "HOME" "/canary/home"
      builtEnvironment <- awsCliSubprocessEnvironment credentialsWithoutSession
      lookup "PATH" builtEnvironment `shouldBe` Just "/canary/bin:/usr/bin"
      lookup "HOME" builtEnvironment `shouldBe` Just "/canary/home"
      lookup "AWS_ACCESS_KEY_ID" builtEnvironment `shouldBe` Just "config-access-key"
      lookup "AWS_SECRET_ACCESS_KEY" builtEnvironment `shouldBe` Just "config-secret-key"
      lookup "AWS_REGION" builtEnvironment `shouldBe` Just "us-west-2"
      maybe (unsetEnv "PATH") (setEnv "PATH") originalPath
      maybe (unsetEnv "HOME") (setEnv "HOME") originalHome

    it "retries transient AWS credential propagation failures before failing the prerequisite" $
      withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
        let binDir = tmpDir </> "bin"
            fakeAwsPath = binDir </> "aws"
            stateDir = tmpDir </> "fake-aws-state"
            countPath = stateDir </> "sts-count"
            restoreEnv key previous =
              case previous of
                Just value -> setEnv key value
                Nothing -> unsetEnv key

        createDirectoryIfMissing True binDir
        writeFile fakeAwsPath (unlines (fakeAwsCredentialPropagationScript stateDir))
        makeExecutable fakeAwsPath

        withBinarySiblingTier0 (wrapTier0 validConfig) $ do
          originalPath <- lookupEnv "PATH"
          originalHostVaultKv <- lookupEnv "PRODBOX_TEST_HOST_VAULT_KV"
          let configuredPath =
                case originalPath of
                  Just currentPath -> binDir ++ ":" ++ currentPath
                  Nothing -> binDir

          setEnv "PATH" configuredPath
          setEnv "PRODBOX_TEST_HOST_VAULT_KV" "allow"
          validationResult <-
            runEffect (InterpreterContext tmpDir) (Validate RequireAwsCredentials)
              `finally` do
                restoreEnv "PATH" originalPath
                restoreEnv "PRODBOX_TEST_HOST_VAULT_KV" originalHostVaultKv

          validationResult `shouldBe` Result.Success ()
          readFile countPath `shouldReturn` "3"

  describe "native validation helpers" $ do
    it "retries AWS test-stack SSH validation until a node accepts connections" $
      withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
        -- Sprint 4.18 fourth/sixth chunks: SSH validation reads BOTH the
        -- aws-test nodes and ssh_private_key from the live Pulumi
        -- outputs (rather than .prodbox-state). The test injects both
        -- via the PRODBOX_TEST_PER_RUN_OUTPUTS_DIR override on
        -- 'fetchPerRunStackOutputs'.
        let sshStateDir = tmpDir </> "ssh-state"
            binDir = tmpDir </> "bin"
            fakeSshPath = binDir </> "ssh"
            mockOutputsDir = tmpDir </> "pulumi-outputs"
            mockOutputsPath = mockOutputsDir </> (AwsTest.awsTestStackName ++ ".json")
            mockOutputsJson =
              "{\"nodes\":\"[ {\\\"name\\\":\\\"aws-test-node-0\\\""
                ++ ", \\\"availability_zone\\\":\\\"us-west-2a\\\""
                ++ ", \\\"instance_id\\\":\\\"i-1234567890\\\""
                ++ ", \\\"private_ip\\\":\\\"10.0.0.10\\\""
                ++ ", \\\"public_ip\\\":\\\"203.0.113.10\\\"} ]\""
                ++ ", \"ssh_private_key\":\"fake-private-key\"}"
        createDirectoryIfMissing True sshStateDir
        createDirectoryIfMissing True binDir
        createDirectoryIfMissing True mockOutputsDir
        writeFile mockOutputsPath mockOutputsJson
        writeFile fakeSshPath (unlines fakeAwsTestSshScript)
        makeExecutable fakeSshPath

        originalPath <- lookupEnv "PATH"
        originalSshStateDir <- lookupEnv "PRODBOX_TEST_SSH_STATE_DIR"
        originalOutputsDir <- lookupEnv "PRODBOX_TEST_PER_RUN_OUTPUTS_DIR"
        let restoreEnv key previous =
              case previous of
                Just value -> setEnv key value
                Nothing -> unsetEnv key
            configuredPath =
              case originalPath of
                Just currentPath -> binDir ++ ":" ++ currentPath
                Nothing -> binDir

        setEnv "PATH" configuredPath
        setEnv "PRODBOX_TEST_SSH_STATE_DIR" sshStateDir
        setEnv "PRODBOX_TEST_PER_RUN_OUTPUTS_DIR" mockOutputsDir
        validationResult <-
          verifyAwsTestSshReachability tmpDir
            `finally` do
              restoreEnv "PATH" originalPath
              restoreEnv "PRODBOX_TEST_SSH_STATE_DIR" originalSshStateDir
              restoreEnv "PRODBOX_TEST_PER_RUN_OUTPUTS_DIR" originalOutputsDir

        validationResult `shouldBe` ExitSuccess
        readFile (sshStateDir </> "count") `shouldReturn` "3"

  describe "Keycloak admin base URL" $ do
    it "derives the default public host from validated settings" $
      Prodbox.Keycloak.Admin.buildKeycloakBaseUrl (testValidatedSettings "/tmp/prodbox/.data")
        `shouldBe` "https://test.resolvefintech.com/auth"
    it "accepts an explicit substrate public host" $
      Prodbox.Keycloak.Admin.buildKeycloakBaseUrlForHost " aws.test.resolvefintech.com "
        `shouldBe` "https://aws.test.resolvefintech.com/auth"

  -- Sprint 8.8: Keycloak 26's user-profile validation rejects a name-less
  -- user's first login / direct-grant token request with
  -- @invalid_grant: "Account is not fully set up"@, so the invited-user
  -- creation payload must carry non-empty firstName/lastName. (Confirmed
  -- live 2026-06-08: the credential-setup flow completed but the OIDC claim
  -- assertion 400'd until firstName/lastName were set.)
  describe "Keycloak invited-user creation payload" $ do
    it "sets non-empty firstName/lastName (firstName from the email local part)" $ do
      let payload =
            Prodbox.Keycloak.Admin.newUserCreationPayload
              Prodbox.Keycloak.Admin.NewUser
                { Prodbox.Keycloak.Admin.newUserEmail =
                    "test-abc123@inbox.test.resolvefintech.com"
                , Prodbox.Keycloak.Admin.newUserRole = Nothing
                }
      payload
        `shouldBe` object
          [ "enabled" .= True
          , "email" .= ("test-abc123@inbox.test.resolvefintech.com" :: Text.Text)
          , "username" .= ("test-abc123@inbox.test.resolvefintech.com" :: Text.Text)
          , "firstName" .= ("test-abc123" :: Text.Text)
          , "lastName" .= ("Invitee" :: Text.Text)
          , "emailVerified" .= False
          , "requiredActions" .= (["VERIFY_EMAIL"] :: [Text.Text])
          ]

  describe "Keycloak realm SMTP reconciliation" $ do
    let smtpSettings =
          Prodbox.Keycloak.Admin.RealmSmtpSettings
            { Prodbox.Keycloak.Admin.realmSmtpHost = "email-smtp.us-west-2.amazonaws.com"
            , Prodbox.Keycloak.Admin.realmSmtpPort = "587"
            , Prodbox.Keycloak.Admin.realmSmtpFrom = "noreply@test.resolvefintech.com"
            , Prodbox.Keycloak.Admin.realmSmtpFromDisplayName = "prodbox"
            , Prodbox.Keycloak.Admin.realmSmtpReplyTo = "noreply@test.resolvefintech.com"
            , Prodbox.Keycloak.Admin.realmSmtpUser = "AKIAEXAMPLE"
            , Prodbox.Keycloak.Admin.realmSmtpPassword = "smtp-pass"
            }
        expectedSmtpJson =
          object
            [ "host" .= ("email-smtp.us-west-2.amazonaws.com" :: Text.Text)
            , "port" .= ("587" :: Text.Text)
            , "from" .= ("noreply@test.resolvefintech.com" :: Text.Text)
            , "fromDisplayName" .= ("prodbox" :: Text.Text)
            , "replyTo" .= ("noreply@test.resolvefintech.com" :: Text.Text)
            , "starttls" .= ("true" :: Text.Text)
            , "auth" .= ("true" :: Text.Text)
            , "user" .= ("AKIAEXAMPLE" :: Text.Text)
            , "password" .= ("smtp-pass" :: Text.Text)
            ]
    it "decodes the keycloak/smtp Vault KV object into realm SMTP settings" $ do
      let fields =
            Map.fromList
              [ ("host", "email-smtp.us-west-2.amazonaws.com")
              , ("port", "587")
              , ("from", "noreply@test.resolvefintech.com")
              , ("from_display_name", "prodbox")
              , ("reply_to", "noreply@test.resolvefintech.com")
              , ("username", "AKIAEXAMPLE")
              , ("password", "smtp-pass")
              ]
      Prodbox.UsersAdmin.smtpSettingsFromVaultFields fields `shouldBe` Right smtpSettings
    it "renders Keycloak's smtpServer representation from the Vault fields" $
      Prodbox.Keycloak.Admin.realmSmtpSettingsJson smtpSettings `shouldBe` expectedSmtpJson
    it "patches an existing realm representation without dropping existing fields" $
      Prodbox.Keycloak.Admin.applyRealmSmtpSettings
        smtpSettings
        (object ["realm" .= ("prodbox" :: Text.Text), "enabled" .= True])
        `shouldBe` Result.Success
          ( object
              [ "realm" .= ("prodbox" :: Text.Text)
              , "enabled" .= True
              , "smtpServer" .= expectedSmtpJson
              ]
          )

  describe "Keycloak invite-email parser" $ do
    it "extracts the action-token URL from a plain-text invite email" $
      Prodbox.Keycloak.Email.parseKeycloakInviteLink keycloakInvitePlainFixture
        `shouldBe` Right "https://test.resolvefintech.com/auth/realms/prodbox/login-actions/action-token?key=abc123"
    it "extracts the action-token URL across a quoted-printable soft-wrap" $
      Prodbox.Keycloak.Email.parseKeycloakInviteLink keycloakInviteQuotedPrintableFixture
        `shouldBe` Right "https://test.resolvefintech.com/auth/realms/prodbox/login-actions/action-token?key=def456"
    it "deduplicates multipart text/html copies after URL-local quoted-printable normalization" $
      Prodbox.Keycloak.Email.parseKeycloakInviteLink keycloakInviteMultipartDuplicateFixture
        `shouldBe` Right "https://test.resolvefintech.com/auth/realms/prodbox/login-actions/action-token?key=ghi789"
    it "fails fast when the email body contains multiple distinct invite links" $
      Prodbox.Keycloak.Email.parseKeycloakInviteLink keycloakInviteMultipleDistinctFixture
        `shouldBe` Left "multiple Keycloak invite links found in email body"
    it "fails fast when the email body contains no invite link" $
      Prodbox.Keycloak.Email.parseKeycloakInviteLink keycloakInviteMissingFixture
        `shouldBe` Left "no Keycloak invite link found in email body"

  describe "SES SMTP password derivation" $ do
    it "matches the AWS published algorithm for us-west-2" $
      Prodbox.Ses.SmtpPassword.derivedSesSmtpPassword "us-west-2" sesSmtpPasswordExampleSecret
        `shouldBe` "BF2PynzbSCAjX08zhZZnP/kW+T9P5zs/1Er0pi5vTEmd"
    it "matches the AWS published algorithm for us-east-1" $
      Prodbox.Ses.SmtpPassword.derivedSesSmtpPassword "us-east-1" sesSmtpPasswordExampleSecret
        `shouldBe` "BLBM/9hSUELfq8Gw+rU1YcBjkOxGbhT2XG763xVLGWL9"
    it "matches the AWS published algorithm for eu-west-1" $
      Prodbox.Ses.SmtpPassword.derivedSesSmtpPassword "eu-west-1" sesSmtpPasswordExampleSecret
        `shouldBe` "BMW5RDrXmmVs0lV7GpI4oLkHXpZ4stDsk6q91z1g38Pk"
    it "is region-sensitive (different region → different password)" $ do
      let p1 = Prodbox.Ses.SmtpPassword.derivedSesSmtpPassword "us-west-2" sesSmtpPasswordExampleSecret
          p2 = Prodbox.Ses.SmtpPassword.derivedSesSmtpPassword "us-east-1" sesSmtpPasswordExampleSecret
      p1 `shouldNotBe` p2
    it "is deterministic (same inputs → same output)" $ do
      let p1 = Prodbox.Ses.SmtpPassword.derivedSesSmtpPassword "us-west-2" sesSmtpPasswordExampleSecret
          p2 = Prodbox.Ses.SmtpPassword.derivedSesSmtpPassword "us-west-2" sesSmtpPasswordExampleSecret
      p1 `shouldBe` p2

  describe "Keycloak SMTP Vault sync" $ do
    it "renders the externally-owned keycloak/smtp Vault fields" $ do
      let fields =
            AwsSesStack.keycloakSmtpVaultFields
              "us-west-2"
              "test.resolvefintech.com"
              "email-smtp.us-west-2.amazonaws.com"
              "AKIAEXAMPLE"
              (Text.unpack sesSmtpPasswordExampleSecret)
      Map.lookup "host" fields `shouldBe` Just "email-smtp.us-west-2.amazonaws.com"
      Map.lookup "port" fields `shouldBe` Just "587"
      Map.lookup "from" fields `shouldBe` Just "noreply@test.resolvefintech.com"
      Map.lookup "from_display_name" fields `shouldBe` Just "prodbox"
      Map.lookup "reply_to" fields `shouldBe` Just "noreply@test.resolvefintech.com"
      Map.lookup "username" fields `shouldBe` Just "AKIAEXAMPLE"
      Map.lookup "password" fields
        `shouldBe` Just (Prodbox.Ses.SmtpPassword.derivedSesSmtpPassword "us-west-2" sesSmtpPasswordExampleSecret)

    it "lets aws-ses Route 53 records reconcile over retained records during state repair" $ do
      repoRoot <- getCurrentDirectory
      pulumiProgram <- readFile (repoRoot </> "pulumi" </> "aws-ses" </> "Main.yaml")
      length (filter (== "      allowOverwrite: true") (lines pulumiProgram))
        `shouldBe` 5

    it "allows Keycloak egress to the configured SES SMTP port" $ do
      repoRoot <- getCurrentDirectory
      networkPolicy <-
        readFile (repoRoot </> "charts" </> "keycloak" </> "templates" </> "networkpolicy.yaml")
      networkPolicy `shouldContain` "cidr: 0.0.0.0/0"
      networkPolicy `shouldContain` "port: {{ .Values.smtp.port }}"

  describe "Sprint 7.5.c.v.b EKS custom-image push pod" $ do
    let cfg = Prodbox.Lib.EksCustomImagePush.defaultEksCustomImagePushConfig
        manifest = Prodbox.Lib.EksCustomImagePush.eksCustomImagePushPodManifest cfg
        manifestJson = BL8.unpack (encode manifest)
    it "default config matches bootstrap Harbor admin + in-cluster DNS endpoint" $ do
      Prodbox.Lib.EksCustomImagePush.customPushPodNamespace cfg `shouldBe` "harbor"
      Prodbox.Lib.EksCustomImagePush.customPushPodName cfg `shouldBe` "prodbox-custom-image-push"
      Prodbox.Lib.EksCustomImagePush.customPushHarborInternalEndpoint cfg
        `shouldBe` "harbor.harbor.svc.cluster.local"
      Prodbox.Lib.EksCustomImagePush.customPushChartRegistryEndpoint cfg `shouldBe` "127.0.0.1:30080"
      Prodbox.Lib.EksCustomImagePush.customPushHarborAdminUser cfg `shouldBe` "admin"
      Prodbox.Lib.EksCustomImagePush.customPushHarborAdminPassword cfg `shouldBe` "Harbor12345"
    it "pod manifest declares v1 Pod in harbor namespace with sprint label + restartPolicy Never" $ do
      manifestJson `shouldContain` "\"apiVersion\":\"v1\""
      manifestJson `shouldContain` "\"kind\":\"Pod\""
      manifestJson `shouldContain` "\"namespace\":\"harbor\""
      manifestJson `shouldContain` "\"name\":\"prodbox-custom-image-push\""
      manifestJson `shouldContain` "\"prodbox.io/sprint\":\"7.5.c.v.b\""
      manifestJson `shouldContain` "\"restartPolicy\":\"Never\""
    it "uses crane:debug image with sleep entrypoint + /data emptyDir mount" $ do
      manifestJson `shouldContain` "go-containerregistry/crane:debug"
      manifestJson `shouldContain` "\"command\":[\"/busybox/sh\",\"-c\",\"sleep infinity\"]"
      manifestJson `shouldContain` "\"mountPath\":\"/data\""
      manifestJson `shouldContain` "\"emptyDir\":{\"sizeLimit\":\"12Gi\"}"
      manifestJson `shouldContain` "\"memory\":\"4Gi\""
      manifestJson `shouldContain` "\"ephemeral-storage\":\"12Gi\""
    it "projects Harbor credentials and authenticates before crane push" $ do
      manifestJson
        `shouldContain` "\"name\":\"HARBOR_INTERNAL\",\"value\":\"harbor.harbor.svc.cluster.local\""
      manifestJson `shouldContain` "\"name\":\"HARBOR_USER\",\"value\":\"admin\""
      manifestJson `shouldContain` "\"name\":\"HARBOR_PASSWORD\",\"value\":\"Harbor12345\""
    it "rewriteChartRefForInClusterPush swaps the host:port for the in-cluster DNS endpoint" $ do
      Prodbox.Lib.EksCustomImagePush.rewriteChartRefForInClusterPush
        cfg
        "127.0.0.1:30080/prodbox/prodbox-runtime:tag"
        `shouldBe` "harbor.harbor.svc.cluster.local/prodbox/prodbox-runtime:tag"
    it "rewriteChartRefForInClusterPush leaves unrecognized refs unchanged (defensive)" $ do
      Prodbox.Lib.EksCustomImagePush.rewriteChartRefForInClusterPush cfg "docker.io/library/foo:tag"
        `shouldBe` "docker.io/library/foo:tag"

  describe "Sprint 7.5.c.iv EKS image-mirror Job" $ do
    let cfg = Prodbox.Lib.EksImageMirror.defaultEksImageMirrorConfig
        pairs =
          [
            ( "docker.io/percona/percona-postgresql-operator:2.9.0"
            , "127.0.0.1:30080/prodbox/percona-postgresql-operator-mirror:2.9.0"
            )
          , ("quay.io/keycloak/keycloak:26.0.0", "127.0.0.1:30080/prodbox/keycloak-mirror:26.0.0")
          ]
        manifest = Prodbox.Lib.EksImageMirror.eksImageMirrorJobManifest cfg pairs
        manifestJson = BL8.unpack (encode manifest)
        copyScript = Prodbox.Lib.EksImageMirror.eksImageMirrorCopyScript cfg pairs
    it "default config matches the bootstrap Harbor admin contract + in-cluster DNS endpoint" $ do
      Prodbox.Lib.EksImageMirror.mirrorJobNamespace cfg `shouldBe` "harbor"
      Prodbox.Lib.EksImageMirror.mirrorJobName cfg `shouldBe` "prodbox-image-mirror"
      Prodbox.Lib.EksImageMirror.mirrorHarborInternalEndpoint cfg
        `shouldBe` "harbor.harbor.svc.cluster.local"
      Prodbox.Lib.EksImageMirror.mirrorChartRegistryEndpoint cfg `shouldBe` "127.0.0.1:30080"
      Prodbox.Lib.EksImageMirror.mirrorHarborAdminUser cfg `shouldBe` "admin"
      Prodbox.Lib.EksImageMirror.mirrorHarborAdminPassword cfg `shouldBe` "Harbor12345"
    it "Job manifest declares batch/v1 Job in harbor namespace with sprint label and crane container" $ do
      manifestJson `shouldContain` "\"apiVersion\":\"batch/v1\""
      manifestJson `shouldContain` "\"kind\":\"Job\""
      manifestJson `shouldContain` "\"namespace\":\"harbor\""
      manifestJson `shouldContain` "\"name\":\"prodbox-image-mirror\""
      manifestJson `shouldContain` "\"prodbox.io/sprint\":\"7.5.c.iv\""
      manifestJson `shouldContain` "go-containerregistry/crane:debug"
    it
      "Job manifest projects HARBOR_INTERNAL + HARBOR_USER + HARBOR_PASSWORD env into the crane container"
      $ do
        manifestJson
          `shouldContain` "\"name\":\"HARBOR_INTERNAL\",\"value\":\"harbor.harbor.svc.cluster.local\""
        manifestJson `shouldContain` "\"name\":\"HARBOR_USER\",\"value\":\"admin\""
        manifestJson `shouldContain` "\"name\":\"HARBOR_PASSWORD\",\"value\":\"Harbor12345\""
    it "copy script rewrites 127.0.0.1:30080 chart targets to the in-cluster harbor DNS for crane push" $ do
      copyScript
        `shouldContain` "crane copy \"docker.io/percona/percona-postgresql-operator:2.9.0\" \"harbor.harbor.svc.cluster.local/prodbox/percona-postgresql-operator-mirror:2.9.0\""
      copyScript
        `shouldContain` "crane copy \"quay.io/keycloak/keycloak:26.0.0\" \"harbor.harbor.svc.cluster.local/prodbox/keycloak-mirror:26.0.0\""
    it "copy script authenticates to Harbor before any copy + emits a per-pair progress line" $ do
      copyScript `shouldContain` "crane auth login \"${HARBOR_INTERNAL}\""
      copyScript `shouldContain` "prodbox-image-mirror: copying 2 required public images"
      copyScript
        `shouldContain` "prodbox-image-mirror: docker.io/percona/percona-postgresql-operator:2.9.0 -> harbor.harbor.svc.cluster.local/prodbox/percona-postgresql-operator-mirror:2.9.0"

  describe "Sprint 7.12 substrate-equivalence structural invariant" $ do
    it "the home installer covers every shared platform component (no omission)" $
      Set.fromList homeSubstratePlatformComponents
        `shouldBe` Set.fromList ContainerImage.sharedPlatformComponents
    it "the AWS installer covers every shared platform component (no omission)" $
      Set.fromList Prodbox.Lib.AwsSubstratePlatform.awsSubstratePlatformComponents
        `shouldBe` Set.fromList ContainerImage.sharedPlatformComponents
    it "both installers cover the identical shared component set" $
      Set.fromList homeSubstratePlatformComponents
        `shouldBe` Set.fromList Prodbox.Lib.AwsSubstratePlatform.awsSubstratePlatformComponents
    it "the shared inventory enumerates all 14 canonical components" $
      sort (map ContainerImage.platformComponentLabel ContainerImage.sharedPlatformComponents)
        `shouldBe` sort
          [ "gateway"
          , "keycloak"
          , "keycloak-postgres"
          , "vscode"
          , "api"
          , "redis"
          , "websocket"
          , "minio"
          , "harbor"
          , "percona-postgres-operator"
          , "envoy-gateway"
          , "cert-manager"
          , "zerossl-dns01"
          , "vault"
          ]
    it "the single Envoy Gateway release feeds chart + control plane + data plane from one pin" $ do
      ContainerImage.envoyGatewayChartVersion
        `shouldBe` ContainerImage.envoyGatewayReleaseChartVersion ContainerImage.envoyGatewayRelease
      ContainerImage.imageTag ContainerImage.harborEnvoyGatewayImage `shouldBe` "v1.7.2"
      ContainerImage.imageTag ContainerImage.harborEnvoyProxyImage `shouldBe` "distroless-v1.37.0"
      ContainerImage.envoyGatewayChartVersion `shouldBe` "v1.7.2"
    it "the AWS Envoy chart version equals the home Envoy chart version (no per-substrate skew)" $
      Prodbox.Lib.AwsSubstratePlatform.awsSubstrateEnvoyGatewayChartVersion
        `shouldBe` ContainerImage.envoyGatewayChartVersion
    it "the AWS cert-manager chart version equals the shared cert-manager pin (no per-substrate skew)" $
      Prodbox.Lib.AwsSubstratePlatform.awsSubstrateCertManagerChartVersion
        `shouldBe` ContainerImage.certManagerChartVersion
    it "checkSubstrateImagePinning passes on a tree that sources shared pins from ContainerImage" $
      substrateImagePinningViolations
        "src/Prodbox/Lib/AwsSubstratePlatform.hs"
        "awsSubstrateEnvoyGatewayChartVersion = ContainerImage.envoyGatewayChartVersion\n"
        `shouldBe` []
    it "checkSubstrateImagePinning fires on a reintroduced per-substrate Envoy chart pin" $
      substrateImagePinningViolations
        "src/Prodbox/Lib/AwsSubstratePlatform.hs"
        "awsSubstrateEnvoyGatewayChartVersion = \"v1.4.4\"\n"
        `shouldSatisfy` (not . null)
    it "checkSubstrateImagePinning fires on a reintroduced per-substrate cert-manager chart pin" $
      substrateImagePinningViolations
        "src/Prodbox/Lib/AwsSubstratePlatform.hs"
        "awsSubstrateCertManagerChartVersion = \"v1.16.2\"\n"
        `shouldSatisfy` (not . null)
    it "checkSubstrateImagePinning does NOT fire on the legitimate lower-layer AWS LB Controller pin" $
      substrateImagePinningViolations
        "src/Prodbox/Lib/AwsSubstratePlatform.hs"
        "awsLoadBalancerControllerChartVersion = \"1.8.4\"\n"
        `shouldBe` []
    it "checkSubstrateImagePinning does NOT fire on the legitimate lower-layer MetalLB pin" $
      substrateImagePinningViolations
        "src/Prodbox/CLI/Rke2.hs"
        "metallbChartVersion = \"0.14.9\"\n"
        `shouldBe` []

  describe
    "Sprint 7.32 graph-derived AWS-substrate platform orchestration"
    $ do
      let steps = Prodbox.Lib.AwsSubstratePlatform.awsSubstratePlatformRuntimeStepDescriptions
      it
        "projects the exact anchored default order, including every final readiness barrier"
        $ steps
          `shouldBe` [ "ensureAwsLoadBalancerControllerRuntime"
                     , "observeAwsClusterBaseReady"
                     , "ensureAwsSubstrateRetainedStorage"
                     , "ensureMinioRuntime SubstrateAws MinioBootstrapPublic"
                     , "observeAwsMinioReady"
                     , "ensureAwsSubstrateVaultRuntime"
                     , "observeAwsVaultWorkloadReady"
                     , "applyEksContainerdMirrorDaemonSet"
                     , "ensureHarborRegistryStorageBackend"
                     , "ensureHarborRegistryRuntime SubstrateAws"
                     , "ensureRegistryStorageBackendEdgeReady"
                     , "applyEksImageMirrorJob"
                     , "ensureRuntimeImageForSubstrate SubstrateAws"
                     , "observeAwsRegistryReady"
                     , "ensureAwsSubstrateCertManagerRuntime"
                     , "observeAwsCertManagerReady"
                     , "ensureGatewayChartReady SubstrateAws"
                     , "observeAwsGatewayPreVaultReady"
                     , "runVaultBootstrapViaDaemonAt"
                     , "observeAwsVaultUnsealedReady"
                     , "ensureAwsSubstrateEnvoyGatewayRuntime"
                     , "observeAwsEnvoyGatewayReady"
                     , "ensurePostgresOperatorRuntime"
                     , "observeAwsPostgresOperatorReady"
                     , "ensureGatewayMinioBootstrap"
                     , "ensureGatewayChartReadyPostVaultAt SubstrateAws"
                     , "observeAwsGatewayFullReady"
                     , "ensureAwsSubstrateAcmeRuntime"
                     , "ensureAdminPublicEdgeRoutes SubstrateAws"
                     ]
      it "derives the typed order from the validated config graph" $ do
        case Prodbox.Lib.AwsSubstratePlatform.buildAwsSubstratePlatformExecutionPlan
          (testValidatedSettings "/tmp/prodbox/.data") of
          Left err -> expectationFailure err
          Right payload ->
            Prodbox.Lib.AwsSubstratePlatform.awsSubstratePlatformStepOrderRespectsGraph
              (Prodbox.Lib.AwsSubstratePlatform.awsPlatformDag payload)
              (Prodbox.Lib.AwsSubstratePlatform.awsPlatformStepOrder payload)
              `shouldBe` Right ()
      it "refuses an inverted AWS dependency before invoking the mutation continuation" $ do
        let baseSettings = testValidatedSettings "/tmp/prodbox/.data"
            baseConfig = validatedConfig baseSettings
            invertAwsLowerLayer node
              | component_id node == ComponentClusterBase =
                  node {depends_on = [orderingOn ComponentMetalLB]}
              | component_id node == ComponentMetalLB = node {depends_on = []}
              | otherwise = node
            invertedSettings =
              baseSettings
                { validatedConfig =
                    baseConfig
                      { components = map invertAwsLowerLayer (components baseConfig)
                      }
                }
        mutationStarted <- newIORef False
        result <-
          Prodbox.Lib.AwsSubstratePlatform.runAwsSubstratePlatformPlanWith
            invertedSettings
            (\_ -> writeIORef mutationStarted True >> pure ExitSuccess)
        result `shouldBe` ExitFailure 1
        readIORef mutationStarted `shouldReturn` False
      it "binds every AWS-owned component group to a production one-shot target" $ do
        let endpoint = Just (Prodbox.Gateway.Client.hostLoopbackGatewayEndpoint 49152)
            expectTarget component =
              case Prodbox.Lib.AwsSubstratePlatform.awsComponentReadinessTarget
                "/tmp/prodbox"
                endpoint
                component of
                Left reason -> expectationFailure (Text.unpack reason)
                Right _ -> pure ()
        case validateComponentGraph defaultComponentGraph of
          Left err -> expectationFailure (show err)
          Right dag ->
            forM_
              [ component
              | component <- componentReconcileOrder dag
              , not
                  ( null
                      (Prodbox.Lib.AwsSubstratePlatform.awsStepsForComponent component)
                  )
              ]
              expectTarget
      it "keeps MetalLB explicitly AWS-inapplicable while LB Controller belongs to cluster base" $ do
        Prodbox.Lib.AwsSubstratePlatform.awsStepsForComponent ComponentMetalLB
          `shouldBe` []
        Prodbox.Lib.AwsSubstratePlatform.awsStepsForComponent ComponentClusterBase
          `shouldBe` [ Prodbox.Lib.AwsSubstratePlatform.StepAwsLoadBalancerControllerRuntime
                     , Prodbox.Lib.AwsSubstratePlatform.StepAwsClusterBaseReady
                     ]
        case Prodbox.Lib.AwsSubstratePlatform.awsComponentReadinessTarget
          "/tmp/prodbox"
          Nothing
          ComponentMetalLB of
          Left _ -> pure ()
          Right _ -> expectationFailure "expected MetalLB readiness to be AWS-inapplicable"
      it "Sprint 7.31: gates the EKS image-mirror Job behind the deep registry->MinIO edge" $ do
        let edgeIndex = elemIndex "ensureRegistryStorageBackendEdgeReady" steps
            mirrorIndex = elemIndex "applyEksImageMirrorJob" steps
            harborIndex = elemIndex "ensureHarborRegistryRuntime SubstrateAws" steps
        harborIndex `shouldSatisfy` (`indexPrecedes` edgeIndex)
        edgeIndex `shouldSatisfy` (`indexPrecedes` mirrorIndex)
      it "Sprint 7.32: delegates EKS image-mirror failures to the shared transient base" $ do
        map
          Prodbox.Lib.EksImageMirror.isRetryableEksImageMirrorFailure
          [ "dial tcp: lookup minio.prodbox.svc.cluster.local: no such host"
          , "temporary failure in name resolution"
          , "UNEXPECTED EOF"
          , "503 SERVICE UNAVAILABLE"
          , "i/o timeout"
          ]
          `shouldBe` replicate 5 True
        Prodbox.Lib.EksImageMirror.isRetryableEksImageMirrorFailure
          "MANIFEST_UNKNOWN: manifest unknown"
          `shouldBe` False
      it
        "places MinIO before the registry group and the containerd mirror before Harbor"
        $ do
          let mirrorIndex = elemIndex "applyEksContainerdMirrorDaemonSet" steps
              minioIndex = elemIndex "ensureMinioRuntime SubstrateAws MinioBootstrapPublic" steps
              harborIndex = elemIndex "ensureHarborRegistryRuntime SubstrateAws" steps
          minioIndex `shouldSatisfy` (`indexPrecedes` mirrorIndex)
          mirrorIndex `shouldSatisfy` (`indexPrecedes` harborIndex)
      it "places retained EBS PV reconciliation before AWS MinIO bootstrap" $ do
        let retainedStorageIndex = elemIndex "ensureAwsSubstrateRetainedStorage" steps
            minioIndex = elemIndex "ensureMinioRuntime SubstrateAws MinioBootstrapPublic" steps
        retainedStorageIndex `shouldSatisfy` (`indexPrecedes` minioIndex)
      it "places MinIO bootstrap before Harbor storage backend (Harbor's S3 lives in MinIO)" $ do
        let minioIndex = elemIndex "ensureMinioRuntime SubstrateAws MinioBootstrapPublic" steps
            backendIndex = elemIndex "ensureHarborRegistryStorageBackend" steps
        minioIndex `shouldSatisfy` (`indexPrecedes` backendIndex)
      it "places the image-mirror Job after Harbor install and before Percona (which pulls from Harbor)" $ do
        let harborIndex = elemIndex "ensureHarborRegistryRuntime SubstrateAws" steps
            mirrorJobIndex = elemIndex "applyEksImageMirrorJob" steps
            perconaIndex = elemIndex "ensurePostgresOperatorRuntime" steps
        harborIndex `shouldSatisfy` (`indexPrecedes` mirrorJobIndex)
        mirrorJobIndex `shouldSatisfy` (`indexPrecedes` perconaIndex)
      it
        "runs gateway pre-Vault, daemon Vault bootstrap, and full-mode convergence in graph phase order"
        $ do
          let preIndex = elemIndex "ensureGatewayChartReady SubstrateAws" steps
              vaultIndex = elemIndex "runVaultBootstrapViaDaemonAt" steps
              fullIndex = elemIndex "ensureGatewayChartReadyPostVaultAt SubstrateAws" steps
          preIndex `shouldSatisfy` (`indexPrecedes` vaultIndex)
          vaultIndex `shouldSatisfy` (`indexPrecedes` fullIndex)
      it "does not retain the redundant steady-state MinIO reinstall" $
        steps `shouldNotContain` ["ensureMinioRuntime SubstrateAws MinioSteadyStateHarbor"]
      it
        "places ACME and AWS admin routes after the gateway-full readiness barrier"
        $ do
          let gatewayReadyIndex = elemIndex "observeAwsGatewayFullReady" steps
              acmeIndex = elemIndex "ensureAwsSubstrateAcmeRuntime" steps
              adminIndex = elemIndex "ensureAdminPublicEdgeRoutes SubstrateAws" steps
          gatewayReadyIndex `shouldSatisfy` (`indexPrecedes` acmeIndex)
          acmeIndex `shouldSatisfy` (`indexPrecedes` adminIndex)
      it "classifies EKS node observations without treating absence as readiness" $ do
        Prodbox.Lib.AwsSubstratePlatform.classifyEksNodesReadiness "node-a:True\nnode-b:true\n"
          `shouldBe` Right ReadinessProbeReady
        Prodbox.Lib.AwsSubstratePlatform.classifyEksNodesReadiness ""
          `shouldBe` Right (ReadinessProbePending "EKS has no observable nodes")
        Prodbox.Lib.AwsSubstratePlatform.classifyEksNodesReadiness "node-a:False\n"
          `shouldBe` Right (ReadinessProbePending "EKS nodes are not Ready: node-a:False")
      it "renders AWS admin routes on the AWS subzone host and issuer" $ do
        let rendered =
              BL8.unpack
                ( encode
                    ( adminPublicEdgeManifestItems
                        (testValidatedSettings "/tmp/prodbox/.data")
                        SubstrateAws
                        "prodbox-test"
                        "prodbox-test"
                        "client-secret"
                    )
                )
        rendered `shouldContain` "\"hostnames\":[\"aws.test.resolvefintech.com\"]"
        -- registry:2 has no web UI, so only the MinIO console admin route is
        -- rendered; the former /harbor OIDC route is gone.
        rendered
          `shouldContain` "\"redirectURL\":\"https://aws.test.resolvefintech.com/minio/oauth2/callback\""
        rendered
          `shouldNotContain` "/harbor/oauth2/callback"
        rendered
          `shouldContain` "\"issuer\":\"https://aws.test.resolvefintech.com/auth/realms/prodbox\""
        rendered
          `shouldNotContain` "\"hostnames\":[\"test.resolvefintech.com\"]"
      it
        "places the union runtime-image build after image-mirror (Harbor populated) and before Percona (Percona pulls from Harbor)"
        $ do
          let mirrorIndex = elemIndex "applyEksImageMirrorJob" steps
              runtimeIndex = elemIndex "ensureRuntimeImageForSubstrate SubstrateAws" steps
              perconaIndex = elemIndex "ensurePostgresOperatorRuntime" steps
          mirrorIndex `shouldSatisfy` (`indexPrecedes` runtimeIndex)
          runtimeIndex `shouldSatisfy` (`indexPrecedes` perconaIndex)

  describe "Sprint 7.32 scoped gateway Service port-forward" $ do
    let spec =
          GatewayPortForward.GatewayServicePortForward
            { GatewayPortForward.gatewayPortForwardNamespace = "gateway"
            , GatewayPortForward.gatewayPortForwardServiceName = "gateway"
            , GatewayPortForward.gatewayPortForwardRemotePort = 8443
            , GatewayPortForward.gatewayPortForwardEnvironment = Nothing
            , GatewayPortForward.gatewayPortForwardWorkingDirectory = Just "/tmp/prodbox"
            }
    it "renders the exact loopback gateway Service port-forward command" $
      renderSubprocess (GatewayPortForward.gatewayServicePortForwardSubprocess spec 49152)
        `shouldBe` "kubectl --namespace gateway port-forward service/gateway 49152:8443"
    it "rejects invalid coordinates and TCP ports before launching kubectl" $ do
      GatewayPortForward.validateGatewayServicePortForward
        spec {GatewayPortForward.gatewayPortForwardRemotePort = 0}
        `shouldSatisfy` isLeft
      GatewayPortForward.validateGatewayServicePortForward
        spec {GatewayPortForward.gatewayPortForwardServiceName = "Gateway_Invalid"}
        `shouldSatisfy` isLeft

  describe "Sprint 7.5.c.ii EKS containerd registry-mirror DaemonSet" $ do
    let cfg = Prodbox.Lib.EksContainerdMirror.defaultProdboxMirrorConfig
        manifest = Prodbox.Lib.EksContainerdMirror.eksContainerdMirrorDaemonSetManifest cfg
        manifestJson = BL8.unpack (encode manifest)
        bootstrapScript = Prodbox.Lib.EksContainerdMirror.eksContainerdMirrorBootstrapScript cfg
    it "default config matches the home-substrate Harbor contract (127.0.0.1:30080 + prodbox/ rewrite)" $ do
      Prodbox.Lib.EksContainerdMirror.mirrorRegistryHostPort cfg `shouldBe` "127.0.0.1:30080"
      Prodbox.Lib.EksContainerdMirror.mirrorTargetEndpoint cfg `shouldBe` "http://127.0.0.1:30080"
      Prodbox.Lib.EksContainerdMirror.mirrorRewritePrefix cfg `shouldBe` "prodbox/"
      Prodbox.Lib.EksContainerdMirror.mirrorNamespace cfg `shouldBe` "kube-system"
      Prodbox.Lib.EksContainerdMirror.mirrorDaemonSetName cfg `shouldBe` "prodbox-containerd-mirror"
    it "DaemonSet manifest declares apps/v1 DaemonSet in kube-system with sprint label" $ do
      manifestJson `shouldContain` "\"apiVersion\":\"apps/v1\""
      manifestJson `shouldContain` "\"kind\":\"DaemonSet\""
      manifestJson `shouldContain` "\"namespace\":\"kube-system\""
      manifestJson `shouldContain` "\"name\":\"prodbox-containerd-mirror\""
      manifestJson `shouldContain` "\"prodbox.io/sprint\":\"7.5.c.ii\""
    it "pod spec runs with hostNetwork + hostPID + a privileged init container" $ do
      manifestJson `shouldContain` "\"hostNetwork\":true"
      manifestJson `shouldContain` "\"hostPID\":true"
      manifestJson `shouldContain` "\"privileged\":true"
    it
      "mounts the host /etc directory as a hostPath volume so the init container can write containerd config"
      $ do
        manifestJson `shouldContain` "\"hostPath\":{\"path\":\"/etc\",\"type\":\"Directory\"}"
        manifestJson `shouldContain` "\"mountPath\":\"/host/etc\""
    it "bootstrap script writes the hosts.toml drop-in at the canonical containerd config path" $ do
      bootstrapScript `shouldContain` "/host/etc/containerd/certs.d/${HOST}"
      bootstrapScript `shouldContain` "hosts.toml"
      bootstrapScript `shouldContain` "127.0.0.1:30080"
    it "bootstrap script enables config_path in the main containerd config when missing" $ do
      bootstrapScript `shouldContain` "config_path = \"/etc/containerd/certs.d\""
      bootstrapScript `shouldContain` "plugins.\"io.containerd.grpc.v1.cri\".registry"
    it "bootstrap script restarts containerd via nsenter only when something changed (idempotence)" $ do
      bootstrapScript `shouldContain` "RESTART_NEEDED=0"
      bootstrapScript `shouldContain` "RESTART_NEEDED=1"
      bootstrapScript `shouldContain` "nsenter --target 1"
      bootstrapScript `shouldContain` "systemctl restart containerd"
      bootstrapScript `shouldContain` "no restart"
    it "hosts.toml drop-in declares pull+resolve capabilities + HTTP skip_verify for in-cluster Harbor" $ do
      let hostsToml = Prodbox.Lib.EksContainerdMirror.eksContainerdMirrorBootstrapScript cfg
      hostsToml `shouldContain` "capabilities = [\"pull\", \"resolve\"]"
      hostsToml `shouldContain` "skip_verify = true"

  describe "Sprint 4.31 substrate-aware MinIO chart values" $ do
    -- MinIO backs Harbor, so it always uses the public (bootstrap-exception)
    -- image regardless of the requested image source — never the Harbor mirror,
    -- which would deadlock a non-surging StatefulSet. Only storage varies.
    it "Home substrate: manual StorageClass + 20Gi, always the public image (never Harbor)" $ do
      let bootstrapArgs = renderMinioChartArgs SubstrateHomeLocal MinioBootstrapPublic
          steadyArgs = renderMinioChartArgs SubstrateHomeLocal MinioSteadyStateHarbor
      consecutivePair bootstrapArgs "storage.className=manual" `shouldBe` True
      consecutivePair bootstrapArgs "storage.size=20Gi" `shouldBe` True
      consecutivePair bootstrapArgs "storage.className=gp2" `shouldBe` False
      any ("image.repository=" `isPrefixOf`) bootstrapArgs `shouldBe` True
      -- Sprint 7.25: the STATIC MinIO root credential is injected directly so
      -- the chart needs no Vault init container (MinIO is cluster-only).
      consecutivePair bootstrapArgs ("rootUser=" ++ minioRootUser) `shouldBe` True
      consecutivePair bootstrapArgs ("rootPassword=" ++ minioRootPassword) `shouldBe` True
      -- The image source is ignored: steady-state renders identically to
      -- bootstrap, and never the Harbor-mirrored registry.
      steadyArgs `shouldBe` bootstrapArgs
      any ("image.repository=127.0.0.1:30080" `isPrefixOf`) steadyArgs `shouldBe` False
    it "AWS substrate: manual retained EBS class + 20Gi, always the public image (never Harbor)" $ do
      let bootstrapArgs = renderMinioChartArgs SubstrateAws MinioBootstrapPublic
          steadyArgs = renderMinioChartArgs SubstrateAws MinioSteadyStateHarbor
      consecutivePair bootstrapArgs "storage.className=manual" `shouldBe` True
      consecutivePair bootstrapArgs "storage.size=20Gi" `shouldBe` True
      consecutivePair bootstrapArgs "storage.className=gp2" `shouldBe` False
      steadyArgs `shouldBe` bootstrapArgs
      any ("image.repository=127.0.0.1:30080" `isPrefixOf`) steadyArgs `shouldBe` False

  describe "Sprint 7.6 AWS harness orphan-safety (Sprint 4.16 source-of-truth pure layer)" $ do
    it
      "Scenario A — direct teardown footgun: aws-eks present → residue refuses with eks-destroy hint"
      $ do
        let perRun = absentPerRunStatuses {perRunAwsEksTest = residuePresentFor "aws-eks-test"}
            residue = categorizePulumiResidue perRun Residue.ResidueAbsent
        residue `shouldBe` [("aws-eks", "prodbox aws stack eks destroy --yes")]
        let refusal = renderPulumiResidueRefusal residue
        refusal `shouldContain` "aws-eks → prodbox aws stack eks destroy --yes"
        refusal `shouldContain` "--allow-pulumi-residue"
    it "Scenario B — interrupted suite: no live residue → list empty so cleanup proceeds" $ do
      let residue = categorizePulumiResidue absentPerRunStatuses Residue.ResidueAbsent
      residue `shouldBe` []
    it "Scenario C — partial residue: aws-eks-subzone + aws-test present → refusal lists both" $ do
      let perRun =
            absentPerRunStatuses
              { perRunAwsEksSubzone = residuePresentFor "aws-eks-subzone"
              , perRunAwsTest = residuePresentFor "aws-test"
              }
          residue = categorizePulumiResidue perRun Residue.ResidueAbsent
      residue
        `shouldBe` [ ("aws-eks-subzone", "prodbox aws stack aws-subzone destroy --yes")
                   , ("aws-test", "prodbox aws stack test destroy --yes")
                   ]
    it "Scenario D — SES present: aws-ses live → refusal names aws-ses-destroy as recovery" $ do
      let residue = categorizePulumiResidue absentPerRunStatuses (residuePresentFor "aws-ses")
      residue `shouldBe` [("aws-ses", "prodbox aws stack aws-ses destroy --yes")]
      let refusal = renderPulumiResidueRefusal residue
      refusal `shouldContain` "aws-ses → prodbox aws stack aws-ses destroy --yes"
    it "Scenario all-four — every stack present → all four canonical destroy commands in order" $ do
      let perRun =
            PerRunResidueStatuses
              { perRunAwsEksTest = residuePresentFor "aws-eks-test"
              , perRunAwsEksSubzone = residuePresentFor "aws-eks-subzone"
              , perRunAwsTest = residuePresentFor "aws-test"
              }
          residue = categorizePulumiResidue perRun (residuePresentFor "aws-ses")
      residue
        `shouldBe` [ ("aws-eks", "prodbox aws stack eks destroy --yes")
                   , ("aws-eks-subzone", "prodbox aws stack aws-subzone destroy --yes")
                   , ("aws-test", "prodbox aws stack test destroy --yes")
                   , ("aws-ses", "prodbox aws stack aws-ses destroy --yes")
                   ]
    it "Sprint 4.19 unreachable per-run: MinIO down → gate refuses (cannot confirm gone)" $ do
      let unreachable =
            Residue.ResidueUnreachable
              (Residue.ResidueBackendMinioUnreachable "MinIO unreachable")
          perRun =
            PerRunResidueStatuses
              { perRunAwsEksTest = unreachable
              , perRunAwsEksSubzone = unreachable
              , perRunAwsTest = unreachable
              }
          residue = categorizePulumiResidue perRun Residue.ResidueAbsent
      residue
        `shouldBe` [ ("aws-eks", "prodbox aws stack eks destroy --yes")
                   , ("aws-eks-subzone", "prodbox aws stack aws-subzone destroy --yes")
                   , ("aws-test", "prodbox aws stack test destroy --yes")
                   ]
    it "Sprint 4.16 unreachable long-lived: S3 down → aws-ses treated as still-present (doctrine §3)" $ do
      let unreachable =
            Residue.ResidueUnreachable
              (Residue.ResidueBackendS3Unreachable "admin credentials missing")
          residue = categorizePulumiResidue absentPerRunStatuses unreachable
      residue `shouldBe` [("aws-ses", "prodbox aws stack aws-ses destroy --yes")]

  describe "Sprint 4.20 managed-resource registry facts" $ do
    it "the per-run class includes Pulumi stacks and dynamic Pulsar topics" $
      ResourceClass.resourceNamesOfClass ResourceClass.PerRun
        `shouldBe` ["aws-eks", "aws-eks-subzone", "aws-test", "pulsar-topics-per-run"]

    it
      "the long-lived class includes aws-ses, retained EBS volumes, public-edge cert, and dynamic Pulsar topics"
      $ ResourceClass.resourceNamesOfClass ResourceClass.LongLived
        `shouldBe` ["aws-ses", "aws-ebs-volumes", "public-edge-tls", "pulsar-topics-long-lived"]

    it "the operational class registers the SES role, IAM user, and aws.* config block" $
      ResourceClass.resourceNamesOfClass ResourceClass.Operational
        `shouldBe` [ "operational-aws-ses-lease-role"
                   , "operational-iam-user"
                   , "operational-aws-config"
                   ]

    it "perRunStackNames is derived from the registry (matches the prior literal)" $
      perRunStackNames `shouldBe` ["aws-eks", "aws-eks-subzone", "aws-test"]

    it "longLivedResourceNames is derived from the registry" $
      longLivedResourceNames
        `shouldBe` ["aws-ses", "aws-ebs-volumes", "public-edge-tls", "pulsar-topics-long-lived"]

    it "derived stack/resource-name lists match their owning SSoTs" $ do
      perRunStackNames `shouldBe` StackDescriptor.perRunStackDescriptorNames
      longLivedResourceNames `shouldBe` ResourceClass.resourceNamesOfClass ResourceClass.LongLived

    it "Sprint 4.22 renderRegisteredResourcesMarkdown renders every registered resource + class" $ do
      let rendered =
            ResourceClass.renderRegisteredResourcesMarkdown ResourceClass.resourceLifecycleClasses
      rendered `shouldContain` "| Resource | Lifecycle class |"
      rendered `shouldContain` "| `aws-eks` | PerRun |"
      rendered `shouldContain` "| `aws-ses` | LongLived |"
      rendered `shouldContain` "| `aws-ebs-volumes` | LongLived |"
      rendered `shouldContain` "| `public-edge-tls` | LongLived |"
      rendered `shouldContain` "| `pulsar-topics-per-run` | PerRun |"
      rendered `shouldContain` "| `pulsar-topics-long-lived` | LongLived |"
      rendered `shouldContain` "| `operational-iam-user` | Operational |"
      rendered `shouldContain` "| `operational-aws-config` | Operational |"

  describe "Sprint 4.24 retained public-edge TLS certificate managed resource" $ do
    it "registers public-edge-tls as a LongLived managed resource" $ do
      map ResourceRegistry.resourceName ResourceRegistry.longLivedManagedResources
        `shouldBe` ["public-edge-tls"]
      map ResourceRegistry.resourceClass ResourceRegistry.longLivedManagedResources
        `shouldBe` [ResourceClass.LongLived]

    it "the registered cert resource name matches the LiveResidue constant" $
      map ResourceRegistry.resourceName ResourceRegistry.longLivedManagedResources
        `shouldBe` [LiveResidue.publicEdgeTlsResourceName]

    it "the retention prefix scopes the S3 key namespace" $
      LiveResidue.publicEdgeTlsRetentionPrefix `shouldBe` "public-edge-tls/"

    it "discover: retained objects present -> ResiduePresent" $
      Residue.isResiduePresent
        ( LiveResidue.residueStatusFromObjectListing
            LiveResidue.publicEdgeTlsResourceName
            (Right ["public-edge-tls/home-local/test.resolvefintech.com/tls.crt"])
        )
        `shouldBe` True

    it "discover: no retained objects -> ResidueAbsent" $
      LiveResidue.residueStatusFromObjectListing
        LiveResidue.publicEdgeTlsResourceName
        (Right [])
        `shouldBe` Residue.ResidueAbsent

    it "discover: missing long-lived bucket -> ResidueAbsent (authoritative nothing-to-destroy)" $
      LiveResidue.residueStatusFromObjectListing
        LiveResidue.publicEdgeTlsResourceName
        ( Left
            "An error occurred (NoSuchBucket) when calling the ListObjectsV2 operation: \
            \The specified bucket does not exist"
        )
        `shouldBe` Residue.ResidueAbsent

    it "discover: unreadable backend -> ResidueUnreachable and blocks teardown (soundness)" $ do
      let status =
            LiveResidue.residueStatusFromObjectListing
              LiveResidue.publicEdgeTlsResourceName
              (Left "connection timed out reaching s3.amazonaws.com")
      Residue.isResidueUnreachable status `shouldBe` True
      Residue.residueBlocksTeardownGate status `shouldBe` True

    it "parseObjectKeysPayload decodes the list-objects-v2 --query json shape" $ do
      parseObjectKeysPayload "null" `shouldBe` Right []
      parseObjectKeysPayload "[]" `shouldBe` Right []
      parseObjectKeysPayload
        "[\"public-edge-tls/home-local/test/tls.crt\",\"public-edge-tls/aws/foo/tls.crt\"]"
        `shouldBe` Right
          [ "public-edge-tls/home-local/test/tls.crt"
          , "public-edge-tls/aws/foo/tls.crt"
          ]

    it "Sprint 4.33 renders long-lived object lookups as unobservable when Vault is sealed" $ do
      let rendered = renderLongLivedObjectVaultGateBlock VaultGateBlockSealed
      rendered `shouldContain` "vault_status=sealed"
      rendered `shouldContain` "component=long-lived-object"
      rendered `shouldContain` "result=unobservable"
      rendered `shouldNotContain` "NoSuchKey"
      rendered `shouldNotContain` "public-edge-tls"

  describe "ZeroSSL ACME ClusterIssuer + cert retention key scheme" $ do
    let settings = testValidatedSettings "/tmp"
        zoneId = "ZHOSTEDZONE"
        baseConfig = validatedConfig settings
        -- Sprint 7.15: EAB references are SecretRef.Vault into secret/acme/eab.
        -- The resolved key ID is supplied separately (host-resolved from
        -- Vault); the HMAC key is materialized in-cluster, never rendered.
        eabSettings =
          settings
            { validatedConfig =
                baseConfig
                  { acme =
                      (acme baseConfig)
                        { eab_key_id =
                            Just (SecretRefVault (VaultSecretRef "secret" "acme/eab" "key_id"))
                        , eab_hmac_key =
                            Just (SecretRefVault (VaultSecretRef "secret" "acme/eab" "hmac_key"))
                        }
                  }
            }
        noEabSettings =
          settings
            { validatedConfig =
                baseConfig
                  { acme =
                      (acme baseConfig)
                        { eab_key_id = Nothing
                        , eab_hmac_key = Nothing
                        }
                  }
            }
        resolvedKeyId = Just "test-eab-key-id"

    it "the issuer spec renders acme.server (ZeroSSL) and the ZeroSSL account key" $ do
      let rendered = BL8.unpack (encode (acmeClusterIssuerSpec settings resolvedKeyId zoneId))
      rendered `shouldContain` "https://acme.zerossl.com/v2/DV90"
      rendered `shouldContain` "zerossl-account-key"

    it "the issuer spec references the DNS-01 Route 53 solver secret and hosted zone" $ do
      let rendered = BL8.unpack (encode (acmeClusterIssuerSpec settings resolvedKeyId zoneId))
      rendered `shouldContain` "route53-credentials"
      rendered `shouldContain` "ZHOSTEDZONE"

    it "the issuer spec includes the ZeroSSL external account binding when configured" $ do
      let rendered = BL8.unpack (encode (acmeClusterIssuerSpec eabSettings resolvedKeyId zoneId))
      rendered `shouldContain` "externalAccountBinding"
      -- The EAB key ID is the host-resolved (Vault-sourced) value, inline.
      rendered `shouldContain` "test-eab-key-id"
      -- The HMAC key is materialized in-cluster; it never appears in the spec,
      -- only the keySecretRef to the materialized Secret.
      rendered `shouldContain` "acme-eab-credentials"

    it "the issuer spec omits the external account binding when EAB is not configured" $ do
      let rendered = BL8.unpack (encode (acmeClusterIssuerSpec noEabSettings Nothing zoneId))
      rendered `shouldNotContain` "externalAccountBinding"

    it "the issuer spec omits the binding when EAB is configured but the key ID is unresolved" $ do
      -- A sealed Vault yields an unresolved key ID; the binding is then omitted
      -- (fail-closed) rather than rendered without its key ID.
      let rendered = BL8.unpack (encode (acmeClusterIssuerSpec eabSettings Nothing zoneId))
      rendered `shouldNotContain` "externalAccountBinding"

    it "acmeRuntimeManifestWith renders the EAB materializer Job and the single issuer" $ do
      let manifests = acmeRuntimeManifestWith SubstrateHomeLocal eabSettings zoneId resolvedKeyId "pid" "lbl"
          rendered = BL8.unpack (encode manifests)
      clusterIssuerNamesIn manifests `shouldBe` [publicEdgeClusterIssuerName]
      -- The EAB HMAC key is materialized by a Vault-login Job, not rendered
      -- as inline plaintext stringData.
      rendered `shouldContain` "acme-eab-secret-materializer"
      rendered `shouldContain` "vault-materialized"
      rendered `shouldNotContain` "test-eab-hmac-key"

    it "acmeRuntimeManifestWith omits the EAB materializer when EAB is not configured" $ do
      let rendered =
            BL8.unpack
              (encode (acmeRuntimeManifestWith SubstrateHomeLocal noEabSettings zoneId Nothing "pid" "lbl"))
      rendered `shouldNotContain` "acme-eab-secret-materializer"

    it "the public-edge ClusterIssuer name is the ZeroSSL cert-manager issuer" $
      publicEdgeClusterIssuerName `shouldBe` "zerossl-dns01"

    it "the substrate-scoped retention key namespaces the production cert per substrate + fqdn" $ do
      publicEdgeTlsRetentionKey SubstrateHomeLocal "test.resolvefintech.com"
        `shouldBe` "public-edge-tls/home-local/test.resolvefintech.com"
      publicEdgeTlsRetentionKey SubstrateAws "aws.test.resolvefintech.com"
        `shouldBe` "public-edge-tls/aws/aws.test.resolvefintech.com"

  describe "public-edge typed preserve outcome" $ do
    it "classifyPublicEdgePreserve distinguishes retain / in-flight / nothing (no silent absent)" $ do
      classifyPublicEdgePreserve (Just (object [])) Nothing
        `shouldBe` PreservedToRetentionStore
      classifyPublicEdgePreserve (Just (object [])) (Just (object []))
        `shouldBe` PreservedToRetentionStore
      classifyPublicEdgePreserve Nothing (Just (object []))
        `shouldBe` PreserveDeferredIssuanceInFlight
      classifyPublicEdgePreserve Nothing Nothing
        `shouldBe` PreserveNothingToRetain

    it "renderPublicEdgePreserveOutcome surfaces the absent states (no silent success)" $ do
      renderPublicEdgePreserveOutcome PreserveNothingToRetain
        `shouldContain` "fresh order"
      renderPublicEdgePreserveOutcome PreserveDeferredIssuanceInFlight
        `shouldContain` "mid-issuance"
      renderPublicEdgePreserveOutcome PreservedToRetentionStore
        `shouldContain` "retained"

    -- Sprint 8.8: a restored public-edge cert Secret must carry the
    -- cert-manager.io/* adoption annotations, else cert-manager re-issues
    -- (re-ordering against ZeroSSL) on every rebuild instead of adopting it.
    it "certManagerAdoptionAnnotations preserves only the cert-manager.io/* annotations" $ do
      let secretValue =
            object
              [ "metadata"
                  .= object
                    [ "name" .= ("public-edge-tls" :: Text.Text)
                    , "annotations"
                        .= object
                          [ "cert-manager.io/certificate-name" .= ("public-edge-tls" :: Text.Text)
                          , "cert-manager.io/issuer-name" .= ("zerossl-dns01" :: Text.Text)
                          , "cert-manager.io/issuer-kind" .= ("ClusterIssuer" :: Text.Text)
                          , "kubectl.kubernetes.io/last-applied-configuration" .= ("{}" :: Text.Text)
                          ]
                    ]
              , "type" .= ("kubernetes.io/tls" :: Text.Text)
              , "data" .= object ["tls.crt" .= ("Y3J0" :: Text.Text)]
              ]
      certManagerAdoptionAnnotations secretValue
        `shouldBe` object
          [ "cert-manager.io/certificate-name" .= ("public-edge-tls" :: Text.Text)
          , "cert-manager.io/issuer-name" .= ("zerossl-dns01" :: Text.Text)
          , "cert-manager.io/issuer-kind" .= ("ClusterIssuer" :: Text.Text)
          ]
    it "certManagerAdoptionAnnotations returns an empty object when there are no annotations" $
      certManagerAdoptionAnnotations (object ["metadata" .= object ["name" .= ("x" :: Text.Text)]])
        `shouldBe` object []

  describe "Sprint 4.18 forbidDotProdboxState lint" $ do
    -- This block verifies the lint's regression-resistance contract end-to-end
    -- by writing a synthetic Haskell module containing a `.prodbox-state/`
    -- string literal into a temp directory shaped like the repo and running
    -- the lint against it. The lint must (a) fire on the offending literal
    -- and (b) skip its own self-reference path. After Sprint 3.13 chunk 16
    -- the scan was broadened from `.secrets.json` to the whole
    -- `.prodbox-state/` prefix because every cache under it is closed.
    it "fires on `.prodbox-state/` string literal in src/-shaped Haskell" $
      withSystemTempDirectory "prodbox-forbid-dot-state" $ \tempRoot -> do
        let srcDir = tempRoot </> "src" </> "Prodbox" </> "Probe"
        createDirectoryIfMissing True srcDir
        writeFile
          (srcDir </> "Hit.hs")
          "module Prodbox.Probe.Hit where\n\
          \\n\
          \cachePath :: String\n\
          \cachePath = \".prodbox-state/charts/keycloak/whatever.json\"\n"
        violations <- Prodbox.CheckCode.checkForbidDotProdboxState tempRoot
        assertExactlyOne violations $ \violation -> do
          violation `shouldContain` "src/Prodbox/Probe/Hit.hs"
          violation `shouldContain` ".prodbox-state/"

    it "fires on the broader `.prodbox-state/` prefix (any subpath, not just .secrets.json)" $
      withSystemTempDirectory "prodbox-forbid-dot-state-broader" $ \tempRoot -> do
        let srcDir = tempRoot </> "src" </> "Prodbox" </> "Probe"
        createDirectoryIfMissing True srcDir
        writeFile
          (srcDir </> "EventKeys.hs")
          "module Prodbox.Probe.EventKeys where\n\
          \\n\
          \eventKeysCache :: String\n\
          \eventKeysCache = \".prodbox-state/gateway/.gateway-event-keys.json\"\n"
        violations <- Prodbox.CheckCode.checkForbidDotProdboxState tempRoot
        assertExactlyOne violations $ \violation ->
          violation `shouldContain` ".prodbox-state/"

    it "leaves comments / docstrings that mention `.prodbox-state/` alone" $
      withSystemTempDirectory "prodbox-forbid-dot-state-comments" $ \tempRoot -> do
        let srcDir = tempRoot </> "src" </> "Prodbox" </> "Probe"
        createDirectoryIfMissing True srcDir
        writeFile
          (srcDir </> "OnlyComment.hs")
          "module Prodbox.Probe.OnlyComment where\n\
          \\n\
          \-- A doc comment mentioning .prodbox-state/whatever for historical context only.\n\
          \harmless :: String\n\
          \harmless = \"nothing to see\"\n"
        violations <- Prodbox.CheckCode.checkForbidDotProdboxState tempRoot
        violations `shouldBe` []

    it "returns no violations on the current repo (regression-resistance baseline)" $ do
      repoRoot <- getCurrentDirectory
      violations <- Prodbox.CheckCode.checkForbidDotProdboxState repoRoot
      violations `shouldBe` []

  describe "Sprint 4.22 create-call-site coverage lint" $ do
    let registeredNames =
          ResourceClass.resourceNamesOfClass ResourceClass.PerRun
            ++ ResourceClass.resourceNamesOfClass ResourceClass.LongLived
        commandWithKnownConstructors =
          unlines
            [ "data PulumiCommand"
            , "  = PulumiEksResources PlanOptions"
            , "  | PulumiTestResources PlanOptions"
            , "  | PulumiAwsSubzoneResources PlanOptions"
            , "  | PulumiAwsSesResources PlanOptions"
            ]
        commandWithBogusConstructor =
          commandWithKnownConstructors
            ++ unlines ["  | PulumiFooResources PlanOptions"]
        contentsWithCreateUser =
          unlines
            [ "      [ \"iam\""
            , "      , \"create-user\""
            , "      , \"--user-name\""
            , "      ]"
            ]
        contentsWithoutVerbs =
          unlines
            [ "      [ \"sts\""
            , "      , \"get-caller-identity\""
            , "      ]"
            ]

    it "real registered names + the 4 known Pulumi constructors yields no violations" $
      pulumiCreateSiteViolations registeredNames commandWithKnownConstructors `shouldBe` []

    it "a bogus PulumiFooResources constructor yields exactly one violation naming it" $ do
      let violations =
            pulumiCreateSiteViolations registeredNames commandWithBogusConstructor
      assertExactlyOne violations $ \violation ->
        violation `shouldContain` "PulumiFooResources"

    it "a mapped stack absent from the registered names yields a violation naming that stack" $ do
      let registeredWithoutSes = filter (/= "aws-ses") registeredNames
          violations =
            pulumiCreateSiteViolations registeredWithoutSes commandWithKnownConstructors
      assertExactlyOne violations $ \violation ->
        violation `shouldContain` "aws-ses"

    it "awsCreateSiteViolations allows the owner module src/Prodbox/Aws.hs" $
      awsCreateSiteViolations "src/Prodbox/Aws.hs" contentsWithCreateUser `shouldBe` []

    it "awsCreateSiteViolations flags an IAM create verb outside the owner module" $ do
      let violations =
            awsCreateSiteViolations "src/Prodbox/Other.hs" contentsWithCreateUser
      assertExactlyOne violations $ \violation -> do
        violation `shouldContain` "create-user"
        violation `shouldContain` "src/Prodbox/Aws.hs"

    it "awsCreateSiteViolations ignores a non-owner module with no AWS create verbs" $
      awsCreateSiteViolations "src/Prodbox/Other.hs" contentsWithoutVerbs `shouldBe` []

    it "iamCreateSiteViolations remains a back-compat alias of awsCreateSiteViolations" $
      iamCreateSiteViolations "src/Prodbox/Other.hs" contentsWithCreateUser
        `shouldBe` awsCreateSiteViolations "src/Prodbox/Other.hs" contentsWithCreateUser

    it "Sprint 4.27 flags a non-IAM create verb (create-bucket) outside its owners" $ do
      let contentsWithCreateBucket =
            unlines
              [ "      [ \"s3api\""
              , "      , \"create-bucket\""
              , "      , \"--bucket\""
              , "      ]"
              ]
          violations =
            awsCreateSiteViolations "src/Prodbox/Other.hs" contentsWithCreateBucket
      assertExactlyOne violations $ \violation ->
        violation `shouldContain` "create-bucket"

    it "Sprint 4.27 awsCreateSiteViolations allows create-bucket in its owner modules" $ do
      let contentsWithCreateBucket =
            unlines ["      , \"create-bucket\""]
      awsCreateSiteViolations "src/Prodbox/Infra/LongLivedPulumiBackend.hs" contentsWithCreateBucket
        `shouldBe` []
      awsCreateSiteViolations "src/Prodbox/Infra/MinioBackend.hs" contentsWithCreateBucket
        `shouldBe` []
      awsCreateSiteViolations "src/Prodbox/Minio/ObjectStore.hs" contentsWithCreateBucket
        `shouldBe` []

    it "Sprint 4.27 the Route 53 capability probe (create-hosted-zone) is carved out, never flagged" $ do
      let contentsWithCreateHostedZone =
            unlines
              [ "      [ \"route53\""
              , "      , \"create-hosted-zone\""
              , "      , \"--name\""
              , "      ]"
              ]
      "create-hosted-zone" `shouldSatisfy` (`elem` awsCreateProbeVerbs)
      ("create-hosted-zone" `elem` map fst awsCreateVerbs) `shouldBe` False
      awsCreateSiteViolations "src/Prodbox/EffectInterpreter.hs" contentsWithCreateHostedZone
        `shouldBe` []
      awsCreateSiteViolations "src/Prodbox/TestValidation.hs" contentsWithCreateHostedZone
        `shouldBe` []

    it "Sprint 4.27 awsCreateSiteViolations returns no violations on the current repo tree" $ do
      repoRoot <- getCurrentDirectory
      violations <- Prodbox.CheckCode.checkCreateCallSiteCoverage repoRoot
      violations `shouldBe` []

  describe "Sprint 4.27 StackDescriptor SSoT" $ do
    it
      "per-run descriptor names equal the prior Pulumi-stack literal and are registered PerRun resources"
      $ do
        StackDescriptor.perRunStackDescriptorNames `shouldBe` ["aws-eks", "aws-eks-subzone", "aws-test"]
        forM_ StackDescriptor.perRunStackDescriptorNames $ \name ->
          ResourceClass.resourceLifecycleClasses `shouldContain` [(name, ResourceClass.PerRun)]

    it "perRunStackNames is derived from the StackDescriptor SSoT" $
      perRunStackNames `shouldBe` StackDescriptor.perRunStackDescriptorNames

    it "every descriptor registry name is in the managed-resource registry with the matching class" $
      [ (StackDescriptor.stackRegistryName d, StackDescriptor.stackLifecycleClass d)
      | d <- StackDescriptor.stackDescriptors
      ]
        `shouldBe` [ ("aws-eks", ResourceClass.PerRun)
                   , ("aws-eks-subzone", ResourceClass.PerRun)
                   , ("aws-test", ResourceClass.PerRun)
                   , ("aws-ses", ResourceClass.LongLived)
                   ]

    it "the resources/destroy CLI verbs derive from the verb stem" $ do
      map StackDescriptor.stackResourcesCliVerb StackDescriptor.stackDescriptors
        `shouldBe` ["eks-resources", "aws-subzone-resources", "test-resources", "aws-ses-resources"]
      map StackDescriptor.stackDestroyCliVerb StackDescriptor.stackDescriptors
        `shouldBe` ["eks-destroy", "aws-subzone-destroy", "test-destroy", "aws-ses-destroy"]

    it "the project subdirs derive from the descriptors" $
      StackDescriptor.stackProjectSubdirs
        `shouldBe` ["aws-eks", "aws-eks-subzone", "aws-test", "aws-ses"]

    it "the EKS registry name and Pulumi stack id differ as recorded" $ do
      case find ((== "aws-eks") . StackDescriptor.stackRegistryName) StackDescriptor.stackDescriptors of
        Nothing -> expectationFailure "expected aws-eks stack descriptor"
        Just eks -> StackDescriptor.stackPulumiStackId eks `shouldBe` "aws-eks-test"

    it "renderStackCommandSurfaceMarkdown renders a header and every descriptor row" $ do
      let rendered =
            StackDescriptor.renderStackCommandSurfaceMarkdown StackDescriptor.stackDescriptors
      rendered `shouldContain` "| Registry name | Pulumi stack id |"
      rendered
        `shouldContain` "| `aws-eks` | `aws-eks-test` | `pulumi/aws-eks/` | `prodbox aws stack eks reconcile` |"
      rendered
        `shouldContain` "| `aws-ses` | `aws-ses` | `pulumi/aws-ses/` | `prodbox aws stack aws-ses reconcile` |"

  describe "Sprint 0.9 documentation-harmony pure helpers" $ do
    describe "stripFencedCodeBlocks" $ do
      it "drops lines inside a fenced block and the fence lines themselves" $
        stripFencedCodeBlocks
          [ "outside before"
          , "```markdown"
          , "<!-- prodbox:command-registry:start -->"
          , "<!-- prodbox:command-registry:end -->"
          , "```"
          , "outside after"
          ]
          `shouldBe` ["outside before", "outside after"]

      it "leaves content alone when there is no fence" $
        stripFencedCodeBlocks ["a", "b", "c"] `shouldBe` ["a", "b", "c"]

      it "treats an indented fence opener as a fence" $
        stripFencedCodeBlocks ["keep", "  ```", "hidden", "  ```", "keep2"]
          `shouldBe` ["keep", "keep2"]

    describe "stripInlineCodeSpans" $ do
      it "blanks a backtick-delimited inline-code span" $
        stripInlineCodeSpans "the `<!-- prodbox:foo:start -->` marker example"
          `shouldNotContain` "prodbox:foo:start"

      it "leaves text with no backticks unchanged" $
        stripInlineCodeSpans "plain prose with no code"
          `shouldBe` "plain prose with no code"

      it "blanks an inline-code link example so it is not surfaced" $
        stripInlineCodeSpans "every relative `[text](path#anchor)` link"
          `shouldNotContain` "](path#anchor)"

    describe "prodboxMarkerKeysPresent" $ do
      it "finds a real Markdown marker pair outside fences/inline code" $
        prodboxMarkerKeysPresent
          ( unlines
              [ "intro"
              , "<!-- prodbox:command-registry.markdown:start -->"
              , "table"
              , "<!-- prodbox:command-registry.markdown:end -->"
              ]
          )
          `shouldBe` ["command-registry.markdown"]

      it "ignores EXAMPLE markers inside a fenced markdown block" $
        prodboxMarkerKeysPresent
          ( unlines
              [ "```markdown"
              , "<!-- prodbox:command-registry:start -->"
              , "<!-- prodbox:command-registry:end -->"
              , "```"
              ]
          )
          `shouldBe` []

      it "ignores marker placeholders quoted inline as code spans" $
        prodboxMarkerKeysPresent
          "| Markdown | `<!-- prodbox:<key>:start -->` | `<!-- prodbox:<key>:end -->` |"
          `shouldBe` []

      it "finds a Helm template marker key" $
        prodboxMarkerKeysPresent "{{/* prodbox:route-registry:start */}}"
          `shouldBe` ["route-registry"]

      it "finds a YAML-comment marker key" $
        prodboxMarkerKeysPresent "# prodbox:route-registry:end"
          `shouldBe` ["route-registry"]

      it "the literal <key> placeholder is never reported as a real key" $
        prodboxMarkerKeysPresent "<!-- prodbox:<key>:start -->"
          `shouldBe` []

    describe "parseGeneratedSectionsField" $ do
      it "returns Nothing when the field is absent" $
        parseGeneratedSectionsField "# Title\n\n**Status**: Reference only\n"
          `shouldBe` Nothing

      it "parses `none` to the empty declared set" $
        parseGeneratedSectionsField "**Generated sections**: none\n"
          `shouldBe` Just []

      it "parses a single backtick-quoted key" $
        parseGeneratedSectionsField "**Generated sections**: `command-registry.markdown`\n"
          `shouldBe` Just ["command-registry.markdown"]

      it "parses a comma-separated key list" $
        parseGeneratedSectionsField "**Generated sections**: foo, bar.baz\n"
          `shouldBe` Just ["foo", "bar.baz"]

      it "stops at a parenthesised annotation after `none`" $
        parseGeneratedSectionsField
          "**Generated sections**: none (the matrices are hand-maintained today)\n"
          `shouldBe` Just []

    describe "generatedSectionsReconcilerViolations" $ do
      it "agrees: registered + declared + marked yields no violations" $
        generatedSectionsReconcilerViolations
          "documents/cli/commands.md"
          ["command-registry.markdown"]
          ["command-registry.markdown"]
          ["command-registry.markdown"]
          ["command-registry.markdown", "resource-lifecycle-classes"]
          `shouldBe` []

      it "agrees: a clean `none` doc with no markers and no registry entry" $
        generatedSectionsReconcilerViolations "documents/x.md" [] [] [] ["command-registry.markdown"]
          `shouldBe` []

      it "flags a registry key that the metadata does not declare" $ do
        -- declared=[] while the key is both registered AND physically
        -- marked surfaces two distinct legs: the registry-undeclared leg
        -- (`does not declare`) and the marker-undeclared leg (`but does
        -- not declare`). Both are correct: metadata must declare the key.
        let violations =
              generatedSectionsReconcilerViolations
                "documents/cli/commands.md"
                []
                ["command-registry.markdown"]
                ["command-registry.markdown"]
                ["command-registry.markdown"]
        length violations `shouldBe` 2
        any (isInfixOf "does not declare") violations `shouldBe` True

      it "flags a registry key whose markers are missing from the file" $ do
        let violations =
              generatedSectionsReconcilerViolations
                "documents/cli/commands.md"
                ["command-registry.markdown"]
                []
                ["command-registry.markdown"]
                ["command-registry.markdown"]
        assertExactlyOne violations $ \violation ->
          violation `shouldContain` "are not present in the file"

      it "flags a declared key that no GeneratedSectionRule registers" $ do
        let violations =
              generatedSectionsReconcilerViolations
                "documents/x.md"
                ["ghost-key"]
                []
                []
                ["command-registry.markdown"]
        assertExactlyOne violations $ \violation ->
          violation `shouldContain` "no `GeneratedSectionRule` registers it"

      it "flags a marker present in the file but absent from metadata" $ do
        let violations =
              generatedSectionsReconcilerViolations
                "documents/x.md"
                []
                ["route-registry"]
                []
                ["route-registry"]
        assertExactlyOne violations $ \violation ->
          violation `shouldContain` "but does not declare"

    describe "extractMarkdownLinkTargets" $ do
      it "extracts a relative link target" $
        extractMarkdownLinkTargets "see [the doc](./engineering/code_quality.md#x) please"
          `shouldBe` ["./engineering/code_quality.md#x"]

      it "skips link examples quoted inside inline code spans" $
        extractMarkdownLinkTargets "the `[text](path#anchor)` form is documentation"
          `shouldBe` []

      it "skips link examples inside fenced code blocks" $
        extractMarkdownLinkTargets (unlines ["```", "[x](./gone.md)", "```"])
          `shouldBe` []

      it "extracts multiple targets on one line" $
        extractMarkdownLinkTargets "[a](a.md) and [b](b.md)"
          `shouldBe` ["a.md", "b.md"]

    describe "isRelativeLinkTarget" $ do
      it "treats a relative path as relative" $
        isRelativeLinkTarget "../substrates.md#anchor" `shouldBe` True

      it "skips https URLs" $
        isRelativeLinkTarget "https://example.com" `shouldBe` False

      it "skips mailto links" $
        isRelativeLinkTarget "mailto:matthewnowak@gmail.com" `shouldBe` False

      it "skips pure-anchor links" $
        isRelativeLinkTarget "#section" `shouldBe` False

    describe "relativeLinkResolves" $ do
      it "resolves a sibling link against the doc directory and strips the anchor" $
        relativeLinkResolves
          "DEVELOPMENT_PLAN/phase-8-email-invite-auth.md"
          "substrates.md#cross-substrate-shared-resources"
          `shouldBe` Just "DEVELOPMENT_PLAN/substrates.md"

      it "resolves a parent-relative link normally (the corrected phase-8 link)" $
        relativeLinkResolves
          "DEVELOPMENT_PLAN/phase-8-email-invite-auth.md"
          "../documents/engineering/aws_integration_environment_doctrine.md"
          `shouldBe` Just "documents/engineering/aws_integration_environment_doctrine.md"

      it "shows why the OLD `../substrates.md` link was broken from DEVELOPMENT_PLAN/" $
        relativeLinkResolves
          "DEVELOPMENT_PLAN/phase-8-email-invite-auth.md"
          "../substrates.md"
          `shouldBe` Just "substrates.md"

      it "returns Nothing for an absolute URL" $
        relativeLinkResolves "documents/x.md" "https://example.com" `shouldBe` Nothing

      it "returns Nothing for a pure-anchor link" $
        relativeLinkResolves "documents/x.md" "#section" `shouldBe` Nothing

  describe "Sprint 4.15 cascade decision from drain result" $ do
    it "DrainSucceeded maps to CascadeContinue Nothing" $
      cascadeDecisionFromDrainResult DrainSucceeded `shouldBe` CascadeContinue Nothing

    it "DrainSkipped maps to CascadeContinue (Just reason)" $
      cascadeDecisionFromDrainResult (DrainSkipped "no cluster")
        `shouldBe` CascadeContinue (Just "no cluster")

    it "DrainTimedOut maps to CascadeAbort with surviving resources listed" $ do
      let result = cascadeDecisionFromDrainResult (DrainTimedOut ["Service/foo", "Ingress/bar"])
      case result of
        CascadeAbort reason -> do
          reason `shouldContain` "timed out"
          reason `shouldContain` "Service/foo"
          reason `shouldContain` "Ingress/bar"
        _ -> expectationFailure ("expected CascadeAbort, got: " ++ show result)

    it "DrainFailed maps to CascadeAbort with the error" $ do
      let result = cascadeDecisionFromDrainResult (DrainFailed "kubectl exit code 42")
      case result of
        CascadeAbort reason -> do
          reason `shouldContain` "K8s drain failed"
          reason `shouldContain` "kubectl exit code 42"
        _ -> expectationFailure ("expected CascadeAbort, got: " ++ show result)

    it "skip-is-success invariant: every CascadeContinue path returns no abort" $
      -- This codifies the doctrine's invariant: only DrainTimedOut and
      -- DrainFailed can produce CascadeAbort. If a future contributor
      -- adds a new DrainResult ctor that maps to CascadeAbort, this
      -- test still passes; if they accidentally map DrainSucceeded or
      -- DrainSkipped to CascadeAbort, this test fires.
      mapM_
        assertSkipIsSuccess
        [ ("DrainSucceeded", DrainSucceeded)
        , ("DrainSkipped \"x\"", DrainSkipped "x")
        ]

    it "Sprint 4.40 drain selector targets Delete-reclaim PVs, not Retain PVs" $ do
      deleteReclaimPersistentVolumeJsonPath
        `shouldContain` "persistentVolumeReclaimPolicy==\"Delete\""
      deleteReclaimPersistentVolumeJsonPath `shouldNotContain` "Retain"

    it "Sprint 4.40 parses only concrete Delete-reclaim PVC bindings" $
      deleteReclaimPvcBindings
        "prodbox|minio-0\nvault|vault-0\nmalformed\n|empty-namespace\nempty-name|\n"
        `shouldBe` [("prodbox", "minio-0"), ("vault", "vault-0")]

  describe "Sprint 4.14 operator vocabulary scan" $ do
    it "matchesSprintToken returns True for an adjacent Sprint + digit pair" $ do
      matchesSprintToken "Sprint 4.11: orchestrate the full teardown" `shouldBe` True
      matchesSprintToken "(Sprint 4.11)" `shouldBe` True
      matchesSprintToken "see Sprint 7.5.c.v.f" `shouldBe` True
      matchesSprintToken "Sprints 4.11/4.12 cover the cascade" `shouldBe` True

    it "matchesSprintToken returns False on clean operator vocabulary" $ do
      matchesSprintToken "Orchestrate the full teardown" `shouldBe` False
      matchesSprintToken "K8s drain skipped: cluster not reachable" `shouldBe` False
      matchesSprintToken "Confirm full RKE2 cluster deletion" `shouldBe` False
      matchesSprintToken "" `shouldBe` False

    it "matchesSprintToken does not fire on Sprint without an adjacent digit" $ do
      -- Bare 'Sprint' as an English word (no version number) should
      -- not be a violation; the check is conservatively scoped to
      -- adjacent digit tokens.
      matchesSprintToken "Sprint planning is a developer concern" `shouldBe` False

    it "extractStringLiterals pulls bodies of double-quoted strings" $ do
      let source =
            unlines
              [ "module M where"
              , "x :: String"
              , "x = \"hello, world\""
              , "y = \"second\""
              ]
      extractStringLiterals source `shouldContain` ["hello, world"]
      extractStringLiterals source `shouldContain` ["second"]

    it "extractStringLiterals ignores line comments" $ do
      let source = "x = \"good\" -- \"Sprint 4.11: in a comment\""
      extractStringLiterals source `shouldBe` ["good"]

    it "extractStringLiterals ignores block comments" $ do
      let source = "x = \"good\" {- \"Sprint 4.11: in a comment\" -}"
      extractStringLiterals source `shouldBe` ["good"]

    it "extractStringLiterals preserves escaped quotes inside literals" $ do
      let source = "x = \"a \\\"quoted\\\" thing\""
      extractStringLiterals source `shouldBe` ["a \\\"quoted\\\" thing"]

  describe "Sprint 4.10 long-lived Pulumi backend URL renderer" $ do
    it "renders an s3:// URL with region and prefix when bucket_name and region are set" $ do
      let section =
            PulumiStateBackendSection
              { psbBucketName = "prodbox-pulumi-state-long-lived"
              , psbRegion = "us-west-2"
              , psbKeyPrefix = "pulumi/"
              }
      longLivedPulumiBackendUrl section
        `shouldBe` Just "s3://prodbox-pulumi-state-long-lived?region=us-west-2&awssdk=v2&prefix=pulumi/"

    it "omits the prefix segment when key_prefix is empty" $ do
      let section =
            PulumiStateBackendSection
              { psbBucketName = "bucket"
              , psbRegion = "us-east-1"
              , psbKeyPrefix = ""
              }
      longLivedPulumiBackendUrl section
        `shouldBe` Just "s3://bucket?region=us-east-1&awssdk=v2"

    it "returns Nothing when bucket_name is empty (no fallback)" $ do
      let section =
            PulumiStateBackendSection
              { psbBucketName = "   "
              , psbRegion = "us-west-2"
              , psbKeyPrefix = "pulumi/"
              }
      longLivedPulumiBackendUrl section `shouldBe` Nothing

    it "returns Nothing when region is empty (no fallback)" $ do
      let section =
            PulumiStateBackendSection
              { psbBucketName = "bucket"
              , psbRegion = ""
              , psbKeyPrefix = "pulumi/"
              }
      longLivedPulumiBackendUrl section `shouldBe` Nothing

    it "Either form reports BackendBucketNameEmpty for missing bucket" $ do
      let section =
            PulumiStateBackendSection
              { psbBucketName = ""
              , psbRegion = "us-west-2"
              , psbKeyPrefix = "pulumi/"
              }
      longLivedPulumiBackendUrlEither section `shouldBe` Left BackendBucketNameEmpty

    it "Either form reports BackendRegionEmpty for missing region" $ do
      let section =
            PulumiStateBackendSection
              { psbBucketName = "bucket"
              , psbRegion = ""
              , psbKeyPrefix = "pulumi/"
              }
      longLivedPulumiBackendUrlEither section `shouldBe` Left BackendRegionEmpty

    it "renders structured error messages" $ do
      longLivedBackendErrorMessage BackendBucketNameEmpty
        `shouldContain` "pulumi_state_backend.bucket_name"
      longLivedBackendErrorMessage BackendRegionEmpty
        `shouldContain` "pulumi_state_backend.region"
      longLivedBackendErrorMessage (BucketEnsureFailed "boom")
        `shouldContain` "boom"

  describe "Sprint 8.5 Keycloak credential-setup form parser" $ do
    let syntheticForm =
          "<!DOCTYPE html>\
          \<html><body>\
          \<form id=\"kc-passwd-update-form\" \
          \action=\"https://test.resolvefintech.com/auth/realms/prodbox/login-actions/required-action?session_code=SCODE\" \
          \method=\"post\">\
          \<input type=\"hidden\" name=\"session_code\" value=\"SCODE\">\
          \<input type=\"hidden\" name=\"execution\" value=\"UPDATE_PASSWORD\">\
          \<input type=\"hidden\" name=\"client_id\" value=\"account\">\
          \<input type=\"password\" name=\"password\" />\
          \<input type=\"password\" name=\"password-confirm\" />\
          \</form></body></html>"

    it "parses the synthetic Keycloak fixture into the expected shape" $ do
      let parsed = parseCredentialSetupForm syntheticForm
      (formActionUrl <$> parsed)
        `shouldBe` Right
          "https://test.resolvefintech.com/auth/realms/prodbox/login-actions/required-action?session_code=SCODE"
      (formPasswordFieldName <$> parsed) `shouldBe` Right "password"
      (formPasswordConfirmFieldName <$> parsed) `shouldBe` Right "password-confirm"

    it "decodes HTML entities in the form action like a browser submit" $ do
      let encodedActionForm =
            "<form id=\"kc-passwd-update-form\" \
            \action=\"https://test.resolvefintech.com/auth/realms/prodbox/login-actions/required-action?session_code=SCODE&amp;execution=UPDATE_PASSWORD&amp;client_id=account\" \
            \method=\"post\">\
            \<input type=\"password\" name=\"password\" />\
            \<input type=\"password\" name=\"password-confirm\" />\
            \</form>"
      (formActionUrl <$> parseCredentialSetupForm encodedActionForm)
        `shouldBe` Right
          "https://test.resolvefintech.com/auth/realms/prodbox/login-actions/required-action?session_code=SCODE&execution=UPDATE_PASSWORD&client_id=account"

    it "collects all hidden inputs verbatim, preserving order" $ do
      let parsed = parseCredentialSetupForm syntheticForm
      (formHiddenFields <$> parsed)
        `shouldBe` Right
          [ ("session_code", "SCODE")
          , ("execution", "UPDATE_PASSWORD")
          , ("client_id", "account")
          ]

    it "refuses HTML that lacks the kc-passwd-update-form id" $
      parseCredentialSetupForm "<html><body><form></form></body></html>"
        `shouldSatisfy` leftContains "kc-passwd-update-form"

    it "extracts the Keycloak verify-email continuation link" $ do
      let verifyEmailPage =
            "<html><body>\
            \<p class=\"instruction\">Verify email first</p>\
            \<a href=\"/auth/realms/prodbox/login-actions/required-action?execution=UPDATE_PASSWORD&amp;client_id=account&amp;tab_id=TID\">Click here</a>\
            \</body></html>"
      parseCredentialSetupContinuationLink verifyEmailPage
        `shouldBe` Right
          "/auth/realms/prodbox/login-actions/required-action?execution=UPDATE_PASSWORD&client_id=account&tab_id=TID"

    it "refuses continuation pages without a required-action anchor" $
      parseCredentialSetupContinuationLink
        "<html><body><a href=\"/auth/realms/prodbox/account\">Account</a></body></html>"
        `shouldSatisfy` leftContains "required-action anchor"

    -- Sprint 8.5/8.8 live capture (2026-06-08): the real Keycloak 26 invite
    -- flow lands on a bundled "Perform the following action(s) … Click here
    -- to proceed" page whose proceed anchor is an /login-actions/action-token
    -- URL (NOT /login-actions/required-action). The earlier parser only
    -- matched required-action, so the live keycloak-invite gate failed with
    -- "no required-action anchor". This pins the action-token shape.
    it "extracts the Keycloak 26 action-token proceed continuation link" $ do
      let proceedPage =
            "<!DOCTYPE html><html><body>\
            \<div id=\"kc-content\">\
            \<div id=\"kc-info-message\">\
            \<p class=\"instruction\">Perform the following action(s): Verify Email, Update Password</p>\
            \<p><a href=\"https://test.resolvefintech.com/auth/realms/prodbox/login-actions/action-token?key=KEYJWT&amp;client_id=account&amp;tab_id=TID&amp;client_data=CD\">&raquo; Click here to proceed</a></p>\
            \</div></div></body></html>"
      parseCredentialSetupContinuationLink proceedPage
        `shouldBe` Right
          "https://test.resolvefintech.com/auth/realms/prodbox/login-actions/action-token?key=KEYJWT&client_id=account&tab_id=TID&client_data=CD"

    it "parses the live Keycloak 26 PatternFly update-password form" $ do
      let livePasswordForm =
            "<form id=\"kc-passwd-update-form\" class=\"pf-v5-c-form\" \
            \action=\"https://test.resolvefintech.com/auth/realms/prodbox/login-actions/required-action?session_code=SC&amp;execution=UPDATE_PASSWORD&amp;client_id=account&amp;tab_id=TID\" \
            \method=\"post\" novalidate=\"novalidate\">\
            \<div class=\"pf-v5-c-form-control\">\
            \<input id=\"password-new\" name=\"password-new\" value=\"\" type=\"password\" autocomplete=\"new-password\" autofocus aria-invalid=\"\"/>\
            \</div>\
            \<div class=\"pf-v5-c-form-control\">\
            \<input id=\"password-confirm\" name=\"password-confirm\" value=\"\" type=\"password\" autocomplete=\"new-password\" aria-invalid=\"\"/>\
            \</div>\
            \<input class=\"pf-v5-c-check__input\" type=\"checkbox\" id=\"logout-sessions\" name=\"logout-sessions\" value=\"on\" checked>\
            \<button type=\"submit\">Submit</button>\
            \</form>"
      let parsed = parseCredentialSetupForm livePasswordForm
      (formPasswordFieldName <$> parsed) `shouldBe` Right "password-new"
      (formPasswordConfirmFieldName <$> parsed) `shouldBe` Right "password-confirm"
      (formActionUrl <$> parsed)
        `shouldBe` Right
          "https://test.resolvefintech.com/auth/realms/prodbox/login-actions/required-action?session_code=SC&execution=UPDATE_PASSWORD&client_id=account&tab_id=TID"
      -- The live form carries no hidden inputs; session state is in the action query string.
      (formHiddenFields <$> parsed) `shouldBe` Right []

    it "refuses HTML that has only one password input" $ do
      let onlyOnePassword =
            "<form id=\"kc-passwd-update-form\" action=\"/x\" method=\"post\">\
            \<input type=\"password\" name=\"password\" />\
            \</form>"
      parseCredentialSetupForm onlyOnePassword
        `shouldSatisfy` leftContains "expected two"

    it "renderCredentialSetupFormPost emits canonical URL-encoded body" $ do
      let form =
            CredentialSetupForm
              { formActionUrl = "/post"
              , formHiddenFields = [("session_code", "SCODE"), ("client_id", "ac count")]
              , formPasswordFieldName = "password"
              , formPasswordConfirmFieldName = "password-confirm"
              }
      renderCredentialSetupFormPost form "secret!" "secret!"
        `shouldBe` "session_code=SCODE&client_id=ac+count&password=secret%21&password-confirm=secret%21"

    it "accepts invited-user OIDC claims with email_verified=true" $ do
      let recipient = "test-invite@example.com"
          issuer = "https://test.resolvefintech.com/auth/realms/prodbox"
      assertInviteOidcClaims
        issuer
        recipient
        ( object
            [ "iss" .= issuer
            , "email" .= recipient
            , "email_verified" .= True
            ]
        )
        `shouldBe` Right ()

    it "refuses invited-user OIDC claims when email_verified is false" $ do
      let recipient = "test-invite@example.com"
          issuer = "https://test.resolvefintech.com/auth/realms/prodbox"
      assertInviteOidcClaims
        issuer
        recipient
        ( object
            [ "iss" .= issuer
            , "email" .= recipient
            , "email_verified" .= False
            ]
        )
        `shouldSatisfy` leftContains "email_verified"

    it "refuses invited-user OIDC claims with the wrong email" $ do
      let recipient = "test-invite@example.com"
          issuer = "https://test.resolvefintech.com/auth/realms/prodbox"
      assertInviteOidcClaims
        issuer
        recipient
        ( object
            [ "iss" .= issuer
            , "email" .= ("different@example.com" :: String)
            , "email_verified" .= True
            ]
        )
        `shouldSatisfy` leftContains "email mismatch"

  describe "Sprint 4.11 predicate-library labels" $ do
    it "noLiveClusterTaggedAws exposes its label" $
      Preconditions.preconditionLabel
        ( Preconditions.noLiveClusterTaggedAws
            TagSweep.TagSweepInput
              { TagSweep.tagSweepEnvironment = []
              , TagSweep.tagSweepClusterName = Nothing
              , TagSweep.tagSweepWorkingDirectory = Nothing
              }
        )
        `shouldBe` "noLiveClusterTaggedAws"

    it "noUndrainedK8sAwsResources exposes its label" $
      Preconditions.preconditionLabel
        ( Preconditions.noUndrainedK8sAwsResources
            K8sDrainEnv
              { drainEnvironment = []
              , drainWorkingDirectory = Nothing
              }
        )
        `shouldBe` "noUndrainedK8sAwsResources"

    it "noLiveOperationalIamUser exposes its label" $
      Preconditions.preconditionLabel
        ( Preconditions.noLiveOperationalIamUser
            "/tmp/repo"
            Credentials
              { access_key_id = "AKIA"
              , secret_access_key = "secret"
              , session_token = Nothing
              , region = "us-west-2"
              }
        )
        `shouldBe` "noLiveOperationalIamUser"

    it "noLeftoverDnsBootstrapRecords exposes its label" $
      Preconditions.preconditionLabel
        ( Preconditions.noLeftoverDnsBootstrapRecords
            "/tmp/repo"
            Credentials
              { access_key_id = "AKIA"
              , secret_access_key = "secret"
              , session_token = Nothing
              , region = "us-west-2"
              }
        )
        `shouldBe` "noLeftoverDnsBootstrapRecords"

  describe "Sprint 4.10 admin-credential predicate" $ do
    it "adminCredentialsConfigured accepts a fully populated credential block" $
      adminCredentialsConfigured
        Credentials
          { access_key_id = "AKIAEXAMPLE"
          , secret_access_key = "secret"
          , session_token = Nothing
          , region = "us-west-2"
          }
        `shouldBe` True

    it "adminCredentialsConfigured refuses an empty access_key_id" $
      adminCredentialsConfigured
        Credentials
          { access_key_id = ""
          , secret_access_key = "secret"
          , session_token = Nothing
          , region = "us-west-2"
          }
        `shouldBe` False

    it "adminCredentialsConfigured refuses an empty secret_access_key" $
      adminCredentialsConfigured
        Credentials
          { access_key_id = "AKIAEXAMPLE"
          , secret_access_key = "   "
          , session_token = Nothing
          , region = "us-west-2"
          }
        `shouldBe` False

    it "adminCredentialsConfigured refuses an empty region" $
      adminCredentialsConfigured
        Credentials
          { access_key_id = "AKIAEXAMPLE"
          , secret_access_key = "secret"
          , session_token = Nothing
          , region = ""
          }
        `shouldBe` False

    it "adminCredentialsConfigured tolerates an optional session_token" $
      adminCredentialsConfigured
        Credentials
          { access_key_id = "ASIAEXAMPLE"
          , secret_access_key = "secret"
          , session_token = Just "tok"
          , region = "us-east-1"
          }
        `shouldBe` True

  describe "Sprint 4.13 long-lived state-bucket destroy payload" $ do
    it "renderDeletePayload emits the canonical S3 delete-objects shape for one version" $ do
      renderDeletePayload [("pulumi/.pulumi/stacks/aws-ses.json", "vid-1")]
        `shouldBe` "{\"Objects\":[{\"Key\":\"pulumi/.pulumi/stacks/aws-ses.json\",\"VersionId\":\"vid-1\"}]}"

    it "renderDeletePayload emits an empty Objects array when given no entries" $ do
      renderDeletePayload [] `shouldBe` "{\"Objects\":[]}"

    it "renderDeletePayload preserves order across multiple entries" $ do
      renderDeletePayload [("a", "v1"), ("b", "v2"), ("c", "v3")]
        `shouldBe` "{\"Objects\":[{\"Key\":\"a\",\"VersionId\":\"v1\"},{\"Key\":\"b\",\"VersionId\":\"v2\"},{\"Key\":\"c\",\"VersionId\":\"v3\"}]}"

  describe "Sprint 4.13 prodbox nuke renderer + confirmation literal" $ do
    it "confirmation literal is `NUKE EVERYTHING` (case-sensitive, no shorthand)" $
      Nuke.confirmationLiteral `shouldBe` "NUKE EVERYTHING"
    it "renderNukePlan lists the five-step orchestration in order" $ do
      let plan = Nuke.renderNukePlan "/tmp/repo"
      plan `shouldContain` "STEP=1 prodbox aws stack aws-ses destroy"
      plan `shouldContain` "STEP=2 K8s drain"
      plan `shouldContain` "STEP=3 prodbox aws teardown"
      plan `shouldContain` "STEP=4 postflight tag sweep"
      plan `shouldContain` "STEP=5 destroy long-lived `pulumi_state_backend` S3 bucket"
      plan
        `shouldContain` "ADMIN_CREDENTIAL_SOURCE=ephemeral admin AWS credential from the interactive prompt (harness-simulated from test-secrets.dhall::aws_admin_for_test_simulation.*); never read from prodbox.dhall or Vault"
      plan `shouldContain` "CONFIRMATION_LITERAL=NUKE EVERYTHING"

  describe "Sprint 7.7 residue lifecycle partition" $ do
    it "perRunStackNames matches the Pulumi stack descriptor SSoT" $
      perRunStackNames `shouldBe` ["aws-eks", "aws-eks-subzone", "aws-test"]
    it "longLivedResourceNames lists every long-lived managed resource" $
      longLivedResourceNames
        `shouldBe` ["aws-ses", "aws-ebs-volumes", "public-edge-tls", "pulsar-topics-long-lived"]
    it "partitionResidueByLifecycle splits residue correctly with all four stacks live" $ do
      let allFour =
            [ ("aws-eks", "prodbox aws stack eks destroy --yes")
            , ("aws-eks-subzone", "prodbox aws stack aws-subzone destroy --yes")
            , ("aws-test", "prodbox aws stack test destroy --yes")
            , ("aws-ses", "prodbox aws stack aws-ses destroy --yes")
            ]
          (perRun, longLived) = partitionResidueByLifecycle allFour
      map fst perRun `shouldBe` ["aws-eks", "aws-eks-subzone", "aws-test"]
      map fst longLived `shouldBe` ["aws-ses"]
    it "pulumiDestroyPlanForResidue orders subzone -> eks -> test -> ses (most expensive last)" $ do
      let allFour =
            [ ("aws-eks", "prodbox aws stack eks destroy --yes")
            , ("aws-eks-subzone", "prodbox aws stack aws-subzone destroy --yes")
            , ("aws-test", "prodbox aws stack test destroy --yes")
            , ("aws-ses", "prodbox aws stack aws-ses destroy --yes")
            ]
      map fst (pulumiDestroyPlanForResidue allFour)
        `shouldBe` ["aws-eks-subzone", "aws-eks", "aws-test", "aws-ses"]
    it "pulumiDestroyPlanForResidue preserves canonical order even when input is reordered" $ do
      let reordered =
            [ ("aws-ses", "prodbox aws stack aws-ses destroy --yes")
            , ("aws-test", "prodbox aws stack test destroy --yes")
            ]
      map fst (pulumiDestroyPlanForResidue reordered)
        `shouldBe` ["aws-test", "aws-ses"]

  describe "Sprint 7.7 applyAwsTeardown residue policy (Scenarios E/F/G/H/I)" $ do
    let teardownInputWith policy =
          AwsTeardownInput
            { awsTeardownAdminCredentials = awsSetupAdminCredentials sampleAwsSetupInput
            , awsTeardownResiduePolicy = policy
            }
        perRunOnlyResidue =
          categorizePulumiResidue
            (absentPerRunStatuses {perRunAwsEksTest = residuePresentFor "aws-eks-test"})
            Residue.ResidueAbsent
        sesOnlyResidue =
          categorizePulumiResidue
            absentPerRunStatuses
            (residuePresentFor "aws-ses")
        perRunAndSesResidue =
          categorizePulumiResidue
            (absentPerRunStatuses {perRunAwsEksTest = residuePresentFor "aws-eks-test"})
            (residuePresentFor "aws-ses")
        allFourResidue =
          categorizePulumiResidue
            ( PerRunResidueStatuses
                { perRunAwsEksTest = residuePresentFor "aws-eks-test"
                , perRunAwsEksSubzone = residuePresentFor "aws-eks-subzone"
                , perRunAwsTest = residuePresentFor "aws-test"
                }
            )
            (residuePresentFor "aws-ses")
    it
      "Scenario E — BypassPerRunResidueOnly with per-run residue only proceeds (long-lived empty)"
      $ do
        let (_, longLived) = partitionResidueByLifecycle perRunOnlyResidue
        null longLived `shouldBe` True
        awsTeardownResiduePolicy (teardownInputWith BypassPerRunResidueOnly)
          `shouldBe` BypassPerRunResidueOnly
    it
      "Scenario F — BypassPerRunResidueOnly with aws-ses present refuses naming aws-ses-destroy (May 19 bug fix)"
      $ do
        let (_, longLived) = partitionResidueByLifecycle sesOnlyResidue
        let refusal = renderPulumiResidueLongLivedRefusal longLived
        refusal `shouldContain` "long-lived cross-substrate shared"
        refusal `shouldContain` "aws-ses → prodbox aws stack aws-ses destroy --yes"
    it
      "Scenario G — BypassPerRunResidueOnly with both per-run and long-lived: refusal lists only long-lived"
      $ do
        let (_, longLived) = partitionResidueByLifecycle perRunAndSesResidue
        map fst longLived `shouldBe` ["aws-ses"]
        let refusal = renderPulumiResidueLongLivedRefusal longLived
        refusal `shouldContain` "aws-ses"
        ("aws-eks " `isPrefixOf` refusal) `shouldBe` False
    it
      "Scenario H — AcceptOrphanResidue with per-run residue: applyAwsTeardown short-circuits to proceed"
      $ do
        null perRunOnlyResidue `shouldBe` False
        awsTeardownResiduePolicy (teardownInputWith AcceptOrphanResidue)
          `shouldBe` AcceptOrphanResidue
    it "Scenario I — AcceptOrphanResidue with all four stacks: same proceed semantics" $ do
      length allFourResidue `shouldBe` 4
      awsTeardownResiduePolicy (teardownInputWith AcceptOrphanResidue)
        `shouldBe` AcceptOrphanResidue
    it
      "Scenario M — BypassAllResidueForHarnessRefresh with aws-ses live proceeds (Sprint 7.5.c.v.c harness preflight)"
      $ do
        let (_, longLived) = partitionResidueByLifecycle sesOnlyResidue
        map fst longLived `shouldBe` ["aws-ses"]
        awsTeardownResiduePolicy (teardownInputWith BypassAllResidueForHarnessRefresh)
          `shouldBe` BypassAllResidueForHarnessRefresh
    it
      "Scenario N — BypassAllResidueForHarnessRefresh with all four stacks: still proceeds"
      $ do
        length allFourResidue `shouldBe` 4
        awsTeardownResiduePolicy (teardownInputWith BypassAllResidueForHarnessRefresh)
          `shouldBe` BypassAllResidueForHarnessRefresh

  describe "Sprint 7.9 harness postflight no longer gates on admin-managed aws-ses" $ do
    let sesOnlyResidue =
          categorizePulumiResidue
            absentPerRunStatuses
            (residuePresentFor "aws-ses")
    it
      "harnessPostflightResiduePolicy is BypassAllResidueForHarnessRefresh (was BypassPerRunResidueOnly in Sprint 7.7)"
      $ harnessPostflightResiduePolicy `shouldBe` BypassAllResidueForHarnessRefresh
    it
      "the postflight policy matches the preflight policy (both bypass all residue post-Sprint-4.10)"
      $ harnessPostflightResiduePolicy `shouldBe` BypassAllResidueForHarnessRefresh
    it
      "the postflight policy is NOT the old Sprint 7.7 BypassPerRunResidueOnly (which still refuses on aws-ses)"
      $ (harnessPostflightResiduePolicy == BypassPerRunResidueOnly) `shouldBe` False
    it
      "with aws-ses live, the postflight policy proceeds rather than refusing (no operational-user stranding)"
      $ do
        -- aws-ses live is the retained-by-design steady state; the
        -- Sprint 7.7 BypassPerRunResidueOnly path would refuse here
        -- (renderPulumiResidueLongLivedRefusal names aws-ses-destroy),
        -- stranding the freshly-created operational prodbox IAM user.
        -- The Sprint 7.9 postflight policy proceeds: aws-ses is
        -- admin-managed post-4.10, so clearing operational aws.* cannot
        -- strand it.
        let (_, longLived) = partitionResidueByLifecycle sesOnlyResidue
        map fst longLived `shouldBe` ["aws-ses"]
        -- The old policy would have produced a long-lived refusal here:
        renderPulumiResidueLongLivedRefusal longLived
          `shouldContain` "aws-ses → prodbox aws stack aws-ses destroy --yes"
        -- The postflight policy is one of the two proceed-on-everything
        -- policies (BypassAllResidueForHarnessRefresh / AcceptOrphanResidue),
        -- so applyAwsTeardown short-circuits past that refusal.
        ( harnessPostflightResiduePolicy
            `elem` [BypassAllResidueForHarnessRefresh, AcceptOrphanResidue]
          )
          `shouldBe` True

  describe "Sprint 7.10 harness preserves creds on per-run destroy failure" $ do
    it
      "clearOperationalCredsAfterPostflight returns True on ExitSuccess (per-run destroy succeeded)"
      $ clearOperationalCredsAfterPostflight ExitSuccess `shouldBe` True
    it
      "clearOperationalCredsAfterPostflight returns False on ExitFailure (preserve creds for orphan retry)"
      $ do
        clearOperationalCredsAfterPostflight (ExitFailure 1) `shouldBe` False
        clearOperationalCredsAfterPostflight (ExitFailure 124) `shouldBe` False

  describe "Sprint 7.7 DestroyPulumiResidueFirst dispatch plan (Scenarios J/K/L)" $ do
    it "Scenario J — aws-eks only: destroy plan dispatches just eks-destroy --yes" $ do
      let residue =
            categorizePulumiResidue
              (absentPerRunStatuses {perRunAwsEksTest = residuePresentFor "aws-eks-test"})
              Residue.ResidueAbsent
      pulumiDestroyPlanForResidue residue
        `shouldBe` [("aws-eks", "prodbox aws stack eks destroy --yes")]
    it
      "Scenario K — aws-ses only: destroy plan names aws-ses-destroy (long-lived warning fires at dispatch)"
      $ do
        let residue =
              categorizePulumiResidue
                absentPerRunStatuses
                (residuePresentFor "aws-ses")
        pulumiDestroyPlanForResidue residue
          `shouldBe` [("aws-ses", "prodbox aws stack aws-ses destroy --yes")]
    it "Scenario L — all four: destroy plan dispatches in canonical order subzone -> eks -> test -> ses" $ do
      let residue =
            categorizePulumiResidue
              ( PerRunResidueStatuses
                  { perRunAwsEksTest = residuePresentFor "aws-eks-test"
                  , perRunAwsEksSubzone = residuePresentFor "aws-eks-subzone"
                  , perRunAwsTest = residuePresentFor "aws-test"
                  }
              )
              (residuePresentFor "aws-ses")
      map fst (pulumiDestroyPlanForResidue residue)
        `shouldBe` ["aws-eks-subzone", "aws-eks", "aws-test", "aws-ses"]

  describe "Sprint 7.7 promptAdminCredentials UX (sessionTokenPromptShape)" $ do
    it "AKIA prefix -> SkipPrompt (long-lived IAM user key; no session token)" $
      sessionTokenPromptShape "AKIAEXAMPLEKEYID0000" `shouldBe` SkipPrompt
    it "ASIA prefix -> PromptRequiredHidden (STS-derived; session token required)" $
      sessionTokenPromptShape "ASIAEXAMPLEKEYID0000" `shouldBe` PromptRequiredHidden
    it "AGPA prefix (group access key, defensive fallback) -> PromptOptionalWithHint" $
      sessionTokenPromptShape "AGPAEXAMPLEKEYID0000" `shouldBe` PromptOptionalWithHint
    it "AROA prefix (role) -> PromptOptionalWithHint" $
      sessionTokenPromptShape "AROAEXAMPLEKEYID0000" `shouldBe` PromptOptionalWithHint
    it "empty input -> PromptOptionalWithHint (operator hasn't pasted anything yet)" $
      sessionTokenPromptShape "" `shouldBe` PromptOptionalWithHint
    it "AKIa with lower-case is not AKIA (case-sensitive, intentional)" $
      sessionTokenPromptShape "AKIa1234567890ABCDEF" `shouldBe` PromptOptionalWithHint

  describe "Sprint 7.7 awsTeardownPolicyFromFlags mutual exclusion" $ do
    it "neither flag -> RefuseOnAnyResidue (default)" $
      awsTeardownPolicyFromFlags False False `shouldBe` Right RefuseOnAnyResidue
    it "--allow-pulumi-residue only -> AcceptOrphanResidue" $
      awsTeardownPolicyFromFlags True False `shouldBe` Right AcceptOrphanResidue
    it "--destroy-pulumi-residue only -> DestroyPulumiResidueFirst" $
      awsTeardownPolicyFromFlags False True `shouldBe` Right DestroyPulumiResidueFirst
    it "both flags -> Left with mutual-exclusion error" $ do
      let result = awsTeardownPolicyFromFlags True True
      case result of
        Left msg -> msg `shouldContain` "mutually exclusive"
        Right policy -> expectationFailure ("expected Left, got Right " ++ show policy)

  describe "interactive non-TTY guard" $ do
    let guards =
          [
            ( "aws setup"
            , awsSetupGuard
            , "prodbox aws setup"
            , "prodbox test all --substrate aws"
            )
          ,
            ( "aws teardown"
            , awsTeardownGuard
            , "prodbox aws teardown"
            , "test-harness postflight"
            )
          ,
            ( "aws check-quotas"
            , awsCheckQuotasGuard
            , "prodbox aws check-quotas"
            , "operator-only"
            )
          ,
            ( "aws request-quotas"
            , awsRequestQuotasGuard
            , "prodbox aws request-quotas"
            , "operator-only"
            )
          ,
            ( "config setup"
            , configSetupGuard
            , "prodbox config setup"
            , "Edit prodbox.dhall directly"
            )
          ,
            ( "charts delete confirmation"
            , chartsDeleteGuard
            , "prodbox charts delete"
            , "--yes"
            )
          ]
    mapM_
      ( \(label, guard, expectedCommandFragment, expectedAutomationFragment) ->
          it (label ++ " guard carries the command name and the automation hint") $ do
            guardCommand guard `shouldContain` expectedCommandFragment
            guardAutomationHint guard `shouldContain` expectedAutomationFragment
            let rendered = renderNonTtyError guard
            rendered `shouldContain` guardCommand guard
            rendered `shouldContain` "stdin is not a TTY"
            rendered `shouldContain` "non-interactive automation"
            rendered `shouldContain` expectedAutomationFragment
            rendered `shouldContain` "cli_command_surface.md"
      )
      guards

    it "names the test-only bypass env var explicitly" $
      allowNonTtyInteractiveEnvVar `shouldBe` "PRODBOX_ALLOW_NON_TTY_INTERACTIVE"

  describe "command prerequisites (Phase 4 declarative SSoT)" $ do
    it "references only registry-member prerequisite ids" $ do
      let sampleCommands =
            [ NativeAws (AwsSetup PolicyFull (PlanOptions False Nothing))
            , NativeAws AwsCheckQuotas
            , NativeAws (AwsReapTestEbs True)
            , NativeCharts ChartsList
            , NativeDns DnsCheck
            , NativeEdge (EdgeReconcile (PlanOptions False Nothing))
            , NativeK8s K8sHealth
            , NativePulumi (PulumiEksResources (PlanOptions False Nothing))
            , NativeCheckCode
            , NativeTlaCheck
            ]
          referenced = concatMap commandPrerequisites sampleCommands
      all (`Map.member` prerequisiteRegistry) referenced `shouldBe` True

    it "gates edge reconcile on a reachable cluster and valid AWS credentials" $
      commandPrerequisites (NativeEdge (EdgeReconcile (PlanOptions False Nothing)))
        `shouldBe` [K8sClusterReachable, AwsCredentialsValid]

    it "keeps the local cluster lifecycle commands prerequisite-free at the SSoT layer" $
      commandPrerequisites (NativeRke2 (Rke2Reconcile (PlanOptions False Nothing) False))
        `shouldBe` []

  describe "Sprint 4.34 autoscaler runtime and federation-scoped placement" $ do
    let smallBudget = Capacity.CapacityBudget 1 1 1
        largeBudget = Capacity.CapacityBudget 4 4 4
        childMetadata childId parentId =
          ChildMetadata
            { childMetadataClusterId = childId
            , childMetadataVaultAddress = "https://vault.example"
            , childMetadataTransitKey = "transit-key"
            , childMetadataVaultNamespace = "namespace"
            , childMetadataParentClusterId = parentId
            , childMetadataEndpoints = Map.empty
            , childMetadataKubeconfigReference = Nothing
            , childMetadataAccountId = Nothing
            , childMetadataPulumiStacks = Map.empty
            }
        children =
          [ childMetadata "child-a" "root"
          , childMetadata "child-b" "root"
          , childMetadata "grandchild-a" "child-a"
          ]
        capacityFor clusterId budget =
          Autoscaler.ClusterCapacity
            { Autoscaler.clusterCapacityClusterId = clusterId
            , Autoscaler.clusterCapacityAvailable = budget
            }
        input intents =
          Autoscaler.AutoscalerInput
            { Autoscaler.autoscalerRootClusterId = "root"
            , Autoscaler.autoscalerChildren = children
            , Autoscaler.autoscalerClusterCapacities =
                [ capacityFor "root" largeBudget
                , capacityFor "child-a" largeBudget
                , capacityFor "child-b" largeBudget
                ]
            , Autoscaler.autoscalerGatewayLeaderClusterId = "root"
            , Autoscaler.autoscalerIntents = intents
            }

    it "admits only clusters in the parent-custodied federation trust tree" $ do
      Autoscaler.clusterInTrustTree "root" children "root" `shouldBe` True
      Autoscaler.clusterInTrustTree "root" children "grandchild-a" `shouldBe` True
      Autoscaler.clusterInTrustTree "root" children "stray" `shouldBe` False

    it "accepts scale-up when the target is trusted and the budget fits" $
      Autoscaler.autoscalerPlan (input [Autoscaler.ScaleWorkloadUp "child-a" smallBudget])
        `shouldBe` Autoscaler.ScalingPlanAccepted
          (Autoscaler.ScalingPlan [Autoscaler.ScalingActionScaleUp "child-a" smallBudget])

    it "refuses scale-up outside the federation trust tree" $
      Autoscaler.autoscalerPlan (input [Autoscaler.ScaleWorkloadUp "stray" smallBudget])
        `shouldBe` Autoscaler.ScalingPlanRefused (Autoscaler.ScalingTargetOutsideTrustTree "stray")

    it "refuses scale-up before mutation when observed capacity is insufficient" $
      Autoscaler.autoscalerPlan
        ( (input [Autoscaler.ScaleWorkloadUp "child-a" largeBudget])
            { Autoscaler.autoscalerClusterCapacities = [capacityFor "child-a" smallBudget]
            }
        )
        `shouldBe` Autoscaler.ScalingPlanRefused
          (Autoscaler.ScalingInsufficientCapacity "child-a" largeBudget smallBudget)

    it "refuses to scale down the current gateway leader" $
      Autoscaler.autoscalerPlan
        ( (input [Autoscaler.ScaleWorkloadDown "child-a"])
            { Autoscaler.autoscalerGatewayLeaderClusterId = "child-a"
            }
        )
        `shouldBe` Autoscaler.ScalingPlanRefused (Autoscaler.ScalingWouldRemoveGatewayLeader "child-a")

    it "orders scale-up before non-leader scale-down so leadership is preserved" $
      Autoscaler.autoscalerPlan
        (input [Autoscaler.ScaleWorkloadDown "child-b", Autoscaler.ScaleWorkloadUp "child-a" smallBudget])
        `shouldBe` Autoscaler.ScalingPlanAccepted
          ( Autoscaler.ScalingPlan
              [ Autoscaler.ScalingActionScaleUp "child-a" smallBudget
              , Autoscaler.ScalingActionScaleDown "child-b"
              ]
          )

    it "exposes capacity-scaled resources through the lifecycle registry surface" $ do
      ResourceRegistry.capacityScaledManagedResources `shouldBe` Autoscaler.capacityScaledResourceNames
      mapM_
        (\name -> ResourceRegistry.capacityScaledManagedResources `shouldContain` [name])
        ["gateway", "api", "websocket"]

  describe "Sprint 7.27 spot-price economics gate" $ do
    let threshold = Spot.SpotPriceThreshold (Spot.UsdPerHour 0.05)
        unobservable = Spot.UnobservableReason "ec2 pricing API unreachable"
        linuxT3Large =
          SpotPriceRequest
            { spotPriceInstanceType = "t3.large"
            , spotPriceProductDescription = "Linux/UNIX"
            }
        spotHistoryPayload price =
          unlines
            [ "{"
            , "  \"SpotPriceHistory\": ["
            , "    {"
            , "      \"InstanceType\": \"t3.large\","
            , "      \"ProductDescription\": \"Linux/UNIX\","
            , "      \"SpotPrice\": \"" ++ price ++ "\","
            , "      \"AvailabilityZone\": \"us-east-1a\""
            , "    }"
            , "  ]"
            , "}"
            ]

    it "admits below-threshold spot observations" $
      Spot.admitSpotDeploy threshold (Spot.SpotObserved (Spot.UsdPerHour 0.04))
        `shouldBe` Spot.SpotAdmit

    it "defers at or above the configured threshold" $ do
      Spot.admitSpotDeploy threshold (Spot.SpotObserved (Spot.UsdPerHour 0.05))
        `shouldBe` Spot.SpotDefer (Spot.SpotPriceAboveThreshold (Spot.UsdPerHour 0.05) threshold)
      Spot.admitSpotDeploy threshold (Spot.SpotObserved (Spot.UsdPerHour 0.06))
        `shouldBe` Spot.SpotDefer (Spot.SpotPriceAboveThreshold (Spot.UsdPerHour 0.06) threshold)

    it "refuses unobservable spot prices rather than admitting fail-open" $
      Spot.admitSpotDeploy threshold (Spot.SpotUnobservable unobservable)
        `shouldBe` Spot.SpotRefuse unobservable

    it "makes the home-local substrate a structural no-op for spot gates" $ do
      Spot.spotGateForScalingPolicy
        SubstrateHomeLocal
        (ScalingPolicyFixed 1)
        (Just threshold)
        `shouldBe` Spot.SpotGateNotApplicable
      Spot.spotGateForScalingPolicy
        SubstrateAws
        (ScalingPolicyElastic (ElasticScalingBounds 1 3))
        (Just threshold)
        `shouldBe` Spot.SpotGateRequired threshold
      Spot.spotGateForScalingPolicy
        SubstrateAws
        (ScalingPolicyFixed 1)
        (Just threshold)
        `shouldBe` Spot.SpotGateNotApplicable

    it "builds the EC2 spot-price query through the existing credential-region AWS CLI path" $
      awsSpotPriceHistoryArgs linuxT3Large
        `shouldBe` [ "ec2"
                   , "describe-spot-price-history"
                   , "--instance-types"
                   , "t3.large"
                   , "--product-descriptions"
                   , "Linux/UNIX"
                   , "--max-results"
                   , "1"
                   , "--output"
                   , "json"
                   ]

    it "parses AWS spot-price history payloads into observations" $
      spotObservationFromAwsSpotPriceHistory (spotHistoryPayload "0.010400")
        `shouldBe` Spot.SpotObserved (Spot.UsdPerHour 0.0104)

    it "marks empty or invalid spot-price history as unobservable" $ do
      spotObservationFromAwsSpotPriceHistory "{\"SpotPriceHistory\": []}"
        `shouldBe` Spot.SpotUnobservable
          (Spot.UnobservableReason "aws ec2 describe-spot-price-history returned no spot price history")
      spotObservationFromAwsSpotPriceHistory "{\"SpotPriceHistory\": [{\"SpotPrice\": \"not-a-number\"}]}"
        `shouldBe` Spot.SpotUnobservable
          (Spot.UnobservableReason "invalid USD/hour spot price: not-a-number")

    it "turns failed AWS CLI output into an unobservable spot price" $
      spotObservationFromAwsSpotPriceOutput (ProcessOutput (ExitFailure 2) "" "throttled")
        `shouldBe` Spot.SpotUnobservable
          (Spot.UnobservableReason "aws ec2 describe-spot-price-history failed: throttled")

  describe "Sprint 4.36 tiered-storage capacity budget and quota gate" $ do
    let storageBudget bytes = Capacity.CapacityBudget 0 0 bytes
        store name bytes capacity =
          Storage.DurableStoreClaim
            { Storage.durableStoreName = name
            , Storage.durableStoreBudget = storageBudget bytes
            , Storage.durableStoreCapacity = capacity
            }
        cache jit model =
          Storage.MlCacheBudget
            { Storage.mlJitArtifactCacheBudget = storageBudget jit
            , Storage.mlModelCacheBudget = storageBudget model
            }
        mlEngine =
          Storage.MlEngineStorageBudget
            { Storage.mlEngineName = "jit-model-worker"
            , Storage.mlHostBudget = cache 1 2
            , Storage.mlClusterBudget = cache 1 2
            }
        quotaStatus name current target meets =
          QuotaStatus
            { quotaStatusDisplayName = name
            , quotaStatusServiceCode = "ec2"
            , quotaStatusQuotaCode = "L-STORAGE"
            , quotaStatusCurrentValue = current
            , quotaStatusTargetValue = target
            , quotaStatusSource = "stub"
            , quotaStatusMeetsTarget = meets
            , quotaStatusRequestStatus = Nothing
            , quotaStatusNote = Nothing
            }

    it "keeps durable capacity finite and has no Infinite constructor" $ do
      Storage.durableStoreCapacityConstructors `shouldBe` ["Bounded", "Autoscaled"]
      ("Infinite" `elem` Storage.durableStoreCapacityConstructors) `shouldBe` False

    it "admits autoscaled MinIO capacity only with a scaling-policy witness" $ do
      Storage.validateDurableStoreCapacityRequest
        "minio"
        (Storage.DurableStoreCapacityRequestAutoscaled Nothing)
        `shouldBe` Left (Storage.StorageAutoscaledSinkMissingWitness "minio")
      let witnessResult = Storage.scalingPolicyWitness "aws-elastic-minio"
      case witnessResult of
        Left err -> expectationFailure ("expected valid scaling-policy witness: " ++ show err)
        Right witness ->
          Storage.validateDurableStoreCapacityRequest
            "minio"
            (Storage.DurableStoreCapacityRequestAutoscaled (Just witness))
            `shouldBe` Right (Storage.DurableStoreAutoscaled witness)
      Storage.scalingPolicyWitness " "
        `shouldBe` Left (Storage.StorageInvalidScalingWitness " ")

    it "adds durable store claims and mandatory ML host/cluster cache budgets into one finite budget" $ do
      let boundedStore = store "pulsar-offload" 4 (Storage.DurableStoreBounded (storageBudget 4))
          plan storageCeiling =
            Storage.StorageCapacityPlan
              { Storage.storageCapacityBudget = storageBudget storageCeiling
              , Storage.storageCapacityStores = [boundedStore]
              , Storage.storageCapacityMlEngines = [mlEngine]
              }
      Storage.mlEngineStorageTotal mlEngine `shouldBe` storageBudget 6
      Storage.storageCapacityPlanDraw (plan 10) `shouldBe` storageBudget 10
      Storage.validateStorageCapacityPlan (plan 10) `shouldBe` Right ()
      Storage.validateStorageCapacityPlan (plan 9)
        `shouldBe` Left (Storage.StorageCapacityBudgetExceeded (storageBudget 10) (storageBudget 9))

    it "refuses an AWS region quota preflight when a stubbed quota is below target" $ do
      let okStatus = quotaStatus "EBS storage quota" 100.0 80.0 True
          lowStatus = quotaStatus "EBS storage quota" 20.0 80.0 False
      quotaStatusRegionObservation okStatus
        `shouldBe` Storage.AwsRegionQuotaObservation
          { Storage.regionQuotaName = "EBS storage quota"
          , Storage.regionQuotaCurrentValue = 100.0
          , Storage.regionQuotaTargetValue = 80.0
          , Storage.regionQuotaMeetsTarget = True
          }
      awsRegionQuotaPreflightFromStatuses [okStatus] `shouldBe` Right ()
      awsRegionQuotaPreflightFromStatuses [lowStatus]
        `shouldBe` Left
          ( Storage.StorageRegionQuotaShortfall
              [ Storage.RegionQuotaShortfall
                  { Storage.regionQuotaShortfallName = "EBS storage quota"
                  , Storage.regionQuotaShortfallCurrentValue = 20.0
                  , Storage.regionQuotaShortfallTargetValue = 80.0
                  }
              ]
          )

  describe "Sprint 1.60 runtime-memory decomposition and RTS policy" $ do
    it "rejects zero for every positive byte term and preserves positive bytes" $ do
      forM_ [minBound .. maxBound] $ \term -> do
        RuntimeMemory.mkPositiveBytes term 0
          `shouldBe` Left (RuntimeMemory.MemoryTermMustBePositive term)
        fmap RuntimeMemory.positiveBytesValue (RuntimeMemory.mkPositiveBytes term 1)
          `shouldBe` Right 1

    it "rejects unbounded, zero-permit, missing-deadline, zero-deadline, and missing-peak schedules" $ do
      RuntimeMemory.validateChildSchedule RuntimeMemory.UnboundedChildSchedule
        `shouldBe` Left RuntimeMemory.ChildScheduleMustBeBounded
      RuntimeMemory.validateChildSchedule (RuntimeMemory.BoundedChildSchedule 0 (Just 1000) [10])
        `shouldBe` Left RuntimeMemory.ChildPermitCountMustBePositive
      RuntimeMemory.validateChildSchedule (RuntimeMemory.BoundedChildSchedule 1 Nothing [10])
        `shouldBe` Left RuntimeMemory.ChildDeadlineMissing
      RuntimeMemory.validateChildSchedule (RuntimeMemory.BoundedChildSchedule 1 (Just 0) [10])
        `shouldBe` Left RuntimeMemory.ChildDeadlineMustBePositive
      RuntimeMemory.validateChildSchedule (RuntimeMemory.BoundedChildSchedule 1 (Just 1000) [])
        `shouldBe` Left RuntimeMemory.ChildPeakListMustNotBeEmpty

    it "rejects a zero child peak with its exact schedule index" $ do
      RuntimeMemory.validateChildSchedule
        (RuntimeMemory.BoundedChildSchedule 1 (Just 1000) [10, 0, 30])
        `shouldBe` Left (RuntimeMemory.ChildPeakMustBePositive 1)

    it "uses the maximum possible peak for a capacity-one serialized child schedule" $ do
      case RuntimeMemory.validateChildSchedule
        (RuntimeMemory.BoundedChildSchedule 1 (Just 30000000) [10, 30, 20]) of
        Left err -> expectationFailure (show err)
        Right budget -> do
          RuntimeMemory.childProcessPermitCount budget `shouldBe` 1
          RuntimeMemory.childProcessDeadlineMicros budget `shouldBe` 30000000
          RuntimeMemory.positiveBytesValue
            (RuntimeMemory.childProcessReservedPeakBytes budget)
            `shouldBe` 30

    it "sums concurrent child peaks and rejects a permit-to-peak count mismatch" $ do
      case RuntimeMemory.validateChildSchedule
        (RuntimeMemory.BoundedChildSchedule 3 (Just 1000) [10, 30, 20]) of
        Left err -> expectationFailure (show err)
        Right budget ->
          RuntimeMemory.positiveBytesValue
            (RuntimeMemory.childProcessReservedPeakBytes budget)
            `shouldBe` 60
      RuntimeMemory.validateChildSchedule
        (RuntimeMemory.BoundedChildSchedule 2 (Just 1000) [10])
        `shouldBe` Left (RuntimeMemory.ConcurrentChildPeakCountMismatch 2 1)

    it "rejects an inner heap sum above the configured heap cap" $ do
      RuntimeMemory.validateRuntimeMemoryPlan
        ( runtimeMemoryTestInputs
            99
            200
            (RuntimeMemory.BoundedChildSchedule 1 (Just 1000) [20])
        )
        `shouldBe` Left (RuntimeMemory.HeapBudgetExceedsCap 100 99)

    it "rejects the heap cap plus headroom above the container limit" $ do
      RuntimeMemory.validateRuntimeMemoryPlan
        ( runtimeMemoryTestInputs
            120
            169
            (RuntimeMemory.BoundedChildSchedule 1 (Just 1000) [20])
        )
        `shouldBe` Left (RuntimeMemory.RuntimeBudgetExceedsContainerLimit 170 169)

    it "counts heap-resident terms once and derives the cgroup high-water threshold from safety" $ do
      case RuntimeMemory.validateRuntimeMemoryPlan
        ( runtimeMemoryTestInputs
            120
            200
            (RuntimeMemory.BoundedChildSchedule 1 (Just 1000) [20])
        ) of
        Left err -> expectationFailure (show err)
        Right plan -> do
          RuntimeMemory.positiveBytesValue (RuntimeMemory.runtimeMemoryRetainedHeapBytes plan)
            `shouldBe` 30
          RuntimeMemory.positiveBytesValue (RuntimeMemory.runtimeMemoryScratchBytes plan)
            `shouldBe` 30
          RuntimeMemory.positiveBytesValue (RuntimeMemory.runtimeMemoryHeapRequiredBytes plan)
            `shouldBe` 100
          RuntimeMemory.positiveBytesValue (RuntimeMemory.runtimeMemoryHeapCapBytes plan)
            `shouldBe` 120
          -- Outer demand is heap_cap + 15 + 20 + 10 + 5 = 170. Adding
          -- the 100-byte resident inner sum again would incorrectly yield 270.
          RuntimeMemory.positiveBytesValue (RuntimeMemory.runtimeMemoryOuterRequiredBytes plan)
            `shouldBe` 170
          RuntimeMemory.positiveBytesValue (RuntimeMemory.runtimeMemoryContainerLimitBytes plan)
            `shouldBe` 200
          RuntimeMemory.positiveBytesValue (RuntimeMemory.runtimeMemorySafetyMarginBytes plan)
            `shouldBe` 5
          RuntimeMemory.positiveBytesValue (RuntimeMemory.runtimeMemoryHighWaterBytes plan)
            `shouldBe` 195

    it "rejects missing, duplicate, and unknown configured runtime-memory profiles" $ do
      Capacity.validateCapacitySection
        Capacity.defaultCapacitySection {Capacity.runtime_memory_profiles = []}
        `shouldBe` Left "capacity.runtime_memory_profiles must not be empty"
      Capacity.validateCapacitySection
        Capacity.defaultCapacitySection
          { Capacity.runtime_memory_profiles =
              [defaultGatewayRuntimeMemoryProfile, defaultGatewayRuntimeMemoryProfile]
          }
        `shouldBe` Left "capacity.runtime_memory_profiles must have unique runtime_profile_id values"
      Capacity.validateCapacitySection
        Capacity.defaultCapacitySection
          { Capacity.runtime_memory_profiles =
              [ defaultGatewayRuntimeMemoryProfile
                  { Capacity.runtime_profile_id = "unknown-runtime"
                  }
              ]
          }
        `shouldSatisfy` leftContains "references unknown workload profile"
      Capacity.runtimeMemoryPlanForProfile Capacity.defaultCapacitySection "api"
        `shouldSatisfy` leftContains "is missing profile `api`"

    it "derives the runtime container ceiling from the matching ResourceEnvelope memory limit" $ do
      let lowerGatewayLimit profile =
            if Capacity.profile_id profile == "gateway"
              then
                let envelope = Capacity.resources profile
                    oldLimit = Capacity.limit envelope
                 in profile
                      { Capacity.resources =
                          envelope
                            { Capacity.limit = oldLimit {Capacity.memory_mib = 500}
                            }
                      }
              else profile
          originalResourcePlan = Capacity.resource_plan Capacity.defaultCapacitySection
          linkedResourcePlan =
            originalResourcePlan
              { Capacity.workload_profiles =
                  map lowerGatewayLimit (Capacity.workload_profiles originalResourcePlan)
              }
          linkedCapacity =
            Capacity.defaultCapacitySection
              { Capacity.resource_plan = linkedResourcePlan
              }
      Capacity.validateCapacitySection linkedCapacity `shouldBe` Right ()
      case Capacity.runtimeMemoryPlanForProfile linkedCapacity "gateway" of
        Left err -> expectationFailure err
        Right plan -> do
          RuntimeMemory.positiveBytesValue
            (RuntimeMemory.runtimeMemoryContainerLimitBytes plan)
            `shouldBe` (500 * 1024 * 1024)
          RuntimeMemory.positiveBytesValue
            (RuntimeMemory.runtimeMemoryHighWaterBytes plan)
            `shouldBe` ((500 - 64) * 1024 * 1024)

    it "renders exact gateway RTS argv from the validated default capacity plan" $ do
      case Capacity.runtimeMemoryPlanForProfile Capacity.defaultCapacitySection "gateway" of
        Left err -> expectationFailure err
        Right plan -> do
          RuntimeMemory.runtimeMemoryRtsArguments plan
            `shouldBe` ["+RTS", "-M268435456", "-RTS"]
          RuntimeMemory.renderRuntimeMemoryRtsPolicy plan
            `shouldBe` "+RTS -M268435456 -RTS"

    goldenTest
      "renders the gateway runtime-memory RTS policy solely from its validated plan"
      "test/golden/plans/gateway-runtime-memory.txt"
      $ case Capacity.runtimeMemoryPlanForProfile Capacity.defaultCapacitySection "gateway" of
        Left err -> fail err
        Right plan ->
          pure (BL8.pack (RuntimeMemory.renderRuntimeMemoryRtsPolicy plan ++ "\n"))

    it "injects generated runtime and lifecycle-probe values into the gateway chart plan" $ do
      result <-
        buildChartDeploymentPlanForSubstrate
          SubstrateAws
          "/tmp/prodbox"
          (testValidatedSettings "/tmp/prodbox/.data")
          "gateway"
          testChartSecrets
          Map.empty
      case result of
        Left err -> expectationFailure err
        Right deploymentPlan ->
          case filter ((== "gateway") . chartReleasePlanReleaseName) (chartDeploymentPlanReleases deploymentPlan) of
            [release] ->
              case eitherDecode (BL8.pack (chartReleasePlanValuesJson release)) :: Either String Value of
                Left err -> expectationFailure err
                Right (Object payload) -> do
                  case KeyMap.lookup (Key.fromString "runtime") payload of
                    Just (Object runtimePayload) ->
                      KeyMap.lookup (Key.fromString "rtsArguments") runtimePayload
                        `shouldBe` Just
                          ( Array
                              ( Vector.fromList
                                  [ String "+RTS"
                                  , String "-M268435456"
                                  , String "-RTS"
                                  ]
                              )
                          )
                    _ -> expectationFailure "expected gateway runtime values"
                  KeyMap.lookup (Key.fromString "probes") payload
                    `shouldBe` Just GatewayProbe.gatewayLifecycleProbeValues
                Right _ -> expectationFailure "expected gateway values object"
            _ -> expectationFailure "expected one gateway release"

  describe "settings" $ do
    it "validates Dhall config and renders masked output without materializing JSON" $
      withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)

        result <- validateAndLoadSettingsAtPath (tmpDir </> "prodbox.dhall") tmpDir

        case result of
          Left err -> expectationFailure err
          Right settings -> do
            renderSettingsDisplay False settings
              `shouldContain` "aws.access_key_id=Vault:secret/gateway/gateway/aws#access_key_id"
            renderSettingsDisplay False settings `shouldContain` "acme.email=****.com"
            renderSettingsDisplay True settings
              `shouldContain` "aws.access_key_id=Vault:secret/gateway/gateway/aws#access_key_id"
            renderSettingsDisplay False settings
              `shouldContain` ("storage.manual_pv_host_root=" ++ (tmpDir </> ".data"))
            renderSettingsDisplay False settings
              `shouldContain` "cluster_topology.type=rke2"
            doesFileExist (tmpDir </> "prodbox-config.json") `shouldReturn` False

    it "fails fast on invalid bootstrap public IP overrides" $
      validatePublicEdgeDeployment
        validDeploymentSection
          { bootstrap_public_ip_override = Just "not-an-ip"
          }
        `shouldBe` Left "deployment.bootstrap_public_ip_override must be a valid IP address when set"

    it "fails fast on invalid BGP peer IP literals" $
      validatePublicEdgeDeployment
        validDeploymentSection
          { public_edge_advertisement_mode = Just "bgp"
          , public_edge_bgp_peers =
              Just
                [ MetallbBgpPeer
                    { peer_name = "peer-a"
                    , peer_address = "invalid-address"
                    , peer_asn = 64501
                    , my_asn = 64500
                    , ebgp_multi_hop = Just False
                    }
                ]
          }
        `shouldBe` Left "deployment.public_edge_bgp_peers[1].peer_address must be a valid IP address when set"

    it "accepts IPv6 literals for the supported public-edge settings" $
      validatePublicEdgeDeployment
        validDeploymentSection
          { bootstrap_public_ip_override = Just "2001:db8::10"
          , public_edge_advertisement_mode = Just "bgp"
          , public_edge_bgp_peers =
              Just
                [ MetallbBgpPeer
                    { peer_name = "peer-a"
                    , peer_address = "2001:db8::20"
                    , peer_asn = 64501
                    , my_asn = 64500
                    , ebgp_multi_hop = Just True
                    }
                ]
          }
        `shouldBe` Right ()

    it "validates typed scaling policies for each substrate" $ do
      validatePublicEdgeDeployment validDeploymentSection `shouldBe` Right ()
      validatePublicEdgeDeployment
        validDeploymentSection
          { api_scaling =
              ScalingPolicyBySubstrate
                { scalingHomeLocal = ScalingPolicyElastic (ElasticScalingBounds 1 2)
                , scalingAws = ScalingPolicyFixed 2
                }
          }
        `shouldBe` Left "deployment.api_scaling.home_local must be Fixed; Elastic scaling is only valid for aws"
      validatePublicEdgeDeployment
        validDeploymentSection
          { api_scaling =
              ScalingPolicyBySubstrate
                { scalingHomeLocal = ScalingPolicyFixed 2
                , scalingAws = ScalingPolicyElastic (ElasticScalingBounds 3 2)
                }
          }
        `shouldBe` Left "deployment.api_scaling.aws.Elastic.min must be less than or equal to max"

    it "checks capacity budget containment with the pure Sprint 1.51 lemmas" $ do
      let small = Capacity.CapacityBudget 1 2 3
          large = Capacity.CapacityBudget 2 4 8
          tooMuchStorage = Capacity.CapacityBudget 1 2 101
      Capacity.fitsWithin small large `shouldBe` True
      Capacity.storageFitsWithin tooMuchStorage large `shouldBe` False
      Capacity.validateCapacitySection
        Capacity.defaultCapacitySection
        `shouldBe` Right ()
      Capacity.validateCapacitySection
        Capacity.defaultCapacitySection {Capacity.workload_budget = tooMuchStorage}
        `shouldBe` Left "capacity.workload_budget must fit within capacity.node_budget"

    it "validates explicit resource envelopes and host/namespace capacity lemmas" $ do
      let request = Capacity.ResourceVector 250 256 512 1
          limit = Capacity.ResourceVector 500 512 1024 1
          tooSmallLimit = Capacity.ResourceVector 100 512 1024 1
          overReservedPlan =
            Capacity.defaultResourcePlan
              { Capacity.rke2_reserved = Capacity.ResourceVector 8000 2048 10240 1024
              }
          overQuotaPlan =
            Capacity.defaultResourcePlan
              { Capacity.namespace_quotas =
                  [ Capacity.NamespaceQuota
                      "keycloak"
                      (Capacity.ResourceVector 7000 13000 90000 160000)
                  ]
              }
          overConcurrentQuotaPlan =
            Capacity.defaultResourcePlan
              { Capacity.namespace_quotas =
                  map
                    ( \namespaceQuota ->
                        if Capacity.namespace_name namespaceQuota == "api"
                          then Capacity.NamespaceQuota "api" (Capacity.ResourceVector 500 3000 2000 1000)
                          else namespaceQuota
                    )
                    (Capacity.namespace_quotas Capacity.defaultResourcePlan)
              }
          shrinkKeycloakQuota namespaceQuota =
            if Capacity.namespace_name namespaceQuota == "keycloak"
              then Capacity.NamespaceQuota "keycloak" (Capacity.ResourceVector 1 1 1 1)
              else namespaceQuota
          workloadOverQuotaPlan =
            Capacity.defaultResourcePlan
              { Capacity.namespace_quotas =
                  map shrinkKeycloakQuota (Capacity.namespace_quotas Capacity.defaultResourcePlan)
              }
      Capacity.mkMilliCpu 0 `shouldBe` Left "cpu must be positive"
      Capacity.mkMebiBytes 0 `shouldBe` Left "MiB value must be positive"
      Capacity.mkResourceEnvelope request limit `shouldBe` Right (Capacity.ResourceEnvelope request limit)
      Capacity.mkResourceEnvelope request tooSmallLimit
        `shouldBe` Left "resource request must fit within resource limit"
      Capacity.validateResourcePlan Capacity.defaultResourcePlan `shouldBe` Right ()
      Capacity.validateResourcePlan overReservedPlan
        `shouldBe` Left "capacity.resource_plan.rke2_reserved + eviction_floor must fit within host_capacity"
      Capacity.validateResourcePlan overQuotaPlan
        `shouldBe` Left
          "capacity.resource_plan.namespace_quotas[keycloak].quota must fit within cluster allocatable capacity"
      Capacity.validateResourcePlan overConcurrentQuotaPlan
        `shouldBe` Left
          "capacity.resource_plan.concurrent_namespace_quotas must fit within cluster allocatable capacity"
      Capacity.validateResourcePlan workloadOverQuotaPlan
        `shouldBe` Left
          "capacity.resource_plan.workload_profiles for namespace keycloak must fit within that namespace quota"

    it "decodes locally even when the ZeroSSL EAB binding is incomplete (AWS-tier check)" $
      -- The ACME / ZeroSSL binding is an AWS / public-edge concern, so the
      -- local decode path ('validateAndLoadSettings') accepts it; only the
      -- AWS tier ('validateAwsBootstrapConfig') enforces it.
      withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 invalidZeroSslConfig)

        localResult <- validateAndLoadSettingsAtPath (tmpDir </> "prodbox.dhall") tmpDir
        case localResult of
          Left err -> expectationFailure ("local validation must accept it: " ++ err)
          Right _ -> pure ()

        configResult <- loadConfigFileAtPath (tmpDir </> "prodbox.dhall")
        case configResult of
          Left err -> expectationFailure err
          Right config ->
            case validateAwsBootstrapConfig config of
              Left err -> err `shouldContain` "required for ZeroSSL ACME"
              Right () -> expectationFailure "expected AWS-tier validation failure"

    -- Sprint 7.15 leak guard: a plaintext (non-Vault) ACME EAB reference must
    -- be rejected at the AWS tier, mirroring the aws.* SecretRef.Vault
    -- discipline. The EAB key ID and HMAC key live in Vault (secret/acme/eab),
    -- never inline in prodbox.dhall.
    it "rejects a plaintext ACME EAB reference at the AWS tier" $
      withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 plaintextEabZeroSslConfig)

        configResult <- loadConfigFileAtPath (tmpDir </> "prodbox.dhall")
        case configResult of
          Left err -> expectationFailure err
          Right config ->
            case validateAwsBootstrapConfig config of
              Left err -> err `shouldContain` "must be a SecretRef.Vault reference"
              Right () ->
                expectationFailure "expected plaintext EAB reference to be rejected"

    it "fails fast with setup guidance when the repo Dhall config is missing" $
      withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
        result <- validateAndLoadSettingsAtPath (tmpDir </> "prodbox.dhall") tmpDir

        case result of
          Left err -> do
            err `shouldContain` "Missing required repository config"
            err `shouldContain` (tmpDir </> "prodbox.dhall")
            err `shouldContain` "./.build/prodbox config setup"
          Right _ -> expectationFailure "expected missing-config failure"

renderAllLeafHelpPages :: String
renderAllLeafHelpPages =
  unlines
    ( concatMap renderLeafSection leafCommandPaths
        ++ ["-- end --"]
    )
 where
  renderLeafSection commandPath =
    case findCommandSpec commandPath of
      Just spec ->
        [ "## prodbox " ++ unwords commandPath
        , renderCommandHelp commandPath spec
        ]
      Nothing -> ["## missing " ++ unwords commandPath]

parseArgs :: [String] -> Either String Options
parseArgs argv =
  case validateCommandArgv argv of
    Left err -> Left err
    Right () ->
      case execParserPure defaultPrefs parserInfo argv of
        Success options -> Right options
        Failure failure ->
          let (message, _) = renderFailure failure "prodbox"
           in Left message
        CompletionInvoked _ -> Left "shell completion requested"

makeExecutable :: FilePath -> IO ()
makeExecutable path = do
  permissions <- getPermissions path
  setPermissions path permissions {executable = True}

keycloakInvitePlainFixture :: BL8.ByteString
keycloakInvitePlainFixture =
  BL8.pack
    ( unlines
        [ "From: noreply@test.resolvefintech.com"
        , "To: invitee@inbox.test.resolvefintech.com"
        , "Subject: Verify your email"
        , "Content-Type: text/plain; charset=UTF-8"
        , ""
        , "Hi,"
        , ""
        , "Please follow this link to activate your account:"
        , "https://test.resolvefintech.com/auth/realms/prodbox/login-actions/action-token?key=abc123"
        , ""
        , "Thanks."
        ]
    )

keycloakInviteQuotedPrintableFixture :: BL8.ByteString
keycloakInviteQuotedPrintableFixture =
  BL8.pack
    ( unlines
        [ "From: noreply@test.resolvefintech.com"
        , "To: invitee@inbox.test.resolvefintech.com"
        , "Subject: Verify your email"
        , "Content-Type: text/plain; charset=UTF-8"
        , "Content-Transfer-Encoding: quoted-printable"
        , ""
        , "Please activate:"
        , "https://test.resolvefintech.com/auth/realms/prodbox/login-act=\r"
        , "ions/action-token?key=def456"
        , ""
        , "Thanks."
        ]
    )

keycloakInviteMultipartDuplicateFixture :: BL8.ByteString
keycloakInviteMultipartDuplicateFixture =
  BL8.pack
    ( unlines
        [ "From: noreply@test.resolvefintech.com"
        , "To: invitee@inbox.test.resolvefintech.com"
        , "Subject: Verify your email"
        , "Content-Type: multipart/alternative; boundary=\"invite-boundary\""
        , ""
        , "--invite-boundary"
        , "Content-Type: text/plain; charset=UTF-8"
        , ""
        , "https://test.resolvefintech.com/auth/realms/prodbox/login-actions/action-token?key=ghi789"
        , "--invite-boundary"
        , "Content-Type: text/html; charset=UTF-8"
        , "Content-Transfer-Encoding: quoted-printable"
        , ""
        , "<a href=3D\"https://test.resolvefintech.com/auth/realms/prodbox/login-actions/action-token?key=3Dghi789\">Activate</a>"
        , "--invite-boundary--"
        ]
    )

keycloakInviteMultipleDistinctFixture :: BL8.ByteString
keycloakInviteMultipleDistinctFixture =
  BL8.pack
    ( unlines
        [ "From: noreply@test.resolvefintech.com"
        , "To: invitee@inbox.test.resolvefintech.com"
        , "Subject: Verify your email"
        , "Content-Type: text/plain; charset=UTF-8"
        , ""
        , "https://test.resolvefintech.com/auth/realms/prodbox/login-actions/action-token?key=first-token"
        , "https://test.resolvefintech.com/auth/realms/prodbox/login-actions/action-token?key=second-token"
        ]
    )

keycloakInviteMissingFixture :: BL8.ByteString
keycloakInviteMissingFixture =
  BL8.pack
    ( unlines
        [ "From: noreply@test.resolvefintech.com"
        , "To: invitee@inbox.test.resolvefintech.com"
        , "Subject: Welcome"
        , "Content-Type: text/plain; charset=UTF-8"
        , ""
        , "Hello — your invitation was processed."
        , "Contact support if you have questions."
        ]
    )

sesSmtpPasswordExampleSecret :: Text.Text
sesSmtpPasswordExampleSecret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

-- | Sprint 7.5.c.i test helper: detect that a `helm upgrade --install`
-- argument list contains the consecutive pair `["--set", target]`
-- somewhere in its flat alternating-arg layout. This is preferable to
-- a naive `elem target args` because `target` itself could
-- accidentally land in a different argument position (e.g. as a
-- chart-ref name fragment); requiring `--set` immediately before it
-- pins the intent to "this is a Helm value override".
consecutivePair :: [String] -> String -> Bool
consecutivePair args target = go args
 where
  go ("--set" : value : rest)
    | value == target = True
    | otherwise = go rest
  go (_ : rest) = go rest
  go [] = False

-- | Sprint 7.5.c.iii orchestration ordering helper: both indices must be
-- present and the first must strictly precede the second. Extracted from
-- inline lambdas so HLint's @Avoid case inside lambda body@ stays clean.
indexPrecedes :: Maybe Int -> Maybe Int -> Bool
indexPrecedes (Just earlier) (Just later) = earlier < later
indexPrecedes _ _ = False

isRetainedSesPreparationStep :: RestoreCycleStep -> Bool
isRetainedSesPreparationStep restoreStep =
  case restoreStep of
    RestorePrepareRetainedSes _ -> True
    _ -> False

fakeAwsTestSshScript :: [String]
fakeAwsTestSshScript =
  [ "#!/usr/bin/env bash"
  , "set -eu"
  , "state_dir=\"${PRODBOX_TEST_SSH_STATE_DIR:?}\""
  , "count_file=\"$state_dir/count\""
  , "count=0"
  , "if [ -f \"$count_file\" ]; then"
  , "  count=$(cat \"$count_file\")"
  , "fi"
  , "count=$((count + 1))"
  , "printf '%s' \"$count\" > \"$count_file\""
  , "if [ \"$count\" -lt 3 ]; then"
  , "  echo \"ssh: connect to host 203.0.113.10 port 22: Connection refused\" >&2"
  , "  exit 255"
  , "fi"
  , "echo \"aws-test-node-0\""
  ]

fakeAwsCredentialPropagationScript :: FilePath -> [String]
fakeAwsCredentialPropagationScript stateDir =
  [ "#!/usr/bin/env bash"
  , "set -euo pipefail"
  , "STATE_DIR=\"" ++ stateDir ++ "\""
  , "COUNT_FILE=\"$STATE_DIR/sts-count\""
  , "/bin/mkdir -p \"$STATE_DIR\""
  , "if [[ \"${1:-}\" == \"--version\" ]]; then"
  , "  printf 'aws-cli/2.17.0 Python/3.12.0 Linux/6.8.0 exe/x86_64\\n'"
  , "  exit 0"
  , "fi"
  , "if [[ \"$*\" != 'sts get-caller-identity --output json' ]]; then"
  , "  printf 'unsupported fake aws command: %s\\n' \"$*\" >&2"
  , "  exit 1"
  , "fi"
  , "count=0"
  , "if [[ -f \"$COUNT_FILE\" ]]; then"
  , "  count=$(cat \"$COUNT_FILE\")"
  , "fi"
  , "count=$((count + 1))"
  , "printf '%s' \"$count\" > \"$COUNT_FILE\""
  , "if [[ $count -lt 3 ]]; then"
  , "  printf 'An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid.\\n' >&2"
  , "  exit 254"
  , "fi"
  , "cat <<'JSON'"
  , "{\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/prodbox\",\"UserId\":\"AIDAFake\"}"
  , "JSON"
  ]

-- | Sprint 5.6: resolve a 'PrerequisiteId' by its stable display string
-- ('prerequisiteIdText'). Lets the prerequisite-registry tests keep
-- asserting the stable snake_case identifiers while the registry is keyed
-- by the typed ADT.
prerequisiteIdFromText :: String -> PrerequisiteId
prerequisiteIdFromText text =
  case lookup text [(prerequisiteIdText pid, pid) | pid <- [minBound .. maxBound]] of
    Just pid -> pid
    Nothing -> error ("unknown prerequisite id in test: " ++ text)

lookupPrerequisiteNode :: String -> EffectNode
lookupPrerequisiteNode prerequisiteId =
  case Map.lookup (prerequisiteIdFromText prerequisiteId) prerequisiteRegistry of
    Just node -> node
    Nothing -> error ("missing prerequisite in test registry: " ++ prerequisiteId)

lookupPrerequisiteEffect :: String -> Effect
lookupPrerequisiteEffect = effectNodeEffect . lookupPrerequisiteNode

-- | The declared prerequisite edges of a registry node, as their stable
-- display strings (so the dependency-chain assertions stay readable while
-- the registry is keyed by the typed 'PrerequisiteId').
lookupPrereqTexts :: String -> [String]
lookupPrereqTexts =
  map prerequisiteIdText . effectNodePrerequisites . lookupPrerequisiteNode

-- | Resolve a transitive closure over the production registry from
-- string roots, returning the closure's stable display strings — a
-- text-facing adapter over the typed 'transitiveClosureIds' so the
-- closure assertions stay readable.
transitiveClosureTexts :: [String] -> Either String [String]
transitiveClosureTexts roots =
  fmap
    (map prerequisiteIdText)
    (transitiveClosureIds (map prerequisiteIdFromText roots) prerequisiteRegistry)

-- | Build a synthetic `EffectNode` for construction-time acyclicity tests (Sprint 1.31). The
-- effect is `Noop`; only the id and dependency edges matter to the pure DAG construction path.
-- Sprint 5.6: the synthetic nodes are keyed by real 'PrerequisiteId'
-- constructors with deliberately rewired dependency edges (the production
-- registry is acyclic, so a synthetic cyclic shape is built by re-pointing
-- the edges, not by inventing string ids).
cycleNode :: PrerequisiteId -> [PrerequisiteId] -> EffectNode
cycleNode nodeId prerequisites = effectNode nodeId prerequisites Noop

-- | Build a synthetic `EffectNode` with an explicit effect (used by the interpreter memo test).
effectNode :: PrerequisiteId -> [PrerequisiteId] -> Effect -> EffectNode
effectNode nodeId prerequisites effect =
  EffectNode
    { effectNodeId = nodeId
    , effectNodeDescription = "synthetic test node " ++ prerequisiteIdText nodeId
    , effectNodeRemedyHint = "synthetic test node " ++ prerequisiteIdText nodeId
    , effectNodePrerequisites = prerequisites
    , effectNodeEffect = effect
    }

isRightResult :: Either a b -> Bool
isRightResult = either (const False) (const True)

hasCycle :: Set.Set PrerequisiteId -> PrerequisiteId -> Bool
hasCycle visited prerequisiteId
  | Set.member prerequisiteId visited = True
  | otherwise =
      case Map.lookup prerequisiteId prerequisiteRegistry of
        Nothing -> False
        Just node ->
          any (hasCycle (Set.insert prerequisiteId visited)) (effectNodePrerequisites node)

validConfig :: String
validConfig =
  unlines
    [ "{ aws = " ++ awsCredentialRefDhall "gateway/gateway/aws" "us-east-1"
    , ", route53 = { zone_id = \"Z1234567890ABC\" }"
    , ", aws_substrate = { hosted_zone_id = \"\", subzone_name = \"\" }"
    , ", ses = { sender_domain = \"\", receive_subdomain = \"\", capture_bucket = \"\" }"
    , ", domain = { demo_fqdn = \"test.resolvefintech.com\", demo_ttl = 60 }"
    , ", acme = " ++ acmeSectionDhall (eabRefDhall "key_id") (eabRefDhall "hmac_key")
    , ", deployment = " ++ deploymentDhallFragment
    , ", capacity = " ++ capacityDhallFragment
    , ", cluster_topology = " ++ clusterTopologyDhallFragment
    , ", storage = { manual_pv_host_root = \".data\" }"
    , ", pulumi_state_backend = " ++ pulumiStateBackendDhallFragment
    , ", components = " ++ componentsDhallFragment
    , "}"
    ]
invalidZeroSslConfig :: String
invalidZeroSslConfig =
  unlines
    [ "{ aws = " ++ awsCredentialRefDhall "gateway/gateway/aws" "us-east-1"
    , ", route53 = { zone_id = \"Z1234567890ABC\" }"
    , ", aws_substrate = { hosted_zone_id = \"\", subzone_name = \"\" }"
    , ", ses = { sender_domain = \"\", receive_subdomain = \"\", capture_bucket = \"\" }"
    , ", domain = { demo_fqdn = \"test.resolvefintech.com\", demo_ttl = 60 }"
    , ", acme = "
        ++ acmeSectionDhall
          ("None (" ++ secretRefTypeDhall ++ ")")
          ("None (" ++ secretRefTypeDhall ++ ")")
    , ", deployment = " ++ deploymentDhallFragment
    , ", capacity = " ++ capacityDhallFragment
    , ", cluster_topology = " ++ clusterTopologyDhallFragment
    , ", storage = { manual_pv_host_root = \".data\" }"
    , ", pulumi_state_backend = " ++ pulumiStateBackendDhallFragment
    , ", components = " ++ componentsDhallFragment
    , "}"
    ]

-- | Sprint 7.15 leak-guard fixture: a ZeroSSL config whose EAB references
-- carry plaintext @TestPlaintext@ values instead of @SecretRef.Vault@. The
-- AWS-tier validator must reject it.
plaintextEabZeroSslConfig :: String
plaintextEabZeroSslConfig =
  unlines
    [ "{ aws = " ++ awsCredentialRefDhall "gateway/gateway/aws" "us-east-1"
    , ", route53 = { zone_id = \"Z1234567890ABC\" }"
    , ", aws_substrate = { hosted_zone_id = \"\", subzone_name = \"\" }"
    , ", ses = { sender_domain = \"\", receive_subdomain = \"\", capture_bucket = \"\" }"
    , ", domain = { demo_fqdn = \"test.resolvefintech.com\", demo_ttl = 60 }"
    , ", acme = "
        ++ acmeSectionDhall
          ("Some (" ++ secretRefTypeDhall ++ ".TestPlaintext \"test-eab-key-id\")")
          ("Some (" ++ secretRefTypeDhall ++ ".TestPlaintext \"test-eab-hmac-key\")")
    , ", deployment = " ++ deploymentDhallFragment
    , ", capacity = " ++ capacityDhallFragment
    , ", cluster_topology = " ++ clusterTopologyDhallFragment
    , ", storage = { manual_pv_host_root = \".data\" }"
    , ", pulumi_state_backend = " ++ pulumiStateBackendDhallFragment
    , ", components = " ++ componentsDhallFragment
    , "}"
    ]

-- | Sprint 7.15: an @acme@ section with the given Optional SecretRef
-- expressions for @eab_key_id@ / @eab_hmac_key@ (the EAB material now
-- references Vault rather than carrying plaintext).
acmeSectionDhall :: String -> String -> String
acmeSectionDhall eabKeyIdExpr eabHmacKeyExpr =
  "{ email = \"test@resolvefintech.com\""
    ++ ", server = \"https://acme.zerossl.com/v2/DV90\""
    ++ ", eab_key_id = "
    ++ eabKeyIdExpr
    ++ ", eab_hmac_key = "
    ++ eabHmacKeyExpr
    ++ " }"

-- | A @Some SecretRef.Vault@ expression into @secret/acme/eab@ for the
-- given field, in the schema-less inline-union style the unit fixtures use.
eabRefDhall :: String -> String
eabRefDhall fieldValue =
  "Some (" ++ vaultSecretRefDhall "acme/eab" fieldValue ++ ")"

awsCredentialRefDhall :: String -> String -> String
awsCredentialRefDhall pathValue regionValue =
  "{ access_key_id = "
    ++ vaultSecretRefDhall pathValue "access_key_id"
    ++ ", secret_access_key = "
    ++ vaultSecretRefDhall pathValue "secret_access_key"
    ++ ", session_token = None ("
    ++ secretRefTypeDhall
    ++ "), region = "
    ++ show regionValue
    ++ " }"

vaultSecretRefDhall :: String -> String -> String
vaultSecretRefDhall pathValue fieldValue =
  secretRefTypeDhall
    ++ ".Vault { mount = \"secret\", path = "
    ++ show pathValue
    ++ ", field = "
    ++ show fieldValue
    ++ " }"

secretRefTypeDhall :: String
secretRefTypeDhall =
  "< Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text >"

-- Sprint 1.56: 'componentsDhallFragment' (the inline empty @components@ field the
-- schema-less fixtures carry) is shared from "TestSupport".

-- | Sprint 4.15 helper: assert that a 'DrainResult' maps to a
-- 'CascadeContinue' arm. Extracted to a named helper to satisfy the
-- `Refactor nested case` lint rule (no `case` inside `lambda` body).
assertSkipIsSuccess :: (String, DrainResult) -> Expectation
assertSkipIsSuccess (label, result) = case cascadeDecisionFromDrainResult result of
  CascadeContinue _ -> pure ()
  CascadeAbort reason ->
    expectationFailure
      (label ++ " must map to CascadeContinue but got CascadeAbort: " ++ reason)

-- | Sprint 4.16 test fixtures.
residueFixtureDetails :: Residue.ResidueDetails
residueFixtureDetails =
  Residue.ResidueDetails
    { Residue.residueEvidence = "file-existence: /some/snapshot.json"
    , Residue.residueStackName = "aws-eks"
    }

residueFixtureMinioReason :: Residue.ResidueUnreachableReason
residueFixtureMinioReason = Residue.ResidueBackendMinioUnreachable "connection refused"

residueFixtureS3Reason :: Residue.ResidueUnreachableReason
residueFixtureS3Reason = Residue.ResidueBackendS3Unreachable "credentials missing"

-- | Sprint 4.17 helper fixture: stack-present value with placeholder
-- details, suitable for cascade-inventory tests where the stack name
-- is asserted at the consumer rather than inside the fixture.
residueFixturePresent :: Residue.ResidueStatus
residueFixturePresent = Residue.ResiduePresent residueFixtureDetails

-- | Sprint 4.16 helper: 'ResiduePresent' value with the given stack
-- name embedded in the details. Suitable for tests that need to assert
-- on the canonical destroy command list returned by
-- 'categorizePulumiResidue'.
residuePresentFor :: String -> Residue.ResidueStatus
residuePresentFor stackName =
  Residue.ResiduePresent
    Residue.ResidueDetails
      { Residue.residueEvidence = "test fixture: stack present"
      , Residue.residueStackName = stackName
      }

-- | Sprint 4.16 helper: zero-residue per-run statuses (all three
-- per-run stacks absent). Tests override individual fields when the
-- scenario requires presence.
absentPerRunStatuses :: PerRunResidueStatuses
absentPerRunStatuses =
  PerRunResidueStatuses
    { perRunAwsEksTest = Residue.ResidueAbsent
    , perRunAwsEksSubzone = Residue.ResidueAbsent
    , perRunAwsTest = Residue.ResidueAbsent
    }

-- | Sprint 4.26: the parallel hand-maintained @Prodbox.Aws.categorizePulumiResidue@
-- classifier was retired in favor of the registry-derived residue path
-- ('ResourceRegistry.pairPerRunResidue' + 'pairAwsSesResidue' +
-- 'residueGateRefusalList'). This local helper exercises exactly that
-- registry path under the old signature, so every existing assertion below
-- now proves the registry-derived @(stack-name, destroy-command)@ output
-- matches the retired classifier's output verbatim (a behavior-preserving
-- retirement).
categorizePulumiResidue
  :: PerRunResidueStatuses -> Residue.ResidueStatus -> [(String, String)]
categorizePulumiResidue perRun sesStatus =
  ResourceRegistry.residueGateRefusalList
    ( ResourceRegistry.pairPerRunResidue
        (perRunAwsEksTest perRun)
        (perRunAwsEksSubzone perRun)
        (perRunAwsTest perRun)
        ++ ResourceRegistry.pairAwsSesResidue sesStatus
    )

pulumiStateBackendDhallFragment :: String
pulumiStateBackendDhallFragment =
  "{ bucket_name = \"\", region = \"\", key_prefix = \"pulumi/\" }"

deploymentDhallFragment :: String
deploymentDhallFragment =
  concat
    [ "{ dev_mode = True"
    , ", bootstrap_public_ip_override = None Text"
    , ", pulumi_enable_dns_bootstrap = True"
    , ", public_edge_advertisement_mode = None Text"
    , ", public_edge_bgp_peers ="
    , "    None (List { peer_name : Text, peer_address : Text, peer_asn : Natural, my_asn : Natural, ebgp_multi_hop : Optional Bool })"
    , ", envoy_gateway_controller_scaling = " ++ fixedScalingDhall 1
    , ", envoy_gateway_data_plane_scaling = " ++ fixedScalingDhall 1
    , ", api_scaling = " ++ fixedScalingDhall 2
    , ", websocket_scaling = " ++ fixedScalingDhall 2
    , " }"
    ]

scalingPolicyTypeDhall :: String
scalingPolicyTypeDhall =
  "< Fixed : Natural | Elastic : { min : Natural, max : Natural } >"

fixedScalingDhall :: Int -> String
fixedScalingDhall count =
  "{ home_local = "
    ++ scalingPolicyTypeDhall
    ++ ".Fixed "
    ++ show count
    ++ ", aws = "
    ++ scalingPolicyTypeDhall
    ++ ".Fixed "
    ++ show count
    ++ " }"

capacityDhallFragment :: String
capacityDhallFragment =
  unlines
    [ "{ node_budget = { cpu = 8, memory = 16, storage = 100 }"
    , ", workload_budget = { cpu = 4, memory = 8, storage = 40 }"
    , ", region_quota = { cpu = 32, memory = 64, storage = 500 }"
    , ", resource_plan = " ++ resourcePlanDhallFragment
    , ", runtime_memory_profiles = " ++ runtimeMemoryProfilesDhallFragment
    , "}"
    ]

runtimeMemoryProfilesDhallFragment :: String
runtimeMemoryProfilesDhallFragment =
  "[ { runtime_profile_id = \"gateway\", bounded_application_state_bytes = 67108864, bounded_pending_persistence_state_bytes = 16777216, bounded_in_heap_transport_decode_bytes = 67108864, other_heap_reserve_bytes = 50331648, heap_cap_bytes = 268435456, native_non_heap_reserve_bytes = 67108864, child_process_budget = { permit_capacity = Some 1, action_deadline_milliseconds = Some 30000, simultaneous_peak_bytes = [ 67108864 ] }, kernel_cgroup_reserve_bytes = 33554432, safety_margin_bytes = 67108864 } ]"

resourcePlanDhallFragment :: String
resourcePlanDhallFragment =
  unlines
    [ "{ host_capacity = { milli_cpu = 8000, memory_mib = 15872, ephemeral_storage_mib = 100000, durable_storage_mib = 180000 }"
    , ", rke2_reserved = { milli_cpu = 1000, memory_mib = 2048, ephemeral_storage_mib = 10240, durable_storage_mib = 1024 }"
    , ", eviction_floor = { milli_cpu = 500, memory_mib = 1024, ephemeral_storage_mib = 10240, durable_storage_mib = 1024 }"
    , ", namespace_quotas ="
    , "  [ { namespace_name = \"keycloak\", quota = { milli_cpu = 2025, memory_mib = 4448, ephemeral_storage_mib = 12000, durable_storage_mib = 61440 } }"
    , "  , { namespace_name = \"vscode\", quota = { milli_cpu = 2425, memory_mib = 5216, ephemeral_storage_mib = 10944, durable_storage_mib = 112640 } }"
    , "  , { namespace_name = \"api\", quota = { milli_cpu = 500, memory_mib = 768, ephemeral_storage_mib = 2000, durable_storage_mib = 1000 } }"
    , "  , { namespace_name = \"websocket\", quota = { milli_cpu = 500, memory_mib = 768, ephemeral_storage_mib = 3000, durable_storage_mib = 1000 } }"
    , "  , { namespace_name = \"gateway\", quota = { milli_cpu = 1250, memory_mib = 3584, ephemeral_storage_mib = 6000, durable_storage_mib = 20480 } }"
    , "  , { namespace_name = \"prodbox\", quota = { milli_cpu = 1000, memory_mib = 1792, ephemeral_storage_mib = 5000, durable_storage_mib = 20480 } }"
    , "  , { namespace_name = \"vault\", quota = { milli_cpu = 300, memory_mib = 512, ephemeral_storage_mib = 2000, durable_storage_mib = 1024 } }"
    , "  ]"
    , ", workload_profiles ="
    , "  [ " ++ resourceProfileDhall "keycloak" "keycloak" 1 (500, 1024, 1024, 1) (600, 1280, 2048, 1)
    , "  , "
        ++ resourceProfileDhall "keycloak-vault-secrets" "keycloak" 1 (50, 128, 256, 1) (100, 256, 512, 1)
    , "  , "
        ++ resourceProfileDhall "keycloak-postgres" "keycloak" 3 (250, 512, 1024, 1024) (350, 768, 2048, 2048)
    , "  , "
        ++ resourceProfileDhall
          "keycloak-postgres-replica-cert-copy"
          "keycloak"
          3
          (10, 16, 32, 1)
          (25, 32, 64, 1)
    , "  , "
        ++ resourceProfileDhall
          "keycloak-postgres-vault-secrets"
          "keycloak"
          1
          (50, 128, 256, 1)
          (100, 256, 512, 1)
    , "  , "
        ++ resourceProfileDhall
          "keycloak-postgres-secret-materializer"
          "keycloak"
          1
          (50, 128, 256, 1)
          (100, 256, 512, 1)
    , "  , " ++ resourceProfileDhall "vscode" "vscode" 1 (500, 1024, 1024, 1024) (600, 1280, 2048, 2048)
    , "  , "
        ++ resourceProfileDhall "vscode-vault-secrets" "vscode" 1 (50, 128, 256, 1) (100, 256, 512, 1)
    , "  , "
        ++ resourceProfileDhall "vscode-secret-materializer" "vscode" 1 (50, 128, 256, 1) (100, 256, 512, 1)
    , "  , " ++ resourceProfileDhall "api" "api" 2 (250, 256, 512, 1) (250, 384, 512, 1)
    , "  , " ++ resourceProfileDhall "websocket" "websocket" 2 (100, 256, 512, 1) (150, 256, 512, 1)
    , "  , " ++ resourceProfileDhall "redis" "websocket" 1 (100, 256, 512, 1) (150, 256, 512, 1)
    , "  , " ++ resourceProfileDhall "gateway" "gateway" 3 (250, 256, 512, 1) (250, 512, 512, 1)
    , "  , " ++ resourceProfileDhall "pulsar" "gateway" 1 (250, 1024, 1024, 1) (500, 2048, 4096, 1)
    , "  , " ++ resourceProfileDhall "minio" "prodbox" 1 (250, 512, 1024, 1024) (500, 1024, 2048, 2048)
    , "  , " ++ resourceProfileDhall "harbor" "prodbox" 1 (200, 256, 512, 1024) (300, 512, 1024, 2048)
    , "  , "
        ++ resourceProfileDhall "percona-postgres-operator" "prodbox" 1 (100, 128, 512, 1) (150, 256, 1024, 1)
    , "  , " ++ resourceProfileDhall "vault" "vault" 1 (200, 256, 1024, 1) (250, 512, 1024, 1)
    , "  ]"
    , "}"
    ]

resourceProfileDhall
  :: String
  -> String
  -> Int
  -> (Int, Int, Int, Int)
  -> (Int, Int, Int, Int)
  -> String
resourceProfileDhall profile namespace count req lim =
  "{ profile_id = "
    ++ show profile
    ++ ", profile_namespace = "
    ++ show namespace
    ++ ", replicas = "
    ++ show count
    ++ ", resources = { request = "
    ++ resourceVectorDhall req
    ++ ", limit = "
    ++ resourceVectorDhall lim
    ++ " } }"

resourceVectorDhall :: (Int, Int, Int, Int) -> String
resourceVectorDhall (cpuMilli, memoryMib, ephemeralMib, durableMib) =
  "{ milli_cpu = "
    ++ show cpuMilli
    ++ ", memory_mib = "
    ++ show memoryMib
    ++ ", ephemeral_storage_mib = "
    ++ show ephemeralMib
    ++ ", durable_storage_mib = "
    ++ show durableMib
    ++ " }"

clusterTopologyDhallFragment :: String
clusterTopologyDhallFragment =
  clusterTopologyDhallType
    ++ ".Rke2 { machines = [ "
    ++ clusterTopologyMachineDhall
    ++ " ] : List "
    ++ clusterTopologyMachineTypeDhall
    ++ " }"

testTopologyDhallDocument :: FilePath -> String
testTopologyDhallDocument repoRoot =
  unlines
    [ "let TestTopology = " ++ (repoRoot </> "dhall" </> "TestTopologySchema.dhall")
    , ""
    , "in  { suites ="
    , "        [ { name = \"ha-rke2-aws\""
    , "          , variants ="
    , "              [ { cluster ="
    , "                    TestTopology.Cluster.ClusterTopology.Rke2"
    , "                      { machines ="
    , "                          [ { machine_id = \"prodbox-home\""
    , "                            , machine_substrate = TestTopology.Cluster.WorkerSubstrate.LinuxCpu"
    , "                            , compute_worker ="
    , "                                { worker_substrate = TestTopology.Cluster.WorkerSubstrate.LinuxCpu"
    , "                                , manages_all_local_devices = True"
    , "                                }"
    , "                            }"
    , "                          ] : List TestTopology.Cluster.Machine"
    , "                      }"
    , "                , replicas = 1"
    , "                , failover = Some TestTopology.FailoverScenario.LeaderKill"
    , "                }"
    , "              ] : List TestTopology.RunVariant"
    , "          , budget = { max_nodes = 2, wall_clock_seconds = 5400 }"
    , "          , fixtures = [ TestTopology.FixtureId.AwsAdminForTestSimulation ] : List TestTopology.FixtureId"
    , "          }"
    , "        ] : List TestTopology.Suite"
    , "    , fixtures = [ TestTopology.FixtureId.AwsAdminForTestSimulation ] : List TestTopology.FixtureId"
    , "    }"
    ]

clusterTopologyDhallType :: String
clusterTopologyDhallType =
  "< Kind : { machine : "
    ++ clusterTopologyMachineTypeDhall
    ++ ", node_count : Natural } | Rke2 : { machines : List "
    ++ clusterTopologyMachineTypeDhall
    ++ " } | Eks : { node_group_size : Natural, eks_substrate : "
    ++ workerSubstrateDhallType
    ++ " } >"

clusterTopologyMachineTypeDhall :: String
clusterTopologyMachineTypeDhall =
  "{ machine_id : Text, machine_substrate : "
    ++ workerSubstrateDhallType
    ++ ", compute_worker : { worker_substrate : "
    ++ workerSubstrateDhallType
    ++ ", manages_all_local_devices : Bool } }"

clusterTopologyMachineDhall :: String
clusterTopologyMachineDhall =
  "{ machine_id = \"prodbox-home\", machine_substrate = "
    ++ workerSubstrateDhallType
    ++ ".LinuxCpu, compute_worker = { worker_substrate = "
    ++ workerSubstrateDhallType
    ++ ".LinuxCpu, manages_all_local_devices = True } }"

workerSubstrateDhallType :: String
workerSubstrateDhallType =
  "< LinuxCpu | LinuxCuda | AppleMetal | CudaWindows >"

resourceGuardrailPodsFixture :: Value
resourceGuardrailPodsFixture =
  object
    [ "items"
        .= Array
          ( Vector.fromList
              [ resourceGuardrailPod "keycloak" "keycloak-0" "keycloak"
              , resourceGuardrailPod "vscode" "vscode-0" "vscode"
              , resourceGuardrailPod "api" "api-0" "api"
              , resourceGuardrailPod "websocket" "websocket-0" "websocket"
              , resourceGuardrailPod "gateway" "gateway-0" "gateway"
              ]
          )
    ]

resourceGuardrailBadPodsFixture :: Value
resourceGuardrailBadPodsFixture =
  object
    [ "items"
        .= Array
          ( Vector.fromList
              [ object
                  [ "metadata" .= object ["namespace" .= ("api" :: String), "name" .= ("api-0" :: String)]
                  , "status" .= object ["qosClass" .= ("BestEffort" :: String)]
                  , "spec" .= object ["containers" .= Array (Vector.fromList [object ["name" .= ("api" :: String)]])]
                  ]
              ]
          )
    ]

resourceGuardrailPod :: String -> String -> String -> Value
resourceGuardrailPod namespace podName containerName =
  object
    [ "metadata" .= object ["namespace" .= namespace, "name" .= podName]
    , "status" .= object ["qosClass" .= ("Burstable" :: String)]
    , "spec"
        .= object
          [ "containers"
              .= Array
                ( Vector.fromList
                    [ object
                        [ "name" .= containerName
                        , "resources"
                            .= object
                              [ "requests" .= resourceGuardrailRuntimeVector "100m" "128Mi" "256Mi"
                              , "limits" .= resourceGuardrailRuntimeVector "250m" "256Mi" "512Mi"
                              ]
                        ]
                    ]
                )
          ]
    ]

resourceGuardrailRuntimeVector :: String -> String -> String -> Value
resourceGuardrailRuntimeVector cpu memory ephemeral =
  object
    [ "cpu" .= cpu
    , "memory" .= memory
    , "ephemeral-storage" .= ephemeral
    ]

resourceGuardrailQuotaFixture :: Value
resourceGuardrailQuotaFixture =
  object
    [ "items"
        .= Array
          ( Vector.fromList
              [ resourceGuardrailQuota "keycloak" "2025m" "4448Mi" "12000Mi" "61440Mi"
              , resourceGuardrailQuota "vscode" "2425m" "5216Mi" "10944Mi" "112640Mi"
              , resourceGuardrailQuota "api" "500m" "768Mi" "2000Mi" "1000Mi"
              , resourceGuardrailQuota "websocket" "500m" "768Mi" "3000Mi" "1000Mi"
              , resourceGuardrailQuota "gateway" "1250m" "3584Mi" "6000Mi" "20480Mi"
              ]
          )
    ]

resourceGuardrailCanonicalQuotaFixture :: Value
resourceGuardrailCanonicalQuotaFixture =
  object
    [ "items"
        .= Array
          ( Vector.fromList
              [ resourceGuardrailQuota "keycloak" "2025m" "4448Mi" "12000Mi" "60Gi"
              , resourceGuardrailQuota "vscode" "2425m" "5216Mi" "10944Mi" "110Gi"
              , resourceGuardrailQuota "api" "500m" "768Mi" "2000Mi" "1000Mi"
              , resourceGuardrailQuota "websocket" "500m" "768Mi" "3000Mi" "1000Mi"
              , resourceGuardrailQuota "gateway" "1250m" "3584Mi" "6000Mi" "20Gi"
              ]
          )
    ]

resourceGuardrailQuota :: String -> String -> String -> String -> String -> Value
resourceGuardrailQuota namespace cpu memory ephemeral durable =
  object
    [ "metadata" .= object ["namespace" .= namespace, "name" .= (namespace ++ "-resource-quota")]
    , "spec"
        .= object
          [ "hard"
              .= object
                [ "requests.cpu" .= cpu
                , "limits.cpu" .= cpu
                , "requests.memory" .= memory
                , "limits.memory" .= memory
                , "requests.ephemeral-storage" .= ephemeral
                , "limits.ephemeral-storage" .= ephemeral
                , "requests.storage" .= durable
                ]
          ]
    ]

resourceGuardrailLimitRangeFixture :: Value
resourceGuardrailLimitRangeFixture =
  object
    [ "items"
        .= Array
          ( Vector.fromList
              [ resourceGuardrailLimitRange "keycloak" "500m" "1024Mi" "1024Mi" "600m" "1280Mi" "2048Mi"
              , resourceGuardrailLimitRange "vscode" "500m" "1024Mi" "1024Mi" "600m" "1280Mi" "2048Mi"
              , resourceGuardrailLimitRange "api" "250m" "256Mi" "512Mi" "250m" "384Mi" "512Mi"
              , resourceGuardrailLimitRange "websocket" "100m" "256Mi" "512Mi" "150m" "256Mi" "512Mi"
              , resourceGuardrailLimitRange "gateway" "250m" "256Mi" "512Mi" "250m" "512Mi" "512Mi"
              ]
          )
    ]

resourceGuardrailCanonicalLimitRangeFixture :: Value
resourceGuardrailCanonicalLimitRangeFixture =
  object
    [ "items"
        .= Array
          ( Vector.fromList
              [ resourceGuardrailLimitRange "keycloak" "500m" "1Gi" "1Gi" "600m" "1280Mi" "2Gi"
              , resourceGuardrailLimitRange "vscode" "500m" "1Gi" "1Gi" "600m" "1280Mi" "2Gi"
              , resourceGuardrailLimitRange "api" "250m" "256Mi" "512Mi" "250m" "384Mi" "512Mi"
              , resourceGuardrailLimitRange "websocket" "100m" "256Mi" "512Mi" "150m" "256Mi" "512Mi"
              , resourceGuardrailLimitRange "gateway" "250m" "256Mi" "512Mi" "250m" "512Mi" "512Mi"
              ]
          )
    ]

resourceGuardrailLimitRange
  :: String -> String -> String -> String -> String -> String -> String -> Value
resourceGuardrailLimitRange namespace reqCpu reqMemory reqEphemeral limitCpu limitMemory limitEphemeral =
  object
    [ "metadata" .= object ["namespace" .= namespace, "name" .= (namespace ++ "-limit-range")]
    , "spec"
        .= object
          [ "limits"
              .= Array
                ( Vector.fromList
                    [ object
                        [ "type" .= ("Container" :: String)
                        , "defaultRequest" .= resourceGuardrailRuntimeVector reqCpu reqMemory reqEphemeral
                        , "default" .= resourceGuardrailRuntimeVector limitCpu limitMemory limitEphemeral
                        ]
                    ]
                )
          ]
    ]

validDeploymentSection :: DeploymentSection
validDeploymentSection =
  DeploymentSection
    { dev_mode = True
    , bootstrap_public_ip_override = Nothing
    , pulumi_enable_dns_bootstrap = True
    , public_edge_advertisement_mode = Just "l2"
    , public_edge_bgp_peers = Nothing
    , envoy_gateway_controller_scaling = fixedScalingPolicyBySubstrate 1
    , envoy_gateway_data_plane_scaling = fixedScalingPolicyBySubstrate 1
    , api_scaling = fixedScalingPolicyBySubstrate 2
    , websocket_scaling = fixedScalingPolicyBySubstrate 2
    }

-- | Extract the @metadata.name@ of every cert-manager @ClusterIssuer@
-- resource in a rendered ACME runtime manifest, in order. Used to assert
-- 'acmeRuntimeManifestWith' renders the single ZeroSSL issuer.
clusterIssuerNamesIn :: [Value] -> [String]
clusterIssuerNamesIn = concatMap nameOf
 where
  nameOf (Object o)
    | KeyMap.lookup (Key.fromString "kind") o == Just (String "ClusterIssuer")
    , Just (Object meta) <- KeyMap.lookup (Key.fromString "metadata") o
    , Just (String name) <- KeyMap.lookup (Key.fromString "name") meta =
        [Text.unpack name]
  nameOf _ = []

expectResourceEnvelope
  :: KeyMap.KeyMap Value
  -> String
  -> (String, String, String)
  -> (String, String, String)
  -> Expectation
expectResourceEnvelope payload profileName requestValues limitValues =
  case KeyMap.lookup (Key.fromString "resources") payload of
    Just (Object resourcesPayload) ->
      case KeyMap.lookup (Key.fromString profileName) resourcesPayload of
        Just (Object envelopePayload) -> do
          expectResourceVector envelopePayload "requests" requestValues
          expectResourceVector envelopePayload "limits" limitValues
        _ -> expectationFailure ("expected resource envelope `" ++ profileName ++ "`")
    _ -> expectationFailure "expected resources payload"

expectResourceVector :: KeyMap.KeyMap Value -> String -> (String, String, String) -> Expectation
expectResourceVector envelopePayload fieldName (cpu, memory, ephemeralStorage) =
  case KeyMap.lookup (Key.fromString fieldName) envelopePayload of
    Just (Object vectorPayload) -> do
      expectTextField vectorPayload "cpu" cpu
      expectTextField vectorPayload "memory" memory
      expectTextField vectorPayload "ephemeral-storage" ephemeralStorage
    _ -> expectationFailure ("expected resource vector `" ++ fieldName ++ "`")

expectQuotaHard :: KeyMap.KeyMap Value -> String -> String -> Expectation
expectQuotaHard guardrailsPayload fieldName expected =
  case KeyMap.lookup (Key.fromString "quota") guardrailsPayload of
    Just (Object quotaPayload) ->
      case KeyMap.lookup (Key.fromString "hard") quotaPayload of
        Just (Object hardPayload) -> expectTextField hardPayload fieldName expected
        _ -> expectationFailure "expected quota hard payload"
    _ -> expectationFailure "expected quota payload"

expectLimitRangeDefault :: KeyMap.KeyMap Value -> String -> String -> Expectation
expectLimitRangeDefault = expectLimitRangeVector "default"

expectLimitRangeDefaultRequest :: KeyMap.KeyMap Value -> String -> String -> Expectation
expectLimitRangeDefaultRequest = expectLimitRangeVector "defaultRequest"

expectLimitRangeVector :: String -> KeyMap.KeyMap Value -> String -> String -> Expectation
expectLimitRangeVector vectorName guardrailsPayload fieldName expected =
  case KeyMap.lookup (Key.fromString "limitRange") guardrailsPayload of
    Just (Object limitRangePayload) ->
      case KeyMap.lookup (Key.fromString vectorName) limitRangePayload of
        Just (Object vectorPayload) -> expectTextField vectorPayload fieldName expected
        _ -> expectationFailure ("expected LimitRange `" ++ vectorName ++ "` payload")
    _ -> expectationFailure "expected LimitRange payload"

expectTextField :: KeyMap.KeyMap Value -> String -> String -> Expectation
expectTextField payload fieldName expected =
  KeyMap.lookup (Key.fromString fieldName) payload `shouldBe` Just (String (Text.pack expected))

testValidatedSettings :: FilePath -> ValidatedSettings
testValidatedSettings manualRoot =
  ValidatedSettings
    { validatedConfig =
        defaultConfigFile
          { aws =
              AwsCredentialsRef
                { awsCredentialAccessKeyId =
                    SecretRefVault (VaultSecretRef "secret" "gateway/gateway/aws" "access_key_id")
                , awsCredentialSecretAccessKey =
                    SecretRefVault (VaultSecretRef "secret" "gateway/gateway/aws" "secret_access_key")
                , awsCredentialSessionToken =
                    Just (SecretRefVault (VaultSecretRef "secret" "gateway/gateway/aws" "session_token"))
                , awsCredentialRegion = "us-east-1"
                }
          , route53 = Route53Section {zone_id = "Z1234567890ABC"}
          , aws_substrate =
              AwsSubstrateSection
                { hosted_zone_id = "ZAWSSUBZONE123"
                , subzone_name = "aws.test.resolvefintech.com"
                }
          , domain =
              DomainSection
                { demo_fqdn = "test.resolvefintech.com"
                , demo_ttl = 60
                }
          , deployment = validDeploymentSection
          , storage = StorageSection {manual_pv_host_root = ".data"}
          }
    , resolvedManualPvHostRoot = manualRoot
    }

sampleAwsSetupInput :: AwsSetupInput
sampleAwsSetupInput =
  AwsSetupInput
    { awsSetupAdminCredentials =
        Credentials
          { access_key_id = "admin-access-key"
          , secret_access_key = "admin-secret-key"
          , session_token = Just "admin-session-token"
          , region = "us-west-2"
          }
    , awsSetupPolicyTierInput = PolicyFull
    }

sampleAwsTeardownInput :: AwsTeardownInput
sampleAwsTeardownInput =
  AwsTeardownInput
    { awsTeardownAdminCredentials = awsSetupAdminCredentials sampleAwsSetupInput
    , awsTeardownResiduePolicy = RefuseOnAnyResidue
    }

sampleConfigSetupInput :: ConfigSetupInput
sampleConfigSetupInput =
  ConfigSetupInput
    { configSetupAdminCredentialsInput = awsSetupAdminCredentials sampleAwsSetupInput
    , configSetupRoute53ZoneIdInput = "Z1234567890ABC"
    , configSetupDemoFqdnInput = "test.resolvefintech.com"
    , configSetupDemoTtlInput = 60
    , configSetupAcmeEmailInput = "ops@resolvefintech.com"
    , configSetupAcmeServerInput = "https://acme.zerossl.com/v2/DV90"
    , configSetupAcmeEabKeyIdInput = Just "test-eab-key-id"
    , configSetupAcmeEabHmacKeyInput = Just "test-eab-hmac-key"
    , configSetupDevModeInput = True
    , configSetupBootstrapPublicIpOverrideInput = Just "203.0.113.10"
    , configSetupPulumiEnableDnsBootstrapInput = True
    , configSetupPublicEdgeAdvertisementModeInput = Just "bgp"
    , configSetupPublicEdgeBgpPeersInput =
        Just
          [ MetallbBgpPeer
              { peer_name = "router-a"
              , peer_address = "192.0.2.10"
              , peer_asn = 64512
              , my_asn = 64513
              , ebgp_multi_hop = Just True
              }
          ]
    , configSetupEnvoyGatewayControllerScalingInput = fixedScalingPolicyBySubstrate 1
    , configSetupEnvoyGatewayDataPlaneScalingInput = fixedScalingPolicyBySubstrate 1
    , configSetupApiScalingInput = fixedScalingPolicyBySubstrate 2
    , configSetupWebsocketScalingInput = fixedScalingPolicyBySubstrate 2
    , configSetupManualPvHostRootInput = "/tmp/prodbox/.data"
    , configSetupPolicyTierInput = PolicyFull
    }

roundTripConfigFile :: ConfigFile
roundTripConfigFile =
  defaultConfigFile
    { aws =
        AwsCredentialsRef
          { awsCredentialAccessKeyId =
              SecretRefVault (VaultSecretRef "secret" "gateway/gateway/aws" "access_key_id")
          , awsCredentialSecretAccessKey =
              SecretRefVault (VaultSecretRef "secret" "gateway/gateway/aws" "secret_access_key")
          , awsCredentialSessionToken =
              Just (SecretRefVault (VaultSecretRef "secret" "gateway/gateway/aws" "session_token"))
          , awsCredentialRegion = "us-east-1"
          }
    , route53 = Route53Section {zone_id = "Z1234567890ABC"}
    , domain =
        DomainSection
          { demo_fqdn = "test.resolvefintech.com"
          , demo_ttl = 60
          }
    , deployment =
        validDeploymentSection
          { bootstrap_public_ip_override = Just "203.0.113.10"
          , public_edge_advertisement_mode = Just "bgp"
          , public_edge_bgp_peers =
              Just
                [ MetallbBgpPeer
                    { peer_name = "router-a"
                    , peer_address = "192.0.2.10"
                    , peer_asn = 64512
                    , my_asn = 64513
                    , ebgp_multi_hop = Just True
                    }
                ]
          }
    , storage = StorageSection {manual_pv_host_root = ".data"}
    }

samplePeerEndpoint :: PeerEndpoint
samplePeerEndpoint =
  PeerEndpoint
    { peerNodeId = "node-a"
    , peerStableDnsName = "node-a.example.test"
    , peerRestHost = "0.0.0.0"
    , peerRestPort = 31001
    , peerSocketHost = "0.0.0.0"
    , peerSocketPort = 32001
    }

sampleOrders :: Orders
sampleOrders =
  Orders
    { ordersVersionUtc = 1
    , ordersNodes = [samplePeerEndpoint]
    , ordersGatewayRule =
        GatewayRule
          { rankedNodes = ["node-a"]
          , heartbeatTimeoutSeconds = 3
          }
    }

storedDaemonEvent :: String -> Integer -> Maybe UTCTime -> DaemonEvents.StoredEvent
storedDaemonEvent eventName createdSecond processedAt =
  DaemonEvents.StoredEvent
    { DaemonEvents.eventId = DaemonEvents.EventId eventName
    , DaemonEvents.eventAggregateId = DaemonEvents.AggregateId "aggregate-a"
    , DaemonEvents.eventType = DaemonEvents.EventType "heartbeat"
    , DaemonEvents.eventPayload = cborPayloadFromJsonValue (object ["event_name" .= eventName])
    , DaemonEvents.eventCreatedAt = testUtc createdSecond
    , DaemonEvents.eventProcessedAt = processedAt
    }

testUtc :: Integer -> UTCTime
testUtc seconds =
  UTCTime (fromGregorian 2026 5 13) (secondsToDiffTime seconds)

sampleAwsTestStackSnapshot :: AwsTest.AwsTestStackSnapshot
sampleAwsTestStackSnapshot =
  AwsTest.AwsTestStackSnapshot
    { AwsTest.testSnapshotStackName = AwsTest.awsTestStackName
    , AwsTest.testSnapshotBackendBucket = "prodbox-state"
    , AwsTest.testSnapshotVpcId = "vpc-1234567890"
    , AwsTest.testSnapshotSubnetIds = ["subnet-1", "subnet-2", "subnet-3"]
    , AwsTest.testSnapshotSecurityGroupId = "sg-1234567890"
    , AwsTest.testSnapshotNodes =
        [ AwsTest.AwsTestNode
            { AwsTest.testNodeName = "aws-test-node-0"
            , AwsTest.testNodeAvailabilityZone = "us-west-2a"
            , AwsTest.testNodeInstanceId = "i-1234567890"
            , AwsTest.testNodePrivateIp = "10.0.0.10"
            , AwsTest.testNodePublicIp = "203.0.113.10"
            }
        ]
    }

sampleAwsEksTestStackSnapshot :: AwsEks.AwsEksTestStackSnapshot
sampleAwsEksTestStackSnapshot =
  AwsEks.AwsEksTestStackSnapshot
    { AwsEks.eksSnapshotStackName = AwsEks.awsEksTestStackName
    , AwsEks.eksSnapshotBackendBucket = "prodbox-state"
    , AwsEks.eksSnapshotClusterName = "aws-eks-test-cluster"
    , AwsEks.eksSnapshotClusterRoleName = "aws-eks-test-cluster-role"
    , AwsEks.eksSnapshotNodeGroupName = "aws-eks-test-node-group"
    , AwsEks.eksSnapshotNodeRoleName = "aws-eks-test-node-role"
    , AwsEks.eksSnapshotVpcId = "vpc-1234567890"
    , AwsEks.eksSnapshotSubnetIds = ["subnet-a", "subnet-b"]
    , AwsEks.eksSnapshotClusterSecurityGroupId = "sg-0987654321"
    , AwsEks.eksSnapshotClusterOidcIssuer = "https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE"
    , AwsEks.eksSnapshotOidcProviderArn =
        "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE"
    , AwsEks.eksSnapshotAwsLbControllerPolicyArn =
        "arn:aws:iam::123456789012:policy/aws-eks-test-aws-lb-controller"
    , AwsEks.eksSnapshotAwsLbControllerRoleArn =
        "arn:aws:iam::123456789012:role/aws-eks-test-aws-lb-controller"
    , AwsEks.eksSnapshotAwsLbControllerRoleName = "aws-eks-test-aws-lb-controller"
    , AwsEks.eksSnapshotRetainedEbsAvailabilityZone = "us-east-1a"
    }

-- | Sprint 4.18: the flat @Map Text Text@ shape the Pulumi backend
-- emits for the @aws-test@ stack — scalar outputs verbatim, complex
-- outputs (@subnet_ids@, @nodes@) as JSON-encoded strings. Decodes
-- back to 'sampleAwsTestStackSnapshot' via 'parseAwsTestStackFromOutputs'.
sampleAwsTestStackOutputsMap :: Map.Map Text.Text Text.Text
sampleAwsTestStackOutputsMap =
  Map.fromList
    [ ("backend_bucket", "prodbox-state")
    , ("vpc_id", "vpc-1234567890")
    , ("subnet_ids", Text.pack "[\"subnet-1\",\"subnet-2\",\"subnet-3\"]")
    , ("security_group_id", "sg-1234567890")
    ,
      ( "nodes"
      , Text.pack
          ( "[{\"name\":\"aws-test-node-0\""
              ++ ",\"availability_zone\":\"us-west-2a\""
              ++ ",\"instance_id\":\"i-1234567890\""
              ++ ",\"private_ip\":\"10.0.0.10\""
              ++ ",\"public_ip\":\"203.0.113.10\"}]"
          )
      )
    ]

-- | Sprint 4.18: the flat @Map Text Text@ shape the Pulumi backend
-- emits for the @aws-eks-test@ stack. Decodes back to
-- 'sampleAwsEksTestStackSnapshot' via 'parseAwsEksTestStackFromOutputs'.
sampleAwsEksTestStackOutputsMap :: Map.Map Text.Text Text.Text
sampleAwsEksTestStackOutputsMap =
  Map.fromList
    [ ("backend_bucket", "prodbox-state")
    , ("cluster_name", "aws-eks-test-cluster")
    , ("cluster_role_name", "aws-eks-test-cluster-role")
    , ("node_group_name", "aws-eks-test-node-group")
    , ("node_role_name", "aws-eks-test-node-role")
    , ("vpc_id", "vpc-1234567890")
    , ("subnet_ids", Text.pack "[\"subnet-a\",\"subnet-b\"]")
    , ("cluster_security_group_id", "sg-0987654321")
    , ("cluster_oidc_issuer", "https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE")
    ,
      ( "oidc_provider_arn"
      , "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE"
      )
    , ("aws_lb_controller_policy_arn", "arn:aws:iam::123456789012:policy/aws-eks-test-aws-lb-controller")
    , ("aws_lb_controller_role_arn", "arn:aws:iam::123456789012:role/aws-eks-test-aws-lb-controller")
    , ("aws_lb_controller_role_name", "aws-eks-test-aws-lb-controller")
    , ("retained_ebs_availability_zone", "us-east-1a")
    ]

gatewaySecretRefType :: String
gatewaySecretRefType =
  "< Vault : { mount : Text, path : Text, field : Text } | TransitKey : Text | Prompt : { name : Text, purpose : Text } | TestPlaintext : Text >"

gatewayTestPlaintextRef :: String -> String
gatewayTestPlaintextRef value =
  gatewaySecretRefType ++ ".TestPlaintext " ++ show value

gatewayVaultNoneLines :: [String]
gatewayVaultNoneLines =
  [ ", vault ="
  , "    None { address : Text, auth_path : Text, role : Text, service_account_token_file : Optional Text }"
  ]

gatewayEventKeysEmptyLine :: String
gatewayEventKeysEmptyLine =
  "  , event_keys = [] : List { name : Text, value : " ++ gatewaySecretRefType ++ " }"

gatewayEventKeyTestPlaintextLines :: String -> String -> [String]
gatewayEventKeyTestPlaintextLines nodeName value =
  [ "  , event_keys ="
  , "    [ { name = "
      ++ show nodeName
      ++ ", value = "
      ++ gatewayTestPlaintextRef value
      ++ " } ]"
  ]

gatewayAwsCredsNoneLines :: [String]
gatewayAwsCredsNoneLines =
  [ "  , aws_creds ="
  , "      None { access_key_id : "
      ++ gatewaySecretRefType
      ++ ", secret_access_key : "
      ++ gatewaySecretRefType
      ++ ", session_token : Optional "
      ++ gatewaySecretRefType
      ++ ", region : Text }"
  ]

gatewayMinioCredsNoneLines :: [String]
gatewayMinioCredsNoneLines =
  [ "  , minio_creds ="
  , "      None { minio_access_key : "
      ++ gatewaySecretRefType
      ++ ", minio_secret_key : "
      ++ gatewaySecretRefType
      ++ " }"
  ]

testChartSecrets :: Map.Map String String
testChartSecrets =
  Map.fromList
    [ ("keycloak_admin_password", "adminpass")
    , ("keycloak_vscode_client_secret", "vscodesecret")
    , ("keycloak_api_client_secret", "apiclientsecret")
    , ("keycloak_websocket_client_secret", "websocketclientsecret")
    , ("keycloak_demo_user_password", "demouserpassword")
    , ("patroni_app_password", "patroniapppassword")
    , ("patroni_standby_password", "patronistandbypassword")
    , ("patroni_superuser_password", "patronisuperuserpassword")
    ]
