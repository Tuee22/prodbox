{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Host-side access to the in-cluster Vault root token.
--
-- Operator/admin helper flows use this module when they must read or write
-- Vault KV from the host process. Workloads continue to use Vault Kubernetes
-- auth directly in-cluster.
module Prodbox.Vault.Host
  ( hostVaultAddress
  , loadAndDecryptBundle
  , loadReadyVaultRootToken
  , obtainNewOperatorPassword
  , obtainOperatorPassword
  , readHostVaultKvField
  , readHostVaultKvObject
  , requireReadyVault
  , resolveHostVaultAddress
  , writeHostVaultKvObject

    -- * Sprint 7.19 P3: pure bootstrap-bundle unseal-source classification
  , BootstrapMinioRead (..)
  , bootstrapBundleTestFileName

    -- * Sprint 1.43: the test-harness secrets fixture (@test-secrets.dhall@)
  , TestSecrets (..)
  , TestSecretsAdminCredentials (..)
  , AcmeEabFixture (..)
  , defaultTestSecrets
  , testSecretsPath
  , loadTestSecrets
  , seedAcmeEabFromTestSecrets
  )
where

import Control.Exception (SomeException, bracket_, try)
import Control.Monad (forM)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (FromDhall, ToDhall, auto, inputFile)
import GHC.Generics (Generic)
import Prodbox.CLI.Output (writeDiagnostic, writeDiagnosticLine, writeOutputLine)
import Prodbox.Http.Client (HttpError (..), renderHttpError)
import Prodbox.Infra.MinioBackend (withMinioPortForward)
import Prodbox.Vault.BootstrapBundle
  ( bootstrapObjectStoreConfig
  , bootstrapUnlockBundleKey
  , getBundleObject
  )
import Prodbox.Vault.Client
  ( SealStatus (..)
  , VaultAddress (..)
  , VaultToken (..)
  , vaultKvReadV2
  , vaultKvWriteV2
  , vaultSealStatus
  )
import Prodbox.Vault.UnlockBundle
  ( UnlockBundle (..)
  , decryptUnlockBundle
  , renderUnlockBundleError
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  )
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO
  ( hGetEcho
  , hIsTerminalDevice
  , hSetEcho
  , stdin
  )

-- | The host-reachable in-cluster Vault endpoint (the NodePort-on-127.0.0.1
-- pattern the gateway daemon also uses). The chart exposes the Vault API on the
-- host NodePort 31820 (@charts/vault/values.yaml@); the in-pod API is 8200.
-- Sourcing the NodePort from a @vault.node_port@ Dhall field is a follow-up.
hostVaultAddress :: VaultAddress
hostVaultAddress = VaultAddress "http://127.0.0.1:31820"

resolveHostVaultAddress :: IO VaultAddress
resolveHostVaultAddress = do
  override <- lookupEnv "PRODBOX_TEST_HOST_VAULT_ADDR"
  pure (VaultAddress (Text.pack (maybe "http://127.0.0.1:31820" id override)))

-- LEGACY-ESCAPE[host-direct-vault-root-token]: the host CLI loads the Vault
-- root token directly (to build AWS provider credentials and drive host-side
-- Vault lifecycle) rather than obtaining a role-scoped projection from the
-- Lifecycle Authority. Registered in Prodbox.Legacy.EscapeRegistry; removed when
-- the Authority owns credential provisioning (Sprints 4.49/4.50).
loadReadyVaultRootToken :: FilePath -> VaultAddress -> IO (Either String VaultToken)
loadReadyVaultRootToken repoRoot address = do
  readiness <- requireReadyVault address
  case readiness of
    Left err -> pure (Left err)
    Right () -> do
      testToken <- lookupEnv "PRODBOX_TEST_HOST_VAULT_TOKEN"
      case testToken of
        Just token | not (null token) -> pure (Right (VaultToken (Text.pack token)))
        _ -> do
          bundleResult <- loadAndDecryptBundle repoRoot
          pure $ VaultToken . unlockBundleInitialRootToken <$> bundleResult

readHostVaultKvObject
  :: FilePath -> Text -> Text -> IO (Either String (Map Text Text))
readHostVaultKvObject repoRoot mount path = do
  testKvDir <- lookupEnv "PRODBOX_TEST_HOST_VAULT_KV_DIR"
  case testKvDir of
    Just dir | not (null dir) -> readTestHostVaultKvObject dir mount path
    _ -> do
      testKv <- lookupEnv "PRODBOX_TEST_HOST_VAULT_KV"
      case testKv of
        Just "allow" -> pure (Right testHostVaultFields)
        _ -> do
          address <- resolveHostVaultAddress
          tokenResult <- loadReadyVaultRootToken repoRoot address
          case tokenResult of
            Left err -> pure (Left err)
            Right token -> do
              result <- vaultKvReadV2 address token mount path
              pure $ case result of
                Left err@(HttpStatus 404 _) ->
                  Left
                    ( "Vault KV object "
                        ++ Text.unpack (mount <> "/" <> path)
                        ++ " missing: "
                        ++ renderHttpError err
                    )
                Left err ->
                  Left
                    ( "read Vault KV object "
                        ++ Text.unpack (mount <> "/" <> path)
                        ++ ": "
                        ++ renderHttpError err
                    )
                Right fields -> Right fields

readTestHostVaultKvObject :: FilePath -> Text -> Text -> IO (Either String (Map Text Text))
readTestHostVaultKvObject kvRoot mount path = do
  let objectDir = testHostVaultObjectDir kvRoot mount path
  exists <- doesDirectoryExist objectDir
  if not exists
    then pure (Left ("test Vault KV object " ++ Text.unpack (mount <> "/" <> path) ++ " missing"))
    else do
      fieldFiles <- listDirectory objectDir
      fields <-
        forM fieldFiles $ \fieldName -> do
          value <- readFile (objectDir </> fieldName)
          pure (Text.pack fieldName, Text.pack value)
      pure (Right (Map.fromList fields))

testHostVaultObjectDir :: FilePath -> Text -> Text -> FilePath
testHostVaultObjectDir kvRoot mount path =
  kvRoot </> Text.unpack mount </> Text.unpack path

-- LEGACY-ESCAPE[host-direct-vault-kv]: the host CLI reads Vault KV directly
-- here to resolve credentials, bypassing the Lifecycle Authority's role-scoped
-- projection. Registered in Prodbox.Legacy.EscapeRegistry; removed by Sprint 4.49.
readHostVaultKvField
  :: FilePath -> Text -> Text -> Text -> IO (Either String Text)
readHostVaultKvField repoRoot mount path field = do
  objectResult <- readHostVaultKvObject repoRoot mount path
  pure $ case objectResult of
    Left err -> Left err
    Right fields ->
      case Map.lookup field fields of
        Nothing ->
          Left
            ( "Vault KV object "
                ++ Text.unpack (mount <> "/" <> path)
                ++ " missing field `"
                ++ Text.unpack field
                ++ "`"
            )
        Just value
          | Text.null (Text.strip value) ->
              Left
                ( "Vault KV object "
                    ++ Text.unpack (mount <> "/" <> path)
                    ++ " field `"
                    ++ Text.unpack field
                    ++ "` is empty"
                )
          | otherwise -> Right value

writeHostVaultKvObject
  :: FilePath -> Text -> Text -> Map Text Text -> IO (Either String ())
writeHostVaultKvObject repoRoot mount path fields = do
  testKvDir <- lookupEnv "PRODBOX_TEST_HOST_VAULT_KV_DIR"
  case testKvDir of
    Just dir | not (null dir) -> writeTestHostVaultKvObject dir mount path fields
    _ -> do
      testKv <- lookupEnv "PRODBOX_TEST_HOST_VAULT_KV"
      case testKv of
        Just "allow" -> pure (Right ())
        _ -> do
          address <- resolveHostVaultAddress
          tokenResult <- loadReadyVaultRootToken repoRoot address
          case tokenResult of
            Left err -> pure (Left err)
            Right token -> do
              result <- vaultKvWriteV2 address token mount path fields
              pure $ case result of
                Left err ->
                  Left
                    ( "write Vault KV object "
                        ++ Text.unpack (mount <> "/" <> path)
                        ++ ": "
                        ++ renderHttpError err
                    )
                Right () -> Right ()

writeTestHostVaultKvObject :: FilePath -> Text -> Text -> Map Text Text -> IO (Either String ())
writeTestHostVaultKvObject kvRoot mount path fields = do
  let objectDir = testHostVaultObjectDir kvRoot mount path
  createDirectoryIfMissing True objectDir
  mapM_
    ( \(fieldName, value) ->
        writeFile (objectDir </> Text.unpack fieldName) (Text.unpack value)
    )
    (Map.toList fields)
  pure (Right ())

testHostVaultFields :: Map Text Text
testHostVaultFields =
  Map.fromList
    [ ("client_secret", "test-vault-client-secret")
    , ("password", "test-vault-password")
    , ("access_key_id", "test-vault-access-key")
    , ("secret_access_key", "test-vault-secret-key")
    , ("session_token", "test-vault-session-token")
    , ("region", "us-west-2")
    , ("host", "email-smtp.us-east-1.amazonaws.com")
    , ("port", "587")
    , ("from", "noreply@test.resolvefintech.com")
    , ("from_display_name", "prodbox")
    , ("reply_to", "support@test.resolvefintech.com")
    , ("username", "smtp-user")
    , ("key", "test-vault-hmac-key")
    , -- Sprint 7.15: ZeroSSL EAB material (secret/acme/eab). The key ID is
      -- read host-side for the ClusterIssuer; the HMAC key is materialized
      -- in-cluster and only present here for completeness.
      ("key_id", "test-eab-key-id")
    , ("hmac_key", "test-eab-hmac-key")
    ]

-- | Read the encrypted unlock bundle from the durable MinIO bucket and decrypt
-- it with the operator password. Shared by host-side Vault commands and
-- admin/helper flows. Errors are secret-free.
--
-- Sprint 7.25 (disk-free): the bundle lives ONLY in MinIO — there is no
-- host-disk copy and no fallback. MinIO is reachable here because it comes up
-- BEFORE Vault (it depends only on the cluster + its retained PV), so "MinIO
-- unreachable" means the cluster itself is down, when there is nothing to
-- unseal. A wrong password still fails closed (the envelope fails to decrypt).
loadAndDecryptBundle :: FilePath -> IO (Either String UnlockBundle)
loadAndDecryptBundle repoRoot = do
  passwordResult <- obtainOperatorPassword repoRoot
  case passwordResult of
    Left err -> pure (Left err)
    Right password -> do
      minioRead <- fetchBootstrapBundleEnvelope
      case minioRead of
        BootstrapMinioPresent envelopeBytes ->
          case decryptUnlockBundle password envelopeBytes of
            Right bundle -> do
              writeOutputLine
                ( "Tier-1 unlock bundle read from the durable MinIO bucket at "
                    ++ Text.unpack bootstrapUnlockBundleKey
                    ++ "."
                )
              pure (Right bundle)
            Left err ->
              pure
                ( Left
                    ( "the Tier-1 unlock bundle at "
                        ++ Text.unpack bootstrapUnlockBundleKey
                        ++ " is present but did not decrypt ("
                        ++ renderUnlockBundleError err
                        ++ "); if this is not a wrong-password run, the MinIO object is corrupt"
                    )
                )
        BootstrapMinioAbsent ->
          pure
            ( Left
                ( "no Tier-1 unlock bundle at "
                    ++ Text.unpack bootstrapUnlockBundleKey
                    ++ " in the durable MinIO bucket; run `prodbox vault init` first"
                )
            )
        BootstrapMinioUnavailable reason ->
          pure
            ( Left
                ( "could not read the Tier-1 unlock bundle from the durable MinIO bucket at "
                    ++ Text.unpack bootstrapUnlockBundleKey
                    ++ " ("
                    ++ reason
                    ++ ")"
                )
            )

-- | The classified MinIO read outcome from 'fetchBootstrapBundleEnvelope', kept
-- as a small ADT so the read is decomposable. A failure to observe
-- ('BootstrapMinioUnavailable') is NOT collapsed to "absent".
data BootstrapMinioRead
  = -- | The fixed bootstrap object was present; carries its ciphertext envelope.
    BootstrapMinioPresent BS.ByteString
  | -- | The object was cleanly absent (no object at the bootstrap key).
    BootstrapMinioAbsent
  | -- | The MinIO read failed; carries a secret-free reason. This is NOT
    -- "absent" — it is a failure to observe.
    BootstrapMinioUnavailable String
  deriving (Eq, Show)

-- | Best-effort read of the Tier-1 unlock-bundle ciphertext envelope from the
-- durable MinIO bucket (§6.1), using the STATIC MinIO root credential
-- ('bootstrapObjectStoreConfig'). Opens the local MinIO port-forward and reads
-- the fixed bootstrap key. Returns a classified 'BootstrapMinioRead' so the
-- caller can DISTINGUISH a clean absence (fall back silently) from a failure to
-- observe or a present-but-corrupt object (fall back WITH a warning); a
-- read/connection failure is surfaced as 'BootstrapMinioUnavailable', never
-- collapsed to "absent".
fetchBootstrapBundleEnvelope :: IO BootstrapMinioRead
fetchBootstrapBundleEnvelope = do
  -- Sprint 7.25 test seam: when PRODBOX_TEST_BOOTSTRAP_BUNDLE_DIR is set, the
  -- bundle is read from a local file instead of MinIO, so the host-only
  -- vault-lifecycle integration test can exercise unseal/rotate without a real
  -- cluster MinIO (and never touches it). Production never sets this var.
  testDir <- lookupEnv "PRODBOX_TEST_BOOTSTRAP_BUNDLE_DIR"
  case testDir of
    Just dir -> do
      let path = dir </> bootstrapBundleTestFileName
      present <- doesFileExist path
      if not present
        then pure BootstrapMinioAbsent
        else do
          readResult <- try (BS.readFile path) :: IO (Either SomeException BS.ByteString)
          pure $ case readResult of
            Right bytes -> BootstrapMinioPresent bytes
            Left err -> BootstrapMinioUnavailable ("test bootstrap-bundle read failed: " ++ show err)
    Nothing -> do
      result <-
        withMinioPortForward $ \localPort ->
          getBundleObject (bootstrapObjectStoreConfig localPort)
      pure $ case result of
        Right (Right (Just envelopeBytes)) -> BootstrapMinioPresent envelopeBytes
        Right (Right Nothing) -> BootstrapMinioAbsent
        Right (Left readErr) -> BootstrapMinioUnavailable ("MinIO read failed: " ++ readErr)
        Left portErr -> BootstrapMinioUnavailable ("MinIO unreachable: " ++ portErr)

-- | Sprint 7.25 test seam: the local filename used for the bootstrap unlock
-- bundle under @PRODBOX_TEST_BOOTSTRAP_BUNDLE_DIR@. Shared by the read path here
-- and the write path in "Prodbox.CLI.Vault".
bootstrapBundleTestFileName :: FilePath
bootstrapBundleTestFileName = "bootstrap-bundle.enc"

requireReadyVault :: VaultAddress -> IO (Either String ())
requireReadyVault address = do
  testStatus <- lookupEnv "PRODBOX_TEST_CLUSTER_VAULT_STATUS"
  case testStatus of
    Just "ready" -> pure (Right ())
    Just "sealed" -> pure (Left "Vault is sealed; run `prodbox vault unseal` first.")
    Just "uninitialized" -> pure (Left "Vault is not initialized; run `prodbox vault init` first.")
    Just "unreachable" ->
      pure (Left ("Vault is unreachable at " ++ Text.unpack (unVaultAddress address) ++ " (test seam)"))
    Just other ->
      pure (Left ("invalid PRODBOX_TEST_CLUSTER_VAULT_STATUS=" ++ other))
    _ -> do
      statusResult <- vaultSealStatus address
      pure $ case statusResult of
        Left err -> Left (unreachableMessageAt address err)
        Right status
          | not (sealStatusInitialized status) ->
              Left "Vault is not initialized; run `prodbox vault init` first."
          | sealStatusSealed status ->
              Left "Vault is sealed; run `prodbox vault unseal` first."
          | otherwise -> Right ()

-- | The operator unlock-bundle password seam. The doctrine-blessed cleartext
-- home is @test-secrets.dhall@ (test harness only); a host operator is prompted
-- on a TTY with echo disabled; a non-interactive host with no
-- @test-secrets.dhall@ fails loud rather than blocking. The password unseals
-- Vault, so it lives host-side (Sprint 1.44: it cannot route through the
-- daemon, which needs an already-unsealed Vault).
obtainOperatorPassword :: FilePath -> IO (Either String Text)
obtainOperatorPassword repoRoot = do
  testSecretsResult <- loadTestSecrets repoRoot
  case testSecretsResult of
    Just (Left err) -> pure (Left err)
    Just (Right testSecrets) -> pure (Right (vault_operator_password testSecrets))
    Nothing -> do
      isTty <- hIsTerminalDevice stdin
      if isTty
        then Right <$> promptOperatorPassword
        else
          pure
            ( Left
                "no TTY for the Vault unlock-bundle password and no test-secrets.dhall present; supply test-secrets.dhall for automation"
            )

-- | The new unlock-bundle password. Test harness automation reuses the
-- test-only password from @test-secrets.dhall@; real operators must confirm a
-- fresh hidden password on a TTY.
obtainNewOperatorPassword :: FilePath -> IO (Either String Text)
obtainNewOperatorPassword repoRoot = do
  testSecretsPresent <- doesFileExist (testSecretsPath repoRoot)
  if testSecretsPresent
    then obtainOperatorPassword repoRoot
    else do
      isTty <- hIsTerminalDevice stdin
      if isTty
        then promptNewOperatorPassword
        else
          pure
            ( Left
                "no TTY for the new Vault unlock-bundle password and no test-secrets.dhall present; rerun from a terminal"
            )

-- | The canonical path of the test-harness secrets fixture relative to a
-- repository root. The file is git-ignored; only the harness (or an
-- operator-driven automation run) ever supplies it. Sprint 1.43 renamed this
-- from @test-config.dhall@: @test-secrets.dhall@ is now the ONLY durable-secret
-- fixture file (operator decision 2026-06-19).
testSecretsPath :: FilePath -> FilePath
testSecretsPath repoRoot = repoRoot </> "test-secrets.dhall"

-- | The test-harness secrets fixture. Carries the unlock-bundle password,
-- the EPHEMERAL admin AWS credential the harness feeds into the same
-- interactive admin prompt a real operator would answer, and (optionally) the
-- ZeroSSL ACME external-account-binding material the harness seeds into Vault
-- so the public edge can come up non-interactively. Decoded from
-- @test-secrets.dhall@ (imports the generated @test-secrets-types.dhall@
-- schema). Sprint 1.43: these are the only durable secrets the harness owns —
-- there is no non-secret @test-config.dhall@ (it would carry no fields).
data TestSecrets = TestSecrets
  { vault_operator_password :: Text
  , -- Sprint 5.10: the cleartext Route 53 hosted-zone id the harness injects into
    -- the generated @prodbox.dhall@'s @route53.zone_id@ (the @demoTestConfig@
    -- idiom). @test-secrets.dhall@ is the one file where cleartext operator ids
    -- are allowed; the harness copies this through 'configFromSetupInput' so
    -- @validateAwsBootstrapConfig@ passes without an interactive prompt. The
    -- deferred operator ids (@aws_substrate.*@ / @ses.*@ / @pulumi_state_backend.*@)
    -- extend the same way when a run needs them.
    route53_zone_id :: Text
  , -- Sprint 5.10 follow-up: the cleartext SES operator naming the harness injects
    -- into the generated @prodbox.dhall@'s @ses.*@ block (the AWS SES stack the
    -- keycloak-invite email flow provisions needs them). These are operator naming
    -- decisions (sourced from @pulumi/aws-ses/Pulumi.aws-ses.yaml@), not
    -- discoverable, so they live in @test-secrets.dhall@ like @route53_zone_id@.
    ses_sender_domain :: Text
  , ses_receive_subdomain :: Text
  , ses_capture_bucket :: Text
  , -- Sprint 5.10 follow-up: the long-lived @pulumi_state_backend@ S3 backend the
    -- retained @aws-ses@ (and other long-lived) stacks live in. Operator infra ids
    -- (from @pulumi/aws-ses/Pulumi.yaml@), injected like @route53_zone_id@. The
    -- key prefix is the fixed @pulumi/@ skeleton default.
    pulumi_state_backend_bucket_name :: Text
  , pulumi_state_backend_region :: Text
  , aws_admin_for_test_simulation :: TestSecretsAdminCredentials
  , -- Sprint 7.18: optional so existing @test-secrets.dhall@ fixtures (and the
    -- @TestSecrets.default@ used by the round-trip drift guard) without the EAB
    -- block still decode. When present and populated, the suite-level IAM
    -- harness seeds @secret/acme/eab@ the same way it materializes @aws.*@,
    -- mirroring the interactive @prodbox config setup@ EAB prompt.
    acme_eab :: Maybe AcmeEabFixture
  }
  deriving (Eq, Generic, Show)

