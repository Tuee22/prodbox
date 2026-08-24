{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownCloudRuntime
  ( lifecycleTeardownCloudRuntimeSuite
  )
where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityOperationClient
import Prodbox.ControlPlane.AwsStackReaderRepository
import Prodbox.ControlPlane.CleanupRunClient
import Prodbox.ControlPlane.CleanupRunEndpoint (CleanupRunCommand (..))
import Prodbox.ControlPlane.EksDrainIntentClient
import Prodbox.ControlPlane.EksDrainIntentRepository
import Prodbox.ControlPlane.EksDrainReadBackReceiptClient
import Prodbox.ControlPlane.EksDrainReadBackReceiptRepository
import Prodbox.ControlPlane.PulumiCheckpointClient
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.CleanupRunRunner
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderRevision
  , ProviderStackConfig
  , mkAwsEksProviderStackConfig
  , mkAwsEksSubzoneProviderStackConfig
  , mkAwsTestProviderStackConfig
  , mkProviderRevision
  )
import Prodbox.Lifecycle.PulumiCheckpoint
import Prodbox.Lifecycle.Teardown.AwsCheckpointInterpreter
import Prodbox.Lifecycle.Teardown.AwsNativeStackFamilyAdapter
  ( encodeAwsNativeStackFamilyEvidence
  )
import Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
import Prodbox.Lifecycle.Teardown.AwsStackReaderInterpreter
import Prodbox.Lifecycle.Teardown.CloudRuntime
import Prodbox.Lifecycle.Teardown.EksDrainInterpreter
import Prodbox.Lifecycle.Teardown.EksTeardownExecutor
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.ProviderDispatch
import TestSupport

lifecycleTeardownCloudRuntimeSuite :: SuiteBuilder ()
lifecycleTeardownCloudRuntimeSuite =
  describe "single lifecycle cloud-operation runtime" $ do
    it "exhaustively claims every cloud constructor and no non-cloud constructor" $ do
      environment <- newEnvironment ProviderExact
      routes <-
        concat
          <$> sequence
            [ checkSurface environment LocalOnlySurface
            , checkSurface environment CascadeSurface
            , checkSurface environment ExplicitPerRunSurface
            , checkSurface environment OperationalTeardownSurface
            , checkSurface environment ExplicitLongLivedSurface
            , checkSurface environment TotalDecommissionSurface
            ]
      Set.fromList routes `shouldBe` Set.fromList [minBound .. maxBound]

    it "normalizes checkpoint and EKS Provider observations to one shared interpreter" $ do
      checkpointEnvironment <- newEnvironment ProviderExact
      let checkpointCompiled = compiledFor CascadeSurface
          restorePlan =
            planForTag
              checkpointCompiled
              "restore-checkpoint/aws-test"
      _ <-
        runCloudEffects
          (runCompiledTeardownNode checkpointCompiled restorePlan)
          checkpointEnvironment
      checkpointCalls <- readIORef (fakeProviderCalls checkpointEnvironment)
      map providerCallOwner checkpointCalls `shouldBe` [SharedProvider]

      eksEnvironment <- newEnvironment ProviderExact
      result <- runEksProtocol eksEnvironment
      result `shouldSatisfy` isRight
      eksCalls <- readIORef (fakeProviderCalls eksEnvironment)
      map providerCallOwner eksCalls `shouldBe` [SharedProvider]

    it "turns every claimed component failure into refusal and never swallows it" $ do
      environment <- newEnvironment ProviderMalformed
      let compiled = compiledFor CascadeSurface
          cases =
            [ ("observe/aws-eks", "registered-target observe component refused")
            , ("restore-checkpoint/aws-test", "checkpoint component refused")
            , ("commit-aws-stack-reader-bundle/aws-test", "AwsStackReaderRecoveryPredecessorInvalid")
            , ("commit-eks-drain-intent/aws-eks", "EksTeardownRequiredAttemptMissing")
            ]
      forM_ cases $ \(tag, expectedDetail) -> do
        writeIORef (fakeDispatchTrace environment) []
        let plan = planForTag compiled tag
        _ <-
          runCloudEffects
            (runCompiledTeardownNode compiled plan)
            environment
        traces <- readIORef (fakeDispatchTrace environment)
        case traces of
          [DispatchTrace actualTag (DispatchRefused detail)] -> do
            actualTag `shouldBe` tag
            detail `shouldSatisfy` Text.isInfixOf expectedDetail
          _ -> expectationFailure ("expected one refusal for " <> Text.unpack tag <> ", got " <> show traces)

