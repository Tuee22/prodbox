module Prodbox.Pulsar.TopicResidue
  ( ManagedTopic (..)
  , PulsarTopicBroker (..)
  , RetentionPolicy (..)
  , TopicResidueDetails (..)
  , TopicResidueStatus (..)
  , TopicUnobservableReason (..)
  , deleteTopic
  , ensureTopic
  , managedTopicResourceName
  , pulsarLongLivedTopicsResourceName
  , pulsarPerRunTopicsResourceName
  , renderTopicUnobservableReason
  , topicDiscover
  , topicResidueStatus
  )
where

import Data.Text qualified as Text
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueDetails (..)
  , ResidueStatus (..)
  , ResidueUnreachableReason (..)
  )
import Prodbox.Lifecycle.ResourceClass (LifecycleClass (..))
import Prodbox.Pulsar.Client (PulsarClientError (..))
import Prodbox.Pulsar.Topic
  ( TopicName
  , renderTopicName
  )

data RetentionPolicy = RetentionPolicy
  { retentionBacklogBytes :: Int
  , retentionOffloadBytes :: Int
  }
  deriving (Eq, Show)

data ManagedTopic = ManagedTopic
  { managedTopicName :: TopicName
  , managedTopicRetention :: RetentionPolicy
  , managedTopicClass :: LifecycleClass
  }
  deriving (Eq, Show)

data TopicResidueStatus
  = TopicAbsent
  | TopicPresent TopicResidueDetails
  | TopicUnobservable TopicUnobservableReason
  deriving (Eq, Show)

data TopicResidueDetails = TopicResidueDetails
  { topicResidueTopicName :: TopicName
  , topicResidueResourceName :: String
  }
  deriving (Eq, Show)

data TopicUnobservableReason
  = TopicBrokerUnreachable String
  | TopicBrokerMalformedFrame String
  | TopicBrokerAuthenticationFailed String
  | TopicBrokerAuthorizationFailed String
  | TopicBrokerUnsupported String
  | TopicBrokerError String
  deriving (Eq, Show)

data PulsarTopicBroker = PulsarTopicBroker
  { pulsarTopicExists :: TopicName -> IO (Either PulsarClientError Bool)
  , pulsarTopicEnsure :: TopicName -> IO (Either PulsarClientError ())
  , pulsarTopicDelete :: TopicName -> IO (Either PulsarClientError ())
  }

pulsarPerRunTopicsResourceName :: String
pulsarPerRunTopicsResourceName = "pulsar-topics-per-run"

pulsarLongLivedTopicsResourceName :: String
pulsarLongLivedTopicsResourceName = "pulsar-topics-long-lived"

managedTopicResourceName :: ManagedTopic -> String
managedTopicResourceName topic =
  case managedTopicClass topic of
    PerRun -> pulsarPerRunTopicsResourceName
    LongLived -> pulsarLongLivedTopicsResourceName
    Operational -> "pulsar-topics-operational"

topicDiscover :: PulsarTopicBroker -> ManagedTopic -> IO TopicResidueStatus
topicDiscover broker topic = do
  result <- pulsarTopicExists broker (managedTopicName topic)
  pure $ case result of
    Right True ->
      TopicPresent
        TopicResidueDetails
          { topicResidueTopicName = managedTopicName topic
          , topicResidueResourceName = managedTopicResourceName topic
          }
    Right False -> TopicAbsent
    Left (PulsarTopicAbsent _ _) -> TopicAbsent
    Left err -> TopicUnobservable (topicUnobservableFromClientError err)

deleteTopic :: PulsarTopicBroker -> ManagedTopic -> IO (Either TopicUnobservableReason ())
deleteTopic broker topic = do
  result <- pulsarTopicDelete broker (managedTopicName topic)
  pure $ case result of
    Right () -> Right ()
    Left (PulsarTopicAbsent _ _) -> Right ()
    Left err -> Left (topicUnobservableFromClientError err)

ensureTopic :: PulsarTopicBroker -> ManagedTopic -> IO (Either TopicUnobservableReason ())
ensureTopic broker topic = do
  observed <- pulsarTopicExists broker (managedTopicName topic)
  case observed of
    Right True -> pure (Right ())
    Right False -> do
      ensured <- pulsarTopicEnsure broker (managedTopicName topic)
      pure (either (Left . topicUnobservableFromClientError) Right ensured)
    Left (PulsarTopicAbsent _ _) -> do
      ensured <- pulsarTopicEnsure broker (managedTopicName topic)
      pure (either (Left . topicUnobservableFromClientError) Right ensured)
    Left err -> pure (Left (topicUnobservableFromClientError err))

topicResidueStatus :: TopicResidueStatus -> ResidueStatus
topicResidueStatus status =
  case status of
    TopicAbsent -> ResidueAbsent
    TopicPresent details ->
      ResiduePresent
        ResidueDetails
          { residueEvidence =
              "pulsar-topic: "
                ++ Text.unpack (renderTopicName (topicResidueTopicName details))
          , residueStackName = topicResidueResourceName details
          }
    TopicUnobservable reason ->
      ResidueUnreachable
        ( ResidueQueryFailed
            ("Pulsar topic broker unobservable: " ++ renderTopicUnobservableReason reason)
        )

renderTopicUnobservableReason :: TopicUnobservableReason -> String
renderTopicUnobservableReason reason =
  case reason of
    TopicBrokerUnreachable message -> "broker unreachable: " ++ message
    TopicBrokerMalformedFrame message -> "malformed frame: " ++ message
    TopicBrokerAuthenticationFailed message -> "authentication failed: " ++ message
    TopicBrokerAuthorizationFailed message -> "authorization failed: " ++ message
    TopicBrokerUnsupported message -> "unsupported broker behavior: " ++ message
    TopicBrokerError message -> "broker error: " ++ message

topicUnobservableFromClientError :: PulsarClientError -> TopicUnobservableReason
topicUnobservableFromClientError err =
  case err of
    PulsarInvalidEndpoint message -> TopicBrokerUnsupported message
    PulsarBrokerUnreachable message -> TopicBrokerUnreachable message
    PulsarMalformedFrame message -> TopicBrokerMalformedFrame message
    PulsarAuthenticationFailed message -> TopicBrokerAuthenticationFailed message
    PulsarAuthorizationFailed message -> TopicBrokerAuthorizationFailed message
    PulsarTopicAbsent _ message -> TopicBrokerError message
    PulsarUnsupportedServerBehavior message -> TopicBrokerUnsupported message
    PulsarBrokerError serverError message ->
      TopicBrokerError (show serverError ++ ": " ++ message)
