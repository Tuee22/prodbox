{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownLegacyAdoptionObserver
  ( lifecycleTeardownLegacyAdoptionObserverSuite
  )
where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.DnsRecord (mkHostedZoneId)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderStackConfig
  , mkAwsEksProviderStackConfig
  , mkAwsEksSubzoneProviderStackConfig
  , mkAwsTestProviderStackConfig
  , providerIntentCoordinate
  , providerNativeStackFamilyStackRef
  , providerStackRefText
  )
import Prodbox.Lifecycle.Teardown.AwsNativeStackFamilyAdapter
  ( encodeAwsNativeStackFamilyEvidence
  )
import Prodbox.Lifecycle.Teardown.LegacyAdoptionObserver
import Prodbox.Lifecycle.Teardown.LegacyAdoptionPlan
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownLegacyAdoptionObserverSuite :: SuiteBuilder ()
lifecycleTeardownLegacyAdoptionObserverSuite =
  describe "Sprint 7.36 Provider-native legacy-adoption observer" $ do
    it "observes every member of each closed registered stack family" $ do
      mapM_ assertObservedFamily [AwsEksKey, AwsEksSubzoneKey, AwsTestKey]

    it "turns transport and result-kind failures into family refusal" $ do
      let transportFailure =
            LegacyAdoptionProviderObserver
              (\_ -> pure (Left "provider transport unavailable"))
          wrongKind =
            LegacyAdoptionProviderObserver
              ( \intent ->
                  pure
                    ( Right
                        ( ProviderIntentExecutionApplied
                            (providerIntentCoordinate intent)
                            stackAbsentEvidence
                        )
                    )
              )
      observeAndPlanLegacyAdoption
        ExplicitPerRunSurface
        AwsTestKey
        perRunScope
        observationRevision
        testConfig
        transportFailure
        `shouldReturn` Left
          ( LegacyAdoptionPlanRefused
              (LegacyAdoptionCandidatesUnobservable [AwsTestKey])
          )
      observeAndPlanLegacyAdoption
        ExplicitPerRunSurface
        AwsTestKey
        perRunScope
        observationRevision
        testConfig
        wrongKind
        `shouldReturn` Left
          ( LegacyAdoptionPlanRefused
              (LegacyAdoptionCandidatesUnobservable [AwsTestKey])
          )

    it "refuses a non-stack family root before dispatching provider work" $ do
      calls <- newIORef (0 :: Int)
      let observer =
            LegacyAdoptionProviderObserver
              (\_ -> modifyIORef' calls (+ 1) >> pure (Left "must not run"))
      observeAndPlanLegacyAdoption
        ExplicitPerRunSurface
        AwsEbsPerRunTestKey
        perRunScope
        observationRevision
        testConfig
        observer
        `shouldReturn` Left
          (LegacyAdoptionObservationKeyUnsupported AwsEbsPerRunTestKey)
      readIORef calls `shouldReturn` 0

assertObservedFamily :: RegisteredResourceKey -> Expectation
assertObservedFamily stackKey = do
  calls <- newIORef []
  let observer =
        LegacyAdoptionProviderObserver $ \intent -> do
          modifyIORef' calls (<> [intent])
          pure (Right (observationResult intent))
  result <-
    observeAndPlanLegacyAdoption
      ExplicitPerRunSurface
      stackKey
      (scopeFor stackKey)
      observationRevision
      (configFor stackKey)
      observer
  case result of
    Left err -> expectationFailure (show err)
    Right plan -> do
      legacyAdoptionPlanStackKey plan `shouldBe` stackKey
      map legacyAdoptionEntryKey (legacyAdoptionPlanEntries plan)
        `shouldBe` legacyAdoptionExpectedFamily stackKey
  observed <- readIORef calls
  map providerIntentResourceKey observed
    `shouldBe` legacyAdoptionExpectedFamily stackKey
  observed `shouldSatisfy` all isReadOnlyIntent

observationResult :: ProviderIntent -> ProviderIntentExecutionResult
observationResult intent =
  ProviderIntentExecutionObserved
    (providerIntentCoordinate intent)
    ( case intent of
        ObserveNativeStackFamily ref _ ->
          mustRight (encodeAwsNativeStackFamilyEvidence ref [])
        ObserveTestEbsVolumes _ -> ebsAbsentEvidence
        ObserveEksIamRoleFamily _ _ -> iamAbsentEvidence
        ObserveEksLoadBalancerControllerFamily _ _ -> lbcAbsentEvidence
        _ -> "unexpected mutation intent"
    )

isReadOnlyIntent :: ProviderIntent -> Bool
isReadOnlyIntent intent = case intent of
  ObserveNativeStackFamily _ _ -> True
  ObserveTestEbsVolumes _ -> True
  ObserveEksIamRoleFamily _ _ -> True
  ObserveEksLoadBalancerControllerFamily _ _ -> True
  _ -> False

providerIntentResourceKey :: ProviderIntent -> RegisteredResourceKey
providerIntentResourceKey intent = case intent of
  ObserveNativeStackFamily ref _ -> case providerNativeStackFamilyStackRef ref of
    stackRef
      | providerStackRefText stackRef == "aws-eks-subzone" -> AwsEksSubzoneKey
      | providerStackRefText stackRef == "aws-eks" -> AwsEksKey
      | otherwise -> AwsTestKey
  ObserveTestEbsVolumes _ -> AwsEbsPerRunTestKey
  ObserveEksIamRoleFamily _ _ -> AwsEksIamRoleFamilyKey
  ObserveEksLoadBalancerControllerFamily _ _ ->
    AwsEksLoadBalancerControllerFamilyKey
  _ -> AwsTestKey

ebsAbsentEvidence :: Text.Text
ebsAbsentEvidence = "prodbox-test-ebs-observation/v1:absent"

iamAbsentEvidence :: Text.Text
iamAbsentEvidence =
  Text.unlines
    ( ["prodbox-eks-iam-family/v1"]
        <> map (\name -> "role|" <> name <> "|absent") awsEksIamRoleNames
        <> map (\name -> "policy|" <> name <> "|absent") awsEksIamManagedPolicyNames
    )

lbcAbsentEvidence :: Text.Text
lbcAbsentEvidence = "prodbox-eks-lbc-family/v1"

stackAbsentEvidence :: Text.Text
stackAbsentEvidence = "registered stack is absent"

observationRevision :: ObservationRevision
observationRevision = ObservationRevision 73

perRunScope :: ObservationEvidenceScope
perRunScope =
  mkObservationEvidenceScope
    ExplicitPerRun
    lifecycleRegistryRevision
    (DurableObservationRunScope "legacy-adoption-observer-run")
    (LinuxRke2FoundationId "home-rke2")
    ( Just
        ( AwsScope
            (AwsAccountId "123456789012")
            (AwsRegion (fixtureAwsRegion FixtureCaCentral1))
        )
    )
    ReconcileDesiredAbsent

scopeFor :: RegisteredResourceKey -> ObservationEvidenceScope
scopeFor AwsEksSubzoneKey =
  mkObservationEvidenceScopeWithDnsZone
    ExplicitPerRun
    lifecycleRegistryRevision
    (DurableObservationRunScope "legacy-adoption-observer-run")
    (LinuxRke2FoundationId "home-rke2")
    ( Just
        ( AwsScope
            (AwsAccountId "123456789012")
            (AwsRegion (fixtureAwsRegion FixtureCaCentral1))
        )
    )
    (mustRight (mkHostedZoneId "ZSUBZONE123"))
    ReconcileDesiredAbsent
scopeFor _ = perRunScope

configFor :: RegisteredResourceKey -> ProviderStackConfig
configFor AwsEksKey = mustRight (mkAwsEksProviderStackConfig "203.0.113.1/32")
configFor AwsEksSubzoneKey =
  mustRight
    (mkAwsEksSubzoneProviderStackConfig "ZPARENT123" "aws.example.test")
configFor _ = testConfig

testConfig :: ProviderStackConfig
testConfig = mustRight (mkAwsTestProviderStackConfig "203.0.113.1/32")

mustRight :: (Show errorValue) => Either errorValue value -> value
mustRight value = case value of
  Right result -> result
  Left err -> error ("expected Right, got " <> show err)
