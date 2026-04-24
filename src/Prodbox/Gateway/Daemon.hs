{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Gateway.Daemon (
    runGatewayDaemon,
)
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, waitAnyCancel)
import Control.Concurrent.STM (
    TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVarIO,
 )
import Control.Exception (SomeException, try)
import Control.Monad (forever, void, when)
import Crypto.Hash.SHA256 (hash, hmac)
import Data.Aeson (
    Value (..),
    encode,
    object,
    (.=),
 )
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (intToDigit)
import Data.Map.Strict qualified as Map
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (formatShow, iso8601Format)
import Data.Word (Word8)
import Network.Socket (
    Family (AF_INET),
    SockAddr (..),
    Socket,
    SocketOption (ReuseAddr),
    SocketType (Stream),
    accept,
    bind,
    gracefulClose,
    listen,
    setSocketOption,
    socket,
    tupleToHostAddress,
    withSocketsDo,
 )
import Network.Socket.ByteString (sendAll)
import Prodbox.Gateway.Types (
    CommitLog (..),
    DaemonConfig (..),
    DnsWriteGate (..),
    GatewayRule (..),
    Orders (..),
    PeerEndpoint (..),
    SignedEvent (..),
    appendIfNew,
    emptyCommitLog,
    parseOrders,
 )
import Prodbox.Result (Result (..))
import Prodbox.Subprocess (
    CommandSpec (..),
    ProcessOutput (..),
    captureCommand,
 )
import System.Exit (ExitCode (..))
import System.IO (hPutStrLn, stderr)

data DaemonState = DaemonState
    { stateCommitLog :: CommitLog
    , stateLastHeartbeatTimes :: Map.Map String UTCTime
    , stateGatewayOwner :: Maybe String
    , stateLastPublicIp :: Maybe String
    , stateLastDnsWriteIp :: Maybe String
    , stateLastDnsWriteTime :: Maybe UTCTime
    , stateMeshPeers :: [String]
    }

initialState :: DaemonState
initialState =
    DaemonState
        { stateCommitLog = emptyCommitLog
        , stateLastHeartbeatTimes = Map.empty
        , stateGatewayOwner = Nothing
        , stateLastPublicIp = Nothing
        , stateLastDnsWriteIp = Nothing
        , stateLastDnsWriteTime = Nothing
        , stateMeshPeers = []
        }

runGatewayDaemon :: DaemonConfig -> IO ExitCode
runGatewayDaemon config = withSocketsDo $ do
    hPutStrLn stderr ("Gateway daemon starting: node_id=" ++ daemonNodeId config)
    ordersText <- readFile (daemonOrdersFile config)
    case parseOrders ordersText of
        Left err -> do
            hPutStrLn stderr ("Failed to parse orders: " ++ err)
            pure (ExitFailure 1)
        Right orders -> do
            stateVar <- newTVarIO initialState
            let eventKeys = Map.fromList (daemonEventKeys config)

            hPutStrLn stderr ("Orders loaded: " ++ show (length (ordersNodes orders)) ++ " nodes")

            heartbeatThread <- async (heartbeatLoop config orders stateVar eventKeys)
            gatewayThread <- async (gatewayLoop config orders stateVar)
            dnsWriteThread <- async (dnsWriteLoop config orders stateVar)
            restThread <- async (restServerLoop config orders stateVar)

            let allThreads = [heartbeatThread, gatewayThread, dnsWriteThread, restThread]

            result <- try (void (waitAnyCancel allThreads)) :: IO (Either SomeException ())
            case result of
                Left exc -> do
                    hPutStrLn stderr ("Gateway daemon error: " ++ show exc)
                    mapM_ cancel allThreads
                    pure (ExitFailure 1)
                Right () -> do
                    hPutStrLn stderr "Gateway daemon stopped"
                    pure ExitSuccess

heartbeatLoop :: DaemonConfig -> Orders -> TVar DaemonState -> Map.Map String String -> IO ()
heartbeatLoop config _orders stateVar eventKeys = forever $ do
    now <- getCurrentTime
    let nodeId = daemonNodeId config
        heartbeatPayload =
            object
                [ "node_id" .= nodeId
                , "timestamp" .= formatUtcIso now
                ]
    case Map.lookup nodeId eventKeys of
        Nothing -> hPutStrLn stderr ("No event key for local node " ++ nodeId)
        Just key -> do
            let event = createSignedEvent nodeId "heartbeat" heartbeatPayload key now
            atomically $ modifyTVar' stateVar $ \state ->
                state
                    { stateCommitLog = appendIfNew (stateCommitLog state) event
                    , stateLastHeartbeatTimes =
                        Map.insert nodeId now (stateLastHeartbeatTimes state)
                    }
    threadDelay (round (daemonHeartbeatInterval config * 1000000))

