{-# LANGUAGE OverloadedStrings #-}

-- | Non-authorizing inventory for the operational credential used by the
-- fenced Provider Worker.  This module records identity, consumers, and the
-- prerequisites that are still missing before ordinary teardown may revoke
-- the credential.  It deliberately exposes no observation, tombstone,
-- quiescence, terminal-audit, or Cascade evidence constructor.
module Prodbox.Lifecycle.Teardown.OperationalCredentialInventory
  ( OperationalCredentialInventory
  , operationalCredentialInventory
  , operationalCredentialInventoryClass
  , operationalCredentialInventoryPrincipal
  , operationalCredentialInventoryPolicy
  , operationalCredentialInventoryLifetime
  , operationalCredentialInventoryTarget
  , operationalCredentialInventoryPermissions
  , operationalCredentialInventoryMaximumAccessKeys
  , OperationalCredentialGenerationOwner (..)
  , operationalCredentialInventoryGenerationOwner
  , OperationalCredentialConsumer (..)
  , operationalCredentialConsumerForIntent
  , operationalCredentialInventoryConsumers
  , OperationalCredentialGraphConsumer (..)
  , operationalCredentialGraphConsumerTag
  , operationalCredentialInventoryGraphConsumers
  , OperationalCredentialDispositionBlocker (..)
  , operationalCredentialInventoryDispositionBlockers
  , DispositionBlockerEvidence (..)
  , dispositionBlockerEvidence
  , LegacyOperationalIdentity
  , legacyOperationalIdentity
  , legacyOperationalIdentityPrincipal
  , legacyOperationalIdentityPolicy
  , legacyOperationalIdentityResources
  , LegacyOperationalIdentityStatus (..)
  , legacyOperationalIdentityStatus
  , LegacyOperationalResource (..)
  , legacyOperationalResourceName
  , legacyOperationalResources
  , OperationalIdentityReplacement (..)
  , legacyOperationalResourceReplacement
  , retainedCustodyCredentialClasses
  )
where

import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , AwsCredentialDescriptor
  , CredentialLifetime (..)
  , CredentialPermission
  , CredentialTarget (..)
  , awsCredentialDescriptor
  , awsCredentialDescriptorClass
  , awsCredentialDescriptorLifetime
  , awsCredentialDescriptorMaximumAccessKeys
  , awsCredentialDescriptorPermissions
  , awsCredentialDescriptorPolicy
  , awsCredentialDescriptorPrincipal
  , awsCredentialDescriptorTarget
  , managedAwsCredentialInventory
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  )

-- | Exact, secret-free identity facts for the canonical Lifecycle-provider
-- credential.  The constructor is private: callers can inspect the canonical
-- inventory but cannot substitute a different credential descriptor.
data OperationalCredentialInventory = OperationalCredentialInventory
  { internalOperationalCredentialDescriptor :: !AwsCredentialDescriptor
  , internalOperationalCredentialGenerationOwner
      :: !OperationalCredentialGenerationOwner
  }
  deriving (Eq, Show)

-- | The durable system that owns allocation of the credential generation.
-- This is descriptive inventory only; it carries no generation value or
-- Authority admission capability.
data OperationalCredentialGenerationOwner
  = LifecycleAuthorityFirstReconcileJournal
  deriving (Bounded, Enum, Eq, Ord, Show)

operationalCredentialInventory :: OperationalCredentialInventory
operationalCredentialInventory =
  OperationalCredentialInventory
    { internalOperationalCredentialDescriptor =
        awsCredentialDescriptor LifecycleProviderCredential
    , internalOperationalCredentialGenerationOwner =
        LifecycleAuthorityFirstReconcileJournal
    }

operationalCredentialInventoryClass
  :: OperationalCredentialInventory -> AwsCredentialClass
operationalCredentialInventoryClass =
  awsCredentialDescriptorClass . internalOperationalCredentialDescriptor

operationalCredentialInventoryPrincipal
  :: OperationalCredentialInventory -> Text
operationalCredentialInventoryPrincipal =
  awsCredentialDescriptorPrincipal . internalOperationalCredentialDescriptor

operationalCredentialInventoryPolicy
  :: OperationalCredentialInventory -> Text
operationalCredentialInventoryPolicy =
  awsCredentialDescriptorPolicy . internalOperationalCredentialDescriptor

operationalCredentialInventoryLifetime
  :: OperationalCredentialInventory -> CredentialLifetime
