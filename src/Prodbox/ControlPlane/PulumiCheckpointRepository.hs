{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production-shaped composition of the checkpoint endpoint over the one
-- retained Authority aggregate and a receipt-backed immutable blob pair.
--
-- Blob publication happens before aggregate promotion.  The blob seam may
-- return a 'VerifiedPulumiCheckpointRef' only after both primary and backup
-- copies were read back.  A CAS response can be lost safely: confirmation
-- always re-reads the aggregate and the referenced bytes.
module Prodbox.ControlPlane.PulumiCheckpointRepository
  ( PulumiCheckpointBlobStore (..)
  , aggregatePulumiCheckpointRepository
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  , registeredGenerationForSlot
  )
import Prodbox.ControlPlane.PulumiCheckpointEndpoint
  ( PulumiCheckpointCopyObservation (..)
  , PulumiCheckpointMutationTicket (..)
  , PulumiCheckpointObservation (..)
  , PulumiCheckpointPairObservation (..)
  , PulumiCheckpointPublicationResult (..)
  , PulumiCheckpointRepository (..)
  , PulumiCheckpointRestoreReadBack (..)
  , PulumiCheckpointRestoreResult (..)
  , PulumiCheckpointRetirementAttemptResult (..)
  , PulumiCheckpointRetirementReadBack (..)
  , PulumiCheckpointRetirementResult (..)
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( verifiedCallerSlotPrincipal
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , authorityAggregatePulumiCheckpoints
  , authorityCheckpointOperationRef
  , authorityCheckpointOperationStatus
  , stepAuthorityCheckpointPermit
  , stepAuthorityCheckpointPublication
  , stepAuthorityCheckpointRestore
  , stepAuthorityCheckpointRetirement
  )
import Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry
  ( CheckpointMutationAuthorization (..)
  , CheckpointMutationDecision (..)
  , CheckpointOperationKind (..)
  , CheckpointPermitDecision (..)
  , CheckpointRestoreReadBack (..)
  , CheckpointRetirementReadBack (..)
  , VerifiedPulumiCheckpointRef
  , authorizeCheckpointPublication
  , authorizeCheckpointRestore
  , authorizeCheckpointRetirement
  , observeAuthorityPulumiCheckpoint
  , observeCheckpointRestoreReadBack
  , observeCheckpointRetirementReadBack
  , observeRetiredAuthorityPulumiCheckpoints
  , verifiedPulumiCheckpointBackupVersion
  , verifiedPulumiCheckpointDigest
  , verifiedPulumiCheckpointPrimaryVersion
  )
import Prodbox.Lifecycle.Authority.Submission
  ( SubmissionStatus (StatusInFlight, StatusSettled)
  , TerminalOutcome (OperationCompletedOutcome)
  )
import Prodbox.Lifecycle.PulumiCheckpoint
  ( CanonicalPulumiCheckpoint
  , PulumiCheckpointOperationRef
  , RegisteredPulumiCheckpoint
  , canonicalPulumiCheckpointDigest
  )

data CheckpointPermitPreparation revision
  = CheckpointPermitReady
      !(AuthorityAdmissionSnapshot revision)
      !PulumiCheckpointOperationRef
  | CheckpointPermitRejected !Text
  | CheckpointPermitUnavailable !Text

-- | The only large-byte seam used by the aggregate repository.  An
-- implementation must seal the canonical checkpoint once, put/read-back that
-- exact ciphertext in the primary store, copy/read-back the same ciphertext in
-- the independent backup store, and only then construct the verified ref.
data PulumiCheckpointBlobStore m = PulumiCheckpointBlobStore
  { replicatePulumiCheckpointBlob
      :: RegisteredPulumiCheckpoint
      -> CanonicalPulumiCheckpoint
      -> m (Either Text VerifiedPulumiCheckpointRef)
  , observePulumiCheckpointBlob
      :: RegisteredPulumiCheckpoint
      -> VerifiedPulumiCheckpointRef
      -> m PulumiCheckpointObservation
  , observePrimaryPulumiCheckpointCopy
      :: RegisteredPulumiCheckpoint
      -> VerifiedPulumiCheckpointRef
      -> m PulumiCheckpointCopyObservation
  , observeBackupPulumiCheckpointCopy
      :: RegisteredPulumiCheckpoint
      -> VerifiedPulumiCheckpointRef
      -> m PulumiCheckpointCopyObservation
  , restorePulumiCheckpointPrimary
      :: RegisteredPulumiCheckpoint
      -> VerifiedPulumiCheckpointRef
      -> m (Either Text VerifiedPulumiCheckpointRef)
  }

aggregatePulumiCheckpointRepository
  :: (Monad m)
  => AuthorityAdmissionRepository m revision
  -> PulumiCheckpointBlobStore m
  -> PulumiCheckpointRepository m
aggregatePulumiCheckpointRepository authorityRepository blobStore =
  repository
 where
  repository =
    PulumiCheckpointRepository
      { observeRegisteredPulumiCheckpoint = observeCurrent
      , observeRegisteredPulumiCheckpointPair = observePair
      , publishRegisteredPulumiCheckpoint = publish
      , retireRegisteredPulumiCheckpoint = retire
      , restoreRegisteredPulumiCheckpointPrimary = restorePrimary
      , readBackRegisteredPulumiCheckpointRestore = readBackRestore
      , attemptRegisteredPulumiCheckpointRetirement = attemptRetirement
      , readBackRegisteredPulumiCheckpointRetirement = readBackRetirement
      }

  observeCurrent _callerSlot registered = do
    observed <- readAuthorityAdmission authorityRepository
    case observed of
      Left detail ->
        pure (PulumiCheckpointEndpointUnready detail)
      Right snapshot ->
        observeAggregateCheckpoint
          blobStore
          registered
          (authorityAdmissionSnapshotState snapshot)

  observePair _callerSlot registered = do
    observed <- readAuthorityAdmission authorityRepository
    case observed of
      Left detail -> pure (PulumiCheckpointPairUnobservable detail)
      Right snapshot ->
        observePairInAggregate
          registered
          (authorityAdmissionSnapshotState snapshot)

  observePairInAggregate registered aggregate =
    case observeAuthorityPulumiCheckpoint
      registered
      (authorityAggregatePulumiCheckpoints aggregate) of
      Nothing -> pure PulumiCheckpointPairNoCurrentReference
      Just reference -> do
        -- These calls are deliberately independent.  In particular, a failed
        -- primary observation must never suppress the backup read-back.
        primary <-
          observePrimaryPulumiCheckpointCopy blobStore registered reference
        backup <-
          observeBackupPulumiCheckpointCopy blobStore registered reference
        pure (PulumiCheckpointPairCurrent reference primary backup)

  restorePrimary callerSlot ticket registered predecessor =
    case registeredGenerationForSlot callerSlot of
      Left detail -> pure (PulumiCheckpointRestoreRefused detail)
      Right generation ->
        restoreForCaller callerSlot generation ticket registered predecessor

  restoreForCaller callerSlot generation ticket registered predecessor = do
    let operation = pulumiCheckpointTicketOperation ticket
        expected = pulumiCheckpointTicketExpectedDigest ticket
        predecessorDigest = verifiedPulumiCheckpointDigest predecessor
    if expected /= Just predecessorDigest
      then
        pure
          ( PulumiCheckpointRestoreRefused
              "restore ticket does not bind the predecessor checkpoint digest"
          )
      else do
        prepared <-
          preparePermit
            callerSlot
            generation
            operation
            registered
            RestoreCheckpoint
            expected
            Nothing
        case prepared of
          CheckpointPermitRejected detail ->
            pure (PulumiCheckpointRestoreRefused detail)
          CheckpointPermitUnavailable detail ->
            pure (PulumiCheckpointRestoreUnavailable detail)
          CheckpointPermitReady snapshot operationReference ->
            authorizeAndRestore
              callerSlot
              generation
              snapshot
              operationReference
              operation
              registered
              predecessor

  authorizeAndRestore
    callerSlot
    generation
    snapshot
    operationReference
    operation
    registered
    predecessor =
      case authorizeCheckpointRestore
        operationReference
        registered
        predecessor
        predecessor
        checkpoints of
        Left invariant -> pure (restoreInvariant invariant)
        Right (CheckpointMutationAuthorizationRefused decision) ->
          pure (PulumiCheckpointRestoreRefused (decisionText decision))
        Right (CheckpointMutationAlreadyAppliedWith (Just current)) ->
          pure (PulumiCheckpointRestoreAlreadyApplied current)
        Right (CheckpointMutationAlreadyAppliedWith Nothing) ->
          pure
            ( PulumiCheckpointRestoreRefused
                "restore operation has no current checkpoint reference"
            )
        Right CheckpointMutationAuthorized -> do
          pair <- observePairInAggregate registered aggregate
          case pair of
            PulumiCheckpointPairCurrent actual primary backup
              | actual /= predecessor ->
                  pure
                    ( PulumiCheckpointRestoreRefused
                        "active checkpoint reference changed before restore"
                    )
              | otherwise ->
                  restoreFromExactPair
                    callerSlot
                    generation
                    snapshot
                    operation
                    registered
                    predecessor
                    primary
                    backup
            PulumiCheckpointPairNoCurrentReference ->
              pure
                ( PulumiCheckpointRestoreRefused
                    "active checkpoint reference disappeared before restore"
                )
            PulumiCheckpointPairUnobservable detail ->
              pure (PulumiCheckpointRestoreUnavailable detail)
     where
      aggregate = authorityAdmissionSnapshotState snapshot
      checkpoints = authorityAggregatePulumiCheckpoints aggregate

  restoreFromExactPair
    callerSlot
    generation
    snapshot
    operation
    registered
    predecessor
    primary
    backup =
      case (exactPrimaryCopy predecessor primary, exactBackupCopy predecessor backup) of
        (Right True, Right True) ->
          applyRestore
            callerSlot
            generation
            snapshot
            operation
            registered
            predecessor
            predecessor
        (Right False, Right True) -> do
          restored <- restorePulumiCheckpointPrimary blobStore registered predecessor
          case restored of
            Left detail -> pure (PulumiCheckpointRestoreUnavailable detail)
            Right current ->
              applyRestore
                callerSlot
                generation
                snapshot
                operation
                registered
                predecessor
                current
        (_, Right False) ->
          pure
            ( PulumiCheckpointRestoreRefused
                "backup checkpoint is not current"
            )
        (Left (False, detail), _) ->
          pure (PulumiCheckpointRestoreRefused detail)
        (_, Left (False, detail)) ->
          pure (PulumiCheckpointRestoreRefused detail)
        (Left (True, detail), _) ->
          pure (PulumiCheckpointRestoreUnavailable detail)
        (_, Left (True, detail)) ->
          pure (PulumiCheckpointRestoreUnavailable detail)

  exactPrimaryCopy reference observation = case observation of
    PulumiCheckpointCopyCurrent version
      | version == verifiedPulumiCheckpointPrimaryVersion reference -> Right True
      | otherwise -> Left (False, "primary checkpoint version changed")
    PulumiCheckpointCopyMissing -> Right False
    PulumiCheckpointCopyCorrupt detail ->
      Left (False, "primary checkpoint is corrupt: " <> detail)
    PulumiCheckpointCopyUnobservable detail ->
      Left (True, "primary checkpoint is unobservable: " <> detail)

  exactBackupCopy reference observation = case observation of
    PulumiCheckpointCopyCurrent version
      | version == verifiedPulumiCheckpointBackupVersion reference -> Right True
      | otherwise -> Left (False, "backup checkpoint version changed")
    PulumiCheckpointCopyMissing -> Left (False, "backup checkpoint is missing")
    PulumiCheckpointCopyCorrupt detail ->
      Left (False, "backup checkpoint is corrupt: " <> detail)
    PulumiCheckpointCopyUnobservable detail ->
      Left (True, "backup checkpoint is unobservable: " <> detail)

  applyRestore
    callerSlot
    generation
    snapshot
    operation
    registered
    predecessor
    current =
      case stepAuthorityCheckpointRestore
        (verifiedCallerSlotPrincipal callerSlot)
        generation
        operation
        registered
        predecessor
        current
        (authorityAdmissionSnapshotState snapshot) of
        Left invariant -> pure (restoreInvariant invariant)
        Right (decision, next)
          | next /= authorityAdmissionSnapshotState snapshot -> do
              attempted <-
                compareAndSwapAuthorityAdmission
                  authorityRepository
                  (authorityAdmissionRevision snapshot)
                  next
              pure $ case attempted of
                Right () -> PulumiCheckpointRestoreApplied current
                Left detail -> PulumiCheckpointRestoreUnavailable detail
          | decision == CheckpointMutationAlreadyApplied ->
              pure (PulumiCheckpointRestoreAlreadyApplied current)
          | otherwise ->
              pure (PulumiCheckpointRestoreRefused (decisionText decision))

  readBackRestore callerSlot operation registered =
    case registeredGenerationForSlot callerSlot of
      Left detail -> pure (PulumiCheckpointRestoreReadBackRefused detail)
      Right generation -> do
        observed <- readAuthorityAdmission authorityRepository
        case observed of
          Left detail ->
            pure (PulumiCheckpointRestoreReadBackUnavailable detail)
          Right snapshot ->
            case authorityCheckpointOperationRef operation of
              Left detail ->
                pure
                  ( PulumiCheckpointRestoreReadBackRefused
                      ("authority operation identity is invalid: " <> Text.pack (show detail))
                  )
              Right operationReference ->
                confirmRestoreReadBack
                  callerSlot
                  generation
                  operation
                  operationReference
                  registered
                  (authorityAdmissionSnapshotState snapshot)

  confirmRestoreReadBack
    callerSlot
    generation
    operation
    operationReference
    registered
    aggregate =
      case authorityCheckpointOperationStatus
        (verifiedCallerSlotPrincipal callerSlot)
        generation
        operation
        aggregate of
        Left refusal ->
          pure
            ( PulumiCheckpointRestoreReadBackRefused
                ("restore operation binding is invalid: " <> Text.pack (show refusal))
            )
        Right operationStatus ->
          case observeCheckpointRestoreReadBack
            operationReference
            registered
            checkpoints of
            Nothing ->
              pure
                ( PulumiCheckpointRestoreReadBackRefused
                    "restore operation is not bound to this checkpoint"
                )
            Just CheckpointRestoreOperationPending
              | operationStatus == StatusInFlight ->
                  pure PulumiCheckpointRestorePending
              | otherwise ->
                  pure
                    ( PulumiCheckpointRestoreReadBackUnavailable
                        "restore operation is pending but its submission is not in flight"
                    )
            Just (CheckpointRestoreOperationApplied predecessor current)
              | operationStatus /= StatusSettled OperationCompletedOutcome ->
                  pure
                    ( PulumiCheckpointRestoreReadBackUnavailable
                        "restore operation is applied but its submission is not settled"
                    )
              | observeAuthorityPulumiCheckpoint registered checkpoints
                  /= Just current ->
                  pure
                    ( PulumiCheckpointRestoreReadBackRefused
                        "restored checkpoint reference is not current"
                    )
              | otherwise -> do
                  pair <- observePairInAggregate registered aggregate
                  pure $ case pair of
                    PulumiCheckpointPairCurrent actual primary backup
                      | actual /= current ->
                          PulumiCheckpointRestoreReadBackRefused
                            "restored checkpoint reference changed during read-back"
                      | otherwise ->
                          case (exactPrimaryCopy current primary, exactBackupCopy current backup) of
                            (Right True, Right True) ->
                              PulumiCheckpointRestoreConfirmed predecessor current
                            (Left (True, detail), _) ->
                              PulumiCheckpointRestoreReadBackUnavailable detail
                            (_, Left (True, detail)) ->
                              PulumiCheckpointRestoreReadBackUnavailable detail
                            (Left (_, detail), _) ->
                              PulumiCheckpointRestoreReadBackRefused detail
                            (_, Left (_, detail)) ->
                              PulumiCheckpointRestoreReadBackRefused detail
                            _ ->
                              PulumiCheckpointRestoreReadBackRefused
                                "restored checkpoint pair is incomplete"
                    PulumiCheckpointPairNoCurrentReference ->
                      PulumiCheckpointRestoreReadBackRefused
                        "restored checkpoint reference is no longer current"
                    PulumiCheckpointPairUnobservable detail ->
                      PulumiCheckpointRestoreReadBackUnavailable detail
     where
      checkpoints = authorityAggregatePulumiCheckpoints aggregate

  attemptRetirement callerSlot ticket disposition registered expectedReference =
    case registeredGenerationForSlot callerSlot of
      Left detail -> pure (PulumiCheckpointRetirementAttemptRefused detail)
      Right generation ->
        attemptRetirementForCaller
          callerSlot
          generation
          ticket
          disposition
          registered
          expectedReference

  attemptRetirementForCaller
    callerSlot
    generation
    ticket
    disposition
    registered
    expectedReference = do
      let operation = pulumiCheckpointTicketOperation ticket
          expected = pulumiCheckpointTicketExpectedDigest ticket
          expectedDigest = fmap verifiedPulumiCheckpointDigest expectedReference
      if expected /= expectedDigest
        then
          pure
            ( PulumiCheckpointRetirementAttemptRefused
                "retirement ticket does not bind the exact active reference"
            )
        else do
          prepared <-
            preparePermit
              callerSlot
              generation
              operation
              registered
              RetireCheckpoint
              expected
              (Just disposition)
          case prepared of
            CheckpointPermitRejected detail ->
              pure (PulumiCheckpointRetirementAttemptRefused detail)
            CheckpointPermitUnavailable detail ->
              pure (PulumiCheckpointRetirementAttemptUnavailable detail)
            CheckpointPermitReady snapshot operationReference ->
              authorizeAndRetire
                callerSlot
                generation
                snapshot
                operationReference
                operation
                registered
                expectedReference

  authorizeAndRetire
    callerSlot
    generation
    snapshot
    operationReference
    operation
    registered
    expectedReference
      | observeAuthorityPulumiCheckpoint registered checkpoints
          /= expectedReference =
          pure
            ( PulumiCheckpointRetirementAttemptRefused
                "active checkpoint reference changed before retirement"
            )
      | otherwise =
          case authorizeCheckpointRetirement
            operationReference
            registered
            checkpoints of
            Left invariant -> pure (retirementAttemptInvariant invariant)
            Right (CheckpointMutationAuthorizationRefused decision) ->
              pure (PulumiCheckpointRetirementAttemptRefused (decisionText decision))
            Right (CheckpointMutationAlreadyAppliedWith Nothing) ->
              pure PulumiCheckpointRetirementAlreadyApplied
            Right (CheckpointMutationAlreadyAppliedWith (Just _)) ->
              pure
                ( PulumiCheckpointRetirementAttemptRefused
                    "retirement operation retained an unexpected current reference"
                )
            Right CheckpointMutationAuthorized ->
              applyRetirementAttempt
                callerSlot
                generation
                snapshot
                operation
                registered
     where
      checkpoints =
        authorityAggregatePulumiCheckpoints
          (authorityAdmissionSnapshotState snapshot)

  applyRetirementAttempt callerSlot generation snapshot operation registered =
    case stepAuthorityCheckpointRetirement
      (verifiedCallerSlotPrincipal callerSlot)
      generation
      operation
      registered
      (authorityAdmissionSnapshotState snapshot) of
      Left invariant -> pure (retirementAttemptInvariant invariant)
      Right (decision, next)
        | next /= authorityAdmissionSnapshotState snapshot -> do
            attempted <-
              compareAndSwapAuthorityAdmission
                authorityRepository
                (authorityAdmissionRevision snapshot)
                next
            pure $ case attempted of
              Right () -> PulumiCheckpointRetirementApplied
              Left detail -> PulumiCheckpointRetirementAttemptUnavailable detail
        | decision == CheckpointMutationAlreadyApplied ->
            pure PulumiCheckpointRetirementAlreadyApplied
        | otherwise ->
            pure (PulumiCheckpointRetirementAttemptRefused (decisionText decision))

  readBackRetirement callerSlot operation registered =
    case registeredGenerationForSlot callerSlot of
      Left detail -> pure (PulumiCheckpointRetirementReadBackRefused detail)
      Right generation -> do
        observed <- readAuthorityAdmission authorityRepository
        case observed of
          Left detail ->
            pure (PulumiCheckpointRetirementReadBackUnavailable detail)
          Right snapshot ->
            case authorityCheckpointOperationRef operation of
              Left detail ->
                pure
                  ( PulumiCheckpointRetirementReadBackRefused
                      ("authority operation identity is invalid: " <> Text.pack (show detail))
                  )
              Right operationReference ->
                pure
                  ( confirmRetirementReadBack
                      callerSlot
                      generation
                      operation
                      operationReference
                      registered
                      (authorityAdmissionSnapshotState snapshot)
                  )

  confirmRetirementReadBack
    callerSlot
    generation
    operation
    operationReference
    registered
    aggregate =
      case authorityCheckpointOperationStatus
        (verifiedCallerSlotPrincipal callerSlot)
        generation
        operation
        aggregate of
        Left refusal ->
          PulumiCheckpointRetirementReadBackRefused
            ("retirement operation binding is invalid: " <> Text.pack (show refusal))
        Right operationStatus ->
          case observeCheckpointRetirementReadBack
            operationReference
            registered
            checkpoints of
            Nothing ->
              PulumiCheckpointRetirementReadBackRefused
                "retirement operation is not bound to this checkpoint"
            Just CheckpointRetirementOperationPending
              | operationStatus == StatusInFlight ->
                  PulumiCheckpointRetirementPending
              | otherwise ->
                  PulumiCheckpointRetirementReadBackUnavailable
                    "retirement operation is pending but its submission is not in flight"
            Just (CheckpointRetirementOperationApplied retiredReference)
              | operationStatus /= StatusSettled OperationCompletedOutcome ->
                  PulumiCheckpointRetirementReadBackUnavailable
                    "retirement operation is applied but its submission is not settled"
              | observeAuthorityPulumiCheckpoint registered checkpoints /= Nothing ->
                  PulumiCheckpointReferenceStillCurrent
                    (observeAuthorityPulumiCheckpoint registered checkpoints)
              | not
                  ( maybe
                      True
                      (`elem` observeRetiredAuthorityPulumiCheckpoints registered checkpoints)
                      retiredReference
                  ) ->
                  PulumiCheckpointRetirementReadBackRefused
                    "retired checkpoint reference is missing from the retained ledger"
              | otherwise -> PulumiCheckpointReferenceRetired retiredReference
     where
      checkpoints = authorityAggregatePulumiCheckpoints aggregate

  publish callerSlot ticket registered checkpoint =
    case registeredGenerationForSlot callerSlot of
      Left detail -> pure (PulumiCheckpointPublicationRefused detail)
      Right generation -> publishForCaller callerSlot generation ticket registered checkpoint

  publishForCaller callerSlot generation ticket registered checkpoint = do
    let operation = pulumiCheckpointTicketOperation ticket
        expected = pulumiCheckpointTicketExpectedDigest ticket
    prepared <-
      preparePermit
        callerSlot
        generation
        operation
        registered
        PublishCheckpoint
        expected
        Nothing
    case prepared of
      CheckpointPermitRejected detail ->
        pure (PulumiCheckpointPublicationRefused detail)
      CheckpointPermitUnavailable detail ->
        pure (PulumiCheckpointPublicationUnavailable detail)
      CheckpointPermitReady snapshot operationReference ->
        case authorizeCheckpointPublication
          operationReference
          registered
          (canonicalPulumiCheckpointDigest checkpoint)
          ( authorityAggregatePulumiCheckpoints
              (authorityAdmissionSnapshotState snapshot)
          ) of
          Left invariant -> pure (publicationInvariant invariant)
          Right (CheckpointMutationAuthorizationRefused decision) ->
            pure (PulumiCheckpointPublicationRefused (decisionText decision))
          Right (CheckpointMutationAlreadyAppliedWith (Just reference)) ->
            confirmPublication callerSlot generation (Right ()) False operation registered reference
          Right (CheckpointMutationAlreadyAppliedWith Nothing) ->
            pure
              ( PulumiCheckpointPublicationRefused
                  "publication operation has no checkpoint reference"
              )
          Right CheckpointMutationAuthorized -> do
            replicated <-
              replicatePulumiCheckpointBlob blobStore registered checkpoint
            case replicated of
              Left detail ->
                pure (PulumiCheckpointPublicationUnavailable detail)
              Right reference ->
                applyPublication callerSlot generation snapshot operation registered reference

  applyPublication callerSlot generation snapshot operation registered reference =
    case stepAuthorityCheckpointPublication
      (verifiedCallerSlotPrincipal callerSlot)
      generation
      operation
      registered
      reference
      (authorityAdmissionSnapshotState snapshot) of
      Left invariant -> pure (publicationInvariant invariant)
      Right (decision, next)
        | next /= authorityAdmissionSnapshotState snapshot -> do
            attempted <-
              compareAndSwapAuthorityAdmission
                authorityRepository
                (authorityAdmissionRevision snapshot)
                next
            confirmPublication
              callerSlot
              generation
              attempted
              (decision == CheckpointMutationApplied)
              operation
              registered
              reference
        | decision == CheckpointMutationAlreadyApplied ->
            confirmPublication callerSlot generation (Right ()) False operation registered reference
        | otherwise ->
            pure (PulumiCheckpointPublicationRefused (decisionText decision))

  confirmPublication callerSlot generation attempted newlyApplied operation registered reference = do
    readback <- readAuthorityAdmission authorityRepository
    case readback of
      Left detail ->
        pure
          ( PulumiCheckpointPublicationUnavailable
              (confirmationFailure attempted detail)
          )
      Right confirmed -> do
        let aggregate = authorityAdmissionSnapshotState confirmed
        case ( authorityCheckpointOperationStatus
                 (verifiedCallerSlotPrincipal callerSlot)
                 generation
                 operation
                 aggregate
             , observeAuthorityPulumiCheckpoint
                 registered
                 (authorityAggregatePulumiCheckpoints aggregate)
             ) of
          (Right (StatusSettled OperationCompletedOutcome), Just actual)
            | actual == reference ->
                confirmReferencedBlob newlyApplied registered reference
          (_, Just actual)
            | actual == reference ->
                pure
                  ( PulumiCheckpointPublicationUnavailable
                      "checkpoint publication is current but its submission is not settled"
                  )
          _ -> do
            conflict <- observeAggregateCheckpoint blobStore registered aggregate
            pure (PulumiCheckpointPublicationConflict conflict)

  confirmReferencedBlob newlyApplied registered reference = do
    observed <- observePulumiCheckpointBlob blobStore registered reference
    pure $ case observed of
      PulumiCheckpointCurrent checkpoint
        | canonicalPulumiCheckpointDigest checkpoint
            == verifiedPulumiCheckpointDigest reference ->
            if newlyApplied
              then
                PulumiCheckpointPublished
                  (verifiedPulumiCheckpointDigest reference)
              else
                PulumiCheckpointAlreadyCurrent
                  (verifiedPulumiCheckpointDigest reference)
        | otherwise ->
            PulumiCheckpointPublicationConflict
              (PulumiCheckpointCorrupt "checkpoint reference digest mismatch")
      PulumiCheckpointEndpointUnready detail ->
        PulumiCheckpointPublicationUnavailable detail
      PulumiCheckpointUnobservable detail ->
        PulumiCheckpointPublicationUnavailable detail
      other -> PulumiCheckpointPublicationConflict other

  retire callerSlot ticket disposition registered =
    case registeredGenerationForSlot callerSlot of
      Left detail -> pure (PulumiCheckpointRetirementUnavailable detail)
      Right generation ->
        retireForCaller callerSlot generation ticket disposition registered

  retireForCaller callerSlot generation ticket disposition registered = do
    let operation = pulumiCheckpointTicketOperation ticket
        expected = pulumiCheckpointTicketExpectedDigest ticket
    prepared <-
      preparePermit
        callerSlot
        generation
        operation
        registered
        RetireCheckpoint
        expected
        (Just disposition)
    case prepared of
      CheckpointPermitRejected _ -> do
        current <- observeCurrent callerSlot registered
        pure (PulumiCheckpointRetirementRefused current)
      CheckpointPermitUnavailable detail ->
        pure (PulumiCheckpointRetirementUnavailable detail)
      CheckpointPermitReady snapshot operationReference ->
        case authorizeCheckpointRetirement
          operationReference
          registered
          ( authorityAggregatePulumiCheckpoints
              (authorityAdmissionSnapshotState snapshot)
          ) of
          Left invariant -> pure (retirementInvariant invariant)
          Right (CheckpointMutationAuthorizationRefused _) -> do
            current <-
              observeAggregateCheckpoint
                blobStore
                registered
                (authorityAdmissionSnapshotState snapshot)
            pure (PulumiCheckpointRetirementRefused current)
          Right (CheckpointMutationAlreadyAppliedWith Nothing) ->
            confirmRetirement callerSlot generation (Right ()) False operation registered
          Right (CheckpointMutationAlreadyAppliedWith (Just _)) ->
            pure
              ( PulumiCheckpointRetirementUnavailable
                  "retirement operation unexpectedly retained a checkpoint reference"
              )
          Right CheckpointMutationAuthorized ->
            applyRetirement callerSlot generation snapshot operation registered

  applyRetirement callerSlot generation snapshot operation registered =
    case stepAuthorityCheckpointRetirement
      (verifiedCallerSlotPrincipal callerSlot)
      generation
      operation
      registered
      (authorityAdmissionSnapshotState snapshot) of
      Left invariant -> pure (retirementInvariant invariant)
      Right (decision, next)
        | next /= authorityAdmissionSnapshotState snapshot -> do
            attempted <-
              compareAndSwapAuthorityAdmission
                authorityRepository
                (authorityAdmissionRevision snapshot)
                next
            confirmRetirement
              callerSlot
              generation
              attempted
              (decision == CheckpointMutationApplied)
              operation
              registered
        | decision == CheckpointMutationAlreadyApplied ->
            confirmRetirement callerSlot generation (Right ()) False operation registered
        | otherwise -> do
            current <-
              observeAggregateCheckpoint
                blobStore
                registered
                (authorityAdmissionSnapshotState snapshot)
            pure (PulumiCheckpointRetirementRefused current)

  confirmRetirement callerSlot generation attempted newlyApplied operation registered = do
    readback <- readAuthorityAdmission authorityRepository
    case readback of
      Left detail ->
        pure
          ( PulumiCheckpointRetirementUnavailable
              (confirmationFailure attempted detail)
          )
      Right confirmed ->
        let aggregate = authorityAdmissionSnapshotState confirmed
         in case ( authorityCheckpointOperationStatus
                     (verifiedCallerSlotPrincipal callerSlot)
                     generation
                     operation
                     aggregate
                 , observeAuthorityPulumiCheckpoint
                     registered
                     (authorityAggregatePulumiCheckpoints aggregate)
                 ) of
              (Right (StatusSettled OperationCompletedOutcome), Nothing) ->
                pure
                  ( if newlyApplied
                      then PulumiCheckpointRetiredAndReadBack
                      else PulumiCheckpointAlreadyAbsent
                  )
              (_, Nothing) ->
                pure
                  ( PulumiCheckpointRetirementUnavailable
                      "checkpoint is absent but its retirement submission is not settled"
                  )
              (_, Just _) -> do
                current <-
                  observeAggregateCheckpoint
                    blobStore
                    registered
                    aggregate
                pure (PulumiCheckpointRetirementRefused current)

  preparePermit callerSlot generation operation registered kind expected disposition = do
    observed <- readAuthorityAdmission authorityRepository
    case observed of
      Left detail -> pure (CheckpointPermitUnavailable detail)
      Right snapshot ->
        case stepAuthorityCheckpointPermit
          (verifiedCallerSlotPrincipal callerSlot)
          generation
          operation
          registered
          kind
          expected
          disposition
          (authorityAdmissionSnapshotState snapshot) of
          Left invariant ->
            pure
              ( CheckpointPermitRejected
                  ("authority checkpoint invariant failed: " <> Text.pack (show invariant))
              )
          Right (CheckpointPermitAlreadyRegistered, _) ->
            readyPermit snapshot operation
          Right (CheckpointPermitRegistered, next) -> do
            attempted <-
              compareAndSwapAuthorityAdmission
                authorityRepository
                (authorityAdmissionRevision snapshot)
                next
            confirmPermit
              callerSlot
              generation
              attempted
              operation
              registered
              kind
              expected
              disposition
          Right (decision, _) ->
            pure (permitDecisionFailure decision)

  confirmPermit callerSlot generation attempted operation registered kind expected disposition = do
    readback <- readAuthorityAdmission authorityRepository
    case readback of
      Left detail ->
        pure
          ( CheckpointPermitUnavailable
              (confirmationFailure attempted detail)
          )
      Right snapshot ->
        case stepAuthorityCheckpointPermit
          (verifiedCallerSlotPrincipal callerSlot)
          generation
          operation
          registered
          kind
          expected
          disposition
          (authorityAdmissionSnapshotState snapshot) of
          Right (CheckpointPermitAlreadyRegistered, _) ->
            readyPermit snapshot operation
          _ ->
            pure
              ( CheckpointPermitUnavailable
                  ( fromAttempt
                      attempted
                      "checkpoint permit CAS was not confirmed by read-back"
                  )
              )

  readyPermit snapshot operation =
    pure $ case authorityCheckpointOperationRef operation of
      Left detail ->
        CheckpointPermitRejected
          ("authority operation identity is not representable: " <> Text.pack (show detail))
      Right reference -> CheckpointPermitReady snapshot reference

observeAggregateCheckpoint
  :: (Monad m)
  => PulumiCheckpointBlobStore m
  -> RegisteredPulumiCheckpoint
  -> AuthorityAdmissionAggregate
  -> m PulumiCheckpointObservation
observeAggregateCheckpoint blobStore registered aggregate =
  case observeAuthorityPulumiCheckpoint
    registered
    (authorityAggregatePulumiCheckpoints aggregate) of
    Nothing -> pure PulumiCheckpointMissing
    Just reference -> do
      observed <- observePulumiCheckpointBlob blobStore registered reference
      pure $ case observed of
        PulumiCheckpointMissing ->
          PulumiCheckpointCorruptAt
            (verifiedPulumiCheckpointDigest reference)
            "authority aggregate references a missing checkpoint blob"
        PulumiCheckpointCurrent checkpoint
          | canonicalPulumiCheckpointDigest checkpoint
              == verifiedPulumiCheckpointDigest reference ->
              PulumiCheckpointCurrent checkpoint
          | otherwise ->
              PulumiCheckpointCorruptAt
                (verifiedPulumiCheckpointDigest reference)
                "authority aggregate checkpoint digest does not match blob"
        PulumiCheckpointCorrupt detail ->
          PulumiCheckpointCorruptAt
            (verifiedPulumiCheckpointDigest reference)
            detail
        other -> other

publicationInvariant :: (Show invariant) => invariant -> PulumiCheckpointPublicationResult
publicationInvariant =
  PulumiCheckpointPublicationRefused
    . ("authority checkpoint invariant failed: " <>)
    . Text.pack
    . show

retirementInvariant :: (Show invariant) => invariant -> PulumiCheckpointRetirementResult
retirementInvariant =
  PulumiCheckpointRetirementUnavailable
    . ("authority checkpoint invariant failed: " <>)
    . Text.pack
    . show

restoreInvariant :: (Show invariant) => invariant -> PulumiCheckpointRestoreResult
restoreInvariant =
  PulumiCheckpointRestoreRefused
    . ("authority checkpoint invariant failed: " <>)
    . Text.pack
    . show

retirementAttemptInvariant
  :: (Show invariant)
  => invariant
  -> PulumiCheckpointRetirementAttemptResult
retirementAttemptInvariant =
  PulumiCheckpointRetirementAttemptRefused
    . ("authority checkpoint invariant failed: " <>)
    . Text.pack
    . show

decisionText :: CheckpointMutationDecision -> Text
decisionText = Text.pack . show

permitDecisionFailure
  :: CheckpointPermitDecision -> CheckpointPermitPreparation revision
permitDecisionFailure decision = case decision of
  CheckpointPermitRefusedCapacity ->
    CheckpointPermitUnavailable "checkpoint permit capacity is exhausted"
  CheckpointPermitRegistered ->
    CheckpointPermitUnavailable "checkpoint permit registration was not committed"
  CheckpointPermitAlreadyRegistered ->
    CheckpointPermitUnavailable "checkpoint permit read-back was not confirmed"
  _ -> CheckpointPermitRejected (Text.pack (show decision))

fromAttempt :: Either Text () -> Text -> Text
fromAttempt attempted fallback = case attempted of
  Left detail -> detail <> "; " <> fallback
  Right () -> fallback

confirmationFailure :: Either Text () -> Text -> Text
confirmationFailure attempted readback =
  case attempted of
    Left detail -> detail <> "; checkpoint aggregate readback failed: " <> readback
    Right () -> "checkpoint aggregate readback failed: " <> readback
