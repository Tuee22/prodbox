{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Ephemeral destination-only envelope for a short-lived EKS client
-- projection. Provider evidence may retain only 'EksClientAuthEnvelope'; the
-- destination secret exists solely in the host callback that consumes it.
module Prodbox.ControlPlane.EksClientAuthProjection
  ( EksClientAuthDestination
  , EksClientAuthPublicKey
  , EksClientAuthEnvelope
  , EksClientAuthProjection
  , EksClientAuthProjectionError (..)
  , prepareEksClientAuthDestination
  , eksClientAuthPublicKeyBytes
  , mkEksClientAuthPublicKey
  , mkEksClientAuthProjection
  , eksClientAuthAccountId
  , eksClientAuthRegion
  , eksClientAuthClusterName
  , eksClientAuthEndpoint
  , eksClientAuthCertificateAuthorityData
  , eksClientAuthBearerToken
  , eksClientAuthExpiresAtEpochSeconds
  , sealEksClientAuthProjection
  , openEksClientAuthProjection
  , encodeEksClientAuthEnvelope
  , decodeEksClientAuthEnvelope
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.Hash.SHA256 qualified as SHA256
import Crypto.PubKey.Curve25519 qualified as X25519
import Crypto.Random (getRandomBytes)
import Data.Bifunctor (first)
import Data.ByteArray qualified as ByteArray
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Crypto.Aead (aeadNonceBytes, openAead, sealAead)

data EksClientAuthDestination = EksClientAuthDestination
  { internalDestinationSecret :: !X25519.SecretKey
  , internalDestinationPublic :: !EksClientAuthPublicKey
  }

newtype EksClientAuthPublicKey = EksClientAuthPublicKey ByteString
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show EksClientAuthPublicKey where
  show key =
    "<eks-client-auth-public-key:"
      <> show (ByteString.length (eksClientAuthPublicKeyBytes key))
      <> " bytes>"

data EksClientAuthProjection = EksClientAuthProjection
  { internalAccountId :: !Text
  , internalRegion :: !Text
  , internalClusterName :: !Text
  , internalEndpoint :: !Text
  , internalCertificateAuthorityData :: !Text
  , internalBearerToken :: !Text
  , internalExpiresAtEpochSeconds :: !Integer
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show EksClientAuthProjection where
  show projection =
    "<eks-client-auth-projection:account="
      <> Text.unpack (internalAccountId projection)
      <> ",region="
      <> Text.unpack (internalRegion projection)
      <> ",cluster="
      <> Text.unpack (internalClusterName projection)
      <> ",expires="
      <> show (internalExpiresAtEpochSeconds projection)
      <> ">"

data EksClientAuthEnvelope = EksClientAuthEnvelope
  { internalEnvelopeVersion :: !Word16
  , internalEnvelopeDestination :: !ByteString
  , internalEnvelopeSender :: !ByteString
  , internalEnvelopeNonce :: !ByteString
  , internalEnvelopeCiphertext :: !ByteString
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show EksClientAuthEnvelope where
  show envelope =
    "<eks-client-auth-envelope:"
      <> show (ByteString.length (internalEnvelopeCiphertext envelope))
      <> " bytes>"

data EksClientAuthProjectionError
  = EksClientAuthFieldInvalid !Text
  | EksClientAuthPublicKeyInvalid
  | EksClientAuthEnvelopeInvalid
  | EksClientAuthEnvelopeTooLarge !Int !Int
  | EksClientAuthEnvelopeVersionUnsupported !Word16
  | EksClientAuthEnvelopeBindingMismatch
  | EksClientAuthCipherFailed
  deriving stock (Eq, Show)

projectionVersion :: Word16
projectionVersion = 1

maximumEnvelopeBytes :: Int
maximumEnvelopeBytes = 64 * 1024

prepareEksClientAuthDestination :: IO (EksClientAuthDestination, EksClientAuthPublicKey)
prepareEksClientAuthDestination = do
  secret <- X25519.generateSecretKey
  let public = EksClientAuthPublicKey (ByteArray.convert (X25519.toPublic secret))
  pure (EksClientAuthDestination secret public, public)

eksClientAuthPublicKeyBytes :: EksClientAuthPublicKey -> ByteString
eksClientAuthPublicKeyBytes (EksClientAuthPublicKey bytes) = bytes

mkEksClientAuthPublicKey
  :: ByteString -> Either EksClientAuthProjectionError EksClientAuthPublicKey
mkEksClientAuthPublicKey bytes = case X25519.publicKey bytes of
  CryptoFailed _ -> Left EksClientAuthPublicKeyInvalid
  CryptoPassed _ -> Right (EksClientAuthPublicKey bytes)

mkEksClientAuthProjection
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Integer
  -> Either EksClientAuthProjectionError EksClientAuthProjection
mkEksClientAuthProjection account region cluster endpoint caData bearer expires = do
  validate "account" 64 account
  validate "region" 64 region
  validate "cluster" 256 cluster
  validate "endpoint" 2048 endpoint
  validate "certificate-authority" 32768 caData
  validate "bearer" 16384 bearer
  if expires <= 0
    then Left (EksClientAuthFieldInvalid "expires")
    else
      Right
        EksClientAuthProjection
          { internalAccountId = account
          , internalRegion = region
          , internalClusterName = cluster
          , internalEndpoint = endpoint
          , internalCertificateAuthorityData = caData
          , internalBearerToken = bearer
          , internalExpiresAtEpochSeconds = expires
          }

eksClientAuthAccountId
  , eksClientAuthRegion
  , eksClientAuthClusterName
    :: EksClientAuthProjection -> Text
eksClientAuthAccountId = internalAccountId
eksClientAuthRegion = internalRegion
eksClientAuthClusterName = internalClusterName

eksClientAuthEndpoint
  , eksClientAuthCertificateAuthorityData
  , eksClientAuthBearerToken
    :: EksClientAuthProjection -> Text
eksClientAuthEndpoint = internalEndpoint
eksClientAuthCertificateAuthorityData = internalCertificateAuthorityData
eksClientAuthBearerToken = internalBearerToken

eksClientAuthExpiresAtEpochSeconds :: EksClientAuthProjection -> Integer
eksClientAuthExpiresAtEpochSeconds = internalExpiresAtEpochSeconds

sealEksClientAuthProjection
  :: EksClientAuthPublicKey
  -> EksClientAuthProjection
  -> IO (Either EksClientAuthProjectionError EksClientAuthEnvelope)
sealEksClientAuthProjection destination projection =
  case X25519.publicKey (eksClientAuthPublicKeyBytes destination) of
    CryptoFailed _ -> pure (Left EksClientAuthPublicKeyInvalid)
    CryptoPassed destinationKey -> do
      senderSecret <- X25519.generateSecretKey
      nonce <- getRandomBytes aeadNonceBytes
      let sender = ByteArray.convert (X25519.toPublic senderSecret)
          aad = envelopeAad (eksClientAuthPublicKeyBytes destination) sender
          key = deriveKey (X25519.dh destinationKey senderSecret) aad
          plaintext = LazyByteString.toStrict (serialise projection)
      pure $ do
        ciphertext <- first (const EksClientAuthCipherFailed) (sealAead key nonce aad plaintext)
        Right
          EksClientAuthEnvelope
            { internalEnvelopeVersion = projectionVersion
            , internalEnvelopeDestination = eksClientAuthPublicKeyBytes destination
            , internalEnvelopeSender = sender
            , internalEnvelopeNonce = nonce
            , internalEnvelopeCiphertext = ciphertext
            }

openEksClientAuthProjection
  :: EksClientAuthDestination
  -> EksClientAuthEnvelope
  -> Either EksClientAuthProjectionError EksClientAuthProjection
openEksClientAuthProjection destination envelope = do
  if internalEnvelopeVersion envelope /= projectionVersion
    then Left (EksClientAuthEnvelopeVersionUnsupported (internalEnvelopeVersion envelope))
    else Right ()
  let expected = eksClientAuthPublicKeyBytes (internalDestinationPublic destination)
  if internalEnvelopeDestination envelope /= expected
    then Left EksClientAuthEnvelopeBindingMismatch
    else Right ()
  sender <- case X25519.publicKey (internalEnvelopeSender envelope) of
    CryptoFailed _ -> Left EksClientAuthPublicKeyInvalid
    CryptoPassed key -> Right key
  let aad = envelopeAad expected (internalEnvelopeSender envelope)
      key = deriveKey (X25519.dh sender (internalDestinationSecret destination)) aad
  plaintext <-
    first
      (const EksClientAuthCipherFailed)
      (openAead key (internalEnvelopeNonce envelope) aad (internalEnvelopeCiphertext envelope))
  projection <-
    first (const EksClientAuthEnvelopeInvalid) (deserialiseOrFail (LazyByteString.fromStrict plaintext))
  if LazyByteString.toStrict (serialise projection) /= plaintext
    then Left EksClientAuthEnvelopeInvalid
    else
      mkEksClientAuthProjection
        (internalAccountId projection)
        (internalRegion projection)
        (internalClusterName projection)
        (internalEndpoint projection)
        (internalCertificateAuthorityData projection)
        (internalBearerToken projection)
        (internalExpiresAtEpochSeconds projection)

encodeEksClientAuthEnvelope :: EksClientAuthEnvelope -> ByteString
encodeEksClientAuthEnvelope = LazyByteString.toStrict . serialise

decodeEksClientAuthEnvelope
  :: ByteString -> Either EksClientAuthProjectionError EksClientAuthEnvelope
decodeEksClientAuthEnvelope bytes
  | ByteString.length bytes > maximumEnvelopeBytes =
      Left (EksClientAuthEnvelopeTooLarge (ByteString.length bytes) maximumEnvelopeBytes)
  | otherwise = do
      envelope <-
        first (const EksClientAuthEnvelopeInvalid) (deserialiseOrFail (LazyByteString.fromStrict bytes))
      if LazyByteString.toStrict (serialise envelope) == bytes
        then Right envelope
        else Left EksClientAuthEnvelopeInvalid

validate :: Text -> Int -> Text -> Either EksClientAuthProjectionError ()
validate field maximumLength value
  | Text.null value || Text.length value > maximumLength = Left (EksClientAuthFieldInvalid field)
  | Text.any (\c -> isControl c || isSpace c) value = Left (EksClientAuthFieldInvalid field)
  | otherwise = Right ()

envelopeAad :: ByteString -> ByteString -> ByteString
envelopeAad destination sender = "prodbox-eks-client-auth-v1\0" <> destination <> sender

deriveKey :: X25519.DhSecret -> ByteString -> ByteString
deriveKey shared aad = SHA256.hash ("prodbox-eks-client-auth-key-v1\0" <> ByteArray.convert shared <> aad)
