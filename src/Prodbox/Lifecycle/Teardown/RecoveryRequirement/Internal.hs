{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Package-private exact join between a sealed compiled capability catalog
-- and the durable CleanupRun aggregate.  The public facade is read-only; a
-- future Authority-owned re-observation boundary will be the production
-- caller of this join.
module Prodbox.Lifecycle.Teardown.RecoveryRequirement.Internal
  ( DerivedOrdinaryTeardownRecoveryRequirement
  , RecoveryRequirementDiagnostic
  , RecoveryRequirementError (..)
  , deriveOrdinaryTeardownRecoveryRequirementInternal
  , deriveRecoveryRequirementForFixtureInternal
  , derivedOrdinaryTeardownTargetAgent
  , derivedRecoveryRequirementDiagnostic
  , recoveryRequirementDiagnosticRunId
  , recoveryRequirementDiagnosticGraphDigest
  , recoveryRequirementDiagnosticCapabilityCatalogDigest
  , recoveryRequirementDiagnosticNonterminalCapabilities
  , recoveryRequirementDiagnosticIdentityDigest
  , RecoveryRequirementFixtureRegression
  , fixedRecoveryRequirementFixtureRegression
  , recoveryFixtureCatalogConstructionRefused
  , recoveryFixtureCurrentProgramTargetAgents
  , recoveryFixtureCapabilityIdentitySeparated
  , recoveryFixtureFullCatalogIdentitySeparated
  , recoveryFixturePendingTargetAgent
  , recoveryFixtureRunningTargetAgent
  , recoveryFixtureCompletedTargetAgent
  , recoveryFixtureBlockedTargetAgent
  , recoveryFixtureTerminalStatesPreserved
  , recoveryFixtureBindingMismatchesRefused
  )
where

import Data.Bifunctor (first)
import Data.Either (isLeft)
import Data.Foldable (traverse_)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.OrdinaryTeardownRecovery
  ( OrdinaryTeardownTargetAgent (..)
  )
import Prodbox.ControlPlane.CapabilityKind (CapabilityKind (LifecycleSubmit))
import Prodbox.ControlPlane.CapabilityRef (mkCapabilityRef)
import Prodbox.ControlPlane.Coordinate
  ( CapabilityCoordinate
  , mkAuthorityScope
  , mkCapabilityEndpoint
  , mkCoordinate
  , mkLogicalName
  , mkServiceIdentity
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDependency (..)
  , CleanupDependencyKind (CleanupRequiresSuccess)
  , CleanupDigest
  , CleanupGraph
  , CleanupNodeId
  , CleanupNodeOutcome (..)
  , CleanupNodeState (..)
  , CleanupOperationId
  , CleanupRun (..)
  , CleanupRunId
  , beginCleanupNode
  , cleanupDigestText
  , cleanupGraphDigest
  , cleanupGraphNodes
  , cleanupNodeCapabilityDigest
  , cleanupNodeDependencies
  , cleanupNodeId
  , cleanupNodeIdText
  , cleanupNodeOperationId
  , cleanupRunIdText
  , completeCleanupNode
  , mkCleanupAttemptId
  , mkCleanupDigest
  , mkCleanupGraph
  , mkCleanupNodeId
  , mkCleanupNodePlan
  , mkCleanupOperationId
  , mkCleanupOwnerId
  , mkCleanupRunId
  , newCleanupRun
  )
import Prodbox.Lifecycle.TargetCommitIntent (mkCredentialGeneration)
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compileDesiredAbsenceGraph
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceOperations
  , compiledDesiredAbsenceRecoveryCapabilityCatalog
  , compiledDesiredAbsenceRunId
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurfaceWitness (..)
  , LinuxRke2FoundationId (..)
  )
import Prodbox.Lifecycle.Teardown.RecoveryCapability
  ( RecoveryCapabilityCatalog
  , recoveryCapabilityCatalogCapabilitiesForNode
  , recoveryCapabilityCatalogDigest
  , recoveryCapabilityCatalogNodes
  , recoveryCapabilityCatalogOperationForNode
  , recoveryCapabilitySetNames
  , recoveryCapabilitySetRequiresTargetAgent
  )
import Prodbox.Lifecycle.Teardown.RecoveryCapability.Internal qualified as CapabilityInternal

