{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Lifecycle-Authority-owned persistence seam for the EKS drain write-ahead
-- intent.  This module defines logical Authority coordinates only; it does not
-- provide a host-file or process-memory production store.
--
-- The submission key deliberately excludes the selected Kubernetes targets.
-- A second payload for the same run, graph, scope, registry identity, and four
-- operations therefore reaches the same create-if-absent slot and conflicts
-- instead of silently creating a parallel intent.
module Prodbox.ControlPlane.EksDrainIntentRepository
  ( EksDrainIntentSubmissionKey
  , eksDrainIntentSubmissionKeyText
  , EksDrainIntentAuthorityIdentity
  , eksDrainIntentAuthorityIdentity
  , eksDrainIntentAuthorityRecoveryIdentity
  , encodeEksDrainIntentAuthorityIdentity
  , decodeEksDrainIntentAuthorityIdentity
  , maximumEksDrainIntentAuthorityIdentityBytes
  , EksDrainIntentAuthorityIdentityError (..)
  , eksDrainIntentAuthoritySubmissionKey
  , eksDrainIntentAuthorityRunId
  , eksDrainIntentAuthorityGraphDigest
  , eksDrainIntentAuthorityScope
  , eksDrainIntentAuthorityResourceKey
  , eksDrainIntentAuthorityCoordinateDigest
  , eksDrainIntentAuthorityCommitOperationId
  , eksDrainIntentAuthorityReadBackOperationId
  , eksDrainIntentAuthorityEffectOperationId
  , eksDrainIntentAuthorityDrainReadBackOperationId
  , EksDrainIntentCommitRequest
  , prepareEksDrainIntentCommitRequest
  , eksDrainIntentCommitRequestIdentity
  , eksDrainIntentCommitRequestDigest
  , eksDrainIntentCommitRequestBytes
  , EksDrainIntentCommitRequestError (..)
  , EksDrainIntentCommitResult (..)
  , EksDrainIntentAuthorityReadBackObservation (..)
  , EksDrainIntentRepository (..)
  , eksDrainIntentAuthorityLogicalName
  , eksDrainIntentModelBCodec
  , modelBEksDrainIntentRepository
  )
where

import Codec.CBOR.Decoding qualified as Cbor
import Codec.CBOR.Encoding qualified as Cbor
import Codec.Serialise
  ( Serialise (decode, encode)
  , deserialiseOrFail
  , serialise
  )
import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import Prodbox.Aws.SigV4 (hexSha256)
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
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupOperationId
  , CleanupRunId
  , cleanupDigestText
  , cleanupOperationIdText
  , cleanupRunIdText
  , mkCleanupDigest
  , mkCleanupOperationId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.Teardown.EksDrainIntent
  ( EksDrainIntent
  , EksDrainIntentDigest
  , EksDrainIntentError (..)
  , EksDrainOperationBinding
  , decodeEksDrainIntent
  , eksDrainBindingDrainReadBackOperationId
  , eksDrainBindingEffectOperationId
  , eksDrainBindingGraphDigest
  , eksDrainBindingIntentCommitOperationId
  , eksDrainBindingIntentReadBackOperationId
  , eksDrainBindingRunId
  , eksDrainBindingScope
  , eksDrainIntentBinding
  , eksDrainIntentCoordinateDigest
  , eksDrainIntentDigest
  , eksDrainIntentResourceKey
  , encodeEksDrainIntent
  , maximumEksDrainIntentBytes
  , mkEksDrainOperationBinding
  )
import Prodbox.Lifecycle.Teardown.Model
  ( ManagedResourceCoordinateDigest
  , ObservationEvidenceScope
  , ObservationFailure (..)
  , RegisteredResourceKey (AwsEksKey)
  , managedResourceCoordinateDigestText
  , registeredResourceKeyText
  )
import Prodbox.Lifecycle.Teardown.Registry qualified as Registry
import Prodbox.Lifecycle.Teardown.ScopeCodec
  ( ScopeWire
  , renderScopeWireError
  , scopeFromWire
  , scopeIdentityFields
  , scopeToWire
  )

newtype EksDrainIntentSubmissionKey = EksDrainIntentSubmissionKey Text
  deriving stock (Eq, Ord, Show)

eksDrainIntentSubmissionKeyText :: EksDrainIntentSubmissionKey -> Text
eksDrainIntentSubmissionKeyText (EksDrainIntentSubmissionKey value) = value

-- | Exact logical coordinate selected by the Authority repository.  The
-- constructor is private: every field is projected from either one validated
-- intent or the exact validated operation binding used for process recovery.
data EksDrainIntentAuthorityIdentity = EksDrainIntentAuthorityIdentity
  { internalEksDrainIntentAuthoritySubmissionKey
      :: !EksDrainIntentSubmissionKey
  , internalEksDrainIntentAuthorityRunId :: !CleanupRunId
  , internalEksDrainIntentAuthorityGraphDigest :: !CleanupDigest
  , internalEksDrainIntentAuthorityScope :: !ObservationEvidenceScope
  , internalEksDrainIntentAuthorityResourceKey :: !RegisteredResourceKey
  , internalEksDrainIntentAuthorityCoordinateDigest
      :: !ManagedResourceCoordinateDigest
  , internalEksDrainIntentAuthorityCommitOperationId :: !CleanupOperationId
  , internalEksDrainIntentAuthorityReadBackOperationId :: !CleanupOperationId
  , internalEksDrainIntentAuthorityEffectOperationId :: !CleanupOperationId
  , internalEksDrainIntentAuthorityDrainReadBackOperationId
      :: !CleanupOperationId
  }
  deriving stock (Eq, Show)

eksDrainIntentAuthorityIdentity
  :: EksDrainIntent -> EksDrainIntentAuthorityIdentity
eksDrainIntentAuthorityIdentity intent =
  authorityIdentityFromBinding
    (eksDrainIntentBinding intent)
    (eksDrainIntentResourceKey intent)
    (eksDrainIntentCoordinateDigest intent)

-- | Reconstruct the exact retained Authority coordinate from the stable
-- operation binding alone.  This is the process-loss ingress: it deliberately
-- contains no Kubernetes target selection and cannot choose a different
-- registry identity or coordinate.
eksDrainIntentAuthorityRecoveryIdentity
  :: EksDrainOperationBinding -> EksDrainIntentAuthorityIdentity
eksDrainIntentAuthorityRecoveryIdentity binding =
  authorityIdentityFromBinding
    binding
    AwsEksKey
    exactEksCoordinateDigest

authorityIdentityFromBinding
  :: EksDrainOperationBinding
  -> RegisteredResourceKey
  -> ManagedResourceCoordinateDigest
  -> EksDrainIntentAuthorityIdentity
authorityIdentityFromBinding binding resourceKey coordinateDigest =
  EksDrainIntentAuthorityIdentity
    { internalEksDrainIntentAuthoritySubmissionKey =
        stableSubmissionKey
          runId
          graphDigest
          scope
          resourceKey
          coordinateDigest
          commitOperation
          readBackOperation
          effectOperation
          drainReadBackOperation
    , internalEksDrainIntentAuthorityRunId = runId
    , internalEksDrainIntentAuthorityGraphDigest = graphDigest
    , internalEksDrainIntentAuthorityScope = scope
    , internalEksDrainIntentAuthorityResourceKey = resourceKey
    , internalEksDrainIntentAuthorityCoordinateDigest = coordinateDigest
    , internalEksDrainIntentAuthorityCommitOperationId = commitOperation
    , internalEksDrainIntentAuthorityReadBackOperationId = readBackOperation
    , internalEksDrainIntentAuthorityEffectOperationId = effectOperation
    , internalEksDrainIntentAuthorityDrainReadBackOperationId =
        drainReadBackOperation
    }
 where
  runId = eksDrainBindingRunId binding
  graphDigest = eksDrainBindingGraphDigest binding
  scope = eksDrainBindingScope binding
  commitOperation = eksDrainBindingIntentCommitOperationId binding
  readBackOperation = eksDrainBindingIntentReadBackOperationId binding
  effectOperation = eksDrainBindingEffectOperationId binding
  drainReadBackOperation = eksDrainBindingDrainReadBackOperationId binding

eksDrainIntentAuthoritySubmissionKey
  :: EksDrainIntentAuthorityIdentity -> EksDrainIntentSubmissionKey
eksDrainIntentAuthoritySubmissionKey =
  internalEksDrainIntentAuthoritySubmissionKey

eksDrainIntentAuthorityRunId
  :: EksDrainIntentAuthorityIdentity -> CleanupRunId
eksDrainIntentAuthorityRunId = internalEksDrainIntentAuthorityRunId

eksDrainIntentAuthorityGraphDigest
  :: EksDrainIntentAuthorityIdentity -> CleanupDigest
eksDrainIntentAuthorityGraphDigest = internalEksDrainIntentAuthorityGraphDigest

eksDrainIntentAuthorityScope
  :: EksDrainIntentAuthorityIdentity -> ObservationEvidenceScope
eksDrainIntentAuthorityScope = internalEksDrainIntentAuthorityScope

eksDrainIntentAuthorityResourceKey
  :: EksDrainIntentAuthorityIdentity -> RegisteredResourceKey
eksDrainIntentAuthorityResourceKey = internalEksDrainIntentAuthorityResourceKey

eksDrainIntentAuthorityCoordinateDigest
  :: EksDrainIntentAuthorityIdentity -> ManagedResourceCoordinateDigest
eksDrainIntentAuthorityCoordinateDigest =
  internalEksDrainIntentAuthorityCoordinateDigest

eksDrainIntentAuthorityCommitOperationId
  :: EksDrainIntentAuthorityIdentity -> CleanupOperationId
eksDrainIntentAuthorityCommitOperationId =
  internalEksDrainIntentAuthorityCommitOperationId

eksDrainIntentAuthorityReadBackOperationId
  :: EksDrainIntentAuthorityIdentity -> CleanupOperationId
eksDrainIntentAuthorityReadBackOperationId =
  internalEksDrainIntentAuthorityReadBackOperationId

eksDrainIntentAuthorityEffectOperationId
  :: EksDrainIntentAuthorityIdentity -> CleanupOperationId
eksDrainIntentAuthorityEffectOperationId =
  internalEksDrainIntentAuthorityEffectOperationId

eksDrainIntentAuthorityDrainReadBackOperationId
  :: EksDrainIntentAuthorityIdentity -> CleanupOperationId
eksDrainIntentAuthorityDrainReadBackOperationId =
  internalEksDrainIntentAuthorityDrainReadBackOperationId

-- | Canonical, secret-free recovery coordinate carried over the authenticated
-- Authority route.  The constructor stays private; decode reconstructs the
-- validated EKS operation binding and checks every mirrored identity field.
--
-- Sprint 4.92: the evidence scope travels as one nested 'ScopeWire' instead of
-- as seven fields flattened among this envelope's own.  The flattened form had
-- no field for the run's retained DNS hosted zone, and its decoder re-minted the
-- scope through @mkObservationEvidenceScope@, whose contract hardcodes that zone
-- to absent.  A recovery identity emitted for a zone-bearing run therefore
-- decoded back to a materially different scope, and the submission-key
-- comparison that closes 'decodeAuthorityIdentityWire' then refused the very
-- coordinate this module had just encoded.  Nesting the canonical wire form
-- leaves no field list here for a later author to forget to extend.
data EksDrainIntentAuthorityIdentityWire = EksDrainIntentAuthorityIdentityWire
  { identityWireVersion :: !Word16
  , identityWireSubmissionKey :: !Text
  , identityWireRunId :: !Text
  , identityWireGraphDigest :: !Text
  , identityWireScope :: !ScopeWire
  , identityWireResourceKey :: !Text
  , identityWireCoordinateDigest :: !Text
  , identityWireCommitOperation :: !Text
  , identityWireReadBackOperation :: !Text
  , identityWireEffectOperation :: !Text
  , identityWireDrainReadBackOperation :: !Text
  }
  deriving stock (Eq, Show)

instance Serialise EksDrainIntentAuthorityIdentityWire where
  encode wire =
    Cbor.encodeListLen 11
      <> Cbor.encodeWord16 (identityWireVersion wire)
      <> Cbor.encodeString (identityWireSubmissionKey wire)
      <> Cbor.encodeString (identityWireRunId wire)
      <> Cbor.encodeString (identityWireGraphDigest wire)
      <> encode (identityWireScope wire)
      <> Cbor.encodeString (identityWireResourceKey wire)
      <> Cbor.encodeString (identityWireCoordinateDigest wire)
      <> Cbor.encodeString (identityWireCommitOperation wire)
      <> Cbor.encodeString (identityWireReadBackOperation wire)
      <> Cbor.encodeString (identityWireEffectOperation wire)
      <> Cbor.encodeString (identityWireDrainReadBackOperation wire)
  decode = do
    fields <- Cbor.decodeListLen
    unless (fields == 11) $
      fail "EksDrainIntentAuthorityIdentity: expected 11 fields"
    EksDrainIntentAuthorityIdentityWire
      <$> Cbor.decodeWord16
      <*> Cbor.decodeString
      <*> Cbor.decodeString
      <*> Cbor.decodeString
      <*> decode
      <*> Cbor.decodeString
      <*> Cbor.decodeString
      <*> Cbor.decodeString
      <*> Cbor.decodeString
      <*> Cbor.decodeString
      <*> Cbor.decodeString

data EksDrainIntentAuthorityIdentityError
  = EksDrainIntentAuthorityIdentityEmpty
  | EksDrainIntentAuthorityIdentityTooLarge !Int !Int
  | EksDrainIntentAuthorityIdentityDecodeInvalid !Text
  | EksDrainIntentAuthorityIdentityNonCanonical
  | EksDrainIntentAuthorityIdentityVersionUnsupported !Word16
  | EksDrainIntentAuthorityIdentityFieldInvalid !Text
  | EksDrainIntentAuthorityIdentityResourceKeyMismatch !Text
  | EksDrainIntentAuthorityIdentityCoordinateMismatch !Text !Text
  | EksDrainIntentAuthorityIdentitySubmissionKeyMismatch !Text !Text
  | EksDrainIntentAuthorityIdentityBindingInvalid !EksDrainIntentError
  deriving stock (Eq, Show)

maximumEksDrainIntentAuthorityIdentityBytes :: Int
maximumEksDrainIntentAuthorityIdentityBytes = 4096

-- | Sprint 4.92: version 2 is the first encoding whose scope is nested, and
-- therefore the first that carries the run's retained DNS hosted zone.  Version
-- 1 bytes are refused rather than upgraded.  A version-1 identity's submission
-- key was derived from a zone-blind canonical text, so it names a different
-- retained Authority object than any version-2 read addresses; upgrading such
-- bytes in place would hand back an identity whose own submission key no longer
-- matched the object it came from.
eksDrainIntentAuthorityIdentityFormatVersion :: Word16
eksDrainIntentAuthorityIdentityFormatVersion = 2

encodeEksDrainIntentAuthorityIdentity
  :: EksDrainIntentAuthorityIdentity -> ByteString
encodeEksDrainIntentAuthorityIdentity =
  LazyByteString.toStrict . serialise . authorityIdentityWire

decodeEksDrainIntentAuthorityIdentity
  :: ByteString
  -> Either
       EksDrainIntentAuthorityIdentityError
       EksDrainIntentAuthorityIdentity
decodeEksDrainIntentAuthorityIdentity bytes
  | ByteString.null bytes = Left EksDrainIntentAuthorityIdentityEmpty
  | ByteString.length bytes > maximumEksDrainIntentAuthorityIdentityBytes =
      Left
        ( EksDrainIntentAuthorityIdentityTooLarge
            (ByteString.length bytes)
            maximumEksDrainIntentAuthorityIdentityBytes
        )
  | otherwise = do
      wire <-
        first
          (EksDrainIntentAuthorityIdentityDecodeInvalid . Text.pack . show)
          (deserialiseOrFail (LazyByteString.fromStrict bytes))
      if LazyByteString.toStrict (serialise wire) == bytes
        then Right ()
        else Left EksDrainIntentAuthorityIdentityNonCanonical
      decodeAuthorityIdentityWire wire

authorityIdentityWire
  :: EksDrainIntentAuthorityIdentity
  -> EksDrainIntentAuthorityIdentityWire
authorityIdentityWire identity =
  EksDrainIntentAuthorityIdentityWire
    { identityWireVersion = eksDrainIntentAuthorityIdentityFormatVersion
    , identityWireSubmissionKey =
        eksDrainIntentSubmissionKeyText
          (eksDrainIntentAuthoritySubmissionKey identity)
    , identityWireRunId = cleanupRunIdText (eksDrainIntentAuthorityRunId identity)
    , identityWireGraphDigest =
        cleanupDigestText (eksDrainIntentAuthorityGraphDigest identity)
    , identityWireScope = scopeToWire (eksDrainIntentAuthorityScope identity)
    , identityWireResourceKey =
        registeredResourceKeyText (eksDrainIntentAuthorityResourceKey identity)
    , identityWireCoordinateDigest =
        managedResourceCoordinateDigestText
          (eksDrainIntentAuthorityCoordinateDigest identity)
    , identityWireCommitOperation =
        cleanupOperationIdText
          (eksDrainIntentAuthorityCommitOperationId identity)
    , identityWireReadBackOperation =
        cleanupOperationIdText
          (eksDrainIntentAuthorityReadBackOperationId identity)
    , identityWireEffectOperation =
        cleanupOperationIdText
          (eksDrainIntentAuthorityEffectOperationId identity)
    , identityWireDrainReadBackOperation =
        cleanupOperationIdText
          (eksDrainIntentAuthorityDrainReadBackOperationId identity)
    }

decodeAuthorityIdentityWire
  :: EksDrainIntentAuthorityIdentityWire
  -> Either
       EksDrainIntentAuthorityIdentityError
       EksDrainIntentAuthorityIdentity
decodeAuthorityIdentityWire wire = do
  unlessIdentity
    (identityWireVersion wire == eksDrainIntentAuthorityIdentityFormatVersion)
    (EksDrainIntentAuthorityIdentityVersionUnsupported (identityWireVersion wire))
  requireIdentityText "submission key" 160 (identityWireSubmissionKey wire)
  let expectedResourceKey = registeredResourceKeyText AwsEksKey
  unlessIdentity
    (identityWireResourceKey wire == expectedResourceKey)
    ( EksDrainIntentAuthorityIdentityResourceKeyMismatch
        (identityWireResourceKey wire)
    )
  let expectedCoordinate = managedResourceCoordinateDigestText exactEksCoordinateDigest
  unlessIdentity
    (identityWireCoordinateDigest wire == expectedCoordinate)
    ( EksDrainIntentAuthorityIdentityCoordinateMismatch
        expectedCoordinate
        (identityWireCoordinateDigest wire)
    )
  runId <- identityText "run id" (mkCleanupRunId (identityWireRunId wire))
  graphDigest <-
    identityText "graph digest" (mkCleanupDigest (identityWireGraphDigest wire))
  commitOperation <-
    identityText
      "commit operation"
      (mkCleanupOperationId (identityWireCommitOperation wire))
  readBackOperation <-
    identityText
      "read-back operation"
      (mkCleanupOperationId (identityWireReadBackOperation wire))
  effectOperation <-
    identityText
      "effect operation"
      (mkCleanupOperationId (identityWireEffectOperation wire))
  drainReadBackOperation <-
    identityText
      "drain read-back operation"
      (mkCleanupOperationId (identityWireDrainReadBackOperation wire))
  scope <- decodeScopeWire (identityWireScope wire)
  binding <-
    first
      EksDrainIntentAuthorityIdentityBindingInvalid
      ( mkEksDrainOperationBinding
          scope
          runId
          graphDigest
          commitOperation
          readBackOperation
          effectOperation
          drainReadBackOperation
      )
  let identity = eksDrainIntentAuthorityRecoveryIdentity binding
      expectedSubmissionKey =
        eksDrainIntentSubmissionKeyText
          (eksDrainIntentAuthoritySubmissionKey identity)
  unlessIdentity
    (identityWireSubmissionKey wire == expectedSubmissionKey)
    ( EksDrainIntentAuthorityIdentitySubmissionKeyMismatch
        expectedSubmissionKey
        (identityWireSubmissionKey wire)
    )
  Right identity

identityText
  :: Text
  -> Either Text value
  -> Either EksDrainIntentAuthorityIdentityError value
identityText label =
  first
    ( EksDrainIntentAuthorityIdentityFieldInvalid
        . ((label <> ": ") <>)
    )

requireIdentityText
  :: Text
  -> Int
  -> Text
  -> Either EksDrainIntentAuthorityIdentityError ()
requireIdentityText label maximumLength value
  | Text.null value = invalid "must not be empty"
  | Text.length value > maximumLength = invalid "exceeds maximum length"
  | otherwise = Right ()
 where
  invalid detail =
    Left
      ( EksDrainIntentAuthorityIdentityFieldInvalid
          (label <> " " <> detail)
      )

unlessIdentity
  :: Bool
  -> EksDrainIntentAuthorityIdentityError
  -> Either EksDrainIntentAuthorityIdentityError ()
unlessIdentity condition err = if condition then Right () else Left err

-- | Sprint 4.92: the canonical scope decoder, mapped into this module's error
-- type.
--
-- The field rules live in "Prodbox.Lifecycle.Teardown.ScopeCodec" so that every
-- envelope reads a scope the same way.  This module used to restate a subset of
-- them inline and then rebuild the scope through @mkObservationEvidenceScope@,
-- which is precisely how the run's retained DNS hosted zone was erased on every
-- recovery decode.
--
-- The two hand-written tag decoders replaced here additionally narrowed the
-- cleanup surface to @Cascade@, @ExplicitPerRun@ or @TotalDecommission@ and the
-- lifecycle operation to @ReconcileDesiredAbsent@.  That narrowing is not lost:
-- 'decodeAuthorityIdentityWire' hands the decoded scope straight to
-- 'mkEksDrainOperationBinding', which refuses exactly the same surfaces and
-- operations, so an out-of-range value now surfaces as
-- 'EksDrainIntentAuthorityIdentityBindingInvalid' rather than as a field
-- refusal, and is refused either way.
decodeScopeWire
  :: ScopeWire
  -> Either EksDrainIntentAuthorityIdentityError ObservationEvidenceScope
decodeScopeWire =
  first (EksDrainIntentAuthorityIdentityFieldInvalid . renderScopeWireError)
    . scopeFromWire

data EksDrainIntentCommitRequest = EksDrainIntentCommitRequest
  { internalEksDrainIntentCommitRequestIdentity
      :: !EksDrainIntentAuthorityIdentity
  , internalEksDrainIntentCommitRequestDigest :: !EksDrainIntentDigest
  , internalEksDrainIntentCommitRequestBytes :: !ByteString
  }
  deriving stock (Eq)

data EksDrainIntentCommitRequestError
  = EksDrainIntentCommitRequestEmpty
  | EksDrainIntentCommitRequestTooLarge !Int !Int
  | EksDrainIntentCommitRequestCodecInvalid !EksDrainIntentError
  | EksDrainIntentCommitRequestRoundTripMismatch
  deriving stock (Eq, Show)

-- | Build the only repository write request.  The generated bytes are checked
-- through the public strict decoder before they can reach Authority storage.
prepareEksDrainIntentCommitRequest
  :: EksDrainIntent
  -> Either EksDrainIntentCommitRequestError EksDrainIntentCommitRequest
prepareEksDrainIntentCommitRequest intent
  | ByteString.null bytes = Left EksDrainIntentCommitRequestEmpty
  | ByteString.length bytes > maximumEksDrainIntentBytes =
      Left
        ( EksDrainIntentCommitRequestTooLarge
            (ByteString.length bytes)
            maximumEksDrainIntentBytes
        )
  | otherwise = case decodeEksDrainIntent bytes of
      Left err -> Left (EksDrainIntentCommitRequestCodecInvalid err)
      Right decoded
        | decoded == intent ->
            Right
              EksDrainIntentCommitRequest
                { internalEksDrainIntentCommitRequestIdentity =
                    eksDrainIntentAuthorityIdentity intent
                , internalEksDrainIntentCommitRequestDigest =
                    eksDrainIntentDigest intent
                , internalEksDrainIntentCommitRequestBytes = bytes
                }
        | otherwise -> Left EksDrainIntentCommitRequestRoundTripMismatch
 where
  bytes = encodeEksDrainIntent intent

eksDrainIntentCommitRequestIdentity
  :: EksDrainIntentCommitRequest -> EksDrainIntentAuthorityIdentity
eksDrainIntentCommitRequestIdentity =
  internalEksDrainIntentCommitRequestIdentity

eksDrainIntentCommitRequestDigest
  :: EksDrainIntentCommitRequest -> EksDrainIntentDigest
eksDrainIntentCommitRequestDigest = internalEksDrainIntentCommitRequestDigest

eksDrainIntentCommitRequestBytes
  :: EksDrainIntentCommitRequest -> ByteString
eksDrainIntentCommitRequestBytes = internalEksDrainIntentCommitRequestBytes

-- | Create-if-absent result from the durable Authority store.  A lost or
-- cancelled response is never treated as proof that the write did not happen;
-- the client always performs an independent read-back.
data EksDrainIntentCommitResult
  = EksDrainIntentCommitCreated
  | EksDrainIntentCommitExactReplay
  | EksDrainIntentCommitConflict
  | EksDrainIntentCommitCancelled
  | EksDrainIntentCommitResponseLost !ObservationFailure
  | EksDrainIntentCommitUnavailable !ObservationFailure
  deriving stock (Eq, Show)

-- | Authority storage observation kept distinct from the pure intent
-- read-back algebra so retained codec corruption cannot be collapsed into an
-- endpoint outage.  Only the client converts a positive byte observation into
-- the opaque committed proof.
data EksDrainIntentAuthorityReadBackObservation
  = EksDrainIntentAuthorityReadBackPresent !ByteString
  | EksDrainIntentAuthorityReadBackMissing
  | EksDrainIntentAuthorityReadBackCorrupt !Text
  | EksDrainIntentAuthorityReadBackUnobservable !ObservationFailure
  | EksDrainIntentAuthorityReadBackUnbounded !Int !Int
  deriving stock (Eq, Show)

-- | Dependency-injected Lifecycle Authority persistence.  Production
-- implementations must use the retained Authority object namespace.  The
-- repository is intentionally not backed by a host path or a module-global
-- map here; tests may supply a fake.
data EksDrainIntentRepository m = EksDrainIntentRepository
  { createOrReplayAuthorityEksDrainIntent
      :: EksDrainIntentCommitRequest -> m EksDrainIntentCommitResult
  , independentlyReadBackAuthorityEksDrainIntent
      :: EksDrainIntentAuthorityIdentity
      -> m EksDrainIntentAuthorityReadBackObservation
  }

-- | Fixed retained namespace below the Lifecycle Authority object root.  The
-- caller cannot choose an object name: the only suffix is the SHA-256-bound
-- logical submission key projected from the opaque identity.
eksDrainIntentAuthorityLogicalName
  :: EksDrainIntentAuthorityIdentity -> Text
eksDrainIntentAuthorityLogicalName identity =
  "authority/eks-drain-intents/"
    <> eksDrainIntentSubmissionKeyText
      (eksDrainIntentAuthoritySubmissionKey identity)

-- | Strict codec installed in the encrypted Model-B adapter.  It stores only
-- the canonical, bounded, secret-free intent bytes; malformed or noncanonical
-- retained values are corruption, never a missing intent.
eksDrainIntentModelBCodec :: ModelBCodec ByteString
eksDrainIntentModelBCodec =
  ModelBCodec
    { encodeModelBValue = first show . validateCanonicalIntentBytes
    , decodeModelBValue = first show . validateCanonicalIntentBytes
    }

-- | Durable create-if-absent repository over the retained Lifecycle Authority
-- Model-B adapter.  A Runtime restart constructs a fresh value around the same
-- encrypted object coordinate and therefore observes the prior canonical
-- intent.  This function carries no object-store or Vault credential.
modelBEksDrainIntentRepository
  :: (Monad m)
  => LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> EksDrainIntentRepository m
modelBEksDrainIntentRepository authority adapter =
  EksDrainIntentRepository
    { createOrReplayAuthorityEksDrainIntent = createOrReplay
    , independentlyReadBackAuthorityEksDrainIntent = readBack
    }
 where
  createOrReplay request =
    case coordinateFor (eksDrainIntentCommitRequestIdentity request) of
      Left detail -> pure (EksDrainIntentCommitUnavailable detail)
      Right coordinate -> do
        observed <- modelBObserve adapter coordinate
        case observed of
          ModelBMissing -> initialize coordinate request
          ModelBObserved _ existing ->
            pure (existingDisposition request existing)
          ModelBCorrupt detail ->
            pure (EksDrainIntentCommitUnavailable (repositoryFailure "corrupt" detail))
          ModelBEndpointUnready detail ->
            pure (EksDrainIntentCommitUnavailable (repositoryFailure "endpoint-unready" detail))
          ModelBUnobservable detail ->
            pure (EksDrainIntentCommitUnavailable (repositoryFailure "unobservable" detail))

  initialize coordinate request = do
    result <-
      modelBCompareAndSwap
        adapter
        (ModelBInitialize coordinate (eksDrainIntentCommitRequestBytes request))
    pure $ case result of
      ModelBCasApplied _ applied
        | applied == eksDrainIntentCommitRequestBytes request ->
            EksDrainIntentCommitCreated
        | otherwise -> EksDrainIntentCommitConflict
      ModelBCasConflict observation ->
        conflictDisposition request observation
      ModelBCasRefusedCorrupt detail ->
        EksDrainIntentCommitUnavailable (repositoryFailure "cas-corrupt" detail)
      ModelBCasEndpointUnready detail ->
        EksDrainIntentCommitUnavailable
          (repositoryFailure "cas-endpoint-unready" detail)
      ModelBCasUnobservable detail ->
        EksDrainIntentCommitResponseLost
          (repositoryFailure "cas-response-unobservable" detail)

  readBack identity = case coordinateFor identity of
    Left detail -> pure (EksDrainIntentAuthorityReadBackUnobservable detail)
    Right coordinate -> do
      observed <- modelBObserve adapter coordinate
      pure $ case observed of
        ModelBMissing -> EksDrainIntentAuthorityReadBackMissing
        ModelBObserved _ bytes
          | ByteString.length bytes > maximumEksDrainIntentBytes ->
              EksDrainIntentAuthorityReadBackUnbounded
                (ByteString.length bytes)
                maximumEksDrainIntentBytes
          | otherwise -> EksDrainIntentAuthorityReadBackPresent bytes
        ModelBCorrupt detail ->
          EksDrainIntentAuthorityReadBackCorrupt detail
        ModelBEndpointUnready detail ->
          EksDrainIntentAuthorityReadBackUnobservable
            (repositoryFailure "endpoint-unready" detail)
        ModelBUnobservable detail ->
          EksDrainIntentAuthorityReadBackUnobservable
            (repositoryFailure "unobservable" detail)

  coordinateFor identity =
    first
      (repositoryFailure "coordinate" . Text.pack . show)
      ( mkClusterRetainedCoordinate
          authority
          (eksDrainIntentAuthorityLogicalName identity)
      )

existingDisposition
  :: EksDrainIntentCommitRequest -> ByteString -> EksDrainIntentCommitResult
existingDisposition request existing
  | existing == eksDrainIntentCommitRequestBytes request =
      EksDrainIntentCommitExactReplay
  | otherwise = EksDrainIntentCommitConflict

conflictDisposition
  :: EksDrainIntentCommitRequest
  -> ModelBObservation ByteString
  -> EksDrainIntentCommitResult
conflictDisposition request observation = case observation of
  ModelBObserved _ existing -> existingDisposition request existing
  ModelBMissing ->
    EksDrainIntentCommitUnavailable
      (repositoryFailure "cas-conflict" "conflict observation was missing")
  ModelBCorrupt detail ->
    EksDrainIntentCommitUnavailable
      (repositoryFailure "cas-conflict-corrupt" detail)
  ModelBEndpointUnready detail ->
    EksDrainIntentCommitUnavailable
      (repositoryFailure "cas-conflict-endpoint-unready" detail)
  ModelBUnobservable detail ->
    EksDrainIntentCommitUnavailable
      (repositoryFailure "cas-conflict-unobservable" detail)

validateCanonicalIntentBytes
  :: ByteString -> Either EksDrainIntentError ByteString
validateCanonicalIntentBytes bytes = do
  intent <- decodeEksDrainIntent bytes
  if encodeEksDrainIntent intent == bytes
    then Right bytes
    else Left EksDrainIntentCodecNonCanonical

exactEksCoordinateDigest :: ManagedResourceCoordinateDigest
exactEksCoordinateDigest =
  Registry.managedResourceCoordinateDigest Registry.awsEksResource

repositoryFailure :: Text -> Text -> ObservationFailure
repositoryFailure category detail =
  ObservationFailure
    ("EKS drain-intent Authority " <> category <> ": " <> detail)

-- | The create-if-absent slot this run's intent must reach.
--
-- Sprint 4.92: the scope contributes 'scopeIdentityFields' rather than a
-- hand-written field list.  The list this replaces was zone-blind, so two runs
-- that differed only in their retained DNS hosted zone produced byte-identical
-- canonical text and collided on one Authority submission key: the second run's
-- commit observed the first run's intent bytes and was reported as a conflict
-- against an intent it had nothing to do with.  The canonical text is therefore
-- version @v2@ — the digest genuinely changes, and a v1 key names an object no
-- v2 read addresses.  The @eks-drain-intent-v1-@ literal below is deliberately
-- untouched: it names the key scheme rather than the canonical text, and the
-- new digest already moves every key to an unoccupied object name.
stableSubmissionKey
  :: CleanupRunId
  -> CleanupDigest
  -> ObservationEvidenceScope
  -> RegisteredResourceKey
  -> ManagedResourceCoordinateDigest
  -> CleanupOperationId
  -> CleanupOperationId
  -> CleanupOperationId
  -> CleanupOperationId
  -> EksDrainIntentSubmissionKey
stableSubmissionKey runId graphDigest scope resourceKey coordinateDigest commitOperation readBackOperation effectOperation drainReadBackOperation =
  EksDrainIntentSubmissionKey
    ( "eks-drain-intent-v1-"
        <> TextEncoding.decodeUtf8
          (hexSha256 (TextEncoding.encodeUtf8 canonical))
    )
 where
  canonical =
    canonicalFields
      ( [ "prodbox.eks-drain-intent-authority/v2"
        , cleanupRunIdText runId
        , cleanupDigestText graphDigest
        ]
          <> scopeIdentityFields scope
          <> [ registeredResourceKeyText resourceKey
             , managedResourceCoordinateDigestText coordinateDigest
             , cleanupOperationIdText commitOperation
             , cleanupOperationIdText readBackOperation
             , cleanupOperationIdText effectOperation
             , cleanupOperationIdText drainReadBackOperation
             ]
      )

canonicalFields :: [Text] -> Text
canonicalFields = Text.concat . map frame
 where
  frame value = Text.pack (show (Text.length value)) <> ":" <> value
