{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Lifecycle-Authority-owned durable receipt for the independently observed
-- EKS Kubernetes drain result.  The stable object coordinate excludes the
-- fenced drain attempt: downstream reconciliation can locate the receipt from
-- its run, graph, scope, registered EKS identity, and four drain operations.
-- The actual attempt is payload-bound and validated while reconstructing the
-- opaque proof.
--
-- Only canonical safe projections are retained.  Provider ARN, Kubernetes
-- UID, endpoint/CA digests, selected PVC names, bounded absence evidence, and
-- stable lifecycle identifiers are durable; bearer tokens, endpoint plaintext,
-- CA plaintext, client projections, and sessions never enter this module.
module Prodbox.ControlPlane.EksDrainReadBackReceiptRepository
  ( EksDrainReadBackReceiptSubmissionKey
  , eksDrainReadBackReceiptSubmissionKeyText
  , EksDrainReadBackReceiptIdentity
  , eksDrainReadBackReceiptIdentity
  , eksDrainReadBackReceiptIdentitySubmissionKey
  , eksDrainReadBackReceiptIdentityRunId
  , eksDrainReadBackReceiptIdentityGraphDigest
  , eksDrainReadBackReceiptIdentityScope
  , eksDrainReadBackReceiptIdentityResourceKey
  , eksDrainReadBackReceiptIdentityCoordinateDigest
  , eksDrainReadBackReceiptIdentityCommitOperationId
  , eksDrainReadBackReceiptIdentityIntentReadBackOperationId
  , eksDrainReadBackReceiptIdentityEffectOperationId
  , eksDrainReadBackReceiptIdentityDrainReadBackOperationId
  , EksDrainReadBackEvidenceDigest
  , eksDrainReadBackEvidenceDigestText
  , EksDrainReadBackReceiptDigest
  , eksDrainReadBackReceiptDigestText
  , EksDrainReadBackReceiptCommitRequest
  , prepareEksDrainReadBackReceiptCommitRequest
  , recoverEksDrainReadBackReceiptCommitRequest
  , recoverCommittedEksDrainReadBackReceipt
  , eksDrainReadBackReceiptCommitRequestIdentity
  , eksDrainReadBackReceiptCommitRequestAttemptId
  , eksDrainReadBackReceiptCommitRequestEvidenceDigest
  , eksDrainReadBackReceiptCommitRequestReceiptDigest
  , eksDrainReadBackReceiptCommitRequestBytes
  , EksDrainReadBackReceiptCommitResult (..)
  , EksDrainReadBackReceiptObservation (..)
  , EksDrainReadBackReceiptRepository (..)
  , CommittedEksDrainReadBackReceipt
  , committedEksDrainReadBackReceiptIdentity
  , committedEksDrainReadBackReceiptAttemptId
  , committedEksDrainReadBackReceiptEvidenceDigest
  , committedEksDrainReadBackReceiptDigest
  , committedEksDrainReadBackReceiptBytes
  , committedEksDrainTargetsAbsentEvidence
  , commitPreparedAndReadBackEksDrainTargetsAbsentReceipt
  , commitAndReadBackEksDrainTargetsAbsentReceipt
  , readBackCommittedEksDrainTargetsAbsentReceipt
  , EksDrainReadBackReceiptError (..)
  , eksDrainReadBackReceiptMaximumBytes
  , eksDrainReadBackReceiptAuthorityLogicalName
  , eksDrainReadBackReceiptModelBCodec
  , modelBEksDrainReadBackReceiptRepository
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.EksDrainIntentRepository
  ( EksDrainIntentAuthorityIdentity
  , eksDrainIntentAuthorityCommitOperationId
  , eksDrainIntentAuthorityCoordinateDigest
  , eksDrainIntentAuthorityDrainReadBackOperationId
  , eksDrainIntentAuthorityEffectOperationId
  , eksDrainIntentAuthorityGraphDigest
  , eksDrainIntentAuthorityIdentity
  , eksDrainIntentAuthorityReadBackOperationId
  , eksDrainIntentAuthorityResourceKey
  , eksDrainIntentAuthorityRunId
  , eksDrainIntentAuthorityScope
  , eksDrainIntentAuthoritySubmissionKey
  , eksDrainIntentSubmissionKeyText
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
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupOperationId
  , CleanupRunId
  , cleanupAttemptIdText
  , cleanupDigestText
  , cleanupOperationIdText
  , cleanupRunIdText
  , mkCleanupAttemptId
  , mkCleanupDigest
  , mkCleanupOperationId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.Teardown.EksDrainIntent
  ( CommittedEksDrainIntent
  , EksDrainAttemptEvidence
  , EksDrainAttemptOutcome (..)
  , EksDrainIntentError
  , EksDrainKubernetesTargetReadBack (..)
  , EksDrainPvcReadBack (..)
  , EksDrainPvcReadBackResult (..)
  , EksDrainResourceClassReadBack (..)
  , EksDrainTargetReadBackObservation (..)
  , EksDrainTargetReadBackResult (..)
  , EksDrainTargetsAbsentEvidence
  , IngressClassReadBack (..)
  , LoadBalancerServiceClassReadBack (..)
  , beginEksDrainAttempt
  , committedEksDrainIntent
  , committedEksDrainIntentDigest
  , confirmEksDrainTargetsAbsent
  , eksDrainAttemptEvidenceAttemptId
  , eksDrainAttemptIntent
  , eksDrainAttemptIntentDigest
  , eksDrainAttemptObservationFor
  , eksDrainAttemptOutcome
  , eksDrainIntentDigestText
  , eksDrainTargetReadBackObservationFor
  , eksDrainTargetsAbsentEffectAttemptId
  , eksNamespacedNameName
  , eksNamespacedNameNamespace
  , maximumEksDrainPvcTargets
  , mkEksNamespacedName
  , recordEksDrainAttempt
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
  ( AbsenceEvidence (..)
  )

newtype EksDrainReadBackReceiptSubmissionKey
  = EksDrainReadBackReceiptSubmissionKey Text
  deriving stock (Eq, Ord, Show)

eksDrainReadBackReceiptSubmissionKeyText
  :: EksDrainReadBackReceiptSubmissionKey -> Text
eksDrainReadBackReceiptSubmissionKeyText
  (EksDrainReadBackReceiptSubmissionKey value) = value

-- | Stable lookup coordinate.  It deliberately contains no cleanup attempt.
newtype EksDrainReadBackReceiptIdentity = EksDrainReadBackReceiptIdentity
  { internalEksDrainReadBackReceiptIntentIdentity
      :: EksDrainIntentAuthorityIdentity
  }
  deriving stock (Eq, Show)

eksDrainReadBackReceiptIdentity
  :: CommittedEksDrainIntent -> EksDrainReadBackReceiptIdentity
eksDrainReadBackReceiptIdentity =
  EksDrainReadBackReceiptIdentity
    . eksDrainIntentAuthorityIdentity
    . committedEksDrainIntent

eksDrainReadBackReceiptIdentitySubmissionKey
  :: EksDrainReadBackReceiptIdentity
  -> EksDrainReadBackReceiptSubmissionKey
eksDrainReadBackReceiptIdentitySubmissionKey identity =
  EksDrainReadBackReceiptSubmissionKey
    ( "eks-drain-readback-receipt-v1-"
        <> sha256Text
          ( "prodbox.eks-drain-readback-receipt-key/v1\NUL"
              <> eksDrainIntentSubmissionKeyText
                ( eksDrainIntentAuthoritySubmissionKey
                    (internalEksDrainReadBackReceiptIntentIdentity identity)
                )
          )
    )

eksDrainReadBackReceiptIdentityRunId
  :: EksDrainReadBackReceiptIdentity -> CleanupRunId
eksDrainReadBackReceiptIdentityRunId =
  eksDrainIntentAuthorityRunId . internalEksDrainReadBackReceiptIntentIdentity

eksDrainReadBackReceiptIdentityGraphDigest
  :: EksDrainReadBackReceiptIdentity -> CleanupDigest
eksDrainReadBackReceiptIdentityGraphDigest =
  eksDrainIntentAuthorityGraphDigest
    . internalEksDrainReadBackReceiptIntentIdentity

eksDrainReadBackReceiptIdentityScope
  :: EksDrainReadBackReceiptIdentity -> ObservationEvidenceScope
eksDrainReadBackReceiptIdentityScope =
  eksDrainIntentAuthorityScope . internalEksDrainReadBackReceiptIntentIdentity

eksDrainReadBackReceiptIdentityResourceKey
  :: EksDrainReadBackReceiptIdentity -> RegisteredResourceKey
eksDrainReadBackReceiptIdentityResourceKey =
  eksDrainIntentAuthorityResourceKey
    . internalEksDrainReadBackReceiptIntentIdentity

eksDrainReadBackReceiptIdentityCoordinateDigest
  :: EksDrainReadBackReceiptIdentity -> ManagedResourceCoordinateDigest
eksDrainReadBackReceiptIdentityCoordinateDigest =
  eksDrainIntentAuthorityCoordinateDigest
    . internalEksDrainReadBackReceiptIntentIdentity

eksDrainReadBackReceiptIdentityCommitOperationId
  :: EksDrainReadBackReceiptIdentity -> CleanupOperationId
eksDrainReadBackReceiptIdentityCommitOperationId =
  eksDrainIntentAuthorityCommitOperationId
    . internalEksDrainReadBackReceiptIntentIdentity

eksDrainReadBackReceiptIdentityIntentReadBackOperationId
  :: EksDrainReadBackReceiptIdentity -> CleanupOperationId
eksDrainReadBackReceiptIdentityIntentReadBackOperationId =
  eksDrainIntentAuthorityReadBackOperationId
    . internalEksDrainReadBackReceiptIntentIdentity

eksDrainReadBackReceiptIdentityEffectOperationId
  :: EksDrainReadBackReceiptIdentity -> CleanupOperationId
eksDrainReadBackReceiptIdentityEffectOperationId =
  eksDrainIntentAuthorityEffectOperationId
    . internalEksDrainReadBackReceiptIntentIdentity

eksDrainReadBackReceiptIdentityDrainReadBackOperationId
  :: EksDrainReadBackReceiptIdentity -> CleanupOperationId
eksDrainReadBackReceiptIdentityDrainReadBackOperationId =
  eksDrainIntentAuthorityDrainReadBackOperationId
    . internalEksDrainReadBackReceiptIntentIdentity

newtype EksDrainReadBackEvidenceDigest = EksDrainReadBackEvidenceDigest Text
  deriving stock (Eq, Ord, Show)

eksDrainReadBackEvidenceDigestText :: EksDrainReadBackEvidenceDigest -> Text
eksDrainReadBackEvidenceDigestText (EksDrainReadBackEvidenceDigest value) = value

newtype EksDrainReadBackReceiptDigest = EksDrainReadBackReceiptDigest Text
  deriving stock (Eq, Ord, Show)

eksDrainReadBackReceiptDigestText :: EksDrainReadBackReceiptDigest -> Text
eksDrainReadBackReceiptDigestText (EksDrainReadBackReceiptDigest value) = value

data EksDrainReadBackReceiptCommitRequest = EksDrainReadBackReceiptCommitRequest
  { internalReceiptCommitRequestIdentity :: !EksDrainReadBackReceiptIdentity
  , internalReceiptCommitRequestAttemptId :: !CleanupAttemptId
  , internalReceiptCommitRequestEvidenceDigest
      :: !EksDrainReadBackEvidenceDigest
  , internalReceiptCommitRequestReceiptDigest :: !EksDrainReadBackReceiptDigest
  , internalReceiptCommitRequestBytes :: !ByteString
  }
  deriving stock (Eq)

eksDrainReadBackReceiptCommitRequestIdentity
  :: EksDrainReadBackReceiptCommitRequest
  -> EksDrainReadBackReceiptIdentity
eksDrainReadBackReceiptCommitRequestIdentity = internalReceiptCommitRequestIdentity

eksDrainReadBackReceiptCommitRequestAttemptId
  :: EksDrainReadBackReceiptCommitRequest -> CleanupAttemptId
eksDrainReadBackReceiptCommitRequestAttemptId = internalReceiptCommitRequestAttemptId

eksDrainReadBackReceiptCommitRequestEvidenceDigest
  :: EksDrainReadBackReceiptCommitRequest
  -> EksDrainReadBackEvidenceDigest
eksDrainReadBackReceiptCommitRequestEvidenceDigest =
  internalReceiptCommitRequestEvidenceDigest

eksDrainReadBackReceiptCommitRequestReceiptDigest
  :: EksDrainReadBackReceiptCommitRequest
  -> EksDrainReadBackReceiptDigest
eksDrainReadBackReceiptCommitRequestReceiptDigest =
  internalReceiptCommitRequestReceiptDigest

eksDrainReadBackReceiptCommitRequestBytes
  :: EksDrainReadBackReceiptCommitRequest -> ByteString
eksDrainReadBackReceiptCommitRequestBytes = internalReceiptCommitRequestBytes

-- | Revalidate the opaque proof inputs before any bytes can reach Authority
-- storage.  The exact attempt and read-back result are encoded only after the
-- public smart constructors reproduce positive absence evidence.
prepareEksDrainReadBackReceiptCommitRequest
  :: CommittedEksDrainIntent
  -> EksDrainAttemptEvidence
  -> EksDrainTargetReadBackObservation
  -> Either EksDrainReadBackReceiptError EksDrainReadBackReceiptCommitRequest
prepareEksDrainReadBackReceiptCommitRequest committed attempt observation = do
  let expectedIntent = committedEksDrainIntent committed
  if eksDrainAttemptIntent attempt == expectedIntent
    && eksDrainAttemptIntentDigest attempt == committedEksDrainIntentDigest committed
    then Right ()
    else Left EksDrainReadBackReceiptAttemptIntentMismatch
  _ <- first EksDrainReadBackReceiptProofInvalid (confirmEksDrainTargetsAbsent attempt observation)
  outcomeWire <- encodeOutcome (eksDrainAttemptOutcome attempt)
  readBackWire <- positiveReadBackWire observation
  validateReadBackWire readBackWire
  let identity = eksDrainReadBackReceiptIdentity committed
      evidenceDigest = evidenceDigestFor readBackWire
      envelope =
        EksDrainReadBackReceiptEnvelope
          receiptFormatVersion
          (identityWire identity)
          (eksDrainIntentDigestText (committedEksDrainIntentDigest committed))
          (cleanupAttemptIdText (eksDrainAttemptEvidenceAttemptId attempt))
          outcomeWire
          readBackWire
          (eksDrainReadBackEvidenceDigestText evidenceDigest)
      bytes = encodeEnvelope envelope
  if ByteString.length bytes > eksDrainReadBackReceiptMaximumBytes
    then
      Left
        ( EksDrainReadBackReceiptCodecTooLarge
            (ByteString.length bytes)
            eksDrainReadBackReceiptMaximumBytes
        )
    else Right ()
  decoded <- decodeEnvelope bytes
  if decoded == envelope
    then Right ()
    else Left EksDrainReadBackReceiptCodecRoundTripMismatch
  Right
    EksDrainReadBackReceiptCommitRequest
      { internalReceiptCommitRequestIdentity = identity
      , internalReceiptCommitRequestAttemptId =
          eksDrainAttemptEvidenceAttemptId attempt
      , internalReceiptCommitRequestEvidenceDigest = evidenceDigest
      , internalReceiptCommitRequestReceiptDigest = receiptDigestFor bytes
      , internalReceiptCommitRequestBytes = bytes
      }

data EksDrainReadBackReceiptCommitResult
  = EksDrainReadBackReceiptCommitCreated
  | EksDrainReadBackReceiptCommitExactReplay
  | EksDrainReadBackReceiptCommitConflict
  | EksDrainReadBackReceiptCommitCancelled
  | EksDrainReadBackReceiptCommitResponseLost !ObservationFailure
  | EksDrainReadBackReceiptCommitUnavailable !ObservationFailure
  deriving stock (Eq, Show)

data EksDrainReadBackReceiptObservation
  = EksDrainReadBackReceiptMissing
  | EksDrainReadBackReceiptPresent !ByteString
  | EksDrainReadBackReceiptUnobservable !ObservationFailure
  | EksDrainReadBackReceiptUnbounded !Int !Int
  deriving stock (Eq, Show)

data EksDrainReadBackReceiptRepository m = EksDrainReadBackReceiptRepository
  { createOrReplayAuthorityEksDrainReadBackReceipt
      :: EksDrainReadBackReceiptCommitRequest
      -> m EksDrainReadBackReceiptCommitResult
  , independentlyReadBackAuthorityEksDrainReadBackReceipt
      :: EksDrainReadBackReceiptIdentity
      -> m EksDrainReadBackReceiptObservation
  }

data CommittedEksDrainReadBackReceipt = CommittedEksDrainReadBackReceipt
  { internalCommittedReceiptIdentity :: !EksDrainReadBackReceiptIdentity
  , internalCommittedReceiptAttemptId :: !CleanupAttemptId
  , internalCommittedReceiptEvidenceDigest :: !EksDrainReadBackEvidenceDigest
  , internalCommittedReceiptDigest :: !EksDrainReadBackReceiptDigest
  , internalCommittedReceiptBytes :: !ByteString
  , internalCommittedReceiptEvidence :: !EksDrainTargetsAbsentEvidence
  }
  deriving stock (Eq, Show)

committedEksDrainReadBackReceiptIdentity
  :: CommittedEksDrainReadBackReceipt -> EksDrainReadBackReceiptIdentity
committedEksDrainReadBackReceiptIdentity = internalCommittedReceiptIdentity

committedEksDrainReadBackReceiptAttemptId
  :: CommittedEksDrainReadBackReceipt -> CleanupAttemptId
committedEksDrainReadBackReceiptAttemptId = internalCommittedReceiptAttemptId

committedEksDrainReadBackReceiptEvidenceDigest
  :: CommittedEksDrainReadBackReceipt -> EksDrainReadBackEvidenceDigest
committedEksDrainReadBackReceiptEvidenceDigest =
  internalCommittedReceiptEvidenceDigest

committedEksDrainReadBackReceiptDigest
  :: CommittedEksDrainReadBackReceipt -> EksDrainReadBackReceiptDigest
committedEksDrainReadBackReceiptDigest = internalCommittedReceiptDigest

committedEksDrainReadBackReceiptBytes
  :: CommittedEksDrainReadBackReceipt -> ByteString
committedEksDrainReadBackReceiptBytes = internalCommittedReceiptBytes

committedEksDrainTargetsAbsentEvidence
  :: CommittedEksDrainReadBackReceipt -> EksDrainTargetsAbsentEvidence
committedEksDrainTargetsAbsentEvidence = internalCommittedReceiptEvidence

commitAndReadBackEksDrainTargetsAbsentReceipt
  :: (Monad m)
  => EksDrainReadBackReceiptRepository m
  -> CommittedEksDrainIntent
  -> EksDrainAttemptEvidence
  -> EksDrainTargetReadBackObservation
  -> m
       ( Either
           EksDrainReadBackReceiptError
           CommittedEksDrainReadBackReceipt
       )
commitAndReadBackEksDrainTargetsAbsentReceipt repository committed attempt observation =
  case prepareEksDrainReadBackReceiptCommitRequest committed attempt observation of
    Left err -> pure (Left err)
    Right request ->
      commitPreparedAndReadBackEksDrainTargetsAbsentReceipt
        repository
        committed
        request

-- | Commit a previously validated opaque request.  This is the Authority
-- endpoint seam: a wire decoder must first recover the request against the
-- independently retained committed intent with
-- 'recoverEksDrainReadBackReceiptCommitRequest'.
commitPreparedAndReadBackEksDrainTargetsAbsentReceipt
  :: (Monad m)
  => EksDrainReadBackReceiptRepository m
  -> CommittedEksDrainIntent
  -> EksDrainReadBackReceiptCommitRequest
  -> m
       ( Either
           EksDrainReadBackReceiptError
           CommittedEksDrainReadBackReceipt
       )
commitPreparedAndReadBackEksDrainTargetsAbsentReceipt repository committed request = do
  let expectedIdentity = eksDrainReadBackReceiptIdentity committed
  if eksDrainReadBackReceiptCommitRequestIdentity request /= expectedIdentity
    then pure (Left EksDrainReadBackReceiptAttemptIntentMismatch)
    else do
      commitResult <-
        createOrReplayAuthorityEksDrainReadBackReceipt repository request
      case commitResult of
        EksDrainReadBackReceiptCommitCreated -> confirm request
        EksDrainReadBackReceiptCommitExactReplay -> confirm request
        EksDrainReadBackReceiptCommitResponseLost _ -> confirm request
        other -> pure (Left (EksDrainReadBackReceiptCommitNotConfirmed other))
 where
  confirm expectedRequest = do
    observed <-
      readBackCommittedEksDrainTargetsAbsentReceipt repository committed
    pure $ do
      receipt <- observed
      if committedEksDrainReadBackReceiptAttemptId receipt
        == eksDrainReadBackReceiptCommitRequestAttemptId expectedRequest
        && committedEksDrainReadBackReceiptEvidenceDigest receipt
          == eksDrainReadBackReceiptCommitRequestEvidenceDigest expectedRequest
        && committedEksDrainReadBackReceiptDigest receipt
          == eksDrainReadBackReceiptCommitRequestReceiptDigest expectedRequest
        then Right receipt
        else Left EksDrainReadBackReceiptCommitReadBackConflict

-- | Reconstruct an opaque commit request from canonical wire bytes only after
-- the Authority has independently recovered the exact committed intent.  The
-- reconstruction remints the final absence proof before exposing a request;
-- raw bytes can never bypass intent, attempt, or evidence-digest validation.
recoverEksDrainReadBackReceiptCommitRequest
  :: CommittedEksDrainIntent
  -> ByteString
  -> Either EksDrainReadBackReceiptError EksDrainReadBackReceiptCommitRequest
recoverEksDrainReadBackReceiptCommitRequest committed bytes = do
  receipt <- recoverCommittedEksDrainReadBackReceipt committed bytes
  let identity = eksDrainReadBackReceiptIdentity committed
  Right
    EksDrainReadBackReceiptCommitRequest
      { internalReceiptCommitRequestIdentity = identity
      , internalReceiptCommitRequestAttemptId =
          committedEksDrainReadBackReceiptAttemptId receipt
      , internalReceiptCommitRequestEvidenceDigest =
          committedEksDrainReadBackReceiptEvidenceDigest receipt
      , internalReceiptCommitRequestReceiptDigest =
          committedEksDrainReadBackReceiptDigest receipt
      , internalReceiptCommitRequestBytes = bytes
      }

-- | Pure durable codec bridge used by authenticated clients after an
-- Authority response.  It revalidates the exact retained intent binding,
-- actual attempt, positive read-back digest, and canonical bytes before
-- reminting the opaque absence receipt.
recoverCommittedEksDrainReadBackReceipt
  :: CommittedEksDrainIntent
  -> ByteString
  -> Either EksDrainReadBackReceiptError CommittedEksDrainReadBackReceipt
recoverCommittedEksDrainReadBackReceipt committed =
  reconstructCommittedReceipt
    (eksDrainReadBackReceiptIdentity committed)
    committed

-- | Downstream reader.  Lookup uses only the stable identity derived from the
-- committed intent.  The payload's actual drain attempt is parsed and
-- validated while reconstructing the opaque final evidence.
readBackCommittedEksDrainTargetsAbsentReceipt
  :: (Monad m)
  => EksDrainReadBackReceiptRepository m
  -> CommittedEksDrainIntent
  -> m
       ( Either
           EksDrainReadBackReceiptError
           CommittedEksDrainReadBackReceipt
       )
readBackCommittedEksDrainTargetsAbsentReceipt repository committed = do
  let identity = eksDrainReadBackReceiptIdentity committed
  observed <-
    independentlyReadBackAuthorityEksDrainReadBackReceipt repository identity
  pure $ case observed of
    EksDrainReadBackReceiptMissing -> Left EksDrainReadBackReceiptReadBackMissing
    EksDrainReadBackReceiptUnobservable failure ->
      Left (EksDrainReadBackReceiptReadBackUnobservable failure)
    EksDrainReadBackReceiptUnbounded actual maximumAllowed ->
      Left
        ( EksDrainReadBackReceiptCodecTooLarge
            actual
            maximumAllowed
        )
    EksDrainReadBackReceiptPresent bytes ->
      reconstructCommittedReceipt identity committed bytes

data EksDrainReadBackReceiptError
  = EksDrainReadBackReceiptAttemptIntentMismatch
  | EksDrainReadBackReceiptProofInvalid !EksDrainIntentError
  | EksDrainReadBackReceiptPositiveShapeInvalid
  | EksDrainReadBackReceiptAbsenceEvidenceInvalid !Text
  | EksDrainReadBackReceiptCodecEmpty
  | EksDrainReadBackReceiptCodecTooLarge !Int !Int
  | EksDrainReadBackReceiptCodecMalformed !Text
  | EksDrainReadBackReceiptCodecNonCanonical
  | EksDrainReadBackReceiptCodecVersionUnsupported !Word16
  | EksDrainReadBackReceiptCodecRoundTripMismatch
  | EksDrainReadBackReceiptCodecTextInvalid !Text !Text
  | EksDrainReadBackReceiptCodecDigestInvalid !Text !Text
  | EksDrainReadBackReceiptCodecIdentityInvalid !Text
  | EksDrainReadBackReceiptCodecResourceKeyInvalid !Text
  | EksDrainReadBackReceiptCodecSurfaceInvalid !Word16
  | EksDrainReadBackReceiptCodecOperationInvalid !Word16
  | EksDrainReadBackReceiptCodecAwsScopeInvalid
  | EksDrainReadBackReceiptEvidenceDigestMismatch !Text !Text
  | EksDrainReadBackReceiptRunMismatch !CleanupRunId !CleanupRunId
  | EksDrainReadBackReceiptGraphMismatch !CleanupDigest !CleanupDigest
  | EksDrainReadBackReceiptScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | EksDrainReadBackReceiptResourceKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | EksDrainReadBackReceiptCoordinateMismatch !Text !Text
  | EksDrainReadBackReceiptCommitOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | EksDrainReadBackReceiptIntentReadBackOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | EksDrainReadBackReceiptEffectOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | EksDrainReadBackReceiptDrainReadBackOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | EksDrainReadBackReceiptIntentDigestMismatch !Text !Text
  | EksDrainReadBackReceiptCommitNotConfirmed
      !EksDrainReadBackReceiptCommitResult
  | EksDrainReadBackReceiptCommitReadBackConflict
  | EksDrainReadBackReceiptReadBackMissing
  | EksDrainReadBackReceiptReadBackUnobservable !ObservationFailure
  deriving stock (Eq, Show)

eksDrainReadBackReceiptMaximumBytes :: Int
eksDrainReadBackReceiptMaximumBytes = 262_144

eksDrainReadBackReceiptAuthorityLogicalName
  :: EksDrainReadBackReceiptIdentity -> Text
eksDrainReadBackReceiptAuthorityLogicalName identity =
  "authority/eks-drain-readback-receipts/"
    <> eksDrainReadBackReceiptSubmissionKeyText
      (eksDrainReadBackReceiptIdentitySubmissionKey identity)

eksDrainReadBackReceiptModelBCodec :: ModelBCodec ByteString
eksDrainReadBackReceiptModelBCodec =
  ModelBCodec
    { encodeModelBValue = first show . validateCanonicalReceiptBytes
    , decodeModelBValue = first show . validateCanonicalReceiptBytes
    }

modelBEksDrainReadBackReceiptRepository
  :: (Monad m)
  => LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> EksDrainReadBackReceiptRepository m
modelBEksDrainReadBackReceiptRepository authority adapter =
  EksDrainReadBackReceiptRepository
    { createOrReplayAuthorityEksDrainReadBackReceipt = createOrReplay
    , independentlyReadBackAuthorityEksDrainReadBackReceipt = readBack
    }
 where
  createOrReplay request =
    case coordinateFor (eksDrainReadBackReceiptCommitRequestIdentity request) of
      Left failure -> pure (EksDrainReadBackReceiptCommitUnavailable failure)
      Right coordinate -> do
        observed <- modelBObserve adapter coordinate
        case observed of
          ModelBMissing -> initialize coordinate request
          ModelBObserved _ existing ->
            pure (existingDisposition request existing)
          ModelBCorrupt detail ->
            pure (unavailable "corrupt" detail)
          ModelBEndpointUnready detail ->
            pure (unavailable "endpoint-unready" detail)
          ModelBUnobservable detail ->
            pure (unavailable "unobservable" detail)

  initialize coordinate request = do
    result <-
      modelBCompareAndSwap
        adapter
        (ModelBInitialize coordinate (eksDrainReadBackReceiptCommitRequestBytes request))
    pure $ case result of
      ModelBCasApplied _ applied
        | applied == eksDrainReadBackReceiptCommitRequestBytes request ->
            EksDrainReadBackReceiptCommitCreated
        | otherwise -> EksDrainReadBackReceiptCommitConflict
      ModelBCasConflict observation -> conflictDisposition request observation
      ModelBCasRefusedCorrupt detail -> unavailable "cas-corrupt" detail
      ModelBCasEndpointUnready detail ->
        unavailable "cas-endpoint-unready" detail
      ModelBCasUnobservable detail ->
        EksDrainReadBackReceiptCommitResponseLost
          (repositoryFailure "cas-response-unobservable" detail)

  readBack identity = case coordinateFor identity of
    Left failure -> pure (EksDrainReadBackReceiptUnobservable failure)
    Right coordinate -> do
      observed <- modelBObserve adapter coordinate
      pure $ case observed of
        ModelBMissing -> EksDrainReadBackReceiptMissing
        ModelBObserved _ bytes
          | ByteString.length bytes > eksDrainReadBackReceiptMaximumBytes ->
              EksDrainReadBackReceiptUnbounded
                (ByteString.length bytes)
                eksDrainReadBackReceiptMaximumBytes
          | otherwise -> EksDrainReadBackReceiptPresent bytes
        ModelBCorrupt detail -> unobservable "corrupt" detail
        ModelBEndpointUnready detail -> unobservable "endpoint-unready" detail
        ModelBUnobservable detail -> unobservable "unobservable" detail

  coordinateFor identity =
    first
      (repositoryFailure "coordinate" . Text.pack . show)
      ( mkClusterRetainedCoordinate
          authority
          (eksDrainReadBackReceiptAuthorityLogicalName identity)
      )
  unavailable category detail =
    EksDrainReadBackReceiptCommitUnavailable
      (repositoryFailure category detail)
  unobservable category detail =
    EksDrainReadBackReceiptUnobservable
      (repositoryFailure category detail)

existingDisposition
  :: EksDrainReadBackReceiptCommitRequest
  -> ByteString
  -> EksDrainReadBackReceiptCommitResult
existingDisposition request existing
  | existing == eksDrainReadBackReceiptCommitRequestBytes request =
      EksDrainReadBackReceiptCommitExactReplay
  | otherwise = EksDrainReadBackReceiptCommitConflict

conflictDisposition
  :: EksDrainReadBackReceiptCommitRequest
  -> ModelBObservation ByteString
  -> EksDrainReadBackReceiptCommitResult
conflictDisposition request observation = case observation of
  ModelBObserved _ existing -> existingDisposition request existing
  ModelBMissing -> unavailable "conflict-missing" "conflict observation was missing"
  ModelBCorrupt detail -> unavailable "conflict-corrupt" detail
  ModelBEndpointUnready detail -> unavailable "conflict-endpoint-unready" detail
  ModelBUnobservable detail -> unavailable "conflict-unobservable" detail
 where
  unavailable category detail =
    EksDrainReadBackReceiptCommitUnavailable
      (repositoryFailure category detail)

data EksDrainReadBackReceiptEnvelope
  = EksDrainReadBackReceiptEnvelope
      !Word16
      !ReceiptIdentityWire
      !Text
      !Text
      !AttemptOutcomeWire
      !PositiveReadBackWire
      !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ReceiptIdentityWire
  = ReceiptIdentityWire
      !Text
      !Text
      !ReceiptScopeWire
      !Text
      !Text
      !Text
      !Text
      !Text
      !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ReceiptScopeWire
  = ReceiptScopeWire
      !Word16
      !Text
      !Text
      !Text
      !(Maybe Text)
      !(Maybe Text)
      !Word16
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AttemptOutcomeWire
  = AttemptAppliedWire
  | AttemptFailedWire
  | AttemptUnobservableWire
  | AttemptSkippedNoTargetWire
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data PositiveReadBackWire
  = KubernetesTargetsAbsentWire
      !Text
      !Text
      !Text
      !Text
      !Text
      !Text
      ![PvcAbsenceWire]
  | NoKubernetesTargetWire
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data PvcAbsenceWire = PvcAbsenceWire !Text !Text !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data DecodedReceiptIdentity = DecodedReceiptIdentity
  { decodedReceiptRunId :: !CleanupRunId
  , decodedReceiptGraphDigest :: !CleanupDigest
  , decodedReceiptScope :: !ObservationEvidenceScope
  , decodedReceiptResourceKey :: !RegisteredResourceKey
  , decodedReceiptCoordinateDigest :: !Text
  , decodedReceiptCommitOperation :: !CleanupOperationId
  , decodedReceiptIntentReadBackOperation :: !CleanupOperationId
  , decodedReceiptEffectOperation :: !CleanupOperationId
  , decodedReceiptDrainReadBackOperation :: !CleanupOperationId
  }

receiptFormatVersion :: Word16
receiptFormatVersion = 1

identityWire :: EksDrainReadBackReceiptIdentity -> ReceiptIdentityWire
identityWire identity =
  ReceiptIdentityWire
    (cleanupRunIdText (eksDrainReadBackReceiptIdentityRunId identity))
    (cleanupDigestText (eksDrainReadBackReceiptIdentityGraphDigest identity))
    (scopeWire (eksDrainReadBackReceiptIdentityScope identity))
    (registeredResourceKeyText (eksDrainReadBackReceiptIdentityResourceKey identity))
    ( managedResourceCoordinateDigestText
        (eksDrainReadBackReceiptIdentityCoordinateDigest identity)
    )
    (cleanupOperationIdText (eksDrainReadBackReceiptIdentityCommitOperationId identity))
    ( cleanupOperationIdText
        (eksDrainReadBackReceiptIdentityIntentReadBackOperationId identity)
    )
    (cleanupOperationIdText (eksDrainReadBackReceiptIdentityEffectOperationId identity))
    ( cleanupOperationIdText
        (eksDrainReadBackReceiptIdentityDrainReadBackOperationId identity)
    )

scopeWire :: ObservationEvidenceScope -> ReceiptScopeWire
scopeWire scope =
  ReceiptScopeWire
    (encodeSurface (evidenceCleanupSurface scope))
    (registryRevisionText (evidenceRegistryRevision scope))
    (durableRunScopeText (evidenceDurableRunScope scope))
    (foundationIdText (evidenceLinuxRke2Foundation scope))
    account
    region
    (encodeOperation (evidenceLifecycleOperation scope))
 where
  (account, region) = case evidenceAwsScope scope of
    Nothing -> (Nothing, Nothing)
    Just (AwsScope (AwsAccountId accountId) (AwsRegion regionId)) ->
      (Just accountId, Just regionId)

encodeOutcome
  :: EksDrainAttemptOutcome
  -> Either EksDrainReadBackReceiptError AttemptOutcomeWire
encodeOutcome outcome = case outcome of
  EksDrainMutationApplied -> Right AttemptAppliedWire
  -- Diagnostic text is not proof identity and may contain unsafe provider
  -- detail. Retain the exact outcome constructor only; reconstruction uses a
  -- fixed Authority-owned explanation and never parses diagnostics.
  EksDrainMutationFailed _ -> Right AttemptFailedWire
  EksDrainMutationUnobservable _ -> Right AttemptUnobservableWire
  EksDrainSkippedNoKubernetesTarget -> Right AttemptSkippedNoTargetWire

decodeOutcome
  :: AttemptOutcomeWire
  -> Either EksDrainReadBackReceiptError EksDrainAttemptOutcome
decodeOutcome wire = case wire of
  AttemptAppliedWire -> Right EksDrainMutationApplied
  AttemptFailedWire ->
    Right
      ( EksDrainMutationFailed
          (ObservationFailure "durable EKS drain attempt failed")
      )
  AttemptUnobservableWire ->
    Right
      ( EksDrainMutationUnobservable
          (ObservationFailure "durable EKS drain attempt effect was unobservable")
      )
  AttemptSkippedNoTargetWire -> Right EksDrainSkippedNoKubernetesTarget

positiveReadBackWire
  :: EksDrainTargetReadBackObservation
  -> Either EksDrainReadBackReceiptError PositiveReadBackWire
positiveReadBackWire observation =
  case eksDrainTargetReadBackResult observation of
    EksDrainObservedNoKubernetesTarget -> Right NoKubernetesTargetWire
    EksDrainObservedKubernetesTarget readBack -> do
      serviceEvidence <- case eksDrainReadBackLoadBalancerServiceClass readBack of
        LoadBalancerServiceClassReadBack
          (EksDrainResourceClassAbsent (AbsenceEvidence detail)) ->
            boundedAbsence detail
        _ -> Left EksDrainReadBackReceiptPositiveShapeInvalid
      ingressEvidence <- case eksDrainReadBackIngressClass readBack of
        IngressClassReadBack
          (EksDrainResourceClassAbsent (AbsenceEvidence detail)) ->
            boundedAbsence detail
        _ -> Left EksDrainReadBackReceiptPositiveShapeInvalid
      pvcs <- mapM pvcWire (eksDrainReadBackDeletePolicyPvcs readBack)
      Right
        ( KubernetesTargetsAbsentWire
            (eksDrainReadBackProviderArn readBack)
            (eksDrainReadBackKubernetesUid readBack)
            (eksDrainReadBackEndpointDigest readBack)
            (eksDrainReadBackCertificateAuthorityDigest readBack)
            serviceEvidence
            ingressEvidence
            pvcs
        )
    EksDrainTargetReadBackUnobservable _ ->
      Left EksDrainReadBackReceiptPositiveShapeInvalid
 where
  pvcWire pvc = case eksDrainPvcReadBackResult pvc of
    EksDrainPvcAbsent (AbsenceEvidence detail) -> do
      absence <- boundedAbsence detail
      Right
        ( PvcAbsenceWire
            (eksNamespacedNameNamespace (eksDrainPvcReadBackTarget pvc))
            (eksNamespacedNameName (eksDrainPvcReadBackTarget pvc))
            absence
        )
    _ -> Left EksDrainReadBackReceiptPositiveShapeInvalid

  boundedAbsence detail
    | Text.null detail || Text.length detail > 512 =
        Left (EksDrainReadBackReceiptAbsenceEvidenceInvalid detail)
    | otherwise = Right detail

validateReadBackWire
  :: PositiveReadBackWire -> Either EksDrainReadBackReceiptError ()
validateReadBackWire wire = case wire of
  NoKubernetesTargetWire -> Right ()
  KubernetesTargetsAbsentWire arn uid endpointDigest caDigest service ingress pvcs -> do
    validateBoundedText "provider ARN" 2048 arn
    validateBoundedText "Kubernetes UID" 256 uid
    validateSha256 "endpoint digest" endpointDigest
    validateSha256 "certificate-authority digest" caDigest
    validateAbsence service
    validateAbsence ingress
    if length pvcs <= maximumEksDrainPvcTargets
      then Right ()
      else
        Left
          ( EksDrainReadBackReceiptCodecTextInvalid
              "PVC target count"
              (Text.pack (show (length pvcs)))
          )
    mapM_ validatePvcWire pvcs
 where
  validateAbsence detail
    | Text.null detail || Text.length detail > 512 =
        Left (EksDrainReadBackReceiptAbsenceEvidenceInvalid detail)
    | otherwise = Right ()
  validatePvcWire (PvcAbsenceWire namespace name absence) = do
    _ <- first EksDrainReadBackReceiptProofInvalid (mkEksNamespacedName namespace name)
    validateAbsence absence

reconstructCommittedReceipt
  :: EksDrainReadBackReceiptIdentity
  -> CommittedEksDrainIntent
  -> ByteString
  -> Either EksDrainReadBackReceiptError CommittedEksDrainReadBackReceipt
reconstructCommittedReceipt expectedIdentity committed bytes = do
  envelope@( EksDrainReadBackReceiptEnvelope
               _
               wireIdentity
               intentDigest
               attemptText
               outcomeWire
               readBackWire
               storedEvidenceDigest
             ) <-
    decodeEnvelope bytes
  decodedIdentity <- decodeIdentityWire wireIdentity
  validateIdentity expectedIdentity decodedIdentity
  let expectedIntentDigest =
        eksDrainIntentDigestText (committedEksDrainIntentDigest committed)
  if intentDigest == expectedIntentDigest
    then Right ()
    else
      Left
        ( EksDrainReadBackReceiptIntentDigestMismatch
            expectedIntentDigest
            intentDigest
        )
  attemptId <-
    mapIdentityError
      (const (EksDrainReadBackReceiptCodecIdentityInvalid "attempt"))
      (mkCleanupAttemptId attemptText)
  outcome <- decodeOutcome outcomeWire
  validateReadBackWire readBackWire
  let actualEvidenceDigest = evidenceDigestFor readBackWire
      actualEvidenceDigestText =
        eksDrainReadBackEvidenceDigestText actualEvidenceDigest
  if storedEvidenceDigest == actualEvidenceDigestText
    then Right ()
    else
      Left
        ( EksDrainReadBackReceiptEvidenceDigestMismatch
            storedEvidenceDigest
            actualEvidenceDigestText
        )
  let begun = beginEksDrainAttempt committed attemptId
  attemptEvidence <-
    first
      EksDrainReadBackReceiptProofInvalid
      ( recordEksDrainAttempt
          begun
          (eksDrainAttemptObservationFor begun outcome)
      )
  readBackResult <- decodePositiveReadBack readBackWire
  evidence <-
    first
      EksDrainReadBackReceiptProofInvalid
      ( confirmEksDrainTargetsAbsent
          attemptEvidence
          (eksDrainTargetReadBackObservationFor attemptEvidence readBackResult)
      )
  if eksDrainTargetsAbsentEffectAttemptId evidence == attemptId
    then Right ()
    else Left EksDrainReadBackReceiptCommitReadBackConflict
  Right
    CommittedEksDrainReadBackReceipt
      { internalCommittedReceiptIdentity = expectedIdentity
      , internalCommittedReceiptAttemptId = attemptId
      , internalCommittedReceiptEvidenceDigest = actualEvidenceDigest
      , internalCommittedReceiptDigest = receiptDigestFor (encodeEnvelope envelope)
      , internalCommittedReceiptBytes = bytes
      , internalCommittedReceiptEvidence = evidence
      }

decodePositiveReadBack
  :: PositiveReadBackWire
  -> Either EksDrainReadBackReceiptError EksDrainTargetReadBackResult
decodePositiveReadBack wire = case wire of
  NoKubernetesTargetWire -> Right EksDrainObservedNoKubernetesTarget
  KubernetesTargetsAbsentWire arn uid endpointDigest caDigest service ingress pvcs -> do
    decodedPvcs <- mapM decodePvc pvcs
    Right
      ( EksDrainObservedKubernetesTarget
          EksDrainKubernetesTargetReadBack
            { eksDrainReadBackProviderArn = arn
            , eksDrainReadBackKubernetesUid = uid
            , eksDrainReadBackEndpointDigest = endpointDigest
            , eksDrainReadBackCertificateAuthorityDigest = caDigest
            , eksDrainReadBackLoadBalancerServiceClass =
                LoadBalancerServiceClassReadBack
                  (EksDrainResourceClassAbsent (AbsenceEvidence service))
            , eksDrainReadBackIngressClass =
                IngressClassReadBack
                  (EksDrainResourceClassAbsent (AbsenceEvidence ingress))
            , eksDrainReadBackDeletePolicyPvcs = decodedPvcs
            }
      )
 where
  decodePvc (PvcAbsenceWire namespace name absence) = do
    target <- first EksDrainReadBackReceiptProofInvalid (mkEksNamespacedName namespace name)
    Right
      EksDrainPvcReadBack
        { eksDrainPvcReadBackTarget = target
        , eksDrainPvcReadBackResult =
            EksDrainPvcAbsent (AbsenceEvidence absence)
        }

decodeEnvelope
  :: ByteString
  -> Either EksDrainReadBackReceiptError EksDrainReadBackReceiptEnvelope
decodeEnvelope bytes
  | ByteString.null bytes = Left EksDrainReadBackReceiptCodecEmpty
  | ByteString.length bytes > eksDrainReadBackReceiptMaximumBytes =
      Left
        ( EksDrainReadBackReceiptCodecTooLarge
            (ByteString.length bytes)
            eksDrainReadBackReceiptMaximumBytes
        )
  | otherwise = do
      envelope <-
        first
          (EksDrainReadBackReceiptCodecMalformed . Text.pack . show)
          (deserialiseOrFail (LazyByteString.fromStrict bytes))
      if encodeEnvelope envelope == bytes
        then Right ()
        else Left EksDrainReadBackReceiptCodecNonCanonical
      validateEnvelope envelope
      Right envelope

validateEnvelope
  :: EksDrainReadBackReceiptEnvelope
  -> Either EksDrainReadBackReceiptError ()
validateEnvelope
  ( EksDrainReadBackReceiptEnvelope
      version
      wireIdentity
      intentDigest
      attempt
      outcome
      readBack
      evidenceDigest
    ) = do
    if version == receiptFormatVersion
      then Right ()
      else Left (EksDrainReadBackReceiptCodecVersionUnsupported version)
    _ <- decodeIdentityWire wireIdentity
    validateSha256 "intent digest" intentDigest
    _ <-
      mapIdentityError
        (const (EksDrainReadBackReceiptCodecIdentityInvalid "attempt"))
        (mkCleanupAttemptId attempt)
    _ <- decodeOutcome outcome
    validateReadBackWire readBack
    validateSha256 "read-back evidence digest" evidenceDigest
    let actual = eksDrainReadBackEvidenceDigestText (evidenceDigestFor readBack)
    if evidenceDigest == actual
      then Right ()
      else
        Left
          ( EksDrainReadBackReceiptEvidenceDigestMismatch
              evidenceDigest
              actual
          )

decodeIdentityWire
  :: ReceiptIdentityWire
  -> Either EksDrainReadBackReceiptError DecodedReceiptIdentity
decodeIdentityWire
  ( ReceiptIdentityWire
      runText
      graphText
      scopeValue
      keyText
      coordinateText
      commitText
      intentReadBackText
      effectText
      drainReadBackText
    ) = do
    runId <- mapIdentity "run" mkCleanupRunId runText
    graphDigest <- mapIdentity "graph" mkCleanupDigest graphText
    scope <- decodeScopeWire scopeValue
    key <- decodeResourceKey keyText
    validateSha256 "coordinate digest" coordinateText
    commitOperation <- mapIdentity "intent commit operation" mkCleanupOperationId commitText
    intentReadBackOperation <-
      mapIdentity "intent read-back operation" mkCleanupOperationId intentReadBackText
    effectOperation <- mapIdentity "drain effect operation" mkCleanupOperationId effectText
    drainReadBackOperation <-
      mapIdentity "drain read-back operation" mkCleanupOperationId drainReadBackText
    Right
      DecodedReceiptIdentity
        { decodedReceiptRunId = runId
        , decodedReceiptGraphDigest = graphDigest
        , decodedReceiptScope = scope
        , decodedReceiptResourceKey = key
        , decodedReceiptCoordinateDigest = coordinateText
        , decodedReceiptCommitOperation = commitOperation
        , decodedReceiptIntentReadBackOperation = intentReadBackOperation
        , decodedReceiptEffectOperation = effectOperation
        , decodedReceiptDrainReadBackOperation = drainReadBackOperation
        }
   where
    mapIdentity label constructor raw =
      mapIdentityError
        (const (EksDrainReadBackReceiptCodecIdentityInvalid label))
        (constructor raw)

decodeScopeWire
  :: ReceiptScopeWire
  -> Either EksDrainReadBackReceiptError ObservationEvidenceScope
decodeScopeWire
  ( ReceiptScopeWire
      surfaceTag
      registryRevision
      runScope
      foundation
      maybeAccount
      maybeRegion
      operationTag
    ) = do
    surface <- decodeSurface surfaceTag
    operation <- decodeOperation operationTag
    validateBoundedText "registry revision" 256 registryRevision
    validateBoundedText "durable run scope" 256 runScope
    validateBoundedText "foundation" 256 foundation
    awsScope <- case (maybeAccount, maybeRegion) of
      (Just account, Just region) -> do
        validateAwsAccount account
        validateAwsRegion region
        Right (Just (AwsScope (AwsAccountId account) (AwsRegion region)))
      (Nothing, Nothing) -> Right Nothing
      _ -> Left EksDrainReadBackReceiptCodecAwsScopeInvalid
    Right
      ( mkObservationEvidenceScope
          surface
          (RegistryRevision registryRevision)
          (DurableObservationRunScope runScope)
          (LinuxRke2FoundationId foundation)
          awsScope
          operation
      )

validateIdentity
  :: EksDrainReadBackReceiptIdentity
  -> DecodedReceiptIdentity
  -> Either EksDrainReadBackReceiptError ()
validateIdentity expected actual = do
  requireEqual
    EksDrainReadBackReceiptRunMismatch
    (eksDrainReadBackReceiptIdentityRunId expected)
    (decodedReceiptRunId actual)
  requireEqual
    EksDrainReadBackReceiptGraphMismatch
    (eksDrainReadBackReceiptIdentityGraphDigest expected)
    (decodedReceiptGraphDigest actual)
  requireEqual
    EksDrainReadBackReceiptScopeMismatch
    (eksDrainReadBackReceiptIdentityScope expected)
    (decodedReceiptScope actual)
  requireEqual
    EksDrainReadBackReceiptResourceKeyMismatch
    (eksDrainReadBackReceiptIdentityResourceKey expected)
    (decodedReceiptResourceKey actual)
  requireEqual
    EksDrainReadBackReceiptCoordinateMismatch
    ( managedResourceCoordinateDigestText
        (eksDrainReadBackReceiptIdentityCoordinateDigest expected)
    )
    (decodedReceiptCoordinateDigest actual)
  requireEqual
    EksDrainReadBackReceiptCommitOperationMismatch
    (eksDrainReadBackReceiptIdentityCommitOperationId expected)
    (decodedReceiptCommitOperation actual)
  requireEqual
    EksDrainReadBackReceiptIntentReadBackOperationMismatch
    (eksDrainReadBackReceiptIdentityIntentReadBackOperationId expected)
    (decodedReceiptIntentReadBackOperation actual)
  requireEqual
    EksDrainReadBackReceiptEffectOperationMismatch
    (eksDrainReadBackReceiptIdentityEffectOperationId expected)
    (decodedReceiptEffectOperation actual)
  requireEqual
    EksDrainReadBackReceiptDrainReadBackOperationMismatch
    (eksDrainReadBackReceiptIdentityDrainReadBackOperationId expected)
    (decodedReceiptDrainReadBackOperation actual)

validateCanonicalReceiptBytes
  :: ByteString -> Either EksDrainReadBackReceiptError ByteString
validateCanonicalReceiptBytes bytes = do
  envelope <- decodeEnvelope bytes
  if encodeEnvelope envelope == bytes
    then Right bytes
    else Left EksDrainReadBackReceiptCodecNonCanonical

encodeEnvelope :: EksDrainReadBackReceiptEnvelope -> ByteString
encodeEnvelope = LazyByteString.toStrict . serialise

evidenceDigestFor :: PositiveReadBackWire -> EksDrainReadBackEvidenceDigest
evidenceDigestFor =
  EksDrainReadBackEvidenceDigest
    . sha256Bytes
    . LazyByteString.toStrict
    . serialise

receiptDigestFor :: ByteString -> EksDrainReadBackReceiptDigest
receiptDigestFor = EksDrainReadBackReceiptDigest . sha256Bytes

decodeResourceKey
  :: Text -> Either EksDrainReadBackReceiptError RegisteredResourceKey
decodeResourceKey raw = case raw of
  "local-linux-rke2" -> Right LocalLinuxRke2Key
  "aws-eks" -> Right AwsEksKey
  "aws-eks-subzone" -> Right AwsEksSubzoneKey
  "aws-test" -> Right AwsTestKey
  "aws-ebs-volumes-per-run-test" -> Right AwsEbsPerRunTestKey
  "aws-ebs-volumes-production-retained" -> Right AwsEbsProductionRetainedKey
  _ -> Left (EksDrainReadBackReceiptCodecResourceKeyInvalid raw)

encodeSurface :: CleanupSurface -> Word16
encodeSurface surface = case surface of
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

decodeSurface
  :: Word16 -> Either EksDrainReadBackReceiptError CleanupSurface
decodeSurface tag = case tag of
  1 -> Right Cascade
  2 -> Right ExplicitPerRun
  3 -> Right TotalDecommission
  _ -> Left (EksDrainReadBackReceiptCodecSurfaceInvalid tag)

encodeOperation :: LifecycleOperation -> Word16
encodeOperation operation = case operation of
  ReconcileDesiredAbsent -> 1
  ReconcileDesiredPresent -> reconcileDesiredPresentOperationTag
  RunTerminalEscapeAudit -> runTerminalEscapeAuditOperationTag

reconcileDesiredPresentOperationTag, runTerminalEscapeAuditOperationTag :: Word16
reconcileDesiredPresentOperationTag = 101
runTerminalEscapeAuditOperationTag = 102

decodeOperation
  :: Word16 -> Either EksDrainReadBackReceiptError LifecycleOperation
decodeOperation tag = case tag of
  1 -> Right ReconcileDesiredAbsent
  _ -> Left (EksDrainReadBackReceiptCodecOperationInvalid tag)

validateBoundedText
  :: Text -> Int -> Text -> Either EksDrainReadBackReceiptError ()
validateBoundedText label maximumLength value
  | Text.null value || Text.length value > maximumLength =
      Left (EksDrainReadBackReceiptCodecTextInvalid label value)
  | otherwise = Right ()

validateSha256
  :: Text -> Text -> Either EksDrainReadBackReceiptError ()
validateSha256 label value
  | Text.length value == 64 && Text.all isLowerHex value = Right ()
  | otherwise = Left (EksDrainReadBackReceiptCodecDigestInvalid label value)
 where
  isLowerHex character = character `elem` ("0123456789abcdef" :: String)

validateAwsAccount :: Text -> Either EksDrainReadBackReceiptError ()
validateAwsAccount value
  | Text.length value == 12 && Text.all isDigit value = Right ()
  | otherwise = Left (EksDrainReadBackReceiptCodecTextInvalid "AWS account" value)

validateAwsRegion :: Text -> Either EksDrainReadBackReceiptError ()
validateAwsRegion value
  | Text.null value || Text.length value > 64 =
      Left (EksDrainReadBackReceiptCodecTextInvalid "AWS region" value)
  | Text.all valid value = Right ()
  | otherwise = Left (EksDrainReadBackReceiptCodecTextInvalid "AWS region" value)
 where
  valid character = isAsciiLower character || isDigit character || character == '-'

mapIdentityError
  :: (Text -> EksDrainReadBackReceiptError)
  -> Either Text value
  -> Either EksDrainReadBackReceiptError value
mapIdentityError wrap = either (Left . wrap) Right

requireEqual
  :: (Eq value)
  => (value -> value -> EksDrainReadBackReceiptError)
  -> value
  -> value
  -> Either EksDrainReadBackReceiptError ()
requireEqual mismatch expected actual
  | expected == actual = Right ()
  | otherwise = Left (mismatch expected actual)

repositoryFailure :: Text -> Text -> ObservationFailure
repositoryFailure category detail =
  ObservationFailure
    ("EKS drain read-back receipt Authority " <> category <> ": " <> detail)

sha256Text :: Text -> Text
sha256Text = sha256Bytes . TextEncoding.encodeUtf8

sha256Bytes :: ByteString -> Text
sha256Bytes = TextEncoding.decodeUtf8 . hexSha256

registryRevisionText :: RegistryRevision -> Text
registryRevisionText (RegistryRevision value) = value

durableRunScopeText :: DurableObservationRunScope -> Text
durableRunScopeText (DurableObservationRunScope value) = value

foundationIdText :: LinuxRke2FoundationId -> Text
foundationIdText (LinuxRke2FoundationId value) = value