gatewayLoop :: DaemonConfig -> Orders -> TVar DaemonState -> IO ()
gatewayLoop config _orders stateVar = forever $ do
    now <- getCurrentTime
    state <- readTVarIO stateVar
    let rule = ordersGatewayRule _orders
        timeout = fromIntegral (heartbeatTimeoutSeconds rule)
        activeNodes =
            [ nodeId
            | nodeId <- rankedNodes rule
            , case Map.lookup nodeId (stateLastHeartbeatTimes state) of
                Just lastHeartbeat -> diffUTCTime now lastHeartbeat < timeout
                Nothing -> nodeId == daemonNodeId config
            ]
        owner = case activeNodes of
            (first : _) -> Just first
            [] -> Nothing
    atomically $ modifyTVar' stateVar $ \s -> s{stateGatewayOwner = owner}
    threadDelay 1000000

dnsWriteLoop :: DaemonConfig -> Orders -> TVar DaemonState -> IO ()
dnsWriteLoop config _orders stateVar = forever $ do
    state <- readTVarIO stateVar
    let nodeId = daemonNodeId config
        isOwner = stateGatewayOwner state == Just nodeId
    when isOwner $ do
        case daemonDnsWriteGate config of
            Nothing -> pure ()
            Just gate -> do
                publicIpResult <- fetchPublicIp
                case publicIpResult of
                    Left err -> hPutStrLn stderr ("DNS write skipped: " ++ err)
                    Right currentIp -> do
                        let shouldWrite = case stateLastDnsWriteIp state of
                                Nothing -> True
                                Just lastIp -> lastIp /= currentIp
                        when shouldWrite $ do
                            writeResult <- writeDnsRecord gate currentIp
                            case writeResult of
                                Left err -> hPutStrLn stderr ("DNS write failed: " ++ err)
                                Right () -> do
                                    now <- getCurrentTime
                                    atomically $ modifyTVar' stateVar $ \s ->
                                        s
                                            { stateLastPublicIp = Just currentIp
                                            , stateLastDnsWriteIp = Just currentIp
                                            , stateLastDnsWriteTime = Just now
                                            }
                                    hPutStrLn stderr ("DNS write: " ++ dnsWriteGateFqdn gate ++ " -> " ++ currentIp)
    threadDelay (round (daemonSyncInterval config * 1000000))

restServerLoop :: DaemonConfig -> Orders -> TVar DaemonState -> IO ()
restServerLoop config orders stateVar = do
    let localPeer = case filter (\n -> peerNodeId n == daemonNodeId config) (ordersNodes orders) of
            [peer] -> peer
            _ -> error ("Local node " ++ daemonNodeId config ++ " not found in orders")
        port = peerRestPort localPeer
    sock <- socket AF_INET Stream 0
    setSocketOption sock ReuseAddr 1
    bind sock (SockAddrInet (fromIntegral port) (tupleToHostAddress (0, 0, 0, 0)))
    listen sock 16
    hPutStrLn stderr ("REST server listening on port " ++ show port)
    forever $ do
        (clientSock, _) <- accept sock
        void $ async $ handleRestClient clientSock config stateVar

handleRestClient :: Socket -> DaemonConfig -> TVar DaemonState -> IO ()
handleRestClient sock config stateVar = do
    _ <- try handleRequest :: IO (Either SomeException ())
    gracefulClose sock 1000
  where
    handleRequest = do
        state <- readTVarIO stateVar
        let responseBody = renderStateJson config state
            responseHeaders =
                "HTTP/1.1 200 OK\r\n"
                    ++ "Content-Type: application/json\r\n"
                    ++ "Content-Length: "
                    ++ show (BL.length responseBody)
                    ++ "\r\n"
                    ++ "Connection: close\r\n"
                    ++ "\r\n"
        sendAll sock (BS8.pack responseHeaders)
        sendAll sock (BL.toStrict responseBody)

renderStateJson :: DaemonConfig -> DaemonState -> BL.ByteString
renderStateJson config state =
    encode $
        object
            [ "node_id" .= daemonNodeId config
            , "gateway_owner" .= stateGatewayOwner state
            , "has_active_claim" .= (stateGatewayOwner state == Just (daemonNodeId config))
            , "mesh_peers" .= stateMeshPeers state
            , "event_count" .= length (commitLogEvents (stateCommitLog state))
            , "last_public_ip_observed" .= stateLastPublicIp state
            , "last_dns_write_ip" .= stateLastDnsWriteIp state
            , "last_dns_write_at_utc" .= fmap formatUtcIso (stateLastDnsWriteTime state)
            , "dns_write_gate" .= fmap renderDnsWriteGate (daemonDnsWriteGate config)
            , "heartbeat_age_seconds" .= renderHeartbeatAges state
            ]

