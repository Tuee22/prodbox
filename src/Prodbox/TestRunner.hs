{-# LANGUAGE OverloadedStrings #-}

module Prodbox.TestRunner
  ( runTests
  , ClusterEvidence (..)
  , TestGate (..)
  , TestDeleteTarget (..)
  , TestRefusal (..)
  , clearOperationalCredsAfterPostflight
  , guardTestDelete
  , integrationRunbookCommandArgs
  , PublicEdgeCertificateFailure (..)
  , awsSubstrateBootstrapCommandArgs
  , awsSubstrateBootstrapRestorePlan
  , awsSubstrateBootstrapRestoreSteps
  , awsSubstrateBootstrapPreMonitorSteps
  , awsSubstrateBootstrapPostMonitorSteps
  , awsPostflightDestroyCommandArgs
  , GatewayRuntimeValidationBoundary (..)
  , gatewayRuntimeValidationBoundary
  , publicEdgeCertificateReissueStatusPatch
  , renderTestRefusal
  , supportedRuntimeBootstrapNeedsReconcile
  , supportedRuntimeBootstrapRestorePlan
  , supportedRuntimePostflightRestorePlan
  , testModePreflightAtPaths
  , testModePreflightAtPath
  , testTopologyModeGate
  , testProductionConfigGate
  , testProductionClusterGate
  , topologyRunConfig
  , topologyVariantEnvironment
  , testScopeForTopologySuite
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( SomeException
  , displayException
  , finally
  , throwIO
  , try
  )
import Control.Monad (foldM, unless)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char qualified as Char
import Data.List (dropWhileEnd, find, isInfixOf, isPrefixOf)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Prodbox.Aws
  ( ConfigSetupInput (..)
  , configFromSetupInput
  , regenerateConfigFromTestSecrets
  , runAwsIamHarnessSetup
  , runAwsIamHarnessTeardown
  )
import Prodbox.AwsEnvironment (awsCliSubprocessEnvironment)
import Prodbox.BuildSupport
  ( addBuildSupportEnvironment
  , canonicalOperatorBinaryPath
  , syncBuiltOperatorBinary
  )
import Prodbox.CLI.Command
  ( CoverageFlags (..)
  , IntegrationSuite (..)
  , PolicyTier (..)
  , TestCommand (..)
  , TestScope (..)
  , validateCoverage
  )
import Prodbox.CLI.Output
  ( writeDiagnostic
  , writeDiagnosticLine
  , writeError
  , writeOutput
  , writeOutputLine
  )
import Prodbox.CLI.Rke2
  ( ensureGatewayMinioBootstrap
  , gatewayNamespace
  , observeGatewayBackendRoundTripOnceAt
  , observeGatewayReadyzOnceAt
  , rke2InstallPresent
  )
import Prodbox.CheckCode (runCheckCode)
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.EffectDAG
  ( fromRootIds
  )
import Prodbox.EffectInterpreter
  ( InterpreterContext (..)
  , runEffectDAG
  )
import Prodbox.Error (fatalError)
import Prodbox.Gateway.Client qualified as GatewayClient
import Prodbox.Gateway.PortForward
  ( GatewayServicePortForward (..)
  , renderGatewayPortForwardError
  , withGatewayServicePortForward
  )
import Prodbox.Gateway.Types (PeerEndpoint (..), peerRestUrl)
import Prodbox.Infra.AwsEksTestStack
  ( awsEksCanonicalClusterName
  , withEksKubeconfig
  )
import Prodbox.Infra.AwsSesStack qualified as AwsSesStack
import Prodbox.Lib.ChartPlatform
  ( gatewayRestServiceName
  , gatewayRestServicePort
  , renderPublicEdgePreserveOutcome
  , retainReadyPublicEdgeCertificate
  )
import Prodbox.Lib.Storage
  ( testCaseDataRoot
  , testDataRootRelative
  , testManualPvHostRootEnv
  )
import Prodbox.Lifecycle.AuthorityConfig
  ( checkpointGatewayNodePort
  , resolveLongLivedCheckpointAuthority
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( checkpointAuthorityClusterId
  , checkpointAuthorityGatewayEndpoint
  , mkTargetClusterSecretSink
  )
import Prodbox.Lifecycle.Preconditions
  ( checkAll
  , renderPreconditionFailures
  )
import Prodbox.Lifecycle.ResourceClass qualified as ResourceClass
import Prodbox.Lifecycle.RestoreGraph
  ( RestoreNodeResult (..)
  , RestoreOutcome (..)
  , RestoreReport (..)
  , buildRestoreGraphForPlan
  , restoreCycleStepNodeId
  , restoreReportBlocked
  , restoreReportFailed
  , runRestoreGraphWith
  )
import Prodbox.Prerequisite
  ( prerequisiteRegistry
  )
import Prodbox.Repo
  ( resolveTestTopologyConfigPath
  , resolveTier0ConfigPath
  )
import Prodbox.Result
  ( Result (..)
  )
import Prodbox.Settings
  ( AcmeSection (..)
  , AwsCredentialsRef (..)
  , ConfigFile (..)
  , Credentials (..)
  , DeploymentSection (..)
  , DomainSection (..)
  , Route53Section (..)
  , ValidatedSettings (..)
  , acme
  , aws
  , defaultConfigFile
  , deployment
  , domain
  , forceSyncInForceConfigFromFile
  , loadTestTopology
  , resolveAwsCredentialsRefFromHostVault
  , route53
  , validateAndLoadSettings
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , commandDisplay
  , runSubprocessStreaming
  )
import Prodbox.Substrate (Substrate (..), substrateId)
import Prodbox.TestPlan
  ( NativeSuitePlan (..)
  , NativeValidation (..)
  , TestExecutionMode (..)
  , TestExecutionPlan (..)
  , retainedSesRequirementForValidations
  , testExecutionPlan
  )
import Prodbox.TestRestore
  ( RestoreChart (..)
  , RestoreCyclePlan (..)
  , RestoreCycleStep (..)
  , RetainedSesPreparationInputs (..)
  , RetainedSesPreparationInterpreter (..)
  , RetainedSesPreparationPlan
  , RetainedSesPreparationPrecondition (..)
  , RetainedSesPreparationStep (..)
  , RetainedSesRequirement (..)
  , buildRestoreCyclePlan
  , gatewayDaemonLivenessPrecondition
  , restoreChartId
  , restoreStepResetsGatewayHealthyWindow
  , retainedSesPreparationTrace
  , runRetainedSesPreparationWith
  )
import Prodbox.TestTopology
  ( TestSuite (..)
  , TestTopology (..)
  , defaultTestTopology
  , renderTestTopologyDhall
  )
import Prodbox.TestValidation
  ( GatewayRuntimeStabilityMonitor
  , GatewayRuntimeStabilityRecorder
  , newGatewayRuntimeStabilityRecorder
  , pauseGatewayRuntimeStabilityMonitor
  , recordGatewayRuntimeStabilitySample
  , refreshGatewayRuntimeStabilityMonitor
  , resetGatewayRuntimeStabilityHealthyWindow
  , resumeGatewayRuntimeStabilityMonitor
  , runGatewayRuntimeStabilityGate
  , runNativeValidationWithGatewayStability
  , withGatewayRuntimeStabilityMonitor
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , removePathForcibly
  )
import System.Environment (getEnvironment)
import System.Exit
  ( ExitCode (..)
  )
import System.FilePath
  ( isAbsolute
  , normalise
  , splitDirectories
  , takeDirectory
  , takeFileName
  , (</>)
  )

phaseOneGateMessage :: String
phaseOneGateMessage = "Phase 1/2: validating integration prerequisites"

phaseOneNoPrereqMessage :: String
phaseOneNoPrereqMessage = "Phase 1/2: no integration prerequisites required"

phaseOnePointFiveMessage :: String
phaseOnePointFiveMessage = "Phase 1.5/2: enforcing integration runbook"

phaseOnePointSixMessage :: String
phaseOnePointSixMessage = "Phase 1.6/2: restoring supported runtime"

phaseTwoMessage :: String
phaseTwoMessage = "Phase 2/2: running test suites"

postTestRestoreMessage :: String
postTestRestoreMessage = "Post-test: restoring supported runtime"

publicEdgeNamespace :: String
publicEdgeNamespace = "vscode"

publicEdgeCertificateName :: String
publicEdgeCertificateName = "public-edge-tls"

publicEdgeReadyClassification :: String
publicEdgeReadyClassification = "CLASSIFICATION=ready-for-external-proof"

publicEdgeReadyAttempts :: Int
publicEdgeReadyAttempts = 60

publicEdgeReadyDelayMicroseconds :: Int
publicEdgeReadyDelayMicroseconds = 10000000

publicEdgeCertificateRepairAttempts :: Int
publicEdgeCertificateRepairAttempts = 3

data PublicEdgeCertificateFailure = PublicEdgeCertificateFailure
  { publicEdgeFailedIssuanceAttempts :: Int
  , publicEdgeNextPrivateKeySecretName :: Maybe String
  , publicEdgeCertificateObservedGeneration :: Maybe Int
  }
  deriving (Eq, Show)

data TestGate
  = TestGateClear
  | TestGateRefuse TestRefusal
  deriving (Eq, Show)

data ClusterEvidence = ClusterEvidence
  { clusterEvidenceDescription :: String
  }
  deriving (Eq, Show)

data TestDeleteTarget
  = DeleteGeneratedRunConfig FilePath
  | DeleteThisRunTestData FilePath
  | DeletePerRunResidue String
  deriving (Eq, Show)

data TestRefusal
  = ProductionConfigPresent FilePath
  | ProductionClusterRunning ClusterEvidence
  | TestDeleteOutsideTestData FilePath
  | TestDeleteLongLivedResource String
  | UnknownTopologySuite String
  deriving (Eq, Show)

runTests :: FilePath -> TestCommand -> IO ExitCode
runTests repoRoot command =
  case validateCoverage (testCoverage command) of
    Left err -> failWith err
    Right () ->
      case testScope command of
        TestInit force -> runTopologyTestInit repoRoot force
        TestRun suiteName -> runTopologyTestRun repoRoot suiteName (testCoverage command) (testSubstrate command)
        _ -> do
          preflightExit <- runTestModePreflight repoRoot
          case preflightExit of
            failure@(ExitFailure _) -> pure failure
            ExitSuccess -> runLegacyTestCommand repoRoot command

runLegacyTestCommand :: FilePath -> TestCommand -> IO ExitCode
runLegacyTestCommand repoRoot command = do
  baseEnvironment <- getEnvironment
  environment <- addBuildSupportEnvironment repoRoot baseEnvironment
  let plan = testExecutionPlan (testSubstrate command) (testScope command)
  writeOutputLine ("Running prodbox test " ++ testPlanLabel plan ++ " (Haskell entrypoint)")
  case testScope command of
    TestLint -> runLintFirst repoRoot environment
    TestAll -> do
      lintExit <- runLintFirst repoRoot environment
      case lintExit of
        ExitSuccess ->
          runPlannedTests repoRoot environment plan
        failure@(ExitFailure _) -> pure failure
    _ -> runPlannedTests repoRoot environment plan

runTestModePreflight :: FilePath -> IO ExitCode
runTestModePreflight repoRoot = do
  productionConfigPath <- resolveTier0ConfigPath repoRoot
  testTopologyPath <- resolveTestTopologyConfigPath repoRoot
  gate <- testModePreflightAtPaths productionConfigPath testTopologyPath
  case gate of
    TestGateClear -> pure ExitSuccess
    TestGateRefuse refusal -> failWith (renderTestRefusal refusal)

testModePreflightAtPath :: FilePath -> IO TestGate
testModePreflightAtPath productionConfigPath =
  testProductionConfigGate productionConfigPath <$> doesFileExist productionConfigPath

testModePreflightAtPaths :: FilePath -> FilePath -> IO TestGate
testModePreflightAtPaths productionConfigPath testTopologyPath =
  testTopologyModeGate productionConfigPath
    <$> doesFileExist testTopologyPath
    <*> doesFileExist productionConfigPath

testTopologyModeGate :: FilePath -> Bool -> Bool -> TestGate
testTopologyModeGate productionConfigPath testTopologyPresent productionConfigPresent =
  if testTopologyPresent
    then testProductionConfigGate productionConfigPath productionConfigPresent
    else TestGateClear

testProductionConfigGate :: FilePath -> Bool -> TestGate
testProductionConfigGate productionConfigPath productionConfigPresent =
  if productionConfigPresent
    then TestGateRefuse (ProductionConfigPresent productionConfigPath)
    else TestGateClear

renderTestRefusal :: TestRefusal -> String
renderTestRefusal refusal =
  case refusal of
    ProductionConfigPresent path ->
      "Refusing to run tests while production binary-sibling config exists at `"
        ++ path
        ++ "`. Remove or move that production `prodbox.dhall` before running the test harness; "
        ++ "topology-driven tests may create a disposable per-run config only after this gate clears."
    ProductionClusterRunning evidence ->
      "Refusing to run topology-driven tests while a production cluster appears to be running ("
        ++ clusterEvidenceDescription evidence
        ++ "). Stop or delete the production cluster before running `prodbox test init` or `prodbox test run`."
    TestDeleteOutsideTestData path ->
      "Refusing test cleanup target outside `"
        ++ testDataRootRelative
        ++ "`: "
        ++ path
    TestDeleteLongLivedResource resourceName ->
      "Refusing test cleanup of long-lived resource `" ++ resourceName ++ "`."
    UnknownTopologySuite suiteName ->
      "Unknown test topology suite `" ++ suiteName ++ "`."

runTopologyTestInit :: FilePath -> Bool -> IO ExitCode
runTopologyTestInit repoRoot force = do
  preflightExit <- runTopologyCommandPreflight repoRoot
  case preflightExit of
    failure@(ExitFailure _) -> pure failure
    ExitSuccess -> do
      topologyPath <- resolveTestTopologyConfigPath repoRoot
      exists <- doesFileExist topologyPath
      if exists && not force
        then
          failWith
            ( "Refusing to overwrite existing test topology `"
                ++ topologyPath
                ++ "`. Re-run with `--force` to replace it."
            )
        else do
          createDirectoryIfMissing True (takeDirectory topologyPath)
          writeFile
            topologyPath
            (renderTestTopologyDhall (repoRoot </> "dhall" </> "TestTopologySchema.dhall") defaultTestTopology)
          writeOutputLine ("Wrote test topology: " ++ topologyPath)
          pure ExitSuccess

runTopologyTestRun :: FilePath -> String -> CoverageFlags -> Substrate -> IO ExitCode
runTopologyTestRun repoRoot requestedSuite coverage substrate = do
  preflightExit <- runTopologyCommandPreflight repoRoot
  case preflightExit of
    failure@(ExitFailure _) -> pure failure
    ExitSuccess -> do
      topologyResult <- loadTestTopology repoRoot
      case topologyResult of
        Left err -> failWith err
        Right topology ->
          case selectTopologySuites requestedSuite topology of
            Left refusal -> failWith (renderTestRefusal refusal)
            Right suites -> do
              baseEnvironment <- getEnvironment
              environment <- addBuildSupportEnvironment repoRoot baseEnvironment
              foldM (runTopologySuite repoRoot environment coverage substrate) ExitSuccess suites

runTopologyCommandPreflight :: FilePath -> IO ExitCode
runTopologyCommandPreflight repoRoot = do
  productionConfigPath <- resolveTier0ConfigPath repoRoot
  configGate <- testModePreflightAtPath productionConfigPath
  case configGate of
    TestGateRefuse refusal -> failWith (renderTestRefusal refusal)
    TestGateClear -> do
      clusterPresent <- rke2InstallPresent
      case testProductionClusterGate clusterPresent of
        TestGateClear -> pure ExitSuccess
        TestGateRefuse refusal -> failWith (renderTestRefusal refusal)

testProductionClusterGate :: Bool -> TestGate
testProductionClusterGate clusterPresent =
  if clusterPresent
    then
      TestGateRefuse
        ( ProductionClusterRunning
            ClusterEvidence
              { clusterEvidenceDescription = "RKE2 install marker present"
              }
        )
    else TestGateClear

selectTopologySuites :: String -> TestTopology -> Either TestRefusal [TestSuite]
selectTopologySuites requestedSuite topology
  | requestedSuite == "all" = Right (topologySuites topology)
  | otherwise =
      case filter ((== Text.pack requestedSuite) . suiteName) (topologySuites topology) of
        [] -> Left (UnknownTopologySuite requestedSuite)
        suites -> Right suites

runTopologySuite
  :: FilePath
  -> [(String, String)]
  -> CoverageFlags
  -> Substrate
  -> ExitCode
  -> TestSuite
  -> IO ExitCode
runTopologySuite _ _ _ _ failure@(ExitFailure _) _ = pure failure
runTopologySuite repoRoot environment coverage substrate ExitSuccess suite = do
  case testScopeForTopologySuite (Text.unpack (suiteName suite)) of
    Left err -> failWith err
    Right scope -> do
      let variants = zip [(1 :: Int) ..] (suiteVariants suite)
      foldM (runTopologyVariant repoRoot environment coverage substrate scope suite) ExitSuccess variants

runTopologyVariant
  :: FilePath
  -> [(String, String)]
  -> CoverageFlags
  -> Substrate
  -> TestScope
  -> TestSuite
  -> ExitCode
  -> (Int, a)
  -> IO ExitCode
runTopologyVariant _ _ _ _ _ _ failure@(ExitFailure _) _ = pure failure
runTopologyVariant repoRoot environment coverage substrate scope suite ExitSuccess (variantIndex, _) = do
  let caseId = topologyCaseId (Text.unpack (suiteName suite)) variantIndex
      testDataPath = repoRoot </> testCaseDataRoot caseId
      variantEnvironment = topologyVariantEnvironment testDataPath coverage environment
  generatedConfigPath <- resolveTier0ConfigPath repoRoot
  let cleanupTargets =
        [ DeleteGeneratedRunConfig generatedConfigPath
        , DeleteThisRunTestData testDataPath
        ]
  createDirectoryIfMissing True testDataPath
  ( do
      configWriteResult <- writeTopologyVariantConfig repoRoot testDataPath
      case configWriteResult of
        Left err -> failWith err
        Right () -> do
          writeOutputLine
            ( "Running topology suite `"
                ++ Text.unpack (suiteName suite)
                ++ "` variant "
                ++ show variantIndex
                ++ " with test data root "
                ++ testDataPath
            )
          runPlannedTests repoRoot variantEnvironment (testExecutionPlan substrate scope)
    )
    `finally` cleanupTestDeleteTargets repoRoot cleanupTargets

topologyVariantEnvironment :: FilePath -> CoverageFlags -> [(String, String)] -> [(String, String)]
topologyVariantEnvironment testDataPath coverage environment =
  withCoverageThreshold (withCoverage (withRoot environment))
 where
  withRoot = upsertEnv testManualPvHostRootEnv testDataPath
  withCoverage =
    if coverageEnabled coverage
      then upsertEnv "PRODBOX_TEST_COVERAGE" "1"
      else id
  withCoverageThreshold =
    case coverageFailUnder coverage of
      Nothing -> id
      Just threshold -> upsertEnv "PRODBOX_TEST_COVERAGE_FAIL_UNDER" (show threshold)

upsertEnv :: String -> String -> [(String, String)] -> [(String, String)]
upsertEnv name value environment =
  (name, value) : filter ((/= name) . fst) environment

writeTopologyVariantConfig :: FilePath -> FilePath -> IO (Either String ())
writeTopologyVariantConfig repoRoot testDataPath = do
  result <- Tier0.writeOperatorParametersToTier0 repoRoot (topologyRunConfig testDataPath)
  case result of
    Left err -> pure (Left err)
    Right () -> pure (Right ())

topologyRunConfig :: FilePath -> ConfigFile
topologyRunConfig testDataPath =
  configFromSetupInput defaultConfigFile (topologyConfigSetupInput testDataPath)

topologyConfigSetupInput :: FilePath -> ConfigSetupInput
topologyConfigSetupInput testDataPath =
  ConfigSetupInput
    { configSetupAdminCredentialsInput =
        Credentials
          { access_key_id = ""
          , secret_access_key = ""
          , session_token = Nothing
          , region = awsCredentialRegion (aws defaultConfigFile)
          }
    , configSetupRoute53ZoneIdInput = zone_id (route53 defaultConfigFile)
    , configSetupDemoFqdnInput = demo_fqdn (domain defaultConfigFile)
    , configSetupDemoTtlInput = demo_ttl (domain defaultConfigFile)
    , configSetupAcmeEmailInput = email (acme defaultConfigFile)
    , configSetupAcmeServerInput = server (acme defaultConfigFile)
    , configSetupAcmeEabKeyIdInput = Nothing
    , configSetupAcmeEabHmacKeyInput = Nothing
    , configSetupDevModeInput = dev_mode (deployment defaultConfigFile)
    , configSetupBootstrapPublicIpOverrideInput =
        bootstrap_public_ip_override (deployment defaultConfigFile)
    , configSetupPulumiEnableDnsBootstrapInput =
        pulumi_enable_dns_bootstrap (deployment defaultConfigFile)
    , configSetupPublicEdgeAdvertisementModeInput =
        public_edge_advertisement_mode (deployment defaultConfigFile)
    , configSetupPublicEdgeBgpPeersInput =
        public_edge_bgp_peers (deployment defaultConfigFile)
    , configSetupEnvoyGatewayControllerScalingInput =
        envoy_gateway_controller_scaling (deployment defaultConfigFile)
    , configSetupEnvoyGatewayDataPlaneScalingInput =
        envoy_gateway_data_plane_scaling (deployment defaultConfigFile)
    , configSetupApiScalingInput = api_scaling (deployment defaultConfigFile)
    , configSetupWebsocketScalingInput = websocket_scaling (deployment defaultConfigFile)
    , configSetupManualPvHostRootInput = Text.pack testDataPath
    , configSetupPolicyTierInput = PolicyFull
    }

testScopeForTopologySuite :: String -> Either String TestScope
testScopeForTopologySuite suiteName =
  case suiteName of
    "lint" -> Right TestLint
    "unit" -> Right TestUnit
    "integration-all" -> Right (TestIntegration IntegrationAll)
    "cli" -> Right (TestIntegration IntegrationCli)
    "aws-iam" -> Right (TestIntegration IntegrationAwsIam)
    "dns-aws" -> Right (TestIntegration IntegrationDnsAws)
    "aws-eks" -> Right (TestIntegration IntegrationAwsEks)
    "env" -> Right (TestIntegration IntegrationEnv)
    "gateway-daemon" -> Right (TestIntegration IntegrationGatewayDaemon)
    "gateway-pods" -> Right (TestIntegration IntegrationGatewayPods)
    "gateway-partition" -> Right (TestIntegration IntegrationGatewayPartition)
    "ha-rke2-aws" -> Right (TestIntegration IntegrationHaRke2Aws)
    "lifecycle" -> Right (TestIntegration IntegrationLifecycle)
    "pulumi" -> Right (TestIntegration IntegrationPulumi)
    "eks-volume-rebind" -> Right (TestIntegration IntegrationEksVolumeRebind)
    "charts-storage" -> Right (TestIntegration IntegrationChartsStorage)
    "charts-platform" -> Right (TestIntegration IntegrationChartsPlatform)
    "resource-guardrails" -> Right (TestIntegration IntegrationResourceGuardrails)
    "daemon-bootstrap" -> Right (TestIntegration IntegrationDaemonBootstrap)
    "pulsar-broker" -> Right (TestIntegration IntegrationPulsarBroker)
    "charts-vscode" -> Right (TestIntegration IntegrationChartsVscode)
    "charts-api" -> Right (TestIntegration IntegrationChartsApi)
    "charts-websocket" -> Right (TestIntegration IntegrationChartsWebsocket)
    "admin-routes" -> Right (TestIntegration IntegrationAdminRoutes)
    "public-dns" -> Right (TestIntegration IntegrationPublicDns)
    "keycloak-invite" -> Right (TestIntegration IntegrationKeycloakInvite)
    "sealed-vault" -> Right (TestIntegration IntegrationSealedVault)
    _ -> Left ("test topology suite `" ++ suiteName ++ "` is not mapped to a supported test scope")

topologyCaseId :: String -> Int -> FilePath
topologyCaseId suiteName variantIndex =
  sanitizeSegment suiteName </> ("variant-" ++ show variantIndex)

sanitizeSegment :: String -> String
sanitizeSegment raw =
  case map sanitizeChar raw of
    "" -> "unnamed"
    sanitized -> sanitized
 where
  sanitizeChar char
    | Char.isAlphaNum char = char
    | char == '-' = char
    | otherwise = '-'

cleanupTestDeleteTargets :: FilePath -> [TestDeleteTarget] -> IO ()
cleanupTestDeleteTargets repoRoot targets =
  mapM_ cleanup targets
 where
  cleanup target =
    case guardTestDelete repoRoot target of
      Left refusal -> writeDiagnosticLine (renderTestRefusal refusal)
      Right allowed ->
        case allowed of
          DeleteGeneratedRunConfig path -> removeFileIfPresent path
          DeleteThisRunTestData path -> removeDirectoryIfPresent path
          DeletePerRunResidue _ -> pure ()

removeFileIfPresent :: FilePath -> IO ()
removeFileIfPresent path = do
  exists <- doesFileExist path
  if exists then removePathForcibly path else pure ()

removeDirectoryIfPresent :: FilePath -> IO ()
removeDirectoryIfPresent path = do
  exists <- doesDirectoryExist path
  if exists then removePathForcibly path else pure ()

guardTestDelete :: FilePath -> TestDeleteTarget -> Either TestRefusal TestDeleteTarget
guardTestDelete repoRoot target =
  case target of
    DeleteGeneratedRunConfig path ->
      if pathWithinBuildRoot repoRoot path && takeFileName path == "prodbox.dhall"
        then Right target
        else Left (TestDeleteOutsideTestData path)
    DeleteThisRunTestData path ->
      if pathWithinTestDataRoot repoRoot path
        then Right target
        else Left (TestDeleteOutsideTestData path)
    DeletePerRunResidue resourceName ->
      if resourceName `elem` ResourceClass.resourceNamesOfClass ResourceClass.PerRun
        then Right target
        else Left (TestDeleteLongLivedResource resourceName)

pathWithinTestDataRoot :: FilePath -> FilePath -> Bool
pathWithinTestDataRoot repoRoot path =
  ".." `notElem` splitDirectories path
    && let normalized =
             normalise
               ( if isAbsolute path
                   then path
                   else repoRoot </> path
               )
           normalizedRoot = normalise (repoRoot </> testDataRootRelative)
        in normalized == normalizedRoot || (normalizedRoot ++ "/") `isPrefixOf` normalized

pathWithinBuildRoot :: FilePath -> FilePath -> Bool
pathWithinBuildRoot repoRoot path =
  ".." `notElem` splitDirectories path
    && let normalized =
             normalise
               ( if isAbsolute path
                   then path
                   else repoRoot </> path
               )
           normalizedRoot = normalise (repoRoot </> ".build")
        in normalized == normalizedRoot || (normalizedRoot ++ "/") `isPrefixOf` normalized

runPlannedTests :: FilePath -> [(String, String)] -> TestExecutionPlan -> IO ExitCode
runPlannedTests repoRoot environment plan =
  case testPlanExecutionMode plan of
    DelegatedSuite _ ->
      runHaskellSuites repoRoot environment (testPlanHaskellSuites plan)
    NativeSuite suitePlan -> do
      prepareExit <- ensureCanonicalOperatorBinary repoRoot environment
      case prepareExit of
        ExitSuccess ->
          runNativeSuite repoRoot environment (testPlanHaskellSuites plan) suitePlan
        failure@(ExitFailure _) -> pure failure

runLintFirst :: FilePath -> [(String, String)] -> IO ExitCode
runLintFirst repoRoot environment = do
  lintExit <- runCheckCode repoRoot
  case lintExit of
    ExitSuccess ->
      runCommandForExitCode
        Subprocess
          { subprocessPath = "cabal"
          , subprocessArguments = ["build", "--builddir=.build", "all"]
          , subprocessEnvironment = Just environment
          , subprocessWorkingDirectory = Just repoRoot
          }
    failure@(ExitFailure _) -> pure failure

runHaskellSuites :: FilePath -> [(String, String)] -> [String] -> IO ExitCode
runHaskellSuites repoRoot environment suites = do
  unless (null suites) (writeOutputLine "Running Haskell test suites")
  foldM runSuite ExitSuccess suites
 where
  runSuite :: ExitCode -> String -> IO ExitCode
  runSuite failure@(ExitFailure _) _ = pure failure
  runSuite ExitSuccess suiteName =
    runCommandForExitCode
      Subprocess
        { subprocessPath = "cabal"
        , subprocessArguments =
            [ "test"
            , "--builddir=.build"
            , suiteName
            , "--test-show-details=direct"
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just repoRoot
        }

runNativeSuite :: FilePath -> [(String, String)] -> [String] -> NativeSuitePlan -> IO ExitCode
runNativeSuite repoRoot environment haskellSuites suitePlan = do
  bannerExit <- emitLineAction (phaseOneMessage suitePlan)
  case bannerExit of
    failure@(ExitFailure _) -> pure failure
    ExitSuccess ->
      case nativeManagedAwsHarnessPolicyTier suitePlan of
        Nothing -> runNativeSuiteBody repoRoot environment haskellSuites suitePlan
        Just policyTier -> do
          -- Sprint 5.10: regenerate the binary-sibling `prodbox.dhall` from
          -- `test-secrets.dhall` + baked defaults (through the shared
          -- `configFromSetupInput` builder) BEFORE anything reads or validates
          -- the bootstrap config, so a freshly-generated skeleton runs `test all`
          -- without an interactive `config setup`. Idempotent / refuses to
          -- clobber a populated real config.
          regenExit <- runConfigRegenFromTestSecrets repoRoot policyTier
          case regenExit of
            failure@(ExitFailure _) -> pure failure
            ExitSuccess -> do
              -- Sprint 7.24 (ordering): the harness setup materializes operational
              -- `aws.*` + the ACME EAB INTO Vault, which only exists once a cluster
              -- reconcile has brought it up. For cluster-bootstrapping suites, run a
              -- bare `cluster reconcile` FIRST (Vault up; the gateway/edge chart is
              -- skipped cleanly while `aws.*` is unmaterialized) so the harness Vault
              -- write succeeds; the body's later `--with-edge` reconcile then has a
              -- materialized `aws.*`. Pure harness-only suites (e.g. `aws-iam`) do
              -- not bootstrap a cluster and are excluded — no extra pre-reconcile.
              preReconcileExit <-
                if harnessNeedsVaultBeforeSetup suitePlan
                  then runNativeCliCommandForExitCode repoRoot environment ["cluster", "reconcile"]
                  else pure ExitSuccess
              case preReconcileExit of
                failure@(ExitFailure _) -> pure failure
                ExitSuccess -> do
                  -- Sprint 5.10 follow-up: with Vault now unsealed by the
                  -- pre-reconcile, force the in-force config SSoT to match the
                  -- regenerated binary-sibling config so the body's `--with-edge`
                  -- reconcile (which reads the in-force SSoT) sees the populated
                  -- `route53.zone_id`. Fixes a cluster established before the
                  -- operator fields were populated (stale SSoT).
                  syncExit <- runForceSyncInForceConfig repoRoot
                  case syncExit of
                    failure@(ExitFailure _) -> pure failure
                    ExitSuccess -> do
                      setupExit <- runManagedAwsHarnessSetup repoRoot policyTier
                      case setupExit of
                        failure@(ExitFailure _) -> pure failure
                        ExitSuccess ->
                          runWithAwsHarnessCleanup
                            repoRoot
                            environment
                            suitePlan
                            (runNativeSuiteBody repoRoot environment haskellSuites suitePlan)

-- | Sprint 7.6 orphan-safety: run the suite body, then destroy every
-- per-run Pulumi stack the suite may have provisioned before clearing
-- operational @aws.*@ via the harness teardown. The destroys run on
-- success, failure, and async exception (Ctrl-C) alike, so no
-- `prodbox test all` exit path can strand
-- @aws-eks@ / @aws-eks-subzone@ / @aws-test@ resources in AWS. The
-- @aws-ses@ stack is explicitly excluded per the long-lived
-- cross-substrate shared-infrastructure class in
-- @DEVELOPMENT_PLAN/substrates.md@ § Resource Lifecycle Classes.
--
-- Sprint 7.10 credential-preservation: the per-run destroys still run
-- on every exit path, but the *operational-credential teardown*
-- ('runManagedAwsHarnessTeardown', which clears @aws.*@ + deletes the
-- operational @prodbox@ IAM user) now runs **only when the per-run
-- destroy succeeded** ('clearOperationalCredsAfterPostflight'). When a
-- per-run @pulumi <stack>-destroy@ fails (e.g. the May 28/29
-- @DependencyViolation@ on subnet deletion from lagging orphan ENIs),
-- the orphaned per-run stacks still exist in AWS and need operational
-- creds to be destroyed on retry. Tearing the creds down here would
-- strand those orphans without the credentials required to delete them,
-- so the teardown is held and a diagnostic explains the recovery path.
-- This is the per-run analog of Sprint 7.9 (which made the teardown not
-- gate on admin-managed @aws-ses@): 7.9 said "don't block teardown on
-- aws-ses"; 7.10 says "DO hold the teardown when the per-run
-- auto-destroy — which needs operational creds — failed."
runWithAwsHarnessCleanup
  :: FilePath
  -> [(String, String)]
  -> NativeSuitePlan
  -> IO ExitCode
  -> IO ExitCode
runWithAwsHarnessCleanup repoRoot environment suitePlan body = do
  result <- try body :: IO (Either SomeException ExitCode)
  destroyExit <- runSequentially (awsPostflightDestroyActions repoRoot environment suitePlan)
  cleanupExit <- runConditionalHarnessTeardown destroyExit
  case result of
    Left exc -> do
      writeDiagnosticLine
        ("AWS harness cleanup ran after async exception: " ++ show exc)
      _ <- writeReason destroyExit cleanupExit
      throwIO exc
    Right suiteExit ->
      pure
        ( preferEarlierFailure
            suiteExit
            (preferEarlierFailure destroyExit cleanupExit)
        )
 where
  -- Sprint 7.10: clear operational @aws.*@ + delete the operational
  -- @prodbox@ user only when the per-run destroy succeeded. On a
  -- per-run destroy failure, preserve the operational credentials so the
  -- orphaned per-run resources can be destroyed on retry, and explain the
  -- recovery path.
  runConditionalHarnessTeardown :: ExitCode -> IO ExitCode
  runConditionalHarnessTeardown destroyExit
    | clearOperationalCredsAfterPostflight destroyExit =
        runManagedAwsHarnessTeardown repoRoot
    | otherwise = do
        writeDiagnosticLine
          ( "Per-run AWS postflight cleanup failed ("
              ++ show destroyExit
              ++ "); the per-run AWS stacks (aws-eks, aws-eks-subzone, "
              ++ "aws-test) or test-scoped EBS volumes may still hold live resources. PRESERVING "
              ++ "operational aws.* and the operational `prodbox` IAM "
              ++ "user so the orphaned per-run resources can be destroyed on "
              ++ "retry. Skipping the operational-credential teardown to "
              ++ "avoid stranding the orphans without the credentials "
              ++ "required to delete them. Recover with: resolve the "
              ++ "destroy failure (e.g. wait out / clean up the orphan "
              ++ "ENIs behind a DependencyViolation), then "
              ++ "`prodbox aws stack <stack> destroy --yes` for each "
              ++ "remaining per-run stack, `prodbox aws ebs reap-test --yes` "
              ++ "for any test-scoped EBS volumes, then `prodbox aws teardown` to "
              ++ "clear the operational credentials."
          )
        -- The per-run destroy failure is already surfaced as the
        -- composed exit code; the held teardown is not itself a failure.
        pure ExitSuccess

  writeReason :: ExitCode -> ExitCode -> IO ()
  writeReason destroyExit cleanupExit =
    case (destroyExit, cleanupExit) of
      (ExitSuccess, ExitSuccess) -> pure ()
      _ ->
        writeDiagnosticLine
          ( "AWS harness cleanup non-zero: destroy="
              ++ show destroyExit
              ++ ", harnessTeardown="
              ++ show cleanupExit
          )

-- | Sprint 7.10 pure decision: should the operational-credential
-- teardown ('runManagedAwsHarnessTeardown') run after the per-run
-- AWS per-run cleanup postflight?
--
-- Returns 'True' iff the per-run cleanup succeeded ('ExitSuccess'). On
-- any 'ExitFailure' the orphaned per-run resources may still hold live AWS
-- resources that require operational creds to destroy on retry, so the
-- teardown is held and the operational @aws.*@ + @prodbox@ IAM user are
-- preserved. Extracted as a pure helper so the decision matrix is
-- unit-testable without harness IO.
clearOperationalCredsAfterPostflight :: ExitCode -> Bool
clearOperationalCredsAfterPostflight destroyExit =
  case destroyExit of
    ExitSuccess -> True
    ExitFailure _ -> False

awsPostflightDestroyActions
  :: FilePath -> [(String, String)] -> NativeSuitePlan -> [IO ExitCode]
awsPostflightDestroyActions repoRoot environment suitePlan =
  case awsPostflightDestroyCommandArgs suitePlan of
    [] -> []
    commands ->
      emitLineAction
        ( "Auto-destroying per-run AWS Pulumi stacks (aws-eks, "
            ++ "aws-eks-subzone, aws-test). aws-ses is retained per the "
            ++ "long-lived cross-substrate shared-infrastructure class."
        )
        -- The `lifecycle` validation tears the cluster down and reconciles it,
        -- which brings up a fresh Vault that auto-unseals from the durable unlock
        -- bundle — but under host memory pressure that unseal can lose the race,
        -- leaving Vault sealed. Every per-run destroy needs Vault (Pulumi backend
        -- in MinIO + AWS deployment credentials), so an idempotent `vault unseal`
        -- here (no-op when already unsealed) closes the teardown→destroy race; if
        -- the cluster is genuinely down it fails and the destroys are skipped,
        -- preserving the operational credentials for manual recovery as before.
        : runNativeCliCommandForExitCode repoRoot environment ["vault", "unseal"]
        : map (runNativeCliCommandForExitCode repoRoot environment) commands
        ++ [runNativeCliCommandForExitCode repoRoot environment ["aws", "ebs", "reap-test", "--yes"]]

awsPostflightDestroyCommandArgs :: NativeSuitePlan -> [[String]]
awsPostflightDestroyCommandArgs suitePlan =
  if nativeMayProvisionPerRunAwsStacks suitePlan
    then
      [ ["aws", "stack", "aws-subzone", "destroy", "--yes"]
      , ["aws", "stack", "eks", "destroy", "--yes"]
      , ["aws", "stack", "test", "destroy", "--yes"]
      ]
    else []

nativeMayProvisionPerRunAwsStacks :: NativeSuitePlan -> Bool
nativeMayProvisionPerRunAwsStacks suitePlan =
  nativeRequiresSupportedRuntimePostflight suitePlan
    || (nativeSubstrate suitePlan == SubstrateAws && nativeRequiresSupportedRuntimeBootstrap suitePlan)
    || any validationMayProvisionPerRunAwsStacks (nativeValidations suitePlan)

validationMayProvisionPerRunAwsStacks :: NativeValidation -> Bool
validationMayProvisionPerRunAwsStacks validation =
  case validation of
    ValidationAwsEks -> True
    ValidationPulumi -> True
    ValidationHaRke2Aws -> True
    ValidationEksVolumeRebind -> True
    _ -> False

runNativeSuiteBody :: FilePath -> [(String, String)] -> [String] -> NativeSuitePlan -> IO ExitCode
runNativeSuiteBody repoRoot environment haskellSuites suitePlan = do
  initialPrerequisitesExit <- runPhaseOneInitialPrerequisites repoRoot suitePlan
  case initialPrerequisitesExit of
    failure@(ExitFailure _) -> pure failure
    ExitSuccess -> do
      recorderResult <- prepareGatewayRuntimeStabilityRecorder repoRoot suitePlan
      case recorderResult of
        Left err -> failWith err
        Right maybeGatewayStability -> do
          runbookExit <-
            runSequentially (runbookActions repoRoot environment suitePlan)
          case runbookExit of
            failure@(ExitFailure _) -> pure failure
            ExitSuccess -> do
              baselineExit <-
                recordGatewayRuntimeStabilityIfPresent
                  repoRoot
                  suitePlan
                  maybeGatewayStability
              case baselineExit of
                failure@(ExitFailure _) -> pure failure
                ExitSuccess ->
                  runSuiteWithGatewayRuntimeMonitor
                    repoRoot
                    environment
                    haskellSuites
                    suitePlan
                    maybeGatewayStability

runSuiteWithGatewayRuntimeMonitor
  :: FilePath
  -> [(String, String)]
  -> [String]
  -> NativeSuitePlan
  -> Maybe GatewayRuntimeStabilityRecorder
  -> IO ExitCode
runSuiteWithGatewayRuntimeMonitor repoRoot environment haskellSuites suitePlan maybeRecorder =
  case (nativeSubstrate suitePlan, maybeRecorder) of
    (SubstrateHomeLocal, Just recorder) ->
      withGatewayRuntimeMonitorExit repoRoot suitePlan recorder $ \monitor ->
        runBootstrapAndRemaining (Just recorder) (Just monitor)
    -- The monitor-private EKS kubeconfig cannot be materialized until the AWS
    -- bootstrap has created the target.  Its compiled gateway reconcile takes
    -- the first point sample; the continuous observer starts immediately
    -- afterward and spans every deferred prerequisite, validation, and
    -- postflight action.
    (SubstrateAws, Just recorder) -> do
      bootstrapExit <- runBootstrap (Just recorder) Nothing
      case bootstrapExit of
        failure@(ExitFailure _) -> pure failure
        ExitSuccess ->
          withGatewayRuntimeMonitorExit repoRoot suitePlan recorder $ \monitor ->
            runAwsPostGatewayBootstrapAndRemaining recorder monitor
    (_, Nothing) -> runBootstrapAndRemaining Nothing Nothing
 where
  runBootstrap maybeStability maybeMonitor =
    runSequentially
      ( supportedRuntimeBootstrapActions
          repoRoot
          environment
          suitePlan
          maybeStability
          maybeMonitor
      )

  runBootstrapAndRemaining maybeStability maybeMonitor = do
    bootstrapExit <- runBootstrap maybeStability maybeMonitor
    case bootstrapExit of
      failure@(ExitFailure _) -> pure failure
      ExitSuccess -> runRemaining maybeStability maybeMonitor

  runAwsPostGatewayBootstrapAndRemaining recorder monitor = do
    postGatewayBootstrapExit <-
      runAwsSubstratePostGatewayBootstrap repoRoot environment suitePlan
    case postGatewayBootstrapExit of
      failure@(ExitFailure _) -> pure failure
      ExitSuccess -> runRemaining (Just recorder) (Just monitor)

  runRemaining maybeStability maybeMonitor = do
    deferredPrerequisitesExit <-
      runPhaseOneDeferredPrerequisites repoRoot suitePlan
    case deferredPrerequisitesExit of
      failure@(ExitFailure _) -> pure failure
      ExitSuccess ->
        runPhaseTwo
          repoRoot
          environment
          haskellSuites
          suitePlan
          maybeStability
          maybeMonitor

withGatewayRuntimeMonitorExit
  :: FilePath
  -> NativeSuitePlan
  -> GatewayRuntimeStabilityRecorder
  -> (GatewayRuntimeStabilityMonitor -> IO ExitCode)
  -> IO ExitCode
withGatewayRuntimeMonitorExit repoRoot suitePlan recorder action = do
  result <-
    withGatewayRuntimeStabilityMonitor
      (nativeSubstrate suitePlan)
      repoRoot
      recorder
      action
  case result of
    Left err -> failWith ("start gateway runtime-stability monitor: " ++ err)
    Right exitCode -> pure exitCode

prepareGatewayRuntimeStabilityRecorder
  :: FilePath
  -> NativeSuitePlan
  -> IO (Either String (Maybe GatewayRuntimeStabilityRecorder))
prepareGatewayRuntimeStabilityRecorder repoRoot suitePlan =
  if ValidationGatewayPods `elem` nativeValidations suitePlan
    then fmap (fmap Just) (newGatewayRuntimeStabilityRecorder repoRoot)
    else pure (Right Nothing)

recordGatewayRuntimeStabilityIfPresent
  :: FilePath
  -> NativeSuitePlan
  -> Maybe GatewayRuntimeStabilityRecorder
  -> IO ExitCode
recordGatewayRuntimeStabilityIfPresent _ _ Nothing = pure ExitSuccess
recordGatewayRuntimeStabilityIfPresent repoRoot suitePlan (Just recorder) =
  case nativeSubstrate suitePlan of
    SubstrateHomeLocal ->
      recordGatewayRuntimeStabilitySample
        SubstrateHomeLocal
        repoRoot
        recorder
    -- The per-run EKS target does not exist until the AWS bootstrap below;
    -- its first authoritative sample is taken after the compiled gateway
    -- reconcile step in that target plan.
    SubstrateAws -> pure ExitSuccess

runPhaseTwo
  :: FilePath
  -> [(String, String)]
  -> [String]
  -> NativeSuitePlan
  -> Maybe GatewayRuntimeStabilityRecorder
  -> Maybe GatewayRuntimeStabilityMonitor
  -> IO ExitCode
runPhaseTwo repoRoot environment haskellSuites suitePlan maybeGatewayStability maybeGatewayMonitor = do
  phaseTwoExit <- emitLineAction phaseTwoMessage
  case phaseTwoExit of
    failure@(ExitFailure _) -> pure failure
    ExitSuccess -> do
      haskellExit <- runHaskellSuites repoRoot environment haskellSuites
      case haskellExit of
        failure@(ExitFailure _) -> pure failure
        ExitSuccess -> do
          validationsExit <-
            runNativeValidations
              repoRoot
              environment
              suitePlan
              maybeGatewayStability
              maybeGatewayMonitor
          case validationsExit of
            failure@(ExitFailure _) -> pure failure
            ExitSuccess -> do
              postflightExit <-
                runSequentially
                  ( supportedRuntimePostflightActions
                      repoRoot
                      environment
                      suitePlan
                      maybeGatewayStability
                      maybeGatewayMonitor
                  )
              case postflightExit of
                failure@(ExitFailure _) -> pure failure
                ExitSuccess ->
                  runFinalGatewayRuntimeStabilityGate
                    repoRoot
                    suitePlan
                    maybeGatewayStability

runFinalGatewayRuntimeStabilityGate
  :: FilePath
  -> NativeSuitePlan
  -> Maybe GatewayRuntimeStabilityRecorder
  -> IO ExitCode
runFinalGatewayRuntimeStabilityGate _ _ Nothing = pure ExitSuccess
runFinalGatewayRuntimeStabilityGate repoRoot suitePlan (Just recorder)
  | nativeRequiresSupportedRuntimePostflight suitePlan =
      runGatewayRuntimeStabilityGate
        (nativeSubstrate suitePlan)
        repoRoot
        recorder
  | otherwise = pure ExitSuccess

runSequentially :: [IO ExitCode] -> IO ExitCode
runSequentially = foldM step ExitSuccess
 where
  step :: ExitCode -> IO ExitCode -> IO ExitCode
  step failure@(ExitFailure _) _ = pure failure
  step ExitSuccess action = action

emitLineAction :: String -> IO ExitCode
emitLineAction message = writeOutputLine message >> pure ExitSuccess

runbookActions :: FilePath -> [(String, String)] -> NativeSuitePlan -> [IO ExitCode]
runbookActions repoRoot environment suitePlan =
  case integrationRunbookCommandArgs suitePlan of
    [] -> []
    commands ->
      emitLineAction phaseOnePointFiveMessage
        : map (runNativeCliCommandForExitCode repoRoot environment) commands

integrationRunbookCommandArgs :: NativeSuitePlan -> [[String]]
integrationRunbookCommandArgs suitePlan
  | not (nativeRequiresIntegrationRunbook suitePlan) = []
  | nativeValidations suitePlan == [ValidationSealedVault] = [["cluster", "reconcile"]]
  | nativeValidations suitePlan == [ValidationPulsarBroker] = [["cluster", "reconcile"]]
  | otherwise = [["cluster", "reconcile", "--with-edge"]]

supportedRuntimeBootstrapActions
  :: FilePath
  -> [(String, String)]
  -> NativeSuitePlan
  -> Maybe GatewayRuntimeStabilityRecorder
  -> Maybe GatewayRuntimeStabilityMonitor
  -> [IO ExitCode]
supportedRuntimeBootstrapActions repoRoot environment suitePlan maybeGatewayStability maybeGatewayMonitor =
  if nativeRequiresSupportedRuntimeBootstrap suitePlan
    then
      let reconcileActions =
            if supportedRuntimeBootstrapNeedsReconcile suitePlan
              then
                plannedHomeGatewayReconcileActions
                  repoRoot
                  environment
                  suitePlan
                  maybeGatewayStability
                  maybeGatewayMonitor
              else []
       in [emitLineAction phaseOnePointSixMessage]
            ++ reconcileActions
            ++ restoreCycleActions
              repoRoot
              environment
              (supportedRuntimeBootstrapRestorePlan suitePlan)
              (nativeSubstrate suitePlan)
              maybeGatewayStability
              maybeGatewayMonitor
            ++ awsSubstrateBootstrapActions
              repoRoot
              environment
              suitePlan
              maybeGatewayStability
    else []

supportedRuntimeBootstrapNeedsReconcile :: NativeSuitePlan -> Bool
supportedRuntimeBootstrapNeedsReconcile suitePlan =
  nativeRequiresSupportedRuntimeBootstrap suitePlan
    && not (nativeRequiresIntegrationRunbook suitePlan)

-- | Sprint 7.24 (ordering): a cluster-bootstrapping harness suite needs Vault
-- up BEFORE the harness setup runs, because the setup materializes operational
-- `aws.*` + the ACME EAB into Vault. A bare `cluster reconcile` brings Vault up
-- (and skips the gateway/edge chart cleanly while `aws.*` is unmaterialized), so
-- the harness write succeeds. Pure harness-only suites (e.g. `aws-iam`) do not
-- bootstrap a cluster and are excluded, so no extra pre-reconcile is added to
-- them.
harnessNeedsVaultBeforeSetup :: NativeSuitePlan -> Bool
harnessNeedsVaultBeforeSetup = nativeRequiresSupportedRuntimeBootstrap

supportedRuntimeBootstrapRestorePlan :: NativeSuitePlan -> RestoreCyclePlan
supportedRuntimeBootstrapRestorePlan suitePlan =
  buildRestoreCyclePlan SubstrateHomeLocal retainedSesRequirement
 where
  retainedSesRequirement =
    case nativeSubstrate suitePlan of
      SubstrateHomeLocal ->
        retainedSesRequirementForValidations (nativeValidations suitePlan)
      -- The home bootstrap remains the retained control-plane authority for
      -- an AWS suite, but its workload secret target is EKS.  Project the one
      -- capability-derived preparation fragment into the AWS restore below.
      SubstrateAws -> SesNotRequired

supportedRuntimePostflightRestorePlan :: NativeSuitePlan -> RestoreCyclePlan
supportedRuntimePostflightRestorePlan _ =
  buildRestoreCyclePlan SubstrateHomeLocal SesNotRequired

restoreCycleActions
  :: FilePath
  -> [(String, String)]
  -> RestoreCyclePlan
  -> Substrate
  -> Maybe GatewayRuntimeStabilityRecorder
  -> Maybe GatewayRuntimeStabilityMonitor
  -> [IO ExitCode]
restoreCycleActions repoRoot environment restorePlan observedSubstrate maybeGatewayStability maybeGatewayMonitor =
  [ runDerivedRestoreGraph
      repoRoot
      environment
      restorePlan
      observedSubstrate
      maybeGatewayStability
      maybeGatewayMonitor
  ]

-- | Sprint 5.20: drive the restore cycle from the derived 'RestoreGraph' total
-- executor instead of a fail-fast fold over the flat step list. Every node whose
-- dependencies are satisfiable runs; a node whose @RequiresSuccess@ dependency
-- failed is recorded as blocked rather than silently discarding every later step.
-- The @F-RESTORE@ fix is structural: each app-chart restoration @RequiresSuccess@
-- only the gateway restoration (never the retained-SES node), so a retained-SES
-- failure can no longer take an independent chart down with it. The whole cycle
-- is one action so that the surrounding suite fold still fails fast AFTER a failed
-- restore, while the restore INTERNALLY runs to completion and reports the
-- aggregate. The per-node dispatch reuses 'restoreCycleStepActionWithGatewayStability'
-- verbatim, preserving the runtime-stability recorder bracketing around the
-- gateway delete/reconcile nodes.
runDerivedRestoreGraph
  :: FilePath
  -> [(String, String)]
  -> RestoreCyclePlan
  -> Substrate
  -> Maybe GatewayRuntimeStabilityRecorder
  -> Maybe GatewayRuntimeStabilityMonitor
  -> IO ExitCode
runDerivedRestoreGraph repoRoot environment restorePlan observedSubstrate maybeGatewayStability maybeGatewayMonitor = do
  report <- runRestoreGraphWith runNode graph
  projectRestoreReport report
 where
  graph = buildRestoreGraphForPlan restorePlan
  runNode nodeId =
    case find ((== nodeId) . restoreCycleStepNodeId) (restoreCycleSteps restorePlan) of
      -- Coverage is a proven bijection (RestoreGraphSuite: the plan's step
      -- node-ids equal the graph's node ids), so a miss is a construction bug,
      -- surfaced as an explicit failure rather than a silently skipped node.
      Nothing -> pure (Left (ExitFailure 3))
      Just restoreStep -> do
        code <-
          restoreCycleStepActionWithGatewayStability
            repoRoot
            environment
            (restoreCycleSubstrate restorePlan)
            observedSubstrate
            maybeGatewayStability
            maybeGatewayMonitor
            restoreStep
        pure $ case code of
          ExitSuccess -> Right ()
          failure@(ExitFailure _) -> Left failure

-- | Project the aggregate 'RestoreReport' into one suite exit code. On any
-- failed or blocked node, the full per-node outcome table is written so the
-- aggregate failure (primary failure plus every independent node that still ran)
-- is visible, and the first node failure's exit code is returned.
projectRestoreReport :: RestoreReport ExitCode -> IO ExitCode
projectRestoreReport report
  | null (restoreReportFailed report) && null (restoreReportBlocked report) =
      pure ExitSuccess
  | otherwise = do
      writeOutputLine (renderRestoreReportSummary report)
      pure (aggregateRestoreExit report)

renderRestoreReportSummary :: RestoreReport ExitCode -> String
renderRestoreReportSummary report =
  unlines
    ( "Restore graph aggregate report (total executor; no step silently discarded):"
        : [ "  " ++ show (restoreResultNode result) ++ " -> " ++ describe (restoreResultOutcome result)
          | result <- restoreReportResults report
          ]
    )
 where
  describe NodeSucceeded = "succeeded"
  describe (NodeFailed code) = "FAILED (" ++ show code ++ ")"
  describe (NodeBlocked blockers) = "BLOCKED by " ++ show blockers

aggregateRestoreExit :: RestoreReport ExitCode -> ExitCode
aggregateRestoreExit report =
  case [code | result <- restoreReportResults report, NodeFailed code <- [restoreResultOutcome result]] of
    (code : _) -> code
    [] -> if null (restoreReportBlocked report) then ExitSuccess else ExitFailure 1

restoreCycleStepActionWithGatewayStability
  :: FilePath
  -> [(String, String)]
  -> Substrate
  -> Substrate
  -> Maybe GatewayRuntimeStabilityRecorder
  -> Maybe GatewayRuntimeStabilityMonitor
  -> RestoreCycleStep
  -> IO ExitCode
restoreCycleStepActionWithGatewayStability repoRoot environment restoreSubstrate observedSubstrate maybeRecorder maybeMonitor restoreStep
  | restoreSubstrate /= observedSubstrate
      || not (restoreStepResetsGatewayHealthyWindow restoreStep) =
      restoreCycleStepAction repoRoot environment restoreSubstrate restoreStep
  | otherwise =
      case (maybeRecorder, restoreStep) of
        (Just recorder, RestoreDeleteChart RestoreChartGateway) ->
          runSequentially
            [ pauseGatewayRuntimeMonitorIfPresent maybeMonitor
            , recordGatewayRuntimeStabilitySample observedSubstrate repoRoot recorder
            , resetGatewayRuntimeStabilityHealthyWindow recorder >> pure ExitSuccess
            , restoreCycleStepAction repoRoot environment restoreSubstrate restoreStep
            ]
        (Just recorder, RestoreReconcileChart RestoreChartGateway) ->
          runSequentially
            [ resetGatewayRuntimeStabilityHealthyWindow recorder >> pure ExitSuccess
            , restoreCycleStepAction repoRoot environment restoreSubstrate restoreStep
            , recordGatewayRuntimeStabilitySample observedSubstrate repoRoot recorder
            , resumeGatewayRuntimeMonitorIfPresent maybeMonitor
            ]
        _ -> restoreCycleStepAction repoRoot environment restoreSubstrate restoreStep

pauseGatewayRuntimeMonitorIfPresent
  :: Maybe GatewayRuntimeStabilityMonitor -> IO ExitCode
pauseGatewayRuntimeMonitorIfPresent Nothing = pure ExitSuccess
pauseGatewayRuntimeMonitorIfPresent (Just monitor) =
  pauseGatewayRuntimeStabilityMonitor monitor >> pure ExitSuccess

resumeGatewayRuntimeMonitorIfPresent
  :: Maybe GatewayRuntimeStabilityMonitor -> IO ExitCode
resumeGatewayRuntimeMonitorIfPresent Nothing = pure ExitSuccess
resumeGatewayRuntimeMonitorIfPresent (Just monitor) =
  resumeGatewayRuntimeStabilityMonitor monitor >> pure ExitSuccess

refreshGatewayRuntimeMonitorIfPresent
  :: Maybe GatewayRuntimeStabilityMonitor -> IO ExitCode
refreshGatewayRuntimeMonitorIfPresent Nothing = pure ExitSuccess
refreshGatewayRuntimeMonitorIfPresent (Just monitor) =
  refreshGatewayRuntimeStabilityMonitor monitor >> pure ExitSuccess

plannedHomeGatewayReconcileActions
  :: FilePath
  -> [(String, String)]
  -> NativeSuitePlan
  -> Maybe GatewayRuntimeStabilityRecorder
  -> Maybe GatewayRuntimeStabilityMonitor
  -> [IO ExitCode]
plannedHomeGatewayReconcileActions repoRoot environment suitePlan maybeRecorder maybeMonitor =
  case (nativeSubstrate suitePlan, maybeRecorder) of
    (SubstrateHomeLocal, Just recorder) ->
      [ pauseGatewayRuntimeMonitorIfPresent maybeMonitor
      , recordGatewayRuntimeStabilitySample SubstrateHomeLocal repoRoot recorder
      , resetGatewayRuntimeStabilityHealthyWindow recorder >> pure ExitSuccess
      , reconcile
      , recordGatewayRuntimeStabilitySample SubstrateHomeLocal repoRoot recorder
      , resumeGatewayRuntimeMonitorIfPresent maybeMonitor
      ]
    _ -> [reconcile]
 where
  reconcile =
    runNativeCliCommandForExitCode
      repoRoot
      environment
      ["cluster", "reconcile", "--with-edge"]

restoreCycleStepAction
  :: FilePath -> [(String, String)] -> Substrate -> RestoreCycleStep -> IO ExitCode
restoreCycleStepAction repoRoot environment substrate restoreStep =
  case restoreStep of
    RestoreDeleteChart chart ->
      runNativeCliCommandForExitCode
        repoRoot
        environment
        (restoreChartCommandArgs substrate "delete" chart ["--yes"])
    RestoreEnsureGatewayMinioBootstrap -> ensureGatewayMinioBootstrap repoRoot
    RestoreReconcileChart chart ->
      runNativeCliCommandForExitCode
        repoRoot
        environment
        (restoreChartCommandArgs substrate "reconcile" chart [])
    RestorePrepareRetainedSes preparationPlan ->
      prepareRetainedSesForSubstrate
        repoRoot
        environment
        substrate
        preparationPlan
    RestoreWaitForPublicEdge ->
      runWaitForPublicEdgeReady
        repoRoot
        environment
        substrate
        publicEdgeReadyAttempts
        publicEdgeReadyDelayMicroseconds

restoreChartCommandArgs :: Substrate -> String -> RestoreChart -> [String] -> [String]
restoreChartCommandArgs substrate commandName chart trailingArguments =
  ["charts", commandName, restoreChartId chart]
    ++ trailingArguments
    ++ case substrate of
      SubstrateHomeLocal -> []
      SubstrateAws -> ["--substrate", substrateId substrate]

-- | AWS-substrate-specific bootstrap: provision the per-run AWS Pulumi
-- stacks and deploy the AWS chart set so substrate-aware validations
-- (@charts-vscode --substrate aws@, @public-edge --substrate aws@, the
-- cert-manager DNS01 ACME @ClusterIssuer@) can reach EKS, read the Route
-- 53 subzone's hosted-zone ID, and talk to the validation EC2 nodes. The
-- substrate-platform install in
-- 'Prodbox.Lib.AwsSubstratePlatform.ensureAwsSubstratePlatformRuntime'
-- documents the Pulumi stacks as preconditions; the test harness owns the
-- provisioning per [CLAUDE.md "AWS Substrate Provisioning
-- Ownership"](../../CLAUDE.md). Idempotent: every @prodbox aws stack
-- <stack> reconcile@ entrypoint uses Pulumi's standard @up@ semantics, and
-- every chart reconcile uses Helm's upgrade/install path.
--
-- The canonical validation order (@canonicalNativeValidations@ in
-- 'Prodbox.TestPlan') puts @charts-vscode@ first and @aws-eks@ /
-- @ha-rke2-aws@ much later. On the home substrate that ordering is fine
-- because @charts-vscode@ runs against the local cluster brought up by
-- 'supportedRuntimeBootstrapActions'. On the AWS substrate
-- @charts-vscode@ needs EKS already provisioned, so we provision aws-eks
-- (and aws-test for the HA-RKE2 validation) here in the bootstrap rather
-- than waiting for the validation-driven path.
awsSubstrateBootstrapActions
  :: FilePath
  -> [(String, String)]
  -> NativeSuitePlan
  -> Maybe GatewayRuntimeStabilityRecorder
  -> [IO ExitCode]
awsSubstrateBootstrapActions repoRoot environment suitePlan maybeGatewayStability =
  case nativeSubstrate suitePlan of
    SubstrateHomeLocal -> []
    SubstrateAws ->
      [ runAwsSubstrateBootstrap
          repoRoot
          environment
          suitePlan
          maybeGatewayStability
      ]

runAwsSubstrateBootstrap
  :: FilePath
  -> [(String, String)]
  -> NativeSuitePlan
  -> Maybe GatewayRuntimeStabilityRecorder
  -> IO ExitCode
runAwsSubstrateBootstrap repoRoot environment suitePlan maybeGatewayStability =
  case awsSubstrateStackCommandArgs suitePlan of
    [] -> pure ExitSuccess
    subzoneCommand : remainingStackCommands -> do
      subzoneExit <- runNativeCliCommandForExitCode repoRoot environment subzoneCommand
      case subzoneExit of
        failure@(ExitFailure _) -> pure failure
        ExitSuccess ->
          -- Sprint 7.13: the subzone Pulumi stack is now provisioned, so
          -- every child `prodbox` process resolves
          -- `aws_substrate.hosted_zone_id` from settings or the live
          -- aws-eks-subzone Pulumi output via
          -- `Prodbox.PublicEdge.resolveSubstrateHostedZoneId`. No
          -- `PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID` env var is set or read
          -- (config_doctrine.md § 10, no `PRODBOX_*` config reads).
          runSequentially
            ( map
                (runNativeCliCommandForExitCode repoRoot environment)
                remainingStackCommands
                ++ map
                  ( awsSubstrateBootstrapRestoreStepActionWithGatewayStability
                      repoRoot
                      environment
                      maybeGatewayStability
                  )
                  restoreStepsBeforeMonitor
            )
 where
  restoreStepsBeforeMonitor =
    case maybeGatewayStability of
      Nothing -> awsSubstrateBootstrapRestoreSteps suitePlan
      Just _ -> awsSubstrateBootstrapPreMonitorSteps suitePlan

runAwsSubstratePostGatewayBootstrap
  :: FilePath
  -> [(String, String)]
  -> NativeSuitePlan
  -> IO ExitCode
runAwsSubstratePostGatewayBootstrap repoRoot environment suitePlan =
  case nativeSubstrate suitePlan of
    SubstrateHomeLocal -> pure ExitSuccess
    SubstrateAws ->
      runSequentially
        ( map
            (awsSubstrateBootstrapRestoreStepAction repoRoot environment)
            (awsSubstrateBootstrapPostMonitorSteps suitePlan)
        )

splitAwsSubstrateBootstrapAtGateway
  :: [RestoreCycleStep]
  -> ([RestoreCycleStep], [RestoreCycleStep])
splitAwsSubstrateBootstrapAtGateway = go []
 where
  go before [] = (reverse before, [])
  go before (restoreStep : remaining) =
    case restoreStep of
      RestoreReconcileChart RestoreChartGateway ->
        (reverse (restoreStep : before), remaining)
      _ -> go (restoreStep : before) remaining

awsSubstrateBootstrapPreMonitorSteps :: NativeSuitePlan -> [RestoreCycleStep]
awsSubstrateBootstrapPreMonitorSteps suitePlan =
  fst
    ( splitAwsSubstrateBootstrapAtGateway
        (awsSubstrateBootstrapRestoreSteps suitePlan)
    )

awsSubstrateBootstrapPostMonitorSteps :: NativeSuitePlan -> [RestoreCycleStep]
awsSubstrateBootstrapPostMonitorSteps suitePlan =
  snd
    ( splitAwsSubstrateBootstrapAtGateway
        (awsSubstrateBootstrapRestoreSteps suitePlan)
    )

awsSubstrateBootstrapRestoreStepActionWithGatewayStability
  :: FilePath
  -> [(String, String)]
  -> Maybe GatewayRuntimeStabilityRecorder
  -> RestoreCycleStep
  -> IO ExitCode
awsSubstrateBootstrapRestoreStepActionWithGatewayStability repoRoot environment maybeRecorder restoreStep =
  case (maybeRecorder, restoreStep) of
    (Just recorder, RestoreReconcileChart RestoreChartGateway) ->
      runSequentially
        [ resetGatewayRuntimeStabilityHealthyWindow recorder >> pure ExitSuccess
        , awsSubstrateBootstrapRestoreStepAction repoRoot environment restoreStep
        , recordGatewayRuntimeStabilitySample SubstrateAws repoRoot recorder
        ]
    _ -> awsSubstrateBootstrapRestoreStepAction repoRoot environment restoreStep

awsSubstrateBootstrapRestoreStepAction
  :: FilePath -> [(String, String)] -> RestoreCycleStep -> IO ExitCode
awsSubstrateBootstrapRestoreStepAction repoRoot environment restoreStep =
  case restoreStep of
    RestoreReconcileChart chart ->
      runNativeCliCommandForExitCode
        repoRoot
        environment
        (restoreChartCommandArgs SubstrateAws "reconcile" chart [])
    RestorePrepareRetainedSes preparationPlan ->
      prepareRetainedSesForSubstrate
        repoRoot
        environment
        SubstrateAws
        preparationPlan
    RestoreDeleteChart _ -> unsupportedProjectionStep
    RestoreEnsureGatewayMinioBootstrap -> unsupportedProjectionStep
    RestoreWaitForPublicEdge -> unsupportedProjectionStep
 where
  unsupportedProjectionStep =
    failWith
      ( "AWS substrate bootstrap restore projection admitted unsupported step: "
          ++ show restoreStep
      )

-- | Interpret the one atomic retained-SES marker against the selected
-- workload target.  The long-lived home checkpoint authority and the target
-- secret sink stay distinct typed values all the way into the Phase 4.47
-- fenced transaction; no kube context or gateway environment selects either.
prepareRetainedSesForSubstrate
  :: FilePath
  -> [(String, String)]
  -> Substrate
  -> RetainedSesPreparationPlan
  -> IO ExitCode
prepareRetainedSesForSubstrate repoRoot _environment substrate preparationPlan = do
  authorityResult <- resolveLongLivedCheckpointAuthority repoRoot
  case authorityResult of
    Left err -> failWith err
    Right authority ->
      case substrate of
        SubstrateHomeLocal -> prepareHome authority
        SubstrateAws -> prepareAws authority
 where
  prepareHome authority = do
    let endpoint =
          GatewayClient.hostLoopbackGatewayEndpoint checkpointGatewayNodePort
    if Text.pack (peerRestUrl endpoint)
      /= checkpointAuthorityGatewayEndpoint authority
      then
        failWith
          "Retained SES preparation refused: the canonical home gateway endpoint does not match the retained checkpoint authority."
      else case mkTargetClusterSecretSink
        (checkpointAuthorityClusterId authority)
        (checkpointAuthorityGatewayEndpoint authority)
        "secret"
        "keycloak/smtp" of
        Left err -> failWith (show err)
        Right target ->
          prepareRetainedSesAtTarget
            repoRoot
            endpoint
            preparationPlan
            RetainedSesPreparationInputs
              { retainedSesCheckpointAuthority = authority
              , retainedSesTargetSecretSink = target
              }

  prepareAws authority = do
    settingsResult <- validateAndLoadSettings repoRoot
    case settingsResult of
      Left err -> failWith err
      Right settings -> do
        credentialsResult <-
          resolveAwsCredentialsRefFromHostVault
            repoRoot
            "aws"
            (aws (validatedConfig settings))
        case credentialsResult of
          Left err ->
            failWith ("load operational AWS credentials from Vault: " ++ err)
          Right credentials ->
            withEksKubeconfig repoRoot $ \kubeconfigPath -> do
              baseEnvironment <- awsCliSubprocessEnvironment credentials
              let kubeEnvironment =
                    ("KUBECONFIG", kubeconfigPath)
                      : filter ((/= "KUBECONFIG") . fst) baseEnvironment
                  portForwardSpec =
                    GatewayServicePortForward
                      { gatewayPortForwardNamespace = gatewayNamespace
                      , gatewayPortForwardServiceName = gatewayRestServiceName
                      , gatewayPortForwardRemotePort = gatewayRestServicePort
                      , gatewayPortForwardEnvironment = Just kubeEnvironment
                      , gatewayPortForwardWorkingDirectory = Just repoRoot
                      }
              forwarded <-
                withGatewayServicePortForward
                  portForwardSpec
                  (prepareAwsTarget authority)
              case forwarded of
                Left err -> failWith (renderGatewayPortForwardError err)
                Right exitCode -> pure exitCode

  prepareAwsTarget authority endpoint =
    case mkTargetClusterSecretSink
      (Text.pack awsEksCanonicalClusterName)
      (Text.pack (peerRestUrl endpoint))
      "secret"
      "keycloak/smtp" of
      Left err -> failWith (show err)
      Right target ->
        prepareRetainedSesAtTarget
          repoRoot
          endpoint
          preparationPlan
          RetainedSesPreparationInputs
            { retainedSesCheckpointAuthority = authority
            , retainedSesTargetSecretSink = target
            }

prepareRetainedSesAtTarget
  :: FilePath
  -> PeerEndpoint
  -> RetainedSesPreparationPlan
  -> RetainedSesPreparationInputs
  -> IO ExitCode
prepareRetainedSesAtTarget repoRoot endpoint preparationPlan inputs = do
  writeOutputLine
    "Retained SES preparation: acquire -> reconcile -> await-ready -> sync-target -> release"
  interpretationResult <-
    runRetainedSesPreparationWith
      RetainedSesPreparationInterpreter
        { checkRetainedSesPreparationPrecondition = checkTargetReadiness
        , runRegisteredRetainedSesEnsure = runRegisteredEnsure
        }
      preparationPlan
      inputs
  case interpretationResult of
    Left failure -> pure failure
    Right () -> pure ExitSuccess
 where
  checkTargetReadiness readinessPrecondition _ =
    case readinessPrecondition of
      RetainedSesGatewayObjectStoreReady -> do
        let daemonPrecondition =
              gatewayDaemonLivenessPrecondition
                GatewayClient.daemonRestartBridgeRetryPolicy
                (peerRestUrl endpoint)
                (observeGatewayReadyzOnceAt endpoint)
                (observeGatewayBackendRoundTripOnceAt endpoint)
        preconditionResult <- checkAll [daemonPrecondition]
        case preconditionResult of
          Left failures ->
            Left <$> failWith (renderPreconditionFailures failures)
          Right () -> pure (Right ())

  runRegisteredEnsure plannedPreparation selectedInputs =
    case validateAwsSesPreparationTrace plannedPreparation of
      Left err -> Left <$> failWith err
      Right () ->
        case AwsSesStack.awsSesTargetSelectionForSink
          (retainedSesCheckpointAuthority selectedInputs)
          (retainedSesTargetSecretSink selectedInputs) of
          Left err -> Left <$> failWith err
          Right selection -> do
            ensureExit <-
              AwsSesStack.ensureAwsSesStackResourcesForAuthorityAndTarget
                repoRoot
                (retainedSesCheckpointAuthority selectedInputs)
                selection
            pure $
              case ensureExit of
                ExitSuccess -> Right ()
                failure@(ExitFailure _) -> Left failure

validateAwsSesPreparationTrace
  :: RetainedSesPreparationPlan -> Either String ()
validateAwsSesPreparationTrace preparationPlan =
  if retainedSesPreparationTrace preparationPlan == expectedTrace
    then Right ()
    else
      Left
        ( "Retained SES preparation refused: plan semantic trace drifted from "
            ++ "the registered Phase 4.47 transaction: expected "
            ++ show expectedTrace
            ++ ", observed "
            ++ show (retainedSesPreparationTrace preparationPlan)
        )
 where
  expectedTrace =
    RetainedSesAcquire
      : map awsStageToPreparationStep AwsSesStack.awsSesDesiredPresentStages
      ++ [RetainedSesRelease]

awsStageToPreparationStep
  :: AwsSesStack.AwsSesTransactionStage -> RetainedSesPreparationStep
awsStageToPreparationStep awsStage =
  case awsStage of
    AwsSesStack.AwsSesStageReconcile -> RetainedSesReconcile
    AwsSesStack.AwsSesStageAwaitReady -> RetainedSesAwaitReady
    AwsSesStack.AwsSesStageRepairAndMaterializeSmtp -> RetainedSesSyncTarget

awsSubstrateBootstrapCommandArgs :: NativeSuitePlan -> [[String]]
awsSubstrateBootstrapCommandArgs suitePlan =
  awsSubstrateStackCommandArgs suitePlan
    ++ case nativeSubstrate suitePlan of
      SubstrateHomeLocal -> []
      SubstrateAws ->
        concatMap
          awsSubstrateBootstrapRestoreStepCommandArgs
          (awsSubstrateBootstrapRestoreSteps suitePlan)

awsSubstrateStackCommandArgs :: NativeSuitePlan -> [[String]]
awsSubstrateStackCommandArgs suitePlan =
  case nativeSubstrate suitePlan of
    SubstrateHomeLocal -> []
    SubstrateAws ->
      [ ["aws", "stack", "aws-subzone", "reconcile"]
      , ["aws", "stack", "eks", "reconcile"]
      , ["aws", "stack", "test", "reconcile"]
      ]

-- | The AWS bootstrap consumes the same typed restore-cycle builder as the
-- home bootstrap.  Only the selected invite capability projects retained SES
-- preparation into this target; non-invite AWS suites contain no SES action.
awsSubstrateBootstrapRestorePlan :: NativeSuitePlan -> RestoreCyclePlan
awsSubstrateBootstrapRestorePlan suitePlan =
  buildRestoreCyclePlan SubstrateAws retainedSesRequirement
 where
  retainedSesRequirement =
    case nativeSubstrate suitePlan of
      SubstrateHomeLocal -> SesNotRequired
      SubstrateAws ->
        retainedSesRequirementForValidations (nativeValidations suitePlan)

awsSubstrateBootstrapRestoreSteps :: NativeSuitePlan -> [RestoreCycleStep]
awsSubstrateBootstrapRestoreSteps suitePlan =
  concatMap project (restoreCycleSteps (awsSubstrateBootstrapRestorePlan suitePlan))
 where
  project :: RestoreCycleStep -> [RestoreCycleStep]
  project restoreStep =
    case restoreStep of
      RestoreDeleteChart _ -> []
      RestoreEnsureGatewayMinioBootstrap -> []
      RestoreReconcileChart _ -> [restoreStep]
      RestorePrepareRetainedSes _ -> [restoreStep]
      RestoreWaitForPublicEdge -> []

awsSubstrateBootstrapRestoreStepCommandArgs :: RestoreCycleStep -> [[String]]
awsSubstrateBootstrapRestoreStepCommandArgs restoreStep =
  case restoreStep of
    RestoreReconcileChart chart ->
      [restoreChartCommandArgs SubstrateAws "reconcile" chart []]
    RestorePrepareRetainedSes _ -> []
    RestoreDeleteChart _ -> []
    RestoreEnsureGatewayMinioBootstrap -> []
    RestoreWaitForPublicEdge -> []

-- | Post-success suite restore actions: reconcile the local cluster
-- and re-deploy the canonical chart set so the operator's substrate
-- is back to a known-good steady state after destructive tests. AWS
-- per-run-stack destroys are handled separately by
-- 'awsPostflightDestroyActions', which runs on every exit path (Sprint
-- 7.6 orphan-safety guard).
supportedRuntimePostflightActions
  :: FilePath
  -> [(String, String)]
  -> NativeSuitePlan
  -> Maybe GatewayRuntimeStabilityRecorder
  -> Maybe GatewayRuntimeStabilityMonitor
  -> [IO ExitCode]
supportedRuntimePostflightActions repoRoot environment suitePlan maybeGatewayStability maybeGatewayMonitor =
  if nativeRequiresSupportedRuntimePostflight suitePlan
    then
      [emitLineAction postTestRestoreMessage]
        ++ plannedHomeGatewayReconcileActions
          repoRoot
          environment
          suitePlan
          maybeGatewayStability
          maybeGatewayMonitor
        ++ restoreCycleActions
          repoRoot
          environment
          (supportedRuntimePostflightRestorePlan suitePlan)
          (nativeSubstrate suitePlan)
          maybeGatewayStability
          maybeGatewayMonitor
    else []

runNativeValidations
  :: FilePath
  -> [(String, String)]
  -> NativeSuitePlan
  -> Maybe GatewayRuntimeStabilityRecorder
  -> Maybe GatewayRuntimeStabilityMonitor
  -> IO ExitCode
runNativeValidations repoRoot environment suitePlan maybeGatewayStability maybeGatewayMonitor =
  case nativeValidations suitePlan of
    [] -> pure ExitSuccess
    validations -> foldM runValidation ExitSuccess validations
 where
  runValidation :: ExitCode -> NativeValidation -> IO ExitCode
  runValidation failure@(ExitFailure _) _ = pure failure
  runValidation ExitSuccess validation = do
    rolloutBoundaryExit <-
      prepareValidationGatewayRolloutBoundary
        repoRoot
        suitePlan
        maybeGatewayStability
        maybeGatewayMonitor
        validation
    case rolloutBoundaryExit of
      failure@(ExitFailure _) -> pure failure
      ExitSuccess -> do
        validationExit <-
          runNativeValidationWithGatewayStability
            maybeGatewayStability
            (nativeSubstrate suitePlan)
            repoRoot
            environment
            validation
        case validationExit of
          failure@(ExitFailure _) -> pure failure
          ExitSuccess ->
            finishValidationGatewayRolloutBoundary
              repoRoot
              suitePlan
              maybeGatewayStability
              maybeGatewayMonitor
              validation

prepareValidationGatewayRolloutBoundary
  :: FilePath
  -> NativeSuitePlan
  -> Maybe GatewayRuntimeStabilityRecorder
  -> Maybe GatewayRuntimeStabilityMonitor
  -> NativeValidation
  -> IO ExitCode
prepareValidationGatewayRolloutBoundary _ _ Nothing _ _ = pure ExitSuccess
prepareValidationGatewayRolloutBoundary repoRoot suitePlan (Just recorder) maybeMonitor validation =
  case gatewayRuntimeValidationBoundary (nativeSubstrate suitePlan) validation of
    GatewayRuntimeNoBoundary -> pure ExitSuccess
    GatewayRuntimePlannedRollout -> pauseSampleAndReset
    GatewayRuntimeRecreatedTarget -> pauseSampleAndReset
 where
  pauseSampleAndReset =
    runSequentially
      [ pauseGatewayRuntimeMonitorIfPresent maybeMonitor
      , recordGatewayRuntimeStabilitySample
          (nativeSubstrate suitePlan)
          repoRoot
          recorder
      , resetGatewayRuntimeStabilityHealthyWindow recorder >> pure ExitSuccess
      ]

data GatewayRuntimeValidationBoundary
  = GatewayRuntimeNoBoundary
  | GatewayRuntimePlannedRollout
  | GatewayRuntimeRecreatedTarget
  deriving (Eq, Show)

gatewayRuntimeValidationBoundary
  :: Substrate -> NativeValidation -> GatewayRuntimeValidationBoundary
gatewayRuntimeValidationBoundary substrate validation =
  case validation of
    ValidationLifecycle ->
      case substrate of
        SubstrateHomeLocal -> GatewayRuntimePlannedRollout
        SubstrateAws -> GatewayRuntimeNoBoundary
    ValidationEksVolumeRebind -> GatewayRuntimeRecreatedTarget
    ValidationChartsVscode -> GatewayRuntimeNoBoundary
    ValidationChartsApi -> GatewayRuntimeNoBoundary
    ValidationChartsWebsocket -> GatewayRuntimeNoBoundary
    ValidationAdminRoutes -> GatewayRuntimeNoBoundary
    ValidationPublicDns -> GatewayRuntimeNoBoundary
    ValidationDnsAws -> GatewayRuntimeNoBoundary
    ValidationAwsIam -> GatewayRuntimeNoBoundary
    ValidationAwsEks -> GatewayRuntimeNoBoundary
    ValidationPulumi -> GatewayRuntimeNoBoundary
    ValidationHaRke2Aws -> GatewayRuntimeNoBoundary
    ValidationGatewayDaemon -> GatewayRuntimeNoBoundary
    ValidationGatewayPods -> GatewayRuntimeNoBoundary
    ValidationGatewayPartition -> GatewayRuntimeNoBoundary
    ValidationChartsPlatform -> GatewayRuntimeNoBoundary
    ValidationResourceGuardrails -> GatewayRuntimeNoBoundary
    ValidationDaemonBootstrap -> GatewayRuntimeNoBoundary
    ValidationPulsarBroker -> GatewayRuntimeNoBoundary
    ValidationChartsStorage -> GatewayRuntimeNoBoundary
    ValidationKeycloakInvite -> GatewayRuntimeNoBoundary
    ValidationSealedVault -> GatewayRuntimeNoBoundary

finishValidationGatewayRolloutBoundary
  :: FilePath
  -> NativeSuitePlan
  -> Maybe GatewayRuntimeStabilityRecorder
  -> Maybe GatewayRuntimeStabilityMonitor
  -> NativeValidation
  -> IO ExitCode
finishValidationGatewayRolloutBoundary _ _ Nothing _ _ = pure ExitSuccess
finishValidationGatewayRolloutBoundary repoRoot suitePlan (Just recorder) maybeMonitor validation =
  case gatewayRuntimeValidationBoundary (nativeSubstrate suitePlan) validation of
    GatewayRuntimeNoBoundary -> pure ExitSuccess
    GatewayRuntimePlannedRollout -> sampleAndResume
    GatewayRuntimeRecreatedTarget ->
      runSequentially
        [ refreshGatewayRuntimeMonitorIfPresent maybeMonitor
        , recordGatewayRuntimeStabilitySample
            (nativeSubstrate suitePlan)
            repoRoot
            recorder
        , resumeGatewayRuntimeMonitorIfPresent maybeMonitor
        ]
 where
  sampleAndResume =
    runSequentially
      [ recordGatewayRuntimeStabilitySample
          (nativeSubstrate suitePlan)
          repoRoot
          recorder
      , resumeGatewayRuntimeMonitorIfPresent maybeMonitor
      ]

runPhaseOneInitialPrerequisites :: FilePath -> NativeSuitePlan -> IO ExitCode
runPhaseOneInitialPrerequisites repoRoot suitePlan =
  case nativeInitialIntegrationGatePrerequisites suitePlan of
    [] -> pure ExitSuccess
    prerequisites ->
      case fromRootIds prerequisites prerequisiteRegistry of
        Left err -> failWith err
        Right dag -> do
          result <-
            runEffectDAG
              InterpreterContext {interpreterRepoRoot = repoRoot}
              dag
          case result of
            Failure err -> failWith err
            Success () -> pure ExitSuccess

runPhaseOneDeferredPrerequisites :: FilePath -> NativeSuitePlan -> IO ExitCode
runPhaseOneDeferredPrerequisites repoRoot suitePlan =
  case nativeDeferredIntegrationGatePrerequisites suitePlan of
    [] -> pure ExitSuccess
    prerequisites ->
      case fromRootIds prerequisites prerequisiteRegistry of
        Left err -> failWith err
        Right dag -> do
          result <-
            runEffectDAG
              InterpreterContext {interpreterRepoRoot = repoRoot}
              dag
          case result of
            Failure err -> failWith err
            Success () -> pure ExitSuccess

phaseOneMessage :: NativeSuitePlan -> String
phaseOneMessage suitePlan =
  if null (nativeInitialIntegrationGatePrerequisites suitePlan)
    && null (nativeDeferredIntegrationGatePrerequisites suitePlan)
    then phaseOneNoPrereqMessage
    else phaseOneGateMessage

-- | Sprint 5.10: regenerate the binary-sibling @prodbox.dhall@ from
-- @test-secrets.dhall@ + baked defaults through the shared
-- 'Prodbox.Aws.configFromSetupInput' builder, so @prodbox test all@ runs from a
-- freshly-generated skeleton without an interactive @config setup@. Idempotent
-- and refuses to clobber a populated real config. Failures are surfaced as a
-- loud 'ExitFailure', mirroring 'runManagedAwsHarnessSetup'.
runConfigRegenFromTestSecrets :: FilePath -> PolicyTier -> IO ExitCode
runConfigRegenFromTestSecrets repoRoot policyTier = do
  result <-
    try (regenerateConfigFromTestSecrets repoRoot policyTier)
      :: IO (Either SomeException (Either String ()))
  case result of
    Left err ->
      failWith
        ("Harness config regeneration from test-secrets.dhall failed: " ++ displayException err)
    Right (Left err) ->
      failWith ("Harness config regeneration from test-secrets.dhall failed: " ++ err)
    Right (Right ()) -> pure ExitSuccess

-- | Sprint 5.10 follow-up: after the pre-reconcile has unsealed Vault, force the
-- in-force config SSoT to match the regenerated binary-sibling config, so the
-- edge reconcile (which reads the in-force SSoT) sees the harness-populated
-- @route53.zone_id@ etc. On a freshly-established cluster the in-force SSoT seeds
-- from the file automatically; this fixes the case where the cluster was
-- established BEFORE the operator fields were populated, leaving a stale SSoT
-- that fails the gateway-chart deploy. Best-effort: a graceful no-op when not
-- established / Vault sealed; loud 'ExitFailure' only on a real MinIO write
-- failure.
runForceSyncInForceConfig :: FilePath -> IO ExitCode
runForceSyncInForceConfig repoRoot = do
  result <-
    try (forceSyncInForceConfigFromFile repoRoot)
      :: IO (Either SomeException (Either String ()))
  case result of
    Left err ->
      failWith ("Harness in-force config sync failed: " ++ displayException err)
    Right (Left err) ->
      failWith ("Harness in-force config sync failed: " ++ err)
    Right (Right ()) -> pure ExitSuccess

runManagedAwsHarnessSetup :: FilePath -> PolicyTier -> IO ExitCode
runManagedAwsHarnessSetup repoRoot policyTier = do
  setupResult <- try (runAwsIamHarnessSetup repoRoot policyTier) :: IO (Either SomeException String)
  case setupResult of
    Left err ->
      failWith
        ( "Managed AWS IAM harness setup failed: "
            ++ displayException err
        )
    Right output -> do
      writeOutput output
      pure ExitSuccess

runManagedAwsHarnessTeardown :: FilePath -> IO ExitCode
runManagedAwsHarnessTeardown repoRoot = do
  teardownResult <- try (runAwsIamHarnessTeardown repoRoot) :: IO (Either SomeException String)
  case teardownResult of
    Left err ->
      failWith
        ( "Managed AWS IAM harness teardown failed: "
            ++ displayException err
        )
    Right output -> do
      writeOutput output
      pure ExitSuccess

preferEarlierFailure :: ExitCode -> ExitCode -> ExitCode
preferEarlierFailure earlierResult cleanupResult =
  case earlierResult of
    failure@(ExitFailure _) -> failure
    ExitSuccess -> cleanupResult

runCommandForExitCode :: Subprocess -> IO ExitCode
runCommandForExitCode spec = do
  commandResult <- runSubprocessStreaming spec
  case commandResult of
    Failure err -> failWith err
    Success exitCode -> pure exitCode

runWaitForPublicEdgeReady
  :: FilePath -> [(String, String)] -> Substrate -> Int -> Int -> IO ExitCode
runWaitForPublicEdgeReady repoRoot environment substrate attempts delayMicroseconds =
  go attempts publicEdgeCertificateRepairAttempts
 where
  spec =
    nativeCliCommandSpec
      repoRoot
      environment
      ["edge", "status", "--substrate", substrateId substrate]

  go :: Int -> Int -> IO ExitCode
  go attemptsLeft repairsLeft = do
    outputResult <- captureSubprocessResult spec
    case outputResult of
      Failure err -> failWith ("failed to start `" ++ commandDisplay spec ++ "`: " ++ err)
      Success output -> do
        let combinedOutput = processStdout output ++ processStderr output
        writeOutput (processStdout output)
        writeDiagnostic (processStderr output)
        case processExitCode output of
          ExitFailure code ->
            failWith
              ( "`"
                  ++ commandDisplay spec
                  ++ "` exited with code "
                  ++ show code
              )
          ExitSuccess
            | publicEdgeReadyClassification `isInfixOf` combinedOutput -> do
                -- Sprint 8.8 retain-on-ready: capture the freshly-issued cert
                -- to the long-lived S3 store now that it is confirmed ready, so
                -- every subsequent rebuild restores it instead of re-ordering
                -- against ZeroSSL. Best-effort: a retention failure never fails
                -- the run (the cert is already issued and serving).
                retainOutcome <- retainReadyPublicEdgeCertificate repoRoot substrate
                case retainOutcome of
                  Left err ->
                    writeDiagnosticLine
                      ("public-edge cert retain-on-ready failed (non-fatal): " ++ err)
                  Right outcome ->
                    writeDiagnosticLine
                      ("public-edge cert retain-on-ready: " ++ renderPublicEdgePreserveOutcome outcome)
                pure ExitSuccess
            | attemptsLeft <= 1 ->
                failWith
                  ( "`"
                      ++ commandDisplay spec
                      ++ "` did not report required output `"
                      ++ publicEdgeReadyClassification
                      ++ "` before timeout."
                  )
            | otherwise -> do
                repairResult <-
                  if repairsLeft > 0
                    then maybeRepairPublicEdgeCertificateIssuance repoRoot environment combinedOutput
                    else pure (Right False)
                case repairResult of
                  Left err -> failWith err
                  Right repaired -> do
                    writeDiagnosticLine
                      ( if repaired
                          then "Waiting for public-edge certificate reissue before retry."
                          else "Waiting for required native command output before retry."
                      )
                    threadDelay delayMicroseconds
                    go
                      (attemptsLeft - 1)
                      ( if repaired
                          then repairsLeft - 1
                          else repairsLeft
                      )

maybeRepairPublicEdgeCertificateIssuance
  :: FilePath
  -> [(String, String)]
  -> String
  -> IO (Either String Bool)
maybeRepairPublicEdgeCertificateIssuance repoRoot environment combinedOutput
  | "CLASSIFICATION=certificate-not-ready" `notElem` lines combinedOutput = pure (Right False)
  | otherwise = do
      failureInfoResult <- loadPublicEdgeCertificateFailure repoRoot environment
      case failureInfoResult of
        Left err -> pure (Left err)
        Right Nothing -> pure (Right False)
        Right (Just failureInfo) -> do
          repairTargetsResult <- loadPublicEdgeRepairTargets repoRoot environment failureInfo
          case repairTargetsResult of
            Left err -> pure (Left err)
            Right repairTargets ->
              if null repairTargets
                then do
                  writeOutputLine
                    ( "Detected failed public-edge certificate issuance ("
                        ++ show (publicEdgeFailedIssuanceAttempts failureInfo)
                        ++ " failed attempt(s)); no stale ACME resources remain, triggering immediate reissue."
                    )
                  triggerPublicEdgeCertificateReissue repoRoot environment failureInfo
                else do
                  writeOutputLine
                    ( "Detected failed public-edge certificate issuance ("
                        ++ show (publicEdgeFailedIssuanceAttempts failureInfo)
                        ++ " failed attempt(s)); deleting stale ACME resources for an immediate reissue."
                    )
                  deleteResult <-
                    captureSubprocessResult
                      Subprocess
                        { subprocessPath = "kubectl"
                        , subprocessArguments = ["-n", publicEdgeNamespace, "delete", "--ignore-not-found"] ++ repairTargets
                        , subprocessEnvironment = Just environment
                        , subprocessWorkingDirectory = Just repoRoot
                        }
                  case deleteResult of
                    Failure err ->
                      pure
                        ( Left
                            ( "failed to start `kubectl` while repairing public-edge certificate issuance: "
                                ++ err
                            )
                        )
                    Success deleteOutput ->
                      case processExitCode deleteOutput of
                        ExitFailure _ ->
                          pure
                            ( Left
                                ( "Failed to delete stale public-edge ACME resources: "
                                    ++ processStderr deleteOutput
                                    ++ processStdout deleteOutput
                                )
                            )
                        ExitSuccess ->
                          triggerPublicEdgeCertificateReissue repoRoot environment failureInfo

triggerPublicEdgeCertificateReissue
  :: FilePath
  -> [(String, String)]
  -> PublicEdgeCertificateFailure
  -> IO (Either String Bool)
triggerPublicEdgeCertificateReissue repoRoot environment failureInfo = do
  now <- getCurrentTime
  let timestamp = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now
      statusPatch = publicEdgeCertificateReissueStatusPatch timestamp failureInfo
  patchResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "-n"
            , publicEdgeNamespace
            , "patch"
            , "certificate"
            , publicEdgeCertificateName
            , "--subresource=status"
            , "--type=merge"
            , "-p"
            , statusPatch
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $
    case patchResult of
      Failure err ->
        Left ("failed to start `kubectl` while triggering public-edge certificate reissue: " ++ err)
      Success patchOutput ->
        case processExitCode patchOutput of
          ExitFailure _ ->
            Left
              ( "Failed to trigger public-edge certificate reissue: "
                  ++ processStderr patchOutput
                  ++ processStdout patchOutput
              )
          ExitSuccess -> Right True

publicEdgeCertificateReissueStatusPatch :: String -> PublicEdgeCertificateFailure -> String
publicEdgeCertificateReissueStatusPatch timestamp failureInfo =
  BL8.unpack
    ( encode
        ( object
            [ "status"
                .= object
                  [ "conditions"
                      .= [ object
                             ( baseConditionFields
                                 ++ maybe
                                   []
                                   (\generation -> ["observedGeneration" .= generation])
                                   (publicEdgeCertificateObservedGeneration failureInfo)
                             )
                         ]
                  ]
            ]
        )
    )
 where
  baseConditionFields =
    [ "type" .= ("Issuing" :: String)
    , "status" .= ("True" :: String)
    , "reason" .= ("ManualTrigger" :: String)
    , "message"
        .= ( "Certificate renewal manually triggered by prodbox after failed public-edge issuance"
               :: String
           )
    , "lastTransitionTime" .= timestamp
    ]

loadPublicEdgeCertificateFailure
  :: FilePath
  -> [(String, String)]
  -> IO (Either String (Maybe PublicEdgeCertificateFailure))
loadPublicEdgeCertificateFailure repoRoot environment = do
  outputResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "-n"
            , publicEdgeNamespace
            , "get"
            , "certificate"
            , publicEdgeCertificateName
            , "--ignore-not-found=true"
            , "-o"
            , "jsonpath={.status.failedIssuanceAttempts}{\"|\"}{.status.nextPrivateKeySecretName}{\"|\"}{.metadata.generation}"
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $
    case outputResult of
      Failure err ->
        Left ("failed to start `kubectl` while checking public-edge certificate status: " ++ err)
      Success output ->
        case processExitCode output of
          ExitFailure _ ->
            Left
              ( "Failed to inspect public-edge certificate status: "
                  ++ processStderr output
                  ++ processStdout output
              )
          ExitSuccess ->
            Right (parsePublicEdgeCertificateFailure (processStdout output))

loadPublicEdgeRepairTargets
  :: FilePath
  -> [(String, String)]
  -> PublicEdgeCertificateFailure
  -> IO (Either String [String])
loadPublicEdgeRepairTargets repoRoot environment failureInfo = do
  outputResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "-n"
            , publicEdgeNamespace
            , "get"
            , "certificaterequest,order,challenge"
            , "-o"
            , "name"
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $
    case outputResult of
      Failure err ->
        Left ("failed to start `kubectl` while listing public-edge ACME resources: " ++ err)
      Success output ->
        case processExitCode output of
          ExitFailure _ ->
            Left
              ( "Failed to list public-edge ACME resources: "
                  ++ processStderr output
                  ++ processStdout output
              )
          ExitSuccess ->
            Right
              ( filter isPublicEdgeAcmeResource (nonEmptyLines (processStdout output))
                  ++ maybe [] (\secretName -> ["secret/" ++ secretName]) (publicEdgeNextPrivateKeySecretName failureInfo)
              )

parsePublicEdgeCertificateFailure :: String -> Maybe PublicEdgeCertificateFailure
parsePublicEdgeCertificateFailure stdoutText =
  case splitOnChar '|' (trimWhitespace stdoutText) of
    [] -> Nothing
    [""] -> Nothing
    attemptsText : secretNameText : generationText : _ ->
      parseFailure
        attemptsText
        (normalizeOptionalText secretNameText)
        (parsePositiveInt generationText)
    attemptsText : secretNameText : _ ->
      parseFailure attemptsText (normalizeOptionalText secretNameText) Nothing
    attemptsText : _ ->
      parseFailure attemptsText Nothing Nothing
 where
  parseFailure :: String -> Maybe String -> Maybe Int -> Maybe PublicEdgeCertificateFailure
  parseFailure attemptsText maybeSecretName maybeGeneration =
    case reads attemptsText of
      [(attemptCount, "")]
        | attemptCount > 0 ->
            Just
              PublicEdgeCertificateFailure
                { publicEdgeFailedIssuanceAttempts = attemptCount
                , publicEdgeNextPrivateKeySecretName = maybeSecretName
                , publicEdgeCertificateObservedGeneration = maybeGeneration
                }
      _ -> Nothing

  parsePositiveInt :: String -> Maybe Int
  parsePositiveInt value =
    case reads (trimWhitespace value) of
      [(parsed, "")]
        | parsed > 0 -> Just parsed
      _ -> Nothing

isPublicEdgeAcmeResource :: String -> Bool
isPublicEdgeAcmeResource resourceName =
  case break (== '/') resourceName of
    (_, '/' : objectName) -> (publicEdgeCertificateName ++ "-") `isPrefixOf` objectName
    _ -> False

nonEmptyLines :: String -> [String]
nonEmptyLines =
  filter (not . null) . map trimWhitespace . lines

splitOnChar :: Char -> String -> [String]
splitOnChar separator = go []
 where
  go current [] = [reverse current]
  go current (character : rest)
    | character == separator = reverse current : go [] rest
    | otherwise = go (character : current) rest

trimWhitespace :: String -> String
trimWhitespace = dropWhileEnd isWhitespace . dropWhile isWhitespace
 where
  isWhitespace character = character == ' ' || character == '\n' || character == '\r' || character == '\t'

normalizeOptionalText :: String -> Maybe String
normalizeOptionalText rawValue =
  let trimmed = trimWhitespace rawValue
   in if null trimmed
        then Nothing
        else Just trimmed

runNativeCliCommandForExitCode :: FilePath -> [(String, String)] -> [String] -> IO ExitCode
runNativeCliCommandForExitCode repoRoot environment cliArgs = do
  runCommandForExitCode (nativeCliCommandSpec repoRoot environment cliArgs)

nativeCliCommandSpec :: FilePath -> [(String, String)] -> [String] -> Subprocess
nativeCliCommandSpec repoRoot environment cliArgs =
  Subprocess
    { subprocessPath = canonicalOperatorBinaryPath repoRoot
    , subprocessArguments = cliArgs
    , subprocessEnvironment = Just environment
    , subprocessWorkingDirectory = Just repoRoot
    }

ensureCanonicalOperatorBinary :: FilePath -> [(String, String)] -> IO ExitCode
ensureCanonicalOperatorBinary repoRoot environment = do
  syncResult <- syncBuiltOperatorBinary repoRoot environment
  case syncResult of
    Left err -> failWith err
    Right binaryPath
      | binaryPath == canonicalOperatorBinaryPath repoRoot -> pure ExitSuccess
      | otherwise ->
          failWith
            ( "canonical operator binary synced to unexpected path: "
                ++ binaryPath
            )

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)
