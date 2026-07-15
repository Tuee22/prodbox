{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}

-- | Sprint 1.61: the exhaustive, promoted operation universe for the
-- operation-indexed capability algebra. Every capability reference, program,
-- observation, admission ticket, writer permit, and committed intent is indexed
-- by one 'CapabilityKind', so an authority that observes one operation can never
-- drive a different operation. There is deliberately NO generic transport escape
-- kind.
--
-- Each kind belongs to exactly one permit tier, and that tier is what makes
-- weaker-capability substitution unrepresentable: an observe-only kind has no
-- mutation program, an internal-CAS kind needs a 'Prodbox.ControlPlane.Permit.WriterPermit',
-- and an external-intent kind needs a signed committed intent. The type-level
-- marker classes ('MutatingKind'/'InternalCasKind'/'ExternalIntentKind') gate the
-- mutation program constructors at compile time; the value-level classifiers
-- ('permitTier'/'isMutating'/'requiresRoundTripEvidence') are the behavioural
-- SSoT the readiness classifier and the (deferred) graph lowering consume. The
-- field set and rules mirror
-- [lifecycle_control_plane_architecture.md](../../../documents/engineering/lifecycle_control_plane_architecture.md)
-- and [bootstrap_readiness_doctrine.md](../../../documents/engineering/bootstrap_readiness_doctrine.md).
module Prodbox.ControlPlane.CapabilityKind
  ( -- * The promoted operation universe
    CapabilityKind (..)
  , CapabilityOp (..)

    -- * Type-level reflection and mutation gating
  , KnownCapability (..)
  , MutatingKind
  , InternalCasKind
  , ExternalIntentKind

    -- * Value-level classifiers (behavioural SSoT)
  , PermitTier (..)
  , permitTier
  , isMutating
  , requiresRoundTripEvidence
  )
where

-- | The exhaustive operation universe, grouped by permit tier. Sub-verbs the
-- doctrine bundles are split so each verb owns its own tier.
data CapabilityKind
  = -- TierObserveOnly: read/availability operations. No mutation program may
    -- target these.
    ProcessAvailability
  | WorkloadAvailability
  | OperatorAvailability
  | VaultBaseline
  | VaultPki
  | GatewayFrontDoor
  | LifecycleObserve
  | ConfigObserve
  | TargetObserve
  | ProviderReadBack
  | AuthorityBackupReadBack
  | ManagedObserve
  | ManagedReadBack
  | -- TierInternalCas: internal authority compare-and-swap operations. Gated by
    -- a 'Prodbox.ControlPlane.Permit.WriterPermit'.
    LifecycleCas
  | LifecycleSubmit
  | LifecycleCancel
  | ConfigProposeCas
  | TargetCas
  | AuthorityEpochCutover
  | AuthorityBackupCommit
  | GatewayContinuityCommit
  | -- TierExternalIntent: external mutations. Gated by a signed
    -- 'Prodbox.ControlPlane.Permit.CommittedIntent'.
    VaultBootstrap
  | ProviderApply
  | TargetSeal
  | GatewayDns
  | GatewayEmitterRetire
  | GatewayPeerHandshake
  | RegistryPublication
  | OperatorMaterialSubmit
  | AdminAction
  | CredentialProvision
  | ChildCustodyDelivery
  | DecommissionExport
  | AuthorityBackupEstablish
  | TlsSecretMaterialize
  | TlsDekExchange
  | TlsRetentionStore
  | ManagedEnsure
  | ManagedDestroy
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The value-level mirror of 'CapabilityKind' (same constructors, @Op@-prefixed).
-- 'Enum'/'Bounded' give the exhaustive @[minBound .. maxBound]@ the consistency
-- test enumerates.
data CapabilityOp
  = OpProcessAvailability
  | OpWorkloadAvailability
  | OpOperatorAvailability
  | OpVaultBaseline
  | OpVaultPki
  | OpGatewayFrontDoor
  | OpLifecycleObserve
  | OpConfigObserve
  | OpTargetObserve
  | OpProviderReadBack
  | OpAuthorityBackupReadBack
  | OpManagedObserve
  | OpManagedReadBack
  | OpLifecycleCas
  | OpLifecycleSubmit
  | OpLifecycleCancel
  | OpConfigProposeCas
  | OpTargetCas
  | OpAuthorityEpochCutover
  | OpAuthorityBackupCommit
  | OpGatewayContinuityCommit
  | OpVaultBootstrap
  | OpProviderApply
  | OpTargetSeal
  | OpGatewayDns
  | OpGatewayEmitterRetire
  | OpGatewayPeerHandshake
  | OpRegistryPublication
  | OpOperatorMaterialSubmit
  | OpAdminAction
  | OpCredentialProvision
  | OpChildCustodyDelivery
  | OpDecommissionExport
  | OpAuthorityBackupEstablish
  | OpTlsSecretMaterialize
  | OpTlsDekExchange
  | OpTlsRetentionStore
  | OpManagedEnsure
  | OpManagedDestroy
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The one reflection from a statically-known kind to its value-level operation.
-- No singleton is needed: @k@ is always statically known where a reference or
-- program is built, so we never recover a type from a value.
class KnownCapability (k :: CapabilityKind) where
  capabilityOp :: CapabilityOp

