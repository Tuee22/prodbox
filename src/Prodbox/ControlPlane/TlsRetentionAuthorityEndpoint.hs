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
  , TlsAuthorityUnopenableSuccessorStageRequest (..)
  , TlsAuthorityPromoteRequest (..)
  , TlsAuthorityResponse (..)
  , TlsAuthorityRepositoryResolver
  , serveTlsAuthorityObserveRequest
  , serveTlsAuthorityStageRequest
  , serveTlsAuthorityLegacyRecoveryStageRequest
  , serveTlsAuthorityUnopenableSuccessorStageRequest
  , serveTlsAuthorityPromoteRequest
  , tlsAuthorityResponseHttpStatus
  , tlsAuthorityResponseBody
  , tlsAuthorityResponseMaximumBytes
  )
where

import Codec.Serialise (Serialise (decode, encode))
import Codec.Serialise.Decoding (decodeListLen, decodeWord)
import Codec.Serialise.Encoding (encodeListLen, encodeWord)
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
  , TlsPendingCollisionStagingResult (..)
  , TlsRetentionAuthorityError (..)
  , TlsRetentionAuthorityRepository
  , TlsRetentionPromotionResult (..)
  , TlsRetentionSlot
  , TlsRetentionStagingResult (..)
  , TlsTerminalReplacementStagingResult (..)
  , TlsUnopenableSuccessorStagingResult (..)
  , mkTlsRetentionSlot
  , observeTlsRetentionAuthority
  , promoteTlsRetentionAuthority
  , stageTlsLegacyRecoveryAuthority
  , stageTlsPendingCollisionAuthority
  , stageTlsRetentionAuthority
  , stageTlsTerminalReplacementAuthority
  , stageTlsUnopenableSuccessorAuthority
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
  , TlsPendingCollisionRecovery
  , TlsPendingCollisionStagingDecision (..)
  , TlsPendingCollisionStagingRefusal (..)
  , TlsPromotionDecision (..)
  , TlsPromotionRefusal (..)
  , TlsRetentionState
  , TlsSealedEnvelope
  , TlsStagingDecision (..)
  , TlsStagingRefusal (..)
  , TlsTerminalReplacementEvidence
  , TlsTerminalReplacementEvidenceCause (..)
  , TlsTerminalReplacementStagingDecision (..)
  , TlsTerminalReplacementStagingRefusal (..)
  , TlsUnopenableSuccessorStagingDecision (..)
  , TlsUnopenableSuccessorStagingRefusal (..)
  , TlsUnopenableVersionEvidence
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
  , tlsAuthorityStagePendingCollision :: !(Maybe TlsPendingCollisionRecovery)
  , tlsAuthorityStageTerminalReplacement :: !(Maybe TlsTerminalReplacementEvidence)
  , tlsAuthorityStageCandidate :: !RetainedTlsRef
  , tlsAuthorityStageEnvelope :: !TlsSealedEnvelope
  }
  deriving stock (Eq, Show, Generic)

