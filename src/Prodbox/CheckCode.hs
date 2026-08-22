module Prodbox.CheckCode
  ( DoctrineViolation (..)
  , GeneratedSectionRule (..)
  , awsCreateSiteViolations
  , awsCreateVerbs
  , bootstrapBrokerChartStaticViolations
  , bootstrapBrokerChartStaticsConformanceViolations
  , bootstrapBrokerIsolationViolations
  , ControlPlaneChartLint (..)
  , controlPlaneChartLints
  , controlPlaneChartStaticViolations
  , checkCommittedValueHygiene
  , checkCreateCallSiteCoverage
  , managedResourceRegistryParityViolations
  , untypedLifecycleInventoryExemptions
  , untypedLifecycleInventoryViolations
  , legacyOperationalResourceParityViolations
  , registeredTargetExecutorViolations
  , capabilityDependantDerivationViolations
  , ownershipEdgeDerivationViolations
  , codeCreatedResourceFieldOfViewViolations
  , checkRegisteredStackProvisioningPrograms
  , pulumiProjectNameIn
  , decommissionProgramTagParityViolations
  , decommissionInterpreterIdentityViolations
  , decommissionTerminalPhaseOrderViolations
  , effectRegistryLifecycleClassViolations
  , checkTestNamespaceBoundary
  , testNamespaceImportViolations
  , validationHarnessClientModules
  , checkWorkerImagePullReferenceOwner
  , checkForbidDotProdboxState
  , checkLegacyEscapeRegistry
  , checkAwsCoordinateLiterals
  , awsCoordinateLiteralRegistry
  , awsCoordinateLiteralsIn
  , awsCoordinateFindings
  , awsCoordinateRegistered
  , awsCoordinateRegistryOwners
  , AwsCoordinateLiteral (..)
  , AwsCoordinateReason (..)
  , isAwsRegionShapedToken
  , checkProductionEnvVarReads
  , productionEnvVarRegistry
  , ProductionEnvVarRead (..)
  , productionEnvVarNamesIn
  , productionEnvVarOwnersFor
  , isEnvironmentVariableName
  , planOptionsProjectionExemptions
  , doctrineViolationsInPaths
  , extractMarkdownLinkTargets
  , extractStringLiterals
  , generatedSectionRules
  , generatedSectionsReconcilerViolations
  , gatewayProbeViolations
  , gatewayChartStaticViolations
  , gatewayChartStaticsConformanceViolations
  , haskellStyleViolations
  , iamCreateSiteViolations
  , iamCreateVerbs
  , inlineRetrySubstringListViolations
  , isCitedSourcePath
  , isRelativeLinkTarget
  , boundSectionCitationsInLine
  , checkDoctrineSectionCitations
  , citedSourcePathsInDoc
  , planSprintBlocks
  , developmentPlanResumeViolations
  , sprintBlockMissingFields
  , sprintDependencyDirectionViolations
  , executionOrderViolations
  , sprintDependencyFields
  , sprintLiveDependencyIds
  , compareSprintIds
  , documentSectionNumbers
  , headingSectionNumber
  , governedDocStatusValues
  , governedDocStatusViolations
  , inlineCodeSpansInLine
  , parseGovernedDocStatusField
  , removedLegacyTransportSourcePaths
  , retiredCitedSourcePaths
  , listRepoOwnedPaths
  , matchesSprintToken
  , pendingRemovalPrerequisiteViolations
  , parseGeneratedSectionsField
  , planOptionsHonoredViolations
  , destructivePlanOptionsArms
  , prodboxMarkerKeysPresent
  , pulumiCreateSiteOwners
  , pulumiCreateSiteViolations
  , qualificationIsolationViolations
  , relativeLinkResolves
  , renderGeneratedSection
  , renderTrackedGeneratedPath
  , rendererDeterminismViolations
  , rendererSourceViolations
  , runCheckCode
  , scannedCredentialPatternsPresent
  , scannedCredentialViolations
  , serviceErrorRetryableLiteralViolations
  , secretPayloadInternalSourceViolations
  , roundTripWitnessInternalSourceViolations
  , dnsOwnerAuthorityInternalSourceViolations
  , vaultCasClassificationViolations
  , tier0CoordinateReadRegistry
  , tier0CoordinateReadViolations
  , validatedSettingsConstructionFields
  , validatedSettingsMinterViolations
  , controlPlaneListenPortLiteralViolations
  , controlPlaneReplyStatusViolations
  , dependencyAdmissionInternalSourceViolations
  , responseObligationViolations
  , tier0EncoderViolations
  , brokerReadinessProjectionViolations
  , roleReadinessProjectionViolations
  , supervisedWorkerViolations
  , sharedRetryScheduleViolations
  , targetSinkVersionInternalSourceViolations
  , targetSinkRecordMinterViolations
  , runDocsCommand
  , runLintCommand
  , substrateImagePinningViolations
  , workerImagePullReferenceViolations
  , stripFencedCodeBlocks
  , stripInlineCodeSpans
  , tier0DriftFindings
  , tier0DriftLocation
  , tier0MalformedFinding
  , TrackedGeneratedPath (..)
  , trackingGeneratedPaths
  )
where

import Control.Exception (evaluate)
import Control.Monad (filterM, forM)
import Data.ByteString.Char8 qualified as ByteStringChar8
import Data.Char (isAlpha, isAlphaNum, isAsciiLower, isAsciiUpper, isDigit, isSpace, toLower)
import Data.Either (rights)
import Data.List
  ( dropWhileEnd
  , find
  , intercalate
  , isInfixOf
  , isPrefixOf
  , isSuffixOf
  , nub
  , sort
  , stripPrefix
  , tails
  )
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.ChartStatics qualified as BrokerChartStatics
import Prodbox.BuildSupport
  ( addBuildSupportEnvironment
  , syncBuiltOperatorBinary
  )
import Prodbox.CLI.Command
  ( DocsCommand (..)
  , LintCommand (..)
  )
import Prodbox.CLI.Docs
  ( renderBashCompletion
  , renderCommandSurfaceMatrix
  , renderCommandSurfaceTopLevel
  , renderFishCompletion
  , renderGroupManpage
  , renderMarkdownCommandReference
  , renderTopLevelManpage
  , renderZshCompletion
  )
import Prodbox.CLI.Output
  ( writeError
  , writeOutputLine
  )
import Prodbox.CLI.Spec (CommandSpec (..), commandRegistry)
import Prodbox.Capacity.Allocation qualified as Allocation
import Prodbox.Capacity.Config (defaultResourcePlan)
import Prodbox.Capacity.MeasuredProfile (certifyMeasuredProfiles)
import Prodbox.Config.Tier0
  ( decodeProjectConfigDhall
  , renderProjectConfigDhall
  )
import Prodbox.ControlPlane.Runtime (controlPlaneCapacityPlan)
import Prodbox.Error (fatalError)
import Prodbox.Gateway.ChartStatics qualified as ChartStatics
import Prodbox.Gateway.Probe (renderGatewayProbeDefaultsYaml)
import Prodbox.Infra.StackDescriptor
  ( renderStackCommandSurfaceMarkdown
  , stackDescriptors
  )
import Prodbox.Legacy.EscapeRegistry
  ( escapeRegistryViolations
  , isLegacyEscapeScanFile
  )
import Prodbox.Lib.ChartPlatform qualified as ChartPlatform
import Prodbox.Lifecycle.Authority.ChartStatics qualified as AuthorityStatics
import Prodbox.Lifecycle.AuthorityBackup.ChartStatics qualified as AuthorityBackupStatics
import Prodbox.Lifecycle.Decommission.ProgramTag
  ( decommissionInterpreterIdentityViolations
  , decommissionProgramTagParityViolations
  , decommissionTerminalPhaseOrderViolations
  )
import Prodbox.Lifecycle.OwnedResourceTags
  ( codeCreatedAwsResourceTags
  )
import Prodbox.Lifecycle.ProviderWorker.ChartStatics qualified as ProviderWorkerStatics
import Prodbox.Lifecycle.ResourceClass
  ( LifecycleClass (..)
  , renderRegisteredResourcesMarkdown
  , resourceLifecycleClasses
  , resourceNamesOfClass
  )
import Prodbox.Lifecycle.ResourceRegistry (effectRegistryLifecycleClassViolations)
import Prodbox.Lifecycle.TargetSecretAgent.ChartStatics qualified as TargetSecretAgentStatics
import Prodbox.Lifecycle.Teardown.AuditFieldOfView
  ( auditFieldOfViewViolations
  , parseProvisioningProgram
  , renderProvisioningProgramParseError
  )
import Prodbox.Lifecycle.Teardown.CapabilityCustody.Internal
  ( capabilityDependantDerivationViolations
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface
  , ManagedResourceCoordinate (AwsPulumiStackCoordinate)
  , ResourceKind (Stack)
  , cleanupSurfaceMintsCompletionEvidence
  , registeredResourceKeyText
  )
import Prodbox.Lifecycle.Teardown.OperationalCredentialCoverage
  ( operationalCredentialCoverageViolations
  )
import Prodbox.Lifecycle.Teardown.OperationalCredentialInventory
  ( legacyOperationalResourceName
  , legacyOperationalResources
  )
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( controllerOwnedFamiliesWithoutRegisteredStack
  , ownershipEdgeResourceKey
  , ownershipEdgeStackKey
  , registeredOwnershipEdges
  )
import Prodbox.Lifecycle.Teardown.RegisteredTargetExecutor
  ( registeredTargetExecutorFor
  , unexecutableRegisteredTargetDetail
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( RegisteredIdentity (..)
  , SomeManagedResourceDescriptor (..)
  , cleanupSurfaceAllows
  , managedResourceCoordinate
  , managedResourceKey
  , managedResourceKind
  , managedResourceLifecycleClass
  , managedResourceRegistry
  , pulumiProjectNameFor
  )
import Prodbox.Lifecycle.Teardown.RetainedInventory
  ( RetainedBindingError
  , RetainedNameBinding
  , auditQueryCoversTag
  , mkRetainedNameBinding
  , terminalAuditQueryCatalog
  )
import Prodbox.Lifecycle.TlsRetention.ChartStatics qualified as TlsRetentionStatics
import Prodbox.Lint
  ( ensureSandboxedStyleTools
  , missingStyleToolViolations
  , styleToolsBinDir
  )
import Prodbox.PublicEdge (renderHelmRouteInventory)
import Prodbox.Repo (resolveTier0ConfigPath)
import Prodbox.Result (Result (..))
import Prodbox.Secret.VaultInventory (vaultIdentityRegistryViolations)
import Prodbox.Subprocess qualified as Subprocess
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  )
import System.Environment (getEnvironment)
import System.Exit
  ( ExitCode (..)
  )
import System.FilePath
  ( normalise
  , splitDirectories
  , takeDirectory
  , takeFileName
  , (</>)
  )
import System.IO.Error (tryIOError)

data DoctrineViolation
  = ForbiddenWorkflowDirectory FilePath
  | ForbiddenHookSurface FilePath
  | ForbiddenBuildShim FilePath
  deriving (Eq, Show)

data GeneratedSectionRule = GeneratedSectionRule
  { generatedSectionKey :: String
  , generatedSectionPath :: FilePath
  , generatedSectionStartMarker :: String
  , generatedSectionEndMarker :: String
  , generatedSectionRender :: () -> String
  , generatedSectionRendererSources :: [FilePath]
  }

data TrackedGeneratedPath = TrackedGeneratedPath
  { trackedGeneratedPathKey :: String
  , trackedGeneratedPathPath :: FilePath
  , trackedGeneratedPathRender :: () -> String
  , trackedGeneratedPathRendererSources :: [FilePath]
  }

generatedSectionRules :: [GeneratedSectionRule]
generatedSectionRules =
  [ GeneratedSectionRule
      { generatedSectionKey = "command-registry.markdown"
      , generatedSectionPath = "documents/cli/commands.md"
      , generatedSectionStartMarker = "<!-- prodbox:command-registry.markdown:start -->"
      , generatedSectionEndMarker = "<!-- prodbox:command-registry.markdown:end -->"
      , generatedSectionRender = const (renderMarkdownCommandReference commandRegistry)
      , generatedSectionRendererSources = ["src/Prodbox/CLI/Docs.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "route-registry.api"
      , generatedSectionPath = "charts/api/templates/http-route.yaml"
      , generatedSectionStartMarker = "{{/* prodbox:route-registry:start */}}"
      , generatedSectionEndMarker = "{{/* prodbox:route-registry:end */}}"
      , generatedSectionRender = const renderHelmRouteInventory
      , generatedSectionRendererSources = ["src/Prodbox/PublicEdge.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "route-registry.keycloak"
      , generatedSectionPath = "charts/keycloak/templates/gateway.yaml"
      , generatedSectionStartMarker = "{{/* prodbox:route-registry:start */}}"
      , generatedSectionEndMarker = "{{/* prodbox:route-registry:end */}}"
      , generatedSectionRender = const renderHelmRouteInventory
      , generatedSectionRendererSources = ["src/Prodbox/PublicEdge.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "route-registry.vscode"
      , generatedSectionPath = "charts/vscode/templates/http-route.yaml"
      , generatedSectionStartMarker = "{{/* prodbox:route-registry:start */}}"
      , generatedSectionEndMarker = "{{/* prodbox:route-registry:end */}}"
      , generatedSectionRender = const renderHelmRouteInventory
      , generatedSectionRendererSources = ["src/Prodbox/PublicEdge.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "route-registry.websocket"
      , generatedSectionPath = "charts/websocket/templates/http-route.yaml"
      , generatedSectionStartMarker = "{{/* prodbox:route-registry:start */}}"
      , generatedSectionEndMarker = "{{/* prodbox:route-registry:end */}}"
      , generatedSectionRender = const renderHelmRouteInventory
      , generatedSectionRendererSources = ["src/Prodbox/PublicEdge.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "gateway-probes.values"
      , generatedSectionPath = "charts/gateway/values.yaml"
      , generatedSectionStartMarker = "# prodbox:gateway-probes.values:start"
      , generatedSectionEndMarker = "# prodbox:gateway-probes.values:end"
      , generatedSectionRender = const renderGatewayProbeDefaultsYaml
      , generatedSectionRendererSources = ["src/Prodbox/Gateway/Probe.hs"]
      }
  , -- Sprint 2.34: the gateway chart's static ports / NodePort / ServiceAccount
    -- defaults are generated from the one compiled Prodbox.Gateway.ChartStatics
    -- source of truth, so the committed values.yaml cannot drift from the code.
    GeneratedSectionRule
      { generatedSectionKey = "gateway-chart-statics.values"
      , generatedSectionPath = "charts/gateway/values.yaml"
      , generatedSectionStartMarker = "# prodbox:gateway-chart-statics.values:start"
      , generatedSectionEndMarker = "# prodbox:gateway-chart-statics.values:end"
      , generatedSectionRender = const ChartStatics.renderGatewayChartStaticsYaml
      , generatedSectionRendererSources = ["src/Prodbox/Gateway/ChartStatics.hs"]
      }
  , -- Sprint 3.26: the Bootstrap Broker chart's ServiceAccount / bootstrap-only
    -- Vault role / lifecycle probe-path defaults are generated from the one
    -- compiled Prodbox.Bootstrap.Broker.ChartStatics source of truth, so the
    -- committed values.yaml cannot drift from the compiled broker identity or
    -- the closed BrokerRoute registry.
    GeneratedSectionRule
      { generatedSectionKey = "bootstrap-broker-chart-statics.values"
      , generatedSectionPath = "charts/bootstrap-broker/values.yaml"
      , generatedSectionStartMarker = "# prodbox:bootstrap-broker-chart-statics.values:start"
      , generatedSectionEndMarker = "# prodbox:bootstrap-broker-chart-statics.values:end"
      , generatedSectionRender = const BrokerChartStatics.renderBrokerChartStaticsYaml
      , generatedSectionRendererSources = ["src/Prodbox/Bootstrap/Broker/ChartStatics.hs"]
      }
  , -- Sprint 3.26: the five standing control-plane role charts each project their
    -- ServiceAccount / Vault role / probe paths from one compiled ChartStatics,
    -- drift-gated the same way as the broker.
    GeneratedSectionRule
      { generatedSectionKey = "lifecycle-authority-chart-statics.values"
      , generatedSectionPath = "charts/lifecycle-authority/values.yaml"
      , generatedSectionStartMarker = "# prodbox:lifecycle-authority-chart-statics.values:start"
      , generatedSectionEndMarker = "# prodbox:lifecycle-authority-chart-statics.values:end"
      , generatedSectionRender = const AuthorityStatics.renderLifecycleAuthorityChartStaticsYaml
      , generatedSectionRendererSources = ["src/Prodbox/Lifecycle/Authority/ChartStatics.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "provider-worker-chart-statics.values"
      , generatedSectionPath = "charts/provider-worker/values.yaml"
      , generatedSectionStartMarker = "# prodbox:provider-worker-chart-statics.values:start"
      , generatedSectionEndMarker = "# prodbox:provider-worker-chart-statics.values:end"
      , generatedSectionRender = const ProviderWorkerStatics.renderProviderWorkerChartStaticsYaml
      , generatedSectionRendererSources = ["src/Prodbox/Lifecycle/ProviderWorker/ChartStatics.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "authority-backup-chart-statics.values"
      , generatedSectionPath = "charts/authority-backup/values.yaml"
      , generatedSectionStartMarker = "# prodbox:authority-backup-chart-statics.values:start"
      , generatedSectionEndMarker = "# prodbox:authority-backup-chart-statics.values:end"
      , generatedSectionRender = const AuthorityBackupStatics.renderAuthorityBackupChartStaticsYaml
      , generatedSectionRendererSources = ["src/Prodbox/Lifecycle/AuthorityBackup/ChartStatics.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "tls-retention-chart-statics.values"
      , generatedSectionPath = "charts/tls-retention/values.yaml"
      , generatedSectionStartMarker = "# prodbox:tls-retention-chart-statics.values:start"
      , generatedSectionEndMarker = "# prodbox:tls-retention-chart-statics.values:end"
      , generatedSectionRender = const TlsRetentionStatics.renderTlsRetentionChartStaticsYaml
      , generatedSectionRendererSources = ["src/Prodbox/Lifecycle/TlsRetention/ChartStatics.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "target-secret-agent-chart-statics.values"
      , generatedSectionPath = "charts/target-secret-agent/values.yaml"
      , generatedSectionStartMarker = "# prodbox:target-secret-agent-chart-statics.values:start"
      , generatedSectionEndMarker = "# prodbox:target-secret-agent-chart-statics.values:end"
      , generatedSectionRender = const TargetSecretAgentStatics.renderTargetSecretAgentChartStaticsYaml
      , generatedSectionRendererSources = ["src/Prodbox/Lifecycle/TargetSecretAgent/ChartStatics.hs"]
      }
  , -- The recovery observer subject is one compiled Lifecycle Authority
    -- identity projected into each namespace-local exact-name GET RoleBinding.
    -- These generated defaults keep raw-chart rendering aligned with the
    -- supported ChartPlatform value injection.
    GeneratedSectionRule
      { generatedSectionKey = "minio-recovery-observer.values"
      , generatedSectionPath = "charts/minio/values.yaml"
      , generatedSectionStartMarker = "# prodbox:lifecycle-authority-recovery-observer.values:start"
      , generatedSectionEndMarker = "# prodbox:lifecycle-authority-recovery-observer.values:end"
      , generatedSectionRender = const AuthorityStatics.renderLifecycleAuthorityRecoveryObserverYaml
      , generatedSectionRendererSources = ["src/Prodbox/Lifecycle/Authority/ChartStatics.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "vault-recovery-observer.values"
      , generatedSectionPath = "charts/vault/values.yaml"
      , generatedSectionStartMarker = "# prodbox:lifecycle-authority-recovery-observer.values:start"
      , generatedSectionEndMarker = "# prodbox:lifecycle-authority-recovery-observer.values:end"
      , generatedSectionRender = const AuthorityStatics.renderLifecycleAuthorityRecoveryObserverYaml
      , generatedSectionRendererSources = ["src/Prodbox/Lifecycle/Authority/ChartStatics.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "bootstrap-broker-recovery-observer.values"
      , generatedSectionPath = "charts/bootstrap-broker/values.yaml"
      , generatedSectionStartMarker = "# prodbox:lifecycle-authority-recovery-observer.values:start"
      , generatedSectionEndMarker = "# prodbox:lifecycle-authority-recovery-observer.values:end"
      , generatedSectionRender = const AuthorityStatics.renderLifecycleAuthorityRecoveryObserverYaml
      , generatedSectionRendererSources = ["src/Prodbox/Lifecycle/Authority/ChartStatics.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "authority-backup-recovery-observer.values"
      , generatedSectionPath = "charts/authority-backup/values.yaml"
      , generatedSectionStartMarker = "# prodbox:lifecycle-authority-recovery-observer.values:start"
      , generatedSectionEndMarker = "# prodbox:lifecycle-authority-recovery-observer.values:end"
      , generatedSectionRender = const AuthorityStatics.renderLifecycleAuthorityRecoveryObserverYaml
      , generatedSectionRendererSources = ["src/Prodbox/Lifecycle/Authority/ChartStatics.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "provider-worker-recovery-observer.values"
      , generatedSectionPath = "charts/provider-worker/values.yaml"
      , generatedSectionStartMarker = "# prodbox:lifecycle-authority-recovery-observer.values:start"
      , generatedSectionEndMarker = "# prodbox:lifecycle-authority-recovery-observer.values:end"
      , generatedSectionRender = const AuthorityStatics.renderLifecycleAuthorityRecoveryObserverYaml
      , generatedSectionRendererSources = ["src/Prodbox/Lifecycle/Authority/ChartStatics.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "target-secret-agent-recovery-observer.values"
      , generatedSectionPath = "charts/target-secret-agent/values.yaml"
      , generatedSectionStartMarker = "# prodbox:lifecycle-authority-recovery-observer.values:start"
      , generatedSectionEndMarker = "# prodbox:lifecycle-authority-recovery-observer.values:end"
      , generatedSectionRender = const AuthorityStatics.renderLifecycleAuthorityRecoveryObserverYaml
      , generatedSectionRendererSources = ["src/Prodbox/Lifecycle/Authority/ChartStatics.hs"]
      }
  , -- Sprint 4.22: the managed-resource registry's lifecycle-class facts
    -- are rendered into substrates.md so `prodbox dev docs check` fails the
    -- build if the doc drifts from the registry SSoT.
    GeneratedSectionRule
      { generatedSectionKey = "resource-lifecycle-classes"
      , generatedSectionPath = "DEVELOPMENT_PLAN/substrates.md"
      , generatedSectionStartMarker = "<!-- prodbox:resource-lifecycle-classes:start -->"
      , generatedSectionEndMarker = "<!-- prodbox:resource-lifecycle-classes:end -->"
      , generatedSectionRender = const (renderRegisteredResourcesMarkdown resourceLifecycleClasses)
      , generatedSectionRendererSources = ["src/Prodbox/Lifecycle/ResourceClass.hs"]
      }
  , -- Sprint 4.27: the registry-name↔CLI-command table is rendered from
    -- the `StackDescriptor` SSoT into substrates.md so `prodbox dev docs
    -- check` fails the build if the doc drifts from the typed source.
    -- This is the typed source Sprint 0.10 consumes for the
    -- registry-name↔CLI-verb list and Sprint 5.6 consumes for
    -- registry-generated golden coverage.
    GeneratedSectionRule
      { generatedSectionKey = "stack-command-surface"
      , generatedSectionPath = "DEVELOPMENT_PLAN/substrates.md"
      , generatedSectionStartMarker = "<!-- prodbox:stack-command-surface:start -->"
      , generatedSectionEndMarker = "<!-- prodbox:stack-command-surface:end -->"
      , generatedSectionRender = const (renderStackCommandSurfaceMarkdown stackDescriptors)
      , generatedSectionRendererSources = ["src/Prodbox/Infra/StackDescriptor.hs"]
      }
  , -- Sprint 1.29: the §2 top-level command table and the §3 per-group
    -- command matrix in cli_command_surface.md are rendered directly from
    -- the typed `commandRegistry`, so `prodbox dev docs check` fails the build
    -- if the operator command matrix drifts from the parser SSoT. The §2
    -- table and §3 matrix are non-contiguous (substantial prose lives
    -- between them and after the matrix), so they are two separate
    -- generated sections.
    GeneratedSectionRule
      { generatedSectionKey = "command-surface-toplevel"
      , generatedSectionPath = "documents/engineering/cli_command_surface.md"
      , generatedSectionStartMarker = "<!-- prodbox:command-surface-toplevel:start -->"
      , generatedSectionEndMarker = "<!-- prodbox:command-surface-toplevel:end -->"
      , generatedSectionRender = const (renderCommandSurfaceTopLevel commandRegistry)
      , generatedSectionRendererSources = ["src/Prodbox/CLI/Spec.hs", "src/Prodbox/CLI/Docs.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "command-surface-matrix"
      , generatedSectionPath = "documents/engineering/cli_command_surface.md"
      , generatedSectionStartMarker = "<!-- prodbox:command-surface-matrix:start -->"
      , generatedSectionEndMarker = "<!-- prodbox:command-surface-matrix:end -->"
      , generatedSectionRender = const (renderCommandSurfaceMatrix commandRegistry)
      , generatedSectionRendererSources = ["src/Prodbox/CLI/Spec.hs", "src/Prodbox/CLI/Docs.hs"]
      }
  ]

trackingGeneratedPaths :: [TrackedGeneratedPath]
trackingGeneratedPaths =
  TrackedGeneratedPath
    { trackedGeneratedPathKey = "command-registry.manpage.prodbox"
    , trackedGeneratedPathPath = "share/man/man1/prodbox.1"
    , trackedGeneratedPathRender = const (renderTopLevelManpage commandRegistry)
    , trackedGeneratedPathRendererSources = ["src/Prodbox/CLI/Docs.hs"]
    }
    : map commandGroupManpageRule (children commandRegistry)
    ++ [ TrackedGeneratedPath
           { trackedGeneratedPathKey = "command-registry.completion.bash"
           , trackedGeneratedPathPath = "share/completion/bash/prodbox"
           , trackedGeneratedPathRender = const (renderBashCompletion commandRegistry)
           , trackedGeneratedPathRendererSources = ["src/Prodbox/CLI/Docs.hs"]
           }
       , TrackedGeneratedPath
           { trackedGeneratedPathKey = "command-registry.completion.zsh"
           , trackedGeneratedPathPath = "share/completion/zsh/_prodbox"
           , trackedGeneratedPathRender = const (renderZshCompletion commandRegistry)
           , trackedGeneratedPathRendererSources = ["src/Prodbox/CLI/Docs.hs"]
           }
       , TrackedGeneratedPath
           { trackedGeneratedPathKey = "command-registry.completion.fish"
           , trackedGeneratedPathPath = "share/completion/fish/prodbox.fish"
           , trackedGeneratedPathRender = const (renderFishCompletion commandRegistry)
           , trackedGeneratedPathRendererSources = ["src/Prodbox/CLI/Docs.hs"]
           }
       ]
 where
  commandGroupManpageRule commandGroup =
    TrackedGeneratedPath
      { trackedGeneratedPathKey = "command-registry.manpage." ++ name commandGroup
      , trackedGeneratedPathPath = "share/man/man1/prodbox-" ++ name commandGroup ++ ".1"
      , trackedGeneratedPathRender = const (renderGroupManpage commandGroup)
      , trackedGeneratedPathRendererSources = ["src/Prodbox/CLI/Docs.hs"]
      }

renderGeneratedSection :: GeneratedSectionRule -> String
renderGeneratedSection rule = generatedSectionRender rule ()

renderTrackedGeneratedPath :: TrackedGeneratedPath -> String
renderTrackedGeneratedPath rule = trackedGeneratedPathRender rule ()

doctrineViolationsInPaths :: [FilePath] -> [DoctrineViolation]
doctrineViolationsInPaths =
  concatMap (pathViolations . normalise)
 where
  pathViolations relativePath
    | takeFileName relativePath == ".github" =
        [ForbiddenWorkflowDirectory relativePath]
    | takeFileName relativePath `elem` forbiddenHookDirectories =
        [ForbiddenHookSurface relativePath]
    | takeFileName relativePath `elem` forbiddenHookConfigs =
        [ForbiddenHookSurface relativePath]
    | isRepoRootPath relativePath && takeFileName relativePath `elem` forbiddenBuildShims =
        [ForbiddenBuildShim relativePath]
    | takeFileName relativePath `elem` forbiddenHookScripts
        && (isRepoRootPath relativePath || "hooks" `elem` splitDirectories relativePath) =
        [ForbiddenHookSurface relativePath]
    | otherwise = []

  forbiddenHookDirectories = [".githooks", ".husky"]
  forbiddenHookConfigs = [".pre-commit-config.yaml", ".pre-commit-hooks.yaml", "lefthook.yml"]
  forbiddenHookScripts = ["pre-commit", "pre-push", "post-commit", "pre-merge-commit"]
  forbiddenBuildShims = ["Makefile", "justfile", "Taskfile.yml"]
  isRepoRootPath relativePath = takeDirectory relativePath `elem` [".", ""]

runCheckCode :: FilePath -> IO ExitCode
runCheckCode repoRoot = do
  baseEnvironment <- getEnvironment
  environment <- addBuildSupportEnvironment repoRoot baseEnvironment
  writeOutputLine "Running prodbox dev check (policy + formatter + linter + warning-clean build)"
  lintExit <- runLintAll repoRoot environment
  case lintExit of
    ExitFailure _ -> pure lintExit
    ExitSuccess -> do
      buildExit <-
        runSubprocessStreaming
          repoRoot
          environment
          "cabal"
          -- Sprint 5.30: `--enable-tests` is what gives this gate a region that
          -- covers the evidence surface. Without it `all` resolves to the library
          -- and the executable only, so `test/` was linted here and type-checked
          -- nowhere routine — see "The region of Ring 2" in
          -- resource_scaling_doctrine.md section 2C.
          ["build", "--builddir=.build", "all", "--enable-tests", "--ghc-options=-Werror"]
      case buildExit of
        ExitFailure _ -> pure buildExit
        ExitSuccess -> do
          syncResult <- syncBuiltOperatorBinary repoRoot environment
          case syncResult of
            Left err -> failWith err
            Right _ -> pure ExitSuccess

runDocsCommand :: FilePath -> DocsCommand -> IO ExitCode
runDocsCommand repoRoot command =
  case command of
    DocsCheck -> runGeneratedArtifactLint repoRoot False
    DocsGenerate -> runGeneratedArtifactLint repoRoot True

runLintCommand :: FilePath -> LintCommand -> IO ExitCode
runLintCommand repoRoot command = do
  baseEnvironment <- getEnvironment
  environment <- addBuildSupportEnvironment repoRoot baseEnvironment
  case command of
    LintAll -> runLintAll repoRoot environment
    LintFiles _writeEnabled -> runFileLint repoRoot
    LintDocs writeEnabled -> runGeneratedArtifactLint repoRoot writeEnabled
    LintHaskell writeEnabled -> runHaskellLint repoRoot environment writeEnabled
    LintChart -> runChartLint repoRoot

runLintAll :: FilePath -> [(String, String)] -> IO ExitCode
runLintAll repoRoot environment = do
  filesExit <- runFileLint repoRoot
  case filesExit of
    ExitFailure _ -> pure filesExit
    ExitSuccess -> do
      docsExit <- runGeneratedArtifactLint repoRoot False
      case docsExit of
        ExitFailure _ -> pure docsExit
        ExitSuccess -> do
          haskellExit <- runHaskellLint repoRoot environment False
          case haskellExit of
            ExitFailure _ -> pure haskellExit
            ExitSuccess -> runChartLint repoRoot

runFileLint :: FilePath -> IO ExitCode
runFileLint repoRoot = do
  doctrineExit <- runDoctrineAlignmentCheck repoRoot
  case doctrineExit of
    ExitFailure _ -> pure doctrineExit
    ExitSuccess -> do
      thinMainResult <- verifyThinMainEntrypoint repoRoot
      case thinMainResult of
        Left err -> failWith err
        Right () -> do
          trackedExit <- runTrackedGeneratedPathLint repoRoot
          case trackedExit of
            ExitFailure _ -> pure trackedExit
            ExitSuccess -> runConformanceTier repoRoot

runGeneratedArtifactLint :: FilePath -> Bool -> IO ExitCode
runGeneratedArtifactLint repoRoot writeEnabled = do
  results <- processGeneratedArtifacts repoRoot writeEnabled
  case firstLeft results of
    Just err -> failWith err
    Nothing -> do
      -- The marker-content splice always runs first so `docs generate` /
      -- `--write` still regenerates the registered sections. The
      -- governed-document checks then gate the exit code; they have no
      -- auto-fix counterpart, so they only ever fail the command, never
      -- block the writes above.
      whenWriteRepoFiles results
      governedDocViolations <- runGovernedDocChecks repoRoot
      case governedDocViolations of
        [] -> pure ExitSuccess
        violations ->
          failWith
            (unlines ("Governed-document harmony lint failed:" : map ("- " ++) violations))

-- | Sprint 0.9: aggregate the governed-document harmony checks wired into
-- @prodbox dev lint docs@ / @prodbox dev docs check@ (and reached by
-- @prodbox dev check@ through @runLintAll@): the @**Generated
-- sections**@ header ↔ markers ↔ registry reconciler and the
-- relative-link resolution check.
--
-- Sprint 0.21 adds the @**Status**:@ value-legality gate and the cited-source-
-- path existence gate, and STRIKES the @**Referenced by**:@ field entirely.
-- That field was derived data cached in a second place — measured at ~7%
-- complete and ~8% wrong across all 62 governed documents, with no entry
-- carrying anything @grep -rl@ could not reconstruct exactly. The reverse edge
-- is now recovered by search
-- (@documents\/documentation_standards.md § 4@), not authored.
runGovernedDocChecks :: FilePath -> IO [String]
runGovernedDocChecks repoRoot = do
  harmonyViolations <- checkGeneratedSectionsHarmony repoRoot
  linkViolations <- checkGovernedDocRelativeLinks repoRoot
  statusViolations <- checkGovernedDocStatusValues repoRoot
  citedPathViolations <- checkPlanCitedSourcePaths repoRoot
  sectionCitationViolations <- checkDoctrineSectionCitations repoRoot
  sprintFieldViolations <- checkSprintRequiredFields repoRoot
  dependencyDirectionViolations <- checkPlanDependencyDirection repoRoot
  resumeLedgerViolations <- checkDevelopmentPlanResumeLedger repoRoot
  pure
    ( harmonyViolations
        ++ linkViolations
        ++ statusViolations
        ++ citedPathViolations
        ++ sectionCitationViolations
        ++ sprintFieldViolations
        ++ dependencyDirectionViolations
        ++ resumeLedgerViolations
    )

runTrackedGeneratedPathLint :: FilePath -> IO ExitCode
runTrackedGeneratedPathLint repoRoot = do
  results <- processGeneratedArtifacts repoRoot False
  case firstLeft results of
    Just err -> failWith err
    Nothing -> pure ExitSuccess

-- | Sprint 1.63: the conformance tier — the pre-cluster, seconds-fast check
-- family that proves cross-artifact agreement between compiled registries and
-- their projections (see @unit_testing_policy.md § The Conformance Tier@ and
-- @code_quality.md § 3@). It runs inside the fast file-lint phase of
-- @prodbox dev check@, before the warning-clean build, so cross-artifact drift
-- fails in seconds rather than surfacing in the multi-hour aggregate suite.
--
-- Today it hosts the legacy-escape registry bijection (the
-- [Standard P](../../DEVELOPMENT_PLAN/development_plan_standards.md) interim
-- escape-path guard); later Foundation Epoch sprints (@2.34@, @4.51@, @5.20@,
-- @7.34@) add their own conformance suites under this same surface.
runConformanceTier :: FilePath -> IO ExitCode
runConformanceTier repoRoot =
  case resourcePlanOverCommitViolations of
    (_ : _) ->
      failWith
        ( unlines
            ( ( "Resource-plan over-commit gate failed. The committed defaultResourcePlan "
                  ++ "must compile into an AllocatedResourcePlan proof — host_capacity ≥ "
                  ++ "cluster allocatable ≥ Σ workload draw (see resource_scaling_doctrine.md "
                  ++ "§§ 2B/2C, Sprints 1.68/1.69):"
              )
                : map ("- " ++) resourcePlanOverCommitViolations
                ++ ["Correct capacity/Config.hs defaultResourcePlan so the nesting proof holds."]
            )
        )
    [] -> case controlPlaneCapacityViolations of
      (_ : _) ->
        failWith
          ( unlines
              ( ( "Control-plane service-capacity gate failed. The committed "
                    ++ "controlPlaneCapacityInputs must compile into a ServiceCapacityPlan "
                    ++ "(Sprint 4.68); the accept path fails closed on a Left, so an "
                    ++ "over-committed lane would surface as a role that will not serve:"
                )
                  : map ("- " ++) controlPlaneCapacityViolations
              )
          )
      [] -> runConformanceTierChecks repoRoot

-- | Sprint 1.68 over-commit compile gate: the committed 'defaultResourcePlan' must
-- compile into an 'Allocation.AllocatedResourcePlan' proof. No committed measured
-- profile is required — every workload compiles as
-- @WorkloadUncertifiedUntilFirstProfile@, which is deployable — so this asserts
-- only the host/allocatable/quota nesting, failing an over-committed default in
-- seconds rather than at runtime.
resourcePlanOverCommitViolations :: [String]
resourcePlanOverCommitViolations =
  case Allocation.compileResourcePlanUncertified defaultResourcePlan of
    Right _ -> []
    Left err -> [Allocation.renderCompileError err]

-- | Sprint 4.68 accept-path capacity gate.
--
-- 'runControlPlaneServer' answers @ExitFailure 1@ when its plan does not
-- compile, which is the right runtime behaviour and a terrible way to find out:
-- the symptom is a role Pod that starts and refuses to serve, with the cause an
-- arithmetic property of four constants. This makes it a build failure instead,
-- in the same seconds-fast tier as the resource-plan proof and for the same
-- reason.
controlPlaneCapacityViolations :: [String]
controlPlaneCapacityViolations =
  case controlPlaneCapacityPlan of
    Right _ -> []
    Left err -> [show err]

runConformanceTierChecks :: FilePath -> IO ExitCode
runConformanceTierChecks repoRoot = do
  tier0Violations <- checkTier0SiblingDrift repoRoot
  case tier0Violations of
    (_ : _) ->
      failWith
        ( unlines
            ( ( "Tier-0 sibling-config drift gate failed. The binary-sibling "
                  ++ "prodbox.dhall is GENERATED and must equal what the generator "
                  ++ "emits for the record it decodes to (config_doctrine.md § 3, "
                  ++ "code_quality.md § 3, Sprint 0.24):"
              )
                : map ("- " ++) tier0Violations
            )
        )
    [] -> runConformanceTierRegistryChecks repoRoot

-- | Sprint 0.24: the binary-sibling Tier-0 @prodbox.dhall@ is GENERATED and
-- git-ignored, so neither the tracked-generated-path registry nor the committed
-- credential scan can reach it — both are deliberately scoped to
-- version-controlled content. This gate reads the binary-sibling path directly
-- ('resolveTier0ConfigPath'), decodes it, re-renders the decoded record through
-- the one canonical generator ('renderProjectConfigDhall' — the sole writer
-- behind @config generate@, @config setup@, the @vault init@ floor stamp, and the
-- test harness), and compares.
--
-- Three dispositions, deliberately distinct:
--
--   * __absent__ is not a finding. A fresh worktree has no sibling config until
--     @prodbox config generate@ runs, and @dev check@ must not require one.
--   * __malformed__ is a finding that says the file does not decode, separate
--     from drift: an undecodable file has no record to re-render.
--   * __drifted__ is a finding naming the record field whose canonical rendering
--     the file does not carry.
--
-- Honest bound: this detects divergence from the generator's __output__ — a hand
-- edit that changes the emitted text, a file left behind by an older schema, or a
-- derived block (the emitted @concurrentDraws@ Ring-1 witness) that no longer
-- matches the plan it was computed from. A hand-edited primitive that round-trips
-- unchanged through decode and re-render is textually indistinguishable from
-- generated output and is __not__ caught; Ring 1 cannot constrain those values
-- either. The gate closes the silence, not the representability gap.
checkTier0SiblingDrift :: FilePath -> IO [String]
checkTier0SiblingDrift repoRoot = do
  tier0Path <- resolveTier0ConfigPath repoRoot
  present <- doesFileExist tier0Path
  if not present
    then pure []
    else do
      decoded <- decodeProjectConfigDhall tier0Path
      case decoded of
        Left err -> pure [tier0MalformedFinding tier0Path err]
        Right config -> do
          onDisk <- readFileStrict tier0Path
          pure
            ( tier0DriftFindings
                tier0Path
                (Text.unpack (renderProjectConfigDhall config))
                onDisk
            )

-- | The malformed-file finding. Distinct from a drift finding because there is
-- no decoded record to re-render, so no field can be named.
tier0MalformedFinding :: FilePath -> String -> String
tier0MalformedFinding path err =
  path
    ++ " does not decode as a Tier-0 record, so it cannot be compared with the "
    ++ "generator's output: "
    ++ err
    ++ ". Regenerate it with `prodbox config generate`."

-- | Pure core of the drift gate: the generator's canonical rendering versus the
-- bytes on disk. Reports the differing field rather than a whole-file diff, per
-- the @code_quality.md@ § 3 error-message contract (path, what drifted, remedy).
tier0DriftFindings
  :: FilePath
  -- ^ The binary-sibling path, reported verbatim.
  -> String
  -- ^ What the generator emits for the record decoded from the file.
  -> String
  -- ^ What is on disk.
  -> [String]
tier0DriftFindings path expected actual
  | expected == actual = []
  | otherwise =
      [ path
          ++ " has drifted from the generator's canonical rendering at "
          ++ tier0DriftLocation expected actual
          ++ ". Regenerate it with `prodbox config generate` (or re-author the "
          ++ "operator sections with `prodbox config setup`); the binary-sibling "
          ++ "prodbox.dhall is generated, never hand-edited."
      ]

-- | The 1-based line at which the canonical rendering and the on-disk text first
-- diverge, qualified by the record-field path enclosing that line. The field path
-- is recovered from the canonical rendering's own indentation, so it names a
-- field of the Tier-0 record (@parameters.route53.zone_id@) rather than a byte
-- offset.
tier0DriftLocation :: String -> String -> String
tier0DriftLocation expected actual =
  case tier0FirstDivergence (lines expected) (lines actual) of
    (lineNumber, []) -> "line " ++ show lineNumber
    (lineNumber, fields) ->
      "line " ++ show lineNumber ++ ", field `" ++ intercalate "." fields ++ "`"

-- | Walk both renderings in step, maintaining the enclosing-field stack from the
-- canonical side, and stop at the first divergence (including one text running
-- out before the other).
tier0FirstDivergence :: [String] -> [String] -> (Int, [String])
tier0FirstDivergence = go 1 []
 where
  go lineNumber stack expectedLines actualLines =
    case (expectedLines, actualLines) of
      ([], []) -> (lineNumber, fieldPath stack)
      ([], _ : _) -> (lineNumber, fieldPath stack)
      (expectedLine : _, []) ->
        (lineNumber, fieldPath (trackRecordScope expectedLine stack))
      (expectedLine : restExpected, actualLine : restActual)
        | expectedLine == actualLine ->
            go
              (lineNumber + 1)
              (trackRecordScope expectedLine stack)
              restExpected
              restActual
        | otherwise ->
            (lineNumber, fieldPath (trackRecordScope expectedLine stack))

  fieldPath = map snd . reverse

-- | Maintain an indentation-keyed stack of open record fields: a field opened at
-- column @c@ closes every field opened at column @c@ or deeper, and a line whose
-- first token closes a record or list closes every field opened at or inside its
-- own column. Without the closer arm the stack would keep naming the last field
-- it saw for text that has already left it.
trackRecordScope :: String -> [(Int, String)] -> [(Int, String)]
trackRecordScope line stack =
  case fieldAssignmentInLine line of
    Just entry@(column, _) -> entry : closeAt column
    Nothing -> maybe stack closeAt (recordCloserColumn line)
 where
  closeAt column = dropWhile ((>= column) . fst) stack

-- | The column of a line that opens with a record\/list\/parenthesis closer.
recordCloserColumn :: String -> Maybe Int
recordCloserColumn line
  | any (`isPrefixOf` dropWhile (== ' ') line) ["}", "]", ")"] =
      Just (length (takeWhile (== ' ') line))
  | otherwise = Nothing

-- | The record-field assignment a Dhall-pretty-printed line opens, if any: an
-- identifier bound with @=@, optionally behind the @{@ or @,@ the pretty-printer
-- puts at the head of a record line. The dotted single-field shorthand the
-- pretty-printer emits (@, route53.zone_id = ""@) is one name. A type annotation
-- (@field : Natural@) and a @let@ binding are both rejected, so only fields of
-- the emitted record enter the path.
fieldAssignmentInLine :: String -> Maybe (Int, String)
fieldAssignmentInLine line
  | not (null name)
  , "=" `isPrefixOf` afterName
  , not ("==" `isPrefixOf` afterName) =
      Just (column, name)
  | otherwise = Nothing
 where
  column = length (takeWhile (== ' ') line)
  trimmed = dropWhile (== ' ') line
  body
    | "{ " `isPrefixOf` trimmed = drop 2 trimmed
    | ", " `isPrefixOf` trimmed = drop 2 trimmed
    | otherwise = trimmed
  isNameCharacter character =
    isAlphaNum character || character == '_' || character == '.'
  name = takeWhile isNameCharacter body
  afterName = dropWhile (== ' ') (drop (length name) body)

runConformanceTierRegistryChecks :: FilePath -> IO ExitCode
runConformanceTierRegistryChecks repoRoot = do
  escapeViolations <- checkLegacyEscapeRegistry repoRoot
  case escapeViolations of
    (_ : _) ->
      failWith
        ( unlines
            ( ( "Legacy escape-registry bijection failed. The compiled registry "
                  ++ "src/Prodbox/Legacy/EscapeRegistry.hs must match the escape "
                  ++ "markers in source one-to-one (see code_quality.md § 3):"
              )
                : map ("- " ++) escapeViolations
                ++ ["Rerun `./.build/prodbox dev check` after reconciling the registry and markers."]
            )
        )
    [] -> do
      brokerIsolationViolations <- checkBootstrapBrokerIsolation repoRoot
      case brokerIsolationViolations of
        (_ : _) ->
          failWith
            ( unlines
                ( ( "Bootstrap Broker isolation conformance failed. Gateway target registries "
                      ++ "must contain no pre-Vault route and the broker registry must remain "
                      ++ "a fixed allowlist (Sprint 2.33):"
                  )
                    : map ("- " ++) brokerIsolationViolations
                    ++ ["Reconcile the closed role/route registries; do not add a generic transport escape."]
                )
            )
        [] -> do
          measuredViolations <- checkMeasuredCapacityProfiles repoRoot
          case measuredViolations of
            (_ : _) ->
              failWith
                ( unlines
                    ( ( "Measured-capacity certification failed. Authored Guaranteed-QoS "
                          ++ "envelopes must be justified by their committed measured profiles "
                          ++ "under dhall/capacity/measured/ (see resource_scaling_doctrine.md § 2F):"
                      )
                        : map ("- " ++) measuredViolations
                        ++ ["Recapture the profile (Sprint 5.21 recorder) or correct the authored envelope."]
                    )
                )
            [] -> do
              staticsViolations <- checkGatewayChartStatics repoRoot
              case staticsViolations of
                [] ->
                  case vaultIdentityRegistryViolations of
                    [] -> do
                      readinessViolations <- readinessObservationViolations repoRoot
                      case readinessViolations of
                        [] -> do
                          qualificationViolations <- checkQualificationIsolation repoRoot
                          case qualificationViolations of
                            [] -> runTerminalAuditFieldOfViewCheck repoRoot
                            _ ->
                              failWith
                                ( unlines
                                    ( ( "Qualification-fixture isolation failed. Test-only source/evidence "
                                          ++ "identities must not enter a production module or capability registry:"
                                      )
                                        : map ("- " ++) qualificationViolations
                                        ++ [ "Move the import below src/Prodbox/Test; production interpreters cannot consume qualification fixtures."
                                           ]
                                    )
                                )
                        _ ->
                          failWith
                            ( unlines
                                ( ( "Three-valued readiness conformance failed. Each readiness/"
                                      ++ "observation type must keep a DISTINCT non-terminal constructor "
                                      ++ "for the not-yet-ready state; collapsing it into a terminal or "
                                      ++ "absent bucket is the forbidden bring-up-dual / fail-open defect "
                                      ++ "(bootstrap_readiness_doctrine.md §0/§2.4, Sprints 4.53/5.25):"
                                  )
                                    : map ("- " ++) readinessViolations
                                    ++ [ "Restore the non-terminal readiness constructor; never collapse "
                                           ++ "a not-yet-ready observation into a fatal or absent one."
                                       ]
                                )
                            )
                    vaultViolations ->
                      failWith
                        ( unlines
                            ( ( "Vault identity-registry conformance failed. Every Vault "
                                  ++ "Kubernetes-auth role name and chart-secret policy name must be "
                                  ++ "bound by exactly one identity across the VaultRoleId registry and "
                                  ++ "the chart-secret consumers (lifecycle_control_plane_architecture.md § 10.2, "
                                  ++ "Sprint 3.26):"
                              )
                                : map ("- " ++) vaultViolations
                                ++ ["Rename the colliding role/policy so each identity is defined exactly once."]
                            )
                        )
                violations ->
                  failWith
                    ( unlines
                        ( ( "Gateway chart-statics conformance failed. The committed "
                              ++ "charts/gateway/values.yaml defaults must equal the compiled "
                              ++ "Prodbox.Gateway.ChartStatics projection (Sprint 2.34):"
                          )
                            : map ("- " ++) violations
                            ++ ["Run `./.build/prodbox dev docs generate` and reconcile the raw values.yaml literals."]
                        )
                    )

-- | Sprints 4.53 / 5.25: the typed three-valued-readiness doctrine
-- (bootstrap_readiness_doctrine.md §0/§2.4) requires every readiness/observation
-- type to keep a DISTINCT non-terminal "not-yet-ready" constructor.  Collapsing
-- that third value back into a terminal (bring-up dual) or absent (fail-open)
-- bucket is the forbidden defect the two readiness-race fixes remove.  This build
-- gate fails if any of the three doctrine constructors is deleted or renamed away
-- — a regression that would re-collapse the distinction.
readinessObservationViolations :: FilePath -> IO [String]
readinessObservationViolations repoRoot =
  concat <$> mapM checkConstructorPresent requiredNonTerminalReadinessConstructors
 where
  checkConstructorPresent (relativePath, constructor, rationale) = do
    let absolutePath = repoRoot </> relativePath
    exists <- doesFileExist absolutePath
    if not exists
      then
        pure
          [ relativePath
              ++ " is missing (expected the three-valued readiness/observation type)"
          ]
      else do
        contents <- readFileStrict absolutePath
        pure
          [ relativePath
              ++ ": missing the non-terminal readiness constructor `"
              ++ constructor
              ++ "` — "
              ++ rationale
          | not (constructor `isInfixOf` contents)
          ]

-- | The three non-terminal "not-yet-ready" constructors that make the readiness
-- races unrepresentable, each in its owning module.
requiredNonTerminalReadinessConstructors :: [(FilePath, String, String)]
requiredNonTerminalReadinessConstructors =
  [
    ( "src/Prodbox/Test/GatewayRuntimeStability.hs"
    , "GatewayObservationIncomplete"
    , "a not-yet-scraped healthy gateway Pod must be non-absorbing, not latched fatal"
    )
  ,
    ( "src/Prodbox/Lifecycle/CheckpointAuthority.hs"
    , "ModelBEndpointUnready"
    , "a transient object-store endpoint-unreachability is retryable, not a terminal authority-loss"
    )
  ,
    ( "src/Prodbox/Lifecycle/Lease.hs"
    , "LeaseAuthorityEndpointUnready"
    , "a transient endpoint-unready lease refusal is retried within the readiness budget"
    )
  ]

-- | Sprint 4.50 / Standard P: the frozen counterexample and qualification
-- identities are evidence, never runtime authority.  No production module may
-- import their namespace; this keeps a fixture from satisfying a real role or
-- capability registry by construction.
checkQualificationIsolation :: FilePath -> IO [String]
checkQualificationIsolation repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  sources <-
    forM
      [ path
      | path <- repoPaths
      , "src/" `isPrefixOf` path || "app/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      ]
      (\path -> do contents <- readFileStrict (repoRoot </> path); pure (path, contents))
  pure (qualificationIsolationViolations sources)

qualificationIsolationViolations :: [(FilePath, String)] -> [String]
qualificationIsolationViolations sources =
  [ path
      ++ " imports the test-only Prodbox.Test.Qualification namespace."
  | (path, contents) <- sources
  , not ("src/Prodbox/Test/" `isPrefixOf` path)
  , path /= "src/Prodbox/CheckCode.hs"
  , sourceLine <- lines contents
  , let stripped = dropWhile isSpace sourceLine
  , "import " `isPrefixOf` stripped
  , "Prodbox.Test.Qualification" `isInfixOf` stripped
  ]

checkBootstrapBrokerIsolation :: FilePath -> IO [String]
checkBootstrapBrokerIsolation repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let additionalIsolationPaths =
        [ path
        | path <- repoPaths
        , any
            (`isPrefixOf` path)
            [ "src/Prodbox/Gateway/"
            , "src/Prodbox/Bootstrap/Broker/"
            ]
        , ".hs" `isSuffixOf` path
        , path `notElem` bootstrapIsolationSourcePaths
        ]
  sources <-
    forM
      ( bootstrapIsolationSourcePaths
          ++ bootstrapOptionalIsolationSourcePaths
          ++ additionalIsolationPaths
      )
      $ \relativePath -> do
        let absolutePath = repoRoot </> relativePath
        exists <- doesFileExist absolutePath
        contents <- if exists then readFileStrict absolutePath else pure ""
        pure (relativePath, contents)
  pure (bootstrapBrokerIsolationViolations sources)

bootstrapIsolationSourcePaths :: [FilePath]
bootstrapIsolationSourcePaths =
  [ "src/Prodbox/Gateway/Routes.hs"
  , "src/Prodbox/Gateway/Client.hs"
  , "src/Prodbox/Gateway/Daemon.hs"
  , "src/Prodbox/Bootstrap/Broker/Client.hs"
  , "src/Prodbox/Bootstrap/Broker/Routes.hs"
  ]

-- | Sprint 0.21: the lifecycle transport modules Sprint @4.50@ removed. The
-- negative-space lint below requires each to stay absent (or empty), which
-- makes this list the SSoT for "deliberately deleted, and enforced deleted" —
-- so 'retiredCitedSourcePaths' derives from it rather than re-authoring the
-- same facts. A plan document citing one of these is recording history, not
-- asserting a live artifact.
removedLegacyTransportSourcePaths :: [FilePath]
removedLegacyTransportSourcePaths =
  [ "src/Prodbox/Bootstrap/Broker/LegacyAdapter.hs"
  , "src/Prodbox/Gateway/ObjectStore.hs"
  , "src/Prodbox/Gateway/TargetSecret.hs"
  , "src/Prodbox/Lifecycle/CheckpointAuthorityStore.hs"
  , "src/Prodbox/Lifecycle/HostDirectAuthorityStore.hs"
  , "src/Prodbox/Lifecycle/TargetSecretStore.hs"
  , "src/Prodbox/Pulumi/HostDirectObjectStore.hs"
  ]

bootstrapOptionalIsolationSourcePaths :: [FilePath]
bootstrapOptionalIsolationSourcePaths =
  [ "src/Prodbox/Gateway/ObjectStore.hs"
  , "src/Prodbox/Gateway/TargetSecret.hs"
  , "src/Prodbox/Lifecycle/CheckpointAuthorityStore.hs"
  , "src/Prodbox/Lifecycle/HostDirectAuthorityStore.hs"
  , "src/Prodbox/Lifecycle/TargetSecretStore.hs"
  , "src/Prodbox/Pulumi/HostDirectObjectStore.hs"
  ]

-- | Pure Sprint-2.33 role-isolation check.  Comments are ignored for path
-- checks by scanning string literals; constructor/adapter checks intentionally
-- inspect source tokens because they prove ownership, not prose wording.
bootstrapBrokerIsolationViolations :: [(FilePath, String)] -> [String]
bootstrapBrokerIsolationViolations sources =
  missingViolations
    ++ gatewayRouteViolations
    ++ gatewayClientViolations
    ++ gatewayModuleViolations
    ++ brokerClientViolations
    ++ brokerEscapeViolations
    ++ removedLegacyViolations
 where
  sourceAt path = lookup path sources
  missingViolations =
    [ path ++ " is missing from the Bootstrap Broker isolation proof."
    | path <- bootstrapIsolationSourcePaths
    , maybe True null (sourceAt path)
    ]
  gatewayRouteViolations =
    sourceViolations
      "src/Prodbox/Gateway/Routes.hs"
      ["RouteBootstrapVault", "/v1/bootstrap/vault"]
  gatewayClientViolations =
    sourceViolations
      "src/Prodbox/Gateway/Client.hs"
      [ "ensureVaultBootstrap"
      , "queryVaultStatus"
      , "sealVault"
      , "rotateVaultUnlockBundle"
      , "rotateVaultTransitKey"
      , "/v1/bootstrap/vault"
      ]
  gatewayModuleViolations =
    concatMap
      gatewayModuleSourceViolations
      [ source
      | source@(path, _) <- sources
      , "src/Prodbox/Gateway/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      ]
  brokerClientViolations =
    case sourceAt "src/Prodbox/Bootstrap/Broker/Client.hs" of
      Nothing -> []
      Just contents ->
        [ "Bootstrap Broker target client can represent forbidden secret field `"
            ++ token
            ++ "`."
        | token <- ["unlock_password", "new_unlock_password", "initial_root_token"]
        , token `isInfixOf` contents
        ]
          ++ [ "Bootstrap Broker target client is missing authenticated request binding `"
                 ++ token
                 ++ "`."
             | token <-
                 [ "x-prodbox-service-identity"
                 , "x-prodbox-transport-credential"
                 , "idempotency-key"
                 , "x-prodbox-request-sha256"
                 , "requestDigestForBytes"
                 ]
             , not (token `isInfixOf` contents)
             ]
  brokerEscapeViolations =
    case sourceAt "src/Prodbox/Bootstrap/Broker/Routes.hs" of
      Nothing -> []
      Just contents ->
        [ "Bootstrap Broker route registry contains forbidden generic literal `"
            ++ literal
            ++ "`."
        | literal <- extractStringLiterals contents
        , any (`isInfixOf` map toLower literal) brokerForbiddenFragments
        ]
  removedLegacyViolations =
    [ path ++ " retains a removed lifecycle transport module."
    | (path, contents) <- sources
    , ( ( not (null contents)
            && path `elem` removedLegacyTransportSourcePaths
        )
          || any
            (`elem` sourceIdentifiers contents)
            [ "LegacyGatewayBootstrapRoute"
            , "legacyGatewayBootstrapRouteForPath"
            , "runLegacyGatewayBootstrapRequest"
            , "dispatchLegacyGatewayBootstrapRoute"
            ]
          || ( "src/Prodbox/Gateway/" `isPrefixOf` path
                 && any
                   ("/v1/bootstrap/vault" `isPrefixOf`)
                   (extractStringLiterals contents)
             )
      )
    ]
  brokerForbiddenFragments =
    [ "/v1/object-store"
    , "/v1/secret"
    , "pulumi"
    , "route53"
    , "target-secret"
    , "/authority"
    , "/mesh"
    , "/ses"
    , "/kv/"
    ]
  sourceViolations path forbiddenTokens =
    case sourceAt path of
      Nothing -> []
      Just contents ->
        [ path ++ " retains forbidden Bootstrap Broker target token `" ++ token ++ "`."
        | token <- forbiddenTokens
        , token `isInfixOf` contents
        ]
  gatewayModuleSourceViolations (path, contents) =
    [ path ++ " retains forbidden pre-Vault literal `" ++ literal ++ "`."
    | literal <- extractStringLiterals contents
    , literal
        `elem` [ "/v1/bootstrap/vault/ensure"
               , "/v1/federation/children"
               , "/v1/object-store/pulumi/get"
               , "/v1/object-store/pulumi/put"
               , "/v1/object-store/pulumi/delete"
               , "/v1/object-store/authority/get"
               , "/v1/object-store/authority/cas"
               , "/v1/object-store/authority/time"
               , "/v1/target-secret/read"
               , "/v1/target-secret/cas"
               , "/v1/secret/"
               , "unlock_password"
               , "new_unlock_password"
               , "initial_root_token"
               ]
    ]
      ++ [ path ++ " retains forbidden pre-Vault identifier `" ++ identifier ++ "`."
         | identifier <- sourceIdentifiers contents
         , identifier
             `elem` [ "BootstrapVaultRequest"
                    , "BootstrapVaultRotateUnlockBundleRequest"
                    , "BootstrapVaultRotateTransitKeyRequest"
                    , "TargetBootstrapVaultEnsure"
                    , "TargetBootstrapVaultStatus"
                    , "TargetBootstrapVaultSeal"
                    , "TargetBootstrapVaultRotateUnlockBundle"
                    , "TargetBootstrapVaultRotateTransitKey"
                    , "TargetBootstrapVaultPkiStatus"
                    , "TargetBootstrapVaultPkiIssueTestCert"
                    , "handleBootstrapVaultEnsure"
                    , "bootstrapRootToken"
                    , "bootstrapObjectStoreConfigWithEndpoint"
                    , "minioRootPassword"
                    , "minioRootUser"
                    , "RouteFederationChildren"
                    , "federationChildPathPrefix"
                    , "federationChildBootstrapSuffix"
                    , "queryFederationChildren"
                    , "queryChildBootstrap"
                    , "TargetFederationChildrenRead"
                    , "TargetFederationChildBootstrapRead"
                    , "RoutePulumiObjectGet"
                    , "RoutePulumiObjectPut"
                    , "RoutePulumiObjectDelete"
                    , "RouteAuthorityObjectGet"
                    , "RouteAuthorityObjectCas"
                    , "RouteAuthorityClock"
                    , "RouteTargetSecretRead"
                    , "RouteTargetSecretCas"
                    , "getPulumiObject"
                    , "putPulumiObject"
                    , "deletePulumiObject"
                    , "getAuthorityObject"
                    , "compareAndSwapAuthorityObject"
                    , "getAuthorityClock"
                    , "getTargetSecret"
                    , "compareAndSwapTargetSecret"
                    , "writeOperatorSecret"
                    ]
         ]

runTerminalAuditFieldOfViewCheck :: FilePath -> IO ExitCode
runTerminalAuditFieldOfViewCheck repoRoot = do
  fieldOfViewViolations <- checkTerminalAuditFieldOfView repoRoot
  provisioningViolations <- checkRegisteredStackProvisioningPrograms repoRoot
  case fieldOfViewViolations ++ provisioningViolations of
    [] -> pure ExitSuccess
    _ ->
      failWith
        ( unlines
            ( ( "Terminal-audit field-of-view join failed. Every taggable AWS resource "
                  ++ "a provisioning program declares must carry a tag the escape audit "
                  ++ "queries for; otherwise a leaked instance of it is never returned "
                  ++ "and a clean verdict says nothing about it "
                  ++ "(lifecycle_reconciliation_doctrine.md § 3.1, Sprint 4.84):"
              )
                : map ("- " ++) (fieldOfViewViolations ++ provisioningViolations)
                ++ [ "Author a queried tag onto the resource, or classify a genuinely "
                       ++ "untaggable type in Prodbox.Lifecycle.Teardown.AuditFieldOfView. "
                       ++ "A registered stack with no provisioning program is a "
                       ++ "separate defect: register the program, or remove the "
                       ++ "descriptor."
                   ]
            )
        )

-- | Sprint 4.84: certify that every AWS resource the repository provisions is
-- inside the terminal escape audit's field of view.
--
-- The audit decides over what its tag queries return, so a resource carrying no
-- queried tag is not merely unmatched — it is never returned, and a clean
-- verdict reads as a statement about a resource the audit never saw. The query
-- catalog's completeness was a claim about the provisioning programs that no
-- code read; this reads them.
--
-- The program set is enumerated from disk rather than declared, so a new
-- provisioning program is covered by existing, not by remembering to add it.
checkTerminalAuditFieldOfView :: FilePath -> IO [String]
checkTerminalAuditFieldOfView repoRoot = do
  let programRoot = repoRoot </> "pulumi"
  rootExists <- doesDirectoryExist programRoot
  if not rootExists
    then
      pure
        [ "pulumi/ is missing, so the terminal-audit field-of-view join has "
            ++ "nothing to read and cannot certify the audit sees what is provisioned."
        ]
    else do
      entries <- listDirectory programRoot
      programs <-
        filterM
          (\entry -> doesFileExist (programRoot </> entry </> "Main.yaml"))
          (sort entries)
      case (programs, fieldOfViewQueryBinding) of
        ([], _) ->
          pure
            [ "pulumi/ contains no Main.yaml provisioning program; an empty "
                ++ "program set cannot be read as full terminal-audit coverage."
            ]
        (_, Left bindingError) ->
          pure
            [ "the terminal-audit query catalog could not be built for the "
                ++ "field-of-view join: "
                ++ show bindingError
            ]
        (_, Right binding) -> do
          parsed <-
            forM programs $ \program -> do
              contents <- readFileStrict (programRoot </> program </> "Main.yaml")
              pure (parseProvisioningProgram (Text.pack program) (Text.pack contents))
          let parseErrors =
                [ renderProvisioningProgramParseError err
                | Left err <- parsed
                ]
              declared = concat (rights parsed)
          pure
            ( parseErrors
                ++ auditFieldOfViewViolations
                  (terminalAuditQueryCatalog binding)
                  declared
            )

-- | Sprint 4.85: join the __third creation surface__ to the terminal audit's
-- field of view.
--
-- Sprint @4.84@ closed two of the three surfaces that create AWS resources: the
-- field-of-view gate reads every @pulumi\/*\/Main.yaml@ and fails on a taggable
-- declared resource authoring no queried tag, and the Provider Worker's SES
-- capture-bucket intent was given the tags its retained catalog already
-- assumed. A resource created by a direct AWS call in @src\/@ is covered by
-- neither — no provisioning program declares it, so the disk-reading gate
-- cannot see it.
--
-- The @dns-aws@ validation hosted zone was exactly that: billable, created by
-- @Prodbox.Infra.Route53ValidationZone@, and carrying no tag at all, so a
-- leaked zone was returned by no audit query while a clean verdict read like a
-- statement that it was gone.
--
-- 'CodeCreatedAwsResource' is the closed enumeration of that surface and the
-- writers take their tag set from it, so this check covers every member. Both
-- sides are values, so the join is exact: at least one authored family must be
-- covered by the audit's query catalog.
codeCreatedResourceFieldOfViewViolations :: [String]
codeCreatedResourceFieldOfViewViolations =
  case fieldOfViewQueryBinding of
    Left bindingError ->
      [ "the terminal-audit query catalog could not be built for the "
          ++ "code-created resource join: "
          ++ show bindingError
      ]
    Right binding ->
      concatMap (resourceViolations (terminalAuditQueryCatalog binding)) [minBound .. maxBound]
 where
  resourceViolations queries resource
    | null authored =
        [ show resource
            ++ " is a code-created AWS resource with no authored tags, so the "
            ++ "terminal escape audit returns it from no query and a clean "
            ++ "verdict says nothing about it."
        ]
    | any (auditQueryCoversTag queries) authored = []
    | otherwise =
        [ show resource
            ++ " authors tag families the terminal-audit query catalog does not "
            ++ "cover, so the audit returns it from no query. Author a queried "
            ++ "family in Prodbox.Lifecycle.OwnedResourceTags, or add the family "
            ++ "to the catalog in Prodbox.Lifecycle.Teardown.RetainedInventory."
        ]
   where
    authored = codeCreatedAwsResourceTags resource

-- | Sprint 4.85: join every registered stack coordinate to a provisioning
-- program that exists on disk.
--
-- A registered stack coordinate carries a Pulumi project name and a stack name.
-- Both are only meaningful if a program under @pulumi\/@ actually declares that
-- project: a registered stack whose project does not exist can never be
-- reconciled or destroyed, and its compiled desired-absence nodes would fail
-- for a reason no report distinguishes from infrastructure that refused to go
-- away.
--
-- The project-name rule (@prodbox-\<stack name\>@) is checked as well as the
-- existence, because the registry derives one from the other. Reading the
-- @name:@ field is deliberate: it is the field Pulumi itself resolves, so the
-- join's input is the source rather than the directory layout, which does not
-- match the stack names (@pulumi\/aws-eks@ provisions stack @aws-eks-test@).
checkRegisteredStackProvisioningPrograms :: FilePath -> IO [String]
checkRegisteredStackProvisioningPrograms repoRoot = do
  let programRoot = repoRoot </> "pulumi"
  rootExists <- doesDirectoryExist programRoot
  if not rootExists
    then
      pure
        [ "pulumi/ is missing, so no registered stack coordinate can be joined "
            ++ "to a provisioning program."
        ]
    else do
      entries <- listDirectory programRoot
      programs <-
        filterM
          (\entry -> doesFileExist (programRoot </> entry </> "Pulumi.yaml"))
          (sort entries)
      declaredProjects <-
        forM programs $ \program -> do
          contents <- readFileStrict (programRoot </> program </> "Pulumi.yaml")
          pure (pulumiProjectNameIn contents)
      let onDisk = [project | Just project <- declaredProjects]
      pure (concatMap (stackViolations onDisk) registeredStackCoordinates)
 where
  registeredStackCoordinates =
    [ (managedResourceKey descriptor, managedResourceCoordinate descriptor)
    | SomeManagedResourceDescriptor descriptor <- managedResourceRegistry
    , managedResourceKind descriptor == Stack
    ]

  stackViolations onDisk (key, coordinate) = case coordinate of
    AwsPulumiStackCoordinate projectName stackName ->
      [ "registered stack `"
          ++ Text.unpack (registeredResourceKeyText key)
          ++ "` names Pulumi project `"
          ++ Text.unpack projectName
          ++ "`, but no pulumi/*/Pulumi.yaml declares it. A registered stack "
          ++ "with no provisioning program can never be reconciled or "
          ++ "destroyed, and its compiled desired-absence nodes fail for a "
          ++ "reason no teardown report distinguishes from live infrastructure."
      | projectName `notElem` onDisk
      ]
        ++ [ "registered stack `"
               ++ Text.unpack (registeredResourceKeyText key)
               ++ "` names Pulumi project `"
               ++ Text.unpack projectName
               ++ "`, which is not `"
               ++ Text.unpack (pulumiProjectNameFor stackName)
               ++ "`; Prodbox.Lifecycle.Teardown.Registry derives the project "
               ++ "name from the stack name, so the two cannot differ."
           | projectName /= pulumiProjectNameFor stackName
           ]
    _ ->
      [ "registered stack `"
          ++ Text.unpack (registeredResourceKeyText key)
          ++ "` has Stack kind but does not carry an AwsPulumiStackCoordinate, "
          ++ "so it names no provisioning program."
      ]

-- | The @name:@ field of a @Pulumi.yaml@, which is the project name Pulumi
-- resolves. Read rather than inferred from the directory, because the two do
-- not match.
pulumiProjectNameIn :: String -> Maybe Text.Text
pulumiProjectNameIn contents =
  case [Text.strip rest | line <- lines contents, Just rest <- [stripName line]] of
    project : _ | not (Text.null project) -> Just project
    _ -> Nothing
 where
  stripName line = Text.stripPrefix (Text.pack "name:") (Text.pack line)

-- | The binding the field-of-view join evaluates the query catalog at.
--
-- The join decides over tag /families/, not names: four of the five queries are
-- name-free, and the fifth — the per-run Kubernetes cluster-ownership tag — is
-- matched by its family prefix, because a provisioning program templates the
-- cluster name it embeds. The values here are therefore deliberately synthetic
-- placeholders that no comparison consults.
fieldOfViewQueryBinding :: Either RetainedBindingError RetainedNameBinding
fieldOfViewQueryBinding =
  mkRetainedNameBinding
    (Text.pack "field-of-view-placeholder-state-bucket")
    (Text.pack "field-of-view-placeholder-capture-bucket")
    (Text.pack "field-of-view-placeholder.invalid")
    (Text.pack "field-of-view-placeholder-cluster")

-- | Certify that the committed @charts/gateway/values.yaml@ static defaults
-- equal the compiled 'ChartStatics.gatewayChartStatics' projection. Reads the
-- values file and delegates to the pure 'gatewayChartStaticsConformanceViolations'.
checkGatewayChartStatics :: FilePath -> IO [String]
checkGatewayChartStatics repoRoot = do
  let valuesPath = repoRoot </> "charts" </> "gateway" </> "values.yaml"
  exists <- doesFileExist valuesPath
  if not exists
    then pure ["charts/gateway/values.yaml is missing the gateway chart-statics defaults."]
    else do
      valuesContents <- readFileStrict valuesPath
      pure (gatewayChartStaticsConformanceViolations valuesContents)

-- | Sprint 2.34 (pure). Prove the deployed helm values equal the compiled
-- 'ChartStatics.gatewayChartStatics' projection: every static identity — ports,
-- NodePort, ServiceAccount name, and Vault role — must appear verbatim in
-- @values.yaml@. Exposed for the conformance unit suite.
gatewayChartStaticsConformanceViolations :: String -> [String]
gatewayChartStaticsConformanceViolations valuesContents =
  [ "charts/gateway/values.yaml drifted from the compiled GatewayChartStatics `"
      ++ field
      ++ "` (expected `"
      ++ expected
      ++ "`)."
  | (field, expected) <- expectedStatics
  , not (expected `isInfixOf` valuesContents)
  ]
 where
  statics = ChartStatics.gatewayChartStatics
  expectedStatics =
    [ ("ports.rest", "rest: " ++ show (ChartStatics.gatewayStaticRestPort statics))
    , ("ports.events", "events: " ++ show (ChartStatics.gatewayStaticEventsPort statics))
    , ("nodePort.rest", "rest: " ++ show (ChartStatics.gatewayStaticNodePort statics))
    , ("serviceAccount.name", "name: " ++ Text.unpack (ChartStatics.gatewayStaticServiceAccount statics))
    , ("vault.role", "role: " ++ Text.unpack (ChartStatics.gatewayStaticVaultRole statics))
    ]
      ++ [ ("externalCallers.serviceAccounts", "- " ++ Text.unpack serviceAccount)
         | serviceAccount <- ChartStatics.gatewayStaticExternalCallerServiceAccounts statics
         ]

-- | Sprint 3.26 (pure). Prove the committed @charts/bootstrap-broker/values.yaml@
-- static defaults equal the compiled 'BrokerChartStatics.brokerChartStatics'
-- projection: the ServiceAccount name, the bootstrap-only Vault role, and both
-- lifecycle probe paths must appear verbatim in @values.yaml@. The
-- generated-section drift gate enforces byte-equality of the marked block; this
-- is the complementary field-level check exposed for the conformance unit suite.
bootstrapBrokerChartStaticsConformanceViolations :: String -> [String]
bootstrapBrokerChartStaticsConformanceViolations valuesContents =
  [ "charts/bootstrap-broker/values.yaml drifted from the compiled BrokerChartStatics `"
      ++ field
      ++ "` (expected `"
      ++ expected
      ++ "`)."
  | (field, expected) <- expectedStatics
  , not (expected `isInfixOf` valuesContents)
  ]
 where
  statics = BrokerChartStatics.brokerChartStatics
  expectedStatics =
    [
      ( "serviceAccount.name"
      , "name: " ++ Text.unpack (BrokerChartStatics.brokerStaticServiceAccount statics)
      )
    ,
      ( "cleanupCaller.serviceAccountName"
      , "serviceAccountName: "
          ++ Text.unpack (BrokerChartStatics.brokerStaticCleanupCallerServiceAccount statics)
      )
    ,
      ( "client.serviceAccountName"
      , "serviceAccountName: "
          ++ Text.unpack (BrokerChartStatics.brokerStaticClientServiceAccount statics)
      )
    ,
      ( "client.tokenAudience"
      , "tokenAudience: " ++ Text.unpack (BrokerChartStatics.brokerStaticTokenAudience statics)
      )
    , ("vault.role", "role: " ++ Text.unpack (BrokerChartStatics.brokerStaticVaultRole statics))
    ,
      ( "probes.liveness"
      , "liveness: " ++ Text.unpack (BrokerChartStatics.brokerStaticLivenessPath statics)
      )
    ,
      ( "probes.readiness"
      , "readiness: " ++ Text.unpack (BrokerChartStatics.brokerStaticReadinessPath statics)
      )
    ]

-- | Certify every committed measured-capacity profile against the authored
-- default resource plan. Inert until a profile is committed under
-- @dhall/capacity/measured/@ (Sprint 1.65).
checkMeasuredCapacityProfiles :: FilePath -> IO [String]
checkMeasuredCapacityProfiles repoRoot = do
  posixNow <- getPOSIXTime
  let now = fromIntegral (floor posixNow :: Integer) :: Natural
  certifyMeasuredProfiles repoRoot now defaultResourcePlan

-- | Effectful half of the legacy-escape bijection check: read every scanned
-- source file and delegate to the pure 'escapeRegistryViolations'. Exposed for
-- the conformance-tier unit suite.
checkLegacyEscapeRegistry :: FilePath -> IO [String]
checkLegacyEscapeRegistry repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  scanned <-
    forM
      (filter isLegacyEscapeScanFile repoPaths)
      ( \relativePath -> do
          contents <- readFileStrict (repoRoot </> relativePath)
          pure (relativePath, contents)
      )
  pure (escapeRegistryViolations scanned)

runHaskellLint :: FilePath -> [(String, String)] -> Bool -> IO ExitCode
runHaskellLint repoRoot environment writeEnabled = do
  bootstrapResult <- ensureSandboxedStyleTools repoRoot environment
  case bootstrapResult of
    Right () -> do
      sandboxViolations <- missingStyleToolViolations (styleToolsBinDir repoRoot)
      case sandboxViolations of
        [] -> do
          styleViolations <- haskellStyleViolations repoRoot
          case styleViolations of
            [] -> do
              formatExit <-
                runSubprocessStreaming
                  repoRoot
                  environment
                  (styleToolsBinDir repoRoot </> "fourmolu")
                  (["--mode", if writeEnabled then "inplace" else "check", "app", "src", "test"])
              case formatExit of
                ExitFailure _ -> pure formatExit
                ExitSuccess -> do
                  lintExit <-
                    runSubprocessStreaming
                      repoRoot
                      environment
                      (styleToolsBinDir repoRoot </> "hlint")
                      ["app", "src", "test", "--hint=.hlint.yaml", "--with-group=default", "--with-group=extra"]
                  case lintExit of
                    ExitFailure _ -> pure lintExit
                    ExitSuccess ->
                      if writeEnabled
                        then rewriteCabalFile repoRoot environment
                        else checkCabalFormat repoRoot environment
            _ ->
              failWith
                (unlines ("Haskell style lint failed:" : map ("- " ++) styleViolations))
        _ ->
          failWith
            (unlines ("Haskell style lint failed:" : map ("- " ++) sandboxViolations))
    Left err ->
      failWith
        (unlines ["Haskell style lint failed:", "- " ++ err])

runChartLint :: FilePath -> IO ExitCode
runChartLint repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let chartFiles =
        sort
          [ path
          | path <- repoPaths
          , takeFileName path == "Chart.yaml"
          , "charts" `isPrefixOf` path
          ]
  if null chartFiles
    then failWith "No chart manifests found under `charts/`."
    else do
      chartViolations <- fmap concat (forM chartFiles (chartViolationsFor repoRoot))
      generatedResults <- processChartGeneratedArtifacts repoRoot
      case chartViolations ++ leftMessages generatedResults of
        [] -> pure ExitSuccess
        violations ->
          failWith (unlines ("Chart lint failed:" : map ("- " ++) violations))

runDoctrineAlignmentCheck :: FilePath -> IO ExitCode
runDoctrineAlignmentCheck repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let surfaceViolations =
        map (("- " ++) . renderDoctrineViolation) (doctrineViolationsInPaths repoPaths)
  serviceErrorViolations <- checkServiceErrorRetryableLiteral repoRoot
  inlineRetryListViolations <- checkInlineRetrySubstringLists repoRoot
  planOptionsHonoredViolations' <- checkPlanOptionsHonored repoRoot
  -- Sprint 4.27: the create-site coverage lint (the §3.1 totality gate
  -- over every `aws`/`pulumi` create call site, now generalized from
  -- IAM-only to every AWS-resource create verb via
  -- 'awsCreateSiteViolations') is a doctrine-alignment check, so it is
  -- wired here rather than alongside the Haskell-style lints.
  createCallSiteViolations <- checkCreateCallSiteCoverage repoRoot
  -- Sprint 0.28: the production `PRODBOX_*` read registry. Wired beside the
  -- create-site coverage gate because it is the same shape — a registry the
  -- worktree must agree with, rather than a claim about it.
  productionEnvVarViolations <- checkProductionEnvVarReads repoRoot
  -- Sprint 1.91: the compiled-AWS-coordinate registry. Same register-or-fail
  -- shape as the read registry above, over the partition config_doctrine.md § 0
  -- draws between a value AWS fixes and a value an operator chooses.
  awsCoordinateViolations <- checkAwsCoordinateLiterals repoRoot
  -- Sprint 7.12: substrate equivalence is a structural invariant — a shared
  -- platform component's chart version / image must come from the single
  -- 'Prodbox.ContainerImage' pin, never be re-pinned on a per-substrate
  -- branch. This is a doctrine-alignment check, so it is wired here.
  substrateImagePinningViolations' <- checkSubstrateImagePinning repoRoot
  case surfaceViolations
    ++ map ("- " ++) serviceErrorViolations
    ++ map ("- " ++) inlineRetryListViolations
    ++ map ("- " ++) planOptionsHonoredViolations'
    ++ map ("- " ++) createCallSiteViolations
    ++ map ("- " ++) managedResourceRegistryParityViolations
    ++ map ("- " ++) untypedLifecycleInventoryViolations
    ++ map ("- " ++) legacyOperationalResourceParityViolations
    ++ map ("- " ++) registeredTargetExecutorViolations
    ++ map ("- " ++) ownershipEdgeDerivationViolations
    ++ map ("- " ++) capabilityDependantDerivationViolations
    ++ map ("- " ++) codeCreatedResourceFieldOfViewViolations
    ++ map ("- " ++) decommissionProgramTagParityViolations
    ++ map ("- " ++) decommissionInterpreterIdentityViolations
    ++ map ("- " ++) decommissionTerminalPhaseOrderViolations
    ++ map ("- " ++) effectRegistryLifecycleClassViolations
    ++ map ("- " ++) operationalCredentialCoverageViolations
    ++ map ("- " ++) productionEnvVarViolations
    ++ map ("- " ++) awsCoordinateViolations
    ++ map ("- " ++) substrateImagePinningViolations' of
    [] -> pure ExitSuccess
    violations ->
      failWith
        ( unlines
            ( ( "Doctrine alignment failed. Remove unsupported workflow or git-hook surfaces, "
                  ++ "hand-set ServiceError retryable literals, "
                  ++ "inline retry-substring lists, "
                  ++ "destructive dispatch arms that discard their --dry-run / --plan-file "
                  ++ "options, AWS/Pulumi create call sites with no registered managed "
                  ++ "resource, lifecycle-class disagreements between the typed "
                  ++ "registry and resourceLifecycleClasses, registered teardown "
                  ++ "targets with no production executor on a completing surface, "
                  ++ "controller-owned families with no owning registered stack, "
                  ++ "code-created AWS resources outside the terminal audit's "
                  ++ "field of view, "
                  ++ "decommission program tags whose declared implementation "
                  ++ "disagrees with the compiled program or the manifest node "
                  ++ "universe, and operational-credential "
                  ++ "consumers the compiled cascade program does not order before its "
                  ++ "terminal audit, and unregistered compiled AWS coordinates:"
              )
                : violations
                ++ ["Rerun `./.build/prodbox dev check` after addressing the listed items."]
            )
        )

haskellStyleViolations :: FilePath -> IO [String]
haskellStyleViolations repoRoot = do
  thinMainResult <- verifyThinMainEntrypoint repoRoot
  hlintConfigViolations <- checkHlintDoctrineCoverage repoRoot
  parserModuleViolation <- checkParserModuleImports repoRoot
  nestedCaseViolations <- checkNestedCaseViolations repoRoot
  daemonRuntimeViolations <- checkDaemonRuntimeImports repoRoot
  daemonHookViolations <- checkDaemonHookContract repoRoot
  daemonLifecycleTestViolations <- checkDaemonLifecycleTestBoundaries repoRoot
  subprocessViolations <- checkSubprocessBoundaries repoRoot
  errorBoundaryViolations <- checkErrorBoundaryViolations repoRoot
  operatorVocabularyViolations <- checkOperatorVocabulary repoRoot
  envVarConfigViolations <- checkEnvVarConfigReads repoRoot
  testSuiteTypeViolations <- checkTestSuiteInterfaces repoRoot
  forbidDotProdboxStateViolations <- checkForbidDotProdboxState repoRoot
  secretPayloadInternalViolations <- checkSecretPayloadInternalBoundary repoRoot
  targetSinkVersionViolations <- checkTargetSinkVersionBoundary repoRoot
  targetSinkRecordViolations <- checkTargetSinkRecordMinter repoRoot
  roundTripWitnessViolations <- checkRoundTripWitnessBoundary repoRoot
  dnsOwnerAuthorityViolations <- checkDnsOwnerAuthorityBoundary repoRoot
  dependencyAdmissionViolations <- checkDependencyAdmissionBoundary repoRoot
  responseObligationFindings <- checkResponseObligation repoRoot
  tier0EncoderFindings <- checkTier0FixtureEncoder repoRoot
  sharedRetryViolations <- checkSharedRetrySchedule repoRoot
  brokerReadinessViolations <- checkBrokerReadinessProjection repoRoot
  roleReadinessViolations <- checkRoleReadinessProjection repoRoot
  supervisedWorkerViolationsFound <- checkSupervisedWorkers repoRoot
  replyStatusViolations <- checkControlPlaneReplyStatusCoverage repoRoot
  committedValueViolations <- checkCommittedValueHygiene repoRoot
  vaultCasFindings <- checkVaultCasClassification repoRoot
  validatedSettingsFindings <- checkValidatedSettingsMinter repoRoot
  tier0CoordinateFindings <- checkTier0CoordinateReads repoRoot
  listenPortFindings <- checkControlPlaneListenPortOwner repoRoot
  residueMinterFindings <- checkResidueObservationMinter repoRoot
  workerImagePullFindings <- checkWorkerImagePullReferenceOwner repoRoot
  testNamespaceFindings <- checkTestNamespaceBoundary repoRoot
  pure
    ( either pure (const []) thinMainResult
        ++ hlintConfigViolations
        ++ maybeToList parserModuleViolation
        ++ nestedCaseViolations
        ++ daemonRuntimeViolations
        ++ daemonHookViolations
        ++ daemonLifecycleTestViolations
        ++ subprocessViolations
        ++ errorBoundaryViolations
        ++ operatorVocabularyViolations
        ++ envVarConfigViolations
        ++ testSuiteTypeViolations
        ++ forbidDotProdboxStateViolations
        ++ secretPayloadInternalViolations
        ++ targetSinkVersionViolations
        ++ targetSinkRecordViolations
        ++ roundTripWitnessViolations
        ++ dnsOwnerAuthorityViolations
        ++ dependencyAdmissionViolations
        ++ responseObligationFindings
        ++ tier0EncoderFindings
        ++ sharedRetryViolations
        ++ brokerReadinessViolations
        ++ roleReadinessViolations
        ++ supervisedWorkerViolationsFound
        ++ replyStatusViolations
        ++ committedValueViolations
        ++ vaultCasFindings
        ++ validatedSettingsFindings
        ++ tier0CoordinateFindings
        ++ listenPortFindings
        ++ workerImagePullFindings
        ++ testNamespaceFindings
        ++ residueMinterFindings
    )

checkHlintDoctrineCoverage :: FilePath -> IO [String]
checkHlintDoctrineCoverage repoRoot = do
  let hintPath = repoRoot </> ".hlint.yaml"
  fileExists <- doesFileExist hintPath
  if not fileExists
    then pure ["Missing `/.hlint.yaml` doctrine configuration file."]
    else do
      contents <- readFileStrict hintPath
      pure
        [ "`.hlint.yaml` must mention `" ++ marker ++ "`."
        | marker <-
            [ "Refactor nested case"
            , "Avoid case inside lambda body"
            , "forkIO"
            , "unsafePerformIO"
            , "module-level IORef"
            , "callProcess"
            , "readCreateProcess"
            , "readCreateProcessWithExitCode"
            , "createProcess"
            , "proc"
            , "shell"
            , "putStr"
            , "Text.IO.putStrLn"
            , "hPutStrLn stderr"
            , "Aeson.object"
            , "Aeson.fromList"
            , "sd_notify"
            , "READY=1"
            , "System.FSNotify"
            , "newIORef"
            , "newMVar"
            , "withAsync"
            , "race"
            , "concurrently"
            , "replicateConcurrently"
            ]
        , null (filter (isInfixOf marker) (lines contents))
        ]

checkSecretPayloadInternalBoundary :: FilePath -> IO [String]
checkSecretPayloadInternalBoundary repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , "src/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \path -> do
          contents <- readFileStrict (repoRoot </> path)
          pure (secretPayloadInternalSourceViolations (path, contents))
      )

secretPayloadInternalSourceViolations :: (FilePath, String) -> [String]
secretPayloadInternalSourceViolations (path, contents) =
  internalModuleViolations ++ eliminatorViolations
 where
  internalModuleName = "Prodbox.Bootstrap.Broker.Request.Internal"
  eliminatorName = "withSecretPayloadBytes"
  internalModuleAllowedPaths =
    [ "src/Prodbox/Bootstrap/Broker/Request.hs"
    , "src/Prodbox/Bootstrap/Broker/Request/Internal.hs"
    , "src/Prodbox/Bootstrap/Broker/PgpBoundary.hs"
    ]
  eliminatorAllowedPaths =
    [ "src/Prodbox/Bootstrap/Broker/Request/Internal.hs"
    , "src/Prodbox/Bootstrap/Broker/PgpBoundary.hs"
    ]
  internalModuleViolations =
    [ path
        ++ " imports or names the package-internal SecretPayload representation; "
        ++ "only Request and PgpBoundary may cross that boundary."
    | internalModuleName `isInfixOf` contents
    , path `notElem` internalModuleAllowedPaths
    ]
  eliminatorViolations =
    [ path
        ++ " uses the SecretPayload byte eliminator outside its definition or "
        ++ "the PgpBoundary primitive adapter."
    | eliminatorName `isInfixOf` contents
    , path `notElem` eliminatorAllowedPaths
    ]

-- | Vault KV v2 checks exactly one token when it accepts a conditional write:
-- the expected version.  A 'TargetSinkVersion' is therefore meant to be
-- evidence that a store read happened, which holds only while one module can
-- mint one.  Scoped to @src/@: a test fixture standing in for a store may
-- mint, and a test module cannot be imported by production code.
checkTargetSinkVersionBoundary :: FilePath -> IO [String]
checkTargetSinkVersionBoundary repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , "src/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \path -> do
          contents <- readFileStrict (repoRoot </> path)
          pure (targetSinkVersionInternalSourceViolations (path, contents))
      )

-- | Sprint 4.70: same shape and same scope as the target-sink-version boundary
-- above, over the record rather than the version. A test fixture standing in
-- for a store may mint one; a test module cannot be imported by production
-- code.
checkTargetSinkRecordMinter :: FilePath -> IO [String]
checkTargetSinkRecordMinter repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , "src/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \path -> do
          contents <- readFileStrict (repoRoot </> path)
          pure (targetSinkRecordMinterViolations (path, contents))
      )

-- | Sprint 1.76: a 'RoundTripWitness' asserts that a conditional WRITE reached
-- a store. That claim is only worth anything while the set of modules able to
-- make it is exactly the set that performed or authoritatively decoded one.
-- Scoped to @src\/@ for the same reason as the target-sink boundary: a test
-- fixture standing in for a store may mint, and a test module cannot be
-- imported by production code.
checkRoundTripWitnessBoundary :: FilePath -> IO [String]
checkRoundTripWitnessBoundary repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , "src/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \path -> do
          contents <- readFileStrict (repoRoot </> path)
          pure (roundTripWitnessInternalSourceViolations (path, contents))
      )

-- | Sprint 3.35: the control-plane role listen port has one compiled owner,
-- 'Prodbox.ControlPlane.ListenPort.controlPlaneListenPort'. This rule is the
-- Haskell half of the region Sprint 3.34's @chartTemplatePortLiteralViolations@
-- opened over chart templates: before both, the value existed only as a literal
-- restated in fourteen places across nine modules, so there was nothing for any
-- restatement to drift from.
--
-- __The bound is stated__: this is a text rule over @src\/@, so it stops the
-- literal from re-acquiring authors; it does not make a wrong port
-- unrepresentable. What makes the value single-sourced is that the binder, the
-- rendered chart values, the embedded broker Dhall, the AWS role-transport
-- table, and the loopback forward targets now all read the same binding.
checkControlPlaneListenPortOwner :: FilePath -> IO [String]
checkControlPlaneListenPortOwner repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , "src/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \path -> do
          contents <- readFileStrict (repoRoot </> path)
          pure (controlPlaneListenPortLiteralViolations (path, contents))
      )

controlPlaneListenPortLiteralViolations :: (FilePath, String) -> [String]
controlPlaneListenPortLiteralViolations (path, contents) =
  [ path
      ++ " spells the control-plane listen port literal `"
      ++ controlPlaneListenPortLiteral
      ++ "`. It has one compiled owner: import"
      ++ " Prodbox.ControlPlane.ListenPort (controlPlaneListenPort) and read it,"
      ++ " or use controlPlaneClusterServiceUrl for an in-cluster role endpoint."
  | controlPlaneListenPortLiteral `isInfixOf` contents
  , path `notElem` controlPlaneListenPortOwnerPaths
  ]

controlPlaneListenPortLiteral :: String
controlPlaneListenPortLiteral = "8600"

controlPlaneListenPortOwnerPaths :: [FilePath]
controlPlaneListenPortOwnerPaths = ["src/Prodbox/ControlPlane/ListenPort.hs"]

-- | Sprint 2.51: a Bootstrap Broker Pod's @image@ field is __observed, never
-- assembled__.
--
-- A container image has two sha256 identities and they are the same sixty-four
-- lower-hex characters: the __config__ digest the container runtime reports as
-- @status.containerStatuses[].imageID@, and the __manifest__ digest an OCI
-- registry can resolve. There is no reverse index from the first to the second,
-- so a reference built as @repo\@sha256:\<config digest\>@ is unpullable — and
-- because the two are syntactically identical, no smart constructor over the
-- digest text can tell them apart. That is
-- @chaos_hardening_doctrine.md@ § 24 exactly: an observation has a layer, and
-- this one named the runtime's layer while being consumed as the registry's.
--
-- The separation therefore lives at the consuming boundary rather than in the
-- digest, and this rule is what keeps it there. Two things are forbidden in the
-- Broker's own modules:
--
--   1. a Pod manifest @\"image\" .=@ applied to anything other than
--      'Prodbox.Bootstrap.Broker.KubernetesWorker.renderWorkerImagePullReference',
--      which is constructible only from a __declared__ reference naming the
--      compiled worker repository; and
--   2. building any reference by concatenating @\"\@\"@, which is the exact
--      shape the defect took at both sites it occupied.
--
-- __The bound is stated rather than implied.__ The rule is scoped to
-- @src\/Prodbox\/Bootstrap\/Broker\/@ because that is Sprint 2.51's owned
-- surface. Three sites outside it still assemble a digest reference and are
-- tracked as their own @Pending Removal@ rows; widening this scope belongs to
-- the sprint that fixes them, not to this one — a check that fails on work no
-- sprint has taken is a broken build, not a guard.
checkWorkerImagePullReferenceOwner :: FilePath -> IO [String]
checkWorkerImagePullReferenceOwner repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , any (`isPrefixOf` path) workerImageSourcePrefixes
      , ".hs" `isSuffixOf` path
      ]
      ( \path -> do
          contents <- readFileStrict (repoRoot </> path)
          pure (workerImagePullReferenceViolations (path, contents))
      )

bootstrapBrokerSourcePrefix :: FilePath
bootstrapBrokerSourcePrefix = "src/Prodbox/Bootstrap/Broker/"

workerImageSourcePrefixes :: [FilePath]
workerImageSourcePrefixes =
  [ bootstrapBrokerSourcePrefix
  , "src/Prodbox/ControlPlane/TargetSecretWorker"
  , "src/Prodbox/Lifecycle/CredentialProvisioner/"
  , "src/Prodbox/Lifecycle/AdminAction/"
  ]

-- | Pure so the unit suite can pin both contracts: it fires on the exact
-- pre-Sprint-2.51 source shape, and it passes on the current tree.
workerImagePullReferenceViolations :: (FilePath, String) -> [String]
workerImagePullReferenceViolations (path, contents) =
  [ path
      ++ ":"
      ++ show lineNumber
      ++ " builds an image reference by concatenating `\"@\"`. A pull reference"
      ++ " is observed from the controller's declared image, never assembled"
      ++ " from a digest — see `WorkerImagePullReference`."
  | (lineNumber, line) <- numberedLines
  , "<> \"@\"" `isInfixOf` line || "\"@\" <>" `isInfixOf` line
  ]
 where
  numberedLines = zip [(1 :: Int) ..] (lines contents)

-- | Sprint 1.88: a 'Prodbox.Settings.ValidatedSettings' asserts that
-- @validateConfig@ ran and every Tier-0 invariant it decides was satisfied.
-- Before this sprint that was a property of 'validateConfig' rather than of the
-- value: the constructor is exported, and one production site
-- (@defaultResourceStatusSettings@ in @src\/Prodbox\/CLI\/Rke2.hs@) built a
-- record no validation had produced, obtaining its resource plan by @error@-ing
-- on failure. That site is gone — the status reader takes the two fields it
-- reads — and this rule keeps the seam closed.
--
-- __The bound is stated rather than implied__: this is a compiled rule over a
-- source region, not a property of the type. The constructor stays exported
-- because @test\/unit\/Main.hs@ builds fixture settings purely at 40 call sites,
-- and routing those through the @IO@ @validateConfig@ is a coupled change with
-- its own measurement to take. Scoped to @src\/@ for the same reason as the
-- round-trip witness and the target-sink boundary: a test fixture may mint, and
-- a test module cannot be imported by production code
-- (@resource_scaling_doctrine.md@ § 2C, "The region of Ring 2").
checkValidatedSettingsMinter :: FilePath -> IO [String]
checkValidatedSettingsMinter repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , "src/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \path -> do
          contents <- readFileStrict (repoRoot </> path)
          pure (validatedSettingsMinterViolations (path, contents))
      )

validatedSettingsMinterViolations :: (FilePath, String) -> [String]
validatedSettingsMinterViolations (path, contents) =
  [ path
      ++ " assigns `"
      ++ fieldName
      ++ "`, which builds or updates a ValidatedSettings outside validateConfig."
      ++ " A ValidatedSettings is the claim that every Tier-0 invariant was"
      ++ " decided; Prodbox.Settings.validateConfig is the only production site"
      ++ " entitled to make it."
  | fieldName <- validatedSettingsConstructionFields
  , (fieldName ++ " =") `isInfixOf` contents
  , path `notElem` validatedSettingsMinterAllowedPaths
  ]

-- | The field names whose /assignment/ means a 'ValidatedSettings' is being
-- built or record-updated. Reads use the same names as accessors and carry no
-- @=@, so this discriminates construction from use without parsing.
--
-- Positional coupling is deliberate: this list must name every field of the
-- record, and a field added without a row here is a hole in the rule. The unit
-- case beside it pins that correspondence.
validatedSettingsConstructionFields :: [String]
validatedSettingsConstructionFields =
  [ "validatedConfig"
  , "resolvedManualPvHostRoot"
  , "validatedAllocatedPlan"
  , "validatedPublicEdge"
  , "validatedCoordinates"
  ]

validatedSettingsMinterAllowedPaths :: [FilePath]
validatedSettingsMinterAllowedPaths = ["src/Prodbox/Settings.hs"]

-- | Sprint 1.89: a module holding a 'Prodbox.Settings.ValidatedSettings' reads
-- a Tier-0 coordinate through its parsed projection, or not at all.
--
-- The defect this closes is not that the raw fields exist — they are the Dhall
-- wire record and must — but that validation decided them and then every
-- consumer re-read the undecided text beside the decision. Sprint 1.83 fixed
-- that for the public edge and the pattern did not spread on its own: three
-- sprints later the served host was still being re-read from
-- @domain.demo_fqdn@ in four places.
--
-- __What this proves and what it does not.__ It proves no @src\/@ module reaches
-- a registered coordinate field through a 'ValidatedSettings', by either of the
-- two spellings that exist — the direct chain, and the local alias
-- (@let config = validatedConfig settings@) that the direct-chain rule alone
-- would miss. It does not prove the field is unreachable: a module could pass
-- the section itself to a helper, and a rule over source text cannot see that.
-- The bound is stated because it is a compiled rule over a source region, not a
-- property of the type — the same bound 'checkValidatedSettingsMinter' carries
-- and for the same reason.
--
-- Reads of an /unvalidated/ 'Prodbox.Settings.ConfigFile' are deliberately not
-- registered. @Prodbox.Aws@ builds a config from operator answers and
-- @Prodbox.CLI.Rke2.resolveRetainedManualPvRoot@ reads one that
-- 'Prodbox.Settings.validateConfig' has not seen and cannot see; in both, raw
-- is the only thing there is to read, and there is no discarded decision.
checkTier0CoordinateReads :: FilePath -> IO [String]
checkTier0CoordinateReads repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , "src/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path `notElem` tier0CoordinateReadAllowedPaths
      ]
      ( \path -> do
          contents <- readFileStrict (repoRoot </> path)
          pure (tier0CoordinateReadViolations (path, contents))
      )

tier0CoordinateReadViolations :: (FilePath, String) -> [String]
tier0CoordinateReadViolations (path, contents) =
  [ path
      ++ " reads the raw Tier-0 field `"
      ++ field
      ++ "` from a ValidatedSettings ("
      ++ chain
      ++ "). Validation already decided this coordinate; read the parsed"
      ++ " projection on Prodbox.Settings.ValidatedCoordinates instead of the"
      ++ " undecided text beside it."
  | (field, section) <- tier0CoordinateReadRegistry
  , holder <- validatedConfigHolders contents
  , let chain = field ++ " (" ++ section ++ " " ++ holder
  , chain `isInfixOf` contents
  ]

-- | The spellings by which a module can hold the decoded record of a
-- 'ValidatedSettings': the accessor applied inline, and any local name bound to
-- it.
validatedConfigHolders :: String -> [String]
validatedConfigHolders contents =
  "(validatedConfig" : [alias | alias <- aliases, not (null alias)]
 where
  aliases =
    [ takeWhile (\character -> not (isSpace character)) (dropWhile isSpace line)
    | line <- lines contents
    , "= validatedConfig " `isInfixOf` line
    ]

-- | The coordinate fields with a parsed projection, keyed by the section
-- accessor that reaches them.
--
-- Positional coupling is deliberate, exactly as in
-- 'validatedSettingsConstructionFields': a field given a projection on
-- 'Prodbox.Settings.ValidatedCoordinates' and not added here is a hole in the
-- rule, and the unit case beside it pins that correspondence against the
-- record.
tier0CoordinateReadRegistry :: [(String, String)]
tier0CoordinateReadRegistry =
  [ ("zone_id", "route53")
  , ("hosted_zone_id", "aws_substrate")
  , ("subzone_name", "aws_substrate")
  , ("awsCredentialRegion", "aws")
  , ("psbRegion", "pulumi_state_backend")
  , ("psbBucketName", "pulumi_state_backend")
  , ("psbKeyPrefix", "pulumi_state_backend")
  , ("sender_domain", "ses")
  , ("receive_subdomain", "ses")
  , ("capture_bucket", "ses")
  , ("demo_fqdn", "domain")
  , ("demo_ttl", "domain")
  , ("manual_pv_host_root", "storage")
  , ("email", "acme")
  , ("server", "acme")
  , ("bootstrap_public_ip_override", "deployment")
  ]

-- | 'Prodbox.Settings' is where the projections are built, so it necessarily
-- reads every raw field this rule forbids elsewhere. 'Prodbox.CheckCode' names
-- the fields in the registry above.
tier0CoordinateReadAllowedPaths :: [FilePath]
tier0CoordinateReadAllowedPaths =
  [ "src/Prodbox/Settings.hs"
  , "src/Prodbox/CheckCode.hs"
  ]

-- | Sprint 3.32: a 'DnsOwnerAuthority' asserts that the running process /is/
-- the named DNS owner.  A destroy consumes it instead of comparing two
-- caller-supplied copies of the coordinate's owner, which is why the assertion
-- must be unforgeable: the newtype constructor lives in the package-internal
-- module and only the module exporting the minter may name it.  Scoped to
-- @src\/@ for the same reason as the round-trip witness — a test may mint, and
-- a test module cannot be imported by production code.
checkDnsOwnerAuthorityBoundary :: FilePath -> IO [String]
checkDnsOwnerAuthorityBoundary repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , "src/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \path -> do
          contents <- readFileStrict (repoRoot </> path)
          pure (dnsOwnerAuthorityInternalSourceViolations (path, contents))
      )

-- | Sprint 4.81: a residue observation is minted by the module that made the
-- observation, or not at all.
--
-- 'Prodbox.Lifecycle.ResidueStatus.ResidueObservation' pairs a residue answer
-- with the authority that produced it, and its constructor is unexported so
-- 'observeResidueAt' is the sole minter. That alone stops a caller
-- /fabricating/ the pair, but not a caller far from any observation asserting a
-- layer it did not consult — which is the class-A defect in its original form:
-- a witness constructed by describing the operation rather than returned by
-- performing it.
--
-- This rule supplies the missing force over the compiled source region: only
-- the modules that actually hold an observation boundary may name the minter.
-- It is the same idiom as the Sprint @1.76@ @RoundTripWitness@ and Sprint
-- @4.58@ @TargetSinkVersion@ boundaries and Sprint @3.32@'s
-- 'checkDnsOwnerAuthorityBoundary'.
--
-- __The bound is stated__ (@chaos_hardening_doctrine.md § 22@): this is a
-- compiled rule over a source region, not a property of the type. It cannot
-- prove that a permitted module named the /correct/ layer — only that a module
-- with no observation boundary cannot name one at all.
residueObservationMinterOwners :: [FilePath]
residueObservationMinterOwners =
  [ "src/Prodbox/Lifecycle/ResidueStatus.hs"
  , "src/Prodbox/Lifecycle/LiveResidue.hs"
  ]

checkResidueObservationMinter :: FilePath -> IO [String]
checkResidueObservationMinter repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , "src/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/CheckCode.hs"
      , path `notElem` residueObservationMinterOwners
      ]
      ( \path -> do
          contents <- readFileStrict (repoRoot </> path)
          pure (residueObservationMinterViolations (path, contents))
      )

residueObservationMinterViolations :: (FilePath, String) -> [String]
residueObservationMinterViolations (path, contents) =
  [ path
      ++ ":"
      ++ show lineNumber
      ++ " names `observeResidueAt` outside a residue-observation boundary. A "
      ++ "residue observation records which authority answered, so it must be "
      ++ "minted where the observation is made, not asserted by a consumer "
      ++ "downstream (chaos_hardening_doctrine.md § 21 class-A, § 24). The "
      ++ "modules permitted to mint are: "
      ++ intercalate ", " residueObservationMinterOwners
      ++ ". If this module genuinely observes residue at a new authority, add it "
      ++ "to `residueObservationMinterOwners` in the same change that adds the "
      ++ "boundary -- never to silence this rule."
  | (lineNumber, line) <- zip [1 :: Int ..] (lines contents)
  , "observeResidueAt" `isInfixOf` line
  , not ("--" `isPrefixOf` dropWhile isSpace line)
  ]

-- | Sprint 4.74: a Vault CAS result is read through its classifier or not at
-- all.
--
-- The three facts a CAS attempt can establish — a lost race, a refused
-- request, and an attempt whose outcome is unknown — are distinguishable only
-- through 'Prodbox.Vault.Client.classifyVaultCasOutcome'. Nothing in the type
-- forces a caller to use it, because the transport result must stay an
-- @Either HttpError@ for the Vault session wrapper's single relogin. This rule
-- supplies the missing force over the compiled source region instead: a module
-- that writes a CAS and does not classify it fails the build.
--
-- What this does not prove is the same thing
-- @chaos_hardening_doctrine.md § 22@ says of every ring-2 gate: it bounds this
-- repository's source, not the Vault protocol.
checkVaultCasClassification :: FilePath -> IO [String]
checkVaultCasClassification repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , "src/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \path -> do
          contents <- readFileStrict (repoRoot </> path)
          pure (vaultCasClassificationViolations (path, contents))
      )

vaultCasClassificationViolations :: (FilePath, String) -> [String]
vaultCasClassificationViolations (path, contents) =
  [ path
      ++ " performs a Vault KV-v2 compare-and-swap without reading the result "
      ++ "through `classifyVaultCasOutcome`. A lost race, a refused request, and "
      ++ "an attempt whose outcome is unknown are three different facts, and "
      ++ "matching on `HttpStatus` at the call site reports the first two as each "
      ++ "other and the third as either (Sprint 4.74)."
  | path `notElem` classifierOwningPaths
  , "vaultKvCasWriteV2" `isInfixOf` contents
  , not ("classifyVaultCasOutcome" `isInfixOf` contents)
  ]
 where
  classifierOwningPaths = ["src/Prodbox/Vault/Client.hs"]

-- | Sprint 4.56: the admission minting boundary, same shape and same reason.
checkDependencyAdmissionBoundary :: FilePath -> IO [String]
checkDependencyAdmissionBoundary repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , "src/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \path -> do
          contents <- readFileStrict (repoRoot </> path)
          pure (dependencyAdmissionInternalSourceViolations (path, contents))
      )

-- | Sprint 2.41: a long-lived gateway worker is spawned only through
-- 'withSupervisedWorkers', which links the handle and records the worker's exit
-- on every path. Eight workers used to be spawned through raw @withAsync@ with
-- their handles discarded, so a worker that died was invisible to readiness and
-- its exception reached nobody.
--
-- This is the negative-space check pattern Sprint 2.10 established for
-- module-local mutable counters: the rule is that the raw primitive is not in
-- scope, and the check is what makes it fail.
checkSupervisedWorkers :: FilePath -> IO [String]
checkSupervisedWorkers repoRoot = do
  let relativePath = "src/Prodbox/Gateway/Daemon.hs"
      absolutePath = repoRoot </> relativePath
  exists <- doesFileExist absolutePath
  contents <- if exists then readFileStrict absolutePath else pure ""
  pure (supervisedWorkerViolations (relativePath, if exists then Just contents else Nothing))

supervisedWorkerViolations :: (FilePath, Maybe String) -> [String]
supervisedWorkerViolations (path, Nothing) =
  [path ++ " is missing; the supervised-worker gate cannot run (Sprint 2.41)."]
supervisedWorkerViolations (path, Just contents) =
  unqualifiedImport ++ missingSupervisor
 where
  unqualifiedImport =
    [ path
        ++ " imports `withAsync` unqualified. A long-lived daemon worker is"
        ++ " spawned only through `withSupervisedWorkers`, which links the handle"
        ++ " and records the worker's exit on every path (Sprint 2.41)."
    | sourceLine <- lines contents
    , "import " `isPrefixOf` dropWhile isSpace sourceLine
    , "Control.Concurrent.Async" `isInfixOf` sourceLine
    , "withAsync" `isInfixOf` sourceLine
    ]
  missingSupervisor =
    [ path
        ++ " no longer defines `withSupervisedWorkers`; the supervised-worker"
        ++ " gate has nothing to protect (Sprint 2.41)."
    | not ("withSupervisedWorkers ::" `isInfixOf` contents)
    ]

-- | Sprint 2.39 deliverable 3: assert that the Bootstrap Broker's @\/readyz@
-- performs no boundary I/O in its request path.
--
-- The chart's @probeTiming@ comment has always asserted this, and the runtime
-- did not honour it: @productionReady@ used to perform a MinIO @listKeys@ plus a
-- generation read, a Vault seal call, and two Kubernetes reads each with a
-- five-second deadline, inline, against a @timeoutSeconds: 1@ probe budget. The
-- measured consequence was @\/healthz@ at 0.19 ms and @\/readyz@ at 5.003 s, so
-- the Deployment never reported available and @cluster reconcile@ exited 1
-- before Vault was initialized. The projection was rewritten; nothing stopped it
-- from being un-rewritten, and this is that gate.
--
-- It makes two structural claims rather than looking for known-bad calls:
--
--   * the projection module imports only pure modules, so no boundary is even in
--     scope where the fold is defined;
--   * the request-path function's body draws from an exact token allowlist, so a
--     NEW call — not merely a previously-seen one — fails the gate. A
--     forbidden-substring list would have to be extended every time somebody
--     invents a way to reach a backend; an allowlist does not.
checkBrokerReadinessProjection :: FilePath -> IO [String]
checkBrokerReadinessProjection repoRoot = do
  sources <-
    forM
      [ brokerReadinessModulePath
      , brokerReadinessRequestPath
      ]
      ( \relativePath -> do
          let absolutePath = repoRoot </> relativePath
          exists <- doesFileExist absolutePath
          contents <- if exists then readFileStrict absolutePath else pure ""
          pure (relativePath, if exists then Just contents else Nothing)
      )
  pure (brokerReadinessProjectionViolations sources)

brokerReadinessModulePath :: FilePath
brokerReadinessModulePath = "src/Prodbox/Bootstrap/Broker/Readiness.hs"

brokerReadinessRequestPath :: FilePath
brokerReadinessRequestPath = "src/Prodbox/Bootstrap/Broker/ProductionEngine.hs"

-- | Sprint 4.55: the same structural claim as the broker's, for the five
-- control-plane roles.
--
-- The role readiness projection folds boundary-owned cached facts, so it must
-- have no boundary in scope. It is allowed one thing the broker's is not:
-- @Control.Concurrent.STM@. That is the deliverable rather than an exception —
-- @STM@ cannot perform @IO@, so a seam typed as an @STM@ read is a seam a
-- signed S3 @LIST@, a Vault read, or an @aws sts get-caller-identity@
-- subprocess cannot hide behind. Everything effectful lives in
-- "Prodbox.ControlPlane.RoleReadinessObserver", which runs off the request
-- path.
checkRoleReadinessProjection :: FilePath -> IO [String]
checkRoleReadinessProjection repoRoot = do
  let relativePath = roleReadinessModulePath
      absolutePath = repoRoot </> relativePath
  exists <- doesFileExist absolutePath
  contents <- if exists then readFileStrict absolutePath else pure ""
  pure
    ( roleReadinessProjectionViolations
        (relativePath, if exists then Just contents else Nothing)
    )

roleReadinessModulePath :: FilePath
roleReadinessModulePath = "src/Prodbox/ControlPlane/RoleReadiness.hs"

roleReadinessProjectionViolations :: (FilePath, Maybe String) -> [String]
roleReadinessProjectionViolations (path, Nothing) =
  [ path
      ++ " is missing; the control-plane role readiness projection gate cannot"
      ++ " run (Sprint 4.55)."
  ]
roleReadinessProjectionViolations (path, Just contents) =
  impureImports ++ missingSeam
 where
  impureImports =
    [ path
        ++ " imports `"
        ++ moduleName
        ++ "`, which is not a pure module and is not `Control.Concurrent.STM`."
        ++ " A role readiness projection folds cached facts and must have no"
        ++ " boundary in scope; the observation belongs in"
        ++ " Prodbox.ControlPlane.RoleReadinessObserver (Sprint 4.55)."
    | moduleName <- importedModuleNames contents
    , not (any (`isPrefixOf` moduleName) pureModulePrefixes)
    , moduleName `notElem` pureProdboxModules
    , moduleName `notElem` roleReadinessAllowedEffectModules
    ]
  missingSeam =
    [ path
        ++ " no longer defines the `RoleReadinessSource` newtype over `STM`;"
        ++ " the seam that makes backend I/O on a probe path a type error has"
        ++ " nothing to protect (Sprint 4.55)."
    | not ("newtype RoleReadinessSource = RoleReadinessSource (STM " `isInfixOf` contents)
    ]

-- | The one non-pure module the role readiness projection may name. @STM@ has
-- no @IO@; that is the entire point of typing the seam with it.
roleReadinessAllowedEffectModules :: [String]
roleReadinessAllowedEffectModules =
  [ "Control.Concurrent.STM"
  ]

brokerReadinessProjectionViolations :: [(FilePath, Maybe String)] -> [String]
brokerReadinessProjectionViolations sources =
  concatMap check sources
 where
  check (path, Nothing) =
    [ path
        ++ " is missing; the broker readiness projection gate cannot run"
        ++ " (Sprint 2.39)."
    ]
  check (path, Just contents)
    | path == brokerReadinessModulePath = impureImportViolations path contents
    | path == brokerReadinessRequestPath = requestPathViolations path contents
    | otherwise = []

  impureImportViolations path contents =
    [ path
        ++ " imports `"
        ++ moduleName
        ++ "`, which is not a pure module. The broker readiness projection folds"
        ++ " boundary-owned cached facts and must have no boundary in scope"
        ++ " (bootstrap_readiness_doctrine.md § 0.7, Sprint 2.39)."
    | moduleName <- importedModuleNames contents
    , not (any (`isPrefixOf` moduleName) pureModulePrefixes)
    , moduleName `notElem` pureProdboxModules
    ]

  requestPathViolations path contents =
    case functionBodyTokens "productionReady" contents of
      Nothing ->
        [ path
            ++ " no longer defines `productionReady`; the broker readiness"
            ++ " request-path gate has nothing to check (Sprint 2.39)."
        ]
      Just tokens ->
        [ path
            ++ ": `productionReady` names `"
            ++ token
            ++ "`, which is not one of the reads the constant-time readiness"
            ++ " projection is allowed to perform. The request path may read the"
            ++ " monotonic clock and the latched record and fold them, and"
            ++ " nothing else (Sprint 2.39)."
        | token <- tokens
        , token `notElem` brokerReadinessRequestPathAllowedTokens
        ]

-- | Module prefixes with no I/O. Deliberately narrow: widening it is how a
-- boundary gets back into scope.
pureModulePrefixes :: [String]
pureModulePrefixes =
  [ "Data."
  , "Numeric."
  , "GHC.Generics"
  ]

-- | Repository modules a readiness projection may import, named __exactly__.
--
-- Sprint 4.55 shares one 'ObservationSchedule' between the Bootstrap Broker and
-- the five control-plane roles instead of copying the derivation, which means
-- the projection modules now import a @Prodbox.@ module. Listing the one module
-- by name keeps the gate's strength: adding @\"Prodbox.\"@ to
-- 'pureModulePrefixes' would put every boundary in the repository back in
-- scope, which is strictly worse than not sharing the schedule at all. A module
-- earns a place here only by importing nothing but 'pureModulePrefixes' itself.
pureProdboxModules :: [String]
pureProdboxModules =
  [ "Prodbox.Readiness.ObservationSchedule"
  ]

-- | Everything @productionReady@ may name. A clock read, a latched-record read,
-- the pure fold, and the binders that join them.
brokerReadinessRequestPathAllowedTokens :: [String]
brokerReadinessRequestPathAllowedTokens =
  [ "productionReady"
  , "cache"
  , "do"
  , "now"
  , "realMonotonicNow"
  , "facts"
  , "readTVarIO"
  , "brokerReadinessCacheFacts"
  , "pure"
  , "computeBrokerReadiness"
  , "brokerReadinessSchedule"
  , "monotonicInstantMicros"
  ]

-- | The module names an import list mentions.
importedModuleNames :: String -> [String]
importedModuleNames contents =
  [ moduleName
  | sourceLine <- lines contents
  , "import " `isPrefixOf` sourceLine
  , let afterImport = dropWhile isSpace (drop (length "import") sourceLine)
  , let withoutQualified =
          if "qualified " `isPrefixOf` afterImport
            then drop (length "qualified ") afterImport
            else afterImport
  , let moduleName =
          takeWhile
            (\character -> isAlphaNum character || character `elem` ("._'" :: String))
            withoutQualified
  , not (null moduleName)
  ]

-- | The identifier tokens in a top-level function's equation, excluding its type
-- signature, comments, and string literals. Returns 'Nothing' when the function
-- is not defined at all, so a deletion is a finding rather than a vacuous pass.
functionBodyTokens :: String -> String -> Maybe [String]
functionBodyTokens functionName contents =
  case equationLines of
    [] -> Nothing
    body -> Just (nub (concatMap tokenizeSource body))
 where
  sourceLines = lines contents
  isEquationStart sourceLine =
    (functionName ++ " ") `isPrefixOf` sourceLine
      && not ((functionName ++ " ::") `isPrefixOf` sourceLine)
  equationLines =
    case dropWhile (not . isEquationStart) sourceLines of
      [] -> []
      (first : rest) ->
        first : takeWhile (\sourceLine -> null sourceLine || " " `isPrefixOf` sourceLine) rest

-- | Sprint 1.77: Sprint 1.13 validation item 2 said "the retry surface is
-- consumed only through the @RetryPolicy@ API" and named no lint, no gate, and
-- no scan, so it could not be checked. This is that sentence as a rule that
-- fails, in the shape Sprint 2.10 item 4 established.
--
-- Two claims, both negative-space:
--
--   * no production module reaches the __un-jittered__ schedule
--     ('retryDelayMicros'); every delay is drawn through
--     'drawRetryDelayMicros', so a new retrier cannot reintroduce the lockstep
--     the sprint removed;
--   * no production module imports 'RetryPolicy' with its constructor, so a
--     schedule cannot be authored around 'mkRetryPolicy' by re-exporting it.
checkSharedRetrySchedule :: FilePath -> IO [String]
checkSharedRetrySchedule repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , "src/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \path -> do
          contents <- readFileStrict (repoRoot </> path)
          pure (sharedRetryScheduleViolations (path, contents))
      )

sharedRetryScheduleViolations :: (FilePath, String) -> [String]
sharedRetryScheduleViolations (path, contents) =
  scheduleViolations ++ constructorViolations
 where
  retryModulePath = "src/Prodbox/Retry.hs"
  scheduleViolations =
    [ path
        ++ " names the un-jittered retry schedule `retryDelayMicros`; production "
        ++ "delays are drawn through `drawRetryDelayMicros` so independent "
        ++ "retriers do not share one schedule (Sprint 1.77)."
    | path /= retryModulePath
    , "retryDelayMicros" `isInfixOf` withoutDrawSites
    ]
  -- `drawRetryDelayMicros` contains `RetryDelayMicros`, not `retryDelayMicros`,
  -- so the two do not collide; the blanking is belt-and-braces for a future
  -- rename that would make them overlap.
  withoutDrawSites = blankOut "drawRetryDelayMicros" contents
  constructorViolations =
    [ path
        ++ " imports RetryPolicy with its constructor; a schedule is a named "
        ++ "value in Prodbox.Retry or the result of `mkRetryPolicy` (Sprint 1.77)."
    | path /= retryModulePath
    , "RetryPolicy (..)" `isInfixOf` contents
    ]

-- | Replace every occurrence of @needle@ with spaces, so a longer identifier
-- cannot satisfy a search for the shorter one it contains.
blankOut :: String -> String -> String
blankOut needle = go
 where
  go [] = []
  go remaining@(character : rest)
    | needle `isPrefixOf` remaining = map (const ' ') needle ++ go (drop (length needle) remaining)
    | otherwise = character : go rest

roundTripWitnessInternalSourceViolations :: (FilePath, String) -> [String]
roundTripWitnessInternalSourceViolations (path, contents) =
  internalModuleViolations ++ minterViolations
 where
  internalModuleName = "Prodbox.ControlPlane.Observation.Internal"
  minterName = "mintRoundTripWitness"
  internalModuleAllowedPaths =
    [ "src/Prodbox/ControlPlane/Observation.hs"
    , "src/Prodbox/ControlPlane/Observation/Internal.hs"
    , "src/Prodbox/Gateway/Client.hs"
    , "src/Prodbox/Lifecycle/RegistryBackendWitness.hs"
    ]
  minterAllowedPaths =
    [ "src/Prodbox/ControlPlane/Observation/Internal.hs"
    , "src/Prodbox/Gateway/Client.hs"
    , "src/Prodbox/Lifecycle/RegistryBackendWitness.hs"
    ]
  internalModuleViolations =
    [ path
        ++ " imports or names the package-internal RoundTripWitness "
        ++ "representation; only Observation, the gateway state decoder, and the "
        ++ "registry storage-backend witness may cross that boundary."
    | internalModuleName `isInfixOf` contents
    , path `notElem` internalModuleAllowedPaths
    ]
  minterViolations =
    [ path
        ++ " mints a round-trip witness outside its definition, the gateway "
        ++ "state decoder, or the registry storage-backend witness; a witness "
        ++ "must be evidence that a conditional write landed, not an authored "
        ++ "value (bootstrap_readiness_doctrine.md § 2.3)."
    | minterName `isInfixOf` contents
    , path `notElem` minterAllowedPaths
    ]

-- | Sprint 5.30: a Tier-0 test fixture is a rendered value, not authored Dhall.
--
-- The rule is on the /write/, not on the mention: a test may name
-- @prodbox.dhall@ freely in a comment, in an expected error message, or as the
-- argument of the production path helper it is asserting about. What it may not
-- do is hand a @String@ of its own to `writeFile` at that path, because that is
-- the only shape a second hand-maintained encoder can take. Four such encoders
-- of a record with one decoder is how Sprint `1.80`'s type tightening broke
-- twenty integration cases while updating only one of them
-- (chaos_hardening_doctrine.md section 23).
--
-- @writeTier0AtPath@ is deliberately not banned: it is the production writer,
-- it renders through the canonical encoder, and tests of it are tests of the
-- encoder rather than rivals to it.
--
-- Bound, stated rather than implied: this is a line-local check, so binding the
-- path first and writing to the binding on a later line escapes it. The
-- structural guarantee is the one that carries the weight — a fixture is a
-- typed value, so a schema change is a compile error — and this rule only keeps
-- the shortest road back from being taken by accident.
--
-- The last two arms are positive anchors: if the fixture module stops routing
-- through `renderProjectConfigDhall`, or stops offering the reasoned raw escape,
-- the rule would pass vacuously.
tier0EncoderViolations :: [(FilePath, Maybe String)] -> [String]
tier0EncoderViolations = concatMap check
 where
  check (path, Nothing) =
    [path ++ " is missing; the Tier-0 encoder gate cannot run (Sprint 5.30)."]
  check (path, Just contents)
    | path == tier0FixtureModulePath = anchorViolations path contents
    | otherwise = writeSiteViolations path contents

  anchorViolations path contents =
    [ path
        ++ " no longer renders through `renderProjectConfigDhall`; the Tier-0"
        ++ " fixture encoder gate has nothing to protect, and a second"
        ++ " hand-maintained encoder becomes expressible again (Sprint 5.30)."
    | not ("renderProjectConfigDhall" `isInfixOf` contents)
    ]
      ++ [ path
             ++ " no longer defines `rawTier0Fixture`; the reasoned escape for a"
             ++ " fixture that cannot be a typed value is gone, which pushes such"
             ++ " fixtures back to unreasoned hand-authored text (Sprint 5.30)."
         | not ("rawTier0Fixture" `isInfixOf` contents)
         ]

  writeSiteViolations path contents =
    [ path
        ++ ":"
        ++ show lineNumber
        ++ " writes hand-authored text to a Tier-0 `"
        ++ tier0SiblingFileName
        ++ "`"
        ++ via
        ++ ". Write it with `Tier0Fixture.writeTier0Fixture`, whose value is"
        ++ " rendered by the one canonical encoder, so a schema change is a"
        ++ " compile error rather than a runtime decode failure (Sprint 5.30)."
    | (lineNumber, via) <- tier0WriteSiteLines contents
    ]

-- | Sprint 5.34: the Tier-0 write sites in one source file, as
-- @(line, how it was reached)@.
--
-- Sprint 5.30 matched a @writeFile@ and the sibling filename on __one__ source
-- line, and registered the escape in its own words: bind the path first, write
-- to the binding on a later line, and the rule sees nothing. That escape is now
-- closed. A binding whose right-hand side names the sibling file is collected,
-- and a later @writeFile@ applied to that name is a violation naming the
-- binding it travelled through.
--
-- __The bound moves from one line to one hop, and it is still stated rather
-- than implied.__ A path assembled across two bindings, passed through a
-- function parameter, or built from a list still escapes. That is deliberate:
-- widening further would trade a stated bound for an unstated one, which is the
-- reason Sprint `5.30` gave for not widening at all. The structural guarantee
-- carries the weight — a fixture is a typed value, so a schema change is a
-- compile error — and this rule keeps the two shortest roads back from being
-- taken by accident rather than the one.
tier0WriteSiteLines :: String -> [(Int, String)]
tier0WriteSiteLines contents =
  [ (lineNumber, reachedVia)
  | (lineNumber, line) <- numberedLines
  , "writeFile" `isInfixOf` line
  , not (rendersThroughCanonicalEncoder line)
  , reachedVia <-
      if tier0SiblingFileName `isInfixOf` line
        then [""]
        else
          [ " through the binding `" ++ name ++ "`"
          | Just name <- [writtenBindingName line]
          , nearestBindingNamesSibling name lineNumber
          ]
  ]
 where
  numberedLines = zip [1 :: Int ..] (lines contents)

  -- The rule's own message says "hand-authored text", and a write whose content
  -- comes from the canonical encoder is not that. Sprint 5.34's widened rule
  -- named such a site on its first run, and exempting it is the rule agreeing
  -- with what it claims rather than a carve-out: `renderProjectConfigDhall` IS
  -- the one canonical generator the message points the author at.
  --
  -- __Bound__: this reads the write line only. A rendered value bound on an
  -- earlier line and written on a later one is still reported, which is the
  -- fail-loud direction — the author is told to route it through
  -- `writeTier0Fixture`, which is where it belongs anyway.
  rendersThroughCanonicalEncoder line =
    any
      (`isInfixOf` line)
      ["renderProjectConfigDhall", "tier0FixtureText", "writeTier0Fixture"]

  -- The name in `writeFile <name>`, when the argument is a bare identifier.
  writtenBindingName line = case dropWhile (/= "writeFile") (words line) of
    (_ : argument : _) | isBindingName argument -> Just argument
    _ -> Nothing

  -- Does the nearest preceding binding of this name, __within the same
  -- top-level definition__, name the sibling file?
  --
  -- Both restrictions were arrived at by the rule reporting something untrue,
  -- and both are recorded rather than quietly folded in:
  --
  --   * /Nearest preceding/ rather than anywhere-in-file. The first draft
  --     collected every name ever bound to a sibling path in the module and
  --     flagged any `writeFile` of that name, making an unrelated
  --     @let path = tmpDir \<\/\> "config.dhall"@ a violation because a different
  --     case bound @path@ to the sibling.
  --   * /Same top-level definition/. Nearest-preceding alone still reached
  --     across definitions into a helper whose @tier0Path@ is a __parameter__,
  --     shadowing an earlier @let@ of that name in a different function.
  --
  -- Both are the unstated bound Sprint `5.30` declined to take, arrived at by
  -- accident. The bound that remains is stated: one hop, one definition.
  nearestBindingNamesSibling name lineNumber =
    case [ bindingLine
         | (bindingNumber, bindingLine) <- numberedLines
         , bindingNumber >= enclosingDefinitionStart lineNumber
         , bindingNumber < lineNumber
         , simpleBindingName bindingLine == Just name
         ] of
      [] -> False
      bindings -> maybe False (isInfixOf tier0SiblingFileName) (lastMaybe bindings)

  -- The first line of the top-level definition enclosing this line: the last
  -- line at or before it that starts in column 0 with an identifier character.
  enclosingDefinitionStart lineNumber =
    maybe
      1
      id
      ( lastMaybe
          [ candidateNumber
          | (candidateNumber, candidateLine) <- numberedLines
          , candidateNumber <= lineNumber
          , startsTopLevelDefinition candidateLine
          ]
      )

  startsTopLevelDefinition line = case line of
    (firstCharacter : _) -> isAlpha firstCharacter
    [] -> False

lastMaybe :: [value] -> Maybe value
lastMaybe = foldl (\_ value -> Just value) Nothing

isBindingName :: String -> Bool
isBindingName name = case name of
  [] -> False
  (firstCharacter : _) ->
    isAlpha firstCharacter
      && all
        (\character -> isAlphaNum character || character `elem` ("_'" :: String))
        name

-- | The bound name in a @  name = ...@ or @  let name = ...@ line, if the line
-- has that shape. 'Nothing' for anything else.
simpleBindingName :: String -> Maybe String
simpleBindingName line =
  case words (dropWhile isSpace line) of
    ("let" : name : "=" : _) | isBindingName name -> Just name
    (name : "=" : _) | isBindingName name -> Just name
    _ -> Nothing

tier0FixtureModulePath :: FilePath
tier0FixtureModulePath = "test/support/Tier0Fixture.hs"

tier0SiblingFileName :: String
tier0SiblingFileName = "prodbox.dhall"

checkTier0FixtureEncoder :: FilePath -> IO [String]
checkTier0FixtureEncoder repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  sources <-
    forM
      ( tier0FixtureModulePath
          : [ path
            | path <- repoPaths
            , "test/" `isPrefixOf` path
            , ".hs" `isSuffixOf` path
            , path /= tier0FixtureModulePath
            ]
      )
      ( \relativePath -> do
          let absolutePath = repoRoot </> relativePath
          exists <- doesFileExist absolutePath
          contents <- if exists then readFileStrict absolutePath else pure ""
          pure (relativePath, if exists then Just contents else Nothing)
      )
  pure (tier0EncoderViolations sources)

-- | Sprint 4.60: a server answers an accepted connection through
-- 'withResponseObligation', or not at all.
--
-- Negative space, the Sprint 2.10 / 2.41 pattern: the rule is that the raw
-- socket write is not in scope in a governed server module, and this check is
-- what makes it fail. A server holding `sendAll` can always reach the state
-- this sprint removed — accept, throw, close, say nothing — no matter what the
-- helper guarantees.
--
-- The last three arms are positive anchors. Without them the gate passes
-- vacuously the moment somebody deletes the thing it protects, which is the
-- failure mode Sprint 2.41 named when it added the same shape for
-- `withSupervisedWorkers`.
--
-- Deliberately not yet governed, each by named sprint rather than by omission:
-- the Bootstrap Broker (its own equivalent plus deadline and backpressure), the
-- gateway daemon, and the CliSuite fake servers. Client-side writers
-- (`Prodbox.Workload`, `Prodbox.Pulsar.Client`, request-writing tests) are out
-- of scope permanently — they send requests, not responses.
responseObligationViolations :: [(FilePath, Maybe String)] -> [String]
responseObligationViolations = concatMap check
 where
  check (path, Nothing) =
    [ path
        ++ " is missing; the response-obligation gate cannot run (Sprint 4.60)."
    ]
  check (path, Just contents)
    | path == responseObligationModulePath = helperAnchorViolations path contents
    | otherwise = rawWriteViolations path contents ++ adoptionViolations path contents

  helperAnchorViolations path contents =
    [ path
        ++ " no longer defines `"
        ++ anchor
        ++ "`; the response-obligation gate has nothing to protect (Sprint 4.60)."
    | anchor <- ["withResponseObligation", "mkResponseObligation"]
    , not (definesTopLevel anchor contents)
    ]
      ++ [ path
             ++ " no longer defines the closed `ResponseRefusal` type; a refusal"
             ++ " renderer stops being a total function and a new refusal kind"
             ++ " becomes a silent bare close (Sprint 4.60)."
         | not ("data ResponseRefusal" `isInfixOf` contents)
         ]

  -- The formatter wraps a long signature onto its own line, so anchoring on the
  -- literal `name ::` would make this gate fail the moment somebody reformats
  -- the module it protects. Match a top-level binding instead: the bare name on
  -- its own line (a wrapped signature) or the name in leading position.
  definesTopLevel name contents =
    any matchesLine (lines contents)
   where
    matchesLine sourceLine =
      sourceLine == name
        || (name ++ " ") `isPrefixOf` sourceLine

  rawWriteViolations path contents =
    [ path
        ++ " imports the raw socket write from `Network.Socket.ByteString`. An"
        ++ " accepted connection is answered through `withResponseObligation`"
        ++ " (Prodbox.Http.ResponseObligation), which carries a required refusal"
        ++ " renderer and catches a handler's synchronous exception into it; a"
        ++ " raw `sendAll` re-admits \"accepted a connection and answered"
        ++ " nothing\" (Sprint 4.60)."
    | sourceLine <- lines contents
    , "import " `isPrefixOf` dropWhile isSpace sourceLine
    , "Network.Socket.ByteString" `isInfixOf` sourceLine
    , any (`elem` rawSocketWriteNames) (tokenizeSource sourceLine)
        || "qualified" `elem` tokenizeSource sourceLine
    ]

  adoptionViolations path contents =
    [ path
        ++ " no longer names `withResponseObligation`; its accept path is"
        ++ " outside the response-obligation gate, which would then pass"
        ++ " vacuously (Sprint 4.60)."
    | not ("withResponseObligation" `isInfixOf` contents)
    ]

-- | The raw write names a governed server may not bring into scope. A qualified
-- import of the module is refused separately, because an alias reaches all of
-- them at once.
rawSocketWriteNames :: [String]
rawSocketWriteNames = ["sendAll", "send", "sendMany", "sendTo"]

responseObligationModulePath :: FilePath
responseObligationModulePath = "src/Prodbox/Http/ResponseObligation.hs"

-- | The servers this gate governs. Adding one is how a new accept loop opts in.
responseObligationGovernedServers :: [FilePath]
responseObligationGovernedServers =
  [ "src/Prodbox/ControlPlane/Runtime.hs"
  , "test/integration/FixtureServer.hs"
  ]

checkResponseObligation :: FilePath -> IO [String]
checkResponseObligation repoRoot = do
  sources <-
    forM (responseObligationModulePath : responseObligationGovernedServers) $ \relativePath -> do
      let absolutePath = repoRoot </> relativePath
      exists <- doesFileExist absolutePath
      contents <- if exists then readFileStrict absolutePath else pure ""
      pure (relativePath, if exists then Just contents else Nothing)
  pure (responseObligationViolations sources)

-- | Sprint 4.56: a 'DependencyAdmission' asserts that a graph-declared
-- dependency was observed ready, and a 'MutationAdmission' that every one of
-- them was, recently enough to act on. Both are worth something only while the
-- set of modules able to construct one is exactly the module that folds a ready
-- verdict into one.
dependencyAdmissionInternalSourceViolations :: (FilePath, String) -> [String]
dependencyAdmissionInternalSourceViolations (path, contents) =
  internalModuleViolations
 where
  internalModuleName = "Prodbox.Lifecycle.DependencyAdmission.Internal"
  internalModuleAllowedPaths =
    [ "src/Prodbox/Lifecycle/DependencyAdmission.hs"
    , "src/Prodbox/Lifecycle/DependencyAdmission/Internal.hs"
    , -- Sprint 4.64: the reconcile executor is the one place a run legitimately
      -- begins with no admissions, so it alone reaches `noAdmissions`. Adding
      -- it here is what lets the empty set leave the public API.
      "src/Prodbox/Lifecycle/AnchoredReconcile.hs"
    ]
  internalModuleViolations =
    [ path
        ++ " imports or names the package-internal DependencyAdmission "
        ++ "representation; an admission must be evidence that a readiness "
        ++ "barrier passed, not a value a mutating step constructed for itself "
        ++ "(Sprint 4.56)."
    | internalModuleName `isInfixOf` contents
    , path `notElem` internalModuleAllowedPaths
    ]

-- | Sprint 4.67: no control-plane producer states an HTTP status as a number.
--
-- Sprint 4.66 introduced this rule in a weaker form — a literal was permitted
-- so long as the closed set defined it — because the producers still answered a
-- raw @Int@ and a text rule was the only available gate. They now answer
-- 'Prodbox.Http.ReplyStatus.ReplyStatus', so the closed set is carried by the
-- type and this rule has a different job: it stops a new @Int@-typed reply seam
-- being opened beside the typed one. The original defect is worth restating,
-- because it is what an untyped seam re-enables — @httpReasonPhrase@ fell four
-- codes behind its producers and the control plane wrote
-- @HTTP\/1.1 403 Status@ on the wire.
--
-- __The bound, stated in the rule rather than left to the reader.__ It is a
-- text scan for reply-tuple and status-projection literals under one namespace.
-- It cannot see a status computed arithmetically, and it says nothing about a
-- status reaching the renderer from outside that namespace — a ring-2 gate
-- bounds a process, not a protocol
-- ([chaos_hardening_doctrine.md § 22](../../documents/engineering/chaos_hardening_doctrine.md)).
-- What it does cover is the shape every producer in the namespace actually
-- uses today, which is what let the gap open.
checkControlPlaneReplyStatusCoverage :: FilePath -> IO [String]
checkControlPlaneReplyStatusCoverage repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , "src/Prodbox/ControlPlane/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      ]
      ( \path -> do
          contents <- readFileStrict (repoRoot </> path)
          pure (controlPlaneReplyStatusViolations (path, contents))
      )

-- | Paths whose three-digit projection arms are not HTTP statuses.
--
-- Exactly one today. @CallerPrincipal@ encodes caller identities as @100@-@103@
-- through the same @-> NNN@ shape a status projection uses, and no text rule
-- can tell the two apart from one line. Naming the exemption is honest; a
-- cleverer matcher that happened to exclude it would be an unstated bound.
controlPlaneNonStatusCodePaths :: [FilePath]
controlPlaneNonStatusCodePaths = ["src/Prodbox/ControlPlane/CallerPrincipal.hs"]

controlPlaneReplyStatusViolations :: (FilePath, String) -> [String]
controlPlaneReplyStatusViolations (path, contents) =
  [ path
      ++ " emits the raw HTTP status literal "
      ++ code
      ++ " in a reply position. Control-plane producers answer "
      ++ "Prodbox.Http.ReplyStatus, so a status is a constructor and not a "
      ++ "number (Sprint 4.67). Add a constructor to ReplyStatus if the set "
      ++ "needs to grow; do not reintroduce an Int-typed reply seam."
  | path `notElem` controlPlaneNonStatusCodePaths
  , code <- emittedCodes
  ]
 where
  emittedCodes = dedupeStrings (concatMap statusLiteralsOnLine (lines contents))

  -- Two producer shapes, both measured from the namespace: a reply tuple
  -- `(NNN, body)` anywhere on the line, and a status projection arm ending
  -- `-> NNN`. Reading shapes rather than bare three-digit numbers is what keeps
  -- ordinary constants out; it is NOT enough to separate a status from a
  -- same-shaped non-status encoding, which is why
  -- 'controlPlaneNonStatusCodePaths' exists and is named rather than implied.
  statusLiteralsOnLine line =
    replyTupleLiterals line ++ projectionArmLiteral line

  -- The body after the comma must not itself start with a digit. Without that
  -- clause an IPv4 octet tuple matches: `(127, 0, 0, 1)` in
  -- `ControlPlane/LocalClient.hs` was flagged as HTTP status 127 by the first
  -- version of this rule, which is how the clause came to exist. The cost is a
  -- stated false negative — a reply whose body literal begins with a digit
  -- would be missed — and no producer in the namespace has one, because a reply
  -- body is a quoted ByteString or a function call.
  replyTupleLiterals line =
    [ digits
    | '(' : rest <- tails line
    , let (digits, remainder) = span isDigit rest
    , length digits == 3
    , "," `isPrefixOf` remainder
    , not (any isDigit (take 1 (dropWhile isSpace (drop 1 remainder))))
    ]

  projectionArmLiteral line =
    let trimmed = dropWhileEnd isSpace line
        digits = reverse (takeWhile isDigit (reverse trimmed))
     in [digits | length digits == 3, ("-> " ++ digits) `isSuffixOf` trimmed]

dedupeStrings :: [String] -> [String]
dedupeStrings = foldr (\value seen -> if value `elem` seen then seen else value : seen) []

dnsOwnerAuthorityInternalSourceViolations :: (FilePath, String) -> [String]
dnsOwnerAuthorityInternalSourceViolations (path, contents) =
  internalModuleViolations
 where
  internalModuleName = "Prodbox.Lifecycle.DnsRecord.Owner.Internal"
  internalModuleAllowedPaths =
    [ "src/Prodbox/Lifecycle/DnsRecord/Owner.hs"
    , "src/Prodbox/Lifecycle/DnsRecord/Owner/Internal.hs"
    ]
  internalModuleViolations =
    [ path
        ++ " imports or names the package-internal DnsOwnerAuthority "
        ++ "representation; a DNS ownership authority is minted only by "
        ++ "`dnsOwnerAuthorityForProcess` from the role and substrate the "
        ++ "process actually runs as, never constructed from an owner a caller "
        ++ "already had (Sprint 3.32)."
    | internalModuleName `isInfixOf` contents
    , path `notElem` internalModuleAllowedPaths
    ]

-- | Sprint 4.70: a target sink record may be rebuilt from the store by the
-- durable decoder, and by nothing else.
--
-- The two minters of a 'Prodbox.Lifecycle.TargetCommitIntent.TargetSinkRecord'
-- state different facts through one shape: @recordForIntent@ builds the record
-- a committed intent __decided__ to write, and @targetSinkRecordFromStore@
-- rebuilds what the store __says__ it holds. No type separates them, because
-- the arguments are identical — so the bound is a named path list rather than a
-- signature, and per
-- [chaos_hardening_doctrine.md § 22](../../documents/engineering/chaos_hardening_doctrine.md)
-- it bounds this process and not the protocol.
targetSinkRecordMinterViolations :: (FilePath, String) -> [String]
targetSinkRecordMinterViolations (path, contents) =
  [ path
      ++ " mints a TargetSinkRecord from raw fields outside the durable target"
      ++ " decoder. A record carries the owner nonce and fencing token that make"
      ++ " a write authoritative; it is either decided from a"
      ++ " PreparedTargetWritePermit or decoded from what the store reports, and"
      ++ " nothing else may assemble one (Sprint 4.70)."
  | minterName `isInfixOf` contents
  , path `notElem` minterAllowedPaths
  ]
 where
  minterName = "targetSinkRecordFromStore"
  minterAllowedPaths =
    [ "src/Prodbox/Lifecycle/TargetCommitIntent.hs"
    , "src/Prodbox/ControlPlane/TargetMaterialRecordCodec.hs"
    ]

targetSinkVersionInternalSourceViolations :: (FilePath, String) -> [String]
targetSinkVersionInternalSourceViolations (path, contents) =
  internalModuleViolations ++ minterViolations
 where
  internalModuleName = "Prodbox.Lifecycle.TargetSinkVersion.Internal"
  minterName = "targetSinkVersionFromStoreVersion"
  internalModuleAllowedPaths =
    [ "src/Prodbox/Lifecycle/TargetSinkVersion.hs"
    , "src/Prodbox/Lifecycle/TargetSinkVersion/Internal.hs"
    , "src/Prodbox/ControlPlane/TrustedTargetSink.hs"
    ]
  minterAllowedPaths =
    [ "src/Prodbox/Lifecycle/TargetSinkVersion/Internal.hs"
    , "src/Prodbox/ControlPlane/TrustedTargetSink.hs"
    ]
  internalModuleViolations =
    [ path
        ++ " imports or names the package-internal TargetSinkVersion "
        ++ "representation; only TargetSinkVersion and the target sink's Vault "
        ++ "observation decoder may cross that boundary."
    | internalModuleName `isInfixOf` contents
    , path `notElem` internalModuleAllowedPaths
    ]
  minterViolations =
    [ path
        ++ " mints a target sink expected version outside its definition or the "
        ++ "target sink's Vault observation decoder; an expected version must be "
        ++ "evidence of a store read, not an authored value."
    | minterName `isInfixOf` contents
    , path `notElem` minterAllowedPaths
    ]

verifyThinMainEntrypoint :: FilePath -> IO (Either String ())
verifyThinMainEntrypoint repoRoot = do
  let mainPath = repoRoot </> "app" </> "prodbox" </> "Main.hs"
  fileExists <- doesFileExist mainPath
  if not fileExists
    then pure (Left "Missing `app/prodbox/Main.hs`; the library-first entrypoint gate cannot run.")
    else do
      contents <- readFileStrict mainPath
      let normalizedLines =
            filter
              (not . null)
              (map trimLine (lines contents))
          allowedLines =
            [ "module Main (main) where"
            , "import Prodbox.App qualified as App"
            , "main :: IO ()"
            , "main = App.main"
            ]
      pure $
        if normalizedLines == allowedLines
          then Right ()
          else
            Left
              "library-first lint failed for `app/prodbox/Main.hs`: keep `Main.hs` thin (`main = Prodbox.App.main`) and move all logic into `src/`."

checkParserModuleImports :: FilePath -> IO (Maybe String)
checkParserModuleImports repoRoot = do
  let parserPath = repoRoot </> "test" </> "unit" </> "Parser.hs"
  fileExists <- doesFileExist parserPath
  if not fileExists
    then pure Nothing
    else do
      contents <- readFileStrict parserPath
      pure $
        if "typed-process" `isInfixOf` contents
          then Just "`test/unit/Parser.hs` must not import or mention `typed-process`."
          else Nothing

checkNestedCaseViolations :: FilePath -> IO [String]
checkNestedCaseViolations repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  concat
    <$> forM
      [ path
      | path <- repoPaths
      , isHaskellSourcePath path
      ]
      ( \relativePath -> do
          contents <- readFileStrict (repoRoot </> relativePath)
          pure (lambdaCaseViolations relativePath (lines contents))
      )

lambdaCaseViolations :: FilePath -> [String] -> [String]
lambdaCaseViolations relativePath sourceLines =
  [ relativePath
      ++ " line "
      ++ show lineNumber
      ++ " violates `Avoid case inside lambda body`; extract a named helper to satisfy `Refactor nested case`."
  | (lineNumber, lineText, maybeNextLine) <- withNextLines sourceLines
  , lambdaIntroducesCase lineText maybeNextLine
  ]

lambdaIntroducesCase :: String -> Maybe String -> Bool
lambdaIntroducesCase lineText maybeNextLine =
  ("\\" `isInfixOf` lineText)
    && ( ("-> case" `isInfixOf` lineText)
           || maybe False nextLineStartsLambdaBodyCase maybeNextLine
       )
 where
  currentIndent = leadingWhitespaceCount lineText
  nextLineStartsLambdaBodyCase nextLine =
    "->" `isInfixOf` lineText
      && leadingWhitespaceCount nextLine > currentIndent
      && startsWithCase (trimLeft nextLine)

startsWithCase :: String -> Bool
startsWithCase lineText =
  "case " `isPrefixOf` lineText

withNextLines :: [String] -> [(Int, String, Maybe String)]
withNextLines sourceLines =
  [ (lineNumber, lineText, nextMeaningfulLine remaining)
  | (lineNumber, lineText, remaining) <- zip3 [1 :: Int ..] sourceLines (tails sourceLines)
  ]

nextMeaningfulLine :: [String] -> Maybe String
nextMeaningfulLine [] = Nothing
nextMeaningfulLine (_current : remaining) =
  case dropWhile (null . trimLeft) remaining of
    nextLine : _ -> Just nextLine
    [] -> Nothing

leadingWhitespaceCount :: String -> Int
leadingWhitespaceCount = length . takeWhile (== ' ')

isHaskellSourcePath :: FilePath -> Bool
isHaskellSourcePath path =
  (".hs" `isSuffixOf` path)
    && any (`isPrefixOf` path) ["app/", "src/", "test/"]

-- | Sprint 4.85 (pure). The validation-harness namespace boundary.
--
-- @Prodbox.Test.*@ is the validation harness: fixtures, fake interpreters, and
-- the harness's own cleanup composition. It lives under @src\/@ because the
-- harness ships in the binary, not because it is supported production
-- composition — and the distinction was previously only a convention.
--
-- It stopped being one. @Prodbox.Lifecycle.Dns01Challenge@ — a lifecycle
-- module, not a harness module — imported @Prodbox.Test.ManagedCleanupPlan@ to
-- express its cleanup edge, so a production teardown obligation was typed in a
-- shape the harness owned. This gate makes that direction non-constructible:
-- only the harness itself, and the harness entrypoints that are its clients,
-- may import the harness namespace.
--
-- 'validationHarnessClientModules' is the exact allowlist. It is deliberately
-- small and enumerated rather than pattern-matched, so widening it is a visible
-- edit rather than a naming accident. Sprint @5.36@ removes @TestRunner@'s
-- entries when it migrates the validation client onto the lifecycle-owned
-- kernel.
validationHarnessClientModules :: [FilePath]
validationHarnessClientModules =
  [ "src/Prodbox/TestRunner.hs"
  , "src/Prodbox/TestValidation.hs"
  ]

testNamespaceImportViolations :: FilePath -> String -> [String]
testNamespaceImportViolations relativePath contents =
  [ relativePath
      ++ " imports the validation-harness namespace ("
      ++ importedModule line
      ++ "). Only the harness itself and its enumerated clients may; express "
      ++ "the obligation in lifecycle-owned types instead "
      ++ "(lifecycle_reconciliation_doctrine.md § 3.3)."
  | line <- lines contents
  , "import Prodbox.Test." `isPrefixOf` line
  ]
 where
  importedModule line = case drop 1 (words line) of
    moduleName : _ -> moduleName
    [] -> "Prodbox.Test.*"

checkTestNamespaceBoundary :: FilePath -> IO [String]
checkTestNamespaceBoundary repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , "src/Prodbox/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , not ("src/Prodbox/Test/" `isPrefixOf` path)
      , path `notElem` validationHarnessClientModules
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \relativePath -> do
          contents <- readFileStrict (repoRoot </> relativePath)
          pure (testNamespaceImportViolations relativePath contents)
      )

checkDaemonRuntimeImports :: FilePath -> IO [String]
checkDaemonRuntimeImports repoRoot = do
  let daemonPaths =
        [ repoRoot </> "src" </> "Prodbox" </> "Gateway" </> "Daemon.hs"
        , repoRoot </> "src" </> "Prodbox" </> "Workload.hs"
        ]
  fmap concat $
    forM daemonPaths $ \path -> do
      contents <- readFileStrict path
      let importViolations =
            [ path ++ " must not import `System.Posix.Process`."
            | "System.Posix.Process" `isInfixOf` contents
            ]
          forkViolations =
            [ path ++ " must not call `forkProcess`."
            | "forkProcess" `isInfixOf` contents
            ]
          rawThreadViolations =
            [ path ++ " must not call `forkIO`."
            | "forkIO" `isInfixOf` contents
            ]
          unsafeViolations =
            [ path ++ " must not call `unsafePerformIO`."
            | "unsafePerformIO" `isInfixOf` contents
            ]
          moduleLevelIoRefViolations =
            [ path ++ " must not define a module-level `IORef`."
            | "unsafePerformIO" `isInfixOf` contents
                && "IORef" `isInfixOf` contents
            ]
          sessionViolations =
            [ path ++ " must not call `setsid`."
            | "setsid" `isInfixOf` contents
            ]
          readinessSignalViolations =
            [ path
                ++ " must use HTTP `/readyz` as the only readiness signal; filesystem readiness markers and `sd_notify` are forbidden."
            | any
                (`isInfixOf` contents)
                [ "sd_notify"
                , "READY=1"
                , "readiness_marker"
                , "readinessMarker"
                , "ready_file"
                , "readyFile"
                ]
            ]
          mutableMetricsViolations =
            [ path
                ++ " must keep daemon metrics behind `envMetrics`; module-local `IORef`/`MVar` counters are forbidden."
            | "metrics" `isInfixOf` contents || "MetricsRegistry" `isInfixOf` contents
            , any (`elem` tokenizeSource contents) ["newIORef", "newMVar"]
            ]
          asyncPrimitiveViolations =
            [ path
                ++ " must use only the daemon structured-concurrency primitive set: `withAsync`, `race`, `concurrently`, and `replicateConcurrently`."
            | any
                (`elem` tokenizeSource contents)
                [ "async"
                , "wait"
                , "waitAny"
                , "waitEither"
                , "mapConcurrently"
                , "mapConcurrently_"
                ]
            ]
          inlineLogObjectViolations =
            [ path
                ++ " must route structured log fields through `field`; inline `Aeson.object` / `Aeson.fromList` log payloads are forbidden."
            | any daemonLogLineBuildsInlineObject (lines contents)
            ]
      pure
        ( importViolations
            ++ forkViolations
            ++ rawThreadViolations
            ++ unsafeViolations
            ++ moduleLevelIoRefViolations
            ++ sessionViolations
            ++ readinessSignalViolations
            ++ mutableMetricsViolations
            ++ asyncPrimitiveViolations
            ++ inlineLogObjectViolations
        )

daemonLogLineBuildsInlineObject :: String -> Bool
daemonLogLineBuildsInlineObject lineText =
  any (`isInfixOf` lineText) ["logDebug", "logInfo", "logWarn", "logError", "logStructured"]
    && any (`isInfixOf` lineText) ["Aeson.object", "Aeson.fromList", "object ["]

checkDaemonHookContract :: FilePath -> IO [String]
checkDaemonHookContract repoRoot = do
  let path = repoRoot </> "src" </> "Prodbox" </> "Gateway" </> "Daemon.hs"
  contents <- readFileStrict path
  pure
    ( missingHookSurfaceViolations path contents
        ++ [ path
               ++ " must construct the production daemon `Env` with literal `noopDaemonHooks`."
           | not (any ("envHooks = noopDaemonHooks" `isInfixOf`) (lines contents))
           ]
        ++ [ path
               ++ " must read daemon hook fields only through the injected `envHooks env` value."
           | any daemonHookReadBypassesEnv (lines contents)
           ]
    )

missingHookSurfaceViolations :: FilePath -> String -> [String]
missingHookSurfaceViolations path contents =
  [ path ++ " must define daemon hook field `" ++ hookName ++ "`."
  | hookName <-
      [ "envAfterPeerEventCommit"
      , "envBeforeOrdersAdoption"
      , "envOnPeerConnectionEstablished"
      ]
  , hookName `notElem` tokenizeSource contents
  ]

daemonHookReadBypassesEnv :: String -> Bool
daemonHookReadBypassesEnv lineText =
  let trimmedLine = trimLine lineText
   in any (`isInfixOf` trimmedLine) daemonHookNames
        && not (any (`isInfixOf` trimmedLine) allowedHookContexts)
 where
  daemonHookNames =
    [ "envAfterPeerEventCommit"
    , "envBeforeOrdersAdoption"
    , "envOnPeerConnectionEstablished"
    ]
  allowedHookContexts =
    [ "envAfterPeerEventCommit ::"
    , "envBeforeOrdersAdoption ::"
    , "envOnPeerConnectionEstablished ::"
    , "envAfterPeerEventCommit ="
    , "envBeforeOrdersAdoption ="
    , "envOnPeerConnectionEstablished ="
    , "envAfterPeerEventCommit (envHooks env)"
    , "envBeforeOrdersAdoption (envHooks env)"
    , "envOnPeerConnectionEstablished (envHooks env)"
    ]

checkDaemonLifecycleTestBoundaries :: FilePath -> IO [String]
checkDaemonLifecycleTestBoundaries repoRoot = do
  let path = repoRoot </> "test" </> "daemon-lifecycle" </> "Main.hs"
  fileExists <- doesFileExist path
  if not fileExists
    then pure []
    else do
      contents <- readFileStrict path
      pure
        ( [ path
              ++ " must not use raw `threadDelay`; readiness waits must route through shared retry or hooks."
          | "threadDelay" `elem` tokenizeSource contents
          ]
            ++ [ path
                   ++ " must not call raw `terminateProcess`; tests must send the daemon's graceful shutdown signal first."
               | "terminateProcess" `elem` tokenizeSource contents
               ]
        )

checkSubprocessBoundaries :: FilePath -> IO [String]
checkSubprocessBoundaries repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  concat
    <$> forM
      [ path
      | path <- repoPaths
      , "src/Prodbox/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/Subprocess.hs"
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \relativePath -> do
          contents <- readFileStrict (repoRoot </> relativePath)
          let tokens = tokenizeSource (stripStringLiterals contents)
              hasSystemProcessImport = "import System.Process" `isInfixOf` contents
              forbiddenTokens =
                [ token
                | token <-
                    [ "callProcess"
                    , "readCreateProcess"
                    , "readCreateProcessWithExitCode"
                    , "createProcess"
                    , "proc"
                    , "shell"
                    ]
                , token `elem` tokens
                ]
          pure $
            [ relativePath ++ " must route subprocess creation through `src/Prodbox/Subprocess.hs`."
            | hasSystemProcessImport || not (null forbiddenTokens)
            ]
      )

stripStringLiterals :: String -> String
stripStringLiterals = go False False
 where
  go _ _ [] = []
  go inString escaped (character : remaining)
    | inString && escaped = ' ' : go True False remaining
    | inString && character == '\\' = ' ' : go True True remaining
    | inString && character == '"' = ' ' : go False False remaining
    | inString = ' ' : go True False remaining
    | character == '"' = ' ' : go True False remaining
    | otherwise = character : go False False remaining

checkErrorBoundaryViolations :: FilePath -> IO [String]
checkErrorBoundaryViolations repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  concat
    <$> forM
      [ path
      | path <- repoPaths
      , "src/Prodbox/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/CLI/Output.hs"
      , path /= "src/Prodbox/Gateway/Logging.hs"
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \relativePath -> do
          contents <- readFileStrict (repoRoot </> relativePath)
          let tokens = tokenizeSource contents
              directStderrWrites =
                [ "hPutStr stderr"
                , "hPutStrLn stderr"
                , "TextIO.hPutStrLn stderr"
                , "Text.IO.hPutStrLn stderr"
                ]
          pure $
            [ relativePath
                ++ " must route terminal output and error rendering through `src/Prodbox/CLI/Output.hs`."
            | any (`elem` tokens) ["print", "exitFailure", "putStr", "putStrLn"]
                || any (`isInfixOf` contents) directStderrWrites
            ]
      )

-- | Sprint 1.28: refuse `lookupEnv` / `getEnv` / `getEnvironment` reads on
-- supported config-loading paths, per
-- @documents/engineering/config_doctrine.md § 10. Forbidden surfaces@. The
-- Dhall file passed via `--config <path>` is the sole source for binary
-- configuration; no `PRODBOX_*` env-var precedence rule survives. Scope is
-- the modules called out in Phase 1 Sprint 1.28 deliverables plus
-- `src/Prodbox/Workload.hs`, whose `PRODBOX_*` env-var ladder was deleted in
-- Sprint 3.15, and `src/Prodbox/PublicEdge.hs` (Sprint 7.13), whose
-- `PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID` read was deleted and which now
-- fails this lint on any reintroduced config read.
checkEnvVarConfigReads :: FilePath -> IO [String]
checkEnvVarConfigReads repoRoot =
  concat
    <$> forM
      scopedPaths
      ( \relativePath -> do
          let fullPath = repoRoot </> relativePath
          fileExists <- doesFileExist fullPath
          if not fileExists
            then pure [scopedPathMissingViolation "checkEnvVarConfigReads" relativePath]
            else do
              contents <- readFileStrict fullPath
              let tokens = tokenizeSource (stripStringLiterals contents)
                  forbiddenTokens =
                    [ token
                    | token <- ["lookupEnv", "getEnv", "getEnvironment"]
                    , token `elem` tokens
                    ]
              pure $
                [ relativePath
                    ++ " must not read configuration from environment variables. "
                    ++ "See `documents/engineering/config_doctrine.md` § 10."
                | not (null forbiddenTokens)
                ]
      )
 where
  scopedPaths =
    [ "src/Prodbox/Settings.hs"
    , "src/Prodbox/Gateway/Settings.hs"
    , "src/Prodbox/Gateway.hs"
    , "src/Prodbox/Workload.hs"
    , -- Sprint 7.13: the public-edge config / route-catalog module. Its
      -- AWS-substrate hosted-zone id is sourced from settings
      -- (@aws_substrate.hosted_zone_id@) and the live aws-eks-subzone
      -- Pulumi output, never from a @PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID@
      -- env read. Scoping it here keeps that env read from reappearing.
      "src/Prodbox/PublicEdge.hs"
    ]

-- | First index at which @needle@ occurs in @haystack@, or 'Nothing'.
findInfixIndex :: String -> String -> Maybe Int
findInfixIndex needle haystack =
  go 0 (tails haystack)
 where
  go _ [] = Nothing
  go idx (candidate : rest)
    | needle `isPrefixOf` candidate = Just idx
    | otherwise = go (idx + 1) rest

-- | Sprint 7.12: substrate equivalence as a structural invariant. The home
-- substrate and the AWS substrate stand up the same SHARED platform
-- components (Envoy Gateway, cert-manager, Harbor, MinIO, the Percona
-- PostgreSQL operator); each such component's chart version and container
-- image must be pinned ONCE, in 'Prodbox.ContainerImage', and consumed by
-- both installers. Re-pinning a shared component's chart version / image on a
-- per-substrate branch (e.g. a literal @"v1.4.4"@ in the AWS installer that
-- can drift from the home installer's @"v1.7.2"@ — audit C79) is forbidden.
--
-- The genuinely substrate-specific LOWER layer is legitimately per-substrate
-- and is NOT flagged: the AWS Load Balancer Controller image / chart on AWS,
-- MetalLB + FRR on home, and the EKS node-local registry proxy
-- (containerd-mirror) all pin their own versions because there is no
-- home/AWS counterpart to keep in lockstep.
checkSubstrateImagePinning :: FilePath -> IO [String]
checkSubstrateImagePinning repoRoot =
  concat
    <$> forM
      substrateInstallerPaths
      ( \relativePath -> do
          let fullPath = repoRoot </> relativePath
          fileExists <- doesFileExist fullPath
          if not fileExists
            then pure []
            else do
              contents <- readFileStrict fullPath
              pure (substrateImagePinningViolations relativePath contents)
      )

-- | The installer modules scanned by 'checkSubstrateImagePinning'. The
-- substrate-specific platform install paths plus the shared chart-platform
-- module — the only places a chart version / image pin could be re-bound on a
-- per-substrate branch.
substrateInstallerPaths :: [FilePath]
substrateInstallerPaths =
  [ "src/Prodbox/Lib/AwsSubstratePlatform.hs"
  , "src/Prodbox/CLI/Rke2.hs"
  , "src/Prodbox/Lib/ChartPlatform.hs"
  ]

-- | The SHARED platform components whose chart version / image must be pinned
-- once in 'Prodbox.ContainerImage'. Matched (case-insensitively) against a
-- binding's identifier; a binding whose name contains one of these tokens and
-- @ChartVersion@ (or an image tag) but whose right-hand side is a literal
-- version string rather than a @ContainerImage.@ reference is a violation.
sharedComponentNameTokens :: [String]
sharedComponentNameTokens =
  [ "envoygateway"
  , "envoyproxy"
  , "certmanager"
  , "harbor"
  , "minio"
  , "postgresoperator"
  , "percona"
  ]

-- | The LOWER-layer (legitimately per-substrate) component name tokens. A
-- binding whose identifier contains one of these is exempt even if it carries
-- a literal version — these have no cross-substrate counterpart to keep in
-- lockstep.
lowerLayerNameTokens :: [String]
lowerLayerNameTokens =
  [ "loadbalancercontroller"
  , "metallb"
  , "frr"
  , "containerd"
  , "mirror"
  ]

-- | Sprint 7.12 (pure). Emit a violation for each shared-component
-- chart-version / image binding in @contents@ whose right-hand side is a
-- literal version string instead of a 'Prodbox.ContainerImage' reference.
-- Pure so the unit suite can pin the fires-on-offending-input contract (a
-- reintroduced per-substrate Envoy pin) and the passes-on-current-tree
-- contract.
--
-- Detection is per definition line of the form @ident = rhs@: the binding is
-- in scope when its identifier contains a 'sharedComponentNameTokens' token,
-- @ChartVersion@ (or an image-tag pin), and NOT a 'lowerLayerNameTokens'
-- token; it is a violation when the right-hand side carries a version-like
-- string literal and does not reference @ContainerImage.@.
substrateImagePinningViolations :: FilePath -> String -> [String]
substrateImagePinningViolations relativePath contents =
  [ relativePath
      ++ ": shared platform component `"
      ++ bindingName
      ++ "` re-pins a chart version / image with the literal `"
      ++ offendingLiteral
      ++ "`. Source it from the single `Prodbox.ContainerImage` pin "
      ++ "(e.g. `ContainerImage.envoyGatewayChartVersion` / "
      ++ "`ContainerImage.certManagerChartVersion`) instead of re-pinning "
      ++ "per substrate. See `DEVELOPMENT_PLAN/substrates.md` (substrate "
      ++ "equivalence) and `documents/engineering/helm_chart_platform_doctrine.md`."
  | rawLine <- lines contents
  , let codeLine = dropLineCommentTail rawLine
  , Just (bindingName, rhs) <- [splitDefinitionLine codeLine]
  , isSharedComponentBinding bindingName
  , not ("ContainerImage." `isInfixOf` rhs)
  , offendingLiteral <- take 1 (filter looksLikeVersionLiteral (extractStringLiterals rhs))
  ]
 where
  dropLineCommentTail line =
    case findInfixIndex "--" line of
      Just idx -> take idx line
      Nothing -> line

-- | Split a top-level definition line @ident = rhs@ into its binding name and
-- right-hand side. Only fires on a binding whose name starts in column 0
-- (a top-level definition) so indented record fields / @where@ helpers are
-- not misread as bindings.
splitDefinitionLine :: String -> Maybe (String, String)
splitDefinitionLine line =
  case line of
    [] -> Nothing
    (c : _)
      | c == ' ' || c == '\t' -> Nothing
      | otherwise ->
          case break (== '=') line of
            (lhs, '=' : rhs) ->
              case words lhs of
                [identifier] -> Just (identifier, rhs)
                _ -> Nothing
            _ -> Nothing

-- | A binding identifier names a SHARED platform component's chart version or
-- image pin (and is not a lower-layer, legitimately per-substrate binding).
isSharedComponentBinding :: String -> Bool
isSharedComponentBinding identifier =
  any (`isInfixOf` lowered) sharedComponentNameTokens
    && ("chartversion" `isInfixOf` lowered || "image" `isInfixOf` lowered || "tag" `isInfixOf` lowered)
    && not (any (`isInfixOf` lowered) lowerLayerNameTokens)
 where
  lowered = map toLower identifier

-- | A string literal that looks like a pinned image / chart version: a
-- leading @v@ followed by a digit (@v1.7.2@), a leading digit (@5.4.0@,
-- @2.9.0@), or an Envoy-style @distroless-v...@ tag. Plain words ("jetstack",
-- "cert-manager") are not flagged.
looksLikeVersionLiteral :: String -> Bool
looksLikeVersionLiteral literal =
  case literal of
    ('v' : d : _) -> isDigit d
    (d : _) | isDigit d -> True
    _ -> "distroless-v" `isInfixOf` literal

-- | Sprint 1.30: refuse hand-built `ServiceError` values that pin a literal
-- `True` / `False` retryable Bool at a call site. Per
-- @documents/engineering/haskell_code_guide.md@ → "Target shape:
-- `ServiceError` classified by constructor", retryability is a total
-- function of the classified constructor, decided once at the single
-- subprocess boundary (`classifyServiceError` in
-- `src/Prodbox/Service.hs`), never asserted by the caller. The
-- post-Sprint-1.30 `ServiceError` sum no longer carries a `retryable`
-- field, so any `serviceErrorRetryable = True/False` field assignment or
-- positional `ServiceError <…> True/False` construction is by definition
-- a regression that re-introduces a hand-set retryable Bool.
--
-- The scan is intentionally narrow:
--
--   * Only Haskell `.hs` files under `src/` and `app/`.
--   * String literals are stripped (a comment or message that merely
--     mentions the pattern is allowed).
--   * `src/Prodbox/Service.hs` is excluded — it is the classifier
--     boundary that legitimately owns `ServiceError` construction.
--   * `src/Prodbox/CheckCode.hs` is excluded — its own diagnostic text
--     names the very tokens it scans for.
--   * `test/` is excluded so the unit tests can pin the lint's
--     fires-on-offending-input contract with synthetic offenders.
-- | Sprint 4.26: the destructive command-dispatch constructors that carry
-- a @PlanOptions@ / @NukeOptions@ argument, paired with the 1-based
-- argument position of that options field. A destructive arm that binds
-- this field to a @_@ wildcard silently drops @--dry-run@ / @--plan-file@
-- (the historical @rke2 delete --dry-run@ SILENTLY MUTATES bug, where
-- @Rke2Delete flags _planOptions@ discarded the options). Exposed for
-- unit tests; consumed by 'planOptionsHonoredViolations'.
--
-- @Rke2Delete@ is @Rke2Delete Rke2DeleteFlags PlanOptions@ → the options
-- field is the 2nd argument. @NativeNuke@ is @NativeNuke NukeOptions@ →
-- 1st argument. Both must be threaded into 'runPlanWithOptions' (or read,
-- for @NukeOptions@), never wildcarded away.
destructivePlanOptionsArms :: [(String, Int)]
destructivePlanOptionsArms =
  [ ("Rke2Delete", 2)
  , ("NativeNuke", 1)
  , -- Sprint 0.28: the seven destructive `PlanOptions`-carrying constructors
    -- that dispatched outside this table. The position is the constructor's
    -- 1-based options argument, read from its declaration in
    -- `src/Prodbox/CLI/Command.hs`.
    ("PulumiEksDestroy", 2)
  , ("PulumiTestDestroy", 2)
  , ("PulumiAwsSubzoneDestroy", 2)
  , ("PulumiAwsSesDestroy", 2)
  , ("ChartsDelete", 4)
  , ("UsersRevoke", 3)
  , ("AwsTeardown", 1)
  ]

-- | Sprint 0.28 (pure). The @(path, constructor)@ pairs where a wildcard
-- options binder is correct, with the reason each is correct.
--
-- The lint's subject is a *dispatch* arm — one that runs the command and must
-- therefore thread @--dry-run@ / @--plan-file@ into 'runPlanWithOptions'. A
-- *projection* arm maps the same constructor to something else entirely and has
-- no options to honour. Widening the region in Sprint 0.28 surfaced exactly one
-- such arm, and it is exempted by named pair rather than by dropping the
-- constructor or narrowing the region back — the shape Sprint 4.66 used when its
-- own gate's first run produced two false positives.
--
-- A bare constructor exemption would be wrong: it would also excuse the real
-- dispatch site. The pair is the unit because the pair is what is safe.
planOptionsProjectionExemptions :: [(FilePath, String, String)]
planOptionsProjectionExemptions =
  [
    ( "src/Prodbox/Native.hs"
    , "AwsTeardown"
    , "commandPrerequisites is a pure projection from a command to its "
        ++ "PrerequisiteIds; it does not dispatch, so it has no PlanOptions to "
        ++ "honour. The dispatching arm is applyAwsTeardown in "
        ++ "src/Prodbox/Aws.hs, which binds and threads them and is inside "
        ++ "this gate's region."
    )
  ]

-- | Sprint 4.26 (pure): given a scanned file's relative path and its
-- contents, emit a violation for any destructive dispatch arm
-- ('destructivePlanOptionsArms') that binds its @PlanOptions@ /
-- @NukeOptions@ field to a @_@-prefixed wildcard, so a future destructive
-- command cannot silently drop @--dry-run@ / @--plan-file@.
--
-- Detection is tokenization-based: the arm appears in the source as the
-- constructor token followed by its binder tokens (e.g.
-- @Rke2Delete flags _planOptions@ tokenizes to
-- @["Rke2Delete", "flags", "_planOptions"]@). A wildcard binder is a token
-- that is exactly @_@ or begins with @_@. The check fires when the binder
-- at the constructor's options-argument position is such a wildcard. The
-- lint's own occurrences are excluded by the path filter in
-- 'checkPlanOptionsHonored'.
planOptionsHonoredViolations :: FilePath -> String -> [String]
planOptionsHonoredViolations relativePath contents =
  [ relativePath
      ++ " destructive dispatch arm `"
      ++ constructorName
      ++ "` binds its PlanOptions/NukeOptions field to a `_` wildcard ("
      ++ wildcardBinder
      ++ "), silently dropping --dry-run / --plan-file. Thread the options "
      ++ "into runPlanWithOptions (or read NukeOptions) instead. See "
      ++ "lifecycle_reconciliation_doctrine.md § 3.1."
  | (constructorName, optionsPosition) <- destructivePlanOptionsArms
  , (relativePath, constructorName) `notElem` exemptPairs
  , wildcardBinder <- wildcardBindersAt constructorName optionsPosition
  ]
 where
  exemptPairs =
    [ (path, constructorName)
    | (path, constructorName, _reason) <- planOptionsProjectionExemptions
    ]
  tokens = tokenizeSource (stripStringLiterals contents)
  -- For each occurrence of @constructorName@ in the token stream, the
  -- binder at @optionsPosition@ (1-based, relative to the constructor)
  -- is @drop optionsPosition@ of the tail starting at the constructor.
  wildcardBindersAt constructorName optionsPosition =
    [ binder
    | suffix <- tails tokens
    , (constructorToken : argTokens) <- [suffix]
    , constructorToken == constructorName
    , binder <- take 1 (drop (optionsPosition - 1) argTokens)
    , isWildcardBinder binder
    ]
  isWildcardBinder binder = case binder of
    "" -> False
    ('_' : _) -> True
    _ -> False

-- | Sprint 4.26: scan the destructive command-dispatch modules and fail
-- when a destructive arm wildcards its @PlanOptions@ / @NukeOptions@ field
-- (per 'planOptionsHonoredViolations'). The scope is the dispatch modules
-- that pattern-match the destructive constructors; @CheckCode.hs@ is
-- excluded so its own constructor-name literals do not self-trigger.
checkPlanOptionsHonored :: FilePath -> IO [String]
checkPlanOptionsHonored repoRoot =
  concat
    <$> forM
      scopedPaths
      ( \relativePath -> do
          let fullPath = repoRoot </> relativePath
          fileExists <- doesFileExist fullPath
          if not fileExists
            then pure [scopedPathMissingViolation "checkPlanOptionsHonored" relativePath]
            else do
              contents <- readFileStrict fullPath
              pure (planOptionsHonoredViolations relativePath contents)
      )
 where
  -- Sprint 0.28 widened the region. It named three files while seven
  -- destructive `PlanOptions`-carrying constructors dispatched elsewhere; the
  -- CLI modules that own them are now scanned too.
  scopedPaths =
    [ "src/Prodbox/CLI/Rke2.hs"
    , "src/Prodbox/CLI/Nuke.hs"
    , "src/Prodbox/CLI/Pulumi.hs"
    , "src/Prodbox/CLI/Charts.hs"
    , "src/Prodbox/CLI/Users.hs"
    , "src/Prodbox/Aws.hs"
    , "src/Prodbox/Native.hs"
    ]

checkServiceErrorRetryableLiteral :: FilePath -> IO [String]
checkServiceErrorRetryableLiteral repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let scanPath path =
        (".hs" `isSuffixOf` path)
          && any (`isPrefixOf` path) ["src/", "app/"]
          && path /= "src/Prodbox/Service.hs"
          && path /= forbidLintSelfPath
  fmap concat $
    forM
      [path | path <- repoPaths, scanPath path]
      ( \relativePath -> do
          let absolutePath = repoRoot </> relativePath
          isFile <- doesFileExist absolutePath
          if not isFile
            then pure []
            else do
              contents <- readFileStrict absolutePath
              pure (serviceErrorRetryableLiteralViolations relativePath contents)
      )

-- | Pure half of 'checkServiceErrorRetryableLiteral'. Detect a hand-set
-- retryable Bool on a `ServiceError`: either the record-field form
-- (`serviceErrorRetryable` token immediately followed by a `True`/`False`
-- literal) or the positional form (`ServiceError` token followed by a
-- bare `True`/`False` literal within a short token window, after string
-- literals are stripped). Exposed for unit tests.
serviceErrorRetryableLiteralViolations :: FilePath -> String -> [String]
serviceErrorRetryableLiteralViolations relativePath contents =
  [ relativePath
      ++ " constructs a `ServiceError` with a literal retryable Bool; "
      ++ "retryability is derived from the classified constructor at the "
      ++ "single subprocess boundary (`classifyServiceError`), never pinned "
      ++ "by a caller (haskell_code_guide.md → ServiceError classification)."
  | serviceErrorRetryableLiteralPresent (tokenizeSource (stripStringLiterals contents))
  ]

-- | True when the token stream pins a literal retryable Bool onto a
-- `ServiceError`. After 'tokenizeSource' collapses `=` to whitespace, the
-- record-field form `serviceErrorRetryable = True` becomes the adjacent
-- pair @["serviceErrorRetryable", "True"]@, and the positional form
-- `ServiceError "msg" True` (string literal stripped) becomes
-- @["ServiceError", "True"]@.
serviceErrorRetryableLiteralPresent :: [String] -> Bool
serviceErrorRetryableLiteralPresent tokens =
  fieldFormPresent || positionalFormPresent
 where
  boolLiteral token = token == "True" || token == "False"
  fieldFormPresent =
    any
      (\(token, next) -> token == "serviceErrorRetryable" && boolLiteral next)
      (zip tokens (drop 1 tokens))
  -- The positional ServiceError <…> True/False form: a `ServiceError`
  -- token with a bare Bool literal within the next few tokens and no
  -- intervening constructor that would re-open a fresh value.
  positionalFormPresent = go tokens
  go [] = False
  go ("ServiceError" : rest) = boolWithinWindow (take serviceErrorWindow rest) || go rest
  go (_ : rest) = go rest
  boolWithinWindow window =
    any boolLiteral (takeWhile (not . opensNestedValue) window)
  opensNestedValue token =
    token `elem` ["ServiceError", "MinIOError", "RedisError", "PgError"]

serviceErrorWindow :: Int
serviceErrorWindow = 4

-- | Sprint 1.57: scan production Haskell modules for retry classifiers that
-- carry their own substring table instead of delegating to the shared
-- constructor-owned base in 'Prodbox.Service'. Sprint 7.32 removed the final
-- EKS allowance, so every production classifier is now checked uniformly.
checkInlineRetrySubstringLists :: FilePath -> IO [String]
checkInlineRetrySubstringLists repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  fmap concat $
    forM
      [ path
      | path <- repoPaths
      , ".hs" `isSuffixOf` path
      , any (`isPrefixOf` path) ["src/", "app/"]
      , path /= "src/Prodbox/Service.hs"
      , path /= forbidLintSelfPath
      ]
      ( \relativePath -> do
          contents <- readFileStrict (repoRoot </> relativePath)
          pure (inlineRetrySubstringListViolations relativePath contents)
      )

-- | Pure half of 'checkInlineRetrySubstringLists'. Any @isRetryable…@
-- definition that performs its own @isInfixOf@ match is an inline classifier;
-- operation-specific extensions passed to 'isRetryableTransientFailure' do
-- not need a matcher and therefore pass.
inlineRetrySubstringListViolations :: FilePath -> String -> [String]
inlineRetrySubstringListViolations relativePath contents =
  [ relativePath
      ++ " defines inline retry substrings in `"
      ++ classifierName
      ++ "`; delegate common transient classes to "
      ++ "`Prodbox.Service.isRetryableTransientFailure` and pass only "
      ++ "operation-specific extensions. See bootstrap_readiness_doctrine.md §4."
  | (classifierName, classifierBody) <- topLevelRetryClassifierBodies contents
  , classifierUsesInlineSubstringList classifierBody
  ]

classifierUsesInlineSubstringList :: String -> Bool
classifierUsesInlineSubstringList classifierBody =
  "isInfixOf" `elem` bodyTokens
 where
  bodyTokens =
    tokenizeSource
      (stripHaskellComments (stripStringLiterals classifierBody))

-- | Mask line comments and nested block comments while preserving newlines.
-- String contents are masked before this helper is called, so comment markers
-- embedded in a diagnostic literal cannot affect the scan.
stripHaskellComments :: String -> String
stripHaskellComments = go 0
 where
  go :: Int -> String -> String
  go _ [] = []
  go 0 ('-' : '-' : remaining) = stripLineComment remaining
  go depth ('{' : '-' : remaining) = ' ' : ' ' : go (depth + 1) remaining
  go depth ('-' : '}' : remaining)
    | depth > 0 = ' ' : ' ' : go (depth - 1) remaining
  go depth (character : remaining)
    | depth > 0 = masked character : go depth remaining
    | otherwise = character : go depth remaining

  stripLineComment :: String -> String
  stripLineComment [] = []
  stripLineComment ('\n' : remaining) = '\n' : go 0 remaining
  stripLineComment (_ : remaining) = ' ' : stripLineComment remaining

  masked :: Char -> Char
  masked '\n' = '\n'
  masked _ = ' '

topLevelRetryClassifierBodies :: String -> [(String, String)]
topLevelRetryClassifierBodies = go . lines
 where
  go [] = []
  go (sourceLine : remaining) =
    case retryClassifierDefinitionName sourceLine of
      Nothing -> go remaining
      Just classifierName ->
        let definitionIndent = leadingWhitespaceCount sourceLine
            (bodyLines, rest) = span (isDefinitionContinuation definitionIndent) remaining
         in (classifierName, unlines (sourceLine : bodyLines)) : go rest

  isDefinitionContinuation definitionIndent sourceLine =
    null sourceLine
      || leadingWhitespaceCount sourceLine > definitionIndent
      || "--" `isPrefixOf` trimLeft sourceLine

retryClassifierDefinitionName :: String -> Maybe String
retryClassifierDefinitionName sourceLine
  | '=' `notElem` sourceLine = Nothing
  | otherwise =
      case tokenizeSource (trimLeft sourceLine) of
        classifierName : _
          | "isRetryable" `isPrefixOf` classifierName -> Just classifierName
        _ -> Nothing

-- | Sprint 4.22 follow-on: the create-call-site coverage scan that
-- enforces the managed-resource registry totality invariant
-- (@documents/engineering/lifecycle_reconciliation_doctrine.md § 3.1@,
-- invariant 1: "No prodbox code path may create an AWS or cluster
-- resource that is not in the registry"). Registry ↔ doc parity is
-- already machine-enforced via the @resource-lifecycle-classes@
-- generated section; this scan covers the *other* half — the create
-- call sites themselves — across the two deliberately narrow surfaces
-- where prodbox actually originates new AWS/cluster resources:
--
--   1. Pulumi stack creation: the @Pulumi<Word>Resources@ constructors
--      of the @PulumiCommand@ ADT in @src/Prodbox/CLI/Command.hs@. Each
--      must map (via 'pulumiCreateSiteOwners') to a registered stack
--      name.
--   2. Operational IAM user creation: the AWS CLI verbs in
--      'iamCreateVerbs', which may appear only in the
--      @operational-iam-user@ owner module @src/Prodbox/Aws.hs@.
--
-- Broader generic-@create*@ / @change-resource-record-sets@ /
-- @create-bucket@ / @mc mb@ scanning is *deliberately out of scope*:
-- those resources are Pulumi-managed (covered transitively by the
-- stack scan) or specially-handled bootstrap operations, and scanning
-- them by raw substring would false-positive on legitimate code. The
-- scan stays narrow on purpose.
-- | Sprint 4.18: refuse new @`.prodbox-state/`@ string literals anywhere
-- in the production Haskell source tree (@src/@ + @app/@). Sprint 3.13
-- chunks 8–16 erased every supported path that writes to the
-- @.prodbox-state/@ host-side directory:
--
--   * chunks 8–14 — chart-secret cache (@.prodbox-state/<ns>/.secrets.json@):
--     data-bound chart secrets now flow through Vault KV and chart-local
--     materializers.
--   * chunk 16 — gateway per-node event-key cache
--     (@.prodbox-state/<ns>/.gateway-event-keys.json@): gateway event keys
--     now come from Vault KV and the gateway chart materializer.
--
-- With both caches gone, any new @`.prodbox-state/`@ literal in
-- production source is by definition a regression of the closed cache
-- surface.
--
-- The scan is intentionally narrow:
--
--   * Only Haskell @.hs@ files under @src/@ and @app/@.
--   * Only string literals (via 'extractStringLiterals') — comments and
--     docstrings that *mention* @`.prodbox-state/`@ for historical
--     context are allowed.
--   * @test/@ is excluded so the unit tests can pin the lint's
--     fires-on-offending-literal contract with synthetic offenders.
--   * The lint module itself is excluded — its own pattern string and
--     diagnostic text contain the very substring it scans for.
checkForbidDotProdboxState :: FilePath -> IO [String]
checkForbidDotProdboxState repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let
    -- The needle pattern is built at runtime so this lint module's own
    -- string literals (its scan pattern + diagnostic text) don't
    -- accidentally trip the scan when it sweeps over @src/@.
    needle = "." ++ "prodbox-state" ++ "/"
    -- Production-only scope: only @src/@ and @app/@ Haskell files. Test
    -- modules legitimately mention the closed cache prefix for
    -- regression coverage (see the Sprint 4.18 unit tests in
    -- @test/unit/Main.hs@), so excluding @test/@ here keeps the lint
    -- narrowly focused on production regressions. The lint module
    -- itself is also excluded — its own pattern string and diagnostic
    -- text contain the very substring it scans for.
    scanPath path =
      (".hs" `isSuffixOf` path)
        && any (`isPrefixOf` path) ["src/", "app/"]
        && path /= forbidLintSelfPath
  fmap concat $
    forM
      [path | path <- repoPaths, scanPath path]
      ( \relativePath -> do
          let absolutePath = repoRoot </> relativePath
          isFile <- doesFileExist absolutePath
          if not isFile
            then pure []
            else do
              contents <- readFileStrict absolutePath
              let offenders =
                    filter (needle `isInfixOf`) (extractStringLiterals contents)
              pure
                [ relativePath
                    ++ " string literal contains the closed prodbox-state "
                    ++ "prefix (Sprint 3.13 chunks 8\8211\&16 eradicated "
                    ++ "every host-side cache under it; any new reference "
                    ++ "is a regression): "
                    ++ shortenSprintLeak offender
                | offender <- offenders
                ]
      )

-- | The self-exclusion path for 'checkForbidDotProdboxState'. The lint
-- module's own pattern string and diagnostic text contain the very
-- substring it scans for, so this module is allowlisted by relative
-- path.
forbidLintSelfPath :: FilePath
forbidLintSelfPath = "src/Prodbox/CheckCode.hs"

-- | Sprint 0.9: the set of repo-relative governed-documentation paths
-- subject to the documentation-harmony reconciler and the relative-link
-- check. "Governed docs" are every @*.md@ under @documents/@ and
-- @DEVELOPMENT_PLAN/@ plus the repo-root ALL-CAPS exceptions
-- (@README.md@, @CLAUDE.md@, @AGENTS.md@) named by
-- @documents/documentation_standards.md § 2@.
isGovernedDocPath :: FilePath -> Bool
isGovernedDocPath path =
  (".md" `isSuffixOf` path)
    && ( any (`isPrefixOf` path) ["documents/", "DEVELOPMENT_PLAN/"]
           || path `elem` ["README.md", "CLAUDE.md", "AGENTS.md"]
       )

-- | Drop every line that lives inside a fenced code block (a region
-- opened and closed by a line whose first non-whitespace content is a
-- triple-backtick fence). The fence lines themselves are dropped too.
-- Used to strip the EXAMPLE prodbox markers that
-- @documents/documentation_standards.md@ carries inside a @```markdown@
-- block (which legitimately declares @none@), so the marker scan does
-- not false-positive on teaching examples. Exposed for unit tests.
stripFencedCodeBlocks :: [String] -> [String]
stripFencedCodeBlocks = go False
 where
  go _ [] = []
  go inFence (lineText : remaining)
    | isFenceLine lineText = go (not inFence) remaining
    | inFence = go inFence remaining
    | otherwise = lineText : go inFence remaining
  isFenceLine lineText = "```" `isPrefixOf` trimLeft lineText

-- | Blank out backtick-delimited inline-code spans within a single line,
-- replacing each span (and its delimiting backticks) with spaces. Used so
-- that markers and links quoted inline for documentation purposes — e.g.
-- ``the `<!-- prodbox:<key>:start -->` marker`` or ``the
-- `[text](path#anchor)` form`` — are not treated as real markers or
-- links. Unterminated spans (a lone backtick) blank out the remainder of
-- the line, which is the conservative choice. Exposed for unit tests.
stripInlineCodeSpans :: String -> String
stripInlineCodeSpans = goOutside
 where
  goOutside [] = []
  goOutside ('`' : rest) = ' ' : goInside rest
  goOutside (character : rest) = character : goOutside rest

  goInside [] = []
  goInside ('`' : rest) = ' ' : goOutside rest
  goInside (_ : rest) = ' ' : goInside rest

-- | The set of prodbox generated-section marker keys PHYSICALLY present
-- in a governed document, scanning only content OUTSIDE fenced code
-- blocks and OUTSIDE inline-code spans. A key counts as present when a
-- start or end marker for it appears in the cleaned content, in any of
-- the host-syntax forms enumerated by
-- @documents/documentation_standards.md § 11@ (Markdown @<!-- ... -->@,
-- Helm/Go templates @{{\/* ... *\/}}@, YAML @# ...@, and the
-- Haskell/PureScript/TypeScript @-- ...@ comment form). Returns the keys
-- sorted and de-duplicated. Exposed for unit tests.
prodboxMarkerKeysPresent :: String -> [String]
prodboxMarkerKeysPresent contents =
  dedupeSorted
    [ key
    | cleanedLine <- map stripInlineCodeSpans (stripFencedCodeBlocks (lines contents))
    , key <- markerKeysInLine cleanedLine
    ]

-- | Extract every prodbox marker key declared on a single (already
-- code-stripped) line. A line may carry more than one marker (the
-- documentation-standards table puts start+end markers on one row, though
-- those rows are inline-code and thus blanked before this runs).
markerKeysInLine :: String -> [String]
markerKeysInLine cleanedLine =
  [ key
  | (openToken, closeTokens) <- markerSyntaxes
  , key <- markerKeysForSyntax openToken closeTokens cleanedLine
  ]

-- | The open/close delimiter forms for each host syntax. The body between
-- the @prodbox:@ prefix and the @:start@/@:end@ suffix is the key.
markerSyntaxes :: [(String, [String])]
markerSyntaxes =
  [ ("<!-- prodbox:", ["-->"])
  , ("{{/* prodbox:", ["*/}}"])
  , ("# prodbox:", [""])
  , ("-- prodbox:", [""])
  , ("// prodbox:", [""])
  ]

-- | Given one open delimiter, the acceptable close delimiters, and a
-- cleaned line, return the marker keys for every well-formed marker the
-- line carries. A marker body has the shape @<key>:start@ or @<key>:end@;
-- the key is everything before the final @:start@ / @:end@ suffix.
markerKeysForSyntax :: String -> [String] -> String -> [String]
markerKeysForSyntax openToken closeTokens cleanedLine =
  [ key
  | afterOpen <- segmentsAfter openToken cleanedLine
  , body <- bodyBeforeClose afterOpen
  , key <- keyFromBody body
  ]
 where
  bodyBeforeClose afterOpen =
    case closeTokens of
      [""] -> [trimLine (takeWhile (/= ' ') (trimLeft afterOpen))]
      _ -> [trimLine (takeBeforeAny closeTokens afterOpen) | endsWithAny closeTokens afterOpen]

-- | Split a string into the suffixes that follow each (non-overlapping)
-- occurrence of @needle@. Total; returns @[]@ when @needle@ is absent.
segmentsAfter :: String -> String -> [String]
segmentsAfter needle = go
 where
  go haystack =
    case stripFirstInfix needle haystack of
      Nothing -> []
      Just rest -> rest : go rest

-- | The portion of @haystack@ after the first occurrence of @needle@, if
-- present.
stripFirstInfix :: String -> String -> Maybe String
stripFirstInfix needle haystack =
  case haystack of
    [] -> Nothing
    (_ : rest) ->
      case stripExactPrefix needle haystack of
        Just suffix -> Just suffix
        Nothing -> stripFirstInfix needle rest

-- | Total prefix strip: @Just suffix@ when @needle@ is a prefix of the
-- string, otherwise @Nothing@.
stripExactPrefix :: String -> String -> Maybe String
stripExactPrefix [] suffix = Just suffix
stripExactPrefix _ [] = Nothing
stripExactPrefix (n : ns) (c : cs)
  | n == c = stripExactPrefix ns cs
  | otherwise = Nothing

-- | The portion of @haystack@ before the first occurrence of any token in
-- @tokens@. Total; returns the whole string when no token matches.
takeBeforeAny :: [String] -> String -> String
takeBeforeAny tokens = go
 where
  go [] = []
  go haystack@(c : cs)
    | any (`isPrefixOfString` haystack) tokens = []
    | otherwise = c : go cs
  isPrefixOfString token str =
    case stripExactPrefix token str of
      Just _ -> True
      Nothing -> False

-- | Does the string contain any of the close tokens?
endsWithAny :: [String] -> String -> Bool
endsWithAny tokens str = any (`isInfixOf` str) tokens

-- | Parse a marker body of the form @<key>:start@ or @<key>:end@ into its
-- key. Returns @[]@ when the body does not end in a recognized suffix, or
-- when the key would be empty or the placeholder @<key>@ token (the
-- documentation table uses a literal @<key>@ placeholder).
keyFromBody :: String -> [String]
keyFromBody body =
  [ key
  | suffix <- [":start", ":end"]
  , suffix `isSuffixOf` body
  , let key = take (length body - length suffix) body
  , not (null key)
  , key /= "<key>"
  ]

-- | Sprint 0.9 (pure). The @**Generated sections**@ header ↔ markers ↔
-- registry reconciler decision for ONE governed document. Inputs:
--
--   * @path@ — the document's repo-relative path (for diagnostics);
--   * @declaredKeys@ — the keys parsed from the document's
--     @**Generated sections**:@ metadata field (empty for @none@);
--   * @markerKeys@ — the marker keys physically present in the file
--     (outside fences / inline code), from 'prodboxMarkerKeysPresent';
--   * @registryKeysForFile@ — the registry keys that target this file;
--   * @allRegistryKeys@ — every key in the @GeneratedSectionRule@
--     registry (across all files).
--
-- Three leg agreement is enforced (documentation_standards.md § 3 / § 11):
--
--   1. Every registry key for this file must be declared in metadata AND
--      have its markers physically present.
--   2. Every declared (non-@none@) key must be registered (in
--      @allRegistryKeys@).
--   3. Every marker key physically present must be declared in metadata.
generatedSectionsReconcilerViolations
  :: FilePath -> [String] -> [String] -> [String] -> [String] -> [String]
generatedSectionsReconcilerViolations
  path
  declaredKeys
  markerKeys
  registryKeysForFile
  allRegistryKeys =
    registryUndeclaredViolations
      ++ registryMissingMarkerViolations
      ++ declaredUnregisteredViolations
      ++ markerUndeclaredViolations
   where
    registryUndeclaredViolations =
      [ path
          ++ " is registered for generated-section key `"
          ++ key
          ++ "` but does not declare it in its `**Generated sections**:` "
          ++ "metadata field (documentation_standards.md § 3)."
      | key <- registryKeysForFile
      , key `notElem` declaredKeys
      ]
    registryMissingMarkerViolations =
      [ path
          ++ " is registered for generated-section key `"
          ++ key
          ++ "` but its `prodbox:"
          ++ key
          ++ ":start`/`:end` markers are not present in the file "
          ++ "(documentation_standards.md § 11)."
      | key <- registryKeysForFile
      , key `notElem` markerKeys
      ]
    declaredUnregisteredViolations =
      [ path
          ++ " declares generated-section key `"
          ++ key
          ++ "` in its `**Generated sections**:` metadata field, but no "
          ++ "`GeneratedSectionRule` registers it (documentation_standards.md § 11)."
      | key <- declaredKeys
      , key `notElem` allRegistryKeys
      ]
    markerUndeclaredViolations =
      [ path
          ++ " carries `prodbox:"
          ++ key
          ++ ":start`/`:end` markers but does not declare `"
          ++ key
          ++ "` in its `**Generated sections**:` metadata field "
          ++ "(documentation_standards.md § 3)."
      | key <- markerKeys
      , key `notElem` declaredKeys
      ]

-- | Sprint 0.9 (pure). Parse the value of a governed document's
-- @**Generated sections**:@ metadata field from its full contents into
-- the declared key list. Returns @Nothing@ when no metadata line is
-- present (a separate violation surface), @Just []@ for @none@, and
-- @Just keys@ otherwise.
--
-- The value is tolerant of documentation prose: it reads only the first
-- comma-separated list of tokens, stops at the first parenthesis (some
-- docs annotate @none (… scheduled …)@), strips surrounding backticks
-- (some docs quote keys as @`command-registry.markdown`@), and treats a
-- bare @none@ token as the empty declared set. Exposed for unit tests.
parseGeneratedSectionsField :: String -> Maybe [String]
parseGeneratedSectionsField contents =
  case metadataValues of
    [] -> Nothing
    (value : _) -> Just (parseValue value)
 where
  fieldPrefix = "**Generated sections**:"
  metadataValues =
    [ trimLine (drop (length fieldPrefix) lineText)
    | lineText <- lines contents
    , fieldPrefix `isPrefixOf` lineText
    ]
  parseValue rawValue =
    let beforeParen = takeWhile (/= '(') rawValue
        tokens =
          [ token
          | rawToken <- splitOnComma beforeParen
          , let token = stripBackticks (trimLine rawToken)
          , not (null token)
          ]
     in case tokens of
          ["none"] -> []
          _ -> filter (/= "none") tokens
  stripBackticks = filter (/= '`')

-- | Split a string on commas. Total.
splitOnComma :: String -> [String]
splitOnComma value =
  case break (== ',') value of
    (before, []) -> [before]
    (before, _ : after) -> before : splitOnComma after

-- | Sprint 0.9 (pure). Every markdown link TARGET @target@ from an
-- inline link of the form @[text](target)@ found in the supplied
-- governed-document contents, scanning only content OUTSIDE fenced code
-- blocks and OUTSIDE inline-code spans (so example links quoted for
-- documentation purposes — e.g. ``the `[text](path#anchor)` form`` — are
-- not surfaced). Reference-style links and autolinks are out of scope.
-- Exposed for unit tests.
extractMarkdownLinkTargets :: String -> [String]
extractMarkdownLinkTargets contents =
  concatMap
    (linkTargetsInLine . stripInlineCodeSpans)
    (stripFencedCodeBlocks (lines contents))

-- | The link targets on one already-code-stripped line. A target is the
-- text between @](@ and the matching @)@.
linkTargetsInLine :: String -> [String]
linkTargetsInLine = go
 where
  go lineText =
    case stripFirstInfix "](" lineText of
      Nothing -> []
      Just afterOpen ->
        let target = takeWhile (/= ')') afterOpen
            rest = drop (length target) afterOpen
         in target : go rest

-- | Sprint 0.9 (pure). Is a markdown link target a RELATIVE in-repo path
-- worth resolving? Skips absolute URLs (@http://@, @https://@,
-- @mailto:@), pure-anchor links (@#section@), protocol-relative URLs
-- (@//host@), and empty targets. Exposed for unit tests.
isRelativeLinkTarget :: String -> Bool
isRelativeLinkTarget target =
  let trimmed = trimLine target
   in not (null trimmed)
        && not (any (`isPrefixOf` trimmed) ["http://", "https://", "mailto:", "#", "//"])

-- | Sprint 0.9 (pure). Resolve a relative link target against the
-- directory of the document that contains it, returning the repo-relative
-- target path to test for existence. The trailing @#anchor@ (if any) is
-- stripped before resolution. Returns @Nothing@ when the target is not a
-- relative in-repo path (per 'isRelativeLinkTarget') or when, after
-- stripping the anchor, only an anchor remained. Exposed for unit tests.
relativeLinkResolves :: FilePath -> String -> Maybe FilePath
relativeLinkResolves docPath target
  | not (isRelativeLinkTarget target) = Nothing
  | null pathPart = Nothing
  | otherwise = Just (collapseRelativePath (takeDirectory docPath </> pathPart))
 where
  pathPart = takeWhile (/= '#') (trimLine target)

-- | Syntactically collapse @.@ and @..@ segments of a relative path into a
-- canonical repo-relative form. @System.FilePath.normalise@ deliberately
-- keeps @..@ segments, so this folds them: a @..@ pops the previous
-- ordinary segment, or is preserved verbatim when there is nothing to pop
-- (the path escapes its base — a genuine broken-link signal). Total; no
-- partial functions.
collapseRelativePath :: FilePath -> FilePath
collapseRelativePath path =
  -- The accumulator is kept REVERSED (most-recent segment at the head) so
  -- a @..@ pops the immediately-preceding segment in O(1); it is reversed
  -- back to forward order before joining.
  case reverse (foldl step [] (splitDirectories (normalise path))) of
    [] -> "."
    collapsed -> joinSegments collapsed
 where
  step reversedAcc segment =
    case segment of
      "." -> reversedAcc
      ".." ->
        case reversedAcc of
          (previous : rest)
            | previous /= ".." -> rest
          _ -> ".." : reversedAcc
      _ -> segment : reversedAcc
  joinSegments segments =
    case segments of
      [] -> "."
      (first : rest) -> foldl (</>) first rest

-- | Sprint 0.9 (IO wrapper). The @**Generated sections**@ header ↔
-- markers ↔ registry reconciler over every governed document, mirroring
-- the @checkEnvVarConfigReads@ pattern: a thin IO shell over the pure
-- 'generatedSectionsReconcilerViolations' decision and
-- 'prodboxMarkerKeysPresent' / 'parseGeneratedSectionsField' parsers.
checkGeneratedSectionsHarmony :: FilePath -> IO [String]
checkGeneratedSectionsHarmony repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let governedPaths = [path | path <- repoPaths, isGovernedDocPath path]
      allRegistryKeys = dedupeSorted (map generatedSectionKey generatedSectionRules)
      registryKeysForFile path =
        dedupeSorted
          [ generatedSectionKey rule
          | rule <- generatedSectionRules
          , normalise (generatedSectionPath rule) == normalise path
          ]
  fmap concat $
    forM governedPaths $ \relativePath -> do
      contents <- readFileStrict (repoRoot </> relativePath)
      let markerKeys = prodboxMarkerKeysPresent contents
          forFile = registryKeysForFile relativePath
      pure $
        case parseGeneratedSectionsField contents of
          Nothing ->
            [ relativePath
                ++ " is missing the mandatory `**Generated sections**:` "
                ++ "metadata field (documentation_standards.md § 3)."
            ]
          Just declaredKeys ->
            generatedSectionsReconcilerViolations
              relativePath
              declaredKeys
              markerKeys
              forFile
              allRegistryKeys

-- | Sprint 0.9 (IO wrapper). The relative-link check over every governed
-- document: extract inline link targets (outside fences / inline code),
-- resolve each relative target against the document's directory, and
-- report any that do not resolve to an existing on-disk file. Mirrors the
-- @checkEnvVarConfigReads@ pattern.
checkGovernedDocRelativeLinks :: FilePath -> IO [String]
checkGovernedDocRelativeLinks repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let governedPaths = [path | path <- repoPaths, isGovernedDocPath path]
  fmap concat $
    forM governedPaths $ \relativePath -> do
      contents <- readFileStrict (repoRoot </> relativePath)
      let resolvedTargets =
            [ (target, resolved)
            | target <- extractMarkdownLinkTargets contents
            , Just resolved <- [relativeLinkResolves relativePath target]
            ]
      fmap concat $
        forM resolvedTargets $ \(target, resolved) -> do
          targetExists <- doesFileExist (repoRoot </> resolved)
          dirExists <- doesDirectoryExist (repoRoot </> resolved)
          pure
            [ relativePath
                ++ " has a broken relative link `"
                ++ target
                ++ "`; resolved target `"
                ++ resolved
                ++ "` does not exist (documentation_standards.md § 4)."
            | not targetExists && not dirExists
            ]

-- | Sprint 0.21 (pure). The four legal @**Status**:@ values enumerated by
-- @documents/documentation_standards.md § 3@. § 9 already names
-- @**Status**: WIP@ as an anti-pattern; this list is what makes that
-- machine-checkable rather than review-enforced.
governedDocStatusValues :: [String]
governedDocStatusValues =
  [ "Authoritative source"
  , "Reference only"
  , "Generated reference"
  , "Deprecated"
  ]

-- | Sprint 0.21 (pure). Read the first @**Status**:@ metadata value from a
-- governed document, scanning only content OUTSIDE fenced code blocks so
-- the teaching example in @documentation_standards.md § 3@ (which spells
-- the whole @[A | B | C | D]@ alternation inside a @```markdown@ fence) is
-- not read as a real declaration. Exposed for unit tests.
parseGovernedDocStatusField :: String -> Maybe String
parseGovernedDocStatusField contents =
  case metadataValues of
    [] -> Nothing
    (value : _) -> Just value
 where
  fieldPrefix = "**Status**:"
  metadataValues =
    [ trimLine (drop (length fieldPrefix) lineText)
    | lineText <- stripFencedCodeBlocks (lines contents)
    , fieldPrefix `isPrefixOf` lineText
    ]

-- | Sprint 0.21 (pure). Status-field violations for one governed document:
-- a missing field, or a value outside the closed set. Exposed for unit
-- tests.
governedDocStatusViolations :: FilePath -> String -> [String]
governedDocStatusViolations relativePath contents =
  case parseGovernedDocStatusField contents of
    Nothing ->
      [ relativePath
          ++ " is missing the mandatory `**Status**:` metadata field "
          ++ "(documentation_standards.md § 3)."
      ]
    Just value
      | value `elem` governedDocStatusValues -> []
      | otherwise ->
          [ relativePath
              ++ " declares `**Status**: "
              ++ value
              ++ "`, which is not one of the four legal values ("
              ++ intercalate " | " governedDocStatusValues
              ++ ") (documentation_standards.md § 3)."
          ]

-- | Sprint 0.21 (IO wrapper). The @**Status**:@ legality check over every
-- governed document.
checkGovernedDocStatusValues :: FilePath -> IO [String]
checkGovernedDocStatusValues repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let governedPaths = [path | path <- repoPaths, isGovernedDocPath path]
  fmap concat $
    forM governedPaths $ \relativePath -> do
      contents <- readFileStrict (repoRoot </> relativePath)
      pure (governedDocStatusViolations relativePath contents)

-- | Sprint 0.21 (pure). Source paths the development plan cites as
-- historical fact — each deleted by a named sprint that owns its removal —
-- so a citation to them records what the repository USED to contain rather
-- than asserting a live artifact. Every other cited path must exist.
--
-- Adding an entry here is a deliberate act: it says "this sprint deleted
-- this file, and the citation is history." It is NOT a place to silence a
-- stale evidence claim — Standard C requires status to describe reality,
-- and Sprints @4.53@/@4.54@ are the worked example of an Independent
-- Validation resting on a module a later sprint had already deleted.
retiredCitedSourcePaths :: [FilePath]
retiredCitedSourcePaths =
  removedLegacyTransportSourcePaths
    ++ [ "src/Prodbox/Host/Tool.hs" -- retired by Sprint 1.78 (zero production importers)
       , "src/Prodbox/StateMachine.hs" -- retired by Sprint 1.32
       , "src/Prodbox/SupportedRuntime.hs" -- retired by Sprints 6.3/7.3
       , "src/Prodbox/Secret/Derive.hs" -- retired by Sprint 3.19 (master-seed removal)
       , "src/Prodbox/Secret/EnsureNamespace.hs" -- retired by Sprint 3.19
       , "src/Prodbox/Secret/HostBootstrap.hs" -- retired by Sprint 3.19
       , "src/Prodbox/Secret/Inventory.hs" -- retired by Sprint 3.19
       , "src/Prodbox/Secret/MasterSeed.hs" -- retired by Sprint 3.19
       , "src/Prodbox/Secret/Wire.hs" -- retired by Sprint 3.19
       , -- Deleted by Sprint 4.50 with the host-direct store it was named for.
         -- Its coverage did not disappear: Sprint 4.53 moved the differential
         -- suite to test/unit/ModelBCasTransportAdapter.hs, whose own header
         -- records the replacement.
         "test/unit/HostDirectModelBAdapter.hs"
       , -- Deleted by Sprint 4.59 together with the in-controller Target Agent
         -- write lane it covered. No coverage moved with it: the suite was
         -- listed in `other-modules` and never registered in test/unit/Main.hs,
         -- so it compiled and never ran. The deployed writer's coverage is
         -- unaffected — it lives on the TargetSecretWorker path.
         "test/unit/ControlPlaneTargetSecretAgentExecution.hs"
       ]

-- | Sprint 0.21 (pure). The inline-code spans on one line, WITHOUT their
-- delimiting backticks — the inverse of 'stripInlineCodeSpans'. An
-- unterminated span yields nothing, which is the conservative choice.
-- Exposed for unit tests.
inlineCodeSpansInLine :: String -> [String]
inlineCodeSpansInLine = goOutside
 where
  goOutside [] = []
  goOutside ('`' : rest) = goInside "" rest
  goOutside (_ : rest) = goOutside rest

  goInside _ [] = []
  goInside acc ('`' : rest) = reverse acc : goOutside rest
  goInside acc (character : rest) = goInside (character : acc) rest

-- | Sprint 0.21 (pure). Does an inline-code span name ONE concrete in-repo
-- Haskell source or test module? Deliberately narrow: a single
-- whitespace-free token ending in @.hs@ under a known source root, and
-- carrying no glob or brace-expansion metacharacter — the plan legitimately
-- writes families such as @src\/Prodbox\/**.hs@,
-- @src\/Prodbox\/Infra\/{AwsEksTestStack,AwsTestStack}.hs@, and
-- @src\/Prodbox\/ControlPlane\/RetainedMaterialDelivery*.hs@ in prose, and
-- those name a set rather than an artifact a reader can open. Angle-bracket
-- placeholders (@src\/Prodbox\/Lifecycle\/\<Role\>\/ChartStatics.hs@) are
-- excluded for the same reason, as is an elided path such as
-- @src\/\<U+2026\>.hs@ — the ellipsis is a placeholder exactly like the glob
-- and brace forms. Exposed for unit tests.
isCitedSourcePath :: String -> Bool
isCitedSourcePath candidate =
  ".hs" `isSuffixOf` candidate
    && any (`isPrefixOf` candidate) ["src/Prodbox/", "test/", "app/"]
    && not (any (`elem` placeholderCharacters) candidate)
 where
  -- Glob and brace metacharacters, angle-bracket placeholders, whitespace,
  -- plus the horizontal ellipsis (U+2026) and zero-width space (U+200B) that
  -- prose uses to elide a path segment.
  placeholderCharacters :: String
  placeholderCharacters = " \t*?{}[]<>\8230\8203"

-- | Sprint 0.21 (pure). Every in-repo Haskell source path cited in a
-- document's inline-code spans, outside fenced code blocks, sorted and
-- de-duplicated. Exposed for unit tests.
citedSourcePathsInDoc :: String -> [FilePath]
citedSourcePathsInDoc contents =
  dedupeSorted
    [ codeSpan
    | lineText <- stripFencedCodeBlocks (lines contents)
    , codeSpan <- inlineCodeSpansInLine lineText
    , isCitedSourcePath codeSpan
    ]

-- | Sprint 0.28: one registered production @PRODBOX_*@ environment read.
data ProductionEnvVarRead = ProductionEnvVarRead
  { productionEnvVarName :: String
  , productionEnvVarOwners :: [FilePath]
  , productionEnvVarReason :: String
  }

-- | Sprint 0.28: every @PRODBOX_*@ name a production module may read, with the
-- module(s) that may read it and why.
--
-- This replaces a claim with a registry. @checkEnvVarConfigReads@ forbids
-- @lookupEnv@ outright in five named config modules, which is a sound rule about
-- Tier-0 config and says nothing about the rest of @src/@ — and the rest of
-- @src/@ is where the production reads are. Both this repository's `CLAUDE.md`
-- and the ledger row that scheduled this work stated the inventory, and the
-- measured set is wider than either: **12** non-@PRODBOX_TEST_@ names, of which
-- five live in @src\/Prodbox\/CLI\/Rke2.hs@ (the four the guidance names, with
-- the LB-IP pair counted as one) and **seven** more that neither document
-- mentions at all.
--
-- The gate is a bijection, in the idiom of the legacy-escape registry: an
-- unregistered read fails, a read outside its owner fails, and a registry entry
-- with no surviving call site fails. @PRODBOX_TEST_@ names are out of scope —
-- they select repository fixtures rather than configure a running system, and
-- Sprint 5.33's rule that a fixture's unset arm must observe or refuse is what
-- governs them.
productionEnvVarRegistry :: [ProductionEnvVarRead]
productionEnvVarRegistry =
  [ ProductionEnvVarRead
      "PRODBOX_ALLOW_NON_TTY_INTERACTIVE"
      ["src/Prodbox/CLI/Interactive.hs"]
      "Operator escape for the TTY guard on interactive-only commands."
  , ProductionEnvVarRead
      "PRODBOX_NUKE_PLAN"
      ["src/Prodbox/CLI/Nuke.hs"]
      "Plan-file destination for `prodbox nuke --dry-run`."
  , ProductionEnvVarRead
      "PRODBOX_PULUMI_METALLB_POOL"
      ["src/Prodbox/CLI/Rke2.hs"]
      "Substitutes for live LAN detection when rendering the MetalLB pool. \
      \Load-bearing for host networking on the home substrate."
  , ProductionEnvVarRead
      "PRODBOX_PULUMI_EDGE_LB_IP"
      ["src/Prodbox/CLI/Rke2.hs"]
      "Substitutes for live LAN detection when rendering the edge LB address."
  , ProductionEnvVarRead
      "PRODBOX_PULUMI_INGRESS_LB_IP"
      ["src/Prodbox/CLI/Rke2.hs"]
      "Substitutes for live LAN detection when rendering the ingress LB address."
  , ProductionEnvVarRead
      "PRODBOX_RKE2_ENDPOINT_STATUS_ROOT"
      ["src/Prodbox/CLI/Rke2.hs"]
      "Relocates the Calico endpoint-status root the teardown path sweeps."
  , ProductionEnvVarRead
      "PRODBOX_RKE2_CONTAINERD_SOCKET"
      ["src/Prodbox/CLI/Rke2.hs"]
      "Relocates the containerd socket the registry-mirror config targets."
  , ProductionEnvVarRead
      "PRODBOX_PULUMI_AWS_ACCESS_KEY_ID"
      pulumiCredentialOwners
      pulumiCredentialReason
  , ProductionEnvVarRead
      "PRODBOX_PULUMI_AWS_SECRET_ACCESS_KEY"
      pulumiCredentialOwners
      pulumiCredentialReason
  , ProductionEnvVarRead
      "PRODBOX_PULUMI_AWS_SESSION_TOKEN"
      pulumiCredentialOwners
      pulumiCredentialReason
  , ProductionEnvVarRead
      "PRODBOX_PULUMI_AWS_REGION"
      pulumiCredentialOwners
      pulumiCredentialReason
  , ProductionEnvVarRead
      "PRODBOX_PULUMI_AWS_DEFAULT_REGION"
      pulumiCredentialOwners
      pulumiCredentialReason
  ]
 where
  pulumiCredentialOwners =
    [ "src/Prodbox/Infra/AwsEksTestStack.hs"
    , "src/Prodbox/Infra/AwsSesStack.hs"
    ]
  pulumiCredentialReason =
    "Carries the already-resolved AWS credential into the `pulumi` subprocess \
    \environment. It is a transport for a value the caller already holds, not a \
    \configuration source, so it does not reach Tier-0 resolution."

-- | Sprint 0.28 (pure). The files a production @PRODBOX_*@ read may appear in,
-- keyed by name. Exposed for unit tests.
productionEnvVarOwnersFor :: String -> Maybe [FilePath]
productionEnvVarOwnersFor name =
  productionEnvVarOwners
    <$> find ((== name) . productionEnvVarName) productionEnvVarRegistry

-- | Sprint 0.28 (pure). Whether a literal can be an environment variable name
-- at all.
--
-- POSIX forbids @=@ in a name, and every name this repository reads is
-- upper-snake. The predicate exists because the gate's first run flagged
-- @"PRODBOX_ID="@ in @src\/Prodbox\/CLI\/Rke2.hs@, which is a @--dry-run@ plan
-- **key** rendered as @KEY=value@ and never passed to @lookupEnv@. That is a
-- false positive, and it is excluded by a property of environment names rather
-- than by a path exemption or a trailing-@=@ heuristic — the distinction being
-- that this rule stays true for a plan key nobody has written yet.
isEnvironmentVariableName :: String -> Bool
isEnvironmentVariableName candidate =
  not (null candidate)
    && all (\character -> isAsciiUpper character || isDigit character || character == '_') candidate

-- | Sprint 0.28 (pure). The @PRODBOX_*@ names a source file references,
-- excluding the @PRODBOX_TEST_@ fixture family. Exposed for unit tests.
productionEnvVarNamesIn :: String -> [String]
productionEnvVarNamesIn contents =
  dedupeSorted
    [ literal
    | literal <- extractStringLiterals contents
    , "PRODBOX_" `isPrefixOf` literal
    , not ("PRODBOX_TEST_" `isPrefixOf` literal)
    , isEnvironmentVariableName literal
    ]

-- | Sprint 0.28 (IO). The production environment-read registry bijection.
checkProductionEnvVarReads :: FilePath -> IO [String]
checkProductionEnvVarReads repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let scanPath path =
        (".hs" `isSuffixOf` path)
          && any (`isPrefixOf` path) ["src/", "app/"]
          && path /= forbidLintSelfPath
  scanned <-
    forM
      [path | path <- repoPaths, scanPath path]
      ( \relativePath -> do
          contents <- readFileStrict (repoRoot </> relativePath)
          pure (relativePath, productionEnvVarNamesIn contents)
      )
  let observed = [(path, name) | (path, names) <- scanned, name <- names]
      unregistered =
        [ path
            ++ " reads the production environment variable `"
            ++ name
            ++ "`, which is not in `productionEnvVarRegistry`. Register it with "
            ++ "its owner module and the reason it is not Tier-0 configuration, "
            ++ "or remove the read (config_doctrine.md § 10)."
        | (path, name) <- observed
        , productionEnvVarOwnersFor name == Nothing
        ]
      outsideOwner =
        [ path
            ++ " reads `"
            ++ name
            ++ "`, which is registered to "
            ++ intercalate ", " owners
            ++ ". Move the read into an owner module or widen the registry entry."
        | (path, name) <- observed
        , Just owners <- [productionEnvVarOwnersFor name]
        , path `notElem` owners
        ]
      orphanEntries =
        [ "`productionEnvVarRegistry` registers `"
            ++ productionEnvVarName entry
            ++ "`, which no scanned production module reads. Remove the entry so "
            ++ "the registry stays a description of the worktree."
        | entry <- productionEnvVarRegistry
        , productionEnvVarName entry `notElem` map snd observed
        ]
  pure (unregistered ++ outsideOwner ++ orphanEntries)

-- | Sprint 1.91: why one compiled AWS-coordinate literal is not a value an
-- operator should have chosen.
--
-- The first four are @config_doctrine.md@ § 0's four compiled classes, in
-- order. 'AwsCoordinateDocumentationExample' is deliberately __not__ a fifth
-- compiled class: it marks a coordinate that appears inside operator-facing
-- prose (a refusal message, a generated schema header) and is never a value the
-- program uses. It is registered rather than exempted because a scanner that
-- skipped prose would be one string-concatenation away from skipping a real
-- coordinate.
data AwsCoordinateReason
  = AwsCoordinateProtocolFixed
  | AwsCoordinateNotAws
  | AwsCoordinateProdboxIdentity
  | AwsCoordinateRegressionFixture
  | AwsCoordinateDocumentationExample
  deriving (Eq, Show)

-- | The reason as it appears in a refusal.
renderAwsCoordinateReason :: AwsCoordinateReason -> String
renderAwsCoordinateReason reason = case reason of
  AwsCoordinateProtocolFixed -> "protocol-fixed"
  AwsCoordinateNotAws -> "not AWS"
  AwsCoordinateProdboxIdentity -> "prodbox-chosen identity"
  AwsCoordinateRegressionFixture -> "compiled regression fixture"
  AwsCoordinateDocumentationExample -> "documentation example"

-- | Sprint 1.91: one registered compiled AWS-coordinate literal.
data AwsCoordinateLiteral = AwsCoordinateLiteral
  { awsCoordinateValue :: String
  -- ^ The exact region-shaped token, as it appears inside the literal.
  , awsCoordinateSymbol :: String
  -- ^ The top-level source symbol that holds or decides it. The gate refuses
  -- when this symbol is gone, so a registry entry cannot outlive the code it
  -- describes.
  , awsCoordinateOwners :: [FilePath]
  -- ^ The exact repo-relative file set permitted to mention the value.
  , awsCoordinateReason :: AwsCoordinateReason
  , awsCoordinateNote :: String
  -- ^ Why this reason covers this value, in one sentence.
  }

-- | Sprint 1.91: every AWS-region-shaped literal a scanned module may compile
-- in, with the symbol that holds it and the reason it is not a deployment
-- choice.
--
-- @config_doctrine.md@ § 0 states the partition and refuses to let "the
-- deployment we happen to run uses this one" be a reason. This is the
-- enforcement, in the register-or-fail idiom of 'productionEnvVarRegistry' and
-- "Prodbox.Legacy.EscapeRegistry": an unregistered literal fails, a literal in
-- a file outside its declared set fails, and an entry whose symbol no longer
-- exists fails.
--
-- __Measured, not asserted.__ The matcher was run against @src\/@ and @app\/@
-- before the sprint's own deletions and found __22__ (file, value) pairs with
-- zero false positives: 2 configuration defects (the seeded @aws.region@ and
-- the prompt default, both closed by Sprint 1.91), 3 MinIO signing scopes
-- (collapsed to one constant), 6 protocol-fixed, and 11 values that are
-- fixtures or prose. The loose form that drops the two-letter-geography rule
-- found 37 with 15 false positives, which is why the shape is the strict one.
-- __18__ pairs survive; Sprint @4.86@ registered a nineteenth when the cascade
-- candidate entrypoint's fixed regression gained the same fixture scope.
awsCoordinateLiteralRegistry :: [AwsCoordinateLiteral]
awsCoordinateLiteralRegistry =
  [ AwsCoordinateLiteral
      globalSigningRegion
      "iamScope"
      ["src/Prodbox/Aws/Native/Iam.hs"]
      AwsCoordinateProtocolFixed
      "IAM is a global service and signs in one region; a deployment cannot choose otherwise."
  , AwsCoordinateLiteral
      globalSigningRegion
      "route53Scope"
      ["src/Prodbox/Aws/Native/Route53.hs"]
      AwsCoordinateProtocolFixed
      "Route 53 is a global service and signs in one region."
  , AwsCoordinateLiteral
      globalSigningRegion
      "renderCreateBucketXml"
      ["src/Prodbox/Aws/Native/S3.hs"]
      AwsCoordinateProtocolFixed
      "S3 requires `CreateBucket` in this one region to omit `LocationConstraint` entirely."
  , AwsCoordinateLiteral
      globalSigningRegion
      "applySesCaptureBucket"
      ["src/Prodbox/ControlPlane/ProviderProduction.hs"]
      AwsCoordinateProtocolFixed
      "The same `CreateBucket` rule, on the subprocess arm; the configured region is the input."
  , AwsCoordinateLiteral
      globalSigningRegion
      "globalServiceTaggingRegion"
      ["src/Prodbox/Lifecycle/Teardown/TaggingApiReach.hs"]
      AwsCoordinateProtocolFixed
      "The Resource Groups Tagging API answers for global services from one region only."
  , AwsCoordinateLiteral
      globalSigningRegion
      "minioSigningRegion"
      ["src/Prodbox/Minio/ObjectStoreTypes.hs"]
      AwsCoordinateNotAws
      "MinIO requires a SigV4 signing scope and ignores which; no AWS account is reached."
  , AwsCoordinateLiteral
      globalSigningRegion
      "renderCoordinateError"
      ["src/Prodbox/Settings/Coordinate.hs"]
      AwsCoordinateDocumentationExample
      "An example inside the refusal a malformed `aws.region` produces."
  , AwsCoordinateLiteral
      "us-west-2"
      "configTypesHeader"
      ["src/Prodbox/Config/SchemaDhall.hs"]
      AwsCoordinateDocumentationExample
      "An override example in the generated schema's own header comment."
  , AwsCoordinateLiteral
      globalSigningRegion
      "fixedAuditScenario"
      ["src/Prodbox/Lifecycle/Teardown/CascadeTerminalAudit.hs"]
      AwsCoordinateRegressionFixture
      "The escapee cluster ARN the terminal-audit verdict fixtures classify."
  , AwsCoordinateLiteral
      fixtureRegion
      "regressionAwsScope"
      ["src/Prodbox/ControlPlane/CleanupProgramDescriptorRepository/Internal.hs"]
      AwsCoordinateRegressionFixture
      fixtureRegionNote
  , AwsCoordinateLiteral
      fixtureRegion
      "regressionAwsScope"
      ["src/Prodbox/ControlPlane/DescriptorBoundLifecycleRuntime/Internal.hs"]
      AwsCoordinateRegressionFixture
      fixtureRegionNote
  , AwsCoordinateLiteral
      fixtureRegion
      "regressionInputs"
      ["src/Prodbox/Lifecycle/Teardown/CascadeCandidate/Internal.hs"]
      AwsCoordinateRegressionFixture
      fixtureRegionNote
  , AwsCoordinateLiteral
      fixtureRegion
      "fixedProviderCredentialSessionRegression"
      ["src/Prodbox/ControlPlane/ProviderCredentialSession/Internal.hs"]
      AwsCoordinateRegressionFixture
      fixtureRegionNote
  , AwsCoordinateLiteral
      fixtureRegion
      "fixedCascadeAwsScope"
      ["src/Prodbox/Lifecycle/Teardown/CascadeEvidence/Internal.hs"]
      AwsCoordinateRegressionFixture
      fixtureRegionNote
  , AwsCoordinateLiteral
      fixtureRegion
      "fixtureAwsScope"
      ["src/Prodbox/Lifecycle/Teardown/RecoveryPlane/Internal.hs"]
      AwsCoordinateRegressionFixture
      fixtureRegionNote
  , AwsCoordinateLiteral
      fixtureRegion
      "regressionAwsScope"
      ["src/Prodbox/Lifecycle/Teardown/RecoveryPlaneInterpreter/Internal.hs"]
      AwsCoordinateRegressionFixture
      fixtureRegionNote
  , AwsCoordinateLiteral
      fixtureRegion
      "fixedAwsScope"
      ["src/Prodbox/Lifecycle/Teardown/RecoveryRequirement/Internal.hs"]
      AwsCoordinateRegressionFixture
      fixtureRegionNote
  , AwsCoordinateLiteral
      fixtureRegion
      "fixedReportAwsScope"
      ["src/Prodbox/Lifecycle/Teardown/Report/Internal.hs"]
      AwsCoordinateRegressionFixture
      fixtureRegionNote
  , AwsCoordinateLiteral
      fixtureRegion
      "canonicalTeardownEvidenceScope"
      ["src/Prodbox/Test/Qualification/TeardownCounterexample.hs"]
      AwsCoordinateRegressionFixture
      fixtureRegionNote
  ]
 where
  -- Spelled once so the registry does not become the duplication it exists to
  -- forbid.
  globalSigningRegion = "us-" ++ "east-1"
  fixtureRegion = "ca-" ++ "central-1"
  fixtureRegionNote =
    "A fixture scope, deliberately not the global signing region, so a test can \
    \distinguish an audit taken inside it from one taken outside."

-- | Sprint 1.91 (pure). Whether a token has the shape of an AWS region name.
--
-- A two-letter geography, one or more lowercase words, and a non-zero ordinal.
-- Deliberately a shape and not a pinned list, for the reason
-- "Prodbox.Settings.Coordinate" gives at 'Prodbox.Settings.Coordinate.mkAwsRegion':
-- a repository-pinned region list refuses a legitimate value the day after AWS
-- launches one. @us-gov-west-1@, @cn-northwest-1@, and @us-iso-east-1@ match by
-- shape without appearing anywhere here.
--
-- The two-letter geography is what makes the scan usable: without it the same
-- scan matches @x-amz-content-sha256@-shaped protocol tokens and every other
-- hyphenated identifier ending in a digit.
isAwsRegionShapedToken :: String -> Bool
isAwsRegionShapedToken token =
  case splitOnHyphen token of
    (geography : rest@(_ : _ : _)) ->
      isLowerWordOfLength 2 geography
        && all isLowerWord (init rest)
        && isNonZeroOrdinal (last rest)
    _ -> False
 where
  isLowerWord segment = not (null segment) && all isAsciiLower segment
  isLowerWordOfLength len segment = length segment == len && isLowerWord segment
  isNonZeroOrdinal segment = case segment of
    [] -> False
    (leading : _) ->
      all isDigit segment && length segment <= 2 && leading /= '0'

-- | Sprint 1.91 (pure). Split on @-@, keeping empty segments so a malformed
-- token cannot pass by collapsing them.
splitOnHyphen :: String -> [String]
splitOnHyphen value =
  case break (== '-') value of
    (segment, []) -> [segment]
    (segment, _ : rest) -> segment : splitOnHyphen rest

-- | Sprint 1.91 (pure). The maximal @[a-z0-9-]@ runs of a string. A region
-- inside a larger literal (@arn:aws:eks:us-east-1:...@) is one such run,
-- because every ARN and URL delimiter breaks the run.
coordinateTokens :: String -> [String]
coordinateTokens = filter (not . null) . foldr step [[]]
 where
  step character (current : rest)
    | isCoordinateCharacter character = (character : current) : rest
    | otherwise = [] : current : rest
  step _ [] = [[]]
  isCoordinateCharacter character =
    isAsciiLower character || isDigit character || character == '-'

-- | Sprint 1.91 (pure). The AWS-region-shaped values a source file compiles,
-- read from its string literals only. Comments are excluded because a comment
-- is not a value; the two that reasoned about a prompt default as though it
-- were the deployed region were corrected in place instead. Exposed for unit
-- tests.
awsCoordinateLiteralsIn :: String -> [String]
awsCoordinateLiteralsIn contents =
  dedupeSorted
    [ token
    | literal <- extractStringLiterals contents
    , token <- coordinateTokens literal
    , isAwsRegionShapedToken token
    ]

-- | Sprint 1.91 (pure). Whether a registry admits this value in this file.
-- Exposed for unit tests.
awsCoordinateRegistered :: [AwsCoordinateLiteral] -> FilePath -> String -> Bool
awsCoordinateRegistered registry path value =
  any
    (\entry -> awsCoordinateValue entry == value && path `elem` awsCoordinateOwners entry)
    registry

-- | Sprint 1.91 (pure). Every file a registry declares, for the
-- symbol-survival half of the bijection. Exposed for unit tests.
awsCoordinateRegistryOwners :: [AwsCoordinateLiteral] -> [FilePath]
awsCoordinateRegistryOwners = dedupeSorted . concatMap awsCoordinateOwners

-- | Sprint 1.91 (pure). The bijection, expressed over observations rather than
-- over the filesystem, so all three directions are injection-testable: an
-- unregistered literal, a registered literal observed outside its declared file
-- set, and a registry entry whose symbol no longer exists.
--
-- The registry is a parameter rather than a global for exactly that reason. A
-- gate that can only be exercised against the tree it already passes on has
-- been observed to pass, not to refuse.
awsCoordinateFindings
  :: [AwsCoordinateLiteral]
  -- ^ The registry under test.
  -> [FilePath]
  -- ^ Every scanned path.
  -> [(FilePath, [String])]
  -- ^ The AWS-coordinate literals observed per scanned path.
  -> [(FilePath, [String])]
  -- ^ The source identifiers of each registry-declared path that was scanned.
  -> [String]
awsCoordinateFindings registry scanned observedByPath symbolsByOwner =
  unregistered ++ missingOwners ++ orphanEntries
 where
  observed = [(path, value) | (path, values) <- observedByPath, value <- values]
  unregistered =
    [ path
        ++ " compiles the AWS-coordinate literal `"
        ++ value
        ++ "`, which `awsCoordinateLiteralRegistry` does not admit here. Register "
        ++ "it with the symbol that holds it and exactly one of the compiled "
        ++ "reasons, or make the value operator-supplied Tier-0 Dhall "
        ++ "(config_doctrine.md § 0)."
    | (path, value) <- observed
    , not (awsCoordinateRegistered registry path value)
    ]
  missingOwners =
    [ scopedPathMissingViolation "`awsCoordinateLiteralRegistry`" relativePath
    | relativePath <- awsCoordinateRegistryOwners registry
    , relativePath `notElem` scanned
    ]
  orphanEntries =
    [ "`awsCoordinateLiteralRegistry` registers `"
        ++ awsCoordinateValue entry
        ++ "` ("
        ++ renderAwsCoordinateReason (awsCoordinateReason entry)
        ++ ") against the symbol `"
        ++ awsCoordinateSymbol entry
        ++ "`, which no longer exists in "
        ++ intercalate ", " (awsCoordinateOwners entry)
        ++ ". Remove the entry so the registry stays a description of the "
        ++ "worktree rather than a memory of it."
    | entry <- registry
    , not (any (symbolPresentIn entry) (awsCoordinateOwners entry))
    ]
  symbolPresentIn entry owner =
    maybe False (awsCoordinateSymbol entry `elem`) (lookup owner symbolsByOwner)

-- | Sprint 1.91 (IO). The compiled-AWS-coordinate register-or-fail bijection.
--
-- Scoped to @src\/@ and @app\/@, which is the region in which a literal can
-- reach a live AWS call. A literal in a Pulumi program under @pulumi\/@ is not
-- visible to this gate and is not claimed to be: the AWS substrate resource
-- envelope is a provisioning surface owned elsewhere.
checkAwsCoordinateLiterals :: FilePath -> IO [String]
checkAwsCoordinateLiterals repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let scanPath path =
        (".hs" `isSuffixOf` path)
          && any (`isPrefixOf` path) ["src/", "app/"]
          && path /= forbidLintSelfPath
      scanned = [path | path <- repoPaths, scanPath path]
      registry = awsCoordinateLiteralRegistry
  observedByPath <-
    forM scanned $ \relativePath -> do
      contents <- readFileStrict (repoRoot </> relativePath)
      pure (relativePath, awsCoordinateLiteralsIn contents)
  symbolsByOwner <-
    forM (filter (`elem` scanned) (awsCoordinateRegistryOwners registry)) $ \relativePath -> do
      contents <- readFileStrict (repoRoot </> relativePath)
      pure (relativePath, sourceIdentifiers contents)
  pure (awsCoordinateFindings registry scanned observedByPath symbolsByOwner)

-- | Sprint 0.28 (pure). The violation a path-scoped gate emits when one of its
-- scoped files is not in the worktree.
--
-- Every scoped gate previously answered a missing file with @pure []@, so a
-- rename silently emptied the gate's region while the gate kept passing — the
-- fail-open shape the doctrine names, applied to the gates themselves. A gate
-- that cannot find what it was told to scan has not observed compliance; it has
-- observed nothing.
scopedPathMissingViolation :: String -> FilePath -> String
scopedPathMissingViolation gateName relativePath =
  gateName
    ++ " is scoped to `"
    ++ relativePath
    ++ "`, which is not in the worktree. A scoped gate cannot silently shrink "
    ++ "its own region: update the gate's `scopedPaths` in the same change that "
    ++ "moved or deleted the file, so the region stays a stated fact rather than "
    ++ "an accident of which files happen to exist."

-- | Sprint 0.27 (pure). The Standard-H header fields a sprint block is
-- missing, given that block's body.
--
-- Every sprint in the plan is @Done@, and
-- [Standard H](../../DEVELOPMENT_PLAN/development_plan_standards.md#h-sprint-status-format)
-- makes @**Implementation**@ required for @Done@ while
-- [Standard G](../../DEVELOPMENT_PLAN/development_plan_standards.md#g-phase-documentation-requirements)
-- makes the docs field the mechanism by which "the plan must not claim a sprint
-- is done if the listed docs are stale" can be checked at all. A block carrying
-- neither states a closure that cannot be audited against source.
--
-- The predicate deliberately accepts every heading form the plan actually uses
-- — @**Implementation**:@, @**Implementation** (landed):@, and
-- @**Implementation (Increment A, 2026-07-26)**:@ — because all three name
-- paths, and a stricter rule would report a formatting difference as missing
-- evidence. That distinction is not hypothetical: the ledger row this gate
-- closes counted 19 missing @Implementation@ fields where the measured figure
-- is 11 absent outright and 4 more carrying a non-standard heading, and it
-- named Sprint @4.50@ as an example when @4.50@ does name its paths.
sprintBlockMissingFields :: String -> [String]
sprintBlockMissingFields body =
  [ name
  | name <- ["Implementation", "Docs"]
  , not (any (declaresField name) (stripFencedCodeBlocks (lines body)))
  ]
 where
  declaresField name lineText = case stripPrefix ("**" ++ name) lineText of
    Nothing -> False
    Just rest ->
      -- The heading may carry a qualifier before or after the closing `**`;
      -- what it may not do is omit the closing `**` or the colon.
      case afterClosingBold rest of
        Nothing -> False
        Just afterBold -> ':' `elem` takeWhile (/= '`') afterBold

  afterClosingBold text = case text of
    [] -> Nothing
    ('*' : '*' : remaining) -> Just remaining
    (_ : remaining) -> afterClosingBold remaining

-- | Sprint 0.27 (pure). Split a plan document into @(sprint heading, body)@
-- pairs. Exposed for unit tests.
planSprintBlocks :: String -> [(String, String)]
planSprintBlocks contents = go (lines contents) Nothing []
 where
  go [] current acc = reverse (close current acc)
  go (lineText : rest) current acc
    | "## Sprint " `isPrefixOf` lineText = go rest (Just (lineText, [])) (close current acc)
    | otherwise = case current of
        Nothing -> go rest Nothing acc
        Just (heading, collected) -> go rest (Just (heading, lineText : collected)) acc
  close Nothing acc = acc
  close (Just (heading, collected)) acc = (heading, unlines (reverse collected)) : acc

-- | The development plan's one hand-maintained execution ledger.  The plan is
-- intentionally split into detailed phase documents, but "what should a fresh
-- session do next?" has exactly one answer: the numerically ordered
-- @DEVELOPMENT_PLAN/README.md#resume-here@ table.  This pure check keeps that
-- table a projection of the sprint blocks instead of a second plan that can
-- quietly diverge from them.
--
-- The input is the repo-relative path and contents of every Markdown document
-- under @DEVELOPMENT_PLAN/@.  Keeping the check pure makes the queue grammar
-- and its failure modes directly testable; 'checkDevelopmentPlanResumeLedger'
-- is the filesystem wrapper used by the documentation gate.
developmentPlanResumeViolations :: [(FilePath, String)] -> [String]
developmentPlanResumeViolations planDocuments =
  requiredDocumentViolations
    ++ resumeHeadingViolations
    ++ competingLedgerViolations
    ++ sprintIdentityViolations
    ++ resumeParseViolations
    ++ queueShapeViolations
    ++ queueCoverageViolations
    ++ pendingOwnerViolations
 where
  requiredPaths =
    [ "DEVELOPMENT_PLAN/README.md"
    , "DEVELOPMENT_PLAN/00-overview.md"
    , "DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md"
    ]
  requiredDocumentViolations =
    [ "The development-plan resume gate cannot find `" ++ path ++ "`."
    | path <- requiredPaths
    , lookup path planDocuments == Nothing
    ]
  contentsAt path = maybe "" id (lookup path planDocuments)
  readmeContents = contentsAt "DEVELOPMENT_PLAN/README.md"
  ledgerContents = contentsAt "DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md"
  phaseDocuments =
    [ (path, contents)
    | (path, contents) <- planDocuments
    , "DEVELOPMENT_PLAN/phase-" `isPrefixOf` path
    , ".md" `isSuffixOf` path
    ]
  sprintBlocks =
    [ (path, heading, body)
    | (path, contents) <- phaseDocuments
    , (heading, body) <- planSprintBlocks (unlines (stripFencedCodeBlocks (lines contents)))
    ]
  sprintRecords =
    [ (path, sprintId, uniqueSprintStatus body)
    | (path, heading, body) <- sprintBlocks
    , Just sprintId <- [sprintIdFromHeading heading]
    ]
  allSprintIds = [sprintId | (_, sprintId, _) <- sprintRecords]
  openSprints =
    [ (sprintId, status)
    | (_, sprintId, Just status) <- sprintRecords
    , status /= "Done"
    ]

  resumeOccurrences =
    [ path
    | (path, contents) <- planDocuments
    , lineText <- stripFencedCodeBlocks (lines contents)
    , lineText == "## Resume Here"
    ]
  resumeHeadingViolations = case resumeOccurrences of
    ["DEVELOPMENT_PLAN/README.md"] -> []
    [] ->
      [ "The development plan has no `## Resume Here` ledger. "
          ++ "Define it once in `DEVELOPMENT_PLAN/README.md`."
      ]
    occurrences ->
      [ "The development plan must have exactly one `## Resume Here` ledger in "
          ++ "`DEVELOPMENT_PLAN/README.md`; found it in "
          ++ intercalate ", " (map (\path -> "`" ++ path ++ "`") occurrences)
          ++ "."
      ]

  competingLedgerHeadings =
    [ ("DEVELOPMENT_PLAN/README.md", "## Closure Status")
    , ("DEVELOPMENT_PLAN/README.md", "## Phase Overview")
    , ("DEVELOPMENT_PLAN/README.md", "## Current Plan Status")
    , ("DEVELOPMENT_PLAN/00-overview.md", "## Clean-Room Sequence")
    , ("DEVELOPMENT_PLAN/00-overview.md", "## Alignment Status")
    , ("DEVELOPMENT_PLAN/00-overview.md", "## Current Execution State")
    ]
  competingLedgerViolations =
    [ path
        ++ " retains the competing current-state ledger `"
        ++ heading
        ++ "`. Keep current execution state only in "
        ++ "`DEVELOPMENT_PLAN/README.md#resume-here`; make this section static "
        ++ "reference material or remove it."
    | (path, heading) <- competingLedgerHeadings
    , heading `elem` stripFencedCodeBlocks (lines (contentsAt path))
    ]

  duplicateSprintIds =
    [ sprintId
    | sprintId <- nub allSprintIds
    , length (filter (== sprintId) allSprintIds) > 1
    ]
  duplicateViolations =
    [ "Sprint `" ++ sprintId ++ "` is declared more than once across the phase plan."
    | sprintId <- duplicateSprintIds
    ]
  malformedHeadingViolations =
    [ path
        ++ " contains malformed sprint heading `"
        ++ heading
        ++ "`; use `## Sprint <phase>.<number>: <name>`."
    | (path, heading, _) <- sprintBlocks
    , sprintIdFromHeading heading == Nothing
    ]
  phasePrefixViolations =
    [ path
        ++ " declares Sprint `"
        ++ sprintId
        ++ "`, whose numeric prefix does not match the phase file."
    | (path, sprintId, _) <- sprintRecords
    , Just phaseNumber <- [phaseNumberFromPlanPath path]
    , takeWhile isDigit sprintId /= phaseNumber
    ]
  statusViolations =
    concat
      [ sprintStatusViolations path sprintId body
      | (path, heading, body) <- sprintBlocks
      , Just sprintId <- [sprintIdFromHeading heading]
      ]
  sprintIdentityViolations =
    malformedHeadingViolations
      ++ duplicateViolations
      ++ phasePrefixViolations
      ++ statusViolations

  (resumeParseViolations, resumeRows) = parseResumeQueue readmeContents
  queueIds = [sprintId | (_, sprintId, _, _, _) <- resumeRows]
  queueShapeViolations =
    sequentialOrderViolations resumeRows
      ++ executionOrderViolations resumeRows
      ++ nextEntryViolations resumeRows
      ++ rowPhaseViolations resumeRows
      ++ rowStateViolations openSprints resumeRows
      ++ rowDependencyViolations resumeRows
      ++ [ "The Resume Here queue repeats Sprint `" ++ sprintId ++ "`."
         | sprintId <- nub queueIds
         , length (filter (== sprintId) queueIds) > 1
         ]
      ++ queueProjectionViolations
  -- Sprint 0.32: the declared fields and the queue cells were two unrelated
  -- channels — 'checkPlanDependencyDirection' reads only phase docs and never
  -- opens the queue, and this ledger reads only the queue and never opens a
  -- dependency field.  A dependency declared in a field but absent from its
  -- queue cell therefore contributed nothing to the ordering proof, which is
  -- what makes 'executionOrderViolations' a derivation over the real graph
  -- rather than over whatever the author chose to restate.
  --
  -- Scoped to open sprints: a dependency on a `Done` sprint is not a queue row
  -- and has nothing to project onto.
  queueProjectionViolations =
    [ "The Resume Here row for Sprint `"
        ++ sprintId
        ++ "` omits dependency `"
        ++ dependencyId
        ++ "`, which its phase block declares under `**"
        ++ fieldName
        ++ "**`. The queue's order proves workability only when it carries "
        ++ "every declared dependency (Standards J/N.2)."
    | (_, heading, body) <- sprintBlocks
    , Just sprintId <- [sprintIdFromHeading heading]
    , sprintId `elem` queueIds
    , (fieldName, fieldText) <- sprintDependencyFields body
    , fieldName `elem` planDependencyFieldNames
    , dependencyId <- nub (sprintLiveDependencyIds fieldText)
    , dependencyId `elem` openIds
    , dependencyId `notElem` queueDependenciesOf sprintId
    ]
  queueDependenciesOf sprintId =
    concat
      [ dependencyIds
      | (_, rowId, _, _, dependencyIds) <- resumeRows
      , rowId == sprintId
      ]
  openIds = map fst openSprints
  queueCoverageViolations =
    [ "Open Sprint `"
        ++ sprintId
        ++ "` is missing from `DEVELOPMENT_PLAN/README.md#resume-here`."
    | sprintId <- openIds
    , sprintId `notElem` queueIds
    ]
      ++ [ "The Resume Here queue lists Sprint `"
             ++ sprintId
             ++ "`, but its phase block is not Active, Planned, or Blocked."
         | sprintId <- queueIds
         , sprintId `notElem` openIds
         ]

  pendingOwnerViolations =
    pendingRemovalOwnerViolations allSprintIds ledgerContents

-- | Parse the sole current-plan table.  A row is @(order, sprint, phase,
-- state, dependencies)@.  The intentionally small grammar keeps a human edit
-- obvious in review and makes forward dependencies impossible to disguise in
-- prose.
parseResumeQueue :: String -> ([String], [(Int, String, String, String, [String])])
parseResumeQueue contents = case markdownHeadingSections "## Resume Here" contents of
  [] -> ([], [])
  [sectionLines] -> parseTable sectionLines
  sections ->
    (
      [ "`DEVELOPMENT_PLAN/README.md` contains "
          ++ show (length sections)
          ++ " `## Resume Here` sections; exactly one is permitted."
      ]
    , []
    )
 where
  expectedHeader = ["Order", "Sprint", "Phase", "State", "Dependency"]

  parseTable sectionLines = case map markdownTableCells tableLines of
    [] ->
      (
        [ "`DEVELOPMENT_PLAN/README.md#resume-here` must contain the table "
            ++ "`Order | Sprint | Phase | State | Dependency`."
        ]
      , []
      )
    [header]
      | header /= expectedHeader ->
          (
            [ "The Resume Here table header must be exactly `Order | Sprint | Phase | "
                ++ "State | Dependency`."
            ]
          , []
          )
      | otherwise ->
          ( ["The Resume Here table is missing its Markdown separator row."]
          , []
          )
    header : separator : remaining
      | header /= expectedHeader ->
          (
            [ "The Resume Here table header must be exactly `Order | Sprint | Phase | "
                ++ "State | Dependency`."
            ]
          , []
          )
      | length separator /= length expectedHeader || not (isMarkdownSeparatorRow separator) ->
          ( ["The Resume Here table must place a Markdown separator directly below its header."]
          , []
          )
      | otherwise -> foldRows remaining
   where
    tableLines =
      [ lineText
      | lineText <- sectionLines
      , "|" `isPrefixOf` trimLine lineText
      ]

  foldRows rows =
    let parsed = zipWith parseRow [1 :: Int ..] rows
     in (concatMap fst parsed, [row | (_, Just row) <- parsed])

  parseRow rowNumber cells = case cells of
    [orderText, sprintText, phaseText, stateText, dependencyText] ->
      case parseDecimal orderText of
        Nothing ->
          (
            [ "Resume Here table row "
                ++ show rowNumber
                ++ " has non-numeric Order `"
                ++ orderText
                ++ "`."
            ]
          , Nothing
          )
        Just orderValue ->
          let sprintId = stripSingleCodeSpan sprintText
              dependencyIds =
                filter isPlanSprintId (inlineCodeSpansInLine dependencyText)
              canonicalDependencyText =
                intercalate ", " (map (\dependencyId -> "`" ++ dependencyId ++ "`") dependencyIds)
              rowViolations =
                [ "Resume Here table row "
                    ++ show rowNumber
                    ++ " has invalid Sprint `"
                    ++ sprintText
                    ++ "`; use a backtick-quoted numeric id such as `3.41`."
                | stripSingleCodeSpan sprintText == sprintText
                    || numericSprintKey sprintId == Nothing
                ]
                  ++ [ "Resume Here table row "
                         ++ show rowNumber
                         ++ " must spell dependencies exactly as `—` or as a comma-separated "
                         ++ "list of backtick-quoted sprint ids."
                     | dependencyText /= "—"
                     , dependencyText /= canonicalDependencyText
                     ]
                  ++ [ "Resume Here table row "
                         ++ show rowNumber
                         ++ " repeats dependency `"
                         ++ dependencyId
                         ++ "`."
                     | dependencyId <- nub dependencyIds
                     , length (filter (== dependencyId) dependencyIds) > 1
                     ]
           in ( rowViolations
              , Just (orderValue, sprintId, phaseText, stateText, dependencyIds)
              )
    _ ->
      (
        [ "Resume Here table row "
            ++ show rowNumber
            ++ " has "
            ++ show (length cells)
            ++ " cells; exactly five are required."
        ]
      , Nothing
      )

sequentialOrderViolations :: [(Int, String, String, String, [String])] -> [String]
sequentialOrderViolations rows =
  [ "Resume Here Order values must be consecutive starting at 1; found `"
      ++ intercalate ", " (map (show . firstOfFive) rows)
      ++ "`."
  | map firstOfFive rows /= [1 .. length rows]
  ]
 where
  firstOfFive (value, _, _, _, _) = value

-- | Sprint 0.32: the queue's order is a /derivation/ over the declared
-- dependency graph, not an authored sequence (Standards J and N.2).
--
-- Strict numerical order was the rule until 2026-08-21.  It was doing three
-- jobs: spelling Standard J's "in numerical order"; making the positional rule
-- in 'rowDependencyViolations' coincide with Standard N's numeric direction
-- rule; and making the order a function of the queue's contents, so nobody can
-- hand-promote a row to @Next@ or reorder until a dependency looks satisfied.
-- Standard N.2 gives up the second job deliberately.  This keeps the third,
-- which simply deleting the rule would have lost.
--
-- The order is: repeatedly emit the numerically smallest open sprint all of
-- whose declared dependencies are already emitted.  With no backward
-- dependency declared that is exactly ascending numerical order, so this
-- strictly generalises the rule it replaces rather than relaxing it.  A cycle
-- is the case in which no complete order exists, and is reported as itself.
executionOrderViolations :: [(Int, String, String, String, [String])] -> [String]
executionOrderViolations rows
  | length canonical /= length rows =
      [ "The Resume Here dependencies contain a cycle among `"
          ++ intercalate ", " unresolvable
          ++ "`; no row in that set can be worked first."
      ]
  | canonical /= sprintIds =
      [ "Resume Here must list open sprints in execution order, which is "
          ++ "derived from the declared dependencies rather than authored "
          ++ "(Standard J). Expected `"
          ++ intercalate " -> " canonical
          ++ "`; found `"
          ++ intercalate " -> " sprintIds
          ++ "`."
      ]
  | otherwise = []
 where
  sprintIds = [sprintId | (_, sprintId, _, _, _) <- rows]
  dependenciesOf sprintId =
    [ dependencyId
    | (_, rowId, _, _, dependencyIds) <- rows
    , rowId == sprintId
    , dependencyId <- dependencyIds
    , dependencyId `elem` sprintIds
    ]
  canonical = emit [] sprintIds
  unresolvable = filter (`notElem` canonical) sprintIds
  emit _ [] = []
  emit done pending =
    case filter ready pending of
      [] -> []
      candidates ->
        let next = foldr1 smallest candidates
         in next : emit (next : done) (filter (/= next) pending)
   where
    ready sprintId = all (`elem` done) (dependenciesOf sprintId)
    smallest left right =
      if compareSprintIds left right == GT then right else left

nextEntryViolations :: [(Int, String, String, String, [String])] -> [String]
nextEntryViolations rows =
  [ "Resume Here must mark exactly its first row `Next`; found Next at order values `"
      ++ intercalate ", " (map show nextOrders)
      ++ "`."
  | nextOrders /= [1]
  ]
 where
  nextOrders = [orderValue | (orderValue, _, _, state, _) <- rows, state == "Next"]

rowPhaseViolations :: [(Int, String, String, String, [String])] -> [String]
rowPhaseViolations rows =
  [ "Resume Here Sprint `"
      ++ sprintId
      ++ "` must name Phase `"
      ++ takeWhile isDigit sprintId
      ++ "`, not `"
      ++ phaseText
      ++ "`."
  | (_, sprintId, phaseText, _, _) <- rows
  , phaseText /= takeWhile isDigit sprintId
  ]

rowStateViolations :: [(String, String)] -> [(Int, String, String, String, [String])] -> [String]
rowStateViolations openSprints rows = concatMap checkRow rows
 where
  checkRow (_, sprintId, _, queueState, _) = case lookup sprintId openSprints of
    Nothing -> []
    Just "Blocked"
      | queueState == "Blocked" -> []
      | otherwise -> [wrongState sprintId "Blocked" queueState]
    Just "Active"
      | queueState `elem` ["Next", "Parked"] -> []
      | otherwise -> [wrongState sprintId "Next or Parked" queueState]
    Just "Planned"
      | queueState `elem` ["Next", "Parked"] -> []
      | otherwise -> [wrongState sprintId "Next or Parked" queueState]
    Just _ -> []
  wrongState sprintId expected actual =
    "Resume Here Sprint `"
      ++ sprintId
      ++ "` must have State `"
      ++ expected
      ++ "`, not `"
      ++ actual
      ++ "`."

rowDependencyViolations :: [(Int, String, String, String, [String])] -> [String]
rowDependencyViolations rows = concatMap checkRow (zip [0 :: Int ..] rows)
 where
  checkRow (rowIndex, (_, sprintId, _, queueState, dependencyIds)) =
    [ "Resume Here Sprint `"
        ++ sprintId
        ++ "` is Blocked but names no earlier dependency."
    | queueState == "Blocked"
    , null dependencyIds
    ]
      ++ [ "Resume Here Sprint `"
             ++ sprintId
             ++ "` depends on `"
             ++ dependencyId
             ++ "`, which is not an earlier row in the numerical queue."
         | dependencyId <- dependencyIds
         , dependencyId `notElem` earlierIds rowIndex
         ]
  earlierIds rowIndex =
    [ sprintId
    | (_, sprintId, _, _, _) <- take rowIndex rows
    ]

pendingRemovalOwnerViolations :: [String] -> String -> [String]
pendingRemovalOwnerViolations knownSprintIds contents =
  case markdownHeadingSections "## Pending Removal" contents of
    [sectionLines] -> checkTable sectionLines
    [] ->
      [ "`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` has no exact "
          ++ "`## Pending Removal` section."
      ]
    sections ->
      [ "`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` contains "
          ++ show (length sections)
          ++ " exact `## Pending Removal` sections; exactly one is permitted."
      ]
 where
  expectedHeader = ["Item", "Owning Sprint", "Notes"]

  checkTable sectionLines = case map markdownTableCells tableLines of
    [] ->
      [ "The Pending Removal section must contain the table "
          ++ "`Item | Owning Sprint | Notes`."
      ]
    [header]
      | header /= expectedHeader -> [wrongHeader]
      | otherwise -> ["The Pending Removal table is missing its Markdown separator row."]
    header : separator : remaining
      | header /= expectedHeader -> [wrongHeader]
      | length separator /= length expectedHeader || not (isMarkdownSeparatorRow separator) ->
          ["The Pending Removal table must place a Markdown separator directly below its header."]
      | otherwise -> concat (zipWith checkRow [1 :: Int ..] remaining)
   where
    tableLines =
      [ lineText
      | lineText <- sectionLines
      , "|" `isPrefixOf` trimLine lineText
      ]
    wrongHeader =
      "The Pending Removal table header must be exactly `Item | Owning Sprint | Notes`."

  checkRow rowNumber cells = case cells of
    [_, owner, _]
      | explicitlyUnowned owner -> []
      | otherwise ->
          let ownerSprintIds = filter isPlanSprintId (inlineCodeSpansInLine owner)
           in [ "A Pending Removal row has no sprint owner and is not explicitly "
                  ++ "`Unowned`: `"
                  ++ owner
                  ++ "`."
              | null ownerSprintIds
              ]
                ++ [ "A Pending Removal row names nonexistent Sprint `"
                       ++ sprintId
                       ++ "` as its owner. Register the sprint or mark the row "
                       ++ "explicitly `Unowned`."
                   | sprintId <- ownerSprintIds
                   , sprintId `notElem` knownSprintIds
                   ]
    _ ->
      [ "Pending Removal table row "
          ++ show rowNumber
          ++ " has "
          ++ show (length cells)
          ++ " cells; exactly three are required."
      ]

  explicitlyUnowned owner = case words (filter (/= '*') owner) of
    "Unowned" : _ -> True
    _ -> False

markdownHeadingSections :: String -> String -> [[String]]
markdownHeadingSections heading contents =
  [ takeWhile (not . ("## " `isPrefixOf`)) remaining
  | lineText : remaining <- tails (stripFencedCodeBlocks (lines contents))
  , lineText == heading
  ]

markdownTableCells :: String -> [String]
markdownTableCells lineText =
  map trimLine (dropTrailingEmpty (dropLeadingEmpty (splitMarkdownRow (trimLine lineText))))
 where
  dropLeadingEmpty ("" : rest) = rest
  dropLeadingEmpty values = values
  dropTrailingEmpty values = case reverse values of
    "" : rest -> reverse rest
    _ -> values

splitMarkdownRow :: String -> [String]
splitMarkdownRow = go [] []
 where
  go cells current [] = reverse (reverse current : cells)
  go cells current ('\\' : '|' : rest) = go cells ('|' : '\\' : current) rest
  go cells current ('|' : rest) = go (reverse current : cells) [] rest
  go cells current (character : rest) = go cells (character : current) rest

isMarkdownSeparatorRow :: [String] -> Bool
isMarkdownSeparatorRow cells =
  not (null cells)
    && all (\cell -> not (null cell) && all (`elem` ['-', ':']) cell) cells

splitOnCharacter :: Char -> String -> [String]
splitOnCharacter delimiter value = case break (== delimiter) value of
  (before, []) -> [before]
  (before, _ : after) -> before : splitOnCharacter delimiter after

parseDecimal :: String -> Maybe Int
parseDecimal value = case reads value of
  [(parsed, "")] -> Just parsed
  _ -> Nothing

stripSingleCodeSpan :: String -> String
stripSingleCodeSpan value = case value of
  '`' : rest -> case reverse rest of
    '`' : middleReversed -> reverse middleReversed
    _ -> value
  _ -> value

numericSprintKey :: String -> Maybe [Int]
numericSprintKey sprintId =
  traverse parseDecimal (splitOnCharacter '.' sprintId)

isPlanSprintId :: String -> Bool
isPlanSprintId sprintId = case break (== '.') sprintId of
  (phaseNumber, '.' : rest) ->
    not (null phaseNumber)
      && all isDigit phaseNumber
      && not (null rest)
      && all (\character -> isAlphaNum character || character == '.') rest
      && any isDigit rest
  _ -> False

sprintIdFromHeading :: String -> Maybe String
sprintIdFromHeading heading = do
  rest <- stripPrefix "## Sprint " heading
  let sprintId = takeWhile (/= ':') rest
  if isPlanSprintId sprintId then Just sprintId else Nothing

uniqueSprintStatus :: String -> Maybe String
uniqueSprintStatus body = case sprintStatusDeclarations body of
  [Just status] -> Just status
  _ -> Nothing

sprintStatusViolations :: FilePath -> String -> String -> [String]
sprintStatusViolations path sprintId body = case sprintStatusDeclarations body of
  [] -> [prefix ++ "has no `**Status**:` declaration."]
  [Nothing] ->
    [ prefix
        ++ "has an unrecognized `**Status**:` value; the leading status must be "
        ++ "Done, Active, Planned, or Blocked."
    ]
  [Just _] -> []
  declarations ->
    [ prefix
        ++ "has "
        ++ show (length declarations)
        ++ " `**Status**:` declarations; exactly one is permitted."
    ]
 where
  prefix = path ++ " Sprint `" ++ sprintId ++ "` "

sprintStatusDeclarations :: String -> [Maybe String]
sprintStatusDeclarations body =
  [ leadingSprintStatus statusText
  | lineText <- stripFencedCodeBlocks (lines body)
  , Just statusText <- [stripPrefix "**Status**:" lineText]
  ]

leadingSprintStatus :: String -> Maybe String
leadingSprintStatus statusText = case statusWords of
  status : _
    | status `elem` ["Done", "Active", "Planned", "Blocked"] -> Just status
  _ -> Nothing
 where
  statusWords =
    [ word
    | token <- words statusText
    , let word = takeWhile isAlpha (dropWhile (not . isAlpha) token)
    , not (null word)
    ]

phaseNumberFromPlanPath :: FilePath -> Maybe String
phaseNumberFromPlanPath path = do
  rest <- stripPrefix "DEVELOPMENT_PLAN/phase-" path
  let phaseNumber = takeWhile isDigit rest
  if null phaseNumber then Nothing else Just phaseNumber

-- | Filesystem wrapper for 'developmentPlanResumeViolations'.
checkDevelopmentPlanResumeLedger :: FilePath -> IO [String]
checkDevelopmentPlanResumeLedger repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let planPaths =
        [ path
        | path <- repoPaths
        , "DEVELOPMENT_PLAN/" `isPrefixOf` path
        , ".md" `isSuffixOf` path
        ]
  planDocuments <-
    forM planPaths $ \relativePath -> do
      contents <- readFileStrict (repoRoot </> relativePath)
      pure (relativePath, contents)
  pure (developmentPlanResumeViolations planDocuments)

-- | Sprint 0.27 (IO wrapper). Every sprint block in @DEVELOPMENT_PLAN/phase-*.md@
-- carries its Standard-H @Implementation@ and docs fields.
--
-- Back-filling the debt once would have left it free to recur; this is the
-- gate that makes the plan's own closure requirement mechanical, in the same
-- idiom as Sprint @0.21@'s status-value and cited-path gates directly below.
checkSprintRequiredFields :: FilePath -> IO [String]
checkSprintRequiredFields repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let planPaths =
        [ path
        | path <- repoPaths
        , "DEVELOPMENT_PLAN/phase-" `isPrefixOf` path
        , ".md" `isSuffixOf` path
        ]
  fmap concat $
    forM planPaths $ \relativePath -> do
      contents <- readFileStrict (repoRoot </> relativePath)
      pure
        [ relativePath
            ++ " "
            ++ takeWhile (/= ':') (drop 3 heading)
            ++ " is missing its Standard-H `**"
            ++ missing
            ++ "**` field. Every sprint in this plan is `Done`, and Standard H "
            ++ "requires `Implementation` for `Done` while Standard G requires the "
            ++ "docs list. Name what the sprint actually touched — never infer a "
            ++ "path, because `checkPlanCitedSourcePaths` will either fail on a "
            ++ "path that does not exist or silently point a reader at the wrong "
            ++ "module."
        | (heading, body) <- planSprintBlocks contents
        , missing <- sprintBlockMissingFields body
        ]

-- | Sprint 0.30: the two sprint-block fields in which a dependency may be
-- recorded (Standard H).
--
-- A dependency written anywhere else is invisible to this gate, which is
-- exactly how the 2026-08-17 plan-compliance audit found a queue in which no
-- row could reach @Done@ while @prodbox dev lint docs@ reported it clean: the
-- backward dependencies lived in prose, and three Active sprints declared
-- theirs under an invented field name no gate reads.
planDependencyFieldNames :: [String]
planDependencyFieldNames = ["Blocked by", "Closure dependency"]

-- | Sprint 0.31: the field in which a sprint /admits/ a backward dependency
-- already recorded in one of the two above (Standard N.2).
--
-- It records no dependency of its own.  Its whole job is to make a physical
-- backward dependency sayable: the 2026-08-21 audit found that forbidding the
-- declaration had not removed a single real dependency, it had moved four of
-- them into prose where no gate could see them — including one on the queue
-- head.  The two directions must agree, so neither an unadmitted backward
-- dependency nor an orphan admission can survive this gate.
planBackwardDependencyFieldName :: String
planBackwardDependencyFieldName = "Backward dependency"

-- | The minimum non-identifier text a `**Backward dependency**` field must
-- carry.
--
-- Standard N.2 requires one sentence naming what would be stranded.  This
-- checks that a justification was /written/, not that it is true — a bound
-- worth stating rather than implying, in the idiom of the other declaration
-- proofs in this module.
minimumBackwardDependencyJustificationChars :: Int
minimumBackwardDependencyJustificationChars = 40

-- | The sprint ids a `**Backward dependency**` field admits.
--
-- Deliberately not 'sprintLiveDependencyIds'. That function suppresses a whole
-- field when it reads as a historical resolution note, which is right for a
-- dependency field and wrong here: this field is /required/ to carry a
-- justification sentence in the same line, and a justification is ordinary
-- prose that may legitimately contain a word like @unresolved@. Running the
-- resolution scan over it would silently void the admission and let the
-- unadmitted dependency through — the same shape as the prose hole this whole
-- rule exists to close.
backwardDependencyAdmittedIds :: String -> [String]
backwardDependencyAdmittedIds = nub . sprintIdsInText . dropStruckSpans

-- | What is left of an admission once its sprint references are removed.
--
-- This proves a justification was written, not that it is true — a bound worth
-- stating rather than implying.
backwardDependencyJustification :: String -> String
backwardDependencyJustification fieldText =
  filter
    (\character -> isAlphaNum character || character == ' ')
    (foldr removeToken fieldText tokens)
 where
  tokens = "Sprints" : "Sprint" : backwardDependencyAdmittedIds fieldText
  removeToken _ [] = []
  removeToken token text@(character : rest) = case stripPrefix token text of
    Just remainder -> removeToken token remainder
    Nothing -> character : removeToken token rest

-- | Field names that look like a dependency but are not the two Standard-H
-- ones.  Named rather than pattern-matched loosely so a new spelling is a
-- deliberate addition here instead of a silent bypass.
planRejectedDependencyFieldNames :: [String]
planRejectedDependencyFieldNames =
  [ "Closure dependencies"
  , "Closure Dependency"
  , "Closure Dependencies"
  , "Depends on"
  , "Dependency"
  , "Dependencies"
  , "Waiting on"
  , "Waits on"
  , "Blocked On"
  , "Blocked on"
  , "Blocked by dependency"
  ]

-- | Sprint 0.30 (pure). Order two plan sprint ids the way the queue does:
-- phase number first, then each remaining segment numerically when it is
-- numeric and lexically otherwise, so @7.5.b.i@ sorts after @7.5.b@ and before
-- @7.6@ rather than by string comparison, which would put @7.10@ before @7.5@.
--
-- Exposed for unit tests.
compareSprintIds :: String -> String -> Ordering
compareSprintIds left right =
  compare (sprintIdSortKey left) (sprintIdSortKey right)

sprintIdSortKey :: String -> [(Int, Int, String)]
sprintIdSortKey = map segmentKey . splitOnDots
 where
  segmentKey segment = case span isDigit segment of
    ([], _) -> (1, 0, segment)
    (digits, rest) -> (0, read digits, rest)
  splitOnDots value = case break (== '.') value of
    (segment, '.' : rest) -> segment : splitOnDots rest
    (segment, _) -> [segment]

-- | Sprint 0.30 (pure). The dependency fields a sprint body declares, as
-- @(fieldName, fieldText)@, including the rejected spellings so the caller can
-- report them.  Exposed for unit tests.
sprintDependencyFields :: String -> [(String, String)]
sprintDependencyFields body =
  [ (name, fieldText)
  | lineText <- stripFencedCodeBlocks (lines body)
  , (name, fieldText) <- maybe [] pure (dependencyFieldOnLine lineText)
  ]
 where
  dependencyFieldOnLine lineText =
    case [ (name, rest)
         | name <-
             planDependencyFieldNames
               ++ [planBackwardDependencyFieldName]
               ++ planRejectedDependencyFieldNames
         , Just rest <- [stripPrefix ("**" ++ name ++ "**:") lineText]
         ] of
      -- Longest match wins so `Closure dependency` never shadows
      -- `Closure dependencies`.
      [] -> Nothing
      matches -> Just (longestFieldName matches)
  longestFieldName = foldr1 (\left right -> if length (fst left) >= length (fst right) then left else right)

-- | Sprint 0.30 (pure). The sprint ids a dependency field still asserts.
--
-- Historical lines record their own resolution in place — @~~Sprint 2.19~~
-- unblocked@, @Sprint `1.38` (closed)@, @Sprint 0.8 (...) — resolved@ — and
-- those are statements that the dependency is gone, not live dependencies. A
-- struck span is dropped outright; a parenthetical or dash-introduced
-- resolution note drops the ids it annotates. @none@ yields no ids.
--
-- Exposed for unit tests.
sprintLiveDependencyIds :: String -> [String]
sprintLiveDependencyIds fieldText
  | resolvedInPlace = []
  | otherwise = sprintIdsInText withoutStruck
 where
  withoutStruck = dropStruckSpans fieldText
  lowered = map toLower withoutStruck
  resolvedInPlace =
    any
      (`isInfixOf` lowered)
      ["(closed)", "(satisfied", "(all closed)", "(now done", "resolved", "unblocked", "n/a"]

dropStruckSpans :: String -> String
dropStruckSpans = go
 where
  go [] = []
  go ('~' : '~' : rest) = go (drop 2 (dropWhileNotStrike rest))
  go (character : rest) = character : go rest
  dropWhileNotStrike [] = []
  dropWhileNotStrike ('~' : '~' : rest) = '~' : '~' : rest
  dropWhileNotStrike (_ : rest) = dropWhileNotStrike rest

-- | Every @Sprint N.M@ / @Sprint `N.M`@ / @Sprint-`N.M`@ id in a fragment.
sprintIdsInText :: String -> [String]
sprintIdsInText = go
 where
  go [] = []
  go text@(_ : rest) = case stripPrefix "Sprint" text of
    Just afterKeyword ->
      let afterSeparator = dropWhile (\character -> character `elem` (" -s" :: String)) afterKeyword
          candidate =
            takeWhile
              (\character -> isAlphaNum character || character == '.')
              (dropWhile (== '`') afterSeparator)
          trimmed = dropTrailingDots candidate
       in if isPlanSprintId trimmed
            then trimmed : go rest
            else go rest
    Nothing -> go rest
  dropTrailingDots value = reverse (dropWhile (== '.') (reverse value))

-- | Sprint 0.30 (pure). Standard N, made mechanical over the declared fields.
--
-- Two violations: a live dependency that sorts later than the sprint declaring
-- it, and a dependency-shaped field this gate cannot read. Exposed for unit
-- tests.
sprintDependencyDirectionViolations :: [(FilePath, String)] -> [String]
sprintDependencyDirectionViolations planDocuments =
  concat
    [ fieldViolations path sprintId body
    | (path, contents) <- planDocuments
    , "DEVELOPMENT_PLAN/phase-" `isPrefixOf` path
    , ".md" `isSuffixOf` path
    , (heading, body) <- planSprintBlocks contents
    , Just sprintId <- [sprintIdFromHeading heading]
    ]
 where
  fieldViolations path sprintId body =
    concat
      [ fieldViolation path sprintId admitted name fieldText
      | (name, fieldText) <- dependencyFields
      ]
      ++ admissionViolations path sprintId dependencyFields backwardFields
   where
    allFields = sprintDependencyFields body
    dependencyFields =
      [field | field@(name, _) <- allFields, name /= planBackwardDependencyFieldName]
    backwardFields =
      [field | field@(name, _) <- allFields, name == planBackwardDependencyFieldName]
    admitted = concatMap (backwardDependencyAdmittedIds . snd) backwardFields

  fieldViolation path sprintId admitted name fieldText
    | name `elem` planRejectedDependencyFieldNames =
        [ path
            ++ " Sprint `"
            ++ sprintId
            ++ "` records a dependency under `**"
            ++ name
            ++ "**`, which is not a Standard-H dependency field. Use `**Blocked by**` "
            ++ "or `**Closure dependency**`; a dependency under any other name is "
            ++ "invisible to this gate, which is how a backward dependency last "
            ++ "reached the queue undetected (Standard N)."
        ]
    | otherwise =
        [ path
            ++ " Sprint `"
            ++ sprintId
            ++ "` declares `**"
            ++ name
            ++ "**: Sprint `"
            ++ dependencyId
            ++ "``, which is a later sprint, and does not admit it under `**"
            ++ planBackwardDependencyFieldName
            ++ "**`. Standard N.2 permits a backward dependency only when it is "
            ++ "physical — the deliverable would destroy, strand, or leave "
            ++ "unreplaced something only Sprint `"
            ++ dependencyId
            ++ "` supplies — and only when this block says so in that field. "
            ++ "Otherwise re-scope this sprint so its owned surface is validatable "
            ++ "now, or state the later work as a disclaimer rather than a "
            ++ "dependency."
        | dependencyId <- sprintLiveDependencyIds fieldText
        , compareSprintIds dependencyId sprintId == GT
        , dependencyId `notElem` admitted
        ]

  -- The other direction of the bijection: an admission with nothing to admit,
  -- an admission of a sprint that is not later, and an admission carrying no
  -- justification are each their own defect.
  admissionViolations path sprintId dependencyFields backwardFields =
    concat
      [ orphanViolation path sprintId declaredId
      | declaredId <- concatMap (backwardDependencyAdmittedIds . snd) backwardFields
      , declaredId `notElem` declaredDependencyIds
      ]
      ++ concat
        [ notLaterViolation path sprintId declaredId
        | declaredId <- concatMap (backwardDependencyAdmittedIds . snd) backwardFields
        , compareSprintIds declaredId sprintId /= GT
        ]
      ++ concat
        [ justificationViolation path sprintId
        | (_, fieldText) <- backwardFields
        , not (null (backwardDependencyAdmittedIds fieldText))
        , length (backwardDependencyJustification fieldText)
            < minimumBackwardDependencyJustificationChars
        ]
   where
    declaredDependencyIds =
      concatMap (sprintLiveDependencyIds . snd) dependencyFields

  orphanViolation path sprintId declaredId =
    [ path
        ++ " Sprint `"
        ++ sprintId
        ++ "` admits Sprint `"
        ++ declaredId
        ++ "` under `**"
        ++ planBackwardDependencyFieldName
        ++ "**`, but no `**Blocked by**` or `**Closure dependency**` field names "
        ++ "it. An admission with nothing to admit is a claim nothing can "
        ++ "consume (Standard N.2)."
    ]

  notLaterViolation path sprintId declaredId =
    [ path
        ++ " Sprint `"
        ++ sprintId
        ++ "` admits Sprint `"
        ++ declaredId
        ++ "` under `**"
        ++ planBackwardDependencyFieldName
        ++ "**`, which is not a later sprint. Only a backward dependency needs "
        ++ "admitting; a forward one is the default and must not be declared "
        ++ "here (Standard N.2)."
    ]

  justificationViolation path sprintId =
    [ path
        ++ " Sprint `"
        ++ sprintId
        ++ "` admits a backward dependency under `**"
        ++ planBackwardDependencyFieldName
        ++ "**` without a justification. Standard N.2 requires one sentence "
        ++ "naming what would be destroyed, stranded, or left unreplaced without "
        ++ "the later sprint."
    ]

-- | Sprint 0.30 (pure). The ledger's declarable prerequisite direction
-- (Standard I).
--
-- A @Pending Removal@ row whose removal waits on a later sprint is a blocked
-- earlier phase wearing a ledger row: nobody in the queue can close it. The
-- row is re-owned to that sprint instead. Exposed for unit tests.
pendingRemovalPrerequisiteViolations :: String -> [String]
pendingRemovalPrerequisiteViolations contents =
  case markdownHeadingSections "## Pending Removal" contents of
    [sectionLines] -> concat (zipWith checkRow [1 :: Int ..] (dataRows sectionLines))
    _ -> []
 where
  dataRows sectionLines =
    drop
      2
      [ cells
      | lineText <- sectionLines
      , "|" `isPrefixOf` trimLine lineText
      , let cells = markdownTableCells lineText
      ]
  checkRow rowNumber cells = case cells of
    [_, ownerCell, notesCell] ->
      [ "`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` Pending Removal row "
          ++ show rowNumber
          ++ " is owned by Sprint `"
          ++ ownerId
          ++ "` but declares `**Prerequisite**: Sprint `"
          ++ prerequisiteId
          ++ "``, a later sprint. Re-own the row to Sprint `"
          ++ prerequisiteId
          ++ "`; a row whose prerequisite lands after its owner closes has no "
          ++ "scheduled remover (Standards I/N)."
      | ownerId <- take 1 (sprintIdsInText ownerCell)
      , prerequisiteId <- prerequisiteIdsInNotes notesCell
      , compareSprintIds prerequisiteId ownerId == GT
      ]
    _ -> []
  prerequisiteIdsInNotes notesCell =
    concat
      [ take 1 (sprintIdsInText fragment)
      | fragment <- prerequisiteFragments notesCell
      ]
  prerequisiteFragments notesCell = go notesCell
   where
    go [] = []
    go text@(_ : rest) = case stripPrefix "**Prerequisite**:" text of
      Just after -> take 64 after : go rest
      Nothing -> go rest

-- | Sprint 0.30 (IO wrapper). Standard-N dependency direction over the plan
-- documents and the deletion ledger.
checkPlanDependencyDirection :: FilePath -> IO [String]
checkPlanDependencyDirection repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let planPaths =
        [ path
        | path <- repoPaths
        , "DEVELOPMENT_PLAN/" `isPrefixOf` path
        , ".md" `isSuffixOf` path
        ]
  planDocuments <-
    forM planPaths $ \relativePath -> do
      contents <- readFileStrict (repoRoot </> relativePath)
      pure (relativePath, contents)
  let ledgerContents =
        maybe "" id (lookup "DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md" planDocuments)
  pure
    ( sprintDependencyDirectionViolations planDocuments
        ++ pendingRemovalPrerequisiteViolations ledgerContents
    )

-- | Sprint 0.21 (IO wrapper). The cited-source-path existence check over
-- @DEVELOPMENT_PLAN/@ — the mechanical form of the evidence sweep that has
-- repeatedly found real defects by hand (Sprints @4.51@, @4.53@, @5.18@,
-- @5.23@ each recorded a closure whose cited evidence did not exist).
--
-- A sprint may only claim @Done@ on evidence a reader can open, so a plan
-- document that cites a module which is not in the worktree fails the
-- build unless the path is a declared historical retirement.
checkPlanCitedSourcePaths :: FilePath -> IO [String]
checkPlanCitedSourcePaths repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let governedPaths =
        [ path
        | path <- repoPaths
        , citedSourcePathRegion path
        , ".md" `isSuffixOf` path
        ]
  fmap concat $
    forM governedPaths $ \relativePath -> do
      contents <- readFileStrict (repoRoot </> relativePath)
      let candidates =
            [ cited
            | cited <- citedSourcePathsInDoc contents
            , cited `notElem` retiredCitedSourcePaths
            ]
      missingPaths <-
        filterM (fmap not . doesFileExist . (repoRoot </>)) candidates
      pure
        [ relativePath
            ++ " cites source path `"
            ++ missingPath
            ++ "`, which does not exist in the worktree. Correct the citation, or add "
            ++ "the path to `retiredCitedSourcePaths` naming the sprint that removed it ("
            ++ citedSourcePathStandard relativePath
            ++ ")."
        | missingPath <- missingPaths
        ]

-- | Sprint 0.31. The region this check guarantees over. It was
-- @DEVELOPMENT_PLAN/@ only from Sprint 0.21 until 2026-08-20, which left the
-- 44 governed documents under @documents/@ free to cite modules that do not
-- exist -- and two of them did. A gate guarantees things over a region, and
-- the region is what the enumeration selects.
citedSourcePathRegion :: FilePath -> Bool
citedSourcePathRegion path =
  "DEVELOPMENT_PLAN/" `isPrefixOf` path || "documents/" `isPrefixOf` path

-- | The standard a citation refusal cites, which differs by region: the plan
-- suite answers to Standard C, and a governed document to the revision-scoped
-- claims rule.
citedSourcePathStandard :: FilePath -> String
citedSourcePathStandard relativePath
  | "documents/" `isPrefixOf` relativePath =
      "documentation_standards.md " ++ sectionTwelveLabel ++ ": a cited artifact must resolve"
  | otherwise =
      "development_plan_standards.md Standard C: status must describe reality"

-- | Spelled once so the section number is not restated at each refusal site.
sectionTwelveLabel :: String
sectionTwelveLabel = "section 12"

-- | Sprint 0.22 (pure). The section numbers a document actually defines, read
-- from its headings. The grammar is uniform across the doctrine set:
-- @## 7. Title@, @### 3.1 Title@, @## 2C. Title@, @### 5a.1. Title@.
-- Exposed for unit tests.
documentSectionNumbers :: String -> [String]
documentSectionNumbers contents =
  dedupeSorted
    [ number
    | lineText <- stripFencedCodeBlocks (lines contents)
    , Just number <- [headingSectionNumber lineText]
    ]

-- | Sprint 0.22 (pure). The section number a heading line declares, if any.
-- Exposed for unit tests.
headingSectionNumber :: String -> Maybe String
headingSectionNumber lineText =
  case span (== '#') lineText of
    ([], _) -> Nothing
    (_, afterHashes)
      | not (startsWithSpace afterHashes) -> Nothing
      | otherwise ->
          let body = dropWhile (== '*') (trimLeft afterHashes)
              token = takeWhile isSectionNumberChar body
              rest = drop (length token) body
              trimmed = dropTrailingDot token
           in case trimmed of
                (firstChar : _) | isDigit firstChar && validSectionRest rest -> Just trimmed
                _ -> Nothing
 where
  startsWithSpace (c : _) = c == ' '
  startsWithSpace [] = False
  validSectionRest rest = case rest of
    [] -> True
    (c : _) -> isSpace c

-- | Sprint 0.22 (pure). Characters legal inside a section number.
isSectionNumberChar :: Char -> Bool
isSectionNumberChar c = isDigit c || isAlpha c || c == '.'

-- | Sprint 0.22 (pure). Drop one trailing @.@ from a heading's number token.
dropTrailingDot :: String -> String
dropTrailingDot token
  | not (null token) && last token == '.' = init token
  | otherwise = token

-- | Sprint 0.22 (pure). Section citations on one line that are LEXICALLY BOUND
-- to a named document — a @doc.md@ token close enough before the @\<section\>@
-- marker that the pairing is unambiguous. Returns @(docBasename, number)@ pairs.
--
-- Bare citations are deliberately not returned. 937 of them exist, and the
-- obvious "a bare number in a markdown file means this file" heuristic
-- false-positives at 29%, because the plan documents narrate about doctrine
-- across whole paragraphs. Under-covering is the correct failure mode here.
--
-- Rejected on purpose: a gap containing a letter, @;@ or @.@ (the doc named is
-- then something else — @[README.md](…); §4.1@ is a self-reference, not a
-- README one); a number of three or more digits (a line-number convention used
-- in four phase files); and an external-standard citation such as @RFC 6455
-- §1.3@. Exposed for unit tests.
boundSectionCitationsInLine :: String -> [(String, String)]
boundSectionCitationsInLine rawLine = go (stripHaddockMarkup rawLine) ""
 where
  go [] _ = []
  go ('\167' : rest) seen =
    let afterMarkers = dropWhile (\c -> c == '\167' || c == ' ') rest
        number = dropTrailingDot (takeWhile isSectionNumberChar afterMarkers)
        remaining = drop (length (takeWhile isSectionNumberChar afterMarkers)) afterMarkers
     in case boundDocumentName seen of
          Just doc
            | plausibleSectionNumber number
            , not (externalStandardCitation seen) ->
                (doc, number) : go remaining ('\167' : seen)
          _ -> go remaining ('\167' : seen)
  go (c : rest) seen = go rest (c : seen)

-- | Sprint 0.22 (pure). Is a citation's number plausibly a section rather than
-- a line number? Three or more leading digits is the line-number convention.
plausibleSectionNumber :: String -> Bool
plausibleSectionNumber number = case number of
  (firstChar : _) -> isDigit firstChar && length (takeWhile isDigit number) < 3
  [] -> False

-- | Sprint 0.22 (pure). Was the text immediately before the marker an external
-- standard rather than a repository document? @seen@ is reversed.
externalStandardCitation :: String -> Bool
externalStandardCitation seen =
  -- @seen@ is reversed, so an "RFC 6455 " prefix arrives as " 5546 CFR".
  -- Drop the reversed standard number and spaces, then match the reversed tag.
  let afterNumber = dropWhile (\c -> isDigit c || isSpace c || c == '.') seen
   in any (`isPrefixOf` map toLower afterNumber) ["cfr", "osi", "tsin"]

-- | Sprint 0.22 (pure). Strip Haddock code-span and escape markup so
-- @\@…md \<section\> 3\@@ tokenizes as a plain citation. Exposed for unit tests.
stripHaddockMarkup :: String -> String
stripHaddockMarkup = filter (\c -> c /= '@' && c /= '\\')

-- | Sprint 0.22 (pure). Read the document basename bound to a marker, given the
-- REVERSED text preceding it. The gap between the @.md@ token and the marker
-- must contain no letter, @;@ or @.@.
boundDocumentName :: String -> Maybe String
boundDocumentName seen =
  let gap = takeWhile (/= 'd') (take 8 seen)
   in if any (\c -> isAlpha c || c == ';' || c == '.') gap
        then Nothing
        else case stripPrefix' "dm." (drop (length gap) seen) of
          Nothing -> Nothing
          Just afterSuffix ->
            let nameRev = takeWhile (\c -> isAlphaNum c || c == '_' || c == '-') afterSuffix
             in if null nameRev then Nothing else Just (reverse nameRev ++ ".md")
 where
  stripPrefix' p s = if p `isPrefixOf` s then Just (drop (length p) s) else Nothing

-- | Sprint 0.22 (IO). Every bound section citation resolves to a heading that
-- exists in the document it names.
--
-- This is the doctrine analogue of 'checkPlanCitedSourcePaths'. It scans the
-- whole tree rather than only @DEVELOPMENT_PLAN\/@, because @CheckCode.hs@ is
-- itself among the heaviest citing files and ~25 sites emit section citations
-- into operator-facing output, where they are least likely to be proofread. A
-- broken citation has already shipped inside a @dev check@ error message once.
--
-- A citation naming a document that is not in this repository is skipped: some
-- doctrine deliberately cites an absolute path into a sibling repository.
checkDoctrineSectionCitations :: FilePath -> IO [String]
checkDoctrineSectionCitations repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let docPaths = [path | path <- repoPaths, ".md" `isSuffixOf` path]
      scanPaths =
        [ path
        | path <- repoPaths
        , ".md" `isSuffixOf` path || ".hs" `isSuffixOf` path
        ]
  sectionsByDoc <-
    forM docPaths $ \path -> do
      contents <- readFileStrict (repoRoot </> path)
      pure (takeFileNameSimple path, documentSectionNumbers contents)
  let lookupSections basename =
        [ numbers
        | (name, numbers) <- sectionsByDoc
        , name == basename
        ]
  fmap concat $
    forM scanPaths $ \relativePath -> do
      contents <- readFileStrict (repoRoot </> relativePath)
      pure
        [ relativePath
            ++ " cites `"
            ++ doc
            ++ " section "
            ++ number
            ++ "`, which is not a heading in that document (documentation_standards.md § 4)."
        | lineText <- stripFencedCodeBlocks (lines contents)
        , (doc, number) <- boundSectionCitationsInLine lineText
        , numbers <- take 1 (lookupSections doc)
        , number `notElem` numbers
        ]

-- | Sprint 0.22 (pure). The final path component. Total.
takeFileNameSimple :: FilePath -> String
takeFileNameSimple = reverse . takeWhile (/= '/') . reverse

-- | Sprint 4.84 (pure). Join the typed lifecycle registry
-- ('managedResourceRegistry') to the flat name\/class inventory
-- ('resourceLifecycleClasses') that the generated documentation and the
-- per-run delete guard are both derived from.
--
-- The two tables are different shapes for a reason — the typed one carries
-- keys, kinds, coordinates, and capability requirements; the flat one is the
-- documentation SSoT and the name-keyed guard — but a resource's *lifecycle
-- class* must be the same fact in both. Before this check they could
-- disagree silently, which is exactly how the two EBS families came to share
-- one @aws-ebs-volumes :: LongLived@ row in the flat table while the typed
-- registry had already split them: the flat table then said the test-scoped
-- family was retained, and the runtime tag set was left to disagree with it.
--
-- Both directions fail:
--
--   * a typed descriptor whose key names no row in the flat inventory, and
--   * a typed descriptor whose flat row carries a different class.
--
-- The reverse direction (a flat row with no typed descriptor) is deliberately
-- not a violation: the flat inventory also registers non-AWS-resource
-- identities — Pulsar topic families, the superseded Harbor release, the
-- retained public-edge certificate, the operational credentials — that the
-- typed teardown registry does not own.
-- | Sprint 4.85: which flat inventory rows deliberately have no typed
-- teardown descriptor, and why.
--
-- 'managedResourceRegistryParityViolations' joins typed -> flat, which cannot
-- see a flat row the typed registry never registered. That is exactly how the
-- @dns-aws@ validation hosted zone stayed out of the compiled desired-absence
-- program while being registered, swept by the harness, and billable: nothing
-- asked which flat rows had no descriptor, so its omission read like a
-- decision. Every row here is now a stated decision, and a new flat row is a
-- build failure until someone makes one.
untypedLifecycleInventoryExemptions :: [(String, String)]
untypedLifecycleInventoryExemptions =
  [
    ( "pulsar-topics-per-run"
    , "a dynamic broker-topic family whose concrete members are produced by "
        ++ "the typed topic algebra at run time, not a registrable coordinate"
    )
  ,
    ( "pulsar-topics-long-lived"
    , "the long-lived half of the same dynamic topic family"
    )
  ,
    ( "legacy-harbor-helm-release"
    , "a superseded Helm release with no desired-present path; its removal "
        ++ "owner is the chart platform, not the teardown registry"
    )
  ,
    ( "aws-ses"
    , "the long-lived SES stack, whose teardown is operator-explicit and whose "
        ++ "typed descriptor lands with the Sprint 7.36 AWS adapters"
    )
  ,
    ( "public-edge-tls"
    , "retained S3 object material rather than a provider resource; destroyed "
        ++ "transitively by the long-lived bucket destroy"
    )
  ,
    ( "operational-aws-ses-lease-role"
    , "the pre-cutover operational identity, whose successor is declared: the "
        ++ "fixed session role becomes the registered provider role that "
        ++ "prodbox-lifecycle-provider assumes. Registering it as a typed "
        ++ "teardown descriptor would make a superseded identity a target of "
        ++ "the supported registry; its removal is deletion-ledger work"
    )
  ,
    ( "operational-iam-user"
    , "the pre-cutover operational identity, superseded by "
        ++ "prodbox-lifecycle-provider; see the SES lease role row"
    )
  ,
    ( "operational-aws-config"
    , "the pre-cutover operational aws.* block, superseded by generated "
        ++ "non-secret configuration rather than by any credential; see the "
        ++ "SES lease role row"
    )
  ]

-- | Join flat -> typed. The reverse direction of
-- 'managedResourceRegistryParityViolations'.
untypedLifecycleInventoryViolations :: [String]
untypedLifecycleInventoryViolations =
  [ violation
  | (name, _) <- resourceLifecycleClasses
  , name `notElem` typedNames
  , violation <- missingExemption name
  ]
    ++ [ "`"
           ++ name
           ++ "` is exempted from the typed teardown registry in "
           ++ "Prodbox.CheckCode.untypedLifecycleInventoryExemptions, but it is "
           ++ "registered there now; delete the stale exemption."
       | (name, _) <- untypedLifecycleInventoryExemptions
       , name `elem` typedNames
       ]
 where
  typedNames =
    [ Text.unpack (registeredResourceKeyText (managedResourceKey descriptor))
    | SomeManagedResourceDescriptor descriptor <- managedResourceRegistry
    ]
  missingExemption name
    | any ((== name) . fst) untypedLifecycleInventoryExemptions = []
    | otherwise =
        [ "`"
            ++ name
            ++ "` is registered in resourceLifecycleClasses but has no typed "
            ++ "teardown descriptor, so compileDesiredAbsenceProgram emits no "
            ++ "node for it and no compiled cleanup program can reach it. "
            ++ "Register it in Prodbox.Lifecycle.Teardown.Registry, or state "
            ++ "why it cannot be in "
            ++ "Prodbox.CheckCode.untypedLifecycleInventoryExemptions."
        ]

-- | Sprint 4.85: join the closed pre-cutover operational resource enumeration
-- to the @Operational@ rows of the flat lifecycle inventory.
--
-- @LegacyOperationalResource@ is what carries each legacy name's declared
-- successor, and 'legacyOperationalIdentityStatus' — the source
-- @LegacyOperationalIdentityReplacementUndefined@ is derived from — is a
-- statement about that enumeration being complete. An enumeration that had
-- silently lost a row would report "every legacy resource has a successor"
-- while a real one went unanswered, which is the same defect the disposition
-- blockers exist to prevent.
legacyOperationalResourceParityViolations :: [String]
legacyOperationalResourceParityViolations =
  [ "`"
      ++ name
      ++ "` is an Operational row in resourceLifecycleClasses but is not a "
      ++ "LegacyOperationalResource, so no declared successor exists for it "
      ++ "and legacyOperationalIdentityStatus would report the migration "
      ++ "defined while it is not. Add it to "
      ++ "Prodbox.Lifecycle.Teardown.OperationalCredentialInventory."
  | name <- resourceNamesOfClass Operational
  , name `notElem` legacyNames
  ]
    ++ [ "`"
           ++ name
           ++ "` is a LegacyOperationalResource but has no Operational row in "
           ++ "resourceLifecycleClasses; the enumeration is describing a "
           ++ "resource the repository no longer registers."
       | name <- legacyNames
       , name `notElem` resourceNamesOfClass Operational
       ]
 where
  legacyNames =
    map
      (Text.unpack . legacyOperationalResourceName)
      legacyOperationalResources

-- | Join the typed teardown registry to the production registered-target
-- interpreter.
--
-- Registering a managed descriptor makes @compileDesiredAbsenceProgram@ emit a
-- mandatory absence read-back for it, and a surface that mints completion
-- evidence is asserting every mandatory read-back succeeded. A descriptor with
-- no production executor therefore does not merely fail to be swept: it makes
-- that surface's completion structurally unreachable, and the failing node
-- reads like infrastructure that refused to go away.
--
-- The gap itself is not a violation — 'registeredTargetExecutorFor' records it
-- as a typed value with a named owner. What is a violation is a gap on a
-- surface that can claim completion, which is why this joins the executor
-- answer to 'cleanupSurfaceAllows' and
-- 'cleanupSurfaceMintsCompletionEvidence' rather than reading an authored
-- exemption list. A stale exemption is not possible here: there is one total
-- function, so a key that gains an executor stops being reported by
-- construction.
registeredTargetExecutorViolations :: [String]
registeredTargetExecutorViolations =
  concatMap descriptorViolations managedResourceRegistry
 where
  descriptorViolations someDescriptor@(SomeManagedResourceDescriptor descriptor) =
    case registeredTargetExecutorFor (managedResourceKey descriptor) of
      Right _ -> []
      Left unexecutable ->
        [ violation someDescriptor unexecutable surface
        | surface <- [minBound .. maxBound] :: [CleanupSurface]
        , cleanupSurfaceMintsCompletionEvidence surface
        , cleanupSurfaceAllows surface (RegisteredManagedResource someDescriptor)
        ]
  violation (SomeManagedResourceDescriptor descriptor) unexecutable surface =
    "`"
      ++ Text.unpack (registeredResourceKeyText (managedResourceKey descriptor))
      ++ "` is registered in Prodbox.Lifecycle.Teardown.Registry and projects "
      ++ "onto the "
      ++ show surface
      ++ " cleanup surface, which mints completion evidence — but "
      ++ Text.unpack
        ( unexecutableRegisteredTargetDetail
            (managedResourceKey descriptor)
            unexecutable
        )
      ++ ". The compiled program's mandatory absence read-back for this target "
      ++ "can never succeed, so that surface can never report completion. "
      ++ "Build the adapter, or do not register the descriptor until the "
      ++ "sprint that owns the adapter lands it."

-- | Every controller-owned registered family must have exactly one owning
-- registered stack, and every derived ownership edge must name a registered
-- @Stack@.
--
-- The relation is derived from two registry coordinates rather than authored
-- (see 'registeredOwnershipEdges'), so a wrong owner is no longer
-- representable. What remains representable is a family whose ownership tag
-- names a cluster no registered stack provisions — which produces no edge at
-- all, and an absent edge is indistinguishable at the edge list from a family
-- that genuinely has no controller owner. That is the case this reports.
ownershipEdgeDerivationViolations :: [String]
ownershipEdgeDerivationViolations =
  [ "`"
      ++ Text.unpack (registeredResourceKeyText resourceKey)
      ++ "` declares controller owner cluster `"
      ++ Text.unpack ownerCluster
      ++ "` but no registered stack's provisioning program yields that cluster "
      ++ "name, so it has no owning stack: no write-ahead ownership manifest "
      ++ "may contain it and no destroy order can be derived for it. Register "
      ++ "the owning stack in Prodbox.Lifecycle.Teardown.Registry, or correct "
      ++ "the family's cluster ownership tag."
  | (resourceKey, ownerCluster) <- controllerOwnedFamiliesWithoutRegisteredStack
  ]
    ++ [ "the derived ownership edge `"
           ++ Text.unpack (registeredResourceKeyText (ownershipEdgeStackKey edge))
           ++ "` -> `"
           ++ Text.unpack (registeredResourceKeyText (ownershipEdgeResourceKey edge))
           ++ "` names an owner that is not a registered Stack descriptor; a "
           ++ "controller owner is a stack whose program declares the cluster."
       | edge <- registeredOwnershipEdges
       , ownershipEdgeStackKey edge `notElem` registeredStackKeys
       ]
 where
  registeredStackKeys =
    [ managedResourceKey descriptor
    | SomeManagedResourceDescriptor descriptor <- managedResourceRegistry
    , managedResourceKind descriptor == Stack
    ]

managedResourceRegistryParityViolations :: [String]
managedResourceRegistryParityViolations =
  concatMap descriptorViolations managedResourceRegistry
 where
  descriptorViolations (SomeManagedResourceDescriptor descriptor) =
    let name = Text.unpack (registeredResourceKeyText (managedResourceKey descriptor))
        registered = managedResourceLifecycleClass descriptor
     in case lookup name resourceLifecycleClasses of
          Nothing ->
            [ "the typed lifecycle registry registers `"
                ++ name
                ++ "` but resourceLifecycleClasses has no row for it; add it to "
                ++ "src/Prodbox/Lifecycle/ResourceClass.hs "
                ++ "(lifecycle_reconciliation_doctrine.md §3.1 totality)."
            ]
          Just flatClass
            | flatClass == registered -> []
            | otherwise ->
                [ "`"
                    ++ name
                    ++ "` is "
                    ++ show registered
                    ++ " in the typed lifecycle registry but "
                    ++ show flatClass
                    ++ " in resourceLifecycleClasses; a resource has exactly one "
                    ++ "static lifecycle class (lifecycle_reconciliation_doctrine.md §3.1)."
                ]

checkCreateCallSiteCoverage :: FilePath -> IO [String]
checkCreateCallSiteCoverage repoRoot = do
  let registeredNames =
        resourceNamesOfClass PerRun ++ resourceNamesOfClass LongLived
  commandContents <- readFileStrict (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Command.hs")
  let pulumiViolations = pulumiCreateSiteViolations registeredNames commandContents
  repoPaths <- listRepoOwnedPaths repoRoot
  awsViolations <-
    concat
      <$> forM
        [ path
        | path <- repoPaths
        , "src/Prodbox/" `isPrefixOf` path
        , ".hs" `isSuffixOf` path
        , path /= "src/Prodbox/CheckCode.hs"
        ]
        ( \relativePath -> do
            contents <- readFileStrict (repoRoot </> relativePath)
            pure (awsCreateSiteViolations relativePath contents)
        )
  pure (pulumiViolations ++ awsViolations)

-- | The explicit map from a Pulumi stack-creation constructor name to
-- the registered stack name it provisions. Every entry's value must be
-- present in 'resourceLifecycleClasses' (enforced by
-- 'pulumiCreateSiteViolations'). Adding a new @Pulumi<Word>Resources@
-- constructor without a matching entry here fails the lint. Exposed for
-- unit tests; consumed by 'pulumiCreateSiteViolations'.
pulumiCreateSiteOwners :: [(String, String)]
pulumiCreateSiteOwners =
  [ ("PulumiEksResources", "aws-eks")
  , ("PulumiTestResources", "aws-test")
  , ("PulumiAwsSubzoneResources", "aws-eks-subzone")
  , ("PulumiAwsSesResources", "aws-ses")
  ]

-- | Sprint 4.22 follow-on (pure). Given the registered resource names
-- (from the registry) and the contents of @CLI/Command.hs@, emit a
-- violation for any Pulumi stack-creation constructor that is not
-- covered by the registry.
--
-- A stack-creation site is any token of the shape @Pulumi<Word>Resources@
-- (starts with @"Pulumi"@, ends with @"Resources"@). Two failure modes:
--
--   * a creation constructor with no entry in 'pulumiCreateSiteOwners'
--     (an unregistered create site), and
--   * a mapped constructor whose stack name is absent from the supplied
--     registered names (the registry lost the entry).
pulumiCreateSiteViolations :: [String] -> String -> [String]
pulumiCreateSiteViolations registeredNames commandContents =
  unregisteredConstructorViolations ++ missingRegistryViolations
 where
  creationConstructors =
    dedupeSorted
      [ token
      | token <- tokenizeSource commandContents
      , "Pulumi" `isPrefixOf` token
      , "Resources" `isSuffixOf` token
      ]
  unregisteredConstructorViolations =
    [ constructorName
        ++ " is a Pulumi stack-creation site with no registered managed resource; "
        ++ "add its stack to resourceLifecycleClasses and pulumiCreateSiteOwners "
        ++ "(lifecycle_reconciliation_doctrine.md §3.1 totality)."
    | constructorName <- creationConstructors
    , constructorName `notElem` map fst pulumiCreateSiteOwners
    ]
  missingRegistryViolations =
    [ constructorName
        ++ " maps to Pulumi stack `"
        ++ stackName
        ++ "`, which is not in the managed-resource registry; add `"
        ++ stackName
        ++ "` to resourceLifecycleClasses (lifecycle_reconciliation_doctrine.md §3.1 totality)."
    | (constructorName, stackName) <- pulumiCreateSiteOwners
    , constructorName `elem` creationConstructors
    , stackName `notElem` registeredNames
    ]

-- | Sprint 4.27: the AWS-resource creation verbs the create-site lint
-- covers, each paired with the owner module(s) where the create call
-- site is sanctioned (because the created resource is a registered
-- managed resource). Generalizes the Sprint 4.22 IAM-only
-- @iamCreateVerbs@ to every AWS-resource create call site:
--
--   * @create-user@ \/ @put-user-policy@ — the @operational-iam-user@
--     owner module @src/Prodbox/Aws.hs@.
--   * @create-role@ \/ @put-role-policy@ — the fixed operational SES
--     lease-role owner @src/Prodbox/Infra/AwsSesLeaseRole.hs@.
--   * @create-access-key@ — either that operational-user owner or the
--     lease/fence-guarded SES SMTP-key owner
--     @src/Prodbox/Infra/AwsSesSmtpKey.hs@.
--   * @create-bucket@ — the long-lived @pulumi_state_backend@ bucket
--     owner @src/Prodbox/Infra/LongLivedPulumiBackend.hs@, the
--     in-cluster Pulumi MinIO backend bucket owner
--     @src/Prodbox/Infra/MinioBackend.hs@, and the Sprint 4.30
--     object-store bucket owner @src/Prodbox/Minio/ObjectStore.hs@. The
--     Provider Worker production interpreter is the narrow owner of the
--     registered @ses:capture-bucket@ provider resource.
--
-- @create-hosted-zone@ is deliberately NOT in this list — see
-- their owner modules. The verbs are matched as raw substrings because
-- they are subprocess string-literal arguments (e.g. @aws iam
-- create-user@). Exposed for unit tests; consumed by
-- 'awsCreateSiteViolations'.
--
-- __Sprint 0.28 widened the region.__ Until this sprint the table held seven
-- verbs, and § 3.1 invariant 1's totality claim was cited over it. Six further
-- verbs that create or mutate real AWS resources were shelled out in @src/@ and
-- outside the table entirely — @create-volume@, @create-receipt-rule-set@,
-- @put-bucket-policy@, @put-object@, @put-public-access-block@, and
-- @request-service-quota-increase@ — so the gate was silent about them. Each is
-- now registered against the owner module measured to contain it. The bound is
-- unchanged in kind and only in extent: this is a substring allowlist over a
-- stated region ([chaos_hardening_doctrine.md § 22](../../documents/engineering/chaos_hardening_doctrine.md)),
-- not a totality proof, and a verb nobody has thought of is still invisible to
-- it. What the widening buys is that the six verbs already known to be outside
-- it no longer are.
awsCreateVerbs :: [(String, [FilePath])]
awsCreateVerbs =
  [ ("create-user", ["src/Prodbox/Aws.hs"])
  ,
    ( "create-access-key"
    ,
      [ "src/Prodbox/Aws.hs"
      , "src/Prodbox/Infra/AwsSesSmtpKey.hs"
      ]
    )
  , ("put-user-policy", ["src/Prodbox/Aws.hs"])
  , ("create-role", ["src/Prodbox/Infra/AwsSesLeaseRole.hs"])
  , ("put-role-policy", ["src/Prodbox/Infra/AwsSesLeaseRole.hs"])
  , ("create-hosted-zone", ["src/Prodbox/Infra/Route53ValidationZone.hs"])
  ,
    ( "create-bucket"
    ,
      [ "src/Prodbox/Infra/LongLivedPulumiBackend.hs"
      , "src/Prodbox/Infra/MinioBackend.hs"
      , "src/Prodbox/Minio/ObjectStore.hs"
      , "src/Prodbox/ControlPlane/ProviderProduction.hs"
      ]
    )
  , -- Sprint 0.28: the six verbs measured outside the pre-0.28 table. Each
    -- owner below is where the verb's subprocess literal actually lives, not
    -- where it arguably belongs.
    ("create-volume", ["src/Prodbox/Lifecycle/EbsVolume.hs"])
  , ("create-receipt-rule-set", ["src/Prodbox/ControlPlane/ProviderProduction.hs"])
  , ("put-bucket-policy", ["src/Prodbox/ControlPlane/ProviderProduction.hs"])
  ,
    ( "put-object"
    ,
      [ "src/Prodbox/ControlPlane/ProviderProduction.hs"
      , "src/Prodbox/Infra/LongLivedPulumiBackend.hs"
      , "src/Prodbox/Infra/MinioBackend.hs"
      ]
    )
  , ("put-public-access-block", ["src/Prodbox/Infra/LongLivedPulumiBackend.hs"])
  , ("request-service-quota-increase", ["src/Prodbox/Aws.hs"])
  ]

-- | The operational-IAM creation verbs. Retained for unit-test
-- back-compatibility; the IAM verbs are the @src/Prodbox/Aws.hs@-owned
-- entries of 'awsCreateVerbs'.
--
-- Sprint 0.28 narrowed the projection to the verbs that are actually IAM:
-- @request-service-quota-increase@ is also solely owned by
-- @src/Prodbox/Aws.hs@ but is a Service Quotas call, so an owner-equality
-- test alone would have silently relabelled it as IAM.
iamCreateVerbs :: [String]
iamCreateVerbs =
  [ verb
  | (verb, owners) <- awsCreateVerbs
  , owners == ["src/Prodbox/Aws.hs"]
  , verb /= "request-service-quota-increase"
  ]

-- | Sprint 4.27 (pure). Given a scanned file's relative path and its raw
-- contents, emit a violation for any 'awsCreateVerbs' verb that appears
-- in a file other than its sanctioned owner module(s). Generalizes the
-- Sprint 4.22 IAM-only @iamCreateSiteViolations@ to every AWS-resource
-- create call site so the create-site coverage lint cannot be bypassed
-- by reaching for a non-IAM @aws … create-*@ verb in an unowned module.
-- Sprint 5.28 removed the last carve-out ('awsCreateProbeVerbs', which had
-- exempted @create-hosted-zone@): every AWS create verb is now owned.
-- @CheckCode.hs@ is excluded from the scan by the path filter in
-- 'checkCreateCallSiteCoverage', so its own occurrences of these verb
-- literals do not self-trigger.
awsCreateSiteViolations :: FilePath -> String -> [String]
awsCreateSiteViolations relativePath contents =
  [ relativePath
      ++ " shells out an AWS-resource creation verb ("
      ++ verb
      ++ ") outside its owner module(s) "
      ++ intercalate ", " owners
      ++ "; register the created resource or move it into the owner."
  | (verb, owners) <- awsCreateVerbs
  , relativePath `notElem` owners
  , -- Match the quoted subprocess-argument form (@"create-bucket"@), not
  -- the bare substring, so Haddock prose describing a verb
  -- (@\@create-bucket\@@) in a non-owner module is not a false positive.
  ('"' : verb ++ "\"") `isInfixOf` contents
  ]

-- | Sprint 4.22 alias retained for back-compatibility (Sprint 4.27
-- generalized the lint to 'awsCreateSiteViolations'). Exposed for unit
-- tests; the live lint uses 'awsCreateSiteViolations'.
iamCreateSiteViolations :: FilePath -> String -> [String]
iamCreateSiteViolations = awsCreateSiteViolations

-- | Sprint 4.14: enforce the operator vocabulary contract defined in
-- @documents/engineering/cli_command_surface.md § 2A@. Sprint
-- identifiers (`Sprint <number>`, `Sprints <list>`) must not appear
-- in any operator-facing surface. This check scans:
--
--   * `src/Prodbox/CLI/Spec.hs` (string literals only — comments are
--     exempt because they are developer documentation, not operator
--     output)
--   * Every file under `share/man/`, `share/completion/`,
--     `documents/cli/`, and `test/golden/cli/`
--
-- A match anywhere in these paths fails the gate. The check is
-- conservative: it does not parse Haskell, it just extracts string
-- literals out of source files and greps the token sequence for an
-- adjacent `Sprint`/`Sprints` + digit. The non-source paths are
-- searched whole because they have no comment syntax that needs
-- stripping.
checkOperatorVocabulary :: FilePath -> IO [String]
checkOperatorVocabulary repoRoot = do
  specViolations <- scanSpecHsStringLiterals
  artifactViolations <- scanGeneratedArtifacts
  pure (specViolations ++ artifactViolations)
 where
  scanSpecHsStringLiterals :: IO [String]
  scanSpecHsStringLiterals = do
    let specPath = repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Spec.hs"
    contents <- readFileStrict specPath
    let literals = extractStringLiterals contents
        offenders =
          [ "src/Prodbox/CLI/Spec.hs string literal contains sprint identifier: "
              ++ shortenSprintLeak lit
          | lit <- literals
          , matchesSprintToken lit
          ]
    pure offenders

  scanGeneratedArtifacts :: IO [String]
  scanGeneratedArtifacts = do
    repoPaths <- listRepoOwnedPaths repoRoot
    let targetPaths =
          [ path
          | path <- repoPaths
          , any
              (`isPrefixOf` path)
              [ "share/man/"
              , "share/completion/"
              , "documents/cli/"
              , "test/golden/cli/"
              ]
          ]
    concat
      <$> forM
        targetPaths
        ( \relativePath -> do
            let absolutePath = repoRoot </> relativePath
            isFile <- doesFileExist absolutePath
            if not isFile
              then pure []
              else do
                contents <- readFileStrict absolutePath
                pure $
                  [ relativePath
                      ++ " contains sprint identifier in operator-facing "
                      ++ "artifact (see "
                      ++ "documents/engineering/cli_command_surface.md § 2A)."
                  | any matchesSprintToken (lines contents)
                  ]
        )

-- | Sprint 4.14: does a single line contain the forbidden adjacent
-- `Sprint <digit>` or `Sprints <digit>` token pair? Exposed for unit
-- tests; consumed by 'checkOperatorVocabulary'.
--
-- Tokens are normalized by stripping leading and trailing
-- non-alphanumeric characters so the check fires on
-- @"(Sprint 4.11)"@ as well as @"Sprint 4.11:"@.
matchesSprintToken :: String -> Bool
matchesSprintToken line =
  let tokens = map stripPunct (words line)
      adjacentDigit (token : nextToken : rest)
        | token == "Sprint" || token == "Sprints"
        , firstChar : _ <- nextToken
        , firstChar `elem` ['0' .. '9'] =
            True
        | otherwise = adjacentDigit (nextToken : rest)
      adjacentDigit _ = False
   in adjacentDigit tokens
 where
  stripPunct :: String -> String
  stripPunct = dropWhileEnd (not . isAlphaNum) . dropWhile (not . isAlphaNum)

shortenSprintLeak :: String -> String
shortenSprintLeak lit
  | length lit <= 80 = lit
  | otherwise = take 77 lit ++ "..."

-- | Sprint 1.75: the mechanical outer ring of repository value hygiene,
-- registered by Sprint 0.19 and generalized by Sprint 0.20. See
-- [vault_doctrine.md § 20.5] and [code_quality.md § Committed Values].
--
-- No tracked file may contain a string matching a scanned provider
-- pattern that the scanner's own exclusions do not cover — whether or
-- not the value is real. The remote decides on shape, never on truth,
-- so this gate does too.
--
-- Scope is __tracked__ content, not a filesystem walk: the git-ignored
-- @test-secrets.dhall@ carries real credential values by design (§ 4),
-- and a walk would fail the gate on a developer whose credentials are
-- exactly where doctrine says to put them. The remote can only reject
-- tracked content, so the narrowing loses no coverage.
--
-- There is deliberately __no exemption mechanism__ — no allowlist, no
-- per-file suppression, no marker comment. The repository satisfies the
-- invariant with zero exemptions; a first exemption request is evidence
-- the pattern set drifted from the remote's, not that the rule needs an
-- escape hatch.
checkCommittedValueHygiene :: FilePath -> IO [String]
checkCommittedValueHygiene repoRoot = do
  trackedResult <- trackedRepositoryFiles repoRoot
  case trackedResult of
    Left failureMessage -> pure [failureMessage]
    Right trackedFiles ->
      concat
        <$> forM
          trackedFiles
          ( \relativePath -> do
              let absolutePath = repoRoot </> relativePath
              isFile <- doesFileExist absolutePath
              if not isFile
                then pure []
                else do
                  -- Read as bytes: two golden artifacts are not valid
                  -- UTF-8, so a locale-sensitive read would throw on
                  -- them. Every scanned pattern is ASCII, so a
                  -- byte-wise view is both sufficient and total.
                  contents <- ByteStringChar8.readFile absolutePath
                  -- Cheap byte-level necessary condition first: the
                  -- tracked corpus is ~19 MB, and unpacking all of it
                  -- into a Haskell String to run the precise matchers
                  -- would turn a seconds-long gate into a minutes-long
                  -- one. A file carrying no candidate fragment cannot
                  -- match any pattern, so it is never unpacked.
                  if not (anyCandidateFragment contents)
                    then pure []
                    else
                      pure
                        ( scannedCredentialViolations
                            relativePath
                            (ByteStringChar8.unpack contents)
                        )
          )

-- | Does this file carry any pattern's required fragment? Each entry
-- in 'scannedCredentialPatterns' names substrings that any real match
-- must contain, so a negative answer here is conclusive.
anyCandidateFragment :: ByteStringChar8.ByteString -> Bool
anyCandidateFragment contents =
  any
    (\fragment -> not (ByteStringChar8.null (snd (ByteStringChar8.breakSubstring fragment contents))))
    allCandidateFragments

allCandidateFragments :: [ByteStringChar8.ByteString]
allCandidateFragments =
  map
    ByteStringChar8.pack
    (concatMap scannedPatternFragments scannedCredentialPatterns)

-- | Enumerate tracked repository paths. Delegates to the version
-- control index rather than walking the filesystem, which is what keeps
-- ignored secret material out of scope.
trackedRepositoryFiles :: FilePath -> IO (Either String [FilePath])
trackedRepositoryFiles repoRoot = do
  captureResult <-
    Subprocess.capture
      Subprocess.Subprocess
        { Subprocess.subprocessPath = "git"
        , Subprocess.subprocessArguments = ["ls-files", "-z"]
        , Subprocess.subprocessEnvironment = Nothing
        , Subprocess.subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case captureResult of
    Left err ->
      Left
        ( "Unable to enumerate tracked paths for the committed-value scan: "
            ++ show err
        )
    Right output ->
      Right
        ( filter
            (not . null)
            (splitOnNulByte (Subprocess.processStdout output))
        )

-- | Read a file, fully, before returning.
--
-- 'System.IO.readFile' is lazy: its handle stays open until the caller
-- consumes to end of input, and many checks in this module stop early
-- (an 'any' that finds its match, a pattern that fails on line one).
-- Those handles then survive until the garbage collector happens to
-- finalize them.
--
-- The binary is built without @-threaded@, so its IO manager waits on
-- descriptors with @select@, which cannot represent a descriptor
-- numbered at or above 1024. Enough leaked handles and the next pipe
-- this module opens — the tracked-path enumeration below, or any
-- future one — is allocated a descriptor past that ceiling and fails
-- with a @file descriptor out of range@ error that has nothing to do
-- with the check that triggered it.
--
-- Forcing the content preserves the decoding behaviour of the lazy
-- read exactly while letting each handle close as soon as it is done.
readFileStrict :: FilePath -> IO String
readFileStrict path = do
  contents <- readFile path
  _ <- evaluate (length contents)
  pure contents

splitOnNulByte :: String -> [String]
splitOnNulByte input = case break (== '\NUL') input of
  (segment, []) -> [segment]
  (segment, _ : rest) -> segment : splitOnNulByte rest

-- | Pure half of the § 20.5 scan: which scanned provider patterns does
-- this file's content carry? Exposed for unit tests; consumed by
-- 'checkCommittedValueHygiene'.
scannedCredentialViolations :: FilePath -> String -> [String]
scannedCredentialViolations relativePath contents =
  [ relativePath
      ++ " contains a string matching the scanned "
      ++ patternName
      ++ " pattern (see documents/engineering/vault_doctrine.md § 20.5)."
  | patternName <- nub (scannedCredentialPatternsPresent contents)
  ]

-- | The scanned pattern set. It mirrors the remote's push protection;
-- anything stricter would forbid the one immovable category § 20.4
-- names, published vendor test vectors, whose bytes cannot change
-- without the test ceasing to prove conformance to anything.
--
-- Several entries assemble their own literal from fragments. That is
-- not obfuscation: this module is itself a tracked file, so spelling a
-- scanned literal contiguously here would make the scanner report
-- itself. Splitting the literal is the § 20.4 discipline — do not have
-- the shape — applied to the scanner's own source.
scannedCredentialPatternsPresent :: String -> [String]
scannedCredentialPatternsPresent contents =
  [ scannedPatternName scanned
  | scanned <- scannedCredentialPatterns
  , any (`isInfixOf` contents) (scannedPatternFragments scanned)
  , scannedPatternPrecise scanned contents
  ]

-- | One scanned provider pattern. 'scannedPatternFragments' are
-- substrings a real match must contain; they exist so the gate can
-- reject a file at byte level without unpacking it, and each one is a
-- necessary condition of 'scannedPatternPrecise' rather than an
-- independent rule.
data ScannedCredentialPattern = ScannedCredentialPattern
  { scannedPatternName :: String
  , scannedPatternFragments :: [String]
  , scannedPatternPrecise :: String -> Bool
  }

scannedCredentialPatterns :: [ScannedCredentialPattern]
scannedCredentialPatterns =
  [ prefixPattern "AWS access key identifier" awsKeyFragments (scanWithBoundary awsAccessKeyIdAt)
  , tokenPattern "GitHub token" githubTokenPrefixes 36
  , tokenPattern "Slack token" slackTokenPrefixes 10
  , literalPattern "Slack webhook URL" ("hooks.slack" ++ ".com/services/")
  , tokenPattern "Anthropic API key" ["sk-" ++ "ant-"] 20
  , tokenPattern "OpenAI API key" openAiKeyPrefixes 20
  , tokenPattern "Google API key" ["AIza"] 35
  , tokenPattern "GitLab token" ["glpat" ++ "-"] 20
  , tokenPattern "npm token" ["npm" ++ "_"] 36
  , tokenPattern "PyPI token" ["pypi-" ++ "AgEIcHlwaS5vcmc"] 10
  , tokenPattern "Stripe secret key" stripeKeyPrefixes 24
  , literalPattern
      "Azure storage connection string"
      ("DefaultEndpointsProtocol=https;" ++ "AccountName=")
  , prefixPattern
      "armored private key block"
      ["-----" ++ "BEGIN"]
      armoredPrivateKeyPresent
  ]
 where
  awsKeyFragments = ["AKIA", "ASIA", "ABIA", "ACCA", "A3T"]
  githubTokenPrefixes = map (\kind -> "gh" ++ [kind] ++ "_") "pousr"
  slackTokenPrefixes = map (\kind -> "xox" ++ [kind] ++ "-") "baprs"
  openAiKeyPrefixes = ["sk-" ++ "proj-", "sk-" ++ "svcacct-"]
  stripeKeyPrefixes = ["sk" ++ "_live_", "rk" ++ "_live_"]

  prefixPattern name fragments precise =
    ScannedCredentialPattern
      { scannedPatternName = name
      , scannedPatternFragments = fragments
      , scannedPatternPrecise = precise
      }

  tokenPattern name prefixes minimumBodyLength =
    prefixPattern name prefixes (scanWithBoundary (prefixTokenAt prefixes minimumBodyLength))

  literalPattern name literalText = prefixPattern name [literalText] (isInfixOf literalText)

-- | Walk the content, offering each position to a matcher but only
-- where a regex @\\b@ would hold — that is, where the preceding
-- character is not a word character.
scanWithBoundary :: (String -> Bool) -> String -> Bool
scanWithBoundary matchesAt = go '\n'
 where
  go _ [] = False
  go previousChar remaining@(currentChar : rest)
    | not (isWordChar previousChar), matchesAt remaining = True
    | otherwise = go currentChar rest

-- | @\\b(A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}\\b@.
--
-- Two properties are load-bearing and frequently misread. The
-- exclusion is the token @EXAMPLE@ and nothing else — not @FAKE@, not
-- @TEST@, not a run of zeroes, not an adjacent explanatory comment.
-- And the trailing boundary is real: a twenty-one-character identifier
-- whose first twenty characters match is not a finding. Neither
-- property says anything about whether the literal satisfies § 20.1,
-- which is judged by a reader rather than by this function.
awsAccessKeyIdAt :: String -> Bool
awsAccessKeyIdAt remaining =
  let (prefixChars, afterPrefix) = splitAt 4 remaining
      (bodyChars, afterBody) = splitAt 16 afterPrefix
   in length prefixChars == 4
        && awsPrefixValid prefixChars
        && length bodyChars == 16
        && all isAwsKeyChar bodyChars
        && trailingBoundary afterBody
        && not ("EXAMPLE" `isInfixOf` (prefixChars ++ bodyChars))
 where
  awsPrefixValid prefixChars =
    prefixChars `elem` ["AKIA", "ASIA", "ABIA", "ACCA"]
      || case prefixChars of
        'A' : '3' : 'T' : fourthChar : _ -> isAwsKeyChar fourthChar
        _ -> False

isAwsKeyChar :: Char -> Bool
isAwsKeyChar c = isAsciiUpper c || isDigit c

-- | A vendor prefix followed by at least @minimumBodyLength@ token
-- characters.
prefixTokenAt :: [String] -> Int -> String -> Bool
prefixTokenAt prefixes minimumBodyLength remaining =
  any matchesPrefix prefixes
 where
  matchesPrefix prefixText =
    prefixText `isPrefixOf` remaining
      && length
        (take minimumBodyLength (takeWhile isSecretBodyChar (drop (length prefixText) remaining)))
        >= minimumBodyLength

armoredPrivateKeyPresent :: String -> Bool
armoredPrivateKeyPresent contents =
  any isArmorLine (lines contents)
 where
  isArmorLine line =
    ("-----" ++ "BEGIN") `isInfixOf` line
      && ("PRIVATE KEY" ++ "-----") `isInfixOf` line

trailingBoundary :: String -> Bool
trailingBoundary [] = True
trailingBoundary (nextChar : _) = not (isWordChar nextChar)

isWordChar :: Char -> Bool
isWordChar c = isAlphaNum c || c == '_'

isSecretBodyChar :: Char -> Bool
isSecretBodyChar c = isAlphaNum c || c == '_' || c == '-'

-- | Walk a Haskell source string and emit the contents of every
-- @"..."@ string literal (in source order). Escaped quotes inside
-- literals are preserved as part of the body. Line- and block-
-- comments are ignored. Conservative: when in doubt, errs on the
-- side of treating data as outside a literal. Exposed for unit
-- tests; consumed by 'checkOperatorVocabulary'.
extractStringLiterals :: String -> [String]
extractStringLiterals = goOutside []
 where
  goOutside :: String -> String -> [String]
  goOutside _ [] = []
  goOutside acc ('-' : '-' : rest) =
    let _ = acc
     in goOutside [] (dropWhile (/= '\n') rest)
  goOutside acc ('{' : '-' : rest) =
    let _ = acc
     in goOutside [] (skipBlockComment rest)
  goOutside _ ('"' : rest) = goInside [] rest
  goOutside acc (_ : rest) = goOutside acc rest

  goInside :: String -> String -> [String]
  goInside acc [] = [reverse acc]
  goInside acc ('\\' : c : rest) = goInside (c : '\\' : acc) rest
  goInside acc ('"' : rest) = reverse acc : goOutside [] rest
  goInside acc (c : rest) = goInside (c : acc) rest

  skipBlockComment :: String -> String
  skipBlockComment [] = []
  skipBlockComment ('-' : '}' : rest) = rest
  skipBlockComment (_ : rest) = skipBlockComment rest

-- | Extract Haskell identifiers while ignoring comments and string/character
-- literals. This is deliberately a small lexical scan, not a formatting or
-- marker check: isolation rules use it to distinguish executable ownership
-- from prose that merely names a legacy surface.
sourceIdentifiers :: String -> [String]
sourceIdentifiers = goOutside
 where
  goOutside [] = []
  goOutside ('-' : '-' : rest) = goOutside (dropWhile (/= '\n') rest)
  goOutside ('{' : '-' : rest) = goOutside (skipBlockComment 1 rest)
  goOutside ('"' : rest) = goOutside (skipQuoted '"' rest)
  goOutside ('\'' : rest) = goOutside (skipQuoted '\'' rest)
  goOutside (first : rest)
    | isIdentifierStart first =
        let (suffix, remaining) = span isIdentifierContinue rest
         in (first : suffix) : goOutside remaining
    | otherwise = goOutside rest

  isIdentifierStart character = isAlpha character || character == '_'
  isIdentifierContinue character =
    isAlphaNum character || character == '_' || character == '\''

  skipQuoted _ [] = []
  skipQuoted quote ('\\' : _escaped : rest) = skipQuoted quote rest
  skipQuoted quote (candidate : rest)
    | candidate == quote = rest
    | otherwise = skipQuoted quote rest

  skipBlockComment :: Int -> String -> String
  skipBlockComment _ [] = []
  skipBlockComment depth ('{' : '-' : rest) =
    skipBlockComment (depth + 1) rest
  skipBlockComment depth ('-' : '}' : rest)
    | depth == 1 = rest
    | otherwise = skipBlockComment (depth - 1) rest
  skipBlockComment depth (_ : rest) = skipBlockComment depth rest

checkTestSuiteInterfaces :: FilePath -> IO [String]
checkTestSuiteInterfaces repoRoot = do
  let cabalPath = repoRoot </> "prodbox.cabal"
  contents <- readFileStrict cabalPath
  pure (go [] Nothing (lines contents))
 where
  go violations _ [] = reverse violations
  go violations currentSuite (lineText : remaining) =
    let trimmedLine = trimLeft lineText
     in if "test-suite " `isPrefixOf` trimmedLine
          then
            let suiteName = drop (length ("test-suite " :: String)) trimmedLine
             in go violations (Just (trimLine suiteName, False)) remaining
          else
            if "type:" `isPrefixOf` trimmedLine
              then case currentSuite of
                Just (suiteName, False) ->
                  let hasExpectedType = "exitcode-stdio-1.0" `isInfixOf` lineText
                      nextViolations =
                        if hasExpectedType
                          then violations
                          else ("Test suite `" ++ suiteName ++ "` must declare `type: exitcode-stdio-1.0`.") : violations
                   in go nextViolations (Just (suiteName, True)) remaining
                _ -> go violations currentSuite remaining
              else go violations currentSuite remaining

rendererDeterminismViolations :: FilePath -> IO [String]
rendererDeterminismViolations repoRoot =
  fmap concat $
    forM uniqueRendererSources $ \relativePath -> do
      contents <- readFileStrict (repoRoot </> relativePath)
      pure (rendererSourceViolations relativePath contents)
 where
  uniqueRendererSources =
    dedupeSorted
      ( concatMap generatedSectionRendererSources generatedSectionRules
          ++ concatMap trackedGeneratedPathRendererSources trackingGeneratedPaths
      )

rendererSourceViolations :: FilePath -> String -> [String]
rendererSourceViolations sourceLabel sourceText =
  concatMap violationsFor forbiddenRendererInputs
 where
  sourceTokens = tokenizeSource sourceText
  violationsFor (inputClass, tokens, substrings) =
    let matchedTokens = filter (`elem` sourceTokens) tokens
        matchedSubstrings = filter (`isInfixOf` sourceText) substrings
        matchedInputs = matchedTokens ++ matchedSubstrings
     in [ sourceLabel
            ++ " uses forbidden renderer input class `"
            ++ inputClass
            ++ "` via "
            ++ commaSeparated matchedInputs
            ++ "."
        | not (null matchedInputs)
        ]
  forbiddenRendererInputs =
    [ ("timestamps", ["getCurrentTime", "getZonedTime", "getPOSIXTime"], [])
    , ("random-ids", ["randomIO", "randomRIO"], ["UUID"])
    , ("locale-dependent-ordering", ["sort"], [])
    ,
      ( "terminal-width-dependent-wrapping"
      , ["getTerminalSize"]
      , ["System.Console.Terminal.Size", "COLUMNS"]
      )
    , ("environment-dependent-paths", ["getCurrentDirectory", "getHomeDirectory", "getEnv"], [])
    ]

tokenizeSource :: String -> [String]
tokenizeSource =
  words . map normalizeCharacter
 where
  normalizeCharacter character
    | isAlphaNum character || character == '_' = character
    | otherwise = ' '

commaSeparated :: [String] -> String
commaSeparated = intercalate ", " . sort

dedupeSorted :: [String] -> [String]
dedupeSorted = go . sort
 where
  go [] = []
  go (value : remaining) =
    value : go (dropWhile (== value) remaining)

rewriteCabalFile :: FilePath -> [(String, String)] -> IO ExitCode
rewriteCabalFile repoRoot environment = do
  cabalTextResult <- renderFormattedCabal repoRoot environment
  case cabalTextResult of
    Left err -> failWith err
    Right renderedCabal -> do
      writeFile (repoRoot </> "prodbox.cabal") renderedCabal
      pure ExitSuccess

checkCabalFormat :: FilePath -> [(String, String)] -> IO ExitCode
checkCabalFormat repoRoot environment = do
  currentContents <- readFileStrict (repoRoot </> "prodbox.cabal")
  cabalTextResult <- renderFormattedCabal repoRoot environment
  case cabalTextResult of
    Left err -> failWith err
    Right renderedCabal ->
      if currentContents == renderedCabal
        then pure ExitSuccess
        else
          failWith
            "cabal format drift detected in `prodbox.cabal`. Run `prodbox lint haskell --write` to rewrite the file."

renderFormattedCabal :: FilePath -> [(String, String)] -> IO (Either String String)
renderFormattedCabal repoRoot environment = do
  createDirectoryIfMissing True (repoRoot </> ".build")
  let tempCabalPath = repoRoot </> ".build" </> "prodbox.cabal.format"
      cabalPath = repoRoot </> "prodbox.cabal"
  copyFile cabalPath tempCabalPath
  formatExit <- runSubprocessStreaming repoRoot environment "cabal" ["format", tempCabalPath]
  case formatExit of
    ExitFailure _ ->
      pure (Left "Failed to format `prodbox.cabal` via `cabal format`.")
    ExitSuccess -> Right <$> readFileStrict tempCabalPath

spliceGeneratedSection :: String -> GeneratedSectionRule -> Either String String
spliceGeneratedSection contents rule = do
  let fileLines = lines contents
      startMarker = generatedSectionStartMarker rule
      endMarker = generatedSectionEndMarker rule
      beforeMarker = takeWhile (/= startMarker) fileLines
      afterStart = dropWhile (/= startMarker) fileLines
  case afterStart of
    [] ->
      Left ("Missing start marker `" ++ startMarker ++ "` in `" ++ generatedSectionPath rule ++ "`.")
    (_ : remainingAfterStart) ->
      let afterMarker = dropWhile (/= endMarker) remainingAfterStart
       in case afterMarker of
            [] ->
              Left ("Missing end marker `" ++ endMarker ++ "` in `" ++ generatedSectionPath rule ++ "`.")
            (_ : trailingLines) ->
              Right
                ( unlines
                    ( beforeMarker
                        ++ [startMarker]
                        ++ lines (renderGeneratedSection rule)
                        ++ [endMarker]
                        ++ trailingLines
                    )
                )

generatedSectionDriftMessage :: FilePath -> GeneratedSectionRule -> String
generatedSectionDriftMessage targetPath rule =
  generatedAssetDriftMessage targetPath (generatedSectionKey rule)

generatedAssetDriftMessage :: FilePath -> String -> String
generatedAssetDriftMessage targetPath registryKey =
  unlines
    [ targetPath
    , registryKey
    , "Run `prodbox dev docs generate` to update."
    ]

missingGeneratedTargetMessage :: GeneratedSectionRule -> String
missingGeneratedTargetMessage rule =
  missingGeneratedFileMessage (generatedSectionPath rule) (generatedSectionKey rule)

missingGeneratedFileMessage :: FilePath -> String -> String
missingGeneratedFileMessage path registryKey =
  "Missing generated documentation target `"
    ++ path
    ++ "` for registry key `"
    ++ registryKey
    ++ "`."

processGeneratedArtifacts :: FilePath -> Bool -> IO [Either String (FilePath, String, Bool)]
processGeneratedArtifacts repoRoot writeEnabled = do
  sectionResults <- forM generatedSectionRules (processGeneratedSection repoRoot writeEnabled)
  fileResults <- forM trackingGeneratedPaths (processTrackedGeneratedPath repoRoot writeEnabled)
  untrackedManpageViolations <- checkUntrackedGeneratedManpages repoRoot
  pure (sectionResults ++ fileResults ++ map Left untrackedManpageViolations)

checkUntrackedGeneratedManpages :: FilePath -> IO [String]
checkUntrackedGeneratedManpages repoRoot = do
  let manpageDirectory = "share/man/man1"
      absoluteManpageDirectory = repoRoot </> manpageDirectory
      expectedPaths = map (normalise . trackedGeneratedPathPath) trackingGeneratedPaths
  directoryExists <- doesDirectoryExist absoluteManpageDirectory
  if not directoryExists
    then pure []
    else do
      entries <- sort <$> listDirectory absoluteManpageDirectory
      let staleManpages =
            [ normalise (manpageDirectory </> entry)
            | entry <- entries
            , "prodbox-" `isPrefixOf` entry
            , ".1" `isSuffixOf` entry
            , normalise (manpageDirectory </> entry) `notElem` expectedPaths
            ]
      pure (map untrackedGeneratedManpageMessage staleManpages)

untrackedGeneratedManpageMessage :: FilePath -> String
untrackedGeneratedManpageMessage path =
  "Untracked generated manpage `"
    ++ path
    ++ "` is not present in the command registry. Remove the file or add the command to `src/Prodbox/CLI/Spec.hs`."

processGeneratedSection
  :: FilePath -> Bool -> GeneratedSectionRule -> IO (Either String (FilePath, String, Bool))
processGeneratedSection repoRoot writeEnabled rule = do
  let targetPath = repoRoot </> generatedSectionPath rule
  fileExists <- doesFileExist targetPath
  if not fileExists
    then pure (Left (missingGeneratedTargetMessage rule))
    else do
      contents <- readFileStrict targetPath
      let forcedContents = length contents `seq` contents
      pure $
        case spliceGeneratedSection forcedContents rule of
          Left err -> Left err
          Right expectedContents ->
            if writeEnabled
              then Right (targetPath, expectedContents, forcedContents /= expectedContents)
              else
                if forcedContents == expectedContents
                  then Right (targetPath, expectedContents, False)
                  else Left (generatedSectionDriftMessage targetPath rule)

processTrackedGeneratedPath
  :: FilePath -> Bool -> TrackedGeneratedPath -> IO (Either String (FilePath, String, Bool))
processTrackedGeneratedPath repoRoot writeEnabled rule = do
  let targetPath = repoRoot </> trackedGeneratedPathPath rule
      expectedContents = renderTrackedGeneratedPath rule
  fileExists <- doesFileExist targetPath
  case (fileExists, writeEnabled) of
    (False, False) ->
      pure
        ( Left
            ( missingGeneratedFileMessage
                (trackedGeneratedPathPath rule)
                (trackedGeneratedPathKey rule)
            )
        )
    (False, True) -> pure (Right (targetPath, expectedContents, True))
    (True, _) -> do
      currentContents <- readFileStrict targetPath
      let forcedContents = length currentContents `seq` currentContents
          hasDrift = forcedContents /= expectedContents
      pure $
        if writeEnabled || not hasDrift
          then Right (targetPath, expectedContents, hasDrift)
          else Left (generatedAssetDriftMessage targetPath (trackedGeneratedPathKey rule))

processChartGeneratedArtifacts :: FilePath -> IO [Either String (FilePath, String, Bool)]
processChartGeneratedArtifacts repoRoot =
  forM
    [ rule
    | rule <- generatedSectionRules
    , "charts/" `isPrefixOf` generatedSectionPath rule
    ]
    (processGeneratedSection repoRoot False)

chartViolationsFor :: FilePath -> FilePath -> IO [String]
chartViolationsFor repoRoot relativeChartPath = do
  let absoluteChartPath = repoRoot </> relativeChartPath
      chartDir = takeDirectory absoluteChartPath
      helperPath = chartDir </> "templates" </> "_helpers.tpl"
  chartContents <- readFileStrict absoluteChartPath
  helperExists <- doesFileExist helperPath
  helperViolations <-
    if helperExists
      then do
        helperContents <- readFileStrict helperPath
        pure (labelViolations helperPath helperContents)
      else pure [helperPath ++ " is missing the shared label helper."]
  templateViolations <- chartTemplateResourceViolations chartDir
  portLiteralFindings <- chartTemplatePortLiteralViolations chartDir
  guardrailViolations <- chartRootGuardrailViolations (takeFileName chartDir) chartDir
  probeViolations <- gatewayProbeChartViolations (takeFileName chartDir) chartDir
  staticsViolations <- gatewayStaticsChartViolations (takeFileName chartDir) chartDir
  brokerStaticsViolations <- bootstrapBrokerStaticsChartViolations (takeFileName chartDir) chartDir
  controlPlaneStaticsViolations <- controlPlaneChartStaticsViolations (takeFileName chartDir) chartDir
  recoveryObserverViolations <-
    recoveryObserverRbacChartViolations (takeFileName chartDir) chartDir
  pure
    ( manifestViolations relativeChartPath chartContents
        ++ helperViolations
        ++ templateViolations
        ++ portLiteralFindings
        ++ guardrailViolations
        ++ probeViolations
        ++ staticsViolations
        ++ brokerStaticsViolations
        ++ controlPlaneStaticsViolations
        ++ recoveryObserverViolations
    )
 where
  manifestViolations path contents =
    missingPrefixedFields path contents ["apiVersion: v2", "name:", "version:", "appVersion:"]

-- | Every recovery-profile namespace owns only an exact-name GET Role for the
-- Lifecycle Authority.  This guard deliberately scans the rendered source
-- shape rather than accepting a generic RBAC value: list/watch and Secret
-- access cannot be introduced without failing the canonical code check.
recoveryObserverRbacChartViolations :: String -> FilePath -> IO [String]
recoveryObserverRbacChartViolations chartName chartDir
  | chartName `notElem` ChartPlatform.recoveryObserverRbacChartNames = pure []
  | otherwise = do
      let templatePath = chartDir </> "templates" </> "recovery-observer-rbac.yaml"
          valuesPath = chartDir </> "values.yaml"
      template <- readFileIfExists templatePath
      values <- readFileIfExists valuesPath
      networkPolicy <-
        if chartName == "lifecycle-authority"
          then readFileIfExists (chartDir </> "templates" </> "networkpolicy.yaml")
          else pure ""
      pure
        ( missingTemplate templatePath template
            ++ requiredTemplateBindings templatePath template
            ++ forbiddenAuthority templatePath template
            ++ generatedSubject valuesPath values
            ++ lifecycleAuthorityApiEgress networkPolicy
        )
 where
  readFileIfExists path = do
    exists <- doesFileExist path
    if exists then readFileStrict path else pure ""

  missingTemplate path contents =
    [path ++ " is missing the exact recovery-observer RBAC template." | null contents]

  requiredTemplateBindings path contents =
    [ path ++ " must bind the recovery observer through `" ++ needle ++ "`."
    | needle <-
        [ "resourceNames:"
        , "verbs: [\"get\"]"
        , ".Values.recoveryObserver.serviceAccountName"
        , ".Values.recoveryObserver.serviceAccountNamespace"
        ]
    , needle `notElemIn` contents
    ]

  forbiddenAuthority path contents =
    [ path ++ " grants forbidden recovery-observer authority `" ++ token ++ "`."
    | token <-
        [ "verbs: [\"list\"]"
        , "verbs: [\"watch\"]"
        , "verbs: [\"create\"]"
        , "verbs: [\"update\"]"
        , "verbs: [\"patch\"]"
        , "verbs: [\"delete\"]"
        , "resources: [\"secrets\"]"
        , "resources: [\"pods\"]"
        ]
    , token `isInfixOf` contents
    ]

  generatedSubject path contents =
    [ path
        ++ " must contain the generated Lifecycle Authority recovery-observer subject."
    | AuthorityStatics.renderLifecycleAuthorityRecoveryObserverYaml
        `notElemIn` contents
    ]

  lifecycleAuthorityApiEgress contents
    | chartName /= "lifecycle-authority" = []
    | otherwise =
        [ "charts/lifecycle-authority NetworkPolicy must consume the observed Kubernetes API egress coordinate."
        | any
            (`notElemIn` contents)
            [ "range .Values.kubernetesApiEgress.addresses"
            , ".Values.kubernetesApiEgress.port"
            ]
        ]

  needle `notElemIn` haystack = not (needle `isInfixOf` haystack)

gatewayProbeChartViolations :: String -> FilePath -> IO [String]
gatewayProbeChartViolations chartName chartDir =
  if chartName /= "gateway"
    then pure []
    else do
      let templatePath = chartDir </> "templates" </> "deployments.yaml"
          valuesPath = chartDir </> "values.yaml"
      templateExists <- doesFileExist templatePath
      valuesExists <- doesFileExist valuesPath
      case (templateExists, valuesExists) of
        (True, True) -> do
          templateContents <- readFileStrict templatePath
          valuesContents <- readFileStrict valuesPath
          pure (gatewayProbeViolations templateContents valuesContents)
        (False, False) ->
          pure
            [ templatePath ++ " is missing the gateway Deployment probe bindings."
            , valuesPath ++ " is missing the typed gateway probe defaults."
            ]
        (False, True) ->
          pure [templatePath ++ " is missing the gateway Deployment probe bindings."]
        (True, False) ->
          pure [valuesPath ++ " is missing the typed gateway probe defaults."]

-- | Sprint 3.25: enforce the gateway lifecycle-probe boundary independently
-- of Helm availability. The static defaults are generated from the same typed
-- value used by the Haskell chart plan; the Deployment must consume every
-- timing/threshold field from that value and must never use the diagnostic
-- state projection as a kubelet probe.
gatewayProbeViolations :: String -> String -> [String]
gatewayProbeViolations deploymentTemplate valuesContents =
  forbiddenStateProbeViolations
    ++ missingBindingViolations
    ++ generatedDefaultsViolations
 where
  forbiddenStateProbeViolations =
    [ "charts/gateway "
        ++ surface
        ++ " uses forbidden kubelet probe path `/v1/state`; kubelet liveness and readiness must use `/healthz` (process reachability) so the degraded pre-Vault daemon stays reachable — full `/readyz` readiness is the lifecycle gate, never a kubelet probe."
    | (surface, contents) <-
        [ ("Deployment template", deploymentTemplate)
        , ("values", valuesContents)
        ]
    , "/v1/state" `isInfixOf` contents
    ]
  missingBindingViolations =
    [ "charts/gateway/templates/deployments.yaml must render the complete values-backed `"
        ++ probeName
        ++ "` stanza."
    | (probeName, expectedBlock) <- gatewayProbeTemplateBlocks
    , expectedBlock `notElemIn` deploymentTemplate
    ]
  generatedDefaultsViolations =
    [ "charts/gateway/values.yaml must contain the generated typed gateway lifecycle-probe defaults."
    | renderGatewayProbeDefaultsYaml `notElemIn` valuesContents
    ]
  needle `notElemIn` haystack = not (needle `isInfixOf` haystack)

-- | Sprint 2.34: enforce that the gateway chart's static identities flow from
-- the one compiled 'ChartStatics.gatewayChartStatics' rather than raw literals.
-- The hand-written ServiceAccount name must be @.Values@-driven and the
-- @values.yaml@ defaults must carry the generated statics block.
gatewayStaticsChartViolations :: String -> FilePath -> IO [String]
gatewayStaticsChartViolations chartName chartDir =
  if chartName /= "gateway"
    then pure []
    else do
      let serviceAccountPath = chartDir </> "templates" </> "serviceaccount.yaml"
          deploymentPath = chartDir </> "templates" </> "deployments.yaml"
          valuesPath = chartDir </> "values.yaml"
      serviceAccountContents <- readFileIfExists serviceAccountPath
      deploymentContents <- readFileIfExists deploymentPath
      valuesContents <- readFileIfExists valuesPath
      pure
        ( gatewayChartStaticViolations
            serviceAccountContents
            deploymentContents
            valuesContents
        )
 where
  readFileIfExists path = do
    exists <- doesFileExist path
    if exists then readFileStrict path else pure ""

-- | Sprint 2.34 (pure). The gateway chart's ServiceAccount identity must render
-- @{{ .Values.serviceAccount.name }}@ from 'ChartStatics.gatewayChartStatics',
-- never the raw role literal, and @values.yaml@ must carry the generated
-- statics defaults. Exposed for the conformance unit suite.
gatewayChartStaticViolations :: String -> String -> String -> [String]
gatewayChartStaticViolations serviceAccountTemplate deploymentTemplate valuesContents =
  serviceAccountLiteralViolations ++ generatedStaticsViolations
 where
  serviceAccountName = Text.unpack (ChartStatics.gatewayStaticServiceAccount ChartStatics.gatewayChartStatics)
  serviceAccountLiteralViolations =
    [ "charts/gateway/templates/"
        ++ file
        ++ " hard-codes the ServiceAccount identity `"
        ++ serviceAccountName
        ++ "`; render `{{ .Values.serviceAccount.name }}` from GatewayChartStatics instead."
    | (file, contents, needle) <-
        [ ("serviceaccount.yaml", serviceAccountTemplate, "name: " ++ serviceAccountName)
        , ("deployments.yaml", deploymentTemplate, "serviceAccountName: " ++ serviceAccountName)
        ]
    , needle `isInfixOf` contents
    ]
  generatedStaticsViolations =
    [ "charts/gateway/values.yaml must contain the generated GatewayChartStatics defaults (ports/nodePort/serviceAccount/externalCallers)."
    | not (ChartStatics.renderGatewayChartStaticsYaml `isInfixOf` valuesContents)
    ]

-- | Sprint 3.26: enforce that the Bootstrap Broker chart's static identities
-- flow from the one compiled 'BrokerChartStatics.brokerChartStatics' rather than
-- raw literals. The hand-written ServiceAccount name and lifecycle probe paths
-- must be @.Values@-driven and @values.yaml@ must carry the generated statics
-- block. Guarded to the @bootstrap-broker@ chart so it is inert elsewhere.
bootstrapBrokerStaticsChartViolations :: String -> FilePath -> IO [String]
bootstrapBrokerStaticsChartViolations chartName chartDir =
  if chartName /= "bootstrap-broker"
    then pure []
    else do
      let serviceAccountPath = chartDir </> "templates" </> "serviceaccount.yaml"
          deploymentPath = chartDir </> "templates" </> "deployment.yaml"
          valuesPath = chartDir </> "values.yaml"
      serviceAccountContents <- readFileIfExists serviceAccountPath
      deploymentContents <- readFileIfExists deploymentPath
      valuesContents <- readFileIfExists valuesPath
      pure
        ( bootstrapBrokerChartStaticViolations
            serviceAccountContents
            deploymentContents
            valuesContents
        )
 where
  readFileIfExists path = do
    exists <- doesFileExist path
    if exists then readFileStrict path else pure ""

-- | Sprint 3.26 (pure). The Bootstrap Broker chart's ServiceAccount identity and
-- lifecycle probe paths must render from @.Values@ (fed by the compiled
-- 'BrokerChartStatics.brokerChartStatics'), never raw literals, and @values.yaml@
-- must carry the generated statics block. Exposed for the conformance unit suite.
bootstrapBrokerChartStaticViolations :: String -> String -> String -> [String]
bootstrapBrokerChartStaticViolations serviceAccountTemplate deploymentTemplate valuesContents =
  serviceAccountLiteralViolations ++ probePathLiteralViolations ++ generatedStaticsViolations
 where
  statics = BrokerChartStatics.brokerChartStatics
  serviceAccountName = Text.unpack (BrokerChartStatics.brokerStaticServiceAccount statics)
  serviceAccountLiteralViolations =
    [ "charts/bootstrap-broker/templates/"
        ++ file
        ++ " hard-codes the ServiceAccount identity `"
        ++ serviceAccountName
        ++ "`; render `{{ .Values.serviceAccount.name }}` from BrokerChartStatics instead."
    | (file, contents, needle) <-
        [ ("serviceaccount.yaml", serviceAccountTemplate, "name: " ++ serviceAccountName)
        , ("deployment.yaml", deploymentTemplate, "serviceAccountName: " ++ serviceAccountName)
        ]
    , needle `isInfixOf` contents
    ]
  probePathLiteralViolations =
    [ "charts/bootstrap-broker/templates/deployment.yaml hard-codes the "
        ++ probeName
        ++ " probe path `"
        ++ path
        ++ "`; render `{{ .Values.probes."
        ++ probeName
        ++ " | quote }}` from BrokerChartStatics instead."
    | (probeName, path) <-
        [ ("liveness", Text.unpack (BrokerChartStatics.brokerStaticLivenessPath statics))
        , ("readiness", Text.unpack (BrokerChartStatics.brokerStaticReadinessPath statics))
        ]
    , ("path: " ++ path) `isInfixOf` deploymentTemplate
    ]
  generatedStaticsViolations =
    [ "charts/bootstrap-broker/values.yaml must contain the generated BrokerChartStatics defaults (serviceAccount/vault.role/probes)."
    | not (BrokerChartStatics.renderBrokerChartStaticsYaml `isInfixOf` valuesContents)
    ]

-- | Sprint 3.26: the negative-lint registry for the five standing control-plane
-- role charts. Each entry pins a chart to its compiled ServiceAccount identity,
-- constant-time probe paths, generated @values.yaml@ block, and hand-written
-- workload template file, so the regression guard below can reject a raw literal
-- that drifts from the compiled @ChartStatics@.
data ControlPlaneChartLint = ControlPlaneChartLint
  { cplChartName :: String
  , cplServiceAccount :: String
  , cplLiveness :: String
  , cplReadiness :: String
  , cplRenderYaml :: String
  , cplWorkloadFile :: String
  }

controlPlaneChartLints :: [ControlPlaneChartLint]
controlPlaneChartLints =
  [ ControlPlaneChartLint
      "lifecycle-authority"
      ( Text.unpack
          ( AuthorityStatics.lifecycleAuthorityStaticServiceAccount
              AuthorityStatics.lifecycleAuthorityChartStatics
          )
      )
      ( Text.unpack
          ( AuthorityStatics.lifecycleAuthorityStaticLivenessPath
              AuthorityStatics.lifecycleAuthorityChartStatics
          )
      )
      ( Text.unpack
          ( AuthorityStatics.lifecycleAuthorityStaticReadinessPath
              AuthorityStatics.lifecycleAuthorityChartStatics
          )
      )
      AuthorityStatics.renderLifecycleAuthorityChartStaticsYaml
      "statefulset.yaml"
  , ControlPlaneChartLint
      "provider-worker"
      ( Text.unpack
          ( ProviderWorkerStatics.providerWorkerStaticServiceAccount
              ProviderWorkerStatics.providerWorkerChartStatics
          )
      )
      ( Text.unpack
          ( ProviderWorkerStatics.providerWorkerStaticLivenessPath
              ProviderWorkerStatics.providerWorkerChartStatics
          )
      )
      ( Text.unpack
          ( ProviderWorkerStatics.providerWorkerStaticReadinessPath
              ProviderWorkerStatics.providerWorkerChartStatics
          )
      )
      ProviderWorkerStatics.renderProviderWorkerChartStaticsYaml
      "deployment.yaml"
  , ControlPlaneChartLint
      "authority-backup"
      ( Text.unpack
          ( AuthorityBackupStatics.authorityBackupStaticServiceAccount
              AuthorityBackupStatics.authorityBackupChartStatics
          )
      )
      ( Text.unpack
          ( AuthorityBackupStatics.authorityBackupStaticLivenessPath
              AuthorityBackupStatics.authorityBackupChartStatics
          )
      )
      ( Text.unpack
          ( AuthorityBackupStatics.authorityBackupStaticReadinessPath
              AuthorityBackupStatics.authorityBackupChartStatics
          )
      )
      AuthorityBackupStatics.renderAuthorityBackupChartStaticsYaml
      "deployment.yaml"
  , ControlPlaneChartLint
      "tls-retention"
      ( Text.unpack
          (TlsRetentionStatics.tlsRetentionStaticServiceAccount TlsRetentionStatics.tlsRetentionChartStatics)
      )
      ( Text.unpack
          (TlsRetentionStatics.tlsRetentionStaticLivenessPath TlsRetentionStatics.tlsRetentionChartStatics)
      )
      ( Text.unpack
          (TlsRetentionStatics.tlsRetentionStaticReadinessPath TlsRetentionStatics.tlsRetentionChartStatics)
      )
      TlsRetentionStatics.renderTlsRetentionChartStaticsYaml
      "deployment.yaml"
  , ControlPlaneChartLint
      "target-secret-agent"
      ( Text.unpack
          ( TargetSecretAgentStatics.targetSecretAgentStaticServiceAccount
              TargetSecretAgentStatics.targetSecretAgentChartStatics
          )
      )
      ( Text.unpack
          ( TargetSecretAgentStatics.targetSecretAgentStaticLivenessPath
              TargetSecretAgentStatics.targetSecretAgentChartStatics
          )
      )
      ( Text.unpack
          ( TargetSecretAgentStatics.targetSecretAgentStaticReadinessPath
              TargetSecretAgentStatics.targetSecretAgentChartStatics
          )
      )
      TargetSecretAgentStatics.renderTargetSecretAgentChartStaticsYaml
      "deployment.yaml"
  ]

-- | Sprint 3.26 (IO). Dispatch a chart to its control-plane negative-lint if it
-- is one of the five standing control-plane role charts; otherwise no-op.
controlPlaneChartStaticsViolations :: String -> FilePath -> IO [String]
controlPlaneChartStaticsViolations chartName chartDir =
  case find ((== chartName) . cplChartName) controlPlaneChartLints of
    Nothing -> pure []
    Just lint -> do
      serviceAccountContents <- readFileIfExists (chartDir </> "templates" </> "serviceaccount.yaml")
      workloadContents <- readFileIfExists (chartDir </> "templates" </> cplWorkloadFile lint)
      valuesContents <- readFileIfExists (chartDir </> "values.yaml")
      pure (controlPlaneChartStaticViolations lint serviceAccountContents workloadContents valuesContents)
 where
  readFileIfExists path = do
    exists <- doesFileExist path
    if exists then readFileStrict path else pure ""

-- | Sprint 3.26 (pure). A standing control-plane role chart's ServiceAccount
-- identity and lifecycle probe paths must render from @.Values@ (fed by the
-- compiled per-role @ChartStatics@), never raw literals, and @values.yaml@ must
-- carry the generated statics block. Exposed for the conformance unit suite.
controlPlaneChartStaticViolations :: ControlPlaneChartLint -> String -> String -> String -> [String]
controlPlaneChartStaticViolations lint serviceAccountTemplate workloadTemplate valuesContents =
  serviceAccountLiteralViolations ++ probePathLiteralViolations ++ generatedStaticsViolations
 where
  chart = cplChartName lint
  serviceAccountName = cplServiceAccount lint
  serviceAccountLiteralViolations =
    [ "charts/"
        ++ chart
        ++ "/templates/"
        ++ file
        ++ " hard-codes the ServiceAccount identity `"
        ++ serviceAccountName
        ++ "`; render `{{ .Values.serviceAccount.name }}` from the compiled ChartStatics instead."
    | (file, contents, needle) <-
        [ ("serviceaccount.yaml", serviceAccountTemplate, "name: " ++ serviceAccountName)
        , (cplWorkloadFile lint, workloadTemplate, "serviceAccountName: " ++ serviceAccountName)
        ]
    , needle `isInfixOf` contents
    ]
  probePathLiteralViolations =
    [ "charts/"
        ++ chart
        ++ "/templates/"
        ++ cplWorkloadFile lint
        ++ " hard-codes the "
        ++ probeName
        ++ " probe path `"
        ++ path
        ++ "`; render `{{ .Values.probes."
        ++ probeName
        ++ " | quote }}` from the compiled ChartStatics instead."
    | (probeName, path) <-
        [ ("liveness", cplLiveness lint)
        , ("readiness", cplReadiness lint)
        ]
    , ("path: " ++ path) `isInfixOf` workloadTemplate
    ]
  generatedStaticsViolations =
    [ "charts/"
        ++ chart
        ++ "/values.yaml must contain the generated ChartStatics defaults (serviceAccount/vault.role/probes)."
    | not (cplRenderYaml lint `isInfixOf` valuesContents)
    ]

gatewayProbeTemplateBlocks :: [(String, String)]
gatewayProbeTemplateBlocks =
  [
    ( "livenessProbe"
    , unlines
        [ "          livenessProbe:"
        , "            httpGet:"
        , "              path: {{ $.Values.probes.liveness.path | quote }}"
        , "              port: rest"
        , "              scheme: HTTP"
        , "            initialDelaySeconds: {{ $.Values.probes.liveness.initialDelaySeconds }}"
        , "            periodSeconds: {{ $.Values.probes.liveness.periodSeconds }}"
        , "            timeoutSeconds: {{ $.Values.probes.liveness.timeoutSeconds }}"
        , "            failureThreshold: {{ $.Values.probes.liveness.failureThreshold }}"
        , "            successThreshold: {{ $.Values.probes.liveness.successThreshold }}"
        ]
    )
  ,
    ( "readinessProbe"
    , unlines
        [ "          readinessProbe:"
        , "            httpGet:"
        , "              path: {{ $.Values.probes.readiness.path | quote }}"
        , "              port: rest"
        , "              scheme: HTTP"
        , "            initialDelaySeconds: {{ $.Values.probes.readiness.initialDelaySeconds }}"
        , "            periodSeconds: {{ $.Values.probes.readiness.periodSeconds }}"
        , "            timeoutSeconds: {{ $.Values.probes.readiness.timeoutSeconds }}"
        , "            failureThreshold: {{ $.Values.probes.readiness.failureThreshold }}"
        , "            successThreshold: {{ $.Values.probes.readiness.successThreshold }}"
        ]
    )
  ]

chartTemplateResourceViolations :: FilePath -> IO [String]
chartTemplateResourceViolations chartDir = do
  let templatesDir = chartDir </> "templates"
  templatesDirExists <- doesDirectoryExist templatesDir
  if not templatesDirExists
    then pure []
    else do
      entries <- listDirectory templatesDir
      fmap concat $
        forM
          (sort [entry | entry <- entries, ".yaml" `isSuffixOf` entry])
          ( \entry -> do
              let path = templatesDir </> entry
              contents <- readFileStrict path
              pure (containerResourceViolations path contents)
          )

-- | Sprint 3.34: a sibling of 'chartTemplateResourceViolations', reusing its
-- enumeration, that refuses an all-digit port value in any repo-owned chart
-- template.
--
-- __Why the region is every template, not a filename list.__ Per
-- [resource_scaling_doctrine.md § 2C](../../documents/engineering/resource_scaling_doctrine.md)
-- a gate's region must cover the surface that carries its evidence, and before
-- this check no gate read a chart @networkpolicy.yaml@ for content at all — the
-- Kubernetes API egress coordinate lived in three independently-authored
-- literals with no compiled owner.
--
-- __No allowlist is needed.__ Named ports (@port: http@) and @{{ .Values… }}@
-- expressions are not all-digit, so they fall out of the predicate rather than
-- being excepted by it.
--
-- __The honest bound.__ This closes drift between a rendered value and its
-- compiled owner; it does not close correctness of the owner. Had it existed,
-- @port: 443@ would have become a values binding, and if the compiled owner
-- still said @443@ the cluster would break identically. Only a live run proves
-- @6443@. This gate is not credited with catching the outage that registered
-- the sprint.
chartTemplatePortLiteralViolations :: FilePath -> IO [String]
chartTemplatePortLiteralViolations chartDir = do
  let templatesDir = chartDir </> "templates"
  templatesDirExists <- doesDirectoryExist templatesDir
  if not templatesDirExists
    then pure []
    else do
      entries <- listDirectory templatesDir
      fmap concat $
        forM
          (sort [entry | entry <- entries, ".yaml" `isSuffixOf` entry])
          ( \entry -> do
              let path = templatesDir </> entry
              contents <- readFileStrict path
              pure (portLiteralViolations path contents)
          )

-- | The closed key set that carries a port coordinate in a Kubernetes manifest.
chartPortKeys :: [String]
chartPortKeys = ["port:", "targetPort:", "containerPort:", "nodePort:", "hostPort:"]

portLiteralViolations :: FilePath -> String -> [String]
portLiteralViolations path contents =
  [ path
      ++ " line "
      ++ show lineNumber
      ++ " renders `"
      ++ trimLine lineText
      ++ "` as a port literal; bind it to a compiled owner through `.Values`."
  | (lineNumber, lineText) <- zip [1 :: Int ..] (lines contents)
  , Just value <- [portValueOnLine lineText]
  , not (null value)
  , all isDigit value
  ]

-- | The value of a port-carrying key on this line, if the line declares one.
portValueOnLine :: String -> Maybe String
portValueOnLine lineText =
  case find (`isPrefixOf` afterDash) chartPortKeys of
    Nothing -> Nothing
    Just key -> Just (trimLine (drop (length key) afterDash))
 where
  trimmed = trimLine lineText
  afterDash = if "- " `isPrefixOf` trimmed then trimLine (drop 2 trimmed) else trimmed

containerResourceViolations :: FilePath -> String -> [String]
containerResourceViolations path contents =
  concatMap sectionViolations (containerSections numberedLines)
 where
  numberedLines = zip [1 :: Int ..] (lines contents)
  sectionViolations (sectionLineNumber, sectionIndent, sectionLines) =
    if isPerconaReplicaCertCopyContainerMap sectionLines
      then []
      else case containerBlocks sectionIndent sectionLines of
        [] ->
          [ path
              ++ " line "
              ++ show sectionLineNumber
              ++ " declares a container section with no container items."
          ]
        blocks -> concatMap blockViolation blocks
  blockViolation (lineNumber, name, blockLines) =
    [ path
        ++ " line "
        ++ show lineNumber
        ++ " container `"
        ++ name
        ++ "` must render a values-backed `resources` stanza."
    | not (hasValuesBackedResources blockLines)
    ]

containerSections :: [(Int, String)] -> [(Int, Int, [(Int, String)])]
containerSections [] = []
containerSections ((lineNumber, lineText) : remaining) =
  if trimmedLine `elem` ["containers:", "initContainers:"]
    then (lineNumber, sectionIndent, sectionBody) : containerSections rest
    else containerSections remaining
 where
  trimmedLine = trimLine lineText
  sectionIndent = leadingWhitespaceCount lineText
  (sectionBody, rest) = span (belongsToSection sectionIndent) remaining

belongsToSection :: Int -> (Int, String) -> Bool
belongsToSection sectionIndent (_, lineText) =
  null trimmedLine
    || "{{" `isPrefixOf` trimmedLine
    || leadingWhitespaceCount lineText > sectionIndent
 where
  trimmedLine = trimLine lineText

containerBlocks :: Int -> [(Int, String)] -> [(Int, String, [(Int, String)])]
containerBlocks sectionIndent sectionLines =
  case containerItemIndent sectionIndent sectionLines of
    Nothing -> []
    Just itemIndent -> blocksAtIndent itemIndent sectionLines

containerItemIndent :: Int -> [(Int, String)] -> Maybe Int
containerItemIndent sectionIndent sectionLines =
  case sort itemIndents of
    [] -> Nothing
    firstIndent : _ -> Just firstIndent
 where
  itemIndents =
    [ leadingWhitespaceCount lineText
    | (_, lineText) <- sectionLines
    , leadingWhitespaceCount lineText > sectionIndent
    , "- name:" `isPrefixOf` trimLine lineText
    ]

blocksAtIndent :: Int -> [(Int, String)] -> [(Int, String, [(Int, String)])]
blocksAtIndent _ [] = []
blocksAtIndent itemIndent ((lineNumber, lineText) : remaining) =
  if leadingWhitespaceCount lineText == itemIndent && "- name:" `isPrefixOf` trimLine lineText
    then
      let (blockBody, rest) = break (startsContainerItem itemIndent) remaining
       in (lineNumber, containerName lineText, (lineNumber, lineText) : blockBody)
            : blocksAtIndent itemIndent rest
    else blocksAtIndent itemIndent remaining

startsContainerItem :: Int -> (Int, String) -> Bool
startsContainerItem itemIndent (_, lineText) =
  leadingWhitespaceCount lineText == itemIndent && "- name:" `isPrefixOf` trimLine lineText

containerName :: String -> String
containerName lineText =
  case words (drop (length "- name:") (trimLine lineText)) of
    quotedName : _ -> filter (`notElem` ("\"'" :: String)) quotedName
    [] -> "<unknown>"

hasValuesBackedResources :: [(Int, String)] -> Bool
hasValuesBackedResources blockLines =
  any ((== "resources:") . trimLine . snd) blockLines
    && any ((".Values.resources" `isInfixOf`) . snd) blockLines

isPerconaReplicaCertCopyContainerMap :: [(Int, String)] -> Bool
isPerconaReplicaCertCopyContainerMap sectionLines =
  any ((== "replicaCertCopy:") . trimLine . snd) sectionLines
    && any ((".Values.resources.replicaCertCopy" `isInfixOf`) . snd) sectionLines

chartRootGuardrailViolations :: String -> FilePath -> IO [String]
chartRootGuardrailViolations chartName chartDir =
  if chartName `elem` rootGuardrailCharts
    then do
      let guardrailPath = chartDir </> "templates" </> "resource-guardrails.yaml"
      guardrailExists <- doesFileExist guardrailPath
      if not guardrailExists
        then pure [guardrailPath ++ " is missing the root-chart ResourceQuota/LimitRange manifest."]
        else do
          contents <- readFileStrict guardrailPath
          pure
            ( missingPrefixedFields guardrailPath contents ["kind: ResourceQuota", "kind: LimitRange"]
                ++ missingLiteralFields
                  guardrailPath
                  contents
                  [ ".Values.resourceGuardrails.enabled"
                  , ".Values.resourceGuardrails.quota.hard"
                  , ".Values.resourceGuardrails.limitRange.default"
                  , ".Values.resourceGuardrails.limitRange.defaultRequest"
                  ]
            )
    else pure []

rootGuardrailCharts :: [String]
rootGuardrailCharts = ["api", "gateway", "keycloak", "vscode", "websocket"]

missingLiteralFields :: FilePath -> String -> [String] -> [String]
missingLiteralFields path contents =
  map missingFieldMessage . filter (not . containsField)
 where
  containsField expectedLiteral =
    expectedLiteral `isInfixOf` contents
  missingFieldMessage expectedLiteral =
    path ++ " is missing required chart literal `" ++ expectedLiteral ++ "`."

labelViolations :: FilePath -> String -> [String]
labelViolations helperPath contents =
  missingPrefixedFields
    helperPath
    contents
    [ "app.kubernetes.io/name:"
    , "app.kubernetes.io/managed-by: prodbox"
    , "prodbox.io/chart-root:"
    ]

missingPrefixedFields :: FilePath -> String -> [String] -> [String]
missingPrefixedFields path contents =
  map missingFieldMessage . filter (not . containsField)
 where
  normalizedLines = map trimLine (lines contents)
  containsField expectedPrefix =
    any (expectedPrefix `isPrefixOf`) normalizedLines
  missingFieldMessage expectedPrefix =
    path ++ " is missing required chart field `" ++ expectedPrefix ++ "`."

leftMessages :: [Either String right] -> [String]
leftMessages [] = []
leftMessages (value : remaining) =
  case value of
    Left err -> err : leftMessages remaining
    Right _ -> leftMessages remaining

whenWriteRepoFiles :: [Either String (FilePath, String, Bool)] -> IO ()
whenWriteRepoFiles results =
  mapM_ writeUpdatedFile (rightsOnly results)
 where
  writeUpdatedFile (targetPath, expectedContents, hasDrift) =
    if hasDrift
      then do
        createDirectoryIfMissing True (takeDirectory targetPath)
        writeFile targetPath expectedContents
      else pure ()

firstLeft :: [Either left right] -> Maybe left
firstLeft [] = Nothing
firstLeft (value : remaining) =
  case value of
    Left err -> Just err
    Right _ -> firstLeft remaining

rightsOnly :: [Either left right] -> [right]
rightsOnly [] = []
rightsOnly (value : remaining) =
  case value of
    Left _ -> rightsOnly remaining
    Right success -> success : rightsOnly remaining

maybeToList :: Maybe a -> [a]
maybeToList Nothing = []
maybeToList (Just value) = [value]

trimLeft :: String -> String
trimLeft = dropWhile (`elem` [' ', '\t'])

trimLine :: String -> String
trimLine = reverse . dropWhile (`elem` [' ', '\t']) . reverse . trimLeft

listRepoOwnedPaths :: FilePath -> IO [FilePath]
listRepoOwnedPaths repoRoot = scanDirectory ""
 where
  scanDirectory :: FilePath -> IO [FilePath]
  scanDirectory relativeRoot = do
    let directoryPath =
          if null relativeRoot
            then repoRoot
            else repoRoot </> relativeRoot
    entriesResult <- tryIOError (sort <$> listDirectory directoryPath)
    case entriesResult of
      Left _ -> pure []
      Right entries ->
        fmap concat $
          forM entries $ \entry -> do
            let relativePath =
                  if null relativeRoot
                    then entry
                    else relativeRoot </> entry
                absolutePath = repoRoot </> relativePath
            isDirectory <- doesDirectoryExist absolutePath
            if not isDirectory
              then pure [relativePath]
              else
                if entry `elem` excludedDirectories
                  then pure []
                  else
                    if entry `elem` forbiddenDirectories
                      then pure [relativePath]
                      else do
                        descendants <- scanDirectory relativePath
                        pure (relativePath : descendants)

  excludedDirectories = [".git", ".build", "dist-newstyle", ".prodbox-state", ".data"]
  forbiddenDirectories = [".github", ".githooks", ".husky"]

renderDoctrineViolation :: DoctrineViolation -> String
renderDoctrineViolation violation =
  case violation of
    ForbiddenWorkflowDirectory relativePath ->
      relativePath ++ " is forbidden because repository-owned CI workflow automation is not supported."
    ForbiddenHookSurface relativePath ->
      relativePath
        ++ " is forbidden because repository-owned git-hook and pre-commit style tooling is not supported."
    ForbiddenBuildShim relativePath ->
      relativePath
        ++ " is forbidden because root build-shim automation must not duplicate the `prodbox` CLI surface."

runSubprocessStreaming :: FilePath -> [(String, String)] -> FilePath -> [String] -> IO ExitCode
runSubprocessStreaming repoRoot environment subprocessPath arguments = do
  runResult <-
    Subprocess.runSubprocessStreaming
      Subprocess.Subprocess
        { Subprocess.subprocessPath = subprocessPath
        , Subprocess.subprocessArguments = arguments
        , Subprocess.subprocessEnvironment = Just environment
        , Subprocess.subprocessWorkingDirectory = Just repoRoot
        }
  case runResult of
    Failure err -> do
      writeError (fatalError (Text.pack err))
      pure (ExitFailure 1)
    Success exitCode -> pure exitCode

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)
