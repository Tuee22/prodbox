{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownEksTeardownExecutor
  ( lifecycleTeardownEksTeardownExecutorSuite
  )
where

import Data.ByteString (ByteString)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.CleanupRunClient
import Prodbox.ControlPlane.CleanupRunEndpoint
import Prodbox.ControlPlane.EksDrainIntentClient
import Prodbox.ControlPlane.EksDrainIntentRepository
import Prodbox.ControlPlane.EksDrainReadBackReceiptClient
import Prodbox.ControlPlane.EksDrainReadBackReceiptRepository
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.CleanupRunRunner
import Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
import Prodbox.Lifecycle.Teardown.EksDrainInterpreter
import Prodbox.Lifecycle.Teardown.EksTeardownExecutor
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.ProviderDispatch
import TestSupport

lifecycleTeardownEksTeardownExecutorSuite :: SuiteBuilder ()
lifecycleTeardownEksTeardownExecutorSuite =
  describe "Sprint 4.85 durable EKS teardown executor" $ do
    it
      "runs the four compiled nodes through durable attempt receipts and closes an already-absent EKS target"
      $ do
        environment <- newFakeEnvironment
        stored <- newIORef fixtureRun
        resumed <-
          resumeDurableCleanupWithContext
            (memoryCleanupRunClient stored)
            fixtureOwner
            (runExecutorNode environment)
            fixtureRun
        resumed `shouldSatisfy` isRight
        finalRun <- readIORef stored
        mapM_
          (\tag -> nodeOutcomeForTag finalRun tag `shouldBe` Just CleanupNodeSucceeded)
          eksDrainTags
        readIORef (fakeProviderCalls environment) `shouldReturnListLength` 1
        readIORef (fakeIntentBytes environment) `shouldSatisfyIO` maybeFalse (not . nullBytes)
        readIORef (fakeReceiptBytes environment) `shouldSatisfyIO` maybeFalse (not . nullBytes)
        readIORef (fakeSessionCalls environment) `shouldReturn` []

    it "refuses every node before effects when called without authoritative dependency receipts" $ do
      environment <- newFakeEnvironment
      mapM_
        ( \tag -> do
            plan <- expectPlan tag
            outcome <-
              runExecutorEffects
                (runCompiledTeardownNode fixtureCompiled plan)
                environment
            outcome `shouldSatisfy` isRequiredAttemptFailure
        )
        eksDrainTags
      readIORef (fakeProviderCalls environment) `shouldReturn` []
      readIORef (fakeIntentBytes environment) `shouldReturn` Nothing
      readIORef (fakeReceiptBytes environment) `shouldReturn` Nothing
      readIORef (fakeSessionCalls environment) `shouldReturn` []

    it "recovers an existing intent and receipt without reselecting or invoking Kubernetes" $ do
      environment <- newFakeEnvironment
      firstStore <- newIORef fixtureRun
      first <-
        resumeDurableCleanupWithContext
          (memoryCleanupRunClient firstStore)
          fixtureOwner
          (runExecutorNode environment)
          fixtureRun
      first `shouldSatisfy` isRight
      writeIORef (fakeProviderCalls environment) []
      completedRun <- readIORef firstStore
      let replayRun = resetEksNodes completedRun
      replayStore <- newIORef replayRun
      replayed <-
        resumeDurableCleanupWithContext
          (memoryCleanupRunClient replayStore)
          fixtureOwner
          (runExecutorNode environment)
          replayRun
      replayed `shouldSatisfy` isRight
      readIORef (fakeProviderCalls environment) `shouldReturn` []
      readIORef (fakeSessionCalls environment) `shouldReturn` []

data FakeEnvironment = FakeEnvironment
  { fakeIntentBytes :: !(IORef (Maybe ByteString))
  , fakeReceiptBytes :: !(IORef (Maybe ByteString))
  , fakeProviderCalls :: !(IORef [Text])
  , fakeSessionCalls :: !(IORef [Text])
  }

newFakeEnvironment :: IO FakeEnvironment
newFakeEnvironment =
  FakeEnvironment
    <$> newIORef Nothing
    <*> newIORef Nothing
    <*> newIORef []
    <*> newIORef []

newtype ExecutorEffects value = ExecutorEffects
  { runExecutorEffects :: FakeEnvironment -> IO value
  }

instance Functor ExecutorEffects where
  fmap function (ExecutorEffects action) =
    ExecutorEffects (fmap function . action)

instance Applicative ExecutorEffects where
  pure value = ExecutorEffects (const (pure value))
  ExecutorEffects function <*> ExecutorEffects action =
    ExecutorEffects $ \environment ->
      function environment <*> action environment

instance Monad ExecutorEffects where
  ExecutorEffects action >>= continue =
    ExecutorEffects $ \environment -> do
      value <- action environment
      runExecutorEffects (continue value) environment

instance LifecycleTeardownEffects ExecutorEffects where
  executeLifecycleTeardownOperation context operation =
    ExecutorEffects $ \environment -> do
      interpreted <-
        runExecutorEffects
          (executeEksTeardownOperation (executorFor environment) context operation)
          environment
      pure
        ( case interpreted of
            Just result -> result
            Nothing -> TeardownNodeRefused "fixture received a non-EKS operation"
        )

liftExecutorIO :: IO value -> ExecutorEffects value
liftExecutorIO action = ExecutorEffects (const action)

executorFor :: FakeEnvironment -> EksTeardownExecutor ExecutorEffects
executorFor environment =
  EksTeardownExecutor
    { eksTeardownRegisteredTargetInterpreter = registeredInterpreter environment
    , eksTeardownDrainInterpreter = drainInterpreter
    , eksTeardownCommitSelectionBoundary =
        mkEksDrainCommitSelectionBoundary $ \_ _ consume -> do
          liftExecutorIO
            (modifyIORef' (fakeSessionCalls environment) (<> ["unexpected commit selection"]))
          consume
            ( Left
                ( EksDrainClientAccessRefused
                    (ObservationFailure "already-absent target must not select Kubernetes")
                )
            )
    , eksTeardownAttemptBoundary =
        mkEksDrainAttemptBoundary $ \_ _ consume -> do
          liftExecutorIO
            (modifyIORef' (fakeSessionCalls environment) (<> ["unexpected drain attempt"]))
          consume
            ( Left
                ( EksDrainClientAccessRefused
                    (ObservationFailure "already-absent target must not acquire attempt auth")
                )
            )
    , eksTeardownIntentClient = intentClient environment
    , eksTeardownReceiptClient = receiptClient environment
    , eksTeardownSelectionParameters = \_ ->
        pure (Left "already-absent target must not request selection parameters")
    }

registeredInterpreter
  :: FakeEnvironment -> AwsRegisteredTargetInterpreter ExecutorEffects
registeredInterpreter environment =
  AwsRegisteredTargetInterpreter
    { awsRegisteredTargetProviderBoundary =
        TeardownProviderBoundary $ \dispatchKey _ -> do
          let submissionKey = providerDispatchSubmissionKey dispatchKey
          liftExecutorIO
            ( modifyIORef'
                (fakeProviderCalls environment)
                (<> [Text.pack (show submissionKey)])
            )
          pure (TeardownProviderCompleted "registered EKS cluster is absent")
    , awsRegisteredTargetReadStackDecisionInputs = \_ _ _ ->
        pure (Left "not used by EKS intent commit")
    , awsRegisteredTargetReadStackProviderBinding = \_ _ _ ->
        pure (Left "not used by EKS intent commit")
    , awsRegisteredTargetPresentEksDestroyBoundary =
        mkAwsEksPresentDestroyBoundary $ \_ _ _ ->
          pure (Left AwsRegisteredTargetEksDrainProofRequired)
    , awsRegisteredTargetDns01ChallengeOwnerDeleteBoundary =
        refusingDns01ChallengeOwnerDeleteBoundary
          "fixture has no Kubernetes access"
    }

drainInterpreter :: EksDrainInterpreter ExecutorEffects
drainInterpreter = mkEksDrainInterpreter (pure 1_000)

intentClient :: FakeEnvironment -> EksDrainIntentClient ExecutorEffects
intentClient environment =
  lifecycleAuthorityEksDrainIntentClient
    EksDrainIntentRepository
      { createOrReplayAuthorityEksDrainIntent = \request -> do
          stored <- liftExecutorIO (readIORef (fakeIntentBytes environment))
          let bytes = eksDrainIntentCommitRequestBytes request
          case stored of
            Nothing -> do
              liftExecutorIO (writeIORef (fakeIntentBytes environment) (Just bytes))
              pure EksDrainIntentCommitCreated
            Just current
              | current == bytes -> pure EksDrainIntentCommitExactReplay
              | otherwise -> pure EksDrainIntentCommitConflict
      , independentlyReadBackAuthorityEksDrainIntent = \_ -> do
          stored <- liftExecutorIO (readIORef (fakeIntentBytes environment))
          pure $ maybe EksDrainIntentAuthorityReadBackMissing EksDrainIntentAuthorityReadBackPresent stored
      }

receiptClient
  :: FakeEnvironment -> EksDrainReadBackReceiptClient ExecutorEffects
receiptClient environment =
  lifecycleAuthorityEksDrainReadBackReceiptClient
    (intentClient environment)
    EksDrainReadBackReceiptRepository
      { createOrReplayAuthorityEksDrainReadBackReceipt = \request -> do
          stored <- liftExecutorIO (readIORef (fakeReceiptBytes environment))
          let bytes = eksDrainReadBackReceiptCommitRequestBytes request
          case stored of
            Nothing -> do
              liftExecutorIO (writeIORef (fakeReceiptBytes environment) (Just bytes))
              pure EksDrainReadBackReceiptCommitCreated
            Just current
              | current == bytes -> pure EksDrainReadBackReceiptCommitExactReplay
              | otherwise -> pure EksDrainReadBackReceiptCommitConflict
      , independentlyReadBackAuthorityEksDrainReadBackReceipt = \_ -> do
          stored <- liftExecutorIO (readIORef (fakeReceiptBytes environment))
          pure $ maybe EksDrainReadBackReceiptMissing EksDrainReadBackReceiptPresent stored
      }

runExecutorNode
  :: FakeEnvironment
  -> CleanupNodeExecutionContext
  -> CleanupNodePlan
  -> IO CleanupNodeOutcome
runExecutorNode environment execution plan =
  runExecutorEffects
    (runCompiledTeardownNodeWithContext fixtureCompiled execution plan)
    environment

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
            , if isEksDrainPlan plan
                then CleanupNodePending
                else CleanupNodeCompleted fixtureCompletedAttempt CleanupNodeSucceeded
            )
          | plan <- cleanupGraphNodes graph
          ]
    }
 where
  graph = compiledDesiredAbsenceGraph fixtureCompiled

