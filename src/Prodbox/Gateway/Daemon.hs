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
    readTVar,
    readTVarIO,
    writeTVar,
 )
import Control.Exception (SomeException, try)
import Control.Monad (forever, void, when)
import Crypto.Hash.SHA256 (hash, hmac)
import Data.Aeson (
    Value (..),
    encode,
    object,
    toJSON,
    (.=),
 )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (intToDigit, toLower)
import Data.List (isPrefixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
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
    addrAddress,
    bind,
    close,
    connect,
    defaultProtocol,
    getAddrInfo,
    listen,
    setSocketOption,
    socket,
    tupleToHostAddress,
    withSocketsDo,
 )
import Network.Socket.ByteString (recv, sendAll)
import Prodbox.Gateway.Peer (
    PeerEventBatch (..),
    PeerTransportRequest (..),
    PeerTransportResponse (..),
    encodePeerEventBatch,
    handlePeerRequest,
    parsePeerHttpRequest,
    renderPeerHttpResponse,
 )
import Prodbox.Gateway.Types (
    CommitLog (..),
    DaemonConfig (..),
    Disposition (..),
    DnsWriteGate (..),
    GatewayRule (..),
    Orders (..),
    PeerEndpoint (..),
    PeerHealth (..),
    SignedEvent (..),
    appendIfNew,
    canWriteDns,
    emptyCommitLog,
    eventTimestampUtc,
    eventTypeClaim,
    eventTypeHeartbeat,
    eventTypeYield,
    extractOrdersVersionFromEvent,
    nodeDisposition,
    parseOrders,
    peerDialSocketHost,
    validateDaemonTimingAgainstOrders,
 )
import Prodbox.Result (Result (..))
import Prodbox.Subprocess (
    CommandSpec (..),
    ProcessOutput (..),
    captureCommand,
 )
import System.Exit (ExitCode (..))
import System.IO (hPutStrLn, stderr)

{- | In-memory daemon state.  Updated through STM by the loops and HTTP
listeners, and rendered onto @/v1/state@ for operator inspection.
-}
data DaemonState = DaemonState
    { stateCommitLog :: CommitLog
    , stateLastHeartbeatTimes :: Map String UTCTime
    , stateGatewayOwner :: Maybe String
    , statePreviousOwner :: Maybe String
    , stateLastPublicIp :: Maybe String
    , stateLastDnsWriteIp :: Maybe String
    , stateLastDnsWriteTime :: Maybe UTCTime
    , stateMeshPeers :: [String]
    , statePeerHealth :: Map String PeerHealth
    , stateMaxObservedSkewSeconds :: Maybe Double
    , stateOrdersVersionUtc :: Int
    , stateLatestObservedOrdersVersion :: Int
    }

initialState :: Int -> DaemonState
initialState ordersVersion =
    DaemonState
        { stateCommitLog = emptyCommitLog
        , stateLastHeartbeatTimes = Map.empty
        , stateGatewayOwner = Nothing
        , statePreviousOwner = Nothing
        , stateLastPublicIp = Nothing
        , stateLastDnsWriteIp = Nothing
        , stateLastDnsWriteTime = Nothing
        , stateMeshPeers = []
        , statePeerHealth = Map.empty
        , stateMaxObservedSkewSeconds = Nothing
        , stateOrdersVersionUtc = ordersVersion
        , stateLatestObservedOrdersVersion = ordersVersion
        }

