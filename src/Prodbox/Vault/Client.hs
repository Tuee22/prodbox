{-# LANGUAGE OverloadedStrings #-}

-- | Typed Vault HTTP primitives used only behind role-scoped interpreters. It
-- speaks Vault's HTTP API through the native 'Prodbox.Http.Client' (no curl).
--
--   * the __unauthenticated bootstrap trio__ — @sys/seal-status@, PGP-targeted
--     @sys/init@, and @sys/unseal@ — plus the pure 'bootstrapAction' decision;
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
  , initRequestForPreparedRecipients
  , EncryptedVaultInitResponse
  , GenerateRootRequest (..)
  , GenerateRootUpdateRequest (..)
  , GenerateRootResponse (..)
  , TokenAccessorListing (..)
  , TokenAccessorInfo (..)
  , BootstrapAction (..)
  , KvV2WriteRequest (..)
  , KvV2ReadResponse (..)
  , KvV2Cas (..)
  , KvV2CasWriteRequest (..)
  , KvV2VersionedSecret (..)
  , KvV2ExactVersionSecret (..)
  , KvV2WriteResponse (..)
  , KvV2SecretMetadata (..)
  , VaultMountInfo (..)
  , VaultMountListing (..)
  , VaultAuthInfo (..)
  , VaultAuthListing (..)
  , EnableMountRequest (..)
  , EnableAuthMethodRequest (..)
  , WritePolicyRequest (..)
  , TransitKeyInfo (..)
  , TransitSigningKeyInfo (..)
  , TransitSignature (..)
  , TransitKeyRequest (..)
  , PkiIssueCertificateRequest (..)
  , PkiIssueCertificateResponse (..)
  , PkiIssuerListing (..)
  , PkiRoleInfo (..)
  , KubernetesAuthConfigRequest (..)
  , KubernetesLoginRequest (..)
  , KubernetesLoginResponse (..)
  , KubernetesRoleRequest (..)
  , KubernetesRoleReadback (..)
  , TransitEncryptRequest (..)
  , TransitEncryptResponse (..)
  , TransitDecryptRequest (..)
  , TransitDecryptResponse (..)
  , TransitHmacResponse (..)
  , TokenCreateRequest (..)
  , TokenCreateResponse (..)
  , defaultInitRequest
  , bootstrapAction
  , vaultSealStatus
  , vaultInitEncrypted
  , vaultSubmitUnseal
  , vaultObserveGenerateRoot
  , vaultStartGenerateRoot
  , vaultSubmitGenerateRootShare
  , vaultCancelGenerateRoot
  , vaultListTokenAccessors
  , vaultRevokeTokenAccessor
  , vaultRevokeSelf
  , vaultLookupSelfAccessor
  , vaultLookupTokenAccessorPolicies
  , vaultLookupTokenAccessorInfo
  , vaultTokenAccessorAbsent
  , vaultSeal
  , vaultKvReadV2
  , vaultKvReadVersionedV2
  , vaultKvReadExactVersionV2
  , vaultKvCasWriteV2
  , vaultKvWriteV2
  , vaultKvReadMetadataV2
  , vaultKvWriteCustomMetadataV2
  , vaultKvMetadataExistsV2
  , vaultKvDeleteMetadataV2
  , vaultKvDestroyVersionV2
  , vaultListMounts
  , vaultEnableMount
  , vaultListAuthMethods
  , vaultEnableAuthMethod
  , vaultWritePolicy
  , vaultReadTransitKey
  , vaultCreateTransitKey
  , vaultRotateTransitKey
  , vaultReadTransitSigningKey
  , vaultTransitSignEd25519
  , vaultPkiIssueTestCertificate
  , vaultListPkiIssuers
  , vaultGeneratePkiInternalRoot
  , vaultWritePkiRole
  , vaultReadPkiRole
  , vaultWriteKubernetesAuthConfig
  , vaultKubernetesLogin
  , vaultKubernetesLoginWithLease
  , VaultKubernetesLoginResult (..)
  , vaultWriteKubernetesRole
  , vaultWriteKubernetesBatchRole
  , vaultReadKubernetesRole
  , vaultCreateToken
  , vaultTransitEncrypt
  , vaultTransitDecrypt
  , vaultTransitHmacSha256
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
import Text.Read (readMaybe)

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

-- | The Standard-P @POST \/v1\/sys\/init@ DTO. Production submission is only
-- exposed through 'vaultInitEncrypted', which constructs this value from
-- durable prepared-recipient evidence.
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

-- | One recovery/unseal share for an exact generated-root attempt.
data GenerateRootUpdateRequest = GenerateRootUpdateRequest
  { generateRootUpdateKey :: !Text
  , generateRootUpdateNonce :: !Text
  }
  deriving (Eq, Show)

instance ToJSON GenerateRootUpdateRequest where
  toJSON request =
    object
      [ "key" .= generateRootUpdateKey request
      , "nonce" .= generateRootUpdateNonce request
      ]

newtype PkiIssuerListing = PkiIssuerListing
  { pkiIssuerKeys :: [Text]
  }
  deriving (Eq, Show)

instance FromJSON PkiIssuerListing where
  parseJSON =
    withObject "PkiIssuerListing" $ \o -> do
      body <- o .: "data"
      PkiIssuerListing <$> body .:? "keys" .!= []

data PkiInternalRootRequest = PkiInternalRootRequest
  { pkiInternalRootCommonName :: !Text
  , pkiInternalRootTtl :: !Text
  }

instance ToJSON PkiInternalRootRequest where
  toJSON request =
    object
      [ "common_name" .= pkiInternalRootCommonName request
      , "ttl" .= pkiInternalRootTtl request
      , "issuer_name" .= ("prodbox-bootstrap" :: Text)
      , "key_type" .= ("ec" :: Text)
      , "key_bits" .= (256 :: Int)
      ]

data PkiRoleRequest = PkiRoleRequest

instance ToJSON PkiRoleRequest where
  toJSON _ =
    object
      [ "allow_any_name" .= True
      , "max_ttl" .= ("1h" :: Text)
      , "key_type" .= ("ec" :: Text)
      , "key_bits" .= (256 :: Int)
      ]

data PkiRoleInfo = PkiRoleInfo
  { pkiRoleAllowsAnyName :: !Bool
  , pkiRoleMaxTtlSeconds :: !Natural
  , pkiRoleKeyType :: !Text
  }
  deriving (Eq, Show)

instance FromJSON PkiRoleInfo where
  parseJSON =
    withObject "PkiRoleInfo" $ \o -> do
      body <- o .: "data"
      PkiRoleInfo
        <$> body .:? "allow_any_name" .!= False
        <*> body .:? "max_ttl" .!= 0
        <*> body .:? "key_type" .!= ""

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

newtype TokenLookupSelfResponse = TokenLookupSelfResponse
  { tokenLookupSelfAccessor :: Text
  }

instance FromJSON TokenLookupSelfResponse where
  parseJSON =
    withObject "TokenLookupSelfResponse" $ \o -> do
      body <- o .: "data"
      TokenLookupSelfResponse <$> body .: "accessor"

data TokenAccessorInfo = TokenAccessorInfo
  { tokenAccessorInfoPolicies :: ![Text]
  , tokenAccessorInfoMetadata :: !(Map Text Text)
  , tokenAccessorInfoCreationPath :: !Text
  , tokenAccessorInfoDisplayName :: !Text
  }
  deriving (Eq, Show)

newtype TokenAccessorLookupResponse = TokenAccessorLookupResponse
  { tokenAccessorLookupInfo :: TokenAccessorInfo
  }

instance FromJSON TokenAccessorLookupResponse where
  parseJSON =
    withObject "TokenAccessorLookupResponse" $ \o -> do
      body <- o .: "data"
      TokenAccessorLookupResponse
        <$> ( TokenAccessorInfo
                <$> body .:? "policies" .!= []
                <*> body .:? "meta" .!= Map.empty
                <*> body .:? "path" .!= ""
                <*> body .:? "display_name" .!= ""
            )

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
  , kubernetesLoginResponseAccessor :: Text
  , kubernetesLoginResponseLeaseSeconds :: Int
  , kubernetesLoginResponseRenewable :: Bool
  , kubernetesLoginResponseTokenType :: Text
  }
  deriving (Eq, Show)

