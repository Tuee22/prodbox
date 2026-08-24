{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownProviderDispatch
  ( lifecycleTeardownProviderDispatchSuite
  )
where

import Control.Monad (void)
import Data.IORef
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKeyError (ClientSubmissionKeyTooLong)
  , clientSubmissionKeyText
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupOperationId
  , mkCleanupOperationId
  )
import Prodbox.Lifecycle.OwnedResourceTags
  ( dns01ChallengeRecordNamePrefix
  , dnsValidationHostedZoneNamePrefix
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( EksClusterIdentityRequest
  , ProviderIntent (..)
  , ProviderRevision
  , ProviderStackConfig
  , ProviderStackRef
  , mkAwsEksProviderStackConfig
  , mkEksClusterIdentityRequest
  , mkProviderRevision
  , mkProviderStackRef
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.TagSweep qualified as TagSweep
import Prodbox.Lifecycle.Teardown.ProviderDispatch
import Prodbox.Lifecycle.Teardown.RegisteredTargetExecutor
  ( RegisteredTargetExecutor (..)
  )
import Prodbox.Lifecycle.Teardown.RegisteredTargetResult
  ( RegisteredTargetMutationAttempt (..)
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( awsEksIamManagedPolicyNames
  , awsEksIamRoleNames
  , awsEksLoadBalancerControllerName
  , awsEksLoadBalancerControllerTags
  )
import TestSupport

lifecycleTeardownProviderDispatchSuite :: SuiteBuilder ()
lifecycleTeardownProviderDispatchSuite =
  describe "Sprint 4.85 stable registered Provider dispatch" $ do
    it "derives deterministic, purpose-separated Authority submission keys" $ do
      let decision = keyFor ProviderDecisionObservation
          mutation = keyFor ProviderRegisteredMutation
          readBack = keyFor ProviderAbsenceReadBack
      providerDispatchKeyOperationId decision `shouldBe` operationId
      providerDispatchKeyPurpose decision `shouldBe` ProviderDecisionObservation
      map submissionText [decision, mutation, readBack]
        `shouldBe` [ operationText <> ":decision-observe"
                   , operationText <> ":mutate"
                   , operationText <> ":absence-readback"
                   ]
      keyFor ProviderDecisionObservation `shouldBe` decision
      length
        ( nub
            (map observationRevisionForProviderDispatchKey [decision, mutation, readBack])
        )
        `shouldBe` 3
      observationRevisionForProviderDispatchKey
        (keyFor ProviderDecisionObservation)
        `shouldBe` observationRevisionForProviderDispatchKey decision

    it "refuses a stable graph identity that cannot fit the Authority key bound" $ do
      let longOperation = mustRight (mkCleanupOperationId (Text.replicate 120 "x"))
          expectedLength = 120 + Text.length (":decision-observe" :: Text)
      mkProviderDispatchKey longOperation ProviderDecisionObservation
        `shouldBe` Left
          ( ProviderDispatchKeyInvalid
              (ClientSubmissionKeyTooLong expectedLength 128)
          )

    it "dispatches only exact read-only intents and reconstructs their coordinate" $ do
      trace <- newIORef []
      let boundary = recordingBoundary trace (TeardownProviderCompleted canonicalAbsent)
          request = ObserveRegisteredStack stackRef
      observed <-
        dispatchRegisteredProviderObservation
          boundary
          (keyFor ProviderDecisionObservation)
          request
      observed
        `shouldBe` Right
          ( ProviderIntentExecutionObserved
              (providerIntentCoordinate request)
              canonicalAbsent
          )
      readIORef trace
        `shouldReturn` [
                         ( operationText <> ":decision-observe"
                         , request
                         )
                       ]

    it "keeps observation transport inability unobservable" $ do
      let boundary = fixedBoundary (TeardownProviderUnavailable "authority response unavailable")
      observed <-
        dispatchRegisteredProviderObservation
          boundary
          (keyFor ProviderAbsenceReadBack)
          (ReadBackRegisteredStack stackRef)
      observed
        `shouldBe` Left
          ( ProviderDispatchObservationUnobservable
              "authority response unavailable"
          )

    it "rejects mutation intents at observation keys before dispatch" $ do
      calls <- newIORef (0 :: Int)
      let boundary =
            TeardownProviderBoundary $ \_ _ -> do
              modifyIORef' calls (+ 1)
              pure (TeardownProviderCompleted "unexpected")
          destroy = DestroyRegisteredStack stackRef providerRevision stackConfig
      dispatched <-
        dispatchRegisteredProviderObservation
          boundary
          (keyFor ProviderDecisionObservation)
          destroy
      dispatched
        `shouldBe` Left
          ( ProviderDispatchIntentPurposeMismatch
              ProviderDecisionObservation
              destroy
          )
      readIORef calls `shouldReturn` 0

    it "maps confirmed mutation dispatch to applied and transport loss to unconfirmed" $ do
      let destroy = DestroyRegisteredStack stackRef providerRevision stackConfig
          mutationKey = keyFor ProviderRegisteredMutation
      applied <-
        dispatchRegisteredProviderMutation
          (fixedBoundary (TeardownProviderCompleted "provider read-back satisfied"))
          mutationKey
          destroy
      lost <-
        dispatchRegisteredProviderMutation
          (fixedBoundary (TeardownProviderUnavailable "connection closed after submit"))
          mutationKey
          destroy
      applied `shouldBe` Right RegisteredTargetMutationApplied
      lost
        `shouldBe` Right
          (RegisteredTargetMutationResponseLost "connection closed after submit")

    it "admits only the three registered teardown mutation constructors" $ do
      let mutationKey = keyFor ProviderRegisteredMutation
          boundary = fixedBoundary (TeardownProviderCompleted "unused")
          forbidden = ReconcileRegisteredStack stackRef providerRevision stackConfig
      refused <- dispatchRegisteredProviderMutation boundary mutationKey forbidden
      refused
        `shouldBe` Left
          ( ProviderDispatchIntentPurposeMismatch
              ProviderRegisteredMutation
              forbidden
          )
      ebs <-
        dispatchRegisteredProviderMutation
          boundary
          mutationKey
          (ReapTestEbsVolumes "prodbox-test")
      ebs `shouldBe` Right RegisteredTargetMutationApplied
      validationZone <-
        dispatchRegisteredProviderMutation
          boundary
          mutationKey
          (ReapValidationHostedZones dnsValidationHostedZoneNamePrefix)
      validationZone `shouldBe` Right RegisteredTargetMutationApplied

    it "keeps a definite Authority refusal distinct from response loss" $ do
      let destroy = DestroyRegisteredStack stackRef providerRevision stackConfig
          boundary = fixedBoundary (TeardownProviderRefused "generation fenced")
      mutation <-
        dispatchRegisteredProviderMutation
          boundary
          (keyFor ProviderRegisteredMutation)
          destroy
      observation <-
        dispatchRegisteredProviderObservation
          boundary
          (keyFor ProviderDecisionObservation)
          (ObserveRegisteredStack stackRef)
      mutation
        `shouldBe` Right (RegisteredTargetMutationRefused "generation fenced")
      observation
        `shouldBe` Left (ProviderDispatchObservationRefused "generation fenced")

    it "admits every registered-target executor's intents at its own purposes" $ do
      let boundary = fixedBoundary (TeardownProviderCompleted "unused")
          admit executor = do
            let intents = executorIntents executor
            decision <-
              dispatchRegisteredProviderObservation
                boundary
                (keyFor ProviderDecisionObservation)
                (executorDecisionIntent intents)
            readBack <-
              dispatchRegisteredProviderObservation
                boundary
                (keyFor ProviderAbsenceReadBack)
                (executorReadBackIntent intents)
            mutation <- case executorMutationIntent intents of
              Nothing -> pure (Right ())
              Just intent ->
                void
                  <$> dispatchRegisteredProviderMutation
                    boundary
                    (keyFor ProviderRegisteredMutation)
                    intent
            pure
              ( executor
              , map purposeMismatched [void decision, void readBack, mutation]
              )
      admitted <- traverse admit [minBound .. maxBound]
      admitted
        `shouldBe` [ (executor, [False, False, False])
                   | executor <- [minBound .. maxBound]
                   ]

    it "does not use a fresh Provider submission path" $ do
      source <- readFile "src/Prodbox/Lifecycle/Teardown/ProviderDispatch.hs"
      source `shouldNotContain` "dispatchHostProviderIntentFresh"
      source `shouldNotContain` "dispatchAuthenticatedProviderIntentFresh"
      source `shouldNotContain` "getPOSIXTime"

recordingBoundary
  :: IORef [(Text, ProviderIntent)]
  -> TeardownProviderBoundaryResult
  -> TeardownProviderBoundary IO
recordingBoundary trace result =
  TeardownProviderBoundary $ \dispatchKey intent -> do
    let submissionKey = providerDispatchSubmissionKey dispatchKey
    modifyIORef' trace (++ [(clientSubmissionKeyText submissionKey, intent)])
    pure result

fixedBoundary :: TeardownProviderBoundaryResult -> TeardownProviderBoundary IO
fixedBoundary result = TeardownProviderBoundary (\_ _ -> pure result)

keyFor :: ProviderDispatchPurpose -> ProviderDispatchKey
keyFor = mustRight . mkProviderDispatchKey operationId

submissionText :: ProviderDispatchKey -> Text
submissionText = clientSubmissionKeyText . providerDispatchSubmissionKey

operationId :: CleanupOperationId
operationId = mustRight (mkCleanupOperationId operationText)

operationText :: Text
operationText = "lifecycle-operation/0123456789abcdef"

stackRef :: ProviderStackRef
stackRef = mustRight (mkProviderStackRef "aws-eks")

providerRevision :: ProviderRevision
providerRevision = mustRight (mkProviderRevision 1)

stackConfig :: ProviderStackConfig
stackConfig = mustRight (mkAwsEksProviderStackConfig "127.0.0.1/32")

canonicalAbsent :: Text
canonicalAbsent = "registered stack is absent"

mustRight :: (Show error) => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("unexpected fixture failure: " ++ show err)

-- | The exact provider intents each registered-target executor dispatches, by
-- dispatch purpose.  The @case@ is exhaustive on purpose: a new executor
-- cannot be added without deciding what it dispatches, and the assertion above
-- then measures that "ProviderDispatch" admits it.  Sprint 7.36's validation
-- hosted-zone executor was registered with its adapter and its intents were
-- *not* admitted here, so every dispatched observation would have refused as a
-- purpose mismatch while the adapter's own tables stayed green.
data ExecutorIntents = ExecutorIntents
  { executorDecisionIntent :: ProviderIntent
  , executorReadBackIntent :: ProviderIntent
  , executorMutationIntent :: Maybe ProviderIntent
  -- ^ 'Nothing' when the executor's mutation is not a provider call at all.
  -- Sprint 7.36's DNS01 challenge family deletes a Kubernetes owner object,
  -- so it has no reap intent to admit and none to forget.
  }

executorIntents :: RegisteredTargetExecutor -> ExecutorIntents
executorIntents executor = case executor of
  EksStackExecutor ->
    ExecutorIntents
      { executorDecisionIntent = ObserveEksClusterIdentity eksIdentityRequest
      , executorReadBackIntent = ObserveEksClusterIdentity eksIdentityRequest
      , executorMutationIntent =
          Just (DestroyRegisteredStack stackRef providerRevision stackConfig)
      }
  GenericStackExecutor ->
    ExecutorIntents
      { executorDecisionIntent = ObserveRegisteredStack stackRef
      , executorReadBackIntent = ReadBackRegisteredStack stackRef
      , executorMutationIntent =
          Just (DestroyRegisteredStack stackRef providerRevision stackConfig)
      }
  PerRunTestEbsFamilyExecutor ->
    ExecutorIntents
      { executorDecisionIntent = ObserveTestEbsVolumes "prodbox-test"
      , executorReadBackIntent = ObserveTestEbsVolumes "prodbox-test"
      , executorMutationIntent = Just (ReapTestEbsVolumes "prodbox-test")
      }
  ValidationHostedZoneFamilyExecutor ->
    ExecutorIntents
      { executorDecisionIntent =
          ObserveValidationHostedZones dnsValidationHostedZoneNamePrefix
      , executorReadBackIntent =
          ObserveValidationHostedZones dnsValidationHostedZoneNamePrefix
      , executorMutationIntent =
          Just (ReapValidationHostedZones dnsValidationHostedZoneNamePrefix)
      }
  RetainedEbsFamilyExecutor ->
    ExecutorIntents
      { executorDecisionIntent = ObserveRetainedEbsVolumes retainedLifecycleValue
      , executorReadBackIntent = ObserveRetainedEbsVolumes retainedLifecycleValue
      , executorMutationIntent = Just (ReapRetainedEbsVolumes retainedLifecycleValue)
      }
  Dns01ChallengeRecordFamilyExecutor ->
    ExecutorIntents
      { executorDecisionIntent = dns01ChallengeObserveIntent
      , executorReadBackIntent = dns01ChallengeObserveIntent
      , -- No reap intent: the removal is a Kubernetes owner delete through the
        -- interpreter's Kubernetes-scoped execution arm, so there is nothing
        -- for the provider dispatcher to admit at the mutation purpose.
        executorMutationIntent = Nothing
      }
  EksIamRoleFamilyExecutor ->
    ExecutorIntents
      { executorDecisionIntent = iamObservation
      , executorReadBackIntent = iamObservation
      , executorMutationIntent = Just iamReap
      }
  EksLoadBalancerControllerFamilyExecutor ->
    ExecutorIntents
      { executorDecisionIntent = lbcObservation
      , executorReadBackIntent = lbcObservation
      , executorMutationIntent = Just lbcReap
      }
 where
  roles = Text.intercalate "|" awsEksIamRoleNames
  policies = Text.intercalate "|" awsEksIamManagedPolicyNames
  iamObservation = ObserveEksIamRoleFamily roles policies
  iamReap = ReapEksIamRoleFamily roles policies
  lbcName = awsEksLoadBalancerControllerName
  lbcTags =
    Text.intercalate
      "|"
      (map (\(key, value) -> key <> "=" <> value) awsEksLoadBalancerControllerTags)
  lbcObservation = ObserveEksLoadBalancerControllerFamily lbcName lbcTags
  lbcReap = ReapEksLoadBalancerControllerFamily lbcName lbcTags

purposeMismatched :: Either ProviderDispatchError () -> Bool
purposeMismatched dispatched = case dispatched of
  Left (ProviderDispatchIntentPurposeMismatch _ _) -> True
  _ -> False

eksIdentityRequest :: EksClusterIdentityRequest
eksIdentityRequest =
  mustRight
    ( mkEksClusterIdentityRequest
        stackRef
        "123456789012"
        (fixtureAwsRegion FixtureCaCentral1)
        "aws-eks-test-cluster"
    )

retainedLifecycleValue :: Text
retainedLifecycleValue = Text.pack TagSweep.ebsRetainedLifecycleValue

dns01ChallengeObserveIntent :: ProviderIntent
dns01ChallengeObserveIntent =
  ObserveDns01ChallengeRecords "Z1EXAMPLEZONE" dns01ChallengeRecordNamePrefix
