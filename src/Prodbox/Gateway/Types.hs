{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Gateway.Types
  ( PeerEndpoint (..)
  , GatewayRule (..)
  , Orders (..)
  , SignedEvent (..)
  , CommitLog (..)
  , DaemonConfig (..)
  , DnsWriteGate (..)
  , GatewayAwsCreds (..)
  , GatewayMinioCreds (..)
  , GatewayVaultAuth (..)
  , ChannelName (..)
  , ConnectionKey (..)
  , Disposition (..)
  , PeerHealth (..)
  , eventTypeHeartbeat
  , eventTypeClaim
  , eventTypeYield
  , defaultMaxClockSkewSeconds
  , defaultDrainDeadlineSeconds
  , supportedDaemonConfigSchemaVersion
  , emptyCommitLog
  , appendIfNew
  , sortedEvents
  , latestTimestamp
  , parseOrders
  , parseEvent
  , encodeEvent
  , peerDialRestHost
  , peerRestUrl
  , peerDialSocketHost
  , peerSocketUrl
  , peerEventsUrl
  , eventTimestampUtc
  , nodeDisposition
  , canWriteDns
  , parseIso8601Utc
  , formatUtcIso
  , computeMaxObservedSkew
  , validateDaemonTimingAgainstOrders
  )
where

import Data.Aeson
  ( Value (..)
  , eitherDecode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (nub, sortBy)
import Data.Ord (comparing)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime)
import Data.Time.Format.ISO8601 (formatShow, iso8601Format, iso8601ParseM)
import Data.Vector qualified as Vector

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
  deriving (Eq, Show)

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

peerEventsUrl :: PeerEndpoint -> String
peerEventsUrl peer = peerSocketUrl peer ++ "/v1/peer/events"

data GatewayRule = GatewayRule
  { rankedNodes :: [String]
  , heartbeatTimeoutSeconds :: Int
  }
  deriving (Eq, Show)

data Orders = Orders
  { ordersVersionUtc :: Int
  , ordersNodes :: [PeerEndpoint]
  , ordersGatewayRule :: GatewayRule
  }
  deriving (Eq, Show)

data SignedEvent = SignedEvent
  { eventHash :: String
  , emitterNodeId :: String
  , timestampUtc :: String
  , eventType :: String
  , payloadJson :: String
  , signatureHex :: String
  }
  deriving (Eq, Show)

data CommitLog = CommitLog
  { commitLogEvents :: [SignedEvent]
  }
  deriving (Eq, Show)

emptyCommitLog :: CommitLog
emptyCommitLog = CommitLog []

appendIfNew :: CommitLog -> SignedEvent -> CommitLog
appendIfNew commitLog event =
  if any (\e -> eventHash e == eventHash event) (commitLogEvents commitLog)
    then commitLog
    else CommitLog (commitLogEvents commitLog ++ [event])

sortedEvents :: CommitLog -> [SignedEvent]
sortedEvents commitLog =
  sortBy (comparing (\e -> (timestampUtc e, eventHash e))) (commitLogEvents commitLog)

latestTimestamp :: CommitLog -> Maybe String
latestTimestamp commitLog =
  case commitLogEvents commitLog of
    [] -> Nothing
    events -> Just (maximum (map timestampUtc events))

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
--     of the most recent signed event this daemon accepted FROM the peer. It
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

eventTypeHeartbeat :: String
eventTypeHeartbeat = "heartbeat"

eventTypeClaim :: String
eventTypeClaim = "claim"

eventTypeYield :: String
eventTypeYield = "yield"

defaultMaxClockSkewSeconds :: Double
defaultMaxClockSkewSeconds = 10.0

defaultDrainDeadlineSeconds :: Int
defaultDrainDeadlineSeconds = 30

supportedDaemonConfigSchemaVersion :: Int
supportedDaemonConfigSchemaVersion = 1

-- Sprint 2.20 closure (May 24, 2026): the JSON `parseDaemonConfig` parser
-- and its structured-vs-flat branches were removed. The supported decoder is
-- `Prodbox.Gateway.Settings.loadDaemonConfig` built on
-- `Dhall.inputFile auto` per
-- [config_doctrine.md §4](../../documents/engineering/config_doctrine.md#4-decoding).

parseOrders :: String -> Either String Orders
parseOrders jsonText =
  case eitherDecode (BL8.pack jsonText) of
    Left err -> Left ("failed to parse orders: " ++ err)
    Right (Object obj) -> do
      versionUtc <- requireInt obj "version_utc"
      if versionUtc < 0
        then Left "version_utc must be non-negative"
        else pure ()
      nodes <- parseNodeList obj
      rule <- parseGatewayRule obj
      let nodeIds = map peerNodeId nodes
      if length (nub nodeIds) /= length nodeIds
        then Left "orders.nodes node_id values must be unique"
        else
          if all (`elem` nodeIds) (rankedNodes rule)
            then
              Right
                Orders
                  { ordersVersionUtc = versionUtc
                  , ordersNodes = nodes
                  , ordersGatewayRule = rule
                  }
            else Left "gateway_rule.ranked_nodes must be a subset of orders.nodes.node_id"
    Right _ -> Left "orders must be a JSON object"

parseEvent :: Value -> Either String SignedEvent
parseEvent value =
  case value of
    Object obj -> do
      evHash <- requireStr obj "event_hash"
      emitter <- requireStr obj "emitter_node_id"
      ts <- requireStr obj "timestamp_utc"
      evType <- requireStr obj "event_type"
      payload <- requireStr obj "payload_json"
      sig <- requireStr obj "signature_hex"
      Right
        SignedEvent
          { eventHash = evHash
          , emitterNodeId = emitter
          , timestampUtc = ts
          , eventType = evType
          , payloadJson = payload
          , signatureHex = sig
          }
    _ -> Left "event entries must be JSON objects"

encodeEvent :: SignedEvent -> Value
encodeEvent ev =
  object
    [ "event_hash" .= eventHash ev
    , "emitter_node_id" .= emitterNodeId ev
    , "timestamp_utc" .= timestampUtc ev
    , "event_type" .= eventType ev
    , "payload_json" .= payloadJson ev
    , "signature_hex" .= signatureHex ev
    ]

eventTimestampUtc :: SignedEvent -> Maybe UTCTime
eventTimestampUtc ev = parseIso8601Utc (timestampUtc ev)

parseIso8601Utc :: String -> Maybe UTCTime
parseIso8601Utc = iso8601ParseM

formatUtcIso :: UTCTime -> String
formatUtcIso = formatShow iso8601Format

requireStr :: KeyMap.KeyMap Value -> String -> Either String String
requireStr obj key =
  case KeyMap.lookup (Key.fromString key) obj of
    Just (String text) ->
      let str = Text.unpack text
       in if null str then Left (key ++ " is required") else Right str
    _ -> Left (key ++ " is required")

requireInt :: KeyMap.KeyMap Value -> String -> Either String Int
requireInt obj key =
  case KeyMap.lookup (Key.fromString key) obj of
    Just (Number n) -> Right (round n)
    _ -> Left (key ++ " must be an integer")

-- Sprint 2.20 closure: `requireObject`, `readOptionalInt`,
-- `readOptionalString`, `parseEventKeys`, `parseDnsWriteGate`,
-- `rejectForbiddenCredKeys`, and `readOptionalFloat` were JSON-parser
-- helpers for the legacy `parseDaemonConfig` path. The pure-Dhall
-- decoder owns those fields via 'DaemonBootDhall', so the JSON
-- helpers are removed. The surviving JSON helpers (`requireStr`,
-- `requireInt`) remain because 'parseOrders' (still used by tests for
-- the JSON Orders fixture) calls them transitively.

parseNodeList :: KeyMap.KeyMap Value -> Either String [PeerEndpoint]
parseNodeList obj =
  case KeyMap.lookup (Key.fromString "nodes") obj of
    Just (Array arr) -> mapM parseNode (Vector.toList arr)
    _ -> Left "orders.nodes must be a list"

parseNode :: Value -> Either String PeerEndpoint
parseNode (Object obj) = do
  nodeId <- requireStr obj "node_id"
  stableDnsName <- requireStr obj "stable_dns_name"
  restHost <- requireStr obj "rest_host"
  restPort <- requireInt obj "rest_port"
  socketHost <- requireStr obj "socket_host"
  socketPort <- requireInt obj "socket_port"
  Right
    PeerEndpoint
      { peerNodeId = nodeId
      , peerStableDnsName = stableDnsName
      , peerRestHost = restHost
      , peerRestPort = restPort
      , peerSocketHost = socketHost
      , peerSocketPort = socketPort
      }
parseNode _ = Left "orders.nodes entries must be objects"

parseGatewayRule :: KeyMap.KeyMap Value -> Either String GatewayRule
parseGatewayRule obj =
  case KeyMap.lookup (Key.fromString "gateway_rule") obj of
    Just (Object ruleObj) -> do
      rankedNodesList <- case KeyMap.lookup (Key.fromString "ranked_nodes") ruleObj of
        Just (Array arr) ->
          mapM parseRankedNode (Vector.toList arr)
        _ -> Left "gateway_rule.ranked_nodes must be a list"
      if null rankedNodesList
        then Left "gateway_rule.ranked_nodes must be non-empty"
        else pure ()
      timeoutValue <- requireInt ruleObj "heartbeat_timeout_seconds"
      if timeoutValue < 3
        then Left "gateway_rule.heartbeat_timeout_seconds must be >= 3"
        else
          if timeoutValue > 60
            then Left "gateway_rule.heartbeat_timeout_seconds must be <= 60"
            else
              if length (nub rankedNodesList) /= length rankedNodesList
                then Left "gateway_rule.ranked_nodes must be unique"
                else
                  Right
                    GatewayRule
                      { rankedNodes = rankedNodesList
                      , heartbeatTimeoutSeconds = timeoutValue
                      }
    _ -> Left "orders.gateway_rule must be an object"

parseRankedNode :: Value -> Either String String
parseRankedNode value =
  case value of
    String text -> Right (Text.unpack text)
    _ -> Left "ranked_nodes must contain strings"

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

-- | Compute the disposition (last-known claim/yield state) for a node from
-- the commit log.  A node is the owner if its most recent claim/yield event
-- is a claim; yielded if the most recent is a yield; unknown if neither has
-- been observed.
nodeDisposition :: String -> CommitLog -> Disposition
nodeDisposition nodeId commitLog =
  let claimYieldEvents =
        [ ev
        | ev <- sortedEvents commitLog
        , emitterNodeId ev == nodeId
        , eventType ev == eventTypeClaim || eventType ev == eventTypeYield
        ]
   in case claimYieldEvents of
        [] -> DispositionUnknown
        firstEvent : remainingEvents ->
          let lastEv = foldl (\_ event -> event) firstEvent remainingEvents
           in if eventType lastEv == eventTypeClaim
                then DispositionOwner
                else DispositionYielded

-- | The runtime equivalent of the modelled @CanWriteDns@ predicate: the local
-- node may write DNS only when the in-memory election picks the local node
-- AND the local node has an active claim in the commit log AND no later
-- yield from the local node supersedes that claim.
canWriteDns
  :: String
  -- ^ local node id
  -> Maybe String
  -- ^ current owner view (in-memory election)
  -> CommitLog
  -> Bool
canWriteDns localNodeId ownerView log_ =
  ownerView == Just localNodeId
    && nodeDisposition localNodeId log_ == DispositionOwner

-- | Compute the maximum observed inter-node clock skew given a "now"
-- sample and the events recorded in the commit log.  Returns 'Nothing' when
-- no event timestamps were parseable.
computeMaxObservedSkew :: UTCTime -> CommitLog -> Maybe Double
computeMaxObservedSkew now log_ =
  let parsed =
        [ realToFrac (abs (diffUTCTime now ts)) :: Double
        | ev <- commitLogEvents log_
        , Just ts <- [eventTimestampUtc ev]
        ]
   in case parsed of
        [] -> Nothing
        xs -> Just (foldl' max 0 xs)

-- Sprint 2.25 (doctrine D4): the in-process @orders_promoted@ promotion
-- machinery was deleted. @stateOrdersVersionUtc@ never advances at runtime;
-- a newer Orders document is adopted only by restarting the daemon against
-- the new config (config_doctrine.md §8). The former
-- @extractOrdersVersionFromEvent@ recovered an Orders version from an
-- @orders_promoted@ event payload; nothing ever emitted that event class, so
-- it was dead code. The refuse-to-reclaim-while-behind gate
-- (@stateLatestObservedOrdersVersion > stateOrdersVersionUtc@ blocks ownership
-- claims) is kept in 'Prodbox.Gateway.Daemon' and is fed only by the sender's
-- advertised @orders_version_utc@ on each peer push, never by an in-process
-- promotion event.
