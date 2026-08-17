{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownEksDrainInterpreter
  ( lifecycleTeardownEksDrainInterpreterSuite
  )
where

import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import EksClientAuthProjectionFixture (testEksClientAuthProjection)
import Prodbox.ControlPlane.EksClientAuthProjection
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (ProviderIntentExecutionObserved)
  )
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderRevision
  , mkProviderRevision
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
import Prodbox.Lifecycle.Teardown.AwsEksDestroyAdapter
import Prodbox.Lifecycle.Teardown.Decision
import Prodbox.Lifecycle.Teardown.EksDrainIntent
import Prodbox.Lifecycle.Teardown.EksDrainInterpreter
import Prodbox.Lifecycle.Teardown.EksDrainSession
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.ExecutionIdentity
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.ProviderDispatch
  ( ProviderDispatchPurpose (ProviderDecisionObservation)
  , mkProviderDispatchKey
  , observationRevisionForProviderDispatchKey
  )
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownEksDrainInterpreterSuite :: SuiteBuilder ()
lifecycleTeardownEksDrainInterpreterSuite =
  describe "Sprint 7.36 exact EKS drain interpreter" $ do
    it "mints selection only after complete UID, Service, Ingress, and Delete-policy PVC queries" $ do
      (interpreter, cluster, calls) <- fixtureInterpreter
      selected <-
        observeVerifiedEksDrainSelection
          interpreter
          fixtureBinding
          (ObservationRevision 41)
          fixtureEffectSession
      verified <- case selected of
        Left observation -> expectationFailure (show observation) >> fail "selection refused"
        Right value -> pure value
      let intent = mustRight (prepareEksDrainIntentFromVerifiedSelection verified)
      case eksDrainIntentTarget intent of
        EksDrainExactKubernetesTarget {eksDrainTargetDeletePolicyPvcs = pvcs} ->
          pvcs `shouldBe` [fixturePvcA, fixturePvcB]
        target -> expectationFailure ("unexpected target: " <> show target)
      readIORef calls
        `shouldReturnListContain` [ FakeOpenClient drainEffectOperation
                                  , FakeObserveUid
                                  , FakeObserveServices
                                  , FakeObserveIngresses
                                  , FakeObserveDeletePolicyPvcs
                                  ]
      modifyIORef'
        cluster
        ( \state ->
            state
              { fakeServiceInventory =
                  EksDrainInventoryPartial
                    []
                    (ObservationFailure "service list truncated" :| [])
              }
        )
      refused <-
        observeVerifiedEksDrainSelection
          interpreter
          fixtureBinding
          (ObservationRevision 42)
          fixtureEffectSession
      refused `shouldSatisfy` isIncompleteSelection

    it "acquires commit selection from the sealed attempt and binds it to the future drain operation" $ do
      environment <-
        newCommitSelectionEnvironment
          commitSelectionEksTarget
          commitSelectionBinding
          fixtureProjection
          [ presentUid fixtureUid
          , presentUid fixtureUid
          ]
      selected <- runCommitSelectionCase environment commitSelectionCommitPlan
      verified <- expectCommitSelection selected
      intent <- pure (mustRight (prepareEksDrainIntentFromVerifiedSelection verified))
      eksDrainBindingEffectOperationId (eksDrainIntentBinding intent)
        `shouldBe` commitSelectionEffectOperation
      case eksDrainIntentTarget intent of
        EksDrainExactKubernetesTarget
          { eksDrainTargetKubernetesUid = uid
          , eksDrainTargetDeletePolicyPvcs = pvcs
          } -> do
            uid `shouldBe` fixtureUid
            pvcs `shouldBe` [fixturePvcA, fixturePvcB]
        target -> expectationFailure ("unexpected selected target: " <> show target)
      show verified `shouldNotContain` "bearer-secret"
      calls <- readIORef (commitSelectionCalls environment)
      calls
        `shouldBe` [ CommitSelectionOpen
                       fixtureRunId
                       (cleanupGraphDigest (compiledDesiredAbsenceGraph commitSelectionCompiled))
                       commitSelectionCommitOperation
                       commitSelectionAttempt
                       expectedProjectionRequest
                   , CommitSelectionObserveUid
                   , CommitSelectionObserveUid
                   , CommitSelectionObserveServices
                   , CommitSelectionObserveIngresses
                   , CommitSelectionObserveDeletePolicyPvcs
                   ]

    it "refuses a non-commit execution context and a cross-operation binding before auth issuance" $ do
      wrongContext <-
        newCommitSelectionEnvironment
          commitSelectionEksTarget
          commitSelectionBinding
          fixtureProjection
          [presentUid fixtureUid, presentUid fixtureUid]
      contextResult <- runCommitSelectionCase wrongContext commitSelectionEffectPlan
      contextResult `shouldSatisfy` isCurrentOperationMismatch
      readIORef (commitSelectionCalls wrongContext) `shouldReturn` []

      wrongBinding <-
        newCommitSelectionEnvironment
          commitSelectionEksTarget
          commitSelectionBindingWithWrongEffect
          fixtureProjection
          [presentUid fixtureUid, presentUid fixtureUid]
      bindingResult <- runCommitSelectionCase wrongBinding commitSelectionCommitPlan
      bindingResult `shouldSatisfy` isEffectOperationMismatch
      readIORef (commitSelectionCalls wrongBinding) `shouldReturn` []

    it "refuses a cross-key target before auth issuance" $ do
      environment <-
        newCommitSelectionEnvironment
          commitSelectionAwsTestTarget
          commitSelectionBinding
          fixtureProjection
          [presentUid fixtureUid, presentUid fixtureUid]
      selected <- runCommitSelectionCase environment commitSelectionCommitPlan
      selected `shouldSatisfy` isCommitSelectionKeyMismatch
      readIORef (commitSelectionCalls environment) `shouldReturn` []

    it "refuses a Kubernetes UID change inside the continuation before inventory selection" $ do
      environment <-
        newCommitSelectionEnvironment
          commitSelectionEksTarget
          commitSelectionBinding
          fixtureProjection
          [ presentUid fixtureUid
          , presentUid "recreated-kube-system-uid"
          ]
      selected <- runCommitSelectionCase environment commitSelectionCommitPlan
      selected `shouldSatisfy` isCommitSelectionUidChanged
      readIORef (commitSelectionCalls environment)
        `shouldReturn` [ CommitSelectionOpen
                           fixtureRunId
                           (cleanupGraphDigest (compiledDesiredAbsenceGraph commitSelectionCompiled))
                           commitSelectionCommitOperation
                           commitSelectionAttempt
                           expectedProjectionRequest
                       , CommitSelectionObserveUid
                       , CommitSelectionObserveUid
                       ]

    it "refuses an expired Provider projection before inventory selection" $ do
      environment <-
        newCommitSelectionEnvironment
          commitSelectionEksTarget
          commitSelectionBinding
          fixtureExpiredProjection
          [presentUid fixtureUid]
      selected <- runCommitSelectionCase environment commitSelectionCommitPlan
      selected `shouldSatisfy` isExpiredCommitSelectionProjection
      calls <- readIORef (commitSelectionCalls environment)
      countCall CommitSelectionObserveUid calls `shouldBe` 1
      calls `shouldNotContain` [CommitSelectionObserveServices]
      calls `shouldNotContain` [CommitSelectionObserveIngresses]
      calls `shouldNotContain` [CommitSelectionObserveDeletePolicyPvcs]

    it "mints only destroy authorization from a fresh UID under the sealed reconcile attempt" $ do
      environment <- newDestroyAdmissionEnvironment fixtureProjection (presentUid fixtureUid)
      admitted <- runDestroyAdmissionCase environment commitSelectionReconcilePlan
      authorization <- expectDestroyAuthorization admitted
      awsEksDestroyAuthorizationKey authorization `shouldBe` AwsEksKey
      awsEksDestroyAuthorizationScope authorization
        `shouldBe` compiledDesiredAbsenceObservationScope commitSelectionCompiled
      awsEksDestroyAuthorizationOperationId authorization
        `shouldBe` commitSelectionDestroyOperation
      awsEksDestroyAuthorizationDrainAttemptId authorization
        `shouldBe` destroyDrainAttempt
      awsEksDestroyAuthorizationProviderRevision authorization
        `shouldBe` destroyProviderRevision
      awsEksDestroyAuthorizationProviderObservationRevision authorization
        `shouldBe` destroyProviderObservationRevision
      awsEksDestroyAuthorizationKubernetesObservationRevision authorization
        `shouldBe` destroyKubernetesObservationRevision
      awsEksDestroyAuthorizationClusterUid authorization `shouldBe` fixtureUid
      readIORef (destroyAdmissionCalls environment)
        `shouldReturn` [ CommitSelectionOpen
                           fixtureRunId
                           (cleanupGraphDigest (compiledDesiredAbsenceGraph commitSelectionCompiled))
                           commitSelectionDestroyOperation
                           destroyAdmissionAttempt
                           expectedProjectionRequest
                       , CommitSelectionObserveUid
                       , CommitSelectionObserveUid
                       , CommitSelectionObserveServices
                       , CommitSelectionObserveIngresses
                       , CommitSelectionObservePvc fixturePvcA
                       , CommitSelectionObservePvc fixturePvcB
                       ]

    it "refuses destroy admission outside the sealed registered-target reconcile node" $ do
      environment <- newDestroyAdmissionEnvironment fixtureProjection (presentUid fixtureUid)
      admitted <- runDestroyAdmissionCase environment commitSelectionCommitPlan
      admitted `shouldSatisfy` isDestroyCurrentOperationMismatch
      readIORef (destroyAdmissionCalls environment) `shouldReturn` []

    it "refuses a recreated UID and rotated endpoint or certificate authority" $ do
      recreated <-
        newDestroyAdmissionEnvironment
          fixtureProjection
          (presentUid "recreated-kube-system-uid")
      runDestroyAdmissionCase recreated commitSelectionReconcilePlan
        >>= (`shouldSatisfy` isDestroyUidMismatch)

      rotatedEndpoint <-
        newDestroyAdmissionEnvironment
          fixtureRotatedEndpointProjection
          (presentUid fixtureUid)
      runDestroyAdmissionCase rotatedEndpoint commitSelectionReconcilePlan
        >>= (`shouldSatisfy` isDestroyEndpointMismatch)

      rotatedCa <-
        newDestroyAdmissionEnvironment
          fixtureRotatedCaProjection
          (presentUid fixtureUid)
      runDestroyAdmissionCase rotatedCa commitSelectionReconcilePlan
        >>= (`shouldSatisfy` isDestroyCaMismatch)

    it "refuses destroy when a persisted drain target is freshly recreated" $ do
      base <- newDestroyAdmissionEnvironment fixtureProjection (presentUid fixtureUid)
      let recreated =
            base
              { destroyAdmissionPvcs =
                  Map.insert
                    fixturePvcA
                    (EksDrainPvcObservedPresent "recreated-pvc-uid")
                    (destroyAdmissionPvcs base)
              }
      admitted <- runDestroyAdmissionCase recreated commitSelectionReconcilePlan
      admitted `shouldSatisfy` isDestroyPvcPresent
      calls <- readIORef (destroyAdmissionCalls recreated)
      calls `shouldContain` [CommitSelectionObservePvc fixturePvcA]

    it "binds fresh effect and read-back sessions to their sealed operation and attempt" $ do
      effectEnvironment <-
        newAttemptExecutionEnvironment
          (RunAttemptEffect contextCommittedIntent)
          (Just (contextVerifiedFor commitSelectionEffectOperation))
          fixtureProjection
          defaultFakeCluster
          Nothing
      effectCaptured <-
        runAttemptExecutionCase
          effectEnvironment
          attemptA
          commitSelectionEffectPlan
      effectEvidence <- expectCapturedAttempt effectCaptured
      eksDrainAttemptEvidenceAttemptId effectEvidence `shouldBe` attemptA
      eksDrainAttemptOutcome effectEvidence `shouldBe` EksDrainMutationApplied
      readIORef (attemptExecutionCalls effectEnvironment)
        `shouldReturn` [ AttemptExecutionOpen
                           commitSelectionEffectOperation
                           attemptA
                           expectedProjectionRequest
                       , AttemptExecutionObserveUid
                       , AttemptExecutionObserveUid
                       , AttemptExecutionDeleteServices
                       , AttemptExecutionDeleteIngresses
                       , AttemptExecutionDeletePvc fixturePvcA
                       , AttemptExecutionDeletePvc fixturePvcB
                       ]

      effectState <- readIORef (attemptExecutionCluster effectEnvironment)
      readBackEnvironment <-
        newAttemptExecutionEnvironment
          (RunAttemptReadBack contextCommittedIntent effectEvidence)
          (Just (contextVerifiedFor commitSelectionDrainReadBackOperation))
          fixtureProjection
          (classesAbsent effectState)
          Nothing
      readBackCaptured <-
        runAttemptExecutionCase
          readBackEnvironment
          attemptB
          commitSelectionReadBackPlan
      observation <- expectCapturedReadBack readBackCaptured
      confirmEksDrainTargetsAbsent effectEvidence observation `shouldSatisfy` isRight
      readIORef (attemptExecutionCalls readBackEnvironment)
        `shouldReturn` [ AttemptExecutionOpen
                           commitSelectionDrainReadBackOperation
                           attemptB
                           expectedProjectionRequest
                       , AttemptExecutionObserveUid
                       , AttemptExecutionObserveUid
                       , AttemptExecutionObserveServices
                       , AttemptExecutionObserveIngresses
                       , AttemptExecutionObservePvc fixturePvcA
                       , AttemptExecutionObservePvc fixturePvcB
                       ]

    it "refuses cross-operation Provider evidence and a cross-key target before auth issuance" $ do
      crossOperation <-
        newAttemptExecutionEnvironment
          (RunAttemptEffect contextCommittedIntent)
          (Just (contextVerifiedFor commitSelectionDrainReadBackOperation))
          fixtureProjection
          defaultFakeCluster
          Nothing
      captured <-
        runAttemptExecutionCase
          crossOperation
          attemptA
          commitSelectionEffectPlan
      evidence <- expectCapturedAttempt captured
      eksDrainAttemptOutcome evidence `shouldSatisfy` isFailedOutcome
      readIORef (attemptExecutionCalls crossOperation) `shouldReturn` []

      crossKey <-
        newAttemptExecutionEnvironment
          (RunAttemptEffect contextCommittedIntent)
          (Just (contextVerifiedFor commitSelectionEffectOperation))
          fixtureProjection
          defaultFakeCluster
          Nothing
      capturedKey <-
        runAttemptExecutionCaseForTarget
          commitSelectionAwsTestTarget
          crossKey
          attemptA
          commitSelectionEffectPlan
      keyEvidence <- expectCapturedAttempt capturedKey
      eksDrainAttemptOutcome keyEvidence `shouldSatisfy` isFailedOutcome
      readIORef (attemptExecutionCalls crossKey) `shouldReturn` []

    it "refuses expired or identity-rotated projections before Kubernetes mutation" $ do
      let cases =
            [
              ( fixtureExpiredProjection
              , defaultFakeCluster
              )
            ,
              ( fixtureProjection
              , defaultFakeCluster
                  { fakeUidObservation =
                      presentUid "recreated-kube-system-uid"
                  }
              )
            , (fixtureRotatedEndpointProjection, defaultFakeCluster)
            , (fixtureRotatedCaProjection, defaultFakeCluster)
            ]
      mapM_
        ( \(projection, cluster) -> do
            environment <-
              newAttemptExecutionEnvironment
                (RunAttemptEffect contextCommittedIntent)
                (Just (contextVerifiedFor commitSelectionEffectOperation))
                projection
                cluster
                Nothing
            captured <-
              runAttemptExecutionCase
                environment
                attemptA
                commitSelectionEffectPlan
            evidence <- expectCapturedAttempt captured
            eksDrainAttemptOutcome evidence `shouldSatisfy` isFailedOutcome
            calls <- readIORef (attemptExecutionCalls environment)
            filter isAttemptMutation calls `shouldBe` []
        )
        cases

    it "keeps Provider auth unavailability unobservable under the sealed effect" $ do
      environment <-
        newAttemptExecutionEnvironment
          (RunAttemptEffect contextCommittedIntent)
          (Just (contextVerifiedFor commitSelectionEffectOperation))
          fixtureProjection
          defaultFakeCluster
          ( Just
              ( EksDrainClientAccessUnobservable
                  (ObservationFailure "Provider auth response unavailable")
              )
          )
      captured <-
        runAttemptExecutionCase
          environment
          attemptA
          commitSelectionEffectPlan
      evidence <- expectCapturedAttempt captured
      eksDrainAttemptOutcome evidence `shouldSatisfy` isUnobservableOutcome
      readIORef (attemptExecutionCalls environment)
        `shouldReturn` [ AttemptExecutionOpen
                           commitSelectionEffectOperation
                           attemptA
                           expectedProjectionRequest
                       ]

    it "replays a committed no-target intent without Provider evidence or credentials" $ do
      effectEnvironment <-
        newAttemptExecutionEnvironment
          (RunAttemptEffect contextNoTargetCommittedIntent)
          Nothing
          fixtureProjection
          defaultFakeCluster
          Nothing
      effectCaptured <-
        runAttemptExecutionCase
          effectEnvironment
          attemptA
          commitSelectionEffectPlan
      effectEvidence <- expectCapturedAttempt effectCaptured
      eksDrainAttemptOutcome effectEvidence `shouldBe` EksDrainSkippedNoKubernetesTarget
      readIORef (attemptExecutionCalls effectEnvironment) `shouldReturn` []

      readBackEnvironment <-
        newAttemptExecutionEnvironment
          (RunAttemptReadBack contextNoTargetCommittedIntent effectEvidence)
          Nothing
          fixtureProjection
          defaultFakeCluster
          Nothing
      readBackCaptured <-
        runAttemptExecutionCase
          readBackEnvironment
          attemptB
          commitSelectionReadBackPlan
      observation <- expectCapturedReadBack readBackCaptured
      fmap
        eksDrainTargetsAbsentDisposition
        (confirmEksDrainTargetsAbsent effectEvidence observation)
        `shouldBe` Right NoKubernetesDrainTargetRequired
      readIORef (attemptExecutionCalls readBackEnvironment) `shouldReturn` []

      unnecessaryEvidence <-
        newAttemptExecutionEnvironment
          (RunAttemptEffect contextNoTargetCommittedIntent)
          (Just (contextVerifiedFor commitSelectionEffectOperation))
          fixtureProjection
          defaultFakeCluster
          Nothing
      rejected <-
        runAttemptExecutionCase
          unnecessaryEvidence
          attemptA
          commitSelectionEffectPlan
      rejected `shouldSatisfy` isCapturedAttemptRefusal
      readIORef (attemptExecutionCalls unnecessaryEvidence) `shouldReturn` []

    it "reacquires a fenced session and deletes both complete classes plus every persisted PVC" $ do
      (interpreter, _, calls) <- fixtureInterpreter
      executed <-
        executeCommittedEksDrainIntent
          interpreter
          (effectInvocation attemptA)
          fixtureCommittedIntent
      fmap eksDrainAttemptOutcome executed `shouldBe` Right EksDrainMutationApplied
      observed <- readIORef calls
      observed
        `shouldContainAll` [ FakeAcquire drainEffectOperation attemptA
                           , FakeOpenClient drainEffectOperation
                           , FakeDeleteServices
                           , FakeDeleteIngresses
                           , FakeDeletePvc fixturePvcA
                           , FakeDeletePvc fixturePvcB
                           ]

    it "keeps response loss unconfirmed until a separately acquired exact read-back" $ do
      (interpreter, cluster, calls) <- fixtureInterpreter
      modifyIORef'
        cluster
        ( \state ->
            state
              { fakeIngressDelete =
                  EksDrainMutationResponseLost
                    (ObservationFailure "delete response lost")
              }
        )
      attempted <-
        executeCommittedEksDrainIntent
          interpreter
          (effectInvocation attemptA)
          fixtureCommittedIntent
      attempt <- mustRightIO attempted
      eksDrainAttemptOutcome attempt `shouldSatisfy` isUnobservableOutcome
      modifyIORef' cluster classesAbsent
      completed <-
        executeEksDrainReadBack
          interpreter
          (readBackInvocation attemptB)
          attempt
      completed `shouldSatisfy` isRight
      observed <- readIORef calls
      observed
        `shouldContainAll` [ FakeAcquire drainEffectOperation attemptA
                           , FakeAcquire drainReadBackOperation attemptB
                           , FakeObservePvc fixturePvcA
                           , FakeObservePvc fixturePvcB
                           ]

    it "queries a persisted PVC directly even after its Delete-policy PV disappears" $ do
      (interpreter, cluster, calls) <- fixtureInterpreter
      attempt <- executeApplied interpreter
      modifyIORef'
        cluster
        ( \state ->
            state
              { fakeServiceInventory = EksDrainInventoryComplete []
              , fakeIngressInventory = EksDrainInventoryComplete []
              , fakeDeletePolicyPvcInventory = EksDrainInventoryComplete []
              , fakePvcObservations =
                  Map.insert
                    fixturePvcA
                    (EksDrainPvcObservedPresent "original-pvc-uid")
                    (fakePvcObservations state)
              }
        )
      completed <-
        executeEksDrainReadBack
          interpreter
          (readBackInvocation attemptB)
          attempt
      completed `shouldBe` Left (EksDrainPvcNotAbsent fixturePvcA EksDrainPvcPresent)
      observed <- readIORef calls
      countCall FakeObserveDeletePolicyPvcs observed `shouldBe` 0
      observed `shouldContain` [FakeObservePvc fixturePvcA]

    it "treats a recreated same-name PVC with another UID as present" $ do
      (interpreter, cluster, _) <- fixtureInterpreter
      attempt <- executeApplied interpreter
      modifyIORef'
        cluster
        ( \state ->
            state
              { fakeServiceInventory = EksDrainInventoryComplete []
              , fakeIngressInventory = EksDrainInventoryComplete []
              , fakePvcObservations =
                  Map.insert
                    fixturePvcB
                    (EksDrainPvcObservedPresent "replacement-pvc-uid")
                    (fakePvcObservations state)
              }
        )
      observation <-
        observeEksDrainTargetsReadBack
          interpreter
          (readBackInvocation attemptB)
          attempt
      confirmEksDrainTargetsAbsent attempt observation
        `shouldBe` Left (EksDrainPvcNotAbsent fixturePvcB EksDrainPvcPresent)

    it "refuses wrong run, graph, operation, and acquired-attempt bindings before mutation" $ do
      let wrongInvocations =
            [ (effectInvocation attemptA) {eksDrainInvocationRunId = otherRunId}
            , (effectInvocation attemptA) {eksDrainInvocationGraphDigest = otherGraphDigest}
            , (effectInvocation attemptA) {eksDrainInvocationOperationId = otherOperation}
            ]
      mapM_
        ( \invocation -> do
            (interpreter, _, calls) <- fixtureInterpreter
            result <-
              executeCommittedEksDrainIntent
                interpreter
                invocation
                fixtureCommittedIntent
            fmap eksDrainAttemptOutcome result `shouldSatisfy` isFailedResult
            shouldReturnNoMutation (readIORef calls)
        )
        wrongInvocations
      (_, cluster, calls) <- fixtureInterpreter
      let wrongAttemptAcquirer requested = do
            modifyIORef' calls (<> [FakeAcquire (eksDrainInvocationOperationId requested) attemptB])
            pure
              ( EksDrainSessionAcquired
                  requested {eksDrainInvocationAttemptId = attemptB}
                  fixtureEffectSession
              )
          interpreter =
            mkEksDrainInterpreter
              (pure 1_000)
              wrongAttemptAcquirer
              (fakeBoundary cluster calls)
      wrongAttempt <-
        executeCommittedEksDrainIntent
          interpreter
          (effectInvocation attemptA)
          fixtureCommittedIntent
      fmap eksDrainAttemptOutcome wrongAttempt `shouldSatisfy` isFailedResult
      shouldReturnNoMutation (readIORef calls)

    it "refuses a recreated cluster UID before any delete" $ do
      cluster <- newIORef defaultFakeCluster
      calls <- newIORef []
      let acquire requested = do
            modifyIORef'
              calls
              (<> [FakeAcquire (eksDrainInvocationOperationId requested) (eksDrainInvocationAttemptId requested)])
            pure (EksDrainSessionAcquired requested fixtureRecreatedClusterSession)
          interpreter =
            mkEksDrainInterpreter (pure 1_000) acquire (fakeBoundary cluster calls)
      executed <-
        executeCommittedEksDrainIntent
          interpreter
          (effectInvocation attemptA)
          fixtureCommittedIntent
      fmap eksDrainAttemptOutcome executed `shouldSatisfy` isFailedResult
      shouldReturnNoMutation (readIORef calls)

    it "keeps auth and network unknown distinct from absence" $ do
      cluster <- newIORef defaultFakeCluster
      calls <- newIORef []
      let unavailable requested = do
            modifyIORef'
              calls
              (<> [FakeAcquire (eksDrainInvocationOperationId requested) (eksDrainInvocationAttemptId requested)])
            pure
              ( EksDrainSessionAcquisitionUnobservable
                  (ObservationFailure "Authority auth route unavailable")
              )
          interpreter =
            mkEksDrainInterpreter (pure 1_000) unavailable (fakeBoundary cluster calls)
      attempted <-
        executeCommittedEksDrainIntent
          interpreter
          (effectInvocation attemptA)
          fixtureCommittedIntent
      attempt <- mustRightIO attempted
      eksDrainAttemptOutcome attempt `shouldSatisfy` isUnobservableOutcome
      modifyIORef'
        cluster
        ( \state ->
            state
              { fakeUidObservation =
                  EksDrainKubernetesUidUnobservable
                    (ObservationFailure "Kubernetes network unknown" :| [])
              }
        )
      let readBackInterpreter = fixtureInterpreterFor cluster calls
      completed <-
        executeEksDrainReadBack
          readBackInterpreter
          (readBackInvocation attemptB)
          attempt
      completed `shouldSatisfy` isLeft

    it "closes the provider-already-absent arm without acquiring Kubernetes credentials" $ do
      (interpreter, _, calls) <- fixtureInterpreter
      attempted <-
        executeCommittedEksDrainIntent
          interpreter
          (effectInvocation attemptA)
          fixtureNoTargetCommittedIntent
      attempt <- mustRightIO attempted
      eksDrainAttemptOutcome attempt `shouldBe` EksDrainSkippedNoKubernetesTarget
      completed <-
        executeEksDrainReadBack
          interpreter
          (readBackInvocation attemptB)
          attempt
      fmap eksDrainTargetsAbsentDisposition completed
        `shouldBe` Right NoKubernetesDrainTargetRequired
      readIORef calls `shouldReturn` []

