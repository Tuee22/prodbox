{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Lifecycle-Authority Model-B persistence for write-ahead ownership
-- manifests.  A write is committed before a registered create; a separate
-- read reopens canonical bytes and only then asks the ownership-manifest
-- boundary to mint cleanup decision evidence.
--
-- The logical slot includes the durable lifecycle generation but excludes the
-- present/absent operation.  An exact generation therefore survives restart
-- and can be read during cleanup, while a later generation receives a new
-- immutable slot rather than conflicting with stale state.
module Prodbox.ControlPlane.OwnershipManifestRepository
  ( OwnershipManifestAuthorityIdentity
  , ownershipManifestAuthoritySubmissionKey
  , ownershipManifestAuthorityStackKey
  , ownershipManifestAuthorityCoordinateDigest
  , ownershipManifestAuthoritySurface
  , ownershipManifestAuthorityRunScope
  , ownershipManifestAuthorityFoundation
  , ownershipManifestAuthorityAwsScope
  , ownershipManifestAuthorityLogicalName
  , encodeOwnershipManifestAuthorityIdentity
  , decodeOwnershipManifestAuthorityIdentity
  , maximumOwnershipManifestAuthorityIdentityBytes
  , AuthorityOwnershipManifestWrite
  , prepareAuthorityOwnershipManifestWrite
  , confirmAuthorityOwnershipManifestWriteBytes
  , authorityOwnershipManifestWriteIdentity
  , authorityOwnershipManifestWriteBytes
  , OwnershipManifestCommitResult (..)
  , OwnershipManifestAuthorityReadBack (..)
  , OwnershipManifestRepository (..)
  , ownershipManifestModelBCodec
  , modelBOwnershipManifestRepository
  , commitOwnershipManifestWriteAheadAttempt
  , independentlyReadBackOwnershipManifestDecisionEvidence
  , confirmOwnershipManifestDecisionReadBack
  , OwnershipManifestClient (..)
  , lifecycleAuthorityOwnershipManifestClient
  , OwnershipManifestRepositoryError (..)
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAscii, isControl, isDigit, isSpace)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (ModelBInitialize)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , modelBObjectVersionText
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
  ( OwnershipManifestObservation (..)
  , OwnershipManifestProvenance (..)
  , OwnershipManifestResult (..)
  , OwnershipManifestVersion (..)
  )
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( DurableWriteAheadOwnershipManifestError
  , OwnershipManifestDecisionEvidence
  , OwnershipManifestPurpose (WriteAheadOwnership)
  , OwnershipManifestTarget
  , OwnershipManifestWrite
  , captureDurableWriteAheadOwnershipManifest
  , durableWriteAheadOwnershipManifestBytes
  , durableWriteAheadOwnershipManifestScope
  , durableWriteAheadOwnershipManifestStackKey
  , maximumDurableWriteAheadOwnershipManifestBytes
  , ownershipManifestObservationOnly
  , ownershipManifestTargetScope
  , ownershipManifestTargetStackKey
  )
import Prodbox.Lifecycle.Teardown.OwnershipManifest.Internal
  ( decodeDurableWriteAheadOwnershipManifest
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( cleanupSurfaceAllows
  , lifecycleRegistryRevision
  , lookupRegisteredIdentity
  , registeredIdentityCoordinateDigest
  , registeredIdentityKind
  )

data OwnershipManifestAuthorityIdentity = OwnershipManifestAuthorityIdentity
  { internalOwnershipManifestAuthoritySubmissionKey :: !Text
  , internalOwnershipManifestAuthorityStackKey :: !RegisteredResourceKey
  , internalOwnershipManifestAuthorityCoordinateDigest
      :: !ManagedResourceCoordinateDigest
  , internalOwnershipManifestAuthoritySurface :: !CleanupSurface
  , internalOwnershipManifestAuthorityRunScope :: !DurableObservationRunScope
  , internalOwnershipManifestAuthorityFoundation :: !LinuxRke2FoundationId
  , internalOwnershipManifestAuthorityAwsScope :: !AwsScope
  }
  deriving stock (Eq, Show)

ownershipManifestAuthoritySubmissionKey
  :: OwnershipManifestAuthorityIdentity -> Text
ownershipManifestAuthoritySubmissionKey =
  internalOwnershipManifestAuthoritySubmissionKey

ownershipManifestAuthorityStackKey
  :: OwnershipManifestAuthorityIdentity -> RegisteredResourceKey
ownershipManifestAuthorityStackKey = internalOwnershipManifestAuthorityStackKey

ownershipManifestAuthorityCoordinateDigest
  :: OwnershipManifestAuthorityIdentity -> ManagedResourceCoordinateDigest
ownershipManifestAuthorityCoordinateDigest =
  internalOwnershipManifestAuthorityCoordinateDigest

ownershipManifestAuthoritySurface
  :: OwnershipManifestAuthorityIdentity -> CleanupSurface
ownershipManifestAuthoritySurface = internalOwnershipManifestAuthoritySurface

ownershipManifestAuthorityRunScope
  :: OwnershipManifestAuthorityIdentity -> DurableObservationRunScope
ownershipManifestAuthorityRunScope =
  internalOwnershipManifestAuthorityRunScope

ownershipManifestAuthorityFoundation
  :: OwnershipManifestAuthorityIdentity -> LinuxRke2FoundationId
ownershipManifestAuthorityFoundation =
  internalOwnershipManifestAuthorityFoundation

ownershipManifestAuthorityAwsScope
  :: OwnershipManifestAuthorityIdentity -> AwsScope
ownershipManifestAuthorityAwsScope = internalOwnershipManifestAuthorityAwsScope

ownershipManifestAuthorityLogicalName
  :: OwnershipManifestAuthorityIdentity -> Text
ownershipManifestAuthorityLogicalName identity =
  "authority/ownership-manifests/"
    <> ownershipManifestAuthoritySubmissionKey identity

data OwnershipManifestIdentityWire = OwnershipManifestIdentityWire
  { manifestIdentityWireVersion :: !Int
  , manifestIdentityWireRegistryRevision :: !Text
  , manifestIdentityWireStackKey :: !Int
  , manifestIdentityWireCoordinateDigest :: !Text
  , manifestIdentityWireSurface :: !Int
  , manifestIdentityWireRunScope :: !Text
  , manifestIdentityWireFoundation :: !Text
  , manifestIdentityWireAwsAccount :: !Text
  , manifestIdentityWireAwsRegion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

maximumOwnershipManifestAuthorityIdentityBytes :: Int
maximumOwnershipManifestAuthorityIdentityBytes = 16 * 1024

encodeOwnershipManifestAuthorityIdentity
  :: OwnershipManifestAuthorityIdentity -> ByteString
encodeOwnershipManifestAuthorityIdentity =
  LazyByteString.toStrict . serialise . ownershipManifestIdentityToWire

decodeOwnershipManifestAuthorityIdentity
  :: ByteString
  -> Either OwnershipManifestRepositoryError OwnershipManifestAuthorityIdentity
decodeOwnershipManifestAuthorityIdentity bytes = do
  when
    (ByteString.null bytes)
    (Left (OwnershipManifestRepositoryIdentityInvalid "identity was empty"))
  when
    (ByteString.length bytes > maximumOwnershipManifestAuthorityIdentityBytes)
    ( Left
        ( OwnershipManifestRepositoryIdentityInvalid
            "identity exceeded the canonical byte bound"
        )
    )
  wire <-
    first
      ( OwnershipManifestRepositoryIdentityInvalid
          . ("identity decode failed: " <>)
          . Text.pack
          . show
      )
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (LazyByteString.toStrict (serialise wire) == bytes)
    ( Left
        ( OwnershipManifestRepositoryIdentityInvalid
            "identity encoding was non-canonical"
        )
    )
  unless
    (manifestIdentityWireVersion wire == 1)
    ( Left
        ( OwnershipManifestRepositoryIdentityInvalid
            "identity version was unsupported"
        )
    )
  unless
    ( manifestIdentityWireRegistryRevision wire
        == registryRevisionText lifecycleRegistryRevision
    )
    ( Left
        ( OwnershipManifestRepositoryIdentityInvalid
            "registry revision mismatch"
        )
    )
  key <- decodeIdentityStackKey (manifestIdentityWireStackKey wire)
  surface <- decodeIdentitySurface (manifestIdentityWireSurface wire)
  let scope =
        mkObservationEvidenceScope
          surface
          lifecycleRegistryRevision
          ( DurableObservationRunScope
              (manifestIdentityWireRunScope wire)
          )
          ( LinuxRke2FoundationId
              (manifestIdentityWireFoundation wire)
          )
          ( Just
              ( AwsScope
                  (AwsAccountId (manifestIdentityWireAwsAccount wire))
                  (AwsRegion (manifestIdentityWireAwsRegion wire))
              )
          )
          ReconcileDesiredPresent
  identity <- identityFor key scope
  unless
    ( manifestIdentityWireCoordinateDigest wire
        == managedResourceCoordinateDigestText
          (ownershipManifestAuthorityCoordinateDigest identity)
    )
    ( Left
        ( OwnershipManifestRepositoryIdentityInvalid
            "registered coordinate digest mismatch"
        )
    )
  Right identity

ownershipManifestIdentityToWire
  :: OwnershipManifestAuthorityIdentity -> OwnershipManifestIdentityWire
ownershipManifestIdentityToWire identity =
  OwnershipManifestIdentityWire
    { manifestIdentityWireVersion = 1
    , manifestIdentityWireRegistryRevision =
        registryRevisionText lifecycleRegistryRevision
    , manifestIdentityWireStackKey =
        fromEnum (ownershipManifestAuthorityStackKey identity)
    , manifestIdentityWireCoordinateDigest =
        managedResourceCoordinateDigestText
          (ownershipManifestAuthorityCoordinateDigest identity)
    , manifestIdentityWireSurface =
        fromEnum (ownershipManifestAuthoritySurface identity)
    , manifestIdentityWireRunScope =
        runScopeText (ownershipManifestAuthorityRunScope identity)
    , manifestIdentityWireFoundation =
        foundationText (ownershipManifestAuthorityFoundation identity)
    , manifestIdentityWireAwsAccount =
        accountText (ownershipManifestAuthorityAwsScope identity)
    , manifestIdentityWireAwsRegion =
        regionText (ownershipManifestAuthorityAwsScope identity)
    }

data AuthorityOwnershipManifestWrite = AuthorityOwnershipManifestWrite
  { internalAuthorityOwnershipManifestWriteIdentity
      :: !OwnershipManifestAuthorityIdentity
  , internalAuthorityOwnershipManifestWriteBytes :: !ByteString
  }

instance Eq AuthorityOwnershipManifestWrite where
  left == right =
    authorityOwnershipManifestWriteBytes left
      == authorityOwnershipManifestWriteBytes right

instance Show AuthorityOwnershipManifestWrite where
  show write =
    "<authority-ownership-manifest-write:"
      <> show
        ( ownershipManifestAuthorityStackKey
            (authorityOwnershipManifestWriteIdentity write)
        )
      <> ">"

authorityOwnershipManifestWriteIdentity
  :: AuthorityOwnershipManifestWrite -> OwnershipManifestAuthorityIdentity
authorityOwnershipManifestWriteIdentity =
  internalAuthorityOwnershipManifestWriteIdentity

authorityOwnershipManifestWriteBytes
  :: AuthorityOwnershipManifestWrite -> ByteString
authorityOwnershipManifestWriteBytes =
  internalAuthorityOwnershipManifestWriteBytes

data OwnershipManifestCommitResult
  = OwnershipManifestCommitCreated
  | OwnershipManifestCommitExactReplay
  | OwnershipManifestCommitConflict
  | OwnershipManifestCommitResponseLost !ObservationFailure
  | OwnershipManifestCommitUnavailable !ObservationFailure
  deriving stock (Eq, Show)

data OwnershipManifestAuthorityReadBack
  = OwnershipManifestAuthorityReadBackPresent !ModelBObjectVersion !ByteString
  | OwnershipManifestAuthorityReadBackMissing
  | OwnershipManifestAuthorityReadBackPartial !(NonEmpty ObservationFailure)
  | OwnershipManifestAuthorityReadBackCorrupt !Text
  | OwnershipManifestAuthorityReadBackUnobservable !ObservationFailure
  | OwnershipManifestAuthorityReadBackUnbounded !Int !Int
  deriving stock (Eq, Show)

data OwnershipManifestRepository m = OwnershipManifestRepository
  { createOrReplayOwnershipManifest
      :: AuthorityOwnershipManifestWrite -> m OwnershipManifestCommitResult
  , independentlyReadBackOwnershipManifest
      :: OwnershipManifestAuthorityIdentity
      -> m OwnershipManifestAuthorityReadBack
  }

data OwnershipManifestRepositoryError
  = OwnershipManifestRepositoryDurabilityInvalid
      !DurableWriteAheadOwnershipManifestError
  | OwnershipManifestRepositoryIdentityInvalid !Text
  | OwnershipManifestRepositoryMissing
  | OwnershipManifestRepositoryCorrupt !Text
  | OwnershipManifestRepositoryUnobservable !ObservationFailure
  | OwnershipManifestRepositoryUnbounded !Int !Int
  | OwnershipManifestRepositoryIdentityMismatch
      !OwnershipManifestAuthorityIdentity
      !OwnershipManifestAuthorityIdentity
  deriving stock (Eq, Show)

prepareAuthorityOwnershipManifestWrite
  :: OwnershipManifestWrite 'WriteAheadOwnership surface
  -> Either OwnershipManifestRepositoryError AuthorityOwnershipManifestWrite
prepareAuthorityOwnershipManifestWrite write = do
  durable <-
    first
      OwnershipManifestRepositoryDurabilityInvalid
      (captureDurableWriteAheadOwnershipManifest write)
  identity <-
    identityFor
      (durableWriteAheadOwnershipManifestStackKey durable)
      (durableWriteAheadOwnershipManifestScope durable)
  Right
    AuthorityOwnershipManifestWrite
      { internalAuthorityOwnershipManifestWriteIdentity = identity
      , internalAuthorityOwnershipManifestWriteBytes =
          durableWriteAheadOwnershipManifestBytes durable
      }

confirmAuthorityOwnershipManifestWriteBytes
  :: OwnershipManifestAuthorityIdentity
  -> ByteString
  -> Either OwnershipManifestRepositoryError AuthorityOwnershipManifestWrite
confirmAuthorityOwnershipManifestWriteBytes expected bytes = do
  durable <-
    first
      OwnershipManifestRepositoryDurabilityInvalid
      (decodeDurableWriteAheadOwnershipManifest bytes)
  actual <-
    identityFor
      (durableWriteAheadOwnershipManifestStackKey durable)
      (durableWriteAheadOwnershipManifestScope durable)
  unless
    (actual == expected)
    ( Left
        ( OwnershipManifestRepositoryIdentityMismatch
            expected
            actual
        )
    )
  Right
    AuthorityOwnershipManifestWrite
      { internalAuthorityOwnershipManifestWriteIdentity = actual
      , internalAuthorityOwnershipManifestWriteBytes = bytes
      }

data OwnershipManifestClient m = OwnershipManifestClient
  { attemptOwnershipManifestWriteAheadCommit
      :: forall surface
       . OwnershipManifestWrite 'WriteAheadOwnership surface
      -> m
           ( Either
               OwnershipManifestRepositoryError
               OwnershipManifestCommitResult
           )
  , readBackOwnershipManifestDecisionByIdentity
      :: forall surface
       . OwnershipManifestTarget surface
      -> OwnershipManifestAuthorityIdentity
      -> m
           ( Either
               OwnershipManifestRepositoryError
               OwnershipManifestDecisionEvidence
           )
  }

commitOwnershipManifestWriteAheadAttempt
  :: (Monad m)
  => OwnershipManifestRepository m
  -> OwnershipManifestWrite 'WriteAheadOwnership surface
  -> m (Either OwnershipManifestRepositoryError OwnershipManifestCommitResult)
commitOwnershipManifestWriteAheadAttempt repository write =
  case prepareAuthorityOwnershipManifestWrite write of
    Left err -> pure (Left err)
    Right candidate ->
      Right <$> createOrReplayOwnershipManifest repository candidate

independentlyReadBackOwnershipManifestDecisionEvidence
  :: (Monad m)
  => OwnershipManifestRepository m
  -> OwnershipManifestTarget surface
  -> m (Either OwnershipManifestRepositoryError OwnershipManifestDecisionEvidence)
independentlyReadBackOwnershipManifestDecisionEvidence repository target =
  case identityFor (ownershipManifestTargetStackKey target) targetScope of
    Left err -> pure (Left err)
    Right expected -> do
      observed <- independentlyReadBackOwnershipManifest repository expected
      pure (confirmOwnershipManifestDecisionReadBack target expected observed)
 where
  targetScope = ownershipManifestTargetScope target

confirmOwnershipManifestDecisionReadBack
  :: OwnershipManifestTarget surface
  -> OwnershipManifestAuthorityIdentity
  -> OwnershipManifestAuthorityReadBack
  -> Either OwnershipManifestRepositoryError OwnershipManifestDecisionEvidence
confirmOwnershipManifestDecisionReadBack target expected observation = do
  targetIdentity <-
    identityFor
      (ownershipManifestTargetStackKey target)
      targetScope
  unless
    (targetIdentity == expected)
    ( Left
        ( OwnershipManifestRepositoryIdentityMismatch
            expected
            targetIdentity
        )
    )
  decisionFromReadBack observation
 where
  targetScope = ownershipManifestTargetScope target

  decisionFromReadBack readBack = case readBack of
    OwnershipManifestAuthorityReadBackMissing ->
      Right (observationOnly OwnershipManifestAbsent)
    OwnershipManifestAuthorityReadBackPartial failures ->
      Right
        ( observationOnly
            (OwnershipManifestPartial (fmap boundedObservationFailure failures))
        )
    OwnershipManifestAuthorityReadBackCorrupt detail ->
      Right (unobservable "corrupt" detail)
    OwnershipManifestAuthorityReadBackUnobservable (ObservationFailure detail) ->
      Right (unobservable "unobservable" detail)
    OwnershipManifestAuthorityReadBackUnbounded actual maximumBytes ->
      Right
        ( unobservable
            "unbounded"
            ( Text.pack (show actual)
                <> " bytes exceeded "
                <> Text.pack (show maximumBytes)
            )
        )
    OwnershipManifestAuthorityReadBackPresent version bytes ->
      case decodeDurableWriteAheadOwnershipManifest bytes of
        Left err -> Right (unobservable "invalid canonical payload" (Text.pack (show err)))
        Right durable -> case identityFor
          (durableWriteAheadOwnershipManifestStackKey durable)
          (durableWriteAheadOwnershipManifestScope durable) of
          Left err ->
            Right (unobservable "invalid payload identity" (Text.pack (show err)))
          Right actual
            | actual /= expected ->
                Left
                  ( OwnershipManifestRepositoryIdentityMismatch
                      expected
                      actual
                  )
            | otherwise ->
                Right
                  ( observationOnly
                      ( OwnershipManifestPresent
                          (OwnershipManifestVersion (modelBObjectVersionText version))
                      )
                  )

  observationOnly result =
    ownershipManifestObservationOnly
      OwnershipManifestObservation
        { ownershipManifestStackKey = ownershipManifestTargetStackKey target
        , ownershipManifestProvenance =
            OwnershipManifestProvenance authorityProvenance
        , ownershipManifestEvidenceScope = targetScope
        , ownershipManifestResult = result
        }

  unobservable category detail =
    observationOnly
      ( OwnershipManifestUnobservable
          ( repositoryFailure category detail
              :| []
          )
      )

lifecycleAuthorityOwnershipManifestClient
  :: (Monad m)
  => OwnershipManifestRepository m
  -> OwnershipManifestClient m
lifecycleAuthorityOwnershipManifestClient repository =
  OwnershipManifestClient
    { attemptOwnershipManifestWriteAheadCommit =
        commitOwnershipManifestWriteAheadAttempt repository
    , readBackOwnershipManifestDecisionByIdentity = readBack
    }
 where
  readBack target expected = do
    observed <- independentlyReadBackOwnershipManifest repository expected
    pure (confirmOwnershipManifestDecisionReadBack target expected observed)

ownershipManifestModelBCodec :: ModelBCodec ByteString
ownershipManifestModelBCodec =
  ModelBCodec
    { encodeModelBValue = first show . validateCanonicalBytes
    , decodeModelBValue = first show . validateCanonicalBytes
    }

modelBOwnershipManifestRepository
  :: (Monad m)
  => LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> OwnershipManifestRepository m
modelBOwnershipManifestRepository authority adapter =
  OwnershipManifestRepository
    { createOrReplayOwnershipManifest = createOrReplay
    , independentlyReadBackOwnershipManifest = readBack
    }
 where
  createOrReplay write =
    case coordinateFor (authorityOwnershipManifestWriteIdentity write) of
      Left failure -> pure (OwnershipManifestCommitUnavailable failure)
      Right coordinate -> do
        observed <- modelBObserve adapter coordinate
        case observed of
          ModelBMissing -> initialize coordinate write
          ModelBObserved _ existing -> pure (existingDisposition write existing)
          ModelBCorrupt detail -> pure (unavailable "corrupt" detail)
          ModelBEndpointUnready detail -> pure (unavailable "endpoint-unready" detail)
          ModelBUnobservable detail -> pure (unavailable "unobservable" detail)

  initialize coordinate write = do
    result <-
      modelBCompareAndSwap
        adapter
        (ModelBInitialize coordinate (authorityOwnershipManifestWriteBytes write))
    pure $ case result of
      ModelBCasApplied _ applied
        | applied == authorityOwnershipManifestWriteBytes write ->
            OwnershipManifestCommitCreated
        | otherwise -> OwnershipManifestCommitConflict
      ModelBCasConflict observation -> conflictDisposition write observation
      ModelBCasRefusedCorrupt detail -> unavailable "cas-corrupt" detail
      ModelBCasEndpointUnready detail -> unavailable "cas-endpoint-unready" detail
      ModelBCasUnobservable detail ->
        OwnershipManifestCommitResponseLost
          (repositoryFailure "cas-response-unobservable" detail)

  readBack identity = case coordinateFor identity of
    Left failure -> pure (OwnershipManifestAuthorityReadBackUnobservable failure)
    Right coordinate -> do
      observed <- modelBObserve adapter coordinate
      pure $ case observed of
        ModelBMissing -> OwnershipManifestAuthorityReadBackMissing
        ModelBObserved version bytes
          | ByteString.length bytes
              > maximumDurableWriteAheadOwnershipManifestBytes ->
              OwnershipManifestAuthorityReadBackUnbounded
                (ByteString.length bytes)
                maximumDurableWriteAheadOwnershipManifestBytes
          | otherwise ->
              OwnershipManifestAuthorityReadBackPresent version bytes
        ModelBCorrupt detail -> OwnershipManifestAuthorityReadBackCorrupt detail
        ModelBEndpointUnready detail -> unobservable "endpoint-unready" detail
        ModelBUnobservable detail -> unobservable "unobservable" detail

  coordinateFor identity =
    first
      (repositoryFailure "coordinate" . Text.pack . show)
      ( mkClusterRetainedCoordinate
          authority
          (ownershipManifestAuthorityLogicalName identity)
      )
  unavailable category detail =
    OwnershipManifestCommitUnavailable (repositoryFailure category detail)
  unobservable category detail =
    OwnershipManifestAuthorityReadBackUnobservable
      (repositoryFailure category detail)

identityFor
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> Either OwnershipManifestRepositoryError OwnershipManifestAuthorityIdentity
identityFor key scope = do
  identity <-
    maybe
      (Left (OwnershipManifestRepositoryIdentityInvalid "stack is unregistered"))
      Right
      (lookupRegisteredIdentity key)
  unless
    (registeredIdentityKind identity == Stack)
    (Left (OwnershipManifestRepositoryIdentityInvalid "resource is not a stack"))
  unless
    (cleanupSurfaceAllows (evidenceCleanupSurface scope) identity)
    (Left (OwnershipManifestRepositoryIdentityInvalid "surface excludes stack"))
  unless
    (evidenceRegistryRevision scope == lifecycleRegistryRevision)
    (Left (OwnershipManifestRepositoryIdentityInvalid "registry revision mismatch"))
  awsScope <-
    maybe
      (Left (OwnershipManifestRepositoryIdentityInvalid "AWS scope is missing"))
      Right
      (evidenceAwsScope scope)
  validateIdentityText
    "durable run scope"
    512
    (runScopeText (evidenceDurableRunScope scope))
  validateIdentityText
    "Linux RKE2 foundation"
    512
    (foundationText (evidenceLinuxRke2Foundation scope))
  validateAwsScope awsScope
  let coordinate = registeredIdentityCoordinateDigest identity
      runScope = evidenceDurableRunScope scope
      foundation = evidenceLinuxRke2Foundation scope
      surface = evidenceCleanupSurface scope
      canonicalIdentity =
        Text.concat
          ( map
              frame
              [ "ownership-manifest/v1"
              , registryRevisionText (evidenceRegistryRevision scope)
              , Text.pack (show surface)
              , registeredResourceKeyText key
              , managedResourceCoordinateDigestText coordinate
              , runScopeText runScope
              , foundationText foundation
              , accountText awsScope
              , regionText awsScope
              ]
          )
      submissionKey =
        "ownership-manifest-v1-"
          <> TextEncoding.decodeUtf8
            (hexSha256 (TextEncoding.encodeUtf8 canonicalIdentity))
  Right
    OwnershipManifestAuthorityIdentity
      { internalOwnershipManifestAuthoritySubmissionKey = submissionKey
      , internalOwnershipManifestAuthorityStackKey = key
      , internalOwnershipManifestAuthorityCoordinateDigest = coordinate
      , internalOwnershipManifestAuthoritySurface = surface
      , internalOwnershipManifestAuthorityRunScope = runScope
      , internalOwnershipManifestAuthorityFoundation = foundation
      , internalOwnershipManifestAuthorityAwsScope = awsScope
      }

validateCanonicalBytes
  :: ByteString
  -> Either DurableWriteAheadOwnershipManifestError ByteString
validateCanonicalBytes bytes = do
  _ <- decodeDurableWriteAheadOwnershipManifest bytes
  Right bytes

existingDisposition
  :: AuthorityOwnershipManifestWrite
  -> ByteString
  -> OwnershipManifestCommitResult
existingDisposition candidate existing
  | existing == authorityOwnershipManifestWriteBytes candidate =
      OwnershipManifestCommitExactReplay
  | otherwise = OwnershipManifestCommitConflict

conflictDisposition
  :: AuthorityOwnershipManifestWrite
  -> ModelBObservation ByteString
  -> OwnershipManifestCommitResult
conflictDisposition candidate observation = case observation of
  ModelBObserved _ existing -> existingDisposition candidate existing
  ModelBMissing -> OwnershipManifestCommitConflict
  ModelBCorrupt detail ->
    OwnershipManifestCommitUnavailable
      (repositoryFailure "cas-conflict-corrupt" detail)
  ModelBEndpointUnready detail ->
    OwnershipManifestCommitUnavailable
      (repositoryFailure "cas-conflict-endpoint-unready" detail)
  ModelBUnobservable detail ->
    OwnershipManifestCommitResponseLost
      (repositoryFailure "cas-conflict-unobservable" detail)

repositoryFailure :: Text -> Text -> ObservationFailure
repositoryFailure category detail =
  ObservationFailure
    (Text.take 1024 ("ownership manifest repository " <> category <> ": " <> detail))

boundedObservationFailure :: ObservationFailure -> ObservationFailure
boundedObservationFailure (ObservationFailure detail) =
  ObservationFailure (Text.take 1024 detail)

authorityProvenance :: Text
authorityProvenance = "lifecycle-authority/model-b/write-ahead/v1"

validateAwsScope
  :: AwsScope -> Either OwnershipManifestRepositoryError ()
validateAwsScope
  (AwsScope (AwsAccountId account) (AwsRegion region)) = do
    unless
      (Text.length account == 12 && Text.all isDigit account)
      (Left (OwnershipManifestRepositoryIdentityInvalid "AWS account is invalid"))
    unless
      ( not (Text.null region)
          && Text.length region <= 128
          && Text.all
            (\character -> isAscii character && not (isControl character || isSpace character))
            region
      )
      (Left (OwnershipManifestRepositoryIdentityInvalid "AWS region is invalid"))

validateIdentityText
  :: Text -> Int -> Text -> Either OwnershipManifestRepositoryError ()
validateIdentityText label maximumLength value =
  unless
    ( not (Text.null value)
        && Text.length value <= maximumLength
        && Text.all (\character -> isAscii character && not (isControl character)) value
    )
    (Left (OwnershipManifestRepositoryIdentityInvalid (label <> " is invalid")))

decodeIdentityStackKey
  :: Int -> Either OwnershipManifestRepositoryError RegisteredResourceKey
decodeIdentityStackKey raw
  | raw < fromEnum (minBound :: RegisteredResourceKey)
      || raw > fromEnum (maxBound :: RegisteredResourceKey) =
      Left
        ( OwnershipManifestRepositoryIdentityInvalid
            "registered stack key was outside the closed registry"
        )
  | otherwise = Right (toEnum raw)

decodeIdentitySurface
  :: Int -> Either OwnershipManifestRepositoryError CleanupSurface
decodeIdentitySurface raw
  | raw < fromEnum (minBound :: CleanupSurface)
      || raw > fromEnum (maxBound :: CleanupSurface) =
      Left
        ( OwnershipManifestRepositoryIdentityInvalid
            "cleanup surface was outside the closed enum"
        )
  | otherwise = Right (toEnum raw)

frame :: Text -> Text
frame value = Text.pack (show (Text.length value)) <> ":" <> value

registryRevisionText :: RegistryRevision -> Text
registryRevisionText (RegistryRevision value) = value

foundationText :: LinuxRke2FoundationId -> Text
foundationText (LinuxRke2FoundationId value) = value

runScopeText :: DurableObservationRunScope -> Text
runScopeText (DurableObservationRunScope value) = value

accountText :: AwsScope -> Text
accountText (AwsScope (AwsAccountId value) _) = value

regionText :: AwsScope -> Text
regionText (AwsScope _ (AwsRegion value)) = value
