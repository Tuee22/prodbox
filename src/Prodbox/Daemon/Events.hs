{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Daemon.Events
  ( AggregateId (..)
  , EventHandler (..)
  , EventId (..)
  , EventStore
  , EventType (..)
  , StoredEvent (..)
  , fetchUnprocessedEvents
  , markEventProcessed
  , newEventStore
  , processEvents
  , recordEvent
  )
where

import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  )
import Data.Aeson (Value)
import Data.List (sortOn)
import Data.Time.Clock (UTCTime)

newtype EventId = EventId {unEventId :: String}
  deriving (Eq, Ord, Show)

newtype AggregateId = AggregateId {unAggregateId :: String}
  deriving (Eq, Ord, Show)

newtype EventType = EventType {unEventType :: String}
  deriving (Eq, Ord, Show)

data StoredEvent = StoredEvent
  { eventId :: EventId
  , eventAggregateId :: AggregateId
  , eventType :: EventType
  , eventPayload :: Value
  , eventCreatedAt :: UTCTime
  , eventProcessedAt :: Maybe UTCTime
  }
  deriving (Eq, Show)

newtype EventStore = EventStore (TVar [StoredEvent])

-- | Handlers must be idempotent: replaying the same event after a crash must
-- produce the same durable result as handling it once.
newtype EventHandler = EventHandler {runEventHandler :: StoredEvent -> IO ()}

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

markEventProcessed :: EventStore -> EventId -> UTCTime -> IO ()
markEventProcessed (EventStore storeVar) targetId processedAt =
  atomically $
    modifyTVar' storeVar $
      map $ \event ->
        if eventId event == targetId
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
