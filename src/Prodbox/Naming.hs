{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Naming
  ( boundedResourceName
  , hashSuffix
  , sanitizeResourceName
  )
where

import Crypto.Hash.SHA1 qualified as SHA1
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char (isAsciiLower, isDigit, toLower)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric (showHex)

maxDns1123LabelLength :: Int
maxDns1123LabelLength = 63

sanitizeResourceName :: Text -> Text
sanitizeResourceName input =
  ensureNonEmpty
    . trimDashes
    . collapseDashes
    . Text.map normalizeCharacter
    $ Text.toLower input
 where
  normalizeCharacter character
    | isDns1123Character character = character
    | otherwise = '-'

  isDns1123Character character =
    isAsciiLower character || isDigit character || character == '-'

  collapseDashes textValue =
    Text.intercalate "-" (filter (not . Text.null) (Text.splitOn "-" textValue))

  trimDashes = Text.dropWhileEnd (== '-') . Text.dropWhile (== '-')

  ensureNonEmpty textValue =
    if Text.null textValue
      then "x"
      else textValue

hashSuffix :: Text -> Text
hashSuffix =
  Text.take 8
    . Text.pack
    . concatMap renderByte
    . BS.unpack
    . SHA1.hash
    . BS8.pack
    . Text.unpack
 where
  renderByte byteValue =
    let rendered = showHex byteValue ""
     in case rendered of
          [singleDigit] -> ['0', toLower singleDigit]
          digits -> map toLower digits

boundedResourceName :: Text -> Text -> Text -> Text
boundedResourceName prefix component suffix =
  let cleanedSegments =
        [ sanitizeResourceName segment
        | segment <- [prefix, component, suffix]
        , not (Text.null (Text.strip segment))
        ]
      candidate = Text.intercalate "-" cleanedSegments
   in if Text.length candidate <= maxDns1123LabelLength
        then candidate
        else
          let suffixHash = hashSuffix candidate
              reservedLength = Text.length suffixHash + 1
              prefixBudget = max 1 (maxDns1123LabelLength - reservedLength)
              truncatedPrefix = Text.take prefixBudget candidate
           in trimTrailingDash truncatedPrefix <> "-" <> suffixHash
 where
  trimTrailingDash = Text.dropWhileEnd (== '-')