instance FromDhall TestSecrets

-- | Sprint 7.17: the dual encoder, used by 'Prodbox.Config.SchemaDhall' to
-- render the @default@ record of the generated @test-secrets-types.dhall@
-- schema from this Haskell source of truth. The default mirrors the all-empty
-- @default@ of the hand-written schema.
instance ToDhall TestSecrets

-- | The cleartext admin AWS credential carried by @test-secrets.dhall@. Field
-- names mirror the @aws_admin_for_test_simulation@ record in
-- @test-secrets-types.dhall@.
data TestSecretsAdminCredentials = TestSecretsAdminCredentials
  { access_key_id :: Text
  , secret_access_key :: Text
  , session_token :: Maybe Text
  , region :: Text
  }
  deriving (Eq, Generic, Show)

instance FromDhall TestSecretsAdminCredentials

instance ToDhall TestSecretsAdminCredentials

-- | Sprint 7.18: the cleartext ZeroSSL ACME external-account-binding material
-- carried by the optional @acme_eab@ block of @test-secrets.dhall@. Field names
-- mirror the @secret/acme/eab@ Vault object (@key_id@ / @hmac_key@) the harness
-- seeds via 'writeAcmeEabVaultCredentials'. Never production config; never
-- committed with real values (the committed fixture uses placeholders).
data AcmeEabFixture = AcmeEabFixture
  { key_id :: Text
  , hmac_key :: Text
  }
  deriving (Eq, Generic, Show)

