{-# LANGUAGE OverloadedStrings #-}

-- | Restart-safe orchestration for the Authority's exceptional bootstrap and
-- backup-repair lanes.  The effect boundary contains only typed observations,
-- control submissions, and the two receipt-producing interpreters.  Normal
-- lifecycle work is deliberately absent from this vocabulary.
module Prodbox.Lifecycle.Authority.BootstrapReconcile
  ( AuthorityBackupReconcileBoundary (..)
  , AuthorityBackupReconcileOutcome (..)
  , AuthorityBackupReconcileError (..)
  , reconcileAuthorityBackupAdmission
  )
where

import Data.Text (Text)
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionCommand (..)
  )
import Prodbox.Lifecycle.Authority.BackupRepair
  ( BackupHealth (..)
  , BackupRepairCommand (..)
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (..)
  , AuthorityEpoch
  , AuthorityGenesisCommand (..)
  , BackupReceipt
  , BackupRepairPermit
  , BackupRepairProgress (..)
  , GenesisPlan
  , GenesisProgress (..)
  , TargetAgentGenerationReceipt
  , nextAuthorityEpoch
  )

-- | The only external effects admitted while establishing or repairing the
-- independent Authority backup.  Implementations bind the genesis target
-- action to the Broker's opaque @GenesisBackupPermit@ executor and bind the
-- copy actions to the physically separate Authority Backup Adapter.
data AuthorityBackupReconcileBoundary m = AuthorityBackupReconcileBoundary
  { observeAuthorityAdmissionState
      :: m (Either Text AuthorityAdmissionState)
  , submitAuthorityAdmissionControl
      :: AuthorityAdmissionCommand
      -> m (Either Text ())
  , compileGenesisPlan
      :: m (Either Text GenesisPlan)
  , establishGenesisTargetGeneration
      :: GenesisPlan
      -> m (Either Text TargetAgentGenerationReceipt)
  , copyGenesisAuthorityBackup
      :: GenesisPlan
      -> m (Either Text BackupReceipt)
  , observeAuthorityBackupHealth
      :: BackupReceipt
      -> m (Either Text BackupHealth)
  , mintAuthorityBackupRepairPermit
      :: AuthorityEpoch
      -> TargetAgentGenerationReceipt
      -> BackupReceipt
      -> m (Either Text BackupRepairPermit)
  , establishRepairTargetGeneration
      :: BackupRepairPermit
      -> m (Either Text TargetAgentGenerationReceipt)
  , copyRepairedAuthorityBackup
      :: BackupRepairPermit
      -> m (Either Text BackupReceipt)
  }

data AuthorityBackupReconcileOutcome
  = AuthorityBackupAdmissionReady !AuthorityEpoch
  | AuthorityBackupAdmissionFrozen !AuthorityEpoch !BackupHealth
  deriving (Eq, Show)

data AuthorityBackupReconcileError
  = AuthorityBackupObservationFailed !Text
  | AuthorityBackupPlanFailed !Text
  | AuthorityBackupGenesisTargetFailed !Text
  | AuthorityBackupGenesisCopyFailed !Text
  | AuthorityBackupHealthObservationFailed !Text
  | AuthorityBackupRepairPermitFailed !Text
  | AuthorityBackupRepairTargetFailed !Text
  | AuthorityBackupRepairCopyFailed !Text
  | AuthorityBackupControlFailed !Text !Text
  | AuthorityBackupUnexpectedState !Text !AuthorityAdmissionState
  deriving (Eq, Show)

-- | Drive the retained admission projection to either a positively observed
-- open epoch or an explicit temporary/unobservable freeze.  Every control
-- submission is followed by an authoritative observation.  If the response
-- was lost but that observation proves the exact transition, reconciliation
-- continues; a successful response without the expected state does not.
reconcileAuthorityBackupAdmission
  :: (Monad m)
  => AuthorityBackupReconcileBoundary m
  -> m (Either AuthorityBackupReconcileError AuthorityBackupReconcileOutcome)