instance FromJSON KubernetesLoginResponse where
  parseJSON =
    withObject "KubernetesLoginResponse" $ \o -> do
      auth <- o .: "auth"
      KubernetesLoginResponse
        <$> auth .: "client_token"
        <*> auth .:? "accessor" .!= ""
        <*> auth .:? "lease_duration" .!= 0
        <*> auth .:? "renewable" .!= False
        <*> auth .:? "token_type" .!= "service"

-- | A Vault Kubernetes-auth login result carrying the lease evidence a cached
-- session needs to schedule renewal (Sprint 1.64).
data VaultKubernetesLoginResult = VaultKubernetesLoginResult
  { vaultLoginToken :: VaultToken
  , vaultLoginAccessor :: Text
  , vaultLoginLeaseSeconds :: Int
  , vaultLoginRenewable :: Bool
  , vaultLoginTokenType :: Text
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

vaultUrl :: VaultAddress -> String -> String
vaultUrl address path = Text.unpack (unVaultAddress address) ++ path

-- | @GET \/v1\/sys\/seal-status@ — the unauthenticated readiness probe.
vaultSealStatus :: VaultAddress -> IO (Either HttpError SealStatus)
vaultSealStatus address =
  httpGetJson defaultHttpConfig (vaultUrl address "/v1/sys/seal-status")

-- | Target Broker initialization decoder. Vault's PGP outputs are projected
-- directly into opaque custody values; no printable root-token result exists.
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

-- | Submit one share to the exact generated-root attempt.  Completion can
-- return only the PGP-encrypted token represented by 'GenerateRootResponse'.
vaultSubmitGenerateRootShare
  :: VaultAddress
  -> Text
  -> Text
  -> IO (Either HttpError GenerateRootResponse)
vaultSubmitGenerateRootShare address nonce share =
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

-- | Revoke the calling token.  One-shot credential workers invoke this on
-- every post-login terminal path and before emitting any receipt, so Job
-- deletion never intentionally leaves a usable Vault session behind.
vaultRevokeSelf :: VaultAddress -> VaultToken -> IO (Either HttpError ())
vaultRevokeSelf address token =
  httpRequestNoBody
    defaultHttpConfig
    "POST"
    [vaultTokenHeader token]
    (vaultUrl address "/v1/auth/token/revoke-self")

-- | Resolve only the non-secret accessor of the calling token. The token
-- itself stays in the scoped interpreter and is never projected in the
-- response type.
vaultLookupSelfAccessor
  :: VaultAddress -> VaultToken -> IO (Either HttpError Text)
vaultLookupSelfAccessor address token =
  fmap (fmap tokenLookupSelfAccessor) $
    httpGetJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address "/v1/auth/token/lookup-self")

