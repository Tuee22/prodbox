{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module OrdinaryTeardownRepair
  ( ordinaryTeardownRepairSuite
  )
where

import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Prodbox.Config.ComponentGraph
  ( ComponentId (..)
  , chartNameForComponent
  )
import Prodbox.Config.LocalRke2RecoveryState (LocalRke2RecoveryStateView (..))
import Prodbox.Config.OrdinaryTeardownRecovery
  ( OrdinaryTeardownRecovery
  , OrdinaryTeardownRecoveryComponent (..)
  , OrdinaryTeardownTargetAgent (..)
  , ordinaryTeardownRecovery
  , renderOrdinaryTeardownRecoveryError
  )
import Prodbox.Config.OrdinaryTeardownRepair
import Prodbox.ControlPlane.AuthenticationRegistry
  ( harnessControlPlaneVaultRole
  , operatorControlPlaneVaultRole
  )
import Prodbox.Vault.Reconcile
  ( VaultKubernetesRoleSpec (..)
  , defaultVaultReconcilePlan
  , vaultReconcileKubernetesRoles
  )
import TestSupport

ordinaryTeardownRepairSuite :: SuiteBuilder ()
ordinaryTeardownRepairSuite =
  describe "Sprint 3.41 ordinary teardown repair rendering" $ do
    describe "versioned retained artifact inventory" $ do
      it "accepts a complete, pinned, architecture-uniform declaration" $ do
        inventory <- requireInventory RetainedArtifactAmd64 completeEntries
        retainedArtifactInventoryArchitecture inventory `shouldBe` RetainedArtifactAmd64
        retainedArtifactInventoryKinds inventory `shouldBe` [minBound .. maxBound]
        fmap retainedArtifactRefVersion (lookupRetainedArtifact RetainedSubstrateInstaller inventory)
          `shouldBe` Just "v1.31.4+rke2r1"

      it "treats an empty declaration as a valid inventory that retains nothing" $ do
        inventory <- requireInventory RetainedArtifactAmd64 []
        retainedArtifactInventoryKinds inventory `shouldBe` []

      it "refuses a second entry for the same artifact kind" $ do
        retainedArtifactInventory
          RetainedArtifactAmd64
          (entryFor RetainedSubstrateInstaller : completeEntries)
          `shouldBe` Left
            (RetainedArtifactInventoryDuplicateKind RetainedSubstrateInstaller)

      it "refuses an entry declaring another architecture" $ do
        let foreign_ =
              (entryFor RetainedProdboxRuntimeImage) {retainedArtifactEntryArchitecture = RetainedArtifactArm64}
        retainedArtifactInventory RetainedArtifactAmd64 [foreign_]
          `shouldBe` Left
            ( RetainedArtifactInventoryForeignArchitecture
                RetainedProdboxRuntimeImage
                RetainedArtifactAmd64
                RetainedArtifactArm64
            )

      it "refuses an unpinned version, a non-canonical digest, and an escaping location" $ do
        let unversioned = (entryFor RetainedObjectStoreImage) {retainedArtifactEntryVersion = ""}
            uppercaseDigest =
              (entryFor RetainedObjectStoreImage)
                { retainedArtifactEntryDigest = "sha256:" ++ replicate 64 'A'
                }
            shortDigest =
              (entryFor RetainedObjectStoreImage) {retainedArtifactEntryDigest = "sha256:abc"}
            escaping =
              (entryFor RetainedObjectStoreImage)
                { retainedArtifactEntryRelativePath = "artifacts/../../etc/shadow"
                }
            absolute =
              (entryFor RetainedObjectStoreImage)
                { retainedArtifactEntryRelativePath = "/var/lib/rancher/image.tar"
                }
        retainedArtifactInventory RetainedArtifactAmd64 [unversioned]
          `shouldBe` Left (RetainedArtifactInventoryUnversioned RetainedObjectStoreImage "")
        retainedArtifactInventory RetainedArtifactAmd64 [uppercaseDigest]
          `shouldBe` Left
            ( RetainedArtifactInventoryMalformedDigest
                RetainedObjectStoreImage
                ("sha256:" ++ replicate 64 'A')
            )
        retainedArtifactInventory RetainedArtifactAmd64 [shortDigest]
          `shouldBe` Left
            (RetainedArtifactInventoryMalformedDigest RetainedObjectStoreImage "sha256:abc")
        retainedArtifactInventory RetainedArtifactAmd64 [escaping]
          `shouldBe` Left
            ( RetainedArtifactInventoryUnsafeRetainedPath
                RetainedObjectStoreImage
                "artifacts/../../etc/shadow"
            )
        retainedArtifactInventory RetainedArtifactAmd64 [absolute]
          `shouldBe` Left
            ( RetainedArtifactInventoryUnsafeRetainedPath
                RetainedObjectStoreImage
                "/var/lib/rancher/image.tar"
            )

    describe "artifact obligations derived from the recovery closure" $ do
      it "derives the image obligation identically in every observed state" $ do
        recovery <- requireRecovery OrdinaryTeardownWithoutTargetAgent
        healthy <- requireKinds LocalRke2RecoveryHealthy recovery
        stopped <- requireKinds LocalRke2RecoveryStopped recovery
        healthy
          `shouldBe` [ RetainedObjectStoreImage
                     , RetainedSecretStoreImage
                     , RetainedProdboxRuntimeImage
                     ]
        stopped `shouldBe` healthy

      it "adds the substrate obligation only when the substrate is absent" $ do
        recovery <- requireRecovery OrdinaryTeardownWithoutTargetAgent
        absent <- requireKinds LocalRke2RecoveryAbsent recovery
        absent
          `shouldBe` [ RetainedSubstrateInstaller
                     , RetainedSubstrateSystemImages
                     , RetainedObjectStoreImage
                     , RetainedSecretStoreImage
                     , RetainedProdboxRuntimeImage
                     ]

      it "declares a policy for every member of both recovery closures" $ do
        baseline <- requireRecovery OrdinaryTeardownWithoutTargetAgent
        withTarget <- requireRecovery OrdinaryTeardownWithTargetAgent
        mapM_
          (\state -> requireKinds state baseline >> requireKinds state withTarget)
          [minBound .. maxBound]

      it "refuses a closure member with no declared retained-artifact policy" $ do
        -- The image Registry is exactly the component the recovery profile
        -- excludes; if it ever entered the closure it must refuse, not default
        -- to needing nothing.
        retainedArtifactPolicy
          LocalRke2RecoveryAbsent
          (RecoveryGraphComponent ComponentRegistry)
          `shouldBe` Nothing
        retainedArtifactPolicy
          LocalRke2RecoveryAbsent
          (RecoveryGraphComponent ComponentChartGateway)
          `shouldBe` Nothing
        retainedArtifactPolicy
          LocalRke2RecoveryAbsent
          RecoveryBootstrapCoreExternalCli
          `shouldBe` Just []

    describe "the stopped/absent/healthy repair matrix" $ do
      it "renders a healthy substrate with no install and no service step" $ do
        recovery <- requireRecovery OrdinaryTeardownWithoutTargetAgent
        inventory <- requireInventory RetainedArtifactAmd64 completeEntries
        plan <- requirePlan inventory recovery LocalRke2RecoveryHealthy
        ordinaryTeardownRepairPlanState plan `shouldBe` LocalRke2RecoveryHealthy
        ordinaryTeardownRepairPlanArchitecture plan `shouldBe` RetainedArtifactAmd64
        stepShapes plan
          `shouldBe` [ "load:object_store_image"
                     , "load:secret_store_image"
                     , "load:prodbox_runtime_image"
                     , "reconcile:bootstrap-broker"
                     , "reconcile:lifecycle-authority"
                     , "reconcile:authority-backup"
                     , "reconcile:provider-worker"
                     ]

      it "renders a stopped substrate as start plus await, with no install" $ do
        recovery <- requireRecovery OrdinaryTeardownWithoutTargetAgent
        inventory <- requireInventory RetainedArtifactAmd64 completeEntries
        plan <- requirePlan inventory recovery LocalRke2RecoveryStopped
        take 2 (stepShapes plan) `shouldBe` ["start-service", "await-api"]
        stepShapes plan `shouldNotContain` ["install-substrate"]

      it "renders an absent substrate as a retained reinstall before start" $ do
        recovery <- requireRecovery OrdinaryTeardownWithTargetAgent
        inventory <- requireInventory RetainedArtifactAmd64 completeEntries
        plan <- requirePlan inventory recovery LocalRke2RecoveryAbsent
        stepShapes plan
          `shouldBe` [ "install-substrate"
                     , "start-service"
                     , "await-api"
                     , "load:object_store_image"
                     , "load:secret_store_image"
                     , "load:prodbox_runtime_image"
                     , "reconcile:bootstrap-broker"
                     , "reconcile:target-secret-agent"
                     , "reconcile:lifecycle-authority"
                     , "reconcile:authority-backup"
                     , "reconcile:provider-worker"
                     ]
        installedKinds plan
          `shouldBe` [RetainedSubstrateInstaller, RetainedSubstrateSystemImages]

      it "refuses an absent substrate against a repository that retains nothing" $ do
        recovery <- requireRecovery OrdinaryTeardownWithoutTargetAgent
        inventory <- requireInventory RetainedArtifactAmd64 []
        ordinaryTeardownRepairPlan inventory recovery LocalRke2RecoveryAbsent
          `shouldBe` Left
            ( OrdinaryTeardownRepairUnretainedArtifacts
                LocalRke2RecoveryAbsent
                RetainedArtifactAmd64
                ( NonEmpty.fromList
                    [ RetainedSubstrateInstaller
                    , RetainedSubstrateSystemImages
                    , RetainedObjectStoreImage
                    , RetainedSecretStoreImage
                    , RetainedProdboxRuntimeImage
                    ]
                )
            )

      it "names the whole missing retention obligation, not the first hole" $ do
        recovery <- requireRecovery OrdinaryTeardownWithoutTargetAgent
        inventory <-
          requireInventory
            RetainedArtifactAmd64
            [entryFor RetainedSubstrateInstaller, entryFor RetainedSecretStoreImage]
        case ordinaryTeardownRepairPlan inventory recovery LocalRke2RecoveryAbsent of
          Right _ -> expectationFailure "an incomplete inventory must not render a plan"
          Left err ->
            renderOrdinaryTeardownRepairError err
              `shouldContain` "substrate_system_images, object_store_image, prodbox_runtime_image"

      it "renders a healthy substrate from an image-only inventory" $ do
        recovery <- requireRecovery OrdinaryTeardownWithoutTargetAgent
        inventory <-
          requireInventory
            RetainedArtifactAmd64
            [ entryFor RetainedObjectStoreImage
            , entryFor RetainedSecretStoreImage
            , entryFor RetainedProdboxRuntimeImage
            ]
        plan <- requirePlan inventory recovery LocalRke2RecoveryHealthy
        stepShapes plan `shouldNotContain` ["install-substrate"]
        ordinaryTeardownRepairPlan inventory recovery LocalRke2RecoveryAbsent
          `shouldBe` Left
            ( OrdinaryTeardownRepairUnretainedArtifacts
                LocalRke2RecoveryAbsent
                RetainedArtifactAmd64
                ( NonEmpty.fromList
                    [RetainedSubstrateInstaller, RetainedSubstrateSystemImages]
                )
            )

      it "carries only validated inventory references into every byte-touching step" $ do
        recovery <- requireRecovery OrdinaryTeardownWithoutTargetAgent
        inventory <- requireInventory RetainedArtifactAmd64 completeEntries
        plan <- requirePlan inventory recovery LocalRke2RecoveryAbsent
        let referenced = planArtifactRefs plan
        referenced `shouldNotBe` []
        all (\ref -> lookupRetainedArtifact (retainedArtifactRefKind ref) inventory == Just ref) referenced
          `shouldBe` True
        all ((== RetainedArtifactAmd64) . retainedArtifactRefArchitecture) referenced
          `shouldBe` True

    describe "deletion-survivor projection" $ do
      it "scopes deletion to every chart the recovery closure does not admit" $ do
        recovery <- requireRecovery OrdinaryTeardownWithTargetAgent
        let scope = gatewayAndApplicationDeletionScope recovery
        deletionScopeReleases scope `shouldBe` deletionScopeNamespaces scope
        deletionScopeReleases scope `shouldContain` ["gateway"]
        deletionScopeReleases scope `shouldContain` ["vscode"]
        deletionScopeReleases scope `shouldContain` ["tls-retention"]
        deletionScopeReleases scope `shouldNotContain` ["bootstrap-broker"]
        deletionScopeReleases scope `shouldNotContain` ["provider-worker"]

      it "leaves the teardown caller identity and every recovery role present" $ do
        recovery <- requireRecovery OrdinaryTeardownWithTargetAgent
        let projection =
              projectDeletionSurvivors recovery (gatewayAndApplicationDeletionScope recovery)
        deletionSurvivorCasualties projection `shouldBe` []
        fmap recoveryPlaneResourceText (deletionSurvivorSurvivors projection)
          `shouldBe` [ "chart_bootstrap_broker"
                     , "chart_target_secret_agent"
                     , "chart_lifecycle_authority"
                     , "chart_authority_backup"
                     , "chart_provider_worker"
                     , "bootstrap_core_external_cli_service_account"
                     , "bootstrap_core_external_cli_self_tokenrequest_role"
                     , "bootstrap_core_external_cli_self_tokenrequest_rolebinding"
                     ]

      it "owns the caller identity in the Bootstrap Broker release, not Gateway" $ do
        recoveryPlaneResourceOwner RecoveryPlaneCallerServiceAccount
          `shouldBe` Just
            ( RecoveryPlaneResourceOwner
                { recoveryPlaneResourceOwnerRelease = "bootstrap-broker"
                , recoveryPlaneResourceOwnerNamespace = "bootstrap-broker"
                }
            )
        fmap
          recoveryPlaneResourceOwnerRelease
          (recoveryPlaneResourceOwner RecoveryPlaneCallerSelfTokenRequestRole)
          `shouldNotBe` chartNameForComponent ComponentChartGateway

      it "reports a casualty when a recovery resource's owner is in scope" $ do
        recovery <- requireRecovery OrdinaryTeardownWithoutTargetAgent
        let scope =
              DeletionScope
                { deletionScopeReleases = []
                , deletionScopeNamespaces = ["bootstrap-broker"]
                }
            projection = projectDeletionSurvivors recovery scope
        fmap recoveryPlaneResourceText (deletionSurvivorCasualties projection)
          `shouldBe` [ "chart_bootstrap_broker"
                     , "bootstrap_core_external_cli_service_account"
                     , "bootstrap_core_external_cli_self_tokenrequest_role"
                     , "bootstrap_core_external_cli_self_tokenrequest_rolebinding"
                     ]

      it "keeps the operator control-plane Vault role's bound namespace out of deletion scope" $ do
        recovery <- requireRecovery OrdinaryTeardownWithTargetAgent
        let scope = gatewayAndApplicationDeletionScope recovery
            deleted = fmap Text.pack (deletionScopeNamespaces scope)
            boundNamespaces role =
              concatMap
                vaultKubernetesRoleSpecNamespaces
                ( filter
                    ((== role) . vaultKubernetesRoleSpecName)
                    (vaultReconcileKubernetesRoles defaultVaultReconcilePlan)
                )
        boundNamespaces operatorControlPlaneVaultRole `shouldBe` ["bootstrap-broker"]
        any (`elem` deleted) (boundNamespaces operatorControlPlaneVaultRole) `shouldBe` False
        -- The Gateway-owned test-harness caller is deliberately still a
        -- casualty: that is the identity whose lifetime Sprint 3.41 moved the
        -- operator caller away from.
        boundNamespaces harnessControlPlaneVaultRole `shouldBe` ["gateway"]
        all (`elem` deleted) (boundNamespaces harnessControlPlaneVaultRole) `shouldBe` True

completeEntries :: [RetainedArtifactEntry]
completeEntries = fmap entryFor [minBound .. maxBound]

-- | Synthetic retained declaration.  Every digest is an obviously synthetic
-- repeated nibble; no value here identifies a real published artifact.
entryFor :: RetainedArtifactKind -> RetainedArtifactEntry
entryFor kind =
  RetainedArtifactEntry
    { retainedArtifactEntryKind = kind
    , retainedArtifactEntryArchitecture = RetainedArtifactAmd64
    , retainedArtifactEntryVersion = versionFor kind
    , retainedArtifactEntryDigest = "sha256:" ++ replicate 64 (digestNibble kind)
    , retainedArtifactEntryRelativePath =
        "recovery-artifacts/amd64/" ++ retainedArtifactKindText kind ++ ".tar"
    }

versionFor :: RetainedArtifactKind -> String
versionFor kind = case kind of
  RetainedSubstrateInstaller -> "v1.31.4+rke2r1"
  RetainedSubstrateSystemImages -> "v1.31.4+rke2r1"
  RetainedObjectStoreImage -> "RELEASE.0000-00-00T00-00-00Z"
  RetainedSecretStoreImage -> "0.0.0-fixture"
  RetainedProdboxRuntimeImage -> "0.0.0-fixture"

digestNibble :: RetainedArtifactKind -> Char
digestNibble kind = case kind of
  RetainedSubstrateInstaller -> '1'
  RetainedSubstrateSystemImages -> '2'
  RetainedObjectStoreImage -> '3'
  RetainedSecretStoreImage -> '4'
  RetainedProdboxRuntimeImage -> '5'

stepShapes :: OrdinaryTeardownRepairPlan -> [String]
stepShapes = fmap shape . ordinaryTeardownRepairPlanSteps
 where
  shape step = case step of
    RepairInstallSubstrateFromRetained _ -> "install-substrate"
    RepairStartSubstrateService -> "start-service"
    RepairAwaitSubstrateApi -> "await-api"
    RepairLoadRetainedImage ref ->
      "load:" ++ retainedArtifactKindText (retainedArtifactRefKind ref)
    RepairReconcileRecoveryChart chartName -> "reconcile:" ++ chartName

installedKinds :: OrdinaryTeardownRepairPlan -> [RetainedArtifactKind]
installedKinds plan =
  concat
    [ fmap retainedArtifactRefKind (NonEmpty.toList refs)
    | RepairInstallSubstrateFromRetained refs <- ordinaryTeardownRepairPlanSteps plan
    ]

planArtifactRefs :: OrdinaryTeardownRepairPlan -> [RetainedArtifactRef]
planArtifactRefs plan =
  concatMap refsOf (ordinaryTeardownRepairPlanSteps plan)
 where
  refsOf step = case step of
    RepairInstallSubstrateFromRetained refs -> NonEmpty.toList refs
    RepairLoadRetainedImage ref -> [ref]
    RepairStartSubstrateService -> []
    RepairAwaitSubstrateApi -> []
    RepairReconcileRecoveryChart _ -> []

requireRecovery :: OrdinaryTeardownTargetAgent -> IO OrdinaryTeardownRecovery
requireRecovery targetRequirement =
  case ordinaryTeardownRecovery targetRequirement of
    Left err ->
      expectationFailure (renderOrdinaryTeardownRecoveryError err) >> fail "unreachable"
    Right recovery -> pure recovery

requireInventory
  :: RetainedArtifactArchitecture
  -> [RetainedArtifactEntry]
  -> IO RetainedArtifactInventory
requireInventory architecture entries =
  case retainedArtifactInventory architecture entries of
    Left err ->
      expectationFailure (renderRetainedArtifactInventoryError err) >> fail "unreachable"
    Right inventory -> pure inventory

requireKinds
  :: LocalRke2RecoveryStateView
  -> OrdinaryTeardownRecovery
  -> IO [RetainedArtifactKind]
requireKinds state recovery =
  case requiredRetainedArtifacts state recovery of
    Left err ->
      expectationFailure (renderOrdinaryTeardownRepairError err) >> fail "unreachable"
    Right kinds -> pure kinds

requirePlan
  :: RetainedArtifactInventory
  -> OrdinaryTeardownRecovery
  -> LocalRke2RecoveryStateView
  -> IO OrdinaryTeardownRepairPlan
requirePlan inventory recovery state =
  case ordinaryTeardownRepairPlan inventory recovery state of
    Left err ->
      expectationFailure (renderOrdinaryTeardownRepairError err) >> fail "unreachable"
    Right plan -> pure plan
