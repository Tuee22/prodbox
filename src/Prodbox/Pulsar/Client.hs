{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Pulsar.Client
  ( AckRequest (..)
  , ConsumeRequest (..)
  , ConsumedMessage (..)
  , MessageId (..)
  , ProduceReceipt (..)
  , ProduceRequest (..)
  , PulsarClientConfig (..)
  , PulsarClientError (..)
  , PulsarConnection (..)
  , PulsarLookupStrategy (..)
  , SubscriptionName (..)
  , ack
  , connect
  , consume
  , consumeMessage
  , produce
  , renderPulsarClientError
  )
where

import Control.Concurrent
  ( MVar
  , modifyMVar
  , newMVar
  , threadDelay
  )
import Control.Exception
  ( IOException
  , try
  )
import Data.Bits
  ( shiftL
  , (.|.)
  )
import Data.ByteString qualified as BS
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  )
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word
  ( Word32
  , Word64
  )
import GHC.Generics (Generic)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBS
import Prodbox.Cbor (CborPayload)
import Prodbox.Pulsar.Protocol
  ( AckResponse (..)
  , BrokerEndpoint (..)
  , BrokerFrame (..)
  , BrokerMessage (..)
  , BrokerResponse (..)
  , ConnectedResponse (..)
  , LookupResponse (..)
  , LookupResponseType (..)
  , MessageMetadata (..)
  , ProducerSuccess (..)
  , SendError (..)
  , SendReceipt (..)
  , ServerError (..)
  , buildAckCommand
  , buildConnectCommand
  , buildFlowCommand
  , buildLookupCommand
  , buildPayloadFrame
  , buildPongCommand
  , buildProducerCommand
  , buildSendCommand
  , buildSimpleFrame
  , buildSubscribeCommand
  , decodeMessageIdText
  , encodeMessageIdText
  , encodeMessageMetadata
  , parseBrokerServiceUrl
  , parseFrameBody
  , renderBrokerEndpoint
  , renderServerError
  )
import Prodbox.Pulsar.Topic
  ( TopicName
  , renderTopicName
  )
import System.Timeout (timeout)

data PulsarClientConfig = PulsarClientConfig
  { pulsarClientHost :: String
  , pulsarClientPort :: Int
  , pulsarClientName :: Text
  , pulsarClientLookupStrategy :: PulsarLookupStrategy
  }
  deriving (Eq, Show, Generic)

data PulsarLookupStrategy
  = FollowBrokerLookupUrl
  | StayOnConnectedBroker
  deriving (Eq, Show, Generic)

data PulsarConnection = PulsarConnection
  { pulsarConnectionConfig :: PulsarClientConfig
  , pulsarConnectionState :: MVar BrokerSession
  , pulsarConnectionIds :: IORef IdState
  }

instance Show PulsarConnection where
  show connection =
    "PulsarConnection " ++ show (pulsarConnectionConfig connection)

newtype SubscriptionName = SubscriptionName Text
  deriving (Eq, Ord, Show, Generic)

newtype MessageId = MessageId Text
  deriving (Eq, Ord, Show, Generic)

data ProduceRequest = ProduceRequest
  { produceTopic :: TopicName
  , producePayload :: CborPayload
  }
  deriving (Eq, Show, Generic)

data ConsumeRequest = ConsumeRequest
  { consumeTopic :: TopicName
  , consumeSubscription :: SubscriptionName
  }
  deriving (Eq, Show, Generic)

data ConsumedMessage = ConsumedMessage
  { consumedMessageId :: MessageId
  , consumedPayload :: CborPayload
  }
  deriving (Eq, Show, Generic)

data AckRequest = AckRequest
  { ackTopic :: TopicName
  , ackSubscription :: SubscriptionName
  , ackMessageId :: MessageId
  }
  deriving (Eq, Show, Generic)