operationalCredentialInventoryLifetime =
  awsCredentialDescriptorLifetime . internalOperationalCredentialDescriptor

operationalCredentialInventoryTarget
  :: OperationalCredentialInventory -> CredentialTarget
operationalCredentialInventoryTarget =
  awsCredentialDescriptorTarget . internalOperationalCredentialDescriptor

operationalCredentialInventoryPermissions
  :: OperationalCredentialInventory -> [CredentialPermission]
operationalCredentialInventoryPermissions =
  awsCredentialDescriptorPermissions . internalOperationalCredentialDescriptor

operationalCredentialInventoryMaximumAccessKeys
  :: OperationalCredentialInventory -> Natural
operationalCredentialInventoryMaximumAccessKeys =
  awsCredentialDescriptorMaximumAccessKeys
    . internalOperationalCredentialDescriptor

operationalCredentialInventoryGenerationOwner
  :: OperationalCredentialInventory -> OperationalCredentialGenerationOwner
operationalCredentialInventoryGenerationOwner =
  internalOperationalCredentialGenerationOwner

-- | Every closed Provider intent is a distinct consumer of the same sealed
-- Lifecycle-provider generation.  Keeping this one-for-one with
-- 'ProviderIntent' makes a newly added intent an exhaustiveness failure until
-- its credential dependency is classified deliberately.
data OperationalCredentialConsumer
  = RegisteredStackReconcileConsumer
  | RegisteredStackDestroyConsumer
  | RegisteredStackObserveConsumer
  | RegisteredStackReadBackConsumer
  | ScratchCheckpointConsumer
  | SesSendingIdentityConsumer
  | SesDkimConsumer
  | SesReceiptRulesConsumer
  | SesCaptureBucketConsumer
  | SesDnsConsumer
  | PublicARecordObserveConsumer
  | PublicARecordReconcileConsumer
  | TestEbsReapConsumer
  | SpotPriceObserveConsumer
  | OperationalIdentityObserveConsumer
  | ProviderReadinessObserveConsumer
  | EksClientAuthIssueConsumer
  | TestEbsObserveConsumer
  | EksClusterIdentityObserveConsumer
  | ProviderAwsScopeObserveConsumer
  deriving (Bounded, Enum, Eq, Ord, Show)

operationalCredentialConsumerForIntent
  :: ProviderIntent -> OperationalCredentialConsumer
operationalCredentialConsumerForIntent intent = case intent of
  ReconcileRegisteredStack {} -> RegisteredStackReconcileConsumer
  DestroyRegisteredStack {} -> RegisteredStackDestroyConsumer
  ObserveRegisteredStack {} -> RegisteredStackObserveConsumer
  ReadBackRegisteredStack {} -> RegisteredStackReadBackConsumer
  BoundedScratchCheckpoint {} -> ScratchCheckpointConsumer
  ReconcileSesSendingIdentity {} -> SesSendingIdentityConsumer
  ReconcileSesDkim {} -> SesDkimConsumer
  ReconcileSesReceiptRules {} -> SesReceiptRulesConsumer
  ReconcileSesCaptureBucket {} -> SesCaptureBucketConsumer
  ReconcileSesDns {} -> SesDnsConsumer
  ObservePublicARecord {} -> PublicARecordObserveConsumer
  ReconcilePublicARecord {} -> PublicARecordReconcileConsumer
  ReapTestEbsVolumes {} -> TestEbsReapConsumer
  ObserveSpotPrice {} -> SpotPriceObserveConsumer
  ObserveOperationalIdentity -> OperationalIdentityObserveConsumer
  ObserveProviderReadiness {} -> ProviderReadinessObserveConsumer
  IssueEksClientAuth {} -> EksClientAuthIssueConsumer
  ObserveTestEbsVolumes {} -> TestEbsObserveConsumer
  ObserveEksClusterIdentity {} -> EksClusterIdentityObserveConsumer
  ObserveProviderAwsScope -> ProviderAwsScopeObserveConsumer

operationalCredentialInventoryConsumers
  :: OperationalCredentialInventory -> [OperationalCredentialConsumer]
operationalCredentialInventoryConsumers _ = [minBound .. maxBound]

