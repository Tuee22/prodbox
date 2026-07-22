{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed, secret-free controller protocol for the Bootstrap Broker.
--
-- The HTTP route selects the operation.  Every body-bearing request repeats
-- that closed operation name and binds it to one validated storage generation
-- and one SHA-256 action digest.  The only route-specific extension is the
-- already-bounded PKI test-certificate request.  There is no arbitrary Vault
-- path, object-store coordinate, command, provider, or secret field.
module Prodbox.Bootstrap.Broker.Protocol
  ( BrokerActionRequest
  , mkBrokerActionRequest
  , brokerActionStorageGeneration
  , brokerActionDigest
  , BrokerControllerRequest
  , mkBrokerControllerRequest
  , mkBrokerPkiControllerRequest
  , brokerControllerRequestAction
  , brokerControllerRequestPkiIssue
  , brokerControllerRequestValue
  , encodeBrokerControllerRequest
  , decodeBrokerControllerRequest
  , BrokerProtocolError (..)
  , renderBrokerProtocolError
  , brokerRouteOperationName
  )
where

import Data.Aeson
  ( FromJSON
  , Object
  , Value (..)
  , eitherDecodeStrict'
  , encode
  , object
  , parseJSON
  , (.:)
  , (.=)
  )
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (sort)
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Program
  ( PkiIssueRequest
  , mkPkiIssueRequest
  , pkiIssueCommonName
  , pkiIssueTtlSeconds
  )
import Prodbox.Bootstrap.Broker.Routes
  ( BrokerBodyRequirement (..)
  , BrokerRoute (..)
  , brokerRouteBodyRequirement
  )
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , VaultStorageGeneration
  , mkArtifactDigest
  , mkVaultStorageGeneration
  , renderArtifactDigest
  , renderVaultStorageGeneration
  )

-- | Common durable action binding carried by a controller request.  Both
-- values are validated, non-secret identifiers.  Constructors remain private
-- so decoded wire values cannot bypass validation.
data BrokerActionRequest = BrokerActionRequest
  { brokerActionStorageGeneration :: !VaultStorageGeneration
  , brokerActionDigest :: !ArtifactDigest
  }
  deriving stock (Eq, Show)

mkBrokerActionRequest
  :: VaultStorageGeneration -> ArtifactDigest -> BrokerActionRequest
mkBrokerActionRequest = BrokerActionRequest

-- | A complete body-bearing controller message.  Its route is retained with
-- the payload so encoding cannot accidentally write one route's operation
-- tag into another route's request.
data BrokerControllerRequest = BrokerControllerRequest
  { controllerRoute :: !BrokerRoute
  , brokerControllerRequestAction :: !BrokerActionRequest
  , brokerControllerRequestPkiIssue :: !(Maybe PkiIssueRequest)
  }
  deriving stock (Eq, Show)

data BrokerProtocolError
  = BrokerProtocolBodyForbidden
  | BrokerProtocolPkiFieldsRequired
  | BrokerProtocolPkiFieldsForbidden
  | BrokerProtocolMalformedJson
  | BrokerProtocolUnexpectedFields
  | BrokerProtocolWrongOperation
  | BrokerProtocolInvalidStorageGeneration
  | BrokerProtocolInvalidActionDigest
  | BrokerProtocolInvalidPkiIssue
  deriving stock (Eq, Ord, Show, Enum, Bounded)

renderBrokerProtocolError :: BrokerProtocolError -> String
renderBrokerProtocolError protocolError = case protocolError of
  BrokerProtocolBodyForbidden ->
    "the selected Bootstrap Broker route forbids a request body"
  BrokerProtocolPkiFieldsRequired ->
    "the PKI test-certificate route requires bounded PKI fields"
  BrokerProtocolPkiFieldsForbidden ->
    "bounded PKI fields are permitted only on the PKI test-certificate route"
  BrokerProtocolMalformedJson ->
    "the Bootstrap Broker controller request is not a JSON object"
  BrokerProtocolUnexpectedFields ->
    "the Bootstrap Broker controller request does not contain the exact closed fields"
  BrokerProtocolWrongOperation ->
    "the Bootstrap Broker operation tag does not match the selected route"
  BrokerProtocolInvalidStorageGeneration ->
    "the Bootstrap Broker storage generation is invalid"
  BrokerProtocolInvalidActionDigest ->
    "the Bootstrap Broker action digest is invalid"
  BrokerProtocolInvalidPkiIssue ->
    "the Bootstrap Broker PKI test-certificate fields are invalid"

