{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.50: the response projection for the Target Secret Agent role's
-- @commit@ (prepare + complete) route.
--
-- The Target-commit protocol ('Prodbox.Lifecycle.TargetCommitIntent') is the
-- richest of the standing-role algebras: @decidePrepareTargetCommit@ and
-- @decideCompleteTargetCommit@ take the registered target set, coordinate,
-- authority time, fenced permit, sink, generation, digest, and the retained
-- projection observation, and yield a decision that either performs a guarded
-- retained compare-and-swap, is idempotently already-committed/applied, or is
-- refused with one of a large, precise refusal taxonomy.
--
-- This module owns the endpoint's total projection of those two decisions onto an
-- HTTP status and a stable summary — the pure, testable half of the endpoint. The
-- full handler (constructing the decision inputs and performing the guarded
-- retained CAS through the injected target-sink adapter) is the live-coupled
-- Standard-O follow-on; the refusal classification below is shared by both the
-- prepare and complete arms.
module Prodbox.ControlPlane.TargetSecretEndpoint
  ( targetPrepareHttpStatus
  , targetCompleteHttpStatus
  , targetPrepareSummary
  , targetCompleteSummary
  , targetCommitRefusalStatus
  , targetCommitRefusalToken

    -- * Sprint 4.50 prepare request handler
  , PrepareTargetCommitPayload (..)
  , TargetSecretPrepareRepository (..)
  , TargetPrepareEndpointResult (..)
  , servePrepareTargetCommitRequest
  , targetPrepareEndpointStatus
  , targetPrepareEndpointSummary
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBObservation
  , TargetClusterSecretSink
  , mkTargetClusterSecretSink
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , FencedCommitPermit
  , authorityTimeFromMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , RegisteredTargetSet
  , TargetCommitCompleteDecision
    ( TargetCommitCompleteAlreadyApplied
    , TargetCommitCompleteCompareAndSwap
    , TargetCommitCompleteRefused
    )
  , TargetCommitPrepareDecision
    ( TargetCommitPrepareAlreadyCommitted
    , TargetCommitPrepareCompareAndSwap
    , TargetCommitPrepareRefused
    )
  , TargetCommitRefusal (..)
  , TargetIntentCoordinate
  , TargetIntentProjection
  , TargetValueDigest
  , decidePrepareTargetCommit
  , mkCredentialGeneration
  , mkTargetValueDigest
  )

targetPrepareHttpStatus :: TargetCommitPrepareDecision -> Int
targetPrepareHttpStatus decision = case decision of
  TargetCommitPrepareCompareAndSwap _ _ -> 200
  TargetCommitPrepareAlreadyCommitted _ -> 200
  TargetCommitPrepareRefused refusal -> targetCommitRefusalStatus refusal

targetCompleteHttpStatus :: TargetCommitCompleteDecision -> Int
targetCompleteHttpStatus decision = case decision of
  TargetCommitCompleteCompareAndSwap _ -> 200
  TargetCommitCompleteAlreadyApplied -> 200
  TargetCommitCompleteRefused refusal -> targetCommitRefusalStatus refusal

targetPrepareSummary :: TargetCommitPrepareDecision -> Text
targetPrepareSummary decision = case decision of
  TargetCommitPrepareCompareAndSwap _ _ -> "target-prepare-cas"
  TargetCommitPrepareAlreadyCommitted _ -> "target-prepare-already-committed"
  TargetCommitPrepareRefused refusal -> "target-prepare-refused:" <> targetCommitRefusalToken refusal

targetCompleteSummary :: TargetCommitCompleteDecision -> Text
targetCompleteSummary decision = case decision of
  TargetCommitCompleteCompareAndSwap _ -> "target-complete-cas"
  TargetCommitCompleteAlreadyApplied -> "target-complete-already-applied"
  TargetCommitCompleteRefused refusal -> "target-complete-refused:" <> targetCommitRefusalToken refusal

-- | An unobservable global projection is @503@ (transient, re-read); a corrupt or
-- missing-after-prepare projection is a @500@ invariant break; every other refusal
-- is a @409@ conflict the caller re-resolves.
targetCommitRefusalStatus :: TargetCommitRefusal -> Int
targetCommitRefusalStatus refusal = case refusal of
  TargetCommitGlobalUnobservable _ -> 503
  TargetCommitGlobalCorrupt _ -> 500
  TargetCommitGlobalMissingAfterPrepare -> 500
  _ -> 409

-- | Stable kebab token for every refusal constructor (exhaustive).
targetCommitRefusalToken :: TargetCommitRefusal -> Text
targetCommitRefusalToken refusal = case refusal of
  TargetCommitGlobalMissingAfterPrepare -> "global-missing-after-prepare"
  TargetCommitGlobalCorrupt _ -> "global-corrupt"
  TargetCommitGlobalUnobservable _ -> "global-unobservable"
  TargetCommitProjectionRegistrationMismatch _ _ -> "projection-registration-mismatch"
  TargetCommitProjectionOverBound _ _ -> "projection-over-bound"
  TargetCommitProjectionKeyMismatch _ _ -> "projection-key-mismatch"
  TargetCommitIntentTargetMismatch _ _ -> "intent-target-mismatch"
  TargetCommitUnregisteredTarget _ -> "unregistered-target"
  TargetCommitDeadlineReached _ _ -> "deadline-reached"
  TargetCommitGenerationStale _ _ -> "generation-stale"
  TargetCommitGenerationDigestConflict _ -> "generation-digest-conflict"
  TargetCommitOutstandingIntent _ _ -> "outstanding-intent"
  TargetCommitTerminalIntentNeedsCompaction _ _ -> "terminal-intent-needs-compaction"
  TargetCommitExpectedIntentMissing _ -> "expected-intent-missing"
  TargetCommitExpectedIntentChanged _ _ -> "expected-intent-changed"
  TargetCommitPermitOwnerMismatch _ _ -> "permit-owner-mismatch"
  TargetCommitPermitFenceMismatch _ _ -> "permit-fence-mismatch"
  TargetCommitRecoveryFenceNotNewer _ _ -> "recovery-fence-not-newer"
  TargetCommitRecoveryWitnessMissing _ -> "recovery-witness-missing"
  TargetCommitRecoveryWitnessUnexpected _ -> "recovery-witness-unexpected"
  TargetCommitRecoveryWitnessIntentMismatch _ -> "recovery-witness-intent-mismatch"

-- | Sprint 4.50: the raw wire payload for the Target Secret Agent @commit@ route's
-- prepare arm. It carries only primitive commit specifics — the target sink
-- coordinates, the credential generation, the value digest, and the deadline (in
-- authority micros). The authority-side inputs (registered target set, intent
-- coordinate, the fenced commit permit minted from the held lease, the retained
-- projection observation, and the authority clock) are supplied by the injected
-- repository, never carried in the request: the fenced permit is an
-- authority-minted lease-authorization artifact and must never be reconstructed
-- from client bytes. No key or ciphertext material crosses this boundary.
data PrepareTargetCommitPayload = PrepareTargetCommitPayload
  { prepareSinkIdentity :: !Text
  , prepareSinkGatewayEndpoint :: !Text
  , prepareSinkVaultMount :: !Text
  , prepareSinkKvPath :: !Text
  , prepareGeneration :: !Natural
  , prepareDigest :: !Text
  , prepareDeadlineMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The authority-side inputs a prepare decision needs, read (never
-- request-carried) so the fenced permit stays unforgeable. An in-memory fixture
-- supplies these in a unit test; the production binding derives them from the
-- authority's lease / config / retained state (Standard-O).
data TargetSecretPrepareRepository m = TargetSecretPrepareRepository
  { readRegisteredTargets :: m RegisteredTargetSet
  , readTargetCoordinate :: m TargetIntentCoordinate
  , readFencedCommitPermit :: m FencedCommitPermit
  , readProjectionObservation :: m (ModelBObservation TargetIntentProjection)
  , readAuthorityNow :: m AuthorityTime
  }

-- | The closed outcome of serving a prepare request: a well-formed command the
-- proven algebra decided, a malformed request body, or a well-formed body whose
-- primitive field failed its smart-constructor validation.
data TargetPrepareEndpointResult
  = TargetPrepareDecided !TargetCommitPrepareDecision
  | -- | The request body was not a bounded, canonical, supported-version payload.
    TargetPrepareCodecRejected !ControlPlaneRequestCodecError
  | -- | A well-formed body carried a primitive that failed re-validation (empty
    -- digest, zero generation, malformed sink coordinate); the rendered field
    -- reason is diagnostic.
    TargetPrepareFieldRejected !Text
  deriving stock (Eq, Show)

-- | Serve a prepare request from a raw body: decode the bounded, canonical
-- 'PrepareTargetCommitPayload', re-validate its primitives through the same smart
-- constructors the algebra requires, read the authority-side inputs from the
-- injected repository, and decide through the proven 'decidePrepareTargetCommit'.
-- A malformed body or an invalid field is refused before any decision. Pure over
-- the repository; the production repository binding and the guarded-CAS execution
-- of the resulting decision are the Standard-O follow-ons.
servePrepareTargetCommitRequest
  :: (Monad m)
  => Int
  -> TargetSecretPrepareRepository m
  -> ByteString
  -> m TargetPrepareEndpointResult
servePrepareTargetCommitRequest maximumBytes repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (TargetPrepareCodecRejected err)
    Right payload -> case rebuildPreparedInputs payload of
      Left reason -> pure (TargetPrepareFieldRejected reason)
      Right (sink, generation, digest, deadline) -> do
        registered <- readRegisteredTargets repository
        coordinate <- readTargetCoordinate repository
        permit <- readFencedCommitPermit repository
        observation <- readProjectionObservation repository
        now <- readAuthorityNow repository
        pure
          ( TargetPrepareDecided
              ( decidePrepareTargetCommit
                  registered
                  coordinate
                  now
                  deadline
                  permit
                  sink
                  generation
                  digest
                  observation
              )
          )

-- | Re-validate the raw payload primitives into the typed inputs the algebra
-- requires, rendering the first failing field as a diagnostic reason.
rebuildPreparedInputs
  :: PrepareTargetCommitPayload
  -> Either Text (TargetClusterSecretSink, CredentialGeneration, TargetValueDigest, AuthorityTime)
rebuildPreparedInputs payload = do
  sink <-
    first
      (fieldReason "sink")
      ( mkTargetClusterSecretSink
          (prepareSinkIdentity payload)
          (prepareSinkGatewayEndpoint payload)
          (prepareSinkVaultMount payload)
          (prepareSinkKvPath payload)
      )
  generation <- first (fieldReason "generation") (mkCredentialGeneration (prepareGeneration payload))
  digest <- first (fieldReason "digest") (mkTargetValueDigest (prepareDigest payload))
  let deadline = authorityTimeFromMicros (prepareDeadlineMicros payload)
  pure (sink, generation, digest, deadline)
 where
  fieldReason :: (Show e) => Text -> e -> Text
  fieldReason field err = field <> ":" <> Text.pack (show err)

-- | Total HTTP status for a prepare-endpoint result. A decided command projects
-- through 'targetPrepareHttpStatus'; a codec or field rejection is @400@.
targetPrepareEndpointStatus :: TargetPrepareEndpointResult -> Int
targetPrepareEndpointStatus result = case result of
  TargetPrepareDecided decision -> targetPrepareHttpStatus decision
  TargetPrepareCodecRejected _ -> 400
  TargetPrepareFieldRejected _ -> 400

-- | Stable single-line diagnostic summary for a prepare-endpoint result.
targetPrepareEndpointSummary :: TargetPrepareEndpointResult -> Text
targetPrepareEndpointSummary result = case result of
  TargetPrepareDecided decision -> targetPrepareSummary decision
  TargetPrepareCodecRejected err -> "target-prepare-bad-request:" <> controlPlaneRequestCodecToken err
  TargetPrepareFieldRejected reason -> "target-prepare-invalid-field:" <> reason
