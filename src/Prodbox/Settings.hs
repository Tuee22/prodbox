{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Prodbox.Settings
  ( AcmeSection (..)
  , AwsCredentialsRef (..)
  , AwsSubstrateSection (..)
  , ConfigFile (..)
  , Credentials (..)
  , DeploymentSection (..)
  , DomainSection (..)
  , MetallbBgpPeer (..)
  , PulumiStateBackendSection (..)
  , Route53Section (..)
  , SesSection (..)
  , StorageSection (..)
  , ValidatedSettings (..)
  , defaultConfigFile
  , decodeConfigDhallBytes
  , loadConfigFile
  , loadConfigForSettingsWith
  , loadUnencryptedBasics
  , renderConfigDhall
  , renderSettingsDisplay
  , resolveAwsCredentialsRefFromHostVault
  , supportedPublicHostname
  , validateAwsBootstrapConfig
  , validateAndLoadSettings
  , validateAndLoadBootstrapSettings
  , validateAndLoadSettingsWithVaultToken
  , validateOperationalAwsCredentials
  , validatePublicEdgeDeployment
  , writeUnencryptedBasics
  )
where

import Control.Exception (SomeException, displayException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isDigit, isHexDigit, toLower)
import Data.Char qualified as Char
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Dhall
  ( FromDhall (..)
  , InterpretOptions (..)
  , auto
  , defaultInterpretOptions
  , genericAutoWith
  , inputFile
  )
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Config.Basics
  ( UnencryptedBasics (..)
  , basicsFromJson
  , basicsToJson
  , renderBasicsError
  , validateBasics
  )
import Prodbox.Config.InForce.Core
  ( fetchInForceValueWith
  , renderInForceConfigError
  )
import Prodbox.Http.Client (renderHttpError)
import Prodbox.Infra.MinioBackend (withMinioPortForward)
import Prodbox.Minio.EncryptedObject
  ( LogicalObject (LogicalInForceConfig)
  , objectKeyForOpaqueId
  , opaqueObjectId
  )
import Prodbox.Minio.ObjectStore
  ( ObjectStoreConfig (..)
  , defaultObjectStoreBucket
  , getObject
  )
import Prodbox.Repo
  ( ConfigPaths (..)
  , canonicalConfigPaths
  )
import Prodbox.Settings.SecretRef
  ( PromptSpec (..)
  , SecretRef (..)
  , VaultSecretRef (..)
  )
import Prodbox.Vault.Client
  ( VaultAddress (..)
  , VaultToken
  , vaultKvReadV2
  )
import Prodbox.Vault.Host
  ( loadReadyVaultRootToken
  , readHostVaultKvField
  )
import Prodbox.Vault.TransitCipher (vaultTransitDekCipher)
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesFileExist
  , makeAbsolute
  )
import System.FilePath
  ( takeDirectory
  , (</>)
  )
import System.IO.Temp (withSystemTempDirectory)

data Credentials = Credentials
  { access_key_id :: Text
  , secret_access_key :: Text
  , session_token :: Maybe Text
  , region :: Text
  }
  deriving (Eq, Show, Generic, FromDhall)

data AwsCredentialsRef = AwsCredentialsRef
  { awsCredentialAccessKeyId :: SecretRef
  , awsCredentialSecretAccessKey :: SecretRef
  , awsCredentialSessionToken :: Maybe SecretRef
  , awsCredentialRegion :: Text
  }
  deriving (Eq, Show, Generic)

instance FromDhall AwsCredentialsRef where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {fieldModifier = awsCredentialFieldModifier}
   where
    awsCredentialFieldModifier :: Text -> Text
    awsCredentialFieldModifier value =
      case Text.stripPrefix "awsCredential" value of
        Just stripped -> haskellCamelToDhallSnake stripped
        Nothing -> value

data Route53Section = Route53Section
  { zone_id :: Text
  }
  deriving (Eq, Show, Generic, FromDhall)

data AwsSubstrateSection = AwsSubstrateSection
  { hosted_zone_id :: Text
  , subzone_name :: Text
  }
  deriving (Eq, Show, Generic, FromDhall)

data SesSection = SesSection
  { sender_domain :: Text
  , receive_subdomain :: Text
  , capture_bucket :: Text
  }
  deriving (Eq, Show, Generic, FromDhall)

data DomainSection = DomainSection
  { demo_fqdn :: Text
  , demo_ttl :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall)

data MetallbBgpPeer = MetallbBgpPeer
  { peer_name :: Text
  , peer_address :: Text
  , peer_asn :: Natural
  , my_asn :: Natural
  , ebgp_multi_hop :: Maybe Bool
  }
  deriving (Eq, Show, Generic, FromDhall)

data AcmeSection = AcmeSection
  { email :: Text
  , server :: Text
  , eab_key_id :: Maybe SecretRef
  , eab_hmac_key :: Maybe SecretRef
  }
  deriving (Eq, Show, Generic, FromDhall)

data DeploymentSection = DeploymentSection
  { dev_mode :: Bool
  , bootstrap_public_ip_override :: Maybe Text
  , pulumi_enable_dns_bootstrap :: Bool
  , public_edge_advertisement_mode :: Maybe Text
  , public_edge_bgp_peers :: Maybe [MetallbBgpPeer]
  , envoy_gateway_controller_replicas :: Maybe Natural
  , envoy_gateway_data_plane_replicas :: Maybe Natural
  , api_replicas :: Maybe Natural
  , websocket_replicas :: Maybe Natural
  }
  deriving (Eq, Show, Generic, FromDhall)

data StorageSection = StorageSection
  { manual_pv_host_root :: Text
  }
  deriving (Eq, Show, Generic, FromDhall)

