module Main (main) where

import CliSuite (integrationCliSuite)
import EnvSuite (integrationEnvSuite)
import TestSupport (mainWithSuite)

main :: IO ()
main = mainWithSuite "prodbox-integration" $ do
  integrationCliSuite
  integrationEnvSuite
