{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Invocation-only invite delivery. The Provider returns authenticated
-- ciphertext through the durable Authority; only the current caller holds the
-- receiver secret, with no serialisation or raw-key projection.
module Prodbox.Ses.InviteEvidence
  ( InviteMailReceiver
  , InviteMailPublicKey
  , newInviteMailReceiver
  , inviteMailReceiverPublicKey
  , mkInviteMailPublicKey
  , inviteMailPublicKeyText
  , retiredInviteMailEvidence
  , pendingInviteMailEvidence
  , maximumInviteMailPlaintextBytes
  , maximumInviteMailEvidenceCharacters
  , sealInviteMailEvidence
  , validateInviteMailEvidence
  , openInviteMailEvidence
  )
where

import Codec.Serialise (Serialise (..), deserialiseOrFail, serialise)
import Control.Monad (void)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.Hash.Algorithms (SHA256)
import Crypto.KDF.HKDF qualified as HKDF
import Crypto.PubKey.Curve25519 qualified as X25519
import Crypto.Random (getRandomBytes)
import Data.Bifunctor (first)
import Data.ByteArray qualified as ByteArray
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as BL
import Data.Char (isControl)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Word (Word8)
import Prodbox.Crypto.Aead (aeadNonceBytes, openAead, sealAead)

newtype InviteMailReceiver = InviteMailReceiver X25519.SecretKey

instance Show InviteMailReceiver where
  show _ = "<invite-mail-receiver>"

newtype InviteMailPublicKey = InviteMailPublicKey ByteString
  deriving (Eq)

instance Show InviteMailPublicKey where
  show _ = "<invite-mail-public-key>"

instance Serialise InviteMailPublicKey where
  encode = encode . inviteMailPublicKeyText
  decode = do
    raw <- decode
    either (const (fail "invalid invite-mail public key")) pure (mkInviteMailPublicKey raw)

type WireInviteEnvelope = (Word8, ByteString, ByteString, ByteString, ByteString)

newInviteMailReceiver :: IO InviteMailReceiver
newInviteMailReceiver = InviteMailReceiver <$> X25519.generateSecretKey

inviteMailReceiverPublicKey :: InviteMailReceiver -> InviteMailPublicKey
inviteMailReceiverPublicKey (InviteMailReceiver secret) =
  InviteMailPublicKey (ByteArray.convert (X25519.toPublic secret))

mkInviteMailPublicKey :: Text -> Either Text InviteMailPublicKey
mkInviteMailPublicKey raw
  | Text.length raw /= 44 = Left "invite-mail public key has the wrong size"
  | otherwise = do
      bytes <-
        first (const "invite-mail public key is not base64") (Base64.decode (Encoding.encodeUtf8 raw))
      if BS.length bytes /= 32 || Base64.encode bytes /= Encoding.encodeUtf8 raw
        then Left "invite-mail public key is not canonical"
        else do
          point <- publicKey bytes
          -- Validate low-order points before the Provider reads any mail. This
          -- fixed non-secret scalar is only a point-validity probe.
          probe <- cryptoValue (X25519.secretKey (BS.replicate 32 0))
          _ <- exchangeKey (X25519.dh point probe) domain
          Right (InviteMailPublicKey bytes)

inviteMailPublicKeyText :: InviteMailPublicKey -> Text
inviteMailPublicKeyText (InviteMailPublicKey bytes) = Encoding.decodeUtf8 (Base64.encode bytes)

retiredInviteMailEvidence :: Text
retiredInviteMailEvidence = "ses-invite:retired"

pendingInviteMailEvidence :: Text
pendingInviteMailEvidence = evidencePrefix <> "pending"

maximumInviteMailPlaintextBytes :: Int
maximumInviteMailPlaintextBytes = 2800

-- Derived from the largest canonical wire tuple, including the AEAD tag and
-- base64 expansion. This fits the existing shared 4096-character evidence cap.
maximumInviteMailEnvelopeBytes :: Int
maximumInviteMailEnvelopeBytes =
  BS.length
    ( encodeWire
        ( 1
        , BS.replicate 32 0
        , BS.replicate 32 0
        , BS.replicate aeadNonceBytes 0
        , BS.replicate (maximumInviteMailPlaintextBytes + 16) 0
        )
    )

maximumInviteMailEvidenceCharacters :: Int
maximumInviteMailEvidenceCharacters =
  Text.length evidencePrefix + 4 * ((maximumInviteMailEnvelopeBytes + 2) `div` 3)

sealInviteMailEvidence
  :: InviteMailPublicKey -> Text -> Text -> Text -> Text -> IO (Either Text Text)
sealInviteMailEvidence destination@(InviteMailPublicKey receiverBytes) bucket recipient objectKey link =
  case encodePlaintext objectKey link of
    Left refusal -> pure (Left refusal)
    Right plaintext -> do
      sender <- X25519.generateSecretKey
      nonce <- getRandomBytes aeadNonceBytes
      let senderBytes = ByteArray.convert (X25519.toPublic sender)
          aad = exchangeAad bucket recipient receiverBytes senderBytes
      pure $ do
        receiver <- publicKey receiverBytes
        key <- exchangeKey (X25519.dh receiver sender) aad
        ciphertext <- first (const "invite-mail encryption failed") (sealAead key nonce aad plaintext)
        let evidence =
              evidencePrefix
                <> Encoding.decodeUtf8
                  (Base64.encode (encodeWire (1, receiverBytes, senderBytes, nonce, ciphertext)))
        validateInviteMailEvidence destination evidence
        Right evidence

validateInviteMailEvidence :: InviteMailPublicKey -> Text -> Either Text ()
validateInviteMailEvidence destination evidence
  | evidence == pendingInviteMailEvidence = Right ()
  | otherwise = void (decodeEnvelope destination evidence)

openInviteMailEvidence
  :: InviteMailReceiver -> Text -> Text -> Text -> Either Text (Maybe (Text, Text))
openInviteMailEvidence receiver@(InviteMailReceiver secret) bucket recipient evidence
  | evidence == pendingInviteMailEvidence = Right Nothing
  | otherwise = do
      (_, receiverBytes, senderBytes, nonce, ciphertext) <-
        decodeEnvelope (inviteMailReceiverPublicKey receiver) evidence
      sender <- publicKey senderBytes
      let aad = exchangeAad bucket recipient receiverBytes senderBytes
      key <- exchangeKey (X25519.dh sender secret) aad
      plaintext <- first (const "invite-mail authentication failed") (openAead key nonce aad ciphertext)
      if BS.length plaintext > maximumInviteMailPlaintextBytes
        then Left "invite-mail plaintext exceeds its bound"
        else do
          decoded <- decodeCanonical plaintext
          _ <- encodePlaintext (fst decoded) (snd decoded)
          Right (Just decoded)

decodeEnvelope :: InviteMailPublicKey -> Text -> Either Text WireInviteEnvelope
decodeEnvelope (InviteMailPublicKey expectedReceiver) evidence
  | Text.length evidence > maximumInviteMailEvidenceCharacters =
      Left "invite-mail envelope exceeds its bound"
  | otherwise = do
      encoded <-
        maybe (Left "invite-mail evidence is not sealed") Right (Text.stripPrefix evidencePrefix evidence)
      bytes <-
        first (const "invite-mail envelope is not base64") (Base64.decode (Encoding.encodeUtf8 encoded))
      if BS.length bytes > maximumInviteMailEnvelopeBytes
        || Base64.encode bytes /= Encoding.encodeUtf8 encoded
        then Left "invite-mail envelope is not canonical"
        else do
          wire@(version, receiverBytes, senderBytes, nonce, ciphertext) <- decodeCanonical bytes
          if version /= 1
            || receiverBytes /= expectedReceiver
            || BS.length senderBytes /= 32
            || BS.length nonce /= aeadNonceBytes
            || BS.length ciphertext < 16
            || BS.length ciphertext > maximumInviteMailPlaintextBytes + 16
            then Left "invite-mail envelope binding is invalid"
            else do
              _ <- publicKey senderBytes
              Right wire

encodePlaintext :: Text -> Text -> Either Text ByteString
encodePlaintext objectKey link
  | Text.length objectKey > 1024 || Text.length link > maximumInviteMailPlaintextBytes =
      Left "invite-mail payload exceeds its bound"
  | not ("inbound/" `Text.isPrefixOf` objectKey)
      || Text.length objectKey <= 8
      || Text.any isControl objectKey
      || BS.length (Encoding.encodeUtf8 objectKey) > 1024 =
      Left "invite-mail object key is invalid"
  | not ("https://" `Text.isPrefixOf` link)
      || Text.any (<= ' ') link
      || not ("/login-actions/action-token?key=" `Text.isInfixOf` link) =
      Left "invite-mail action link is invalid"
  | BS.length plaintext > maximumInviteMailPlaintextBytes =
      Left "invite-mail payload exceeds its bound"
  | otherwise = Right plaintext
 where
  plaintext = BL.toStrict (serialise (objectKey, link))

encodeWire :: WireInviteEnvelope -> ByteString
encodeWire = BL.toStrict . serialise

decodeCanonical :: (Serialise value) => ByteString -> Either Text value
decodeCanonical bytes = do
  value <- first (const "invite-mail payload is not CBOR") (deserialiseOrFail (BL.fromStrict bytes))
  if BL.toStrict (serialise value) == bytes
    then Right value
    else Left "invite-mail payload is not canonical CBOR"

publicKey :: ByteString -> Either Text X25519.PublicKey
publicKey = cryptoValue . X25519.publicKey

cryptoValue :: CryptoFailable value -> Either Text value
cryptoValue result = case result of
  CryptoPassed value -> Right value
  CryptoFailed _ -> Left "invite-mail exchange key is invalid"

exchangeKey :: X25519.DhSecret -> ByteString -> Either Text ByteString
exchangeKey shared aad
  | ByteArray.constEq shared (BS.replicate 32 0) = Left "invite-mail exchange key has low order"
  | otherwise = Right (HKDF.expand (HKDF.extract domain shared :: HKDF.PRK SHA256) aad 32)

exchangeAad :: Text -> Text -> ByteString -> ByteString -> ByteString
exchangeAad bucket recipient receiver sender =
  BL.toStrict (serialise (domain, (1 :: Word8), bucket, recipient, receiver, sender))

domain :: ByteString
domain = "prodbox-ses-invite-delivery-v1"

evidencePrefix :: Text
evidencePrefix = "ses-invite-sealed:v1:"
