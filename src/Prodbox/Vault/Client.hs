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
  , initRequestWithPgpRecipientsLegacy
  , initRequestForPreparedRecipients
  , InitResponse (..)
  , EncryptedVaultInitResponse
  , GenerateRootRequest (..)
  , GenerateRootUpdateRequest
  , GenerateRootResponse (..)
  , TokenAccessorListing (..)
  , BootstrapAction (..)
  , KvV2WriteRequest (..)
  , KvV2ReadResponse (..)
  , KvV2Cas (..)
  , KvV2CasWriteRequest (..)
  , KvV2VersionedSecret (..)
  , KvV2WriteResponse (..)
  , VaultMountInfo (..)
  , VaultMountListing (..)
  , VaultAuthInfo (..)
  , VaultAuthListing (..)
  , EnableMountRequest (..)
  , EnableAuthMethodRequest (..)
  , WritePolicyRequest (..)
  , TransitKeyInfo (..)
  , TransitKeyRequest (..)
  , PkiIssueCertificateRequest (..)
  , PkiIssueCertificateResponse (..)
  , KubernetesAuthConfigRequest (..)
  , KubernetesLoginRequest (..)
  , KubernetesLoginResponse (..)
  , KubernetesRoleRequest (..)
  , TransitEncryptRequest (..)
  , TransitEncryptResponse (..)
  , TransitDecryptRequest (..)
  , TransitDecryptResponse (..)
  , TokenCreateRequest (..)
  , TokenCreateResponse (..)
  , defaultInitRequest
  , bootstrapAction
  , initResponseToUnlockBundle
  , vaultSealStatus
  , vaultInit
  , vaultInitEncrypted
  , vaultSubmitUnseal
  , vaultObserveGenerateRoot
  , vaultStartGenerateRoot
  , vaultSubmitGenerateRootShareLegacy
  , vaultCancelGenerateRoot
  , vaultListTokenAccessors
  , vaultRevokeTokenAccessor
  , vaultTokenAccessorAbsent
  , vaultSeal
  , vaultKvReadV2
  , vaultKvReadVersionedV2
  , vaultKvCasWriteV2
  , vaultKvWriteV2
  , vaultListMounts
  , vaultEnableMount
  , vaultListAuthMethods
  , vaultEnableAuthMethod
  , vaultWritePolicy
  , vaultReadTransitKey
  , vaultCreateTransitKey
  , vaultRotateTransitKey
  , vaultPkiIssueTestCertificate
  , vaultWriteKubernetesAuthConfig
  , vaultKubernetesLogin
  , vaultKubernetesLoginWithLease
  , VaultKubernetesLoginResult (..)
  , vaultWriteKubernetesRole
  , vaultCreateToken
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
  , (.!=)
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.Aeson.Types (Pair, Parser)
import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as B64
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.HTTP.Types.Header (Header)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.PgpBoundary
  ( PreparedInitRecipients
  , preparedInitBurnPublicKeyBase64
  , preparedInitRecipientShareCount
  , preparedInitRecipientThreshold
  , preparedInitRecoveryPublicKeysBase64
  )
