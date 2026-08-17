{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownAwsEbsAdapter
  ( lifecycleTeardownAwsEbsAdapterSuite
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.AwsEbsAdapter
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownAwsEbsAdapterSuite :: SuiteBuilder ()
lifecycleTeardownAwsEbsAdapterSuite =
  describe "Sprint 4.85 exact per-run EBS ProviderIntent adapter" $ do
    it "projects only the registered per-run cleanup surfaces and exact cluster" $ do
      let cascade = requestFor CascadeSurface cascadeScope
      awsEbsObservationRequestScope cascade `shouldBe` cascadeScope
      awsEbsObservationRequestRevision cascade `shouldBe` initialRevision
      awsEbsObservationRequestProviderIntent cascade
        `shouldBe` ObserveTestEbsVolumes testClusterName
      mkExactAwsEbsObservationRequest
        ExplicitPerRunSurface
        initialRevision
        (scopeFor ExplicitPerRun validAwsScope ReconcileDesiredAbsent)
        `shouldSatisfy` isRight
      mkExactAwsEbsObservationRequest
        TotalDecommissionSurface
        initialRevision
        (scopeFor TotalDecommission validAwsScope ReconcileDesiredAbsent)
        `shouldSatisfy` isRight
      mkExactAwsEbsObservationRequest
        LocalOnlySurface
        initialRevision
        (scopeFor LocalOnly validAwsScope ReconcileDesiredAbsent)
        `shouldSatisfy` isLeft
      mkExactAwsEbsObservationRequest
        OperationalTeardownSurface
        initialRevision
        (scopeFor OperationalTeardown validAwsScope ReconcileDesiredAbsent)
        `shouldSatisfy` isLeft
      mkExactAwsEbsObservationRequest
        ExplicitLongLivedSurface
        initialRevision
        (scopeFor ExplicitLongLived validAwsScope ReconcileDesiredAbsent)
        `shouldSatisfy` isLeft

    it "refuses missing AWS scope, stale registry, wrong operation, and surface drift" $ do
      mkExactAwsEbsObservationRequest
        CascadeSurface
        initialRevision
        (scopeFor Cascade Nothing ReconcileDesiredAbsent)
        `shouldBe` Left AwsEbsAwsScopeMissing
      mkExactAwsEbsObservationRequest
        CascadeSurface
        initialRevision
        staleRegistryScope
        `shouldBe` Left
          ( AwsEbsRegistryRevisionMismatch
              lifecycleRegistryRevision
              staleRegistryRevision
          )
      mkExactAwsEbsObservationRequest
        CascadeSurface
        initialRevision
        (scopeFor Cascade validAwsScope ReconcileDesiredPresent)
        `shouldBe` Left (AwsEbsOperationInvalid ReconcileDesiredPresent)
      mkExactAwsEbsObservationRequest
        ExplicitPerRunSurface
        initialRevision
        cascadeScope
        `shouldBe` Left (AwsEbsSurfaceMismatch ExplicitPerRun Cascade)

    it "decodes only canonical provider evidence as exact absence or presence" $ do
      let request = requestFor CascadeSurface cascadeScope
          absent = decode request canonicalAbsent
          present = decode request canonicalPresent
      exactObservationResult absent
        `shouldBe` ExactResourceAbsent
          ( AbsenceEvidence
              "provider-worker exact test-scoped EBS family returned its canonical empty set"
          )
      exactObservationResult present
        `shouldBe` ExactResourcePresent
          ( ExactResourceInventory
              (ObservedResourceIdentity "volume/vol-01234567" :| [])
          )
      assertExactBinding request absent
      assertExactBinding request present

    it "keeps transport and malformed evidence unobservable, never absent" $ do
      let request = requestFor CascadeSurface cascadeScope
      case mustRight (decodeExactAwsEbsObservation request (Left "provider unavailable")) of
        observation -> do
          exactObservationResult observation `shouldSatisfy` isUnobservable
          exactObservationResult observation `shouldSatisfy` isNotAbsent
      mapM_
        ( \evidence -> do
            let observation = decode request evidence
            exactObservationResult observation `shouldSatisfy` isUnobservable
            exactObservationResult observation `shouldSatisfy` isNotAbsent
        )
        [ "prodbox-test-ebs-observation/v1:absent "
        , "prodbox-test-ebs-observation/v1:present:"
        , "prodbox-test-ebs-observation/v1:present:vol-01234567,vol-01234567"
        , "prodbox-test-ebs-observation/v1:present:vol-01234567,vol-00000000"
        , "not evidence"
        ]

    it "refuses results for another intent and every mutation result kind" $ do
      let request = requestFor CascadeSurface cascadeScope
          expected =
            providerIntentCoordinate (awsEbsObservationRequestProviderIntent request)
          other = providerIntentCoordinate (ObserveTestEbsVolumes "another-cluster")
      decodeExactAwsEbsObservation
        request
        (Right (ProviderIntentExecutionObserved other canonicalAbsent))
        `shouldBe` Left (AwsEbsProviderCoordinateMismatch expected other)
      decodeExactAwsEbsObservation
        request
        (Right (ProviderIntentExecutionApplied expected canonicalAbsent))
        `shouldBe` Left AwsEbsProviderResultKindMismatch
      decodeExactAwsEbsObservation
        request
        (Right (ProviderIntentExecutionAlreadySatisfied expected canonicalAbsent))
        `shouldBe` Left AwsEbsProviderResultKindMismatch

    it "authorizes the exact reaper only from a complete positive observation" $ do
      let request = requestFor CascadeSurface cascadeScope
          present = decode request canonicalPresent
          absent = decode request canonicalAbsent
          unknown = decode request "not evidence"
      authorizeExactAwsEbsReap request absent `shouldBe` Right Nothing
      case mustRight (authorizeExactAwsEbsReap request present) of
        Nothing -> expectationFailure "present EBS family did not authorize cleanup"
        Just authorization -> do
          awsEbsReapScope authorization `shouldBe` cascadeScope
          awsEbsReapProviderIntent authorization
            `shouldBe` ReapTestEbsVolumes testClusterName
      authorizeExactAwsEbsReap request unknown `shouldSatisfy` isLeft
      authorizeExactAwsEbsReap
        request
        (present {exactObservationResourceKey = AwsTestKey})
        `shouldSatisfy` isLeft

    it "requires a separate exact read-back after reaping" $ do
      let request = requestFor CascadeSurface cascadeScope
      confirmExactAwsEbsAbsence request (observedResult request canonicalAbsent)
        `shouldSatisfy` isRight
      confirmExactAwsEbsAbsence request (observedResult request canonicalPresent)
        `shouldSatisfy` isStillPresent
      confirmExactAwsEbsAbsence request (observedResult request "not evidence")
        `shouldSatisfy` isObservationRefused
      confirmExactAwsEbsAbsence
        request
        ( Right
            ( ProviderIntentExecutionApplied
                (providerIntentCoordinate (awsEbsObservationRequestProviderIntent request))
                canonicalAbsent
            )
        )
        `shouldBe` Left AwsEbsProviderResultKindMismatch

requestFor
  :: CleanupSurfaceWitness surface
  -> ObservationEvidenceScope
  -> ExactAwsEbsObservationRequest
requestFor surface scope =
  mustRight (mkExactAwsEbsObservationRequest surface initialRevision scope)

decode :: ExactAwsEbsObservationRequest -> Text -> ExactResourceObservation
decode request evidence =
  mustRight (decodeExactAwsEbsObservation request (observedResult request evidence))

observedResult
  :: ExactAwsEbsObservationRequest
  -> Text
  -> Either Text ProviderIntentExecutionResult
observedResult request evidence =
  Right
    ( ProviderIntentExecutionObserved
        (providerIntentCoordinate (awsEbsObservationRequestProviderIntent request))
        evidence
    )

assertExactBinding
  :: ExactAwsEbsObservationRequest
  -> ExactResourceObservation
  -> Expectation
assertExactBinding request observation = do
  exactObservationResourceKey observation `shouldBe` AwsEbsPerRunTestKey
  exactObservationAuthority observation `shouldBe` AwsResourceApiAuthority
  exactObservationRevision observation `shouldBe` awsEbsObservationRequestRevision request
  exactObservationEvidenceScope observation `shouldBe` awsEbsObservationRequestScope request

scopeFor
  :: CleanupSurface
  -> Maybe AwsScope
  -> LifecycleOperation
  -> ObservationEvidenceScope
scopeFor surface awsScope operation =
  mkObservationEvidenceScope
    surface
    lifecycleRegistryRevision
    (DurableObservationRunScope "aws-ebs-adapter-run")
    (LinuxRke2FoundationId "home-rke2")
    awsScope
    operation

cascadeScope :: ObservationEvidenceScope
cascadeScope = scopeFor Cascade validAwsScope ReconcileDesiredAbsent

staleRegistryScope :: ObservationEvidenceScope
staleRegistryScope =
  mkObservationEvidenceScope
    Cascade
    staleRegistryRevision
    (DurableObservationRunScope "aws-ebs-adapter-run")
    (LinuxRke2FoundationId "home-rke2")
    validAwsScope
    ReconcileDesiredAbsent

validAwsScope :: Maybe AwsScope
validAwsScope =
  Just (AwsScope (AwsAccountId "123456789012") (AwsRegion "us-east-1"))

staleRegistryRevision :: RegistryRevision
staleRegistryRevision = RegistryRevision "lifecycle-registry/stale"

initialRevision :: ObservationRevision
initialRevision = ObservationRevision 91

testClusterName :: Text
testClusterName = "aws-eks-test-cluster"

canonicalAbsent :: Text
canonicalAbsent = "prodbox-test-ebs-observation/v1:absent"

canonicalPresent :: Text
canonicalPresent = "prodbox-test-ebs-observation/v1:present:vol-01234567"

isLeft :: Either left right -> Bool
isLeft result = case result of
  Left _ -> True
  Right _ -> False

isRight :: Either left right -> Bool
isRight result = case result of
  Left _ -> False
  Right _ -> True

isUnobservable :: ExactObservationResult -> Bool
isUnobservable result = case result of
  ExactResourceUnobservable _ -> True
  _ -> False

isNotAbsent :: ExactObservationResult -> Bool
isNotAbsent result = case result of
  ExactResourceAbsent _ -> False
  _ -> True

isStillPresent :: Either AwsEbsAdapterError value -> Bool
isStillPresent result = case result of
  Left (AwsEbsStillPresent _) -> True
  _ -> False

isObservationRefused :: Either AwsEbsAdapterError value -> Bool
isObservationRefused result = case result of
  Left (AwsEbsObservationRefused _) -> True
  _ -> False

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("expected Right, got " <> show err)
