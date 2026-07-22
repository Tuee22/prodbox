{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Bounded loopback HTTP runtime for the Bootstrap Broker.
--
-- The listener accepts one request per connection.  One accept producer feeds
-- a bounded queue consumed by a compile-time-sized worker pool; request
-- handlers never fork.  Each accepted connection receives one absolute
-- monotonic deadline before it enters the queue, so queue wait, request read,
-- interpretation, response serialization, and socket write all spend the same
-- budget.
module Prodbox.Bootstrap.Broker.Server
  ( BrokerAuthenticator (..)
  , BrokerAuthenticationRequest (..)
  , BrokerAuthenticationFailure (..)
  , BrokerTransportCredential
  , brokerTransportCredentialLength
  , withBrokerTransportCredential
  , failClosedBrokerAuthenticator
  , BrokerInterpreter (..)
  , failClosedBrokerInterpreter
  , BrokerServerHooks (..)
  , noBrokerServerHooks
  , BrokerRequestContext (..)
  , BrokerRequestAuthentication (..)
  , BrokerRequestBody
  , BrokerRequestBodyError (..)
  , mkBrokerRequestBody
  , brokerRequestBodyLength
  , withBrokerRequestBody
  , BrokerReplyStatus (..)
  , BrokerReply
  , mkBrokerReply
  , brokerReplyStatus
  , brokerReplyBodyLength
  , withBrokerReplyBody
  , maximumBrokerReplyBytes
  , brokerFixedWorkerCount
  , BrokerServerPhase (..)
  , BrokerServerSnapshot (..)
  , BrokerServerError (..)
  , renderBrokerServerError
  , BrokerServerHandle
  , brokerRouteOperationTag
  , projectBrokerRequest
  , startBrokerServer
  , startBrokerServerWithHooks
  , runBrokerServer
  , beginBrokerDrain
  , forceBrokerDrain
  , waitBrokerServer
  , brokerServerSnapshot
  )
where

import Control.Concurrent.Async
  ( Async
  , async
  , cancel
  , cancelMany
  , waitCatch
  , waitCatchSTM
  )
import Control.Concurrent.STM
  ( STM
  , TBQueue
  , TMVar
  , TVar
  , atomically
  , isFullTBQueue
  , lengthTBQueue
  , modifyTVar'
  , newEmptyTMVar
  , newEmptyTMVarIO
  , newTBQueueIO
  , newTVarIO
  , readTBQueue
  , readTMVar
  , readTVar
  , readTVarIO
  , retry
  , tryPutTMVar
  , writeTBQueue
  , writeTVar
  )
import Control.Exception
  ( IOException
  , SomeAsyncException
  , SomeException
  , bracketOnError
  , finally
  , fromException
  , mask
  , throwIO
  , try
  )
import Control.Monad (replicateM, replicateM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char (isDigit, isSpace, toLower)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Clock (getMonotonicTimeNSec)
import Network.Socket
  ( Family (AF_INET, AF_INET6)
  , PortNumber
  , SockAddr (..)
  , Socket
  , SocketOption (ReuseAddr)
  , SocketType (Stream)
  , accept
  , bind
  , close
  , defaultProtocol
  , hostAddress6ToTuple
  , hostAddressToTuple
  , listen
  , setSocketOption
  , socket
  , tupleToHostAddress
  , tupleToHostAddress6
  , withSocketsDo
  )
import Network.Socket.ByteString (recv, sendAll)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Admission
  ( AdmissionDisposition (..)
  , AdmissionLane
  , AdmissionLimits
  , AdmissionRefusal (..)
  , AdmissionResult (..)
  , AdmissionTicket (..)
  , admitRequest
  , beginDraining
  , cancelAdmission
  , completeAdmission
  , emptyAdmissionLane
  , forgetCancelledAdmission
  , forgetCompletedAdmission
  , mkAdmissionLimits
  , startAdmission
  )
import Prodbox.Bootstrap.Broker.Request
  ( BrokerRequest (..)
  , BrokerServiceIdentity
  , IdempotencyKey
  , RequestDigest
  , RequestMetadata (..)
  , mkBrokerServiceIdentity
  , mkIdempotencyKey
  , mkRequestDigest
  , requestDigestForBytes
  )
import Prodbox.Bootstrap.Broker.Request qualified as Request
import Prodbox.Bootstrap.Broker.Routes
  ( BrokerBodyRequirement (..)
  , BrokerHttpMethod (..)
  , BrokerRoute (..)
  , brokerRouteBodyRequirement
  , brokerRouteForPath
  , brokerRouteForRequest
  , brokerRouteMethod
  )
import Prodbox.Bootstrap.Broker.Settings
  ( BootstrapBrokerSettings
  , LoopbackAddress (..)
  , brokerDrainDeadlineMilliseconds
  , brokerLimits
  , brokerListenAddress
  , brokerListenPort
  , brokerListener
  , brokerMaximumRequestBodyBytes
  , brokerQueueCapacity
  , brokerRequestDeadlineMilliseconds
  , brokerServiceIdentity
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  , RemainingDuration (..)
  , deadlineAtOffset
  , deadlineInstant
  , monotonicInstantFromMicros
  , monotonicInstantMicros
  )
import System.Posix.Signals
  ( Handler (Catch)
  , installHandler
  , sigINT
  , sigTERM
  )
import System.Timeout (timeout)

-- | The number of request workers is deliberately not configurable.  A
-- deployment changes capacity by changing broker replicas, not by opening an
-- unbounded in-process concurrency dial.
brokerFixedWorkerCount :: Int
brokerFixedWorkerCount = 4

maximumBrokerReplyBytes :: Natural
maximumBrokerReplyBytes = 64 * 1024

-- | Byte-preserving request body whose ordinary rendering is always redacted.
-- The constructor is private so only a bounded ingress can create one.
newtype BrokerRequestBody = BrokerRequestBody ByteString
  deriving stock (Eq)

instance Show BrokerRequestBody where
  show body =
    "BrokerRequestBody <redacted:"
      ++ show (brokerRequestBodyLength body)
      ++ " bytes>"

brokerRequestBodyLength :: BrokerRequestBody -> Natural
brokerRequestBodyLength (BrokerRequestBody body) = fromIntegral (BS.length body)

data BrokerRequestBodyError
  = BrokerRequestBodyForbidden !BrokerRoute
  | BrokerRequestBodyEmpty !BrokerRoute
  | BrokerRequestBodyTooLarge !Natural !Natural
  deriving stock (Eq, Show)

-- | Construct a request body under the exact route shape and configured
-- ingress limit used by the loopback server.  Bodyless routes cannot acquire
-- a synthetic value through this boundary.
mkBrokerRequestBody
  :: BootstrapBrokerSettings
  -> BrokerRoute
  -> ByteString
  -> Either BrokerRequestBodyError BrokerRequestBody
mkBrokerRequestBody settings route body
  | brokerRouteBodyRequirement route == BrokerBodyForbidden =
      Left (BrokerRequestBodyForbidden route)
  | actualBytes == 0 = Left (BrokerRequestBodyEmpty route)
  | actualBytes > maximumBytes =
      Left (BrokerRequestBodyTooLarge maximumBytes actualBytes)
  | otherwise = Right (BrokerRequestBody body)
 where
  maximumBytes = brokerMaximumRequestBodyBytes (brokerLimits settings)
  actualBytes = fromIntegral (BS.length body)

withBrokerRequestBody :: BrokerRequestBody -> (ByteString -> value) -> value
withBrokerRequestBody (BrokerRequestBody body) use = use body

data BrokerReplyStatus
  = BrokerReplyOk
  | BrokerReplyAccepted
  | BrokerReplyBadRequest
  | BrokerReplyUnauthorized
  | BrokerReplyNotFound
  | BrokerReplyMethodNotAllowed
  | BrokerReplyPayloadTooLarge
  | BrokerReplyConflict
  | BrokerReplyTooManyRequests
  | BrokerReplyServiceUnavailable
  | BrokerReplyGatewayTimeout
  | BrokerReplyInternalError
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | A bounded reply.  Its bytes are not exposed through 'Show', preventing an
-- interpreter exception or diagnostic from accidentally logging a payload.
data BrokerReply = BrokerReply
  { brokerReplyStatus :: !BrokerReplyStatus
  , brokerReplyBytes :: !ByteString
  }
  deriving stock (Eq)

instance Show BrokerReply where
  show reply =
    "BrokerReply {status = "
      ++ show (brokerReplyStatus reply)
      ++ ", body = <redacted:"
      ++ show (brokerReplyBodyLength reply)
      ++ " bytes>}"

mkBrokerReply :: BrokerReplyStatus -> ByteString -> Either String BrokerReply
mkBrokerReply status body
  | fromIntegral (BS.length body) > maximumBrokerReplyBytes =
      Left "broker reply exceeds the compiled response bound"
  | otherwise = Right (BrokerReply status body)

brokerReplyBodyLength :: BrokerReply -> Natural
brokerReplyBodyLength = fromIntegral . BS.length . brokerReplyBytes

withBrokerReplyBody :: BrokerReply -> (ByteString -> value) -> value
withBrokerReplyBody reply use = use (brokerReplyBytes reply)

-- | The sole operation interpreter port.  It receives a member of the closed
-- route registry and an optional bounded opaque body; there is no generic URL,
-- object-store coordinate, KV path, provider selector, or command escape.
data BrokerRequestContext = BrokerRequestContext
  { brokerRequestAcceptedAt :: !MonotonicInstant
  , brokerRequestDeadline :: !Deadline
  , brokerRequestCallerAddress :: !LoopbackAddress
  , brokerRequestAuthentication :: !BrokerRequestAuthentication
  }
  deriving stock (Eq, Show)

data BrokerRequestAuthentication
  = BrokerProbeRequest
  | BrokerAuthenticatedRequest !BrokerServiceIdentity
  deriving stock (Eq, Show)

-- | Opaque, bounded authentication material read at the transport boundary.
-- It has no 'Show' or JSON instance and is never passed to the operation
-- interpreter.
newtype BrokerTransportCredential = BrokerTransportCredential ByteString
  deriving stock (Eq)

brokerTransportCredentialLength :: BrokerTransportCredential -> Natural
brokerTransportCredentialLength (BrokerTransportCredential credential) =
  fromIntegral (BS.length credential)

withBrokerTransportCredential
  :: BrokerTransportCredential -> (ByteString -> value) -> value
withBrokerTransportCredential (BrokerTransportCredential credential) use = use credential

data BrokerAuthenticationRequest = BrokerAuthenticationRequest
  { authenticationRoute :: !BrokerRoute
  , authenticationOperation :: !Request.BrokerOperationTag
  , authenticationClaimedIdentity :: !BrokerServiceIdentity
  , authenticationExpectedServiceIdentity :: !BrokerServiceIdentity
  , authenticationIdempotencyKey :: !IdempotencyKey
  , authenticationRequestBodyDigest :: !RequestDigest
  , authenticationCallerAddress :: !LoopbackAddress
  , authenticationDeadline :: !Deadline
  , authenticationCredential :: !BrokerTransportCredential
  }

data BrokerAuthenticationFailure
  = BrokerAuthenticationRejected
  | BrokerAuthenticationUnavailable
  deriving stock (Eq, Show)

newtype BrokerAuthenticator = BrokerAuthenticator
  { authenticateBrokerCaller
      :: BrokerAuthenticationRequest
      -> IO (Either BrokerAuthenticationFailure BrokerServiceIdentity)
  }

failClosedBrokerAuthenticator :: BrokerAuthenticator
failClosedBrokerAuthenticator =
  BrokerAuthenticator (const (pure (Left BrokerAuthenticationRejected)))

newtype BrokerInterpreter = BrokerInterpreter
  { interpretBrokerRequest
      :: BrokerRequestContext
      -> BrokerRoute
      -> Maybe BrokerRequestBody
      -> IO BrokerReply
  }

failClosedBrokerInterpreter :: BrokerInterpreter
failClosedBrokerInterpreter =
  BrokerInterpreter (\_context _route _body -> pure unavailableReply)

-- | In-memory scheduling seams used by deterministic lifecycle proofs.  The
-- production runtime always installs 'noBrokerServerHooks'.  A hook executes
-- inside the worker-acquisition STM transaction, so retrying it cannot expose
-- a dequeued connection before that connection is counted as active.
newtype BrokerServerHooks = BrokerServerHooks
  { brokerBeforeWorkerAccounting :: STM ()
  }

noBrokerServerHooks :: BrokerServerHooks
noBrokerServerHooks = BrokerServerHooks {brokerBeforeWorkerAccounting = pure ()}

data BrokerServerPhase
  = BrokerServing
  | BrokerDraining
  | BrokerForceDraining
  | BrokerStopped
  deriving stock (Eq, Ord, Show)

data BrokerServerSnapshot = BrokerServerSnapshot
  { snapshotPhase :: !BrokerServerPhase
  , snapshotQueuedConnections :: !Natural
  , snapshotActiveConnections :: !Natural
  , snapshotIdempotencyEntries :: !Natural
  }
  deriving stock (Eq, Show)

data BrokerServerError
  = BrokerListenerUnavailable
  | BrokerListenerFailed
  | BrokerDrainDeadlineExceeded
  | BrokerForcedShutdown
  deriving stock (Eq, Show)

renderBrokerServerError :: BrokerServerError -> String
renderBrokerServerError err = case err of
  BrokerListenerUnavailable ->
    "bootstrap broker could not open its configured loopback listener"
  BrokerListenerFailed ->
    "bootstrap broker loopback listener stopped unexpectedly"
  BrokerDrainDeadlineExceeded ->
    "bootstrap broker drain deadline elapsed before admitted work completed"
  BrokerForcedShutdown ->
    "bootstrap broker was force-drained by a second termination signal"

data BrokerServerHandle = BrokerServerHandle
  { handleRuntime :: !BrokerRuntime
  , handleManager :: !(Async ())
  , handleDone :: !(TMVar (Either BrokerServerError ()))
  }

data BrokerRuntime = BrokerRuntime
  { runtimeSettings :: !BootstrapBrokerSettings
  , runtimeExpectedServiceIdentity :: !BrokerServiceIdentity
  , runtimeAdmissionLimits :: !AdmissionLimits
  , runtimeAuthenticator :: !BrokerAuthenticator
  , runtimeInterpreter :: !BrokerInterpreter
  , runtimeListener :: !Socket
  , runtimeQueue :: !(TBQueue (Maybe QueuedConnection))
  , runtimePhase :: !(TVar BrokerServerPhase)
  , runtimeActive :: !(TVar Natural)
  , runtimeAdmission :: !(TVar AdmissionLane)
  , runtimeIdempotency :: !(TVar IdempotencyState)
  , runtimeHooks :: !BrokerServerHooks
  }

data QueuedConnection = QueuedConnection
  { queuedSocket :: !Socket
  , queuedAcceptedAtMicros :: !Natural
  , queuedPeer :: !LoopbackAddress
  }

data IdempotencyState = IdempotencyState
  { idempotencyEntries :: !(Map IdempotencyKey RuntimeIdempotencyEntry)
  , idempotencyOrder :: ![IdempotencyKey]
  }

data RuntimeIdempotencyEntry
  = RuntimeRequestRunning !(TMVar BrokerReply)
  | RuntimeRequestCompleted !RequestDigest !BrokerReply

data IdempotencyClaim
  = ClaimOwner !AdmissionTicket !(TMVar BrokerReply)
  | ClaimWait !(TMVar BrokerReply)
  | ClaimCached !BrokerReply
  | ClaimRefused !BrokerReply

data AcceptOutcome
  = AcceptStopped
  | AcceptFailed

data ManagerTrigger
  = ManagerListenerSettled !(Either SomeException AcceptOutcome)
  | ManagerDrainRequested

newtype DrainDeadline = DrainDeadline Natural

-- | Open the validated listener and start the fixed runtime.  Startup failures
-- are deliberately categorical: exception text can contain environment data
-- and is never reflected to an RPC caller.
startBrokerServer
  :: BootstrapBrokerSettings
  -> BrokerAuthenticator
  -> BrokerInterpreter
  -> IO (Either BrokerServerError BrokerServerHandle)
startBrokerServer settings =
  startBrokerServerWithHooks settings noBrokerServerHooks

startBrokerServerWithHooks
  :: BootstrapBrokerSettings
  -> BrokerServerHooks
  -> BrokerAuthenticator
  -> BrokerInterpreter
  -> IO (Either BrokerServerError BrokerServerHandle)
startBrokerServerWithHooks settings hooks authenticator interpreter = withSocketsDo $
  case runtimeFoundation settings of
    Left _ -> pure (Left BrokerListenerUnavailable)
    Right (expectedServiceIdentity, admissionLimits) -> do
      opened <- try (openListener settings) :: IO (Either SomeException Socket)
      case opened of
        Left _ -> pure (Left BrokerListenerUnavailable)
        Right listenerSocket -> do
          queue <- newTBQueueIO (fromIntegral (brokerQueueCapacity limits))
          phase <- newTVarIO BrokerServing
          active <- newTVarIO 0
          admission <- newTVarIO emptyAdmissionLane
          idempotency <- newTVarIO (IdempotencyState Map.empty [])
          done <- newEmptyTMVarIO
          let runtime =
                BrokerRuntime
                  { runtimeSettings = settings
                  , runtimeExpectedServiceIdentity = expectedServiceIdentity
                  , runtimeAdmissionLimits = admissionLimits
                  , runtimeAuthenticator = authenticator
                  , runtimeInterpreter = interpreter
                  , runtimeListener = listenerSocket
                  , runtimeQueue = queue
                  , runtimePhase = phase
                  , runtimeActive = active
                  , runtimeAdmission = admission
                  , runtimeIdempotency = idempotency
                  , runtimeHooks = hooks
                  }
          workers <- replicateM brokerFixedWorkerCount (async (workerLoop runtime))
          acceptThread <- async (acceptLoop runtime)
          manager <- async (managerLoop runtime acceptThread workers done)
          pure
            ( Right
                BrokerServerHandle
                  { handleRuntime = runtime
                  , handleManager = manager
                  , handleDone = done
                  }
            )
 where
  limits = brokerLimits settings

runtimeFoundation
  :: BootstrapBrokerSettings
  -> Either String (BrokerServiceIdentity, AdmissionLimits)
runtimeFoundation settings = do
  expectedServiceIdentity <- mkBrokerServiceIdentity (brokerServiceIdentity settings)
  admissionLimits <-
    mkAdmissionLimits
      (brokerMaximumRequestBodyBytes limits)
      (brokerQueueCapacity limits)
      estimate
      estimate
      estimate
  Right (expectedServiceIdentity, admissionLimits)
 where
  limits = brokerLimits settings
  totalBudget = 1000 * brokerRequestDeadlineMilliseconds limits
  estimate = max 1 (totalBudget `div` (brokerQueueCapacity limits + 4))

-- | Run until a graceful drain, a forced second signal, or a listener failure.
-- SIGTERM and SIGINT are equivalent: the first begins an absorbing drain and
-- the second forces cancellation of remaining work.
runBrokerServer
  :: BootstrapBrokerSettings
  -> BrokerAuthenticator
  -> BrokerInterpreter
  -> IO (Either BrokerServerError ())
runBrokerServer settings authenticator interpreter = do
  started <- startBrokerServer settings authenticator interpreter
  case started of
    Left err -> pure (Left err)
    Right handle -> do
      signalCount <- newTVarIO (0 :: Natural)
      let signalHandler = Catch $ do
            signalNumber <- atomically $ do
              previous <- readTVar signalCount
              let current = previous + 1
              writeTVar signalCount current
              pure current
            if signalNumber == 1
              then beginBrokerDrain handle
              else forceBrokerDrain handle
      oldTerm <- installHandler sigTERM signalHandler Nothing
      oldInt <- installHandler sigINT signalHandler Nothing
      waitBrokerServer handle
        `finally` do
          _ <- installHandler sigTERM oldTerm Nothing
          _ <- installHandler sigINT oldInt Nothing
          pure ()

beginBrokerDrain :: BrokerServerHandle -> IO ()
beginBrokerDrain handle = do
  atomically $ do
    phase <- readTVar (runtimePhase runtime)
    case phase of
      BrokerServing -> do
        writeTVar (runtimePhase runtime) BrokerDraining
        modifyTVar' (runtimeAdmission runtime) beginDraining
      BrokerDraining -> pure ()
      BrokerForceDraining -> pure ()
      BrokerStopped -> pure ()
  closeQuietly (runtimeListener runtime)
 where
  runtime = handleRuntime handle

forceBrokerDrain :: BrokerServerHandle -> IO ()
forceBrokerDrain handle = do
  atomically $ do
    phase <- readTVar (runtimePhase runtime)
    case phase of
      BrokerStopped -> pure ()
      _ -> do
        writeTVar (runtimePhase runtime) BrokerForceDraining
        modifyTVar' (runtimeAdmission runtime) beginDraining
  closeQuietly (runtimeListener runtime)
 where
  runtime = handleRuntime handle

waitBrokerServer :: BrokerServerHandle -> IO (Either BrokerServerError ())
waitBrokerServer handle = do
  outcome <- atomically (readTMVar (handleDone handle))
  let managerJoinMicros =
        1000
          * brokerDrainDeadlineMilliseconds
            (brokerLimits (runtimeSettings (handleRuntime handle)))
  void
    ( timeout
        (naturalToTimeoutMicros managerJoinMicros)
        (waitCatch (handleManager handle))
    )
  pure outcome

brokerServerSnapshot :: BrokerServerHandle -> IO BrokerServerSnapshot
brokerServerSnapshot handle = atomically $ do
  phase <- readTVar (runtimePhase runtime)
  queued <- lengthTBQueue (runtimeQueue runtime)
  active <- readTVar (runtimeActive runtime)
  entries <- idempotencyEntries <$> readTVar (runtimeIdempotency runtime)
  pure
    BrokerServerSnapshot
      { snapshotPhase = phase
      , snapshotQueuedConnections = fromIntegral queued
      , snapshotActiveConnections = active
      , snapshotIdempotencyEntries = fromIntegral (Map.size entries)
      }
 where
  runtime = handleRuntime handle

openListener :: BootstrapBrokerSettings -> IO Socket
openListener settings = do
  listenerSocket <- socket family Stream defaultProtocol
  bracketOnError
    (pure listenerSocket)
    close
    ( \sock -> do
        setSocketOption sock ReuseAddr 1
        bind sock address
        listen sock (fromIntegral (brokerQueueCapacity (brokerLimits settings)))
        pure sock
    )
 where
  listener = brokerListener settings
  port = fromIntegral (brokerListenPort listener) :: PortNumber
  (family, address) = case brokerListenAddress listener of
    LoopbackIpv4 ->
      (AF_INET, SockAddrInet port (tupleToHostAddress (127, 0, 0, 1)))
    LoopbackIpv6 ->
      ( AF_INET6
      , SockAddrInet6
          port
          0
          (tupleToHostAddress6 (0, 0, 0, 0, 0, 0, 0, 1))
          0
      )

acceptLoop :: BrokerRuntime -> IO AcceptOutcome
acceptLoop runtime = do
  phase <- readTVarIO (runtimePhase runtime)
  case phase of
    BrokerServing -> acceptOne
    BrokerDraining -> pure AcceptStopped
    BrokerForceDraining -> pure AcceptStopped
    BrokerStopped -> pure AcceptStopped
 where
  acceptOne = do
    accepted <- try (accept (runtimeListener runtime)) :: IO (Either IOException (Socket, SockAddr))
    case accepted of
      Left _ -> do
        phase <- readTVarIO (runtimePhase runtime)
        pure $ if phase == BrokerServing then AcceptFailed else AcceptStopped
      Right (clientSocket, peerAddress) -> do
        case exactLoopbackPeer peerAddress of
          Nothing -> closeQuietly clientSocket
          Just peer -> do
            acceptedAt <- monotonicMicros
            queued <- atomically $ do
              full <- isFullTBQueue (runtimeQueue runtime)
              if full
                then pure False
                else do
                  writeTBQueue
                    (runtimeQueue runtime)
                    (Just (QueuedConnection clientSocket acceptedAt peer))
                  pure True
            unless queued $ do
              sendBriefly clientSocket saturatedReply
              closeQuietly clientSocket
        acceptLoop runtime

exactLoopbackPeer :: SockAddr -> Maybe LoopbackAddress
exactLoopbackPeer peerAddress = case peerAddress of
  SockAddrInet _ host
    | hostAddressToTuple host == (127, 0, 0, 1) -> Just LoopbackIpv4
  SockAddrInet6 _ _ host _
    | hostAddress6ToTuple host == (0, 0, 0, 0, 0, 0, 0, 1) -> Just LoopbackIpv6
  _ -> Nothing

workerLoop :: BrokerRuntime -> IO ()
workerLoop runtime = mask $ \restore -> do
  work <- atomically (takeWorkerWork runtime)
  case work of
    Nothing -> pure ()
    Just connection -> do
      -- Keep cancellation masked from the atomic claim until the connection
      -- cleanup is installed.  The request body itself is restored to normal
      -- interruptibility so force-drain can cancel admitted work.
      outcome <-
        try
          ( restore (serveQueuedConnection runtime connection)
              `finally` do
                closeQuietly (queuedSocket connection)
                atomically (modifyTVar' (runtimeActive runtime) decreaseNatural)
          )
          :: IO (Either SomeException ())
      case outcome of
        Right () -> workerLoop runtime
        Left err -> case fromException err :: Maybe SomeAsyncException of
          Just _ -> throwIO err
          Nothing -> workerLoop runtime

-- | Dequeue and active-worker accounting are one linearizable claim.  Drain
-- settlement can therefore never observe the old queue-empty/active-zero
-- interleaving while a worker already owns a connection.
takeWorkerWork :: BrokerRuntime -> STM (Maybe QueuedConnection)
takeWorkerWork runtime = do
  work <- readTBQueue (runtimeQueue runtime)
  case work of
    Nothing -> pure Nothing
    Just connection -> do
      brokerBeforeWorkerAccounting (runtimeHooks runtime)
      modifyTVar' (runtimeActive runtime) (+ 1)
      pure (Just connection)

serveQueuedConnection :: BrokerRuntime -> QueuedConnection -> IO ()
serveQueuedConnection runtime connection = do
  now <- monotonicMicros
  let configuredBudget =
        1000 * brokerRequestDeadlineMilliseconds (brokerLimits (runtimeSettings runtime))
      acceptedAt = monotonicInstantFromMicros (queuedAcceptedAtMicros connection)
      deadline = deadlineAtOffset acceptedAt (RemainingDuration configuredBudget)
      deadlineMicros = monotonicInstantMicros (deadlineInstant deadline)
      context =
        BrokerRequestContext
          { brokerRequestAcceptedAt = acceptedAt
          , brokerRequestDeadline = deadline
          , brokerRequestCallerAddress = queuedPeer connection
          , brokerRequestAuthentication = BrokerProbeRequest
          }
  if now >= deadlineMicros
    then sendBriefly (queuedSocket connection) deadlineReply
    else do
      let remaining = deadlineMicros - now
      result <-
        timeout
          (naturalToTimeoutMicros remaining)
          (processConnection runtime context connection)
      case result of
        Just () -> pure ()
        Nothing -> sendBriefly (queuedSocket connection) deadlineReply

processConnection :: BrokerRuntime -> BrokerRequestContext -> QueuedConnection -> IO ()
processConnection runtime context connection = do
  parsed <-
    readWireRequest
      (brokerMaximumRequestBodyBytes (brokerLimits (runtimeSettings runtime)))
      (queuedSocket connection)
  reply <- case parsed of
    Left wireError -> pure (wireErrorReply wireError)
    Right request -> dispatchWireRequest runtime context request
  sendHttpReply (queuedSocket connection) reply

data WireRequest = WireRequest
  { wireMethod :: !BrokerHttpMethod
  , wirePath :: !String
  , wireHeaders :: !(Map ByteString [ByteString])
  , wireBody :: !ByteString
  }

data WireRequestError
  = WireMalformed
  | WireBodyTooLarge
  | WireUnsupportedTransferEncoding

maximumHeaderBytes :: Int
maximumHeaderBytes = 16 * 1024

readWireRequest :: Natural -> Socket -> IO (Either WireRequestError WireRequest)
readWireRequest maximumBodyBytes clientSocket = do
  headerResult <- receiveHeaderBlock clientSocket BS.empty
  case headerResult of
    Left err -> pure (Left err)
    Right (headerBlock, initialBody) ->
      case parseHeaderBlock maximumBodyBytes headerBlock of
        Left err -> pure (Left err)
        Right (method, path, headers, bodyLength) -> do
          bodyResult <- receiveBody clientSocket bodyLength initialBody
          pure
            ( WireRequest method path headers
                <$> bodyResult
            )

receiveHeaderBlock
  :: Socket
  -> ByteString
  -> IO (Either WireRequestError (ByteString, ByteString))
receiveHeaderBlock clientSocket buffered =
  let (headerBlock, delimiterAndRemainder) = BS.breakSubstring "\r\n\r\n" buffered
   in if not (BS.null delimiterAndRemainder)
        then pure (Right (headerBlock, BS.drop 4 delimiterAndRemainder))
        else
          if BS.length buffered >= maximumHeaderBytes
            then pure (Left WireMalformed)
            else do
              bytes <- recv clientSocket (min 4096 (maximumHeaderBytes - BS.length buffered))
              if BS.null bytes
                then pure (Left WireMalformed)
                else receiveHeaderBlock clientSocket (buffered <> bytes)

parseHeaderBlock
  :: Natural
  -> ByteString
  -> Either WireRequestError (BrokerHttpMethod, String, Map ByteString [ByteString], Int)
parseHeaderBlock maximumBodyBytes headerBlock = do
  (requestLine, headerLines) <- case BS8.split '\n' headerBlock of
    [] -> Left WireMalformed
    firstLine : remaining -> Right (stripCarriageReturn firstLine, map stripCarriageReturn remaining)
  (method, path) <- parseRequestLine requestLine
  headers <- foldHeaders headerLines
  whenEither (Map.member "transfer-encoding" headers) WireUnsupportedTransferEncoding
  contentLength <- parseContentLength headers
  whenEither (fromIntegral contentLength > maximumBodyBytes) WireBodyTooLarge
  Right (method, path, headers, contentLength)

parseRequestLine :: ByteString -> Either WireRequestError (BrokerHttpMethod, String)
parseRequestLine requestLine = case BS8.words requestLine of
  [methodBytes, pathBytes, version]
    | version == "HTTP/1.1" || version == "HTTP/1.0" -> do
        method <- case methodBytes of
          "GET" -> Right BrokerGet
          "POST" -> Right BrokerPost
          _ -> Left WireMalformed
        Right (method, BS8.unpack pathBytes)
  _ -> Left WireMalformed

foldHeaders :: [ByteString] -> Either WireRequestError (Map ByteString [ByteString])
foldHeaders = foldr addHeader (Right Map.empty)
 where
  addHeader line accumulated = do
    headers <- accumulated
    let (rawName, colonAndValue) = BS8.break (== ':') line
    if BS.null rawName || BS.null colonAndValue
      then Left WireMalformed
      else do
        let name = BS8.map toLower rawName
            value = trimHeaderValue (BS.drop 1 colonAndValue)
        if BS8.any (not . validHeaderNameCharacter) name
          then Left WireMalformed
          else Right (Map.insertWith (<>) name [value] headers)

validHeaderNameCharacter :: Char -> Bool
validHeaderNameCharacter char =
  char >= 'a' && char <= 'z'
    || isDigit char
    || char == '-'

trimHeaderValue :: ByteString -> ByteString
trimHeaderValue = BS8.dropWhileEnd isSpace . BS8.dropWhile isSpace

stripCarriageReturn :: ByteString -> ByteString
stripCarriageReturn line = fromMaybe line (BS.stripSuffix "\r" line)

parseContentLength :: Map ByteString [ByteString] -> Either WireRequestError Int
parseContentLength headers = case Map.lookup "content-length" headers of
  Nothing -> Right 0
  Just [raw]
    | not (BS.null raw) && BS8.all isDigit raw ->
        case reads (BS8.unpack raw) of
          [(value, "")]
            | value >= (0 :: Integer) && value <= fromIntegral (maxBound :: Int) ->
                Right (fromIntegral value)
          _ -> Left WireMalformed
  _ -> Left WireMalformed

receiveBody
  :: Socket
  -> Int
  -> ByteString
  -> IO (Either WireRequestError ByteString)
receiveBody clientSocket expected initial =
  collect [BS.take expected initial] (expected - min expected (BS.length initial))
 where
  collect chunks remaining
    | remaining == 0 = pure (Right (BS.concat (reverse chunks)))
    | otherwise = do
        bytes <- recv clientSocket (min 4096 remaining)
        if BS.null bytes
          then pure (Left WireMalformed)
          else collect (bytes : chunks) (remaining - BS.length bytes)

dispatchWireRequest
  :: BrokerRuntime
  -> BrokerRequestContext
  -> WireRequest
  -> IO BrokerReply
dispatchWireRequest runtime context request =
  case brokerRouteForRequest (wireMethod request) (wirePath request) of
    Nothing ->
      pure $ case brokerRouteForPath (wirePath request) of
        Nothing -> notFoundReply
        Just _ -> methodNotAllowedReply
    Just route ->
      case validateBodyShape (runtimeSettings runtime) route (wireBody request) of
        Left reply -> pure reply
        Right body ->
          if isProbeRoute route
            then dispatchProbe runtime context route body
            else dispatchRpc runtime context route body (wireHeaders request)

validateBodyShape
  :: BootstrapBrokerSettings
  -> BrokerRoute
  -> ByteString
  -> Either BrokerReply (Maybe BrokerRequestBody)
validateBodyShape settings route body = case brokerRouteBodyRequirement route of
  BrokerBodyForbidden
    | BS.null body -> Right Nothing
    | otherwise -> Left badRequestReply
  BrokerBodyRequired
    | otherwise ->
        case mkBrokerRequestBody settings route body of
          Left _ -> Left badRequestReply
          Right requestBody -> Right (Just requestBody)

isProbeRoute :: BrokerRoute -> Bool
isProbeRoute route = case route of
  BrokerHealth -> True
  BrokerReadiness -> True
  _ -> False

dispatchProbe
  :: BrokerRuntime
  -> BrokerRequestContext
  -> BrokerRoute
  -> Maybe BrokerRequestBody
  -> IO BrokerReply
dispatchProbe runtime context route body = do
  phase <- readTVarIO (runtimePhase runtime)
  if route == BrokerReadiness && phase /= BrokerServing
    then pure unavailableReply
    else invokeInterpreter runtime context route body

dispatchRpc
  :: BrokerRuntime
  -> BrokerRequestContext
  -> BrokerRoute
  -> Maybe BrokerRequestBody
  -> Map ByteString [ByteString]
  -> IO BrokerReply
dispatchRpc runtime context route body headers =
  case validateRpcHeaders runtime body headers of
    Left reply -> pure reply
    Right (claimedIdentity, credential, idempotencyKey, requestDigest) -> do
      authenticated <-
        authenticateRpc
          runtime
          context
          route
          claimedIdentity
          credential
          idempotencyKey
          requestDigest
      case authenticated of
        Left reply -> pure reply
        Right authorizedCallerIdentity ->
          -- Mask before the admission claim so there is no async-exception
          -- window between installing a running idempotency entry and
          -- installing its terminal transition.  Only the interpreter and a
          -- replay wait are restored to the caller's interruptibility.
          mask $ \restore -> do
            now <- monotonicInstantFromMicros <$> monotonicMicros
            let authenticatedContext =
                  context
                    { brokerRequestAuthentication =
                        BrokerAuthenticatedRequest authorizedCallerIdentity
                    }
                request =
                  projectBrokerRequest
                    authenticatedContext
                    authorizedCallerIdentity
                    idempotencyKey
                    requestDigest
                    route
                    (maybe 0 brokerRequestBodyLength body)
            claim <- atomically (claimAdmission runtime now request)
            case claim of
              ClaimOwner ticket completion -> do
                interpreted <-
                  try
                    (restore (invokeInterpreter runtime authenticatedContext route body))
                    :: IO (Either SomeException BrokerReply)
                case interpreted of
                  Left err -> do
                    atomically (cancelRuntimeAdmission runtime ticket completion)
                    throwIO err
                  Right reply -> do
                    atomically (completeRuntimeAdmission runtime ticket completion reply)
                    pure reply
              ClaimWait completion -> restore (atomically (readTMVar completion))
              ClaimCached reply -> pure reply
              ClaimRefused reply -> pure reply

validateRpcHeaders
  :: BrokerRuntime
  -> Maybe BrokerRequestBody
  -> Map ByteString [ByteString]
  -> Either
       BrokerReply
       (BrokerServiceIdentity, BrokerTransportCredential, IdempotencyKey, RequestDigest)
validateRpcHeaders _runtime body headers = do
  rawIdentity <- requiredSingletonHeader "x-prodbox-service-identity" headers
  identityText <- firstHeaderError (TextEncoding.decodeUtf8' rawIdentity)
  claimedIdentity <- firstValidationError (mkBrokerServiceIdentity identityText)
  rawCredential <- requiredSingletonHeader "x-prodbox-transport-credential" headers
  credential <- mkBrokerTransportCredential rawCredential
  rawKey <- requiredSingletonHeader "idempotency-key" headers
  keyText <- firstHeaderError (TextEncoding.decodeUtf8' rawKey)
  idempotencyKey <- firstValidationError (mkIdempotencyKey keyText)
  rawDigest <- requiredSingletonHeader "x-prodbox-request-sha256" headers
  digestText <- firstHeaderError (TextEncoding.decodeUtf8' rawDigest)
  requestDigest <- firstValidationError (mkRequestDigest digestText)
  if requestDigest == digestBody body
    then Right (claimedIdentity, credential, idempotencyKey, requestDigest)
    else Left badRequestReply

mkBrokerTransportCredential
  :: ByteString -> Either BrokerReply BrokerTransportCredential
mkBrokerTransportCredential credential
  | BS.null credential = Left unauthorizedReply
  | BS.length credential > maximumTransportCredentialBytes = Left unauthorizedReply
  | otherwise = Right (BrokerTransportCredential credential)

maximumTransportCredentialBytes :: Int
maximumTransportCredentialBytes = 4096

authenticateRpc
  :: BrokerRuntime
  -> BrokerRequestContext
  -> BrokerRoute
  -> BrokerServiceIdentity
  -> BrokerTransportCredential
  -> IdempotencyKey
  -> RequestDigest
  -> IO (Either BrokerReply BrokerServiceIdentity)
authenticateRpc
  runtime
  context
  route
  claimedServiceIdentity
  credential
  idempotencyKey
  requestBodyDigest
    | claimedServiceIdentity /= runtimeExpectedServiceIdentity runtime =
        pure (Left unauthorizedReply)
    | otherwise = do
        let request =
              BrokerAuthenticationRequest
                { authenticationRoute = route
                , authenticationOperation = brokerRouteOperationTag route
                , authenticationClaimedIdentity = claimedServiceIdentity
                , authenticationExpectedServiceIdentity =
                    runtimeExpectedServiceIdentity runtime
                , authenticationIdempotencyKey = idempotencyKey
                , authenticationRequestBodyDigest = requestBodyDigest
                , authenticationCallerAddress = brokerRequestCallerAddress context
                , authenticationDeadline = brokerRequestDeadline context
                , authenticationCredential = credential
                }
        outcome <-
          try (authenticateBrokerCaller (runtimeAuthenticator runtime) request)
            :: IO
                 ( Either
                     SomeException
                     (Either BrokerAuthenticationFailure BrokerServiceIdentity)
                 )
        case outcome of
          Left err -> case fromException err :: Maybe SomeAsyncException of
            Just _ -> throwIO err
            Nothing -> pure (Left unavailableReply)
          Right (Left BrokerAuthenticationRejected) -> pure (Left unauthorizedReply)
          Right (Left BrokerAuthenticationUnavailable) -> pure (Left unavailableReply)
          Right (Right authorizedCallerIdentity)
            | authorizedCallerIdentity == runtimeExpectedServiceIdentity runtime ->
                pure (Right authorizedCallerIdentity)
            | otherwise -> pure (Left unauthorizedReply)

requiredSingletonHeader
  :: ByteString
  -> Map ByteString [ByteString]
  -> Either BrokerReply ByteString
requiredSingletonHeader name headers = case Map.lookup name headers of
  Just [value]
    | not (BS.null value) -> Right value
  _ -> Left badRequestReply

firstHeaderError :: Either value text -> Either BrokerReply text
firstHeaderError = either (const (Left badRequestReply)) Right

firstValidationError :: Either String value -> Either BrokerReply value
firstValidationError = either (const (Left badRequestReply)) Right

digestBody :: Maybe BrokerRequestBody -> RequestDigest
digestBody maybeBody = requestDigestForBytes bodyBytes
 where
  bodyBytes = maybe BS.empty (\body -> withBrokerRequestBody body id) maybeBody

-- | Total route projection into the admission algebra.  Keeping this mapping
-- next to the wire boundary prevents the HTTP registry and request contracts
-- from drifting independently.
brokerRouteOperationTag :: BrokerRoute -> Request.BrokerOperationTag
brokerRouteOperationTag route = case route of
  BrokerHealth -> Request.BrokerHealth
  BrokerReadiness -> Request.BrokerReadiness
  BrokerVaultStatus -> Request.ObserveBootstrapStatus
  BrokerVaultInitialize -> Request.EnsureVaultInitialized
  BrokerVaultUnseal -> Request.EnsureVaultUnsealed
  BrokerVaultSeal -> Request.SealVault
  BrokerVaultRotateUnlockBundle -> Request.RotateUnlockBundle
  BrokerVaultRotateTransitKey -> Request.RotateTransitKey
  BrokerVaultBaselineReconcile -> Request.ReconcileVaultBaseline
  BrokerVaultPkiStatus -> Request.ObserveVaultPki
  BrokerVaultPkiIssueTestCertificate -> Request.IssueVaultPkiTestCertificate
  BrokerVaultResetAmbiguousInitialization -> Request.RecoverAmbiguousInitialization
  BrokerChildCustodyCommit -> Request.CommitChildInitCustody
  BrokerChildRecoveryDeliver -> Request.DeliverChildRecovery
  BrokerChildRecoveryObserve -> Request.ObserveChildRecoveryDelivery

projectBrokerRequest
  :: BrokerRequestContext
  -> BrokerServiceIdentity
  -> IdempotencyKey
  -> RequestDigest
  -> BrokerRoute
  -> Natural
  -> BrokerRequest
projectBrokerRequest context claimedIdentity idempotencyKey requestDigest route bodyLength =
  BrokerRequest
    { brokerRequestOperation = brokerRouteOperationTag route
    , brokerRequestMethod = case brokerRouteMethod route of
        BrokerGet -> Request.HttpGet
        BrokerPost -> Request.HttpPost
    , brokerRequestMetadata =
        RequestMetadata
          { requestIdempotencyKey = idempotencyKey
          , requestDigest = requestDigest
          , requestCallerIdentity = claimedIdentity
          , requestCallerAddress = requestLoopbackAddress
          , requestContentLength = bodyLength
          , requestReceivedAt = brokerRequestAcceptedAt context
          , requestBudget = RemainingDuration requestBudgetMicros
          }
    , brokerRequestSecret = Nothing
    }
 where
  requestLoopbackAddress = case brokerRequestCallerAddress context of
    LoopbackIpv4 -> validatedRequestLoopback "127.0.0.1"
    LoopbackIpv6 -> validatedRequestLoopback "::1"
  acceptedMicros = monotonicInstantMicros (brokerRequestAcceptedAt context)
  deadlineMicros =
    monotonicInstantMicros (deadlineInstant (brokerRequestDeadline context))
  requestBudgetMicros
    | deadlineMicros > acceptedMicros = deadlineMicros - acceptedMicros
    | otherwise = 0

validatedRequestLoopback :: Text.Text -> Request.LoopbackAddress
validatedRequestLoopback address = case Request.mkLoopbackAddress address of
  Right loopback -> loopback
  Left _ -> error "compiled loopback projection violated the request invariant"

claimAdmission
  :: BrokerRuntime
  -> MonotonicInstant
  -> BrokerRequest
  -> STM IdempotencyClaim
claimAdmission runtime now request = do
  lane <- readTVar (runtimeAdmission runtime)
  let (admittedLane, result) =
        admitRequest
          now
          (runtimeExpectedServiceIdentity runtime)
          (runtimeAdmissionLimits runtime)
          lane
          request
  case result of
    AdmissionRefused refusal -> pure (ClaimRefused (admissionRefusalReply refusal))
    AdmissionAccepted disposition -> do
      writeTVar (runtimeAdmission runtime) admittedLane
      claimDisposition admittedLane disposition
 where
  capacity = fromIntegral (brokerQueueCapacity (brokerLimits (runtimeSettings runtime)))
  key = requestIdempotencyKey (brokerRequestMetadata request)

  claimDisposition admittedLane disposition = case disposition of
    AdmissionNew ticket -> do
      case startAdmission ticket admittedLane of
        Left _ -> pure (ClaimRefused internalErrorReply)
        Right runningLane -> do
          executions <- readTVar (runtimeIdempotency runtime)
          let (bounded, evictedKeys) =
                evictCompletedForCapacity capacity executions
              boundedLane =
                foldl'
                  (flip forgetCompletedAdmission)
                  runningLane
                  evictedKeys
          if Map.size (idempotencyEntries bounded) >= capacity
            then do
              case cancelAdmission ticket runningLane of
                Left _ -> pure ()
                Right cancelledLane ->
                  writeTVar
                    (runtimeAdmission runtime)
                    (forgetCancelledAdmission key cancelledLane)
              pure (ClaimRefused saturatedReply)
            else do
              completion <- newEmptyTMVar
              writeTVar (runtimeAdmission runtime) boundedLane
              writeTVar
                (runtimeIdempotency runtime)
                bounded
                  { idempotencyEntries =
                      Map.insert key (RuntimeRequestRunning completion) (idempotencyEntries bounded)
                  , idempotencyOrder = idempotencyOrder bounded ++ [key]
                  }
              pure (ClaimOwner ticket completion)
    AdmissionResumeQueued _ ->
      claimExistingExecution key
    AdmissionResumeRunning _ ->
      claimExistingExecution key
    AdmissionReturnCached responseDigest -> do
      executions <- readTVar (runtimeIdempotency runtime)
      case Map.lookup key (idempotencyEntries executions) of
        Just (RuntimeRequestCompleted cachedDigest reply)
          | cachedDigest == responseDigest -> pure (ClaimCached reply)
        _ -> pure (ClaimRefused unavailableReply)

  claimExistingExecution existingKey = do
    executions <- readTVar (runtimeIdempotency runtime)
    case Map.lookup existingKey (idempotencyEntries executions) of
      Just (RuntimeRequestRunning completion) -> pure (ClaimWait completion)
      Just (RuntimeRequestCompleted _ reply) -> pure (ClaimCached reply)
      Nothing -> pure (ClaimRefused unavailableReply)

evictCompletedForCapacity
  :: Int -> IdempotencyState -> (IdempotencyState, [IdempotencyKey])
evictCompletedForCapacity capacity state
  | Map.size (idempotencyEntries state) < capacity = (state, [])
  | otherwise = case find isCompletedKey (idempotencyOrder state) of
      Nothing -> (state, [])
      Just key ->
        let (evictedState, remainingKeys) =
              evictCompletedForCapacity
                capacity
                state
                  { idempotencyEntries = Map.delete key (idempotencyEntries state)
                  , idempotencyOrder = filter (/= key) (idempotencyOrder state)
                  }
         in (evictedState, key : remainingKeys)
 where
  isCompletedKey key = case Map.lookup key (idempotencyEntries state) of
    Just RuntimeRequestCompleted {} -> True
    _ -> False

completeRuntimeAdmission
  :: BrokerRuntime
  -> AdmissionTicket
  -> TMVar BrokerReply
  -> BrokerReply
  -> STM ()
completeRuntimeAdmission runtime ticket completion reply = do
  let responseDigest = digestReply reply
      key = ticketIdempotencyKey ticket
  lane <- readTVar (runtimeAdmission runtime)
  case completeAdmission ticket responseDigest lane of
    Left _ -> pure ()
    Right completedLane -> writeTVar (runtimeAdmission runtime) completedLane
  executions <- readTVar (runtimeIdempotency runtime)
  case Map.lookup key (idempotencyEntries executions) of
    Just (RuntimeRequestRunning recordedCompletion)
      | recordedCompletion == completion ->
          writeTVar
            (runtimeIdempotency runtime)
            executions
              { idempotencyEntries =
                  Map.insert
                    key
                    (RuntimeRequestCompleted responseDigest reply)
                    (idempotencyEntries executions)
              }
    _ -> pure ()
  void (tryPutTMVar completion reply)

cancelRuntimeAdmission
  :: BrokerRuntime
  -> AdmissionTicket
  -> TMVar BrokerReply
  -> STM ()
cancelRuntimeAdmission runtime ticket completion = do
  let key = ticketIdempotencyKey ticket
  executions <- readTVar (runtimeIdempotency runtime)
  case Map.lookup key (idempotencyEntries executions) of
    Just (RuntimeRequestRunning recordedCompletion)
      | recordedCompletion == completion -> do
          cancellationRecorded <- tryPutTMVar completion internalErrorReply
          when cancellationRecorded $ do
            lane <- readTVar (runtimeAdmission runtime)
            case cancelAdmission ticket lane of
              Left _ -> pure ()
              Right cancelledLane ->
                writeTVar
                  (runtimeAdmission runtime)
                  (forgetCancelledAdmission key cancelledLane)
            writeTVar
              (runtimeIdempotency runtime)
              executions
                { idempotencyEntries = Map.delete key (idempotencyEntries executions)
                , idempotencyOrder = filter (/= key) (idempotencyOrder executions)
                }
    _ -> pure ()

digestReply :: BrokerReply -> RequestDigest
digestReply = requestDigestForBytes . brokerReplyBytes

admissionRefusalReply :: AdmissionRefusal -> BrokerReply
admissionRefusalReply refusal = case refusal of
  RefuseWrongServiceIdentity -> unauthorizedReply
  RefuseMethod -> methodNotAllowedReply
  RefuseBodyRequired -> badRequestReply
  RefuseBodyForbidden -> badRequestReply
  RefuseSecretForbidden -> badRequestReply
  RefuseBodyTooLarge _ _ -> payloadTooLargeReply
  RefuseContentLengthMismatch _ _ -> badRequestReply
  RefuseIdempotencyConflict -> conflictReply
  RefuseDraining -> unavailableReply
  RefuseSaturated _ -> saturatedReply
  RefuseDeadlineExpired -> deadlineReply
  RefuseDeadlineInfeasible _ -> deadlineReply

invokeInterpreter
  :: BrokerRuntime
  -> BrokerRequestContext
  -> BrokerRoute
  -> Maybe BrokerRequestBody
  -> IO BrokerReply
invokeInterpreter runtime context route body = do
  outcome <-
    try (interpretBrokerRequest (runtimeInterpreter runtime) context route body)
      :: IO (Either SomeException BrokerReply)
  case outcome of
    Right reply -> pure reply
    Left err -> case fromException err :: Maybe SomeAsyncException of
      Just _ -> throwIO err
      Nothing -> pure internalErrorReply

managerLoop
  :: BrokerRuntime
  -> Async AcceptOutcome
  -> [Async ()]
  -> TMVar (Either BrokerServerError ())
  -> IO ()
managerLoop runtime acceptThread workers done = do
  trigger <- atomically (waitForManagerTrigger runtime acceptThread)
  drainDeadline <- newDrainDeadline runtime
  let acceptFailure = case trigger of
        ManagerListenerSettled (Left _) -> True
        ManagerListenerSettled (Right AcceptFailed) -> True
        ManagerListenerSettled (Right AcceptStopped) -> False
        ManagerDrainRequested -> False
  atomically $ do
    phase <- readTVar (runtimePhase runtime)
    when (phase == BrokerServing) $ do
      writeTVar (runtimePhase runtime) BrokerDraining
      modifyTVar' (runtimeAdmission runtime) beginDraining
  closeQuietly (runtimeListener runtime)
  settled <-
    runUntilDrainDeadline
      drainDeadline
      (atomically (waitForRuntimeSettlement runtime acceptThread))
  phaseAfterWait <- readTVarIO (runtimePhase runtime)
  outcome <- case (phaseAfterWait, settled) of
    (BrokerForceDraining, _) -> do
      forceStopRuntime runtime acceptThread workers
      pure (Left BrokerForcedShutdown)
    (_, Nothing) -> do
      atomically (writeTVar (runtimePhase runtime) BrokerForceDraining)
      forceStopRuntime runtime acceptThread workers
      pure (Left BrokerDrainDeadlineExceeded)
    (_, Just ()) -> do
      stopped <-
        runUntilDrainDeadline
          drainDeadline
          (stopWorkersNormally runtime workers)
      phaseAfterStop <- readTVarIO (runtimePhase runtime)
      case (phaseAfterStop, stopped) of
        (BrokerForceDraining, _) -> do
          forceStopRuntime runtime acceptThread workers
          pure (Left BrokerForcedShutdown)
        (_, Nothing) -> do
          atomically (writeTVar (runtimePhase runtime) BrokerForceDraining)
          forceStopRuntime runtime acceptThread workers
          pure (Left BrokerDrainDeadlineExceeded)
        (_, Just ()) ->
          pure $ if acceptFailure then Left BrokerListenerFailed else Right ()
  atomically $ do
    terminalPhase <- readTVar (runtimePhase runtime)
    let terminalOutcome = case (terminalPhase, outcome) of
          (BrokerForceDraining, Right ()) -> Left BrokerForcedShutdown
          (BrokerForceDraining, Left BrokerListenerFailed) -> Left BrokerForcedShutdown
          _ -> outcome
    writeTVar (runtimePhase runtime) BrokerStopped
    void (tryPutTMVar done terminalOutcome)

waitForManagerTrigger :: BrokerRuntime -> Async AcceptOutcome -> STM ManagerTrigger
waitForManagerTrigger runtime acceptThread = do
  phase <- readTVar (runtimePhase runtime)
  case phase of
    BrokerServing -> ManagerListenerSettled <$> waitCatchSTM acceptThread
    BrokerDraining -> pure ManagerDrainRequested
    BrokerForceDraining -> pure ManagerDrainRequested
    BrokerStopped -> pure ManagerDrainRequested

waitForRuntimeSettlement :: BrokerRuntime -> Async AcceptOutcome -> STM ()
waitForRuntimeSettlement runtime acceptThread = do
  phase <- readTVar (runtimePhase runtime)
  case phase of
    BrokerForceDraining -> pure ()
    _ -> do
      void (waitCatchSTM acceptThread)
      waitForDrainSettlement runtime

waitForDrainSettlement :: BrokerRuntime -> STM ()
waitForDrainSettlement runtime = do
  phase <- readTVar (runtimePhase runtime)
  queued <- lengthTBQueue (runtimeQueue runtime)
  active <- readTVar (runtimeActive runtime)
  unless
    (phase == BrokerForceDraining || queued == 0 && active == 0)
    retry

stopWorkersNormally :: BrokerRuntime -> [Async ()] -> IO ()
stopWorkersNormally runtime workers = do
  replicateM_
    (length workers)
    (atomically (writeTBQueue (runtimeQueue runtime) Nothing))
  mapM_ waitCatch workers

forceStopRuntime :: BrokerRuntime -> Async AcceptOutcome -> [Async ()] -> IO ()
forceStopRuntime runtime acceptThread workers = do
  forceDeadline <- newDrainDeadline runtime
  void $ runUntilDrainDeadline forceDeadline $ do
    queuedSockets <- atomically (drainQueuedSockets (runtimeQueue runtime))
    mapM_ closeQuietly queuedSockets
    cancelMany workers
    cancel acceptThread

newDrainDeadline :: BrokerRuntime -> IO DrainDeadline
newDrainDeadline runtime = do
  now <- monotonicMicros
  let drainMicros =
        1000 * brokerDrainDeadlineMilliseconds (brokerLimits (runtimeSettings runtime))
  pure (DrainDeadline (now + drainMicros))

runUntilDrainDeadline :: DrainDeadline -> IO value -> IO (Maybe value)
runUntilDrainDeadline (DrainDeadline deadlineMicros) action = do
  now <- monotonicMicros
  if now >= deadlineMicros
    then pure Nothing
    else
      timeout
        (naturalToTimeoutMicros (deadlineMicros - now))
        action

drainQueuedSockets :: TBQueue (Maybe QueuedConnection) -> STM [Socket]
drainQueuedSockets queue = do
  queuedCount <- lengthTBQueue queue
  catMaybes
    <$> replicateM
      (fromIntegral queuedCount)
      (fmap (fmap queuedSocket) (readTBQueue queue))

sendHttpReply :: Socket -> BrokerReply -> IO ()
sendHttpReply clientSocket reply = sendAll clientSocket (renderHttpReply reply)

sendBriefly :: Socket -> BrokerReply -> IO ()
sendBriefly clientSocket reply = do
  _ <- timeout 100000 (sendHttpReply clientSocket reply)
  pure ()

renderHttpReply :: BrokerReply -> ByteString
renderHttpReply reply =
  BS.concat
    [ "HTTP/1.1 "
    , renderStatus (brokerReplyStatus reply)
    , "\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "
    , BS8.pack (show (BS.length body))
    , "\r\n\r\n"
    , body
    ]
 where
  body = brokerReplyBytes reply

renderStatus :: BrokerReplyStatus -> ByteString
renderStatus status = case status of
  BrokerReplyOk -> "200 OK"
  BrokerReplyAccepted -> "202 Accepted"
  BrokerReplyBadRequest -> "400 Bad Request"
  BrokerReplyUnauthorized -> "401 Unauthorized"
  BrokerReplyNotFound -> "404 Not Found"
  BrokerReplyMethodNotAllowed -> "405 Method Not Allowed"
  BrokerReplyPayloadTooLarge -> "413 Payload Too Large"
  BrokerReplyConflict -> "409 Conflict"
  BrokerReplyTooManyRequests -> "429 Too Many Requests"
  BrokerReplyServiceUnavailable -> "503 Service Unavailable"
  BrokerReplyGatewayTimeout -> "504 Gateway Timeout"
  BrokerReplyInternalError -> "500 Internal Server Error"

wireErrorReply :: WireRequestError -> BrokerReply
wireErrorReply err = case err of
  WireMalformed -> badRequestReply
  WireBodyTooLarge -> payloadTooLargeReply
  WireUnsupportedTransferEncoding -> badRequestReply

badRequestReply :: BrokerReply
badRequestReply = fixedReply BrokerReplyBadRequest "{\"error\":\"bad_request\"}"

payloadTooLargeReply :: BrokerReply
payloadTooLargeReply =
  fixedReply BrokerReplyPayloadTooLarge "{\"error\":\"request_body_too_large\"}"

unauthorizedReply :: BrokerReply
unauthorizedReply = fixedReply BrokerReplyUnauthorized "{\"error\":\"unauthorized\"}"

notFoundReply :: BrokerReply
notFoundReply = fixedReply BrokerReplyNotFound "{\"error\":\"not_found\"}"

methodNotAllowedReply :: BrokerReply
methodNotAllowedReply =
  fixedReply BrokerReplyMethodNotAllowed "{\"error\":\"method_not_allowed\"}"

conflictReply :: BrokerReply
conflictReply = fixedReply BrokerReplyConflict "{\"error\":\"idempotency_conflict\"}"

saturatedReply :: BrokerReply
saturatedReply = fixedReply BrokerReplyTooManyRequests "{\"error\":\"broker_saturated\"}"

unavailableReply :: BrokerReply
unavailableReply =
  fixedReply BrokerReplyServiceUnavailable "{\"error\":\"broker_unavailable\"}"

deadlineReply :: BrokerReply
deadlineReply = fixedReply BrokerReplyGatewayTimeout "{\"error\":\"deadline_exceeded\"}"

internalErrorReply :: BrokerReply
internalErrorReply = fixedReply BrokerReplyInternalError "{\"error\":\"internal_error\"}"

fixedReply :: BrokerReplyStatus -> ByteString -> BrokerReply
fixedReply status body = case mkBrokerReply status body of
  Right reply -> reply
  Left _ -> error "compiled broker reply violated the response bound"

monotonicMicros :: IO Natural
monotonicMicros = fromIntegral . (`div` 1000) <$> getMonotonicTimeNSec

naturalToTimeoutMicros :: Natural -> Int
naturalToTimeoutMicros value =
  fromIntegral (min value (fromIntegral (maxBound :: Int)))

decreaseNatural :: Natural -> Natural
decreaseNatural value
  | value == 0 = 0
  | otherwise = value - 1

whenEither :: Bool -> errorValue -> Either errorValue ()
whenEither condition err = if condition then Left err else Right ()

closeQuietly :: Socket -> IO ()
closeQuietly clientSocket = do
  _ <- try (close clientSocket) :: IO (Either IOException ())
  pure ()