data ProviderMode
  = ProviderExact
  | ProviderMalformed

data ProviderOwner
  = SharedProvider
  | StaleProvider
  deriving (Eq, Show)

data ProviderCall = ProviderCall
  { providerCallOwner :: !ProviderOwner
  , providerCallIntent :: !ProviderIntent
  }
  deriving (Eq, Show)

data DispatchShape
  = DispatchNotOwned
  | DispatchRefused !Text
  | DispatchHandled
  deriving (Eq, Show)

data DispatchTrace = DispatchTrace !Text !DispatchShape
  deriving (Eq, Show)

data CloudRoute
  = RegisteredObserveRoute
  | RegisteredReconcileRoute
  | RegisteredReadBackRoute
  | CheckpointObserveRoute
  | CheckpointRestoreRoute
  | CheckpointRecoveryReadBackRoute
  | CheckpointRetireRoute
  | CheckpointRetirementReadBackRoute
  | StackReaderCommitRoute
  | StackReaderReadBackRoute
  | EksIntentCommitRoute
  | EksIntentReadBackRoute
  | EksDrainRoute
  | EksDrainReadBackRoute
  deriving (Bounded, Enum, Eq, Ord, Show)

data FakeEnvironment = FakeEnvironment
  { fakeProviderMode :: !ProviderMode
  , fakeProviderCalls :: !(IORef [ProviderCall])
  , fakeDispatchTrace :: !(IORef [DispatchTrace])
  , fakeIntentBytes :: !(IORef (Maybe ByteString))
  , fakeReceiptBytes :: !(IORef (Maybe ByteString))
  }

newEnvironment :: ProviderMode -> IO FakeEnvironment
newEnvironment mode =
  FakeEnvironment mode
    <$> newIORef []
    <*> newIORef []
    <*> newIORef Nothing
    <*> newIORef Nothing

newtype CloudEffects value = CloudEffects
  { runCloudEffects :: FakeEnvironment -> IO value
  }

instance Functor CloudEffects where
  fmap function (CloudEffects action) =
    CloudEffects (fmap function . action)

instance Applicative CloudEffects where
  pure value = CloudEffects (const (pure value))
  CloudEffects function <*> CloudEffects action =
    CloudEffects $ \environment ->
      function environment <*> action environment

instance Monad CloudEffects where
  CloudEffects action >>= continue =
    CloudEffects $ \environment -> do
      value <- action environment
      runCloudEffects (continue value) environment

instance LifecycleTeardownEffects CloudEffects where
  executeLifecycleTeardownOperation context operation =
    CloudEffects $ \environment -> do
      interpreted <-
        runCloudEffects
          (executeCloudOperation (runtimeFor environment) context operation)
          environment
      modifyIORef'
        (fakeDispatchTrace environment)
        (<> [DispatchTrace (teardownOperationTag operation) (dispatchShape interpreted)])
      pure
        ( case interpreted of
            Nothing -> TeardownNodeRefused "operation is outside the cloud runtime"
            Just result -> result
        )

liftCloudIO :: IO value -> CloudEffects value
liftCloudIO action = CloudEffects (const action)

