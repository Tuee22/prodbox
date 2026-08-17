{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownEksDrainAttemptRecovery
  ( lifecycleTeardownEksDrainAttemptRecoverySuite
  )
where

import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import EksClientAuthProjectionFixture (testEksClientAuthProjection)
import Prodbox.ControlPlane.CleanupRunClient
import Prodbox.ControlPlane.CleanupRunEndpoint (CleanupRunCommand (..))
import Prodbox.ControlPlane.EksClientAuthProjection (EksClientAuthProjection)
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (ProviderIntentExecutionObserved)
  )
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupNodeExecutionContext
  , resumeDurableCleanupWithContext
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (providerIntentCoordinate)
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
import Prodbox.Lifecycle.Teardown.EksDrainAttemptRecovery
import Prodbox.Lifecycle.Teardown.EksDrainIntent
import Prodbox.Lifecycle.Teardown.EksDrainSession
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownEksDrainAttemptRecoverySuite :: SuiteBuilder ()
lifecycleTeardownEksDrainAttemptRecoverySuite =
  describe "Sprint 7.36 EKS drain attempt crash recovery" $ do
    it "reconstructs applied only from a successful exact-target durable attempt" $ do
      recovered <- runRecoveryCase exactFixture CleanupNodeSucceeded eksDrainReadBackPlan
      evidence <- expectRecovered recovered
      eksDrainAttemptOutcome evidence `shouldBe` EksDrainMutationApplied
      eksDrainAttemptEvidenceAttemptId evidence `shouldBe` predecessorAttempt

    it "downgrades a collapsed failed node to unobservable, never definite failure" $ do
      recovered <-
        runRecoveryCase
          exactFixture
          (CleanupNodeFailed "result binding rejected")
          eksDrainReadBackPlan
      evidence <- expectRecovered recovered
      eksDrainAttemptOutcome evidence `shouldSatisfy` isUnobservable
      eksDrainAttemptOutcome evidence `shouldSatisfy` isNotDefiniteFailure

    it "retains an effect-unconfirmed node only as unobservable" $ do
      recovered <-
        runRecoveryCase
          exactFixture
          (CleanupNodeEffectUnconfirmed "transport response lost")
          eksDrainReadBackPlan
      evidence <- expectRecovered recovered
      eksDrainAttemptOutcome evidence `shouldSatisfy` isUnobservable

    it "reconstructs no-target as skipped without rewriting its durable predecessor outcome" $ do
      mapM_
        ( \outcome -> do
            (recovered, finalRun) <-
              runRecoveryCaseWithRun noTargetFixture outcome eksDrainReadBackPlan
            evidence <- expectRecovered recovered
            eksDrainAttemptOutcome evidence `shouldBe` EksDrainSkippedNoKubernetesTarget
            Map.lookup fixtureEffectNodeId (cleanupRunNodeStates finalRun)
              `shouldBe` Just (CleanupNodeCompleted predecessorAttempt outcome)
        )
        [ CleanupNodeSucceeded
        , CleanupNodeFailed "effect result rejected"
        , CleanupNodeEffectUnconfirmed "effect response lost"
        ]

    it "refuses a registered target different from the durable drain predecessor" $ do
      recovered <-
        runRecoveryCase
          exactFixture {recoveryExpectedTarget = fixtureAwsTestTarget}
          CleanupNodeSucceeded
          eksDrainReadBackPlan
      recovered `shouldSatisfy` isTargetMismatch

    it "refuses an effect operation different from the authoritative predecessor" $ do
      recovered <-
        runRecoveryCase
          exactFixture {recoveryExpectedEffectOperation = fixtureOtherOperation}
          CleanupNodeSucceeded
          eksDrainReadBackPlan
      recovered `shouldSatisfy` isPredecessorOperationIdMismatch

    it "refuses committed scope, run, graph, effect, and read-back mismatches" $ do
      let mismatches =
            [ (scopeMismatchFixture, isScopeMismatch)
            , (runMismatchFixture, isRunMismatch)
            , (graphMismatchFixture, isGraphMismatch)
            , (effectMismatchFixture, isEffectMismatch)
            , (readBackMismatchFixture, isReadBackMismatch)
            ]
      mapM_
        ( \(fixture, predicate) -> do
            recovered <- runRecoveryCase fixture CleanupNodeSucceeded eksDrainReadBackPlan
            recovered `shouldSatisfy` predicate
        )
        mismatches

    it "refuses a direct attempted predecessor of the wrong operation kind" $ do
      recovered <- runRecoveryCase exactFixture CleanupNodeSucceeded eksDrainEffectPlan
      recovered `shouldSatisfy` isPredecessorOperationInvalid

    it "refuses missing attempted receipts and never treats terminal receipts as attempts" $ do
      missing <- runRecoveryCase exactFixture CleanupNodeSucceeded targetObservePlan
      missing `shouldSatisfy` isPredecessorMissing
      terminalOnly <-
        runRecoveryCase exactFixture CleanupNodeSucceeded recoveryDispositionPlan
      terminalOnly `shouldSatisfy` isPredecessorMissing

