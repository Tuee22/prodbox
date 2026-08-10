{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.50: the server side of the Lifecycle Authority @migration/apply@
-- route.  Where 'Prodbox.ControlPlane.Interpreter' is the client-side capability
-- boundary that /calls/ an authority, this module is the endpoint an authority
-- role /serves/: it receives a bounded, canonically framed 'MigrationCommand'
-- request body, applies it through the exact-revision retained
-- 'MigrationRepository', and projects the outcome onto a total HTTP status and a
-- stable diagnostic summary.
--
-- It is pure over an injected repository, so an in-memory fixture exercises every
-- request/response arm without a live cluster, Vault, or object store. Binding a
-- production retained repository and dispatching the raw socket request to this
-- handler is the following increment; this increment fixes the request framing
-- and the response projection.
module Prodbox.ControlPlane.MigrationEndpoint
  ( MigrationEndpointResult (..)
  , serveMigrationApply
  , serveAuthorityMigrationApply
  , migrationEndpointHttpStatus
  , migrationEndpointSummary
  )
where

import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (authorityAdmissionSnapshotState)
  , AuthorityTransitionResult (..)
  , serveAuthorityTransition
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionCommand (ApplyAuthorityMigration)
  , AuthorityAdmissionCommandRefusal
  , AuthorityAdmissionDecision (..)
  , AuthorityMigrationMode (..)
  , authorityAggregateMigration
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationCodecError (..)
  , MigrationDecision (..)
  , MigrationRefusal (..)
  , decodeMigrationCommand
  )
import Prodbox.Lifecycle.Authority.MigrationInterpreter
  ( MigrationApplyError (..)
  , MigrationApplyResult (..)
  , MigrationRepository
  , applyMigrationCommand
  )

-- | The closed outcome of serving one migration-apply request.  A malformed
-- request body ('MigrationEndpointBadRequest') is distinct from a well-formed
-- command the state machine refuses (carried inside
-- 'MigrationEndpointApplied' as a 'MigrationRefused' decision), which is in turn
-- distinct from an authority-side durable failure (read/decode/write/concurrent).
data MigrationEndpointResult
  = -- | The request body was not a bounded, canonical, supported-version
    -- migration command.  No state was read or written.
    MigrationEndpointBadRequest !MigrationCodecError
  | -- | The command was applied through the retained repository; the enclosed
    -- result carries the resulting state and the accept/already-applied/refuse
    -- decision.
    MigrationEndpointApplied !MigrationApplyResult
  | -- | The retained migration state could not be observed (fail-closed, never
    -- treated as absent).
    MigrationEndpointReadFailed !Text
  | -- | The retained migration state was corrupt at decode.
    MigrationEndpointDecodeFailed !MigrationCodecError
  | -- | The accepted transition could not be durably written.
    MigrationEndpointWriteFailed !Text
  | -- | A concurrent writer won the compare-and-swap; the caller must re-observe
    -- and retry.
    MigrationEndpointConcurrentWrite
  | -- | The aggregate-level genesis, repair, or migration gate refused this
    -- otherwise well-formed command.
    MigrationEndpointAdmissionRefused !AuthorityAdmissionCommandRefusal
  | -- | The aggregate transition could not be projected onto a
    -- migration-controlled retained state.
    MigrationEndpointAggregateMismatch
  deriving stock (Eq, Show)

-- | Serve one migration-apply request against an injected retained repository.
-- @maximumBytes@ bounds both the request-command framing and the retained-state
-- framing.
serveMigrationApply
  :: (Monad m)
  => Int
  -> MigrationRepository m revision
  -> ByteString
  -> m MigrationEndpointResult
serveMigrationApply maximumBytes repository body =
  case decodeMigrationCommand maximumBytes body of
    Left err -> pure (MigrationEndpointBadRequest err)
    Right command -> do
      outcome <- applyMigrationCommand maximumBytes repository command
      pure $ case outcome of
        Right applied -> MigrationEndpointApplied applied
        Left (MigrationReadFailed detail) -> MigrationEndpointReadFailed detail
        Left (MigrationDecodeFailed err) -> MigrationEndpointDecodeFailed err
        Left (MigrationWriteFailed detail) -> MigrationEndpointWriteFailed detail
        Left MigrationConcurrentWrite -> MigrationEndpointConcurrentWrite

-- | Apply through the same exact-revision aggregate that gates and appends
-- submissions.  Successful transitions are re-observed and projected back to
-- the legacy endpoint result; a clean-install or unrelated decision at that
-- point is an Authority invariant failure.
serveAuthorityMigrationApply
  :: (Monad m)
  => Int
  -> AuthorityAdmissionRepository m revision
  -> ByteString
  -> m MigrationEndpointResult
