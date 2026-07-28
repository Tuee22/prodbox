{-# LANGUAGE OverloadedStrings #-}

module DecommissionGraph (decommissionGraphSuite) where

import Data.Functor.Identity (Identity, runIdentity)
import Data.List (find)
import Data.Text (Text)
import Prodbox.Lifecycle.Decommission.Graph
import Prodbox.Lifecycle.Decommission.Manifest (DecommissionNode (..))
import TestSupport

decommissionGraphSuite :: SuiteBuilder ()
decommissionGraphSuite =
  describe "Sprint 4.50 decommission destroy subgraph" $ do
    it "derives an order with the shared bucket last and the SES/TLS/backup chains in sequence" $ do
      sharedBucketIsTerminal fullInventory `shouldBe` True
      tlsPrecedesSharedBucket fullInventory `shouldBe` True
      sesDestroyPrecedesTombstones fullInventory `shouldBe` True
      last (decommissionTopologicalOrder fullInventory) `shouldBe` SharedObjectBucket
    it "runs every node and converges under an all-success interpreter" $ do
      let report = run fullInventory alwaysSucceed
      reportConverged report `shouldBe` True
      length (reportExecutions report) `shouldBe` length fullInventory
      reportFailed report `shouldBe` []
      reportBlocked report `shouldBe` []
    it "blocks the shared bucket and downstream when a backup node fails" $ do
      let report = run fullInventory (failNode BackupPrefixAbsenceProof)
      reportConverged report `shouldBe` False
      reportFailed report `shouldBe` [BackupPrefixAbsenceProof]
      verdictOf report BackupObjects `shouldBe` Just (NodeBlocked [BackupPrefixAbsenceProof])
      (SharedObjectBucket `elem` reportBlocked report) `shouldBe` True
      -- Independent SES and TLS-object work still completed.
      verdictOf report SesProviderStack `shouldBe` Just NodeSucceeded
      verdictOf report TlsRetainedObjects `shouldBe` Just NodeSucceeded
    it "keeps the independent TLS/backup branch alive when the SES branch fails" $ do
      let report = run fullInventory (failNode SesProviderStack)
      reportConverged report `shouldBe` False
      reportFailed report `shouldBe` [SesProviderStack]
      -- SES tombstones depend on the failed provider destroy and are blocked.
      verdictOf report RetainedCustody `shouldBe` Just (NodeBlocked [SesProviderStack])
      verdictOf report (TargetGeneration "vscode") `shouldBe` Just (NodeBlocked [SesProviderStack])
      -- The whole TLS -> backup chain is independent of SES and still succeeds.
      verdictOf report TlsRetainedObjects `shouldBe` Just NodeSucceeded
      verdictOf report BackupPrefixAbsenceProof `shouldBe` Just NodeSucceeded
      verdictOf report BackupObjects `shouldBe` Just NodeSucceeded
      -- The shared bucket depends on every node, so any failure blocks it.
      (SharedObjectBucket `elem` reportBlocked report) `shouldBe` True
 where
  fullInventory =
    [ SesConsumerQuiescence
    , SesProviderStack
    , SesSmtpIam
    , TargetGeneration "vscode"
    , RetainedCustody
    , TlsRetainedObjects
    , TlsRetentionIdentity
    , BackupPrefixAbsenceProof
    , BackupObjects
    , SharedObjectBucket
    ]

run :: [DecommissionNode] -> (DecommissionNode -> Identity (Either Text ())) -> DecommissionReport
run nodes interpreter = runIdentity (runDecommissionGraph nodes interpreter)

alwaysSucceed :: DecommissionNode -> Identity (Either Text ())
alwaysSucceed _ = pure (Right ())

failNode :: DecommissionNode -> DecommissionNode -> Identity (Either Text ())
failNode target node = pure (if node == target then Left "injected failure" else Right ())

verdictOf :: DecommissionReport -> DecommissionNode -> Maybe NodeVerdict
verdictOf report node =
  executedVerdict <$> find ((== node) . executedNode) (reportExecutions report)