resetEksNodes :: CleanupRun -> CleanupRun
resetEksNodes run =
  run
    { cleanupRunLease = CleanupLease fixtureOwner 2 1_000_000
    , cleanupRunNodeStates =
        Map.mapWithKey
          ( \nodeId state ->
              if nodeId `elem` eksDrainNodeIds
                then CleanupNodePending
                else state
          )
          (cleanupRunNodeStates run)
    }

isEksDrainPlan :: CleanupNodePlan -> Bool
isEksDrainPlan plan = cleanupNodeId plan `elem` eksDrainNodeIds

eksDrainNodeIds :: [CleanupNodeId]
eksDrainNodeIds = map (cleanupNodeId . mustPlan) eksDrainTags

eksDrainTags :: [Text]
eksDrainTags =
  [ "commit-eks-drain-intent/aws-eks"
  , "read-back-eks-drain-intent/aws-eks"
  , "drain-eks-kubernetes/aws-eks"
  , "read-back-eks-kubernetes-drain/aws-eks"
  ]

expectPlan :: Text -> IO CleanupNodePlan
expectPlan tag = pure (mustPlan tag)

mustPlan :: Text -> CleanupNodePlan
mustPlan tag = case [ plan
                    | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph fixtureCompiled)
                    , Just operation <- [compiledOperationForNode (cleanupNodeId plan) fixtureCompiled]
                    , teardownOperationTag operation == tag
                    ] of
  [plan] -> plan
  plans -> error ("expected one plan for " <> Text.unpack tag <> ", got " <> show (length plans))

