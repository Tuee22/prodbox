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

-- | The per-substrate retention state: no committed reference, one current
-- committed reference, or a durable pre-effect outbox retaining the previous
-- committed reference while its exact successor is in flight.
data TlsRetentionState
  = TlsRetentionEmpty
  | TlsRetentionCurrent !RetainedTlsRef
  | TlsRetentionPendingState !TlsRetentionPending
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

pendingTlsRetention :: TlsRetentionState -> Maybe TlsRetentionPending
pendingTlsRetention state = case state of
  TlsRetentionPendingState pending -> Just pending
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
  RestoreCommittedAbsent -> TlsRestoreIssue
  RestoreTrustedTimeExpired -> TlsRestoreIssue
  RestoreCommittedCorrupt -> TlsRestoreRefused TlsRestoreCorrupt
  RestoreCommittedUnobservable -> TlsRestoreRefused TlsRestoreUnobservable
