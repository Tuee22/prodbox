{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 4.60: an accepted connection is answered, or the attempt to answer
-- it fails loudly. "Accepted a connection and answered nothing" is not
-- expressible through this seam.
--
-- The defect this removes is a /conversion/, in the sense of
-- [chaos_hardening_doctrine.md § 23](../../../documents/engineering/chaos_hardening_doctrine.md):
-- a handler's typed failure escaped as an exception and became a socket closed
-- with zero bytes, which on the wire is indistinguishable from a network fault.
-- The Bootstrap Broker has mapped a synchronous interpreter failure onto a reply
-- since Sprint @2.33@ (@invokeInterpreter@); this is that guarantee, factored
-- out so the control-plane server and the integration fixture server share one
-- implementation and one @prodbox dev check@ rule.
--
-- Two design points are load-bearing rather than stylistic:
--
--   * __The handler returns @reply@, not @()@.__ A handler that computes no
--     reply does not type-check, so at-most-once delivery is structural rather
--     than guarded by a runtime flag.
--   * __The fallback is a total function of a closed refusal, not a constant.__
--     Production must not put an exception's text on the wire; a fixture server
--     must, because there the detail is the entire deliverable. One helper
--     serves both only because the refusal renderer is a parameter. A constant
--     reply would force the fixture to fork the helper, which is the topology
--     that produced the defect in the first place.
module Prodbox.Http.ResponseObligation
  ( ResponseRefusal (..)
  , ResponseObligation
  , mkResponseObligation
  , withResponseObligation
  , responseWriteBudgetMicrosDefault
  , responseObserveBudgetMicrosDefault
  , renderResponseRefusalReason
  , lastResortInternalError
  )
where

import Control.Exception
  ( SomeAsyncException
  , SomeException
  , evaluate
  , fromException
  , mask
  , throwIO
  , try
  )
import Data.ByteString (ByteString)
import Network.Socket (Socket)
import Network.Socket.ByteString (sendAll)
import System.Timeout (timeout)

-- | Why the handler produced no reply of its own.
--
-- Closed on purpose: a server's refusal renderer is a total function, so adding
-- a refusal kind is a @-Werror@ compile error at every server rather than a new
-- silent bare close.
data ResponseRefusal
  = -- | The handler raised a synchronous exception.
    ResponseHandlerFailed !SomeException
  | -- | The handler was cancelled (an asynchronous exception). The reply is
    -- best-effort and the exception is re-raised regardless.
    ResponseCancelled !SomeException

instance Show ResponseRefusal where
  show refusal = case refusal of
    ResponseHandlerFailed err -> "ResponseHandlerFailed " ++ show err
    ResponseCancelled err -> "ResponseCancelled " ++ show err

-- | How one server turns replies and refusals into wire bytes.
--
-- Opaque, with 'mkResponseObligation' as its only constructor, so
-- 'withResponseObligation' cannot be invoked without a refusal renderer having
-- been supplied. This is the delivery mechanism the required-field rule of
-- [chaos_hardening_doctrine.md § 21](../../../documents/engineering/chaos_hardening_doctrine.md)
-- asks for: not a proof type somebody may pass, but an argument the call does
-- not type-check without.
data ResponseObligation reply = ResponseObligation
  { obligationRender :: reply -> ByteString
  , obligationRefusal :: ResponseRefusal -> reply
  , obligationObserveRefusal :: ResponseRefusal -> IO ()
  , obligationWriteBudgetMicros :: !Int
  }

-- | The default write budget. A reply that cannot be handed to the kernel
-- within this window is abandoned: the peer is gone, or the socket is wedged,
-- and holding the thread helps nobody.
responseWriteBudgetMicrosDefault :: Int
responseWriteBudgetMicrosDefault = 5 * 1000 * 1000

-- | Build an obligation. The budget is clamped rather than refused, because a
-- server that mis-authors it should still answer — this helper's whole purpose
-- is that a mistake here does not become a silent close.
mkResponseObligation
  :: (reply -> ByteString)
  -- ^ Render a reply to wire bytes.
  -> (ResponseRefusal -> reply)
  -- ^ Render a refusal to a reply. Required.
  -> (ResponseRefusal -> IO ())
  -- ^ Observe a refusal server-side. Required, and __positional on purpose__.
  --
  -- Sprint @4.65@. Sprint @4.60@ made the reply obligatory and left the
  -- /reason/ nowhere: production must not put an exception's text on the wire,
  -- so after @4.60@ a `500` was the entire surviving record of any handler
  -- failure — a refusal that does not retain its structured reason, which
  -- [bootstrap_readiness_doctrine.md § 0.5](../../../documents/engineering/bootstrap_readiness_doctrine.md)
  -- forbids.
  --
  -- A record field with a default would have made observation opt-in, and the
  -- defect this closes is precisely that nobody opted in. This is the same
  -- required-argument move the module already makes for the refusal renderer:
  -- an argument the call does not type-check without.
  -> Int
  -- ^ Write budget in microseconds; clamped to a positive value.
  -> ResponseObligation reply
mkResponseObligation render refusal observe budgetMicros =
  ResponseObligation
    { obligationRender = render
    , obligationRefusal = refusal
    , obligationObserveRefusal = observe
    , obligationWriteBudgetMicros =
        if budgetMicros > 0 then budgetMicros else responseWriteBudgetMicrosDefault
    }

-- | The budget the refusal observation runs under.
--
-- Small relative to 'responseWriteBudgetMicrosDefault' and deliberately so: a
-- wedged logger must cost the reply a rounding error, never the reply itself.
responseObserveBudgetMicrosDefault :: Int
responseObserveBudgetMicrosDefault = 250 * 1000

-- | The structured reason an observer records, bounded.
--
-- Sprint @4.65@. Two properties matter and neither is cosmetic.
--
--   * __It is bounded.__ An exception's rendering is attacker-influenced in
--     principle (a decode failure can quote its input), so an unbounded reason
--     is an unbounded write to the pod's log stream from the request path.
--   * __It is truncated, not sanitised, and this is a stated residual.__ No
--     mechanism here can prove an exception's text carries no secret byte. What
--     bounds the exposure is the destination: the reason goes to the process's
--     own stderr, which the wire never sees, and never into a reply. A caller
--     that can produce an exception embedding secret material should not be
--     throwing it — that is the writer's obligation, not this renderer's, and
--     it is recorded rather than implied.
renderResponseRefusalReason :: ResponseRefusal -> String
renderResponseRefusalReason refusal = case refusal of
  ResponseHandlerFailed err -> bounded "handler-failed" err
  ResponseCancelled err -> bounded "cancelled" err
 where
  bounded label err = label ++ ": " ++ take responseRefusalReasonMaximumChars (show err)

-- | The bound 'renderResponseRefusalReason' truncates at.
responseRefusalReasonMaximumChars :: Int
responseRefusalReasonMaximumChars = 512

-- | The last thing a server can say when even the refusal renderer is broken.
--
-- A top-level literal rather than a bounded construction, deliberately: the
-- Bootstrap Broker's equivalent calls @error@ on a bound violation, so its
-- last-resort path can itself bottom. This one cannot.
lastResortInternalError :: ByteString
lastResortInternalError =
  "HTTP/1.1 500 Internal Server Error\r\n\
  \Connection: close\r\n\
  \Content-Length: 15\r\n\
  \\r\n\
  \internal-error\n"

-- | Answer exactly one accepted connection.
--
-- The socket is __not__ closed here; the caller's @bracket@ or @forkFinally@
-- owns its lifetime. What this owns is the guarantee that exactly one reply is
-- attempted on every path out.
--
-- Asynchronous exceptions are answered on a bounded best-effort write and then
-- __re-raised unchanged__. That is not politeness: @System.Timeout.Timeout@ is
-- an asynchronous exception, so converting it into a @500@ would both send a
-- reply and make an enclosing 'timeout' return @Just@ — silently defeating any
-- deadline composed around this call.
withResponseObligation
  :: ResponseObligation reply
  -> Socket
  -> IO reply
  -- ^ Compute the reply. Cannot be @IO ()@: a handler that answers nothing does
  -- not type-check.
  -> IO ()
withResponseObligation obligation client handler =
  mask $ \restore -> do
    -- The render happens inside the protected region. A bottom in the reply
    -- body must become a refusal, not escape past the write: `renderHttpResponse`
    -- forces the body to compute its Content-Length, so the thunk is evaluated
    -- somewhere regardless — the only question is which side of the guard.
    rendered <-
      try (restore (handler >>= evaluate . obligationRender obligation))
        :: IO (Either SomeException ByteString)
    case rendered of
      Right wire -> deliver wire
      Left err
        | isAsyncException err -> do
            bestEffort =<< refusalWire (ResponseCancelled err)
            throwIO err
        | otherwise -> deliver =<< refusalWire (ResponseHandlerFailed err)
 where
  budget = obligationWriteBudgetMicros obligation

  refusalWire refusal = do
    -- Sprint 4.65: the reason is recorded before the reply is computed, so a
    -- refusal is observed even if rendering it then bottoms out into
    -- 'lastResortInternalError'.
    --
    -- Both wrappers are load-bearing rather than defensive habit. Sprint 4.60's
    -- whole guarantee is that nothing on the refusal path prevents the reply,
    -- and an observer is caller-supplied code: it may throw, and it may block.
    -- A throw is swallowed and a stall is abandoned at
    -- 'responseObserveBudgetMicrosDefault'. The one thing not swallowed is
    -- cancellation, which is re-raised so an enclosing deadline still fires.
    observed <-
      try (timeout responseObserveBudgetMicrosDefault (obligationObserveRefusal obligation refusal))
        :: IO (Either SomeException (Maybe ()))
    case observed of
      Left err | isAsyncException err -> throwIO err
      _ -> pure ()
    attempted <-
      try (evaluate (obligationRender obligation (obligationRefusal obligation refusal)))
        :: IO (Either SomeException ByteString)
    pure (either (const lastResortInternalError) id attempted)

  deliver wire = do
    written <- try (timeout budget (sendAll client wire)) :: IO (Either SomeException (Maybe ()))
    case written of
      Right _ -> pure ()
      Left err
        | isAsyncException err -> throwIO err
        -- The peer is already gone. There is nothing left to say to it, and
        -- failing here would only replace one silent close with a louder one.
        | otherwise -> pure ()

  -- Swallows everything, including a second cancellation arriving mid-write, so
  -- the original asynchronous exception is the one that propagates.
  bestEffort wire = do
    _ <- try (timeout budget (sendAll client wire)) :: IO (Either SomeException (Maybe ()))
    pure ()

-- | Asynchronous exceptions route through @asyncExceptionToException@, so this
-- catches @ThreadKilled@, @AsyncCancelled@, @Timeout@, and the RTS overflow
-- exceptions alike. An arbitrary /synchronous/ type delivered by @throwTo@ is
-- indistinguishable and becomes a handler failure; @safe-exceptions@ and the
-- Bootstrap Broker share that limitation.
isAsyncException :: SomeException -> Bool
isAsyncException err = case fromException err :: Maybe SomeAsyncException of
  Just _ -> True
  Nothing -> False
