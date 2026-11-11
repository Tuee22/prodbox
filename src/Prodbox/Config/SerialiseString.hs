{-# LANGUAGE ImportQualifiedPost #-}

-- | Preserve the selected SDK's String wire representation while checking
-- generalized UTF8 before its unchecked ByteArray traversal. This supplies no
-- canonicality, decoded-state or admission witness; the enclosing codec owns
-- those checks. Construction and nested CBOR buffers remain separately funded.
module Prodbox.Config.SerialiseString
  ( SerialiseString (..)
  , validGeneralisedUtf8
  , generalisedUtf8ScalarCount
  ) where

import Codec.CBOR.ByteArray qualified as Array
import Codec.CBOR.Decoding qualified as Cbor
import Codec.Serialise (Serialise (..))
import Codec.Serialise.Internal.GeneralisedUTF8 qualified as Utf8
import Control.Monad (unless)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.Text qualified as Text
import Numeric.Natural (Natural)

newtype SerialiseString = SerialiseString {serialiseStringValue :: String}
  deriving (Eq)

instance Serialise SerialiseString where
  encode (SerialiseString value) = encode value
  decode = do
    token <- Cbor.peekTokenType
    case token of
      Cbor.TypeString -> SerialiseString . Text.unpack <$> Cbor.decodeString
      Cbor.TypeBytes -> do
        bytes <- Cbor.decodeBytes
        unless (validGeneralisedUtf8 bytes) (fail "invalid generalized UTF8 String")
        -- Use the same SDK routine as its String instance, after validation.
        -- Only the exact visible payload is copied to the decoder's array;
        -- there is no synthetic CBOR field or second CBOR parser.
        pure (SerialiseString (Utf8.decodeGenUTF8 (Array.unBA (Array.fromByteString bytes))))
      _ -> fail "expected a String"

-- Every index is guarded by the remaining payload length. Surrogates are
-- accepted in the three-byte ED range, exactly as the String encoder needs.
-- Overlong forms, truncation, stray continuations and values above Char's
-- range refuse. This does not replace the enclosing canonical read-back.
validGeneralisedUtf8 :: ByteString -> Bool
validGeneralisedUtf8 bytes = go 0
 where
  size = Bytes.length bytes
  between low high value = low <= value && value <= high
  go offset
    | offset == size = True
    | first <= 0x7f = go (offset + 1)
    | between 0xc2 0xdf first =
        remaining >= 2 && continuation 1 && go (offset + 2)
    | first == 0xe0 =
        remaining >= 3 && between 0xa0 0xbf (at 1) && continuation 2 && go (offset + 3)
    | between 0xe1 0xef first =
        remaining >= 3 && continuation 1 && continuation 2 && go (offset + 3)
    | first == 0xf0 =
        remaining >= 4 && between 0x90 0xbf (at 1) && continuation 2 && continuation 3 && go (offset + 4)
    | between 0xf1 0xf3 first =
        remaining >= 4 && continuation 1 && continuation 2 && continuation 3 && go (offset + 4)
    | first == 0xf4 =
        remaining >= 4 && between 0x80 0x8f (at 1) && continuation 2 && continuation 3 && go (offset + 4)
    | otherwise = False
   where
    first = Bytes.index bytes offset
    remaining = size - offset
    at relative = Bytes.index bytes (offset + relative)
    continuation relative = between 0x80 0xbf (at relative)

-- Count the exact Char domain accepted by the existing byte decoder without
-- constructing Text, String or character objects. Every leading byte belongs
-- to one scalar after validation; continuation bytes contribute no scalar.
-- This is a syntax/count observation, not canonicality or admission evidence.
generalisedUtf8ScalarCount :: ByteString -> Maybe Natural
generalisedUtf8ScalarCount bytes
  | validGeneralisedUtf8 bytes = Just (Bytes.foldl' count 0 bytes)
  | otherwise = Nothing
 where
  count total byte
    | byte .&. 0xc0 == 0x80 = total
    | otherwise = total + 1
