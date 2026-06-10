{-# LANGUAGE OverloadedStrings #-}

-- | Workload-Pod runtime identity.
--
-- The workload binary tags Redis session keys with the name of the Pod it
-- runs in. That name is k8s *runtime metadata* injected by the kubelet via
-- the @HOSTNAME@ environment variable (the downward API default), not part
-- of the binary's configuration surface — so reading it does not violate
-- [config_doctrine.md §10](../../../documents/engineering/config_doctrine.md#10-forbidden-surfaces),
-- which forbids reading *configuration* from environment variables.
--
-- The read is isolated in this dedicated module so that
-- @Prodbox.Workload@ itself stays entirely free of @lookupEnv@ /
-- @getEnv@ / @getEnvironment@ and is covered cleanly by the
-- @checkEnvVarConfigReads@ lint scope (Sprint 3.15): any reintroduced
-- @PRODBOX_*@ config read on the workload surface fails @prodbox
-- check-code@, while this single k8s-runtime-metadata read lives outside
-- that scope by design.
module Prodbox.Workload.PodIdentity
  ( resolvePodName
  )
where

import System.Environment (lookupEnv)

-- | Resolve the Pod name from the kubelet-injected @HOSTNAME@ runtime
-- metadata, falling back to @unknown-pod@ for host-side smoke runs that
-- lack the downward-API value.
resolvePodName :: IO String
resolvePodName = do
  maybePodName <- lookupEnv "HOSTNAME"
  pure $
    case maybePodName of
      Just podName | podName /= "" -> podName
      _ -> "unknown-pod"
