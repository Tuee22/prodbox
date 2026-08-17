{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownAwsEksAdapter
  ( lifecycleTeardownAwsEksAdapterSuite
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , mkProviderStackRef
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownAwsEksAdapterSuite :: SuiteBuilder ()
lifecycleTeardownAwsEksAdapterSuite =
  describe "Sprint 4.85 exact EKS ProviderIntent adapter" $ do
    it "binds the repository EKS identity to its exact account, region, and cluster" $ do
      let request = decisionRequest
      awsEksObservationRequestKey request `shouldBe` AwsEksKey
      awsEksObservationRequestScope request `shouldBe` exactScope
      awsEksObservationRequestRevision request `shouldBe` initialRevision
      awsEksObservationRequestClusterName request `shouldBe` canonicalClusterName
      case awsEksObservationRequestProviderIntent request of
        ObserveEksClusterIdentity _ -> pure ()
        intent -> expectationFailure ("unexpected intent: " <> show intent)
      awsEksObservationRequestProviderCoordinate request
        `shouldBe` providerIntentCoordinate (awsEksObservationRequestProviderIntent request)

    it "refuses a missing AWS scope, stale registry, wrong operation, and disallowed surface" $ do
      mkAwsEksDecisionObservationRequest
        initialRevision
        (scopeFor Cascade Nothing ReconcileDesiredAbsent lifecycleRegistryRevision)
        `shouldBe` Left AwsEksAwsScopeMissing
      mkAwsEksDecisionObservationRequest initialRevision staleRegistryScope
        `shouldBe` Left
          ( AwsEksRegistryRevisionMismatch
              lifecycleRegistryRevision
              staleRegistryRevision
          )
      mkAwsEksDecisionObservationRequest
        initialRevision
        (scopeFor Cascade validAwsScope ReconcileDesiredPresent lifecycleRegistryRevision)
        `shouldBe` Left (AwsEksOperationInvalid ReconcileDesiredPresent)
      mkAwsEksDecisionObservationRequest
        initialRevision
        (scopeFor LocalOnly validAwsScope ReconcileDesiredAbsent lifecycleRegistryRevision)
        `shouldSatisfy` isLeft

    it "decodes only exact not-found or an account/region/name-bound EKS ARN" $ do
      let absent = decodedExact decisionRequest exactAbsentEvidence
          present = decodedExact decisionRequest exactPresentEvidence
      exactObservationResult absent
        `shouldBe` ExactResourceAbsent
          (AbsenceEvidence "Provider EKS DescribeCluster returned exact not-found evidence")
      exactObservationResult present
        `shouldBe` ExactResourcePresent
          ( ExactResourceInventory
              (ObservedResourceIdentity canonicalArn :| [])
          )
      assertExactBinding decisionRequest absent
      assertExactBinding decisionRequest present
      case decodeEvidence decisionRequest exactPresentEvidence of
        AwsEksObservationDecoded verified ->
          verifiedAwsEksClusterArn verified `shouldBe` Just canonicalArn
        AwsEksObservationRejected err _ ->
          expectationFailure ("canonical ARN rejected: " <> show err)

    it "keeps malformed and cross-scope ARN evidence unobservable" $ do
      mapM_
        ( \evidence -> do
            let observation = awsEksObservationDecodeObservation (decodeEvidence decisionRequest evidence)
            exactObservationResult observation `shouldSatisfy` isUnobservable
            exactObservationResult observation `shouldSatisfy` isNotAbsent
        )
        [ exactAbsentEvidence <> " "
        , "eks-cluster-arn:arn:aws:eks:us-west-2:123456789012:cluster/aws-eks-test-cluster"
        , "eks-cluster-arn:arn:aws:eks:us-east-1:999999999999:cluster/aws-eks-test-cluster"
        , "eks-cluster-arn:arn:aws:eks:us-east-1:123456789012:cluster/another-cluster"
        , "eks-cluster-arn:"
        , "sha256:0123456789abcdef"
        , "connection refused"
        ]

    it "turns provider inability into unobservable evidence and never absence" $ do
      let decoded = decodeAwsEksObservation decisionRequest (Left "provider unavailable")
          observation = awsEksObservationDecodeObservation decoded
      decoded `shouldSatisfy` isRejected
      exactObservationResult observation `shouldSatisfy` isUnobservable
      exactObservationResult observation `shouldSatisfy` isNotAbsent

    it "rejects wrong coordinates and mutation-shaped results for both purposes" $ do
      let request = decisionRequest
          expected = awsEksObservationRequestProviderCoordinate request
          otherRef = mustRight (mkProviderStackRef "aws-test")
          other = providerIntentCoordinate (ObserveRegisteredStack otherRef)
      decodeAwsEksObservation
        request
        (Right (ProviderIntentExecutionObserved other exactAbsentEvidence))
        `shouldSatisfy` isRejected
      decodeAwsEksObservation
        request
        (Right (ProviderIntentExecutionApplied expected exactAbsentEvidence))
        `shouldSatisfy` isRejected
      let readBack = readBackRequest
      awsEksObservationRequestProviderCoordinate readBack
        `shouldBe` providerIntentCoordinate (awsEksObservationRequestProviderIntent readBack)
      case decodeEvidence readBack exactAbsentEvidence of
        AwsEksObservationDecoded verified ->
          exactObservationResult (verifiedAwsEksExactObservation verified)
            `shouldSatisfy` isAbsent
        AwsEksObservationRejected err _ ->
          expectationFailure ("exact read-back refused: " <> show err)

decisionRequest
  :: ExactAwsEksObservationRequest 'ObserveEksForDecision
decisionRequest =
  mustRight (mkAwsEksDecisionObservationRequest initialRevision exactScope)

readBackRequest
  :: ExactAwsEksObservationRequest 'ReadBackEksDesiredAbsent
readBackRequest =
  mustRight (mkAwsEksDesiredAbsenceReadBackRequest readBackRevision exactScope)

decodeEvidence
  :: ExactAwsEksObservationRequest purpose
  -> Text
  -> AwsEksObservationDecode purpose
decodeEvidence request evidence =
  decodeAwsEksObservation
    request
    ( Right
        ( ProviderIntentExecutionObserved
            (awsEksObservationRequestProviderCoordinate request)
            evidence
        )
    )

decodedExact
  :: ExactAwsEksObservationRequest purpose
  -> Text
  -> ExactResourceObservation
decodedExact request evidence = case decodeEvidence request evidence of
  AwsEksObservationDecoded verified -> verifiedAwsEksExactObservation verified
  AwsEksObservationRejected err _ -> error ("expected decoded EKS evidence: " <> show err)

assertExactBinding
  :: ExactAwsEksObservationRequest purpose
  -> ExactResourceObservation
  -> Expectation
assertExactBinding request observation = do
  exactObservationResourceKey observation `shouldBe` AwsEksKey
  exactObservationAuthority observation `shouldBe` AwsResourceApiAuthority
  exactObservationRevision observation `shouldBe` awsEksObservationRequestRevision request
  exactObservationEvidenceScope observation `shouldBe` awsEksObservationRequestScope request

scopeFor
  :: CleanupSurface
  -> Maybe AwsScope
  -> LifecycleOperation
  -> RegistryRevision
  -> ObservationEvidenceScope
scopeFor surface awsScope operation revision =
  mkObservationEvidenceScope
    surface
    revision
    (DurableObservationRunScope "aws-eks-adapter-run")
    (LinuxRke2FoundationId "home-rke2")
    awsScope
    operation

exactScope :: ObservationEvidenceScope
exactScope =
  scopeFor Cascade validAwsScope ReconcileDesiredAbsent lifecycleRegistryRevision

staleRegistryScope :: ObservationEvidenceScope
staleRegistryScope =
  scopeFor Cascade validAwsScope ReconcileDesiredAbsent staleRegistryRevision

validAwsScope :: Maybe AwsScope
validAwsScope =
  Just (AwsScope (AwsAccountId "123456789012") (AwsRegion "us-east-1"))

staleRegistryRevision :: RegistryRevision
staleRegistryRevision = RegistryRevision "lifecycle-registry/stale"

initialRevision, readBackRevision :: ObservationRevision
initialRevision = ObservationRevision 101
readBackRevision = ObservationRevision 102

canonicalClusterName :: Text
canonicalClusterName = "aws-eks-test-cluster"

canonicalArn :: Text
canonicalArn =
  "arn:aws:eks:us-east-1:123456789012:cluster/aws-eks-test-cluster"

exactAbsentEvidence, exactPresentEvidence :: Text
exactAbsentEvidence = "registered EKS cluster is absent"
exactPresentEvidence = "eks-cluster-arn:" <> canonicalArn

isLeft :: Either left right -> Bool
isLeft result = case result of
  Left _ -> True
  Right _ -> False

isRejected :: AwsEksObservationDecode purpose -> Bool
isRejected decoded = case decoded of
  AwsEksObservationRejected {} -> True
  AwsEksObservationDecoded {} -> False

isAbsent, isUnobservable, isNotAbsent :: ExactObservationResult -> Bool
isAbsent result = case result of
  ExactResourceAbsent {} -> True
  _ -> False
isUnobservable result = case result of
  ExactResourceUnobservable {} -> True
  _ -> False
isNotAbsent result = not (isAbsent result)

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