import Prodbox.Bootstrap.Broker.VaultWire (EncryptedVaultInitResponse)
import Prodbox.Http.Client
  ( HttpError (..)
  , defaultHttpConfig
  , httpGetJson
  , httpGetJsonWithHeaders
  , httpPostJsonNoResponse
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

instance ToJSON SealStatus where
  toJSON status =
    object
      [ "initialized" .= sealStatusInitialized status
      , "sealed" .= sealStatusSealed status
      , "t" .= sealStatusThreshold status
      , "n" .= sealStatusShares status
      , "progress" .= sealStatusProgress status
      ]

-- | The retained Standard-P @POST \/v1\/sys\/init@ DTO.  Target Broker code
-- obtains this value only from 'initRequestForPreparedRecipients'; legacy
-- callers still construct the raw DTO until the rollback path is removed.
data InitRequest = InitRequest
  { initRequestSecretShares :: Maybe Natural
  , initRequestSecretThreshold :: Maybe Natural
  , initRequestRecoveryShares :: Maybe Natural
  , initRequestRecoveryThreshold :: Maybe Natural
  , initRequestPgpKeys :: [Text]
  , initRequestRootTokenPgpKey :: Maybe Text
  }
  deriving (Eq, Show)

instance ToJSON InitRequest where
  toJSON req =
    object
      ( maybeField "secret_shares" (initRequestSecretShares req)
          ++ maybeField "secret_threshold" (initRequestSecretThreshold req)
          ++ maybeField "recovery_shares" (initRequestRecoveryShares req)
          ++ maybeField "recovery_threshold" (initRequestRecoveryThreshold req)
          ++ listField "pgp_keys" (initRequestPgpKeys req)
          ++ maybeField "root_token_pgp_key" (initRequestRootTokenPgpKey req)
      )

-- | The standard 5-share / 3-threshold Shamir init parameters.
defaultInitRequest :: InitRequest
defaultInitRequest =
  InitRequest
    { initRequestSecretShares = Just 5
    , initRequestSecretThreshold = Just 3
    , initRequestRecoveryShares = Nothing
    , initRequestRecoveryThreshold = Nothing
    , initRequestPgpKeys = []
    , initRequestRootTokenPgpKey = Nothing
    }

-- | Bind every initialization share and the initial root token to explicit
-- OpenPGP recipients before @sys/init@ is called.  Vault requires one share
-- recipient per configured Shamir/recovery share.  The broker supplies a
-- pinned burn recipient for the root token; no corresponding private key is
-- accepted by this API.
initRequestWithPgpRecipientsLegacy :: [Text] -> Text -> InitRequest -> Either String InitRequest
initRequestWithPgpRecipientsLegacy shareRecipients burnRecipient request
  | expectedShares == Nothing =
      Left "Vault init request does not declare a share count for PGP recipients"
  | Just (fromIntegral (length shareRecipients)) /= expectedShares =
      Left "Vault init PGP recipient count must equal the configured share count"
  | any (Text.null . Text.strip) shareRecipients =
      Left "Vault init PGP share recipients must not be empty"
  | Text.null (Text.strip burnRecipient) =
      Left "Vault init burn recipient must not be empty"
  | otherwise =
      Right
        request
          { initRequestPgpKeys = fmap Text.strip shareRecipients
          , initRequestRootTokenPgpKey = Just (Text.strip burnRecipient)
          }
 where
  expectedShares =
    case initRequestSecretShares request of
      Just shares -> Just shares
      Nothing -> initRequestRecoveryShares request

-- | The target Broker request can be produced only from the evidence that the
-- exact recovery array and burn key match the durable prepared envelope.
initRequestForPreparedRecipients :: PreparedInitRecipients -> InitRequest
initRequestForPreparedRecipients recipients =
  InitRequest
    { initRequestSecretShares = Just (preparedInitRecipientShareCount recipients)
    , initRequestSecretThreshold = Just (preparedInitRecipientThreshold recipients)
    , initRequestRecoveryShares = Nothing
    , initRequestRecoveryThreshold = Nothing
    , initRequestPgpKeys = preparedInitRecoveryPublicKeysBase64 recipients
    , initRequestRootTokenPgpKey = Just (preparedInitBurnPublicKeyBase64 recipients)
    }

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
      InitResponse . fromMaybe []
        <$> o .:? "keys_base64"
        <*> (fromMaybe [] <$> o .:? "recovery_keys_base64")
        <*> o .: "root_token"

maybeField :: (ToJSON a) => Text -> Maybe a -> [Pair]
maybeField fieldName value = case value of
  Nothing -> []
  Just concrete -> [fromString (Text.unpack fieldName) .= concrete]

listField :: (ToJSON a) => Text -> [a] -> [Pair]
listField _ [] = []
listField fieldName values = [fromString (Text.unpack fieldName) .= values]

-- | Request used to start a PGP-protected generated-root attempt.  There is
-- intentionally no OTP constructor: the broker only admits the pinned PGP
-- custody path.
newtype GenerateRootRequest = GenerateRootRequest
  { generateRootPgpKey :: Text
  }
  deriving (Eq, Show)

instance ToJSON GenerateRootRequest where
  toJSON request = object ["pgp_key" .= generateRootPgpKey request]

-- | One unseal/recovery share contribution to an existing generated-root
-- attempt.  The nonce binds the share to exactly that attempt.
data GenerateRootUpdateRequest = GenerateRootUpdateRequest
  { generateRootUpdateKey :: Text
  , generateRootUpdateNonce :: Text
  }
  deriving (Eq)

instance Show GenerateRootUpdateRequest where
  show request =
    "GenerateRootUpdateRequest {key = <redacted>, noncePresent = "
      ++ show (not (Text.null (generateRootUpdateNonce request)))
      ++ "}"

instance ToJSON GenerateRootUpdateRequest where
  toJSON request =
    object
      [ "key" .= generateRootUpdateKey request
      , "nonce" .= generateRootUpdateNonce request
      ]

-- | The non-secret progress/result fields returned by Vault's generated-root
-- protocol.  @encoded_token@ is PGP ciphertext when complete; plaintext/OTP
-- token fields are deliberately absent from the model.
data GenerateRootResponse = GenerateRootResponse
  { generateRootStarted :: Bool
  , generateRootNonce :: Maybe Text
  , generateRootProgress :: Natural
  , generateRootRequired :: Natural
  , generateRootComplete :: Bool
  , generateRootEncodedToken :: Maybe Text
  , generateRootPgpFingerprint :: Maybe Text
  }
  deriving (Eq)

instance Show GenerateRootResponse where
  show response =
    "GenerateRootResponse {started = "
      ++ show (generateRootStarted response)
      ++ ", nonce = "
      ++ show (generateRootNonce response)
      ++ ", progress = "
      ++ show (generateRootProgress response)
      ++ ", required = "
      ++ show (generateRootRequired response)
      ++ ", complete = "
      ++ show (generateRootComplete response)
      ++ ", encodedToken = <redacted>, pgpFingerprint = "
      ++ show (generateRootPgpFingerprint response)
      ++ "}"

instance FromJSON GenerateRootResponse where
  parseJSON =
    withObject "GenerateRootResponse" $ \o ->
      GenerateRootResponse
        <$> o .:? "started" .!= False
        <*> o .:? "nonce"
        <*> o .:? "progress" .!= 0
        <*> o .:? "required" .!= 0
        <*> o .:? "complete" .!= False
        <*> o .:? "encoded_token"
        <*> o .:? "pgp_fingerprint"

-- | Accessors are non-secret token identifiers.  The broker journals the
-- accessor before using the short-lived generated-root token and proves its
-- absence by listing again after revocation.
newtype TokenAccessorListing = TokenAccessorListing
  { tokenAccessorKeys :: [Text]
  }
  deriving (Eq, Show)

instance FromJSON TokenAccessorListing where
  parseJSON =
    withObject "TokenAccessorListing" $ \o -> do
      body <- o .: "data"
      TokenAccessorListing <$> body .:? "keys" .!= []

newtype RevokeTokenAccessorRequest = RevokeTokenAccessorRequest
  { revokeTokenAccessor :: Text
  }

instance ToJSON RevokeTokenAccessorRequest where
  toJSON request = object ["accessor" .= revokeTokenAccessor request]

-- | The @POST \/v1\/auth\/kubernetes\/login@ request body.
data KubernetesLoginRequest = KubernetesLoginRequest
  { kubernetesLoginRequestRole :: Text
  , kubernetesLoginRequestJwt :: Text
  }
  deriving (Eq, Show)

instance ToJSON KubernetesLoginRequest where
  toJSON req =
    object
      [ "role" .= kubernetesLoginRequestRole req
      , "jwt" .= kubernetesLoginRequestJwt req
      ]

-- | The decoded token-bearing response from Vault Kubernetes auth. The
-- @lease_duration@ (seconds) and @renewable@ fields are captured so a cached
-- session can schedule renewal at a fraction of the TTL (Sprint 1.64); older
-- callers that only need the token use 'vaultKubernetesLogin'.
data KubernetesLoginResponse = KubernetesLoginResponse
  { kubernetesLoginResponseClientToken :: Text
  , kubernetesLoginResponseLeaseSeconds :: Int
  , kubernetesLoginResponseRenewable :: Bool
  }
  deriving (Eq, Show)

instance FromJSON KubernetesLoginResponse where
  parseJSON =
    withObject "KubernetesLoginResponse" $ \o -> do
      auth <- o .: "auth"
      KubernetesLoginResponse
        <$> auth .: "client_token"
        <*> auth .:? "lease_duration" .!= 0
        <*> auth .:? "renewable" .!= False

-- | A Vault Kubernetes-auth login result carrying the lease evidence a cached
-- session needs to schedule renewal (Sprint 1.64).
data VaultKubernetesLoginResult = VaultKubernetesLoginResult
  { vaultLoginToken :: VaultToken
  , vaultLoginLeaseSeconds :: Int
  , vaultLoginRenewable :: Bool
  }
  deriving (Eq, Show)

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

-- | Target Broker initialization decoder.  Unlike the retained Standard-P
-- legacy 'vaultInit', this result has no printable/plaintext root-token field:
-- Vault's PGP outputs are projected directly into opaque custody values.
vaultInitEncrypted
  :: VaultAddress
  -> PreparedInitRecipients
  -> IO (Either HttpError EncryptedVaultInitResponse)
vaultInitEncrypted address recipients =
  httpPostJsonResponseJson
    defaultHttpConfig
    (vaultUrl address "/v1/sys/init")
    (initRequestForPreparedRecipients recipients)

-- | @POST \/v1\/sys\/unseal@ — submit one unseal key share; the response is
-- the updated seal status (progress advances until @sealed@ flips false).
vaultSubmitUnseal :: VaultAddress -> Text -> IO (Either HttpError SealStatus)
vaultSubmitUnseal address key =
  httpPostJsonResponseJson
    defaultHttpConfig
    (vaultUrl address "/v1/sys/unseal")
    (UnsealRequest key)

-- | Observe an in-progress generated-root attempt.  No token is required;
-- possession of the threshold unseal/recovery shares authorizes completion.
vaultObserveGenerateRoot :: VaultAddress -> IO (Either HttpError GenerateRootResponse)
vaultObserveGenerateRoot address =
  httpGetJson defaultHttpConfig (vaultUrl address "/v1/sys/generate-root/attempt")

-- | Start a generated-root attempt whose result can only be decrypted by the
-- supplied short-lived recipient.  The broker never starts Vault's OTP mode.
vaultStartGenerateRoot :: VaultAddress -> Text -> IO (Either HttpError GenerateRootResponse)
vaultStartGenerateRoot address pgpPublicKey =
  httpPostJsonResponseJson
    defaultHttpConfig
    (vaultUrl address "/v1/sys/generate-root/attempt")
    (GenerateRootRequest pgpPublicKey)

-- | Standard-P raw-share wrapper.  Target Broker generated-root submission is
-- confined to its one-shot secret-worker/PGP port and never calls this Text
-- API from the long-lived controller.
vaultSubmitGenerateRootShareLegacy
  :: VaultAddress
  -> Text
  -> Text
  -> IO (Either HttpError GenerateRootResponse)
vaultSubmitGenerateRootShareLegacy address nonce share =
  httpPostJsonResponseJson
    defaultHttpConfig
    (vaultUrl address "/v1/sys/generate-root/update")
    (GenerateRootUpdateRequest share nonce)

-- | Cancel an ambiguous or abandoned generated-root attempt before retrying.
vaultCancelGenerateRoot :: VaultAddress -> IO (Either HttpError ())
vaultCancelGenerateRoot address =
  httpRequestNoBody
    defaultHttpConfig
    "DELETE"
    []
    (vaultUrl address "/v1/sys/generate-root/attempt")

-- | List all token accessors through Vault's bounded list query.  The token
-- value itself never appears in the response model.
vaultListTokenAccessors
  :: VaultAddress -> VaultToken -> IO (Either HttpError TokenAccessorListing)
vaultListTokenAccessors address token =
  httpGetJsonWithHeaders
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address "/v1/auth/token/accessors?list=true")