data ProduceReceipt = ProduceReceipt
  { produceReceiptMessageId :: MessageId
  }
  deriving (Eq, Show, Generic)

data PulsarClientError
  = PulsarInvalidEndpoint String
  | PulsarBrokerUnreachable String
  | PulsarMalformedFrame String
  | PulsarAuthenticationFailed String
  | PulsarAuthorizationFailed String
  | PulsarTopicAbsent TopicName String
  | PulsarUnsupportedServerBehavior String
  | PulsarBrokerError ServerError String
  deriving (Eq, Show)

data BrokerSession = BrokerSession
  { brokerSessionEndpoint :: BrokerEndpoint
  , brokerSessionSocket :: Socket.Socket
  , brokerSessionProducers :: Map TopicName ProducerState
  , brokerSessionConsumers :: Map (TopicName, SubscriptionName) ConsumerState
  }

data ProducerState = ProducerState
  { producerStateId :: Word64
  , producerStateName :: Text
  }
  deriving (Eq, Show)

data ConsumerState = ConsumerState
  { consumerStateId :: Word64
  }
  deriving (Eq, Show)

data IdState = IdState
  { nextRequestId :: Word64
  , nextProducerId :: Word64
  , nextConsumerId :: Word64
  , nextSequenceId :: Word64
  }
  deriving (Eq, Show)

connect :: PulsarClientConfig -> IO (Either PulsarClientError PulsarConnection)
connect config =
  case validateConfig config of
    Left err -> pure (Left err)
    Right endpoint -> do
      ids <- newIORef initialIdState
      openResult <- openSession config endpoint
      case openResult of
        Left err -> pure (Left err)
        Right session -> do
          state <- newMVar session
          pure
            ( Right
                PulsarConnection
                  { pulsarConnectionConfig = config
                  , pulsarConnectionState = state
                  , pulsarConnectionIds = ids
                  }
            )

produce :: PulsarConnection -> ProduceRequest -> IO (Either PulsarClientError ProduceReceipt)
produce connection request =
  withSession connection $ \session -> do
    producerResult <- ensureProducer connection session (produceTopic request)
    case producerResult of
      Left err -> pure (Left err, session)
      Right (producer, sessionWithProducer) -> do
        sequenceId <- nextSequence connection
        publishTimeMillis <- currentMillis
        let commandBytes = buildSendCommand (producerStateId producer) sequenceId
            metadata =
              MessageMetadata
                { messageMetadataProducerName = producerStateName producer
                , messageMetadataSequenceId = sequenceId
                , messageMetadataPublishTimeMillis = publishTimeMillis
                }
            frame = buildPayloadFrame commandBytes (encodeMessageMetadata metadata) (producePayload request)
        sendResult <- sendFrame (brokerSessionSocket sessionWithProducer) frame
        case sendResult of
          Left err -> pure (Left err, sessionWithProducer)
          Right () -> do
            receiptResult <-
              waitForResponse
                sessionWithProducer
                (matchSendReceipt (producerStateId producer) sequenceId)
            case receiptResult of
              Left err -> pure (Left err, sessionWithProducer)
              Right receipt ->
                pure
                  ( Right
                      ProduceReceipt
                        { produceReceiptMessageId =
                            MessageId
                              ( maybe
                                  (Text.pack (show (sendReceiptSequenceId receipt)))
                                  encodeMessageIdText
                                  (sendReceiptMessageId receipt)
                              )
                        }
                  , sessionWithProducer
                  )

consume :: PulsarConnection -> ConsumeRequest -> IO (Either PulsarClientError (Maybe CborPayload))
consume connection request =
  fmap (fmap (fmap consumedPayload)) (consumeMessage connection request)

consumeMessage
  :: PulsarConnection -> ConsumeRequest -> IO (Either PulsarClientError (Maybe ConsumedMessage))
