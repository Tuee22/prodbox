{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.50: the server side of the Lifecycle Authority's core operation
-- routes @operations/submit@ (POST @\/v1\/operations\/submit@) and
-- @operations/observe@ (GET @\/v1\/operations\/observe@).
--
-- The pure idempotent submission algebra
-- ('Prodbox.Lifecycle.Authority.Submission') already binds a stable
-- @(client, sequence, digest)@ identity to an 'OperationId' under the admitting
-- 'AuthorityEpoch', treats an exact resubmission as an idempotent duplicate, and
-- refuses a reused sequence, an expired sequence, or an at-capacity ledger. This
-- endpoint fronts that decision the way 'Prodbox.ControlPlane.AuthorityBackupEndpoint'
-- fronts backup-repair: @submit@ reads the admitting epoch plus the current ledger
-- through an injected repository, drives 'stepSubmit', and compare-and-swaps the
-- evolved ledger only when it changed (a duplicate or refusal never mutates, exactly
-- like 'applySubmit'); @observe@ returns a @(client, sequence)@ status without
-- mutation. The outcome projects onto a total HTTP status and a stable kebab-case
-- diagnostic summary.
--
-- It is pure over the injected repository, so an in-memory fixture exercises every
-- request/response arm without a live cluster, Vault, or object store. Binding the
-- production retained compare-and-swap repository and dispatching the raw socket
-- request on 'Prodbox.ControlPlane.Route.LifecycleOperationSubmit' /
-- 'Prodbox.ControlPlane.Route.LifecycleOperationObserve' to these handlers in
-- @runControlPlaneRole@ are the live-coupled follow-ons (Standard O), exactly as for
-- the migration, backup, TLS-retention, and target-secret endpoints.
module Prodbox.ControlPlane.OperationEndpoint
  ( -- * Wire payloads
    OperationSubmitPayload (..)
  , OperationObservePayload (..)

    -- * Repository
  , OperationSubmissionRepository (..)

    -- * Serving
  , OperationSubmitResult (..)
  , serveOperationSubmit
  , serveOperationSubmitRequest
  , serveOperationObserve
  , serveOperationObserveRequest

    -- * Response projections
  , operationSubmitHttpStatus
  , operationSubmitSummary
  , operationObserveHttpStatus
  , operationObserveSummary
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  )
import Prodbox.Lifecycle.Authority.Genesis (AuthorityEpoch)
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId (ClientId)
  , ClientSequence (ClientSequence)
  , RequestDigest (RequestDigest)
  , SubmissionLedger
  , SubmissionStatus
    ( StatusExpired
    , StatusInFlight
    , StatusSettled
    , StatusUnknown
    )
  , SubmitDecision
    ( SubmissionAccepted
    , SubmissionDuplicate
    , SubmissionRefusedExpired
    , SubmissionRefusedFull
    , SubmissionRefusedSequenceReused
    )
  , TerminalOutcome (OperationCancelledOutcome, OperationCompletedOutcome)
  , stepSubmit
  , submissionStatus
  )

