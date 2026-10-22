{-# LANGUAGE OverloadedStrings #-}

-- | Package-private interpreter for the global Provider credential fence.
-- The Authority supplies its own repositories and authenticated Agent client.
module Prodbox.ControlPlane.ProviderCredentialMutationRuntime
  ( providerCredentialMutationBoundary
  , ProviderCredentialParentRecoveryBoundary (..)
  ) where

import Control.Monad (forM_, unless)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.AuthorityBackupClient (AuthorityAggregateBackupClient)
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( AwsAdminAuthorityRepositoryResolver
  , AwsAdminProviderCredentialBoundary (..)
  )
import Prodbox.ControlPlane.CleanupProgramDescriptorRepository
  ( CleanupProgramDescriptorAuthorityClient
  )
import Prodbox.ControlPlane.CompletedProviderPredecessor (observeCompletedProviderPredecessor)
import Prodbox.ControlPlane.ProviderCredentialAdmissionEvidence
  ( observeProviderCredentialAdmission
  , providerCredentialMutationReservationForIntent
  )
import Prodbox.ControlPlane.ProviderCredentialPublication.Internal (publishAwsAdminProviderLineage)
import Prodbox.ControlPlane.TargetMaterialClient
  ( TargetMaterialClient (..)
  , targetWorkerReceiptFromMaterialObservation
  )
import Prodbox.ControlPlane.TargetMaterialEndpoint
  ( TargetMaterialObservation (targetMaterialObservedGeneration)
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (AwsLifecycleProvider)
  , TargetSecretId (TargetAwsCredential)
  )
import Prodbox.ControlPlane.TargetSecretWorker (decodeTargetWorkerReceipt)
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.CompletedProviderPredecessor (providerPredecessorRunId)
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( providerCredentialCleanupOperationId
  , providerCredentialLineageArchiveOperationId
  )
import Prodbox.Lifecycle.Authority.ProviderCredentialCleanupEvidence.Internal
  ( ObservedProviderCredentialCleanup (..)
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupRunId
  , DescriptorBoundCleanupRunRepository
  , cleanupDigestOfBytes
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAuthority
  ( AwsAdminAuthorityState (..)
  , awsAdminAuthorityCurrentPermit
  , observeAwsAdminAuthority
  , validateAwsAdminProviderLineageCapacity
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminWorkerReceipt
  , awsAdminWorkerReceiptTargetReadBack
  , validateAwsAdminWorkerReceiptForPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( SignedAwsAdminPermit
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentAuthorityEndpoint
  , awsAdminPermitIntentAuthorityScope
  , awsAdminPermitIntentCredentialClass
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentIamParameters
  , awsAdminPermitIntentOperationId
  , encodeSignedAwsAdminPermit
  , signedAwsAdminPermitIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (LifecycleProviderCredential)
  , OperatorMaterialAction (RevokeOperatorMaterial)
  , operatorMaterialOperationIdText
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Lifecycle.TargetCommitIntent (credentialGenerationValue)

data ProviderCredentialParentRecoveryBoundary m = ProviderCredentialParentRecoveryBoundary
  { credentialParentObserveNow :: m (Either Text AuthorityTime)
  , credentialParentObserveCompletion
      :: SignedAwsAdminPermit -> m (Either Text (Maybe AwsAdminWorkerReceipt))
  , credentialParentProveExpiredAbsence :: AuthorityTime -> SignedAwsAdminPermit -> m (Either Text ())
  , credentialObserveLegacyWorkerQuiescence :: m (Either Text ())
  }

providerCredentialMutationBoundary
  :: (Monad m)
  => AuthorityAdmissionRepository m revision
  -> AwsAdminAuthorityRepositoryResolver m outboxRevision
  -> CleanupProgramDescriptorAuthorityClient m
  -> (CleanupRunId -> DescriptorBoundCleanupRunRepository m runRevision)
  -> AuthorityAggregateBackupClient m
  -> TargetMaterialClient m
  -> ProviderCredentialParentRecoveryBoundary m
  -> AwsAdminProviderCredentialBoundary m
providerCredentialMutationBoundary admission resolve descriptors runs backup agent recovery =
  AwsAdminProviderCredentialBoundary
    { reserveAwsAdminProviderCredential = forProvider reserve
    , admitAwsAdminProviderPermit = \permit -> forProvider (admit permit) (signedAwsAdminPermitIntent permit)
    , settleAwsAdminProviderCredential = forProvider settle
    , observePendingAwsAdminProviderCredential = do
        observed <- readAuthorityAdmission admission
        pure $
          fmap
            ( fmap providerCredentialLineageArchiveOperationId
                . authorityAggregatePendingCredentialArchive
                . authorityAdmissionSnapshotState
            )
            observed
    , observeAwsAdminProviderCredentialRecovery = do
        observed <- readAuthorityAdmission admission
        pure
          (authorityAggregateProviderCredentialRecoveryView . authorityAdmissionSnapshotState <$> observed)
    , confirmAwsAdminProviderCredentialServing = runExceptT $ do
        initial <- ExceptT (readAuthorityAdmission admission)
        operation <- case authorityAggregateServingCredentialOperation (authorityAdmissionSnapshotState initial) of
          Nothing -> throwE "provider-credential-serving-lineage-missing"
          Just value -> pure value
        repository <- checked (resolve operation)
        current <- observeOutbox repository
        intent <- case current of
          AwsAdminAuthorityCompleted permit _ -> pure (signedAwsAdminPermitIntent permit)
          AwsAdminAuthorityCompletedWithLineage permit _ _ -> pure (signedAwsAdminPermitIntent permit)
          _ -> throwE "provider-credential-serving-outbox-incomplete"
        unless
          ( awsAdminPermitIntentCredentialClass intent == LifecycleProviderCredential
              && awsAdminPermitIntentAction intent /= RevokeOperatorMaterial
              && operationId intent == operation
          )
          (throwE "provider-credential-serving-outbox-mismatch")
        settle intent
        closing <- ExceptT (readAuthorityAdmission admission)
        unless
          ( authorityAggregateServingCredentialOperation (authorityAdmissionSnapshotState closing)
              == Just operation
          )
          (throwE "provider-credential-serving-lineage-changed")
    }
 where
  forProvider action intent
    | awsAdminPermitIntentCredentialClass intent /= LifecycleProviderCredential = pure (Right ())
    | otherwise = runExceptT (action intent)

  repositoryFor intent = checked (resolve (operationId intent))
  operationId = operatorMaterialOperationIdText . awsAdminPermitIntentOperationId
  observeOutbox repository = ExceptT (fmap (first (Text.pack . show)) (observeAwsAdminAuthority repository))

  reserve intent = do
    repository <- repositoryFor intent
    current <- observeOutbox repository
    case current of
      AwsAdminAuthorityCompleted {} -> settle intent
      AwsAdminAuthorityCompletedWithLineage {} -> settle intent
      _ -> do
        _ <- reserveGlobal intent
        pure ()

  reserveGlobal intent = do
    reservation <- checked (providerCredentialMutationReservationForIntent intent)
    snapshot <- ExceptT (readAuthorityAdmission admission)
    let aggregate = authorityAdmissionSnapshotState snapshot
        standard = reserveAuthorityProviderCredentialMutation aggregate reservation
    if authorityAggregateNeedsProviderCredentialQuiescence aggregate
      then ExceptT (credentialObserveLegacyWorkerQuiescence recovery)
      else pure ()
    case standard of
      Left AuthorityCredentialMutationPredecessorCompletionRequired -> do
        coordinates <-
          maybe
            (throwE "predecessor-coordinates-unavailable")
            pure
            (authorityAggregateProviderPredecessorCoordinates aggregate)
        proof <-
          ExceptT
            ( fmap
                (first (Text.pack . show))
                ( observeCompletedProviderPredecessor
                    descriptors
                    (runs (providerPredecessorRunId coordinates))
                    backup
                    coordinates
                )
            )
        commitObservedFold
          admission
          ( first (Text.pack . show)
              . (\actual -> reserveAuthorityProviderCredentialMutationAfterPredecessor actual reservation proof)
          )
      Left (AuthorityCredentialMutationReservationRefused _) -> do
        parent <-
          maybe
            (throwE "provider-credential-active-reservation-unavailable")
            pure
            (authorityAggregatePendingCredentialArchive aggregate)
        proof <- proveCleanupChild parent intent
        commitObservedFold
          admission
          (first (Text.pack . show) . (`reserveAuthorityProviderCredentialCleanup` proof))
      Left cause -> throwE (Text.pack (show cause))
      Right _ ->
        commitObservedFold
          admission
          (first (Text.pack . show) . (`reserveAuthorityProviderCredentialMutation` reservation))

  proveCleanupChild parent childIntent = do
    parentRepository <- checked (resolve (providerCredentialLineageArchiveOperationId parent))
    initial <- observeOutbox parentRepository
    (permit, retainedReceipt) <- case initial of
      AwsAdminAuthorityAuthorized authorized -> pure (authorized, Nothing)
      AwsAdminAuthorityCompleted completed receipt -> pure (completed, Just receipt)
      AwsAdminAuthorityCompletedWithLineage completed receipt archived
        | archived == parent -> pure (completed, Just receipt)
      _ -> throwE "provider-credential-parent-is-not-an-exact-authorized-or-completed-operation"
    let parentIntent = signedAwsAdminPermitIntent permit
    parentReservation <- checked (providerCredentialMutationReservationForIntent parentIntent)
    childReservation <- checked (providerCredentialMutationReservationForIntent childIntent)
    childOperation <- checked (providerCredentialCleanupOperationId parentReservation)
    checked (validateAwsAdminProviderLineageCapacity parent permit)
    unless
      ( operationId childIntent == operatorMaterialOperationIdText childOperation
          && awsAdminPermitIntentAction childIntent == RevokeOperatorMaterial
          && awsAdminPermitIntentIamParameters childIntent == awsAdminPermitIntentIamParameters parentIntent
          && awsAdminPermitIntentAuthorityScope childIntent == awsAdminPermitIntentAuthorityScope parentIntent
          && awsAdminPermitIntentAuthorityEndpoint childIntent
            == awsAdminPermitIntentAuthorityEndpoint parentIntent
      )
      (throwE "provider-credential-cleanup-child-binding-mismatch")
    journalReceipt <- ExceptT (credentialParentObserveCompletion recovery permit)
    completed <- case (retainedReceipt, journalReceipt) of
      (Just receipt, Just journal)
        | receipt /= journal -> throwE "provider-credential-parent-completion-receipt-mismatch"
      (Just receipt, _) -> pure (Just receipt)
      (Nothing, journal) -> pure journal
    forM_ completed $ \receipt -> do
      checked (validateAwsAdminWorkerReceiptForPermit permit receipt)
      _ <- checked (decodeTargetWorkerReceipt (awsAdminWorkerReceiptTargetReadBack receipt))
      pure ()
    now <- ExceptT (credentialParentObserveNow recovery)
    ExceptT (credentialParentProveExpiredAbsence recovery now permit)
    target <-
      ExceptT
        ( fmap
            (first (Text.pack . show))
            (observeRegisteredTargetMaterial agent (TargetAwsCredential AwsLifecycleProvider))
        )
    let refuseCurrentTarget receipt =
          case (target, decodeTargetWorkerReceipt (awsAdminWorkerReceiptTargetReadBack receipt)) of
            (Just metadata, Right expected)
              | targetWorkerReceiptFromMaterialObservation (TargetAwsCredential AwsLifecycleProvider) metadata
                  == Right expected ->
                  throwE "provider-credential-parent-target-is-current; refresh its completion"
            _ -> pure ()
    forM_ completed refuseCurrentTarget
    let ceilingGeneration = credentialGenerationValue (awsAdminPermitIntentGeneration parentIntent)
        actualGeneration = maybe ceilingGeneration targetMaterialObservedGeneration target
    unless
      ( actualGeneration <= ceilingGeneration
          && credentialGenerationValue (awsAdminPermitIntentGeneration childIntent) == actualGeneration
      )
      (throwE "provider-credential-cleanup-target-generation-mismatch")
    closing <- observeOutbox parentRepository
    unless (closing == initial) (throwE "provider-credential-parent-changed-during-cleanup-admission")
    pure
      ( ObservedProviderCredentialCleanup
          parent
          childReservation
          (cleanupDigestOfBytes (encodeSignedAwsAdminPermit permit))
      )

  admit permit intent = do
    repository <- repositoryFor intent
    current <- observeOutbox repository
    unless (awsAdminAuthorityCurrentPermit current == Just permit) (throwE "permit-outbox-mismatch")
    archive <- archiveFor intent current
    checked (validateAwsAdminProviderLineageCapacity archive permit)

  settle intent = do
    repository <- repositoryFor intent
    current <- observeOutbox repository
    archive <- archiveFor intent current
    publication <-
      ExceptT (fmap (first (Text.pack . show)) (publishAwsAdminProviderLineage repository archive))
    evidence <-
      ExceptT (fmap (first (Text.pack . show)) (observeProviderCredentialAdmission agent publication))
    commitObservedFold admission $ \aggregate -> do
      next <- first (Text.pack . show) (completeAuthorityProviderCredentialMutation aggregate evidence)
      Right (next, ())

  archiveFor intent current = do
    snapshot <- ExceptT (readAuthorityAdmission admission)
    archive <- case authorityAggregatePendingCredentialArchive (authorityAdmissionSnapshotState snapshot) of
      Just pending -> pure pending
      Nothing -> case current of
        AwsAdminAuthorityCompletedWithLineage _ _ archived -> pure archived
        _ -> throwE "provider-credential-reservation-missing"
    unless
      (providerCredentialLineageArchiveOperationId archive == operationId intent)
      (throwE "provider-credential-reservation-mismatch")
    pure archive

checked :: (Monad m, Show cause) => Either cause value -> ExceptT Text m value
checked = ExceptT . pure . first (Text.pack . show)

-- A CAS reply is not durability evidence. Re-apply the exact fold to a separate
-- read; only an idempotent fold retaining the same product confirms success.
-- This settles a lost write reply without overwriting unrelated aggregate work.
commitObservedFold
  :: (Monad m, Eq product)
  => AuthorityAdmissionRepository m revision
  -> (AuthorityAdmissionAggregate -> Either Text (AuthorityAdmissionAggregate, product))
  -> ExceptT Text m product
commitObservedFold repository foldState = do
  snapshot <- ExceptT (readAuthorityAdmission repository)
  let current = authorityAdmissionSnapshotState snapshot
  (next, expected) <- ExceptT (pure (foldState current))
  if next == current
    then pure expected
    else do
      _ <-
        ExceptT
          (Right <$> compareAndSwapAuthorityAdmission repository (authorityAdmissionRevision snapshot) next)
      independent <- ExceptT (readAuthorityAdmission repository)
      let actual = authorityAdmissionSnapshotState independent
      (replayed, observed) <- ExceptT (pure (foldState actual))
      unless
        (replayed == actual && observed == expected)
        (throwE "provider-credential-aggregate-readback-mismatch")
      pure observed