-- | Revoke a token by its journaled accessor.
vaultRevokeTokenAccessor
  :: VaultAddress -> VaultToken -> Text -> IO (Either HttpError ())
vaultRevokeTokenAccessor address token accessor =
  httpPostJsonNoResponse
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address "/v1/auth/token/revoke-accessor")
    (RevokeTokenAccessorRequest accessor)

-- | Authoritative post-revocation readback used before the broker may report
-- generated-root session cleanup complete.
vaultTokenAccessorAbsent
  :: VaultAddress -> VaultToken -> Text -> IO (Either HttpError Bool)
vaultTokenAccessorAbsent address token accessor =
  fmap (fmap (notElem accessor . tokenAccessorKeys)) (vaultListTokenAccessors address token)

-- | A Vault authentication token, sent as the @X-Vault-Token@ header on every
-- authenticated request. Never logged.
newtype VaultToken = VaultToken {unVaultToken :: Text}
  deriving (Eq)

instance Show VaultToken where
  show _ = "VaultToken <redacted>"

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

-- | Vault KV v2 check-and-set version. Version @0@ means create only when the
-- key is absent; a positive value means replace exactly that version.
newtype KvV2Cas = KvV2Cas {kvV2CasVersion :: Natural}
  deriving (Eq, Ord, Show)

