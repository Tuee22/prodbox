{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Prodbox.Config.BootstrapProjection
  ( bootstrapKindPlan
  , bootstrapScope
  , readBootstrapProjection
  )
import Prodbox.Config.DeploymentScope (FreshScopeResult (FreshScopePrepared), prepareFreshScope)
import Prodbox.Config.KindPlan (KindNodeCreateInput (..), kindNodeRunArguments)
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (..), DockerSocketIdentity (..))
import Prodbox.Control.KindLease (KindOperationOutcome (..), withNewKindOperation)
import Prodbox.Control.KindNodeCreateIntent
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = withSystemTempDirectory "prodbox-node-intent-budget" $ \anchor -> do
  let selected = anchor </> "selected.dhall"
      operation = replicate 32 'b'
      generation = replicate 32 'a'
      digest c = "sha256:" ++ replicate 64 c
      tool = "sha256:50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54"
      document =
        "{ bootstrap = { schema_version = 3, project_anchor = \""
          ++ anchor
          ++ "\", runtime_socket = \""
          ++ anchor
          ++ "/docker.sock\", environment = \"test\", deployment_id = \"run\", root_generation = \""
          ++ generation
          ++ "\", api_port = 26443, node_image = \"kindest/node@"
          ++ digest 'a'
          ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, "
          ++ "node_artifact = { path = \"artifacts/node.tar\", digest = \""
          ++ digest 'a'
          ++ "\", maximum_bytes = 4096 }, kind_tool = { path = \"artifacts/kind\", digest = \""
          ++ tool
          ++ "\", maximum_bytes = 4096 }, listen_address = \"127.0.0.1\" } }"
  writeFile selected document
  bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
  prepared <- prepareFreshScope (bootstrapScope bootstrap) generation
  unless (prepared == FreshScopePrepared) (fail "fixture root refused")
  let input =
        KindNodeCreateInput
          tool
          (digest 'd')
          (replicate 64 'e')
          generation
          operation
          (kindNodeRunArguments (bootstrapKindPlan bootstrap) (digest 'd'))
      daemon = DockerDaemonObserved "daemon-a" (DockerSocketIdentity 1 2 1000 0o140660)
  intent <- maybe (fail "node intent invalid") pure (mkKindNodeCreateIntent bootstrap input daemon)
  result <- withNewKindOperation bootstrap operation $ \stable -> do
    written <- recordKindNodeCreateIntent bootstrap intent (threadDelay 6000000 >> stable)
    observed <- observeKindNodeCreateIntent bootstrap intent stable
    refused <- recordKindNodeCreateIntent bootstrap intent (pure False)
    pure (written, observed, refused)
  unless
    ( result
        == KindOperationCallbackReturned
          (NodeCreateIntentRecorded, NodeCreateIntentMatches, NodeCreateIntentRefused)
    )
    $ fail ("slow bounded admission did not confirm the node intent: " ++ show result)
  putStrLn "slow admission confirmed the node intent and false admission was refused"