data RecoveryRequirementDiagnostic = RecoveryRequirementDiagnostic
  { recoveryRequirementDiagnosticRunId :: !CleanupRunId
  , recoveryRequirementDiagnosticGraphDigest :: !CleanupDigest
  , recoveryRequirementDiagnosticCapabilityCatalogDigest :: !Text
  , recoveryRequirementDiagnosticNonterminalCapabilities
      :: ![(CleanupNodeId, [Text])]
  , recoveryRequirementDiagnosticIdentityDigest :: !Text
  }
  deriving (Eq, Show)

data DerivedOrdinaryTeardownRecoveryRequirement
  = DerivedOrdinaryTeardownRecoveryRequirement
      !OrdinaryTeardownTargetAgent
      !RecoveryRequirementDiagnostic
  deriving (Eq, Show)

data RecoveryRequirementError
  = RecoveryRequirementRunIdMismatch !CleanupRunId !CleanupRunId
  | RecoveryRequirementGraphMismatch
  | RecoveryRequirementGraphDigestMismatch !CleanupDigest !CleanupDigest
  | RecoveryRequirementNodeCatalogMismatch ![CleanupNodeId] ![CleanupNodeId]
  | RecoveryRequirementStateCatalogMismatch ![CleanupNodeId] ![CleanupNodeId]
  | RecoveryRequirementCompiledOperationCatalogMismatch
      ![CleanupNodeId]
      ![CleanupNodeId]
  | RecoveryRequirementCapabilityMissing !CleanupNodeId
  | RecoveryRequirementCapabilityOperationMissing !CleanupNodeId
  | RecoveryRequirementCapabilityOperationMismatch
      !CleanupNodeId
      !CleanupOperationId
      !CleanupOperationId
  deriving (Eq, Show)

-- | Fixed, non-authorizing regression vector for the package-private
-- synthetic Target-generation fixture.  The facade exposes only these
-- diagnostic facts: no catalog, capability set, CleanupRun, or derived
-- requirement can cross this boundary.
data RecoveryRequirementFixtureRegression
  = RecoveryRequirementFixtureRegression
  { recoveryFixtureCatalogConstructionRefused :: !Bool
  , recoveryFixtureCurrentProgramTargetAgents
      :: ![OrdinaryTeardownTargetAgent]
  , recoveryFixtureCapabilityIdentitySeparated :: !Bool
  , recoveryFixtureFullCatalogIdentitySeparated :: !Bool
  , recoveryFixturePendingTargetAgent :: !OrdinaryTeardownTargetAgent
  , recoveryFixtureRunningTargetAgent :: !OrdinaryTeardownTargetAgent
  , recoveryFixtureCompletedTargetAgent :: !OrdinaryTeardownTargetAgent
  , recoveryFixtureBlockedTargetAgent :: !OrdinaryTeardownTargetAgent
  , recoveryFixtureTerminalStatesPreserved :: !Bool
  , recoveryFixtureBindingMismatchesRefused :: !Bool
  }
  deriving (Eq, Show)

deriveOrdinaryTeardownRecoveryRequirementInternal
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupRun
  -> Either RecoveryRequirementError DerivedOrdinaryTeardownRecoveryRequirement
deriveOrdinaryTeardownRecoveryRequirementInternal compiled =
  deriveRecoveryRequirementForFixtureInternal
    (compiledDesiredAbsenceRunId compiled)
    (compiledDesiredAbsenceGraph compiled)
    (map fst (compiledDesiredAbsenceOperations compiled))
    (compiledDesiredAbsenceRecoveryCapabilityCatalog compiled)

-- | Synthetic-only seam for proving a future Target-generation obligation
-- without inventing a registered resource.  Production Authority code must
-- use 'deriveOrdinaryTeardownRecoveryRequirementInternal' with the sealed
-- compiled program.
deriveRecoveryRequirementForFixtureInternal
  :: CleanupRunId
  -> CleanupGraph
  -> [CleanupNodeId]
  -> RecoveryCapabilityCatalog
  -> CleanupRun
  -> Either RecoveryRequirementError DerivedOrdinaryTeardownRecoveryRequirement