-- | Resolve the policy names of one non-secret accessor. This is the only
-- classifier used by the bootstrap accessor auditor; token values are never
-- returned.
vaultLookupTokenAccessorPolicies
  :: VaultAddress -> VaultToken -> Text -> IO (Either HttpError [Text])
vaultLookupTokenAccessorPolicies address token accessor =
  fmap (fmap (tokenAccessorInfoPolicies . tokenAccessorLookupInfo)) $
    httpPostJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address "/v1/auth/token/lookup-accessor")
      (RevokeTokenAccessorRequest accessor)

-- | Resolve the non-secret policy/identity metadata required by the standing
-- lifecycle cleanup authority to classify a response-lost Kubernetes login.
vaultLookupTokenAccessorInfo
  :: VaultAddress -> VaultToken -> Text -> IO (Either HttpError TokenAccessorInfo)
vaultLookupTokenAccessorInfo address token accessor =
  fmap (fmap tokenAccessorLookupInfo) $
    httpPostJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address "/v1/auth/token/lookup-accessor")
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

-- | One exact KV-v2 version, including Vault's physical-destruction bit.
-- Vault returns @data: null@ for both soft-deleted and destroyed versions, so
-- callers must not treat a missing data document alone as physical absence.
data KvV2ExactVersionSecret = KvV2ExactVersionSecret
  { kvV2ExactVersionSecretData :: !(Maybe (Map Text Text))
  , kvV2ExactVersionSecretVersion :: !Natural
  , kvV2ExactVersionSecretDestroyed :: !Bool
  }
  deriving (Eq, Show)

