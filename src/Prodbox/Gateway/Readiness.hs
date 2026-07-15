{-# LANGUAGE DerivingStrategies #-}

-- | Sprint 2.34: the gateway daemon's kubelet readiness as ONE pure latched
-- projection. This closes the @F-READY@ mechanism of counterexample
-- @LCPC-2026-07-11@: readiness is no longer written unconditionally at
-- serve-start, but computed from three monotone boundary-owned facts —
-- exactly the cached state
-- [bootstrap_readiness_doctrine §0.7](../../../documents/engineering/bootstrap_readiness_doctrine.md)
-- permits @/readyz@ to project ("startup complete, not draining, required
-- managed sessions available") — with zero backend I/O in the projection
-- itself.
--
-- Each input is monotone (set once, never cleared within a boot), so no
-- flapping backend signal can be folded into readiness: a slow or
-- intermittently failing object store after the first proven round trip never
-- yanks the Pod out of its Service endpoints. The observable @/readyz@
-- sequence is therefore exactly @Starting* -> Ready* -> Draining*@, with the
-- only downward edge being the intended shutdown transition.
module Prodbox.Gateway.Readiness
  ( DrainPhase (..)
  , ObjectStoreProof (..)
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

-- | The object-store round-trip proof latch. Monotone:
-- @ObjectStoreUnproven -> ObjectStoreProven@, never back. Set once, when the
-- continuity worker installs the first validated @StartupRecovery@ since boot
-- — a real authoritative GET + read-back on the previously-admitted path, or a
-- CAS write on the first-admission path. It is NEVER a bare absent-object GET
-- (an absent object yields @Left ContinuityAuthorityMissing@ and never
-- latches), so it is materially stronger than the evidence
-- [bootstrap_readiness_doctrine §2.3](../../../documents/engineering/bootstrap_readiness_doctrine.md)
-- forbids.
data ObjectStoreProof
  = ObjectStoreUnproven
  | ObjectStoreProven
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

-- | The boundary-owned cached facts 'computeReadiness' folds. Every field is
-- monotone, so no flapping backend signal can be threaded in.
data ReadinessInputs = ReadinessInputs
  { readinessDrainPhase :: DrainPhase
  , readinessObjectStoreProof :: ObjectStoreProof
  , readinessWorkersStatus :: WorkersStatus
  }
  deriving stock (Eq, Show)

-- | The one readiness projection. Drain dominates (terminal, absorbing).
-- 'Ready' requires BOTH the object-store proof latch AND started workers.
-- Everything else is 'Starting'. Total, pure, no I/O.
computeReadiness :: ReadinessInputs -> ReadinessState
computeReadiness inputs
  | readinessDrainPhase inputs == PhaseDraining = Draining
  | readinessObjectStoreProof inputs == ObjectStoreProven
      && readinessWorkersStatus inputs == WorkersStarted =
      Ready
  | otherwise = Starting
