module Prodbox.CLI.Charts
  ( renderChartDeletePlan
  , renderChartDeploymentPlan
  , runChartsCommand
  )
where

import Control.Exception (IOException, bracket_, try)
import Data.Char (toLower)
import Data.List (intercalate)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Prodbox.AwsEnvironment (overlayAwsCredentials)
import Prodbox.CLI.Command
  ( ChartsCommand (..)
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.CLI.Interactive
  ( chartsDeleteGuard
  , requireInteractiveTty
  )
import Prodbox.CLI.Output
  ( writeError
  , writeOutput
  )
import Prodbox.Error (fatalError)
import Prodbox.Host
  ( defaultGatewayNodePort
  , runHostFirewallGatewayRestrictOptional
  , runHostFirewallGatewayUnrestrict
  )
import Prodbox.Infra.AwsEksTestStack (withEksKubeconfig)
import Prodbox.Lib.AwsSubstratePlatform (ensureAwsSubstratePlatformRuntime)
import Prodbox.Lib.ChartPlatform
  ( ChartDeploymentPlan (..)
  , ChartReleasePlan (..)
  , buildChartDeletePlan
  , buildChartDeploymentPlanForSubstrate
  , deleteChartPlan
  , deployChartPlan
  , renderChartList
  , renderChartStatus
  , resolveChartSecrets
  , supportedChartNames
  )
import Prodbox.Settings
  ( ConfigFile (..)
  , ValidatedSettings (..)
  , aws
  , resolveAwsCredentialsRefFromHostVault
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
                -- Gateway event keys are Vault materialized by chart init /
                -- hook logic; the legacy host-side event-key cache is gone.
                let gatewayEventKeys = Map.empty
                buildResult <-
                  buildChartDeploymentPlanForSubstrate
                    substrate
                    repoRoot
                    settings
                    rootChart
                    chartSecrets
                    gatewayEventKeys
                case buildResult of
                  Left err -> failWith err
                  Right plan ->
                    withSubstrateEnvironment repoRoot settings substrate $ do
                      platformExit <- ensurePlatformForSubstrate repoRoot settings substrate
                      case platformExit of
                        ExitFailure _ -> pure platformExit
                        ExitSuccess ->
                          runPlanWithOptions
                            planOptions
                            (buildPlan renderChartDeploymentPlan plan)
                            (applyChartDeployWithPostHook rootChart substrate)
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
                  withSubstrateEnvironment repoRoot settings substrate $
                    runPlanWithOptions
                      planOptions
                      (buildPlan renderChartDeletePlan plan)
                      (applyChartDeleteWithPostHook rootChart substrate)

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
  requireInteractiveTty chartsDeleteGuard
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

-- | Sprint 2.19 lifecycle hook: after a successful @charts reconcile gateway@
-- on the home substrate, install the iptables loopback-only rule on the
-- gateway NodePort. Other charts and substrates pass through unchanged.
applyChartDeployWithPostHook
  :: String -> Substrate -> ChartDeploymentPlan -> IO ExitCode
applyChartDeployWithPostHook rootChart substrate plan = do
  deployExit <- applyChartPlanOutput deployChartPlan plan
  case (deployExit, rootChart, substrate) of
    (ExitSuccess, "gateway", SubstrateHomeLocal) ->
      runHostFirewallGatewayRestrictOptional defaultGatewayNodePort
    _ -> pure deployExit

-- | Sprint 2.19 lifecycle hook: symmetric to
-- 'applyChartDeployWithPostHook'. After @charts delete gateway@ on the
-- home substrate, remove the iptables loopback-only rule on the gateway
-- NodePort. Idempotent — @runHostFirewallGatewayUnrestrict@ treats an
-- absent rule as success-with-reason.
applyChartDeleteWithPostHook :: String -> Substrate -> ChartDeploymentPlan -> IO ExitCode
applyChartDeleteWithPostHook rootChart substrate plan = do
  deleteExit <- applyChartPlanOutput deleteChartPlan plan
  case (deleteExit, rootChart, substrate) of
    (ExitSuccess, "gateway", SubstrateHomeLocal) ->
      runHostFirewallGatewayUnrestrict defaultGatewayNodePort
    _ -> pure deleteExit

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
-- because the operator runs `prodbox cluster reconcile` separately and that
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
-- kubeconfig and AWS_* credentials projected for substrate-aware subprocesses.
--
-- For the home substrate this is a no-op (kubectl/helm pick up the operator's
-- default kubeconfig and the home cluster doesn't need AWS auth). For the AWS
-- substrate (Sprint 4.18 fifth chunk re-migration), the EKS kubeconfig is
-- materialized via 'withEksKubeconfig' into a scoped temp file and exported
-- alongside `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`
-- (and optionally `AWS_SESSION_TOKEN`) from `settings.aws.*`. Without the AWS
-- env vars, the EKS kubeconfig's `aws eks get-token` exec provider can't
-- fetch a token and every kubectl/helm call returns 401 "the server has asked
-- for the client to provide credentials".
withSubstrateEnvironment
  :: FilePath -> ValidatedSettings -> Substrate -> IO ExitCode -> IO ExitCode
withSubstrateEnvironment repoRoot settings substrate action =
  case substrate of
    SubstrateHomeLocal -> action
    SubstrateAws ->
      withEksKubeconfig repoRoot $ \kubeconfigPath -> do
        credentialsResult <-
          resolveAwsCredentialsRefFromHostVault
            repoRoot
            "aws"
            (aws (validatedConfig settings))
        case credentialsResult of
          Left err -> do
            writeError (fatalError (Text.pack ("load operational AWS credentials from Vault: " ++ err)))
            pure (ExitFailure 1)
          Right credentials -> do
            let envOverrides = overlayAwsCredentials [("KUBECONFIG", kubeconfigPath)] credentials
            previousValues <- mapM (\(name, _) -> lookupEnv name) envOverrides
            bracket_
              (mapM_ (\(name, value) -> setEnv name value) envOverrides)
              (mapM_ restoreOne (zip envOverrides previousValues))
              action
 where
  restoreOne :: ((String, String), Maybe String) -> IO ()
  restoreOne ((name, _), Nothing) = unsetEnv name
  restoreOne ((name, _), Just value) = setEnv name value