runtimeFor :: FakeEnvironment -> CloudRuntime CloudEffects
runtimeFor environment =
  mkCloudRuntime
    shared
    checkpoint
    stackReader
    eksExecutor
 where
  shared = registeredInterpreter environment SharedProvider
  stale = registeredInterpreter environment StaleProvider
  checkpoint =
    AwsCheckpointInterpreter
      { awsCheckpointOperationAuthority = refusedAuthorityOperationClient
      , awsCheckpointAuthorities = checkpointAuthorities
      , awsCheckpointRegisteredTargetInterpreter = stale
      }
  stackReader =
    AwsStackReaderInterpreter
      { awsStackReaderClient = refusedStackReaderClient
      , awsStackReaderInputReaders =
          mkAwsStackReaderInputReaders
            (\_ _ -> pure (Left "fixture checkpoint reader refused"))
            (\_ _ -> pure (Left "fixture manifest reader refused"))
            (\_ _ _ -> pure (Left "fixture Provider-binding reader refused"))
      }
  eksExecutor =
    EksTeardownExecutor
      { eksTeardownRegisteredTargetInterpreter = stale
      , eksTeardownDrainInterpreter = refusedDrainInterpreter
      , eksTeardownCommitSelectionBoundary = refusedCommitSelection
      , eksTeardownAttemptBoundary = refusedAttemptBoundary
      , eksTeardownIntentClient = intentClient environment
      , eksTeardownReceiptClient = receiptClient environment
      , eksTeardownSelectionParameters =
          \_ -> pure (Left "fixture target must not request EKS selection parameters")
      }

registeredInterpreter
  :: FakeEnvironment
  -> ProviderOwner
  -> AwsRegisteredTargetInterpreter CloudEffects
registeredInterpreter environment owner =
  AwsRegisteredTargetInterpreter
    { awsRegisteredTargetProviderBoundary =
        TeardownProviderBoundary $ \_ intent -> do
          liftCloudIO
            ( modifyIORef'
                (fakeProviderCalls environment)
                (<> [ProviderCall owner intent])
            )
          pure
            ( TeardownProviderCompleted
                (providerEvidence (fakeProviderMode environment) intent)
            )
    , awsRegisteredTargetReadStackDecisionInputs =
        \_ _ _ -> pure (Left "fixture decision reader refused")
    , awsRegisteredTargetReadStackProviderBinding =
        \operationId key scope ->
          pure
            ( firstText
                ( mkAwsStackProviderBinding
                    operationId
                    key
                    scope
                    providerRevision
                    (providerConfig key)
                )
            )
    , awsRegisteredTargetPresentEksDestroyBoundary =
        mkAwsEksPresentDestroyBoundary $ \_ _ _ ->
          pure (Left AwsRegisteredTargetEksDrainProofRequired)
    , awsRegisteredTargetDns01ChallengeOwnerDeleteBoundary =
        refusingDns01ChallengeOwnerDeleteBoundary
          "fixture has no Kubernetes access"
    }

providerEvidence :: ProviderMode -> ProviderIntent -> Text
providerEvidence mode intent = case mode of
  ProviderMalformed -> "malformed Provider observation"
  ProviderExact -> case intent of
    ObserveEksClusterIdentity _ -> "registered EKS cluster is absent"
    ObserveNativeStackFamily ref _ ->
      mustRight (encodeAwsNativeStackFamilyEvidence ref [])
    _ -> "fixture Provider operation refused by exact decoder"

providerConfig :: RegisteredResourceKey -> ProviderStackConfig
providerConfig key = case key of
  AwsEksKey -> mustRight (mkAwsEksProviderStackConfig "127.0.0.1/32")
  AwsEksSubzoneKey ->
    mustRight (mkAwsEksSubzoneProviderStackConfig "ZCLOUD" "aws.example.test")
  AwsTestKey -> mustRight (mkAwsTestProviderStackConfig "127.0.0.1/32")
  _ -> error ("no Provider stack config for " <> show key)

providerRevision :: ProviderRevision
providerRevision = mustRight (mkProviderRevision 1)

refusedAuthorityOperationClient :: AuthorityOperationClient CloudEffects
refusedAuthorityOperationClient =
  AuthorityOperationClient
    { submitAuthorityOperation = \_ _ ->
        pure (Left (AuthorityOperationRemoteRefused 409 "fixture refusal"))
    , observeAuthorityOperation = \_ ->
        pure (Left (AuthorityOperationRemoteRefused 409 "fixture refusal"))
    }

