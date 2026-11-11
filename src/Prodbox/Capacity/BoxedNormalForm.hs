{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE PatternSynonyms #-}

-- | Primitive boxed normal-form storage on the pinned unprofiled 64-bit ABI.
-- These are structural terms, not compiler-closure/GC/decoder/RSS bounds.
module Prodbox.Capacity.BoxedNormalForm
  ( boxedRecordBytes
  , boxedNaturalBytes
  , boxedIntegerBytes
  , boxedTextBytes
  , boxedCharBytes
  , boxedIntBytes
  , boxedWordBytes
  , boxedWord32Bytes
  , boxedWord64Bytes
  , boxedListBytes
  , boxedMaybeBytes
  , boxedMapBytes
  , boxedCompactBytes
  , boxedByteViewBytes
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Array qualified as Array
import Data.Text.Internal qualified as Text
import Data.Word (Word32, Word64)
import GHC.Exts (Int (I#), sizeofByteArray#)
import GHC.Natural (BigNat (BN#), Natural, pattern NatJ#, pattern NatS#)

boxedRecordBytes :: [Natural] -> Natural
boxedRecordBytes fields = 8 * (1 + max 1 (fromIntegral (length fields))) + sum fields

boxedNaturalBytes :: Natural -> Natural
boxedNaturalBytes (NatS# _) = 16
boxedNaturalBytes (NatJ# (BN# array)) = 32 + alignBytes (fromIntegral (I# (sizeofByteArray# array)))

-- The positive bignum conversion preserves its limb array. A one-word
-- Integer can become a small Natural; 32 extra bytes cover that distinction.
boxedIntegerBytes :: Integer -> Natural
boxedIntegerBytes value = 32 + boxedNaturalBytes (fromInteger (abs value))

boxedTextBytes :: Text -> Natural
boxedTextBytes (Text.Text (Array.ByteArray array) _ _) = 48 + alignBytes (fromIntegral (I# (sizeofByteArray# array)))

boxedCharBytes :: Char -> Natural
boxedCharBytes value = value `seq` 16
boxedIntBytes :: Int -> Natural
boxedIntBytes value = value `seq` 16
boxedWordBytes :: Word -> Natural
boxedWordBytes value = value `seq` 16
boxedWord32Bytes :: Word32 -> Natural
boxedWord32Bytes value = value `seq` 16
boxedWord64Bytes :: Word64 -> Natural
boxedWord64Bytes value = value `seq` 16

boxedListBytes :: (value -> Natural) -> [value] -> Natural
boxedListBytes size = go 16
 where
  go !total [] = total
  go !total (value : rest) = go (total + 24 + size value) rest

boxedMaybeBytes :: (value -> Natural) -> Maybe value -> Natural
boxedMaybeBytes size value = case value of
  Nothing -> boxedRecordBytes []
  Just present -> boxedRecordBytes [size present]

-- Each Bin has six words; charge a Tip per child even when static sharing
-- makes the real graph smaller. Keys and values keep their own field terms.
boxedMapBytes :: (key -> Natural) -> (value -> Natural) -> Map key value -> Natural
boxedMapBytes keySize valueSize = Map.foldlWithKey' add 16
 where
  add total key value = total + 64 + keySize key + valueSize value

-- For Bytes.copy's PlainPtr storage: BS has four words including unpacked
-- ForeignPtr, PlainPtr two, and the byte array two plus rounded payload.
-- View budgets require the known capacity of their compact originating blob.
boxedCompactBytes :: ByteString -> Natural
boxedCompactBytes bytes = boxedByteViewBytes (fromIntegral (Bytes.length bytes)) bytes

boxedByteViewBytes :: Natural -> ByteString -> Natural
boxedByteViewBytes capacity bytes = bytes `seq` (64 + alignBytes capacity)

alignBytes :: Natural -> Natural
alignBytes bytes = 8 * ((bytes + 7) `div` 8)
