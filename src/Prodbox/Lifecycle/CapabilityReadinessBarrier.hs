{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Sprint 1.61 driver cutover: drive a component's readiness barrier through the
-- SINGLE capability handle (its 'SomeCapabilityRequirement') and the shared
-- 'runCapability' boundary, instead of a bespoke injected
-- 'Prodbox.Lifecycle.ReadinessObservation.waitForComponentReadiness'. The ACTUAL
-- probe I/O is unchanged — the observe lane runs the existing
-- 'observeComponentReadiness' one-shot; only the ROUTING (ref → runCapability →
-- classifyObservation) is new, and it is byte-for-byte behaviour-preserving for
-- every reachable probe reading.
module Prodbox.Lifecycle.CapabilityReadinessBarrier
  ( newReadinessObservationClient
  , observeReadinessThroughCapability

    -- * The evidence fold (exported for the Sprint 1.76 mutation exercise)
  , evidenceFor
  )
where

import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Prodbox.Config.ComponentGraph (ComponentId, ReadinessProbe)
import Prodbox.ControlPlane.CapabilityKind
  ( CapabilityOp
  , KnownCapability
  , requiresRoundTripEvidence
  )
import Prodbox.ControlPlane.CapabilityRef (mkCapabilityRef)
import Prodbox.ControlPlane.CapabilityRequirement
  ( CapabilityRequirement (..)
  , LatencyBudget (..)
  , SomeCapabilityRequirement (..)
  )
import Prodbox.ControlPlane.Coordinate
  ( CapabilityCoordinate
  , coordAuthority
  , coordGeneration
  , coordService
  )
import Prodbox.ControlPlane.Deadline (RemainingDuration (..), deadlineAtOffset)
import Prodbox.ControlPlane.Interpreter
  ( CapabilityClient (..)
  , CapabilityFailure (..)
  , LaneFault (LaneUnavailable)
  , ObservedReading (..)
  , QueueAdmission (Admitted)
  , realMonotonicNow
  , runCapability
  )
import Prodbox.ControlPlane.Observation
  ( CapabilityObservation
  , ExpectedAuthority
  , ExternalEvidence (..)
  , FreshnessWindow (..)
  , ReadinessVerdict (..)
  , classifyObservation
  , expectedAuthorityFromRef
  , roundTripWitnessLandedAt
  )
import Prodbox.ControlPlane.Program (CapabilityProgram (Observe))
import Prodbox.ControlPlane.SCapability (SCapability, withKnownCapability)
import Prodbox.Lifecycle.DependencyAdmission
  ( DependencyAdmission
  , dependencyAdmissionFromVerdict
  )
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeFromMicros)
import Prodbox.Lifecycle.ReadinessObservation
  ( ComponentReadinessTarget
  , ReadinessObservation (..)
  , observeComponentReadiness
  )
import Prodbox.Lifecycle.TargetCommitIntent (CredentialGeneration)
import Prodbox.Retry (PollOutcome (..), RetryPolicy, pollUntilReady)

-- | Seconds. The intra-attempt observedAt→now gap is microseconds; generous, and
-- fails closed on a backward wall-clock step (→ retry, never a false Ready).
readinessFreshnessWindow :: FreshnessWindow
readinessFreshnessWindow = FreshnessWindow 300

-- | A readiness-only boundary client whose observe lane runs the EXISTING one-shot
-- probe ('observeComponentReadiness', byte-for-byte) and lifts its three-valued
-- reading into flat 'ExternalEvidence'. The generation is taken from the handle's
-- coordinate (a real value; never read on the Observe path). Mutation lanes are
-- unreachable for an Observe program and fail closed.
newReadinessObservationClient
  :: CredentialGeneration -> ReadinessProbe -> ComponentReadinessTarget -> CapabilityClient
newReadinessObservationClient generation probe target =
  CapabilityClient
    { clientCurrentGeneration = generation
    , clientMonotonicNow = realMonotonicNow
    , clientAdmit = const (pure Admitted)
    , clientObserve = \op coordinate _freshness _remaining -> do
        observation <- observeComponentReadiness target probe
        clockNow <- authorityWallClockNow
        pure (Right (readingFromObservation op coordinate clockNow observation))
    , clientInternalCas = \_ _ _ -> pure (Left (LaneUnavailable noMutationLane))
    , clientExternalCommit = \_ _ _ -> pure (Left (LaneUnavailable noMutationLane))
    }
 where
  noMutationLane = "readiness-observation client exposes no mutation lane"

