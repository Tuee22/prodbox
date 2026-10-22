{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module AwsLifecycleCanary (awsLifecycleCanarySuite) where

import AwsCanaryFixtures
import Control.Monad (forM_)
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Lifecycle.AwsAuditEvidence (AuditBinding (..))
import Prodbox.Lifecycle.AwsTestCanary
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Test.AwsLifecycle
import Prodbox.Test.AwsLifecycleCanary
import TestSupport

awsLifecycleCanarySuite :: SuiteBuilder ()
awsLifecycleCanarySuite = describe "Sprint 5.59 registered canary client plan" $ do
  it
    "takes the root run and AWS binding from registration and the creating stack markers from outputs"
    $ planCanaryPlantIntent scope targets outputs
      `shouldBe` Right (PlantTestVpcCanary fixtureCanaryReference fixtureCanaryRequest)
  forM_ targets $ \missing ->
    it ("refuses creation without a registered cleanup target " ++ show missing) $
      planCanaryPlantIntent scope (filter (/= missing) targets) outputs `shouldSatisfy` isLeft
  it "refuses duplicate targets and unrelated network families" $ do
    planCanaryPlantIntent scope (targets ++ [AwsTestKey]) outputs `shouldSatisfy` isLeft
    planCanaryPlantIntent
      scope
      [AwsTestKey, AwsEksVpcCniInterfacesKey, AwsEksClusterSecurityGroupsKey]
      outputs
      `shouldSatisfy` isLeft
  it "does not need a hosted-zone binding or uncreated DNS/EKS capabilities" $ do
    evidenceAwsDnsZone scope `shouldBe` Nothing
    planCanaryPlantIntent scope targets outputs
      `shouldBe` Right (PlantTestVpcCanary fixtureCanaryReference fixtureCanaryRequest)
  it "requires observed AWS coordinates even when outputs look complete" $ do
    planCanaryPlantIntent (scopeFor "cleanup/run" Nothing) targets outputs `shouldSatisfy` isLeft
    lifecycleAwsBindingFromScope (scopeFor "cleanup/run" Nothing) `shouldSatisfy` isLeft
    lifecycleAwsBindingFromScope scope
      `shouldBe` Right (AuditBinding "123456789012" (fixtureAwsRegion FixtureUsEast1))
  forM_ ["vpc_id", "subnet_ids", "prodbox_run_scope", "prodbox_submission"] $ \missing ->
    it ("refuses a missing recorded output " ++ Text.unpack missing) $
      planCanaryPlantIntent scope targets (Map.delete missing outputs) `shouldSatisfy` isLeft
  it "requires the exact current output keys rather than guessing a legacy run prefix" $ do
    let legacy = Map.insert "run_scope" "stack/run" (Map.delete "prodbox_run_scope" outputs)
    planCanaryPlantIntent scope targets legacy `shouldSatisfy` isLeft
  it "rejects malformed, repeated, incomplete and oversized subnet projections" $ do
    forM_
      [ "not json"
      , "[]"
      , "{}"
      , "[1,2,3]"
      , subnetArray [subnet, subnet, subnet]
      , subnetArray [subnet]
      , subnetArray [subnet, "subnet-00000000000000003", "wrong-prefix-00000000000000004"]
      , subnetArray
          [subnet, "subnet-00000000000000003", "subnet-00000000000000004", "subnet-00000000000000005"]
      , Text.replicate 513 " "
      ]
      $ \bad -> planCanaryPlantIntent scope targets (Map.insert "subnet_ids" bad outputs) `shouldSatisfy` isLeft
  it "rejects wrong VPC and creating-run coordinates without echoing unrelated secret outputs" $ do
    forM_ [("vpc_id", "wrong"), ("prodbox_run_scope", ""), ("prodbox_submission", "unrecorded")] $ \(key, bad) -> do
      let result = planCanaryPlantIntent scope targets (Map.insert key bad outputs)
      result `shouldSatisfy` isLeft
      show result `shouldSatisfy` (not . Text.isInfixOf "unused-unit-secret" . Text.pack)
  it "binds a successor cleanup run into the signed intent coordinate and interface idempotency token" $ do
    let successor = must (planCanaryPlantIntent (scopeFor "cleanup/successor" awsScope) targets outputs)
        original = must (planCanaryPlantIntent scope targets outputs)
    providerIntentCoordinate successor `shouldNotBe` providerIntentCoordinate original
    case successor of
      PlantTestVpcCanary _ request ->
        testCanaryClientToken request `shouldNotBe` testCanaryClientToken fixtureCanaryRequest
      _ -> error "closed canary intent required"

scope :: ObservationEvidenceScope
scope = scopeFor "cleanup/run" awsScope

scopeFor :: Text -> Maybe AwsScope -> ObservationEvidenceScope
scopeFor run target =
  mkObservationEvidenceScope
    ExplicitPerRun
    (RegistryRevision "fixture-registry")
    (DurableObservationRunScope run)
    (LinuxRke2FoundationId "fixture-home")
    target
    ReconcileDesiredAbsent

awsScope :: Maybe AwsScope
awsScope = Just (AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureUsEast1)))

targets :: [RegisteredResourceKey]
targets = lifecycleExerciseCleanupTargets AwsTestVpcCanary

subnet :: Text
subnet = "subnet-00000000000000002"

outputs :: Map.Map Text Text
outputs =
  Map.fromList
    [ ("vpc_id", "vpc-00000000000000001")
    , ("subnet_ids", subnetArray [subnet, "subnet-00000000000000003", "subnet-00000000000000004"])
    , ("prodbox_run_scope", "stack/run")
    , ("prodbox_submission", "create/submission")
    , ("ssh_private_key", "unused-unit-secret")
    ]

subnetArray :: [Text] -> Text
subnetArray = TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

must :: (Show error) => Either error a -> a
must = either (error . show) id
