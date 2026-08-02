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
  ( PulumiCheckpointMutationTicket (..)
  , PulumiCheckpointObservation (..)
  , PulumiCheckpointPublicationResult (..)
  , PulumiCheckpointRepository (..)
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
  , stepAuthorityCheckpointRetirement
  )
import Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry
  ( CheckpointMutationAuthorization (..)
  , CheckpointMutationDecision (..)
  , CheckpointOperationKind (..)
  , CheckpointPermitDecision (..)
  , VerifiedPulumiCheckpointRef
  , authorizeCheckpointPublication
  , authorizeCheckpointRetirement
  , observeAuthorityPulumiCheckpoint
  , verifiedPulumiCheckpointDigest
  )
import Prodbox.Lifecycle.Authority.Submission
  ( SubmissionStatus (StatusSettled)
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
      , publishRegisteredPulumiCheckpoint = publish
      , retireRegisteredPulumiCheckpoint = retire
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

  publish callerSlot ticket registered checkpoint =
    case registeredGenerationForSlot callerSlot of
      Left detail -> pure (PulumiCheckpointPublicationRefused detail)
      Right generation -> publishForCaller callerSlot generation ticket registered checkpoint

  publishForCaller callerSlot generation ticket registered checkpoint = do
    let operation = pulumiCheckpointTicketOperation ticket
        expected = pulumiCheckpointTicketExpectedDigest ticket
    prepared <- preparePermit callerSlot generation operation registered PublishCheckpoint expected
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

  retire callerSlot ticket registered =
    case registeredGenerationForSlot callerSlot of
      Left detail -> pure (PulumiCheckpointRetirementUnavailable detail)
      Right generation -> retireForCaller callerSlot generation ticket registered

  retireForCaller callerSlot generation ticket registered = do
    let operation = pulumiCheckpointTicketOperation ticket
        expected = pulumiCheckpointTicketExpectedDigest ticket
    prepared <- preparePermit callerSlot generation operation registered RetireCheckpoint expected
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

  preparePermit callerSlot generation operation registered kind expected = do
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
            confirmPermit callerSlot generation attempted operation registered kind expected
          Right (decision, _) ->
            pure (permitDecisionFailure decision)

  confirmPermit callerSlot generation attempted operation registered kind expected = do
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
