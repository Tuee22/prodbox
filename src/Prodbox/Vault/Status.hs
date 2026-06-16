{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Vault.Status
  ( probeVaultStatusLine
  , renderSealStatus
  , renderVaultUnreachableStatus
  )
where

import Data.Text qualified as Text
import Prodbox.Http.Client (HttpError, renderHttpError)
import Prodbox.Vault.Client
  ( SealStatus (..)
  , VaultAddress (..)
  , vaultSealStatus
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

-- | Probe Vault for status surfaces that should report Vault as one line
-- without duplicating the @prodbox vault status@ handler. The test seam exists
-- only so fake RKE2/edge integration tests do not need to bind an HTTP server
-- on the production Vault NodePort.
probeVaultStatusLine :: VaultAddress -> IO (String, ExitCode)
probeVaultStatusLine address = do
  testStatus <- lookupEnv "PRODBOX_TEST_CLUSTER_VAULT_STATUS"
  case testStatus of
    Just "ready" -> pure (renderSealStatus (SealStatus True False 3 5 0), ExitSuccess)
    Just "sealed" -> pure (renderSealStatus (SealStatus True True 3 5 0), ExitSuccess)
    Just "uninitialized" -> pure (renderSealStatus (SealStatus False True 0 0 0), ExitSuccess)
    Just "unreachable" ->
      pure
        ( "Vault: unreachable at "
            ++ Text.unpack (unVaultAddress address)
            ++ " (test seam)"
        , ExitFailure 1
        )
    Just other ->
      pure
        ( "Vault: invalid PRODBOX_TEST_CLUSTER_VAULT_STATUS="
            ++ other
        , ExitFailure 1
        )
    _ -> do
      result <- vaultSealStatus address
      pure $ case result of
        Left err -> (renderVaultUnreachableStatus address err, ExitFailure 1)
        Right status -> (renderSealStatus status, ExitSuccess)

renderVaultUnreachableStatus :: VaultAddress -> HttpError -> String
renderVaultUnreachableStatus address err =
  "Vault: unreachable at "
    ++ Text.unpack (unVaultAddress address)
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
