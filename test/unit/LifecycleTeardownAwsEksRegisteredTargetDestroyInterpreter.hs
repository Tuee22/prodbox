{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownAwsEksRegisteredTargetDestroyInterpreter
  ( lifecycleTeardownAwsEksRegisteredTargetDestroyInterpreterSuite
  )
where

import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import EksClientAuthProjectionFixture (testEksClientAuthProjection)
import Prodbox.ControlPlane.AwsStackReaderRepository
import Prodbox.ControlPlane.CleanupRunClient
import Prodbox.ControlPlane.CleanupRunEndpoint
import Prodbox.ControlPlane.EksClientAuthProjection
  ( EksClientAuthProjection
  )
import Prodbox.ControlPlane.EksDrainIntentRepository
  ( EksDrainIntentAuthorityIdentity
  )
import Prodbox.ControlPlane.EksDrainReadBackReceiptClient
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (ProviderIntentExecutionObserved)
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  )
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.CleanupRunRunner
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
import Prodbox.Lifecycle.Teardown.AwsEksRegisteredTargetDestroyInterpreter
import Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
import Prodbox.Lifecycle.Teardown.EksDrainInterpreter
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.ExecutionIdentity
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.ProviderDispatch
import TestSupport

lifecycleTeardownAwsEksRegisteredTargetDestroyInterpreterSuite
  :: SuiteBuilder ()
lifecycleTeardownAwsEksRegisteredTargetDestroyInterpreterSuite =
  describe "receipt-gated registered EKS Provider destruction" $ do
    it "fails closed when the opaque Authority stack-reader bundle is unavailable" $ do
      environment <- newEnvironment False
      runDestroyNode environment
        `shouldSatisfyIO` failedWith "AwsStackReaderClientMissing"
      readIORef (fakeReceiptCalls environment) `shouldReturn` []
      readIORef (fakeSessionCalls environment) `shouldReturn` []
      calls <- readIORef (fakeProviderCalls environment)
      let isSingleEksObservation intents = case intents of
            [ObserveEksClusterIdentity _] -> True
            _ -> False
      map snd calls `shouldSatisfy` isSingleEksObservation

    it "refuses an unsealed direct invocation before any durable reader or mutation" $ do
      environment <- newEnvironment True
      runDirectDestroyNode environment `shouldSatisfyIO` failedWith "EbsBackstopMissing"
      readIORef (fakeReceiptCalls environment) `shouldReturn` []
      readIORef (fakeSessionCalls environment) `shouldReturn` []
      readIORef (fakeProviderCalls environment) `shouldReturn` []

    it "keeps bearer/projection values and side caches outside the production layer" $ do
      source <-
        readFile
          "src/Prodbox/Lifecycle/Teardown/AwsEksRegisteredTargetDestroyInterpreter.hs"
      mapM_
        (source `shouldNotContain`)
        [ "EksClientAuthProjection"
        , "eksClientAuthBearerToken"
        , "IORef"
        , "Map "
        , "unsafePerformIO"
        ]

data FakeEnvironment = FakeEnvironment
  { fakeDirectInvocation :: !Bool
  , fakeReceiptCalls :: !(IORef [EksDrainIntentAuthorityIdentity])
  , fakeSessionCalls :: !(IORef [TeardownExecutionIdentity])
  , fakeProviderCalls :: !(IORef [(ClientSubmissionKey, ProviderIntent)])
  }

newEnvironment :: Bool -> IO FakeEnvironment
newEnvironment directInvocation =
  FakeEnvironment directInvocation
    <$> newIORef []
    <*> newIORef []
    <*> newIORef []

newtype DestroyEffects value = DestroyEffects
  { runDestroyEffects :: FakeEnvironment -> IO value
  }

instance Functor DestroyEffects where
  fmap function (DestroyEffects action) =
    DestroyEffects (fmap function . action)

instance Applicative DestroyEffects where
  pure value = DestroyEffects (const (pure value))
  DestroyEffects function <*> DestroyEffects action =
    DestroyEffects $ \environment -> function environment <*> action environment

instance Monad DestroyEffects where
  DestroyEffects action >>= continue =
    DestroyEffects $ \environment -> do
      value <- action environment
      runDestroyEffects (continue value) environment