consumeMessage connection request =
  withSession connection $ \session -> do
    consumerResult <-
      ensureConsumer connection session (consumeTopic request) (consumeSubscription request)
    case consumerResult of
      Left err -> pure (Left err, session)
      Right (consumer, sessionWithConsumer) -> do
        sendResult <-
          sendFrame
            (brokerSessionSocket sessionWithConsumer)
            (buildSimpleFrame (buildFlowCommand (consumerStateId consumer) 1))
        case sendResult of
          Left err -> pure (Left err, sessionWithConsumer)
          Right () -> do
            messageResult <- waitForResponse sessionWithConsumer (matchMessage (consumerStateId consumer))
            case messageResult of
              Left err -> pure (Left err, sessionWithConsumer)
              Right (message, payload) ->
                pure
                  ( Right
                      ( Just
                          ConsumedMessage
                            { consumedMessageId = MessageId (encodeMessageIdText (brokerMessageId message))
                            , consumedPayload = payload
                            }
                      )
                  , sessionWithConsumer
                  )

ack :: PulsarConnection -> AckRequest -> IO (Either PulsarClientError ())
ack connection request =
  withSession connection (ackWithSession connection request messageIdText)
 where
  MessageId messageIdText = ackMessageId request

ackWithSession
  :: PulsarConnection
  -> AckRequest
  -> Text
  -> BrokerSession
  -> IO (Either PulsarClientError (), BrokerSession)
ackWithSession connection request messageIdText session =
  case decodeMessageIdText messageIdText of
    Left err -> pure (Left (PulsarUnsupportedServerBehavior err), session)
    Right messageId -> do
      consumerResult <- ensureConsumer connection session (ackTopic request) (ackSubscription request)
      case consumerResult of
        Left err -> pure (Left err, session)
        Right (consumer, sessionWithConsumer) -> do
          requestId <- nextRequest connection
          sendResult <-
            sendFrame
              (brokerSessionSocket sessionWithConsumer)
              (buildSimpleFrame (buildAckCommand (consumerStateId consumer) requestId messageId))
          case sendResult of
            Left err -> pure (Left err, sessionWithConsumer)
            Right () -> do
              ackResult <- waitForResponse sessionWithConsumer (matchAckResponse requestId)
              case ackResult of
                Left err -> pure (Left err, sessionWithConsumer)
                Right () -> pure (Right (), sessionWithConsumer)

renderPulsarClientError :: PulsarClientError -> String
renderPulsarClientError err =
  case err of
    PulsarInvalidEndpoint message -> message
    PulsarBrokerUnreachable message -> "Pulsar broker unreachable: " ++ message
    PulsarMalformedFrame message -> "Pulsar malformed frame: " ++ message
    PulsarAuthenticationFailed message -> "Pulsar authentication failed: " ++ message
    PulsarAuthorizationFailed message -> "Pulsar authorization failed: " ++ message
    PulsarTopicAbsent topic message ->
      "Pulsar topic absent: " ++ Text.unpack (renderTopicName topic) ++ " (" ++ message ++ ")"
    PulsarUnsupportedServerBehavior message -> "Pulsar unsupported server behavior: " ++ message
    PulsarBrokerError serverError message ->
      "Pulsar broker error " ++ renderServerError serverError ++ ": " ++ message

validateConfig :: PulsarClientConfig -> Either PulsarClientError BrokerEndpoint
validateConfig config
  | null (pulsarClientHost config) =
      Left (PulsarInvalidEndpoint "Pulsar host must not be empty.")
  | pulsarClientPort config <= 0 =
      Left (PulsarInvalidEndpoint "Pulsar port must be positive.")
  | otherwise =
      Right
        BrokerEndpoint
          { brokerEndpointHost = pulsarClientHost config
          , brokerEndpointPort = pulsarClientPort config
          }

initialIdState :: IdState
initialIdState =
  IdState
    { nextRequestId = 1
    , nextProducerId = 1
    , nextConsumerId = 1
    , nextSequenceId = 0
    }