data RecoveryFixture = RecoveryFixture
  { recoveryExpectedTarget :: !RegisteredTargetBinding
  , recoveryExpectedEffectOperation :: !CleanupOperationId
  , recoveryCommittedIntent :: !CommittedEksDrainIntent
  }

data RecoveryEnvironment = RecoveryEnvironment
  { recoveryFixture :: !RecoveryFixture
  , recoveryCaptured
      :: !( IORef
              ( Maybe
                  ( Either
                      EksDrainAttemptRecoveryError
                      EksDrainAttemptEvidence
                  )
              )
          )
  }

newtype RecoveryEffects value = RecoveryEffects
  { runRecoveryEffects :: RecoveryEnvironment -> IO value
  }

instance Functor RecoveryEffects where
  fmap function (RecoveryEffects action) =
    RecoveryEffects (fmap function . action)

instance Applicative RecoveryEffects where
  pure value = RecoveryEffects (const (pure value))
  RecoveryEffects function <*> RecoveryEffects action =
    RecoveryEffects $ \environment ->
      function environment <*> action environment

instance Monad RecoveryEffects where
  RecoveryEffects action >>= continue =
    RecoveryEffects $ \environment -> do
      value <- action environment
      runRecoveryEffects (continue value) environment

instance LifecycleTeardownEffects RecoveryEffects where
  executeLifecycleTeardownOperation context _operation =
    RecoveryEffects $ \environment -> do
      let fixture = recoveryFixture environment
          recovered =
            recoverEksDrainAttemptEvidence
              (recoveryExpectedTarget fixture)
              (recoveryExpectedEffectOperation fixture)
              context
              (recoveryCommittedIntent fixture)
      writeIORef (recoveryCaptured environment) (Just recovered)
      pure
        ( TeardownMutationAttempt
            (TeardownMutationRefused "recovery result captured")
        )

