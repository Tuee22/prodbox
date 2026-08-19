{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authority-retained record of the exact Provider binding that first
-- admitted a registered AWS stack creation.  The source operation is opaque:
-- it can be obtained only by independently reopening the Authority admission
-- aggregate and matching an exact retained @ReconcileRegisteredStack@.
--
-- This module deliberately does not install itself in the normal mutation
-- path.  That path must first supply a positively observed AWS account/region
-- binding and a replay-stable submission identity.
module Prodbox.ControlPlane.AwsStackCreationBindingRepository
  ( ObservedAwsStackCreationOperation
  , observeAuthorityAwsStackCreationOperation
  , observedAwsStackCreationOperationId
  , observedAwsStackCreationKey
  , observedAwsStackCreationCoordinateDigest
  , observedAwsStackCreationRevision
  , observedAwsStackCreationConfig
  , AwsStackCreationAuthorityIdentity
  , awsStackCreationAuthoritySubmissionKey
  , awsStackCreationAuthorityKey
  , awsStackCreationAuthorityCoordinateDigest
  , awsStackCreationAuthoritySurface
  , awsStackCreationAuthorityRegistryRevision
  , awsStackCreationAuthorityRunScope
  , awsStackCreationAuthorityFoundation
  , awsStackCreationAuthorityAwsScope
  , awsStackCreationAuthorityLogicalName
  , encodeAwsStackCreationAuthorityIdentity
  , decodeAwsStackCreationAuthorityIdentity
  , maximumAwsStackCreationAuthorityIdentityBytes
  , AwsStackCreationBinding
  , prepareAwsStackCreationBinding
  , awsStackCreationBindingIdentity
  , awsStackCreationBindingOperationId
  , awsStackCreationBindingRevision
  , awsStackCreationBindingConfig
  , awsStackCreationBindingBytes
  , maximumAwsStackCreationBindingBytes
  , AwsStackCreationBindingError (..)
  , AwsStackCreationCommitResult (..)
  , AwsStackCreationReadBackObservation (..)
  , AwsStackCreationBindingRepository (..)
  , awsStackCreationBindingModelBCodec
  , modelBAwsStackCreationBindingRepository
  , CommittedAwsStackCreationBinding
  , committedAwsStackCreationIdentity
  , committedAwsStackCreationOperationId
  , committedAwsStackCreationRevision
  , committedAwsStackCreationConfig
  , confirmCommittedAwsStackCreationBindingBytes
  , confirmCommittedAwsStackCreationBindingReadBack
  , commitAwsStackCreationBindingAttempt
  , independentlyReadBackCommittedAwsStackCreationBinding
  , AwsStackCreationBindingClient (..)
  , lifecycleAuthorityAwsStackCreationBindingClient
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAscii, isControl, isDigit, isSpace)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityProviderOperation (..)
  , authorityAggregateProviderOperations
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( authorityEpochFromValue
  , authorityEpochValue
  )
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId (..)
  , ClientSequence (..)
  , OperationId (..)
  , RequestDigest (..)
  , requestDigestText
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (ModelBInitialize)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ReconcileRegisteredStack)
  , ProviderRevision
  , ProviderStackConfig (..)
  , ProviderStackRef
  , mkAwsEksProviderStackConfig
  , mkAwsEksSubzoneProviderStackConfig
  , mkAwsTestProviderStackConfig
  , mkProviderRevision
  , mkProviderStackRef
  , providerRevisionNatural
  , providerStackRefText
  , validateProviderStackConfig
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Registry
  ( cleanupSurfaceAllows
  , lifecycleRegistryRevision
  , lookupRegisteredIdentity
  , registeredIdentityCoordinateDigest
  , registeredIdentityKind
  )

data ObservedAwsStackCreationOperation = ObservedAwsStackCreationOperation
  { internalObservedAwsStackCreationOperationId :: !OperationId
  , internalObservedAwsStackCreationKey :: !RegisteredResourceKey
  , internalObservedAwsStackCreationCoordinateDigest
      :: !ManagedResourceCoordinateDigest
  , internalObservedAwsStackCreationRevision :: !ProviderRevision
  , internalObservedAwsStackCreationConfig :: !ProviderStackConfig
  }

observedAwsStackCreationOperationId
  :: ObservedAwsStackCreationOperation -> OperationId
observedAwsStackCreationOperationId =
  internalObservedAwsStackCreationOperationId

observedAwsStackCreationKey
  :: ObservedAwsStackCreationOperation -> RegisteredResourceKey
observedAwsStackCreationKey = internalObservedAwsStackCreationKey

observedAwsStackCreationCoordinateDigest
  :: ObservedAwsStackCreationOperation -> ManagedResourceCoordinateDigest
observedAwsStackCreationCoordinateDigest =
  internalObservedAwsStackCreationCoordinateDigest

observedAwsStackCreationRevision
  :: ObservedAwsStackCreationOperation -> ProviderRevision
observedAwsStackCreationRevision = internalObservedAwsStackCreationRevision

observedAwsStackCreationConfig
  :: ObservedAwsStackCreationOperation -> ProviderStackConfig
observedAwsStackCreationConfig = internalObservedAwsStackCreationConfig

data AwsStackCreationAuthorityIdentity = AwsStackCreationAuthorityIdentity
  { internalAwsStackCreationSubmissionKey :: !Text
  , internalAwsStackCreationKey :: !RegisteredResourceKey
  , internalAwsStackCreationCoordinateDigest :: !ManagedResourceCoordinateDigest
  , internalAwsStackCreationSurface :: !CleanupSurface
  , internalAwsStackCreationRegistryRevision :: !RegistryRevision
  , internalAwsStackCreationRunScope :: !DurableObservationRunScope
  , internalAwsStackCreationFoundation :: !LinuxRke2FoundationId
  , internalAwsStackCreationAwsScope :: !AwsScope
  }
  deriving stock (Eq, Show)

