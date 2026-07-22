{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 1.36: handler for the @prodbox vault@ command group. @vault status@
-- probes the in-cluster Vault seal state; @vault init@ / @vault unseal@ /
-- @vault seal@ drive the host-side lifecycle through "Prodbox.Vault.Client" and
-- the encrypted unlock bundle of "Prodbox.Vault.UnlockBundle", with the pure
-- decision logic in "Prodbox.Vault.Orchestration"; @vault reconcile@ applies
-- the typed baseline mounts / auth / policy / Transit-key plan from
-- "Prodbox.Vault.Reconcile"; key rotation and @pki@ use the authenticated
-- Vault client surface after readiness checks.
module Prodbox.CLI.Vault
  ( runVaultCommand
  , VaultReconcileCommandResult (..)
  , HostVaultDirectSeam (..)
  , VaultDaemonProbe (..)
  , VaultLifecycleTransportDecision (..)
  , gatewayProbeFromResult
  , retryDaemonTransient
  , gatewayAwsVaultFields
  , gatewayEndpointFromEnv
  , runVaultBootstrapViaDaemon
  , runVaultBootstrapViaDaemonAt
  , runVaultInit
  , runVaultReconcileCommand
  , runVaultReconcileCommandDetailed
  , runVaultUnseal
  , vaultLifecycleTransportDecision
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.Aeson (Value (..), encode)
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Prodbox.Bootstrap.Broker.Client qualified as BrokerClient
import Prodbox.CLI.Command (VaultCommand (..))
import Prodbox.CLI.Output (writeOutput, writeOutputLine)
import Prodbox.Config.Tier0
  ( writeTier0FloorPreservingParameters
  )
import Prodbox.Gateway.Client qualified as GatewayClient
import Prodbox.Gateway.Types (PeerEndpoint)
import Prodbox.Host (defaultGatewayNodePort)
import Prodbox.Http.Client (HttpError (..), renderHttpError)
import Prodbox.Infra.MinioBackend (withMinioPortForward)
import Prodbox.Retry (RetryPolicy (..), retryDelayMicros)
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.SecretRef
  ( SecretRef (..)
  , VaultSecretRef (..)
  )
import Prodbox.Vault.BootstrapBundle
  ( bootstrapObjectStoreConfig
  , bootstrapUnlockBundleKey
  , getBundleObject
  , putBundleObject
  )
import Prodbox.Vault.Client
  ( BootstrapAction (..)
  , SealStatus (sealStatusSealed)
  , VaultAddress (..)
  , VaultToken (..)
  , bootstrapAction
  , initResponseToUnlockBundle
  , vaultInit
  , vaultListMounts
  , vaultMountType
  , vaultPkiIssueTestCertificate
  , vaultRotateTransitKey
  , vaultSeal
  , vaultSealStatus
  , vaultSubmitUnseal
  )
import Prodbox.Vault.Host
  ( bootstrapBundleTestFileName
  , loadAndDecryptBundle
  , loadReadyVaultRootToken
  , obtainNewOperatorPassword
  , obtainOperatorPassword
  , resolveHostVaultAddress
  )
import Prodbox.Vault.Orchestration
  ( UnsealOutcome (..)
  , UnsealStep (..)
  , clusterEstablishedMarkerPath
  , interpretUnsealProgress
  , planUnseal
  )
import Prodbox.Vault.Reconcile
  ( VaultReconcileStep
  , defaultVaultReconcilePlan
  , renderVaultReconcileError
  , renderVaultReconcileStep
  , runVaultReconcile
  )
import Prodbox.Vault.Seal
  ( VaultSealMode (..)
  , defaultRootShamirSealConfig
  , initRequestForSealMode
  )
import Prodbox.Vault.Status
  ( renderSealStatus
  , renderVaultUnreachableStatus
  )
import Prodbox.Vault.UnlockBundle
  ( UnlockBundle (..)
  , decryptUnlockBundle
  , encryptUnlockBundle
  , renderUnlockBundleError
  )
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeDirectory, (</>))

-- | The cluster id stamped into the unlock bundle. A wired cluster-id source is
-- a follow-up (Sprint 1.38 in-force config / cluster federation).
defaultClusterId :: Text
defaultClusterId = "prodbox-home"

data VaultDaemonProbe
  = VaultDaemonReachable
  | VaultDaemonUnavailable String
  deriving (Eq, Show)

data HostVaultDirectSeam
  = HostVaultDirectSeamPresent
  | HostVaultDirectSeamAbsent
  deriving (Eq, Show)

data VaultLifecycleTransportDecision
  = UseDaemonVaultLifecycle
  | UseDirectHostVaultTestSeam
  | RefuseDirectHostVaultFallback String
  deriving (Eq, Show)

vaultLifecycleTransportDecision
  :: VaultDaemonProbe -> HostVaultDirectSeam -> VaultLifecycleTransportDecision
vaultLifecycleTransportDecision probe seam =
  case (probe, seam) of
    (VaultDaemonReachable, _) -> UseDaemonVaultLifecycle
    (VaultDaemonUnavailable _, HostVaultDirectSeamPresent) -> UseDirectHostVaultTestSeam
    (VaultDaemonUnavailable detail, HostVaultDirectSeamAbsent) ->
      RefuseDirectHostVaultFallback
        ( "Gateway daemon is unavailable on loopback NodePort "
            ++ show defaultGatewayNodePort
            ++ " before Vault lifecycle bootstrap: "
            ++ detail
            ++ ". Refusing direct host Vault/MinIO fallback outside explicit test seams."
        )

gatewayProbeFromResult :: Either GatewayClient.GatewayError a -> VaultDaemonProbe
gatewayProbeFromResult result =
  case result of
    Right _ -> VaultDaemonReachable
    Left (GatewayClient.GatewayTransport (HttpConnectionFailure detail)) ->
      VaultDaemonUnavailable detail
    Left (GatewayClient.GatewayTransport (HttpTimeout detail)) ->
      VaultDaemonUnavailable detail
    Left _ -> VaultDaemonReachable

gatewayEndpointFromEnv :: IO PeerEndpoint
gatewayEndpointFromEnv = do
  override <- lookupEnv "PRODBOX_TEST_GATEWAY_NODEPORT"
  let port = maybe defaultGatewayNodePort parseGatewayNodePort override
  pure (GatewayClient.hostLoopbackGatewayEndpoint port)

parseGatewayNodePort :: String -> Int
parseGatewayNodePort raw =
  case reads raw of
    [(port, "")] | port > 0 -> port
    _ -> defaultGatewayNodePort

resolveVaultLifecycleTransport :: IO VaultLifecycleTransportDecision
resolveVaultLifecycleTransport = do
  endpoint <- gatewayEndpointFromEnv
  seam <- detectHostVaultDirectSeam
  -- With no host-Vault test seam, a 'VaultDaemonUnavailable' probe result would
  -- REFUSE (no fallback), so a transient connection failure during a daemon
  -- restart window (e.g. the destructive Phase 1.6 chart cycle rolling the
  -- gateway Deployments) would abort the lifecycle command. Bridge that window
  -- by retrying the readiness probe. With a test seam present a down daemon
  -- should fall back to the seam immediately, so probe just once.
  probeResult <- case seam of
    HostVaultDirectSeamAbsent ->
      retryDaemonTransient
        GatewayClient.daemonRestartBridgeRetryPolicy
        "gateway daemon readiness probe"
        (GatewayClient.queryState endpoint)
    HostVaultDirectSeamPresent -> GatewayClient.queryState endpoint
  pure (vaultLifecycleTransportDecision (gatewayProbeFromResult probeResult) seam)

detectHostVaultDirectSeam :: IO HostVaultDirectSeam
detectHostVaultDirectSeam = do
  values <- mapM lookupEnv hostVaultDirectSeamEnvVars
  pure $
    if any (maybe False (not . null)) values
      then HostVaultDirectSeamPresent
      else HostVaultDirectSeamAbsent

hostVaultDirectSeamEnvVars :: [String]
hostVaultDirectSeamEnvVars =
  [ "PRODBOX_TEST_HOST_VAULT_ADDR"
  , "PRODBOX_TEST_BOOTSTRAP_BUNDLE_DIR"
  , "PRODBOX_TEST_HOST_VAULT_TOKEN"
  , "PRODBOX_TEST_CLUSTER_VAULT_STATUS"
  , "PRODBOX_TEST_HOST_VAULT_KV"
  , "PRODBOX_TEST_HOST_VAULT_KV_DIR"
  ]

runVaultCommand :: FilePath -> VaultCommand -> IO ExitCode
runVaultCommand repoRoot command =
  case command of
    VaultStatus ->
      runDaemonPreferredVaultCommand repoRoot runDirectVaultStatus runDaemonVaultStatus
    VaultInit ->
      runDaemonPreferredVaultCommand
        repoRoot
        (runDirectVaultInit repoRoot)
        (runVaultBootstrapViaDaemon repoRoot)
    VaultUnseal ->
      runDaemonPreferredVaultCommand
        repoRoot
        (runDirectVaultUnseal repoRoot)
        (runVaultBootstrapViaDaemon repoRoot)
    VaultReconcile ->
      runDaemonPreferredVaultCommand
        repoRoot
        (runDirectVaultReconcile repoRoot)
        (runVaultBootstrapViaDaemon repoRoot)
    VaultSeal ->
      runDaemonPreferredVaultCommand repoRoot (runDirectVaultSeal repoRoot) (runDaemonVaultSeal repoRoot)
    VaultRotateUnlockBundle ->
      runDaemonPreferredVaultCommand
        repoRoot
        (runVaultRotateUnlockBundle repoRoot)
        (runDaemonVaultRotateUnlockBundle repoRoot)
    VaultRotateTransitKey keyName ->
      runDaemonPreferredVaultCommand
        repoRoot
        (runDirectVaultRotateTransitKey repoRoot (Text.pack keyName))
        (runDaemonVaultRotateTransitKey repoRoot (Text.pack keyName))
    VaultPkiStatus ->
      runDaemonPreferredVaultCommand
        repoRoot
        (runDirectVaultPkiStatus repoRoot)
        (runDaemonVaultPkiStatus repoRoot)
    VaultPkiIssueTestCert ->
      runDaemonPreferredVaultCommand
        repoRoot
        (runDirectVaultPkiIssueTestCert repoRoot)
        (runDaemonVaultPkiIssueTestCert repoRoot)

runDaemonPreferredVaultCommand :: FilePath -> IO ExitCode -> IO ExitCode -> IO ExitCode
runDaemonPreferredVaultCommand _repoRoot directTestSeamAction daemonAction = do
  decision <- resolveVaultLifecycleTransport
  case decision of
    UseDaemonVaultLifecycle -> daemonAction
    UseDirectHostVaultTestSeam -> directTestSeamAction
    RefuseDirectHostVaultFallback message -> do
      writeOutput message
      pure (ExitFailure 1)

runDirectVaultStatus :: IO ExitCode
runDirectVaultStatus = do
  address <- resolveHostVaultAddress
  result <- vaultSealStatus address
  case result of
    Left err -> do
      writeOutput (unreachableMessage address err)
      pure (ExitFailure 1)
    Right status -> do
      writeOutput (renderSealStatus status)
      pure ExitSuccess

runDirectVaultInit :: FilePath -> IO ExitCode
runDirectVaultInit repoRoot = do
  address <- resolveHostVaultAddress
  runVaultInit repoRoot address

runDirectVaultUnseal :: FilePath -> IO ExitCode
runDirectVaultUnseal repoRoot = do
  address <- resolveHostVaultAddress
  runVaultUnseal repoRoot address

runDirectVaultSeal :: FilePath -> IO ExitCode
runDirectVaultSeal repoRoot = do
  address <- resolveHostVaultAddress
  runVaultSeal repoRoot address

runDirectVaultReconcile :: FilePath -> IO ExitCode
runDirectVaultReconcile repoRoot = do
  address <- resolveHostVaultAddress
  runVaultReconcileCommand repoRoot address

runDirectVaultRotateTransitKey :: FilePath -> Text -> IO ExitCode
runDirectVaultRotateTransitKey repoRoot keyName = do
  address <- resolveHostVaultAddress
  runVaultRotateTransitKeyCommand repoRoot address keyName

runDirectVaultPkiStatus :: FilePath -> IO ExitCode
runDirectVaultPkiStatus repoRoot = do
  address <- resolveHostVaultAddress
  runVaultPkiStatus repoRoot address

runDirectVaultPkiIssueTestCert :: FilePath -> IO ExitCode
runDirectVaultPkiIssueTestCert repoRoot = do
  address <- resolveHostVaultAddress
  runVaultPkiIssueTestCert repoRoot address

runVaultBootstrapViaDaemon :: FilePath -> IO ExitCode
runVaultBootstrapViaDaemon repoRoot = do
  endpoint <- gatewayEndpointFromEnv
  runVaultBootstrapViaDaemonAt repoRoot endpoint

-- | Endpoint-explicit daemon bootstrap used by substrates whose gateway is
-- reached through a bounded port-forward bracket. The home wrapper above
-- retains the environment-derived NodePort behaviour.
runVaultBootstrapViaDaemonAt :: FilePath -> PeerEndpoint -> IO ExitCode
runVaultBootstrapViaDaemonAt repoRoot endpoint = do
  passwordResult <- obtainOperatorPassword repoRoot
  case passwordResult of
    Left err -> do
      writeOutput err
      pure (ExitFailure 1)
    Right password -> do
      result <-
        retryBrokerTransient
          GatewayClient.daemonRestartBridgeRetryPolicy
          "daemon-mediated Vault bootstrap"
          (BrokerClient.ensureVaultBootstrapLegacy endpoint password)
      case result of
        Left err -> do
          writeOutput ("broker-mediated Vault bootstrap failed: " ++ BrokerClient.renderBrokerError err)
          pure (ExitFailure 1)
        Right value -> do
          writeOutput ("Vault daemon bootstrap complete: " ++ renderJsonValue value)
          pure ExitSuccess

-- | Retry a daemon-mediated Vault command on TRANSIENT transport failures only
-- ('GatewayClient.gatewayErrorIsTransient'), logging each retry so an operator
-- can see the daemon-restart bridge happening. The daemon is rolled (Deployment
-- restart) partway through a reconcile, so a probe-then-act sequence can hit the
-- restart window and get a dropped connection ('HttpConnectionFailure', e.g.
-- @NoResponseDataReceived@ / @Connection refused@) or a timeout even though the
-- daemon is moments from ready; bridge that window rather than aborting. A
-- non-transient gateway error (a definite HTTP status / decode / payload error)
-- is the daemon answering with a real rejection and fails immediately.
retryDaemonTransient
  :: RetryPolicy
  -> String
  -> IO (Either GatewayClient.GatewayError a)
  -> IO (Either GatewayClient.GatewayError a)
retryDaemonTransient policy label action = go 0
 where
  go attemptIndex = do
    result <- action
    case result of
      Right _ -> pure result
      Left err
        | GatewayClient.gatewayErrorIsTransient err
        , attemptIndex + 1 < retryPolicyMaxAttempts policy -> do
            writeOutput
              ( label
                  ++ ": transient daemon transport failure ("
                  ++ GatewayClient.renderGatewayError err
                  ++ "); retrying (attempt "
                  ++ show (attemptIndex + 2)
                  ++ "/"
                  ++ show (retryPolicyMaxAttempts policy)
                  ++ ")"
              )
            threadDelay (retryDelayMicros policy attemptIndex)
            go (attemptIndex + 1)
        | otherwise -> pure result

retryBrokerTransient
  :: RetryPolicy
  -> String
  -> IO (Either BrokerClient.BrokerError a)
  -> IO (Either BrokerClient.BrokerError a)
retryBrokerTransient policy label action = go 0
 where
  go attemptIndex = do
    result <- action
    case result of
      Right _ -> pure result
      Left err
        | BrokerClient.brokerErrorIsTransient err
        , attemptIndex + 1 < retryPolicyMaxAttempts policy -> do
            writeOutput
              ( label
                  ++ ": transient broker transport failure ("
                  ++ BrokerClient.renderBrokerError err
                  ++ "); retrying (attempt "
                  ++ show (attemptIndex + 2)
                  ++ "/"
                  ++ show (retryPolicyMaxAttempts policy)
                  ++ ")"
              )
            threadDelay (retryDelayMicros policy attemptIndex)
            go (attemptIndex + 1)
        | otherwise -> pure result

runDaemonVaultStatus :: IO ExitCode
runDaemonVaultStatus = do
  endpoint <- gatewayEndpointFromEnv
  result <- BrokerClient.queryVaultStatusLegacy endpoint
  case result of
    Left err -> do
      writeOutput ("broker-mediated Vault status failed: " ++ BrokerClient.renderBrokerError err)
      pure (ExitFailure 1)
    Right status -> do
      writeOutput (renderSealStatus status)
      pure ExitSuccess

runDaemonVaultSeal :: FilePath -> IO ExitCode
runDaemonVaultSeal repoRoot =
  runDaemonPasswordAction repoRoot BrokerClient.sealVaultLegacy $ \_ -> do
    writeOutput "Vault sealed."
    pure ExitSuccess

runDaemonVaultRotateUnlockBundle :: FilePath -> IO ExitCode
runDaemonVaultRotateUnlockBundle repoRoot = do
  passwordResult <- obtainOperatorPassword repoRoot
  newPasswordResult <- obtainNewOperatorPassword repoRoot
  case (passwordResult, newPasswordResult) of
    (Left err, _) -> writeOutput err >> pure (ExitFailure 1)
    (_, Left err) -> writeOutput err >> pure (ExitFailure 1)
    (Right password, Right newPassword) -> do
      endpoint <- gatewayEndpointFromEnv
      result <- BrokerClient.rotateVaultUnlockBundleLegacy endpoint password newPassword
      case result of
        Left err -> do
          writeOutput
            ("broker-mediated Vault unlock-bundle rotation failed: " ++ BrokerClient.renderBrokerError err)
          pure (ExitFailure 1)
        Right _ -> do
          writeOutput "Vault unlock bundle re-encrypted in the durable MinIO bucket."
          pure ExitSuccess

runDaemonVaultRotateTransitKey :: FilePath -> Text -> IO ExitCode
runDaemonVaultRotateTransitKey repoRoot keyName =
  runDaemonPasswordAction
    repoRoot
    (\endpoint password -> BrokerClient.rotateVaultTransitKeyLegacy endpoint password keyName)
    $ \_ -> do
      writeOutput ("Vault Transit key rotated: " ++ Text.unpack keyName)
      pure ExitSuccess

runDaemonVaultPkiStatus :: FilePath -> IO ExitCode
runDaemonVaultPkiStatus repoRoot =
  runDaemonPasswordAction
    repoRoot
    BrokerClient.queryVaultPkiStatusLegacy
    handleDaemonVaultPkiStatusResponse

handleDaemonVaultPkiStatusResponse :: Value -> IO ExitCode
handleDaemonVaultPkiStatusResponse value =
  case jsonTextField "status" value of
    Just "present" -> do
      writeOutput "Vault PKI: pki mount present."
      pure ExitSuccess
    Just "missing" -> do
      writeOutput "Vault PKI: pki mount missing; run `prodbox vault reconcile`."
      pure (ExitFailure 1)
    _ -> do
      writeOutput ("Vault PKI status response: " ++ renderJsonValue value)
      pure ExitSuccess

runDaemonVaultPkiIssueTestCert :: FilePath -> IO ExitCode
runDaemonVaultPkiIssueTestCert repoRoot =
  runDaemonPasswordAction
    repoRoot
    BrokerClient.issueVaultPkiTestCertLegacy
    handleDaemonVaultPkiIssueTestCertResponse

handleDaemonVaultPkiIssueTestCertResponse :: Value -> IO ExitCode
handleDaemonVaultPkiIssueTestCertResponse value =
  case jsonTextField "certificate" value of
    Just certPem -> do
      writeOutput ("Vault PKI test certificate issued:\n" ++ Text.unpack certPem)
      pure ExitSuccess
    Nothing -> do
      writeOutput ("Vault PKI test certificate response: " ++ renderJsonValue value)
      pure ExitSuccess

runDaemonPasswordAction
  :: FilePath
  -> (PeerEndpoint -> Text -> IO (Either BrokerClient.BrokerError Value))
  -> (Value -> IO ExitCode)
  -> IO ExitCode
runDaemonPasswordAction repoRoot action onSuccess = do
  passwordResult <- obtainOperatorPassword repoRoot
  case passwordResult of
    Left err -> do
      writeOutput err
      pure (ExitFailure 1)
    Right password -> do
      endpoint <- gatewayEndpointFromEnv
      result <- action endpoint password
      case result of
        Left err -> do
          writeOutput ("broker-mediated Vault command failed: " ++ BrokerClient.renderBrokerError err)
          pure (ExitFailure 1)
        Right value -> onSuccess value

jsonTextField :: Text -> Value -> Maybe Text
jsonTextField name value =
  case value of
    Object fields ->
      case AesonKeyMap.lookup (AesonKey.fromText name) fields of
        Just (String textValue) -> Just textValue
        _ -> Nothing
    _ -> Nothing

renderJsonValue :: Value -> String
renderJsonValue = BL8.unpack . encode

-- | @prodbox vault init@: initialize an empty Vault exactly once, capturing the
-- unseal/recovery keys + root token into the encrypted unlock bundle. An
-- already-initialized Vault is an idempotent no-op success — 'vaultInit' is
-- never called against existing state.
runVaultInit :: FilePath -> VaultAddress -> IO ExitCode
runVaultInit repoRoot address = do
  statusResult <- vaultSealStatus address
  case statusResult of
    Left err -> do
      writeOutput (unreachableMessage address err)
      pure (ExitFailure 1)
    Right status -> case bootstrapAction status of
      BootstrapInitialize -> initFreshVault repoRoot address
      _ -> do
        writeOutput
          "Vault is already initialized; refusing to re-initialize (would destroy existing state). Run `prodbox vault unseal`."
        pure ExitSuccess

initFreshVault :: FilePath -> VaultAddress -> IO ExitCode
initFreshVault repoRoot address = do
  -- 'runVaultInit' only calls this when Vault is uninitialized, so any unlock
  -- bundle already in MinIO is for a now-gone Vault (a wiped Vault PV) and is
  -- safe to overwrite — there is no separate host-disk bundle to reconcile.
  passwordResult <- obtainOperatorPassword repoRoot
  case passwordResult of
    Left err -> do
      writeOutput err
      pure (ExitFailure 1)
    Right password -> do
      initResult <-
        vaultInit
          address
          (initRequestForSealMode (VaultSealRootShamir defaultRootShamirSealConfig))
      case initResult of
        Left err -> do
          writeOutput ("Vault init failed: " ++ renderHttpError err)
          pure (ExitFailure 1)
        Right initResponse -> do
          createdAt <- iso8601Now
          let bundle =
                initResponseToUnlockBundle defaultClusterId address createdAt initResponse
          encryptResult <- encryptUnlockBundle password bundle
          case encryptResult of
            Left err -> do
              writeOutput ("unlock bundle encryption failed: " ++ renderUnlockBundleError err)
              pure (ExitFailure 1)
            Right envelopeBytes -> do
              -- Sprint 7.25 (disk-free): the unlock bundle lives ONLY in the
              -- durable MinIO bucket — there is no host-disk copy. The MinIO
              -- write is REQUIRED: if it fails, init fails LOUDLY, because the
              -- unseal material exists nowhere else (the cluster cannot be
              -- unsealed). MinIO is reachable here because it is brought up
              -- BEFORE the Vault lifecycle (it depends only on the cluster).
              minioWriteResult <- writeBootstrapBundleToMinio password envelopeBytes
              case minioWriteResult of
                Left writeErr -> do
                  writeOutput
                    ( "Vault initialized but the REQUIRED Tier-1 unlock-bundle write to the durable "
                        ++ "MinIO bucket at "
                        ++ Text.unpack bootstrapUnlockBundleKey
                        ++ " FAILED: "
                        ++ writeErr
                        ++ ". The cluster is initialized but has NO unlock bundle, so it cannot be "
                        ++ "unsealed. RECOVERY: ensure MinIO is running, then wipe the Vault PV "
                        ++ "(`.data/vault`) and re-run `prodbox cluster reconcile` to re-initialize."
                    )
                  pure (ExitFailure 1)
                Right () -> do
                  -- Sprint 1.39 (P2): the Tier-0 basics floor write is a
                  -- REQUIRED part of init success. Vault is now stamped
                  -- initialized; if the floor write fails we must fail LOUDLY
                  -- rather than leave the cluster init'd-but-floor-less (a
                  -- silent inconsistent state that breaks every
                  -- `loadUnencryptedBasics` consumer). The next
                  -- `prodbox cluster reconcile` self-heals the floor
                  -- (`ensureBasicsFloor`), so the recovery is automatic — but
                  -- init must still surface the failure here.
                  basicsResult <- writeTier0BasicsFloor repoRoot address
                  case basicsResult of
                    Left err -> do
                      writeOutput
                        ( "Vault initialized and the unlock bundle written to the durable MinIO "
                            ++ "bucket, but the REQUIRED Tier-0 basics floor write FAILED: "
                            ++ err
                            ++ ". The cluster is initialized but has no sealed-Vault basics floor; "
                            ++ "every `loadUnencryptedBasics` consumer (per-run Pulumi destroy, AWS "
                            ++ "provider credentials, cluster reconcile) will fail until the floor "
                            ++ "exists. RECOVERY: re-run `prodbox cluster reconcile` (it self-heals "
                            ++ "the floor idempotently after unseal), or fix the underlying write "
                            ++ "error above and retry."
                        )
                      pure (ExitFailure 1)
                    Right () -> do
                      -- Sprint 7.25: stamp the NON-SECRET cluster-established
                      -- marker on host disk so the config loader can tell an
                      -- established cluster (read the in-force SSoT) from a
                      -- pre-establishment one (read the seed) without a MinIO
                      -- port-forward. The unlock material itself is NOT here — it
                      -- lives only in MinIO. This empty marker unseals nothing.
                      let markerPath = clusterEstablishedMarkerPath repoRoot
                      createDirectoryIfMissing True (takeDirectory markerPath)
                      writeFile
                        markerPath
                        "prodbox cluster-established marker (Sprint 7.25; non-secret; unseals nothing)\n"
                      writeOutput
                        ( "Vault initialized; encrypted unlock bundle written to the durable MinIO "
                            ++ "bucket at "
                            ++ Text.unpack bootstrapUnlockBundleKey
                            ++ ". Keep the unlock password safe — it is the only way to unseal this cluster."
                        )
                      pure ExitSuccess