runGatewayDaemon :: DaemonConfig -> IO ExitCode
runGatewayDaemon config = withSocketsDo $ do
    hPutStrLn stderr ("Gateway daemon starting: node_id=" ++ daemonNodeId config)
    ordersText <- readFile (daemonOrdersFile config)
    case parseOrders ordersText of
        Left err -> do
            hPutStrLn stderr ("Failed to parse orders: " ++ err)
            pure (ExitFailure 1)
        Right orders ->
            case validateDaemonTimingAgainstOrders config orders of
                Left err -> do
                    hPutStrLn stderr ("Failed to validate gateway timing: " ++ err)
                    pure (ExitFailure 1)
                Right () ->
                    case resolveLocalPeerEndpoint config orders of
                        Left err -> do
                            hPutStrLn stderr ("Failed to resolve local gateway node: " ++ err)
                            pure (ExitFailure 1)
                        Right localPeer -> do
                            now <- getCurrentTime
                            let localNodeId = daemonNodeId config
                                meshPeers =
                                    [ peerNodeId peer
                                    | peer <- ordersNodes orders
                                    , peerNodeId peer /= localNodeId
                                    ]
                                initialDaemonState =
                                    (initialState (ordersVersionUtc orders))
                                        { stateLastHeartbeatTimes = Map.singleton localNodeId now
                                        , stateMeshPeers = meshPeers
                                        , statePeerHealth =
                                            Map.fromList
                                                [(p, PeerHealth Nothing False Nothing) | p <- meshPeers]
                                        }
                            stateVar <- newTVarIO initialDaemonState
                            let eventKeys = Map.fromList (daemonEventKeys config)

                            hPutStrLn stderr ("Orders loaded: " ++ show (length (ordersNodes orders)) ++ " nodes")

                            heartbeatThread <- async (heartbeatLoop config orders stateVar eventKeys)
                            gatewayThread <- async (gatewayLoop config orders stateVar eventKeys)
                            dnsWriteThread <- async (dnsWriteLoop config orders stateVar)
                            restThread <- async (restServerLoop localPeer config stateVar)
                            peerListenerThread <- async (peerListenerLoop localPeer config orders stateVar eventKeys)
                            peerDialerThread <- async (peerDialerLoop config orders stateVar)

                            let allThreads =
                                    [ heartbeatThread
                                    , gatewayThread
                                    , dnsWriteThread
                                    , restThread
                                    , peerListenerThread
                                    , peerDialerThread
                                    ]

                            result <- try (void (waitAnyCancel allThreads)) :: IO (Either SomeException ())
                            case result of
                                Left exc -> do
                                    hPutStrLn stderr ("Gateway daemon error: " ++ show exc)
                                    mapM_ cancel allThreads
                                    pure (ExitFailure 1)
                                Right () -> do
                                    hPutStrLn stderr "Gateway daemon stopped"
                                    pure ExitSuccess

resolveLocalPeerEndpoint :: DaemonConfig -> Orders -> Either String PeerEndpoint
resolveLocalPeerEndpoint config orders =
    case filter (\peer -> peerNodeId peer == daemonNodeId config) (ordersNodes orders) of
        [peer] -> Right peer
        [] -> Left ("local node " ++ daemonNodeId config ++ " not found in orders")
        _ -> Left ("local node " ++ daemonNodeId config ++ " appeared multiple times in orders")

heartbeatLoop :: DaemonConfig -> Orders -> TVar DaemonState -> Map String String -> IO ()
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
            let event = createSignedEvent nodeId eventTypeHeartbeat heartbeatPayload key now
            atomically $ modifyTVar' stateVar $ \state ->
                state
                    { stateCommitLog = appendIfNew (stateCommitLog state) event
                    , stateLastHeartbeatTimes =
                        Map.insert nodeId now (stateLastHeartbeatTimes state)
                    }
    threadDelay (round (daemonHeartbeatInterval config * 1000000))

