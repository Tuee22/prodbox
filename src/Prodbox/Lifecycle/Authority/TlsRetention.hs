{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Sprint 4.48: the retained Lifecycle Authority's versioned TLS-retention fold.
--
-- The Authority retains, per substrate, one committed immutable reference to the
-- public-edge TLS material (ciphertext only; the retained-home TLS DEK is
-- referenced, not copied). A renewal binds a fenced candidate — its immutable
-- retention version, the certificate serial\/validity\/SPKI, the
-- ciphertext\/wrapped-DEK digest, and the source Kubernetes Secret
-- UID\/resourceVersion. Promotion is a CAS on the Authority's current reference
-- and is permitted ONLY after the exact source is re-observed AND the Adapter's
-- byte read-back matches. Out-of-order\/stale versions, a validity regression, or
-- an unapproved key change are refused; a lost response recovers the same
-- immutable version (idempotent no-op).
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
  , CertIdentity (..)
  , SourceSecretRef (..)
  , RetainedTlsRef (..)

    -- * State
  , TlsRetentionState (..)
  , initialTlsRetentionState
  , currentRetainedRef

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
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- | A monotone retention version identifying an immutable S3 object version. A
-- promotion may only advance it.
newtype RetentionVersion = RetentionVersion Natural
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

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

-- | The per-substrate retention state: no committed reference yet, or one current
-- committed reference.
data TlsRetentionState
  = TlsRetentionEmpty
  | TlsRetentionCurrent !RetainedTlsRef
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

initialTlsRetentionState :: TlsRetentionState
initialTlsRetentionState = TlsRetentionEmpty

-- | The current committed reference, or @Nothing@ before the first retention.
currentRetainedRef :: TlsRetentionState -> Maybe RetainedTlsRef
currentRetainedRef state = case state of
  TlsRetentionEmpty -> Nothing
  TlsRetentionCurrent ref -> Just ref

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
  deriving (Eq, Show)

data TlsPromotionDecision
  = -- | CAS-promote the current reference to this candidate.
    TlsPromoted !RetainedTlsRef
  | -- | The candidate is the exact current committed version (idempotent
    -- response-loss recovery); commit nothing.
    TlsPromotionNoop !RetainedTlsRef
  | TlsPromotionRefused !TlsPromotionRefusal
  deriving (Eq, Show)

-- | Decide a renewal promotion. Pure. Source re-observation and Adapter read-back
-- are required first (fail closed otherwise). From empty, the first candidate is
-- promoted. Against a current reference, the exact same version is an idempotent
-- no-op; an equal-or-lower version, a validity regression, or an unapproved key
-- change are refused; a strictly newer, non-regressing, approved candidate is
-- promoted.
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
      TlsRetentionEmpty -> TlsPromoted candidate
      TlsRetentionCurrent current
        | retainedVersion candidate == retainedVersion current ->
            if sameCommitted candidate current
              then TlsPromotionNoop current
              else TlsPromotionRefused TlsStaleVersion
        | retainedVersion candidate < retainedVersion current ->
            TlsPromotionRefused TlsStaleVersion
        | certNotAfter (retainedCert candidate) < certNotAfter (retainedCert current) ->
            TlsPromotionRefused TlsValidityRegression
        | certSpkiDigest (retainedCert candidate) /= certSpkiDigest (retainedCert current)
            && approval == KeyRotationNotApproved ->
            TlsPromotionRefused TlsUnapprovedKeyChange
        | otherwise -> TlsPromoted candidate
 where
  sameCommitted a b =
    retainedCert a == retainedCert b
      && retainedCiphertextDigest a == retainedCiphertextDigest b

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
  RestoreCommittedAbsent -> TlsRestoreIssue
  RestoreTrustedTimeExpired -> TlsRestoreIssue
  RestoreCommittedCorrupt -> TlsRestoreRefused TlsRestoreCorrupt
  RestoreCommittedUnobservable -> TlsRestoreRefused TlsRestoreUnobservable
