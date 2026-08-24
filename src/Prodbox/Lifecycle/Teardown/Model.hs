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
  , SomeCleanupSurfaceWitness (..)
  , cleanupSurfaceWitnessFor
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
  , evidenceAwsDnsZone
  , mkObservationEvidenceScopeWithDnsZone
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
import Prodbox.Lifecycle.DnsRecord (HostedZoneId)
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
  | -- | Sprint 7.36: a bounded family of Route 53 hosted zones this repository
    -- creates and owns, identified by its owned tags rather than by a
    -- deterministic name — the @dns-aws@ validation zone carries a per-run
    -- nonce, so no exact name is knowable before it exists.
    DnsZoneFamily
  | -- | Sprint 7.36: a bounded family of Route 53 resource __record sets__
    -- inside one retained hosted zone, identified by a record-name prefix.
    --
    -- Distinct from 'DnsZoneFamily' because the two are removed by different
    -- authorities: a zone this repository created is deleted through the
    -- Provider, while a DNS01 challenge record is written by cert-manager's
    -- solver and is removed by deleting the Kubernetes object that owns it.  A
    -- Provider delete would race the solver into rewriting the record, so
    -- collapsing the two kinds would let one execution arm stand in for the
    -- other.
    DnsRecordFamily
  | LocalSubstrate
  deriving (Bounded, Enum, Eq, Ord, Show)

data ResourceKindWitness (kind :: ResourceKind) where
  StackKind :: ResourceKindWitness 'Stack
  ControllerFamilyKind :: ResourceKindWitness 'ControllerFamily
  SingletonKind :: ResourceKindWitness 'Singleton
  TopicKind :: ResourceKindWitness 'Topic
  CredentialKind :: ResourceKindWitness 'Credential
  VolumeFamilyKind :: ResourceKindWitness 'VolumeFamily
  DnsZoneFamilyKind :: ResourceKindWitness 'DnsZoneFamily
  DnsRecordFamilyKind :: ResourceKindWitness 'DnsRecordFamily
  LocalSubstrateKind :: ResourceKindWitness 'LocalSubstrate

resourceKindFromWitness :: ResourceKindWitness kind -> ResourceKind
resourceKindFromWitness witness = case witness of
  StackKind -> Stack
  ControllerFamilyKind -> ControllerFamily
  SingletonKind -> Singleton
  TopicKind -> Topic
  CredentialKind -> Credential
  VolumeFamilyKind -> VolumeFamily
  DnsZoneFamilyKind -> DnsZoneFamily
  DnsRecordFamilyKind -> DnsRecordFamily
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

-- | A witness whose surface index is not known to the caller.
--
-- Sprint @4.86@: a durable record keyed by @(stack key, scope)@ is read back
-- by callers that hold the scope but no witness — a rank-2 reader over
-- @forall surface@ cannot name one.  The scope already carries the surface, so
-- recovering the witness /from/ it is the opposite of choosing one: it is the
-- only value that can satisfy the surface checks the scope itself imposes.
data SomeCleanupSurfaceWitness where
  SomeCleanupSurfaceWitness
    :: !(CleanupSurfaceWitness surface) -> SomeCleanupSurfaceWitness

cleanupSurfaceWitnessFor :: CleanupSurface -> SomeCleanupSurfaceWitness
cleanupSurfaceWitnessFor surface = case surface of
  LocalOnly -> SomeCleanupSurfaceWitness LocalOnlySurface
  Cascade -> SomeCleanupSurfaceWitness CascadeSurface
  ExplicitPerRun -> SomeCleanupSurfaceWitness ExplicitPerRunSurface
  OperationalTeardown -> SomeCleanupSurfaceWitness OperationalTeardownSurface
  ExplicitLongLived -> SomeCleanupSurfaceWitness ExplicitLongLivedSurface
  TotalDecommission -> SomeCleanupSurfaceWitness TotalDecommissionSurface

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
  -- Sprint 7.36: the explicit long-lived surface mints completion. Its
  -- mandatory absence read-back became dischargeable when the retained EBS
  -- adapter landed -- before that, completing it was structurally unreachable
  -- rather than merely unwritten -- and its fourth required fact, the
  -- aggregate operator permit, now has a type.
  ExplicitLongLived -> True
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
  | AwsDnsValidationZoneKey
  | AwsDns01ChallengeRecordKey
  | AwsEksIamRoleFamilyKey
  | AwsEksLoadBalancerControllerFamilyKey
  deriving (Bounded, Enum, Eq, Ord, Show)

