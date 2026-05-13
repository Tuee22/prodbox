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

import Crypto.Hash.SHA256 (hash, hmac)
import Data.Aeson (Value (..), eitherDecode, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (intToDigit)
import Data.List (isPrefixOf)
import Data.Time.Clock (diffUTCTime)
import Data.Vector qualified as Vector
import Data.Word (Word8)
import Prodbox.Gateway.Types
  ( SignedEvent (..)
  , encodeEvent
  , parseEvent
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
  deriving (Eq, Show)

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
  deriving (Eq, Show)

-- | Parse a peer event batch from a JSON value.
parsePeerEventBatch :: Value -> Either String PeerEventBatch
parsePeerEventBatch value =
  case value of
    Object obj -> do
      eventArray <- case KeyMap.lookup (Key.fromString "events") obj of
        Just (Array arr) -> pure arr
        _ -> Left "peer event batch: events must be an array"
      events <- mapM parseEvent (Vector.toList eventArray)
      ordersVersion <- case KeyMap.lookup (Key.fromString "sender_orders_version_utc") obj of
        Just (Number n) -> Right (round n)
        Nothing -> Right 0
        _ -> Left "peer event batch: sender_orders_version_utc must be a number"
      Right (PeerEventBatch events ordersVersion)
    _ -> Left "peer event batch must be a JSON object"

encodePeerEventBatch :: PeerEventBatch -> Value
encodePeerEventBatch batch =
  object
    [ "events" .= map encodeEvent (peerEventBatchEvents batch)
    , "sender_orders_version_utc" .= peerEventBatchSenderOrdersVersionUtc batch
    ]

-- | Parse a minimal HTTP request used by the peer transport. Only the verb
-- and the JSON body are interpreted; HTTP headers are otherwise ignored.
parsePeerHttpRequest :: BS.ByteString -> Either String PeerTransportRequest
parsePeerHttpRequest raw =
  let text = BS8.unpack raw
      (headerSection, body) = splitOnDoubleCrlf text
      firstLine = takeWhile (/= '\r') (takeWhile (/= '\n') headerSection)
      parts = words firstLine
   in case parts of
        (method : path : _) ->
          if method == "POST" && pathMatches "/v1/peer/events" path
            then case eitherDecode (BL8.pack body) of
              Left err -> Left ("invalid peer push body: " ++ err)
              Right value -> PeerPushEvents <$> parsePeerEventBatch value
            else
              if method == "GET" && pathMatches "/v1/peer/events" path
                then Right PeerPullEvents
                else Left ("unsupported peer transport route: " ++ method ++ " " ++ path)
        _ -> Left "malformed peer transport request line"

splitOnDoubleCrlf :: String -> (String, String)
splitOnDoubleCrlf input = go [] input
 where
  go acc rest =
    case rest of
      '\r' : '\n' : '\r' : '\n' : remainder -> (reverse acc, remainder)
      '\n' : '\n' : remainder -> (reverse acc, remainder)
      (c : remainder) -> go (c : acc) remainder
      [] -> (reverse acc, "")

pathMatches :: String -> String -> Bool
pathMatches expected actual =
  let withoutQuery = takeWhile (/= '?') actual
   in expected == withoutQuery || expected `isPrefixOf` actual

-- | Render an HTTP response payload from a peer transport response.
renderPeerHttpResponse :: PeerTransportResponse -> BL.ByteString
renderPeerHttpResponse response =
  let (status, body) = case response of
        PeerResponseEventsAccepted applied rejected ->
          let payload =
                object
                  [ "applied" .= applied
                  , "rejected"
                      .= [ object ["event_hash" .= h, "reason" .= reason]
                         | (h, reason) <- rejected
                         ]
                  ]
           in ("200 OK", encode payload)
        PeerResponseEventBatch batch ->
          ("200 OK", encode (encodePeerEventBatch batch))
        PeerResponseStaleOrders senderVersion receiverVersion ->
          ( "409 Conflict"
          , encode
              ( object
                  [ "error" .= ("stale orders" :: String)
                  , "sender_orders_version_utc" .= senderVersion
                  , "receiver_orders_version_utc" .= receiverVersion
                  ]
              )
          )
        PeerResponseError msg ->
          ("400 Bad Request", encode (object ["error" .= msg]))
      headers =
        "HTTP/1.1 "
          ++ status
          ++ "\r\n"
          ++ "Content-Type: application/json\r\n"
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
  -> String
  -- ^ encoded payload string (passed through verbatim)
  -> String
  -- ^ HMAC key shared with peers
  -> SignedEvent
signEvent nodeId evType ts payload key =
  let unsigned =
        object
          [ "emitter_node_id" .= nodeId
          , "event_type" .= evType
          , "payload_json" .= payload
          , "timestamp_utc" .= ts
          ]
      unsignedStr = BL8.unpack (encode unsigned)
      eventHashHex = bytesToHex (hash (BS8.pack unsignedStr))
      sigHex = bytesToHex (hmac (BS8.pack key) (BS8.pack eventHashHex))
   in SignedEvent
        { eventHash = eventHashHex
        , emitterNodeId = nodeId
        , timestampUtc = ts
        , eventType = evType
        , payloadJson = payload
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
      let unsigned =
            object
              [ "emitter_node_id" .= emitterNodeId ev
              , "event_type" .= eventType ev
              , "payload_json" .= payloadJson ev
              , "timestamp_utc" .= timestampUtc ev
              ]
          unsignedStr = BL8.unpack (encode unsigned)
          expectedHash = hash (BS8.pack unsignedStr)
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