data CommitSelectionCall
  = CommitSelectionOpen
      !CleanupRunId
      !CleanupDigest
      !CleanupOperationId
      !CleanupAttemptId
      !EksDrainProjectionRequest
  | CommitSelectionObserveUid
  | CommitSelectionObserveServices
  | CommitSelectionObserveIngresses
  | CommitSelectionObserveDeletePolicyPvcs
  | CommitSelectionObservePvc !EksNamespacedName
  deriving (Eq, Show)

data CommitSelectionEnvironment = CommitSelectionEnvironment
  { commitSelectionTarget :: !RegisteredTargetBinding
  , commitSelectionOperationBinding :: !EksDrainOperationBinding
  , commitSelectionProjection :: !EksClientAuthProjection
  , commitSelectionUidAnswers :: !(IORef [EksDrainKubernetesUidObservation])
  , commitSelectionCalls :: !(IORef [CommitSelectionCall])
  , commitSelectionCaptured
      :: !( IORef
              ( Maybe
                  ( Either
                      EksDrainCommitSelectionError
                      VerifiedEksDrainSelection
                  )
              )
          )
  }

newtype CommitSelectionEffects value = CommitSelectionEffects
  { runCommitSelectionEffects :: CommitSelectionEnvironment -> IO value
  }

instance Functor CommitSelectionEffects where
  fmap function (CommitSelectionEffects action) =
    CommitSelectionEffects (fmap function . action)

