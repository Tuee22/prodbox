{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Frozen finite regression reference from the pre-scanner AWS profile parser.
module FrozenAwsSubstrateCidr (frozenParseAwsCidr) where

import Data.Char (isDigit, ord)
import Data.Text (Text)
import Data.Text qualified as Text

frozenParseAwsCidr :: Text -> Maybe (Integer, Int)
frozenParseAwsCidr raw
  -- Four three-digit octets, three dots, a slash and the existing three-digit
  -- prefix grammar. In particular, preserve accepted prefixes such as /032.
  | Text.length trimmed > 4 * 3 + 3 + 1 + 3 = malformed
  | otherwise =
      case Text.splitOn "/" trimmed of
        [addressText, prefixText] -> do
          octets <- traverse parseOctet (Text.splitOn "." addressText)
          prefix <- parseDecimal prefixText
          case octets of
            [a, b, c, d]
              | prefix >= 0 && prefix <= 32 ->
                  Just (a * 16777216 + b * 65536 + c * 256 + d, fromInteger prefix)
            _ -> malformed
        _ -> malformed
 where
  trimmed = Text.strip raw
  malformed = Nothing
  parseOctet value = do
    if Text.length value > 3 then Nothing else Just ()
    number <- parseDecimal value
    if number <= 255 && (Text.length value == 1 || Text.head value /= '0')
      then Just number
      else Nothing
  parseDecimal value
    | Text.null value || Text.length value > 3 || not (Text.all isDigit value) = Nothing
    | otherwise =
        Just (Text.foldl' (\number digit -> 10 * number + fromIntegral (ord digit - ord '0')) 0 value)
