{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownAwsCheckpointInterpreter
  ( lifecycleTeardownAwsCheckpointInterpreterSuite
  )
where

import Data.IORef
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.AuthorityOperationClient
import Prodbox.ControlPlane.CleanupRunClient
import Prodbox.ControlPlane.CleanupRunEndpoint
import Prodbox.ControlPlane.PulumiCheckpointClient
import Prodbox.ControlPlane.PulumiCheckpointEndpoint
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , clientSubmissionKeyText
  )
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry
import Prodbox.Lifecycle.Authority.Submission
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupNodeExecutionContext
  , resumeDurableCleanupWithContext
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (ProviderIntent (..))
import Prodbox.Lifecycle.PulumiCheckpoint
import Prodbox.Lifecycle.Teardown.AwsCheckpointInterpreter
import Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
import Prodbox.Lifecycle.Teardown.CheckpointAuthority
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.ProviderDispatch
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownAwsCheckpointInterpreterSuite :: SuiteBuilder ()
lifecycleTeardownAwsCheckpointInterpreterSuite =
  describe "Sprint 4.85 Authority-owned AWS checkpoint interpreter" $ do
    it "accepts a complete current pair without admitting a restore mutation" $ do
      environment <- newEnvironment TargetPresent PairBoth RestoreApplied RetireApplied
      runNode environment (nodeFor RestoreNode AwsTestKey)
        `shouldReturn` CleanupNodeSucceeded
      readIORef (fakeAuthoritySubmissions environment) `shouldReturn` []
      readIORef (fakeCheckpointCalls environment)
        `shouldReturn` [CheckpointPairObserved "aws-test"]

    it "restores an exactly missing primary from the current backup under one stable retry key" $ do
      environment <- newEnvironment TargetPresent PairBackupOnly RestoreApplied RetireApplied
      let restorePlan = nodeFor RestoreNode AwsTestKey
      runNode environment restorePlan `shouldReturn` CleanupNodeSucceeded
      runNode environment restorePlan `shouldReturn` CleanupNodeSucceeded
      submissions <- readIORef (fakeAuthoritySubmissions environment)
      map (clientSubmissionKeyText . fst) submissions
        `shouldSatisfy` twoEqualValues
      map snd submissions `shouldSatisfy` twoEqualValues
      calls <- readIORef (fakeCheckpointCalls environment)
      [ operation
        | CheckpointRestoreAttempted operation <- calls
        ]
        `shouldSatisfy` twoEqualValues

    it "keeps a lost restore response unconfirmed until the independent read-back" $ do
      environment <- newEnvironment TargetPresent PairBackupOnly RestoreResponseLost RetireApplied
      runNode environment (nodeFor RestoreNode AwsTestKey)
        `shouldReturn` CleanupNodeEffectUnconfirmed "checkpoint restore response lost"
      runNode environment (nodeFor RecoveryReadBackNode AwsTestKey)
        `shouldReturn` CleanupNodeSucceeded
      let hasObservationAndReadBack calls = case map snd calls of
            [ObserveRegisteredStack _, ReadBackRegisteredStack _] -> True
            _ -> False
      readIORef (fakeProviderCalls environment)
        `shouldReturnSatisfying` hasObservationAndReadBack
      readIORef (fakeCheckpointCalls environment)
        `shouldReturnSatisfying` hasSeparateRestoreAttemptAndReadBack

    it "uses exact target absence as the no-restore arm even when a stale backup remains" $ do
      environment <- newEnvironment TargetAbsent PairBackupOnly RestoreApplied RetireApplied
      runNode environment (nodeFor RestoreNode AwsTestKey)
        `shouldReturn` CleanupNodeSucceeded
      runNode environment (nodeFor RecoveryReadBackNode AwsTestKey)
        `shouldReturn` CleanupNodeSucceeded
      readIORef (fakeAuthoritySubmissions environment) `shouldReturn` []
      readIORef (fakeCheckpointCalls environment) `shouldReturn` []

    it "refuses missing, partial, and unobservable copies instead of weakening them to absence" $ do
      let cases =
            [ PairBackupMissing
            , PairPrimaryCorrupt
            , PairUnobservable
            ]
      mapM_
        ( \pairFixture -> do
            environment <-
              newEnvironment TargetPresent pairFixture RestoreApplied RetireApplied
            runNode environment (nodeFor RestoreNode AwsTestKey)
              `shouldReturn` CleanupNodeFailed "lifecycle interpreter returned the wrong result kind"
            errors <- readIORef (fakeErrors environment)
            errors `shouldSatisfy` any (Text.isInfixOf "RecoveryIncomplete")
            readIORef (fakeAuthoritySubmissions environment) `shouldReturn` []
        )
        cases
      targetUnknown <-
        newEnvironment TargetUnobservable PairBoth RestoreApplied RetireApplied
      runNode targetUnknown (nodeFor RestoreNode AwsTestKey)
        `shouldReturn` CleanupNodeFailed "lifecycle interpreter returned the wrong result kind"
      readIORef (fakeErrors targetUnknown)
        `shouldReturnSatisfying` any (Text.isInfixOf "TargetObservationIncomplete")

    it "distinguishes definite restore refusal from ambiguous response loss" $ do
      refused <- newEnvironment TargetPresent PairBackupOnly RestoreRefused RetireApplied
      runNode refused (nodeFor RestoreNode AwsTestKey)
        `shouldReturn` CleanupNodeFailed "checkpoint restore was refused"
      lost <- newEnvironment TargetPresent PairBackupOnly RestoreResponseLost RetireApplied
      runNode lost (nodeFor RestoreNode AwsTestKey)
        `shouldReturn` CleanupNodeEffectUnconfirmed "checkpoint restore response lost"

    it "refuses cross-key, cross-scope, and missing-attempt Authority bindings" $ do
      inventory <- newEnvironment TargetPresent PairBoth RestoreApplied RetireApplied
      mkAwsCheckpointAuthorities
        (checkpointAuthorityFor inventory "aws-test")
        (checkpointAuthorityFor inventory "aws-eks-subzone")
        (checkpointAuthorityFor inventory "aws-eks")
        `shouldSatisfy` isClientBindingMismatch

      mapM_
        ( \bindingMode -> do
            environment <-
              newEnvironment TargetPresent PairBackupOnly RestoreResponseLost RetireApplied
            writeIORef (fakeObservedBindingMode environment) bindingMode
            runNode environment (nodeFor RestoreNode AwsTestKey)
              `shouldReturn` CleanupNodeEffectUnconfirmed "checkpoint restore response lost"
            runNode environment (nodeFor RecoveryReadBackNode AwsTestKey)
              `shouldReturn` CleanupNodeFailed "lifecycle interpreter returned the wrong result kind"
            readIORef (fakeErrors environment)
              `shouldReturnSatisfying` any (Text.isInfixOf "ObservedDigestMismatch")
        )
        [ObserveWrongKey, ObserveWrongScope]

      noAttempt <- newEnvironment TargetPresent PairBoth RestoreApplied RetireApplied
      writeIORef (fakeForceRecoveryReadBack noAttempt) True
      runNode noAttempt (nodeFor PairObserveNode AwsTestKey)
        `shouldReturn` CleanupNodeFailed "lifecycle interpreter returned the wrong result kind"
      readIORef (fakeErrors noAttempt)
        `shouldReturnSatisfying` any (Text.isInfixOf "AttemptBindingInvalid []")

    it "refuses a retirement reached without the run's dependant absences" $ do
      -- Sprint 4.89: retiring the reference ends this run's custody of the
      -- capability that made the stack's resources destroyable, and the
      -- discharge is the absence read-back the run already performed for every
      -- resource that checkpoint reaches. The compatibility entrypoint supplies
      -- no successful predecessors, so it cannot reach the effect at all —
      -- which is the rule that "proof-gated effects consume only the durable
      -- path" already states, now enforced for this one.
      environment <-
        newEnvironment TargetAbsent PairBoth RestoreApplied RetireResponseLost
      runNode environment (nodeFor RetirementNode AwsTestKey)
        `shouldReturn` CleanupNodeFailed "lifecycle interpreter returned the wrong result kind"
      readIORef (fakeErrors environment)
        `shouldReturnSatisfying` any (Text.isInfixOf "CustodyUndischarged")

    it "logically retires the active reference and closes response loss only by read-back" $ do
      environment <-
        newEnvironment TargetAbsent PairBoth RestoreApplied RetireResponseLost
      runDurableNode environment (nodeFor RetirementNode AwsTestKey)
        `shouldReturn` CleanupNodeEffectUnconfirmed "checkpoint retirement response lost"
      runNode environment (nodeFor RetirementReadBackNode AwsTestKey)
        `shouldReturn` CleanupNodeSucceeded
      readIORef (fakeCheckpointCalls environment)
        `shouldReturnSatisfying` hasSeparateRetirementAttemptAndReadBack
      source <-
        readFile
          "src/Prodbox/Lifecycle/Teardown/AwsCheckpointInterpreter.hs"
      source `shouldNotContain` "DeleteCheckpoint"
      source `shouldNotContain` "deletePulumiCheckpoint"
      source `shouldNotContain` "AWS_ACCESS_KEY_ID"
      source `shouldNotContain` "dispatchHostProviderIntentFresh"