instance FromJSON KvV2ExactVersionSecret where
  parseJSON =
    withObject "KvV2ExactVersionSecret" $ \o -> do
      outer <- o .: "data"
      fields <- outer .:? "data"
      metadata <- outer .: "metadata"
      version <- metadata .: "version"
      destroyed <- metadata .:? "destroyed" .!= False
      pure
        KvV2ExactVersionSecret
          { kvV2ExactVersionSecretData = fields
          , kvV2ExactVersionSecretVersion = version
          , kvV2ExactVersionSecretDestroyed = destroyed
          }

newtype KvV2WriteResponse = KvV2WriteResponse
  { kvV2WriteResponseVersion :: Natural
  }
  deriving (Eq, Show)

instance FromJSON KvV2WriteResponse where
  parseJSON =
    withObject "KvV2WriteResponse" $ \o -> do
      metadata <- o .: "data"
      KvV2WriteResponse <$> metadata .: "version"

-- | Non-secret KV-v2 metadata. The standing Target Agent may observe this
-- response without receiving the secret data document.
data KvV2SecretMetadata = KvV2SecretMetadata
  { kvV2SecretMetadataCurrentVersion :: !Natural
  , kvV2SecretMetadataCustom :: !(Map Text Text)
  }
  deriving (Eq, Show)

instance FromJSON KvV2SecretMetadata where
  parseJSON =
    withObject "KvV2SecretMetadataResponse" $ \o -> do
      metadata <- o .: "data"
      currentVersion <- metadata .: "current_version"
      custom <- metadata .:? "custom_metadata" .!= Map.empty
      pure (KvV2SecretMetadata currentVersion custom)

newtype KvV2CustomMetadataRequest = KvV2CustomMetadataRequest (Map Text Text)

instance ToJSON KvV2CustomMetadataRequest where
  toJSON (KvV2CustomMetadataRequest fields) = object ["custom_metadata" .= fields]

newtype KvV2DestroyVersionsRequest = KvV2DestroyVersionsRequest Natural

instance ToJSON KvV2DestroyVersionsRequest where
  toJSON (KvV2DestroyVersionsRequest version) = object ["versions" .= [version]]

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

-- | Opaque commitment produced by a non-exportable Transit HMAC key.
newtype TransitHmacResponse = TransitHmacResponse {transitHmac :: Text}
  deriving (Eq, Show)

instance FromJSON TransitHmacResponse where
  parseJSON =
    withObject "TransitHmacResponse" $ \o -> do
      d <- o .: "data"
      TransitHmacResponse <$> d .: "hmac"

data TransitHmacRequest = TransitHmacRequest
  { transitHmacInputB64 :: !Text
  , transitHmacAlgorithm :: !Text
  }

instance ToJSON TransitHmacRequest where
  toJSON request =
    object
      [ "input" .= transitHmacInputB64 request
      , "algorithm" .= transitHmacAlgorithm request
      ]

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

-- | Read one exact KV-v2 generation.  Retained custody uses this for a
-- receipt-committed predecessor; reading "current" would race rotation.
vaultKvReadExactVersionV2
  :: VaultAddress
  -> VaultToken
  -> Text
  -> Text
  -> Natural
  -> IO (Either HttpError KvV2ExactVersionSecret)
