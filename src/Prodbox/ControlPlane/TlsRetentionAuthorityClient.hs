{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Caller-bound client for the Lifecycle Authority's one TLS-retention slot.
-- The constructor fixes substrate and canonical scope before a request can be
-- made; the resulting value has no generic Authority-object operation.
module Prodbox.ControlPlane.TlsRetentionAuthorityClient
  ( TlsRetentionAuthorityClient (..)
  , TlsRetentionAuthorityClientError (..)
  , renderTlsRetentionAuthorityClientCause
  , TlsAuthorityStagingOutcome (..)
  , TlsAuthorityPromotionOutcome (..)
  , mkTlsRetentionAuthorityClient
  )
where

import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError (..)
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneClientError (..)
  , ControlPlaneResponse (..)
  , ControlPlaneRouteFor
    ( LifecycleTlsRetentionLegacyRecoveryStageRoute
    , LifecycleTlsRetentionObserveRoute
    , LifecycleTlsRetentionPromoteRoute
    , LifecycleTlsRetentionStageRoute
    , LifecycleTlsRetentionUnopenableSuccessorStageRoute
    )
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , controlPlaneResponseCodecToken
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.TlsRetentionAuthority
  ( TlsRetentionSlotError (..)
  , mkTlsRetentionSlot
  )
import Prodbox.ControlPlane.TlsRetentionAuthorityEndpoint
  ( TlsAuthorityLegacyRecoveryStageRequest (..)
  , TlsAuthorityObserveRequest (..)
  , TlsAuthorityPromoteRequest (..)
  , TlsAuthorityResponse (..)
  , TlsAuthorityStageRequest (..)
  , TlsAuthorityUnopenableSuccessorStageRequest (..)
  , tlsAuthorityResponseHttpStatus
  , tlsAuthorityResponseMaximumBytes
  )
import Prodbox.Http.Client (HttpError (..))
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.Authority.TlsRetention
  ( KeyRotationApproval
  , PromotionEvidence
  , RetainedTlsRef
  , TlsLegacyRecoveryCollisionEvidence
  , TlsLegacyRecoveryEvidence
  , TlsPendingCollisionRecovery
  , TlsRetentionState
  , TlsSealedEnvelope
  , TlsTerminalReplacementEvidence
  , TlsUnopenableVersionEvidence
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data TlsRetentionAuthorityClient m = TlsRetentionAuthorityClient
  { observeTlsRetentionCurrent
      :: m (Either TlsRetentionAuthorityClientError TlsRetentionState)
  , stageTlsRetentionCurrent
      :: KeyRotationApproval
      -> RetainedTlsRef
      -> TlsSealedEnvelope
      -> m
           ( Either
               TlsRetentionAuthorityClientError
               TlsAuthorityStagingOutcome
           )
  , stageTlsRetentionAfterUnrecoverableLegacy
      :: KeyRotationApproval
      -> TlsLegacyRecoveryEvidence
      -> Maybe TlsLegacyRecoveryCollisionEvidence
      -> RetainedTlsRef
      -> TlsSealedEnvelope
      -> m
           ( Either
               TlsRetentionAuthorityClientError
               TlsAuthorityStagingOutcome
           )
  , stageTlsRetentionAfterPendingCollision
      :: KeyRotationApproval
      -> TlsPendingCollisionRecovery
      -> RetainedTlsRef
      -> TlsSealedEnvelope
      -> m
           ( Either
               TlsRetentionAuthorityClientError
               TlsAuthorityStagingOutcome
           )
  , stageTlsRetentionTerminalReplacement
      :: KeyRotationApproval
      -> TlsPendingCollisionRecovery
      -> TlsTerminalReplacementEvidence
      -> RetainedTlsRef
      -> TlsSealedEnvelope
      -> m
           ( Either
               TlsRetentionAuthorityClientError
               TlsAuthorityStagingOutcome
           )
  , stageTlsRetentionAfterUnopenableVersion
      :: KeyRotationApproval
      -> TlsUnopenableVersionEvidence
      -> RetainedTlsRef
      -> TlsSealedEnvelope
      -> m
           ( Either
               TlsRetentionAuthorityClientError
               TlsAuthorityStagingOutcome
           )
  , promoteTlsRetentionCurrent
      :: KeyRotationApproval
      -> PromotionEvidence
      -> RetainedTlsRef
      -> m
           ( Either
               TlsRetentionAuthorityClientError
               TlsAuthorityPromotionOutcome
           )
  }

data TlsAuthorityStagingOutcome
  = TlsAuthorityStagingCommitted !TlsRetentionState
  | TlsAuthorityStagingAlreadyPending !TlsRetentionState
  deriving stock (Eq, Show)

data TlsAuthorityPromotionOutcome
  = TlsAuthorityPromotionCommitted !TlsRetentionState
  | TlsAuthorityPromotionAlreadyCurrent !TlsRetentionState
  deriving stock (Eq, Show)

data TlsRetentionAuthorityClientError
  = TlsRetentionAuthorityClientSlotInvalid !TlsRetentionSlotError
  | TlsRetentionAuthorityClientTransportFailed !AuthenticatedClientError
  | TlsRetentionAuthorityClientResponseInvalid !ControlPlaneResponseCodecError
  | TlsRetentionAuthorityClientHttpStatus !Int
  | TlsRetentionAuthorityClientRemoteRefused !Text
  | TlsRetentionAuthorityClientUnavailable
  | TlsRetentionAuthorityClientConcurrentWrite
  | TlsRetentionAuthorityClientResponseShapeMismatch
  deriving stock (Eq, Show)

-- | Closed, value-free diagnosis for the self-client used by the TLS
-- retention workflow. Payload-bearing provider, codec, HTTP, and remote
-- refusal detail is erased before this token reaches the protected log.
renderTlsRetentionAuthorityClientCause
  :: TlsRetentionAuthorityClientError -> Text
renderTlsRetentionAuthorityClientCause clientError = case clientError of
  TlsRetentionAuthorityClientSlotInvalid slotError ->
    "slot/" <> renderSlotError slotError
  TlsRetentionAuthorityClientTransportFailed authenticatedError ->
    "authenticated/" <> renderAuthenticatedError authenticatedError
  TlsRetentionAuthorityClientResponseInvalid codecError ->
    "response-codec/" <> controlPlaneResponseCodecToken codecError
  TlsRetentionAuthorityClientHttpStatus status ->
    "response-status/" <> renderHttpStatusClass status
  TlsRetentionAuthorityClientRemoteRefused detail ->
    renderRemoteRefusal detail
  TlsRetentionAuthorityClientUnavailable -> "remote-unavailable"
  TlsRetentionAuthorityClientConcurrentWrite -> "remote-concurrent-write"
  TlsRetentionAuthorityClientResponseShapeMismatch -> "response-shape-mismatch"

-- The endpoint authors this finite vocabulary. Keep every returned value
-- literal: an untrusted peer cannot turn its response payload into protected
-- log text merely by resembling one of these tokens.
renderRemoteRefusal :: Text -> Text
renderRemoteRefusal detail = case detail of
  "request-refused" -> "remote-refusal/request-refused"
  "source-not-reobserved" -> "remote-refusal/source-not-reobserved"
  "adapter-readback-mismatch" -> "remote-refusal/adapter-readback-mismatch"
  "stale-version" -> "remote-refusal/stale-version"
  "validity-regression" -> "remote-refusal/validity-regression"
  "unapproved-key-change" -> "remote-refusal/unapproved-key-change"
  "pending-missing" -> "remote-refusal/pending-missing"
  "pending-mismatch" -> "remote-refusal/pending-mismatch"
  "envelope-invalid" -> "remote-refusal/envelope-invalid"
  "reference-invalid" -> "remote-refusal/reference-invalid"
  "digest-mismatch" -> "remote-refusal/digest-mismatch"
  "version-mismatch" -> "remote-refusal/version-mismatch"
  "concurrent-pending" -> "remote-refusal/concurrent-pending"
  "pending-collision-state-not-pending" ->
    "remote-refusal/pending-collision-state-not-pending"
  "pending-collision-concurrent-pending" ->
    "remote-refusal/pending-collision-concurrent-pending"
  "pending-collision-evidence-invalid" ->
    "remote-refusal/pending-collision-evidence-invalid"
  "pending-collision-envelope-invalid" ->
    "remote-refusal/pending-collision-envelope-invalid"
  "pending-collision-reference-invalid" ->
    "remote-refusal/pending-collision-reference-invalid"
  "pending-collision-digest-mismatch" ->
    "remote-refusal/pending-collision-digest-mismatch"
  "terminal-replacement-state-not-successor" ->
    "remote-refusal/terminal-replacement-state-not-successor"
  "terminal-replacement-concurrent-pending" ->
    "remote-refusal/terminal-replacement-concurrent-pending"
  "terminal-replacement-evidence-invalid" ->
    "remote-refusal/terminal-replacement-evidence-invalid"
  "terminal-replacement-evidence-invalid/malformed" ->
    "remote-refusal/terminal-replacement-evidence-invalid/malformed"
  "terminal-replacement-evidence-invalid/version-lineage" ->
    "remote-refusal/terminal-replacement-evidence-invalid/version-lineage"
  "terminal-replacement-evidence-invalid/digest-lineage" ->
    "remote-refusal/terminal-replacement-evidence-invalid/digest-lineage"
  "terminal-replacement-evidence-invalid/approval-lineage" ->
    "remote-refusal/terminal-replacement-evidence-invalid/approval-lineage"
  "terminal-replacement-evidence-invalid/certificate-lineage" ->
    "remote-refusal/terminal-replacement-evidence-invalid/certificate-lineage"
  "terminal-replacement-evidence-invalid/source-lineage" ->
    "remote-refusal/terminal-replacement-evidence-invalid/source-lineage"
  "terminal-replacement-evidence-invalid/source-uid-lineage" ->
    "remote-refusal/terminal-replacement-evidence-invalid/source-uid-lineage"
  "terminal-replacement-evidence-invalid/source-resource-version-lineage" ->
    "remote-refusal/terminal-replacement-evidence-invalid/source-resource-version-lineage"
  "terminal-replacement-evidence-invalid/recovery-disposition" ->
    "remote-refusal/terminal-replacement-evidence-invalid/recovery-disposition"
  "terminal-replacement-envelope-invalid" ->
    "remote-refusal/terminal-replacement-envelope-invalid"
  "terminal-replacement-reference-invalid" ->
    "remote-refusal/terminal-replacement-reference-invalid"
  "terminal-replacement-digest-mismatch" ->
    "remote-refusal/terminal-replacement-digest-mismatch"
  "legacy-recovery-state-not-empty" ->
    "remote-refusal/legacy-recovery-state-not-empty"
  "legacy-recovery-concurrent-pending" ->
    "remote-refusal/legacy-recovery-concurrent-pending"
  "legacy-recovery-evidence-invalid" ->
    "remote-refusal/legacy-recovery-evidence-invalid"
  "legacy-recovery-envelope-invalid" ->
    "remote-refusal/legacy-recovery-envelope-invalid"
  "legacy-recovery-reference-invalid" ->
    "remote-refusal/legacy-recovery-reference-invalid"
  "legacy-recovery-digest-mismatch" ->
    "remote-refusal/legacy-recovery-digest-mismatch"
  "legacy-recovery-version-mismatch" ->
    "remote-refusal/legacy-recovery-version-mismatch"
  "legacy-recovery-collision-evidence-invalid" ->
    "remote-refusal/legacy-recovery-collision-evidence-invalid"
  "unopenable-successor-evidence-invalid" ->
    "remote-refusal/unopenable-successor-evidence-invalid"
  "unopenable-successor-skipped-version-mismatch" ->
    "remote-refusal/unopenable-successor-skipped-version-mismatch"
  "unopenable-successor-skipped-digest-reused" ->
    "remote-refusal/unopenable-successor-skipped-digest-reused"
  "unopenable-successor-envelope-invalid" ->
    "remote-refusal/unopenable-successor-envelope-invalid"
  "unopenable-successor-reference-invalid" ->
    "remote-refusal/unopenable-successor-reference-invalid"
  "unopenable-successor-digest-mismatch" ->
    "remote-refusal/unopenable-successor-digest-mismatch"
  "unopenable-successor-version-mismatch" ->
    "remote-refusal/unopenable-successor-version-mismatch"
  "unopenable-successor-state-not-current" ->
    "remote-refusal/unopenable-successor-state-not-current"
  "unopenable-successor-concurrent-pending" ->
    "remote-refusal/unopenable-successor-concurrent-pending"
  "unopenable-successor-validity-regression" ->
    "remote-refusal/unopenable-successor-validity-regression"
  "unopenable-successor-unapproved-key-change" ->
    "remote-refusal/unopenable-successor-unapproved-key-change"
  _ -> "remote-refusal/other"

renderSlotError :: TlsRetentionSlotError -> Text
renderSlotError slotError = case slotError of
  TlsRetentionSlotSubstrateInvalid -> "substrate-invalid"
  TlsRetentionSlotScopeEmpty -> "scope-empty"
  TlsRetentionSlotScopeContainsControl -> "scope-control"
  TlsRetentionSlotScopeContainsWhitespace -> "scope-whitespace"
  TlsRetentionSlotScopeTooLong _ _ -> "scope-too-long"

renderAuthenticatedError :: AuthenticatedClientError -> Text
renderAuthenticatedError authenticatedError = case authenticatedError of
  AuthenticatedClientSignerUnavailable _ -> "signer-unavailable"
  AuthenticatedClientScopeUnavailable _ -> "scope-unavailable"
  AuthenticatedClientEpochUnavailable _ -> "epoch-unavailable"
  AuthenticatedClientDeadlineUnavailable _ -> "deadline-unavailable"
  AuthenticatedClientNonceUnavailable _ -> "nonce-unavailable"
  AuthenticatedClientBindingFailed _ -> "binding-failed"
  AuthenticatedClientSigningFailed _ -> "signing-failed"
  AuthenticatedClientFrameFailed _ -> "frame-failed"
  AuthenticatedClientTransportFailed transportError ->
    "transport/" <> renderTransportError transportError

renderTransportError :: ControlPlaneClientError -> Text
renderTransportError transportError = case transportError of
  ControlPlaneEndpointEmpty -> "endpoint-empty"
  ControlPlaneEndpointContainsWhitespace -> "endpoint-whitespace"
  ControlPlaneEndpointContainsControl -> "endpoint-control"
  ControlPlaneEndpointTooLong _ _ -> "endpoint-too-long"
  ControlPlaneEndpointSchemeUnsupported -> "endpoint-scheme-unsupported"
  ControlPlaneEndpointAuthorityInvalid -> "endpoint-authority-invalid"
  ControlPlaneResponseLimitMustBePositive -> "response-limit-invalid"
  ControlPlaneTransportFailed httpError ->
    "http/" <> renderTransportHttpError httpError
  ControlPlaneResponseTooLarge _ _ -> "response-too-large"

renderTransportHttpError :: HttpError -> Text
renderTransportHttpError httpError = case httpError of
  HttpConnectionFailure _ -> "connection-failed"
  HttpTimeout _ -> "timeout"
  HttpStatus status _ -> "status/" <> renderHttpStatusClass status
  HttpDecode _ -> "decode-failed"

renderHttpStatusClass :: Int -> Text
renderHttpStatusClass status = case status of
  400 -> "bad-request"
  401 -> "unauthorized"
  403 -> "forbidden"
  404 -> "not-found"
  409 -> "conflict"
  429 -> "too-many-requests"
  _
    | status >= 400 && status < 500 -> "other-client"
    | status >= 500 && status < 600 -> "server"
    | otherwise -> "other"

mkTlsRetentionAuthorityClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> Text
  -> Text
  -> Either TlsRetentionAuthorityClientError (TlsRetentionAuthorityClient IO)
mkTlsRetentionAuthorityClient transport substrate scope = do
  _ <- first TlsRetentionAuthorityClientSlotInvalid (mkTlsRetentionSlot substrate scope)
  Right
    TlsRetentionAuthorityClient
      { observeTlsRetentionCurrent = observe
      , stageTlsRetentionCurrent = stage
      , stageTlsRetentionAfterUnrecoverableLegacy = stageLegacyRecovery
      , stageTlsRetentionAfterPendingCollision = stagePendingCollision
      , stageTlsRetentionTerminalReplacement = stageTerminalReplacement
      , stageTlsRetentionAfterUnopenableVersion = stageUnopenableSuccessor
      , promoteTlsRetentionCurrent = promote
      }
 where
  observe = do
    response <-
      call
        LifecycleTlsRetentionObserveRoute
        TlsAuthorityObserveRequest
          { tlsAuthorityObserveSubstrate = substrate
          , tlsAuthorityObserveScope = scope
          }
    pure $ do
      decoded <- response
      case decoded of
        TlsAuthorityObserved state -> Right state
        other -> Left (remoteError other)

  stage approval candidate envelope = do
    response <-
      call
        LifecycleTlsRetentionStageRoute
        TlsAuthorityStageRequest
          { tlsAuthorityStageSubstrate = substrate
          , tlsAuthorityStageScope = scope
          , tlsAuthorityStageApproval = approval
          , tlsAuthorityStagePendingCollision = Nothing
          , tlsAuthorityStageTerminalReplacement = Nothing
          , tlsAuthorityStageCandidate = candidate
          , tlsAuthorityStageEnvelope = envelope
          }
    pure $ do
      decoded <- response
      case decoded of
        TlsAuthorityStagingApplied state ->
          Right (TlsAuthorityStagingCommitted state)
        TlsAuthorityStagingNoop state ->
          Right (TlsAuthorityStagingAlreadyPending state)
        other -> Left (remoteError other)

  stagePendingCollision approval recovery candidate envelope = do
    response <-
      call
        LifecycleTlsRetentionStageRoute
        TlsAuthorityStageRequest
          { tlsAuthorityStageSubstrate = substrate
          , tlsAuthorityStageScope = scope
          , tlsAuthorityStageApproval = approval
          , tlsAuthorityStagePendingCollision = Just recovery
          , tlsAuthorityStageTerminalReplacement = Nothing
          , tlsAuthorityStageCandidate = candidate
          , tlsAuthorityStageEnvelope = envelope
          }
    pure $ do
      decoded <- response
      case decoded of
        TlsAuthorityStagingApplied state ->
          Right (TlsAuthorityStagingCommitted state)
        TlsAuthorityStagingNoop state ->
          Right (TlsAuthorityStagingAlreadyPending state)
        other -> Left (remoteError other)

  stageTerminalReplacement approval recovery terminalEvidence candidate envelope = do
    response <-
      call
        LifecycleTlsRetentionStageRoute
        TlsAuthorityStageRequest
          { tlsAuthorityStageSubstrate = substrate
          , tlsAuthorityStageScope = scope
          , tlsAuthorityStageApproval = approval
          , tlsAuthorityStagePendingCollision = Just recovery
          , tlsAuthorityStageTerminalReplacement = Just terminalEvidence
          , tlsAuthorityStageCandidate = candidate
          , tlsAuthorityStageEnvelope = envelope
          }
    pure $ do
      decoded <- response
      case decoded of
        TlsAuthorityStagingApplied state ->
          Right (TlsAuthorityStagingCommitted state)
        TlsAuthorityStagingNoop state ->
          Right (TlsAuthorityStagingAlreadyPending state)
        other -> Left (remoteError other)

  stageLegacyRecovery approval evidence collision candidate envelope = do
    response <-
      call
        LifecycleTlsRetentionLegacyRecoveryStageRoute
        TlsAuthorityLegacyRecoveryStageRequest
          { tlsAuthorityLegacyRecoveryStageSubstrate = substrate
          , tlsAuthorityLegacyRecoveryStageScope = scope
          , tlsAuthorityLegacyRecoveryStageApproval = approval
          , tlsAuthorityLegacyRecoveryStageEvidence = evidence
          , tlsAuthorityLegacyRecoveryStageCollision = collision
          , tlsAuthorityLegacyRecoveryStageCandidate = candidate
          , tlsAuthorityLegacyRecoveryStageEnvelope = envelope
          }
    pure $ do
      decoded <- response
      case decoded of
        TlsAuthorityStagingApplied state ->
          Right (TlsAuthorityStagingCommitted state)
        TlsAuthorityStagingNoop state ->
          Right (TlsAuthorityStagingAlreadyPending state)
        other -> Left (remoteError other)

  stageUnopenableSuccessor approval evidence candidate envelope = do
    response <-
      call
        LifecycleTlsRetentionUnopenableSuccessorStageRoute
        TlsAuthorityUnopenableSuccessorStageRequest
          { tlsAuthorityUnopenableSuccessorStageSubstrate = substrate
          , tlsAuthorityUnopenableSuccessorStageScope = scope
          , tlsAuthorityUnopenableSuccessorStageApproval = approval
          , tlsAuthorityUnopenableSuccessorStageEvidence = evidence
          , tlsAuthorityUnopenableSuccessorStageCandidate = candidate
          , tlsAuthorityUnopenableSuccessorStageEnvelope = envelope
          }
    pure $ do
      decoded <- response
      case decoded of
        TlsAuthorityStagingApplied state ->
          Right (TlsAuthorityStagingCommitted state)
        TlsAuthorityStagingNoop state ->
          Right (TlsAuthorityStagingAlreadyPending state)
        other -> Left (remoteError other)

  promote approval evidence candidate = do
    response <-
      call
        LifecycleTlsRetentionPromoteRoute
        TlsAuthorityPromoteRequest
          { tlsAuthorityPromoteSubstrate = substrate
          , tlsAuthorityPromoteScope = scope
          , tlsAuthorityPromoteApproval = approval
          , tlsAuthorityPromoteEvidence = evidence
          , tlsAuthorityPromoteCandidate = candidate
          }
    pure $ do
      decoded <- response
      case decoded of
        TlsAuthorityPromotionApplied state ->
          Right (TlsAuthorityPromotionCommitted state)
        TlsAuthorityPromotionNoop state ->
          Right (TlsAuthorityPromotionAlreadyCurrent state)
        other -> Left (remoteError other)

  call route request = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        route
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        first TlsRetentionAuthorityClientTransportFailed attempted
      response <-
        first
          TlsRetentionAuthorityClientResponseInvalid
          ( decodeControlPlaneResponse
              tlsAuthorityResponseMaximumBytes
              (LazyByteString.fromStrict body)
          )
      -- Sprint 4.67: the expected status comes from the server's own
      -- projection. This `where` clause used to hold a second, verbatim copy of
      -- `tlsAuthorityResponseHttpStatus` — a restatement that a change to the
      -- server would have made wrong rather than updated
      -- ([chaos_hardening_doctrine.md § 23](../../../documents/engineering/chaos_hardening_doctrine.md)).
      -- The peer's status stays an `Int` because it is a byte off the wire and
      -- no type here bounds what a peer may send (§ 22); the comparison
      -- projects the expected value down to meet it.
      if status == replyStatusCode (tlsAuthorityResponseHttpStatus response)
        then Right response
        else Left (TlsRetentionAuthorityClientHttpStatus status)

remoteError :: TlsAuthorityResponse -> TlsRetentionAuthorityClientError
remoteError response = case response of
  TlsAuthorityStagingRefused detail ->
    TlsRetentionAuthorityClientRemoteRefused detail
  TlsAuthorityPromotionRefused detail ->
    TlsRetentionAuthorityClientRemoteRefused detail
  TlsAuthorityConcurrentWrite -> TlsRetentionAuthorityClientConcurrentWrite
  TlsAuthorityUnavailable -> TlsRetentionAuthorityClientUnavailable
  TlsAuthorityRequestRefused ->
    TlsRetentionAuthorityClientRemoteRefused "request-refused"
  _ -> TlsRetentionAuthorityClientResponseShapeMismatch
