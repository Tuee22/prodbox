{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

-- | Sprint 1.61 Increment B: a runtime singleton for the 'CapabilityKind'
-- universe.
--
-- Increment A deliberately shipped only the 'KnownCapability' class (statically
-- known kinds; "no singleton is needed") because it never recovered a type from
-- a value. Lowering the component graph over capabilities changes that: a
-- capability requirement is existentially wrapped ('SomeCapabilityRequirement'),
-- so the kind must be recoverable at runtime to resolve the requirement into an
-- opaque 'Prodbox.ControlPlane.CapabilityRef.CapabilityRef' via
-- 'Prodbox.ControlPlane.CapabilityRef.mkCapabilityRef' (which needs a
-- 'KnownCapability' dictionary). 'withKnownCapability' re-provides exactly that
-- dictionary from the singleton, so the graph never smuggles a coordinate for one
-- operation into another.
--
-- The singleton is a third listing of the ~39 kinds beside 'CapabilityKind' and
-- 'CapabilityOp'; their agreement is pinned by an exhaustive consistency test.
module Prodbox.ControlPlane.SCapability
  ( SCapability (..)
  , SomeSCapability (..)
  , sCapabilityOp
  , sCapabilityTier
  , opToSCapability
  , withKnownCapability
  )
where

import Prodbox.ControlPlane.CapabilityKind
  ( CapabilityKind (..)
  , CapabilityOp (..)
  , KnownCapability
  , PermitTier
  , permitTier
  )

-- | A value-level witness of a statically-unknown 'CapabilityKind'. One
-- constructor per kind; matching a constructor refines @k@ and brings its
-- 'KnownCapability' instance into scope.
data SCapability (k :: CapabilityKind) where
  SProcessAvailability :: SCapability 'ProcessAvailability
  SWorkloadAvailability :: SCapability 'WorkloadAvailability
  SOperatorAvailability :: SCapability 'OperatorAvailability
  SVaultBootstrapObserve :: SCapability 'VaultBootstrapObserve
  SGatewayFrontDoor :: SCapability 'GatewayFrontDoor
  SLifecycleObserve :: SCapability 'LifecycleObserve
  SConfigObserve :: SCapability 'ConfigObserve
  STargetObserve :: SCapability 'TargetObserve
  SProviderReadBack :: SCapability 'ProviderReadBack
  SAuthorityBackupReadBack :: SCapability 'AuthorityBackupReadBack
  SManagedObserve :: SCapability 'ManagedObserve
  SManagedReadBack :: SCapability 'ManagedReadBack
  SLifecycleCas :: SCapability 'LifecycleCas
  SLifecycleSubmit :: SCapability 'LifecycleSubmit
  SLifecycleCancel :: SCapability 'LifecycleCancel
  SConfigProposeCas :: SCapability 'ConfigProposeCas
  STargetCas :: SCapability 'TargetCas
  SAuthorityEpochCutover :: SCapability 'AuthorityEpochCutover
  SAuthorityBackupCommit :: SCapability 'AuthorityBackupCommit
  SGatewayContinuityCommit :: SCapability 'GatewayContinuityCommit
  SVaultBootstrapMutate :: SCapability 'VaultBootstrapMutate
  SVaultBaselineReconcile :: SCapability 'VaultBaselineReconcile
  SVaultPkiOperate :: SCapability 'VaultPkiOperate
  SProviderApply :: SCapability 'ProviderApply
  STargetSeal :: SCapability 'TargetSeal
  SGatewayDns :: SCapability 'GatewayDns
  SGatewayEmitterRetire :: SCapability 'GatewayEmitterRetire
  SGatewayPeerHandshake :: SCapability 'GatewayPeerHandshake
  SRegistryPublication :: SCapability 'RegistryPublication
  SOperatorMaterialSubmit :: SCapability 'OperatorMaterialSubmit
  SAdminAction :: SCapability 'AdminAction
  SCredentialProvision :: SCapability 'CredentialProvision
  SChildCustodyDelivery :: SCapability 'ChildCustodyDelivery
  SDecommissionExport :: SCapability 'DecommissionExport
  SAuthorityBackupEstablish :: SCapability 'AuthorityBackupEstablish
  STlsSecretMaterialize :: SCapability 'TlsSecretMaterialize
  STlsDekExchange :: SCapability 'TlsDekExchange
  STlsRetentionStore :: SCapability 'TlsRetentionStore
  SManagedEnsure :: SCapability 'ManagedEnsure
  SManagedDestroy :: SCapability 'ManagedDestroy

-- | An existentially wrapped singleton, produced by 'opToSCapability' when the
-- kind is only known at runtime.
data SomeSCapability where
  SomeSCapability :: SCapability k -> SomeSCapability

-- | The value-level operation a singleton witnesses.
sCapabilityOp :: SCapability k -> CapabilityOp
sCapabilityOp singleton = case singleton of
  SProcessAvailability -> OpProcessAvailability
  SWorkloadAvailability -> OpWorkloadAvailability
  SOperatorAvailability -> OpOperatorAvailability
  SVaultBootstrapObserve -> OpVaultBootstrapObserve
  SGatewayFrontDoor -> OpGatewayFrontDoor
  SLifecycleObserve -> OpLifecycleObserve
  SConfigObserve -> OpConfigObserve
  STargetObserve -> OpTargetObserve
  SProviderReadBack -> OpProviderReadBack
  SAuthorityBackupReadBack -> OpAuthorityBackupReadBack
  SManagedObserve -> OpManagedObserve
  SManagedReadBack -> OpManagedReadBack
  SLifecycleCas -> OpLifecycleCas
  SLifecycleSubmit -> OpLifecycleSubmit
  SLifecycleCancel -> OpLifecycleCancel
  SConfigProposeCas -> OpConfigProposeCas
  STargetCas -> OpTargetCas
  SAuthorityEpochCutover -> OpAuthorityEpochCutover
  SAuthorityBackupCommit -> OpAuthorityBackupCommit
  SGatewayContinuityCommit -> OpGatewayContinuityCommit
  SVaultBootstrapMutate -> OpVaultBootstrapMutate
  SVaultBaselineReconcile -> OpVaultBaselineReconcile
  SVaultPkiOperate -> OpVaultPkiOperate
  SProviderApply -> OpProviderApply
  STargetSeal -> OpTargetSeal
  SGatewayDns -> OpGatewayDns
  SGatewayEmitterRetire -> OpGatewayEmitterRetire
  SGatewayPeerHandshake -> OpGatewayPeerHandshake
  SRegistryPublication -> OpRegistryPublication
  SOperatorMaterialSubmit -> OpOperatorMaterialSubmit
  SAdminAction -> OpAdminAction
  SCredentialProvision -> OpCredentialProvision
  SChildCustodyDelivery -> OpChildCustodyDelivery
  SDecommissionExport -> OpDecommissionExport
  SAuthorityBackupEstablish -> OpAuthorityBackupEstablish
  STlsSecretMaterialize -> OpTlsSecretMaterialize
  STlsDekExchange -> OpTlsDekExchange
  STlsRetentionStore -> OpTlsRetentionStore
  SManagedEnsure -> OpManagedEnsure
  SManagedDestroy -> OpManagedDestroy

-- | The permit tier of a singleton, reusing the 'CapabilityKind' behavioural
-- SSoT — no second source of truth to drift.
sCapabilityTier :: SCapability k -> PermitTier
sCapabilityTier = permitTier . sCapabilityOp

-- | Recover the singleton (and thus the type-level kind) from a runtime
-- operation value.
opToSCapability :: CapabilityOp -> SomeSCapability
opToSCapability op = case op of
  OpProcessAvailability -> SomeSCapability SProcessAvailability
  OpWorkloadAvailability -> SomeSCapability SWorkloadAvailability
  OpOperatorAvailability -> SomeSCapability SOperatorAvailability
  OpVaultBootstrapObserve -> SomeSCapability SVaultBootstrapObserve
  OpGatewayFrontDoor -> SomeSCapability SGatewayFrontDoor
  OpLifecycleObserve -> SomeSCapability SLifecycleObserve
  OpConfigObserve -> SomeSCapability SConfigObserve
  OpTargetObserve -> SomeSCapability STargetObserve
  OpProviderReadBack -> SomeSCapability SProviderReadBack
  OpAuthorityBackupReadBack -> SomeSCapability SAuthorityBackupReadBack
  OpManagedObserve -> SomeSCapability SManagedObserve
  OpManagedReadBack -> SomeSCapability SManagedReadBack
  OpLifecycleCas -> SomeSCapability SLifecycleCas
  OpLifecycleSubmit -> SomeSCapability SLifecycleSubmit
  OpLifecycleCancel -> SomeSCapability SLifecycleCancel
  OpConfigProposeCas -> SomeSCapability SConfigProposeCas
  OpTargetCas -> SomeSCapability STargetCas
  OpAuthorityEpochCutover -> SomeSCapability SAuthorityEpochCutover
  OpAuthorityBackupCommit -> SomeSCapability SAuthorityBackupCommit
  OpGatewayContinuityCommit -> SomeSCapability SGatewayContinuityCommit
  OpVaultBootstrapMutate -> SomeSCapability SVaultBootstrapMutate
  OpVaultBaselineReconcile -> SomeSCapability SVaultBaselineReconcile
  OpVaultPkiOperate -> SomeSCapability SVaultPkiOperate
  OpProviderApply -> SomeSCapability SProviderApply
  OpTargetSeal -> SomeSCapability STargetSeal
  OpGatewayDns -> SomeSCapability SGatewayDns
  OpGatewayEmitterRetire -> SomeSCapability SGatewayEmitterRetire
  OpGatewayPeerHandshake -> SomeSCapability SGatewayPeerHandshake
  OpRegistryPublication -> SomeSCapability SRegistryPublication
  OpOperatorMaterialSubmit -> SomeSCapability SOperatorMaterialSubmit
  OpAdminAction -> SomeSCapability SAdminAction
  OpCredentialProvision -> SomeSCapability SCredentialProvision
  OpChildCustodyDelivery -> SomeSCapability SChildCustodyDelivery
  OpDecommissionExport -> SomeSCapability SDecommissionExport
  OpAuthorityBackupEstablish -> SomeSCapability SAuthorityBackupEstablish
  OpTlsSecretMaterialize -> SomeSCapability STlsSecretMaterialize
  OpTlsDekExchange -> SomeSCapability STlsDekExchange
  OpTlsRetentionStore -> SomeSCapability STlsRetentionStore
  OpManagedEnsure -> SomeSCapability SManagedEnsure
  OpManagedDestroy -> SomeSCapability SManagedDestroy

-- | Run an action that needs a 'KnownCapability' dictionary for the singleton's
-- kind. Matching each constructor refines @k@ to a concrete kind whose
-- 'KnownCapability' instance is in scope.
withKnownCapability :: SCapability k -> ((KnownCapability k) => r) -> r
withKnownCapability singleton body = case singleton of
  SProcessAvailability -> body
  SWorkloadAvailability -> body
  SOperatorAvailability -> body
  SVaultBootstrapObserve -> body
  SGatewayFrontDoor -> body
  SLifecycleObserve -> body
  SConfigObserve -> body
  STargetObserve -> body
  SProviderReadBack -> body
  SAuthorityBackupReadBack -> body
  SManagedObserve -> body
  SManagedReadBack -> body
  SLifecycleCas -> body
  SLifecycleSubmit -> body
  SLifecycleCancel -> body
  SConfigProposeCas -> body
  STargetCas -> body
  SAuthorityEpochCutover -> body
  SAuthorityBackupCommit -> body
  SGatewayContinuityCommit -> body
  SVaultBootstrapMutate -> body
  SVaultBaselineReconcile -> body
  SVaultPkiOperate -> body
  SProviderApply -> body
  STargetSeal -> body
  SGatewayDns -> body
  SGatewayEmitterRetire -> body
  SGatewayPeerHandshake -> body
  SRegistryPublication -> body
  SOperatorMaterialSubmit -> body
  SAdminAction -> body
  SCredentialProvision -> body
  SChildCustodyDelivery -> body
  SDecommissionExport -> body
  SAuthorityBackupEstablish -> body
  STlsSecretMaterialize -> body
  STlsDekExchange -> body
  STlsRetentionStore -> body
  SManagedEnsure -> body
  SManagedDestroy -> body