reconcileAuthorityBackupAdmission boundary = do
  observed <- observeState boundary
  case observed of
    Left err -> pure (Left err)
    Right state -> reconcileFrom boundary state

reconcileFrom
  :: (Monad m)
  => AuthorityBackupReconcileBoundary m
  -> AuthorityAdmissionState
  -> m (Either AuthorityBackupReconcileError AuthorityBackupReconcileOutcome)
reconcileFrom boundary state = case state of
  GenesisFrozen -> do
    planned <- compileGenesisPlan boundary
    case planned of
      Left detail -> pure (Left (AuthorityBackupPlanFailed detail))
      Right plan -> do
        advanced <-
          submitAndConfirm
            boundary
            "begin genesis backup establishment"
            (ApplyAuthorityGenesis (BeginGenesisEstablishment plan))
            (genesisPlanObserved plan)
        continue advanced
  EstablishingBackup progress -> reconcileGenesis boundary progress
  BackupEstablished epoch _ receipt -> reconcileEstablished boundary epoch receipt
  BackupRepairFrozen epoch progress -> reconcileRepair boundary epoch progress
 where
  continue result = case result of
    Left err -> pure (Left err)
    Right next -> reconcileFrom boundary next

reconcileGenesis
  :: (Monad m)
  => AuthorityBackupReconcileBoundary m
  -> GenesisProgress
  -> m (Either AuthorityBackupReconcileError AuthorityBackupReconcileOutcome)
reconcileGenesis boundary progress =
  case genesisProgressTargetAgentReceipt progress of
    Nothing -> do
      established <-
        establishGenesisTargetGeneration
          boundary
          (genesisProgressPlan progress)
      case established of
        Left detail -> pure (Left (AuthorityBackupGenesisTargetFailed detail))
        Right receipt -> do
          advanced <-
            submitAndConfirm
              boundary
              "record genesis target generation"
              (ApplyAuthorityGenesis (ObserveTargetAgentGeneration receipt))
              (genesisTargetReceiptObserved (genesisProgressPlan progress) receipt)
          continue advanced
    Just _ -> case genesisProgressBackupReceipt progress of
      Nothing -> do
        copied <-
          copyGenesisAuthorityBackup
            boundary
            (genesisProgressPlan progress)
        case copied of
          Left detail -> pure (Left (AuthorityBackupGenesisCopyFailed detail))
          Right receipt -> do
            advanced <-
              submitAndConfirm
                boundary
                "record genesis backup receipt and disable genesis admission"
                (ApplyAuthorityGenesis (ObserveBackupReceipt receipt))
                (genesisBackupReceiptObserved (genesisProgressPlan progress) receipt)
            continue advanced
      Just _ ->
        pure
          ( Left
              ( AuthorityBackupUnexpectedState
                  "genesis contains both receipts but admission did not open"
                  (EstablishingBackup progress)
              )
          )
 where
  continue result = case result of
    Left err -> pure (Left err)
    Right next -> reconcileFrom boundary next

reconcileEstablished
  :: (Monad m)
  => AuthorityBackupReconcileBoundary m
  -> AuthorityEpoch
  -> BackupReceipt
  -> m (Either AuthorityBackupReconcileError AuthorityBackupReconcileOutcome)
reconcileEstablished boundary epoch receipt = do
  observedHealth <- observeAuthorityBackupHealth boundary receipt
  case observedHealth of
    Left detail -> pure (Left (AuthorityBackupHealthObservationFailed detail))
    Right BackupHealthy -> pure (Right (AuthorityBackupAdmissionReady epoch))
    Right health -> do
      frozen <-
        submitAndConfirm
          boundary
          "freeze admission after non-healthy backup observation"
          (ApplyAuthorityBackupRepair (AssessBackupHealth health))
          (backupFreezeObserved epoch)
      case frozen of
        Left err -> pure (Left err)
        Right next -> case health of
          BackupTemporarilyUnavailable ->
            pure (Right (AuthorityBackupAdmissionFrozen epoch health))
          BackupUnobservable ->
            pure (Right (AuthorityBackupAdmissionFrozen epoch health))
          BackupPositivelyAbsent -> reconcileFrom boundary next
          BackupPolicyDrift -> reconcileFrom boundary next

