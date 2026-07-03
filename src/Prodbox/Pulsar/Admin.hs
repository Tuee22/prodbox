{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Pulsar.Admin
  ( PulsarAdminConfig (..)
  , pulsarAdminTopicBroker
  , pulsarTopicDeleteAdmin
  , pulsarTopicEnsureAdmin
  , pulsarTopicExistsAdmin
  )
where

import Data.Text qualified as Text
import Prodbox.Http.Client
  ( HttpError (..)
  , defaultHttpConfig
  , httpGetText
  , httpRequestNoBody
  , renderHttpError
  )
import Prodbox.Pulsar.Client
  ( PulsarClientError (..)
  )
import Prodbox.Pulsar.Protocol
  ( ServerError (..)
  )
import Prodbox.Pulsar.Topic
  ( TopicName
  , renderTopicName
  )
import Prodbox.Pulsar.TopicResidue
  ( PulsarTopicBroker (..)
  )

data PulsarAdminConfig = PulsarAdminConfig
  { pulsarAdminHost :: String
  , pulsarAdminPort :: Int
  }
  deriving (Eq, Show)

pulsarAdminTopicBroker :: PulsarAdminConfig -> PulsarTopicBroker
pulsarAdminTopicBroker config =
  PulsarTopicBroker
    { pulsarTopicExists = pulsarTopicExistsAdmin config
    , pulsarTopicEnsure = pulsarTopicEnsureAdmin config
    , pulsarTopicDelete = pulsarTopicDeleteAdmin config
    }

pulsarTopicExistsAdmin :: PulsarAdminConfig -> TopicName -> IO (Either PulsarClientError Bool)
pulsarTopicExistsAdmin config topic =
  case topicStatsUrl config topic of
    Left err -> pure (Left err)
    Right url -> do
      result <- httpGetText defaultHttpConfig url
      pure $ case result of
        Right _ -> Right True
        Left (HttpStatus 404 _) -> Right False
        Left err -> Left (adminHttpError topic "query topic" err)

pulsarTopicEnsureAdmin :: PulsarAdminConfig -> TopicName -> IO (Either PulsarClientError ())
pulsarTopicEnsureAdmin config topic =
  case topicResourceUrl config topic of
    Left err -> pure (Left err)
    Right url -> do
      result <- httpRequestNoBody defaultHttpConfig "PUT" [] url
      pure $ case result of
        Right () -> Right ()
        Left (HttpStatus 409 _) -> Right ()
        Left err -> Left (adminHttpError topic "create topic" err)

pulsarTopicDeleteAdmin :: PulsarAdminConfig -> TopicName -> IO (Either PulsarClientError ())
pulsarTopicDeleteAdmin config topic =
  case topicDeleteUrl config topic of
    Left err -> pure (Left err)
    Right url -> do
      result <- httpRequestNoBody defaultHttpConfig "DELETE" [] url
      pure $ case result of
        Right () -> Right ()
        Left (HttpStatus 404 body) -> Left (PulsarTopicAbsent topic body)
        Left err -> Left (adminHttpError topic "delete topic" err)

topicStatsUrl :: PulsarAdminConfig -> TopicName -> Either PulsarClientError String
topicStatsUrl config topic =
  (++ "/stats") <$> topicResourceUrl config topic

topicDeleteUrl :: PulsarAdminConfig -> TopicName -> Either PulsarClientError String
topicDeleteUrl config topic =
  (++ "?force=true") <$> topicResourceUrl config topic

topicResourceUrl :: PulsarAdminConfig -> TopicName -> Either PulsarClientError String
topicResourceUrl config topic = do
  validateAdminConfig config
  path <- topicAdminPath topic
  Right
    ( "http://"
        ++ pulsarAdminHost config
        ++ ":"
        ++ show (pulsarAdminPort config)
        ++ "/admin/v2/"
        ++ path
    )

validateAdminConfig :: PulsarAdminConfig -> Either PulsarClientError ()
validateAdminConfig config
  | null (pulsarAdminHost config) =
      Left (PulsarInvalidEndpoint "Pulsar admin host must not be empty.")
  | pulsarAdminPort config <= 0 =
      Left (PulsarInvalidEndpoint "Pulsar admin port must be positive.")
  | otherwise = Right ()

topicAdminPath :: TopicName -> Either PulsarClientError String
topicAdminPath topic =
  case Text.stripPrefix "persistent://" (renderTopicName topic) of
    Nothing ->
      Left
        ( PulsarInvalidEndpoint
            ("Pulsar admin topic must be persistent://, got " ++ Text.unpack (renderTopicName topic))
        )
    Just suffix ->
      case Text.splitOn "/" suffix of
        [tenant, namespaceName, topicName]
          | all (not . Text.null) [tenant, namespaceName, topicName] ->
              Right
                ( Text.unpack
                    (Text.intercalate "/" ["persistent", tenant, namespaceName, topicName])
                )
        _ ->
          Left
            ( PulsarInvalidEndpoint
                ( "Pulsar admin topic has invalid tenant/namespace/name shape: "
                    ++ Text.unpack (renderTopicName topic)
                )
            )

adminHttpError :: TopicName -> String -> HttpError -> PulsarClientError
adminHttpError topic operation err =
  case err of
    HttpConnectionFailure message ->
      PulsarBrokerUnreachable (operation ++ " failed: " ++ message)
    HttpTimeout message ->
      PulsarBrokerUnreachable (operation ++ " failed: " ++ message)
    HttpStatus 401 body ->
      PulsarAuthenticationFailed (operation ++ " failed: " ++ body)
    HttpStatus 403 body ->
      PulsarAuthorizationFailed (operation ++ " failed: " ++ body)
    HttpStatus 404 body ->
      PulsarTopicAbsent topic body
    HttpStatus _ _ ->
      PulsarBrokerError ServerUnknownError (operation ++ " failed: " ++ renderHttpError err)
    HttpDecode message ->
      PulsarMalformedFrame (operation ++ " returned undecodable JSON: " ++ message)
