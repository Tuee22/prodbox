{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Host access to the Bootstrap Broker through one loopback-only Kubernetes
-- Service port-forward and one short-lived custom-audience TokenRequest.
--
-- The Kubernetes namespace, Service, remote named port, client
-- ServiceAccount, audience, and HTTP endpoint family are compiled. Callers
-- choose only the intended kubectl environment and an idempotency key; they
-- cannot redirect the bearer credential to a hostname, Gateway, or NodePort.
module Prodbox.Bootstrap.Broker.PortForward
  ( BrokerHostConnection (..)
  , BrokerHostConnectionError (..)
  , brokerHostNamespace
  , brokerHostPortForwardSubprocess
  , renderBrokerHostConnectionError
  , withBrokerHostConnection
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( IOException
  , bracket
  , displayException
  , try
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
import Prodbox.Bootstrap.Broker.Client
  ( BrokerCallContext
  , BrokerClientContextError
  , BrokerEndpoint
  , BrokerError
  , mkLoopbackBrokerEndpoint
  , queryBrokerHealth
  , renderBrokerClientContextError
  , renderBrokerError
  , requestHostBrokerCallContextWithEnvironment
  )
import Prodbox.Bootstrap.Broker.Request (IdempotencyKey)
import Prodbox.Error (errorMsg)
import Prodbox.Subprocess
  ( BackgroundProcess
  , Subprocess (..)
  , startBackgroundProcess
  , stopBackgroundProcess
  )

data BrokerHostConnection = BrokerHostConnection
  { brokerHostEnvironment :: !(Maybe [(String, String)])
  , brokerHostWorkingDirectory :: !FilePath
  }
  deriving stock (Eq, Show)

data BrokerHostConnectionError
  = BrokerHostPortReservationFailed !String
  | BrokerHostEndpointInvalid !String
  | BrokerHostCredentialFailed !BrokerClientContextError
  | BrokerHostPortForwardStartFailed !String
  | BrokerHostReadinessFailed !BrokerError
  deriving stock (Eq, Show)

renderBrokerHostConnectionError :: BrokerHostConnectionError -> String
renderBrokerHostConnectionError err = case err of
  BrokerHostPortReservationFailed detail ->
    "reserve Bootstrap Broker loopback port: " ++ detail
  BrokerHostEndpointInvalid detail ->
    "construct Bootstrap Broker loopback endpoint: " ++ detail
  BrokerHostCredentialFailed detail ->
    "mint Bootstrap Broker TokenRequest credential: "
      ++ renderBrokerClientContextError detail
  BrokerHostPortForwardStartFailed detail ->
    "start Bootstrap Broker Service port-forward: " ++ detail
  BrokerHostReadinessFailed detail ->
    "Bootstrap Broker Service is not ready: " ++ renderBrokerError detail

brokerHostNamespace :: Text.Text
brokerHostNamespace = "bootstrap-broker"

brokerHostService :: String
brokerHostService = "bootstrap-broker"

brokerHostRemotePortName :: String
brokerHostRemotePortName = "broker"

-- | Pure, exact command projection. Explicit @--address 127.0.0.1@ prevents
-- kubectl defaults or future configuration from widening the listener.
brokerHostPortForwardSubprocess
  :: BrokerHostConnection -> Int -> Subprocess
brokerHostPortForwardSubprocess connection localPort =
  Subprocess
    { subprocessPath = "kubectl"
    , subprocessArguments =
        [ "--namespace"
        , Text.unpack brokerHostNamespace
        , "port-forward"
        , "--address"
        , "127.0.0.1"
        , "service/" ++ brokerHostService
        , show localPort ++ ":" ++ brokerHostRemotePortName
        ]
    , subprocessEnvironment = brokerHostEnvironment connection
    , subprocessWorkingDirectory = Just (brokerHostWorkingDirectory connection)
    }

-- | Mint one credential, open one loopback port-forward, prove the Broker is
-- answering through it, run the callback, and always stop kubectl. The same
-- opaque call context is valid only for this bracket and is never returned.
withBrokerHostConnection
  :: BrokerHostConnection
  -> IdempotencyKey
  -> (BrokerEndpoint -> BrokerCallContext -> IO value)
  -> IO (Either BrokerHostConnectionError value)
withBrokerHostConnection connection idempotencyKey action = do
  reserved <- reserveLoopbackPort
  case reserved of
    Left detail -> pure (Left (BrokerHostPortReservationFailed detail))
    Right localPort ->
      case mkLoopbackBrokerEndpoint (fromIntegral localPort) of
        Left detail -> pure (Left (BrokerHostEndpointInvalid detail))
        Right endpoint -> do
          credentialResult <-
            requestHostBrokerCallContextWithEnvironment
              (brokerHostEnvironment connection)
              (brokerHostWorkingDirectory connection)
              brokerHostNamespace
              idempotencyKey
          case credentialResult of
            Left detail -> pure (Left (BrokerHostCredentialFailed detail))
            Right context ->
              bracket
                (startForward connection localPort)
                cleanupForward
                (runWithForward endpoint context)
 where
  runWithForward _ _ (Left err) = pure (Left err)
  runWithForward endpoint context (Right _) = do
    readiness <- waitForBroker endpoint context brokerReadinessAttempts
    case readiness of
      Left detail -> pure (Left (BrokerHostReadinessFailed detail))
      Right () -> Right <$> action endpoint context

brokerReadinessAttempts :: Int
brokerReadinessAttempts = 240

waitForBroker
  :: BrokerEndpoint
  -> BrokerCallContext
  -> Int
  -> IO (Either BrokerError ())
waitForBroker endpoint context remaining = do
  observed <- queryBrokerHealth endpoint context
  case observed of
    Right _ -> pure (Right ())
    Left err
      | remaining <= 1 -> pure (Left err)
      | otherwise -> do
          threadDelay 250000
          waitForBroker endpoint context (remaining - 1)

startForward
  :: BrokerHostConnection
  -> Int
  -> IO (Either BrokerHostConnectionError BackgroundProcess)
startForward connection localPort = do
  started <-
    startBackgroundProcess
      (brokerHostPortForwardSubprocess connection localPort)
  pure $ case started of
    Left err ->
      Left (BrokerHostPortForwardStartFailed (Text.unpack (errorMsg err)))
    Right process -> Right process

cleanupForward
  :: Either BrokerHostConnectionError BackgroundProcess
  -> IO ()
cleanupForward result = case result of
  Left _ -> pure ()
  Right process -> stopBackgroundProcess process

reserveLoopbackPort :: IO (Either String Int)
reserveLoopbackPort = do
  attempted <-
    try
      ( withSocketsDo $
          bracket
            (socket AF_INET Stream defaultProtocol)
            close
            ( \reserved -> do
                setSocketOption reserved ReuseAddr 1
                bind reserved (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
                address <- getSocketName reserved
                case address of
                  SockAddrInet port _ -> pure (fromIntegral port)
                  _ -> ioError (userError "reserved socket was not IPv4")
            )
      )
      :: IO (Either IOException Int)
  pure (either (Left . displayException) Right attempted)