instance Applicative CommitSelectionEffects where
  pure value = CommitSelectionEffects (const (pure value))
  CommitSelectionEffects function <*> CommitSelectionEffects action =
    CommitSelectionEffects $ \environment ->
      function environment <*> action environment

instance Monad CommitSelectionEffects where
  CommitSelectionEffects action >>= continue =
    CommitSelectionEffects $ \environment -> do
      value <- action environment
      runCommitSelectionEffects (continue value) environment

instance LifecycleTeardownEffects CommitSelectionEffects where
  executeLifecycleTeardownOperation context _operation =
    CommitSelectionEffects $ \environment -> do
      selected <-
        runCommitSelectionEffects
          ( acquireVerifiedEksDrainSelection
              commitSelectionInterpreter
              commitSelectionBoundary
              context
              (commitSelectionTarget environment)
              (commitSelectionOperationBinding environment)
              (ObservationRevision 51)
              (ObservationRevision 52)
              1_500
              commitSelectionVerifiedPresent
          )
          environment
      writeIORef (commitSelectionCaptured environment) (Just selected)
      pure
        ( TeardownMutationAttempt
            (TeardownMutationRefused "commit selection captured")
        )

newCommitSelectionEnvironment
  :: RegisteredTargetBinding
  -> EksDrainOperationBinding
  -> EksClientAuthProjection
  -> [EksDrainKubernetesUidObservation]
  -> IO CommitSelectionEnvironment
newCommitSelectionEnvironment target binding projection uidAnswers = do
  uidRef <- newIORef uidAnswers
  calls <- newIORef []
  captured <- newIORef Nothing
  pure
    CommitSelectionEnvironment
      { commitSelectionTarget = target
      , commitSelectionOperationBinding = binding
      , commitSelectionProjection = projection
      , commitSelectionUidAnswers = uidRef
      , commitSelectionCalls = calls
      , commitSelectionCaptured = captured
      }

runCommitSelectionCase
  :: CommitSelectionEnvironment
  -> CleanupNodePlan
  -> IO
       ( Either
           EksDrainCommitSelectionError
           VerifiedEksDrainSelection
       )
runCommitSelectionCase environment plan = do
  _ <-
    runCommitSelectionEffects
      ( runCompiledTeardownNodeWithAttempt
          commitSelectionCompiled
          commitSelectionAttempt
          plan
      )
      environment
  captured <- readIORef (commitSelectionCaptured environment)
  case captured of
    Nothing -> expectationFailure "commit selection was not invoked" >> fail "missing result"
    Just selected -> pure selected