deriveRecoveryRequirementForFixtureInternal
  expectedRunId
  expectedGraph
  compiledOperationNodes
  capabilityCatalog
  run = do
    if cleanupRunId run == expectedRunId
      then Right ()
      else
        Left
          ( RecoveryRequirementRunIdMismatch
              expectedRunId
              (cleanupRunId run)
          )
    if cleanupRunGraph run == expectedGraph
      then Right ()
      else Left RecoveryRequirementGraphMismatch
    let expectedGraphDigest = cleanupGraphDigest expectedGraph
    if cleanupRunGraphDigest run == expectedGraphDigest
      then Right ()
      else
        Left
          ( RecoveryRequirementGraphDigestMismatch
              expectedGraphDigest
              (cleanupRunGraphDigest run)
          )
    let expectedNodes = map cleanupNodeId (cleanupGraphNodes expectedGraph)
        sortedExpectedNodes = sort expectedNodes
        catalogNodes = sort (recoveryCapabilityCatalogNodes capabilityCatalog)
        stateNodes = Map.keys (cleanupRunNodeStates run)
        operationNodes = sort compiledOperationNodes
    if catalogNodes == sortedExpectedNodes
      then Right ()
      else
        Left
          ( RecoveryRequirementNodeCatalogMismatch
              sortedExpectedNodes
              catalogNodes
          )
    if stateNodes == sortedExpectedNodes
      then Right ()
      else
        Left
          ( RecoveryRequirementStateCatalogMismatch
              sortedExpectedNodes
              stateNodes
          )
    if operationNodes == sortedExpectedNodes
      then Right ()
      else
        Left
          ( RecoveryRequirementCompiledOperationCatalogMismatch
              sortedExpectedNodes
              operationNodes
          )
    traverse_ validateOperationBinding (cleanupGraphNodes expectedGraph)
    nonterminal <- traverse nonterminalEntry expectedNodes
    let active = [entry | Just entry <- nonterminal]
        targetAgent =
          if any (recoveryCapabilitySetRequiresTargetAgent . snd) active
            then OrdinaryTeardownWithTargetAgent
            else OrdinaryTeardownWithoutTargetAgent
        activeDiagnostics =
          [ (nodeId, recoveryCapabilitySetNames capabilities)
          | (nodeId, capabilities) <- active
          ]
        diagnostic =
          RecoveryRequirementDiagnostic
            { recoveryRequirementDiagnosticRunId = expectedRunId
            , recoveryRequirementDiagnosticGraphDigest = expectedGraphDigest
            , recoveryRequirementDiagnosticCapabilityCatalogDigest =
                recoveryCapabilityCatalogDigest capabilityCatalog
            , recoveryRequirementDiagnosticNonterminalCapabilities =
                activeDiagnostics
            , recoveryRequirementDiagnosticIdentityDigest =
                diagnosticDigest
                  expectedRunId
                  expectedGraphDigest
                  (recoveryCapabilityCatalogDigest capabilityCatalog)
                  activeDiagnostics
            }
    pure
      (DerivedOrdinaryTeardownRecoveryRequirement targetAgent diagnostic)
   where
    validateOperationBinding plan = do
      observedOperation <-
        maybe
          (Left (RecoveryRequirementCapabilityOperationMissing (cleanupNodeId plan)))
          Right
          ( recoveryCapabilityCatalogOperationForNode
              (cleanupNodeId plan)
              capabilityCatalog
          )
      let expectedOperation = cleanupNodeOperationId plan
      if observedOperation == expectedOperation
        then Right ()
        else
          Left
            ( RecoveryRequirementCapabilityOperationMismatch
                (cleanupNodeId plan)
                expectedOperation
                observedOperation
            )

    nonterminalEntry nodeId = do
      capabilities <-
        maybe
          (Left (RecoveryRequirementCapabilityMissing nodeId))
          Right
          ( recoveryCapabilityCatalogCapabilitiesForNode
              nodeId
              capabilityCatalog
          )
      state <-
        maybe
          ( Left
              ( RecoveryRequirementStateCatalogMismatch
                  (sort (map cleanupNodeId (cleanupGraphNodes expectedGraph)))
                  (Map.keys (cleanupRunNodeStates run))
              )
          )
          Right
          (Map.lookup nodeId (cleanupRunNodeStates run))
      pure
        ( if nodeStateTerminal state
            then Nothing
            else Just (nodeId, capabilities)
        )

