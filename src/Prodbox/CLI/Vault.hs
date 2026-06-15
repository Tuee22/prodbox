{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 1.36: handler for the @prodbox vault@ command group. @vault status@
-- probes the in-cluster Vault seal state; @vault init@ / @vault unseal@ /
-- @vault seal@ drive the host-side lifecycle through "Prodbox.Vault.Client" and
-- the encrypted unlock bundle of "Prodbox.Vault.UnlockBundle", with the pure
-- decision logic in "Prodbox.Vault.Orchestration". The remaining subcommands
-- (@reconcile@, key rotation, @pki@) are wired to the surface but not yet
-- implemented.
--
-- The live init/unseal/seal exercise runs against a deployed in-cluster Vault
-- (Sprint 3.17 + a reconciled cluster); the pure orchestration is unit-tested
-- offline.
module Prodbox.CLI.Vault
  ( runVaultCommand
  )
where

import Control.Exception (SomeException, bracket_, try)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Dhall (FromDhall, auto, inputFile)
import GHC.Generics (Generic)
import Prodbox.CLI.Command (VaultCommand (..))
import Prodbox.CLI.Output (writeDiagnostic, writeDiagnosticLine, writeOutput)
import Prodbox.Http.Client (HttpError, renderHttpError)
import Prodbox.Vault.Client
  ( BootstrapAction (..)
  , SealStatus (..)
  , VaultAddress (..)
  , VaultToken (..)
  , bootstrapAction
  , defaultInitRequest
  , initResponseToUnlockBundle
  , vaultInit
  , vaultSeal
  , vaultSealStatus
  , vaultSubmitUnseal
  )
import Prodbox.Vault.Orchestration
  ( UnsealOutcome (..)
  , UnsealStep (..)
  , interpretUnsealProgress
  , planUnseal
  , vaultUnlockBundlePath
  )
import Prodbox.Vault.UnlockBundle
  ( UnlockBundle (..)
  , decryptUnlockBundle
  , encryptUnlockBundle
  , renderUnlockBundleError
  )
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeDirectory, (</>))
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

-- | The cluster id stamped into the unlock bundle. A wired cluster-id source is
-- a follow-up (Sprint 1.38 in-force config / cluster federation).
defaultClusterId :: Text
defaultClusterId = "prodbox-home"

runVaultCommand :: FilePath -> VaultCommand -> IO ExitCode
runVaultCommand repoRoot command = case command of
  VaultStatus -> do
    result <- vaultSealStatus hostVaultAddress
    case result of
      Left err -> do
        writeOutput (unreachableMessage err)
        pure (ExitFailure 1)
      Right status -> do
        writeOutput (renderSealStatus status)
        pure ExitSuccess
  VaultInit -> runVaultInit repoRoot hostVaultAddress
  VaultUnseal -> runVaultUnseal repoRoot hostVaultAddress
  VaultSeal -> runVaultSeal repoRoot hostVaultAddress
  _ -> do
    writeOutput (notYetAvailable command)
    pure (ExitFailure 1)

-- | @prodbox vault init@: initialize an empty Vault exactly once, capturing the
-- unseal/recovery keys + root token into the encrypted unlock bundle. An
-- already-initialized Vault is an idempotent no-op success — 'vaultInit' is
-- never called against existing state.
runVaultInit :: FilePath -> VaultAddress -> IO ExitCode
runVaultInit repoRoot address = do
  statusResult <- vaultSealStatus address
  case statusResult of
    Left err -> do
      writeOutput (unreachableMessage err)
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
          initResult <- vaultInit address defaultInitRequest
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
                  writeOutput
                    ( "Vault initialized; encrypted unlock bundle written to "
                        ++ bundlePath
                        ++ ". Keep the unlock password safe — it is the only way to unseal this cluster."
                    )
                  pure ExitSuccess