commitSelectionInterpreter :: EksDrainInterpreter CommitSelectionEffects
commitSelectionInterpreter =
  mkEksDrainInterpreter
    (pure 1_000)
    ( \_ ->
        pure
          ( EksDrainSessionAcquisitionRefused
              (ObservationFailure "commit selector cannot acquire an effect session")
          )
    )
    ( mkEksDrainClientBoundary $ \_ consume ->
        consume
          ( Left
              ( EksDrainClientAccessRefused
                  (ObservationFailure "commit selector cannot open an effect client")
              )
          )
    )

commitSelectionBoundary
  :: EksDrainCommitSelectionBoundary CommitSelectionEffects
commitSelectionBoundary =
  mkEksDrainCommitSelectionBoundary $ \identity request consume ->
    CommitSelectionEffects $ \environment -> do
      modifyIORef'
        (commitSelectionCalls environment)
        ( <>
            [ CommitSelectionOpen
                (teardownExecutionIdentityRunId identity)
                (teardownExecutionIdentityGraphDigest identity)
                (teardownExecutionIdentityOperationId identity)
                (teardownExecutionIdentityAttemptId identity)
                request
            ]
        )
      runCommitSelectionEffects
        ( consume
            ( Right
                ( commitSelectionProjection environment
                , commitSelectionClientEffects
                )
            )
        )
        environment

commitSelectionClientEffects :: EksDrainClientEffects CommitSelectionEffects
commitSelectionClientEffects =
  EksDrainClientEffects
    { eksDrainClientObserveKubernetesUid = nextCommitSelectionUid
    , eksDrainClientObserveLoadBalancerServices =
        tracedCommitSelection
          CommitSelectionObserveServices
          (EksDrainInventoryComplete [fixtureService])
    , eksDrainClientObserveIngresses =
        tracedCommitSelection
          CommitSelectionObserveIngresses
          (EksDrainInventoryComplete [fixtureIngress])
    , eksDrainClientObserveDeletePolicyPvcs =
        tracedCommitSelection
          CommitSelectionObserveDeletePolicyPvcs
          (EksDrainInventoryComplete [fixturePvcB, fixturePvcA])
    , eksDrainClientDeleteLoadBalancerServices =
        pure
          ( EksDrainMutationResponseRefused
              (ObservationFailure "commit selector cannot mutate Services")
          )
    , eksDrainClientDeleteIngresses =
        pure
          ( EksDrainMutationResponseRefused
              (ObservationFailure "commit selector cannot mutate Ingresses")
          )
    , eksDrainClientDeletePvc =
        \_ ->
          pure
            ( EksDrainMutationResponseRefused
                (ObservationFailure "commit selector cannot mutate PVCs")
            )
    , eksDrainClientObservePvc =
        \_ ->
          pure
            ( EksDrainPvcObservationUnobservable
                (ObservationFailure "commit selector cannot read back PVCs" :| [])
            )
    }

nextCommitSelectionUid
  :: CommitSelectionEffects EksDrainKubernetesUidObservation
nextCommitSelectionUid =
  CommitSelectionEffects $ \environment -> do
    modifyIORef'
      (commitSelectionCalls environment)
      (<> [CommitSelectionObserveUid])
    atomicModifyIORef' (commitSelectionUidAnswers environment) $ \answers ->
      case answers of
        answer : remaining -> (remaining, answer)
        [] ->
          ( []
          , EksDrainKubernetesUidUnobservable
              (ObservationFailure "fake UID response omitted" :| [])
          )

tracedCommitSelection
  :: CommitSelectionCall -> value -> CommitSelectionEffects value
tracedCommitSelection call value =
  CommitSelectionEffects $ \environment -> do
    modifyIORef' (commitSelectionCalls environment) (<> [call])
    pure value

presentUid :: Text -> EksDrainKubernetesUidObservation
presentUid = EksDrainKubernetesUidPresent

expectCommitSelection
  :: Either EksDrainCommitSelectionError VerifiedEksDrainSelection
  -> IO VerifiedEksDrainSelection
expectCommitSelection selected = case selected of
  Left err -> expectationFailure (show err) >> fail "selection refused"
  Right verified -> pure verified

isCurrentOperationMismatch
  :: Either EksDrainCommitSelectionError VerifiedEksDrainSelection -> Bool
isCurrentOperationMismatch selected = case selected of
  Left
    ( EksDrainCommitSelectionCurrentOperationMismatch
        expected
        actual
      ) ->
      expected == commitSelectionCommitOperation
        && actual == commitSelectionEffectOperation
  _ -> False

isEffectOperationMismatch
  :: Either EksDrainCommitSelectionError VerifiedEksDrainSelection -> Bool
isEffectOperationMismatch selected = case selected of
  Left
    ( EksDrainCommitSelectionBindingOperationMismatch
        label
        expected
        actual
      ) ->
      label == "drain EKS Kubernetes resources"
        && expected == commitSelectionEffectOperation
        && actual == otherOperation
  _ -> False

isCommitSelectionKeyMismatch
  :: Either EksDrainCommitSelectionError VerifiedEksDrainSelection -> Bool
isCommitSelectionKeyMismatch selected = case selected of
  Left (EksDrainCommitSelectionTargetKeyMismatch AwsEksKey AwsTestKey) -> True
  _ -> False

isCommitSelectionUidChanged
  :: Either EksDrainCommitSelectionError VerifiedEksDrainSelection -> Bool
isCommitSelectionUidChanged selected = case selected of
  Left (EksDrainCommitSelectionKubernetesUidChanged _) -> True
  _ -> False

isExpiredCommitSelectionProjection
  :: Either EksDrainCommitSelectionError VerifiedEksDrainSelection -> Bool
isExpiredCommitSelectionProjection selected = case selected of
  Left
    ( EksDrainCommitSelectionSessionInvalid
        (EksDrainProjectionExpired 1_000 900)
      ) -> True
  _ -> False

data DestroyAdmissionEnvironment = DestroyAdmissionEnvironment
  { destroyAdmissionProjection :: !EksClientAuthProjection
  , destroyAdmissionUid :: !EksDrainKubernetesUidObservation
  , destroyAdmissionServices :: !(EksDrainInventoryResult EksNamespacedName)
  , destroyAdmissionIngresses :: !(EksDrainInventoryResult EksNamespacedName)
  , destroyAdmissionPvcs :: !(Map EksNamespacedName EksDrainPvcObservation)
  , destroyAdmissionCalls :: !(IORef [CommitSelectionCall])
  , destroyAdmissionCaptured
      :: !( IORef
              ( Maybe
                  ( Either
                      EksDrainDestroyAdmissionError
                      AwsEksDestroyAuthorization
                  )
              )
          )
  }

newtype DestroyAdmissionEffects value = DestroyAdmissionEffects
  { runDestroyAdmissionEffects :: DestroyAdmissionEnvironment -> IO value
  }

instance Functor DestroyAdmissionEffects where
  fmap function (DestroyAdmissionEffects action) =
    DestroyAdmissionEffects (fmap function . action)

instance Applicative DestroyAdmissionEffects where
  pure value = DestroyAdmissionEffects (const (pure value))
  DestroyAdmissionEffects function <*> DestroyAdmissionEffects action =
    DestroyAdmissionEffects $ \environment ->
      function environment <*> action environment

instance Monad DestroyAdmissionEffects where
  DestroyAdmissionEffects action >>= continue =
    DestroyAdmissionEffects $ \environment -> do
      value <- action environment
      runDestroyAdmissionEffects (continue value) environment

instance LifecycleTeardownEffects DestroyAdmissionEffects where
  executeLifecycleTeardownOperation context _operation =
    DestroyAdmissionEffects $ \environment -> do
      admitted <-
        runDestroyAdmissionEffects
          ( acquireAwsEksDestroyAuthorization
              destroyAdmissionInterpreter
              destroyAdmissionBoundary
              context
              commitSelectionEksTarget
              commitSelectionBinding
              destroyProviderRevision
              destroyDecision
              destroyDrainEvidence
              destroyKubernetesObservationRevision
              1_500
              destroyVerifiedPresent
          )
          environment
      writeIORef (destroyAdmissionCaptured environment) (Just admitted)
      pure
        ( TeardownMutationAttempt
            (TeardownMutationRefused "destroy admission captured")
        )

newDestroyAdmissionEnvironment
  :: EksClientAuthProjection
  -> EksDrainKubernetesUidObservation
  -> IO DestroyAdmissionEnvironment
newDestroyAdmissionEnvironment projection uid = do
  calls <- newIORef []
  captured <- newIORef Nothing
  pure
    DestroyAdmissionEnvironment
      { destroyAdmissionProjection = projection
      , destroyAdmissionUid = uid
      , destroyAdmissionServices = EksDrainInventoryComplete []
      , destroyAdmissionIngresses = EksDrainInventoryComplete []
      , destroyAdmissionPvcs =
          Map.fromList
            [ (fixturePvcA, absentPvc "PVC A absent")
            , (fixturePvcB, absentPvc "PVC B absent")
            ]
      , destroyAdmissionCalls = calls
      , destroyAdmissionCaptured = captured
      }

runDestroyAdmissionCase
  :: DestroyAdmissionEnvironment
  -> CleanupNodePlan
  -> IO
       ( Either
           EksDrainDestroyAdmissionError
           AwsEksDestroyAuthorization
       )
runDestroyAdmissionCase environment plan = do
  _ <-
    runDestroyAdmissionEffects
      ( runCompiledTeardownNodeWithAttempt
          commitSelectionCompiled
          destroyAdmissionAttempt
          plan
      )
      environment
  captured <- readIORef (destroyAdmissionCaptured environment)
  case captured of
    Nothing -> expectationFailure "destroy admission was not invoked" >> fail "missing result"
    Just admitted -> pure admitted

destroyAdmissionInterpreter :: EksDrainInterpreter DestroyAdmissionEffects
destroyAdmissionInterpreter =
  mkEksDrainInterpreter
    (pure 1_000)
    ( \_ ->
        pure
          ( EksDrainSessionAcquisitionRefused
              (ObservationFailure "destroy admission uses only its projection boundary")
          )
    )
    ( mkEksDrainClientBoundary $ \_ consume ->
        consume
          ( Left
              ( EksDrainClientAccessRefused
                  (ObservationFailure "destroy admission cannot open an effect client")
              )
          )
    )

destroyAdmissionBoundary
  :: EksDrainCommitSelectionBoundary DestroyAdmissionEffects