-- | Sprint 4.10: dedicated S3 bucket that backs long-lived Pulumi
-- stacks (today: @aws-ses@). Per-run stacks (@aws-eks@,
-- @aws-eks-subzone@, @aws-test@) continue using the in-cluster MinIO
-- backend; this record names the long-lived destination only. An
-- empty @bucket_name@ means the operator has not yet provisioned the
-- long-lived backend, and long-lived Pulumi operations remain on the
-- legacy MinIO backend until the migration command runs.
--
-- The Haskell field names carry a @psb@ prefix to avoid collision
-- with @Credentials.region@; a custom 'FromDhall' instance strips the
-- prefix so the Dhall config keeps bare field names
-- (@bucket_name@, @region@, @key_prefix@).
data PulumiStateBackendSection = PulumiStateBackendSection
  { psbBucketName :: Text
  , psbRegion :: Text
  , psbKeyPrefix :: Text
  }
  deriving (Eq, Show, Generic)

instance FromDhall PulumiStateBackendSection where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {fieldModifier = stripPsbPrefix}
   where
    stripPsbPrefix :: Text -> Text
    stripPsbPrefix value = case Text.stripPrefix "psb" value of
      Just stripped -> haskellCamelToDhallSnake stripped
      Nothing -> value

haskellCamelToDhallSnake :: Text -> Text
haskellCamelToDhallSnake value =
  Text.toLower
    ( Text.concat
        [ if i > 0 && Char.isUpper c
            then Text.pack ['_', c]
            else Text.singleton c
        | (i :: Int, c) <- zip [0 ..] (Text.unpack value)
        ]
    )

data ConfigFile = ConfigFile
  { aws :: AwsCredentialsRef
  , route53 :: Route53Section
  , aws_substrate :: AwsSubstrateSection
  , ses :: SesSection
  , domain :: DomainSection
  , acme :: AcmeSection
  , deployment :: DeploymentSection
  , storage :: StorageSection
  , pulumi_state_backend :: PulumiStateBackendSection
  }
  deriving (Eq, Show, Generic, FromDhall)

data ValidatedSettings = ValidatedSettings
  { validatedConfig :: ConfigFile
  , resolvedManualPvHostRoot :: FilePath
  }
  deriving (Eq, Show)

supportedPublicHostname :: Text
supportedPublicHostname = "test.resolvefintech.com"

validateAndLoadSettings :: FilePath -> IO (Either String ValidatedSettings)
validateAndLoadSettings repoRoot = do
  configResult <- loadConfigForSettingsWith (loadRuntimeInForceConfig repoRoot) repoRoot
  case configResult of
    Left err -> pure (Left err)
    Right config -> validateConfig repoRoot config

-- | Lifecycle bootstrap settings are the repository Dhall seed/propose input.
-- Use this only for the pre-Vault/pre-MinIO steps that cannot read the
-- encrypted in-force config yet.
validateAndLoadBootstrapSettings :: FilePath -> IO (Either String ValidatedSettings)
validateAndLoadBootstrapSettings repoRoot = do
  configResult <- loadConfigFile repoRoot
  case configResult of
    Left err -> pure (Left err)
    Right config -> validateConfig repoRoot config

validateAndLoadSettingsWithVaultToken
  :: FilePath -> VaultToken -> IO (Either String ValidatedSettings)
validateAndLoadSettingsWithVaultToken repoRoot token = do
  configResult <-
    loadConfigForSettingsWith (loadRuntimeInForceConfigWithToken repoRoot token) repoRoot
  case configResult of
    Left err -> pure (Left err)
    Right config -> validateConfig repoRoot config

-- | Resolve the config source for supported host settings loads. Without an
-- unencrypted-basics file, the filesystem Dhall remains the first-bring-up seed
-- input. Once basics exist, the filesystem file is no longer authoritative:
-- the caller-supplied in-force loader must fetch and decrypt the MinIO SSoT.
loadConfigForSettingsWith
  :: (UnencryptedBasics -> IO (Either String ConfigFile))
  -> FilePath
  -> IO (Either String ConfigFile)
loadConfigForSettingsWith loadInForce repoRoot = do
  let paths = canonicalConfigPaths repoRoot
  basicsExists <- doesFileExist (configBasicsPath paths)
  if not basicsExists
    then loadConfigFile repoRoot
    else do
      basicsResult <- loadUnencryptedBasics repoRoot
      case basicsResult of
        Left err -> pure (Left err)
        Right basics -> loadInForce basics

loadRuntimeInForceConfig :: FilePath -> UnencryptedBasics -> IO (Either String ConfigFile)
loadRuntimeInForceConfig repoRoot basics = do
  let address = VaultAddress (basicsVaultAddress basics)
  tokenResult <- loadReadyVaultRootToken repoRoot address
  case tokenResult of
    Left err -> pure (Left err)
    Right token -> loadRuntimeInForceConfigWithToken repoRoot token basics

loadRuntimeInForceConfigWithToken
  :: FilePath -> VaultToken -> UnencryptedBasics -> IO (Either String ConfigFile)
loadRuntimeInForceConfigWithToken repoRoot token basics = do
  let address = VaultAddress (basicsVaultAddress basics)
  credentialsResult <- readMinioRootCredentials address token
  case credentialsResult of
    Left err -> pure (Left err)
    Right (accessKey, secretKey) -> do
      hmacKeyResult <- readObjectStoreHmacKey address token
      case hmacKeyResult of
        Left err -> pure (Left err)
        Right hmacKey -> do
          let cipher = vaultTransitDekCipher address token "prodbox-active-config"
          portForwardResult <-
            withMinioPortForward $ \localPort ->
              fetchInForceValueWith
                ( fetchInForceConfigEnvelope
                    localPort
                    (Text.unpack accessKey)
                    (Text.unpack secretKey)
                    hmacKey
                )
                cipher
                (basicsClusterId basics)
                (decodeConfigDhallBytes repoRoot)
          pure $ case portForwardResult of
            Left err -> Left ("failed to reach in-force config MinIO backend: " ++ err)
            Right result -> mapLeft renderInForceConfigError result