-- | Teardown graph operations whose current production interpreters may open
-- a Lifecycle-provider session.  These names are intentionally independent of
-- @Teardown.Program@: the Program integration
-- (@Teardown.OperationalCredentialCoverage@) consumes both without creating an
-- import cycle.  This list proves no node is terminal.
--
-- Sprint @4.84@ added the three checkpoint-tail entries. The list previously
-- stopped at 'ReconcileStackCheckpointRestoreCredentialConsumer', but
-- 'Prodbox.Lifecycle.Teardown.AwsCheckpointInterpreter' calls
-- @readBackAwsRegisteredTargetAbsent@ through the shared registered-target
-- interpreter in three further arms — recovery read-back, retirement, and
-- retirement read-back. Those are the *late* consumers, which is exactly what
-- an under-complete list gets wrong: the argument this inventory exists to
-- support is about when the credential may be disposed of, and that argument
-- turns on which consumer is last, not on how many there are.
--
-- The list is now joined to the compiled program by
-- 'Prodbox.Lifecycle.Teardown.OperationalCredentialCoverage', so it cannot
-- drift again silently.
data OperationalCredentialGraphConsumer
  = ObserveRegisteredTargetCredentialConsumer
  | ReconcileStackCheckpointRestoreCredentialConsumer
  | ReadBackStackCheckpointRecoveryCredentialConsumer
  | CommitEksDrainIntentCredentialConsumer
  | DrainEksKubernetesResourcesCredentialConsumer
  | ReadBackEksKubernetesDrainCredentialConsumer
  | ReconcileRegisteredTargetAbsentCredentialConsumer
  | ReadBackRegisteredTargetAbsentCredentialConsumer
  | RetireStackCheckpointPairCredentialConsumer
  | ReadBackStackCheckpointRetirementCredentialConsumer
  | -- | Sprint 4.85 (2026-08-18): the terminal escape audit itself.
    --
    -- This is the capability assignment @TerminalAuditProviderCapabilityUnassigned@
    -- named as missing.  An escape audit enumerates provider-side resources, so
    -- it cannot run without a Lifecycle-provider session — and until it was
    -- classified, the "credential must stay live /through/ the audit" ordering
    -- claim rested on an audit that, as far as this inventory was concerned,
    -- needed no credential at all.
    --
    -- The audit's executing adapter is Sprint @7.36@'s; this inventory makes no
    -- claim about it.  What is assigned here is the requirement that adapter has
    -- to satisfy, which is exactly what fixes the last consumer in the ordering.
    TerminalEscapeAuditCredentialConsumer
  deriving (Bounded, Enum, Eq, Ord, Show)

operationalCredentialGraphConsumerTag
  :: OperationalCredentialGraphConsumer -> Text
operationalCredentialGraphConsumerTag consumer = case consumer of
  ObserveRegisteredTargetCredentialConsumer -> "observe-registered-target"
  ReconcileStackCheckpointRestoreCredentialConsumer ->
    "reconcile-stack-checkpoint-restore"
  ReadBackStackCheckpointRecoveryCredentialConsumer ->
    "read-back-stack-checkpoint-recovery"
  CommitEksDrainIntentCredentialConsumer -> "commit-eks-drain-intent"
  DrainEksKubernetesResourcesCredentialConsumer ->
    "drain-eks-kubernetes-resources"
  ReadBackEksKubernetesDrainCredentialConsumer ->
    "read-back-eks-kubernetes-drain"
  ReconcileRegisteredTargetAbsentCredentialConsumer ->
    "reconcile-registered-target-absent"
  ReadBackRegisteredTargetAbsentCredentialConsumer ->
    "read-back-registered-target-absent"
  RetireStackCheckpointPairCredentialConsumer ->
    "retire-stack-checkpoint-pair"
  ReadBackStackCheckpointRetirementCredentialConsumer ->
    "read-back-stack-checkpoint-retirement"
  TerminalEscapeAuditCredentialConsumer -> "terminal-escape-audit"

operationalCredentialInventoryGraphConsumers
  :: OperationalCredentialInventory -> [OperationalCredentialGraphConsumer]
operationalCredentialInventoryGraphConsumers _ = [minBound .. maxBound]

