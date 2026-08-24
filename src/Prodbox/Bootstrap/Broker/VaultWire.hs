{-# LANGUAGE OverloadedStrings #-}

-- | Secret-safe decoding for the PGP-targeted Vault initialization response.
--
-- This is the only init-response decoder in the supported runtime. It admits
-- only canonical base64 ciphertext and projects it immediately into opaque,
-- redacting custody values.
module Prodbox.Bootstrap.Broker.VaultWire
  ( EncryptedVaultInitResponse
  , encryptedVaultInitShares
  , encryptedVaultInitBurnToken
  )
where

import Data.Aeson
  ( FromJSON (..)
  , withObject
  , (.:)
  , (.:?)
  )
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word8)
import Prodbox.Bootstrap.Broker.Types
  ( BurnTokenCiphertext
  , PgpEncryptedShare
  , burnTokenCiphertextBytes
  , mkBurnTokenCiphertext
  , mkPgpEncryptedShare
  , pgpEncryptedShareBytes
  )

-- | The only initialization response shape admitted to the target Broker.
-- Its fields cannot expose bytes or render ciphertext.
data EncryptedVaultInitResponse = EncryptedVaultInitResponse
  { encryptedVaultInitShares :: ![PgpEncryptedShare]
  , encryptedVaultInitBurnToken :: !BurnTokenCiphertext
  }
  deriving (Eq)

instance Show EncryptedVaultInitResponse where
  show response =
    "EncryptedVaultInitResponse {shareCount = "
      ++ show (length shares)
      ++ ", shareBytes = "
      ++ show (fmap pgpEncryptedShareBytes shares)
      ++ ", burnTokenBytes = "
      ++ show (burnTokenCiphertextBytes (encryptedVaultInitBurnToken response))
      ++ "}"
   where
    shares = encryptedVaultInitShares response

instance FromJSON EncryptedVaultInitResponse where
  parseJSON =
    withObject "EncryptedVaultInitResponse" $ \objectValue -> do
      rejectUnexpectedFields objectValue
      shamirHexShares <- objectValue .:? "keys"
      shamirBase64Shares <- objectValue .:? "keys_base64"
      recoveryHexShares <- objectValue .:? "recovery_keys"
      recoveryBase64Shares <- objectValue .:? "recovery_keys_base64"
      encodedBurnToken <- objectValue .: "root_token"
      encodedShares <-
        case ( shamirHexShares
             , shamirBase64Shares
             , recoveryHexShares
             , recoveryBase64Shares
             ) of
          (Just hexShares, Just base64Shares, Nothing, Nothing) ->
            parseDualEncodedShares "Shamir" hexShares base64Shares
          (Nothing, Nothing, Just hexShares, Just base64Shares) ->
            parseDualEncodedShares "recovery" hexShares base64Shares
          (Just _, Just _, Just _, Just _) ->
            fail "encrypted Vault init response ambiguously contains two share families"
          (Nothing, Nothing, Nothing, Nothing) ->
            fail "encrypted Vault init response contains no PGP share ciphertext"
          _ ->
            fail "encrypted Vault init response contains an incomplete dual share encoding"
      shares <- traverse parseEncryptedShare encodedShares
      burnToken <- parseBurnToken encodedBurnToken
      pure
        EncryptedVaultInitResponse
          { encryptedVaultInitShares = shares
          , encryptedVaultInitBurnToken = burnToken
          }

rejectUnexpectedFields :: KeyMap.KeyMap value -> Parser ()
rejectUnexpectedFields objectValue =
  case filter (`notElem` encryptedResponseFields) (KeyMap.keys objectValue) of
    [] -> pure ()
    unexpected ->
      fail
        ( "encrypted Vault init response contains forbidden fields: "
            ++ show (fmap Key.toText unexpected)
        )

encryptedResponseFields :: [Key]
encryptedResponseFields =
  [ "keys"
  , "keys_base64"
  , "recovery_keys"
  , "recovery_keys_base64"
  , "root_token"
  ]

parseDualEncodedShares :: Text -> [Text] -> [Text] -> Parser [Text]
parseDualEncodedShares family encodedHex encodedBase64
  | null encodedHex || null encodedBase64 =
      fail (Text.unpack family ++ " share encoding is empty")
  | length encodedHex /= length encodedBase64 =
      fail (Text.unpack family ++ " share encodings have different cardinality")
  | otherwise = do
      decodedHex <- traverse (parseCanonicalHex "PGP share ciphertext") encodedHex
      decodedBase64 <- traverse (parseCanonicalBase64 "PGP share ciphertext") encodedBase64
      if decodedHex == decodedBase64
        then pure encodedBase64
        else fail (Text.unpack family ++ " share encodings disagree")

parseEncryptedShare :: Text -> Parser PgpEncryptedShare
parseEncryptedShare encoded = do
  bytes <- parseCanonicalBase64 "PGP share ciphertext" encoded
  either (fail . show) pure (mkPgpEncryptedShare bytes)

parseBurnToken :: Text -> Parser BurnTokenCiphertext
parseBurnToken encoded = do
  bytes <- parseCanonicalBase64 "burn-recipient token ciphertext" encoded
  either (fail . show) pure (mkBurnTokenCiphertext bytes)

parseCanonicalBase64 :: Text -> Text -> Parser ByteString
parseCanonicalBase64 label encoded
  | encoded /= Text.strip encoded = fail (Text.unpack label ++ " must be canonical base64")
  | otherwise =
      case Base64.decode encodedBytes of
        Left _ -> fail (Text.unpack label ++ " must be canonical base64")
        Right decoded
          | Base64.encode decoded == encodedBytes -> pure decoded
          | otherwise -> fail (Text.unpack label ++ " must be canonical base64")
 where
  encodedBytes = TextEncoding.encodeUtf8 encoded

parseCanonicalHex :: Text -> Text -> Parser ByteString
parseCanonicalHex label encoded
  | encoded /= Text.strip encoded = fail invalid
  | Text.toLower encoded /= encoded = fail invalid
  | otherwise =
      case decodeLowerHex (Text.unpack encoded) of
        Just decoded -> pure decoded
        Nothing -> fail invalid
 where
  invalid = Text.unpack label ++ " must be canonical lowercase hexadecimal"

decodeLowerHex :: String -> Maybe ByteString
decodeLowerHex = fmap ByteString.pack . go
 where
  go [] = Just []
  go (high : low : rest) = do
    highNibble <- lowerHexNibble high
    lowNibble <- lowerHexNibble low
    ((highNibble * 16 + lowNibble) :) <$> go rest
  go [_] = Nothing

lowerHexNibble :: Char -> Maybe Word8
lowerHexNibble char
  | char >= '0' && char <= '9' =
      Just (fromIntegral (fromEnum char - fromEnum '0'))
  | char >= 'a' && char <= 'f' =
      Just (fromIntegral (fromEnum char - fromEnum 'a' + 10))
  | otherwise = Nothing