destroyAdmissionBoundary =
  mkEksDrainCommitSelectionBoundary $ \identity request consume ->
    DestroyAdmissionEffects $ \environment -> do
      modifyIORef'
        (destroyAdmissionCalls environment)
        ( <>
            [ CommitSelectionOpen
                (teardownExecutionIdentityRunId identity)
                (teardownExecutionIdentityGraphDigest identity)
                (teardownExecutionIdentityOperationId identity)
                (teardownExecutionIdentityAttemptId identity)
                request
            ]
        )
      runDestroyAdmissionEffects
        ( consume
            ( Right
                ( destroyAdmissionProjection environment
                , destroyAdmissionClientEffects
                )
            )
        )
        environment

destroyAdmissionClientEffects :: EksDrainClientEffects DestroyAdmissionEffects
destroyAdmissionClientEffects =
  EksDrainClientEffects
    { eksDrainClientObserveKubernetesUid =
        DestroyAdmissionEffects $ \environment -> do
          modifyIORef'
            (destroyAdmissionCalls environment)
            (<> [CommitSelectionObserveUid])
          pure (destroyAdmissionUid environment)
    , eksDrainClientObserveLoadBalancerServices =
        tracedDestroyAdmission
          CommitSelectionObserveServices
          destroyAdmissionServices
    , eksDrainClientObserveIngresses =
        tracedDestroyAdmission
          CommitSelectionObserveIngresses
          destroyAdmissionIngresses
    , eksDrainClientObserveDeletePolicyPvcs = unavailableInventory
    , eksDrainClientDeleteLoadBalancerServices = unavailableMutation
    , eksDrainClientDeleteIngresses = unavailableMutation
    , eksDrainClientDeletePvc = const unavailableMutation
    , eksDrainClientObservePvc =
        \pvc ->
          DestroyAdmissionEffects $ \environment -> do
            modifyIORef'
              (destroyAdmissionCalls environment)
              (<> [CommitSelectionObservePvc pvc])
            pure
              ( Map.findWithDefault
                  ( EksDrainPvcObservationUnobservable
                      (ObservationFailure "destroy admission PVC fixture missing" :| [])
                  )
                  pvc
                  (destroyAdmissionPvcs environment)
              )
    }
 where
  unavailableInventory =
    pure
      ( EksDrainInventoryUnobservable
          (ObservationFailure "destroy admission cannot select inventory" :| [])
      )
  unavailableMutation =
    pure
      ( EksDrainMutationResponseRefused
          (ObservationFailure "destroy admission cannot mutate Kubernetes")
      )

tracedDestroyAdmission
  :: CommitSelectionCall
  -> (DestroyAdmissionEnvironment -> value)
  -> DestroyAdmissionEffects value
tracedDestroyAdmission call project =
  DestroyAdmissionEffects $ \environment -> do
    modifyIORef' (destroyAdmissionCalls environment) (<> [call])
    pure (project environment)

expectDestroyAuthorization
  :: Either EksDrainDestroyAdmissionError AwsEksDestroyAuthorization
  -> IO AwsEksDestroyAuthorization
expectDestroyAuthorization admitted = case admitted of
  Left err -> expectationFailure (show err) >> fail "destroy admission refused"
  Right authorization -> pure authorization

isDestroyCurrentOperationMismatch
  :: Either EksDrainDestroyAdmissionError AwsEksDestroyAuthorization -> Bool
isDestroyCurrentOperationMismatch admitted = case admitted of
  Left
    ( EksDrainDestroyAdmissionContextInvalid
        ( EksDrainCommitSelectionCurrentOperationMismatch
            expected
            actual
          )
      ) ->
      expected == commitSelectionDestroyOperation
        && actual == commitSelectionCommitOperation
  _ -> False

isDestroyUidMismatch
  :: Either EksDrainDestroyAdmissionError AwsEksDestroyAuthorization -> Bool
isDestroyUidMismatch admitted = case admitted of
  Left
    ( EksDrainDestroyAdmissionRefused
        (AwsEksDestroyDrainedUidMismatch expected actual)
      ) ->
      expected == fixtureUid && actual == "recreated-kube-system-uid"
  _ -> False

isDestroyEndpointMismatch
  :: Either EksDrainDestroyAdmissionError AwsEksDestroyAuthorization -> Bool
isDestroyEndpointMismatch admitted = case admitted of
  Left
    ( EksDrainDestroyAdmissionRefused
        AwsEksDestroyDrainedEndpointDigestMismatch {}
      ) -> True
  _ -> False

isDestroyCaMismatch
  :: Either EksDrainDestroyAdmissionError AwsEksDestroyAuthorization -> Bool
isDestroyCaMismatch admitted = case admitted of
  Left
    ( EksDrainDestroyAdmissionRefused
        AwsEksDestroyDrainedCertificateAuthorityDigestMismatch {}
      ) -> True
  _ -> False

isDestroyPvcPresent
  :: Either EksDrainDestroyAdmissionError AwsEksDestroyAuthorization -> Bool
isDestroyPvcPresent admitted = case admitted of
  Left
    ( EksDrainDestroyAdmissionPvcNotAbsent
        pvc
        (EksDrainPvcObservedPresent uid)
      ) ->
      pvc == fixturePvcA && uid == "recreated-pvc-uid"
  _ -> False

data AttemptExecutionMode
  = RunAttemptEffect !CommittedEksDrainIntent
  | RunAttemptReadBack !CommittedEksDrainIntent !EksDrainAttemptEvidence

data AttemptExecutionCaptured
  = CapturedAttempt
      !(Either EksDrainIntentError EksDrainAttemptEvidence)
  | CapturedReadBack !EksDrainTargetReadBackObservation

data AttemptExecutionCall
  = AttemptExecutionOpen
      !CleanupOperationId
      !CleanupAttemptId
      !EksDrainProjectionRequest
  | AttemptExecutionObserveUid
  | AttemptExecutionObserveServices
  | AttemptExecutionObserveIngresses
  | AttemptExecutionObserveDeletePolicyPvcs
  | AttemptExecutionDeleteServices
  | AttemptExecutionDeleteIngresses
  | AttemptExecutionDeletePvc !EksNamespacedName
  | AttemptExecutionObservePvc !EksNamespacedName
  deriving (Eq, Show)

