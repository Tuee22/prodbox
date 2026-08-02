{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Worker-local cryptography for the pre-Vault federation handshake.
--
-- Child and parent private keys have no equality, show, or serialization
-- instance and remain inside their running one-shot Jobs.  The coordinating
-- host can receive only the public attestations, AEAD ciphertext, commitments,
-- Kubernetes read-back evidence, and secret-free commit checkpoints exposed by
-- this module.
module Prodbox.ControlPlane.FederationBootstrapCrypto
  ( FederationChildRecipientSession
  , FederationParentCustodySession
  , ScopedTransitCredential
  , mkScopedTransitCredential
  , withScopedTransitCredential
  , FederationChildApplied
  , mkFederationChildApplied
  , FederationChildReturnMaterial
  , mkFederationChildReturnMaterial
  , withFederationChildReturnMaterial
  , FederationParentCustodyCheckpoint
  , federationParentCheckpointDelivery
  , federationParentCheckpointWorker
  , FederationBootstrapCryptoError (..)
  , prepareFederationChildRecipient
  , prepareFederationParentEnvelope
  , completeFederationChildDelivery
  , completeFederationParentCustody
  , finalizeFederationParentCustody
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
import Prodbox.Bootstrap.Broker.Types (ArtifactDigest)
import Prodbox.Cluster.FederationRegistration
  ( ChildBootstrapDeliveryIntent (..)
  , ChildBootstrapDeliveryReceipt (..)
  , ChildBootstrapRecipientAttestation (..)
  , ChildKubernetesUid
  , FederationWorkerBinding
  , FederationWorkerCleanup (federationWorkerCleanupBinding)
  , ParentBootstrapCustodyReceipt
  , ParentBootstrapEnvelope (..)
  , mkChildBootstrapRecipientAttestation
  , mkParentBootstrapCustodyReceipt
  , mkParentBootstrapEnvelope
  , validateChildBootstrapDeliveryIntent
  , validateChildBootstrapDeliveryReceipt
  , validateChildBootstrapRecipientAttestation
  , validateParentBootstrapEnvelope
  )
import Prodbox.ControlPlane.FederationBootstrapCoordinator
  ( FederationChildDeliveryCheckpoint
  , mkFederationChildDeliveryCheckpoint
  )
import Prodbox.Crypto.Aead
  ( AeadError
  , aeadNonceBytes
  , openAead
  , sealAead
  )

data FederationChildRecipientSession = FederationChildRecipientSession
  { internalChildSessionIntent :: !ChildBootstrapDeliveryIntent
  , internalChildSessionWorker :: !FederationWorkerBinding
  , internalChildSessionSecret :: !X25519.SecretKey
  , internalChildSessionPublic :: !ByteString
  }

data FederationParentCustodySession = FederationParentCustodySession
  { internalParentSessionEnvelope :: !ParentBootstrapEnvelope
  , internalParentSessionSecret :: !X25519.SecretKey
  }

-- | Plaintext scoped credential.  It has no instances or field accessors and
-- is supplied only to the child worker's continuation after AEAD opening.
data ScopedTransitCredential = ScopedTransitCredential
  { internalCredentialVaultAddress :: !Text
  , internalCredentialTransitKey :: !Text
  , internalCredentialToken :: !Text
  , internalCredentialCommitment :: !ArtifactDigest
  }

data FederationChildReturnMaterial = FederationChildReturnMaterial
  { internalReturnMetadata :: !ByteString
  , internalReturnKubeconfig :: !ByteString
  }

data FederationChildApplied = FederationChildApplied
  { internalAppliedSecretUid :: !ChildKubernetesUid
  , internalAppliedResourceVersion :: !Text
  , internalAppliedSecretCommitment :: !ArtifactDigest
  , internalAppliedReturnMaterial :: !FederationChildReturnMaterial
  }

-- | Secret-free, durable result after the parent has decrypted and committed
-- metadata/bootstrap/index but before its Job can be deleted.  Persisting this
-- first closes the commit-versus-cleanup crash window without retaining the
-- parent private key or decrypted child material.
data FederationParentCustodyCheckpoint = FederationParentCustodyCheckpoint
  { internalParentCheckpointDelivery :: !ChildBootstrapDeliveryReceipt
  , internalParentCheckpointWorker :: !FederationWorkerBinding
  , internalParentCheckpointMetadataCommitment :: !ArtifactDigest
  , internalParentCheckpointBootstrapCommitment :: !ArtifactDigest
  , internalParentCheckpointIndexCommitment :: !ArtifactDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data FederationBootstrapCryptoError
  = FederationBootstrapCryptoIntentInvalid
  | FederationBootstrapCryptoRecipientInvalid
  | FederationBootstrapCryptoParentEnvelopeInvalid
  | FederationBootstrapCryptoDeliveryInvalid
  | FederationBootstrapCryptoCredentialInvalid
  | FederationBootstrapCryptoReturnMaterialInvalid
  | FederationBootstrapCryptoPublicKeyInvalid
  | FederationBootstrapCryptoEnvelopeTooLarge !Int
  | FederationBootstrapCryptoEnvelopeDecodeFailed
  | FederationBootstrapCryptoEnvelopeNonCanonical
  | FederationBootstrapCryptoEnvelopeVersionUnsupported !Word16
  | FederationBootstrapCryptoEnvelopeSenderMismatch
  | FederationBootstrapCryptoCipherFailed !AeadError
  | FederationBootstrapCryptoBindingMismatch
  | FederationBootstrapCryptoChildApplyUnavailable !Text
  | FederationBootstrapCryptoParentCommitUnavailable !Text
  | FederationBootstrapCryptoParentCleanupMismatch
  deriving stock (Eq, Show)

data WireCiphertext = WireCiphertext
  { wireCiphertextVersion :: !Word16
  , wireCiphertextSender :: !ByteString
  , wireCiphertextNonce :: !ByteString
  , wireCiphertextBody :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireScopedTransitCredential = WireScopedTransitCredential
  { wireCredentialVersion :: !Word16
  , wireCredentialVaultAddress :: !Text
  , wireCredentialTransitKey :: !Text
  , wireCredentialToken :: !Text
  , wireCredentialCommitment :: !ArtifactDigest
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

data WireChildReturnMaterial = WireChildReturnMaterial
  { wireReturnVersion :: !Word16
  , wireReturnMetadata :: !ByteString
  , wireReturnKubeconfig :: !ByteString
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

federationBootstrapCryptoVersion :: Word16
federationBootstrapCryptoVersion = 1

maximumFederationCiphertextBytes :: Int
maximumFederationCiphertextBytes = 1024 * 1024

maximumTransitTokenCharacters :: Int
maximumTransitTokenCharacters = 16 * 1024

maximumReturnMaterialBytes :: Int
maximumReturnMaterialBytes = 768 * 1024

mkScopedTransitCredential
  :: ChildBootstrapDeliveryIntent
  -> ArtifactDigest
  -> Text
  -> Either FederationBootstrapCryptoError ScopedTransitCredential
mkScopedTransitCredential intent commitment rawToken = do
  _ <-
    first (const FederationBootstrapCryptoIntentInvalid) (validateChildBootstrapDeliveryIntent intent)
  token <- validateSecretText maximumTransitTokenCharacters rawToken
  Right
    ScopedTransitCredential
      { internalCredentialVaultAddress = childBootstrapDeliveryParentVaultAddress intent
      , internalCredentialTransitKey = childBootstrapDeliveryTransitKey intent
      , internalCredentialToken = token
      , internalCredentialCommitment = commitment
      }

withScopedTransitCredential
  :: ScopedTransitCredential
  -> (Text -> Text -> Text -> result)
  -> result
withScopedTransitCredential credential use =
  use
    (internalCredentialVaultAddress credential)
    (internalCredentialTransitKey credential)
    (internalCredentialToken credential)

mkFederationChildReturnMaterial
  :: ByteString
  -> ByteString
  -> Either FederationBootstrapCryptoError FederationChildReturnMaterial
mkFederationChildReturnMaterial metadata kubeconfig
  | ByteString.null metadata || ByteString.null kubeconfig =
      Left FederationBootstrapCryptoReturnMaterialInvalid
  | ByteString.length metadata + ByteString.length kubeconfig > maximumReturnMaterialBytes =
      Left FederationBootstrapCryptoReturnMaterialInvalid
  | otherwise =
      Right
        FederationChildReturnMaterial
          { internalReturnMetadata = metadata
          , internalReturnKubeconfig = kubeconfig
          }

withFederationChildReturnMaterial
  :: FederationChildReturnMaterial
  -> (ByteString -> ByteString -> result)
  -> result
withFederationChildReturnMaterial material use =
  use
    (internalReturnMetadata material)
    (internalReturnKubeconfig material)

mkFederationChildApplied
  :: ChildKubernetesUid
  -> Text
  -> ArtifactDigest
  -> FederationChildReturnMaterial
  -> Either FederationBootstrapCryptoError FederationChildApplied
mkFederationChildApplied secretUid rawResourceVersion secretCommitment material = do
  resourceVersion <- validateResourceVersion rawResourceVersion
  Right
    FederationChildApplied
      { internalAppliedSecretUid = secretUid
      , internalAppliedResourceVersion = resourceVersion
      , internalAppliedSecretCommitment = secretCommitment
      , internalAppliedReturnMaterial = material
      }

federationParentCheckpointDelivery
  :: FederationParentCustodyCheckpoint -> ChildBootstrapDeliveryReceipt
federationParentCheckpointDelivery = internalParentCheckpointDelivery

federationParentCheckpointWorker
  :: FederationParentCustodyCheckpoint -> FederationWorkerBinding
federationParentCheckpointWorker = internalParentCheckpointWorker

prepareFederationChildRecipient
  :: ChildBootstrapDeliveryIntent
  -> FederationWorkerBinding
  -> IO
       ( Either
           FederationBootstrapCryptoError
           (FederationChildRecipientSession, ChildBootstrapRecipientAttestation)
       )
prepareFederationChildRecipient intent worker =
  case validateChildBootstrapDeliveryIntent intent of
    Left _ -> pure (Left FederationBootstrapCryptoIntentInvalid)
    Right _ -> do
      secret <- X25519.generateSecretKey
      let public = ByteArray.convert (X25519.toPublic secret)
      pure $ do
        recipient <-
          first
            (const FederationBootstrapCryptoRecipientInvalid)
            (mkChildBootstrapRecipientAttestation intent worker public)
        Right
          ( FederationChildRecipientSession
              { internalChildSessionIntent = intent
              , internalChildSessionWorker = worker
              , internalChildSessionSecret = secret
              , internalChildSessionPublic = public
              }
          , recipient
          )

prepareFederationParentEnvelope
  :: ChildBootstrapRecipientAttestation
  -> FederationWorkerBinding
  -> ScopedTransitCredential
  -> IO
       ( Either
           FederationBootstrapCryptoError
           (FederationParentCustodySession, ParentBootstrapEnvelope)
       )
prepareFederationParentEnvelope recipient worker credential =
  case validateChildBootstrapRecipientAttestation recipient of
    Left _ -> pure (Left FederationBootstrapCryptoRecipientInvalid)
    Right _
      | not (credentialMatchesIntent (childBootstrapRecipientIntent recipient) credential) ->
          pure (Left FederationBootstrapCryptoBindingMismatch)
      | otherwise -> do
          secret <- X25519.generateSecretKey
          let public = ByteArray.convert (X25519.toPublic secret)
              aad = credentialAad recipient worker public (internalCredentialCommitment credential)
              plaintext = encodeCredential credential
          sealed <-
            sealForPublic
              (childBootstrapRecipientPublicKey recipient)
              secret
              public
              aad
              plaintext
          pure $ do
            ciphertext <- sealed
            envelope <-
              first
                (const FederationBootstrapCryptoParentEnvelopeInvalid)
                ( mkParentBootstrapEnvelope
                    recipient
                    worker
                    public
                    ciphertext
                    (internalCredentialCommitment credential)
                )
            Right
              ( FederationParentCustodySession
                  { internalParentSessionEnvelope = envelope
                  , internalParentSessionSecret = secret
                  }
              , envelope
              )

completeFederationChildDelivery
  :: FederationChildRecipientSession
  -> ParentBootstrapEnvelope
  -> (ScopedTransitCredential -> IO (Either Text FederationChildApplied))
  -> IO (Either FederationBootstrapCryptoError FederationChildDeliveryCheckpoint)
completeFederationChildDelivery session suppliedEnvelope applyCredential =
  case validateParentBootstrapEnvelope suppliedEnvelope of
    Left _ -> pure (Left FederationBootstrapCryptoParentEnvelopeInvalid)
    Right envelope
      | parentBootstrapEnvelopeChildRecipient envelope /= sessionRecipient session ->
          pure (Left FederationBootstrapCryptoBindingMismatch)
      | otherwise -> do
          let aad =
                credentialAad
                  (parentBootstrapEnvelopeChildRecipient envelope)
                  (parentBootstrapEnvelopeWorker envelope)
                  (parentBootstrapEnvelopeCustodyPublicKey envelope)
                  (parentBootstrapEnvelopeCredentialCommitment envelope)
          let opened =
                openForSecret
                  (internalChildSessionSecret session)
                  (internalChildSessionPublic session)
                  (parentBootstrapEnvelopeCustodyPublicKey envelope)
                  aad
                  (parentBootstrapEnvelopeCiphertext envelope)
          case opened >>= decodeCredential (internalChildSessionIntent session) envelope of
            Left failure -> pure (Left failure)
            Right credential -> do
              applied <- applyCredential credential
              case applied of
                Left detail -> pure (Left (FederationBootstrapCryptoChildApplyUnavailable detail))
                Right result -> sealChildReturn session envelope result

completeFederationParentCustody
  :: FederationParentCustodySession
  -> ChildBootstrapDeliveryReceipt
  -> ( FederationChildReturnMaterial
       -> IO (Either Text (ArtifactDigest, ArtifactDigest, ArtifactDigest))
     )
  -> IO (Either FederationBootstrapCryptoError FederationParentCustodyCheckpoint)
completeFederationParentCustody session suppliedDelivery commit =
  case validateChildBootstrapDeliveryReceipt suppliedDelivery of
    Left _ -> pure (Left FederationBootstrapCryptoDeliveryInvalid)
    Right delivery
      | childBootstrapDeliveryParentEnvelope delivery
          /= internalParentSessionEnvelope session ->
          pure (Left FederationBootstrapCryptoBindingMismatch)
      | otherwise -> do
          let aad = returnAad delivery
              childPublic =
                childBootstrapRecipientPublicKey
                  ( parentBootstrapEnvelopeChildRecipient
                      (childBootstrapDeliveryParentEnvelope delivery)
                  )
          let opened =
                openForSecret
                  (internalParentSessionSecret session)
                  ( parentBootstrapEnvelopeCustodyPublicKey
                      (internalParentSessionEnvelope session)
                  )
                  childPublic
                  aad
                  (childBootstrapDeliveryParentCiphertext delivery)
          case opened >>= decodeReturnMaterial of
            Left failure -> pure (Left failure)
            Right material -> do
              committed <- commit material
              pure $ case committed of
                Left detail -> Left (FederationBootstrapCryptoParentCommitUnavailable detail)
                Right (metadataCommitment, bootstrapCommitment, indexCommitment) ->
                  Right
                    FederationParentCustodyCheckpoint
                      { internalParentCheckpointDelivery = delivery
                      , internalParentCheckpointWorker =
                          parentBootstrapEnvelopeWorker
                            (internalParentSessionEnvelope session)
                      , internalParentCheckpointMetadataCommitment = metadataCommitment
                      , internalParentCheckpointBootstrapCommitment = bootstrapCommitment
                      , internalParentCheckpointIndexCommitment = indexCommitment
                      }

finalizeFederationParentCustody
  :: FederationParentCustodyCheckpoint
  -> FederationWorkerCleanup
  -> Either FederationBootstrapCryptoError ParentBootstrapCustodyReceipt
finalizeFederationParentCustody checkpoint cleanup
  | federationWorkerCleanupBinding cleanup /= internalParentCheckpointWorker checkpoint =
      Left FederationBootstrapCryptoParentCleanupMismatch
  | otherwise =
      first
        (const FederationBootstrapCryptoParentCleanupMismatch)
        ( mkParentBootstrapCustodyReceipt
            (internalParentCheckpointDelivery checkpoint)
            (internalParentCheckpointMetadataCommitment checkpoint)
            (internalParentCheckpointBootstrapCommitment checkpoint)
            (internalParentCheckpointIndexCommitment checkpoint)
            cleanup
        )

sealChildReturn
  :: FederationChildRecipientSession
  -> ParentBootstrapEnvelope
  -> FederationChildApplied
  -> IO (Either FederationBootstrapCryptoError FederationChildDeliveryCheckpoint)
sealChildReturn session envelope applied = do
  let worker = internalChildSessionWorker session
      aad =
        returnCheckpointAad
          envelope
          worker
          (internalAppliedSecretUid applied)
          (internalAppliedResourceVersion applied)
          (internalAppliedSecretCommitment applied)
      plaintext = encodeReturnMaterial (internalAppliedReturnMaterial applied)
  sealed <-
    sealForPublic
      (parentBootstrapEnvelopeCustodyPublicKey envelope)
      (internalChildSessionSecret session)
      (internalChildSessionPublic session)
      aad
      plaintext
  pure $ do
    ciphertext <- sealed
    first
      (const FederationBootstrapCryptoDeliveryInvalid)
      ( mkFederationChildDeliveryCheckpoint
          envelope
          worker
          (internalAppliedSecretUid applied)
          (internalAppliedResourceVersion applied)
          (internalAppliedSecretCommitment applied)
          ciphertext
      )

sealForPublic
  :: ByteString
  -> X25519.SecretKey
  -> ByteString
  -> ByteString
  -> ByteString
  -> IO (Either FederationBootstrapCryptoError ByteString)
sealForPublic destinationBytes senderSecret senderPublic aad plaintext =
  case cryptoValue (X25519.publicKey destinationBytes) of
    Left failure -> pure (Left failure)
    Right destination -> do
      nonce <- getRandomBytes aeadNonceBytes
      let key = deriveKey (X25519.dh destination senderSecret) aad
      pure $ do
        body <- first FederationBootstrapCryptoCipherFailed (sealAead key nonce aad plaintext)
        let encoded =
              LazyByteString.toStrict
                ( serialise
                    WireCiphertext
                      { wireCiphertextVersion = federationBootstrapCryptoVersion
                      , wireCiphertextSender = senderPublic
                      , wireCiphertextNonce = nonce
                      , wireCiphertextBody = body
                      }
                )
        if ByteString.length encoded <= maximumFederationCiphertextBytes
          then Right encoded
          else Left (FederationBootstrapCryptoEnvelopeTooLarge (ByteString.length encoded))

openForSecret
  :: X25519.SecretKey
  -> ByteString
  -> ByteString
  -> ByteString
  -> ByteString
  -> Either FederationBootstrapCryptoError ByteString
openForSecret destinationSecret destinationPublic expectedSender aad encoded = do
  wire <- decodeCiphertext encoded
  if wireCiphertextSender wire /= expectedSender
    then Left FederationBootstrapCryptoEnvelopeSenderMismatch
    else Right ()
  sender <- cryptoValue (X25519.publicKey (wireCiphertextSender wire))
  let key = deriveKey (X25519.dh sender destinationSecret) aad
      destinationMatches =
        ByteArray.convert (X25519.toPublic destinationSecret) == destinationPublic
  if not destinationMatches
    then Left FederationBootstrapCryptoBindingMismatch
    else
      first
        FederationBootstrapCryptoCipherFailed
        (openAead key (wireCiphertextNonce wire) aad (wireCiphertextBody wire))

decodeCiphertext :: ByteString -> Either FederationBootstrapCryptoError WireCiphertext
decodeCiphertext encoded
  | ByteString.length encoded > maximumFederationCiphertextBytes =
      Left (FederationBootstrapCryptoEnvelopeTooLarge (ByteString.length encoded))
  | otherwise = do
      wire <-
        first
          (const FederationBootstrapCryptoEnvelopeDecodeFailed)
          (deserialiseOrFail (LazyByteString.fromStrict encoded))
      if LazyByteString.toStrict (serialise wire) /= encoded
        then Left FederationBootstrapCryptoEnvelopeNonCanonical
        else Right ()
      if wireCiphertextVersion wire /= federationBootstrapCryptoVersion
        then Left (FederationBootstrapCryptoEnvelopeVersionUnsupported (wireCiphertextVersion wire))
        else Right wire

encodeCredential :: ScopedTransitCredential -> ByteString
encodeCredential credential =
  LazyByteString.toStrict
    ( serialise
        WireScopedTransitCredential
          { wireCredentialVersion = federationBootstrapCryptoVersion
          , wireCredentialVaultAddress = internalCredentialVaultAddress credential
          , wireCredentialTransitKey = internalCredentialTransitKey credential
          , wireCredentialToken = internalCredentialToken credential
          , wireCredentialCommitment = internalCredentialCommitment credential
          }
    )

decodeCredential
  :: ChildBootstrapDeliveryIntent
  -> ParentBootstrapEnvelope
  -> ByteString
  -> Either FederationBootstrapCryptoError ScopedTransitCredential
decodeCredential intent envelope encoded = do
  wire <-
    first
      (const FederationBootstrapCryptoCredentialInvalid)
      (deserialiseOrFail (LazyByteString.fromStrict encoded))
  if LazyByteString.toStrict (serialise wire) /= encoded
    then Left FederationBootstrapCryptoEnvelopeNonCanonical
    else Right ()
  token <- validateSecretText maximumTransitTokenCharacters (wireCredentialToken wire)
  if wireCredentialVersion wire == federationBootstrapCryptoVersion
    && wireCredentialVaultAddress wire == childBootstrapDeliveryParentVaultAddress intent
    && wireCredentialTransitKey wire == childBootstrapDeliveryTransitKey intent
    && wireCredentialCommitment wire == parentBootstrapEnvelopeCredentialCommitment envelope
    then
      Right
        ScopedTransitCredential
          { internalCredentialVaultAddress = wireCredentialVaultAddress wire
          , internalCredentialTransitKey = wireCredentialTransitKey wire
          , internalCredentialToken = token
          , internalCredentialCommitment = wireCredentialCommitment wire
          }
    else Left FederationBootstrapCryptoCredentialInvalid

encodeReturnMaterial :: FederationChildReturnMaterial -> ByteString
encodeReturnMaterial material =
  LazyByteString.toStrict
    ( serialise
        WireChildReturnMaterial
          { wireReturnVersion = federationBootstrapCryptoVersion
          , wireReturnMetadata = internalReturnMetadata material
          , wireReturnKubeconfig = internalReturnKubeconfig material
          }
    )

decodeReturnMaterial
  :: ByteString -> Either FederationBootstrapCryptoError FederationChildReturnMaterial
decodeReturnMaterial encoded = do
  wire <-
    first
      (const FederationBootstrapCryptoReturnMaterialInvalid)
      (deserialiseOrFail (LazyByteString.fromStrict encoded))
  if LazyByteString.toStrict (serialise wire) /= encoded
    then Left FederationBootstrapCryptoEnvelopeNonCanonical
    else Right ()
  if wireReturnVersion wire /= federationBootstrapCryptoVersion
    then Left (FederationBootstrapCryptoEnvelopeVersionUnsupported (wireReturnVersion wire))
    else mkFederationChildReturnMaterial (wireReturnMetadata wire) (wireReturnKubeconfig wire)

credentialMatchesIntent
  :: ChildBootstrapDeliveryIntent -> ScopedTransitCredential -> Bool
credentialMatchesIntent intent credential =
  internalCredentialVaultAddress credential == childBootstrapDeliveryParentVaultAddress intent
    && internalCredentialTransitKey credential == childBootstrapDeliveryTransitKey intent

sessionRecipient :: FederationChildRecipientSession -> ChildBootstrapRecipientAttestation
sessionRecipient session =
  case mkChildBootstrapRecipientAttestation
    (internalChildSessionIntent session)
    (internalChildSessionWorker session)
    (internalChildSessionPublic session) of
    Left failure -> error ("validated federation child session became invalid: " <> show failure)
    Right recipient -> recipient

credentialAad
  :: ChildBootstrapRecipientAttestation
  -> FederationWorkerBinding
  -> ByteString
  -> ArtifactDigest
  -> ByteString
credentialAad recipient worker public commitment =
  LazyByteString.toStrict
    ( serialise
        ( "prodbox-federation-bootstrap-credential-aad-v1" :: Text
        , recipient
        , worker
        , public
        , commitment
        )
    )

returnAad :: ChildBootstrapDeliveryReceipt -> ByteString
returnAad delivery =
  returnCheckpointAad
    (childBootstrapDeliveryParentEnvelope delivery)
    (childBootstrapDeliveryWorker delivery)
    (childBootstrapDeliveryChildSecretUid delivery)
    (childBootstrapDeliveryChildSecretResourceVersion delivery)
    (childBootstrapDeliveryChildSecretCommitment delivery)

returnCheckpointAad
  :: ParentBootstrapEnvelope
  -> FederationWorkerBinding
  -> ChildKubernetesUid
  -> Text
  -> ArtifactDigest
  -> ByteString
returnCheckpointAad envelope worker secretUid resourceVersion secretCommitment =
  LazyByteString.toStrict
    ( serialise
        ( "prodbox-federation-bootstrap-return-aad-v1" :: Text
        , envelope
        , worker
        , secretUid
        , resourceVersion
        , secretCommitment
        )
    )

deriveKey :: X25519.DhSecret -> ByteString -> ByteString
deriveKey shared aad =
  SHA256.hash (ByteArray.convert shared <> aad)

cryptoValue
  :: CryptoFailable value -> Either FederationBootstrapCryptoError value
cryptoValue attempted = case attempted of
  CryptoFailed _ -> Left FederationBootstrapCryptoPublicKeyInvalid
  CryptoPassed value -> Right value

validateSecretText
  :: Int -> Text -> Either FederationBootstrapCryptoError Text
validateSecretText maximumLength raw
  | Text.null raw = Left FederationBootstrapCryptoCredentialInvalid
  | Text.length raw > maximumLength = Left FederationBootstrapCryptoCredentialInvalid
  | Text.any (\character -> isControl character || isSpace character) raw =
      Left FederationBootstrapCryptoCredentialInvalid
  | otherwise = Right raw

validateResourceVersion
  :: Text -> Either FederationBootstrapCryptoError Text
validateResourceVersion raw
  | Text.null value = Left FederationBootstrapCryptoBindingMismatch
  | Text.length value > 256 = Left FederationBootstrapCryptoBindingMismatch
  | Text.any (\character -> isControl character || isSpace character) value =
      Left FederationBootstrapCryptoBindingMismatch
  | otherwise = Right value
 where
  value = Text.strip raw
