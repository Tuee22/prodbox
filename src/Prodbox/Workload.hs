{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Workload (
    runWorkloadCommand,
)
where

import Control.Exception (
    SomeException,
    bracket,
    finally,
    try,
 )
import Control.Monad (forever)
import Data.Aeson (
    Value,
    encode,
    object,
    (.=),
 )
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAsciiUpper)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Network.Socket (
    AddrInfo (..),
    AddrInfoFlag (AI_PASSIVE),
    Socket,
    SocketOption (ReuseAddr),
    SocketType (Stream),
    accept,
    addrAddress,
    addrFlags,
    addrProtocol,
    bind,
    close,
    connect,
    defaultHints,
    getAddrInfo,
    gracefulClose,
    listen,
    setSocketOption,
    socket,
    withSocketsDo,
 )
import Network.Socket.ByteString (recv, sendAll)
import Prodbox.CLI.Command (WorkloadCommand (..))
import System.Environment (lookupEnv)
import System.Exit (
    ExitCode (ExitFailure, ExitSuccess),
 )
import System.IO (hPutStrLn, stderr)

data WorkloadMode
    = WorkloadApi
    | WorkloadWebsocket
    deriving (Eq, Show)

data HttpRequest = HttpRequest
    { httpRequestPath :: String
    , httpRequestHeaders :: Map String String
    , httpRequestBody :: String
    }
    deriving (Eq, Show)

data RedisConfig = RedisConfig
    { redisHost :: String
    , redisPort :: String
    }
    deriving (Eq, Show)

data RedisReply
    = RedisSimple String
    | RedisInteger Int
    | RedisBulk (Maybe String)
    | RedisArray [RedisReply]
    deriving (Eq, Show)

runWorkloadCommand :: WorkloadCommand -> IO ExitCode
runWorkloadCommand command =
    case command of
        WorkloadStart -> withSocketsDo runWorkloadServer

runWorkloadServer :: IO ExitCode
runWorkloadServer = do
    modeResult <- resolveWorkloadMode
    case modeResult of
        Left err -> failWith err
        Right mode -> do
            port <- resolveHttpPort
            hPutStrLn stderr ("Public workload starting: mode=" ++ renderMode mode ++ " port=" ++ show port)
            bracket (openListeningSocket port) close $ \serverSocket -> do
                listen serverSocket 16
                forever $ do
                    (clientSocket, _) <- accept serverSocket
                    _ <- try (handleClient mode clientSocket) :: IO (Either SomeException ())
                    pure ()
                pure ExitSuccess

handleClient :: WorkloadMode -> Socket -> IO ()
handleClient mode clientSocket =
    finally
        ( do
            requestResult <- readHttpRequest clientSocket
            case requestResult of
                Left err -> sendPlainTextResponse clientSocket 400 err
                Right request ->
                    case mode of
                        WorkloadApi -> handleApiRequest clientSocket request
                        WorkloadWebsocket -> handleWebsocketRequest clientSocket request
        )
        (gracefulClose clientSocket 1000)

handleApiRequest :: Socket -> HttpRequest -> IO ()
handleApiRequest clientSocket request = do
    podName <- resolvePodName
    let pathOnly = requestPathOnly request
    case pathOnly of
        "/healthz" -> sendPlainTextResponse clientSocket 200 "ok"
        _ ->
            sendJsonResponse
                clientSocket
                200
                ( object
                    [ "mode" .= ("api" :: String)
                    , "pod" .= podName
                    , "path" .= pathOnly
                    ]
                )