-- | @prodbox vault unseal@: read and decrypt the unlock bundle, then submit its
-- unseal key shares until the Vault reports unsealed.
runVaultUnseal :: FilePath -> VaultAddress -> IO ExitCode
runVaultUnseal repoRoot address = do
  bundleResult <- loadAndDecryptBundle repoRoot
  case bundleResult of
    Left err -> do
      writeOutput err
      pure (ExitFailure 1)
    Right bundle -> do
      statusResult <- vaultSealStatus address
      case statusResult of
        Left err -> do
          writeOutput (unreachableMessage err)
          pure (ExitFailure 1)
        Right status -> case planUnseal status (unlockBundleUnsealKeys bundle) of
          Left planErr -> do
            writeOutput ("unseal plan failed: " ++ planErr)
            pure (ExitFailure 1)
          Right [] -> do
            writeOutput "Vault already unsealed."
            pure ExitSuccess
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

-- | Read the on-disk encrypted unlock bundle and decrypt it with the operator
-- password. Shared by @unseal@ and @seal@. Errors are secret-free.
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

-- | The operator unlock-bundle password seam. The doctrine-blessed cleartext
-- home is @test-secrets.dhall@ (test harness only); a host operator is prompted
-- on a TTY with echo disabled; a non-interactive host with no @test-secrets.dhall@
-- fails loud rather than blocking.
obtainOperatorPassword :: FilePath -> IO (Either String Text)
obtainOperatorPassword repoRoot = do
  let testSecretsPath = repoRoot </> "test-secrets.dhall"
  hasTestSecrets <- doesFileExist testSecretsPath
  if hasTestSecrets
    then do
      decoded <-
        try (inputFile auto testSecretsPath) :: IO (Either SomeException TestSecrets)
      pure $ case decoded of
        Left ex -> Left ("failed to decode test-secrets.dhall: " ++ show ex)
        Right secrets -> Right (vaultOperatorPassword secrets)
    else do
      isTty <- hIsTerminalDevice stdin
      if isTty
        then Right <$> promptOperatorPassword
        else
          pure
            ( Left
                "no TTY for the Vault unlock-bundle password and no test-secrets.dhall present; supply test-secrets.dhall for automation"
            )

-- | The test-harness cleartext source for the unlock-bundle password.
newtype TestSecrets = TestSecrets
  { vaultOperatorPassword :: Text
  }
  deriving (Generic)

instance FromDhall TestSecrets

-- | Prompt for the unlock-bundle password on the controlling terminal with
-- echo disabled, restoring the prior echo state afterward.
promptOperatorPassword :: IO Text
promptOperatorPassword = do
  writeDiagnostic "Vault unlock-bundle password: "
  priorEcho <- hGetEcho stdin
  bracket_
    (hSetEcho stdin False)
    (hSetEcho stdin priorEcho >> writeDiagnosticLine "")
    (Text.pack <$> getLine)

iso8601Now :: IO Text
iso8601Now = Text.pack . iso8601Show <$> getCurrentTime

unreachableMessage :: HttpError -> String
unreachableMessage err =
  "Vault: unreachable at "
    ++ Text.unpack (unVaultAddress hostVaultAddress)
    ++ " ("
    ++ renderHttpError err
    ++ ")"

renderSealStatus :: SealStatus -> String
renderSealStatus status =
  "Vault: initialized="
    ++ show (sealStatusInitialized status)
    ++ ", sealed="
    ++ show (sealStatusSealed status)
    ++ ", unseal-progress="
    ++ show (sealStatusProgress status)
    ++ "/"
    ++ show (sealStatusThreshold status)

notYetAvailable :: VaultCommand -> String
notYetAvailable command =
  "prodbox vault "
    ++ subcommandName command
    ++ " is not yet available on this build: the init/unseal/seal lifecycle is"
    ++ " wired, but reconcile, key rotation, and the PKI surface are still being"
    ++ " built. Run `prodbox vault status` to probe the in-cluster Vault."

subcommandName :: VaultCommand -> String
subcommandName command = case command of
  VaultStatus -> "status"
  VaultInit -> "init"
  VaultUnseal -> "unseal"
  VaultSeal -> "seal"
  VaultReconcile -> "reconcile"
  VaultRotateUnlockBundle -> "rotate-unlock-bundle"
  VaultRotateTransitKey _ -> "rotate-transit-key"
  VaultPkiStatus -> "pki status"
  VaultPkiIssueTestCert -> "pki issue-test-cert"
