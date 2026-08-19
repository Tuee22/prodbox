{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure names and indices shared by the exact-keyed lifecycle registry and
-- its observation algebra.  The local Linux RKE2 foundation is the only
-- lifecycle authority; AWS and EKS are managed systems that authority may
-- observe and orchestrate, not peer substrates.
module Prodbox.Lifecycle.Teardown.Model
  ( LifecycleClass (..)
  , ResourceKind (..)
  , ResourceKindWitness (..)
  , resourceKindFromWitness
  , CleanupSurface (..)
  , CleanupSurfaceWitness (..)
  , cleanupSurfaceFromWitness
  , cleanupSurfaceMintsCompletionEvidence
  , RegisteredResourceKey (..)
  , registeredResourceKeyText
  , registeredResourceKeyFromText
  , LifecycleAuthority (..)
  , ObservationAuthority (..)
  , ManagedResourceCoordinate (..)
  , coordinateIsAws
  , clusterOwnershipTagPrefix
  , clusterOwnedTagValue
  , pulumiEksClusterNameSuffix
  , coordinateControllerOwnerCluster
  , coordinateProvisionedClusterName
  , ManagedResourceCoordinateDigest
  , managedResourceCoordinateDigest
  , managedResourceCoordinateDigestText
  , RegistryRevision (..)
  , DurableObservationRunScope (..)
  , LinuxRke2FoundationId (..)
  , AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , LifecycleOperation (..)
  , ObservationEvidenceScope
  , mkObservationEvidenceScope
  , evidenceCleanupSurface
  , evidenceRegistryRevision
  , evidenceDurableRunScope
  , evidenceLinuxRke2Foundation
  , evidenceAwsScope
  , evidenceLifecycleOperation
  , ObservationRevision (..)
  , ObservationFailure (..)
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word64)
import Numeric (showHex)
import Prodbox.Lifecycle.ResourceClass (LifecycleClass (..))

-- | The closed physical shape of a registered identity.  A local substrate is
-- intentionally a distinct kind: it never enters a generic managed-resource
-- destroyer.
data ResourceKind
  = Stack
  | ControllerFamily
  | Singleton
  | Topic
  | Credential
  | VolumeFamily
  | LocalSubstrate
  deriving (Bounded, Enum, Eq, Ord, Show)

data ResourceKindWitness (kind :: ResourceKind) where
  StackKind :: ResourceKindWitness 'Stack
  ControllerFamilyKind :: ResourceKindWitness 'ControllerFamily
  SingletonKind :: ResourceKindWitness 'Singleton
  TopicKind :: ResourceKindWitness 'Topic
  CredentialKind :: ResourceKindWitness 'Credential
  VolumeFamilyKind :: ResourceKindWitness 'VolumeFamily
  LocalSubstrateKind :: ResourceKindWitness 'LocalSubstrate

resourceKindFromWitness :: ResourceKindWitness kind -> ResourceKind
resourceKindFromWitness witness = case witness of
  StackKind -> Stack
  ControllerFamilyKind -> ControllerFamily
  SingletonKind -> Singleton
  TopicKind -> Topic
  CredentialKind -> Credential
  VolumeFamilyKind -> VolumeFamily
  LocalSubstrateKind -> LocalSubstrate

-- | Authority surfaces stay distinct even when they select some of the same
-- descriptors.  In particular, an explicit per-run operation is not a
-- cascade and an explicit long-lived operation cannot become one.
data CleanupSurface
  = LocalOnly
  | Cascade
  | ExplicitPerRun
  | OperationalTeardown
  | ExplicitLongLived
  | TotalDecommission
  deriving (Bounded, Enum, Eq, Ord, Show)

data CleanupSurfaceWitness (surface :: CleanupSurface) where
  LocalOnlySurface :: CleanupSurfaceWitness 'LocalOnly
  CascadeSurface :: CleanupSurfaceWitness 'Cascade
  ExplicitPerRunSurface :: CleanupSurfaceWitness 'ExplicitPerRun
  OperationalTeardownSurface :: CleanupSurfaceWitness 'OperationalTeardown
  ExplicitLongLivedSurface :: CleanupSurfaceWitness 'ExplicitLongLived
  TotalDecommissionSurface :: CleanupSurfaceWitness 'TotalDecommission

cleanupSurfaceFromWitness :: CleanupSurfaceWitness surface -> CleanupSurface
cleanupSurfaceFromWitness witness = case witness of
  LocalOnlySurface -> LocalOnly
  CascadeSurface -> Cascade
  ExplicitPerRunSurface -> ExplicitPerRun
  OperationalTeardownSurface -> OperationalTeardown
  ExplicitLongLivedSurface -> ExplicitLongLived
  TotalDecommissionSurface -> TotalDecommission

-- | Whether a run on this surface can mint completion evidence today.
--
-- This lives beside 'CleanupSurface' rather than beside the minters because it
-- has to be readable from a leaf module — 'Prodbox.CheckCode' joins it to the
-- registry to decide whether a registered target with no production executor
-- is admissible. @Prodbox.Lifecycle.Teardown.Report@ owns the minters
-- themselves, and its fixed regression exercises each surface marked 'True'
-- here, so a surface claimed complete-able but unable to mint is a failing
-- case rather than a silent disagreement.
--
-- The distinction is load-bearing rather than descriptive. A compiled program
-- ends in mandatory read-backs, and a surface that mints completion is
-- asserting every one of them succeeded. Registering a target whose read-back
-- no production interpreter can execute therefore makes that surface's
-- completion unreachable — while a surface with no minter makes no claim at
-- all, so the same gap is merely unfinished work there.
cleanupSurfaceMintsCompletionEvidence :: CleanupSurface -> Bool
cleanupSurfaceMintsCompletionEvidence surface = case surface of
  LocalOnly -> False
  Cascade -> True
  ExplicitPerRun -> True
  -- Sprint 4.85 (2026-08-18): the operational surface mints completion. Its
  -- obligation is no longer empty -- the credential revocation and that
  -- revocation's mandatory read-back are its own rather than a registered
  -- target's -- which is what a completion claim over zero registered targets
  -- previously lacked.
  OperationalTeardown -> True
  ExplicitLongLived -> False
  TotalDecommission -> False

-- | Closed initial keys.  The two EBS families are different identities; no
-- catch-all key exists whose provider tags could later choose a lifecycle
-- class.
data RegisteredResourceKey
  = LocalLinuxRke2Key
  | AwsEksKey
  | AwsEksSubzoneKey
  | AwsTestKey
  | AwsEbsPerRunTestKey
  | AwsEbsProductionRetainedKey
  deriving (Bounded, Enum, Eq, Ord, Show)

registeredResourceKeyText :: RegisteredResourceKey -> Text
registeredResourceKeyText key = case key of
  LocalLinuxRke2Key -> "local-linux-rke2"
  AwsEksKey -> "aws-eks"
  AwsEksSubzoneKey -> "aws-eks-subzone"
  AwsTestKey -> "aws-test"
  AwsEbsPerRunTestKey -> "aws-ebs-volumes-per-run-test"
  AwsEbsProductionRetainedKey -> "aws-ebs-volumes-production-retained"

-- | The inverse of 'registeredResourceKeyText', over the closed enumeration.
--
-- Total in the refusing direction: a name this binary does not register has no
-- key, and a caller naming one is refused rather than matched approximately.
-- Derived from the enumeration itself, so the two directions cannot disagree.
registeredResourceKeyFromText :: Text -> Maybe RegisteredResourceKey
registeredResourceKeyFromText name =
  lookup name [(registeredResourceKeyText key, key) | key <- [minBound .. maxBound]]

-- | The sole lifecycle authority in this architecture.  Remote AWS and EKS
-- resources remain below this local authority.
data LifecycleAuthority = LinuxRke2LifecycleAuthority
  deriving (Eq, Ord, Show)

-- | The external system that supplied one exact observation.  This is not a
-- lifecycle authority and cannot select a cleanup surface.
data ObservationAuthority
  = LocalRke2SystemAuthority
  | AwsResourceApiAuthority
  deriving (Eq, Ord, Show)

-- | Exact static coordinates.  Account and region are deliberately carried by
-- the durable observation scope instead of baked into this repository-owned
-- inventory.
data ManagedResourceCoordinate
  = LocalRke2Coordinate
      { localRke2CoordinateName :: !Text
      }
  | AwsPulumiStackCoordinate
      { awsPulumiProjectName :: !Text
      , awsPulumiStackName :: !Text
      }
  | AwsEbsPerRunFamilyCoordinate
      { awsEbsOwnershipTagKey :: !Text
      , awsEbsOwnershipTagValue :: !Text
      , awsEbsClusterOwnershipTagKey :: !Text
      , awsEbsClusterOwnershipTagValue :: !Text
      }
  | AwsEbsRetainedFamilyCoordinate
      { awsEbsOwnershipTagKey :: !Text
      , awsEbsOwnershipTagValue :: !Text
      }
  deriving (Eq, Ord, Show)

coordinateIsAws :: ManagedResourceCoordinate -> Bool
coordinateIsAws coordinate = case coordinate of
  LocalRke2Coordinate {} -> False
  AwsPulumiStackCoordinate {} -> True
  AwsEbsPerRunFamilyCoordinate {} -> True
  AwsEbsRetainedFamilyCoordinate {} -> True

-- | The AWS convention for "a Kubernetes cluster owns or shares this
-- resource": @kubernetes.io\/cluster\/\<cluster-name\>@.  The cluster name is
-- part of the key, which is why key equality is the wrong relation for this
-- family and prefix membership is the right one.
clusterOwnershipTagPrefix :: Text
clusterOwnershipTagPrefix = "kubernetes.io/cluster/"

-- | The ownership tag value that makes the named cluster the __owner__.  The
-- other legal value, @shared@, does not: a shared resource outlives the
-- cluster by design, so it has no controller owner to order a teardown
-- against.
clusterOwnedTagValue :: Text
clusterOwnedTagValue = "owned"

-- | How the EKS provisioning program names the cluster it declares.
--
-- @pulumi\/aws-eks\/Main.yaml@ sets @clusterName: ${stackName}-cluster@, so a
-- registered stack's Pulumi stack name determines the cluster name any
-- controller-owned family will carry.  This constant is the one place that
-- external fact is written down; deriving the ownership relation from it is
-- what keeps a controller-owned family's owning stack from being an
-- independently authored third statement.
pulumiEksClusterNameSuffix :: Text
pulumiEksClusterNameSuffix = "-cluster"

-- | The Kubernetes cluster whose controllers own this resource family, if any.
--
-- Total over the coordinate universe, so a new coordinate shape is an
-- exhaustiveness failure until someone states whether it has a controller
-- owner.  A @shared@ ownership value deliberately answers 'Nothing': the tag
-- names a cluster that uses the resource, not one that owns its lifetime.
coordinateControllerOwnerCluster :: ManagedResourceCoordinate -> Maybe Text
coordinateControllerOwnerCluster coordinate = case coordinate of
  LocalRke2Coordinate {} -> Nothing
  AwsPulumiStackCoordinate {} -> Nothing
  AwsEbsPerRunFamilyCoordinate _ _ clusterTagKey clusterTagValue
    | clusterTagValue == clusterOwnedTagValue ->
        Text.stripPrefix clusterOwnershipTagPrefix clusterTagKey
    | otherwise -> Nothing
  -- The retained family is keyed only by its retention marker and carries no
  -- cluster ownership tag, which is exactly what lets it outlive any cluster.
  AwsEbsRetainedFamilyCoordinate {} -> Nothing

-- | The cluster name a registered stack's provisioning program would give an
-- EKS cluster, if that program declares one.
--
-- This is a __candidate__ rather than a claim: a stack that declares no
-- cluster simply matches no controller-owned family, so the join stays sound
-- without this function having to know which programs declare clusters.
coordinateProvisionedClusterName :: ManagedResourceCoordinate -> Maybe Text
coordinateProvisionedClusterName coordinate = case coordinate of
  LocalRke2Coordinate {} -> Nothing
  AwsPulumiStackCoordinate _ stackName ->
    Just (stackName <> pulumiEksClusterNameSuffix)
  AwsEbsPerRunFamilyCoordinate {} -> Nothing
  AwsEbsRetainedFamilyCoordinate {} -> Nothing

newtype ManagedResourceCoordinateDigest
  = ManagedResourceCoordinateDigest Text
  deriving (Eq, Ord, Show)

-- | Hash the canonical, constructor-tagged coordinate.  The digest is derived
-- only from static registry data; provider rows cannot influence it.
managedResourceCoordinateDigest
  :: ManagedResourceCoordinate -> ManagedResourceCoordinateDigest
managedResourceCoordinateDigest coordinate =
  ManagedResourceCoordinateDigest
    ( Text.pack
        ( concatMap
            renderHexByte
            (ByteString.unpack (SHA256.hash (TextEncoding.encodeUtf8 canonical)))
        )
    )
 where
  canonical = case coordinate of
    LocalRke2Coordinate name -> Text.intercalate "\NUL" ["local-rke2/v1", name]
    AwsPulumiStackCoordinate projectName stackName ->
      Text.intercalate "\NUL" ["aws-pulumi-stack/v1", projectName, stackName]
    AwsEbsPerRunFamilyCoordinate tagKey tagValue clusterTagKey clusterTagValue ->
      Text.intercalate
        "\NUL"
        [ "aws-ebs-per-run-family/v1"
        , tagKey
        , tagValue
        , clusterTagKey
        , clusterTagValue
        ]
    AwsEbsRetainedFamilyCoordinate tagKey tagValue ->
      Text.intercalate "\NUL" ["aws-ebs-retained-family/v1", tagKey, tagValue]

  renderHexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

managedResourceCoordinateDigestText :: ManagedResourceCoordinateDigest -> Text
managedResourceCoordinateDigestText (ManagedResourceCoordinateDigest digest) = digest

newtype RegistryRevision = RegistryRevision Text
  deriving (Eq, Ord, Show)

newtype DurableObservationRunScope = DurableObservationRunScope Text
  deriving (Eq, Ord, Show)

-- | Identifies the retained local Linux RKE2 foundation that owns a run.  A
-- second value can be represented for mismatch detection, but there is no AWS
-- lifecycle-authority constructor.
newtype LinuxRke2FoundationId = LinuxRke2FoundationId Text
  deriving (Eq, Ord, Show)

newtype AwsAccountId = AwsAccountId Text
  deriving (Eq, Ord, Show)

newtype AwsRegion = AwsRegion Text
  deriving (Eq, Ord, Show)

data AwsScope = AwsScope
  { awsScopeAccountId :: !AwsAccountId
  , awsScopeRegion :: !AwsRegion
  }
  deriving (Eq, Ord, Show)

data LifecycleOperation
  = ReconcileDesiredAbsent
  | ReconcileDesiredPresent
  | RunTerminalEscapeAudit
  deriving (Eq, Ord, Show)

-- | Opaque durable-run binding shared by observation requests and responses.
-- The value always names the local orchestrating foundation; an optional AWS
-- target scope describes remote resources that foundation manages.
data ObservationEvidenceScope = ObservationEvidenceScope
  { internalEvidenceCleanupSurface :: !CleanupSurface
  , internalEvidenceRegistryRevision :: !RegistryRevision
  , internalEvidenceDurableRunScope :: !DurableObservationRunScope
  , internalEvidenceLinuxRke2Foundation :: !LinuxRke2FoundationId
  , internalEvidenceAwsScope :: !(Maybe AwsScope)
  , internalEvidenceLifecycleOperation :: !LifecycleOperation
  }
  deriving (Eq, Ord, Show)

mkObservationEvidenceScope
  :: CleanupSurface
  -> RegistryRevision
  -> DurableObservationRunScope
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> LifecycleOperation
  -> ObservationEvidenceScope
mkObservationEvidenceScope surface revision runScope foundation awsScope operation =
  ObservationEvidenceScope
    { internalEvidenceCleanupSurface = surface
    , internalEvidenceRegistryRevision = revision
    , internalEvidenceDurableRunScope = runScope
    , internalEvidenceLinuxRke2Foundation = foundation
    , internalEvidenceAwsScope = awsScope
    , internalEvidenceLifecycleOperation = operation
    }

evidenceCleanupSurface :: ObservationEvidenceScope -> CleanupSurface
evidenceCleanupSurface = internalEvidenceCleanupSurface

evidenceRegistryRevision :: ObservationEvidenceScope -> RegistryRevision
evidenceRegistryRevision = internalEvidenceRegistryRevision

evidenceDurableRunScope :: ObservationEvidenceScope -> DurableObservationRunScope
evidenceDurableRunScope = internalEvidenceDurableRunScope

evidenceLinuxRke2Foundation :: ObservationEvidenceScope -> LinuxRke2FoundationId
evidenceLinuxRke2Foundation = internalEvidenceLinuxRke2Foundation

evidenceAwsScope :: ObservationEvidenceScope -> Maybe AwsScope
evidenceAwsScope = internalEvidenceAwsScope

evidenceLifecycleOperation :: ObservationEvidenceScope -> LifecycleOperation
evidenceLifecycleOperation = internalEvidenceLifecycleOperation

newtype ObservationRevision = ObservationRevision Word64
  deriving (Eq, Ord, Show)

newtype ObservationFailure = ObservationFailure Text
  deriving (Eq, Ord, Show)
