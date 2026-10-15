{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.62 deliverable 3 (shared XML): a namespace-unaware substring
-- extractor for AWS query\/REST-XML responses, plus an escaper for the XML we
-- EMIT (Route 53 record names\/values) and the unescaper its read-back needs.
-- Mirrors the private @extractBetween@ in
-- "Prodbox.Minio.ObjectStoreNative" (lifted here so both the object-store and
-- the service clients share one implementation). Not a general XML parser; it is
-- sufficient for AWS's flat, well-formed response shapes and is contained by the
-- ambiguity model (a mis-extract on a mutating op becomes an ambiguous outcome,
-- never a false success).
module Prodbox.Aws.Native.Xml
  ( extractFirst
  , extractAll
  , xmlEscape
  , xmlUnescape
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (chr, digitToInt, isDigit, isHexDigit)
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word8)

-- | The first (non-nested) value between @open@ and @close@, if present.
extractFirst :: ByteString -> ByteString -> ByteString -> Maybe ByteString
extractFirst open close = listToMaybe . extractAll open close

-- | Every value between successive @open@\/@close@ delimiters, in document order.
extractAll :: ByteString -> ByteString -> ByteString -> [ByteString]
extractAll open close = go
 where
  go haystack =
    case breakAfter open haystack of
      Nothing -> []
      Just afterOpen ->
        case breakBefore close afterOpen of
          Nothing -> []
          Just (value, rest) -> value : go rest

breakAfter :: ByteString -> ByteString -> Maybe ByteString
breakAfter needle haystack =
  let (_, matched) = BS.breakSubstring needle haystack
   in if BS.null matched
        then Nothing
        else Just (BS.drop (BS.length needle) matched)

breakBefore :: ByteString -> ByteString -> Maybe (ByteString, ByteString)
breakBefore needle haystack =
  let (before, matched) = BS.breakSubstring needle haystack
   in if BS.null matched
        then Nothing
        else Just (before, BS.drop (BS.length needle) matched)

-- | Escape the five XML metacharacters in a value we emit.
xmlEscape :: ByteString -> ByteString
xmlEscape = BS.concatMap escapeByte
 where
  escapeByte c
    | c == ampersand = "&amp;"
    | c == lessThan = "&lt;"
    | c == greaterThan = "&gt;"
    | c == doubleQuote = "&quot;"
    | c == singleQuote = "&apos;"
    | otherwise = BS.singleton c

-- | Decode the character data of one element a caller has already extracted:
-- the five predefined entities and decimal or hexadecimal character references.
-- A reference it does not know, one that is not closed within a few bytes, and
-- a code point that is not a Unicode scalar value are left exactly as they came,
-- so the result is never longer than a lossless reading of the input and a stray
-- ampersand costs nothing.
--
-- This is the inverse of 'xmlEscape' and it matters on the read side: Route 53
-- returns a TXT value wrapped in quotation marks that arrive as the entity
-- @&quot;@, and a value read back with the entities still in it is never equal
-- to the value that was written. Decoding is a single left-to-right pass, so
-- the text @&amp;quot;@ becomes the six characters @&quot;@ and not a quotation
-- mark.
--
-- Apply it to a leaf's text only. The structural extractors above return nested
-- markup, and decoding that would turn an escaped closing tag inside a record
-- value into a real one the next extraction then reads as structure.
xmlUnescape :: ByteString -> ByteString
xmlUnescape input
  | not (BS.elem ampersand input) = input
  | otherwise = BS.concat (pieces input)
 where
  pieces rest =
    let (plain, remaining) = BS.break (== ampersand) rest
     in if BS.null remaining
          then [plain]
          else plain : reference (BS.drop 1 remaining)

  -- 'afterAmpersand' is the text after one ampersand.
  reference afterAmpersand =
    let window = BS.take maximumReferenceBytes afterAmpersand
        (name, closing) = BS.break (== semicolon) window
     in case (BS.null closing, decodeReference name) of
          (False, Just decoded) ->
            decoded : pieces (BS.drop (BS.length name + 1) afterAmpersand)
          _ -> BS.singleton ampersand : pieces afterAmpersand

decodeReference :: ByteString -> Maybe ByteString
decodeReference name
  | name == "amp" = Just "&"
  | name == "lt" = Just "<"
  | name == "gt" = Just ">"
  | name == "quot" = Just "\""
  | name == "apos" = Just "'"
  | Just (marker, numeric) <- BS.uncons name, marker == numberSign = decodeNumeric numeric
  | otherwise = Nothing
 where
  decodeNumeric numeric =
    case BS.uncons numeric of
      Just (marker, digits)
        | marker == lowerX || marker == upperX -> scalar 16 isHexDigit digits
      _ -> scalar 10 isDigit numeric

  scalar base accepts digits = do
    let characters = map (toEnum . fromIntegral) (BS.unpack digits)
    if null characters || not (all accepts characters) || length characters > 8
      then Nothing
      else do
        let codePoint = foldl (\acc c -> acc * base + digitToInt c) 0 characters
        if codePoint >= 1 && codePoint <= 0x10FFFF && not (codePoint >= 0xD800 && codePoint <= 0xDFFF)
          then Just (TextEncoding.encodeUtf8 (Text.singleton (chr codePoint)))
          else Nothing

-- | A reference longer than this is not one: the longest real reference is a
-- hexadecimal one for a code point above the basic plane, and a bound keeps a
-- stray ampersand from pairing with a semicolon a paragraph away.
maximumReferenceBytes :: Int
maximumReferenceBytes = 12

ampersand
  , lessThan
  , greaterThan
  , doubleQuote
  , singleQuote
  , semicolon
  , numberSign
  , lowerX
  , upperX
    :: Word8
ampersand = 38
lessThan = 60
greaterThan = 62
doubleQuote = 34
singleQuote = 39
semicolon = 59
numberSign = 35
lowerX = 120
upperX = 88