-- | Sprint 1.39: establish the Tier-0 binary context as part of first-ever
-- bring-up. Once @vault init@ has stamped the cluster identity, write
-- @prodbox.dhall@ (the non-secret @{ parameters, context, witness }@ record),
-- which is also the sole source of the dependency-free sealed-Vault bootstrap
-- floor — the floor is projected from this record's @context@ at read time
-- rather than relying on a hard-coded default cluster id (Sprint 7.18: there is
-- no separate derived @prodbox-basics.json@ artifact). The cluster id and Vault
-- address stamped here match the ones written into the unlock bundle.
writeTier0BasicsFloor :: FilePath -> VaultAddress -> IO (Either String ())
writeTier0BasicsFloor repoRoot address =
  -- Sprint 1.42 Part B / Sprint 7.25: preserve any operator-authored
  -- `parameters`/`witness` an earlier `config setup` (or the test harness) wrote
  -- to prodbox.dhall; only stamp the cluster identity into the `context`. There
  -- is NO default fallback — if prodbox.dhall is absent this fails fast.
  writeTier0FloorPreservingParameters repoRoot defaultClusterId (unVaultAddress address)

-- | Sprint 7.25 (disk-free): write the password-AEAD unlock-bundle envelope to
-- the durable MinIO bucket at the fixed bootstrap key — the SOLE home for the
-- bundle (no host-disk copy). The bundle is Tier-1 and root-cluster-only;
-- @vault init@ always initializes the root with Shamir seal
-- ('VaultSealRootShamir'), so this path is reached only for the root cluster
-- (child clusters use transit-seal and never call 'initFreshVault').
--
-- The write uses the STATIC MinIO root credential ('bootstrapObjectStoreConfig')
-- and is REQUIRED-AND-VERIFIED: open the local port-forward, write, then read
-- back and DECRYPT with the operator password (proving the object is usable at
-- unseal). ANY failure (MinIO unreachable, write error, undecryptable read-back)
-- is returned as @Left@ so the caller fails LOUDLY — there is no disk fallback,
-- so a silent failure would brick the cluster (no way to unseal).
writeBootstrapBundleToMinio :: Text -> BS.ByteString -> IO (Either String ())
writeBootstrapBundleToMinio password envelopeBytes = do
  -- Sprint 7.25 test seam: when PRODBOX_TEST_BOOTSTRAP_BUNDLE_DIR is set, write
  -- the bundle to a local file instead of MinIO (mirrors the read seam in
  -- 'fetchBootstrapBundleEnvelope'), so the host-only vault-lifecycle integration
  -- test can exercise init/rotate without a real cluster MinIO. Production never
  -- sets this var, so the bundle always lives in the durable MinIO bucket.
  testDir <- lookupEnv "PRODBOX_TEST_BOOTSTRAP_BUNDLE_DIR"
  case testDir of
    Just dir -> do
      let path = dir </> bootstrapBundleTestFileName
      createDirectoryIfMissing True dir
      writeResult <- try (BS.writeFile path envelopeBytes) :: IO (Either SomeException ())
      case writeResult of
        Left err -> pure (Left ("test bootstrap-bundle write failed: " ++ show err))
        Right () -> do
          writeOutputLine
            ("Tier-1 unlock bundle written to the test bootstrap-bundle file at " ++ path ++ ".")
          pure (Right ())
    Nothing -> writeBootstrapBundleToMinioReal password envelopeBytes

