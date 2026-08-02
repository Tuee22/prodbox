{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.50: the physical unit of the resumable decommission receipt.
--
-- The decommission runner (a later increment) journals a hash-chained log of
-- typed intent/observation/result entries so that, after any crash, it can reopen
-- the receipt, validate the longest complete valid prefix, and resume the exact
-- durably recorded attempt — never authorising a duplicate destructive mutation.
-- This module owns the frame unit and its integrity discipline; the log stream,
-- longest-valid-prefix recovery, and fsync barrier are separate modules.
--
-- Every frame carries its schema version, the manifest digest that binds the whole
-- receipt, a monotonically increasing index, a stable node id, a stable attempt
-- id, the digest of the previous frame (the hash chain), a checksum over its own
-- payload, and the typed payload. Two integrity facts fall out of the codec: a
-- frame cannot be re-encoded non-canonically without detection, and its stored
-- payload checksum must actually match its payload — so a tampered frame is
-- refused before it can be trusted as recorded history.
--
-- The frame is polymorphic in its @payload@ (any 'Serialise' value); the runner
-- increment fixes it to the concrete decommission intent/observation/result
-- vocabulary.
module Prodbox.Lifecycle.Decommission.Frame
  ( FrameDigest (..)
  , FrameChecksum (..)
  , FrameNodeId
  , FrameAttemptId
  , FrameCodecError (..)
  , DecommissionFrame (..)
  , currentFrameVersion
  , mkFrameNodeId
  , mkFrameAttemptId
  , frameNodeIdForContent
  , frameAttemptIdForNode
  , frameNodeIdText
  , frameAttemptIdText
  , genesisPreviousDigest
  , contentDigest
  , frameDigest
  , payloadChecksum
  , appendPayload
  , encodeFrame
  , decodeFrame
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric (showHex)

-- | A SHA-256 digest of a frame's canonical bytes: the hash-chain link a
-- successor frame carries in 'framePreviousDigest'.
newtype FrameDigest = FrameDigest ByteString
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | A SHA-256 checksum over a frame's payload bytes, independent of the chain
-- link so a payload can be validated in isolation.
newtype FrameChecksum = FrameChecksum ByteString
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | A stable identifier for the external node a frame concerns.  Stability across
-- retries is what lets a re-observed external effect be matched to its recorded
-- attempt rather than duplicated.
newtype FrameNodeId = FrameNodeId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | A stable identifier for one attempt against a node.  A crash-and-retry reuses
-- the same attempt id after re-observing, so a torn receipt can never authorise a
-- second distinct attempt.
newtype FrameAttemptId = FrameAttemptId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data FrameCodecError
  = FrameTooLarge
  | FrameInvalid
  | FrameUnsupportedVersion
  | FrameNonCanonical
  | FrameIdentifierInvalid
  | FrameChecksumMismatch
  deriving stock (Eq, Show)

-- | One committed frame of the decommission receipt.
data DecommissionFrame payload = DecommissionFrame
  { frameVersion :: !Word
  , frameManifestDigest :: !FrameDigest
  , frameIndex :: !Word
  , frameNodeId :: !FrameNodeId
  , frameAttemptId :: !FrameAttemptId
  , framePreviousDigest :: !FrameDigest
  , framePayloadChecksum :: !FrameChecksum
  , framePayload :: !payload
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

currentFrameVersion :: Word
currentFrameVersion = 1

-- | Validate a stable identifier: non-empty, bounded, and free of control
-- characters, so a receipt cannot smuggle a delimiter or an unbounded blob.
mkStableId :: Text -> Maybe Text
mkStableId value
  | Text.null trimmed = Nothing
  | Text.length trimmed > 128 = Nothing
  | Text.any isControl trimmed = Nothing
  | otherwise = Just trimmed
 where
  trimmed = Text.strip value

mkFrameNodeId :: Text -> Maybe FrameNodeId
mkFrameNodeId = fmap FrameNodeId . mkStableId

mkFrameAttemptId :: Text -> Maybe FrameAttemptId
mkFrameAttemptId = fmap FrameAttemptId . mkStableId

-- | Derive a bounded stable node identifier from canonical node content.  The
-- domain separator prevents the identifier from being confused with another
-- SHA-256 use, while the fixed-width hexadecimal rendering remains valid under
-- 'mkFrameNodeId' regardless of the coordinate length in the node payload.
frameNodeIdForContent :: ByteString -> FrameNodeId
frameNodeIdForContent content =
  FrameNodeId
    ("node-v1-" <> Text.pack (concatMap renderOctet (ByteString.unpack digest)))
 where
  digest = sha256 ("prodbox-decommission-node-v1:" <> content)
  renderOctet byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

-- | Derive the one stable attempt identity used for an exact manifest node.
-- 'frameNodeIdForContent' always yields a fixed-width printable identifier, so
-- this constructor cannot violate the bounded identifier invariant.  Keeping
-- the construction here avoids a partial smart-constructor unwrap in the
-- production decommission composition.
frameAttemptIdForNode :: FrameNodeId -> FrameAttemptId
frameAttemptIdForNode nodeId =
  FrameAttemptId ("attempt-v1-" <> frameNodeIdText nodeId)

frameNodeIdText :: FrameNodeId -> Text
frameNodeIdText (FrameNodeId value) = value

frameAttemptIdText :: FrameAttemptId -> Text
frameAttemptIdText (FrameAttemptId value) = value

sha256 :: ByteString -> ByteString
sha256 = SHA256.hash

-- | The genesis previous-digest: the chain root for the first frame, bound to the
-- manifest digest so a frame log cannot be replayed under a different manifest.
genesisPreviousDigest :: FrameDigest -> FrameDigest
genesisPreviousDigest (FrameDigest manifest) =
  FrameDigest (sha256 (genesisLabel <> manifest))
 where
  genesisLabel :: ByteString
  genesisLabel = "prodbox-decommission-genesis-v1:"

-- | The SHA-256 of arbitrary content, as a 'FrameDigest'. The shared primitive
-- behind the frame chain digest and the receipt's binding manifest digest.
contentDigest :: ByteString -> FrameDigest
contentDigest = FrameDigest . sha256

-- | The SHA-256 of a frame's canonical bytes — the value its successor carries in
-- 'framePreviousDigest'.
frameDigest :: (Serialise payload) => DecommissionFrame payload -> FrameDigest
frameDigest = contentDigest . LazyByteString.toStrict . serialise

payloadChecksum :: (Serialise payload) => payload -> FrameChecksum
payloadChecksum = FrameChecksum . sha256 . LazyByteString.toStrict . serialise

-- | Build the next frame in a chain. @Nothing@ for the previous frame produces the
-- genesis frame (index 0, previous digest bound to the manifest); a @Just@
-- predecessor advances the index by one and links to its digest.
appendPayload
  :: (Serialise payload)
  => FrameDigest
  -- ^ manifest digest binding the receipt
  -> Maybe (DecommissionFrame payload)
  -- ^ the previous committed frame, if any
  -> FrameNodeId
  -> FrameAttemptId
  -> payload
  -> DecommissionFrame payload
appendPayload manifest previous nodeId attemptId payload =
  DecommissionFrame
    { frameVersion = currentFrameVersion
    , frameManifestDigest = manifest
    , frameIndex = maybe 0 ((+ 1) . frameIndex) previous
    , frameNodeId = nodeId
    , frameAttemptId = attemptId
    , framePreviousDigest = maybe (genesisPreviousDigest manifest) frameDigest previous
    , framePayloadChecksum = payloadChecksum payload
    , framePayload = payload
    }

-- | Canonical frame bytes (no length prefix; the log stream owns delimiting).
encodeFrame :: (Serialise payload) => DecommissionFrame payload -> ByteString
encodeFrame = LazyByteString.toStrict . serialise

-- | Decode a single frame from @maximumBytes@-bounded canonical bytes, verifying
-- the version, canonical form, and that the stored payload checksum matches the
-- payload.
decodeFrame
  :: (Serialise payload)
  => Int
  -> ByteString
  -> Either FrameCodecError (DecommissionFrame payload)
decodeFrame maximumBytes bytes
  | maximumBytes < 0 = Left FrameTooLarge
  | ByteString.length bytes > maximumBytes = Left FrameTooLarge
  | otherwise =
      case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left FrameInvalid
        Right frame
          | frameVersion frame /= currentFrameVersion -> Left FrameUnsupportedVersion
          | encodeFrame frame /= bytes -> Left FrameNonCanonical
          | not (validNodeId (frameNodeId frame)) -> Left FrameIdentifierInvalid
          | not (validAttemptId (frameAttemptId frame)) -> Left FrameIdentifierInvalid
          | framePayloadChecksum frame /= payloadChecksum (framePayload frame) ->
              Left FrameChecksumMismatch
          | otherwise -> Right frame
 where
  validNodeId (FrameNodeId value) = mkStableId value == Just value
  validAttemptId (FrameAttemptId value) = mkStableId value == Just value
