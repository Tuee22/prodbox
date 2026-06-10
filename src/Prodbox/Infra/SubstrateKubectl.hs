{-# LANGUAGE OverloadedStrings #-}

-- | Substrate-scoped @kubectl@ / @aws eks get-token@ subprocess
-- environment management.
--
-- This module owns the one place that brackets an arbitrary IO action
-- with the substrate-specific @KUBECONFIG@ + @AWS_*@ process environment.
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
import Data.Text qualified as Text
import Prodbox.Infra.AwsEksTestStack (withEksKubeconfig)
import Prodbox.Settings
  ( Credentials (..)
  , ValidatedSettings (..)
  , aws
  , validatedConfig
  )
import Prodbox.Substrate (Substrate (..))
import System.Environment (lookupEnv, setEnv, unsetEnv)

-- | Sprint 7.5.c.v follow-up (Sprint 4.18 fifth chunk re-migration):
-- bracket an IO action with the substrate-specific @KUBECONFIG@ + @AWS_*@
-- environment so kubectl and @aws eks get-token@ subprocesses speak to
-- the correct cluster. Returns the action unchanged on the home
-- substrate (kubectl uses the ambient kubeconfig from
-- @/etc/rancher/rke2/rke2.yaml@ or @~\/.kube\/config@, and no AWS creds
-- are needed). On the AWS substrate materializes a scoped kubeconfig via
-- 'withEksKubeconfig' (replaces the legacy @.prodbox-state@ persistent
-- path) and projects @AWS_*@ from @settings.aws@ around the action.
withSubstrateKubectlEnvironment
  :: FilePath -> ValidatedSettings -> Substrate -> IO a -> IO a
withSubstrateKubectlEnvironment repoRoot settings substrate action =
  case substrate of
    SubstrateHomeLocal -> action
    SubstrateAws ->
      withEksKubeconfig repoRoot $ \kubeconfigPath -> do
        let awsCreds = aws (validatedConfig settings)
            envOverrides =
              [ ("KUBECONFIG", kubeconfigPath)
              , ("AWS_ACCESS_KEY_ID", Text.unpack (access_key_id awsCreds))
              , ("AWS_SECRET_ACCESS_KEY", Text.unpack (secret_access_key awsCreds))
              , ("AWS_DEFAULT_REGION", Text.unpack (region awsCreds))
              , ("AWS_REGION", Text.unpack (region awsCreds))
              ]
                ++ maybe [] (\tok -> [("AWS_SESSION_TOKEN", Text.unpack tok)]) (session_token awsCreds)
        previousValues <- mapM (lookupEnv . fst) envOverrides
        bracket_
          (mapM_ (uncurry setEnv) envOverrides)
          (mapM_ restoreOne (zip envOverrides previousValues))
          action
 where
  restoreOne :: ((String, String), Maybe String) -> IO ()
  restoreOne ((name, _), Nothing) = unsetEnv name
  restoreOne ((name, _), Just value) = setEnv name value