-- | Construct a request for every ordinary body-bearing route.  Probe and
-- GET observation routes remain bodyless by server doctrine; PKI issuance has
-- its dedicated constructor so its bounded extension cannot be omitted.
mkBrokerControllerRequest
  :: BrokerRoute
  -> BrokerActionRequest
  -> Either BrokerProtocolError BrokerControllerRequest
mkBrokerControllerRequest route action =
  case brokerRouteBodyRequirement route of
    BrokerBodyForbidden -> Left BrokerProtocolBodyForbidden
    BrokerBodyRequired
      | route == BrokerVaultPkiIssueTestCertificate ->
          Left BrokerProtocolPkiFieldsRequired
      | otherwise ->
          Right
            BrokerControllerRequest
              { controllerRoute = route
              , brokerControllerRequestAction = action
              , brokerControllerRequestPkiIssue = Nothing
              }

mkBrokerPkiControllerRequest
  :: BrokerActionRequest -> PkiIssueRequest -> BrokerControllerRequest
mkBrokerPkiControllerRequest action pkiRequest =
  BrokerControllerRequest
    { controllerRoute = BrokerVaultPkiIssueTestCertificate
    , brokerControllerRequestAction = action
    , brokerControllerRequestPkiIssue = Just pkiRequest
    }

brokerControllerRequestValue :: BrokerControllerRequest -> Value
brokerControllerRequestValue request =
  object (commonFields ++ pkiFields)
 where
  action = brokerControllerRequestAction request
  commonFields =
    [ "operation" .= brokerRouteOperationName (controllerRoute request)
    , "storage_generation"
        .= renderVaultStorageGeneration (brokerActionStorageGeneration action)
    , "action_digest" .= renderArtifactDigest (brokerActionDigest action)
    ]
  pkiFields = case brokerControllerRequestPkiIssue request of
    Nothing -> []
    Just pkiRequest ->
      [ "common_name" .= pkiIssueCommonName pkiRequest
      , "ttl_seconds" .= pkiIssueTtlSeconds pkiRequest
      ]

encodeBrokerControllerRequest :: BrokerControllerRequest -> ByteString
encodeBrokerControllerRequest =
  LazyByteString.toStrict . encode . brokerControllerRequestValue

-- | Decode and validate the exact payload schema for the selected route.  In
-- particular, route binding is checked before the typed result is returned;
-- the interpreter never receives unvalidated generation/digest text.
decodeBrokerControllerRequest
  :: BrokerRoute
  -> ByteString
  -> Either BrokerProtocolError BrokerControllerRequest