derivedOrdinaryTeardownTargetAgent
  :: DerivedOrdinaryTeardownRecoveryRequirement
  -> OrdinaryTeardownTargetAgent
derivedOrdinaryTeardownTargetAgent
  (DerivedOrdinaryTeardownRecoveryRequirement targetAgent _) = targetAgent

derivedRecoveryRequirementDiagnostic
  :: DerivedOrdinaryTeardownRecoveryRequirement
  -> RecoveryRequirementDiagnostic
derivedRecoveryRequirementDiagnostic
  (DerivedOrdinaryTeardownRecoveryRequirement _ diagnostic) = diagnostic

fixedRecoveryRequirementFixtureRegression
  :: Either Text RecoveryRequirementFixtureRegression
fixedRecoveryRequirementFixtureRegression = do
  fixtureNode <- firstShow (mkCleanupNodeId "lifecycle/synthetic/resolve-target")
  fixtureSecondary <- firstShow (mkCleanupNodeId "lifecycle/synthetic/unchanged")
  fixtureRunId <- firstShow (mkCleanupRunId "recovery-capability-run")
  fixtureOtherRunId <- firstShow (mkCleanupRunId "other-recovery-capability-run")
  fixtureOwner <- firstShow (mkCleanupOwnerId "recovery-capability-owner")
  fixtureAttempt <- firstShow (mkCleanupAttemptId "recovery-capability-attempt")
  fixtureCoordinate <- fixedFixtureCoordinate
  currentProgramTargetAgents <- fixedCurrentProgramTargetAgents
  baselineDraft <-
    firstShow
      ( CapabilityInternal.mkRecoveryCapabilityCatalogDraft
          [(fixtureNode, CapabilityInternal.resumeOrdinaryCleanupCapabilities)]
      )
  targetDraft <-
    firstShow
      ( CapabilityInternal.mkRecoveryCapabilityCatalogDraft
          [(fixtureNode, CapabilityInternal.targetGenerationRecoveryCapabilities)]
      )
  baselineOperation <-
    fixedFixtureOperation
      "synthetic-target-generation-operation/v1"
      baselineDraft
      CapabilityInternal.resumeOrdinaryCleanupCapabilities
  targetOperation <-
    fixedFixtureOperation
      "synthetic-target-generation-operation/v1"
      targetDraft
      CapabilityInternal.targetGenerationRecoveryCapabilities
  baselineGraph <-
    fixedFixtureGraph fixtureCoordinate fixtureNode baselineOperation
  targetGraph <-
    fixedFixtureGraph fixtureCoordinate fixtureNode targetOperation
  baselineCatalog <-
    firstShow
      ( CapabilityInternal.sealRecoveryCapabilityCatalog
          baselineDraft
          [(fixtureNode, baselineOperation)]
      )
  targetCatalog <-
    firstShow
      ( CapabilityInternal.sealRecoveryCapabilityCatalog
          targetDraft
          [(fixtureNode, targetOperation)]
      )
  twoNodeBaselineDraft <-
    firstShow
      ( CapabilityInternal.mkRecoveryCapabilityCatalogDraft
          [ (fixtureNode, CapabilityInternal.resumeOrdinaryCleanupCapabilities)
          , (fixtureSecondary, CapabilityInternal.resumeOrdinaryCleanupCapabilities)
          ]
      )
  twoNodeAlteredDraft <-
    firstShow
      ( CapabilityInternal.mkRecoveryCapabilityCatalogDraft
          [ (fixtureNode, CapabilityInternal.targetGenerationRecoveryCapabilities)
          , (fixtureSecondary, CapabilityInternal.resumeOrdinaryCleanupCapabilities)
          ]
      )
  unchangedBaselineOperation <-
    fixedFixtureOperation
      "synthetic-unchanged-operation/v1"
      twoNodeBaselineDraft
      CapabilityInternal.resumeOrdinaryCleanupCapabilities
  unchangedAlteredOperation <-
    fixedFixtureOperation
      "synthetic-unchanged-operation/v1"
      twoNodeAlteredDraft
      CapabilityInternal.resumeOrdinaryCleanupCapabilities
  blockedTargetDraft <-
    firstShow
      ( CapabilityInternal.mkRecoveryCapabilityCatalogDraft
          [ (fixtureNode, CapabilityInternal.resumeOrdinaryCleanupCapabilities)
          , (fixtureSecondary, CapabilityInternal.targetGenerationRecoveryCapabilities)
          ]
      )
  blockingOperation <-
    fixedFixtureOperation
      "synthetic-blocking-predecessor-operation/v1"
      blockedTargetDraft
      CapabilityInternal.resumeOrdinaryCleanupCapabilities
  blockedTargetOperation <-
    fixedFixtureOperation
      "synthetic-blocked-target-operation/v1"
      blockedTargetDraft
      CapabilityInternal.targetGenerationRecoveryCapabilities
  blockedGraph <-
    fixedFixtureTwoNodeGraph
      fixtureCoordinate
      fixtureNode
      fixtureSecondary
      blockingOperation
      blockedTargetOperation
  blockedCatalog <-
    firstShow
      ( CapabilityInternal.sealRecoveryCapabilityCatalog
          blockedTargetDraft
          [ (fixtureNode, blockingOperation)
          , (fixtureSecondary, blockedTargetOperation)
          ]
      )
  pending <-
    firstShow (newCleanupRun fixtureRunId targetGraph fixtureOwner 0 100)
  running <-
    firstShow
      (beginCleanupNode fixtureOwner 1 fixtureNode fixtureAttempt pending)
  completed <-
    firstShow
      ( completeCleanupNode
          fixtureOwner
          1
          fixtureNode
          fixtureAttempt
          CleanupNodeSucceeded
          running
      )
  blockedPending <-
    firstShow (newCleanupRun fixtureRunId blockedGraph fixtureOwner 0 100)
  blocking <-
    firstShow
      ( beginCleanupNode
          fixtureOwner
          1
          fixtureNode
          fixtureAttempt
          blockedPending
      )
  blocked <-
    firstShow
      ( completeCleanupNode
          fixtureOwner
          1
          fixtureNode
          fixtureAttempt
          (CleanupNodeFailed "synthetic predecessor refusal")
          blocking
      )
  pendingRequirement <-
    firstShow
      ( deriveRecoveryRequirementForFixtureInternal
          fixtureRunId
          targetGraph
          [fixtureNode]
          targetCatalog
          pending
      )
  runningRequirement <-
    firstShow
      ( deriveRecoveryRequirementForFixtureInternal
          fixtureRunId
          targetGraph
          [fixtureNode]
          targetCatalog
          running
      )
  completedRequirement <-
    firstShow
      ( deriveRecoveryRequirementForFixtureInternal
          fixtureRunId
          targetGraph
          [fixtureNode]
          targetCatalog
          completed
      )
  blockedRequirement <-
    firstShow
      ( deriveRecoveryRequirementForFixtureInternal
          fixtureRunId
          blockedGraph
          [fixtureNode, fixtureSecondary]
          blockedCatalog
          blocked
      )
  wrongDigest <- firstShow (mkCleanupDigest (Text.replicate 64 "0"))
  let duplicateCatalogRefused =
        isLeft
          ( CapabilityInternal.mkRecoveryCapabilityCatalogDraft
              [ (fixtureNode, CapabilityInternal.resumeOrdinaryCleanupCapabilities)
              , (fixtureNode, CapabilityInternal.resumeOrdinaryCleanupCapabilities)
              ]
          )
      missingBindingRefused =
        isLeft
          (CapabilityInternal.sealRecoveryCapabilityCatalog baselineDraft [])
      duplicateBindingRefused =
        isLeft
          ( CapabilityInternal.sealRecoveryCapabilityCatalog
              baselineDraft
              [ (fixtureNode, baselineOperation)
              , (fixtureNode, targetOperation)
              ]
          )
      wrongDigestRun = pending {cleanupRunGraphDigest = wrongDigest}
      missingStateRun = pending {cleanupRunNodeStates = Map.empty}
      bindingMismatchesRefused =
        and
          [ isLeft
              ( deriveRecoveryRequirementForFixtureInternal
                  fixtureOtherRunId
                  targetGraph
                  [fixtureNode]
                  targetCatalog
                  pending
              )
          , isLeft
              ( deriveRecoveryRequirementForFixtureInternal
                  fixtureRunId
                  baselineGraph
                  [fixtureNode]
                  baselineCatalog
                  pending
              )
          , isLeft
              ( deriveRecoveryRequirementForFixtureInternal
                  fixtureRunId
                  targetGraph
                  [fixtureNode]
                  targetCatalog
                  wrongDigestRun
              )
          , isLeft
              ( deriveRecoveryRequirementForFixtureInternal
                  fixtureRunId
                  targetGraph
                  [fixtureNode]
                  targetCatalog
                  missingStateRun
              )
          , isLeft
              ( deriveRecoveryRequirementForFixtureInternal
                  fixtureRunId
                  targetGraph
                  []
                  targetCatalog
                  pending
              )
          , isLeft
              ( deriveRecoveryRequirementForFixtureInternal
                  fixtureRunId
                  targetGraph
                  [fixtureNode]
                  baselineCatalog
                  pending
              )
          ]
      terminalStatesPreserved =
        Map.lookup fixtureNode (cleanupRunNodeStates completed)
          == Just (CleanupNodeCompleted fixtureAttempt CleanupNodeSucceeded)
          && Map.lookup fixtureSecondary (cleanupRunNodeStates blocked)
            == Just (CleanupNodeBlocked [fixtureNode])
  pure
    RecoveryRequirementFixtureRegression
      { recoveryFixtureCatalogConstructionRefused =
          duplicateCatalogRefused
            && missingBindingRefused
            && duplicateBindingRefused
      , recoveryFixtureCurrentProgramTargetAgents =
          currentProgramTargetAgents
      , recoveryFixtureCapabilityIdentitySeparated =
          baselineOperation /= targetOperation
            && cleanupGraphDigest baselineGraph /= cleanupGraphDigest targetGraph
            && fixedFixtureGraphShape baselineGraph
              == fixedFixtureGraphShape targetGraph
      , recoveryFixtureFullCatalogIdentitySeparated =
          unchangedBaselineOperation /= unchangedAlteredOperation
      , recoveryFixturePendingTargetAgent =
          derivedOrdinaryTeardownTargetAgent pendingRequirement
      , recoveryFixtureRunningTargetAgent =
          derivedOrdinaryTeardownTargetAgent runningRequirement
      , recoveryFixtureCompletedTargetAgent =
          derivedOrdinaryTeardownTargetAgent completedRequirement
      , recoveryFixtureBlockedTargetAgent =
          derivedOrdinaryTeardownTargetAgent blockedRequirement
      , recoveryFixtureTerminalStatesPreserved = terminalStatesPreserved
      , recoveryFixtureBindingMismatchesRefused = bindingMismatchesRefused
      }

