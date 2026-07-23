{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityGenesis
  ( lifecycleAuthorityGenesisSuite
  )
where

import Prodbox.Lifecycle.Authority.Genesis
import TestSupport

lifecycleAuthorityGenesisSuite :: SuiteBuilder ()
lifecycleAuthorityGenesisSuite =
  describe "Sprint 4.48 Lifecycle Authority genesis admission fold" $ do
    it "starts frozen and refuses normal operations until backup is established" $ do
      admitsNormalOperations initialGenesisState `shouldBe` False
      establishedEpoch initialGenesisState `shouldBe` Nothing

    it "begins establishment from frozen and refuses receipts before establishment" $ do
      decideGenesis GenesisFrozen (BeginGenesisEstablishment samplePlan)
        `shouldBe` GenesisBeginEstablishment samplePlan
      decideGenesis GenesisFrozen (ObserveBackupReceipt (BackupReceipt "b1"))
        `shouldBe` GenesisRefused GenesisNotEstablishing

    it "does not open normal admission on only one read-back receipt" $ do
      let (_, s1) = stepGenesis GenesisFrozen (BeginGenesisEstablishment samplePlan)
          (d2, s2) = stepGenesis s1 (ObserveBackupReceipt (BackupReceipt "b1"))
      d2 `shouldBe` GenesisRecordReceipt (BackupReceiptRecorded (BackupReceipt "b1"))
      admitsNormalOperations s2 `shouldBe` False

    it "opens normal admission only after BOTH receipts read back, under the genesis epoch" $ do
      let (_, s1) = stepGenesis GenesisFrozen (BeginGenesisEstablishment samplePlan)
          (_, s2) = stepGenesis s1 (ObserveBackupReceipt (BackupReceipt "b1"))
          (d3, s3) = stepGenesis s2 (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "t1"))
      d3
        `shouldBe` GenesisOpenAdmission
          (TargetAgentGenerationRecorded (TargetAgentGenerationReceipt "t1"))
          authorityEpochGenesis
      admitsNormalOperations s3 `shouldBe` True
      establishedEpoch s3 `shouldBe` Just authorityEpochGenesis

    it "is order-independent: target-agent-then-backup also opens admission" $ do
      let (_, s1) = stepGenesis GenesisFrozen (BeginGenesisEstablishment samplePlan)
          (_, s2) = stepGenesis s1 (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "t1"))
          (_, s3) = stepGenesis s2 (ObserveBackupReceipt (BackupReceipt "b1"))
      admitsNormalOperations s3 `shouldBe` True

    it "refuses re-establishment with a different plan and is idempotent on the same plan" $ do
      let (_, s1) = stepGenesis GenesisFrozen (BeginGenesisEstablishment samplePlan)
      decideGenesis s1 (BeginGenesisEstablishment samplePlan)
        `shouldBe` GenesisRefused GenesisAlreadyEstablishing
      decideGenesis s1 (BeginGenesisEstablishment otherPlan)
        `shouldBe` GenesisRefused GenesisPlanMismatch

    it "refuses every genesis command once admission is open" $ do
      let established = BackupEstablished authorityEpochGenesis
      decideGenesis established (BeginGenesisEstablishment samplePlan)
        `shouldBe` GenesisRefused GenesisAlreadyEstablished
      decideGenesis established (ObserveBackupReceipt (BackupReceipt "b1"))
        `shouldBe` GenesisRefused GenesisAlreadyEstablished

    it "evolve is idempotent under replay of an already-applied event" $ do
      let s1 = evolveGenesis GenesisFrozen (GenesisEstablishmentBegun samplePlan)
          s1' = evolveGenesis s1 (GenesisEstablishmentBegun samplePlan)
      s1' `shouldBe` s1
 where
  samplePlan = GenesisPlan "digest-abc" "authority-backup-store/home/genesis"
  otherPlan = GenesisPlan "digest-xyz" "authority-backup-store/home/genesis"
