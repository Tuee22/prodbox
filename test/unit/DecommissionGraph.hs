{-# LANGUAGE OverloadedStrings #-}

module DecommissionGraph (decommissionGraphSuite) where

import Data.Functor.Identity (Identity, runIdentity)
import Data.List (find)
import Data.Text (Text)
import Prodbox.Lifecycle.Decommission.Graph
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionLocalDataDisposition (DeleteLocalData, RetainLocalData)
  , DecommissionNode (..)
  , DecommissionTargetGeneration
  , mandatoryDecommissionChoiceNodes
  , mkDecommissionTargetGeneration
  , requiredSingletonDecommissionNodes
  )
import TestSupport

decommissionGraphSuite :: SuiteBuilder ()
decommissionGraphSuite =
  describe "Sprint 4.50 decommission destroy subgraph" $ do
    it "derives an order with the audit terminal and the SES/TLS/backup chains in sequence" $ do
      -- Sprint 4.85: the shared bucket is the last resource deletion, and the
      -- final no-retention audit is the unique terminal behind it. The audit
      -- admits no retained carve-out, so a clean verdict is only a statement
      -- about the whole plan once the bucket it would otherwise report as an
      -- escapee is gone.
      sharedBucketIsLastDeletion fullInventory `shouldBe` True
      terminalPhaseRunsLastInOrder fullInventory `shouldBe` True
      tlsPrecedesSharedBucket fullInventory `shouldBe` True
      sesDestroyPrecedesTombstones fullInventory `shouldBe` True
      targetTombstonesPrecedeCustody fullInventory `shouldBe` True
      custodyPrecedesTls fullInventory `shouldBe` True
      tlsPrecedesBackup fullInventory `shouldBe` True
      allPrefixesProvenBeforeSharedBucket fullInventory `shouldBe` True
      -- Sprint 4.85: the terminal phase is ordered -- the audit proves what the
      -- deletions achieved, then the home uninstall dismantles the plane the
      -- earlier nodes were answered through.
      drop (length fullInventory - 4) (decommissionTopologicalOrder fullInventory)
        `shouldBe` [ FinalNoRetentionAudit
                   , HomeSubstrateUninstall
                   , LocalDataDisposition DeleteLocalData
                   , DecommissionTerminalReceipt
                   ]
      decommissionTerminalPhaseOrder
        `shouldBe` [ FinalNoRetentionAudit
                   , HomeSubstrateUninstall
                   , LocalDataDisposition RetainLocalData
                   , DecommissionTerminalReceipt
                   ]
      -- Sprint 4.85: the enumeration's representative is not the node any
      -- particular plan contains, so the last-in-order property is compared by
      -- phase rank. This inventory carries the `delete` decision and still
      -- satisfies it.
      decommissionTerminalPhaseBijection `shouldBe` True
    it "Sprint 4.85 derives the production plan the Authority signs" $ do
      -- The Authority authored this inventory as a three-element prefix and a
      -- six-element suffix around the optional Target Agent generation, while
      -- the verifier required the set derived from the closed singleton
      -- enumeration. Nothing joined producer to verifier: a newly added
      -- singleton would have been demanded by one and never signed by the
      -- other, and the fail-closed refusal lands inside the interactive run
      -- after the point-of-no-return confirmation.
      productionDecommissionPlanNodes DeleteLocalData [targetNode]
        `shouldBe` [ SesConsumerQuiescence
                   , SesProviderStack
                   , SesSmtpIam
                   , targetNode
                   , RetainedCustody
                   , TlsRetainedObjects
                   , TlsRetentionIdentity
                   , BackupObjects
                   , BackupPrefixAbsenceProof
                   , SharedObjectBucket
                   , FinalNoRetentionAudit
                   , HomeSubstrateUninstall
                   , LocalDataDisposition DeleteLocalData
                   , DecommissionTerminalReceipt
                   ]
      -- An Agent-less cluster signs exactly the mandatory singletons plus the
      -- one mandatory choice node the operator decided.
      productionDecommissionPlanNodes RetainLocalData []
        `shouldBe` [ SesConsumerQuiescence
                   , SesProviderStack
                   , SesSmtpIam
                   , RetainedCustody
                   , TlsRetainedObjects
                   , TlsRetentionIdentity
                   , BackupObjects
                   , BackupPrefixAbsenceProof
                   , SharedObjectBucket
                   , FinalNoRetentionAudit
                   , HomeSubstrateUninstall
                   , LocalDataDisposition RetainLocalData
                   , DecommissionTerminalReceipt
                   ]
      -- Sprint 4.85: the operator's decision is the only thing that differs
      -- between the two plans, so a `retain` receipt cannot be resumed as a
      -- `delete` run -- the node, and therefore its frame identity, differs.
      filter
        (`notElem` productionDecommissionPlanNodes RetainLocalData [])
        (productionDecommissionPlanNodes DeleteLocalData [])
        `shouldBe` [LocalDataDisposition DeleteLocalData]
      -- The derived plan is exactly the mandatory set plus the parameterized
      -- nodes it was given: no singleton is dropped, and none is invented.
      filter
        (`notElem` productionDecommissionPlanNodes DeleteLocalData [targetNode])
        requiredSingletonDecommissionNodes
        `shouldBe` []
      filter
        ( `notElem`
            ( targetNode
                : mandatoryDecommissionChoiceNodes DeleteLocalData
                ++ requiredSingletonDecommissionNodes
            )
        )
        (productionDecommissionPlanNodes DeleteLocalData [targetNode])
        `shouldBe` []
      -- And it satisfies the graph invariants it was derived from, so the
      -- signed plan cannot name an order the runner would refuse.
      sharedBucketIsLastDeletion
        (productionDecommissionPlanNodes DeleteLocalData [targetNode])
        `shouldBe` True
      terminalPhaseRunsLastInOrder
        (productionDecommissionPlanNodes DeleteLocalData [targetNode])
        `shouldBe` True
      targetTombstonesPrecedeCustody
        (productionDecommissionPlanNodes DeleteLocalData [targetNode])
        `shouldBe` True

    it "runs every node and converges under an all-success interpreter" $ do
      let report = run fullInventory alwaysSucceed
      reportConverged report `shouldBe` True
      length (reportExecutions report) `shouldBe` length fullInventory
      reportFailed report `shouldBe` []
      reportBlocked report `shouldBe` []
    it "runs the all-prefix proof only after backup object and identity deletion" $ do
      let report = run fullInventory (failNode BackupObjects)
      reportConverged report `shouldBe` False
      reportFailed report `shouldBe` [BackupObjects]
      verdictOf report BackupPrefixAbsenceProof `shouldBe` Just (NodeBlocked [BackupObjects])
      (SharedObjectBucket `elem` reportBlocked report) `shouldBe` True
      -- Independent SES and TLS-object work still completed.
      verdictOf report SesProviderStack `shouldBe` Just NodeSucceeded
      verdictOf report TlsRetainedObjects `shouldBe` Just NodeSucceeded
    it "blocks only the terminal shared bucket when the all-prefix proof fails" $ do
      let report = run fullInventory (failNode BackupPrefixAbsenceProof)
      reportConverged report `shouldBe` False
      reportFailed report `shouldBe` [BackupPrefixAbsenceProof]
      verdictOf report BackupObjects `shouldBe` Just NodeSucceeded
      (SharedObjectBucket `elem` reportBlocked report) `shouldBe` True
    it "blocks post-custody TLS and backup deletion when the SES branch fails" $ do
      let report = run fullInventory (failNode SesProviderStack)
      reportConverged report `shouldBe` False
      reportFailed report `shouldBe` [SesProviderStack]
      -- SES tombstones depend on the failed provider destroy and are blocked.
      verdictOf report RetainedCustody
        `shouldBe` Just (NodeBlocked [SesProviderStack, targetNode])
      verdictOf report targetNode `shouldBe` Just (NodeBlocked [SesProviderStack])
      -- TLS may begin only after the live-Agent custody tombstone, so the
      -- post-control-plane tail is transitively blocked.
      verdictOf report TlsRetainedObjects `shouldBe` Just (NodeBlocked [RetainedCustody])
      verdictOf report TlsRetentionIdentity `shouldBe` Just (NodeBlocked [RetainedCustody])
      verdictOf report BackupObjects
        `shouldBe` Just (NodeBlocked [TlsRetainedObjects, TlsRetentionIdentity])
      verdictOf report BackupPrefixAbsenceProof `shouldBe` Just (NodeBlocked [BackupObjects])
      -- The shared bucket depends on every node, so any failure blocks it.
      (SharedObjectBucket `elem` reportBlocked report) `shouldBe` True
    it "requires every live Target Agent generation tombstone before retained custody" $ do
      let report = run fullInventory (failNode targetNode)
      reportFailed report `shouldBe` [targetNode]
      verdictOf report RetainedCustody
        `shouldBe` Just (NodeBlocked [targetNode])
      verdictOf report TlsRetainedObjects `shouldBe` Just (NodeBlocked [RetainedCustody])
    it "requires both disjoint TLS deletions before Authority backup deletion" $ do
      let objectsFailure = run fullInventory (failNode TlsRetainedObjects)
          identityFailure = run fullInventory (failNode TlsRetentionIdentity)
      verdictOf objectsFailure BackupObjects
        `shouldBe` Just (NodeBlocked [TlsRetainedObjects])
      verdictOf identityFailure BackupObjects
        `shouldBe` Just (NodeBlocked [TlsRetentionIdentity])
 where
  fullInventory =
    [ SesConsumerQuiescence
    , SesProviderStack
    , SesSmtpIam
    , targetNode
    , RetainedCustody
    , TlsRetainedObjects
    , TlsRetentionIdentity
    , BackupPrefixAbsenceProof
    , BackupObjects
    , SharedObjectBucket
    , FinalNoRetentionAudit
    , HomeSubstrateUninstall
    , LocalDataDisposition DeleteLocalData
    , DecommissionTerminalReceipt
    ]

  targetNode = TargetGeneration "vscode" targetGeneration

targetGeneration :: DecommissionTargetGeneration
targetGeneration = case mkDecommissionTargetGeneration 7 of
  Right generation -> generation
  Left err -> error ("invalid graph fixture generation: " <> show err)

run :: [DecommissionNode] -> (DecommissionNode -> Identity (Either Text ())) -> DecommissionReport
run nodes interpreter = runIdentity (runDecommissionGraph nodes interpreter)

alwaysSucceed :: DecommissionNode -> Identity (Either Text ())
alwaysSucceed _ = pure (Right ())

failNode :: DecommissionNode -> DecommissionNode -> Identity (Either Text ())
failNode target node = pure (if node == target then Left "injected failure" else Right ())

verdictOf :: DecommissionReport -> DecommissionNode -> Maybe NodeVerdict
verdictOf report node =
  executedVerdict <$> find ((== node) . executedNode) (reportExecutions report)