{- | Recompute the elected owner from heartbeat freshness, emit signed
@claim@/@yield@ events on transitions, and update the in-memory owner
view.  Closes the model's ownership-event lifecycle in the runtime.
-}
gatewayLoop :: DaemonConfig -> Orders -> TVar DaemonState -> Map String String -> IO ()
gatewayLoop config orders stateVar eventKeys = forever $ do
    now <- getCurrentTime
    state <- readTVarIO stateVar
    let nodeId = daemonNodeId config
        rule = ordersGatewayRule orders
        timeout = fromIntegral (heartbeatTimeoutSeconds rule)
        ordersOk = stateLatestObservedOrdersVersion state <= stateOrdersVersionUtc state
        activeNodes =
            [ rankedId
            | rankedId <- rankedNodes rule
            , case Map.lookup rankedId (stateLastHeartbeatTimes state) of
                Just lastHeartbeat -> diffUTCTime now lastHeartbeat < timeout
                Nothing -> rankedId == nodeId
            ]
        owner =
            if not ordersOk
                then Nothing
                else case activeNodes of
                    (firstNode : _) -> Just firstNode
                    [] -> Nothing
        previous = stateGatewayOwner state
        transitionedToOwner = previous /= Just nodeId && owner == Just nodeId
        transitionedFromOwner = previous == Just nodeId && owner /= Just nodeId
    when transitionedToOwner $
        appendOwnershipEvent
            stateVar
            eventKeys
            nodeId
            eventTypeClaim
            now
            ( object
                [ "claiming_node_id" .= nodeId
                , "previous_owner" .= toMaybeString previous
                ]
            )
    when transitionedFromOwner $
        appendOwnershipEvent
            stateVar
            eventKeys
            nodeId
            eventTypeYield
            now
            ( object
                [ "yielding_node_id" .= nodeId
                , "new_owner" .= toMaybeString owner
                ]
            )
    atomically $ modifyTVar' stateVar $ \s ->
        s
            { stateGatewayOwner = owner
            , statePreviousOwner = previous
            }
    threadDelay 1000000

toMaybeString :: Maybe String -> Value
toMaybeString Nothing = Null
toMaybeString (Just s) = String (Text.pack s)

appendOwnershipEvent ::
    TVar DaemonState ->
    Map String String ->
    String ->
    String ->
    UTCTime ->
    Value ->
    IO ()
appendOwnershipEvent stateVar eventKeys nodeId evType now payload =
    case Map.lookup nodeId eventKeys of
        Nothing -> hPutStrLn stderr ("No event key for local node " ++ nodeId)
        Just key -> do
            let ev = createSignedEvent nodeId evType payload key now
            atomically $ modifyTVar' stateVar $ \s ->
                s{stateCommitLog = appendIfNew (stateCommitLog s) ev}
            hPutStrLn stderr ("Gateway emitted " ++ evType ++ " event from " ++ nodeId)

{- | Write Route 53 only when the runtime CanWriteDns predicate holds: the
local node must be the elected owner AND the most recent claim/yield
event from the local node must be a claim.
-}
dnsWriteLoop :: DaemonConfig -> Orders -> TVar DaemonState -> IO ()
dnsWriteLoop config _orders stateVar = forever $ do
    state <- readTVarIO stateVar
    let nodeId = daemonNodeId config
        eligible = canWriteDns nodeId (stateGatewayOwner state) (stateCommitLog state)
    when eligible $ do
        case daemonDnsWriteGate config of
            Nothing -> pure ()
            Just gate -> do
                publicIpResult <- fetchPublicIp
                case publicIpResult of
                    Left err -> hPutStrLn stderr ("DNS write skipped: " ++ err)
                    Right currentIp -> do
                        atomically $ modifyTVar' stateVar $ \s -> s{stateLastPublicIp = Just currentIp}
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

restServerLoop :: PeerEndpoint -> DaemonConfig -> TVar DaemonState -> IO ()
restServerLoop localPeer config stateVar = do
    let port = peerRestPort localPeer
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
    close sock
  where
    handleRequest = do
        -- Consume the inbound request before closing the socket so the
        -- response does not get reset under kubectl port-forward.
        _ <- receiveAll sock
        state <- readTVarIO stateVar
        now <- getCurrentTime
        let responseBody = renderStateJson now config state
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

-- | Bind the peer-events HTTP listener on the configured socket port.
peerListenerLoop ::
    PeerEndpoint ->
    DaemonConfig ->
    Orders ->
    TVar DaemonState ->
    Map String String ->
    IO ()
