{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.48: the retained Lifecycle Authority's versioned TLS-retention fold.
--
-- The Authority retains, per substrate, one committed immutable reference to
-- the public-edge TLS material or one exact ciphertext-only pending outbox
-- retaining its predecessor. A renewal durably stages that outbox before the
-- immutable Adapter write and binds a fenced candidate — its immutable
-- retention version, the certificate serial\/validity\/SPKI, the
-- ciphertext\/wrapped-DEK digest, and the source Kubernetes Secret
-- UID\/resourceVersion. Promotion is a CAS on the Authority's pending state and
-- is permitted ONLY after the exact source is re-observed AND the Adapter's byte
-- read-back matches. Out-of-order\/stale versions, a validity regression, or an
-- unapproved key change are refused; a lost response resumes the same staged
-- immutable bytes and an already-promoted exact reference is an idempotent no-op.
--
-- Restore names THAT committed reference (never S3 latest\/list order). A total
-- restore ADT applies the exact committed reference when it reads back intact,
-- permits fresh issuance ONLY after positive authoritative absence or trusted-
-- time-validated expiry, and fails closed on corrupt, digest-mismatched, or
-- unobservable state.
--
-- This module is pure. The interpreter supplies the source\/read-back evidence,
-- the key-rotation approval, and the restore observation; this fold owns the
-- monotone CAS and restore invariants.
module Prodbox.Lifecycle.Authority.TlsRetention
  ( -- * Retained reference
    RetentionVersion (..)
  , TlsSealedEnvelope
  , tlsMaximumCertificateCiphertextBytes
  , tlsMaximumWrappedDekBytes
  , mkTlsSealedEnvelope
  , tlsCertificateCiphertextBytes
  , tlsWrappedDekBytes
  , tlsSealedEnvelopeDigest
  , validateTlsSealedEnvelope
  , CertIdentity (..)
  , SourceSecretRef (..)
  , RetainedTlsRef (..)

    -- * State
  , TlsRetentionPending (..)
  , TlsLegacyRecoveryEvidence (..)
  , TlsLegacyRecoveryCollisionEvidence (..)
  , TlsLegacyRecoverySuccessorEvidence (..)
  , TlsRetentionState (..)
  , initialTlsRetentionState
  , currentRetainedRef
  , pendingTlsRetention
  , nextRetentionVersion
  , validateRetainedTlsRef
  , validateTlsRetentionState

    -- * Durable staging
  , TlsStagingDecision (..)
  , TlsStagingRefusal (..)
  , decideTlsStaging
  , applyTlsStaging
  , stepTlsStaging

    -- * Unrecoverable pre-outbox recovery staging
  , TlsLegacyRecoveryStagingDecision (..)
  , TlsLegacyRecoveryStagingRefusal (..)
  , decideTlsLegacyRecoveryStaging
  , applyTlsLegacyRecoveryStaging

    -- * Promotion (renewal CAS)
  , PromotionEvidence (..)
  , KeyRotationApproval (..)
  , TlsPromotionDecision (..)
  , TlsPromotionRefusal (..)
  , decideTlsPromotion
  , applyTlsPromotion
  , stepTlsPromotion

    -- * Restore
  , RestoreObservation (..)
  , TlsRestoreDecision (..)
  , TlsRestoreRefusal (..)
  , decideTlsRestore
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.Char (isControl)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Aws.SigV4 (hexSha256)

-- | A monotone retention version identifying an immutable S3 object version. A
-- promotion may only advance it.
newtype RetentionVersion = RetentionVersion Natural
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | Ciphertext-only certificate envelope.  Its 'Show' instance exposes only
-- bounded lengths; neither certificate ciphertext nor wrapped DEK is rendered.
data TlsSealedEnvelope = TlsSealedEnvelope
  { internalTlsCertificateCiphertext :: !ByteString
  , internalTlsWrappedDek :: !ByteString
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show TlsSealedEnvelope where
  show envelope =
    "<tls-sealed-envelope:ciphertext="
      <> show (ByteString.length (tlsCertificateCiphertextBytes envelope))
      <> " bytes,wrapped-dek="
      <> show (ByteString.length (tlsWrappedDekBytes envelope))
      <> " bytes>"

tlsMaximumCertificateCiphertextBytes :: Int
tlsMaximumCertificateCiphertextBytes = 768 * 1024

tlsMaximumWrappedDekBytes :: Int
tlsMaximumWrappedDekBytes = 64 * 1024

mkTlsSealedEnvelope :: ByteString -> ByteString -> Either Text TlsSealedEnvelope
mkTlsSealedEnvelope certificateCiphertext wrappedDek = do
  let envelope = TlsSealedEnvelope certificateCiphertext wrappedDek
  validateTlsSealedEnvelope envelope
  Right envelope

tlsCertificateCiphertextBytes :: TlsSealedEnvelope -> ByteString
tlsCertificateCiphertextBytes = internalTlsCertificateCiphertext

tlsWrappedDekBytes :: TlsSealedEnvelope -> ByteString
tlsWrappedDekBytes = internalTlsWrappedDek

tlsSealedEnvelopeDigest :: TlsSealedEnvelope -> Text
tlsSealedEnvelopeDigest envelope =
  TextEncoding.decodeUtf8
    ( hexSha256
        ( ByteString.intercalate
            "\NUL"
            [ "prodbox-tls-sealed-envelope-v1"
            , lengthBytes (tlsCertificateCiphertextBytes envelope)
            , tlsCertificateCiphertextBytes envelope
            , lengthBytes (tlsWrappedDekBytes envelope)
            , tlsWrappedDekBytes envelope
            ]
        )
    )
 where
  lengthBytes = ByteString8.pack . show . ByteString.length

validateTlsSealedEnvelope :: TlsSealedEnvelope -> Either Text ()
validateTlsSealedEnvelope envelope
  | ByteString.null (tlsCertificateCiphertextBytes envelope) =
      Left "TLS certificate ciphertext must not be empty"
  | ByteString.length (tlsCertificateCiphertextBytes envelope)
      > tlsMaximumCertificateCiphertextBytes =
      Left "TLS certificate ciphertext exceeds the compiled bound"
  | ByteString.null (tlsWrappedDekBytes envelope) =
      Left "TLS wrapped DEK must not be empty"
  | ByteString.length (tlsWrappedDekBytes envelope) > tlsMaximumWrappedDekBytes =
      Left "TLS wrapped DEK exceeds the compiled bound"
  | otherwise = Right ()

-- | The approval-relevant identity of a certificate: serial, subject-public-key
-- digest (key identity), and validity end as a trusted-time instant.
data CertIdentity = CertIdentity
  { certSerial :: !Text
  , certSpkiDigest :: !Text
  , certNotAfter :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The source Kubernetes Secret's fencing coordinates.
data SourceSecretRef = SourceSecretRef
  { sourceSecretUid :: !Text
  , sourceSecretResourceVersion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | A committed, retained TLS reference: the immutable version, the certificate
-- identity, the ciphertext\/wrapped-DEK digest, and the source Secret coordinates.
data RetainedTlsRef = RetainedTlsRef
  { retainedVersion :: !RetentionVersion
  , retainedCert :: !CertIdentity
  , retainedCiphertextDigest :: !Text
  , retainedSourceSecret :: !SourceSecretRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The durable pre-effect outbox.  The previous committed reference remains
-- available for restore while this exact candidate is in flight.  Approval is
-- part of the staged intent and cannot be supplied differently on retry.
data TlsRetentionPending = TlsRetentionPending
  { tlsPendingPrevious :: !(Maybe RetainedTlsRef)
  , tlsPendingApproval :: !KeyRotationApproval
  , tlsPendingCandidate :: !RetainedTlsRef
  , tlsPendingEnvelope :: !TlsSealedEnvelope
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Value-free evidence for the one pre-outbox immutable version that cannot
-- be opened by the retained-home Transit key. The digest binds the exact
-- occupied bytes; the fixed constructor records the only admitted diagnosis.
-- It grants neither restore nor issuance authority.
data TlsLegacyRecoveryEvidence = TlsLegacyRecoveryEvidence
  { tlsLegacyRecoveryVersion :: !RetentionVersion
  , tlsLegacyRecoveryEnvelopeDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Exact value-free evidence that an already-staged recovery candidate cannot
-- occupy its immutable key because that key contains different canonical
-- bytes. The Authority retains both digests before replacing the outbox; this
-- evidence grants neither restore nor issuance authority.
data TlsLegacyRecoveryCollisionEvidence = TlsLegacyRecoveryCollisionEvidence
  { tlsLegacyRecoveryCollisionVersion :: !RetentionVersion
  , tlsLegacyRecoveryPendingEnvelopeDigest :: !Text
  , tlsLegacyRecoveryObservedEnvelopeDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Compact durable identity of the version-2 recovery outbox displaced by
-- an exact immutable collision whose occupied wrapped DEK did not authenticate
-- under the retained-home Transit key. The fixed successor state records that
-- closed diagnosis without retaining a second maximum-sized envelope.
data TlsLegacyRecoverySuccessorEvidence = TlsLegacyRecoverySuccessorEvidence
  { tlsLegacyRecoverySuccessorCollision :: !TlsLegacyRecoveryCollisionEvidence
  , tlsLegacyRecoveryDisplacedApproval :: !KeyRotationApproval
  , tlsLegacyRecoveryDisplacedCandidate :: !RetainedTlsRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The per-substrate retention state: no committed reference, one current
-- committed reference, or a durable pre-effect outbox retaining the previous
-- committed reference while its exact successor is in flight.
data TlsRetentionState
  = TlsRetentionEmpty
  | TlsRetentionCurrent !RetainedTlsRef
  | TlsRetentionPendingState !TlsRetentionPending
  | TlsRetentionLegacyRecoveryPendingState
      !TlsLegacyRecoveryEvidence
      !TlsRetentionPending
  | TlsRetentionLegacyRecoveryCollisionPendingState
      !TlsLegacyRecoveryEvidence
      !TlsLegacyRecoveryCollisionEvidence
      !TlsRetentionPending
  | TlsRetentionLegacyRecoverySuccessorPendingState
      !TlsLegacyRecoveryEvidence
      !TlsLegacyRecoverySuccessorEvidence
      !TlsRetentionPending
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

initialTlsRetentionState :: TlsRetentionState
initialTlsRetentionState = TlsRetentionEmpty

-- | The current committed reference, or @Nothing@ before the first retention.
currentRetainedRef :: TlsRetentionState -> Maybe RetainedTlsRef
currentRetainedRef state = case state of
  TlsRetentionEmpty -> Nothing
  TlsRetentionCurrent ref -> Just ref
  TlsRetentionPendingState pending -> tlsPendingPrevious pending
  TlsRetentionLegacyRecoveryPendingState _ _ -> Nothing
  TlsRetentionLegacyRecoveryCollisionPendingState {} -> Nothing
  TlsRetentionLegacyRecoverySuccessorPendingState {} -> Nothing

pendingTlsRetention :: TlsRetentionState -> Maybe TlsRetentionPending
pendingTlsRetention state = case state of
  TlsRetentionPendingState pending -> Just pending
  TlsRetentionLegacyRecoveryPendingState _ pending -> Just pending
  TlsRetentionLegacyRecoveryCollisionPendingState _ _ pending -> Just pending
  TlsRetentionLegacyRecoverySuccessorPendingState _ _ pending -> Just pending
  TlsRetentionEmpty -> Nothing
  TlsRetentionCurrent _ -> Nothing

nextRetentionVersion :: TlsRetentionState -> RetentionVersion
nextRetentionVersion state = case currentRetainedRef state of
  Nothing -> RetentionVersion 1
  Just current -> case retainedVersion current of
    RetentionVersion version -> RetentionVersion (version + 1)

-- | Validate the bounded semantic fields of one retained reference. This is
-- applied both before staging and at the durable codec boundary, so canonical
-- CBOR alone cannot manufacture an invalid version or unbounded identity.
validateRetainedTlsRef :: RetainedTlsRef -> Either Text ()
validateRetainedTlsRef reference = do
  case retainedVersion reference of
    RetentionVersion 0 -> Left "TLS retention version must be positive"
    RetentionVersion _ -> Right ()
  validateBoundedText "certificate serial" 256 (certSerial certificate)
  validateBoundedText "certificate SPKI digest" 128 (certSpkiDigest certificate)
  if certNotAfter certificate == 0
    then Left "certificate notAfter must be positive"
    else Right ()
  validateDigest (retainedCiphertextDigest reference)
  validateBoundedText "Secret UID" 512 (sourceSecretUid source)
  validateBoundedText "Secret resourceVersion" 512 (sourceSecretResourceVersion source)
 where
  certificate = retainedCert reference
  source = retainedSourceSecret reference

-- | Validate a complete durable state, including the relationship between a
-- pending outbox and its previous committed reference. A pending value is
-- valid only when the ordinary staging transition could have produced it.
validateTlsRetentionState :: TlsRetentionState -> Either Text ()
validateTlsRetentionState state = case state of
  TlsRetentionEmpty -> Right ()
  TlsRetentionCurrent reference -> validateRetainedTlsRef reference
  TlsRetentionPendingState pending -> do
    mapM_ validateRetainedTlsRef (tlsPendingPrevious pending)
    validateRetainedTlsRef (tlsPendingCandidate pending)
    validateTlsSealedEnvelope (tlsPendingEnvelope pending)
    let previousState = case tlsPendingPrevious pending of
          Nothing -> TlsRetentionEmpty
          Just reference -> TlsRetentionCurrent reference
    if decideTlsStaging
      (tlsPendingApproval pending)
      previousState
      (tlsPendingCandidate pending)
      (tlsPendingEnvelope pending)
      == TlsStaged pending
      then Right ()
      else Left "TLS retention pending state is not a valid staging transition"
  TlsRetentionLegacyRecoveryPendingState evidence pending ->
    case decideTlsLegacyRecoveryStaging
      (tlsPendingApproval pending)
      TlsRetentionEmpty
      evidence
      Nothing
      (tlsPendingCandidate pending)
      (tlsPendingEnvelope pending) of
      TlsLegacyRecoveryStaged expected
        | pending == expected -> Right ()
      _ -> Left "TLS legacy-recovery pending state is not a valid staging transition"
  TlsRetentionLegacyRecoveryCollisionPendingState evidence collision pending ->
    case validateLegacyRecoveryCollisionPending evidence collision pending of
      True -> Right ()
      False -> Left "TLS legacy-recovery collision pending state is invalid"
  TlsRetentionLegacyRecoverySuccessorPendingState evidence successor pending ->
    case validateLegacyRecoverySuccessorPending evidence successor pending of
      True -> Right ()
      False -> Left "TLS legacy-recovery successor pending state is invalid"

validateBoundedText :: Text -> Int -> Text -> Either Text ()
validateBoundedText label maximumLength value
  | Text.null value = Left (label <> " must not be empty")
  | Text.any isControl value = Left (label <> " contains a control character")
  | Text.length value > maximumLength = Left (label <> " exceeds the compiled bound")
  | otherwise = Right ()

validateDigest :: Text -> Either Text ()
validateDigest digest
  | Text.length digest /= 64 = Left "TLS retention digest has an invalid width"
  | Text.all isLowerHex digest = Right ()
  | otherwise = Left "TLS retention digest is not lowercase hexadecimal"
 where
  isLowerHex character =
    (character >= '0' && character <= '9')
      || (character >= 'a' && character <= 'f')

-- | The evidence a promotion requires: exact source re-observation and Adapter
-- byte read-back of the candidate.
data PromotionEvidence = PromotionEvidence
  { evidenceSourceReobserved :: !Bool
  , evidenceAdapterReadBack :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Whether the interpreter has approved a key (SPKI) rotation for this promotion.
data KeyRotationApproval
  = KeyRotationApproved
  | KeyRotationNotApproved
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsStagingRefusal
  = TlsStageEnvelopeInvalid
  | TlsStageReferenceInvalid
  | TlsStageDigestMismatch
  | TlsStageVersionMismatch
  | TlsStageValidityRegression
  | TlsStageUnapprovedKeyChange
  | TlsStageConcurrentPending
  deriving stock (Eq, Show)

data TlsStagingDecision
  = TlsStaged !TlsRetentionPending
  | TlsStagingNoop !TlsRetentionPending
  | TlsStagingRefused !TlsStagingRefusal
  deriving stock (Eq, Show)

decideTlsStaging
  :: KeyRotationApproval
  -> TlsRetentionState
  -> RetainedTlsRef
  -> TlsSealedEnvelope
  -> TlsStagingDecision
decideTlsStaging approval state candidate envelope
  | Left _ <- validateTlsSealedEnvelope envelope =
      TlsStagingRefused TlsStageEnvelopeInvalid
  | retainedCiphertextDigest candidate /= tlsSealedEnvelopeDigest envelope =
      TlsStagingRefused TlsStageDigestMismatch
  | Left _ <- validateRetainedTlsRef candidate =
      TlsStagingRefused TlsStageReferenceInvalid
  | otherwise = case pendingTlsRetention state of
      Just pending
        | pending == desiredPending -> TlsStagingNoop pending
        | otherwise -> TlsStagingRefused TlsStageConcurrentPending
      Nothing
        | retainedVersion candidate /= nextRetentionVersion state ->
            TlsStagingRefused TlsStageVersionMismatch
        | Just current <- currentRetainedRef state
        , certNotAfter (retainedCert candidate) < certNotAfter (retainedCert current) ->
            TlsStagingRefused TlsStageValidityRegression
        | Just current <- currentRetainedRef state
        , certSpkiDigest (retainedCert candidate) /= certSpkiDigest (retainedCert current)
        , approval == KeyRotationNotApproved ->
            TlsStagingRefused TlsStageUnapprovedKeyChange
        | otherwise -> TlsStaged desiredPending
 where
  desiredPending =
    TlsRetentionPending
      { tlsPendingPrevious = currentRetainedRef state
      , tlsPendingApproval = approval
      , tlsPendingCandidate = candidate
      , tlsPendingEnvelope = envelope
      }

applyTlsStaging :: TlsStagingDecision -> TlsRetentionState -> TlsRetentionState
applyTlsStaging decision state = case decision of
  TlsStaged pending -> TlsRetentionPendingState pending
  TlsStagingNoop _ -> state
  TlsStagingRefused _ -> state

stepTlsStaging
  :: KeyRotationApproval
  -> TlsRetentionState
  -> RetainedTlsRef
  -> TlsSealedEnvelope
  -> (TlsStagingDecision, TlsRetentionState)
stepTlsStaging approval state candidate envelope =
  let decision = decideTlsStaging approval state candidate envelope
   in (decision, applyTlsStaging decision state)

data TlsLegacyRecoveryStagingRefusal
  = TlsLegacyRecoveryStageStateNotEmpty
  | TlsLegacyRecoveryStageConcurrentPending
  | TlsLegacyRecoveryStageEvidenceInvalid
  | TlsLegacyRecoveryStageEnvelopeInvalid
  | TlsLegacyRecoveryStageReferenceInvalid
  | TlsLegacyRecoveryStageDigestMismatch
  | TlsLegacyRecoveryStageVersionMismatch
  | TlsLegacyRecoveryStageCollisionEvidenceInvalid
  deriving stock (Eq, Show)

data TlsLegacyRecoveryStagingDecision
  = TlsLegacyRecoveryStaged !TlsRetentionPending
  | TlsLegacyRecoveryCollisionRebased
      !TlsLegacyRecoveryCollisionEvidence
      !TlsRetentionPending
  | TlsLegacyRecoveryCollisionSuccessorStaged
      !TlsLegacyRecoverySuccessorEvidence
      !TlsRetentionPending
  | TlsLegacyRecoveryStagingNoop !TlsRetentionPending
  | TlsLegacyRecoveryStagingRefused !TlsLegacyRecoveryStagingRefusal
  deriving stock (Eq, Show)

-- | Stage a fresh version only after exact version 1 is occupied by a
-- pre-outbox envelope whose Transit ciphertext produced the closed
-- authentication-failed observation. The ordinary recovery stages fixed
-- version 2. If its immutable key is occupied, the verified occupied envelope
-- may replace that outbox at version 2; if the occupied wrapped DEK itself
-- produces the same closed authentication failure, exactly one fresh version-3
-- successor may be staged. No state admits a later version.
decideTlsLegacyRecoveryStaging
  :: KeyRotationApproval
  -> TlsRetentionState
  -> TlsLegacyRecoveryEvidence
  -> Maybe TlsLegacyRecoveryCollisionEvidence
  -> RetainedTlsRef
  -> TlsSealedEnvelope
  -> TlsLegacyRecoveryStagingDecision
decideTlsLegacyRecoveryStaging approval state evidence maybeCollision candidate envelope
  | tlsLegacyRecoveryVersion evidence /= RetentionVersion 1 =
      TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageEvidenceInvalid
  | Left _ <- validateDigest (tlsLegacyRecoveryEnvelopeDigest evidence) =
      TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageEvidenceInvalid
  | Left _ <- validateTlsSealedEnvelope envelope =
      TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageEnvelopeInvalid
  | retainedCiphertextDigest candidate /= tlsSealedEnvelopeDigest envelope =
      TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageDigestMismatch
  | Left _ <- validateRetainedTlsRef candidate =
      TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageReferenceInvalid
  | retainedVersion candidate /= RetentionVersion 2
      && retainedVersion candidate /= RetentionVersion 3 =
      TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageVersionMismatch
  | otherwise = case state of
      TlsRetentionEmpty -> case maybeCollision of
        Nothing
          | retainedVersion candidate == RetentionVersion 2 ->
              TlsLegacyRecoveryStaged desiredPending
          | otherwise -> versionMismatch
        Just _ -> collisionInvalid
      TlsRetentionLegacyRecoveryPendingState existingEvidence pending
        | existingEvidence /= evidence -> concurrentPending
        | pending == desiredPending
            && maybeCollision == Nothing
            && retainedVersion candidate == RetentionVersion 2 ->
            TlsLegacyRecoveryStagingNoop pending
        | Just collision <- maybeCollision
        , retainedVersion candidate == RetentionVersion 2
        , validCollisionRebase collision pending desiredPending ->
            TlsLegacyRecoveryCollisionRebased collision desiredPending
        | Just collision <- maybeCollision
        , retainedVersion candidate == RetentionVersion 3
        , let successor = successorEvidenceFor collision pending
        , validUnopenableCollisionSuccessor
            evidence
            successor
            desiredPending ->
            TlsLegacyRecoveryCollisionSuccessorStaged successor desiredPending
        | maybeCollision /= Nothing -> collisionInvalid
        | retainedVersion candidate /= RetentionVersion 2 -> versionMismatch
        | otherwise -> concurrentPending
      TlsRetentionLegacyRecoveryCollisionPendingState existingEvidence existingCollision pending
        | existingEvidence == evidence
            && Just existingCollision == maybeCollision
            && retainedVersion candidate == RetentionVersion 2
            && pending == desiredPending ->
            TlsLegacyRecoveryStagingNoop pending
        | otherwise -> concurrentPending
      TlsRetentionLegacyRecoverySuccessorPendingState existingEvidence successor pending
        | existingEvidence == evidence
            && Just (tlsLegacyRecoverySuccessorCollision successor) == maybeCollision
            && retainedVersion candidate == RetentionVersion 3
            && pending == desiredPending ->
            TlsLegacyRecoveryStagingNoop pending
        | otherwise -> concurrentPending
      TlsRetentionPendingState _ ->
        concurrentPending
      TlsRetentionCurrent _ ->
        TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageStateNotEmpty
 where
  desiredPending =
    TlsRetentionPending
      { tlsPendingPrevious = Nothing
      , tlsPendingApproval = approval
      , tlsPendingCandidate = candidate
      , tlsPendingEnvelope = envelope
      }
  concurrentPending =
    TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageConcurrentPending
  collisionInvalid =
    TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageCollisionEvidenceInvalid
  versionMismatch =
    TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageVersionMismatch
  successorEvidenceFor collision pending =
    TlsLegacyRecoverySuccessorEvidence
      { tlsLegacyRecoverySuccessorCollision = collision
      , tlsLegacyRecoveryDisplacedApproval = tlsPendingApproval pending
      , tlsLegacyRecoveryDisplacedCandidate = tlsPendingCandidate pending
      }

applyTlsLegacyRecoveryStaging
  :: TlsLegacyRecoveryEvidence
  -> TlsLegacyRecoveryStagingDecision
  -> TlsRetentionState
  -> TlsRetentionState
applyTlsLegacyRecoveryStaging evidence decision state = case decision of
  TlsLegacyRecoveryStaged pending ->
    TlsRetentionLegacyRecoveryPendingState evidence pending
  TlsLegacyRecoveryCollisionRebased collision pending ->
    TlsRetentionLegacyRecoveryCollisionPendingState evidence collision pending
  TlsLegacyRecoveryCollisionSuccessorStaged successor pending ->
    TlsRetentionLegacyRecoverySuccessorPendingState evidence successor pending
  TlsLegacyRecoveryStagingNoop _ -> state
  TlsLegacyRecoveryStagingRefused _ -> state

validCollisionRebase
  :: TlsLegacyRecoveryCollisionEvidence
  -> TlsRetentionPending
  -> TlsRetentionPending
  -> Bool
validCollisionRebase collision existing replacement =
  validateLegacyRecoveryCollisionPendingEvidence collision existing replacement
    && tlsPendingApproval replacement == tlsPendingApproval existing
    && retainedCert replacementCandidate == retainedCert existingCandidate
    && retainedSourceSecret replacementCandidate == retainedSourceSecret existingCandidate
 where
  existingCandidate = tlsPendingCandidate existing
  replacementCandidate = tlsPendingCandidate replacement

validateLegacyRecoveryCollisionPending
  :: TlsLegacyRecoveryEvidence
  -> TlsLegacyRecoveryCollisionEvidence
  -> TlsRetentionPending
  -> Bool
validateLegacyRecoveryCollisionPending evidence collision pending =
  tlsLegacyRecoveryVersion evidence == RetentionVersion 1
    && either (const False) (const True) (validateDigest (tlsLegacyRecoveryEnvelopeDigest evidence))
    && tlsPendingPrevious pending == Nothing
    && tlsLegacyRecoveryCollisionVersion collision == retainedVersion candidate
    && tlsLegacyRecoveryObservedEnvelopeDigest collision == retainedCiphertextDigest candidate
    && tlsLegacyRecoveryPendingEnvelopeDigest collision /= retainedCiphertextDigest candidate
    && either
      (const False)
      (const True)
      (validateDigest (tlsLegacyRecoveryPendingEnvelopeDigest collision))
    && either (const False) (const True) (validateRetainedTlsRef candidate)
    && either (const False) (const True) (validateTlsSealedEnvelope (tlsPendingEnvelope pending))
    && retainedCiphertextDigest candidate == tlsSealedEnvelopeDigest (tlsPendingEnvelope pending)
 where
  candidate = tlsPendingCandidate pending

validateLegacyRecoveryCollisionPendingEvidence
  :: TlsLegacyRecoveryCollisionEvidence
  -> TlsRetentionPending
  -> TlsRetentionPending
  -> Bool
validateLegacyRecoveryCollisionPendingEvidence collision existing replacement =
  tlsPendingPrevious existing == Nothing
    && tlsPendingPrevious replacement == Nothing
    && collisionVersion == retainedVersion existingCandidate
    && collisionVersion == retainedVersion replacementCandidate
    && pendingDigest == retainedCiphertextDigest existingCandidate
    && observedDigest == retainedCiphertextDigest replacementCandidate
    && pendingDigest /= observedDigest
    && either (const False) (const True) (validateDigest pendingDigest)
    && either (const False) (const True) (validateDigest observedDigest)
 where
  collisionVersion = tlsLegacyRecoveryCollisionVersion collision
  pendingDigest = tlsLegacyRecoveryPendingEnvelopeDigest collision
  observedDigest = tlsLegacyRecoveryObservedEnvelopeDigest collision
  existingCandidate = tlsPendingCandidate existing
  replacementCandidate = tlsPendingCandidate replacement

validUnopenableCollisionSuccessor
  :: TlsLegacyRecoveryEvidence
  -> TlsLegacyRecoverySuccessorEvidence
  -> TlsRetentionPending
  -> Bool
validUnopenableCollisionSuccessor evidence successor pending =
  validateLegacyRecoverySuccessorPending evidence successor pending

validateLegacyRecoverySuccessorPending
  :: TlsLegacyRecoveryEvidence
  -> TlsLegacyRecoverySuccessorEvidence
  -> TlsRetentionPending
  -> Bool
validateLegacyRecoverySuccessorPending evidence successor pending =
  tlsLegacyRecoveryVersion evidence == RetentionVersion 1
    && either (const False) (const True) (validateDigest (tlsLegacyRecoveryEnvelopeDigest evidence))
    && tlsLegacyRecoveryCollisionVersion collision == RetentionVersion 2
    && tlsLegacyRecoveryPendingEnvelopeDigest collision == retainedCiphertextDigest displaced
    && tlsLegacyRecoveryObservedEnvelopeDigest collision /= retainedCiphertextDigest displaced
    && tlsLegacyRecoveryObservedEnvelopeDigest collision /= retainedCiphertextDigest candidate
    && retainedCiphertextDigest displaced /= retainedCiphertextDigest candidate
    && either
      (const False)
      (const True)
      (validateDigest (tlsLegacyRecoveryObservedEnvelopeDigest collision))
    && either (const False) (const True) (validateRetainedTlsRef displaced)
    && retainedVersion displaced == RetentionVersion 2
    && tlsPendingPrevious pending == Nothing
    && tlsPendingApproval pending == tlsLegacyRecoveryDisplacedApproval successor
    && retainedVersion candidate == RetentionVersion 3
    && retainedCert candidate == retainedCert displaced
    && retainedSourceSecret candidate == retainedSourceSecret displaced
    && either (const False) (const True) (validateRetainedTlsRef candidate)
    && either (const False) (const True) (validateTlsSealedEnvelope (tlsPendingEnvelope pending))
    && retainedCiphertextDigest candidate == tlsSealedEnvelopeDigest (tlsPendingEnvelope pending)
 where
  collision = tlsLegacyRecoverySuccessorCollision successor
  displaced = tlsLegacyRecoveryDisplacedCandidate successor
  candidate = tlsPendingCandidate pending

data TlsPromotionRefusal
  = -- | The source Secret was not re-observed exactly.
    TlsSourceNotReobserved
  | -- | The Adapter byte read-back did not match the candidate.
    TlsAdapterReadBackMismatch
  | -- | The candidate version is not strictly newer (out-of-order\/stale receipt),
    -- or reuses the current version with different content.
    TlsStaleVersion
  | -- | The candidate certificate validity regresses (earlier @notAfter@).
    TlsValidityRegression
  | -- | The candidate changes the key (SPKI) without an approval.
    TlsUnapprovedKeyChange
  | -- | A fresh candidate cannot promote without its exact durable outbox.
    TlsPendingMissing
  | -- | The candidate or approval differs from the durable pending intent.
    TlsPendingMismatch
  deriving (Eq, Show)

data TlsPromotionDecision
  = -- | CAS-promote the current reference to this candidate.
    TlsPromoted !RetainedTlsRef
  | -- | The candidate is the exact current committed version (idempotent
    -- response-loss recovery); commit nothing.
    TlsPromotionNoop !RetainedTlsRef
  | TlsPromotionRefused !TlsPromotionRefusal
  deriving (Eq, Show)

-- | Decide a renewal promotion. Pure. Source re-observation, Adapter read-back,
-- and the exact durable pending outbox are required first (fail closed
-- otherwise). Against a committed reference, only the exact same reference is
-- an idempotent response-loss no-op; every new candidate must match its pending
-- reference and stored approval.
decideTlsPromotion
  :: KeyRotationApproval
  -> PromotionEvidence
  -> TlsRetentionState
  -> RetainedTlsRef
  -> TlsPromotionDecision
decideTlsPromotion approval evidence state candidate
  | not (evidenceSourceReobserved evidence) = TlsPromotionRefused TlsSourceNotReobserved
  | not (evidenceAdapterReadBack evidence) = TlsPromotionRefused TlsAdapterReadBackMismatch
  | otherwise = case state of
      TlsRetentionPendingState pending
        | tlsPendingCandidate pending /= candidate
            || tlsPendingApproval pending /= approval ->
            TlsPromotionRefused TlsPendingMismatch
        | otherwise -> decideAgainstPrevious (tlsPendingPrevious pending)
      TlsRetentionCurrent current
        | retainedVersion candidate == retainedVersion current ->
            if candidate == current
              then TlsPromotionNoop current
              else TlsPromotionRefused TlsStaleVersion
        | otherwise -> TlsPromotionRefused TlsPendingMissing
      TlsRetentionEmpty -> TlsPromotionRefused TlsPendingMissing
      TlsRetentionLegacyRecoveryPendingState _ pending
        | tlsPendingCandidate pending /= candidate
            || tlsPendingApproval pending /= approval ->
            TlsPromotionRefused TlsPendingMismatch
        | otherwise -> decideAgainstPrevious Nothing
      TlsRetentionLegacyRecoveryCollisionPendingState _ _ pending
        | tlsPendingCandidate pending /= candidate
            || tlsPendingApproval pending /= approval ->
            TlsPromotionRefused TlsPendingMismatch
        | otherwise -> decideAgainstPrevious Nothing
      TlsRetentionLegacyRecoverySuccessorPendingState _ _ pending
        | tlsPendingCandidate pending /= candidate
            || tlsPendingApproval pending /= approval ->
            TlsPromotionRefused TlsPendingMismatch
        | otherwise -> decideAgainstPrevious Nothing
 where
  decideAgainstPrevious maybeCurrent = case maybeCurrent of
    Nothing -> TlsPromoted candidate
    Just current
      | retainedVersion candidate <= retainedVersion current ->
          TlsPromotionRefused TlsStaleVersion
      | certNotAfter (retainedCert candidate) < certNotAfter (retainedCert current) ->
          TlsPromotionRefused TlsValidityRegression
      | certSpkiDigest (retainedCert candidate) /= certSpkiDigest (retainedCert current)
          && approval == KeyRotationNotApproved ->
          TlsPromotionRefused TlsUnapprovedKeyChange
      | otherwise -> TlsPromoted candidate

-- | Fold a promotion decision into the retention state. Only 'TlsPromoted'
-- advances the current reference; a no-op or refusal leaves it unchanged.
applyTlsPromotion :: TlsPromotionDecision -> TlsRetentionState -> TlsRetentionState
applyTlsPromotion decision state = case decision of
  TlsPromoted candidate -> TlsRetentionCurrent candidate
  TlsPromotionNoop _ -> state
  TlsPromotionRefused _ -> state

-- | 'decideTlsPromotion' then apply, returning the decision and evolved state.
stepTlsPromotion
  :: KeyRotationApproval
  -> PromotionEvidence
  -> TlsRetentionState
  -> RetainedTlsRef
  -> (TlsPromotionDecision, TlsRetentionState)
stepTlsPromotion approval evidence state candidate =
  let decision = decideTlsPromotion approval evidence state candidate
   in (decision, applyTlsPromotion decision state)

-- | What the interpreter observed when attempting to restore the committed
-- reference. Every case names the Authority's committed reference, never S3
-- latest\/list order.
data RestoreObservation
  = -- | The committed immutable version was read back and its digest verified.
    RestoreCommittedIntact !RetainedTlsRef
  | -- | The committed reference is positively, authoritatively absent.
    RestoreCommittedAbsent
  | -- | The committed reference's validity has expired by trusted time.
    RestoreTrustedTimeExpired
  | -- | The committed reference read back with a digest mismatch.
    RestoreCommittedCorrupt
  | -- | The committed reference could not be observed.
    RestoreCommittedUnobservable
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsRestoreRefusal
  = TlsRestoreCorrupt
  | TlsRestoreUnobservable
  | -- | An intact reference was claimed but nothing is committed, or it does not
    -- match the committed version.
    TlsRestoreReferenceMismatch
  | -- | A recovery outbox has no recoverable predecessor and therefore cannot
    -- authorize restore or fresh issuance before its fresh candidate promotes.
    TlsRestoreRecoveryPending
  deriving (Eq, Show)

data TlsRestoreDecision
  = -- | Decrypt\/apply\/read-back the exact committed reference.
    TlsRestoreApply !RetainedTlsRef
  | -- | Permitted to issue anew (positive absence or trusted-time expiry only).
    TlsRestoreIssue
  | TlsRestoreRefused !TlsRestoreRefusal
  deriving (Eq, Show)

-- | Decide a restore. Pure and total. An intact read-back that matches the
-- committed reference is applied by that exact reference; positive absence or
-- trusted-time expiry permits fresh issuance; corrupt, mismatched, or unobservable
-- state fails closed.
decideTlsRestore :: TlsRetentionState -> RestoreObservation -> TlsRestoreDecision
decideTlsRestore state observation = case observation of
  RestoreCommittedIntact observed -> case state of
    TlsRetentionCurrent current
      | retainedVersion observed == retainedVersion current
          && retainedCiphertextDigest observed == retainedCiphertextDigest current ->
          TlsRestoreApply current
      | otherwise -> TlsRestoreRefused TlsRestoreReferenceMismatch
    TlsRetentionEmpty -> TlsRestoreRefused TlsRestoreReferenceMismatch
    TlsRetentionPendingState pending -> case tlsPendingPrevious pending of
      Just current
        | retainedVersion observed == retainedVersion current
            && retainedCiphertextDigest observed == retainedCiphertextDigest current ->
            TlsRestoreApply current
      _ -> TlsRestoreRefused TlsRestoreReferenceMismatch
    TlsRetentionLegacyRecoveryPendingState _ _ ->
      TlsRestoreRefused TlsRestoreReferenceMismatch
    TlsRetentionLegacyRecoveryCollisionPendingState {} ->
      TlsRestoreRefused TlsRestoreReferenceMismatch
    TlsRetentionLegacyRecoverySuccessorPendingState {} ->
      TlsRestoreRefused TlsRestoreReferenceMismatch
  RestoreCommittedAbsent -> issueUnlessRecoveryPending state
  RestoreTrustedTimeExpired -> issueUnlessRecoveryPending state
  RestoreCommittedCorrupt -> TlsRestoreRefused TlsRestoreCorrupt
  RestoreCommittedUnobservable -> TlsRestoreRefused TlsRestoreUnobservable

issueUnlessRecoveryPending :: TlsRetentionState -> TlsRestoreDecision
issueUnlessRecoveryPending state = case state of
  TlsRetentionLegacyRecoveryPendingState _ _ ->
    TlsRestoreRefused TlsRestoreRecoveryPending
  TlsRetentionLegacyRecoveryCollisionPendingState {} ->
    TlsRestoreRefused TlsRestoreRecoveryPending
  TlsRetentionLegacyRecoverySuccessorPendingState {} ->
    TlsRestoreRefused TlsRestoreRecoveryPending
  TlsRetentionPendingState pending
    | tlsPendingPrevious pending == Nothing ->
        TlsRestoreRefused TlsRestoreRecoveryPending
  _ -> TlsRestoreIssue
