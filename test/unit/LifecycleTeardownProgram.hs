{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownProgram
  ( lifecycleTeardownProgramSuite
  )
where

import Control.Monad (filterM, forM_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isSuffixOf, nub, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.EksClientAuthClient
  ( eksClientAuthTeardownExecutionSubmissionKey
  )
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.Registry (lifecycleRegistryRevision)
import Prodbox.Lifecycle.Teardown.Report
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import TestSupport

lifecycleTeardownProgramSuite :: SuiteBuilder ()
lifecycleTeardownProgramSuite = do
  describe "Sprint 4.84 closed lifecycle teardown program" $ do
    it "compiles the exact operation surface for every cleanup authority" $ do
      let checkSurface (SurfaceCase surface expectedCount expectedTargets) =
            case compileDesiredAbsenceProgram surface of
              Left err -> expectationFailure (show err)
              Right program -> do
                cleanupSurfaceFromWitness (desiredAbsenceProgramSurface program)
                  `shouldBe` cleanupSurfaceFromWitness surface
                let nodes = desiredAbsenceProgramNodes program
                    operations = map programNodeOperation nodes
                    operationTags = map teardownOperationTag operations
                length nodes `shouldBe` expectedCount
                operationTags `shouldBe` expectedOperationTags surface expectedTargets
                assertTopologicallyOrdered nodes
                length (nub (map programNodeName nodes)) `shouldBe` expectedCount
                length (nub operationTags) `shouldBe` expectedCount
                mapMaybe registeredObservationKey operations `shouldBe` expectedTargets
                sort (mapMaybe registeredReconcileKey operations)
                  `shouldBe` sort expectedTargets
                sort (mapMaybe registeredReadBackKey operations)
                  `shouldBe` sort expectedTargets
                mapMaybe checkpointObservationKey operations
                  `shouldBe` stackTargetKeysFor expectedTargets
                mapMaybe checkpointRestoreKey operations
                  `shouldBe` stackTargetKeysFor expectedTargets
                mapMaybe checkpointRecoveryReadBackKey operations
                  `shouldBe` stackTargetKeysFor expectedTargets
                mapMaybe awsStackReaderCommitKey operations
                  `shouldBe` stackTargetKeysFor expectedTargets
                mapMaybe awsStackReaderReadBackKey operations
                  `shouldBe` stackTargetKeysFor expectedTargets
                mapMaybe eksDrainIntentCommitKey operations
                  `shouldBe` eksTargetKeysFor expectedTargets
                mapMaybe eksDrainIntentReadBackKey operations
                  `shouldBe` eksTargetKeysFor expectedTargets
                mapMaybe eksDrainKey operations `shouldBe` eksTargetKeysFor expectedTargets
                mapMaybe eksDrainReadBackKey operations
                  `shouldBe` eksTargetKeysFor expectedTargets
                sort (mapMaybe checkpointRetirementKey operations)
                  `shouldBe` sort (stackTargetKeysFor expectedTargets)
                sort (mapMaybe checkpointRetirementReadBackKey operations)
                  `shouldBe` sort (stackTargetKeysFor expectedTargets)
                mapMaybe registeredBindingKind operations
                  `shouldSatisfy` notElem LocalSubstrate
      forM_ surfaceCases checkSurface

    it "pairs every accepted effect with one attempt-gated mandatory read-back" $ do
      let checkEffect nodes (effectNode, readBackTag) =
            case nodesWithTag readBackTag nodes of
              [readBackNode] ->
                programNodeDependencies readBackNode
                  `shouldBe` [ ProgramDependency
                                 (programNodeName effectNode)
                                 CleanupRequiresAttempt
                             ]
              matches ->
                expectationFailure
                  ( "expected exactly one read-back for "
                      ++ Text.unpack readBackTag
                      ++ ", observed "
                      ++ show (length matches)
                  )
          checkSurface (SurfaceCase surface _ expectedTargets) =
            case compileDesiredAbsenceProgram surface of
              Left err -> expectationFailure (show err)
              Right program -> do
                let nodes = desiredAbsenceProgramNodes program
                    effects =
                      [ (node, confirmation)
                      | node <- nodes
                      , Just confirmation <- [confirmationTag (programNodeOperation node)]
                      ]
                    readBackTags =
                      sort
                        [ teardownOperationTag operation
                        | node <- nodes
                        , let operation = programNodeOperation node
                        , isMandatoryReadBack operation
                        ]
                length effects `shouldBe` expectedEffectCount surface expectedTargets
                readBackTags `shouldBe` sort (map snd effects)
                forM_ effects (checkEffect nodes)
      forM_ surfaceCases checkSurface

    it "keeps local uninstall and terminal authority behind successful proof edges" $ do
      cascade <- expectProgram CascadeSurface
      assertProgramDependencies
        cascade
        "restore-checkpoint/aws-eks"
        [ ("target/aws-eks/observe-checkpoint-pair", CleanupRequiresSuccess)
        , ("target/aws-eks/observe", CleanupRequiresSuccess)
        ]
      assertProgramDependencies
        cascade
        "read-back-checkpoint-recovery/aws-eks"
        [("target/aws-eks/restore-checkpoint", CleanupRequiresAttempt)]
      assertProgramDependencies
        cascade
        "commit-aws-stack-reader-bundle/aws-eks"
        [("target/aws-eks/read-back-checkpoint-recovery", CleanupRequiresSuccess)]
      assertProgramDependencies
        cascade
        "read-back-aws-stack-reader-bundle/aws-eks"
        [("target/aws-eks/commit-aws-stack-reader-bundle", CleanupRequiresAttempt)]
      assertProgramDependencies
        cascade
        "commit-eks-drain-intent/aws-eks"
        [("target/aws-eks/observe", CleanupRequiresAttempt)]
      assertProgramDependencies
        cascade
        "read-back-eks-drain-intent/aws-eks"
        [("target/aws-eks/commit-eks-drain-intent", CleanupRequiresAttempt)]
      assertProgramDependencies
        cascade
        "drain-eks-kubernetes/aws-eks"
        [("target/aws-eks/read-back-eks-drain-intent", CleanupRequiresAttempt)]
      assertProgramDependencies
        cascade
        "read-back-eks-kubernetes-drain/aws-eks"
        [("target/aws-eks/drain-eks-kubernetes", CleanupRequiresAttempt)]
      assertProgramDependencies
        cascade
        "reconcile-absent/aws-eks"
        [ ("target/aws-eks/observe", CleanupRequiresSuccess)
        , ("target/aws-eks/read-back-checkpoint-recovery", CleanupRequiresSuccess)
        , ("target/aws-eks/read-back-aws-stack-reader-bundle", CleanupRequiresSuccess)
        , ("target/aws-eks/read-back-eks-kubernetes-drain", CleanupRequiresSuccess)
        , ("target/aws-ebs-volumes-per-run-test/read-back-absent", CleanupRequiresSuccess)
        ]
      assertProgramDependencies
        cascade
        "observe/aws-ebs-volumes-per-run-test"
        [ ("recovery/read-back", CleanupRequiresSuccess)
        , ("target/aws-eks/drain-eks-kubernetes", CleanupRequiresAttempt)
        ]
      assertProgramDependencies
        cascade
        "retire-checkpoint-pair/aws-eks"
        [("target/aws-eks/read-back-absent", CleanupRequiresSuccess)]
      assertProgramDependencies
        cascade
        "read-back-checkpoint-retirement/aws-eks"
        [("target/aws-eks/retire-checkpoint-pair", CleanupRequiresAttempt)]
      assertProgramDependencies
        cascade
        "observe-recovery-plane-disposition"
        [ ("recovery/read-back", CleanupRequiresTerminal)
        , ("target/aws-eks/read-back-checkpoint-retirement", CleanupRequiresTerminal)
        , ("target/aws-eks-subzone/read-back-checkpoint-retirement", CleanupRequiresTerminal)
        , ("target/aws-test/read-back-checkpoint-retirement", CleanupRequiresTerminal)
        , ("target/aws-ebs-volumes-per-run-test/read-back-absent", CleanupRequiresTerminal)
        ]
      assertProgramDependencies
        cascade
        "audit-cascade-escapes"
        [ ("recovery/observe-disposition", CleanupRequiresSuccess)
        , ("target/aws-eks/read-back-checkpoint-retirement", CleanupRequiresSuccess)
        , ("target/aws-eks-subzone/read-back-checkpoint-retirement", CleanupRequiresSuccess)
        , ("target/aws-test/read-back-checkpoint-retirement", CleanupRequiresSuccess)
        , ("target/aws-ebs-volumes-per-run-test/read-back-absent", CleanupRequiresSuccess)
        ]
      assertProgramDependencies
        cascade
        "uninstall-cascade-local-foundation"
        [("cascade/read-back-pre-uninstall-report", CleanupRequiresSuccess)]
      assertProgramDependencies
        cascade
        "commit-cascade-completion"
        [("cascade/read-back-local-absence", CleanupRequiresSuccess)]

      localOnly <- expectProgram LocalOnlySurface
      assertProgramDependencies
        localOnly
        "commit-local-only-completion"
        [("local/read-back-absence", CleanupRequiresSuccess)]

      total <- expectProgram TotalDecommissionSurface
      assertProgramDependencies
        total
        "uninstall-decommission-local-foundation"
        [ ("decommission/audit-escapes", CleanupRequiresSuccess)
        , ("decommission/observe-external-receipt", CleanupRequiresSuccess)
        ]
      assertProgramDependencies
        total
        "apply-decommission-local-data-disposition"
        [("decommission/read-back-local-absence", CleanupRequiresSuccess)]
      assertProgramDependencies
        total
        "commit-decommission-terminal-receipt"
        [("decommission/read-back-local-data-disposition", CleanupRequiresSuccess)]

  describe "Sprint 4.84 durable teardown graph" $ do
    it "requires and retains the exact local foundation and AWS evidence scope" $ do
      case compileDesiredAbsenceGraph
        fixtureRunId
        fixtureFoundation
        (Just fixtureAwsScope)
        LocalOnlySurface of
        Left err -> err `shouldBe` DesiredAbsenceAwsScopeForbidden LocalOnly
        Right _ -> expectationFailure "local-only graph accepted an AWS scope"
      let checkMissingAwsScope (SurfaceCase surface _ _) =
            case compileDesiredAbsenceGraph fixtureRunId fixtureFoundation Nothing surface of
              Left err ->
                err
                  `shouldBe` DesiredAbsenceAwsScopeRequired
                    (cleanupSurfaceFromWitness surface)
              Right _ -> expectationFailure "non-local graph compiled without an AWS scope"
          checkEvidenceScope (SurfaceCase surface _ _) =
            case compileGraph fixtureRunId surface of
              Left err -> expectationFailure (show err)
              Right compiled -> do
                let evidence = compiledDesiredAbsenceObservationScope compiled
                    expectedAwsScope = awsScopeFor surface
                evidenceCleanupSurface evidence
                  `shouldBe` cleanupSurfaceFromWitness surface
                evidenceRegistryRevision evidence `shouldBe` lifecycleRegistryRevision
                evidenceDurableRunScope evidence
                  `shouldBe` DurableObservationRunScope (cleanupRunIdText fixtureRunId)
                evidenceLinuxRke2Foundation evidence `shouldBe` fixtureFoundation
                evidenceAwsScope evidence `shouldBe` expectedAwsScope
                evidenceLifecycleOperation evidence `shouldBe` ReconcileDesiredAbsent
      forM_ nonLocalSurfaceCases checkMissingAwsScope
      forM_ surfaceCases checkEvidenceScope

    it "lowers every program node and dependency exactly once" $ do
      let checkLoweredNode compiled (sourceNode, graphNode) = do
            let expectedNodeId = nodeIdForName (programNodeName sourceNode)
            cleanupNodeId graphNode `shouldBe` expectedNodeId
            cleanupNodeIdText expectedNodeId `shouldSatisfy` Text.isPrefixOf "lifecycle/"
            cleanupNodeDependencies graphNode
              `shouldBe` map lowerDependency (programNodeDependencies sourceNode)
            cleanupNodeCapabilityDigest graphNode `shouldSatisfy` isSha256
            compiledOperationForNode expectedNodeId compiled
              `shouldBe` Just (programNodeOperation sourceNode)
          checkSurface (SurfaceCase surface expectedCount _) =
            case compileGraph fixtureRunId surface of
              Left err -> expectationFailure (show err)
              Right compiled -> do
                let sourceNodes =
                      desiredAbsenceProgramNodes
                        (compiledDesiredAbsenceProgram compiled)
                    graphNodes = cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
                    operationMap = compiledDesiredAbsenceOperations compiled
                length sourceNodes `shouldBe` expectedCount
                length graphNodes `shouldBe` expectedCount
                length operationMap `shouldBe` expectedCount
                length (nub (map cleanupNodeId graphNodes)) `shouldBe` expectedCount
                length (nub (map cleanupNodeOperationId graphNodes)) `shouldBe` expectedCount
                forM_ (zip sourceNodes graphNodes) (checkLoweredNode compiled)
      forM_ surfaceCases checkSurface

    it "is deterministic within a run and separates operation identities across runs" $ do
      firstCompiled <- expectGraph fixtureRunId CascadeSurface
      repeated <- expectGraph fixtureRunId CascadeSurface
      otherRunCompiled <- expectGraph fixtureOtherRunId CascadeSurface
      compiledDesiredAbsenceGraph repeated
        `shouldBe` compiledDesiredAbsenceGraph firstCompiled
      compiledDesiredAbsenceObservationScope repeated
        `shouldBe` compiledDesiredAbsenceObservationScope firstCompiled
      map graphNodeStableShape (cleanupGraphNodes (compiledDesiredAbsenceGraph otherRunCompiled))
        `shouldBe` map graphNodeStableShape (cleanupGraphNodes (compiledDesiredAbsenceGraph firstCompiled))
      map cleanupNodeOperationId (cleanupGraphNodes (compiledDesiredAbsenceGraph otherRunCompiled))
        `shouldSatisfy` (/= map cleanupNodeOperationId (cleanupGraphNodes (compiledDesiredAbsenceGraph firstCompiled)))
      cleanupGraphDigest (compiledDesiredAbsenceGraph otherRunCompiled)
        `shouldNotBe` cleanupGraphDigest (compiledDesiredAbsenceGraph firstCompiled)
      compiledDesiredAbsenceRunScope otherRunCompiled
        `shouldBe` DurableObservationRunScope (cleanupRunIdText fixtureOtherRunId)

    it "seals foundation, AWS account, and AWS region into the durable graph identity" $ do
      original <- expectGraph fixtureRunId CascadeSurface
      changedFoundation <-
        expectGraphWith
          fixtureRunId
          (LinuxRke2FoundationId "replacement-linux-rke2")
          (Just fixtureAwsScope)
          CascadeSurface
      changedAccount <-
        expectGraphWith
          fixtureRunId
          fixtureFoundation
          ( Just
              ( AwsScope
                  (AwsAccountId "999900001111")
                  (AwsRegion "ca-central-1")
              )
          )
          CascadeSurface
      changedRegion <-
        expectGraphWith
          fixtureRunId
          fixtureFoundation
          ( Just
              ( AwsScope
                  (AwsAccountId "111122223333")
                  (AwsRegion "us-east-2")
              )
          )
          CascadeSurface
      delimiterShifted <-
        expectGraphWith
          fixtureRunId
          (LinuxRke2FoundationId "home\NULaws-scope/present")
          ( Just
              ( AwsScope
                  (AwsAccountId "account")
                  (AwsRegion "region")
              )
          )
          CascadeSurface
      delimiterShiftedAccount <-
        expectGraphWith
          fixtureRunId
          (LinuxRke2FoundationId "home")
          ( Just
              ( AwsScope
                  (AwsAccountId "aws-scope/present\NULaccount")
                  (AwsRegion "region")
              )
          )
          CascadeSurface
      let variants =
            [ changedFoundation
            , changedAccount
            , changedRegion
            , delimiterShifted
            , delimiterShiftedAccount
            ]
          originalGraph = compiledDesiredAbsenceGraph original
          graphDigests =
            cleanupGraphDigest originalGraph
              : map (cleanupGraphDigest . compiledDesiredAbsenceGraph) variants
      length (nub graphDigests) `shouldBe` length graphDigests

  describe "Sprint 4.84 proof-carrying teardown result" $ do
    it "admits complete ordinary read-backs only with the exact Established proof" $ do
      regression <- expectReportRegression
      desiredAbsenceRegressionEstablishedCompletes regression `shouldBe` True
      desiredAbsenceRegressionNotEstablishedRefused regression `shouldBe` True
      desiredAbsenceRegressionLostRefused regression `shouldBe` True
      desiredAbsenceRegressionUnavailableRefused regression `shouldBe` True

    it "retains the opaque final disposition on every incomplete ordinary result" $ do
      regression <- expectReportRegression
      desiredAbsenceRegressionIncompleteRetainsFinal regression `shouldBe` True

    it "rejects every stale run, descriptor, graph, scope, operation, attempt, and report binding" $ do
      regression <- expectReportRegression
      desiredAbsenceRegressionExactBindingAccepted regression `shouldBe` True
      desiredAbsenceRegressionCrossBindingRefused regression `shouldBe` True
      desiredAbsenceRegressionAttemptBindingRefused regression `shouldBe` True
      desiredAbsenceRegressionReportBindingRefused regression `shouldBe` True

    it "keeps LocalOnly and TotalDecommission distinct from ordinary recovery" $ do
      regression <- expectReportRegression
      desiredAbsenceRegressionLocalAndTotalDistinct regression `shouldBe` True

    it "Sprint 4.85 explicit per-run mints its own completion witness" $ do
      -- `SurfaceCompletionEvidence` had only its Cascade constructor, so no
      -- ordinary surface could report completion at all. Explicit per-run is
      -- the one whose obligation is fully determined by the compiled program:
      -- it has no local-uninstall arm, so its registered-target read-backs,
      -- checkpoint retirement read-backs, and its own independently read-back
      -- report ARE the completion evidence.
      regression <- expectReportRegression
      desiredAbsenceRegressionExplicitPerRunCompletes regression `shouldBe` True
      -- And the obligation is not vacuous -- the per-run program really does
      -- carry both target absence and checkpoint disposition as mandatory
      -- read-backs, which is what makes the previous claim mean anything.
      desiredAbsenceRegressionExplicitPerRunObligationNonEmpty regression
        `shouldBe` True

    it "Sprint 4.85 explicit per-run completion refuses a plane-less or wrong-surface value" $ do
      -- These two arms belong to the minter rather than to classification: an
      -- ordinary classification cannot produce either, so only a mis-minted
      -- read-back value could carry one, and the minter refuses rather than
      -- trusting the value's own claim about itself.
      regression <- expectReportRegression
      desiredAbsenceRegressionExplicitPerRunUnavailableRefused regression
        `shouldBe` True
      desiredAbsenceRegressionExplicitPerRunSurfaceMismatchRefused regression
        `shouldBe` True

    it "keeps raw report and evidence minters outside the public facade" $ do
      source <- readFile "src/Prodbox/Lifecycle/Teardown/Report.hs"
      let header = moduleHeader source
      header `shouldNotContain` "CompiledDesiredAbsenceProgram"
      header `shouldNotContain` "CleanupRunReport"
      header `shouldNotContain` "classifyDesiredAbsenceReportInternal"
      header `shouldNotContain` "SurfaceReadBackEvidence (..)"
      header `shouldNotContain` "SurfaceIncompleteEvidence (..)"
      header `shouldNotContain` "RecoveryPlaneFinalEvidence (..)"
      cabal <- readFile "prodbox.cabal"
      let exposedLibrary =
            unlines
              (takeWhile (/= "    hs-source-dirs:   src") (lines cabal))
      cabal `shouldContain` "Prodbox.Lifecycle.Teardown.Report.Internal"
      exposedLibrary
        `shouldNotContain` "Prodbox.Lifecycle.Teardown.Report.Internal"
      importers <-
        sourceImporters
          "src"
          "import Prodbox.Lifecycle.Teardown.Report.Internal"
      importers
        `shouldBe` ["src/Prodbox/Lifecycle/Teardown/Report.hs"]

    it "seals the exact node identity and complete EKS operation catalog for effects" $ do
      compiled <- expectGraph fixtureRunId CascadeSurface
      commitPlan <- expectPlanWithTag compiled "commit-eks-drain-intent/aws-eks"
      drainPlan <- expectPlanWithTag compiled "drain-eks-kubernetes/aws-eks"
      let (commitOutcome, commitCaptures) =
            runCaptureEffects (runCompiledTeardownNode compiled commitPlan)
          (drainOutcome, drainCaptures) =
            runCaptureEffects (runCompiledTeardownNode compiled drainPlan)
      commitOutcome `shouldBe` CleanupNodeFailed "fixture interpreter refusal"
      drainOutcome `shouldBe` CleanupNodeFailed "fixture interpreter refusal"
      case (commitCaptures, drainCaptures) of
        ([commitCapture], [drainCapture]) -> do
          capturedNodeId commitCapture `shouldBe` cleanupNodeId commitPlan
          capturedOperationId commitCapture
            `shouldBe` cleanupNodeOperationId commitPlan
          capturedOperationTag commitCapture
            `shouldBe` "commit-eks-drain-intent/aws-eks"
          let operationIds = mapMaybe id (capturedEksOperationIds commitCapture)
          length operationIds `shouldBe` 4
          length (nub operationIds) `shouldBe` 4
          capturedEksOperationIds commitCapture
            `shouldBe` capturedEksOperationIds drainCapture
          capturedAuthSubmissionKey commitCapture
            `shouldNotBe` capturedAuthSubmissionKey drainCapture
        other -> expectationFailure ("unexpected execution captures: " ++ show other)

  describe "Sprint 4.84 promoted CleanupRun response-loss boundary" $ do
    it "accepts a lost CAS response only after exact read-back of the expected graph state" $ do
      compiled <- expectGraph fixtureRunId CascadeSurface
      initial <- expectFreshRun compiled
      state <- newIORef initial
      let repository =
            CleanupRunRepository
              { readCleanupRun =
                  Right . CleanupRunObserved (1 :: Int) <$> readIORef state
              , compareAndSwapCleanupRun = \_ expected -> do
                  writeIORef state expected
                  pure (Left "response lost")
              , compareAndSwapCleanupRunTombstone = \_ _ ->
                  pure (Left "not used")
              }
      result <-
        applyCleanupRunTransition
          repository
          (recordPrimaryOutcome fixtureOwner 1 CleanupPrimarySucceeded)
      case result of
        Left err -> expectationFailure (show err)
        Right observed -> do
          cleanupRunGraph observed `shouldBe` compiledDesiredAbsenceGraph compiled
          cleanupRunPrimaryOutcome observed `shouldBe` Just CleanupPrimarySucceeded

    it "refuses a lost CAS response when read-back does not equal the expected transition" $ do
      compiled <- expectGraph fixtureRunId CascadeSurface
      initial <- expectFreshRun compiled
      state <- newIORef initial
      let repository =
            CleanupRunRepository
              { readCleanupRun =
                  Right . CleanupRunObserved (1 :: Int) <$> readIORef state
              , compareAndSwapCleanupRun = \_ _ -> pure (Left "response lost")
              , compareAndSwapCleanupRunTombstone = \_ _ ->
                  pure (Left "not used")
              }
      applyCleanupRunTransition
        repository
        (recordPrimaryOutcome fixtureOwner 1 CleanupPrimarySucceeded)
        `shouldReturn` Left (CleanupRunStoreCommitFailed "response lost")

data SurfaceCase where
  SurfaceCase
    :: CleanupSurfaceWitness surface
    -> Int
    -> [RegisteredResourceKey]
    -> SurfaceCase

data CapturedExecution = CapturedExecution
  { capturedNodeId :: !CleanupNodeId
  , capturedOperationId :: !CleanupOperationId
  , capturedOperationTag :: !Text
  , capturedAuthSubmissionKey :: !Text
  , capturedEksOperationIds :: ![Maybe CleanupOperationId]
  }
  deriving (Eq, Show)

newtype CaptureEffects value = CaptureEffects
  { runCaptureEffects :: (value, [CapturedExecution])
  }

instance Functor CaptureEffects where
  fmap function (CaptureEffects (value, captures)) =
    CaptureEffects (function value, captures)

instance Applicative CaptureEffects where
  pure value = CaptureEffects (value, [])
  CaptureEffects (function, firstCaptures)
    <*> CaptureEffects (value, secondCaptures) =
      CaptureEffects (function value, firstCaptures <> secondCaptures)

instance Monad CaptureEffects where
  CaptureEffects (value, firstCaptures) >>= continue =
    let CaptureEffects (result, secondCaptures) = continue value
     in CaptureEffects (result, firstCaptures <> secondCaptures)

instance LifecycleTeardownEffects CaptureEffects where
  executeLifecycleTeardownOperation context operation =
    CaptureEffects
      ( TeardownNodeRefused "fixture interpreter refusal"
      ,
        [ CapturedExecution
            { capturedNodeId = teardownExecutionNodeId context
            , capturedOperationId = teardownExecutionOperationId context
            , capturedOperationTag = teardownOperationTag operation
            , capturedAuthSubmissionKey =
                eksClientAuthTeardownExecutionSubmissionKey
                  (teardownExecutionIdentity context)
            , capturedEksOperationIds = case eksTargetForOperation operation of
                Nothing -> []
                Just target ->
                  [ teardownExecutionOperationIdFor
                      context
                      (CommitEksDrainIntent target)
                  , teardownExecutionOperationIdFor
                      context
                      (ReadBackEksDrainIntent target)
                  , teardownExecutionOperationIdFor
                      context
                      (DrainEksKubernetesResources target)
                  , teardownExecutionOperationIdFor
                      context
                      (ReadBackEksKubernetesDrain target)
                  ]
            }
        ]
      )

eksTargetForOperation
  :: TeardownOperation surface -> Maybe RegisteredTargetBinding
eksTargetForOperation operation = case operation of
  CommitEksDrainIntent target -> Just target
  ReadBackEksDrainIntent target -> Just target
  DrainEksKubernetesResources target -> Just target
  ReadBackEksKubernetesDrain target -> Just target
  _ -> Nothing

assertTopologicallyOrdered :: [ProgramNode surface] -> Expectation
assertTopologicallyOrdered nodes =
  forM_ (zip [(0 :: Int) ..] nodes) checkNode
 where
  positions = Map.fromList (zip (map programNodeName nodes) [(0 :: Int) ..])
  checkNode (nodeIndex, node) =
    forM_ (programNodeDependencies node) (checkDependency nodeIndex)
  checkDependency nodeIndex dependency =
    case Map.lookup (programDependencyNode dependency) positions of
      Nothing ->
        expectationFailure
          ( "dependency is absent from the rendered program: "
              ++ show (programDependencyNode dependency)
          )
      Just dependencyIndex ->
        dependencyIndex
          `shouldSatisfy` (< nodeIndex)

surfaceCases :: [SurfaceCase]
surfaceCases =
  [ SurfaceCase LocalOnlySurface 4 []
  , SurfaceCase CascadeSurface 47 perRunTargetKeys
  , SurfaceCase ExplicitPerRunSurface 42 perRunTargetKeys
  , SurfaceCase OperationalTeardownSurface 5 []
  , SurfaceCase ExplicitLongLivedSurface 8 [AwsEbsProductionRetainedKey]
  , SurfaceCase TotalDecommissionSurface 48 allManagedTargetKeys
  ]

nonLocalSurfaceCases :: [SurfaceCase]
nonLocalSurfaceCases = drop 1 surfaceCases

perRunTargetKeys :: [RegisteredResourceKey]
perRunTargetKeys =
  [ AwsEksKey
  , AwsEksSubzoneKey
  , AwsTestKey
  , AwsEbsPerRunTestKey
  ]

allManagedTargetKeys :: [RegisteredResourceKey]
allManagedTargetKeys = perRunTargetKeys ++ [AwsEbsProductionRetainedKey]

expectedOperationTags
  :: CleanupSurfaceWitness surface
  -> [RegisteredResourceKey]
  -> [Text]
expectedOperationTags surface targetKeys = case surface of
  LocalOnlySurface ->
    [ "uninstall-local-only-foundation"
    , "read-back-local-only-absence"
    , "commit-local-only-completion"
    , "read-back-local-only-completion"
    ]
  CascadeSurface ->
    recoveryTags
      ++ orderedTargetTags targetKeys
      ++ [ "observe-recovery-plane-disposition"
         , "audit-cascade-escapes"
         , "commit-cascade-pre-uninstall-report"
         , "read-back-cascade-pre-uninstall-report"
         , "uninstall-cascade-local-foundation"
         , "read-back-cascade-local-absence"
         , "commit-cascade-completion"
         , "read-back-cascade-completion"
         ]
  ExplicitPerRunSurface -> ordinaryTags targetKeys
  OperationalTeardownSurface -> ordinaryTags targetKeys
  ExplicitLongLivedSurface -> ordinaryTags targetKeys
  TotalDecommissionSurface ->
    orderedTargetTags targetKeys
      ++ [ "audit-total-decommission-escapes"
         , "observe-external-decommission-receipt"
         , "uninstall-decommission-local-foundation"
         , "read-back-decommission-local-absence"
         , "apply-decommission-local-data-disposition"
         , "read-back-decommission-local-data-disposition"
         , "commit-decommission-terminal-receipt"
         , "read-back-decommission-terminal-receipt"
         ]
 where
  recoveryTags = ["establish-recovery-plane", "read-back-recovery-plane"]
  ordinaryTags keys =
    recoveryTags
      ++ orderedTargetTags keys
      ++ [ "observe-recovery-plane-disposition"
         , "commit-ordinary-surface-report"
         , "read-back-ordinary-surface-report"
         ]

orderedTargetTags :: [RegisteredResourceKey] -> [Text]
orderedTargetTags keys =
  concatMap targetInitialTags keys ++ concatMap targetFinalTags keys

targetInitialTags :: RegisteredResourceKey -> [Text]
targetInitialTags key =
  let keyText = registeredResourceKeyText key
      registeredTags =
        [ "observe/" <> keyText
        , "reconcile-absent/" <> keyText
        , "read-back-absent/" <> keyText
        ]
   in if key == AwsEksKey
        then
          [ "observe-checkpoint-pair/" <> keyText
          , "observe/" <> keyText
          , "restore-checkpoint/" <> keyText
          , "read-back-checkpoint-recovery/" <> keyText
          , "commit-aws-stack-reader-bundle/" <> keyText
          , "read-back-aws-stack-reader-bundle/" <> keyText
          , "commit-eks-drain-intent/" <> keyText
          , "read-back-eks-drain-intent/" <> keyText
          , "drain-eks-kubernetes/" <> keyText
          , "read-back-eks-kubernetes-drain/" <> keyText
          ]
        else
          if key `elem` stackTargetKeys
            then
              [ "observe-checkpoint-pair/" <> keyText
              , "observe/" <> keyText
              , "restore-checkpoint/" <> keyText
              , "read-back-checkpoint-recovery/" <> keyText
              , "commit-aws-stack-reader-bundle/" <> keyText
              , "read-back-aws-stack-reader-bundle/" <> keyText
              , "reconcile-absent/" <> keyText
              , "read-back-absent/" <> keyText
              , "retire-checkpoint-pair/" <> keyText
              , "read-back-checkpoint-retirement/" <> keyText
              ]
            else registeredTags

targetFinalTags :: RegisteredResourceKey -> [Text]
targetFinalTags key
  | key == AwsEksKey =
      let keyText = registeredResourceKeyText key
       in [ "reconcile-absent/" <> keyText
          , "read-back-absent/" <> keyText
          , "retire-checkpoint-pair/" <> keyText
          , "read-back-checkpoint-retirement/" <> keyText
          ]
  | otherwise = []

expectedEffectCount
  :: CleanupSurfaceWitness surface -> [RegisteredResourceKey] -> Int
expectedEffectCount surface targetKeys = surfaceEffectCount + length targetKeys + checkpointEffects
 where
  checkpointEffects = 3 * length (stackTargetKeysFor targetKeys)
  eksDrainEffects = 2 * length (eksTargetKeysFor targetKeys)
  surfaceEffectCount =
    eksDrainEffects + case surface of
      LocalOnlySurface -> 2
      CascadeSurface -> 4
      ExplicitPerRunSurface -> 2
      OperationalTeardownSurface -> 2
      ExplicitLongLivedSurface -> 2
      TotalDecommissionSurface -> 3

registeredObservationKey
  :: TeardownOperation surface -> Maybe RegisteredResourceKey
registeredObservationKey operation = case operation of
  ObserveRegisteredTarget target -> Just (registeredTargetKey target)
  _ -> Nothing

registeredReconcileKey
  :: TeardownOperation surface -> Maybe RegisteredResourceKey
registeredReconcileKey operation = case operation of
  ReconcileRegisteredTargetAbsent target -> Just (registeredTargetKey target)
  _ -> Nothing

registeredReadBackKey
  :: TeardownOperation surface -> Maybe RegisteredResourceKey
registeredReadBackKey operation = case operation of
  ReadBackRegisteredTargetAbsent target -> Just (registeredTargetKey target)
  _ -> Nothing

checkpointObservationKey
  :: TeardownOperation surface -> Maybe RegisteredResourceKey
checkpointObservationKey operation = case operation of
  ObserveStackCheckpointPair target -> Just (registeredTargetKey target)
  _ -> Nothing

checkpointRestoreKey
  :: TeardownOperation surface -> Maybe RegisteredResourceKey
checkpointRestoreKey operation = case operation of
  ReconcileStackCheckpointRestore target -> Just (registeredTargetKey target)
  _ -> Nothing

checkpointRecoveryReadBackKey
  :: TeardownOperation surface -> Maybe RegisteredResourceKey
checkpointRecoveryReadBackKey operation = case operation of
  ReadBackStackCheckpointRecovery target -> Just (registeredTargetKey target)
  _ -> Nothing

awsStackReaderCommitKey
  :: TeardownOperation surface -> Maybe RegisteredResourceKey
awsStackReaderCommitKey operation = case operation of
  CommitAwsStackReaderBundle target -> Just (registeredTargetKey target)
  _ -> Nothing

awsStackReaderReadBackKey
  :: TeardownOperation surface -> Maybe RegisteredResourceKey
awsStackReaderReadBackKey operation = case operation of
  ReadBackAwsStackReaderBundle target -> Just (registeredTargetKey target)
  _ -> Nothing

eksDrainIntentCommitKey
  :: TeardownOperation surface -> Maybe RegisteredResourceKey
eksDrainIntentCommitKey operation = case operation of
  CommitEksDrainIntent target -> Just (registeredTargetKey target)
  _ -> Nothing

eksDrainIntentReadBackKey
  :: TeardownOperation surface -> Maybe RegisteredResourceKey
eksDrainIntentReadBackKey operation = case operation of
  ReadBackEksDrainIntent target -> Just (registeredTargetKey target)
  _ -> Nothing

eksDrainKey :: TeardownOperation surface -> Maybe RegisteredResourceKey
eksDrainKey operation = case operation of
  DrainEksKubernetesResources target -> Just (registeredTargetKey target)
  _ -> Nothing

eksDrainReadBackKey
  :: TeardownOperation surface -> Maybe RegisteredResourceKey
eksDrainReadBackKey operation = case operation of
  ReadBackEksKubernetesDrain target -> Just (registeredTargetKey target)
  _ -> Nothing

checkpointRetirementKey
  :: TeardownOperation surface -> Maybe RegisteredResourceKey
checkpointRetirementKey operation = case operation of
  RetireStackCheckpointPair target -> Just (registeredTargetKey target)
  _ -> Nothing

checkpointRetirementReadBackKey
  :: TeardownOperation surface -> Maybe RegisteredResourceKey
checkpointRetirementReadBackKey operation = case operation of
  ReadBackStackCheckpointRetirement target -> Just (registeredTargetKey target)
  _ -> Nothing

registeredBindingKind :: TeardownOperation surface -> Maybe ResourceKind
registeredBindingKind operation = case operation of
  ObserveRegisteredTarget target -> Just (registeredTargetKind target)
  ObserveStackCheckpointPair target -> Just (registeredTargetKind target)
  ReconcileStackCheckpointRestore target -> Just (registeredTargetKind target)
  ReadBackStackCheckpointRecovery target -> Just (registeredTargetKind target)
  CommitAwsStackReaderBundle target -> Just (registeredTargetKind target)
  ReadBackAwsStackReaderBundle target -> Just (registeredTargetKind target)
  CommitEksDrainIntent target -> Just (registeredTargetKind target)
  ReadBackEksDrainIntent target -> Just (registeredTargetKind target)
  DrainEksKubernetesResources target -> Just (registeredTargetKind target)
  ReadBackEksKubernetesDrain target -> Just (registeredTargetKind target)
  ReconcileRegisteredTargetAbsent target -> Just (registeredTargetKind target)
  ReadBackRegisteredTargetAbsent target -> Just (registeredTargetKind target)
  RetireStackCheckpointPair target -> Just (registeredTargetKind target)
  ReadBackStackCheckpointRetirement target -> Just (registeredTargetKind target)
  _ -> Nothing

confirmationTag :: TeardownOperation surface -> Maybe Text
confirmationTag operation = case operation of
  EstablishRecoveryPlane _ -> Just "read-back-recovery-plane"
  ReconcileRegisteredTargetAbsent target ->
    Just ("read-back-absent/" <> registeredResourceKeyText (registeredTargetKey target))
  ReconcileStackCheckpointRestore target ->
    Just
      ( "read-back-checkpoint-recovery/"
          <> registeredResourceKeyText (registeredTargetKey target)
      )
  CommitAwsStackReaderBundle target ->
    Just
      ( "read-back-aws-stack-reader-bundle/"
          <> registeredResourceKeyText (registeredTargetKey target)
      )
  CommitEksDrainIntent target ->
    Just
      ( "read-back-eks-drain-intent/"
          <> registeredResourceKeyText (registeredTargetKey target)
      )
  DrainEksKubernetesResources target ->
    Just
      ( "read-back-eks-kubernetes-drain/"
          <> registeredResourceKeyText (registeredTargetKey target)
      )
  RetireStackCheckpointPair target ->
    Just
      ( "read-back-checkpoint-retirement/"
          <> registeredResourceKeyText (registeredTargetKey target)
      )
  CommitCascadePreUninstallReport -> Just "read-back-cascade-pre-uninstall-report"
  UninstallCascadeLocalFoundation -> Just "read-back-cascade-local-absence"
  CommitCascadeCompletion -> Just "read-back-cascade-completion"
  UninstallLocalOnlyFoundation -> Just "read-back-local-only-absence"
  CommitLocalOnlyCompletion -> Just "read-back-local-only-completion"
  CommitOrdinarySurfaceReport -> Just "read-back-ordinary-surface-report"
  UninstallDecommissionLocalFoundation -> Just "read-back-decommission-local-absence"
  ApplyDecommissionLocalDataDisposition ->
    Just "read-back-decommission-local-data-disposition"
  CommitDecommissionTerminalReceipt -> Just "read-back-decommission-terminal-receipt"
  _ -> Nothing

isMandatoryReadBack :: TeardownOperation surface -> Bool
isMandatoryReadBack operation = case operation of
  ReadBackRecoveryPlane _ -> True
  ReadBackRegisteredTargetAbsent _ -> True
  ReadBackStackCheckpointRecovery _ -> True
  ReadBackAwsStackReaderBundle _ -> True
  ReadBackEksDrainIntent _ -> True
  ReadBackEksKubernetesDrain _ -> True
  ReadBackStackCheckpointRetirement _ -> True
  ReadBackCascadePreUninstallReport -> True
  ReadBackCascadeLocalAbsence -> True
  ReadBackCascadeCompletion -> True
  ReadBackLocalOnlyAbsence -> True
  ReadBackLocalOnlyCompletion -> True
  ReadBackOrdinarySurfaceReport -> True
  ReadBackDecommissionLocalAbsence -> True
  ReadBackDecommissionLocalDataDisposition -> True
  ReadBackDecommissionTerminalReceipt -> True
  _ -> False

stackTargetKeys :: [RegisteredResourceKey]
stackTargetKeys = [AwsEksKey, AwsEksSubzoneKey, AwsTestKey]

stackTargetKeysFor :: [RegisteredResourceKey] -> [RegisteredResourceKey]
stackTargetKeysFor = filter (`elem` stackTargetKeys)

eksTargetKeysFor :: [RegisteredResourceKey] -> [RegisteredResourceKey]
eksTargetKeysFor = filter (== AwsEksKey)

nodesWithTag :: Text -> [ProgramNode surface] -> [ProgramNode surface]
nodesWithTag tag =
  filter ((== tag) . teardownOperationTag . programNodeOperation)

assertProgramDependencies
  :: DesiredAbsenceProgram surface
  -> Text
  -> [(Text, CleanupDependencyKind)]
  -> Expectation
assertProgramDependencies program operationTag expected =
  case nodesWithTag operationTag (desiredAbsenceProgramNodes program) of
    [node] ->
      map renderDependency (programNodeDependencies node) `shouldBe` expected
    matches ->
      expectationFailure
        ( "expected exactly one operation "
            ++ Text.unpack operationTag
            ++ ", observed "
            ++ show (length matches)
        )
 where
  renderDependency dependency =
    ( programNodeNameText (programDependencyNode dependency)
    , programDependencyKind dependency
    )

awsScopeFor :: CleanupSurfaceWitness surface -> Maybe AwsScope
awsScopeFor surface = case surface of
  LocalOnlySurface -> Nothing
  CascadeSurface -> Just fixtureAwsScope
  ExplicitPerRunSurface -> Just fixtureAwsScope
  OperationalTeardownSurface -> Just fixtureAwsScope
  ExplicitLongLivedSurface -> Just fixtureAwsScope
  TotalDecommissionSurface -> Just fixtureAwsScope

compileGraph
  :: CleanupRunId
  -> CleanupSurfaceWitness surface
  -> Either DesiredAbsenceGraphError (CompiledDesiredAbsenceProgram surface)
compileGraph runId surface =
  compileGraphWith runId fixtureFoundation (awsScopeFor surface) surface

compileGraphWith
  :: CleanupRunId
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> CleanupSurfaceWitness surface
  -> Either DesiredAbsenceGraphError (CompiledDesiredAbsenceProgram surface)
compileGraphWith = compileDesiredAbsenceGraph

lowerDependency :: ProgramDependency -> CleanupDependency
lowerDependency dependency =
  CleanupDependency
    { cleanupDependencyNode = nodeIdForName (programDependencyNode dependency)
    , cleanupDependencyKind = programDependencyKind dependency
    }

nodeIdForName :: ProgramNodeName -> CleanupNodeId
nodeIdForName (ProgramNodeName name) = mustRight (mkCleanupNodeId ("lifecycle/" <> name))

graphNodeStableShape
  :: CleanupNodePlan
  -> (CleanupNodeId, Text, [CleanupDependency])
graphNodeStableShape node =
  ( cleanupNodeId node
  , cleanupNodeCapabilityDigest node
  , cleanupNodeDependencies node
  )

isSha256 :: Text -> Bool
isSha256 digest =
  Text.length digest == 64
    && Text.all (`elem` ("0123456789abcdef" :: String)) digest

expectReportRegression :: IO DesiredAbsenceReportRegression
expectReportRegression = case fixedDesiredAbsenceReportRegression of
  Left err -> do
    expectationFailure (Text.unpack err)
    error "unreachable"
  Right regression -> pure regression

moduleHeader :: String -> String
moduleHeader = unlines . takeWhile (/= "where") . lines

sourceImporters :: FilePath -> String -> IO [FilePath]
sourceImporters root importNeedle = do
  paths <- sourceFiles root
  sort <$> filterM containsImport paths
 where
  containsImport path = do
    contents <- readFile path
    pure (importNeedle `isInfixOf` contents)

sourceFiles :: FilePath -> IO [FilePath]
sourceFiles path = do
  directory <- doesDirectoryExist path
  if directory
    then do
      children <- listDirectory path
      concat <$> mapM (sourceFiles . (path </>)) children
    else pure [path | ".hs" `isSuffixOf` path]

expectProgram
  :: CleanupSurfaceWitness surface
  -> IO (DesiredAbsenceProgram surface)
expectProgram surface = case compileDesiredAbsenceProgram surface of
  Left err -> do
    expectationFailure (show err)
    error "unreachable"
  Right program -> pure program

expectGraph
  :: CleanupRunId
  -> CleanupSurfaceWitness surface
  -> IO (CompiledDesiredAbsenceProgram surface)
expectGraph runId surface = case compileGraph runId surface of
  Left err -> do
    expectationFailure (show err)
    error "unreachable"
  Right compiled -> pure compiled

expectGraphWith
  :: CleanupRunId
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> CleanupSurfaceWitness surface
  -> IO (CompiledDesiredAbsenceProgram surface)
expectGraphWith runId foundation awsScope surface =
  case compileGraphWith runId foundation awsScope surface of
    Left err -> do
      expectationFailure (show err)
      error "unreachable"
    Right compiled -> pure compiled

expectPlanWithTag
  :: CompiledDesiredAbsenceProgram surface
  -> Text
  -> IO CleanupNodePlan
expectPlanWithTag compiled tag =
  case [ plan
       | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
       , Just operation <- [compiledOperationForNode (cleanupNodeId plan) compiled]
       , teardownOperationTag operation == tag
       ] of
    [plan] -> pure plan
    matches -> do
      expectationFailure
        ( "expected one cleanup plan tagged "
            ++ Text.unpack tag
            ++ ", observed "
            ++ show (length matches)
        )
      error "unreachable"

expectFreshRun
  :: CompiledDesiredAbsenceProgram surface -> IO CleanupRun
expectFreshRun compiled =
  case newCleanupRun
    (compiledDesiredAbsenceRunId compiled)
    (compiledDesiredAbsenceGraph compiled)
    fixtureOwner
    0
    1000000 of
    Left err -> do
      expectationFailure (show err)
      error "unreachable"
    Right run -> pure run

fixtureRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "lifecycle-teardown-run-1")

fixtureOtherRunId :: CleanupRunId
fixtureOtherRunId = mustRight (mkCleanupRunId "lifecycle-teardown-run-2")

fixtureOwner :: CleanupOwnerId
fixtureOwner = mustRight (mkCleanupOwnerId "lifecycle-authority-owner")

fixtureFoundation :: LinuxRke2FoundationId
fixtureFoundation = LinuxRke2FoundationId "home-linux-rke2"

fixtureAwsScope :: AwsScope
fixtureAwsScope =
  AwsScope
    (AwsAccountId "111122223333")
    (AwsRegion "ca-central-1")

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
