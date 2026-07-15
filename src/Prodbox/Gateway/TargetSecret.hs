{-# LANGUAGE OverloadedStrings #-}

-- | Wire contract for the gateway-mediated, allowlisted target Vault secret.
-- This is deliberately separate from the retained Model-B authority API: the
-- target Vault version is evidence about one KV object, not a global fence.
module Prodbox.Gateway.TargetSecret
  ( TargetSecretCasRequest (..)
  , TargetSecretCasResponse (..)
  , TargetSecretCoordinate (..)
  , TargetSecretObservation (..)
  , TargetSecretReadRequest (..)
  , TargetSecretRecord (..)
  , TargetSecretRequestError (..)
  , targetSecretCasPath
  , targetSecretReadPath
  , targetSecretRequestMaxBytes
  , targetSecretRecordFromVaultFields
  , targetSecretRecordToVaultFields
  , validateTargetSecretCasRequest
  , validateTargetSecretIdentity
  , validateTargetSecretReadRequest
  , validateTargetSecretRecord
  )
where

import Control.Monad (unless, when)
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
import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.Gateway.Routes (GatewayRoute (..), routePattern)
import Text.Read (readMaybe)

-- Sprint 2.34: the target-secret wire paths are projections of the one compiled
-- route registry ("Prodbox.Gateway.Routes"), so this contract cannot drift from
-- the daemon dispatcher or the gateway client.
targetSecretReadPath :: String
targetSecretReadPath = routePattern RouteTargetSecretRead

targetSecretCasPath :: String
targetSecretCasPath = routePattern RouteTargetSecretCas

targetSecretRequestMaxBytes :: Int
targetSecretRequestMaxBytes = 64 * 1024

data TargetSecretCoordinate = TargetSecretCoordinate
  { targetSecretCoordinateIdentity :: !Text
  , targetSecretCoordinateVaultMount :: !Text
  , targetSecretCoordinateKvPath :: !Text
  }
  deriving (Eq, Show)

instance FromJSON TargetSecretCoordinate where
  parseJSON =
    withObject "TargetSecretCoordinate" $ \o ->
      TargetSecretCoordinate
        <$> o .: "target_identity"
        <*> o .: "vault_mount"
        <*> o .: "kv_path"

instance ToJSON TargetSecretCoordinate where
  toJSON coordinate =
    object
      [ "target_identity" .= targetSecretCoordinateIdentity coordinate
      , "vault_mount" .= targetSecretCoordinateVaultMount coordinate
      , "kv_path" .= targetSecretCoordinateKvPath coordinate
      ]

data TargetSecretRecord = TargetSecretRecord
  { targetSecretRecordOwnerNonce :: !Text
  , targetSecretRecordFencingToken :: !Natural
  , targetSecretRecordGeneration :: !Natural
  , targetSecretRecordDigest :: !Text
  , targetSecretRecordFields :: !(Map Text Text)
  }
  deriving (Eq)

instance Show TargetSecretRecord where
  show record =
    "TargetSecretRecord {targetSecretRecordOwnerNonce = "
      ++ show (targetSecretRecordOwnerNonce record)
      ++ ", targetSecretRecordFencingToken = "
      ++ show (targetSecretRecordFencingToken record)
      ++ ", targetSecretRecordGeneration = "
      ++ show (targetSecretRecordGeneration record)
      ++ ", targetSecretRecordDigest = "
      ++ show (targetSecretRecordDigest record)
      ++ ", targetSecretRecordFields = <redacted>}"

instance FromJSON TargetSecretRecord where
  parseJSON =
    withObject "TargetSecretRecord" $ \o ->
      TargetSecretRecord
        <$> o .: "owner_nonce"
        <*> o .: "fencing_token"
        <*> o .: "generation"
        <*> o .: "digest"
        <*> o .: "fields"

instance ToJSON TargetSecretRecord where
  toJSON record =
    object
      [ "owner_nonce" .= targetSecretRecordOwnerNonce record
      , "fencing_token" .= targetSecretRecordFencingToken record
      , "generation" .= targetSecretRecordGeneration record
      , "digest" .= targetSecretRecordDigest record
      , "fields" .= targetSecretRecordFields record
      ]

data TargetSecretReadRequest = TargetSecretReadRequest
  { targetSecretReadCoordinate :: !TargetSecretCoordinate
  , targetSecretReadLoopbackNodePortVerified :: !Bool
  }
  deriving (Eq, Show)

instance FromJSON TargetSecretReadRequest where
  parseJSON =
    withObject "TargetSecretReadRequest" $ \o ->
      TargetSecretReadRequest
        <$> o .: "coordinate"
        <*> o .:? "loopback_nodeport_verified" .!= False

instance ToJSON TargetSecretReadRequest where
  toJSON request =
    object
      [ "coordinate" .= targetSecretReadCoordinate request
      , "loopback_nodeport_verified"
          .= targetSecretReadLoopbackNodePortVerified request
      ]

data TargetSecretCasRequest = TargetSecretCasRequest
  { targetSecretCasCoordinate :: !TargetSecretCoordinate
  , targetSecretCasExpectedVersion :: !Natural
  , targetSecretCasRecord :: !TargetSecretRecord
  , targetSecretCasLoopbackNodePortVerified :: !Bool
  }
  deriving (Eq)

instance Show TargetSecretCasRequest where
  show request =
    "TargetSecretCasRequest {targetSecretCasCoordinate = "
      ++ show (targetSecretCasCoordinate request)
      ++ ", targetSecretCasExpectedVersion = "
      ++ show (targetSecretCasExpectedVersion request)
      ++ ", targetSecretCasRecord = <redacted>, targetSecretCasLoopbackNodePortVerified = "
      ++ show (targetSecretCasLoopbackNodePortVerified request)
      ++ "}"

instance FromJSON TargetSecretCasRequest where
  parseJSON =
    withObject "TargetSecretCasRequest" $ \o ->
      TargetSecretCasRequest
        <$> o .: "coordinate"
        <*> o .: "expected_version"
        <*> o .: "record"
        <*> o .:? "loopback_nodeport_verified" .!= False

instance ToJSON TargetSecretCasRequest where
  toJSON request =
    object
      [ "coordinate" .= targetSecretCasCoordinate request
      , "expected_version" .= targetSecretCasExpectedVersion request
      , "record" .= targetSecretCasRecord request
      , "loopback_nodeport_verified"
          .= targetSecretCasLoopbackNodePortVerified request
      ]

data TargetSecretObservation
  = TargetSecretMissing
  | TargetSecretObserved !Natural !TargetSecretRecord
  deriving (Eq, Show)

instance FromJSON TargetSecretObservation where
  parseJSON =
    withObject "TargetSecretObservation" $ \o -> do
      status <- o .: "status"
      case status :: Text of
        "missing" -> pure TargetSecretMissing
        "observed" -> TargetSecretObserved <$> o .: "version" <*> o .: "record"
        _ -> fail "target-secret observation status must be missing or observed"

instance ToJSON TargetSecretObservation where
  toJSON observation = case observation of
    TargetSecretMissing -> object ["status" .= ("missing" :: Text)]
    TargetSecretObserved version record ->
      object
        [ "status" .= ("observed" :: Text)
        , "version" .= version
        , "record" .= record
        ]

data TargetSecretCasResponse
  = TargetSecretCasApplied !Natural
  | TargetSecretCasConflict !TargetSecretObservation
  deriving (Eq, Show)

instance FromJSON TargetSecretCasResponse where
  parseJSON =
    withObject "TargetSecretCasResponse" $ \o -> do
      status <- o .: "status"
      case status :: Text of
        "applied" -> TargetSecretCasApplied <$> o .: "version"
        "conflict" -> TargetSecretCasConflict <$> o .: "observation"
        _ -> fail "target-secret CAS status must be applied or conflict"

instance ToJSON TargetSecretCasResponse where
  toJSON response = case response of
    TargetSecretCasApplied version ->
      object ["status" .= ("applied" :: Text), "version" .= version]
    TargetSecretCasConflict observation ->
      object
        [ "status" .= ("conflict" :: Text)
        , "observation" .= observation
        ]

data TargetSecretRequestError
  = TargetSecretMethodNotAllowed !String
  | TargetSecretRequestTooLarge !Int !Int
  | TargetSecretRequestEmpty
  | TargetSecretRequestMalformed !String
  | TargetSecretLoopbackUnverified
  | TargetSecretIdentityInvalid !Text
  | TargetSecretIdentityMismatch !Text !Text
  | TargetSecretCoordinateNotAllowed !Text !Text
  | TargetSecretOwnerNonceInvalid !Text
  | TargetSecretFencingTokenMustBePositive
  | TargetSecretGenerationMustBePositive
  | TargetSecretDigestInvalid !Text
  | TargetSecretPayloadEmpty
  | TargetSecretPayloadOverBound !Int !Int
  | TargetSecretFieldNameInvalid !Text
  | TargetSecretReservedFieldCollision !Text
  | TargetSecretMetadataMissing !Text
  | TargetSecretMetadataInvalid !Text !Text
  deriving (Eq, Show)

validateTargetSecretReadRequest
  :: TargetSecretReadRequest -> Either TargetSecretRequestError TargetSecretReadRequest
validateTargetSecretReadRequest request = do
  validateCoordinate (targetSecretReadCoordinate request)
  unless
    (targetSecretReadLoopbackNodePortVerified request)
    (Left TargetSecretLoopbackUnverified)
  pure request

validateTargetSecretCasRequest
  :: TargetSecretCasRequest -> Either TargetSecretRequestError TargetSecretCasRequest
validateTargetSecretCasRequest request = do
  validateCoordinate (targetSecretCasCoordinate request)
  validateTargetSecretRecord (targetSecretCasRecord request)
  unless
    (targetSecretCasLoopbackNodePortVerified request)
    (Left TargetSecretLoopbackUnverified)
  pure request

-- | Bind an explicit sink identity to the daemon actually reached.  Endpoint
-- selection alone is insufficient: a miswired @aws@ sink must not be allowed
-- to write the home Vault merely because both expose the same allowlisted KV
-- path.
validateTargetSecretIdentity
  :: Text
  -> TargetSecretCoordinate
  -> Either TargetSecretRequestError ()
validateTargetSecretIdentity daemonClusterId coordinate =
  unless
    (targetSecretCoordinateIdentity coordinate == daemonClusterId)
    ( Left
        ( TargetSecretIdentityMismatch
            daemonClusterId
            (targetSecretCoordinateIdentity coordinate)
        )
    )

validateCoordinate :: TargetSecretCoordinate -> Either TargetSecretRequestError ()
validateCoordinate coordinate = do
  validateBoundedIdentity
    TargetSecretIdentityInvalid
    (targetSecretCoordinateIdentity coordinate)
  unless
    ( targetSecretCoordinateVaultMount coordinate == "secret"
        && targetSecretCoordinateKvPath coordinate == "keycloak/smtp"
    )
    ( Left
        ( TargetSecretCoordinateNotAllowed
            (targetSecretCoordinateVaultMount coordinate)
            (targetSecretCoordinateKvPath coordinate)
        )
    )

validateTargetSecretRecord
  :: TargetSecretRecord -> Either TargetSecretRequestError ()
validateTargetSecretRecord record = do
  validateBoundedIdentity
    TargetSecretOwnerNonceInvalid
    (targetSecretRecordOwnerNonce record)
  when
    (targetSecretRecordFencingToken record == 0)
    (Left TargetSecretFencingTokenMustBePositive)
  when
    (targetSecretRecordGeneration record == 0)
    (Left TargetSecretGenerationMustBePositive)
  let digest = targetSecretRecordDigest record
  unless
    (Text.length digest == 64 && Text.all isLowerHex digest)
    (Left (TargetSecretDigestInvalid digest))
  let fields = targetSecretRecordFields record
  when (Map.null fields) (Left TargetSecretPayloadEmpty)
  when
    (Map.size fields > targetSecretMaximumFieldCount)
    (Left (TargetSecretPayloadOverBound (Map.size fields) targetSecretMaximumFieldCount))
  mapM_ validateFieldName (Map.keys fields)
  let encodedBytes =
        sum
          [ TextEncoding.encodeUtf8 key `byteLengthPlus` TextEncoding.encodeUtf8 value
          | (key, value) <- Map.toList fields
          ]
  when
    (encodedBytes > targetSecretMaximumPayloadBytes)
    (Left (TargetSecretPayloadOverBound encodedBytes targetSecretMaximumPayloadBytes))
 where
  isLowerHex character = isDigit character || character `elem` ['a' .. 'f']
  byteLengthPlus left right = BS.length left + BS.length right

targetSecretMaximumFieldCount :: Int
targetSecretMaximumFieldCount = 32

targetSecretMaximumPayloadBytes :: Int
targetSecretMaximumPayloadBytes = 32 * 1024

validateBoundedIdentity
  :: (Text -> TargetSecretRequestError)
  -> Text
  -> Either TargetSecretRequestError ()
validateBoundedIdentity onError value =
  unless
    ( not (Text.null value)
        && Text.length value <= 128
        && Text.all safeIdentityCharacter value
    )
    (Left (onError value))
 where
  safeIdentityCharacter character =
    isAsciiLower character
      || isAsciiUpper character
      || isDigit character
      || character `elem` ("-._:@" :: String)

validateFieldName :: Text -> Either TargetSecretRequestError ()
validateFieldName fieldName
  | Text.null fieldName || Text.length fieldName > 128 =
      Left (TargetSecretFieldNameInvalid fieldName)
  | Text.any (not . safeFieldCharacter) fieldName =
      Left (TargetSecretFieldNameInvalid fieldName)
  | targetSecretMetadataPrefix `Text.isPrefixOf` fieldName =
      Left (TargetSecretReservedFieldCollision fieldName)
  | otherwise = Right ()
 where
  safeFieldCharacter character =
    isAsciiLower character
      || isAsciiUpper character
      || isDigit character
      || character `elem` ("-._" :: String)

targetSecretMetadataPrefix :: Text
targetSecretMetadataPrefix = "prodbox_commit_"

ownerNonceField :: Text
ownerNonceField = targetSecretMetadataPrefix <> "owner_nonce"

fencingTokenField :: Text
fencingTokenField = targetSecretMetadataPrefix <> "fencing_token"

generationField :: Text
generationField = targetSecretMetadataPrefix <> "generation"

digestField :: Text
digestField = targetSecretMetadataPrefix <> "digest"

targetSecretRecordToVaultFields
  :: TargetSecretRecord -> Either TargetSecretRequestError (Map Text Text)
targetSecretRecordToVaultFields record = do
  validateTargetSecretRecord record
  pure
    ( Map.unions
        [ targetSecretRecordFields record
        , Map.fromList
            [ (ownerNonceField, targetSecretRecordOwnerNonce record)
            , (fencingTokenField, Text.pack (show (targetSecretRecordFencingToken record)))
            , (generationField, Text.pack (show (targetSecretRecordGeneration record)))
            , (digestField, targetSecretRecordDigest record)
            ]
        ]
    )

targetSecretRecordFromVaultFields
  :: Map Text Text -> Either TargetSecretRequestError TargetSecretRecord
targetSecretRecordFromVaultFields fields = do
  owner <- requireMetadata ownerNonceField fields
  fence <- requireNaturalMetadata fencingTokenField fields
  generation <- requireNaturalMetadata generationField fields
  digest <- requireMetadata digestField fields
  let payload = foldr Map.delete fields metadataFields
  case filter (targetSecretMetadataPrefix `Text.isPrefixOf`) (Map.keys payload) of
    unexpected : _ -> Left (TargetSecretReservedFieldCollision unexpected)
    [] -> do
      let record =
            TargetSecretRecord
              { targetSecretRecordOwnerNonce = owner
              , targetSecretRecordFencingToken = fence
              , targetSecretRecordGeneration = generation
              , targetSecretRecordDigest = digest
              , targetSecretRecordFields = payload
              }
      validateTargetSecretRecord record
      pure record
 where
  metadataFields = [ownerNonceField, fencingTokenField, generationField, digestField]

requireMetadata
  :: Text -> Map Text Text -> Either TargetSecretRequestError Text
requireMetadata fieldName fields =
  case Map.lookup fieldName fields of
    Nothing -> Left (TargetSecretMetadataMissing fieldName)
    Just value -> Right value

requireNaturalMetadata
  :: Text -> Map Text Text -> Either TargetSecretRequestError Natural
requireNaturalMetadata fieldName fields = do
  value <- requireMetadata fieldName fields
  case readMaybe (Text.unpack value) of
    Just parsed -> Right parsed
    Nothing -> Left (TargetSecretMetadataInvalid fieldName value)
