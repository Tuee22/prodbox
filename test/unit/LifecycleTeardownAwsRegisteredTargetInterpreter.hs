{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownAwsRegisteredTargetInterpreter
  ( lifecycleTeardownAwsRegisteredTargetInterpreterSuite
  )
where

import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Authority.AdminAction
  ( PermitFreshness (PermitFresh)
  , RunnerRole (AdminActionRunner)
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , clientSubmissionKeyText
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupNodeOutcome (..)
  , CleanupNodePlan
  , CleanupOperationId
  , CleanupRunId
  , cleanupGraphNodes
  , cleanupNodeId
  , cleanupNodeOperationId
  , cleanupOperationIdText
  , mkCleanupOperationId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderRevision
  , ProviderStackConfig
  , mkAwsEksProviderStackConfig
  , mkAwsEksSubzoneProviderStackConfig
  , mkAwsTestProviderStackConfig
  , mkProviderRevision
  )
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
  ( AwsEksAdapterError (AwsEksEvidenceNotRecognized)
  , AwsEksObservationPurpose (ObserveEksForDecision)
  , VerifiedAwsEksObservation
  , verifiedAwsEksClusterArn
  , verifiedAwsEksExactObservation
  )
import Prodbox.Lifecycle.Teardown.AwsNativeStackFamilyAdapter
  ( encodeAwsNativeStackFamilyEvidence
  )
import Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.LegacyAdoptionPlan
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.OwnershipManifest
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.ProviderDispatch
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownAwsRegisteredTargetInterpreterSuite :: SuiteBuilder ()
lifecycleTeardownAwsRegisteredTargetInterpreterSuite =
  describe "Sprint 4.85 exact registered AWS target interpreter" $ do
    it "uses stable purpose-separated keys for decision and final read-back" $ do
      environment <- newEnvironment BoundaryHealthy DecisionPrimary False
      runNode environment (nodeFor ObserveNode AwsTestKey)
        `shouldReturn` CleanupNodeSucceeded
      runNode environment (nodeFor ReadBackNode AwsTestKey)
        `shouldReturn` CleanupNodeSucceeded
      calls <- readIORef (fakeProviderCalls environment)
      map (clientSubmissionKeyText . fst) calls
        `shouldBe` [ operationText (nodeFor ObserveNode AwsTestKey) <> ":decision-observe"
                   , operationText (nodeFor ReadBackNode AwsTestKey) <> ":absence-readback"
                   ]
      let hasObservationAndReadBack intents = case intents of
            [ObserveNativeStackFamily {}, ObserveNativeStackFamily {}] -> True
            _ -> False
      map snd calls `shouldSatisfy` hasObservationAndReadBack

    it "keeps unavailable and refused observations unobservable, never absent" $ do
      mapM_
        ( \mode -> do
            environment <- newEnvironment mode DecisionPrimary False
            outcome <- runNode environment (nodeFor ObserveNode AwsTestKey)
            outcome
              `shouldBe` CleanupNodeFailed "registered resource is unobservable"
        )
        [ BoundaryDecisionUnavailable
        , BoundaryDecisionRefused
        ]

    it "destroys from exact primary authority and reads absence separately" $ do
      mapM_
        ( \decisionMode -> do
            environment <- newEnvironment BoundaryHealthy decisionMode False
            let reconcilePlan = nodeFor ReconcileNode AwsTestKey
                readBackPlan = nodeFor ReadBackNode AwsTestKey
            runNode environment reconcilePlan `shouldReturn` CleanupNodeSucceeded
            runNode environment readBackPlan `shouldReturn` CleanupNodeSucceeded
            calls <- readIORef (fakeProviderCalls environment)
            let hasDestroySequence intents = case intents of
                  [ ObserveNativeStackFamily {}
                    , DestroyRegisteredStack {}
                    , ObserveNativeStackFamily {}
                    ] -> True
                  _ -> False
            map snd calls `shouldSatisfy` hasDestroySequence
            let firstKeys = map (clientSubmissionKeyText . fst) calls
            runNode environment reconcilePlan `shouldReturn` CleanupNodeSucceeded
            retryCalls <- readIORef (fakeProviderCalls environment)
            drop 3 (map (clientSubmissionKeyText . fst) retryCalls)
              `shouldBe` take 2 firstKeys
        )
        [DecisionPrimary]

    it "reaps provider-native resources from complete adopted-manifest authority" $ do
      environment <- newEnvironment BoundaryHealthy DecisionManifestComplete False
      let reconcilePlan = nodeFor ReconcileNode AwsTestKey
          readBackPlan = nodeFor ReadBackNode AwsTestKey
      runNode environment reconcilePlan `shouldReturn` CleanupNodeSucceeded
      runNode environment readBackPlan `shouldReturn` CleanupNodeSucceeded
      calls <- readIORef (fakeProviderCalls environment)
      let hasNativeReapSequence intents = case intents of
            [ ObserveNativeStackFamily {}
              , ReapNativeStackFamily {}
              , ObserveNativeStackFamily {}
              ] -> True
            _ -> False
      map snd calls `shouldSatisfy` hasNativeReapSequence

    it "does not upgrade a present observation-only manifest into destroy authority" $ do
      environment <-
        newEnvironment BoundaryHealthy DecisionManifestObservedPresent False
      outcome <- runNode environment (nodeFor ReconcileNode AwsTestKey)
      outcome
        `shouldSatisfy` failedWith
          "StackOwnershipManifestPresentWithoutCompleteEvidence"
      readIORef (fakeProviderCalls environment)
        `shouldReturnSatisfying` onlyOneStackObservation

    it "distinguishes definite mutation refusal from an unavailable response" $ do
      refused <- newEnvironment BoundaryMutationRefused DecisionPrimary False
      runNode refused (nodeFor ReconcileNode AwsTestKey)
        `shouldReturn` CleanupNodeFailed "generation fenced"
      unavailable <- newEnvironment BoundaryMutationUnavailable DecisionPrimary False
      runNode unavailable (nodeFor ReconcileNode AwsTestKey)
        `shouldReturn` CleanupNodeEffectUnconfirmed "response unavailable after submit"

    it "does not mutate when checkpoint recovery is required" $ do
      environment <- newEnvironment BoundaryHealthy DecisionBackup False
      outcome <- runNode environment (nodeFor ReconcileNode AwsTestKey)
      outcome `shouldSatisfy` failedWith "AwsRegisteredTargetCheckpointRecoveryRequired"
      calls <- readIORef (fakeProviderCalls environment)
      let isSingleStackObservation intents = case intents of
            [ObserveNativeStackFamily {}] -> True
            _ -> False
      map snd calls `shouldSatisfy` isSingleStackObservation

    it "requires an explicit EKS drain proof before stack destruction" $ do
      environment <- newEnvironment BoundaryHealthy DecisionPrimary False
      outcome <- runNode environment (nodeFor ReconcileNode AwsEksKey)
      outcome `shouldSatisfy` failedWith "AwsRegisteredTargetEksDrainProofRequired"
      calls <- readIORef (fakeProviderCalls environment)
      let isSingleEksObservation intents = case intents of
            [ObserveEksClusterIdentity _] -> True
            _ -> False
      map snd calls `shouldSatisfy` isSingleEksObservation

    it "returns only the opaque exact Provider-decoded EKS decision proof" $ do
      environment <- newEnvironment BoundaryHealthy DecisionPrimary False
      runNode environment (nodeFor ObserveNode AwsEksKey)
        `shouldReturn` CleanupNodeSucceeded
      decisions <- readIORef (fakeVerifiedEksDecisions environment)
      case decisions of
        [Right verified] -> do
          verifiedAwsEksClusterArn verified
            `shouldBe` Just
              ( "arn:aws:eks:"
                  <> (fixtureAwsRegion FixtureCaCentral1)
                  <> ":111122223333:cluster/aws-eks-test-cluster"
              )
          exactObservationResult (verifiedAwsEksExactObservation verified)
            `shouldSatisfy` isPresent
        other -> expectationFailure ("unexpected verified EKS decisions: " <> show other)
      readIORef (fakeProviderCalls environment)
        `shouldReturnSatisfying` onlyOneEksObservation

    it "keeps unavailable, refused, and rejected EKS decisions typed" $ do
      mapM_
        ( \(mode, expected) -> do
            environment <- newEnvironment mode DecisionPrimary False
            outcome <- runNode environment (nodeFor ObserveNode AwsEksKey)
            outcome `shouldSatisfy` failedWith expected
            decisions <- readIORef (fakeVerifiedEksDecisions environment)
            decisions `shouldSatisfy` onlyTypedEksFailure mode
        )
        [ (BoundaryDecisionUnavailable, "ProviderDispatchObservationUnobservable")
        , (BoundaryDecisionRefused, "ProviderDispatchObservationRefused")
        , (BoundaryDecisionMalformed, "AwsEksEvidenceNotRecognized")
        ]

    it "refuses a non-EKS registered binding before Provider dispatch" $ do
      environment <-
        newEnvironment BoundaryDecisionWrongTargetProbe DecisionPrimary False
      outcome <- runNode environment (nodeFor ObserveNode AwsTestKey)
      outcome `shouldSatisfy` failedWith "AwsRegisteredTargetEksKeyMismatch AwsTestKey"
      let isExactKeyMismatch decisions = case decisions of
            [Left (AwsRegisteredTargetEksKeyMismatch AwsTestKey)] -> True
            _ -> False
      readIORef (fakeVerifiedEksDecisions environment)
        `shouldReturnSatisfying` isExactKeyMismatch
      readIORef (fakeProviderCalls environment) `shouldReturn` []

    it "reaps only the registered per-run EBS family and performs a distinct read-back" $ do
      environment <- newEnvironment BoundaryHealthy DecisionPrimary False
      runNode environment (nodeFor ReconcileNode AwsEbsPerRunTestKey)
        `shouldReturn` CleanupNodeSucceeded
      runNode environment (nodeFor ReadBackNode AwsEbsPerRunTestKey)
        `shouldReturn` CleanupNodeSucceeded
      calls <- readIORef (fakeProviderCalls environment)
      map snd calls
        `shouldBe` [ ObserveTestEbsVolumes "aws-eks-test-cluster"
                   , ReapTestEbsVolumes "aws-eks-test-cluster"
                   , ObserveTestEbsVolumes "aws-eks-test-cluster"
                   ]
      let submissionKeys = map (clientSubmissionKeyText . fst) calls
          areDistinctSubmissionKeys keys = case keys of
            [decisionKey, mutationKey, readBackKey] ->
              decisionKey /= mutationKey
                && mutationKey /= readBackKey
                && decisionKey /= readBackKey
            _ -> False
      submissionKeys `shouldSatisfy` areDistinctSubmissionKeys

    it "refuses stale decision and provider bindings before mutation" $ do
      staleDecision <- newEnvironment BoundaryHealthy DecisionWrongOperation False
      decisionOutcome <- runNode staleDecision (nodeFor ReconcileNode AwsTestKey)
      decisionOutcome
        `shouldSatisfy` failedWith "AwsRegisteredTargetDecisionInputsBindingMismatch"
      readIORef (fakeProviderCalls staleDecision)
        `shouldReturnSatisfying` onlyOneStackObservation

      staleProvider <- newEnvironment BoundaryHealthy DecisionPrimary True
      providerOutcome <- runNode staleProvider (nodeFor ReconcileNode AwsTestKey)
      providerOutcome
        `shouldSatisfy` failedWith "AwsRegisteredTargetProviderBindingMismatch"
      readIORef (fakeProviderCalls staleProvider)
        `shouldReturn` []

    it "contains no fresh submission, host AWS credential, or unsafe escape hatch" $ do
      source <-
        readFile
          "src/Prodbox/Lifecycle/Teardown/AwsRegisteredTargetInterpreter.hs"
      source `shouldNotContain` "dispatchHostProviderIntentFresh"
      source `shouldNotContain` "dispatchAuthenticatedProviderIntentFresh"
      source `shouldNotContain` "AWS_ACCESS_KEY_ID"
      source `shouldNotContain` "AWS_SECRET_ACCESS_KEY"
      source `shouldNotContain` "unsafePerformIO"
      source `shouldNotContain` "undefined"
      source `shouldContain` "observeVerifiedAwsEksForDecision"
      source
        `shouldContain` "VerifiedAwsEksObservation 'ObserveEksForDecision"
      adapter <- readFile "src/Prodbox/Lifecycle/Teardown/AwsEksAdapter.hs"
      adapter `shouldNotContain` "VerifiedAwsEksObservation (.."

data NodeKind = ObserveNode | ReconcileNode | ReadBackNode

data BoundaryMode
  = BoundaryHealthy
  | BoundaryDecisionUnavailable
  | BoundaryDecisionRefused
  | BoundaryDecisionMalformed
  | BoundaryDecisionWrongTargetProbe
  | BoundaryMutationUnavailable
  | BoundaryMutationRefused

data DecisionMode
  = DecisionPrimary
  | DecisionManifestObservedPresent
  | DecisionManifestComplete
  | DecisionBackup
  | DecisionWrongOperation

data FakeEnvironment = FakeEnvironment
  { fakeBoundaryMode :: !BoundaryMode
  , fakeDecisionMode :: !DecisionMode
  , fakeWrongProviderBinding :: !Bool
  , fakeProviderCalls :: !(IORef [(ClientSubmissionKey, ProviderIntent)])
  , fakeVerifiedEksDecisions
      :: !( IORef
              [ Either
                  AwsRegisteredTargetInterpreterError
                  (VerifiedAwsEksObservation 'ObserveEksForDecision)
              ]
          )
  }

newtype InterpreterEffects value = InterpreterEffects
  { runInterpreterEffects :: FakeEnvironment -> IO value
  }

instance Functor InterpreterEffects where
  fmap function (InterpreterEffects action) =
    InterpreterEffects (fmap function . action)

instance Applicative InterpreterEffects where
  pure value = InterpreterEffects (const (pure value))
  InterpreterEffects function <*> InterpreterEffects action =
    InterpreterEffects $ \environment ->
      function environment <*> action environment

instance Monad InterpreterEffects where
  InterpreterEffects action >>= continue =
    InterpreterEffects $ \environment -> do
      value <- action environment
      runInterpreterEffects (continue value) environment

instance LifecycleTeardownEffects InterpreterEffects where
  executeLifecycleTeardownOperation context operation = do
    environment <- askEnvironment
    let interpreter = interpreterFor environment
    case operation of
      ObserveRegisteredTarget target
        | registeredTargetKey target == AwsEksKey
            || probesWrongEksTarget environment -> do
            observed <- observeVerifiedAwsEksForDecision interpreter context target
            liftInterpreterIO
              (modifyIORef' (fakeVerifiedEksDecisions environment) (++ [observed]))
            pure $ case observed of
              Left err -> TeardownNodeRefused (Text.pack (show err))
              Right verified ->
                TeardownExactResourceObservation
                  (verifiedAwsEksExactObservation verified)
      ObserveRegisteredTarget target -> do
        observed <- observeAwsRegisteredTarget interpreter context target
        pure (TeardownExactResourceObservation (mustRight observed))
      ReconcileRegisteredTargetAbsent target -> do
        reconciled <- reconcileAwsRegisteredTargetAbsent interpreter context target
        pure (TeardownRegisteredTargetReconcile (mustRight reconciled))
      ReadBackRegisteredTargetAbsent target -> do
        observed <- readBackAwsRegisteredTargetAbsent interpreter context target
        pure (TeardownExactResourceObservation (mustRight observed))
      _ -> error "unexpected operation in registered-target interpreter test"

newEnvironment
  :: BoundaryMode -> DecisionMode -> Bool -> IO FakeEnvironment
newEnvironment boundaryMode decisionMode wrongProviderBinding = do
  calls <- newIORef []
  verifiedEksDecisions <- newIORef []
  pure
    FakeEnvironment
      { fakeBoundaryMode = boundaryMode
      , fakeDecisionMode = decisionMode
      , fakeWrongProviderBinding = wrongProviderBinding
      , fakeProviderCalls = calls
      , fakeVerifiedEksDecisions = verifiedEksDecisions
      }

interpreterFor
  :: FakeEnvironment -> AwsRegisteredTargetInterpreter InterpreterEffects
interpreterFor environment =
  AwsRegisteredTargetInterpreter
    { awsRegisteredTargetProviderBoundary =
        TeardownProviderBoundary $ \dispatchKey intent -> do
          let submissionKey = providerDispatchSubmissionKey dispatchKey
          liftInterpreterIO
            (modifyIORef' (fakeProviderCalls environment) (++ [(submissionKey, intent)]))
          pure (providerResponse environment submissionKey intent)
    , awsRegisteredTargetReadStackDecisionInputs =
        \operationId key scope ->
          pure (firstText (decisionInputs environment operationId key scope))
    , awsRegisteredTargetReadStackProviderBinding =
        \operationId key scope ->
          pure (firstText (providerBinding environment operationId key scope))
    , awsRegisteredTargetPresentEksDestroyBoundary =
        mkAwsEksPresentDestroyBoundary $ \_ _ _ ->
          pure (Left AwsRegisteredTargetEksDrainProofRequired)
    , awsRegisteredTargetDns01ChallengeOwnerDeleteBoundary =
        refusingDns01ChallengeOwnerDeleteBoundary
          "fixture has no Kubernetes access"
    }

providerResponse
  :: FakeEnvironment
  -> ClientSubmissionKey
  -> ProviderIntent
  -> TeardownProviderBoundaryResult
providerResponse environment submissionKey intent
  | isDecisionSubmission submissionKey = case fakeBoundaryMode environment of
      BoundaryDecisionUnavailable ->
        TeardownProviderUnavailable "decision observer unavailable"
      BoundaryDecisionRefused ->
        TeardownProviderRefused "decision observer refused"
      BoundaryDecisionMalformed ->
        TeardownProviderCompleted "malformed EKS decision evidence"
      _ -> observedResponse submissionKey intent
  | isMutation intent = case fakeBoundaryMode environment of
      BoundaryMutationUnavailable ->
        TeardownProviderUnavailable "response unavailable after submit"
      BoundaryMutationRefused -> TeardownProviderRefused "generation fenced"
      _ -> TeardownProviderCompleted "mutation accepted"
  | otherwise = observedResponse submissionKey intent

observedResponse
  :: ClientSubmissionKey -> ProviderIntent -> TeardownProviderBoundaryResult
observedResponse submissionKey intent = case intent of
  ObserveNativeStackFamily ref _ ->
    TeardownProviderCompleted
      ( mustRight
          ( encodeAwsNativeStackFamilyEvidence
              ref
              [ "vpc/vpc-fixture"
              | not
                  ( Text.isSuffixOf
                      ":absence-readback"
                      (clientSubmissionKeyText submissionKey)
                  )
              ]
          )
      )
  ObserveEksClusterIdentity _ ->
    TeardownProviderCompleted eksEvidence
  ObserveTestEbsVolumes _ ->
    TeardownProviderCompleted ebsEvidence
  _ -> TeardownProviderCompleted "mutation accepted"
 where
  ebsEvidence
    | Text.isSuffixOf ":absence-readback" (clientSubmissionKeyText submissionKey) =
        ebsAbsentEvidence
    | otherwise = ebsPresentEvidence
  eksEvidence
    | Text.isSuffixOf ":absence-readback" (clientSubmissionKeyText submissionKey) =
        "registered EKS cluster is absent"
    | otherwise =
        ( "eks-cluster-arn:arn:aws:eks:"
            <> (fixtureAwsRegion FixtureCaCentral1)
            <> ":111122223333:cluster/aws-eks-test-cluster"
        )

isDecisionSubmission :: ClientSubmissionKey -> Bool
isDecisionSubmission =
  Text.isSuffixOf ":decision-observe" . clientSubmissionKeyText

isMutation :: ProviderIntent -> Bool
isMutation intent = case intent of
  DestroyRegisteredStack {} -> True
  ReapNativeStackFamily {} -> True
  ReapTestEbsVolumes {} -> True
  _ -> False

probesWrongEksTarget :: FakeEnvironment -> Bool
probesWrongEksTarget environment = case fakeBoundaryMode environment of
  BoundaryDecisionWrongTargetProbe -> True
  _ -> False

decisionInputs
  :: FakeEnvironment
  -> CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> Either AwsRegisteredTargetInterpreterError AwsStackDecisionInputs
decisionInputs environment operationId key scope =
  mkAwsStackDecisionInputs
    boundOperationId
    key
    scope
    checkpoints
    manifest
 where
  boundOperationId = case fakeDecisionMode environment of
    DecisionWrongOperation -> otherOperationId
    _ -> operationId
  checkpoints = case fakeDecisionMode environment of
    DecisionBackup -> checkpointPair key scope FixtureAbsent FixturePresent
    DecisionManifestObservedPresent ->
      checkpointPair key scope FixtureAbsent FixtureAbsent
    DecisionManifestComplete ->
      checkpointPair key scope FixtureAbsent FixtureAbsent
    _ -> checkpointPair key scope FixturePresent FixtureAbsent
  manifest = case fakeDecisionMode environment of
    DecisionManifestObservedPresent ->
      observationOnlyManifestEvidence key scope (OwnershipManifestPresent manifestVersion)
    DecisionManifestComplete -> completeManifestEvidence key scope
    _ -> observationOnlyManifestEvidence key scope OwnershipManifestAbsent

data CheckpointFixture = FixtureAbsent | FixturePresent

checkpointPair
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> CheckpointFixture
  -> CheckpointFixture
  -> CheckpointPairObservation
checkpointPair key scope primary backup =
  mustRight
    ( mkCheckpointPairObservation
        key
        scope
        (checkpointObservation PrimaryCheckpointCopy primary)
        (checkpointObservation BackupCheckpointCopy backup)
    )
 where
  checkpointObservation copy fixture =
    CheckpointObservation
      { checkpointObservationStackKey = key
      , checkpointObservationCopy = copy
      , checkpointObservationProvenance = case copy of
          PrimaryCheckpointCopy -> CheckpointProvenance "checkpoint/primary"
          BackupCheckpointCopy -> CheckpointProvenance "checkpoint/backup"
      , checkpointObservationEvidenceScope = scope
      , checkpointObservationResult = case fixture of
          FixtureAbsent -> CheckpointAbsent
          FixturePresent ->
            CheckpointPresent (CheckpointVersion "checkpoint/version-1")
      }

observationOnlyManifestEvidence
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> OwnershipManifestResult
  -> OwnershipManifestDecisionEvidence
observationOnlyManifestEvidence key scope result =
  ownershipManifestObservationOnly
    ( OwnershipManifestObservation
        { ownershipManifestStackKey = key
        , ownershipManifestProvenance = manifestProvenance
        , ownershipManifestEvidenceScope = scope
        , ownershipManifestResult = result
        }
    )

completeManifestEvidence
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> OwnershipManifestDecisionEvidence
completeManifestEvidence key scope =
  mustRight
    ( completeConfirmedLegacyAdoptionManifestReadBack
        manifestProvenance
        manifestVersion
        write
    )
 where
  plan =
    mustRight
      ( planLegacyAdoption
          CascadeSurface
          key
          scope
          [ exactResourceObservationFor
              (mustIdentity key)
              (ObservationRevision 1)
              scope
              ( ExactResourcePresent
                  ( ExactResourceInventory
                      (ObservedResourceIdentity "vpc/vpc-fixture" :| [])
                  )
              )
          ]
      )
  permit =
    mustRight
      ( admitAdminLegacyAdoptionPermit
          PermitFresh
          AdminLegacyAdoptionPermitRequest
            { adminLegacyPermitRequestAudience = AdminActionRunner
            , adminLegacyPermitRequestStackKey = key
            , adminLegacyPermitRequestPlanDigest = legacyAdoptionPlanDigestOf plan
            , adminLegacyPermitRequestNonce = "fixture-confirmation"
            }
      )
  confirmed = mustRight (confirmLegacyAdoptionPlan permit plan)
  write = mustRight (confirmedLegacyAdoptionManifestWrite CascadeSurface confirmed)

providerBinding
  :: FakeEnvironment
  -> CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> Either AwsRegisteredTargetInterpreterError AwsStackProviderBinding
providerBinding environment operationId key scope =
  mkAwsStackProviderBinding
    (if fakeWrongProviderBinding environment then otherOperationId else operationId)
    key
    scope
    providerRevision
    (providerConfig key)

providerConfig :: RegisteredResourceKey -> ProviderStackConfig
providerConfig key = case key of
  AwsEksKey -> mustRight (mkAwsEksProviderStackConfig "127.0.0.1/32")
  AwsEksSubzoneKey ->
    mustRight
      (mkAwsEksSubzoneProviderStackConfig "Z123456789" "test.example.com")
  AwsTestKey -> mustRight (mkAwsTestProviderStackConfig "127.0.0.1/32")
  _ -> error ("no Provider stack config for " <> show key)

runNode
  :: FakeEnvironment -> CleanupNodePlan -> IO CleanupNodeOutcome
runNode environment plan =
  runInterpreterEffects (runCompiledTeardownNode compiled plan) environment

askEnvironment :: InterpreterEffects FakeEnvironment
askEnvironment = InterpreterEffects pure

liftInterpreterIO :: IO value -> InterpreterEffects value
liftInterpreterIO action = InterpreterEffects (const action)

nodeFor :: NodeKind -> RegisteredResourceKey -> CleanupNodePlan
nodeFor kind key = case matching of
  [plan] -> plan
  plans ->
    error
      ( "expected one "
          <> showNodeKind kind
          <> " node for "
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
  :: NodeKind -> RegisteredResourceKey -> TeardownOperation surface -> Bool
operationMatches kind key operation = case (kind, operation) of
  (ObserveNode, ObserveRegisteredTarget target) -> registeredTargetKey target == key
  (ReconcileNode, ReconcileRegisteredTargetAbsent target) ->
    registeredTargetKey target == key
  (ReadBackNode, ReadBackRegisteredTargetAbsent target) ->
    registeredTargetKey target == key
  _ -> False

showNodeKind :: NodeKind -> String
showNodeKind kind = case kind of
  ObserveNode -> "observe"
  ReconcileNode -> "reconcile"
  ReadBackNode -> "read-back"

operationText :: CleanupNodePlan -> Text
operationText = cleanupOperationIdText . cleanupNodeOperationId

failedWith :: Text -> CleanupNodeOutcome -> Bool
failedWith needle outcome = case outcome of
  CleanupNodeFailed detail -> needle `Text.isInfixOf` detail
  _ -> False

onlyOneStackObservation
  :: [(ClientSubmissionKey, ProviderIntent)] -> Bool
onlyOneStackObservation calls = case map snd calls of
  [ObserveNativeStackFamily {}] -> True
  _ -> False

onlyOneEksObservation
  :: [(ClientSubmissionKey, ProviderIntent)] -> Bool
onlyOneEksObservation calls = case map snd calls of
  [ObserveEksClusterIdentity _] -> True
  _ -> False

isPresent :: ExactObservationResult -> Bool
isPresent result = case result of
  ExactResourcePresent _ -> True
  _ -> False

onlyTypedEksFailure
  :: BoundaryMode
  -> [ Either
         AwsRegisteredTargetInterpreterError
         (VerifiedAwsEksObservation 'ObserveEksForDecision)
     ]
  -> Bool
onlyTypedEksFailure mode decisions = case (mode, decisions) of
  ( BoundaryDecisionUnavailable
    , [Left (AwsRegisteredTargetDispatchInvalid (ProviderDispatchObservationUnobservable _))]
    ) -> True
  ( BoundaryDecisionRefused
    , [Left (AwsRegisteredTargetDispatchInvalid (ProviderDispatchObservationRefused _))]
    ) -> True
  ( BoundaryDecisionMalformed
    , [Left (AwsRegisteredTargetEksInvalid (AwsEksEvidenceNotRecognized _))]
    ) -> True
  _ -> False

shouldReturnSatisfying :: IO value -> (value -> Bool) -> Expectation
shouldReturnSatisfying action predicate = do
  value <- action
  value `shouldSatisfy` predicate

firstText :: (Show err) => Either err value -> Either Text value
firstText = either (Left . Text.pack . show) Right

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error ("expected Right, got " <> show err)
  Right value -> value

mustIdentity :: RegisteredResourceKey -> RegisteredIdentity
mustIdentity key = case lookupRegisteredIdentity key of
  Just identity -> identity
  Nothing -> error ("missing registered identity: " <> show key)

compiled :: CompiledDesiredAbsenceProgram 'Cascade
compiled =
  mustRight
    ( compileDesiredAbsenceGraph
        cleanupRunId
        foundation
        (Just awsScope)
        Nothing
        CascadeSurface
    )

cleanupRunId :: CleanupRunId
cleanupRunId = mustRight (mkCleanupRunId "aws-registered-target-interpreter")

foundation :: LinuxRke2FoundationId
foundation = LinuxRke2FoundationId "linux-rke2/home"

awsScope :: AwsScope
awsScope =
  AwsScope
    (AwsAccountId "111122223333")
    (AwsRegion (fixtureAwsRegion FixtureCaCentral1))

otherOperationId :: CleanupOperationId
otherOperationId = mustRight (mkCleanupOperationId "other-operation")

providerRevision :: ProviderRevision
providerRevision = mustRight (mkProviderRevision 9)

manifestProvenance :: OwnershipManifestProvenance
manifestProvenance = OwnershipManifestProvenance "lifecycle-authority/manifest"

manifestVersion :: OwnershipManifestVersion
manifestVersion = OwnershipManifestVersion "manifest/version-1"

ebsPresentEvidence :: Text
ebsPresentEvidence =
  "prodbox-test-ebs-observation/v1:present:vol-01234567"

ebsAbsentEvidence :: Text
ebsAbsentEvidence = "prodbox-test-ebs-observation/v1:absent"
