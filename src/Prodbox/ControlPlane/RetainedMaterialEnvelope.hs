{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Destination-only X25519 envelopes for the two retained material schemas.
--
-- A selected one-shot Target worker receives its private key and this envelope
-- only on the already-attested stdin stream.  The standing Authority carries
-- the public key, its digest, the ciphertext, and receipts; it never receives
-- the opening key or the decoded 'TargetSecretPayload'.  Constructors remain
-- private so the envelope cannot be repurposed as a generic decrypt service.
module Prodbox.ControlPlane.RetainedMaterialEnvelope
  ( RetainedDestinationKeyPair
  , RetainedDestinationPublicKey
  , RetainedDestinationEnvelope
  , RetainedDestinationEnvelopeError (..)
  , retainedDestinationEnvelopeMaximumBytes
  , retainedDestinationOpeningMaximumBytes
  , generateRetainedDestinationKeyPair
  , retainedDestinationPublicKey
  , mkRetainedDestinationPublicKey
  , retainedDestinationPublicKeyBytes
  , retainedDestinationPublicKeyDigest
  , sealRetainedDestinationEnvelope
  , encodeRetainedDestinationEnvelope
  , decodeRetainedDestinationEnvelope
  , encodeRetainedDestinationOpening
  , validateRetainedDestinationOpening
  , openRetainedDestinationOpening
  , openRetainedDestinationOpeningForGeneration
  , retainedEnvelopeOperationId
  , retainedEnvelopeSourceReceipt
  , retainedEnvelopeTarget
  , retainedEnvelopeGeneration
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless)
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
import Data.Word (Word16, Word8)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId (TargetAcmeEab, TargetSesSmtp)
  , TargetSecretPayload
  , targetSecretPayloadId
  , validateTargetSecretPayload
  )
import Prodbox.Crypto.Aead
  ( AeadError
  , aeadNonceBytes
  , openAead
  , sealAead
  )
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( RetainedMaterialRef
  , RetainedMaterialSchema
  , RetainedMaterialTarget
  , SRetainedMaterialSchema (SRetainedAcmeEabMaterial, SRetainedSesSmtpMaterial)
  , mkRetainedMaterialRef
  , mkRetainedMaterialTarget
  , retainedMaterialRefText
  , retainedMaterialTargetText
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  , mkCredentialGeneration
  , sha256TargetValueDigest
  )

type role RetainedDestinationKeyPair nominal

-- Intentionally has no Show/Serialise instance.  The opening key is emitted
-- only by 'encodeRetainedDestinationOpening' for direct attachment.
data RetainedDestinationKeyPair (schema :: RetainedMaterialSchema)
  = RetainedDestinationKeyPair
      !X25519.SecretKey
      !(RetainedDestinationPublicKey schema)

type role RetainedDestinationPublicKey nominal

newtype RetainedDestinationPublicKey (schema :: RetainedMaterialSchema)
  = RetainedDestinationPublicKey X25519.PublicKey
  deriving stock (Eq)

instance Show (RetainedDestinationPublicKey schema) where
  show value =
    "<retained-destination-public-key:"
      <> show (ByteString.length (retainedDestinationPublicKeyBytes value))
      <> " bytes>"

type role RetainedDestinationEnvelope nominal

data RetainedDestinationEnvelope (schema :: RetainedMaterialSchema)
  = RetainedDestinationEnvelope
  { internalEnvelopeOperationId :: !RetainedMaterialRef
  , internalEnvelopeSourceReceipt :: !RetainedMaterialRef
  , internalEnvelopeTarget :: !(RetainedMaterialTarget schema)
  , internalEnvelopeGeneration :: !CredentialGeneration
  , internalEnvelopeTargetPublicKey :: !(RetainedDestinationPublicKey schema)
  , internalEnvelopeSenderPublicKey :: !X25519.PublicKey
  , internalEnvelopeNonce :: !ByteString
  , internalEnvelopeCiphertext :: !ByteString
  }

instance Show (RetainedDestinationEnvelope schema) where
  show envelope =
    "<retained-destination-envelope:ciphertext="
      <> show (ByteString.length (internalEnvelopeCiphertext envelope))
      <> " bytes>"

