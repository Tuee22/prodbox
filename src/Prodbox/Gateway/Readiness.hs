{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

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
  , WorkerState (..)
  , WorkerRoster (..)
  , pendingWorkerRoster
  , recordWorkerState
  , workerRosterLive
  , workerRosterStalled
  , ReadinessState (..)
  , ReadinessInputs (..)
  , computeReadiness
  )
where

import Data.Text (Text)
import Numeric.Natural (Natural)

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

-- | Sprint 2.41: the daemon's long-lived workers, each with its own state.
--
-- This replaces a monotone @WorkersStatus@ flag that was written once at
-- 'daemonWorkers' entry — before any worker existed — and never written again.
-- A worker that died therefore never un-readied the Pod: the flag said
-- @WorkersStarted@ because it had been set, not because anything was running.
-- That is the *Staleness* class of
-- [chaos_hardening_doctrine.md § 21](../../../documents/engineering/chaos_hardening_doctrine.md).
--
-- The roster is keyed by a closed 'Bounded'/'Enum' worker identity, so adding a
-- worker without giving it a roster entry does not type-check, and readiness
-- folds the roster rather than a flag.
data WorkerState
  = -- | Never started.
    WorkerPending
  | -- | Running; the value is the monotonic instant of its last heartbeat.
    WorkerRunning !Natural
  | -- | Exited, with the reason. Absorbing until the supervisor restarts it,
    -- and un-readies the Pod while it holds.
    WorkerExited !Text
  deriving stock (Eq, Show)

-- | The complete roster, one state per worker identity.
newtype WorkerRoster = WorkerRoster {workerRosterStates :: [(Text, WorkerState)]}
  deriving stock (Eq, Show)

-- | The roster before any worker starts: every worker pending.
pendingWorkerRoster :: [Text] -> WorkerRoster
pendingWorkerRoster names = WorkerRoster [(name, WorkerPending) | name <- names]

-- | Record a worker's state, leaving every other entry alone.
recordWorkerState :: Text -> WorkerState -> WorkerRoster -> WorkerRoster
recordWorkerState name state (WorkerRoster entries) =
  WorkerRoster
    [(entryName, if entryName == name then state else entryState) | (entryName, entryState) <- entries]

-- | Whether every worker is running and has beaten within the bound.
--
-- A pending worker, an exited worker, and a worker whose heartbeat is older than
-- the bound all hold readiness closed — the last because a wedged worker is not
-- a running one, which the monotone flag could not express at all.
workerRosterLive :: Natural -> Natural -> WorkerRoster -> Bool
workerRosterLive nowMicros heartbeatBoundMicros (WorkerRoster entries) =
  not (null entries) && all live entries
 where
  live (_, state) = case state of
    WorkerPending -> False
    WorkerExited _ -> False
    WorkerRunning beatAtMicros ->
      beatAtMicros <= nowMicros && nowMicros - beatAtMicros <= heartbeatBoundMicros

-- | The workers that are not currently live, with the reason, for the operator
-- diagnostic the readiness body carries.
workerRosterStalled :: Natural -> Natural -> WorkerRoster -> [(Text, WorkerState)]
workerRosterStalled nowMicros heartbeatBoundMicros (WorkerRoster entries) =
  [ entry
  | entry@(_, state) <- entries
  , not (liveState state)
  ]
 where
  liveState state = case state of
    WorkerPending -> False
    WorkerExited _ -> False
    WorkerRunning beatAtMicros ->
      beatAtMicros <= nowMicros && nowMicros - beatAtMicros <= heartbeatBoundMicros

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
  , readinessWorkerRoster :: WorkerRoster
  , readinessNowMicros :: Natural
  , readinessWorkerHeartbeatBoundMicros :: Natural
  }
  deriving stock (Eq, Show)

-- | The one readiness projection. Drain dominates (terminal, absorbing).
-- 'Ready' requires BOTH current durable emitter authority AND a live worker
-- roster. Everything else is 'Starting'. Total, pure, no I/O.
--
-- Sprint 2.41: the second conjunct is a roster fold rather than a monotone flag,
-- so a worker that exits or stops beating removes the Pod from ready endpoints
-- instead of being invisible to readiness.
computeReadiness :: ReadinessInputs -> ReadinessState
computeReadiness inputs
  | readinessDrainPhase inputs == PhaseDraining = Draining
  | readinessEmitterAuthority inputs == EmitterAuthorityReady
      && workerRosterLive
        (readinessNowMicros inputs)
        (readinessWorkerHeartbeatBoundMicros inputs)
        (readinessWorkerRoster inputs) =
      Ready
  | otherwise = Starting
