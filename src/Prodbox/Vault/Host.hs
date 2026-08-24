{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Host-side operator-password, bootstrap-bundle, and fixture decoding helpers.
--
-- Production Vault effects use role-scoped in-cluster identities. The host
-- helpers below never recover an initial root token or read/write Vault KV.
module Prodbox.Vault.Host
  ( loadAndDecryptBundle
  , loadReadyVaultRootToken
  , obtainNewOperatorPassword
  , obtainOperatorPassword
  , requireReadyVault
  , vaultAddressForDeploymentContext

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
  )
where

import Control.Exception (SomeException, bracket_, try)
import Data.ByteString qualified as BS
import Data.Char qualified as Char
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (FromDhall, ToDhall, auto, inputFile)
import Dhall qualified
import GHC.Generics (Generic)
import Prodbox.CLI.Output (writeDiagnostic, writeDiagnosticLine, writeOutputLine)
import Prodbox.Http.Client (HttpError, renderHttpError)
import Prodbox.Infra.MinioBackend
  ( hostDirectEndpointPort
  , withMinioPortForward
  )
import Prodbox.Settings
  ( ValidatedDeploymentContext
  , deploymentVaultAddress
  )
import Prodbox.Vault.BootstrapBundle
  ( bootstrapObjectStoreConfig
  , bootstrapUnlockBundleKey
  , getBundleObject
  )
import Prodbox.Vault.Client
  ( SealStatus (..)
  , VaultAddress (..)
  , VaultToken
  , vaultSealStatus
  )
import Prodbox.Vault.UnlockBundle
  ( UnlockBundle (..)
  , decryptUnlockBundle
  , renderUnlockBundleError
  )
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO
  ( hGetEcho
  , hIsTerminalDevice
  , hSetEcho
  , stdin
  )

-- | Project the host Vault capability from the same validated deployment
-- context that lifecycle reconciliation seals. There is deliberately no
-- compiled address or environment override on this boundary: tests construct
-- another validated context or inject a client at the effect boundary.
vaultAddressForDeploymentContext :: ValidatedDeploymentContext -> VaultAddress
vaultAddressForDeploymentContext = VaultAddress . deploymentVaultAddress

-- | Temporary source-compatible refusal for callers being migrated by the
-- Authority/checkpoint cutovers. It cannot construct or recover a token and
-- must be deleted with the final importing call site.
loadReadyVaultRootToken :: FilePath -> VaultAddress -> IO (Either String VaultToken)
loadReadyVaultRootToken _repoRoot _address =
  pure
    ( Left
        "host root-token recovery is removed; use a role-scoped in-cluster capability"
    )

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
        withMinioPortForward $ \endpoint ->
          getBundleObject (bootstrapObjectStoreConfig (hostDirectEndpointPort endpoint))
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
  , -- Sprint 5.37: externally chosen, non-secret test-deployment inputs. They
    -- live beside the harness's secret fixture because this is the one
    -- operator-authored harness input; they never enter production config by
    -- default and are required before a generated run config may be written.
    test_served_fqdn :: Text
  , test_acme_email :: Text
  , -- The legacy aggregate has not yet moved onto @prodbox.test.dhall@. Until
    -- that cutover, it receives the same explicit identity/endpoint facts here
    -- instead of reconstructing them from production defaults.
    legacy_cluster_id :: Text
  , legacy_machine_id :: Text
  , legacy_vault_address :: Text
  , legacy_minio_endpoint :: Text
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
  , -- Optional so existing @test-secrets.dhall@ fixtures (and the
    -- @TestSecrets.default@ used by the round-trip drift guard) without the EAB
    -- block still decode. When present, the value may enter only through the
    -- schema-indexed attested external-material ingress; it is never consumed
    -- by Tier-0 config setup or the IAM-only harness.
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

-- | Sprint 5.34: a __validating__ decoder, because the generic one made the
-- fixture's worst confusion type-check.
--
-- @access_key_id@ and @secret_access_key@ are both @Text@, so transposing them
-- decodes cleanly and the harness then presents an AWS secret as an access-key
-- id. The mistake is silent at every layer below: AWS answers
-- @InvalidClientTokenId@, which is indistinguishable from a revoked credential.
--
-- The two values are distinguishable by shape — an AWS access-key id is 20
-- upper-case alphanumerics beginning @AKIA@ or @ASIA@, a secret is 40 characters
-- and is not of that form — so the transposition is __detectable__ and is now
-- refused at the decode seam. This is the same move Sprint @1.86@ made for
-- 'Prodbox.Cluster.Topology.Machine': the wide value is read through
-- @record@\/@field@ and narrowed by the constructor owning the invariant.
--
-- __The check is one-sided, and the reason is a conflict worth recording.__ The
-- symmetric rule — also require @access_key_id@ to /have/ the access-key-id
-- shape — was written first and is not available: it refuses this repository's
-- own integration fixtures, and those fixtures cannot be given a
-- structurally-valid id, because @scannedCredentialViolations@ (Sprint @1.75@,
-- the @vault_doctrine.md@ § 20.5 mechanical outer ring) fails the build for any
-- __tracked__ file carrying that shape. So the two rules are in direct
-- opposition, and the credential scanner is the one that must win.
--
-- What survives is strictly the more valuable half. A transposition of
-- __placeholder__ values is undetectable and now goes unremarked; a
-- transposition of __real__ operator credentials — the case that costs an
-- afternoon, because AWS answers @InvalidClientTokenId@ — puts a real
-- access-key id into @secret_access_key@ and is refused.
--
-- __An empty field is admitted, deliberately.__ 'defaultTestSecrets' is
-- all-empty by construction — it is what the generated schema's @default@
-- record carries, and a unit case round-trips it back through this decoder — so
-- refusing empty would refuse the schema's own default. The rule is the one
-- 'Prodbox.Settings.validateAwsSubstrateSection' already uses: refuse a value
-- that is __present and malformed__, never one that is absent.
instance FromDhall TestSecretsAdminCredentials where
  autoWith options =
    narrowingTestSecretsDecoder
      ( Dhall.record
          ( (,,,)
              <$> Dhall.field "access_key_id" (Dhall.autoWith options)
              <*> Dhall.field "secret_access_key" (Dhall.autoWith options)
              <*> Dhall.field "session_token" (Dhall.autoWith options)
              <*> Dhall.field "region" (Dhall.autoWith options)
          )
      )
      narrowTestSecretsAdminCredentials

narrowTestSecretsAdminCredentials
  :: (Text, Text, Maybe Text, Text) -> Either String TestSecretsAdminCredentials
narrowTestSecretsAdminCredentials (keyId, secret, sessionToken, credentialRegion)
  | looksLikeAwsAccessKeyId secret =
      Left
        ( "aws_admin_for_test_simulation.secret_access_key has the shape of an "
            ++ "access-key id"
            ++ transpositionHint
        )
  | otherwise =
      Right
        TestSecretsAdminCredentials
          { access_key_id = keyId
          , secret_access_key = secret
          , session_token = sessionToken
          , region = credentialRegion
          }
 where
  transpositionHint =
    ". The two fields are both Text, so transposing them type-checks; that is "
      ++ "what this refusal exists to catch. No value is echoed."

-- | The documented AWS access-key-id shape. Kept narrow on purpose: it is used
-- to tell two fixture fields apart, not to validate a credential.
looksLikeAwsAccessKeyId :: Text -> Bool
looksLikeAwsAccessKeyId value =
  Text.length trimmed == 20
    && any (`Text.isPrefixOf` trimmed) ["AKIA", "ASIA"]
    && Text.all (\character -> Char.isAsciiUpper character || Char.isDigit character) trimmed
 where
  trimmed = Text.strip value

narrowingTestSecretsDecoder
  :: Dhall.Decoder wide -> (wide -> Either String narrow) -> Dhall.Decoder narrow
narrowingTestSecretsDecoder base narrow =
  base
    { Dhall.extract = \expression -> Dhall.fromMonadic $ do
        wide <- Dhall.toMonadic (Dhall.extract base expression)
        case narrow wide of
          Right narrowed -> pure narrowed
          Left err -> Dhall.toMonadic (Dhall.extractError (Text.pack err))
    }

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
    , test_served_fqdn = ""
    , test_acme_email = ""
    , legacy_cluster_id = ""
    , legacy_machine_id = ""
    , legacy_vault_address = ""
    , legacy_minio_endpoint = ""
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