peerListenerLoop localPeer config orders stateVar eventKeys = do
    let port = peerSocketPort localPeer
    sock <- socket AF_INET Stream 0
    setSocketOption sock ReuseAddr 1
    bind sock (SockAddrInet (fromIntegral port) (tupleToHostAddress (0, 0, 0, 0)))
    listen sock 16
    hPutStrLn stderr ("Peer events listener on port " ++ show port)
    forever $ do
        (clientSock, _) <- accept sock
        void $ async $ handlePeerClient clientSock config orders stateVar eventKeys

handlePeerClient ::
    Socket ->
    DaemonConfig ->
    Orders ->
    TVar DaemonState ->
    Map String String ->
    IO ()
handlePeerClient sock config orders stateVar eventKeys = do
    _ <- try handleOne :: IO (Either SomeException ())
    close sock
  where
    handleOne = do
        raw <- receiveAll sock
        case parsePeerHttpRequest raw of
            Left err -> do
                let response = renderPeerHttpResponse (PeerResponseError err)
                sendAll sock (BL.toStrict response)
            Right (PeerPushEvents batch) -> do
                response <- ingestPeerBatch config orders stateVar eventKeys batch
                sendAll sock (BL.toStrict response)
            Right PeerPullEvents -> do
                state <- readTVarIO stateVar
                let batch =
                        PeerEventBatch
                            (commitLogEvents (stateCommitLog state))
                            (stateOrdersVersionUtc state)
                    response = renderPeerHttpResponse (PeerResponseEventBatch batch)
                sendAll sock (BL.toStrict response)

{- | Read the inbound request until the body matches the @Content-Length@
header.  GET requests with no body return after the header section.
-}
receiveAll :: Socket -> IO BS.ByteString
receiveAll sock = loop BS.empty
  where
    loop acc = do
        chunk <- recv sock 16384
        if BS.null chunk
            then pure acc
            else
                let acc' = acc `BS.append` chunk
                 in if hasFullBody acc'
                        then pure acc'
                        else loop acc'

    hasFullBody :: BS.ByteString -> Bool
    hasFullBody bs =
        let text = BS8.unpack bs
            (header, body) = splitOnDoubleCrlf text
         in case lookupContentLength header of
                Just expected -> length body >= expected
                Nothing -> not (null header) && doubleCrlfPresent text

    doubleCrlfPresent :: String -> Bool
    doubleCrlfPresent text = "\r\n\r\n" `isInfixOf'` text || "\n\n" `isInfixOf'` text

    splitOnDoubleCrlf :: String -> (String, String)
    splitOnDoubleCrlf = go []
      where
        go acc rest = case rest of
            '\r' : '\n' : '\r' : '\n' : remainder -> (reverse acc, remainder)
            '\n' : '\n' : remainder -> (reverse acc, remainder)
            (c : remainder) -> go (c : acc) remainder
            [] -> (reverse acc, "")

    lookupContentLength :: String -> Maybe Int
    lookupContentLength text =
        let headerLines = lines (replace '\r' ' ' text)
            findHeader [] = Nothing
            findHeader (h : rest) =
                let lc = map toLower h
                 in if "content-length:" `isPrefixOf` lc
                        then case reads (drop (length ("content-length:" :: String)) lc) of
                            ((n, _) : _) -> Just n
                            _ -> findHeader rest
                        else findHeader rest
         in findHeader headerLines

    replace c r = map (\x -> if x == c then r else x)

    isInfixOf' :: String -> String -> Bool
    isInfixOf' needle haystack = any (needle `isPrefixOf`) (tails haystack)

    tails :: [a] -> [[a]]
    tails [] = [[]]
    tails xs@(_ : rest) = xs : tails rest

ingestPeerBatch ::
    DaemonConfig ->
    Orders ->
    TVar DaemonState ->
    Map String String ->
    PeerEventBatch ->
    IO BL.ByteString
