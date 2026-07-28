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
  = LifecycleMigrationApply
  | LifecycleOperationSubmit
  | LifecycleOperationObserve
  | ProviderWorkApply
  | ProviderWorkObserve
  | AuthorityBackupCopy
  | AuthorityBackupObserve
  | TlsRetentionStore
  | TlsRetentionRestore
  | TargetSecretObserve
  | TargetSecretCommit
  deriving stock (Eq, Ord, Show, Enum, Bounded)

allControlPlaneRoutes :: [ControlPlaneRoute]
allControlPlaneRoutes = [minBound .. maxBound]

controlPlaneRouteMethod :: ControlPlaneRoute -> ControlPlaneMethod
controlPlaneRouteMethod route = case route of
  LifecycleMigrationApply -> ControlPlanePost
  LifecycleOperationSubmit -> ControlPlanePost
  LifecycleOperationObserve -> ControlPlaneGet
  ProviderWorkApply -> ControlPlanePost
  ProviderWorkObserve -> ControlPlaneGet
  AuthorityBackupCopy -> ControlPlanePost
  AuthorityBackupObserve -> ControlPlaneGet
  TlsRetentionStore -> ControlPlanePost
  TlsRetentionRestore -> ControlPlanePost
  TargetSecretObserve -> ControlPlaneGet
  TargetSecretCommit -> ControlPlanePost

controlPlaneRoutePath :: ControlPlaneRoute -> String
controlPlaneRoutePath route = case route of
  LifecycleMigrationApply -> "/v1/migration/apply"
  LifecycleOperationSubmit -> "/v1/operations/submit"
  LifecycleOperationObserve -> "/v1/operations/observe"
  ProviderWorkApply -> "/v1/provider-work/apply"
  ProviderWorkObserve -> "/v1/provider-work/observe"
  AuthorityBackupCopy -> "/v1/authority-backup/copy"
  AuthorityBackupObserve -> "/v1/authority-backup/observe"
  TlsRetentionStore -> "/v1/tls-retention/store"
  TlsRetentionRestore -> "/v1/tls-retention/restore"
  TargetSecretObserve -> "/v1/target-secret/observe"
  TargetSecretCommit -> "/v1/target-secret/commit"

controlPlaneRouteRole :: ControlPlaneRoute -> RuntimeRole
controlPlaneRouteRole route = case route of
  LifecycleMigrationApply -> LifecycleAuthorityRuntime
  LifecycleOperationSubmit -> LifecycleAuthorityRuntime
  LifecycleOperationObserve -> LifecycleAuthorityRuntime
  ProviderWorkApply -> ProviderWorkerRuntime
  ProviderWorkObserve -> ProviderWorkerRuntime
  AuthorityBackupCopy -> AuthorityBackupRuntime
  AuthorityBackupObserve -> AuthorityBackupRuntime
  TlsRetentionStore -> TlsRetentionRuntime
  TlsRetentionRestore -> TlsRetentionRuntime
  TargetSecretObserve -> TargetSecretAgentRuntime
  TargetSecretCommit -> TargetSecretAgentRuntime

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
