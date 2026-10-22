{-# LANGUAGE OverloadedStrings #-}

-- Authored unit fixtures. These are never promoted as live provider recordings.
module AwsCanaryFixtures
  ( fixtureCanaryRequest
  , fixtureCanaryReference
  , fixtureCanaryTranscript
  , fixtureCanaryEvidence
  ) where

import Data.Text (Text)
import Prodbox.Lifecycle.AwsProviderRecording
import Prodbox.Lifecycle.AwsTestCanary
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import TestSupport (FixtureAwsRegion (FixtureUsEast1), fixtureAwsRegion)

fixtureCanaryRequest :: TestVpcCanaryRequest
fixtureCanaryRequest = must $ do
  binding <- mkTestCanaryBinding "cleanup/run" "stack/run" "create/submission"
  mkTestVpcCanaryRequest "vpc-00000000000000001" "subnet-00000000000000002" binding

fixtureCanaryReference :: ProviderNativeStackFamilyRef
fixtureCanaryReference = must $ do
  stack <- mkProviderStackRef "aws-test"
  mkProviderNativeStackFamilyRef stack "123456789012" (fixtureAwsRegion FixtureUsEast1) Nothing

fixtureCanaryTranscript :: ProviderTranscript
fixtureCanaryTranscript =
  ProviderTranscript
    LiveCanaryCapture
    [ ProviderRecordedCall "delete-security-group:held" 100 254 "" (dependency "sg-00000000000000003")
    , ProviderRecordedCall "delete-security-group:left" 200 254 "" (dependency "sg-00000000000000004")
    ]
 where
  dependency identity =
    "aws: [ERROR]: An error occurred (DependencyViolation) when calling the DeleteSecurityGroup operation: resource "
      <> identity
      <> " has a dependent object"

fixtureCanaryEvidence :: Text
fixtureCanaryEvidence = must $ scrubProviderRecording [] fixtureCanaryTranscript >>= canaryPlantRecordingEvidence

must :: (Show error) => Either error a -> a
must = either (error . show) id