instance KnownCapability 'ProcessAvailability where capabilityOp = OpProcessAvailability
instance KnownCapability 'WorkloadAvailability where capabilityOp = OpWorkloadAvailability
instance KnownCapability 'OperatorAvailability where capabilityOp = OpOperatorAvailability
instance KnownCapability 'VaultBaseline where capabilityOp = OpVaultBaseline
instance KnownCapability 'VaultPki where capabilityOp = OpVaultPki
instance KnownCapability 'GatewayFrontDoor where capabilityOp = OpGatewayFrontDoor
instance KnownCapability 'LifecycleObserve where capabilityOp = OpLifecycleObserve
instance KnownCapability 'ConfigObserve where capabilityOp = OpConfigObserve
instance KnownCapability 'TargetObserve where capabilityOp = OpTargetObserve
instance KnownCapability 'ProviderReadBack where capabilityOp = OpProviderReadBack
instance KnownCapability 'AuthorityBackupReadBack where capabilityOp = OpAuthorityBackupReadBack
instance KnownCapability 'ManagedObserve where capabilityOp = OpManagedObserve
instance KnownCapability 'ManagedReadBack where capabilityOp = OpManagedReadBack
instance KnownCapability 'LifecycleCas where capabilityOp = OpLifecycleCas
instance KnownCapability 'LifecycleSubmit where capabilityOp = OpLifecycleSubmit
instance KnownCapability 'LifecycleCancel where capabilityOp = OpLifecycleCancel
instance KnownCapability 'ConfigProposeCas where capabilityOp = OpConfigProposeCas
instance KnownCapability 'TargetCas where capabilityOp = OpTargetCas
instance KnownCapability 'AuthorityEpochCutover where capabilityOp = OpAuthorityEpochCutover
instance KnownCapability 'AuthorityBackupCommit where capabilityOp = OpAuthorityBackupCommit
instance KnownCapability 'GatewayContinuityCommit where capabilityOp = OpGatewayContinuityCommit
instance KnownCapability 'VaultBootstrap where capabilityOp = OpVaultBootstrap
instance KnownCapability 'ProviderApply where capabilityOp = OpProviderApply
instance KnownCapability 'TargetSeal where capabilityOp = OpTargetSeal
instance KnownCapability 'GatewayDns where capabilityOp = OpGatewayDns
instance KnownCapability 'GatewayEmitterRetire where capabilityOp = OpGatewayEmitterRetire
instance KnownCapability 'GatewayPeerHandshake where capabilityOp = OpGatewayPeerHandshake
instance KnownCapability 'RegistryPublication where capabilityOp = OpRegistryPublication
instance KnownCapability 'OperatorMaterialSubmit where capabilityOp = OpOperatorMaterialSubmit
instance KnownCapability 'AdminAction where capabilityOp = OpAdminAction
instance KnownCapability 'CredentialProvision where capabilityOp = OpCredentialProvision
instance KnownCapability 'ChildCustodyDelivery where capabilityOp = OpChildCustodyDelivery
instance KnownCapability 'DecommissionExport where capabilityOp = OpDecommissionExport
instance KnownCapability 'AuthorityBackupEstablish where capabilityOp = OpAuthorityBackupEstablish
instance KnownCapability 'TlsSecretMaterialize where capabilityOp = OpTlsSecretMaterialize
instance KnownCapability 'TlsDekExchange where capabilityOp = OpTlsDekExchange
instance KnownCapability 'TlsRetentionStore where capabilityOp = OpTlsRetentionStore
instance KnownCapability 'ManagedEnsure where capabilityOp = OpManagedEnsure
instance KnownCapability 'ManagedDestroy where capabilityOp = OpManagedDestroy

-- | A kind that mutates external or internal state. The instance set is closed
-- (defined only here, not exported for extension), so a read/availability kind
-- can never be used where a mutation is required.
class (KnownCapability k) => MutatingKind (k :: CapabilityKind)

-- | A mutation gated by an opaque writer permit (internal authority CAS).
class (MutatingKind k) => InternalCasKind (k :: CapabilityKind)

-- | A mutation gated by a signed committed intent (external effect).
class (MutatingKind k) => ExternalIntentKind (k :: CapabilityKind)

instance MutatingKind 'LifecycleCas
instance MutatingKind 'LifecycleSubmit
instance MutatingKind 'LifecycleCancel
instance MutatingKind 'ConfigProposeCas
instance MutatingKind 'TargetCas
instance MutatingKind 'AuthorityEpochCutover
instance MutatingKind 'AuthorityBackupCommit
instance MutatingKind 'GatewayContinuityCommit
instance MutatingKind 'VaultBootstrap
instance MutatingKind 'ProviderApply
instance MutatingKind 'TargetSeal
instance MutatingKind 'GatewayDns
instance MutatingKind 'GatewayEmitterRetire
instance MutatingKind 'GatewayPeerHandshake
instance MutatingKind 'RegistryPublication
instance MutatingKind 'OperatorMaterialSubmit
instance MutatingKind 'AdminAction
instance MutatingKind 'CredentialProvision
instance MutatingKind 'ChildCustodyDelivery
instance MutatingKind 'DecommissionExport
instance MutatingKind 'AuthorityBackupEstablish
instance MutatingKind 'TlsSecretMaterialize
instance MutatingKind 'TlsDekExchange
instance MutatingKind 'TlsRetentionStore
instance MutatingKind 'ManagedEnsure
instance MutatingKind 'ManagedDestroy

