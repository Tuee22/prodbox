{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Pulsar.Protocol
  ( AckResponse (..)
  , BrokerEndpoint (..)
  , BrokerFrame (..)
  , BrokerMessage (..)
  , BrokerResponse (..)
  , ConnectedResponse (..)
  , LookupResponse (..)
  , LookupResponseType (..)
  , MessageIdData (..)
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
  , crc32c
  , decodeMessageIdText
  , encodeMessageIdText
  , encodeMessageMetadata
  , parseBrokerServiceUrl
  , parseFrameBody
  , renderBrokerEndpoint
  , renderServerError
  )
where

import Data.Bits
  ( complement
  , shiftL
  , shiftR
  , testBit
  , xor
  , (.&.)
  , (.|.)
  )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Word
  ( Word16
  , Word32
  , Word64
  , Word8
  )
import Prodbox.Cbor
  ( CborPayload (..)
  )
import Prodbox.Pulsar.Topic
  ( TopicName
  , renderTopicName
  )

data BrokerEndpoint = BrokerEndpoint
  { brokerEndpointHost :: String
  , brokerEndpointPort :: Int
  }
  deriving (Eq, Show)

data MessageIdData = MessageIdData
  { messageIdLedgerId :: Word64
  , messageIdEntryId :: Word64
  , messageIdPartition :: Maybe Int
  , messageIdBatchIndex :: Maybe Int
  }
  deriving (Eq, Show)

data MessageMetadata = MessageMetadata
  { messageMetadataProducerName :: Text
  , messageMetadataSequenceId :: Word64
  , messageMetadataPublishTimeMillis :: Word64
  }
  deriving (Eq, Show)

data ConnectedResponse = ConnectedResponse
  { connectedServerVersion :: Text
  , connectedProtocolVersion :: Int
  , connectedMaxMessageSize :: Maybe Int
  }
  deriving (Eq, Show)

data LookupResponseType
  = LookupRedirect
  | LookupConnect
  | LookupFailed
  | LookupResponseUnknown Int
  deriving (Eq, Show)

data LookupResponse = LookupResponse
  { lookupResponseRequestId :: Word64
  , lookupResponseType :: LookupResponseType
  , lookupResponseBrokerServiceUrl :: Maybe String
  , lookupResponseAuthoritative :: Bool
  , lookupResponseError :: Maybe ServerError
  , lookupResponseMessage :: Maybe Text
  }
  deriving (Eq, Show)

data ProducerSuccess = ProducerSuccess
  { producerSuccessRequestId :: Word64
  , producerSuccessName :: Text
  , producerSuccessReady :: Bool
  }
  deriving (Eq, Show)

data SendReceipt = SendReceipt
  { sendReceiptProducerId :: Word64
  , sendReceiptSequenceId :: Word64
  , sendReceiptMessageId :: Maybe MessageIdData
  }
  deriving (Eq, Show)

data SendError = SendError
  { sendErrorProducerId :: Word64
  , sendErrorSequenceId :: Word64
  , sendErrorKind :: ServerError
  , sendErrorMessage :: Text
  }
  deriving (Eq, Show)

data BrokerMessage = BrokerMessage
  { brokerMessageConsumerId :: Word64
  , brokerMessageId :: MessageIdData
  }
  deriving (Eq, Show)

data AckResponse = AckResponse
  { ackResponseConsumerId :: Word64
  , ackResponseRequestId :: Maybe Word64
  , ackResponseError :: Maybe ServerError
  , ackResponseMessage :: Maybe Text
  }
  deriving (Eq, Show)

data ServerError
  = ServerUnknownError
  | ServerMetadataError
  | ServerPersistenceError
  | ServerAuthenticationError
  | ServerAuthorizationError
  | ServerConsumerBusy
  | ServerServiceNotReady
  | ServerProducerBlockedQuotaExceededError
  | ServerProducerBlockedQuotaExceededException
  | ServerChecksumError
  | ServerUnsupportedVersionError
  | ServerTopicNotFound
  | ServerSubscriptionNotFound
  | ServerConsumerNotFound
  | ServerTooManyRequests
  | ServerTopicTerminatedError
  | ServerProducerBusy
  | ServerInvalidTopicName
  | ServerIncompatibleSchema
  | ServerConsumerAssignError
  | ServerTransactionCoordinatorNotFound
  | ServerInvalidTxnStatus
  | ServerNotAllowedError
  | ServerTransactionConflict
  | ServerTransactionNotFound
  | ServerProducerFenced
  | ServerErrorUnknownCode Int
  deriving (Eq, Show)

data BrokerResponse
  = BrokerConnected ConnectedResponse
  | BrokerLookupResponse LookupResponse
  | BrokerProducerSuccess ProducerSuccess
  | BrokerSendReceipt SendReceipt
  | BrokerSendError SendError
  | BrokerMessageCommand BrokerMessage
  | BrokerAckResponse AckResponse
  | BrokerSuccess Word64
  | BrokerError Word64 ServerError Text
  | BrokerPing
  | BrokerPong
  | BrokerUnsupported Int
  deriving (Eq, Show)

data BrokerFrame = BrokerFrame
  { brokerFrameCommand :: BrokerResponse
  , brokerFrameMetadata :: Maybe MessageMetadata
  , brokerFramePayload :: Maybe CborPayload
  }
  deriving (Eq, Show)

data ProtoValue
  = ProtoVarint Word64
  | ProtoBytes ByteString
  | ProtoFixed32 Word32
  | ProtoFixed64 Word64
  deriving (Eq, Show)

type ProtoField = (Int, ProtoValue)

buildConnectCommand :: Text -> ByteString
buildConnectCommand clientVersion =
  encodeBaseCommand 2 2 $
    mconcat
      [ stringField 1 clientVersion
      , varintField 4 21
      ]

buildLookupCommand :: TopicName -> Word64 -> Bool -> ByteString
buildLookupCommand topic requestId authoritative =
  encodeBaseCommand 23 23 $
    mconcat
      [ stringField 1 (renderTopicName topic)
      , varintField 2 requestId
      , boolField 3 authoritative
      ]

buildProducerCommand :: TopicName -> Word64 -> Word64 -> ByteString
buildProducerCommand topic producerId requestId =
  encodeBaseCommand 5 5 $
    mconcat
      [ stringField 1 (renderTopicName topic)
      , varintField 2 producerId
      , varintField 3 requestId
      ]

buildSendCommand :: Word64 -> Word64 -> ByteString
buildSendCommand producerId sequenceId =
  encodeBaseCommand 6 6 $
    mconcat
      [ varintField 1 producerId
      , varintField 2 sequenceId
      , varintField 3 1
      ]

buildSubscribeCommand :: TopicName -> Text -> Word64 -> Word64 -> Text -> ByteString
buildSubscribeCommand topic subscription consumerId requestId consumerName =
  encodeBaseCommand 4 4 $
    mconcat
      [ stringField 1 (renderTopicName topic)
      , stringField 2 subscription
      , varintField 3 0
      , varintField 4 consumerId
      , varintField 5 requestId
      , stringField 6 consumerName
      , boolField 8 True
      , varintField 13 1
      ]

buildFlowCommand :: Word64 -> Word32 -> ByteString
buildFlowCommand consumerId permits =
  encodeBaseCommand 11 11 $
    mconcat
      [ varintField 1 consumerId
      , varintField 2 (fromIntegral permits)
      ]

buildAckCommand :: Word64 -> Word64 -> MessageIdData -> ByteString
buildAckCommand consumerId requestId messageId =
  encodeBaseCommand 10 10 $
    mconcat
      [ varintField 1 consumerId
      , varintField 2 0
      , bytesField 3 (encodeMessageIdData messageId)
      , varintField 8 requestId
      ]

buildPongCommand :: ByteString
buildPongCommand =
  encodeBaseCommand 19 19 BS.empty

encodeMessageMetadata :: MessageMetadata -> ByteString
encodeMessageMetadata metadata =
  mconcatBytes
    [ stringField 1 (messageMetadataProducerName metadata)
    , varintField 2 (messageMetadataSequenceId metadata)
    , varintField 3 (messageMetadataPublishTimeMillis metadata)
    , varintField 11 1
    ]

buildSimpleFrame :: ByteString -> ByteString
buildSimpleFrame commandBytes =
  prefixFrame (word32BEBytes (fromIntegral (BS.length commandBytes)) <> commandBytes)

buildPayloadFrame :: ByteString -> ByteString -> CborPayload -> ByteString
buildPayloadFrame commandBytes metadataBytes (CborPayload payloadBytes) =
  prefixFrame body
 where
  metadataAndPayload =
    mconcatBytes
      [ word32BEBytes (fromIntegral (BS.length metadataBytes))
      , metadataBytes
      , payloadBytes
      ]
  payloadBlock =
    mconcatBytes
      [ word16BEBytes 0x0e01
      , word32BEBytes (crc32c metadataAndPayload)
      , metadataAndPayload
      ]
  body =
    mconcatBytes
      [ word32BEBytes (fromIntegral (BS.length commandBytes))
      , commandBytes
      , payloadBlock
      ]

parseFrameBody :: ByteString -> Either String BrokerFrame
parseFrameBody body = do
  (commandSize, afterCommandSize) <- takeWord32BE body
  let commandSizeInt = fromIntegral commandSize
  if BS.length afterCommandSize < commandSizeInt
    then Left "Pulsar frame command size exceeds frame body."
    else do
      let (commandBytes, rest) = BS.splitAt commandSizeInt afterCommandSize
      command <- parseBaseCommand commandBytes
      case BS.null rest of
        True ->
          Right
            BrokerFrame
              { brokerFrameCommand = command
              , brokerFrameMetadata = Nothing
              , brokerFramePayload = Nothing
              }
        False -> do
          (metadata, payload) <- parsePayloadBlock rest
          Right
            BrokerFrame
              { brokerFrameCommand = command
              , brokerFrameMetadata = Just metadata
              , brokerFramePayload = Just payload
              }

parseBrokerServiceUrl :: String -> Either String BrokerEndpoint
parseBrokerServiceUrl raw =
  let withoutScheme =
        fromMaybe raw $
          stripPrefixString "pulsar://" raw
            <|> stripPrefixString "pulsar+ssl://" raw
      (hostPart, portPartWithColon) = break (== ':') withoutScheme
      portPart = drop 1 portPartWithColon
   in if null hostPart
        then Left ("Pulsar broker service URL has no host: " ++ raw)
        else
          if null portPart
            then Right BrokerEndpoint {brokerEndpointHost = hostPart, brokerEndpointPort = 6650}
            else case parsePositiveInt portPart of
              Just port -> Right BrokerEndpoint {brokerEndpointHost = hostPart, brokerEndpointPort = port}
              Nothing -> Left ("Pulsar broker service URL has an invalid port: " ++ raw)

renderBrokerEndpoint :: BrokerEndpoint -> String
renderBrokerEndpoint endpoint =
  brokerEndpointHost endpoint ++ ":" ++ show (brokerEndpointPort endpoint)

encodeMessageIdText :: MessageIdData -> Text
encodeMessageIdText messageId =
  Text.intercalate
    ":"
    ( map
        (Text.pack . show)
        ( [ fromIntegral (messageIdLedgerId messageId) :: Integer
          , fromIntegral (messageIdEntryId messageId) :: Integer
          ]
            ++ maybe [] (\partition -> [fromIntegral partition :: Integer]) (messageIdPartition messageId)
            ++ maybe [] (\batchIndex -> [fromIntegral batchIndex :: Integer]) (messageIdBatchIndex messageId)
        )
    )

decodeMessageIdText :: Text -> Either String MessageIdData
decodeMessageIdText raw =
  case Text.splitOn ":" raw of
    [ledgerText, entryText] -> do
      ledgerId <- parseUnsignedText (Text.unpack ledgerText)
      entryId <- parseUnsignedText (Text.unpack entryText)
      Right
        MessageIdData
          { messageIdLedgerId = ledgerId
          , messageIdEntryId = entryId
          , messageIdPartition = Nothing
          , messageIdBatchIndex = Nothing
          }
    [ledgerText, entryText, partitionText] -> do
      ledgerId <- parseUnsignedText (Text.unpack ledgerText)
      entryId <- parseUnsignedText (Text.unpack entryText)
      partition <- parseSignedText (Text.unpack partitionText)
      Right
        MessageIdData
          { messageIdLedgerId = ledgerId
          , messageIdEntryId = entryId
          , messageIdPartition = Just partition
          , messageIdBatchIndex = Nothing
          }
    [ledgerText, entryText, partitionText, batchIndexText] -> do
      ledgerId <- parseUnsignedText (Text.unpack ledgerText)
      entryId <- parseUnsignedText (Text.unpack entryText)
      partition <- parseSignedText (Text.unpack partitionText)
      batchIndex <- parseSignedText (Text.unpack batchIndexText)
      Right
        MessageIdData
          { messageIdLedgerId = ledgerId
          , messageIdEntryId = entryId
          , messageIdPartition = Just partition
          , messageIdBatchIndex = Just batchIndex
          }
    _ -> Left ("Pulsar message id must be ledger:entry[:partition[:batch]], got: " ++ Text.unpack raw)

renderServerError :: ServerError -> String
renderServerError err =
  case err of
    ServerUnknownError -> "UnknownError"
    ServerMetadataError -> "MetadataError"
    ServerPersistenceError -> "PersistenceError"
    ServerAuthenticationError -> "AuthenticationError"
    ServerAuthorizationError -> "AuthorizationError"
    ServerConsumerBusy -> "ConsumerBusy"
    ServerServiceNotReady -> "ServiceNotReady"
    ServerProducerBlockedQuotaExceededError -> "ProducerBlockedQuotaExceededError"
    ServerProducerBlockedQuotaExceededException -> "ProducerBlockedQuotaExceededException"
    ServerChecksumError -> "ChecksumError"
    ServerUnsupportedVersionError -> "UnsupportedVersionError"
    ServerTopicNotFound -> "TopicNotFound"
    ServerSubscriptionNotFound -> "SubscriptionNotFound"
    ServerConsumerNotFound -> "ConsumerNotFound"
    ServerTooManyRequests -> "TooManyRequests"
    ServerTopicTerminatedError -> "TopicTerminatedError"
    ServerProducerBusy -> "ProducerBusy"
    ServerInvalidTopicName -> "InvalidTopicName"
    ServerIncompatibleSchema -> "IncompatibleSchema"
    ServerConsumerAssignError -> "ConsumerAssignError"
    ServerTransactionCoordinatorNotFound -> "TransactionCoordinatorNotFound"
    ServerInvalidTxnStatus -> "InvalidTxnStatus"
    ServerNotAllowedError -> "NotAllowedError"
    ServerTransactionConflict -> "TransactionConflict"
    ServerTransactionNotFound -> "TransactionNotFound"
    ServerProducerFenced -> "ProducerFenced"
    ServerErrorUnknownCode code -> "ServerError(" ++ show code ++ ")"

crc32c :: ByteString -> Word32
crc32c bytes =
  complement (BS.foldl' step 0xffffffff bytes)
 where
  step :: Word32 -> Word8 -> Word32
  step crc byte =
    iterateBit 8 (crc `xor` fromIntegral byte)
  iterateBit :: Int -> Word32 -> Word32
  iterateBit 0 crc = crc
  iterateBit n crc =
    iterateBit
      (n - 1)
      ( if testBit crc 0
          then (crc `shiftR` 1) `xor` 0x82f63b78
          else crc `shiftR` 1
      )

parsePayloadBlock :: ByteString -> Either String (MessageMetadata, CborPayload)
parsePayloadBlock raw = do
  withoutBrokerMetadata <- dropBrokerEntryMetadata raw
  (magic, afterMagic) <- takeWord16BE withoutBrokerMetadata
  if magic /= 0x0e01
    then Left "Pulsar payload frame is missing the 0x0e01 magic number."
    else do
      (observedChecksum, afterChecksum) <- takeWord32BE afterMagic
      let expectedChecksum = crc32c afterChecksum
      if observedChecksum /= expectedChecksum
        then Left "Pulsar payload frame CRC32C checksum mismatch."
        else do
          (metadataSize, afterMetadataSize) <- takeWord32BE afterChecksum
          let metadataSizeInt = fromIntegral metadataSize
          if BS.length afterMetadataSize < metadataSizeInt
            then Left "Pulsar payload metadata size exceeds frame body."
            else do
              let (metadataBytes, payloadBytes) = BS.splitAt metadataSizeInt afterMetadataSize
              metadata <- parseMessageMetadata metadataBytes
              Right (metadata, CborPayload payloadBytes)

dropBrokerEntryMetadata :: ByteString -> Either String ByteString
dropBrokerEntryMetadata bytes =
  case readWord16BEAt 0 bytes of
    Just 0x0e02 -> do
      (_, afterMagic) <- takeWord16BE bytes
      (metadataSize, afterSize) <- takeWord32BE afterMagic
      let metadataSizeInt = fromIntegral metadataSize
      if BS.length afterSize < metadataSizeInt
        then Left "Pulsar broker-entry metadata size exceeds frame body."
        else Right (BS.drop metadataSizeInt afterSize)
    _ -> Right bytes

parseBaseCommand :: ByteString -> Either String BrokerResponse
parseBaseCommand bytes = do
  fields <- parseFields bytes
  commandType <- requiredEnumField "BaseCommand.type" 1 fields
  case commandType of
    3 -> BrokerConnected <$> (parseConnected =<< requiredMessageField "BaseCommand.connected" 3 fields)
    7 ->
      BrokerSendReceipt
        <$> (parseSendReceipt =<< requiredMessageField "BaseCommand.send_receipt" 7 fields)
    8 -> BrokerSendError <$> (parseSendError =<< requiredMessageField "BaseCommand.send_error" 8 fields)
    9 ->
      BrokerMessageCommand
        <$> (parseBrokerMessage =<< requiredMessageField "BaseCommand.message" 9 fields)
    13 -> BrokerSuccess <$> (parseSuccess =<< requiredMessageField "BaseCommand.success" 13 fields)
    14 -> parseCommandError =<< requiredMessageField "BaseCommand.error" 14 fields
    17 ->
      BrokerProducerSuccess
        <$> (parseProducerSuccess =<< requiredMessageField "BaseCommand.producer_success" 17 fields)
    18 -> Right BrokerPing
    19 -> Right BrokerPong
    24 ->
      BrokerLookupResponse
        <$> (parseLookupResponse =<< requiredMessageField "BaseCommand.lookupTopicResponse" 24 fields)
    38 ->
      BrokerAckResponse
        <$> (parseAckResponse =<< requiredMessageField "BaseCommand.ackResponse" 38 fields)
    other -> Right (BrokerUnsupported other)

parseConnected :: ByteString -> Either String ConnectedResponse
parseConnected bytes = do
  fields <- parseFields bytes
  serverVersion <- requiredTextField "CommandConnected.server_version" 1 fields
  Right
    ConnectedResponse
      { connectedServerVersion = serverVersion
      , connectedProtocolVersion = fromIntegral (optionalVarintField 2 fields 0)
      , connectedMaxMessageSize = fmap fromIntegral (fieldVarint 3 fields)
      }

parseLookupResponse :: ByteString -> Either String LookupResponse
parseLookupResponse bytes = do
  fields <- parseFields bytes
  requestId <- requiredVarintField "CommandLookupTopicResponse.request_id" 4 fields
  Right
    LookupResponse
      { lookupResponseRequestId = requestId
      , lookupResponseType = lookupTypeFromInt (fromIntegral (optionalVarintField 3 fields 2))
      , lookupResponseBrokerServiceUrl = fmap Text.unpack (fieldText 1 fields)
      , lookupResponseAuthoritative = optionalBoolField 5 fields False
      , lookupResponseError = fmap (serverErrorFromInt . fromIntegral) (fieldVarint 6 fields)
      , lookupResponseMessage = fieldText 7 fields
      }

parseProducerSuccess :: ByteString -> Either String ProducerSuccess
parseProducerSuccess bytes = do
  fields <- parseFields bytes
  requestId <- requiredVarintField "CommandProducerSuccess.request_id" 1 fields
  producerName <- requiredTextField "CommandProducerSuccess.producer_name" 2 fields
  Right
    ProducerSuccess
      { producerSuccessRequestId = requestId
      , producerSuccessName = producerName
      , producerSuccessReady = optionalBoolField 6 fields True
      }

parseSendReceipt :: ByteString -> Either String SendReceipt
parseSendReceipt bytes = do
  fields <- parseFields bytes
  producerId <- requiredVarintField "CommandSendReceipt.producer_id" 1 fields
  sequenceId <- requiredVarintField "CommandSendReceipt.sequence_id" 2 fields
  messageId <- traverse parseMessageIdData (fieldBytes 3 fields)
  Right
    SendReceipt
      { sendReceiptProducerId = producerId
      , sendReceiptSequenceId = sequenceId
      , sendReceiptMessageId = messageId
      }

parseSendError :: ByteString -> Either String SendError
parseSendError bytes = do
  fields <- parseFields bytes
  producerId <- requiredVarintField "CommandSendError.producer_id" 1 fields
  sequenceId <- requiredVarintField "CommandSendError.sequence_id" 2 fields
  errorKind <-
    serverErrorFromInt . fromIntegral <$> requiredVarintField "CommandSendError.error" 3 fields
  message <- requiredTextField "CommandSendError.message" 4 fields
  Right
    SendError
      { sendErrorProducerId = producerId
      , sendErrorSequenceId = sequenceId
      , sendErrorKind = errorKind
      , sendErrorMessage = message
      }

parseBrokerMessage :: ByteString -> Either String BrokerMessage
parseBrokerMessage bytes = do
  fields <- parseFields bytes
  consumerId <- requiredVarintField "CommandMessage.consumer_id" 1 fields
  messageId <- parseMessageIdData =<< requiredMessageField "CommandMessage.message_id" 2 fields
  Right
    BrokerMessage
      { brokerMessageConsumerId = consumerId
      , brokerMessageId = messageId
      }

parseAckResponse :: ByteString -> Either String AckResponse
parseAckResponse bytes = do
  fields <- parseFields bytes
  consumerId <- requiredVarintField "CommandAckResponse.consumer_id" 1 fields
  Right
    AckResponse
      { ackResponseConsumerId = consumerId
      , ackResponseRequestId = fieldVarint 6 fields
      , ackResponseError = fmap (serverErrorFromInt . fromIntegral) (fieldVarint 4 fields)
      , ackResponseMessage = fieldText 5 fields
      }

parseSuccess :: ByteString -> Either String Word64
parseSuccess bytes = do
  fields <- parseFields bytes
  requiredVarintField "CommandSuccess.request_id" 1 fields

parseCommandError :: ByteString -> Either String BrokerResponse
parseCommandError bytes = do
  fields <- parseFields bytes
  requestId <- requiredVarintField "CommandError.request_id" 1 fields
  errorKind <- serverErrorFromInt . fromIntegral <$> requiredVarintField "CommandError.error" 2 fields
  message <- requiredTextField "CommandError.message" 3 fields
  Right (BrokerError requestId errorKind message)

parseMessageMetadata :: ByteString -> Either String MessageMetadata
parseMessageMetadata bytes = do
  fields <- parseFields bytes
  producerName <- requiredTextField "MessageMetadata.producer_name" 1 fields
  sequenceId <- requiredVarintField "MessageMetadata.sequence_id" 2 fields
  publishTime <- requiredVarintField "MessageMetadata.publish_time" 3 fields
  Right
    MessageMetadata
      { messageMetadataProducerName = producerName
      , messageMetadataSequenceId = sequenceId
      , messageMetadataPublishTimeMillis = publishTime
      }

parseMessageIdData :: ByteString -> Either String MessageIdData
parseMessageIdData bytes = do
  fields <- parseFields bytes
  ledgerId <- requiredVarintField "MessageIdData.ledgerId" 1 fields
  entryId <- requiredVarintField "MessageIdData.entryId" 2 fields
  Right
    MessageIdData
      { messageIdLedgerId = ledgerId
      , messageIdEntryId = entryId
      , messageIdPartition = fmap fromIntegral (fieldVarint 3 fields)
      , messageIdBatchIndex = fmap fromIntegral (fieldVarint 4 fields)
      }

encodeMessageIdData :: MessageIdData -> ByteString
encodeMessageIdData messageId =
  mconcatBytes
    ( [ varintField 1 (messageIdLedgerId messageId)
      , varintField 2 (messageIdEntryId messageId)
      ]
        ++ maybe [] (\partition -> [varintField 3 (fromIntegral partition)]) (messageIdPartition messageId)
        ++ maybe [] (\batchIndex -> [varintField 4 (fromIntegral batchIndex)]) (messageIdBatchIndex messageId)
    )

lookupTypeFromInt :: Int -> LookupResponseType
lookupTypeFromInt value =
  case value of
    0 -> LookupRedirect
    1 -> LookupConnect
    2 -> LookupFailed
    other -> LookupResponseUnknown other

serverErrorFromInt :: Int -> ServerError
serverErrorFromInt value =
  case value of
    0 -> ServerUnknownError
    1 -> ServerMetadataError
    2 -> ServerPersistenceError
    3 -> ServerAuthenticationError
    4 -> ServerAuthorizationError
    5 -> ServerConsumerBusy
    6 -> ServerServiceNotReady
    7 -> ServerProducerBlockedQuotaExceededError
    8 -> ServerProducerBlockedQuotaExceededException
    9 -> ServerChecksumError
    10 -> ServerUnsupportedVersionError
    11 -> ServerTopicNotFound
    12 -> ServerSubscriptionNotFound
    13 -> ServerConsumerNotFound
    14 -> ServerTooManyRequests
    15 -> ServerTopicTerminatedError
    16 -> ServerProducerBusy
    17 -> ServerInvalidTopicName
    18 -> ServerIncompatibleSchema
    19 -> ServerConsumerAssignError
    20 -> ServerTransactionCoordinatorNotFound
    21 -> ServerInvalidTxnStatus
    22 -> ServerNotAllowedError
    23 -> ServerTransactionConflict
    24 -> ServerTransactionNotFound
    25 -> ServerProducerFenced
    other -> ServerErrorUnknownCode other

requiredEnumField :: String -> Int -> [ProtoField] -> Either String Int
requiredEnumField label fieldNumber fields =
  fromIntegral <$> requiredVarintField label fieldNumber fields

requiredVarintField :: String -> Int -> [ProtoField] -> Either String Word64
requiredVarintField label fieldNumber fields =
  case fieldVarint fieldNumber fields of
    Just value -> Right value
    Nothing -> Left (label ++ " is missing.")

optionalVarintField :: Int -> [ProtoField] -> Word64 -> Word64
optionalVarintField fieldNumber fields fallback =
  fromMaybe fallback (fieldVarint fieldNumber fields)

optionalBoolField :: Int -> [ProtoField] -> Bool -> Bool
optionalBoolField fieldNumber fields fallback =
  case fieldVarint fieldNumber fields of
    Just 0 -> False
    Just _ -> True
    Nothing -> fallback

requiredTextField :: String -> Int -> [ProtoField] -> Either String Text
requiredTextField label fieldNumber fields =
  case fieldText fieldNumber fields of
    Just value -> Right value
    Nothing -> Left (label ++ " is missing.")

requiredMessageField :: String -> Int -> [ProtoField] -> Either String ByteString
requiredMessageField label fieldNumber fields =
  case fieldBytes fieldNumber fields of
    Just value -> Right value
    Nothing -> Left (label ++ " is missing.")

fieldVarint :: Int -> [ProtoField] -> Maybe Word64
fieldVarint fieldNumber fields =
  listToMaybeReversed
    [value | (number, ProtoVarint value) <- fields, number == fieldNumber]

fieldBytes :: Int -> [ProtoField] -> Maybe ByteString
fieldBytes fieldNumber fields =
  listToMaybeReversed
    [value | (number, ProtoBytes value) <- fields, number == fieldNumber]

fieldText :: Int -> [ProtoField] -> Maybe Text
fieldText fieldNumber fields = do
  bytes <- fieldBytes fieldNumber fields
  case Text.decodeUtf8' bytes of
    Left _ -> Nothing
    Right value -> Just value

listToMaybeReversed :: [a] -> Maybe a
listToMaybeReversed values =
  case reverse values of
    [] -> Nothing
    value : _ -> Just value

parseFields :: ByteString -> Either String [ProtoField]
parseFields bytes =
  go 0 []
 where
  go offset acc
    | offset == BS.length bytes = Right (reverse acc)
    | offset > BS.length bytes = Left "protobuf parser advanced past input."
    | otherwise = do
        (tag, afterTag) <- readVarintAt offset bytes
        let fieldNumber = fromIntegral (tag `shiftR` 3)
            wireType = fromIntegral (tag .&. 0x07) :: Int
        case wireType of
          0 -> do
            (value, next) <- readVarintAt afterTag bytes
            go next ((fieldNumber, ProtoVarint value) : acc)
          1 -> do
            (value, next) <- readFixed64At afterTag bytes
            go next ((fieldNumber, ProtoFixed64 value) : acc)
          2 -> do
            (len, afterLen) <- readVarintAt afterTag bytes
            let lenInt = fromIntegral len
            if BS.length bytes - afterLen < lenInt
              then Left "protobuf length-delimited field exceeds input."
              else
                go
                  (afterLen + lenInt)
                  ((fieldNumber, ProtoBytes (BS.take lenInt (BS.drop afterLen bytes))) : acc)
          5 -> do
            (value, next) <- readFixed32At afterTag bytes
            go next ((fieldNumber, ProtoFixed32 value) : acc)
          _ -> Left ("unsupported protobuf wire type: " ++ show wireType)

readVarintAt :: Int -> ByteString -> Either String (Word64, Int)
readVarintAt start bytes =
  go start 0 0
 where
  go offset shift acc
    | offset >= BS.length bytes = Left "unterminated protobuf varint."
    | shift >= 64 = Left "protobuf varint exceeds 64 bits."
    | otherwise =
        let byte = BS.index bytes offset
            acc' = acc .|. (fromIntegral (byte .&. 0x7f) `shiftL` shift)
         in if byte .&. 0x80 == 0
              then Right (acc', offset + 1)
              else go (offset + 1) (shift + 7) acc'

readFixed32At :: Int -> ByteString -> Either String (Word32, Int)
readFixed32At offset bytes =
  if BS.length bytes - offset < 4
    then Left "protobuf fixed32 field exceeds input."
    else
      Right
        ( fromIntegral (BS.index bytes offset)
            .|. (fromIntegral (BS.index bytes (offset + 1)) `shiftL` 8)
            .|. (fromIntegral (BS.index bytes (offset + 2)) `shiftL` 16)
            .|. (fromIntegral (BS.index bytes (offset + 3)) `shiftL` 24)
        , offset + 4
        )

readFixed64At :: Int -> ByteString -> Either String (Word64, Int)
readFixed64At offset bytes =
  if BS.length bytes - offset < 8
    then Left "protobuf fixed64 field exceeds input."
    else
      Right
        ( foldr
            (.|.)
            0
            [fromIntegral (BS.index bytes (offset + n)) `shiftL` (8 * n) | n <- [0 .. 7]]
        , offset + 8
        )

encodeBaseCommand :: Word64 -> Int -> ByteString -> ByteString
encodeBaseCommand commandType commandField commandPayload =
  mconcatBytes
    [ varintField 1 commandType
    , bytesField commandField commandPayload
    ]

varintField :: Int -> Word64 -> ByteString
varintField fieldNumber value =
  mconcatBytes [encodeVarint (fromIntegral (fieldNumber `shiftL` 3) :: Word64), encodeVarint value]

boolField :: Int -> Bool -> ByteString
boolField fieldNumber value =
  varintField fieldNumber (if value then 1 else 0)

stringField :: Int -> Text -> ByteString
stringField fieldNumber value =
  bytesField fieldNumber (Text.encodeUtf8 value)

bytesField :: Int -> ByteString -> ByteString
bytesField fieldNumber value =
  mconcatBytes
    [ encodeVarint (fromIntegral ((fieldNumber `shiftL` 3) .|. 2))
    , encodeVarint (fromIntegral (BS.length value))
    , value
    ]

encodeVarint :: Word64 -> ByteString
encodeVarint value =
  BS.pack (go value)
 where
  go n
    | n < 0x80 = [fromIntegral n]
    | otherwise = fromIntegral ((n .&. 0x7f) .|. 0x80) : go (n `shiftR` 7)

prefixFrame :: ByteString -> ByteString
prefixFrame body =
  word32BEBytes (fromIntegral (BS.length body)) <> body

takeWord16BE :: ByteString -> Either String (Word16, ByteString)
takeWord16BE bytes =
  case readWord16BEAt 0 bytes of
    Nothing -> Left "expected 2-byte big-endian field."
    Just value -> Right (value, BS.drop 2 bytes)

takeWord32BE :: ByteString -> Either String (Word32, ByteString)
takeWord32BE bytes =
  case readWord32BEAt 0 bytes of
    Nothing -> Left "expected 4-byte big-endian field."
    Just value -> Right (value, BS.drop 4 bytes)

readWord16BEAt :: Int -> ByteString -> Maybe Word16
readWord16BEAt offset bytes
  | BS.length bytes - offset < 2 = Nothing
  | otherwise =
      Just
        ( (fromIntegral (BS.index bytes offset) `shiftL` 8)
            .|. fromIntegral (BS.index bytes (offset + 1))
        )

readWord32BEAt :: Int -> ByteString -> Maybe Word32
readWord32BEAt offset bytes
  | BS.length bytes - offset < 4 = Nothing
  | otherwise =
      Just
        ( (fromIntegral (BS.index bytes offset) `shiftL` 24)
            .|. (fromIntegral (BS.index bytes (offset + 1)) `shiftL` 16)
            .|. (fromIntegral (BS.index bytes (offset + 2)) `shiftL` 8)
            .|. fromIntegral (BS.index bytes (offset + 3))
        )

word16BEBytes :: Word16 -> ByteString
word16BEBytes value =
  BS.pack
    [ fromIntegral (value `shiftR` 8)
    , fromIntegral value
    ]

word32BEBytes :: Word32 -> ByteString
word32BEBytes value =
  BS.pack
    [ fromIntegral (value `shiftR` 24)
    , fromIntegral (value `shiftR` 16)
    , fromIntegral (value `shiftR` 8)
    , fromIntegral value
    ]

mconcatBytes :: [ByteString] -> ByteString
mconcatBytes =
  BL.toStrict . Builder.toLazyByteString . foldMap Builder.byteString

stripPrefixString :: String -> String -> Maybe String
stripPrefixString prefix value =
  if prefix `isPrefixOfString` value
    then Just (drop (length prefix) value)
    else Nothing

isPrefixOfString :: String -> String -> Bool
isPrefixOfString prefix value =
  take (length prefix) value == prefix

parsePositiveInt :: String -> Maybe Int
parsePositiveInt value
  | null value = Nothing
  | all isDigit value =
      case reads value of
        [(parsed, "")] | parsed > 0 -> Just parsed
        _ -> Nothing
  | otherwise = Nothing

parseUnsignedText :: String -> Either String Word64
parseUnsignedText value
  | null value = Left "Pulsar message id contains an empty segment."
  | all isDigit value =
      case reads value of
        [(parsed, "")] -> Right parsed
        _ -> Left ("Pulsar message id segment is out of range: " ++ value)
  | otherwise = Left ("Pulsar message id segment is not numeric: " ++ value)

parseSignedText :: String -> Either String Int
parseSignedText value
  | null value = Left "Pulsar message id contains an empty segment."
  | signedDigits value =
      case reads value of
        [(parsed, "")] -> Right parsed
        _ -> Left ("Pulsar message id segment is out of range: " ++ value)
  | otherwise = Left ("Pulsar message id segment is not numeric: " ++ value)
 where
  signedDigits ('-' : rest) = not (null rest) && all isDigit rest
  signedDigits rest = all isDigit rest

(<|>) :: Maybe a -> Maybe a -> Maybe a
Nothing <|> right = right
left <|> _ = left