checkpointAuthorities :: AwsCheckpointAuthorities CloudEffects
checkpointAuthorities =
  mustRight
    ( mkAwsCheckpointAuthorities
        (refusedCheckpointAuthority "aws-eks")
        (refusedCheckpointAuthority "aws-eks-subzone")
        (refusedCheckpointAuthority "aws-test")
    )

refusedCheckpointAuthority :: Text -> PulumiCheckpointAuthority CloudEffects
refusedCheckpointAuthority name =
  PulumiCheckpointAuthority
    { pulumiCheckpointAuthorityRegistration =
        mustRight (registeredPulumiCheckpointByName name)
    , observePulumiCheckpoint = checkpointRefusal
    , observePulumiCheckpointPair = checkpointRefusal
    , publishPulumiCheckpoint = \_ _ _ -> checkpointRefusal
    , retirePulumiCheckpoint = \_ _ _ -> checkpointRefusal
    , restorePulumiCheckpointPrimary = \_ _ _ -> checkpointRefusal
    , readBackPulumiCheckpointRestore = \_ -> checkpointRefusal
    , attemptPulumiCheckpointRetirement = \_ _ _ _ -> checkpointRefusal
    , readBackPulumiCheckpointRetirement = \_ -> checkpointRefusal
    }

checkpointRefusal
  :: CloudEffects (Either PulumiCheckpointClientError value)
checkpointRefusal = pure (Left (PulumiCheckpointRemoteRefused "fixture refusal"))

refusedStackReaderClient :: AwsStackReaderClient CloudEffects
refusedStackReaderClient =
  nonAuthorizingAwsStackReaderDiagnosticClient
    (AwsStackReaderClientRemoteRefused "fixture refusal")

refusedDrainInterpreter :: EksDrainInterpreter CloudEffects
refusedDrainInterpreter =
  mkEksDrainInterpreter (pure 1_000)

refusedCommitSelection :: EksDrainCommitSelectionBoundary CloudEffects
refusedCommitSelection =
  mkEksDrainCommitSelectionBoundary $ \_ _ consume ->
    consume
      ( Left
          ( EksDrainClientAccessRefused
              (ObservationFailure "fixture commit selection refused")
          )
      )

refusedAttemptBoundary :: EksDrainAttemptBoundary CloudEffects
refusedAttemptBoundary =
  mkEksDrainAttemptBoundary $ \_ _ consume ->
    consume
      ( Left
          ( EksDrainClientAccessRefused
              (ObservationFailure "fixture attempt client refused")
          )
      )

intentClient :: FakeEnvironment -> EksDrainIntentClient CloudEffects
intentClient environment =
  lifecycleAuthorityEksDrainIntentClient
    EksDrainIntentRepository
      { createOrReplayAuthorityEksDrainIntent = \request -> do
          stored <- liftCloudIO (readIORef (fakeIntentBytes environment))
          let bytes = eksDrainIntentCommitRequestBytes request
          case stored of
            Nothing -> do
              liftCloudIO (writeIORef (fakeIntentBytes environment) (Just bytes))
              pure EksDrainIntentCommitCreated
            Just current
              | current == bytes -> pure EksDrainIntentCommitExactReplay
              | otherwise -> pure EksDrainIntentCommitConflict
      , independentlyReadBackAuthorityEksDrainIntent = \_ -> do
          stored <- liftCloudIO (readIORef (fakeIntentBytes environment))
          pure
            ( maybe
                EksDrainIntentAuthorityReadBackMissing
                EksDrainIntentAuthorityReadBackPresent
                stored
            )
      }

receiptClient
  :: FakeEnvironment -> EksDrainReadBackReceiptClient CloudEffects
