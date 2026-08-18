{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.84: the join between the operational-credential graph-consumer
-- inventory and the program that actually contains those nodes.
--
-- 'Prodbox.Lifecycle.Teardown.OperationalCredentialInventory' enumerates the
-- teardown operations whose production interpreters may open a
-- Lifecycle-provider session, and its
-- 'OperationalCredentialDispositionBlocker' list rests on that enumeration:
-- the credential may not be disposed of while a consumer is still to run, and
-- the AWS audit doctrine additionally requires it live /through/ the terminal
-- audit. Both are claims about ordering, and an ordering claim is only as good
-- as its knowledge of which node is __last__.
--
-- The enumeration was authored by hand and joined to nothing. It was wrong:
-- it stopped at @ReconcileStackCheckpointRestore@, while
-- 'Prodbox.Lifecycle.Teardown.AwsCheckpointInterpreter' reaches the shared
-- registered-target interpreter in three further arms — checkpoint recovery
-- read-back, retirement, and retirement read-back — and the retirement
-- read-back is the completion node of every stack target, so it is later than
-- everything the list named. An inventory that under-reports its last consumer
-- understates precisely the fact it exists to establish.
--
-- This module supplies the missing join and the ordering property:
--
--   * 'teardownOperationCredentialConsumer' is total over the closed operation
--     universe, so a newly added 'TeardownOperation' is an exhaustiveness
--     failure until its credential dependency is classified deliberately —
--     the same discipline 'operationalCredentialConsumerForIntent' already
--     applies to @ProviderIntent@.
--   * 'validateOperationalCredentialCoverage' compiles the cascade program and
--     proves, in both directions, that the inventory and the program agree,
--     and that every credential-consuming node is a transitive predecessor of
--     the terminal audit.
--
-- Only 'Cascade' is used as the witness program. It is the surface that owns
-- both the full registered-target set and the terminal audit, so it is the
-- only surface on which the liveness-through-audit claim is even expressible.
module Prodbox.Lifecycle.Teardown.OperationalCredentialCoverage
  ( teardownOperationCredentialConsumer
  , OperationalCredentialCoverageError (..)
  , renderOperationalCredentialCoverageError
  , cascadeTerminalAuditNodeName
  , validateOperationalCredentialCoverage
  , operationalCredentialCoverageViolations
  , OperationalCredentialCoverageRegression
  , fixedOperationalCredentialCoverageRegression
  , coverageRegressionEveryConsumerReached
  , coverageRegressionConsumersPrecedeAudit
  , coverageRegressionCheckpointTailCounted
  , coverageRegressionAncestryIsDiscriminating
  , coverageRegressionAuditIsNotItsOwnConsumer
  )
where

import Data.List (nub, sort)
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (Cascade)
  , CleanupSurfaceWitness (CascadeSurface)
  )
import Prodbox.Lifecycle.Teardown.OperationalCredentialInventory
  ( OperationalCredentialGraphConsumer (..)
  , operationalCredentialGraphConsumerTag
  )
import Prodbox.Lifecycle.Teardown.Program
  ( DesiredAbsenceProgram
  , DesiredAbsenceProgramError
  , ProgramDependency (..)
  , ProgramNode
  , ProgramNodeName (..)
  , TeardownOperation (..)
  , compileDesiredAbsenceProgram
  , desiredAbsenceProgramNodes
  , programNodeDependencies
  , programNodeName
  , programNodeOperation
  )

-- | Which operational-credential consumer, if any, one closed teardown
-- operation is.
--
-- @Nothing@ means the operation's production interpreter reaches no
-- Lifecycle-provider session. The three cases where that is a deliberate
-- narrow answer rather than an obvious one are called out inline, because each
-- is adjacent to an arm that /does/ open a session.
teardownOperationCredentialConsumer
  :: TeardownOperation surface -> Maybe OperationalCredentialGraphConsumer