ingestPeerBatch config orders stateVar eventKeys batch = do
    now <- getCurrentTime
    state0 <- readTVarIO stateVar
    let receiverOrdersVersion = stateOrdersVersionUtc state0
        senderOrdersVersion = peerEventBatchSenderOrdersVersionUtc batch
    if senderOrdersVersion > 0 && senderOrdersVersion < receiverOrdersVersion
        then
            pure
                ( renderPeerHttpResponse
                    (PeerResponseStaleOrders senderOrdersVersion receiverOrdersVersion)
                )
        else do
            let nowIso = formatUtcIso now
                knownEmitters = map peerNodeId (ordersNodes orders)
                lookupKey = (`Map.lookup` eventKeys)
                (accepted, rejected) =
                    handlePeerRequest
                        lookupKey
                        knownEmitters
                        (daemonMaxClockSkewSeconds config)
                        nowIso
                        batch
            appliedCount <- atomically $ do
                s0 <- readTVar stateVar
                let preCount = length (commitLogEvents (stateCommitLog s0))
                    updated =
                        applyAcceptedEvents now accepted s0
                            `noteSenderOrdersAdvert` senderOrdersVersion
                    postCount = length (commitLogEvents (stateCommitLog updated))
                writeTVar stateVar updated
                pure (postCount - preCount)
            pure (renderPeerHttpResponse (PeerResponseEventsAccepted appliedCount rejected))

noteSenderOrdersAdvert :: DaemonState -> Int -> DaemonState
noteSenderOrdersAdvert s senderVersion
    | senderVersion > stateLatestObservedOrdersVersion s =
        s{stateLatestObservedOrdersVersion = senderVersion}
    | otherwise = s

{- | Apply a list of accepted peer events to the daemon state in one pass:
append to the commit log (idempotently), update last-heartbeat times,
record per-peer transport health, refresh max-observed clock skew, and
promote a newer Orders version when announced.
-}
applyAcceptedEvents :: UTCTime -> [SignedEvent] -> DaemonState -> DaemonState
applyAcceptedEvents now events s0 =
    let log0 = stateCommitLog s0
        log' = foldl' appendIfNew log0 events
        heartbeats0 = stateLastHeartbeatTimes s0
        heartbeats' = foldl' updateHeartbeatFromEvent heartbeats0 events
        peerHealth0 = statePeerHealth s0
        peerHealth' = foldl' (updatePeerHealthFromEvent now) peerHealth0 events
        skew0 = stateMaxObservedSkewSeconds s0
        skew' = foldl' (updateSkewFromEvent now) skew0 events
        ordersAdvert = foldl' updateOrdersAdvert (stateLatestObservedOrdersVersion s0) events
     in s0
            { stateCommitLog = log'
            , stateLastHeartbeatTimes = heartbeats'
            , statePeerHealth = peerHealth'
            , stateMaxObservedSkewSeconds = skew'
            , stateLatestObservedOrdersVersion = ordersAdvert
            }

updateHeartbeatFromEvent :: Map String UTCTime -> SignedEvent -> Map String UTCTime
updateHeartbeatFromEvent acc ev =
    case eventTimestampUtc ev of
        Just ts ->
            Map.insertWith max (emitterNodeId ev) ts acc
        Nothing -> acc

updatePeerHealthFromEvent :: UTCTime -> Map String PeerHealth -> SignedEvent -> Map String PeerHealth
updatePeerHealthFromEvent now acc ev =
    let baseline = PeerHealth (Just now) True Nothing
        merge _new old =
            old
                { peerHealthLastInboundEvent = Just now
                , peerHealthConnected = True
                , peerHealthLastError = Nothing
                }
     in Map.insertWith merge (emitterNodeId ev) baseline acc

updateSkewFromEvent :: UTCTime -> Maybe Double -> SignedEvent -> Maybe Double
updateSkewFromEvent now acc ev =
    case eventTimestampUtc ev of
        Just ts ->
            let skew = abs (realToFrac (diffUTCTime now ts) :: Double)
             in Just (maybe skew (max skew) acc)
        Nothing -> acc

updateOrdersAdvert :: Int -> SignedEvent -> Int
updateOrdersAdvert acc ev =
    case extractOrdersVersionFromEvent ev of
        Just v | v > acc -> v
        _ -> acc

