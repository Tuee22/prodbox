{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownEksDrainSession
  ( lifecycleTeardownEksDrainSessionSuite
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import EksClientAuthProjectionFixture (testEksClientAuthProjection)
import Prodbox.ControlPlane.EksClientAuthProjection
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (ProviderIntentExecutionObserved)
  )
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (providerIntentCoordinate)
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
import Prodbox.Lifecycle.Teardown.EksDrainSession
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownEksDrainSessionSuite :: SuiteBuilder ()
lifecycleTeardownEksDrainSessionSuite = do
  describe "Sprint 7.36 exact EKS drain session" $ do
    it "mints only from exact positive EKS evidence and a matching short-lived projection" $ do
      case fixtureSession of
        Left err -> expectationFailure (show err)
        Right session -> do
          eksClusterArnText (eksDrainSessionClusterArn session) `shouldBe` fixtureArn
          eksClusterUidText (eksDrainSessionClusterUid session) `shouldBe` fixtureUid
          eksDrainSessionOperationId session `shouldBe` fixtureOperation
          eksDrainSessionEvidenceScope session `shouldBe` fixtureScope
          eksDrainSessionExpiresAtEpochSeconds session `shouldBe` 1_500
          Text.length (eksDrainSessionEndpointDigest session) `shouldBe` 64
          Text.length (eksDrainSessionCertificateAuthorityDigest session) `shouldBe` 64
          show session `shouldNotContain` "bearer-secret"
          withEksDrainClientProjection session eksClientAuthBearerToken
            `shouldBe` "bearer-secret"

    it "refuses exact Provider absence and cannot receive rejected Provider evidence" $ do
      mkSession fixtureAbsentVerified fixtureProjection
        `shouldSatisfy` isObservationNotPresent
      rejectedVerified "provider unavailable" `shouldSatisfy` isRejected
      rejectedVerified "eks-cluster-uid:forged" `shouldSatisfy` isRejected

    it "requires an independently observed provider ARN and live Kubernetes UID" $ do
      mkSession fixtureVerified fixtureProjection `shouldSatisfy` isRight
      rejectedVerified ("eks-cluster-uid:" <> fixtureUid) `shouldSatisfy` isRejected
      mkEksDrainSession
        1_000
        1_500
        fixtureOperation
        fixtureScope
        fixtureVerified
        fixtureKubernetes
          { eksKubernetesIdentityResult =
              EksKubernetesIdentityUnobservable (ObservationFailure "API read failed")
          }
        fixtureProjection
        `shouldBe` Left
          ( EksDrainKubernetesIdentityNotPresent
              (EksKubernetesIdentityUnobservable (ObservationFailure "API read failed"))
          )

    it "binds the Kubernetes UID observation to scope, ARN, endpoint, and CA" $ do
      let otherScope =
            mkObservationEvidenceScope
              Cascade
              lifecycleRegistryRevision
              (DurableObservationRunScope "other-run")
              fixtureFoundation
              (Just fixtureAwsScope)
              ReconcileDesiredAbsent
      mkEksDrainSession
        1_000
        1_500
        fixtureOperation
        fixtureScope
        fixtureVerified
        fixtureKubernetes {eksKubernetesIdentityScope = otherScope}
        fixtureProjection
        `shouldBe` Left (EksDrainKubernetesScopeMismatch fixtureScope otherScope)
      mkSessionWith
        fixtureKubernetes {eksKubernetesIdentityClusterArn = fixtureArn <> "-other"}
        `shouldBe` Left
          ( EksDrainKubernetesClusterArnMismatch
              fixtureClusterArn
              (fixtureArn <> "-other")
          )
      mkSessionWith
        fixtureKubernetes {eksKubernetesIdentityEndpointDigest = Text.replicate 64 "0"}
        `shouldBe` Left
          ( EksDrainKubernetesEndpointMismatch
              (eksKubernetesIdentityEndpointDigest fixtureKubernetes)
              (Text.replicate 64 "0")
          )
      mkSessionWith
        fixtureKubernetes
          { eksKubernetesIdentityCertificateAuthorityDigest = Text.replicate 64 "f"
          }
        `shouldBe` Left
          ( EksDrainKubernetesCertificateAuthorityMismatch
              (eksKubernetesIdentityCertificateAuthorityDigest fixtureKubernetes)
              (Text.replicate 64 "f")
          )
      mkSessionWith
        fixtureKubernetes {eksKubernetesIdentityResult = EksKubernetesIdentityPresent "bad uid!"}
        `shouldBe` Left (EksDrainClusterUidInvalid "bad uid!")

    it "binds account, region, cluster name, and projection lifetime" $ do
      let wrongAccount =
            mustProjection
              "999900001111"
              "ca-central-1"
              fixtureClusterName
              1_800
          wrongRegion =
            mustProjection
              "111122223333"
              "us-east-1"
              fixtureClusterName
              1_800
          wrongCluster =
            mustProjection
              "111122223333"
              "ca-central-1"
              "other-cluster"
              1_800
          wrongArn =
            mustProjectionWithArn
              "111122223333"
              "ca-central-1"
              fixtureClusterName
              ("arn:aws-us-gov:eks:ca-central-1:111122223333:cluster/" <> fixtureClusterName)
              1_800
          expired =
            mustProjection
              "111122223333"
              "ca-central-1"
              fixtureClusterName
              999
      mkSession fixtureVerified wrongAccount
        `shouldBe` Left
          ( EksDrainProjectionAccountMismatch
              (AwsAccountId "111122223333")
              "999900001111"
          )
      mkSession fixtureVerified wrongRegion
        `shouldBe` Left
          (EksDrainProjectionRegionMismatch (AwsRegion "ca-central-1") "us-east-1")
      mkSession fixtureVerified wrongCluster
        `shouldBe` Left
          (EksDrainProjectionClusterMismatch fixtureClusterName "other-cluster")
      mkSession fixtureVerified wrongArn
        `shouldBe` Left
          (EksDrainProjectionClusterArnMismatch fixtureClusterArn (eksClientAuthClusterArn wrongArn))
      mkSession fixtureVerified expired
        `shouldBe` Left (EksDrainProjectionExpired 1_000 999)
      mkEksDrainSession
        1_000
        1_801
        fixtureOperation
        fixtureScope
        fixtureVerified
        fixtureKubernetes
        fixtureProjection
        `shouldBe` Left (EksDrainDeadlineInvalid 1_000 1_801)
      let longLivedProjection =
            mustProjection
              "111122223333"
              "ca-central-1"
              fixtureClusterName
              5_000
      mkEksDrainSession
        1_000
        1_901
        fixtureOperation
        fixtureScope
        fixtureVerified
        fixtureKubernetes
        longLivedProjection
        `shouldBe` Left (EksDrainDeadlineBeyondMaximum 1_901 900)

    it "rejects another run and keeps invalid operations and surfaces before admission" $ do
      let wrongRun =
            mkObservationEvidenceScope
              Cascade
              lifecycleRegistryRevision
              (DurableObservationRunScope "other-run")
              fixtureFoundation
              (Just fixtureAwsScope)
              ReconcileDesiredAbsent
          wrongOperation =
            mkObservationEvidenceScope
              Cascade
              lifecycleRegistryRevision
              fixtureRunScope
              fixtureFoundation
              (Just fixtureAwsScope)
              RunTerminalEscapeAudit
          wrongSurface =
            mkObservationEvidenceScope
              OperationalTeardown
              lifecycleRegistryRevision
              fixtureRunScope
              fixtureFoundation
              (Just fixtureAwsScope)
              ReconcileDesiredAbsent
          wrongRunVerified = verifiedPresentFor (ObservationRevision 7) wrongRun
      mkEksDrainSession
        1_000
        1_500
        fixtureOperation
        fixtureScope
        wrongRunVerified
        fixtureKubernetes
        fixtureProjection
        `shouldBe` Left
          (EksDrainObservationScopeMismatch fixtureScope wrongRun)
      mkAwsEksDecisionObservationRequest (ObservationRevision 7) wrongOperation
        `shouldBe` Left (AwsEksOperationInvalid RunTerminalEscapeAudit)
      mkAwsEksDecisionObservationRequest (ObservationRevision 7) wrongSurface
        `shouldSatisfy` isSurfaceRejected

    it "revalidates run, operation, observation revision, and deadline at use" $ do
      session <- case fixtureSession of
        Left err -> expectationFailure (show err) >> fail "unreachable"
        Right value -> pure value
      validateEksDrainSession
        1_100
        fixtureOperation
        fixtureScope
        fixtureVerified
        fixtureKubernetes
        session
        `shouldBe` Right ()
      validateEksDrainSession
        1_500
        fixtureOperation
        fixtureScope
        fixtureVerified
        fixtureKubernetes
        session
        `shouldBe` Left (EksDrainSessionExpired 1_500 1_500)
      validateEksDrainSession
        1_100
        otherOperation
        fixtureScope
        fixtureVerified
        fixtureKubernetes
        session
        `shouldBe` Left EksDrainSessionBindingMismatch
      validateEksDrainSession
        1_100
        fixtureOperation
        fixtureScope
        (verifiedPresentFor (ObservationRevision 8) fixtureScope)
        fixtureKubernetes
        session
        `shouldBe` Left EksDrainSessionBindingMismatch
      validateEksDrainSession
        1_100
        fixtureOperation
        fixtureScope
        fixtureVerified
        fixtureKubernetes {eksKubernetesIdentityRevision = ObservationRevision 10}
        session
        `shouldBe` Left EksDrainSessionBindingMismatch

    it "admits drain sessions only from the opaque Provider decision wrapper" $ do
      source <- readFile "src/Prodbox/Lifecycle/Teardown/EksDrainSession.hs"
      source `shouldContain` "VerifiedAwsEksObservation 'ObserveEksForDecision"
      source `shouldNotContain` "mkEksDrainSession now deadline operationId expectedScope observation"
      adapter <- readFile "src/Prodbox/Lifecycle/Teardown/AwsEksAdapter.hs"
      adapter `shouldNotContain` "VerifiedAwsEksObservation (.."

fixtureSession :: Either EksDrainSessionError EksDrainSession
fixtureSession = mkSession fixtureVerified fixtureProjection

mkSession
  :: VerifiedAwsEksObservation 'ObserveEksForDecision
  -> EksClientAuthProjection
  -> Either EksDrainSessionError EksDrainSession
mkSession verified projection =
  mkEksDrainSession
    1_000
    1_500
    fixtureOperation
    fixtureScope
    verified
    fixtureKubernetes
    projection

mkSessionWith
  :: EksKubernetesIdentityObservation
  -> Either EksDrainSessionError EksDrainSession
mkSessionWith kubernetes =
  mkEksDrainSession
    1_000
    1_500
    fixtureOperation
    fixtureScope
    fixtureVerified
    kubernetes
    fixtureProjection

fixtureVerified :: VerifiedAwsEksObservation 'ObserveEksForDecision
fixtureVerified = verifiedPresentFor (ObservationRevision 7) fixtureScope

fixtureAbsentVerified :: VerifiedAwsEksObservation 'ObserveEksForDecision
fixtureAbsentVerified =
  case decodedFor (ObservationRevision 7) fixtureScope "registered EKS cluster is absent" of
    AwsEksObservationDecoded verified -> verified
    AwsEksObservationRejected err _ -> error (show err)

verifiedPresentFor
  :: ObservationRevision
  -> ObservationEvidenceScope
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
verifiedPresentFor revision scope =
  case decodedFor revision scope ("eks-cluster-arn:" <> fixtureArn) of
    AwsEksObservationDecoded verified -> verified
    AwsEksObservationRejected err _ -> error (show err)

rejectedVerified
  :: Text
  -> AwsEksObservationDecode 'ObserveEksForDecision
rejectedVerified = decodedFor (ObservationRevision 7) fixtureScope

decodedFor
  :: ObservationRevision
  -> ObservationEvidenceScope
  -> Text
  -> AwsEksObservationDecode 'ObserveEksForDecision
decodedFor revision scope evidence =
  let request = mustRight (mkAwsEksDecisionObservationRequest revision scope)
   in decodeAwsEksObservation
        request
        ( Right
            ( ProviderIntentExecutionObserved
                (providerIntentCoordinate (awsEksObservationRequestProviderIntent request))
                evidence
            )
        )

fixtureProjection :: EksClientAuthProjection
fixtureProjection =
  mustProjection
    "111122223333"
    "ca-central-1"
    fixtureClusterName
    1_800

fixtureKubernetes :: EksKubernetesIdentityObservation
fixtureKubernetes =
  eksKubernetesIdentityObservationFor
    fixtureScope
    (ObservationRevision 9)
    fixtureArn
    (EksKubernetesIdentityPresent fixtureUid)
    fixtureProjection

mustProjection
  :: Text.Text
  -> Text.Text
  -> Text.Text
  -> Integer
  -> EksClientAuthProjection
mustProjection account region cluster expires =
  mustProjectionWithArn
    account
    region
    cluster
    ("arn:aws:eks:" <> region <> ":" <> account <> ":cluster/" <> cluster)
    expires

mustProjectionWithArn
  :: Text.Text
  -> Text.Text
  -> Text.Text
  -> Text.Text
  -> Integer
  -> EksClientAuthProjection
mustProjectionWithArn account region cluster clusterArn expires =
  case testEksClientAuthProjection
    account
    region
    cluster
    clusterArn
    "https://example.eks.amazonaws.com"
    "Y2EtZGF0YQ=="
    "bearer-secret"
    expires of
    Left err -> error (show err)
    Right value -> value

fixtureScope :: ObservationEvidenceScope
fixtureScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    fixtureRunScope
    fixtureFoundation
    (Just fixtureAwsScope)
    ReconcileDesiredAbsent

fixtureRunScope :: DurableObservationRunScope
fixtureRunScope = DurableObservationRunScope "cleanup-run/eks-drain"

fixtureFoundation :: LinuxRke2FoundationId
fixtureFoundation = LinuxRke2FoundationId "home-linux-rke2"

fixtureAwsScope :: AwsScope
fixtureAwsScope =
  AwsScope (AwsAccountId "111122223333") (AwsRegion "ca-central-1")

fixtureArn :: Text.Text
fixtureArn =
  "arn:aws:eks:ca-central-1:111122223333:cluster/aws-eks-test-cluster"

fixtureUid :: Text.Text
fixtureUid = "eks-generation-7"

fixtureClusterName :: Text.Text
fixtureClusterName = "aws-eks-test-cluster"

fixtureOperation :: CleanupOperationId
fixtureOperation = mustOperation "lifecycle-operation/eks-drain"

otherOperation :: CleanupOperationId
otherOperation = mustOperation "lifecycle-operation/other"

mustOperation :: Text.Text -> CleanupOperationId
mustOperation raw = case mkCleanupOperationId raw of
  Left err -> error (Text.unpack err)
  Right value -> value

fixtureClusterArn :: EksClusterArn
fixtureClusterArn = case fixtureSession of
  Left err -> error (show err)
  Right session -> eksDrainSessionClusterArn session

isObservationNotPresent
  :: Either EksDrainSessionError EksDrainSession -> Bool
isObservationNotPresent result = case result of
  Left (EksDrainObservationNotPresent _) -> True
  _ -> False

isRight :: Either left right -> Bool
isRight result = case result of
  Right _ -> True
  Left _ -> False

isRejected :: AwsEksObservationDecode purpose -> Bool
isRejected decoded = case decoded of
  AwsEksObservationRejected {} -> True
  AwsEksObservationDecoded {} -> False

isSurfaceRejected
  :: Either AwsEksAdapterError value -> Bool
isSurfaceRejected result = case result of
  Left (AwsEksSurfaceNotAllowed _) -> True
  _ -> False

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