awsStackCreationAuthoritySubmissionKey
  :: AwsStackCreationAuthorityIdentity -> Text
awsStackCreationAuthoritySubmissionKey = internalAwsStackCreationSubmissionKey

awsStackCreationAuthorityKey
  :: AwsStackCreationAuthorityIdentity -> RegisteredResourceKey
awsStackCreationAuthorityKey = internalAwsStackCreationKey

awsStackCreationAuthorityCoordinateDigest
  :: AwsStackCreationAuthorityIdentity -> ManagedResourceCoordinateDigest
awsStackCreationAuthorityCoordinateDigest =
  internalAwsStackCreationCoordinateDigest

awsStackCreationAuthoritySurface
  :: AwsStackCreationAuthorityIdentity -> CleanupSurface
awsStackCreationAuthoritySurface = internalAwsStackCreationSurface

awsStackCreationAuthorityRegistryRevision
  :: AwsStackCreationAuthorityIdentity -> RegistryRevision
awsStackCreationAuthorityRegistryRevision =
  internalAwsStackCreationRegistryRevision

awsStackCreationAuthorityRunScope
  :: AwsStackCreationAuthorityIdentity -> DurableObservationRunScope
awsStackCreationAuthorityRunScope = internalAwsStackCreationRunScope

awsStackCreationAuthorityFoundation
  :: AwsStackCreationAuthorityIdentity -> LinuxRke2FoundationId
awsStackCreationAuthorityFoundation = internalAwsStackCreationFoundation

awsStackCreationAuthorityAwsScope
  :: AwsStackCreationAuthorityIdentity -> AwsScope
awsStackCreationAuthorityAwsScope = internalAwsStackCreationAwsScope

awsStackCreationAuthorityLogicalName
  :: AwsStackCreationAuthorityIdentity -> Text
awsStackCreationAuthorityLogicalName identity =
  "authority/aws-stack-creations/"
    <> internalAwsStackCreationSubmissionKey identity

