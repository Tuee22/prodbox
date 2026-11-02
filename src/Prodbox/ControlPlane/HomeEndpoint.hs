{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | Compiled home-service identities. Selecting an endpoint grants no
-- authentication, process slot, or Authority operation permit.
module Prodbox.ControlPlane.HomeEndpoint
  ( HomeControlPlaneRole (..)
  , homeControlPlaneRuntimeRole
  , homeControlPlaneNamespace
  , homeControlPlaneForwardTarget
  , homeControlPlaneRemotePort
  , homeControlPlaneStartupProbePath
  , homeControlPlaneForwardStartupLines
  ) where

import Prodbox.ControlPlane.ListenPort (controlPlaneListenPort)
import Prodbox.Runtime.Role (RuntimeRole (..), runtimeRoleName)

data HomeControlPlaneRole (r :: RuntimeRole) where
  HomeLifecycleAuthority :: HomeControlPlaneRole 'LifecycleAuthorityRuntime
  HomeProviderWorker :: HomeControlPlaneRole 'ProviderWorkerRuntime
  HomeAuthorityBackup :: HomeControlPlaneRole 'AuthorityBackupRuntime
  HomeTlsRetention :: HomeControlPlaneRole 'TlsRetentionRuntime
  HomeTargetSecretAgent :: HomeControlPlaneRole 'TargetSecretAgentRuntime

deriving instance Eq (HomeControlPlaneRole r)
deriving instance Show (HomeControlPlaneRole r)

homeControlPlaneRuntimeRole :: HomeControlPlaneRole r -> RuntimeRole
homeControlPlaneRuntimeRole r = case r of
  HomeLifecycleAuthority -> LifecycleAuthorityRuntime
  HomeProviderWorker -> ProviderWorkerRuntime
  HomeAuthorityBackup -> AuthorityBackupRuntime
  HomeTlsRetention -> TlsRetentionRuntime
  HomeTargetSecretAgent -> TargetSecretAgentRuntime

homeControlPlaneNamespace :: HomeControlPlaneRole r -> String
homeControlPlaneNamespace = runtimeRoleName . homeControlPlaneRuntimeRole

homeControlPlaneForwardTarget :: HomeControlPlaneRole r -> String
homeControlPlaneForwardTarget r = prefix ++ homeControlPlaneNamespace r
 where
  -- Genesis reaches the single-generation Recreate Deployment before
  -- credential-backed readiness can publish a backup Service endpoint.
  prefix = case r of
    HomeAuthorityBackup -> "deployment/"
    HomeLifecycleAuthority -> "service/"
    HomeProviderWorker -> "service/"
    HomeTlsRetention -> "service/"
    HomeTargetSecretAgent -> "service/"

homeControlPlaneRemotePort :: HomeControlPlaneRole r -> Int
homeControlPlaneRemotePort _ = controlPlaneListenPort

homeControlPlaneStartupProbePath :: HomeControlPlaneRole r -> String
homeControlPlaneStartupProbePath r = case r of
  HomeAuthorityBackup -> "/healthz"
  HomeLifecycleAuthority -> "/readyz"
  HomeProviderWorker -> "/readyz"
  HomeTlsRetention -> "/readyz"
  HomeTargetSecretAgent -> "/readyz"

-- The observed line must bind this exact local port and compiled remote port.
-- Invalid externally supplied ports cannot describe a matching startup line.
homeControlPlaneForwardStartupLines :: HomeControlPlaneRole r -> Int -> [String]
homeControlPlaneForwardStartupLines selected localPort
  | localPort <= 0 || localPort > 65535 = []
  | otherwise =
      [ "Forwarding from 127.0.0.1:" ++ show localPort ++ suffix
      , "Forwarding from [::1]:" ++ show localPort ++ suffix
      ]
 where
  suffix = " -> " ++ show (homeControlPlaneRemotePort selected)
