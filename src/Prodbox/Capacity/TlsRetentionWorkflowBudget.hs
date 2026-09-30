-- | Finite host-response budget for the closed TLS retention workflow.
module Prodbox.Capacity.TlsRetentionWorkflowBudget
  ( tlsRetentionWorkflowMaximumTargetOneShotCalls
  , tlsRetentionWorkflowMaximumShortCalls
  , tlsRetentionWorkflowShortCallTimeoutMicros
  , tlsRetentionWorkflowResponseOverheadMicros
  , tlsRetentionWorkflowResponseTimeoutMicros
  )
where

import Numeric.Natural (Natural)
import Prodbox.Capacity.TargetWorkerBudget qualified as TargetWorkerBudget

-- | The fixed legacy-recovery terminal race is the longest program. It proves
-- version 3 unopenable (selected prepare plus home rewrap), creates version 4
-- (home prepare, selected retain, and home wrap), adopts a racing openable
-- version-4 occupant (selected prepare, home rewrap, and selected restore),
-- then verifies the promoted source. The replacement branch stops both apply
-- attempts before selected restore and is therefore one Target call shorter.
tlsRetentionWorkflowMaximumTargetOneShotCalls :: Natural
tlsRetentionWorkflowMaximumTargetOneShotCalls = 9

-- | The same terminal race performs the initial Authority observation; the
-- version-3 store and collision observation; the terminal-version observation,
-- stage, store, and collision observation; the same-version rebase stage and
-- store; the exact Adapter restore; and Authority promotion. The terminal
-- replacement race has the same count, substituting replacement stage/write
-- for rebase stage/write.
tlsRetentionWorkflowMaximumShortCalls :: Natural
tlsRetentionWorkflowMaximumShortCalls = 11

-- | Those non-Target calls retain the shared ten-second control-plane bound.
tlsRetentionWorkflowShortCallTimeoutMicros :: Natural
tlsRetentionWorkflowShortCallTimeoutMicros = 10 * 1000000

-- | Bounded time for host admission, authenticated framing, response
-- encoding, and the final socket write.
tlsRetentionWorkflowResponseOverheadMicros :: Natural
tlsRetentionWorkflowResponseOverheadMicros = 30 * 1000000

-- | TLS-workflow-only host timeout. This fits the supported 64-bit runtime.
tlsRetentionWorkflowResponseTimeoutMicros :: Int
tlsRetentionWorkflowResponseTimeoutMicros =
  fromIntegral
    ( tlsRetentionWorkflowMaximumTargetOneShotCalls
        * fromIntegral TargetWorkerBudget.targetOneShotResponseTimeoutMicros
        + tlsRetentionWorkflowMaximumShortCalls
          * tlsRetentionWorkflowShortCallTimeoutMicros
        + tlsRetentionWorkflowResponseOverheadMicros
    )
