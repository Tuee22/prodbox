{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Daemon.Events
  ( AggregateId (..)
  , EventHandler (..)
  , EventId (..)
  , EventStore
  , EventType (..)
  , StoredEvent (..)
  , decodeStoredEventCbor
  , encodeStoredEventCbor
  , fetchUnprocessedEvents
  , lookupProcessedAt
  , markEventProcessed
  , newEventStore
  , processEvents
  , recordEvent
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  )
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as BL
import Data.List (sortOn)
import Data.Maybe (isNothing)
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)
import Prodbox.Cbor (CborPayload)

newtype EventId = EventId {unEventId :: String}
  deriving (Eq, Ord, Show, Generic)

instance Serialise EventId

newtype AggregateId = AggregateId {unAggregateId :: String}
  deriving (Eq, Ord, Show, Generic)

instance Serialise AggregateId

newtype EventType = EventType {unEventType :: String}
  deriving (Eq, Ord, Show, Generic)

instance Serialise EventType

data StoredEvent = StoredEvent
  { eventId :: EventId
  , eventAggregateId :: AggregateId
  , eventType :: EventType
  , eventPayload :: CborPayload
  , eventCreatedAt :: UTCTime
  , eventProcessedAt :: Maybe UTCTime
  }
  deriving (Eq, Show, Generic)

instance Serialise StoredEvent

newtype EventStore = EventStore (TVar [StoredEvent])

-- | Handlers must be idempotent: replaying the same event after a crash must
-- produce the same durable result as handling it once.
newtype EventHandler = EventHandler {runEventHandler :: StoredEvent -> IO ()}

encodeStoredEventCbor :: StoredEvent -> BL.ByteString
encodeStoredEventCbor = serialise

decodeStoredEventCbor :: BL.ByteString -> Either String StoredEvent
decodeStoredEventCbor =
  first (("failed to decode StoredEvent CBOR: " ++) . show) . deserialiseOrFail

newEventStore :: [StoredEvent] -> IO EventStore
newEventStore events =
  EventStore <$> newTVarIO (sortEvents events)

recordEvent :: EventStore -> StoredEvent -> IO ()
recordEvent (EventStore storeVar) event =
  atomically $
    modifyTVar' storeVar $ \events ->
      if any ((== eventId event) . eventId) events
        then events
        else sortEvents (event : events)

-- | Mark an event processed, first-write-wins. The write fires only when the
-- event's @processed_at@ is still NULL ('eventProcessedAt' is 'Nothing'); a
-- later redelivery of the same event finds it already stamped and is a no-op.
-- This is the IS-NULL guard from the streaming doctrine's at-least-once
-- contract — an authoritative, load-bearing invariant, not an optimization:
-- it pins a single processing timestamp per event no matter how many times a
-- concurrent processor replays it, so the delivery-state audit trail is not
-- corrupted by a redelivery overwriting the original.
--
-- This is the durable at-least-once REFERENCE port. The gateway peer-gossip
-- anti-entropy commit log is intentionally the non-durable variant and must
-- not adopt this guard (per pure_fp_standards.md §6.3 / streaming_doctrine.md).
markEventProcessed :: EventStore -> EventId -> UTCTime -> IO ()
markEventProcessed (EventStore storeVar) targetId processedAt =
  atomically $
    modifyTVar' storeVar $
      map $ \event ->
        if eventId event == targetId && isNothing (eventProcessedAt event)
          then event {eventProcessedAt = Just processedAt}
          else event

fetchUnprocessedEvents :: EventStore -> IO [StoredEvent]
fetchUnprocessedEvents (EventStore storeVar) =
  atomically $ do
    events <- readTVar storeVar
    pure (filter (isUnprocessed . eventProcessedAt) (sortEvents events))
 where
  isUnprocessed Nothing = True
  isUnprocessed (Just _) = False

-- | Read the recorded @processed_at@ stamp for an event, if the event exists.
-- A double 'Maybe': outer 'Nothing' means no such event in the store, inner
-- 'Nothing' means the event is recorded but not yet processed. Lets callers
-- (and the first-write-wins guard test) observe the delivery-state audit
-- trail without exposing the underlying store.
lookupProcessedAt :: EventStore -> EventId -> IO (Maybe (Maybe UTCTime))
lookupProcessedAt (EventStore storeVar) targetId =
  atomically $ do
    events <- readTVar storeVar
    pure (fmap eventProcessedAt (firstMatching events))
 where
  firstMatching events = case filter ((== targetId) . eventId) events of
    (event : _) -> Just event
    [] -> Nothing

processEvents :: EventStore -> (IO UTCTime) -> EventHandler -> IO Int
processEvents store clock handler = do
  events <- fetchUnprocessedEvents store
  mapM_ processOne events
  pure (length events)
 where
  processOne event = do
    runEventHandler handler event
    processedAt <- clock
    markEventProcessed store (eventId event) processedAt

sortEvents :: [StoredEvent] -> [StoredEvent]
sortEvents =
  sortOn (\event -> (eventCreatedAt event, eventId event))