data KvV2CasWriteRequest = KvV2CasWriteRequest
  { kvV2CasWriteData :: !(Map Text Text)
  , kvV2CasWriteExpectedVersion :: !KvV2Cas
  }
  deriving (Eq, Show)

instance ToJSON KvV2CasWriteRequest where
  toJSON request =
    object
      [ "data" .= kvV2CasWriteData request
      , "options"
          .= object
            [ "cas" .= kvV2CasVersion (kvV2CasWriteExpectedVersion request)
            ]
      ]

data KvV2VersionedSecret = KvV2VersionedSecret
  { kvV2VersionedSecretData :: !(Map Text Text)
  , kvV2VersionedSecretVersion :: !Natural
  }
  deriving (Eq, Show)

instance FromJSON KvV2VersionedSecret where
  parseJSON =
    withObject "KvV2VersionedSecret" $ \o -> do
      outer <- o .: "data"
      fields <- outer .: "data"
      metadata <- outer .: "metadata"
      KvV2VersionedSecret fields <$> metadata .: "version"

newtype KvV2WriteResponse = KvV2WriteResponse
  { kvV2WriteResponseVersion :: Natural
  }
  deriving (Eq, Show)

instance FromJSON KvV2WriteResponse where
  parseJSON =
    withObject "KvV2WriteResponse" $ \o -> do
      metadata <- o .: "data"
      KvV2WriteResponse <$> metadata .: "version"

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

