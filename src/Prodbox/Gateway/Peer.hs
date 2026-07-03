{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Peer transport for the gateway daemon.
--
-- Each gateway daemon binds an HTTP listener on its configured peer-events
-- port and accepts signed event batches from peers.  Each daemon also
-- periodically pushes its known commit log to every other peer.  Acceptance
-- is idempotent (repeated events are dropped via 'Prodbox.Gateway.Types.appendIfNew'),
-- per-event HMAC signatures are validated against 'daemonEventKeys', and
-- inbound events whose timestamps lie beyond the configured maximum clock
-- skew are refused with the offending peer marked unhealthy.
--
-- The transport is intentionally HTTP rather than mutual TLS today: the
-- daemon still consumes the retained certificate, key, CA, and listener-host
-- inputs at startup and binding time, while the peer mesh itself closes on
-- the simplest transport that materialises the documented anti-entropy
-- gossip and per-peer transport-health reporting.
module Prodbox.Gateway.Peer
  ( PeerTransportRequest (..)
  , PeerTransportResponse (..)
  , PeerEventBatch (..)
  , parsePeerEventBatch
  , parsePeerHttpRequest
  , renderPeerHttpResponse
  , encodePeerEventBatch
  , handlePeerRequest
  , signEvent
  , verifyEventSignature
  , HmacKeyLookup
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Crypto.Hash.SHA256 (hash, hmac)
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.Char (intToDigit)
import Data.List (isPrefixOf)
import Data.Time.Clock (diffUTCTime)
import Data.Word (Word8)
import GHC.Generics (Generic)
import Prodbox.Gateway.Types
  ( CborPayload (..)
  , SignedEvent (..)
  , eventSignaturePayloadBytes
  , parseIso8601Utc
  )

-- | A single peer-to-peer request after HTTP framing has been parsed.
data PeerTransportRequest
  = -- | Push a batch of events to the receiving daemon.
    PeerPushEvents PeerEventBatch
  | -- | Request all events from the receiving daemon's commit log.
    PeerPullEvents
  deriving (Eq, Show)

-- | A batch of signed events carried in a peer transport message.  The
-- sender's monotonic @orders_version_utc@ is included so the receiver can
-- refuse pushes from peers whose Orders view is older than the receiver's.
data PeerEventBatch = PeerEventBatch
  { peerEventBatchEvents :: [SignedEvent]
  , peerEventBatchSenderOrdersVersionUtc :: Int
  }
  deriving (Eq, Show, Generic)

instance Serialise PeerEventBatch

-- | Lookup function for a peer's HMAC key by node id.  Used to verify
-- signatures on incoming events.
type HmacKeyLookup = String -> Maybe String

-- | Result of handling a peer transport request.
data PeerTransportResponse
  = -- | Number of events newly applied; list of (event_hash, reason)
    -- pairs for events the receiver rejected.
    PeerResponseEventsAccepted Int [(String, String)]
  | -- | A pulled batch of events served to the requesting peer.
    PeerResponseEventBatch PeerEventBatch
  | -- | Receiver refused the push because the sender's Orders version is
    -- older than the receiver's.  Encodes both versions for operator
    -- diagnosis.
    PeerResponseStaleOrders Int Int
  | -- | Transport-level error (malformed request, unsupported route).
    PeerResponseError String
  deriving (Eq, Show, Generic)

instance Serialise PeerTransportResponse

parsePeerEventBatch :: BL.ByteString -> Either String PeerEventBatch
parsePeerEventBatch =
  first (("invalid peer event batch CBOR: " ++) . show) . deserialiseOrFail

encodePeerEventBatch :: PeerEventBatch -> BL.ByteString
encodePeerEventBatch = serialise

-- | Parse a minimal HTTP request used by the peer transport. Only the verb
-- and the CBOR body are interpreted; HTTP headers are otherwise ignored.
parsePeerHttpRequest :: BS.ByteString -> Either String PeerTransportRequest
parsePeerHttpRequest raw =
  let (headerBytes, bodyBytes) = splitOnDoubleCrlf raw
      headerSection = BS8.unpack headerBytes
      firstLine = takeWhile (/= '\r') (takeWhile (/= '\n') headerSection)
      parts = words firstLine
   in case parts of
        (method : path : _) ->
          if method == "POST" && pathMatches "/v1/peer/events" path
            then PeerPushEvents <$> parsePeerEventBatch (BL.fromStrict bodyBytes)
            else
              if method == "GET" && pathMatches "/v1/peer/events" path
                then Right PeerPullEvents
                else Left ("unsupported peer transport route: " ++ method ++ " " ++ path)
        _ -> Left "malformed peer transport request line"

splitOnDoubleCrlf :: BS.ByteString -> (BS.ByteString, BS.ByteString)
splitOnDoubleCrlf input =
  case BS.breakSubstring crlfCrlf input of
    (headers, rest)
      | crlfCrlf `BS.isPrefixOf` rest ->
          (headers, BS.drop (BS.length crlfCrlf) rest)
    _ ->
      case BS.breakSubstring lfLf input of
        (headers, rest)
          | lfLf `BS.isPrefixOf` rest ->
              (headers, BS.drop (BS.length lfLf) rest)
        _ -> (input, BS.empty)
 where
  crlfCrlf = BS8.pack "\r\n\r\n"
  lfLf = BS8.pack "\n\n"

pathMatches :: String -> String -> Bool
pathMatches expected actual =
  let withoutQuery = takeWhile (/= '?') actual
   in expected == withoutQuery || expected `isPrefixOf` actual

-- | Render an HTTP response payload from a peer transport response.
renderPeerHttpResponse :: PeerTransportResponse -> BL.ByteString
renderPeerHttpResponse response =
  let (status, body) = case response of
        PeerResponseEventsAccepted _applied _rejected ->
          ("200 OK", serialise response)
        PeerResponseEventBatch _batch ->
          ("200 OK", serialise response)
        PeerResponseStaleOrders senderVersion receiverVersion ->
          senderVersion `seq` receiverVersion `seq` ("409 Conflict", serialise response)
        PeerResponseError _msg ->
          ("400 Bad Request", serialise response)
      headers =
        "HTTP/1.1 "
          ++ status
          ++ "\r\n"
          ++ "Content-Type: application/cbor\r\n"
          ++ "Content-Length: "
          ++ show (BL.length body)
          ++ "\r\n"
          ++ "Connection: close\r\n"
          ++ "\r\n"
   in BL.append (BL.fromStrict (BS8.pack headers)) body

-- | Build a 'SignedEvent' whose hash and HMAC signature match the
-- canonical unsigned-payload encoding.  The receiver-side check is
-- 'verifyEventSignature'.
signEvent
  :: String
  -- ^ emitter node id
  -> String
  -- ^ event type
  -> String
  -- ^ timestamp in ISO 8601 UTC
  -> CborPayload
  -- ^ canonical CBOR payload bytes
  -> String
  -- ^ HMAC key shared with peers
  -> SignedEvent
signEvent nodeId evType ts payload key =
  let unsignedBytes = eventSignaturePayloadBytes nodeId evType ts payload
      eventHashHex = bytesToHex (hash unsignedBytes)
      sigHex = bytesToHex (hmac (BS8.pack key) (BS8.pack eventHashHex))
   in SignedEvent
        { eventHash = eventHashHex
        , emitterNodeId = nodeId
        , timestampUtc = ts
        , eventType = evType
        , payloadCbor = payload
        , signatureHex = sigHex
        }

-- | Validate the HMAC signature on a received event using the peer's known
-- event key.  Returns 'Right ()' when the signature matches; otherwise an
-- explanatory 'Left' string.
verifyEventSignature :: HmacKeyLookup -> SignedEvent -> Either String ()
verifyEventSignature lookupKey ev =
  case lookupKey (emitterNodeId ev) of
    Nothing -> Left ("no event key registered for " ++ emitterNodeId ev)
    Just key ->
      let unsignedBytes =
            eventSignaturePayloadBytes
              (emitterNodeId ev)
              (eventType ev)
              (timestampUtc ev)
              (payloadCbor ev)
          expectedHash = hash unsignedBytes
          expectedHashHex = bytesToHex expectedHash
          expectedSig = bytesToHex (hmac (BS8.pack key) (BS8.pack expectedHashHex))
       in if expectedHashHex /= eventHash ev
            then Left "event hash does not match payload"
            else
              if expectedSig /= signatureHex ev
                then Left "event HMAC signature mismatch"
                else Right ()

-- | Apply per-event verification rules and return accepted/rejected.  Pure
-- helper used by the transport listener; see 'Prodbox.Gateway.Daemon' for
-- the IO-side state-update integration.
--
-- The "now" reference is supplied by the caller so the helper stays pure.
-- Any event whose timestamp is more than @maxSkew@ seconds away from
-- @nowIso@ is rejected.
handlePeerRequest
  :: HmacKeyLookup
  -> [String]
  -- ^ known emitter ids (configured in Orders)
  -> Double
  -- ^ maximum tolerable absolute skew between emitter timestamps and the
  -- supplied "now" sample, in seconds
  -> String
  -- ^ "now" reference timestamp string in ISO 8601 UTC
  -> PeerEventBatch
  -> ([SignedEvent], [(String, String)])
  -- ^ (accepted events in batch order, rejected (event_hash, reason) pairs)
handlePeerRequest lookupKey knownEmitters maxSkew nowIso (PeerEventBatch events _ordersVersion) =
  let nowParsed = parseIso8601Utc nowIso
      check ev
        | emitterNodeId ev `notElem` knownEmitters =
            Left ("unknown emitter " ++ emitterNodeId ev)
        | otherwise = case verifyEventSignature lookupKey ev of
            Left err -> Left err
            Right () -> case (nowParsed, parseIso8601Utc (timestampUtc ev)) of
              (Just now, Just ts) ->
                let skew = abs (realToFrac (diffUTCTime now ts) :: Double)
                 in if skew > maxSkew
                      then Left ("timestamp skew " ++ show skew ++ "s exceeds bound " ++ show maxSkew)
                      else Right ev
              _ -> Right ev
      partitioned =
        foldr (partitionCheckedEvent check) ([], []) events
   in partitioned

partitionCheckedEvent
  :: (SignedEvent -> Either String SignedEvent)
  -> SignedEvent
  -> ([SignedEvent], [(String, String)])
  -> ([SignedEvent], [(String, String)])
partitionCheckedEvent check ev (acc, rej) =
  case check ev of
    Right okEv -> (okEv : acc, rej)
    Left reason -> (acc, (eventHash ev, reason) : rej)

bytesToHex :: BS.ByteString -> String
bytesToHex = concatMap byteToHex . BS.unpack
 where
  byteToHex :: Word8 -> String
  byteToHex w =
    [ intToDigit (fromIntegral (w `div` 16))
    , intToDigit (fromIntegral (w `mod` 16))
    ]
