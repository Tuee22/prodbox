{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownAwsRetainedEbsAdapter
  ( lifecycleTeardownAwsRetainedEbsAdapterSuite
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.Authority.AdminAction
  ( PermitFreshness (PermitExpired, PermitFresh)
  , RunnerRole (AdminActionRunner, DecommissionRunner)
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupRunId
  , mkCleanupDigest
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.EbsVolume
  ( parseRetainedEbsObservation
  , parseTestScopedEbsObservation
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.TagSweep qualified as TagSweep
import Prodbox.Lifecycle.Teardown.AwsRetainedEbsAdapter
import Prodbox.Lifecycle.Teardown.LongLivedAggregatePermit
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.RegisteredTargetExecutor
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownAwsRetainedEbsAdapterSuite :: SuiteBuilder ()
lifecycleTeardownAwsRetainedEbsAdapterSuite =
  describe "Sprint 7.36 exact retained EBS ProviderIntent adapter" $ do
    it "closes the last registered target with no production executor" $ do
      -- Sprint 4.85 recorded this key as the one registered descriptor whose
      -- adapter was unbuilt. With the adapter landed the gap enumeration has no
      -- constructors at all, so declaring a new gap is the only way to
      -- reintroduce one.
      registeredTargetExecutorFor AwsEbsProductionRetainedKey
        `shouldBe` Right RetainedEbsFamilyExecutor
      lookupRegisteredIdentity AwsEbsProductionRetainedKey
        `shouldSatisfy` isJustIdentity

    it "refuses every surface that is not explicitly long-lived" $ do
      -- The bound is the registry's own projection: the retained family is
      -- LongLived, so a cascade or per-run cleanup cannot construct a request
      -- for storage those surfaces exist to preserve.
      mkExactAwsRetainedEbsObservationRequest
        CascadeSurface
        initialRevision
        (scopeFor Cascade)
        `shouldSatisfy` isLeftResult
      mkExactAwsRetainedEbsObservationRequest
        ExplicitPerRunSurface
        initialRevision
        (scopeFor ExplicitPerRun)
        `shouldSatisfy` isLeftResult
      mkExactAwsRetainedEbsObservationRequest
        ExplicitLongLivedSurface
        initialRevision
        longLivedScope
        `shouldSatisfy` isRightResult

    it "derives the family bound from the registry rather than from a caller" $ do
      awsRetainedEbsObservationRequestProviderIntent longLivedRequest
        `shouldBe` ObserveRetainedEbsVolumes retainedLifecycleValue
      awsRetainedEbsObservationRequestScope longLivedRequest
        `shouldBe` longLivedScope

    it "reads the canonical empty set as absent and volumes as present" $ do
      exactObservationResult (decode "prodbox-retained-ebs-observation/v1:absent")
        `shouldSatisfy` isExactAbsent
      exactObservationResult
        (decode "prodbox-retained-ebs-observation/v1:present:vol-0123abcd")
        `shouldSatisfy` isExactPresent

    it "never turns an unobtainable listing into an absence" $ do
      exactObservationResult
        ( mustRight
            ( decodeExactAwsRetainedEbsObservation
                longLivedRequest
                (Left "ec2 describe-volumes was refused")
            )
        )
        `shouldSatisfy` isExactUnobservable
      -- A malformed wire is unobservable too, never absence.
      exactObservationResult (decode "prodbox-retained-ebs-observation/v1:bogus")
        `shouldSatisfy` isExactUnobservable

    it "keeps the two EBS families' wires from decoding as each other" $ do
      -- The families have opposite default dispositions, so a per-run
      -- observation must not be able to answer for the retained family.
      parseRetainedEbsObservation "prodbox-test-ebs-observation/v1:absent"
        `shouldSatisfy` isLeftResult
      parseTestScopedEbsObservation "prodbox-retained-ebs-observation/v1:absent"
        `shouldSatisfy` isLeftResult
      parseRetainedEbsObservation "prodbox-retained-ebs-observation/v1:absent"
        `shouldSatisfy` isRightResult

    it "authorizes a reap only from a positive observation" $ do
      fmap
        (fmap awsRetainedEbsReapProviderIntent)
        ( authorizeExactAwsRetainedEbsReap
            longLivedRequest
            (decode "prodbox-retained-ebs-observation/v1:absent")
        )
        `shouldBe` Right Nothing
      fmap
        (fmap awsRetainedEbsReapProviderIntent)
        ( authorizeExactAwsRetainedEbsReap
            longLivedRequest
            (decode "prodbox-retained-ebs-observation/v1:present:vol-0123abcd")
        )
        `shouldBe` Right (Just (ReapRetainedEbsVolumes retainedLifecycleValue))

    it "closes the family only on a separate exact read-back" $ do
      confirmExactAwsRetainedEbsAbsence
        longLivedRequest
        (observedResult "prodbox-retained-ebs-observation/v1:present:vol-0123abcd")
        `shouldSatisfy` isLeftResult
      confirmExactAwsRetainedEbsAbsence
        longLivedRequest
        (observedResult "prodbox-retained-ebs-observation/v1:absent")
        `shouldSatisfy` isRightResult

    it "derives the aggregate permit's universe from the registry" $ do
      -- Authored lists go stale; this one cannot, because it is the registry's
      -- own ExplicitLongLived projection.
      longLivedAggregateUniverse `shouldBe` [AwsEbsProductionRetainedKey]

    it "admits an aggregate permit only for the exact registered aggregate" $ do
      fmap longLivedAggregatePermitAggregate (admit PermitFresh permitRequest)
        `shouldBe` Right longLivedAggregateUniverse
      -- A subset would authorize a partial destruction the surface then reports
      -- as complete.
      admit PermitFresh permitRequest {longLivedPermitRequestAggregate = []}
        `shouldBe` Left
          (LongLivedPermitAggregateIncomplete [AwsEbsProductionRetainedKey])
      -- A widened permit names something the surface does not project.
      admit
        PermitFresh
        permitRequest
          { longLivedPermitRequestAggregate =
              AwsEbsProductionRetainedKey : [AwsEbsPerRunTestKey]
          }
        `shouldBe` Left (LongLivedPermitAggregateWidened [AwsEbsPerRunTestKey])

    it "refuses a permit issued for another runner, expired, or unnonced" $ do
      admit
        PermitFresh
        permitRequest {longLivedPermitRequestAudience = DecommissionRunner}
        `shouldBe` Left (LongLivedPermitWrongAudience DecommissionRunner)
      admit PermitExpired permitRequest `shouldBe` Left LongLivedPermitExpired
      admit PermitFresh permitRequest {longLivedPermitRequestNonce = ""}
        `shouldBe` Left LongLivedPermitNonceMissing

    it "keeps the long-lived surface the one that needs the permit" $ do
      -- Every other minting surface completes from its own read-backs; this one
      -- additionally consumes an operator decision.
      map
        cleanupSurfaceMintsCompletionEvidence
        [ Cascade
        , ExplicitPerRun
        , OperationalTeardown
        , ExplicitLongLived
        , TotalDecommission
        , LocalOnly
        ]
        `shouldBe` [True, True, True, True, False, False]

admit
  :: PermitFreshness
  -> LongLivedAggregatePermitRequest
  -> Either LongLivedAggregatePermitRefusal LongLivedAggregatePermit
admit = admitLongLivedAggregatePermit

permitRequest :: LongLivedAggregatePermitRequest
permitRequest =
  LongLivedAggregatePermitRequest
    { longLivedPermitRequestAudience = AdminActionRunner
    , longLivedPermitRequestRunId = permitRunId
    , longLivedPermitRequestGraphDigest = permitGraphDigest
    , longLivedPermitRequestAggregate = longLivedAggregateUniverse
    , longLivedPermitRequestNonce = "retained-ebs-adapter-permit"
    }

longLivedRequest :: ExactAwsRetainedEbsObservationRequest
longLivedRequest =
  mustRight
    ( mkExactAwsRetainedEbsObservationRequest
        ExplicitLongLivedSurface
        initialRevision
        longLivedScope
    )

decode :: Text -> ExactResourceObservation
decode evidence =
  mustRight
    (decodeExactAwsRetainedEbsObservation longLivedRequest (observedResult evidence))

observedResult :: Text -> Either Text ProviderIntentExecutionResult
observedResult evidence =
  Right
    ( ProviderIntentExecutionObserved
        ( providerIntentCoordinate
            (awsRetainedEbsObservationRequestProviderIntent longLivedRequest)
        )
        evidence
    )

permitRunId :: CleanupRunId
permitRunId = mustRight (mkCleanupRunId "retained-ebs-adapter-run")

permitGraphDigest :: CleanupDigest
permitGraphDigest = mustRight (mkCleanupDigest (Text.replicate 64 "a"))

retainedLifecycleValue :: Text
retainedLifecycleValue = Text.pack TagSweep.ebsRetainedLifecycleValue

initialRevision :: ObservationRevision
initialRevision = ObservationRevision 1

longLivedScope :: ObservationEvidenceScope
longLivedScope = scopeFor ExplicitLongLived

scopeFor :: CleanupSurface -> ObservationEvidenceScope
scopeFor surface =
  mkObservationEvidenceScope
    surface
    lifecycleRegistryRevision
    (DurableObservationRunScope "aws-retained-ebs-adapter-run")
    (LinuxRke2FoundationId "home-rke2")
    (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureUsEast1))))
    ReconcileDesiredAbsent

isExactAbsent :: ExactObservationResult -> Bool
isExactAbsent result = case result of
  ExactResourceAbsent _ -> True
  _ -> False

isExactPresent :: ExactObservationResult -> Bool
isExactPresent result = case result of
  ExactResourcePresent _ -> True
  _ -> False

isExactUnobservable :: ExactObservationResult -> Bool
isExactUnobservable result = case result of
  ExactResourceUnobservable _ -> True
  _ -> False

isJustIdentity :: Maybe RegisteredIdentity -> Bool
isJustIdentity = maybe False (const True)

isLeftResult :: Either left right -> Bool
isLeftResult result = case result of
  Left _ -> True
  Right _ -> False

isRightResult :: Either left right -> Bool
isRightResult result = case result of
  Right _ -> True
  Left _ -> False

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("expected Right, got " <> show err)
