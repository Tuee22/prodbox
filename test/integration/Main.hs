module Main (main) where

import CliSuite (integrationCliSuite)
import EnvSuite (integrationEnvSuite)
import FixtureServer (runAuthorityFixtureServer, runBrokerFixtureServer, runVaultFixtureServer)
import System.Environment (getArgs, withArgs)
import TestSupport (mainWithSuite)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--fixture-broker-server", rawPort] -> runBrokerFixtureServer (read rawPort)
    ["--fixture-authority-server", rawPort] -> runAuthorityFixtureServer (read rawPort)
    ["--fixture-vault-server", rawPort] -> runVaultFixtureServer (read rawPort)
    _ ->
      withArgs ("--num-threads=1" : arguments) $
        mainWithSuite "prodbox-integration" $ do
          integrationCliSuite
          integrationEnvSuite