runRecoveryCase
  :: RecoveryFixture
  -> CleanupNodeOutcome
  -> (TeardownOperation 'Cascade -> Bool)
  -> IO
       ( Either
           EksDrainAttemptRecoveryError
           EksDrainAttemptEvidence
       )
runRecoveryCase fixture predecessorOutcome selectPending = do
  (recovered, _) <-
    runRecoveryCaseWithRun fixture predecessorOutcome selectPending
  pure recovered

runRecoveryCaseWithRun
  :: RecoveryFixture
  -> CleanupNodeOutcome
  -> (TeardownOperation 'Cascade -> Bool)
  -> IO
       ( Either
           EksDrainAttemptRecoveryError
           EksDrainAttemptEvidence
       , CleanupRun
       )
runRecoveryCaseWithRun fixture predecessorOutcome selectPending = do
  let pendingPlan = uniquePlan selectPending
      dependencyNodes = map cleanupDependencyNode (cleanupNodeDependencies pendingPlan)
      run = fixtureRun pendingPlan dependencyNodes predecessorOutcome
  stored <- newIORef run
  captured <- newIORef Nothing
  let environment = RecoveryEnvironment fixture captured
  resumed <-
    resumeDurableCleanupWithContext
      (memoryCleanupRunClient stored)
      fixtureOwner
      (runCapturedNode environment)
      run
  case resumed of
    Left err -> expectationFailure (show err)
    Right _ -> pure ()
  observed <- readIORef captured
  finalRun <- readIORef stored
  case observed of
    Nothing -> expectationFailure "recovery effect was not invoked" >> fail "missing recovery result"
    Just recovered -> pure (recovered, finalRun)

runCapturedNode
  :: RecoveryEnvironment
  -> CleanupNodeExecutionContext
  -> CleanupNodePlan
  -> IO CleanupNodeOutcome
runCapturedNode environment execution plan =
  runRecoveryEffects
    (runCompiledTeardownNodeWithContext fixtureCompiled execution plan)
    environment

fixtureRun
  :: CleanupNodePlan
  -> [CleanupNodeId]
  -> CleanupNodeOutcome
  -> CleanupRun
fixtureRun pendingPlan dependencyNodes predecessorOutcome =
  CleanupRun
    { cleanupRunId = fixtureRunId
    , cleanupRunGraphDigest = cleanupGraphDigest graph
    , cleanupRunGraph = graph
    , cleanupRunLease = CleanupLease fixtureOwner 1 1_000_000
    , cleanupRunPrimaryOutcome = Just CleanupPrimarySucceeded
    , cleanupRunNodeStates =
        Map.fromList
          [ ( cleanupNodeId plan
            , if cleanupNodeId plan == cleanupNodeId pendingPlan
                then CleanupNodePending
                else
                  CleanupNodeCompleted
                    predecessorAttempt
                    ( if cleanupNodeId plan `elem` dependencyNodes
                        then predecessorOutcome
                        else CleanupNodeSucceeded
                    )
            )
          | plan <- cleanupGraphNodes graph
          ]
    }
 where
  graph = compiledDesiredAbsenceGraph fixtureCompiled

memoryCleanupRunClient :: IORef CleanupRun -> CleanupRunClient IO
memoryCleanupRunClient stored =
  CleanupRunClient
    { executeCleanupRunCommand = execute
    , scanNonterminalCleanupRuns = pure (Right [])
    , compactTerminalCleanupRun = \_ _ _ ->
        pure (Left (clientFailure "unexpected compact request"))
    }
 where
  execute command = do
    current <- readIORef stored
    transitioned <- case command of
      CleanupRunBeginNode rawRun rawOwner fence rawNode rawAttempt ->
        applyTransition rawRun rawOwner $ \owner ->
          pure $ do
            node <- mapIdentity (mkCleanupNodeId rawNode)
            attempt <- mapIdentity (mkCleanupAttemptId rawAttempt)
            mapTransition (beginCleanupNode owner fence node attempt current)
      CleanupRunCompleteNode rawRun rawOwner fence rawNode rawAttempt outcome ->
        applyTransition rawRun rawOwner $ \owner ->
          pure $ do
            node <- mapIdentity (mkCleanupNodeId rawNode)
            attempt <- mapIdentity (mkCleanupAttemptId rawAttempt)
            mapTransition
              (completeCleanupNode owner fence node attempt outcome current)
      _ -> pure (Left (clientFailure "unexpected cleanup command"))
    case transitioned of
      Left err -> pure (Left err)
      Right updated -> do
        writeIORef stored updated
        pure (Right (Just updated))
   where
    applyTransition rawRun rawOwner transition
      | rawRun /= cleanupRunIdText fixtureRunId =
          pure (Left (clientFailure "cleanup run mismatch"))
      | otherwise = case mkCleanupOwnerId rawOwner of
          Left detail -> pure (Left (clientFailure detail))
          Right owner -> transition owner
    mapIdentity = either (Left . clientFailure) Right
    mapTransition = either (Left . clientFailure . Text.pack . show) Right

clientFailure :: Text -> CleanupRunClientError
clientFailure = CleanupRunClientHttpStatus 500

uniquePlan
  :: (TeardownOperation 'Cascade -> Bool)
  -> CleanupNodePlan
uniquePlan predicate =
  case [ plan
       | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph fixtureCompiled)
       , Just operation <- [compiledOperationForNode (cleanupNodeId plan) fixtureCompiled]
       , predicate operation
       ] of
    [plan] -> plan
    plans -> error ("expected one fixture plan, observed " <> show (length plans))

eksDrainReadBackPlan :: TeardownOperation 'Cascade -> Bool
eksDrainReadBackPlan operation = case operation of
  ReadBackEksKubernetesDrain target -> target == fixtureAwsEksTarget
  _ -> False

eksDrainEffectPlan :: TeardownOperation 'Cascade -> Bool
eksDrainEffectPlan operation = case operation of
  DrainEksKubernetesResources target -> target == fixtureAwsEksTarget
  _ -> False

targetObservePlan :: TeardownOperation 'Cascade -> Bool
targetObservePlan operation = case operation of
  ObserveRegisteredTarget target -> target == fixtureAwsEksTarget
  _ -> False

recoveryDispositionPlan :: TeardownOperation 'Cascade -> Bool
recoveryDispositionPlan operation = case operation of
  ObserveRecoveryPlaneDisposition CascadeRecoverySurface -> True
  _ -> False

exactFixture :: RecoveryFixture
exactFixture =
  RecoveryFixture
    { recoveryExpectedTarget = fixtureAwsEksTarget
    , recoveryExpectedEffectOperation = fixtureEffectOperation
    , recoveryCommittedIntent = fixtureExactCommitted
    }

noTargetFixture :: RecoveryFixture
noTargetFixture =
  exactFixture {recoveryCommittedIntent = committedNoTarget fixtureBinding}

scopeMismatchFixture :: RecoveryFixture
scopeMismatchFixture =
  exactFixture
    { recoveryCommittedIntent =
        committedNoTarget
          ( bindingFor
              fixtureOtherScope
              fixtureRunId
              fixtureGraphDigest
              fixtureEffectOperation
              fixtureReadBackOperation
          )
    }

runMismatchFixture :: RecoveryFixture
runMismatchFixture =
  exactFixture
    { recoveryCommittedIntent =
        committedNoTarget
          ( bindingFor
              fixtureOtherRunScope
              fixtureOtherRunId
              fixtureGraphDigest
              fixtureEffectOperation
              fixtureReadBackOperation
          )
    }

graphMismatchFixture :: RecoveryFixture
graphMismatchFixture =
  exactFixture
    { recoveryCommittedIntent =
        committedNoTarget
          ( bindingFor
              fixtureScope
              fixtureRunId
              fixtureOtherGraph
              fixtureEffectOperation
              fixtureReadBackOperation
          )
    }

effectMismatchFixture :: RecoveryFixture
effectMismatchFixture =
  exactFixture
    { recoveryCommittedIntent =
        committedNoTarget
          ( bindingFor
              fixtureScope
              fixtureRunId
              fixtureGraphDigest
              fixtureOtherOperation
              fixtureReadBackOperation
          )
    }

readBackMismatchFixture :: RecoveryFixture
readBackMismatchFixture =
  exactFixture
    { recoveryCommittedIntent =
        committedNoTarget
          (bindingFor fixtureScope fixtureRunId fixtureGraphDigest fixtureEffectOperation fixtureOtherOperation)
    }

fixtureExactCommitted :: CommittedEksDrainIntent
fixtureExactCommitted =
  committed
    ( mustRight
        ( prepareEksKubernetesDrainIntent
            fixtureBinding
            fixtureSession
            ( eksDrainTargetSelectionObservationFor
                fixtureSession
                (ObservationRevision 41)
                (EksDrainTargetSelectionComplete [fixturePvc])
            )
        )
    )

fixtureSession :: EksDrainSession
fixtureSession =
  mustRight
    ( mkEksDrainSession
        1_000
        1_500
        fixtureEffectOperation
        fixtureScope
        (verifiedEks fixtureScope (ObservationRevision 13) ("eks-cluster-arn:" <> fixtureArn))
        ( eksKubernetesIdentityObservationFor
            fixtureScope
            (ObservationRevision 14)
            fixtureArn
            (EksKubernetesIdentityPresent fixtureUid)
            fixtureProjection
        )
        fixtureProjection
    )

committedNoTarget :: EksDrainOperationBinding -> CommittedEksDrainIntent
committedNoTarget binding =
  committed
    ( mustRight
        ( prepareEksNoKubernetesTargetIntent
            binding
            ( verifiedEks
                (eksDrainBindingScope binding)
                (ObservationRevision 13)
                "registered EKS cluster is absent"
            )
        )
    )

committed :: EksDrainIntent -> CommittedEksDrainIntent
committed intent =
  mustRight
    ( confirmEksDrainIntentCommitted
        intent
        (EksDrainIntentReadBackPresent (encodeEksDrainIntent intent))
    )

verifiedEks
  :: ObservationEvidenceScope
  -> ObservationRevision
  -> Text
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
verifiedEks scope revision evidence =
  let request = mustRight (mkAwsEksDecisionObservationRequest revision scope)
   in case decodeAwsEksObservation
        request
        ( Right
            ( ProviderIntentExecutionObserved
                (providerIntentCoordinate (awsEksObservationRequestProviderIntent request))
                evidence
            )
        ) of
        AwsEksObservationDecoded verified -> verified
        AwsEksObservationRejected err _ -> error (show err)

bindingFor
  :: ObservationEvidenceScope
  -> CleanupRunId
  -> CleanupDigest
  -> CleanupOperationId
  -> CleanupOperationId
  -> EksDrainOperationBinding
bindingFor scope runId graph effectOperation readBackOperation =
  mustRight
    ( mkEksDrainOperationBinding
        scope
        runId
        graph
        fixtureCommitOperation
        fixtureIntentReadBackOperation
        effectOperation
        readBackOperation
    )

fixtureBinding :: EksDrainOperationBinding
fixtureBinding =
  bindingFor
    fixtureScope
    fixtureRunId
    fixtureGraphDigest
    fixtureEffectOperation
    fixtureReadBackOperation

fixtureCompiled :: CompiledDesiredAbsenceProgram 'Cascade
fixtureCompiled =
  mustRight
    ( compileDesiredAbsenceGraph
        fixtureRunId
        fixtureFoundation
        (Just fixtureAwsScope)
        CascadeSurface
    )

fixtureAwsEksTarget, fixtureAwsTestTarget :: RegisteredTargetBinding
fixtureAwsEksTarget = targetForKey AwsEksKey
fixtureAwsTestTarget = targetForKey AwsTestKey

targetForKey :: RegisteredResourceKey -> RegisteredTargetBinding
targetForKey key =
  case [ target
       | (_, operation) <- compiledDesiredAbsenceOperations fixtureCompiled
       , ObserveRegisteredTarget target <- [operation]
       , registeredTargetKey target == key
       ] of
    [target] -> target
    targets -> error ("expected one target for key, observed " <> show (length targets))

fixtureCommitOperation
  , fixtureIntentReadBackOperation
  , fixtureEffectOperation
  , fixtureReadBackOperation
    :: CleanupOperationId
fixtureCommitOperation =
  operationIdFor isFixtureEksDrainIntentCommit
fixtureIntentReadBackOperation =
  operationIdFor isFixtureEksDrainIntentReadBack
fixtureEffectOperation = operationIdFor eksDrainEffectPlan
fixtureReadBackOperation = operationIdFor eksDrainReadBackPlan

isFixtureEksDrainIntentCommit :: TeardownOperation 'Cascade -> Bool
isFixtureEksDrainIntentCommit operation = case operation of
  CommitEksDrainIntent target -> target == fixtureAwsEksTarget
  _ -> False

isFixtureEksDrainIntentReadBack :: TeardownOperation 'Cascade -> Bool
isFixtureEksDrainIntentReadBack operation = case operation of
  ReadBackEksDrainIntent target -> target == fixtureAwsEksTarget
  _ -> False

fixtureEffectNodeId :: CleanupNodeId
fixtureEffectNodeId = cleanupNodeId (uniquePlan eksDrainEffectPlan)

operationIdFor :: (TeardownOperation 'Cascade -> Bool) -> CleanupOperationId
operationIdFor predicate = cleanupNodeOperationId (uniquePlan predicate)

fixtureRunId, fixtureOtherRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "cleanup-run/eks-drain-attempt-recovery")
fixtureOtherRunId = mustRight (mkCleanupRunId "cleanup-run/eks-drain-attempt-other")

fixtureGraphDigest, fixtureOtherGraph :: CleanupDigest
fixtureGraphDigest = cleanupGraphDigest (compiledDesiredAbsenceGraph fixtureCompiled)
fixtureOtherGraph = mustRight (mkCleanupDigest (Text.replicate 64 "b"))

fixtureScope, fixtureOtherScope, fixtureOtherRunScope :: ObservationEvidenceScope
fixtureScope = compiledDesiredAbsenceObservationScope fixtureCompiled
fixtureOtherScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope (cleanupRunIdText fixtureRunId))
    (LinuxRke2FoundationId "other-linux-rke2")
    (Just fixtureAwsScope)
    ReconcileDesiredAbsent
fixtureOtherRunScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope (cleanupRunIdText fixtureOtherRunId))
    fixtureFoundation
    (Just fixtureAwsScope)
    ReconcileDesiredAbsent

