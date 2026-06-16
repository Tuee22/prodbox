{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Daemon Dhall settings module per
--   [config_doctrine.md §4](../../documents/engineering/config_doctrine.md#4-decoding).
--
-- Mirrors the host-CLI `Prodbox.Settings` pattern: a Dhall expression at the
-- daemon's `--config <path>` is decoded in-process by the native Haskell
-- `dhall` library, producing a typed `DaemonConfig` directly. No intermediate
-- JSON projection. No env-var fallback.
--
-- Sprint 2.20 closure (May 24, 2026): the JSON `parseDaemonConfig` fallback
-- path was removed once `renderGatewayConfigTemplate` migrated to emit Dhall
-- and the chart templates landed on Dhall content. `loadDaemonConfig` is
-- now Dhall-only.
module Prodbox.Gateway.Settings
  ( loadDaemonConfig
  , decodeDaemonConfigDhall
  , decodeDaemonConfigDhallWith
  , DaemonConfigDhall (..)
  , DaemonBootDhall (..)
  , DaemonLiveDhall (..)
  , DnsWriteGateDhall (..)
  , EventKeyDhall (..)
  , AwsCredsDhall (..)
  , MinioCredsDhall (..)
  , VaultKubernetesAuthDhall (..)
  , toDaemonConfig
  , toDaemonConfigWith
  , loadOrders
  , decodeOrdersDhall
  , OrdersDhall (..)
  , PeerEndpointDhall (..)
  , GatewayRuleDhall (..)
  , toOrders
  )
where

import Control.Exception (SomeException, displayException, try)
import Data.List (nub)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Dhall (FromDhall, auto, input, inputFile)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Gateway.Types
  ( DaemonConfig (..)
  , DnsWriteGate (..)
  , GatewayAwsCreds (..)
  , GatewayMinioCreds (..)
  , GatewayRule (..)
  , GatewayVaultAuth (..)
  , Orders (..)
  , PeerEndpoint (..)
  )
import Prodbox.Http.Client (renderHttpError)
import Prodbox.Settings.SecretRef
  ( SecretRef
  , SecretRefError (..)
  , SecretRefMode (..)
  , renderSecretRefError
  , resolveSecretRef
  , resolveSecretRefFromVault
  )
import Prodbox.Vault.Client
  ( VaultAddress (..)
  , vaultKubernetesLogin
  )

-- | Dhall-friendly DTO for the daemon config.
--
-- The schema is `{ schemaVersion : Natural, boot : { … }, live : { … } }`.
-- The `schemaVersion` field is part of the wire contract (matches the
-- structured JSON shape's `schemaVersion`) so chart-rendered Dhall files
-- carry an explicit version stamp; mismatched versions fail the decode in
-- 'toDaemonConfig'.
data DaemonConfigDhall = DaemonConfigDhall
  { schemaVersion :: Natural
  , vault :: Maybe VaultKubernetesAuthDhall
  , boot :: DaemonBootDhall
  , live :: DaemonLiveDhall
  }
  deriving (Eq, Show, Generic, FromDhall)

data VaultKubernetesAuthDhall = VaultKubernetesAuthDhall
  { address :: Text
  , auth_path :: Text
  , role :: Text
  , service_account_token_file :: Maybe Text
  }
  deriving (Eq, Show, Generic, FromDhall)

data DaemonBootDhall = DaemonBootDhall
  { node_id :: Text
  , cert_file :: Text
  , key_file :: Text
  , ca_file :: Text
  , orders_file :: Text
  , event_keys :: [EventKeyDhall]
  , dns_write_gate :: Maybe DnsWriteGateDhall
  , aws_creds :: Maybe AwsCredsDhall
  , minio_creds :: Maybe MinioCredsDhall
  , minio_endpoint_url :: Maybe Text
  -- ^ In-cluster MinIO Service endpoint URL used for gateway-owned
  -- object-store access. Sibling field on @boot@ rather than nested inside
  -- @minio_creds@ so the endpoint can be rendered by the chart-side
  -- ConfigMap while credentials stay Vault-backed SecretRef values.
  -- Canonical home value:
  -- @http://minio.prodbox.svc.cluster.local:9000@.
  }
  deriving (Eq, Show, Generic, FromDhall)

-- | Sprint 3.18: AWS credentials are Vault-backed SecretRefs, resolved by the
-- daemon through Vault Kubernetes auth during config load.
data AwsCredsDhall = AwsCredsDhall
  { access_key_id :: SecretRef
  , secret_access_key :: SecretRef
  , session_token :: Maybe SecretRef
  , region :: Text
  }
  deriving (Eq, Show, Generic, FromDhall)

-- | Sprint 3.18: MinIO credentials are Vault-backed SecretRefs, resolved by
-- the daemon through Vault Kubernetes auth during config load.
data MinioCredsDhall = MinioCredsDhall
  { minio_access_key :: SecretRef
  , minio_secret_key :: SecretRef
  }
  deriving (Eq, Show, Generic, FromDhall)

data DaemonLiveDhall = DaemonLiveDhall
  { heartbeat_interval_seconds :: Double
  , reconnect_interval_seconds :: Double
  , sync_interval_seconds :: Double
  , max_clock_skew_seconds :: Double
  , drain_deadline_seconds :: Maybe Natural
  , log_level :: Maybe Text
  }
  deriving (Eq, Show, Generic, FromDhall)

data DnsWriteGateDhall = DnsWriteGateDhall
  { zone_id :: Text
  , fqdn :: Text
  , ttl :: Natural
  , aws_region :: Text
  }
  deriving (Eq, Show, Generic, FromDhall)

data EventKeyDhall = EventKeyDhall
  { name :: Text
  , value :: SecretRef
  }
  deriving (Eq, Show, Generic, FromDhall)

-- | Supported schemaVersion stamp on the Dhall surface. Kept in sync with
-- 'Prodbox.Gateway.Types.supportedDaemonConfigSchemaVersion'.
supportedDhallSchemaVersion :: Natural
supportedDhallSchemaVersion = 1

-- | Convert the Dhall DTO to the runtime 'DaemonConfig' with the test-harness
-- SecretRef resolver. Production callers must use 'loadDaemonConfig', which
-- resolves Vault references through Kubernetes auth.
toDaemonConfig :: DaemonConfigDhall -> IO (Either String DaemonConfig)
toDaemonConfig = toDaemonConfigWith (resolveSecretRef TestHarnessMode)

-- | Convert the Dhall DTO to the runtime 'DaemonConfig' using the supplied
-- SecretRef resolver. Fails fast on schema-version mismatches, timing
-- invariants, and any secret reference that cannot be resolved.
toDaemonConfigWith
  :: (SecretRef -> IO (Either SecretRefError Text))
  -> DaemonConfigDhall
  -> IO (Either String DaemonConfig)
toDaemonConfigWith
  secretResolver
  DaemonConfigDhall
    { schemaVersion = sv
    , vault = maybeVaultAuth
    , boot =
      DaemonBootDhall
        { node_id = nodeIdText
        , cert_file = certFileText
        , key_file = keyFileText
        , ca_file = caFileText
        , orders_file = ordersFileText
        , event_keys = eventKeysList
        , dns_write_gate = maybeDnsGate
        , aws_creds = maybeAwsCreds
        , minio_creds = maybeMinioCreds
        , minio_endpoint_url = maybeMinioEndpoint
        }
    , live =
      DaemonLiveDhall
        { heartbeat_interval_seconds = hb
        , reconnect_interval_seconds = rc
        , sync_interval_seconds = sy
        , max_clock_skew_seconds = ms
        , drain_deadline_seconds = ddl
        , log_level = ll
        }
    } =
    case validateDaemonStaticFields of
      Left err -> pure (Left err)
      Right () -> do
        eventKeysResult <- traverseEitherIO (toEventKey secretResolver) eventKeysList
        awsCredsResult <- traverseMaybeEitherIO (toGatewayAwsCreds secretResolver) maybeAwsCreds
        minioCredsResult <- traverseMaybeEitherIO (toGatewayMinioCreds secretResolver) maybeMinioCreds
        pure $ do
          resolvedEventKeys <- eventKeysResult
          resolvedAwsCreds <- awsCredsResult
          resolvedMinioCreds <- minioCredsResult
          Right
            DaemonConfig
              { daemonNodeId = Text.unpack nodeIdText
              , daemonCertFile = Text.unpack certFileText
              , daemonKeyFile = Text.unpack keyFileText
              , daemonCaFile = Text.unpack caFileText
              , daemonOrdersFile = Text.unpack ordersFileText
              , daemonEventKeys = resolvedEventKeys
              , daemonHeartbeatInterval = hb
              , daemonReconnectInterval = rc
              , daemonSyncInterval = sy
              , daemonMaxClockSkewSeconds = ms
              , daemonDrainDeadlineSeconds = fromIntegral <$> ddl
              , daemonConfigLogLevel = Text.unpack <$> ll
              , daemonVaultAuth = toGatewayVaultAuth <$> maybeVaultAuth
              , daemonDnsWriteGate = toDnsWriteGate <$> maybeDnsGate
              , daemonAwsCreds = resolvedAwsCreds
              , daemonMinioCreds = resolvedMinioCreds
              , daemonMinioEndpointUrl = Text.unpack <$> maybeMinioEndpoint
              }
   where
    validateDaemonStaticFields = do
      if sv == supportedDhallSchemaVersion
        then Right ()
        else
          Left
            ( "config_schema_mismatch: expected schemaVersion "
                ++ show supportedDhallSchemaVersion
                ++ ", got "
                ++ show sv
            )
      requireNonEmpty "node_id" nodeIdText
      requireNonEmpty "cert_file" certFileText
      requireNonEmpty "key_file" keyFileText
      requireNonEmpty "ca_file" caFileText
      requireNonEmpty "orders_file" ordersFileText
      validatePositive "heartbeat_interval_seconds" hb
      validatePositive "reconnect_interval_seconds" rc
      validatePositive "sync_interval_seconds" sy
      validateNonNegative "max_clock_skew_seconds" ms
      case ddl of
        Just deadline | deadline == 0 -> Left "drain_deadline_seconds must be positive when set"
        _ -> Right ()

toEventKey
  :: (SecretRef -> IO (Either SecretRefError Text))
  -> EventKeyDhall
  -> IO (Either String (String, String))
toEventKey secretResolver EventKeyDhall {name = keyName, value = keyValueRef} = do
  keyValueResult <-
    resolveRequiredSecret secretResolver ("event_keys." ++ Text.unpack keyName ++ ".value") keyValueRef
  pure $ do
    keyValue <- keyValueResult
    Right (Text.unpack keyName, Text.unpack keyValue)

toGatewayAwsCreds
  :: (SecretRef -> IO (Either SecretRefError Text))
  -> AwsCredsDhall
  -> IO (Either String GatewayAwsCreds)
toGatewayAwsCreds
  secretResolver
  AwsCredsDhall
    { access_key_id = ak
    , secret_access_key = sk
    , session_token = st
    , region = rg
    } =
    if Text.null rg
      then pure (Left "aws_creds.region is required")
      else do
        accessKeyResult <- resolveRequiredSecret secretResolver "aws_creds.access_key_id" ak
        secretKeyResult <- resolveRequiredSecret secretResolver "aws_creds.secret_access_key" sk
        sessionTokenResult <- resolveOptionalSecret secretResolver "aws_creds.session_token" st
        pure $ do
          accessKey <- accessKeyResult
          secretKey <- secretKeyResult
          session <- sessionTokenResult
          Right
            GatewayAwsCreds
              { gatewayAwsAccessKeyId = Text.unpack accessKey
              , gatewayAwsSecretAccessKey = Text.unpack secretKey
              , gatewayAwsSessionToken = Text.unpack <$> session
              , gatewayAwsRegion = Text.unpack rg
              }

toGatewayMinioCreds
  :: (SecretRef -> IO (Either SecretRefError Text))
  -> MinioCredsDhall
  -> IO (Either String GatewayMinioCreds)
toGatewayMinioCreds
  secretResolver
  MinioCredsDhall
    { minio_access_key = ak
    , minio_secret_key = sk
    } = do
    accessKeyResult <- resolveRequiredSecret secretResolver "minio_creds.minio_access_key" ak
    secretKeyResult <- resolveRequiredSecret secretResolver "minio_creds.minio_secret_key" sk
    pure $ do
      accessKey <- accessKeyResult
      secretKey <- secretKeyResult
      Right
        GatewayMinioCreds
          { gatewayMinioAccessKey = Text.unpack accessKey
          , gatewayMinioSecretKey = Text.unpack secretKey
          }

resolveRequiredSecret
  :: (SecretRef -> IO (Either SecretRefError Text))
  -> String
  -> SecretRef
  -> IO (Either String Text)
resolveRequiredSecret secretResolver fieldName ref = do
  result <- secretResolver ref
  pure $ case result of
    Left err -> Left (fieldName ++ ": " ++ renderSecretRefError err)
    Right value ->
      if Text.null value
        then Left (fieldName ++ " resolved to an empty value")
        else Right value

resolveOptionalSecret
  :: (SecretRef -> IO (Either SecretRefError Text))
  -> String
  -> Maybe SecretRef
  -> IO (Either String (Maybe Text))
resolveOptionalSecret _ _ Nothing = pure (Right Nothing)
resolveOptionalSecret secretResolver fieldName (Just ref) = do
  result <- secretResolver ref
  pure $ case result of
    Left err -> Left (fieldName ++ ": " ++ renderSecretRefError err)
    Right value ->
      let stripped = Text.strip value
       in Right (if Text.null stripped then Nothing else Just stripped)

traverseEitherIO :: (a -> IO (Either String b)) -> [a] -> IO (Either String [b])
traverseEitherIO _ [] = pure (Right [])
traverseEitherIO f (x : xs) = do
  result <- f x
  case result of
    Left err -> pure (Left err)
    Right value -> do
      rest <- traverseEitherIO f xs
      pure ((value :) <$> rest)

traverseMaybeEitherIO :: (a -> IO (Either String b)) -> Maybe a -> IO (Either String (Maybe b))
traverseMaybeEitherIO _ Nothing = pure (Right Nothing)
traverseMaybeEitherIO f (Just value) = fmap Just <$> f value

toDnsWriteGate :: DnsWriteGateDhall -> DnsWriteGate
toDnsWriteGate g =
  DnsWriteGate
    { dnsWriteGateZoneId = Text.unpack (zone_id g)
    , dnsWriteGateFqdn = Text.unpack (fqdn g)
    , dnsWriteGateTtl = fromIntegral (ttl g)
    , dnsWriteGateAwsRegion = Text.unpack (aws_region g)
    }

toGatewayVaultAuth :: VaultKubernetesAuthDhall -> GatewayVaultAuth
toGatewayVaultAuth auth =
  GatewayVaultAuth
    { gatewayVaultAddress = Text.unpack (address auth)
    , gatewayVaultAuthPath = Text.unpack (auth_path auth)
    , gatewayVaultRole = Text.unpack (role auth)
    , gatewayVaultServiceAccountTokenFile =
        Text.unpack
          ( fromMaybe
              (Text.pack defaultVaultServiceAccountTokenFile)
              (service_account_token_file auth)
          )
    }

requireNonEmpty :: String -> Text -> Either String ()
requireNonEmpty fieldName fieldValue =
  if Text.null fieldValue
    then Left (fieldName ++ " is required")
    else Right ()

validatePositive :: String -> Double -> Either String ()
validatePositive fieldName fieldValue =
  if fieldValue > 0
    then Right ()
    else Left (fieldName ++ " must be positive")

validateNonNegative :: String -> Double -> Either String ()
validateNonNegative fieldName fieldValue =
  if fieldValue >= 0
    then Right ()
    else Left (fieldName ++ " must be non-negative")

-- | Decode a Dhall text expression to 'DaemonConfig'. Exposed for test
-- fixtures that supply Dhall source as a string rather than a file path.
decodeDaemonConfigDhall :: Text -> IO (Either String DaemonConfig)
decodeDaemonConfigDhall src = do
  decodeDaemonConfigDhallWith (resolveSecretRef TestHarnessMode) src

decodeDaemonConfigDhallWith
  :: (SecretRef -> IO (Either SecretRefError Text))
  -> Text
  -> IO (Either String DaemonConfig)
decodeDaemonConfigDhallWith secretResolver src = do
  result <- try (input auto src) :: IO (Either SomeException DaemonConfigDhall)
  case result of
    Left e -> pure (Left ("failed to decode gateway daemon Dhall config: " ++ displayException e))
    Right dto -> toDaemonConfigWith secretResolver dto

-- | Canonical entrypoint: load the daemon config from the file at the path
-- passed via `--config <path>`. Sprint 2.20 closure: the JSON dispatch arm
-- is removed; the daemon decodes Dhall exclusively via
-- `Dhall.inputFile auto`.
loadDaemonConfig :: FilePath -> IO (Either String DaemonConfig)
loadDaemonConfig path = do
  result <- try (inputFile auto path) :: IO (Either SomeException DaemonConfigDhall)
  case result of
    Left e ->
      pure
        ( Left
            ( "failed to decode gateway daemon Dhall config `"
                ++ path
                ++ "`: "
                ++ displayException e
            )
        )
    Right dto -> toDaemonConfigWith (resolveGatewaySecretRef dto) dto

defaultVaultServiceAccountTokenFile :: FilePath
defaultVaultServiceAccountTokenFile =
  "/var/run/secrets/kubernetes.io/serviceaccount/token"

resolveGatewaySecretRef
  :: DaemonConfigDhall
  -> SecretRef
  -> IO (Either SecretRefError Text)
resolveGatewaySecretRef dto ref =
  case vault dto of
    Nothing -> resolveSecretRef ProductionMode ref
    Just vaultAuth -> do
      let tokenPath =
            Text.unpack
              ( fromMaybe
                  (Text.pack defaultVaultServiceAccountTokenFile)
                  (service_account_token_file vaultAuth)
              )
      jwtResult <- readServiceAccountToken tokenPath
      case jwtResult of
        Left err -> pure (Left err)
        Right jwt -> do
          loginResult <-
            vaultKubernetesLogin
              (VaultAddress (address vaultAuth))
              (auth_path vaultAuth)
              (role vaultAuth)
              jwt
          case loginResult of
            Left err ->
              pure
                ( Left
                    ( SecretRefVaultReadFailed
                        ("Vault Kubernetes auth login failed: " ++ renderHttpError err)
                    )
                )
            Right token ->
              resolveSecretRefFromVault
                ProductionMode
                (VaultAddress (address vaultAuth))
                token
                ref

readServiceAccountToken :: FilePath -> IO (Either SecretRefError Text)
readServiceAccountToken path = do
  result <- try (TextIO.readFile path) :: IO (Either SomeException Text)
  pure $ case result of
    Left ex ->
      Left
        ( SecretRefVaultReadFailed
            ( "failed to read Kubernetes service-account token `"
                ++ path
                ++ "`: "
                ++ displayException ex
            )
        )
    Right rawToken ->
      let token = Text.strip rawToken
       in if Text.null token
            then
              Left
                ( SecretRefVaultReadFailed
                    ("Kubernetes service-account token `" ++ path ++ "` is empty")
                )
            else Right token

-- | Dhall-friendly DTO for the gateway Orders file (Sprint 2.22).
--
-- The schema mirrors the existing JSON Orders shape used by
-- @charts/gateway/templates/configmap-orders.yaml@ and decoded today by
-- @Prodbox.Gateway.Types.parseOrders@. The Dhall path is the new sole-source
-- on the supported chart surface; the JSON path is retained as a
-- backwards-compatible fallback in 'loadOrders' until the chart-rewrite
-- transition completes.
data OrdersDhall = OrdersDhall
  { version_utc :: Natural
  , nodes :: [PeerEndpointDhall]
  , gateway_rule :: GatewayRuleDhall
  }
  deriving (Eq, Show, Generic, FromDhall)

data PeerEndpointDhall = PeerEndpointDhall
  { node_id :: Text
  , stable_dns_name :: Text
  , rest_host :: Text
  , rest_port :: Natural
  , socket_host :: Text
  , socket_port :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall)

data GatewayRuleDhall = GatewayRuleDhall
  { ranked_nodes :: [Text]
  , heartbeat_timeout_seconds :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall)

-- | Convert an 'OrdersDhall' DTO to the runtime 'Orders' value. Mirrors the
-- invariants enforced by 'Prodbox.Gateway.Types.parseOrders': @version_utc@
-- non-negative, unique node_id values, and @ranked_nodes@ being a subset of
-- @nodes.node_id@.
toOrders :: OrdersDhall -> Either String Orders
toOrders dto = do
  let nodeList = map toPeer (nodes dto)
      nodeIds = map peerNodeId nodeList
  if length (nub nodeIds) /= length nodeIds
    then Left "orders.nodes node_id values must be unique"
    else Right ()
  let ruleDto = gateway_rule dto
      rankedNodeIds = map Text.unpack (ranked_nodes ruleDto)
  if all (`elem` nodeIds) rankedNodeIds
    then Right ()
    else Left "gateway_rule.ranked_nodes must be a subset of orders.nodes.node_id"
  pure
    Orders
      { ordersVersionUtc = fromIntegral (version_utc dto)
      , ordersNodes = nodeList
      , ordersGatewayRule =
          GatewayRule
            { rankedNodes = rankedNodeIds
            , heartbeatTimeoutSeconds = fromIntegral (heartbeat_timeout_seconds ruleDto)
            }
      }

toPeer :: PeerEndpointDhall -> PeerEndpoint
toPeer
  PeerEndpointDhall
    { node_id = nodeIdText
    , stable_dns_name = stableDnsNameText
    , rest_host = restHostText
    , rest_port = restPortNat
    , socket_host = socketHostText
    , socket_port = socketPortNat
    } =
    PeerEndpoint
      { peerNodeId = Text.unpack nodeIdText
      , peerStableDnsName = Text.unpack stableDnsNameText
      , peerRestHost = Text.unpack restHostText
      , peerRestPort = fromIntegral restPortNat
      , peerSocketHost = Text.unpack socketHostText
      , peerSocketPort = fromIntegral socketPortNat
      }

decodeOrdersDhall :: Text -> IO (Either String Orders)
decodeOrdersDhall src = do
  result <- try (input auto src) :: IO (Either SomeException OrdersDhall)
  pure $ case result of
    Left e -> Left ("failed to decode gateway orders Dhall: " ++ displayException e)
    Right dto -> toOrders dto

-- | Canonical entrypoint for loading the gateway Orders file. Sprint 2.22
-- closure: the JSON dispatch arm is removed; the daemon decodes Dhall Orders
-- exclusively via `Dhall.inputFile auto`.
loadOrders :: FilePath -> IO (Either String Orders)
loadOrders path = do
  result <- try (inputFile auto path) :: IO (Either SomeException OrdersDhall)
  case result of
    Left e ->
      pure
        ( Left
            ( "failed to decode gateway orders Dhall `"
                ++ path
                ++ "`: "
                ++ displayException e
            )
        )
    Right dto -> pure (toOrders dto)