-- | Typed reasons the inventory cannot yet become credential-disposition or
-- terminal-audit authority.  Both apparent revoke orders are explicitly
-- blocked: no compiled surface can express disposition after an audit, and the
-- one surface that would carry disposition has no audit at all, while the AWS
-- audit doctrine requires the credential to remain live through the audit.
--
-- A retired blocker keeps its constructor and its derivation.  The published
-- list is what the omission of the @Operational@ registry descriptors rests
-- on, and the coverage join fails in __both__ directions, so a blocker that
-- becomes true again is an unpublished-blocker failure rather than a silently
-- lost reason.
--
-- Sprint 4.85: this list is load-bearing — it is the stated reason
-- @OperationalTeardown@ has no registered descriptors and therefore no
-- completion minter — and it was authored by hand with no consumer but a unit
-- case asserting it equalled itself.  A blocker that stopped being true would
-- have gone on justifying the same omission.
-- 'dispositionBlockerEvidence' says how each one is established, and
-- 'Prodbox.Lifecycle.Teardown.OperationalCredentialCoverage' recomputes the
-- derivable ones from the compiled programs and this module\'s own values,
-- failing @prodbox dev check@ in both directions.
data OperationalCredentialDispositionBlocker
  = -- | Retired 2026-08-18: the total-decommission program orders every
    -- credential disposition strictly after its terminal audit, so the audit
    -- runs while the credential is still live.  Measured over the emitted
    -- dependency graph, so re-ordering the program re-establishes it.
    DispositionBeforeAuditConflictsWithLiveAuditCredential
  | -- | Retired 2026-08-18: total decommission owns both halves — a terminal
    -- escape audit and a credential disposition — so the audit-then-dispose
    -- order is expressible on one surface.  The name is historical: it was
    -- first measured against the cascade graph, which deliberately retains the
    -- credential and therefore never carried a disposition.
    AuditBeforeDispositionConflictsWithCurrentCascadeGraph
  | -- | Retired 2026-08-18: the terminal escape audit is classified as a
    -- Lifecycle-provider consumer, which is the capability assignment this
    -- blocker named.
    TerminalAuditProviderCapabilityUnassigned
  | -- | Retired 2026-08-18: an authenticated control route now issues the
    -- Cascade-audit freeze.  The constructor stays, and stays derivable, so
    -- deleting the route re-establishes the blocker rather than leaving it
    -- silently retired.
    GlobalProviderAdmissionFreezeUnavailable
  | -- | Retired 2026-08-18: a retained Provider operation carries the cleanup
    -- operation that authorized it, and the teardown dispatch path supplies
    -- one for every purpose.  Still derived, so a dispatch that stopped naming
    -- its cleanup operation re-establishes it.
    ProviderOperationCleanupRunOwnershipUnavailable
  | -- | Retired 2026-08-18: the compiled @OperationalTeardown@ program names a
    -- credential disposition and the mandatory read-back that confirms it, and
    -- the canonical revocation protocol exists at the fenced Admin-worker
    -- boundary.  Executing compiled nodes is the dispatcher activation Sprints
    -- @4.86@ and @6.5@ own, which every compiled node on every surface waits
    -- on equally; this blocker is about the path existing, not about that
    -- activation.  Still derived, so deleting either node re-establishes it.
    OrdinaryLifecycleProviderRevocationUnavailable
  | -- | Retired 2026-08-18: the canonical target revocation read-back decision
    -- exists and admits exactly one of its twelve observation pairs — both
    -- absences independently observed.  Still derived, so a protocol that
    -- drifted into accepting an unobservable or still-present target
    -- re-establishes it.
    CanonicalTargetRevocationReadBackUnavailable
  | -- | Retired 2026-08-18: every legacy operational resource names the
    -- supported surface that supersedes it.  Still derived, so an undeclared
    -- successor re-establishes it.
    LegacyOperationalIdentityReplacementUndefined
  deriving (Bounded, Enum, Eq, Ord, Show)

operationalCredentialInventoryDispositionBlockers
  :: OperationalCredentialInventory
  -> [OperationalCredentialDispositionBlocker]
operationalCredentialInventoryDispositionBlockers _ = []

