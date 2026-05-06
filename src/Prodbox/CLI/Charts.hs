module Prodbox.CLI.Charts (
    runChartsCommand,
)
where

import Control.Exception (IOException, try)
import Data.Char (toLower)
import Data.List (intercalate)
import Prodbox.CLI.Command (ChartsCommand (..))
import Prodbox.Lib.ChartPlatform (
    buildChartDeletePlan,
    buildChartDeploymentPlan,
    deleteChartPlan,
    deployChartPlan,
    renderChartList,
    renderChartStatus,
    resolveChartSecrets,
    resolveGatewayEventKeys,
    supportedChartNames,
 )
import Prodbox.Settings (
    ValidatedSettings,
    validateAndLoadSettings,
 )
import System.Exit (
    ExitCode (ExitFailure, ExitSuccess),
 )
import System.IO (
    hFlush,
    hPutStrLn,
    stderr,
    stdout,
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
        ChartsDeploy chartName ->
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
                                            Right plan -> do
                                                deployResult <- deployChartPlan plan
                                                either failWith writeSuccess deployResult
        ChartsDelete chartName confirmed ->
            case requirePublicRootChartName chartName of
                Left err -> failWith err
                Right rootChart ->
                    withSettings repoRoot $ \settings -> do
                        allowed <- if confirmed then pure True else promptForDelete rootChart
                        if not allowed
                            then failWith "User declined confirmation"
                            else case buildChartDeletePlan repoRoot (Just settings) rootChart of
                                Left err -> failWith err
                                Right plan -> do
                                    deleteResult <- deleteChartPlan plan
                                    either failWith writeSuccess deleteResult

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

failWith :: String -> IO ExitCode
failWith message = do
    hPutStrLn stderr message
    pure (ExitFailure 1)