-- | The real MinIO-backed bootstrap-bundle write (Sprint 7.25). See
-- 'writeBootstrapBundleToMinio' for the doctrine; this is the production path.
writeBootstrapBundleToMinioReal :: Text -> BS.ByteString -> IO (Either String ())
writeBootstrapBundleToMinioReal password envelopeBytes = do
  result <-
    withMinioPortForward $ \localPort -> do
      let config = bootstrapObjectStoreConfig localPort
      putResult <- putBundleObject config envelopeBytes
      case putResult of
        Left err -> pure (Left ("write failed: " ++ err))
        Right () -> do
          readBack <- getBundleObject config
          -- Verify the read-back by DECRYPTING it with the operator password —
          -- proves the object is actually usable at unseal, not merely byte-equal.
          pure $ case readBack of
            Left err -> Left ("read-back failed: " ++ err)
            Right Nothing ->
              Left ("read-back returned no object at " ++ Text.unpack bootstrapUnlockBundleKey)
            Right (Just bytes) ->
              case decryptUnlockBundle password bytes of
                Right _ -> Right ()
                Left decErr ->
                  Left ("read-back is PRESENT but UNDECRYPTABLE (" ++ renderUnlockBundleError decErr ++ ")")
  case result of
    Left portErr -> pure (Left ("MinIO unreachable: " ++ portErr))
    Right (Left err) -> pure (Left err)
    Right (Right ()) -> do
      writeOutputLine
        ( "Tier-1 unlock bundle written to the durable MinIO bucket at "
            ++ Text.unpack bootstrapUnlockBundleKey
            ++ " (verified by decrypting the read-back)."
        )
      pure (Right ())

