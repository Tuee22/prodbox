{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 5.53: the Provider's EBS and Route 53 validation-zone interpreters
-- start the AWS CLI through the runner they are given.
--
-- Every other AWS child the Provider Worker starts goes through one bounded,
-- permit-serialised runner (a 30-second lifetime, capped output, one child at a
-- time). These two interpreters started their own unbounded process, so a hung
-- `aws ec2 describe-volumes` held a Provider request open with no limit and no
-- permit. They now take the runner as an argument, which a unit case can
-- script, and the Provider passes its own.
module ProviderAwsRunner (providerAwsRunnerSuite) where

import Control.Monad (forM_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (intercalate, isInfixOf)
import Prodbox.Lifecycle.EbsVolume qualified as EbsVolume
import Prodbox.Lifecycle.TagSweep qualified as TagSweep
import Prodbox.Lifecycle.ValidationHostedZone qualified as Route53ValidationZone
import Prodbox.Result (Result (..))
import Prodbox.Settings.AwsSubstrateProfile (mkAwsEbsVolumeType)
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import TestSupport

-- | A runner that records every argument vector it is given and answers from a table.
recordingRun
  :: IORef [[String]]
  -> ([String] -> Result ProcessOutput)
  -> EbsVolume.AwsCliRun
recordingRun calls answer arguments = do
  modifyIORef' calls (++ [arguments])
  pure (answer arguments)

succeeded :: String -> Result ProcessOutput
succeeded stdout = Success (ProcessOutput ExitSuccess stdout "")

fixtureZone :: String
fixtureZone = fixtureAwsRegion FixtureCaCentral1 <> "a"

-- | One volume in the shape @aws ec2 describe-volumes@ prints it.
volumeJson :: String -> [(String, String)] -> String
volumeJson identifier tags =
  "{\"VolumeId\":\""
    <> identifier
    <> "\",\"State\":\"available\",\"AvailabilityZone\":\""
    <> fixtureZone
    <> "\",\"Size\":5,\"Tags\":["
    <> intercalate "," ["{\"Key\":\"" <> key <> "\",\"Value\":\"" <> value <> "\"}" | (key, value) <- tags]
    <> "]}"

-- | A @describe-volumes@ payload listing the given volumes.
listing :: [String] -> String
listing volumes = "{\"Volumes\":[" <> intercalate "," volumes <> "]}"

providerAwsRunnerSuite :: SuiteBuilder ()
providerAwsRunnerSuite =
  describe
    "Sprint 5.53 the Provider's EBS and Route 53 interpreters run through the runner they are given"
    $ do
      it "starts every EBS invocation through the injected runner, with exactly the documented arguments" $ do
        calls <- newIORef []
        volumeType <- either (fail . show) pure (mkAwsEbsVolumeType "gp3")
        let required = EbsVolume.EbsRequiredVolume "pv-a" 5 fixtureZone
            volumeId = EbsVolume.EbsVolumeId "vol-0new"
            retainedTags =
              [ (EbsVolume.ebsPersistentVolumeTagKey, "pv-a")
              , (TagSweep.prodboxManagedByTagKey, TagSweep.prodboxManagedByTagValue)
              , (TagSweep.ebsLifecycleTagKey, TagSweep.ebsRetainedLifecycleValue)
              ]
            runAnswer arguments = case arguments of
              "ec2" : "describe-volumes" : _ -> succeeded (listing [volumeJson "vol-0listed" retainedTags])
              "ec2" : "create-volume" : _ -> succeeded (volumeJson "vol-0new" [])
              "ec2" : "wait" : _ -> succeeded ""
              "ec2" : "delete-volume" : _ -> succeeded ""
              _ -> Failure ("unscripted invocation: " <> unwords arguments)
            run = recordingRun calls runAnswer
        listed <- EbsVolume.discoverEbsVolumesVia run EbsVolume.EbsRetainedProduction
        fmap (map EbsVolume.ebsVolumeId) listed `shouldBe` Right [EbsVolume.EbsVolumeId "vol-0listed"]
        fmap (map EbsVolume.ebsVolumeSizeGiB) listed `shouldBe` Right [Just 5]
        EbsVolume.createRetainedVolumeVia run volumeType required `shouldReturn` Right volumeId
        EbsVolume.waitForCreatedVolumesVia run [volumeId] `shouldReturn` Right ()
        EbsVolume.destroyEbsVolumeVia run volumeId `shouldReturn` Right ()
        readIORef calls
          >>= ( `shouldBe`
                  [ EbsVolume.ebsDescribeVolumesArgs EbsVolume.EbsRetainedProduction
                  , EbsVolume.ebsCreateVolumeArgs volumeType required
                  , EbsVolume.ebsWaitVolumeAvailableArgs [volumeId]
                  , EbsVolume.ebsDeleteVolumeArgs volumeId
                  ]
              )

      it "runs both reapers through the injected runner and deletes only what each plan selects" $ do
        calls <- newIORef []
        let clusterName = "aws-eks-test-cluster"
            perRunTags =
              [ (TagSweep.ebsClusterOwnedTagKey clusterName, "owned")
              , (TagSweep.ebsLifecycleTagKey, TagSweep.ebsTestScopedLifecycleValue)
              ]
            runAnswer arguments = case arguments of
              "ec2" : "describe-volumes" : _ -> succeeded (listing [volumeJson "vol-0perrun" perRunTags])
              "ec2" : "delete-volume" : _ -> succeeded ""
              _ -> Failure ("unscripted invocation: " <> unwords arguments)
            run = recordingRun calls runAnswer
        EbsVolume.runTestScopedEbsReaperVia run clusterName
          >>= \report ->
            fmap EbsVolume.testEbsReaperDeletedVolumeIds report
              `shouldBe` Right [EbsVolume.EbsVolumeId "vol-0perrun"]
        readIORef calls
          >>= ( `shouldBe`
                  [ EbsVolume.ebsDescribeVolumesArgs (EbsVolume.EbsPerRunTest clusterName)
                  , EbsVolume.ebsDeleteVolumeArgs (EbsVolume.EbsVolumeId "vol-0perrun")
                  ]
              )
        -- The retained reaper lists the retained family and, with nothing in it, deletes nothing.
        retainedCalls <- newIORef []
        let emptyRunAnswer arguments = case arguments of
              "ec2" : "describe-volumes" : _ -> succeeded (listing [])
              _ -> Failure ("unscripted invocation: " <> unwords arguments)
            emptyRun = recordingRun retainedCalls emptyRunAnswer
        EbsVolume.runRetainedEbsReaperVia emptyRun
          >>= \report -> fmap EbsVolume.retainedEbsReaperDeletedVolumeIds report `shouldBe` Right []
        readIORef retainedCalls
          >>= (`shouldBe` [EbsVolume.ebsDescribeVolumesArgs EbsVolume.EbsRetainedProduction])

      it "names a process that could not start, and the arguments of a refused invocation" $ do
        calls <- newIORef []
        let cannotStart = recordingRun calls (const (Failure "no such file or directory"))
            refused =
              recordingRun calls (const (Success (ProcessOutput (ExitFailure 254) "" "UnauthorizedOperation")))
        startFailure <- EbsVolume.discoverEbsVolumesVia cannotStart EbsVolume.EbsRetainedProduction
        startFailure
          `shouldBe` Left "failed to start `aws ec2 describe-volumes`: no such file or directory"
        refusal <- EbsVolume.destroyEbsVolumeVia refused (EbsVolume.EbsVolumeId "vol-0x")
        refusal `shouldBe` Left "aws ec2 delete-volume failed for vol-0x: UnauthorizedOperation"

      it "starts every Route 53 validation-zone invocation through the injected runner" $ do
        calls <- newIORef []
        let zoneName = Route53ValidationZone.validationHostedZoneName "abc" "example.invalid"
            run :: Route53ValidationZone.AwsCliText
            run arguments = do
              modifyIORef' calls (++ [arguments])
              pure $ case arguments of
                "route53" : "list-hosted-zones" : _ ->
                  Right ("{\"HostedZones\":[{\"Id\":\"/hostedzone/ZABC\",\"Name\":\"" <> zoneName <> "\"}]}")
                "route53" : "list-resource-record-sets" : _ -> Right "[]"
                "route53" : "delete-hosted-zone" : _ -> Right "{}"
                "route53" : "get-hosted-zone" : _ ->
                  Left "An error occurred (NoSuchHostedZone) when calling the GetHostedZone operation"
                _ -> Left ("unscripted invocation: " <> unwords arguments)
        Route53ValidationZone.destroyValidationHostedZones run `shouldReturn` ExitSuccess
        invocations <- readIORef calls
        -- Discovery, the record-set prune, the delete, and the read-back that proves it absent.
        map (take 2) invocations
          `shouldBe` [ ["route53", "list-hosted-zones"]
                     , ["route53", "list-resource-record-sets"]
                     , ["route53", "delete-hosted-zone"]
                     , ["route53", "get-hosted-zone"]
                     ]
        Route53ValidationZone.discoverValidationHostedZones run
          `shouldReturn` Right [("/hostedzone/ZABC", zoneName)]
        -- A finished invocation's exit status, not the runner, decides success.
        Route53ValidationZone.awsCliTextFromOutput
          ["route53", "x"]
          (ProcessOutput (ExitFailure 2) "" "boom")
          `shouldBe` Left "aws route53 x failed with exit code 2: boom"
        Route53ValidationZone.awsCliTextFromOutput ["route53", "x"] (ProcessOutput ExitSuccess "out" "")
          `shouldBe` Right "out"

      it "keeps the Provider's interpreters off the direct, unbounded EBS and Route 53 entrances" $ do
        source <- readFile "src/Prodbox/ControlPlane/ProviderProduction.hs"
        let callsDirectly name = any (`isInfixOf` source) [name <> " ", name <> "\n"]
        forM_
          [ "EbsVolume.discoverEbsVolumes"
          , "EbsVolume.ensureRetainedEbsVolumes"
          , "EbsVolume.destroyEbsVolume"
          , "EbsVolume.runTestScopedEbsReaper"
          , "EbsVolume.runRetainedEbsReaper"
          , "TaggedResourceQuery.discoverTaggedResources"
          ]
          (\name -> (name, callsDirectly name) `shouldBe` (name, False))
        -- The negative control: the bounded entrances the Provider does use are present.
        source `shouldSatisfy` isInfixOf "EbsVolume.discoverEbsVolumesVia (boundedAwsCliRun environment)"
        source `shouldSatisfy` isInfixOf "boundedAwsCliText environment"
        source `shouldSatisfy` isInfixOf "TaggedResourceQuery.discoverTaggedResourcesVia"