reconcileRepair
  :: (Monad m)
  => AuthorityBackupReconcileBoundary m
  -> AuthorityEpoch
  -> BackupRepairProgress
  -> m (Either AuthorityBackupReconcileError AuthorityBackupReconcileOutcome)
reconcileRepair boundary epoch progress = case backupRepairPermit progress of
  Nothing -> do
    observedHealth <-
      observeAuthorityBackupHealth boundary (backupRepairPreviousReceipt progress)
    case observedHealth of
      Left detail -> pure (Left (AuthorityBackupHealthObservationFailed detail))
      Right BackupTemporarilyUnavailable ->
        pure
          ( Right
              (AuthorityBackupAdmissionFrozen epoch BackupTemporarilyUnavailable)
          )
      Right BackupUnobservable ->
        pure (Right (AuthorityBackupAdmissionFrozen epoch BackupUnobservable))
      Right BackupHealthy -> do
        reopened <-
          submitAndConfirm
            boundary
            "reopen after the backup recovered without repair"
            (ApplyAuthorityBackupRepair (AssessBackupHealth BackupHealthy))
            (backupReopenedObserved epoch)
        continue reopened
      Right BackupPositivelyAbsent -> beginRepair
      Right BackupPolicyDrift -> beginRepair
  Just permit -> case backupRepairGeneration progress of
    Nothing -> do
      established <- establishRepairTargetGeneration boundary permit
      case established of
        Left detail -> pure (Left (AuthorityBackupRepairTargetFailed detail))
        Right receipt -> do
          advanced <-
            submitAndConfirm
              boundary
              "record repaired target generation"
              (ApplyAuthorityBackupRepair (ObserveRepairGeneration receipt))
              (backupRepairGenerationObserved epoch permit receipt)
          continue advanced
    Just _ -> case backupRepairNewReceipt progress of
      Nothing -> do
        copied <- copyRepairedAuthorityBackup boundary permit
        case copied of
          Left detail -> pure (Left (AuthorityBackupRepairCopyFailed detail))
          Right receipt -> do
            advanced <-
              submitAndConfirm
                boundary
                "record repaired backup receipt and reopen admission"
                (ApplyAuthorityBackupRepair (ObserveRepairNewBackupReceipt receipt))
                (backupRepairReceiptObserved epoch permit receipt)
            continue advanced
      Just _ ->
        pure
          ( Left
              ( AuthorityBackupUnexpectedState
                  "repair contains both receipts but admission did not reopen"
                  (BackupRepairFrozen epoch progress)
              )
          )
 where
  beginRepair = do
    minted <-
      mintAuthorityBackupRepairPermit
        boundary
        epoch
        (backupRepairPreviousGeneration progress)
        (backupRepairPreviousReceipt progress)
    case minted of
      Left detail -> pure (Left (AuthorityBackupRepairPermitFailed detail))
      Right permit -> do
        advanced <-
          submitAndConfirm
            boundary
            "record the deterministic backup-repair permit"
            (ApplyAuthorityBackupRepair (BeginBackupRepair permit))
            (backupRepairPermitObserved epoch permit)
        continue advanced
  continue result = case result of
    Left err -> pure (Left err)
    Right next -> reconcileFrom boundary next

submitAndConfirm
  :: (Monad m)
  => AuthorityBackupReconcileBoundary m
  -> Text
  -> AuthorityAdmissionCommand
  -> (AuthorityAdmissionState -> Bool)
  -> m (Either AuthorityBackupReconcileError AuthorityAdmissionState)
submitAndConfirm boundary label command accepts = do
  attempted <- submitAuthorityAdmissionControl boundary command
  observed <- observeState boundary
  pure $ case observed of
    Left err -> Left err
    Right actual
      | accepts actual -> Right actual
      | otherwise -> case attempted of
          Left detail -> Left (AuthorityBackupControlFailed label detail)
          Right () -> Left (AuthorityBackupUnexpectedState label actual)