vaultKvReadExactVersionV2 address token mount path version =
  httpGetJsonWithHeaders
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address (kvV2DataPath mount path) ++ "?version=" ++ show version)

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

-- | Read only a KV-v2 coordinate's non-secret metadata document.
vaultKvReadMetadataV2
  :: VaultAddress
  -> VaultToken
  -> Text
  -> Text
  -> IO (Either HttpError KvV2SecretMetadata)
vaultKvReadMetadataV2 address token mount path =
  httpGetJsonWithHeaders
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address (kvV2MetadataPath mount path))

-- | Publish an opaque generation/commitment receipt into Vault custom
-- metadata after a one-shot worker has completed and read back the data CAS.
-- The body cannot contain the secret payload.
vaultKvWriteCustomMetadataV2
  :: VaultAddress
  -> VaultToken
  -> Text
  -> Text
  -> Map Text Text
  -> IO (Either HttpError ())
vaultKvWriteCustomMetadataV2 address token mount path fields =
  httpPostJsonNoResponse
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address (kvV2MetadataPath mount path))
    (KvV2CustomMetadataRequest fields)

-- | Observe the physical KV-v2 metadata coordinate without reading secret
-- bytes.  A successful response means at least metadata remains; callers must
-- classify only an exact @404@ as physical absence.
vaultKvMetadataExistsV2
  :: VaultAddress -> VaultToken -> Text -> Text -> IO (Either HttpError ())
vaultKvMetadataExistsV2 address token mount path =
  httpRequestNoBody
    defaultHttpConfig
    "GET"
    [vaultTokenHeader token]
    (vaultUrl address (kvV2MetadataPath mount path))

-- | Permanently remove every KV-v2 version and its metadata.  This capability
-- is reserved for the Target Secret Agent's signed decommission arm; ordinary
-- target writes never receive it.  The caller must subsequently read back the
-- data path and accept only an exact 404 as absence.
vaultKvDeleteMetadataV2
  :: VaultAddress -> VaultToken -> Text -> Text -> IO (Either HttpError ())
vaultKvDeleteMetadataV2 address token mount path =
  httpRequestNoBody
    defaultHttpConfig
    "DELETE"
    [vaultTokenHeader token]
    (vaultUrl address (kvV2MetadataPath mount path))

-- | Permanently destroy exactly one KV-v2 generation, retaining every other
-- custody generation.  Callers must positively read this version back as 404
-- before publishing a retirement receipt.
vaultKvDestroyVersionV2
  :: VaultAddress
  -> VaultToken
  -> Text
  -> Text
  -> Natural
  -> IO (Either HttpError ())
vaultKvDestroyVersionV2 address token mount path version =
  httpPostJsonNoResponse
    defaultHttpConfig
    [vaultTokenHeader token]
    ( vaultUrl
        address
        ("/v1/" ++ Text.unpack mount ++ "/destroy/" ++ Text.unpack path)
    )
    (KvV2DestroyVersionsRequest version)

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
  , transitKeyLatestVersion :: Natural
  }
  deriving (Eq, Show)

-- | Public half of one non-exportable Ed25519 Transit key generation.
data TransitSigningKeyInfo = TransitSigningKeyInfo
  { transitSigningKeyName :: !Text
  , transitSigningKeyVersion :: !Natural
  , transitSigningPublicKey :: !ByteString
  }
  deriving (Eq, Show)

-- | Raw Ed25519 signature returned by Vault, retaining the key generation
-- carried in Vault's @vault:vN:...@ envelope.
data TransitSignature = TransitSignature
  { transitSignatureKeyVersion :: !Natural
  , transitSignatureBytes :: !ByteString
  }
  deriving (Eq, Show)

data TransitKeyReadResponse = TransitKeyReadResponse
  { transitKeyReadType :: Text
  , transitKeyReadLatestVersion :: Natural
  }

instance FromJSON TransitKeyReadResponse where
  parseJSON =
    withObject "TransitKeyReadResponse" $ \o -> do
      d <- o .: "data"
      TransitKeyReadResponse
        <$> d .: "type"
        <*> d .:? "latest_version" .!= 0