-- | How one disposition blocker is established.
--
-- Every kind is a recomputation.  Sprint @4.85@ began with four blockers whose
-- evidence was a @TypeLevelAbsence@ — a \"no constructor exists\" fact that no
-- value could witness, and therefore one that would go on justifying an
-- omission after it stopped being true.  Each was closed by building the
-- missing capability and deriving the blocker from it, and the last of them
-- took the kind with it.
data DispositionBlockerEvidence
  = -- | Recomputed by compiling the teardown programs and inspecting their
    -- operations.
    DerivedFromCompiledTeardownPrograms
  | -- | Recomputed from 'teardownOperationCredentialConsumer', the classifier
    -- that already decides which operations open a Lifecycle-provider session.
    DerivedFromCredentialConsumerClassifier
  | -- | Recomputed from 'legacyOperationalIdentityStatus'.
    DerivedFromLegacyIdentityStatus
  | -- | Recomputed from the canonical target revocation read-back decision
    -- table in @Prodbox.Lifecycle.CredentialProvisioner.Execution@.
    DerivedFromRevocationReadBackProtocol
  | -- | Recomputed from the compiled @OperationalTeardown@ program: the
    -- ordinary revocation path is a credential disposition together with the
    -- mandatory read-back that confirms it.
    DerivedFromCompiledOrdinaryRevocationPath
  | -- | Recomputed from the teardown Provider dispatch key's cleanup
    -- ownership: every dispatch names the cleanup operation that authorized
    -- it, and the Authority retains that owner beside the intent.
    DerivedFromProviderDispatchOwnership
  | -- | Recomputed from the closed vocabulary of externally admissible
    -- Authority control routes
    -- ('Prodbox.Lifecycle.Authority.Admission.AuthorityControlRoute') and the
    -- aggregate command each one issues.
    DerivedFromAuthorityControlRoutes
  deriving (Eq, Show)

-- | Total over the closed blocker universe, so a new blocker cannot be added
-- without stating how it is established.
dispositionBlockerEvidence
  :: OperationalCredentialDispositionBlocker -> DispositionBlockerEvidence
dispositionBlockerEvidence blocker = case blocker of
  DispositionBeforeAuditConflictsWithLiveAuditCredential ->
    DerivedFromCompiledTeardownPrograms
  AuditBeforeDispositionConflictsWithCurrentCascadeGraph ->
    DerivedFromCompiledTeardownPrograms
  TerminalAuditProviderCapabilityUnassigned ->
    DerivedFromCredentialConsumerClassifier
  GlobalProviderAdmissionFreezeUnavailable ->
    DerivedFromAuthorityControlRoutes
  ProviderOperationCleanupRunOwnershipUnavailable ->
    DerivedFromProviderDispatchOwnership
  OrdinaryLifecycleProviderRevocationUnavailable ->
    DerivedFromCompiledOrdinaryRevocationPath
  CanonicalTargetRevocationReadBackUnavailable ->
    DerivedFromRevocationReadBackProtocol
  LegacyOperationalIdentityReplacementUndefined ->
    DerivedFromLegacyIdentityStatus

-- | Pre-cutover operational identity family.  It is deliberately a distinct
-- inventory object with no conversion to 'OperationalCredentialInventory'.
-- A migration must supply exact replacement/tombstone evidence before these
-- names can participate in credential disposition.
data LegacyOperationalIdentity = LegacyOperationalIdentity
  { internalLegacyOperationalIdentityPrincipal :: !Text
  , internalLegacyOperationalIdentityPolicy :: !Text
  , internalLegacyOperationalIdentityResources :: ![Text]
  , internalLegacyOperationalIdentityStatus :: !LegacyOperationalIdentityStatus
  }
  deriving (Eq, Show)

-- | The closed set of pre-cutover operational resources.
--
-- These names were a @[Text]@ field until 2026-08-18, which is why nothing
-- could say what supersedes one: a string has no place to carry a replacement.
-- The names are still exactly the @Operational@ rows of the flat lifecycle
-- inventory, and @prodbox dev check@ joins the two lists so neither can drift.
-- The join lives in @Prodbox.CheckCode@ rather than here: this module stays
-- free of the inventory's imports.
data LegacyOperationalResource
  = LegacyOperationalSesLeaseRole
  | LegacyOperationalIamUser
  | LegacyOperationalAwsConfigBlock
  deriving (Bounded, Enum, Eq, Ord, Show)

legacyOperationalResourceName :: LegacyOperationalResource -> Text
legacyOperationalResourceName resource = case resource of
  LegacyOperationalSesLeaseRole -> "operational-aws-ses-lease-role"
  LegacyOperationalIamUser -> "operational-iam-user"
  LegacyOperationalAwsConfigBlock -> "operational-aws-config"

legacyOperationalResources :: [LegacyOperationalResource]
legacyOperationalResources = [minBound .. maxBound]