openSession :: PulsarClientConfig -> BrokerEndpoint -> IO (Either PulsarClientError BrokerSession)
openSession config endpoint = do
  socketResult <- openSocket endpoint
  case socketResult of
    Left err -> pure (Left err)
    Right socket -> do
      sendResult <- sendFrame socket (buildSimpleFrame (buildConnectCommand (pulsarClientName config)))
      case sendResult of
        Left err -> do
          closeSocket socket
          pure (Left err)
        Right () -> do
          connectedResult <- waitForConnected socket
          case connectedResult of
            Left err -> do
              closeSocket socket
              pure (Left err)
            Right _ ->
              pure
                ( Right
                    BrokerSession
                      { brokerSessionEndpoint = endpoint
                      , brokerSessionSocket = socket
                      , brokerSessionProducers = Map.empty
                      , brokerSessionConsumers = Map.empty
                      }
                )

openSocket :: BrokerEndpoint -> IO (Either PulsarClientError Socket.Socket)
openSocket endpoint = do
  result <- try (openSocketUnsafe endpoint)
  case result of
    Left err ->
      pure
        ( Left
            ( PulsarBrokerUnreachable
                (renderBrokerEndpoint endpoint ++ ": " ++ show (err :: IOException))
            )
        )
    Right socket -> pure (Right socket)

openSocketUnsafe :: BrokerEndpoint -> IO Socket.Socket
openSocketUnsafe endpoint = do
  addresses <-
    Socket.getAddrInfo
      Nothing
      (Just (brokerEndpointHost endpoint))
      (Just (show (brokerEndpointPort endpoint)))
  case addresses of
    [] -> ioError (userError ("no address records for " ++ renderBrokerEndpoint endpoint))
    address : _ -> do
      socket <- Socket.socket (Socket.addrFamily address) Socket.Stream Socket.defaultProtocol
      Socket.connect socket (Socket.addrAddress address)
      pure socket

closeSocket :: Socket.Socket -> IO ()
closeSocket socket = do
  _ <- try (Socket.close socket) :: IO (Either IOException ())
  pure ()

withSession
  :: PulsarConnection
  -> (BrokerSession -> IO (Either PulsarClientError a, BrokerSession))
  -> IO (Either PulsarClientError a)
withSession connection action =
  modifyMVar (pulsarConnectionState connection) $ \session -> do
    first <- action session
    case first of
      (Left err, failedSession)
        | shouldReconnect err -> do
            closeSocket (brokerSessionSocket failedSession)
            reconnectResult <- reconnectWithBackoff connection (brokerSessionEndpoint failedSession)
            case reconnectResult of
              Left reconnectErr -> pure (failedSession, Left reconnectErr)
              Right freshSession -> do
                retry <- action freshSession
                case retry of
                  (retryResult, retrySession) -> pure (retrySession, retryResult)
      (result, updatedSession) -> pure (updatedSession, result)

shouldReconnect :: PulsarClientError -> Bool
shouldReconnect err =
  case err of
    PulsarBrokerUnreachable _ -> True
    PulsarMalformedFrame _ -> True
    PulsarBrokerError ServerServiceNotReady _ -> True
    PulsarBrokerError ServerTooManyRequests _ -> True
    _ -> False

reconnectWithBackoff
  :: PulsarConnection -> BrokerEndpoint -> IO (Either PulsarClientError BrokerSession)
reconnectWithBackoff connection endpoint =
  go (0 :: Int) [100000, 300000, 700000]
 where
  go _ [] = openSession (pulsarConnectionConfig connection) endpoint
  go attempt (delayMicros : rest) = do
    if attempt > 0
      then threadDelay delayMicros
      else pure ()
    result <- openSession (pulsarConnectionConfig connection) endpoint
    case result of
      Right session -> pure (Right session)
      Left _ -> go (attempt + 1) rest

