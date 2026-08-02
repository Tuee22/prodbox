{-# LANGUAGE OverloadedStrings #-}

module DecommissionGraph (decommissionGraphSuite) where

import Data.Functor.Identity (Identity, runIdentity)
import Data.List (find)
import Data.Text (Text)
import Prodbox.Lifecycle.Decommission.Graph
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionNode (..)
  , DecommissionTargetGeneration
  , mkDecommissionTargetGeneration
  )
import TestSupport

decommissionGraphSuite :: SuiteBuilder ()
decommissionGraphSuite =
  describe "Sprint 4.50 decommission destroy subgraph" $ do
    it "derives an order with the shared bucket last and the SES/TLS/backup chains in sequence" $ do
      sharedBucketIsTerminal fullInventory `shouldBe` True
      tlsPrecedesSharedBucket fullInventory `shouldBe` True
      sesDestroyPrecedesTombstones fullInventory `shouldBe` True
      targetTombstonesPrecedeCustody fullInventory `shouldBe` True
      custodyPrecedesTls fullInventory `shouldBe` True
      tlsPrecedesBackup fullInventory `shouldBe` True
      allPrefixesProvenBeforeSharedBucket fullInventory `shouldBe` True
      last (decommissionTopologicalOrder fullInventory) `shouldBe` SharedObjectBucket
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
