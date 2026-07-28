{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Bounded canonical-CBOR codec for retained operation records.
module Prodbox.Lifecycle.Authority.OperationStore
  ( OperationStoreCodecError (..)
  , operationRecordCodec
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Authority.Operation (OperationRecord)
import Prodbox.Lifecycle.CheckpointAuthority (ModelBCodec (..))

data OperationEnvelope binding intent result = OperationEnvelope
  { operationEnvelopeVersion :: !Word16
  , operationEnvelopeRecord :: !(OperationRecord binding intent result)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data OperationStoreCodecError
  = OperationStoreEnvelopeTooLarge !Int !Int
  | OperationStoreEnvelopeInvalid
  | OperationStoreEnvelopeUnsupportedVersion !Word16
  | OperationStoreEnvelopeNonCanonical
  deriving stock (Eq, Show)

operationRecordCodec
  :: (Serialise binding, Serialise intent, Serialise result)
  => Int
  -> ModelBCodec (OperationRecord binding intent result)
operationRecordCodec maximumBytes =
  ModelBCodec
    { encodeModelBValue = encodeRecord maximumBytes
    , decodeModelBValue = decodeRecord maximumBytes
    }

encodeRecord
  :: (Serialise binding, Serialise intent, Serialise result)
  => Int
  -> OperationRecord binding intent result
  -> Either String ByteString
encodeRecord maximumBytes record =
  let bytes =
        LazyByteString.toStrict
          ( serialise
              OperationEnvelope
                { operationEnvelopeVersion = currentVersion
                , operationEnvelopeRecord = record
                }
          )
   in if ByteString.length bytes > maximumBytes
        then Left (show (OperationStoreEnvelopeTooLarge (ByteString.length bytes) maximumBytes))
        else Right bytes

decodeRecord
  :: (Serialise binding, Serialise intent, Serialise result)
  => Int
  -> ByteString
  -> Either String (OperationRecord binding intent result)
decodeRecord maximumBytes bytes
  | maximumBytes < 0 || ByteString.length bytes > maximumBytes =
      Left (show (OperationStoreEnvelopeTooLarge (ByteString.length bytes) maximumBytes))
  | otherwise =
      case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left (show OperationStoreEnvelopeInvalid)
        Right envelope
          | operationEnvelopeVersion envelope /= currentVersion ->
              Left
                ( show
                    ( OperationStoreEnvelopeUnsupportedVersion
                        (operationEnvelopeVersion envelope)
                    )
                )
          | LazyByteString.toStrict (serialise envelope) /= bytes ->
              Left (show OperationStoreEnvelopeNonCanonical)
          | otherwise -> Right (operationEnvelopeRecord envelope)

currentVersion :: Word16
currentVersion = 1