handleWebsocketRequest :: Socket -> HttpRequest -> IO ()
handleWebsocketRequest clientSocket request = do
    podName <- resolvePodName
    let pathOnly = requestPathOnly request
        queryParams = requestQueryParams request
    case pathOnly of
        "/healthz" -> sendPlainTextResponse clientSocket 200 "ok"
        "/ws/connect" ->
            case requireSession queryParams of
                Left err -> sendPlainTextResponse clientSocket 400 err
                Right sessionId -> do
                    redisResult <- withRedisConnection $ \redisSocket -> do
                        setResult <- redisSet redisSocket (connectedByKey sessionId) podName
                        case setResult of
                            Left err -> pure (Left err)
                            Right () ->
                                if Map.lookup "reset" queryParams == Just "true"
                                    then redisDel redisSocket (messagesKey sessionId)
                                    else pure (Right ())
                    case redisResult of
                        Left err -> sendPlainTextResponse clientSocket 500 err
                        Right () ->
                            sendJsonResponse
                                clientSocket
                                200
                                ( object
                                    [ "mode" .= ("websocket" :: String)
                                    , "pod" .= podName
                                    , "session" .= sessionId
                                    ]
                                )
        "/ws/publish" ->
            case requireSession queryParams of
                Left err -> sendPlainTextResponse clientSocket 400 err
                Right sessionId -> do
                    let messageBody =
                            case httpRequestBody request of
                                "" -> fromMaybe "" (Map.lookup "message" queryParams)
                                value -> value
                    if messageBody == ""
                        then sendPlainTextResponse clientSocket 400 "message body must not be empty"
                        else do
                            redisResult <- withRedisConnection $ \redisSocket -> do
                                setResult <- redisSet redisSocket (connectedByKey sessionId) podName
                                case setResult of
                                    Left err -> pure (Left err)
                                    Right () -> redisRpush redisSocket (messagesKey sessionId) messageBody
                            case redisResult of
                                Left err -> sendPlainTextResponse clientSocket 500 err
                                Right messageCount ->
                                    sendJsonResponse
                                        clientSocket
                                        200
                                        ( object
                                            [ "mode" .= ("websocket" :: String)
                                            , "pod" .= podName
                                            , "session" .= sessionId
                                            , "messageCount" .= messageCount
                                            ]
                                        )
        "/ws/state" ->
            case requireSession queryParams of
                Left err -> sendPlainTextResponse clientSocket 400 err
                Right sessionId -> do
                    redisResult <- withRedisConnection $ \redisSocket -> do
                        connectedByResult <- redisGet redisSocket (connectedByKey sessionId)
                        case connectedByResult of
                            Left err -> pure (Left err)
                            Right connectedBy -> do
                                messagesResult <- redisLrange redisSocket (messagesKey sessionId) 0 (-1)
                                pure ((,) connectedBy <$> messagesResult)
                    case redisResult of
                        Left err -> sendPlainTextResponse clientSocket 500 err
                        Right (connectedBy, messages) ->
                            sendJsonResponse
                                clientSocket
                                200
                                ( object
                                    [ "mode" .= ("websocket" :: String)
                                    , "pod" .= podName
                                    , "session" .= sessionId
                                    , "connectedBy" .= connectedBy
                                    , "messages" .= messages
                                    ]
                                )
        _ -> sendPlainTextResponse clientSocket 404 "not found"

requireSession :: Map String String -> Either String String
requireSession queryParams =
    case Map.lookup "session" queryParams of
        Just sessionId | sessionId /= "" -> Right sessionId
        _ -> Left "session query parameter is required"

requestPathOnly :: HttpRequest -> String
requestPathOnly request =
    fst (splitOnFirst '?' (httpRequestPath request))

requestQueryParams :: HttpRequest -> Map String String
requestQueryParams request =
    case splitOnFirst '?' (httpRequestPath request) of
        (_, "") -> Map.empty
        (_, rawQuery) ->
            Map.fromList
                [ splitOnFirst '=' queryPart
                | queryPart <- splitOn '&' rawQuery
                , queryPart /= ""
                ]

readHttpRequest :: Socket -> IO (Either String HttpRequest)
readHttpRequest clientSocket = go ""
  where
    go :: String -> IO (Either String HttpRequest)
    go accumulated = do
        chunk <- recv clientSocket 4096
        let next = accumulated ++ BS8.unpack chunk
        if BS.null chunk
            then
                if next == ""
                    then pure (Left "request payload was empty")
                    else pure (parseHttpRequest next)
            else case splitOnSubstring "\r\n\r\n" next of
                Nothing -> go next
                Just (headerText, bodyText) ->
                    let expectedBodyLength = contentLengthFromHeaderText headerText
                     in if length bodyText >= expectedBodyLength
                            then pure (parseHttpRequest (headerText ++ "\r\n\r\n" ++ take expectedBodyLength bodyText))
                            else go next

