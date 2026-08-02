{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed, action-indexed execution vocabulary for the Admin Action Runner.
--
-- The constructors for each action interpreter are intentionally opaque.  The
-- runner can execute exactly one of the three 'AdminAction' constructors and
-- cannot acquire a credential-provisioning, provider-work, or general
-- decommission capability through this module.
module Prodbox.Lifecycle.AdminAction.Execution
  ( AdminAbsenceObservation (..)
  , AdminResultObservation (..)
  , AdminActionExecutionError (..)
  , DestroyAwsSesInterpreter
  , mkDestroyAwsSesInterpreter
  , MigrateLegacyBackendInterpreter
  , mkMigrateLegacyBackendInterpreter
  , ReconcileQuotaInterpreter
  , mkReconcileQuotaInterpreter
  , AdminActionInterpreters
  , mkAdminActionInterpreters
  , executeSignedAdminAction
  )
where

import Codec.Serialise (Serialise)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminActionPlan (..)
  , AdminActionReadBack (..)
  , AdminActionReceipt
  , AdminDestroyAwsSesPlan
  , AdminDestroyReadBack (..)
  , AdminLegacyBackendPlan
  , AdminLegacyMigrationReadBack
  , AdminQuotaItemReadBack
  , AdminQuotaRequest
  , AdminTargetGenerationReadBack
  , SignedAdminActionPermit
  , adminActionPermitOperationId
  , adminActionPermitPlan
  , mkAdminActionReceipt
  , signedAdminActionPermitCore
  )

-- | Authoritative read-back for an exact absence-converging boundary.
data AdminAbsenceObservation
  = AdminObservedAbsent !Text
  | AdminObservedPresent !Text
  | AdminObservationUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Authoritative read-back for an idempotent result-producing boundary.
data AdminResultObservation result
  = AdminResultCompleted !result
  | AdminResultPending !Text
  | AdminResultUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionExecutionError
  = AdminActionObservationFailed !Text !Text
  | AdminActionMutationFailed !Text !Text
  | AdminActionReadBackFailed !Text !Text
  | AdminActionReceiptFailed !Text
  deriving stock (Eq, Show)

-- The five exact DestroyAwsSes families are fields rather than a list or a
-- generic capability registry.  Consumer and provider stages are deliberately
-- observation-only: their quiescence/desired-absence mutations are committed
-- to their owning runtimes before this permit can advance.  The Admin Runner
-- mutates only legacy SMTP IAM and the two live-Agent tombstone families.
data DestroyAwsSesInterpreter m = DestroyAwsSesInterpreter
  { observeAdminSesConsumers :: AdminDestroyAwsSesPlan -> Text -> m AdminAbsenceObservation
  , observeAdminSesProvider :: AdminDestroyAwsSesPlan -> Text -> m AdminAbsenceObservation
  , observeAdminSesSmtpIam :: AdminDestroyAwsSesPlan -> Text -> m AdminAbsenceObservation
  , destroyAdminSesSmtpIam :: AdminDestroyAwsSesPlan -> Text -> m (Either Text ())
  , observeAdminTargetGenerations
      :: AdminDestroyAwsSesPlan
      -> Text
      -> m (AdminResultObservation [AdminTargetGenerationReadBack])
  , tombstoneAdminTargetGenerations :: AdminDestroyAwsSesPlan -> Text -> m (Either Text ())
  , observeAdminRetainedCustody :: AdminDestroyAwsSesPlan -> Text -> m AdminAbsenceObservation
  , tombstoneAdminRetainedCustody :: AdminDestroyAwsSesPlan -> Text -> m (Either Text ())
  }

mkDestroyAwsSesInterpreter
  :: (AdminDestroyAwsSesPlan -> Text -> m AdminAbsenceObservation)
  -> (AdminDestroyAwsSesPlan -> Text -> m AdminAbsenceObservation)
  -> (AdminDestroyAwsSesPlan -> Text -> m AdminAbsenceObservation)
  -> (AdminDestroyAwsSesPlan -> Text -> m (Either Text ()))
  -> ( AdminDestroyAwsSesPlan
       -> Text
       -> m (AdminResultObservation [AdminTargetGenerationReadBack])
     )
  -> (AdminDestroyAwsSesPlan -> Text -> m (Either Text ()))
  -> (AdminDestroyAwsSesPlan -> Text -> m AdminAbsenceObservation)
  -> (AdminDestroyAwsSesPlan -> Text -> m (Either Text ()))
  -> DestroyAwsSesInterpreter m