-- | Preserve the original six-field staging command exactly when no terminal
-- replacement evidence is present.  The generic product codec includes a
-- leading zero constructor tag, hence the legacy arity of seven.  Only the
-- replacement command uses the arity-eight extension, allowing old and new
-- peers to continue exchanging ordinary stage requests during a rollout.
instance Serialise TlsAuthorityStageRequest where
  encode request =
    case tlsAuthorityStageTerminalReplacement request of
      Nothing ->
        encodeListLen 7
          <> encodeWord 0
          <> encode (tlsAuthorityStageSubstrate request)
          <> encode (tlsAuthorityStageScope request)
          <> encode (tlsAuthorityStageApproval request)
          <> encode (tlsAuthorityStagePendingCollision request)
          <> encode (tlsAuthorityStageCandidate request)
          <> encode (tlsAuthorityStageEnvelope request)
      Just evidence ->
        encodeListLen 8
          <> encodeWord 0
          <> encode (tlsAuthorityStageSubstrate request)
          <> encode (tlsAuthorityStageScope request)
          <> encode (tlsAuthorityStageApproval request)
          <> encode (tlsAuthorityStagePendingCollision request)
          <> encode evidence
          <> encode (tlsAuthorityStageCandidate request)
          <> encode (tlsAuthorityStageEnvelope request)
  decode = do
    elements <- decodeListLen
    tag <- decodeWord
    if tag /= 0
      then fail ("unsupported TLS Authority stage request tag: " ++ show tag)
      else pure ()
    substrate <- decode
    scope <- decode
    approval <- decode
    pendingCollision <- decode
    terminalReplacement <- case elements of
      7 -> pure Nothing
      8 -> Just <$> decode
      _ -> fail ("unsupported TLS Authority stage request arity: " ++ show elements)
    TlsAuthorityStageRequest substrate scope approval pendingCollision terminalReplacement
      <$> decode
      <*> decode

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