data AwsStackCreationIdentityWire = AwsStackCreationIdentityWire
  { creationIdentityWireVersion :: !Int
  , creationIdentityWireRegistryRevision :: !Text
  , creationIdentityWireKey :: !Int
  , creationIdentityWireCoordinateDigest :: !Text
  , creationIdentityWireSurface :: !Int
  , creationIdentityWireRunScope :: !Text
  , creationIdentityWireFoundation :: !Text
  , creationIdentityWireAwsAccount :: !Text
  , creationIdentityWireAwsRegion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

maximumAwsStackCreationAuthorityIdentityBytes :: Int
maximumAwsStackCreationAuthorityIdentityBytes = 16 * 1024

encodeAwsStackCreationAuthorityIdentity
  :: AwsStackCreationAuthorityIdentity -> ByteString
encodeAwsStackCreationAuthorityIdentity =
  LazyByteString.toStrict . serialise . creationIdentityToWire

decodeAwsStackCreationAuthorityIdentity
  :: ByteString
  -> Either AwsStackCreationBindingError AwsStackCreationAuthorityIdentity
decodeAwsStackCreationAuthorityIdentity bytes = do
  when (ByteString.null bytes) (Left AwsStackCreationEmpty)
  when
    (ByteString.length bytes > maximumAwsStackCreationAuthorityIdentityBytes)
    ( Left
        ( AwsStackCreationTooLarge
            maximumAwsStackCreationAuthorityIdentityBytes
            (ByteString.length bytes)
        )
    )
  wire <-
    first
      (AwsStackCreationDecodeFailed . Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (LazyByteString.toStrict (serialise wire) == bytes)
    (Left AwsStackCreationNonCanonical)
  unless
    (creationIdentityWireVersion wire == 1)
    ( Left
        ( AwsStackCreationVersionUnsupported
            (creationIdentityWireVersion wire)
        )
    )
  unless
    ( creationIdentityWireRegistryRevision wire
        == registryRevisionText lifecycleRegistryRevision
    )
    (Left (AwsStackCreationFieldInvalid "registry revision mismatch"))
  key <- decodeBoundedKey (creationIdentityWireKey wire)
  surface <- decodeBoundedSurface (creationIdentityWireSurface wire)
  runScope <-
    DurableObservationRunScope
      <$> checkedText
        "durable run scope"
        512
        (creationIdentityWireRunScope wire)
  foundation <-
    LinuxRke2FoundationId
      <$> checkedText
        "Linux RKE2 foundation"
        512
        (creationIdentityWireFoundation wire)
  let awsScope =
        AwsScope
          (AwsAccountId (creationIdentityWireAwsAccount wire))
          (AwsRegion (creationIdentityWireAwsRegion wire))
      creationScope =
        mkObservationEvidenceScope
          surface
          lifecycleRegistryRevision
          runScope
          foundation
          (Just awsScope)
          ReconcileDesiredPresent
  identity <- identityFor ReconcileDesiredPresent key creationScope
  unless
    ( creationIdentityWireCoordinateDigest wire
        == managedResourceCoordinateDigestText
          (awsStackCreationAuthorityCoordinateDigest identity)
    )
    (Left (AwsStackCreationFieldInvalid "registered coordinate mismatch"))
  Right identity

creationIdentityToWire
  :: AwsStackCreationAuthorityIdentity -> AwsStackCreationIdentityWire
creationIdentityToWire identity =
  AwsStackCreationIdentityWire
    { creationIdentityWireVersion = 1
    , creationIdentityWireRegistryRevision =
        registryRevisionText (awsStackCreationAuthorityRegistryRevision identity)
    , creationIdentityWireKey = fromEnum (awsStackCreationAuthorityKey identity)
    , creationIdentityWireCoordinateDigest =
        managedResourceCoordinateDigestText
          (awsStackCreationAuthorityCoordinateDigest identity)
    , creationIdentityWireSurface =
        fromEnum (awsStackCreationAuthoritySurface identity)
    , creationIdentityWireRunScope =
        durableRunScopeText (awsStackCreationAuthorityRunScope identity)
    , creationIdentityWireFoundation =
        foundationText (awsStackCreationAuthorityFoundation identity)
    , creationIdentityWireAwsAccount =
        awsAccountText (awsStackCreationAuthorityAwsScope identity)
    , creationIdentityWireAwsRegion =
        awsRegionText (awsStackCreationAuthorityAwsScope identity)
    }

data AwsStackCreationBinding = AwsStackCreationBinding
  { internalAwsStackCreationBindingIdentity
      :: !AwsStackCreationAuthorityIdentity
  , internalAwsStackCreationBindingOperationId :: !OperationId
  , internalAwsStackCreationBindingRevision :: !ProviderRevision
  , internalAwsStackCreationBindingConfig :: !ProviderStackConfig
  , internalAwsStackCreationBindingBytes :: !ByteString
  }

instance Eq AwsStackCreationBinding where
  left == right =
    awsStackCreationBindingBytes left == awsStackCreationBindingBytes right

instance Show AwsStackCreationBinding where
  show binding =
    "<aws-stack-creation-binding:"
      <> show
        (awsStackCreationAuthorityKey (awsStackCreationBindingIdentity binding))
      <> ">"

awsStackCreationBindingIdentity
  :: AwsStackCreationBinding -> AwsStackCreationAuthorityIdentity
awsStackCreationBindingIdentity = internalAwsStackCreationBindingIdentity

awsStackCreationBindingOperationId :: AwsStackCreationBinding -> OperationId
awsStackCreationBindingOperationId = internalAwsStackCreationBindingOperationId

awsStackCreationBindingRevision :: AwsStackCreationBinding -> ProviderRevision
awsStackCreationBindingRevision = internalAwsStackCreationBindingRevision

awsStackCreationBindingConfig :: AwsStackCreationBinding -> ProviderStackConfig
awsStackCreationBindingConfig = internalAwsStackCreationBindingConfig

awsStackCreationBindingBytes :: AwsStackCreationBinding -> ByteString
awsStackCreationBindingBytes = internalAwsStackCreationBindingBytes

maximumAwsStackCreationBindingBytes :: Int
maximumAwsStackCreationBindingBytes = 32 * 1024

data AwsStackCreationBindingError
  = AwsStackCreationAdmissionUnavailable !Text
  | AwsStackCreationOperationMissing !OperationId
  | AwsStackCreationOperationDigestMismatch !OperationId
  | AwsStackCreationOperationNotReconcile !OperationId
  | AwsStackCreationProviderRevisionMismatch !ProviderRevision !ProviderRevision
  | AwsStackCreationProviderConfigInvalid !Text
  | AwsStackCreationStackUnregistered !Text
  | AwsStackCreationResourceNotStack !RegisteredResourceKey !ResourceKind
  | AwsStackCreationAwsAccountInvalid !Text
  | AwsStackCreationAwsRegionInvalid !Text
  | AwsStackCreationEmpty
  | AwsStackCreationTooLarge !Int !Int
  | AwsStackCreationDecodeFailed !Text
  | AwsStackCreationNonCanonical
  | AwsStackCreationVersionUnsupported !Int
  | AwsStackCreationFieldInvalid !Text
  | AwsStackCreationConfirmationMissing
  | AwsStackCreationConfirmationCorrupt !Text
  | AwsStackCreationConfirmationUnobservable !ObservationFailure
  | AwsStackCreationConfirmationUnbounded !Int !Int
  | AwsStackCreationIdentityMismatch
      !AwsStackCreationAuthorityIdentity
      !AwsStackCreationAuthorityIdentity
  deriving stock (Eq, Show)

data AwsStackCreationCommitResult
  = AwsStackCreationCommitCreated
  | AwsStackCreationCommitExactReplay
  | AwsStackCreationCommitConflict
  | AwsStackCreationCommitResponseLost !ObservationFailure
  | AwsStackCreationCommitUnavailable !ObservationFailure
  deriving stock (Eq, Show)

data AwsStackCreationReadBackObservation
  = AwsStackCreationReadBackPresent !ByteString
  | AwsStackCreationReadBackMissing
  | AwsStackCreationReadBackCorrupt !Text
  | AwsStackCreationReadBackUnobservable !ObservationFailure
  | AwsStackCreationReadBackUnbounded !Int !Int
  deriving stock (Eq, Show)

data AwsStackCreationBindingRepository m = AwsStackCreationBindingRepository
  { createOrReplayAwsStackCreationBinding
      :: AwsStackCreationBinding -> m AwsStackCreationCommitResult
  , independentlyReadBackAwsStackCreationBinding
      :: AwsStackCreationAuthorityIdentity
      -> m AwsStackCreationReadBackObservation
  }

data CommittedAwsStackCreationBinding = CommittedAwsStackCreationBinding
  { internalCommittedAwsStackCreationBinding :: !AwsStackCreationBinding
  }

committedAwsStackCreationIdentity
  :: CommittedAwsStackCreationBinding -> AwsStackCreationAuthorityIdentity
committedAwsStackCreationIdentity =
  awsStackCreationBindingIdentity . internalCommittedAwsStackCreationBinding

committedAwsStackCreationOperationId
  :: CommittedAwsStackCreationBinding -> OperationId
committedAwsStackCreationOperationId =
  awsStackCreationBindingOperationId . internalCommittedAwsStackCreationBinding

committedAwsStackCreationRevision
  :: CommittedAwsStackCreationBinding -> ProviderRevision
committedAwsStackCreationRevision =
  awsStackCreationBindingRevision . internalCommittedAwsStackCreationBinding

committedAwsStackCreationConfig
  :: CommittedAwsStackCreationBinding -> ProviderStackConfig
committedAwsStackCreationConfig =
  awsStackCreationBindingConfig . internalCommittedAwsStackCreationBinding

confirmCommittedAwsStackCreationBindingBytes
  :: AwsStackCreationAuthorityIdentity
  -> ByteString
  -> Either AwsStackCreationBindingError CommittedAwsStackCreationBinding
confirmCommittedAwsStackCreationBindingBytes expected bytes =
  confirmCommittedAwsStackCreationBindingReadBack
    expected
    (AwsStackCreationReadBackPresent bytes)

confirmCommittedAwsStackCreationBindingReadBack
  :: AwsStackCreationAuthorityIdentity
  -> AwsStackCreationReadBackObservation
  -> Either AwsStackCreationBindingError CommittedAwsStackCreationBinding
confirmCommittedAwsStackCreationBindingReadBack expected observed =
  CommittedAwsStackCreationBinding <$> confirmReadBack expected observed

data AwsStackCreationBindingClient m = AwsStackCreationBindingClient
  { attemptAwsStackCreationBindingCommit
      :: OperationId
      -- \^ the admitted create operation
      -> OperationId
      -- \^ Sprint 4.84: the admitted @ObserveProviderAwsScope@ operation whose
      -- retained receipt proves the account and region.  The binding slot
      -- itself does not consume it; the endpoint behind this client does,
      -- because committing the run-invariant generation needs a proven scope.
      -> ProviderRevision
      -> ObservationEvidenceScope
      -> m (Either AwsStackCreationBindingError AwsStackCreationCommitResult)
  , readBackAwsStackCreationBindingByIdentity
      :: AwsStackCreationAuthorityIdentity
      -> m
           ( Either
               AwsStackCreationBindingError
               CommittedAwsStackCreationBinding
           )
  }

data ProviderConfigWire
  = AwsEksProviderConfigWire !Text
  | AwsTestProviderConfigWire !Text
  | AwsEksSubzoneProviderConfigWire !Text !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsStackCreationWire = AwsStackCreationWire
  { creationWireVersion :: !Int
  , creationWireRegistryRevision :: !Text
  , creationWireKey :: !Int
  , creationWireCoordinateDigest :: !Text
  , creationWireSurface :: !Int
  , creationWireRunScope :: !Text
  , creationWireFoundation :: !Text
  , creationWireAwsAccount :: !Text
  , creationWireAwsRegion :: !Text
  , creationWireOperationEpoch :: !Integer
  , creationWireOperationClient :: !Text
  , creationWireOperationSequence :: !Integer
  , creationWireOperationDigest :: !Text
  , creationWireProviderRevision :: !Integer
  , creationWireProviderConfig :: !ProviderConfigWire
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

observeAuthorityAwsStackCreationOperation
  :: (Monad m)
  => AuthorityAdmissionRepository m revision
  -> ProviderRevision
  -> OperationId
  -> m (Either AwsStackCreationBindingError ObservedAwsStackCreationOperation)
observeAuthorityAwsStackCreationOperation repository currentRevision operationId = do
  observed <- readAuthorityAdmission repository
  pure $ do
    snapshot <- first AwsStackCreationAdmissionUnavailable observed
    retained <-
      maybe
        (Left (AwsStackCreationOperationMissing operationId))
        Right
        ( Map.lookup
            (operationIdClient operationId, operationIdSequence operationId)
            ( authorityAggregateProviderOperations
                (authorityAdmissionSnapshotState snapshot)
            )
        )
    (digest, intent) <- case retained of
      AuthorityProviderPending retainedDigest retainedIntent _ ->
        Right (retainedDigest, retainedIntent)
      AuthorityProviderCompleted retainedDigest retainedIntent _ _ ->
        Right (retainedDigest, retainedIntent)
    unless
      (digest == operationIdDigest operationId)
      (Left (AwsStackCreationOperationDigestMismatch operationId))
    case intent of
      ReconcileRegisteredStack ref revision config -> do
        unless
          (revision == currentRevision)
          ( Left
              ( AwsStackCreationProviderRevisionMismatch
                  currentRevision
                  revision
              )
          )
        first
          (AwsStackCreationProviderConfigInvalid . Text.pack . show)
          (validateProviderStackConfig ref config)
        (key, coordinate) <- registeredStackForRef ref
        Right
          ObservedAwsStackCreationOperation
            { internalObservedAwsStackCreationOperationId = operationId
            , internalObservedAwsStackCreationKey = key
            , internalObservedAwsStackCreationCoordinateDigest = coordinate
            , internalObservedAwsStackCreationRevision = revision
            , internalObservedAwsStackCreationConfig = config
            }
      _ -> Left (AwsStackCreationOperationNotReconcile operationId)

prepareAwsStackCreationBinding
  :: ObservedAwsStackCreationOperation
  -> ObservationEvidenceScope
  -> Either AwsStackCreationBindingError AwsStackCreationBinding
prepareAwsStackCreationBinding observed creationScope = do
  identity <-
    identityFor
      ReconcileDesiredPresent
      (observedAwsStackCreationKey observed)
      creationScope
  unless
    ( awsStackCreationAuthorityCoordinateDigest identity
        == observedAwsStackCreationCoordinateDigest observed
    )
    (Left (AwsStackCreationFieldInvalid "registered coordinate changed"))
  let wire = wireFromObserved identity observed
      bytes = canonicalBytes wire
  when
    (ByteString.length bytes > maximumAwsStackCreationBindingBytes)
    ( Left
        ( AwsStackCreationTooLarge
            maximumAwsStackCreationBindingBytes
            (ByteString.length bytes)
        )
    )
  decodeAwsStackCreationBinding bytes

commitAwsStackCreationBindingAttempt
  :: (Monad m)
  => AwsStackCreationBindingRepository m
  -> ObservedAwsStackCreationOperation
  -> ObservationEvidenceScope
  -> m (Either AwsStackCreationBindingError AwsStackCreationCommitResult)
commitAwsStackCreationBindingAttempt repository observed creationScope =
  case prepareAwsStackCreationBinding observed creationScope of
    Left err -> pure (Left err)
    Right candidate ->
      Right <$> createOrReplayAwsStackCreationBinding repository candidate

independentlyReadBackCommittedAwsStackCreationBinding
  :: (Monad m)
  => AwsStackCreationBindingRepository m
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> m (Either AwsStackCreationBindingError CommittedAwsStackCreationBinding)
independentlyReadBackCommittedAwsStackCreationBinding repository key cleanupScope =
  case identityFor ReconcileDesiredAbsent key cleanupScope of
    Left err -> pure (Left err)
    Right identity -> do
      observed <- independentlyReadBackAwsStackCreationBinding repository identity
      pure (confirmCommittedAwsStackCreationBindingReadBack identity observed)

-- | A binding-only client.  See the note on 'attemptAwsStackCreationBindingCommit'.
lifecycleAuthorityAwsStackCreationBindingClient
  :: (Monad m)
  => AuthorityAdmissionRepository m revision
  -> AwsStackCreationBindingRepository m
  -> AwsStackCreationBindingClient m
lifecycleAuthorityAwsStackCreationBindingClient admissionRepository repository =
  AwsStackCreationBindingClient
    { attemptAwsStackCreationBindingCommit = attemptCommit
    , readBackAwsStackCreationBindingByIdentity = readBack
    }
 where
  -- The binding slot alone.  Production goes through
  -- "Prodbox.ControlPlane.RegisteredStackCreationProducer", which proves the
  -- AWS scope, reserves a cycle, and commits the run-invariant generation
  -- before committing this binding; this constructor is retained so the
  -- binding slot's own create/replay/read-back semantics stay independently
  -- exercisable, and it therefore has no use for the scope-observation
  -- operation.
  attemptCommit operationId _providerScopeOperation currentRevision creationScope = do
    observed <-
      observeAuthorityAwsStackCreationOperation
        admissionRepository
        currentRevision
        operationId
    case observed of
      Left err -> pure (Left err)
      Right exact ->
        commitAwsStackCreationBindingAttempt repository exact creationScope

  readBack identity = do
    observed <- independentlyReadBackAwsStackCreationBinding repository identity
    pure (confirmCommittedAwsStackCreationBindingReadBack identity observed)

awsStackCreationBindingModelBCodec :: ModelBCodec ByteString
awsStackCreationBindingModelBCodec =
  ModelBCodec
    { encodeModelBValue = first show . validateCanonicalBytes
    , decodeModelBValue = first show . validateCanonicalBytes
    }

modelBAwsStackCreationBindingRepository
  :: (Monad m)
  => LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> AwsStackCreationBindingRepository m
modelBAwsStackCreationBindingRepository authority adapter =
  AwsStackCreationBindingRepository
    { createOrReplayAwsStackCreationBinding = createOrReplay
    , independentlyReadBackAwsStackCreationBinding = readBack
    }
 where
  createOrReplay binding =
    case coordinateFor (awsStackCreationBindingIdentity binding) of
      Left failure -> pure (AwsStackCreationCommitUnavailable failure)
      Right coordinate -> do
        observed <- modelBObserve adapter coordinate
        case observed of
          ModelBMissing -> initialize coordinate binding
          ModelBObserved _ existing -> pure (existingDisposition binding existing)
          ModelBCorrupt detail -> pure (unavailable "corrupt" detail)
          ModelBEndpointUnready detail -> pure (unavailable "endpoint-unready" detail)
          ModelBUnobservable detail -> pure (unavailable "unobservable" detail)

  initialize coordinate binding = do
    result <-
      modelBCompareAndSwap
        adapter
        (ModelBInitialize coordinate (awsStackCreationBindingBytes binding))
    pure $ case result of
      ModelBCasApplied _ applied
        | applied == awsStackCreationBindingBytes binding ->
            AwsStackCreationCommitCreated
        | otherwise -> AwsStackCreationCommitConflict
      ModelBCasConflict observation -> conflictDisposition binding observation
      ModelBCasRefusedCorrupt detail -> unavailable "cas-corrupt" detail
      ModelBCasEndpointUnready detail -> unavailable "cas-endpoint-unready" detail
      ModelBCasUnobservable detail ->
        AwsStackCreationCommitResponseLost
          (repositoryFailure "cas-response-unobservable" detail)

  readBack identity = case coordinateFor identity of
    Left failure -> pure (AwsStackCreationReadBackUnobservable failure)
    Right coordinate -> do
      observed <- modelBObserve adapter coordinate
      pure $ case observed of
        ModelBMissing -> AwsStackCreationReadBackMissing
        ModelBObserved _ bytes
          | ByteString.length bytes > maximumAwsStackCreationBindingBytes ->
              AwsStackCreationReadBackUnbounded
                (ByteString.length bytes)
                maximumAwsStackCreationBindingBytes
          | otherwise -> AwsStackCreationReadBackPresent bytes
        ModelBCorrupt detail -> AwsStackCreationReadBackCorrupt detail
        ModelBEndpointUnready detail -> unobservable "endpoint-unready" detail
        ModelBUnobservable detail -> unobservable "unobservable" detail

  coordinateFor identity =
    first
      (repositoryFailure "coordinate" . Text.pack . show)
      ( mkClusterRetainedCoordinate
          authority
          (awsStackCreationAuthorityLogicalName identity)
      )
  unavailable category detail =
    AwsStackCreationCommitUnavailable (repositoryFailure category detail)
  unobservable category detail =
    AwsStackCreationReadBackUnobservable (repositoryFailure category detail)

identityFor
  :: LifecycleOperation
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> Either AwsStackCreationBindingError AwsStackCreationAuthorityIdentity
identityFor
  expectedOperation
  key
  scope = do
    unless
      (evidenceLifecycleOperation scope == expectedOperation)
      (Left (AwsStackCreationFieldInvalid "lifecycle operation mismatch"))
    unless
      (evidenceRegistryRevision scope == lifecycleRegistryRevision)
      (Left (AwsStackCreationFieldInvalid "registry revision mismatch"))
    let runScope@(DurableObservationRunScope runScopeValue) =
          evidenceDurableRunScope scope
        foundation@(LinuxRke2FoundationId foundationValue) =
          evidenceLinuxRke2Foundation scope
        surface = evidenceCleanupSurface scope
    awsScope@(AwsScope (AwsAccountId account) (AwsRegion region)) <-
      maybe
        (Left (AwsStackCreationFieldInvalid "AWS scope is missing"))
        Right
        (evidenceAwsScope scope)
    _ <- checkedText "durable run scope" 512 runScopeValue
    _ <- checkedText "Linux RKE2 foundation" 512 foundationValue
    validateAwsAccount account
    validateAwsRegion region
    identity <-
      maybe
        (Left (AwsStackCreationStackUnregistered (registeredResourceKeyText key)))
        Right
        (lookupRegisteredIdentity key)
    unless
      (registeredIdentityKind identity == Stack)
      ( Left
          ( AwsStackCreationResourceNotStack
              key
              (registeredIdentityKind identity)
          )
      )
    unless
      (cleanupSurfaceAllows surface identity)
      (Left (AwsStackCreationFieldInvalid "cleanup surface excludes stack"))
    let coordinate = registeredIdentityCoordinateDigest identity
        canonicalIdentity =
          Text.concat
            ( map
                frame
                [ "aws-stack-creation/v1"
                , registryRevisionText lifecycleRegistryRevision
                , Text.pack (show surface)
                , registeredResourceKeyText key
                , managedResourceCoordinateDigestText coordinate
                , runScopeValue
                , foundationValue
                , account
                , region
                ]
            )
        submissionKey =
          "aws-stack-creation-v1-"
            <> TextEncoding.decodeUtf8
              (hexSha256 (TextEncoding.encodeUtf8 canonicalIdentity))
    Right
      AwsStackCreationAuthorityIdentity
        { internalAwsStackCreationSubmissionKey = submissionKey
        , internalAwsStackCreationKey = key
        , internalAwsStackCreationCoordinateDigest = coordinate
        , internalAwsStackCreationSurface = surface
        , internalAwsStackCreationRegistryRevision = lifecycleRegistryRevision
        , internalAwsStackCreationRunScope = runScope
        , internalAwsStackCreationFoundation = foundation
        , internalAwsStackCreationAwsScope = awsScope
        }

registeredStackForRef
  :: ProviderStackRef
  -> Either
       AwsStackCreationBindingError
       (RegisteredResourceKey, ManagedResourceCoordinateDigest)
registeredStackForRef ref =
  case [ (key, registeredIdentityCoordinateDigest identity)
       | key <- [minBound .. maxBound]
       , registeredResourceKeyText key == providerStackRefText ref
       , Just identity <- [lookupRegisteredIdentity key]
       , registeredIdentityKind identity == Stack
       ] of
    [entry] -> Right entry
    _ -> Left (AwsStackCreationStackUnregistered (providerStackRefText ref))

wireFromObserved
  :: AwsStackCreationAuthorityIdentity
  -> ObservedAwsStackCreationOperation
  -> AwsStackCreationWire
wireFromObserved identity observed =
  AwsStackCreationWire
    { creationWireVersion = 1
    , creationWireRegistryRevision = registryRevisionText lifecycleRegistryRevision
    , creationWireKey = fromEnum (awsStackCreationAuthorityKey identity)
    , creationWireCoordinateDigest =
        managedResourceCoordinateDigestText
          (awsStackCreationAuthorityCoordinateDigest identity)
    , creationWireSurface =
        fromEnum (awsStackCreationAuthoritySurface identity)
    , creationWireRunScope =
        durableRunScopeText (awsStackCreationAuthorityRunScope identity)
    , creationWireFoundation =
        foundationText (awsStackCreationAuthorityFoundation identity)
    , creationWireAwsAccount = awsAccountText scope
    , creationWireAwsRegion = awsRegionText scope
    , creationWireOperationEpoch =
        toInteger
          ( authorityEpochValue
              (operationIdEpoch (observedAwsStackCreationOperationId observed))
          )
    , creationWireOperationClient =
        clientIdText
          (operationIdClient (observedAwsStackCreationOperationId observed))
    , creationWireOperationSequence =
        toInteger
          ( clientSequenceNatural
              (operationIdSequence (observedAwsStackCreationOperationId observed))
          )
    , creationWireOperationDigest =
        requestDigestText
          (operationIdDigest (observedAwsStackCreationOperationId observed))
    , creationWireProviderRevision =
        toInteger (providerRevisionNatural (observedAwsStackCreationRevision observed))
    , creationWireProviderConfig =
        providerConfigToWire (observedAwsStackCreationConfig observed)
    }
 where
  scope = awsStackCreationAuthorityAwsScope identity

decodeAwsStackCreationBinding
  :: ByteString -> Either AwsStackCreationBindingError AwsStackCreationBinding
decodeAwsStackCreationBinding bytes = do
  when (ByteString.null bytes) (Left AwsStackCreationEmpty)
  when
    (ByteString.length bytes > maximumAwsStackCreationBindingBytes)
    ( Left
        ( AwsStackCreationTooLarge
            maximumAwsStackCreationBindingBytes
            (ByteString.length bytes)
        )
    )
  wire <-
    first
      (AwsStackCreationDecodeFailed . Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless (canonicalBytes wire == bytes) (Left AwsStackCreationNonCanonical)
  unless
    (creationWireVersion wire == 1)
    (Left (AwsStackCreationVersionUnsupported (creationWireVersion wire)))
  unless
    (creationWireRegistryRevision wire == registryRevisionText lifecycleRegistryRevision)
    (Left (AwsStackCreationFieldInvalid "registry revision mismatch"))
  key <- decodeBoundedKey (creationWireKey wire)
  surface <- decodeBoundedSurface (creationWireSurface wire)
  let awsScope =
        AwsScope
          (AwsAccountId (creationWireAwsAccount wire))
          (AwsRegion (creationWireAwsRegion wire))
  runScopeValue <- checkedText "durable run scope" 512 (creationWireRunScope wire)
  foundationValue <-
    checkedText "Linux RKE2 foundation" 512 (creationWireFoundation wire)
  let creationScope =
        mkObservationEvidenceScope
          surface
          lifecycleRegistryRevision
          (DurableObservationRunScope runScopeValue)
          (LinuxRke2FoundationId foundationValue)
          (Just awsScope)
          ReconcileDesiredPresent
  identity <- identityFor ReconcileDesiredPresent key creationScope
  unless
    ( creationWireCoordinateDigest wire
        == managedResourceCoordinateDigestText
          (awsStackCreationAuthorityCoordinateDigest identity)
    )
    (Left (AwsStackCreationFieldInvalid "registered coordinate mismatch"))
  operationId <- operationFromWire wire
  revisionNatural <- checkedNatural "provider revision" (creationWireProviderRevision wire)
  revision <- first AwsStackCreationFieldInvalid (mkProviderRevision revisionNatural)
  config <- providerConfigFromWire (creationWireProviderConfig wire)
  let refText = registeredResourceKeyText key
  ref <-
    first
      (AwsStackCreationFieldInvalid . Text.pack . show)
      (mkProviderStackRef refText)
  first
    (AwsStackCreationProviderConfigInvalid . Text.pack . show)
    (validateProviderStackConfig ref config)
  Right
    AwsStackCreationBinding
      { internalAwsStackCreationBindingIdentity = identity
      , internalAwsStackCreationBindingOperationId = operationId
      , internalAwsStackCreationBindingRevision = revision
      , internalAwsStackCreationBindingConfig = config
      , internalAwsStackCreationBindingBytes = bytes
      }

operationFromWire
  :: AwsStackCreationWire -> Either AwsStackCreationBindingError OperationId
operationFromWire wire = do
  epochNatural <- checkedNatural "operation epoch" (creationWireOperationEpoch wire)
  epoch <-
    maybe
      (Left (AwsStackCreationFieldInvalid "operation epoch must be positive"))
      Right
      (authorityEpochFromValue epochNatural)
  client <- checkedText "operation client" 256 (creationWireOperationClient wire)
  sequenceNumber <-
    checkedNatural "operation sequence" (creationWireOperationSequence wire)
  digest <- checkedDigest "operation digest" (creationWireOperationDigest wire)
  Right
    OperationId
      { operationIdEpoch = epoch
      , operationIdClient = ClientId client
      , operationIdSequence = ClientSequence sequenceNumber
      , operationIdDigest = RequestDigest digest
      }

confirmReadBack
  :: AwsStackCreationAuthorityIdentity
  -> AwsStackCreationReadBackObservation
  -> Either AwsStackCreationBindingError AwsStackCreationBinding
confirmReadBack expected observation = case observation of
  AwsStackCreationReadBackMissing ->
    Left AwsStackCreationConfirmationMissing
  AwsStackCreationReadBackCorrupt detail ->
    Left (AwsStackCreationConfirmationCorrupt detail)
  AwsStackCreationReadBackUnobservable failure ->
    Left (AwsStackCreationConfirmationUnobservable failure)
  AwsStackCreationReadBackUnbounded actual maximumBytes ->
    Left (AwsStackCreationConfirmationUnbounded actual maximumBytes)
  AwsStackCreationReadBackPresent bytes -> do
    binding <- decodeAwsStackCreationBinding bytes
    let actual = awsStackCreationBindingIdentity binding
    if actual == expected
      then Right binding
      else Left (AwsStackCreationIdentityMismatch expected actual)

validateCanonicalBytes
  :: ByteString -> Either AwsStackCreationBindingError ByteString
validateCanonicalBytes bytes = do
  _ <- decodeAwsStackCreationBinding bytes
  Right bytes

providerConfigToWire :: ProviderStackConfig -> ProviderConfigWire
providerConfigToWire config = case config of
  AwsEksProviderStackConfig operatorCidr -> AwsEksProviderConfigWire operatorCidr
  AwsTestProviderStackConfig operatorCidr -> AwsTestProviderConfigWire operatorCidr
  AwsEksSubzoneProviderStackConfig parentZone subzone ->
    AwsEksSubzoneProviderConfigWire parentZone subzone

providerConfigFromWire
  :: ProviderConfigWire -> Either AwsStackCreationBindingError ProviderStackConfig
providerConfigFromWire wire =
  first (AwsStackCreationProviderConfigInvalid . Text.pack . show) $ case wire of
    AwsEksProviderConfigWire operatorCidr ->
      mkAwsEksProviderStackConfig operatorCidr
    AwsTestProviderConfigWire operatorCidr ->
      mkAwsTestProviderStackConfig operatorCidr
    AwsEksSubzoneProviderConfigWire parentZone subzone ->
      mkAwsEksSubzoneProviderStackConfig parentZone subzone

decodeBoundedKey
  :: Int -> Either AwsStackCreationBindingError RegisteredResourceKey
decodeBoundedKey raw
  | raw < fromEnum (minBound :: RegisteredResourceKey)
      || raw > fromEnum (maxBound :: RegisteredResourceKey) =
      Left (AwsStackCreationFieldInvalid "registered key is outside the closed registry")
  | otherwise = Right (toEnum raw)

decodeBoundedSurface
  :: Int -> Either AwsStackCreationBindingError CleanupSurface
decodeBoundedSurface raw
  | raw < fromEnum (minBound :: CleanupSurface)
      || raw > fromEnum (maxBound :: CleanupSurface) =
      Left (AwsStackCreationFieldInvalid "cleanup surface is outside the closed enum")
  | otherwise = Right (toEnum raw)

validateAwsAccount :: Text -> Either AwsStackCreationBindingError ()
validateAwsAccount value
  | Text.length value == 12 && Text.all isDigit value = Right ()
  | otherwise = Left (AwsStackCreationAwsAccountInvalid value)

validateAwsRegion :: Text -> Either AwsStackCreationBindingError ()
validateAwsRegion value
  | Text.null value
      || Text.length value > 128
      || Text.any (\character -> not (isAscii character) || isControl character || isSpace character) value =
      Left (AwsStackCreationAwsRegionInvalid value)
  | otherwise = Right ()

checkedNatural
  :: Text -> Integer -> Either AwsStackCreationBindingError Natural
checkedNatural label value
  | value < 0 = Left (AwsStackCreationFieldInvalid (label <> " was negative"))
  | otherwise = Right (fromInteger value)

checkedText
  :: Text -> Int -> Text -> Either AwsStackCreationBindingError Text
checkedText label maximumLength value
  | Text.null value = invalid "was empty"
  | Text.length value > maximumLength = invalid "was too long"
  | Text.any (\character -> not (isAscii character) || isControl character) value =
      invalid "contained a non-printable character"
  | otherwise = Right value
 where
  invalid detail = Left (AwsStackCreationFieldInvalid (label <> " " <> detail))

checkedDigest
  :: Text -> Text -> Either AwsStackCreationBindingError Text
checkedDigest label value
  | Text.length value == 64 && Text.all isLowerHex value = Right value
  | otherwise =
      Left
        ( AwsStackCreationFieldInvalid
            (label <> " was not a canonical SHA-256 digest")
        )
 where
  isLowerHex character =
    isDigit character || (character >= 'a' && character <= 'f')

canonicalBytes :: AwsStackCreationWire -> ByteString
canonicalBytes = LazyByteString.toStrict . serialise

durableRunScopeText :: DurableObservationRunScope -> Text
durableRunScopeText (DurableObservationRunScope value) = value

foundationText :: LinuxRke2FoundationId -> Text
foundationText (LinuxRke2FoundationId value) = value

existingDisposition
  :: AwsStackCreationBinding -> ByteString -> AwsStackCreationCommitResult
existingDisposition candidate existing
  | existing == awsStackCreationBindingBytes candidate =
      AwsStackCreationCommitExactReplay
  | otherwise = AwsStackCreationCommitConflict

conflictDisposition
  :: AwsStackCreationBinding
  -> ModelBObservation ByteString
  -> AwsStackCreationCommitResult
conflictDisposition candidate observation = case observation of
  ModelBObserved _ existing -> existingDisposition candidate existing
  ModelBMissing -> AwsStackCreationCommitConflict
  ModelBCorrupt detail ->
    AwsStackCreationCommitUnavailable
      (repositoryFailure "cas-conflict-corrupt" detail)
  ModelBEndpointUnready detail ->
    AwsStackCreationCommitUnavailable
      (repositoryFailure "cas-conflict-endpoint-unready" detail)
  ModelBUnobservable detail ->
    AwsStackCreationCommitResponseLost
      (repositoryFailure "cas-conflict-unobservable" detail)

repositoryFailure :: Text -> Text -> ObservationFailure
repositoryFailure category detail =
  ObservationFailure
    (Text.take 1024 ("AWS stack creation repository " <> category <> ": " <> detail))

frame :: Text -> Text
frame value = Text.pack (show (Text.length value)) <> ":" <> value

registryRevisionText :: RegistryRevision -> Text
registryRevisionText (RegistryRevision value) = value

awsAccountText :: AwsScope -> Text
awsAccountText (AwsScope (AwsAccountId value) _) = value

awsRegionText :: AwsScope -> Text
awsRegionText (AwsScope _ (AwsRegion value)) = value

clientIdText :: ClientId -> Text
clientIdText (ClientId value) = value

clientSequenceNatural :: ClientSequence -> Natural
clientSequenceNatural (ClientSequence value) = value
