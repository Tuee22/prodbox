{-# LANGUAGE DerivingStrategies #-}

-- | Closed HTTP topology for the physically separate control-plane roles.
--
-- A route belongs to exactly one standing role.  There is deliberately no
-- generic object-store, Vault, or provider route: an interpreter is selected by
-- the executable role before a request is decoded.
module Prodbox.ControlPlane.Route
  ( ControlPlaneMethod (..)
  , ControlPlaneRoute (..)
  , allControlPlaneRoutes
  , controlPlaneRouteMethod
  , controlPlaneRoutePath
  , controlPlaneRouteRole
  , routesForRole
  , decodeRoleRoute
  )
where

import Prodbox.Runtime.Role
  ( RuntimeRole
      ( AuthorityBackupRuntime
      , LifecycleAuthorityRuntime
      , ProviderWorkerRuntime
      , TargetSecretAgentRuntime
      , TlsRetentionRuntime
      )
  )

data ControlPlaneMethod
  = ControlPlaneGet
  | ControlPlanePost
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data ControlPlaneRoute
  = LifecycleAuthorityControl
  | LifecycleMigrationApply
  | LifecycleProjectionImport
  | LifecycleAuthorityObserve
  | LifecycleAuthorityBackupExport
  | LifecycleAuthorityDecommissionExport
  | LifecycleAuthorityDecommissionStop
  | LifecycleRetainedSesLease
  | LifecycleOperationSubmit
  | LifecycleOperationObserve
  | LifecycleConfigObserve
  | LifecycleConfigProposeCas
  | LifecycleExternalMaterialIngress
  | LifecycleFederationRegister
  | LifecycleAdminAction
  | LifecycleAwsAdminProvisioner
  | LifecycleProviderDispatch
  | ProviderWorkApply
  | ProviderWorkObserve
  | AuthorityBackupCopy
  | AuthorityBackupObserve
  | TlsRetentionStore
  | TlsRetentionRestore
  | TargetMaterialObserve
  | TargetSecretDecommissionInventory
  | TargetSecretDecommissionTombstone
  | TargetSecretDecommissionCustodyTombstone
  | TargetTlsPrepareExchange
  | TargetTlsRetain
  | TargetTlsHomeWrap
  | TargetTlsHomeRewrap
  | TargetTlsRestore
  | TargetTlsVerifySource
  | LifecycleTlsRetentionObserve
  | LifecycleTlsRetentionPromote
  | LifecycleAdminActionExecution
  | TargetSecretAdminActionGenerationTombstone
  | TargetSecretAdminActionCustodyTombstone
  | TargetChildCustodyCommit
  | TargetChildRecoveryPrepare
  | TargetChildRecoveryObserve
  | LifecycleBootstrapHandoffAccept
  | LifecycleBootstrapHandoffObserve
  | LifecyclePulumiCheckpoint
  | LifecycleTargetIntentIssue
  | TargetSecretTrustInstall
  | LifecycleRetainedMaterialDelivery
  | TargetRetainedMaterialRewrap
  | LifecycleCleanupRun
  | LifecycleEksDrainIntent
  | LifecycleEksDrainReadBackReceipt
  | LifecycleAwsStackReader
  | LifecycleAwsStackCreationBinding
  | LifecycleOwnershipManifest
  | LifecycleRecoveryPlane
  | LifecycleLocalRke2HostObservation
  deriving stock (Eq, Ord, Show, Enum, Bounded)

allControlPlaneRoutes :: [ControlPlaneRoute]
allControlPlaneRoutes = [minBound .. maxBound]

controlPlaneRouteMethod :: ControlPlaneRoute -> ControlPlaneMethod
controlPlaneRouteMethod route = case route of
  LifecycleAuthorityControl -> ControlPlanePost
  LifecycleMigrationApply -> ControlPlanePost
  LifecycleProjectionImport -> ControlPlanePost
  LifecycleAuthorityObserve -> ControlPlaneGet
  LifecycleAuthorityBackupExport -> ControlPlanePost
  LifecycleAuthorityDecommissionExport -> ControlPlanePost
  LifecycleAuthorityDecommissionStop -> ControlPlanePost
  LifecycleRetainedSesLease -> ControlPlanePost
  LifecycleOperationSubmit -> ControlPlanePost
  LifecycleOperationObserve -> ControlPlaneGet
  LifecycleConfigObserve -> ControlPlaneGet
  LifecycleConfigProposeCas -> ControlPlanePost
  LifecycleExternalMaterialIngress -> ControlPlanePost
  LifecycleFederationRegister -> ControlPlanePost
  LifecycleAdminAction -> ControlPlanePost
  LifecycleAwsAdminProvisioner -> ControlPlanePost
  LifecycleProviderDispatch -> ControlPlanePost
  ProviderWorkApply -> ControlPlanePost
  ProviderWorkObserve -> ControlPlaneGet
  AuthorityBackupCopy -> ControlPlanePost
  AuthorityBackupObserve -> ControlPlaneGet
  TlsRetentionStore -> ControlPlanePost
  TlsRetentionRestore -> ControlPlanePost
  TargetMaterialObserve -> ControlPlaneGet
  TargetSecretDecommissionInventory -> ControlPlanePost
  TargetSecretDecommissionTombstone -> ControlPlanePost
  TargetSecretDecommissionCustodyTombstone -> ControlPlanePost
  TargetTlsPrepareExchange -> ControlPlanePost
  TargetTlsRetain -> ControlPlanePost
  TargetTlsHomeWrap -> ControlPlanePost
  TargetTlsHomeRewrap -> ControlPlanePost
  TargetTlsRestore -> ControlPlanePost
  TargetTlsVerifySource -> ControlPlanePost
  LifecycleTlsRetentionObserve -> ControlPlanePost
  LifecycleTlsRetentionPromote -> ControlPlanePost
  LifecycleAdminActionExecution -> ControlPlanePost
  TargetSecretAdminActionGenerationTombstone -> ControlPlanePost
  TargetSecretAdminActionCustodyTombstone -> ControlPlanePost
  TargetChildCustodyCommit -> ControlPlanePost
  TargetChildRecoveryPrepare -> ControlPlanePost
  TargetChildRecoveryObserve -> ControlPlanePost
  LifecycleBootstrapHandoffAccept -> ControlPlanePost
  LifecycleBootstrapHandoffObserve -> ControlPlaneGet
  LifecyclePulumiCheckpoint -> ControlPlanePost
  LifecycleTargetIntentIssue -> ControlPlanePost
  TargetSecretTrustInstall -> ControlPlanePost
  LifecycleRetainedMaterialDelivery -> ControlPlanePost
  TargetRetainedMaterialRewrap -> ControlPlanePost
  LifecycleCleanupRun -> ControlPlanePost
  LifecycleEksDrainIntent -> ControlPlanePost
  LifecycleEksDrainReadBackReceipt -> ControlPlanePost
  LifecycleAwsStackReader -> ControlPlanePost
  LifecycleAwsStackCreationBinding -> ControlPlanePost
  LifecycleOwnershipManifest -> ControlPlanePost
  LifecycleRecoveryPlane -> ControlPlanePost
  LifecycleLocalRke2HostObservation -> ControlPlanePost

controlPlaneRoutePath :: ControlPlaneRoute -> String
controlPlaneRoutePath route = case route of
  LifecycleAuthorityControl -> "/v1/authority/control"
  LifecycleMigrationApply -> "/v1/migration/apply"
  LifecycleProjectionImport -> "/v1/migration/import"
  LifecycleAuthorityObserve -> "/v1/authority/observe"
  LifecycleAuthorityBackupExport -> "/v1/authority/backup/export"
  LifecycleAuthorityDecommissionExport -> "/v1/authority/decommission/export"
  LifecycleAuthorityDecommissionStop -> "/v1/authority/decommission/stop"
  LifecycleRetainedSesLease -> "/v1/authority/retained-ses-lease"
  LifecycleOperationSubmit -> "/v1/operations/submit"
  LifecycleOperationObserve -> "/v1/operations/observe"
  LifecycleConfigObserve -> "/v1/authority/config/observe"
  LifecycleConfigProposeCas -> "/v1/authority/config/propose-cas"
  LifecycleExternalMaterialIngress -> "/v1/authority/external-material-ingress"
  LifecycleFederationRegister -> "/v1/authority/federation/register"
  LifecycleAdminAction -> "/v1/authority/admin-action"
  LifecycleAwsAdminProvisioner -> "/v1/authority/aws-admin-provisioner"
  LifecycleProviderDispatch -> "/v1/authority/provider-dispatch"
  ProviderWorkApply -> "/v1/provider-work/apply"
  ProviderWorkObserve -> "/v1/provider-work/observe"
  AuthorityBackupCopy -> "/v1/authority-backup/copy"
  AuthorityBackupObserve -> "/v1/authority-backup/observe"
  TlsRetentionStore -> "/v1/tls-retention/store"
  TlsRetentionRestore -> "/v1/tls-retention/restore"
  TargetMaterialObserve -> "/v1/target-material/observe"
  TargetSecretDecommissionInventory -> "/v1/target-secret/decommission/inventory"
  TargetSecretDecommissionTombstone -> "/v1/target-secret/decommission/tombstone"
  TargetSecretDecommissionCustodyTombstone ->
    "/v1/target-secret/decommission/retained-custody"
  TargetTlsPrepareExchange -> "/v1/target-tls/exchange/prepare"
  TargetTlsRetain -> "/v1/target-tls/retain"
  TargetTlsHomeWrap -> "/v1/target-tls/home/wrap"
  TargetTlsHomeRewrap -> "/v1/target-tls/home/rewrap"
  TargetTlsRestore -> "/v1/target-tls/restore"
  TargetTlsVerifySource -> "/v1/target-tls/verify-source"
  LifecycleTlsRetentionObserve -> "/v1/authority/tls-retention/observe"
  LifecycleTlsRetentionPromote -> "/v1/authority/tls-retention/promote"
  LifecycleAdminActionExecution -> "/v1/authority/admin-action/execute"
  TargetSecretAdminActionGenerationTombstone ->
    "/v1/target-secret/admin-action/generation-tombstone"
  TargetSecretAdminActionCustodyTombstone ->
    "/v1/target-secret/admin-action/custody-tombstone"
  TargetChildCustodyCommit -> "/v1/target-secret/child-custody/commit"
  TargetChildRecoveryPrepare -> "/v1/target-secret/child-custody/recovery/prepare"
  TargetChildRecoveryObserve -> "/v1/target-secret/child-custody/recovery/observe"
  LifecycleBootstrapHandoffAccept -> "/v1/authority/bootstrap-handoff/accept"
  LifecycleBootstrapHandoffObserve -> "/v1/authority/bootstrap-handoff/observe"
  LifecyclePulumiCheckpoint -> "/v1/authority/pulumi-checkpoint"
  LifecycleTargetIntentIssue -> "/v1/authority/target-intent/issue"
  TargetSecretTrustInstall -> "/v1/target-secret/trust/install"
  LifecycleRetainedMaterialDelivery -> "/v1/authority/retained-material/delivery"
  TargetRetainedMaterialRewrap -> "/v1/target-secret/retained-material/rewrap"
  LifecycleCleanupRun -> "/v1/authority/cleanup-run"
  LifecycleEksDrainIntent -> "/v1/authority/eks-drain-intent"
  LifecycleEksDrainReadBackReceipt ->
    "/v1/authority/eks-drain-readback-receipt"
  LifecycleAwsStackReader -> "/v1/authority/aws-stack-reader"
  LifecycleAwsStackCreationBinding ->
    "/v1/authority/aws-stack-creation-binding"
  LifecycleOwnershipManifest -> "/v1/authority/ownership-manifest"
  LifecycleRecoveryPlane -> "/v1/authority/recovery-plane"
  LifecycleLocalRke2HostObservation ->
    "/v1/authority/local-rke2-host-observation"

controlPlaneRouteRole :: ControlPlaneRoute -> RuntimeRole
controlPlaneRouteRole route = case route of
  LifecycleAuthorityControl -> LifecycleAuthorityRuntime
  LifecycleMigrationApply -> LifecycleAuthorityRuntime
  LifecycleProjectionImport -> LifecycleAuthorityRuntime
  LifecycleAuthorityObserve -> LifecycleAuthorityRuntime
  LifecycleAuthorityBackupExport -> LifecycleAuthorityRuntime
  LifecycleAuthorityDecommissionExport -> LifecycleAuthorityRuntime
  LifecycleAuthorityDecommissionStop -> LifecycleAuthorityRuntime
  LifecycleRetainedSesLease -> LifecycleAuthorityRuntime
  LifecycleOperationSubmit -> LifecycleAuthorityRuntime
  LifecycleOperationObserve -> LifecycleAuthorityRuntime
  LifecycleConfigObserve -> LifecycleAuthorityRuntime
  LifecycleConfigProposeCas -> LifecycleAuthorityRuntime
  LifecycleExternalMaterialIngress -> LifecycleAuthorityRuntime
  LifecycleFederationRegister -> LifecycleAuthorityRuntime
  LifecycleAdminAction -> LifecycleAuthorityRuntime
  LifecycleAwsAdminProvisioner -> LifecycleAuthorityRuntime
  LifecycleProviderDispatch -> LifecycleAuthorityRuntime
  ProviderWorkApply -> ProviderWorkerRuntime
  ProviderWorkObserve -> ProviderWorkerRuntime
  AuthorityBackupCopy -> AuthorityBackupRuntime
  AuthorityBackupObserve -> AuthorityBackupRuntime
  TlsRetentionStore -> TlsRetentionRuntime
  TlsRetentionRestore -> TlsRetentionRuntime
  TargetMaterialObserve -> TargetSecretAgentRuntime
  TargetSecretDecommissionInventory -> TargetSecretAgentRuntime
  TargetSecretDecommissionTombstone -> TargetSecretAgentRuntime
  TargetSecretDecommissionCustodyTombstone -> TargetSecretAgentRuntime
  TargetTlsPrepareExchange -> TargetSecretAgentRuntime
  TargetTlsRetain -> TargetSecretAgentRuntime
  TargetTlsHomeWrap -> TargetSecretAgentRuntime
  TargetTlsHomeRewrap -> TargetSecretAgentRuntime
  TargetTlsRestore -> TargetSecretAgentRuntime
  TargetTlsVerifySource -> TargetSecretAgentRuntime
  LifecycleTlsRetentionObserve -> LifecycleAuthorityRuntime
  LifecycleTlsRetentionPromote -> LifecycleAuthorityRuntime
  LifecycleAdminActionExecution -> LifecycleAuthorityRuntime
  TargetSecretAdminActionGenerationTombstone -> TargetSecretAgentRuntime
  TargetSecretAdminActionCustodyTombstone -> TargetSecretAgentRuntime
  TargetChildCustodyCommit -> TargetSecretAgentRuntime
  TargetChildRecoveryPrepare -> TargetSecretAgentRuntime
  TargetChildRecoveryObserve -> TargetSecretAgentRuntime
  LifecycleBootstrapHandoffAccept -> LifecycleAuthorityRuntime
  LifecycleBootstrapHandoffObserve -> LifecycleAuthorityRuntime
  LifecyclePulumiCheckpoint -> LifecycleAuthorityRuntime
  LifecycleTargetIntentIssue -> LifecycleAuthorityRuntime
  TargetSecretTrustInstall -> TargetSecretAgentRuntime
  LifecycleRetainedMaterialDelivery -> LifecycleAuthorityRuntime
  TargetRetainedMaterialRewrap -> TargetSecretAgentRuntime
  LifecycleCleanupRun -> LifecycleAuthorityRuntime
  LifecycleEksDrainIntent -> LifecycleAuthorityRuntime
  LifecycleEksDrainReadBackReceipt -> LifecycleAuthorityRuntime
  LifecycleAwsStackReader -> LifecycleAuthorityRuntime
  LifecycleAwsStackCreationBinding -> LifecycleAuthorityRuntime
  LifecycleOwnershipManifest -> LifecycleAuthorityRuntime
  LifecycleRecoveryPlane -> LifecycleAuthorityRuntime
  LifecycleLocalRke2HostObservation -> LifecycleAuthorityRuntime

routesForRole :: RuntimeRole -> [ControlPlaneRoute]
routesForRole role =
  filter ((== role) . controlPlaneRouteRole) allControlPlaneRoutes

decodeRoleRoute
  :: RuntimeRole
  -> ControlPlaneMethod
  -> String
  -> Maybe ControlPlaneRoute
decodeRoleRoute role method path =
  exactlyOne
    [ route
    | route <- routesForRole role
    , controlPlaneRouteMethod route == method
    , controlPlaneRoutePath route == path
    ]
 where
  exactlyOne matches = case matches of
    [route] -> Just route
    _ -> Nothing
