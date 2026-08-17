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
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (..)
  , DurableObservationRunScope (..)
  , LifecycleOperation (..)
  , LinuxRke2FoundationId (..)
  , ManagedResourceCoordinateDigest
  , ObservationEvidenceScope
  , ObservationFailure (..)
  , RegisteredResourceKey (AwsEksKey)
  , RegistryRevision (..)
  , evidenceAwsScope
  , evidenceCleanupSurface
  , evidenceDurableRunScope
  , evidenceLifecycleOperation
  , evidenceLinuxRke2Foundation
  , evidenceRegistryRevision
  , managedResourceCoordinateDigestText
  , mkObservationEvidenceScope
  , registeredResourceKeyText
  )
import Prodbox.Lifecycle.Teardown.Registry qualified as Registry

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
data EksDrainIntentAuthorityIdentityWire = EksDrainIntentAuthorityIdentityWire
  { identityWireVersion :: !Word16
  , identityWireSubmissionKey :: !Text
  , identityWireRunId :: !Text
  , identityWireGraphDigest :: !Text
  , identityWireSurface :: !Word16
  , identityWireRegistryRevision :: !Text
  , identityWireDurableRunScope :: !Text
  , identityWireFoundation :: !Text
  , identityWireAwsAccount :: !Text
  , identityWireAwsRegion :: !Text
  , identityWireLifecycleOperation :: !Word16
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
    Cbor.encodeListLen 17
      <> Cbor.encodeWord16 (identityWireVersion wire)
      <> Cbor.encodeString (identityWireSubmissionKey wire)
      <> Cbor.encodeString (identityWireRunId wire)
      <> Cbor.encodeString (identityWireGraphDigest wire)
      <> Cbor.encodeWord16 (identityWireSurface wire)
      <> Cbor.encodeString (identityWireRegistryRevision wire)
      <> Cbor.encodeString (identityWireDurableRunScope wire)
      <> Cbor.encodeString (identityWireFoundation wire)
      <> Cbor.encodeString (identityWireAwsAccount wire)
      <> Cbor.encodeString (identityWireAwsRegion wire)
      <> Cbor.encodeWord16 (identityWireLifecycleOperation wire)
      <> Cbor.encodeString (identityWireResourceKey wire)
      <> Cbor.encodeString (identityWireCoordinateDigest wire)
      <> Cbor.encodeString (identityWireCommitOperation wire)
      <> Cbor.encodeString (identityWireReadBackOperation wire)
      <> Cbor.encodeString (identityWireEffectOperation wire)
      <> Cbor.encodeString (identityWireDrainReadBackOperation wire)
  decode = do
    fields <- Cbor.decodeListLen
    unless (fields == 17) $
      fail "EksDrainIntentAuthorityIdentity: expected 17 fields"
    EksDrainIntentAuthorityIdentityWire
      <$> Cbor.decodeWord16
      <*> Cbor.decodeString
      <*> Cbor.decodeString
      <*> Cbor.decodeString
      <*> Cbor.decodeWord16
      <*> Cbor.decodeString
      <*> Cbor.decodeString
      <*> Cbor.decodeString
      <*> Cbor.decodeString
      <*> Cbor.decodeString
      <*> Cbor.decodeWord16
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

eksDrainIntentAuthorityIdentityFormatVersion :: Word16
eksDrainIntentAuthorityIdentityFormatVersion = 1

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
    , identityWireSurface =
        encodeIdentitySurface
          (evidenceCleanupSurface (eksDrainIntentAuthorityScope identity))
    , identityWireRegistryRevision =
        registryRevisionText
          (evidenceRegistryRevision (eksDrainIntentAuthorityScope identity))
    , identityWireDurableRunScope =
        durableRunScopeText
          (evidenceDurableRunScope (eksDrainIntentAuthorityScope identity))
    , identityWireFoundation =
        foundationIdText
          (evidenceLinuxRke2Foundation (eksDrainIntentAuthorityScope identity))
    , identityWireAwsAccount = maybe "" awsAccount (evidenceAwsScope scope)
    , identityWireAwsRegion = maybe "" awsRegion (evidenceAwsScope scope)
    , identityWireLifecycleOperation =
        encodeIdentityLifecycleOperation (evidenceLifecycleOperation scope)
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
 where
  scope = eksDrainIntentAuthorityScope identity
  awsAccount (AwsScope (AwsAccountId account) _) = account
  awsRegion (AwsScope _ (AwsRegion region)) = region

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
  requireIdentityText "registry revision" 256 (identityWireRegistryRevision wire)
  requireIdentityText "durable run scope" 256 (identityWireDurableRunScope wire)
  requireIdentityText "Linux RKE2 foundation" 256 (identityWireFoundation wire)
  requireIdentityText "AWS account" 64 (identityWireAwsAccount wire)
  requireIdentityText "AWS region" 64 (identityWireAwsRegion wire)
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
  surface <- decodeIdentitySurface (identityWireSurface wire)
  lifecycleOperation <-
    decodeIdentityLifecycleOperation (identityWireLifecycleOperation wire)
  let scope =
        mkObservationEvidenceScope
          surface
          (RegistryRevision (identityWireRegistryRevision wire))
          (DurableObservationRunScope (identityWireDurableRunScope wire))
          (LinuxRke2FoundationId (identityWireFoundation wire))
          ( Just
              ( AwsScope
                  (AwsAccountId (identityWireAwsAccount wire))
                  (AwsRegion (identityWireAwsRegion wire))
              )
          )
          lifecycleOperation
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

encodeIdentitySurface :: CleanupSurface -> Word16
encodeIdentitySurface surface = case surface of
  Cascade -> 1
  ExplicitPerRun -> 2
  TotalDecommission -> 3
  LocalOnly -> localOnlySurfaceTag
  OperationalTeardown -> operationalTeardownSurfaceTag
  ExplicitLongLived -> explicitLongLivedSurfaceTag

localOnlySurfaceTag, operationalTeardownSurfaceTag, explicitLongLivedSurfaceTag :: Word16
localOnlySurfaceTag = 101
operationalTeardownSurfaceTag = 102
explicitLongLivedSurfaceTag = 103

decodeIdentitySurface
  :: Word16
  -> Either EksDrainIntentAuthorityIdentityError CleanupSurface
decodeIdentitySurface tag = case tag of
  1 -> Right Cascade
  2 -> Right ExplicitPerRun
  3 -> Right TotalDecommission
  _ ->
    Left
      ( EksDrainIntentAuthorityIdentityFieldInvalid
          ("unsupported cleanup surface tag " <> Text.pack (show tag))
      )

encodeIdentityLifecycleOperation :: LifecycleOperation -> Word16
encodeIdentityLifecycleOperation operation = case operation of
  ReconcileDesiredAbsent -> 1
  ReconcileDesiredPresent -> reconcileDesiredPresentOperationTag
  RunTerminalEscapeAudit -> runTerminalEscapeAuditOperationTag

reconcileDesiredPresentOperationTag, runTerminalEscapeAuditOperationTag :: Word16
reconcileDesiredPresentOperationTag = 101
runTerminalEscapeAuditOperationTag = 102

decodeIdentityLifecycleOperation
  :: Word16
  -> Either EksDrainIntentAuthorityIdentityError LifecycleOperation
decodeIdentityLifecycleOperation tag = case tag of
  1 -> Right ReconcileDesiredAbsent
  _ ->
    Left
      ( EksDrainIntentAuthorityIdentityFieldInvalid
          ("unsupported lifecycle operation tag " <> Text.pack (show tag))
      )

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
      ( [ "prodbox.eks-drain-intent-authority/v1"
        , cleanupRunIdText runId
        , cleanupDigestText graphDigest
        ]
          <> scopeFields scope
          <> [ registeredResourceKeyText resourceKey
             , managedResourceCoordinateDigestText coordinateDigest
             , cleanupOperationIdText commitOperation
             , cleanupOperationIdText readBackOperation
             , cleanupOperationIdText effectOperation
             , cleanupOperationIdText drainReadBackOperation
             ]
      )

scopeFields :: ObservationEvidenceScope -> [Text]
scopeFields scope =
  [ cleanupSurfaceToken (evidenceCleanupSurface scope)
  , registryRevisionText (evidenceRegistryRevision scope)
  , durableRunScopeText (evidenceDurableRunScope scope)
  , foundationIdText (evidenceLinuxRke2Foundation scope)
  ]
    <> awsScopeFields (evidenceAwsScope scope)
    <> [lifecycleOperationToken (evidenceLifecycleOperation scope)]

awsScopeFields :: Maybe AwsScope -> [Text]
awsScopeFields maybeScope = case maybeScope of
  Nothing -> ["aws:none"]
  Just (AwsScope (AwsAccountId account) (AwsRegion region)) ->
    ["aws:present", account, region]

cleanupSurfaceToken :: CleanupSurface -> Text
cleanupSurfaceToken surface = case surface of
  LocalOnly -> "local-only"
  Cascade -> "cascade"
  ExplicitPerRun -> "explicit-per-run"
  OperationalTeardown -> "operational-teardown"
  ExplicitLongLived -> "explicit-long-lived"
  TotalDecommission -> "total-decommission"

lifecycleOperationToken :: LifecycleOperation -> Text
lifecycleOperationToken operation = case operation of
  ReconcileDesiredAbsent -> "reconcile-desired-absent"
  ReconcileDesiredPresent -> "reconcile-desired-present"
  RunTerminalEscapeAudit -> "run-terminal-escape-audit"

registryRevisionText :: RegistryRevision -> Text
registryRevisionText (RegistryRevision value) = value

durableRunScopeText :: DurableObservationRunScope -> Text
durableRunScopeText (DurableObservationRunScope value) = value

foundationIdText :: LinuxRke2FoundationId -> Text
foundationIdText (LinuxRke2FoundationId value) = value

canonicalFields :: [Text] -> Text
canonicalFields = Text.concat . map frame
 where
  frame value = Text.pack (show (Text.length value)) <> ":" <> value
