-- | Closed caller workloads for the standalone AWS lifecycle clients.
-- Production replay sizing depends on this capacity-owned projection, never
-- on a validation harness implementation.
module Prodbox.Capacity.AwsLifecycleBudget
  ( AwsLifecycleWorkload (..)
  , awsLifecycleProviderBodyRequestMaximum
  , awsLifecycleRecordedOutputReadMaximum
  ) where

import Numeric.Natural (Natural)

data AwsLifecycleWorkload = AwsStackCycleWorkload | AwsTestVpcCanaryWorkload
  deriving (Eq, Show, Enum, Bounded)

awsLifecycleProviderBodyRequestMaximum :: AwsLifecycleWorkload -> Natural
awsLifecycleProviderBodyRequestMaximum workload =
  workloadStackCount workload * (3 + 3 + 3) + canaryPlantCount workload

awsLifecycleRecordedOutputReadMaximum :: AwsLifecycleWorkload -> Natural
awsLifecycleRecordedOutputReadMaximum workload =
  workloadStackCount workload + canaryPlantCount workload

workloadStackCount :: AwsLifecycleWorkload -> Natural
workloadStackCount workload = case workload of
  AwsStackCycleWorkload -> 2
  AwsTestVpcCanaryWorkload -> 1

canaryPlantCount :: AwsLifecycleWorkload -> Natural
canaryPlantCount workload = case workload of
  AwsStackCycleWorkload -> 0
  AwsTestVpcCanaryWorkload -> 1
