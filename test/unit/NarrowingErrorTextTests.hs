{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module NarrowingErrorTextTests (narrowingErrorTextSuite) where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Void (Void)
import Dhall qualified
import Dhall.Core qualified as Core
import Dhall.Map qualified as Map
import FrozenNarrowingErrors
import Numeric.Natural (Natural)
import PinnedHeapGraph
import Prodbox.Cluster.Substrate qualified as Substrate
import Prodbox.Cluster.Topology qualified as Topology
import Prodbox.Settings.AwsSubstrateProfile qualified as Aws
import Test.Tasty.HUnit
import TestSupport (SuiteBuilder, describe, it, syntheticAwsSubstrateProfileInput)

narrowingErrorTextSuite :: SuiteBuilder ()
narrowingErrorTextSuite = describe "Text narrowing error compatibility" $ do
  it "preserves every AWS error family and the existing String API" $ do
    forM_ awsErrors $ \err -> do
      Aws.renderAwsSubstrateProfileErrorText err @?= Text.pack (frozenAwsError err)
      Aws.renderAwsSubstrateProfileError err @?= frozenAwsError err
    print ("narrowing_text_aws_reference_cases" :: String, length awsErrors)
  it "preserves all topology error constructors and substrate combinations" $ do
    forM_ topologyErrors $ \err -> do
      Topology.renderTopologyErrorText err @?= Text.pack (frozenTopologyError err)
      Topology.renderTopologyError err @?= frozenTopologyError err
    length topologyErrors @?= 23
    print ("narrowing_text_topology_reference_cases" :: String, length topologyErrors)
  it "preserves complete SDK AWS failures and successful narrowed values" $ do
    forM_ invalidProfiles $ \(input, expected) -> do
      Aws.mkAwsSubstrateProfile input @?= Left expected
      expectFailure
        (Proxy @Aws.AwsSubstrateProfile)
        (Core.denote (Dhall.embed Dhall.inject input))
        (Text.pack (frozenAwsError expected))
    forM_
      [ validInput
      , validInput {Aws.operator_cidr = " 203.0.113.44/032 "}
      , validInput {Aws.eks_node_disk_size_gib = 2 ^ (130 :: Int)}
      ]
      $ \input -> do
        expected <- either (fail . show) pure (Aws.mkAwsSubstrateProfile input)
        actual <-
          either
            (fail . show)
            pure
            ( Dhall.toMonadic
                (Dhall.extract (Dhall.auto @Aws.AwsSubstrateProfile) (Dhall.embed Dhall.inject input))
            )
        actual @?= expected
    print ("narrowing_text_aws_sdk_cases" :: String, length invalidProfiles, 3 :: Int)
  it "preserves complete SDK topology failures and accepted MachineIds" $ do
    forM_ ["", " ", "\t\n", "\x2003"] $ \input ->
      expectFailure
        (Proxy @Topology.MachineId)
        (Core.denote (Dhall.embed Dhall.inject (input :: Text)))
        (Text.pack (frozenTopologyError Topology.EmptyMachineId))
    forM_ ["synthetic", " λ😀 ", "\0"] $ \input -> do
      actual <-
        either
          (fail . show)
          pure
          ( Dhall.toMonadic
              (Dhall.extract (Dhall.auto @Topology.MachineId) (Dhall.embed Dhall.inject (input :: Text)))
          )
      Topology.machineIdText actual @?= input
    forM_ substrates $ \machineSubstrate -> forM_ substrates $ \workerSubstrate -> do
      let expression =
            Core.RecordLit
              ( Map.fromList
                  [ ("machine_id", Core.makeRecordField (Core.TextLit (Core.Chunks [] "synthetic")))
                  ,
                    ( "machine_substrate"
                    , Core.makeRecordField (Core.denote (Dhall.embed Dhall.inject machineSubstrate))
                    )
                  ,
                    ( "compute_worker"
                    , Core.makeRecordField
                        (Core.denote (Dhall.embed Dhall.inject (Topology.ComputeWorker workerSubstrate True)))
                    )
                  ]
              )
      if machineSubstrate == workerSubstrate
        then case Dhall.toMonadic (Dhall.extract (Dhall.auto @Topology.Machine) (Core.renote expression)) of
          Left err -> assertFailure (show err)
          Right machine -> Topology.machine_substrate machine @?= machineSubstrate
        else
          expectFailure
            (Proxy @Topology.Machine)
            expression
            (Text.pack (frozenTopologyError (Topology.WorkerSubstrateMismatch machineSubstrate workerSubstrate)))
    expectFailure
      (Proxy @Topology.Rke2Topology)
      ( Core.RecordLit
          ( Map.fromList
              [
                ( "machines"
                , Core.makeRecordField
                    (Core.ListLit (Just (Core.denote (Dhall.declared (Dhall.inject @Topology.Machine)))) mempty)
                )
              ]
          )
      )
      (Text.pack (frozenTopologyError Topology.Rke2TopologyEmpty))
    forM_ substrates $ \substrate -> do
      let zero =
            Core.RecordLit
              ( Map.fromList
                  [ ("node_group_size", Core.makeRecordField (Core.NaturalLit 0))
                  , ("eks_substrate", Core.makeRecordField (Core.denote (Dhall.embed Dhall.inject substrate)))
                  ]
              )
      expectFailure
        (Proxy @Topology.EksTopology)
        zero
        (Text.pack (frozenTopologyError Topology.EksNodeGroupSizeZero))
      if Substrate.residencyIsInCluster (Substrate.residencyOf substrate)
        then pure ()
        else
          expectFailure
            (Proxy @Topology.EksTopology)
            ( Core.RecordLit
                ( Map.fromList
                    [ ("node_group_size", Core.makeRecordField (Core.NaturalLit 1))
                    , ("eks_substrate", Core.makeRecordField (Core.denote (Dhall.embed Dhall.inject substrate)))
                    ]
                )
            )
            (Text.pack (frozenTopologyError (Topology.EksHostResidentSubstrate substrate)))
    print
      ( "narrowing_text_topology_sdk_cases" :: String
      , 4 :: Int
      , 16 :: Int
      , 1 :: Int
      , 4 :: Int
      , 2 :: Int
      , 3 :: Int
      )
  it "preserves the first typed refusal when multiple profile fields are invalid" $ do
    forM_ firstRefusals $ \(input, expected) -> do
      Aws.mkAwsSubstrateProfile input @?= Left expected
      expectFailure
        (Proxy @Aws.AwsSubstrateProfile)
        (Core.denote (Dhall.embed Dhall.inject input))
        (Text.pack (frozenAwsError expected))
    print ("narrowing_text_first_refusal_cases" :: String, length firstRefusals)
  it "renders compact diagnostic Text without retaining a sliced input backing" $ do
    let parent = Text.replicate 256 "λ😀"
        slices = [Text.take 3 (Text.drop offset parent) | offset <- [0, 1, 7, 32]]
    parentGraph <- evaluate (force parent) >>= observeGraph
    forM_ slices $ \view -> do
      let err = Aws.AwsSubstrateProfileUnsupportedVolumeType view
      rendered <- evaluate (force (Aws.renderAwsSubstrateProfileErrorText err))
      rendered @?= Text.pack (frozenAwsError err)
      actual <- observeGraph rendered
      compact <- evaluate (force (Text.copy rendered)) >>= observeGraph
      observedDataBytes actual @?= observedDataBytes compact
      assertBool
        "diagnostic retained the parent input backing"
        (observedDataBytes actual < observedDataBytes parentGraph)
    print ("narrowing_text_compact_cases" :: String, length slices)

expectFailure
  :: forall value. (Dhall.FromDhall value) => Proxy value -> Core.Expr Void Void -> Text -> IO ()
expectFailure _ expression message = do
  let decoder = Dhall.auto @value
      frozen = decoder {Dhall.extract = const (Dhall.extractError message)}
      renderFailure selected = case Dhall.toMonadic (Dhall.extract selected (Core.renote expression)) of
        Left err -> pure (show err)
        Right _ -> assertFailure "expected a typed narrowing refusal" >> fail "unreachable"
  actual <- renderFailure decoder
  expected <- renderFailure frozen
  actual @?= expected

substrates :: [Substrate.WorkerSubstrate]
substrates = [Substrate.LinuxCpu, Substrate.LinuxCuda, Substrate.AppleMetal, Substrate.CudaWindows]
texts :: [Text]
texts = ["", "field", "λ😀", "nul\0field", "  name  ", "\x2003", Text.replicate 64 "x"]
awsErrors :: [Aws.AwsSubstrateProfileError]
awsErrors =
  [ constructor value
  | constructor <-
      [ Aws.AwsSubstrateProfileFieldEmpty
      , Aws.AwsSubstrateProfileFieldZero
      , Aws.AwsSubstrateProfileMalformedCidr
      , Aws.AwsSubstrateProfileHostCidrForNetwork
      , Aws.AwsSubstrateProfileUnsupportedVolumeType
      ]
  , value <- texts
  ]
    <> [ Aws.AwsSubstrateProfileListLength field expected actual
       | field <- texts
       , expected <- [minBound, -1, 0, 2, 3, maxBound]
       , actual <- [minBound, 0, 3, maxBound]
       ]
    <> [ constructor first second
       | constructor <-
           [Aws.AwsSubstrateProfileDesiredBelowMinimum, Aws.AwsSubstrateProfileMaximumBelowDesired]
       , first <- naturals
       , second <- naturals
       ]
 where
  naturals = [0, 1, 3, 2 ^ (130 :: Int)] :: [Natural]
topologyErrors :: [Topology.TopologyError]
topologyErrors =
  [Topology.EmptyMachineId, Topology.Rke2TopologyEmpty, Topology.EksNodeGroupSizeZero]
    <> [Topology.WorkerSubstrateMismatch first second | first <- substrates, second <- substrates]
    <> map Topology.EksHostResidentSubstrate substrates
validInput :: Aws.AwsSubstrateProfileInput
validInput = syntheticAwsSubstrateProfileInput
invalidProfiles :: [(Aws.AwsSubstrateProfileInput, Aws.AwsSubstrateProfileError)]
invalidProfiles =
  [ (validInput {Aws.operator_cidr = "bad"}, Aws.AwsSubstrateProfileMalformedCidr "operator_cidr")
  ,
    ( validInput {Aws.eks_node_instance_type = " "}
    , Aws.AwsSubstrateProfileFieldEmpty "eks_node_instance_type"
    )
  ,
    ( validInput {Aws.eks_node_disk_size_gib = 0}
    , Aws.AwsSubstrateProfileFieldZero "eks_node_disk_size_gib"
    )
  , (validInput {Aws.eks_node_min_size = 0}, Aws.AwsSubstrateProfileFieldZero "eks_node_min_size")
  ,
    ( validInput {Aws.aws_test_instance_types = []}
    , Aws.AwsSubstrateProfileListLength "aws_test_instance_types" 3 0
    )
  ,
    ( validInput {Aws.aws_test_root_volume_types = ["gp3"]}
    , Aws.AwsSubstrateProfileListLength "aws_test_root_volume_types" 3 1
    )
  ,
    ( validInput {Aws.aws_test_root_volume_types = ["gp3", "λ\0", "gp3"]}
    , Aws.AwsSubstrateProfileUnsupportedVolumeType "λ\0"
    )
  ,
    ( validInput {Aws.aws_test_root_volume_sizes_gib = [31, 0, 33]}
    , Aws.AwsSubstrateProfileFieldZero "aws_test_root_volume_sizes_gib"
    )
  ,
    ( validInput {Aws.static_ebs_volume_type = "badλ\0"}
    , Aws.AwsSubstrateProfileUnsupportedVolumeType "badλ\0"
    )
  ,
    ( validInput {Aws.eks_vpc_cidr = "10.71.0.1/32"}
    , Aws.AwsSubstrateProfileHostCidrForNetwork "eks_vpc_cidr"
    )
  , (validInput {Aws.eks_subnet_cidrs = []}, Aws.AwsSubstrateProfileListLength "eks_subnet_cidrs" 2 0)
  ,
    ( validInput {Aws.aws_test_subnet_cidrs = []}
    , Aws.AwsSubstrateProfileListLength "aws_test_subnet_cidrs" 3 0
    )
  ]
firstRefusals :: [(Aws.AwsSubstrateProfileInput, Aws.AwsSubstrateProfileError)]
firstRefusals =
  [
    ( validInput {Aws.operator_cidr = "bad", Aws.eks_node_disk_size_gib = 0}
    , Aws.AwsSubstrateProfileMalformedCidr "operator_cidr"
    )
  ,
    ( validInput {Aws.eks_node_instance_type = "", Aws.eks_node_disk_size_gib = 0}
    , Aws.AwsSubstrateProfileFieldEmpty "eks_node_instance_type"
    )
  ,
    ( validInput {Aws.eks_node_disk_size_gib = 0, Aws.aws_test_instance_types = []}
    , Aws.AwsSubstrateProfileFieldZero "eks_node_disk_size_gib"
    )
  ,
    ( validInput
        { Aws.aws_test_root_volume_types = ["bad", "gp3", "gp3"]
        , Aws.static_ebs_volume_type = "bad"
        }
    , Aws.AwsSubstrateProfileUnsupportedVolumeType "bad"
    )
  ,
    ( validInput {Aws.eks_vpc_cidr = "bad", Aws.aws_test_subnet_cidrs = []}
    , Aws.AwsSubstrateProfileMalformedCidr "eks_vpc_cidr"
    )
  ]
