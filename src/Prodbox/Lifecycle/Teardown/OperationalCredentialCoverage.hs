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
  , teardownOperationIsTerminalAudit
  , teardownOperationIsCredentialDisposition
  , teardownOperationIsCredentialRevocationReadBack
  , measuredOperationalCredentialDispositionBlockers
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
  , coverageRegressionAuditConsumesCredential
  , coverageRegressionNonConsumersExist
  , OperationalCredentialDispositionRegression
  , fixedOperationalCredentialDispositionRegression
  , dispositionRegressionMeasuredEqualsPublished
  , dispositionRegressionSomeBlockersAreDerived
  , dispositionRegressionCascadeHasAudit
  , dispositionRegressionOperationalSurfaceHasNoAudit
  , dispositionRegressionAuditPredicateDiscriminates
  , dispositionRegressionFreezeRouteIssuesFreeze
  , dispositionRegressionFreezeRouteMeasurementDiscriminates
  , dispositionRegressionDecommissionOrdersDispositionAfterAudit
  , dispositionRegressionDispositionIsNotAnAuditAncestor
  )
where

import Data.List (nub, sort)
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityControlRoute
  , authorityControlRouteIssuedCommandTag
  , authorityControlRoutesIssueCascadeAuditFreeze
  )
import Prodbox.Lifecycle.CredentialProvisioner.Execution
  ( canonicalTargetRevocationReadBackProtocolExists
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (Cascade, TotalDecommission)
  , CleanupSurfaceWitness
    ( CascadeSurface
    , OperationalTeardownSurface
    , TotalDecommissionSurface
    )
  )
