{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownOperationalCredentialInventory
  ( lifecycleTeardownOperationalCredentialInventorySuite
  )
where

import qualified Data.ByteString as ByteString
import qualified Data.List.NonEmpty as NonEmpty
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , CredentialLifetime (..)
  , CredentialPermission (..)
  , CredentialTarget (..)
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( EksClientAuthRequest
  , EksClusterIdentityRequest
  , ProviderCheckpointRef
  , ProviderIntent (..)
  , ProviderReadinessProbe (..)
  , ProviderRevision
  , ProviderSpotPriceQuery
  , ProviderStackConfig
  , ProviderStackRef
  , PublicARecordRef
  , SesBucketRef
  , SesDnsRef
  , SesIdentityRef
  , SesRuleSetRef
  , mkAwsEksProviderStackConfig
  , mkEksClientAuthRequest
  , mkEksClusterIdentityRequest
  , mkProviderCheckpointRef
  , mkProviderRevision
  , mkProviderSpotPriceQuery
  , mkProviderStackRef
  , mkPublicARecordRef
  , mkSesBucketRef
  , mkSesDnsRef
  , mkSesIdentityRef
  , mkSesRuleSetRef
  )
import Prodbox.Lifecycle.Teardown.OperationalCredentialInventory
import TestSupport

lifecycleTeardownOperationalCredentialInventorySuite :: SuiteBuilder ()
lifecycleTeardownOperationalCredentialInventorySuite =
  describe "operational credential dependency inventory" $ do
    it "carries the canonical Lifecycle-provider identity without generation authority" $ do
      operationalCredentialInventoryClass inventory
        `shouldBe` LifecycleProviderCredential
      operationalCredentialInventoryPrincipal inventory
        `shouldBe` "prodbox-lifecycle-provider"
      operationalCredentialInventoryPolicy inventory
        `shouldBe` "prodbox-lifecycle-provider"
      operationalCredentialInventoryLifetime inventory
        `shouldBe` OperationalCredential
      operationalCredentialInventoryTarget inventory
        `shouldBe` LifecycleProviderTarget
      operationalCredentialInventoryPermissions inventory
        `shouldBe` [AssumeRegisteredProviderRole]
      operationalCredentialInventoryMaximumAccessKeys inventory `shouldBe` 2
      operationalCredentialInventoryGenerationOwner inventory
        `shouldBe` LifecycleAuthorityFirstReconcileJournal

    it "classifies every closed Provider intent as an exact consumer" $ do
      let classified = map operationalCredentialConsumerForIntent providerIntents
      classified `shouldBe` [minBound .. maxBound]
      operationalCredentialInventoryConsumers inventory `shouldBe` classified

    it "names only the currently Provider-backed teardown operations" $ do
      operationalCredentialInventoryGraphConsumers inventory
        `shouldBe` [minBound .. maxBound]
      map
        operationalCredentialGraphConsumerTag
        (operationalCredentialInventoryGraphConsumers inventory)
        `shouldBe` [ "observe-registered-target"
                   , "reconcile-stack-checkpoint-restore"
                   , "commit-eks-drain-intent"
                   , "drain-eks-kubernetes-resources"
                   , "read-back-eks-kubernetes-drain"
                   , "reconcile-registered-target-absent"
                   , "read-back-registered-target-absent"
                   ]

    it "keeps both revoke orders and missing global authority explicitly blocked" $ do
      NonEmpty.toList (operationalCredentialInventoryDispositionBlockers inventory)
        `shouldBe` [ DispositionBeforeAuditConflictsWithLiveAuditCredential
                   , AuditBeforeDispositionConflictsWithCurrentCascadeGraph
                   , TerminalAuditProviderCapabilityUnassigned
                   , GlobalProviderAdmissionFreezeUnavailable
                   , ProviderOperationCleanupRunOwnershipUnavailable
                   , OrdinaryLifecycleProviderRevocationUnavailable
                   , CanonicalTargetRevocationReadBackUnavailable
                   , LegacyOperationalIdentityReplacementUndefined
                   ]

    it "keeps the pre-cutover identity migration-required and distinct" $ do
      legacyOperationalIdentityPrincipal legacyOperationalIdentity
        `shouldBe` "prodbox"
      legacyOperationalIdentityPolicy legacyOperationalIdentity
        `shouldBe` "prodbox-inline"
      legacyOperationalIdentityResources legacyOperationalIdentity
        `shouldBe` [ "operational-aws-ses-lease-role"
                   , "operational-iam-user"
                   , "operational-aws-config"
                   ]
      legacyOperationalIdentityStatus legacyOperationalIdentity
        `shouldBe` LegacyOperationalIdentityMigrationRequired
      legacyOperationalIdentityPrincipal legacyOperationalIdentity
        `shouldNotBe` operationalCredentialInventoryPrincipal inventory

    it "keeps SES SMTP in the distinct retained-custody inventory" $ do
      retainedCustodyCredentialClasses
        `shouldBe` [SesSmtpRetainedCustodyCredential]
      retainedCustodyCredentialClasses
        `shouldSatisfy` notElem LifecycleProviderCredential

    it "exports no authority-bearing constructor or proof seam" $ do
      source <-
        readFile
          "src/Prodbox/Lifecycle/Teardown/OperationalCredentialInventory.hs"
      let header = unlines (takeWhile (/= "where") (lines source))
      header `shouldNotContain` "OperationalCredentialInventory (.."
      header `shouldNotContain` "LegacyOperationalIdentity (.."
      mapM_
        (source `shouldNotContain`)
        [ "CascadeCredentialDispositionEvidence"
        , "TerminalAuditObservation"
        , "Prodbox.Lifecycle.TargetCommitIntent"
        , "Prodbox.Lifecycle.ResourceClass"
        , "Prodbox.Lifecycle.TagSweep"
        , "Prodbox.Lifecycle.Teardown.Execution"
        , "Prodbox.Lifecycle.Teardown.Program"
        ]

inventory :: OperationalCredentialInventory
inventory = operationalCredentialInventory

providerIntents :: [ProviderIntent]
providerIntents =
  [ ReconcileRegisteredStack stackRef revision stackConfig
  , DestroyRegisteredStack stackRef revision stackConfig
  , ObserveRegisteredStack stackRef
  , ReadBackRegisteredStack stackRef
  , BoundedScratchCheckpoint checkpointRef
  , ReconcileSesSendingIdentity sesIdentity
  , ReconcileSesDkim sesIdentity
  , ReconcileSesReceiptRules sesRules
  , ReconcileSesCaptureBucket sesBucket
  , ReconcileSesDns sesDns
  , ObservePublicARecord publicARecord
  , ReconcilePublicARecord publicARecord
  , ReapTestEbsVolumes "prodbox-test"
  , ObserveSpotPrice spotPrice
  , ObserveOperationalIdentity
  , ObserveProviderReadiness ProviderReadinessStsIdentity
  , IssueEksClientAuth eksClientAuth
  , ObserveTestEbsVolumes "prodbox-test"
  , ObserveEksClusterIdentity eksIdentity
  , ObserveProviderAwsScope
  ]

stackRef :: ProviderStackRef
stackRef = mustRight (mkProviderStackRef "aws-eks")

revision :: ProviderRevision
revision = mustRight (mkProviderRevision 1)

stackConfig :: ProviderStackConfig
stackConfig = mustRight (mkAwsEksProviderStackConfig "127.0.0.1/32")

checkpointRef :: ProviderCheckpointRef
checkpointRef = mustRight (mkProviderCheckpointRef "aws-eks-checkpoint")

sesIdentity :: SesIdentityRef
sesIdentity = mustRight (mkSesIdentityRef "example.test")

sesRules :: SesRuleSetRef
sesRules =
  mustRight
    (mkSesRuleSetRef "example-rules" "mail@example.test" "example-capture")

sesBucket :: SesBucketRef
sesBucket = mustRight (mkSesBucketRef "example-capture")

sesDns :: SesDnsRef
sesDns = mustRight (mkSesDnsRef "Z123" "example.test" "mail.example.test")

publicARecord :: PublicARecordRef
publicARecord =
  mustRight (mkPublicARecordRef "Z123" "api.example.test" 60 ["192.0.2.1"])

spotPrice :: ProviderSpotPriceQuery
spotPrice = mustRight (mkProviderSpotPriceQuery "m7i.large" "Linux/UNIX")

eksClientAuth :: EksClientAuthRequest
eksClientAuth =
  mustRight
    ( mkEksClientAuthRequest
        "111122223333"
        "ca-central-1"
        "prodbox"
        (ByteString.replicate 32 7)
    )

eksIdentity :: EksClusterIdentityRequest
eksIdentity =
  mustRight
    ( mkEksClusterIdentityRequest
        stackRef
        "111122223333"
        "ca-central-1"
        "prodbox"
    )

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error ("unexpected fixture failure: " ++ show err)
  Right value -> value
