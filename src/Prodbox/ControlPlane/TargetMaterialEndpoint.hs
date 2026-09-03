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
  , TargetMaterialReadinessStage (..)
  , allTargetMaterialReadinessStages
  , renderTargetMaterialReadinessStage
  , targetMaterialReadinessDependencyLabel
  , decodeTargetMaterialReadinessDependencyLabel
  , targetMaterialReadinessObservation
  , vaultTargetMaterialRepository
  , observeVaultTargetMaterialDependencies
  , targetMaterialObservationAuthenticatedHandler
  , targetMaterialResponseMaximumBytes
  , targetMaterialMetadataGenerationField
  , targetMaterialMetadataVaultVersionField
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
import Data.List (find)
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
import Prodbox.ControlPlane.RoleReadiness
  ( RoleDependencyObservation
  , RoleReadinessSource
  , roleDependencyFromOutcome
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (TargetMaterialObserve)
  )
import Prodbox.ControlPlane.TargetMaterialEndpoint.Internal
  ( targetMaterialMetadataActionDigestField
  , targetMaterialMetadataCommitmentField
  , targetMaterialMetadataFencingTokenField
  , targetMaterialMetadataGenerationField
  , targetMaterialMetadataImageDigestField
  , targetMaterialMetadataOwnerNonceField
  , targetMaterialMetadataPodUidField
  , targetMaterialMetadataRequestDigestField
  , targetMaterialMetadataVaultVersionField
  , validateTargetMaterialMetadataInternal
  , validateTargetMaterialMetadataReadinessInternal
  , validatedTargetMaterialActionDigest
  , validatedTargetMaterialCommitment
  , validatedTargetMaterialFencingToken
  , validatedTargetMaterialGeneration
  , validatedTargetMaterialImageDigest
  , validatedTargetMaterialOwnerNonce
  , validatedTargetMaterialPodUid
  , validatedTargetMaterialRequestDigest
  , validatedTargetMaterialVaultVersion
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId
  , allTargetMaterialIds
  , compiledTargetSecretSink
  , targetSecretIdToken
  )
import Prodbox.Http.Client (HttpError (HttpStatus), renderHttpError)
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
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
  , targetMaterialRepositoryReadiness :: !RoleReadinessSource
  }

-- | The closed stage at which a target-material readiness observation can
-- fail. The target itself is carried separately as 'TargetSecretId'; neither
-- component can retain a Vault response, decoder detail, or physical path.
data TargetMaterialReadinessStage
  = TargetMaterialMetadataRead
  | TargetMaterialMetadataValidation
  deriving stock (Bounded, Enum, Eq, Show)

allTargetMaterialReadinessStages :: [TargetMaterialReadinessStage]
allTargetMaterialReadinessStages = [minBound .. maxBound]

renderTargetMaterialReadinessStage :: TargetMaterialReadinessStage -> Text
renderTargetMaterialReadinessStage stage = case stage of
  TargetMaterialMetadataRead -> "metadata-read"
  TargetMaterialMetadataValidation -> "metadata-validation"

targetMaterialReadinessDependencyLabel
  :: TargetSecretId -> TargetMaterialReadinessStage -> Text
targetMaterialReadinessDependencyLabel target stage =
  Text.intercalate
    ":"
    [ "target-material"
    , targetSecretIdToken target
    , renderTargetMaterialReadinessStage stage
    ]

-- | Decode only labels constructed from the closed target and stage
-- inventories. Arbitrary tokens and legacy family-only labels are rejected.
decodeTargetMaterialReadinessDependencyLabel
  :: Text -> Maybe (TargetSecretId, TargetMaterialReadinessStage)
decodeTargetMaterialReadinessDependencyLabel label = case Text.splitOn ":" label of
  ["target-material", targetToken, stageToken] -> do
    target <- find ((== targetToken) . targetSecretIdToken) allTargetMaterialIds
    stage <-
      find ((== stageToken) . renderTargetMaterialReadinessStage) allTargetMaterialReadinessStages
    pure (target, stage)
  _ -> Nothing

targetMaterialResponseMaximumBytes :: Int
targetMaterialResponseMaximumBytes = 64 * 1024

targetMaterialObservationAuthenticatedHandler
  :: (Monad m)
  => Int
  -> TargetMaterialRepository m
  -> AuthenticatedRoleHandler m
