{-# LANGUAGE ImportQualifiedPost #-}

-- Frozen pre-Text-renderer references for exact diagnostic compatibility.
module FrozenNarrowingErrors (frozenAwsError, frozenTopologyError) where

import Data.Text qualified as Text
import Prodbox.Cluster.Substrate (renderWorkerSubstrate)
import Prodbox.Cluster.Topology (TopologyError (..))
import Prodbox.Settings.AwsSubstrateProfile (AwsSubstrateProfileError (..))

frozenAwsError :: AwsSubstrateProfileError -> String
frozenAwsError err = case err of
  AwsSubstrateProfileFieldEmpty fieldName ->
    Text.unpack fieldName ++ " must be a non-empty AWS token"
  AwsSubstrateProfileFieldZero fieldName -> Text.unpack fieldName ++ " must be greater than zero"
  AwsSubstrateProfileListLength fieldName expected actual ->
    Text.unpack fieldName
      ++ " must contain exactly "
      ++ show expected
      ++ " values (got "
      ++ show actual
      ++ ")"
  AwsSubstrateProfileMalformedCidr fieldName -> Text.unpack fieldName ++ " is not a canonical IPv4 CIDR"
  AwsSubstrateProfileHostCidrForNetwork fieldName ->
    Text.unpack fieldName ++ " requires a network CIDR, not a /32 host CIDR"
  AwsSubstrateProfileUnsupportedVolumeType value ->
    "unsupported EBS volume type: " ++ Text.unpack value
  AwsSubstrateProfileDesiredBelowMinimum desired minimumValue ->
    "EKS desired node count " ++ show desired ++ " is below authored minimum " ++ show minimumValue
  AwsSubstrateProfileMaximumBelowDesired maximumValue desired ->
    "EKS authored maximum " ++ show maximumValue ++ " is below desired node count " ++ show desired

frozenTopologyError :: TopologyError -> String
frozenTopologyError err =
  case err of
    EmptyMachineId ->
      "cluster_topology machine_id must be non-empty"
    WorkerSubstrateMismatch machineSubstrate workerSubstrate ->
      "cluster_topology worker substrate "
        ++ renderWorkerSubstrate workerSubstrate
        ++ " does not match machine substrate "
        ++ renderWorkerSubstrate machineSubstrate
    Rke2TopologyEmpty ->
      "cluster_topology rke2 topology must include at least one machine"
    EksHostResidentSubstrate substrate ->
      "cluster_topology eks substrate must be in-cluster, not "
        ++ renderWorkerSubstrate substrate
    EksNodeGroupSizeZero ->
      "cluster_topology eks node_group_size must be greater than zero"
