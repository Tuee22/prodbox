{-# LANGUAGE ImportQualifiedPost #-}

-- Closed IPv4/CIDR grammar used by the authored AWS profile. The scan bound
-- excludes Text.strip and is not a whole working-set or admission certificate.
module Prodbox.Settings.AwsSubstrateCidr
  ( ParsedAwsCidr
  , parseAwsCidr
  , awsCidrAddress
  , awsCidrPrefix
  , awsCidrMaximumCharacters
  , awsCidrScanSteps
  ) where

import Data.Bits (shiftL, (.|.))
import Data.Char (isDigit, ord)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32)

data ParsedAwsCidr = ParsedAwsCidr !Word32 !Int deriving (Eq, Show)

awsCidrAddress :: ParsedAwsCidr -> Integer
awsCidrAddress (ParsedAwsCidr address _) = toInteger address
awsCidrPrefix :: ParsedAwsCidr -> Int
awsCidrPrefix (ParsedAwsCidr _ prefix) = prefix

-- Four octets of at most three digits,three dots,one slash and up to three
-- prefix digits. Prefix leading zeros remain accepted,including /000,/032.
awsCidrMaximumCharacters, awsCidrScanSteps :: Int
awsCidrMaximumCharacters = 4 * 3 + 3 + 1 + 3
awsCidrScanSteps = awsCidrMaximumCharacters + 1

data ScanState
  = Octets !Int !Word32 !Word32 !Int
  | Prefix !Word32 !Int !Int

parseAwsCidr :: Text -> Maybe ParsedAwsCidr
parseAwsCidr = scan awsCidrScanSteps (Octets 0 0 0 0) . Text.strip

scan :: Int -> ScanState -> Text -> Maybe ParsedAwsCidr
scan remaining state input
  | remaining <= 0 = Nothing
  | otherwise = case Text.uncons input of
      Nothing -> case state of
        Prefix address prefix digits
          | digits > 0 && prefix <= 32 -> Just (ParsedAwsCidr address prefix)
        Octets {} -> Nothing
        Prefix {} -> Nothing
      Just (character, rest) -> case state of
        Octets completed address octet digits
          | character == '.' && completed < 3 && digits > 0 ->
              continue (Octets (completed + 1) (appendOctet address octet) 0 0) rest
          | character == '/' && completed == 3 && digits > 0 ->
              continue (Prefix (appendOctet address octet) 0 0) rest
          | isDigit character && digits < 3 && (digits == 0 || octet /= 0) ->
              let next = octet * 10 + fromIntegral (ord character - ord '0')
               in if next <= 255
                    then continue (Octets completed address next (digits + 1)) rest
                    else Nothing
          | otherwise -> Nothing
        Prefix address prefix digits
          | isDigit character && digits < 3 ->
              continue (Prefix address (prefix * 10 + ord character - ord '0') (digits + 1)) rest
          | otherwise -> Nothing
 where
  continue = scan (remaining - 1)

appendOctet :: Word32 -> Word32 -> Word32
appendOctet address octet = shiftL address 8 .|. octet