data AttemptExecutionEnvironment = AttemptExecutionEnvironment
  { attemptExecutionMode :: !AttemptExecutionMode
  , attemptExecutionTarget :: !RegisteredTargetBinding
  , attemptExecutionVerified
      :: !(Maybe (VerifiedAwsEksObservation 'ObserveEksForDecision))
  , attemptExecutionProjection :: !EksClientAuthProjection
  , attemptExecutionCluster :: !(IORef FakeCluster)
  , attemptExecutionAccessFailure :: !(Maybe EksDrainClientAccessFailure)
  , attemptExecutionCalls :: !(IORef [AttemptExecutionCall])
  , attemptExecutionCaptured :: !(IORef (Maybe AttemptExecutionCaptured))
  }

newtype AttemptExecutionEffects value = AttemptExecutionEffects
  { runAttemptExecutionEffects :: AttemptExecutionEnvironment -> IO value
  }

instance Functor AttemptExecutionEffects where
  fmap function (AttemptExecutionEffects action) =
    AttemptExecutionEffects (fmap function . action)

instance Applicative AttemptExecutionEffects where
  pure value = AttemptExecutionEffects (const (pure value))
  AttemptExecutionEffects function <*> AttemptExecutionEffects action =
    AttemptExecutionEffects $ \environment ->
      function environment <*> action environment

instance Monad AttemptExecutionEffects where
  AttemptExecutionEffects action >>= continue =
    AttemptExecutionEffects $ \environment -> do
      value <- action environment
      runAttemptExecutionEffects (continue value) environment

instance LifecycleTeardownEffects AttemptExecutionEffects where
  executeLifecycleTeardownOperation context _operation =
    AttemptExecutionEffects $ \environment -> do
      captured <- case attemptExecutionMode environment of
        RunAttemptEffect committedIntent ->
          CapturedAttempt
            <$> runAttemptExecutionEffects
              ( executeCommittedEksDrainIntentWithContext
                  attemptExecutionInterpreter
                  attemptExecutionBoundary
                  context
                  (attemptExecutionTarget environment)
                  attemptKubernetesObservationRevision
                  1_500
                  (attemptExecutionVerified environment)
                  committedIntent
              )
              environment
        RunAttemptReadBack committedIntent attemptEvidence ->
          CapturedReadBack
            <$> runAttemptExecutionEffects
              ( observeEksDrainTargetsReadBackWithContext
                  attemptExecutionInterpreter
                  attemptExecutionBoundary
                  context
                  (attemptExecutionTarget environment)
                  attemptKubernetesObservationRevision
                  1_500
                  (attemptExecutionVerified environment)
                  committedIntent
                  attemptEvidence
              )
              environment
      writeIORef (attemptExecutionCaptured environment) (Just captured)
      pure
        ( TeardownMutationAttempt
            (TeardownMutationRefused "attempt execution captured")
        )

newAttemptExecutionEnvironment
  :: AttemptExecutionMode
  -> Maybe (VerifiedAwsEksObservation 'ObserveEksForDecision)
  -> EksClientAuthProjection
  -> FakeCluster
  -> Maybe EksDrainClientAccessFailure
  -> IO AttemptExecutionEnvironment
newAttemptExecutionEnvironment mode verified projection cluster accessFailure = do
  clusterRef <- newIORef cluster
  calls <- newIORef []
  captured <- newIORef Nothing
  pure
    AttemptExecutionEnvironment
      { attemptExecutionMode = mode
      , attemptExecutionTarget = commitSelectionEksTarget
      , attemptExecutionVerified = verified
      , attemptExecutionProjection = projection
      , attemptExecutionCluster = clusterRef
      , attemptExecutionAccessFailure = accessFailure
      , attemptExecutionCalls = calls
      , attemptExecutionCaptured = captured
      }

runAttemptExecutionCase
  :: AttemptExecutionEnvironment
  -> CleanupAttemptId
  -> CleanupNodePlan
  -> IO AttemptExecutionCaptured
runAttemptExecutionCase =
  runAttemptExecutionCaseForTarget commitSelectionEksTarget

runAttemptExecutionCaseForTarget
  :: RegisteredTargetBinding
  -> AttemptExecutionEnvironment
  -> CleanupAttemptId
  -> CleanupNodePlan
  -> IO AttemptExecutionCaptured
runAttemptExecutionCaseForTarget target environment attempt plan = do
  let targeted = environment {attemptExecutionTarget = target}
  _ <-
    runAttemptExecutionEffects
      ( runCompiledTeardownNodeWithAttempt
          commitSelectionCompiled
          attempt
          plan
      )
      targeted
  captured <- readIORef (attemptExecutionCaptured targeted)
  case captured of
    Nothing -> expectationFailure "attempt execution was not invoked" >> fail "missing result"
    Just result -> pure result

attemptExecutionInterpreter
  :: EksDrainInterpreter AttemptExecutionEffects
attemptExecutionInterpreter =
  mkEksDrainInterpreter
    (pure 1_000)
    ( \_ ->
        pure
          ( EksDrainSessionAcquisitionRefused
              (ObservationFailure "sealed attempt must not use legacy session acquisition")
          )
    )
    ( mkEksDrainClientBoundary $ \_ consume ->
        consume
          ( Left
              ( EksDrainClientAccessRefused
                  (ObservationFailure "sealed attempt must not use legacy client boundary")
              )
          )
    )

attemptExecutionBoundary :: EksDrainAttemptBoundary AttemptExecutionEffects
attemptExecutionBoundary =
  mkEksDrainAttemptBoundary $ \identity request consume ->
    AttemptExecutionEffects $ \environment -> do
      modifyIORef'
        (attemptExecutionCalls environment)
        ( <>
            [ AttemptExecutionOpen
                (teardownExecutionIdentityOperationId identity)
                (teardownExecutionIdentityAttemptId identity)
                request
            ]
        )
      let created = case attemptExecutionAccessFailure environment of
            Just failure -> Left failure
            Nothing ->
              Right
                ( attemptExecutionProjection environment
                , attemptExecutionClientEffects
                )
      runAttemptExecutionEffects (consume created) environment

attemptExecutionClientEffects
  :: EksDrainClientEffects AttemptExecutionEffects
attemptExecutionClientEffects =
  EksDrainClientEffects
    { eksDrainClientObserveKubernetesUid =
        tracedAttemptExecution AttemptExecutionObserveUid fakeUidObservation
    , eksDrainClientObserveLoadBalancerServices =
        tracedAttemptExecution
          AttemptExecutionObserveServices
          fakeServiceInventory
    , eksDrainClientObserveIngresses =
        tracedAttemptExecution
          AttemptExecutionObserveIngresses
          fakeIngressInventory
    , eksDrainClientObserveDeletePolicyPvcs =
        tracedAttemptExecution
          AttemptExecutionObserveDeletePolicyPvcs
          fakeDeletePolicyPvcInventory
    , eksDrainClientDeleteLoadBalancerServices =
        tracedAttemptExecution
          AttemptExecutionDeleteServices
          fakeServiceDelete
    , eksDrainClientDeleteIngresses =
        tracedAttemptExecution
          AttemptExecutionDeleteIngresses
          fakeIngressDelete
    , eksDrainClientDeletePvc = \pvc ->
        AttemptExecutionEffects $ \environment -> do
          modifyIORef'
            (attemptExecutionCalls environment)
            (<> [AttemptExecutionDeletePvc pvc])
          cluster <- readIORef (attemptExecutionCluster environment)
          pure
            ( Map.findWithDefault
                EksDrainMutationResponseApplied
                pvc
                (fakePvcDelete cluster)
            )
    , eksDrainClientObservePvc = \pvc ->
        AttemptExecutionEffects $ \environment -> do
          modifyIORef'
            (attemptExecutionCalls environment)
            (<> [AttemptExecutionObservePvc pvc])
          cluster <- readIORef (attemptExecutionCluster environment)
          pure
            ( Map.findWithDefault
                ( EksDrainPvcObservationUnobservable
                    (ObservationFailure "attempt PVC fixture missing" :| [])
                )
                pvc
                (fakePvcObservations cluster)
            )
    }

tracedAttemptExecution
  :: AttemptExecutionCall
  -> (FakeCluster -> value)
  -> AttemptExecutionEffects value
tracedAttemptExecution call project =
  AttemptExecutionEffects $ \environment -> do
    modifyIORef' (attemptExecutionCalls environment) (<> [call])
    project <$> readIORef (attemptExecutionCluster environment)

expectCapturedAttempt
  :: AttemptExecutionCaptured -> IO EksDrainAttemptEvidence
expectCapturedAttempt captured = case captured of
  CapturedAttempt result -> mustRightIO result
  CapturedReadBack _ -> expectationFailure "captured read-back, expected attempt" >> fail "wrong result"

expectCapturedReadBack
  :: AttemptExecutionCaptured -> IO EksDrainTargetReadBackObservation
expectCapturedReadBack captured = case captured of
  CapturedReadBack observation -> pure observation
  CapturedAttempt _ -> expectationFailure "captured attempt, expected read-back" >> fail "wrong result"

isCapturedAttemptRefusal :: AttemptExecutionCaptured -> Bool
isCapturedAttemptRefusal captured = case captured of
  CapturedAttempt (Left _) -> True
  _ -> False

isAttemptMutation :: AttemptExecutionCall -> Bool
isAttemptMutation call = case call of
  AttemptExecutionDeleteServices -> True
  AttemptExecutionDeleteIngresses -> True
  AttemptExecutionDeletePvc _ -> True
  _ -> False

data FakeCluster = FakeCluster
  { fakeUidObservation :: !EksDrainKubernetesUidObservation
  , fakeServiceInventory :: !(EksDrainInventoryResult EksNamespacedName)
  , fakeIngressInventory :: !(EksDrainInventoryResult EksNamespacedName)
  , fakeDeletePolicyPvcInventory :: !(EksDrainInventoryResult EksNamespacedName)
  , fakeServiceDelete :: !EksDrainMutationResponse
  , fakeIngressDelete :: !EksDrainMutationResponse
  , fakePvcDelete :: !(Map EksNamespacedName EksDrainMutationResponse)
  , fakePvcObservations :: !(Map EksNamespacedName EksDrainPvcObservation)
  }

data FakeCall
  = FakeAcquire !CleanupOperationId !CleanupAttemptId
  | FakeOpenClient !CleanupOperationId
  | FakeObserveUid
  | FakeObserveServices
  | FakeObserveIngresses
  | FakeObserveDeletePolicyPvcs
  | FakeDeleteServices
  | FakeDeleteIngresses
  | FakeDeletePvc !EksNamespacedName
  | FakeObservePvc !EksNamespacedName
  deriving (Eq, Show)

defaultFakeCluster :: FakeCluster
defaultFakeCluster =
  FakeCluster
    { fakeUidObservation = EksDrainKubernetesUidPresent fixtureUid
    , fakeServiceInventory = EksDrainInventoryComplete [fixtureService]
    , fakeIngressInventory = EksDrainInventoryComplete [fixtureIngress]
    , fakeDeletePolicyPvcInventory =
        EksDrainInventoryComplete [fixturePvcB, fixturePvcA]
    , fakeServiceDelete = EksDrainMutationResponseApplied
    , fakeIngressDelete = EksDrainMutationResponseApplied
    , fakePvcDelete = Map.empty
    , fakePvcObservations =
        Map.fromList
          [ (fixturePvcA, absentPvc "api/api-data absent")
          , (fixturePvcB, absentPvc "keycloak/postgres-data absent")
          ]
    }

fixtureInterpreter
  :: IO
       ( EksDrainInterpreter IO
       , IORef FakeCluster
       , IORef [FakeCall]
       )
fixtureInterpreter = do
  cluster <- newIORef defaultFakeCluster
  calls <- newIORef []
  pure (fixtureInterpreterFor cluster calls, cluster, calls)

fixtureInterpreterFor
  :: IORef FakeCluster -> IORef [FakeCall] -> EksDrainInterpreter IO
fixtureInterpreterFor cluster calls =
  mkEksDrainInterpreter
    (pure 1_000)
    acquire
    (fakeBoundary cluster calls)
 where
  acquire requested = do
    modifyIORef'
      calls
      ( <>
          [ FakeAcquire
              (eksDrainInvocationOperationId requested)
              (eksDrainInvocationAttemptId requested)
          ]
      )
    pure $ case eksDrainInvocationOperationId requested of
      operation
        | operation == drainEffectOperation ->
            EksDrainSessionAcquired requested fixtureEffectSession
        | operation == drainReadBackOperation ->
            EksDrainSessionAcquired requested fixtureReadBackSession
      _ ->
        EksDrainSessionAcquisitionRefused
          (ObservationFailure "unexpected EKS session operation")

fakeBoundary
  :: IORef FakeCluster -> IORef [FakeCall] -> EksDrainClientBoundary IO
fakeBoundary cluster calls =
  mkEksDrainClientBoundary $ \session consume -> do
    modifyIORef' calls (<> [FakeOpenClient (eksDrainSessionOperationId session)])
    consume (Right (fakeEffects cluster calls))

fakeEffects :: IORef FakeCluster -> IORef [FakeCall] -> EksDrainClientEffects IO
fakeEffects cluster calls =
  EksDrainClientEffects
    { eksDrainClientObserveKubernetesUid =
        traced FakeObserveUid fakeUidObservation
    , eksDrainClientObserveLoadBalancerServices =
        traced FakeObserveServices fakeServiceInventory
    , eksDrainClientObserveIngresses =
        traced FakeObserveIngresses fakeIngressInventory
    , eksDrainClientObserveDeletePolicyPvcs =
        traced FakeObserveDeletePolicyPvcs fakeDeletePolicyPvcInventory
    , eksDrainClientDeleteLoadBalancerServices =
        traced FakeDeleteServices fakeServiceDelete
    , eksDrainClientDeleteIngresses =
        traced FakeDeleteIngresses fakeIngressDelete
    , eksDrainClientDeletePvc = \target -> do
        modifyIORef' calls (<> [FakeDeletePvc target])
        state <- readIORef cluster
        pure
          ( Map.findWithDefault
              EksDrainMutationResponseApplied
              target
              (fakePvcDelete state)
          )
    , eksDrainClientObservePvc = \target -> do
        modifyIORef' calls (<> [FakeObservePvc target])
        state <- readIORef cluster
        pure
          ( Map.findWithDefault
              ( EksDrainPvcObservationUnobservable
                  (ObservationFailure "fake omitted exact PVC observation" :| [])
              )
              target
              (fakePvcObservations state)
          )
    }
 where
  traced :: FakeCall -> (FakeCluster -> value) -> IO value
  traced call project = do
    modifyIORef' calls (<> [call])
    project <$> readIORef cluster

executeApplied
  :: EksDrainInterpreter IO -> IO EksDrainAttemptEvidence
executeApplied interpreter =
  executeCommittedEksDrainIntent
    interpreter
    (effectInvocation attemptA)
    fixtureCommittedIntent
    >>= mustRightIO

effectInvocation :: CleanupAttemptId -> EksDrainInvocationBinding
effectInvocation attempt =
  EksDrainInvocationBinding
    { eksDrainInvocationScope = fixtureScope
    , eksDrainInvocationRunId = fixtureRunId
    , eksDrainInvocationGraphDigest = fixtureGraphDigest
    , eksDrainInvocationOperationId = drainEffectOperation
    , eksDrainInvocationAttemptId = attempt
    }

readBackInvocation :: CleanupAttemptId -> EksDrainInvocationBinding
readBackInvocation attempt =
  (effectInvocation attempt)
    { eksDrainInvocationOperationId = drainReadBackOperation
    }

commitSelectionCompiled :: CompiledDesiredAbsenceProgram 'Cascade
commitSelectionCompiled =
  mustRight
    ( compileDesiredAbsenceGraph
        fixtureRunId
        (LinuxRke2FoundationId "home-linux-rke2")
        (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion "us-east-1")))
        CascadeSurface
    )

commitSelectionEksTarget, commitSelectionAwsTestTarget :: RegisteredTargetBinding
commitSelectionEksTarget = commitSelectionTargetFor AwsEksKey
commitSelectionAwsTestTarget = commitSelectionTargetFor AwsTestKey

commitSelectionTargetFor :: RegisteredResourceKey -> RegisteredTargetBinding
commitSelectionTargetFor key =
  case [ target
       | (_, operation) <- compiledDesiredAbsenceOperations commitSelectionCompiled
       , ObserveRegisteredTarget target <- [operation]
       , registeredTargetKey target == key
       ] of
    [target] -> target
    targets -> error ("expected one compiled target, observed " <> show (length targets))

commitSelectionCommitPlan
  , commitSelectionEffectPlan
  , commitSelectionReadBackPlan
  , commitSelectionReconcilePlan
    :: CleanupNodePlan
commitSelectionCommitPlan =
  commitSelectionPlanFor $ \operation -> case operation of
    CommitEksDrainIntent target -> target == commitSelectionEksTarget
    _ -> False
commitSelectionEffectPlan =
  commitSelectionPlanFor $ \operation -> case operation of
    DrainEksKubernetesResources target -> target == commitSelectionEksTarget
    _ -> False
commitSelectionReadBackPlan =
  commitSelectionPlanFor $ \operation -> case operation of
    ReadBackEksKubernetesDrain target -> target == commitSelectionEksTarget
    _ -> False
commitSelectionReconcilePlan =
  commitSelectionPlanFor $ \operation -> case operation of
    ReconcileRegisteredTargetAbsent target -> target == commitSelectionEksTarget
    _ -> False

commitSelectionPlanFor
  :: (TeardownOperation 'Cascade -> Bool) -> CleanupNodePlan
commitSelectionPlanFor matches =
  case [ plan
       | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph commitSelectionCompiled)
       , Just operation <-
           [compiledOperationForNode (cleanupNodeId plan) commitSelectionCompiled]
       , matches operation
       ] of
    [plan] -> plan
    plans -> error ("expected one compiled plan, observed " <> show (length plans))

commitSelectionCommitOperation
  , commitSelectionIntentReadBackOperation
  , commitSelectionEffectOperation
  , commitSelectionDrainReadBackOperation
  , commitSelectionDestroyOperation
    :: CleanupOperationId
commitSelectionCommitOperation =
  commitSelectionOperationFor $ \operation -> case operation of
    CommitEksDrainIntent target -> target == commitSelectionEksTarget
    _ -> False
commitSelectionIntentReadBackOperation =
  commitSelectionOperationFor $ \operation -> case operation of
    ReadBackEksDrainIntent target -> target == commitSelectionEksTarget
    _ -> False
commitSelectionEffectOperation = cleanupNodeOperationId commitSelectionEffectPlan
commitSelectionDrainReadBackOperation =
  commitSelectionOperationFor $ \operation -> case operation of
    ReadBackEksKubernetesDrain target -> target == commitSelectionEksTarget
    _ -> False
commitSelectionDestroyOperation = cleanupNodeOperationId commitSelectionReconcilePlan

commitSelectionOperationFor
  :: (TeardownOperation 'Cascade -> Bool) -> CleanupOperationId
commitSelectionOperationFor = cleanupNodeOperationId . commitSelectionPlanFor

commitSelectionBinding, commitSelectionBindingWithWrongEffect :: EksDrainOperationBinding
commitSelectionBinding =
  commitSelectionBindingFor commitSelectionEffectOperation
commitSelectionBindingWithWrongEffect =
  commitSelectionBindingFor otherOperation

contextCommittedIntent :: CommittedEksDrainIntent
contextCommittedIntent =
  committed (eksDrainTargetsAbsentIntent destroyDrainEvidence)

contextNoTargetCommittedIntent :: CommittedEksDrainIntent
contextNoTargetCommittedIntent =
  committed
    ( mustRight
        ( prepareEksNoKubernetesTargetIntent
            commitSelectionBinding
            ( verifiedAt
                (ObservationRevision 70)
                (compiledDesiredAbsenceObservationScope commitSelectionCompiled)
                "registered EKS cluster is absent"
            )
        )
    )

contextVerifiedFor
  :: CleanupOperationId
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
contextVerifiedFor operation =
  verifiedForOperation
    operation
    (compiledDesiredAbsenceObservationScope commitSelectionCompiled)
    ("eks-cluster-arn:" <> fixtureArn)

attemptKubernetesObservationRevision :: ObservationRevision
attemptKubernetesObservationRevision = ObservationRevision 71

commitSelectionBindingFor :: CleanupOperationId -> EksDrainOperationBinding
commitSelectionBindingFor effectOperation =
  mustRight
    ( mkEksDrainOperationBinding
        (compiledDesiredAbsenceObservationScope commitSelectionCompiled)
        fixtureRunId
        (cleanupGraphDigest (compiledDesiredAbsenceGraph commitSelectionCompiled))
        commitSelectionCommitOperation
        commitSelectionIntentReadBackOperation
        effectOperation
        commitSelectionDrainReadBackOperation
    )

commitSelectionVerifiedPresent
  :: VerifiedAwsEksObservation 'ObserveEksForDecision
commitSelectionVerifiedPresent =
  verifiedForOperation
    commitSelectionCommitOperation
    (compiledDesiredAbsenceObservationScope commitSelectionCompiled)
    ("eks-cluster-arn:" <> fixtureArn)

destroyVerifiedPresent
  :: VerifiedAwsEksObservation 'ObserveEksForDecision
destroyVerifiedPresent =
  verifiedForOperation
    commitSelectionDestroyOperation
    (compiledDesiredAbsenceObservationScope commitSelectionCompiled)
    ("eks-cluster-arn:" <> fixtureArn)

destroyDrainEvidence :: EksDrainTargetsAbsentEvidence
destroyDrainEvidence =
  mustRight (confirmEksDrainTargetsAbsent attemptEvidence readBack)
 where
  scope = compiledDesiredAbsenceObservationScope commitSelectionCompiled
  initialVerified =
    verifiedAt
      destroyInitialProviderObservationRevision
      scope
      ("eks-cluster-arn:" <> fixtureArn)
  initialSession =
    mustRight
      ( mkEksDrainSession
          1_000
          1_500
          commitSelectionEffectOperation
          scope
          initialVerified
          ( eksKubernetesIdentityObservationFor
              scope
              destroyInitialKubernetesObservationRevision
              fixtureArn
              (EksKubernetesIdentityPresent fixtureUid)
              fixtureProjection
          )
          fixtureProjection
      )
  selection =
    eksDrainTargetSelectionObservationFor
      initialSession
      destroySelectionRevision
      (EksDrainTargetSelectionComplete [fixturePvcB, fixturePvcA])
  intent =
    mustRight
      ( prepareEksKubernetesDrainIntent
          commitSelectionBinding
          initialSession
          selection
      )
  committedIntent = committed intent
  pendingAttempt = beginEksDrainAttempt committedIntent destroyDrainAttempt
  attemptEvidence =
    mustRight
      ( recordEksDrainAttempt
          pendingAttempt
          ( eksDrainAttemptObservationFor
              pendingAttempt
              EksDrainMutationApplied
          )
      )
  absentClass detail = EksDrainResourceClassAbsent (AbsenceEvidence detail)
  absentPvcReadBack target =
    EksDrainPvcReadBack target (EksDrainPvcAbsent (AbsenceEvidence "PVC absent"))
  readBack =
    eksDrainTargetReadBackObservationFor
      attemptEvidence
      ( EksDrainObservedKubernetesTarget
          EksDrainKubernetesTargetReadBack
            { eksDrainReadBackProviderArn = fixtureArn
            , eksDrainReadBackKubernetesUid = fixtureUid
            , eksDrainReadBackEndpointDigest =
                eksDrainSessionEndpointDigest initialSession
            , eksDrainReadBackCertificateAuthorityDigest =
                eksDrainSessionCertificateAuthorityDigest initialSession
            , eksDrainReadBackLoadBalancerServiceClass =
                LoadBalancerServiceClassReadBack
                  (absentClass "all LoadBalancer Services absent")
            , eksDrainReadBackIngressClass =
                IngressClassReadBack (absentClass "all Ingresses absent")
            , eksDrainReadBackDeletePolicyPvcs =
                map absentPvcReadBack [fixturePvcA, fixturePvcB]
            }
      )

destroyDecision :: StackDesiredAbsenceDecision
destroyDecision =
  StackDestroyFromVerifiedPrimary
    AwsEksKey
    ( VerifiedPrimaryCheckpoint
        (CheckpointProvenance "primary://eks-drain-interpreter")
        (CheckpointVersion "primary-v1")
    )

destroyProviderRevision :: ProviderRevision
destroyProviderRevision = mustRight (mkProviderRevision 17)

destroyInitialProviderObservationRevision
  , destroyInitialKubernetesObservationRevision
  , destroySelectionRevision
  , destroyProviderObservationRevision
  , destroyKubernetesObservationRevision
    :: ObservationRevision
destroyInitialProviderObservationRevision = ObservationRevision 40
destroyInitialKubernetesObservationRevision = ObservationRevision 41
destroySelectionRevision = ObservationRevision 52
destroyProviderObservationRevision =
  providerObservationRevisionFor commitSelectionDestroyOperation
destroyKubernetesObservationRevision = ObservationRevision 62

commitSelectionAttempt :: CleanupAttemptId
commitSelectionAttempt =
  mustRight (mkCleanupAttemptId "attempt/eks-drain-commit-selection")

destroyDrainAttempt, destroyAdmissionAttempt :: CleanupAttemptId
destroyDrainAttempt = mustRight (mkCleanupAttemptId "attempt/eks-drain-effect-durable")
destroyAdmissionAttempt = mustRight (mkCleanupAttemptId "attempt/eks-destroy-admission")

expectedProjectionRequest :: EksDrainProjectionRequest
expectedProjectionRequest =
  EksDrainProjectionRequest
    { eksDrainProjectionAccountId = "123456789012"
    , eksDrainProjectionRegion = "us-east-1"
    , eksDrainProjectionClusterName = "aws-eks-test-cluster"
    }

fixtureBinding :: EksDrainOperationBinding
fixtureBinding =
  mustRight
    ( mkEksDrainOperationBinding
        fixtureScope
        fixtureRunId
        fixtureGraphDigest
        intentCommitOperation
        intentReadBackOperation
        drainEffectOperation
        drainReadBackOperation
    )

fixtureIntent :: EksDrainIntent
fixtureIntent =
  mustRight
    ( prepareEksKubernetesDrainIntent
        fixtureBinding
        fixtureEffectSession
        ( eksDrainTargetSelectionObservationFor
            fixtureEffectSession
            (ObservationRevision 41)
            (EksDrainTargetSelectionComplete [fixturePvcB, fixturePvcA])
        )
    )

fixtureCommittedIntent :: CommittedEksDrainIntent
fixtureCommittedIntent = committed fixtureIntent

fixtureNoTargetCommittedIntent :: CommittedEksDrainIntent
fixtureNoTargetCommittedIntent =
  committed
    (mustRight (prepareEksNoKubernetesTargetIntent fixtureBinding fixtureVerifiedAbsent))

committed :: EksDrainIntent -> CommittedEksDrainIntent
committed intent =
  mustRight
    ( confirmEksDrainIntentCommitted
        intent
        (EksDrainIntentReadBackPresent (encodeEksDrainIntent intent))
    )

fixtureEffectSession, fixtureReadBackSession, fixtureRecreatedClusterSession :: EksDrainSession
fixtureEffectSession = fixtureSessionFor drainEffectOperation fixtureUid
fixtureReadBackSession = fixtureSessionFor drainReadBackOperation fixtureUid
fixtureRecreatedClusterSession =
  fixtureSessionFor drainEffectOperation "recreated-kube-system-uid"

fixtureSessionFor :: CleanupOperationId -> Text -> EksDrainSession
fixtureSessionFor operation uid =
  mustRight
    ( mkEksDrainSession
        1_000
        1_500
        operation
        fixtureScope
        fixtureVerifiedPresent
        ( eksKubernetesIdentityObservationFor
            fixtureScope
            (ObservationRevision 14)
            fixtureArn
            (EksKubernetesIdentityPresent uid)
            fixtureProjection
        )
        fixtureProjection
    )

fixtureVerifiedPresent
  :: VerifiedAwsEksObservation 'ObserveEksForDecision
fixtureVerifiedPresent = verifiedFromEvidence ("eks-cluster-arn:" <> fixtureArn)

fixtureVerifiedAbsent
  :: VerifiedAwsEksObservation 'ObserveEksForDecision
fixtureVerifiedAbsent = verifiedFromEvidence "registered EKS cluster is absent"

verifiedFromEvidence
  :: Text -> VerifiedAwsEksObservation 'ObserveEksForDecision
verifiedFromEvidence = verifiedFromEvidenceFor fixtureScope

verifiedFromEvidenceFor
  :: ObservationEvidenceScope
  -> Text
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
verifiedFromEvidenceFor = verifiedAt (ObservationRevision 13)

verifiedForOperation
  :: CleanupOperationId
  -> ObservationEvidenceScope
  -> Text
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
verifiedForOperation operation =
  verifiedAt (providerObservationRevisionFor operation)

providerObservationRevisionFor :: CleanupOperationId -> ObservationRevision
providerObservationRevisionFor operation =
  observationRevisionForProviderDispatchKey
    ( mustRight
        (mkProviderDispatchKey operation ProviderDecisionObservation)
    )

verifiedAt
  :: ObservationRevision
  -> ObservationEvidenceScope
  -> Text
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
verifiedAt revision scope evidence =
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

fixtureProjection :: EksClientAuthProjection
fixtureProjection =
  fixtureProjectionFor
    "https://example.eks.amazonaws.com"
    "Y2EtZGF0YQ=="
    1_800

fixtureExpiredProjection :: EksClientAuthProjection
fixtureExpiredProjection =
  fixtureProjectionFor
    "https://example.eks.amazonaws.com"
    "Y2EtZGF0YQ=="
    900

fixtureRotatedEndpointProjection, fixtureRotatedCaProjection :: EksClientAuthProjection
fixtureRotatedEndpointProjection =
  fixtureProjectionFor
    "https://rotated.eks.amazonaws.com"
    "Y2EtZGF0YQ=="
    1_800
fixtureRotatedCaProjection =
  fixtureProjectionFor
    "https://example.eks.amazonaws.com"
    "cm90YXRlZC1jYQ=="
    1_800

fixtureProjectionFor :: Text -> Text -> Integer -> EksClientAuthProjection
fixtureProjectionFor endpoint ca expiresAt =
  mustRight
    ( testEksClientAuthProjection
        "123456789012"
        "us-east-1"
        "aws-eks-test-cluster"
        fixtureArn
        endpoint
        ca
        "bearer-secret"
        expiresAt
    )

fixtureScope :: ObservationEvidenceScope
fixtureScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope (cleanupRunIdText fixtureRunId))
    (LinuxRke2FoundationId "home-linux-rke2")
    (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion "us-east-1")))
    ReconcileDesiredAbsent

