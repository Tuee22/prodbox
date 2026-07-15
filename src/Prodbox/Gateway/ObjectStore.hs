{-# LANGUAGE OverloadedStrings #-}

-- | Wire contract for the daemon-mediated Pulumi object-store API.
module Prodbox.Gateway.ObjectStore
  ( AuthorityClockRequest (..)
  , AuthorityClockResponse (..)
  , AuthorityObjectCasRequest (..)
  , AuthorityObjectCasResponse (..)
  , AuthorityObjectLeaseGuard (..)
  , AuthorityObjectObservation (..)
  , AuthorityObjectRequest (..)
  , AuthorityObjectPayloadError (..)
  , PulumiObjectGetResponse (..)
  , PulumiObjectPutRequest (..)
  , PulumiObjectRequest (..)
  , authorityObjectCasPath
  , authorityClockPath
  , authorityObjectGetPath
  , authorityObjectRequestMaxBytes
  , authorityControlObjectPayloadMaxBytes
  , authorityObjectPayloadLimit
  , authorityPulumiObjectPayloadMaxBytes
  , pulumiObjectDeletePath
  , pulumiObjectGetPath
  , pulumiObjectPutPath
  , pulumiObjectRequestMaxBytes
  , validateAuthorityObjectLogicalName
  , validateAuthorityObjectPayloadSize
  , validateAuthorityObjectPayloadLength
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
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.Gateway.Routes (GatewayRoute (..), routePattern)

-- Sprint 2.34: the object-store wire paths are projections of the one compiled
-- route registry ("Prodbox.Gateway.Routes"), so this contract cannot drift from
-- the daemon dispatcher or the gateway client.
pulumiObjectGetPath :: String
pulumiObjectGetPath = routePattern RoutePulumiObjectGet

pulumiObjectPutPath :: String
pulumiObjectPutPath = routePattern RoutePulumiObjectPut

pulumiObjectDeletePath :: String
pulumiObjectDeletePath = routePattern RoutePulumiObjectDelete

authorityObjectGetPath :: String
authorityObjectGetPath = routePattern RouteAuthorityObjectGet

authorityObjectCasPath :: String
authorityObjectCasPath = routePattern RouteAuthorityObjectCas

-- | The same retained gateway that owns Model-B CAS supplies the transaction
-- clock.  Callers must never substitute their process wall clock.
authorityClockPath :: String
authorityClockPath = routePattern RouteAuthorityClock

pulumiObjectRequestMaxBytes :: Int
pulumiObjectRequestMaxBytes = 64 * 1024 * 1024

-- | Lease and target-intent records are deliberately small.  The separate
-- bound prevents the generic authority route from inheriting the Pulumi
-- checkpoint surface's 64 MiB request allowance.
authorityObjectRequestMaxBytes :: Int
authorityObjectRequestMaxBytes = pulumiObjectRequestMaxBytes

authorityControlObjectPayloadMaxBytes :: Int
authorityControlObjectPayloadMaxBytes = 1024 * 1024

authorityPulumiObjectPayloadMaxBytes :: Int
authorityPulumiObjectPayloadMaxBytes = pulumiObjectRequestMaxBytes

data AuthorityObjectPayloadError = AuthorityObjectPayloadTooLarge
  { authorityPayloadLogicalName :: !Text
  , authorityPayloadObservedBytes :: !Int
  , authorityPayloadMaximumBytes :: !Int
  }
  deriving (Eq, Show)

authorityObjectPayloadLimit :: Text -> Int
authorityObjectPayloadLimit logicalName
  | "pulumi-stack/" `Text.isPrefixOf` logicalName =
      authorityPulumiObjectPayloadMaxBytes
  | otherwise = authorityControlObjectPayloadMaxBytes

validateAuthorityObjectPayloadSize
  :: Text -> ByteString -> Either AuthorityObjectPayloadError ()
validateAuthorityObjectPayloadSize logicalName =
  validateAuthorityObjectPayloadLength logicalName . BS.length

validateAuthorityObjectPayloadLength
  :: Text -> Int -> Either AuthorityObjectPayloadError ()
validateAuthorityObjectPayloadLength logicalName observed
  | observed > maximumBytes =
      Left
        AuthorityObjectPayloadTooLarge
          { authorityPayloadLogicalName = logicalName
          , authorityPayloadObservedBytes = observed
          , authorityPayloadMaximumBytes = maximumBytes
          }
  | otherwise = Right ()
 where
  maximumBytes = authorityObjectPayloadLimit logicalName

data AuthorityClockRequest = AuthorityClockRequest
  { authorityClockLoopbackNodePortVerified :: Bool
  }
  deriving (Eq, Show)

instance FromJSON AuthorityClockRequest where
  parseJSON =
    withObject "AuthorityClockRequest" $ \o ->
      AuthorityClockRequest
        <$> o .:? "loopback_nodeport_verified" .!= False

instance ToJSON AuthorityClockRequest where
  toJSON request =
    object
      [ "loopback_nodeport_verified"
          .= authorityClockLoopbackNodePortVerified request
      ]

newtype AuthorityClockResponse = AuthorityClockResponse
  { authorityClockMicros :: Natural
  }
  deriving (Eq, Show)

instance FromJSON AuthorityClockResponse where
  parseJSON =
    withObject "AuthorityClockResponse" $ \o ->
      AuthorityClockResponse <$> o .: "authority_time_micros"

instance ToJSON AuthorityClockResponse where
  toJSON response =
    object ["authority_time_micros" .= authorityClockMicros response]

data AuthorityObjectRequest = AuthorityObjectRequest
  { authorityObjectLogicalName :: Text
  , authorityObjectLoopbackNodePortVerified :: Bool
  }
  deriving (Eq, Show)

instance FromJSON AuthorityObjectRequest where
  parseJSON =
    withObject "AuthorityObjectRequest" $ \o ->
      AuthorityObjectRequest
        <$> o .: "logical_name"
        <*> o .:? "loopback_nodeport_verified" .!= False

instance ToJSON AuthorityObjectRequest where
  toJSON request =
    object
      [ "logical_name" .= authorityObjectLogicalName request
      , "loopback_nodeport_verified" .= authorityObjectLoopbackNodePortVerified request
      ]

data AuthorityObjectCasRequest = AuthorityObjectCasRequest
  { authorityObjectCasLogicalName :: Text
  , authorityObjectCasExpectedVersion :: Maybe Text
  , authorityObjectCasLeaseGuard :: Maybe AuthorityObjectLeaseGuard
  , authorityObjectCasPayload :: ByteString
  , authorityObjectCasLoopbackNodePortVerified :: Bool
  }
  deriving (Eq)

instance Show AuthorityObjectCasRequest where
  show request =
    "AuthorityObjectCasRequest {authorityObjectCasLogicalName = "
      ++ show (authorityObjectCasLogicalName request)
      ++ ", authorityObjectCasExpectedVersion = "
      ++ show (authorityObjectCasExpectedVersion request)
      ++ ", authorityObjectCasLeaseGuard = "
      ++ show (authorityObjectCasLeaseGuard request)
      ++ ", authorityObjectCasPayload = <redacted>, authorityObjectCasLoopbackNodePortVerified = "
      ++ show (authorityObjectCasLoopbackNodePortVerified request)
      ++ "}"

instance FromJSON AuthorityObjectCasRequest where
  parseJSON =
    withObject "AuthorityObjectCasRequest" $ \o -> do
      logicalName <- o .: "logical_name"
      expectedVersion <- o .:? "expected_version"
      leaseGuard <- o .:? "lease_guard"
      encoded <- o .: "payload_base64"
      loopback <- o .:? "loopback_nodeport_verified" .!= False
      case decodeBase64Text encoded of
        Left err -> fail err
        Right payload ->
          pure
            AuthorityObjectCasRequest
              { authorityObjectCasLogicalName = logicalName
              , authorityObjectCasExpectedVersion = expectedVersion
              , authorityObjectCasLeaseGuard = leaseGuard
              , authorityObjectCasPayload = payload
              , authorityObjectCasLoopbackNodePortVerified = loopback
              }

instance ToJSON AuthorityObjectCasRequest where
  toJSON request =
    object
      [ "logical_name" .= authorityObjectCasLogicalName request
      , "expected_version" .= authorityObjectCasExpectedVersion request
      , "lease_guard" .= authorityObjectCasLeaseGuard request
      , "payload_base64" .= base64Text (authorityObjectCasPayload request)
      , "loopback_nodeport_verified" .= authorityObjectCasLoopbackNodePortVerified request
      ]

data AuthorityObjectLeaseGuard = AuthorityObjectLeaseGuard
  { authorityLeaseGuardLogicalName :: !Text
  , authorityLeaseGuardExpectedVersion :: !Text
  , authorityLeaseGuardOwnerNonce :: !Text
  , authorityLeaseGuardFencingToken :: !Natural
  }
  deriving (Eq, Show)

instance FromJSON AuthorityObjectLeaseGuard where
  parseJSON =
    withObject "AuthorityObjectLeaseGuard" $ \o ->
      AuthorityObjectLeaseGuard
        <$> o .: "logical_name"
        <*> o .: "expected_version"
        <*> o .: "owner_nonce"
        <*> o .: "fencing_token"

instance ToJSON AuthorityObjectLeaseGuard where
  toJSON guard =
    object
      [ "logical_name" .= authorityLeaseGuardLogicalName guard
      , "expected_version" .= authorityLeaseGuardExpectedVersion guard
      , "owner_nonce" .= authorityLeaseGuardOwnerNonce guard
      , "fencing_token" .= authorityLeaseGuardFencingToken guard
      ]

data AuthorityObjectObservation
  = AuthorityObjectMissing
  | AuthorityObjectObserved !Text !ByteString
  deriving (Eq, Show)

instance FromJSON AuthorityObjectObservation where
  parseJSON =
    withObject "AuthorityObjectObservation" $ \o -> do
      status <- o .: "status"
      case status :: Text of
        "missing" -> pure AuthorityObjectMissing
        "observed" -> do
          version <- o .: "version"
          encoded <- o .: "payload_base64"
          case decodeBase64Text encoded of
            Left err -> fail err
            Right payload -> pure (AuthorityObjectObserved version payload)
        _ -> fail "authority object observation status must be missing or observed"

instance ToJSON AuthorityObjectObservation where
  toJSON observation =
    case observation of
      AuthorityObjectMissing -> object ["status" .= ("missing" :: Text)]
      AuthorityObjectObserved version payload ->
        object
          [ "status" .= ("observed" :: Text)
          , "version" .= version
          , "payload_base64" .= base64Text payload
          ]

data AuthorityObjectCasResponse
  = AuthorityObjectCasApplied !Text
  | AuthorityObjectCasConflict !AuthorityObjectObservation
  deriving (Eq, Show)

instance FromJSON AuthorityObjectCasResponse where
  parseJSON =
    withObject "AuthorityObjectCasResponse" $ \o -> do
      status <- o .: "status"
      case status :: Text of
        "applied" -> AuthorityObjectCasApplied <$> o .: "version"
        "conflict" -> AuthorityObjectCasConflict <$> o .: "observation"
        _ -> fail "authority object CAS status must be applied or conflict"

instance ToJSON AuthorityObjectCasResponse where
  toJSON response =
    case response of
      AuthorityObjectCasApplied version ->
        object
          [ "status" .= ("applied" :: Text)
          , "version" .= version
          ]
      AuthorityObjectCasConflict observation ->
        object
          [ "status" .= ("conflict" :: Text)
          , "observation" .= observation
          ]

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

-- | The daemon exposes conditional Model-B access only for the closed
-- long-lived authority namespaces.  Pulumi checkpoint names retain their
-- existing logical identity so a fenced writer addresses the same encrypted
-- object as the ordinary checkpoint path.
validateAuthorityObjectLogicalName :: Text -> Either String Text
validateAuthorityObjectLogicalName raw
  | Text.null stripped = Left "logical_name must not be empty"
  | Text.length stripped > 512 = Left "logical_name must be 512 characters or fewer"
  | Text.any (not . allowed) stripped =
      Left "logical_name may contain only ASCII letters, digits, '.', '_', '-', and '/'"
  | not (any (`Text.isPrefixOf` stripped) allowedPrefixes) =
      Left
        "logical_name must use the leases/, target-commit-intents/, smtp-commit/, or pulumi-stack/ namespace"
  | Text.isSuffixOf "/" stripped || "//" `Text.isInfixOf` stripped =
      Left "logical_name contains an empty path segment"
  | otherwise = Right stripped
 where
  stripped = Text.strip raw
  allowedPrefixes =
    [ "leases/"
    , "target-commit-intents/"
    , "smtp-commit/"
    , "pulumi-stack/"
    ]
  allowed c =
    isAsciiLower c
      || isAsciiUpper c
      || isDigit c
      || c == '.'
      || c == '_'
      || c == '-'
      || c == '/'

base64Text :: ByteString -> Text
base64Text =
  TextEncoding.decodeUtf8 . Base64.encode

decodeBase64Text :: Text -> Either String ByteString
decodeBase64Text encoded =
  case Base64.decode (TextEncoding.encodeUtf8 encoded) of
    Left err -> Left ("checkpoint_base64 decode failed: " ++ err)
    Right bytes -> Right bytes