-- | @prodbox vault unseal@: read and decrypt the unlock bundle, then submit its
-- unseal key shares until the Vault reports unsealed.
runVaultUnseal :: FilePath -> VaultAddress -> IO ExitCode
runVaultUnseal repoRoot address = do
  statusResult <- vaultSealStatus address
  case statusResult of
    Left err -> do
      writeOutput (unreachableMessage address err)
      pure (ExitFailure 1)
    Right status
      | not (sealStatusSealed status) -> do
          writeOutput "Vault already unsealed."
          pure ExitSuccess
      | otherwise -> do
          bundleResult <- loadAndDecryptBundle repoRoot
          case bundleResult of
            Left err -> do
              writeOutput err
              pure (ExitFailure 1)
            Right bundle ->
              case planUnseal status (unlockBundleUnsealKeys bundle) of
                Left planErr -> do
                  writeOutput ("unseal plan failed: " ++ planErr)
                  pure (ExitFailure 1)
                Right steps -> submitUnsealSteps address steps

submitUnsealSteps :: VaultAddress -> [UnsealStep] -> IO ExitCode
submitUnsealSteps _ [] = do
  writeOutput
    "unseal consumed every key share but Vault is still sealed; the bundle may not match this Vault."
  pure (ExitFailure 1)
submitUnsealSteps address (step : rest) = do
  submitResult <- vaultSubmitUnseal address (unsealStepKey step)
  case submitResult of
    Left err -> do
      writeOutput ("unseal submission failed: " ++ renderHttpError err)
      pure (ExitFailure 1)
    Right newStatus -> case interpretUnsealProgress newStatus step of
      UnsealCompleted -> do
        writeOutput "Vault unsealed."
        pure ExitSuccess
      UnsealAdvanced _ -> submitUnsealSteps address rest
      UnsealStalled -> do
        writeOutput
          "unseal stalled — a key share did not advance progress; the bundle may not match this Vault."
        pure (ExitFailure 1)

