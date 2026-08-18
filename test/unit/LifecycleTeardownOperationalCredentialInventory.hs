{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownOperationalCredentialInventory
  ( lifecycleTeardownOperationalCredentialInventorySuite
  )
where

import Data.ByteString qualified as ByteString
import Data.List (sort)
import Data.List.NonEmpty qualified as NonEmpty
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
import Prodbox.Lifecycle.Teardown.OperationalCredentialCoverage
  ( cascadeTerminalAuditNodeName
  , coverageRegressionAncestryIsDiscriminating
  , coverageRegressionAuditIsNotItsOwnConsumer
  , coverageRegressionCheckpointTailCounted
  , coverageRegressionConsumersPrecedeAudit
  , coverageRegressionEveryConsumerReached
  , dispositionRegressionAuditPredicateDiscriminates
  , dispositionRegressionCascadeHasAudit
  , dispositionRegressionMeasuredEqualsPublished
  , dispositionRegressionOperationalSurfaceHasNoAudit
  , dispositionRegressionSomeBlockersAreDerived
  , fixedOperationalCredentialCoverageRegression
  , fixedOperationalCredentialDispositionRegression
  , measuredOperationalCredentialDispositionBlockers
  , operationalCredentialCoverageViolations
  , validateOperationalCredentialCoverage
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
        -- Sprint 4.84 added the three checkpoint-tail entries. The list
        -- previously stopped at the restore, but AwsCheckpointInterpreter
        -- reaches the shared registered-target interpreter in three further
        -- arms, and the retirement read-back is every stack target's
        -- completion node -- later than anything the old list named.
        `shouldBe` [ "observe-registered-target"
                   , "reconcile-stack-checkpoint-restore"
                   , "read-back-stack-checkpoint-recovery"
                   , "commit-eks-drain-intent"
                   , "drain-eks-kubernetes-resources"
                   , "read-back-eks-kubernetes-drain"
                   , "reconcile-registered-target-absent"
                   , "read-back-registered-target-absent"
                   , "retire-stack-checkpoint-pair"
                   , "read-back-stack-checkpoint-retirement"
                   ]

    it "Sprint 4.84 joins the inventory to the program that contains those nodes" $
      -- The enumeration was authored by hand and joined to nothing, so it
      -- silently under-reported its own last consumer. Both directions are
      -- now closed: an unclassified operation is a compile error (the
      -- classifier's result type IS the inventory), and a stale entry no
      -- node reaches is a finding here.
      operationalCredentialCoverageViolations `shouldBe` []

    it "Sprint 4.84 every credential consumer precedes the terminal audit" $ do
      -- `DispositionBeforeAuditConflictsWithLiveAuditCredential` is an
      -- ordering claim, and it is only as good as the graph actually
      -- enforcing it: the audit must run while the credential is still live,
      -- so no consumer may sit outside the audit's ancestry.
      validateOperationalCredentialCoverage `shouldBe` Right ()
      cascadeTerminalAuditNodeName `shouldBe` "cascade/audit-escapes"

    it "Sprint 4.84 the ordering check is discriminating, not vacuous" $ do
      -- A coverage check whose ancestry relation is trivially total proves
      -- nothing. `cascade/read-back-completion` runs strictly after the audit
      -- and must not be an ancestor of it.
      let regression = fixedOperationalCredentialCoverageRegression
      coverageRegressionEveryConsumerReached regression `shouldBe` True
      coverageRegressionConsumersPrecedeAudit regression `shouldBe` True
      coverageRegressionCheckpointTailCounted regression `shouldBe` True
      coverageRegressionAncestryIsDiscriminating regression `shouldBe` True
      coverageRegressionAuditIsNotItsOwnConsumer regression `shouldBe` True

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

    -- Sprint 4.85: the list above is the stated reason OperationalTeardown has
    -- no registered descriptors, and until now its only consumer was the case
    -- above asserting it equals itself. A blocker that stopped being true would
    -- have gone on justifying the same omission.
    it "Sprint 4.85 recomputes the derivable blockers from their sources" $ do
      measured <-
        either
          (\err -> expectationFailure (show err) >> pure [])
          pure
          measuredOperationalCredentialDispositionBlockers
      sort measured
        `shouldBe` sort
          (NonEmpty.toList (operationalCredentialInventoryDispositionBlockers inventory))

      -- Half the list is genuinely measured; the other half rests on a missing
      -- constructor, which no value can witness, and says so.
      [ blocker
        | blocker <- [minBound .. maxBound]
        , DerivedFromCompiledTeardownPrograms <- [dispositionBlockerEvidence blocker]
        ]
        `shouldBe` [ DispositionBeforeAuditConflictsWithLiveAuditCredential
                   , AuditBeforeDispositionConflictsWithCurrentCascadeGraph
                   ]
      [ capability
        | blocker <- [minBound .. maxBound]
        , TypeLevelAbsence capability <- [dispositionBlockerEvidence blocker]
        ]
        `shouldBe` [minBound .. maxBound]

    it "Sprint 4.85 the disposition join is discriminating, not vacuous" $ do
      let regression = fixedOperationalCredentialDispositionRegression
      dispositionRegressionMeasuredEqualsPublished regression `shouldBe` True
      dispositionRegressionSomeBlockersAreDerived regression `shouldBe` True
      -- The audit predicate finds the cascade audit, so "the operational
      -- surface has no audit" is a measurement rather than a predicate that
      -- never matches anything.
      dispositionRegressionCascadeHasAudit regression `shouldBe` True
      dispositionRegressionOperationalSurfaceHasNoAudit regression `shouldBe` True
      dispositionRegressionAuditPredicateDiscriminates regression `shouldBe` True

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
