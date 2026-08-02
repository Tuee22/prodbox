{-# LANGUAGE OverloadedStrings #-}

-- | Substrate-scoped @kubectl@ subprocess
-- environment management.
--
-- This module owns the one place that brackets an arbitrary IO action
-- with the substrate-specific @KUBECONFIG@ process environment.
-- It deliberately lives outside 'Prodbox.PublicEdge': @PublicEdge.hs@ is
-- a config / route-catalog module scoped by
-- @Prodbox.CheckCode.checkEnvVarConfigReads@ (Sprint @7.13@), so it must
-- carry no @lookupEnv@ / @setEnv@ env I/O. The save-and-restore of the
-- ambient process environment around a subprocess call is *not* a
-- @PRODBOX_*@ config read — it is subprocess plumbing — and so belongs in
-- an unscoped @Prodbox.Infra.*@ module alongside the EKS kubeconfig
-- materializer it composes with.
module Prodbox.Infra.SubstrateKubectl
  ( withSubstrateKubectlEnvironment
  )
where

import Control.Exception (bracket_)
import Prodbox.Infra.AwsEksTestStack (withEksKubeconfig)
import Prodbox.Settings
  ( ValidatedSettings
  )
import Prodbox.Substrate (Substrate (..))
import System.Environment (lookupEnv, setEnv, unsetEnv)

-- | Sprint 7.5.c.v follow-up (Sprint 4.18 fifth chunk re-migration):
-- bracket an IO action with the substrate-specific @KUBECONFIG@
-- environment so kubectl subprocesses speak to
-- the correct cluster. Returns the action unchanged on the home
-- substrate (kubectl uses the ambient kubeconfig from
-- @/etc/rancher/rke2/rke2.yaml@ or @~\/.kube\/config@, and no AWS creds
-- are needed). On the AWS substrate it materializes a scoped Provider-issued
-- kubeconfig with a memory-to-FIFO bearer path.
withSubstrateKubectlEnvironment
  :: FilePath -> ValidatedSettings -> Substrate -> IO a -> IO a
withSubstrateKubectlEnvironment repoRoot _settings substrate action =
  case substrate of
    SubstrateHomeLocal -> action
    SubstrateAws ->
      withEksKubeconfig repoRoot (\kubeconfigPath -> withKubeconfig kubeconfigPath action)
 where
  withKubeconfig kubeconfigPath scopedAction = do
    previousValue <- lookupEnv "KUBECONFIG"
    bracket_
      (setEnv "KUBECONFIG" kubeconfigPath)
      (restoreOne (("KUBECONFIG", kubeconfigPath), previousValue))
      scopedAction

  restoreOne :: ((String, String), Maybe String) -> IO ()
  restoreOne ((name, _), Nothing) = unsetEnv name
  restoreOne ((name, _), Just value) = setEnv name value
