{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Sprint 4.50: the decommission run orchestration.
--
-- Once a run is authorized ('Prodbox.Lifecycle.Decommission.Permit') and its plan
-- committed ('Prodbox.Lifecycle.Decommission.Commit'), the runner walks the destroy
-- subgraph ('Prodbox.Lifecycle.Decommission.Graph') in topological order and, for
-- each node it attempts, journals an intent frame before the external effect and a
-- result frame after — the durable evidence a crashed run reopens and resumes.
--
-- Resumption is derived from that evidence: 'completedNodes' reads the recovered
-- receipt entries and returns the nodes that were durably destroyed, and
-- 'runDecommission' skips them without re-running their effect or re-journaling —
-- so a node whose one-time external destroy already succeeded is never attempted
-- twice, while a node that only recorded an intent or a failure is re-attempted.
-- The orchestration is monad-generic over the injected journal and destroy effects,
-- so an in-memory fixture drives every branch and resume path without a live
-- cluster.
module Prodbox.Lifecycle.Decommission.Runner
  ( NodeResultStatus (..)
  , DecommissionEntry (..)
  , runDecommission
  , completedNodes
  )
where

import Codec.Serialise (Serialise)
import Control.Monad (foldM)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Decommission.Graph
  ( DecommissionReport (DecommissionReport)
  , NodeExecution (NodeExecution)
  , NodeVerdict (NodeBlocked, NodeFailed, NodeSucceeded)
  , decommissionRequiredPredecessors
  , decommissionTopologicalOrder
  )
import Prodbox.Lifecycle.Decommission.Manifest (DecommissionNode)

-- | The outcome a result frame records for a node.
data NodeResultStatus
  = NodeDestroyed
  | NodeDestroyFailed !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | A receipt entry. The runner journals an intent before attempting a node and a
-- result after — the payload carried by each decommission receipt frame.
data DecommissionEntry
  = DecommissionIntent !DecommissionNode
  | DecommissionNodeResult !DecommissionNode !NodeResultStatus
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Drive one decommission run (or resume). @completed@ is the set of nodes already
-- durably destroyed by a prior attempt (from 'completedNodes'); they are treated as
-- succeeded without re-running or re-journaling. Every other ready node journals an
-- intent, runs the injected destroy/read-back effect, and journals its result; a
-- node whose predecessors did not all succeed is 'NodeBlocked' and neither run nor
-- journaled.
runDecommission
  :: (Monad m)
  => [DecommissionNode]
  -> [DecommissionNode]
  -> (DecommissionEntry -> m ())
  -> (DecommissionNode -> m (Either Text ()))
  -> m DecommissionReport
runDecommission allNodes completed record runNode = do
  (_, executions) <- foldM step (Map.empty, []) (decommissionTopologicalOrder allNodes)
  pure (DecommissionReport (reverse executions))
 where
  step (verdicts, executions) node = do
    verdict <- decideNode verdicts node
    pure (Map.insert node verdict verdicts, NodeExecution node verdict : executions)
  decideNode verdicts node
    | node `elem` completed = pure NodeSucceeded
    | not (null (unmetPredecessors verdicts node)) =
        pure (NodeBlocked (unmetPredecessors verdicts node))
    | otherwise = attemptNode node
  attemptNode node = do
    record (DecommissionIntent node)
    outcome <- runNode node
    case outcome of
      Right () -> do
        record (DecommissionNodeResult node NodeDestroyed)
        pure NodeSucceeded
      Left detail -> do
        record (DecommissionNodeResult node (NodeDestroyFailed detail))
        pure (NodeFailed detail)
  unmetPredecessors verdicts node =
    filter (not . succeededIn verdicts) (decommissionRequiredPredecessors allNodes node)
  succeededIn :: Map DecommissionNode NodeVerdict -> DecommissionNode -> Bool
  succeededIn verdicts node = Map.lookup node verdicts == Just NodeSucceeded

-- | The nodes a prior run durably destroyed, read from recovered receipt entries.
-- A node that only recorded an intent, or recorded a failure, is not completed and
-- is re-attempted on resume.
completedNodes :: [DecommissionEntry] -> [DecommissionNode]
completedNodes entries =
  [node | DecommissionNodeResult node NodeDestroyed <- entries]
