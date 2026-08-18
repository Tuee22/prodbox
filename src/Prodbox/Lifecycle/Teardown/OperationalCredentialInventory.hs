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
  , AbsentDispositionCapability (..)
  , dispositionBlockerEvidence
  , absentDispositionCapabilityDetail
  , LegacyOperationalIdentity
  , legacyOperationalIdentity
  , legacyOperationalIdentityPrincipal
  , legacyOperationalIdentityPolicy
  , legacyOperationalIdentityResources
  , LegacyOperationalIdentityStatus (..)
  , legacyOperationalIdentityStatus
  , retainedCustodyCredentialClasses
  )
where

import Data.List.NonEmpty (NonEmpty (..))
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

operationalCredentialInventoryGraphConsumers
  :: OperationalCredentialInventory -> [OperationalCredentialGraphConsumer]
operationalCredentialInventoryGraphConsumers _ = [minBound .. maxBound]

-- | Typed reasons the inventory cannot yet become credential-disposition or
-- terminal-audit authority.  Both apparent revoke orders are explicitly
-- blocked: no compiled surface can express disposition after an audit, and the
-- one surface that would carry disposition has no audit at all, while the AWS
-- audit doctrine requires the credential to remain live through the audit.
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
  = DispositionBeforeAuditConflictsWithLiveAuditCredential
  | AuditBeforeDispositionConflictsWithCurrentCascadeGraph
  | TerminalAuditProviderCapabilityUnassigned
  | GlobalProviderAdmissionFreezeUnavailable
  | ProviderOperationCleanupRunOwnershipUnavailable
  | OrdinaryLifecycleProviderRevocationUnavailable
  | CanonicalTargetRevocationReadBackUnavailable
  | LegacyOperationalIdentityReplacementUndefined
  deriving (Bounded, Enum, Eq, Ord, Show)

operationalCredentialInventoryDispositionBlockers
  :: OperationalCredentialInventory
  -> NonEmpty OperationalCredentialDispositionBlocker
operationalCredentialInventoryDispositionBlockers _ =
  DispositionBeforeAuditConflictsWithLiveAuditCredential
    :| [ AuditBeforeDispositionConflictsWithCurrentCascadeGraph
       , TerminalAuditProviderCapabilityUnassigned
       , GlobalProviderAdmissionFreezeUnavailable
       , ProviderOperationCleanupRunOwnershipUnavailable
       , OrdinaryLifecycleProviderRevocationUnavailable
       , CanonicalTargetRevocationReadBackUnavailable
       , LegacyOperationalIdentityReplacementUndefined
       ]

-- | How one disposition blocker is established.
--
-- The distinction is the point.  A blocker derived from a compiled program or
-- from a value in this repository stops being true the moment the source
-- changes, and the coverage join notices.  A blocker that rests on a
-- \"no constructor exists\" fact cannot be recomputed from a value at all, so it
-- is marked as such and names the missing capability rather than pretending to
-- be measured.
data DispositionBlockerEvidence
  = -- | Recomputed by compiling the teardown programs and inspecting their
    -- operations.
    DerivedFromCompiledTeardownPrograms
  | -- | Recomputed from 'teardownOperationCredentialConsumer', the classifier
    -- that already decides which operations open a Lifecycle-provider session.
    DerivedFromCredentialConsumerClassifier
  | -- | Recomputed from 'legacyOperationalIdentityStatus'.
    DerivedFromLegacyIdentityStatus
  | -- | Rests on the absence of a constructor or transition, which no value in
    -- this repository can witness.
    TypeLevelAbsence !AbsentDispositionCapability
  deriving (Eq, Show)

-- | The capabilities whose absence a non-derivable blocker rests on.  Each
-- names the exact missing transition or protocol, so implementing one is a
-- deliberate act rather than a silent invalidation of the blocker beside it.
data AbsentDispositionCapability
  = -- | The Cascade-audit freeze exists as a pure aggregate command, and the
    -- submission gate already honours its reservation — but no authenticated
    -- route issues that command, so no production caller can fence admission.
    ProviderAdmissionFreezeRouteAbsent
  | -- | No Provider operation is owned by a cleanup run, so a disposition
    -- cannot be attributed to the run that authorized it.
    ProviderOperationCleanupRunOwnershipAbsent
  | -- | No ordinary lifecycle path revokes the Lifecycle-provider credential.
    LifecycleProviderRevocationAbsent
  | -- | No canonical target revocation read-back protocol exists, so a revoke
    -- response could not be independently confirmed.
    CanonicalTargetRevocationReadBackAbsent
  deriving (Bounded, Enum, Eq, Ord, Show)

absentDispositionCapabilityDetail :: AbsentDispositionCapability -> Text
absentDispositionCapabilityDetail capability = case capability of
  ProviderAdmissionFreezeRouteAbsent ->
    "no authenticated route issues the Cascade-audit freeze command, so no \
    \production caller can fence Provider admission"
  ProviderOperationCleanupRunOwnershipAbsent ->
    "no Provider operation is owned by a cleanup run"
  LifecycleProviderRevocationAbsent ->
    "no ordinary lifecycle path revokes the Lifecycle-provider credential"
  CanonicalTargetRevocationReadBackAbsent ->
    "no canonical target revocation read-back protocol exists"

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
    TypeLevelAbsence ProviderAdmissionFreezeRouteAbsent
  ProviderOperationCleanupRunOwnershipUnavailable ->
    TypeLevelAbsence ProviderOperationCleanupRunOwnershipAbsent
  OrdinaryLifecycleProviderRevocationUnavailable ->
    TypeLevelAbsence LifecycleProviderRevocationAbsent
  CanonicalTargetRevocationReadBackUnavailable ->
    TypeLevelAbsence CanonicalTargetRevocationReadBackAbsent
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

data LegacyOperationalIdentityStatus
  = LegacyOperationalIdentityMigrationRequired
  deriving (Bounded, Enum, Eq, Ord, Show)

legacyOperationalIdentity :: LegacyOperationalIdentity
legacyOperationalIdentity =
  LegacyOperationalIdentity
    { internalLegacyOperationalIdentityPrincipal = "prodbox"
    , internalLegacyOperationalIdentityPolicy = "prodbox-inline"
    , internalLegacyOperationalIdentityResources =
        [ "operational-aws-ses-lease-role"
        , "operational-iam-user"
        , "operational-aws-config"
        ]
    , internalLegacyOperationalIdentityStatus =
        LegacyOperationalIdentityMigrationRequired
    }

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