teardownOperationCredentialConsumer operation = case operation of
  ObserveRegisteredTarget {} ->
    Just ObserveRegisteredTargetCredentialConsumer
  ReconcileRegisteredTargetAbsent {} ->
    Just ReconcileRegisteredTargetAbsentCredentialConsumer
  ReadBackRegisteredTargetAbsent {} ->
    Just ReadBackRegisteredTargetAbsentCredentialConsumer
  -- The checkpoint family routes through the same registered-target
  -- interpreter that @mkCloudRuntime@ normalizes into it, except for the
  -- pair observation, which reads only the two Authority-held checkpoint
  -- copies.
  ObserveStackCheckpointPair {} -> Nothing
  ReconcileStackCheckpointRestore {} ->
    Just ReconcileStackCheckpointRestoreCredentialConsumer
  ReadBackStackCheckpointRecovery {} ->
    Just ReadBackStackCheckpointRecoveryCredentialConsumer
  RetireStackCheckpointPair {} ->
    Just RetireStackCheckpointPairCredentialConsumer
  ReadBackStackCheckpointRetirement {} ->
    Just ReadBackStackCheckpointRetirementCredentialConsumer
  -- The stack-reader bundle is an Authority repository round trip. It carries
  -- provider-derived facts but opens no provider session of its own.
  CommitAwsStackReaderBundle {} -> Nothing
  ReadBackAwsStackReaderBundle {} -> Nothing
  CommitEksDrainIntent {} ->
    Just CommitEksDrainIntentCredentialConsumer
  -- The intent read-back recovers the committed intent from the Authority; it
  -- is the one EKS arm that does not re-observe the cluster.
  ReadBackEksDrainIntent {} -> Nothing
  DrainEksKubernetesResources {} ->
    Just DrainEksKubernetesResourcesCredentialConsumer
  ReadBackEksKubernetesDrain {} ->
    Just ReadBackEksKubernetesDrainCredentialConsumer
  EstablishRecoveryPlane {} -> Nothing
  ReadBackRecoveryPlane {} -> Nothing
  ObserveRecoveryPlaneDisposition {} -> Nothing
  AuditCascadeEscapes -> Nothing
  CommitCascadePreUninstallReport -> Nothing
  ReadBackCascadePreUninstallReport -> Nothing
  UninstallCascadeLocalFoundation -> Nothing
  ReadBackCascadeLocalAbsence -> Nothing
  CommitCascadeCompletion -> Nothing
  ReadBackCascadeCompletion -> Nothing
  UninstallLocalOnlyFoundation -> Nothing
  ReadBackLocalOnlyAbsence -> Nothing
  CommitLocalOnlyCompletion -> Nothing
  ReadBackLocalOnlyCompletion -> Nothing
  CommitOrdinarySurfaceReport -> Nothing
  ReadBackOrdinarySurfaceReport -> Nothing
  AuditTotalDecommissionEscapes -> Nothing
  ObserveExternalDecommissionReceipt -> Nothing
  UninstallDecommissionLocalFoundation -> Nothing
  ReadBackDecommissionLocalAbsence -> Nothing
  ApplyDecommissionLocalDataDisposition -> Nothing
  ReadBackDecommissionLocalDataDisposition -> Nothing
  CommitDecommissionTerminalReceipt -> Nothing
  ReadBackDecommissionTerminalReceipt -> Nothing

data OperationalCredentialCoverageError
  = -- | The cascade program did not compile, so nothing can be proved about it.
    OperationalCredentialProgramUncompilable !DesiredAbsenceProgramError
  | -- | An inventoried consumer that no node in the compiled program reaches.
    -- A stale entry overstates how long the credential must stay live, which
    -- is the safe direction, but it also means the inventory is describing a
    -- program that no longer exists.
    OperationalCredentialConsumerUnreached !OperationalCredentialGraphConsumer
  | -- | A credential-consuming node that is not a transitive predecessor of
    -- the terminal audit. The audit must run while the credential is still
    -- live; a consumer scheduled outside its ancestry could run after the
    -- credential was disposed of.
    OperationalCredentialConsumerNotBeforeAudit
      !Text
      !OperationalCredentialGraphConsumer
  | -- | The compiled program has no terminal audit node, so the
    -- liveness-through-audit ordering has nothing to be checked against.
    OperationalCredentialTerminalAuditMissing !Text
  deriving (Eq, Show)

