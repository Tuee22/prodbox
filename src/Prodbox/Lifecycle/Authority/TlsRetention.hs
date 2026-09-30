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
  , TlsPendingCollisionDisposition (..)
  , TlsPendingCollisionRecovery (..)
  , TlsDisplacedPendingIdentity (..)
  , TlsTerminalReplacementEvidence (..)
  , TlsUnopenableVersionEvidence (..)
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

    -- * Ordinary pending immutable-collision recovery
  , TlsPendingCollisionStagingDecision (..)
  , TlsPendingCollisionStagingRefusal (..)
  , decideTlsPendingCollisionStaging
  , applyTlsPendingCollisionStaging

    -- * Exact terminal replacement staging
  , TlsTerminalReplacementStagingDecision (..)
  , TlsTerminalReplacementStagingRefusal (..)
  , TlsTerminalReplacementEvidenceCause (..)
  , decideTlsTerminalReplacementStaging
  , applyTlsTerminalReplacementStaging

    -- * Unrecoverable pre-outbox recovery staging
  , TlsLegacyRecoveryStagingDecision (..)
  , TlsLegacyRecoveryStagingRefusal (..)
  , decideTlsLegacyRecoveryStaging
  , applyTlsLegacyRecoveryStaging

    -- * Unopenable Authority-lane successor staging
  , TlsUnopenableSuccessorStagingDecision (..)
  , TlsUnopenableSuccessorStagingRefusal (..)
  , tlsUnopenableSuccessorVersion
  , decideTlsUnopenableSuccessorStaging
  , applyTlsUnopenableSuccessorStaging

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

