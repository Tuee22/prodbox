{-# LANGUAGE OverloadedStrings #-}

-- Real kubectl composition against a disposable, non-secret configuration.
-- This is read-only evidence; it does not contact or authenticate a cluster.
-- Run: cabal exec --builddir=.build -- runghc -package=prodbox -package=temporary test/qualification/KindKubeconfigSnapshot.hs
module Main (main) where

import Control.Monad (unless)
import Data.ByteString qualified as ByteString
import Prodbox.Config.BootstrapProjection
import Prodbox.Config.DeploymentScope
import Prodbox.Control.KindKubeconfigFile
import Prodbox.Control.KindKubeconfig (kindKubeconfigServer, withKindKubeconfigMaterial)
import Prodbox.Subprocess
import System.Directory
import System.Exit
import System.FilePath
import System.IO.Temp
import System.Posix.Files

main :: IO ()
main = withSystemTempDirectory "prodbox-kubectl-snapshot" $ \anchor -> do
  let selected = anchor </> "selected.dhall"
      generation = replicate 32 'a'
      config =
        "{ bootstrap = { schema_version = 1, project_anchor = \"" ++ anchor
          ++ "\", runtime_socket = \"/var/run/docker.sock\", environment = \"test\", deployment_id = \"run\", root_generation = \""
          ++ generation ++ "\", api_port = 26443, node_image = \"kindest/node@sha256:"
          ++ replicate 64 'a' ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, listen_address = \"127.0.0.1\" } }"
      document =
        unlines
          [ "apiVersion: v1", "kind: Config", "current-context: kind-prodbox-t-run"
          , "clusters:", "- name: kind-prodbox-t-run", "  cluster:"
          , "    server: https://127.0.0.1:26443", "    certificate-authority-data: Y2E="
          , "contexts:", "- name: kind-prodbox-t-run", "  context:"
          , "    cluster: kind-prodbox-t-run", "    user: kind-prodbox-t-run"
          , "users:", "- name: kind-prodbox-t-run", "  user:"
          , "    client-certificate-data: Y2VydA==", "    client-key-data: a2V5"
          ]
  writeFile selected config
  projection <- readBootstrapProjection selected >>= either (fail . show) pure
  let scope = bootstrapScope projection
      control = scopeRoot scope </> "control"
      path = control </> "kubeconfig"
      saved = control </> "saved"
  setup <- prepareFreshScope scope generation
  unless (setup == FreshScopePrepared) (fail "scope creation refused")
  createDirectory control
  setFileMode control 0o700
  writeFile path document
  setFileMode path 0o600
  result <- withKindKubeconfigSnapshotBound projection $ \bound snapshot -> do
    unless (kindKubeconfigServer bound == "https://127.0.0.1:26443") (fail "bound endpoint changed")
    withKindKubeconfigMaterial bound $ \ca _ _ -> unless (ca == "ca") (fail "bound CA changed")
    let invoke =
          captureSubprocessWithInputBounded
            (BoundedSubprocessLimits 1 8192 8192 30000000)
            ByteString.empty
            ( Subprocess "/usr/bin/kubectl"
                ["--kubeconfig", snapshot, "config", "current-context"]
                (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
                Nothing
            )
        valid outcome = case outcome of
          Right response -> processExitCode response == ExitSuccess && processStdout response == "kind-prodbox-t-run\n"
          Left _ -> False
    first <- invoke
    renameFile path saved
    writeFile path "invalid replacement"
    second <- invoke
    unless (valid first && valid second) (fail "kubectl snapshot observation failed")
    withKindKubeconfigMaterial bound $ \ca _ _ -> unless (ca == "ca") (fail "bound projection changed")
    putStrLn "kubectl read the validated snapshot before and after retained-file replacement"
  case result of
    Right () -> pure ()
    Left failure -> fail (show failure)
