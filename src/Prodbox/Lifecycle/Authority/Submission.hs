{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Sprint 4.48: the retained Lifecycle Authority's idempotent operation-
-- submission front-door.
--
-- Submission is separate from execution. A caller submits an operation with a
-- stable @(client, client-sequence, request digest)@ identity; the authority
-- binds an 'OperationId' to that identity plus the admitting 'AuthorityEpoch',
-- and returns it. Resubmitting the exact same identity is idempotent — it returns
-- the SAME 'OperationId' and the operation's current status — so a lost response
-- converges by re-submission (by ID) rather than becoming a second operation. A
-- client disconnect never determines an operation's outcome: cancellation is an
-- explicit command, and there is no disconnect input to this fold.
--
-- The ledger keeps, per client, a monotone sequence floor plus a bounded set of
-- in-flight (nonterminal) and settled (terminal tombstone) records for a
-- configured idempotency window. A submission at or below the compacted floor is
-- 'SubmissionRefusedExpired' — an old id is never silently treated as new. When
-- the live (in-flight) population is at capacity a new submission is
-- 'SubmissionRefusedFull'. Reusing a sequence with a DIFFERENT digest is
-- 'SubmissionRefusedSequenceReused'.
--
-- This module is pure and standalone (like @Prodbox.Lifecycle.Authority.Operation@):
-- the interpreter drives it and separately journals the bound operation's intent
-- and result.
module Prodbox.Lifecycle.Authority.Submission
  ( -- * Identities
    ClientId (..)
  , ClientSequence (..)
  , RequestDigest (..)
  , requestDigestText
  , OperationId (..)

    -- * Ledger
  , SubmissionRecord (..)
  , TerminalOutcome (..)
  , ClientSubmissions (..)
  , SubmissionLedger (..)
  , emptySubmissionLedger
  , liveSubmissionCount

    -- * Submission
  , SubmitDecision (..)
  , decideSubmit
  , applySubmit
  , stepSubmit

    -- * Terminal transitions and compaction
  , SubmissionTransitionRefusal (..)
  , cancelSubmission
  , completeSubmission
  , compactClientTerminalsBelow

    -- * Status
  , SubmissionStatus (..)
  , submissionStatus
  )
where

import Codec.Serialise (Serialise)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.Authority.Genesis (AuthorityEpoch)

-- | The durable client identity that owns a monotone submission sequence.
newtype ClientId = ClientId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | A client's monotone per-submission sequence number.
newtype ClientSequence = ClientSequence Natural
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | A digest over the exact request payload; distinguishes an idempotent
-- resubmission from a sequence reused for a different request.
newtype RequestDigest = RequestDigest Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

requestDigestText :: RequestDigest -> Text
requestDigestText (RequestDigest value) = value

-- | The identity bound at submission: the admitting epoch plus the caller's
-- @(client, sequence, digest)@. Epoch-scoped so a post-failover authority under a
-- greater epoch mints distinct ids.
data OperationId = OperationId
  { operationIdEpoch :: !AuthorityEpoch
  , operationIdClient :: !ClientId
  , operationIdSequence :: !ClientSequence
  , operationIdDigest :: !RequestDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Whether a settled submission completed or was cancelled.
data TerminalOutcome
  = OperationCompletedOutcome
  | OperationCancelledOutcome
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | A per-sequence submission record: in-flight (nonterminal) or settled
-- (terminal tombstone). Each retains its request digest for idempotent match.
data SubmissionRecord
  = SubmissionInFlight !RequestDigest
  | SubmissionSettled !RequestDigest !TerminalOutcome
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | One client's submissions: the compacted sequence floor (sequences at or below
-- it are expired) plus the retained window of records above it.
data ClientSubmissions = ClientSubmissions
  { clientSequenceFloor :: !ClientSequence
  , clientRecords :: !(Map ClientSequence SubmissionRecord)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The whole submission ledger: a live-population capacity plus per-client
-- submissions.
data SubmissionLedger = SubmissionLedger
  { submissionCapacity :: !Natural
  , submissionClients :: !(Map ClientId ClientSubmissions)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | A fresh ledger with the given live-population capacity and no clients.
emptySubmissionLedger :: Natural -> SubmissionLedger
emptySubmissionLedger capacity = SubmissionLedger capacity Map.empty

-- | The number of in-flight (nonterminal) submissions across all clients.
liveSubmissionCount :: SubmissionLedger -> Natural
liveSubmissionCount ledger =
  fromIntegral $
    sum
      [ length [() | SubmissionInFlight _ <- Map.elems (clientRecords subs)]
      | subs <- Map.elems (submissionClients ledger)
      ]

-- | An empty per-client record set at the zero floor.
emptyClientSubmissions :: ClientSubmissions
emptyClientSubmissions = ClientSubmissions (ClientSequence 0) Map.empty

data SubmitDecision
  = -- | A new operation; the bound id is durably recorded and returned.
    SubmissionAccepted !OperationId
  | -- | The exact same identity is already known (idempotent); the SAME id is
    -- returned. Query 'submissionStatus' for its current phase.
    SubmissionDuplicate !OperationId
  | -- | The live population is at capacity.
    SubmissionRefusedFull
  | -- | The sequence exists with a DIFFERENT request digest.
    SubmissionRefusedSequenceReused
  | -- | The sequence is at or below the compacted floor (an old id, not new).
    SubmissionRefusedExpired
  deriving (Eq, Show)

-- | Decide a submission. Pure; never mutates the ledger. An exact
-- @(client, sequence, digest)@ match is an idempotent 'SubmissionDuplicate'; a
-- reused sequence with a different digest is refused; a sequence at or below the
-- compacted floor is expired; otherwise a fresh submission is accepted unless the
-- live population is at capacity.
decideSubmit
  :: AuthorityEpoch
  -> SubmissionLedger
  -> ClientId
  -> ClientSequence
  -> RequestDigest
  -> SubmitDecision
decideSubmit epoch ledger client seqNo digest =
  case Map.lookup client (submissionClients ledger) of
    Nothing -> acceptFresh (clientSequenceFloor emptyClientSubmissions)
    Just subs -> case Map.lookup seqNo (clientRecords subs) of
      Just (SubmissionInFlight existing) -> matchOrReuse existing
      Just (SubmissionSettled existing _) -> matchOrReuse existing
      Nothing -> acceptFresh (clientSequenceFloor subs)
 where
  boundId = OperationId epoch client seqNo digest
  matchOrReuse existing
    | existing == digest = SubmissionDuplicate boundId
    | otherwise = SubmissionRefusedSequenceReused
  acceptFresh currentFloor
    | seqNo <= currentFloor = SubmissionRefusedExpired
    | liveSubmissionCount ledger >= submissionCapacity ledger = SubmissionRefusedFull
    | otherwise = SubmissionAccepted boundId

-- | Record an accepted submission as in-flight. A no-op for any decision other
-- than 'SubmissionAccepted' (duplicates and refusals never mutate the ledger).
applySubmit :: SubmitDecision -> SubmissionLedger -> SubmissionLedger
applySubmit decision ledger = case decision of
  SubmissionAccepted opId ->
    insertRecord
      (operationIdClient opId)
      (operationIdSequence opId)
      (SubmissionInFlight (operationIdDigest opId))
      ledger
  SubmissionDuplicate _ -> ledger
  SubmissionRefusedFull -> ledger
  SubmissionRefusedSequenceReused -> ledger
  SubmissionRefusedExpired -> ledger

-- | 'decideSubmit' then apply, returning the decision and the evolved ledger.
stepSubmit
  :: AuthorityEpoch
  -> SubmissionLedger
  -> ClientId
  -> ClientSequence
  -> RequestDigest
  -> (SubmitDecision, SubmissionLedger)
stepSubmit epoch ledger client seqNo digest =
  let decision = decideSubmit epoch ledger client seqNo digest
   in (decision, applySubmit decision ledger)

insertRecord
  :: ClientId -> ClientSequence -> SubmissionRecord -> SubmissionLedger -> SubmissionLedger
insertRecord client seqNo record ledger =
  ledger
    { submissionClients =
        Map.alter
          ( \existing ->
              let subs = maybe emptyClientSubmissions id existing
               in Just subs {clientRecords = Map.insert seqNo record (clientRecords subs)}
          )
          client
          (submissionClients ledger)
    }

data SubmissionTransitionRefusal
  = -- | No such @(client, sequence)@ submission is known.
    SubmissionUnknown
  | -- | Cancelling an already-completed submission.
    SubmissionCancelAfterComplete
  | -- | Completing an already-cancelled submission.
    SubmissionCompleteAfterCancel
  | -- | Compacting across an in-flight (nonterminal) submission.
    SubmissionCompactAcrossInFlight
  deriving (Eq, Show)

-- | Settle an in-flight submission as cancelled. Idempotent on an already-
-- cancelled submission; refuses to cancel a completed one or an unknown one. (A
-- client disconnect never invokes this — cancellation is an explicit command.)
cancelSubmission
  :: ClientId
  -> ClientSequence
  -> SubmissionLedger
  -> Either SubmissionTransitionRefusal SubmissionLedger
cancelSubmission = settleSubmission OperationCancelledOutcome SubmissionCancelAfterComplete

-- | Settle an in-flight submission as completed. Idempotent on an already-
-- completed submission; refuses to complete a cancelled one or an unknown one.
completeSubmission
  :: ClientId
  -> ClientSequence
  -> SubmissionLedger
  -> Either SubmissionTransitionRefusal SubmissionLedger
completeSubmission = settleSubmission OperationCompletedOutcome SubmissionCompleteAfterCancel

settleSubmission
  :: TerminalOutcome
  -> SubmissionTransitionRefusal
  -> ClientId
  -> ClientSequence
  -> SubmissionLedger
  -> Either SubmissionTransitionRefusal SubmissionLedger
settleSubmission outcome conflictRefusal client seqNo ledger =
  case Map.lookup client (submissionClients ledger) >>= Map.lookup seqNo . clientRecords of
    Nothing -> Left SubmissionUnknown
    Just (SubmissionInFlight digest) ->
      Right (insertRecord client seqNo (SubmissionSettled digest outcome) ledger)
    Just (SubmissionSettled _ existing)
      | existing == outcome -> Right ledger
      | otherwise -> Left conflictRefusal

-- | Advance a client's sequence floor to @seqNo@, dropping settled records at or
-- below it. Refuses if any in-flight (nonterminal) record sits at or below the
-- new floor — a nonterminal submission must settle before it can be compacted.
compactClientTerminalsBelow
  :: ClientId
  -> ClientSequence
  -> SubmissionLedger
  -> Either SubmissionTransitionRefusal SubmissionLedger
compactClientTerminalsBelow client seqNo ledger =
  case Map.lookup client (submissionClients ledger) of
    Nothing -> Right ledger
    Just subs
      | any inFlightAtOrBelow (Map.toList (clientRecords subs)) ->
          Left SubmissionCompactAcrossInFlight
      | otherwise ->
          Right
            ledger
              { submissionClients =
                  Map.insert
                    client
                    ClientSubmissions
                      { clientSequenceFloor = max (clientSequenceFloor subs) seqNo
                      , clientRecords = Map.filterWithKey (\k _ -> k > seqNo) (clientRecords subs)
                      }
                    (submissionClients ledger)
              }
 where
  inFlightAtOrBelow (k, SubmissionInFlight _) = k <= seqNo
  inFlightAtOrBelow (_, SubmissionSettled {}) = False

-- | The status of a @(client, sequence)@ submission.
data SubmissionStatus
  = StatusInFlight
  | StatusSettled !TerminalOutcome
  | -- | At or below the compacted floor (previously known, now expired).
    StatusExpired
  | -- | Never seen for this client above the floor.
    StatusUnknown
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Look up a submission's status without mutating the ledger.
submissionStatus :: ClientId -> ClientSequence -> SubmissionLedger -> SubmissionStatus
submissionStatus client seqNo ledger =
  case Map.lookup client (submissionClients ledger) of
    Nothing -> StatusUnknown
    Just subs -> case Map.lookup seqNo (clientRecords subs) of
      Just (SubmissionInFlight _) -> StatusInFlight
      Just (SubmissionSettled _ outcome) -> StatusSettled outcome
      Nothing
        | seqNo <= clientSequenceFloor subs -> StatusExpired
        | otherwise -> StatusUnknown