fixtureAwsScope :: AwsScope
fixtureAwsScope = AwsScope (AwsAccountId "123456789012") (AwsRegion "us-east-1")

fixtureFoundation :: LinuxRke2FoundationId
fixtureFoundation = LinuxRke2FoundationId "home-linux-rke2"

fixtureOwner :: CleanupOwnerId
fixtureOwner = mustRight (mkCleanupOwnerId "owner/eks-drain-attempt-recovery")

predecessorAttempt :: CleanupAttemptId
predecessorAttempt = mustRight (mkCleanupAttemptId "attempt/eks-drain-effect")

fixtureOtherOperation :: CleanupOperationId
fixtureOtherOperation = mustRight (mkCleanupOperationId "operation/other")

fixtureProjection :: EksClientAuthProjection
fixtureProjection =
  mustRight
    ( testEksClientAuthProjection
        "123456789012"
        "us-east-1"
        "aws-eks-test-cluster"
        fixtureArn
        "https://example.eks.amazonaws.com"
        "Y2EtZGF0YQ=="
        "bearer-secret"
        1_800
    )

fixtureArn, fixtureUid :: Text
fixtureArn =
  "arn:aws:eks:us-east-1:123456789012:cluster/aws-eks-test-cluster"
fixtureUid = "eks-kube-system-uid-recovery"