renderDnsWriteGate :: DnsWriteGate -> Value
renderDnsWriteGate gate =
    object
        [ "zone_id" .= dnsWriteGateZoneId gate
        , "fqdn" .= dnsWriteGateFqdn gate
        , "ttl" .= dnsWriteGateTtl gate
        , "aws_region" .= dnsWriteGateAwsRegion gate
        ]

renderHeartbeatAges :: DaemonState -> Value
renderHeartbeatAges _state = object []

fetchPublicIp :: IO (Either String String)
fetchPublicIp = do
    result <-
        captureCommand
            CommandSpec
                { commandPath = "curl"
                , commandArguments = ["-s", "--max-time", "10", "https://api.ipify.org"]
                , commandEnvironment = Nothing
                , commandWorkingDirectory = Nothing
                }
    case result of
        Failure err -> pure (Left ("failed to fetch public IP: " ++ err))
        Success output ->
            case processExitCode output of
                ExitSuccess ->
                    let ip = trim (processStdout output)
                     in if length (filter (== '.') ip) == 3
                            then pure (Right ip)
                            else pure (Left ("unexpected public IP: " ++ ip))
                ExitFailure _ -> pure (Left ("curl failed: " ++ trim (processStderr output)))

writeDnsRecord :: DnsWriteGate -> String -> IO (Either String ())
writeDnsRecord gate ip = do
    let changeBatch =
            BL8.unpack $
                encode $
                    object
                        [ "Changes"
                            .= [ object
                                    [ "Action" .= ("UPSERT" :: String)
                                    , "ResourceRecordSet"
                                        .= object
                                            [ "Name" .= dnsWriteGateFqdn gate
                                            , "Type" .= ("A" :: String)
                                            , "TTL" .= dnsWriteGateTtl gate
                                            , "ResourceRecords" .= [object ["Value" .= ip]]
                                            ]
                                    ]
                               ]
                        ]
    result <-
        captureCommand
            CommandSpec
                { commandPath = "aws"
                , commandArguments =
                    [ "route53"
                    , "change-resource-record-sets"
                    , "--hosted-zone-id"
                    , dnsWriteGateZoneId gate
                    , "--change-batch"
                    , changeBatch
                    , "--region"
                    , dnsWriteGateAwsRegion gate
                    ]
                , commandEnvironment = Nothing
                , commandWorkingDirectory = Nothing
                }
    case result of
        Failure err -> pure (Left ("aws cli failed: " ++ err))
        Success output ->
            case processExitCode output of
                ExitSuccess -> pure (Right ())
                ExitFailure _ -> pure (Left ("route53 update failed: " ++ trim (processStderr output)))

createSignedEvent :: String -> String -> Value -> String -> UTCTime -> SignedEvent
createSignedEvent nodeId evtType payload key now =
    let payloadJsonStr = BL8.unpack (encode payload)
        tsStr = formatUtcIso now
        unsignedPayload =
            object
                [ "emitter_node_id" .= nodeId
                , "event_type" .= evtType
                , "payload_json" .= payloadJsonStr
                , "timestamp_utc" .= tsStr
                ]
        unsignedStr = BL8.unpack (encode unsignedPayload)
        eventHashBytes = hash (BS8.pack unsignedStr)
        eventHashHex = bytesToHex eventHashBytes
        signatureBytes = hmac (BS8.pack key) (BS8.pack eventHashHex)
        signatureHexStr = bytesToHex signatureBytes
     in SignedEvent
            { eventHash = eventHashHex
            , emitterNodeId = nodeId
            , timestampUtc = tsStr
            , eventType = evtType
            , payloadJson = payloadJsonStr
            , signatureHex = signatureHexStr
            }

formatUtcIso :: UTCTime -> String
formatUtcIso = formatShow iso8601Format

bytesToHex :: BS.ByteString -> String
bytesToHex = concatMap byteToHex . BS.unpack
  where
    byteToHex :: Word8 -> String
    byteToHex b = [intToDigit (fromIntegral (b `div` 16)), intToDigit (fromIntegral (b `mod` 16))]

trim :: String -> String
trim = reverse . dropWhile (\c -> c == '\n' || c == '\r' || c == ' ') . reverse
