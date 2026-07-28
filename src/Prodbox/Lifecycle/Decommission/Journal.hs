{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 4.50: the length-delimited decommission receipt log and its reopen /
-- recovery decision.
--
-- The runner appends 'Prodbox.Lifecycle.Decommission.Frame' units to a durable
-- file as length-delimited records. After a crash it reopens the file and asks
-- 'recoverReceipt' for the longest complete, checksum-valid, hash-chain-consistent
-- prefix that is bound to the expected manifest. Exactly one tail condition is
-- recoverable — a torn final record, i.e. a crash part-way through appending the
-- last record: recovery truncates the file back to the end of the last valid frame
-- and resumes. Every other tail condition — a fully written but corrupt frame
-- (interior or final), a chain/index break, or a manifest mismatch — refuses,
-- because a fully written record is committed history that must not be silently
-- discarded.
--
-- This module is pure; the fsync-ordered append and the truncate-to-@recoveredValidBytes@
-- effect are the separate barrier increment. It deliberately does NOT yet decide
-- runner-semantic conflicts (a reused node/attempt identifier standing for a
-- different intent); that check layers on top once the runner fixes the payload
-- vocabulary.
module Prodbox.Lifecycle.Decommission.Journal
  ( JournalRecoveryError (..)
  , RecoveryOutcome (..)
  , ReceiptRecovery (..)
  , encodeRecord
  , encodeJournal
  , recoverReceipt
  )
where

import Codec.Serialise (Serialise)
import Data.Bits (shiftL, shiftR, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Word (Word32, Word8)
import Prodbox.Lifecycle.Decommission.Frame
  ( DecommissionFrame
  , FrameCodecError
  , FrameDigest
  , decodeFrame
  , encodeFrame
  , frameDigest
  , frameIndex
  , frameManifestDigest
  , framePreviousDigest
  , genesisPreviousDigest
  )

-- | An unrecoverable receipt defect, tagged with the frame index at which it was
-- detected.
data JournalRecoveryError
  = -- | A fully present record failed the bounded canonical / checksum codec.
    JournalFrameCodecError !Word !FrameCodecError
  | -- | A valid frame broke the chain: its manifest, index, or previous digest did
    -- not match the expected running chain state.
    JournalChainDrift !Word
  deriving stock (Eq, Show)

data RecoveryOutcome
  = -- | The whole stream is a valid chain; nothing to truncate.
    RecoveryComplete
  | -- | The final record is torn (a partial length prefix or body); truncate to
    -- @recoveredValidBytes@ and resume.
    RecoveryTruncatableTorn
  | -- | An unrecoverable defect; the receipt must not be resumed by truncation.
    RecoveryRefused !JournalRecoveryError
  deriving stock (Eq, Show)

-- | The result of reopening a receipt: the recovered valid prefix, the byte length
-- to truncate to, and the tail classification.
data ReceiptRecovery payload = ReceiptRecovery
  { recoveredFrames :: ![DecommissionFrame payload]
  , recoveredValidBytes :: !Int
  , recoveryOutcome :: !RecoveryOutcome
  }
  deriving stock (Eq, Show)

lengthPrefixBytes :: Int
lengthPrefixBytes = 4

-- | Encode one frame as a length-delimited record: a 4-byte big-endian length
-- prefix followed by the frame's canonical bytes.
encodeRecord :: (Serialise payload) => DecommissionFrame payload -> ByteString
encodeRecord frame =
  word32ToBE (fromIntegral (ByteString.length body)) <> body
 where
  body = encodeFrame frame

-- | Encode a whole frame chain as concatenated length-delimited records.
encodeJournal :: (Serialise payload) => [DecommissionFrame payload] -> ByteString
encodeJournal = ByteString.concat . fmap encodeRecord

-- | Reopen a receipt: return the longest complete, checksum-valid,
-- manifest-bound, hash-chain-consistent prefix and how its tail is classified.
-- @maximumFrameBytes@ bounds each frame; @expectedManifest@ is the manifest digest
-- every frame must carry (the signed-manifest binding).
recoverReceipt
  :: (Serialise payload)
  => Int
  -> FrameDigest
  -> ByteString
  -> ReceiptRecovery payload
recoverReceipt maximumFrameBytes expectedManifest journal =
  loop 0 0 (genesisPreviousDigest expectedManifest) [] journal
 where
  finish validBytes acc outcome =
    ReceiptRecovery
      { recoveredFrames = reverse acc
      , recoveredValidBytes = validBytes
      , recoveryOutcome = outcome
      }
  loop validBytes expectedIndex expectedPrevious acc remaining
    | ByteString.null remaining = finish validBytes acc RecoveryComplete
    | ByteString.length remaining < lengthPrefixBytes =
        -- A partial length prefix: the last append was torn mid-write.
        finish validBytes acc RecoveryTruncatableTorn
    | otherwise =
        let (prefix, afterPrefix) = ByteString.splitAt lengthPrefixBytes remaining
            recordLength = fromIntegral (word32FromBE prefix) :: Int
         in if ByteString.length afterPrefix < recordLength
              then -- A record whose declared body never fully landed: torn tail.
                finish validBytes acc RecoveryTruncatableTorn
              else
                let (body, rest) = ByteString.splitAt recordLength afterPrefix
                 in case decodeFrame maximumFrameBytes body of
                      Left err ->
                        -- A fully present but corrupt record: committed history, refuse.
                        finish validBytes acc (RecoveryRefused (JournalFrameCodecError expectedIndex err))
                      Right frame
                        | frameManifestDigest frame /= expectedManifest -> drift
                        | frameIndex frame /= expectedIndex -> drift
                        | framePreviousDigest frame /= expectedPrevious -> drift
                        | otherwise ->
                            loop
                              (validBytes + lengthPrefixBytes + recordLength)
                              (expectedIndex + 1)
                              (frameDigest frame)
                              (frame : acc)
                              rest
                       where
                        drift = finish validBytes acc (RecoveryRefused (JournalChainDrift expectedIndex))

word32ToBE :: Word32 -> ByteString
word32ToBE value =
  ByteString.pack
    [ octet 24
    , octet 16
    , octet 8
    , octet 0
    ]
 where
  octet shiftBy = fromIntegral (value `shiftR` shiftBy) :: Word8

word32FromBE :: ByteString -> Word32
word32FromBE bytes = case ByteString.unpack bytes of
  [a, b, c, d] ->
    (fromIntegral a `shiftL` 24)
      .|. (fromIntegral b `shiftL` 16)
      .|. (fromIntegral c `shiftL` 8)
      .|. fromIntegral d
  _ -> 0
