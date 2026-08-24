{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Static, effect-free lifecycle inventory.  Entries carry only exact
-- identity, coordinate, class, kind, authority, and observer facts.  Effectful
-- interpreters and operator command text belong above this module.
module Prodbox.Lifecycle.Teardown.Registry
  ( LifecycleClassWitness (..)
  , lifecycleClassFromWitness
  , ManagedResourceDescriptor
  , SomeManagedResourceDescriptor (..)
  , RegisteredLocalSubstrate
  , RegisteredIdentity (..)
  , managedResourceKey
  , managedResourceLifecycleClass
  , managedResourceKind
  , managedResourceCoordinate
  , managedResourceCoordinateDigest
  , managedResourceAuthority
  , managedResourceObservationAuthority
  , managedResourceRecoveryCapabilities
  , localSubstrateKey
  , localSubstrateCoordinate
  , localSubstrateCoordinateDigest
  , localSubstrateAuthority
  , localSubstrateObservationAuthority
  , localSubstrateRecoveryCapabilities
  , registeredIdentityKey
  , registeredIdentityLifecycleClass
  , registeredIdentityKind
  , registeredIdentityCoordinate
  , registeredIdentityCoordinateDigest
  , registeredIdentityAuthority
  , registeredIdentityObservationAuthority
  , registeredIdentityRecoveryCapabilities
  , lifecycleRegistryRevision
  , awsEksPulumiStackName
  , awsEksSubzonePulumiStackName
  , awsTestPulumiStackName
  , pulumiProjectNamePrefix
  , pulumiProjectNameFor
  , awsEksProvisionedClusterName
  , localLinuxRke2Resource
  , awsEksResource
  , awsEksSubzoneResource
  , awsTestResource
  , awsEbsPerRunTestResource
  , awsEbsProductionRetainedResource
  , awsDnsValidationZoneResource
  , awsDns01ChallengeRecordResource
  , awsEksIamRoleFamilyResource
  , awsEksIamRoleNames
  , awsEksIamManagedPolicyNames
  , awsEksLoadBalancerControllerFamilyResource
  , awsEksLoadBalancerControllerName
  , awsEksLoadBalancerControllerTags
  , managedResourceRegistry
  , lifecycleRegistry
  , lookupRegisteredIdentity
  , RegistryValidationError (..)
  , validateLifecycleRegistry
  , lifecycleRegistryValidation
  , CleanupTarget
  , cleanupTargetKey
  , cleanupTargetLifecycleClass
  , cleanupTargetKind
  , cleanupTargetCoordinateDigest
  , cleanupTargetRecoveryCapabilities
  , cleanupTargetSurface
  , CleanupSelectionError (..)
  , cleanupSurfaceAllows
  , projectCleanupTarget
  , cleanupTargetsForSurface
  )
where

import Data.List (group, sort)
import Data.Text (Text)
import Prodbox.Lifecycle.OwnedResourceTags
  ( dns01ChallengeRecordNamePrefix
  , dnsValidationHostedZoneNamePrefix
  )
import Prodbox.Lifecycle.Teardown.Model hiding (managedResourceCoordinateDigest)
import Prodbox.Lifecycle.Teardown.Model qualified as Model
import Prodbox.Lifecycle.Teardown.RecoveryCapability
  ( RecoveryCapabilitySet
  , noAdditionalRecoveryCapabilities
  )

data LifecycleClassWitness (life :: LifecycleClass) where
  PerRunLifecycle :: LifecycleClassWitness 'PerRun
  LongLivedLifecycle :: LifecycleClassWitness 'LongLived
  OperationalLifecycle :: LifecycleClassWitness 'Operational

lifecycleClassFromWitness :: LifecycleClassWitness life -> LifecycleClass
lifecycleClassFromWitness witness = case witness of
  PerRunLifecycle -> PerRun
  LongLivedLifecycle -> LongLived
  OperationalLifecycle -> Operational

-- | A managed descriptor is indexed by its repository-owned class and kind.
-- Its constructor is private so provider facts cannot mint or reclassify one.
data ManagedResourceDescriptor (life :: LifecycleClass) (kind :: ResourceKind)
  = ManagedResourceDescriptor
  { internalManagedResourceKey :: !RegisteredResourceKey
  , internalManagedResourceLifecycle :: !(LifecycleClassWitness life)
  , internalManagedResourceKind :: !(ResourceKindWitness kind)
  , internalManagedResourceCoordinate :: !ManagedResourceCoordinate
  , internalManagedResourceCoordinateDigest :: !ManagedResourceCoordinateDigest
  , internalManagedResourceAuthority :: !LifecycleAuthority
  , internalManagedResourceObservationAuthority :: !ObservationAuthority
  , internalManagedResourceRecoveryCapabilities :: !RecoveryCapabilitySet
  }

data SomeManagedResourceDescriptor where
  SomeManagedResourceDescriptor
    :: ManagedResourceDescriptor life kind
    -> SomeManagedResourceDescriptor

instance Eq SomeManagedResourceDescriptor where
  left == right = someManagedResourceView left == someManagedResourceView right

instance Show SomeManagedResourceDescriptor where
  show = show . someManagedResourceView

data RegisteredLocalSubstrate = RegisteredLocalSubstrate
  { internalLocalSubstrateKey :: !RegisteredResourceKey
  , internalLocalSubstrateCoordinate :: !ManagedResourceCoordinate
  , internalLocalSubstrateCoordinateDigest :: !ManagedResourceCoordinateDigest
  , internalLocalSubstrateAuthority :: !LifecycleAuthority
  , internalLocalSubstrateObservationAuthority :: !ObservationAuthority
  , internalLocalSubstrateRecoveryCapabilities :: !RecoveryCapabilitySet
  }
  deriving (Eq, Show)

data RegisteredIdentity
  = RegisteredManagedResource !SomeManagedResourceDescriptor
  | RegisteredLocalSubstrateIdentity !RegisteredLocalSubstrate
  deriving (Eq, Show)

managedResourceKey :: ManagedResourceDescriptor life kind -> RegisteredResourceKey
managedResourceKey = internalManagedResourceKey

managedResourceLifecycleClass :: ManagedResourceDescriptor life kind -> LifecycleClass
managedResourceLifecycleClass = lifecycleClassFromWitness . internalManagedResourceLifecycle

managedResourceKind :: ManagedResourceDescriptor life kind -> ResourceKind
managedResourceKind = resourceKindFromWitness . internalManagedResourceKind

managedResourceCoordinate :: ManagedResourceDescriptor life kind -> ManagedResourceCoordinate
managedResourceCoordinate = internalManagedResourceCoordinate

managedResourceCoordinateDigest
  :: ManagedResourceDescriptor life kind -> ManagedResourceCoordinateDigest
managedResourceCoordinateDigest = internalManagedResourceCoordinateDigest

managedResourceAuthority :: ManagedResourceDescriptor life kind -> LifecycleAuthority
managedResourceAuthority = internalManagedResourceAuthority

managedResourceObservationAuthority
  :: ManagedResourceDescriptor life kind -> ObservationAuthority
managedResourceObservationAuthority = internalManagedResourceObservationAuthority

managedResourceRecoveryCapabilities
  :: ManagedResourceDescriptor life kind -> RecoveryCapabilitySet
managedResourceRecoveryCapabilities = internalManagedResourceRecoveryCapabilities

localSubstrateKey :: RegisteredLocalSubstrate -> RegisteredResourceKey
localSubstrateKey = internalLocalSubstrateKey

localSubstrateCoordinate :: RegisteredLocalSubstrate -> ManagedResourceCoordinate
localSubstrateCoordinate = internalLocalSubstrateCoordinate

localSubstrateCoordinateDigest
  :: RegisteredLocalSubstrate -> ManagedResourceCoordinateDigest
localSubstrateCoordinateDigest = internalLocalSubstrateCoordinateDigest

localSubstrateAuthority :: RegisteredLocalSubstrate -> LifecycleAuthority
localSubstrateAuthority = internalLocalSubstrateAuthority

localSubstrateObservationAuthority :: RegisteredLocalSubstrate -> ObservationAuthority
localSubstrateObservationAuthority = internalLocalSubstrateObservationAuthority

localSubstrateRecoveryCapabilities
  :: RegisteredLocalSubstrate -> RecoveryCapabilitySet
localSubstrateRecoveryCapabilities = internalLocalSubstrateRecoveryCapabilities

registeredIdentityKey :: RegisteredIdentity -> RegisteredResourceKey
registeredIdentityKey identity = case identity of
  RegisteredManagedResource (SomeManagedResourceDescriptor descriptor) ->
    managedResourceKey descriptor
  RegisteredLocalSubstrateIdentity substrate -> localSubstrateKey substrate

registeredIdentityLifecycleClass :: RegisteredIdentity -> Maybe LifecycleClass
registeredIdentityLifecycleClass identity = case identity of
  RegisteredManagedResource (SomeManagedResourceDescriptor descriptor) ->
    Just (managedResourceLifecycleClass descriptor)
  RegisteredLocalSubstrateIdentity _ -> Nothing

registeredIdentityKind :: RegisteredIdentity -> ResourceKind
registeredIdentityKind identity = case identity of
  RegisteredManagedResource (SomeManagedResourceDescriptor descriptor) ->
    managedResourceKind descriptor
  RegisteredLocalSubstrateIdentity _ -> LocalSubstrate

registeredIdentityCoordinate :: RegisteredIdentity -> ManagedResourceCoordinate
registeredIdentityCoordinate identity = case identity of
  RegisteredManagedResource (SomeManagedResourceDescriptor descriptor) ->
    managedResourceCoordinate descriptor
  RegisteredLocalSubstrateIdentity substrate -> localSubstrateCoordinate substrate

registeredIdentityCoordinateDigest
  :: RegisteredIdentity -> ManagedResourceCoordinateDigest
registeredIdentityCoordinateDigest identity = case identity of
  RegisteredManagedResource (SomeManagedResourceDescriptor descriptor) ->
    managedResourceCoordinateDigest descriptor
  RegisteredLocalSubstrateIdentity substrate ->
    localSubstrateCoordinateDigest substrate

registeredIdentityAuthority :: RegisteredIdentity -> LifecycleAuthority
registeredIdentityAuthority identity = case identity of
  RegisteredManagedResource (SomeManagedResourceDescriptor descriptor) ->
    managedResourceAuthority descriptor
  RegisteredLocalSubstrateIdentity substrate -> localSubstrateAuthority substrate

registeredIdentityObservationAuthority :: RegisteredIdentity -> ObservationAuthority
registeredIdentityObservationAuthority identity = case identity of
  RegisteredManagedResource (SomeManagedResourceDescriptor descriptor) ->
    managedResourceObservationAuthority descriptor
  RegisteredLocalSubstrateIdentity substrate ->
    localSubstrateObservationAuthority substrate

registeredIdentityRecoveryCapabilities
  :: RegisteredIdentity -> RecoveryCapabilitySet
registeredIdentityRecoveryCapabilities identity = case identity of
  RegisteredManagedResource (SomeManagedResourceDescriptor descriptor) ->
    managedResourceRecoveryCapabilities descriptor
  RegisteredLocalSubstrateIdentity substrate ->
    localSubstrateRecoveryCapabilities substrate

lifecycleRegistryRevision :: RegistryRevision
lifecycleRegistryRevision = RegistryRevision "lifecycle-registry/v1"

localLinuxRke2Resource :: RegisteredLocalSubstrate
localLinuxRke2Resource =
  mkLocalSubstrate
    LocalLinuxRke2Key
    (LocalRke2Coordinate "linux-rke2-foundation")

-- | The Pulumi stack names of the registered per-run stacks.
--
-- Sprint 4.85: named here because they were also written down in
-- 'Prodbox.Lifecycle.LiveResidue' and 'Prodbox.Infra.AwsEksTestStack', so the
-- same fact had three independent statements and a stack rename could split
-- them silently. This is the compiled source; the other two are projections of
-- it.
awsEksPulumiStackName, awsEksSubzonePulumiStackName, awsTestPulumiStackName :: Text
awsEksPulumiStackName = "aws-eks-test"
awsEksSubzonePulumiStackName = "aws-eks-subzone"
awsTestPulumiStackName = "aws-test"

-- | Every provisioning program's Pulumi project is @prodbox-\<stack name\>@;
-- see the @name:@ field of each @pulumi\/*\/Pulumi.yaml@, which
-- @prodbox dev check@ joins these coordinates to.
pulumiProjectNamePrefix :: Text
pulumiProjectNamePrefix = "prodbox-"

pulumiProjectNameFor :: Text -> Text
pulumiProjectNameFor stackName = pulumiProjectNamePrefix <> stackName

-- | The EKS cluster the @aws-eks@ program declares.
--
-- @pulumi\/aws-eks\/Main.yaml@ sets @clusterName: ${stackName}-cluster@, and
-- 'pulumiEksClusterNameSuffix' is where that rule is written down. Deriving the
-- name here is what makes the per-run EBS family's controller owner a fact
-- about the registry rather than a fourth independently authored string.
awsEksProvisionedClusterName :: Text
awsEksProvisionedClusterName =
  awsEksPulumiStackName <> pulumiEksClusterNameSuffix

awsEksResource :: ManagedResourceDescriptor 'PerRun 'Stack
awsEksResource =
  mkManagedResource
    AwsEksKey
    PerRunLifecycle
    StackKind
    ( AwsPulumiStackCoordinate
        (pulumiProjectNameFor awsEksPulumiStackName)
        awsEksPulumiStackName
    )
    AwsResourceApiAuthority

awsEksSubzoneResource :: ManagedResourceDescriptor 'PerRun 'Stack
awsEksSubzoneResource =
  mkManagedResource
    AwsEksSubzoneKey
    PerRunLifecycle
    StackKind
    ( AwsPulumiStackCoordinate
        (pulumiProjectNameFor awsEksSubzonePulumiStackName)
        awsEksSubzonePulumiStackName
    )
    AwsResourceApiAuthority

awsTestResource :: ManagedResourceDescriptor 'PerRun 'Stack
awsTestResource =
  mkManagedResource
    AwsTestKey
    PerRunLifecycle
    StackKind
    ( AwsPulumiStackCoordinate
        (pulumiProjectNameFor awsTestPulumiStackName)
        awsTestPulumiStackName
    )
    AwsResourceApiAuthority

-- | The volumes the EKS cluster's EBS CSI driver provisions for one validation
-- run.
--
-- The cluster ownership tag is built from the EKS stack's own name rather than
-- written out, so "the EKS stack owns this family" is true by construction
-- instead of being a claim the ownership derivation has to discover. The
-- rendered coordinate is byte-identical to the string it replaced, so the
-- coordinate digest is unchanged.
awsEbsPerRunTestResource :: ManagedResourceDescriptor 'PerRun 'VolumeFamily
awsEbsPerRunTestResource =
  mkManagedResource
    AwsEbsPerRunTestKey
    PerRunLifecycle
    VolumeFamilyKind
    ( AwsEbsPerRunFamilyCoordinate
        "prodbox.io/lifecycle"
        "per-run-test"
        (clusterOwnershipTagPrefix <> awsEksProvisionedClusterName)
        clusterOwnedTagValue
    )
    AwsResourceApiAuthority

awsEbsProductionRetainedResource
  :: ManagedResourceDescriptor 'LongLived 'VolumeFamily
awsEbsProductionRetainedResource =
  mkManagedResource
    AwsEbsProductionRetainedKey
    LongLivedLifecycle
    VolumeFamilyKind
    (AwsEbsRetainedFamilyCoordinate "prodbox.io/lifecycle" "retained-ebs")
    AwsResourceApiAuthority

-- | Sprint 7.36: the @dns-aws@ validation hosted-zone family.
--
-- Registered only now, with its adapter, because registering a descriptor
-- compiles a mandatory absence read-back and a surface that mints completion
-- asserts every such read-back succeeded — so registering it before
-- 'Prodbox.Lifecycle.Teardown.AwsRoute53ZoneAdapter' existed would have made
-- the @Cascade@ and @ExplicitPerRun@ programs unsatisfiable rather than making
-- the zone swept.  That pairing rule is mechanical:
-- @Prodbox.CheckCode.registeredTargetExecutorViolations@ fails the build on the
-- unpaired shape.
awsDnsValidationZoneResource :: ManagedResourceDescriptor 'PerRun 'DnsZoneFamily
awsDnsValidationZoneResource =
  mkManagedResource
    AwsDnsValidationZoneKey
    PerRunLifecycle
    DnsZoneFamilyKind
    (AwsRoute53ValidationZoneFamilyCoordinate dnsValidationHostedZoneNamePrefix)
    AwsResourceApiAuthority

-- | Sprint 7.36: the DNS01 challenge record family.
--
-- Registered with its adapter and its executor, for the same reason the
-- validation hosted zone was: a registered descriptor compiles a __mandatory__
-- absence read-back, and a surface that reports completion asserts every such
-- read-back succeeded.
--
-- Its executor is the only one in the registry whose reconcile step is not a
-- Provider mutation.  cert-manager's solver owns the record, and a Provider
-- delete would race it into rewriting one; the record is therefore removed by
-- deleting the Kubernetes object that owns it, and only the separate Route 53
-- read-back closes the family.
--
-- @PerRun@ because the AWS-lane challenge is per-run: the certificate the
-- record validates is issued for one suite run, and a run that fails before
-- issuance completes is exactly the case that leaves the record behind.
awsDns01ChallengeRecordResource
  :: ManagedResourceDescriptor 'PerRun 'DnsRecordFamily
awsDns01ChallengeRecordResource =
  mkManagedResource
    AwsDns01ChallengeRecordKey
    PerRunLifecycle
    DnsRecordFamilyKind
    (AwsRoute53Dns01ChallengeRecordFamilyCoordinate dns01ChallengeRecordNamePrefix)
    AwsResourceApiAuthority

-- | The four deterministic roles declared by @pulumi/aws-eks/Main.yaml@.
-- Derived from the registered stack and cluster names so the cleanup family,
-- the Pulumi program, and the stack/family ownership edge share one naming
-- rule. The EBS CSI role predates the common prefix but is still exact.
awsEksIamRoleNames :: [Text]
awsEksIamRoleNames =
  [ iamPrefix <> "-cluster-role"
  , iamPrefix <> "-node-role"
  , iamPrefix <> "-lbc-role"
  , awsEksPulumiStackName <> "-ebs-csi-driver"
  ]
 where
  iamPrefix =
    "prodbox-"
      <> awsEksPulumiStackName
      <> "-"
      <> awsEksProvisionedClusterName

awsEksIamManagedPolicyNames :: [Text]
awsEksIamManagedPolicyNames = [awsEksPulumiStackName <> "-aws-lb-controller"]

awsEksIamRoleFamilyResource
  :: ManagedResourceDescriptor 'PerRun 'ControllerFamily
awsEksIamRoleFamilyResource =
  mkManagedResource
    AwsEksIamRoleFamilyKey
    PerRunLifecycle
    ControllerFamilyKind
    ( AwsIamRoleFamilyCoordinate
        awsEksProvisionedClusterName
        awsEksIamRoleNames
        awsEksIamManagedPolicyNames
    )
    AwsResourceApiAuthority

-- | The NLB family created by the AWS Load Balancer Controller for the
-- public-edge Service.  Its AWS name and tags are written before the Service
-- is enabled and are shared by the Kubernetes manifest, the retained
-- controller-owner record, and the Provider backstop.
awsEksLoadBalancerControllerName :: Text
awsEksLoadBalancerControllerName = "prodbox-public-edge"

awsEksLoadBalancerControllerTags :: [(Text, Text)]
awsEksLoadBalancerControllerTags =
  [ ("prodbox.io/cluster", awsEksProvisionedClusterName)
  , ("prodbox.io/managed-by", "prodbox")
  , ("prodbox.io/resource", "public-edge")
  ]

awsEksLoadBalancerControllerFamilyResource
  :: ManagedResourceDescriptor 'PerRun 'ControllerFamily
awsEksLoadBalancerControllerFamilyResource =
  mkManagedResource
    AwsEksLoadBalancerControllerFamilyKey
    PerRunLifecycle
    ControllerFamilyKind
    ( AwsLoadBalancerControllerFamilyCoordinate
        awsEksProvisionedClusterName
        awsEksLoadBalancerControllerName
        awsEksLoadBalancerControllerTags
    )
    AwsResourceApiAuthority

managedResourceRegistry :: [SomeManagedResourceDescriptor]
managedResourceRegistry =
  [ SomeManagedResourceDescriptor awsEksResource
  , SomeManagedResourceDescriptor awsEksSubzoneResource
  , SomeManagedResourceDescriptor awsTestResource
  , SomeManagedResourceDescriptor awsEbsPerRunTestResource
  , SomeManagedResourceDescriptor awsDnsValidationZoneResource
  , SomeManagedResourceDescriptor awsDns01ChallengeRecordResource
  , SomeManagedResourceDescriptor awsEksIamRoleFamilyResource
  , SomeManagedResourceDescriptor awsEksLoadBalancerControllerFamilyResource
  , SomeManagedResourceDescriptor awsEbsProductionRetainedResource
  ]

lifecycleRegistry :: [RegisteredIdentity]
lifecycleRegistry =
  RegisteredLocalSubstrateIdentity localLinuxRke2Resource
    : map RegisteredManagedResource managedResourceRegistry

lookupRegisteredIdentity :: RegisteredResourceKey -> Maybe RegisteredIdentity
lookupRegisteredIdentity wanted =
  findFirst ((== wanted) . registeredIdentityKey) lifecycleRegistry

data RegistryValidationError
  = DuplicateRegistryKey !RegisteredResourceKey
  | DuplicateRegistryCoordinate !ManagedResourceCoordinateDigest
  | RegistryAuthorityMismatch !RegisteredResourceKey !LifecycleAuthority
  | RegistryObserverMismatch !RegisteredResourceKey !ObservationAuthority
  deriving (Eq, Show)

validateLifecycleRegistry
  :: [RegisteredIdentity] -> Either RegistryValidationError ()
validateLifecycleRegistry identities = do
  case duplicateValues (map registeredIdentityKey identities) of
    duplicateKey : _ -> Left (DuplicateRegistryKey duplicateKey)
    [] -> Right ()
  case duplicateValues (map registeredIdentityCoordinateDigest identities) of
    duplicateCoordinate : _ ->
      Left (DuplicateRegistryCoordinate duplicateCoordinate)
    [] -> Right ()
  mapM_ validateAuthority identities
 where
  validateAuthority identity
    | registeredIdentityAuthority identity /= LinuxRke2LifecycleAuthority =
        Left
          ( RegistryAuthorityMismatch
              (registeredIdentityKey identity)
              (registeredIdentityAuthority identity)
          )
    | coordinateIsAws (registeredIdentityCoordinate identity)
        && registeredIdentityObservationAuthority identity /= AwsResourceApiAuthority =
        Left
          ( RegistryObserverMismatch
              (registeredIdentityKey identity)
              (registeredIdentityObservationAuthority identity)
          )
    | not (coordinateIsAws (registeredIdentityCoordinate identity))
        && registeredIdentityObservationAuthority identity /= LocalRke2SystemAuthority =
        Left
          ( RegistryObserverMismatch
              (registeredIdentityKey identity)
              (registeredIdentityObservationAuthority identity)
          )
    | otherwise = Right ()

lifecycleRegistryValidation :: Either RegistryValidationError ()
lifecycleRegistryValidation = validateLifecycleRegistry lifecycleRegistry

-- | A legal target projected from a registered identity.  Constructors remain
-- private: callers select through 'projectCleanupTarget', which preserves the
-- class/surface relation in the result index.
data CleanupTarget (surface :: CleanupSurface) where
  LocalOnlyTarget
    :: RegisteredLocalSubstrate
    -> CleanupTarget 'LocalOnly
  CascadePerRunTarget
    :: ManagedResourceDescriptor 'PerRun kind
    -> CleanupTarget 'Cascade
  CascadeLocalTarget
    :: RegisteredLocalSubstrate
    -> CleanupTarget 'Cascade
  ExplicitPerRunTarget
    :: ManagedResourceDescriptor 'PerRun kind
    -> CleanupTarget 'ExplicitPerRun
  OperationalTarget
    :: ManagedResourceDescriptor 'Operational kind
    -> CleanupTarget 'OperationalTeardown
  ExplicitLongLivedTarget
    :: ManagedResourceDescriptor 'LongLived kind
    -> CleanupTarget 'ExplicitLongLived
  TotalDecommissionManagedTarget
    :: ManagedResourceDescriptor life kind
    -> CleanupTarget 'TotalDecommission
  TotalDecommissionLocalTarget
    :: RegisteredLocalSubstrate
    -> CleanupTarget 'TotalDecommission

cleanupTargetKey :: CleanupTarget surface -> RegisteredResourceKey
cleanupTargetKey target = case target of
  LocalOnlyTarget substrate -> localSubstrateKey substrate
  CascadePerRunTarget resource -> managedResourceKey resource
  CascadeLocalTarget substrate -> localSubstrateKey substrate
  ExplicitPerRunTarget resource -> managedResourceKey resource
  OperationalTarget resource -> managedResourceKey resource
  ExplicitLongLivedTarget resource -> managedResourceKey resource
  TotalDecommissionManagedTarget resource -> managedResourceKey resource
  TotalDecommissionLocalTarget substrate -> localSubstrateKey substrate

cleanupTargetLifecycleClass :: CleanupTarget surface -> Maybe LifecycleClass
cleanupTargetLifecycleClass target = case target of
  LocalOnlyTarget _ -> Nothing
  CascadePerRunTarget resource -> Just (managedResourceLifecycleClass resource)
  CascadeLocalTarget _ -> Nothing
  ExplicitPerRunTarget resource -> Just (managedResourceLifecycleClass resource)
  OperationalTarget resource -> Just (managedResourceLifecycleClass resource)
  ExplicitLongLivedTarget resource -> Just (managedResourceLifecycleClass resource)
  TotalDecommissionManagedTarget resource ->
    Just (managedResourceLifecycleClass resource)
  TotalDecommissionLocalTarget _ -> Nothing

cleanupTargetKind :: CleanupTarget surface -> ResourceKind
cleanupTargetKind target = case target of
  LocalOnlyTarget _ -> LocalSubstrate
  CascadePerRunTarget resource -> managedResourceKind resource
  CascadeLocalTarget _ -> LocalSubstrate
  ExplicitPerRunTarget resource -> managedResourceKind resource
  OperationalTarget resource -> managedResourceKind resource
  ExplicitLongLivedTarget resource -> managedResourceKind resource
  TotalDecommissionManagedTarget resource -> managedResourceKind resource
  TotalDecommissionLocalTarget _ -> LocalSubstrate

cleanupTargetCoordinateDigest
  :: CleanupTarget surface -> ManagedResourceCoordinateDigest
cleanupTargetCoordinateDigest target = case target of
  LocalOnlyTarget substrate -> localSubstrateCoordinateDigest substrate
  CascadePerRunTarget resource -> managedResourceCoordinateDigest resource
  CascadeLocalTarget substrate -> localSubstrateCoordinateDigest substrate
  ExplicitPerRunTarget resource -> managedResourceCoordinateDigest resource
  OperationalTarget resource -> managedResourceCoordinateDigest resource
  ExplicitLongLivedTarget resource -> managedResourceCoordinateDigest resource
  TotalDecommissionManagedTarget resource ->
    managedResourceCoordinateDigest resource
  TotalDecommissionLocalTarget substrate -> localSubstrateCoordinateDigest substrate

cleanupTargetRecoveryCapabilities
  :: CleanupTarget surface -> RecoveryCapabilitySet
cleanupTargetRecoveryCapabilities target = case target of
  LocalOnlyTarget substrate -> localSubstrateRecoveryCapabilities substrate
  CascadePerRunTarget resource -> managedResourceRecoveryCapabilities resource
  CascadeLocalTarget substrate -> localSubstrateRecoveryCapabilities substrate
  ExplicitPerRunTarget resource -> managedResourceRecoveryCapabilities resource
  OperationalTarget resource -> managedResourceRecoveryCapabilities resource
  ExplicitLongLivedTarget resource -> managedResourceRecoveryCapabilities resource
  TotalDecommissionManagedTarget resource ->
    managedResourceRecoveryCapabilities resource
  TotalDecommissionLocalTarget substrate ->
    localSubstrateRecoveryCapabilities substrate

cleanupTargetSurface :: CleanupTarget surface -> CleanupSurface
cleanupTargetSurface = targetSurface

data CleanupSelectionError
  = ManagedResourceNotAllowedOnSurface
      !RegisteredResourceKey
      !LifecycleClass
      !CleanupSurface
  | LocalSubstrateNotAllowedOnSurface
      !RegisteredResourceKey
      !CleanupSurface
  deriving (Eq, Show)

cleanupSurfaceAllows :: CleanupSurface -> RegisteredIdentity -> Bool
cleanupSurfaceAllows surface identity = case (surface, identity) of
  (LocalOnly, RegisteredLocalSubstrateIdentity _) -> True
  (Cascade, RegisteredLocalSubstrateIdentity _) -> True
  (Cascade, RegisteredManagedResource (SomeManagedResourceDescriptor resource)) ->
    managedResourceLifecycleClass resource == PerRun
  (ExplicitPerRun, RegisteredManagedResource (SomeManagedResourceDescriptor resource)) ->
    managedResourceLifecycleClass resource == PerRun
  (OperationalTeardown, RegisteredManagedResource (SomeManagedResourceDescriptor resource)) ->
    managedResourceLifecycleClass resource == Operational
  (ExplicitLongLived, RegisteredManagedResource (SomeManagedResourceDescriptor resource)) ->
    managedResourceLifecycleClass resource == LongLived
  (TotalDecommission, _) -> True
  _ -> False

projectCleanupTarget
  :: CleanupSurfaceWitness surface
  -> RegisteredIdentity
  -> Either CleanupSelectionError (CleanupTarget surface)
projectCleanupTarget surfaceWitness identity = case (surfaceWitness, identity) of
  (LocalOnlySurface, RegisteredLocalSubstrateIdentity substrate) ->
    Right (LocalOnlyTarget substrate)
  (CascadeSurface, RegisteredLocalSubstrateIdentity substrate) ->
    Right (CascadeLocalTarget substrate)
  (CascadeSurface, RegisteredManagedResource (SomeManagedResourceDescriptor resource)) ->
    case internalManagedResourceLifecycle resource of
      PerRunLifecycle -> Right (CascadePerRunTarget resource)
      lifecycle -> Left (managedSelectionError Cascade resource lifecycle)
  (ExplicitPerRunSurface, RegisteredManagedResource (SomeManagedResourceDescriptor resource)) ->
    case internalManagedResourceLifecycle resource of
      PerRunLifecycle -> Right (ExplicitPerRunTarget resource)
      lifecycle -> Left (managedSelectionError ExplicitPerRun resource lifecycle)
  (OperationalTeardownSurface, RegisteredManagedResource (SomeManagedResourceDescriptor resource)) ->
    case internalManagedResourceLifecycle resource of
      OperationalLifecycle -> Right (OperationalTarget resource)
      lifecycle -> Left (managedSelectionError OperationalTeardown resource lifecycle)
  (ExplicitLongLivedSurface, RegisteredManagedResource (SomeManagedResourceDescriptor resource)) ->
    case internalManagedResourceLifecycle resource of
      LongLivedLifecycle -> Right (ExplicitLongLivedTarget resource)
      lifecycle -> Left (managedSelectionError ExplicitLongLived resource lifecycle)
  (TotalDecommissionSurface, RegisteredManagedResource (SomeManagedResourceDescriptor resource)) ->
    Right (TotalDecommissionManagedTarget resource)
  (TotalDecommissionSurface, RegisteredLocalSubstrateIdentity substrate) ->
    Right (TotalDecommissionLocalTarget substrate)
  (_, RegisteredLocalSubstrateIdentity substrate) ->
    Left
      ( LocalSubstrateNotAllowedOnSurface
          (localSubstrateKey substrate)
          (cleanupSurfaceFromWitness surfaceWitness)
      )
  (_, RegisteredManagedResource (SomeManagedResourceDescriptor resource)) ->
    Left
      ( ManagedResourceNotAllowedOnSurface
          (managedResourceKey resource)
          (managedResourceLifecycleClass resource)
          (cleanupSurfaceFromWitness surfaceWitness)
      )

cleanupTargetsForSurface
  :: CleanupSurfaceWitness surface -> [CleanupTarget surface]
cleanupTargetsForSurface surface =
  [ target
  | identity <- orderedIdentities
  , Right target <- [projectCleanupTarget surface identity]
  ]
 where
  -- Aggregate destructive surfaces keep the separately typed local
  -- foundation last.  This is registry projection order, not an effectful
  -- execution program.
  orderedIdentities = case surface of
    CascadeSurface -> managedIdentities ++ localIdentities
    TotalDecommissionSurface -> managedIdentities ++ localIdentities
    _ -> lifecycleRegistry
  managedIdentities =
    [identity | identity@(RegisteredManagedResource _) <- lifecycleRegistry]
  localIdentities =
    [identity | identity@(RegisteredLocalSubstrateIdentity _) <- lifecycleRegistry]

mkManagedResource
  :: RegisteredResourceKey
  -> LifecycleClassWitness life
  -> ResourceKindWitness kind
  -> ManagedResourceCoordinate
  -> ObservationAuthority
  -> ManagedResourceDescriptor life kind
mkManagedResource key lifecycle kind coordinate observer =
  ManagedResourceDescriptor
    { internalManagedResourceKey = key
    , internalManagedResourceLifecycle = lifecycle
    , internalManagedResourceKind = kind
    , internalManagedResourceCoordinate = coordinate
    , internalManagedResourceCoordinateDigest =
        Model.managedResourceCoordinateDigest coordinate
    , internalManagedResourceAuthority = LinuxRke2LifecycleAuthority
    , internalManagedResourceObservationAuthority = observer
    , internalManagedResourceRecoveryCapabilities =
        noAdditionalRecoveryCapabilities
    }

mkLocalSubstrate
  :: RegisteredResourceKey
  -> ManagedResourceCoordinate
  -> RegisteredLocalSubstrate
mkLocalSubstrate key coordinate =
  RegisteredLocalSubstrate
    { internalLocalSubstrateKey = key
    , internalLocalSubstrateCoordinate = coordinate
    , internalLocalSubstrateCoordinateDigest =
        Model.managedResourceCoordinateDigest coordinate
    , internalLocalSubstrateAuthority = LinuxRke2LifecycleAuthority
    , internalLocalSubstrateObservationAuthority = LocalRke2SystemAuthority
    , internalLocalSubstrateRecoveryCapabilities =
        noAdditionalRecoveryCapabilities
    }

someManagedResourceView
  :: SomeManagedResourceDescriptor
  -> ( RegisteredResourceKey
     , LifecycleClass
     , ResourceKind
     , ManagedResourceCoordinate
     , ManagedResourceCoordinateDigest
     , LifecycleAuthority
     , ObservationAuthority
     , RecoveryCapabilitySet
     )
someManagedResourceView (SomeManagedResourceDescriptor resource) =
  ( managedResourceKey resource
  , managedResourceLifecycleClass resource
  , managedResourceKind resource
  , managedResourceCoordinate resource
  , managedResourceCoordinateDigest resource
  , managedResourceAuthority resource
  , managedResourceObservationAuthority resource
  , managedResourceRecoveryCapabilities resource
  )

managedSelectionError
  :: CleanupSurface
  -> ManagedResourceDescriptor life kind
  -> LifecycleClassWitness life
  -> CleanupSelectionError
managedSelectionError surface resource lifecycle =
  ManagedResourceNotAllowedOnSurface
    (managedResourceKey resource)
    (lifecycleClassFromWitness lifecycle)
    surface

targetSurface :: CleanupTarget surface -> CleanupSurface
targetSurface target = case target of
  LocalOnlyTarget _ -> LocalOnly
  CascadePerRunTarget _ -> Cascade
  CascadeLocalTarget _ -> Cascade
  ExplicitPerRunTarget _ -> ExplicitPerRun
  OperationalTarget _ -> OperationalTeardown
  ExplicitLongLivedTarget _ -> ExplicitLongLived
  TotalDecommissionManagedTarget _ -> TotalDecommission
  TotalDecommissionLocalTarget _ -> TotalDecommission

duplicateValues :: (Ord value) => [value] -> [value]
duplicateValues values =
  [ value
  | groupedValues@(value : _) <- group (sort values)
  , length groupedValues > 1
  ]

findFirst :: (value -> Bool) -> [value] -> Maybe value
findFirst predicate values = case values of
  [] -> Nothing
  value : remaining
    | predicate value -> Just value
    | otherwise -> findFirst predicate remaining
