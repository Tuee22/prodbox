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
  , DaemonConfigDhall (..)
  , DaemonBootDhall (..)
  , DaemonLiveDhall (..)
  , DnsWriteGateDhall (..)
  , EventKeyDhall (..)
  , AwsCredsDhall (..)
  , MinioCredsDhall (..)
  , toDaemonConfig
  , awsCredsFromConfig
  , minioCredsFromConfig
  , loadOrders
  , decodeOrdersDhall
  , OrdersDhall (..)
  , PeerEndpointDhall (..)
  , GatewayRuleDhall (..)
  , toOrders
  )
where

import Control.Exception (SomeException, displayException, try)
import Data.Char (toLower)
import Data.List (isSuffixOf, nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (FromDhall, auto, input, inputFile)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Gateway.Types
  ( DaemonConfig (..)
  , DnsWriteGate (..)
  , GatewayAwsCreds (..)
  , GatewayMinioCreds (..)
  , GatewayRule (..)
  , Orders (..)
  , PeerEndpoint (..)
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
  , boot :: DaemonBootDhall
  , live :: DaemonLiveDhall
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
  }
  deriving (Eq, Show, Generic, FromDhall)

-- | Sprint 2.22: AWS credentials Dhall fragment imported by the daemon's
-- config.dhall (typically from a Secret-mounted file at
-- @/etc/gateway/secrets/aws.dhall@ per @config_doctrine.md §6@).
data AwsCredsDhall = AwsCredsDhall
  { access_key_id :: Text
  , secret_access_key :: Text
  , session_token :: Maybe Text
  , region :: Text
  }
  deriving (Eq, Show, Generic, FromDhall)

-- | Sprint 2.22: MinIO credentials Dhall fragment imported by the daemon's
-- config.dhall (typically from a Secret-mounted file at
-- @/etc/gateway/secrets/minio.dhall@ per @config_doctrine.md §6@).
data MinioCredsDhall = MinioCredsDhall
  { minio_access_key :: Text
  , minio_secret_key :: Text
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
  , value :: Text
  }
  deriving (Eq, Show, Generic, FromDhall)

-- | Supported schemaVersion stamp on the Dhall surface. Kept in sync with
-- 'Prodbox.Gateway.Types.supportedDaemonConfigSchemaVersion'.
supportedDhallSchemaVersion :: Natural
supportedDhallSchemaVersion = 1

-- | Convert the Dhall DTO to the runtime 'DaemonConfig'. Fails fast on
-- schema-version mismatches and on the obvious validation invariants the
-- legacy JSON parser already enforces (positive intervals, non-negative drain
-- deadline, no inline AWS credentials on the DNS gate).
toDaemonConfig :: DaemonConfigDhall -> Either String DaemonConfig
toDaemonConfig
  DaemonConfigDhall
    { schemaVersion = sv
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
    } = do
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
    pure
      DaemonConfig
        { daemonNodeId = Text.unpack nodeIdText
        , daemonCertFile = Text.unpack certFileText
        , daemonKeyFile = Text.unpack keyFileText
        , daemonCaFile = Text.unpack caFileText
        , daemonOrdersFile = Text.unpack ordersFileText
        , daemonEventKeys =
            [ (Text.unpack (name k), Text.unpack (value k))
            | k <- eventKeysList
            ]
        , daemonHeartbeatInterval = hb
        , daemonReconnectInterval = rc
        , daemonSyncInterval = sy
        , daemonMaxClockSkewSeconds = ms
        , daemonDrainDeadlineSeconds = fromIntegral <$> ddl
        , daemonConfigLogLevel = Text.unpack <$> ll
        , daemonDnsWriteGate = toDnsWriteGate <$> maybeDnsGate
        , daemonAwsCreds = toGatewayAwsCreds <$> maybeAwsCreds
        , daemonMinioCreds = toGatewayMinioCreds <$> maybeMinioCreds
        }

toGatewayAwsCreds :: AwsCredsDhall -> GatewayAwsCreds
toGatewayAwsCreds
  AwsCredsDhall
    { access_key_id = ak
    , secret_access_key = sk
    , session_token = st
    , region = rg
    } =
    GatewayAwsCreds
      { gatewayAwsAccessKeyId = Text.unpack ak
      , gatewayAwsSecretAccessKey = Text.unpack sk
      , gatewayAwsSessionToken = Text.unpack <$> st
      , gatewayAwsRegion = Text.unpack rg
      }

toGatewayMinioCreds :: MinioCredsDhall -> GatewayMinioCreds
toGatewayMinioCreds
  MinioCredsDhall
    { minio_access_key = ak
    , minio_secret_key = sk
    } =
    GatewayMinioCreds
      { gatewayMinioAccessKey = Text.unpack ak
      , gatewayMinioSecretKey = Text.unpack sk
      }

-- | Extract AWS credentials directly from a 'DaemonConfigDhall' DTO. Exposed
-- so callers that need credentials before 'toDaemonConfig' validation can
-- still read them.
awsCredsFromConfig :: DaemonConfigDhall -> Maybe GatewayAwsCreds
awsCredsFromConfig dto = toGatewayAwsCreds <$> aws_creds (boot dto)

-- | Extract MinIO credentials directly from a 'DaemonConfigDhall' DTO.
minioCredsFromConfig :: DaemonConfigDhall -> Maybe GatewayMinioCreds
minioCredsFromConfig dto = toGatewayMinioCreds <$> minio_creds (boot dto)

toDnsWriteGate :: DnsWriteGateDhall -> DnsWriteGate
toDnsWriteGate g =
  DnsWriteGate
    { dnsWriteGateZoneId = Text.unpack (zone_id g)
    , dnsWriteGateFqdn = Text.unpack (fqdn g)
    , dnsWriteGateTtl = fromIntegral (ttl g)
    , dnsWriteGateAwsRegion = Text.unpack (aws_region g)
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
  result <- try (input auto src) :: IO (Either SomeException DaemonConfigDhall)
  pure $ case result of
    Left e -> Left ("failed to decode gateway daemon Dhall config: " ++ displayException e)
    Right dto -> toDaemonConfig dto

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
    Right dto -> pure (toDaemonConfig dto)

hasSuffix :: String -> String -> Bool
hasSuffix suffix str = map toLower suffix `isSuffixOf` map toLower str

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