-- | Which exact, bounded recovery an immutable collision observation supports.
-- An openable occupant can replace only the pending envelope at the same
-- version. An unopenable occupant can admit only the immediately following
-- version; it never starts a search.
data TlsPendingCollisionDisposition
  = TlsPendingCollisionAdoptObserved
  | TlsPendingCollisionStepPastUnopenable
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Value-free evidence for an immutable collision against an ordinary
-- Authority pending. The two digests name the displaced outbox and the exact
-- bytes observed at its version; the disposition records whether the selected
-- Target authenticated those bytes or the retained-home key rejected their
-- wrapped DEK.
data TlsPendingCollisionRecovery = TlsPendingCollisionRecovery
  { tlsPendingCollisionVersion :: !RetentionVersion
  , tlsPendingCollisionDisplacedEnvelopeDigest :: !Text
  , tlsPendingCollisionObservedEnvelopeDigest :: !Text
  , tlsPendingCollisionDisposition :: !TlsPendingCollisionDisposition
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Compact durable identity of the pending displaced by an immutable
-- collision. The original maximum-sized envelope is deliberately omitted; its
-- digest remains in both the candidate and collision evidence.
data TlsDisplacedPendingIdentity = TlsDisplacedPendingIdentity
  { tlsDisplacedPendingPrevious :: !(Maybe RetainedTlsRef)
  , tlsDisplacedPendingApproval :: !KeyRotationApproval
  , tlsDisplacedPendingCandidate :: !RetainedTlsRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Exact evidence authorizing replacement of the fixed terminal slot. The
-- version remains four: this is neither a fifth version nor a search. The
-- digest names the canonical occupant that the retained-home Agent proved
-- authenticated-unopenable before the replacement outbox was staged.
data TlsTerminalReplacementEvidence = TlsTerminalReplacementEvidence
  { tlsTerminalReplacementVersion :: !RetentionVersion
  , tlsTerminalReplacementOccupantEnvelopeDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Value-free evidence that one /Authority-lane/ immutable version is occupied
-- by an envelope this control plane cannot open: its wrapped DEK returned the
-- closed authenticated @home-rewrap-ciphertext-authentication-failed@ result
-- under the retained-home Transit key. It grants neither restore nor issuance
-- authority and admits exactly one successor version.
--
-- __What the digest is and is not.__ It records which bytes the interpreter
-- observed at that version when it proved them unopenable, so a later reader
-- can re-observe the key and tell \"the object we stepped past\" from \"some
-- object at that number\". This fold does not and cannot verify it against the
-- store: the digest is an interpreter claim, exactly as
-- 'TlsLegacyRecoveryEvidence' is. What the fold does enforce is that the claim
-- is well formed, that it names the version this reference was about to claim,
-- and that it is not the successor's own digest — so the evidence carries
-- information the pending does not already contain and cannot launder the
-- skipped envelope forward.
--
-- This is deliberately a separate type from 'TlsLegacyRecoveryEvidence' rather
-- than a reuse of it. That value is pinned to version 1 of the /pre-Authority/
-- lane by 'decideTlsLegacyRecoveryStaging', and the two lanes are disjoint: the
-- legacy recovery transitions are reachable only from 'TlsRetentionEmpty' and
-- this one only from 'TlsRetentionCurrent'.
data TlsUnopenableVersionEvidence = TlsUnopenableVersionEvidence
  { tlsUnopenableVersion :: !RetentionVersion
  , tlsUnopenableEnvelopeDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The per-substrate retention state: no committed reference, one current
-- committed reference, or a durable pre-effect outbox retaining the previous
-- committed reference while its exact successor is in flight.
--
-- Constructors are only ever /appended/. The derived 'Serialise' instance tags
-- a constructor by its declaration index, so the retained encodings of every
-- earlier constructor — including the pre-outbox @Empty@ and @Current@ bytes a
-- codec case pins directly — are preserved by construction.
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
  | -- | A durable outbox for the one successor version admitted past an
    -- Authority-lane version proven unopenable. Unlike every legacy-recovery
    -- state above, this one /retains its predecessor/: the condition arises
    -- from 'TlsRetentionCurrent', that committed reference is still intact and
    -- still restorable, and only the unwritable successor slot is in flight.
    TlsRetentionUnopenableSuccessorPendingState
      !TlsUnopenableVersionEvidence
      !TlsRetentionPending
  | -- | An ordinary pending rebased onto authenticated immutable bytes already
    -- present at its exact version. The displaced identity and both digests
    -- make the supersession reconstructible without retaining two envelopes.
    TlsRetentionPendingCollisionRebasedState
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsRetentionPending
  | -- | The one fresh successor admitted after an ordinary pending's exact
    -- version was occupied by a well-formed envelope whose wrapped DEK did not
    -- authenticate under the retained-home key.
    TlsRetentionPendingCollisionSuccessorState
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsRetentionPending
  | -- | The already-bounded successor pending rebased onto authenticated
    -- immutable bytes at that same successor version. The original
    -- skipped-version evidence remains durable, so this transition cannot
    -- erase the fact that the lane has already spent its single skip.
    TlsRetentionUnopenableSuccessorCollisionRebasedState
      !TlsUnopenableVersionEvidence
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsRetentionPending
  | -- | The pre-Authority legacy-recovery lane's fixed version-3 successor
    -- rebased onto authenticated immutable bytes already present at version 3.
    -- Both earlier facts remain durable: version 1 was unopenable, and the
    -- version-2 recovery outbox collided with an unopenable occupant. The
    -- final collision may therefore adopt only at version 3; it cannot spend a
    -- second skip.
    TlsRetentionLegacyRecoverySuccessorCollisionRebasedState
      !TlsLegacyRecoveryEvidence
      !TlsLegacyRecoverySuccessorEvidence
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsRetentionPending
  | -- | The current-backed ordinary-collision lane's one admitted successor
    -- rebased onto authenticated bytes at that same successor version. The
    -- original collision/skip and displaced identity remain alongside the
    -- successor collision, so no later reader can erase the spent skip.
    TlsRetentionPendingCollisionSuccessorRebasedState
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsRetentionPending
  | -- | The current-less legacy-recovery lane's terminal fixed version-4
    -- successor. Versions 1, 2, and 3 were all proven unusable through the
    -- exact bounded chain retained here. This is a terminal compatibility
    -- continuation, not a recursive skip: no state admits version 5.
    TlsRetentionLegacyRecoveryTerminalSuccessorState
      !TlsLegacyRecoveryEvidence
      !TlsLegacyRecoverySuccessorEvidence
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsRetentionPending
  | -- | Same-version adoption after the terminal fixed version-4 successor
    -- races with an immutable occupant. Both the version-3 terminal admission
    -- and the version-4 collision remain durable; another skip is impossible.
    TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState
      !TlsLegacyRecoveryEvidence
      !TlsLegacyRecoverySuccessorEvidence
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsRetentionPending
  | -- | A durable replacement outbox for an authenticated-unopenable occupant
    -- at the fixed terminal version 4. The complete v1/v2/v3 chain, the v3
    -- collision that admitted v4, and the exact v4 occupant digest all precede
    -- the same-key compare-and-swap. No later version is representable.
    TlsRetentionLegacyRecoveryTerminalReplacementState
      !TlsLegacyRecoveryEvidence
      !TlsLegacyRecoverySuccessorEvidence
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsTerminalReplacementEvidence
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
  -- The predecessor survives an unopenable successor: it is a committed
  -- reference whose own object is intact, and the only thing this outbox
  -- cannot do is occupy the version after it.
  TlsRetentionUnopenableSuccessorPendingState _ pending -> tlsPendingPrevious pending
  TlsRetentionPendingCollisionRebasedState _ _ pending -> tlsPendingPrevious pending
  TlsRetentionPendingCollisionSuccessorState _ _ pending -> tlsPendingPrevious pending
  TlsRetentionUnopenableSuccessorCollisionRebasedState _ _ _ pending ->
    tlsPendingPrevious pending
  TlsRetentionLegacyRecoverySuccessorCollisionRebasedState {} -> Nothing
  TlsRetentionPendingCollisionSuccessorRebasedState _ _ _ _ pending ->
    tlsPendingPrevious pending
  TlsRetentionLegacyRecoveryTerminalSuccessorState {} -> Nothing
  TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState {} -> Nothing
  TlsRetentionLegacyRecoveryTerminalReplacementState {} -> Nothing

pendingTlsRetention :: TlsRetentionState -> Maybe TlsRetentionPending
pendingTlsRetention state = case state of
  TlsRetentionPendingState pending -> Just pending
  TlsRetentionLegacyRecoveryPendingState _ pending -> Just pending
  TlsRetentionLegacyRecoveryCollisionPendingState _ _ pending -> Just pending
  TlsRetentionLegacyRecoverySuccessorPendingState _ _ pending -> Just pending
  TlsRetentionUnopenableSuccessorPendingState _ pending -> Just pending
  TlsRetentionPendingCollisionRebasedState _ _ pending -> Just pending
  TlsRetentionPendingCollisionSuccessorState _ _ pending -> Just pending
  TlsRetentionUnopenableSuccessorCollisionRebasedState _ _ _ pending -> Just pending
  TlsRetentionLegacyRecoverySuccessorCollisionRebasedState _ _ _ _ pending -> Just pending
  TlsRetentionPendingCollisionSuccessorRebasedState _ _ _ _ pending -> Just pending
  TlsRetentionLegacyRecoveryTerminalSuccessorState _ _ _ _ pending -> Just pending
  TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState _ _ _ _ _ _ pending -> Just pending
  TlsRetentionLegacyRecoveryTerminalReplacementState _ _ _ _ _ pending -> Just pending
  TlsRetentionEmpty -> Nothing
  TlsRetentionCurrent _ -> Nothing

nextRetentionVersion :: TlsRetentionState -> RetentionVersion
nextRetentionVersion state = case currentRetainedRef state of
  Nothing -> RetentionVersion 1
  Just current -> successorRetentionVersion (retainedVersion current)

-- | The exact next integer version. Named rather than inlined because both the
-- ordinary selection above and the bounded successor admission below must mean
-- the same step, and a lane that computed its own would be a search.
successorRetentionVersion :: RetentionVersion -> RetentionVersion
successorRetentionVersion (RetentionVersion version) = RetentionVersion (version + 1)

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
  TlsRetentionUnopenableSuccessorPendingState evidence pending -> do
    mapM_ validateRetainedTlsRef (tlsPendingPrevious pending)
    validateRetainedTlsRef (tlsPendingCandidate pending)
    validateTlsSealedEnvelope (tlsPendingEnvelope pending)
    -- Everything 'decideTlsUnopenableSuccessorStaging' reads is recoverable
    -- from this record alone: the predecessor is the pending's own previous,
    -- the approval and candidate are the pending's, and the skipped version and
    -- its occupant digest are the durably retained evidence. A version jump
    -- therefore cannot be authorized by a token the codec boundary never sees.
    let previousState = case tlsPendingPrevious pending of
          Nothing -> TlsRetentionEmpty
          Just reference -> TlsRetentionCurrent reference
    if decideTlsUnopenableSuccessorStaging
      (tlsPendingApproval pending)
      previousState
      evidence
      (tlsPendingCandidate pending)
      (tlsPendingEnvelope pending)
      == TlsUnopenableSuccessorStaged pending
      then Right ()
      else Left "TLS unopenable-successor pending state is not a valid staging transition"
  TlsRetentionPendingCollisionRebasedState recovery displaced pending ->
    validatePendingCollisionState
      TlsPendingCollisionAdoptObserved
      recovery
      displaced
      pending
  TlsRetentionPendingCollisionSuccessorState recovery displaced pending ->
    validatePendingCollisionState
      TlsPendingCollisionStepPastUnopenable
      recovery
      displaced
      pending
  TlsRetentionUnopenableSuccessorCollisionRebasedState evidence recovery displaced pending ->
    validateUnopenableSuccessorCollisionState evidence recovery displaced pending
  TlsRetentionLegacyRecoverySuccessorCollisionRebasedState
    evidence
    successor
    recovery
    displaced
    pending ->
      validateLegacyRecoverySuccessorCollisionState
        evidence
        successor
        recovery
        displaced
        pending
  TlsRetentionPendingCollisionSuccessorRebasedState
    originalRecovery
    originalDisplaced
    recovery
    displaced
    pending ->
      validatePendingCollisionSuccessorRebasedState
        originalRecovery
        originalDisplaced
        recovery
        displaced
        pending
  TlsRetentionLegacyRecoveryTerminalSuccessorState
    evidence
    successor
    recovery
    displaced
    pending ->
      validateLegacyRecoveryTerminalSuccessorState
        evidence
        successor
        recovery
        displaced
        pending
  TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState
    evidence
    successor
    originalRecovery
    originalDisplaced
    recovery
    displaced
    pending ->
      validateLegacyRecoveryTerminalSuccessorRebasedState
        evidence
        successor
        originalRecovery
        originalDisplaced
        recovery
        displaced
        pending
  TlsRetentionLegacyRecoveryTerminalReplacementState
    evidence
    successor
    recovery
    displaced
    terminalEvidence
    pending ->
      validateLegacyRecoveryTerminalReplacementState
        evidence
        successor
        recovery
        displaced
        terminalEvidence
        pending

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

data TlsPendingCollisionStagingRefusal
  = TlsPendingCollisionStageStateNotPending
  | TlsPendingCollisionStageConcurrentPending
  | TlsPendingCollisionStageEvidenceInvalid
  | TlsPendingCollisionStageEnvelopeInvalid
  | TlsPendingCollisionStageReferenceInvalid
  | TlsPendingCollisionStageDigestMismatch
  deriving stock (Eq, Show)

data TlsPendingCollisionStagingDecision
  = TlsPendingCollisionRebased
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsRetentionPending
  | TlsPendingCollisionSuccessorStaged
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsRetentionPending
  | TlsPendingCollisionUnopenableSuccessorRebased
      !TlsUnopenableVersionEvidence
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsRetentionPending
  | TlsPendingCollisionLegacyRecoverySuccessorRebased
      !TlsLegacyRecoveryEvidence
      !TlsLegacyRecoverySuccessorEvidence
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsRetentionPending
  | TlsPendingCollisionBoundedSuccessorRebased
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsRetentionPending
  | TlsPendingCollisionLegacyRecoveryTerminalSuccessorStaged
      !TlsLegacyRecoveryEvidence
      !TlsLegacyRecoverySuccessorEvidence
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsRetentionPending
  | TlsPendingCollisionLegacyRecoveryTerminalSuccessorRebased
      !TlsLegacyRecoveryEvidence
      !TlsLegacyRecoverySuccessorEvidence
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsRetentionPending
  | TlsPendingCollisionStagingNoop !TlsRetentionPending
  | TlsPendingCollisionStagingRefused !TlsPendingCollisionStagingRefusal
  deriving stock (Eq, Show)

-- | Replace an ordinary pending only after its immutable slot is observed with
-- different bytes. An authenticated occupant stays at that exact version; an
-- occupant whose wrapped DEK is unopenable admits exactly one successor. The
-- original pending's predecessor, approval, certificate and source all remain
-- fixed, and the displaced identity is retained durably before another object
-- write is attempted.
decideTlsPendingCollisionStaging
  :: KeyRotationApproval
  -> TlsRetentionState
  -> TlsPendingCollisionRecovery
  -> RetainedTlsRef
  -> TlsSealedEnvelope
  -> TlsPendingCollisionStagingDecision
decideTlsPendingCollisionStaging approval state recovery candidate envelope
  | Left _ <- validateTlsSealedEnvelope envelope =
      refused TlsPendingCollisionStageEnvelopeInvalid
  | retainedCiphertextDigest candidate /= tlsSealedEnvelopeDigest envelope =
      refused TlsPendingCollisionStageDigestMismatch
  | Left _ <- validateRetainedTlsRef candidate =
      refused TlsPendingCollisionStageReferenceInvalid
  | otherwise = case state of
      TlsRetentionPendingState displacedPending ->
        stageAgainst displacedPending
      TlsRetentionPendingCollisionRebasedState
        existingRecovery
        existingDisplaced
        pending
          | existingRecovery == recovery
              && existingDisplaced == displacedIdentity
              && pending == desiredPending ->
              TlsPendingCollisionStagingNoop pending
          | otherwise -> concurrent
      TlsRetentionPendingCollisionSuccessorState
        existingRecovery
        existingDisplaced
        pending
          | existingRecovery == recovery
              && existingDisplaced == displacedIdentity
              && pending == desiredPending ->
              TlsPendingCollisionStagingNoop pending
          | existingRecovery == recovery -> concurrent
          | otherwise ->
              stageAgainstPendingCollisionSuccessor
                existingRecovery
                existingDisplaced
                pending
      TlsRetentionUnopenableSuccessorPendingState evidence displacedPending ->
        stageAgainstUnopenableSuccessor evidence displacedPending
      TlsRetentionLegacyRecoverySuccessorPendingState evidence successor displacedPending ->
        stageAgainstLegacyRecoverySuccessor evidence successor displacedPending
      TlsRetentionLegacyRecoveryTerminalSuccessorState
        evidence
        successor
        originalRecovery
        originalDisplaced
        displacedPending
          | originalRecovery == recovery
              && originalDisplaced == displacedIdentity
              && displacedPending == desiredPending ->
              TlsPendingCollisionStagingNoop displacedPending
          | originalRecovery == recovery -> concurrent
          | otherwise ->
              stageAgainstLegacyRecoveryTerminalSuccessor
                evidence
                successor
                originalRecovery
                originalDisplaced
                displacedPending
      TlsRetentionUnopenableSuccessorCollisionRebasedState
        _
        existingRecovery
        existingDisplaced
        pending
          | existingRecovery == recovery
              && existingDisplaced == displacedIdentity
              && pending == desiredPending ->
              TlsPendingCollisionStagingNoop pending
          | otherwise -> concurrent
      TlsRetentionLegacyRecoverySuccessorCollisionRebasedState
        _
        _
        existingRecovery
        existingDisplaced
        pending
          | existingRecovery == recovery
              && existingDisplaced == displacedIdentity
              && pending == desiredPending ->
              TlsPendingCollisionStagingNoop pending
          | otherwise -> concurrent
      TlsRetentionPendingCollisionSuccessorRebasedState
        _
        _
        existingRecovery
        existingDisplaced
        pending
          | existingRecovery == recovery
              && existingDisplaced == displacedIdentity
              && pending == desiredPending ->
              TlsPendingCollisionStagingNoop pending
          | otherwise -> concurrent
      TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState
        _
        _
        _
        _
        existingRecovery
        existingDisplaced
        pending
          | existingRecovery == recovery
              && existingDisplaced == displacedIdentity
              && pending == desiredPending ->
              TlsPendingCollisionStagingNoop pending
          | otherwise -> concurrent
      TlsRetentionLegacyRecoveryTerminalReplacementState {} -> concurrent
      TlsRetentionEmpty -> notPending
      TlsRetentionCurrent _ -> notPending
      TlsRetentionLegacyRecoveryPendingState _ _ -> concurrent
      TlsRetentionLegacyRecoveryCollisionPendingState {} -> concurrent
 where
  refused = TlsPendingCollisionStagingRefused
  notPending = refused TlsPendingCollisionStageStateNotPending
  concurrent = refused TlsPendingCollisionStageConcurrentPending
  displacedIdentity = case state of
    TlsRetentionPendingState displacedPending -> identityFor displacedPending
    TlsRetentionPendingCollisionRebasedState _ existing _ -> existing
    TlsRetentionPendingCollisionSuccessorState _ existing _ -> existing
    TlsRetentionUnopenableSuccessorPendingState _ displacedPending ->
      identityFor displacedPending
    TlsRetentionUnopenableSuccessorCollisionRebasedState _ _ existing _ -> existing
    TlsRetentionLegacyRecoverySuccessorPendingState _ _ displacedPending ->
      identityFor displacedPending
    TlsRetentionLegacyRecoverySuccessorCollisionRebasedState _ _ _ existing _ -> existing
    TlsRetentionPendingCollisionSuccessorRebasedState _ _ _ existing _ -> existing
    TlsRetentionLegacyRecoveryTerminalSuccessorState _ _ _ existing _ -> existing
    TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState _ _ _ _ _ existing _ -> existing
    _ ->
      TlsDisplacedPendingIdentity
        { tlsDisplacedPendingPrevious = Nothing
        , tlsDisplacedPendingApproval = approval
        , tlsDisplacedPendingCandidate = candidate
        }
  desiredPending =
    TlsRetentionPending
      { tlsPendingPrevious = tlsDisplacedPendingPrevious displacedIdentity
      , tlsPendingApproval = approval
      , tlsPendingCandidate = candidate
      , tlsPendingEnvelope = envelope
      }
  identityFor pending =
    TlsDisplacedPendingIdentity
      { tlsDisplacedPendingPrevious = tlsPendingPrevious pending
      , tlsDisplacedPendingApproval = tlsPendingApproval pending
      , tlsDisplacedPendingCandidate = tlsPendingCandidate pending
      }
  stageAgainst displacedPending =
    let displaced = identityFor displacedPending
        next =
          case tlsPendingCollisionDisposition recovery of
            TlsPendingCollisionAdoptObserved ->
              TlsRetentionPendingCollisionRebasedState recovery displaced desiredPending
            TlsPendingCollisionStepPastUnopenable ->
              TlsRetentionPendingCollisionSuccessorState recovery displaced desiredPending
     in case validateTlsRetentionState next of
          Left _ -> refused TlsPendingCollisionStageEvidenceInvalid
          Right () -> case tlsPendingCollisionDisposition recovery of
            TlsPendingCollisionAdoptObserved ->
              TlsPendingCollisionRebased recovery displaced desiredPending
            TlsPendingCollisionStepPastUnopenable ->
              TlsPendingCollisionSuccessorStaged recovery displaced desiredPending
  stageAgainstUnopenableSuccessor evidence displacedPending =
    let displaced = identityFor displacedPending
        next =
          TlsRetentionUnopenableSuccessorCollisionRebasedState
            evidence
            recovery
            displaced
            desiredPending
     in case tlsPendingCollisionDisposition recovery of
          TlsPendingCollisionStepPastUnopenable ->
            refused TlsPendingCollisionStageEvidenceInvalid
          TlsPendingCollisionAdoptObserved ->
            case validateTlsRetentionState next of
              Left _ -> refused TlsPendingCollisionStageEvidenceInvalid
              Right () ->
                TlsPendingCollisionUnopenableSuccessorRebased
                  evidence
                  recovery
                  displaced
                  desiredPending
  stageAgainstLegacyRecoverySuccessor evidence successor displacedPending =
    let displaced = identityFor displacedPending
        rebased =
          TlsRetentionLegacyRecoverySuccessorCollisionRebasedState
            evidence
            successor
            recovery
            displaced
            desiredPending
        terminal =
          TlsRetentionLegacyRecoveryTerminalSuccessorState
            evidence
            successor
            recovery
            displaced
            desiredPending
     in case tlsPendingCollisionDisposition recovery of
          TlsPendingCollisionStepPastUnopenable ->
            case validateTlsRetentionState terminal of
              Left _ -> refused TlsPendingCollisionStageEvidenceInvalid
              Right () ->
                TlsPendingCollisionLegacyRecoveryTerminalSuccessorStaged
                  evidence
                  successor
                  recovery
                  displaced
                  desiredPending
          TlsPendingCollisionAdoptObserved ->
            case validateTlsRetentionState rebased of
              Left _ -> refused TlsPendingCollisionStageEvidenceInvalid
              Right () ->
                TlsPendingCollisionLegacyRecoverySuccessorRebased
                  evidence
                  successor
                  recovery
                  displaced
                  desiredPending
  stageAgainstLegacyRecoveryTerminalSuccessor
    evidence
    successor
    originalRecovery
    originalDisplaced
    displacedPending =
      let displaced = identityFor displacedPending
          next =
            TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState
              evidence
              successor
              originalRecovery
              originalDisplaced
              recovery
              displaced
              desiredPending
       in case tlsPendingCollisionDisposition recovery of
            TlsPendingCollisionStepPastUnopenable ->
              refused TlsPendingCollisionStageEvidenceInvalid
            TlsPendingCollisionAdoptObserved ->
              case validateTlsRetentionState next of
                Left _ -> refused TlsPendingCollisionStageEvidenceInvalid
                Right () ->
                  TlsPendingCollisionLegacyRecoveryTerminalSuccessorRebased
                    evidence
                    successor
                    originalRecovery
                    originalDisplaced
                    recovery
                    displaced
                    desiredPending
  stageAgainstPendingCollisionSuccessor originalRecovery originalDisplaced displacedPending =
    let displaced = identityFor displacedPending
        next =
          TlsRetentionPendingCollisionSuccessorRebasedState
            originalRecovery
            originalDisplaced
            recovery
            displaced
            desiredPending
     in case tlsPendingCollisionDisposition recovery of
          TlsPendingCollisionStepPastUnopenable ->
            refused TlsPendingCollisionStageEvidenceInvalid
          TlsPendingCollisionAdoptObserved ->
            case validateTlsRetentionState next of
              Left _ -> refused TlsPendingCollisionStageEvidenceInvalid
              Right () ->
                TlsPendingCollisionBoundedSuccessorRebased
                  originalRecovery
                  originalDisplaced
                  recovery
                  displaced
                  desiredPending

applyTlsPendingCollisionStaging
  :: TlsPendingCollisionStagingDecision
  -> TlsRetentionState
  -> TlsRetentionState
applyTlsPendingCollisionStaging decision state = case decision of
  TlsPendingCollisionRebased recovery displaced pending ->
    TlsRetentionPendingCollisionRebasedState recovery displaced pending
  TlsPendingCollisionSuccessorStaged recovery displaced pending ->
    TlsRetentionPendingCollisionSuccessorState recovery displaced pending
  TlsPendingCollisionUnopenableSuccessorRebased evidence recovery displaced pending ->
    TlsRetentionUnopenableSuccessorCollisionRebasedState
      evidence
      recovery
      displaced
      pending
  TlsPendingCollisionLegacyRecoverySuccessorRebased
    evidence
    successor
    recovery
    displaced
    pending ->
      TlsRetentionLegacyRecoverySuccessorCollisionRebasedState
        evidence
        successor
        recovery
        displaced
        pending
  TlsPendingCollisionBoundedSuccessorRebased
    originalRecovery
    originalDisplaced
    recovery
    displaced
    pending ->
      TlsRetentionPendingCollisionSuccessorRebasedState
        originalRecovery
        originalDisplaced
        recovery
        displaced
        pending
  TlsPendingCollisionLegacyRecoveryTerminalSuccessorStaged
    evidence
    successor
    recovery
    displaced
    pending ->
      TlsRetentionLegacyRecoveryTerminalSuccessorState
        evidence
        successor
        recovery
        displaced
        pending
  TlsPendingCollisionLegacyRecoveryTerminalSuccessorRebased
    evidence
    successor
    originalRecovery
    originalDisplaced
    recovery
    displaced
    pending ->
      TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState
        evidence
        successor
        originalRecovery
        originalDisplaced
        recovery
        displaced
        pending
  TlsPendingCollisionStagingNoop _ -> state
  TlsPendingCollisionStagingRefused _ -> state

data TlsTerminalReplacementStagingRefusal
  = TlsTerminalReplacementStageStateNotSuccessor
  | TlsTerminalReplacementStageConcurrentPending
  | TlsTerminalReplacementStageEvidenceInvalid !TlsTerminalReplacementEvidenceCause
  | TlsTerminalReplacementStageEnvelopeInvalid
  | TlsTerminalReplacementStageReferenceInvalid
  | TlsTerminalReplacementStageDigestMismatch
  deriving stock (Eq, Show)

-- | Closed attribution for the otherwise generic terminal-replacement state
-- validation failure. Each constructor names only an invariant family; no
-- certificate, source, digest, or durable-state value can cross this boundary.
data TlsTerminalReplacementEvidenceCause
  = TlsTerminalReplacementEvidenceMalformed
  | TlsTerminalReplacementVersionLineageInvalid
  | TlsTerminalReplacementDigestLineageInvalid
  | TlsTerminalReplacementApprovalLineageInvalid
  | TlsTerminalReplacementCertificateLineageInvalid
  | TlsTerminalReplacementSourceUidLineageInvalid
  | TlsTerminalReplacementSourceResourceVersionLineageInvalid
  | TlsTerminalReplacementRecoveryDispositionInvalid
  deriving stock (Bounded, Enum, Eq, Show)

data TlsTerminalReplacementStagingDecision
  = TlsTerminalReplacementStaged
      !TlsLegacyRecoveryEvidence
      !TlsLegacyRecoverySuccessorEvidence
      !TlsPendingCollisionRecovery
      !TlsDisplacedPendingIdentity
      !TlsTerminalReplacementEvidence
      !TlsRetentionPending
  | TlsTerminalReplacementStagingNoop !TlsRetentionPending
  | TlsTerminalReplacementStagingRefused !TlsTerminalReplacementStagingRefusal
  deriving stock (Eq, Show)

-- | Stage a same-key replacement only from the exact current-less
-- legacy-recovery successor that proved version 3 unopenable. The resulting
-- state binds the version-4 occupant digest before any replace effect occurs.
decideTlsTerminalReplacementStaging
  :: KeyRotationApproval
  -> TlsRetentionState
  -> TlsPendingCollisionRecovery
  -> TlsTerminalReplacementEvidence
  -> RetainedTlsRef
  -> TlsSealedEnvelope
  -> TlsTerminalReplacementStagingDecision
decideTlsTerminalReplacementStaging approval state recovery terminalEvidence candidate envelope
  | Left _ <- validateTlsSealedEnvelope envelope =
      refused TlsTerminalReplacementStageEnvelopeInvalid
  | retainedCiphertextDigest candidate /= tlsSealedEnvelopeDigest envelope =
      refused TlsTerminalReplacementStageDigestMismatch
  | Left _ <- validateRetainedTlsRef candidate =
      refused TlsTerminalReplacementStageReferenceInvalid
  | otherwise = case state of
      TlsRetentionLegacyRecoverySuccessorPendingState evidence successor displacedPending ->
        let displaced = identityFor displacedPending
         in stage evidence successor displaced
      TlsRetentionLegacyRecoveryTerminalSuccessorState
        evidence
        successor
        existingRecovery
        displaced
        existingPending
          | existingRecovery == recovery
              && existingPending == desiredPending ->
              stage evidence successor displaced
          | otherwise -> refused TlsTerminalReplacementStageConcurrentPending
      TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState
        evidence
        successor
        existingRecovery
        displaced
        _
        _
        existingPending
          | existingRecovery == recovery
              && existingPending == desiredPending ->
              stage evidence successor displaced
          | otherwise -> refused TlsTerminalReplacementStageConcurrentPending
      TlsRetentionLegacyRecoveryTerminalReplacementState
        _
        _
        existingRecovery
        _
        existingTerminalEvidence
        pending
          | existingRecovery == recovery
              && existingTerminalEvidence == terminalEvidence
              && pending == desiredPending ->
              TlsTerminalReplacementStagingNoop pending
          | otherwise -> refused TlsTerminalReplacementStageConcurrentPending
      _ -> refused TlsTerminalReplacementStageStateNotSuccessor
 where
  desiredPending =
    TlsRetentionPending
      { tlsPendingPrevious = Nothing
      , tlsPendingApproval = approval
      , tlsPendingCandidate = candidate
      , tlsPendingEnvelope = envelope
      }
  identityFor pending =
    TlsDisplacedPendingIdentity
      { tlsDisplacedPendingPrevious = tlsPendingPrevious pending
      , tlsDisplacedPendingApproval = tlsPendingApproval pending
      , tlsDisplacedPendingCandidate = tlsPendingCandidate pending
      }
  stage evidence successor displaced =
    case validateTerminalReplacementEvidence
      evidence
      successor
      recovery
      displaced
      terminalEvidence
      desiredPending of
      Left cause -> refused (TlsTerminalReplacementStageEvidenceInvalid cause)
      Right () ->
        TlsTerminalReplacementStaged
          evidence
          successor
          recovery
          displaced
          terminalEvidence
          desiredPending
  refused = TlsTerminalReplacementStagingRefused

applyTlsTerminalReplacementStaging
  :: TlsTerminalReplacementStagingDecision
  -> TlsRetentionState
  -> TlsRetentionState
applyTlsTerminalReplacementStaging decision state = case decision of
  TlsTerminalReplacementStaged
    evidence
    successor
    recovery
    displaced
    terminalEvidence
    pending ->
      TlsRetentionLegacyRecoveryTerminalReplacementState
        evidence
        successor
        recovery
        displaced
        terminalEvidence
        pending
  TlsTerminalReplacementStagingNoop _ -> state
  TlsTerminalReplacementStagingRefused _ -> state

validatePendingCollisionState
  :: TlsPendingCollisionDisposition
  -> TlsPendingCollisionRecovery
  -> TlsDisplacedPendingIdentity
  -> TlsRetentionPending
  -> Either Text ()
validatePendingCollisionState expectedDisposition recovery displaced pending = do
  mapM_ validateRetainedTlsRef (tlsDisplacedPendingPrevious displaced)
  validateRetainedTlsRef displacedCandidate
  mapM_ validateRetainedTlsRef (tlsPendingPrevious pending)
  validateRetainedTlsRef candidate
  validateTlsSealedEnvelope (tlsPendingEnvelope pending)
  validateDigest displacedDigest
  validateDigest observedDigest
  if validRelationships
    then Right ()
    else Left "TLS pending-collision state is not a valid bounded recovery transition"
 where
  displacedCandidate = tlsDisplacedPendingCandidate displaced
  candidate = tlsPendingCandidate pending
  collisionVersion = tlsPendingCollisionVersion recovery
  displacedDigest = tlsPendingCollisionDisplacedEnvelopeDigest recovery
  observedDigest = tlsPendingCollisionObservedEnvelopeDigest recovery
  expectedOriginalVersion = case tlsDisplacedPendingPrevious displaced of
    Nothing -> RetentionVersion 1
    Just previous -> successorRetentionVersion (retainedVersion previous)
  originalDoesNotRegress = case tlsDisplacedPendingPrevious displaced of
    Nothing -> True
    Just previous ->
      certNotAfter (retainedCert displacedCandidate)
        >= certNotAfter (retainedCert previous)
  originalKeyChangeApproved = case tlsDisplacedPendingPrevious displaced of
    Nothing -> True
    Just previous ->
      certSpkiDigest (retainedCert displacedCandidate)
        == certSpkiDigest (retainedCert previous)
        || tlsDisplacedPendingApproval displaced == KeyRotationApproved
  dispositionRelationships = case expectedDisposition of
    TlsPendingCollisionAdoptObserved ->
      retainedVersion candidate == collisionVersion
        && retainedCiphertextDigest candidate == observedDigest
    TlsPendingCollisionStepPastUnopenable ->
      retainedVersion candidate == successorRetentionVersion collisionVersion
        && retainedCiphertextDigest candidate /= observedDigest
        && retainedCiphertextDigest candidate /= displacedDigest
  validRelationships =
    tlsPendingCollisionDisposition recovery == expectedDisposition
      && collisionVersion == retainedVersion displacedCandidate
      && retainedVersion displacedCandidate == expectedOriginalVersion
      && displacedDigest == retainedCiphertextDigest displacedCandidate
      && observedDigest /= displacedDigest
      && originalDoesNotRegress
      && originalKeyChangeApproved
      && tlsPendingPrevious pending == tlsDisplacedPendingPrevious displaced
      && tlsPendingApproval pending == tlsDisplacedPendingApproval displaced
      && retainedCert candidate == retainedCert displacedCandidate
      && retainedSourceSecret candidate == retainedSourceSecret displacedCandidate
      && retainedCiphertextDigest candidate == tlsSealedEnvelopeDigest (tlsPendingEnvelope pending)
      && dispositionRelationships

-- | Validate the narrower collision transition reached after the lane already
-- spent its one bounded skip. The displaced successor's full envelope is
-- compacted away exactly as in the ordinary collision states, so this fold
-- reconstructs the original unopenable-successor relation from its retained
-- predecessor, approval, candidate and skipped-version evidence. Only an
-- authenticated occupant at the same successor version can replace it.
validateUnopenableSuccessorCollisionState
  :: TlsUnopenableVersionEvidence
  -> TlsPendingCollisionRecovery
  -> TlsDisplacedPendingIdentity
  -> TlsRetentionPending
  -> Either Text ()
validateUnopenableSuccessorCollisionState evidence recovery displaced pending = do
  validateDigest (tlsUnopenableEnvelopeDigest evidence)
  mapM_ validateRetainedTlsRef (tlsDisplacedPendingPrevious displaced)
  validateRetainedTlsRef displacedCandidate
  mapM_ validateRetainedTlsRef (tlsPendingPrevious pending)
  validateRetainedTlsRef candidate
  validateTlsSealedEnvelope (tlsPendingEnvelope pending)
  validateDigest displacedDigest
  validateDigest observedDigest
  if validRelationships
    then Right ()
    else Left "TLS unopenable-successor collision state is not a valid same-version recovery"
 where
  displacedCandidate = tlsDisplacedPendingCandidate displaced
  candidate = tlsPendingCandidate pending
  collisionVersion = tlsPendingCollisionVersion recovery
  displacedDigest = tlsPendingCollisionDisplacedEnvelopeDigest recovery
  observedDigest = tlsPendingCollisionObservedEnvelopeDigest recovery
  validRelationships = case tlsDisplacedPendingPrevious displaced of
    Nothing -> False
    Just previous ->
      tlsPendingCollisionDisposition recovery == TlsPendingCollisionAdoptObserved
        && tlsUnopenableVersion evidence /= RetentionVersion 0
        && tlsUnopenableVersion evidence
          == successorRetentionVersion (retainedVersion previous)
        && tlsUnopenableEnvelopeDigest evidence /= retainedCiphertextDigest displacedCandidate
        && retainedVersion displacedCandidate == tlsUnopenableSuccessorVersion evidence
        && collisionVersion == retainedVersion displacedCandidate
        && displacedDigest == retainedCiphertextDigest displacedCandidate
        && observedDigest /= displacedDigest
        && tlsPendingPrevious pending == Just previous
        && tlsPendingApproval pending == tlsDisplacedPendingApproval displaced
        && retainedVersion candidate == collisionVersion
        && retainedCiphertextDigest candidate == observedDigest
        && retainedCiphertextDigest candidate
          == tlsSealedEnvelopeDigest (tlsPendingEnvelope pending)
        && retainedCert candidate == retainedCert displacedCandidate
        && retainedSourceSecret candidate == retainedSourceSecret displacedCandidate
        && certNotAfter (retainedCert displacedCandidate) >= certNotAfter (retainedCert previous)
        && ( certSpkiDigest (retainedCert displacedCandidate)
               == certSpkiDigest (retainedCert previous)
               || tlsDisplacedPendingApproval displaced == KeyRotationApproved
           )

-- | Validate the collision reached after the pre-Authority recovery lane has
-- already used its one fixed successor. The displaced version-3 envelope is
-- compacted to its identity, while the version-1 and version-2 evidence stays
-- intact. Only authenticated same-version adoption at version 3 is legal.
validateLegacyRecoverySuccessorCollisionState
  :: TlsLegacyRecoveryEvidence
  -> TlsLegacyRecoverySuccessorEvidence
  -> TlsPendingCollisionRecovery
  -> TlsDisplacedPendingIdentity
  -> TlsRetentionPending
  -> Either Text ()
validateLegacyRecoverySuccessorCollisionState evidence successor recovery displaced pending = do
  validateDigest (tlsLegacyRecoveryEnvelopeDigest evidence)
  validateDigest (tlsLegacyRecoveryPendingEnvelopeDigest firstCollision)
  validateDigest (tlsLegacyRecoveryObservedEnvelopeDigest firstCollision)
  validateDigest secondDisplacedDigest
  validateDigest secondObservedDigest
  validateRetainedTlsRef firstDisplacedCandidate
  validateRetainedTlsRef secondDisplacedCandidate
  validateRetainedTlsRef candidate
  validateTlsSealedEnvelope (tlsPendingEnvelope pending)
  if validRelationships
    then Right ()
    else Left "TLS legacy-recovery successor collision state is not a valid same-version recovery"
 where
  firstCollision = tlsLegacyRecoverySuccessorCollision successor
  firstDisplacedCandidate = tlsLegacyRecoveryDisplacedCandidate successor
  secondDisplacedCandidate = tlsDisplacedPendingCandidate displaced
  candidate = tlsPendingCandidate pending
  secondDisplacedDigest = tlsPendingCollisionDisplacedEnvelopeDigest recovery
  secondObservedDigest = tlsPendingCollisionObservedEnvelopeDigest recovery
  validRelationships =
    tlsLegacyRecoveryVersion evidence == RetentionVersion 1
      && tlsLegacyRecoveryCollisionVersion firstCollision == RetentionVersion 2
      && tlsLegacyRecoveryPendingEnvelopeDigest firstCollision
        == retainedCiphertextDigest firstDisplacedCandidate
      && tlsLegacyRecoveryObservedEnvelopeDigest firstCollision
        /= retainedCiphertextDigest firstDisplacedCandidate
      && tlsLegacyRecoveryObservedEnvelopeDigest firstCollision
        /= retainedCiphertextDigest secondDisplacedCandidate
      && retainedCiphertextDigest firstDisplacedCandidate
        /= retainedCiphertextDigest secondDisplacedCandidate
      && retainedVersion firstDisplacedCandidate == RetentionVersion 2
      && tlsDisplacedPendingPrevious displaced == Nothing
      && tlsDisplacedPendingApproval displaced
        == tlsLegacyRecoveryDisplacedApproval successor
      && retainedVersion secondDisplacedCandidate == RetentionVersion 3
      && retainedCert secondDisplacedCandidate == retainedCert firstDisplacedCandidate
      && retainedSourceSecret secondDisplacedCandidate
        == retainedSourceSecret firstDisplacedCandidate
      && tlsPendingCollisionDisposition recovery == TlsPendingCollisionAdoptObserved
      && tlsPendingCollisionVersion recovery == RetentionVersion 3
      && secondDisplacedDigest == retainedCiphertextDigest secondDisplacedCandidate
      && secondObservedDigest /= secondDisplacedDigest
      && tlsPendingPrevious pending == Nothing
      && tlsPendingApproval pending == tlsDisplacedPendingApproval displaced
      && retainedVersion candidate == RetentionVersion 3
      && retainedCiphertextDigest candidate == secondObservedDigest
      && retainedCiphertextDigest candidate
        == tlsSealedEnvelopeDigest (tlsPendingEnvelope pending)
      && retainedCert candidate == retainedCert secondDisplacedCandidate
      && retainedSourceSecret candidate == retainedSourceSecret secondDisplacedCandidate

-- | Validate the single terminal continuation admitted when the current-less
-- legacy-recovery chain has proven versions 1, 2, and 3 unusable. Version 4 is
-- fixed by the state relation; no constructor can derive a later version.
validateLegacyRecoveryTerminalSuccessorState
  :: TlsLegacyRecoveryEvidence
  -> TlsLegacyRecoverySuccessorEvidence
  -> TlsPendingCollisionRecovery
  -> TlsDisplacedPendingIdentity
  -> TlsRetentionPending
  -> Either Text ()
validateLegacyRecoveryTerminalSuccessorState evidence successor recovery displaced pending = do
  validateLegacyRecoveryTerminalPrefix evidence successor recovery displaced candidate
  validateTlsSealedEnvelope (tlsPendingEnvelope pending)
  if tlsPendingPrevious pending == Nothing
    && tlsPendingApproval pending == tlsDisplacedPendingApproval displaced
    && retainedCiphertextDigest candidate
      == tlsSealedEnvelopeDigest (tlsPendingEnvelope pending)
    then Right ()
    else Left "TLS legacy-recovery terminal successor state is not a valid fixed-version recovery"
 where
  candidate = tlsPendingCandidate pending

-- | Validate same-version adoption when fixed version 4 races with an
-- immutable occupant. The original terminal admission remains in the record,
-- and the new collision may only adopt at version 4.
validateLegacyRecoveryTerminalSuccessorRebasedState
  :: TlsLegacyRecoveryEvidence
  -> TlsLegacyRecoverySuccessorEvidence
  -> TlsPendingCollisionRecovery
  -> TlsDisplacedPendingIdentity
  -> TlsPendingCollisionRecovery
  -> TlsDisplacedPendingIdentity
  -> TlsRetentionPending
  -> Either Text ()
validateLegacyRecoveryTerminalSuccessorRebasedState
  evidence
  successor
  originalRecovery
  originalDisplaced
  recovery
  displaced
  pending = do
    validateLegacyRecoveryTerminalPrefix
      evidence
      successor
      originalRecovery
      originalDisplaced
      terminalDisplacedCandidate
    validateRetainedTlsRef terminalDisplacedCandidate
    validateRetainedTlsRef candidate
    validateDigest (tlsPendingCollisionDisplacedEnvelopeDigest recovery)
    validateDigest (tlsPendingCollisionObservedEnvelopeDigest recovery)
    validateTlsSealedEnvelope (tlsPendingEnvelope pending)
    if validRelationships
      then Right ()
      else Left "TLS legacy-recovery terminal successor rebase is not a valid same-version recovery"
   where
    terminalDisplacedCandidate = tlsDisplacedPendingCandidate displaced
    candidate = tlsPendingCandidate pending
    validRelationships =
      tlsDisplacedPendingPrevious displaced == Nothing
        && tlsDisplacedPendingApproval displaced
          == tlsDisplacedPendingApproval originalDisplaced
        && tlsPendingCollisionDisposition recovery == TlsPendingCollisionAdoptObserved
        && tlsPendingCollisionVersion recovery == RetentionVersion 4
        && tlsPendingCollisionDisplacedEnvelopeDigest recovery
          == retainedCiphertextDigest terminalDisplacedCandidate
        && tlsPendingCollisionObservedEnvelopeDigest recovery
          /= tlsPendingCollisionDisplacedEnvelopeDigest recovery
        && tlsPendingPrevious pending == Nothing
        && tlsPendingApproval pending == tlsDisplacedPendingApproval displaced
        && retainedVersion candidate == RetentionVersion 4
        && retainedCiphertextDigest candidate
          == tlsPendingCollisionObservedEnvelopeDigest recovery
        && retainedCiphertextDigest candidate
          == tlsSealedEnvelopeDigest (tlsPendingEnvelope pending)
        && retainedCert candidate == retainedCert terminalDisplacedCandidate
        && retainedSourceSecret candidate == retainedSourceSecret terminalDisplacedCandidate

validateLegacyRecoveryTerminalReplacementState
  :: TlsLegacyRecoveryEvidence
  -> TlsLegacyRecoverySuccessorEvidence
  -> TlsPendingCollisionRecovery
  -> TlsDisplacedPendingIdentity
  -> TlsTerminalReplacementEvidence
  -> TlsRetentionPending
  -> Either Text ()
validateLegacyRecoveryTerminalReplacementState
  evidence
  successor
  recovery
  displaced
  terminalEvidence
  pending = case validateTerminalReplacementEvidence
    evidence
    successor
    recovery
    displaced
    terminalEvidence
    pending of
    Left _ -> Left "TLS terminal replacement state evidence is invalid"
    Right () -> Right ()

validateTerminalReplacementEvidence
  :: TlsLegacyRecoveryEvidence
  -> TlsLegacyRecoverySuccessorEvidence
  -> TlsPendingCollisionRecovery
  -> TlsDisplacedPendingIdentity
  -> TlsTerminalReplacementEvidence
  -> TlsRetentionPending
  -> Either TlsTerminalReplacementEvidenceCause ()
validateTerminalReplacementEvidence
  evidence
  successor
  recovery
  displaced
  terminalEvidence
  pending
    | anyMalformed = Left TlsTerminalReplacementEvidenceMalformed
    | not validVersions = Left TlsTerminalReplacementVersionLineageInvalid
    | not validDigests = Left TlsTerminalReplacementDigestLineageInvalid
    | not validApprovals = Left TlsTerminalReplacementApprovalLineageInvalid
    | not validCertificates = Left TlsTerminalReplacementCertificateLineageInvalid
    | not validSourceUids = Left TlsTerminalReplacementSourceUidLineageInvalid
    | not validSourceResourceVersions =
        Left TlsTerminalReplacementSourceResourceVersionLineageInvalid
    | tlsPendingCollisionDisposition recovery /= TlsPendingCollisionStepPastUnopenable =
        Left TlsTerminalReplacementRecoveryDispositionInvalid
    | otherwise = Right ()
   where
    firstCollision = tlsLegacyRecoverySuccessorCollision successor
    firstDisplacedCandidate = tlsLegacyRecoveryDisplacedCandidate successor
    secondDisplacedCandidate = tlsDisplacedPendingCandidate displaced
    candidate = tlsPendingCandidate pending
    anyMalformed =
      any
        isInvalid
        [ validateDigest (tlsLegacyRecoveryEnvelopeDigest evidence)
        , validateDigest (tlsLegacyRecoveryPendingEnvelopeDigest firstCollision)
        , validateDigest (tlsLegacyRecoveryObservedEnvelopeDigest firstCollision)
        , validateDigest (tlsPendingCollisionDisplacedEnvelopeDigest recovery)
        , validateDigest (tlsPendingCollisionObservedEnvelopeDigest recovery)
        , validateRetainedTlsRef firstDisplacedCandidate
        , validateRetainedTlsRef secondDisplacedCandidate
        , validateRetainedTlsRef candidate
        , validateDigest (tlsTerminalReplacementOccupantEnvelopeDigest terminalEvidence)
        , validateTlsSealedEnvelope (tlsPendingEnvelope pending)
        ]
    validVersions =
      tlsLegacyRecoveryVersion evidence == RetentionVersion 1
        && tlsLegacyRecoveryCollisionVersion firstCollision == RetentionVersion 2
        && retainedVersion firstDisplacedCandidate == RetentionVersion 2
        && retainedVersion secondDisplacedCandidate == RetentionVersion 3
        && tlsPendingCollisionVersion recovery == RetentionVersion 3
        && retainedVersion candidate == RetentionVersion 4
        && tlsTerminalReplacementVersion terminalEvidence == RetentionVersion 4
        && tlsTerminalReplacementVersion terminalEvidence == retainedVersion candidate
    validDigests =
      tlsLegacyRecoveryPendingEnvelopeDigest firstCollision
        == retainedCiphertextDigest firstDisplacedCandidate
        && tlsLegacyRecoveryObservedEnvelopeDigest firstCollision
          /= retainedCiphertextDigest firstDisplacedCandidate
        && retainedCiphertextDigest secondDisplacedCandidate
          /= retainedCiphertextDigest firstDisplacedCandidate
        && retainedCiphertextDigest secondDisplacedCandidate
          /= tlsLegacyRecoveryObservedEnvelopeDigest firstCollision
        && tlsPendingCollisionDisplacedEnvelopeDigest recovery
          == retainedCiphertextDigest secondDisplacedCandidate
        && tlsPendingCollisionObservedEnvelopeDigest recovery
          /= tlsPendingCollisionDisplacedEnvelopeDigest recovery
        && retainedCiphertextDigest candidate
          /= tlsPendingCollisionObservedEnvelopeDigest recovery
        && retainedCiphertextDigest candidate
          /= tlsPendingCollisionDisplacedEnvelopeDigest recovery
        && tlsTerminalReplacementOccupantEnvelopeDigest terminalEvidence
          /= retainedCiphertextDigest candidate
        && retainedCiphertextDigest candidate
          == tlsSealedEnvelopeDigest (tlsPendingEnvelope pending)
    validApprovals =
      tlsDisplacedPendingPrevious displaced == Nothing
        && tlsDisplacedPendingApproval displaced
          == tlsLegacyRecoveryDisplacedApproval successor
        && tlsPendingPrevious pending == Nothing
        && tlsPendingApproval pending == tlsDisplacedPendingApproval displaced
    validCertificates =
      retainedCert secondDisplacedCandidate == retainedCert firstDisplacedCandidate
        && retainedCert candidate == retainedCert secondDisplacedCandidate
    validSourceUids =
      sourceSecretUid (retainedSourceSecret secondDisplacedCandidate)
        == sourceSecretUid (retainedSourceSecret firstDisplacedCandidate)
        && sourceSecretUid (retainedSourceSecret candidate)
          == sourceSecretUid (retainedSourceSecret secondDisplacedCandidate)
    validSourceResourceVersions =
      sourceSecretResourceVersion (retainedSourceSecret secondDisplacedCandidate)
        == sourceSecretResourceVersion (retainedSourceSecret firstDisplacedCandidate)
    isInvalid result = case result of
      Left _ -> True
      Right () -> False

validateLegacyRecoveryTerminalPrefix
  :: TlsLegacyRecoveryEvidence
  -> TlsLegacyRecoverySuccessorEvidence
  -> TlsPendingCollisionRecovery
  -> TlsDisplacedPendingIdentity
  -> RetainedTlsRef
  -> Either Text ()
validateLegacyRecoveryTerminalPrefix evidence successor recovery displaced candidate = do
  validateDigest (tlsLegacyRecoveryEnvelopeDigest evidence)
  validateDigest (tlsLegacyRecoveryPendingEnvelopeDigest firstCollision)
  validateDigest (tlsLegacyRecoveryObservedEnvelopeDigest firstCollision)
  validateDigest (tlsPendingCollisionDisplacedEnvelopeDigest recovery)
  validateDigest (tlsPendingCollisionObservedEnvelopeDigest recovery)
  validateRetainedTlsRef firstDisplacedCandidate
  validateRetainedTlsRef secondDisplacedCandidate
  validateRetainedTlsRef candidate
  if validRelationships
    then Right ()
    else Left "TLS legacy-recovery terminal successor prefix is invalid"
 where
  firstCollision = tlsLegacyRecoverySuccessorCollision successor
  firstDisplacedCandidate = tlsLegacyRecoveryDisplacedCandidate successor
  secondDisplacedCandidate = tlsDisplacedPendingCandidate displaced
  validRelationships =
    tlsLegacyRecoveryVersion evidence == RetentionVersion 1
      && tlsLegacyRecoveryCollisionVersion firstCollision == RetentionVersion 2
      && tlsLegacyRecoveryPendingEnvelopeDigest firstCollision
        == retainedCiphertextDigest firstDisplacedCandidate
      && tlsLegacyRecoveryObservedEnvelopeDigest firstCollision
        /= retainedCiphertextDigest firstDisplacedCandidate
      && retainedVersion firstDisplacedCandidate == RetentionVersion 2
      && tlsDisplacedPendingPrevious displaced == Nothing
      && tlsDisplacedPendingApproval displaced
        == tlsLegacyRecoveryDisplacedApproval successor
      && retainedVersion secondDisplacedCandidate == RetentionVersion 3
      && retainedCiphertextDigest secondDisplacedCandidate
        /= retainedCiphertextDigest firstDisplacedCandidate
      && retainedCiphertextDigest secondDisplacedCandidate
        /= tlsLegacyRecoveryObservedEnvelopeDigest firstCollision
      && retainedCert secondDisplacedCandidate == retainedCert firstDisplacedCandidate
      && retainedSourceSecret secondDisplacedCandidate
        == retainedSourceSecret firstDisplacedCandidate
      && tlsPendingCollisionDisposition recovery == TlsPendingCollisionStepPastUnopenable
      && tlsPendingCollisionVersion recovery == RetentionVersion 3
      && tlsPendingCollisionDisplacedEnvelopeDigest recovery
        == retainedCiphertextDigest secondDisplacedCandidate
      && tlsPendingCollisionObservedEnvelopeDigest recovery
        /= tlsPendingCollisionDisplacedEnvelopeDigest recovery
      && retainedVersion candidate == RetentionVersion 4
      && retainedCiphertextDigest candidate
        /= tlsPendingCollisionObservedEnvelopeDigest recovery
      && retainedCiphertextDigest candidate
        /= tlsPendingCollisionDisplacedEnvelopeDigest recovery
      && retainedCert candidate == retainedCert secondDisplacedCandidate
      && sourceSecretUid (retainedSourceSecret candidate)
        == sourceSecretUid (retainedSourceSecret secondDisplacedCandidate)

-- | Validate same-version adoption after an ordinary pending collision has
-- already admitted its one successor. The two collision records and both
-- compact displaced identities reconstruct the full bounded path.
validatePendingCollisionSuccessorRebasedState
  :: TlsPendingCollisionRecovery
  -> TlsDisplacedPendingIdentity
  -> TlsPendingCollisionRecovery
  -> TlsDisplacedPendingIdentity
  -> TlsRetentionPending
  -> Either Text ()
validatePendingCollisionSuccessorRebasedState
  originalRecovery
  originalDisplaced
  recovery
  displaced
  pending = do
    mapM_ validateRetainedTlsRef (tlsDisplacedPendingPrevious originalDisplaced)
    validateRetainedTlsRef originalCandidate
    validateRetainedTlsRef displacedCandidate
    validateRetainedTlsRef candidate
    validateDigest (tlsPendingCollisionDisplacedEnvelopeDigest originalRecovery)
    validateDigest (tlsPendingCollisionObservedEnvelopeDigest originalRecovery)
    validateDigest (tlsPendingCollisionDisplacedEnvelopeDigest recovery)
    validateDigest (tlsPendingCollisionObservedEnvelopeDigest recovery)
    validateTlsSealedEnvelope (tlsPendingEnvelope pending)
    if validRelationships
      then Right ()
      else Left "TLS pending-collision successor rebase is not a valid same-version recovery"
   where
    originalCandidate = tlsDisplacedPendingCandidate originalDisplaced
    displacedCandidate = tlsDisplacedPendingCandidate displaced
    candidate = tlsPendingCandidate pending
    originalVersion = tlsPendingCollisionVersion originalRecovery
    originalDisplacedDigest = tlsPendingCollisionDisplacedEnvelopeDigest originalRecovery
    originalObservedDigest = tlsPendingCollisionObservedEnvelopeDigest originalRecovery
    collisionVersion = tlsPendingCollisionVersion recovery
    displacedDigest = tlsPendingCollisionDisplacedEnvelopeDigest recovery
    observedDigest = tlsPendingCollisionObservedEnvelopeDigest recovery
    expectedOriginalVersion = case tlsDisplacedPendingPrevious originalDisplaced of
      Nothing -> RetentionVersion 1
      Just previous -> successorRetentionVersion (retainedVersion previous)
    originalDoesNotRegress = case tlsDisplacedPendingPrevious originalDisplaced of
      Nothing -> True
      Just previous ->
        certNotAfter (retainedCert originalCandidate)
          >= certNotAfter (retainedCert previous)
    originalKeyChangeApproved = case tlsDisplacedPendingPrevious originalDisplaced of
      Nothing -> True
      Just previous ->
        certSpkiDigest (retainedCert originalCandidate)
          == certSpkiDigest (retainedCert previous)
          || tlsDisplacedPendingApproval originalDisplaced == KeyRotationApproved
    validRelationships =
      tlsPendingCollisionDisposition originalRecovery
        == TlsPendingCollisionStepPastUnopenable
        && originalVersion == retainedVersion originalCandidate
        && originalVersion == expectedOriginalVersion
        && originalDisplacedDigest == retainedCiphertextDigest originalCandidate
        && originalObservedDigest /= originalDisplacedDigest
        && originalDoesNotRegress
        && originalKeyChangeApproved
        && tlsDisplacedPendingPrevious displaced
          == tlsDisplacedPendingPrevious originalDisplaced
        && tlsDisplacedPendingApproval displaced
          == tlsDisplacedPendingApproval originalDisplaced
        && retainedVersion displacedCandidate == successorRetentionVersion originalVersion
        && retainedCiphertextDigest displacedCandidate /= originalObservedDigest
        && retainedCiphertextDigest displacedCandidate /= originalDisplacedDigest
        && retainedCert displacedCandidate == retainedCert originalCandidate
        && retainedSourceSecret displacedCandidate == retainedSourceSecret originalCandidate
        && tlsPendingCollisionDisposition recovery == TlsPendingCollisionAdoptObserved
        && collisionVersion == retainedVersion displacedCandidate
        && displacedDigest == retainedCiphertextDigest displacedCandidate
        && observedDigest /= displacedDigest
        && tlsPendingPrevious pending == tlsDisplacedPendingPrevious displaced
        && tlsPendingApproval pending == tlsDisplacedPendingApproval displaced
        && retainedVersion candidate == collisionVersion
        && retainedCiphertextDigest candidate == observedDigest
        && retainedCiphertextDigest candidate
          == tlsSealedEnvelopeDigest (tlsPendingEnvelope pending)
        && retainedCert candidate == retainedCert displacedCandidate
        && retainedSourceSecret candidate == retainedSourceSecret displacedCandidate

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
      -- The Authority-owned successor lane is disjoint from this one by
      -- construction, and the disjointness is symmetric: that outbox is not a
      -- pre-outbox recovery this transition may rebase, replay, or supersede.
      TlsRetentionUnopenableSuccessorPendingState _ _ ->
        concurrentPending
      TlsRetentionPendingCollisionRebasedState {} ->
        concurrentPending
      TlsRetentionPendingCollisionSuccessorState {} ->
        concurrentPending
      TlsRetentionUnopenableSuccessorCollisionRebasedState {} ->
        concurrentPending
      TlsRetentionLegacyRecoverySuccessorCollisionRebasedState {} ->
        concurrentPending
      TlsRetentionPendingCollisionSuccessorRebasedState {} ->
        concurrentPending
      TlsRetentionLegacyRecoveryTerminalSuccessorState {} ->
        concurrentPending
      TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState {} ->
        concurrentPending
      TlsRetentionLegacyRecoveryTerminalReplacementState {} ->
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

data TlsUnopenableSuccessorStagingRefusal
  = -- | The evidence is not a well-formed statement about one object: a zero
    -- version, or a digest that is not a canonical lowercase SHA-256.
    TlsUnopenableSuccessorStageEvidenceInvalid
  | -- | The evidence names a version this state would not have selected. The
    -- admitted skip is exactly the version the committed reference was about
    -- to claim, so evidence about any other version authorizes nothing here.
    TlsUnopenableSuccessorStageSkippedVersionMismatch
  | -- | The candidate claims the skipped object's own bytes. A successor that
    -- re-asserted the unopenable digest would launder the envelope the lane is
    -- stepping past into a fresh version.
    TlsUnopenableSuccessorStageSkippedDigestReused
  | TlsUnopenableSuccessorStageEnvelopeInvalid
  | TlsUnopenableSuccessorStageReferenceInvalid
  | TlsUnopenableSuccessorStageDigestMismatch
  | -- | The candidate is not the exact single successor of the skipped
    -- version. One version, not a search.
    TlsUnopenableSuccessorStageVersionMismatch
  | -- | There is no committed reference to step forward from. The pre-outbox
    -- lane owns that case and is kept disjoint from this one.
    TlsUnopenableSuccessorStageStateNotCurrent
  | TlsUnopenableSuccessorStageConcurrentPending
  | TlsUnopenableSuccessorStageValidityRegression
  | TlsUnopenableSuccessorStageUnapprovedKeyChange
  deriving stock (Eq, Show)

data TlsUnopenableSuccessorStagingDecision
  = TlsUnopenableSuccessorStaged !TlsRetentionPending
  | TlsUnopenableSuccessorStagingNoop !TlsRetentionPending
  | TlsUnopenableSuccessorStagingRefused !TlsUnopenableSuccessorStagingRefusal
  deriving stock (Eq, Show)

-- | The one successor version this evidence admits.
--
-- Exposed because the interpreter must seal fresh certificate material /at/
-- that version before it can build a candidate to stage — the retention version
-- is part of the AEAD associated data — and a second derivation of "one past"
-- somewhere else is how a bounded step becomes a search.
tlsUnopenableSuccessorVersion :: TlsUnopenableVersionEvidence -> RetentionVersion
tlsUnopenableSuccessorVersion =
  successorRetentionVersion . tlsUnopenableVersion

-- | Stage the single successor admitted past an Authority-lane version proven
-- unopenable.
--
-- __Why this transition exists.__ 'retainTlsAtSelectedAgent' draws a fresh DEK
-- and nonce on every call, so the envelope a retain builds is not reproducible
-- and an occupied immutable version can never be written again. Sprint @6.5@'s
-- convergence closes every collision where the occupant opens: the retain
-- adopts it, proves it by applying it at the selected Target under an AEAD
-- whose associated data binds the version, certificate identity and source
-- Secret, and stages it through the ordinary transition. What that cannot close
-- is an occupant whose wrapped DEK does not open under
-- @prodbox-tls-retention-dek@ — it can be neither rewritten nor adopted, and
-- 'nextRetentionVersion' selects it on every future retain, so one unusable
-- object stops every retain on that slot forever.
--
-- __Why it is bounded to one version.__ The skipped version is pinned to the
-- one this state would itself have claimed and the candidate to its exact
-- successor, both checked against the durable predecessor rather than against
-- an argument. An unbounded search for a free integer is how a lane starts
-- silently skipping objects it should have refused; a second consecutive skip
-- therefore refuses rather than advancing.
--
-- __What it does not relax.__ Validity may not regress, a key change still
-- needs approval, the candidate digest must be the envelope's, and the state
-- must carry a committed predecessor. The skipped object is neither read,
-- overwritten, deleted, nor asserted to hold any certificate: only its digest
-- is retained, and only to say which object was proven unopenable.
decideTlsUnopenableSuccessorStaging
  :: KeyRotationApproval
  -> TlsRetentionState
  -> TlsUnopenableVersionEvidence
  -> RetainedTlsRef
  -> TlsSealedEnvelope
  -> TlsUnopenableSuccessorStagingDecision
decideTlsUnopenableSuccessorStaging approval state evidence candidate envelope
  | tlsUnopenableVersion evidence == RetentionVersion 0 =
      refused TlsUnopenableSuccessorStageEvidenceInvalid
  | Left _ <- validateDigest (tlsUnopenableEnvelopeDigest evidence) =
      refused TlsUnopenableSuccessorStageEvidenceInvalid
  | Left _ <- validateTlsSealedEnvelope envelope =
      refused TlsUnopenableSuccessorStageEnvelopeInvalid
  | retainedCiphertextDigest candidate /= tlsSealedEnvelopeDigest envelope =
      refused TlsUnopenableSuccessorStageDigestMismatch
  | Left _ <- validateRetainedTlsRef candidate =
      refused TlsUnopenableSuccessorStageReferenceInvalid
  | tlsUnopenableEnvelopeDigest evidence == retainedCiphertextDigest candidate =
      refused TlsUnopenableSuccessorStageSkippedDigestReused
  | otherwise = case state of
      TlsRetentionCurrent current -> decideAgainstCurrent current
      -- An exact replay re-decides against the predecessor the outbox itself
      -- retains and accepts only the pending already stored, so the replay
      -- predicate and the codec boundary's predicate are the same by
      -- construction rather than by two authors agreeing.
      TlsRetentionUnopenableSuccessorPendingState existingEvidence pending
        | existingEvidence == evidence
        , Just previous <- tlsPendingPrevious pending
        , decideAgainstCurrent previous == TlsUnopenableSuccessorStaged pending ->
            TlsUnopenableSuccessorStagingNoop pending
        -- A second successor stacked on a first is refused rather than
        -- admitted: the durable record already names the one version this lane
        -- stepped past, and stacking another is the search the bound forbids.
        | otherwise -> concurrentPending
      TlsRetentionEmpty -> refused TlsUnopenableSuccessorStageStateNotCurrent
      TlsRetentionPendingState _ -> concurrentPending
      TlsRetentionLegacyRecoveryPendingState _ _ -> concurrentPending
      TlsRetentionLegacyRecoveryCollisionPendingState {} -> concurrentPending
      TlsRetentionLegacyRecoverySuccessorPendingState {} -> concurrentPending
      TlsRetentionPendingCollisionRebasedState {} -> concurrentPending
      TlsRetentionPendingCollisionSuccessorState {} -> concurrentPending
      TlsRetentionUnopenableSuccessorCollisionRebasedState {} -> concurrentPending
      TlsRetentionLegacyRecoverySuccessorCollisionRebasedState {} -> concurrentPending
      TlsRetentionPendingCollisionSuccessorRebasedState {} -> concurrentPending
      TlsRetentionLegacyRecoveryTerminalSuccessorState {} -> concurrentPending
      TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState {} -> concurrentPending
      TlsRetentionLegacyRecoveryTerminalReplacementState {} -> concurrentPending
 where
  refused = TlsUnopenableSuccessorStagingRefused
  concurrentPending = refused TlsUnopenableSuccessorStageConcurrentPending
  -- Deliberately a pattern match on 'TlsRetentionCurrent' rather than a
  -- 'currentRetainedRef' lookup: an ordinary pending outbox also answers
  -- @Just previous@, and admitting a skip from one would step over a version
  -- some other candidate is already staged for.
  decideAgainstCurrent current
    | tlsUnopenableVersion evidence
        /= nextRetentionVersion (TlsRetentionCurrent current) =
        refused TlsUnopenableSuccessorStageSkippedVersionMismatch
    | retainedVersion candidate /= tlsUnopenableSuccessorVersion evidence =
        refused TlsUnopenableSuccessorStageVersionMismatch
    | certNotAfter (retainedCert candidate) < certNotAfter (retainedCert current) =
        refused TlsUnopenableSuccessorStageValidityRegression
    | certSpkiDigest (retainedCert candidate) /= certSpkiDigest (retainedCert current)
    , approval == KeyRotationNotApproved =
        refused TlsUnopenableSuccessorStageUnapprovedKeyChange
    | otherwise = TlsUnopenableSuccessorStaged (desiredPendingFor current)

  desiredPendingFor previous =
    TlsRetentionPending
      { tlsPendingPrevious = Just previous
      , tlsPendingApproval = approval
      , tlsPendingCandidate = candidate
      , tlsPendingEnvelope = envelope
      }

applyTlsUnopenableSuccessorStaging
  :: TlsUnopenableVersionEvidence
  -> TlsUnopenableSuccessorStagingDecision
  -> TlsRetentionState
  -> TlsRetentionState
applyTlsUnopenableSuccessorStaging evidence decision state = case decision of
  TlsUnopenableSuccessorStaged pending ->
    TlsRetentionUnopenableSuccessorPendingState evidence pending
  TlsUnopenableSuccessorStagingNoop _ -> state
  TlsUnopenableSuccessorStagingRefused _ -> state

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
      -- These recovery states retain their predecessor, so promotion is still
      -- judged against a committed reference: the successor must be strictly
      -- newer than it, must not regress its validity, and still needs approval
      -- to change its key.
      TlsRetentionUnopenableSuccessorPendingState _ pending
        | tlsPendingCandidate pending /= candidate
            || tlsPendingApproval pending /= approval ->
            TlsPromotionRefused TlsPendingMismatch
        | otherwise -> decideAgainstPrevious (tlsPendingPrevious pending)
      TlsRetentionPendingCollisionRebasedState _ _ pending
        | tlsPendingCandidate pending /= candidate
            || tlsPendingApproval pending /= approval ->
            TlsPromotionRefused TlsPendingMismatch
        | otherwise -> decideAgainstPrevious (tlsPendingPrevious pending)
      TlsRetentionPendingCollisionSuccessorState _ _ pending
        | tlsPendingCandidate pending /= candidate
            || tlsPendingApproval pending /= approval ->
            TlsPromotionRefused TlsPendingMismatch
        | otherwise -> decideAgainstPrevious (tlsPendingPrevious pending)
      TlsRetentionUnopenableSuccessorCollisionRebasedState _ _ _ pending
        | tlsPendingCandidate pending /= candidate
            || tlsPendingApproval pending /= approval ->
            TlsPromotionRefused TlsPendingMismatch
        | otherwise -> decideAgainstPrevious (tlsPendingPrevious pending)
      TlsRetentionLegacyRecoverySuccessorCollisionRebasedState _ _ _ _ pending
        | tlsPendingCandidate pending /= candidate
            || tlsPendingApproval pending /= approval ->
            TlsPromotionRefused TlsPendingMismatch
        | otherwise -> decideAgainstPrevious Nothing
      TlsRetentionPendingCollisionSuccessorRebasedState _ _ _ _ pending
        | tlsPendingCandidate pending /= candidate
            || tlsPendingApproval pending /= approval ->
            TlsPromotionRefused TlsPendingMismatch
        | otherwise -> decideAgainstPrevious (tlsPendingPrevious pending)
      TlsRetentionLegacyRecoveryTerminalSuccessorState _ _ _ _ pending
        | tlsPendingCandidate pending /= candidate
            || tlsPendingApproval pending /= approval ->
            TlsPromotionRefused TlsPendingMismatch
        | otherwise -> decideAgainstPrevious Nothing
      TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState _ _ _ _ _ _ pending
        | tlsPendingCandidate pending /= candidate
            || tlsPendingApproval pending /= approval ->
            TlsPromotionRefused TlsPendingMismatch
        | otherwise -> decideAgainstPrevious Nothing
      TlsRetentionLegacyRecoveryTerminalReplacementState _ _ _ _ _ pending
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
    -- The predecessor stayed restorable throughout: the unopenable object is
    -- the successor slot, never the committed reference.
    TlsRetentionUnopenableSuccessorPendingState _ pending ->
      case tlsPendingPrevious pending of
        Just current
          | retainedVersion observed == retainedVersion current
              && retainedCiphertextDigest observed == retainedCiphertextDigest current ->
              TlsRestoreApply current
        _ -> TlsRestoreRefused TlsRestoreReferenceMismatch
    TlsRetentionPendingCollisionRebasedState _ _ pending ->
      restorePendingPrevious pending observed
    TlsRetentionPendingCollisionSuccessorState _ _ pending ->
      restorePendingPrevious pending observed
    TlsRetentionUnopenableSuccessorCollisionRebasedState _ _ _ pending ->
      restorePendingPrevious pending observed
    TlsRetentionLegacyRecoverySuccessorCollisionRebasedState {} ->
      TlsRestoreRefused TlsRestoreReferenceMismatch
    TlsRetentionPendingCollisionSuccessorRebasedState _ _ _ _ pending ->
      restorePendingPrevious pending observed
    TlsRetentionLegacyRecoveryTerminalSuccessorState {} ->
      TlsRestoreRefused TlsRestoreReferenceMismatch
    TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState {} ->
      TlsRestoreRefused TlsRestoreReferenceMismatch
    TlsRetentionLegacyRecoveryTerminalReplacementState {} ->
      TlsRestoreRefused TlsRestoreReferenceMismatch
  RestoreCommittedAbsent -> issueUnlessRecoveryPending state
  RestoreTrustedTimeExpired -> issueUnlessRecoveryPending state
  RestoreCommittedCorrupt -> TlsRestoreRefused TlsRestoreCorrupt
  RestoreCommittedUnobservable -> TlsRestoreRefused TlsRestoreUnobservable

restorePendingPrevious
  :: TlsRetentionPending
  -> RetainedTlsRef
  -> TlsRestoreDecision
restorePendingPrevious pending observed = case tlsPendingPrevious pending of
  Just current
    | retainedVersion observed == retainedVersion current
        && retainedCiphertextDigest observed == retainedCiphertextDigest current ->
        TlsRestoreApply current
  _ -> TlsRestoreRefused TlsRestoreReferenceMismatch

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
  TlsRetentionUnopenableSuccessorPendingState _ pending
    | tlsPendingPrevious pending == Nothing ->
        TlsRestoreRefused TlsRestoreRecoveryPending
  TlsRetentionPendingCollisionRebasedState _ _ pending
    | tlsPendingPrevious pending == Nothing ->
        TlsRestoreRefused TlsRestoreRecoveryPending
  TlsRetentionPendingCollisionSuccessorState _ _ pending
    | tlsPendingPrevious pending == Nothing ->
        TlsRestoreRefused TlsRestoreRecoveryPending
  TlsRetentionUnopenableSuccessorCollisionRebasedState _ _ _ pending
    | tlsPendingPrevious pending == Nothing ->
        TlsRestoreRefused TlsRestoreRecoveryPending
  TlsRetentionLegacyRecoverySuccessorCollisionRebasedState {} ->
    TlsRestoreRefused TlsRestoreRecoveryPending
  TlsRetentionPendingCollisionSuccessorRebasedState _ _ _ _ pending
    | tlsPendingPrevious pending == Nothing ->
        TlsRestoreRefused TlsRestoreRecoveryPending
  TlsRetentionLegacyRecoveryTerminalSuccessorState {} ->
    TlsRestoreRefused TlsRestoreRecoveryPending
  TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState {} ->
    TlsRestoreRefused TlsRestoreRecoveryPending
  TlsRetentionLegacyRecoveryTerminalReplacementState {} ->
    TlsRestoreRefused TlsRestoreRecoveryPending
  _ -> TlsRestoreIssue