data TargetFixture
  = TargetPresent
  | TargetAbsent
  | TargetUnobservable

data PairFixture
  = PairBoth
  | PairBackupOnly
  | PairBackupMissing
  | PairPrimaryCorrupt
  | PairUnobservable

data RestoreFixture
  = RestoreApplied
  | RestoreResponseLost
  | RestoreRefused

data RetirementFixture
  = RetireApplied
  | RetireResponseLost

data ObservedBindingMode
  = ObserveExact
  | ObserveWrongKey
  | ObserveWrongScope

data CheckpointCall
  = CheckpointPairObserved !Text
  | CheckpointRestoreAttempted !OperationId
  | CheckpointRestoreReadBack !OperationId
  | CheckpointRetirementAttempted !OperationId
  | CheckpointRetirementReadBack !OperationId
  deriving (Eq, Show)

data FakeEnvironment = FakeEnvironment
  { fakeTargetFixture :: !TargetFixture
  , fakePairFixture :: !PairFixture
  , fakeRestoreFixture :: !RestoreFixture
  , fakeRetirementFixture :: !RetirementFixture
  , fakeProviderCalls :: !(IORef [(ClientSubmissionKey, ProviderIntent)])
  , fakeAuthoritySubmissions :: !(IORef [(ClientSubmissionKey, RequestDigest)])
  , fakeCheckpointCalls :: !(IORef [CheckpointCall])
  , fakeErrors :: !(IORef [Text])
  , fakeObservedBindingMode :: !(IORef ObservedBindingMode)
  , fakeForceRecoveryReadBack :: !(IORef Bool)
  }

