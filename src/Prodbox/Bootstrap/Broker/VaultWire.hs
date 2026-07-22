{-# LANGUAGE OverloadedStrings #-}

-- | Secret-safe decoding for the PGP-targeted Vault initialization response.
--
-- The legacy host workflow still decodes 'Prodbox.Vault.Client.InitResponse',
-- whose root-token field is printable plaintext.  The Broker must never use
-- that type: this decoder admits only canonical base64 ciphertext and projects
-- it immediately into opaque, redacting custody values.
module Prodbox.Bootstrap.Broker.VaultWire
  ( EncryptedVaultInitResponse
  , encryptedVaultInitShares
  , encryptedVaultInitBurnToken
  )
where

import Data.Aeson
  ( FromJSON (..)
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  )
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as Base64
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
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
      shamirShares <- objectValue .:? "keys_base64" .!= []
      recoveryShares <- objectValue .:? "recovery_keys_base64" .!= []
      encodedBurnToken <- objectValue .: "root_token"
      encodedShares <-
        case (shamirShares, recoveryShares) of
          ([], []) -> fail "encrypted Vault init response contains no PGP share ciphertext"
          (_ : _, _ : _) ->
            fail "encrypted Vault init response ambiguously contains two share families"
          (_ : _, []) -> pure shamirShares
          ([], _ : _) -> pure recoveryShares
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
  [ "keys_base64"
  , "recovery_keys_base64"
  , "root_token"
  ]

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
