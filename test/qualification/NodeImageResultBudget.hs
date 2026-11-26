{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Prodbox.Config.BootstrapProjection (bootstrapScope, readBootstrapProjection)
import Prodbox.Config.DeploymentScope (FreshScopeResult (FreshScopePrepared), prepareFreshScope)
import Prodbox.Control.DockerConnectedInfo (DockerImageLoadResult (..), DockerImageLoadStream (..))
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (..), DockerSocketIdentity (..))
import Prodbox.Control.KindLease (KindOperationOutcome (..), withNewKindOperation)
import Prodbox.Control.NodeImageIntent
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = withSystemTempDirectory "prodbox-image-result-budget" $ \anchor -> do
  let selected = anchor </> "selected.dhall"
      operation = replicate 32 'b'
      generation = replicate 32 'a'
      digest c = "sha256:" ++ replicate 64 c
      document =
        "{ bootstrap = { schema_version = 2, project_anchor = \""
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
          ++ "\", maximum_bytes = 4096 }, listen_address = \"127.0.0.1\" } }"
      transport = DockerImageLoadReply 200 (DockerImageLoadMessages 1)
  writeFile selected document
  bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
  prepared <- prepareFreshScope (bootstrapScope bootstrap) generation
  unless (prepared == FreshScopePrepared) (fail "fixture root refused")
  intent <-
    maybe
      (fail "intent invalid")
      pure
      (mkNodeImageIntent operation (digest 'c') (digest 'd') (digest 'e') 4096)
  bound <-
    maybe
      (fail "daemon binding invalid")
      pure
      ( bindNodeImageIntent
          intent
          (DockerDaemonObserved "daemon-a" (DockerSocketIdentity 1 2 1000 0o140660))
      )
  result <- withNewKindOperation bootstrap operation $ \stable -> do
    proposal <- recordNodeImageIntent bootstrap bound stable
    attempt <- recordNodeImageAttempt bootstrap bound stable
    unless
      (proposal == NodeImageIntentRecorded && attempt == NodeImageAttemptRecorded)
      (fail "fixture journal refused")
    written <- recordNodeImageResult bootstrap bound transport (threadDelay 2000000 >> stable)
    observed <- observeNodeImageResult bootstrap bound stable
    refused <- recordNodeImageResult bootstrap bound transport (pure False)
    pure (written, observed, refused)
  unless
    ( result
        == KindOperationCallbackReturned
          (NodeImageResultRecorded, NodeImageResultObserved transport, NodeImageResultRefused)
    )
    $ fail ("slow bounded admission did not confirm its durable result: " ++ show result)
  putStrLn "slow admission confirmed the durable image result"
