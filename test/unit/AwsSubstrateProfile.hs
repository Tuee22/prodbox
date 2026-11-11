{-# LANGUAGE OverloadedStrings #-}

module AwsSubstrateProfile
  ( awsSubstrateProfileSuite
  )
where

import Control.Monad (forM_)
import Data.Either (isRight)
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Dhall qualified
import Prodbox.Cluster.Substrate qualified as ClusterSubstrate
import Prodbox.Cluster.Topology qualified as ClusterTopology
import Prodbox.Infra.AwsEksTestStack (awsEksDesiredNodeCount)
import Prodbox.Lifecycle.EbsVolume qualified as EbsVolume
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderStackConfigView (..)
  , mkAwsEksProfileProviderStackConfig
  , mkAwsEksProfileZoneProviderStackConfig
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
    forM_ listCardinalityCases $ \(fieldName, _, _, unreadTailInput) ->
      it ("rejects an overlong " <> Text.unpack fieldName <> " before reading its tail") $
        case mkAwsSubstrateProfile unreadTailInput of
          Left _ -> pure ()
          Right _ -> expectationFailure "an overlong AWS list was accepted"

    it "preserves exact list errors and successful profiles for finite cardinalities" $
      forM_ listCardinalityCases $ \(fieldName, expected, inputForCount, _) ->
        forM_ [0 .. 12] $ \count ->
          if count == expected
            then mkAwsSubstrateProfile (inputForCount count) `shouldSatisfy` isRight
            else
              mkAwsSubstrateProfile (inputForCount count)
                `shouldBe` Left (AwsSubstrateProfileListLength fieldName expected count)

    it "preserves the full accepted CIDR decimal grammar before bounded splitting" $ do
      forM_ [0 :: Int .. 255] $ \octet -> do
        let part = Text.pack (show octet)
            cidr = Text.intercalate "." (replicate 4 part) <> "/032"
        (awsSubstrateOperatorCidr <$> mkAwsSubstrateProfile (validInput {operator_cidr = cidr}))
          `shouldBe` Right cidr
      forM_ [0 :: Int .. 31] $ \prefix -> do
        let digits = Text.justifyRight 3 '0' (Text.pack (show prefix))
            cidr = "0.0.0.0/" <> digits
            profile = mustRight (mkAwsSubstrateProfile (validInput {eks_vpc_cidr = cidr}))
        (lookup "vpcCidr" <$> awsEksStackConfiguration profile 3) `shouldBe` Right (Just (Text.unpack cidr))
      forM_ ["1.2.3.4/0000", "1.2.3.4.5/032", "256.1.2.3/032", Text.replicate 128 "0."] $ \cidr ->
        mkAwsSubstrateProfile (validInput {operator_cidr = cidr})
          `shouldBe` Left (AwsSubstrateProfileMalformedCidr "operator_cidr")

    it "checks token length before lowercasing without changing normalization or refusals" $ do
      forM_ [(Text.replicate 64 "A", replicate 64 'a'), (Text.replicate 64 "K", replicate 64 'k')] $ \(raw, expected) -> do
        let profile = mustRight (mkAwsSubstrateProfile (validInput {eks_node_instance_type = "  " <> raw <> "  "}))
        (lookup "nodeInstanceType" <$> awsEksStackConfiguration profile 3) `shouldBe` Right (Just expected)
      forM_ [Text.replicate 65 "A", Text.replicate 63 "A" <> "İ", Text.replicate 256 "A", " "] $ \raw ->
        mkAwsSubstrateProfile (validInput {eks_node_instance_type = raw})
          `shouldBe` Left (AwsSubstrateProfileFieldEmpty "eks_node_instance_type")

    it "keeps supported EBS spellings and the original unsupported value" $ do
      forM_ ["gp2", "gp3", "io1", "io2", "st1", "sc1", "standard"] $ \token ->
        (awsEbsVolumeTypeText <$> mkAwsEbsVolumeType ("  " <> Text.toUpper token <> "  "))
          `shouldBe` Right token
      forM_ ["standardx", Text.replicate 256 "A", Text.replicate 16 "İ", " "] $ \raw ->
        mkAwsEbsVolumeType raw `shouldBe` Left (AwsSubstrateProfileUnsupportedVolumeType raw)

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

    it "carries the exact subzone hosted-zone id in the append-only zoned EKS config" $ do
      let profile = mustRight (mkAwsSubstrateProfile validInput)
      providerStackConfigView
        (mustRight (mkAwsEksProfileZoneProviderStackConfig profile 3 "Z0123456789ABC"))
        `shouldBe` AwsEksProfileZoneConfig profile 3 "Z0123456789ABC"
      mkAwsEksProfileZoneProviderStackConfig profile 3 ""
        `shouldSatisfy` either (const True) (const False)
      mkAwsEksProfileZoneProviderStackConfig profile 3 "Z1\nZ2"
        `shouldSatisfy` either (const True) (const False)

    it
      "takes the EKS desired count from the topology when it is EKS and from the profile minimum otherwise"
      $ do
        let profile = mustRight (mkAwsSubstrateProfile validInput)
            eksTopology = mustRight (ClusterTopology.mkEksTopology 4 ClusterSubstrate.LinuxCpu)
            homeTopology = mustRight (ClusterTopology.mkSingleMachineRke2Topology "home-machine")
        awsEksDesiredNodeCount profile eksTopology `shouldBe` 4
        awsEksDesiredNodeCount profile homeTopology
          `shouldBe` awsSubstrateEksMinimumNodeCount profile
        awsSubstrateEksMinimumNodeCount profile `shouldBe` 2
        let fallback = awsEksDesiredNodeCount profile homeTopology
        awsEksStackConfiguration profile fallback
          `shouldSatisfy` either (const False) (elem ("nodeDesiredSize", "2"))
        providerStackConfigView
          (mustRight (mkAwsEksProfileProviderStackConfig profile fallback))
          `shouldBe` AwsEksProfileConfig profile 2

    it "still refuses a profile whose maximum is below the minimum the fallback selects" $ do
      let profile = mustRight (mkAwsSubstrateProfile (validInput {eks_node_min_size = 4, eks_node_max_size = 3}))
          homeTopology = mustRight (ClusterTopology.mkSingleMachineRke2Topology "home-machine")
      awsEksStackConfiguration profile (awsEksDesiredNodeCount profile homeTopology)
        `shouldBe` Left (AwsSubstrateProfileMaximumBelowDesired 3 4)

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

listCardinalityCases
  :: [(Text.Text, Int, Int -> AwsSubstrateProfileInput, AwsSubstrateProfileInput)]
listCardinalityCases =
  [
    ( "aws_test_instance_types"
    , 3
    , \count -> validInput {aws_test_instance_types = replicate count "m7i.large"}
    , validInput
        { aws_test_instance_types =
            replicate 4 "m7i.large" <> error "synthetic instance-list tail forced"
        }
    )
  ,
    ( "aws_test_root_volume_types"
    , 3
    , \count -> validInput {aws_test_root_volume_types = replicate count "gp3"}
    , validInput
        { aws_test_root_volume_types =
            replicate 4 "gp3" <> error "synthetic volume-type-list tail forced"
        }
    )
  ,
    ( "aws_test_root_volume_sizes_gib"
    , 3
    , \count -> validInput {aws_test_root_volume_sizes_gib = replicate count 31}
    , validInput
        { aws_test_root_volume_sizes_gib =
            replicate 4 31 <> error "synthetic volume-size-list tail forced"
        }
    )
  ,
    ( "eks_subnet_cidrs"
    , 2
    , \count -> validInput {eks_subnet_cidrs = replicate count "10.71.10.0/24"}
    , validInput
        { eks_subnet_cidrs =
            replicate 3 "10.71.10.0/24" <> error "synthetic EKS-subnet-list tail forced"
        }
    )
  ,
    ( "aws_test_subnet_cidrs"
    , 3
    , \count -> validInput {aws_test_subnet_cidrs = replicate count "10.72.10.0/24"}
    , validInput
        { aws_test_subnet_cidrs =
            replicate 4 "10.72.10.0/24" <> error "synthetic test-subnet-list tail forced"
        }
    )
  ]

validInput :: AwsSubstrateProfileInput
validInput = syntheticAwsSubstrateProfileInput

mustRight :: (Show left) => Either left right -> right
mustRight value = case value of
  Left err -> error (show err)
  Right result -> result