parseHttpRequest :: String -> Either String HttpRequest
parseHttpRequest rawRequest =
    case splitOnSubstring "\r\n\r\n" rawRequest of
        Nothing -> Left "could not parse HTTP headers"
        Just (headerText, bodyText) ->
            case linesWithoutCarriageReturn headerText of
                requestLine : headerLines ->
                    case words requestLine of
                        [_methodName, requestPath, _httpVersion] ->
                            Right
                                HttpRequest
                                    { httpRequestPath = requestPath
                                    , httpRequestHeaders = parseHeaders headerLines
                                    , httpRequestBody = bodyText
                                    }
                        _ -> Left "invalid HTTP request line"
                [] -> Left "missing HTTP request line"

parseHeaders :: [String] -> Map String String
parseHeaders =
    foldl' addHeader Map.empty
  where
    addHeader headers rawLine =
        case splitOnSubstring ": " rawLine of
            Just (headerName, headerValue) ->
                Map.insert (map toLowerAscii headerName) headerValue headers
            Nothing -> headers

contentLengthFromHeaderText :: String -> Int
contentLengthFromHeaderText headerText =
    case Map.lookup "content-length" (parseHeaders (drop 1 (linesWithoutCarriageReturn headerText))) of
        Just rawValue ->
            case readMaybeInt rawValue of
                Just value | value >= 0 -> value
                _ -> 0
        Nothing -> 0

sendPlainTextResponse :: Socket -> Int -> String -> IO ()
sendPlainTextResponse clientSocket statusCode bodyText =
    sendResponse clientSocket statusCode "text/plain; charset=utf-8" (encodeUtf8 bodyText)

sendJsonResponse :: Socket -> Int -> Value -> IO ()
sendJsonResponse clientSocket statusCode payload =
    sendResponse clientSocket statusCode "application/json" (encode payload)

sendResponse :: Socket -> Int -> String -> BL.ByteString -> IO ()
sendResponse clientSocket statusCode contentType payload = do
    let headerText =
            concat
                [ "HTTP/1.1 "
                , show statusCode
                , " "
                , httpStatusText statusCode
                , "\r\nContent-Type: "
                , contentType
                , "\r\nContent-Length: "
                , show (BL.length payload)
                , "\r\nConnection: close\r\n\r\n"
                ]
    sendAll clientSocket (BS8.pack headerText)
    sendAll clientSocket (BL.toStrict payload)

httpStatusText :: Int -> String
httpStatusText statusCode =
    case statusCode of
        200 -> "OK"
        400 -> "Bad Request"
        404 -> "Not Found"
        500 -> "Internal Server Error"
        _ -> "Response"

resolveWorkloadMode :: IO (Either String WorkloadMode)
resolveWorkloadMode = do
    maybeMode <- lookupEnv "PRODBOX_WORKLOAD_MODE"
    pure $
        case maybeMode of
            Just "api" -> Right WorkloadApi
            Just "websocket" -> Right WorkloadWebsocket
            Just value ->
                Left
                    ( "unsupported PRODBOX_WORKLOAD_MODE `"
                        ++ value
                        ++ "`; expected `api` or `websocket`"
                    )
            Nothing -> Left "PRODBOX_WORKLOAD_MODE must be set to `api` or `websocket`"

resolveHttpPort :: IO Int
resolveHttpPort = do
    maybePort <- lookupEnv "PRODBOX_HTTP_PORT"
    pure $
        case maybePort >>= readMaybeInt of
            Just portNumber | portNumber > 0 -> portNumber
            _ -> 8080

resolvePodName :: IO String
resolvePodName = do
    maybePodName <- lookupEnv "HOSTNAME"
    pure $
        case maybePodName of
            Just podName | podName /= "" -> podName
            _ -> "unknown-pod"

openListeningSocket :: Int -> IO Socket
openListeningSocket port = do
    addressInfos <-
        getAddrInfo
            (Just defaultHints{addrFlags = [AI_PASSIVE], addrProtocol = 0})
            Nothing
            (Just (show port))
    case addressInfos of
        addressInfo : _ -> do
            listenSocket <- socket (addrFamily addressInfo) Stream (addrProtocol addressInfo)
            setSocketOption listenSocket ReuseAddr 1
            bind listenSocket (addrAddress addressInfo)
            pure listenSocket
        [] -> error ("no listen addresses resolved for port " ++ show port)

withRedisConnection :: (Socket -> IO (Either String a)) -> IO (Either String a)
withRedisConnection action = do
    configResult <- resolveRedisConfig
    case configResult of
        Left err -> pure (Left err)
        Right config ->
            bracket (openRedisSocket config) close action

