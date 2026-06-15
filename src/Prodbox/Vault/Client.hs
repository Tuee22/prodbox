{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.36: the Vault HTTP client for the host-side lifecycle surface
-- (@prodbox vault status|init|unseal|seal|reconcile@). It speaks Vault's HTTP
-- API through the native 'Prodbox.Http.Client' (no curl) in two layers:
--
--   * the __unauthenticated bootstrap trio__ — @sys/seal-status@, @sys/init@,
--     and @sys/unseal@ — plus the pure 'bootstrapAction' decision and the
--     'initResponseToUnlockBundle' capture into "Prodbox.Vault.UnlockBundle";
--   * the __authenticated (token-bearing) surface__ — @sys/seal@, KV v2 read /
--     write, and Transit encrypt / decrypt — keyed on a 'VaultToken' via the
--     @X-Vault-Token@ header. This is the surface 'SecretRef.Vault' resolution
--     (Sprint 3.17), the Transit-backed envelope @DekCipher@ (Sprint 3.17), and
--     @vault reconcile@ build on.
--
-- The live init / unseal / seal exercise is gated on a deployed in-cluster
-- Vault (Sprint 3.17 + a reconciled cluster); the wire format here is unit-
-- tested offline through the request/response JSON instances.
module Prodbox.Vault.Client
  ( VaultAddress (..)
  , VaultToken (..)
  , SealStatus (..)
  , InitRequest (..)
  , InitResponse (..)
  , BootstrapAction (..)
  , KvV2WriteRequest (..)
  , KvV2ReadResponse (..)
  , TransitEncryptRequest (..)
  , TransitEncryptResponse (..)
  , TransitDecryptRequest (..)
  , TransitDecryptResponse (..)
  , defaultInitRequest
  , bootstrapAction
  , initResponseToUnlockBundle
  , vaultSealStatus
  , vaultInit
  , vaultSubmitUnseal
  , vaultSeal
  , vaultKvReadV2
  , vaultKvWriteV2
  , vaultTransitEncrypt
  , vaultTransitDecrypt
  )
where

import Control.Monad (void)
import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , Value
  , object
  , withObject
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as B64
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Types.Header (Header)
import Numeric.Natural (Natural)
import Prodbox.Http.Client
  ( HttpError (..)
  , defaultHttpConfig
  , httpGetJson
  , httpGetJsonWithHeaders
  , httpPostJsonResponseJson
  , httpPostJsonWithHeaders
  , httpRequestNoBody
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

-- | A Vault authentication token, sent as the @X-Vault-Token@ header on every
-- authenticated request. Never logged.
newtype VaultToken = VaultToken {unVaultToken :: Text}
  deriving (Eq, Show)

vaultTokenHeader :: VaultToken -> Header
vaultTokenHeader token =
  ("X-Vault-Token", TextEncoding.encodeUtf8 (unVaultToken token))

-- | The @POST \/v1\/\<mount\>\/data\/\<path\>@ KV v2 write body: the field map
-- nested under a top-level @data@ key.
newtype KvV2WriteRequest = KvV2WriteRequest (Map Text Text)
  deriving (Eq, Show)

instance ToJSON KvV2WriteRequest where
  toJSON (KvV2WriteRequest fields) = object ["data" .= fields]

-- | The decoded @GET \/v1\/\<mount\>\/data\/\<path\>@ KV v2 read response. The
-- secret fields live at @.data.data@; the surrounding @.data.metadata@ is
-- ignored.
newtype KvV2ReadResponse = KvV2ReadResponse {kvV2ReadData :: Map Text Text}
  deriving (Eq, Show)

instance FromJSON KvV2ReadResponse where
  parseJSON =
    withObject "KvV2ReadResponse" $ \o -> do
      outer <- o .: "data"
      KvV2ReadResponse <$> outer .: "data"

-- | The @POST \/v1\/transit\/encrypt\/\<key\>@ request body. @plaintext@ is the
-- base64-encoded plaintext.
newtype TransitEncryptRequest = TransitEncryptRequest {transitEncryptPlaintextB64 :: Text}
  deriving (Eq, Show)

instance ToJSON TransitEncryptRequest where
  toJSON req = object ["plaintext" .= transitEncryptPlaintextB64 req]

-- | The decoded Transit encrypt response: the wrapped ciphertext token
-- (@vault:v1:...@) at @.data.ciphertext@.
newtype TransitEncryptResponse = TransitEncryptResponse {transitCiphertext :: Text}
  deriving (Eq, Show)

instance FromJSON TransitEncryptResponse where
  parseJSON =
    withObject "TransitEncryptResponse" $ \o -> do
      d <- o .: "data"
      TransitEncryptResponse <$> d .: "ciphertext"

-- | The @POST \/v1\/transit\/decrypt\/\<key\>@ request body.
newtype TransitDecryptRequest = TransitDecryptRequest {transitDecryptCiphertext :: Text}
  deriving (Eq, Show)

instance ToJSON TransitDecryptRequest where
  toJSON req = object ["ciphertext" .= transitDecryptCiphertext req]

-- | The decoded Transit decrypt response: the base64-encoded plaintext at
-- @.data.plaintext@.
newtype TransitDecryptResponse = TransitDecryptResponse {transitPlaintextB64 :: Text}
  deriving (Eq, Show)

instance FromJSON TransitDecryptResponse where
  parseJSON =
    withObject "TransitDecryptResponse" $ \o -> do
      d <- o .: "data"
      TransitDecryptResponse <$> d .: "plaintext"

-- | @PUT \/v1\/sys\/seal@ — re-seal an unsealed Vault. Requires a token with
-- the @sys/seal@ capability; responds 204 No Content on success.
vaultSeal :: VaultAddress -> VaultToken -> IO (Either HttpError ())
vaultSeal address token =
  httpRequestNoBody
    defaultHttpConfig
    "PUT"
    [vaultTokenHeader token]
    (vaultUrl address "/v1/sys/seal")

-- | @GET \/v1\/\<mount\>\/data\/\<path\>@ — read a KV v2 secret's field map.
vaultKvReadV2
  :: VaultAddress -> VaultToken -> Text -> Text -> IO (Either HttpError (Map Text Text))
vaultKvReadV2 address token mount path = do
  result <-
    httpGetJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address (kvV2DataPath mount path))
  pure (fmap kvV2ReadData result)

-- | @POST \/v1\/\<mount\>\/data\/\<path\>@ — write a KV v2 secret's field map.
-- The 200 response carries version metadata, which is ignored.
vaultKvWriteV2
  :: VaultAddress -> VaultToken -> Text -> Text -> Map Text Text -> IO (Either HttpError ())
vaultKvWriteV2 address token mount path fields = do
  result <-
    httpPostJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address (kvV2DataPath mount path))
      (KvV2WriteRequest fields)
  pure (void (result :: Either HttpError Value))

