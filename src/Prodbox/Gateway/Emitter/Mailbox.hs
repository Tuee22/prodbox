{-# LANGUAGE DerivingStrategies #-}

-- | Sprint 2.32 (increment 1): the bounded typed mailbox that fronts the
-- single-writer emitter actor.
--
-- Every request a peer, the ownership loop, or the recovery path wants the
-- emitter to act on enters through this one FIFO. The mailbox is
-- capacity-bounded, so a saturated emitter refuses new work immediately with a
-- retry hint rather than growing memory without limit — the counterexample
-- @LCPC-2026-07-11@ class where unbounded request/rejection materialization
-- pinned the gateway CPU.
--
-- Coalescing is deliberately asymmetric: a fresh heartbeat SUPERSEDES a pending
-- heartbeat (only the latest freshness observation matters, so the queue holds
-- at most one heartbeat and a heartbeat can never fill the mailbox), while
-- ownership transitions, the internally-decided epoch rotation, and recovery are
-- NEVER coalesced or reordered relative to one another — dropping or reordering
-- an ownership claim/yield would violate the DNS-write ordering the gateway
-- depends on. The coalesced heartbeat keeps the position of the oldest pending
-- heartbeat, so it can never jump ahead of an ownership request that arrived
-- after it.
--
-- The module is pure and total: no clock read, no @IO@. The overload
-- 'RetryAfter' hint is carried by the mailbox so 'enqueue' stays clock-free.
module Prodbox.Gateway.Emitter.Mailbox
  ( -- * Capacity
    MailboxCapacity
  , mkMailboxCapacity
  , mailboxCapacityValue

    -- * Requests
  , OwnershipTransition (..)
  , HeartbeatPayload (..)
  , EmitterRequest (..)
  , requestCoalescible

    -- * The mailbox
  , Mailbox
  , emptyMailbox
  , mailboxDepth
  , mailboxRequests
  , mailboxPendingHeartbeat

    -- * Operations
  , EnqueueOutcome (..)
  , enqueue
  , dequeue
  )
where

import Data.Word (Word64)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Deadline (RetryAfter (..))

-- | A positive mailbox capacity. Ctor unexported so a mailbox is never built
-- with a zero (deadlock) or nonsensical bound.
newtype MailboxCapacity = MailboxCapacity Natural
  deriving stock (Eq, Ord, Show)

-- | Build a capacity, rejecting zero.
mkMailboxCapacity :: Natural -> Maybe MailboxCapacity
mkMailboxCapacity value
  | value >= 1 = Just (MailboxCapacity value)
  | otherwise = Nothing

mailboxCapacityValue :: MailboxCapacity -> Natural
mailboxCapacityValue (MailboxCapacity value) = value

-- | The two ownership transitions the emitter can be asked to publish. Both are
-- durable, sequence-advancing continuity transitions and are never coalesced.
data OwnershipTransition
  = OwnershipClaim
  | OwnershipYield
  deriving stock (Eq, Ord, Show)

-- | A heartbeat request carries the monotonic observation time (micros) so the
-- coalesced representative is the freshest one; the value is otherwise opaque to
-- the mailbox.
newtype HeartbeatPayload = HeartbeatPayload
  { heartbeatObservedMicros :: Word64
  }
  deriving stock (Eq, Ord, Show)

-- | A request submitted to the emitter actor.
--
-- 'ReqEpochRotation' exists only so an external caller CAN name it; the actor
-- treats it as a no-op because epoch rotation is decided internally at the
-- sign boundary, never by an external message (Sprint 2.32 adversarial
-- correction 2). It is listed here as non-coalescible for completeness.
data EmitterRequest
  = ReqHeartbeat !HeartbeatPayload
  | ReqOwnership !OwnershipTransition
  | ReqEpochRotation
  | ReqRecover
  deriving stock (Eq, Ord, Show)

-- | Only heartbeats coalesce.
requestCoalescible :: EmitterRequest -> Bool
requestCoalescible (ReqHeartbeat _) = True
requestCoalescible _ = False

-- | A bounded FIFO with at most one pending heartbeat. The head of
-- 'mailboxQueue' is the next request 'dequeue' returns.
data Mailbox = Mailbox
  { mailboxCapacity :: !MailboxCapacity
  , mailboxBackoff :: !RetryAfter
  , mailboxQueue :: ![EmitterRequest]
  }
  deriving stock (Eq, Show)

-- | An empty mailbox with the given capacity and overload retry hint.
emptyMailbox :: MailboxCapacity -> RetryAfter -> Mailbox
emptyMailbox capacity backoff =
  Mailbox
    { mailboxCapacity = capacity
    , mailboxBackoff = backoff
    , mailboxQueue = []
    }

mailboxDepth :: Mailbox -> Natural
mailboxDepth = fromIntegral . length . mailboxQueue

mailboxRequests :: Mailbox -> [EmitterRequest]
mailboxRequests = mailboxQueue

-- | The single pending heartbeat, if any (there is never more than one).
mailboxPendingHeartbeat :: Mailbox -> Maybe HeartbeatPayload
mailboxPendingHeartbeat mailbox =
  case [payload | ReqHeartbeat payload <- mailboxQueue mailbox] of
    (payload : _) -> Just payload
    [] -> Nothing

data EnqueueOutcome
  = -- | Appended; the depth grew by one.
    EnqueueAccepted !Mailbox
  | -- | A pending heartbeat was replaced in place; the depth is unchanged.
    EnqueueCoalesced !Mailbox
  | -- | The mailbox is full and the request cannot coalesce; nothing changed.
    EnqueueRejected !RetryAfter
  deriving stock (Eq, Show)

-- | Enqueue a request.
--
--   * A heartbeat replaces any pending heartbeat in place ('EnqueueCoalesced')
--     — bounded regardless of heartbeat rate. With no pending heartbeat it
--     appends if there is room, else it is rejected (a heartbeat never evicts
--     durable work).
--   * A non-coalescible request appends if there is room, else it is rejected
--     with the mailbox's backoff hint.
enqueue :: Mailbox -> EmitterRequest -> EnqueueOutcome
enqueue mailbox request
  | requestCoalescible request =
      case break requestCoalescible queue of
        (before, _existing : after) ->
          EnqueueCoalesced mailbox {mailboxQueue = before ++ request : after}
        (_, []) -> appendIfRoom
  | otherwise = appendIfRoom
 where
  queue = mailboxQueue mailbox
  appendIfRoom
    | mailboxDepth mailbox >= mailboxCapacityValue (mailboxCapacity mailbox) =
        EnqueueRejected (mailboxBackoff mailbox)
    | otherwise = EnqueueAccepted mailbox {mailboxQueue = queue ++ [request]}

-- | Remove and return the next request, or 'Nothing' when empty.
dequeue :: Mailbox -> Maybe (EmitterRequest, Mailbox)
dequeue mailbox =
  case mailboxQueue mailbox of
    [] -> Nothing
    (request : rest) -> Just (request, mailbox {mailboxQueue = rest})