renderOperationalCredentialCoverageError
  :: OperationalCredentialCoverageError -> String
renderOperationalCredentialCoverageError err = case err of
  OperationalCredentialProgramUncompilable detail ->
    "the cascade desired-absence program did not compile, so operational \
    \credential coverage cannot be proved: "
      ++ show detail
  OperationalCredentialConsumerUnreached consumer ->
    "operational credential consumer `"
      ++ Text.unpack (operationalCredentialGraphConsumerTag consumer)
      ++ "` is inventoried but no node in the compiled cascade program has \
         \that operation; remove the stale entry from \
         \OperationalCredentialGraphConsumer."
  OperationalCredentialConsumerNotBeforeAudit nodeName consumer ->
    "node `"
      ++ Text.unpack nodeName
      ++ "` consumes the operational credential ("
      ++ Text.unpack (operationalCredentialGraphConsumerTag consumer)
      ++ ") but is not a transitive predecessor of `"
      ++ Text.unpack cascadeTerminalAuditNodeName
      ++ "`; the terminal audit must run while the credential is still live \
         \(lifecycle_reconciliation_doctrine.md § 3.3)."
  OperationalCredentialTerminalAuditMissing nodeName ->
    "the compiled cascade program has no `"
      ++ Text.unpack nodeName
      ++ "` node, so the operational credential's liveness-through-audit \
         \ordering cannot be checked."

-- | The cascade node that must run while the operational credential is still
-- live. Named here rather than reconstructed, so a rename of the program node
-- fails this check loudly instead of silently satisfying it.
cascadeTerminalAuditNodeName :: Text
cascadeTerminalAuditNodeName = "cascade/audit-escapes"

-- | Prove the inventory and the compiled cascade program agree, and that every
-- credential-consuming node precedes the terminal audit.
--
-- The forward direction — every credential-consuming operation in the program
-- maps to an inventoried consumer — is discharged by construction: the
-- classifier's result type /is/ the inventory, so an unclassified operation is
-- a compile error rather than a runtime finding.
validateOperationalCredentialCoverage
  :: Either [OperationalCredentialCoverageError] ()
validateOperationalCredentialCoverage =
  case compileDesiredAbsenceProgram CascadeSurface of
    Left err -> Left [OperationalCredentialProgramUncompilable err]
    Right program -> case unreached program ++ misordered program of
      [] -> Right ()
      errors -> Left errors

operationalCredentialCoverageViolations :: [String]
operationalCredentialCoverageViolations =
  either
    (map renderOperationalCredentialCoverageError)
    (const [])
    validateOperationalCredentialCoverage

consumerNodes
  :: DesiredAbsenceProgram 'Cascade
  -> [(ProgramNodeName, OperationalCredentialGraphConsumer)]
consumerNodes program =
  mapMaybe
    ( \node ->
        (,) (programNodeName node)
          <$> teardownOperationCredentialConsumer (programNodeOperation node)
    )
    (desiredAbsenceProgramNodes program)

unreached
  :: DesiredAbsenceProgram 'Cascade -> [OperationalCredentialCoverageError]
unreached program =
  [ OperationalCredentialConsumerUnreached consumer
  | consumer <- [minBound .. maxBound]
  , consumer `notElem` reachedConsumers
  ]
 where
  reachedConsumers = nub (map snd (consumerNodes program))

misordered
  :: DesiredAbsenceProgram 'Cascade -> [OperationalCredentialCoverageError]
misordered program
  | auditNode `notElem` map programNodeName nodes =
      [OperationalCredentialTerminalAuditMissing cascadeTerminalAuditNodeName]
  | otherwise =
      [ OperationalCredentialConsumerNotBeforeAudit
          (programNodeNameText nodeName)
          consumer
      | (nodeName, consumer) <- consumerNodes program
      , not (nodeName `Set.member` auditAncestors)
      ]
 where
  nodes = desiredAbsenceProgramNodes program
  auditNode = ProgramNodeName cascadeTerminalAuditNodeName
  auditAncestors = ancestorsOf nodes auditNode

