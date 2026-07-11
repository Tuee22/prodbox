{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Gateway.Types
  ( PeerEndpoint (..)
  , GatewayRule (..)
  , Orders (..)
  , CborPayload (..)
  , DaemonConfig (..)
  , DnsWriteGate (..)
  , GatewayAwsCreds (..)
  , GatewayMinioCreds (..)
  , GatewayVaultAuth (..)
  , ChannelName (..)
  , ConnectionKey (..)
  , Disposition (..)
  , PeerHealth (..)
  , defaultDrainDeadlineSeconds
  , supportedDaemonConfigSchemaVersion
  , cborPayloadFromJsonValue
  , encodeOrdersCbor
  , decodeOrdersCbor
  , peerDialRestHost
  , peerRestUrl
  , peerDialSocketHost
  , peerSocketUrl
  , validateDaemonTimingAgainstOrders
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as BL
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)
import Prodbox.Cbor (CborPayload (..), cborPayloadFromJsonValue)

data ChannelName = MeshChannel | GatewayChannel
  deriving (Eq, Ord, Show)

data PeerEndpoint = PeerEndpoint
  { peerNodeId :: String
  , peerStableDnsName :: String
  , peerRestHost :: String
  , peerRestPort :: Int
  , peerSocketHost :: String
  , peerSocketPort :: Int
  }
  deriving (Eq, Show, Generic)

instance Serialise PeerEndpoint

peerDialRestHost :: PeerEndpoint -> String
peerDialRestHost peer =
  if peerRestHost peer `elem` ["0.0.0.0", "::"]
    then peerStableDnsName peer
    else peerRestHost peer

peerRestUrl :: PeerEndpoint -> String
peerRestUrl peer =
  "http://" ++ peerDialRestHost peer ++ ":" ++ show (peerRestPort peer)

peerDialSocketHost :: PeerEndpoint -> String
peerDialSocketHost peer =
  if peerSocketHost peer `elem` ["0.0.0.0", "::"]
    then peerStableDnsName peer
    else peerSocketHost peer

peerSocketUrl :: PeerEndpoint -> String
peerSocketUrl peer =
  "http://" ++ peerDialSocketHost peer ++ ":" ++ show (peerSocketPort peer)

data GatewayRule = GatewayRule
  { rankedNodes :: [String]
  , heartbeatTimeoutSeconds :: Int
  }
  deriving (Eq, Show, Generic)

instance Serialise GatewayRule

data Orders = Orders
  { ordersVersionUtc :: Int
  , ordersNodes :: [PeerEndpoint]
  , ordersGatewayRule :: GatewayRule
  }
  deriving (Eq, Show, Generic)

instance Serialise Orders

encodeOrdersCbor :: Orders -> BL.ByteString
encodeOrdersCbor = serialise

decodeOrdersCbor :: BL.ByteString -> Either String Orders
decodeOrdersCbor =
  first (("failed to decode Orders CBOR: " ++) . show) . deserialiseOrFail

data DnsWriteGate = DnsWriteGate
  { dnsWriteGateZoneId :: String
  , dnsWriteGateFqdn :: String
  , dnsWriteGateTtl :: Int
  , dnsWriteGateAwsRegion :: String
  }
  deriving (Eq, Show)

-- | AWS Route 53 credentials for the daemon. Sprint 3.18 resolves these from
-- SecretRef.Vault values in the mounted Dhall config through Vault Kubernetes
-- auth. Optional so daemons that do not own DNS writes can omit the field.
data GatewayAwsCreds = GatewayAwsCreds
  { gatewayAwsAccessKeyId :: String
  , gatewayAwsSecretAccessKey :: String
  , gatewayAwsSessionToken :: Maybe String
  , gatewayAwsRegion :: String
  }
  deriving (Eq, Show)

-- | MinIO IAM credentials for gateway-owned object-store access. Sprint 3.18
-- resolves these from SecretRef.Vault values in the mounted Dhall config.
data GatewayMinioCreds = GatewayMinioCreds
  { gatewayMinioAccessKey :: String
  , gatewayMinioSecretKey :: String
  }
  deriving (Eq, Show)

data GatewayVaultAuth = GatewayVaultAuth
  { gatewayVaultAddress :: String
  , gatewayVaultAuthPath :: String
  , gatewayVaultRole :: String
  , gatewayVaultServiceAccountTokenFile :: FilePath
  }
  deriving (Eq, Show)

data DaemonConfig = DaemonConfig
  { daemonNodeId :: String
  , daemonCertFile :: FilePath
  , daemonKeyFile :: FilePath
  , daemonCaFile :: FilePath
  , daemonOrdersFile :: FilePath
  , daemonEventKeys :: [(String, String)]
  , daemonHeartbeatInterval :: Double
  , daemonReconnectInterval :: Double
  , daemonSyncInterval :: Double
  , daemonMaxClockSkewSeconds :: Double
  , daemonDrainDeadlineSeconds :: Maybe Int
  , daemonConfigLogLevel :: Maybe String
  , daemonVaultAuth :: Maybe GatewayVaultAuth
  , daemonDnsWriteGate :: Maybe DnsWriteGate
  , daemonAwsCreds :: Maybe GatewayAwsCreds
  , daemonMinioCreds :: Maybe GatewayMinioCreds
  , -- \^ In-cluster MinIO Service endpoint URL for gateway-owned
    --   object-store access. Sourced from @boot.minio_endpoint_url@ of the
    --   mounted Dhall config. Canonical home-substrate value:
    --   @http://minio.prodbox.svc.cluster.local:9000@.
    daemonMinioEndpointUrl :: Maybe String
  }
  deriving (Eq, Show)

data ConnectionKey = ConnectionKey
  { connectionKeyPeerNodeId :: String
  , connectionKeyChannel :: ChannelName
  }
  deriving (Eq, Ord, Show)

data Disposition = DispositionOwner | DispositionYielded | DispositionUnknown
  deriving (Eq, Show)

-- | Per-peer health, split into two independent directions so a
-- one-directional partition is observable rather than collapsed into a single
-- transport-health value (Sprint 2.25).
--
--   * 'peerHealthLastInboundEvent' is INBOUND delivery health: the timestamp
--     of the most recent signed assertion this daemon accepted FROM the peer. It
--     is the freshness signal that feeds heartbeat / isolation judgements and
--     is written only when an inbound event is actually accepted.
--   * 'peerHealthOutboundConnected' / 'peerHealthOutboundLastError' are
--     OUTBOUND dial health: whether this daemon's last push TO the peer
--     succeeded, and the last dial error if it failed. They reflect our own
--     delivery attempts and say nothing about whether the peer is producing
--     events.
--
-- A successful outbound push must NOT advance 'peerHealthLastInboundEvent':
-- reaching a peer's socket is not evidence the peer is alive and emitting.
data PeerHealth = PeerHealth
  { peerHealthLastInboundEvent :: Maybe UTCTime
  , peerHealthOutboundConnected :: Bool
  , peerHealthOutboundLastError :: Maybe String
  }
  deriving (Eq, Show)

defaultDrainDeadlineSeconds :: Int
defaultDrainDeadlineSeconds = 30

supportedDaemonConfigSchemaVersion :: Int
supportedDaemonConfigSchemaVersion = 1

-- Sprint 2.20 closure (May 24, 2026): the JSON `parseDaemonConfig` parser
-- and its structured-vs-flat branches were removed. The supported decoder is
-- `Prodbox.Gateway.Settings.loadDaemonConfig` built on
-- `Dhall.inputFile auto` per
-- [config_doctrine.md §4](../../documents/engineering/config_doctrine.md#4-decoding).

-- Sprint 2.20 closure: `validateIntervals`, `validateMaxSkew`, and
-- `validateDrainDeadline` were JSON-parser helpers for the legacy
-- `parseDaemonConfig` path. The pure-Dhall decoder in
-- `Prodbox.Gateway.Settings.toDaemonConfig` now enforces the same
-- invariants inline, so the helpers are removed.

validateDaemonTimingAgainstOrders :: DaemonConfig -> Orders -> Either String ()
validateDaemonTimingAgainstOrders config orders =
  let timeout = fromIntegral (heartbeatTimeoutSeconds (ordersGatewayRule orders)) :: Double
      heartbeat = daemonHeartbeatInterval config
      reconnect = daemonReconnectInterval config
      sync = daemonSyncInterval config
   in if heartbeat > timeout / 2
        then Left "heartbeat_interval_seconds must be <= heartbeat_timeout_seconds / 2"
        else
          if reconnect > timeout
            then Left "reconnect_interval_seconds must be <= heartbeat_timeout_seconds"
            else
              if sync > timeout * 2
                then Left "sync_interval_seconds must be <= heartbeat_timeout_seconds * 2"
                else Right ()
