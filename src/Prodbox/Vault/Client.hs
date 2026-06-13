{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.36: a minimal Vault HTTP client for the host-side lifecycle
-- surface (@prodbox vault status|init|unseal@). It speaks the unauthenticated
-- @sys/seal-status@, @sys/init@, and @sys/unseal@ endpoints of Vault's HTTP
-- API through the native 'Prodbox.Http.Client' (no curl), and ties the init
-- response to the encrypted unlock bundle of "Prodbox.Vault.UnlockBundle".
--
-- The authenticated surface (@sys/seal@ with @X-Vault-Token@, KV, Transit,
-- PKI) lands with the rest of Sprint 1.36 once the token-bearing request
-- helper is in place; the seal-status / init / unseal trio is the bootstrap
-- engine the cluster-reconcile integration (Sprint 4.29) and the live unseal
-- exercise (gated on the deployed Vault, Sprint 3.17) build on.
module Prodbox.Vault.Client
  ( VaultAddress (..)
  , SealStatus (..)
  , InitRequest (..)
  , InitResponse (..)
  , BootstrapAction (..)
  , defaultInitRequest
  , bootstrapAction
  , initResponseToUnlockBundle
  , vaultSealStatus
  , vaultInit
  , vaultSubmitUnseal
  )
where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , object
  , withObject
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Http.Client
  ( HttpError
  , defaultHttpConfig
  , httpGetJson
  , httpPostJsonResponseJson
  )
import Prodbox.Vault.UnlockBundle (UnlockBundle (..))

-- | The base URL of the Vault server, e.g.
-- @http:\/\/127.0.0.1:8200@ (the host-reachable in-cluster Vault endpoint,
-- mirroring the gateway-daemon NodePort-on-127.0.0.1 pattern).
newtype VaultAddress = VaultAddress {unVaultAddress :: Text}
  deriving (Eq, Show)

-- | The decoded @GET \/v1\/sys\/seal-status@ response (the fields prodbox
-- reasons about; Vault returns more).
data SealStatus = SealStatus
  { sealStatusInitialized :: Bool
  , sealStatusSealed :: Bool
  , sealStatusThreshold :: Natural
  , sealStatusShares :: Natural
  , sealStatusProgress :: Natural
  }
  deriving (Eq, Show)

instance FromJSON SealStatus where
  parseJSON =
    withObject "SealStatus" $ \o ->
      SealStatus
        <$> o .: "initialized"
        <*> o .: "sealed"
        <*> o .: "t"
        <*> o .: "n"
        <*> o .: "progress"

-- | The @POST \/v1\/sys\/init@ request body.
data InitRequest = InitRequest
  { initRequestSecretShares :: Natural
  , initRequestSecretThreshold :: Natural
  }
  deriving (Eq, Show)

instance ToJSON InitRequest where
  toJSON req =
    object
      [ "secret_shares" .= initRequestSecretShares req
      , "secret_threshold" .= initRequestSecretThreshold req
      ]

-- | The standard 5-share / 3-threshold Shamir init parameters.
defaultInitRequest :: InitRequest
defaultInitRequest =
  InitRequest {initRequestSecretShares = 5, initRequestSecretThreshold = 3}

-- | The decoded @POST \/v1\/sys\/init@ response. Recovery keys are present
-- only for auto-unseal/seal-wrapped configurations, so they default to empty.
data InitResponse = InitResponse
  { initResponseKeysBase64 :: [Text]
  , initResponseRecoveryKeysBase64 :: [Text]
  , initResponseRootToken :: Text
  }
  deriving (Eq, Show)

instance FromJSON InitResponse where
  parseJSON =
    withObject "InitResponse" $ \o ->
      InitResponse
        <$> o .: "keys_base64"
        <*> (fromMaybe [] <$> o .:? "recovery_keys_base64")
        <*> o .: "root_token"

-- | The @POST \/v1\/sys\/unseal@ request body (one key share per call).
newtype UnsealRequest = UnsealRequest Text

instance ToJSON UnsealRequest where
  toJSON (UnsealRequest key) = object ["key" .= key]

-- | What @prodbox vault@ should do given the current seal status. Pure so
-- the init-if-empty decision is unit-tested without a live Vault.
data BootstrapAction
  = -- | Vault has no state — initialize it (once).
    BootstrapInitialize
  | -- | Initialized but sealed — unseal it from the unlock bundle.
    BootstrapUnseal
  | -- | Initialized and unsealed — nothing to do.
    BootstrapReady
  deriving (Eq, Show)

bootstrapAction :: SealStatus -> BootstrapAction
bootstrapAction status
  | not (sealStatusInitialized status) = BootstrapInitialize
  | sealStatusSealed status = BootstrapUnseal
  | otherwise = BootstrapReady

-- | Build the host-side unlock bundle from a fresh init response. The
-- unseal/recovery keys and root token are captured exactly once here; the
-- caller immediately encrypts the bundle via
-- 'Prodbox.Vault.UnlockBundle.encryptUnlockBundle' and never logs them.
initResponseToUnlockBundle
  :: Text -> VaultAddress -> Text -> InitResponse -> UnlockBundle
initResponseToUnlockBundle clusterId address createdAt response =
  UnlockBundle
    { unlockBundleClusterId = clusterId
    , unlockBundleVaultAddressHint = unVaultAddress address
    , unlockBundleCreatedAt = createdAt
    , unlockBundleUnsealKeys = initResponseKeysBase64 response
    , unlockBundleRecoveryKeys = initResponseRecoveryKeysBase64 response
    , unlockBundleInitialRootToken = initResponseRootToken response
    , unlockBundleFormatVersion = 1
    }

vaultUrl :: VaultAddress -> String -> String
vaultUrl address path = Text.unpack (unVaultAddress address) ++ path

-- | @GET \/v1\/sys\/seal-status@ — the unauthenticated readiness probe.
vaultSealStatus :: VaultAddress -> IO (Either HttpError SealStatus)
vaultSealStatus address =
  httpGetJson defaultHttpConfig (vaultUrl address "/v1/sys/seal-status")

-- | @POST \/v1\/sys\/init@ — initialize an uninitialized Vault. The caller
-- must guard on 'bootstrapAction' so an already-initialized Vault is never
-- re-initialized.
vaultInit :: VaultAddress -> InitRequest -> IO (Either HttpError InitResponse)
vaultInit address request =
  httpPostJsonResponseJson defaultHttpConfig (vaultUrl address "/v1/sys/init") request

-- | @POST \/v1\/sys\/unseal@ — submit one unseal key share; the response is
-- the updated seal status (progress advances until @sealed@ flips false).
vaultSubmitUnseal :: VaultAddress -> Text -> IO (Either HttpError SealStatus)
vaultSubmitUnseal address key =
  httpPostJsonResponseJson
    defaultHttpConfig
    (vaultUrl address "/v1/sys/unseal")
    (UnsealRequest key)