-- | @POST \/v1\/auth\/token\/create@ request for a scoped child bootstrap
-- token. The token itself is returned by Vault and is never logged by callers.
data TokenCreateRequest = TokenCreateRequest
  { tokenCreatePolicies :: [Text]
  , tokenCreateTtl :: Text
  , tokenCreateRenewable :: Bool
  , tokenCreateNoParent :: Bool
  }
  deriving (Eq, Show)

instance ToJSON TokenCreateRequest where
  toJSON req =
    object
      [ "policies" .= tokenCreatePolicies req
      , "ttl" .= tokenCreateTtl req
      , "renewable" .= tokenCreateRenewable req
      , "no_parent" .= tokenCreateNoParent req
      ]

newtype TokenCreateResponse = TokenCreateResponse
  { tokenCreateClientToken :: Text
  }
  deriving (Eq, Show)

instance FromJSON TokenCreateResponse where
  parseJSON =
    withObject "TokenCreateResponse" $ \o -> do
      auth <- o .: "auth"
      TokenCreateResponse <$> auth .: "client_token"

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

-- | Version-preserving KV v2 read used by bounded target-secret readback.
vaultKvReadVersionedV2
  :: VaultAddress
  -> VaultToken
  -> Text
  -> Text
  -> IO (Either HttpError KvV2VersionedSecret)
vaultKvReadVersionedV2 address token mount path =
  httpGetJsonWithHeaders
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address (kvV2DataPath mount path))

-- | Perform exactly one KV v2 CAS attempt and preserve Vault's resulting
-- version. A mismatch remains an 'HttpStatus'; the gateway route performs an
-- authoritative readback and returns a conflict observation without retrying.
vaultKvCasWriteV2
  :: VaultAddress
  -> VaultToken
  -> Text
  -> Text
  -> KvV2Cas
  -> Map Text Text
  -> IO (Either HttpError Natural)
vaultKvCasWriteV2 address token mount path expectedVersion fields = do
  result <-
    httpPostJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address (kvV2DataPath mount path))
      KvV2CasWriteRequest
        { kvV2CasWriteData = fields
        , kvV2CasWriteExpectedVersion = expectedVersion
        }
  pure (kvV2WriteResponseVersion <$> (result :: Either HttpError KvV2WriteResponse))

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

-- | One entry returned by @GET \/v1\/sys\/mounts@. Vault reports keys with a
-- trailing slash; prodbox normalizes them to slash-free mount paths.
data VaultMountInfo = VaultMountInfo
  { vaultMountPath :: Text
  , vaultMountType :: Text
  , vaultMountOptions :: Map Text Text
  }
  deriving (Eq, Show)

newtype VaultMountListing = VaultMountListing
  { unVaultMountListing :: Map Text VaultMountInfo
  }

instance FromJSON VaultMountListing where
  parseJSON =
    withObject "VaultMountListing" $ \o -> do
      listing <- vaultListingObject "VaultMountListing" o
      entries <- traverse parseMount (AesonKeyMap.toList listing)
      pure (VaultMountListing (Map.fromList entries))
   where
    parseMount (rawPath, value) =
      withObject "VaultMountInfo" parseMountInfo value
     where
      path = normalizeVaultPath (AesonKey.toText rawPath)
      parseMountInfo info = do
        mountType <- info .: "type"
        options <- fromMaybe Map.empty <$> info .:? "options"
        pure (path, VaultMountInfo path mountType options)

