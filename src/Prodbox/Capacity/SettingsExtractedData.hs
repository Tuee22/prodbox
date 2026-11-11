{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- | Returned raw settings and selected extraction data: sequence/product/sum/unit
-- spines and guarded AWS case-converter arrays. No complete extraction,
-- narrowing DTO/result/control/GC/native or admission proof.
module Prodbox.Capacity.SettingsExtractedData
  ( RawData
  , settingsExtractedDataBytes
  , settingsExtractedMaximumConstructorFields
  , settingsExtractedMaximumSumDepth
  , settingsExtractionSequenceDataBytes
  , settingsExtractionGenericProductDataBytes
  , settingsExtractionGenericSumDataBytes
  , settingsExtractionAwsCaseArrayDataBytes
  , settingsExtractionTypeTreeDataBytes
  , settingsExtractionTypeMapDataBytes
  ) where

import Data.Kind (Type)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import GHC.Generics
import Numeric.Natural (Natural)
import Prodbox.Capacity.CanonicalDhallNormalForm
  ( canonicalDhallNormalFormBytes
  , canonicalDhallTypeNormalForm
  )
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.Types qualified as Types
import Prodbox.Cluster.Substrate qualified as Cluster
import Prodbox.Cluster.Topology qualified as Topology
import Prodbox.Config.CanonicalDhallValueShape
import Prodbox.Config.ComponentGraph qualified as Component
import Prodbox.Config.RetainedArtifacts qualified as Artifacts
import Prodbox.ControlPlane.RpcAdmissionBirthConfig qualified as Registration
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.AwsSubstrateProfile qualified as Aws
import Prodbox.Settings.SecretRef qualified as Secret
import Prodbox.Substrate qualified as Scaling

-- Every raw field has an explicit instance. There is no Char/String or generic
-- fallback: an unsupported new leaf fails this closed field traversal. This
-- structural contract is not a claim about arbitrary custom FromDhall code.
class RawData value where
  maximumFields :: Proxy value -> Natural
  default maximumFields :: (Generic value, RawFields (Rep value)) => Proxy value -> Natural
  maximumFields = genericMaximumFields
  maximumSumDepth :: Proxy value -> Natural
  default maximumSumDepth :: (Generic value, RawFields (Rep value)) => Proxy value -> Natural
  maximumSumDepth = genericMaximumSumDepth

genericMaximumFields
  :: forall value. (Generic value, RawFields (Rep value)) => Proxy value -> Natural
genericMaximumFields _ = let (fields, child) = rawFields (Proxy @(Rep value)) in max fields child

genericMaximumSumDepth
  :: forall value. (Generic value, RawFields (Rep value)) => Proxy value -> Natural
genericMaximumSumDepth _ = rawSumDepth (Proxy @(Rep value))

class RawFields (representation :: Type -> Type) where
  rawFields :: Proxy representation -> (Natural, Natural)
  rawSumDepth :: Proxy representation -> Natural

instance RawFields U1 where
  rawFields _ = (0, 0)
  rawSumDepth _ = 0
instance (RawData value) => RawFields (K1 index value) where
  rawFields _ = (1, maximumFields (Proxy @value))
  rawSumDepth _ = maximumSumDepth (Proxy @value)
instance (RawFields fields) => RawFields (M1 metadata index fields) where
  rawFields _ = rawFields (Proxy @fields)
  rawSumDepth _ = rawSumDepth (Proxy @fields)
instance (RawFields left, RawFields right) => RawFields (left :*: right) where
  rawFields _ =
    let (leftFields, leftChild) = rawFields (Proxy @left)
        (rightFields, rightChild) = rawFields (Proxy @right)
     in (leftFields + rightFields, max leftChild rightChild)
  rawSumDepth _ = max (rawSumDepth (Proxy @left)) (rawSumDepth (Proxy @right))
instance (RawFields left, RawFields right) => RawFields (left :+: right) where
  rawFields _ =
    let (leftFields, leftChild) = rawFields (Proxy @left)
        (rightFields, rightChild) = rawFields (Proxy @right)
     in (max leftFields rightFields, max leftChild rightChild)
  rawSumDepth _ = 1 + max (rawSumDepth (Proxy @left)) (rawSumDepth (Proxy @right))

instance RawData Bool where
  maximumFields _ = 0
  maximumSumDepth _ = 0
instance RawData Natural where
  maximumFields _ = 0
  maximumSumDepth _ = 0
instance RawData Text where
  maximumFields _ = 0
  maximumSumDepth _ = 0
instance (RawData value) => RawData [value] where
  maximumFields _ = max 2 (maximumFields (Proxy @value))
  maximumSumDepth _ = maximumSumDepth (Proxy @value)
instance (RawData value) => RawData (Maybe value) where
  maximumFields _ = max 1 (maximumFields (Proxy @value))
  maximumSumDepth _ = maximumSumDepth (Proxy @value)

settingsExtractedMaximumConstructorFields :: (RawData value) => Proxy value -> Natural
settingsExtractedMaximumConstructorFields = maximumFields

settingsExtractedMaximumSumDepth :: (RawData value) => Proxy value -> Natural
settingsExtractedMaximumSumDepth = maximumSumDepth

-- Record constructors use the largest arity in the actual closed raw types;
-- enums/Maybe/Bool need two words. Each Haskell list element adds three words
-- and each list root includes its shared Nil. Text/Natural headers use 48/32
-- bytes and at most seven padding bytes per payload. Original token spans
-- conservatively cover payloads, including accepted narrowed Text views.
-- The pinned text case converter shrinks successful normalized arrays to their
-- output length; accepted AWS token outputs are ASCII and do not grow their
-- original UTF8 span. Other selected raw decoders preserve Text/Natural values.
-- The outer extracted operand and small byte-count metadata add forty bytes.
-- These are normal-form data terms; lazy extraction/construction and failure
-- temporaries, narrowing DTOs, validation/readback and GC remain separate.
settingsExtractedDataBytes :: (RawData value) => Proxy value -> CanonicalDhallValueUsage -> Natural
settingsExtractedDataBytes shape usage =
  40
    + 8 * (1 + max 1 (maximumFields shape)) * canonicalDhallRecordValues usage
    + 16
      * ( canonicalDhallBooleanValues usage
            + canonicalDhallOptionalValues usage
            + canonicalDhallUnionValues usage
            + canonicalDhallListValues usage
        )
    + 24 * canonicalDhallListElements usage
    + 55 * canonicalDhallTextValues usage
    + canonicalDhallTextTokenBytes usage
    + 39 * canonicalDhallIntegerTokens usage
    + canonicalDhallIntegerTokenBytes usage

-- Dhall-1.42.3 implements list as fmap toList . sequence; sequence traverses
-- the input Seq with the element extractor. Its returned finger tree is live
-- before conversion to the raw Haskell list. Payloads belong to the separately
-- charged raw-data term, and Seq/Elem are newtypes on containers-0.6.8.
-- A node/digit/deep has at most five words. A Deep's two digits and header
-- use at most fifteen words plus at most five words for each of m middle
-- nodes and F(m) for their tree. Since n >= 2 + 2*m, induction gives
-- F(n) <= 16*(n+1) words, including Empty/Single. Charge all checked value-list
-- roots and elements, including nested lists whose stages can be serial.
-- This is evaluated intermediate data only: traverse construction, Generic
-- product/sum construction/results, narrowing/failure temporaries, compiler/control/GC/native
-- costs and complete admission retain separate obligations.
settingsExtractionSequenceDataBytes :: CanonicalDhallValueUsage -> Natural
settingsExtractionSequenceDataBytes usage =
  128 * (canonicalDhallListElements usage + canonicalDhallListValues usage)

-- A constructor with at most n fields has at most n-1 Generic product nodes.
-- The pinned (:*:) has a header and two pointers (24 bytes); M1/K1 are newtypes.
-- Charge every record and selected union constructor, conservatively together,
-- beside complete raw data. Results/dictionaries, construction/control/GC
-- and custom narrowing/evaluation remain separate from these product spines.
settingsExtractionGenericProductDataBytes
  :: (RawData value) => Proxy value -> CanonicalDhallValueUsage -> Natural
settingsExtractionGenericProductDataBytes shape usage =
  24
    * (max 1 (maximumFields shape) - 1)
    * (canonicalDhallRecordValues usage + canonicalDhallUnionValues usage)

-- Dhall-1.42.3 maps L1/R1 over each selected Generic union branch. Each
-- wrapper has a header and one pointer (16 bytes). The closed traversal adds
-- one at each (:+:) and carries child maxima through products/containers.
-- A child's depth can also be included under a parent sum, conservatively
-- overbounding each local spine. Charge every selected value union, including
-- nested values; type-only alternatives construct no extracted spine.
-- Also reserve one two-word U1 per record/selected union for nullary Generic
-- constructors. This conservatively includes non-nullary constructors too.
-- M1/K1 are newtypes. Result/dictionary data, union-schema evaluation and
-- construction/control/GC/native costs retain separate obligations.
settingsExtractionGenericSumDataBytes
  :: (RawData value) => Proxy value -> CanonicalDhallValueUsage -> Natural
settingsExtractionGenericSumDataBytes shape usage =
  16
    * ( maximumSumDepth shape * canonicalDhallUnionValues usage
          + canonicalDhallRecordValues usage
          + canonicalDhallUnionValues usage
      )

-- The selected SDK's closed-type comparison can hold an expected syntax
-- tree, both denoted operands and both evaluated Val trees. Charge all five
-- beside input syntax. Expected keys have compact origins; this contract is
-- checked over the actual complete expected/declared settings schemas.
-- On this closed grammar, Val retains at most the corresponding Expr/map/
-- Maybe structure: record fields and original-key spines can only disappear.
-- Each encoded type occurrence is charged separately, including type-only
-- optional/list occurrences whose extractor may not need a comparison.
-- This is evaluated tree data only. Key packing/copying, dictionary/result,
-- deletion/comparison temporaries and compiler/update/control/GC/native costs
-- remain separate; it is not a complete extraction or admission bound.
settingsExtractionTypeTreeDataBytes :: CanonicalDhallValueUsage -> Natural
-- SDK metadata can be CAF-retained: keep this full term through subsequent
-- captured-input stages rather than assuming it has been collected.
settingsExtractionTypeTreeDataBytes usage
  | canonicalDhallTypeVisits usage == 0 = 0
  | otherwise = 5 * canonicalDhallNormalFormBytes (canonicalDhallTypeNormalForm usage)

-- Dhall-1.42.3 deletes the selected key from both supplied and expected union
-- maps. Each deletion copies at most n original-key cons cells, a Map/Original
-- pair and Nil (24*n+56 bytes). containers-0.6.8 visits at most h(n) ancestors
-- across search and glue's extremal descent. Each ancestor allocates at most
-- three six-word Bin nodes and one four-word MinView/MaxView (176*h(n) bytes).
-- Charge all such construction data, without relying on collection between
-- selected unions. Existing checked type maps include every compared subtree.
-- eqMapsBy constructs two ascending lists, each with a three-word cons/pair
-- per entry; two Nils per type visit cover empty maps conservatively. Keys and
-- values alias the separately reserved trees. Potential CAF retention keeps
-- this term beside both later input branches. Dictionary/results, compiler
-- closures, comparison/control/stack/GC/native costs remain separate.
settingsExtractionTypeMapDataBytes :: CanonicalDhallValueUsage -> Natural
settingsExtractionTypeMapDataBytes usage =
  2
    * ( 56 * canonicalDhallUnionValues usage
          + 24 * canonicalDhallSelectedUnionEntries usage
          + 176 * canonicalDhallSelectedUnionHeightSum usage
      )
    + 32 * canonicalDhallTypeVisits usage
    + 96 * (canonicalDhallTypeRecordFields usage + canonicalDhallTypeUnionAlternatives usage)

-- text-2.0.2 starts at l+12 bytes and grows at most once per input character.
-- With n guarded characters, l<=4*n, output<=12*n and every request<=16*n+24.
-- Charge all n+1 prospective arrays, including their headers/alignment, rather
-- than assuming collection between resizes. Calls/limits share the validator's
-- sources. Only marked present profiles execute this narrowing. Text/MArray
-- wrappers, DTO/parser/result data and compiler/control/GC/native costs remain
-- independent; this is neither the whole workspace nor an admission proof.
settingsExtractionAwsCaseArrayDataBytes :: CanonicalDhallValueUsage -> Natural
settingsExtractionAwsCaseArrayDataBytes usage =
  canonicalDhallAwsProfileValues usage
    * ( Aws.awsProfileGeneralCaseMaximumCalls
          * arrays (fromIntegral Aws.awsProfileGeneralCaseMaximumCharacters)
          + Aws.awsProfileVolumeCaseMaximumCalls
            * arrays (fromIntegral Aws.awsProfileVolumeCaseMaximumCharacters)
      )
 where
  arrays n = (n + 1) * (16 * n + 48)

instance RawData Settings.ConfigFile
instance RawData Settings.AwsCredentialsRef
instance RawData Settings.Route53Section
instance RawData Settings.AwsSubstrateSection
instance RawData Settings.SesSection
instance RawData Settings.DomainSection
instance RawData Settings.MetallbBgpPeer
instance RawData Settings.AcmeSection
instance RawData Settings.PublicEdgeAdvertisementMode
instance RawData Settings.DeploymentSection
instance RawData Settings.StorageSection
instance RawData Settings.PulumiStateBackendSection
instance RawData Settings.DeploymentContextInput
instance RawData Aws.AwsSubstrateProfileInput
instance RawData Aws.AwsSubstrateProfile where
  maximumFields shape = max (genericMaximumFields shape) (maximumFields (Proxy @Aws.AwsSubstrateProfileInput))
  maximumSumDepth shape = max (genericMaximumSumDepth shape) (maximumSumDepth (Proxy @Aws.AwsSubstrateProfileInput))
instance RawData Secret.SecretRef
instance RawData Secret.VaultSecretRef
instance RawData Secret.PromptSpec
instance RawData Capacity.CapacitySection
instance RawData Capacity.CapacityBudget
instance RawData Capacity.ResourcePlan
instance RawData Capacity.WorkloadResourceProfile
instance RawData Capacity.WorkloadConcurrency
instance RawData Capacity.RuntimeMemoryProfile
instance RawData Capacity.ChildProcessBudgetConfig
instance RawData Types.ResourceVector
instance RawData Types.WorkloadQoS
instance RawData Types.WorkloadDemandSpec
instance RawData Types.CpuDemandSpec
instance RawData Types.MemoryDemandSpec
instance RawData Types.EphemeralDemandSpec
instance RawData Topology.ClusterTopology
instance RawData Topology.Machine
instance RawData Topology.MachineId
instance RawData Topology.ComputeWorker
instance RawData Topology.KindTopology
instance RawData Topology.Rke2Topology
instance RawData Topology.EksTopology
instance RawData Cluster.WorkerSubstrate
instance RawData Scaling.ScalingPolicyBySubstrate
instance RawData Scaling.ScalingPolicy
instance RawData Scaling.ElasticScalingBounds
instance RawData Artifacts.RetainedArtifactsSection
instance RawData Artifacts.RetainedArtifactDeclaration
instance RawData Component.ComponentNode
instance RawData Component.ComponentDependency
instance RawData Component.ComponentId
instance RawData Component.ReadinessProbe
instance RawData Component.EdgeKind
instance RawData Registration.RpcBirthConfig
instance RawData Registration.RpcBirthConfigPin