targetMaterialObservationAuthenticatedHandler maximumBytes repository =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = targetMaterialRepositoryReadiness repository
    , authenticatedHandlerHandle = handle
    }
 where
  handle _caller route body = case route of
    TargetMaterialObserve -> do
      response <- case decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict body) of
        Left _ -> pure (ReplyBadRequest, TargetMaterialObserveRefused "request-codec-rejected")
        Right request -> do
          observed <- observeTargetMaterial repository (targetMaterialObserveTarget request)
          pure $ case observed of
            Left _ -> (ReplyServiceUnavailable, TargetMaterialObserveRefused "target-metadata-unavailable")
            Right Nothing -> (ReplyNotFound, TargetMaterialMissing)
            Right (Just metadata) -> (ReplyOk, TargetMaterialObserved metadata)
      pure (Just (Data.Bifunctor.second responseBody response))
    _ -> pure Nothing

responseBody :: (Serialise value) => value -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse

vaultTargetMaterialRepository
  :: VaultSession -> RoleReadinessSource -> TargetMaterialRepository IO
vaultTargetMaterialRepository session readiness =
  TargetMaterialRepository
    { observeTargetMaterial = observeVaultTargetMaterialMetadata session
    , targetMaterialRepositoryReadiness = readiness
    }

-- | Sprint 4.55: this used to run on the kubelet request path, once per probe,
-- as an `allM` over every registered target — up to 32 sequential Vault KV
-- reads against a `timeoutSeconds: 1` budget, with the healthy path the slowest
-- because `allM` short-circuits only on failure. It is now one background pass.
observeVaultTargetMaterialDependencies
  :: VaultSession -> IO [(Text, RoleDependencyObservation)]
observeVaultTargetMaterialDependencies session =
  traverse observeOne allTargetMaterialIds
 where
  observeOne target = do
    observed <- readVaultTargetMaterialMetadata session target
    pure (targetMaterialReadinessObservation target observed)

-- | Refine the diagnostic label while preserving the exact pre-Sprint-2.86
-- readiness observation: read/validation failure is unavailable, while a
-- missing or valid target is ready.
targetMaterialReadinessObservation
  :: TargetSecretId
  -> Either Text (Maybe KvV2SecretMetadata)
  -> (Text, RoleDependencyObservation)
targetMaterialReadinessObservation target observed = case observed of
  Left detail ->
    ( targetMaterialReadinessDependencyLabel target TargetMaterialMetadataRead
    , roleDependencyFromOutcome (Left detail)
    )
  Right Nothing -> ready
  Right (Just metadata) ->
    case validateTargetMaterialMetadataReadinessInternal metadata of
      Left detail ->
        ( targetMaterialReadinessDependencyLabel target TargetMaterialMetadataValidation
        , roleDependencyFromOutcome (Left detail)
        )
      Right () -> ready
 where
  ready = ("target-material:" <> targetSecretIdToken target, roleDependencyFromOutcome (Right ()))

observeVaultTargetMaterialMetadata
  :: VaultSession
  -> TargetSecretId
  -> IO (Either Text (Maybe TargetMaterialObservation))
observeVaultTargetMaterialMetadata session target = do
  observed <- readVaultTargetMaterialMetadata session target
  pure (observed >>= traverse observationFromMetadata)

readVaultTargetMaterialMetadata
  :: VaultSession
  -> TargetSecretId
  -> IO (Either Text (Maybe KvV2SecretMetadata))
readVaultTargetMaterialMetadata session target = case compiledTargetSecretSink target of
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
      Right metadata -> Right (Just metadata)

observationFromMetadata
  :: KvV2SecretMetadata
  -> Either Text TargetMaterialObservation
observationFromMetadata metadata = do
  validated <- validateTargetMaterialMetadataInternal metadata
  pure
    TargetMaterialObservation
      { targetMaterialObservedGeneration =
          validatedTargetMaterialGeneration validated
      , targetMaterialObservedVaultVersion =
          validatedTargetMaterialVaultVersion validated
      , targetMaterialObservedCommitment =
          validatedTargetMaterialCommitment validated
      , targetMaterialObservedOwnerNonce =
          validatedTargetMaterialOwnerNonce validated
      , targetMaterialObservedFencingToken =
          validatedTargetMaterialFencingToken validated
      , targetMaterialObservedRequestDigest =
          validatedTargetMaterialRequestDigest validated
      , targetMaterialObservedActionDigest =
          validatedTargetMaterialActionDigest validated
      , targetMaterialObservedPodUid =
          validatedTargetMaterialPodUid validated
      , targetMaterialObservedImageDigest =
          validatedTargetMaterialImageDigest validated
      }
