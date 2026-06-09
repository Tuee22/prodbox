{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Main (main) where

import Control.Exception (finally)
import Control.Monad (forM_)
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
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Either (isRight)
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List
  ( elemIndex
  , isInfixOf
  , isPrefixOf
  , sort
  )
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import Data.Vector qualified as Vector
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
  , runApp
  )
import Prodbox.Aws
  ( AwsSetupInput (..)
  , AwsTeardownInput (..)
  , ConfigSetupInput (..)
  , SessionTokenPromptShape (..)
  , buildIamPolicyDocument
  , categorizePulumiResidue
  , harnessPostflightResiduePolicy
  , longLivedStackNames
  , operationalAwsConfigResidueFromKey
  , operationalIamUserResidueFromExists
  , operationalManagedResources
  , partitionResidueByLifecycle
  , perRunStackNames
  , pulumiDestroyPlanForResidue
  , renderAwsSetupPlan
  , renderAwsTeardownPlan
  , renderConfigSetupPlan
  , renderPulumiResidueLongLivedRefusal
  , renderPulumiResidueRefusal
  , sessionTokenPromptShape
  )
import Prodbox.AwsEnvironment
  ( isolatedAwsEnvironment
  , overlayAwsCredentials
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
  , GatewayCommand (..)
  , HostCommand (..)
  , IntegrationSuite (..)
  , K8sCommand (..)
  , NativeCommand (..)
  , NukeOptions (..)
  , PlanOptions (..)
  , PolicyTier (..)
  , PulumiCommand (..)
  , PulumiResiduePolicy (..)
  , Rke2Command (..)
  , Rke2DeleteFlags (..)
  , TestCommand (..)
  , TestScope (..)
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.CLI.Docs (renderCommandHelp)
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
import Prodbox.CLI.Pulumi (renderPulumiPlan)
import Prodbox.CLI.Rke2
  ( MinioImageSource (..)
  , acmeClusterIssuerSpec
  , acmeRuntimeManifestWith
  , adminPublicEdgeManifestItems
  , cascadeOrderNarration
  , inferCascadeSubstrate
  , renderMinioChartArgs
  , renderNativeInstallPlan
  )
import Prodbox.CLI.Spec
  ( awsTeardownPolicyFromFlags
  , commandRegistry
  , findCommandSpec
  , leafCommandPaths
  )
import Prodbox.CLI.Tree (renderCommandTree)
import Prodbox.CheckCode
  ( DoctrineViolation (..)
  , doctrineViolationsInPaths
  , extractStringLiterals
  , iamCreateSiteViolations
  , listRepoOwnedPaths
  , matchesSprintToken
  , pulumiCreateSiteViolations
  )
import Prodbox.CheckCode qualified
import Prodbox.ContainerImage qualified as ContainerImage
import Prodbox.Daemon.Events qualified as DaemonEvents
import Prodbox.Effect
  ( Effect (..)
  , Validation (..)
  )
import Prodbox.EffectDAG
  ( EffectNode (..)
  , transitiveClosureIds
  )
import Prodbox.EffectInterpreter
  ( InterpreterContext (..)
  , runEffect
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
import Prodbox.Gateway.Logging
  ( Severity (..)
  , severityFromLogLevel
  , shouldLogSeverity
  )
import Prodbox.Gateway.Peer
  ( PeerEventBatch (..)
  , PeerTransportRequest (..)
  , encodePeerEventBatch
  , handlePeerRequest
  , parsePeerEventBatch
  , parsePeerHttpRequest
  )
import Prodbox.Gateway.Peer qualified as Peer
import Prodbox.Gateway.Settings qualified as GatewaySettings
import Prodbox.Gateway.Types
  ( DaemonConfig (..)
  , Disposition (..)
  , DnsWriteGate (..)
  , GatewayRule (..)
  , Orders (..)
  , PeerEndpoint (..)
  , SignedEvent (..)
  , appendIfNew
  , canWriteDns
  , defaultMaxClockSkewSeconds
  , emptyCommitLog
  , encodeEvent
  , eventTypeClaim
  , eventTypeHeartbeat
  , eventTypeYield
  , nodeDisposition
  , parseEvent
  , parseOrders
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
import Prodbox.Http.Client qualified
import Prodbox.Infra.AwsEksTestStack qualified as AwsEks
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
  )
import Prodbox.Infra.MinioBackend
  ( firstReadableKubeconfigCandidate
  , localKubeconfigCandidates
  , parseDeletedMinioExportHostPath
  )
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
  , ChartReleasePlan (..)
  , PublicEdgePreserveOutcome (..)
  , buildChartDeletePlan
  , buildChartDeploymentPlan
  , buildChartDeploymentPlanForSubstrate
  , certManagerAdoptionAnnotations
  , classifyPublicEdgePreserve
  , renderPublicEdgePreserveOutcome
  , resolveChartSecrets
  , retainedPublicEdgeTlsSecretManifest
  , supportedChartNames
  )
import Prodbox.Lib.EksContainerdMirror qualified
import Prodbox.Lib.EksCustomImagePush qualified
import Prodbox.Lib.EksImageMirror qualified
import Prodbox.Lib.Storage
  ( ChartStorageBinding (..)
  , ChartStorageSpec (..)
  , chartDynamicStorageManifest
  , storageBinding
  )
import Prodbox.Lifecycle.K8sDrain
  ( CascadeDecision (..)
  , DrainResult (..)
  , K8sDrainEnv (..)
  , cascadeDecisionFromDrainResult
  )
import Prodbox.Lifecycle.LiveResidue (PerRunResidueStatuses (..))
import Prodbox.Lifecycle.LiveResidue qualified as LiveResidue
import Prodbox.Lifecycle.Preconditions qualified as Preconditions
import Prodbox.Lifecycle.ResidueStatus qualified as Residue
import Prodbox.Lifecycle.ResourceClass qualified as ResourceClass
import Prodbox.Lifecycle.ResourceRegistry qualified as ResourceRegistry
import Prodbox.Lifecycle.TagSweep qualified as TagSweep
import Prodbox.Naming
  ( boundedResourceName
  , hashSuffix
  , sanitizeResourceName
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
import Prodbox.PublicEdge
  ( publicEdgeClusterIssuerName
  , publicEdgeTlsRetentionKey
  )
import Prodbox.Result qualified as Result
import Prodbox.Retry
  ( RetryPolicy (..)
  , retryDelayMicros
  )
import Prodbox.Secret.Derive qualified
import Prodbox.Secret.EnsureNamespace qualified as EnsureNamespace
import Prodbox.Secret.Inventory qualified as Inventory
import Prodbox.Secret.MasterSeed qualified as MasterSeed
import Prodbox.Secret.Wire qualified
import Prodbox.Service
  ( RedisError (..)
  , ServiceError (..)
  , retryServiceAction
  )
import Prodbox.Ses.SmtpPassword qualified
import Prodbox.Settings
  ( AcmeSection (..)
  , AwsSubstrateSection (..)
  , ConfigFile (..)
  , Credentials (..)
  , DeploymentSection (..)
  , DomainSection (..)
  , MetallbBgpPeer (..)
  , PulumiStateBackendSection (..)
  , Route53Section (..)
  , StorageSection (..)
  , ValidatedSettings (..)
  , defaultConfigFile
  , loadConfigFile
  , renderConfigDhall
  , renderSettingsDisplay
  , validateAndLoadSettings
  , validatePublicEdgeDeployment
  )
import Prodbox.StateMachine
  ( ChartState (..)
  , GatewayOwnershipState (..)
  , PulumiState (..)
  , chartApply
  , chartPlan
  , chartVerify
  , completeClaim
  , promotePulumi
  , startClaim
  , startPulumiUpdate
  )
import Prodbox.Subprocess
  ( renderSubprocess
  , pattern Subprocess
  )
import Prodbox.Substrate (Substrate (..))
import Prodbox.TestPlan
  ( NativeSuitePlan (..)
  , NativeValidation (..)
  , TestExecutionMode (..)
  , TestExecutionPlan (..)
  , nativeValidationId
  , testExecutionPlan
  )
import Prodbox.TestRunner
  ( PublicEdgeCertificateFailure (..)
  , awsPostflightDestroyCommandArgs
  , awsSubstrateBootstrapCommandArgs
  , clearOperationalCredsAfterPostflight
  , publicEdgeCertificateReissueStatusPatch
  , supportedRuntimeBootstrapNeedsKeycloakSmtpSync
  , supportedRuntimeBootstrapNeedsReconcile
  )
import Prodbox.TestValidation
  ( assertInviteOidcClaims
  , verifyAwsTestSshReachability
  )
import Prodbox.UsersAdmin qualified
import Prodbox.Workload.Settings qualified as WorkloadSettings
import System.Directory
  ( Permissions (..)
  , copyFile
  , createDirectoryIfMissing
  , doesFileExist
  , getCurrentDirectory
  , getPermissions
  , setPermissions
  )
import System.Environment
  ( lookupEnv
  , setEnv
  , unsetEnv
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import TestSupport

-- | Predicate helper for `Either String a` test assertions: passes
-- when the result is `Left msg` and `msg` contains the supplied
-- substring. Lets the `shouldSatisfy` call site stay free of nested
-- case lambdas (forbidden by `haskell-style` linting rules).
leftContains :: String -> Either String a -> Bool
leftContains needle result = case result of
  Left msg -> needle `isInfixOf` msg
  Right _ -> False

main :: IO ()
main = mainWithSuite "prodbox-unit" $ do
  parserSuite
  describe "CLI parser" $ do
    it "routes config show to the native Haskell command" $ do
      parseArgs ["config", "show", "--show-secrets"]
        `shouldBe` Right (Options False (RunNative (NativeConfig (ConfigShow True))))

    it "routes native host commands through the Haskell runtime" $ do
      parseArgs ["host", "info"]
        `shouldBe` Right (Options False (RunNative (NativeHost HostInfo)))

    it "routes host public-edge through the native Haskell runtime" $ do
      parseArgs ["host", "public-edge"]
        `shouldBe` Right (Options False (RunNative (NativeHost (HostPublicEdge SubstrateHomeLocal))))

    it "routes host public-edge --substrate aws to the AWS-substrate diagnostic" $ do
      parseArgs ["host", "public-edge", "--substrate", "aws"]
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
                            , daemonLogLevel = Nothing
                            , daemonPort = Nothing
                            , daemonForeground = True
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
      parseArgs ["aws", "check-quotas"]
        `shouldBe` Right (Options False (RunNative (NativeAws AwsCheckQuotas)))

    it "routes aws request-quotas to the native Haskell runtime" $ do
      parseArgs ["aws", "request-quotas", "--tier", "core"]
        `shouldBe` Right (Options False (RunNative (NativeAws (AwsRequestQuotas PolicyCore))))

    it "routes tla-check through the native Haskell runtime" $ do
      parseArgs ["tla-check"]
        `shouldBe` Right (Options False (RunNative NativeTlaCheck))

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

    it "routes rke2 commands through the native Haskell runtime" $ do
      parseArgs ["rke2", "delete", "--yes"]
        `shouldBe` Right
          ( Options
              False
              ( RunNative
                  ( NativeRke2
                      ( Rke2Delete
                          ( Rke2DeleteFlags
                              { rke2DeleteYes = True
                              , rke2DeleteCascade = False
                              , rke2DeleteAllowPulumiResidue = False
                              }
                          )
                          (PlanOptions False Nothing)
                      )
                  )
              )
          )

    it "routes rke2 delete --cascade through the native Haskell runtime" $ do
      parseArgs ["rke2", "delete", "--yes", "--cascade"]
        `shouldBe` Right
          ( Options
              False
              ( RunNative
                  ( NativeRke2
                      ( Rke2Delete
                          ( Rke2DeleteFlags
                              { rke2DeleteYes = True
                              , rke2DeleteCascade = True
                              , rke2DeleteAllowPulumiResidue = False
                              }
                          )
                          (PlanOptions False Nothing)
                      )
                  )
              )
          )

    it "routes rke2 delete --allow-pulumi-residue through the native Haskell runtime" $ do
      parseArgs ["rke2", "delete", "--yes", "--allow-pulumi-residue"]
        `shouldBe` Right
          ( Options
              False
              ( RunNative
                  ( NativeRke2
                      ( Rke2Delete
                          ( Rke2DeleteFlags
                              { rke2DeleteYes = True
                              , rke2DeleteCascade = False
                              , rke2DeleteAllowPulumiResidue = True
                              }
                          )
                          (PlanOptions False Nothing)
                      )
                  )
              )
          )

    it "rejects rke2 delete --cascade --allow-pulumi-residue (mutual exclusion)" $ do
      case parseArgs ["rke2", "delete", "--yes", "--cascade", "--allow-pulumi-residue"] of
        Left _ -> pure ()
        Right value ->
          expectationFailure
            ( "Expected parse failure for --cascade + --allow-pulumi-residue, got: "
                ++ show value
            )

    it "routes pulumi commands through the native Haskell runtime" $ do
      parseArgs ["pulumi", "test-resources"]
        `shouldBe` Right
          (Options False (RunNative (NativePulumi (PulumiTestResources (PlanOptions False Nothing)))))

      parseArgs ["pulumi", "eks-destroy", "--yes"]
        `shouldBe` Right
          ( Options
              False
              (RunNative (NativePulumi (PulumiEksDestroy True (PlanOptions False Nothing))))
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

    it "routes native k8s commands through the Haskell runtime with defaults" $ do
      parseArgs ["k8s", "logs"]
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

  describe "plan renderers" $ do
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

    goldenTest
      "renders the gateway start plan deterministically"
      "test/golden/plans/gateway-start.txt"
      $ do
        let configText = renderGatewayConfigTemplate (testValidatedSettings "/tmp/prodbox/.data") "node-a"
        decodeResult <- GatewaySettings.decodeDaemonConfigDhall (Text.pack configText)
        case decodeResult of
          Left err -> fail err
          Right config ->
            pure (BL8.pack (renderGatewayStartPlan "/tmp/prodbox/gateway.dhall" "warn" (Just 4200) True config))

    goldenTest
      "renders the rke2 reconcile plan deterministically"
      "test/golden/plans/rke2-reconcile.txt"
      ( pure
          ( BL8.pack
              ( renderNativeInstallPlan
                  "/tmp/prodbox"
                  (testValidatedSettings "/tmp/prodbox/.data")
                  "machine-id-123"
                  "prodbox-123"
                  "prodbox-123"
              )
          )
      )

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
      cabalProject `shouldContain` "with-compiler: ghc-9.14.1"
      cabalProject `shouldContain` "allow-newer: *:base, *:template-haskell"
      cabalProject `shouldNotContain` "builddir:"

    it "builds the container frontend under /opt/build" $ do
      repoRoot <- getCurrentDirectory
      dockerfile <- readFile (repoRoot </> "docker" </> "prodbox.Dockerfile")

      dockerfile `shouldContain` "# syntax=docker/dockerfile:1.7"
      dockerfile `shouldContain` "FROM ubuntu:24.04"
      dockerfile `shouldContain` "ARG GHC_VERSION=9.14.1"
      dockerfile `shouldContain` "ARG CABAL_VERSION=3.16.1.0"
      dockerfile `shouldContain` "WORKDIR /opt/build"
      dockerfile `shouldContain` "BOOTSTRAP_HASKELL_MINIMAL=1"
      dockerfile `shouldContain` "ghcup install ghc \"${GHC_VERSION}\""
      dockerfile `shouldContain` "ghcup install cabal \"${CABAL_VERSION}\""
      dockerfile `shouldNotContain` "--mount=type=bind,from=haskell-toolchain"
      dockerfile `shouldContain` "cabal build --builddir=.build exe:prodbox"
      dockerfile `shouldContain` "cabal list-bin --builddir=.build exe:prodbox"

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

    it "keeps the gateway chart on repo-rootless startup with Dhall-mounted AWS auth" $ do
      -- Sprint 2.22: AWS credentials are no longer env vars on the Pod;
      -- they are a Dhall fragment mounted at /etc/gateway/secrets/aws.dhall
      -- and imported by config.dhall.
      repoRoot <- getCurrentDirectory
      deploymentTemplate <-
        readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "deployments.yaml")
      awsSecretTemplate <-
        readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "secret-aws-credentials.yaml")

      deploymentTemplate `shouldContain` "secretName: gateway-aws-credentials"
      deploymentTemplate `shouldContain` "scheme: HTTP"
      deploymentTemplate `shouldNotContain` "scheme: HTTPS"
      deploymentTemplate `shouldNotContain` "/app/prodbox-config.json"
      deploymentTemplate `shouldNotContain` "name: AWS_ACCESS_KEY_ID"
      awsSecretTemplate `shouldContain` "name: gateway-aws-credentials"
      awsSecretTemplate `shouldContain` "aws.dhall"
      awsSecretTemplate `shouldNotContain` "prodbox-config.json"

    it "lets AWS SMTP pre-created namespaces be adopted by the gateway release" $ do
      repoRoot <- getCurrentDirectory
      rbacTemplate <-
        readFile (repoRoot </> "charts" </> "gateway" </> "templates" </> "rbac.yaml")

      rbacTemplate `shouldContain` "app.kubernetes.io/managed-by: Helm"
      rbacTemplate `shouldContain` "meta.helm.sh/release-name: {{ $.Release.Name | quote }}"
      rbacTemplate `shouldContain` "meta.helm.sh/release-namespace: {{ $.Release.Namespace | quote }}"
      rbacTemplate `shouldContain` "helm.sh/resource-policy: keep"

    it "delegates Patroni credential Secret ownership to the gateway daemon (Sprint 3.13)" $ do
      repoRoot <- getCurrentDirectory
      let secretsTemplatePath =
            repoRoot </> "charts" </> "keycloak-postgres" </> "templates" </> "00-secrets.yaml"
      secretsTemplateExists <- doesFileExist secretsTemplatePath
      secretsTemplateExists `shouldBe` False
      bootstrapJobTemplate <-
        readFile
          (repoRoot </> "charts" </> "keycloak-postgres" </> "templates" </> "secret-bootstrap-job.yaml")
      postgresTemplate <-
        readFile (repoRoot </> "charts" </> "keycloak-postgres" </> "templates" </> "postgresql.yaml")
      bootstrapJobTemplate `shouldContain` "/v1/secret/ensure-namespace"
      bootstrapJobTemplate `shouldContain` "127.0.0.1:30080/prodbox/curl-mirror:8.11.0"
      bootstrapJobTemplate `shouldContain` "helm.sh/hook\": pre-install,pre-upgrade"
      postgresTemplate `shouldContain` "kind: PerconaPGCluster"
      postgresTemplate `shouldContain` "apiVersion: pgv2.percona.com/v2"

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

    it "keeps the gateway image on the single-stage ubuntu doctrine" $ do
      repoRoot <- getCurrentDirectory
      dockerfile <- readFile (repoRoot </> "docker" </> "gateway.Dockerfile")

      dockerfile `shouldContain` "# syntax=docker/dockerfile:1.7"
      dockerfile `shouldContain` "FROM ubuntu:24.04"
      dockerfile `shouldContain` "ARG GHC_VERSION=9.14.1"
      dockerfile `shouldContain` "ARG CABAL_VERSION=3.16.1.0"
      dockerfile `shouldContain` "awscli.amazonaws.com"
      dockerfile `shouldContain` "dpkg --print-architecture"
      dockerfile `shouldContain` "BOOTSTRAP_HASKELL_MINIMAL=1"
      dockerfile `shouldContain` "ghcup install ghc \"${GHC_VERSION}\""
      dockerfile `shouldContain` "ghcup install cabal \"${CABAL_VERSION}\""
      dockerfile `shouldNotContain` "--mount=type=bind,from=haskell-toolchain"
      dockerfile
        `shouldContain` "ENTRYPOINT [\"/usr/bin/tini\", \"--\", \"/usr/local/bin/prodbox\", \"gateway\", \"start\"]"

    it "keeps the vscode chart on the supported code-server path-prefix flag" $ do
      repoRoot <- getCurrentDirectory
      deploymentTemplate <-
        readFile (repoRoot </> "charts" </> "vscode" </> "templates" </> "deployment.yaml")

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
        `shouldContain` "Right () -> completeDestroy repoRoot projectDir providerEnvironment currentSnapshot summary"

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
              nativeInitialIntegrationGatePrerequisites suitePlan
                `shouldBe` [ "supported_ubuntu_2404"
                           , "tool_docker"
                           , "tool_ctr"
                           , "tool_helm"
                           , "tool_kubectl"
                           , "tool_sudo"
                           , "tool_systemctl"
                           , "settings_object"
                           , "aws_credentials_valid"
                           , "tool_pulumi"
                           , "tool_curl"
                           , "route53_lifecycle_capable"
                           , "tool_dig"
                           , "aws_iam_harness_ready"
                           , "tool_aws"
                           , "tool_ssh"
                           , "route53_accessible"
                           ]
              nativeDeferredIntegrationGatePrerequisites suitePlan
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
                           , "gateway-pods"
                           , "gateway-partition"
                           , "charts-platform"
                           , "keycloak-invite"
                           , "charts-storage"
                           , "lifecycle"
                           ]
            DelegatedSuite _ -> expectationFailure "expected native aggregate test plan"

    it "keeps integration-all in the canonical external-proof-first order" $ do
      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationAll) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-all"
              nativeInitialIntegrationGatePrerequisites suitePlan
                `shouldBe` [ "supported_ubuntu_2404"
                           , "tool_docker"
                           , "tool_ctr"
                           , "tool_helm"
                           , "tool_kubectl"
                           , "tool_sudo"
                           , "tool_systemctl"
                           , "settings_object"
                           , "aws_credentials_valid"
                           , "tool_pulumi"
                           , "tool_curl"
                           , "route53_lifecycle_capable"
                           , "tool_dig"
                           , "aws_iam_harness_ready"
                           , "tool_aws"
                           , "tool_ssh"
                           , "route53_accessible"
                           ]
              nativeDeferredIntegrationGatePrerequisites suitePlan
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
              take 4 (dropWhile (/= ValidationChartsPlatform) (nativeValidations suitePlan))
                `shouldBe` [ ValidationChartsPlatform
                           , ValidationKeycloakInvite
                           , ValidationChartsStorage
                           , ValidationLifecycle
                           ]
              last (nativeValidations suitePlan) `shouldBe` ValidationLifecycle
            DelegatedSuite _ -> expectationFailure "expected native integration-all plan"

    it "bootstraps the AWS substrate by provisioning per-run stacks before deploying the AWS chart set" $ do
      case testExecutionPlan SubstrateAws TestAll of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan ->
              awsSubstrateBootstrapCommandArgs suitePlan
                `shouldBe` [ ["pulumi", "aws-subzone-resources"]
                           , ["pulumi", "eks-resources"]
                           , ["pulumi", "test-resources"]
                           , ["charts", "deploy", "gateway", "--substrate", "aws"]
                           , ["charts", "deploy", "vscode", "--substrate", "aws"]
                           , ["charts", "deploy", "api", "--substrate", "aws"]
                           , ["charts", "deploy", "websocket", "--substrate", "aws"]
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
              supportedRuntimeBootstrapNeedsKeycloakSmtpSync suitePlan `shouldBe` True
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
                `shouldBe` [ ["pulumi", "aws-subzone-destroy", "--yes"]
                           , ["pulumi", "eks-destroy", "--yes"]
                           , ["pulumi", "test-destroy", "--yes"]
                           ]
            DelegatedSuite _ -> expectationFailure "expected native keycloak-invite plan"

      case testExecutionPlan SubstrateAws (TestIntegration IntegrationPublicDns) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-public-dns"
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Just PolicyFull
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
                `shouldBe` [ ["pulumi", "aws-subzone-destroy", "--yes"]
                           , ["pulumi", "eks-destroy", "--yes"]
                           , ["pulumi", "test-destroy", "--yes"]
                           ]
            DelegatedSuite _ -> expectationFailure "expected native aws-eks plan"

    it "maps cluster-backed named suites to native validations plus prerequisites" $ do
      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationAwsEks) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeSuiteId suitePlan `shouldBe` "integration-aws-eks"
              nativeValidations suitePlan `shouldBe` [ValidationAwsEks]
              nativeInitialIntegrationGatePrerequisites suitePlan
                `shouldBe` [ "supported_ubuntu_2404"
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
              nativeDeferredIntegrationGatePrerequisites suitePlan
                `shouldBe` ["pulumi_logged_in"]
              nativeRequiresIntegrationRunbook suitePlan `shouldBe` True
            DelegatedSuite _ -> expectationFailure "expected native aws-eks plan"

    it "gates AWS-backed named suites on validated access before validation bodies run" $ do
      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationPublicDns) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeInitialIntegrationGatePrerequisites suitePlan
                `shouldBe` ["route53_lifecycle_capable", "tool_dig"]
              nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
            DelegatedSuite _ -> expectationFailure "expected native public-dns plan"

      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationDnsAws) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeInitialIntegrationGatePrerequisites suitePlan
                `shouldBe` ["route53_lifecycle_capable"]
              nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
            DelegatedSuite _ -> expectationFailure "expected native dns-aws plan"

      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationAwsIam) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeInitialIntegrationGatePrerequisites suitePlan
                `shouldBe` ["aws_iam_harness_ready", "tool_aws"]
              nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
              nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Just PolicyFull
            DelegatedSuite _ -> expectationFailure "expected native aws-iam plan"

    it "includes curl in the gateway-daemon validation prerequisites" $ do
      case testExecutionPlan SubstrateHomeLocal (TestIntegration IntegrationGatewayDaemon) of
        testPlan ->
          case testPlanExecutionMode testPlan of
            NativeSuite suitePlan -> do
              nativeInitialIntegrationGatePrerequisites suitePlan
                `shouldBe` [ "supported_ubuntu_2404"
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

    it "keeps gateway-partition on a native validation path distinct from tla-check" $ do
      repoRoot <- getCurrentDirectory
      validationSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "TestValidation.hs")

      validationSource `shouldContain` "ValidationGatewayPartition -> runGatewayPartitionValidation"
      validationSource `shouldContain` "FORMAL_MODEL_DELEGATED=false"
      validationSource
        `shouldNotContain` "ValidationGatewayPartition -> runNativeCliCommandForExitCode repoRoot environment [\"tla-check\"]"

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
              nativeInitialIntegrationGatePrerequisites suitePlan
                `shouldBe` [ "supported_ubuntu_2404"
                           , "tool_docker"
                           , "tool_ctr"
                           , "tool_helm"
                           , "tool_kubectl"
                           , "tool_sudo"
                           , "tool_systemctl"
                           , "settings_object"
                           , "aws_credentials_valid"
                           , "tool_pulumi"
                           , "tool_curl"
                           ]
              nativeDeferredIntegrationGatePrerequisites suitePlan
                `shouldBe` ["pulumi_logged_in"]
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
              nativeInitialIntegrationGatePrerequisites suitePlan
                `shouldBe` [ "supported_ubuntu_2404"
                           , "tool_docker"
                           , "tool_ctr"
                           , "tool_helm"
                           , "tool_kubectl"
                           , "tool_sudo"
                           , "tool_systemctl"
                           , "settings_object"
                           , "aws_credentials_valid"
                           , "tool_pulumi"
                           , "tool_curl"
                           ]
              nativeDeferredIntegrationGatePrerequisites suitePlan
                `shouldBe` ["pulumi_logged_in"]
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
      rke2Source `shouldContain` "persistence.imageChartStorage.type=s3"
      rke2Source `shouldContain` "persistence.imageChartStorage.disableredirect=true"
      rke2Source `shouldContain` "mc mb --ignore-existing local/"

    it "retries transient Harbor publication failures during custom and mirrored image publication" $ do
      repoRoot <- getCurrentDirectory
      rke2Source <- readFile (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Rke2.hs")

      rke2Source `shouldContain` "customImagePushRetryPolicy :: RetryPolicy"
      rke2Source `shouldContain` "retryPolicyMaxAttempts = 3"
      rke2Source `shouldContain` "retryPolicyBaseDelayMicros = 5000000"
      rke2Source `shouldContain` "pushDockerImageWithRetry"
      rke2Source `shouldContain` "isRetryableHarborPublicationFailure"
      rke2Source `shouldContain` "Retrying Harbor publication for "
      rke2Source `shouldContain` "\"unexpected eof\""
      rke2Source `shouldContain` "\"unexpected status from put request\""
      rke2Source `shouldContain` "\"connection refused\""

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
      minioSource `shouldContain` "\"rollout\", \"restart\", \"deployment/\" ++ minioDeploymentName"

    it "uses the active chart cluster MinIO port-forward for host-side master-seed bootstrap" $ do
      repoRoot <- getCurrentDirectory
      hostBootstrapSource <-
        readFile (repoRoot </> "src" </> "Prodbox" </> "Secret" </> "HostBootstrap.hs")
      rke2Source <- readFile (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Rke2.hs")
      minioSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "MinioBackend.hs")

      minioSource `shouldContain` "withCurrentMinioPortForward"
      minioSource `shouldContain` "subprocessEnvironment = environment"
      hostBootstrapSource
        `shouldContain` "import Prodbox.Infra.MinioBackend (withCurrentMinioPortForward)"
      hostBootstrapSource `shouldContain` "portForwardResult <- withCurrentMinioPortForward"
      rke2Source `shouldContain` "import Prodbox.Infra.MinioBackend (withCurrentMinioPortForward)"
      rke2Source `shouldContain` "portForwardResult <- withCurrentMinioPortForward"

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

      chartPlatformSource `shouldContain` "runPg [\"get\", \"crd\", patroniPostgresqlCrdName"
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
      transitiveClosureIds ["tool_systemctl", "supported_ubuntu_2404"] prerequisiteRegistry
        `shouldBe` Right ["platform_linux", "supported_ubuntu_2404", "systemd_available", "tool_systemctl"]

  describe "prerequisite registry" $ do
    it "covers the full shared prerequisite inventory" $ do
      sort (Map.keys prerequisiteRegistry)
        `shouldBe` sort
          [ "platform_linux"
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
          , "settings_loaded"
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

    it "has no direct self-reference or dependency cycles" $ do
      all
        (\(key, node) -> key `notElem` effectNodePrerequisites node)
        (Map.toList prerequisiteRegistry)
        `shouldBe` True
      all (not . hasCycle Set.empty) (Map.keys prerequisiteRegistry) `shouldBe` True

    it "keeps the expected dependency chains for infrastructure prerequisites" $ do
      effectNodePrerequisites (lookupPrerequisiteNode "aws_credentials_valid")
        `shouldBe` ["settings_loaded", "tool_aws"]
      effectNodePrerequisites (lookupPrerequisiteNode "aws_iam_harness_ready")
        `shouldBe` []
      effectNodePrerequisites (lookupPrerequisiteNode "route53_accessible")
        `shouldBe` ["aws_credentials_valid"]
      effectNodePrerequisites (lookupPrerequisiteNode "route53_lifecycle_capable")
        `shouldBe` ["route53_accessible"]
      effectNodePrerequisites (lookupPrerequisiteNode "rke2_service_exists")
        `shouldBe` ["rke2_installed", "systemd_available", "supported_ubuntu_2404"]
      effectNodePrerequisites (lookupPrerequisiteNode "rke2_service_active")
        `shouldBe` ["rke2_service_exists"]
      effectNodePrerequisites (lookupPrerequisiteNode "k8s_cluster_reachable")
        `shouldBe` ["tool_kubectl", "kubeconfig_exists", "rke2_service_active"]
      effectNodePrerequisites (lookupPrerequisiteNode "pulumi_logged_in")
        `shouldBe` ["tool_pulumi", "k8s_cluster_reachable"]
      effectNodePrerequisites (lookupPrerequisiteNode "k8s_ready")
        `shouldBe` ["k8s_cluster_reachable", "rke2_service_active"]
      effectNodePrerequisites (lookupPrerequisiteNode "infra_ready")
        `shouldBe` ["k8s_ready", "aws_credentials_valid"]
      effectNodePrerequisites (lookupPrerequisiteNode "gateway_daemon_acquire")
        `shouldBe` ["platform_linux"]

    it "uses the expected validation and no-op effect shapes" $ do
      lookupPrerequisiteEffect "platform_linux" `shouldBe` Validate RequireLinux
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
      lookupPrerequisiteEffect "settings_loaded" `shouldBe` Validate RequireSettings
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
      lookupPrerequisiteEffect "gateway_daemon_acquire" `shouldBe` Noop

    it "expands shared prerequisite chains transitively" $ do
      transitiveClosureIds ["rke2_service_active"] prerequisiteRegistry
        `shouldBe` Right
          [ "platform_linux"
          , "rke2_installed"
          , "rke2_service_active"
          , "rke2_service_exists"
          , "supported_ubuntu_2404"
          , "systemd_available"
          ]
      transitiveClosureIds ["route53_accessible"] prerequisiteRegistry
        `shouldBe` Right
          [ "aws_credentials_valid"
          , "route53_accessible"
          , "settings_loaded"
          , "tool_aws"
          ]
      transitiveClosureIds ["route53_lifecycle_capable"] prerequisiteRegistry
        `shouldBe` Right
          [ "aws_credentials_valid"
          , "route53_accessible"
          , "route53_lifecycle_capable"
          , "settings_loaded"
          , "tool_aws"
          ]
      transitiveClosureIds ["pulumi_logged_in"] prerequisiteRegistry
        `shouldBe` Right
          [ "k8s_cluster_reachable"
          , "kubeconfig_exists"
          , "platform_linux"
          , "pulumi_logged_in"
          , "rke2_installed"
          , "rke2_service_active"
          , "rke2_service_exists"
          , "supported_ubuntu_2404"
          , "systemd_available"
          , "tool_kubectl"
          , "tool_pulumi"
          ]
      transitiveClosureIds ["infra_ready"] prerequisiteRegistry
        `shouldBe` Right
          [ "aws_credentials_valid"
          , "infra_ready"
          , "k8s_cluster_reachable"
          , "k8s_ready"
          , "kubeconfig_exists"
          , "platform_linux"
          , "rke2_installed"
          , "rke2_service_active"
          , "rke2_service_exists"
          , "settings_loaded"
          , "supported_ubuntu_2404"
          , "systemd_available"
          , "tool_aws"
          , "tool_kubectl"
          ]

    it "fails fast when a prerequisite id is missing from the registry" $ do
      transitiveClosureIds ["definitely_missing_node"] prerequisiteRegistry
        `shouldBe` Left "Missing effect node in registry: definitely_missing_node"

  describe "shared runtime helpers" $ do
    it "round-trips the rendered repo-root Dhall config through loadConfigFile" $
      withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        copyFile
          (repoRoot </> "prodbox-config-types.dhall")
          (tmpDir </> "prodbox-config-types.dhall")
        writeFile (tmpDir </> "prodbox-config.dhall") (renderConfigDhall roundTripConfigFile)

        loadConfigFile tmpDir `shouldReturn` Right roundTripConfigFile

    -- Sprint 2.20: the JSON `parseDaemonConfig` round-trip tests are
    -- superseded by the Dhall `decodeDaemonConfigDhall` coverage in the
    -- `Sprint 2.20 daemon Dhall settings` describe block above. The legacy
    -- JSON parser is removed from `Prodbox.Gateway.Types` as Phase 2 closure.

    it "round-trips persisted gateway orders through JSON" $ do
      parseOrders (BL8.unpack (encodeJsonValue (ordersJsonValue sampleOrders)))
        `shouldBe` Right sampleOrders

    it "round-trips persisted signed gateway events through JSON" $ do
      parseEvent (encodeEvent sampleSignedEvent) `shouldBe` Right sampleSignedEvent

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
              then Left (RedisError (ServiceError "transient" True))
              else Right ("ready" :: String)
      attempts <- readIORef attemptsRef
      result `shouldBe` Right "ready"
      attempts `shouldBe` 3

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

    it "typechecks the doctrine state-machine transitions" $ do
      case completeClaim (startClaim GatewayIdleState) of
        GatewayOwnerState -> pure ()
      case chartVerify (chartApply chartPlan) of
        ChartVerifiedState -> pure ()
      case promotePulumi (startPulumiUpdate PulumiSelectedState) of
        PulumiReadyState -> pure ()

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

  describe "native chart platform helpers" $ do
    it "extracts deleted MinIO export host paths from mountinfo" $ do
      parseDeletedMinioExportHostPath
        "14443 14435 8:2 /home/matthewnowak/prodbox/.data/prodbox-123/prodbox-minio-pv-0//deleted /export rw,relatime - ext4 /dev/sda2 rw\n"
        `shouldBe` Just "/home/matthewnowak/prodbox/.data/prodbox-123/prodbox-minio-pv-0"

      parseDeletedMinioExportHostPath
        "14443 14435 8:2 /home/matthewnowak/prodbox/.data/prodbox-123/prodbox-minio-pv-0 /export rw,relatime - ext4 /dev/sda2 rw\n"
        `shouldBe` Nothing

    it "derives deterministic storage bindings" $ do
      let spec =
            ChartStorageSpec
              { chartStorageSpecStatefulSetName = "vscode"
              , chartStorageSpecPersistentVolumeClaimName = "vscode-data-0"
              , chartStorageSpecStorageSize = "20Gi"
              , chartStorageSpecOrdinal = 0
              , chartStorageSpecClaimSuffix = "data"
              }
          binding = storageBinding "/tmp/prodbox/.data" "vscode" "vscode" spec
      chartStorageBindingPersistentVolumeName binding
        `shouldBe` "prodbox-chart-vscode-vscode-vscode-0-data"
      chartStorageBindingHostPath binding
        `shouldBe` "/tmp/prodbox/.data/vscode/vscode/vscode/0/data"

    it "lists supported charts in canonical order" $ do
      supportedChartNames `shouldBe` ["keycloak", "vscode", "api", "websocket", "gateway"]

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
                        `shouldBe` Just (String "127.0.0.1:30080/prodbox/prodbox-gateway")
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
                Right _ -> expectationFailure "expected gateway values object"
                Left err -> expectationFailure err
            _ -> expectationFailure "expected one gateway release"

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
                        `shouldBe` Just (String "127.0.0.1:30080/prodbox/prodbox-public-edge-workload")
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

    it "renders AWS vscode plans with dynamic gp2 Patroni storage" $ do
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
                        `shouldBe` Just (String "gp2")
                    _ -> expectationFailure "expected keycloak-postgres storage payload"
                Right _ -> expectationFailure "expected keycloak-postgres values object"
                Left err -> expectationFailure err
            _ -> expectationFailure "expected one keycloak-postgres release"

    it "renders AWS dynamic storage as PVCs without manual PV hostPath artifacts" $ do
      let spec =
            ChartStorageSpec
              { chartStorageSpecStatefulSetName = "vscode"
              , chartStorageSpecPersistentVolumeClaimName = "vscode-data-0"
              , chartStorageSpecStorageSize = "50Gi"
              , chartStorageSpecOrdinal = 0
              , chartStorageSpecClaimSuffix = "data"
              }
          binding = storageBinding "/tmp/prodbox/.data" "vscode" "vscode" spec
          manifestJson =
            BL8.unpack
              (encode (chartDynamicStorageManifest "vscode" "vscode" "gp2" [binding]))
      manifestJson `shouldContain` "\"kind\":\"PersistentVolumeClaim\""
      manifestJson `shouldContain` "\"storageClassName\":\"gp2\""
      manifestJson `shouldContain` "\"name\":\"vscode-data-0\""
      manifestJson `shouldNotContain` "\"kind\":\"PersistentVolume\""
      manifestJson `shouldNotContain` "\"hostPath\""
      manifestJson `shouldNotContain` "\"volumeName\""
      manifestJson `shouldNotContain` "\"storageClassName\":\"manual\""

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
                    Just (Object applicationPayload) ->
                      KeyMap.lookup (Key.fromString "name") applicationPayload
                        `shouldBe` Just (String "prodbox-vscode-pg-pguser-keycloak")
                    _ -> expectationFailure "expected keycloak-postgres application secret payload"
                  case KeyMap.lookup (Key.fromString "superuser") secretsPayload of
                    Just (Object superuserPayload) ->
                      KeyMap.lookup (Key.fromString "name") superuserPayload
                        `shouldBe` Just (String "prodbox-vscode-pg-pguser-postgres")
                    _ -> expectationFailure "expected keycloak-postgres superuser secret payload"
                  case KeyMap.lookup (Key.fromString "standby") secretsPayload of
                    Just (Object standbyPayload) -> do
                      KeyMap.lookup (Key.fromString "name") standbyPayload
                        `shouldBe` Just (String "prodbox-vscode-pg-primaryuser")
                      KeyMap.lookup (Key.fromString "username") standbyPayload
                        `shouldBe` Just (String "primaryuser")
                    _ -> expectationFailure "expected keycloak-postgres standby secret payload"
                _ -> expectationFailure "expected keycloak-postgres secrets payload"
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
                  -- Sprint 3.13 chunks 11 + 28: vscode chart reads the
                  -- OIDC client-secret via Helm `lookup` of the
                  -- daemon-applied `keycloak-oidc-clients` Secret in the
                  -- release namespace. `valuesForVscode` no longer emits
                  -- `oidc.clientSecret`, so the chart values payload should
                  -- not carry the key.
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
                    `shouldBe` "prodbox-chart-vscode-vscode-vscode-0-data"
                _ -> expectationFailure "expected vscode storage binding"
            [] -> expectationFailure "expected releases in chart deployment plan"
            _ -> expectationFailure "expected keycloak-postgres, keycloak, and vscode releases"

    -- Sprint 3.13 chunks 12 + 14 closed the host-side `.prodbox-state/charts`
    -- chart-secret cache. The two prior tests in this slot exercised the
    -- cache's read/merge + Patroni recovery path against `resolveChartSecrets`
    -- + `mergeChartSecretValues`; both have been deleted. The invariant
    -- they were guarding ("host-side secret state is the source of truth")
    -- is now structurally inverted: the cluster's k8s Secrets (materialized
    -- by the gateway daemon's `ensure-namespace` handler for data-bound
    -- fields, and read via Helm `lookup` from chart templates) are the
    -- source of truth. The check below pins that inversion at the
    -- ChartPlatform surface — `resolveChartSecrets` no longer reads or
    -- writes any host-side state.
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
                  , (Key.fromString "event_count", Number 5)
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
                  [ "{ schemaVersion = 1"
                  , ", boot ="
                  , "  { node_id = \"node-a\""
                  , "  , cert_file = \"node-a.crt\""
                  , "  , key_file = \"node-a.key\""
                  , "  , ca_file = \"ca.crt\""
                  , "  , orders_file = \"orders.dhall\""
                  , "  , event_keys ="
                  , "    [ { name = \"node-a\", value = \"REPLACE_WITH_SECRET_KEY\" } ]"
                  , "  , dns_write_gate ="
                  , "      None { zone_id : Text, fqdn : Text, ttl : Natural, aws_region : Text }"
                  , "  , aws_creds ="
                  , "      None { access_key_id : Text, secret_access_key : Text, session_token : Optional Text, region : Text }"
                  , "  , minio_creds ="
                  , "      None { minio_access_key : Text, minio_secret_key : Text }"
                  , "  , minio_endpoint_url = None Text"
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
        writeFile (tmpDir </> "prodbox-config.dhall") validConfig

        result <- validateAndLoadSettings tmpDir

        case result of
          Left err -> expectationFailure err
          Right settings -> do
            decoded <-
              GatewaySettings.decodeDaemonConfigDhall
                (Text.pack (renderGatewayConfigTemplate settings "node-a"))
            case decoded of
              Left err -> expectationFailure err
              Right config ->
                case daemonDnsWriteGate config of
                  Nothing -> expectationFailure "expected Just DnsWriteGate"
                  Just gate -> do
                    dnsWriteGateFqdn gate `shouldBe` "test.resolvefintech.com"
                    dnsWriteGateZoneId gate `shouldBe` "Z1234567890ABC"
                    dnsWriteGateTtl gate `shouldBe` 60
                    dnsWriteGateAwsRegion gate `shouldBe` "us-east-1"

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
                [ "{ schemaVersion = 1"
                , ", boot ="
                , "  { node_id = \"node-a\""
                , "  , cert_file = \"node-a.crt\""
                , "  , key_file = \"node-a.key\""
                , "  , ca_file = \"ca.crt\""
                , "  , orders_file = \"orders.dhall\""
                , "  , event_keys ="
                , "    [ { name = \"node-a\", value = \"abcdef0123456789\" } ]"
                , "  , dns_write_gate ="
                , "      Some { zone_id = \"Z123\""
                , "           , fqdn = \"test.example.com\""
                , "           , ttl = 60"
                , "           , aws_region = \"us-east-1\""
                , "           }"
                , "  , aws_creds ="
                , "      None { access_key_id : Text, secret_access_key : Text, session_token : Optional Text, region : Text }"
                , "  , minio_creds ="
                , "      None { minio_access_key : Text, minio_secret_key : Text }"
                , "  , minio_endpoint_url = None Text"
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
                  [ "{ schemaVersion = 99"
                  , ", boot ="
                  , "  { node_id = \"node-a\""
                  , "  , cert_file = \"a.crt\""
                  , "  , key_file = \"a.key\""
                  , "  , ca_file = \"ca.crt\""
                  , "  , orders_file = \"orders.dhall\""
                  , "  , event_keys = [] : List { name : Text, value : Text }"
                  , "  , dns_write_gate ="
                  , "      None { zone_id : Text"
                  , "           , fqdn : Text"
                  , "           , ttl : Natural"
                  , "           , aws_region : Text"
                  , "           }"
                  , "  , aws_creds ="
                  , "      None { access_key_id : Text, secret_access_key : Text, session_token : Optional Text, region : Text }"
                  , "  , minio_creds ="
                  , "      None { minio_access_key : Text, minio_secret_key : Text }"
                  , "  , minio_endpoint_url = None Text"
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
      result <- GatewaySettings.decodeDaemonConfigDhall mismatched
      case result of
        Right _ -> expectationFailure "expected schema-mismatch failure"
        Left err -> err `shouldContain` "config_schema_mismatch"

    it "fails fast when a required boot field is empty" $ do
      let emptyNode =
            Text.pack
              ( unlines
                  [ "{ schemaVersion = 1"
                  , ", boot ="
                  , "  { node_id = \"\""
                  , "  , cert_file = \"a.crt\""
                  , "  , key_file = \"a.key\""
                  , "  , ca_file = \"ca.crt\""
                  , "  , orders_file = \"orders.dhall\""
                  , "  , event_keys = [] : List { name : Text, value : Text }"
                  , "  , dns_write_gate ="
                  , "      None { zone_id : Text"
                  , "           , fqdn : Text"
                  , "           , ttl : Natural"
                  , "           , aws_region : Text"
                  , "           }"
                  , "  , aws_creds ="
                  , "      None { access_key_id : Text, secret_access_key : Text, session_token : Optional Text, region : Text }"
                  , "  , minio_creds ="
                  , "      None { minio_access_key : Text, minio_secret_key : Text }"
                  , "  , minio_endpoint_url = None Text"
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
      result <- GatewaySettings.decodeDaemonConfigDhall emptyNode
      case result of
        Right _ -> expectationFailure "expected empty-node_id failure"
        Left err -> err `shouldContain` "node_id is required"

    it "fails fast when heartbeat_interval_seconds is zero" $ do
      let zeroHb =
            Text.pack
              ( unlines
                  [ "{ schemaVersion = 1"
                  , ", boot ="
                  , "  { node_id = \"node-a\""
                  , "  , cert_file = \"a.crt\""
                  , "  , key_file = \"a.key\""
                  , "  , ca_file = \"ca.crt\""
                  , "  , orders_file = \"orders.dhall\""
                  , "  , event_keys = [] : List { name : Text, value : Text }"
                  , "  , dns_write_gate ="
                  , "      None { zone_id : Text"
                  , "           , fqdn : Text"
                  , "           , ttl : Natural"
                  , "           , aws_region : Text"
                  , "           }"
                  , "  , aws_creds ="
                  , "      None { access_key_id : Text, secret_access_key : Text, session_token : Optional Text, region : Text }"
                  , "  , minio_creds ="
                  , "      None { minio_access_key : Text, minio_secret_key : Text }"
                  , "  , minio_endpoint_url = None Text"
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
      result <- GatewaySettings.decodeDaemonConfigDhall zeroHb
      case result of
        Right _ -> expectationFailure "expected positive-heartbeat failure"
        Left err -> err `shouldContain` "heartbeat_interval_seconds must be positive"

    it "dispatches by .dhall extension when loading from a file" $
      withSystemTempDirectory "prodbox-daemon-dhall" $ \tmpDir -> do
        let path = tmpDir </> "config.dhall"
        writeFile path (Text.unpack happyDhall)
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
        Right _ -> expectationFailure "expected ranked_nodes subset failure"
        Left err -> err `shouldContain` "must be a subset"

  describe "Sprint 3.14 workload Dhall settings" $ do
    it "decodes a happy-path api workload Dhall config" $ do
      let dhallSrc =
            Text.pack
              ( unlines
                  [ "{ schemaVersion = 1"
                  , ", mode = < Api | Websocket >.Api"
                  , ", log_level = None Text"
                  , ", workload_port = Some 8080"
                  , ", redis = None { host : Text, port : Text }"
                  , ", oidc = None"
                  , "    { issuer : Text"
                  , "    , client_id : Text"
                  , "    , client_secret : Text"
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
                  , "    , client_secret = \"secret\""
                  , "    , public_base_url = \"https://test.example.com\""
                  , "    , token_endpoint = \"/token\""
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
                  , ", redis = None { host : Text, port : Text }"
                  , ", oidc = None"
                  , "    { issuer : Text"
                  , "    , client_id : Text"
                  , "    , client_secret : Text"
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

  describe "Sprint 2.19 master-seed derivation" $ do
    it "rejects a master seed of the wrong length" $
      Prodbox.Secret.Derive.masterSeed (BS.replicate 16 0)
        `shouldBe` Left "master seed must be exactly 32 bytes; got 16"

    it "accepts a master seed of exactly 32 bytes" $
      case Prodbox.Secret.Derive.masterSeed (BS.replicate 32 0) of
        Right _ -> pure () :: IO ()
        Left err -> expectationFailure ("expected Right, got Left: " ++ err)

    it "derive is deterministic across repeated calls" $ do
      let Right seed = Prodbox.Secret.Derive.masterSeed (BS.replicate 32 0x42)
          context = "patroni:keycloak:keycloak:app"
      Prodbox.Secret.Derive.derive seed context
        `shouldBe` Prodbox.Secret.Derive.derive seed context

    it "different context strings produce different derived values" $ do
      let Right seed = Prodbox.Secret.Derive.masterSeed (BS.replicate 32 0x42)
          appValue = Prodbox.Secret.Derive.derive seed "patroni:keycloak:keycloak:app"
          standbyValue = Prodbox.Secret.Derive.derive seed "patroni:keycloak:keycloak:standby"
      (appValue == standbyValue) `shouldBe` False

    it "different seeds produce different derived values for the same context" $ do
      let Right seedA = Prodbox.Secret.Derive.masterSeed (BS.replicate 32 0x01)
          Right seedB = Prodbox.Secret.Derive.masterSeed (BS.replicate 32 0x02)
          context = "patroni:keycloak:keycloak:app"
      (Prodbox.Secret.Derive.derive seedA context == Prodbox.Secret.Derive.derive seedB context)
        `shouldBe` False

    it "derived secret is exactly 32 bytes" $ do
      let Right seed = Prodbox.Secret.Derive.masterSeed (BS.replicate 32 0x42)
      BS.length (Prodbox.Secret.Derive.derive seed "patroni:keycloak:keycloak:app")
        `shouldBe` 32

    it "patroniRoleContext renders the canonical shape per doctrine table" $ do
      Prodbox.Secret.Derive.patroniRoleContext
        "keycloak"
        "keycloak"
        Prodbox.Secret.Derive.PatroniRoleApp
        `shouldBe` "patroni:keycloak:keycloak:app"
      Prodbox.Secret.Derive.patroniRoleContext
        "vscode"
        "vscode"
        Prodbox.Secret.Derive.PatroniRoleSuperuser
        `shouldBe` "patroni:vscode:vscode:superuser"
      Prodbox.Secret.Derive.patroniRoleContext
        "keycloak"
        "keycloak"
        Prodbox.Secret.Derive.PatroniRoleStandby
        `shouldBe` "patroni:keycloak:keycloak:standby"

    it "keycloakAdminContext renders the canonical shape" $
      Prodbox.Secret.Derive.keycloakAdminContext "keycloak"
        `shouldBe` "keycloak:keycloak:admin"

    it "gatewayEventKeyContext renders the canonical shape" $
      Prodbox.Secret.Derive.gatewayEventKeyContext "gateway" "node-a"
        `shouldBe` "gateway:gateway:node-a:event-key"

    it "the five canonical context strings from the doctrine are all distinct" $ do
      let Right seed = Prodbox.Secret.Derive.masterSeed (BS.replicate 32 0x42)
          contexts =
            [ Prodbox.Secret.Derive.patroniRoleContext "ns" "rel" Prodbox.Secret.Derive.PatroniRoleApp
            , Prodbox.Secret.Derive.patroniRoleContext "ns" "rel" Prodbox.Secret.Derive.PatroniRoleSuperuser
            , Prodbox.Secret.Derive.patroniRoleContext "ns" "rel" Prodbox.Secret.Derive.PatroniRoleStandby
            , Prodbox.Secret.Derive.keycloakAdminContext "ns"
            , Prodbox.Secret.Derive.gatewayEventKeyContext "ns" "node-a"
            ]
          derived = map (Prodbox.Secret.Derive.derive seed) contexts
      length (Set.toList (Set.fromList derived)) `shouldBe` length derived

    it "deriveBase64Url encodes the 32-byte derived value as 43 base64url characters (unpadded)" $ do
      let Right seed = Prodbox.Secret.Derive.masterSeed (BS.replicate 32 0x42)
          encoded = Prodbox.Secret.Derive.deriveBase64Url seed "patroni:ns:rel:app"
      Text.length encoded `shouldBe` 43

    it "deriveHex encodes the 32-byte derived value as 64 lowercase-hex characters" $ do
      let Right seed = Prodbox.Secret.Derive.masterSeed (BS.replicate 32 0x42)
          encoded = Prodbox.Secret.Derive.deriveHex seed "patroni:ns:rel:app"
      Text.length encoded `shouldBe` 64

    it "Show on MasterSeed never leaks the bytes" $ do
      let Right seed = Prodbox.Secret.Derive.masterSeed (BS.replicate 32 0xff)
      show seed `shouldBe` "MasterSeed <redacted>"

  describe "Sprint 3.13 derived-secret inventory" $ do
    it "returns the three Patroni roles for keycloak-postgres in the keycloak namespace" $ do
      let entries = Inventory.derivedSecretInventoryFor "keycloak" "keycloak-postgres"
      map Inventory.derivedSecretEntryName entries
        `shouldBe` [ "prodbox-keycloak-pg-pguser-keycloak"
                   , "prodbox-keycloak-pg-pguser-postgres"
                   , "prodbox-keycloak-pg-primaryuser"
                   ]

    it "every keycloak-postgres entry writes its derived value into the `password` key" $ do
      let entries = Inventory.derivedSecretInventoryFor "keycloak" "keycloak-postgres"
      map (map fst . Inventory.derivedSecretEntryDerivedFields) entries
        `shouldBe` replicate 3 ["password"]

    it "keycloak-postgres context strings match the doctrine §3 patroni shape" $ do
      let entries = Inventory.derivedSecretInventoryFor "keycloak" "keycloak-postgres"
      map (map snd . Inventory.derivedSecretEntryDerivedFields) entries
        `shouldBe` [ ["patroni:keycloak:keycloak-postgres:app"]
                   , ["patroni:keycloak:keycloak-postgres:superuser"]
                   , ["patroni:keycloak:keycloak-postgres:standby"]
                   ]

    it
      "returns the keycloak admin + OAuth-clients entries for the keycloak release in the keycloak namespace"
      $ do
        let entries = Inventory.derivedSecretInventoryFor "keycloak" "keycloak"
        entries
          `shouldBe` [ Inventory.DerivedSecretEntry
                         { Inventory.derivedSecretEntryName = "keycloak-runtime"
                         , Inventory.derivedSecretEntryDerivedFields =
                             [("KEYCLOAK_ADMIN_PASSWORD", "keycloak:keycloak:admin")]
                         , Inventory.derivedSecretEntryStaticFields = []
                         }
                     , Inventory.DerivedSecretEntry
                         { Inventory.derivedSecretEntryName = "keycloak-oidc-clients"
                         , Inventory.derivedSecretEntryDerivedFields =
                             [ ("VSCODE_CLIENT_SECRET", "oidc:keycloak:vscode")
                             , ("API_CLIENT_SECRET", "oidc:keycloak:prodbox-api")
                             , ("WEBSOCKET_CLIENT_SECRET", "oidc:keycloak:prodbox-websocket")
                             , ("DEMO_USER_PASSWORD", "keycloak:keycloak:demo-user")
                             ]
                         , Inventory.derivedSecretEntryStaticFields = []
                         }
                     ]

    it "every keycloak-postgres entry carries its Crunchy-required `username` static field" $ do
      let entries = Inventory.derivedSecretInventoryFor "keycloak" "keycloak-postgres"
      map Inventory.derivedSecretEntryStaticFields entries
        `shouldBe` [ [("username", "keycloak")]
                   , [("username", "postgres")]
                   , [("username", "primaryuser")]
                   ]

    it "returns an empty list for releases without static derived secrets (vscode / api / websocket)" $ do
      Inventory.derivedSecretInventoryFor "vscode" "vscode" `shouldBe` []
      Inventory.derivedSecretInventoryFor "api" "api" `shouldBe` []
      Inventory.derivedSecretInventoryFor "websocket" "websocket" `shouldBe` []

    it "returns an empty list for unknown (namespace, release) pairs" $ do
      Inventory.derivedSecretInventoryFor "made-up" "also-made-up" `shouldBe` []

    it "is deterministic across repeated calls (pure function over Text inputs)" $ do
      Inventory.derivedSecretInventoryFor "keycloak" "keycloak-postgres"
        `shouldBe` Inventory.derivedSecretInventoryFor "keycloak" "keycloak-postgres"

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

  describe "Sprint 3.13 applyDerivedSecrets pipeline" $ do
    let testSeed = case Prodbox.Secret.Derive.masterSeed (BS.replicate 32 0x42) of
          Right s -> s
          Left err -> error ("test setup: " ++ err)

    let recordingOps :: IO (InCluster.K8sSecretOps, IORef [(Text.Text, Text.Text, Value)])
        recordingOps = do
          calls <- newIORef []
          let ops =
                InCluster.K8sSecretOps
                  { InCluster.secretOpsGet = \_ _ -> pure (Right Nothing)
                  , InCluster.secretOpsPut = \ns name manifest -> do
                      modifyIORef' calls ((ns, name, manifest) :)
                      pure (Right ())
                  }
          pure (ops, calls)

    it "submits one PUT per inventory entry in the supplied order" $ do
      (ops, calls) <- recordingOps
      let entries = Inventory.derivedSecretInventoryFor "keycloak" "keycloak-postgres"
      result <- EnsureNamespace.applyDerivedSecrets ops testSeed "keycloak" entries
      case result of
        Left err -> expectationFailure ("expected Right, got Left: " ++ err)
        Right inventory -> do
          length inventory `shouldBe` 3
          map Prodbox.Secret.Wire.secretSha256EntryName inventory
            `shouldBe` [ "prodbox-keycloak-pg-pguser-keycloak"
                       , "prodbox-keycloak-pg-pguser-postgres"
                       , "prodbox-keycloak-pg-primaryuser"
                       ]
      recordedCalls <- reverse <$> readIORef calls
      length recordedCalls `shouldBe` 3
      map (\(_, name, _) -> name) recordedCalls
        `shouldBe` [ "prodbox-keycloak-pg-pguser-keycloak"
                   , "prodbox-keycloak-pg-pguser-postgres"
                   , "prodbox-keycloak-pg-primaryuser"
                   ]

    it "puts each manifest with apiVersion v1 + kind Secret + Opaque type" $ do
      -- Sprint 3.13 chunk 11 extended the (keycloak, keycloak) inventory from
      -- one entry to two (keycloak-runtime + keycloak-oidc-clients); the
      -- handler now PUTs two manifests in order.
      (ops, calls) <- recordingOps
      let entries = Inventory.derivedSecretInventoryFor "keycloak" "keycloak"
      _ <- EnsureNamespace.applyDerivedSecrets ops testSeed "keycloak" entries
      recordedCalls <- reverse <$> readIORef calls
      length recordedCalls `shouldBe` 2
      let names = [name | (_, name, _) <- recordedCalls]
      names `shouldBe` ["keycloak-runtime", "keycloak-oidc-clients"]
      let firstManifest = case recordedCalls of
            ((_, _, m) : _) -> m
            _ -> error "unreachable"
          rendered = BL8.unpack (encode firstManifest)
      rendered `shouldContain` "\"apiVersion\":\"v1\""
      rendered `shouldContain` "\"kind\":\"Secret\""
      rendered `shouldContain` "\"type\":\"Opaque\""
      rendered `shouldContain` "\"KEYCLOAK_ADMIN_PASSWORD\":"

    it "returns SHA-256 of the derived inventory (never the plaintext) for each entry" $ do
      -- Sprint 3.13 chunk 11: per-Secret SHA-256 hashes the concatenation of
      -- `key=value` pairs in declared order so a Secret with multiple derived
      -- fields gets one stable digest (rather than only the value of the
      -- single derived key, which was the pre-chunk-11 contract).
      (ops, _) <- recordingOps
      let entries = Inventory.derivedSecretInventoryFor "keycloak" "keycloak-postgres"
      result <- EnsureNamespace.applyDerivedSecrets ops testSeed "keycloak" entries
      case result of
        Left err -> expectationFailure ("expected Right, got Left: " ++ err)
        Right inventory -> do
          let derivedAppValue =
                EnsureNamespace.deriveSecretValueText
                  testSeed
                  "patroni:keycloak:keycloak-postgres:app"
              expectedAppSha = EnsureNamespace.deriveSecretSha256Hex ("password=" <> derivedAppValue)
          case inventory of
            (firstEntry : _) ->
              Prodbox.Secret.Wire.secretSha256EntrySha256 firstEntry `shouldBe` expectedAppSha
            [] -> expectationFailure "expected at least one entry"

    it "deriveSecretSha256Hex is deterministic and lowercase-hex of length 64" $ do
      let value = "any-derived-value"
          h1 = EnsureNamespace.deriveSecretSha256Hex value
          h2 = EnsureNamespace.deriveSecretSha256Hex value
      h1 `shouldBe` h2
      Text.length h1 `shouldBe` 64
      Text.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) h1
        `shouldBe` True

    it "short-circuits on the first PUT failure (no further calls)" $ do
      calls <- newIORef []
      let ops =
            InCluster.K8sSecretOps
              { InCluster.secretOpsGet = \_ _ -> pure (Right Nothing)
              , InCluster.secretOpsPut = \ns name manifest -> do
                  modifyIORef' calls ((ns, name, manifest) :)
                  pure (Left "simulated 403 Forbidden")
              }
      let entries = Inventory.derivedSecretInventoryFor "keycloak" "keycloak-postgres"
      result <- EnsureNamespace.applyDerivedSecrets ops testSeed "keycloak" entries
      case result of
        Right _ -> expectationFailure "expected Left on PUT failure"
        Left err -> do
          err `shouldContain` "failed to apply Secret"
          err `shouldContain` "prodbox-keycloak-pg-pguser-keycloak"
          err `shouldContain` "simulated 403 Forbidden"
      recordedCalls <- readIORef calls
      length recordedCalls `shouldBe` 1

    it "returns an empty inventory when given an empty entry list" $ do
      (ops, calls) <- recordingOps
      result <- EnsureNamespace.applyDerivedSecrets ops testSeed "anywhere" []
      result `shouldBe` Right []
      recordedCalls <- readIORef calls
      recordedCalls `shouldBe` []

    it "writes static fields (e.g. Crunchy `username`) alongside the derived value" $ do
      (ops, calls) <- recordingOps
      let entries = Inventory.derivedSecretInventoryFor "keycloak" "keycloak-postgres"
      _ <- EnsureNamespace.applyDerivedSecrets ops testSeed "keycloak" entries
      recordedCalls <- reverse <$> readIORef calls
      case recordedCalls of
        ((_, _, manifest) : _) -> do
          let rendered = BL8.unpack (encode manifest)
          rendered `shouldContain` "\"username\":\"keycloak\""
          rendered `shouldContain` "\"password\":"
        _ -> expectationFailure "expected at least one PUT call"

  describe "Sprint 2.19 gateway secret-endpoint wire types" $ do
    it "DeriveResponse JSON round-trips through encode/decode" $ do
      let response =
            Prodbox.Secret.Wire.DeriveResponse
              { Prodbox.Secret.Wire.deriveResponseContext = "patroni:keycloak:keycloak:app"
              , Prodbox.Secret.Wire.deriveResponseDerived = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
              , Prodbox.Secret.Wire.deriveResponseEncoding = Prodbox.Secret.Wire.deriveEncodingBase64Url
              }
      Data.Aeson.eitherDecode (Data.Aeson.encode response)
        `shouldBe` Right response

    it "DeriveResponse encodes the wire shape doctrine 4 prescribes" $ do
      let response =
            Prodbox.Secret.Wire.DeriveResponse
              { Prodbox.Secret.Wire.deriveResponseContext = "patroni:keycloak:keycloak:app"
              , Prodbox.Secret.Wire.deriveResponseDerived = "abc"
              , Prodbox.Secret.Wire.deriveResponseEncoding = Prodbox.Secret.Wire.deriveEncodingBase64Url
              }
          encoded = BL8.unpack (Data.Aeson.encode response)
      encoded `shouldContain` "\"context\":\"patroni:keycloak:keycloak:app\""
      encoded `shouldContain` "\"derived\":\"abc\""
      encoded `shouldContain` "\"encoding\":\"base64url\""

    it "deriveEncodingBase64Url pins the canonical encoding name" $
      Prodbox.Secret.Wire.deriveEncodingBase64Url `shouldBe` "base64url"

    it "EnsureNamespaceRequest JSON round-trips through encode/decode" $ do
      let request =
            Prodbox.Secret.Wire.EnsureNamespaceRequest
              { Prodbox.Secret.Wire.ensureNamespaceRequestNamespace = "keycloak"
              , Prodbox.Secret.Wire.ensureNamespaceRequestRelease = "keycloak"
              }
      Data.Aeson.eitherDecode (Data.Aeson.encode request)
        `shouldBe` Right request

    it "EnsureNamespaceResponse JSON round-trips through encode/decode" $ do
      let response =
            Prodbox.Secret.Wire.EnsureNamespaceResponse
              { Prodbox.Secret.Wire.ensureNamespaceResponseNamespace = "keycloak"
              , Prodbox.Secret.Wire.ensureNamespaceResponseRelease = "keycloak"
              , Prodbox.Secret.Wire.ensureNamespaceResponseSecrets =
                  [ Prodbox.Secret.Wire.SecretSha256Entry "prodbox-keycloak-pg-pguser-keycloak" "abc123"
                  , Prodbox.Secret.Wire.SecretSha256Entry "keycloak-runtime" "def456"
                  ]
              }
      Data.Aeson.eitherDecode (Data.Aeson.encode response)
        `shouldBe` Right response

    it "SecretSha256Entry never serializes plaintext (only name + sha256 are members)" $ do
      let entry = Prodbox.Secret.Wire.SecretSha256Entry "keycloak-runtime" "deadbeef"
          encoded = BL8.unpack (Data.Aeson.encode entry)
      encoded `shouldBe` "{\"name\":\"keycloak-runtime\",\"sha256\":\"deadbeef\"}"

    it "deriveUrl produces the canonical URL with URL-encoded context query parameter" $
      let endpoint =
            PeerEndpoint
              { peerNodeId = "node-a"
              , peerStableDnsName = "node-a.example.test"
              , peerRestHost = "127.0.0.1"
              , peerRestPort = 8080
              , peerSocketHost = "127.0.0.1"
              , peerSocketPort = 8081
              }
       in Prodbox.Gateway.Client.deriveUrl endpoint "patroni:keycloak:keycloak:app"
            `shouldBe` "http://127.0.0.1:8080/v1/secret/derive?context=patroni%3Akeycloak%3Akeycloak%3Aapp"

    it "ensureNamespaceUrl produces the canonical URL without query parameters" $
      let endpoint =
            PeerEndpoint
              { peerNodeId = "node-a"
              , peerStableDnsName = "node-a.example.test"
              , peerRestHost = "127.0.0.1"
              , peerRestPort = 8080
              , peerSocketHost = "127.0.0.1"
              , peerSocketPort = 8081
              }
       in Prodbox.Gateway.Client.ensureNamespaceUrl endpoint
            `shouldBe` "http://127.0.0.1:8080/v1/secret/ensure-namespace"

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
            { Residue.residueEvidence = "aws.access_key_id set in prodbox-config.dhall"
            , Residue.residueStackName = "operational-aws-config"
            }

    it "operationalAwsConfigResidueFromKey maps an empty key to absent" $
      operationalAwsConfigResidueFromKey "" `shouldBe` Residue.ResidueAbsent

    it "operationalAwsConfigResidueFromKey treats whitespace-only as absent" $
      operationalAwsConfigResidueFromKey "   \t  " `shouldBe` Residue.ResidueAbsent

    it "operationalManagedResources registers exactly the two operational resources" $
      map ResourceRegistry.resourceName (operationalManagedResources sampleCreds)
        `shouldBe` ["operational-iam-user", "operational-aws-config"]

    it "operationalManagedResources entries are all the Operational lifecycle class" $
      all
        ((== ResourceClass.Operational) . ResourceRegistry.resourceClass)
        (operationalManagedResources sampleCreds)
        `shouldBe` True

    it "operationalManagedResources names match the ResourceClass SSoT Operational class" $
      map ResourceRegistry.resourceName (operationalManagedResources sampleCreds)
        `shouldBe` ResourceClass.resourceNamesOfClass ResourceClass.Operational

  describe "Sprint 4.17.a canonical cascade phase order" $ do
    it "narration lists drain before per-run destroys (doctrine §5b)" $
      ("drain → per-run destroys" `isInfixOf` cascadeOrderNarration) `shouldBe` True

    it "narration places confirm-MinIO first" $
      ("confirm-MinIO → drain" `isInfixOf` cascadeOrderNarration) `shouldBe` True

    it "narration places uninstall between per-run destroys and sweep" $
      ("per-run destroys → uninstall → sweep" `isInfixOf` cascadeOrderNarration) `shouldBe` True

    it "narration does NOT list the pre-Sprint-4.17.a inverted order" $
      ("per-run destroys → drain" `isInfixOf` cascadeOrderNarration) `shouldBe` False

    it "narration is the full canonical cascade phrase" $
      cascadeOrderNarration
        `shouldBe` "rke2 delete --cascade: confirm-MinIO → drain → per-run destroys → uninstall → sweep"

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
              Residue.residueEvidence details `shouldContain` "pulumi stack ls"
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

    it "isMissingLongLivedS3BackendBucketMessage matches Pulumi S3 NoSuchBucket output" $
      LiveResidue.isMissingLongLivedS3BackendBucketMessage
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

    it "canonical stack-name constants match the production names" $ do
      LiveResidue.awsEksTestStackName `shouldBe` "aws-eks-test"
      LiveResidue.awsEksSubzoneStackName `shouldBe` "aws-eks-subzone"
      LiveResidue.awsTestStackName `shouldBe` "aws-test"
      LiveResidue.awsSesStackName `shouldBe` "aws-ses"

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
              [ ("backend_bucket", "prodbox-test-pulumi-backends")
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
                }
            , TagSweep.TaggedResource
                { TagSweep.taggedResourceArn = "arn:aws:iam::123:role/prodbox-residual"
                , TagSweep.taggedResourceMatchedTagKey = "prodbox.io/managed-by"
                }
            ]
          rendered = TagSweep.renderTagSweepRefusal resources
          bulletLines = filter (\line -> take 4 line == "  - ") (lines rendered)
      length bulletLines `shouldBe` 2

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

  describe "Sprint 2.19 MasterSeed MinIO read-write contract" $ do
    let cfg =
          MasterSeed.MinioMasterSeedConfig
            { MasterSeed.minioMasterSeedEndpoint = "http://127.0.0.1:9000"
            , MasterSeed.minioMasterSeedBucket = "prodbox"
            , MasterSeed.minioMasterSeedKey = "master-seed"
            , MasterSeed.minioMasterSeedAccessKey = "AKIA"
            , MasterSeed.minioMasterSeedSecretKey = "secret"
            }

    it "masterSeedObjectKey pins the canonical object key" $
      MasterSeed.masterSeedObjectKey `shouldBe` "master-seed"

    it "defaultMinioMasterSeedConfig resolves the endpoint via the local MinIO port" $ do
      let resolved = MasterSeed.defaultMinioMasterSeedConfig 39000 "AKIA" "secret"
      MasterSeed.minioMasterSeedEndpoint resolved `shouldBe` "http://127.0.0.1:39000"
      MasterSeed.minioMasterSeedBucket resolved `shouldBe` "prodbox"
      MasterSeed.minioMasterSeedKey resolved `shouldBe` "master-seed"

    it "awsS3ApiHeadArgs pins the canonical head-object wire shape" $
      MasterSeed.awsS3ApiHeadArgs cfg
        `shouldBe` [ "--endpoint-url"
                   , "http://127.0.0.1:9000"
                   , "s3api"
                   , "head-object"
                   , "--bucket"
                   , "prodbox"
                   , "--key"
                   , "master-seed"
                   ]

    it "awsS3ApiGetArgs pins the canonical get-object wire shape with output path" $
      MasterSeed.awsS3ApiGetArgs cfg "/tmp/master-seed.bin"
        `shouldBe` [ "--endpoint-url"
                   , "http://127.0.0.1:9000"
                   , "s3api"
                   , "get-object"
                   , "--bucket"
                   , "prodbox"
                   , "--key"
                   , "master-seed"
                   , "/tmp/master-seed.bin"
                   ]

    it "awsS3ApiPutArgs pins the canonical put-object wire shape with If-None-Match guard" $
      MasterSeed.awsS3ApiPutArgs cfg "/tmp/master-seed-put.bin"
        `shouldBe` [ "--endpoint-url"
                   , "http://127.0.0.1:9000"
                   , "s3api"
                   , "put-object"
                   , "--bucket"
                   , "prodbox"
                   , "--key"
                   , "master-seed"
                   , "--body"
                   , "/tmp/master-seed-put.bin"
                   , "--if-none-match"
                   , "*"
                   ]

    it "isAwsCliNoSuchKeyMessage matches the canonical AWS CLI NoSuchKey blob" $ do
      MasterSeed.isAwsCliNoSuchKeyMessage
        "An error occurred (NoSuchKey) when calling the HeadObject operation: Not Found"
        `shouldBe` True

    it "isAwsCliNoSuchKeyMessage matches when only Not Found is present" $
      MasterSeed.isAwsCliNoSuchKeyMessage "Not Found" `shouldBe` True

    it "isAwsCliNoSuchKeyMessage does not match unrelated AWS CLI failures" $
      MasterSeed.isAwsCliNoSuchKeyMessage "Access Denied" `shouldBe` False

    it "isAwsCliHeadObjectForbiddenMessage matches the first-write MinIO HeadObject 403 shape" $ do
      MasterSeed.isAwsCliHeadObjectForbiddenMessage
        "An error occurred (403) when calling the HeadObject operation: Forbidden"
        `shouldBe` True

    it "isAwsCliHeadObjectForbiddenMessage does not match non-head forbidden failures" $
      MasterSeed.isAwsCliHeadObjectForbiddenMessage
        "An error occurred (403) when calling the PutObject operation: Forbidden"
        `shouldBe` False

    it "isAwsCliPreconditionFailedMessage matches the canonical 412 blob" $ do
      MasterSeed.isAwsCliPreconditionFailedMessage
        "An error occurred (PreconditionFailed) when calling the PutObject operation"
        `shouldBe` True
      MasterSeed.isAwsCliPreconditionFailedMessage
        "At least one of the pre-conditions you specified did not hold"
        `shouldBe` True

    it "isAwsCliPreconditionFailedMessage matches when the If-None-Match header is named" $
      MasterSeed.isAwsCliPreconditionFailedMessage "If-None-Match header violated"
        `shouldBe` True

    it "isAwsCliPreconditionFailedMessage does not match unrelated failures" $
      MasterSeed.isAwsCliPreconditionFailedMessage "Network unreachable" `shouldBe` False

    it "renderMasterSeedError discriminates the six error constructors" $ do
      MasterSeed.renderMasterSeedError (MasterSeed.MasterSeedEntropyUnavailable "permission denied")
        `shouldBe` "master seed entropy source unavailable: permission denied"
      MasterSeed.renderMasterSeedError
        (MasterSeed.MasterSeedInvalidSize "master seed must be exactly 32 bytes; got 16")
        `shouldBe` "master seed validator rejected MinIO payload: master seed must be exactly 32 bytes; got 16"
      MasterSeed.renderMasterSeedError (MasterSeed.MasterSeedSubprocessFailed "fork: no entropy")
        `shouldBe` "failed to start `aws s3api`: fork: no entropy"
      MasterSeed.renderMasterSeedError (MasterSeed.MasterSeedGetFailed "403 Forbidden")
        `shouldBe` "`aws s3api get-object` failed: 403 Forbidden"
      MasterSeed.renderMasterSeedError (MasterSeed.MasterSeedPutFailed "503 ServiceUnavailable")
        `shouldBe` "`aws s3api put-object` failed: 503 ServiceUnavailable"
      MasterSeed.renderMasterSeedError (MasterSeed.MasterSeedFileIoFailed "EACCES")
        `shouldBe` "master seed temporary file IO failed: EACCES"

    it "generateFreshSeedBytes produces 32 bytes from /dev/urandom" $ do
      result <- MasterSeed.generateFreshSeedBytes
      case result of
        Left err ->
          expectationFailure
            ("expected 32 bytes from /dev/urandom, got error: " ++ MasterSeed.renderMasterSeedError err)
        Right bytes ->
          BS.length bytes `shouldBe` 32

    it "generateFreshSeedBytes produces distinct outputs across invocations" $ do
      firstResult <- MasterSeed.generateFreshSeedBytes
      secondResult <- MasterSeed.generateFreshSeedBytes
      case (firstResult, secondResult) of
        (Right firstBytes, Right secondBytes) ->
          (firstBytes == secondBytes) `shouldBe` False
        _ ->
          expectationFailure "expected two successful /dev/urandom reads"

  describe "gateway commit-log dispositions" $ do
    it "computes node disposition from claim/yield events in chronological order" $ do
      let claimA = signedEventStub "node-a" eventTypeClaim "2026-04-06T10:00:00Z"
          yieldA = signedEventStub "node-a" eventTypeYield "2026-04-06T10:00:01Z"
          heartbeat = signedEventStub "node-b" eventTypeHeartbeat "2026-04-06T10:00:02Z"
          claimAReclaim = signedEventStub "node-a" eventTypeClaim "2026-04-06T10:00:03Z"
          logBefore = foldl appendIfNew emptyCommitLog [claimA, yieldA, heartbeat]
          logReclaim = appendIfNew logBefore claimAReclaim
      nodeDisposition "node-a" logBefore `shouldBe` DispositionYielded
      nodeDisposition "node-a" logReclaim `shouldBe` DispositionOwner
      nodeDisposition "node-b" logReclaim `shouldBe` DispositionUnknown

    it "gates DNS writes on the runtime CanWriteDns predicate" $ do
      let claim = signedEventStub "node-a" eventTypeClaim "2026-04-06T10:00:00Z"
          yield = signedEventStub "node-a" eventTypeYield "2026-04-06T10:00:01Z"
          logOwner = appendIfNew emptyCommitLog claim
          logYielded = appendIfNew logOwner yield
      canWriteDns "node-a" (Just "node-a") logOwner `shouldBe` True
      canWriteDns "node-a" (Just "node-a") logYielded `shouldBe` False
      canWriteDns "node-a" (Just "node-b") logOwner `shouldBe` False
      canWriteDns "node-a" Nothing logOwner `shouldBe` False
      canWriteDns "node-a" (Just "node-a") emptyCommitLog `shouldBe` False

  describe "gateway peer transport" $ do
    it "round-trips a peer event batch through encode and parse" $ do
      let event = signedEventStub "node-a" eventTypeHeartbeat "2026-04-06T10:00:00Z"
          batch = PeerEventBatch [event] 1700000000
      case parsePeerEventBatch (encodePeerEventBatch batch) of
        Left err -> expectationFailure err
        Right parsed -> do
          peerEventBatchSenderOrdersVersionUtc parsed `shouldBe` 1700000000
          map eventHash (peerEventBatchEvents parsed) `shouldBe` [eventHash event]

    it "rejects events whose HMAC signature does not match the configured key" $ do
      let badEvent =
            Peer.signEvent
              "node-a"
              eventTypeHeartbeat
              "2026-04-06T10:00:00Z"
              "{}"
              "wrong-key"
          eventKeys = Map.fromList [("node-a", "fake-key")]
          batch = PeerEventBatch [badEvent] 1
          (accepted, rejected) =
            handlePeerRequest
              (`Map.lookup` eventKeys)
              ["node-a"]
              defaultMaxClockSkewSeconds
              "2026-04-06T10:00:00Z"
              batch
      accepted `shouldBe` []
      length rejected `shouldBe` 1

    it "rejects events from emitters that are not in the orders node set" $ do
      let event = signedEventStub "stranger" eventTypeHeartbeat "2026-04-06T10:00:00Z"
          eventKeys = Map.fromList [("node-a", "fake-key")]
          batch = PeerEventBatch [event] 1
          (accepted, rejected) =
            handlePeerRequest
              (`Map.lookup` eventKeys)
              ["node-a", "node-b"]
              defaultMaxClockSkewSeconds
              "2026-04-06T10:00:00Z"
              batch
      accepted `shouldBe` []
      map fst rejected `shouldBe` [eventHash event]

    it "rejects events whose timestamp exceeds the configured skew bound" $ do
      let event = signedEventStub "node-a" eventTypeHeartbeat "2026-04-06T10:00:00Z"
          eventKeys = Map.fromList [("node-a", "fake-key")]
          batch = PeerEventBatch [event] 1
          (accepted, rejected) =
            handlePeerRequest
              (`Map.lookup` eventKeys)
              ["node-a"]
              5.0
              "2026-04-06T10:01:00Z"
              batch
      accepted `shouldBe` []
      length rejected `shouldBe` 1

    it "parses an inbound peer push request body" $ do
      let event = signedEventStub "node-a" eventTypeHeartbeat "2026-04-06T10:00:00Z"
          batch = PeerEventBatch [event] 7
          bodyBytes = BL8.unpack (encodeJsonValue (encodePeerEventBatch batch))
          request =
            BL8.pack
              ( "POST /v1/peer/events HTTP/1.1\r\n"
                  ++ "Host: example.test:8444\r\n"
                  ++ "Content-Type: application/json\r\n"
                  ++ "Content-Length: "
                  ++ show (length bodyBytes)
                  ++ "\r\n"
                  ++ "Connection: close\r\n"
                  ++ "\r\n"
                  ++ bodyBytes
              )
      case parsePeerHttpRequest (BL8.toStrict request) of
        Left err -> expectationFailure err
        Right (PeerPushEvents parsed) -> do
          peerEventBatchSenderOrdersVersionUtc parsed `shouldBe` 7
          length (peerEventBatchEvents parsed) `shouldBe` 1
        Right _ -> expectationFailure "expected PeerPushEvents"

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
      let updatedEnvironment = isolatedAwsEnvironment credentialsWithSession
      lookup "AWS_ACCESS_KEY_ID" updatedEnvironment `shouldBe` Just "config-access-key"
      lookup "AWS_SECRET_ACCESS_KEY" updatedEnvironment `shouldBe` Just "config-secret-key"
      lookup "AWS_SESSION_TOKEN" updatedEnvironment `shouldBe` Just "config-session-token"
      lookup "AWS_REGION" updatedEnvironment `shouldBe` Just "us-west-2"
      lookup "AWS_DEFAULT_REGION" updatedEnvironment `shouldBe` Just "us-west-2"

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
        writeFile (tmpDir </> "prodbox-config.dhall") validConfig
        writeFile fakeAwsPath (unlines (fakeAwsCredentialPropagationScript stateDir))
        makeExecutable fakeAwsPath

        originalPath <- lookupEnv "PATH"
        let configuredPath =
              case originalPath of
                Just currentPath -> binDir ++ ":" ++ currentPath
                Nothing -> binDir

        setEnv "PATH" configuredPath
        validationResult <-
          runEffect (InterpreterContext tmpDir) (Validate RequireAwsCredentials)
            `finally` restoreEnv "PATH" originalPath

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
    it "decodes the Kubernetes keycloak-smtp Secret into realm SMTP settings" $ do
      let secretJson =
            "{\"data\":{"
              <> "\"KC_SMTP_HOST\":\"ZW1haWwtc210cC51cy13ZXN0LTIuYW1hem9uYXdzLmNvbQ==\","
              <> "\"KC_SMTP_PORT\":\"NTg3\","
              <> "\"KC_SMTP_FROM\":\"bm9yZXBseUB0ZXN0LnJlc29sdmVmaW50ZWNoLmNvbQ==\","
              <> "\"KC_SMTP_FROM_DISPLAY_NAME\":\"cHJvZGJveA==\","
              <> "\"KC_SMTP_REPLY_TO\":\"bm9yZXBseUB0ZXN0LnJlc29sdmVmaW50ZWNoLmNvbQ==\","
              <> "\"KC_SMTP_USER\":\"QUtJQUVYQU1QTEU=\","
              <> "\"KC_SMTP_PASSWORD\":\"c210cC1wYXNz\""
              <> "}}"
      Prodbox.UsersAdmin.decodeKeycloakSmtpSecretJson secretJson `shouldBe` Right smtpSettings
    it "renders Keycloak's smtpServer representation from the Secret fields" $
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

  describe "Keycloak SMTP Secret sync" $ do
    it "targets every supported Keycloak release namespace" $ do
      AwsSesStack.keycloakSmtpSecretNamespaces `shouldBe` ["vscode", "keycloak"]
      let script =
            AwsSesStack.renderKeycloakSmtpKubectlApplyScript
              [ ("KC_SMTP_HOST", "email-smtp.us-west-2.amazonaws.com")
              , ("KC_SMTP_PASSWORD", "pa'ss")
              ]
      script `shouldContain` "kubectl create namespace 'vscode'"
      script `shouldContain` "kubectl create namespace 'keycloak'"
      script `shouldContain` "kubectl label namespace 'keycloak' 'app.kubernetes.io/managed-by=Helm'"
      script `shouldContain` "kubectl annotate namespace 'keycloak'"
      script `shouldContain` "'meta.helm.sh/release-name=gateway'"
      script `shouldContain` "'meta.helm.sh/release-namespace=gateway'"
      script `shouldContain` "'helm.sh/resource-policy=keep'"
      script `shouldContain` "kubectl create secret generic 'keycloak-smtp'"
      script `shouldContain` " -n 'vscode'"
      script `shouldContain` " -n 'keycloak'"
      script `shouldContain` "--from-literal='KC_SMTP_PASSWORD=pa'\\''ss'"

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
        "127.0.0.1:30080/prodbox-gateway/foo:tag"
        `shouldBe` "harbor.harbor.svc.cluster.local/prodbox-gateway/foo:tag"
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

  describe
    "Sprint 7.5.c.iii AWS-substrate platform orchestration (extended through 7.5.c.iv + 7.5.c.v.b)"
    $ do
      let steps = Prodbox.Lib.AwsSubstratePlatform.awsSubstratePlatformRuntimeStepDescriptions
      it
        "sequences the canonical 15 steps in order through the Sprint 7.5.c.v.b custom-image and admin-route extension"
        $ steps
          `shouldBe` [ "ensureAwsLoadBalancerControllerRuntime"
                     , "ensureAwsSubstrateEnvoyGatewayRuntime"
                     , "ensureAwsSubstrateCertManagerRuntime"
                     , "ensureAwsSubstrateAcmeRuntime"
                     , "applyEksContainerdMirrorDaemonSet"
                     , "ensureMinioRuntime SubstrateAws MinioBootstrapPublic"
                     , "ensureHarborRegistryStorageBackend"
                     , "ensureHarborRegistryRuntime SubstrateAws"
                     , "applyEksImageMirrorJob"
                     , "ensureGatewayImagesForSubstrate SubstrateAws"
                     , "ensurePublicEdgeWorkloadImageForSubstrate SubstrateAws"
                     , "ensurePostgresOperatorRuntime"
                     , "ensureMinioRuntime SubstrateAws MinioSteadyStateHarbor"
                     , "ensureGatewayMinioBootstrap"
                     , "ensureAdminPublicEdgeRoutes SubstrateAws"
                     ]
      it
        "places the containerd mirror DaemonSet apply before any MinIO or Harbor install (so 127.0.0.1:30080 routes are live)"
        $ do
          let mirrorIndex = elemIndex "applyEksContainerdMirrorDaemonSet" steps
              minioIndex = elemIndex "ensureMinioRuntime SubstrateAws MinioBootstrapPublic" steps
              harborIndex = elemIndex "ensureHarborRegistryRuntime SubstrateAws" steps
          mirrorIndex `shouldSatisfy` (`indexPrecedes` minioIndex)
          mirrorIndex `shouldSatisfy` (`indexPrecedes` harborIndex)
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
        "places Percona before steady-state MinIO reconcile (so Percona is up before MinIO reschedules from Harbor refs)"
        $ do
          let perconaIndex = elemIndex "ensurePostgresOperatorRuntime" steps
              steadyIndex = elemIndex "ensureMinioRuntime SubstrateAws MinioSteadyStateHarbor" steps
          perconaIndex `shouldSatisfy` (`indexPrecedes` steadyIndex)
      it
        "places gateway MinIO bootstrap after AWS MinIO steady-state so first chart deploy can read/create the master seed"
        $ do
          let steadyIndex = elemIndex "ensureMinioRuntime SubstrateAws MinioSteadyStateHarbor" steps
              bootstrapIndex = elemIndex "ensureGatewayMinioBootstrap" steps
          steadyIndex `shouldSatisfy` (`indexPrecedes` bootstrapIndex)
      it
        "places AWS admin public-edge routes after gateway MinIO bootstrap so the OIDC client secret can be derived"
        $ do
          let bootstrapIndex = elemIndex "ensureGatewayMinioBootstrap" steps
              adminIndex = elemIndex "ensureAdminPublicEdgeRoutes SubstrateAws" steps
          bootstrapIndex `shouldSatisfy` (`indexPrecedes` adminIndex)
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
        rendered
          `shouldContain` "\"redirectURL\":\"https://aws.test.resolvefintech.com/harbor/oauth2/callback\""
        rendered
          `shouldContain` "\"issuer\":\"https://aws.test.resolvefintech.com/auth/realms/prodbox\""
        rendered
          `shouldNotContain` "\"hostnames\":[\"test.resolvefintech.com\"]"
      it
        "places custom-image build steps after image-mirror (Harbor populated) and before Percona (Percona pulls from Harbor)"
        $ do
          let mirrorIndex = elemIndex "applyEksImageMirrorJob" steps
              gatewayIndex = elemIndex "ensureGatewayImagesForSubstrate SubstrateAws" steps
              workloadIndex = elemIndex "ensurePublicEdgeWorkloadImageForSubstrate SubstrateAws" steps
              perconaIndex = elemIndex "ensurePostgresOperatorRuntime" steps
          mirrorIndex `shouldSatisfy` (`indexPrecedes` gatewayIndex)
          gatewayIndex `shouldSatisfy` (`indexPrecedes` workloadIndex)
          workloadIndex `shouldSatisfy` (`indexPrecedes` perconaIndex)

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

  describe "Sprint 7.5.c.i substrate-aware MinIO chart values" $ do
    it "Home substrate + bootstrap image source: binds the pre-created hostPath PVC, no storageClass" $ do
      let args = renderMinioChartArgs SubstrateHomeLocal MinioBootstrapPublic
      consecutivePair args "persistence.existingClaim=minio" `shouldBe` True
      consecutivePair args "persistence.size=200Gi" `shouldBe` True
      consecutivePair args "resources.requests.memory=512Mi" `shouldBe` True
      consecutivePair args "resources.limits.memory=2Gi" `shouldBe` True
      any ("persistence.storageClass=" `isPrefixOf`) args `shouldBe` False
      consecutivePair args "mode=standalone" `shouldBe` True
    it "Home substrate + steady-state image source: same persistence shape, Harbor-mirrored images" $ do
      let args = renderMinioChartArgs SubstrateHomeLocal MinioSteadyStateHarbor
      consecutivePair args "persistence.existingClaim=minio" `shouldBe` True
      any ("image.repository=127.0.0.1:30080" `isPrefixOf`) args `shouldBe` True
      any ("persistence.storageClass=" `isPrefixOf`) args `shouldBe` False
    it "AWS substrate + bootstrap image source: dynamic gp2 EBS PVC, no existingClaim, 20Gi" $ do
      let args = renderMinioChartArgs SubstrateAws MinioBootstrapPublic
      consecutivePair args "persistence.storageClass=gp2" `shouldBe` True
      consecutivePair args "persistence.size=20Gi" `shouldBe` True
      any ("persistence.existingClaim=" `isPrefixOf`) args `shouldBe` False
      consecutivePair args "mode=standalone" `shouldBe` True
    it "AWS substrate + steady-state image source: gp2 EBS + Harbor-mirrored images" $ do
      let args = renderMinioChartArgs SubstrateAws MinioSteadyStateHarbor
      consecutivePair args "persistence.storageClass=gp2" `shouldBe` True
      any ("image.repository=127.0.0.1:30080" `isPrefixOf`) args `shouldBe` True
      any ("persistence.existingClaim=" `isPrefixOf`) args `shouldBe` False

  describe "Sprint 7.6 AWS harness orphan-safety (Sprint 4.16 source-of-truth pure layer)" $ do
    it
      "Scenario A — direct teardown footgun: aws-eks present → residue refuses with eks-destroy hint"
      $ do
        let perRun = absentPerRunStatuses {perRunAwsEksTest = residuePresentFor "aws-eks-test"}
            residue = categorizePulumiResidue perRun Residue.ResidueAbsent
        residue `shouldBe` [("aws-eks", "prodbox pulumi eks-destroy --yes")]
        let refusal = renderPulumiResidueRefusal residue
        refusal `shouldContain` "aws-eks → prodbox pulumi eks-destroy --yes"
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
        `shouldBe` [ ("aws-eks-subzone", "prodbox pulumi aws-subzone-destroy --yes")
                   , ("aws-test", "prodbox pulumi test-destroy --yes")
                   ]
    it "Scenario D — SES present: aws-ses live → refusal names aws-ses-destroy as recovery" $ do
      let residue = categorizePulumiResidue absentPerRunStatuses (residuePresentFor "aws-ses")
      residue `shouldBe` [("aws-ses", "prodbox pulumi aws-ses-destroy --yes")]
      let refusal = renderPulumiResidueRefusal residue
      refusal `shouldContain` "aws-ses → prodbox pulumi aws-ses-destroy --yes"
    it "Scenario all-four — every stack present → all four canonical destroy commands in order" $ do
      let perRun =
            PerRunResidueStatuses
              { perRunAwsEksTest = residuePresentFor "aws-eks-test"
              , perRunAwsEksSubzone = residuePresentFor "aws-eks-subzone"
              , perRunAwsTest = residuePresentFor "aws-test"
              }
          residue = categorizePulumiResidue perRun (residuePresentFor "aws-ses")
      residue
        `shouldBe` [ ("aws-eks", "prodbox pulumi eks-destroy --yes")
                   , ("aws-eks-subzone", "prodbox pulumi aws-subzone-destroy --yes")
                   , ("aws-test", "prodbox pulumi test-destroy --yes")
                   , ("aws-ses", "prodbox pulumi aws-ses-destroy --yes")
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
        `shouldBe` [ ("aws-eks", "prodbox pulumi eks-destroy --yes")
                   , ("aws-eks-subzone", "prodbox pulumi aws-subzone-destroy --yes")
                   , ("aws-test", "prodbox pulumi test-destroy --yes")
                   ]
    it "Sprint 4.16 unreachable long-lived: S3 down → aws-ses treated as still-present (doctrine §3)" $ do
      let unreachable =
            Residue.ResidueUnreachable
              (Residue.ResidueBackendS3Unreachable "admin credentials missing")
          residue = categorizePulumiResidue absentPerRunStatuses unreachable
      residue `shouldBe` [("aws-ses", "prodbox pulumi aws-ses-destroy --yes")]

  describe "Sprint 4.19 per-run delete-gate refusal messages" $ do
    it "unreadable-only refusal names the escape hatch and warns against deleting .data" $ do
      let summary =
            Preconditions.perRunSummaryLine [] [("aws-eks", "unreachable (MinIO backend unreachable: refused)")]
          narrative =
            Preconditions.renderPerRunRefusal
              []
              [("aws-eks", "unreachable (MinIO backend unreachable: refused)")]
      summary `shouldContain` "unreachable"
      summary `shouldContain` "cannot confirm"
      narrative `shouldContain` "could not"
      narrative `shouldContain` "do NOT delete `.data/`"
      narrative `shouldContain` "--allow-pulumi-residue"

    it "live-only refusal lists the canonical destroy command and the cascade alternative" $ do
      let narrative = Preconditions.renderPerRunRefusal [("aws-eks", "prodbox pulumi eks-destroy --yes")] []
      narrative `shouldContain` "aws-eks → prodbox pulumi eks-destroy --yes"
      narrative `shouldContain` "--cascade"

    it "summary distinguishes the present-and-unreachable combination" $ do
      let summary =
            Preconditions.perRunSummaryLine
              [("aws-eks", "prodbox pulumi eks-destroy --yes")]
              [("aws-test", "unreachable (MinIO backend unreachable: refused)")]
      summary `shouldContain` "live resources"
      summary `shouldContain` "unreachable"

  describe "Sprint 4.20 managed-resource registry facts" $ do
    it "every per-run stack the lifecycle classes declares is a Pulumi stack" $
      ResourceClass.resourceNamesOfClass ResourceClass.PerRun
        `shouldBe` ["aws-eks", "aws-eks-subzone", "aws-test"]

    it "the long-lived class is aws-ses plus the retained public-edge cert (Sprint 4.24)" $
      ResourceClass.resourceNamesOfClass ResourceClass.LongLived
        `shouldBe` ["aws-ses", "public-edge-tls"]

    it "the operational class registers the IAM user and the aws.* config block" $
      ResourceClass.resourceNamesOfClass ResourceClass.Operational
        `shouldBe` ["operational-iam-user", "operational-aws-config"]

    it "perRunStackNames is derived from the registry (matches the prior literal)" $
      perRunStackNames `shouldBe` ["aws-eks", "aws-eks-subzone", "aws-test"]

    it "longLivedStackNames is derived from the registry (aws-ses + public-edge-tls)" $
      longLivedStackNames `shouldBe` ["aws-ses", "public-edge-tls"]

    it "derived stack-name lists equal the PerRun/LongLived registry classes" $ do
      perRunStackNames `shouldBe` ResourceClass.resourceNamesOfClass ResourceClass.PerRun
      longLivedStackNames `shouldBe` ResourceClass.resourceNamesOfClass ResourceClass.LongLived

    it "Sprint 4.22 renderRegisteredResourcesMarkdown renders every registered resource + class" $ do
      let rendered =
            ResourceClass.renderRegisteredResourcesMarkdown ResourceClass.resourceLifecycleClasses
      rendered `shouldContain` "| Resource | Lifecycle class |"
      rendered `shouldContain` "| `aws-eks` | PerRun |"
      rendered `shouldContain` "| `aws-ses` | LongLived |"
      rendered `shouldContain` "| `public-edge-tls` | LongLived |"
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

  describe "ZeroSSL ACME ClusterIssuer + cert retention key scheme" $ do
    let settings = testValidatedSettings "/tmp"
        zoneId = "ZHOSTEDZONE"
        baseConfig = validatedConfig settings
        eabSettings =
          settings
            { validatedConfig =
                baseConfig
                  { acme =
                      (acme baseConfig)
                        { eab_key_id = Just "test-eab-key-id"
                        , eab_hmac_key = Just "test-eab-hmac-key"
                        }
                  }
            }

    it "the issuer spec renders acme.server (ZeroSSL) and the ZeroSSL account key" $ do
      let rendered = BL8.unpack (encode (acmeClusterIssuerSpec settings zoneId))
      rendered `shouldContain` "https://acme.zerossl.com/v2/DV90"
      rendered `shouldContain` "zerossl-account-key"

    it "the issuer spec references the DNS-01 Route 53 solver secret and hosted zone" $ do
      let rendered = BL8.unpack (encode (acmeClusterIssuerSpec settings zoneId))
      rendered `shouldContain` "route53-credentials"
      rendered `shouldContain` "ZHOSTEDZONE"

    it "the issuer spec includes the ZeroSSL external account binding when configured" $ do
      let rendered = BL8.unpack (encode (acmeClusterIssuerSpec eabSettings zoneId))
      rendered `shouldContain` "externalAccountBinding"

    it "acmeRuntimeManifestWith renders the single ZeroSSL ClusterIssuer" $
      clusterIssuerNamesIn
        (acmeRuntimeManifestWith SubstrateHomeLocal settings zoneId "pid" "lbl")
        `shouldBe` [publicEdgeClusterIssuerName]

    it "the public-edge ClusterIssuer name is the ZeroSSL cert-manager issuer" $
      publicEdgeClusterIssuerName `shouldBe` "zerossl-http01"

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
                          , "cert-manager.io/issuer-name" .= ("zerossl-http01" :: Text.Text)
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
          , "cert-manager.io/issuer-name" .= ("zerossl-http01" :: Text.Text)
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
        length violations `shouldBe` 1
        head violations `shouldContain` "src/Prodbox/Probe/Hit.hs"
        head violations `shouldContain` ".prodbox-state/"

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
        length violations `shouldBe` 1
        head violations `shouldContain` ".prodbox-state/"

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
      length violations `shouldBe` 1
      head violations `shouldContain` "PulumiFooResources"

    it "a mapped stack absent from the registered names yields a violation naming that stack" $ do
      let registeredWithoutSes = filter (/= "aws-ses") registeredNames
          violations =
            pulumiCreateSiteViolations registeredWithoutSes commandWithKnownConstructors
      length violations `shouldBe` 1
      head violations `shouldContain` "aws-ses"

    it "iamCreateSiteViolations allows the owner module src/Prodbox/Aws.hs" $
      iamCreateSiteViolations "src/Prodbox/Aws.hs" contentsWithCreateUser `shouldBe` []

    it "iamCreateSiteViolations flags an IAM create verb outside the owner module" $ do
      let violations =
            iamCreateSiteViolations "src/Prodbox/Other.hs" contentsWithCreateUser
      length violations `shouldBe` 1
      head violations `shouldContain` "create-user"
      head violations `shouldContain` "src/Prodbox/Aws.hs"

    it "iamCreateSiteViolations ignores a non-owner module with no IAM create verbs" $
      iamCreateSiteViolations "src/Prodbox/Other.hs" contentsWithoutVerbs `shouldBe` []

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
      plan `shouldContain` "STEP=1 K8s drain"
      plan `shouldContain` "STEP=2 prodbox pulumi aws-ses-destroy"
      plan `shouldContain` "STEP=3 prodbox aws teardown"
      plan `shouldContain` "STEP=4 postflight tag sweep"
      plan `shouldContain` "STEP=5 destroy long-lived `pulumi_state_backend` S3 bucket"
      plan `shouldContain` "ADMIN_CREDENTIAL_SOURCE=prodbox-config.dhall::aws_admin_for_test_simulation.*"
      plan `shouldContain` "CONFIRMATION_LITERAL=NUKE EVERYTHING"

  describe "Sprint 7.7 residue lifecycle partition" $ do
    it "perRunStackNames matches substrates-doctrine Resource Lifecycle Classes verbatim" $
      perRunStackNames `shouldBe` ["aws-eks", "aws-eks-subzone", "aws-test"]
    it "longLivedStackNames lists aws-ses and the retained public-edge cert (Sprint 4.24)" $
      longLivedStackNames `shouldBe` ["aws-ses", "public-edge-tls"]
    it "partitionResidueByLifecycle splits residue correctly with all four stacks live" $ do
      let allFour =
            [ ("aws-eks", "prodbox pulumi eks-destroy --yes")
            , ("aws-eks-subzone", "prodbox pulumi aws-subzone-destroy --yes")
            , ("aws-test", "prodbox pulumi test-destroy --yes")
            , ("aws-ses", "prodbox pulumi aws-ses-destroy --yes")
            ]
          (perRun, longLived) = partitionResidueByLifecycle allFour
      map fst perRun `shouldBe` ["aws-eks", "aws-eks-subzone", "aws-test"]
      map fst longLived `shouldBe` ["aws-ses"]
    it "pulumiDestroyPlanForResidue orders subzone -> eks -> test -> ses (most expensive last)" $ do
      let allFour =
            [ ("aws-eks", "prodbox pulumi eks-destroy --yes")
            , ("aws-eks-subzone", "prodbox pulumi aws-subzone-destroy --yes")
            , ("aws-test", "prodbox pulumi test-destroy --yes")
            , ("aws-ses", "prodbox pulumi aws-ses-destroy --yes")
            ]
      map fst (pulumiDestroyPlanForResidue allFour)
        `shouldBe` ["aws-eks-subzone", "aws-eks", "aws-test", "aws-ses"]
    it "pulumiDestroyPlanForResidue preserves canonical order even when input is reordered" $ do
      let reordered =
            [ ("aws-ses", "prodbox pulumi aws-ses-destroy --yes")
            , ("aws-test", "prodbox pulumi test-destroy --yes")
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
        refusal `shouldContain` "aws-ses → prodbox pulumi aws-ses-destroy --yes"
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
          `shouldContain` "aws-ses → prodbox pulumi aws-ses-destroy --yes"
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
        `shouldBe` [("aws-eks", "prodbox pulumi eks-destroy --yes")]
    it
      "Scenario K — aws-ses only: destroy plan names aws-ses-destroy (long-lived warning fires at dispatch)"
      $ do
        let residue =
              categorizePulumiResidue
                absentPerRunStatuses
                (residuePresentFor "aws-ses")
        pulumiDestroyPlanForResidue residue
          `shouldBe` [("aws-ses", "prodbox pulumi aws-ses-destroy --yes")]
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
            , "Edit prodbox-config.dhall directly"
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

  describe "settings" $ do
    it "validates Dhall config and renders masked output without materializing JSON" $
      withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
        writeFile (tmpDir </> "prodbox-config.dhall") validConfig

        result <- validateAndLoadSettings tmpDir

        case result of
          Left err -> expectationFailure err
          Right settings -> do
            renderSettingsDisplay False settings `shouldContain` "aws.access_key_id=****-key"
            renderSettingsDisplay False settings `shouldContain` "acme.email=****.com"
            renderSettingsDisplay True settings `shouldContain` "aws.access_key_id=test-access-key"
            renderSettingsDisplay False settings
              `shouldContain` ("storage.manual_pv_host_root=" ++ (tmpDir </> ".data"))
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

    it "fails fast on invalid ZeroSSL EAB configuration" $
      withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
        writeFile (tmpDir </> "prodbox-config.dhall") invalidZeroSslConfig

        result <- validateAndLoadSettings tmpDir

        case result of
          Left err -> err `shouldContain` "required for ZeroSSL ACME"
          Right _ -> expectationFailure "expected validation failure"

    it "fails fast with setup guidance when the repo Dhall config is missing" $
      withSystemTempDirectory "prodbox-hs-unit" $ \tmpDir -> do
        result <- validateAndLoadSettings tmpDir

        case result of
          Left err -> do
            err `shouldContain` "Missing required repository config"
            err `shouldContain` (tmpDir </> "prodbox-config.dhall")
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

-- | Build a 'SignedEvent' whose hash and HMAC signature match the
-- canonical unsigned-payload encoding the daemon uses.  Used by the
-- peer-transport tests to construct round-trippable batches.
signedEventStub :: String -> String -> String -> SignedEvent
signedEventStub nodeId evType ts =
  Peer.signEvent nodeId evType ts "{}" "fake-key"

encodeJsonValue :: Value -> BL8.ByteString
encodeJsonValue = encode

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

lookupPrerequisiteNode :: String -> EffectNode
lookupPrerequisiteNode prerequisiteId =
  case Map.lookup prerequisiteId prerequisiteRegistry of
    Just node -> node
    Nothing -> error ("missing prerequisite in test registry: " ++ prerequisiteId)

lookupPrerequisiteEffect :: String -> Effect
lookupPrerequisiteEffect = effectNodeEffect . lookupPrerequisiteNode

hasCycle :: Set.Set String -> String -> Bool
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
    [ "{ aws = { access_key_id = \"test-access-key\", secret_access_key = \"test-secret-key\", session_token = Some \"test-session-token\", region = \"us-east-1\" }"
    , ", aws_admin_for_test_simulation = { access_key_id = \"\", secret_access_key = \"\", session_token = None Text, region = \"\" }"
    , ", route53 = { zone_id = \"Z1234567890ABC\" }"
    , ", aws_substrate = { hosted_zone_id = \"\", subzone_name = \"\" }"
    , ", ses = { sender_domain = \"\", receive_subdomain = \"\", capture_bucket = \"\" }"
    , ", domain = { demo_fqdn = \"test.resolvefintech.com\", demo_ttl = 60 }"
    , ", acme = { email = \"test@resolvefintech.com\", server = \"https://acme.zerossl.com/v2/DV90\", eab_key_id = Some \"test-eab-key-id\", eab_hmac_key = Some \"test-eab-hmac-key\" }"
    , ", deployment = " ++ deploymentDhallFragment
    , ", storage = { manual_pv_host_root = \".data\" }"
    , ", pulumi_state_backend = " ++ pulumiStateBackendDhallFragment
    , "}"
    ]
invalidZeroSslConfig :: String
invalidZeroSslConfig =
  unlines
    [ "{ aws = { access_key_id = \"test-access-key\", secret_access_key = \"test-secret-key\", session_token = None Text, region = \"us-east-1\" }"
    , ", aws_admin_for_test_simulation = { access_key_id = \"\", secret_access_key = \"\", session_token = None Text, region = \"\" }"
    , ", route53 = { zone_id = \"Z1234567890ABC\" }"
    , ", aws_substrate = { hosted_zone_id = \"\", subzone_name = \"\" }"
    , ", ses = { sender_domain = \"\", receive_subdomain = \"\", capture_bucket = \"\" }"
    , ", domain = { demo_fqdn = \"test.resolvefintech.com\", demo_ttl = 60 }"
    , ", acme = { email = \"test@resolvefintech.com\", server = \"https://acme.zerossl.com/v2/DV90\", eab_key_id = None Text, eab_hmac_key = None Text }"
    , ", deployment = " ++ deploymentDhallFragment
    , ", storage = { manual_pv_host_root = \".data\" }"
    , ", pulumi_state_backend = " ++ pulumiStateBackendDhallFragment
    , "}"
    ]

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
    , ", envoy_gateway_controller_replicas = None Natural"
    , ", envoy_gateway_data_plane_replicas = None Natural"
    , ", api_replicas = None Natural"
    , ", websocket_replicas = None Natural"
    , " }"
    ]

validDeploymentSection :: DeploymentSection
validDeploymentSection =
  DeploymentSection
    { dev_mode = True
    , bootstrap_public_ip_override = Nothing
    , pulumi_enable_dns_bootstrap = True
    , public_edge_advertisement_mode = Just "l2"
    , public_edge_bgp_peers = Nothing
    , envoy_gateway_controller_replicas = Just 1
    , envoy_gateway_data_plane_replicas = Just 1
    , api_replicas = Just 2
    , websocket_replicas = Just 2
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

testValidatedSettings :: FilePath -> ValidatedSettings
testValidatedSettings manualRoot =
  ValidatedSettings
    { validatedConfig =
        defaultConfigFile
          { aws =
              Credentials
                { access_key_id = "test-access-key"
                , secret_access_key = "test-secret-key"
                , session_token = Just "test-session-token"
                , region = "us-east-1"
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
    , configSetupEnvoyGatewayControllerReplicasInput = Just 1
    , configSetupEnvoyGatewayDataPlaneReplicasInput = Just 1
    , configSetupApiReplicasInput = Just 2
    , configSetupWebsocketReplicasInput = Just 2
    , configSetupManualPvHostRootInput = "/tmp/prodbox/.data"
    , configSetupPolicyTierInput = PolicyFull
    }

roundTripConfigFile :: ConfigFile
roundTripConfigFile =
  defaultConfigFile
    { aws =
        Credentials
          { access_key_id = "test-access-key"
          , secret_access_key = "test-secret-key"
          , session_token = Just "test-session-token"
          , region = "us-east-1"
          }
    , aws_admin_for_test_simulation =
        Credentials
          { access_key_id = "admin-access-key"
          , secret_access_key = "admin-secret-key"
          , session_token = Just "admin-session-token"
          , region = "us-west-2"
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

sampleDaemonConfig :: DaemonConfig
sampleDaemonConfig =
  DaemonConfig
    { daemonNodeId = "node-a"
    , daemonCertFile = "/tmp/node-a.crt"
    , daemonKeyFile = "/tmp/node-a.key"
    , daemonCaFile = "/tmp/ca.crt"
    , daemonOrdersFile = "/tmp/orders.json"
    , daemonEventKeys = [("node-a", "fake-key")]
    , daemonHeartbeatInterval = 1.0
    , daemonReconnectInterval = 1.0
    , daemonSyncInterval = 1.0
    , daemonMaxClockSkewSeconds = defaultMaxClockSkewSeconds
    , daemonDrainDeadlineSeconds = Just 30
    , daemonConfigLogLevel = Just "info"
    , daemonDnsWriteGate =
        Just
          DnsWriteGate
            { dnsWriteGateZoneId = "Z1234567890ABC"
            , dnsWriteGateFqdn = "test.resolvefintech.com"
            , dnsWriteGateTtl = 60
            , dnsWriteGateAwsRegion = "us-east-1"
            }
    , daemonAwsCreds = Nothing
    , daemonMinioCreds = Nothing
    }

sampleSignedEvent :: SignedEvent
sampleSignedEvent =
  signedEventStub "node-a" eventTypeHeartbeat "2026-04-06T10:00:00Z"

storedDaemonEvent :: String -> Integer -> Maybe UTCTime -> DaemonEvents.StoredEvent
storedDaemonEvent eventName createdSecond processedAt =
  DaemonEvents.StoredEvent
    { DaemonEvents.eventId = DaemonEvents.EventId eventName
    , DaemonEvents.eventAggregateId = DaemonEvents.AggregateId "aggregate-a"
    , DaemonEvents.eventType = DaemonEvents.EventType "heartbeat"
    , DaemonEvents.eventPayload = object ["event_name" .= eventName]
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
    , AwsTest.testSnapshotBackendBucket = "prodbox-test-pulumi-backends"
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
    , AwsEks.eksSnapshotBackendBucket = "prodbox-test-pulumi-backends"
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
    }

-- | Sprint 4.18: the flat @Map Text Text@ shape the Pulumi backend
-- emits for the @aws-test@ stack — scalar outputs verbatim, complex
-- outputs (@subnet_ids@, @nodes@) as JSON-encoded strings. Decodes
-- back to 'sampleAwsTestStackSnapshot' via 'parseAwsTestStackFromOutputs'.
sampleAwsTestStackOutputsMap :: Map.Map Text.Text Text.Text
sampleAwsTestStackOutputsMap =
  Map.fromList
    [ ("backend_bucket", "prodbox-test-pulumi-backends")
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
    [ ("backend_bucket", "prodbox-test-pulumi-backends")
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
    ]

daemonConfigJsonValue :: DaemonConfig -> Value
daemonConfigJsonValue config =
  object
    [ "node_id" .= daemonNodeId config
    , "cert_file" .= daemonCertFile config
    , "key_file" .= daemonKeyFile config
    , "ca_file" .= daemonCaFile config
    , "orders_file" .= daemonOrdersFile config
    , "event_keys" .= object [Key.fromString nodeId .= key | (nodeId, key) <- daemonEventKeys config]
    , "heartbeat_interval_seconds" .= daemonHeartbeatInterval config
    , "reconnect_interval_seconds" .= daemonReconnectInterval config
    , "sync_interval_seconds" .= daemonSyncInterval config
    , "max_clock_skew_seconds" .= daemonMaxClockSkewSeconds config
    , "drain_deadline_seconds" .= daemonDrainDeadlineSeconds config
    , "log_level" .= daemonConfigLogLevel config
    , "dns_write_gate" .= fmap dnsWriteGateJsonValue (daemonDnsWriteGate config)
    ]

dnsWriteGateJsonValue :: DnsWriteGate -> Value
dnsWriteGateJsonValue gate =
  object
    [ "zone_id" .= dnsWriteGateZoneId gate
    , "fqdn" .= dnsWriteGateFqdn gate
    , "ttl" .= dnsWriteGateTtl gate
    , "aws_region" .= dnsWriteGateAwsRegion gate
    ]

ordersJsonValue :: Orders -> Value
ordersJsonValue orders =
  object
    [ "version_utc" .= ordersVersionUtc orders
    , "nodes" .= map peerEndpointJsonValue (ordersNodes orders)
    , "gateway_rule" .= gatewayRuleJsonValue (ordersGatewayRule orders)
    ]

peerEndpointJsonValue :: PeerEndpoint -> Value
peerEndpointJsonValue peer =
  object
    [ "node_id" .= peerNodeId peer
    , "stable_dns_name" .= peerStableDnsName peer
    , "rest_host" .= peerRestHost peer
    , "rest_port" .= peerRestPort peer
    , "socket_host" .= peerSocketHost peer
    , "socket_port" .= peerSocketPort peer
    ]

gatewayRuleJsonValue :: GatewayRule -> Value
gatewayRuleJsonValue rule =
  object
    [ "ranked_nodes" .= rankedNodes rule
    , "heartbeat_timeout_seconds" .= heartbeatTimeoutSeconds rule
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
