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
  , TlsRetentionAuthorityClient (..)
  , TlsRetentionAuthorityClientError
  )
import Prodbox.ControlPlane.TlsRetentionClient
  ( TlsRetentionClient (..)
  , TlsRetentionClientError
  )
import Prodbox.ControlPlane.TlsRetentionEndpoint
  ( TlsEnvelopeObservation (..)
  , TlsRetentionReceipt (..)
  , mkTlsSealedEnvelope
  , tlsCertificateCiphertextBytes
  , tlsSealedEnvelopeDigest
  , tlsWrappedDekBytes
  )
import Prodbox.ControlPlane.TlsTargetAgentClient
  ( TlsTargetAgentClient (..)
  , TlsTargetAgentClientError (..)
  )
import Prodbox.ControlPlane.TlsTargetAgentEndpoint
  ( TlsTargetRetainReceipt (..)
  )
import Prodbox.Lifecycle.Authority.TlsRetention
  ( CertIdentity (..)
  , KeyRotationApproval
  , PromotionEvidence (..)
  , RestoreObservation (..)
  , RetainedTlsRef (..)
  , RetentionVersion (..)
  , TlsRestoreDecision (..)
  , TlsRestoreRefusal
  , TlsRetentionState
  , currentRetainedRef
  , decideTlsRestore
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
  | TlsWorkflowPromotionStateMismatch
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
    Right state -> do
      homePreparedResult <-
        prepareTlsDekDestination (tlsWorkflowRetainedHomeAgent workflow)
      case first TlsWorkflowHomeAgentFailed homePreparedResult of
        Left err -> pure (Left err)
        Right homePrepared -> do
          let version = nextRetentionVersion state
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
                    Right envelope -> do
                      let candidate =
                            RetainedTlsRef
                              { retainedVersion = version
                              , retainedCert = tlsTargetRetainedCertificate retained
                              , retainedCiphertextDigest = tlsSealedEnvelopeDigest envelope
                              , retainedSourceSecret = tlsTargetRetainedSource retained
                              }
                      stored <-
                        storeTlsRetention
                          (tlsWorkflowAdapter workflow)
                          candidate
                          envelope
                      case first TlsWorkflowAdapterFailed stored of
                        Left err -> pure (Left err)
                        Right _ -> confirmAndPromote candidate envelope
 where
  confirmAndPromote candidate envelope = do
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
                    approval
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

restorePublicEdgeTlsWorkflow
  :: TlsRetentionWorkflow IO
  -> Natural
  -> IO (Either TlsRetentionWorkflowError TlsWorkflowRestoreOutcome)
restorePublicEdgeTlsWorkflow workflow trustedNow = do
  observed <- observeTlsRetentionCurrent (tlsWorkflowAuthority workflow)
  case first TlsWorkflowAuthorityFailed observed of
    Left err -> pure (Left err)
    Right state -> case currentRetainedRef state of
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
  applyRestored reference envelope =
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
                  pure $ do
                    _ <- first TlsWorkflowSelectedAgentFailed applied
                    Right (TlsWorkflowRestored reference)

nextRetentionVersion :: TlsRetentionState -> RetentionVersion
nextRetentionVersion state = case currentRetainedRef state of
  Nothing -> RetentionVersion 1
  Just current -> case retainedVersion current of
    RetentionVersion version -> RetentionVersion (version + 1)

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
