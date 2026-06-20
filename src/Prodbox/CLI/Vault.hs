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
  , gatewayAwsVaultFields
  , runVaultInit
  , runVaultReconcileCommand
  , runVaultReconcileCommandDetailed
  , runVaultUnseal
  )
where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Prodbox.CLI.Command (VaultCommand (..))
import Prodbox.CLI.Output (writeOutput, writeOutputLine)
import Prodbox.Config.Tier0
  ( writeTier0FloorPreservingParameters
  )
import Prodbox.Http.Client (HttpError, renderHttpError)
import Prodbox.Infra.MinioBackend (withMinioPortForward)
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.SecretRef
  ( SecretRef (..)
  , VaultSecretRef (..)
  )
import Prodbox.Vault.BootstrapBundle
  ( bootstrapObjectStoreConfig
  , bootstrapSaltForClusterId
  , bootstrapUnlockBundleKey
  , deriveBootstrapMinioCredential
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
  ( loadAndDecryptBundle
  , loadReadyVaultRootToken
  , obtainNewOperatorPassword
  , obtainOperatorPassword
  , resolveHostVaultAddress
  )
import Prodbox.Vault.Orchestration
  ( UnsealOutcome (..)
  , UnsealStep (..)
  , interpretUnsealProgress
  , planUnseal
  , vaultUnlockBundlePath
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
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeDirectory)

-- | The cluster id stamped into the unlock bundle. A wired cluster-id source is
-- a follow-up (Sprint 1.38 in-force config / cluster federation).
defaultClusterId :: Text
defaultClusterId = "prodbox-home"

runVaultCommand :: FilePath -> VaultCommand -> IO ExitCode
runVaultCommand repoRoot command = do
  address <- resolveHostVaultAddress
  case command of
    VaultStatus -> do
      result <- vaultSealStatus address
      case result of
        Left err -> do
          writeOutput (unreachableMessage address err)
          pure (ExitFailure 1)
        Right status -> do
          writeOutput (renderSealStatus status)
          pure ExitSuccess
    VaultInit -> runVaultInit repoRoot address
    VaultUnseal -> runVaultUnseal repoRoot address
    VaultSeal -> runVaultSeal repoRoot address
    VaultReconcile -> runVaultReconcileCommand repoRoot address
    VaultRotateUnlockBundle -> runVaultRotateUnlockBundle repoRoot
    VaultRotateTransitKey keyName -> runVaultRotateTransitKeyCommand repoRoot address (Text.pack keyName)
    VaultPkiStatus -> runVaultPkiStatus repoRoot address
    VaultPkiIssueTestCert -> runVaultPkiIssueTestCert repoRoot address

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
  let bundlePath = vaultUnlockBundlePath repoRoot
  bundleExists <- doesFileExist bundlePath
  if bundleExists
    then do
      writeOutput
        ( "unlock bundle already exists at "
            ++ bundlePath
            ++ " but Vault is uninitialized — manual reconciliation required"
        )
      pure (ExitFailure 1)
    else do
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
                  createDirectoryIfMissing True (takeDirectory bundlePath)
                  BS.writeFile bundlePath envelopeBytes
                  -- Sprint 7.19 (staged): DUAL-WRITE the same password-AEAD
                  -- envelope to the durable MinIO bucket at the fixed bootstrap
                  -- key, in addition to the host-disk write above (which stays
                  -- PRIMARY this stage). Best-effort-but-verified (write then
                  -- read-back); a MinIO failure logs and continues — it must not
                  -- brick init, because disk is still the load-bearing source.
                  dualWriteBootstrapBundle defaultClusterId password envelopeBytes
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
                        ( "Vault initialized and unlock bundle written to "
                            ++ bundlePath
                            ++ ", but the REQUIRED Tier-0 basics floor write FAILED: "
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
                      writeOutput
                        ( "Vault initialized; encrypted unlock bundle written to "
                            ++ bundlePath
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
  -- Sprint 1.42 Part B: preserve any operator-authored `parameters`/`witness`
  -- an earlier `config setup` wrote to prodbox.dhall; only stamp the cluster
  -- identity into the `context`. Falls back to defaultProjectConfig when no
  -- prodbox.dhall exists yet.
  writeTier0FloorPreservingParameters repoRoot defaultClusterId (unVaultAddress address)

-- | Sprint 7.19 (staged): DUAL-WRITE the password-AEAD unlock-bundle envelope
-- to the durable MinIO bucket at the fixed bootstrap key, alongside the
-- host-disk write that remains PRIMARY this stage. The bundle is Tier-1 and
-- root-cluster-only; @vault init@ always initializes the root with Shamir seal
-- ('VaultSealRootShamir'), so this path is reached only for the root cluster
-- (child clusters use transit-seal and never call 'initFreshVault'), satisfying
-- the "no bundle object for a child" constraint without a per-cluster branch.
--
-- The write is BEST-EFFORT-BUT-VERIFIED: derive the password-derived bootstrap
-- MinIO credential, open the local port-forward, write, then read back and
-- compare. ANY failure (no cluster, MinIO unreachable, mismatch) is logged and
-- swallowed — it must not brick init, because the host-disk bundle written just
-- above is still the load-bearing unseal source this stage.
--
-- Sprint 7.19 (live-proof): the reorder that makes this MinIO object the
-- PRIMARY, host-disk-free unseal source (MinIO-reachable-before-Vault-unseal +
-- MinIO-root-decoupled-from-Vault) lands here — promote this best-effort write
-- to a verified-required write and drop the disk write. NOT attempted this
-- stage.
dualWriteBootstrapBundle :: Text -> Text -> BS.ByteString -> IO ()
dualWriteBootstrapBundle clusterId password envelopeBytes =
  case deriveBootstrapMinioCredential password (bootstrapSaltForClusterId clusterId) of
    Left credErr ->
      writeOutputLine
        ( "note: skipped Tier-1 unlock-bundle MinIO dual-write (bootstrap credential derivation failed: "
            ++ renderUnlockBundleError credErr
            ++ "); the host-disk bundle remains the unseal source."
        )
    Right credential -> do
      result <-
        withMinioPortForward $ \localPort -> do
          let config = bootstrapObjectStoreConfig localPort credential
          putResult <- putBundleObject config envelopeBytes
          case putResult of
            Left err -> pure (Left (ReadBackFailed err))
            Right () -> do
              readBack <- getBundleObject config
              -- Sprint 7.19 (P3): verify the read-back by attempting to DECRYPT
              -- it with the operator password — more robust than a byte-compare,
              -- because it proves the object is actually usable at unseal, not
              -- merely byte-equal. A present-but-undecryptable read-back is a
              -- corruption (encoded as `ReadBackUndecryptable`) so the caller can
              -- log CRITICAL rather than a routine note.
              pure $ case readBack of
                Left err -> Left (ReadBackFailed ("read-back failed: " ++ err))
                Right Nothing ->
                  Left
                    ( ReadBackFailed
                        ("read-back returned no object at " ++ Text.unpack bootstrapUnlockBundleKey)
                    )
                Right (Just bytes) ->
                  case decryptUnlockBundle password bytes of
                    Right _ -> Right ()
                    Left decErr -> Left (ReadBackUndecryptable (renderUnlockBundleError decErr))
      case result of
        Right (Right ()) ->
          writeOutputLine
            ( "Tier-1 unlock bundle also written to the durable MinIO bucket at "
                ++ Text.unpack bootstrapUnlockBundleKey
                ++ " (verified by decrypting the read-back)."
            )
        Right (Left (ReadBackUndecryptable detail)) ->
          -- Present-but-undecryptable read-back: the object exists but cannot be
          -- opened with the operator password. Loud CRITICAL — the write stays
          -- best-effort (must not brick init) but this is never a routine note.
          writeOutputLine
            ( "CRITICAL: Tier-1 unlock-bundle MinIO dual-write read-back is PRESENT "
                ++ "but UNDECRYPTABLE at "
                ++ Text.unpack bootstrapUnlockBundleKey
                ++ " ("
                ++ detail
                ++ "). The durable MinIO copy is corrupt; the host-disk bundle "
                ++ "remains the load-bearing unseal source. Re-run "
                ++ "`prodbox vault rotate-unlock-bundle` to repair the MinIO copy."
            )
        Right (Left (ReadBackFailed writeErr)) ->
          writeOutputLine
            ( "note: Tier-1 unlock-bundle MinIO dual-write did not complete ("
                ++ writeErr
                ++ "); the host-disk bundle remains the unseal source."
            )
        Left portErr ->
          writeOutputLine
            ( "note: Tier-1 unlock-bundle MinIO dual-write skipped (MinIO unreachable: "
                ++ portErr
                ++ "); the host-disk bundle remains the unseal source."
            )

-- | The classified failure of the Sprint 7.19 dual-write read-back verification.
-- A present-but-undecryptable read-back ('ReadBackUndecryptable') is a corruption
-- that warrants a CRITICAL log; a plain 'ReadBackFailed' (write error, absent
-- object, read error) is a routine best-effort note.
data DualWriteReadBackError
  = ReadBackFailed String
  | ReadBackUndecryptable String
  deriving (Eq, Show)

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
              let bundlePath = vaultUnlockBundlePath repoRoot
              BS.writeFile bundlePath envelopeBytes
              writeOutput ("Vault unlock bundle re-encrypted at " ++ bundlePath ++ ".")
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