-- | One entry returned by @GET \/v1\/sys\/auth@, normalized the same way as
-- mounts.
data VaultAuthInfo = VaultAuthInfo
  { vaultAuthPath :: Text
  , vaultAuthType :: Text
  }
  deriving (Eq, Show)

newtype VaultAuthListing = VaultAuthListing
  { unVaultAuthListing :: Map Text VaultAuthInfo
  }

instance FromJSON VaultAuthListing where
  parseJSON =
    withObject "VaultAuthListing" $ \o -> do
      listing <- vaultListingObject "VaultAuthListing" o
      entries <- traverse parseAuth (AesonKeyMap.toList listing)
      pure (VaultAuthListing (Map.fromList entries))
   where
    parseAuth (rawPath, value) =
      withObject "VaultAuthInfo" parseAuthInfo value
     where
      path = normalizeVaultPath (AesonKey.toText rawPath)
      parseAuthInfo info = do
        authType <- info .: "type"
        pure (path, VaultAuthInfo path authType)

vaultListingObject
  :: String
  -> AesonKeyMap.KeyMap Value
  -> Parser (AesonKeyMap.KeyMap Value)
vaultListingObject label o =
  case AesonKeyMap.lookup "data" o of
    Nothing -> pure o
    Just wrapped -> withObject (label ++ ".data") pure wrapped

-- | @POST \/v1\/sys\/mounts\/\<path\>@ request.
data EnableMountRequest = EnableMountRequest
  { enableMountType :: Text
  , enableMountOptions :: Map Text Text
  }
  deriving (Eq, Show)

instance ToJSON EnableMountRequest where
  toJSON req =
    object
      [ "type" .= enableMountType req
      , "options" .= enableMountOptions req
      ]

-- | @POST \/v1\/sys\/auth\/\<path\>@ request.
newtype EnableAuthMethodRequest = EnableAuthMethodRequest
  { enableAuthMethodType :: Text
  }
  deriving (Eq, Show)

instance ToJSON EnableAuthMethodRequest where
  toJSON req =
    object ["type" .= enableAuthMethodType req]

-- | @POST \/v1\/sys\/policies\/acl\/\<name\>@ request.
newtype WritePolicyRequest = WritePolicyRequest
  { writePolicyPolicy :: Text
  }
  deriving (Eq, Show)

instance ToJSON WritePolicyRequest where
  toJSON req =
    object ["policy" .= writePolicyPolicy req]

-- | Decoded @GET \/v1\/transit\/keys\/\<name\>@ response.
data TransitKeyInfo = TransitKeyInfo
  { transitKeyName :: Text
  , transitKeyType :: Text
  }
  deriving (Eq, Show)

newtype TransitKeyReadResponse = TransitKeyReadResponse
  { transitKeyReadType :: Text
  }

instance FromJSON TransitKeyReadResponse where
  parseJSON =
    withObject "TransitKeyReadResponse" $ \o -> do
      d <- o .: "data"
      TransitKeyReadResponse <$> d .: "type"

-- | @POST \/v1\/transit\/keys\/\<name\>@ request.
newtype TransitKeyRequest = TransitKeyRequest
  { transitKeyRequestType :: Text
  }
  deriving (Eq, Show)

instance ToJSON TransitKeyRequest where
  toJSON req =
    object ["type" .= transitKeyRequestType req]

-- | @POST \/v1\/pki\/issue\/\<role\>@ request.
data PkiIssueCertificateRequest = PkiIssueCertificateRequest
  { pkiIssueCertificateCommonName :: Text
  , pkiIssueCertificateTtl :: Text
  }
  deriving (Eq, Show)

instance ToJSON PkiIssueCertificateRequest where
  toJSON req =
    object
      [ "common_name" .= pkiIssueCertificateCommonName req
      , "ttl" .= pkiIssueCertificateTtl req
      ]

-- | Decoded Vault PKI issue response. The certificate is PEM text at
-- @.data.certificate@; private key material is intentionally ignored here.
newtype PkiIssueCertificateResponse = PkiIssueCertificateResponse
  { pkiIssueCertificatePem :: Text
  }
  deriving (Eq, Show)

