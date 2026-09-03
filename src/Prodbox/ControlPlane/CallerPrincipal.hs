{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed identities which may originate an authenticated control-plane
-- request.  A caller is not necessarily a long-running runtime role: the
-- operator CLI and the test harness are registered principals in their own
-- right and must never be invented as fake servers.
module Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (..)
  , allCallerPrincipals
  , callerPrincipalCode
  , callerPrincipalFromCode
  , callerPrincipalText
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Runtime.Role
  ( RuntimeRole (..)
  , allRuntimeRoles
  , runtimeRoleName
  )

-- | The complete caller algebra.  Service principals retain their actual
-- server role, while human/operator and harness callers occupy distinct slots.
data CallerPrincipal
  = CallerService !RuntimeRole
  | CallerOperatorCli
  | CallerTestHarness
  | CallerAdminActionRunner
  | CallerCredentialProvisioner
  | CallerCredentialProvisionerCompletion
  deriving stock (Eq, Ord, Show)

allCallerPrincipals :: [CallerPrincipal]
allCallerPrincipals =
  fmap CallerService allRuntimeRoles
    <> [ CallerOperatorCli
       , CallerTestHarness
       , CallerAdminActionRunner
       , CallerCredentialProvisioner
       , CallerCredentialProvisionerCompletion
       ]

-- | Stable authentication/replay wire identity.  Codes 1--7 deliberately
-- preserve the original service-role encoding; 100+ is reserved for
-- non-service principals.
callerPrincipalCode :: CallerPrincipal -> Word
callerPrincipalCode principal = case principal of
  CallerService role -> case role of
    BootstrapBroker -> 1
    GatewayRuntime -> 2
    LifecycleAuthorityRuntime -> 3
    ProviderWorkerRuntime -> 4
    AuthorityBackupRuntime -> 5
    TlsRetentionRuntime -> 6
    TargetSecretAgentRuntime -> 7
  CallerOperatorCli -> 100
  CallerTestHarness -> 101
  CallerAdminActionRunner -> 102
  CallerCredentialProvisioner -> 103
  CallerCredentialProvisionerCompletion -> 104

callerPrincipalFromCode :: Word -> Maybe CallerPrincipal
callerPrincipalFromCode code = case code of
  1 -> Just (CallerService BootstrapBroker)
  2 -> Just (CallerService GatewayRuntime)
  3 -> Just (CallerService LifecycleAuthorityRuntime)
  4 -> Just (CallerService ProviderWorkerRuntime)
  5 -> Just (CallerService AuthorityBackupRuntime)
  6 -> Just (CallerService TlsRetentionRuntime)
  7 -> Just (CallerService TargetSecretAgentRuntime)
  100 -> Just CallerOperatorCli
  101 -> Just CallerTestHarness
  102 -> Just CallerAdminActionRunner
  103 -> Just CallerCredentialProvisioner
  104 -> Just CallerCredentialProvisionerCompletion
  _ -> Nothing

-- | Stable configuration/diagnostic text for a closed caller principal.
-- Authentication carries key generation separately in the verified slot.
callerPrincipalText :: CallerPrincipal -> Text
callerPrincipalText principal = case principal of
  CallerService role -> "service/" <> Text.pack (runtimeRoleName role)
  CallerOperatorCli -> "operator/cli"
  CallerTestHarness -> "test/harness"
  CallerAdminActionRunner -> "worker/admin-action-runner"
  CallerCredentialProvisioner -> "worker/credential-provisioner"
  CallerCredentialProvisionerCompletion -> "worker/credential-provisioner-completion"
