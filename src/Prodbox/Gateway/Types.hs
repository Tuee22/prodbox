{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Gateway.Types (
    PeerEndpoint (..),
    GatewayRule (..),
    Orders (..),
    SignedEvent (..),
    CommitLog (..),
    DaemonConfig (..),
    DnsWriteGate (..),
    ChannelName (..),
    ConnectionKey (..),
    emptyCommitLog,
    appendIfNew,
    sortedEvents,
    latestTimestamp,
    parseDaemonConfig,
    parseOrders,
    peerDialRestHost,
    peerRestUrl,
    peerDialSocketHost,
    validateDaemonTimingAgainstOrders,
)
where

import Data.Aeson (
    Value (..),
    eitherDecode,
 )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (nub, sortBy)
import Data.Ord (comparing)
import Data.Text qualified as Text
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
    , daemonDnsWriteGate :: Maybe DnsWriteGate
    }
    deriving (Eq, Show)

data ConnectionKey = ConnectionKey
    { connectionKeyPeerNodeId :: String
    , connectionKeyChannel :: ChannelName
    }
    deriving (Eq, Ord, Show)

parseDaemonConfig :: String -> Either String DaemonConfig
parseDaemonConfig jsonText =
    case eitherDecode (BL8.pack jsonText) of
        Left err -> Left ("failed to parse daemon config: " ++ err)
        Right (Object obj) -> do
            nodeId <- requireStr obj "node_id"
            certFile <- requireStr obj "cert_file"
            keyFile <- requireStr obj "key_file"
            caFile <- requireStr obj "ca_file"
            ordersFile <- requireStr obj "orders_file"
            eventKeys <- parseEventKeys obj
            let heartbeat = readOptionalFloat obj "heartbeat_interval_seconds" 1.0
                reconnect = readOptionalFloat obj "reconnect_interval_seconds" 1.0
                sync = readOptionalFloat obj "sync_interval_seconds" 5.0
            dnsGate <- parseDnsWriteGate obj
            validateIntervals heartbeat reconnect sync
            Right
                DaemonConfig
                    { daemonNodeId = nodeId
                    , daemonCertFile = certFile
                    , daemonKeyFile = keyFile
                    , daemonCaFile = caFile
                    , daemonOrdersFile = ordersFile
                    , daemonEventKeys = eventKeys
                    , daemonHeartbeatInterval = heartbeat
                    , daemonReconnectInterval = reconnect
                    , daemonSyncInterval = sync
                    , daemonDnsWriteGate = dnsGate
                    }
        Right _ -> Left "daemon config must be a JSON object"

parseOrders :: String -> Either String Orders
parseOrders jsonText =
    case eitherDecode (BL8.pack jsonText) of
        Left err -> Left ("failed to parse orders: " ++ err)
        Right (Object obj) -> do
            versionUtc <- requireInt obj "version_utc"
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

readOptionalFloat :: KeyMap.KeyMap Value -> String -> Double -> Double
readOptionalFloat obj key defaultVal =
    case KeyMap.lookup (Key.fromString key) obj of
        Just (Number n) -> realToFrac n
        _ -> defaultVal

parseEventKeys :: KeyMap.KeyMap Value -> Either String [(String, String)]
parseEventKeys obj =
    case KeyMap.lookup (Key.fromString "event_keys") obj of
        Just (Object keysObj) ->
            Right
                [ (Text.unpack (Key.toText k), Text.unpack v)
                | (k, String v) <- KeyMap.toList keysObj
                ]
        _ -> Left "event_keys must be a JSON object"

parseDnsWriteGate :: KeyMap.KeyMap Value -> Either String (Maybe DnsWriteGate)
parseDnsWriteGate obj =
    case KeyMap.lookup (Key.fromString "dns_write_gate") obj of
        Nothing -> Right Nothing
        Just Null -> Right Nothing
        Just (Object gateObj) -> do
            zoneId <- requireStr gateObj "zone_id"
            fqdn <- requireStr gateObj "fqdn"
            let ttl = readOptionalFloat gateObj "ttl" 300
            awsRegion <- requireStr gateObj "aws_region"
            rejectForbiddenCredKeys gateObj
            Right
                ( Just
                    DnsWriteGate
                        { dnsWriteGateZoneId = zoneId
                        , dnsWriteGateFqdn = fqdn
                        , dnsWriteGateTtl = round ttl
                        , dnsWriteGateAwsRegion = awsRegion
                        }
                )
        _ -> Left "dns_write_gate must be a JSON object or null"

rejectForbiddenCredKeys :: KeyMap.KeyMap Value -> Either String ()
rejectForbiddenCredKeys obj =
    let forbidden = ["aws_access_key_id", "aws_secret_access_key", "aws_session_token"]
        present =
            [ key
            | key <- forbidden
            , case KeyMap.lookup (Key.fromString key) obj of
                Just (String text) -> not (Text.null text)
                _ -> False
            ]
     in if null present
            then Right ()
            else Left ("dns_write_gate must not contain explicit AWS credentials: " ++ show present)

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
                    mapM
                        ( \v -> case v of
                            String text -> Right (Text.unpack text)
                            _ -> Left "ranked_nodes must contain strings"
                        )
                        (Vector.toList arr)
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

validateIntervals :: Double -> Double -> Double -> Either String ()
validateIntervals heartbeat reconnect sync
    | heartbeat < 0.1 = Left "heartbeat_interval_seconds must be >= 0.1"
    | reconnect < 0.1 = Left "reconnect_interval_seconds must be >= 0.1"
    | sync < 0.1 = Left "sync_interval_seconds must be >= 0.1"
    | otherwise = Right ()

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
