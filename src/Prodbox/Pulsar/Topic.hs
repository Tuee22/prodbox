{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Pulsar.Topic
  ( Tenant
  , Namespace
  , Lane
  , TopicName
  , Workflow (..)
  , Phase (..)
  , TopicError (..)
  , mkTenant
  , mkNamespace
  , mkLane
  , renderTopicError
  , renderTopicName
  , topicFor
  )
where

import Codec.Serialise (Serialise)
import Data.Char
  ( isAlphaNum
  , isAscii
  )
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)

newtype Tenant = Tenant Text
  deriving (Eq, Ord, Show, Generic)

instance Serialise Tenant

newtype Namespace = Namespace Text
  deriving (Eq, Ord, Show, Generic)

instance Serialise Namespace

newtype Lane = Lane Text
  deriving (Eq, Ord, Show, Generic)

instance Serialise Lane

newtype TopicName = TopicName Text
  deriving (Eq, Ord, Show, Generic)

instance Serialise TopicName

data Workflow
  = Reconcile
  | Gossip
  | DomainEvent
  deriving (Bounded, Enum, Eq, Ord, Show, Generic)

instance Serialise Workflow

data Phase
  = Command
  | Event
  | Result
  deriving (Bounded, Enum, Eq, Ord, Show, Generic)

instance Serialise Phase

data TopicError
  = EmptyTopicSegment String
  | InvalidTopicSegment String Text
  deriving (Eq, Show)

mkTenant :: Text -> Either TopicError Tenant
mkTenant =
  fmap Tenant . validateSegment "tenant"

mkNamespace :: Text -> Either TopicError Namespace
mkNamespace =
  fmap Namespace . validateSegment "namespace"

mkLane :: Text -> Either TopicError Lane
mkLane =
  fmap Lane . validateSegment "lane"

topicFor :: Tenant -> Namespace -> Workflow -> Phase -> Lane -> TopicName
topicFor (Tenant tenant) (Namespace namespace) workflow phase (Lane lane) =
  TopicName
    ( Text.concat
        [ "persistent://"
        , tenant
        , "/"
        , namespace
        , "/"
        , renderWorkflow workflow
        , "."
        , renderPhase phase
        , "."
        , lane
        ]
    )

renderTopicName :: TopicName -> Text
renderTopicName (TopicName name) =
  name

renderTopicError :: TopicError -> String
renderTopicError err =
  case err of
    EmptyTopicSegment segment ->
      "Pulsar topic " ++ segment ++ " segment must not be empty."
    InvalidTopicSegment segment value ->
      "Pulsar topic "
        ++ segment
        ++ " segment contains unsupported characters: "
        ++ Text.unpack value

validateSegment :: String -> Text -> Either TopicError Text
validateSegment label raw =
  let value = Text.strip raw
   in if Text.null value
        then Left (EmptyTopicSegment label)
        else
          if Text.all isSegmentChar value
            then Right value
            else Left (InvalidTopicSegment label value)

isSegmentChar :: Char -> Bool
isSegmentChar char =
  isAscii char && (isAlphaNum char || char == '-' || char == '_')

renderWorkflow :: Workflow -> Text
renderWorkflow workflow =
  case workflow of
    Reconcile -> "reconcile"
    Gossip -> "gossip"
    DomainEvent -> "domain-event"

renderPhase :: Phase -> Text
renderPhase phase =
  case phase of
    Command -> "command"
    Event -> "event"
    Result -> "result"
