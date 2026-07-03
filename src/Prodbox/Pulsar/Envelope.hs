{-# LANGUAGE DeriveGeneric #-}

module Prodbox.Pulsar.Envelope
  ( CallId (..)
  , RejectReason (..)
  , WorkCommand (..)
  , WorkEvent (..)
  , WorkResult (..)
  , WorkStatus (..)
  , decodeWorkCommand
  , decodeWorkEvent
  , decodeWorkResult
  , encodeWorkCommand
  , encodeWorkEvent
  , encodeWorkResult
  )
where

import Codec.Serialise (Serialise)
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.Cbor (CborPayload)
import Prodbox.Pulsar.Codec
  ( decodePayload
  , encodePayload
  )
import Prodbox.Pulsar.Topic
  ( Lane
  , Workflow
  )

newtype CallId = CallId Text
  deriving (Eq, Ord, Show, Generic)

instance Serialise CallId

newtype RejectReason = RejectReason Text
  deriving (Eq, Ord, Show, Generic)

instance Serialise RejectReason

data WorkCommand = WorkCommand
  { wcCallId :: CallId
  , wcWorkflow :: Workflow
  , wcLane :: Lane
  , wcPayload :: CborPayload
  }
  deriving (Eq, Show, Generic)

instance Serialise WorkCommand

data WorkEvent = WorkEvent
  { weCallId :: CallId
  , wePayload :: CborPayload
  }
  deriving (Eq, Show, Generic)

instance Serialise WorkEvent

data WorkResult = WorkResult
  { wrCallId :: CallId
  , wrStatus :: WorkStatus
  , wrPayload :: CborPayload
  }
  deriving (Eq, Show, Generic)

instance Serialise WorkResult

data WorkStatus
  = WorkSucceeded
  | WorkRejected RejectReason
  deriving (Eq, Show, Generic)

instance Serialise WorkStatus

encodeWorkCommand :: WorkCommand -> CborPayload
encodeWorkCommand =
  encodePayload

decodeWorkCommand :: CborPayload -> Either String WorkCommand
decodeWorkCommand =
  decodePayload

encodeWorkEvent :: WorkEvent -> CborPayload
encodeWorkEvent =
  encodePayload

decodeWorkEvent :: CborPayload -> Either String WorkEvent
decodeWorkEvent =
  decodePayload

encodeWorkResult :: WorkResult -> CborPayload
encodeWorkResult =
  encodePayload

decodeWorkResult :: CborPayload -> Either String WorkResult
decodeWorkResult =
  decodePayload
