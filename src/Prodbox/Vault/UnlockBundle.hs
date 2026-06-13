{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 1.36: the host-side encrypted Vault unlock bundle.
--
-- The unlock bundle is the single host-side artifact that lets a
-- torn-down-and-recreated cluster recover its Vault: it holds Vault's
-- unseal/recovery keys plus the initial root token, encrypted under an
-- operator-supplied password. Per
-- @documents\/engineering\/vault_doctrine.md@ §6 the bundle uses a real
-- password-based KDF (Argon2id) feeding an authenticated cipher
-- (ChaCha20-Poly1305) — never a bare hash. The operator password is the
-- ephemeral root of the unlock chain (§6); its only cleartext home is
-- @test-secrets.dhall@ in the test harness.
--
-- The on-disk artifact is always the ciphertext envelope produced by
-- 'encryptUnlockBundle'; the plaintext 'UnlockBundle' exists only in
-- memory after a successful 'decryptUnlockBundle'.
module Prodbox.Vault.UnlockBundle
  ( UnlockBundle (..)
  , UnlockBundleError (..)
  , encryptUnlockBundle
  , decryptUnlockBundle
  , renderUnlockBundleError
  )
where

import Crypto.Cipher.ChaChaPoly1305 qualified as CCP
import Crypto.Error (CryptoError, CryptoFailable, eitherCryptoError)
import Crypto.KDF.Argon2 qualified as Argon2
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
import Data.ByteArray (ScrubbedBytes)
import Data.ByteArray qualified as ByteArray
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word32)

-- | The plaintext recovery material captured once at @prodbox vault init@.
-- Serialized to JSON, encrypted into the on-disk envelope, and never
-- written to disk in the clear.
data UnlockBundle = UnlockBundle
  { unlockBundleClusterId :: Text
  , unlockBundleVaultAddressHint :: Text
  , unlockBundleCreatedAt :: Text
  , unlockBundleUnsealKeys :: [Text]
  , unlockBundleRecoveryKeys :: [Text]
  , unlockBundleInitialRootToken :: Text
  , unlockBundleFormatVersion :: Int
  }
  deriving (Eq, Show)

instance ToJSON UnlockBundle where
  toJSON bundle =
    object
      [ "cluster_id" .= unlockBundleClusterId bundle
      , "vault_address_hint" .= unlockBundleVaultAddressHint bundle
      , "created_at" .= unlockBundleCreatedAt bundle
      , "unseal_keys" .= unlockBundleUnsealKeys bundle
      , "recovery_keys" .= unlockBundleRecoveryKeys bundle
      , "initial_root_token" .= unlockBundleInitialRootToken bundle
      , "format_version" .= unlockBundleFormatVersion bundle
      ]

instance FromJSON UnlockBundle where
  parseJSON =
    withObject "UnlockBundle" $ \o ->
      UnlockBundle
        <$> o .: "cluster_id"
        <*> o .: "vault_address_hint"
        <*> o .: "created_at"
        <*> o .: "unseal_keys"
        <*> o .: "recovery_keys"
        <*> o .: "initial_root_token"
        <*> o .: "format_version"

-- | Failures that can occur encrypting or decrypting the bundle. None
-- carry secret material, so they are safe to surface to the operator.
data UnlockBundleError
  = -- | The Argon2id key derivation rejected its inputs.
    UnlockBundleKdfFailed CryptoError
  | -- | Cipher init / nonce construction failed.
    UnlockBundleCipherFailed CryptoError
  | -- | The authentication tag did not verify — wrong password or
    -- tampered ciphertext. The two are intentionally indistinguishable.
    UnlockBundleAuthFailed
  | -- | The on-disk envelope JSON was malformed or carried an unknown
    -- format/KDF, or a base64 field failed to decode.
    UnlockBundleMalformed String
  | -- | The decrypted plaintext did not parse as an 'UnlockBundle'.
    UnlockBundleDecodeFailed String
  deriving (Eq, Show)

-- | Operator-facing one-line rendering. Never includes secret values.
renderUnlockBundleError :: UnlockBundleError -> String
renderUnlockBundleError err = case err of
  UnlockBundleKdfFailed cryptoErr ->
    "unlock-bundle key derivation failed: " ++ show cryptoErr
  UnlockBundleCipherFailed cryptoErr ->
    "unlock-bundle cipher failed: " ++ show cryptoErr
  UnlockBundleAuthFailed ->
    "unlock-bundle authentication failed: wrong password or tampered bundle"
  UnlockBundleMalformed detail ->
    "unlock-bundle envelope is malformed: " ++ detail
  UnlockBundleDecodeFailed detail ->
    "unlock-bundle plaintext did not decode: " ++ detail