fixturePvc :: EksNamespacedName
fixturePvc = mustRight (mkEksNamespacedName "api" "api-data")

expectRecovered
  :: Either EksDrainAttemptRecoveryError EksDrainAttemptEvidence
  -> IO EksDrainAttemptEvidence
expectRecovered result = case result of
  Left err -> expectationFailure (show err) >> fail "expected recovered attempt"
  Right evidence -> pure evidence

isUnobservable :: EksDrainAttemptOutcome -> Bool
isUnobservable outcome = case outcome of
  EksDrainMutationUnobservable _ -> True
  _ -> False

isNotDefiniteFailure :: EksDrainAttemptOutcome -> Bool
isNotDefiniteFailure outcome = case outcome of
  EksDrainMutationFailed _ -> False
  _ -> True

isTargetMismatch
  , isPredecessorOperationIdMismatch
  , isScopeMismatch
  , isRunMismatch
  , isGraphMismatch
  , isEffectMismatch
  , isReadBackMismatch
  , isPredecessorOperationInvalid
  , isPredecessorMissing
    :: Either EksDrainAttemptRecoveryError value -> Bool
isTargetMismatch result = case result of
  Left EksDrainAttemptRecoveryPredecessorTargetMismatch {} -> True
  _ -> False
isPredecessorOperationIdMismatch result = case result of
  Left EksDrainAttemptRecoveryPredecessorOperationIdMismatch {} -> True
  _ -> False
isScopeMismatch result = case result of
  Left EksDrainAttemptRecoveryScopeMismatch {} -> True
  _ -> False
isRunMismatch result = case result of
  Left EksDrainAttemptRecoveryRunMismatch {} -> True
  _ -> False
isGraphMismatch result = case result of
  Left EksDrainAttemptRecoveryGraphMismatch {} -> True
  _ -> False
isEffectMismatch result = case result of
  Left EksDrainAttemptRecoveryEffectOperationMismatch {} -> True
  _ -> False
isReadBackMismatch result = case result of
  Left EksDrainAttemptRecoveryReadBackOperationIdMismatch {} -> True
  _ -> False
isPredecessorOperationInvalid result = case result of
  Left EksDrainAttemptRecoveryPredecessorOperationInvalid -> True
  _ -> False
isPredecessorMissing result = case result of
  Left EksDrainAttemptRecoveryPredecessorMissing -> True
  _ -> False

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
