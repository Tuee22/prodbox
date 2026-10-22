{-# LANGUAGE OverloadedStrings #-}

-- | A canary body consumes the exact fresh registration handed to it by the
-- durable bracket. Neither a second nonce nor an inferred output prefix can
-- supply its cleanup scope.
module Prodbox.Test.AwsLifecycleCanary
  ( registeredCanaryPlantIntent
  , planCanaryPlantIntent
  , registeredLifecycleAwsBinding
  , lifecycleAwsBindingFromScope
  ) where

import Control.Monad (unless)
import Data.Aeson (eitherDecodeStrict')
import Data.Bifunctor (first)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Lifecycle.AwsAuditEvidence (AuditBinding (..))
import Prodbox.Lifecycle.AwsTestCanary
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Test.AwsLifecycle
import Prodbox.Test.LifecycleCleanupClient
  ( HarnessBodyScope
  , harnessBodyObservationScope
  , harnessBodyRegisteredTargets
  )

registeredCanaryPlantIntent :: HarnessBodyScope -> Map.Map Text Text -> Either Text ProviderIntent
registeredCanaryPlantIntent registered =
  planCanaryPlantIntent
    (harnessBodyObservationScope registered)
    (harnessBodyRegisteredTargets registered)

registeredLifecycleAwsBinding :: HarnessBodyScope -> Either Text AuditBinding
registeredLifecycleAwsBinding = lifecycleAwsBindingFromScope . harnessBodyObservationScope

lifecycleAwsBindingFromScope :: ObservationEvidenceScope -> Either Text AuditBinding
lifecycleAwsBindingFromScope scope = case evidenceAwsScope scope of
  Nothing -> Left "AWS lifecycle registration has no observed account/region"
  Just (AwsScope (AwsAccountId account) (AwsRegion region)) -> Right (AuditBinding account region)

-- This pure planner constructs an unsigned intent, never execution authority.
-- Production enters it only through the opaque registered-body wrapper above.
planCanaryPlantIntent
  :: ObservationEvidenceScope
  -> [RegisteredResourceKey]
  -> Map.Map Text Text
  -> Either Text ProviderIntent
planCanaryPlantIntent scope targets outputs = do
  unless
    (length (nub targets) == length targets)
    (Left "canary registration repeats a resource target")
  unless
    (all (`elem` targets) (lifecycleExerciseCleanupTargets AwsTestVpcCanary))
    (Left "canary registration does not declare the test stack and both network families before creation")
  AwsScope (AwsAccountId account) (AwsRegion region) <-
    maybe (Left "canary registration has no observed AWS account/region") Right (evidenceAwsScope scope)
  let DurableObservationRunScope runScope = evidenceDurableRunScope scope
  vpc <- required "vpc_id"
  stackRun <- required "prodbox_run_scope"
  submission <- required "prodbox_submission"
  subnetJson <- required "subnet_ids"
  unless (Text.length subnetJson <= 512) (Left "canary recorded subnet array exceeds its bound")
  subnets <-
    first
      (const "canary stack subnet output is not a JSON string array")
      (eitherDecodeStrict' (TextEncoding.encodeUtf8 subnetJson) :: Either String [Text])
  subnet <- case subnets of
    [firstSubnet, secondSubnet, thirdSubnet]
      | length (nub subnets) == 3 -> do
          _ <- first renderTestCanaryError (validateCanaryEc2Identifier CanarySubnet secondSubnet)
          _ <- first renderTestCanaryError (validateCanaryEc2Identifier CanarySubnet thirdSubnet)
          Right firstSubnet
    _ -> Left "canary requires the test stack's three distinct recorded subnets"
  binding <- first renderTestCanaryError (mkTestCanaryBinding runScope stackRun submission)
  request <- first renderTestCanaryError (mkTestVpcCanaryRequest vpc subnet binding)
  stack <- first (const "canary stack reference is invalid") (mkProviderStackRef "aws-test")
  ref <-
    first
      (const "canary registered account/region is invalid")
      (mkProviderNativeStackFamilyRef stack account region Nothing)
  Right (PlantTestVpcCanary ref request)
 where
  required key = maybe (Left ("canary stack output is missing " <> key)) Right (Map.lookup key outputs)