{- | Periodically push the local commit log to every other peer in the
mesh.  Each cycle marks unreachable peers as disconnected so
@/v1/state@ exposes per-peer transport health.
-}
peerDialerLoop :: DaemonConfig -> Orders -> TVar DaemonState -> IO ()
peerDialerLoop config orders stateVar = forever $ do
    state <- readTVarIO stateVar
    let nodeId = daemonNodeId config
        peers = [p | p <- ordersNodes orders, peerNodeId p /= nodeId]
        events = commitLogEvents (stateCommitLog state)
        batch = PeerEventBatch events (stateOrdersVersionUtc state)
    mapM_ (pushToPeer stateVar batch) peers
    threadDelay (round (daemonReconnectInterval config * 1000000))

pushToPeer :: TVar DaemonState -> PeerEventBatch -> PeerEndpoint -> IO ()
pushToPeer stateVar batch peer = do
    let host = peerDialSocketHost peer
        port = peerSocketPort peer
        body = encode (encodePeerEventBatch batch)
        request =
            BL.toStrict $
                BL.append
                    ( BL.fromStrict
                        ( BS8.pack
                            ( "POST /v1/peer/events HTTP/1.1\r\n"
                                ++ "Host: "
                                ++ host
                                ++ ":"
                                ++ show port
                                ++ "\r\n"
                                ++ "Content-Type: application/json\r\n"
                                ++ "Content-Length: "
                                ++ show (BL.length body)
                                ++ "\r\n"
                                ++ "Connection: close\r\n"
                                ++ "\r\n"
                            )
                        )
                    )
                    body
    result <- try (dialAndSend host port request) :: IO (Either SomeException (Either String BS.ByteString))
    case result of
        Left exc -> markPeerError stateVar (peerNodeId peer) (show exc)
        Right (Left err) -> markPeerError stateVar (peerNodeId peer) err
        Right (Right _resp) -> markPeerOk stateVar (peerNodeId peer)

dialAndSend :: String -> Int -> BS.ByteString -> IO (Either String BS.ByteString)
dialAndSend host port request = do
    addrInfos <- getAddrInfo Nothing (Just host) (Just (show port))
    case addrInfos of
        [] -> pure (Left ("no address resolution for " ++ host))
        (info : _) -> do
            sock <- socket AF_INET Stream defaultProtocol
            connectResult <- try (connect sock (addrAddress info)) :: IO (Either SomeException ())
            case connectResult of
                Left exc -> do
                    close sock
                    pure (Left (show exc))
                Right () -> do
                    sendAll sock request
                    chunks <- readUntilClose sock []
                    close sock
                    pure (Right (BS.concat (reverse chunks)))

readUntilClose :: Socket -> [BS.ByteString] -> IO [BS.ByteString]
readUntilClose sock acc = do
    chunk <- recv sock 16384
    if BS.null chunk
        then pure acc
        else readUntilClose sock (chunk : acc)

markPeerError :: TVar DaemonState -> String -> String -> IO ()
markPeerError stateVar peerId reason =
    atomically $ modifyTVar' stateVar $ \s ->
        s
            { statePeerHealth =
                Map.alter
                    ( \mh -> case mh of
                        Just h -> Just h{peerHealthConnected = False, peerHealthLastError = Just reason}
                        Nothing -> Just (PeerHealth Nothing False (Just reason))
                    )
                    peerId
                    (statePeerHealth s)
            }

markPeerOk :: TVar DaemonState -> String -> IO ()
markPeerOk stateVar peerId = do
    now <- getCurrentTime
    atomically $ modifyTVar' stateVar $ \s ->
        s
            { statePeerHealth =
                Map.alter
                    ( \mh -> case mh of
                        Just h ->
                            Just
                                h
                                    { peerHealthConnected = True
                                    , peerHealthLastError = Nothing
                                    , peerHealthLastInboundEvent =
                                        Just (maybe now (max now) (peerHealthLastInboundEvent h))
                                    }
                        Nothing -> Just (PeerHealth (Just now) True Nothing)
                    )
                    peerId
                    (statePeerHealth s)
            }