instance InternalCasKind 'LifecycleCas
instance InternalCasKind 'LifecycleSubmit
instance InternalCasKind 'LifecycleCancel
instance InternalCasKind 'ConfigProposeCas
instance InternalCasKind 'TargetCas
instance InternalCasKind 'AuthorityEpochCutover
instance InternalCasKind 'AuthorityBackupCommit
instance InternalCasKind 'GatewayContinuityCommit

instance ExternalIntentKind 'VaultBootstrap
instance ExternalIntentKind 'ProviderApply
instance ExternalIntentKind 'TargetSeal
instance ExternalIntentKind 'GatewayDns
instance ExternalIntentKind 'GatewayEmitterRetire
instance ExternalIntentKind 'GatewayPeerHandshake
instance ExternalIntentKind 'RegistryPublication
instance ExternalIntentKind 'OperatorMaterialSubmit
instance ExternalIntentKind 'AdminAction
instance ExternalIntentKind 'CredentialProvision
instance ExternalIntentKind 'ChildCustodyDelivery
instance ExternalIntentKind 'DecommissionExport
instance ExternalIntentKind 'AuthorityBackupEstablish
instance ExternalIntentKind 'TlsSecretMaterialize
instance ExternalIntentKind 'TlsDekExchange
instance ExternalIntentKind 'TlsRetentionStore
instance ExternalIntentKind 'ManagedEnsure
instance ExternalIntentKind 'ManagedDestroy

-- | The permit tier of an operation — the value-level SSoT the type-level marker
-- classes above mirror (the consistency test pins their agreement).
data PermitTier
  = TierObserveOnly
  | TierInternalCas
  | TierExternalIntent
  deriving (Eq, Show)

permitTier :: CapabilityOp -> PermitTier
permitTier op = case op of
  OpProcessAvailability -> TierObserveOnly
  OpWorkloadAvailability -> TierObserveOnly
  OpOperatorAvailability -> TierObserveOnly
  OpVaultBaseline -> TierObserveOnly
  OpVaultPki -> TierObserveOnly
  OpGatewayFrontDoor -> TierObserveOnly
  OpLifecycleObserve -> TierObserveOnly
  OpConfigObserve -> TierObserveOnly
  OpTargetObserve -> TierObserveOnly
  OpProviderReadBack -> TierObserveOnly
  OpAuthorityBackupReadBack -> TierObserveOnly
  OpManagedObserve -> TierObserveOnly
  OpManagedReadBack -> TierObserveOnly
  OpLifecycleCas -> TierInternalCas
  OpLifecycleSubmit -> TierInternalCas
  OpLifecycleCancel -> TierInternalCas
  OpConfigProposeCas -> TierInternalCas
  OpTargetCas -> TierInternalCas
  OpAuthorityEpochCutover -> TierInternalCas
  OpAuthorityBackupCommit -> TierInternalCas
  OpGatewayContinuityCommit -> TierInternalCas
  OpVaultBootstrap -> TierExternalIntent
  OpProviderApply -> TierExternalIntent
  OpTargetSeal -> TierExternalIntent
  OpGatewayDns -> TierExternalIntent
  OpGatewayEmitterRetire -> TierExternalIntent
  OpGatewayPeerHandshake -> TierExternalIntent
  OpRegistryPublication -> TierExternalIntent
  OpOperatorMaterialSubmit -> TierExternalIntent
  OpAdminAction -> TierExternalIntent
  OpCredentialProvision -> TierExternalIntent
  OpChildCustodyDelivery -> TierExternalIntent
  OpDecommissionExport -> TierExternalIntent
  OpAuthorityBackupEstablish -> TierExternalIntent
  OpTlsSecretMaterialize -> TierExternalIntent
  OpTlsDekExchange -> TierExternalIntent
  OpTlsRetentionStore -> TierExternalIntent
  OpManagedEnsure -> TierExternalIntent
  OpManagedDestroy -> TierExternalIntent

-- | Whether an operation mutates state (any non-observe tier).
isMutating :: CapabilityOp -> Bool
isMutating op = permitTier op /= TierObserveOnly

-- | Whether an operation requires a proven write/CAS round trip as its readiness
-- evidence (a bare present-object GET can never satisfy it). Every mutating
-- operation does; the invariant the classifier relies on is only that
-- @requiresRoundTripEvidence op ==> isMutating op@.
requiresRoundTripEvidence :: CapabilityOp -> Bool
requiresRoundTripEvidence = isMutating