-- | @prodbox vault seal@: re-seal the Vault using the root token recovered from
-- the decrypted unlock bundle.
runVaultSeal :: FilePath -> VaultAddress -> IO ExitCode
runVaultSeal repoRoot address = do
  bundleResult <- loadAndDecryptBundle repoRoot
  case bundleResult of
    Left err -> do
      writeOutput err
      pure (ExitFailure 1)
    Right bundle -> do
      sealResult <- vaultSeal address (VaultToken (unlockBundleInitialRootToken bundle))
      case sealResult of
        Left err -> do
          writeOutput ("Vault seal failed: " ++ renderHttpError err)
          pure (ExitFailure 1)
        Right () -> do
          writeOutput "Vault sealed."
          pure ExitSuccess

-- | @prodbox vault reconcile@: require initialized+unsealed Vault, recover the
-- root token from the encrypted unlock bundle, then apply the baseline Vault
-- mounts / auth / policy / Transit-key / Kubernetes-role plan.
data VaultReconcileCommandResult = VaultReconcileCommandResult
  { vaultReconcileCommandExitCode :: ExitCode
  , vaultReconcileCommandSteps :: [VaultReconcileStep]
  }
  deriving (Eq, Show)

runVaultReconcileCommand :: FilePath -> VaultAddress -> IO ExitCode
runVaultReconcileCommand repoRoot address =
  vaultReconcileCommandExitCode <$> runVaultReconcileCommandDetailed repoRoot address

