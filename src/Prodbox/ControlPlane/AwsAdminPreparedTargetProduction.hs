{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production owner of the secret-free AWS-admin prepared-target outbox and
-- first-reconcile continuation.  Preparation derives every authority-owned
-- field from retained admission and journal observations, commits the exact
-- outbox by Model-B CAS, and reads it back before the permit authority may
-- prepare or sign anything.
module Prodbox.ControlPlane.AwsAdminPreparedTargetProduction
  ( FirstReconcileContinuation (..)
  , AwsAdminPreparedTargetLifecycle (..)
  , productionAwsAdminPreparedTargetLifecycle
  )
where

import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (readAuthorityAdmission)
  , AuthorityAdmissionSnapshot (authorityAdmissionSnapshotState)
  )
import Prodbox.ControlPlane.InClusterAuthorityStore
  ( InClusterAuthorityStore
  , inClusterAuthorityModelBCasAdapter
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerReceipt
  , decodeTargetWorkerReceipt
  , targetWorkerReceiptCommitment
  , targetWorkerReceiptVaultVersion
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , authorityAggregateAdmission
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (..)
  , BackupRepairPermit (backupRepairPermitDigest)
  , BackupRepairProgress (backupRepairPermit)
  , GenesisPlan
  , GenesisProgress (genesisProgressPlan)
  , authorityEpochGenesis
  , authorityEpochValue
  , nextAuthorityEpoch
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (ModelBInitialize)
  , ModelBObjectCoordinate
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminWorkerReceipt
  , AwsAdminWorkerReceiptKind (AwsAdminInstalled)
  , awsAdminWorkerReceiptKind
  , awsAdminWorkerReceiptTargetReadBack
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminPermitIntent
  , AwsAdminPermitKind (..)
  , SignedAwsAdminPermit
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentCredentialClass
  , awsAdminPermitIntentDeadline
  , awsAdminPermitIntentKind
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentPlanBinding
  , awsAdminPermitIntentPreparedTarget
  , backupRepairFrozenAuthorityEpoch
  , backupRepairFrozenPlanDigest
  , bindAwsAdminPermitIntentPreparedTarget
  , signedAwsAdminPermitIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.FirstReconcileJournal
  ( FirstReconcileJournal
  , appendFirstReconcileJournalStore
  , appendFirstReconcileReceipt
  , firstReconcileJournalCodec
  , firstReconcileJournalCursor
  , firstReconcileJournalPlan
  , initializeFirstReconcileJournalStore
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (AuthorityBackupStoreCredential)
  , FirstReconcilePermitBinding
  , FirstReconcilePlanAction (..)
  , FirstReconcilePlanMember
  , FirstReconcileReceipt
  , OperatorMaterialAction (InstallOperatorMaterial)
  , defaultFirstReconcileProvisioningPlan
  , firstReconcilePermitMemberDigest
  , firstReconcilePermitMemberIndex
  , firstReconcilePermitPlanDigest
  , firstReconcilePlanDeadline
  , firstReconcilePlanDigest
  , firstReconcilePlanMemberAction
  , firstReconcilePlanMemberDigest
  , firstReconcilePlanMemberIndex
  , firstReconcilePlanMembers
  , firstReconcilePriorReceiptDigest
  , mkFirstReconcilePermitBinding
  , mkFirstReconcileReceipt
  , nextFirstReconcileMember
  , operatorMaterialOperationIdText
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( PreparedCredentialTargetObservation
  , preparedCredentialTargetObservationCodec
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( targetValueDigestText
  )

-- | The endpoint consumes this complete lifecycle rather than a read-only
-- caller-supplied boundary.  Preparation returns the canonical intent whose
-- prepared observation was durably read back; completion advances the exact
-- receipt-ordered first-reconcile member when one is bound.
data AwsAdminPreparedTargetLifecycle m = AwsAdminPreparedTargetLifecycle
  { prepareAndReadBackAwsAdminPreparedTarget
      :: AwsAdminPermitIntent
      -> m (Either Text AwsAdminPermitIntent)
  , reobserveRetainedAwsAdminPreparedTarget
      :: AwsAdminPermitIntent
      -> m (Either Text PreparedCredentialTargetObservation)
  , commitAwsAdminFirstReconcileReceipt
      :: SignedAwsAdminPermit
      -> AwsAdminWorkerReceipt
      -> m (Either Text ())
  , observeAwsAdminFirstReconcileContinuation
      :: m (Either Text (Maybe FirstReconcileContinuation))
  }

data FirstReconcileContinuation = FirstReconcileContinuation
  { firstReconcileContinuationClass :: !AwsCredentialClass
  , firstReconcileContinuationMemberIndex :: !Natural
  , firstReconcileContinuationMemberDigest :: !Text
  , firstReconcileContinuationDeadline :: !AuthorityTime
  }
  deriving (Eq, Show)

data PreparedAuthorityContext = PreparedAuthorityContext
  { preparedContextFence :: !Natural
  , preparedContextPlanBinding :: !(Maybe FirstReconcilePermitBinding)
  , preparedContextDeadline :: !AuthorityTime
  , preparedContextGenesis
      :: !(Maybe (GenesisPlan, FirstReconcilePlanMember))
  }

-- | Bind the production Lifecycle Authority store, admission aggregate,
-- first-reconcile journal, exact registered Target Agent rollout, and trusted
-- Authority clock into one closed producer/readback/completion capability.
productionAwsAdminPreparedTargetLifecycle
  :: InClusterAuthorityStore
  -> LongLivedCheckpointAuthority
  -> AuthorityAdmissionRepository IO revision
  -> ModelBObjectCoordinate 'ClusterRetained
  -> TargetAgentIdentity
  -> IO (Either Text AuthorityTime)
  -> AwsAdminPreparedTargetLifecycle IO
productionAwsAdminPreparedTargetLifecycle store authority admissionRepository journalCoordinate selectedAgent observeNow =
  AwsAdminPreparedTargetLifecycle
    { prepareAndReadBackAwsAdminPreparedTarget = prepare
    , reobserveRetainedAwsAdminPreparedTarget = reobservePrepared
    , commitAwsAdminFirstReconcileReceipt = commitFirstReconcile
    , observeAwsAdminFirstReconcileContinuation = observeContinuation
    }
 where
  preparedAdapter =
    inClusterAuthorityModelBCasAdapter
      store
      authority
      preparedCredentialTargetObservationCodec
  journalAdapter =
    inClusterAuthorityModelBCasAdapter
      store
      authority
      firstReconcileJournalCodec

  prepare draft = do
    timeResult <- observeNow
    admissionResult <- readAdmissionAggregate admissionRepository
    case (timeResult, admissionResult) of
      (Left detail, _) -> pure (Left ("Authority time is unavailable: " <> detail))
      (_, Left detail) -> pure (Left detail)
      (Right now, Right admission) -> do
        contextResult <-
          contextForIntent journalAdapter journalCoordinate admission draft
        case contextResult of
          Left detail -> pure (Left detail)
          Right context
            | authorityTimeMicros now
                >= authorityTimeMicros (preparedContextDeadline context) ->
                pure (Left "AWS-admin prepared-target deadline has expired")
            | otherwise -> do
                let owner =
                      "aws-admin-"
                        <> operatorMaterialOperationIdText
                          (awsAdminPermitIntentOperationId draft)
                case first
                  (Text.pack . show)
                  ( bindAwsAdminPermitIntentPreparedTarget
                      (preparedContextGenesis context)
                      (preparedContextPlanBinding context)
                      (preparedContextDeadline context)
                      owner
                      (preparedContextFence context)
                      selectedAgent
                      draft
                  ) of
                  Left detail -> pure (Left ("AWS-admin intent canonicalization failed: " <> detail))
                  Right canonical -> do
                    confirmedAdmission <- readAdmissionAggregate admissionRepository
                    if confirmedAdmission /= Right admission
                      then pure (Left "Authority admission changed during prepared-target derivation")
                      else do
                        published <- publishPrepared authority preparedAdapter canonical
                        pure (canonical <$ published)

  reobservePrepared intent =
    case preparedCoordinate authority intent of
      Left detail -> pure (Left detail)
      Right coordinate -> do
        observed <- modelBObserve preparedAdapter coordinate
        pure (preparedFromObservation observed)

  commitFirstReconcile permit receipt =
    let intent = signedAwsAdminPermitIntent permit
     in case awsAdminPermitIntentPlanBinding intent of
          Nothing -> pure (Right ())
          Just binding
            | awsAdminWorkerReceiptKind receipt /= AwsAdminInstalled ->
                pure (Left "first-reconcile completion requires an install receipt")
            | otherwise -> case decodeTargetWorkerReceipt (awsAdminWorkerReceiptTargetReadBack receipt) of
                Left err -> pure (Left ("target read-back receipt is invalid: " <> Text.pack (show err)))
                Right targetReceipt -> do
                  observed <- modelBObserve journalAdapter journalCoordinate
                  case observed of
                    ModelBObserved _ journal ->
                      case receiptForBinding binding journal targetReceipt of
                        Left detail -> pure (Left detail)
                        Right firstReceipt ->
                          appendAndConfirm journalAdapter journalCoordinate 8 firstReceipt
                    ModelBMissing -> pure (Left "first-reconcile journal is missing")
                    ModelBCorrupt detail -> pure (Left ("first-reconcile journal is corrupt: " <> detail))
                    ModelBEndpointUnready detail ->
                      pure (Left ("first-reconcile journal is not ready: " <> detail))
                    ModelBUnobservable detail ->
                      pure (Left ("first-reconcile journal is unobservable: " <> detail))

  observeContinuation = do
    admissionResult <- readAdmissionAggregate admissionRepository
    case admissionResult of
      Left detail -> pure (Left detail)
      Right aggregate -> case authorityAggregateAdmission aggregate of
        BackupEstablished {} -> do
          journalResult <- observeJournal journalAdapter journalCoordinate
          pure (journalResult >>= continuationFromJournal)
        _ -> pure (Left "first-reconcile continuation requires open backup admission")

readAdmissionAggregate
  :: AuthorityAdmissionRepository IO revision
  -> IO (Either Text AuthorityAdmissionAggregate)
readAdmissionAggregate repository = do
  observed <- readAuthorityAdmission repository
  pure
    ( authorityAdmissionSnapshotState
        <$> first
          ("Authority admission is unavailable: " <>)
          observed
    )

contextForIntent
  :: ModelBCasAdapter 'ClusterRetained IO FirstReconcileJournal
  -> ModelBObjectCoordinate 'ClusterRetained
  -> AuthorityAdmissionAggregate
  -> AwsAdminPermitIntent
  -> IO (Either Text PreparedAuthorityContext)
contextForIntent adapter coordinate aggregate intent =
  case (authorityAggregateAdmission aggregate, awsAdminPermitIntentKind intent) of
    (EstablishingBackup progress, GenesisBackupKind _) -> do
      journalResult <-
        ensureGenesisJournal adapter coordinate (awsAdminPermitIntentDeadline intent)
      pure $ do
        journal <- journalResult
        member <- currentJournalMember journal
        unless
          ( firstReconcilePlanMemberIndex member == 0
              && firstReconcilePlanMemberAction member
                == EstablishAuthorityBackupMember
              && awsAdminPermitIntentCredentialClass intent
                == AuthorityBackupStoreCredential
              && awsAdminPermitIntentAction intent == InstallOperatorMaterial
          )
          (Left "retained first-reconcile journal is not at genesis member zero")
        pure
          PreparedAuthorityContext
            { preparedContextFence = authorityEpochValue authorityEpochGenesis
            , preparedContextPlanBinding = Just (bindingFor journal member)
            , preparedContextDeadline =
                firstReconcilePlanDeadline (firstReconcileJournalPlan journal)
            , preparedContextGenesis =
                Just (genesisProgressPlan progress, member)
            }
    (BackupEstablished epoch _ _, NormalOperatorMaterialKind) -> do
      journalResult <- observeJournal adapter coordinate
      pure $ do
        journalMaybe <- journalResult
        case journalMaybe of
          Nothing ->
            pure
              PreparedAuthorityContext
                { preparedContextFence = authorityEpochValue epoch
                , preparedContextPlanBinding = Nothing
                , preparedContextDeadline = awsAdminPermitIntentDeadline intent
                , preparedContextGenesis = Nothing
                }
          Just journal -> case nextFirstReconcileMember
            (firstReconcileJournalPlan journal)
            (firstReconcileJournalCursor journal) of
            Left err -> Left ("first-reconcile cursor is invalid: " <> Text.pack (show err))
            Right Nothing ->
              pure
                PreparedAuthorityContext
                  { preparedContextFence = authorityEpochValue epoch
                  , preparedContextPlanBinding = Nothing
                  , preparedContextDeadline = awsAdminPermitIntentDeadline intent
                  , preparedContextGenesis = Nothing
                  }
            Right (Just member) -> case firstReconcilePlanMemberAction member of
              EstablishAuthorityBackupMember ->
                Left "first-reconcile genesis receipt has not committed"
              ProvisionAwsCredentialMember expectedClass -> do
                unless
                  ( awsAdminPermitIntentCredentialClass intent == expectedClass
                      && awsAdminPermitIntentAction intent == InstallOperatorMaterial
                  )
                  (Left "AWS-admin request is not the next first-reconcile member")
                pure
                  PreparedAuthorityContext
                    { preparedContextFence = authorityEpochValue epoch
                    , preparedContextPlanBinding = Just (bindingFor journal member)
                    , preparedContextDeadline =
                        firstReconcilePlanDeadline (firstReconcileJournalPlan journal)
                    , preparedContextGenesis = Nothing
                    }
    (BackupRepairFrozen epoch progress, BackupRepairFrozenKind repair) ->
      pure $ do
        retainedPermit <-
          maybe
            (Left "backup repair is frozen without a retained repair permit")
            Right
            (backupRepairPermit progress)
        unless
          ( backupRepairFrozenAuthorityEpoch repair == authorityEpochValue epoch
              && targetValueDigestText (backupRepairFrozenPlanDigest repair)
                == backupRepairPermitDigest retainedPermit
          )
          (Left "AWS-admin backup-repair binding differs from retained admission")
        pure
          PreparedAuthorityContext
            { preparedContextFence = authorityEpochValue (nextAuthorityEpoch epoch)
            , preparedContextPlanBinding = Nothing
            , preparedContextDeadline = awsAdminPermitIntentDeadline intent
            , preparedContextGenesis = Nothing
            }
    _ -> pure (Left "AWS-admin request is not admitted by retained Authority state")

ensureGenesisJournal
  :: ModelBCasAdapter 'ClusterRetained IO FirstReconcileJournal
  -> ModelBObjectCoordinate 'ClusterRetained
  -> AuthorityTime
  -> IO (Either Text FirstReconcileJournal)
ensureGenesisJournal adapter coordinate deadline = do
  let expectedPlan = defaultFirstReconcileProvisioningPlan deadline
  _ <- initializeFirstReconcileJournalStore adapter coordinate expectedPlan
  observed <- modelBObserve adapter coordinate
  pure $ case observed of
    ModelBObserved _ journal
      | firstReconcilePlanDigest (firstReconcileJournalPlan journal)
          == firstReconcilePlanDigest expectedPlan ->
          Right journal
      | otherwise -> Left "retained first-reconcile plan differs from genesis request"
    ModelBMissing -> Left "first-reconcile journal initialization was not read back"
    ModelBCorrupt detail -> Left ("first-reconcile journal is corrupt: " <> detail)
    ModelBEndpointUnready detail ->
      Left ("first-reconcile journal is not ready: " <> detail)
    ModelBUnobservable detail ->
      Left ("first-reconcile journal is unobservable: " <> detail)

observeJournal
  :: ModelBCasAdapter 'ClusterRetained IO FirstReconcileJournal
  -> ModelBObjectCoordinate 'ClusterRetained
  -> IO (Either Text (Maybe FirstReconcileJournal))
observeJournal adapter coordinate = do
  observed <- modelBObserve adapter coordinate
  pure $ case observed of
    ModelBMissing -> Right Nothing
    ModelBObserved _ journal -> Right (Just journal)
    ModelBCorrupt detail -> Left ("first-reconcile journal is corrupt: " <> detail)
    ModelBEndpointUnready detail ->
      Left ("first-reconcile journal is not ready: " <> detail)
    ModelBUnobservable detail ->
      Left ("first-reconcile journal is unobservable: " <> detail)

continuationFromJournal
  :: Maybe FirstReconcileJournal
  -> Either Text (Maybe FirstReconcileContinuation)
continuationFromJournal Nothing =
  Left "first-reconcile journal is missing after backup admission opened"
continuationFromJournal (Just journal) = do
  next <-
    first
      (("first-reconcile cursor is invalid: " <>) . Text.pack . show)
      ( nextFirstReconcileMember
          (firstReconcileJournalPlan journal)
          (firstReconcileJournalCursor journal)
      )
  traverse toContinuation next
 where
  toContinuation member = case firstReconcilePlanMemberAction member of
    EstablishAuthorityBackupMember ->
      Left "first-reconcile genesis member remains after backup admission opened"
    ProvisionAwsCredentialMember credentialClass ->
      Right
        FirstReconcileContinuation
          { firstReconcileContinuationClass = credentialClass
          , firstReconcileContinuationMemberIndex = firstReconcilePlanMemberIndex member
          , firstReconcileContinuationMemberDigest =
              targetValueDigestText (firstReconcilePlanMemberDigest member)
          , firstReconcileContinuationDeadline =
              firstReconcilePlanDeadline (firstReconcileJournalPlan journal)
          }

currentJournalMember
  :: FirstReconcileJournal -> Either Text FirstReconcilePlanMember
currentJournalMember journal = do
  next <-
    first
      (Text.pack . show)
      ( nextFirstReconcileMember
          (firstReconcileJournalPlan journal)
          (firstReconcileJournalCursor journal)
      )
  maybe (Left "first-reconcile journal is already complete") Right next

bindingFor
  :: FirstReconcileJournal
  -> FirstReconcilePlanMember
  -> FirstReconcilePermitBinding
bindingFor journal member =
  mkFirstReconcilePermitBinding
    (firstReconcilePlanDigest (firstReconcileJournalPlan journal))
    (firstReconcilePlanMemberIndex member)
    (firstReconcilePlanMemberDigest member)
    (firstReconcilePriorReceiptDigest (firstReconcileJournalCursor journal))

preparedCoordinate
  :: LongLivedCheckpointAuthority
  -> AwsAdminPermitIntent
  -> Either Text (ModelBObjectCoordinate 'ClusterRetained)
preparedCoordinate authority intent =
  first
    (Text.pack . show)
    ( mkClusterRetainedCoordinate
        authority
        ( "authority/aws-admin-prepared-targets/"
            <> operatorMaterialOperationIdText
              (awsAdminPermitIntentOperationId intent)
        )
    )

publishPrepared
  :: LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained IO PreparedCredentialTargetObservation
  -> AwsAdminPermitIntent
  -> IO (Either Text PreparedCredentialTargetObservation)
publishPrepared authority adapter intent =
  case preparedCoordinate authority intent of
    Left detail -> pure (Left detail)
    Right coordinate -> do
      observed <- modelBObserve adapter coordinate
      case observed of
        ModelBMissing -> do
          _ <-
            modelBCompareAndSwap
              adapter
              (ModelBInitialize coordinate expected)
          confirmed <- modelBObserve adapter coordinate
          pure (confirmExact confirmed)
        ModelBObserved _ existing
          | existing == expected -> pure (Right existing)
          | otherwise ->
              pure (Left "AWS-admin prepared-target operation already has a divergent outbox")
        ModelBCorrupt detail ->
          pure (Left ("AWS-admin prepared-target outbox is corrupt: " <> detail))
        ModelBEndpointUnready detail ->
          pure (Left ("AWS-admin prepared-target outbox is not ready: " <> detail))
        ModelBUnobservable detail ->
          pure (Left ("AWS-admin prepared-target outbox is unobservable: " <> detail))
 where
  expected = awsAdminPermitIntentPreparedTarget intent
  confirmExact confirmed = case confirmed of
    ModelBObserved _ retained
      | retained == expected -> Right retained
      | otherwise ->
          Left "AWS-admin prepared-target CAS read back a divergent outbox"
    other -> preparedFromObservation other

preparedFromObservation
  :: ModelBObservation PreparedCredentialTargetObservation
  -> Either Text PreparedCredentialTargetObservation
preparedFromObservation observation = case observation of
  ModelBMissing -> Left "AWS-admin prepared-target outbox is missing"
  ModelBObserved _ prepared -> Right prepared
  ModelBCorrupt detail -> Left ("AWS-admin prepared-target outbox is corrupt: " <> detail)
  ModelBEndpointUnready detail ->
    Left ("AWS-admin prepared-target outbox is not ready: " <> detail)
  ModelBUnobservable detail ->
    Left ("AWS-admin prepared-target outbox is unobservable: " <> detail)

receiptForBinding
  :: FirstReconcilePermitBinding
  -> FirstReconcileJournal
  -> TargetWorkerReceipt
  -> Either Text FirstReconcileReceipt
receiptForBinding binding journal targetReceipt = do
  let plan = firstReconcileJournalPlan journal
  unless
    (firstReconcilePermitPlanDigest binding == firstReconcilePlanDigest plan)
    (Left "first-reconcile permit plan digest differs from retained journal")
  member <-
    maybe
      (Left "first-reconcile permit member is absent from retained journal")
      Right
      ( find
          ( \candidate ->
              firstReconcilePlanMemberIndex candidate
                == firstReconcilePermitMemberIndex binding
                && firstReconcilePlanMemberDigest candidate
                  == firstReconcilePermitMemberDigest binding
          )
          (firstReconcilePlanMembers plan)
      )
  first
    (Text.pack . show)
    ( mkFirstReconcileReceipt
        member
        (Text.pack (show (targetWorkerReceiptVaultVersion targetReceipt)))
        (targetWorkerReceiptCommitment targetReceipt)
    )

appendAndConfirm
  :: ModelBCasAdapter 'ClusterRetained IO FirstReconcileJournal
  -> ModelBObjectCoordinate 'ClusterRetained
  -> Int
  -> FirstReconcileReceipt
  -> IO (Either Text ())
appendAndConfirm _ _ remaining _
  | remaining <= 0 = pure (Left "first-reconcile receipt CAS retry limit reached")
appendAndConfirm adapter coordinate remaining receipt = do
  _ <- appendFirstReconcileJournalStore adapter coordinate receipt
  observed <- modelBObserve adapter coordinate
  case observed of
    ModelBObserved _ journal -> case appendFirstReconcileReceipt receipt journal of
      Right replayed
        | replayed == journal -> pure (Right ())
        | otherwise -> appendAndConfirm adapter coordinate (remaining - 1) receipt
      Left err -> pure (Left ("first-reconcile receipt conflicts: " <> Text.pack (show err)))
    ModelBMissing -> pure (Left "first-reconcile journal disappeared during receipt commit")
    ModelBCorrupt detail -> pure (Left ("first-reconcile journal is corrupt: " <> detail))
    ModelBEndpointUnready detail ->
      pure (Left ("first-reconcile journal is not ready: " <> detail))
    ModelBUnobservable detail ->
      pure (Left ("first-reconcile journal is unobservable: " <> detail))
