{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE PatternSynonyms #-}

-- | A bounded, evaluated token program from the selected closed-data encoder.
-- This carries neither a callback nor a resource/admission witness. Producer,
-- construction, writer/control/GC/native peaks remain separate obligations.
module Prodbox.Config.CanonicalDhallDataEncoding
  ( CanonicalDhallDataEncoding
  , CanonicalDhallDataEncodingError (..)
  , prepareCanonicalDhallDataEncoding
  , canonicalDhallEncodingWireBytes
  , canonicalDhallEncodingTokenCount
  , canonicalDhallEncodingNormalFormBytes
  , encodePreparedCanonicalDhallData
  , settingsCanonicalProgramBytes
  , settingsCanonicalOutputBufferBytes
  ) where

import Codec.CBOR.ByteArray.Sliced qualified as Sliced
import Codec.CBOR.Encoding qualified as Encoding
import Codec.CBOR.Write qualified as Cbor
import Data.Bits (countLeadingZeros, finiteBitSize)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Builder.Extra qualified as Builder
import Data.ByteString.Lazy qualified as Lazy
import Data.ByteString.Lazy.Internal qualified as LazyInternal
import Data.Primitive.ByteArray (ByteArray (ByteArray))
import Data.Text.Foreign qualified as Text
import GHC.Exts (Int (I#), Word (W#), indexWordArray#, sizeofByteArray#)
import GHC.Natural (BigNat (BN#), Natural, pattern NatJ#, pattern NatS#)
import Prodbox.Capacity.BoxedNormalForm
import Prodbox.Config.CanonicalDhallValueShape

data CanonicalDhallDataEncodingError
  = CanonicalDhallEncodingTooLarge
  | CanonicalDhallEncodingUnsupportedToken
  | CanonicalDhallEncodingWriterDisagreement
  deriving (Eq, Show)

data CanonicalDhallDataEncoding = Prepared !Natural !Natural !Natural !Encoding.Tokens

-- Keep the tail lazy until the current token fits; rejection does not inspect
-- a later producer suffix. A successful full walk evaluates every SDK token.
data TokenStep = TokenStep !Natural !Natural Encoding.Tokens

prepareCanonicalDhallDataEncoding
  :: Natural -> Encoding.Encoding -> Either CanonicalDhallDataEncodingError CanonicalDhallDataEncoding
prepareCanonicalDhallDataEncoding limit (Encoding.Encoding produce) = do
  let !tokens = produce Encoding.TkEnd
      ceilingBytes = min limit (fromIntegral (maxBound :: Int) - 9)
  (size, count, dataBytes) <- measure ceilingBytes 0 0 16 tokens
  if size == 0
    then Left CanonicalDhallEncodingUnsupportedToken
    else pure $! Prepared size count dataBytes tokens

measure
  :: Natural
  -> Natural
  -> Natural
  -> Natural
  -> Encoding.Tokens
  -> Either CanonicalDhallDataEncodingError (Natural, Natural, Natural)
measure limit !size !count !dataBytes tokens = case tokens of
  Encoding.TkEnd -> Right (size, count, dataBytes)
  _ -> do
    TokenStep wireBytes objectBytes rest <- tokenStep tokens
    let !nextSize = size + wireBytes
    if nextSize > limit
      then Left CanonicalDhallEncodingTooLarge
      else measure limit nextSize (count + 1) (dataBytes + objectBytes) rest

-- The selected data encoder emits only these definite primitive constructors.
-- Every other SDK constructor is explicitly refused, including raw encoded
-- fragments and all implicit/indefinite/float/negative-number paths.
tokenStep :: Encoding.Tokens -> Either CanonicalDhallDataEncodingError TokenStep
tokenStep tokens = case tokens of
  Encoding.TkWord value rest -> word value rest
  Encoding.TkWord64 value rest -> scalar (fromIntegral value) (boxedWord64Bytes value) rest
  Encoding.TkInt value rest
    | value >= 0 -> scalar (fromIntegral value) (boxedIntBytes value) rest
    | otherwise -> unsupported
  Encoding.TkInt64 value rest
    | value >= 0 -> scalar (fromIntegral value) 16 rest
    | otherwise -> unsupported
  Encoding.TkInteger value rest
    | value >= 0 ->
        pure (TokenStep (integerWireBytes value) (boxedRecordBytes [boxedIntegerBytes value, 0]) rest)
    | otherwise -> unsupported
  Encoding.TkString value rest ->
    let size = fromIntegral (Text.lengthWord8 value)
     in pure (TokenStep (headerBytes size + size) (boxedRecordBytes [boxedTextBytes value, 0]) rest)
  Encoding.TkListLen value rest -> word value rest
  Encoding.TkMapLen value rest -> word value rest
  Encoding.TkTag value rest -> word value rest
  Encoding.TkTag64 value rest -> scalar (fromIntegral value) (boxedWord64Bytes value) rest
  Encoding.TkNull rest -> pure (TokenStep 1 (boxedRecordBytes [0]) rest)
  Encoding.TkBool value rest -> value `seq` pure (TokenStep 1 (boxedRecordBytes [16, 0]) rest)
  Encoding.TkBytes _ _ -> unsupported
  Encoding.TkBytesBegin _ -> unsupported
  Encoding.TkByteArray _ _ -> unsupported
  Encoding.TkUtf8ByteArray (Sliced.SBA (ByteArray array) offset lengthBytes) rest ->
    let size = fromIntegral lengthBytes
        backing = fromIntegral (I# (sizeofByteArray# array))
        object =
          boxedRecordBytes
            [ boxedRecordBytes [16 + 8 * ((backing + 7) `div` 8)]
            , boxedIntBytes offset
            , boxedIntBytes lengthBytes
            , 0
            ]
     in pure (TokenStep (headerBytes size + size) object rest)
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
  Encoding.TkEnd -> unsupported
 where
  unsupported = Left CanonicalDhallEncodingUnsupportedToken
  word value = scalar (fromIntegral value) (boxedWordBytes value)
  scalar value object rest = pure (TokenStep (headerBytes value) (boxedRecordBytes [object, 0]) rest)

integerWireBytes :: Integer -> Natural
integerWireBytes value
  | value <= fromIntegral (maxBound :: Word) = headerBytes (fromInteger value)
  | otherwise =
      let bytes = (naturalBits (fromInteger value) + 7) `div` 8
       in 1 + headerBytes bytes + bytes

headerBytes :: Natural -> Natural
headerBytes value
  | value < 24 = 1
  | value <= 0xff = 2
  | value <= 0xffff = 3
  | value <= 0xffffffff = 5
  | otherwise = 9

-- Highest-limb inspection constructs no scalar payload or decimal rendering.
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

canonicalDhallEncodingWireBytes :: CanonicalDhallDataEncoding -> Natural
canonicalDhallEncodingWireBytes (Prepared size _ _ _) = size

canonicalDhallEncodingTokenCount :: CanonicalDhallDataEncoding -> Natural
canonicalDhallEncodingTokenCount (Prepared _ count _ _) = count

canonicalDhallEncodingNormalFormBytes :: CanonicalDhallDataEncoding -> Natural
canonicalDhallEncodingNormalFormBytes (Prepared size count dataBytes _) =
  boxedRecordBytes
    [boxedNaturalBytes size, boxedNaturalBytes count, boxedNaturalBytes dataBytes, dataBytes]

encodePreparedCanonicalDhallData
  :: CanonicalDhallDataEncoding -> Either CanonicalDhallDataEncodingError ByteString
encodePreparedCanonicalDhallData (Prepared size _ _ tokens) =
  let capacity = fromIntegral (size + 9)
      encoded =
        Builder.toLazyByteStringWith
          (Builder.untrimmedStrategy capacity capacity)
          Lazy.empty
          (Cbor.toBuilder (Encoding.Encoding (const tokens)))
   in case encoded of
        LazyInternal.Chunk bytes LazyInternal.Empty
          | fromIntegral (Bytes.length bytes) == size -> Right bytes
        _ -> Left CanonicalDhallEncodingWriterDisagreement

-- Every checked container contributes its marker, at most one label and one
-- list null; nullary union alternatives add their own nulls. Scalar/text/bool
-- counts are independent. The selected fixed labels' backing arrays fit within
-- 64 bytes. Twenty-four words per token cover constructors, boxed data and that
-- fixed backing; two source spans conservatively cover variable Text views and
-- Integer limbs. The plan has four fields and three small Natural counters.
-- This is evaluated plan data only, excluding producer ASTs/continuations,
-- construction/measurement, writer/stack/GC/native and original admission.
settingsCanonicalProgramBytes :: CanonicalDhallValueUsage -> Natural
settingsCanonicalProgramBytes usage =
  88 + 192 * (1 + tokens) + 2 * canonicalDhallInputBytes usage
 where
  tokens =
    3 * canonicalDhallCheckedContainers usage
      + canonicalDhallUnionAlternatives usage
      + canonicalDhallTextTokens usage
      + canonicalDhallIntegerTokens usage
      + canonicalDhallBooleanValues usage

settingsCanonicalOutputBufferBytes :: CanonicalDhallValueUsage -> Natural
settingsCanonicalOutputBufferBytes usage = 64 + 8 * ((canonicalDhallInputBytes usage + 9 + 7) `div` 8)