renderStateJson :: UTCTime -> DaemonConfig -> DaemonState -> BL.ByteString
renderStateJson now config state =
    encode $
        object
            [ "node_id" .= daemonNodeId config
            , "gateway_owner" .= stateGatewayOwner state
            , "previous_owner" .= statePreviousOwner state
            , "has_active_claim" .= (stateGatewayOwner state == Just (daemonNodeId config))
            , "can_write_dns"
                .= canWriteDns (daemonNodeId config) (stateGatewayOwner state) (stateCommitLog state)
            , "node_disposition" .= renderDisposition (nodeDisposition (daemonNodeId config) (stateCommitLog state))
            , "peer_dispositions" .= renderPeerDispositions state
            , "mesh_peers" .= stateMeshPeers state
            , "event_count" .= length (commitLogEvents (stateCommitLog state))
            , "event_hashes" .= renderRecentEventHashes (commitLogEvents (stateCommitLog state))
            , "last_public_ip_observed" .= stateLastPublicIp state
            , "last_dns_write_ip" .= stateLastDnsWriteIp state
            , "last_dns_write_at_utc" .= fmap formatUtcIso (stateLastDnsWriteTime state)
            , "dns_write_gate" .= fmap renderDnsWriteGate (daemonDnsWriteGate config)
            , "heartbeat_age_seconds" .= renderHeartbeatAges now state
            , "peer_transport" .= renderPeerTransport now state
            , "max_clock_skew_seconds_observed" .= stateMaxObservedSkewSeconds state
            , "max_clock_skew_seconds_bound" .= daemonMaxClockSkewSeconds config
            , "orders_version_utc" .= stateOrdersVersionUtc state
            , "latest_observed_orders_version_utc" .= stateLatestObservedOrdersVersion state
            ]

gatewayStatusEventHashLimit :: Int
gatewayStatusEventHashLimit = 64

renderRecentEventHashes :: [SignedEvent] -> [String]
renderRecentEventHashes events =
    reverse (take gatewayStatusEventHashLimit (reverse (map eventHash events)))

renderDisposition :: Disposition -> Value
renderDisposition d = case d of
    DispositionOwner -> String "owner"
    DispositionYielded -> String "yielded"
    DispositionUnknown -> String "unknown"

renderPeerDispositions :: DaemonState -> Value
renderPeerDispositions state =
    Object $
        KeyMap.fromList
            [ (Key.fromString peer, renderDisposition (nodeDisposition peer (stateCommitLog state)))
            | peer <- stateMeshPeers state
            ]

renderDnsWriteGate :: DnsWriteGate -> Value
renderDnsWriteGate gate =
    object
        [ "zone_id" .= dnsWriteGateZoneId gate
        , "fqdn" .= dnsWriteGateFqdn gate
        , "ttl" .= dnsWriteGateTtl gate
        , "aws_region" .= dnsWriteGateAwsRegion gate
        ]

renderHeartbeatAges :: UTCTime -> DaemonState -> Value
renderHeartbeatAges now state =
    Object $
        KeyMap.fromList
            [ (Key.fromString nodeId, toJSON (realToFrac (diffUTCTime now timestamp) :: Double))
            | (nodeId, timestamp) <- Map.toList (stateLastHeartbeatTimes state)
            ]

renderPeerTransport :: UTCTime -> DaemonState -> Value
renderPeerTransport now state =
    Object $
        KeyMap.fromList
            [ ( Key.fromString peer
              , object
                    [ "connected" .= peerHealthConnected health
                    , "last_inbound_event_age_seconds"
                        .= fmap (\t -> realToFrac (diffUTCTime now t) :: Double) (peerHealthLastInboundEvent health)
                    , "last_error" .= peerHealthLastError health
                    ]
              )
            | (peer, health) <- Map.toList (statePeerHealth state)
            ]

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
