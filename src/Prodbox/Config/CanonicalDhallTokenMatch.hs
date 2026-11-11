{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE PatternSynonyms #-}

-- | Equality interpretation of the selected definite SDK tokens. Compare
-- headers and existing scalar payloads directly; construct no encoded buffer.
-- This is not a producer, schema validator or memory/admission certificate.
module Prodbox.Config.CanonicalDhallTokenMatch
  ( CanonicalDhallTokenMatchError (..)
  , matchCanonicalDhallTokens
  , matchCanonicalBinaryTokens
  ) where

import Codec.CBOR.ByteArray.Sliced qualified as Sliced
import Codec.CBOR.Encoding qualified as Encoding
import Data.Bits (countLeadingZeros, finiteBitSize, shiftL, shiftR, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.Primitive.ByteArray qualified as Array
import Data.Text.Array qualified as TextArray
import Data.Text.Internal qualified as Text
import Data.Word (Word64, Word8)
import GHC.Exts (Int (I#), Word (W#), indexWordArray#, sizeofByteArray#)
import GHC.Natural (BigNat (BN#), Natural, pattern NatJ#, pattern NatS#)

data CanonicalDhallTokenMatchError
  = CanonicalTokenUnsupported
  | CanonicalTokenInvalidView
  deriving (Eq, Show)

matchCanonicalDhallTokens
  :: ByteString -> Encoding.Tokens -> Either CanonicalDhallTokenMatchError Bool
matchCanonicalDhallTokens = matchTokens DhallTokens

-- Definite binary fields are admitted only by this separate interpreter.
-- The closed Dhall-data factory and its comparison keep rejecting them.
matchCanonicalBinaryTokens
  :: ByteString -> Encoding.Tokens -> Either CanonicalDhallTokenMatchError Bool
matchCanonicalBinaryTokens = matchTokens BinaryTokens

data TokenDomain = DhallTokens | BinaryTokens

matchTokens
  :: TokenDomain -> ByteString -> Encoding.Tokens -> Either CanonicalDhallTokenMatchError Bool
matchTokens domain bytes = walk 0
 where
  size = Bytes.length bytes
  walk !offset tokens = case tokens of
    Encoding.TkEnd -> Right (offset == size)
    Encoding.TkWord value rest -> next (header 0 (fromIntegral value) offset) rest
    Encoding.TkWord64 value rest -> next (header 0 value offset) rest
    Encoding.TkInt value rest
      | value >= 0 -> next (header 0 (fromIntegral value) offset) rest
      | otherwise -> unsupported
    Encoding.TkInt64 value rest
      | value >= 0 -> next (header 0 (fromIntegral value) offset) rest
      | otherwise -> unsupported
    Encoding.TkInteger value rest
      | value >= 0 -> next (integer value offset) rest
      | otherwise -> unsupported
    Encoding.TkString (Text.Text array@(TextArray.ByteArray raw) start count) rest
      | validView (I# (sizeofByteArray# raw)) start count ->
          next
            (header 3 (fromIntegral count) offset >>= payload count (TextArray.unsafeIndex array . (start +)))
            rest
      | otherwise -> invalidView
    Encoding.TkUtf8ByteArray (Sliced.SBA array start count) rest
      | validView (Array.sizeofByteArray array) start count ->
          next
            (header 3 (fromIntegral count) offset >>= payload count (Array.indexByteArray array . (start +)))
            rest
      | otherwise -> invalidView
    Encoding.TkListLen value rest -> next (header 4 (fromIntegral value) offset) rest
    Encoding.TkMapLen value rest -> next (header 5 (fromIntegral value) offset) rest
    Encoding.TkTag value rest -> next (header 6 (fromIntegral value) offset) rest
    Encoding.TkTag64 value rest -> next (header 6 value offset) rest
    Encoding.TkNull rest -> next (byte 0xf6 offset) rest
    Encoding.TkBool value rest -> next (byte (if value then 0xf5 else 0xf4) offset) rest
    Encoding.TkBytes value rest -> case domain of
      DhallTokens -> unsupported
      BinaryTokens ->
        next
          ( header 2 (fromIntegral (Bytes.length value)) offset
              >>= payload (Bytes.length value) (Bytes.index value)
          )
          rest
    Encoding.TkBytesBegin _ -> unsupported
    Encoding.TkByteArray (Sliced.SBA array start count) rest -> case domain of
      DhallTokens -> unsupported
      BinaryTokens
        | validView (Array.sizeofByteArray array) start count ->
            next
              (header 2 (fromIntegral count) offset >>= payload count (Array.indexByteArray array . (start +)))
              rest
        | otherwise -> invalidView
    Encoding.TkStringBegin _ -> unsupported
    Encoding.TkListBegin _ -> unsupported
    Encoding.TkMapBegin _ -> unsupported
    Encoding.TkUndef _ -> unsupported
    Encoding.TkSimple _ _ -> unsupported
    Encoding.TkFloat16 _ _ -> unsupported
    Encoding.TkFloat32 _ _ -> unsupported
    Encoding.TkFloat64 _ _ -> unsupported
    Encoding.TkBreak _ -> unsupported
    Encoding.TkEncoded _ _ -> unsupported
  next Nothing _ = Right False
  next (Just offset) rest = walk offset rest
  unsupported = Left CanonicalTokenUnsupported
  invalidView = Left CanonicalTokenInvalidView
  validView backing start count = start >= 0 && count >= 0 && start <= backing && count <= backing - start
  byte expected !offset
    | offset < size && Bytes.index bytes offset == expected = Just (offset + 1)
    | otherwise = Nothing
  payload :: Int -> (Int -> Word8) -> Int -> Maybe Int
  payload count item !offset
    | count < 0 || offset < 0 || offset > size || count > size - offset = Nothing
    | otherwise = loop 0 offset
   where
    loop !index !position
      | index == count = Just position
      | Bytes.index bytes position == item index = loop (index + 1) (position + 1)
      | otherwise = Nothing
  header :: Word8 -> Word64 -> Int -> Maybe Int
  header major argument offset
    | argument < 24 = byte (prefix .|. fromIntegral argument) offset
    | argument <= 0xff = withWidth 24 1
    | argument <= 0xffff = withWidth 25 2
    | argument <= 0xffffffff = withWidth 26 4
    | otherwise = withWidth 27 8
   where
    prefix = major `shiftL` 5
    withWidth tag count = byte (prefix .|. tag) offset >>= payload count expected
     where
      expected index = fromIntegral (argument `shiftR` (8 * (count - index - 1)))
  integer value offset
    | value <= fromIntegral (maxBound :: Word64) = header 0 (fromInteger value) offset
    | otherwise = do
        let number = fromInteger value
            count = (naturalBits number + 7) `div` 8
        afterTag <- header 6 2 offset
        if count > fromIntegral (size - afterTag)
          then Nothing
          else do
            afterLength <- header 2 (fromIntegral count) afterTag
            payload (fromIntegral count) (naturalByte number (fromIntegral count)) afterLength

naturalBits :: Natural -> Natural
naturalBits (NatS# value) = fromIntegral (finiteBitSize (0 :: Word) - countLeadingZeros (W# value))
naturalBits (NatJ# (BN# array)) =
  let size = I# (sizeofByteArray# array) `div` wordBytes
   in if size <= 0
        then 0
        else case size - 1 of
          index@(I# offset) ->
            fromIntegral index * fromIntegral wordBits
              + fromIntegral (wordBits - countLeadingZeros (W# (indexWordArray# array offset)))
 where
  wordBits = finiteBitSize (0 :: Word)
  wordBytes = wordBits `div` 8

naturalByte :: Natural -> Int -> Int -> Word8
naturalByte value count index =
  let position = count - index - 1
      shift = 8 * (position `mod` wordBytes)
   in case value of
        NatS# word -> fromIntegral (W# word `shiftR` shift)
        NatJ# (BN# array) -> case position `div` wordBytes of
          I# offset -> fromIntegral (W# (indexWordArray# array offset) `shiftR` shift)
 where
  wordBytes = finiteBitSize (0 :: Word) `div` 8
