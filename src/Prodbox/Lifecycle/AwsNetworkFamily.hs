{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed declarations, independent of provider responses and checkpoints.
module Prodbox.Lifecycle.AwsNetworkFamily
  ( AwsNetworkFamily (..)
  , networkFamilyName
  , networkFamilyStack
  , networkFamilyPulumiStack
  , networkFamilyCluster
  , networkFamilyVpcTags
  , pulumiEksClusterNameSuffix
  , networkFamilyPredicate
  )
where

import Codec.Serialise (Serialise)
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.Lifecycle.AwsTestCanary (canaryFamilyPredicate)

data AwsNetworkFamily
  = EksVpcCniInterfaces
  | TestVpcCniInterfaces
  | EksClusterSecurityGroups
  | TestCanarySecurityGroups
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

networkFamilyName :: AwsNetworkFamily -> Text
networkFamilyName family = case family of
  EksVpcCniInterfaces -> "aws-eks-vpc-cni-interfaces"
  TestVpcCniInterfaces -> "aws-test-vpc-cni-interfaces"
  EksClusterSecurityGroups -> "aws-eks-cluster-security-groups"
  TestCanarySecurityGroups -> "aws-test-canary-security-groups"

networkFamilyStack :: AwsNetworkFamily -> Text
networkFamilyStack family = case family of
  EksVpcCniInterfaces -> "aws-eks"
  TestVpcCniInterfaces -> "aws-test"
  EksClusterSecurityGroups -> "aws-eks"
  TestCanarySecurityGroups -> "aws-test"

networkFamilyPulumiStack :: AwsNetworkFamily -> Text
networkFamilyPulumiStack family = case family of
  EksVpcCniInterfaces -> "aws-eks-test"
  TestVpcCniInterfaces -> "aws-test"
  EksClusterSecurityGroups -> "aws-eks-test"
  TestCanarySecurityGroups -> "aws-test"

pulumiEksClusterNameSuffix :: Text
pulumiEksClusterNameSuffix = "-cluster"

networkFamilyCluster :: AwsNetworkFamily -> Maybe Text
networkFamilyCluster family = case family of
  EksVpcCniInterfaces -> Just (networkFamilyPulumiStack family <> pulumiEksClusterNameSuffix)
  TestVpcCniInterfaces -> Nothing
  EksClusterSecurityGroups -> Just (networkFamilyPulumiStack family <> pulumiEksClusterNameSuffix)
  TestCanarySecurityGroups -> Nothing

networkFamilyVpcTags :: AwsNetworkFamily -> [(Text, Text)]
networkFamilyVpcTags family =
  [("Name", networkFamilyPulumiStack family <> "-vpc"), ("prodbox.io/managed-by", "prodbox")]

-- | Version the complete rule in the coordinate digest when it changes.
networkFamilyPredicate :: AwsNetworkFamily -> Text
networkFamilyPredicate family = case family of
  EksVpcCniInterfaces -> interfaceRule
  TestVpcCniInterfaces -> interfaceRule
  EksClusterSecurityGroups -> "v1:exact-vpc:eks-cluster-sg-prefix:exact-cluster-tag:non-default"
  TestCanarySecurityGroups -> canaryFamilyPredicate
 where
  interfaceRule =
    "v1:exact-vpc:available:non-requester-managed:interface:cni-tag-or-description:no-foreign-cluster"
