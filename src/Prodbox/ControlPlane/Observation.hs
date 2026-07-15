{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Sprint 1.61: flat external evidence, its pure classifiers, and the admission
-- ticket. This module encodes the two axes that make "a GET satisfies a
-- write/CAS dependency" unrepresentable:
--
--   * VALUE axis — 'ExternalEvidence' keeps read-shaped evidence
--     ('EvidencePresentReady', a bare GET) DISTINCT from write-shaped evidence
--     ('EvidenceRoundTripConfirmed', a proven CAS round trip). 'classifyEvidence'
--     returns 'Ready' for a present-object GET only when the operation does not
--     require round-trip evidence; a mutating operation's GET is 'Pending'.
--   * TYPE axis — an 'AdmissionTicket' is indexed by the same @k@ as the
--     reference/observation that produced it, so a ticket minted for one
--     operation cannot admit another.
--
-- The admission ticket is opaque and its SOLE producer is 'classifyObservation',
-- which fails CLOSED (stale/unfresh → 'VerdictUnobservable') and binds the ticket
-- to the observed coordinate digest, generation, and observation time.
module Prodbox.ControlPlane.Observation
  ( -- * Evidence and status
    FreshnessWindow (..)
  , RoundTripWitness (..)
  , ExternalEvidence (..)
  , ObservationStatus (..)
  , classifyEvidence

    -- * Observations (bound to the reference that produced them)
  , CapabilityObservation
  , ObservationReading (..)
  , observationFromRef
  , obsCoordinateDigest
  , obsEvidence

    -- * Admission
  , ExpectedAuthority (..)
  , expectedAuthorityFromRef
  , AdmissionTicket
  , admissionCoordinateDigest
  , admissionGeneration
  , admissionObservedAt
  , ReadinessVerdict (..)
  , classifyObservation
  )
where

import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.CapabilityKind
  ( CapabilityKind
  , CapabilityOp
  , KnownCapability (capabilityOp)
  , requiresRoundTripEvidence
  )
import Prodbox.ControlPlane.CapabilityRef
  ( CapabilityRef
  , refCoordinate
  , refCoordinateDigest
  )
import Prodbox.ControlPlane.Coordinate
  ( AuthorityScope
  , CoordinateDigest
  , ServiceIdentity
  , coordAuthority
  , coordGeneration
  , coordService
  )
import Prodbox.Lifecycle.CheckpointAuthority (ModelBObjectVersion)
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Lifecycle.TargetCommitIntent (CredentialGeneration)

-- | The maximum age (seconds) an observation may have before it is treated as
-- unobservable rather than authoritative.
newtype FreshnessWindow = FreshnessWindow Natural
  deriving (Eq, Ord, Show)

-- | Proof that a write/CAS round trip actually reached the store — the Model-B
-- object version it produced (read back after the conditional put).
newtype RoundTripWitness = RoundTripWitness ModelBObjectVersion
  deriving (Eq, Show)

-- | The one flat exhaustive external reading. Read-shaped and write-shaped
-- evidence are distinct constructors; "cannot observe" is never folded into
-- "absent".
data ExternalEvidence
  = -- | The object is positively absent.
    EvidenceAbsent
  | -- | A GET found the object present / converged (READ-shaped evidence).
    EvidencePresentReady
  | -- | The object was observed but is stale.
    EvidencePresentStale !Text
  | -- | A write/CAS canary round-tripped (WRITE-shaped evidence).
    EvidenceRoundTripConfirmed !RoundTripWitness
  | EvidencePending !Text
  | EvidenceConflict !Text
  | EvidenceCorrupt !Text
  | -- | Could not authoritatively observe; fails closed.
    EvidenceUnreachable !Text
  deriving (Eq, Show)

-- | The flat readiness status a piece of evidence folds to.
data ObservationStatus
  = Ready
  | Pending !Text
  | Failed !Text
  | Unobservable !Text
  deriving (Eq, Show)

-- | The GET-vs-write core. A present-object GET satisfies only operations that do
-- not require round-trip evidence; a mutating operation's GET is 'Pending'. A
-- proven round trip is 'Ready' for any operation. "Cannot observe" (unreachable
-- / corrupt) fails closed to 'Unobservable' and is never 'Ready'.
classifyEvidence :: CapabilityOp -> ExternalEvidence -> ObservationStatus
classifyEvidence op evidence = case evidence of
  EvidenceUnreachable detail -> Unobservable detail
  EvidenceCorrupt detail -> Unobservable detail
  EvidenceConflict detail -> Pending detail
  EvidencePending detail -> Pending detail
  EvidenceAbsent -> Pending "object is absent"
  EvidencePresentStale detail -> Pending detail
  EvidenceRoundTripConfirmed _ -> Ready
  EvidencePresentReady ->
    if requiresRoundTripEvidence op
      then Pending "a present-object GET cannot prove a write/CAS round trip"
      else Ready

-- | The per-probe fields an interpreter reads. Combined with the reference by
-- 'observationFromRef', which stamps the reference's coordinate digest so the
-- reading is always bound to the reference that produced it.
data ObservationReading = ObservationReading
  { readingService :: !ServiceIdentity
  , readingAuthority :: !AuthorityScope
  , readingGeneration :: !CredentialGeneration
  , readingObservedAt :: !AuthorityTime
  , readingFreshnessBound :: !FreshnessWindow
  , readingEvidence :: !ExternalEvidence
  }
  deriving (Eq, Show)

-- | The @nominal@ role blocks re-labelling an observation across operations.
type role CapabilityObservation nominal

data CapabilityObservation (k :: CapabilityKind) = MkObservation
  { obsService :: !ServiceIdentity
  , obsAuthority :: !AuthorityScope
  , obsGeneration :: !CredentialGeneration
  , obsObservedAt :: !AuthorityTime
  , obsFreshnessBound :: !FreshnessWindow
  , obsCoordinateDigest :: !CoordinateDigest
  , obsEvidence :: !ExternalEvidence
  }

-- | The sole observation producer: it stamps the reference's coordinate digest,
-- so an observation is always bound to the reference that produced it (and thus
-- to the exact operation @k@).
observationFromRef :: CapabilityRef k -> ObservationReading -> CapabilityObservation k
observationFromRef ref reading =
  MkObservation
    { obsService = readingService reading
    , obsAuthority = readingAuthority reading
    , obsGeneration = readingGeneration reading
    , obsObservedAt = readingObservedAt reading
    , obsFreshnessBound = readingFreshnessBound reading
    , obsCoordinateDigest = refCoordinateDigest ref
    , obsEvidence = readingEvidence reading
    }

-- | What a dependent edge requires of an observation before it will admit work.
data ExpectedAuthority (k :: CapabilityKind) = ExpectedAuthority
  { expectService :: !ServiceIdentity
  , expectScope :: !AuthorityScope
  , expectGeneration :: !CredentialGeneration
  , expectDigest :: !CoordinateDigest
  }

-- | The expectation a reference itself encodes (its coordinate's fields + digest).
expectedAuthorityFromRef :: CapabilityRef k -> ExpectedAuthority k
expectedAuthorityFromRef ref =
  ExpectedAuthority
    { expectService = coordService (refCoordinate ref)
    , expectScope = coordAuthority (refCoordinate ref)
    , expectGeneration = coordGeneration (refCoordinate ref)
    , expectDigest = refCoordinateDigest ref
    }

-- | The @nominal@ role keeps a ticket bound to its operation.
type role AdmissionTicket nominal

data AdmissionTicket (k :: CapabilityKind) = MkAdmissionTicket
  { admissionCoordinateDigest :: !CoordinateDigest
  , admissionGeneration :: !CredentialGeneration
  , admissionObservedAt :: !AuthorityTime
  }

data ReadinessVerdict (k :: CapabilityKind)
  = -- | The only constructor carrying a ticket.
    VerdictReady !(AdmissionTicket k)
  | VerdictPending !Text
  | VerdictFailed !Text
  | VerdictUnobservable !Text

-- | The sole admission-ticket producer. Same-reference (coordinate digest),
-- same service/authority, fresh, non-stale generation, and a 'Ready' evidence
-- fold — or nothing. Every gate fails closed.
classifyObservation
  :: forall k
   . (KnownCapability k)
  => AuthorityTime
  -> ExpectedAuthority k
  -> CapabilityObservation k
  -> ReadinessVerdict k
classifyObservation now expected obs
  | obsCoordinateDigest obs /= expectDigest expected =
      VerdictFailed "capability coordinate digest does not match the required authority"
  | obsService obs /= expectService expected =
      VerdictFailed "observed service identity does not match the required authority"
  | obsAuthority obs /= expectScope expected =
      VerdictFailed "observed authority scope does not match the required authority"
  | not (withinFreshness (obsFreshnessBound obs) (obsObservedAt obs) now) =
      VerdictUnobservable "observation is stale beyond its freshness window"
  | obsGeneration obs < expectGeneration expected =
      VerdictPending "observed generation is older than the required generation"
  | otherwise =
      case classifyEvidence (capabilityOp @k) (obsEvidence obs) of
        Ready ->
          VerdictReady
            ( MkAdmissionTicket
                (obsCoordinateDigest obs)
                (obsGeneration obs)
                (obsObservedAt obs)
            )
        Pending detail -> VerdictPending detail
        Failed detail -> VerdictFailed detail
        Unobservable detail -> VerdictUnobservable detail

-- | An observation is fresh when it is not in the future and no older than its
-- freshness window (seconds). Both bounds fail closed in 'classifyObservation'.
withinFreshness :: FreshnessWindow -> AuthorityTime -> AuthorityTime -> Bool
withinFreshness (FreshnessWindow windowSeconds) observedAt now =
  observedMicros <= nowMicros
    && nowMicros <= observedMicros + windowSeconds * 1000000
 where
  observedMicros = authorityTimeMicros observedAt
  nowMicros = authorityTimeMicros now
