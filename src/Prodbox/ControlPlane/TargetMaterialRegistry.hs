{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed Target Secret Agent material and destination registry.
--
-- A production request carries one of the constructors below.  The constructor
-- fixes both the material schema and the destination; there is no generic
-- mount/path/endpoint or arbitrary field map on the control-plane wire.
-- 'targetSecretPayloadToVaultFields' is the only place that lowers the closed
-- material into Vault's physical text-field representation.
module Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetRealm (..)
  , PatroniIdentity (..)
  , OidcIdentity (..)
  , GatewayNodeIdentity (..)
  , AwsCredentialIdentity (..)
  , TargetSecretId (..)
  , TargetSecretPayload (..)
  , allTargetSecretIds
  , allTargetMaterialIds
  , targetSecretPayloadId
  , targetSecretIdToken
  , targetSecretIdVaultLogicalPath
  , compiledTargetSecretSink
  , targetSecretIdForSink
  , targetSecretPayloadToVaultFields
  , targetSecretPayloadFromVaultFields
  , validateTargetSecretPayload
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.Char (isControl, isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.Lifecycle.CheckpointAuthority
  ( TargetClusterSecretSink
  , mkTargetClusterSecretSink
  )

data TargetRealm
  = KeycloakRealm
  | VscodeRealm
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (Serialise)

data PatroniIdentity
  = PatroniApplication
  | PatroniSuperuser
  | PatroniStandby
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (Serialise)

data OidcIdentity
  = OidcVscode
  | OidcProdboxApi
  | OidcProdboxWebsocket
  | OidcDemoUser
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (Serialise)

data GatewayNodeIdentity
  = GatewayNodeA
  | GatewayNodeB
  | GatewayNodeC
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (Serialise)

data AwsCredentialIdentity
  = AwsLifecycleProvider
  | AwsAuthorityBackupStore
  | AwsTlsRetentionStore
  | AwsGatewayDns
  | AwsHomeCertManagerDns01
  | AwsRunCertManagerDns01
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (Serialise)

-- | Exact logical target inventory.  It mirrors the registered production
-- objects in 'Prodbox.Secret.VaultInventory'; adding a destination requires a
-- new constructor and exhaustive codec/coordinate cases here.
data TargetSecretId
  = TargetSesSmtp
  | TargetAcmeEab
  | -- These constructors are exact authorization coordinates for
    -- non-KV one-shot Target operations.  They deliberately have no
    -- 'TargetSecretPayload' constructor: their arm-specific inputs and results
    -- live in the Target worker protocol and can never be lowered through the
    -- generic KV field codec below.
    TargetPublicEdgeTls
  | TargetFederationCustody
  | TargetAwsCredential !AwsCredentialIdentity
  | TargetKeycloakDatabase !TargetRealm !PatroniIdentity
  | TargetKeycloakAdmin !TargetRealm
  | TargetOidc !TargetRealm !OidcIdentity
  | TargetGatewayEventKey !GatewayNodeIdentity
  | TargetGatewayMinio
  | TargetLifecycleAuthorityMinio
  | TargetMinioRoot
  | TargetObjectStoreHmac
  | TargetFederationHmac
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | Closed schema-indexed material.  Constructor choice determines the exact
-- 'TargetSecretId' and exact physical field names.  The type deliberately has
-- no generic-map constructor.
data TargetSecretPayload
  = SesSmtpMaterial
      { sesSmtpHost :: !Text
      , sesSmtpPort :: !Text
      , sesSmtpFrom :: !Text
      , sesSmtpFromDisplayName :: !Text
      , sesSmtpReplyTo :: !Text
      , sesSmtpUsername :: !Text
      , sesSmtpPassword :: !Text
      }
  | AcmeEabMaterial
      { acmeEabKeyId :: !Text
      , acmeEabHmacKey :: !Text
      }
  | AwsCredentialMaterial
      { awsCredentialMaterialIdentity :: !AwsCredentialIdentity
      , awsCredentialMaterialAccessKeyId :: !Text
      , awsCredentialMaterialSecretAccessKey :: !Text
      , awsCredentialMaterialSessionToken :: !Text
      , awsCredentialMaterialRegion :: !Text
      }
  | KeycloakDatabaseMaterial
      { keycloakDatabaseRealm :: !TargetRealm
      , keycloakDatabaseIdentity :: !PatroniIdentity
      , keycloakDatabaseUsername :: !Text
      , keycloakDatabasePassword :: !Text
      }
  | KeycloakAdminMaterial
      { keycloakAdminRealm :: !TargetRealm
      , keycloakAdminPassword :: !Text
      }
  | OidcClientMaterial
      { oidcClientRealm :: !TargetRealm
      , oidcClientIdentity :: !OidcIdentity
      , oidcClientSecret :: !Text
      }
  | GatewayEventKeyMaterial
      { gatewayEventKeyNode :: !GatewayNodeIdentity
      , gatewayEventKey :: !Text
      }
  | GatewayMinioMaterial
      { gatewayMinioAccessKey :: !Text
      , gatewayMinioSecretKey :: !Text
      }
  | LifecycleAuthorityMinioMaterial
      { lifecycleAuthorityMinioAccessKey :: !Text
      , lifecycleAuthorityMinioSecretKey :: !Text
      }
  | MinioRootMaterial
      { minioRootMaterialUser :: !Text
      , minioRootMaterialPassword :: !Text
      }
  | ObjectStoreHmacMaterial
      { objectStoreHmacKey :: !Text
      }
  | FederationHmacMaterial
      { federationHmacKey :: !Text
      }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

allTargetSecretIds :: [TargetSecretId]
allTargetSecretIds =
  [ TargetSesSmtp
  , TargetAcmeEab
  , TargetPublicEdgeTls
  , TargetFederationCustody
  ]
    <> fmap TargetAwsCredential [minBound .. maxBound]
    <> [ TargetKeycloakDatabase realm identity
       | realm <- [minBound .. maxBound]
       , identity <- [minBound .. maxBound]
       ]
    <> fmap TargetKeycloakAdmin [minBound .. maxBound]
    <> [ TargetOidc realm identity
       | realm <- [minBound .. maxBound]
       , identity <- [minBound .. maxBound]
       ]
    <> fmap TargetGatewayEventKey [minBound .. maxBound]
    <> [ TargetGatewayMinio
       , TargetLifecycleAuthorityMinio
       , TargetMinioRoot
       , TargetObjectStoreHmac
       , TargetFederationHmac
       ]

-- | Targets which physically own a KV payload.  Authorization-only one-shot
-- operation coordinates are intentionally absent: the standing Target Agent
-- must never probe or receive metadata authority over a synthetic secret path.
allTargetMaterialIds :: [TargetSecretId]
allTargetMaterialIds =
  filter isMaterialTarget allTargetSecretIds
 where
  isMaterialTarget target = case target of
    TargetPublicEdgeTls -> False
    TargetFederationCustody -> False
    _ -> True

targetSecretPayloadId :: TargetSecretPayload -> TargetSecretId
targetSecretPayloadId payload = case payload of
  SesSmtpMaterial {} -> TargetSesSmtp
  AcmeEabMaterial {} -> TargetAcmeEab
  AwsCredentialMaterial identity _ _ _ _ -> TargetAwsCredential identity
  KeycloakDatabaseMaterial realm identity _ _ ->
    TargetKeycloakDatabase realm identity
  KeycloakAdminMaterial realm _ -> TargetKeycloakAdmin realm
  OidcClientMaterial realm identity _ -> TargetOidc realm identity
  GatewayEventKeyMaterial node _ -> TargetGatewayEventKey node
  GatewayMinioMaterial {} -> TargetGatewayMinio
  LifecycleAuthorityMinioMaterial {} -> TargetLifecycleAuthorityMinio
  MinioRootMaterial {} -> TargetMinioRoot
  ObjectStoreHmacMaterial {} -> TargetObjectStoreHmac
  FederationHmacMaterial {} -> TargetFederationHmac

targetSecretIdToken :: TargetSecretId -> Text
targetSecretIdToken target = case target of
  TargetSesSmtp -> "ses-smtp"
  TargetAcmeEab -> "acme-eab"
  TargetPublicEdgeTls -> "public-edge-tls-operation"
  TargetFederationCustody -> "federation-custody-operation"
  TargetAwsCredential identity -> "aws-" <> awsIdentityToken identity
  TargetKeycloakDatabase realm identity ->
    realmToken realm <> "-patroni-" <> patroniToken identity
  TargetKeycloakAdmin realm -> realmToken realm <> "-keycloak-admin"
  TargetOidc realm identity -> realmToken realm <> "-oidc-" <> oidcToken identity
  TargetGatewayEventKey node -> "gateway-event-key-" <> gatewayNodeToken node
  TargetGatewayMinio -> "gateway-minio"
  TargetLifecycleAuthorityMinio -> "lifecycle-authority-minio"
  TargetMinioRoot -> "minio-root"
  TargetObjectStoreHmac -> "object-store-hmac"
  TargetFederationHmac -> "federation-hmac"

-- | Compile an exact target identity and Vault lane. Network transport is
-- selected independently by the authenticated Target Agent client.
compiledTargetSecretSink
  :: TargetSecretId
  -> Either Text TargetClusterSecretSink
compiledTargetSecretSink target =
  first
    (Text.pack . show)
    ( mkTargetClusterSecretSink
        (targetSecretIdToken target)
        "secret"
        (targetSecretIdVaultLogicalPath target)
    )

targetSecretIdForSink :: TargetClusterSecretSink -> Maybe TargetSecretId
targetSecretIdForSink sink =
  case filter
    (\target -> compiledTargetSecretSink target == Right sink)
    allTargetSecretIds of
    [target] -> Just target
    _ -> Nothing

targetSecretPayloadToVaultFields
  :: TargetSecretPayload
  -> Either Text (Map Text Text)
targetSecretPayloadToVaultFields payload = do
  validateTargetSecretPayload payload
  pure $ case payload of
    SesSmtpMaterial host port sender displayName replyTo username password ->
      fields
        [ ("host", host)
        , ("port", port)
        , ("from", sender)
        , ("from_display_name", displayName)
        , ("reply_to", replyTo)
        , ("username", username)
        , ("password", password)
        ]
    AcmeEabMaterial keyId hmacKey ->
      fields [("key_id", keyId), ("hmac_key", hmacKey)]
    AwsCredentialMaterial _ accessKey secretKey sessionToken region ->
      fields
        [ ("access_key_id", accessKey)
        , ("secret_access_key", secretKey)
        , ("session_token", sessionToken)
        , ("region", region)
        ]
    KeycloakDatabaseMaterial _ _ username password ->
      fields [("username", username), ("password", password)]
    KeycloakAdminMaterial _ password -> fields [("password", password)]
    OidcClientMaterial _ identity secret -> case identity of
      OidcDemoUser -> fields [("password", secret)]
      _ -> fields [("client_secret", secret)]
    GatewayEventKeyMaterial _ key -> fields [("key", key)]
    GatewayMinioMaterial accessKey secretKey ->
      fields [("minio_access_key", accessKey), ("minio_secret_key", secretKey)]
    LifecycleAuthorityMinioMaterial accessKey secretKey ->
      fields [("minio_access_key", accessKey), ("minio_secret_key", secretKey)]
    MinioRootMaterial user password ->
      fields [("rootUser", user), ("rootPassword", password)]
    ObjectStoreHmacMaterial key -> fields [("key", key)]
    FederationHmacMaterial key -> fields [("key", key)]
 where
  fields = Map.fromList

targetSecretPayloadFromVaultFields
  :: TargetSecretId
  -> Map Text Text
  -> Either Text TargetSecretPayload
targetSecretPayloadFromVaultFields target object = do
  requireExactFieldSet target object
  payload <- case target of
    TargetSesSmtp ->
      SesSmtpMaterial
        <$> field "host"
        <*> field "port"
        <*> field "from"
        <*> field "from_display_name"
        <*> field "reply_to"
        <*> field "username"
        <*> field "password"
    TargetAcmeEab -> AcmeEabMaterial <$> field "key_id" <*> field "hmac_key"
    TargetPublicEdgeTls -> Left "public-edge TLS is an operation authorization, not a KV payload"
    TargetFederationCustody ->
      Left "federation custody is an operation authorization, not a KV payload"
    TargetAwsCredential identity ->
      AwsCredentialMaterial identity
        <$> field "access_key_id"
        <*> field "secret_access_key"
        <*> field "session_token"
        <*> field "region"
    TargetKeycloakDatabase realm identity ->
      KeycloakDatabaseMaterial realm identity
        <$> field "username"
        <*> field "password"
    TargetKeycloakAdmin realm -> KeycloakAdminMaterial realm <$> field "password"
    TargetOidc realm identity ->
      OidcClientMaterial realm identity
        <$> field (if identity == OidcDemoUser then "password" else "client_secret")
    TargetGatewayEventKey node -> GatewayEventKeyMaterial node <$> field "key"
    TargetGatewayMinio ->
      GatewayMinioMaterial <$> field "minio_access_key" <*> field "minio_secret_key"
    TargetLifecycleAuthorityMinio ->
      LifecycleAuthorityMinioMaterial
        <$> field "minio_access_key"
        <*> field "minio_secret_key"
    TargetMinioRoot -> MinioRootMaterial <$> field "rootUser" <*> field "rootPassword"
    TargetObjectStoreHmac -> ObjectStoreHmacMaterial <$> field "key"
    TargetFederationHmac -> FederationHmacMaterial <$> field "key"
  validateTargetSecretPayload payload
  pure payload
 where
  field name =
    maybe
      (Left ("registered target object is missing field `" <> name <> "`"))
      Right
      (Map.lookup name object)

validateTargetSecretPayload :: TargetSecretPayload -> Either Text ()
validateTargetSecretPayload payload = do
  let values = Map.toList (unsafePayloadFields payload)
  mapM_ validateFieldValue values
  case payload of
    SesSmtpMaterial _ port _ _ _ _ _
      | Text.null port || not (Text.all isDigit port) ->
          Left "ses-smtp port must contain only decimal digits"
      | otherwise -> Right ()
    AwsCredentialMaterial _ accessKey secretKey _ region -> do
      requireNonEmpty "access_key_id" accessKey
      requireNonEmpty "secret_access_key" secretKey
      requireNonEmpty "region" region
    _ -> mapM_ (uncurry requireNonEmpty) (requiredNonEmptyFields payload)

requireExactFieldSet :: TargetSecretId -> Map Text Text -> Either Text ()
requireExactFieldSet target object
  | actual == expected = Right ()
  | otherwise =
      Left
        ( "registered target field schema mismatch for "
            <> targetSecretIdToken target
        )
 where
  actual = Map.keysSet object
  expected = Set.fromList (targetSecretFieldNames target)

validateFieldValue :: (Text, Text) -> Either Text ()
validateFieldValue (name, value)
  | Text.length value > maximumTargetSecretValueCharacters =
      Left ("target material field `" <> name <> "` exceeds the value bound")
  | Text.any isControl value =
      Left ("target material field `" <> name <> "` contains a control character")
  | otherwise = Right ()

requireNonEmpty :: Text -> Text -> Either Text ()
requireNonEmpty name value
  | Text.null (Text.strip value) =
      Left ("target material field `" <> name <> "` is empty")
  | otherwise = Right ()

requiredNonEmptyFields :: TargetSecretPayload -> [(Text, Text)]
requiredNonEmptyFields payload = case payload of
  SesSmtpMaterial host _ sender _ _ username password ->
    [("host", host), ("from", sender), ("username", username), ("password", password)]
  AcmeEabMaterial keyId hmacKey -> [("key_id", keyId), ("hmac_key", hmacKey)]
  AwsCredentialMaterial {} -> []
  KeycloakDatabaseMaterial _ _ username password ->
    [("username", username), ("password", password)]
  KeycloakAdminMaterial _ password -> [("password", password)]
  OidcClientMaterial _ identity secret ->
    [(if identity == OidcDemoUser then "password" else "client_secret", secret)]
  GatewayEventKeyMaterial _ key -> [("key", key)]
  GatewayMinioMaterial accessKey secretKey ->
    [("minio_access_key", accessKey), ("minio_secret_key", secretKey)]
  LifecycleAuthorityMinioMaterial accessKey secretKey ->
    [("minio_access_key", accessKey), ("minio_secret_key", secretKey)]
  MinioRootMaterial user password -> [("rootUser", user), ("rootPassword", password)]
  ObjectStoreHmacMaterial key -> [("key", key)]
  FederationHmacMaterial key -> [("key", key)]

unsafePayloadFields :: TargetSecretPayload -> Map Text Text
unsafePayloadFields payload = case targetSecretPayloadToVaultFieldsUnchecked payload of
  fields -> fields

targetSecretPayloadToVaultFieldsUnchecked :: TargetSecretPayload -> Map Text Text
targetSecretPayloadToVaultFieldsUnchecked payload = case payload of
  SesSmtpMaterial host port sender displayName replyTo username password ->
    Map.fromList
      [ ("host", host)
      , ("port", port)
      , ("from", sender)
      , ("from_display_name", displayName)
      , ("reply_to", replyTo)
      , ("username", username)
      , ("password", password)
      ]
  AcmeEabMaterial keyId hmacKey -> Map.fromList [("key_id", keyId), ("hmac_key", hmacKey)]
  AwsCredentialMaterial _ accessKey secretKey sessionToken region ->
    Map.fromList
      [ ("access_key_id", accessKey)
      , ("secret_access_key", secretKey)
      , ("session_token", sessionToken)
      , ("region", region)
      ]
  KeycloakDatabaseMaterial _ _ username password ->
    Map.fromList [("username", username), ("password", password)]
  KeycloakAdminMaterial _ password -> Map.singleton "password" password
  OidcClientMaterial _ identity secret ->
    Map.singleton (if identity == OidcDemoUser then "password" else "client_secret") secret
  GatewayEventKeyMaterial _ key -> Map.singleton "key" key
  GatewayMinioMaterial accessKey secretKey ->
    Map.fromList [("minio_access_key", accessKey), ("minio_secret_key", secretKey)]
  LifecycleAuthorityMinioMaterial accessKey secretKey ->
    Map.fromList [("minio_access_key", accessKey), ("minio_secret_key", secretKey)]
  MinioRootMaterial user password ->
    Map.fromList [("rootUser", user), ("rootPassword", password)]
  ObjectStoreHmacMaterial key -> Map.singleton "key" key
  FederationHmacMaterial key -> Map.singleton "key" key

targetSecretFieldNames :: TargetSecretId -> [Text]
targetSecretFieldNames target = case target of
  TargetSesSmtp -> ["host", "port", "from", "from_display_name", "reply_to", "username", "password"]
  TargetAcmeEab -> ["key_id", "hmac_key"]
  TargetPublicEdgeTls -> []
  TargetFederationCustody -> []
  TargetAwsCredential _ -> ["access_key_id", "secret_access_key", "session_token", "region"]
  TargetKeycloakDatabase _ _ -> ["username", "password"]
  TargetKeycloakAdmin _ -> ["password"]
  TargetOidc _ identity -> [if identity == OidcDemoUser then "password" else "client_secret"]
  TargetGatewayEventKey _ -> ["key"]
  TargetGatewayMinio -> ["minio_access_key", "minio_secret_key"]
  TargetLifecycleAuthorityMinio -> ["minio_access_key", "minio_secret_key"]
  TargetMinioRoot -> ["rootUser", "rootPassword"]
  TargetObjectStoreHmac -> ["key"]
  TargetFederationHmac -> ["key"]

targetSecretIdVaultLogicalPath :: TargetSecretId -> Text
targetSecretIdVaultLogicalPath target = case target of
  TargetSesSmtp -> "keycloak/smtp"
  TargetAcmeEab -> "acme/eab"
  TargetPublicEdgeTls -> "target-operations/public-edge-tls"
  TargetFederationCustody -> "target-operations/federation-custody"
  TargetAwsCredential identity -> case identity of
    AwsLifecycleProvider -> "aws/lifecycle-provider"
    AwsAuthorityBackupStore -> "aws/authority-backup-store"
    AwsTlsRetentionStore -> "aws/tls-retention-store"
    AwsGatewayDns -> "aws/gateway-dns"
    AwsHomeCertManagerDns01 -> "aws/cert-manager/home/dns01"
    AwsRunCertManagerDns01 -> "aws/cert-manager/aws/dns01"
  TargetKeycloakDatabase realm identity ->
    realmToken realm <> "/keycloak-postgres/patroni/" <> patroniToken identity
  TargetKeycloakAdmin realm -> case realm of
    KeycloakRealm -> "keycloak/admin"
    VscodeRealm -> "vscode/keycloak/admin"
  TargetOidc realm identity -> realmToken realm <> "/oidc/" <> oidcToken identity
  TargetGatewayEventKey node ->
    "gateway/gateway/" <> gatewayNodeToken node <> "/event-key"
  TargetGatewayMinio -> "gateway/gateway/minio"
  TargetLifecycleAuthorityMinio -> "minio/lifecycle-authority"
  TargetMinioRoot -> "minio/root"
  TargetObjectStoreHmac -> "object-store/hmac"
  TargetFederationHmac -> "federation/hmac"

realmToken :: TargetRealm -> Text
realmToken realm = case realm of
  KeycloakRealm -> "keycloak"
  VscodeRealm -> "vscode"

patroniToken :: PatroniIdentity -> Text
patroniToken identity = case identity of
  PatroniApplication -> "app"
  PatroniSuperuser -> "superuser"
  PatroniStandby -> "standby"

oidcToken :: OidcIdentity -> Text
oidcToken identity = case identity of
  OidcVscode -> "vscode"
  OidcProdboxApi -> "prodbox-api"
  OidcProdboxWebsocket -> "prodbox-websocket"
  OidcDemoUser -> "demo-user"

gatewayNodeToken :: GatewayNodeIdentity -> Text
gatewayNodeToken node = case node of
  GatewayNodeA -> "node-a"
  GatewayNodeB -> "node-b"
  GatewayNodeC -> "node-c"

awsIdentityToken :: AwsCredentialIdentity -> Text
awsIdentityToken identity = case identity of
  AwsLifecycleProvider -> "lifecycle-provider"
  AwsAuthorityBackupStore -> "authority-backup-store"
  AwsTlsRetentionStore -> "tls-retention-store"
  AwsGatewayDns -> "gateway-dns"
  AwsHomeCertManagerDns01 -> "cert-manager-home-dns01"
  AwsRunCertManagerDns01 -> "cert-manager-aws-dns01"

maximumTargetSecretValueCharacters :: Int
maximumTargetSecretValueCharacters = 64 * 1024
