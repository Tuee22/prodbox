{-# LANGUAGE DeriveGeneric #-}

module Prodbox.Pulsar.Client
  ( AckRequest (..)
  , ConsumeRequest (..)
  , MessageId (..)
  , ProduceReceipt (..)
  , ProduceRequest (..)
  , PulsarClientConfig (..)
  , PulsarClientError (..)
  , PulsarConnection (..)
  , SubscriptionName (..)
  , ack
  , connect
  , consume
  , produce
  , renderPulsarClientError
  )
where

import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.Cbor (CborPayload)
import Prodbox.Pulsar.Topic (TopicName)

data PulsarClientConfig = PulsarClientConfig
  { pulsarClientHost :: String
  , pulsarClientPort :: Int
  , pulsarClientName :: Text
  }
  deriving (Eq, Show, Generic)

data PulsarConnection = PulsarConnection
  { pulsarConnectionConfig :: PulsarClientConfig
  }
  deriving (Eq, Show, Generic)

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
  | PulsarBrokerProtocolUnavailable String
  deriving (Eq, Show)

connect :: PulsarClientConfig -> IO (Either PulsarClientError PulsarConnection)
connect config
  | null (pulsarClientHost config) =
      pure (Left (PulsarInvalidEndpoint "Pulsar host must not be empty."))
  | pulsarClientPort config <= 0 =
      pure (Left (PulsarInvalidEndpoint "Pulsar port must be positive."))
  | otherwise =
      pure (Right PulsarConnection {pulsarConnectionConfig = config})

produce :: PulsarConnection -> ProduceRequest -> IO (Either PulsarClientError ProduceReceipt)
produce _connection _request =
  unsupported "produce"

consume :: PulsarConnection -> ConsumeRequest -> IO (Either PulsarClientError (Maybe CborPayload))
consume _connection _request =
  unsupported "consume"

ack :: PulsarConnection -> AckRequest -> IO (Either PulsarClientError ())
ack _connection _request =
  unsupported "ack"

renderPulsarClientError :: PulsarClientError -> String
renderPulsarClientError err =
  case err of
    PulsarInvalidEndpoint message -> message
    PulsarBrokerProtocolUnavailable message -> message

unsupported :: String -> IO (Either PulsarClientError a)
unsupported operation =
  pure
    ( Left
        ( PulsarBrokerProtocolUnavailable
            ( "Pulsar "
                ++ operation
                ++ " requires the generated Apache Pulsar BaseCommand protocol layer; the prodbox CBOR/topic/envelope boundary is present, but broker I/O is not enabled."
            )
        )
    )