nodeOutcomeForTag :: CleanupRun -> Text -> Maybe CleanupNodeOutcome
nodeOutcomeForTag run tag = case Map.lookup (cleanupNodeId (mustPlan tag)) (cleanupRunNodeStates run) of
  Just (CleanupNodeCompleted _ outcome) -> Just outcome
  _ -> Nothing

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

fixtureRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "eks-teardown-executor-run")

fixtureOwner :: CleanupOwnerId
fixtureOwner = mustRight (mkCleanupOwnerId "eks-teardown-executor-owner")

fixtureCompletedAttempt :: CleanupAttemptId
fixtureCompletedAttempt = mustRight (mkCleanupAttemptId "fixture-completed-attempt")

isRequiredAttemptFailure :: CleanupNodeOutcome -> Bool
isRequiredAttemptFailure outcome = case outcome of
  CleanupNodeFailed detail -> "EksTeardownRequiredAttemptMissing" `Text.isInfixOf` detail
  _ -> False

isRight :: Either left right -> Bool
isRight result = case result of
  Right _ -> True
  Left _ -> False

maybeFalse :: (value -> Bool) -> Maybe value -> Bool
maybeFalse predicate value = maybe False predicate value

nullBytes :: ByteString -> Bool
nullBytes = (== mempty)

shouldSatisfyIO :: IO value -> (value -> Bool) -> Expectation
shouldSatisfyIO action predicate = action >>= (`shouldSatisfy` predicate)

shouldReturnListLength :: IO [value] -> Int -> Expectation
shouldReturnListLength action expected = do
  values <- action
  length values `shouldBe` expected

mustRight :: (Show left) => Either left right -> right
mustRight result = case result of
  Left err -> error ("expected Right, got Left " <> show err)
  Right value -> value
