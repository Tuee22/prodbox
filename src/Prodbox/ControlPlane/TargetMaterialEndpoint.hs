{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Metadata-only steady-state Target Secret Agent observation.
--
-- Plaintext installation belongs exclusively to an attested one-shot target
-- worker. The standing Agent can read only KV-v2 metadata and returns the
-- committed generation, physical version, and opaque digest; neither request
-- nor response can represent target material.
module Prodbox.ControlPlane.TargetMaterialEndpoint
  ( TargetMaterialObserveRequest (..)
  , TargetMaterialObservation (..)
  , TargetMaterialObserveResponse (..)
  , TargetMaterialRepository (..)
  , vaultTargetMaterialRepository
  , targetMaterialObservationAuthenticatedHandler
  , targetMaterialResponseMaximumBytes
  , targetMaterialMetadataGenerationField
  , targetMaterialMetadataCommitmentField
  , targetMaterialMetadataOwnerNonceField
  , targetMaterialMetadataFencingTokenField
  , targetMaterialMetadataRequestDigestField
  , targetMaterialMetadataActionDigestField
  , targetMaterialMetadataPodUidField
  , targetMaterialMetadataImageDigestField
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor qualified
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (TargetMaterialObserve)
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId
  , allTargetMaterialIds
  , compiledTargetSecretSink
  )
import Prodbox.Http.Client (HttpError (HttpStatus), renderHttpError)
import Prodbox.Lifecycle.CheckpointAuthority
  ( targetSecretSinkKvPath
  , targetSecretSinkVaultMount
  )
import Prodbox.Vault.Client
  ( KvV2SecretMetadata (..)
  , vaultKvReadMetadataV2
  )
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , withSessionToken
  )
import Text.Read (readMaybe)

newtype TargetMaterialObserveRequest = TargetMaterialObserveRequest
  { targetMaterialObserveTarget :: TargetSecretId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetMaterialObservation = TargetMaterialObservation
  { targetMaterialObservedGeneration :: !Natural
  , targetMaterialObservedVaultVersion :: !Natural
  , targetMaterialObservedCommitment :: !Text
  , targetMaterialObservedOwnerNonce :: !Text
  , targetMaterialObservedFencingToken :: !Natural
  , targetMaterialObservedRequestDigest :: !Text
  , targetMaterialObservedActionDigest :: !Text
  , targetMaterialObservedPodUid :: !Text
  , targetMaterialObservedImageDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetMaterialObserveResponse
  = TargetMaterialMissing
  | TargetMaterialObserved !TargetMaterialObservation
  | TargetMaterialObserveRefused !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetMaterialRepository m = TargetMaterialRepository
  { observeTargetMaterial
      :: TargetSecretId
      -> m (Either Text (Maybe TargetMaterialObservation))
  , targetMaterialRepositoryReady :: m Bool
  }

targetMaterialResponseMaximumBytes :: Int
targetMaterialResponseMaximumBytes = 64 * 1024

targetMaterialObservationAuthenticatedHandler
  :: (Monad m)
  => Int
  -> TargetMaterialRepository m
  -> AuthenticatedRoleHandler m
targetMaterialObservationAuthenticatedHandler maximumBytes repository =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadyz = targetMaterialRepositoryReady repository
    , authenticatedHandlerHandle = handle
    }
 where
  handle _caller route body = case route of
    TargetMaterialObserve -> do
      response <- case decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict body) of
        Left _ -> pure (400, TargetMaterialObserveRefused "request-codec-rejected")
        Right request -> do
          observed <- observeTargetMaterial repository (targetMaterialObserveTarget request)
          pure $ case observed of
            Left _ -> (503, TargetMaterialObserveRefused "target-metadata-unavailable")
            Right Nothing -> (404, TargetMaterialMissing)
            Right (Just metadata) -> (200, TargetMaterialObserved metadata)
      pure (Just (Data.Bifunctor.second responseBody response))
    _ -> pure Nothing

responseBody :: (Serialise value) => value -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse

vaultTargetMaterialRepository :: VaultSession -> TargetMaterialRepository IO
vaultTargetMaterialRepository session =
  TargetMaterialRepository
    { observeTargetMaterial = observeVaultTargetMaterialMetadata session
    , targetMaterialRepositoryReady =
        allM
          (fmap (either (const False) (const True)) . observeVaultTargetMaterialMetadata session)
          allTargetMaterialIds
    }

observeVaultTargetMaterialMetadata
  :: VaultSession
  -> TargetSecretId
  -> IO (Either Text (Maybe TargetMaterialObservation))
observeVaultTargetMaterialMetadata session target = case compiledTargetSecretSink target of
  Left detail -> pure (Left detail)
  Right sink -> do
    result <-
      withSessionToken session $ \token ->
        vaultKvReadMetadataV2
          (sessionAddress session)
          token
          (targetSecretSinkVaultMount sink)
          (targetSecretSinkKvPath sink)
    pure $ case result of
      Left (HttpStatus 404 _) -> Right Nothing
      Left err -> Left (Text.pack (renderHttpError err))
      Right metadata -> Just <$> observationFromMetadata metadata

