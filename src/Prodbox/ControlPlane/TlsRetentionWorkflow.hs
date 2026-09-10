{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Host-side orchestration for public-edge TLS custody.  The coordinator
-- carries only opaque certificate ciphertext, Transit ciphertext, signed
-- receipts, and Authority references.  The selected Agent is the sole
-- Kubernetes Secret reader/writer and the retained-home Agent is the sole
-- Transit DEK holder.
module Prodbox.ControlPlane.TlsRetentionWorkflow
  ( TlsRetentionWorkflow (..)
  , TlsWorkflowRetainOutcome (..)
  , TlsWorkflowRestoreOutcome (..)
  , TlsRetentionWorkflowError (..)
  , retainPublicEdgeTlsWorkflow
  , restorePublicEdgeTlsWorkflow
  )
where

import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.TlsDekExchange
  ( mkTlsWrappedDek
  , tlsDekPreparedPublicKey
  , tlsWrappedDekText
  )
import Prodbox.ControlPlane.TlsRetentionAuthorityClient
  ( TlsAuthorityPromotionOutcome (..)
  , TlsAuthorityStagingOutcome (..)
  , TlsRetentionAuthorityClient (..)
  , TlsRetentionAuthorityClientError
  )
import Prodbox.ControlPlane.TlsRetentionClient
  ( TlsRetentionClient (..)
  , TlsRetentionClientError (..)
  , TlsRetentionHttpResponseObservation (..)
  )
import Prodbox.ControlPlane.TlsRetentionEndpoint
  ( TlsEnvelopeObservation (..)
  , TlsRetentionPlainResponseCause (..)
  , TlsRetentionReceipt (..)
  , TlsStoreConfirmationFailure (..)
  , TlsStorePutDisposition (..)
  , TlsStoreRepositoryFailure (..)
  , TlsVersionEnvelopeObservation (..)
  )
import Prodbox.ControlPlane.TlsTargetAgentClient
  ( TlsTargetAgentClient (..)
  , TlsTargetAgentClientError (..)
  )
import Prodbox.ControlPlane.TlsTargetAgentEndpoint
  ( TlsTargetRestoreReceipt (..)
  , TlsTargetRetainReceipt (..)
  )
import Prodbox.Lifecycle.Authority.TlsRetention
  ( CertIdentity (..)
  , KeyRotationApproval
  , PromotionEvidence (..)
  , RestoreObservation (..)
  , RetainedTlsRef (..)
  , RetentionVersion (..)
  , TlsLegacyRecoveryCollisionEvidence (..)
  , TlsLegacyRecoveryEvidence (..)
  , TlsLegacyRecoverySuccessorEvidence (..)
  , TlsRestoreDecision (..)
  , TlsRestoreRefusal
  , TlsRetentionPending (..)
  , TlsRetentionState (..)
  , TlsSealedEnvelope
  , currentRetainedRef
  , decideTlsRestore
  , mkTlsSealedEnvelope
  , nextRetentionVersion
  , pendingTlsRetention
  , tlsCertificateCiphertextBytes
  , tlsSealedEnvelopeDigest
  , tlsWrappedDekBytes
  )

data TlsRetentionWorkflow m = TlsRetentionWorkflow
  { tlsWorkflowAuthority :: !(TlsRetentionAuthorityClient m)
  , tlsWorkflowAdapter :: !(TlsRetentionClient m)
  , tlsWorkflowRetainedHomeAgent :: !(TlsTargetAgentClient m)
  , tlsWorkflowSelectedAgent :: !(TlsTargetAgentClient m)
  }

data TlsWorkflowRetainOutcome
  = TlsWorkflowNothingToRetain
  | TlsWorkflowRetained !RetainedTlsRef
  deriving stock (Eq, Show)

data TlsWorkflowRestoreOutcome
  = TlsWorkflowRestored !RetainedTlsRef
  | TlsWorkflowIssuancePermitted
  deriving stock (Eq, Show)

data TlsRetentionWorkflowError
  = TlsWorkflowAuthorityFailed !TlsRetentionAuthorityClientError
  | TlsWorkflowAdapterFailed !TlsRetentionClientError
  | TlsWorkflowHomeAgentFailed !TlsTargetAgentClientError
  | TlsWorkflowSelectedAgentFailed !TlsTargetAgentClientError
  | TlsWorkflowEnvelopeInvalid !Text
  | TlsWorkflowAdapterReadBackMismatch
  | TlsWorkflowSourceReadBackMismatch
  | TlsWorkflowStagingStateMismatch
  | TlsWorkflowPromotionStateMismatch
  | TlsWorkflowLegacyEnvelopeCorrupt
  | TlsWorkflowLegacySourceMissing
  | TlsWorkflowLegacyAdoptionNotIdempotent
  | TlsWorkflowPendingWithoutCurrent
  | TlsWorkflowRestoreRefused !TlsRestoreRefusal
  | TlsWorkflowWrappedDekInvalid
  deriving stock (Eq, Show)

retainPublicEdgeTlsWorkflow
  :: TlsRetentionWorkflow IO
  -> KeyRotationApproval
  -> IO (Either TlsRetentionWorkflowError TlsWorkflowRetainOutcome)
retainPublicEdgeTlsWorkflow workflow approval = do
  observed <- observeTlsRetentionCurrent (tlsWorkflowAuthority workflow)
  case first TlsWorkflowAuthorityFailed observed of
    Left err -> pure (Left err)
    Right state -> case pendingTlsRetention state of
      Just pending -> resumePending state pending
      Nothing -> do
        let version = nextRetentionVersion state
        case currentRetainedRef state of
          Just _ -> createFresh state version
          Nothing -> do
            occupied <-
              observeTlsRetentionVersion
                (tlsWorkflowAdapter workflow)
                version
            case first TlsWorkflowAdapterFailed occupied of
              Left err -> pure (Left err)
              Right TlsVersionEnvelopeMissing -> createFresh state version
              Right TlsVersionEnvelopeCorrupt ->
                pure (Left TlsWorkflowLegacyEnvelopeCorrupt)
              Right (TlsVersionEnvelopePresent envelope _) ->
                adoptLegacy state version envelope
 where
  createFresh state version = do
    homePreparedResult <-
      prepareTlsDekDestination (tlsWorkflowRetainedHomeAgent workflow)
    case first TlsWorkflowHomeAgentFailed homePreparedResult of
      Left err -> pure (Left err)
      Right homePrepared -> do
        retainedResult <-
          retainSelectedPublicEdgeTls
            (tlsWorkflowSelectedAgent workflow)
            version
            (tlsDekPreparedPublicKey homePrepared)
        case retainedResult of
          Left (TlsTargetAgentClientHttpStatus 404 _) ->
            pure (Right TlsWorkflowNothingToRetain)
          Left err -> pure (Left (TlsWorkflowSelectedAgentFailed err))
          Right retained -> do
            wrappedResult <-
              wrapRetainedHomeTlsDek
                (tlsWorkflowRetainedHomeAgent workflow)
                homePrepared
                (tlsTargetRetainedDekEnvelope retained)
            case first TlsWorkflowHomeAgentFailed wrappedResult of
              Left err -> pure (Left err)
              Right wrapped ->
                case mkTlsSealedEnvelope
                  (tlsTargetRetainedCertificateCiphertext retained)
                  (TextEncoding.encodeUtf8 (tlsWrappedDekText wrapped)) of
                  Left detail -> pure (Left (TlsWorkflowEnvelopeInvalid detail))
                  Right envelope ->
                    stageAndResume
                      state
                      approval
                      (referenceFor version retained envelope)
                      envelope

  adoptLegacy state version envelope = do
    homePreparedResult <-
      prepareTlsDekDestination (tlsWorkflowRetainedHomeAgent workflow)
    case first TlsWorkflowHomeAgentFailed homePreparedResult of
      Left err -> pure (Left err)
      Right homePrepared -> do
        retainedResult <-
          retainSelectedPublicEdgeTls
            (tlsWorkflowSelectedAgent workflow)
            version
            (tlsDekPreparedPublicKey homePrepared)
        case retainedResult of
          Left (TlsTargetAgentClientHttpStatus 404 _) ->
            pure (Left TlsWorkflowLegacySourceMissing)
          Left err -> pure (Left (TlsWorkflowSelectedAgentFailed err))
          Right retained -> do
            let candidate = referenceFor version retained envelope
            applied <- applyTlsEnvelopeAtSelected workflow candidate envelope
            case applied of
              Left
                ( TlsWorkflowHomeAgentFailed
                    TlsTargetAgentClientHomeRewrapCiphertextAuthenticationFailed
                  ) ->
                  recoverUnopenableLegacy state version envelope
              Left err -> pure (Left err)
              Right receipt
                | tlsTargetRestoredReadBackSource receipt
                    == retainedSourceSecret candidate ->
                    stageAndResume state approval candidate envelope
                | otherwise ->
                    pure (Left TlsWorkflowLegacyAdoptionNotIdempotent)

  recoverUnopenableLegacy state version legacyEnvelope =
    case (state, version) of
      (TlsRetentionEmpty, RetentionVersion 1) -> do
        let recoveryEvidence =
              TlsLegacyRecoveryEvidence
                { tlsLegacyRecoveryVersion = version
                , tlsLegacyRecoveryEnvelopeDigest =
                    tlsSealedEnvelopeDigest legacyEnvelope
                }
            recoveryVersion = RetentionVersion 2
        homePreparedResult <-
          prepareTlsDekDestination (tlsWorkflowRetainedHomeAgent workflow)
        case first TlsWorkflowHomeAgentFailed homePreparedResult of
          Left err -> pure (Left err)
          Right homePrepared -> do
            retainedResult <-
              retainSelectedPublicEdgeTls
                (tlsWorkflowSelectedAgent workflow)
                recoveryVersion
                (tlsDekPreparedPublicKey homePrepared)
            case retainedResult of
              Left (TlsTargetAgentClientHttpStatus 404 _) ->
                pure (Left TlsWorkflowLegacySourceMissing)
              Left err -> pure (Left (TlsWorkflowSelectedAgentFailed err))
              Right retained -> do
                wrappedResult <-
                  wrapRetainedHomeTlsDek
                    (tlsWorkflowRetainedHomeAgent workflow)
                    homePrepared
                    (tlsTargetRetainedDekEnvelope retained)
                case first TlsWorkflowHomeAgentFailed wrappedResult of
                  Left err -> pure (Left err)
                  Right wrapped ->
                    case mkTlsSealedEnvelope
                      (tlsTargetRetainedCertificateCiphertext retained)
                      (TextEncoding.encodeUtf8 (tlsWrappedDekText wrapped)) of
                      Left detail -> pure (Left (TlsWorkflowEnvelopeInvalid detail))
                      Right envelope ->
                        stageLegacyRecoveryAndResume
                          approval
                          recoveryEvidence
                          Nothing
                          (referenceFor recoveryVersion retained envelope)
                          envelope
      _ -> pure (Left TlsWorkflowLegacyAdoptionNotIdempotent)

  referenceFor version retained envelope =
    RetainedTlsRef
      { retainedVersion = version
      , retainedCert = tlsTargetRetainedCertificate retained
      , retainedCiphertextDigest = tlsSealedEnvelopeDigest envelope
      , retainedSourceSecret = tlsTargetRetainedSource retained
      }

  stageAndResume state stagedApproval candidate envelope = do
    staged <-
      stageTlsRetentionCurrent
        (tlsWorkflowAuthority workflow)
        stagedApproval
        candidate
        envelope
    case first TlsWorkflowAuthorityFailed staged of
      Left err -> pure (Left err)
      Right outcome ->
        let expected =
              TlsRetentionPending
                { tlsPendingPrevious = currentRetainedRef state
                , tlsPendingApproval = stagedApproval
                , tlsPendingCandidate = candidate
                , tlsPendingEnvelope = envelope
                }
         in case validateStaging expected outcome of
              Left err -> pure (Left err)
              Right pending -> resumePending (stagingOutcomeState outcome) pending

  stageLegacyRecoveryAndResume stagedApproval evidence collision candidate envelope = do
    staged <-
      stageTlsRetentionAfterUnrecoverableLegacy
        (tlsWorkflowAuthority workflow)
        stagedApproval
        evidence
        collision
        candidate
        envelope
    case first TlsWorkflowAuthorityFailed staged of
      Left err -> pure (Left err)
      Right outcome ->
        let expected =
              TlsRetentionPending
                { tlsPendingPrevious = Nothing
                , tlsPendingApproval = stagedApproval
                , tlsPendingCandidate = candidate
                , tlsPendingEnvelope = envelope
                }
         in case validateLegacyRecoveryStaging evidence expected outcome of
              Left err -> pure (Left err)
              Right pending -> resumePending (stagingOutcomeState outcome) pending

  resumePending state pending = do
    stored <-
      storeTlsRetention
        (tlsWorkflowAdapter workflow)
        (tlsPendingCandidate pending)
        (tlsPendingEnvelope pending)
    case stored of
      Left clientError
        | isExactImmutableCollision clientError ->
            recoverImmutableCollision state pending clientError
        | otherwise -> pure (Left (TlsWorkflowAdapterFailed clientError))
      Right _ -> confirmAndPromote pending

  recoverImmutableCollision state pending originalError = case state of
    TlsRetentionLegacyRecoveryPendingState evidence durablePending
      | durablePending == pending -> do
          let pendingCandidate = tlsPendingCandidate pending
              version = retainedVersion pendingCandidate
          observed <-
            observeTlsRetentionAuthorityVersion
              (tlsWorkflowAdapter workflow)
              version
          case first TlsWorkflowAdapterFailed observed of
            Left err -> pure (Left err)
            Right (TlsVersionEnvelopePresent occupiedEnvelope _) -> do
              let occupiedCandidate =
                    pendingCandidate
                      { retainedCiphertextDigest = tlsSealedEnvelopeDigest occupiedEnvelope
                      }
                  collision =
                    TlsLegacyRecoveryCollisionEvidence
                      { tlsLegacyRecoveryCollisionVersion = version
                      , tlsLegacyRecoveryPendingEnvelopeDigest =
                          retainedCiphertextDigest pendingCandidate
                      , tlsLegacyRecoveryObservedEnvelopeDigest =
                          retainedCiphertextDigest occupiedCandidate
                      }
              applied <- applyTlsEnvelopeAtSelected workflow occupiedCandidate occupiedEnvelope
              case applied of
                Left
                  ( TlsWorkflowHomeAgentFailed
                      TlsTargetAgentClientHomeRewrapCiphertextAuthenticationFailed
                    ) ->
                    recoverUnopenableCollision evidence collision pending
                Left err -> pure (Left err)
                Right receipt
                  | tlsTargetRestoredReadBackSource receipt
                      == retainedSourceSecret occupiedCandidate ->
                      stageLegacyRecoveryAndResume
                        (tlsPendingApproval pending)
                        evidence
                        (Just collision)
                        occupiedCandidate
                        occupiedEnvelope
                  | otherwise -> pure (Left TlsWorkflowSourceReadBackMismatch)
            Right _ -> pure (Left (TlsWorkflowAdapterFailed originalError))
    _ -> pure (Left (TlsWorkflowAdapterFailed originalError))

  recoverUnopenableCollision evidence collision displaced = do
    let successorVersion = RetentionVersion 3
        displacedApproval = tlsPendingApproval displaced
    homePreparedResult <-
      prepareTlsDekDestination (tlsWorkflowRetainedHomeAgent workflow)
    case first TlsWorkflowHomeAgentFailed homePreparedResult of
      Left err -> pure (Left err)
      Right homePrepared -> do
        retainedResult <-
          retainSelectedPublicEdgeTls
            (tlsWorkflowSelectedAgent workflow)
            successorVersion
            (tlsDekPreparedPublicKey homePrepared)
        case retainedResult of
          Left (TlsTargetAgentClientHttpStatus 404 _) ->
            pure (Left TlsWorkflowLegacySourceMissing)
          Left err -> pure (Left (TlsWorkflowSelectedAgentFailed err))
          Right retained -> do
            wrappedResult <-
              wrapRetainedHomeTlsDek
                (tlsWorkflowRetainedHomeAgent workflow)
                homePrepared
                (tlsTargetRetainedDekEnvelope retained)
            case first TlsWorkflowHomeAgentFailed wrappedResult of
              Left err -> pure (Left err)
              Right wrapped ->
                case mkTlsSealedEnvelope
                  (tlsTargetRetainedCertificateCiphertext retained)
                  (TextEncoding.encodeUtf8 (tlsWrappedDekText wrapped)) of
                  Left detail -> pure (Left (TlsWorkflowEnvelopeInvalid detail))
                  Right envelope ->
                    stageLegacyRecoverySuccessorAndResume
                      displacedApproval
                      evidence
                      collision
                      displaced
                      (referenceFor successorVersion retained envelope)
                      envelope

  stageLegacyRecoverySuccessorAndResume
    stagedApproval
    evidence
    collision
    displaced
    candidate
    envelope = do
      staged <-
        stageTlsRetentionAfterUnrecoverableLegacy
          (tlsWorkflowAuthority workflow)
          stagedApproval
          evidence
          (Just collision)
          candidate
          envelope
      case first TlsWorkflowAuthorityFailed staged of
        Left err -> pure (Left err)
        Right outcome ->
          let expectedPending =
                TlsRetentionPending
                  { tlsPendingPrevious = Nothing
                  , tlsPendingApproval = stagedApproval
                  , tlsPendingCandidate = candidate
                  , tlsPendingEnvelope = envelope
                  }
              expectedSuccessor =
                TlsLegacyRecoverySuccessorEvidence
                  { tlsLegacyRecoverySuccessorCollision = collision
                  , tlsLegacyRecoveryDisplacedApproval = tlsPendingApproval displaced
                  , tlsLegacyRecoveryDisplacedCandidate = tlsPendingCandidate displaced
                  }
           in case validateLegacyRecoverySuccessorStaging
                evidence
                expectedSuccessor
                expectedPending
                outcome of
                Left err -> pure (Left err)
                Right pending -> resumePending (stagingOutcomeState outcome) pending

  confirmAndPromote pending = do
    let candidate = tlsPendingCandidate pending
        envelope = tlsPendingEnvelope pending
    readBack <- restoreTlsRetention (tlsWorkflowAdapter workflow) candidate
    case first TlsWorkflowAdapterFailed readBack of
      Left err -> pure (Left err)
      Right (TlsEnvelopePresent readBackEnvelope receipt)
        | readBackEnvelope == envelope
            && tlsRetentionReceiptReference receipt == candidate -> do
            sourceReadBack <-
              verifySelectedPublicEdgeTlsSource
                (tlsWorkflowSelectedAgent workflow)
                candidate
            case first TlsWorkflowSelectedAgentFailed sourceReadBack of
              Left err -> pure (Left err)
              Right _ -> do
                promoted <-
                  promoteTlsRetentionCurrent
                    (tlsWorkflowAuthority workflow)
                    (tlsPendingApproval pending)
                    PromotionEvidence
                      { evidenceSourceReobserved = True
                      , evidenceAdapterReadBack = True
                      }
                    candidate
                pure $ do
                  outcome <- first TlsWorkflowAuthorityFailed promoted
                  validatePromotion candidate outcome
                  Right (TlsWorkflowRetained candidate)
        | otherwise -> pure (Left TlsWorkflowAdapterReadBackMismatch)
      Right _ -> pure (Left TlsWorkflowAdapterReadBackMismatch)

  stagingOutcomeState outcome = case outcome of
    TlsAuthorityStagingCommitted value -> value
    TlsAuthorityStagingAlreadyPending value -> value

  isExactImmutableCollision clientError = case clientError of
    TlsRetentionClientHttpStatus
      ( TlsRetentionEndpointResponse
          ( TlsRetentionStoreRepositoryFailed
              ( TlsStoreRepositoryConfirmationFailed
                  TlsStorePutConflict
                  TlsStoreConfirmationBytesMismatch
                )
            )
        ) -> True
    _ -> False

applyTlsEnvelopeAtSelected
  :: TlsRetentionWorkflow IO
  -> RetainedTlsRef
  -> TlsSealedEnvelope
  -> IO (Either TlsRetentionWorkflowError TlsTargetRestoreReceipt)
applyTlsEnvelopeAtSelected workflow reference envelope =
  case TextEncoding.decodeUtf8' (tlsWrappedDekBytes envelope) of
    Left _ -> pure (Left TlsWorkflowWrappedDekInvalid)
    Right wrappedText -> case mkTlsWrappedDek wrappedText of
      Left _ -> pure (Left TlsWorkflowWrappedDekInvalid)
      Right wrapped -> do
        selectedPreparedResult <-
          prepareTlsDekDestination (tlsWorkflowSelectedAgent workflow)
        case first TlsWorkflowSelectedAgentFailed selectedPreparedResult of
          Left err -> pure (Left err)
          Right selectedPrepared -> do
            rewrappedResult <-
              rewrapRetainedHomeTlsDek
                (tlsWorkflowRetainedHomeAgent workflow)
                wrapped
                (tlsDekPreparedPublicKey selectedPrepared)
            case first TlsWorkflowHomeAgentFailed rewrappedResult of
              Left err -> pure (Left err)
              Right rewrapped -> do
                applied <-
                  restoreSelectedPublicEdgeTls
                    (tlsWorkflowSelectedAgent workflow)
                    reference
                    selectedPrepared
                    rewrapped
                    (tlsCertificateCiphertextBytes envelope)
                pure (first TlsWorkflowSelectedAgentFailed applied)

restorePublicEdgeTlsWorkflow
  :: TlsRetentionWorkflow IO
  -> Natural
  -> IO (Either TlsRetentionWorkflowError TlsWorkflowRestoreOutcome)
restorePublicEdgeTlsWorkflow workflow trustedNow = do
  observed <- observeTlsRetentionCurrent (tlsWorkflowAuthority workflow)
  case first TlsWorkflowAuthorityFailed observed of
    Left err -> pure (Left err)
    Right state -> case currentRetainedRef state of
      Nothing -> case pendingTlsRetention state of
        Just _ -> pure (Left TlsWorkflowPendingWithoutCurrent)
        Nothing -> pure (Right TlsWorkflowIssuancePermitted)
      Just reference
        | certNotAfter (retainedCert reference) <= trustedNow ->
            pure (restoreDecisionOutcome (decideTlsRestore state RestoreTrustedTimeExpired))
        | otherwise -> do
            restored <- restoreTlsRetention (tlsWorkflowAdapter workflow) reference
            case first TlsWorkflowAdapterFailed restored of
              Left err -> pure (Left err)
              Right TlsEnvelopeMissing ->
                pure (restoreDecisionOutcome (decideTlsRestore state RestoreCommittedAbsent))
              Right (TlsEnvelopeCorrupt _) ->
                pure (restoreDecisionOutcome (decideTlsRestore state RestoreCommittedCorrupt))
              Right (TlsEnvelopePresent envelope receipt)
                | tlsRetentionReceiptReference receipt /= reference ->
                    pure (Left TlsWorkflowAdapterReadBackMismatch)
                | otherwise ->
                    case decideTlsRestore state (RestoreCommittedIntact reference) of
                      TlsRestoreApply committed -> applyRestored committed envelope
                      decision -> pure (restoreDecisionOutcome decision)
 where
  applyRestored reference envelope = do
    applied <- applyTlsEnvelopeAtSelected workflow reference envelope
    pure (TlsWorkflowRestored reference <$ applied)

validateStaging
  :: TlsRetentionPending
  -> TlsAuthorityStagingOutcome
  -> Either TlsRetentionWorkflowError TlsRetentionPending
validateStaging expected outcome =
  let state = case outcome of
        TlsAuthorityStagingCommitted value -> value
        TlsAuthorityStagingAlreadyPending value -> value
   in case pendingTlsRetention state of
        Just pending
          | pending == expected -> Right pending
        _ -> Left TlsWorkflowStagingStateMismatch

validateLegacyRecoveryStaging
  :: TlsLegacyRecoveryEvidence
  -> TlsRetentionPending
  -> TlsAuthorityStagingOutcome
  -> Either TlsRetentionWorkflowError TlsRetentionPending
validateLegacyRecoveryStaging expectedEvidence expectedPending outcome =
  let state = case outcome of
        TlsAuthorityStagingCommitted value -> value
        TlsAuthorityStagingAlreadyPending value -> value
   in case state of
        TlsRetentionLegacyRecoveryPendingState evidence pending
          | evidence == expectedEvidence && pending == expectedPending -> Right pending
        TlsRetentionLegacyRecoveryCollisionPendingState evidence _ pending
          | evidence == expectedEvidence && pending == expectedPending -> Right pending
        _ -> Left TlsWorkflowStagingStateMismatch

validateLegacyRecoverySuccessorStaging
  :: TlsLegacyRecoveryEvidence
  -> TlsLegacyRecoverySuccessorEvidence
  -> TlsRetentionPending
  -> TlsAuthorityStagingOutcome
  -> Either TlsRetentionWorkflowError TlsRetentionPending
validateLegacyRecoverySuccessorStaging expectedEvidence expectedSuccessor expectedPending outcome =
  let state = case outcome of
        TlsAuthorityStagingCommitted value -> value
        TlsAuthorityStagingAlreadyPending value -> value
   in case state of
        TlsRetentionLegacyRecoverySuccessorPendingState evidence successor pending
          | evidence == expectedEvidence
              && successor == expectedSuccessor
              && pending == expectedPending ->
              Right pending
        _ -> Left TlsWorkflowStagingStateMismatch

validatePromotion
  :: RetainedTlsRef
  -> TlsAuthorityPromotionOutcome
  -> Either TlsRetentionWorkflowError ()
validatePromotion candidate outcome =
  let state = case outcome of
        TlsAuthorityPromotionCommitted value -> value
        TlsAuthorityPromotionAlreadyCurrent value -> value
   in if currentRetainedRef state == Just candidate
        then Right ()
        else Left TlsWorkflowPromotionStateMismatch

restoreDecisionOutcome
  :: TlsRestoreDecision
  -> Either TlsRetentionWorkflowError TlsWorkflowRestoreOutcome
restoreDecisionOutcome decision = case decision of
  TlsRestoreIssue -> Right TlsWorkflowIssuancePermitted
  TlsRestoreApply reference -> Right (TlsWorkflowRestored reference)
  TlsRestoreRefused refusal -> Left (TlsWorkflowRestoreRefused refusal)