receiptClient environment =
  lifecycleAuthorityEksDrainReadBackReceiptClient
    (intentClient environment)
    EksDrainReadBackReceiptRepository
      { createOrReplayAuthorityEksDrainReadBackReceipt = \request -> do
          stored <- liftCloudIO (readIORef (fakeReceiptBytes environment))
          let bytes = eksDrainReadBackReceiptCommitRequestBytes request
          case stored of
            Nothing -> do
              liftCloudIO (writeIORef (fakeReceiptBytes environment) (Just bytes))
              pure EksDrainReadBackReceiptCommitCreated
            Just current
              | current == bytes -> pure EksDrainReadBackReceiptCommitExactReplay
              | otherwise -> pure EksDrainReadBackReceiptCommitConflict
      , independentlyReadBackAuthorityEksDrainReadBackReceipt = \_ -> do
          stored <- liftCloudIO (readIORef (fakeReceiptBytes environment))
          pure
            ( maybe
                EksDrainReadBackReceiptMissing
                EksDrainReadBackReceiptPresent
                stored
            )
      }

checkSurface
  :: FakeEnvironment
  -> CleanupSurfaceWitness surface
  -> IO [CloudRoute]
checkSurface environment surface = do
  let compiled = compiledFor surface
      plansAndOperations =
        [ (plan, operation)
        | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
        , Just operation <- [compiledOperationForNode (cleanupNodeId plan) compiled]
        ]
  writeIORef (fakeDispatchTrace environment) []
  forM_ plansAndOperations $ \(plan, _) -> do
    _ <- runCloudEffects (runCompiledTeardownNode compiled plan) environment
    pure ()
  traces <- readIORef (fakeDispatchTrace environment)
  length traces `shouldBe` length plansAndOperations
  forM_ (zip plansAndOperations traces) $ \((_, operation), trace) -> do
    dispatchTraceTag trace `shouldBe` teardownOperationTag operation
    dispatchOwned trace `shouldBe` maybe False (const True) (expectedRoute operation)
  pure (mapMaybe (expectedRoute . snd) plansAndOperations)

dispatchTraceTag :: DispatchTrace -> Text
dispatchTraceTag (DispatchTrace tag _) = tag

dispatchOwned :: DispatchTrace -> Bool
dispatchOwned (DispatchTrace _ shape) = case shape of
  DispatchNotOwned -> False
  DispatchRefused _ -> True
  DispatchHandled -> True

dispatchShape :: Maybe (TeardownNodeResult surface) -> DispatchShape
dispatchShape result = case result of
  Nothing -> DispatchNotOwned
  Just (TeardownNodeRefused detail) -> DispatchRefused detail
  Just _ -> DispatchHandled

expectedRoute :: TeardownOperation surface -> Maybe CloudRoute
expectedRoute operation = case operation of
  ObserveRegisteredTarget _ -> Just RegisteredObserveRoute
  ReconcileRegisteredTargetAbsent _ -> Just RegisteredReconcileRoute
  ReadBackRegisteredTargetAbsent _ -> Just RegisteredReadBackRoute
  ObserveStackCheckpointPair _ -> Just CheckpointObserveRoute
  ReconcileStackCheckpointRestore _ -> Just CheckpointRestoreRoute
  ReadBackStackCheckpointRecovery _ -> Just CheckpointRecoveryReadBackRoute
  RetireStackCheckpointPair _ -> Just CheckpointRetireRoute
  ReadBackStackCheckpointRetirement _ -> Just CheckpointRetirementReadBackRoute
  CommitAwsStackReaderBundle _ -> Just StackReaderCommitRoute
  ReadBackAwsStackReaderBundle _ -> Just StackReaderReadBackRoute
  CommitEksDrainIntent _ -> Just EksIntentCommitRoute
  ReadBackEksDrainIntent _ -> Just EksIntentReadBackRoute
  DrainEksKubernetesResources _ -> Just EksDrainRoute
  ReadBackEksKubernetesDrain _ -> Just EksDrainReadBackRoute
  EstablishRecoveryPlane _ -> Nothing
  ReadBackRecoveryPlane _ -> Nothing
  ObserveRecoveryPlaneDisposition _ -> Nothing
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
  RevokeOperationalCredential _ -> Nothing
  ReadBackOperationalCredentialRevocation _ -> Nothing
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

runEksProtocol
  :: FakeEnvironment
  -> IO (Either CleanupRunDriverError CleanupRun)
