{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

-- | Lifecycle-owned producer for the durable inputs consumed by registered
-- AWS stack reconciliation.  The commit operation reads every proof afresh,
-- writes under the future reconcile operation identity, and returns only a
-- bound attempt outcome.  The following graph node independently reads the
-- Authority object and returns opaque evidence; no process-local handoff is
-- part of the protocol.
module Prodbox.Lifecycle.Teardown.AwsStackReaderInterpreter
  ( AwsStackReaderInputReaders
  , mkAwsStackReaderInputReaders
  , AwsStackReaderInterpreter (..)
  , AwsStackReaderInterpreterError (..)
  , commitAwsStackReaderBundle
  , readBackAwsStackReaderBundle
  , executeAwsStackReaderOperation
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AwsStackReaderRepository
  ( AwsStackReaderAuthorityIdentity
  , AwsStackReaderClient
  , AwsStackReaderClientError
  , AwsStackReaderCommitResult
  , awsStackReaderAuthorityCoordinateDigest
  , awsStackReaderAuthorityGraphDigest
  , awsStackReaderAuthorityKey
  , awsStackReaderAuthorityOperationId
  , awsStackReaderAuthorityRunId
  , awsStackReaderAuthorityScope
  , commitAwsStackReaderBundleAttempt
  , committedAwsStackReaderIdentity
  , independentlyReadBackCommittedAwsStackReaderBundle
  )
import Prodbox.ControlPlane.AwsStackReaderRepository qualified as Repository
import Prodbox.Lifecycle.CleanupRun (CleanupAttemptId, CleanupOperationId)
import Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
import Prodbox.Lifecycle.Teardown.AwsStackReaderEvidence
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.OwnershipManifest
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.Registry

-- | Closed durable readers used only while the commit node is executing.
-- The checkpoint reader must observe the post-recovery state; the manifest
-- and Provider readers must reopen Authority-owned durable records.  None of
-- the callbacks returns a credential or provider session.
data AwsStackReaderInputReaders m = AwsStackReaderInputReaders
  { internalReadPostRecoveryCheckpointPair
      :: forall surface
       . TeardownExecutionContext surface
      -> RegisteredTargetBinding
      -> m (Either Text CheckpointPairObservation)
  , internalReadCompleteOwnershipManifest
      :: forall surface
       . TeardownExecutionContext surface
      -> RegisteredTargetBinding
      -> m (Either Text OwnershipManifestDecisionEvidence)
  , internalReadProviderCreationBinding
      :: forall surface
       . TeardownExecutionContext surface
      -> RegisteredTargetBinding
      -> CleanupOperationId
      -> m (Either Text AwsStackProviderBinding)
  }

mkAwsStackReaderInputReaders
  :: ( forall surface
        . TeardownExecutionContext surface
       -> RegisteredTargetBinding
       -> m (Either Text CheckpointPairObservation)
     )
  -> ( forall surface
        . TeardownExecutionContext surface
       -> RegisteredTargetBinding
       -> m (Either Text OwnershipManifestDecisionEvidence)
     )
  -> ( forall surface
        . TeardownExecutionContext surface
       -> RegisteredTargetBinding
       -> CleanupOperationId
       -> m (Either Text AwsStackProviderBinding)
     )
  -> AwsStackReaderInputReaders m
mkAwsStackReaderInputReaders = AwsStackReaderInputReaders

data AwsStackReaderInterpreter m = AwsStackReaderInterpreter
  { awsStackReaderClient :: !(AwsStackReaderClient m)
  , awsStackReaderInputReaders :: !(AwsStackReaderInputReaders m)
  }

data AwsStackReaderInterpreterError
  = AwsStackReaderTargetUnregistered !RegisteredResourceKey
  | AwsStackReaderTargetKindMismatch
      !RegisteredResourceKey
      !ResourceKind
      !ResourceKind
  | AwsStackReaderTargetNotStack !RegisteredResourceKey !ResourceKind
  | AwsStackReaderTargetCoordinateMismatch
      !RegisteredResourceKey
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | AwsStackReaderOperationCatalogMismatch
  | AwsStackReaderReconcileOperationMissing !RegisteredResourceKey
  | AwsStackReaderRecoveryPredecessorInvalid !RegisteredResourceKey
  | AwsStackReaderCommitPredecessorInvalid !RegisteredResourceKey
  | AwsStackReaderCheckpointUnavailable !Text
  | AwsStackReaderCheckpointBindingInvalid !CheckpointPairError
  | AwsStackReaderManifestUnavailable !Text
  | AwsStackReaderManifestBindingMismatch !RegisteredResourceKey
  | AwsStackReaderProviderBindingUnavailable !Text
  | AwsStackReaderProviderBindingMismatch !RegisteredResourceKey
  | AwsStackReaderDecisionInputsInvalid !AwsRegisteredTargetInterpreterError
  | AwsStackReaderClientRefused !AwsStackReaderClientError
  | AwsStackReaderCommittedIdentityMismatch
  | AwsStackReaderEvidenceInvalid !AwsStackReaderEvidenceError
  deriving (Eq, Show)

commitAwsStackReaderBundle
  :: (Monad m)
  => AwsStackReaderInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (Either AwsStackReaderInterpreterError AwsStackReaderCommitOutcome)
commitAwsStackReaderBundle interpreter context target =
  case validateCommitAdmission context target of
    Left err -> pure (Left err)
    Right reconcileOperation -> do
      pairResult <-
        internalReadPostRecoveryCheckpointPair readers context target
      case pairResult of
        Left detail -> pure (Left (AwsStackReaderCheckpointUnavailable detail))
        Right observedPair -> case validatePair target scope observedPair of
          Left err -> pure (Left err)
          Right pair -> do
            manifestResult <-
              internalReadCompleteOwnershipManifest readers context target
            case manifestResult of
              Left detail -> pure (Left (AwsStackReaderManifestUnavailable detail))
              Right manifest -> case validateManifest target scope manifest of
                Left err -> pure (Left err)
                Right completeManifest -> do
                  providerResult <-
                    internalReadProviderCreationBinding
                      readers
                      context
                      target
                      reconcileOperation
                  case providerResult of
                    Left detail ->
                      pure (Left (AwsStackReaderProviderBindingUnavailable detail))
                    Right providerBinding ->
                      commitBound
                        reconcileOperation
                        pair
                        completeManifest
                        providerBinding
 where
  readers = awsStackReaderInputReaders interpreter
  scope = teardownExecutionObservationScope context

  commitBound reconcileOperation pair manifest providerBinding
    | awsStackProviderBindingOperationId providerBinding /= reconcileOperation
        || awsStackProviderBindingKey providerBinding /= registeredTargetKey target
        || awsStackProviderBindingScope providerBinding /= scope =
        pure
          ( Left
              (AwsStackReaderProviderBindingMismatch (registeredTargetKey target))
          )
    | otherwise =
        case mkAwsStackDecisionInputs
          reconcileOperation
          (registeredTargetKey target)
          scope
          pair
          manifest of
          Left err -> pure (Left (AwsStackReaderDecisionInputsInvalid err))
          Right decisionInputs -> do
            committed <-
              commitAwsStackReaderBundleAttempt
                (awsStackReaderClient interpreter)
                decisionInputs
                providerBinding
            case committed of
              Left err -> pure (Left (AwsStackReaderClientRefused err))
              Right result ->
                pure
                  ( mapEvidence
                      ( mkAwsStackReaderCommitOutcome
                          (teardownExecutionRunId context)
                          (teardownExecutionGraphDigest context)
                          (teardownExecutionOperationId context)
                          (teardownExecutionAttemptId context)
                          reconcileOperation
                          target
                          scope
                          (commitDisposition result)
                      )
                  )

readBackAwsStackReaderBundle
  :: (Monad m)
  => AwsStackReaderInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (Either AwsStackReaderInterpreterError AwsStackReaderReadBackEvidence)
readBackAwsStackReaderBundle interpreter context target =
  case validateReadBackAdmission context target of
    Left err -> pure (Left err)
    Right (commitOperation, commitAttempt, reconcileOperation) -> do
      loaded <-
        independentlyReadBackCommittedAwsStackReaderBundle
          (awsStackReaderClient interpreter)
          reconcileOperation
          (registeredTargetKey target)
          scope
      pure $ case loaded of
        Left err -> Left (AwsStackReaderClientRefused err)
        Right committed
          | committedIdentityMatches
              context
              target
              reconcileOperation
              (committedAwsStackReaderIdentity committed) ->
              mapEvidence
                ( mkAwsStackReaderReadBackEvidence
                    (teardownExecutionRunId context)
                    (teardownExecutionGraphDigest context)
                    (teardownExecutionOperationId context)
                    (teardownExecutionAttemptId context)
                    commitOperation
                    commitAttempt
                    reconcileOperation
                    target
                    scope
                )
          | otherwise -> Left AwsStackReaderCommittedIdentityMismatch
 where
  scope = teardownExecutionObservationScope context

executeAwsStackReaderOperation
  :: (Monad m)
  => AwsStackReaderInterpreter m
  -> TeardownExecutionContext surface
  -> TeardownOperation surface
  -> m (Maybe (TeardownNodeResult surface))
executeAwsStackReaderOperation interpreter context operation = case operation of
  CommitAwsStackReaderBundle target ->
    Just . either (TeardownNodeRefused . renderError) TeardownAwsStackReaderCommit
      <$> commitAwsStackReaderBundle interpreter context target
  ReadBackAwsStackReaderBundle target ->
    Just . either (TeardownNodeRefused . renderError) TeardownAwsStackReaderReadBack
      <$> readBackAwsStackReaderBundle interpreter context target
  _ -> pure Nothing

validateCommitAdmission
  :: TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> Either AwsStackReaderInterpreterError CleanupOperationId
validateCommitAdmission context target = do
  validateTarget target
  validateCurrentOperation context (CommitAwsStackReaderBundle target)
  reconcileOperation <- requireReconcileOperation context target
  case teardownExecutionSuccessfulPredecessors context of
    [predecessor]
      | teardownSucceededPredecessorOperation predecessor
          == ReadBackStackCheckpointRecovery target
          && Just (teardownSucceededPredecessorOperationId predecessor)
            == teardownExecutionOperationIdFor
              context
              (ReadBackStackCheckpointRecovery target) ->
          Right reconcileOperation
    _ -> Left (AwsStackReaderRecoveryPredecessorInvalid (registeredTargetKey target))

validateReadBackAdmission
  :: TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> Either
       AwsStackReaderInterpreterError
       (CleanupOperationId, CleanupAttemptId, CleanupOperationId)
validateReadBackAdmission context target = do
  validateTarget target
  validateCurrentOperation context (ReadBackAwsStackReaderBundle target)
  reconcileOperation <- requireReconcileOperation context target
  case teardownExecutionAttemptedPredecessors context of
    [predecessor]
      | teardownAttemptedPredecessorOperation predecessor
          == CommitAwsStackReaderBundle target
          && Just (teardownAttemptedPredecessorOperationId predecessor)
            == teardownExecutionOperationIdFor
              context
              (CommitAwsStackReaderBundle target) ->
          Right
            ( teardownAttemptedPredecessorOperationId predecessor
            , teardownAttemptedPredecessorAttemptId predecessor
            , reconcileOperation
            )
    _ -> Left (AwsStackReaderCommitPredecessorInvalid (registeredTargetKey target))

validateCurrentOperation
  :: TeardownExecutionContext surface
  -> TeardownOperation surface
  -> Either AwsStackReaderInterpreterError ()
validateCurrentOperation context expected
  | teardownExecutionOperationIdFor context expected
      == Just (teardownExecutionOperationId context) =
      Right ()
  | otherwise = Left AwsStackReaderOperationCatalogMismatch

requireReconcileOperation
  :: TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> Either AwsStackReaderInterpreterError CleanupOperationId
requireReconcileOperation context target =
  maybe
    (Left (AwsStackReaderReconcileOperationMissing (registeredTargetKey target)))
    Right
    ( teardownExecutionOperationIdFor
        context
        (ReconcileRegisteredTargetAbsent target)
    )

validateTarget
  :: RegisteredTargetBinding
  -> Either AwsStackReaderInterpreterError ()
validateTarget target = do
  identity <-
    maybe
      (Left (AwsStackReaderTargetUnregistered key))
      Right
      (lookupRegisteredIdentity key)
  if registeredTargetKind target == registeredIdentityKind identity
    then Right ()
    else
      Left
        ( AwsStackReaderTargetKindMismatch
            key
            (registeredIdentityKind identity)
            (registeredTargetKind target)
        )
  if registeredIdentityKind identity == Stack
    then Right ()
    else Left (AwsStackReaderTargetNotStack key (registeredIdentityKind identity))
  if registeredTargetCoordinateDigest target
    == registeredIdentityCoordinateDigest identity
    then Right ()
    else
      Left
        ( AwsStackReaderTargetCoordinateMismatch
            key
            (registeredIdentityCoordinateDigest identity)
            (registeredTargetCoordinateDigest target)
        )
 where
  key = registeredTargetKey target

validatePair
  :: RegisteredTargetBinding
  -> ObservationEvidenceScope
  -> CheckpointPairObservation
  -> Either AwsStackReaderInterpreterError CheckpointPairObservation
validatePair target scope pair =
  either
    (Left . AwsStackReaderCheckpointBindingInvalid)
    Right
    ( mkCheckpointPairObservation
        (registeredTargetKey target)
        scope
        (primaryCheckpointObservation pair)
        (backupCheckpointObservation pair)
    )

validateManifest
  :: RegisteredTargetBinding
  -> ObservationEvidenceScope
  -> OwnershipManifestDecisionEvidence
  -> Either AwsStackReaderInterpreterError OwnershipManifestDecisionEvidence
validateManifest target scope manifest
  | ownershipManifestDecisionStackKey manifest /= registeredTargetKey target =
      Left (AwsStackReaderManifestBindingMismatch (registeredTargetKey target))
  | ownershipManifestDecisionScope manifest /= scope =
      Left (AwsStackReaderManifestBindingMismatch (registeredTargetKey target))
  | otherwise = Right manifest

committedIdentityMatches
  :: TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> CleanupOperationId
  -> AwsStackReaderAuthorityIdentity
  -> Bool
committedIdentityMatches context target reconcileOperation identity =
  awsStackReaderAuthorityRunId identity == teardownExecutionRunId context
    && awsStackReaderAuthorityGraphDigest identity
      == teardownExecutionGraphDigest context
    && awsStackReaderAuthorityOperationId identity == reconcileOperation
    && awsStackReaderAuthorityKey identity == registeredTargetKey target
    && awsStackReaderAuthorityCoordinateDigest identity
      == registeredTargetCoordinateDigest target
    && awsStackReaderAuthorityScope identity
      == teardownExecutionObservationScope context

commitDisposition
  :: AwsStackReaderCommitResult -> AwsStackReaderCommitDisposition
commitDisposition result = case result of
  Repository.AwsStackReaderCommitCreated ->
    Prodbox.Lifecycle.Teardown.AwsStackReaderEvidence.AwsStackReaderCommitCreated
  Repository.AwsStackReaderCommitExactReplay ->
    Prodbox.Lifecycle.Teardown.AwsStackReaderEvidence.AwsStackReaderCommitExactReplay
  Repository.AwsStackReaderCommitConflict ->
    Prodbox.Lifecycle.Teardown.AwsStackReaderEvidence.AwsStackReaderCommitConflict
  Repository.AwsStackReaderCommitResponseLost failure ->
    Prodbox.Lifecycle.Teardown.AwsStackReaderEvidence.AwsStackReaderCommitResponseLost failure
  Repository.AwsStackReaderCommitUnavailable failure ->
    Prodbox.Lifecycle.Teardown.AwsStackReaderEvidence.AwsStackReaderCommitUnavailable failure

mapEvidence
  :: Either AwsStackReaderEvidenceError value
  -> Either AwsStackReaderInterpreterError value
mapEvidence = either (Left . AwsStackReaderEvidenceInvalid) Right

renderError :: AwsStackReaderInterpreterError -> Text
renderError = Text.pack . show