instance FromJSON PkiIssueCertificateResponse where
  parseJSON =
    withObject "PkiIssueCertificateResponse" $ \o -> do
      d <- o .: "data"
      PkiIssueCertificateResponse <$> d .: "certificate"

-- | @POST \/v1\/auth\/kubernetes\/config@ request.
newtype KubernetesAuthConfigRequest = KubernetesAuthConfigRequest
  { kubernetesAuthConfigHost :: Text
  }
  deriving (Eq, Show)

instance ToJSON KubernetesAuthConfigRequest where
  toJSON req =
    object ["kubernetes_host" .= kubernetesAuthConfigHost req]

-- | @POST \/v1\/auth\/kubernetes\/role\/\<role\>@ request.
data KubernetesRoleRequest = KubernetesRoleRequest
  { kubernetesRoleServiceAccounts :: [Text]
  , kubernetesRoleNamespaces :: [Text]
  , kubernetesRolePolicies :: [Text]
  , kubernetesRoleTtl :: Text
  }
  deriving (Eq, Show)

instance ToJSON KubernetesRoleRequest where
  toJSON req =
    object
      [ "bound_service_account_names" .= kubernetesRoleServiceAccounts req
      , "bound_service_account_namespaces" .= kubernetesRoleNamespaces req
      , "token_policies" .= kubernetesRolePolicies req
      , "token_ttl" .= kubernetesRoleTtl req
      ]

-- | @GET \/v1\/sys\/mounts@ — list currently-enabled secret engines.
vaultListMounts :: VaultAddress -> VaultToken -> IO (Either HttpError (Map Text VaultMountInfo))
vaultListMounts address token = do
  result <-
    httpGetJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address "/v1/sys/mounts")
  pure (fmap unVaultMountListing result)

-- | @POST \/v1\/sys\/mounts\/\<path\>@ — enable a secret engine at a mount.
vaultEnableMount
  :: VaultAddress -> VaultToken -> Text -> Text -> Map Text Text -> IO (Either HttpError ())
vaultEnableMount address token mount mountType options =
  httpPostJsonNoResponse
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address ("/v1/sys/mounts/" ++ Text.unpack (normalizeVaultPath mount)))
    (EnableMountRequest mountType options)

-- | @GET \/v1\/sys\/auth@ — list enabled auth methods.
vaultListAuthMethods :: VaultAddress -> VaultToken -> IO (Either HttpError (Map Text VaultAuthInfo))
vaultListAuthMethods address token = do
  result <-
    httpGetJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address "/v1/sys/auth")
  pure (fmap unVaultAuthListing result)

-- | @POST \/v1\/sys\/auth\/\<path\>@ — enable an auth method.
vaultEnableAuthMethod
  :: VaultAddress -> VaultToken -> Text -> Text -> IO (Either HttpError ())
vaultEnableAuthMethod address token authPath authType =
  httpPostJsonNoResponse
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address ("/v1/sys/auth/" ++ Text.unpack (normalizeVaultPath authPath)))
    (EnableAuthMethodRequest authType)

-- | @POST \/v1\/sys\/policies\/acl\/\<name\>@ — create or replace an ACL
-- policy.
vaultWritePolicy :: VaultAddress -> VaultToken -> Text -> Text -> IO (Either HttpError ())
vaultWritePolicy address token policyName policy =
  httpPostJsonNoResponse
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address ("/v1/sys/policies/acl/" ++ Text.unpack policyName))
    (WritePolicyRequest policy)

-- | @GET \/v1\/transit\/keys\/\<name\>@ — read Transit key metadata.
vaultReadTransitKey
  :: VaultAddress -> VaultToken -> Text -> IO (Either HttpError TransitKeyInfo)
vaultReadTransitKey address token keyName = do
  result <-
    httpGetJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address ("/v1/transit/keys/" ++ Text.unpack keyName))
  pure (fmap (\response -> TransitKeyInfo keyName (transitKeyReadType response)) result)

-- | @POST \/v1\/transit\/keys\/\<name\>@ — create a Transit key. Reconcile
-- callers should probe first with 'vaultReadTransitKey' so this remains
-- idempotent.
vaultCreateTransitKey
  :: VaultAddress -> VaultToken -> Text -> Text -> IO (Either HttpError ())
vaultCreateTransitKey address token keyName keyType =
  httpPostJsonNoResponse
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address ("/v1/transit/keys/" ++ Text.unpack keyName))
    (TransitKeyRequest keyType)

