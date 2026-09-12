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
  , readBackOwnershipManifestDecisionForScope
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
  , OwnershipManifestError
  , OwnershipManifestPurpose (WriteAheadOwnership)
  , OwnershipManifestTarget
  , OwnershipManifestWrite
  , captureDurableWriteAheadOwnershipManifest
  , durableWriteAheadOwnershipManifestBytes
  , durableWriteAheadOwnershipManifestScope
  , durableWriteAheadOwnershipManifestStackKey
  , maximumDurableWriteAheadOwnershipManifestBytes
  , mkOwnershipManifestTarget
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
import Prodbox.Lifecycle.Teardown.ScopeCodec
  ( ObservationEvidenceScopeFields (..)
  , ScopeWire
  , observationEvidenceScopeFields
  , observationEvidenceScopeFromFields
  , renderScopeWireError
  , scopeFromWire
  , scopeIdentityFields
  , scopeToWire
  )

-- | The authority identity of one write-ahead ownership-manifest slot.
--
-- Sprint 4.92: this record used to keep four hand-picked projections of the
-- run's scope — surface, durable run scope, foundation, AWS scope — and what
-- that list left out was the run's retained DNS hosted zone.  Two runs that
-- differed only in the zone they were compiled against therefore minted the
-- same submission key, and so claimed the same immutable object, for manifests
-- describing different DNS records.  The whole scope is kept instead, so the
-- derived 'Eq' and the submission key both move when any scope field moves and
-- a field added to the scope later cannot be quietly left out of identity.
--
-- The scope kept here is the /slot/ scope of 'ownershipManifestSlotScope': the
-- present\/absent operation is normalised away, because the logical slot
-- excludes it by design and the derived 'Eq' has to stay blind to it for the
-- same reason.  The AWS scope stays a field of its own rather than being read
-- back out of the scope, because it is the refined value 'identityFor' proved
-- present; it is projected from the same scope, so the two cannot disagree.
data OwnershipManifestAuthorityIdentity = OwnershipManifestAuthorityIdentity
  { internalOwnershipManifestAuthoritySubmissionKey :: !Text
  , internalOwnershipManifestAuthorityStackKey :: !RegisteredResourceKey
  , internalOwnershipManifestAuthorityCoordinateDigest
      :: !ManagedResourceCoordinateDigest
  , internalOwnershipManifestAuthorityScope :: !ObservationEvidenceScope
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

-- | The three scope projections this module publishes are now read out of the
-- stored scope rather than out of fields copied beside it, so no caller can
-- observe a projection that the scope itself no longer agrees with.
ownershipManifestAuthoritySurface
  :: OwnershipManifestAuthorityIdentity -> CleanupSurface
ownershipManifestAuthoritySurface =
  evidenceCleanupSurface . internalOwnershipManifestAuthorityScope

ownershipManifestAuthorityRunScope
  :: OwnershipManifestAuthorityIdentity -> DurableObservationRunScope
ownershipManifestAuthorityRunScope =
  evidenceDurableRunScope . internalOwnershipManifestAuthorityScope

ownershipManifestAuthorityFoundation
  :: OwnershipManifestAuthorityIdentity -> LinuxRke2FoundationId
ownershipManifestAuthorityFoundation =
  evidenceLinuxRke2Foundation . internalOwnershipManifestAuthorityScope

ownershipManifestAuthorityAwsScope
  :: OwnershipManifestAuthorityIdentity -> AwsScope
ownershipManifestAuthorityAwsScope = internalOwnershipManifestAuthorityAwsScope

ownershipManifestAuthorityLogicalName
  :: OwnershipManifestAuthorityIdentity -> Text
ownershipManifestAuthorityLogicalName identity =
  "authority/ownership-manifests/"
    <> ownershipManifestAuthoritySubmissionKey identity

-- | The durable encoding of an authority identity.
--
-- Sprint 4.92: the scope travels as one nested 'ScopeWire' rather than as five
-- flattened fields — surface, run scope, foundation, AWS account, AWS region —
-- beside a separately carried registry revision.  Flattening is what forced the
-- decoder to rebuild the scope through 'mkObservationEvidenceScope', whose
-- documented contract hardcodes the DNS hosted zone to absent, so an encode and
-- decode round trip of an identity minted in a zone-carrying run handed back a
-- zone-blind one and the exact identity comparison that guards every read-back
-- then refused a record this authority had just written.
--
-- The registry revision is a scope field, so it now travels inside the nested
-- value; the flat check it used to get here is gone because 'identityFor'
-- refuses a revision that is not 'lifecycleRegistryRevision' with the same
-- refusal, on every scope it is given rather than only on decoded ones.
data OwnershipManifestIdentityWire = OwnershipManifestIdentityWire
  { manifestIdentityWireVersion :: !Int
  , manifestIdentityWireStackKey :: !Int
  , manifestIdentityWireCoordinateDigest :: !Text
  , manifestIdentityWireScope :: !ScopeWire
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Version 2 is the first identity encoding that carries the run's retained
-- DNS hosted zone.
--
-- Version 1 bytes are refused rather than upgraded, and could not be upgraded:
-- the zone is not recoverable from bytes written without it.  Nothing is
-- stranded by the refusal, because a version-1 submission key was derived from
-- a zone-blind canonical identity, so no version-2 read addresses a version-1
-- object in the first place.
ownershipManifestIdentityWireFormatVersion :: Int
ownershipManifestIdentityWireFormatVersion = 2

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
    (manifestIdentityWireVersion wire == ownershipManifestIdentityWireFormatVersion)
    ( Left
        ( OwnershipManifestRepositoryIdentityInvalid
            "identity version was unsupported"
        )
    )
  key <- decodeIdentityStackKey (manifestIdentityWireStackKey wire)
  scope <- decodeIdentityScope (manifestIdentityWireScope wire)
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
    { manifestIdentityWireVersion = ownershipManifestIdentityWireFormatVersion
    , manifestIdentityWireStackKey =
        fromEnum (ownershipManifestAuthorityStackKey identity)
    , manifestIdentityWireCoordinateDigest =
        managedResourceCoordinateDigestText
          (ownershipManifestAuthorityCoordinateDigest identity)
    , manifestIdentityWireScope =
        scopeToWire (internalOwnershipManifestAuthorityScope identity)
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

-- | Read a manifest decision back over the host-reachable client, keyed by the
-- stack and the scope alone.
--
-- Sprint @4.86@: 'OwnershipManifestClient' takes the authority identity as an
-- argument, and that identity is derivable only inside this module — so a host
-- holding a transport-backed client had no way to reach the record at all.
-- The target is rebuilt here from the scope's own surface rather than supplied,
-- because a caller reading back @forall surface@ has no witness to give and
-- inventing one would let it name a surface the scope does not carry.
readBackOwnershipManifestDecisionForScope
  :: (Monad m)
  => OwnershipManifestClient m
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> m (Either OwnershipManifestRepositoryError OwnershipManifestDecisionEvidence)
readBackOwnershipManifestDecisionForScope client key scope =
  case cleanupSurfaceWitnessFor (evidenceCleanupSurface scope) of
    SomeCleanupSurfaceWitness witness ->
      case mkOwnershipManifestTarget witness key scope of
        Left err -> pure (Left (targetInvalid err))
        Right target -> case identityFor key scope of
          Left err -> pure (Left err)
          Right expected ->
            readBackOwnershipManifestDecisionByIdentity client target expected
 where
  targetInvalid :: OwnershipManifestError -> OwnershipManifestRepositoryError
  targetInvalid = OwnershipManifestRepositoryIdentityInvalid . Text.pack . show

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

-- | Mint the authority identity — and therefore the immutable object name —
-- of one stack's write-ahead ownership manifest under one run scope.
--
-- Sprint 4.92: the canonical identity projects the scope through
-- 'scopeIdentityFields' instead of naming six of the scope's fields by hand
-- beside this repository's own two.  That hand list was zone-blind, and a
-- zone-blind key is a collision whether or not two zones are reachable from
-- one run today: this key decides which durable object a manifest claims, so
-- two runs compiled against different hosted zones claimed one object, and the
-- second was then either told it had replayed the first run's manifest or
-- refused as a conflict.  Carrying the zone is what makes the key name the run
-- it was minted for.
--
-- The operation is the one scope field the key must ignore, and it is
-- normalised rather than omitted; see 'ownershipManifestSlotScope'.
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
      slotScope = ownershipManifestSlotScope scope
      -- The envelope's own two fields are framed first and the scope's ten
      -- follow, each length-framed by 'frame' exactly as before, so the
      -- concatenation of two adjacent components still cannot be read as one.
      canonicalIdentity =
        Text.concat
          ( map
              frame
              ( [ "ownership-manifest/v2"
                , registeredResourceKeyText key
                , managedResourceCoordinateDigestText coordinate
                ]
                  ++ scopeIdentityFields slotScope
              )
          )
      submissionKey =
        "ownership-manifest-v2-"
          <> TextEncoding.decodeUtf8
            (hexSha256 (TextEncoding.encodeUtf8 canonicalIdentity))
  Right
    OwnershipManifestAuthorityIdentity
      { internalOwnershipManifestAuthoritySubmissionKey = submissionKey
      , internalOwnershipManifestAuthorityStackKey = key
      , internalOwnershipManifestAuthorityCoordinateDigest = coordinate
      , internalOwnershipManifestAuthorityScope = slotScope
      , internalOwnershipManifestAuthorityAwsScope = awsScope
      }

-- | The scope as the immutable slot sees it.
--
-- The slot excludes the present\/absent operation, and has to: a write-ahead
-- manifest is committed under 'ReconcileDesiredPresent' and read back during
-- cleanup under 'ReconcileDesiredAbsent', so if the operation reached the key
-- the two would address different objects and the record would be unreachable
-- at exactly the moment it exists to be read.
--
-- Sprint 4.92: the operation is therefore normalised to the one value the
-- write path mints, rather than dropped from the projection.  Omitting a field
-- is how this key came to be zone-blind in the first place; pinning it keeps
-- 'scopeIdentityFields' as the whole statement of what identity is, so a field
-- added to the scope later joins the key on its own.  Record update, not a
-- field-by-field re-mint, so nothing else here can be dropped either.
ownershipManifestSlotScope
  :: ObservationEvidenceScope -> ObservationEvidenceScope
ownershipManifestSlotScope scope =
  observationEvidenceScopeFromFields
    (observationEvidenceScopeFields scope)
      { scopeFieldLifecycleOperation = ReconcileDesiredPresent
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

-- | Sprint 4.92: the canonical scope decoder, mapped into this repository's
-- error type.
--
-- The field rules live in "Prodbox.Lifecycle.Teardown.ScopeCodec" now, which is
-- why the cleanup-surface bounded-enum check and the flat registry-revision
-- check this decoder used to state for itself are gone: an envelope restating
-- the rules for the scope's fields is exactly how this envelope came to state
-- them for six fields and not for the hosted zone.  The refusals 'identityFor'
-- applies on top are not rules about the scope's own fields but about this
-- repository's slot, so they stay, and they cover every scope it is handed
-- rather than only the decoded ones.
decodeIdentityScope
  :: ScopeWire
  -> Either OwnershipManifestRepositoryError ObservationEvidenceScope
decodeIdentityScope =
  first (OwnershipManifestRepositoryIdentityInvalid . renderScopeWireError)
    . scopeFromWire

frame :: Text -> Text
frame value = Text.pack (show (Text.length value)) <> ":" <> value

foundationText :: LinuxRke2FoundationId -> Text
foundationText (LinuxRke2FoundationId value) = value

runScopeText :: DurableObservationRunScope -> Text
runScopeText (DurableObservationRunScope value) = value
