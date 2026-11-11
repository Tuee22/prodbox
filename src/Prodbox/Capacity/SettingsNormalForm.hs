{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeOperators #-}

-- | Conservative boxed-tree storage for the complete evaluated Settings value
-- on the pinned unprofiled 64-bit runtime. Repeated references are deliberately
-- charged repeatedly: this is not an additive census of disjoint live roots.
-- Compiler thunk environments, parser/validation/GC peaks and process RSS are
-- separate obligations. This structural term alone cannot admit a controller.
module Prodbox.Capacity.SettingsNormalForm
  ( SettingsNormalForm
  , settingsNormalForm
  , settingsRawNormalFormBytes
  , rpcSettingsEnvelopeRawNormalFormBytes
  , settingsDerivedNormalFormBytes
  , settingsNormalFormBytes
  , resourcePlanNormalFormBytes
  , deploymentContextNormalFormBytes
  , runtimeProfileNormalFormBytes
  , SettingsNormalFormBudgetError (..)
  , checkSettingsNormalForm
  ) where

import Data.Text (Text)
import Data.Text.Array qualified as TextArray
import Data.Text.Internal qualified as TextInternal
import GHC.Exts (Int (I#), sizeofByteArray#)
import GHC.Generics
import Numeric.Natural (Natural)
import Prodbox.Capacity.Allocation qualified as Allocation
import Prodbox.Capacity.BoxedNormalForm (boxedNaturalBytes)
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.MeasuredProfile qualified as Measured
import Prodbox.Capacity.Types qualified as Types
import Prodbox.Cluster.Substrate qualified as Cluster
import Prodbox.Cluster.Topology qualified as Topology
import Prodbox.Config.ComponentGraph qualified as Component
import Prodbox.Config.RetainedArtifacts qualified as Artifacts
import Prodbox.ControlPlane.RpcAdmissionBirthConfig qualified as Registration
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.AwsSubstrateProfile qualified as Aws
import Prodbox.Settings.Coordinate qualified as Coordinate
import Prodbox.Settings.SecretRef qualified as Secret
import Prodbox.Substrate qualified as Scaling
import Prodbox.Tls.CertScope qualified as Tls

data SettingsNormalForm = NormalForm !Natural !Natural
  deriving (Eq, Show)

settingsNormalForm :: Settings.ValidatedSettings -> SettingsNormalForm
settingsNormalForm value =
  NormalForm
    (normalFormBytes (Settings.validatedConfig value))
    ( recordBytes
        [ normalFormBytes (Settings.resolvedManualPvHostRoot value)
        , normalFormBytes (Settings.validatedAllocatedPlan value)
        , normalFormBytes (Settings.validatedPublicEdge value)
        , normalFormBytes (Settings.validatedCoordinates value)
        , normalFormBytes (Settings.validatedDeploymentContext value)
        , -- The raw field's pointer belongs to the outer six-field record.
          0
        ]
    )

settingsRawNormalFormBytes
  , settingsDerivedNormalFormBytes
  , settingsNormalFormBytes
    :: SettingsNormalForm -> Natural
settingsRawNormalFormBytes (NormalForm raw _) = raw
settingsDerivedNormalFormBytes (NormalForm _ derived) = derived
settingsNormalFormBytes (NormalForm raw derived) = raw + derived

data SettingsNormalFormBudgetError = SettingsNormalFormUnderfunded !Natural !Natural
  deriving (Eq, Show)

-- Passing this necessary component check grants neither a complete application
-- state budget nor memory/Authority admission. Other retained state is separate.
checkSettingsNormalForm :: Natural -> SettingsNormalForm -> Either SettingsNormalFormBudgetError ()
checkSettingsNormalForm available budget
  | available >= required = Right ()
  | otherwise = Left (SettingsNormalFormUnderfunded required available)
 where
  required = settingsNormalFormBytes budget

-- One info word and at least one payload word. Boxing every source field is
-- conservative when GHC unpacks a strict field. Newtypes have no constructor.
recordBytes :: [Natural] -> Natural
recordBytes fields = 8 * (1 + max 1 (fromIntegral (length fields))) + sum fields

class NormalForm value where
  normalFormBytes :: value -> Natural
  default normalFormBytes :: (Generic value, GenericRoot (Rep value)) => value -> Natural
  normalFormBytes = genericRootBytes . from

class GenericRoot representation where
  genericRootBytes :: representation parameter -> Natural

instance (Datatype metadata, GenericFields fields) => GenericRoot (M1 D metadata fields) where
  genericRootBytes value@(M1 fields) =
    let (slots, children) = genericFieldsBytes fields
     in if isNewtype value then children else 8 * (1 + max 1 slots) + children

class GenericFields representation where
  genericFieldsBytes :: representation parameter -> (Natural, Natural)

instance GenericFields U1 where
  genericFieldsBytes U1 = (0, 0)

instance (NormalForm value) => GenericFields (K1 index value) where
  genericFieldsBytes (K1 value) = (1, normalFormBytes value)

instance (GenericFields fields) => GenericFields (M1 metadata index fields) where
  genericFieldsBytes (M1 value) = genericFieldsBytes value

instance (GenericFields left, GenericFields right) => GenericFields (left :*: right) where
  genericFieldsBytes (left :*: right) =
    let (leftSlots, leftChildren) = genericFieldsBytes left
        (rightSlots, rightChildren) = genericFieldsBytes right
     in (leftSlots + rightSlots, leftChildren + rightChildren)

instance (GenericFields left, GenericFields right) => GenericFields (left :+: right) where
  genericFieldsBytes (L1 value) = genericFieldsBytes value
  genericFieldsBytes (R1 value) = genericFieldsBytes value

instance NormalForm Bool where
  normalFormBytes value = case value of False -> 16; True -> 16

instance NormalForm Char where
  normalFormBytes value = value `seq` 16

instance NormalForm Natural where
  normalFormBytes = boxedNaturalBytes

instance NormalForm Text where
  normalFormBytes (TextInternal.Text (TextArray.ByteArray array) _ _) =
    48 + alignBytes (fromIntegral (I# (sizeofByteArray# array)))

alignBytes :: Natural -> Natural
alignBytes bytes = 8 * ((bytes + 7) `div` 8)

instance (NormalForm value) => NormalForm [value] where
  normalFormBytes = go 16
   where
    go !total [] = total
    go !total (value : rest) = go (total + 24 + normalFormBytes value) rest

instance (NormalForm value) => NormalForm (Maybe value)

-- These explicit instances make a newly introduced unsupported field a compile
-- error. There is no permissive catch-all Generic or textual Show fallback.
instance NormalForm Settings.ConfigFile
instance NormalForm Settings.DeploymentContextInput
instance NormalForm Settings.AwsCredentialsRef
instance NormalForm Settings.Route53Section
instance NormalForm Settings.AwsSubstrateSection
instance NormalForm Settings.SesSection
instance NormalForm Settings.DomainSection
instance NormalForm Settings.MetallbBgpPeer
instance NormalForm Settings.AcmeSection
instance NormalForm Settings.PublicEdgeAdvertisementMode
instance NormalForm Settings.DeploymentSection
instance NormalForm Settings.StorageSection
instance NormalForm Settings.PulumiStateBackendSection
instance NormalForm Aws.AwsSubstrateProfile
instance NormalForm Secret.SecretRef
instance NormalForm Secret.VaultSecretRef
instance NormalForm Secret.PromptSpec
instance NormalForm Capacity.CapacitySection
instance NormalForm Capacity.CapacityBudget
instance NormalForm Capacity.ResourcePlan
instance NormalForm Capacity.WorkloadResourceProfile
instance NormalForm Capacity.WorkloadConcurrency
instance NormalForm Capacity.RuntimeMemoryProfile
instance NormalForm Capacity.ChildProcessBudgetConfig
instance NormalForm Types.ResourceVector
instance NormalForm Types.WorkloadQoS
instance NormalForm Types.WorkloadDemandSpec
instance NormalForm Types.CpuDemandSpec
instance NormalForm Types.MemoryDemandSpec
instance NormalForm Types.EphemeralDemandSpec
instance NormalForm Topology.ClusterTopology
instance NormalForm Topology.Machine
instance NormalForm Topology.MachineId
instance NormalForm Topology.ComputeWorker
instance NormalForm Topology.KindTopology
instance NormalForm Topology.Rke2Topology
instance NormalForm Topology.EksTopology
instance NormalForm Cluster.WorkerSubstrate
instance NormalForm Scaling.ScalingPolicyBySubstrate
instance NormalForm Scaling.ScalingPolicy
instance NormalForm Scaling.ElasticScalingBounds
instance NormalForm Artifacts.RetainedArtifactsSection
instance NormalForm Artifacts.RetainedArtifactDeclaration
instance NormalForm Component.ComponentNode
instance NormalForm Component.ComponentDependency
instance NormalForm Component.ComponentId
instance NormalForm Component.ReadinessProbe
instance NormalForm Component.EdgeKind
instance NormalForm Registration.RpcBirthConfig
instance NormalForm Registration.RpcBirthConfigPin
instance NormalForm Measured.MeasuredResourceProfile

instance NormalForm Allocation.SomeAllocatedPlan where
  normalFormBytes (Allocation.SomeAllocatedPlan tag plan) =
    tag `seq`
      recordBytes
        [ 16
        , recordBytes
            [ normalFormBytes (Allocation.allocatedPlanSource plan)
            , normalFormBytes (Allocation.allocatedPlanClusterBudget plan)
            , normalFormBytes (Allocation.allocatedPlanWorkloads plan)
            ]
        ]

instance NormalForm Allocation.ClusterBudget where
  normalFormBytes value =
    recordBytes
      [ normalFormBytes (Allocation.clusterBudgetAllocatable value)
      , normalFormBytes (Allocation.clusterBudgetRemaining value)
      ]

instance NormalForm Allocation.CertifiedWorkload where
  normalFormBytes value =
    recordBytes
      [ normalFormBytes (Allocation.certifiedWorkloadAllocation value)
      , normalFormBytes (Allocation.certifiedWorkloadCertification value)
      ]

instance NormalForm Allocation.WorkloadAllocation where
  normalFormBytes value =
    recordBytes
      [ normalFormBytes (Allocation.workloadAllocationProfileId value)
      , normalFormBytes (Allocation.workloadAllocationNamespace value)
      , normalFormBytes (Allocation.workloadAllocationDraw value)
      ]

instance NormalForm Allocation.WorkloadCertification where
  normalFormBytes value = case value of
    Allocation.WorkloadUncertifiedUntilFirstProfile -> recordBytes []
    Allocation.WorkloadCertified profile -> recordBytes [normalFormBytes profile]

instance NormalForm Settings.ValidatedDeploymentContext where
  normalFormBytes value =
    recordBytes
      [ normalFormBytes (Settings.deploymentClusterId value)
      , normalFormBytes (Settings.deploymentVaultAddress value)
      , normalFormBytes (Settings.deploymentMinioEndpoint value)
      , normalFormBytes (Settings.deploymentMachineIds value)
      , normalFormBytes (Settings.deploymentRpcRegistration value)
      ]

instance NormalForm Settings.ValidatedCoordinates where
  normalFormBytes value =
    recordBytes
      [ normalFormBytes (Settings.coordinateHomeZoneId value)
      , normalFormBytes (Settings.coordinateAwsSubstrateZoneId value)
      , normalFormBytes (Settings.coordinateAwsSubstrateSubzone value)
      , normalFormBytes (Settings.coordinateOperationalAwsRegion value)
      , normalFormBytes (Settings.coordinatePulumiBackendRegion value)
      , normalFormBytes (Settings.coordinatePulumiBackendBucket value)
      , normalFormBytes (Settings.coordinatePulumiBackendKeyPrefix value)
      , normalFormBytes (Settings.coordinateSesSenderDomain value)
      , normalFormBytes (Settings.coordinateSesReceiveSubdomain value)
      , normalFormBytes (Settings.coordinateSesCaptureBucket value)
      , normalFormBytes (Settings.coordinateDemoTtl value)
      , normalFormBytes (Settings.coordinateBootstrapPublicIp value)
      , normalFormBytes (Settings.coordinateManualPvHostRoot value)
      , normalFormBytes (Settings.coordinateAcmeAccount value)
      ]

instance NormalForm Settings.AcmeAccount where
  normalFormBytes value =
    recordBytes
      [ normalFormBytes (Settings.acmeAccountEmail value)
      , normalFormBytes (Settings.acmeAccountDirectoryUrl value)
      ]

instance NormalForm Settings.ValidatedPublicEdge where
  normalFormBytes value =
    recordBytes
      [ normalFormBytes (Settings.validatedHomeServedHost value)
      , normalFormBytes (Settings.validatedAwsServedHost value)
      ]

instance NormalForm Settings.ValidatedServedHost where
  normalFormBytes value =
    recordBytes
      [ normalFormBytes (Settings.servedHostFqdn value)
      , normalFormBytes (Settings.servedHostCertScopes value)
      ]

instance NormalForm Tls.CertScopeSet where
  normalFormBytes = normalFormBytes . Tls.certScopeSetScopes
instance NormalForm Tls.CertScope where
  normalFormBytes value = case value of
    Tls.ScopeExact host -> recordBytes [normalFormBytes host]
    Tls.ScopeWildcard zone -> recordBytes [normalFormBytes zone]
instance NormalForm Tls.Fqdn where
  normalFormBytes = normalFormBytes . Tls.fqdnText
instance NormalForm Tls.DelegatedZone where
  normalFormBytes = normalFormBytes . Tls.delegatedZoneText
instance NormalForm Coordinate.Route53ZoneId where
  normalFormBytes = normalFormBytes . Coordinate.route53ZoneIdText
instance NormalForm Coordinate.AwsRegion where
  normalFormBytes = normalFormBytes . Coordinate.awsRegionText
instance NormalForm Coordinate.S3BucketName where
  normalFormBytes = normalFormBytes . Coordinate.s3BucketNameText
instance NormalForm Coordinate.SafeRelativePath where
  normalFormBytes = normalFormBytes . Coordinate.safeRelativePathText
instance NormalForm Coordinate.DnsLabel where
  normalFormBytes = normalFormBytes . Coordinate.dnsLabelText
instance NormalForm Coordinate.DnsTtl where
  normalFormBytes = normalFormBytes . Coordinate.dnsTtlSeconds
instance NormalForm Coordinate.IpLiteral where
  normalFormBytes = normalFormBytes . Coordinate.ipLiteralText
instance NormalForm Coordinate.EmailAddress where
  normalFormBytes = normalFormBytes . Coordinate.emailAddressText
instance NormalForm Coordinate.AcmeDirectoryUrl where
  normalFormBytes = normalFormBytes . Coordinate.acmeDirectoryUrlText

resourcePlanNormalFormBytes :: Capacity.ResourcePlan -> Natural
resourcePlanNormalFormBytes = normalFormBytes

deploymentContextNormalFormBytes :: Settings.ValidatedDeploymentContext -> Natural
deploymentContextNormalFormBytes = normalFormBytes

runtimeProfileNormalFormBytes :: Capacity.RuntimeMemoryProfile -> Natural
runtimeProfileNormalFormBytes = normalFormBytes

-- The three fields of the private wire envelope, before semantic validation.
rpcSettingsEnvelopeRawNormalFormBytes
  :: Natural -> Settings.DeploymentContextInput -> Settings.ConfigFile -> Natural
rpcSettingsEnvelopeRawNormalFormBytes schema context parameters =
  recordBytes [normalFormBytes schema, normalFormBytes context, normalFormBytes parameters]