data FixedSurfaceCase where
  FixedSurfaceCase
    :: CleanupSurfaceWitness surface
    -> Maybe AwsScope
    -> FixedSurfaceCase

fixedCurrentProgramTargetAgents
  :: Either Text [OrdinaryTeardownTargetAgent]
fixedCurrentProgramTargetAgents =
  traverse classify fixedSurfaceCases
 where
  classify (FixedSurfaceCase surface maybeAwsScope) = do
    runId <- firstShow (mkCleanupRunId "recovery-capability-current-run")
    owner <- firstShow (mkCleanupOwnerId "recovery-capability-current-owner")
    compiled <-
      firstShow
        ( compileDesiredAbsenceGraph
            runId
            (LinuxRke2FoundationId "linux-rke2-foundation")
            maybeAwsScope
            surface
        )
    run <-
      firstShow
        ( newCleanupRun
            runId
            (compiledDesiredAbsenceGraph compiled)
            owner
            0
            100
        )
    requirement <-
      firstShow
        (deriveOrdinaryTeardownRecoveryRequirementInternal compiled run)
    pure (derivedOrdinaryTeardownTargetAgent requirement)

fixedSurfaceCases :: [FixedSurfaceCase]
fixedSurfaceCases =
  [ FixedSurfaceCase LocalOnlySurface Nothing
  , FixedSurfaceCase CascadeSurface (Just fixedAwsScope)
  , FixedSurfaceCase ExplicitPerRunSurface (Just fixedAwsScope)
  , FixedSurfaceCase OperationalTeardownSurface (Just fixedAwsScope)
  , FixedSurfaceCase ExplicitLongLivedSurface (Just fixedAwsScope)
  , FixedSurfaceCase TotalDecommissionSurface (Just fixedAwsScope)
  ]

