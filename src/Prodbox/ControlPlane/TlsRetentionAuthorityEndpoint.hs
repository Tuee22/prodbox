{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated Lifecycle Authority endpoint for the public-edge TLS
-- pending/current state. Requests name only a compiled substrate and canonical
-- certificate scope; object-store coordinates and CAS revisions stay behind
-- the repository resolver.
module Prodbox.ControlPlane.TlsRetentionAuthorityEndpoint
  ( TlsAuthorityObserveRequest (..)
  , TlsAuthorityStageRequest (..)
  , TlsAuthorityLegacyRecoveryStageRequest (..)
  , TlsAuthorityPromoteRequest (..)
  , TlsAuthorityResponse (..)
  , TlsAuthorityRepositoryResolver
  , serveTlsAuthorityObserveRequest
  , serveTlsAuthorityStageRequest
  , serveTlsAuthorityLegacyRecoveryStageRequest
  , serveTlsAuthorityPromoteRequest
  , tlsAuthorityResponseHttpStatus
  , tlsAuthorityResponseBody
  , tlsAuthorityResponseMaximumBytes
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.TlsRetentionAuthority
  ( TlsLegacyRecoveryStagingResult (..)
  , TlsRetentionAuthorityError (..)
  , TlsRetentionAuthorityRepository
  , TlsRetentionPromotionResult (..)
  , TlsRetentionSlot
  , TlsRetentionStagingResult (..)
  , mkTlsRetentionSlot
  , observeTlsRetentionAuthority
  , promoteTlsRetentionAuthority
  , stageTlsLegacyRecoveryAuthority
  , stageTlsRetentionAuthority
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.TlsRetention
  ( KeyRotationApproval
  , PromotionEvidence
  , RetainedTlsRef
  , TlsLegacyRecoveryCollisionEvidence
  , TlsLegacyRecoveryEvidence
  , TlsLegacyRecoveryStagingDecision (..)
  , TlsLegacyRecoveryStagingRefusal (..)
  , TlsPromotionDecision (..)
  , TlsPromotionRefusal (..)
  , TlsRetentionState
  , TlsSealedEnvelope
  , TlsStagingDecision (..)
  , TlsStagingRefusal (..)
  )

data TlsAuthorityObserveRequest = TlsAuthorityObserveRequest
  { tlsAuthorityObserveSubstrate :: !Text
  , tlsAuthorityObserveScope :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsAuthorityPromoteRequest = TlsAuthorityPromoteRequest
  { tlsAuthorityPromoteSubstrate :: !Text
  , tlsAuthorityPromoteScope :: !Text
  , tlsAuthorityPromoteApproval :: !KeyRotationApproval
  , tlsAuthorityPromoteEvidence :: !PromotionEvidence
  , tlsAuthorityPromoteCandidate :: !RetainedTlsRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsAuthorityStageRequest = TlsAuthorityStageRequest
  { tlsAuthorityStageSubstrate :: !Text
  , tlsAuthorityStageScope :: !Text
  , tlsAuthorityStageApproval :: !KeyRotationApproval
  , tlsAuthorityStageCandidate :: !RetainedTlsRef
  , tlsAuthorityStageEnvelope :: !TlsSealedEnvelope
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsAuthorityLegacyRecoveryStageRequest = TlsAuthorityLegacyRecoveryStageRequest
  { tlsAuthorityLegacyRecoveryStageSubstrate :: !Text
  , tlsAuthorityLegacyRecoveryStageScope :: !Text
  , tlsAuthorityLegacyRecoveryStageApproval :: !KeyRotationApproval
  , tlsAuthorityLegacyRecoveryStageEvidence :: !TlsLegacyRecoveryEvidence
  , tlsAuthorityLegacyRecoveryStageCollision :: !(Maybe TlsLegacyRecoveryCollisionEvidence)
  , tlsAuthorityLegacyRecoveryStageCandidate :: !RetainedTlsRef
  , tlsAuthorityLegacyRecoveryStageEnvelope :: !TlsSealedEnvelope
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsAuthorityResponse
  = TlsAuthorityObserved !TlsRetentionState
  | TlsAuthorityPromotionApplied !TlsRetentionState
  | TlsAuthorityPromotionNoop !TlsRetentionState
  | TlsAuthorityPromotionRefused !Text
  | TlsAuthorityConcurrentWrite
  | TlsAuthorityUnavailable
  | TlsAuthorityRequestRefused
  | TlsAuthorityStagingApplied !TlsRetentionState
  | TlsAuthorityStagingNoop !TlsRetentionState
  | TlsAuthorityStagingRefused !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

type TlsAuthorityRepositoryResolver m revision =
  TlsRetentionSlot -> Either Text (TlsRetentionAuthorityRepository m revision)

tlsAuthorityResponseMaximumBytes :: Int
tlsAuthorityResponseMaximumBytes = 1024 * 1024

serveTlsAuthorityObserveRequest
  :: (Monad m)
  => Int
  -> TlsAuthorityRepositoryResolver m revision
  -> LazyByteString.ByteString
  -> m TlsAuthorityResponse
serveTlsAuthorityObserveRequest maximumBytes resolve body =
  case decodeControlPlaneRequest maximumBytes body of
    Left _ -> pure TlsAuthorityRequestRefused
    Right request ->
      withRepository
        resolve
        (tlsAuthorityObserveSubstrate request)
        (tlsAuthorityObserveScope request)
        (fmap observeResponse . observeTlsRetentionAuthority)

serveTlsAuthorityStageRequest
  :: (Monad m)
  => Int
  -> TlsAuthorityRepositoryResolver m revision
  -> LazyByteString.ByteString
  -> m TlsAuthorityResponse
serveTlsAuthorityStageRequest maximumBytes resolve body =
  case decodeControlPlaneRequest maximumBytes body of
    Left _ -> pure TlsAuthorityRequestRefused
    Right request ->
      withRepository
        resolve
        (tlsAuthorityStageSubstrate request)
        (tlsAuthorityStageScope request)
        ( \repository ->
            stagingResponse
              <$> stageTlsRetentionAuthority
                repository
                (tlsAuthorityStageApproval request)
                (tlsAuthorityStageCandidate request)
                (tlsAuthorityStageEnvelope request)
        )

serveTlsAuthorityLegacyRecoveryStageRequest
  :: (Monad m)
  => Int
  -> TlsAuthorityRepositoryResolver m revision
  -> LazyByteString.ByteString
  -> m TlsAuthorityResponse
serveTlsAuthorityLegacyRecoveryStageRequest maximumBytes resolve body =
  case decodeControlPlaneRequest maximumBytes body of
    Left _ -> pure TlsAuthorityRequestRefused
    Right request ->
      withRepository
        resolve
        (tlsAuthorityLegacyRecoveryStageSubstrate request)
        (tlsAuthorityLegacyRecoveryStageScope request)
        ( \repository ->
            legacyRecoveryStagingResponse
              <$> stageTlsLegacyRecoveryAuthority
                repository
                (tlsAuthorityLegacyRecoveryStageApproval request)
                (tlsAuthorityLegacyRecoveryStageEvidence request)
                (tlsAuthorityLegacyRecoveryStageCollision request)
                (tlsAuthorityLegacyRecoveryStageCandidate request)
                (tlsAuthorityLegacyRecoveryStageEnvelope request)
        )

serveTlsAuthorityPromoteRequest
  :: (Monad m)
  => Int
  -> TlsAuthorityRepositoryResolver m revision
  -> LazyByteString.ByteString
  -> m TlsAuthorityResponse
serveTlsAuthorityPromoteRequest maximumBytes resolve body =
  case decodeControlPlaneRequest maximumBytes body of
    Left _ -> pure TlsAuthorityRequestRefused
    Right request ->
      withRepository
        resolve
        (tlsAuthorityPromoteSubstrate request)
        (tlsAuthorityPromoteScope request)
        ( \repository ->
            promotionResponse
              <$> promoteTlsRetentionAuthority
                repository
                (tlsAuthorityPromoteApproval request)
                (tlsAuthorityPromoteEvidence request)
                (tlsAuthorityPromoteCandidate request)
        )

withRepository
  :: (Monad m)
  => TlsAuthorityRepositoryResolver m revision
  -> Text
  -> Text
  -> (TlsRetentionAuthorityRepository m revision -> m TlsAuthorityResponse)
  -> m TlsAuthorityResponse
withRepository resolve substrate scope action =
  case mkTlsRetentionSlot substrate scope of
    Left _ -> pure TlsAuthorityRequestRefused
    Right slot -> case resolve slot of
      Left _ -> pure TlsAuthorityUnavailable
      Right repository -> action repository

observeResponse
  :: Either TlsRetentionAuthorityError TlsRetentionState
  -> TlsAuthorityResponse
observeResponse result = case result of
  Left _ -> TlsAuthorityUnavailable
  Right state -> TlsAuthorityObserved state

stagingResponse
  :: Either TlsRetentionAuthorityError TlsRetentionStagingResult
  -> TlsAuthorityResponse
stagingResponse result = case result of
  Left TlsRetentionAuthorityConcurrentWrite -> TlsAuthorityConcurrentWrite
  Left _ -> TlsAuthorityUnavailable
  Right staging -> case tlsRetentionStagingDecision staging of
    TlsStaged _ ->
      TlsAuthorityStagingApplied (tlsRetentionStagingState staging)
    TlsStagingNoop _ ->
      TlsAuthorityStagingNoop (tlsRetentionStagingState staging)
    TlsStagingRefused refusal ->
      TlsAuthorityStagingRefused (stagingRefusalToken refusal)

legacyRecoveryStagingResponse
  :: Either TlsRetentionAuthorityError TlsLegacyRecoveryStagingResult
  -> TlsAuthorityResponse
legacyRecoveryStagingResponse result = case result of
  Left TlsRetentionAuthorityConcurrentWrite -> TlsAuthorityConcurrentWrite
  Left _ -> TlsAuthorityUnavailable
  Right staging -> case tlsLegacyRecoveryStagingDecision staging of
    TlsLegacyRecoveryStaged _ ->
      TlsAuthorityStagingApplied (tlsLegacyRecoveryStagingState staging)
    TlsLegacyRecoveryCollisionRebased _ _ ->
      TlsAuthorityStagingApplied (tlsLegacyRecoveryStagingState staging)
    TlsLegacyRecoveryCollisionSuccessorStaged _ _ ->
      TlsAuthorityStagingApplied (tlsLegacyRecoveryStagingState staging)
    TlsLegacyRecoveryStagingNoop _ ->
      TlsAuthorityStagingNoop (tlsLegacyRecoveryStagingState staging)
    TlsLegacyRecoveryStagingRefused refusal ->
      TlsAuthorityStagingRefused (legacyRecoveryStagingRefusalToken refusal)

promotionResponse
  :: Either TlsRetentionAuthorityError TlsRetentionPromotionResult
  -> TlsAuthorityResponse
promotionResponse result = case result of
  Left TlsRetentionAuthorityConcurrentWrite -> TlsAuthorityConcurrentWrite
  Left _ -> TlsAuthorityUnavailable
  Right promotion -> case tlsRetentionPromotionDecision promotion of
    TlsPromoted _ ->
      TlsAuthorityPromotionApplied (tlsRetentionPromotionState promotion)
    TlsPromotionNoop _ ->
      TlsAuthorityPromotionNoop (tlsRetentionPromotionState promotion)
    TlsPromotionRefused refusal ->
      TlsAuthorityPromotionRefused (refusalToken refusal)

refusalToken :: TlsPromotionRefusal -> Text
refusalToken refusal = case refusal of
  TlsSourceNotReobserved -> "source-not-reobserved"
  TlsAdapterReadBackMismatch -> "adapter-readback-mismatch"
  TlsStaleVersion -> "stale-version"
  TlsValidityRegression -> "validity-regression"
  TlsUnapprovedKeyChange -> "unapproved-key-change"
  TlsPendingMissing -> "pending-missing"
  TlsPendingMismatch -> "pending-mismatch"

stagingRefusalToken :: TlsStagingRefusal -> Text
stagingRefusalToken refusal = case refusal of
  TlsStageEnvelopeInvalid -> "envelope-invalid"
  TlsStageReferenceInvalid -> "reference-invalid"
  TlsStageDigestMismatch -> "digest-mismatch"
  TlsStageVersionMismatch -> "version-mismatch"
  TlsStageValidityRegression -> "validity-regression"
  TlsStageUnapprovedKeyChange -> "unapproved-key-change"
  TlsStageConcurrentPending -> "concurrent-pending"

legacyRecoveryStagingRefusalToken :: TlsLegacyRecoveryStagingRefusal -> Text
legacyRecoveryStagingRefusalToken refusal = case refusal of
  TlsLegacyRecoveryStageStateNotEmpty -> "legacy-recovery-state-not-empty"
  TlsLegacyRecoveryStageConcurrentPending -> "legacy-recovery-concurrent-pending"
  TlsLegacyRecoveryStageEvidenceInvalid -> "legacy-recovery-evidence-invalid"
  TlsLegacyRecoveryStageEnvelopeInvalid -> "legacy-recovery-envelope-invalid"
  TlsLegacyRecoveryStageReferenceInvalid -> "legacy-recovery-reference-invalid"
  TlsLegacyRecoveryStageDigestMismatch -> "legacy-recovery-digest-mismatch"
  TlsLegacyRecoveryStageVersionMismatch -> "legacy-recovery-version-mismatch"
  TlsLegacyRecoveryStageCollisionEvidenceInvalid ->
    "legacy-recovery-collision-evidence-invalid"

tlsAuthorityResponseHttpStatus :: TlsAuthorityResponse -> ReplyStatus
tlsAuthorityResponseHttpStatus response = case response of
  TlsAuthorityObserved _ -> ReplyOk
  TlsAuthorityStagingApplied _ -> ReplyOk
  TlsAuthorityStagingNoop _ -> ReplyOk
  TlsAuthorityStagingRefused _ -> ReplyConflict
  TlsAuthorityPromotionApplied _ -> ReplyOk
  TlsAuthorityPromotionNoop _ -> ReplyOk
  TlsAuthorityPromotionRefused _ -> ReplyConflict
  TlsAuthorityConcurrentWrite -> ReplyConflict
  TlsAuthorityUnavailable -> ReplyServiceUnavailable
  TlsAuthorityRequestRefused -> ReplyBadRequest

tlsAuthorityResponseBody :: TlsAuthorityResponse -> ByteString
tlsAuthorityResponseBody = LazyByteString.toStrict . encodeControlPlaneResponse
