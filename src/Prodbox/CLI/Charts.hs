module Prodbox.CLI.Charts
  ( renderChartDeletePlan
  , renderChartDeploymentPlan
  , runChartsCommand
  )
where

import Control.Exception (IOException, bracket_, try)
import Data.Char (toLower)
import Data.List (intercalate)
import Data.Text qualified as Text
import Prodbox.CLI.Command
  ( ChartsCommand (..)
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.CLI.Output
  ( writeError
  , writeOutput
  )
import Prodbox.Error (fatalError)
import Prodbox.Lib.AwsSubstratePlatform (ensureAwsSubstratePlatformRuntime)
import Prodbox.Lib.ChartPlatform
  ( ChartDeploymentPlan (..)
  , ChartReleasePlan (..)
  , buildChartDeletePlan
  , buildChartDeploymentPlan
  , deleteChartPlan
  , deployChartPlan
  , renderChartList
  , renderChartStatus
  , resolveChartSecrets
  , resolveGatewayEventKeys
  , supportedChartNames
  )
import Prodbox.PublicEdge (substrateKubeconfigPath)
import Prodbox.Settings
  ( ValidatedSettings
  , validateAndLoadSettings
  )
import Prodbox.Substrate (Substrate (..))
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit
  ( ExitCode (ExitFailure, ExitSuccess)
  )
import System.IO
  ( hFlush
  , stdout
  )

runChartsCommand :: FilePath -> ChartsCommand -> IO ExitCode
runChartsCommand repoRoot command =
  case command of
    ChartsList ->
      withSettings repoRoot $ \settings -> do
        result <- renderChartList repoRoot settings
        either failWith writeSuccess result
    ChartsStatus chartName ->
      case requirePublicRootChartName chartName of
        Left err -> failWith err
        Right rootChart ->
          withSettings repoRoot $ \settings -> do
            result <- renderChartStatus repoRoot settings rootChart
            either failWith writeSuccess result
    ChartsDeploy chartName substrate planOptions ->
      case requirePublicRootChartName chartName of
        Left err -> failWith err
        Right rootChart ->
          withSettings repoRoot $ \settings -> do
            secretsResult <- resolveChartSecrets repoRoot rootChart
            case secretsResult of
              Left err -> failWith err
              Right chartSecrets -> do
                eventKeysResult <- resolveGatewayEventKeys repoRoot rootChart
                case eventKeysResult of
                  Left err -> failWith err
                  Right gatewayEventKeys -> do
                    buildResult <- buildChartDeploymentPlan repoRoot settings rootChart chartSecrets gatewayEventKeys
                    case buildResult of
                      Left err -> failWith err
                      Right plan ->
                        withSubstrateEnvironment repoRoot substrate $ do
                          platformExit <- ensurePlatformForSubstrate repoRoot settings substrate
                          case platformExit of
                            ExitFailure _ -> pure platformExit
                            ExitSuccess ->
                              runPlanWithOptions
                                planOptions
                                (buildPlan renderChartDeploymentPlan plan)
                                (applyChartPlanOutput deployChartPlan)
    ChartsDelete chartName substrate confirmed planOptions ->
      case requirePublicRootChartName chartName of
        Left err -> failWith err
        Right rootChart ->
          withSettings repoRoot $ \settings -> do
            allowed <- if confirmed then pure True else promptForDelete rootChart
            if not allowed
              then failWith "User declined confirmation"
              else case buildChartDeletePlan repoRoot (Just settings) rootChart of
                Left err -> failWith err
                Right plan ->
                  withSubstrateEnvironment repoRoot substrate $
                    runPlanWithOptions
                      planOptions
                      (buildPlan renderChartDeletePlan plan)
                      (applyChartPlanOutput deleteChartPlan)

requirePublicRootChartName :: String -> Either String String
requirePublicRootChartName chartName
  | chartName `elem` supportedChartNames = Right chartName
  | otherwise =
      Left
        ( "Unsupported public chart '"
            ++ chartName
            ++ "'. Supported root charts: "
            ++ intercalate ", " supportedChartNames
            ++ dependencyHint chartName
        )
 where
  dependencyHint name =
    case name of
      "keycloak-postgres" ->
        ". `keycloak-postgres` is an internal dependency release; use `prodbox charts ... keycloak`."
      "redis" ->
        ". `redis` is an internal dependency release; use `prodbox charts ... websocket`."
      _ -> ""

withSettings :: FilePath -> (ValidatedSettings -> IO ExitCode) -> IO ExitCode
withSettings repoRoot action = do
  settingsResult <- validateAndLoadSettings repoRoot
  case settingsResult of
    Left err -> failWith err
    Right settings -> action settings

promptForDelete :: String -> IO Bool
promptForDelete chartName = do
  writeOutput ("Delete chart stack " ++ chartName ++ "? [y/N]: ")
  hFlush stdout
  responseResult <- try getLine :: IO (Either IOException String)
  pure $ case responseResult of
    Left _ -> False
    Right response -> map toLower response `elem` ["y", "yes"]

writeSuccess :: String -> IO ExitCode
writeSuccess output = do
  writeOutput output
  pure ExitSuccess

applyChartPlanOutput
  :: (ChartDeploymentPlan -> IO (Either String String))
  -> ChartDeploymentPlan
  -> IO ExitCode
applyChartPlanOutput applyPlan plan = do
  applyResult <- applyPlan plan
  either failWith writeSuccess applyResult

renderChartDeploymentPlan :: ChartDeploymentPlan -> String
renderChartDeploymentPlan plan =
  unlines $
    [ "CHART_DEPLOY_PLAN"
    , "ROOT_CHART=" ++ chartDeploymentPlanRootChart plan
    , "NAMESPACE=" ++ chartDeploymentPlanNamespace plan
    ]
      ++ concatMap renderRelease (chartDeploymentPlanReleases plan)
 where
  renderRelease release =
    [ "RELEASE=" ++ chartReleasePlanReleaseName release
    , "CHART=" ++ chartReleasePlanChartName release
    , "CHART_DIR=" ++ chartReleasePlanChartDir release
    ]

renderChartDeletePlan :: ChartDeploymentPlan -> String
renderChartDeletePlan plan =
  unlines $
    [ "CHART_DELETE_PLAN"
    , "ROOT_CHART=" ++ chartDeploymentPlanRootChart plan
    , "NAMESPACE=" ++ chartDeploymentPlanNamespace plan
    ]
      ++ map (("DELETE_RELEASE=" ++) . chartReleasePlanReleaseName) (chartDeploymentPlanReleases plan)

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)