observeState
  :: (Monad m)
  => AuthorityBackupReconcileBoundary m
  -> m (Either AuthorityBackupReconcileError AuthorityAdmissionState)
observeState boundary =
  fmap
    (either (Left . AuthorityBackupObservationFailed) Right)
    (observeAuthorityAdmissionState boundary)

genesisPlanObserved :: GenesisPlan -> AuthorityAdmissionState -> Bool
genesisPlanObserved plan state = case state of
  EstablishingBackup progress -> genesisProgressPlan progress == plan
  BackupEstablished {} -> True
  BackupRepairFrozen _ _ -> True
  GenesisFrozen -> False

genesisTargetReceiptObserved
  :: GenesisPlan
  -> TargetAgentGenerationReceipt
  -> AuthorityAdmissionState
  -> Bool
genesisTargetReceiptObserved plan receipt state = case state of
  EstablishingBackup progress ->
    genesisProgressPlan progress == plan
      && genesisProgressTargetAgentReceipt progress == Just receipt
  BackupEstablished {} -> True
  BackupRepairFrozen _ _ -> True
  GenesisFrozen -> False

genesisBackupReceiptObserved
  :: GenesisPlan -> BackupReceipt -> AuthorityAdmissionState -> Bool
genesisBackupReceiptObserved plan receipt state = case state of
  EstablishingBackup progress ->
    genesisProgressPlan progress == plan
      && genesisProgressBackupReceipt progress == Just receipt
  BackupEstablished {} -> True
  BackupRepairFrozen _ _ -> True
  GenesisFrozen -> False

backupFreezeObserved :: AuthorityEpoch -> AuthorityAdmissionState -> Bool
backupFreezeObserved epoch state = case state of
  BackupRepairFrozen actual _ -> actual == epoch
  BackupEstablished actual _ _ -> actual >= nextAuthorityEpoch epoch
  GenesisFrozen -> False
  EstablishingBackup _ -> False

backupReopenedObserved :: AuthorityEpoch -> AuthorityAdmissionState -> Bool
backupReopenedObserved epoch state = case state of
  BackupEstablished actual _ _ -> actual == nextAuthorityEpoch epoch
  _ -> False

backupRepairPermitObserved
  :: AuthorityEpoch -> BackupRepairPermit -> AuthorityAdmissionState -> Bool
backupRepairPermitObserved epoch permit state = case state of
  BackupRepairFrozen actual progress ->
    actual == epoch && backupRepairPermit progress == Just permit
  BackupEstablished actual _ _ -> actual >= nextAuthorityEpoch epoch
  GenesisFrozen -> False
  EstablishingBackup _ -> False

backupRepairGenerationObserved
  :: AuthorityEpoch
  -> BackupRepairPermit
  -> TargetAgentGenerationReceipt
  -> AuthorityAdmissionState
  -> Bool
backupRepairGenerationObserved epoch permit receipt state = case state of
  BackupRepairFrozen actual progress ->
    actual == epoch
      && backupRepairPermit progress == Just permit
      && backupRepairGeneration progress == Just receipt
  BackupEstablished actual _ _ -> actual >= nextAuthorityEpoch epoch
  GenesisFrozen -> False
  EstablishingBackup _ -> False

backupRepairReceiptObserved
  :: AuthorityEpoch
  -> BackupRepairPermit
  -> BackupReceipt
  -> AuthorityAdmissionState
  -> Bool
backupRepairReceiptObserved epoch permit receipt state = case state of
  BackupRepairFrozen actual progress ->
    actual == epoch
      && backupRepairPermit progress == Just permit
      && backupRepairNewReceipt progress == Just receipt
  BackupEstablished actual _ _ -> actual == nextAuthorityEpoch epoch
  GenesisFrozen -> False
  EstablishingBackup _ -> False