mkDestroyAwsSesInterpreter = DestroyAwsSesInterpreter

data MigrateLegacyBackendInterpreter m = MigrateLegacyBackendInterpreter
  { observeAdminLegacyMigration
      :: AdminLegacyBackendPlan
      -> Text
      -> m (AdminResultObservation AdminLegacyMigrationReadBack)
  , applyAdminLegacyMigration :: AdminLegacyBackendPlan -> Text -> m (Either Text ())
  }

mkMigrateLegacyBackendInterpreter
  :: (AdminLegacyBackendPlan -> Text -> m (AdminResultObservation AdminLegacyMigrationReadBack))
  -> (AdminLegacyBackendPlan -> Text -> m (Either Text ()))
  -> MigrateLegacyBackendInterpreter m
mkMigrateLegacyBackendInterpreter = MigrateLegacyBackendInterpreter

data ReconcileQuotaInterpreter m = ReconcileQuotaInterpreter
  { observeAdminQuotaReconcile
      :: [AdminQuotaRequest]
      -> Text
      -> m (AdminResultObservation [AdminQuotaItemReadBack])
  , applyAdminQuotaReconcile :: [AdminQuotaRequest] -> Text -> m (Either Text ())
  }

mkReconcileQuotaInterpreter
  :: ([AdminQuotaRequest] -> Text -> m (AdminResultObservation [AdminQuotaItemReadBack]))
  -> ([AdminQuotaRequest] -> Text -> m (Either Text ()))
  -> ReconcileQuotaInterpreter m
mkReconcileQuotaInterpreter = ReconcileQuotaInterpreter

data AdminActionInterpreters m = AdminActionInterpreters
  { adminDestroyAwsSesInterpreter :: !(DestroyAwsSesInterpreter m)
  , adminMigrateLegacyBackendInterpreter :: !(MigrateLegacyBackendInterpreter m)
  , adminReconcileQuotaInterpreter :: !(ReconcileQuotaInterpreter m)
  }

mkAdminActionInterpreters
  :: DestroyAwsSesInterpreter m
  -> MigrateLegacyBackendInterpreter m
  -> ReconcileQuotaInterpreter m
  -> AdminActionInterpreters m
mkAdminActionInterpreters = AdminActionInterpreters

-- | Execute exactly the action named by a signed permit, using its stable
-- operation identity for every observation and mutation.  All mutation paths
-- observe first, and observe again even when the apply response is lost.
executeSignedAdminAction
  :: (Monad m)
  => AdminActionInterpreters m
  -> SignedAdminActionPermit
  -> m (Either AdminActionExecutionError AdminActionReceipt)
executeSignedAdminAction interpreters permit = do
  readBack <- case adminActionPermitPlan core of
    AdminDestroyAwsSesPlanAction plan ->
      executeDestroyAwsSes
        (adminDestroyAwsSesInterpreter interpreters)
        plan
        operationId
    AdminMigrateLegacyBackendPlanAction plan ->
      fmap AdminMigrateLegacyBackendReadBack
        <$> convergeResult
          "legacy-backend-migration"
          operationId
          (observeAdminLegacyMigration migration plan)
          (applyAdminLegacyMigration migration plan)
    AdminReconcileQuotaPlanAction requests ->
      fmap AdminReconcileQuotaReadBack
        <$> convergeResult
          "quota-reconcile"
          operationId
          (observeAdminQuotaReconcile quota requests)
          (applyAdminQuotaReconcile quota requests)
  pure $ do
    result <- readBack
    either
      (Left . AdminActionReceiptFailed . showText)
      Right
      (mkAdminActionReceipt permit result)
 where
  core = signedAdminActionPermitCore permit
  operationId = adminActionPermitOperationId core
  migration = adminMigrateLegacyBackendInterpreter interpreters
  quota = adminReconcileQuotaInterpreter interpreters

