{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Ciphertext-only DEK exchange between a selected Target Secret Agent and
-- the retained-home Target Secret Agent. The coordinating host sees only an
-- X25519 public key, a local-Transit-protected private-key token, an AEAD DEK
-- envelope, or a retained-home Transit ciphertext; it never receives a DEK.
module Prodbox.ControlPlane.TlsDekExchange
  ( TlsDekTransitBoundary (..)
  , TlsDekPrepared
  , TlsDekPublicKey
  , TlsDekEnvelope
  , TlsWrappedDek
  , TlsDekExchangeError (..)
  , tlsDekBytes
  , tlsDekPreparedPublicKey
  , tlsDekPublicKeyBytes
  , tlsWrappedDekText
  , mkTlsWrappedDek
  , prepareTlsDekExchange
  , sealTlsDekForDestination
  , wrapTlsDekAtRetainedHome
  , rewrapTlsDekFromRetainedHome
  , openTlsDekAtDestination
  )
where

import Codec.Serialise (Serialise, serialise)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.Hash.SHA256 qualified as SHA256
import Crypto.PubKey.Curve25519 qualified as X25519
import Crypto.Random (getRandomBytes)
import Data.Bifunctor (first)
import Data.ByteArray qualified as ByteArray
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Crypto.Aead
  ( AeadError
  , aeadNonceBytes
  , openAead
  , sealAead
  )

data TlsDekTransitBoundary m = TlsDekTransitBoundary
  { tlsDekTransitEncrypt :: ByteString -> m (Either Text Text)
  , tlsDekTransitDecrypt :: Text -> m (Either Text ByteString)
  }

data TlsDekPrepared = TlsDekPrepared
  { internalTlsDekPreparedPublicKey :: !TlsDekPublicKey
  , internalTlsDekPreparedPrivateToken :: !Text
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show TlsDekPrepared where
  show _ = "<tls-dek-prepared>"

newtype TlsDekPublicKey = TlsDekPublicKey ByteString
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show TlsDekPublicKey where
  show value =
    "<tls-dek-public-key:"
      <> show (ByteString.length (tlsDekPublicKeyBytes value))
      <> " bytes>"

data TlsDekEnvelope = TlsDekEnvelope
  { internalTlsDekEnvelopeVersion :: !Word16
  , internalTlsDekEnvelopeDestination :: !TlsDekPublicKey
  , internalTlsDekEnvelopeSender :: !ByteString
  , internalTlsDekEnvelopeNonce :: !ByteString
  , internalTlsDekEnvelopeCiphertext :: !ByteString
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show TlsDekEnvelope where
  show envelope =
    "<tls-dek-envelope:"
      <> show (ByteString.length (internalTlsDekEnvelopeCiphertext envelope))
      <> " bytes>"

newtype TlsWrappedDek = TlsWrappedDek Text
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show TlsWrappedDek where
  show _ = "<tls-wrapped-dek>"

data TlsDekExchangeError
  = TlsDekLengthInvalid !Int
  | TlsDekPublicKeyInvalid
  | TlsDekSecretKeyInvalid
  | TlsDekPrivateTokenInvalid
  | TlsDekPrivateTokenUnavailable
  | TlsDekEnvelopeBindingMismatch
  | TlsDekEnvelopeVersionUnsupported !Word16
  | TlsDekCipherFailed !AeadError
  | TlsDekTransitWrapUnavailable
  | TlsDekTransitUnwrapUnavailable
  | TlsDekWrappedCiphertextInvalid
  deriving stock (Eq, Show)

tlsDekBytes :: Int
tlsDekBytes = 32

tlsDekExchangeVersion :: Word16
tlsDekExchangeVersion = 1

tlsDekPreparedPublicKey :: TlsDekPrepared -> TlsDekPublicKey
tlsDekPreparedPublicKey = internalTlsDekPreparedPublicKey

tlsDekPublicKeyBytes :: TlsDekPublicKey -> ByteString
tlsDekPublicKeyBytes (TlsDekPublicKey bytes) = bytes

tlsWrappedDekText :: TlsWrappedDek -> Text
tlsWrappedDekText (TlsWrappedDek ciphertext) = ciphertext

mkTlsWrappedDek :: Text -> Either TlsDekExchangeError TlsWrappedDek
mkTlsWrappedDek ciphertext = do
  validateTransitCiphertext TlsDekWrappedCiphertextInvalid ciphertext
  Right (TlsWrappedDek ciphertext)

prepareTlsDekExchange
  :: TlsDekTransitBoundary IO
  -> IO (Either TlsDekExchangeError TlsDekPrepared)
prepareTlsDekExchange transit = do
  secret <- X25519.generateSecretKey
  let public = TlsDekPublicKey (ByteArray.convert (X25519.toPublic secret))
      protected =
        ByteString.concat
          [ privateTokenDomain
          , tlsDekPublicKeyBytes public
          , ByteArray.convert secret
          ]
  encrypted <- tlsDekTransitEncrypt transit protected
  pure $ do
    token <- first (const TlsDekPrivateTokenUnavailable) encrypted
    validateTransitCiphertext TlsDekPrivateTokenInvalid token
    Right (TlsDekPrepared public token)

sealTlsDekForDestination
  :: TlsDekPublicKey
  -> ByteString
  -> IO (Either TlsDekExchangeError TlsDekEnvelope)
sealTlsDekForDestination destination dek
  | ByteString.length dek /= tlsDekBytes =
      pure (Left (TlsDekLengthInvalid (ByteString.length dek)))
  | otherwise = case decodePublic destination of
      Left err -> pure (Left err)
      Right destinationKey -> do
        senderSecret <- X25519.generateSecretKey
        nonce <- getRandomBytes aeadNonceBytes
        let senderPublic = X25519.toPublic senderSecret
            senderBytes = ByteArray.convert senderPublic
            aad = exchangeAad destination senderBytes
            key = deriveExchangeKey (X25519.dh destinationKey senderSecret) aad
        pure $ do
          ciphertext <- first TlsDekCipherFailed (sealAead key nonce aad dek)
          Right
            TlsDekEnvelope
              { internalTlsDekEnvelopeVersion = tlsDekExchangeVersion
              , internalTlsDekEnvelopeDestination = destination
              , internalTlsDekEnvelopeSender = senderBytes
              , internalTlsDekEnvelopeNonce = nonce
              , internalTlsDekEnvelopeCiphertext = ciphertext
              }

wrapTlsDekAtRetainedHome
  :: TlsDekTransitBoundary IO
  -> TlsDekPrepared
  -> TlsDekEnvelope
  -> IO (Either TlsDekExchangeError TlsWrappedDek)
wrapTlsDekAtRetainedHome transit prepared envelope = do
  opened <- openTlsDekAtDestination transit prepared envelope
  case opened of
    Left err -> pure (Left err)
    Right dek -> do
      wrapped <- tlsDekTransitEncrypt transit (retainedDekDomain <> dek)
      pure $ do
        ciphertext <- first (const TlsDekTransitWrapUnavailable) wrapped
        validateTransitCiphertext TlsDekWrappedCiphertextInvalid ciphertext
        Right (TlsWrappedDek ciphertext)

rewrapTlsDekFromRetainedHome
  :: TlsDekTransitBoundary IO
  -> TlsWrappedDek
  -> TlsDekPublicKey
  -> IO (Either TlsDekExchangeError TlsDekEnvelope)
rewrapTlsDekFromRetainedHome transit wrapped destination = do
  decrypted <- tlsDekTransitDecrypt transit (tlsWrappedDekText wrapped)
  case decrypted of
    Left _ -> pure (Left TlsDekTransitUnwrapUnavailable)
    Right plaintext -> case ByteString.stripPrefix retainedDekDomain plaintext of
      Nothing -> pure (Left TlsDekWrappedCiphertextInvalid)
      Just dek
        | ByteString.length dek /= tlsDekBytes ->
            pure (Left (TlsDekLengthInvalid (ByteString.length dek)))
        | otherwise -> sealTlsDekForDestination destination dek

openTlsDekAtDestination
  :: TlsDekTransitBoundary IO
  -> TlsDekPrepared
  -> TlsDekEnvelope
  -> IO (Either TlsDekExchangeError ByteString)
openTlsDekAtDestination transit prepared envelope
  | internalTlsDekEnvelopeVersion envelope /= tlsDekExchangeVersion =
      pure
        ( Left
            ( TlsDekEnvelopeVersionUnsupported
                (internalTlsDekEnvelopeVersion envelope)
            )
        )
  | internalTlsDekEnvelopeDestination envelope
      /= internalTlsDekPreparedPublicKey prepared =
      pure (Left TlsDekEnvelopeBindingMismatch)
  | otherwise = do
      decrypted <-
        tlsDekTransitDecrypt transit (internalTlsDekPreparedPrivateToken prepared)
      pure $ do
        tokenBytes <- first (const TlsDekPrivateTokenUnavailable) decrypted
        secret <- decodePrivateToken prepared tokenBytes
        sender <-
          cryptoValue
            TlsDekPublicKeyInvalid
            (X25519.publicKey (internalTlsDekEnvelopeSender envelope))
        let aad =
              exchangeAad
                (internalTlsDekEnvelopeDestination envelope)
                (internalTlsDekEnvelopeSender envelope)
            key = deriveExchangeKey (X25519.dh sender secret) aad
        dek <-
          first
            TlsDekCipherFailed
            ( openAead
                key
                (internalTlsDekEnvelopeNonce envelope)
                aad
                (internalTlsDekEnvelopeCiphertext envelope)
            )
        if ByteString.length dek == tlsDekBytes
          then Right dek
          else Left (TlsDekLengthInvalid (ByteString.length dek))

decodePrivateToken
  :: TlsDekPrepared
  -> ByteString
  -> Either TlsDekExchangeError X25519.SecretKey
decodePrivateToken prepared bytes = do
  payload <-
    maybe
      (Left TlsDekPrivateTokenInvalid)
      Right
      (ByteString.stripPrefix privateTokenDomain bytes)
  let (publicBytes, secretBytes) = ByteString.splitAt tlsDekBytes payload
  if publicBytes /= tlsDekPublicKeyBytes (internalTlsDekPreparedPublicKey prepared)
    then Left TlsDekPrivateTokenInvalid
    else do
      secret <- cryptoValue TlsDekSecretKeyInvalid (X25519.secretKey secretBytes)
      if ByteArray.convert (X25519.toPublic secret) == publicBytes
        then Right secret
        else Left TlsDekPrivateTokenInvalid

decodePublic :: TlsDekPublicKey -> Either TlsDekExchangeError X25519.PublicKey
decodePublic =
  cryptoValue TlsDekPublicKeyInvalid
    . X25519.publicKey
    . tlsDekPublicKeyBytes

exchangeAad :: TlsDekPublicKey -> ByteString -> ByteString
exchangeAad destination sender =
  LazyByteString.toStrict
    ( serialise
        ( tlsDekExchangeVersion
        , exchangeDomain
        , tlsDekPublicKeyBytes destination
        , sender
        )
    )

deriveExchangeKey :: X25519.DhSecret -> ByteString -> ByteString
deriveExchangeKey shared aad =
  SHA256.hash (ByteArray.convert shared <> aad)

validateTransitCiphertext
  :: TlsDekExchangeError -> Text -> Either TlsDekExchangeError ()
validateTransitCiphertext err value
  | Text.length value > maximumTransitCiphertextChars = Left err
  | "vault:v" `Text.isPrefixOf` value = Right ()
  | otherwise = Left err

cryptoValue
  :: TlsDekExchangeError
  -> CryptoFailable value
  -> Either TlsDekExchangeError value
cryptoValue err result = case result of
  CryptoFailed _ -> Left err
  CryptoPassed value -> Right value

maximumTransitCiphertextChars :: Int
maximumTransitCiphertextChars = 16 * 1024

exchangeDomain :: ByteString
exchangeDomain = "prodbox-tls-dek-exchange-v1"

privateTokenDomain :: ByteString
privateTokenDomain = "prodbox-tls-dek-private-token-v1\NUL"

retainedDekDomain :: ByteString
retainedDekDomain = "prodbox-tls-retained-dek-v1\NUL"
