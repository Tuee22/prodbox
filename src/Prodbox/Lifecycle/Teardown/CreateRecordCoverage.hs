{-# LANGUAGE OverloadedStrings #-}

-- | What reaches the write-ahead ownership lane, what does not, and why.
--
-- The write-ahead ownership manifest names, before any effect, the resources a
-- per-run stack create is about to make, so a cleanup that loses its cluster can
-- still destroy them. It can only name what a registered stack create makes.
-- Other things in this repository create AWS resources without one: a retained
-- program, volumes made straight through the AWS client, IAM principals made by
-- name, a validation hosted zone, and controllers reconciling Kubernetes objects.
-- This module is the one place that states, for every such creator, whether it
-- is on the lane, declared inside a stack's manifest, or deliberately off it, and
-- which destroy path covers it.
--
-- __The table is a declaration, and a gate keeps it true.__ An exclusion that is
-- only an absent import is inferred, and an inference is not a decision. The
-- checks in "Prodbox.CheckCode" make the table total over the registry, equal to
-- the manifest's own derived edges, and consistent with the source it describes,
-- so a program that later joins or leaves the lane, or a creator nobody decided
-- about, fails the build instead of changing the answer silently.
--
-- Two fields are separate on purpose. Whether a creator is on the write-ahead
-- /lane/ and whether it carries the provider-side run-scope /tag/ are different
-- decisions with different reasons: the retained @aws-ses@ program is outside the
-- lane because nothing derives a per-run destroy order for it, and carries no
-- run tag because a per-run marker on the one stack nothing may reap would tell a
-- per-run sweep that it belongs to the run being reaped.
--
-- This module adds no writer and changes no durable shape. The controller
-- families are /declared/ in the owning stack's manifest by the registry-derived
-- edges that already exist; the table records that relation rather than creating
-- it.
module Prodbox.Lifecycle.Teardown.CreateRecordCoverage
  ( CreatorSubject (..)
  , RecordRelation (..)
  , OffLaneBar (..)
  , RunScopeTagDecision (..)
  , DestroyCite (..)
  , CreateRecordRow (..)
  , DerivedRecordRelation (..)
  , createRecordCoverage
  , derivedRecordRelation
  , derivedRelationOfRegistry
  , perRunProgramDirectories
  , nativeCreatorModules
  )
where

import Data.Text (Text)
import Prodbox.Lifecycle.Teardown.Model
  ( RegisteredResourceKey (..)
  , ResourceKind (..)
  )
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( ownershipEdgeResourceKey
  , ownershipEdgeStackKey
  , registeredOwnershipEdges
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( SomeManagedResourceDescriptor (..)
  , managedResourceKey
  , managedResourceKind
  , managedResourceRegistry
  )

-- | Who creates AWS resources.
data CreatorSubject
  = -- | A Pulumi program directory under @pulumi\/@, with the Infra module that
    -- drives it.
    PulumiProgramCreator !Text !FilePath
  | -- | A registry family that is not a stack: it has no Pulumi program of its
    -- own.
    RegisteredKeyCreator !RegisteredResourceKey
  | -- | A module that creates through the native AWS clients, with its entry
    -- function. These have no registry key and the regional Tagging API cannot
    -- see what they make.
    NativeClientCreator !FilePath !Text
  deriving (Eq, Show)

-- | How a creator relates to the write-ahead ownership lane.
data RecordRelation
  = -- | A registered stack create: the lane records it before the effect.
    OnWriteAheadLane !RegisteredResourceKey
  | -- | A family the owning stack's manifest already declares by registry-derived
    -- edge. It is named by key and coordinate digest before any effect; it has no
    -- member identities, and nothing that destroys a family reads them.
    DeclaredInStackManifest !RegisteredResourceKey
  | -- | Deliberately off the lane, with the structural reason it cannot be on it.
    OffWriteAheadLane !OffLaneBar
  deriving (Eq, Show)

-- | Why a creator cannot be on the lane.
data OffLaneBar
  = -- | There is no registered resource key for it, so the manifest cannot name
    -- it (the retained @aws-ses@ program, the production IAM principals).
    BarNoRegisteredKey
  | -- | It has a key but not a stack kind, and the manifest intent refuses a
    -- non-stack kind (retained EBS, the validation zone, the DNS01 records).
    BarKeyIsNotStack
  deriving (Eq, Show)

-- | The provider-side run-scope tag, decided separately from the lane.
data RunScopeTagDecision
  = RunScopeTagStamped
  | RunScopeTagWithheld
  deriving (Eq, Show)

-- | A destroy path, named so the gate can check it exists: a source file and a
-- top-level identifier defined in it.
data DestroyCite = DestroyCite
  { citeModule :: !FilePath
  , citeIdentifier :: !Text
  }
  deriving (Eq, Show)

data CreateRecordRow = CreateRecordRow
  { rowSubject :: !CreatorSubject
  , rowRelation :: !RecordRelation
  , rowRunScopeTag :: !(Maybe RunScopeTagDecision)
  -- ^ Only a Pulumi program carries this decision.
  , rowDestroy :: ![DestroyCite]
  , rowReason :: !Text
  }
  deriving (Eq, Show)

-- | What the registry says about a key, computed and never authored.
data DerivedRecordRelation
  = DerivedStack
  | -- | A family some stack's manifest declares, with that stack.
    DerivedControllerFamily !RegisteredResourceKey
  | DerivedStandalone
  deriving (Eq, Show)

-- | The registry's own answer for one key. 'Nothing' only for the local
-- substrate key, which is not an AWS creator.
derivedRecordRelation :: RegisteredResourceKey -> Maybe DerivedRecordRelation
derivedRecordRelation key = lookup key derivedRelationOfRegistry

-- | The derived relation of every registered AWS key.
derivedRelationOfRegistry :: [(RegisteredResourceKey, DerivedRecordRelation)]
derivedRelationOfRegistry =
  [ (key, relationOf key (managedResourceKind descriptor))
  | SomeManagedResourceDescriptor descriptor <- managedResourceRegistry
  , let key = managedResourceKey descriptor
  ]
 where
  relationOf key kind = case kind of
    Stack -> DerivedStack
    _ -> case [ ownershipEdgeStackKey edge | edge <- registeredOwnershipEdges, ownershipEdgeResourceKey edge == key
              ] of
      owner : _ -> DerivedControllerFamily owner
      [] -> DerivedStandalone

-- | Every creator of AWS resources this repository knows, with its lane
-- relation, its run-tag decision, the destroy path that covers it and the
-- reason.
createRecordCoverage :: [CreateRecordRow]
createRecordCoverage =
  [ programRow
      "aws-eks"
      "src/Prodbox/Infra/AwsEksTestStack.hs"
      AwsEksKey
      [DestroyCite "src/Prodbox/Lifecycle/Teardown/AwsEksDestroyAdapter.hs" "mkAwsEksDestroyRequest"]
  , programRow
      "aws-eks-subzone"
      "src/Prodbox/Infra/AwsEksSubzoneStack.hs"
      AwsEksSubzoneKey
      [DestroyCite "src/Prodbox/Lifecycle/Teardown/AwsStackAdapter.hs" "mkAwsStackDestroyRequest"]
  , programRow
      "aws-test"
      "src/Prodbox/Infra/AwsTestStack.hs"
      AwsTestKey
      [DestroyCite "src/Prodbox/Lifecycle/Teardown/AwsStackAdapter.hs" "mkAwsStackDestroyRequest"]
  , CreateRecordRow
      { rowSubject = PulumiProgramCreator "aws-ses" "src/Prodbox/Infra/AwsSesStack.hs"
      , rowRelation = OffWriteAheadLane BarNoRegisteredKey
      , rowRunScopeTag = Just RunScopeTagWithheld
      , rowDestroy = [DestroyCite "src/Prodbox/Infra/AwsSesStack.hs" "destroyAwsSesStackWithAuthentication"]
      , rowReason =
          "The retained SES program is outside the lane on its own account: it has no registered resource key, \
          \the lane hard-codes the per-run surface and refuses a long-lived key, its reconcile is a series of \
          \idempotent provider intents on deterministic names rather than one stack create with one execute to \
          \bind a witness to, and no cascade ever targets it, so nothing would read a manifest for it. It also \
          \carries no run-scope tag, for a different reason: a per-run marker on the one stack nothing may reap \
          \would tell a per-run sweep that it belongs to the run being reaped. Joining the lane later would need \
          \a registry key and a long-lived manifest surface that has no reader today."
      }
  , keyRow
      AwsEbsProductionRetainedKey
      (OffWriteAheadLane BarKeyIsNotStack)
      [ DestroyCite
          "src/Prodbox/Lifecycle/Teardown/AwsRetainedEbsAdapter.hs"
          "authorizeExactAwsRetainedEbsReap"
      ]
      "Retained production volumes are a volume family, not a stack, so the per-run manifest intent refuses \
      \them by construction. The create is tagged at the moment it is made (the lifecycle tag is part of the \
      \create call), so there is no create-then-tag window for a record to close, and the cascade sweep carves \
      \them out by that tag. Destroy is the explicit long-lived or total-decommission reap only."
  , keyRow
      AwsDnsValidationZoneKey
      (OffWriteAheadLane BarKeyIsNotStack)
      [ DestroyCite
          "src/Prodbox/Lifecycle/Teardown/AwsRoute53ZoneAdapter.hs"
          "authorizeExactAwsValidationZoneReap"
      ]
      "The validation hosted zone is a zone family created by the DNS validation, not by a stack create. It is \
      \tagged by a second call straight after the create, with no retention marker, so there is a create-then-tag \
      \window: the sweep sees a leaked zone only once the tag has landed, and until then (or if the tag call \
      \fails) the zone is bounded by its name prefix and caller reference. Destroy is the exact zone reap."
  , keyRow
      HomeDns01ChallengeRecordKey
      (OffWriteAheadLane BarKeyIsNotStack)
      [ DestroyCite
          "src/Prodbox/Lifecycle/Teardown/Dns01ChallengeRecordAdapter.hs"
          "authorizeExactDns01ChallengeOwnerDelete"
      ]
      "Home cert-manager writes untaggable records into the retained parent zone. The durable run binds exact challenge names before validation; owner deletion and exact record read-back cover that family without deleting the parent zone."
  , keyRow
      SesInviteMailObjectsKey
      (OffWriteAheadLane BarKeyIsNotStack)
      [ DestroyCite
          "src/Prodbox/Lifecycle/Teardown/SesInviteMailAdapter.hs"
          "authorizeInviteMailCleanup"
      ]
      "SES writes untaggable data versions into the retained capture bucket. The durable run binds its exact validation recipient before delivery; complete version inventory and version-specific deletion preserve foreign mail and the bucket."
  , keyRow
      AwsDns01ChallengeRecordKey
      (OffWriteAheadLane BarKeyIsNotStack)
      [ DestroyCite
          "src/Prodbox/Lifecycle/Teardown/Dns01ChallengeRecordAdapter.hs"
          "authorizeExactDns01ChallengeOwnerDelete"
      ]
      "Challenge records are written by cert-manager's solver, not by prodbox, and a record set carries no tag \
      \and is invisible to the Tagging API. There is no owning stack and no edge by design. Deletion is by the \
      \Kubernetes owner and therefore needs a live cluster; this is a stated residual, not a recorded resource."
  , keyRow
      AwsEbsPerRunTestKey
      (DeclaredInStackManifest AwsEksKey)
      [DestroyCite "src/Prodbox/Lifecycle/Teardown/AwsEbsAdapter.hs" "authorizeExactAwsEbsReap"]
      "Per-run volumes are created by the cluster's CSI controller. The EKS stack's write-ahead manifest \
      \already declares the family, by key and registry coordinate digest, before any effect."
  , keyRow
      AwsEksIamRoleFamilyKey
      (DeclaredInStackManifest AwsEksKey)
      [ DestroyCite
          "src/Prodbox/Lifecycle/Teardown/AwsIamRoleFamilyAdapter.hs"
          "authorizeExactAwsIamRoleFamilyReap"
      ]
      "The cluster's IAM role family is declared in the EKS stack's write-ahead manifest by the same \
      \registry-derived edge. IAM is invisible to the regional Tagging API, so the family is named by role names."
  , keyRow
      AwsEksLoadBalancerControllerFamilyKey
      (DeclaredInStackManifest AwsEksKey)
      [ DestroyCite
          "src/Prodbox/Lifecycle/Teardown/AwsLoadBalancerControllerFamilyAdapter.hs"
          "authorizeExactAwsLoadBalancerControllerFamilyReap"
      ]
      "The load balancer controller's children are declared in the EKS stack's write-ahead manifest by family \
      \key and coordinate digest. The reap takes its name and tags from the registry coordinate, not from any \
      \member list, so an empty identity list loses nothing."
  , keyRow
      AwsEksVpcCniInterfacesKey
      (DeclaredInStackManifest AwsEksKey)
      [ DestroyCite
          "src/Prodbox/Lifecycle/Teardown/AwsNativeStackFamilyAdapter.hs"
          "authorizeExactAwsNetworkFamilyReap"
      ]
      "The stack declares this closed network family before any effect; member identities are not a manifest allowlist."
  , keyRow
      AwsTestVpcCniInterfacesKey
      (DeclaredInStackManifest AwsTestKey)
      [ DestroyCite
          "src/Prodbox/Lifecycle/Teardown/AwsNativeStackFamilyAdapter.hs"
          "authorizeExactAwsNetworkFamilyReap"
      ]
      "The stack declares this closed network family before any effect; member identities are not a manifest allowlist."
  , keyRow
      AwsEksClusterSecurityGroupsKey
      (DeclaredInStackManifest AwsEksKey)
      [ DestroyCite
          "src/Prodbox/Lifecycle/Teardown/AwsNativeStackFamilyAdapter.hs"
          "authorizeExactAwsNetworkFamilyReap"
      ]
      "The stack declares this closed network family before any effect; member identities are not a manifest allowlist."
  , keyRow
      AwsTestCanarySecurityGroupsKey
      (DeclaredInStackManifest AwsTestKey)
      [ DestroyCite
          "src/Prodbox/Lifecycle/Teardown/AwsNativeStackFamilyAdapter.hs"
          "authorizeExactAwsNetworkFamilyReap"
      ]
      "The test stack declares the canary's three exact security-group shapes before creation; \
      \its dedicated run markers and closed predicate authorize cleanup independently of the EKS group rule."
  , CreateRecordRow
      { rowSubject =
          NativeClientCreator "src/Prodbox/ControlPlane/ProviderProduction.hs" "testVpcCanaryMutation"
      , rowRelation = DeclaredInStackManifest AwsTestKey
      , rowRunScopeTag = Nothing
      , rowDestroy =
          [ DestroyCite
              "src/Prodbox/Lifecycle/Teardown/AwsNativeStackFamilyAdapter.hs"
              "authorizeExactAwsNetworkFamilyReap"
          ]
      , rowReason =
          "The fenced Provider's test-only interpreter plants one CNI-shaped interface and three exact groups. The test stack manifest declares both native families before creation; the harness requires the same targets in its registered body scope."
      }
  , CreateRecordRow
      { rowSubject =
          NativeClientCreator
            "src/Prodbox/Lifecycle/CredentialProvisioner/ProductionIam.hs"
            "ensureProductionIamPrerequisites"
      , rowRelation = OffWriteAheadLane BarNoRegisteredKey
      , rowRunScopeTag = Nothing
      , rowDestroy =
          [ DestroyCite
              "src/Prodbox/Lifecycle/CredentialProvisioner/ProductionIam.hs"
              "destroyProductionIamIdentity"
          ]
      , rowReason =
          "The production IAM principals are created by name through the native clients, with deterministic \
          \names from a closed program per credential class, outside the registered key universe, and the \
          \regional Tagging API cannot see IAM. The permit-bound admin execution journal is committed before \
          \the ensure runs. Destroy is the joint IAM disposition under its authorization."
      }
  ]
 where
  programRow directory infraModule key cites =
    CreateRecordRow
      { rowSubject = PulumiProgramCreator directory infraModule
      , rowRelation = OnWriteAheadLane key
      , rowRunScopeTag = Just RunScopeTagStamped
      , rowDestroy = cites
      , rowReason =
          "A registered per-run stack create: the write-ahead lane records what it is about to make, and the \
          \provider stamps the run scope on it."
      }
  keyRow key relation cites reason =
    CreateRecordRow
      { rowSubject = RegisteredKeyCreator key
      , rowRelation = relation
      , rowRunScopeTag = Nothing
      , rowDestroy = cites
      , rowReason = reason
      }

-- | The Pulumi program directories that make per-run resources, projected from
-- the table. A program is per-run exactly when it is on the lane.
perRunProgramDirectories :: [Text]
perRunProgramDirectories =
  [ directory
  | CreateRecordRow
      { rowSubject = PulumiProgramCreator directory _
      , rowRelation = OnWriteAheadLane _
      } <-
      createRecordCoverage
  ]

-- | The modules that create through the native AWS clients, projected from the
-- table.
nativeCreatorModules :: [FilePath]
nativeCreatorModules =
  [ modulePath
  | CreateRecordRow {rowSubject = NativeClientCreator modulePath _} <- createRecordCoverage
  ]
