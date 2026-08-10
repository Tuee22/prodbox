{-# LANGUAGE DataKinds #-}
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
-- It is pure over the injected exact-revision repository, so fixtures exercise
-- every request/response arm without a live cluster, while
-- 'modelBOperationSubmissionRepository' supplies the production
-- @'ClusterRetained'@ binding used by @runControlPlaneRole@.
module Prodbox.ControlPlane.OperationEndpoint
  ( -- * Wire payloads
    OperationSubmitPayload (..)
  , OperationObservePayload (..)

    -- * Repository
  , OperationSubmissionState (..)
  , OperationSubmissionSnapshot (..)
  , OperationSubmissionRepository (..)
  , OperationSubmissionStateCodecError (..)
  , operationSubmissionMaximumEncodedBytes
  , initialOperationSubmissionState
  , operationSubmissionStateCodec
  , modelBOperationSubmissionRepository

    -- * Serving
  , OperationSubmitResult (..)
  , OperationObserveResult (..)
  , serveOperationSubmit
  , serveOperationSubmitRequest
  , serveOperationObserve
  , serveOperationObserveRequest

    -- * Response projections
  , operationSubmitHttpStatus
  , operationSubmitSummary
  , operationObserveHttpStatus
  , operationObserveSummary
  , operationObserveResultHttpStatus
  , operationObserveResultSummary
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString qualified as StrictByteString
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (fromLeft)
import Data.Text (Text)
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityEpoch
  , authorityEpochValue
  )
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
  , emptySubmissionLedger
  , liveSubmissionCount
  , stepSubmit
  , submissionCapacity
  , submissionStatus
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
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

-- | The single retained operation-submission object.  Epoch and capacity are
-- durable, rather than process defaults silently substituted after restart.
data OperationSubmissionState = OperationSubmissionState
  { operationSubmissionEpoch :: !AuthorityEpoch
  , operationSubmissionLedger :: !SubmissionLedger
  }
  deriving stock (Eq, Show)

-- | One authoritative read plus the opaque exact revision that read observed.
-- The repository's revision type stays abstract to the endpoint; the production
-- binding uses @Maybe ModelBObjectVersion@ so missing initializes and observed
-- state replaces only its exact S3 version.
data OperationSubmissionSnapshot revision = OperationSubmissionSnapshot
  { operationSubmissionRevision :: !revision
  , operationSubmissionSnapshotState :: !OperationSubmissionState
  }
  deriving stock (Eq, Show)

-- | Exact-revision retained repository.  A CAS result is provisional: callers
-- must always perform a fresh 'readSubmissionState' and confirm the logical
-- operation identity, allowing applied-but-response-lost writes to converge.
data OperationSubmissionRepository m revision = OperationSubmissionRepository
  { readSubmissionState :: m (Either Text (OperationSubmissionSnapshot revision))
  , compareAndSwapSubmissionState
      :: revision
      -> OperationSubmissionState
      -> m (Either Text ())
  }

-- | Physical codec refusal for the one retained submission object.
data OperationSubmissionStateCodecError
  = OperationSubmissionStateTooLarge !Int !Int
  | OperationSubmissionStateInvalid
  | OperationSubmissionStateUnsupportedVersion !Word16
  | OperationSubmissionStateNonCanonical
  | OperationSubmissionStateEpochMismatch !Natural !Natural
  | OperationSubmissionStateCapacityMismatch !Natural !Natural
  | OperationSubmissionStateLiveOverCapacity !Natural !Natural
  deriving stock (Eq, Show)

data OperationSubmissionEnvelope = OperationSubmissionEnvelope
  { operationSubmissionEnvelopeVersion :: !Word16
  , operationSubmissionEnvelopeEpoch :: !Natural
  , operationSubmissionEnvelopeLedger :: !SubmissionLedger
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

operationSubmissionMaximumEncodedBytes :: Int
operationSubmissionMaximumEncodedBytes = 256 * 1024

operationSubmissionCodecVersion :: Word16
operationSubmissionCodecVersion = 1

initialOperationSubmissionState
  :: AuthorityEpoch
  -> Natural
  -> OperationSubmissionState
initialOperationSubmissionState epoch capacity =
  OperationSubmissionState
    { operationSubmissionEpoch = epoch
    , operationSubmissionLedger = emptySubmissionLedger capacity
    }

-- | Bounded, versioned, canonical codec fixed to the runtime's initialized
-- authority epoch and capacity.  A retained object from another authority
-- configuration is corruption evidence, never silently adopted with new
-- process defaults.
operationSubmissionStateCodec
  :: Int
  -> AuthorityEpoch
  -> Natural
  -> ModelBCodec OperationSubmissionState
operationSubmissionStateCodec maximumBytes expectedEpoch expectedCapacity =
  ModelBCodec
    { encodeModelBValue =
        either (Left . show) Right
          . encodeOperationSubmissionState
            maximumBytes
            expectedEpoch
            expectedCapacity
    , decodeModelBValue =
        either (Left . show) Right
          . decodeOperationSubmissionState
            maximumBytes
            expectedEpoch
            expectedCapacity
    }

encodeOperationSubmissionState
  :: Int
  -> AuthorityEpoch
  -> Natural
  -> OperationSubmissionState
  -> Either OperationSubmissionStateCodecError StrictByteString.ByteString
encodeOperationSubmissionState maximumBytes expectedEpoch expectedCapacity state = do
  validateOperationSubmissionState expectedEpoch expectedCapacity state
  let bytes =
        LazyByteString.toStrict
          ( serialise
              OperationSubmissionEnvelope
                { operationSubmissionEnvelopeVersion = operationSubmissionCodecVersion
                , operationSubmissionEnvelopeEpoch = authorityEpochValue expectedEpoch
                , operationSubmissionEnvelopeLedger = operationSubmissionLedger state
                }
          )
  if maximumBytes < 0 || StrictByteString.length bytes > maximumBytes
    then
      Left
        ( OperationSubmissionStateTooLarge
            (StrictByteString.length bytes)
            maximumBytes
        )
    else Right bytes

decodeOperationSubmissionState
  :: Int
  -> AuthorityEpoch
  -> Natural
  -> StrictByteString.ByteString
  -> Either OperationSubmissionStateCodecError OperationSubmissionState
decodeOperationSubmissionState maximumBytes expectedEpoch expectedCapacity bytes
  | maximumBytes < 0 || StrictByteString.length bytes > maximumBytes =
      Left
        ( OperationSubmissionStateTooLarge
            (StrictByteString.length bytes)
            maximumBytes
        )
  | otherwise = do
      envelope <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left OperationSubmissionStateInvalid
        Right decoded -> Right decoded
      if operationSubmissionEnvelopeVersion envelope /= operationSubmissionCodecVersion
        then
          Left
            ( OperationSubmissionStateUnsupportedVersion
                (operationSubmissionEnvelopeVersion envelope)
            )
        else Right ()
      let observedEpoch = operationSubmissionEnvelopeEpoch envelope
          requiredEpoch = authorityEpochValue expectedEpoch
      if observedEpoch /= requiredEpoch
        then Left (OperationSubmissionStateEpochMismatch requiredEpoch observedEpoch)
        else Right ()
      let state =
            OperationSubmissionState
              { operationSubmissionEpoch = expectedEpoch
              , operationSubmissionLedger = operationSubmissionEnvelopeLedger envelope
              }
      validateOperationSubmissionState expectedEpoch expectedCapacity state
      if LazyByteString.toStrict (serialise envelope) /= bytes
        then Left OperationSubmissionStateNonCanonical
        else Right state

validateOperationSubmissionState
  :: AuthorityEpoch
  -> Natural
  -> OperationSubmissionState
  -> Either OperationSubmissionStateCodecError ()
validateOperationSubmissionState expectedEpoch expectedCapacity state
  | operationSubmissionEpoch state /= expectedEpoch =
      Left
        ( OperationSubmissionStateEpochMismatch
            (authorityEpochValue expectedEpoch)
            (authorityEpochValue (operationSubmissionEpoch state))
        )
  | submissionCapacity ledger /= expectedCapacity =
      Left
        ( OperationSubmissionStateCapacityMismatch
            expectedCapacity
            (submissionCapacity ledger)
        )
  | liveSubmissionCount ledger > expectedCapacity =
      Left
        ( OperationSubmissionStateLiveOverCapacity
            (liveSubmissionCount ledger)
            expectedCapacity
        )
  | otherwise = Right ()
 where
  ledger = operationSubmissionLedger state

-- | Bind the exact-revision repository to one retained Model-B coordinate.
-- Missing state is the explicit initialized epoch/capacity snapshot; observed,
-- corrupt, endpoint-unready, and unobservable remain distinct from absence.
modelBOperationSubmissionRepository
  :: (Monad m)
  => OperationSubmissionState
  -> ModelBCasAdapter 'ClusterRetained m OperationSubmissionState
  -> ModelBObjectCoordinate 'ClusterRetained
  -> OperationSubmissionRepository m (Maybe ModelBObjectVersion)
modelBOperationSubmissionRepository initialState adapter coordinate =
  OperationSubmissionRepository
    { readSubmissionState = do
        observation <- modelBObserve adapter coordinate
        pure $ case observation of
          ModelBMissing ->
            Right
              OperationSubmissionSnapshot
                { operationSubmissionRevision = Nothing
                , operationSubmissionSnapshotState = initialState
                }
          ModelBObserved revision state ->
            Right
              OperationSubmissionSnapshot
                { operationSubmissionRevision = Just revision
                , operationSubmissionSnapshotState = state
                }
          ModelBCorrupt detail -> Left ("operation submission state is corrupt: " <> detail)
          ModelBEndpointUnready detail ->
            Left ("operation submission state is not ready: " <> detail)
          ModelBUnobservable detail ->
            Left ("operation submission state is unobservable: " <> detail)
    , compareAndSwapSubmissionState = \expected state -> do
        result <-
          modelBCompareAndSwap adapter $ case expected of
            Nothing -> ModelBInitialize coordinate state
            Just revision -> ModelBReplace coordinate revision state
        pure $ case result of
          ModelBCasApplied _ _ -> Right ()
          ModelBCasConflict _ -> Left "operation submission CAS conflict"
          ModelBCasRefusedCorrupt detail ->
            Left ("operation submission CAS refused corrupt: " <> detail)
          ModelBCasEndpointUnready detail ->
            Left ("operation submission CAS is not ready: " <> detail)
          ModelBCasUnobservable detail ->
            Left ("operation submission CAS is unobservable: " <> detail)
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
  | -- | The retained state could not be authoritatively observed.
    OperationSubmitReadFailed !Text
  | -- | An accepted submission was decided but its durable commit failed (retry).
    OperationSubmitWriteFailed !Text
  | -- | The request body was not a bounded, canonical, supported-version submit
    -- payload; no state was read or written.
    OperationSubmitBadRequest !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

data OperationObserveResult
  = OperationObserveFound !SubmissionStatus
  | OperationObserveReadFailed !Text
  | OperationObserveBadRequest !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

-- | Serve a submission against an injected repository: read the admitting epoch and
-- ledger, 'stepSubmit', and commit only a genuine advance (the evolved ledger
-- differs from the read one). A duplicate or refusal leaves the ledger untouched, so
-- no compare-and-swap is attempted.
serveOperationSubmit
  :: (Monad m)
  => OperationSubmissionRepository m revision
  -> ClientId
  -> ClientSequence
  -> RequestDigest
  -> m OperationSubmitResult
serveOperationSubmit repository client seqNo digest = do
  observed <- readSubmissionState repository
  case observed of
    Left detail -> pure (OperationSubmitReadFailed detail)
    Right snapshot -> do
      let state = operationSubmissionSnapshotState snapshot
          epoch = operationSubmissionEpoch state
          ledger = operationSubmissionLedger state
          (decision, nextLedger) = stepSubmit epoch ledger client seqNo digest
      if nextLedger == ledger
        then pure (OperationSubmitDecided decision)
        else do
          attempted <-
            compareAndSwapSubmissionState
              repository
              (operationSubmissionRevision snapshot)
              state {operationSubmissionLedger = nextLedger}
          confirmAcceptedSubmission repository attempted decision client seqNo digest

confirmAcceptedSubmission
  :: (Monad m)
  => OperationSubmissionRepository m revision
  -> Either Text ()
  -> SubmitDecision
  -> ClientId
  -> ClientSequence
  -> RequestDigest
  -> m OperationSubmitResult
confirmAcceptedSubmission repository attempted decision client seqNo digest =
  case decision of
    SubmissionAccepted accepted -> do
      readback <- readSubmissionState repository
      pure $ case readback of
        Left detail ->
          OperationSubmitWriteFailed
            ("operation submission readback failed: " <> detail)
        Right snapshot ->
          let state = operationSubmissionSnapshotState snapshot
              confirmed =
                decideConfirmed
                  (operationSubmissionEpoch state)
                  (operationSubmissionLedger state)
           in if confirmed
                then OperationSubmitDecided decision
                else
                  OperationSubmitWriteFailed
                    ( fromLeft
                        "operation submission CAS was not confirmed by readback"
                        attempted
                    )
     where
      decideConfirmed epoch ledger =
        case fst (stepSubmit epoch ledger client seqNo digest) of
          SubmissionDuplicate duplicate -> duplicate == accepted
          _ -> False
    _ ->
      pure
        (OperationSubmitWriteFailed "operation submission changed without an accepted decision")

-- | Serve an @operations/submit@ request from a raw body: decode the bounded,
-- canonical 'OperationSubmitPayload' and, only for a well-formed body, run
-- 'serveOperationSubmit'. A malformed body is refused ('OperationSubmitBadRequest')
-- before any state is read. @maximumBytes@ bounds the request framing. This is the
-- through-seam entry a production 'Prodbox.ControlPlane.Server.RoleInterpreter'
-- dispatches the raw socket body to; it stays pure over the injected repository.
serveOperationSubmitRequest
  :: (Monad m)
  => Int
  -> OperationSubmissionRepository m revision
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
  => OperationSubmissionRepository m revision
  -> ClientId
  -> ClientSequence
  -> m OperationObserveResult
serveOperationObserve repository client seqNo = do
  observed <- readSubmissionState repository
  pure $ case observed of
    Left detail -> OperationObserveReadFailed detail
    Right snapshot ->
      OperationObserveFound
        ( submissionStatus
            client
            seqNo
            (operationSubmissionLedger (operationSubmissionSnapshotState snapshot))
        )

-- | Serve an @operations/observe@ request from a raw body: decode the bounded,
-- canonical 'OperationObservePayload' and, only for a well-formed body, look the
-- submission's status up. A malformed body is refused before any state is read.
serveOperationObserveRequest
  :: (Monad m)
  => Int
  -> OperationSubmissionRepository m revision
  -> ByteString
  -> m OperationObserveResult
serveOperationObserveRequest maximumBytes repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (OperationObserveBadRequest err)
    Right payload ->
      serveOperationObserve
        repository
        (ClientId (operationObserveClient payload))
        (ClientSequence (operationObserveSequence payload))

-- | Total HTTP status projection for @operations/submit@. A fresh acceptance and an
-- idempotent duplicate are both @200@ (the caller re-observes for the operation's
-- phase); a reused sequence and an expired sequence are @409 Conflict@; an
-- at-capacity ledger is @503@ (transient back-pressure, retryable, no state change);
-- a failed durable write is @503@; a malformed request is @400@.
operationSubmitHttpStatus :: OperationSubmitResult -> ReplyStatus
operationSubmitHttpStatus result = case result of
  OperationSubmitBadRequest _ -> ReplyBadRequest
  OperationSubmitReadFailed _ -> ReplyServiceUnavailable
  OperationSubmitWriteFailed _ -> ReplyServiceUnavailable
  OperationSubmitDecided decision -> case decision of
    SubmissionAccepted _ -> ReplyOk
    SubmissionDuplicate _ -> ReplyOk
    SubmissionRefusedFull -> ReplyServiceUnavailable
    SubmissionRefusedSequenceReused -> ReplyConflict
    SubmissionRefusedExpired -> ReplyConflict

-- | Stable single-line diagnostic body for @operations/submit@. Kebab-case tokens
-- keep the response machine-greppable without serialising the bound 'OperationId'.
operationSubmitSummary :: OperationSubmitResult -> Text
operationSubmitSummary result = case result of
  OperationSubmitBadRequest err ->
    "operation-submit-bad-request:" <> controlPlaneRequestCodecToken err
  OperationSubmitWriteFailed _ -> "operation-submit-write-failed"
  OperationSubmitReadFailed _ -> "operation-submit-read-failed"
  OperationSubmitDecided decision -> case decision of
    SubmissionAccepted _ -> "operation-accepted"
    SubmissionDuplicate _ -> "operation-duplicate"
    SubmissionRefusedFull -> "operation-refused-full"
    SubmissionRefusedSequenceReused -> "operation-refused-sequence-reused"
    SubmissionRefusedExpired -> "operation-refused-expired"

-- | Total HTTP status projection for @operations/observe@. A known submission
-- (in-flight, settled, or expired but previously seen) is @200@; a never-seen
-- @(client, sequence)@ is @404@.
operationObserveHttpStatus :: SubmissionStatus -> ReplyStatus
operationObserveHttpStatus status = case status of
  StatusInFlight -> ReplyOk
  StatusSettled _ -> ReplyOk
  StatusExpired -> ReplyOk
  StatusUnknown -> ReplyNotFound

-- | Stable single-line diagnostic body for @operations/observe@.
operationObserveSummary :: SubmissionStatus -> Text
operationObserveSummary status = case status of
  StatusInFlight -> "operation-in-flight"
  StatusSettled OperationCompletedOutcome -> "operation-settled-completed"
  StatusSettled OperationCancelledOutcome -> "operation-settled-cancelled"
  StatusExpired -> "operation-expired"
  StatusUnknown -> "operation-unknown"

operationObserveResultHttpStatus :: OperationObserveResult -> ReplyStatus
operationObserveResultHttpStatus result = case result of
  OperationObserveFound status -> operationObserveHttpStatus status
  OperationObserveReadFailed _ -> ReplyServiceUnavailable
  OperationObserveBadRequest _ -> ReplyBadRequest

operationObserveResultSummary :: OperationObserveResult -> Text
operationObserveResultSummary result = case result of
  OperationObserveFound status -> operationObserveSummary status
  OperationObserveReadFailed _ -> "operation-observe-read-failed"
  OperationObserveBadRequest err ->
    "operation-observe-bad-request:" <> controlPlaneRequestCodecToken err