readMinioRootCredentials :: VaultAddress -> VaultToken -> IO (Either String (Text, Text))
readMinioRootCredentials address token = do
  result <- vaultKvReadV2 address token "secret" "minio/root"
  pure $ case result of
    Left err -> Left ("failed to read secret/minio/root from Vault: " ++ renderHttpError err)
    Right fields -> do
      accessKey <- requireVaultField "secret/minio/root" "rootUser" fields
      secretKey <- requireVaultField "secret/minio/root" "rootPassword" fields
      Right (accessKey, secretKey)

readObjectStoreHmacKey :: VaultAddress -> VaultToken -> IO (Either String ByteString)
readObjectStoreHmacKey address token = do
  result <- vaultKvReadV2 address token "secret" "object-store/hmac"
  pure $ case result of
    Left err -> Left ("failed to read secret/object-store/hmac from Vault: " ++ renderHttpError err)
    Right fields -> TextEncoding.encodeUtf8 <$> requireVaultField "secret/object-store/hmac" "key" fields

fetchInForceConfigEnvelope
  :: Int
  -> String
  -> String
  -> ByteString
  -> IO (Either String ByteString)
fetchInForceConfigEnvelope localPort accessKey secretKey hmacKey = do
  let key = objectKeyForOpaqueId (opaqueObjectId hmacKey LogicalInForceConfig)
      config =
        ObjectStoreConfig
          { objectStoreEndpoint = "http://127.0.0.1:" ++ show localPort
          , objectStoreBucket = defaultObjectStoreBucket
          , objectStoreAccessKey = accessKey
          , objectStoreSecretKey = secretKey
          }
  result <- getObject config key
  pure $ case result of
    Left err -> Left err
    Right Nothing -> Left ("in-force config object missing at " ++ Text.unpack key)
    Right (Just envelope) -> Right envelope

requireVaultField :: Text -> Text -> Map.Map Text Text -> Either String Text
requireVaultField path field fields =
  case Map.lookup field fields of
    Nothing -> Left ("Vault KV object " ++ Text.unpack path ++ " missing field `" ++ Text.unpack field ++ "`")
    Just value
      | Text.null (Text.strip value) ->
          Left ("Vault KV object " ++ Text.unpack path ++ " field `" ++ Text.unpack field ++ "` is empty")
      | otherwise -> Right value

resolveAwsCredentialsRefFromHostVault
  :: FilePath -> String -> AwsCredentialsRef -> IO (Either String Credentials)
resolveAwsCredentialsRefFromHostVault repoRoot label refs = do
  accessKeyResult <- resolveRequiredSecret "access_key_id" (awsCredentialAccessKeyId refs)
  secretKeyResult <- resolveRequiredSecret "secret_access_key" (awsCredentialSecretAccessKey refs)
  sessionTokenResult <- resolveOptionalSecret "session_token" (awsCredentialSessionToken refs)
  pure $ do
    accessKey <- accessKeyResult
    secretKey <- secretKeyResult
    sessionTokenValue <- sessionTokenResult
    let regionValue = Text.strip (awsCredentialRegion refs)
    if Text.null regionValue
      then Left (label ++ ".region must not be empty")
      else
        Right
          Credentials
            { access_key_id = accessKey
            , secret_access_key = secretKey
            , session_token = sessionTokenValue
            , region = regionValue
            }
 where
  resolveRequiredSecret
    :: String -> SecretRef -> IO (Either String Text)
  resolveRequiredSecret field ref = do
    result <- resolveHostSecretRef field ref
    pure $ case result of
      Left err -> Left err
      Right value
        | Text.null (Text.strip value) ->
            Left (label ++ "." ++ field ++ " resolved from Vault as empty")
        | otherwise -> Right (Text.strip value)

  resolveOptionalSecret
    :: String -> Maybe SecretRef -> IO (Either String (Maybe Text))
  resolveOptionalSecret _ Nothing = pure (Right Nothing)
  resolveOptionalSecret field (Just ref) = do
    result <- resolveHostSecretRef field ref
    pure $ case result of
      Left err -> Left err
      Right value -> Right (normalizeOptionalText value)

  resolveHostSecretRef :: String -> SecretRef -> IO (Either String Text)
  resolveHostSecretRef field ref =
    case ref of
      SecretRefVault resolvedVaultRef ->
        readHostVaultKvField
          repoRoot
          (vaultSecretMount resolvedVaultRef)
          (vaultSecretPath resolvedVaultRef)
          (vaultSecretField resolvedVaultRef)
      SecretRefTestPlaintext _ ->
        pure
          ( Left
              ( label
                  ++ "."
                  ++ field
                  ++ ": plaintext secret values are forbidden in production config; use a SecretRef.Vault reference"
              )
          )
      SecretRefTransitKey _ ->
        pure (Left (label ++ "." ++ field ++ ": TransitKey references are not readable AWS credentials"))
      SecretRefPrompt spec ->
        pure
          ( Left
              ( label
                  ++ "."
                  ++ field
                  ++ ": prompted secret "
                  ++ Text.unpack (promptSpecName spec)
                  ++ " cannot be resolved non-interactively"
              )
          )