runVaultReconcileCommandDetailed :: FilePath -> VaultAddress -> IO VaultReconcileCommandResult
runVaultReconcileCommandDetailed repoRoot address = do
  tokenResult <- loadReadyVaultRootToken repoRoot address
  case tokenResult of
    Left err -> do
      writeOutput err
      pure (VaultReconcileCommandResult (ExitFailure 1) [])
    Right token -> do
      reconcileResult <- runVaultReconcile address token defaultVaultReconcilePlan
      case reconcileResult of
        Left err -> do
          writeOutput ("Vault reconcile failed: " ++ renderVaultReconcileError err)
          pure (VaultReconcileCommandResult (ExitFailure 1) [])
        Right steps -> do
          gatewayAwsResult <- writeGatewayAwsVaultSecret repoRoot address token
          case gatewayAwsResult of
            Left err -> do
              writeOutput ("Vault reconcile failed: " ++ err)
              pure (VaultReconcileCommandResult (ExitFailure 1) steps)
            Right gatewayAwsLine -> do
              writeOutput
                ( unlines
                    ( "Vault reconcile complete:"
                        : map (("  " ++) . renderVaultReconcileStep) steps
                        ++ ["  " ++ gatewayAwsLine]
                    )
                )
              pure (VaultReconcileCommandResult ExitSuccess steps)

