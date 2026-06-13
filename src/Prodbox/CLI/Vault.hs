{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.36: handler for the @prodbox vault@ command group. @vault
-- status@ probes the in-cluster Vault seal state through
-- "Prodbox.Vault.Client"; the remaining subcommands are wired to the surface
-- but report that the init/unseal orchestration and the authenticated
-- (token-bearing) surface are still being built — those land alongside the
-- live unseal exercise once the in-cluster Vault is deployable.
module Prodbox.CLI.Vault
  ( runVaultCommand
  )
where

import Data.Text qualified as Text
import Prodbox.CLI.Command (VaultCommand (..))
import Prodbox.CLI.Output (writeOutput)
import Prodbox.Http.Client (renderHttpError)
import Prodbox.Vault.Client
  ( SealStatus (..)
  , VaultAddress (..)
  , vaultSealStatus
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

-- | The host-reachable in-cluster Vault endpoint (the NodePort-on-127.0.0.1
-- pattern the gateway daemon also uses). Sourcing this from the Dhall config
-- or a managed port-forward is a follow-up.
defaultVaultAddress :: VaultAddress
defaultVaultAddress = VaultAddress "http://127.0.0.1:8200"

runVaultCommand :: FilePath -> VaultCommand -> IO ExitCode
runVaultCommand _repoRoot command = case command of
  VaultStatus -> do
    result <- vaultSealStatus defaultVaultAddress
    case result of
      Left err -> do
        writeOutput
          ( "Vault: unreachable at "
              ++ Text.unpack (unVaultAddress defaultVaultAddress)
              ++ " ("
              ++ renderHttpError err
              ++ ")"
          )
        pure (ExitFailure 1)
      Right status -> do
        writeOutput (renderSealStatus status)
        pure ExitSuccess
  _ -> do
    writeOutput (notYetAvailable command)
    pure (ExitFailure 1)

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
    ++ " is not yet available on this build: the unlock-bundle crypto and the"
    ++ " Vault API client are implemented and validated, but the init/unseal"
    ++ " orchestration and the authenticated (token-bearing) surface are still"
    ++ " being built. Run `prodbox vault status` to probe the in-cluster Vault."

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
