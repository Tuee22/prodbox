{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.50: the server side of the Authority Backup role's @copy@ and
-- @observe@ routes.
--
-- The pure backup-repair algebra ('Prodbox.Lifecycle.Authority.BackupRepair')
-- already decides whether a backup-health reading freezes admission, mints the
-- one-time repair permit, records a repair read-back, or reopens admission under a
-- strictly greater epoch. This endpoint fronts that decision: @copy@ reads the
-- current admission state through an injected repository, drives
-- 'decideBackupRepair', folds the decision's events into the next state, and
-- commits it only when it changed; @observe@ returns the current admission state.
--
-- It is pure over the injected repository, so an in-memory fixture exercises every
-- arm without a live cluster or object store. The bounded canonical wire codec and
-- the real retained-store compare-and-swap are the live-coupled follow-ons.
module Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupRepository (..)
  , AuthorityBackupEndpointResult (..)
  , serveBackupCopy
  , serveBackupCopyRequest
  , serveBackupObserve
  , authorityBackupHttpStatus
  , authorityBackupSummary
  , authorityBackupObserveStatus
  , authorityBackupObserveSummary
  )
where

import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  )
import Prodbox.Lifecycle.Authority.BackupRepair
  ( BackupRepairCommand
  , BackupRepairDecision
    ( BackupRepairFroze
    , BackupRepairNotNeeded
    , BackupRepairPermitAlreadyMinted
    , BackupRepairPermitMinted
    , BackupRepairRecordProgress
    , BackupRepairRefused
    , BackupRepairReopen
    , BackupRepairWait
    )
  , BackupRepairRefusal
    ( BackupRepairBeforeGenesis
    , BackupRepairNotFrozen
    , BackupRepairPermitAbsent
    , BackupRepairPermitMismatch
    )
  , backupRepairDecisionEvents
  , decideBackupRepair
  , evolveBackupRepair
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState
      ( BackupEstablished
      , BackupRepairFrozen
      , EstablishingBackup
      , GenesisFrozen
      )
  )

-- | The retained admission state store: read the current state and compare-and-swap
-- an evolved one.
data AuthorityBackupRepository m = AuthorityBackupRepository
  { readAdmissionState :: m AuthorityAdmissionState
  , commitAdmissionState :: AuthorityAdmissionState -> m (Either Text ())
  }

data AuthorityBackupEndpointResult
  = AuthorityBackupDecided !BackupRepairDecision
  | -- | A state advance was decided but its durable commit failed (retry).
    AuthorityBackupWriteFailed !Text
  | -- | The request body was not a bounded, canonical, supported-version backup
    -- command; no state was read or written.
    AuthorityBackupBadRequest !ControlPlaneRequestCodecError
  deriving (Eq, Show)

-- | Serve a backup @copy@ command: decide, fold the decision's events into the
-- next admission state, and commit only a genuine advance.
serveBackupCopy
  :: (Monad m)
  => AuthorityBackupRepository m
  -> BackupRepairCommand
  -> m AuthorityBackupEndpointResult
serveBackupCopy repository command = do
  state <- readAdmissionState repository
  let decision = decideBackupRepair state command
      next = foldl' evolveBackupRepair state (backupRepairDecisionEvents decision)
  if next == state
    then pure (AuthorityBackupDecided decision)
    else do
      committed <- commitAdmissionState repository next
      pure $ case committed of
        Left detail -> AuthorityBackupWriteFailed detail
        Right () -> AuthorityBackupDecided decision

-- | Serve a backup @copy@ request from a raw body: decode the bounded, canonical
-- 'BackupRepairCommand' and, only for a well-formed command, run 'serveBackupCopy'.
-- A malformed body is refused ('AuthorityBackupBadRequest') before any state is
-- read. @maximumBytes@ bounds the request framing. This is the through-seam entry a
-- production 'RoleInterpreter' dispatches the raw socket body to; it stays pure over
-- the injected repository.
serveBackupCopyRequest
  :: (Monad m)
  => Int
  -> AuthorityBackupRepository m
  -> ByteString
  -> m AuthorityBackupEndpointResult
serveBackupCopyRequest maximumBytes repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (AuthorityBackupBadRequest err)
    Right command -> serveBackupCopy repository command

-- | Serve a backup @observe@: the current admission state, no mutation.
serveBackupObserve :: (Monad m) => AuthorityBackupRepository m -> m AuthorityAdmissionState
serveBackupObserve = readAdmissionState

-- | Total HTTP status for an @observe@ read. A read never fails at this layer (an
-- unreadable retained store surfaces earlier as a repository error, not here), so
-- the observed admission state is always @200@.
authorityBackupObserveStatus :: AuthorityAdmissionState -> Int
authorityBackupObserveStatus _ = 200

-- | Stable single-line summary naming the observed admission phase, so a caller can
-- distinguish genesis-frozen, mid-establishment, established, and repair-frozen
-- admission without parsing the full retained state. Exhaustive over
-- 'AuthorityAdmissionState'.
authorityBackupObserveSummary :: AuthorityAdmissionState -> Text
authorityBackupObserveSummary state = case state of
  GenesisFrozen -> "backup-observe:genesis-frozen"
  EstablishingBackup _ -> "backup-observe:establishing"
  BackupEstablished _ -> "backup-observe:established"
  BackupRepairFrozen _ _ -> "backup-observe:repair-frozen"

-- | Total HTTP status projection. Every accepted transition (froze, permit minted,
-- progress recorded, reopened, wait, not-needed, idempotent already-minted) is
-- @200@; a refused command is @409@; a failed durable commit is @503@.
authorityBackupHttpStatus :: AuthorityBackupEndpointResult -> Int
authorityBackupHttpStatus result = case result of
  AuthorityBackupBadRequest _ -> 400
  AuthorityBackupWriteFailed _ -> 503
  AuthorityBackupDecided decision -> case decision of
    BackupRepairRefused _ -> 409
    BackupRepairNotNeeded -> 200
    BackupRepairFroze _ -> 200
    BackupRepairWait -> 200
    BackupRepairPermitMinted _ -> 200
    BackupRepairPermitAlreadyMinted -> 200
    BackupRepairRecordProgress _ -> 200
    BackupRepairReopen _ _ -> 200

authorityBackupSummary :: AuthorityBackupEndpointResult -> Text
authorityBackupSummary result = case result of
  AuthorityBackupBadRequest err -> "backup-bad-request:" <> controlPlaneRequestCodecToken err
  AuthorityBackupWriteFailed _ -> "backup-write-failed"
  AuthorityBackupDecided decision -> case decision of
    BackupRepairRefused refusal -> "backup-refused:" <> refusalToken refusal
    BackupRepairNotNeeded -> "backup-not-needed"
    BackupRepairFroze _ -> "backup-froze"
    BackupRepairWait -> "backup-wait"
    BackupRepairPermitMinted _ -> "backup-permit-minted"
    BackupRepairPermitAlreadyMinted -> "backup-permit-already-minted"
    BackupRepairRecordProgress _ -> "backup-progress-recorded"
    BackupRepairReopen _ _ -> "backup-reopened"

refusalToken :: BackupRepairRefusal -> Text
refusalToken refusal = case refusal of
  BackupRepairBeforeGenesis -> "before-genesis"
  BackupRepairNotFrozen -> "not-frozen"
  BackupRepairPermitAbsent -> "permit-absent"
  BackupRepairPermitMismatch -> "permit-mismatch"
