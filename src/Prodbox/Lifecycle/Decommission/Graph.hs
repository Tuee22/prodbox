{-# LANGUAGE DerivingStrategies #-}

-- | Sprint 4.50: the typed destroy-ordering subgraph over a decommission
-- manifest's node inventory.
--
-- The teardown order is derived data, not hand-sequenced I/O. Predecessor edges
-- encode the spec's mandatory ordering: the SES branch proves consumers quiescent
-- before destroying the provider stack and external SMTP IAM. Those destroys
-- precede each live Target Agent tombstone, and every target tombstone precedes
-- the distinct retained-custody tombstone. Only after that live-Agent work are
-- TLS objects and their identity deleted, before the Authority backup objects
-- and identity; the all-prefix
-- absence proof follows those deletes; and the shared object bucket is the unique
-- terminal, destroyed only after every other node (its opaque Pulumi/authority
-- objects would otherwise be stranded).
--
-- 'runDecommissionGraph' is a total executor: it runs every node whose predecessors
-- all succeeded, records 'NodeBlocked' with the offending predecessors otherwise,
-- aggregates every outcome, and never stops early — so an independent branch's
-- failure never silently discards work on another branch, while any failure blocks
-- the shared bucket. It is pure over an injected node effect, so an in-memory
-- fixture drives every branch without touching a live cluster, and the ordering
-- invariants are checkable before any destroy effect is wired.
module Prodbox.Lifecycle.Decommission.Graph
  ( NodeVerdict (..)
  , NodeExecution (..)
  , DecommissionReport (..)
  , decommissionRequiredPredecessors
  , decommissionTopologicalOrder
  , runDecommissionGraph
  , reportConverged
  , reportBlocked
  , reportFailed
  , tlsPrecedesSharedBucket
  , sesDestroyPrecedesTombstones
  , targetTombstonesPrecedeCustody
  , custodyPrecedesTls
  , tlsPrecedesBackup
  , allPrefixesProvenBeforeSharedBucket
  , sharedBucketIsTerminal
  )
where

import Control.Monad (foldM)
import Data.List (delete, elemIndex)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionNode
      ( BackupObjects
      , BackupPrefixAbsenceProof
      , RetainedCustody
      , SesConsumerQuiescence
      , SesProviderStack
      , SesSmtpIam
      , SharedObjectBucket
      , TargetGeneration
      , TlsRetainedObjects
      , TlsRetentionIdentity
      )
  )

-- | The verdict for one node after a run.
data NodeVerdict
  = NodeSucceeded
  | NodeFailed !Text
  | -- | Not attempted because these predecessors did not all succeed.
    NodeBlocked ![DecommissionNode]
  deriving stock (Eq, Show)

data NodeExecution = NodeExecution
  { executedNode :: !DecommissionNode
  , executedVerdict :: !NodeVerdict
  }
  deriving stock (Eq, Show)

-- | Every node's execution outcome in topological order.
newtype DecommissionReport = DecommissionReport
  { reportExecutions :: [NodeExecution]
  }
  deriving stock (Eq, Show)

-- | The predecessors of a node that must succeed before it runs, restricted to the
-- nodes actually present in the manifest.
decommissionRequiredPredecessors :: [DecommissionNode] -> DecommissionNode -> [DecommissionNode]
decommissionRequiredPredecessors allNodes node =
  filter (`elem` allNodes) (rawPredecessors node)
 where
  rawPredecessors current = case current of
    SesConsumerQuiescence -> []
    SesProviderStack -> [SesConsumerQuiescence]
    SesSmtpIam -> [SesConsumerQuiescence]
    TargetGeneration _ _ -> [SesProviderStack, SesSmtpIam]
    RetainedCustody -> [SesProviderStack, SesSmtpIam] ++ targetGenerations allNodes
    TlsRetainedObjects -> [RetainedCustody]
    TlsRetentionIdentity -> [RetainedCustody]
    BackupObjects -> [TlsRetainedObjects, TlsRetentionIdentity]
    BackupPrefixAbsenceProof -> [BackupObjects]
    -- The shared bucket is the unique terminal: every other present node first.
    SharedObjectBucket -> filter (/= SharedObjectBucket) allNodes

-- | A deterministic topological ordering of the present nodes. The cycle guard
-- keeps the function total; the derived graph is acyclic, so it never triggers.
decommissionTopologicalOrder :: [DecommissionNode] -> [DecommissionNode]
decommissionTopologicalOrder allNodes = loop [] allNodes
 where
  loop emitted remaining
    | null remaining = reverse emitted
    | otherwise =
        case filter (ready emitted) remaining of
          [] -> reverse emitted ++ remaining
          (next : _) -> loop (next : emitted) (delete next remaining)
  ready emitted node =
    all (`elem` emitted) (decommissionRequiredPredecessors allNodes node)

-- | Run the destroy subgraph. The injected effect returns @Right ()@ for a node
-- that destroyed and read back its resource (or proved it absent), and
-- @Left detail@ for a failure. A node whose predecessors did not all succeed is
-- 'NodeBlocked' and its effect never runs.
runDecommissionGraph
  :: (Monad m)
  => [DecommissionNode]
  -> (DecommissionNode -> m (Either Text ()))
  -> m DecommissionReport