fixtureRunId, otherRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "cleanup-run/eks-drain-interpreter")
otherRunId = mustRight (mkCleanupRunId "cleanup-run/other")

fixtureGraphDigest, otherGraphDigest :: CleanupDigest
fixtureGraphDigest = mustRight (mkCleanupDigest (Text.replicate 64 "a"))
otherGraphDigest = mustRight (mkCleanupDigest (Text.replicate 64 "b"))

intentCommitOperation
  , intentReadBackOperation
  , drainEffectOperation
  , drainReadBackOperation
  , otherOperation
    :: CleanupOperationId
intentCommitOperation = mustOperation "operation/eks-drain-intent-commit"
intentReadBackOperation = mustOperation "operation/eks-drain-intent-readback"
drainEffectOperation = mustOperation "operation/eks-drain-effect"
drainReadBackOperation = mustOperation "operation/eks-drain-readback"
otherOperation = mustOperation "operation/other"

attemptA, attemptB :: CleanupAttemptId
attemptA = mustRight (mkCleanupAttemptId "attempt/eks-drain-a")
attemptB = mustRight (mkCleanupAttemptId "attempt/eks-drain-b")

fixtureArn, fixtureUid :: Text
fixtureArn =
  "arn:aws:eks:us-east-1:123456789012:cluster/aws-eks-test-cluster"