-- | @POST \/v1\/transit\/encrypt\/\<key\>@ — wrap a plaintext blob under a
-- Transit key, returning the @vault:v1:...@ ciphertext token.
vaultTransitEncrypt
  :: VaultAddress -> VaultToken -> Text -> ByteString -> IO (Either HttpError Text)
vaultTransitEncrypt address token keyName plaintext = do
  let body = TransitEncryptRequest (TextEncoding.decodeUtf8 (B64.encode plaintext))
  result <-
    httpPostJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address ("/v1/transit/encrypt/" ++ Text.unpack keyName))
      body
  pure (fmap transitCiphertext result)

-- | @POST \/v1\/transit\/decrypt\/\<key\>@ — unwrap a @vault:v1:...@ ciphertext
-- token back to the original plaintext bytes.
vaultTransitDecrypt
  :: VaultAddress -> VaultToken -> Text -> Text -> IO (Either HttpError ByteString)
vaultTransitDecrypt address token keyName ciphertext = do
  let body = TransitDecryptRequest ciphertext
  result <-
    httpPostJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address ("/v1/transit/decrypt/" ++ Text.unpack keyName))
      body
  pure (result >>= decodeTransitPlaintext)
 where
  decodeTransitPlaintext (TransitDecryptResponse b64) =
    case B64.decode (TextEncoding.encodeUtf8 b64) of
      Left err -> Left (HttpDecode ("Transit plaintext base64 decode failed: " ++ err))
      Right bytes -> Right bytes

kvV2DataPath :: Text -> Text -> String
kvV2DataPath mount path =
  "/v1/" ++ Text.unpack mount ++ "/data/" ++ Text.unpack path
