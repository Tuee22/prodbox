{-# LANGUAGE DerivingStrategies #-}

-- | Sprint 5.23: a deterministic, exhaustively-schedulable model of the Bootstrap
-- Broker forced-drain shutdown, and the run-final residue oracle.
--
-- The full-suite-only shutdown failure this closes is: the pre-fix broker could
-- publish @BrokerStopped@ while a replay-waiter cell (a running idempotency entry)
-- was still live. Sprint 2.36 made @BrokerStopped@ reachable only through the
-- exact-empty postcondition witness (@Prodbox.Bootstrap.Broker.Server.proveShutdownComplete@:
-- @queued == 0 && active == 0 && Map.null entries@). This module reproduces both
-- shutdowns as pure state machines so every interleaving of drain, worker
-- finalization, and replay-waiter resolution is scheduled deterministically —
-- turning a probabilistic full-suite race into a stable repository-owned
-- counterexample.
--
-- Two variants share one step relation and differ only in the shutdown
-- postcondition, exactly as the real fix does:
--
--   * 'FrozenPreFix' proves completion on @queued == 0 && active == 0@ alone, so an
--     interleaving can reach 'Stopped' while a waiter is still 'WaiterRunning' —
--     'stoppedWithLiveWaiter'.
--   * 'ProofCarrying' additionally requires every replay waiter resolved (the
--     @Map.null entries@ term), so no interleaving reaches that state, while a
--     fully-drained 'Stopped' remains reachable.
--
-- The state space is finite and monotone (queued and active only decrease, waiters
-- only move @Running -> Resolved@, the phase only advances), so 'reachableStates'
-- enumerates every interleaving and terminates. The residue oracle ('shutdownResidue')
-- reports any queued connection, unfinalized worker, or live waiter, so a terminal
-- state that leaked is flagged with typed residue rather than passing silently.
module Prodbox.Bootstrap.Broker.ShutdownModel
  ( ShutdownVariant (..)
  , WaiterState (..)
  , ModelPhase (..)
  , ShutdownState (..)
  , ShutdownStep (..)
  , initialShutdownState
  , postconditionHolds
  , enabledSteps
  , stepShutdown
  , reachableStates
  , terminalStates
  , stoppedWithLiveWaiter
  , ShutdownResidue (..)
  , shutdownResidue
  , residueClean
  )
where

import Data.Set (Set)
import Data.Set qualified as Set

-- | Which shutdown postcondition the model proves completion under.
data ShutdownVariant
  = FrozenPreFix
  | ProofCarrying
  deriving stock (Eq, Show)

data WaiterState
  = WaiterRunning
  | WaiterResolved
  deriving stock (Eq, Ord, Show)

data ModelPhase
  = Draining
  | Stopped
  deriving stock (Eq, Ord, Show)

-- | The force-stop state: the drain phase, the queued and active-worker counts, and
-- the replay-waiter cells (the idempotency completion cells).
data ShutdownState = ShutdownState
  { phase :: !ModelPhase
  , queued :: !Word
  , active :: !Word
  , waiters :: ![WaiterState]
  }
  deriving stock (Eq, Ord, Show)

data ShutdownStep
  = DrainQueue
  | FinalizeWorker
  | ResolveWaiter !Int
  | ProveShutdown
  deriving stock (Eq, Ord, Show)

-- | The force-stop starting point: everything present and every replay waiter
-- running.
initialShutdownState :: Word -> Word -> Int -> ShutdownState
initialShutdownState queuedConnections activeWorkers waiterCount =
  ShutdownState
    { phase = Draining
    , queued = queuedConnections
    , active = activeWorkers
    , waiters = replicate (max 0 waiterCount) WaiterRunning
    }

-- | Whether the shutdown-complete postcondition holds. The proof-carrying variant
-- additionally requires every replay waiter resolved (the @Map.null entries@ term).
postconditionHolds :: ShutdownVariant -> ShutdownState -> Bool
postconditionHolds variant state =
  queued state == 0
    && active state == 0
    && case variant of
      FrozenPreFix -> True
      ProofCarrying -> all (== WaiterResolved) (waiters state)

-- | The steps enabled in a state. 'ProveShutdown' is offered only when its
-- postcondition holds, so every step makes progress and there are no self-loops.
enabledSteps :: ShutdownVariant -> ShutdownState -> [ShutdownStep]
enabledSteps variant state
  | phase state == Stopped = []
  | otherwise =
      concat
        [ [DrainQueue | queued state > 0]
        , [FinalizeWorker | active state > 0]
        , [ResolveWaiter index | (index, WaiterRunning) <- zip [0 ..] (waiters state)]
        , [ProveShutdown | postconditionHolds variant state]
        ]

-- | Apply one step. A step not enabled in the state is a no-op (the caller drives
-- transitions through 'enabledSteps').
stepShutdown :: ShutdownVariant -> ShutdownState -> ShutdownStep -> ShutdownState
stepShutdown variant state step = case step of
  DrainQueue -> state {queued = 0}
  FinalizeWorker
    | active state > 0 -> state {active = active state - 1}
    | otherwise -> state
  ResolveWaiter index -> state {waiters = resolveAt index (waiters state)}
  ProveShutdown
    | postconditionHolds variant state -> state {phase = Stopped}
    | otherwise -> state

resolveAt :: Int -> [WaiterState] -> [WaiterState]
resolveAt index cells =
  [ if position == index then WaiterResolved else cell
  | (position, cell) <- zip [0 ..] cells
  ]

-- | Every state reachable from an initial state under every interleaving. The
-- monotone finite state space guarantees termination.
reachableStates :: ShutdownVariant -> ShutdownState -> Set ShutdownState
reachableStates variant start = explore Set.empty [start]
 where
  explore seen [] = seen
  explore seen (current : rest)
    | current `Set.member` seen = explore seen rest
    | otherwise =
        let seen' = Set.insert current seen
            successors = map (stepShutdown variant current) (enabledSteps variant current)
         in explore seen' (successors ++ rest)

-- | The reachable states with no enabled step (fully progressed).
terminalStates :: ShutdownVariant -> ShutdownState -> Set ShutdownState
terminalStates variant start =
  Set.filter (null . enabledSteps variant) (reachableStates variant start)

-- | The counterexample predicate: stopped while a replay waiter is still running.
stoppedWithLiveWaiter :: ShutdownState -> Bool
stoppedWithLiveWaiter state =
  phase state == Stopped && WaiterRunning `elem` waiters state

-- | Residue left in a state: queued connections, unfinalized workers, and live
-- replay waiters.
data ShutdownResidue = ShutdownResidue
  { residueQueued :: !Word
  , residueActiveWorkers :: !Word
  , residueRunningWaiters :: !Int
  }
  deriving stock (Eq, Show)

shutdownResidue :: ShutdownState -> ShutdownResidue
shutdownResidue state =
  ShutdownResidue
    { residueQueued = queued state
    , residueActiveWorkers = active state
    , residueRunningWaiters = length (filter (== WaiterRunning) (waiters state))
    }

-- | No residue at all — the only acceptable terminal for a completed shutdown.
residueClean :: ShutdownResidue -> Bool
residueClean residue =
  residueQueued residue == 0
    && residueActiveWorkers residue == 0
    && residueRunningWaiters residue == 0
