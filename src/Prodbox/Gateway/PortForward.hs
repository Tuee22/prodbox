module Prodbox.Gateway.PortForward
  ( GatewayPortForwardError (..)
  , GatewayServicePortForward (..)
  , gatewayServicePortForwardSubprocess
  , renderGatewayPortForwardError
  , validateGatewayServicePortForward
  , withGatewayServicePortForward
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.MVar
  ( newEmptyMVar
  , putMVar
  , takeMVar
  )
import Control.Exception
  ( IOException
  , bracket
  , displayException
  , try
  )
import Control.Monad (void)
import Data.Char
  ( isAsciiLower
  , isDigit
  )
import Data.Text qualified as Text
import Network.Socket
  ( Family (AF_INET)
  , SockAddr (SockAddrInet)
  , SocketOption (ReuseAddr)
  , SocketType (Stream)
  , bind
  , close
  , defaultProtocol
  , getSocketName
  , setSocketOption
  , socket
  , tupleToHostAddress
  , withSocketsDo
  )
import Prodbox.Error (errorMsg)
import Prodbox.Gateway.Client qualified as GatewayClient
import Prodbox.Gateway.Types (PeerEndpoint)
import Prodbox.Retry (retryDelayMicros)
import Prodbox.Subprocess
  ( Subprocess (..)
  , startBackgroundProcess
  , stopBackgroundProcess
  , waitBackgroundProcess
  )

-- | Coordinates for reaching a gateway daemon through the Kubernetes API
-- server. The optional environment is where callers bind the intended
-- substrate's @KUBECONFIG@; no ambient cluster-selection policy is hidden in
-- this bracket.
data GatewayServicePortForward = GatewayServicePortForward
  { gatewayPortForwardNamespace :: String
  , gatewayPortForwardServiceName :: String
  , gatewayPortForwardRemotePort :: Int
  , gatewayPortForwardEnvironment :: Maybe [(String, String)]
  , gatewayPortForwardWorkingDirectory :: Maybe FilePath
  }
  deriving (Eq, Show)

-- | Ordinary, operator-actionable failures returned by the port-forward
-- bracket. Unexpected asynchronous exceptions still propagate after the
-- background process has been stopped by 'bracket'.
data GatewayPortForwardError
  = GatewayPortForwardInvalidSpec String
  | GatewayPortForwardPortReservationFailed String
  | GatewayPortForwardProcessStartFailed String
  | GatewayPortForwardDaemonUnavailable GatewayClient.GatewayError
  deriving (Eq, Show)

renderGatewayPortForwardError :: GatewayPortForwardError -> String
renderGatewayPortForwardError err = case err of
  GatewayPortForwardInvalidSpec detail ->
    "invalid gateway Service port-forward specification: " ++ detail
  GatewayPortForwardPortReservationFailed detail ->
    "failed to reserve a loopback TCP port for the gateway Service port-forward: "
      ++ detail
  GatewayPortForwardProcessStartFailed detail ->
    "failed to start the gateway Service port-forward: " ++ detail
  GatewayPortForwardDaemonUnavailable gatewayError ->
    "gateway Service port-forward started, but daemon readiness failed: "
      ++ GatewayClient.renderGatewayError gatewayError

-- | Reject malformed Kubernetes coordinates and impossible TCP ports before
-- starting @kubectl@. Namespace and Service names are DNS-1123 labels.
validateGatewayServicePortForward
  :: GatewayServicePortForward -> Either GatewayPortForwardError ()
validateGatewayServicePortForward spec
  | not (validDns1123Label (gatewayPortForwardNamespace spec)) =
      Left
        ( GatewayPortForwardInvalidSpec
            "namespace must be a non-empty DNS-1123 label of at most 63 characters"
        )
  | not (validDns1123Label (gatewayPortForwardServiceName spec)) =
      Left
        ( GatewayPortForwardInvalidSpec
            "Service name must be a non-empty DNS-1123 label of at most 63 characters"
        )
  | remotePort < 1 || remotePort > 65535 =
      Left
        ( GatewayPortForwardInvalidSpec
            "remote port must be between 1 and 65535"
        )
  | otherwise = Right ()
 where
  remotePort = gatewayPortForwardRemotePort spec

-- | Pure command renderer used by the production bracket and unit tests.
gatewayServicePortForwardSubprocess
  :: GatewayServicePortForward -> Int -> Subprocess
gatewayServicePortForwardSubprocess spec localPort =
  Subprocess
    { subprocessPath = "kubectl"
    , subprocessArguments =
        [ "--namespace"
        , gatewayPortForwardNamespace spec
        , "port-forward"
        , "service/" ++ gatewayPortForwardServiceName spec
        , show localPort ++ ":" ++ show (gatewayPortForwardRemotePort spec)
        ]
    , subprocessEnvironment = gatewayPortForwardEnvironment spec
    , subprocessWorkingDirectory = gatewayPortForwardWorkingDirectory spec
    }

-- | Open a loopback-only, ephemeral host port to the supplied Kubernetes
-- gateway Service, wait until the daemon answers its typed state endpoint, and
-- keep a forwarding process alive for the callback. Kubernetes resolves a
-- Service port-forward to one Pod; if that Pod is replaced during the
-- pre-Vault to full-mode rollout, the supervisor re-establishes @kubectl@ on
-- the same local port and the daemon retry policy bridges the short gap.
-- Readiness uses the
-- shared daemon-restart transient classifier and bounded retry policy; a
-- definite HTTP rejection fails immediately. The background process is always
-- stopped after acquisition, readiness failure, callback completion, or a
-- callback exception.
withGatewayServicePortForward
  :: GatewayServicePortForward
  -> (PeerEndpoint -> IO value)
  -> IO (Either GatewayPortForwardError value)
withGatewayServicePortForward spec action =
  case validateGatewayServicePortForward spec of
    Left err -> pure (Left err)
    Right () -> do
      reservationResult <- reserveLoopbackTcpPort
      case reservationResult of
        Left err -> pure (Left err)
        Right localPort ->
          withSupervisedPortForward localPort
 where
  startPortForward localPort = do
    startResult <-
      startBackgroundProcess
        (gatewayServicePortForwardSubprocess spec localPort)
    pure $ case startResult of
      Left err ->
        Left
          ( GatewayPortForwardProcessStartFailed
              (Text.unpack (errorMsg err))
          )
      Right process -> Right process

  withSupervisedPortForward localPort = do
    firstStart <- newEmptyMVar
    withAsync (supervisePortForward localPort firstStart True) $ \_ -> do
      startResult <- takeMVar firstStart
      case startResult of
        Left err -> pure (Left err)
        Right () -> runWithPortForward localPort

  supervisePortForward localPort firstStart reportFirst = do
    shouldRestart <-
      bracket
        (startPortForward localPort)
        cleanupPortForward
        (observePortForward firstStart reportFirst)
    if shouldRestart
      then supervisePortForward localPort firstStart False
      else pure ()

  observePortForward firstStart reportFirst startResult = do
    if reportFirst
      then putMVar firstStart (void startResult)
      else pure ()
    case startResult of
      Left _ -> pure False
      Right process -> do
        _ <- waitBackgroundProcess process
        threadDelay
          (retryDelayMicros GatewayClient.daemonRestartBridgeRetryPolicy 0)
        pure True

  cleanupPortForward startResult =
    case startResult of
      Left _ -> pure ()
      Right process -> stopBackgroundProcess process

  runWithPortForward localPort = do
    let endpoint = GatewayClient.hostLoopbackGatewayEndpoint localPort
    readinessResult <-
      GatewayClient.retryGatewayTransient
        GatewayClient.daemonRestartBridgeRetryPolicy
        (GatewayClient.queryState endpoint)
    case readinessResult of
      Left err -> pure (Left (GatewayPortForwardDaemonUnavailable err))
      Right _ -> Right <$> action endpoint

reserveLoopbackTcpPort :: IO (Either GatewayPortForwardError Int)
reserveLoopbackTcpPort = do
  portResult <-
    try
      ( withSocketsDo $
          bracket
            (socket AF_INET Stream defaultProtocol)
            close
            ( \reservedSocket -> do
                setSocketOption reservedSocket ReuseAddr 1
                bind
                  reservedSocket
                  (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
                socketAddress <- getSocketName reservedSocket
                case socketAddress of
                  SockAddrInet port _ -> pure (fromIntegral port)
                  _ ->
                    ioError
                      (userError "reserved socket did not have an IPv4 address")
            )
      )
      :: IO (Either IOException Int)
  pure $ case portResult of
    Left err ->
      Left
        ( GatewayPortForwardPortReservationFailed
            (displayException err)
        )
    Right port -> Right port

validDns1123Label :: String -> Bool
validDns1123Label [] = False
validDns1123Label value@(firstCharacter : _) =
  length value <= 63
    && isAlphaNumeric firstCharacter
    && lastCharacterIsAlphaNumeric value
    && all isLabelCharacter value
 where
  isAlphaNumeric character = isAsciiLower character || isDigit character
  isLabelCharacter character = isAlphaNumeric character || character == '-'
  lastCharacterIsAlphaNumeric characters = case characters of
    [] -> False
    [character] -> isAlphaNumeric character
    _ : rest -> lastCharacterIsAlphaNumeric rest