instance LifecycleTeardownEffects DestroyEffects where
  executeLifecycleTeardownOperation context operation = case operation of
    ReconcileRegisteredTargetAbsent target
      | registeredTargetKey target == AwsEksKey -> do
          environment <- askEnvironment
          if fakeDirectInvocation environment
            then runDirect context target
            else runThroughRegisteredBoundary context target
    _ -> pure (TeardownNodeRefused "unexpected operation in EKS destroy fixture")
   where
    runDirect executionContext target = do
      environment <- askEnvironment
      let verified = verifiedForContext executionContext
      reconciled <-
        reconcilePresentAwsEksRegisteredTarget
          (destroyInterpreter environment)
          executionContext
          target
          verified
      pure $ case reconciled of
        Left err -> TeardownNodeRefused (Text.pack (show err))
        Right result -> TeardownRegisteredTargetReconcile result

    runThroughRegisteredBoundary executionContext target = do
      environment <- askEnvironment
      reconciled <-
        reconcileAwsRegisteredTargetAbsent
          (registeredInterpreter environment)
          executionContext
          target
      case reconciled of
        Left err -> pure (TeardownNodeRefused (Text.pack (show err)))
        Right result -> pure (TeardownRegisteredTargetReconcile result)

askEnvironment :: DestroyEffects FakeEnvironment
askEnvironment = DestroyEffects pure

liftDestroyIO :: IO value -> DestroyEffects value
liftDestroyIO action = DestroyEffects (const action)

registeredInterpreter
  :: FakeEnvironment -> AwsRegisteredTargetInterpreter DestroyEffects
registeredInterpreter environment =
  AwsRegisteredTargetInterpreter
    { awsRegisteredTargetProviderBoundary = providerBoundary environment
    , awsRegisteredTargetReadStackDecisionInputs = \_ _ _ ->
        pure (Left "EKS present destroy must use AwsStackReaderClient")
    , awsRegisteredTargetReadStackProviderBinding = \_ _ _ ->
        pure (Left "EKS present destroy must use AwsStackReaderClient")
    , awsRegisteredTargetPresentEksDestroyBoundary =
        awsEksRegisteredTargetDestroyBoundary (destroyInterpreter environment)
    }

destroyInterpreter
  :: FakeEnvironment
  -> AwsEksRegisteredTargetDestroyInterpreter DestroyEffects
destroyInterpreter environment =
  mkAwsEksRegisteredTargetDestroyInterpreter
    stackReaderClient
    (receiptClient environment)
    drainInterpreter
    (sessionBoundary environment)
    (providerBoundary environment)
    (\_ -> pure (Right freshDeadline))

stackReaderClient :: AwsStackReaderClient DestroyEffects
stackReaderClient =
  nonAuthorizingAwsStackReaderDiagnosticClient AwsStackReaderClientMissing

receiptClient
  :: FakeEnvironment -> EksDrainReadBackReceiptClient DestroyEffects
