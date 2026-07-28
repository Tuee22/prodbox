{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneVaultSession
  ( controlPlaneVaultSessionSuite
  )
where

import Data.Text qualified as Text
import Prodbox.ControlPlane.VaultSession
import Prodbox.Runtime.Role
import Prodbox.Vault.Client (VaultAddress (..))
import Prodbox.Vault.Reconcile
  ( VaultKubernetesRoleSpec (..)
  , VaultPolicySpec (..)
  , VaultReconcilePlan (..)
  , defaultVaultReconcilePlan
  )
import Prodbox.Vault.RoleId
import TestSupport

controlPlaneVaultSessionSuite :: SuiteBuilder ()
controlPlaneVaultSessionSuite =
  describe "Sprint 4.50 standing-role cached Vault session config" $ do
    it "accepts exactly the compiled Vault role for every standing runtime" $
      mapM_ assertStandingRoleBinding standingRoleBindings

    it "refuses a role identity borrowed from another standing process" $
      mkControlPlaneVaultConfig
        LifecycleAuthorityRuntime
        "http://vault.vault.svc.cluster.local:8200"
        "kubernetes"
        (vaultRoleIdText VaultRoleProviderWorker)
        "/var/run/secrets/kubernetes.io/serviceaccount/token"
        `shouldHaveLeft` ( ControlPlaneVaultRoleMismatch
                             (vaultRoleIdText VaultRoleLifecycleAuthority)
                             (vaultRoleIdText VaultRoleProviderWorker)
                         )

    it "refuses gateway/bootstrap identities and empty transport coordinates" $ do
      mkControlPlaneVaultConfig
        GatewayRuntime
        "http://vault"
        "kubernetes"
        (vaultRoleIdText VaultRoleGatewayDaemon)
        "/token"
        `shouldHaveLeft` ControlPlaneVaultRoleUnsupported
      mkControlPlaneVaultConfig
        LifecycleAuthorityRuntime
        ""
        "kubernetes"
        (vaultRoleIdText VaultRoleLifecycleAuthority)
        "/token"
        `shouldHaveLeft` ControlPlaneVaultAddressEmpty

    it "reconciles one distinct policy and Kubernetes role for every standing process" $
      mapM_ assertReconciledStandingRole standingRoleBindings

    it "keeps shared Gateway AWS and MinIO-root credentials out of standing-role policies" $ do
      let documents =
            Text.unlines
              [ vaultPolicySpecDocument policy
              | policy <- vaultReconcilePolicies defaultVaultReconcilePlan
              , vaultPolicySpecName policy
                  `elem` fmap (vaultRoleIdText . snd) standingRoleBindings
              ]
      Text.unpack documents `shouldNotContain` "secret/data/gateway/gateway/aws"
      Text.unpack documents `shouldNotContain` "secret/data/minio/root"
      Text.unpack documents
        `shouldContain` "secret/data/minio/lifecycle-authority"

standingRoleBindings :: [(RuntimeRole, VaultRoleId)]
standingRoleBindings =
  [ (LifecycleAuthorityRuntime, VaultRoleLifecycleAuthority)
  , (ProviderWorkerRuntime, VaultRoleProviderWorker)
  , (AuthorityBackupRuntime, VaultRoleAuthorityBackup)
  , (TlsRetentionRuntime, VaultRoleTlsRetention)
  , (TargetSecretAgentRuntime, VaultRoleTargetSecretAgent)
  ]

assertStandingRoleBinding :: (RuntimeRole, VaultRoleId) -> Expectation
assertStandingRoleBinding (runtimeRole, vaultRole) =
  case mkControlPlaneVaultConfig
    runtimeRole
    "http://vault.vault.svc.cluster.local:8200"
    "kubernetes"
    (vaultRoleIdText vaultRole)
    "/var/run/secrets/kubernetes.io/serviceaccount/token" of
    Left err -> expectationFailure ("expected valid config: " ++ show err)
    Right config -> do
      controlPlaneVaultAddress config
        `shouldBe` VaultAddress "http://vault.vault.svc.cluster.local:8200"
      controlPlaneVaultRole config `shouldBe` vaultRoleIdText vaultRole

assertReconciledStandingRole :: (RuntimeRole, VaultRoleId) -> Expectation
assertReconciledStandingRole (_, vaultRole) = do
  let roleName = vaultRoleIdText vaultRole
      matchingRoles =
        filter
          ((== roleName) . vaultKubernetesRoleSpecName)
          (vaultReconcileKubernetesRoles defaultVaultReconcilePlan)
      matchingPolicies =
        filter
          ((== roleName) . vaultPolicySpecName)
          (vaultReconcilePolicies defaultVaultReconcilePlan)
  case (matchingRoles, matchingPolicies) of
    ([role], [_]) -> do
      vaultKubernetesRoleSpecServiceAccounts role `shouldBe` [roleName]
      vaultKubernetesRoleSpecNamespaces role `shouldBe` ["gateway"]
      vaultKubernetesRoleSpecPolicies role `shouldBe` [roleName]
    other ->
      expectationFailure
        ("expected one standing role and policy, got " ++ show other)

shouldHaveLeft
  :: (Eq err, Show err)
  => Either err value
  -> err
  -> Expectation
shouldHaveLeft result expected = case result of
  Left actual -> actual `shouldBe` expected
  Right _ -> expectationFailure "expected Left, got Right"