-- | The bounded, canonical wire body of an @operations/submit@ request: the
-- caller's stable @(client, sequence, digest)@ identity carried as transport
-- primitives. The endpoint rebuilds it into the algebra's 'ClientId' /
-- 'ClientSequence' / 'RequestDigest' after decoding.
data OperationSubmitPayload = OperationSubmitPayload
  { operationSubmitClient :: !Text
  , operationSubmitSequence :: !Natural
  , operationSubmitDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The bounded, canonical wire body of an @operations/observe@ request: the
-- @(client, sequence)@ whose current submission status is queried.
data OperationObservePayload = OperationObservePayload
  { operationObserveClient :: !Text
  , operationObserveSequence :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The retained submission store: read the admitting epoch plus the current
-- ledger, and compare-and-swap an evolved ledger.
data OperationSubmissionRepository m = OperationSubmissionRepository
  { readSubmissionState :: m (AuthorityEpoch, SubmissionLedger)
  , commitSubmissionLedger :: SubmissionLedger -> m (Either Text ())
  }

-- | The closed outcome of serving one @operations/submit@ request. A malformed
-- request body ('OperationSubmitBadRequest') is distinct from a well-formed
-- submission the algebra decides (carried inside 'OperationSubmitDecided'), which is
-- in turn distinct from an authority-side durable write failure.
data OperationSubmitResult
  = -- | The submission was decided against the current ledger. On a genuine
    -- 'SubmissionAccepted' the evolved ledger was durably committed; a duplicate or
    -- refusal never mutates the ledger, so no commit was attempted.
    OperationSubmitDecided !SubmitDecision
  | -- | An accepted submission was decided but its durable commit failed (retry).
    OperationSubmitWriteFailed !Text
  | -- | The request body was not a bounded, canonical, supported-version submit
    -- payload; no state was read or written.
    OperationSubmitBadRequest !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

-- | Serve a submission against an injected repository: read the admitting epoch and
-- ledger, 'stepSubmit', and commit only a genuine advance (the evolved ledger
-- differs from the read one). A duplicate or refusal leaves the ledger untouched, so
-- no compare-and-swap is attempted.
serveOperationSubmit
  :: (Monad m)
  => OperationSubmissionRepository m
  -> ClientId
  -> ClientSequence
  -> RequestDigest
  -> m OperationSubmitResult
serveOperationSubmit repository client seqNo digest = do
  (epoch, ledger) <- readSubmissionState repository
  let (decision, next) = stepSubmit epoch ledger client seqNo digest
  if next == ledger
    then pure (OperationSubmitDecided decision)
    else do
      committed <- commitSubmissionLedger repository next
      pure $ case committed of
        Left detail -> OperationSubmitWriteFailed detail
        Right () -> OperationSubmitDecided decision

-- | Serve an @operations/submit@ request from a raw body: decode the bounded,
-- canonical 'OperationSubmitPayload' and, only for a well-formed body, run
-- 'serveOperationSubmit'. A malformed body is refused ('OperationSubmitBadRequest')
-- before any state is read. @maximumBytes@ bounds the request framing. This is the
-- through-seam entry a production 'Prodbox.ControlPlane.Server.RoleInterpreter'
-- dispatches the raw socket body to; it stays pure over the injected repository.
serveOperationSubmitRequest
  :: (Monad m)
  => Int
  -> OperationSubmissionRepository m
  -> ByteString
  -> m OperationSubmitResult
serveOperationSubmitRequest maximumBytes repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (OperationSubmitBadRequest err)
    Right payload ->
      serveOperationSubmit
        repository
        (ClientId (operationSubmitClient payload))
        (ClientSequence (operationSubmitSequence payload))
        (RequestDigest (operationSubmitDigest payload))

-- | Serve an @operations/observe@: the current status of a @(client, sequence)@
-- submission, no mutation.
serveOperationObserve
  :: (Monad m)
  => OperationSubmissionRepository m
  -> ClientId
  -> ClientSequence
  -> m SubmissionStatus
serveOperationObserve repository client seqNo = do
  (_, ledger) <- readSubmissionState repository
  pure (submissionStatus client seqNo ledger)

-- | Serve an @operations/observe@ request from a raw body: decode the bounded,
-- canonical 'OperationObservePayload' and, only for a well-formed body, look the
-- submission's status up. A malformed body is refused before any state is read.
serveOperationObserveRequest
  :: (Monad m)
  => Int
  -> OperationSubmissionRepository m
  -> ByteString
  -> m (Either ControlPlaneRequestCodecError SubmissionStatus)
serveOperationObserveRequest maximumBytes repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (Left err)
    Right payload ->
      Right
        <$> serveOperationObserve
          repository
          (ClientId (operationObserveClient payload))
          (ClientSequence (operationObserveSequence payload))

-- | Total HTTP status projection for @operations/submit@. A fresh acceptance and an
-- idempotent duplicate are both @200@ (the caller re-observes for the operation's
-- phase); a reused sequence and an expired sequence are @409 Conflict@; an
-- at-capacity ledger is @503@ (transient back-pressure, retryable, no state change);
-- a failed durable write is @503@; a malformed request is @400@.
operationSubmitHttpStatus :: OperationSubmitResult -> Int
operationSubmitHttpStatus result = case result of
  OperationSubmitBadRequest _ -> 400
  OperationSubmitWriteFailed _ -> 503
  OperationSubmitDecided decision -> case decision of
    SubmissionAccepted _ -> 200
    SubmissionDuplicate _ -> 200
    SubmissionRefusedFull -> 503
    SubmissionRefusedSequenceReused -> 409
    SubmissionRefusedExpired -> 409

-- | Stable single-line diagnostic body for @operations/submit@. Kebab-case tokens
-- keep the response machine-greppable without serialising the bound 'OperationId'.
operationSubmitSummary :: OperationSubmitResult -> Text
operationSubmitSummary result = case result of
  OperationSubmitBadRequest err ->
    "operation-submit-bad-request:" <> controlPlaneRequestCodecToken err
  OperationSubmitWriteFailed _ -> "operation-submit-write-failed"
  OperationSubmitDecided decision -> case decision of
    SubmissionAccepted _ -> "operation-accepted"
    SubmissionDuplicate _ -> "operation-duplicate"
    SubmissionRefusedFull -> "operation-refused-full"
    SubmissionRefusedSequenceReused -> "operation-refused-sequence-reused"
    SubmissionRefusedExpired -> "operation-refused-expired"

-- | Total HTTP status projection for @operations/observe@. A known submission
-- (in-flight, settled, or expired but previously seen) is @200@; a never-seen
-- @(client, sequence)@ is @404@.
operationObserveHttpStatus :: SubmissionStatus -> Int
operationObserveHttpStatus status = case status of
  StatusInFlight -> 200
  StatusSettled _ -> 200
  StatusExpired -> 200
  StatusUnknown -> 404

-- | Stable single-line diagnostic body for @operations/observe@.
operationObserveSummary :: SubmissionStatus -> Text
operationObserveSummary status = case status of
  StatusInFlight -> "operation-in-flight"
  StatusSettled OperationCompletedOutcome -> "operation-settled-completed"
  StatusSettled OperationCancelledOutcome -> "operation-settled-cancelled"
  StatusExpired -> "operation-expired"
  StatusUnknown -> "operation-unknown"
