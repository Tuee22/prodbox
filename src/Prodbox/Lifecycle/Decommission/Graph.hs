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
  , DecommissionTerminalPhaseNode (..)
  , decommissionTerminalPhase
  , decommissionTerminalPhaseRepresentative
  , decommissionTerminalPhaseBijection
  , decommissionTerminalPhaseOrder
  , productionDecommissionPlanNodes
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
  , sharedBucketIsLastDeletion
  , terminalPhaseRunsLastInOrder
  )
where

import Control.Monad (foldM)
import Data.List (delete, elemIndex)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionChoiceFamily (LocalDataDispositionFamily)
  , DecommissionLocalDataDisposition
  , DecommissionNode
    ( BackupObjects
    , BackupPrefixAbsenceProof
    , DecommissionTerminalReceipt
    , FinalNoRetentionAudit
    , HomeSubstrateUninstall
    , LocalDataDisposition
    , RetainedCustody
    , SesConsumerQuiescence
    , SesProviderStack
    , SesSmtpIam
    , SharedObjectBucket
    , TargetGeneration
    , TlsRetainedObjects
    , TlsRetentionIdentity
    )
  , decommissionChoiceFamilyRepresentative
  , mandatoryDecommissionChoiceNodes
  , requiredSingletonDecommissionNodes
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

-- | Sprint 4.85: the exact node inventory a production total-decommission plan
-- must contain, in the order the graph derives.
--
-- The Authority authored this twice — a three-element prefix and a six-element
-- suffix around the optional Target Agent generation — while the verifier in
-- @Prodbox.CLI.Nuke@ required the set derived from the closed
-- 'Prodbox.Lifecycle.Decommission.Manifest.DecommissionSingletonNode'
-- enumeration. Nothing joined the producer to the verifier, so a newly added
-- singleton would have been required by one and never signed by the other. The
-- failure is fail-closed but arrives at the worst moment: inside the
-- interactive run, after the confirmation literal and the ephemeral admin
-- credential, as "Authority signed an incomplete production decommission
-- manifest".
--
-- Both halves are now derived from the two values that already state them: the
-- closed mandatory-singleton enumeration says /which/ nodes, and
-- 'decommissionTopologicalOrder' — the same order the runner executes — says
-- /where/ the parameterized target generations sit relative to them. The
-- derived plan is identical to the authored one today, so this is a
-- cannot-drift guard rather than a change to what the Authority signs.
-- Sprint 4.85: the operator's @.data@ retain-or-delete decision is an
-- explicit argument with no default. It is the one part of the plan the
-- Authority cannot derive from its own registered inventory -- the inventory
-- says the root exists, not what should become of it -- so it arrives as a
-- closed two-valued decision and is signed into the plan like every other
-- node.
productionDecommissionPlanNodes
  :: DecommissionLocalDataDisposition
  -> [DecommissionNode]
  -> [DecommissionNode]
productionDecommissionPlanNodes localDataDisposition parameterizedNodes =
  decommissionTopologicalOrder
    ( requiredSingletonDecommissionNodes
        ++ mandatoryDecommissionChoiceNodes localDataDisposition
        ++ parameterizedNodes
    )

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
    -- The shared bucket is the last resource deletion: every other present
    -- deletion or proof first, but not the terminal-phase nodes that observe
    -- or act on the result of deleting it.
    SharedObjectBucket ->
      filter
        (\other -> other /= SharedObjectBucket && isNothing (decommissionTerminalPhase other))
        allNodes
    FinalNoRetentionAudit -> terminalPhasePredecessors allNodes current
    HomeSubstrateUninstall -> terminalPhasePredecessors allNodes current
    LocalDataDisposition _ -> terminalPhasePredecessors allNodes current
    DecommissionTerminalReceipt -> terminalPhasePredecessors allNodes current

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