newtype CheckpointEffects value = CheckpointEffects
  { runCheckpointEffects :: FakeEnvironment -> IO value
  }

instance Functor CheckpointEffects where
  fmap function (CheckpointEffects action) =
    CheckpointEffects (fmap function . action)

instance Applicative CheckpointEffects where
  pure value = CheckpointEffects (const (pure value))
  CheckpointEffects function <*> CheckpointEffects action =
    CheckpointEffects $ \environment ->
      function environment <*> action environment

instance Monad CheckpointEffects where
  CheckpointEffects action >>= continue =
    CheckpointEffects $ \environment -> do
      value <- action environment
      runCheckpointEffects (continue value) environment

instance LifecycleTeardownEffects CheckpointEffects where
  executeLifecycleTeardownOperation context operation = do
    environment <- askEnvironment
    forceReadBack <- liftCheckpointIO (readIORef (fakeForceRecoveryReadBack environment))
    attempted <- case (forceReadBack, operation) of
      (True, ObserveStackCheckpointPair target) ->
        fmap
          (fmap (Just . TeardownCheckpointRecoveryReadBack))
          ( readBackAwsStackCheckpointRecovery
              (interpreterFor environment)
              context
              target
          )
      _ ->
        executeAwsCheckpointOperation
          (interpreterFor environment)
          context
          operation
    case attempted of
      Right (Just result) -> pure result
      Right Nothing ->
        error "unexpected non-checkpoint operation in checkpoint interpreter test"
      Left err -> do
        let detail = Text.pack (show err)
        liftCheckpointIO (modifyIORef' (fakeErrors environment) (++ [detail]))
        pure (TeardownMutationAttempt (TeardownMutationRefused detail))

newEnvironment
  :: TargetFixture
  -> PairFixture
  -> RestoreFixture
  -> RetirementFixture
  -> IO FakeEnvironment
newEnvironment target pairFixture restoreFixture retirementFixture = do
  providerCalls <- newIORef []
  submissions <- newIORef []
  checkpointCalls <- newIORef []
  errors <- newIORef []
  bindingMode <- newIORef ObserveExact
  forceReadBack <- newIORef False
  pure
    FakeEnvironment
      { fakeTargetFixture = target
      , fakePairFixture = pairFixture
      , fakeRestoreFixture = restoreFixture
      , fakeRetirementFixture = retirementFixture
      , fakeProviderCalls = providerCalls
      , fakeAuthoritySubmissions = submissions
      , fakeCheckpointCalls = checkpointCalls
      , fakeErrors = errors
      , fakeObservedBindingMode = bindingMode
      , fakeForceRecoveryReadBack = forceReadBack
      }

interpreterFor :: FakeEnvironment -> AwsCheckpointInterpreter CheckpointEffects
interpreterFor environment =
  AwsCheckpointInterpreter
    { awsCheckpointOperationAuthority = authorityOperationClientFor environment
    , awsCheckpointAuthorities =
        mustRight
          ( mkAwsCheckpointAuthorities
              (checkpointAuthorityFor environment "aws-eks")
              (checkpointAuthorityFor environment "aws-eks-subzone")
              (checkpointAuthorityFor environment "aws-test")
          )
    , awsCheckpointRegisteredTargetInterpreter =
        registeredTargetInterpreterFor environment
    }

registeredTargetInterpreterFor
  :: FakeEnvironment -> AwsRegisteredTargetInterpreter CheckpointEffects
registeredTargetInterpreterFor environment =
  AwsRegisteredTargetInterpreter
    { awsRegisteredTargetProviderBoundary =
        TeardownProviderBoundary $ \dispatchKey intent -> do
          let submissionKey = providerDispatchSubmissionKey dispatchKey
          liftCheckpointIO
            (modifyIORef' (fakeProviderCalls environment) (++ [(submissionKey, intent)]))
          pure (providerResult environment intent)
    , awsRegisteredTargetReadStackDecisionInputs =
        \_ _ _ -> pure (Left "decision input reader is outside this focused adapter")
    , awsRegisteredTargetReadStackProviderBinding =
        \_ _ _ -> pure (Left "provider binding reader is outside this focused adapter")
    , awsRegisteredTargetPresentEksDestroyBoundary =
        mkAwsEksPresentDestroyBoundary $ \_ _ _ ->
          pure (Left AwsRegisteredTargetEksDrainProofRequired)
    , awsRegisteredTargetDns01ChallengeOwnerDeleteBoundary =
        refusingDns01ChallengeOwnerDeleteBoundary
          "fixture has no Kubernetes access"
    }

providerResult :: FakeEnvironment -> ProviderIntent -> TeardownProviderBoundaryResult
providerResult environment intent = case intent of
  ObserveRegisteredStack _ -> observed
  ReadBackRegisteredStack _ -> observed
  _ -> TeardownProviderRefused "unexpected Provider intent"
 where
  observed = case fakeTargetFixture environment of
    TargetPresent -> TeardownProviderCompleted stackPresentIdentity
    TargetAbsent -> TeardownProviderCompleted stackAbsentEvidence
    TargetUnobservable -> TeardownProviderCompleted "malformed-provider-evidence"

authorityOperationClientFor
  :: FakeEnvironment -> AuthorityOperationClient CheckpointEffects
authorityOperationClientFor environment =
  AuthorityOperationClient
    { submitAuthorityOperation = \submissionKey digest -> do
        liftCheckpointIO
          ( modifyIORef'
              (fakeAuthoritySubmissions environment)
              (++ [(submissionKey, digest)])
          )
        pure (Right (AuthorityOperationAdmissionAccepted (operationFor digest)))
    , observeAuthorityOperation = \submissionKey -> do
        submissions <-
          liftCheckpointIO (readIORef (fakeAuthoritySubmissions environment))
        bindingMode <-
          liftCheckpointIO (readIORef (fakeObservedBindingMode environment))
        pure $ case find ((== submissionKey) . fst) (reverse submissions) of
          Nothing -> Right Nothing
          Just (_, digest) ->
            Right
              ( Just
                  AuthorityOperationObservation
                    { authorityOperationObservedId =
                        observedOperation bindingMode digest
                    , authorityOperationObservedStatus =
                        StatusSettled OperationCompletedOutcome
                    }
              )
    }

observedOperation :: ObservedBindingMode -> RequestDigest -> OperationId
observedOperation bindingMode exactDigest = case bindingMode of
  ObserveExact -> operationFor exactDigest
  ObserveWrongKey -> operationFor (wrongBindingDigest AwsEksSubzoneKey scope)
  ObserveWrongScope -> operationFor (wrongBindingDigest AwsTestKey otherScope)

wrongBindingDigest
  :: RegisteredResourceKey -> ObservationEvidenceScope -> RequestDigest
wrongBindingDigest key selectedScope =
  checkpointAuthorityRequestDigest
    ( mustRight
        ( prepareCheckpointAuthorityOperation
            (cleanupNodeOperationId (nodeFor RestoreNode AwsTestKey))
            key
            selectedScope
            CheckpointPrimaryRestore
            (Just checkpointReference)
        )
    )

checkpointAuthorityFor
  :: FakeEnvironment -> Text -> PulumiCheckpointAuthority CheckpointEffects
checkpointAuthorityFor environment rawName =
  PulumiCheckpointAuthority
    { pulumiCheckpointAuthorityRegistration = checkpointRegistration rawName
    , observePulumiCheckpoint =
        pure
          ( Left
              ( PulumiCheckpointRegistrationMismatch
                  rawName
                  "single-copy observation is outside this focused adapter"
              )
          )
    , observePulumiCheckpointPair = do
        liftCheckpointIO
          ( modifyIORef'
              (fakeCheckpointCalls environment)
              (++ [CheckpointPairObserved rawName])
          )
        pure (Right (pairObservation (fakePairFixture environment)))
    , publishPulumiCheckpoint =
        \_ _ _ -> error "publication is outside this focused adapter"
    , retirePulumiCheckpoint =
        \_ _ _ -> error "legacy retirement is outside this focused adapter"
    , restorePulumiCheckpointPrimary = \operation _ _ -> do
        recordCheckpointCall environment (CheckpointRestoreAttempted operation)
        pure $ Right $ case fakeRestoreFixture environment of
          RestoreApplied -> PulumiCheckpointRestoreApplied checkpointReference
          RestoreResponseLost ->
            PulumiCheckpointRestoreUnavailable "restore response lost"
          RestoreRefused -> PulumiCheckpointRestoreRefused "restore fenced"
    , readBackPulumiCheckpointRestore = \operation -> do
        recordCheckpointCall environment (CheckpointRestoreReadBack operation)
        pure
          ( Right
              ( PulumiCheckpointRestoreConfirmed
                  checkpointReference
                  checkpointReference
              )
          )
    , attemptPulumiCheckpointRetirement = \operation _ _ _ -> do
        recordCheckpointCall environment (CheckpointRetirementAttempted operation)
        pure $ Right $ case fakeRetirementFixture environment of
          RetireApplied -> PulumiCheckpointRetirementApplied
          RetireResponseLost ->
            PulumiCheckpointRetirementAttemptUnavailable
              "retirement response lost"
    , readBackPulumiCheckpointRetirement = \operation -> do
        recordCheckpointCall environment (CheckpointRetirementReadBack operation)
        pure (Right (PulumiCheckpointReferenceRetired (Just checkpointReference)))
    }

recordCheckpointCall :: FakeEnvironment -> CheckpointCall -> CheckpointEffects ()
recordCheckpointCall environment checkpointCall =
  liftCheckpointIO
    (modifyIORef' (fakeCheckpointCalls environment) (++ [checkpointCall]))

pairObservation :: PairFixture -> PulumiCheckpointPairObservation
pairObservation fixture = case fixture of
  PairBoth -> current primaryCurrent backupCurrent
  PairBackupOnly -> current PulumiCheckpointCopyMissing backupCurrent
  PairBackupMissing -> current primaryCurrent PulumiCheckpointCopyMissing
  PairPrimaryCorrupt ->
    current (PulumiCheckpointCopyCorrupt "primary corrupt") backupCurrent
  PairUnobservable -> PulumiCheckpointPairUnobservable "pair unavailable"
 where
  current = PulumiCheckpointPairCurrent checkpointReference
  primaryCurrent =
    PulumiCheckpointCopyCurrent
      (verifiedPulumiCheckpointPrimaryVersion checkpointReference)
  backupCurrent =
    PulumiCheckpointCopyCurrent
      (verifiedPulumiCheckpointBackupVersion checkpointReference)

data CheckpointNodeKind
  = PairObserveNode
  | RestoreNode
  | RecoveryReadBackNode
  | RetirementNode
  | RetirementReadBackNode

runNode :: FakeEnvironment -> CleanupNodePlan -> IO CleanupNodeOutcome
runNode environment plan =
  runCheckpointEffects (runCompiledTeardownNode compiled plan) environment

-- | Sprint 4.89: run one node through the durable path, so it sees the
-- successful predecessors the compiled program made it wait on.
--
-- The checkpoint retirement is proof-gated on the absence read-back of every
-- resource its checkpoint reaches, and those answers live in the run's
-- successful predecessors rather than in a re-observation.
runDurableNode :: FakeEnvironment -> CleanupNodePlan -> IO CleanupNodeOutcome
runDurableNode environment plan = do
  stored <- newIORef (durableRunPending plan)
  resumed <-
    resumeDurableCleanupWithContext
      (memoryCleanupRunClient stored plan)
      durableOwner
      (runDurableFixtureNode environment)
      (durableRunPending plan)
  case resumed of
    Left err -> error ("durable checkpoint fixture failed: " <> show err)
    Right _ -> do
      completed <- readIORef stored
      pure (durableNodeOutcome completed plan)

runDurableFixtureNode
  :: FakeEnvironment
  -> CleanupNodeExecutionContext
  -> CleanupNodePlan
  -> IO CleanupNodeOutcome
runDurableFixtureNode environment execution plan =
  runCheckpointEffects
    (runCompiledTeardownNodeWithContext compiled execution plan)
    environment

-- | Every node succeeded except the one under test.
durableRunPending :: CleanupNodePlan -> CleanupRun
durableRunPending pending =
  CleanupRun
    { cleanupRunId = checkpointCleanupRunId
    , cleanupRunGraphDigest = cleanupGraphDigest graph
    , cleanupRunGraph = graph
    , cleanupRunLease = CleanupLease durableOwner 1 1_000_000
    , cleanupRunPrimaryOutcome = Just CleanupPrimarySucceeded
    , cleanupRunNodeStates =
        Map.fromList
          [ ( cleanupNodeId plan
            , if cleanupNodeId plan == cleanupNodeId pending
                then CleanupNodePending
                else CleanupNodeCompleted durableCompletedAttempt CleanupNodeSucceeded
            )
          | plan <- cleanupGraphNodes graph
          ]
    }
 where
  graph = compiledDesiredAbsenceGraph compiled

durableNodeOutcome :: CleanupRun -> CleanupNodePlan -> CleanupNodeOutcome
durableNodeOutcome run plan =
  case Map.lookup (cleanupNodeId plan) (cleanupRunNodeStates run) of
    Just (CleanupNodeCompleted _ outcome) -> outcome
    other -> error ("durable node did not complete: " <> show other)

durableOwner :: CleanupOwnerId
durableOwner = mustRight (mkCleanupOwnerId "aws-checkpoint-interpreter-owner")

durableCompletedAttempt :: CleanupAttemptId
durableCompletedAttempt =
  mustRight (mkCleanupAttemptId "aws-checkpoint-interpreter-completed")

memoryCleanupRunClient
  :: IORef CleanupRun -> CleanupNodePlan -> CleanupRunClient IO
memoryCleanupRunClient stored _pending =
  CleanupRunClient
    { executeCleanupRunCommand = execute
    , scanNonterminalCleanupRuns = pure (Right [])
    , compactTerminalCleanupRun = \_ _ _ ->
        pure (Left (CleanupRunClientHttpStatus 500 "unexpected compact request"))
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
      _ -> pure (Left (CleanupRunClientHttpStatus 500 "unexpected cleanup command"))
    case transitioned of
      Left err -> pure (Left err)
      Right updated -> do
        writeIORef stored updated
        pure (Right (Just updated))
  applyTransition rawRun rawOwner transition
    | rawRun /= cleanupRunIdText checkpointCleanupRunId =
        pure (Left (CleanupRunClientHttpStatus 500 "cleanup run mismatch"))
    | otherwise = case mkCleanupOwnerId rawOwner of
        Left detail -> pure (Left (CleanupRunClientHttpStatus 500 detail))
        Right owner -> transition owner
  mapIdentity = either (Left . CleanupRunClientHttpStatus 500) Right
  mapTransition =
    either (Left . CleanupRunClientHttpStatus 500 . Text.pack . show) Right

nodeFor :: CheckpointNodeKind -> RegisteredResourceKey -> CleanupNodePlan
nodeFor kind key = case matching of
  [plan] -> plan
  plans ->
    error
      ( "expected one checkpoint node for "
          <> show key
          <> ", got "
          <> show (length plans)
      )
 where
  matching =
    [ plan
    | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
    , Just operation <- [compiledOperationForNode (cleanupNodeId plan) compiled]
    , operationMatches kind key operation
    ]

operationMatches
  :: CheckpointNodeKind
  -> RegisteredResourceKey
  -> TeardownOperation surface
  -> Bool
operationMatches kind key operation = case (kind, operation) of
  (PairObserveNode, ObserveStackCheckpointPair target) ->
    registeredTargetKey target == key
  (RestoreNode, ReconcileStackCheckpointRestore target) ->
    registeredTargetKey target == key
  (RecoveryReadBackNode, ReadBackStackCheckpointRecovery target) ->
    registeredTargetKey target == key
  (RetirementNode, RetireStackCheckpointPair target) ->
    registeredTargetKey target == key
  (RetirementReadBackNode, ReadBackStackCheckpointRetirement target) ->
    registeredTargetKey target == key
  _ -> False

askEnvironment :: CheckpointEffects FakeEnvironment
askEnvironment = CheckpointEffects pure

liftCheckpointIO :: IO value -> CheckpointEffects value
liftCheckpointIO action = CheckpointEffects (const action)

hasSeparateRestoreAttemptAndReadBack :: [CheckpointCall] -> Bool
hasSeparateRestoreAttemptAndReadBack calls = case calls of
  [ CheckpointPairObserved "aws-test"
    , CheckpointRestoreAttempted attempted
    , CheckpointRestoreReadBack observed
    ] -> attempted == observed
  _ -> False

hasSeparateRetirementAttemptAndReadBack :: [CheckpointCall] -> Bool
hasSeparateRetirementAttemptAndReadBack calls = case calls of
  [ CheckpointPairObserved "aws-test"
    , CheckpointRetirementAttempted attempted
    , CheckpointRetirementReadBack observed
    ] -> attempted == observed
  _ -> False

twoEqualValues :: (Eq value) => [value] -> Bool
twoEqualValues values = case values of
  [first, second] -> first == second
  _ -> False

isClientBindingMismatch
  :: Either AwsCheckpointInterpreterError (AwsCheckpointAuthorities CheckpointEffects)
  -> Bool
isClientBindingMismatch result = case result of
  Left AwsCheckpointClientRegistrationMismatch {} -> True
  _ -> False

operationFor :: RequestDigest -> OperationId
operationFor =
  OperationId
    authorityEpochGenesis
    (ClientId "checkpoint-interpreter-test")
    (ClientSequence 1)

checkpointRegistration :: Text -> RegisteredPulumiCheckpoint
checkpointRegistration = mustRight . registeredPulumiCheckpointByName

checkpointReference :: VerifiedPulumiCheckpointRef
checkpointReference =
  mustRight
    ( mkVerifiedPulumiCheckpointRef
        (canonicalPulumiCheckpointDigest checkpoint)
        ciphertextDigest
        "primary-version-1"
        ciphertextDigest
        "backup-version-1"
    )

checkpoint :: CanonicalPulumiCheckpoint
checkpoint =
  mustRight
    ( decodeCanonicalPulumiCheckpoint
        (Set.singleton PulumiFileBackendCheckpoint)
        pulumiCheckpointMaximumBytes
        (TextEncoding.encodeUtf8 "{\"version\":3,\"checkpoint\":{\"sequence\":1}}")
    )

ciphertextDigest :: Text
ciphertextDigest = Text.replicate 64 "a"

compiled :: CompiledDesiredAbsenceProgram 'Cascade
compiled =
  mustRight
    ( compileDesiredAbsenceGraph
        checkpointCleanupRunId
        foundation
        (Just awsScope)
        CascadeSurface
    )

checkpointCleanupRunId :: CleanupRunId
checkpointCleanupRunId = mustRight (mkCleanupRunId "aws-checkpoint-interpreter")

foundation :: LinuxRke2FoundationId
foundation = LinuxRke2FoundationId "linux-rke2/home"

awsScope :: AwsScope
awsScope =
  AwsScope
    (AwsAccountId "111122223333")
    (AwsRegion "ca-central-1")

scope :: ObservationEvidenceScope
scope = compiledDesiredAbsenceObservationScope compiled

otherScope :: ObservationEvidenceScope
otherScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "other-checkpoint-run")
    foundation
    (Just awsScope)
    ReconcileDesiredAbsent

stackPresentIdentity :: Text
stackPresentIdentity = "sha256:" <> Text.replicate 64 "a"

stackAbsentEvidence :: Text
stackAbsentEvidence = "registered stack is absent"

shouldReturnSatisfying :: IO value -> (value -> Bool) -> Expectation
shouldReturnSatisfying action predicate = do
  value <- action
  value `shouldSatisfy` predicate

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error ("expected Right, got " <> show err)
  Right value -> value
