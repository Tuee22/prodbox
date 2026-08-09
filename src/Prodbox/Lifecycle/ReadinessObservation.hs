{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Three-valued component-readiness observation and bounded polling.
--
-- Readiness is externally authoritative state: failing to observe a component
-- is not evidence that it is ready. 'Unreachable' therefore keeps the gate
-- closed, just like a positive "not ready yet" observation. The boundary
-- adapters in 'ComponentReadinessTarget' are injected by the owning lifecycle
-- consumer, which lets those consumers reuse their existing kubectl, Vault,
-- registry, and gateway primitives without introducing a dependency from this
-- low-level module back into @Prodbox.CLI.Rke2@.
module Prodbox.Lifecycle.ReadinessObservation
  ( BackendRoundTripResult (..)
  , ComponentReadinessTarget (..)
  , ReadinessObservation (..)
  , ReadinessProbeResult (..)
  , componentReadinessRetryPolicy
  , observationPollOutcome
  , observeComponentReadiness
  , readinessGateOpen
  , waitForComponentReadiness
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Config.ComponentGraph
  ( ComponentId
  , ReadinessProbe (..)
  , componentIdText
  )
import Prodbox.ControlPlane.Observation (RoundTripWitness)
import Prodbox.Retry
  ( PollOutcome (..)
  , RetryPolicy
  , componentReadinessRetryPolicy
  , pollUntilReady
  )

-- | The result of observing one declared readiness probe.
--
-- 'NotReadyYet' means the target was observed successfully but has not
-- converged. 'Unreachable' means the target could not be authoritatively
-- observed; it is deliberately not collapsed into either of the other states.
--
-- Sprint 1.76: 'ReadyObserved' and 'RoundTripObserved' are both gate-opening,
-- but they are not interchangeable evidence. 'ReadyObserved' is READ-shaped: an
-- interface answered that it is converged. 'RoundTripObserved' is WRITE-shaped
-- and carries the witness the interpreter minted when its conditional write
-- landed. Keeping them apart is what stops a constant-time GET from satisfying a
-- dependency whose declared evidence class is a conditional write plus
-- authoritative read-back
-- ([bootstrap_readiness_doctrine.md § 2.3](../../../documents/engineering/bootstrap_readiness_doctrine.md)).
data ReadinessObservation
  = ReadyObserved
  | RoundTripObserved !RoundTripWitness
  | NotReadyYet !Text
  | Unreachable !Text
  deriving (Eq, Show)

-- | An authoritative response from a reachable probe interface. Pending keeps
-- the primitive's detail instead of collapsing distinct states (for example,
-- Vault sealed vs. uninitialized or an operator reporting Available=False) to
-- an uninformative boolean.
data ReadinessProbeResult
  = ReadinessProbeReady
  | ReadinessProbePending !Text
  deriving (Eq, Show)

-- | Sprint 1.76: the authoritative response of a DEEP probe — one whose
-- declared evidence class is a backend round trip. Its ready arm is a distinct
-- type from 'ReadinessProbeResult' and carries a 'RoundTripWitness', so a
-- shallow probe action cannot be placed in the deep slot of
-- 'ComponentReadinessTarget': the two actions have different types, and the
-- mistake is a compile error rather than a runtime classification the fold has
-- to catch. Nothing outside the object-store write interpreters and the gateway
-- state decoder can produce the witness, so the deep slot cannot be filled by
-- fabricating one either.
data BackendRoundTripResult
  = BackendRoundTripConfirmed !RoundTripWitness
  | BackendRoundTripPending !Text
  deriving (Eq, Show)

-- | A probe-specific adapter around one existing readiness primitive. Each
-- action closes over the coordinates owned by its consumer (repository root,
-- namespace, resource reference, endpoint, and credentials); this module
-- introduces no parallel string constants. The adapter returns
-- 'ReadinessProbeReady' only when its exact interface is ready,
-- 'ReadinessProbePending' with authoritative detail while converging, and a
-- @Left reason@ when the interface cannot be observed.
--
-- This is a plain sum rather than a GADT because readiness remains a projection
-- over external state. A target/probe mismatch is represented explicitly as
-- 'Unreachable' and therefore fails closed.
data ComponentReadinessTarget
  = ResourceExistsTarget !ComponentId (IO (Either Text ReadinessProbeResult))
  | FrontDoorHttpTarget !ComponentId (IO (Either Text ReadinessProbeResult))
  | ServiceActiveTarget !ComponentId (IO (Either Text ReadinessProbeResult))
  | RolloutCompleteTarget !ComponentId (IO (Either Text ReadinessProbeResult))
  | OperatorAvailableTarget !ComponentId (IO (Either Text ReadinessProbeResult))
  | VaultUnsealedTarget !ComponentId (IO (Either Text ReadinessProbeResult))
  | -- | The DEEP slot. Its action type is 'BackendRoundTripResult', not
    -- 'ReadinessProbeResult', so a shallow probe does not inhabit it.
    BackendRoundTripTarget
      !ComponentId
      !ComponentId
      (IO (Either Text BackendRoundTripResult))

-- | Soundness gate: only an affirmative observation opens readiness. Both
-- affirmative shapes open it; which SHAPE is required for a given operation is
-- decided by the evidence fold, not here.
readinessGateOpen :: ReadinessObservation -> Bool
readinessGateOpen = \case
  ReadyObserved -> True
  RoundTripObserved _ -> True
  NotReadyYet _ -> False
  Unreachable _ -> False

-- | Lower one three-valued observation into the shared readiness poller.
-- Unreachable observations are retryable within the bounded poll budget, but
-- remain pending rather than opening the gate; exhaustion returns their reason
-- as a failure.
observationPollOutcome :: ReadinessObservation -> PollOutcome ()
observationPollOutcome = \case
  ReadyObserved -> PollReady ()
  RoundTripObserved _ -> PollReady ()
  NotReadyYet detail -> PollPending detail
  Unreachable reason -> PollPending ("unreachable: " <> reason)

-- | Execute exactly the primitive named by a declared probe. This pattern
-- match is intentionally exhaustive: adding a new 'ReadinessProbe' constructor
-- without an executor arm fails the warning-clean build.
observeComponentReadiness
  :: ComponentReadinessTarget -> ReadinessProbe -> IO ReadinessObservation
observeComponentReadiness target probe =
  case readinessActionFor target probe of
    Left reason -> pure (Unreachable reason)
    Right action -> action

-- | Resolve a declared probe to the observation-producing action of the target
-- that implements it.
--
-- Sprint 1.76: the resolved action produces a 'ReadinessObservation' rather than
-- a probe result, because the shallow and deep slots no longer share a result
-- type. Each arm lifts its own slot's result, so the shape of the evidence a
-- probe yields is decided here, once, by the constructor that carried the
-- action — never by a caller reinterpreting an untyped reading.
readinessActionFor
  :: ComponentReadinessTarget
  -> ReadinessProbe
  -> Either Text (IO ReadinessObservation)
readinessActionFor target probe =
  case probe of
    ProbeResourceExists ->
      case target of
        ResourceExistsTarget _ action -> Right (shallow action)
        _ -> mismatch
    ProbeFrontDoorHttp ->
      case target of
        FrontDoorHttpTarget _ action -> Right (shallow action)
        _ -> mismatch
    ProbeServiceActive ->
      case target of
        ServiceActiveTarget _ action -> Right (shallow action)
        _ -> mismatch
    ProbeRolloutComplete ->
      case target of
        RolloutCompleteTarget _ action -> Right (shallow action)
        _ -> mismatch
    ProbeOperatorAvailable ->
      case target of
        OperatorAvailableTarget _ action -> Right (shallow action)
        _ -> mismatch
    ProbeVaultUnsealed ->
      case target of
        VaultUnsealedTarget _ action -> Right (shallow action)
        _ -> mismatch
    ProbeBackendRoundTrip expectedBackend ->
      case target of
        BackendRoundTripTarget _ actualBackend action
          | actualBackend == expectedBackend -> Right (deep action)
        _ -> mismatch
 where
  shallow action = observationFromResult <$> action
  deep action = observationFromRoundTrip <$> action

  mismatch =
    Left
      ( Text.pack
          ( "Readiness target for `"
              ++ componentIdText (targetComponent target)
              ++ "` does not implement "
              ++ show probe
              ++ "."
          )
      )

-- | Poll the declared probe until it opens or the supplied retry budget is
-- exhausted. Both pending and unreachable readings retry; neither can become
-- success without a later gate-opening observation.
waitForComponentReadiness
  :: RetryPolicy
  -> ComponentReadinessTarget
  -> ReadinessProbe
  -> IO (Either Text ())
waitForComponentReadiness policy target probe =
  case readinessActionFor target probe of
    Left reason -> pure (Left reason)
    Right action -> pollUntilReady policy (observationPollOutcome <$> action)

observationFromResult :: Either Text ReadinessProbeResult -> ReadinessObservation
observationFromResult = \case
  Left reason -> Unreachable reason
  Right ReadinessProbeReady -> ReadyObserved
  Right (ReadinessProbePending detail) -> NotReadyYet detail

-- | Sprint 1.76: lift a deep probe's reading. A confirmed round trip keeps its
-- witness all the way into the observation, so the evidence fold consumes the
-- interpreter's proof rather than synthesising one of its own.
observationFromRoundTrip :: Either Text BackendRoundTripResult -> ReadinessObservation
observationFromRoundTrip = \case
  Left reason -> Unreachable reason
  Right (BackendRoundTripConfirmed witness) -> RoundTripObserved witness
  Right (BackendRoundTripPending detail) -> NotReadyYet detail

targetComponent :: ComponentReadinessTarget -> ComponentId
targetComponent = \case
  ResourceExistsTarget component _ -> component
  FrontDoorHttpTarget component _ -> component
  ServiceActiveTarget component _ -> component
  RolloutCompleteTarget component _ -> component
  OperatorAvailableTarget component _ -> component
  VaultUnsealedTarget component _ -> component
  BackendRoundTripTarget component _ _ -> component
