module Main (main) where

import CliSuite
  ( integrationCliSuite
  , runRke2AdmissionRefusalFixture
  , runRunbookFailureFixture
  )
import EnvSuite (integrationEnvSuite)
import FixtureServer (runAuthorityFixtureServer, runBrokerFixtureServer, runVaultFixtureServer)
import System.Environment (getArgs, withArgs)
import System.Exit (exitWith)
import TestSupport (mainWithSuite)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--fixture-broker-server", rawPort] -> runBrokerFixtureServer (read rawPort)
    ["--fixture-authority-server", rawPort] -> runAuthorityFixtureServer (read rawPort)
    ["--fixture-vault-server", rawPort] -> runVaultFixtureServer (read rawPort)
    ["--fixture-rke2-admission-refusal", repoRoot] ->
      runRke2AdmissionRefusalFixture repoRoot >>= exitWith
    ["--fixture-runbook-failure", repoRoot] ->
      runRunbookFailureFixture repoRoot >>= exitWith
    _ ->
      withArgs ("--num-threads=1" : arguments) $
        mainWithSuite "prodbox-integration" $ do
          integrationCliSuite
          integrationEnvSuite
