{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 8.12 invite-specific qualification extension. Construction is
-- total and requires the complete two-substrate fault/assertion matrix.
module Prodbox.Test.Qualification.Invite
  ( InviteAssertion (..)
  , InviteFaultPoint (..)
  , InviteFaultResult (..)
  , InviteFaultDisposition (..)
  , simulateInviteFault
  , InviteSubstrate (..)
  , InviteSubstrateResult (..)
  , RetainedRestoreEvidence (..)
  , InviteQualificationInput (..)
  , InviteQualificationEvidence
  , InviteQualificationError (..)
  , mkInviteQualificationEvidence
  , canonicalInviteQualificationFixture
  , inviteQualificationInput
  , CodeLocalQualificationStatus (..)
  , codeLocalQualificationStatus
  )
where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

data InviteAssertion
  = InviteSent
  | InviteCaptured
  | InviteLinkFollowed
  | InviteOidcClaimsVerified
  | InviteAuthorityConverged
  | InviteTargetConverged
  | InvitePlatformRestored
  | InvitePerRunResidueAbsent
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data InviteFaultPoint
  = InviteFaultGatewaySaturated
  | InviteFaultGatewayKilled
  | InviteFaultAuthorityBeforeCas
  | InviteFaultAuthorityAfterCasResponseLost
  | InviteFaultTargetAgentRestart
  | InviteFaultAuthorityBackupRestart
  | InviteFaultTlsRetentionRestart
  | InviteFaultProviderWorkerResponseLost
  | InviteFaultCredentialProvisionerPromptBoundary
  | InviteFaultCredentialProvisionerEffectBoundary
  | InviteFaultCredentialProvisionerReadBackBoundary
  | InviteFaultAdminRunnerBoundary
  | InviteFaultVaultDelayed
  | InviteFaultMinioDelayed
  | InviteFaultS3Delayed
  | InviteFaultAwsDelayed
  | InviteFaultBackupUnavailableBeforeEffect
  | InviteFaultBackupPermanentlyLost
  | InviteFaultPrimaryAuthorityLost
  | InviteFaultFreshAwsVault
  | InviteFaultCleanupOwnerLost
  | InviteFaultClientCancelled
  | InviteFaultCleanupFailed
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data InviteFaultResult = InviteFaultResult
  { inviteFaultPoint :: !InviteFaultPoint
  , inviteFaultOperationQueryable :: !Bool
  , inviteFaultDisposition :: !InviteFaultDisposition
  , inviteFaultCleanupAttempted :: !Bool
  }
  deriving stock (Eq, Ord, Show)

data InviteFaultDisposition
  = InviteFaultResumed
  | InviteFaultAlreadyApplied
  | InviteFaultFrozenRepairRequired
  | InviteFaultClosedRefusal
  | InviteFaultCleanupTakenOver
  deriving stock (Eq, Ord, Show)

simulateInviteFault :: InviteFaultPoint -> InviteFaultResult
simulateInviteFault point = InviteFaultResult point True disposition True
 where
  disposition = case point of
    InviteFaultAuthorityAfterCasResponseLost -> InviteFaultAlreadyApplied
    InviteFaultProviderWorkerResponseLost -> InviteFaultAlreadyApplied
    InviteFaultCredentialProvisionerReadBackBoundary -> InviteFaultAlreadyApplied
    InviteFaultBackupUnavailableBeforeEffect -> InviteFaultClosedRefusal
    InviteFaultBackupPermanentlyLost -> InviteFaultFrozenRepairRequired
    InviteFaultCleanupOwnerLost -> InviteFaultCleanupTakenOver
    InviteFaultCleanupFailed -> InviteFaultClosedRefusal
    InviteFaultGatewaySaturated -> InviteFaultResumed
    InviteFaultGatewayKilled -> InviteFaultResumed
    InviteFaultAuthorityBeforeCas -> InviteFaultResumed
    InviteFaultTargetAgentRestart -> InviteFaultResumed
    InviteFaultAuthorityBackupRestart -> InviteFaultResumed
    InviteFaultTlsRetentionRestart -> InviteFaultResumed
    InviteFaultCredentialProvisionerPromptBoundary -> InviteFaultResumed
    InviteFaultCredentialProvisionerEffectBoundary -> InviteFaultResumed
    InviteFaultAdminRunnerBoundary -> InviteFaultResumed
    InviteFaultVaultDelayed -> InviteFaultResumed
    InviteFaultMinioDelayed -> InviteFaultResumed
    InviteFaultS3Delayed -> InviteFaultResumed
    InviteFaultAwsDelayed -> InviteFaultResumed
    InviteFaultPrimaryAuthorityLost -> InviteFaultResumed
    InviteFaultFreshAwsVault -> InviteFaultResumed
    InviteFaultClientCancelled -> InviteFaultResumed

data InviteSubstrate = InviteHome | InviteAws
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data InviteSubstrateResult = InviteSubstrateResult
  { inviteSubstrate :: !InviteSubstrate
  , inviteSubstrateCommand :: !Text
  , inviteSubstrateAggregateSucceeded :: !Bool
  , inviteSubstrateCleanupResidueAbsent :: !Bool
  }
  deriving stock (Eq, Ord, Show)

data RetainedRestoreEvidence = RetainedRestoreEvidence
  { retainedRestoreSesGeneration :: !Text
  , retainedRestoreEabGeneration :: !Text
  , retainedRestoreTlsGeneration :: !Text
  , retainedRestoreRequiredAdminPrompt :: !Bool
  , retainedRestoreRotatedSmtpKey :: !Bool
  , retainedRestoreResetEab :: !Bool
  , retainedRestoreUsedGenericExport :: !Bool
  , retainedRestoreExposedAuthorityPlaintext :: !Bool
  }
  deriving stock (Eq, Show)

data InviteQualificationInput = InviteQualificationInput
  { inviteQualificationAssertions :: !(Set InviteAssertion)
  , inviteQualificationFaults :: ![InviteFaultResult]
  , inviteQualificationSubstrates :: ![InviteSubstrateResult]
  , inviteQualificationAuthorityEpoch :: !Natural
  , inviteQualificationExactBackupRestored :: !Bool
  , inviteQualificationRunnerTakeoverProved :: !Bool
  , inviteQualificationRetainedRestore :: !RetainedRestoreEvidence
  }
  deriving stock (Eq, Show)

newtype InviteQualificationEvidence = InviteQualificationEvidence InviteQualificationInput
  deriving stock (Eq, Show)

inviteQualificationInput :: InviteQualificationEvidence -> InviteQualificationInput
inviteQualificationInput (InviteQualificationEvidence input) = input

data InviteQualificationError
  = InviteAssertionsMissing !(Set InviteAssertion)
  | InviteFaultMissing !InviteFaultPoint
  | InviteFaultDuplicate !InviteFaultPoint
  | InviteFaultNotQueryable !InviteFaultPoint
  | InviteFaultCleanupSkipped !InviteFaultPoint
  | InviteSubstrateMissing !InviteSubstrate
  | InviteSubstrateDuplicate !InviteSubstrate
  | InviteSubstrateCommandWrong !InviteSubstrate !Text
  | InviteSubstrateAggregateFailed !InviteSubstrate
  | InviteSubstrateResiduePresent !InviteSubstrate
  | InviteAuthorityEpochMissing
  | InviteExactBackupRestoreMissing
  | InviteRunnerTakeoverMissing
  | InviteRetainedGenerationMissing !Text
  | InviteRestoreRequiredPrompt
  | InviteRestoreRotatedSmtp
  | InviteRestoreResetEab
  | InviteRestoreUsedGenericExport
  | InviteRestoreExposedAuthorityPlaintext
  deriving stock (Eq, Show)

mkInviteQualificationEvidence
  :: InviteQualificationInput
  -> Either InviteQualificationError InviteQualificationEvidence
mkInviteQualificationEvidence input = do
  let requiredAssertions = Set.fromList [minBound .. maxBound]
      missingAssertions = requiredAssertions `Set.difference` inviteQualificationAssertions input
  require (Set.null missingAssertions) (InviteAssertionsMissing missingAssertions)
  mapM_ validateFault [minBound .. maxBound]
  mapM_ validateFaultResult (inviteQualificationFaults input)
  mapM_ validateSubstrate [minBound .. maxBound]
  require (inviteQualificationAuthorityEpoch input > 0) InviteAuthorityEpochMissing
  require (inviteQualificationExactBackupRestored input) InviteExactBackupRestoreMissing
  require (inviteQualificationRunnerTakeoverProved input) InviteRunnerTakeoverMissing
  validateRestore (inviteQualificationRetainedRestore input)
  pure (InviteQualificationEvidence input)
 where
  validateFault point = case filter ((== point) . inviteFaultPoint) (inviteQualificationFaults input) of
    [] -> Left (InviteFaultMissing point)
    [_] -> Right ()
    _ -> Left (InviteFaultDuplicate point)
  validateFaultResult result = do
    require (inviteFaultOperationQueryable result) (InviteFaultNotQueryable (inviteFaultPoint result))
    require (inviteFaultCleanupAttempted result) (InviteFaultCleanupSkipped (inviteFaultPoint result))
  validateSubstrate substrate = case filter ((== substrate) . inviteSubstrate) (inviteQualificationSubstrates input) of
    [] -> Left (InviteSubstrateMissing substrate)
    [result] -> do
      require
        (inviteSubstrateCommand result == canonicalCommand substrate)
        (InviteSubstrateCommandWrong substrate (inviteSubstrateCommand result))
      require (inviteSubstrateAggregateSucceeded result) (InviteSubstrateAggregateFailed substrate)
      require (inviteSubstrateCleanupResidueAbsent result) (InviteSubstrateResiduePresent substrate)
    _ -> Left (InviteSubstrateDuplicate substrate)

canonicalCommand :: InviteSubstrate -> Text
canonicalCommand InviteHome = "prodbox test all"
canonicalCommand InviteAws = "prodbox test all --substrate aws"

canonicalInviteQualificationFixture
  :: Either InviteQualificationError InviteQualificationEvidence
canonicalInviteQualificationFixture =
  mkInviteQualificationEvidence
    InviteQualificationInput
      { inviteQualificationAssertions = Set.fromList [minBound .. maxBound]
      , inviteQualificationFaults = map simulateInviteFault [minBound .. maxBound]
      , inviteQualificationSubstrates =
          [ InviteSubstrateResult InviteHome (canonicalCommand InviteHome) True True
          , InviteSubstrateResult InviteAws (canonicalCommand InviteAws) True True
          ]
      , inviteQualificationAuthorityEpoch = 1
      , inviteQualificationExactBackupRestored = True
      , inviteQualificationRunnerTakeoverProved = True
      , inviteQualificationRetainedRestore =
          RetainedRestoreEvidence
            "ses-generation-fixture"
            "eab-generation-fixture"
            "tls-generation-fixture"
            False
            False
            False
            False
            False
      }

validateRestore :: RetainedRestoreEvidence -> Either InviteQualificationError ()
validateRestore evidence = do
  requireNonempty "ses-smtp" (retainedRestoreSesGeneration evidence)
  requireNonempty "acme-eab" (retainedRestoreEabGeneration evidence)
  requireNonempty "tls" (retainedRestoreTlsGeneration evidence)
  require (not (retainedRestoreRequiredAdminPrompt evidence)) InviteRestoreRequiredPrompt
  require (not (retainedRestoreRotatedSmtpKey evidence)) InviteRestoreRotatedSmtp
  require (not (retainedRestoreResetEab evidence)) InviteRestoreResetEab
  require (not (retainedRestoreUsedGenericExport evidence)) InviteRestoreUsedGenericExport
  require
    (not (retainedRestoreExposedAuthorityPlaintext evidence))
    InviteRestoreExposedAuthorityPlaintext
 where
  requireNonempty label value = require (not (Text.null (Text.strip value))) (InviteRetainedGenerationMissing label)

require :: Bool -> error -> Either error ()
require condition err = if condition then Right () else Left err

data CodeLocalQualificationStatus = QualificationPendingLiveEvidence
  deriving stock (Eq, Show)

-- Code-local fixtures can validate the recorder but can never manufacture a
-- deployment-qualified result; Standard P requires governed live artifacts.
codeLocalQualificationStatus :: InviteQualificationEvidence -> CodeLocalQualificationStatus
codeLocalQualificationStatus _ = QualificationPendingLiveEvidence