registeredResourceKeyText :: RegisteredResourceKey -> Text
registeredResourceKeyText key = case key of
  LocalLinuxRke2Key -> "local-linux-rke2"
  AwsEksKey -> "aws-eks"
  AwsEksSubzoneKey -> "aws-eks-subzone"
  AwsTestKey -> "aws-test"
  AwsEbsPerRunTestKey -> "aws-ebs-volumes-per-run-test"
  AwsEbsProductionRetainedKey -> "aws-ebs-volumes-production-retained"
  AwsDnsValidationZoneKey -> "dns-aws-validation-hosted-zone"
  AwsDns01ChallengeRecordKey -> "dns-aws-dns01-challenge-records"
  AwsEksIamRoleFamilyKey -> "aws-eks-iam-role-family"
  AwsEksLoadBalancerControllerFamilyKey ->
    "aws-eks-load-balancer-controller-family"

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
  | -- | Sprint 7.36: the deterministic EKS IAM role family and its one
    -- repository-owned managed policy. The owning cluster is explicit so the
    -- registry-derived stack/family ordering includes this family.
    AwsIamRoleFamilyCoordinate
      { awsIamRoleFamilyOwnerCluster :: !Text
      , awsIamRoleFamilyRoleNames :: ![Text]
      , awsIamRoleFamilyManagedPolicyNames :: ![Text]
      }
  | -- | Sprint 7.36: the exact AWS family created by the Load Balancer
    -- Controller for the registered public-edge Kubernetes Service owner.
    AwsLoadBalancerControllerFamilyCoordinate
      { awsLoadBalancerControllerOwnerCluster :: !Text
      , awsLoadBalancerControllerName :: !Text
      , awsLoadBalancerControllerTags :: ![(Text, Text)]
      }
  | -- | Sprint 7.36: the @dns-aws@ validation hosted-zone family.
    --
    -- Bounded by the zone-name prefix its creator authors, because the rest of
    -- the name is a per-run nonce and no exact name is knowable before the zone
    -- exists.  The prefix is the whole family definition, stated once here.
    --
    -- Deliberately __not__ defined by the owned tags in
    -- "Prodbox.Lifecycle.OwnedResourceTags".  Those tags were added later so the
    -- terminal escape audit could /see/ a leaked zone; a zone created before
    -- they landed carries none, and defining the family by them would narrow
    -- what the sweep removes to less than it removes today.  The tags remain
    -- the audit's evidence; the prefix remains the family.
    AwsRoute53ValidationZoneFamilyCoordinate
      { awsRoute53ZoneNamePrefix :: !Text
      }
  | -- | Sprint 7.36: the DNS01 challenge record family.
    --
    -- Bounded by the record-name prefix every ACME DNS01 solver writes.  The
    -- rest of the name is the certificate FQDN, which is per-run data, so the
    -- prefix is the whole static family and the zone it lives in travels on the
    -- run's 'ObservationEvidenceScope' rather than in this coordinate.  That
    -- split is deliberate: a registry coordinate that named a zone would name
    -- one substrate's zone, and the same family exists in every substrate's
    -- retained zone.
    AwsRoute53Dns01ChallengeRecordFamilyCoordinate
      { awsRoute53Dns01RecordNamePrefix :: !Text
      }
  deriving (Eq, Ord, Show)

