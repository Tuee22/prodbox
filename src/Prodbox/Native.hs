module Prodbox.Native
  ( runNativeCommand
  )
where

import Data.Text qualified as Text
import Prodbox.Aws
  ( runAwsCommand
  , runInteractiveConfigSetupWithPlan
  )
import Prodbox.CLI.Charts (runChartsCommand)
import Prodbox.CLI.Command
  ( ConfigCommand (..)
  , NativeCommand (..)
  )
import Prodbox.CLI.Output
  ( writeError
  , writeOutput
  )
import Prodbox.CLI.Pulumi (runPulumiCommand)
import Prodbox.CLI.Rke2 (runRke2Command)
import Prodbox.CheckCode
  ( runCheckCode
  , runDocsCommand
  , runLintCommand
  )
import Prodbox.Dns (runDnsCommand)
import Prodbox.Error (fatalError)
import Prodbox.Gateway (runGatewayCommand)
import Prodbox.Host (runHostCommand)
import Prodbox.K8s (runK8sCommand)
import Prodbox.Settings
  ( renderSettingsDisplay
  , validateAndLoadSettings
  )
import Prodbox.TestRunner (runTests)
import Prodbox.Tla (runTlaCheck)
import Prodbox.Workload (runWorkloadCommand)
import System.Exit
  ( ExitCode (ExitFailure, ExitSuccess)
  )

runNativeCommand :: FilePath -> NativeCommand -> IO ExitCode
runNativeCommand repoRoot command =
  case command of
    NativeAws awsCommand -> runAwsCommand repoRoot awsCommand
    NativeCharts chartsCommand -> runChartsCommand repoRoot chartsCommand
    NativeCheckCode -> runCheckCode repoRoot
    NativeConfig configCommand -> runConfigCommand repoRoot configCommand
    NativeDns dnsCommand -> runDnsCommand repoRoot dnsCommand
    NativeDocs docsCommand -> runDocsCommand repoRoot docsCommand
    NativeGateway gatewayCommand -> runGatewayCommand repoRoot gatewayCommand
    NativeHost hostCommand -> runHostCommand repoRoot hostCommand
    NativeK8s k8sCommand -> runK8sCommand repoRoot k8sCommand
    NativeLint lintCommand -> runLintCommand repoRoot lintCommand
    NativePulumi pulumiCommand -> runPulumiCommand repoRoot pulumiCommand
    NativeRke2 rke2Command -> runRke2Command repoRoot rke2Command
    NativeTest testCommand -> runTests repoRoot testCommand
    NativeTlaCheck -> runTlaCheck repoRoot
    NativeWorkload workloadCommand -> runWorkloadCommand workloadCommand

runConfigCommand :: FilePath -> ConfigCommand -> IO ExitCode
runConfigCommand repoRoot configCommand =
  case configCommand of
    ConfigSetup planOptions -> runInteractiveConfigSetupWithPlan repoRoot planOptions
    ConfigShow showSecrets -> do
      result <- validateAndLoadSettings repoRoot
      case result of
        Left err -> failWith err
        Right settings -> do
          writeOutput (renderSettingsDisplay showSecrets settings)
          pure ExitSuccess
    ConfigValidate -> do
      result <- validateAndLoadSettings repoRoot
      either failWith (const (pure ExitSuccess)) result

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)
