{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 3.17: Vault-Transit envelope encryption. Each secret-bearing
-- object (the master seed, the active Dhall, Pulumi backend state) is sealed
-- under a fresh random data-encryption key (DEK): the plaintext is encrypted
-- locally with a ChaCha20-Poly1305 AEAD, and the DEK is wrapped by Vault
-- Transit. The result is a self-describing @prodbox-envelope-v1@ JSON document.
--
-- The DEK wrap/unwrap is abstracted behind 'DekCipher' so the envelope format,
-- the local AEAD, and the AAD binding are unit-tested with a local cipher,
-- while production injects a Vault-Transit-backed cipher (the in-cluster
-- gateway daemon authenticates with Kubernetes auth). See
-- @documents/engineering/vault_doctrine.md@ §8 (Envelope encryption).
--
-- NOTE: the local AEAD helpers mirror those in "Prodbox.Vault.UnlockBundle";
-- factoring them into a shared @Prodbox.Crypto.Aead@ is a follow-up.
module Prodbox.Crypto.Envelope
  ( Envelope (..)
  , EnvelopeError (..)
  , DekCipher (..)
  , sealEnvelope
  , openEnvelope
  , renderEnvelopeError
  , insecureLocalDekCipher
  )
where

import Crypto.Cipher.ChaChaPoly1305 qualified as CCP
import Crypto.Error (CryptoError, CryptoFailable, eitherCryptoError)
import Crypto.Random (getRandomBytes)
import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , eitherDecodeStrict'
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.Aeson qualified as Aeson
import Data.ByteArray qualified as ByteArray
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding

-- | A pluggable data-encryption-key wrapper. Production binds these to Vault
-- Transit @encrypt@ / @decrypt@; tests inject a local symmetric cipher. The
-- wrapped form is opaque text (e.g. @vault:v1:...@).
data DekCipher = DekCipher
  { dekWrap :: ByteString -> IO (Either String Text)
  , dekUnwrap :: Text -> IO (Either String ByteString)
  }

-- | The self-describing on-disk envelope. The AAD that was bound into the AEAD
-- is stored for reference; the authenticated value comes from the AAD the
-- caller passes to 'openEnvelope', so an envelope cannot be opened under a
-- different identity.
data Envelope = Envelope
  { envelopeFormat :: Text
  , envelopeWrappedDek :: Text
  , envelopeNonce :: Text
  , envelopeAad :: Text
  , envelopeCiphertext :: Text
  }
  deriving (Eq, Show)

instance ToJSON Envelope where
  toJSON env =
    object
      [ "format" .= envelopeFormat env
      , "wrapped_dek" .= envelopeWrappedDek env
      , "nonce" .= envelopeNonce env
      , "aad" .= envelopeAad env
      , "ciphertext" .= envelopeCiphertext env
      ]

instance FromJSON Envelope where
  parseJSON =
    withObject "Envelope" $ \o ->
      Envelope
        <$> o .: "format"
        <*> o .: "wrapped_dek"
        <*> o .: "nonce"
        <*> o .: "aad"
        <*> o .: "ciphertext"

data EnvelopeError
  = EnvelopeCipherFailed CryptoError
  | EnvelopeAuthFailed
  | EnvelopeWrapFailed String
  | EnvelopeUnwrapFailed String
  | EnvelopeMalformed String
  deriving (Eq, Show)

renderEnvelopeError :: EnvelopeError -> String
renderEnvelopeError err = case err of
  EnvelopeCipherFailed cryptoErr -> "envelope cipher failed: " ++ show cryptoErr
  EnvelopeAuthFailed -> "envelope authentication failed: wrong AAD or tampered ciphertext"
  EnvelopeWrapFailed detail -> "envelope DEK wrap failed: " ++ detail
  EnvelopeUnwrapFailed detail -> "envelope DEK unwrap failed: " ++ detail
  EnvelopeMalformed detail -> "envelope is malformed: " ++ detail

envelopeFormatV1 :: Text
envelopeFormatV1 = "prodbox-envelope-v1"

dekBytes :: Int
dekBytes = 32

nonceBytes :: Int
nonceBytes = 12

authTagBytes :: Int
authTagBytes = 16

-- | Seal @plaintext@ under a fresh DEK, binding @aad@ into the AEAD and
-- wrapping the DEK with @cipher@. Returns the encoded envelope JSON.
sealEnvelope :: DekCipher -> ByteString -> ByteString -> IO (Either EnvelopeError ByteString)
sealEnvelope cipher aad plaintext = do
  dek <- getRandomBytes dekBytes
  nonce <- getRandomBytes nonceBytes
  case aeadSeal dek nonce aad plaintext of
    Left cipherErr -> pure (Left cipherErr)
    Right sealed -> do
      wrapResult <- dekWrap cipher dek
      pure $ case wrapResult of
        Left detail -> Left (EnvelopeWrapFailed detail)
        Right wrappedDek ->
          Right
            ( BL.toStrict
                ( Aeson.encode
                    Envelope
                      { envelopeFormat = envelopeFormatV1
                      , envelopeWrappedDek = wrappedDek
                      , envelopeNonce = base64Text nonce
                      , envelopeAad = base64Text aad
                      , envelopeCiphertext = base64Text sealed
                      }
                )
            )

-- | Open an envelope, authenticating it against @expectedAad@. A mismatched
-- AAD, a tampered ciphertext, or a failed DEK unwrap all fail closed.
openEnvelope :: DekCipher -> ByteString -> ByteString -> IO (Either EnvelopeError ByteString)
openEnvelope cipher expectedAad envelopeBytes =
  case decodeEnvelope envelopeBytes of
    Left err -> pure (Left err)
    Right (nonce, sealed, wrappedDek) -> do
      unwrapResult <- dekUnwrap cipher wrappedDek
      pure $ case unwrapResult of
        Left detail -> Left (EnvelopeUnwrapFailed detail)
        Right dek -> aeadOpen dek nonce expectedAad sealed

decodeEnvelope :: ByteString -> Either EnvelopeError (ByteString, ByteString, Text)
decodeEnvelope envelopeBytes = do
  env <- case eitherDecodeStrict' envelopeBytes of
    Left detail -> Left (EnvelopeMalformed detail)
    Right value -> Right value
  if envelopeFormat env /= envelopeFormatV1
    then Left (EnvelopeMalformed ("unknown format: " ++ Text.unpack (envelopeFormat env)))
    else do
      nonce <- decodeField "nonce" (envelopeNonce env)
      sealed <- decodeField "ciphertext" (envelopeCiphertext env)
      Right (nonce, sealed, envelopeWrappedDek env)
 where
  decodeField :: String -> Text -> Either EnvelopeError ByteString
  decodeField fieldName value =
    case B64.decode (TextEncoding.encodeUtf8 value) of
      Left detail -> Left (EnvelopeMalformed (fieldName ++ ": " ++ detail))
      Right bytes -> Right bytes

aeadSeal :: ByteString -> ByteString -> ByteString -> ByteString -> Either EnvelopeError ByteString
aeadSeal key nonce aad plaintext = case eitherCryptoError stateResult of
  Left cryptoErr -> Left (EnvelopeCipherFailed cryptoErr)
  Right st0 ->
    let st1 = CCP.finalizeAAD (CCP.appendAAD aad st0)
        (ciphertext, st2) = CCP.encrypt plaintext st1
        tag = CCP.finalize st2
     in Right (ciphertext <> ByteArray.convert tag)
 where
  stateResult :: CryptoFailable CCP.State
  stateResult = do
    nonce' <- CCP.nonce12 nonce
    CCP.initialize key nonce'

aeadOpen :: ByteString -> ByteString -> ByteString -> ByteString -> Either EnvelopeError ByteString
aeadOpen key nonce aad input
  | BS.length input < authTagBytes = Left EnvelopeAuthFailed
  | otherwise = case eitherCryptoError stateResult of
      Left cryptoErr -> Left (EnvelopeCipherFailed cryptoErr)
      Right st0 ->
        let st1 = CCP.finalizeAAD (CCP.appendAAD aad st0)
            (ciphertext, tag) = BS.splitAt (BS.length input - authTagBytes) input
            (plaintext, st2) = CCP.decrypt ciphertext st1
            expectedTag = ByteArray.convert (CCP.finalize st2) :: ByteString
         in if ByteArray.constEq expectedTag tag
              then Right plaintext
              else Left EnvelopeAuthFailed
 where
  stateResult :: CryptoFailable CCP.State
  stateResult = do
    nonce' <- CCP.nonce12 nonce
    CCP.initialize key nonce'

base64Text :: ByteString -> Text
base64Text = TextEncoding.decodeUtf8 . B64.encode

-- | A LOCAL, INSECURE 'DekCipher' for tests and local development only: it
-- base64-encodes the data-encryption key with no protection at all.
-- Production MUST use a Vault-Transit-backed 'DekCipher'. Named loudly so it
-- can never be mistaken for the production wrap/unwrap path. It exists so the
-- envelope format, the local AEAD, and the AAD binding can be exercised
-- end-to-end without a live Vault.
insecureLocalDekCipher :: DekCipher
insecureLocalDekCipher =
  DekCipher
    { dekWrap = \dek -> pure (Right (base64Text dek))
    , dekUnwrap = \wrapped -> pure (B64.decode (TextEncoding.encodeUtf8 wrapped))
    }
