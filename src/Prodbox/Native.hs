module Prodbox.Native
    ( runNativeCommand,
    )
where

import Prodbox.Aws
    ( runAwsCommand,
      runInteractiveConfigSetup,
    )
import Prodbox.CLI.Charts (runChartsCommand)
import Prodbox.CLI.Command
    ( ConfigCommand (..),
      NativeCommand (..),
    )
import Prodbox.CLI.Pulumi (runPulumiCommand)
import Prodbox.CLI.Rke2 (runRke2Command)
import Prodbox.Dns (runDnsCommand)
import Prodbox.CheckCode (runCheckCode)
import Prodbox.Gateway (runGatewayCommand)
import Prodbox.Host (runHostCommand)
import Prodbox.K8s (runK8sCommand)
import Prodbox.Tla (runTlaCheck)
import Prodbox.Settings
    ( materializeConfigJson,
      renderSettingsDisplay,
      validateAndLoadSettings,
    )
import Prodbox.TestRunner (runTests)
import System.Exit
    ( ExitCode (ExitFailure, ExitSuccess),
    )
import System.IO (hPutStrLn, stderr)

runNativeCommand :: FilePath -> NativeCommand -> IO ExitCode
runNativeCommand repoRoot command =
    case command of
        NativeAws awsCommand -> runAwsCommand repoRoot awsCommand
        NativeCharts chartsCommand -> runChartsCommand repoRoot chartsCommand
        NativeCheckCode -> runCheckCode repoRoot
        NativeConfig configCommand -> runConfigCommand repoRoot configCommand
        NativeDns dnsCommand -> runDnsCommand repoRoot dnsCommand
        NativeGateway gatewayCommand -> runGatewayCommand repoRoot gatewayCommand
        NativeHost hostCommand -> runHostCommand repoRoot hostCommand
        NativeK8s k8sCommand -> runK8sCommand repoRoot k8sCommand
        NativePulumi pulumiCommand -> runPulumiCommand repoRoot pulumiCommand
        NativeRke2 rke2Command -> runRke2Command repoRoot rke2Command
        NativeTest testCommand -> runTests repoRoot testCommand
        NativeTlaCheck -> runTlaCheck repoRoot

runConfigCommand :: FilePath -> ConfigCommand -> IO ExitCode
runConfigCommand repoRoot configCommand =
    case configCommand of
        ConfigCompile -> do
            result <- materializeConfigJson repoRoot
            either failWith (const (pure ExitSuccess)) result
        ConfigSetup -> runInteractiveConfigSetup repoRoot
        ConfigShow showSecrets -> do
            result <- validateAndLoadSettings repoRoot
            case result of
                Left err -> failWith err
                Right settings -> do
                    putStr (renderSettingsDisplay showSecrets settings)
                    pure ExitSuccess
        ConfigValidate -> do
            result <- validateAndLoadSettings repoRoot
            either failWith (const (pure ExitSuccess)) result

failWith :: String -> IO ExitCode
failWith message = do
    hPutStrLn stderr message
    pure (ExitFailure 1)