instance FromDhall AcmeEabFixture

instance ToDhall AcmeEabFixture

-- | The all-empty @default@ for @test-secrets-types.dhall@, matching the
-- hand-written schema. The harness/operator overrides every field; this is the
-- value the generated schema's @default@ record carries. The optional
-- @acme_eab@ block defaults to @None@ so a fixture without it still decodes.
defaultTestSecrets :: TestSecrets
defaultTestSecrets =
  TestSecrets
    { vault_operator_password = ""
    , route53_zone_id = ""
    , ses_sender_domain = ""
    , ses_receive_subdomain = ""
    , ses_capture_bucket = ""
    , pulumi_state_backend_bucket_name = ""
    , pulumi_state_backend_region = ""
    , aws_admin_for_test_simulation =
        TestSecretsAdminCredentials
          { access_key_id = ""
          , secret_access_key = ""
          , session_token = Nothing
          , region = ""
          }
    , acme_eab = Nothing
    }

-- | Load and decode @test-secrets.dhall@ if present. @Nothing@ means the file
-- is absent (so the caller falls back to a TTY prompt or fails loud);
-- @Just (Left err)@ means it exists but failed to decode; @Just (Right cfg)@
-- is the decoded fixture.
loadTestSecrets :: FilePath -> IO (Maybe (Either String TestSecrets))
loadTestSecrets repoRoot = do
  let path = testSecretsPath repoRoot
  present <- doesFileExist path
  if not present
    then pure Nothing
    else do
      decoded <- try (inputFile auto path) :: IO (Either SomeException TestSecrets)
      pure $
        Just $ case decoded of
          Left ex -> Left ("failed to decode test-secrets.dhall: " ++ show ex)
          Right testSecrets -> Right testSecrets