import Prodbox.Lifecycle.Teardown.OperationalCredentialInventory
  ( DispositionBlockerEvidence (..)
  , LegacyOperationalIdentityStatus (LegacyOperationalIdentityMigrationRequired)
  , OperationalCredentialDispositionBlocker (..)
  , OperationalCredentialGraphConsumer (..)
  , dispositionBlockerEvidence
  , legacyOperationalIdentity
  , legacyOperationalIdentityStatus
  , operationalCredentialGraphConsumerTag
  , operationalCredentialInventory
  , operationalCredentialInventoryDispositionBlockers
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
import Prodbox.Lifecycle.Teardown.ProviderDispatch
  ( teardownProviderDispatchOwnershipIsTotal
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
  -- Sprint 4.85 (2026-08-18): an escape audit enumerates provider-side
  -- resources, so it opens a Lifecycle-provider session of its own. Assigning
  -- it is what retires @TerminalAuditProviderCapabilityUnassigned@, and it is
  -- what makes the liveness-through-audit ordering claim about a node that
  -- actually needs the credential. The executing adapter is Sprint @7.36@'s;
  -- what is fixed here is the requirement it has to satisfy.
  AuditCascadeEscapes -> Just TerminalEscapeAuditCredentialConsumer
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
  -- The credential disposition submits to the Authority and reads its own
  -- result back; it never opens a Lifecycle-provider session. A disposition
  -- that consumed the credential it disposes of could not be ordered after
  -- the audit at all.
  RevokeOperationalCredential _ -> Nothing
  ReadBackOperationalCredentialRevocation _ -> Nothing
  AuditTotalDecommissionEscapes -> Just TerminalEscapeAuditCredentialConsumer
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
  | -- | A published disposition blocker the sources no longer establish. A
    -- stale blocker keeps justifying an omission after the reason for it is
    -- gone, which is precisely what this list is used for.
    OperationalCredentialDispositionBlockerStale
      !OperationalCredentialDispositionBlocker
  | -- | A blocker the sources establish that the published list omits.
    OperationalCredentialDispositionBlockerUnpublished
      !OperationalCredentialDispositionBlocker
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
  OperationalCredentialDispositionBlockerStale blocker ->
    "operational credential disposition blocker `"
      ++ show blocker
      ++ "` is published by operationalCredentialInventoryDispositionBlockers "
      ++ "but the sources no longer establish it ("
      ++ evidenceDetail blocker
      ++ "); remove it, because a stale blocker keeps justifying the omission "
      ++ "of the Operational registry descriptors after its reason is gone."
  OperationalCredentialDispositionBlockerUnpublished blocker ->
    "operational credential disposition blocker `"
      ++ show blocker
      ++ "` is established by the sources ("
      ++ evidenceDetail blocker
      ++ ") but operationalCredentialInventoryDispositionBlockers does not "
      ++ "publish it."
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

evidenceDetail :: OperationalCredentialDispositionBlocker -> String
evidenceDetail blocker = case dispositionBlockerEvidence blocker of
  DerivedFromCompiledTeardownPrograms ->
    "derived from the compiled teardown programs"
  DerivedFromCredentialConsumerClassifier ->
    "derived from teardownOperationCredentialConsumer"
  DerivedFromLegacyIdentityStatus ->
    "derived from legacyOperationalIdentityStatus"
  DerivedFromAuthorityControlRoutes ->
    "derived from the closed Authority control-route vocabulary"
  DerivedFromRevocationReadBackProtocol ->
    "derived from the canonical target revocation read-back decision table"
  DerivedFromCompiledOrdinaryRevocationPath ->
    "derived from the compiled operational program's credential disposition \
    \and its mandatory read-back"
  DerivedFromProviderDispatchOwnership ->
    "derived from the teardown Provider dispatch key's cleanup ownership"

-- | Is this operation a terminal escape audit?
--
-- Total, so a new audit operation cannot be added without deciding whether the
-- \"the surface that disposes has no audit\" blocker still holds.
teardownOperationIsTerminalAudit :: TeardownOperation surface -> Bool
teardownOperationIsTerminalAudit operation = case operation of
  AuditCascadeEscapes -> True
  AuditTotalDecommissionEscapes -> True
  _ -> False

-- | Does this operation read back an operational credential disposition?
--
-- The pair matters, not either half: a disposition with no mandatory read-back
-- is a revoke response, and the canonical read-back protocol exists precisely
-- to refuse treating one as evidence.
teardownOperationIsCredentialRevocationReadBack
  :: TeardownOperation surface -> Bool
teardownOperationIsCredentialRevocationReadBack operation = case operation of
  ReadBackOperationalCredentialRevocation _ -> True
  _ -> False

-- | Does this operation dispose of the operational credential?
--
-- Sprint 4.85 (2026-08-18): 'RevokeOperationalCredential' does. It is indexed
-- at @'OperationalTeardown@, which is what
-- @AuditBeforeDispositionConflictsWithCurrentCascadeGraph@ still measures
-- against: the operation now exists, but the surface that owns a terminal
-- audit does not yet emit one, so the audit-then-dispose order still has no
-- single surface expressing both halves.
teardownOperationIsCredentialDisposition :: TeardownOperation surface -> Bool
teardownOperationIsCredentialDisposition operation = case operation of
  RevokeOperationalCredential _ -> True
  _ -> False

-- | Recompute the disposition blockers the sources establish.
--
-- Every one of the eight is measured from a source that can stop being true.
-- The list carried four hand-authored reasons when Sprint @4.85@ began, and a
-- reason nothing recomputes goes on justifying an omission after the reason is
-- gone -- which is the failure mode this module exists to remove.
--
-- @GlobalProviderAdmissionFreezeUnavailable@ became the fifth on 2026-08-18.
-- It rested on a type-level absence for exactly as long as the freeze had no
-- caller-reachable route; the route is now a value
-- ('Prodbox.Lifecycle.Authority.Admission.AuthorityControlRoute'), so the
-- blocker is measured from it and deleting the route re-establishes it.
measuredOperationalCredentialDispositionBlockers
  :: Either DesiredAbsenceProgramError [OperationalCredentialDispositionBlocker]
measuredOperationalCredentialDispositionBlockers = do
  cascade <- compileDesiredAbsenceProgram CascadeSurface
  operational <- compileDesiredAbsenceProgram OperationalTeardownSurface
  decommission <- compileDesiredAbsenceProgram TotalDecommissionSurface
  let operations program = map programNodeOperation (desiredAbsenceProgramNodes program)
      -- The audit-then-dispose order is expressible only on a surface that has
      -- both halves. Total decommission is that surface: it owns the terminal
      -- escape audit and it is the one surface that disposes of the credential
      -- as part of destroying everything.
      auditThenDispositionExpressible =
        any teardownOperationIsTerminalAudit (operations decommission)
          && any teardownOperationIsCredentialDisposition (operations decommission)
      -- ... and the order actually compiled is the legal one. Every disposition
      -- node on that surface is a strict descendant of the audit, so the
      -- credential is live through the audit and disposed of only afterwards.
      -- Measured over the emitted dependency graph rather than asserted beside
      -- the node list, so re-ordering the program re-establishes the blocker.
      dispositionFollowsAudit =
        let nodes = desiredAbsenceProgramNodes decommission
            auditNames =
              [ programNodeName node
              | node <- nodes
              , teardownOperationIsTerminalAudit (programNodeOperation node)
              ]
            dispositionNames =
              [ programNodeName node
              | node <- nodes
              , teardownOperationIsCredentialDisposition
                  (programNodeOperation node)
              ]
         in not (null auditNames)
              && not (null dispositionNames)
              && and
                [ auditName `Set.member` ancestorsOfDecommission nodes dispositionName
                | auditName <- auditNames
                , dispositionName <- dispositionNames
                ]
      cascadeAuditConsumesCredential =
        or
          [ True
          | operation <- operations cascade
          , teardownOperationIsTerminalAudit operation
          , Just _ <- [teardownOperationCredentialConsumer operation]
          ]
      -- The ordinary revocation path is the compiled operational program
      -- naming a credential disposition and the mandatory read-back that
      -- confirms it. Both halves are required: a disposition whose result is
      -- never read back is a revoke response, which is exactly what the
      -- canonical read-back protocol exists to refuse.
      --
      -- Executing the node is the dispatcher activation Sprints `4.86` and
      -- `6.5` own; every other compiled node on every surface is in the same
      -- position, including the ones whose completion minters this sprint
      -- already landed. This sprint makes no claim about that activation.
      operationalPathRevokes =
        any teardownOperationIsCredentialDisposition (operations operational)
          && any
            teardownOperationIsCredentialRevocationReadBack
            (operations operational)
      legacyMigrationRequired =
        legacyOperationalIdentityStatus legacyOperationalIdentity
          == LegacyOperationalIdentityMigrationRequired
  pure
    ( [ DispositionBeforeAuditConflictsWithLiveAuditCredential
      | not dispositionFollowsAudit
      ]
        ++ [ AuditBeforeDispositionConflictsWithCurrentCascadeGraph
           | not auditThenDispositionExpressible
           ]
        ++ [ TerminalAuditProviderCapabilityUnassigned
           | not cascadeAuditConsumesCredential
           ]
        ++ [ GlobalProviderAdmissionFreezeUnavailable
           | not authorityControlRoutesIssueCascadeAuditFreeze
           ]
        ++ [ CanonicalTargetRevocationReadBackUnavailable
           | not canonicalTargetRevocationReadBackProtocolExists
           ]
        ++ [OrdinaryLifecycleProviderRevocationUnavailable | not operationalPathRevokes]
        ++ [ ProviderOperationCleanupRunOwnershipUnavailable
           | not teardownProviderDispatchOwnershipIsTotal
           ]
        ++ [LegacyOperationalIdentityReplacementUndefined | legacyMigrationRequired]
    )

dispositionBlockerViolations
  :: [OperationalCredentialCoverageError]
dispositionBlockerViolations =
  case measuredOperationalCredentialDispositionBlockers of
    Left err -> [OperationalCredentialProgramUncompilable err]
    Right measured ->
      [ OperationalCredentialDispositionBlockerStale blocker
      | blocker <- published
      , blocker `notElem` measured
      ]
        ++ [ OperationalCredentialDispositionBlockerUnpublished blocker
           | blocker <- measured
           , blocker `notElem` published
           ]
 where
  published =
    operationalCredentialInventoryDispositionBlockers operationalCredentialInventory

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
    Right program ->
      case unreached program ++ misordered program ++ dispositionBlockerViolations of
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
  , coverageRegressionAuditConsumesCredential :: !Bool
  -- ^ Sprint 4.85 (2026-08-18): the audit is itself a credential consumer.
  -- Until it was, "the credential must stay live through the audit" was an
  -- ordering claim about a node the inventory said needed no credential.
  , coverageRegressionNonConsumersExist :: !Bool
  -- ^ The consumer classifier still discriminates: the cascade completion
  -- read-back opens no provider session. Without this, classifying the audit
  -- could have been the first step toward a classifier that answered
  -- @Just@ for everything, which would satisfy the ordering check vacuously.
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
            , coverageRegressionAuditConsumesCredential =
                not
                  ( null
                      [ ()
                      | node <- nodes
                      , programNodeName node
                          == ProgramNodeName cascadeTerminalAuditNodeName
                      , Just _ <-
                          [teardownOperationCredentialConsumer (programNodeOperation node)]
                      ]
                  )
            , coverageRegressionNonConsumersExist =
                null
                  [ ()
                  | node <- nodes
                  , programNodeName node
                      == ProgramNodeName "cascade/read-back-completion"
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
      , coverageRegressionAuditConsumesCredential = False
      , coverageRegressionNonConsumersExist = False
      }

-- | Transitive predecessors on the total-decommission program.
--
-- Separate from 'ancestorsOf' only because that one is typed at @'Cascade@;
-- the traversal is the same and both count every dependency kind.
ancestorsOfDecommission
  :: [ProgramNode 'TotalDecommission]
  -> ProgramNodeName
  -> Set.Set ProgramNodeName
ancestorsOfDecommission nodes start =
  go (Set.singleton start) (directPredecessors start)
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

-- | Fixed regression for the disposition-blocker join.
--
-- A join that passes because its predicates never fire proves nothing, so this
-- records the discriminating facts beside the agreement: the audit predicate
-- finds the cascade audit (so "the operational surface has no audit" is a
-- measurement rather than a predicate that never matches), it does not match a
-- non-audit operation, and not every blocker is a type-level absence carried
-- through unchanged.
data OperationalCredentialDispositionRegression = OperationalCredentialDispositionRegression
  { dispositionRegressionMeasuredEqualsPublished :: !Bool
  , dispositionRegressionSomeBlockersAreDerived :: !Bool
  -- ^ Sprint 4.85 (2026-08-18): every blocker is now recomputed from a source,
  -- so no reason survives that nothing can invalidate.
  , dispositionRegressionCascadeHasAudit :: !Bool
  , dispositionRegressionOperationalSurfaceHasNoAudit :: !Bool
  , dispositionRegressionAuditPredicateDiscriminates :: !Bool
  , dispositionRegressionFreezeRouteIssuesFreeze :: !Bool
  -- ^ An externally admissible control route issues the Cascade-audit freeze,
  -- so @GlobalProviderAdmissionFreezeUnavailable@ is retired by measurement
  -- rather than by deletion.
  , dispositionRegressionFreezeRouteMeasurementDiscriminates :: !Bool
  -- ^ The route relation is not "everything is the freeze": the other five
  -- routes issue five other commands. Without this the measurement above
  -- would pass for a relation that had lost its discrimination.
  , dispositionRegressionDecommissionOrdersDispositionAfterAudit :: !Bool
  -- ^ The total-decommission program compiles a credential disposition and
  -- orders it strictly after the terminal audit. This is what makes both
  -- revoke-order blockers measurements rather than statements: the surface has
  -- both halves, and the compiled order is the legal one.
  , dispositionRegressionDispositionIsNotAnAuditAncestor :: !Bool
  -- ^ ... and the relation discriminates in the other direction: the audit is
  -- not a descendant of the disposition, so an unordered pair cannot read as
  -- ordered.
  }
  deriving (Eq, Show)

fixedOperationalCredentialDispositionRegression
  :: OperationalCredentialDispositionRegression
fixedOperationalCredentialDispositionRegression =
  case ( compileDesiredAbsenceProgram CascadeSurface
       , compileDesiredAbsenceProgram OperationalTeardownSurface
       , measuredOperationalCredentialDispositionBlockers
       ) of
    (Right cascade, Right operational, Right measured) ->
      let cascadeOperations =
            map programNodeOperation (desiredAbsenceProgramNodes cascade)
          operationalOperations =
            map programNodeOperation (desiredAbsenceProgramNodes operational)
          published =
            operationalCredentialInventoryDispositionBlockers
              operationalCredentialInventory
       in OperationalCredentialDispositionRegression
            { dispositionRegressionMeasuredEqualsPublished =
                sort measured == sort published
            , dispositionRegressionSomeBlockersAreDerived =
                null
                  [ blocker
                  | blocker <-
                      [minBound .. maxBound]
                        :: [OperationalCredentialDispositionBlocker]
                  , DerivedFromCompiledTeardownPrograms
                      /= dispositionBlockerEvidence blocker
                  , DerivedFromCredentialConsumerClassifier
                      /= dispositionBlockerEvidence blocker
                  , DerivedFromLegacyIdentityStatus
                      /= dispositionBlockerEvidence blocker
                  , DerivedFromAuthorityControlRoutes
                      /= dispositionBlockerEvidence blocker
                  , DerivedFromRevocationReadBackProtocol
                      /= dispositionBlockerEvidence blocker
                  , DerivedFromCompiledOrdinaryRevocationPath
                      /= dispositionBlockerEvidence blocker
                  , DerivedFromProviderDispatchOwnership
                      /= dispositionBlockerEvidence blocker
                  ]
            , dispositionRegressionCascadeHasAudit =
                any teardownOperationIsTerminalAudit cascadeOperations
            , dispositionRegressionOperationalSurfaceHasNoAudit =
                not (any teardownOperationIsTerminalAudit operationalOperations)
            , dispositionRegressionAuditPredicateDiscriminates =
                not
                  ( any
                      teardownOperationIsTerminalAudit
                      [ operation
                      | operation <- cascadeOperations
                      , operation /= AuditCascadeEscapes
                      ]
                  )
            , dispositionRegressionFreezeRouteIssuesFreeze =
                authorityControlRoutesIssueCascadeAuditFreeze
            , dispositionRegressionFreezeRouteMeasurementDiscriminates =
                length
                  ( nub
                      ( map
                          authorityControlRouteIssuedCommandTag
                          [minBound .. maxBound]
                      )
                  )
                  == length ([minBound .. maxBound] :: [AuthorityControlRoute])
            , dispositionRegressionDecommissionOrdersDispositionAfterAudit =
                decommissionOrdering
                  ( \auditName dispositionName nodes ->
                      auditName `Set.member` ancestorsOfDecommission nodes dispositionName
                  )
            , dispositionRegressionDispositionIsNotAnAuditAncestor =
                decommissionOrdering
                  ( \auditName dispositionName nodes ->
                      not
                        ( dispositionName
                            `Set.member` ancestorsOfDecommission nodes auditName
                        )
                  )
            }
    _ -> allDispositionFalse
 where
  allDispositionFalse =
    OperationalCredentialDispositionRegression
      { dispositionRegressionMeasuredEqualsPublished = False
      , dispositionRegressionSomeBlockersAreDerived = False
      , dispositionRegressionCascadeHasAudit = False
      , dispositionRegressionOperationalSurfaceHasNoAudit = False
      , dispositionRegressionAuditPredicateDiscriminates = False
      , dispositionRegressionFreezeRouteIssuesFreeze = False
      , dispositionRegressionFreezeRouteMeasurementDiscriminates = False
      , dispositionRegressionDecommissionOrdersDispositionAfterAudit = False
      , dispositionRegressionDispositionIsNotAnAuditAncestor = False
      }

-- | Hold one relation between every compiled audit and every compiled
-- disposition on the total-decommission surface.
decommissionOrdering
  :: ( ProgramNodeName
       -> ProgramNodeName
       -> [ProgramNode 'TotalDecommission]
       -> Bool
     )
  -> Bool
decommissionOrdering relation =
  case compileDesiredAbsenceProgram TotalDecommissionSurface of
    Left _ -> False
    Right program ->
      let nodes = desiredAbsenceProgramNodes program
          auditNames =
            [ programNodeName node
            | node <- nodes
            , teardownOperationIsTerminalAudit (programNodeOperation node)
            ]
          dispositionNames =
            [ programNodeName node
            | node <- nodes
            , teardownOperationIsCredentialDisposition (programNodeOperation node)
            ]
       in not (null auditNames)
            && not (null dispositionNames)
            && and
              [ relation auditName dispositionName nodes
              | auditName <- auditNames
              , dispositionName <- dispositionNames
              ]