-- | What supersedes one pre-cutover operational resource.
--
-- 'ReplacementUndeclared' is a real answer, not a placeholder: it is what makes
-- @LegacyOperationalIdentityReplacementUndefined@ a measurement.  A new legacy
-- resource is an exhaustiveness failure below until someone answers, and
-- answering @ReplacementUndeclared@ re-establishes the blocker rather than
-- quietly leaving it retired.
--
-- Declaring a replacement is not migrating to it.  This says which supported
-- surface owns the capability the legacy resource carried; revoking the legacy
-- identity and reading back its absence is separate work, tracked in the
-- deletion ledger.
data OperationalIdentityReplacement
  = -- | Superseded by a credential the typed registry manages.
    ReplacedByManagedCredential !AwsCredentialClass
  | -- | Superseded by generated, non-secret repository configuration rather
    -- than by any credential.
    ReplacedByGeneratedRepositoryConfiguration
  | -- | Nobody has said what supersedes this resource.
    ReplacementUndeclared
  deriving (Eq, Show)

-- | Total over the closed legacy set.
--
-- The legacy pair collapses into one managed credential: the @prodbox@ IAM user
-- becomes @prodbox-lifecycle-provider@, and the fixed session role that user
-- assumed for one SES lease transaction becomes the registered provider role
-- that credential's single 'AssumeRegisteredProviderRole' permission names.
-- The operational @aws.*@ config block has no successor credential at all — the
-- generated non-secret configuration carries what it carried.
legacyOperationalResourceReplacement
  :: LegacyOperationalResource -> OperationalIdentityReplacement
legacyOperationalResourceReplacement resource = case resource of
  LegacyOperationalSesLeaseRole ->
    ReplacedByManagedCredential LifecycleProviderCredential
  LegacyOperationalIamUser ->
    ReplacedByManagedCredential LifecycleProviderCredential
  LegacyOperationalAwsConfigBlock -> ReplacedByGeneratedRepositoryConfiguration

data LegacyOperationalIdentityStatus
  = -- | At least one legacy resource has no declared successor, so the legacy
    -- names cannot participate in credential disposition.
    LegacyOperationalIdentityMigrationRequired
  | -- | Every legacy resource names the supported surface that supersedes it.
    -- Executing the migration is separate; this is the definition the
    -- disposition argument needs.
    LegacyOperationalIdentityReplacementDeclared
  deriving (Bounded, Enum, Eq, Ord, Show)

legacyOperationalIdentity :: LegacyOperationalIdentity
legacyOperationalIdentity =
  LegacyOperationalIdentity
    { internalLegacyOperationalIdentityPrincipal = "prodbox"
    , internalLegacyOperationalIdentityPolicy = "prodbox-inline"
    , internalLegacyOperationalIdentityResources =
        map legacyOperationalResourceName legacyOperationalResources
    , internalLegacyOperationalIdentityStatus = derivedLegacyOperationalIdentityStatus
    }

-- | Derived, never authored: the identity is migration-required for exactly as
-- long as some legacy resource has no declared successor.
derivedLegacyOperationalIdentityStatus :: LegacyOperationalIdentityStatus
derivedLegacyOperationalIdentityStatus
  | any undeclared legacyOperationalResources =
      LegacyOperationalIdentityMigrationRequired
  | otherwise = LegacyOperationalIdentityReplacementDeclared
 where
  undeclared resource =
    legacyOperationalResourceReplacement resource == ReplacementUndeclared

legacyOperationalIdentityPrincipal :: LegacyOperationalIdentity -> Text
legacyOperationalIdentityPrincipal = internalLegacyOperationalIdentityPrincipal

legacyOperationalIdentityPolicy :: LegacyOperationalIdentity -> Text
legacyOperationalIdentityPolicy = internalLegacyOperationalIdentityPolicy

legacyOperationalIdentityResources :: LegacyOperationalIdentity -> [Text]
legacyOperationalIdentityResources = internalLegacyOperationalIdentityResources

legacyOperationalIdentityStatus
  :: LegacyOperationalIdentity -> LegacyOperationalIdentityStatus
legacyOperationalIdentityStatus = internalLegacyOperationalIdentityStatus

-- | Retained-custody identities are reported separately from the operational
-- inventory.  This classification comes from the closed credential registry,
-- never from AWS tags or discovered resource names.
retainedCustodyCredentialClasses :: [AwsCredentialClass]
retainedCustodyCredentialClasses =
  [ awsCredentialDescriptorClass descriptor
  | descriptor <- managedAwsCredentialInventory
  , awsCredentialDescriptorLifetime descriptor == RetainedCustodyCredential
  ]
