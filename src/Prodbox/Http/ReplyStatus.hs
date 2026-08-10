{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.65: the closed set of HTTP statuses the control-plane role servers
-- put on the wire, and the only place a status code and its reason phrase are
-- related.
--
-- The defect this closes was live rather than latent. @httpReasonPhrase@ in
-- "Prodbox.ControlPlane.Server" mapped six codes and ended @_ -> "Status"@,
-- while the interpreters emit ten. Four of them — @401@, @403@, @408@, @410@ —
-- fell through, so the control plane was writing status lines reading
-- @HTTP\/1.1 403 Status@. That is the /Totality/ class of
-- [chaos_hardening_doctrine.md § 21](../../../documents/engineering/chaos_hardening_doctrine.md)
-- over a raw 'Int'.
--
-- Two design points are decisions rather than defaults:
--
--   * __'replyStatusFromCode' is derived from 'replyStatusCode', not written
--     out.__ A hand-written inverse is a second table, and a second table is a
--     restatement that a change makes wrong rather than updates
--     ([§ 23](../../../documents/engineering/chaos_hardening_doctrine.md)). The
--     two cannot disagree because there is only one.
--   * __Both projections are total with no wildcard arm.__ Adding a
--     constructor is a @-Werror@ compile error at each, which is what makes the
--     set closed rather than merely enumerated.
--
-- __Where this type is, and is not, in force (Sprint 4.67).__ Every producer
-- answers 'ReplyStatus': @interpreterHandle@, @serveControlPlaneRequest@,
-- @renderHttpResponse@, and 56 status projections across 34 files. A producer
-- can no longer state a status the closed set does not define, so what Sprint
-- 4.66 achieved with a @dev check@ text rule is now a property of the type.
--
-- Two crossings still carry a number, and both are deliberate rather than
-- unfinished ([§ 22](../../../documents/engineering/chaos_hardening_doctrine.md)
-- — a ring-2 gate bounds a process, not a protocol):
--
--   * __A peer's status.__ @ControlPlaneResponse@ carries the @Int@ a server
--     actually sent. No type here bounds what an intermediary may answer, and
--     pretending otherwise would turn a @502@ from a proxy into a decode
--     failure naming nothing.
--   * __A stored status.__ The retained replay projection persists the numeric
--     code, so a projection written before this sprint still decodes.
--     'replyStatusFromCode' is the sole admission point and it refuses rather
--     than widens.
module Prodbox.Http.ReplyStatus
  ( ReplyStatus (..)
  , allReplyStatuses
  , replyStatusCode
  , replyStatusReason
  , replyStatusFromCode
  , reasonPhraseForCode
  , unmappedReasonPhrase
  )
where

import Data.ByteString (ByteString)

-- | Every status a control-plane role server emits.
--
-- Derived from a census of the producers rather than from the HTTP
-- specification: a status is here because something in this repository returns
-- it, and the @dev check@ rule keeps that correspondence exact in both
-- directions.
data ReplyStatus
  = ReplyOk
  | ReplyBadRequest
  | ReplyUnauthorized
  | ReplyForbidden
  | ReplyNotFound
  | ReplyRequestTimeout
  | ReplyConflict
  | ReplyGone
  | ReplyTooManyRequests
  | ReplyInternalError
  | ReplyServiceUnavailable
  deriving stock (Bounded, Enum, Eq, Ord, Show)

allReplyStatuses :: [ReplyStatus]
allReplyStatuses = [minBound .. maxBound]

-- | The numeric code. Total, no wildcard.
replyStatusCode :: ReplyStatus -> Int
replyStatusCode status = case status of
  ReplyOk -> 200
  ReplyBadRequest -> 400
  ReplyUnauthorized -> 401
  ReplyForbidden -> 403
  ReplyNotFound -> 404
  ReplyRequestTimeout -> 408
  ReplyConflict -> 409
  ReplyGone -> 410
  ReplyTooManyRequests -> 429
  ReplyInternalError -> 500
  ReplyServiceUnavailable -> 503

-- | The reason phrase. Total, no wildcard.
replyStatusReason :: ReplyStatus -> ByteString
replyStatusReason status = case status of
  ReplyOk -> "OK"
  ReplyBadRequest -> "Bad Request"
  ReplyUnauthorized -> "Unauthorized"
  ReplyForbidden -> "Forbidden"
  ReplyNotFound -> "Not Found"
  ReplyRequestTimeout -> "Request Timeout"
  ReplyConflict -> "Conflict"
  ReplyGone -> "Gone"
  ReplyTooManyRequests -> "Too Many Requests"
  ReplyInternalError -> "Internal Server Error"
  ReplyServiceUnavailable -> "Service Unavailable"

-- | The sole admission point from a raw code.
--
-- Derived by searching 'allReplyStatuses' through 'replyStatusCode', so it is
-- the inverse of that function by construction rather than by review.
replyStatusFromCode :: Int -> Maybe ReplyStatus
replyStatusFromCode code =
  case [status | status <- allReplyStatuses, replyStatusCode status == code] of
    status : _ -> Just status
    [] -> Nothing

-- | The reason phrase for a raw code, for the one transport seam that still
-- receives one.
reasonPhraseForCode :: Int -> ByteString
reasonPhraseForCode code = maybe unmappedReasonPhrase replyStatusReason (replyStatusFromCode code)

-- | What an undefined status renders as.
--
-- It says what happened instead of pretending, which the superseded @"Status"@
-- did not. It is also unreachable on the governed namespace: the @dev check@
-- rule fails the build if a producer under @src\/Prodbox\/ControlPlane\/@
-- emits a code with no constructor here. Per
-- [§ 22](../../../documents/engineering/chaos_hardening_doctrine.md) that bounds
-- a process and not a protocol — it says nothing about a status reaching this
-- renderer from outside that namespace, which is why the arm exists at all
-- rather than being an @error@.
unmappedReasonPhrase :: ByteString
unmappedReasonPhrase = "Unmapped Status"