-- | Fixed regression result. A coverage check that passes because its
-- ancestry relation is trivially total proves nothing, so this records the
-- discriminating facts alongside the two positive ones.
data OperationalCredentialCoverageRegression = OperationalCredentialCoverageRegression
  { coverageRegressionEveryConsumerReached :: !Bool
  , coverageRegressionConsumersPrecedeAudit :: !Bool
  , coverageRegressionCheckpointTailCounted :: !Bool
  -- ^ The three checkpoint-tail consumers Sprint @4.84@ added are present as
  -- nodes, so the correction is measured against the program rather than
  -- asserted.
  , coverageRegressionAncestryIsDiscriminating :: !Bool
  -- ^ The ancestry relation is not "everything": the cascade completion
  -- read-back runs strictly after the audit and must not be an ancestor of
  -- it. Without this the ordering check would pass vacuously.
  , coverageRegressionAuditIsNotItsOwnConsumer :: !Bool
  -- ^ The audit itself opens no provider session, so it cannot satisfy its
  -- own liveness precondition.
  }
  deriving (Eq, Show)

fixedOperationalCredentialCoverageRegression
  :: OperationalCredentialCoverageRegression
fixedOperationalCredentialCoverageRegression =
  case compileDesiredAbsenceProgram CascadeSurface of
    Left _ -> allFalse
    Right program ->
      let nodes = desiredAbsenceProgramNodes program
          auditAncestors = ancestorsOf nodes (ProgramNodeName cascadeTerminalAuditNodeName)
          reached = nub (map snd (consumerNodes program))
          checkpointTail =
            [ ReadBackStackCheckpointRecoveryCredentialConsumer
            , RetireStackCheckpointPairCredentialConsumer
            , ReadBackStackCheckpointRetirementCredentialConsumer
            ]
       in OperationalCredentialCoverageRegression
            { coverageRegressionEveryConsumerReached =
                null (unreached program)
            , coverageRegressionConsumersPrecedeAudit =
                null (misordered program)
            , coverageRegressionCheckpointTailCounted =
                all (`elem` reached) checkpointTail
            , coverageRegressionAncestryIsDiscriminating =
                not
                  ( ProgramNodeName "cascade/read-back-completion"
                      `Set.member` auditAncestors
                  )
            , coverageRegressionAuditIsNotItsOwnConsumer =
                null
                  [ ()
                  | node <- nodes
                  , programNodeName node
                      == ProgramNodeName cascadeTerminalAuditNodeName
                  , Just _ <-
                      [teardownOperationCredentialConsumer (programNodeOperation node)]
                  ]
            }
 where
  allFalse =
    OperationalCredentialCoverageRegression
      { coverageRegressionEveryConsumerReached = False
      , coverageRegressionConsumersPrecedeAudit = False
      , coverageRegressionCheckpointTailCounted = False
      , coverageRegressionAncestryIsDiscriminating = False
      , coverageRegressionAuditIsNotItsOwnConsumer = False
      }

-- | Transitive predecessors of one node, over every dependency kind.
--
-- Every kind counts: @RequiresAttempt@ and @RequiresTerminal@ order the run
-- exactly as @RequiresSuccess@ does — they differ in what outcome the
-- successor tolerates, not in when it may start — and the credential must stay
-- live for a consumer that is merely attempted just as much as for one that
-- must succeed.
ancestorsOf :: [ProgramNode 'Cascade] -> ProgramNodeName -> Set.Set ProgramNodeName
ancestorsOf nodes start = go (Set.singleton start) (directPredecessors start)
 where
  go seen [] = seen
  go seen (next : queue)
    | next `Set.member` seen = go seen queue
    | otherwise =
        go (Set.insert next seen) (directPredecessors next ++ queue)

  directPredecessors name =
    sort
      ( nub
          [ programDependencyNode dependency
          | node <- nodes
          , programNodeName node == name
          , dependency <- programNodeDependencies node
          ]
      )