renderSettingsDisplay :: Bool -> ValidatedSettings -> String
renderSettingsDisplay showSecrets settings =
  unlines
    [ "aws.region=" ++ renderText (awsCredentialRegion (aws config))
    , "aws.access_key_id=" ++ renderSecretRefDisplay (awsCredentialAccessKeyId (aws config))
    , "aws.secret_access_key=" ++ renderSecretRefDisplay (awsCredentialSecretAccessKey (aws config))
    , "aws.session_token=" ++ renderMaybeSecretRefDisplay (awsCredentialSessionToken (aws config))
    , "route53.zone_id=" ++ renderText (zone_id (route53 config))
    , "aws_substrate.hosted_zone_id=" ++ renderText (hosted_zone_id (aws_substrate config))
    , "aws_substrate.subzone_name=" ++ renderText (subzone_name (aws_substrate config))
    , "ses.sender_domain=" ++ renderText (sender_domain (ses config))
    , "ses.receive_subdomain=" ++ renderText (receive_subdomain (ses config))
    , "ses.capture_bucket=" ++ renderText (capture_bucket (ses config))
    , "domain.demo_fqdn=" ++ renderText (demo_fqdn (domain config))
    , "domain.demo_ttl=" ++ show (demo_ttl (domain config))
    , "acme.email=" ++ renderSensitive showSecrets (email (acme config))
    , "acme.server=" ++ renderText (server (acme config))
    , "acme.eab_key_id=" ++ renderMaybeSecretRefDisplay (eab_key_id (acme config))
    , "acme.eab_hmac_key=" ++ renderMaybeSecretRefDisplay (eab_hmac_key (acme config))
    , "deployment.dev_mode=" ++ renderBool (dev_mode (deployment config))
    , "deployment.bootstrap_public_ip_override="
        ++ renderMaybeText (bootstrap_public_ip_override (deployment config))
    , "deployment.pulumi_enable_dns_bootstrap="
        ++ renderBool (pulumi_enable_dns_bootstrap (deployment config))
    , "deployment.public_edge_advertisement_mode="
        ++ renderMaybeText (public_edge_advertisement_mode (deployment config))
    , "deployment.public_edge_bgp_peers=" ++ renderBgpPeers (public_edge_bgp_peers (deployment config))
    , "deployment.envoy_gateway_controller_replicas="
        ++ renderMaybeNatural (envoy_gateway_controller_replicas (deployment config))
    , "deployment.envoy_gateway_data_plane_replicas="
        ++ renderMaybeNatural (envoy_gateway_data_plane_replicas (deployment config))
    , "deployment.api_replicas=" ++ renderMaybeNatural (api_replicas (deployment config))
    , "deployment.websocket_replicas=" ++ renderMaybeNatural (websocket_replicas (deployment config))
    , "storage.manual_pv_host_root=" ++ resolvedManualPvHostRoot settings
    , "pulumi_state_backend.bucket_name="
        ++ renderText (psbBucketName (pulumi_state_backend config))
    , "pulumi_state_backend.region="
        ++ renderText (psbRegion (pulumi_state_backend config))
    , "pulumi_state_backend.key_prefix="
        ++ renderText (psbKeyPrefix (pulumi_state_backend config))
    ]
 where
  config = validatedConfig settings

loadConfigFile :: FilePath -> IO (Either String ConfigFile)
loadConfigFile repoRoot = do
  let configPath = configDhallPath (canonicalConfigPaths repoRoot)
  configExists <- doesFileExist configPath
  if not configExists
    then pure (Left (missingConfigMessage configPath))
    else do
      result <- try (inputFile auto configPath)
      pure $ case result of
        Left (e :: SomeException) ->
          Left
            ( "Failed to decode Dhall config `"
                ++ configPath
                ++ "`: "
                ++ displayException e
            )
        Right config -> Right config

-- | Decode in-force config payload bytes as Dhall, preserving the repository
-- import contract by materializing the payload beside
-- @prodbox-config-types.dhall@ before calling the same Dhall decoder as
-- 'loadConfigFile'.
decodeConfigDhallBytes :: FilePath -> ByteString -> IO (Either String ConfigFile)
decodeConfigDhallBytes repoRoot payload =
  withSystemTempDirectory "prodbox-in-force-config" $ \tmpDir -> do
    let paths = canonicalConfigPaths repoRoot
        schemaPath = configSchemaPath paths
        tmpSchemaPath = tmpDir </> "prodbox-config-types.dhall"
        tmpConfigPath = tmpDir </> "prodbox-config.dhall"
    schemaCopyResult <- try (copyFile schemaPath tmpSchemaPath) :: IO (Either SomeException ())
    case schemaCopyResult of
      Left err ->
        pure
          ( Left
              ( "Failed to prepare Dhall schema for in-force config decode `"
                  ++ schemaPath
                  ++ "`: "
                  ++ displayException err
              )
          )
      Right () -> do
        payloadWriteResult <- try (BS.writeFile tmpConfigPath payload) :: IO (Either SomeException ())
        case payloadWriteResult of
          Left err ->
            pure
              ( Left
                  ( "Failed to materialize in-force config payload `"
                      ++ tmpConfigPath
                      ++ "`: "
                      ++ displayException err
                  )
              )
          Right () -> loadConfigFile tmpDir

loadUnencryptedBasics :: FilePath -> IO (Either String UnencryptedBasics)
loadUnencryptedBasics repoRoot = do
  let basicsPath = configBasicsPath (canonicalConfigPaths repoRoot)
  exists <- doesFileExist basicsPath
  if not exists
    then pure (Left ("Missing unencrypted basics file: " ++ basicsPath))
    else do
      readResult <- try (BS.readFile basicsPath) :: IO (Either SomeException ByteString)
      pure $ case readResult of
        Left err ->
          Left
            ( "Failed to read unencrypted basics `"
                ++ basicsPath
                ++ "`: "
                ++ displayException err
            )
        Right bytes -> do
          basics <- mapLeft renderBasicsError (basicsFromJson bytes)
          mapLeft renderBasicsError (validateBasics basics)
          pure basics

