module Main (main) where

import Control.Exception (bracket)
import Prodbox.CLI.Command
  ( WorkloadOptions (..)
  )
import Prodbox.CLI.Spec
  ( findCommandSpec
  )
import Prodbox.Gateway
  ( resolveGatewayConfigPath
  , resolveGatewayLogLevel
  , resolveGatewayPortOverride
  )
import Prodbox.Workload
  ( resolveHttpPort
  , resolveWorkloadLogLevel
  )
import System.Directory (getCurrentDirectory)
import System.Environment
  ( lookupEnv
  , setEnv
  , unsetEnv
  )
import System.FilePath ((</>))
import TestSupport

main :: IO ()
main = mainWithSuite "prodbox-daemon-lifecycle" $ do
  describe "daemon lifecycle suite scaffold" $ do
    it "keeps the gateway daemon runtime in the repository" $ do
      repoRoot <- getCurrentDirectory
      daemonSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Gateway" </> "Daemon.hs")
      daemonSource `shouldContain` "runGatewayDaemon"

    it "keeps the gateway start command in the registry-backed parser" $
      findCommandSpec ["gateway", "start"]
        `shouldSatisfy` isJust

  describe "daemon flag precedence" $ do
    it "prefers gateway CLI flags over PRODBOX_* env vars"
      $ withTemporaryEnv
        [ ("PRODBOX_CONFIG_PATH", Just "/tmp/from-env-gateway.json")
        , ("PRODBOX_LOG_LEVEL", Just "debug")
        , ("PRODBOX_PORT", Just "4100")
        ]
      $ do
        resolveGatewayConfigPath (Just "/tmp/from-cli-gateway.json")
          `shouldReturn` Right "/tmp/from-cli-gateway.json"
        resolveGatewayLogLevel (Just "warn")
          `shouldReturn` "warn"
        resolveGatewayPortOverride (Just 4200)
          `shouldReturn` Right (Just 4200)

    it "falls back to gateway env vars when CLI flags are absent"
      $ withTemporaryEnv
        [ ("PRODBOX_CONFIG_PATH", Just "/tmp/from-env-gateway.json")
        , ("PRODBOX_LOG_LEVEL", Just "debug")
        , ("PRODBOX_PORT", Just "4100")
        ]
      $ do
        resolveGatewayConfigPath Nothing
          `shouldReturn` Right "/tmp/from-env-gateway.json"
        resolveGatewayLogLevel Nothing
          `shouldReturn` "debug"
        resolveGatewayPortOverride Nothing
          `shouldReturn` Right (Just 4100)

    it "fails fast on an invalid gateway PRODBOX_PORT"
      $ withTemporaryEnv
        [("PRODBOX_PORT", Just "not-a-port")]
      $ resolveGatewayPortOverride Nothing
        `shouldReturn` Left "Invalid PRODBOX_PORT value: not-a-port"

    it "applies workload port precedence as CLI, then PRODBOX_PORT, then legacy env, then default"
      $ withTemporaryEnv
        [ ("PRODBOX_PORT", Just "9100")
        , ("PRODBOX_HTTP_PORT", Just "9200")
        ]
      $ do
        resolveHttpPort defaultWorkloadOptions
          `shouldReturn` 9100
        resolveHttpPort defaultWorkloadOptions {workloadPort = Just 9300}
          `shouldReturn` 9300

    it "falls back to the workload default port and info log level"
      $ withTemporaryEnv
        [ ("PRODBOX_PORT", Nothing)
        , ("PRODBOX_HTTP_PORT", Nothing)
        , ("PRODBOX_LOG_LEVEL", Nothing)
        ]
      $ do
        resolveHttpPort defaultWorkloadOptions
          `shouldReturn` 8080
        resolveWorkloadLogLevel defaultWorkloadOptions
          `shouldReturn` "info"

    it "prefers workload CLI log level over PRODBOX_LOG_LEVEL"
      $ withTemporaryEnv
        [("PRODBOX_LOG_LEVEL", Just "debug")]
      $ do
        resolveWorkloadLogLevel defaultWorkloadOptions
          `shouldReturn` "debug"
        resolveWorkloadLogLevel defaultWorkloadOptions {workloadLogLevel = Just "warn"}
          `shouldReturn` "warn"

defaultWorkloadOptions :: WorkloadOptions
defaultWorkloadOptions =
  WorkloadOptions
    { workloadLogLevel = Nothing
    , workloadPort = Nothing
    , workloadForeground = True
    }

withTemporaryEnv :: [(String, Maybe String)] -> IO a -> IO a
withTemporaryEnv bindings action =
  bracket capture restore (\_ -> applyBindings bindings >> action)
 where
  capture = mapM (\(name, _) -> captureBinding name) bindings

  restore originalValues = applyBindings originalValues

  captureBinding name = do
    value <- lookupEnv name
    pure (name, value)

applyBindings :: [(String, Maybe String)] -> IO ()
applyBindings =
  mapM_
    ( \(name, maybeValue) ->
        case maybeValue of
          Just value -> setEnv name value
          Nothing -> unsetEnv name
    )

isJust :: Maybe a -> Bool
isJust maybeValue =
  case maybeValue of
    Just _ -> True
    Nothing -> False
