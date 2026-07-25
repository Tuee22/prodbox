{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityBackupRepair
  ( lifecycleAuthorityBackupRepairSuite
  )
where

import Data.Text (Text)
import Prodbox.Lifecycle.Authority.BackupRepair
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (..)
  , AuthorityGenesisCommand (..)
  , BackupReceipt (..)
  , BackupRepairPermit (..)
  , GenesisPlan (..)
  , GenesisProgress (..)
  , TargetAgentGenerationReceipt (..)
  , admitsNormalOperations
  , authorityEpochGenesis
  , establishedEpoch
  , initialGenesisState
  , nextAuthorityEpoch
  )
import Prodbox.Lifecycle.Authority.Operation (OperationPhase (..))
import Prodbox.Lifecycle.Authority.State
import TestSupport

lifecycleAuthorityBackupRepairSuite :: SuiteBuilder ()
lifecycleAuthorityBackupRepairSuite =
  describe "Sprint 4.48 Lifecycle Authority backup-repair reopen fold" $ do
    it "refuses every repair command before genesis establishes the authority" $ do
      decideBackupRepair initialGenesisState (AssessBackupHealth BackupPositivelyAbsent)
        `shouldBe` BackupRepairRefused BackupRepairBeforeGenesis
      decideBackupRepair
        (EstablishingBackup establishingProgress)
        (BeginBackupRepair samplePermit)
        `shouldBe` BackupRepairRefused BackupRepairBeforeGenesis

    it "a healthy backup while established is a no-op and keeps admission open" $ do
      decideBackupRepair established1 (AssessBackupHealth BackupHealthy)
        `shouldBe` BackupRepairNotNeeded
      let (_, s) = stepBackupRepair established1 (AssessBackupHealth BackupHealthy)
      admitsNormalOperations s `shouldBe` True

    it "any non-healthy reading from established freezes admission" $ do
      decideBackupRepair established1 (AssessBackupHealth BackupTemporarilyUnavailable)
        `shouldBe` BackupRepairFroze (BackupRepairAdmissionFrozen authorityEpochGenesis)
      let (_, s) = stepBackupRepair established1 (AssessBackupHealth BackupTemporarilyUnavailable)
      admitsNormalOperations s `shouldBe` False

    it "a temporary outage freezes and a later healthy reading reopens under the next epoch" $ do
      let (_, frozen) = stepBackupRepair established1 (AssessBackupHealth BackupTemporarilyUnavailable)
      admitsNormalOperations frozen `shouldBe` False
      let (d, reopened) = stepBackupRepair frozen (AssessBackupHealth BackupHealthy)
      d `shouldBe` BackupRepairReopen [BackupRepairAdmissionReopened epoch2] epoch2
      admitsNormalOperations reopened `shouldBe` True
      establishedEpoch reopened `shouldBe` Just epoch2

    it "an unobservable backup keeps admission frozen and merely waits" $ do
      let (_, frozen) = stepBackupRepair established1 (AssessBackupHealth BackupUnobservable)
          (d, still) = stepBackupRepair frozen (AssessBackupHealth BackupUnobservable)
      d `shouldBe` BackupRepairWait
      admitsNormalOperations still `shouldBe` False
      still `shouldBe` frozen

    it "positive absence runs the full repair and reopens under a strictly greater epoch" $ do
      let (_, s1) = stepBackupRepair established1 (AssessBackupHealth BackupPositivelyAbsent)
          (dPermit, s2) = stepBackupRepair s1 (BeginBackupRepair samplePermit)
      dPermit `shouldBe` BackupRepairPermitMinted (BackupRepairPermitRecorded samplePermit)
      admitsNormalOperations s2 `shouldBe` False
      let (_, s3) = stepBackupRepair s2 (ObserveRepairGeneration nextGeneration)
      admitsNormalOperations s3 `shouldBe` False
      let (d4, s4) = stepBackupRepair s3 (ObserveRepairNewBackupReceipt newReceipt)
      d4
        `shouldBe` BackupRepairReopen
          [BackupRepairNewBackupReceiptRecorded newReceipt, BackupRepairAdmissionReopened epoch2]
          epoch2
      admitsNormalOperations s4 `shouldBe` True
      establishedEpoch s4 `shouldBe` Just epoch2

    it "policy drift runs the same repair path (receipt order-independent)" $ do
      let (_, s1) = stepBackupRepair established1 (AssessBackupHealth BackupPolicyDrift)
          (_, s2) = stepBackupRepair s1 (BeginBackupRepair samplePermit)
          -- new backup receipt observed BEFORE the generation receipt
          (_, s3) = stepBackupRepair s2 (ObserveRepairNewBackupReceipt newReceipt)
          (d4, s4) = stepBackupRepair s3 (ObserveRepairGeneration nextGeneration)
      d4
        `shouldBe` BackupRepairReopen
          [BackupRepairGenerationRecorded nextGeneration, BackupRepairAdmissionReopened epoch2]
          epoch2
      admitsNormalOperations s4 `shouldBe` True
      establishedEpoch s4 `shouldBe` Just epoch2

    it "refuses a repair receipt before the one-time permit is minted" $ do
      let (_, frozen) = stepBackupRepair established1 (AssessBackupHealth BackupPositivelyAbsent)
      decideBackupRepair frozen (ObserveRepairGeneration nextGeneration)
        `shouldBe` BackupRepairRefused BackupRepairPermitAbsent

    it "the one-time permit is idempotent on replay and refuses a divergent permit" $ do
      let (_, frozen) = stepBackupRepair established1 (AssessBackupHealth BackupPositivelyAbsent)
          (_, minted) = stepBackupRepair frozen (BeginBackupRepair samplePermit)
      decideBackupRepair minted (BeginBackupRepair samplePermit)
        `shouldBe` BackupRepairPermitAlreadyMinted
      decideBackupRepair minted (BeginBackupRepair otherPermit)
        `shouldBe` BackupRepairRefused BackupRepairPermitMismatch

    it "re-observing the same receipt after a lost response is idempotent" $ do
      let (_, frozen) = stepBackupRepair established1 (AssessBackupHealth BackupPositivelyAbsent)
          (_, minted) = stepBackupRepair frozen (BeginBackupRepair samplePermit)
          (_, once) = stepBackupRepair minted (ObserveRepairGeneration nextGeneration)
          (_, twice) = stepBackupRepair once (ObserveRepairGeneration nextGeneration)
      twice `shouldBe` once

    it "evolveBackupRepair replays decision events consistently with stepBackupRepair" $ do
      let command = AssessBackupHealth BackupPositivelyAbsent
          (decision, stepped) = stepBackupRepair established1 command
          replayed = foldl evolveBackupRepair established1 (backupRepairDecisionEvents decision)
      replayed `shouldBe` stepped

    it "the aggregate freezes admission during repair and reopens operations under the greater epoch" $ do
      let frozenMid =
            snd
              (stepAuthority openedAuthority (AuthorityBackupRepair (AssessBackupHealth BackupPositivelyAbsent)))
      -- no new operation is admitted while the repair freeze holds
      fst (stepAuthority frozenMid (AuthorityAdmitOperation "op-frozen" "intent-a"))
        `shouldBe` AuthorityOperationRefused OperationRefusedAdmissionClosed
      let repaired = foldl (\s c -> snd (stepAuthority s c)) openedAuthority repairSteps
      authorityAdmitsOperations repaired `shouldBe` True
      let (d, s') = stepAuthority repaired (AuthorityAdmitOperation "op-2" "intent-a")
      d `shouldBe` AuthorityOperationArmed "op-2" epoch2 "intent-a"
      authorityOperationPhase "op-2" s' `shouldBe` Just (OperationArmed "intent-a")
 where
  established1 = BackupEstablished authorityEpochGenesis
  epoch2 = nextAuthorityEpoch authorityEpochGenesis
  establishingProgress = GenesisProgress (GenesisPlan "d" "c") Nothing Nothing
  samplePermit = BackupRepairPermit "repair-digest" "authority-backup-store/home/repair"
  otherPermit = BackupRepairPermit "repair-digest-2" "authority-backup-store/home/repair"
  nextGeneration = TargetAgentGenerationReceipt "gen-2"
  newReceipt = BackupReceipt "backup-2"
  repairSteps =
    [ AuthorityBackupRepair (AssessBackupHealth BackupPositivelyAbsent)
    , AuthorityBackupRepair (BeginBackupRepair samplePermit)
    , AuthorityBackupRepair (ObserveRepairGeneration nextGeneration)
    , AuthorityBackupRepair (ObserveRepairNewBackupReceipt newReceipt)
    ]
  openedAuthority :: AuthorityState Text Text Text
  openedAuthority =
    let s0 = initialAuthorityState
        (_, s1) = stepAuthority s0 (AuthorityGenesis (BeginGenesisEstablishment (GenesisPlan "d" "c")))
        (_, s2) = stepAuthority s1 (AuthorityGenesis (ObserveBackupReceipt (BackupReceipt "b1")))
        (_, s3) =
          stepAuthority
            s2
            (AuthorityGenesis (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "t1")))
     in s3