resolveRedisConfig :: IO (Either String RedisConfig)
resolveRedisConfig = do
    maybeHost <- lookupEnv "PRODBOX_REDIS_HOST"
    maybePort <- lookupEnv "PRODBOX_REDIS_PORT"
    pure $
        case (maybeHost, maybePort) of
            (Just host, Just port)
                | host /= "" && port /= "" ->
                    Right RedisConfig{redisHost = host, redisPort = port}
            _ ->
                Left
                    "PRODBOX_REDIS_HOST and PRODBOX_REDIS_PORT must be set for websocket mode"

openRedisSocket :: RedisConfig -> IO Socket
openRedisSocket config = do
    addressInfos <-
        getAddrInfo
            (Just defaultHints{addrProtocol = 0})
            (Just (redisHost config))
            (Just (redisPort config))
    case addressInfos of
        addressInfo : _ -> do
            redisSocket <- socket (addrFamily addressInfo) Stream (addrProtocol addressInfo)
            connect redisSocket (addrAddress addressInfo)
            pure redisSocket
        [] -> error ("no Redis addresses resolved for " ++ redisHost config ++ ":" ++ redisPort config)

redisSet :: Socket -> String -> String -> IO (Either String ())
redisSet redisSocket keyName keyValue = do
    replyResult <- sendRedisCommand redisSocket ["SET", keyName, keyValue]
    pure $
        case replyResult of
            Left err -> Left err
            Right (RedisSimple "OK") -> Right ()
            Right reply -> Left ("unexpected Redis SET reply: " ++ show reply)

redisGet :: Socket -> String -> IO (Either String (Maybe String))
redisGet redisSocket keyName = do
    replyResult <- sendRedisCommand redisSocket ["GET", keyName]
    pure $
        case replyResult of
            Left err -> Left err
            Right (RedisBulk maybeValue) -> Right maybeValue
            Right reply -> Left ("unexpected Redis GET reply: " ++ show reply)

redisDel :: Socket -> String -> IO (Either String ())
redisDel redisSocket keyName = do
    replyResult <- sendRedisCommand redisSocket ["DEL", keyName]
    pure $
        case replyResult of
            Left err -> Left err
            Right (RedisInteger _) -> Right ()
            Right reply -> Left ("unexpected Redis DEL reply: " ++ show reply)

redisRpush :: Socket -> String -> String -> IO (Either String Int)
redisRpush redisSocket keyName messageBody = do
    replyResult <- sendRedisCommand redisSocket ["RPUSH", keyName, messageBody]
    pure $
        case replyResult of
            Left err -> Left err
            Right (RedisInteger listLength) -> Right listLength
            Right reply -> Left ("unexpected Redis RPUSH reply: " ++ show reply)

redisLrange :: Socket -> String -> Int -> Int -> IO (Either String [String])
redisLrange redisSocket keyName startIndex endIndex = do
    replyResult <- sendRedisCommand redisSocket ["LRANGE", keyName, show startIndex, show endIndex]
    pure $
        case replyResult of
            Left err -> Left err
            Right (RedisArray values) -> traverse readBulkValue values
            Right reply -> Left ("unexpected Redis LRANGE reply: " ++ show reply)
  where
    readBulkValue reply =
        case reply of
            RedisBulk (Just value) -> Right value
            RedisBulk Nothing -> Right ""
            _ -> Left ("unexpected Redis LRANGE item: " ++ show reply)

sendRedisCommand :: Socket -> [String] -> IO (Either String RedisReply)
sendRedisCommand redisSocket arguments = do
    sendAll redisSocket (BS8.pack (renderRedisCommand arguments))
    readRedisReply redisSocket

renderRedisCommand :: [String] -> String
renderRedisCommand arguments =
    "*"
        ++ show (length arguments)
        ++ "\r\n"
        ++ concatMap renderArgument arguments
  where
    renderArgument argumentText =
        "$"
            ++ show (length argumentText)
            ++ "\r\n"
            ++ argumentText
            ++ "\r\n"