ensureProducer
  :: PulsarConnection
  -> BrokerSession
  -> TopicName
  -> IO (Either PulsarClientError (ProducerState, BrokerSession))
ensureProducer connection session topic =
  case Map.lookup topic (brokerSessionProducers session) of
    Just producer -> pure (Right (producer, session))
    Nothing -> do
      lookupResult <- resolveTopicOwner connection session topic
      case lookupResult of
        Left err -> pure (Left err)
        Right ownerSession -> do
          producerId <- nextProducer connection
          requestId <- nextRequest connection
          let command = buildProducerCommand topic producerId requestId
          sendResult <- sendFrame (brokerSessionSocket ownerSession) (buildSimpleFrame command)
          case sendResult of
            Left err -> pure (Left err)
            Right () -> do
              success <- waitForResponse ownerSession (matchProducerSuccess requestId)
              case success of
                Left err -> pure (Left err)
                Right producerSuccess
                  | not (producerSuccessReady producerSuccess) ->
                      pure (Left (PulsarUnsupportedServerBehavior "broker returned a producer that is not ready"))
                  | otherwise -> do
                      let producer =
                            ProducerState
                              { producerStateId = producerId
                              , producerStateName = producerSuccessName producerSuccess
                              }
                          updated =
                            ownerSession
                              { brokerSessionProducers =
                                  Map.insert topic producer (brokerSessionProducers ownerSession)
                              }
                      pure (Right (producer, updated))

ensureConsumer
  :: PulsarConnection
  -> BrokerSession
  -> TopicName
  -> SubscriptionName
  -> IO (Either PulsarClientError (ConsumerState, BrokerSession))
ensureConsumer connection session topic subscription =
  case Map.lookup (topic, subscription) (brokerSessionConsumers session) of
    Just consumer -> pure (Right (consumer, session))
    Nothing -> do
      lookupResult <- resolveTopicOwner connection session topic
      case lookupResult of
        Left err -> pure (Left err)
        Right ownerSession -> do
          consumerId <- nextConsumer connection
          requestId <- nextRequest connection
          let SubscriptionName subscriptionText = subscription
              command =
                buildSubscribeCommand
                  topic
                  subscriptionText
                  consumerId
                  requestId
                  (pulsarClientName (pulsarConnectionConfig connection) <> "-consumer")
          sendResult <- sendFrame (brokerSessionSocket ownerSession) (buildSimpleFrame command)
          case sendResult of
            Left err -> pure (Left err)
            Right () -> do
              success <- waitForResponse ownerSession (matchSuccess requestId)
              case success of
                Left err -> pure (Left err)
                Right () -> do
                  let consumer = ConsumerState {consumerStateId = consumerId}
                      updated =
                        ownerSession
                          { brokerSessionConsumers =
                              Map.insert (topic, subscription) consumer (brokerSessionConsumers ownerSession)
                          }
                  pure (Right (consumer, updated))

resolveTopicOwner
  :: PulsarConnection
  -> BrokerSession
  -> TopicName
  -> IO (Either PulsarClientError BrokerSession)
