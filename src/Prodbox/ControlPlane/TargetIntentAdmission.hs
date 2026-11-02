{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | The Target issuer consumes writer admission, not the authentication epoch
-- that intentionally remains readable while writers are frozen.
module Prodbox.ControlPlane.TargetIntentAdmission
  ( targetIntentAdmissionFromAggregate
  , readTargetIntentIssuanceAdmission
  , TargetIntentAdmissionProgram (..)
  , TargetIntentAdmissionInterpreter (..)
  , readTargetIntentIssuanceAdmissionForRequest
  , targetIntentRequestMatchesPreparedOutbox
  )
where

import Data.Text (Text)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.Coordinate qualified as Coordinate
import Prodbox.ControlPlane.TargetIntentAuthority
  ( TargetIntentAdmissionObservation (..)
  , TargetIntentIssueRequest (..)
  , TargetIntentWriter (..)
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (AwsAuthorityBackupStore)
  , TargetSecretId (TargetAwsCredential)
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityMigrationMode (..)
  , AuthoritySubmissionGateRefusal (..)
  , activeAuthorityEpoch
  , authorityAggregateAdmission
  , authorityAggregateAuthenticationEpoch
  , authorityAggregateMigration
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (..)
  , BackupRepairPermit (backupRepairPermitDigest)
  , BackupRepairProgress (backupRepairPermit)
  , GenesisProgress (genesisProgressPlan)
  , authorityEpochGenesis
  , authorityEpochValue
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationAuthorityStatus (..)
  , migrationAuthorityStatus
  , migrationNormalAdmissionEpoch
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminCleanupRecoveryProgram (..)
  , AwsAdminPermitKind (..)
  , awsAdminGenesisKindMatches
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentCredentialClass
  , awsAdminPermitIntentDeadline
  , awsAdminPermitIntentKind
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentPlanBinding
  , backupRepairFrozenAuthorityEpoch
  , backupRepairFrozenPlanDigest
  )
import Prodbox.Lifecycle.CredentialProvisioner.FirstReconcileJournal
  ( FirstReconcileJournal
  , firstReconcileJournalCursor
  , firstReconcileJournalPlan
  , firstReconcileJournalPlanIsCompiled
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (AuthorityBackupStoreCredential)
  , FirstReconcilePlanAction (EstablishAuthorityBackupMember)
  , OperatorMaterialAction (InstallOperatorMaterial, RevokeOperatorMaterial, RotateOperatorMaterial)
  , firstReconcilePlanDigest
  , firstReconcilePlanMemberAction
  , firstReconcilePlanMemberDigest
  , firstReconcilePlanMemberIndex
  , firstReconcilePriorReceiptDigest
  , mkFirstReconcilePermitBinding
  , nextFirstReconcileMember
  , operatorMaterialOperationIdText
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( preparedCredentialTargetDeadline
  , preparedCredentialTargetGeneration
  , preparedCredentialTargetId
  , preparedCredentialTargetReceiptDigest
  , preparedCredentialTargetSelectedAgent
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTargetOutbox
  ( PreparedCredentialTargetOutbox
  , preparedCredentialTargetOutboxCanonicalIntent
  , preparedCredentialTargetOutboxObservation
  )
import Prodbox.Lifecycle.TargetCommitIntent (targetValueDigestText)

data TargetIntentAdmissionProgram result where
  ReadTargetWriterAdmission :: TargetIntentAdmissionProgram AuthorityAdmissionAggregate
  ReadGenesisTargetIssuanceEvidence
    :: TargetIntentIssueRequest
    -> TargetIntentAdmissionProgram (PreparedCredentialTargetOutbox, FirstReconcileJournal)
  ReadRepairTargetIssuanceEvidence
    :: TargetIntentIssueRequest -> TargetIntentAdmissionProgram PreparedCredentialTargetOutbox

newtype TargetIntentAdmissionInterpreter m = TargetIntentAdmissionInterpreter
  { runTargetIntentAdmissionProgram
      :: forall result. TargetIntentAdmissionProgram result -> m (Either Text result)
  }

targetIntentAdmissionFromAggregate
  :: AuthorityAdmissionAggregate -> TargetIntentAdmissionObservation
targetIntentAdmissionFromAggregate aggregate = case activeAuthorityEpoch aggregate of
  Right epoch -> TargetIntentAdmissionReady TargetIntentAuthorityWriter (convert epoch)
  Left AuthorityLegacyWriterActive -> legacyTargetIntentAdmission aggregate
  Left refusal -> TargetIntentAdmissionRefused refusal
 where
  convert = Coordinate.AuthorityEpoch . authorityEpochValue

-- The pre-cutover writer remains the sole supported writer until the qualified
-- physical cutover. Its existing Target issuance interval ends at the retained
-- freeze; this branch never admits a prepared/frozen replacement.
legacyTargetIntentAdmission :: AuthorityAdmissionAggregate -> TargetIntentAdmissionObservation
-- LEGACY-ESCAPE[legacy-target-intent-admission]
legacyTargetIntentAdmission aggregate =
  TargetIntentAdmissionReady
    TargetIntentLegacyWriter
    (Coordinate.AuthorityEpoch (authorityEpochValue (authorityAggregateAuthenticationEpoch aggregate)))

readTargetIntentIssuanceAdmission
  :: (Monad m)
  => AuthorityAdmissionRepository m revision
  -> m (Either Text TargetIntentAdmissionObservation)
readTargetIntentIssuanceAdmission repository = do
  observed <- readAuthorityAdmission repository
  pure (targetIntentAdmissionFromAggregate . authorityAdmissionSnapshotState <$> observed)

-- | Recovery is selected from retained purpose, never from a caller flag. An
-- ordinary request remains closed; only the exact backup-store permit may
-- establish or repair the backup that normal admission depends on.
readTargetIntentIssuanceAdmissionForRequest
  :: (Monad m)
  => TargetIntentAdmissionInterpreter m
  -> TargetIntentIssueRequest
  -> m (Either Text TargetIntentAdmissionObservation)
readTargetIntentIssuanceAdmissionForRequest interpreter request = do
  observed <- runTargetIntentAdmissionProgram interpreter ReadTargetWriterAdmission
  case observed of
    Left detail -> pure (Left detail)
    Right aggregate -> case targetIntentAdmissionFromAggregate aggregate of
      admitted@TargetIntentAdmissionReady {} -> pure (Right admitted)
      refused@(TargetIntentAdmissionRefused reason)
        | targetIntentIssueTarget request /= TargetAwsCredential AwsAuthorityBackupStore ->
            pure (Right refused)
        | reason `notElem` [AuthorityGenesisEstablishing, AuthorityBackupRepairFrozen] ->
            pure (Right refused)
        | not (recoveryWriterAllowed aggregate) ->
            pure (Right (TargetIntentAdmissionRefused AuthorityMigrationWritersQuiesced))
        | otherwise -> case reason of
            AuthorityGenesisEstablishing -> do
              evidence <- runTargetIntentAdmissionProgram interpreter (ReadGenesisTargetIssuanceEvidence request)
              pure (genesisAdmission aggregate request refused <$> evidence)
            AuthorityBackupRepairFrozen -> do
              evidence <- runTargetIntentAdmissionProgram interpreter (ReadRepairTargetIssuanceEvidence request)
              pure (repairAdmission aggregate request refused <$> evidence)
            AuthorityGenesisFrozen -> pure (Right refused)
            AuthorityDecommissionAdmissionFrozen -> pure (Right refused)
            AuthorityDecommissionPermanentlyStopped -> pure (Right refused)
            AuthorityLegacyWriterActive -> pure (Right refused)
            AuthorityMigrationWritersQuiesced -> pure (Right refused)
            AuthorityProviderAdmissionCascadeFrozen -> pure (Right refused)
            AuthorityProviderAdmissionCredentialRevoked -> pure (Right refused)
            AuthorityProviderAdmissionCredentialMutationPending -> pure (Right refused)

recoveryWriterAllowed :: AuthorityAdmissionAggregate -> Bool
recoveryWriterAllowed aggregate = case authorityAggregateMigration aggregate of
  AuthorityCleanInstall -> True
  AuthorityMigrationControlled migration -> case migrationAuthorityStatus migration of
    MigrationLegacyWriterActive -> True
    MigrationWritersQuiesced -> False
    MigrationReplacementWriterActive _ -> case migrationNormalAdmissionEpoch migration of
      Nothing -> False
      Just _ -> True

targetIntentRequestMatchesPreparedOutbox
  :: TargetIntentIssueRequest -> PreparedCredentialTargetOutbox -> Bool
targetIntentRequestMatchesPreparedOutbox request outbox =
  preparedCredentialTargetId prepared == targetIntentIssueTarget request
    && preparedCredentialTargetSelectedAgent prepared == targetIntentIssueExpectedAgentIdentity request
    && preparedCredentialTargetGeneration prepared == targetIntentIssueExpectedGeneration request
    && preparedCredentialTargetReceiptDigest prepared == targetIntentIssueExpectedReceiptDigest request
    && case preparedCredentialTargetOutboxCanonicalIntent outbox of
      Nothing -> True
      Just intent ->
        operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent)
          == targetIntentIssueOperationId request
 where
  prepared = preparedCredentialTargetOutboxObservation outbox

genesisAdmission
  :: AuthorityAdmissionAggregate
  -> TargetIntentIssueRequest
  -> TargetIntentAdmissionObservation
  -> (PreparedCredentialTargetOutbox, FirstReconcileJournal)
  -> TargetIntentAdmissionObservation
genesisAdmission aggregate request refused (outbox, journal) =
  case (authorityAggregateAdmission aggregate, preparedCredentialTargetOutboxCanonicalIntent outbox) of
    (EstablishingBackup progress, Just intent)
      | firstReconcileJournalPlanIsCompiled journal
      , targetIntentRequestMatchesPreparedOutbox request outbox
      , awsAdminPermitIntentCredentialClass intent == AuthorityBackupStoreCredential
      , preparedCredentialTargetDeadline (preparedCredentialTargetOutboxObservation outbox)
          == awsAdminPermitIntentDeadline intent
      , Right (Just member) <- nextFirstReconcileMember plan cursor
      , firstReconcilePlanMemberIndex member == 0
      , firstReconcilePlanMemberAction member == EstablishAuthorityBackupMember
      , awsAdminGenesisKindMatches (genesisProgressPlan progress) member intent
      , awsAdminPermitIntentPlanBinding intent
          == Just
            ( mkFirstReconcilePermitBinding
                (firstReconcilePlanDigest plan)
                0
                (firstReconcilePlanMemberDigest member)
                (firstReconcilePriorReceiptDigest cursor)
            )
      , genesisActionMatches (awsAdminPermitIntentKind intent) (awsAdminPermitIntentAction intent) ->
          TargetIntentAdmissionReady
            TargetIntentGenesisBackupWriter
            (Coordinate.AuthorityEpoch (authorityEpochValue authorityEpochGenesis))
    _ -> refused
 where
  plan = firstReconcileJournalPlan journal
  cursor = firstReconcileJournalCursor journal
  genesisActionMatches kind action = case kind of
    GenesisBackupKind _ -> action == InstallOperatorMaterial
    CleanupRecoveryKind (GenesisBackupCleanupProgram _) _ -> action == RevokeOperatorMaterial
    NormalOperatorMaterialKind -> False
    BackupRepairFrozenKind _ -> False
    CleanupRecoveryKind NormalOperatorMaterialCleanupProgram _ -> False

repairAdmission
  :: AuthorityAdmissionAggregate
  -> TargetIntentIssueRequest
  -> TargetIntentAdmissionObservation
  -> PreparedCredentialTargetOutbox
  -> TargetIntentAdmissionObservation
repairAdmission aggregate request refused outbox =
  case (authorityAggregateAdmission aggregate, preparedCredentialTargetOutboxCanonicalIntent outbox) of
    (BackupRepairFrozen epoch progress, Just intent)
      | Just retained <- backupRepairPermit progress
      , BackupRepairFrozenKind binding <- awsAdminPermitIntentKind intent
      , targetIntentRequestMatchesPreparedOutbox request outbox
      , awsAdminPermitIntentCredentialClass intent == AuthorityBackupStoreCredential
      , awsAdminPermitIntentAction intent == RotateOperatorMaterial
      , backupRepairFrozenAuthorityEpoch binding == authorityEpochValue epoch
      , targetValueDigestText (backupRepairFrozenPlanDigest binding) == backupRepairPermitDigest retained
      , preparedCredentialTargetDeadline (preparedCredentialTargetOutboxObservation outbox)
          == awsAdminPermitIntentDeadline intent ->
          TargetIntentAdmissionReady
            TargetIntentBackupRepairWriter
            (Coordinate.AuthorityEpoch (authorityEpochValue epoch))
    _ -> refused