runEksProtocol environment = do
  let compiled = compiledFor CascadeSurface
      initial = eksProtocolRun compiled
  stored <- newIORef initial
  resumed <-
    resumeDurableCleanupWithContext
      (memoryCleanupRunClient stored)
      fixtureOwner
      ( \execution plan ->
          runCloudEffects
            (runCompiledTeardownNodeWithContext compiled execution plan)
            environment
      )
      initial
  case resumed of
    Left err -> pure (Left err)
    Right _ -> Right <$> readIORef stored

eksProtocolRun
  :: CompiledDesiredAbsenceProgram 'Cascade -> CleanupRun
eksProtocolRun compiled =
  CleanupRun
    { cleanupRunId = fixtureRunId
    , cleanupRunGraphDigest = cleanupGraphDigest graph
    , cleanupRunGraph = graph
    , cleanupRunLease = CleanupLease fixtureOwner 1 1_000_000
    , cleanupRunPrimaryOutcome = Just CleanupPrimarySucceeded
    , cleanupRunNodeStates =
        Map.fromList
          [ ( cleanupNodeId plan
            , if isEksDrainOperation compiled plan
                then CleanupNodePending
                else CleanupNodeCompleted fixtureCompletedAttempt CleanupNodeSucceeded
            )
          | plan <- cleanupGraphNodes graph
          ]
    }
 where
  graph = compiledDesiredAbsenceGraph compiled

isEksDrainOperation
  :: CompiledDesiredAbsenceProgram surface -> CleanupNodePlan -> Bool
isEksDrainOperation compiled plan =
  case compiledOperationForNode (cleanupNodeId plan) compiled of
    Just CommitEksDrainIntent {} -> True
    Just ReadBackEksDrainIntent {} -> True
    Just DrainEksKubernetesResources {} -> True
    Just ReadBackEksKubernetesDrain {} -> True
    _ -> False

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

compiledFor
  :: CleanupSurfaceWitness surface
  -> CompiledDesiredAbsenceProgram surface
compiledFor surface =
  mustRight
    ( compileDesiredAbsenceGraph
        fixtureRunId
        fixtureFoundation
        (awsScopeFor surface)
        Nothing
        surface
    )

awsScopeFor :: CleanupSurfaceWitness surface -> Maybe AwsScope
awsScopeFor surface = case surface of
  LocalOnlySurface -> Nothing
  CascadeSurface -> Just fixtureAwsScope
  ExplicitPerRunSurface -> Just fixtureAwsScope
  OperationalTeardownSurface -> Just fixtureAwsScope
  ExplicitLongLivedSurface -> Just fixtureAwsScope
  TotalDecommissionSurface -> Just fixtureAwsScope

planForTag
  :: CompiledDesiredAbsenceProgram surface
  -> Text
  -> CleanupNodePlan
planForTag compiled tag = case matching of
  [plan] -> plan
  plans ->
    error
      ( "expected one plan for "
          <> Text.unpack tag
          <> ", got "
          <> show (length plans)
      )
 where
  matching =
    [ plan
    | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
    , Just operation <- [compiledOperationForNode (cleanupNodeId plan) compiled]
    , teardownOperationTag operation == tag
    ]

fixtureRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "cloud-runtime-run")

fixtureOwner :: CleanupOwnerId
fixtureOwner = mustRight (mkCleanupOwnerId "cloud-runtime-owner")

fixtureCompletedAttempt :: CleanupAttemptId
fixtureCompletedAttempt =
  mustRight (mkCleanupAttemptId "cloud-runtime-completed-attempt")

fixtureFoundation :: LinuxRke2FoundationId
fixtureFoundation = LinuxRke2FoundationId "home-rke2"

fixtureAwsScope :: AwsScope
fixtureAwsScope =
  AwsScope
    (AwsAccountId "123456789012")
    (AwsRegion (fixtureAwsRegion FixtureCaCentral1))

isRight :: Either left right -> Bool
isRight result = case result of
  Right _ -> True
  Left _ -> False

firstText :: (Show left) => Either left right -> Either Text right
firstText = either (Left . Text.pack . show) Right

mustRight :: (Show left) => Either left right -> right
mustRight result = case result of
  Left err -> error ("expected Right, got Left " <> show err)
  Right value -> value
