{-# LANGUAGE DerivingStrategies #-}

-- | Effect-free ChaCha20-Poly1305 used by encrypted local state formats.
-- Callers own key derivation, nonce generation, and the identity-bound AAD.
module Prodbox.Crypto.Aead
  ( AeadError (..)
  , aeadNonceBytes
  , sealAead
  , openAead
  )
where

import Crypto.Cipher.ChaChaPoly1305 qualified as CCP
import Crypto.Error (CryptoError, CryptoFailable, eitherCryptoError)
import Data.ByteArray qualified as ByteArray
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS

data AeadError
  = AeadCipherFailed !CryptoError
  | AeadAuthenticationFailed
  deriving stock (Eq, Show)

aeadNonceBytes :: Int
aeadNonceBytes = 12

authTagBytes :: Int
authTagBytes = 16

sealAead
  :: ByteString
  -> ByteString
  -> ByteString
  -> ByteString
  -> Either AeadError ByteString
sealAead key nonce aad plaintext =
  case eitherCryptoError stateResult of
    Left cryptoErr -> Left (AeadCipherFailed cryptoErr)
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

openAead
  :: ByteString
  -> ByteString
  -> ByteString
  -> ByteString
  -> Either AeadError ByteString
openAead key nonce aad input
  | BS.length input < authTagBytes = Left AeadAuthenticationFailed
  | otherwise =
      case eitherCryptoError stateResult of
        Left cryptoErr -> Left (AeadCipherFailed cryptoErr)
        Right st0 ->
          let st1 = CCP.finalizeAAD (CCP.appendAAD aad st0)
              (ciphertext, tag) = BS.splitAt (BS.length input - authTagBytes) input
              (plaintext, st2) = CCP.decrypt ciphertext st1
              expectedTag = ByteArray.convert (CCP.finalize st2) :: ByteString
           in if ByteArray.constEq expectedTag tag
                then Right plaintext
                else Left AeadAuthenticationFailed
 where
  stateResult :: CryptoFailable CCP.State
  stateResult = do
    nonce' <- CCP.nonce12 nonce
    CCP.initialize key nonce'
