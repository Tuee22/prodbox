{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownProviderDispatch
  ( lifecycleTeardownProviderDispatchSuite
  )
where

import CleanupScopeFixtures (fixtureInviteMailScope)
import Control.Monad (void)
import Data.IORef
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityProviderEndpoint
  ( ProviderExecutionOutcome
  , providerExecutionOutcome
  )
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderExecutionKind (..)
  , ProviderIntentExecutionResult (..)
  , executionResultCoordinate
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKeyError (ClientSubmissionKeyTooLong)
  , clientSubmissionKeyText
  )
import Prodbox.Lifecycle.AwsNetworkFamily (AwsNetworkFamily (EksVpcCniInterfaces))
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
  , ProviderOwnedTagQuery (ProviderOwnedTagKeyQuery)
  , ProviderRevision
  , ProviderStackConfig
  , ProviderStackRef
  , mkAwsEksProviderStackConfig
  , mkEksClusterIdentityRequest
  , mkProviderNetworkFamilyRef
  , mkProviderRevision
  , mkProviderStackRef
  , providerIntentCoordinate
  , registeredStackAbsenceEvidence
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
    it "separates fenced audit observations from v1 completions and each endpoint" $ do
      let query = ProviderOwnedTagKeyQuery "prodbox.io/managed-by"
          intents = [ObserveOwnedResourceTags query, ObserveGlobalOwnedResourceTags query]
          oldKeys = map (mustRight . mkTerminalAuditProviderDispatchKey operationId) intents
          fencedKeys = map (mustRight . mkFencedTerminalAuditProviderDispatchKey operationId) intents
      length (nub fencedKeys) `shouldBe` length intents
      and (zipWith (/=) oldKeys fencedKeys) `shouldBe` True
      map (mustRight . mkFencedTerminalAuditProviderDispatchKey operationId) intents
        `shouldBe` fencedKeys
      map providerDispatchKeyOperationId fencedKeys `shouldBe` replicate (length intents) operationId
      map providerDispatchKeyPurpose fencedKeys
        `shouldBe` replicate (length intents) ProviderTerminalAudit

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
      let boundary = recordingObservingBoundary trace canonicalAbsent
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
            TeardownProviderBoundary $ \_ intent -> do
              modifyIORef' calls (+ 1)
              pure (TeardownProviderCompleted (observedOutcome intent "unexpected"))
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
          (appliedBoundary "provider read-back satisfied")
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

    -- Sprint 4.97.  These are the arms the sprint exists for.  Before it, the
    -- client rebuilt its result from the intent it had *sent* — always
    -- `ProviderIntentExecutionObserved` at the request's own coordinate — so
    -- the adapter's coordinate-mismatch and result-kind refusals compared a
    -- value against itself and could not fire from any dispatch.  They were
    -- unit-tested with hand-built values, which is exactly why that survived
    -- review: the pure decoder was covered and the path feeding it was not.
    it "carries the execution kind from the wire, so a wrong kind refuses" $ do
      let observe = ObserveRegisteredStack stackRef
          destroy = DestroyRegisteredStack stackRef providerRevision stackConfig
          observationKey = keyFor ProviderDecisionObservation
          mutationKey = keyFor ProviderRegisteredMutation

      -- An observation lane answered with a mutation kind is refused, naming
      -- the kind it received.
      appliedToObservation <-
        dispatchRegisteredProviderObservation
          (appliedBoundary "applied on an observation lane")
          observationKey
          observe
      appliedToObservation
        `shouldBe` Left
          (ProviderDispatchObservationResultKind ProviderExecutionAppliedKind)

      satisfiedToObservation <-
        dispatchRegisteredProviderObservation
          (alreadySatisfiedBoundary "already satisfied on an observation lane")
          observationKey
          observe
      satisfiedToObservation
        `shouldBe` Left
          ( ProviderDispatchObservationResultKind
              ProviderExecutionAlreadySatisfiedKind
          )

      -- And a mutation lane answered with an observation is refused too.
      observedToMutation <-
        dispatchRegisteredProviderMutation
          (observingBoundary "observed on a mutation lane")
          mutationKey
          destroy
      observedToMutation
        `shouldBe` Left
          (ProviderDispatchMutationResultKind ProviderExecutionObservedKind)

    -- Sprint 4.97.  A destroy that ran and a destroy that found nothing already
    -- gone stop being the same answer.  This boundary flattened them into
    -- `RegisteredTargetMutationApplied` a second time, after the Authority's
    -- wire had already flattened them once, so carrying the kind on the
    -- response would have bought nothing without this arm.
    it "distinguishes a mutation that ran from one that found nothing to do" $ do
      let destroy = DestroyRegisteredStack stackRef providerRevision stackConfig
          mutationKey = keyFor ProviderRegisteredMutation
      applied <-
        dispatchRegisteredProviderMutation
          (appliedBoundary "destroy ran")
          mutationKey
          destroy
      alreadySatisfied <-
        dispatchRegisteredProviderMutation
          (alreadySatisfiedBoundary "nothing to destroy")
          mutationKey
          destroy
      applied `shouldBe` Right RegisteredTargetMutationApplied
      alreadySatisfied
        `shouldBe` Right
          (RegisteredTargetMutationAlreadySatisfied "nothing to destroy")
      applied `shouldSatisfy` (/= alreadySatisfied)

    -- Sprint 4.97.  The coordinate now comes from the response, so a wire that
    -- answers about a different resource is visible instead of being silently
    -- replaced by the one we asked about.
    it "keeps the coordinate the wire answered with, not the one it was sent" $ do
      let observe = ObserveRegisteredStack stackRef
          other = ObserveRegisteredStack otherStackRef
          observationKey = keyFor ProviderDecisionObservation
      observed <-
        dispatchRegisteredProviderObservation
          (observingBoundaryFor other "evidence about another stack")
          observationKey
          observe
      fmap executionResultCoordinate observed
        `shouldBe` Right (providerIntentCoordinate other)
      fmap executionResultCoordinate observed
        `shouldSatisfy` (/= Right (providerIntentCoordinate observe))

    it "admits only the three registered teardown mutation constructors" $ do
      let mutationKey = keyFor ProviderRegisteredMutation
          boundary = appliedBoundary "unused"
          forbidden =
            ReconcileRegisteredStack
              stackRef
              providerRevision
              stackConfig
              fixtureProviderRunMarker
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
      let boundary = observingBoundary "unused"
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