-- | @POST \/v1\/transit\/keys\/\<name\>\/rotate@ — rotate a named Transit key
-- to a new key version.
vaultRotateTransitKey :: VaultAddress -> VaultToken -> Text -> IO (Either HttpError ())
vaultRotateTransitKey address token keyName =
  httpRequestNoBody
    defaultHttpConfig
    "POST"
    [vaultTokenHeader token]
    (vaultUrl address ("/v1/transit/keys/" ++ Text.unpack keyName ++ "/rotate"))

-- | @POST \/v1\/pki\/issue\/\<role\>@ — issue a short-lived test certificate
-- from an already-configured PKI role.
vaultPkiIssueTestCertificate
  :: VaultAddress
  -> VaultToken
  -> Text
  -> Text
  -> Text
  -> IO (Either HttpError Text)
vaultPkiIssueTestCertificate address token role commonName ttl = do
  result <-
    httpPostJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address ("/v1/pki/issue/" ++ Text.unpack role))
      (PkiIssueCertificateRequest commonName ttl)
  pure (fmap pkiIssueCertificatePem result)

-- | @POST \/v1\/auth\/\<path\>\/config@ — configure Kubernetes auth against
-- the in-cluster API. The Vault server loads its local service-account token
-- and CA cert from the pod filesystem when those fields are omitted.
vaultWriteKubernetesAuthConfig
  :: VaultAddress -> VaultToken -> Text -> Text -> IO (Either HttpError ())
vaultWriteKubernetesAuthConfig address token authPath kubernetesHost =
  httpPostJsonNoResponse
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address ("/v1/auth/" ++ Text.unpack authPath ++ "/config"))
    (KubernetesAuthConfigRequest kubernetesHost)

-- | @POST \/v1\/auth\/\<path\>\/login@ — exchange a Kubernetes service-account
-- JWT for a Vault token bound to a configured Vault role.
vaultKubernetesLogin
  :: VaultAddress -> Text -> Text -> Text -> IO (Either HttpError VaultToken)
vaultKubernetesLogin address authPath role jwt =
  fmap (fmap vaultLoginToken) (vaultKubernetesLoginWithLease address authPath role jwt)

-- | @POST \/v1\/auth\/\<path\>\/login@ returning the full lease evidence (token,
-- @lease_duration@ seconds, @renewable@) the cached session in
-- 'Prodbox.Vault.Session' needs to schedule renewal (Sprint 1.64).
vaultKubernetesLoginWithLease
  :: VaultAddress
  -> Text
  -> Text
  -> Text
  -> IO (Either HttpError VaultKubernetesLoginResult)
vaultKubernetesLoginWithLease address authPath role jwt = do
  result <-
    httpPostJsonResponseJson
      defaultHttpConfig
      (vaultUrl address ("/v1/auth/" ++ Text.unpack authPath ++ "/login"))
      (KubernetesLoginRequest role jwt)
  pure (toLoginResult <$> result)
 where
  toLoginResult resp =
    VaultKubernetesLoginResult
      { vaultLoginToken = VaultToken (kubernetesLoginResponseClientToken resp)
      , vaultLoginLeaseSeconds = kubernetesLoginResponseLeaseSeconds resp
      , vaultLoginRenewable = kubernetesLoginResponseRenewable resp
      }

-- | @POST \/v1\/auth\/kubernetes\/role\/\<role\>@ — create or replace a
-- Kubernetes auth role.
vaultWriteKubernetesRole
  :: VaultAddress
  -> VaultToken
  -> Text
  -> [Text]
  -> [Text]
  -> [Text]
  -> Text
  -> IO (Either HttpError ())
vaultWriteKubernetesRole address token role serviceAccounts namespaces policies ttl =
  httpPostJsonNoResponse
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address ("/v1/auth/kubernetes/role/" ++ Text.unpack role))
    (KubernetesRoleRequest serviceAccounts namespaces policies ttl)

vaultCreateToken
  :: VaultAddress
  -> VaultToken
  -> [Text]
  -> Text
  -> IO (Either HttpError VaultToken)
vaultCreateToken address token policies ttl = do
  result <-
    httpPostJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address "/v1/auth/token/create")
      ( TokenCreateRequest
          { tokenCreatePolicies = policies
          , tokenCreateTtl = ttl
          , tokenCreateRenewable = True
          , tokenCreateNoParent = False
          }
      )
  pure (VaultToken . tokenCreateClientToken <$> result)

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

normalizeVaultPath :: Text -> Text
normalizeVaultPath =
  Text.dropWhileEnd (== '/')