observationFromMetadata
  :: KvV2SecretMetadata
  -> Either Text TargetMaterialObservation
observationFromMetadata metadata = do
  generationText <-
    maybe
      (Left "target metadata has no committed generation")
      Right
      (Map.lookup targetMaterialMetadataGenerationField custom)
  generation <-
    maybe
      (Left "target metadata generation is invalid")
      Right
      (readNatural generationText)
  if generation == 0
    then Left "target metadata generation must be positive"
    else Right ()
  commitment <-
    maybe
      (Left "target metadata has no opaque commitment")
      validateCommitment
      (Map.lookup targetMaterialMetadataCommitmentField custom)
  ownerNonce <-
    maybe
      (Left "target metadata has no owner nonce")
      validateOwnerNonce
      (Map.lookup targetMaterialMetadataOwnerNonceField custom)
  fencingText <-
    maybe
      (Left "target metadata has no fencing token")
      Right
      (Map.lookup targetMaterialMetadataFencingTokenField custom)
  fencing <-
    maybe
      (Left "target metadata fencing token is invalid")
      Right
      (readNatural fencingText)
  if fencing == 0
    then Left "target metadata fencing token must be positive"
    else Right ()
  requestDigest <-
    requiredBounded "request digest" targetMaterialMetadataRequestDigestField 256 custom
  actionDigest <- requiredBounded "action digest" targetMaterialMetadataActionDigestField 256 custom
  podUid <- requiredBounded "Pod UID" targetMaterialMetadataPodUidField 256 custom
  imageDigest <- requiredBounded "image digest" targetMaterialMetadataImageDigestField 256 custom
  pure
    TargetMaterialObservation
      { targetMaterialObservedGeneration = generation
      , targetMaterialObservedVaultVersion = kvV2SecretMetadataCurrentVersion metadata
      , targetMaterialObservedCommitment = commitment
      , targetMaterialObservedOwnerNonce = ownerNonce
      , targetMaterialObservedFencingToken = fencing
      , targetMaterialObservedRequestDigest = requestDigest
      , targetMaterialObservedActionDigest = actionDigest
      , targetMaterialObservedPodUid = podUid
      , targetMaterialObservedImageDigest = imageDigest
      }
 where
  custom = kvV2SecretMetadataCustom metadata

validateCommitment :: Text -> Either Text Text
validateCommitment value
  | Text.null value = Left "target metadata commitment is empty"
  | Text.length value > 256 = Left "target metadata commitment is over bound"
  | Text.any isControl value = Left "target metadata commitment contains control characters"
  | otherwise = Right value

validateOwnerNonce :: Text -> Either Text Text
validateOwnerNonce value
  | Text.null value = Left "target metadata owner nonce is empty"
  | Text.length value > 128 = Left "target metadata owner nonce is over bound"
  | Text.any isControl value = Left "target metadata owner nonce contains control characters"
  | Text.any (== ' ') value = Left "target metadata owner nonce contains whitespace"
  | otherwise = Right value

requiredBounded :: Text -> Text -> Int -> Map.Map Text Text -> Either Text Text
requiredBounded label field maximumLength fields = do
  value <- maybe (Left ("target metadata has no " <> label)) Right (Map.lookup field fields)
  if Text.null value || Text.length value > maximumLength || Text.strip value /= value
    then Left ("target metadata " <> label <> " is invalid")
    else Right value

readNatural :: Text -> Maybe Natural
readNatural = readMaybe . Text.unpack

allM :: (Monad m) => (value -> m Bool) -> [value] -> m Bool
allM predicate = go
 where
  go [] = pure True
  go (value : rest) = do
    accepted <- predicate value
    if accepted then go rest else pure False

targetMaterialMetadataGenerationField :: Text
targetMaterialMetadataGenerationField = "prodbox_generation"

targetMaterialMetadataCommitmentField :: Text
targetMaterialMetadataCommitmentField = "prodbox_commitment"

targetMaterialMetadataOwnerNonceField :: Text
targetMaterialMetadataOwnerNonceField = "prodbox_owner_nonce"

targetMaterialMetadataFencingTokenField :: Text
targetMaterialMetadataFencingTokenField = "prodbox_fencing_token"

targetMaterialMetadataRequestDigestField :: Text
targetMaterialMetadataRequestDigestField = "prodbox_request_digest"

targetMaterialMetadataActionDigestField :: Text
targetMaterialMetadataActionDigestField = "prodbox_action_digest"

targetMaterialMetadataPodUidField :: Text
targetMaterialMetadataPodUidField = "prodbox_worker_pod_uid"

targetMaterialMetadataImageDigestField :: Text
targetMaterialMetadataImageDigestField = "prodbox_worker_image_digest"