receiptClient environment =
  EksDrainReadBackReceiptClient
    { commitAndReadBackEksDrainReceipt = \_ _ _ ->
        pure (Left (EksDrainReadBackReceiptClientRemoteRefused "unexpected commit"))
    , readBackEksDrainReceipt = \_ ->
        pure (Left (EksDrainReadBackReceiptClientRemoteRefused "unexpected read-back"))
    , commitCanonicalEksDrainReceiptFromIntentIdentity = \_ _ ->
        pure (Left (EksDrainReadBackReceiptClientRemoteRefused "unexpected canonical commit"))
    , recoverEksDrainReceiptFromIntentIdentity = \identity -> do
        liftDestroyIO
          (modifyIORef' (fakeReceiptCalls environment) (<> [identity]))
        pure (Left EksDrainReadBackReceiptClientRecoveryMissing)
    }

providerBoundary :: FakeEnvironment -> TeardownProviderBoundary DestroyEffects
providerBoundary environment =
  TeardownProviderBoundary $ \dispatchKey intent -> do
    let submissionKey = providerDispatchSubmissionKey dispatchKey
    liftDestroyIO
      (modifyIORef' (fakeProviderCalls environment) (<> [(submissionKey, intent)]))
    pure $ case intent of
      ObserveEksClusterIdentity {} ->
        TeardownProviderCompleted ("eks-cluster-arn:" <> fixtureArn)
      DestroyRegisteredStack {} ->
        TeardownProviderRefused "diagnostic stack reader must fail before mutation"
      _ -> TeardownProviderRefused "unexpected Provider intent"

drainInterpreter :: EksDrainInterpreter DestroyEffects
drainInterpreter =
  mkEksDrainInterpreter
    (pure currentEpoch)
    ( \_ ->
        pure
          ( EksDrainSessionAcquisitionRefused
              (ObservationFailure "fresh destroy uses its continuation boundary")
          )
    )
    ( mkEksDrainClientBoundary $ \_ consume ->
        consume
          ( Left
              ( EksDrainClientAccessRefused
                  (ObservationFailure "fresh destroy uses its continuation boundary")
              )
          )
    )

sessionBoundary
  :: FakeEnvironment -> EksDrainCommitSelectionBoundary DestroyEffects
sessionBoundary environment =
  mkEksDrainCommitSelectionBoundary $ \identity _request consume -> do
    liftDestroyIO
      (modifyIORef' (fakeSessionCalls environment) (<> [identity]))
    consume (Right (fixtureProjection, sessionEffects))

sessionEffects :: EksDrainClientEffects DestroyEffects
sessionEffects =
  EksDrainClientEffects
    { eksDrainClientObserveKubernetesUid =
        pure (EksDrainKubernetesUidPresent fixtureUid)
    , eksDrainClientObserveLoadBalancerServices = pure (EksDrainInventoryComplete [])
    , eksDrainClientObserveIngresses = pure (EksDrainInventoryComplete [])
    , eksDrainClientObserveDeletePolicyPvcs = unavailableInventory
    , eksDrainClientDeleteLoadBalancerServices = unavailableMutation
    , eksDrainClientDeleteIngresses = unavailableMutation
    , eksDrainClientDeletePvc = const unavailableMutation
    , eksDrainClientObservePvc = \_ ->
        pure
          ( EksDrainPvcObservationUnobservable
              (ObservationFailure "fixture has no PVC targets" :| [])
          )
    }
 where
  unavailableInventory =
    pure
      ( EksDrainInventoryUnobservable
          (ObservationFailure "selection is not available during destroy" :| [])
      )
  unavailableMutation =
    pure
      ( EksDrainMutationResponseRefused
          (ObservationFailure "destroy admission cannot mutate Kubernetes")
      )

runDestroyNode :: FakeEnvironment -> IO CleanupNodeOutcome
runDestroyNode environment = do
  stored <- newIORef fixtureRun
  resumed <-
    resumeDurableCleanupWithContext
      (memoryCleanupRunClient stored)
      fixtureOwner
      (runFixtureNode environment)
      fixtureRun
  case resumed of
    Left err -> expectationFailure (show err) >> fail "durable fixture failed"
    Right _ -> do
      completed <- readIORef stored
      pure (nodeOutcome completed destroyPlan)

runDirectDestroyNode :: FakeEnvironment -> IO CleanupNodeOutcome
runDirectDestroyNode environment =
  runDestroyEffects
    (runCompiledTeardownNode fixtureCompiled destroyPlan)
    environment

runFixtureNode
  :: FakeEnvironment
  -> CleanupNodeExecutionContext
  -> CleanupNodePlan
  -> IO CleanupNodeOutcome
runFixtureNode environment execution plan =
  runDestroyEffects
    (runCompiledTeardownNodeWithContext fixtureCompiled execution plan)
    environment

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
            mapTransition (completeCleanupNode owner fence node attempt outcome current)
      _ -> pure (Left (clientFailure "unexpected cleanup command"))
    case transitioned of
      Left err -> pure (Left err)
      Right updated -> do
        writeIORef stored updated
        pure (Right (Just updated))
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

fixtureCompiled :: CompiledDesiredAbsenceProgram 'Cascade
fixtureCompiled =
  mustRight
    ( compileDesiredAbsenceGraph
        fixtureRunId
        (LinuxRke2FoundationId "home-rke2")
        (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion "us-east-1")))
        CascadeSurface
    )

fixtureRun :: CleanupRun
fixtureRun =
  CleanupRun
    { cleanupRunId = fixtureRunId
    , cleanupRunGraphDigest = cleanupGraphDigest graph
    , cleanupRunGraph = graph
    , cleanupRunLease = CleanupLease fixtureOwner 1 1_000_000
    , cleanupRunPrimaryOutcome = Just CleanupPrimarySucceeded
    , cleanupRunNodeStates =
        Map.fromList
          [ ( cleanupNodeId plan
            , if cleanupNodeId plan == cleanupNodeId destroyPlan
                then CleanupNodePending
                else CleanupNodeCompleted fixtureCompletedAttempt CleanupNodeSucceeded
            )
          | plan <- cleanupGraphNodes graph
          ]
    }
 where
  graph = compiledDesiredAbsenceGraph fixtureCompiled

destroyPlan :: CleanupNodePlan
destroyPlan = planForTag "reconcile-absent/aws-eks"

planForTag :: Text -> CleanupNodePlan
planForTag tag = case matching of
  [plan] -> plan
  plans -> error ("expected one plan for " <> Text.unpack tag <> ", got " <> show (length plans))
 where
  matching =
    [ plan
    | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph fixtureCompiled)
    , Just operation <- [compiledOperationForNode (cleanupNodeId plan) fixtureCompiled]
    , teardownOperationTag operation == tag
    ]

fixtureRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "eks-present-destroy-run")

fixtureOwner :: CleanupOwnerId
fixtureOwner = mustRight (mkCleanupOwnerId "eks-present-destroy-owner")

fixtureCompletedAttempt :: CleanupAttemptId
fixtureCompletedAttempt = mustRight (mkCleanupAttemptId "fixture-completed-attempt")

verifiedForContext
  :: TeardownExecutionContext surface
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
verifiedForContext context =
  decodedVerified request ("eks-cluster-arn:" <> fixtureArn)
 where
  dispatchKey =
    mustRight
      (mkProviderDispatchKey (teardownExecutionOperationId context) ProviderDecisionObservation)
  request =
    mustRight
      ( mkAwsEksDecisionObservationRequest
          (observationRevisionForProviderDispatchKey dispatchKey)
          (teardownExecutionObservationScope context)
      )

decodedVerified
  :: ExactAwsEksObservationRequest purpose
  -> Text
  -> VerifiedAwsEksObservation purpose
decodedVerified request evidence = case decodeAwsEksObservation request result of
  AwsEksObservationDecoded verified -> verified
  AwsEksObservationRejected err _ -> error ("expected verified EKS observation: " <> show err)
 where
  result =
    Right
      ( ProviderIntentExecutionObserved
          (awsEksObservationRequestProviderCoordinate request)
          evidence
      )

fixtureProjection :: EksClientAuthProjection
fixtureProjection =
  mustRight
    ( testEksClientAuthProjection
        "123456789012"
        "us-east-1"
        "aws-eks-test-cluster"
        fixtureArn
        fixtureEndpoint
        fixtureCa
        fixtureBearer
        projectionExpiresAt
    )

currentEpoch, freshDeadline, projectionExpiresAt :: Integer
currentEpoch = 1_000
freshDeadline = 1_500
projectionExpiresAt = 2_000

fixtureArn, fixtureUid, fixtureEndpoint, fixtureCa, fixtureBearer :: Text
fixtureArn = "arn:aws:eks:us-east-1:123456789012:cluster/aws-eks-test-cluster"
fixtureUid = "kube-system-uid-a"
fixtureEndpoint = "https://eks.example.invalid"
fixtureCa = "safe-fixture-ca"
fixtureBearer = "fixture-bearer-must-not-escape"

nodeOutcome :: CleanupRun -> CleanupNodePlan -> CleanupNodeOutcome
nodeOutcome run plan = case Map.lookup (cleanupNodeId plan) (cleanupRunNodeStates run) of
  Just (CleanupNodeCompleted _ outcome) -> outcome
  state -> error ("expected completed node, got " <> show state)

failedWith :: Text -> CleanupNodeOutcome -> Bool
failedWith fragment outcome = case outcome of
  CleanupNodeFailed detail -> fragment `Text.isInfixOf` detail
  _ -> False

shouldSatisfyIO :: IO value -> (value -> Bool) -> Expectation
shouldSatisfyIO action predicate = action >>= (`shouldSatisfy` predicate)

mustRight :: (Show left) => Either left right -> right
mustRight result = case result of
  Left err -> error ("expected Right, got Left " <> show err)
  Right value -> value