writeUnencryptedBasics :: FilePath -> UnencryptedBasics -> IO (Either String ())
writeUnencryptedBasics repoRoot basics =
  case mapLeft renderBasicsError (validateBasics basics) of
    Left err -> pure (Left err)
    Right () -> do
      let basicsPath = configBasicsPath (canonicalConfigPaths repoRoot)
      writeResult <-
        try
          ( do
              createDirectoryIfMissing True (takeDirectory basicsPath)
              BS.writeFile basicsPath (basicsToJson basics)
          )
          :: IO (Either SomeException ())
      pure $ case writeResult of
        Left err ->
          Left
            ( "Failed to write unencrypted basics `"
                ++ basicsPath
                ++ "`: "
                ++ displayException err
            )
        Right () -> Right ()

validateConfig :: FilePath -> ConfigFile -> IO (Either String ValidatedSettings)
validateConfig repoRoot config = do
  resolvedManualRoot <- makeAbsolute (repoRoot </> Text.unpack (manual_pv_host_root (storage config)))
  pure $ do
    -- Local commands (cluster, charts, host, config, gateway) decode and
    -- validate config WITHOUT requiring operational AWS credentials or the
    -- Route 53 / ACME public-edge fields. Those belong to the AWS / edge
    -- tier ('validateAwsBootstrapConfig' / 'validateOperationalAwsCredentials')
    -- and are validated lazily only when a command actually reaches AWS.
    validateLocalConfig config
    pure
      ValidatedSettings
        { validatedConfig = config
        , resolvedManualPvHostRoot = resolvedManualRoot
        }

-- | Purely-local config invariants: the supported public hostname, the
-- demo TTL bounds, the operational @aws.*@ SecretRef shape, and the
-- public-edge deployment knobs. No operational AWS credentials, Route 53
-- zone, or ACME account are required here, so a host with an empty @aws.*@
-- block still decodes config for every local cluster command.
validateLocalConfig :: ConfigFile -> Either String ()
validateLocalConfig config = do
  validateSupportedPublicHost (demo_fqdn (domain config))
  validateDemoTtl (demo_ttl (domain config))
  validateAwsCredentialsRef "aws" (aws config)
  validatePublicEdgeDeployment (deployment config)