data TlsAuthorityUnopenableSuccessorStageRequest = TlsAuthorityUnopenableSuccessorStageRequest
  { tlsAuthorityUnopenableSuccessorStageSubstrate :: !Text
  , tlsAuthorityUnopenableSuccessorStageScope :: !Text
  , tlsAuthorityUnopenableSuccessorStageApproval :: !KeyRotationApproval
  , tlsAuthorityUnopenableSuccessorStageEvidence :: !TlsUnopenableVersionEvidence
  , tlsAuthorityUnopenableSuccessorStageCandidate :: !RetainedTlsRef
  , tlsAuthorityUnopenableSuccessorStageEnvelope :: !TlsSealedEnvelope
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
        (stageRequest request)
 where
  stageRequest request repository =
    case ( tlsAuthorityStagePendingCollision request
         , tlsAuthorityStageTerminalReplacement request
         ) of
      (Nothing, Nothing) ->
        stagingResponse
          <$> stageTlsRetentionAuthority
            repository
            (tlsAuthorityStageApproval request)
            (tlsAuthorityStageCandidate request)
            (tlsAuthorityStageEnvelope request)
      (Just recovery, Nothing) ->
        pendingCollisionStagingResponse
          <$> stageTlsPendingCollisionAuthority
            repository
            (tlsAuthorityStageApproval request)
            recovery
            (tlsAuthorityStageCandidate request)
            (tlsAuthorityStageEnvelope request)
      (Just recovery, Just terminalEvidence) ->
        terminalReplacementStagingResponse
          <$> stageTlsTerminalReplacementAuthority
            repository
            (tlsAuthorityStageApproval request)
            recovery
            terminalEvidence
            (tlsAuthorityStageCandidate request)
            (tlsAuthorityStageEnvelope request)
      (Nothing, Just _) -> pure TlsAuthorityRequestRefused

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

serveTlsAuthorityUnopenableSuccessorStageRequest
  :: (Monad m)
  => Int
  -> TlsAuthorityRepositoryResolver m revision
  -> LazyByteString.ByteString
  -> m TlsAuthorityResponse
serveTlsAuthorityUnopenableSuccessorStageRequest maximumBytes resolve body =
  case decodeControlPlaneRequest maximumBytes body of
    Left _ -> pure TlsAuthorityRequestRefused
    Right request ->
      withRepository
        resolve
        (tlsAuthorityUnopenableSuccessorStageSubstrate request)
        (tlsAuthorityUnopenableSuccessorStageScope request)
        ( \repository ->
            unopenableSuccessorStagingResponse
              <$> stageTlsUnopenableSuccessorAuthority
                repository
                (tlsAuthorityUnopenableSuccessorStageApproval request)
                (tlsAuthorityUnopenableSuccessorStageEvidence request)
                (tlsAuthorityUnopenableSuccessorStageCandidate request)
                (tlsAuthorityUnopenableSuccessorStageEnvelope request)
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

pendingCollisionStagingResponse
  :: Either TlsRetentionAuthorityError TlsPendingCollisionStagingResult
  -> TlsAuthorityResponse
pendingCollisionStagingResponse result = case result of
  Left TlsRetentionAuthorityConcurrentWrite -> TlsAuthorityConcurrentWrite
  Left _ -> TlsAuthorityUnavailable
  Right staging -> case tlsPendingCollisionStagingDecision staging of
    TlsPendingCollisionRebased {} ->
      TlsAuthorityStagingApplied (tlsPendingCollisionStagingState staging)
    TlsPendingCollisionSuccessorStaged {} ->
      TlsAuthorityStagingApplied (tlsPendingCollisionStagingState staging)
    TlsPendingCollisionUnopenableSuccessorRebased {} ->
      TlsAuthorityStagingApplied (tlsPendingCollisionStagingState staging)
    TlsPendingCollisionLegacyRecoverySuccessorRebased {} ->
      TlsAuthorityStagingApplied (tlsPendingCollisionStagingState staging)
    TlsPendingCollisionBoundedSuccessorRebased {} ->
      TlsAuthorityStagingApplied (tlsPendingCollisionStagingState staging)
    TlsPendingCollisionLegacyRecoveryTerminalSuccessorStaged {} ->
      TlsAuthorityStagingApplied (tlsPendingCollisionStagingState staging)
    TlsPendingCollisionLegacyRecoveryTerminalSuccessorRebased {} ->
      TlsAuthorityStagingApplied (tlsPendingCollisionStagingState staging)
    TlsPendingCollisionStagingNoop _ ->
      TlsAuthorityStagingNoop (tlsPendingCollisionStagingState staging)
    TlsPendingCollisionStagingRefused refusal ->
      TlsAuthorityStagingRefused (pendingCollisionStagingRefusalToken refusal)

terminalReplacementStagingResponse
  :: Either TlsRetentionAuthorityError TlsTerminalReplacementStagingResult
  -> TlsAuthorityResponse
terminalReplacementStagingResponse result = case result of
  Left TlsRetentionAuthorityConcurrentWrite -> TlsAuthorityConcurrentWrite
  Left _ -> TlsAuthorityUnavailable
  Right staging -> case tlsTerminalReplacementStagingDecision staging of
    TlsTerminalReplacementStaged {} ->
      TlsAuthorityStagingApplied (tlsTerminalReplacementStagingState staging)
    TlsTerminalReplacementStagingNoop _ ->
      TlsAuthorityStagingNoop (tlsTerminalReplacementStagingState staging)
    TlsTerminalReplacementStagingRefused refusal ->
      TlsAuthorityStagingRefused (terminalReplacementStagingRefusalToken refusal)

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

unopenableSuccessorStagingResponse
  :: Either TlsRetentionAuthorityError TlsUnopenableSuccessorStagingResult
  -> TlsAuthorityResponse
unopenableSuccessorStagingResponse result = case result of
  Left TlsRetentionAuthorityConcurrentWrite -> TlsAuthorityConcurrentWrite
  Left _ -> TlsAuthorityUnavailable
  Right staging -> case tlsUnopenableSuccessorStagingDecision staging of
    TlsUnopenableSuccessorStaged _ ->
      TlsAuthorityStagingApplied (tlsUnopenableSuccessorStagingState staging)
    TlsUnopenableSuccessorStagingNoop _ ->
      TlsAuthorityStagingNoop (tlsUnopenableSuccessorStagingState staging)
    TlsUnopenableSuccessorStagingRefused refusal ->
      TlsAuthorityStagingRefused (unopenableSuccessorStagingRefusalToken refusal)

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

pendingCollisionStagingRefusalToken :: TlsPendingCollisionStagingRefusal -> Text
pendingCollisionStagingRefusalToken refusal = case refusal of
  TlsPendingCollisionStageStateNotPending -> "pending-collision-state-not-pending"
  TlsPendingCollisionStageConcurrentPending -> "pending-collision-concurrent-pending"
  TlsPendingCollisionStageEvidenceInvalid -> "pending-collision-evidence-invalid"
  TlsPendingCollisionStageEnvelopeInvalid -> "pending-collision-envelope-invalid"
  TlsPendingCollisionStageReferenceInvalid -> "pending-collision-reference-invalid"
  TlsPendingCollisionStageDigestMismatch -> "pending-collision-digest-mismatch"

terminalReplacementStagingRefusalToken
  :: TlsTerminalReplacementStagingRefusal -> Text
terminalReplacementStagingRefusalToken refusal = case refusal of
  TlsTerminalReplacementStageStateNotSuccessor ->
    "terminal-replacement-state-not-successor"
  TlsTerminalReplacementStageConcurrentPending ->
    "terminal-replacement-concurrent-pending"
  TlsTerminalReplacementStageEvidenceInvalid cause ->
    "terminal-replacement-evidence-invalid/" <> terminalReplacementEvidenceCauseToken cause
  TlsTerminalReplacementStageEnvelopeInvalid ->
    "terminal-replacement-envelope-invalid"
  TlsTerminalReplacementStageReferenceInvalid ->
    "terminal-replacement-reference-invalid"
  TlsTerminalReplacementStageDigestMismatch ->
    "terminal-replacement-digest-mismatch"

terminalReplacementEvidenceCauseToken :: TlsTerminalReplacementEvidenceCause -> Text
terminalReplacementEvidenceCauseToken cause = case cause of
  TlsTerminalReplacementEvidenceMalformed -> "malformed"
  TlsTerminalReplacementVersionLineageInvalid -> "version-lineage"
  TlsTerminalReplacementDigestLineageInvalid -> "digest-lineage"
  TlsTerminalReplacementApprovalLineageInvalid -> "approval-lineage"
  TlsTerminalReplacementCertificateLineageInvalid -> "certificate-lineage"
  TlsTerminalReplacementSourceUidLineageInvalid -> "source-uid-lineage"
  TlsTerminalReplacementSourceResourceVersionLineageInvalid ->
    "source-resource-version-lineage"
  TlsTerminalReplacementRecoveryDispositionInvalid -> "recovery-disposition"

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

unopenableSuccessorStagingRefusalToken
  :: TlsUnopenableSuccessorStagingRefusal -> Text
unopenableSuccessorStagingRefusalToken refusal = case refusal of
  TlsUnopenableSuccessorStageEvidenceInvalid ->
    "unopenable-successor-evidence-invalid"
  TlsUnopenableSuccessorStageSkippedVersionMismatch ->
    "unopenable-successor-skipped-version-mismatch"
  TlsUnopenableSuccessorStageSkippedDigestReused ->
    "unopenable-successor-skipped-digest-reused"
  TlsUnopenableSuccessorStageEnvelopeInvalid ->
    "unopenable-successor-envelope-invalid"
  TlsUnopenableSuccessorStageReferenceInvalid ->
    "unopenable-successor-reference-invalid"
  TlsUnopenableSuccessorStageDigestMismatch ->
    "unopenable-successor-digest-mismatch"
  TlsUnopenableSuccessorStageVersionMismatch ->
    "unopenable-successor-version-mismatch"
  TlsUnopenableSuccessorStageStateNotCurrent ->
    "unopenable-successor-state-not-current"
  TlsUnopenableSuccessorStageConcurrentPending ->
    "unopenable-successor-concurrent-pending"
  TlsUnopenableSuccessorStageValidityRegression ->
    "unopenable-successor-validity-regression"
  TlsUnopenableSuccessorStageUnapprovedKeyChange ->
    "unopenable-successor-unapproved-key-change"

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