-- Envelope format constants (v1). The KDF parameters are stored in the
-- envelope so a future parameter change stays backward-decryptable.

envelopeFormatV1 :: Text
envelopeFormatV1 = "prodbox-vault-unlock-bundle-v1"

kdfNameArgon2id :: Text
kdfNameArgon2id = "argon2id"

argon2Options :: Argon2.Options
argon2Options =
  Argon2.Options
    { Argon2.iterations = 3
    , Argon2.memory = 65536 -- KiB (64 MiB)
    , Argon2.parallelism = 1
    , Argon2.variant = Argon2.Argon2id
    , Argon2.version = Argon2.Version13
    }

derivedKeyBytes :: Int
derivedKeyBytes = 32

saltBytes :: Int
saltBytes = 16

nonceBytes :: Int
nonceBytes = 12

authTagBytes :: Int
authTagBytes = 16

-- | Derive the 32-byte symmetric key from the operator password and salt
-- via Argon2id. The key is held in 'ScrubbedBytes' so it is zeroed when
-- garbage-collected rather than lingering in the heap.
deriveKey :: Argon2.Options -> Text -> ByteString -> Either UnlockBundleError ScrubbedBytes
deriveKey options password salt =
  mapKdf
    ( Argon2.hash
        options
        (TextEncoding.encodeUtf8 password)
        salt
        derivedKeyBytes
    )
 where
  mapKdf :: CryptoFailable ScrubbedBytes -> Either UnlockBundleError ScrubbedBytes
  mapKdf cf = case eitherCryptoError cf of
    Left cryptoErr -> Left (UnlockBundleKdfFailed cryptoErr)
    Right key -> Right key

-- | Encrypt @plaintext@ with the derived key under a fresh @nonce@,
-- returning @ciphertext <> authTag@.
aeadEncrypt :: ScrubbedBytes -> ByteString -> ByteString -> Either UnlockBundleError ByteString
aeadEncrypt key nonce plaintext = case eitherCryptoError stateResult of
  Left cryptoErr -> Left (UnlockBundleCipherFailed cryptoErr)
  Right st0 ->
    let st1 = CCP.finalizeAAD st0
        (ciphertext, st2) = CCP.encrypt plaintext st1
        tag = CCP.finalize st2
     in Right (ciphertext <> ByteArray.convert tag)
 where
  stateResult :: CryptoFailable CCP.State
  stateResult = do
    nonce' <- CCP.nonce12 nonce
    CCP.initialize key nonce'

-- | Decrypt @ciphertext <> authTag@ with the derived key under @nonce@,
-- verifying the authentication tag in constant time.
aeadDecrypt :: ScrubbedBytes -> ByteString -> ByteString -> Either UnlockBundleError ByteString
aeadDecrypt key nonce input
  | BS.length input < authTagBytes = Left UnlockBundleAuthFailed
  | otherwise = case eitherCryptoError stateResult of
      Left cryptoErr -> Left (UnlockBundleCipherFailed cryptoErr)
      Right st0 ->
        let st1 = CCP.finalizeAAD st0
            (ciphertext, tag) = BS.splitAt (BS.length input - authTagBytes) input
            (plaintext, st2) = CCP.decrypt ciphertext st1
            expectedTag = ByteArray.convert (CCP.finalize st2) :: ByteString
         in if ByteArray.constEq expectedTag tag
              then Right plaintext
              else Left UnlockBundleAuthFailed
 where
  stateResult :: CryptoFailable CCP.State
  stateResult = do
    nonce' <- CCP.nonce12 nonce
    CCP.initialize key nonce'

-- | Encrypt an 'UnlockBundle' under @password@, producing the on-disk
-- ciphertext envelope (a self-describing JSON document carrying the KDF
-- parameters, salt, nonce, and authenticated ciphertext). Fresh random
-- salt and nonce are generated per call.
encryptUnlockBundle :: Text -> UnlockBundle -> IO (Either UnlockBundleError ByteString)
encryptUnlockBundle password bundle = do
  salt <- getRandomBytes saltBytes
  nonce <- getRandomBytes nonceBytes
  pure $ do
    key <- deriveKey argon2Options password salt
    sealed <- aeadEncrypt key nonce (BL.toStrict (Aeson.encode bundle))
    Right (BL.toStrict (Aeson.encode (renderEnvelope salt nonce sealed)))

