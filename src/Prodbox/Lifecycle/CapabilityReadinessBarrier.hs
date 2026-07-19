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
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Prodbox.Config.ComponentGraph (ReadinessProbe)
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
  , RoundTripWitness (..)
  , classifyObservation
  , expectedAuthorityFromRef
  )
import Prodbox.ControlPlane.Program (CapabilityProgram (Observe))
import Prodbox.ControlPlane.SCapability (SCapability, withKnownCapability)
import Prodbox.Lifecycle.CheckpointAuthority (mkModelBObjectVersion)
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
        observedAt <- authorityWallClockNow
        pure (Right (readingFromObservation op coordinate observedAt observation))
    , clientInternalCas = \_ _ _ -> pure (Left (LaneUnavailable noMutationLane))
    , clientExternalCommit = \_ _ _ -> pure (Left (LaneUnavailable noMutationLane))
    }
 where
  noMutationLane = "readiness-observation client exposes no mutation lane"

-- | The lane SYNTHESIZES service/authority/generation by echoing the coordinate
-- 'runCapability' hands it (= the ref's own coordinate), so every identity guard
-- in 'classifyObservation' passes by construction and only the evidence fold
-- decides. @observedAt@ is a fresh wall-clock read after the probe. The coordinate
-- digest is stamped by @observationFromRef@ inside 'runCapability' — the lane
-- cannot forge it.
readingFromObservation
  :: CapabilityOp -> CapabilityCoordinate -> AuthorityTime -> ReadinessObservation -> ObservedReading
readingFromObservation op coordinate observedAt observation =
  ObservedReading
    { observedService = coordService coordinate
    , observedAuthority = coordAuthority coordinate
    , observedGeneration = coordGeneration coordinate
    , observedAt = observedAt
    , observedEvidence = evidenceFor op observation
    }

-- | The GET-vs-write axis. A round-trip op's Ready must be write-shaped
-- (EvidenceRoundTripConfirmed → Ready for any op); an availability op's Ready is
-- read-shaped (EvidencePresentReady → Ready only for non-round-trip ops). Only
-- 'ComponentRegistry' (OpRegistryPublication) and 'ComponentGatewayDaemonFull'
-- (OpLifecycleCas) are round-trip ops (requiresRoundTripEvidence = isMutating).
evidenceFor :: CapabilityOp -> ReadinessObservation -> ExternalEvidence
evidenceFor op observation = case observation of
  ReadyObserved
    | requiresRoundTripEvidence op -> roundTripEvidence
    | otherwise -> EvidencePresentReady
  NotReadyYet detail -> EvidencePending detail
  Unreachable reason -> EvidenceUnreachable reason

-- | The round-trip probes DO a real store round trip; the legacy probe just does
-- not surface the produced object version, so the witness is a fixed valid
-- placeholder. 'classifyObservation' never inspects it (a proven round trip is
-- Ready for any op; the ticket is built from digest/generation/observedAt). Total:
-- the literal is valid, the Left arm is dead and fails closed.
roundTripEvidence :: ExternalEvidence
roundTripEvidence =
  case mkModelBObjectVersion "readiness-observation-round-trip" of
    Right version -> EvidenceRoundTripConfirmed (RoundTripWitness version)
    Left err -> EvidenceUnreachable (Text.pack ("cannot synthesize round-trip witness: " ++ show err))

authorityWallClockNow :: IO AuthorityTime
authorityWallClockNow = do
  posix <- getPOSIXTime
  let micros = max 0 (floor (toRational posix * 1000000)) :: Integer
  pure (authorityTimeFromMicros (fromInteger micros))

-- | Drive one component's readiness barrier through its single capability handle,
-- retrying inside the SAME bounded 'RetryPolicy' the legacy seam used.
observeReadinessThroughCapability
  :: RetryPolicy -> CapabilityClient -> SomeCapabilityRequirement -> IO (Either Text ())
observeReadinessThroughCapability policy client (SomeCapabilityRequirement (singleton :: SCapability k) requirement) =
  withKnownCapability singleton $
    let ref = mkCapabilityRef @k (requiredCoordinate requirement)
        expected = expectedAuthorityFromRef ref
        budget = case requiredLatencyBudget requirement of LatencyBudget micros -> RemainingDuration micros
        oneAttempt = do
          start <- clientMonotonicNow client
          let deadline = deadlineAtOffset start budget
          outcome <- runCapability client ref deadline (Observe readinessFreshnessWindow)
          now <- authorityWallClockNow
          pure (foldOutcome expected now outcome)
     in pollUntilReady policy oneAttempt

-- | Ready opens; Pending/Unobservable retry (fail-closed); Failed = structural.
-- On the Observe path only the first three 'CapabilityFailure's can occur, and our
-- lane never even returns Left — the rest are mapped for totality.
foldOutcome
  :: (KnownCapability k)
  => ExpectedAuthority k
  -> AuthorityTime
  -> Either CapabilityFailure (CapabilityObservation k)
  -> PollOutcome ()
foldOutcome _ _ (Left failure) = case failure of
  FailureDeadlineExpired -> PollPending "readiness observation deadline expired"
  FailureSaturated _ -> PollPending "readiness observation admission saturated"
  FailureUnobservable detail -> PollPending ("unreachable: " <> detail)
  FailureUnavailable detail -> PollFailed detail
  FailureAmbiguous detail -> PollFailed detail
  FailureRefused detail -> PollFailed detail
foldOutcome expected now (Right observation) =
  case classifyObservation now expected observation of
    VerdictReady _ -> PollReady ()
    VerdictPending detail -> PollPending detail
    VerdictUnobservable detail -> PollPending ("unreachable: " <> detail)
    VerdictFailed detail -> PollFailed detail
