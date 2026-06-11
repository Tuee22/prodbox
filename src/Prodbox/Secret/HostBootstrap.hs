{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 3.13 chunk 33 / Sprint 3.16: host-side pre-helm derived-Secret
-- bootstrap, routed through the gateway daemon's secret service.
--
-- The Sprint 3.13 doctrine has the gateway daemon write the
-- @keycloak-runtime@ / @keycloak-oidc-clients@ / Patroni Secrets via its
-- @/v1/secret/ensure-namespace@ endpoint, invoked from each chart's Helm
-- pre-install Job. The chart's own ConfigMap (Keycloak realm import) then
-- reads those Secrets via Helm @lookup@ at template render time.
--
-- This breaks on first install: Helm renders ALL templates (including
-- @lookup@) BEFORE applying pre-install hooks, so the lookup sees an
-- empty cluster and falls back to the @\"change-me\"@ placeholder
-- substituted into the realm import. Keycloak imports the realm with the
-- placeholder once, and never re-imports — direct-grant OIDC handshakes
-- 401 forever.
--
-- The fix: have the host-side @prodbox charts deploy@ flow trigger the
-- same in-cluster materialization the daemon would, BEFORE calling
-- @helm upgrade --install@. The daemon's HTTP endpoint stays as the
-- in-cluster idempotent fallback (the chart's pre-install Job still
-- runs, but on first install it sees the Secret already present and is
-- a no-op).
--
-- Sprint 3.16 closed the master-seed boundary: the host no longer reads
-- the raw seed from MinIO and derives Secret values itself. Instead it
-- POSTs to the gateway daemon's @/v1/secret/ensure-namespace@ over the
-- loopback NodePort ('Prodbox.Gateway.Client.ensureNamespace'); the
-- in-cluster daemon — the sole reader of the master seed — materializes
-- the Secrets. The host obtains only the per-Secret SHA-256 inventory in
-- the response, never the raw seed and never the plaintext derived value.
module Prodbox.Secret.HostBootstrap
  ( preApplyDerivedSecretsForRelease
  )
where

import Control.Exception (SomeException, try)
import Data.Aeson (Value, encode)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Gateway.Client (hostLoopbackGatewayEndpoint, renderGatewayError)
import Prodbox.Gateway.Client qualified as GatewayClient
import Prodbox.Host (defaultGatewayNodePort)
import Prodbox.K8s.InCluster (secretManifestJson)
import Prodbox.Result (Result (..))
import Prodbox.Secret.Derive (MasterSeed, deriveBase64Url)
import Prodbox.Secret.GatewayDeriveMode (GatewayDeriveMode (..))
import Prodbox.Secret.Inventory
  ( DerivedSecretEntry (..)
  , derivedSecretInventoryFor
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , processExitCode
  )
import System.Directory (removeFile)
import System.Exit (ExitCode (..))
import System.IO (hClose)
import System.IO.Temp (openBinaryTempFile)

-- | Materialize every @derivedSecretInventoryFor namespace release@
-- entry as a k8s @Secret@, BEFORE the caller invokes
-- @helm upgrade --install@ for the release. No-op when the inventory is
-- empty (the release has no daemon-owned derived Secrets).
--
-- The materialization runs in the in-cluster gateway daemon: the host
-- POSTs to @/v1/secret/ensure-namespace@ via
-- 'Prodbox.Gateway.Client.ensureNamespace' over the loopback NodePort and
-- the daemon — the sole reader of the master seed — writes the Secrets.
-- The host never reads the raw seed (Sprint 3.16,
-- @secret_derivation_doctrine.md §2/§5@).
--
-- The integration harness sets the gateway-derive test seam
-- ('Prodbox.TestSeam.GatewayDerive') in lieu of a running daemon; in that
-- mode this function simulates the daemon by deriving each Secret value
-- from the seam's test seed and @kubectl apply@-ing the manifests, so the
-- chunk-33 code path is still exercised without a live cluster.
preApplyDerivedSecretsForRelease :: GatewayDeriveMode -> String -> String -> IO (Either String ())
preApplyDerivedSecretsForRelease mode nsStr relStr =
  case derivedSecretInventoryFor namespace release of
    [] -> pure (Right ())
    entries ->
      case mode of
        TestSeed seed -> applyEntriesViaKubectl seed namespace entries
        ProductionGateway
          -- The gateway daemon self-bootstraps its own @gateway-event-keys@
          -- Secret after it acquires the master seed
          -- ('Prodbox.Gateway.Daemon.selfBootstrapOwnSecrets'); that is how
          -- the gateway release escapes the pre-install-vs-daemon
          -- chicken-and-egg the other charts avoid by POSTing to an
          -- already-running daemon (see the @("gateway","gateway")@ case in
          -- 'Prodbox.Secret.Inventory.derivedSecretInventoryFor'). The host
          -- must therefore NOT dial @ensure-namespace@ for the gateway's own
          -- keys before the daemon Pod exists. The integration harness
          -- simulates the daemon via the 'TestSeed' branch above.
          | release == gatewaySelfBootstrapRelease -> pure (Right ())
          | otherwise -> ensureNamespaceViaGateway namespace release
 where
  namespace = Text.pack nsStr
  release = Text.pack relStr

-- | The single Helm release whose derived Secrets the in-cluster daemon
-- materializes for itself rather than via a host @ensure-namespace@ POST.
gatewaySelfBootstrapRelease :: Text
gatewaySelfBootstrapRelease = Text.pack "gateway"

-- | Production path: trigger in-cluster materialization through the
-- gateway daemon's @ensure-namespace@ RPC. The host obtains only the
-- response inventory (Secret names + SHA-256s), never the raw seed or the
-- plaintext derived values.
ensureNamespaceViaGateway :: Text -> Text -> IO (Either String ())
ensureNamespaceViaGateway namespace release = do
  result <-
    GatewayClient.ensureNamespace
      (hostLoopbackGatewayEndpoint defaultGatewayNodePort)
      namespace
      release
  pure $ case result of
    Left err ->
      Left
        ( "gateway ensure-namespace failed for namespace `"
            ++ Text.unpack namespace
            ++ "` release `"
            ++ Text.unpack release
            ++ "`: "
            ++ renderGatewayError err
        )
    Right _ -> Right ()

applyEntriesViaKubectl :: MasterSeed -> Text -> [DerivedSecretEntry] -> IO (Either String ())
applyEntriesViaKubectl seed namespace entries = do
  let manifests = map (entryToManifest seed namespace) entries
      payload = BL.intercalate "\n---\n" (map encode manifests)
  withTempManifestFile payload $ \tmpPath -> do
    result <-
      captureSubprocessResult
        Subprocess
          { subprocessPath = "kubectl"
          , subprocessArguments = ["apply", "-f", tmpPath]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Nothing
          }
    pure $ case result of
      Failure err ->
        Left
          ( "kubectl apply failed for derived secrets in namespace `"
              ++ Text.unpack namespace
              ++ "`: "
              ++ err
          )
      Success output ->
        case processExitCode output of
          ExitSuccess -> Right ()
          ExitFailure _ ->
            Left
              ( "kubectl apply failed for derived secrets in namespace `"
                  ++ Text.unpack namespace
                  ++ "`: "
                  ++ processStderr output
                  ++ processStdout output
              )

entryToManifest :: MasterSeed -> Text -> DerivedSecretEntry -> Value
entryToManifest seed namespace entry =
  secretManifestJson
    namespace
    (derivedSecretEntryName entry)
    ( Map.fromList
        ( [(k, deriveBase64Url seed ctx) | (k, ctx) <- derivedSecretEntryDerivedFields entry]
            ++ derivedSecretEntryStaticFields entry
        )
    )

withTempManifestFile :: BL.ByteString -> (FilePath -> IO a) -> IO a
withTempManifestFile content action = do
  (tmpPath, handle) <- openBinaryTempFile "/tmp" "prodbox-host-bootstrap-.json"
  BL.hPut handle content
  hClose handle
  result <- action tmpPath
  _ <- try (removeFile tmpPath) :: IO (Either SomeException ())
  pure result
