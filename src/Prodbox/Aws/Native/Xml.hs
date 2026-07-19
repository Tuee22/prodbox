{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.62 deliverable 3 (shared XML): a namespace-unaware substring
-- extractor for AWS query\/REST-XML responses, plus an escaper for the XML we
-- EMIT (Route 53 record names\/values). Mirrors the private @extractBetween@ in
-- "Prodbox.Minio.ObjectStoreNative" (lifted here so both the object-store and
-- the service clients share one implementation). Not a general XML parser; it is
-- sufficient for AWS's flat, well-formed response shapes and is contained by the
-- ambiguity model (a mis-extract on a mutating op becomes an ambiguous outcome,
-- never a false success).
module Prodbox.Aws.Native.Xml
  ( extractFirst
  , extractAll
  , xmlEscape
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Maybe (listToMaybe)

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
  ampersand = 38
  lessThan = 60
  greaterThan = 62
  doubleQuote = 34
  singleQuote = 39