serveAuthorityMigrationApply maximumBytes repository body =
  case decodeMigrationCommand maximumBytes body of
    Left err -> pure (MigrationEndpointBadRequest err)
    Right command -> do
      transitioned <-
        serveAuthorityTransition repository (ApplyAuthorityMigration command)
      case transitioned of
        AuthorityTransitionBadRequest _ -> pure MigrationEndpointAggregateMismatch
        AuthorityTransitionReadFailed detail -> pure (MigrationEndpointReadFailed detail)
        AuthorityTransitionWriteFailed detail -> pure (MigrationEndpointWriteFailed detail)
        AuthorityTransitionDecided decision -> case decision of
          AuthorityAdmissionCommandRefused refusal ->
            pure (MigrationEndpointAdmissionRefused refusal)
          AuthorityMigrationDecided migrationDecision -> do
            observed <- readAuthorityAdmission repository
            pure $ case observed of
              Left detail -> MigrationEndpointReadFailed detail
              Right snapshot ->
                case authorityAggregateMigration (authorityAdmissionSnapshotState snapshot) of
                  AuthorityMigrationControlled state ->
                    MigrationEndpointApplied
                      MigrationApplyResult
                        { appliedMigrationState = state
                        , appliedMigrationDecision = migrationDecision
                        }
                  AuthorityCleanInstall -> MigrationEndpointAggregateMismatch
          _ -> pure MigrationEndpointAggregateMismatch

-- | Total projection onto an HTTP status code.  A refused-but-well-formed
-- command and a lost CAS race are both @409 Conflict@ (retry after re-observing);
-- an unobservable read or a failed write is @503@ (transient, no state change); a
-- corrupt durable decode is @500@ (authority-side invariant break); a malformed
-- request is @400@.
migrationEndpointHttpStatus :: MigrationEndpointResult -> ReplyStatus
migrationEndpointHttpStatus result = case result of
  MigrationEndpointBadRequest _ -> ReplyBadRequest
  MigrationEndpointApplied applied -> case appliedMigrationDecision applied of
    MigrationAccepted _ -> ReplyOk
    MigrationAlreadyApplied -> ReplyOk
    MigrationRefused _ -> ReplyConflict
  MigrationEndpointReadFailed _ -> ReplyServiceUnavailable
  MigrationEndpointDecodeFailed _ -> ReplyInternalError
  MigrationEndpointWriteFailed _ -> ReplyServiceUnavailable
  MigrationEndpointConcurrentWrite -> ReplyConflict
  MigrationEndpointAdmissionRefused _ -> ReplyConflict
  MigrationEndpointAggregateMismatch -> ReplyInternalError

-- | Stable single-line diagnostic body.  Kebab-case tokens keep the response
-- machine-greppable without serialising the hidden migration events.
migrationEndpointSummary :: MigrationEndpointResult -> Text
migrationEndpointSummary result = case result of
  MigrationEndpointBadRequest err -> "migration-bad-request:" <> codecToken err
  MigrationEndpointApplied applied -> case appliedMigrationDecision applied of
    MigrationAccepted _ -> "migration-accepted"
    MigrationAlreadyApplied -> "migration-already-applied"
    MigrationRefused refusal -> "migration-refused:" <> refusalToken refusal
  MigrationEndpointReadFailed _ -> "migration-read-failed"
  MigrationEndpointDecodeFailed err -> "migration-state-corrupt:" <> codecToken err
  MigrationEndpointWriteFailed _ -> "migration-write-failed"
  MigrationEndpointConcurrentWrite -> "migration-concurrent-write"
  MigrationEndpointAdmissionRefused _ -> "migration-admission-refused"
  MigrationEndpointAggregateMismatch -> "migration-aggregate-mismatch"

codecToken :: MigrationCodecError -> Text
codecToken err = case err of
  MigrationEnvelopeTooLarge -> "too-large"
  MigrationEnvelopeInvalid -> "invalid"
  MigrationEnvelopeUnsupportedVersion -> "unsupported-version"
  MigrationEnvelopeNonCanonical -> "non-canonical"

refusalToken :: MigrationRefusal -> Text
refusalToken refusal = case refusal of
  ShadowDigestConflict -> "shadow-digest-conflict"
  FreezeBeforeShadowVerification -> "freeze-before-shadow-verification"
  FreezeDigestConflict -> "freeze-digest-conflict"
  PrepareBeforeFreeze -> "prepare-before-freeze"
  ActivationBeforeFreeze -> "activation-before-freeze"
  ActivationBindingsMissing _ -> "activation-bindings-missing"
  EpochMustAdvance -> "epoch-must-advance"
  LegacyRollbackForbidden -> "legacy-rollback-forbidden"