mapLeft :: (left -> left') -> Either left right -> Either left' right
mapLeft f value = case value of
  Left err -> Left (f err)
  Right result -> Right result

-- | The AWS / public-edge tier: everything 'validateLocalConfig' checks
-- plus the Route 53 zone and ACME account required to provision public
-- DNS + TLS. Called by AWS-touching flows (the IAM harness, SES, and the
-- @prodbox aws ...@ surface), never by local cluster commands.
validateAwsBootstrapConfig :: ConfigFile -> Either String ()
validateAwsBootstrapConfig config = do
  validateLocalConfig config
  requireNonEmpty "route53.zone_id" (zone_id (route53 config))
  requireNonEmpty "acme.email" (email (acme config))
  requireNonEmpty "acme.server" (server (acme config))
  validateAcmeBinding (acme config)

-- | Operational AWS credentials gate. Local commands never call this;
-- AWS-credential-consuming flows (edge reconcile, the Route 53 checks,
-- the @AwsCredentialsValid@ prerequisite) call it so an empty @aws.*@
-- block fails fast with a remedy ("Run @prodbox aws setup@") instead of
-- an opaque AWS-CLI error.
validateOperationalAwsCredentials :: ConfigFile -> Either String ()
validateOperationalAwsCredentials config = do
  validateAwsCredentialsRef "aws" (aws config)
  requireNonEmpty "aws.region" (awsCredentialRegion (aws config))

validatePublicEdgeDeployment :: DeploymentSection -> Either String ()
validatePublicEdgeDeployment deploymentSection = do
  validateBootstrapOverride
  validateAdvertisementMode
  validateReplicas
    "deployment.envoy_gateway_controller_replicas"
    (envoy_gateway_controller_replicas deploymentSection)
  validateReplicas
    "deployment.envoy_gateway_data_plane_replicas"
    (envoy_gateway_data_plane_replicas deploymentSection)
  validateReplicas "deployment.api_replicas" (api_replicas deploymentSection)
  validateReplicas "deployment.websocket_replicas" (websocket_replicas deploymentSection)
 where
  normalizedMode =
    fmap (Text.toLower . Text.strip) (public_edge_advertisement_mode deploymentSection)
  validateBootstrapOverride =
    validateOptionalIpAddressField
      "deployment.bootstrap_public_ip_override"
      (normalizeMaybeText (bootstrap_public_ip_override deploymentSection))
  validateAdvertisementMode =
    case normalizedMode of
      Nothing -> Right ()
      Just "l2" -> Right ()
      Just "bgp" ->
        case public_edge_bgp_peers deploymentSection of
          Just peers
            | not (null peers) ->
                mapM_ (uncurry validateBgpPeer) (zip [1 :: Int ..] peers)
          _ ->
            Left
              "deployment.public_edge_bgp_peers must contain at least one non-empty peer when deployment.public_edge_advertisement_mode is bgp"
      _ -> Left "deployment.public_edge_advertisement_mode must be l2 or bgp when set"

validateReplicas :: String -> Maybe Natural -> Either String ()
validateReplicas _ Nothing = Right ()
validateReplicas fieldName (Just value)
  | value >= 1 = Right ()
  | otherwise = Left (fieldName ++ " must be at least 1 when set")

requireNonEmpty :: String -> Text -> Either String ()
requireNonEmpty fieldName value =
  if Text.strip value == ""
    then Left (fieldName ++ " must not be empty")
    else Right ()

validateBgpPeer :: Int -> MetallbBgpPeer -> Either String ()
validateBgpPeer index peer = do
  requireNonEmpty fieldPrefixName (peer_name peer)
  requireNonEmpty fieldPrefixAddress (peer_address peer)
  validateOptionalIpAddressField fieldPrefixAddress (normalizeOptionalText (peer_address peer))
 where
  fieldPrefix = "deployment.public_edge_bgp_peers[" ++ show index ++ "]"
  fieldPrefixName = fieldPrefix ++ ".peer_name"
  fieldPrefixAddress = fieldPrefix ++ ".peer_address"

validateOptionalIpAddressField :: String -> Maybe Text -> Either String ()
validateOptionalIpAddressField _ Nothing = Right ()
validateOptionalIpAddressField fieldName (Just value)
  | isValidIpLiteral (Text.strip value) = Right ()
  | otherwise = Left (fieldName ++ " must be a valid IP address when set")

isValidIpLiteral :: Text -> Bool
isValidIpLiteral value =
  isValidIpv4Literal value || isValidIpv6Literal value

isValidIpv4Literal :: Text -> Bool
isValidIpv4Literal value =
  case Text.splitOn "." value of
    [firstOctet, secondOctet, thirdOctet, fourthOctet] ->
      all isValidIpv4Octet [firstOctet, secondOctet, thirdOctet, fourthOctet]
    _ -> False

isValidIpv4Octet :: Text -> Bool
isValidIpv4Octet octet =
  not (Text.null octet)
    && Text.all isDigit octet
    && case reads (Text.unpack octet) of
      [(value, "")] -> value >= (0 :: Int) && value <= 255
      _ -> False

isValidIpv6Literal :: Text -> Bool
isValidIpv6Literal value =
  case Text.splitOn "::" value of
    [groupsText] ->
      let groups = splitIpv6Groups groupsText
       in not (null groups) && isValidIpv6GroupList groups && ipv6GroupWidth groups == 8
    [leftText, rightText] ->
      let leftGroups = splitIpv6Groups leftText
          rightGroups = splitIpv6Groups rightText
          totalWidth = ipv6GroupWidth leftGroups + ipv6GroupWidth rightGroups
       in isValidIpv6GroupList leftGroups
            && isValidIpv6GroupList rightGroups
            && totalWidth < 8
    _ -> False

splitIpv6Groups :: Text -> [Text]
splitIpv6Groups value
  | Text.null value = []
  | otherwise = Text.splitOn ":" value

isValidIpv6GroupList :: [Text] -> Bool
isValidIpv6GroupList groups =
  and (zipWith validateGroup [0 :: Int ..] groups)
 where
  lastIndex = length groups - 1
  validateGroup index group
    | Text.null group = False
    | isValidIpv4Literal group = index == lastIndex
    | otherwise = isValidIpv6Hextet group

isValidIpv6Hextet :: Text -> Bool
isValidIpv6Hextet group =
  let lengthValue = Text.length group
   in lengthValue >= 1 && lengthValue <= 4 && Text.all isHexDigit group

ipv6GroupWidth :: [Text] -> Int
ipv6GroupWidth =
  sum . map (\group -> if isValidIpv4Literal group then 2 else 1)

validateSupportedPublicHost :: Text -> Either String ()
validateSupportedPublicHost value
  | normalized == "" = Left "domain.demo_fqdn must not be empty"
  | lowerValue /= Text.toLower supportedPublicHostname =
      Left
        ( "domain.demo_fqdn must be "
            ++ Text.unpack supportedPublicHostname
        )
  | otherwise = Right ()
 where
  normalized = Text.unpack (Text.strip value)
  lowerValue = Text.toLower (Text.strip value)

validateDemoTtl :: Natural -> Either String ()
validateDemoTtl ttl
  | ttl < 30 = Left "domain.demo_ttl must be between 30 and 86400"
  | ttl > 86400 = Left "domain.demo_ttl must be between 30 and 86400"
  | otherwise = Right ()

-- | Sprint 7.15: the ZeroSSL external-account-binding (EAB) key ID and HMAC
-- key are no longer plaintext @Optional Text@; they are @SecretRef.Vault@
-- references into @secret/acme/eab@ (fields @key_id@ / @hmac_key@), resolved
-- through Vault exactly like the operational @aws.*@ credentials. ZeroSSL
-- still requires both present; non-ZeroSSL servers may omit both; one without
-- the other is rejected; and a plaintext (non-@Vault@) reference is rejected
-- through the same 'validateVaultRef' discipline used for @aws.*@.
validateAcmeBinding :: AcmeSection -> Either String ()
validateAcmeBinding acmeSection
  | isZeroSslServer (server acmeSection)
      && (eab_key_id acmeSection == Nothing || eab_hmac_key acmeSection == Nothing) =
      Left "acme.eab_key_id and acme.eab_hmac_key are required for ZeroSSL ACME"
  | hasExactlyOne (eab_key_id acmeSection) (eab_hmac_key acmeSection) =
      Left "acme.eab_key_id and acme.eab_hmac_key must either both be set or both be empty"
  | otherwise = do
      mapM_ (validateVaultRef "acme.eab_key_id") (eab_key_id acmeSection)
      mapM_ (validateVaultRef "acme.eab_hmac_key") (eab_hmac_key acmeSection)

validateAwsCredentialsRef :: String -> AwsCredentialsRef -> Either String ()
validateAwsCredentialsRef prefix refs = do
  validateVaultRef (prefix ++ ".access_key_id") (awsCredentialAccessKeyId refs)
  validateVaultRef (prefix ++ ".secret_access_key") (awsCredentialSecretAccessKey refs)
  mapM_ (validateVaultRef (prefix ++ ".session_token")) (awsCredentialSessionToken refs)

validateVaultRef :: String -> SecretRef -> Either String ()
validateVaultRef fieldName ref =
  case ref of
    SecretRefVault _ -> Right ()
    _ -> Left (fieldName ++ " must be a SecretRef.Vault reference")

normalizeOptionalText :: Text -> Maybe Text
normalizeOptionalText value =
  if Text.strip value == ""
    then Nothing
    else Just value

normalizeMaybeText :: Maybe Text -> Maybe Text
normalizeMaybeText maybeValue = maybeValue >>= normalizeOptionalText

isZeroSslServer :: Text -> Bool
isZeroSslServer serverUrl =
  "https://acme.zerossl.com" `Text.isPrefixOf` Text.toLower serverUrl

hasExactlyOne :: Maybe a -> Maybe b -> Bool
hasExactlyOne left right =
  case (left, right) of
    (Just _, Nothing) -> True
    (Nothing, Just _) -> True
    _ -> False

renderSensitive :: Bool -> Text -> String
renderSensitive showSecrets value =
  renderMaybeText $
    if Text.strip value == ""
      then Nothing
      else Just (if showSecrets then value else maskSecret value)

renderMaybeText :: Maybe Text -> String
renderMaybeText maybeValue =
  maybe "" renderText maybeValue

renderText :: Text -> String
renderText = Text.unpack

renderSecretRefDisplay :: SecretRef -> String
renderSecretRefDisplay ref =
  case ref of
    SecretRefVault vault ->
      "Vault:"
        ++ Text.unpack (vaultSecretMount vault)
        ++ "/"
        ++ Text.unpack (vaultSecretPath vault)
        ++ "#"
        ++ Text.unpack (vaultSecretField vault)
    SecretRefTransitKey keyName -> "TransitKey:" ++ Text.unpack keyName
    SecretRefPrompt spec -> "Prompt:" ++ Text.unpack (promptSpecName spec)
    SecretRefTestPlaintext _ -> "TestPlaintext:<redacted>"

renderMaybeSecretRefDisplay :: Maybe SecretRef -> String
renderMaybeSecretRefDisplay =
  maybe "" renderSecretRefDisplay

renderBool :: Bool -> String
renderBool value =
  map toLower (show value)

renderMaybeNatural :: Maybe Natural -> String
renderMaybeNatural maybeValue =
  maybe "" show maybeValue

renderBgpPeers :: Maybe [MetallbBgpPeer] -> String
renderBgpPeers maybePeers =
  case maybePeers of
    Nothing -> ""
    Just peers ->
      Text.unpack
        ( Text.intercalate
            ";"
            [ peer_name peer
                <> "@"
                <> peer_address peer
                <> ":peer_asn="
                <> Text.pack (show (peer_asn peer))
                <> ":my_asn="
                <> Text.pack (show (my_asn peer))
            | peer <- peers
            ]
        )

maskSecret :: Text -> Text
maskSecret value =
  if Text.length value > 4
    then "****" <> Text.takeEnd 4 value
    else "****"

operationalAwsCredentialsRef :: Text -> AwsCredentialsRef
operationalAwsCredentialsRef regionValue =
  AwsCredentialsRef
    { awsCredentialAccessKeyId = vaultRef "gateway/gateway/aws" "access_key_id"
    , awsCredentialSecretAccessKey = vaultRef "gateway/gateway/aws" "secret_access_key"
    , awsCredentialSessionToken = Nothing
    , awsCredentialRegion = regionValue
    }

vaultRef :: Text -> Text -> SecretRef
vaultRef path field =
  SecretRefVault
    VaultSecretRef
      { vaultSecretMount = "secret"
      , vaultSecretPath = path
      , vaultSecretField = field
      }

defaultConfigFile :: ConfigFile
defaultConfigFile =
  ConfigFile
    { aws = operationalAwsCredentialsRef "us-east-1"
    , route53 = Route53Section {zone_id = ""}
    , aws_substrate =
        AwsSubstrateSection
          { hosted_zone_id = ""
          , subzone_name = ""
          }
    , ses =
        SesSection
          { sender_domain = ""
          , receive_subdomain = ""
          , capture_bucket = ""
          }
    , domain =
        DomainSection
          { demo_fqdn = supportedPublicHostname
          , demo_ttl = 60
          }
    , acme =
        AcmeSection
          { email = ""
          , server = "https://acme.zerossl.com/v2/DV90"
          , eab_key_id = Just (vaultRef "acme/eab" "key_id")
          , eab_hmac_key = Just (vaultRef "acme/eab" "hmac_key")
          }
    , deployment =
        DeploymentSection
          { dev_mode = True
          , bootstrap_public_ip_override = Nothing
          , pulumi_enable_dns_bootstrap = True
          , public_edge_advertisement_mode = Just "l2"
          , public_edge_bgp_peers = Nothing
          , envoy_gateway_controller_replicas = Just 1
          , envoy_gateway_data_plane_replicas = Just 1
          , api_replicas = Just 2
          , websocket_replicas = Just 2
          }
    , storage = StorageSection {manual_pv_host_root = ".data"}
    , pulumi_state_backend =
        PulumiStateBackendSection
          { psbBucketName = ""
          , psbRegion = ""
          , psbKeyPrefix = "pulumi/"
          }
    }

renderConfigDhall :: ConfigFile -> String
renderConfigDhall config =
  unlines
    [ "let Config = ./prodbox-config-types.dhall"
    , ""
    , "in  Config::{"
    , "    , aws = Config.default.aws // {"
    , "        , access_key_id = " ++ dhallSecretRef (awsCredentialAccessKeyId (aws config))
    , "        , secret_access_key = " ++ dhallSecretRef (awsCredentialSecretAccessKey (aws config))
    , "        , session_token = " ++ dhallOptionalSecretRef (awsCredentialSessionToken (aws config))
    , "        , region = " ++ dhallText (awsCredentialRegion (aws config))
    , "        }"
    , "    , route53 = { zone_id = " ++ dhallText (zone_id (route53 config)) ++ " }"
    , "    , aws_substrate = Config.default.aws_substrate // {"
    , "        , hosted_zone_id = " ++ dhallText (hosted_zone_id (aws_substrate config))
    , "        , subzone_name = " ++ dhallText (subzone_name (aws_substrate config))
    , "        }"
    , "    , ses = Config.default.ses // {"
    , "        , sender_domain = " ++ dhallText (sender_domain (ses config))
    , "        , receive_subdomain = " ++ dhallText (receive_subdomain (ses config))
    , "        , capture_bucket = " ++ dhallText (capture_bucket (ses config))
    , "        }"
    , "    , domain = Config.default.domain // {"
    , "        , demo_fqdn = " ++ dhallText (demo_fqdn (domain config))
    , "        , demo_ttl = " ++ show (demo_ttl (domain config))
    , "        }"
    , "    , acme = Config.default.acme // {"
    , "        , email = " ++ dhallText (email (acme config))
    , "        , server = " ++ dhallText (server (acme config))
    , "        , eab_key_id = " ++ dhallOptionalSecretRef (eab_key_id (acme config))
    , "        , eab_hmac_key = " ++ dhallOptionalSecretRef (eab_hmac_key (acme config))
    , "        }"
    , "    , deployment = Config.default.deployment // {"
    , "        , dev_mode = " ++ dhallBool (dev_mode (deployment config))
    , "        , bootstrap_public_ip_override = "
        ++ dhallOptionalText (bootstrap_public_ip_override (deployment config))
    , "        , pulumi_enable_dns_bootstrap = "
        ++ dhallBool (pulumi_enable_dns_bootstrap (deployment config))
    , "        , public_edge_advertisement_mode = "
        ++ dhallOptionalText (public_edge_advertisement_mode (deployment config))
    , "        , public_edge_bgp_peers = "
        ++ dhallOptionalBgpPeers (public_edge_bgp_peers (deployment config))
    , "        , envoy_gateway_controller_replicas = "
        ++ dhallOptionalNatural (envoy_gateway_controller_replicas (deployment config))
    , "        , envoy_gateway_data_plane_replicas = "
        ++ dhallOptionalNatural (envoy_gateway_data_plane_replicas (deployment config))
    , "        , api_replicas = " ++ dhallOptionalNatural (api_replicas (deployment config))
    , "        , websocket_replicas = " ++ dhallOptionalNatural (websocket_replicas (deployment config))
    , "        }"
    , "    , storage = Config.default.storage // {"
    , "        , manual_pv_host_root = " ++ dhallText (manual_pv_host_root (storage config))
    , "        }"
    , "    , pulumi_state_backend = Config.default.pulumi_state_backend // {"
    , "        , bucket_name = " ++ dhallText (psbBucketName (pulumi_state_backend config))
    , "        , region = " ++ dhallText (psbRegion (pulumi_state_backend config))
    , "        , key_prefix = " ++ dhallText (psbKeyPrefix (pulumi_state_backend config))
    , "        }"
    , "    }"
    , ""
    ]

dhallText :: Text -> String
dhallText = show . Text.unpack

dhallOptionalText :: Maybe Text -> String
dhallOptionalText maybeValue =
  case maybeValue of
    Nothing -> "None Text"
    Just value -> "Some " ++ dhallText value

dhallSecretRef :: SecretRef -> String
dhallSecretRef ref =
  case ref of
    SecretRefVault vault ->
      "Config.SecretRef.Vault { mount = "
        ++ dhallText (vaultSecretMount vault)
        ++ ", path = "
        ++ dhallText (vaultSecretPath vault)
        ++ ", field = "
        ++ dhallText (vaultSecretField vault)
        ++ " }"
    SecretRefTransitKey name ->
      "Config.SecretRef.TransitKey " ++ dhallText name
    SecretRefPrompt spec ->
      "Config.SecretRef.Prompt { name = "
        ++ dhallText (promptSpecName spec)
        ++ ", purpose = "
        ++ dhallText (promptSpecPurpose spec)
        ++ " }"
    SecretRefTestPlaintext value ->
      "Config.SecretRef.TestPlaintext " ++ dhallText value

dhallOptionalSecretRef :: Maybe SecretRef -> String
dhallOptionalSecretRef maybeValue =
  case maybeValue of
    Nothing -> "None Config.SecretRef"
    Just value -> "Some (" ++ dhallSecretRef value ++ ")"

dhallOptionalNatural :: Maybe Natural -> String
dhallOptionalNatural maybeValue =
  case maybeValue of
    Nothing -> "None Natural"
    Just value -> "Some " ++ show value

dhallOptionalBgpPeers :: Maybe [MetallbBgpPeer] -> String
dhallOptionalBgpPeers maybePeers =
  case maybePeers of
    Nothing ->
      "None (List { peer_name : Text, peer_address : Text, peer_asn : Natural, my_asn : Natural, ebgp_multi_hop : Optional Bool })"
    Just [] ->
      "Some ([] : List { peer_name : Text, peer_address : Text, peer_asn : Natural, my_asn : Natural, ebgp_multi_hop : Optional Bool })"
    Just peers ->
      "Some [ "
        ++ foldr1
          (\left right -> left ++ ", " ++ right)
          (map dhallBgpPeer peers)
        ++ " ]"
 where
  dhallBgpPeer peer =
    "{ peer_name = "
      ++ dhallText (peer_name peer)
      ++ ", peer_address = "
      ++ dhallText (peer_address peer)
      ++ ", peer_asn = "
      ++ show (peer_asn peer)
      ++ ", my_asn = "
      ++ show (my_asn peer)
      ++ ", ebgp_multi_hop = "
      ++ dhallOptionalBool (ebgp_multi_hop peer)
      ++ " }"

dhallOptionalBool :: Maybe Bool -> String
dhallOptionalBool maybeValue =
  case maybeValue of
    Nothing -> "None Bool"
    Just value -> "Some " ++ dhallBool value

dhallBool :: Bool -> String
dhallBool True = "True"
dhallBool False = "False"

missingConfigMessage :: FilePath -> String
missingConfigMessage configPath =
  unlines
    [ "Missing required repository config `" ++ configPath ++ "`."
    , "Run `./.build/prodbox config setup` from the repository root to create it, then rerun the command."
    ]