writeGatewayAwsVaultSecret :: FilePath -> VaultAddress -> VaultToken -> IO (Either String String)
writeGatewayAwsVaultSecret repoRoot _address _token = do
  -- `vault reconcile` is a bring-up step that precedes the in-force object-store
  -- read (config_doctrine.md §9, the bootstrap exception), so it reads the
  -- seed/propose `prodbox.dhall` for the gateway AWS SecretRef shape
  -- rather than routing through the Vault/MinIO in-force loader — which is not
  -- yet reachable during bring-up. This also keeps reconcile decoupled from the
  -- Sprint 1.39 Tier-0 basics floor that `vault init` now writes before
  -- reconcile runs.
  settingsResult <- Settings.validateAndLoadBootstrapSettings repoRoot
  case settingsResult of
    Left err -> pure (Left ("load gateway AWS credentials from prodbox.dhall: " ++ err))
    Right settings ->
      case gatewayAwsVaultFields (Settings.aws (Settings.validatedConfig settings)) of
        Left reason ->
          pure (Right ("secret-object secret/gateway/gateway/aws skipped (" ++ reason ++ ")"))
        Right () ->
          pure (Right "secret-object secret/gateway/gateway/aws declared (managed by prodbox aws setup)")

gatewayAwsVaultFields :: Settings.AwsCredentialsRef -> Either String ()
gatewayAwsVaultFields refs =
  case ( validateGatewayAwsVaultRef
           "aws.access_key_id"
           "access_key_id"
           (Settings.awsCredentialAccessKeyId refs)
       , validateGatewayAwsVaultRef
           "aws.secret_access_key"
           "secret_access_key"
           (Settings.awsCredentialSecretAccessKey refs)
       , validateGatewayAwsSessionTokenRef refs
       , validateGatewayAwsRegion refs
       ) of
    (Right (), Right (), Right (), Right ()) -> Right ()
    (Left err, _, _, _) -> Left err
    (_, Left err, _, _) -> Left err
    (_, _, Left err, _) -> Left err
    (_, _, _, Left err) -> Left err

validateGatewayAwsVaultRef :: String -> Text -> SecretRef -> Either String ()
validateGatewayAwsVaultRef fieldName expectedField ref =
  case ref of
    SecretRefVault vaultRef
      | vaultSecretMount vaultRef == "secret"
          && vaultSecretPath vaultRef == "gateway/gateway/aws"
          && vaultSecretField vaultRef == expectedField ->
          Right ()
      | otherwise ->
          Left
            ( fieldName
                ++ " must reference SecretRef.Vault secret/gateway/gateway/aws#"
                ++ Text.unpack expectedField
            )
    _ -> Left (fieldName ++ " must be a SecretRef.Vault reference")

