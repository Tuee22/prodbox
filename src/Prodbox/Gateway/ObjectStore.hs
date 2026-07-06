{-# LANGUAGE OverloadedStrings #-}

-- | Wire contract for the daemon-mediated Pulumi object-store API.
module Prodbox.Gateway.ObjectStore
  ( PulumiObjectGetResponse (..)
  , PulumiObjectPutRequest (..)
  , PulumiObjectRequest (..)
  , pulumiObjectDeletePath
  , pulumiObjectGetPath
  , pulumiObjectPutPath
  , pulumiObjectRequestMaxBytes
  , validatePulumiObjectStackName
  )
where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , object
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as Base64
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding

pulumiObjectGetPath :: String
pulumiObjectGetPath = "/v1/object-store/pulumi/get"

pulumiObjectPutPath :: String
pulumiObjectPutPath = "/v1/object-store/pulumi/put"

pulumiObjectDeletePath :: String
pulumiObjectDeletePath = "/v1/object-store/pulumi/delete"

pulumiObjectRequestMaxBytes :: Int
pulumiObjectRequestMaxBytes = 64 * 1024 * 1024

data PulumiObjectRequest = PulumiObjectRequest
  { pulumiObjectStackName :: Text
  , pulumiObjectLoopbackNodePortVerified :: Bool
  }
  deriving (Eq, Show)

instance FromJSON PulumiObjectRequest where
  parseJSON =
    withObject "PulumiObjectRequest" $ \o ->
      PulumiObjectRequest
        <$> o .: "stack"
        <*> o .:? "loopback_nodeport_verified" .!= False

instance ToJSON PulumiObjectRequest where
  toJSON request =
    object
      [ "stack" .= pulumiObjectStackName request
      , "loopback_nodeport_verified" .= pulumiObjectLoopbackNodePortVerified request
      ]

data PulumiObjectPutRequest = PulumiObjectPutRequest
  { pulumiObjectPutStackName :: Text
  , pulumiObjectPutCheckpoint :: ByteString
  , pulumiObjectPutLoopbackNodePortVerified :: Bool
  }
  deriving (Eq)

instance Show PulumiObjectPutRequest where
  show request =
    "PulumiObjectPutRequest {pulumiObjectPutStackName = "
      ++ show (pulumiObjectPutStackName request)
      ++ ", pulumiObjectPutCheckpoint = <redacted>, pulumiObjectPutLoopbackNodePortVerified = "
      ++ show (pulumiObjectPutLoopbackNodePortVerified request)
      ++ "}"

instance FromJSON PulumiObjectPutRequest where
  parseJSON =
    withObject "PulumiObjectPutRequest" $ \o -> do
      stack <- o .: "stack"
      encoded <- o .: "checkpoint_base64"
      loopback <- o .:? "loopback_nodeport_verified" .!= False
      case decodeBase64Text encoded of
        Left err -> fail err
        Right checkpoint -> pure (PulumiObjectPutRequest stack checkpoint loopback)

instance ToJSON PulumiObjectPutRequest where
  toJSON request =
    object
      [ "stack" .= pulumiObjectPutStackName request
      , "checkpoint_base64" .= base64Text (pulumiObjectPutCheckpoint request)
      , "loopback_nodeport_verified" .= pulumiObjectPutLoopbackNodePortVerified request
      ]

data PulumiObjectGetResponse
  = PulumiObjectAbsent
  | PulumiObjectPresent ByteString
  deriving (Eq, Show)

instance FromJSON PulumiObjectGetResponse where
  parseJSON =
    withObject "PulumiObjectGetResponse" $ \o -> do
      status <- o .: "status"
      case status :: Text of
        "absent" -> pure PulumiObjectAbsent
        "present" -> do
          encoded <- o .: "checkpoint_base64"
          case decodeBase64Text encoded of
            Left err -> fail err
            Right checkpoint -> pure (PulumiObjectPresent checkpoint)
        _ -> fail "Pulumi object response status must be present or absent"

instance ToJSON PulumiObjectGetResponse where
  toJSON response = case response of
    PulumiObjectAbsent -> object ["status" .= ("absent" :: Text)]
    PulumiObjectPresent checkpoint ->
      object
        [ "status" .= ("present" :: Text)
        , "checkpoint_base64" .= base64Text checkpoint
        ]

validatePulumiObjectStackName :: Text -> Either String Text
validatePulumiObjectStackName raw
  | Text.null stripped = Left "stack must not be empty"
  | Text.length stripped > 128 = Left "stack must be 128 characters or fewer"
  | Text.any (not . allowed) stripped =
      Left "stack may contain only ASCII letters, digits, '.', '_', and '-'"
  | otherwise = Right stripped
 where
  stripped = Text.strip raw
  allowed c =
    isAsciiLower c
      || isAsciiUpper c
      || isDigit c
      || c == '.'
      || c == '_'
      || c == '-'

base64Text :: ByteString -> Text
base64Text =
  TextEncoding.decodeUtf8 . Base64.encode

decodeBase64Text :: Text -> Either String ByteString
decodeBase64Text encoded =
  case Base64.decode (TextEncoding.encodeUtf8 encoded) of
    Left err -> Left ("checkpoint_base64 decode failed: " ++ err)
    Right bytes -> Right bytes