-- | The lane SYNTHESIZES service/authority/generation by echoing the coordinate
-- 'runCapability' hands it (= the ref's own coordinate), so every identity guard
-- in 'classifyObservation' passes by construction and only the evidence fold
-- decides. The coordinate digest is stamped by @observationFromRef@ inside
-- 'runCapability' — the lane cannot forge it.
--
-- Sprint 1.76: @observedAt@ is the instant the OBSERVED EVENT happened, not
-- simply a clock read after the probe. For write-shaped evidence that is the
-- instant the interpreter's conditional write landed, carried on the witness;
-- for read-shaped evidence there is no earlier instant to carry, so the
-- post-probe clock read stands. This is what makes the freshness window in
-- 'classifyObservation' bound the age of the proof rather than the age of the
-- question — previously a decade-old round trip and a fresh one produced
-- identical observations.
readingFromObservation
  :: CapabilityOp -> CapabilityCoordinate -> AuthorityTime -> ReadinessObservation -> ObservedReading
readingFromObservation op coordinate clockNow observation =
  ObservedReading
    { observedService = coordService coordinate
    , observedAuthority = coordAuthority coordinate
    , observedGeneration = coordGeneration coordinate
    , observedAt = evidenceInstant clockNow observation
    , observedEvidence = evidenceFor op observation
    }

-- | The instant the observation is about.
evidenceInstant :: AuthorityTime -> ReadinessObservation -> AuthorityTime
evidenceInstant clockNow observation = case observation of
  RoundTripObserved witness -> roundTripWitnessLandedAt witness
  ReadyObserved -> clockNow
  NotReadyYet _ -> clockNow
  Unreachable _ -> clockNow

-- | The GET-vs-write axis. A round-trip op's Ready must be write-shaped; an
-- availability op's Ready is read-shaped. Only 'ComponentRegistry'
-- (OpRegistryPublication) and 'ComponentGatewayDaemonFull' (OpLifecycleCas) are
-- round-trip ops (requiresRoundTripEvidence = isMutating).
--
-- Sprint 1.76: the write-shaped arm CONSUMES the witness the deep probe carried
-- and nothing here can manufacture one. A read-shaped observation of a
-- round-trip op is therefore Pending — the state the superseded code reached by
-- minting a placeholder witness from a string literal, which made a
-- constant-time GET of a monotone latch satisfy a conditional-write
-- requirement.
evidenceFor :: CapabilityOp -> ReadinessObservation -> ExternalEvidence
evidenceFor op observation = case observation of
  RoundTripObserved witness -> EvidenceRoundTripConfirmed witness
  ReadyObserved
    | requiresRoundTripEvidence op ->
        EvidencePending
          "a read-shaped readiness probe cannot prove a write/CAS round trip"
    | otherwise -> EvidencePresentReady
  NotReadyYet detail -> EvidencePending detail
  Unreachable reason -> EvidenceUnreachable reason

authorityWallClockNow :: IO AuthorityTime
authorityWallClockNow = do
  posix <- getPOSIXTime
  let micros = max 0 (floor (toRational posix * 1000000)) :: Integer
  pure (authorityTimeFromMicros (fromInteger micros))

-- | Drive one component's readiness barrier through its single capability handle,
-- retrying inside the SAME bounded 'RetryPolicy' the legacy seam used.
-- Sprint 4.56: the barrier RETURNS the admission it minted instead of throwing
-- it away. The ready verdict is the only arm that carries a ticket, and
-- 'dependencyAdmissionFromVerdict' is the only way to turn one into an
-- admission, so an admission cannot exist without a passed observation.
observeReadinessThroughCapability
  :: RetryPolicy
  -> CapabilityClient
  -> ComponentId
  -> SomeCapabilityRequirement
  -> IO (Either Text DependencyAdmission)
observeReadinessThroughCapability policy client component (SomeCapabilityRequirement (singleton :: SCapability k) requirement) =
  withKnownCapability singleton $
    let ref = mkCapabilityRef @k (requiredCoordinate requirement)
        expected = expectedAuthorityFromRef ref
        budget = case requiredLatencyBudget requirement of LatencyBudget micros -> RemainingDuration micros
        oneAttempt = do
          start <- clientMonotonicNow client
          let deadline = deadlineAtOffset start budget
          outcome <- runCapability client ref deadline (Observe readinessFreshnessWindow)
          now <- authorityWallClockNow
          pure (foldOutcome component expected now outcome)
     in pollUntilReady policy oneAttempt

-- | Ready opens; Pending/Unobservable retry (fail-closed); Failed = structural.
-- On the Observe path only the first three 'CapabilityFailure's can occur, and our
-- lane never even returns Left — the rest are mapped for totality.
foldOutcome
  :: (KnownCapability k)
  => ComponentId
  -> ExpectedAuthority k
  -> AuthorityTime
  -> Either CapabilityFailure (CapabilityObservation k)
  -> PollOutcome DependencyAdmission
foldOutcome _ _ _ (Left failure) = case failure of
  FailureDeadlineExpired -> PollPending "readiness observation deadline expired"
  FailureSaturated _ -> PollPending "readiness observation admission saturated"
  FailureUnobservable detail -> PollPending ("unreachable: " <> detail)
  FailureUnavailable detail -> PollFailed detail
  FailureAmbiguous detail -> PollFailed detail
  FailureRefused detail -> PollFailed detail
foldOutcome component expected now (Right observation) =
  let verdict = classifyObservation now expected observation
   in case verdict of
        VerdictReady _ ->
          case dependencyAdmissionFromVerdict component verdict of
            Just admission -> PollReady admission
            -- Unreachable: 'dependencyAdmissionFromVerdict' yields Nothing only
            -- for the three non-ready arms, and this is the ready one. Refusing
            -- rather than defaulting keeps the fold total without inventing an
            -- admission nothing produced.
            Nothing -> PollFailed "a ready verdict did not yield an admission"
        VerdictPending detail -> PollPending detail
        VerdictUnobservable detail -> PollPending ("unreachable: " <> detail)
        VerdictFailed detail -> PollFailed detail
