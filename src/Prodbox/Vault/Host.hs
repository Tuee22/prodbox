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

    -- * Sprint 7.16: the test-harness cleartext fixture (@test-config.dhall@)
  , TestConfig (..)
  , TestConfigAdminCredentials (..)
  , testConfigPath
  , loadTestConfig
  )
where

import Control.Exception (SomeException, bracket_, try)
import Control.Monad (forM)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (FromDhall, auto, inputFile)
import GHC.Generics (Generic)
import Prodbox.CLI.Output (writeDiagnostic, writeDiagnosticLine)
import Prodbox.Http.Client (HttpError (..), renderHttpError)
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

-- | Read the on-disk encrypted unlock bundle and decrypt it with the operator
-- password. Shared by host-side Vault commands and admin/helper flows. Errors
-- are secret-free.
loadAndDecryptBundle :: FilePath -> IO (Either String UnlockBundle)
loadAndDecryptBundle repoRoot = do
  let bundlePath = vaultUnlockBundlePath repoRoot
  bundleExists <- doesFileExist bundlePath
  if not bundleExists
    then pure (Left ("no unlock bundle at " ++ bundlePath ++ "; run `prodbox vault init` first"))
    else do
      envelopeBytes <- BS.readFile bundlePath
      passwordResult <- obtainOperatorPassword repoRoot
      case passwordResult of
        Left err -> pure (Left err)
        Right password ->
          pure $ case decryptUnlockBundle password envelopeBytes of
            Left err -> Left (renderUnlockBundleError err)
            Right bundle -> Right bundle

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
-- home is @test-config.dhall@ (test harness only); a host operator is prompted
-- on a TTY with echo disabled; a non-interactive host with no
-- @test-config.dhall@ fails loud rather than blocking.
obtainOperatorPassword :: FilePath -> IO (Either String Text)
obtainOperatorPassword repoRoot = do
  testConfigResult <- loadTestConfig repoRoot
  case testConfigResult of
    Just (Left err) -> pure (Left err)
    Just (Right testConfig) -> pure (Right (vault_operator_password testConfig))
    Nothing -> do
      isTty <- hIsTerminalDevice stdin
      if isTty
        then Right <$> promptOperatorPassword
        else
          pure
            ( Left
                "no TTY for the Vault unlock-bundle password and no test-config.dhall present; supply test-config.dhall for automation"
            )

-- | The new unlock-bundle password. Test harness automation reuses the
-- test-only password from @test-config.dhall@; real operators must confirm a
-- fresh hidden password on a TTY.
obtainNewOperatorPassword :: FilePath -> IO (Either String Text)
obtainNewOperatorPassword repoRoot = do
  testConfigPresent <- doesFileExist (testConfigPath repoRoot)
  if testConfigPresent
    then obtainOperatorPassword repoRoot
    else do
      isTty <- hIsTerminalDevice stdin
      if isTty
        then promptNewOperatorPassword
        else
          pure
            ( Left
                "no TTY for the new Vault unlock-bundle password and no test-config.dhall present; rerun from a terminal"
            )

-- | The canonical path of the test-harness cleartext fixture relative to a
-- repository root. The file is git-ignored; only the harness (or an
-- operator-driven automation run) ever supplies it.
testConfigPath :: FilePath -> FilePath
testConfigPath repoRoot = repoRoot </> "test-config.dhall"

-- | The test-harness cleartext fixture. Carries the unlock-bundle password and
-- the EPHEMERAL admin AWS credential the harness feeds into the same
-- interactive admin prompt a real operator would answer. Decoded from
-- @test-config.dhall@ (imports the committed @test-config-types.dhall@ schema).
data TestConfig = TestConfig
  { vault_operator_password :: Text
  , aws_admin_for_test_simulation :: TestConfigAdminCredentials
  }
  deriving (Generic, Show)

instance FromDhall TestConfig

-- | The cleartext admin AWS credential carried by @test-config.dhall@. Field
-- names mirror the @aws_admin_for_test_simulation@ record in
-- @test-config-types.dhall@.
data TestConfigAdminCredentials = TestConfigAdminCredentials
  { access_key_id :: Text
  , secret_access_key :: Text
  , session_token :: Maybe Text
  , region :: Text
  }
  deriving (Generic, Show)

instance FromDhall TestConfigAdminCredentials

-- | Load and decode @test-config.dhall@ if present. @Nothing@ means the file
-- is absent (so the caller falls back to a TTY prompt or fails loud);
-- @Just (Left err)@ means it exists but failed to decode; @Just (Right cfg)@
-- is the decoded fixture.
loadTestConfig :: FilePath -> IO (Maybe (Either String TestConfig))
loadTestConfig repoRoot = do
  let path = testConfigPath repoRoot
  present <- doesFileExist path
  if not present
    then pure Nothing
    else do
      decoded <- try (inputFile auto path) :: IO (Either SomeException TestConfig)
      pure $
        Just $ case decoded of
          Left ex -> Left ("failed to decode test-config.dhall: " ++ show ex)
          Right testConfig -> Right testConfig

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