resolveTopicOwner connection session topic =
  go (0 :: Int) session False
 where
  go redirects currentSession authoritative
    | redirects > 5 =
        pure (Left (PulsarUnsupportedServerBehavior "topic lookup redirected more than five times"))
    | otherwise = do
        requestId <- nextRequest connection
        sendResult <-
          sendFrame
            (brokerSessionSocket currentSession)
            (buildSimpleFrame (buildLookupCommand topic requestId authoritative))
        case sendResult of
          Left err -> pure (Left err)
          Right () -> do
            lookupResult <- waitForResponse currentSession (matchLookupResponse requestId topic)
            case lookupResult of
              Left err -> pure (Left err)
              Right response ->
                case lookupResponseType response of
                  LookupFailed ->
                    pure (Left (classifyLookupFailure topic response))
                  LookupResponseUnknown value ->
                    pure (Left (PulsarUnsupportedServerBehavior ("unknown lookup response type: " ++ show value)))
                  LookupConnect ->
                    case pulsarClientLookupStrategy (pulsarConnectionConfig connection) of
                      FollowBrokerLookupUrl -> switchToLookupEndpoint currentSession response
                      StayOnConnectedBroker -> pure (Right currentSession)
                  LookupRedirect -> do
                    switched <- switchToLookupEndpoint currentSession response
                    case switched of
                      Left err -> pure (Left err)
                      Right redirected ->
                        go (redirects + 1) redirected (lookupResponseAuthoritative response)
  switchToLookupEndpoint currentSession response =
    case lookupResponseBrokerServiceUrl response of
      Nothing -> pure (Right currentSession)
      Just url -> case parseBrokerServiceUrl url of
        Left err -> pure (Left (PulsarUnsupportedServerBehavior err))
        Right endpoint
          | endpoint == brokerSessionEndpoint currentSession -> pure (Right currentSession)
          | otherwise -> do
              closeSocket (brokerSessionSocket currentSession)
              openSession (pulsarConnectionConfig connection) endpoint

classifyLookupFailure :: TopicName -> LookupResponse -> PulsarClientError
classifyLookupFailure topic response =
  case lookupResponseError response of
    Just ServerTopicNotFound ->
      PulsarTopicAbsent topic message
    Just ServerAuthenticationError ->
      PulsarAuthenticationFailed message
    Just ServerAuthorizationError ->
      PulsarAuthorizationFailed message
    Just err ->
      PulsarBrokerError err message
    Nothing ->
      PulsarUnsupportedServerBehavior ("topic lookup failed without a broker error: " ++ message)
 where
  message = maybe "" Text.unpack (lookupResponseMessage response)

waitForConnected :: Socket.Socket -> IO (Either PulsarClientError ConnectedResponse)
waitForConnected socket =
  withTimeout $ do
    frameResult <- readFrame socket
    case frameResult of
      Left err -> pure (Left err)
      Right frame ->
        case brokerFrameCommand frame of
          BrokerConnected connected -> pure (Right connected)
          BrokerError _ serverError message -> pure (Left (classifyServerError Nothing serverError (Text.unpack message)))
          BrokerPing -> do
            _ <- sendFrame socket (buildSimpleFrame buildPongCommand)
            waitForConnected socket
          other ->
            pure
              ( Left
                  ( PulsarUnsupportedServerBehavior
                      ("expected Connected after Connect, received " ++ show other)
                  )
              )

waitForResponse
  :: BrokerSession
  -> (BrokerFrame -> Maybe (Either PulsarClientError a))
  -> IO (Either PulsarClientError a)
waitForResponse session matcher =
  withTimeout (loop (0 :: Int))
 where
  loop skipped = do
    frameResult <- readFrame (brokerSessionSocket session)
    case frameResult of
      Left err -> pure (Left err)
      Right frame ->
        case matcher frame of
          Just result -> pure result
          Nothing ->
            case brokerFrameCommand frame of
              BrokerPing -> do
                _ <- sendFrame (brokerSessionSocket session) (buildSimpleFrame buildPongCommand)
                loop skipped
              BrokerPong -> loop skipped
              BrokerUnsupported code ->
                pure (Left (PulsarUnsupportedServerBehavior ("unsupported broker command type: " ++ show code)))
              _
                | skipped > 128 ->
                    pure
                      ( Left
                          ( PulsarUnsupportedServerBehavior
                              "too many unrelated broker frames while waiting for a correlated response"
                          )
                      )
              _ -> loop (skipped + 1)