-- | Sprint 4.85: the closed, __ordered__ phase that runs after the last
-- resource deletion.
--
-- These nodes do not delete a registered resource class. They prove what the
-- deletions achieved and then dismantle the plane those deletions were driven
-- through, so they must follow every deletion — and they have an order among
-- themselves. Making that order a closed enumeration rather than a set of
-- pairwise edges is what lets
-- 'Prodbox.Lifecycle.Decommission.ProgramTag.decommissionTerminalPhaseOrderViolations'
-- check it against the order the compiled @TotalDecommission@ program emits,
-- instead of the runner graph and the compiled program each asserting one.
data DecommissionTerminalPhaseNode
  = -- | Prove no prodbox-owned resource survives, with no retained carve-out.
    TerminalPhaseFinalNoRetentionAudit
  | -- | Uninstall the home substrate and read back its absence.
    TerminalPhaseHomeSubstrateUninstall
  | -- | Apply the operator's explicit retained-local-data disposition and read
    -- back that it was honoured.
    TerminalPhaseLocalDataDisposition
  | -- | Prove from the receipt's own committed frames that every other node is
    -- durably terminal, so this node's success frame closes the record.
    TerminalPhaseDecommissionTerminalReceipt
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | Which terminal-phase node one 'DecommissionNode' is, if it is one.
--
-- Total over the closed node universe, so a new node is an exhaustiveness
-- failure until it is deliberately classified as a resource deletion or as
-- terminal-phase work.
decommissionTerminalPhase :: DecommissionNode -> Maybe DecommissionTerminalPhaseNode
decommissionTerminalPhase node = case node of
  SesConsumerQuiescence -> Nothing
  SesProviderStack -> Nothing
  SesSmtpIam -> Nothing
  TargetGeneration _ _ -> Nothing
  RetainedCustody -> Nothing
  TlsRetainedObjects -> Nothing
  TlsRetentionIdentity -> Nothing
  BackupObjects -> Nothing
  BackupPrefixAbsenceProof -> Nothing
  SharedObjectBucket -> Nothing
  FinalNoRetentionAudit -> Just TerminalPhaseFinalNoRetentionAudit
  HomeSubstrateUninstall -> Just TerminalPhaseHomeSubstrateUninstall
  LocalDataDisposition _ -> Just TerminalPhaseLocalDataDisposition
  DecommissionTerminalReceipt -> Just TerminalPhaseDecommissionTerminalReceipt

-- | One node standing for a terminal-phase rank.
--
-- Sprint 4.85: the phase used to enumerate its nodes directly, which stopped
-- working when a terminal-phase node acquired a parameter -- there is no one
-- @LocalDataDisposition@ node, there is one per operator decision. A
-- representative names the rank's /position/ and its /semantic tag/, both of
-- which every decision in the family shares, and is never signed or executed.
decommissionTerminalPhaseRepresentative
  :: DecommissionTerminalPhaseNode -> DecommissionNode
decommissionTerminalPhaseRepresentative phase = case phase of
  TerminalPhaseFinalNoRetentionAudit -> FinalNoRetentionAudit
  TerminalPhaseHomeSubstrateUninstall -> HomeSubstrateUninstall
  TerminalPhaseLocalDataDisposition ->
    decommissionChoiceFamilyRepresentative LocalDataDispositionFamily
  TerminalPhaseDecommissionTerminalReceipt -> DecommissionTerminalReceipt

-- | Both directions of the terminal-phase join, as a value.
decommissionTerminalPhaseBijection :: Bool
decommissionTerminalPhaseBijection =
  all
    ( \phase ->
        decommissionTerminalPhase (decommissionTerminalPhaseRepresentative phase)
          == Just phase
    )
    [minBound .. maxBound]

-- | The terminal phase in execution order, one representative per rank.
decommissionTerminalPhaseOrder :: [DecommissionNode]
decommissionTerminalPhaseOrder =
  map decommissionTerminalPhaseRepresentative [minBound .. maxBound]

-- | A terminal-phase node waits on every non-terminal node in the plan and on
-- every terminal-phase node ranked before it.
terminalPhasePredecessors :: [DecommissionNode] -> DecommissionNode -> [DecommissionNode]
terminalPhasePredecessors allNodes node =
  filter isPredecessor allNodes
 where
  rank = decommissionTerminalPhase node
  isPredecessor other = case decommissionTerminalPhase other of
    Nothing -> True
    Just otherPhase -> maybe False (otherPhase <) rank

-- | The shared bucket, when present, is the last resource deletion: every
-- other present deletion or proof precedes it.
sharedBucketIsLastDeletion :: [DecommissionNode] -> Bool
sharedBucketIsLastDeletion allNodes
  | SharedObjectBucket `notElem` allNodes = True
  | otherwise =
      all
        (\other -> precedes allNodes other SharedObjectBucket)
        ( filter
            (\other -> other /= SharedObjectBucket && isNothing (decommissionTerminalPhase other))
            allNodes
        )

-- | Sprint 4.85: the present terminal-phase nodes appear last, in their
-- enumeration order.
--
-- The shared bucket is no longer the unique terminal. The audit admits no
-- retained carve-out, so a clean verdict is a statement about the whole plan
-- having converged -- which is only true after the bucket it would otherwise
-- report as an escapee is gone; and the home uninstall dismantles the plane
-- through which the earlier nodes were answered, so it follows the audit.
terminalPhaseRunsLastInOrder :: [DecommissionNode] -> Bool
terminalPhaseRunsLastInOrder allNodes =
  map decommissionTerminalPhase tail' == map Just presentPhases
 where
  order = decommissionTopologicalOrder allNodes
  -- Compared by phase rank rather than by node equality: a terminal-phase node
  -- can carry a parameter, so the node in the plan is not the enumeration's
  -- representative.
  presentPhases =
    [ phase
    | phase <- [minBound .. maxBound]
    , any ((== Just phase) . decommissionTerminalPhase) allNodes
    ]
  tail' = drop (length order - length presentPhases) order

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