newtype TransitSigningKeyVersion = TransitSigningKeyVersion
  { transitSigningKeyVersionPublicKey :: Text
  }

instance FromJSON TransitSigningKeyVersion where
  parseJSON =
    withObject "TransitSigningKeyVersion" $ \o ->
      TransitSigningKeyVersion <$> o .: "public_key"

data TransitSigningKeyReadResponse = TransitSigningKeyReadResponse
  { transitSigningKeyReadType :: !Text
  , transitSigningKeyReadLatestVersion :: !Natural
  , transitSigningKeyReadVersions :: !(Map Text TransitSigningKeyVersion)
  }

instance FromJSON TransitSigningKeyReadResponse where
  parseJSON =
    withObject "TransitSigningKeyReadResponse" $ \o -> do
      d <- o .: "data"
      TransitSigningKeyReadResponse
        <$> d .: "type"
        <*> d .: "latest_version"
        <*> d .: "keys"

newtype TransitSignRequest = TransitSignRequest
  { transitSignInput :: ByteString
  }

instance ToJSON TransitSignRequest where
  toJSON request =
    object
      [ "input" .= TextEncoding.decodeUtf8 (B64.encode (transitSignInput request))
      , "prehashed" .= False
      ]

newtype TransitSignResponse = TransitSignResponse
  { transitSignResponseSignature :: Text
  }

instance FromJSON TransitSignResponse where
  parseJSON =
    withObject "TransitSignResponse" $ \o -> do
      d <- o .: "data"
      TransitSignResponse <$> d .: "signature"

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
  , kubernetesRoleAudience :: Maybe Text
  , kubernetesRoleTtl :: Text
  , kubernetesRoleTokenType :: Text
  }
  deriving (Eq, Show)

instance ToJSON KubernetesRoleRequest where
  toJSON req =
    object
      ( [ "bound_service_account_names" .= kubernetesRoleServiceAccounts req
        , "bound_service_account_namespaces" .= kubernetesRoleNamespaces req
        , "token_policies" .= kubernetesRolePolicies req
        , "token_ttl" .= kubernetesRoleTtl req
        , -- One-shot roles may return renewable service tokens, so both hard
          -- server-side lifetime caps are deliberately equal to the requested
          -- TTL.  This closes renewal beyond the one-shot execution window.
          "token_max_ttl" .= kubernetesRoleTtl req
        , "token_explicit_max_ttl" .= kubernetesRoleTtl req
        , "token_type" .= kubernetesRoleTokenType req
        ]
          <> maybe [] (\audience -> ["audience" .= audience]) (kubernetesRoleAudience req)
      )

-- | Exact post-write observation of a Kubernetes auth role. Vault renders
-- durations as seconds even when the request used duration text.
data KubernetesRoleReadback = KubernetesRoleReadback
  { kubernetesRoleReadbackServiceAccounts :: ![Text]
  , kubernetesRoleReadbackNamespaces :: ![Text]
  , kubernetesRoleReadbackPolicies :: ![Text]
  , kubernetesRoleReadbackAudience :: !(Maybe Text)
  , kubernetesRoleReadbackTtlSeconds :: !Natural
  , kubernetesRoleReadbackMaximumTtlSeconds :: !Natural
  , kubernetesRoleReadbackExplicitMaximumTtlSeconds :: !Natural
  , kubernetesRoleReadbackTokenType :: !Text
  }
  deriving (Eq, Show)

instance FromJSON KubernetesRoleReadback where
  parseJSON = withObject "KubernetesRoleReadbackResponse" $ \response -> do
    body <- response .: "data"
    KubernetesRoleReadback
      <$> body .: "bound_service_account_names"
      <*> body .: "bound_service_account_namespaces"
      <*> body .: "token_policies"
      <*> body .:? "audience"
      <*> body .: "token_ttl"
      <*> body .: "token_max_ttl"
      <*> body .: "token_explicit_max_ttl"
      <*> body .: "token_type"

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
  pure
    ( fmap
        ( \response ->
            TransitKeyInfo
              keyName
              (transitKeyReadType response)
              (transitKeyReadLatestVersion response)
        )
        result
    )

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