fixedBoundary :: TeardownProviderBoundaryResult -> TeardownProviderBoundary IO
fixedBoundary result = TeardownProviderBoundary (\_ _ -> pure result)

-- | Sprint 4.97.  A fixture answers with the coordinate the intent carries, as
-- the Authority now does.
--
-- Before this sprint the client rebuilt its result from the intent it had sent,
-- so every fixture agreed with the adapter by construction and the adapter's
-- coordinate check was a value compared against itself.  Building the outcome
-- here from the intent keeps the fixtures honest about the *shape* of the wire
-- while leaving a mismatched coordinate constructible on purpose, which is what
-- makes the refusal arms testable.
observedOutcome :: ProviderIntent -> Text -> ProviderExecutionOutcome
observedOutcome intent evidence =
  providerExecutionOutcome
    (ProviderIntentExecutionObserved (providerIntentCoordinate intent) evidence)

appliedOutcome :: ProviderIntent -> Text -> ProviderExecutionOutcome
appliedOutcome intent evidence =
  providerExecutionOutcome
    (ProviderIntentExecutionApplied (providerIntentCoordinate intent) evidence)

observingBoundary :: Text -> TeardownProviderBoundary IO
observingBoundary evidence =
  TeardownProviderBoundary
    (\_ intent -> pure (TeardownProviderCompleted (observedOutcome intent evidence)))

appliedBoundary :: Text -> TeardownProviderBoundary IO
appliedBoundary evidence =
  TeardownProviderBoundary
    (\_ intent -> pure (TeardownProviderCompleted (appliedOutcome intent evidence)))

alreadySatisfiedOutcome :: ProviderIntent -> Text -> ProviderExecutionOutcome
alreadySatisfiedOutcome intent evidence =
  providerExecutionOutcome
    ( ProviderIntentExecutionAlreadySatisfied
        (providerIntentCoordinate intent)
        evidence
    )

alreadySatisfiedBoundary :: Text -> TeardownProviderBoundary IO
alreadySatisfiedBoundary evidence =
  TeardownProviderBoundary
    ( \_ intent ->
        pure (TeardownProviderCompleted (alreadySatisfiedOutcome intent evidence))
    )

-- | Answer about a resource other than the one that was asked about.
--
-- Sprint 4.97: constructible only because the coordinate now travels on the
-- response.  While the client re-synthesised it from the request, this fixture
-- could not be written at all.
observingBoundaryFor :: ProviderIntent -> Text -> TeardownProviderBoundary IO
observingBoundaryFor answered evidence =
  TeardownProviderBoundary
    (\_ _ -> pure (TeardownProviderCompleted (observedOutcome answered evidence)))

recordingObservingBoundary
  :: IORef [(Text, ProviderIntent)] -> Text -> TeardownProviderBoundary IO
recordingObservingBoundary trace evidence =
  TeardownProviderBoundary $ \dispatchKey intent -> do
    let submissionKey = providerDispatchSubmissionKey dispatchKey
    modifyIORef' trace (++ [(clientSubmissionKeyText submissionKey, intent)])
    pure (TeardownProviderCompleted (observedOutcome intent evidence))

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

otherStackRef :: ProviderStackRef
otherStackRef = mustRight (mkProviderStackRef "aws-test")

providerRevision :: ProviderRevision
providerRevision = mustRight (mkProviderRevision 1)

stackConfig :: ProviderStackConfig
stackConfig = mustRight (mkAwsEksProviderStackConfig "127.0.0.1/32")

canonicalAbsent :: Text
canonicalAbsent =
  registeredStackAbsenceEvidence (mustRight (mkProviderStackRef "aws-eks"))

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
  SesInviteMailObjectsExecutor ->
    ExecutorIntents
      { executorDecisionIntent = ObserveSesInviteMailResidue fixtureInviteMailScope
      , executorReadBackIntent = ObserveSesInviteMailResidue fixtureInviteMailScope
      , executorMutationIntent = Just (ReapSesInviteMailResidue fixtureInviteMailScope)
      }
  EksIamRoleFamilyExecutor ->
    ExecutorIntents
      { executorDecisionIntent = iamObservation
      , executorReadBackIntent = iamObservation
      , executorMutationIntent = Just iamReap
      }
  NetworkDependentFamilyExecutor ->
    let ref =
          mustRight
            (mkProviderNetworkFamilyRef EksVpcCniInterfaces "123456789012" (fixtureAwsRegion FixtureCaCentral1))
     in ExecutorIntents
          { executorDecisionIntent = ObserveNativeStackFamily ref stackConfig
          , executorReadBackIntent = ObserveNativeStackFamily ref stackConfig
          , executorMutationIntent = Just (ReapNativeStackFamily ref stackConfig [])
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