coordinateIsAws :: ManagedResourceCoordinate -> Bool
coordinateIsAws coordinate = case coordinate of
  LocalRke2Coordinate {} -> False
  AwsPulumiStackCoordinate {} -> True
  AwsEbsPerRunFamilyCoordinate {} -> True
  AwsEbsRetainedFamilyCoordinate {} -> True
  AwsIamRoleFamilyCoordinate {} -> True
  AwsLoadBalancerControllerFamilyCoordinate {} -> True
  AwsRoute53ValidationZoneFamilyCoordinate {} -> True
  AwsRoute53Dns01ChallengeRecordFamilyCoordinate {} -> True

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
  AwsIamRoleFamilyCoordinate ownerCluster _ _ -> Just ownerCluster
  AwsLoadBalancerControllerFamilyCoordinate ownerCluster _ _ ->
    Just ownerCluster
  -- A validation hosted zone is created by a suite validation, not by a
  -- cluster's controllers, so no cluster owns its lifetime.
  AwsRoute53ValidationZoneFamilyCoordinate {} -> Nothing
  -- A DNS01 challenge record is written by cert-manager, which runs in a
  -- cluster -- but the record outlives no cluster's teardown order, and the
  -- solver that owns it is selected per certificate rather than per cluster.
  AwsRoute53Dns01ChallengeRecordFamilyCoordinate {} -> Nothing

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
  AwsIamRoleFamilyCoordinate {} -> Nothing
  AwsLoadBalancerControllerFamilyCoordinate {} -> Nothing
  AwsRoute53ValidationZoneFamilyCoordinate {} -> Nothing
  AwsRoute53Dns01ChallengeRecordFamilyCoordinate {} -> Nothing

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
    AwsIamRoleFamilyCoordinate ownerCluster roleNames policyNames ->
      Text.intercalate
        "\NUL"
        ( "aws-iam-role-family/v1"
            : ownerCluster
            : roleNames
            ++ ["managed-policies"]
            ++ policyNames
        )
    AwsLoadBalancerControllerFamilyCoordinate ownerCluster name tags ->
      Text.intercalate
        "\NUL"
        ( [ "aws-load-balancer-controller-family/v1"
          , ownerCluster
          , name
          ]
            ++ concatMap (\(key, value) -> [key, value]) tags
        )
    AwsRoute53ValidationZoneFamilyCoordinate namePrefix ->
      Text.intercalate
        "\NUL"
        ["aws-route53-validation-zone-family/v1", namePrefix]
    AwsRoute53Dns01ChallengeRecordFamilyCoordinate recordNamePrefix ->
      Text.intercalate
        "\NUL"
        ["aws-route53-dns01-challenge-record-family/v1", recordNamePrefix]

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
  , internalEvidenceAwsDnsZone :: !(Maybe HostedZoneId)
  -- ^ Sprint 7.36: the retained hosted zone this run's DNS resources live in.
  --
  -- A registered __record__ family — the DNS01 challenge TXTs — is bounded by
  -- a record-name prefix inside a zone the run keeps, so unlike every other
  -- registered family its coordinate is not complete without a zone. The
  -- account and region already travel here for exactly the same reason, and
  -- adding the zone beside them keeps one answer to \"which AWS thing is this
  -- run talking about\" rather than two.
  --
  -- @Nothing@ means the run named no DNS zone, and an adapter that needs one
  -- refuses rather than guessing: a challenge record swept in the wrong zone
  -- is either a no-op that reads as absence or a deletion in an operator's
  -- parent zone.
  , internalEvidenceLifecycleOperation :: !LifecycleOperation
  }
  deriving (Eq, Ord, Show)

-- | Mint a scope that names no DNS hosted zone.
--
-- This is the arity every existing caller already has, and it stays the default
-- because most registered families are complete without a zone.
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
    , internalEvidenceAwsDnsZone = Nothing
    , internalEvidenceLifecycleOperation = operation
    }

-- | Sprint 7.36: mint a scope that names the run's retained DNS hosted zone.
--
-- Deliberately a second minter rather than a setter on an existing scope. A
-- scope is the durable binding an observation request and its response share,
-- and a function that attached a zone to a scope already minted would let a
-- caller retarget an in-flight observation at a different zone.
mkObservationEvidenceScopeWithDnsZone
  :: CleanupSurface
  -> RegistryRevision
  -> DurableObservationRunScope
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> HostedZoneId
  -> LifecycleOperation
  -> ObservationEvidenceScope
mkObservationEvidenceScopeWithDnsZone
  surface
  revision
  runScope
  foundation
  awsScope
  dnsZone
  operation =
    ObservationEvidenceScope
      { internalEvidenceCleanupSurface = surface
      , internalEvidenceRegistryRevision = revision
      , internalEvidenceDurableRunScope = runScope
      , internalEvidenceLinuxRke2Foundation = foundation
      , internalEvidenceAwsScope = awsScope
      , internalEvidenceAwsDnsZone = Just dnsZone
      , internalEvidenceLifecycleOperation = operation
      }

evidenceAwsDnsZone :: ObservationEvidenceScope -> Maybe HostedZoneId
evidenceAwsDnsZone = internalEvidenceAwsDnsZone

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
