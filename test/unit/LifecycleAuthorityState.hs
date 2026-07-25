{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityState
  ( lifecycleAuthorityStateSuite
  )
where

import Data.Text (Text)
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityGenesisCommand (..)
  , BackupReceipt (..)
  , GenesisPlan (..)
  , TargetAgentGenerationReceipt (..)
  , authorityEpochGenesis
  )
import Prodbox.Lifecycle.Authority.Operation (OperationPhase (..))
import Prodbox.Lifecycle.Authority.State
import TestSupport

lifecycleAuthorityStateSuite :: SuiteBuilder ()
lifecycleAuthorityStateSuite =
  describe "Sprint 4.48 Lifecycle Authority aggregate (admission-gated operation journal)" $ do
    it "refuses to admit operations before genesis opens admission" $ do
      authorityAdmitsOperations frozen `shouldBe` False
      fst (stepAuthority frozen (AuthorityAdmitOperation "op-1" "intent-a"))
        `shouldBe` AuthorityOperationRefused OperationRefusedAdmissionClosed

    it "drives genesis to open admission, then admits a fenced operation" $ do
      let opened = openedAuthority
      authorityAdmitsOperations opened `shouldBe` True
      let (d, s) = stepAuthority opened (AuthorityAdmitOperation "op-1" "intent-a")
      d `shouldBe` AuthorityOperationArmed "op-1" authorityEpochGenesis "intent-a"
      authorityOperationPhase "op-1" s `shouldBe` Just (OperationArmed "intent-a")

    it "is idempotent on re-admitting the same binding+intent, conflicts on a different intent" $ do
      let (_, s) = stepAuthority openedAuthority (AuthorityAdmitOperation "op-1" "intent-a")
      fst (stepAuthority s (AuthorityAdmitOperation "op-1" "intent-a"))
        `shouldBe` AuthorityOperationAlreadyArmed "op-1" authorityEpochGenesis "intent-a"
      fst (stepAuthority s (AuthorityAdmitOperation "op-1" "intent-b"))
        `shouldBe` AuthorityOperationRefused OperationRefusedBindingIntentConflict

    it "completes an armed operation and is idempotent / conflict-checked on re-complete" $ do
      let (_, armed) = stepAuthority openedAuthority (AuthorityAdmitOperation "op-1" "intent-a")
          (d, done) = stepAuthority armed (AuthorityCompleteOperation "op-1" "result-x")
      d `shouldBe` AuthorityOperationCompleted "op-1" "result-x"
      authorityOperationPhase "op-1" done `shouldBe` Just (OperationCompleted "result-x")
      fst (stepAuthority done (AuthorityCompleteOperation "op-1" "result-x"))
        `shouldBe` AuthorityOperationAlreadyComplete "op-1" "result-x"
      fst (stepAuthority done (AuthorityCompleteOperation "op-1" "result-y"))
        `shouldBe` AuthorityOperationRefused OperationRefusedResultConflict

    it "refuses to complete an unknown operation" $
      fst (stepAuthority openedAuthority (AuthorityCompleteOperation "ghost" "result-x"))
        `shouldBe` AuthorityOperationRefused OperationRefusedUnknownBinding

    it "evolveAuthority replays decision events consistently with stepAuthority" $ do
      let command = AuthorityAdmitOperation "op-1" "intent-a"
          (decision, stepped) = stepAuthority openedAuthority command
          replayed = foldl evolveAuthority openedAuthority (authorityDecisionEvents decision)
      replayed `shouldBe` stepped
 where
  frozen :: AuthorityState Text Text Text
  frozen = initialAuthorityState
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