validateGatewayAwsSessionTokenRef :: Settings.AwsCredentialsRef -> Either String ()
validateGatewayAwsSessionTokenRef refs =
  case Settings.awsCredentialSessionToken refs of
    Nothing -> Right ()
    Just ref -> validateGatewayAwsVaultRef "aws.session_token" "session_token" ref

validateGatewayAwsRegion :: Settings.AwsCredentialsRef -> Either String ()
validateGatewayAwsRegion refs =
  if Text.null (Text.strip (Settings.awsCredentialRegion refs))
    then Left "aws.region must not be empty"
    else Right ()

-- | @prodbox vault rotate-unlock-bundle@: re-encrypt the existing bundle under
-- a new operator password without touching Vault state.
runVaultRotateUnlockBundle :: FilePath -> IO ExitCode
runVaultRotateUnlockBundle repoRoot = do
  bundleResult <- loadAndDecryptBundle repoRoot
  case bundleResult of
    Left err -> do
      writeOutput err
      pure (ExitFailure 1)
    Right bundle -> do
      newPasswordResult <- obtainNewOperatorPassword repoRoot
      case newPasswordResult of
        Left err -> do
          writeOutput err
          pure (ExitFailure 1)
        Right newPassword -> do
          encryptResult <- encryptUnlockBundle newPassword bundle
          case encryptResult of
            Left err -> do
              writeOutput ("unlock bundle encryption failed: " ++ renderUnlockBundleError err)
              pure (ExitFailure 1)
            Right envelopeBytes -> do
              -- Sprint 7.25 (disk-free): the re-encrypted bundle is written back
              -- to the durable MinIO bucket (its sole home), not host disk.
              minioWriteResult <- writeBootstrapBundleToMinio newPassword envelopeBytes
              case minioWriteResult of
                Left writeErr -> do
                  writeOutput
                    ( "Vault unlock bundle re-encrypted but the write to the durable MinIO bucket "
                        ++ "FAILED: "
                        ++ writeErr
                        ++ ". The previous bundle is unchanged; retry once MinIO is reachable."
                    )
                  pure (ExitFailure 1)
                Right () -> do
                  writeOutput
                    ( "Vault unlock bundle re-encrypted in the durable MinIO bucket at "
                        ++ Text.unpack bootstrapUnlockBundleKey
                        ++ "."
                    )
                  pure ExitSuccess

-- | @prodbox vault rotate-transit-key KEY@: rotate a named Transit key after
-- verifying Vault is initialized and unsealed.
runVaultRotateTransitKeyCommand :: FilePath -> VaultAddress -> Text -> IO ExitCode
runVaultRotateTransitKeyCommand repoRoot address keyName =
  withReadyVaultRootToken repoRoot address $ \token -> do
    rotateResult <- vaultRotateTransitKey address token keyName
    case rotateResult of
      Left err -> do
        writeOutput ("Vault Transit key rotation failed: " ++ renderHttpError err)
        pure (ExitFailure 1)
      Right () -> do
        writeOutput ("Vault Transit key rotated: " ++ Text.unpack keyName)
        pure ExitSuccess

-- | @prodbox vault pki status@: inspect whether the baseline PKI mount exists.
runVaultPkiStatus :: FilePath -> VaultAddress -> IO ExitCode
runVaultPkiStatus repoRoot address =
  withReadyVaultRootToken repoRoot address $ \token -> do
    mountsResult <- vaultListMounts address token
    case mountsResult of
      Left err -> do
        writeOutput ("Vault PKI status failed: " ++ renderHttpError err)
        pure (ExitFailure 1)
      Right mounts ->
        case Map.lookup "pki" mounts of
          Nothing -> do
            writeOutput "Vault PKI: pki mount missing; run `prodbox vault reconcile`."
            pure (ExitFailure 1)
          Just mount
            | vaultMountType mount == "pki" -> do
                writeOutput "Vault PKI: pki mount present."
                pure ExitSuccess
            | otherwise -> do
                writeOutput
                  ( "Vault PKI: pki mount has type "
                      ++ Text.unpack (vaultMountType mount)
                      ++ "; expected pki."
                  )
                pure (ExitFailure 1)

-- | @prodbox vault pki issue-test-cert@: issue a short-lived certificate from
-- the baseline test role once the later PKI issuer sprint has configured it.
runVaultPkiIssueTestCert :: FilePath -> VaultAddress -> IO ExitCode
runVaultPkiIssueTestCert repoRoot address =
  withReadyVaultRootToken repoRoot address $ \token -> do
    issueResult <-
      vaultPkiIssueTestCertificate
        address
        token
        "prodbox-test"
        "prodbox-vault-test.internal"
        "1m"
    case issueResult of
      Left err -> do
        writeOutput ("Vault PKI test certificate failed: " ++ renderHttpError err)
        pure (ExitFailure 1)
      Right certPem -> do
        writeOutput ("Vault PKI test certificate issued:\n" ++ Text.unpack certPem)
        pure ExitSuccess

withReadyVaultRootToken :: FilePath -> VaultAddress -> (VaultToken -> IO ExitCode) -> IO ExitCode
withReadyVaultRootToken repoRoot address action = do
  tokenResult <- loadReadyVaultRootToken repoRoot address
  case tokenResult of
    Left err -> do
      writeOutput err
      pure (ExitFailure 1)
    Right token -> action token

iso8601Now :: IO Text
iso8601Now = Text.pack . iso8601Show <$> getCurrentTime

unreachableMessage :: VaultAddress -> HttpError -> String
unreachableMessage =
  renderVaultUnreachableStatus