matchProducerSuccess :: Word64 -> BrokerFrame -> Maybe (Either PulsarClientError ProducerSuccess)
matchProducerSuccess requestId frame =
  case brokerFrameCommand frame of
    BrokerProducerSuccess success
      | producerSuccessRequestId success == requestId -> Just (Right success)
    BrokerError errRequestId serverError message
      | errRequestId == requestId ->
          Just (Left (classifyServerError Nothing serverError (Text.unpack message)))
    _ -> Nothing

matchSendReceipt :: Word64 -> Word64 -> BrokerFrame -> Maybe (Either PulsarClientError SendReceipt)
matchSendReceipt producerId sequenceId frame =
  case brokerFrameCommand frame of
    BrokerSendReceipt receipt
      | sendReceiptProducerId receipt == producerId
          && sendReceiptSequenceId receipt == sequenceId ->
          Just (Right receipt)
    BrokerSendError sendError
      | sendErrorProducerId sendError == producerId
          && sendErrorSequenceId sendError == sequenceId ->
          Just
            ( Left
                (classifyServerError Nothing (sendErrorKind sendError) (Text.unpack (sendErrorMessage sendError)))
            )
    _ -> Nothing

matchMessage
  :: Word64 -> BrokerFrame -> Maybe (Either PulsarClientError (BrokerMessage, CborPayload))
matchMessage consumerId frame =
  case (brokerFrameCommand frame, brokerFramePayload frame) of
    (BrokerMessageCommand message, Just payload)
      | brokerMessageConsumerId message == consumerId -> Just (Right (message, payload))
    (BrokerMessageCommand message, Nothing)
      | brokerMessageConsumerId message == consumerId ->
          Just (Left (PulsarMalformedFrame "broker delivered a message command with no payload frame"))
    _ -> Nothing

matchAckResponse :: Word64 -> BrokerFrame -> Maybe (Either PulsarClientError ())
matchAckResponse requestId frame =
  case brokerFrameCommand frame of
    BrokerAckResponse response
      | ackResponseRequestId response == Just requestId ->
          case ackResponseError response of
            Nothing -> Just (Right ())
            Just serverError ->
              Just
                ( Left
                    ( classifyServerError
                        Nothing
                        serverError
                        (maybe "" Text.unpack (ackResponseMessage response))
                    )
                )
    BrokerError errRequestId serverError message
      | errRequestId == requestId ->
          Just (Left (classifyServerError Nothing serverError (Text.unpack message)))
    _ -> Nothing

matchSuccess :: Word64 -> BrokerFrame -> Maybe (Either PulsarClientError ())
matchSuccess requestId frame =
  case brokerFrameCommand frame of
    BrokerSuccess successRequestId
      | successRequestId == requestId -> Just (Right ())
    BrokerError errRequestId serverError message
      | errRequestId == requestId ->
          Just (Left (classifyServerError Nothing serverError (Text.unpack message)))
    _ -> Nothing

matchLookupResponse
  :: Word64 -> TopicName -> BrokerFrame -> Maybe (Either PulsarClientError LookupResponse)
matchLookupResponse requestId topic frame =
  case brokerFrameCommand frame of
    BrokerLookupResponse response
      | lookupResponseRequestId response == requestId -> Just (Right response)
    BrokerError errRequestId serverError message
      | errRequestId == requestId ->
          Just (Left (classifyServerError (Just topic) serverError (Text.unpack message)))
    _ -> Nothing

classifyServerError :: Maybe TopicName -> ServerError -> String -> PulsarClientError
classifyServerError maybeTopic serverError message =
  case serverError of
    ServerAuthenticationError -> PulsarAuthenticationFailed message
    ServerAuthorizationError -> PulsarAuthorizationFailed message
    ServerTopicNotFound ->
      case maybeTopic of
        Just topic -> PulsarTopicAbsent topic message
        Nothing -> PulsarBrokerError serverError message
    ServerChecksumError -> PulsarMalformedFrame message
    ServerUnsupportedVersionError -> PulsarUnsupportedServerBehavior message
    _ -> PulsarBrokerError serverError message