-- | Decrypt an on-disk envelope produced by 'encryptUnlockBundle' using
-- @password@. Pure: Argon2id derivation and AEAD verification have no
-- side effects, so callers can decrypt in memory and discard.
decryptUnlockBundle :: Text -> ByteString -> Either UnlockBundleError UnlockBundle
decryptUnlockBundle password envelopeBytes = do
  envelope <- case eitherDecodeStrict' envelopeBytes of
    Left detail -> Left (UnlockBundleMalformed detail)
    Right env -> Right env
  () <- requireEnvelope envelope
  salt <- decodeField "salt" (envelopeSalt envelope)
  nonce <- decodeField "nonce" (envelopeNonce envelope)
  sealed <- decodeField "ciphertext" (envelopeCiphertext envelope)
  key <- deriveKey (envelopeArgon2Options envelope) password salt
  plaintext <- aeadDecrypt key nonce sealed
  case eitherDecodeStrict' plaintext of
    Left detail -> Left (UnlockBundleDecodeFailed detail)
    Right decoded -> Right decoded
 where
  decodeField :: String -> Text -> Either UnlockBundleError ByteString
  decodeField name value =
    case B64.decode (TextEncoding.encodeUtf8 value) of
      Left detail -> Left (UnlockBundleMalformed (name ++ ": " ++ detail))
      Right bytes -> Right bytes

-- Internal self-describing envelope shape.

data UnlockBundleEnvelope = UnlockBundleEnvelope
  { envelopeFormat :: Text
  , envelopeKdf :: Text
  , envelopeKdfIterations :: Word32
  , envelopeKdfMemoryKiB :: Word32
  , envelopeKdfParallelism :: Word32
  , envelopeSalt :: Text
  , envelopeNonce :: Text
  , envelopeCiphertext :: Text
  }

instance ToJSON UnlockBundleEnvelope where
  toJSON env =
    object
      [ "format" .= envelopeFormat env
      , "kdf" .= envelopeKdf env
      , "kdf_iterations" .= envelopeKdfIterations env
      , "kdf_memory_kib" .= envelopeKdfMemoryKiB env
      , "kdf_parallelism" .= envelopeKdfParallelism env
      , "salt" .= envelopeSalt env
      , "nonce" .= envelopeNonce env
      , "ciphertext" .= envelopeCiphertext env
      ]

instance FromJSON UnlockBundleEnvelope where
  parseJSON =
    withObject "UnlockBundleEnvelope" $ \o ->
      UnlockBundleEnvelope
        <$> o .: "format"
        <*> o .: "kdf"
        <*> o .: "kdf_iterations"
        <*> o .: "kdf_memory_kib"
        <*> o .: "kdf_parallelism"
        <*> o .: "salt"
        <*> o .: "nonce"
        <*> o .: "ciphertext"

renderEnvelope :: ByteString -> ByteString -> ByteString -> UnlockBundleEnvelope
renderEnvelope salt nonce sealed =
  UnlockBundleEnvelope
    { envelopeFormat = envelopeFormatV1
    , envelopeKdf = kdfNameArgon2id
    , envelopeKdfIterations = Argon2.iterations argon2Options
    , envelopeKdfMemoryKiB = Argon2.memory argon2Options
    , envelopeKdfParallelism = Argon2.parallelism argon2Options
    , envelopeSalt = base64Text salt
    , envelopeNonce = base64Text nonce
    , envelopeCiphertext = base64Text sealed
    }

-- | Reconstruct the Argon2id options from the parameters stored in the
-- envelope, so a bundle written with different KDF parameters stays
-- decryptable. The variant and version are pinned to the v1 contract.
envelopeArgon2Options :: UnlockBundleEnvelope -> Argon2.Options
envelopeArgon2Options env =
  Argon2.Options
    { Argon2.iterations = envelopeKdfIterations env
    , Argon2.memory = envelopeKdfMemoryKiB env
    , Argon2.parallelism = envelopeKdfParallelism env
    , Argon2.variant = Argon2.Argon2id
    , Argon2.version = Argon2.Version13
    }

requireEnvelope :: UnlockBundleEnvelope -> Either UnlockBundleError ()
requireEnvelope env
  | envelopeFormat env /= envelopeFormatV1 =
      Left (UnlockBundleMalformed ("unknown format: " ++ Text.unpack (envelopeFormat env)))
  | envelopeKdf env /= kdfNameArgon2id =
      Left (UnlockBundleMalformed ("unknown kdf: " ++ Text.unpack (envelopeKdf env)))
  | otherwise = Right ()

base64Text :: ByteString -> Text
base64Text = TextEncoding.decodeUtf8 . B64.encode
