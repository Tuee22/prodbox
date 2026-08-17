{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Unit-only producer fixture for the hidden Provider side of the encrypted
-- EKS projection protocol.  Production tests consume the public facade; this
-- module mirrors only the versioned wire shape and is not part of the library.
module EksClientAuthProjectionFixture
  ( testEksClientAuthProjection
  , testEksClientAuthProjectionFixture
  )
where

import Codec.Serialise (Serialise, serialise)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.PubKey.Curve25519 qualified as X25519
import Crypto.Random (getRandomBytes)
import Data.ByteArray qualified as ByteArray
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.EksClientAuthProjection
import Prodbox.Crypto.Aead (aeadNonceBytes, sealAead)
import System.IO.Unsafe (unsafePerformIO)

data RawEksClientAuthProjection = RawEksClientAuthProjection
  !Text
  !Text
  !Text
  !Text
  !Text
  !Text
  !Text
  !Integer
  deriving stock (Generic)
  deriving anyclass (Serialise)

data RawEksClientAuthEnvelope = RawEksClientAuthEnvelope
  !Word16
  !ByteString
  !ByteString
  !ByteString
  !ByteString
  deriving stock (Generic)
  deriving anyclass (Serialise)

testEksClientAuthProjection
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Integer
  -> Either EksClientAuthProjectionError EksClientAuthProjection
testEksClientAuthProjection account region cluster clusterArn endpoint caData bearer expires =
  unsafePerformIO $ do
    fixture <-
      testEksClientAuthProjectionFixture
        account
        region
        cluster
        clusterArn
        endpoint
        caData
        bearer
        expires
    pure ((\(_, _, projection) -> projection) <$> fixture)
{-# NOINLINE testEksClientAuthProjection #-}

testEksClientAuthProjectionFixture
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Integer
  -> IO
       ( Either
           EksClientAuthProjectionError
           (EksClientAuthDestination, EksClientAuthEnvelope, EksClientAuthProjection)
       )
testEksClientAuthProjectionFixture account region cluster clusterArn endpoint caData bearer expires = do
  (destination, publicKey) <- prepareEksClientAuthDestination
  senderSecret <- X25519.generateSecretKey
  nonce <- getRandomBytes aeadNonceBytes
  let destinationBytes = eksClientAuthPublicKeyBytes publicKey
      senderBytes = ByteArray.convert (X25519.toPublic senderSecret)
      aad = envelopeAad destinationBytes senderBytes
      rawProjection =
        RawEksClientAuthProjection
          account
          region
          cluster
          clusterArn
          endpoint
          caData
          bearer
          expires
      plaintext = LazyByteString.toStrict (serialise rawProjection)
  pure $ do
    destinationKey <- case X25519.publicKey destinationBytes of
      CryptoFailed _ -> Left EksClientAuthPublicKeyInvalid
      CryptoPassed key -> Right key
    let key = deriveKey (X25519.dh destinationKey senderSecret) aad
    ciphertext <- either (const (Left EksClientAuthCipherFailed)) Right (sealAead key nonce aad plaintext)
    envelope <-
      decodeEksClientAuthEnvelope
        ( LazyByteString.toStrict
            ( serialise
                ( RawEksClientAuthEnvelope
                    2
                    destinationBytes
                    senderBytes
                    nonce
                    ciphertext
                )
            )
        )
    projection <- openEksClientAuthProjection destination envelope
    Right (destination, envelope, projection)

envelopeAad :: ByteString -> ByteString -> ByteString
envelopeAad destination sender =
  "prodbox-eks-client-auth-v2\0" <> destination <> sender

deriveKey :: X25519.DhSecret -> ByteString -> ByteString
deriveKey shared aad =
  ByteArray.convert
    ( hash
        ( "prodbox-eks-client-auth-key-v2\0"
            <> ByteArray.convert shared
            <> aad
        )
        :: Digest SHA256
    )