readRedisReply :: Socket -> IO (Either String RedisReply)
readRedisReply redisSocket = go ""
  where
    go accumulated = do
        chunk <- recv redisSocket 4096
        let next = accumulated ++ BS8.unpack chunk
        case parseRedisReply next of
            Just (reply, _) -> pure (Right reply)
            Nothing ->
                if BS.null chunk
                    then pure (Left "received incomplete Redis reply")
                    else go next

parseRedisReply :: String -> Maybe (RedisReply, String)
parseRedisReply value =
    case value of
        '+' : remaining -> do
            (lineText, rest) <- takeLine remaining
            Just (RedisSimple lineText, rest)
        ':' : remaining -> do
            (lineText, rest) <- takeLine remaining
            parsedValue <- readMaybeInt lineText
            Just (RedisInteger parsedValue, rest)
        '$' : remaining -> do
            (lineText, rest) <- takeLine remaining
            bulkLength <- readMaybeInt lineText
            if bulkLength == (-1)
                then Just (RedisBulk Nothing, rest)
                else do
                    (bulkValue, trailingRest) <- takeBytes bulkLength rest
                    Just (RedisBulk (Just bulkValue), trailingRest)
        '*' : remaining -> do
            (lineText, rest) <- takeLine remaining
            itemCount <- readMaybeInt lineText
            (items, trailingRest) <- takeArrayItems itemCount rest
            Just (RedisArray items, trailingRest)
        _ -> Nothing
  where
    takeArrayItems 0 remaining = Just ([], remaining)
    takeArrayItems itemCount remaining
        | itemCount < 0 = Just ([], remaining)
        | otherwise = do
            (firstItem, next) <- parseRedisReply remaining
            (laterItems, trailingRest) <- takeArrayItems (itemCount - 1) next
            Just (firstItem : laterItems, trailingRest)

takeLine :: String -> Maybe (String, String)
takeLine value = splitOnSubstring "\r\n" value

takeBytes :: Int -> String -> Maybe (String, String)
takeBytes byteCount value =
    let (prefixText, suffixText) = splitAt byteCount value
     in if length prefixText /= byteCount || take 2 suffixText /= "\r\n"
            then Nothing
            else Just (prefixText, drop 2 suffixText)

connectedByKey :: String -> String
connectedByKey sessionId = "prodbox:websocket:" ++ sessionId ++ ":connected-by"

messagesKey :: String -> String
messagesKey sessionId = "prodbox:websocket:" ++ sessionId ++ ":messages"

renderMode :: WorkloadMode -> String
renderMode mode =
    case mode of
        WorkloadApi -> "api"
        WorkloadWebsocket -> "websocket"

encodeUtf8 :: String -> BL.ByteString
encodeUtf8 = BL.fromStrict . BS8.pack

splitOnSubstring :: String -> String -> Maybe (String, String)
splitOnSubstring needle haystack = go [] haystack
  where
    go _ [] = Nothing
    go reversedPrefix remaining
        | needle `startsWith` remaining =
            Just (reverse reversedPrefix, drop (length needle) remaining)
        | otherwise =
            case remaining of
                character : trailing ->
                    go (character : reversedPrefix) trailing

startsWith :: String -> String -> Bool
startsWith [] _ = True
startsWith _ [] = False
startsWith (left : leftRest) (right : rightRest) =
    left == right && startsWith leftRest rightRest

splitOnFirst :: Char -> String -> (String, String)
splitOnFirst delimiter value =
    case break (== delimiter) value of
        (before, _ : after) -> (before, after)
        (before, []) -> (before, "")

splitOn :: Char -> String -> [String]
splitOn _ [] = [""]
splitOn delimiter value =
    case break (== delimiter) value of
        (before, _ : after) -> before : splitOn delimiter after
        (before, []) -> [before]

linesWithoutCarriageReturn :: String -> [String]
linesWithoutCarriageReturn = map trimCarriageReturn . lines

trimCarriageReturn :: String -> String
trimCarriageReturn value =
    case reverse value of
        '\r' : trailing -> reverse trailing
        _ -> value

toLowerAscii :: Char -> Char
toLowerAscii character
    | isAsciiUpper character = toEnum (fromEnum character + 32)
    | otherwise = character

readMaybeInt :: String -> Maybe Int
readMaybeInt value =
    case reads value of
        [(parsedValue, "")] -> Just parsedValue
        _ -> Nothing

failWith :: String -> IO ExitCode
failWith message = do
    hPutStrLn stderr message
    pure (ExitFailure 1)
