{-# LANGUAGE OverloadedStrings #-}

module InviteQualification (inviteQualificationSuite) where

import Data.Set qualified as Set
import Prodbox.Test.Qualification.Invite
import TestSupport

inviteQualificationSuite :: SuiteBuilder ()
inviteQualificationSuite =
  describe "Sprint 8.12 invite fault qualification" $ do
    it "accepts only the complete two-substrate invite artifact" $ do
      evidence <- accepted canonicalInviteQualificationFixture
      inviteQualificationAssertions (inviteQualificationInput evidence)
        `shouldBe` Set.fromList [minBound .. maxBound]
    it "requires every invite assertion" $ do
      input <- fixtureInput
      mkInviteQualificationEvidence
        input
          { inviteQualificationAssertions = Set.delete InviteCaptured (inviteQualificationAssertions input)
          }
        `shouldBe` Left (InviteAssertionsMissing (Set.singleton InviteCaptured))
    it "requires every fault exactly once and queryable with cleanup" $ do
      input <- fixtureInput
      mkInviteQualificationEvidence
        input {inviteQualificationFaults = drop 1 (inviteQualificationFaults input)}
        `shouldBe` Left (InviteFaultMissing minBound)
      let firstFault = simulateInviteFault minBound
          rest = drop 1 (inviteQualificationFaults input)
      mkInviteQualificationEvidence input {inviteQualificationFaults = firstFault : firstFault : rest}
        `shouldBe` Left (InviteFaultDuplicate (inviteFaultPoint firstFault))
      mkInviteQualificationEvidence
        input {inviteQualificationFaults = firstFault {inviteFaultCleanupAttempted = False} : rest}
        `shouldBe` Left (InviteFaultCleanupSkipped (inviteFaultPoint firstFault))
    it "requires exact canonical home and AWS aggregate commands" $ do
      input <- fixtureInput
      let wrongHome = InviteSubstrateResult InviteHome "prodbox test all --substrate aws" True True
          canonicalAws = InviteSubstrateResult InviteAws "prodbox test all --substrate aws" True True
      mkInviteQualificationEvidence
        input
          { inviteQualificationSubstrates = [wrongHome, canonicalAws]
          }
        `shouldBe` Left (InviteSubstrateCommandWrong InviteHome "prodbox test all --substrate aws")
    it "requires exact backup restore and RunnerLost takeover evidence" $ do
      input <- fixtureInput
      mkInviteQualificationEvidence input {inviteQualificationExactBackupRestored = False}
        `shouldBe` Left InviteExactBackupRestoreMissing
      mkInviteQualificationEvidence input {inviteQualificationRunnerTakeoverProved = False}
        `shouldBe` Left InviteRunnerTakeoverMissing
    it "rejects prompt, SMTP rotation, EAB reset, generic export, and Authority plaintext" $ do
      input <- fixtureInput
      let restore = inviteQualificationRetainedRestore input
      mkInviteQualificationEvidence
        input {inviteQualificationRetainedRestore = restore {retainedRestoreRequiredAdminPrompt = True}}
        `shouldBe` Left InviteRestoreRequiredPrompt
      mkInviteQualificationEvidence
        input {inviteQualificationRetainedRestore = restore {retainedRestoreRotatedSmtpKey = True}}
        `shouldBe` Left InviteRestoreRotatedSmtp
      mkInviteQualificationEvidence
        input {inviteQualificationRetainedRestore = restore {retainedRestoreResetEab = True}}
        `shouldBe` Left InviteRestoreResetEab
      mkInviteQualificationEvidence
        input {inviteQualificationRetainedRestore = restore {retainedRestoreUsedGenericExport = True}}
        `shouldBe` Left InviteRestoreUsedGenericExport
      mkInviteQualificationEvidence
        input
          { inviteQualificationRetainedRestore = restore {retainedRestoreExposedAuthorityPlaintext = True}
          }
        `shouldBe` Left InviteRestoreExposedAuthorityPlaintext
    it "keeps code-local qualification pending even with a complete fixture" $ do
      evidence <- accepted canonicalInviteQualificationFixture
      codeLocalQualificationStatus evidence `shouldBe` QualificationPendingLiveEvidence
    it "simulates response loss, backup loss, and owner loss with distinct dispositions" $ do
      inviteFaultDisposition (simulateInviteFault InviteFaultProviderWorkerResponseLost)
        `shouldBe` InviteFaultAlreadyApplied
      inviteFaultDisposition (simulateInviteFault InviteFaultBackupPermanentlyLost)
        `shouldBe` InviteFaultFrozenRepairRequired
      inviteFaultDisposition (simulateInviteFault InviteFaultCleanupOwnerLost)
        `shouldBe` InviteFaultCleanupTakenOver

fixtureInput :: IO InviteQualificationInput
fixtureInput = inviteQualificationInput <$> accepted canonicalInviteQualificationFixture

accepted :: (Show err) => Either err value -> IO value
accepted = either (fail . show) pure