fixedAwsScope :: AwsScope
fixedAwsScope =
  AwsScope
    (AwsAccountId "111122223333")
    (AwsRegion "ca-central-1")

fixedFixtureCoordinate :: Either Text CapabilityCoordinate
fixedFixtureCoordinate = do
  service <- firstShow (mkServiceIdentity "lifecycle-authority")
  scope <- firstShow (mkAuthorityScope "cleanup/synthetic")
  endpoint <- firstShow (mkCapabilityEndpoint "resolve-target")
  logical <- firstShow (mkLogicalName "synthetic-target-generation")
  generation <- firstShow (mkCredentialGeneration 1)
  pure (mkCoordinate service scope endpoint logical generation)

fixedFixtureOperation
  :: Text
  -> CapabilityInternal.RecoveryCapabilityCatalogDraft
  -> CapabilityInternal.RecoveryCapabilitySet
  -> Either Text CleanupOperationId
fixedFixtureOperation baseIdentity catalog capabilities =
  firstShow
    ( mkCleanupOperationId
        ( "lifecycle-operation/"
            <> CapabilityInternal.bindRecoveryCapabilitiesToOperationIdentity
              baseIdentity
              catalog
              capabilities
        )
    )

fixedFixtureGraph
  :: CapabilityCoordinate
  -> CleanupNodeId
  -> CleanupOperationId
  -> Either Text CleanupGraph
