{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownAwsIamRoleFamilyAdapter
  ( lifecycleTeardownAwsIamRoleFamilyAdapterSuite
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
import Prodbox.Lifecycle.Teardown.AwsIamRoleFamilyAdapter
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.RegisteredTargetExecutor
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

lifecycleTeardownAwsIamRoleFamilyAdapterSuite :: SuiteBuilder ()
lifecycleTeardownAwsIamRoleFamilyAdapterSuite =
  describe "Sprint 7.36 exact EKS IAM role-family adapter" $ do
    it "lands its registry descriptor and production executor together" $ do
      lookupRegisteredIdentity AwsEksIamRoleFamilyKey
        `shouldSatisfy` isJustIdentity
      registeredTargetExecutorFor AwsEksIamRoleFamilyKey
        `shouldBe` Right EksIamRoleFamilyExecutor

    it "derives every deterministic Pulumi role and policy name exactly" $ do
      program <- Text.pack <$> readFile "pulumi/aws-eks/Main.yaml"
      mapM_
        (\fragment -> program `shouldSatisfy` Text.isInfixOf fragment)
        [ "name: ${iamNamePrefix}-cluster-role"
        , "name: ${iamNamePrefix}-node-role"
        , "name: ${iamNamePrefix}-lbc-role"
        , "name: ${stackName}-ebs-csi-driver"
        , "name: ${stackName}-aws-lb-controller"
        ]
      awsEksIamRoleNames
        `shouldBe` [ "prodbox-aws-eks-test-aws-eks-test-cluster-cluster-role"
                   , "prodbox-aws-eks-test-aws-eks-test-cluster-node-role"
                   , "prodbox-aws-eks-test-aws-eks-test-cluster-lbc-role"
                   , "aws-eks-test-ebs-csi-driver"
                   ]
      awsEksIamManagedPolicyNames
        `shouldBe` ["aws-eks-test-aws-lb-controller"]

    it "projects only onto per-run cleanup surfaces" $ do
      mkExactAwsIamRoleFamilyObservationRequest
        ExplicitPerRunSurface
        revision
        perRunScope
        `shouldSatisfy` isRightResult
      mkExactAwsIamRoleFamilyObservationRequest
        CascadeSurface
        revision
        (scopeFor Cascade)
        `shouldSatisfy` isRightResult
      mkExactAwsIamRoleFamilyObservationRequest
        ExplicitLongLivedSurface
        revision
        (scopeFor ExplicitLongLived)
        `shouldSatisfy` isLeftResult

    it "binds both Provider intents to the exact registry projection" $ do
      awsIamRoleFamilyObservationRequestProviderIntent request
        `shouldBe` ObserveEksIamRoleFamily roleNames policyNames
      fmap
        (fmap awsIamRoleFamilyReapProviderIntent)
        (authorizeExactAwsIamRoleFamilyReap request presentObservation)
        `shouldBe` Right (Just (ReapEksIamRoleFamily roleNames policyNames))

    it "accepts only a complete, duplicate-free family observation" $ do
      exactObservationResult (decode absentEvidence)
        `shouldSatisfy` isExactAbsent
      exactObservationResult presentObservation
        `shouldSatisfy` isExactPresent
      map
        (exactObservationResult . decode)
        [ ""
        , "prodbox-eks-iam-family/v1\nrole|unexpected|absent"
        , absentEvidence <> "role|unexpected|absent\n"
        , absentEvidence <> "role|" <> primaryRoleName <> "|absent\n"
        ]
        `shouldSatisfy` all isExactUnobservable

    it "turns transport and coordinate failures into non-absence facts" $ do
      exactObservationResult
        ( mustRight
            (decodeExactAwsIamRoleFamilyObservation request (Left "iam refused"))
        )
        `shouldSatisfy` isExactUnobservable
      decodeExactAwsIamRoleFamilyObservation
        request
        ( Right
            ( ProviderIntentExecutionObserved
                (providerIntentCoordinate (ObserveTestEbsVolumes "other"))
                absentEvidence
            )
        )
        `shouldSatisfy` isLeftResult

    it "authorizes no mutation from absence and closes only on read-back" $ do
      authorizeExactAwsIamRoleFamilyReap request (decode absentEvidence)
        `shouldBe` Right Nothing
      confirmExactAwsIamRoleFamilyAbsence request (observed presentEvidence)
        `shouldSatisfy` isLeftResult
      confirmExactAwsIamRoleFamilyAbsence request (observed absentEvidence)
        `shouldSatisfy` isRightResult

request :: ExactAwsIamRoleFamilyObservationRequest
request =
  mustRight
    ( mkExactAwsIamRoleFamilyObservationRequest
        ExplicitPerRunSurface
        revision
        perRunScope
    )

decode :: Text -> ExactResourceObservation
decode evidence =
  mustRight (decodeExactAwsIamRoleFamilyObservation request (observed evidence))

presentObservation :: ExactResourceObservation
presentObservation = decode presentEvidence

observed :: Text -> Either Text ProviderIntentExecutionResult
observed evidence =
  Right
    ( ProviderIntentExecutionObserved
        ( providerIntentCoordinate
            (awsIamRoleFamilyObservationRequestProviderIntent request)
        )
        evidence
    )

absentEvidence :: Text
absentEvidence = familyEvidence (const Nothing) (const Nothing)

presentEvidence :: Text
presentEvidence =
  familyEvidence
    (\name -> if name == primaryRoleName then Just ("arn:role:" <> name) else Nothing)
    (\name -> Just ("arn:policy:" <> name))

familyEvidence
  :: (Text -> Maybe Text)
  -> (Text -> Maybe Text)
  -> Text
familyEvidence roleArn policyArn =
  Text.unlines
    ( ["prodbox-eks-iam-family/v1"]
        <> map (row "role" roleArn) awsEksIamRoleNames
        <> map (row "policy" policyArn) awsEksIamManagedPolicyNames
    )
 where
  row kind arnFor name = case arnFor name of
    Nothing -> kind <> "|" <> name <> "|absent"
    Just arn -> kind <> "|" <> name <> "|present|" <> arn

roleNames, policyNames :: Text
roleNames = Text.intercalate "|" awsEksIamRoleNames
policyNames = Text.intercalate "|" awsEksIamManagedPolicyNames

primaryRoleName :: Text
primaryRoleName = "prodbox-aws-eks-test-aws-eks-test-cluster-cluster-role"

revision :: ObservationRevision
revision = ObservationRevision 91

perRunScope :: ObservationEvidenceScope
perRunScope = scopeFor ExplicitPerRun

scopeFor :: CleanupSurface -> ObservationEvidenceScope
scopeFor surface =
  mkObservationEvidenceScope
    surface
    lifecycleRegistryRevision
    (DurableObservationRunScope "eks-iam-role-family-adapter-run")
    (LinuxRke2FoundationId "home-rke2")
    (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureCaCentral1))))
    ReconcileDesiredAbsent

isExactAbsent, isExactPresent, isExactUnobservable :: ExactObservationResult -> Bool
isExactAbsent result = case result of
  ExactResourceAbsent _ -> True
  _ -> False
isExactPresent result = case result of
  ExactResourcePresent _ -> True
  _ -> False
isExactUnobservable result = case result of
  ExactResourceUnobservable _ -> True
  _ -> False

isJustIdentity :: Maybe RegisteredIdentity -> Bool
isJustIdentity (Just _) = True
isJustIdentity Nothing = False

isRightResult :: Either error value -> Bool
isRightResult (Right _) = True
isRightResult (Left _) = False

isLeftResult :: Either error value -> Bool
isLeftResult (Left _) = True
isLeftResult (Right _) = False

mustRight :: (Show error) => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error (show err)