-- | For the AWS substrate, reconcile the platform runtime (AWS Load
-- Balancer Controller, Envoy Gateway, cert-manager, ACME ClusterIssuer)
-- before deploying a chart. For the home substrate this is a no-op
-- because the operator runs `prodbox rke2 reconcile` separately and that
-- command owns the home-cluster platform reconcile.
--
-- The AWS-substrate orchestrator is idempotent: each underlying step uses
-- `helm upgrade --install` or `kubectl apply`, so repeated runs converge
-- without breaking existing installs.
ensurePlatformForSubstrate
  :: FilePath -> ValidatedSettings -> Substrate -> IO ExitCode
ensurePlatformForSubstrate _ _ SubstrateHomeLocal = pure ExitSuccess
ensurePlatformForSubstrate repoRoot settings SubstrateAws =
  ensureAwsSubstratePlatformRuntime
    repoRoot
    settings
    awsSubstrateProdboxId
    awsSubstrateLabelValue
 where
  awsSubstrateProdboxId :: String
  awsSubstrateProdboxId = "prodbox-aws-substrate"

  awsSubstrateLabelValue :: String
  awsSubstrateLabelValue = "prodbox-aws-substrate"

-- | Run a chart-deploy/delete action with KUBECONFIG pointed at the substrate's
-- kubeconfig. For the home substrate this is a no-op (kubectl/helm pick up the
-- operator's default kubeconfig). For the AWS substrate the EKS kubeconfig
-- materialized by `materializeAwsEksKubeconfig` is exported so every helm and
-- kubectl invocation in `Prodbox.Lib.ChartPlatform` targets the EKS cluster.
withSubstrateEnvironment :: FilePath -> Substrate -> IO ExitCode -> IO ExitCode
withSubstrateEnvironment repoRoot substrate action =
  case substrateKubeconfigPath repoRoot substrate of
    Nothing -> action
    Just kubeconfigPath -> do
      previousKubeconfig <- lookupEnv "KUBECONFIG"
      bracket_
        (setEnv "KUBECONFIG" kubeconfigPath)
        (restoreEnv "KUBECONFIG" previousKubeconfig)
        action
 where
  restoreEnv :: String -> Maybe String -> IO ()
  restoreEnv name Nothing = unsetEnv name
  restoreEnv name (Just value) = setEnv name value