fixedFixtureGraph coordinate nodeId operationId =
  firstShow
    ( mkCleanupGraph
        [ mkCleanupNodePlan
            (mkCapabilityRef @'LifecycleSubmit coordinate)
            nodeId
            operationId
            []
        ]
    )

fixedFixtureTwoNodeGraph
  :: CapabilityCoordinate
  -> CleanupNodeId
  -> CleanupNodeId
  -> CleanupOperationId
  -> CleanupOperationId
  -> Either Text CleanupGraph
fixedFixtureTwoNodeGraph coordinate firstNode secondNode firstOperation secondOperation =
  firstShow
    ( mkCleanupGraph
        [ mkCleanupNodePlan
            (mkCapabilityRef @'LifecycleSubmit coordinate)
            firstNode
            firstOperation
            []
        , mkCleanupNodePlan
            (mkCapabilityRef @'LifecycleSubmit coordinate)
            secondNode
            secondOperation
            [CleanupDependency firstNode CleanupRequiresSuccess]
        ]
    )

fixedFixtureGraphShape
  :: CleanupGraph -> [(CleanupNodeId, Text, [CleanupDependency])]
fixedFixtureGraphShape = map shape . cleanupGraphNodes
 where
  shape plan =
    ( cleanupNodeId plan
    , cleanupNodeCapabilityDigest plan
    , cleanupNodeDependencies plan
    )

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = first (Text.pack . show)

nodeStateTerminal :: CleanupNodeState -> Bool
nodeStateTerminal state = case state of
  CleanupNodeCompleted {} -> True
  CleanupNodeBlocked {} -> True
  CleanupNodePending -> False
  CleanupNodeRunning {} -> False

diagnosticDigest
  :: CleanupRunId
  -> CleanupDigest
  -> Text
  -> [(CleanupNodeId, [Text])]
  -> Text
diagnosticDigest runId graphDigest catalogDigest active =
  sha256Canonical
    ( [ "ordinary-teardown-recovery-requirement/v1"
      , cleanupRunIdText runId
      , cleanupDigestText graphDigest
      , catalogDigest
      ]
        ++ concatMap entryFields active
    )
 where
  entryFields (nodeId, capabilities) =
    "node" : cleanupNodeIdText nodeId : capabilities

sha256Canonical :: [Text] -> Text
sha256Canonical fields =
  TextEncoding.decodeUtf8
    (hexSha256 (TextEncoding.encodeUtf8 (Text.concat (map canonicalField fields))))
 where
  canonicalField value =
    Text.pack (show (Text.length value)) <> ":" <> value
