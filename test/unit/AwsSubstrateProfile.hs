{-# LANGUAGE OverloadedStrings #-}

module AwsSubstrateProfile
  ( awsSubstrateProfileSuite
  )
where

import Data.List (isInfixOf)
import Data.Text qualified as Text
import Dhall qualified
import Prodbox.Cluster.Topology qualified as ClusterTopology
import Prodbox.Lifecycle.EbsVolume qualified as EbsVolume
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderStackConfigView (..)
  , mkAwsEksProfileProviderStackConfig
  , mkAwsTestProfileProviderStackConfig
  , providerStackConfigView
  )
import Prodbox.Settings
  ( AwsSubstrateSection (..)
  , ConfigFile (..)
  , defaultConfigFile
  , renderConfigDhall
  )
import Prodbox.Settings.AwsSubstrateProfile
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import TestSupport

awsSubstrateProfileSuite :: SuiteBuilder ()
awsSubstrateProfileSuite =
  describe "Sprint 7.37 authored AWS substrate profile" $ do
    it "refuses every named malformed envelope before minting a profile" $ do
      mkAwsSubstrateProfile (validInput {eks_node_instance_type = ""})
        `shouldBe` Left (AwsSubstrateProfileFieldEmpty "eks_node_instance_type")
      mkAwsSubstrateProfile (validInput {aws_test_root_volume_sizes_gib = [31, 0, 33]})
        `shouldBe` Left (AwsSubstrateProfileFieldZero "aws_test_root_volume_sizes_gib")
      mkAwsSubstrateProfile (validInput {operator_cidr = "999.1.2.3/32"})
        `shouldBe` Left (AwsSubstrateProfileMalformedCidr "operator_cidr")
      mkAwsSubstrateProfile (validInput {eks_vpc_cidr = "10.71.0.1/32"})
        `shouldBe` Left (AwsSubstrateProfileHostCidrForNetwork "eks_vpc_cidr")
      mkAwsSubstrateProfile (validInput {static_ebs_volume_type = "magnetic-plus"})
        `shouldBe` Left (AwsSubstrateProfileUnsupportedVolumeType "magnetic-plus")
      let profile = mustRight (mkAwsSubstrateProfile (validInput {eks_node_max_size = 2}))
      awsEksStackConfiguration profile 3
        `shouldBe` Left (AwsSubstrateProfileMaximumBelowDesired 2 3)
      awsEksStackConfiguration profile 0
        `shouldBe` Left (AwsSubstrateProfileFieldZero "cluster_topology.Eks.node_group_size")

    it "renders every EKS and aws-test program key from authored values" $ do
      let profile = mustRight (mkAwsSubstrateProfile validInput)
      awsEksStackConfiguration profile 3
        `shouldBe` Right
          [ ("operatorCidr", "203.0.113.44/32")
          , ("nodeInstanceType", "m7i.large")
          , ("nodeDiskSizeGiB", "61")
          , ("nodeDesiredSize", "3")
          , ("nodeMinSize", "2")
          , ("nodeMaxSize", "5")
          , ("vpcCidr", "10.71.0.0/16")
          , ("subnet0Cidr", "10.71.10.0/24")
          , ("subnet1Cidr", "10.71.20.0/24")
          ]
      awsTestStackConfiguration profile
        `shouldBe` Right
          [ ("operatorCidr", "203.0.113.44/32")
          , ("node0InstanceType", "m7i.large")
          , ("node1InstanceType", "m7i.xlarge")
          , ("node2InstanceType", "c7i.large")
          , ("node0RootVolumeType", "gp3")
          , ("node1RootVolumeType", "io2")
          , ("node2RootVolumeType", "gp2")
          , ("node0RootVolumeSizeGiB", "31")
          , ("node1RootVolumeSizeGiB", "32")
          , ("node2RootVolumeSizeGiB", "33")
          , ("vpcCidr", "10.72.0.0/16")
          , ("subnet0Cidr", "10.72.10.0/24")
          , ("subnet1Cidr", "10.72.20.0/24")
          , ("subnet2Cidr", "10.72.30.0/24")
          ]

    it "binds the full profile and topology node count inside appended provider configs" $ do
      let profile = mustRight (mkAwsSubstrateProfile validInput)
          eksConfig = mustRight (mkAwsEksProfileProviderStackConfig profile 3)
          testConfig = mustRight (mkAwsTestProfileProviderStackConfig profile)
      providerStackConfigView eksConfig `shouldBe` AwsEksProfileConfig profile 3
      providerStackConfigView testConfig `shouldBe` AwsTestProfileConfig profile

    it "round-trips a present profile through the generated Tier-0 record codec" $ do
      let profile = mustRight (mkAwsSubstrateProfile validInput)
          section = (aws_substrate defaultConfigFile) {profile = Just profile}
          configured =
            defaultConfigFile
              { aws_substrate = section
              , cluster_topology = ClusterTopology.defaultClusterTopology
              }
      decoded <- Dhall.input Dhall.auto (Text.pack (renderConfigDhall configured))
      decoded `shouldBe` configured

    it "uses the validated static EBS type in the create request" $ do
      let profile = mustRight (mkAwsSubstrateProfile validInput)
          required = EbsVolume.EbsRequiredVolume "pv-authored" 25 "ca-central-1a"
          args =
            EbsVolume.ebsCreateVolumeArgs
              (awsSubstrateStaticEbsVolumeType profile)
              required
      args `shouldContain` ["--volume-type", "io2"]

    it "keeps every retired resource literal and the IP-echo client out of production sources" $ do
      repoRoot <- getCurrentDirectory
      eksProgram <- readFile (repoRoot </> "pulumi" </> "aws-eks" </> "Main.yaml")
      testProgram <- readFile (repoRoot </> "pulumi" </> "aws-test" </> "Main.yaml")
      eksInfra <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "AwsEksTestStack.hs")
      testInfra <- readFile (repoRoot </> "src" </> "Prodbox" </> "Infra" </> "AwsTestStack.hs")
      mapM_
        (\literal -> eksProgram `shouldSatisfy` (not . isInfixOf literal))
        [ "10.91.0.0/16"
        , "10.91.0.0/24"
        , "10.91.1.0/24"
        , "instanceTypes:\n        - t3.large"
        , "diskSize: 50"
        , "desiredSize: 2"
        ]
      mapM_
        (\literal -> testProgram `shouldSatisfy` (not . isInfixOf literal))
        [ "10.90.0.0/16"
        , "10.90.0.0/24"
        , "10.90.1.0/24"
        , "10.90.2.0/24"
        , "instanceType: t3.large"
        , "volumeType: gp3"
        , "volumeSize: 30"
        ]
      eksInfra `shouldSatisfy` (not . isInfixOf "api.ipify.org")
      testInfra `shouldSatisfy` (not . isInfixOf "api.ipify.org")

validInput :: AwsSubstrateProfileInput
validInput =
  AwsSubstrateProfileInput
    { operator_cidr = "203.0.113.44/32"
    , eks_node_instance_type = "m7i.large"
    , eks_node_disk_size_gib = 61
    , eks_node_min_size = 2
    , eks_node_max_size = 5
    , aws_test_instance_types = ["m7i.large", "m7i.xlarge", "c7i.large"]
    , aws_test_root_volume_types = ["gp3", "io2", "gp2"]
    , aws_test_root_volume_sizes_gib = [31, 32, 33]
    , static_ebs_volume_type = "io2"
    , eks_vpc_cidr = "10.71.0.0/16"
    , eks_subnet_cidrs = ["10.71.10.0/24", "10.71.20.0/24"]
    , aws_test_vpc_cidr = "10.72.0.0/16"
    , aws_test_subnet_cidrs = ["10.72.10.0/24", "10.72.20.0/24", "10.72.30.0/24"]
    }

mustRight :: (Show left) => Either left right -> right
mustRight value = case value of
  Left err -> error (show err)
  Right result -> result
