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
  , BootstrapSourceDecision (..)
  , classifyBootstrapMinioSource
  , renderBootstrapSourceWarning

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
import Prodbox.Vault.Orchestration (vaultUnlockBundlePath)
import Prodbox.Vault.UnlockBundle
  ( UnlockBundle (..)
  , UnlockBundleError (..)
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

-- | Read the encrypted unlock bundle and decrypt it with the operator password.
-- Shared by host-side Vault commands and admin/helper flows. Errors are
-- secret-free.
--
-- Sprint 7.19 (staged): the bundle source is now PREFER-MinIO, FALL-BACK-disk.
-- The operator password (obtained once) decrypts whichever source supplies the
-- ciphertext envelope: first the Tier-1 fixed-key object in the durable MinIO
-- bucket, fetched via the password-derived bootstrap credential (§6.1); if MinIO
-- is unreachable, the object is absent, or the credential cannot be derived, it
-- falls back to the host-disk bundle, which remains the load-bearing source this
-- stage. The bundle bytes are identical in both places (the @vault init@
-- dual-write), so the password decrypts either one the same way.
--
-- Sprint 7.19 (live-proof): the MinIO-root-decouple has landed (root password
-- now password-derived); once the remaining MinIO-before-Vault-unseal reorder
-- lands, the disk fallback is removed and MinIO becomes the sole source. NOT
-- done this stage.
loadAndDecryptBundle :: FilePath -> IO (Either String UnlockBundle)
loadAndDecryptBundle repoRoot = do
  passwordResult <- obtainOperatorPassword repoRoot
  case passwordResult of
    Left err -> pure (Left err)
    Right password -> do
      minioRead <- fetchBootstrapBundleEnvelope
      case classifyBootstrapMinioSource password minioRead of
        BootstrapUseMinio bundle -> do
          writeOutputLine
            ( "Tier-1 unlock bundle read from the durable MinIO bucket at "
                ++ Text.unpack bootstrapUnlockBundleKey
                ++ "."
            )
          pure (Right bundle)
        BootstrapFallBackToDisk warning -> do
          -- Sprint 7.19 (P3): never SILENTLY mask a present-but-undecryptable
          -- MinIO bootstrap object or a MinIO read/credential failure. Surface
          -- the reason as a WARNING (secret-free) before falling back to the
          -- host-disk bundle, which remains the recovery source this stage. The
          -- overall path still fails CLOSED when the password is wrong, because
          -- the byte-identical disk envelope fails to decrypt too.
          case warning of
            Just message -> writeOutputLine ("WARNING: " ++ message)
            Nothing -> pure ()
          loadAndDecryptDiskBundle repoRoot password

-- | The classified MinIO read outcome handed to the pure
-- 'classifyBootstrapMinioSource' decision. Keeps the IO (port-forward, MinIO
-- read) separate from the policy so the fall-back / warn decision is unit
-- testable without a cluster.
data BootstrapMinioRead
  = -- | The fixed bootstrap object was present; carries its ciphertext envelope.
    BootstrapMinioPresent BS.ByteString
  | -- | The object was cleanly absent (no object at the bootstrap key).
    BootstrapMinioAbsent
  | -- | The MinIO read or bootstrap-credential derivation failed; carries a
    -- secret-free reason. This is NOT "absent" — it is a failure to observe.
    BootstrapMinioUnavailable String
  deriving (Eq, Show)

-- | The pure unseal-source decision: whether to use the MinIO-sourced bundle or
-- fall back to the host disk, and (when falling back) an optional secret-free
-- WARNING to surface so the failure is never silently masked.
data BootstrapSourceDecision
  = -- | The MinIO object decrypted cleanly; use it.
    BootstrapUseMinio UnlockBundle
  | -- | Fall back to the host-disk bundle. @Just@ a warning when the fall-back
    -- is due to an integrity/availability problem worth surfacing; @Nothing@
    -- when MinIO was cleanly absent (the ordinary pre-dual-write case).
    BootstrapFallBackToDisk (Maybe String)
  deriving (Eq, Show)

-- | Decide the unseal source from a classified MinIO read and the operator
-- password. Pure, so the warn / fall-back policy is testable:
--
--   * a present object that DECRYPTS cleanly is used directly;
--   * a present object that does NOT decrypt is treated as corruption — fall
--     back to disk WITH a warning naming the integrity failure (the disk copy
--     is byte-identical, so a wrong password still fails closed there);
--   * a clean absence falls back to disk SILENTLY (the ordinary case before the
--     dual-write has run);
--   * a MinIO read / credential-derivation failure falls back to disk WITH a
--     warning naming the reason (a failure to OBSERVE is never silently treated
--     as absent).
classifyBootstrapMinioSource :: Text -> BootstrapMinioRead -> BootstrapSourceDecision
classifyBootstrapMinioSource password minioRead = case minioRead of
  BootstrapMinioPresent envelopeBytes ->
    case decryptUnlockBundle password envelopeBytes of
      Right bundle -> BootstrapUseMinio bundle
      Left err -> BootstrapFallBackToDisk (Just (renderBootstrapSourceWarning err))
  BootstrapMinioAbsent -> BootstrapFallBackToDisk Nothing
  BootstrapMinioUnavailable reason ->
    BootstrapFallBackToDisk
      ( Just
          ( "could not read the Tier-1 unlock bundle from the durable MinIO bucket at "
              ++ Text.unpack bootstrapUnlockBundleKey
              ++ " ("
              ++ reason
              ++ "); falling back to the host-disk bundle."
          )
      )

-- | Render the secret-free warning for a MinIO bootstrap object that was present
-- but did not decrypt. 'UnlockBundleMalformed' / 'UnlockBundleDecodeFailed' are
-- unambiguous corruption; 'UnlockBundleAuthFailed' is wrong-password-or-tamper
-- (kept indistinguishable). Either way it is surfaced, never masked.
renderBootstrapSourceWarning :: UnlockBundleError -> String
renderBootstrapSourceWarning err =
  "the Tier-1 unlock bundle in the durable MinIO bucket at "
    ++ Text.unpack bootstrapUnlockBundleKey
    ++ " is present but UNDECRYPTABLE ("
    ++ renderUnlockBundleError err
    ++ "); falling back to the host-disk bundle. If this is not a wrong-password "
    ++ "run, the MinIO object is corrupt and should be re-written from the host "
    ++ "disk via `prodbox vault rotate-unlock-bundle`."

-- | The host-disk fallback half of 'loadAndDecryptBundle': read the on-disk
-- ciphertext envelope and decrypt it. Used when the preferred MinIO source is
-- unreachable, absent, or corrupt.
loadAndDecryptDiskBundle :: FilePath -> Text -> IO (Either String UnlockBundle)
loadAndDecryptDiskBundle repoRoot password = do
  let bundlePath = vaultUnlockBundlePath repoRoot
  bundleExists <- doesFileExist bundlePath
  if not bundleExists
    then pure (Left ("no unlock bundle at " ++ bundlePath ++ "; run `prodbox vault init` first"))
    else do
      envelopeBytes <- BS.readFile bundlePath
      pure $ case decryptUnlockBundle password envelopeBytes of
        Left err -> Left (renderUnlockBundleError err)
        Right bundle -> Right bundle

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
  result <-
    withMinioPortForward $ \localPort ->
      getBundleObject (bootstrapObjectStoreConfig localPort)
  pure $ case result of
    Right (Right (Just envelopeBytes)) -> BootstrapMinioPresent envelopeBytes
    Right (Right Nothing) -> BootstrapMinioAbsent
    Right (Left readErr) -> BootstrapMinioUnavailable ("MinIO read failed: " ++ readErr)
    Left portErr -> BootstrapMinioUnavailable ("MinIO unreachable: " ++ portErr)

requireReadyVault :: VaultAddress -> IO (Either String ())
requireReadyVault address = do
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