data RetainedDestinationEnvelopeError
  = RetainedDestinationPayloadSchemaMismatch
  | RetainedDestinationPayloadInvalid
  | RetainedDestinationPublicKeyInvalid
  | RetainedDestinationSecretKeyInvalid
  | RetainedDestinationCipherFailed !AeadError
  | RetainedDestinationEnvelopeTooLarge !Int !Int
  | RetainedDestinationOpeningTooLarge !Int !Int
  | RetainedDestinationEnvelopeDecodeFailed
  | RetainedDestinationOpeningDecodeFailed
  | RetainedDestinationUnsupportedVersion !Word16
  | RetainedDestinationNonCanonical
  | RetainedDestinationBindingMismatch
  | RetainedDestinationGenerationInvalid
  deriving stock (Eq, Show)

data WireRetainedDestinationBinding = WireRetainedDestinationBinding
  { wireBindingVersion :: !Word16
  , wireBindingSchema :: !Word8
  , wireBindingOperationId :: !Text
  , wireBindingSourceReceipt :: !Text
  , wireBindingTarget :: !Text
  , wireBindingGeneration :: !Natural
  , wireBindingTargetPublicKey :: !ByteString
  , wireBindingSenderPublicKey :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireRetainedDestinationEnvelope = WireRetainedDestinationEnvelope
  { wireEnvelopeBinding :: !WireRetainedDestinationBinding
  , wireEnvelopeNonce :: !ByteString
  , wireEnvelopeCiphertext :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireRetainedDestinationOpening = WireRetainedDestinationOpening
  { wireOpeningVersion :: !Word16
  , wireOpeningSecretKey :: !ByteString
  , wireOpeningEnvelope :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

retainedDestinationVersion :: Word16
retainedDestinationVersion = 1

retainedDestinationEnvelopeMaximumBytes :: Int
retainedDestinationEnvelopeMaximumBytes = 60 * 1024

retainedDestinationOpeningMaximumBytes :: Int
retainedDestinationOpeningMaximumBytes = 64 * 1024

generateRetainedDestinationKeyPair
  :: IO (RetainedDestinationKeyPair schema)
generateRetainedDestinationKeyPair = do
  secret <- X25519.generateSecretKey
  pure
    ( RetainedDestinationKeyPair
        secret
        (RetainedDestinationPublicKey (X25519.toPublic secret))
    )

retainedDestinationPublicKey
  :: RetainedDestinationKeyPair schema
  -> RetainedDestinationPublicKey schema
retainedDestinationPublicKey (RetainedDestinationKeyPair _ publicKeyValue) =
  publicKeyValue

mkRetainedDestinationPublicKey
  :: ByteString
  -> Either RetainedDestinationEnvelopeError (RetainedDestinationPublicKey schema)
mkRetainedDestinationPublicKey bytes =
  case X25519.publicKey bytes of
    CryptoFailed _ -> Left RetainedDestinationPublicKeyInvalid
    CryptoPassed value -> Right (RetainedDestinationPublicKey value)

retainedDestinationPublicKeyBytes
  :: RetainedDestinationPublicKey schema -> ByteString
retainedDestinationPublicKeyBytes (RetainedDestinationPublicKey publicKeyValue) =
  ByteArray.convert publicKeyValue

retainedDestinationPublicKeyDigest
  :: RetainedDestinationPublicKey schema -> TargetValueDigest
retainedDestinationPublicKeyDigest =
  sha256TargetValueDigest . retainedDestinationPublicKeyBytes

sealRetainedDestinationEnvelope
  :: SRetainedMaterialSchema schema
  -> RetainedMaterialRef
  -> RetainedMaterialRef
  -> RetainedMaterialTarget schema
  -> CredentialGeneration
  -> RetainedDestinationPublicKey schema
  -> TargetSecretPayload
  -> IO
       ( Either
           RetainedDestinationEnvelopeError
           (RetainedDestinationEnvelope schema)
       )
sealRetainedDestinationEnvelope schema operationId sourceReceipt target generation targetPublic payload =
  case validatePayload schema payload of
    Left err -> pure (Left err)
    Right () -> do
      senderSecret <- X25519.generateSecretKey
      nonce <- getRandomBytes aeadNonceBytes
      let senderPublic = X25519.toPublic senderSecret
          binding =
            bindingWire
              schema
              operationId
              sourceReceipt
              target
              generation
              targetPublic
              senderPublic
          aad = LazyByteString.toStrict (serialise binding)
          key = destinationKey (X25519.dh (unwrapPublic targetPublic) senderSecret) aad
          plaintext = LazyByteString.toStrict (serialise payload)
      pure $ do
        ciphertext <- first RetainedDestinationCipherFailed (sealAead key nonce aad plaintext)
        let envelope =
              RetainedDestinationEnvelope
                { internalEnvelopeOperationId = operationId
                , internalEnvelopeSourceReceipt = sourceReceipt
                , internalEnvelopeTarget = target
                , internalEnvelopeGeneration = generation
                , internalEnvelopeTargetPublicKey = targetPublic
                , internalEnvelopeSenderPublicKey = senderPublic
                , internalEnvelopeNonce = nonce
                , internalEnvelopeCiphertext = ciphertext
                }
        encoded <- encodeRetainedDestinationEnvelope schema envelope
        unless
          (ByteString.length encoded <= retainedDestinationEnvelopeMaximumBytes)
          ( Left
              ( RetainedDestinationEnvelopeTooLarge
                  (ByteString.length encoded)
                  retainedDestinationEnvelopeMaximumBytes
              )
          )
        Right envelope

encodeRetainedDestinationEnvelope
  :: SRetainedMaterialSchema schema
  -> RetainedDestinationEnvelope schema
  -> Either RetainedDestinationEnvelopeError ByteString
encodeRetainedDestinationEnvelope schema envelope = do
  let encoded =
        LazyByteString.toStrict
          ( serialise
              WireRetainedDestinationEnvelope
                { wireEnvelopeBinding = envelopeBinding schema envelope
                , wireEnvelopeNonce = internalEnvelopeNonce envelope
                , wireEnvelopeCiphertext = internalEnvelopeCiphertext envelope
                }
          )
  unless
    (ByteString.length encoded <= retainedDestinationEnvelopeMaximumBytes)
    ( Left
        ( RetainedDestinationEnvelopeTooLarge
            (ByteString.length encoded)
            retainedDestinationEnvelopeMaximumBytes
        )
    )
  Right encoded

decodeRetainedDestinationEnvelope
  :: SRetainedMaterialSchema schema
  -> ByteString
  -> Either RetainedDestinationEnvelopeError (RetainedDestinationEnvelope schema)
decodeRetainedDestinationEnvelope schema bytes =
  decodeEnvelopeWire bytes >>= envelopeFromWire schema

-- | Encode the one secret-bearing Target-worker input.  The private key is
-- intentionally colocated with the exact envelope and can be consumed only by
-- 'openRetainedDestinationOpening'; it is never part of an Authority command,
-- event, aggregate, receipt, log, or Adapter object.
encodeRetainedDestinationOpening
  :: SRetainedMaterialSchema schema
  -> RetainedDestinationKeyPair schema
  -> RetainedDestinationEnvelope schema
  -> Either RetainedDestinationEnvelopeError ByteString
encodeRetainedDestinationOpening schema keyPair envelope = do
  unless
    (retainedDestinationPublicKey keyPair == internalEnvelopeTargetPublicKey envelope)
    (Left RetainedDestinationBindingMismatch)
  envelopeBytes <- encodeRetainedDestinationEnvelope schema envelope
  let secretBytes = case keyPair of
        RetainedDestinationKeyPair secret _ -> ByteArray.convert secret
      encoded =
        LazyByteString.toStrict
          ( serialise
              WireRetainedDestinationOpening
                { wireOpeningVersion = retainedDestinationVersion
                , wireOpeningSecretKey = secretBytes
                , wireOpeningEnvelope = envelopeBytes
                }
          )
  unless
    (ByteString.length encoded <= retainedDestinationOpeningMaximumBytes)
    ( Left
        ( RetainedDestinationOpeningTooLarge
            (ByteString.length encoded)
            retainedDestinationOpeningMaximumBytes
        )
    )
  Right encoded

openRetainedDestinationOpening
  :: SRetainedMaterialSchema schema
  -> RetainedMaterialTarget schema
  -> CredentialGeneration
  -> ByteString
  -> Either RetainedDestinationEnvelopeError TargetSecretPayload
openRetainedDestinationOpening schema expectedTarget expectedGeneration bytes = do
  (target, payload) <- openRetainedDestinationOpeningInternal schema expectedGeneration bytes
  unless (target == expectedTarget) (Left RetainedDestinationBindingMismatch)
  Right payload

-- | Validate the canonical opening frame and its destination key/generation
-- binding without decrypting the payload.  Coordinators use this before
-- attaching stdin, so a malformed or schema-substituted frame never reaches
-- the selected worker and plaintext is not exposed during validation.
validateRetainedDestinationOpening
  :: SRetainedMaterialSchema schema
  -> CredentialGeneration
  -> ByteString
  -> Either RetainedDestinationEnvelopeError ()
validateRetainedDestinationOpening schema expectedGeneration bytes = do
  opening <- decodeOpening bytes
  secret <-
    cryptoValue
      RetainedDestinationSecretKeyInvalid
      (X25519.secretKey (wireOpeningSecretKey opening))
  envelopeWire <- decodeEnvelopeWire (wireOpeningEnvelope opening)
  envelope <- envelopeFromWire schema envelopeWire
  unless
    ( internalEnvelopeGeneration envelope == expectedGeneration
        && X25519.toPublic secret
          == unwrapPublic (internalEnvelopeTargetPublicKey envelope)
    )
    (Left RetainedDestinationBindingMismatch)

-- | Target-worker opening when the registered target coordinate is carried by
-- the retained envelope rather than chosen by the material sink.  Schema,
-- generation, key-pair, canonical framing, AEAD binding, and payload schema
-- are still checked exactly.  The returned target is deliberately discarded;
-- callers receive only the closed SES/EAB payload selected by @schema@.
openRetainedDestinationOpeningForGeneration
  :: SRetainedMaterialSchema schema
  -> CredentialGeneration
  -> ByteString
  -> Either RetainedDestinationEnvelopeError TargetSecretPayload
openRetainedDestinationOpeningForGeneration schema expectedGeneration bytes =
  snd <$> openRetainedDestinationOpeningInternal schema expectedGeneration bytes

openRetainedDestinationOpeningInternal
  :: SRetainedMaterialSchema schema
  -> CredentialGeneration
  -> ByteString
  -> Either
       RetainedDestinationEnvelopeError
       (RetainedMaterialTarget schema, TargetSecretPayload)
openRetainedDestinationOpeningInternal schema expectedGeneration bytes = do
  unless
    (ByteString.length bytes <= retainedDestinationOpeningMaximumBytes)
    ( Left
        ( RetainedDestinationOpeningTooLarge
            (ByteString.length bytes)
            retainedDestinationOpeningMaximumBytes
        )
    )
  opening <- decodeOpening bytes
  secret <-
    cryptoValue
      RetainedDestinationSecretKeyInvalid
      (X25519.secretKey (wireOpeningSecretKey opening))
  envelopeWire <- decodeEnvelopeWire (wireOpeningEnvelope opening)
  envelope <- envelopeFromWire schema envelopeWire
  unless
    ( internalEnvelopeGeneration envelope == expectedGeneration
        && X25519.toPublic secret
          == unwrapPublic (internalEnvelopeTargetPublicKey envelope)
    )
    (Left RetainedDestinationBindingMismatch)
  let binding = wireEnvelopeBinding envelopeWire
      aad = LazyByteString.toStrict (serialise binding)
      key = destinationKey (X25519.dh (internalEnvelopeSenderPublicKey envelope) secret) aad
  plaintext <-
    first
      RetainedDestinationCipherFailed
      ( openAead
          key
          (internalEnvelopeNonce envelope)
          aad
          (internalEnvelopeCiphertext envelope)
      )
  payload <- case deserialiseOrFail (LazyByteString.fromStrict plaintext) of
    Left _ -> Left RetainedDestinationPayloadInvalid
    Right decoded -> Right decoded
  unless
    (LazyByteString.toStrict (serialise payload) == plaintext)
    (Left RetainedDestinationNonCanonical)
  validatePayload schema payload
  Right (internalEnvelopeTarget envelope, payload)

retainedEnvelopeOperationId
  :: RetainedDestinationEnvelope schema -> RetainedMaterialRef
retainedEnvelopeOperationId = internalEnvelopeOperationId

retainedEnvelopeSourceReceipt
  :: RetainedDestinationEnvelope schema -> RetainedMaterialRef
retainedEnvelopeSourceReceipt = internalEnvelopeSourceReceipt

retainedEnvelopeTarget
  :: RetainedDestinationEnvelope schema -> RetainedMaterialTarget schema
retainedEnvelopeTarget = internalEnvelopeTarget

retainedEnvelopeGeneration
  :: RetainedDestinationEnvelope schema -> CredentialGeneration
retainedEnvelopeGeneration = internalEnvelopeGeneration

decodeOpening
  :: ByteString
  -> Either RetainedDestinationEnvelopeError WireRetainedDestinationOpening
decodeOpening bytes = do
  unless
    (ByteString.length bytes <= retainedDestinationOpeningMaximumBytes)
    ( Left
        ( RetainedDestinationOpeningTooLarge
            (ByteString.length bytes)
            retainedDestinationOpeningMaximumBytes
        )
    )
  opening <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Left _ -> Left RetainedDestinationOpeningDecodeFailed
    Right decoded -> Right decoded
  unless
    (wireOpeningVersion opening == retainedDestinationVersion)
    (Left (RetainedDestinationUnsupportedVersion (wireOpeningVersion opening)))
  unless
    (LazyByteString.toStrict (serialise opening) == bytes)
    (Left RetainedDestinationNonCanonical)
  Right opening

decodeEnvelopeWire
  :: ByteString
  -> Either RetainedDestinationEnvelopeError WireRetainedDestinationEnvelope
decodeEnvelopeWire bytes = do
  unless
    (ByteString.length bytes <= retainedDestinationEnvelopeMaximumBytes)
    ( Left
        ( RetainedDestinationEnvelopeTooLarge
            (ByteString.length bytes)
            retainedDestinationEnvelopeMaximumBytes
        )
    )
  wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Left _ -> Left RetainedDestinationEnvelopeDecodeFailed
    Right decoded -> Right decoded
  unless
    (LazyByteString.toStrict (serialise wire) == bytes)
    (Left RetainedDestinationNonCanonical)
  Right wire

envelopeFromWire
  :: SRetainedMaterialSchema schema
  -> WireRetainedDestinationEnvelope
  -> Either
       RetainedDestinationEnvelopeError
       (RetainedDestinationEnvelope schema)
envelopeFromWire schema wire = do
  let binding = wireEnvelopeBinding wire
  unless
    (wireBindingVersion binding == retainedDestinationVersion)
    (Left (RetainedDestinationUnsupportedVersion (wireBindingVersion binding)))
  unless
    (wireBindingSchema binding == schemaTag schema)
    (Left RetainedDestinationBindingMismatch)
  operationId <- refValue (wireBindingOperationId binding)
  sourceReceipt <- refValue (wireBindingSourceReceipt binding)
  target <- targetValue schema (wireBindingTarget binding)
  generation <-
    first
      (const RetainedDestinationGenerationInvalid)
      (mkCredentialGeneration (wireBindingGeneration binding))
  targetPublic <-
    RetainedDestinationPublicKey
      <$> cryptoValue
        RetainedDestinationPublicKeyInvalid
        (X25519.publicKey (wireBindingTargetPublicKey binding))
  senderPublic <-
    cryptoValue
      RetainedDestinationPublicKeyInvalid
      (X25519.publicKey (wireBindingSenderPublicKey binding))
  unless
    (ByteString.length (wireEnvelopeNonce wire) == aeadNonceBytes)
    (Left RetainedDestinationBindingMismatch)
  unless
    ( not (ByteString.null (wireEnvelopeCiphertext wire))
        && ByteString.length (wireEnvelopeCiphertext wire) <= 80 * 1024
    )
    (Left RetainedDestinationBindingMismatch)
  Right
    RetainedDestinationEnvelope
      { internalEnvelopeOperationId = operationId
      , internalEnvelopeSourceReceipt = sourceReceipt
      , internalEnvelopeTarget = target
      , internalEnvelopeGeneration = generation
      , internalEnvelopeTargetPublicKey = targetPublic
      , internalEnvelopeSenderPublicKey = senderPublic
      , internalEnvelopeNonce = wireEnvelopeNonce wire
      , internalEnvelopeCiphertext = wireEnvelopeCiphertext wire
      }

envelopeBinding
  :: SRetainedMaterialSchema schema
  -> RetainedDestinationEnvelope schema
  -> WireRetainedDestinationBinding
envelopeBinding schema envelope =
  bindingWire
    schema
    (internalEnvelopeOperationId envelope)
    (internalEnvelopeSourceReceipt envelope)
    (internalEnvelopeTarget envelope)
    (internalEnvelopeGeneration envelope)
    (internalEnvelopeTargetPublicKey envelope)
    (internalEnvelopeSenderPublicKey envelope)

bindingWire
  :: SRetainedMaterialSchema schema
  -> RetainedMaterialRef
  -> RetainedMaterialRef
  -> RetainedMaterialTarget schema
  -> CredentialGeneration
  -> RetainedDestinationPublicKey schema
  -> X25519.PublicKey
  -> WireRetainedDestinationBinding
bindingWire schema operationId sourceReceipt target generation targetPublic senderPublic =
  WireRetainedDestinationBinding
    { wireBindingVersion = retainedDestinationVersion
    , wireBindingSchema = schemaTag schema
    , wireBindingOperationId = retainedMaterialRefText operationId
    , wireBindingSourceReceipt = retainedMaterialRefText sourceReceipt
    , wireBindingTarget = retainedMaterialTargetText target
    , wireBindingGeneration = credentialGenerationValue generation
    , wireBindingTargetPublicKey = retainedDestinationPublicKeyBytes targetPublic
    , wireBindingSenderPublicKey = ByteArray.convert senderPublic
    }

destinationKey :: X25519.DhSecret -> ByteString -> ByteString
destinationKey shared aad =
  SHA256.hash
    ( ByteString.intercalate
        "\NUL"
        [ "prodbox-retained-destination-key-v1"
        , ByteArray.convert shared
        , SHA256.hash aad
        ]
    )

validatePayload
  :: SRetainedMaterialSchema schema
  -> TargetSecretPayload
  -> Either RetainedDestinationEnvelopeError ()
validatePayload schema payload = do
  unless
    (targetSecretPayloadId payload == schemaTarget schema)
    (Left RetainedDestinationPayloadSchemaMismatch)
  first (const RetainedDestinationPayloadInvalid) (validateTargetSecretPayload payload)

schemaTarget :: SRetainedMaterialSchema schema -> TargetSecretId
schemaTarget schema = case schema of
  SRetainedSesSmtpMaterial -> TargetSesSmtp
  SRetainedAcmeEabMaterial -> TargetAcmeEab

schemaTag :: SRetainedMaterialSchema schema -> Word8
schemaTag schema = case schema of
  SRetainedSesSmtpMaterial -> 0
  SRetainedAcmeEabMaterial -> 1

refValue :: Text -> Either RetainedDestinationEnvelopeError RetainedMaterialRef
refValue =
  first (const RetainedDestinationBindingMismatch)
    . mkRetainedMaterialRef

targetValue
  :: SRetainedMaterialSchema schema
  -> Text
  -> Either RetainedDestinationEnvelopeError (RetainedMaterialTarget schema)
targetValue schema =
  first (const RetainedDestinationBindingMismatch)
    . mkRetainedMaterialTarget schema

cryptoValue
  :: errorValue -> CryptoFailable value -> Either errorValue value
cryptoValue err value = case value of
  CryptoFailed _ -> Left err
  CryptoPassed ok -> Right ok

unwrapPublic :: RetainedDestinationPublicKey schema -> X25519.PublicKey
unwrapPublic (RetainedDestinationPublicKey value) = value