fixtureUid = "eks-kube-system-uid-7"

fixtureService, fixtureIngress, fixturePvcA, fixturePvcB :: EksNamespacedName
fixtureService = mustRight (mkEksNamespacedName "gateway" "public-gateway")
fixtureIngress = mustRight (mkEksNamespacedName "api" "public-api")
fixturePvcA = mustRight (mkEksNamespacedName "api" "api-data")
fixturePvcB = mustRight (mkEksNamespacedName "keycloak" "postgres-data")

absentPvc :: Text -> EksDrainPvcObservation
absentPvc = EksDrainPvcObservedAbsent . AbsenceEvidence

mustOperation :: Text -> CleanupOperationId
mustOperation = mustRight . mkCleanupOperationId

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value

mustRightIO :: (Show err) => Either err value -> IO value
mustRightIO result = case result of
  Left err -> expectationFailure (show err) >> fail "expected Right"
  Right value -> pure value

isRight :: Either left right -> Bool
isRight result = case result of
  Right _ -> True
  Left _ -> False

isLeft :: Either left right -> Bool
isLeft result = case result of
  Left _ -> True
  Right _ -> False

isIncompleteSelection
  :: Either EksDrainTargetSelectionObservation VerifiedEksDrainSelection -> Bool
isIncompleteSelection result = case result of
  Left observation -> case eksDrainSelectionResult observation of
    EksDrainTargetSelectionPartial {} -> True
    EksDrainTargetSelectionUnobservable {} -> True
    EksDrainTargetSelectionComplete {} -> False
  Right _ -> False

isUnobservableOutcome :: EksDrainAttemptOutcome -> Bool
isUnobservableOutcome outcome = case outcome of
  EksDrainMutationUnobservable _ -> True
  _ -> False

isFailedOutcome :: EksDrainAttemptOutcome -> Bool
isFailedOutcome outcome = case outcome of
  EksDrainMutationFailed _ -> True
  _ -> False

isFailedResult :: Either err EksDrainAttemptOutcome -> Bool
isFailedResult result = case result of
  Right (EksDrainMutationFailed _) -> True
  _ -> False

shouldContainAll :: (Eq value, Show value) => [value] -> [value] -> IO ()
shouldContainAll actual expected =
  mapM_ (\value -> actual `shouldContain` [value]) expected

shouldReturnListContain :: (Eq value, Show value) => IO [value] -> [value] -> IO ()
shouldReturnListContain action expected = action >>= (`shouldContainAll` expected)

shouldReturnNoMutation :: IO [FakeCall] -> IO ()
shouldReturnNoMutation action = do
  calls <- action
  filter isMutation calls `shouldBe` []
 where
  isMutation call = case call of
    FakeDeleteServices -> True
    FakeDeleteIngresses -> True
    FakeDeletePvc _ -> True
    _ -> False

countCall :: (Eq value) => value -> [value] -> Int
countCall expected = length . filter (== expected)

classesAbsent :: FakeCluster -> FakeCluster
classesAbsent state =
  state
    { fakeServiceInventory = EksDrainInventoryComplete []
    , fakeIngressInventory = EksDrainInventoryComplete []
    }
