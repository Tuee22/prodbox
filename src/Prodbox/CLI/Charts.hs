module Prodbox.CLI.Charts
  ( runChartsCommand
  )
where

import Control.Exception (IOException, try)
import Data.Char (toLower)
import Data.List (intercalate)
import Prodbox.CLI.Command
  ( ChartsCommand (..)
  , PlanOptions (..)
  )
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
import Prodbox.Settings
  ( ValidatedSettings
  , validateAndLoadSettings
  )
import System.Exit
  ( ExitCode (ExitFailure, ExitSuccess)
  )
import System.IO
  ( hFlush
  , hPutStrLn
  , stderr
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
    ChartsDeploy chartName planOptions ->
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
                        runPlanApply planOptions plan deployChartPlan renderChartDeploymentPlan
    ChartsDelete chartName confirmed planOptions ->
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
                  runPlanApply planOptions plan deleteChartPlan renderChartDeletePlan

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
  putStr ("Delete chart stack " ++ chartName ++ "? [y/N]: ")
  hFlush stdout
  responseResult <- try getLine :: IO (Either IOException String)
  pure $ case responseResult of
    Left _ -> False
    Right response -> map toLower response `elem` ["y", "yes"]

writeSuccess :: String -> IO ExitCode
writeSuccess output = do
  putStr output
  pure ExitSuccess

runPlanApply
  :: PlanOptions
  -> ChartDeploymentPlan
  -> (ChartDeploymentPlan -> IO (Either String String))
  -> (ChartDeploymentPlan -> String)
  -> IO ExitCode
runPlanApply planOptions plan applyPlan renderPlan = do
  let renderedPlan = renderPlan plan
  maybePersistPlan (planFile planOptions) renderedPlan
  if dryRun planOptions
    then writeSuccess renderedPlan
    else do
      applyResult <- applyPlan plan
      either failWith writeSuccess applyResult

maybePersistPlan :: Maybe FilePath -> String -> IO ()
maybePersistPlan Nothing _ = pure ()
maybePersistPlan (Just path) contents = writeFile path contents

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
  hPutStrLn stderr message
  pure (ExitFailure 1)
