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

-- | The retain arm is the longest program: prepare home, retain selected,
-- wrap home, and verify selected source.
tlsRetentionWorkflowMaximumTargetOneShotCalls :: Natural
tlsRetentionWorkflowMaximumTargetOneShotCalls = 4

-- | The same arm performs at most two Authority and two adapter calls outside
-- the Target one-shot schedule.
tlsRetentionWorkflowMaximumShortCalls :: Natural
tlsRetentionWorkflowMaximumShortCalls = 4

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
