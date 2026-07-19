{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.61 Increment B: the single IO boundary that runs a capability
-- program against the SAME opaque reference used to observe and admit it
-- (bootstrap_readiness §0.2, §3.3). Everything typed and pure stays upstream; the
-- only IO here is the boundary-owned monotonic clock, bounded-queue admission,
-- and the three service lanes carried by 'CapabilityClient'. Additive: no
-- consumer is wired; a fake client makes it trivially testable, and a real
-- @newCapabilityClient@ (deferred) builds the HTTP manager / Vault session /
-- clock / queues ONCE and captures them in the lane closures, so per §9 a lane
-- never parses config, reads a token, logs in to Vault, or builds a manager per
-- request.
module Prodbox.ControlPlane.Interpreter
  ( CapabilityFailure (..)
  , LaneFault (..)
  , QueueAdmission (..)
  , ObservedReading (..)
  , CasRequest (..)
  , CommitRequest (..)
  , CapabilityClient (..)
  , runCapability
  , realMonotonicNow
  )
where

import Data.Text (Text)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.ControlPlane.CapabilityKind (CapabilityOp)
import Prodbox.ControlPlane.CapabilityRef
  ( CapabilityRef
  , refCapabilityOp
  , refCoordinate
  , refCoordinateDigest
  )
import Prodbox.ControlPlane.Coordinate
  ( AuthorityScope
  , CapabilityCoordinate
  , CoordinateDigest
  , ServiceIdentity
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , DeadlineObservation (DeadlineExpired, DeadlineOpen)
  , MonotonicInstant
  , RemainingDuration
  , RetryAfter
  , deadlineObservation
  , monotonicInstantFromMicros
  )
import Prodbox.ControlPlane.Observation
  ( ExternalEvidence
  , FreshnessWindow
  , ObservationReading (..)
  , observationFromRef
  )
import Prodbox.ControlPlane.Permit
  ( FenceEvidence
  , IntentBinding
  , permitCoordinateDigest
  , permitFence
  , permitGeneration
  , verifiedBinding
  , verifiedCoordinateDigest
  )
import Prodbox.ControlPlane.Program
  ( CapabilityProgram (ExternalCommit, InternalCas, Observe)
  , CasOutcome
  , CommitOutcome
  , ExpectedVersion
  , PayloadDigest
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Lifecycle.TargetCommitIntent (CredentialGeneration)

-- | Flat interpreter failure — strictly "could not get an outcome". A successful
-- observation of an unreachable target is NOT here (it is 'EvidenceUnreachable'
-- inside the returned observation); a CAS/commit that round-trips and reports a
-- conflict is NOT here (it is 'CasConflict'/'CommitRejected', a 'Right').
data CapabilityFailure
  = -- | Monotonic deadline reached before dispatch. No side effect.
    FailureDeadlineExpired
  | -- | Bounded-queue admission refused; retry no sooner than the hint. No side
    -- effect.
    FailureSaturated !RetryAfter
  | -- | OBSERVE path: no authoritative reading at all (fail-closed, never
    -- "absent").
    FailureUnobservable !Text
  | -- | MUTATION path: the request definitely never left; the mutation did NOT
    -- run and is safe to retry.
    FailureUnavailable !Text
  | -- | MUTATION path: the request was dispatched but the response was lost; the
    -- outcome is INDETERMINATE and must be resolved by operation-id read-back,
    -- never treated as failure.
    FailureAmbiguous !Text
  | -- | The interpreter's own same-reference guard: a permit/intent whose
    -- coordinate digest differs from the execution reference's. Structural,
    -- never retryable.
    FailureRefused !Text
  deriving (Eq, Show)

-- | A boundary transport condition a service lane reports (distinct from a remote
-- condition, which the lane encodes in its own result type — 'ExternalEvidence' /
-- 'CasOutcome' / 'CommitOutcome').
data LaneFault
  = -- | Could not dispatch: the request never left.
    LaneUnavailable !Text
  | -- | Request sent, response lost/timed out: outcome unknown.
    LaneAmbiguous !Text
  deriving (Eq, Show)

data QueueAdmission
  = Admitted
  | Saturated !RetryAfter
  deriving (Eq, Show)

-- | The observed facts a service lane reports for an Observe. The interpreter —
-- not the lane — owns the freshness window (a program input) and the coordinate
-- binding (via the ref), so this record carries NEITHER, and a lane physically
-- cannot forge either.
data ObservedReading = ObservedReading
  { observedService :: !ServiceIdentity
  , observedAuthority :: !AuthorityScope
  , observedGeneration :: !CredentialGeneration
  , observedAt :: !AuthorityTime
  , observedEvidence :: !ExternalEvidence
  }
  deriving (Eq, Show)

-- | The InternalCas program + permit projected to value level for the untyped
-- lane. 'casCoordinateDigest' is stamped FROM THE REFERENCE by 'runCapability'
-- (not read off the permit); the fence still carries the permit's own digest so
-- the lane can assert they agree. The lane receives the opaque current generation
-- (§9) here; it never fetches it.
data CasRequest = CasRequest
  { casCoordinateDigest :: !CoordinateDigest
  , casFence :: !FenceEvidence
  , casPermitGeneration :: !CredentialGeneration
  , casCurrentGeneration :: !CredentialGeneration
  , casExpectedVersion :: !ExpectedVersion
  , casPayloadDigest :: !PayloadDigest
  , casRemaining :: !RemainingDuration
  }

data CommitRequest = CommitRequest
  { commitCoordinateDigest :: !CoordinateDigest
  , commitBinding :: !IntentBinding
  , commitCurrentGeneration :: !CredentialGeneration
  , commitRemaining :: !RemainingDuration
  }

-- | The boundary-owned service client/router. ONE value, NOT indexed by @k@ (it
-- holds the router, so the graph never smuggles a per-kind client). The three
-- lane fields ARE the router; each internally dispatches on 'CapabilityOp' to a
-- concrete service. Every field is un-indexed plain data in / plain data out,
-- which is what makes an in-memory fake trivial — all kind-indexed safety already
-- happened in the pure algebra that produced the 'WriterPermit'/'VerifiedIntent'
-- handed to 'runCapability'.
data CapabilityClient = CapabilityClient
  { clientCurrentGeneration :: !CredentialGeneration
  -- ^ opaque current generation, established ONCE from the unsealed authority
  -- epoch and handed to every lane; never re-derived per call (§9).
  , clientMonotonicNow :: IO MonotonicInstant
  -- ^ the process-local monotonic clock, read once per 'runCapability' entry.
  , clientAdmit :: CapabilityOp -> IO QueueAdmission
  -- ^ non-blocking bounded-queue capacity check (§0.8): accept, or reject fast
  -- with a retry hint.
  , clientObserve
      :: CapabilityOp
      -> CapabilityCoordinate
      -> FreshnessWindow
      -> RemainingDuration
      -> IO (Either LaneFault ObservedReading)
  , clientInternalCas
      :: CapabilityOp
      -> CapabilityCoordinate
      -> CasRequest
      -> IO (Either LaneFault CasOutcome)
  , clientExternalCommit
      :: CapabilityOp
      -> CapabilityCoordinate
      -> CommitRequest
      -> IO (Either LaneFault CommitOutcome)
  }

-- | Run a program against the SAME reference that observed and admitted it. The
-- program's @k@ equals the reference's @k@ at compile time, so an observe-only
-- reference cannot carry a CAS program and a probe endpoint cannot be supplied
-- separately — the endpoint is @coordEndpoint (refCoordinate ref)@, from this
-- ref. Single-shot: it returns a typed failure and does NOT retry (retry
-- classification is a separate pure layer). The deadline is read once from the
-- client's monotonic clock; the remaining budget is handed to the lane to bound
-- its own I/O.
runCapability
  :: CapabilityClient
  -> CapabilityRef k
  -> Deadline
  -> CapabilityProgram k result
  -> IO (Either CapabilityFailure result)
runCapability client ref deadline program = do
  now <- clientMonotonicNow client
  case deadlineObservation now deadline of
    DeadlineExpired -> pure (Left FailureDeadlineExpired)
    DeadlineOpen remaining -> do
      -- 'remaining' is computed here, once, and the deadline is NOT re-checked
      -- after admission. That is correct only while 'clientAdmit' is genuinely
      -- non-blocking (a fast capacity check, §0.8): a blocking/queueing admit
      -- would hand the lane an over-stated I/O budget. The real client must keep
      -- admit non-blocking, or re-observe the deadline after it.
      admission <- clientAdmit client op
      case admission of
        Saturated retryAfter -> pure (Left (FailureSaturated retryAfter))
        Admitted -> case program of
          Observe freshness -> do
            observeOutcome <- clientObserve client op coordinate freshness remaining
            pure $ case observeOutcome of
              Left fault -> Left (observeFault fault)
              Right observed ->
                Right (observationFromRef ref (toReading freshness observed))
          InternalCas permit expected payload
            | permitCoordinateDigest permit /= refDigest ->
                pure (Left (FailureRefused refusalPermit))
            | otherwise -> do
                let request =
                      CasRequest
                        { casCoordinateDigest = refDigest
                        , casFence = permitFence permit
                        , casPermitGeneration = permitGeneration permit
                        , casCurrentGeneration = clientCurrentGeneration client
                        , casExpectedVersion = expected
                        , casPayloadDigest = payload
                        , casRemaining = remaining
                        }
                mapMutation <$> clientInternalCas client op coordinate request
          ExternalCommit intent
            | verifiedCoordinateDigest intent /= refDigest ->
                pure (Left (FailureRefused refusalIntent))
            | otherwise -> do
                let request =
                      CommitRequest
                        { commitCoordinateDigest = refDigest
                        , commitBinding = verifiedBinding intent
                        , commitCurrentGeneration = clientCurrentGeneration client
                        , commitRemaining = remaining
                        }
                mapMutation <$> clientExternalCommit client op coordinate request
 where
  op = refCapabilityOp ref
  coordinate = refCoordinate ref
  refDigest = refCoordinateDigest ref

  refusalPermit :: Text
  refusalPermit = "writer permit is bound to a different coordinate than the execution reference"

  refusalIntent :: Text
  refusalIntent = "verified intent is bound to a different coordinate than the execution reference"

  observeFault :: LaneFault -> CapabilityFailure
  observeFault (LaneUnavailable detail) = FailureUnobservable detail
  observeFault (LaneAmbiguous detail) = FailureUnobservable detail

  toReading :: FreshnessWindow -> ObservedReading -> ObservationReading
  toReading freshness observed =
    ObservationReading
      { readingService = observedService observed
      , readingAuthority = observedAuthority observed
      , readingGeneration = observedGeneration observed
      , readingObservedAt = observedAt observed
      , readingFreshnessBound = freshness
      , readingEvidence = observedEvidence observed
      }

  mapMutation :: Either LaneFault a -> Either CapabilityFailure a
  mapMutation (Right value) = Right value
  mapMutation (Left (LaneUnavailable detail)) = Left (FailureUnavailable detail)
  mapMutation (Left (LaneAmbiguous detail)) = Left (FailureAmbiguous detail)

-- | The real monotonic clock, all-Natural micros — the only piece of a real
-- 'CapabilityClient' that lands now; the rest of the boundary is deferred.
realMonotonicNow :: IO MonotonicInstant
realMonotonicNow =
  monotonicInstantFromMicros . fromIntegral . (`div` 1000) <$> getMonotonicTimeNSec
