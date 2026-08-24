{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownAwsLoadBalancerControllerFamilyAdapter
  ( lifecycleTeardownAwsLoadBalancerControllerFamilyAdapterSuite
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.AwsLoadBalancerControllerFamilyAdapter
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.RegisteredTargetExecutor
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownAwsLoadBalancerControllerFamilyAdapterSuite :: SuiteBuilder ()
lifecycleTeardownAwsLoadBalancerControllerFamilyAdapterSuite =
  describe "Sprint 7.36 exact EKS load-balancer controller-family adapter" $ do
    it "lands its registry descriptor and production executor together" $ do
      lookupRegisteredIdentity AwsEksLoadBalancerControllerFamilyKey
        `shouldSatisfy` isJustIdentity
      registeredTargetExecutorFor AwsEksLoadBalancerControllerFamilyKey
        `shouldBe` Right EksLoadBalancerControllerFamilyExecutor

    it "binds both Provider intents to the deterministic name and tag set" $ do
      awsLoadBalancerControllerFamilyObservationRequestProviderIntent request
        `shouldBe` ObserveEksLoadBalancerControllerFamily familyName renderedTags
      fmap
        (fmap awsLoadBalancerControllerFamilyReapProviderIntent)
        (authorizeExactAwsLoadBalancerControllerFamilyReap request presentObservation)
        `shouldBe` Right
          (Just (ReapEksLoadBalancerControllerFamily familyName renderedTags))

    it "projects only onto per-run cleanup surfaces" $ do
      mkExactAwsLoadBalancerControllerFamilyObservationRequest
        ExplicitPerRunSurface
        revision
        perRunScope
        `shouldSatisfy` isRightResult
      mkExactAwsLoadBalancerControllerFamilyObservationRequest
        CascadeSurface
        revision
        (scopeFor Cascade)
        `shouldSatisfy` isRightResult
      mkExactAwsLoadBalancerControllerFamilyObservationRequest
        ExplicitLongLivedSurface
        revision
        (scopeFor ExplicitLongLived)
        `shouldSatisfy` isLeftResult

    it "decodes only canonical duplicate-free exact family evidence" $ do
      exactObservationResult (decode absentEvidence)
        `shouldSatisfy` isExactAbsent
      exactObservationResult presentObservation
        `shouldSatisfy` isExactPresent
      map
        (exactObservationResult . decode)
        [ ""
        , "prodbox-eks-lbc-family/v1\nunknown|arn:aws:unknown"
        , presentEvidence <> "load-balancer|arn:aws:elasticloadbalancing:lb/public-edge\n"
        ]
        `shouldSatisfy` all isExactUnobservable

    it "turns transport and coordinate failures into non-absence facts" $ do
      exactObservationResult
        ( mustRight
            ( decodeExactAwsLoadBalancerControllerFamilyObservation
                request
                (Left "ELBv2 refused")
            )
        )
        `shouldSatisfy` isExactUnobservable
      decodeExactAwsLoadBalancerControllerFamilyObservation
        request
        ( Right
            ( ProviderIntentExecutionObserved
                (providerIntentCoordinate (ObserveTestEbsVolumes "other"))
                absentEvidence
            )
        )
        `shouldSatisfy` isLeftResult

    it "authorizes no mutation from absence and closes only on read-back" $ do
      authorizeExactAwsLoadBalancerControllerFamilyReap request (decode absentEvidence)
        `shouldBe` Right Nothing
      confirmExactAwsLoadBalancerControllerFamilyAbsence request (observed presentEvidence)
        `shouldSatisfy` isLeftResult
      confirmExactAwsLoadBalancerControllerFamilyAbsence request (observed absentEvidence)
        `shouldSatisfy` isRightResult

request :: ExactAwsLoadBalancerControllerFamilyObservationRequest
request =
  mustRight
    ( mkExactAwsLoadBalancerControllerFamilyObservationRequest
        ExplicitPerRunSurface
        revision
        perRunScope
    )

decode :: Text -> ExactResourceObservation
decode evidence =
  mustRight
    (decodeExactAwsLoadBalancerControllerFamilyObservation request (observed evidence))

presentObservation :: ExactResourceObservation
presentObservation = decode presentEvidence

observed :: Text -> Either Text ProviderIntentExecutionResult
observed evidence =
  Right
    ( ProviderIntentExecutionObserved
        ( providerIntentCoordinate
            (awsLoadBalancerControllerFamilyObservationRequestProviderIntent request)
        )
        evidence
    )

absentEvidence :: Text
absentEvidence = "prodbox-eks-lbc-family/v1"

presentEvidence :: Text
presentEvidence =
  Text.unlines
    [ "prodbox-eks-lbc-family/v1"
    , "load-balancer|arn:aws:elasticloadbalancing:lb/public-edge"
    , "listener|arn:aws:elasticloadbalancing:listener/public-edge/443"
    , "target-group|arn:aws:elasticloadbalancing:targetgroup/public-edge"
    , "security-group|arn:aws:ec2:"
        <> fixtureAwsRegion FixtureCaCentral1
        <> ":123456789012:security-group/sg-public-edge"
    ]

familyName :: Text
familyName = awsEksLoadBalancerControllerName

renderedTags :: Text
renderedTags =
  Text.intercalate
    "|"
    (map (\(key, value) -> key <> "=" <> value) awsEksLoadBalancerControllerTags)

revision :: ObservationRevision
revision = ObservationRevision 92

perRunScope :: ObservationEvidenceScope
perRunScope = scopeFor ExplicitPerRun

scopeFor :: CleanupSurface -> ObservationEvidenceScope
scopeFor surface =
  mkObservationEvidenceScope
    surface
    lifecycleRegistryRevision
    (DurableObservationRunScope "lbc-family-adapter-run")
    (LinuxRke2FoundationId "home-rke2")
    ( Just
        ( AwsScope
            (AwsAccountId "123456789012")
            (AwsRegion (fixtureAwsRegion FixtureCaCentral1))
        )
    )
    ReconcileDesiredAbsent

isJustIdentity :: Maybe RegisteredIdentity -> Bool
isJustIdentity (Just _) = True
isJustIdentity Nothing = False

isRightResult :: Either left right -> Bool
isRightResult (Right _) = True
isRightResult (Left _) = False

isLeftResult :: Either left right -> Bool
isLeftResult (Left _) = True
isLeftResult (Right _) = False

isExactAbsent :: ExactObservationResult -> Bool
isExactAbsent (ExactResourceAbsent _) = True
isExactAbsent _ = False

isExactPresent :: ExactObservationResult -> Bool
isExactPresent (ExactResourcePresent _) = True
isExactPresent _ = False

isExactUnobservable :: ExactObservationResult -> Bool
isExactUnobservable (ExactResourceUnobservable _) = True
isExactUnobservable _ = False

mustRight :: (Show error) => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error (show err)