-- | Read the latest public generation of a non-exportable Ed25519 Transit
-- signer.  A different key type, missing generation, or malformed public key
-- is a decode refusal, never substitutable signing material.
vaultReadTransitSigningKey
  :: VaultAddress -> VaultToken -> Text -> IO (Either HttpError TransitSigningKeyInfo)
vaultReadTransitSigningKey address token keyName = do
  result <-
    httpGetJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address ("/v1/transit/keys/" ++ Text.unpack keyName))
  pure (result >>= decodeSigningKey)
 where
  decodeSigningKey response
    | transitSigningKeyReadType response /= "ed25519" =
        Left (HttpDecode "Transit signing key is not Ed25519")
    | otherwise = do
        let version = transitSigningKeyReadLatestVersion response
            versionKey = Text.pack (show version)
        encoded <-
          maybe
            (Left (HttpDecode "Transit signing key latest generation is missing"))
            (Right . transitSigningKeyVersionPublicKey)
            (Map.lookup versionKey (transitSigningKeyReadVersions response))
        publicKey <-
          either
            (Left . HttpDecode . ("Transit signing public key is not valid base64: " ++))
            Right
            (B64.decode (TextEncoding.encodeUtf8 encoded))
        Right
          TransitSigningKeyInfo
            { transitSigningKeyName = keyName
            , transitSigningKeyVersion = version
            , transitSigningPublicKey = publicKey
            }

-- | Sign exact bytes with a non-exportable Ed25519 Transit key and decode
-- Vault's @vault:vN:BASE64@ envelope without discarding the generation.
vaultTransitSignEd25519
  :: VaultAddress
  -> VaultToken
  -> Text
  -> ByteString
  -> IO (Either HttpError TransitSignature)
vaultTransitSignEd25519 address token keyName input = do
  result <-
    httpPostJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address ("/v1/transit/sign/" ++ Text.unpack keyName))
      (TransitSignRequest input)
  pure (result >>= decodeTransitSignature . transitSignResponseSignature)

decodeTransitSignature :: Text -> Either HttpError TransitSignature
decodeTransitSignature encoded =
  case Text.splitOn ":" encoded of
    ["vault", versionText, signatureText]
      | Just version <- Text.stripPrefix "v" versionText
      , Just numericVersion <- readMaybe (Text.unpack version)
      , numericVersion > 0 -> do
          signature <-
            either
              (Left . HttpDecode . ("Transit signature is not valid base64: " ++))
              Right
              (B64.decode (TextEncoding.encodeUtf8 signatureText))
          Right
            TransitSignature
              { transitSignatureKeyVersion = numericVersion
              , transitSignatureBytes = signature
              }
    _ -> Left (HttpDecode "Transit signature envelope is malformed")

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

-- | List configured PKI issuers through Vault's bounded list-query form.
vaultListPkiIssuers
  :: VaultAddress -> VaultToken -> IO (Either HttpError PkiIssuerListing)
vaultListPkiIssuers address token =
  httpGetJsonWithHeaders
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address "/v1/pki/issuers?list=true")

-- | Generate the one compiled internal bootstrap test CA. Callers first prove
-- that no issuer exists, keeping this operation idempotent on replay.
vaultGeneratePkiInternalRoot
  :: VaultAddress -> VaultToken -> IO (Either HttpError ())
vaultGeneratePkiInternalRoot address token =
  httpPostJsonNoResponse
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address "/v1/pki/root/generate/internal")
    (PkiInternalRootRequest "Prodbox Bootstrap Test CA" "87600h")

vaultWritePkiRole
  :: VaultAddress -> VaultToken -> Text -> IO (Either HttpError ())
vaultWritePkiRole address token role =
  httpPostJsonNoResponse
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address ("/v1/pki/roles/" ++ Text.unpack role))
    PkiRoleRequest