executeDestroyAwsSes
  :: (Monad m)
  => DestroyAwsSesInterpreter m
  -> AdminDestroyAwsSesPlan
  -> Text
  -> m (Either AdminActionExecutionError AdminActionReadBack)
executeDestroyAwsSes interpreter plan operationId = do
  consumers <-
    requireAbsent
      "ses-consumers"
      operationId
      (observeAdminSesConsumers interpreter plan)
  case consumers of
    Left err -> pure (Left err)
    Right consumersEvidence -> do
      provider <-
        requireAbsent
          "ses-provider"
          operationId
          (observeAdminSesProvider interpreter plan)
      case provider of
        Left err -> pure (Left err)
        Right providerEvidence -> do
          smtp <-
            convergeAbsent
              "ses-smtp-iam"
              operationId
              (observeAdminSesSmtpIam interpreter plan)
              (destroyAdminSesSmtpIam interpreter plan)
          case smtp of
            Left err -> pure (Left err)
            Right smtpEvidence -> do
              targets <-
                convergeResult
                  "target-generations"
                  operationId
                  (observeAdminTargetGenerations interpreter plan)
                  (tombstoneAdminTargetGenerations interpreter plan)
              case targets of
                Left err -> pure (Left err)
                Right targetEvidence -> do
                  custody <-
                    convergeAbsent
                      "retained-custody"
                      operationId
                      (observeAdminRetainedCustody interpreter plan)
                      (tombstoneAdminRetainedCustody interpreter plan)
                  pure $
                    AdminDestroyAwsSesReadBack
                      . AdminDestroyReadBack
                        consumersEvidence
                        providerEvidence
                        smtpEvidence
                        targetEvidence
                      <$> custody

requireAbsent
  :: (Monad m)
  => Text
  -> Text
  -> (Text -> m AdminAbsenceObservation)
  -> m (Either AdminActionExecutionError Text)
requireAbsent label operationId observe = do
  observed <- observe operationId
  pure $ case observed of
    AdminObservedAbsent evidence -> Right evidence
    AdminObservedPresent detail ->
      Left (AdminActionReadBackFailed label detail)
    AdminObservationUnavailable detail ->
      Left (AdminActionObservationFailed label detail)

convergeAbsent
  :: (Monad m)
  => Text
  -> Text
  -> (Text -> m AdminAbsenceObservation)
  -> (Text -> m (Either Text ()))
  -> m (Either AdminActionExecutionError Text)
convergeAbsent label operationId observe apply = do
  initial <- observe operationId
  case initial of
    AdminObservedAbsent evidence -> pure (Right evidence)
    AdminObservationUnavailable detail ->
      pure (Left (AdminActionObservationFailed label detail))
    AdminObservedPresent _ -> do
      applied <- apply operationId
      final <- observe operationId
      pure $ case final of
        AdminObservedAbsent evidence -> Right evidence
        AdminObservedPresent detail ->
          Left
            ( case applied of
                Left applyDetail -> AdminActionMutationFailed label applyDetail
                Right () -> AdminActionReadBackFailed label detail
            )
        AdminObservationUnavailable detail ->
          Left
            ( case applied of
                Left applyDetail -> AdminActionMutationFailed label applyDetail
                Right () -> AdminActionReadBackFailed label detail
            )

convergeResult
  :: (Monad m)
  => Text
  -> Text
  -> (Text -> m (AdminResultObservation result))
  -> (Text -> m (Either Text ()))
  -> m (Either AdminActionExecutionError result)
convergeResult label operationId observe apply = do
  initial <- observe operationId
  case initial of
    AdminResultCompleted result -> pure (Right result)
    AdminResultUnavailable detail ->
      pure (Left (AdminActionObservationFailed label detail))
    AdminResultPending _ -> do
      applied <- apply operationId
      final <- observe operationId
      pure $ case final of
        AdminResultCompleted result -> Right result
        AdminResultPending detail ->
          Left
            ( case applied of
                Left applyDetail -> AdminActionMutationFailed label applyDetail
                Right () -> AdminActionReadBackFailed label detail
            )
        AdminResultUnavailable detail ->
          Left
            ( case applied of
                Left applyDetail -> AdminActionMutationFailed label applyDetail
                Right () -> AdminActionReadBackFailed label detail
            )

showText :: (Show value) => value -> Text
showText = Text.pack . show