sendFrame :: Socket.Socket -> BS.ByteString -> IO (Either PulsarClientError ())
sendFrame socket bytes = do
  result <- try (SocketBS.sendAll socket bytes)
  case result of
    Left err -> pure (Left (PulsarBrokerUnreachable (show (err :: IOException))))
    Right () -> pure (Right ())

readFrame :: Socket.Socket -> IO (Either PulsarClientError BrokerFrame)
readFrame socket = do
  headerResult <- readExact socket 4
  case headerResult of
    Left err -> pure (Left err)
    Right header -> do
      case readFrameSize header of
        Left err -> pure (Left (PulsarMalformedFrame err))
        Right frameSize
          | frameSize > maxFrameSize -> pure (Left (PulsarMalformedFrame "Pulsar frame exceeds 5 MB limit"))
          | otherwise -> do
              bodyResult <- readExact socket (fromIntegral frameSize)
              case bodyResult of
                Left err -> pure (Left err)
                Right body ->
                  pure
                    ( case parseFrameBody body of
                        Left err -> Left (PulsarMalformedFrame err)
                        Right frame -> Right frame
                    )

readExact :: Socket.Socket -> Int -> IO (Either PulsarClientError BS.ByteString)
readExact socket wanted =
  go wanted []
 where
  go remaining chunks
    | remaining <= 0 = pure (Right (BS.concat (reverse chunks)))
    | otherwise = do
        result <- try (SocketBS.recv socket remaining)
        case result of
          Left err -> pure (Left (PulsarBrokerUnreachable (show (err :: IOException))))
          Right chunk
            | BS.null chunk -> pure (Left (PulsarBrokerUnreachable "broker closed the TCP connection"))
            | otherwise -> go (remaining - BS.length chunk) (chunk : chunks)

readFrameSize :: BS.ByteString -> Either String Word32
readFrameSize bytes
  | BS.length bytes /= 4 = Left "Pulsar frame size prefix must be exactly four bytes."
  | otherwise =
      Right
        ( (fromIntegral (BS.index bytes 0) `shiftL` 24)
            .|. (fromIntegral (BS.index bytes 1) `shiftL` 16)
            .|. (fromIntegral (BS.index bytes 2) `shiftL` 8)
            .|. fromIntegral (BS.index bytes 3)
        )

maxFrameSize :: Word32
maxFrameSize = 5 * 1024 * 1024

withTimeout :: IO (Either PulsarClientError a) -> IO (Either PulsarClientError a)
withTimeout action = do
  result <- timeout requestTimeoutMicros action
  case result of
    Nothing -> pure (Left (PulsarBrokerUnreachable "broker request timed out"))
    Just value -> pure value

requestTimeoutMicros :: Int
requestTimeoutMicros = 30000000

nextRequest :: PulsarConnection -> IO Word64
nextRequest connection =
  atomicModifyIORef'
    (pulsarConnectionIds connection)
    (\ids -> (ids {nextRequestId = nextRequestId ids + 1}, nextRequestId ids))

nextProducer :: PulsarConnection -> IO Word64
nextProducer connection =
  atomicModifyIORef'
    (pulsarConnectionIds connection)
    (\ids -> (ids {nextProducerId = nextProducerId ids + 1}, nextProducerId ids))

nextConsumer :: PulsarConnection -> IO Word64
nextConsumer connection =
  atomicModifyIORef'
    (pulsarConnectionIds connection)
    (\ids -> (ids {nextConsumerId = nextConsumerId ids + 1}, nextConsumerId ids))

nextSequence :: PulsarConnection -> IO Word64
nextSequence connection =
  atomicModifyIORef'
    (pulsarConnectionIds connection)
    (\ids -> (ids {nextSequenceId = nextSequenceId ids + 1}, nextSequenceId ids))

currentMillis :: IO Word64
currentMillis = do
  now <- getPOSIXTime
  pure (floor (now * 1000))