vaultReadPkiRole
  :: VaultAddress -> VaultToken -> Text -> IO (Either HttpError PkiRoleInfo)
vaultReadPkiRole address token role =
  httpGetJsonWithHeaders
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address ("/v1/pki/roles/" ++ Text.unpack role))

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
      , vaultLoginAccessor = kubernetesLoginResponseAccessor resp
      , vaultLoginLeaseSeconds = kubernetesLoginResponseLeaseSeconds resp
      , vaultLoginRenewable = kubernetesLoginResponseRenewable resp
      , vaultLoginTokenType = kubernetesLoginResponseTokenType resp
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
  -> Maybe Text
  -> Text
  -> IO (Either HttpError ())
vaultWriteKubernetesRole address token role serviceAccounts namespaces policies audience ttl =
  vaultWriteKubernetesRoleWithTokenType
    "service"
    address
    token
    role
    serviceAccounts
    namespaces
    policies
    audience
    ttl

-- | Create or replace a Kubernetes auth role whose tokens are non-renewable
-- Vault batch tokens.  Batch tokens have no server-side accessor and expire by
-- their bounded TTL, which gives accessor-auditor and seal sessions a finite
-- cleanup tail rather than recursively creating another accessor to prove.
vaultWriteKubernetesBatchRole
  :: VaultAddress
  -> VaultToken
  -> Text
  -> [Text]
  -> [Text]
  -> [Text]
  -> Maybe Text
  -> Text
  -> IO (Either HttpError ())
vaultWriteKubernetesBatchRole = vaultWriteKubernetesRoleWithTokenType "batch"

vaultWriteKubernetesRoleWithTokenType
  :: Text
  -> VaultAddress
  -> VaultToken
  -> Text
  -> [Text]
  -> [Text]
  -> [Text]
  -> Maybe Text
  -> Text
  -> IO (Either HttpError ())
vaultWriteKubernetesRoleWithTokenType tokenType address token role serviceAccounts namespaces policies audience ttl =
  httpPostJsonNoResponse
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address ("/v1/auth/kubernetes/role/" ++ Text.unpack role))
    (KubernetesRoleRequest serviceAccounts namespaces policies audience ttl tokenType)

-- | Read back the exact persisted Kubernetes auth role after reconciliation.
vaultReadKubernetesRole
  :: VaultAddress
  -> VaultToken
  -> Text
  -> IO (Either HttpError KubernetesRoleReadback)
vaultReadKubernetesRole address token role =
  httpGetJsonWithHeaders
    defaultHttpConfig
    [vaultTokenHeader token]
    (vaultUrl address ("/v1/auth/kubernetes/role/" ++ Text.unpack role))

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

-- | Produce an opaque SHA2-256 commitment without exporting either the HMAC
-- key or the input.  Target workers persist only this token in KV metadata.
vaultTransitHmacSha256
  :: VaultAddress -> VaultToken -> Text -> ByteString -> IO (Either HttpError Text)
vaultTransitHmacSha256 address token keyName input = do
  let body =
        TransitHmacRequest
          { transitHmacInputB64 = TextEncoding.decodeUtf8 (B64.encode input)
          , transitHmacAlgorithm = "sha2-256"
          }
  result <-
    httpPostJsonWithHeaders
      defaultHttpConfig
      [vaultTokenHeader token]
      (vaultUrl address ("/v1/transit/hmac/" ++ Text.unpack keyName))
      body
  pure (transitHmac <$> result)

kvV2DataPath :: Text -> Text -> String
kvV2DataPath mount path =
  "/v1/" ++ Text.unpack mount ++ "/data/" ++ Text.unpack path

kvV2MetadataPath :: Text -> Text -> String
kvV2MetadataPath mount path =
  "/v1/" ++ Text.unpack mount ++ "/metadata/" ++ Text.unpack path

normalizeVaultPath :: Text -> Text
normalizeVaultPath =
  Text.dropWhileEnd (== '/')
