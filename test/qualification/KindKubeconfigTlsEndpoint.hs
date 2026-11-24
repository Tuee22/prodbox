{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Disposable loopback TLS control for the sealed kubeconfig; no kind node,
-- external account, provider resource or production credential is used.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as BS8
import Data.List (isInfixOf)
import Network.Socket qualified as Socket
import Prodbox.Config.BootstrapProjection
import Prodbox.Config.DeploymentScope
import Prodbox.Control.KindKubeconfigFile
import Prodbox.Subprocess
import System.Directory (createDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process (CreateProcess (..), StdStream (NoStream), proc, readProcessWithExitCode, withCreateProcess)

main :: IO ()
main = withSystemTempDirectory "prodbox-kube-tls" $ \anchor -> do
  port <- Socket.withSocketsDo $ bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
    Socket.bind sock (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    address <- Socket.getSocketName sock
    case address of
      Socket.SockAddrInet selected _ -> pure (fromIntegral selected :: Int)
      _ -> fail "unexpected loopback socket"
  let cert = anchor </> "server.crt"
      key = anchor </> "server.key"
      otherCert = anchor </> "other.crt"
      otherKey = anchor </> "other.key"
      selected = anchor </> "selected.dhall"
      generation = replicate 32 'a'
      endpoint = "https://127.0.0.1:" ++ show port
      config = "{ bootstrap = { schema_version = 1, project_anchor = \"" ++ anchor
        ++ "\", runtime_socket = \"/var/run/docker.sock\", environment = \"test\", deployment_id = \"run\", root_generation = \""
        ++ generation ++ "\", api_port = " ++ show port ++ ", node_image = \"kindest/node@sha256:"
        ++ replicate 64 'a' ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, listen_address = \"127.0.0.1\" } }"
      generate certPath keyPath = do
        (code, _, _) <- readProcessWithExitCode "/usr/bin/openssl"
          ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=loopback-fixture", "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", keyPath, "-out", certPath] ""
        unless (code == ExitSuccess) (fail "could not generate disposable TLS material")
        setFileMode keyPath 0o600
  generate cert key
  generate otherCert otherKey
  ca <- BS.readFile cert
  clientKey <- BS.readFile key
  wrongCa <- BS.readFile otherCert
  let b64 = BS8.unpack . Base64.encode
      document selectedCa = unlines
        [ "apiVersion: v1", "kind: Config", "current-context: kind-prodbox-t-run"
        , "clusters:", "- name: kind-prodbox-t-run", "  cluster:"
        , "    server: " ++ endpoint, "    certificate-authority-data: " ++ b64 selectedCa
        , "contexts:", "- name: kind-prodbox-t-run", "  context:"
        , "    cluster: kind-prodbox-t-run", "    user: kind-prodbox-t-run"
        , "users:", "- name: kind-prodbox-t-run", "  user:"
        , "    client-certificate-data: " ++ b64 ca, "    client-key-data: " ++ b64 clientKey
        ]
  writeFile selected config
  projection <- readBootstrapProjection selected >>= either (fail . show) pure
  let scope = bootstrapScope projection
      control = scopeRoot scope </> "control"
      path = control </> "kubeconfig"
      run snapshot = captureSubprocessWithInputBounded
        (BoundedSubprocessLimits 1 65536 8192 15000000) BS.empty
        (Subprocess "/usr/bin/kubectl" ["--kubeconfig", snapshot, "--request-timeout=4s", "get", "--raw=/readyz"]
          (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]) Nothing)
      server = (proc "/usr/bin/openssl" ["s_server", "-quiet", "-www", "-accept", "127.0.0.1:" ++ show port, "-cert", cert, "-key", key])
        {std_in = NoStream, std_out = NoStream, std_err = NoStream}
  prepareFreshScope scope generation >>= \result -> unless (result == FreshScopePrepared) (fail "scope creation refused")
  createDirectory control
  setFileMode control 0o700
  writeFile path (document ca)
  setFileMode path 0o600
  withCreateProcess server $ \_ _ _ _ -> do
    threadDelay 500000
    good <- withKindKubeconfigSnapshotBound projection (\_ snapshot -> run snapshot)
    case good of
      Right (Right output) | processExitCode output == ExitSuccess -> pure ()
      _ -> fail "valid loopback TLS endpoint was not accepted"
    writeFile path (document wrongCa)
    bad <- withKindKubeconfigSnapshotBound projection (\_ snapshot -> run snapshot)
    case bad of
      Right (Right output)
        | processExitCode output /= ExitSuccess
          && "certificate signed by unknown authority" `isInfixOf` processStderr output -> pure ()
      _ -> fail "wrong CA did not produce the expected TLS verification failure"
    writeFile path (document ca)
    restored <- withKindKubeconfigSnapshotBound projection (\_ snapshot -> run snapshot)
    case restored of
      Right (Right output) | processExitCode output == ExitSuccess -> pure ()
      _ -> fail "TLS positive control did not recover"
  putStrLn "PASS sealed kubeconfig accepts the selected loopback CA and rejects a different CA"
