{-# LANGUAGE DerivingStrategies #-}

-- | The gateway daemon's kubelet readiness as one pure cached projection.
-- Readiness is never written unconditionally at serve-start. It is computed
-- from the drain phase, the current durable emitter-authority witness, and the
-- worker-started fact — exactly the cached state
-- [bootstrap_readiness_doctrine §0.7](../../../documents/engineering/bootstrap_readiness_doctrine.md)
-- permits @/readyz@ to project ("startup complete, not draining, required
-- managed sessions available") — with zero backend I/O in the projection
-- itself.
--
-- The drain and worker facts are monotone. Emitter authority deliberately is
-- not: loss of the Kubernetes Lease witness must remove the Pod from ready
-- endpoints before another publication can cross the actor boundary. The
-- HTTP projection itself remains constant-time and performs no backend I/O.
module Prodbox.Gateway.Readiness
  ( DrainPhase (..)
  , EmitterAuthorityStatus (..)
  , WorkersStatus (..)
  , ReadinessState (..)
  , ReadinessInputs (..)
  , computeReadiness
  )
where

-- | Drain phase. Monotone: @PhaseServing -> PhaseDraining@, never back. Set to
-- 'PhaseDraining' by the SIGTERM/SIGINT handler and the drain coordinator.
data DrainPhase
  = PhaseServing
  | PhaseDraining
  deriving stock (Eq, Show)

-- | Whether the local emitter currently owns every durable publication fence:
-- an identity-bound encrypted journal under its long-held filesystem lock and
-- a matching Kubernetes Lease mutation that has been authoritatively read
-- back. Renewal failure clears this fact immediately; successful reacquisition
-- may restore it.
data EmitterAuthorityStatus
  = EmitterAuthorityUnavailable
  | EmitterAuthorityReady
  deriving stock (Eq, Show)

-- | Whether the daemon's server workers have started. Monotone:
-- @WorkersPending -> WorkersStarted@, never back. Set once at 'daemonWorkers'
-- entry, before the REST listener that serves @/readyz@ is spawned, so
-- observable readiness structurally implies the workers are up.
data WorkersStatus
  = WorkersPending
  | WorkersStarted
  deriving stock (Eq, Show)

-- | The three-state kubelet readiness projection. The HTTP body strings the
-- daemon serves for each state are pinned by the golden daemon-lifecycle
-- suite: @Ready@ -> 200 @"ready"@, @Draining@ / @Starting@ -> 503.
data ReadinessState
  = Starting
  | Ready
  | Draining
  deriving stock (Eq, Show)

-- | The boundary-owned cached facts 'computeReadiness' folds. Drain and worker
-- startup are monotone; emitter authority is an explicit fail-closed witness
-- that may be cleared on Lease loss and restored only after reacquisition.
data ReadinessInputs = ReadinessInputs
  { readinessDrainPhase :: DrainPhase
  , readinessEmitterAuthority :: EmitterAuthorityStatus
  , readinessWorkersStatus :: WorkersStatus
  }
  deriving stock (Eq, Show)

-- | The one readiness projection. Drain dominates (terminal, absorbing).
-- 'Ready' requires BOTH current durable emitter authority AND started workers.
-- Everything else is 'Starting'. Total, pure, no I/O.
computeReadiness :: ReadinessInputs -> ReadinessState
computeReadiness inputs
  | readinessDrainPhase inputs == PhaseDraining = Draining
  | readinessEmitterAuthority inputs == EmitterAuthorityReady
      && readinessWorkersStatus inputs == WorkersStarted =
      Ready
  | otherwise = Starting
