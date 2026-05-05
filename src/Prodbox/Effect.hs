module Prodbox.Effect (
    Effect (..),
    Validation (..),
)
where

import Prodbox.Subprocess (
    CommandSpec,
 )

data Validation
    = RequireLinux
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
    deriving (Eq, Show)

data Effect
    = EmitLine String
    | Noop
    | RunCommand CommandSpec
    | AssertCommandOutputContains CommandSpec String
    | Sequence [Effect]
    | Validate Validation
    deriving (Eq, Show)