-- | Sprint 7.18: load @test-secrets.dhall@ and, when it carries a populated
-- optional @acme_eab@ block, seed @secret/acme/eab@ in Vault (fields
-- @key_id@ / @hmac_key@) so the in-cluster ACME EAB materializer Job reads a
-- non-empty HMAC. This is the non-interactive analog of the interactive
-- @prodbox config setup@ EAB prompt.
--
-- It lives here (low in the import graph) so both the AWS IAM harness preflight
-- ('Prodbox.Aws.runAwsIamHarnessSetup') and the edge/ACME reconcile
-- ('Prodbox.CLI.Rke2.ensureAcmeRuntime', which must seed before applying the
-- materializer Job) can call it without an import cycle.
--
-- A missing file, a decode failure, an absent block, or empty fields are all
-- silent no-ops: this is a best-effort fixture seam (real operators have no
-- @test-secrets.dhall@ and seed the EAB interactively via @config setup@), and
-- the public-edge prerequisites fail loud later if the EAB is genuinely
-- required but unset. A decode failure here is already surfaced by the
-- admin-credential acquisition path (which decodes the same file and fails
-- loud), so we avoid a second redundant failure path for the EAB seam.
--
-- The best-effort tolerance covers only the "nothing to seed" inputs listed
-- above. A *write* failure is different: valid EAB data was present and the
-- Vault KV write itself was rejected (e.g. Vault unreachable), which signals a
-- real environment fault rather than a missing fixture, so it is surfaced loudly
-- ('ioError' below) instead of being swallowed.
seedAcmeEabFromTestSecrets :: FilePath -> IO ()
seedAcmeEabFromTestSecrets repoRoot = do
  testSecretsResult <- loadTestSecrets repoRoot
  case testSecretsResult of
    Just (Right testSecrets) ->
      case acme_eab testSecrets of
        Just eab
          | not (Text.null (Text.strip (key_id eab)))
          , not (Text.null (Text.strip (hmac_key eab))) -> do
              result <-
                writeHostVaultKvObject
                  repoRoot
                  "secret"
                  "acme/eab"
                  ( Map.fromList
                      [ ("key_id", key_id eab)
                      , ("hmac_key", hmac_key eab)
                      ]
                  )
              case result of
                Left err -> ioError (userError err)
                Right () -> pure ()
        _ -> pure ()
    _ -> pure ()

promptOperatorPassword :: IO Text
promptOperatorPassword =
  promptHiddenText "Vault unlock-bundle password: "

promptNewOperatorPassword :: IO (Either String Text)
promptNewOperatorPassword = do
  password <- promptHiddenText "New Vault unlock-bundle password: "
  confirmation <- promptHiddenText "Confirm new Vault unlock-bundle password: "
  pure $
    if Text.null password
      then Left "new Vault unlock-bundle password must not be empty"
      else
        if password == confirmation
          then Right password
          else Left "new Vault unlock-bundle password confirmation did not match"

promptHiddenText :: String -> IO Text
promptHiddenText prompt = do
  writeDiagnostic prompt
  priorEcho <- hGetEcho stdin
  bracket_
    (hSetEcho stdin False)
    (hSetEcho stdin priorEcho >> writeDiagnosticLine "")
    (Text.pack <$> getLine)

unreachableMessageAt :: VaultAddress -> HttpError -> String
unreachableMessageAt address err =
  "Vault is unreachable at "
    ++ Text.unpack (unVaultAddress address)
    ++ ": "
    ++ renderHttpError err
