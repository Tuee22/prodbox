{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Workload
  ( resolveHttpPort
  , resolveWorkloadLogLevel
  , runWorkloadCommand
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (forkFinally, threadDelay)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception
  ( SomeException
  , bracket
  , finally
  , try
  )
import Control.Monad (forever, void)
import Crypto.Hash.SHA1 qualified as SHA1
import Data.Aeson
  ( Value (..)
  , eitherDecode
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bits (shiftL, shiftR, xor, (.&.), (.|.))
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Base64.URL qualified as Base64Url
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (intercalate, stripPrefix)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Scientific (toBoundedInteger)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word8)
import GHC.Conc (threadWaitRead)
import Network.Socket
  ( AddrInfo (..)
  , AddrInfoFlag (AI_PASSIVE)
  , Socket
  , SocketOption (ReuseAddr)
  , SocketType (Stream)
  , accept
  , addrAddress
  , addrFlags
  , addrProtocol
  , bind
  , close
  , connect
  , defaultHints
  , getAddrInfo
  , gracefulClose
  , listen
  , setSocketOption
  , socket
  , withFdSocket
  , withSocketsDo
  )
import Network.Socket.ByteString (recv, sendAll)
import Prodbox.CLI.Command
  ( WorkloadCommand (..)
  , WorkloadOptions (..)
  )
import Prodbox.CLI.Output (writeError)
import Prodbox.Error (fatalError)
import Prodbox.Gateway.Logging
  ( Severity (..)
  , field
  , logStructuredAt
  , severityFromLogLevel
  )
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( CommandSpec (..)
  , ProcessOutput (..)
  , captureCommand
  )
import System.Environment (lookupEnv)
import System.Exit
  ( ExitCode (ExitFailure, ExitSuccess)
  )
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)

data WorkloadMode
  = WorkloadApi
  | WorkloadWebsocket
  deriving (Eq, Show)

data HttpRequest = HttpRequest
  { httpRequestMethod :: String
  , httpRequestPath :: String
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

data OidcConfig = OidcConfig
  { oidcIssuer :: String
  , oidcClientId :: String
  , oidcClientSecret :: String
  , oidcPublicBaseUrl :: String
  , oidcTokenEndpoint :: String
  }
  deriving (Eq, Show)

data WebsocketRuntime = WebsocketRuntime
  { websocketRuntimePodName :: String
  , websocketRuntimeRedisConfig :: RedisConfig
  , websocketRuntimeOidcConfig :: OidcConfig
  , websocketRuntimeState :: TVar WebsocketServerState
  }

data WebsocketServerState = WebsocketServerState
  { serverDraining :: Bool
  , serverNextConnectionId :: Int
  , serverCloseRequests :: Map Int (TVar (Maybe ConnectionCloseReason))
  }

data ConnectionCloseReason
  = CloseForDrain
  | CloseForRevocation
  | CloseForExpiry
  deriving (Eq, Show)

data AuthorizedToken = AuthorizedToken
  { authorizedRawToken :: String
  , authorizedSubject :: String
  , authorizedPreferredUsername :: Maybe String
  , authorizedIssuer :: String
  , authorizedRouteClaim :: String
  , authorizedExpiryEpoch :: Int
  }
  deriving (Eq, Show)

data OidcSession = OidcSession
  { oidcSessionId :: String
  , oidcSessionCarrier :: String
  , oidcSessionIssuer :: String
  , oidcSessionSubject :: String
  , oidcSessionPreferredUsername :: Maybe String
  , oidcSessionAccessToken :: String
  , oidcSessionIdToken :: String
  , oidcSessionExpiryEpoch :: Int
  }
  deriving (Eq, Show)

data OidcTokenResponse = OidcTokenResponse
  { oidcTokenAccessToken :: String
  , oidcTokenIdToken :: String
  , oidcTokenExpiresInSeconds :: Int
  }
  deriving (Eq, Show)

data WebsocketMessage = WebsocketMessage
  { websocketMessageSenderPod :: String
  , websocketMessagePayload :: String
  }
  deriving (Eq, Show)

data WebSocketFrame
  = WebSocketTextFrame String
  | WebSocketPingFrame BS.ByteString
  | WebSocketPongFrame BS.ByteString
  | WebSocketCloseFrame (Maybe Int) String
  deriving (Eq, Show)

websocketPollDelayMicroseconds :: Int
websocketPollDelayMicroseconds = 250000

websocketDrainGraceMicroseconds :: Int
websocketDrainGraceMicroseconds = 5000000

websocketDrainTimeoutMicroseconds :: Int
websocketDrainTimeoutMicroseconds = 25000000

runWorkloadCommand :: WorkloadCommand -> IO ExitCode
runWorkloadCommand command =
  case command of
    WorkloadStart options -> withSocketsDo (runWorkloadServer options)

runWorkloadServer :: WorkloadOptions -> IO ExitCode
runWorkloadServer options = do
  modeResult <- resolveWorkloadMode
  case modeResult of
    Left err -> failWith err
    Right mode -> do
      port <- resolveHttpPort options
      podName <- resolvePodName
      websocketRuntimeResult <- resolveWebsocketRuntime mode podName
      case websocketRuntimeResult of
        Left err -> failWith err
        Right maybeRuntime -> do
          logLevel <- resolveWorkloadLogLevel options
          logStructuredAt
            (severityFromLogLevel logLevel)
            Info
            "public_workload_starting"
            [ field "mode" (renderMode mode)
            , field "port" port
            , field "log_level" logLevel
            ]
          serverSocketResult <- openListeningSocket port
          case serverSocketResult of
            Left err -> failWith err
            Right serverSocket ->
              bracket (pure serverSocket) close $ \boundSocket -> do
                listen boundSocket 16
                forever $ do
                  (clientSocket, _) <- accept boundSocket
                  void $
                    forkFinally
                      (handleClient mode podName maybeRuntime clientSocket)
                      (\_ -> void (tryCloseSocket clientSocket))

handleClient :: WorkloadMode -> String -> Maybe WebsocketRuntime -> Socket -> IO ()
handleClient mode podName maybeRuntime clientSocket = do
  requestResult <- readHttpRequest clientSocket
  case requestResult of
    Left err -> sendPlainTextResponse clientSocket 400 [] err
    Right (request, requestRemainder) ->
      case mode of
        WorkloadApi -> handleApiRequest podName clientSocket request
        WorkloadWebsocket ->
          case maybeRuntime of
            Nothing -> sendPlainTextResponse clientSocket 500 [] "websocket runtime is unavailable"
            Just runtime ->
              if isWebsocketUpgradeRequest request
                then handleWebsocketUpgrade runtime clientSocket requestRemainder request
                else handleWebsocketHttpRequest runtime clientSocket request

handleApiRequest :: String -> Socket -> HttpRequest -> IO ()
handleApiRequest podName clientSocket request = do
  let pathOnly = requestPathOnly request
  case pathOnly of
    "/healthz" -> sendPlainTextResponse clientSocket 200 [] "ok"
    _ ->
      sendJsonResponse
        clientSocket
        200
        []
        ( object
            [ "mode" .= ("api" :: String)
            , "pod" .= podName
            , "path" .= pathOnly
            ]
        )

handleWebsocketHttpRequest :: WebsocketRuntime -> Socket -> HttpRequest -> IO ()
handleWebsocketHttpRequest runtime clientSocket request = do
  let pathOnly = requestPathOnly request
      queryParams = requestQueryParams request
      methodName = httpRequestMethod request
  case (methodName, pathOnly) of
    ("GET", "/healthz") -> do
      draining <- serverDraining <$> readTVarIO (websocketRuntimeState runtime)
      if draining
        then sendPlainTextResponse clientSocket 503 [] "draining"
        else sendPlainTextResponse clientSocket 200 [] "ok"
    (_, "/drain") -> do
      initiateServerDrain runtime
      waitForDrainCompletion runtime websocketDrainTimeoutMicroseconds
      sendPlainTextResponse clientSocket 200 [] "drain-complete"
    ("POST", "/ws/connect") ->
      withAuthorizedWebsocketToken request clientSocket $ \_ -> do
        let sessionIdResult = requireSession queryParams
            resetRequested = Map.lookup "reset" queryParams == Just "true"
        case sessionIdResult of
          Left err -> sendPlainTextResponse clientSocket 400 [] err
          Right sessionId -> do
            prepareResult <-
              withRedisSocket
                (websocketRuntimeRedisConfig runtime)
                ( \redisSocket -> prepareWebsocketSession redisSocket (websocketRuntimePodName runtime) sessionId resetRequested
                )
            case prepareResult of
              Left err -> sendPlainTextResponse clientSocket 500 [] err
              Right () ->
                sendJsonResponse
                  clientSocket
                  200
                  []
                  ( object
                      [ "mode" .= ("websocket" :: String)
                      , "pod" .= websocketRuntimePodName runtime
                      , "session" .= sessionId
                      ]
                  )
    ("POST", "/ws/publish") ->
      withAuthorizedWebsocketToken request clientSocket $ \token -> do
        let sessionIdResult = requireSession queryParams
            messageBody =
              case httpRequestBody request of
                "" -> fromMaybe "" (Map.lookup "message" queryParams)
                value -> value
        case sessionIdResult of
          Left err -> sendPlainTextResponse clientSocket 400 [] err
          Right sessionId ->
            if messageBody == ""
              then sendPlainTextResponse clientSocket 400 [] "message body must not be empty"
              else do
                publishResult <-
                  withRedisSocket
                    (websocketRuntimeRedisConfig runtime)
                    ( \redisSocket ->
                        publishWebsocketMessage redisSocket token (websocketRuntimePodName runtime) sessionId messageBody
                    )
                case publishResult of
                  Left err -> sendPlainTextResponse clientSocket 500 [] err
                  Right messageCount ->
                    sendJsonResponse
                      clientSocket
                      200
                      []
                      ( object
                          [ "mode" .= ("websocket" :: String)
                          , "pod" .= websocketRuntimePodName runtime
                          , "session" .= sessionId
                          , "messageCount" .= messageCount
                          ]
                      )
    ("POST", "/ws/revoke") ->
      withAuthorizedWebsocketToken request clientSocket $ \token -> do
        let sessionIdResult = requireSession queryParams
        case sessionIdResult of
          Left err -> sendPlainTextResponse clientSocket 400 [] err
          Right sessionId -> do
            revokeResult <-
              withRedisSocket
                (websocketRuntimeRedisConfig runtime)
                (\redisSocket -> revokeWebsocketSession redisSocket token sessionId)
            case revokeResult of
              Left err -> sendPlainTextResponse clientSocket 500 [] err
              Right () -> sendPlainTextResponse clientSocket 200 [] "revoked"
    ("GET", "/ws/state") ->
      withAuthorizedWebsocketToken request clientSocket $ \_ -> do
        let sessionIdResult = requireSession queryParams
        case sessionIdResult of
          Left err -> sendPlainTextResponse clientSocket 400 [] err
          Right sessionId -> do
            stateResult <-
              withRedisSocket
                (websocketRuntimeRedisConfig runtime)
                (\redisSocket -> websocketSessionState redisSocket (websocketRuntimePodName runtime) sessionId)
            case stateResult of
              Left err -> sendPlainTextResponse clientSocket 500 [] err
              Right payload -> sendJsonResponse clientSocket 200 [] payload
    ("GET", "/ws/oidc/start") -> do
      startResult <- buildOidcStartResponse runtime
      case startResult of
        Left err -> sendPlainTextResponse clientSocket 500 [] err
        Right (locationHeader, stateCookie) ->
          sendPlainTextResponse
            clientSocket
            302
            [("Location", locationHeader), ("Set-Cookie", stateCookie)]
            ""
    ("GET", "/ws/oidc/callback") ->
      handleOidcCallback runtime clientSocket request queryParams
    ("GET", "/ws/oidc/session") ->
      handleOidcSession runtime clientSocket request
    ("GET", "/ws") -> sendPlainTextResponse clientSocket 400 [] "websocket upgrade required on /ws"
    _ -> sendPlainTextResponse clientSocket 404 [] "not found"

handleWebsocketUpgrade :: WebsocketRuntime -> Socket -> BS.ByteString -> HttpRequest -> IO ()
handleWebsocketUpgrade runtime clientSocket initialFrameBytes request = do
  let queryParams = requestQueryParams request
      resetRequested = Map.lookup "reset" queryParams == Just "true"
  draining <- serverDraining <$> readTVarIO (websocketRuntimeState runtime)
  if draining
    then sendPlainTextResponse clientSocket 503 [] "draining"
    else case (requireSession queryParams, websocketAcceptKey request, authorizeWebsocketRequest request) of
      (Left err, _, _) -> sendPlainTextResponse clientSocket 400 [] err
      (_, Left err, _) -> sendPlainTextResponse clientSocket 400 [] err
      (_, _, Left err) -> sendPlainTextResponse clientSocket 401 [] err
      (Right sessionId, Right acceptKey, Right token) -> do
        registerResult <- registerWebsocketConnection runtime
        case registerResult of
          Left err -> sendPlainTextResponse clientSocket 500 [] err
          Right (connectionId, closeVar) ->
            finally
              ( do
                  redisResult <-
                    withRedisSocket
                      (websocketRuntimeRedisConfig runtime)
                      ( \redisSocket -> do
                          prepareResult <-
                            prepareWebsocketSession redisSocket (websocketRuntimePodName runtime) sessionId resetRequested
                          case prepareResult of
                            Left err -> pure (Left err)
                            Right () -> do
                              currentMessageCountResult <- redisLlen redisSocket (messagesKey sessionId)
                              case currentMessageCountResult of
                                Left err -> pure (Left err)
                                Right currentMessageCount -> do
                                  sendWebSocketHandshakeResponse clientSocket acceptKey
                                  sendWebSocketText
                                    clientSocket
                                    ( renderJsonText
                                        ( object
                                            [ "type" .= ("welcome" :: String)
                                            , "mode" .= ("websocket" :: String)
                                            , "pod" .= websocketRuntimePodName runtime
                                            , "session" .= sessionId
                                            , "subject" .= authorizedSubject token
                                            , "preferred_username" .= authorizedPreferredUsername token
                                            , "expires_at" .= authorizedExpiryEpoch token
                                            ]
                                        )
                                    )
                                  frameBuffer <- newIORef initialFrameBytes
                                  runWebsocketConnectionLoop
                                    runtime
                                    redisSocket
                                    clientSocket
                                    token
                                    sessionId
                                    currentMessageCount
                                    closeVar
                                    frameBuffer
                                  pure (Right ())
                      )
                  case redisResult of
                    Left err -> sendPlainTextResponse clientSocket 500 [] err
                    Right () -> pure ()
              )
              (unregisterWebsocketConnection runtime connectionId)

runWebsocketConnectionLoop
  :: WebsocketRuntime
  -> Socket
  -> Socket
  -> AuthorizedToken
  -> String
  -> Int
  -> TVar (Maybe ConnectionCloseReason)
  -> IORef BS.ByteString
  -> IO ()
runWebsocketConnectionLoop runtime redisSocket clientSocket token sessionId lastSeenCount closeVar frameBuffer = do
  closeReason <- readTVarIO closeVar
  maybeExpiryReached <- tokenExpired token
  case (closeReason, maybeExpiryReached) of
    (Just CloseForDrain, _) -> do
      sendWebSocketText
        clientSocket
        ( renderJsonText
            ( object
                [ "type" .= ("drain" :: String)
                , "pod" .= websocketRuntimePodName runtime
                , "session" .= sessionId
                ]
            )
        )
      threadDelay websocketDrainGraceMicroseconds
      sendWebSocketClose clientSocket 1012 "server draining"
    (Just CloseForRevocation, _) ->
      sendWebSocketClose clientSocket 4003 "authorization changed; reconnect required"
    (Just CloseForExpiry, _) ->
      sendWebSocketClose clientSocket 4001 "token expired; reconnect required"
    (Nothing, True) -> do
      atomically (writeTVar closeVar (Just CloseForExpiry))
      runWebsocketConnectionLoop
        runtime
        redisSocket
        clientSocket
        token
        sessionId
        lastSeenCount
        closeVar
        frameBuffer
    (Nothing, False) -> do
      bufferedFrameBytes <- readIORef frameBuffer
      maybeReadable <-
        if BS.null bufferedFrameBytes
          then
            withFdSocket
              clientSocket
              (\socketFd -> timeout websocketPollDelayMicroseconds (threadWaitRead (Fd socketFd)))
          else pure (Just ())
      continue <-
        case maybeReadable of
          Nothing -> pure True
          Just () -> do
            frameResult <- readWebSocketFrame clientSocket frameBuffer
            case frameResult of
              Left _ -> pure False
              Right frame ->
                handleIncomingWebSocketFrame runtime redisSocket clientSocket token sessionId frame
      if continue
        then do
          statusResult <- redisGet redisSocket (sessionStatusKey sessionId)
          case statusResult of
            Right (Just "revoked") -> atomically (writeTVar closeVar (Just CloseForRevocation))
            _ -> pure ()
          nextMessageCountResult <- flushNewWebsocketMessages redisSocket clientSocket sessionId lastSeenCount
          case nextMessageCountResult of
            Left _ -> pure ()
            Right nextCount ->
              runWebsocketConnectionLoop
                runtime
                redisSocket
                clientSocket
                token
                sessionId
                nextCount
                closeVar
                frameBuffer
        else pure ()

handleIncomingWebSocketFrame
  :: WebsocketRuntime
  -> Socket
  -> Socket
  -> AuthorizedToken
  -> String
  -> WebSocketFrame
  -> IO Bool
handleIncomingWebSocketFrame runtime redisSocket clientSocket token sessionId frame =
  case frame of
    WebSocketTextFrame messageBody -> do
      publishResult <-
        publishWebsocketMessage redisSocket token (websocketRuntimePodName runtime) sessionId messageBody
      case publishResult of
        Left err -> do
          sendWebSocketClose clientSocket 1011 err
          pure False
        Right _ -> pure True
    WebSocketPingFrame payload -> do
      sendWebSocketControlFrame clientSocket 0xA payload
      pure True
    WebSocketPongFrame _ -> pure True
    WebSocketCloseFrame maybeCode reasonText -> do
      sendWebSocketClose clientSocket (fromMaybe 1000 maybeCode) reasonText
      pure False

buildOidcStartResponse :: WebsocketRuntime -> IO (Either String (String, String))
buildOidcStartResponse runtime = do
  stateToken <- nonceWithPrefix "oidc-state"
  let config = websocketRuntimeOidcConfig runtime
      callbackUrl = oidcPublicBaseUrl config ++ "/oidc/callback"
      locationHeader =
        oidcIssuer config
          ++ "/protocol/openid-connect/auth?client_id="
          ++ urlEncode (oidcClientId config)
          ++ "&response_type=code&scope=openid%20profile"
          ++ "&redirect_uri="
          ++ urlEncode callbackUrl
          ++ "&state="
          ++ urlEncode stateToken
      stateCookie = renderSetCookie oidcStateCookieName stateToken "/ws/oidc" True
  pure (Right (locationHeader, stateCookie))

handleOidcCallback :: WebsocketRuntime -> Socket -> HttpRequest -> Map String String -> IO ()
handleOidcCallback runtime clientSocket request queryParams =
  case ( Map.lookup "code" queryParams
       , Map.lookup "state" queryParams
       , lookupCookie oidcStateCookieName request
       ) of
    (Just authorizationCode, Just returnedState, Just expectedState)
      | returnedState == expectedState -> do
          exchangeResult <- exchangeAuthorizationCode runtime authorizationCode
          case exchangeResult of
            Left err -> sendPlainTextResponse clientSocket 500 [] err
            Right tokenResponse ->
              case buildOidcSessionFromTokens tokenResponse of
                Left err -> sendPlainTextResponse clientSocket 500 [] err
                Right session -> do
                  storeResult <-
                    withRedisSocket
                      (websocketRuntimeRedisConfig runtime)
                      (\redisSocket -> storeOidcSession redisSocket session)
                  case storeResult of
                    Left err -> sendPlainTextResponse clientSocket 500 [] err
                    Right () ->
                      sendPlainTextResponse
                        clientSocket
                        302
                        [ ("Location", "/ws/oidc/session")
                        , ("Set-Cookie", renderSetCookie oidcSessionCookieName (oidcSessionId session) "/ws/oidc" True)
                        , ("Set-Cookie", clearCookie oidcStateCookieName "/ws/oidc")
                        ]
                        ""
    (Nothing, _, _) -> sendPlainTextResponse clientSocket 400 [] "authorization code is required"
    (_, Nothing, _) -> sendPlainTextResponse clientSocket 400 [] "state is required"
    (_, _, Nothing) -> sendPlainTextResponse clientSocket 400 [] "missing oidc state cookie"
    _ -> sendPlainTextResponse clientSocket 400 [] "oidc state did not match"

handleOidcSession :: WebsocketRuntime -> Socket -> HttpRequest -> IO ()
handleOidcSession runtime clientSocket request =
  case lookupCookie oidcSessionCookieName request of
    Nothing -> sendPlainTextResponse clientSocket 401 [] "missing oidc session cookie"
    Just sessionId -> do
      sessionResult <-
        withRedisSocket
          (websocketRuntimeRedisConfig runtime)
          (\redisSocket -> loadOidcSession redisSocket sessionId)
      case sessionResult of
        Left err -> sendPlainTextResponse clientSocket 500 [] err
        Right Nothing -> sendPlainTextResponse clientSocket 401 [] "oidc session not found"
        Right (Just session) ->
          sendJsonResponse
            clientSocket
            200
            []
            ( object
                [ "authenticated" .= True
                , "carrier" .= oidcSessionCarrier session
                , "issuer" .= oidcSessionIssuer session
                , "subject" .= oidcSessionSubject session
                , "preferred_username" .= oidcSessionPreferredUsername session
                , "expires_at" .= oidcSessionExpiryEpoch session
                ]
            )

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

resolveHttpPort :: WorkloadOptions -> IO Int
resolveHttpPort options = do
  maybeModernPort <- lookupEnv "PRODBOX_PORT"
  maybeLegacyPort <- lookupEnv "PRODBOX_HTTP_PORT"
  pure $
    case firstJust [workloadPort options, maybeModernPort >>= readMaybeInt, maybeLegacyPort >>= readMaybeInt] of
      Just portNumber | portNumber > 0 -> portNumber
      _ -> 8080

resolveWorkloadLogLevel :: WorkloadOptions -> IO String
resolveWorkloadLogLevel options = do
  maybeEnvLogLevel <- lookupEnv "PRODBOX_LOG_LEVEL"
  pure (fromMaybe "info" (workloadLogLevel options <|> maybeEnvLogLevel))

resolvePodName :: IO String
resolvePodName = do
  maybePodName <- lookupEnv "HOSTNAME"
  pure $
    case maybePodName of
      Just podName | podName /= "" -> podName
      _ -> "unknown-pod"

resolveWebsocketRuntime :: WorkloadMode -> String -> IO (Either String (Maybe WebsocketRuntime))
resolveWebsocketRuntime mode podName =
  case mode of
    WorkloadApi -> pure (Right Nothing)
    WorkloadWebsocket -> do
      redisConfigResult <- resolveRedisConfig
      oidcConfigResult <- resolveOidcConfig
      case (redisConfigResult, oidcConfigResult) of
        (Left err, _) -> pure (Left err)
        (_, Left err) -> pure (Left err)
        (Right redisConfig, Right oidcConfig) -> do
          runtimeState <-
            newTVarIO
              WebsocketServerState
                { serverDraining = False
                , serverNextConnectionId = 0
                , serverCloseRequests = Map.empty
                }
          pure
            ( Right
                ( Just
                    WebsocketRuntime
                      { websocketRuntimePodName = podName
                      , websocketRuntimeRedisConfig = redisConfig
                      , websocketRuntimeOidcConfig = oidcConfig
                      , websocketRuntimeState = runtimeState
                      }
                )
            )

resolveRedisConfig :: IO (Either String RedisConfig)
resolveRedisConfig = do
  maybeHost <- lookupEnv "PRODBOX_REDIS_HOST"
  maybePort <- lookupEnv "PRODBOX_REDIS_PORT"
  pure $
    case (maybeHost, maybePort) of
      (Just host, Just port)
        | host /= "" && port /= "" ->
            Right RedisConfig {redisHost = host, redisPort = port}
      _ ->
        Left
          "PRODBOX_REDIS_HOST and PRODBOX_REDIS_PORT must be set for websocket mode"

resolveOidcConfig :: IO (Either String OidcConfig)
resolveOidcConfig = do
  maybeIssuer <- lookupEnv "PRODBOX_OIDC_ISSUER"
  maybeClientId <- lookupEnv "PRODBOX_OIDC_CLIENT_ID"
  maybeClientSecret <- lookupEnv "PRODBOX_OIDC_CLIENT_SECRET"
  maybePublicBaseUrl <- lookupEnv "PRODBOX_OIDC_PUBLIC_BASE_URL"
  maybeTokenEndpoint <- lookupEnv "PRODBOX_OIDC_TOKEN_ENDPOINT"
  pure $
    case (maybeIssuer, maybeClientId, maybeClientSecret, maybePublicBaseUrl, maybeTokenEndpoint) of
      (Just issuer, Just clientId, Just clientSecret, Just publicBaseUrl, Just tokenEndpoint)
        | "" `notElem` [issuer, clientId, clientSecret, publicBaseUrl, tokenEndpoint] ->
            Right
              OidcConfig
                { oidcIssuer = issuer
                , oidcClientId = clientId
                , oidcClientSecret = clientSecret
                , oidcPublicBaseUrl = publicBaseUrl
                , oidcTokenEndpoint = tokenEndpoint
                }
      _ ->
        Left
          "PRODBOX_OIDC_ISSUER, PRODBOX_OIDC_CLIENT_ID, PRODBOX_OIDC_CLIENT_SECRET, PRODBOX_OIDC_PUBLIC_BASE_URL, and PRODBOX_OIDC_TOKEN_ENDPOINT must be set for websocket mode"

openListeningSocket :: Int -> IO (Either String Socket)
openListeningSocket port = do
  addressInfos <-
    getAddrInfo
      (Just defaultHints {addrFlags = [AI_PASSIVE], addrProtocol = 0})
      Nothing
      (Just (show port))
  case addressInfos of
    addressInfo : _ -> do
      listenSocket <- socket (addrFamily addressInfo) Stream (addrProtocol addressInfo)
      setSocketOption listenSocket ReuseAddr 1
      bind listenSocket (addrAddress addressInfo)
      pure (Right listenSocket)
    [] -> pure (Left ("no listen addresses resolved for port " ++ show port))

isWebsocketUpgradeRequest :: HttpRequest -> Bool
isWebsocketUpgradeRequest request =
  httpRequestMethod request == "GET"
    && requestPathOnly request == "/ws"
    && headerContainsToken "connection" "upgrade" request
    && normalizedHeaderValue "upgrade" request == Just "websocket"
    && Map.member "sec-websocket-key" (httpRequestHeaders request)

headerContainsToken :: String -> String -> HttpRequest -> Bool
headerContainsToken headerName expectedToken request =
  case normalizedHeaderValue headerName request of
    Nothing -> False
    Just headerValue ->
      expectedToken `elem` map trim (splitOn ',' headerValue)

normalizedHeaderValue :: String -> HttpRequest -> Maybe String
normalizedHeaderValue headerName request =
  fmap (map toLowerAscii) (Map.lookup headerName (httpRequestHeaders request))

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

lookupCookie :: String -> HttpRequest -> Maybe String
lookupCookie cookieName request =
  case Map.lookup "cookie" (httpRequestHeaders request) of
    Nothing -> Nothing
    Just cookieHeader ->
      Map.lookup
        cookieName
        ( Map.fromList
            [ let (namePart, valuePart) = splitOnFirst '=' (trim cookiePart)
               in (namePart, valuePart)
            | cookiePart <- splitOn ';' cookieHeader
            , trim cookiePart /= ""
            ]
        )

requireSession :: Map String String -> Either String String
requireSession queryParams =
  case Map.lookup "session" queryParams of
    Just sessionId | sessionId /= "" -> Right sessionId
    _ -> Left "session query parameter is required"

authorizeWebsocketRequest :: HttpRequest -> Either String AuthorizedToken
authorizeWebsocketRequest request =
  case Map.lookup "authorization" (httpRequestHeaders request) of
    Just headerValue ->
      case stripPrefix "Bearer " headerValue of
        Just tokenValue -> parseAuthorizedToken tokenValue
        Nothing -> Left "Authorization header must use Bearer token syntax"
    Nothing -> Left "Authorization header is required"

parseAuthorizedToken :: String -> Either String AuthorizedToken
parseAuthorizedToken tokenValue = do
  payload <- decodeJwtPayload tokenValue
  subjectValue <- requireStringClaim "sub" payload
  issuerValue <- requireStringClaim "iss" payload
  routeClaimValue <- requireStringClaim "prodbox_route" payload
  expiryValue <- requireIntClaim "exp" payload
  let usernameValue = optionalStringClaim "preferred_username" payload
  whenEither (routeClaimValue /= "websocket") "JWT route claim must equal websocket"
  pure
    AuthorizedToken
      { authorizedRawToken = tokenValue
      , authorizedSubject = subjectValue
      , authorizedPreferredUsername = usernameValue
      , authorizedIssuer = issuerValue
      , authorizedRouteClaim = routeClaimValue
      , authorizedExpiryEpoch = expiryValue
      }

tokenExpired :: AuthorizedToken -> IO Bool
tokenExpired token = do
  currentEpoch <- currentUnixEpochSeconds
  pure (currentEpoch >= authorizedExpiryEpoch token)

decodeJwtPayload :: String -> Either String Value
decodeJwtPayload tokenValue =
  case splitOn '.' tokenValue of
    [_headerText, payloadText, _signatureText] -> do
      decodedPayload <-
        mapLeft
          (const "JWT payload was not valid base64url")
          (Base64Url.decode (BS8.pack (padBase64Url payloadText)))
      mapLeft
        (const "JWT payload was not valid JSON")
        (eitherDecode (BL.fromStrict decodedPayload))
    _ -> Left "JWT did not contain three dot-separated sections"

padBase64Url :: String -> String
padBase64Url value =
  value ++ replicate paddingLength '='
 where
  remainder = length value `mod` 4
  paddingLength =
    case remainder of
      0 -> 0
      2 -> 2
      3 -> 1
      _ -> 0

requireStringClaim :: String -> Value -> Either String String
requireStringClaim claimName payload =
  case payload of
    Object obj ->
      case KeyMap.lookup (Key.fromString claimName) obj of
        Just (String claimValue) -> Right (Text.unpack claimValue)
        _ -> Left ("JWT payload did not include string claim `" ++ claimName ++ "`")
    _ -> Left "JWT payload was not a JSON object"

optionalStringClaim :: String -> Value -> Maybe String
optionalStringClaim claimName payload =
  case payload of
    Object obj ->
      case KeyMap.lookup (Key.fromString claimName) obj of
        Just (String claimValue) -> Just (Text.unpack claimValue)
        _ -> Nothing
    _ -> Nothing

requireIntClaim :: String -> Value -> Either String Int
requireIntClaim claimName payload =
  case payload of
    Object obj ->
      case KeyMap.lookup (Key.fromString claimName) obj of
        Just (Number claimValue) ->
          case toBoundedInteger claimValue of
            Just intValue -> Right intValue
            Nothing -> Left ("JWT claim `" ++ claimName ++ "` was out of range")
        _ -> Left ("JWT payload did not include numeric claim `" ++ claimName ++ "`")
    _ -> Left "JWT payload was not a JSON object"

websocketAcceptKey :: HttpRequest -> Either String String
websocketAcceptKey request =
  case Map.lookup "sec-websocket-key" (httpRequestHeaders request) of
    Just clientKey
      | clientKey /= "" ->
          Right
            ( BS8.unpack
                ( Base64.encode
                    ( SHA1.hash
                        ( BS8.pack
                            (clientKey ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
                        )
                    )
                )
            )
    _ -> Left "Sec-WebSocket-Key header is required"

sendWebSocketHandshakeResponse :: Socket -> String -> IO ()
sendWebSocketHandshakeResponse clientSocket acceptKey =
  sendAll
    clientSocket
    ( BS8.pack
        ( concat
            [ "HTTP/1.1 101 Switching Protocols\r\n"
            , "Upgrade: websocket\r\n"
            , "Connection: Upgrade\r\n"
            , "Sec-WebSocket-Accept: "
            , acceptKey
            , "\r\n\r\n"
            ]
        )
    )

registerWebsocketConnection
  :: WebsocketRuntime -> IO (Either String (Int, TVar (Maybe ConnectionCloseReason)))
registerWebsocketConnection runtime = do
  closeVar <- newTVarIO Nothing
  atomically $ do
    currentState <- readTVar (websocketRuntimeState runtime)
    if serverDraining currentState
      then pure (Left "websocket runtime is draining")
      else do
        let connectionId = serverNextConnectionId currentState + 1
            nextState =
              currentState
                { serverNextConnectionId = connectionId
                , serverCloseRequests = Map.insert connectionId closeVar (serverCloseRequests currentState)
                }
        writeTVar (websocketRuntimeState runtime) nextState
        pure (Right (connectionId, closeVar))

unregisterWebsocketConnection :: WebsocketRuntime -> Int -> IO ()
unregisterWebsocketConnection runtime connectionId =
  atomically
    ( modifyTVar'
        (websocketRuntimeState runtime)
        ( \currentState -> currentState {serverCloseRequests = Map.delete connectionId (serverCloseRequests currentState)}
        )
    )

initiateServerDrain :: WebsocketRuntime -> IO ()
initiateServerDrain runtime = do
  closeVars <-
    atomically $ do
      currentState <- readTVar (websocketRuntimeState runtime)
      let nextState = currentState {serverDraining = True}
      writeTVar (websocketRuntimeState runtime) nextState
      pure (Map.elems (serverCloseRequests currentState))
  mapM_ (\closeVar -> atomically (writeTVar closeVar (Just CloseForDrain))) closeVars

waitForDrainCompletion :: WebsocketRuntime -> Int -> IO ()
waitForDrainCompletion runtime timeoutMicroseconds = go timeoutMicroseconds
 where
  go remaining
    | remaining <= 0 = pure ()
    | otherwise = do
        connectionCount <- Map.size . serverCloseRequests <$> readTVarIO (websocketRuntimeState runtime)
        if connectionCount == 0
          then pure ()
          else do
            threadDelay 250000
            go (remaining - 250000)

prepareWebsocketSession :: Socket -> String -> String -> Bool -> IO (Either String ())
prepareWebsocketSession redisSocket podName sessionId resetRequested = do
  whenReset <-
    if resetRequested then redisDel redisSocket (messagesKey sessionId) else pure (Right ())
  case whenReset of
    Left err -> pure (Left err)
    Right () -> do
      statusResult <- redisSet redisSocket (sessionStatusKey sessionId) "active"
      case statusResult of
        Left err -> pure (Left err)
        Right () -> redisSet redisSocket (connectedByKey sessionId) podName

publishWebsocketMessage
  :: Socket -> AuthorizedToken -> String -> String -> String -> IO (Either String Int)
publishWebsocketMessage redisSocket token podName sessionId messageBody = do
  currentEpoch <- currentUnixEpochSeconds
  if currentEpoch >= authorizedExpiryEpoch token
    then pure (Left "token expired; reconnect required")
    else do
      statusResult <- redisGet redisSocket (sessionStatusKey sessionId)
      case statusResult of
        Right (Just "revoked") -> pure (Left "session authorization changed; reconnect required")
        _ -> do
          connectedByResult <- redisSet redisSocket (connectedByKey sessionId) podName
          case connectedByResult of
            Left err -> pure (Left err)
            Right () ->
              redisRpush
                redisSocket
                (messagesKey sessionId)
                ( renderWebsocketMessage
                    WebsocketMessage {websocketMessageSenderPod = podName, websocketMessagePayload = messageBody}
                )

revokeWebsocketSession :: Socket -> AuthorizedToken -> String -> IO (Either String ())
revokeWebsocketSession redisSocket token sessionId =
  if authorizedRouteClaim token /= "websocket"
    then pure (Left "websocket route claim is required for revocation")
    else redisSet redisSocket (sessionStatusKey sessionId) "revoked"

websocketSessionState :: Socket -> String -> String -> IO (Either String Value)
websocketSessionState redisSocket currentPod sessionId = do
  connectedByResult <- redisGet redisSocket (connectedByKey sessionId)
  case connectedByResult of
    Left err -> pure (Left err)
    Right connectedBy -> do
      messagesResult <- redisLrange redisSocket (messagesKey sessionId) 0 (-1)
      case messagesResult of
        Left err -> pure (Left err)
        Right renderedMessages ->
          pure
            ( Right
                ( object
                    [ "mode" .= ("websocket" :: String)
                    , "pod" .= currentPod
                    , "session" .= sessionId
                    , "connectedBy" .= connectedBy
                    , "messages"
                        .= [ websocketMessagePayload parsedMessage
                           | renderedMessage <- renderedMessages
                           , Right parsedMessage <- [parseWebsocketMessage renderedMessage]
                           ]
                    ]
                )
            )

flushNewWebsocketMessages :: Socket -> Socket -> String -> Int -> IO (Either String Int)
flushNewWebsocketMessages redisSocket clientSocket sessionId lastSeenCount = do
  messagesResult <- redisLrange redisSocket (messagesKey sessionId) lastSeenCount (-1)
  case messagesResult of
    Left err -> pure (Left err)
    Right newRenderedMessages -> do
      mapM_ (flushRenderedWebsocketMessage clientSocket) newRenderedMessages
      pure (Right (lastSeenCount + length newRenderedMessages))

flushRenderedWebsocketMessage :: Socket -> String -> IO ()
flushRenderedWebsocketMessage clientSocket renderedMessage =
  case parseWebsocketMessage renderedMessage of
    Left _ -> pure ()
    Right messageValue ->
      sendWebSocketText
        clientSocket
        ( renderJsonText
            ( object
                [ "type" .= ("message" :: String)
                , "pod" .= websocketMessageSenderPod messageValue
                , "message" .= websocketMessagePayload messageValue
                ]
            )
        )

readWebSocketFrame :: Socket -> IORef BS.ByteString -> IO (Either String WebSocketFrame)
readWebSocketFrame clientSocket bufferRef = do
  headerBytesResult <- readBufferedBytes clientSocket bufferRef 2
  case headerBytesResult of
    Left err -> pure (Left err)
    Right headerBytes -> do
      let firstByte = BS.index headerBytes 0
          secondByte = BS.index headerBytes 1
          opcode = firstByte .&. 0x0F
          masked = (secondByte .&. 0x80) /= 0
          shortLength = fromIntegral (secondByte .&. 0x7F) :: Int
      unlessEither ((firstByte .&. 0x80) /= 0) "fragmented websocket frames are not supported" $ do
        unlessEither masked "client websocket frame was not masked" $ do
          extendedLengthInfoResult <- resolveFrameLength clientSocket bufferRef shortLength
          case extendedLengthInfoResult of
            Left err -> pure (Left err)
            Right payloadLength -> do
              maskKeyResult <- readBufferedBytes clientSocket bufferRef 4
              case maskKeyResult of
                Left err -> pure (Left err)
                Right maskKey -> do
                  payloadResult <- readBufferedBytes clientSocket bufferRef payloadLength
                  case payloadResult of
                    Left err -> pure (Left err)
                    Right maskedPayload -> pure (decodeWebSocketFrame opcode (applyMask maskKey maskedPayload))

resolveFrameLength :: Socket -> IORef BS.ByteString -> Int -> IO (Either String Int)
resolveFrameLength clientSocket bufferRef shortLength =
  case shortLength of
    126 -> do
      lengthBytesResult <- readBufferedBytes clientSocket bufferRef 2
      pure (decodeLength16 <$> lengthBytesResult)
    127 -> do
      lengthBytesResult <- readBufferedBytes clientSocket bufferRef 8
      pure (decodeLength64 <$> lengthBytesResult)
    _ -> pure (Right shortLength)

decodeWebSocketFrame :: Word8 -> BS.ByteString -> Either String WebSocketFrame
decodeWebSocketFrame opcode payload
  | opcode == 0x1 = Right (WebSocketTextFrame (BS8.unpack payload))
  | opcode == 0x8 =
      let (maybeCode, reasonText) = decodeClosePayload payload
       in Right (WebSocketCloseFrame maybeCode reasonText)
  | opcode == 0x9 = Right (WebSocketPingFrame payload)
  | opcode == 0xA = Right (WebSocketPongFrame payload)
  | otherwise = Left "unsupported websocket opcode"

sendWebSocketText :: Socket -> String -> IO ()
sendWebSocketText clientSocket payloadText =
  sendWebSocketDataFrame clientSocket 0x1 (BS8.pack payloadText)

sendWebSocketClose :: Socket -> Int -> String -> IO ()
sendWebSocketClose clientSocket closeCode reasonText = do
  let closePayload =
        BS.pack
          [ fromIntegral ((closeCode `shiftR` 8) .&. 0xFF)
          , fromIntegral (closeCode .&. 0xFF)
          ]
          <> BS8.pack reasonText
  sendWebSocketDataFrame clientSocket 0x8 closePayload

sendWebSocketControlFrame :: Socket -> Int -> BS.ByteString -> IO ()
sendWebSocketControlFrame clientSocket opcode payload =
  sendWebSocketDataFrame clientSocket opcode payload

sendWebSocketDataFrame :: Socket -> Int -> BS.ByteString -> IO ()
sendWebSocketDataFrame clientSocket opcode payload = do
  let headerPrefix = BS.singleton (fromIntegral (0x80 .|. opcode))
      payloadLength = BS.length payload
      lengthBytes
        | payloadLength < 126 = BS.singleton (fromIntegral payloadLength)
        | payloadLength <= 65535 =
            BS.pack
              [ 126
              , fromIntegral ((payloadLength `shiftR` 8) .&. 0xFF)
              , fromIntegral (payloadLength .&. 0xFF)
              ]
        | otherwise =
            BS.pack
              ( 127
                  : [ fromIntegral ((payloadLength `shiftR` shiftAmount) .&. 0xFF)
                    | shiftAmount <- [56, 48, 40, 32, 24, 16, 8, 0]
                    ]
              )
  sendAll clientSocket (headerPrefix <> lengthBytes <> payload)

ensureBufferedBytes :: Socket -> IORef BS.ByteString -> Int -> IO (Either String BS.ByteString)
ensureBufferedBytes clientSocket bufferRef minimumLength = do
  currentBuffer <- readIORef bufferRef
  if BS.length currentBuffer >= minimumLength
    then pure (Right currentBuffer)
    else do
      chunk <- recv clientSocket 4096
      if BS.null chunk
        then pure (Left "websocket peer closed the connection")
        else do
          modifyIORef' bufferRef (<> chunk)
          ensureBufferedBytes clientSocket bufferRef minimumLength

readBufferedBytes :: Socket -> IORef BS.ByteString -> Int -> IO (Either String BS.ByteString)
readBufferedBytes clientSocket bufferRef byteCount = do
  bufferedResult <- ensureBufferedBytes clientSocket bufferRef byteCount
  case bufferedResult of
    Left err -> pure (Left err)
    Right buffered -> do
      let (prefixBytes, suffixBytes) = BS.splitAt byteCount buffered
      modifyIORef' bufferRef (const suffixBytes)
      pure (Right prefixBytes)

applyMask :: BS.ByteString -> BS.ByteString -> BS.ByteString
applyMask maskKey payload =
  BS.pack
    [ BS.index payload index `xor` BS.index maskKey (index `mod` 4)
    | index <- [0 .. BS.length payload - 1]
    ]

decodeLength16 :: BS.ByteString -> Int
decodeLength16 bytes =
  (fromIntegral (BS.index bytes 0) `shiftL` 8)
    .|. fromIntegral (BS.index bytes 1)

decodeLength64 :: BS.ByteString -> Int
decodeLength64 bytes =
  foldl'
    (\accumulator byteValue -> (accumulator `shiftL` 8) .|. fromIntegral byteValue)
    0
    (BS.unpack bytes)

decodeClosePayload :: BS.ByteString -> (Maybe Int, String)
decodeClosePayload payload
  | BS.length payload < 2 = (Nothing, "")
  | otherwise =
      let closeCode =
            (fromIntegral (BS.index payload 0) `shiftL` 8)
              .|. fromIntegral (BS.index payload 1)
          reasonText = BS8.unpack (BS.drop 2 payload)
       in (Just closeCode, reasonText)

withAuthorizedWebsocketToken :: HttpRequest -> Socket -> (AuthorizedToken -> IO ()) -> IO ()
withAuthorizedWebsocketToken request clientSocket action =
  case authorizeWebsocketRequest request of
    Left err -> sendPlainTextResponse clientSocket 401 [] err
    Right token -> action token

exchangeAuthorizationCode :: WebsocketRuntime -> String -> IO (Either String OidcTokenResponse)
exchangeAuthorizationCode runtime authorizationCode = do
  let config = websocketRuntimeOidcConfig runtime
      callbackUrl = oidcPublicBaseUrl config ++ "/oidc/callback"
      tokenUrl = oidcTokenEndpoint config
  outputResult <-
    captureCommand
      CommandSpec
        { commandPath = "curl"
        , commandArguments =
            [ "-sS"
            , "--fail-with-body"
            , "-X"
            , "POST"
            , "--data-urlencode"
            , "grant_type=authorization_code"
            , "--data-urlencode"
            , "client_id=" ++ oidcClientId config
            , "--data-urlencode"
            , "client_secret=" ++ oidcClientSecret config
            , "--data-urlencode"
            , "code=" ++ authorizationCode
            , "--data-urlencode"
            , "redirect_uri=" ++ callbackUrl
            , tokenUrl
            ]
        , commandEnvironment = Nothing
        , commandWorkingDirectory = Nothing
        }
  pure $
    case outputResult of
      Failure err -> Left ("failed to exchange authorization code with Keycloak: " ++ trim err)
      Success output ->
        case processExitCode output of
          ExitFailure _ ->
            Left
              ( "failed to exchange authorization code with Keycloak: "
                  ++ trim (processStdout output ++ " " ++ processStderr output)
              )
          ExitSuccess ->
            case eitherDecode (BL8.pack (processStdout output)) of
              Left _ -> Left "token exchange response was not valid JSON"
              Right payload -> parseOidcTokenResponse payload

parseOidcTokenResponse :: Value -> Either String OidcTokenResponse
parseOidcTokenResponse payload =
  case payload of
    Object obj -> do
      accessTokenValue <-
        case KeyMap.lookup "access_token" obj of
          Just (String tokenText) -> Right (Text.unpack tokenText)
          _ -> Left "token exchange response did not contain access_token"
      idTokenValue <-
        case KeyMap.lookup "id_token" obj of
          Just (String tokenText) -> Right (Text.unpack tokenText)
          _ -> Left "token exchange response did not contain id_token"
      expiresInValue <-
        case KeyMap.lookup "expires_in" obj of
          Just (Number secondsValue) ->
            case toBoundedInteger secondsValue of
              Just secondsInt -> Right secondsInt
              Nothing -> Left "token exchange expires_in was out of range"
          _ -> Left "token exchange response did not contain expires_in"
      pure
        OidcTokenResponse
          { oidcTokenAccessToken = accessTokenValue
          , oidcTokenIdToken = idTokenValue
          , oidcTokenExpiresInSeconds = expiresInValue
          }
    _ -> Left "token exchange response was not a JSON object"

buildOidcSessionFromTokens :: OidcTokenResponse -> Either String OidcSession
buildOidcSessionFromTokens tokenResponse = do
  claimsPayload <- decodeJwtPayload (oidcTokenIdToken tokenResponse)
  issuerValue <- requireStringClaim "iss" claimsPayload
  subjectValue <- requireStringClaim "sub" claimsPayload
  expiryValue <- requireIntClaim "exp" claimsPayload
  let usernameValue = optionalStringClaim "preferred_username" claimsPayload
  sessionIdValue <- Right ("oidc-" ++ show expiryValue ++ "-" ++ take 12 (subjectValue ++ repeat 'x'))
  pure
    OidcSession
      { oidcSessionId = sessionIdValue
      , oidcSessionCarrier = "cookie-session"
      , oidcSessionIssuer = issuerValue
      , oidcSessionSubject = subjectValue
      , oidcSessionPreferredUsername = usernameValue
      , oidcSessionAccessToken = oidcTokenAccessToken tokenResponse
      , oidcSessionIdToken = oidcTokenIdToken tokenResponse
      , oidcSessionExpiryEpoch = expiryValue
      }

storeOidcSession :: Socket -> OidcSession -> IO (Either String ())
storeOidcSession redisSocket session =
  redisSet redisSocket (oidcSessionKey (oidcSessionId session)) (renderOidcSession session)

loadOidcSession :: Socket -> String -> IO (Either String (Maybe OidcSession))
loadOidcSession redisSocket sessionId = do
  rawValueResult <- redisGet redisSocket (oidcSessionKey sessionId)
  pure $
    case rawValueResult of
      Left err -> Left err
      Right Nothing -> Right Nothing
      Right (Just rawValue) ->
        case eitherDecode (BL8.pack rawValue) of
          Left _ -> Left "oidc session payload was not valid JSON"
          Right payload -> Just <$> parseOidcSession payload

parseOidcSession :: Value -> Either String OidcSession
parseOidcSession payload =
  case payload of
    Object obj -> do
      sessionIdValue <- requireJsonString "session_id" obj
      carrierValue <- requireJsonString "carrier" obj
      issuerValue <- requireJsonString "issuer" obj
      subjectValue <- requireJsonString "subject" obj
      accessTokenValue <- requireJsonString "access_token" obj
      idTokenValue <- requireJsonString "id_token" obj
      expiryValue <- requireJsonInt "expires_at" obj
      let usernameValue = optionalJsonString "preferred_username" obj
      pure
        OidcSession
          { oidcSessionId = sessionIdValue
          , oidcSessionCarrier = carrierValue
          , oidcSessionIssuer = issuerValue
          , oidcSessionSubject = subjectValue
          , oidcSessionPreferredUsername = usernameValue
          , oidcSessionAccessToken = accessTokenValue
          , oidcSessionIdToken = idTokenValue
          , oidcSessionExpiryEpoch = expiryValue
          }
    _ -> Left "oidc session payload was not a JSON object"

renderOidcSession :: OidcSession -> String
renderOidcSession session =
  BL8.unpack
    ( encode
        ( object
            [ "session_id" .= oidcSessionId session
            , "carrier" .= oidcSessionCarrier session
            , "issuer" .= oidcSessionIssuer session
            , "subject" .= oidcSessionSubject session
            , "preferred_username" .= oidcSessionPreferredUsername session
            , "access_token" .= oidcSessionAccessToken session
            , "id_token" .= oidcSessionIdToken session
            , "expires_at" .= oidcSessionExpiryEpoch session
            ]
        )
    )

renderWebsocketMessage :: WebsocketMessage -> String
renderWebsocketMessage messageValue =
  BL8.unpack
    ( encode
        ( object
            [ "pod" .= websocketMessageSenderPod messageValue
            , "message" .= websocketMessagePayload messageValue
            ]
        )
    )

parseWebsocketMessage :: String -> Either String WebsocketMessage
parseWebsocketMessage rawValue =
  case eitherDecode (BL8.pack rawValue) of
    Left _ -> Left "websocket message payload was not valid JSON"
    Right payload ->
      case payload of
        Object obj ->
          WebsocketMessage
            <$> requireJsonString "pod" obj
            <*> requireJsonString "message" obj
        _ -> Left "websocket message payload was not a JSON object"

requireJsonString :: String -> KeyMap.KeyMap Value -> Either String String
requireJsonString fieldName obj =
  case KeyMap.lookup (Key.fromString fieldName) obj of
    Just (String fieldValue) -> Right (Text.unpack fieldValue)
    _ -> Left ("JSON object did not contain string field `" ++ fieldName ++ "`")

optionalJsonString :: String -> KeyMap.KeyMap Value -> Maybe String
optionalJsonString fieldName obj =
  case KeyMap.lookup (Key.fromString fieldName) obj of
    Just (String fieldValue) -> Just (Text.unpack fieldValue)
    _ -> Nothing

requireJsonInt :: String -> KeyMap.KeyMap Value -> Either String Int
requireJsonInt fieldName obj =
  case KeyMap.lookup (Key.fromString fieldName) obj of
    Just (Number fieldValue) ->
      case toBoundedInteger fieldValue of
        Just intValue -> Right intValue
        Nothing -> Left ("JSON object field `" ++ fieldName ++ "` was out of range")
    _ -> Left ("JSON object did not contain integer field `" ++ fieldName ++ "`")

withRedisSocket :: RedisConfig -> (Socket -> IO (Either String a)) -> IO (Either String a)
withRedisSocket config action = do
  socketResult <- openRedisSocket config
  case socketResult of
    Left err -> pure (Left err)
    Right redisSocket -> bracket (pure redisSocket) close action

openRedisSocket :: RedisConfig -> IO (Either String Socket)
openRedisSocket config = do
  addressInfos <-
    getAddrInfo
      (Just defaultHints {addrProtocol = 0})
      (Just (redisHost config))
      (Just (redisPort config))
  case addressInfos of
    addressInfo : _ -> do
      redisSocket <- socket (addrFamily addressInfo) Stream (addrProtocol addressInfo)
      connect redisSocket (addrAddress addressInfo)
      pure (Right redisSocket)
    [] -> pure (Left ("no Redis addresses resolved for " ++ redisHost config ++ ":" ++ redisPort config))

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

redisLlen :: Socket -> String -> IO (Either String Int)
redisLlen redisSocket keyName = do
  replyResult <- sendRedisCommand redisSocket ["LLEN", keyName]
  pure $
    case replyResult of
      Left err -> Left err
      Right (RedisInteger listLength) -> Right listLength
      Right reply -> Left ("unexpected Redis LLEN reply: " ++ show reply)

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

readHttpRequest :: Socket -> IO (Either String (HttpRequest, BS.ByteString))
readHttpRequest clientSocket = go ""
 where
  go accumulated = do
    chunk <- recv clientSocket 4096
    let next = accumulated ++ BS8.unpack chunk
    if BS.null chunk
      then
        if next == ""
          then pure (Left "request payload was empty")
          else pure (parseHttpRequestWithRemainder next)
      else case splitOnSubstring "\r\n\r\n" next of
        Nothing -> go next
        Just (headerText, bodyText) ->
          let expectedBodyLength = contentLengthFromHeaderText headerText
           in if length bodyText >= expectedBodyLength
                then pure (parseHttpRequestWithRemainder next)
                else go next

parseHttpRequestWithRemainder :: String -> Either String (HttpRequest, BS.ByteString)
parseHttpRequestWithRemainder rawRequest =
  case splitOnSubstring "\r\n\r\n" rawRequest of
    Nothing -> Left "could not parse HTTP headers"
    Just (headerText, bodyAndTrailingText) ->
      let expectedBodyLength = contentLengthFromHeaderText headerText
          (bodyText, trailingText) = splitAt expectedBodyLength bodyAndTrailingText
       in if length bodyText < expectedBodyLength
            then Left "request body was truncated"
            else do
              request <- parseHttpRequest (headerText ++ "\r\n\r\n" ++ bodyText)
              pure (request, BS8.pack trailingText)

parseHttpRequest :: String -> Either String HttpRequest
parseHttpRequest rawRequest =
  case splitOnSubstring "\r\n\r\n" rawRequest of
    Nothing -> Left "could not parse HTTP headers"
    Just (headerText, bodyText) ->
      case linesWithoutCarriageReturn headerText of
        requestLine : headerLines ->
          case words requestLine of
            [methodName, requestPath, _httpVersion] ->
              Right
                HttpRequest
                  { httpRequestMethod = methodName
                  , httpRequestPath = requestPath
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

sendPlainTextResponse :: Socket -> Int -> [(String, String)] -> String -> IO ()
sendPlainTextResponse clientSocket statusCode extraHeaders bodyText =
  sendResponse clientSocket statusCode "text/plain; charset=utf-8" extraHeaders (encodeUtf8 bodyText)

sendJsonResponse :: Socket -> Int -> [(String, String)] -> Value -> IO ()
sendJsonResponse clientSocket statusCode extraHeaders payload =
  sendResponse clientSocket statusCode "application/json" extraHeaders (encode payload)

sendResponse :: Socket -> Int -> String -> [(String, String)] -> BL.ByteString -> IO ()
sendResponse clientSocket statusCode contentType extraHeaders payload = do
  let headerLines =
        [ "HTTP/1.1 " ++ show statusCode ++ " " ++ httpStatusText statusCode
        , "Content-Type: " ++ contentType
        , "Content-Length: " ++ show (BL.length payload)
        ]
          ++ map (\(headerName, headerValue) -> headerName ++ ": " ++ headerValue) extraHeaders
          ++ ["Connection: close", "", ""]
  sendAll clientSocket (BS8.pack (intercalate "\r\n" headerLines))
  sendAll clientSocket (BL.toStrict payload)

httpStatusText :: Int -> String
httpStatusText statusCode =
  case statusCode of
    101 -> "Switching Protocols"
    200 -> "OK"
    302 -> "Found"
    400 -> "Bad Request"
    401 -> "Unauthorized"
    403 -> "Forbidden"
    404 -> "Not Found"
    500 -> "Internal Server Error"
    503 -> "Service Unavailable"
    _ -> "Response"

takeLine :: String -> Maybe (String, String)
takeLine value = splitOnSubstring "\r\n" value

takeBytes :: Int -> String -> Maybe (String, String)
takeBytes byteCount value =
  let (prefixText, suffixText) = splitAt byteCount value
   in if length prefixText /= byteCount || take 2 suffixText /= "\r\n"
        then Nothing
        else Just (prefixText, drop 2 suffixText)

oidcStateCookieName :: String
oidcStateCookieName = "prodbox_oidc_state"

oidcSessionCookieName :: String
oidcSessionCookieName = "prodbox_oidc_session"

sessionStatusKey :: String -> String
sessionStatusKey sessionId = "prodbox:websocket:" ++ sessionId ++ ":status"

connectedByKey :: String -> String
connectedByKey sessionId = "prodbox:websocket:" ++ sessionId ++ ":connected-by"

messagesKey :: String -> String
messagesKey sessionId = "prodbox:websocket:" ++ sessionId ++ ":messages"

oidcSessionKey :: String -> String
oidcSessionKey sessionId = "prodbox:oidc:session:" ++ sessionId

renderMode :: WorkloadMode -> String
renderMode mode =
  case mode of
    WorkloadApi -> "api"
    WorkloadWebsocket -> "websocket"

renderJsonText :: Value -> String
renderJsonText = BL8.unpack . encode

renderSetCookie :: String -> String -> String -> Bool -> String
renderSetCookie cookieName cookieValue cookiePath httpOnlyEnabled =
  intercalate
    "; "
    ( [cookieName ++ "=" ++ cookieValue, "Path=" ++ cookiePath, "Secure", "SameSite=Lax"]
        ++ ["HttpOnly" | httpOnlyEnabled]
    )

clearCookie :: String -> String -> String
clearCookie cookieName cookiePath =
  intercalate
    "; "
    [ cookieName ++ "="
    , "Path=" ++ cookiePath
    , "Max-Age=0"
    , "Secure"
    , "SameSite=Lax"
    , "HttpOnly"
    ]

nonceWithPrefix :: String -> IO String
nonceWithPrefix prefix = do
  now <- getPOSIXTime
  pure (prefix ++ "-" ++ show (round (now * 1000000) :: Integer))

urlEncode :: String -> String
urlEncode =
  concatMap encodeCharacter
 where
  encodeCharacter character
    | isUnreservedUrlCharacter character = [character]
    | otherwise = "%" ++ toHex (fromEnum character)

  isUnreservedUrlCharacter character =
    isAsciiLower character
      || isAsciiUpper character
      || isDigit character
      || character `elem` ("-._~" :: String)

  toHex value =
    let highNibble = (value `shiftR` 4) .&. 0xF
        lowNibble = value .&. 0xF
     in [hexDigit highNibble, hexDigit lowNibble]

  hexDigit nibble
    | nibble < 10 = toEnum (fromEnum '0' + nibble)
    | otherwise = toEnum (fromEnum 'A' + (nibble - 10))

encodeUtf8 :: String -> BL.ByteString
encodeUtf8 = BL.fromStrict . BS8.pack

currentUnixEpochSeconds :: IO Int
currentUnixEpochSeconds = round <$> getPOSIXTime

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

trim :: String -> String
trim = reverse . dropWhile (== ' ') . reverse . dropWhile (== ' ')

toLowerAscii :: Char -> Char
toLowerAscii character
  | isAsciiUpper character = toEnum (fromEnum character + 32)
  | otherwise = character

readMaybeInt :: String -> Maybe Int
readMaybeInt value =
  case reads value of
    [(parsedValue, "")] -> Just parsedValue
    _ -> Nothing

tryCloseSocket :: Socket -> IO ()
tryCloseSocket socketHandle = do
  _ <- try (gracefulClose socketHandle 1000) :: IO (Either SomeException ())
  pure ()

unlessEither :: Bool -> String -> IO (Either String a) -> IO (Either String a)
unlessEither condition message action =
  if condition
    then action
    else pure (Left message)

whenEither :: Bool -> String -> Either String ()
whenEither condition message =
  if condition
    then Left message
    else Right ()

mapLeft :: (leftA -> leftB) -> Either leftA rightA -> Either leftB rightA
mapLeft mapper eitherValue =
  case eitherValue of
    Left err -> Left (mapper err)
    Right value -> Right value

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)
firstJust :: [Maybe a] -> Maybe a
firstJust [] = Nothing
firstJust (value : remaining) =
  case value of
    Just _ -> value
    Nothing -> firstJust remaining
