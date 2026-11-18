module Main (main) where

import BootstrapSourceFixture (readyVaultVolumeJson)
import CliSuite
  ( integrationCliSuite
  , runRke2AdmissionRefusalFixture
  , runRunbookFailureFixture
  , runSelectedAuthorityRefusalFixture
  , runStreamingCancellationFixture
  )
import EnvSuite (integrationEnvSuite)
import FixtureServer (runAuthorityFixtureServer, runBrokerFixtureServer, runVaultFixtureServer)
import Prodbox.CLI.Command (VaultCommand (VaultResetAmbiguousInitialization))
import Prodbox.CLI.Vault
  ( runHarnessVaultBootstrapViaBroker
  , runVaultBootstrapViaBroker
  , runVaultCommand
  )
import System.Environment (getArgs, withArgs)
import System.Exit (exitWith)
import TestSupport (mainWithSuite)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    "--prodbox-suite=cli" : rest ->
      withArgs ("--num-threads=1" : rest) $
        mainWithSuite "prodbox-integration-cli" integrationCliSuite
    ["--prodbox-suite=env"] ->
      withArgs ["--num-threads=1"] $
        mainWithSuite "prodbox-integration-env" integrationEnvSuite
    ["--fixture-vault-bootstrap", "harness", repoRoot] ->
      runHarnessVaultBootstrapViaBroker repoRoot >>= exitWith
    ["--fixture-vault-bootstrap", "operator", repoRoot] ->
      runVaultBootstrapViaBroker repoRoot >>= exitWith
    ["--fixture-vault-bootstrap", "confirmed-reset", repoRoot] ->
      runVaultCommand repoRoot (VaultResetAmbiguousInitialization True) >>= exitWith
    ["--fixture-vault-volume", hostPath] -> putStrLn (readyVaultVolumeJson hostPath)
    ["--fixture-broker-server", rawPort] -> runBrokerFixtureServer (read rawPort)
    ["--fixture-authority-server", rawPort] -> runAuthorityFixtureServer (read rawPort)
    ["--fixture-vault-server", rawPort] -> runVaultFixtureServer (read rawPort)
    ["--fixture-rke2-admission-refusal", repoRoot] ->
      runRke2AdmissionRefusalFixture repoRoot >>= exitWith
    ["--fixture-selected-authority-refusal", repoRoot, kubeconfig] ->
      runSelectedAuthorityRefusalFixture repoRoot kubeconfig >>= exitWith
    ["--fixture-runbook-failure", repoRoot] ->
      runRunbookFailureFixture repoRoot >>= exitWith
    ["--fixture-streaming-cancellation", markerPath] ->
      runStreamingCancellationFixture markerPath >>= exitWith
    _ ->
      withArgs ("--num-threads=1" : arguments) $
        mainWithSuite "prodbox-integration" $ do
          integrationCliSuite
          integrationEnvSuite
