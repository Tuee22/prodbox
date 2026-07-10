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
  ( ComponentReadinessTarget (..)
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
import Prodbox.Retry
  ( PollOutcome (..)
  , RetryPolicy (..)
  , pollUntilReady
  )

-- | Small shared budget for the final graph barrier. Install actions may own
-- deeper convergence waits; this absorbs observation jitter without ever
-- treating an unreachable target as ready.
componentReadinessRetryPolicy :: RetryPolicy
componentReadinessRetryPolicy =
  RetryPolicy
    { retryPolicyMaxAttempts = 3
    , retryPolicyBaseDelayMicros = 1000000
    , retryPolicyMultiplier = 1
    , retryPolicyMaxDelayMicros = 1000000
    }

-- | The result of observing one declared readiness probe.
--
-- 'ReadyObserved' is the only gate-opening state. 'NotReadyYet' means the
-- target was observed successfully but has not converged. 'Unreachable' means
-- the target could not be authoritatively observed; it is deliberately not
-- collapsed into either of the other states.
data ReadinessObservation
  = ReadyObserved
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
  | BackendRoundTripTarget
      !ComponentId
      !ComponentId
      (IO (Either Text ReadinessProbeResult))

-- | Soundness gate: only an affirmative observation opens readiness.
readinessGateOpen :: ReadinessObservation -> Bool
readinessGateOpen = \case
  ReadyObserved -> True
  NotReadyYet _ -> False
  Unreachable _ -> False

-- | Lower one three-valued observation into the shared readiness poller.
-- Unreachable observations are retryable within the bounded poll budget, but
-- remain pending rather than opening the gate; exhaustion returns their reason
-- as a failure.
observationPollOutcome :: ReadinessObservation -> PollOutcome ()
observationPollOutcome = \case
  ReadyObserved -> PollReady ()
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
    Right action -> observationFromResult <$> action

readinessActionFor
  :: ComponentReadinessTarget
  -> ReadinessProbe
  -> Either Text (IO (Either Text ReadinessProbeResult))
readinessActionFor target probe =
  case probe of
    ProbeResourceExists ->
      case target of
        ResourceExistsTarget _ action -> Right action
        _ -> mismatch
    ProbeFrontDoorHttp ->
      case target of
        FrontDoorHttpTarget _ action -> Right action
        _ -> mismatch
    ProbeServiceActive ->
      case target of
        ServiceActiveTarget _ action -> Right action
        _ -> mismatch
    ProbeRolloutComplete ->
      case target of
        RolloutCompleteTarget _ action -> Right action
        _ -> mismatch
    ProbeOperatorAvailable ->
      case target of
        OperatorAvailableTarget _ action -> Right action
        _ -> mismatch
    ProbeVaultUnsealed ->
      case target of
        VaultUnsealedTarget _ action -> Right action
        _ -> mismatch
    ProbeBackendRoundTrip expectedBackend ->
      case target of
        BackendRoundTripTarget _ actualBackend action
          | actualBackend == expectedBackend -> Right action
        _ -> mismatch
 where
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
-- success without a later 'ReadyObserved'.
waitForComponentReadiness
  :: RetryPolicy
  -> ComponentReadinessTarget
  -> ReadinessProbe
  -> IO (Either Text ())
waitForComponentReadiness policy target probe =
  case readinessActionFor target probe of
    Left reason -> pure (Left reason)
    Right action ->
      pollUntilReady policy (observationPollOutcome . observationFromResult <$> action)

observationFromResult :: Either Text ReadinessProbeResult -> ReadinessObservation
observationFromResult = \case
  Left reason -> Unreachable reason
  Right ReadinessProbeReady -> ReadyObserved
  Right (ReadinessProbePending detail) -> NotReadyYet detail

targetComponent :: ComponentReadinessTarget -> ComponentId
targetComponent = \case
  ResourceExistsTarget component _ -> component
  FrontDoorHttpTarget component _ -> component
  ServiceActiveTarget component _ -> component
  RolloutCompleteTarget component _ -> component
  OperatorAvailableTarget component _ -> component
  VaultUnsealedTarget component _ -> component
  BackendRoundTripTarget component _ _ -> component