runDecommissionGraph allNodes runNode = do
  (_, executions) <- foldM step (Map.empty, []) (decommissionTopologicalOrder allNodes)
  pure (DecommissionReport (reverse executions))
 where
  step (verdicts, executions) node = do
    let predecessors = decommissionRequiredPredecessors allNodes node
        unmet = filter (not . succeeded verdicts) predecessors
    verdict <-
      if null unmet
        then either NodeFailed (const NodeSucceeded) <$> runNode node
        else pure (NodeBlocked unmet)
    pure (Map.insert node verdict verdicts, NodeExecution node verdict : executions)
  succeeded :: Map DecommissionNode NodeVerdict -> DecommissionNode -> Bool
  succeeded verdicts node = Map.lookup node verdicts == Just NodeSucceeded

-- | The run destroyed every node (nothing failed or blocked).
reportConverged :: DecommissionReport -> Bool
reportConverged = all ((== NodeSucceeded) . executedVerdict) . reportExecutions

reportFailed :: DecommissionReport -> [DecommissionNode]
reportFailed report =
  [ executedNode execution | execution <- reportExecutions report, isFailed (executedVerdict execution)
  ]
 where
  isFailed (NodeFailed _) = True
  isFailed _ = False

reportBlocked :: DecommissionReport -> [DecommissionNode]
reportBlocked report =
  [ executedNode execution | execution <- reportExecutions report, isBlocked (executedVerdict execution)
  ]
 where
  isBlocked (NodeBlocked _) = True
  isBlocked _ = False

-- | In the derived order, every present TLS node precedes the shared bucket.
tlsPrecedesSharedBucket :: [DecommissionNode] -> Bool
tlsPrecedesSharedBucket allNodes =
  precedes allNodes TlsRetainedObjects SharedObjectBucket
    && precedes allNodes TlsRetentionIdentity SharedObjectBucket

-- | Every SES provider/IAM destroy precedes every tombstone that depends on it.
sesDestroyPrecedesTombstones :: [DecommissionNode] -> Bool
sesDestroyPrecedesTombstones allNodes =
  and
    [ precedes allNodes destroyNode tombstone
    | destroyNode <- [SesProviderStack, SesSmtpIam]
    , tombstone <- RetainedCustody : targetGenerations allNodes
    ]

-- | Every live Target Agent tombstone precedes the retained-home custody
-- tombstone. This keeps target-owned material live until its exact generation
-- has been tombstoned and read back.
targetTombstonesPrecedeCustody :: [DecommissionNode] -> Bool
targetTombstonesPrecedeCustody allNodes =
  all (\target -> precedes allNodes target RetainedCustody) (targetGenerations allNodes)

-- | Retained-home custody must be tombstoned and read back while its Agent is
-- still live before either post-control-plane TLS deletion can begin.
custodyPrecedesTls :: [DecommissionNode] -> Bool
custodyPrecedesTls allNodes =
  precedes allNodes RetainedCustody TlsRetainedObjects
    && precedes allNodes RetainedCustody TlsRetentionIdentity

-- | Both disjoint TLS delete nodes precede the composite Authority backup
-- object/generation/key/identity/policy deletion node.
tlsPrecedesBackup :: [DecommissionNode] -> Bool
tlsPrecedesBackup allNodes =
  precedes allNodes TlsRetainedObjects BackupObjects
    && precedes allNodes TlsRetentionIdentity BackupObjects

-- | The all-registered-prefix absence proof follows the last prefix-owning
-- deletion and precedes destruction of the shared bucket.
allPrefixesProvenBeforeSharedBucket :: [DecommissionNode] -> Bool
allPrefixesProvenBeforeSharedBucket allNodes =
  precedes allNodes BackupObjects BackupPrefixAbsenceProof
    && precedes allNodes BackupPrefixAbsenceProof SharedObjectBucket

-- | The shared bucket, when present, is the last node in the derived order.
sharedBucketIsTerminal :: [DecommissionNode] -> Bool
sharedBucketIsTerminal allNodes
  | SharedObjectBucket `notElem` allNodes = True
  | otherwise = case reverse (decommissionTopologicalOrder allNodes) of
      (lastNode : _) -> lastNode == SharedObjectBucket
      [] -> True

targetGenerations :: [DecommissionNode] -> [DecommissionNode]
targetGenerations = filter isTargetGeneration
 where
  isTargetGeneration (TargetGeneration _ _) = True
  isTargetGeneration _ = False

-- | Whether @earlier@ precedes @later@ in the derived topological order. Vacuously
-- true when either node is absent from the manifest.
precedes :: [DecommissionNode] -> DecommissionNode -> DecommissionNode -> Bool
precedes allNodes earlier later =
  case (elemIndex earlier order, elemIndex later order) of
    (Just earlierIndex, Just laterIndex) -> earlierIndex < laterIndex
    _ -> True
 where
  order = decommissionTopologicalOrder allNodes
