module Prodbox.Effect
  ( Effect (..)
  , Validation (..)
  )
where

import Prodbox.Subprocess
  ( Subprocess
  )

data Validation
  = RequireLinux
  | RequireHostSubstrateSupported
  | RequireSettings
  | RequireSystemd
  | RequireTool FilePath [String]
  | RequireFileExists FilePath
  | RequireHomeKubeconfig
  | RequireMachineIdentity
  | RequireServiceExists String
  | RequireServiceActive String
  | RequireAwsCredentials
  | RequireAwsIamHarnessReady
  | RequireRoute53Access
  | RequireRoute53LifecycleCapability
  | RequirePulumiLogin
  | RequireKubectlClusterReachable
  | RequireUbuntu2404
  | RequireSesSendingIdentityVerified
  | RequireSesReceiveRuleSetActive
  | RequireSesReceiveBucketAccessible
  deriving (Eq, Show)

data Effect
  = EmitLine String
  | Noop
  | RunCommand Subprocess
  | AssertCommandOutputContains Subprocess String
  | Sequence [Effect]
  | Validate Validation
  deriving (Eq, Show)
