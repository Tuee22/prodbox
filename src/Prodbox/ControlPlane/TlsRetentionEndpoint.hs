{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.50: the server side of the TLS Retention role's @store@ and @restore@
-- routes.
--
-- The pure retention algebra ('Prodbox.Lifecycle.Authority.TlsRetention') already
-- decides a promotion (renewal store) and a restore against the committed
-- reference. This endpoint fronts those decisions: it reads the current retention
-- state through an injected repository, drives the decision, commits a promoted
-- reference through the same repository's compare-and-swap, and projects the
-- outcome onto a total HTTP status and a stable summary — the same shape the
-- Lifecycle Authority migration route uses.
--
-- It is pure over the injected repository, so an in-memory fixture exercises every
-- store/restore arm without a live cluster or object store. The bounded canonical
-- wire codec for the request/response bodies and the real retained-store
-- compare-and-swap are the live-coupled follow-ons this handler isolates.
module Prodbox.ControlPlane.TlsRetentionEndpoint
  ( TlsRetentionRepository (..)
  , TlsRetentionEndpointResult (..)
  , serveTlsStore
  , serveTlsRestore
  , tlsRetentionHttpStatus
  , tlsRetentionSummary
  )
where

import Data.Text (Text)
import Prodbox.Lifecycle.Authority.TlsRetention
  ( KeyRotationApproval
  , PromotionEvidence
  , RestoreObservation
  , RetainedTlsRef
  , TlsPromotionDecision (TlsPromoted, TlsPromotionNoop, TlsPromotionRefused)
  , TlsPromotionRefusal
    ( TlsAdapterReadBackMismatch
    , TlsSourceNotReobserved
    , TlsStaleVersion
    , TlsUnapprovedKeyChange
    , TlsValidityRegression
    )
  , TlsRestoreDecision (TlsRestoreApply, TlsRestoreIssue, TlsRestoreRefused)
  , TlsRestoreRefusal
    ( TlsRestoreCorrupt
    , TlsRestoreReferenceMismatch
    , TlsRestoreUnobservable
    )
  , TlsRetentionState
  , decideTlsPromotion
  , decideTlsRestore
  )

-- | The retained TLS store: read the current retention state and compare-and-swap
-- a promoted reference into it.
data TlsRetentionRepository m = TlsRetentionRepository
  { readRetentionState :: m TlsRetentionState
  , commitRetainedRef :: RetainedTlsRef -> m (Either Text ())
  }

-- | The closed outcome of serving a store or restore request.
data TlsRetentionEndpointResult
  = TlsStoreDecided !TlsPromotionDecision
  | -- | A promotion was decided but its durable commit failed (retry).
    TlsStoreWriteFailed !Text
  | TlsRestoreDecided !TlsRestoreDecision
  deriving (Eq, Show)

-- | Serve a renewal store: decide the promotion against the current retention
-- state and, only for a genuine promotion, commit the new reference.
serveTlsStore
  :: (Monad m)
  => TlsRetentionRepository m
  -> KeyRotationApproval
  -> PromotionEvidence
  -> RetainedTlsRef
  -> m TlsRetentionEndpointResult
serveTlsStore repository approval evidence candidate = do
  state <- readRetentionState repository
  let decision = decideTlsPromotion approval evidence state candidate
  case decision of
    TlsPromoted promoted -> do
      committed <- commitRetainedRef repository promoted
      pure $ case committed of
        Left detail -> TlsStoreWriteFailed detail
        Right () -> TlsStoreDecided decision
    _ -> pure (TlsStoreDecided decision)

-- | Serve a restore: decide against the committed reference. No mutation.
serveTlsRestore
  :: (Monad m)
  => TlsRetentionRepository m
  -> RestoreObservation
  -> m TlsRetentionEndpointResult
serveTlsRestore repository observation = do
  state <- readRetentionState repository
  pure (TlsRestoreDecided (decideTlsRestore state observation))

-- | Total HTTP status projection. A promoted/no-op store and an applied/issue
-- restore are @200@; a refused decision is @409@ (a mismatch to re-resolve); a
-- corrupt committed reference is @500@; an unobservable read or a failed write is
-- @503@.
tlsRetentionHttpStatus :: TlsRetentionEndpointResult -> Int
tlsRetentionHttpStatus result = case result of
  TlsStoreDecided decision -> case decision of
    TlsPromoted _ -> 200
    TlsPromotionNoop _ -> 200
    TlsPromotionRefused _ -> 409
  TlsStoreWriteFailed _ -> 503
  TlsRestoreDecided decision -> case decision of
    TlsRestoreApply _ -> 200
    TlsRestoreIssue -> 200
    TlsRestoreRefused refusal -> case refusal of
      TlsRestoreReferenceMismatch -> 409
      TlsRestoreCorrupt -> 500
      TlsRestoreUnobservable -> 503

-- | Stable single-line diagnostic summary.
tlsRetentionSummary :: TlsRetentionEndpointResult -> Text
tlsRetentionSummary result = case result of
  TlsStoreDecided decision -> case decision of
    TlsPromoted _ -> "tls-promoted"
    TlsPromotionNoop _ -> "tls-promotion-noop"
    TlsPromotionRefused refusal -> "tls-promotion-refused:" <> promotionRefusalToken refusal
  TlsStoreWriteFailed _ -> "tls-store-write-failed"
  TlsRestoreDecided decision -> case decision of
    TlsRestoreApply _ -> "tls-restore-apply"
    TlsRestoreIssue -> "tls-restore-issue"
    TlsRestoreRefused refusal -> "tls-restore-refused:" <> restoreRefusalToken refusal

promotionRefusalToken :: TlsPromotionRefusal -> Text
promotionRefusalToken refusal = case refusal of
  TlsSourceNotReobserved -> "source-not-reobserved"
  TlsAdapterReadBackMismatch -> "adapter-read-back-mismatch"
  TlsStaleVersion -> "stale-version"
  TlsValidityRegression -> "validity-regression"
  TlsUnapprovedKeyChange -> "unapproved-key-change"

restoreRefusalToken :: TlsRestoreRefusal -> Text
restoreRefusalToken refusal = case refusal of
  TlsRestoreCorrupt -> "corrupt"
  TlsRestoreUnobservable -> "unobservable"
  TlsRestoreReferenceMismatch -> "reference-mismatch"