decodeBrokerControllerRequest route bytes = do
  case brokerRouteBodyRequirement route of
    BrokerBodyForbidden -> Left BrokerProtocolBodyForbidden
    BrokerBodyRequired -> Right ()
  value <- firstProtocolError BrokerProtocolMalformedJson (eitherDecodeStrict' bytes)
  fields <- case value of
    Object objectFields -> Right objectFields
    _ -> Left BrokerProtocolMalformedJson
  if sort (AesonKeyMap.keys fields) == expectedRequestKeys route
    then Right ()
    else Left BrokerProtocolUnexpectedFields
  raw <- firstProtocolError BrokerProtocolMalformedJson (parseEither parseRawRequest fields)
  if rawOperation raw == brokerRouteOperationName route
    then Right ()
    else Left BrokerProtocolWrongOperation
  generation <-
    firstProtocolError
      BrokerProtocolInvalidStorageGeneration
      (mkVaultStorageGeneration (rawStorageGeneration raw))
  digest <-
    firstProtocolError
      BrokerProtocolInvalidActionDigest
      (mkArtifactDigest (rawActionDigest raw))
  let action = mkBrokerActionRequest generation digest
  case route of
    BrokerVaultPkiIssueTestCertificate -> do
      commonName <- maybe (Left BrokerProtocolPkiFieldsRequired) Right (rawCommonName raw)
      ttlSeconds <- maybe (Left BrokerProtocolPkiFieldsRequired) Right (rawTtlSeconds raw)
      pkiRequest <-
        firstProtocolError
          BrokerProtocolInvalidPkiIssue
          (mkPkiIssueRequest commonName ttlSeconds)
      Right (mkBrokerPkiControllerRequest action pkiRequest)
    _ ->
      case (rawCommonName raw, rawTtlSeconds raw) of
        (Nothing, Nothing) -> mkBrokerControllerRequest route action
        _ -> Left BrokerProtocolPkiFieldsForbidden

data RawRequest = RawRequest
  { rawOperation :: !Text
  , rawStorageGeneration :: !Text
  , rawActionDigest :: !Text
  , rawCommonName :: !(Maybe Text)
  , rawTtlSeconds :: !(Maybe Natural)
  }

parseRawRequest :: Object -> Parser RawRequest
parseRawRequest fields =
  RawRequest
    <$> fields .: "operation"
    <*> fields .: "storage_generation"
    <*> fields .: "action_digest"
    <*> optionalField "common_name" fields
    <*> optionalField "ttl_seconds" fields

optionalField :: (FromJSON value) => AesonKey.Key -> Object -> Parser (Maybe value)
optionalField key fields =
  case AesonKeyMap.lookup key fields of
    Nothing -> pure Nothing
    Just Null -> fail "closed Bootstrap Broker fields cannot be null"
    Just value -> Just <$> parseJSON value

expectedRequestKeys :: BrokerRoute -> [AesonKey.Key]
expectedRequestKeys route =
  sort
    ( commonRequestKeys
        ++ case route of
          BrokerVaultPkiIssueTestCertificate ->
            [AesonKey.fromText "common_name", AesonKey.fromText "ttl_seconds"]
          _ -> []
    )

commonRequestKeys :: [AesonKey.Key]
commonRequestKeys =
  [ AesonKey.fromText "operation"
  , AesonKey.fromText "storage_generation"
  , AesonKey.fromText "action_digest"
  ]

firstProtocolError
  :: BrokerProtocolError
  -> Either sourceError value
  -> Either BrokerProtocolError value
firstProtocolError protocolError = either (const (Left protocolError)) Right

-- | Stable operation vocabulary for the complete fifteen-route registry.
-- Keeping this projection exhaustive makes a newly added route fail to build
-- until its wire identity is explicitly chosen.
brokerRouteOperationName :: BrokerRoute -> Text
brokerRouteOperationName route = case route of
  BrokerHealth -> "health"
  BrokerReadiness -> "readiness"
  BrokerVaultStatus -> "vault_status"
  BrokerVaultInitialize -> "vault_initialize"
  BrokerVaultUnseal -> "vault_unseal"
  BrokerVaultSeal -> "vault_seal"
  BrokerVaultRotateUnlockBundle -> "vault_rotate_unlock_bundle"
  BrokerVaultRotateTransitKey -> "vault_rotate_transit_key"
  BrokerVaultBaselineReconcile -> "vault_baseline_reconcile"
  BrokerVaultPkiStatus -> "vault_pki_status"
  BrokerVaultPkiIssueTestCertificate -> "vault_pki_issue_test_certificate"
  BrokerVaultResetAmbiguousInitialization -> "vault_reset_ambiguous_initialization"
  BrokerChildCustodyCommit -> "child_custody_commit"
  BrokerChildRecoveryDeliver -> "child_recovery_deliver"
  BrokerChildRecoveryObserve -> "child_recovery_observe"
