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
-- @Teardown.Program@: the future Program integration may consume this module
-- without creating an import cycle.  This list proves no node is terminal.
data OperationalCredentialGraphConsumer
  = ObserveRegisteredTargetCredentialConsumer
  | ReconcileStackCheckpointRestoreCredentialConsumer
  | CommitEksDrainIntentCredentialConsumer
  | DrainEksKubernetesResourcesCredentialConsumer
  | ReadBackEksKubernetesDrainCredentialConsumer
  | ReconcileRegisteredTargetAbsentCredentialConsumer
  | ReadBackRegisteredTargetAbsentCredentialConsumer
  deriving (Bounded, Enum, Eq, Ord, Show)

operationalCredentialGraphConsumerTag
  :: OperationalCredentialGraphConsumer -> Text
operationalCredentialGraphConsumerTag consumer = case consumer of
  ObserveRegisteredTargetCredentialConsumer -> "observe-registered-target"
  ReconcileStackCheckpointRestoreCredentialConsumer ->
    "reconcile-stack-checkpoint-restore"
  CommitEksDrainIntentCredentialConsumer -> "commit-eks-drain-intent"
  DrainEksKubernetesResourcesCredentialConsumer ->
    "drain-eks-kubernetes-resources"
  ReadBackEksKubernetesDrainCredentialConsumer ->
    "read-back-eks-kubernetes-drain"
  ReconcileRegisteredTargetAbsentCredentialConsumer ->
    "reconcile-registered-target-absent"
  ReadBackRegisteredTargetAbsentCredentialConsumer ->
    "read-back-registered-target-absent"

operationalCredentialInventoryGraphConsumers
  :: OperationalCredentialInventory -> [OperationalCredentialGraphConsumer]
operationalCredentialInventoryGraphConsumers _ = [minBound .. maxBound]

-- | Typed reasons the inventory cannot yet become credential-disposition or
-- terminal-audit authority.  Both apparent revoke orders are explicitly
-- blocked: the current graph asks for disposition before audit, while the AWS
-- audit doctrine requires its credential to remain live through the audit.
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
