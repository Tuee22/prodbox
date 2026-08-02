{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Closed, one-shot home-custody worker algebra for retained SES SMTP and
-- ACME EAB material.
--
-- The injected boundary has no path argument and no generic byte export.  It
-- can operate only on the schema selected by its phantom index.  Plaintext is
-- accepted by 'sealRetainedCustody' or recovered transiently inside
-- 'rewrapRetainedCustody'; every durable value and outward result is
-- ciphertext/metadata/receipt-only.
module Prodbox.ControlPlane.RetainedMaterialWorker
  ( RetainedCustodyDataObservation (..)
  , RetainedCustodyMetadataObservation (..)
  , RetainedCustodyVersionObservation (..)
  , RetainedCustodyVaultBoundary (..)
  , RetainedCustodySealResult (..)
  , RetainedCustodyRewrapReceipt
  , retainedCustodyRewrapReceiptRef
  , retainedCustodyRewrapEnvelopeDigest
  , RetainedCustodyRewrapResult (..)
  , RetainedCustodyRetirementResult (..)
  , RetainedCustodyWorkerError (..)
  , retainedCustodyTransitKey
  , retainedCustodyCommitmentKey
  , retainedCustodyDataPath
  , sealRetainedCustody
  , observeRetainedCustody
  , rewrapRetainedCustody
  , retireRetainedCustody
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.RetainedMaterialEnvelope
  ( RetainedDestinationEnvelope
  , RetainedDestinationEnvelopeError
  , RetainedDestinationPublicKey
  , encodeRetainedDestinationEnvelope
  , retainedDestinationPublicKeyDigest
  , sealRetainedDestinationEnvelope
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId (TargetAcmeEab, TargetSesSmtp)
  , TargetSecretPayload
  , targetSecretPayloadId
  , validateTargetSecretPayload
  )
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( RetainedCustodyObservation (..)
  , RetainedDeliveryIntent
  , RetainedMaterialRef
  , RetainedMaterialSchema
  , RetainedMaterialSource
  , RetainedSealIntent
  , SRetainedMaterialSchema (..)
  , mkRetainedMaterialRef
  , mkRetainedMaterialSource
  , retainedDeliveryEphemeralKeyDigest
  , retainedDeliveryOperationId
  , retainedDeliverySourceReceipt
  , retainedDeliveryTarget
  , retainedDeliveryTargetGeneration
  , retainedMaterialRefText
  , retainedMaterialSchemaToken
  , retainedSealBindingDigest
  , retainedSealGeneration
  , retainedSealOperationId
  , retainedSourceCiphertextDigest
  , retainedSourceCommitmentRef
  , retainedSourceGeneration
  , retainedSourceOperationId
  , retainedSourceReceiptRef
  , retainedSourceVaultVersion
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , sha256TargetValueDigest
  , targetValueDigestText
  )

data RetainedCustodyDataObservation
  = RetainedCustodyDataMissing
  | RetainedCustodyDataPresent !Natural !(Map Text Text)
  deriving stock (Eq, Show)

data RetainedCustodyMetadataObservation
  = RetainedCustodyMetadataMissing
  | RetainedCustodyMetadataPresent !Natural !(Map Text Text)
  deriving stock (Eq, Show)

data RetainedCustodyVersionObservation
  = RetainedCustodyVersionMissing
  | RetainedCustodyVersionPresent !(Map Text Text)
  deriving stock (Eq, Show)

-- | Schema-indexed Vault surface.  Production binds one value to one exact
-- @secret/retained-home/<schema>@ coordinate and the non-exportable retained
-- Transit/HMAC keys.  No method accepts a mount, path, key name, target path,
-- or arbitrary decrypt payload.
type role RetainedCustodyVaultBoundary nominal representational

data
  RetainedCustodyVaultBoundary
    (schema :: RetainedMaterialSchema)
    m
  = RetainedCustodyVaultBoundary
  { retainedCustodyReadCurrentData
      :: m (Either Text RetainedCustodyDataObservation)
  , retainedCustodyReadMetadata
      :: m (Either Text RetainedCustodyMetadataObservation)
  , retainedCustodyReadVersion
      :: Natural
      -> m (Either Text RetainedCustodyVersionObservation)
  , retainedCustodyTransitEncrypt
      :: ByteString
      -> m (Either Text Text)
  , retainedCustodyTransitDecrypt
      :: Text
      -> m (Either Text ByteString)
  , retainedCustodyHmac
      :: ByteString
      -> m (Either Text Text)
  , retainedCustodyCompareAndSwap
      :: Natural
      -> Map Text Text
      -> m (Either Text Natural)
  , retainedCustodyWriteMetadata
      :: Map Text Text
      -> m (Either Text ())
  , retainedCustodyTombstoneVersion
      :: Natural
      -> m (Either Text ())
  , retainedCustodyObserveVersionAbsent
      :: Natural
      -> m (Either Text Bool)
  }

data RetainedCustodySealResult schema
  = RetainedCustodySealed !(RetainedMaterialSource schema)
  | RetainedCustodyAlreadySealed !(RetainedMaterialSource schema)
  | RetainedCustodySealRecovered !(RetainedMaterialSource schema)
  deriving stock (Eq, Show)

data RetainedCustodyRewrapReceipt schema = RetainedCustodyRewrapReceipt
  { internalRewrapReceiptRef :: !RetainedMaterialRef
  , internalRewrapEnvelopeDigest :: !TargetValueDigest
  }
  deriving stock (Eq, Show)

retainedCustodyRewrapReceiptRef
  :: RetainedCustodyRewrapReceipt schema -> RetainedMaterialRef
retainedCustodyRewrapReceiptRef = internalRewrapReceiptRef

retainedCustodyRewrapEnvelopeDigest
  :: RetainedCustodyRewrapReceipt schema -> TargetValueDigest
retainedCustodyRewrapEnvelopeDigest = internalRewrapEnvelopeDigest

data RetainedCustodyRewrapResult schema = RetainedCustodyRewrapResult
  { retainedCustodyDestinationEnvelope :: !(RetainedDestinationEnvelope schema)
  , retainedCustodyDestinationReceipt :: !(RetainedCustodyRewrapReceipt schema)
  }
  deriving stock (Show)

data RetainedCustodyRetirementResult
  = RetainedCustodyRetired !RetainedMaterialRef
  | RetainedCustodyAlreadyAbsent !RetainedMaterialRef
  deriving stock (Eq, Show)

data RetainedCustodyWorkerError
  = RetainedCustodyPayloadSchemaMismatch
  | RetainedCustodyPayloadInvalid
  | RetainedCustodyTransitEncryptUnavailable
  | RetainedCustodyTransitDecryptUnavailable
  | RetainedCustodyTransitCiphertextInvalid
  | RetainedCustodyHmacUnavailable
  | RetainedCustodyHmacInvalid
  | RetainedCustodyDataUnavailable
  | RetainedCustodyMetadataUnavailable
  | RetainedCustodyMetadataInvalid
  | RetainedCustodyGenerationNotNext !Natural !Natural
  | RetainedCustodyGenerationCollision !Natural
  | RetainedCustodyCasFailed
  | RetainedCustodyDataReadBackMismatch
  | RetainedCustodyMetadataWriteFailed
  | RetainedCustodyMetadataReadBackMismatch
  | RetainedCustodySourceMismatch
  | RetainedCustodySourceAbsent
  | RetainedCustodySourceCorrupt
  | RetainedCustodyDestinationKeyMismatch
  | RetainedCustodyDestinationEnvelopeFailed !RetainedDestinationEnvelopeError
  | RetainedCustodyTombstoneFailed
  | RetainedCustodyAbsenceUnobservable
  | RetainedCustodyStillPresent
  deriving stock (Eq, Show)

data WireRetainedCommitment = WireRetainedCommitment
  { wireCommitmentVersion :: !Word16
  , wireCommitmentDomain :: !Text
  , wireCommitmentSchema :: !Text
  , wireCommitmentOperationId :: !Text
  , wireCommitmentGeneration :: !Natural
  , wireCommitmentBindingDigest :: !Text
  , wireCommitmentMaterial :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireRetainedReceipt = WireRetainedReceipt
  { wireReceiptVersion :: !Word16
  , wireReceiptDomain :: !Text
  , wireReceiptSchema :: !Text
  , wireReceiptOperationId :: !Text
  , wireReceiptGeneration :: !Natural
  , wireReceiptCiphertextDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

retainedCustodyWireVersion :: Word16
retainedCustodyWireVersion = 1

retainedCustodyTransitKey :: Text
retainedCustodyTransitKey = "prodbox-retained-material"

retainedCustodyCommitmentKey :: Text
retainedCustodyCommitmentKey = "prodbox-retained-material-commitment"

retainedCustodyDataPath :: SRetainedMaterialSchema schema -> Text
retainedCustodyDataPath schema =
  "target-agent/retained-home/" <> retainedMaterialSchemaToken schema

sealRetainedCustody
  :: (Monad m)
  => SRetainedMaterialSchema schema
  -> AuthorityTime
  -> RetainedCustodyVaultBoundary schema m
  -> RetainedSealIntent schema
  -> TargetSecretPayload
  -> m
       ( Either
           RetainedCustodyWorkerError
           (RetainedCustodySealResult schema)
       )
sealRetainedCustody schema readBackAt boundary intent payload =
  case validateSchemaPayload schema payload of
    Left err -> pure (Left err)
    Right plaintext -> do
      commitmentResult <-
        retainedCustodyHmac
          boundary
          ( commitmentInput
              schema
              intent
              plaintext
          )
      encrypted <- retainedCustodyTransitEncrypt boundary plaintext
      case (commitmentResult, encrypted) of
        (Left _, _) -> pure (Left RetainedCustodyHmacUnavailable)
        (_, Left _) -> pure (Left RetainedCustodyTransitEncryptUnavailable)
        (Right commitment, Right ciphertext) ->
          case (hmacRef commitment, validateTransitCiphertext ciphertext) of
            (Left err, _) -> pure (Left err)
            (_, Left err) -> pure (Left err)
            (Right commitmentRef, Right ()) ->
              observeThenSeal
                schema
                readBackAt
                boundary
                intent
                ciphertext
                commitmentRef

observeThenSeal
  :: forall m schema
   . (Monad m)
  => SRetainedMaterialSchema schema
  -> AuthorityTime
  -> RetainedCustodyVaultBoundary schema m
  -> RetainedSealIntent schema
  -> Text
  -> RetainedMaterialRef
  -> m
       ( Either
           RetainedCustodyWorkerError
           (RetainedCustodySealResult schema)
       )
observeThenSeal schema readBackAt boundary intent ciphertext commitmentRef = do
  dataResult <- retainedCustodyReadCurrentData boundary
  metadataResult <- retainedCustodyReadMetadata boundary
  case (dataResult, metadataResult) of
    (Left _, _) -> pure (Left RetainedCustodyDataUnavailable)
    (_, Left _) -> pure (Left RetainedCustodyMetadataUnavailable)
    (Right dataObservation, Right metadataObservation) ->
      case metadataIdentity schema metadataObservation of
        Left err -> pure (Left err)
        Right identity ->
          decideSeal dataObservation metadataObservation identity
 where
  expectedGeneration = credentialGenerationValue (retainedSealGeneration intent)
  ciphertextDigest =
    sha256TargetValueDigest (TextEncoding.encodeUtf8 ciphertext)
  expectedFields =
    Map.fromList
      [ (ciphertextField, ciphertext)
      , (schemaField, retainedMaterialSchemaToken schema)
      , (operationField, retainedMaterialRefText (retainedSealOperationId intent))
      , (generationField, naturalText expectedGeneration)
      , (commitmentField, retainedMaterialRefText commitmentRef)
      , (ciphertextDigestField, targetValueDigestText ciphertextDigest)
      ]
  expectedMetadata version receiptRef storedDigest =
    Map.fromList
      [ (schemaField, retainedMaterialSchemaToken schema)
      , (operationField, retainedMaterialRefText (retainedSealOperationId intent))
      , (generationField, naturalText expectedGeneration)
      , (receiptField, retainedMaterialRefText receiptRef)
      , (commitmentField, retainedMaterialRefText commitmentRef)
      , (ciphertextDigestField, targetValueDigestText storedDigest)
      , (vaultVersionField, naturalText version)
      ]

  decideSeal dataObservation metadataObservationValue metadataIdentityValue =
    case metadataIdentityValue of
      Just (observedGeneration, operation, observedReceipt, observedCommitment, digest, version)
        | credentialGenerationValue observedGeneration > expectedGeneration ->
            pure
              ( Left
                  ( RetainedCustodyGenerationNotNext
                      expectedGeneration
                      (credentialGenerationValue observedGeneration)
                  )
              )
        | credentialGenerationValue observedGeneration == expectedGeneration
            && ( operation /= retainedSealOperationId intent
                   || observedCommitment /= commitmentRef
               ) ->
            pure (Left (RetainedCustodyGenerationCollision expectedGeneration))
        | credentialGenerationValue observedGeneration == expectedGeneration ->
            confirmExisting
              dataObservation
              metadataObservationValue
              observedReceipt
              digest
              version
        | credentialGenerationValue observedGeneration + 1 == expectedGeneration ->
            advance dataObservation
        | otherwise ->
            pure
              ( Left
                  ( RetainedCustodyGenerationNotNext
                      expectedGeneration
                      (credentialGenerationValue observedGeneration)
                  )
              )
      Nothing
        | expectedGeneration == 1 -> advance dataObservation
        | otherwise ->
            pure
              ( Left
                  ( RetainedCustodyGenerationNotNext
                      expectedGeneration
                      0
                  )
              )

  confirmExisting dataObservation metadataObservationValue observedReceipt digest version =
    case sourceFromObservations schema readBackAt dataObservation metadataObservationValue of
      Right existingSource
        | retainedSourceReceiptRef existingSource == observedReceipt
            && retainedSourceCiphertextDigest existingSource == digest
            && retainedSourceVaultVersion existingSource == version ->
            pure (Right (RetainedCustodyAlreadySealed existingSource))
      _ -> pure (Left RetainedCustodyDataReadBackMismatch)

  advance dataObservation = case dataObservation of
    RetainedCustodyDataMissing -> applyCas 0
    RetainedCustodyDataPresent currentVersion fields ->
      case dataIdentity schema fields of
        Left err -> pure (Left err)
        Right (observedGeneration, operation, observedCommitment, _, _)
          | observedGeneration > expectedGeneration ->
              pure
                ( Left
                    ( RetainedCustodyGenerationNotNext
                        expectedGeneration
                        observedGeneration
                    )
                )
          | observedGeneration == expectedGeneration
              && operation == retainedSealOperationId intent
              && observedCommitment == commitmentRef ->
              publish currentVersion RetainedCustodySealRecovered fields
          | observedGeneration == expectedGeneration ->
              pure (Left (RetainedCustodyGenerationCollision expectedGeneration))
          | observedGeneration + 1 == expectedGeneration -> applyCas currentVersion
          | otherwise ->
              pure
                ( Left
                    ( RetainedCustodyGenerationNotNext
                        expectedGeneration
                        observedGeneration
                    )
                )

  applyCas expectedVersion = do
    attempted <-
      retainedCustodyCompareAndSwap boundary expectedVersion expectedFields
    case attempted of
      Right version -> publish version RetainedCustodySealed expectedFields
      Left _ -> do
        recovered <- retainedCustodyReadCurrentData boundary
        case recovered of
          Right (RetainedCustodyDataPresent version fields)
            | version > expectedVersion ->
                case dataIdentity schema fields of
                  Right (observedGeneration, operation, observedCommitment, _, _)
                    | observedGeneration == expectedGeneration
                        && operation == retainedSealOperationId intent
                        && observedCommitment == commitmentRef ->
                        publish version RetainedCustodySealRecovered fields
                  _ -> pure (Left RetainedCustodyCasFailed)
          _ -> pure (Left RetainedCustodyCasFailed)

  publish version constructor storedFields = do
    dataReadBack <- retainedCustodyReadCurrentData boundary
    case dataReadBack of
      Right (RetainedCustodyDataPresent observedVersion fields)
        | observedVersion == version && fields == storedFields ->
            case dataIdentity schema fields of
              Right (storedGeneration, operation, storedCommitment, storedDigest, storedCiphertext)
                | storedGeneration == expectedGeneration
                    && operation == retainedSealOperationId intent
                    && storedCommitment == commitmentRef -> do
                    receiptResult <-
                      retainedCustodyHmac
                        boundary
                        (receiptInput schema intent storedCiphertext)
                    case receiptResult >>= mapTextLeft . hmacRef of
                      Left _ -> pure (Left RetainedCustodyHmacUnavailable)
                      Right receiptRef -> do
                        let metadata = expectedMetadata version receiptRef storedDigest
                        written <- retainedCustodyWriteMetadata boundary metadata
                        case written of
                          Left _ -> pure (Left RetainedCustodyMetadataWriteFailed)
                          Right () -> do
                            metadataReadBack <- retainedCustodyReadMetadata boundary
                            case metadataReadBack of
                              Right (RetainedCustodyMetadataPresent metadataVersion custom)
                                | metadataVersion == version
                                    && custom == metadata ->
                                    pure
                                      ( constructor
                                          <$> source version receiptRef storedDigest
                                      )
                              _ -> pure (Left RetainedCustodyMetadataReadBackMismatch)
              _ -> pure (Left RetainedCustodyDataReadBackMismatch)
      _ -> pure (Left RetainedCustodyDataReadBackMismatch)

  source
    :: Natural
    -> RetainedMaterialRef
    -> TargetValueDigest
    -> Either RetainedCustodyWorkerError (RetainedMaterialSource schema)
  source version receiptRef storedDigest =
    first (const RetainedCustodyMetadataInvalid) $
      mkRetainedMaterialSource
        (retainedSealGeneration intent)
        (retainedSealOperationId intent)
        receiptRef
        storedDigest
        commitmentRef
        version
        readBackAt

observeRetainedCustody
  :: (Monad m)
  => SRetainedMaterialSchema schema
  -> AuthorityTime
  -> RetainedCustodyVaultBoundary schema m
  -> m (RetainedCustodyObservation schema)
observeRetainedCustody schema observedAt boundary = do
  dataResult <- retainedCustodyReadCurrentData boundary
  metadataResult <- retainedCustodyReadMetadata boundary
  pure $ case (dataResult, metadataResult) of
    (Left detail, _) -> RetainedCustodyUnobservable (bounded detail)
    (_, Left detail) -> RetainedCustodyUnobservable (bounded detail)
    (Right RetainedCustodyDataMissing, Right RetainedCustodyMetadataMissing) ->
      case mkRetainedMaterialRef ("absent:" <> retainedMaterialSchemaToken schema) of
        Left detail -> RetainedCustodyCorrupt (Text.pack (show detail))
        Right absenceMarker -> RetainedCustodyPositivelyAbsent absenceMarker
    (Right dataObservation, Right metadataObservation) ->
      case sourceFromObservations schema observedAt dataObservation metadataObservation of
        Left detail -> RetainedCustodyCorrupt detail
        Right source -> RetainedCustodyPresent source
rewrapRetainedCustody
  :: SRetainedMaterialSchema schema
  -> RetainedCustodyVaultBoundary schema IO
  -> RetainedMaterialSource schema
  -> RetainedDeliveryIntent schema
  -> RetainedDestinationPublicKey schema
  -> IO
       ( Either
           RetainedCustodyWorkerError
           (RetainedCustodyRewrapResult schema)
       )
rewrapRetainedCustody schema boundary source intent destinationPublic
  | retainedDeliverySourceReceipt intent /= retainedSourceReceiptRef source =
      pure (Left RetainedCustodySourceMismatch)
  | retainedDeliveryEphemeralKeyDigest intent
      /= retainedDestinationPublicKeyDigest destinationPublic =
      pure (Left RetainedCustodyDestinationKeyMismatch)
  | otherwise = do
      observed <- retainedCustodyReadVersion boundary (retainedSourceVaultVersion source)
      case observed of
        Left _ -> pure (Left RetainedCustodyDataUnavailable)
        Right RetainedCustodyVersionMissing -> pure (Left RetainedCustodySourceAbsent)
        Right (RetainedCustodyVersionPresent fields) ->
          case validateSourceFields schema source fields of
            Left err -> pure (Left err)
            Right ciphertext -> do
              decrypted <- retainedCustodyTransitDecrypt boundary ciphertext
              case decrypted of
                Left _ -> pure (Left RetainedCustodyTransitDecryptUnavailable)
                Right plaintext -> case decodeSchemaPayload schema plaintext of
                  Left err -> pure (Left err)
                  Right payload -> do
                    envelopeResult <-
                      sealRetainedDestinationEnvelope
                        schema
                        (retainedDeliveryOperationId intent)
                        (retainedSourceReceiptRef source)
                        (retainedDeliveryTarget intent)
                        (retainedDeliveryTargetGeneration intent)
                        destinationPublic
                        payload
                    case envelopeResult of
                      Left err ->
                        pure (Left (RetainedCustodyDestinationEnvelopeFailed err))
                      Right envelope -> do
                        encodedResult <- pure (encodeRetainedDestinationEnvelope schema envelope)
                        case encodedResult of
                          Left err ->
                            pure (Left (RetainedCustodyDestinationEnvelopeFailed err))
                          Right encoded -> do
                            receiptResult <-
                              retainedCustodyHmac boundary (rewrapReceiptInput schema source intent encoded)
                            pure $ do
                              receiptText <- first (const RetainedCustodyHmacUnavailable) receiptResult
                              receiptRef <- hmacRef receiptText
                              Right
                                RetainedCustodyRewrapResult
                                  { retainedCustodyDestinationEnvelope = envelope
                                  , retainedCustodyDestinationReceipt =
                                      RetainedCustodyRewrapReceipt
                                        { internalRewrapReceiptRef = receiptRef
                                        , internalRewrapEnvelopeDigest =
                                            sha256TargetValueDigest encoded
                                        }
                                  }

retireRetainedCustody
  :: (Monad m)
  => SRetainedMaterialSchema schema
  -> RetainedCustodyVaultBoundary schema m
  -> RetainedMaterialSource schema
  -> m (Either RetainedCustodyWorkerError RetainedCustodyRetirementResult)
retireRetainedCustody schema boundary source = do
  before <- retainedCustodyReadVersion boundary version
  case before of
    Left _ -> pure (Left RetainedCustodyDataUnavailable)
    Right RetainedCustodyVersionMissing -> absence RetainedCustodyAlreadyAbsent
    Right (RetainedCustodyVersionPresent fields) ->
      case validateSourceFields schema source fields of
        Left err -> pure (Left err)
        Right _ -> do
          deleted <- retainedCustodyTombstoneVersion boundary version
          case deleted of
            Left _ -> pure (Left RetainedCustodyTombstoneFailed)
            Right () -> absence RetainedCustodyRetired
 where
  version = retainedSourceVaultVersion source
  absence constructor = do
    absent <- retainedCustodyObserveVersionAbsent boundary version
    case absent of
      Left _ -> pure (Left RetainedCustodyAbsenceUnobservable)
      Right False -> pure (Left RetainedCustodyStillPresent)
      Right True -> do
        hmacResult <-
          retainedCustodyHmac
            boundary
            ( LazyByteString.toStrict
                ( serialise
                    ( retainedCustodyWireVersion
                    , ("retire" :: Text)
                    , retainedMaterialSchemaToken schema
                    , retainedMaterialRefText (retainedSourceReceiptRef source)
                    , version
                    )
                )
            )
        pure $ do
          raw <- first (const RetainedCustodyHmacUnavailable) hmacResult
          ref <- hmacRef raw
          Right (constructor ref)

sourceFromObservations
  :: SRetainedMaterialSchema schema
  -> AuthorityTime
  -> RetainedCustodyDataObservation
  -> RetainedCustodyMetadataObservation
  -> Either Text (RetainedMaterialSource schema)
sourceFromObservations schema observedAt dataObservation metadataObservation = do
  (dataVersion, fields) <- case dataObservation of
    RetainedCustodyDataMissing -> Left "retained custody data is missing while metadata exists"
    RetainedCustodyDataPresent version value -> Right (version, value)
  identity <- first renderWorkerError (metadataIdentity schema metadataObservation)
  (generation, operation, receipt, commitment, digest, metadataVersion) <-
    maybe (Left "retained custody metadata is missing while data exists") Right identity
  unless (metadataVersion == dataVersion) (Left "retained custody metadata version differs")
  ciphertext <- required ciphertextField fields
  unless
    ( Map.keysSet fields == Map.keysSet dataShape
        && Map.lookup schemaField fields == Just (retainedMaterialSchemaToken schema)
        && Map.lookup operationField fields == Just (retainedMaterialRefText operation)
        && Map.lookup generationField fields
          == Just (naturalText (credentialGenerationValue generation))
        && Map.lookup commitmentField fields
          == Just (retainedMaterialRefText commitment)
        && Map.lookup ciphertextDigestField fields
          == Just (targetValueDigestText digest)
        && sha256TargetValueDigest (TextEncoding.encodeUtf8 ciphertext) == digest
    )
    (Left "retained custody data and metadata identities differ")
  first renderWorkerError (validateTransitCiphertext ciphertext)
  first (Text.pack . show) $
    mkRetainedMaterialSource
      generation
      operation
      receipt
      digest
      commitment
      dataVersion
      observedAt
 where
  dataShape :: Map Text Text
  dataShape =
    Map.fromList
      [ (ciphertextField, "")
      , (schemaField, "")
      , (operationField, "")
      , (generationField, "")
      , (commitmentField, "")
      , (ciphertextDigestField, "")
      ]

metadataIdentity
  :: SRetainedMaterialSchema schema
  -> RetainedCustodyMetadataObservation
  -> Either
       RetainedCustodyWorkerError
       ( Maybe
           ( CredentialGeneration
           , RetainedMaterialRef
           , RetainedMaterialRef
           , RetainedMaterialRef
           , TargetValueDigest
           , Natural
           )
       )
metadataIdentity _ RetainedCustodyMetadataMissing = Right Nothing
metadataIdentity schema (RetainedCustodyMetadataPresent version fields) = do
  unless
    (Map.keysSet fields == Map.keysSet (metadataShape schema version))
    (Left RetainedCustodyMetadataInvalid)
  unless
    (Map.lookup schemaField fields == Just (retainedMaterialSchemaToken schema))
    (Left RetainedCustodyMetadataInvalid)
  generation <- fieldNatural generationField fields >>= generationValue
  operation <- fieldRef operationField fields
  receipt <- fieldRef receiptField fields
  commitment <- fieldRef commitmentField fields
  digest <- fieldDigest ciphertextDigestField fields
  metadataVersion <- fieldNatural vaultVersionField fields
  unless (metadataVersion == version) (Left RetainedCustodyMetadataInvalid)
  Right (Just (generation, operation, receipt, commitment, digest, metadataVersion))

metadataShape :: SRetainedMaterialSchema schema -> Natural -> Map Text Text
metadataShape schema version =
  Map.fromList
    [ (schemaField, retainedMaterialSchemaToken schema)
    , (operationField, "")
    , (generationField, "")
    , (receiptField, "")
    , (commitmentField, "")
    , (ciphertextDigestField, "")
    , (vaultVersionField, naturalText version)
    ]

validateSourceFields
  :: SRetainedMaterialSchema schema
  -> RetainedMaterialSource schema
  -> Map Text Text
  -> Either RetainedCustodyWorkerError Text
validateSourceFields schema source fields = do
  unless
    (Map.keysSet fields == Map.keysSet expectedShape)
    (Left RetainedCustodySourceCorrupt)
  ciphertext <- maybe (Left RetainedCustodySourceCorrupt) Right (Map.lookup ciphertextField fields)
  unless
    ( Map.lookup schemaField fields == Just (retainedMaterialSchemaToken schema)
        && Map.lookup operationField fields
          == Just (retainedMaterialRefText (retainedSourceOperationId source))
        && Map.lookup generationField fields
          == Just (naturalText (credentialGenerationValue (retainedSourceGeneration source)))
        && Map.lookup commitmentField fields
          == Just (retainedMaterialRefText (retainedSourceCommitmentRef source))
        && Map.lookup ciphertextDigestField fields
          == Just (targetValueDigestText (retainedSourceCiphertextDigest source))
        && sha256TargetValueDigest (TextEncoding.encodeUtf8 ciphertext)
          == retainedSourceCiphertextDigest source
    )
    (Left RetainedCustodySourceMismatch)
  validateTransitCiphertext ciphertext
  Right ciphertext
 where
  expectedShape :: Map Text Text
  expectedShape =
    Map.fromList
      [ (ciphertextField, "")
      , (schemaField, "")
      , (operationField, "")
      , (generationField, "")
      , (commitmentField, "")
      , (ciphertextDigestField, "")
      ]

dataIdentity
  :: SRetainedMaterialSchema schema
  -> Map Text Text
  -> Either
       RetainedCustodyWorkerError
       (Natural, RetainedMaterialRef, RetainedMaterialRef, TargetValueDigest, Text)
dataIdentity schema fields = do
  unless
    (Map.keysSet fields == Map.keysSet expectedShape)
    (Left RetainedCustodySourceCorrupt)
  unless
    (Map.lookup schemaField fields == Just (retainedMaterialSchemaToken schema))
    (Left RetainedCustodySourceCorrupt)
  generation <- fieldNatural generationField fields
  operation <- fieldRef operationField fields
  commitment <- fieldRef commitmentField fields
  digest <- fieldDigest ciphertextDigestField fields
  ciphertext <-
    maybe
      (Left RetainedCustodySourceCorrupt)
      Right
      (Map.lookup ciphertextField fields)
  validateTransitCiphertext ciphertext
  unless
    (sha256TargetValueDigest (TextEncoding.encodeUtf8 ciphertext) == digest)
    (Left RetainedCustodySourceCorrupt)
  Right (generation, operation, commitment, digest, ciphertext)
 where
  expectedShape :: Map Text Text
  expectedShape =
    Map.fromList
      [ (ciphertextField, "")
      , (schemaField, "")
      , (operationField, "")
      , (generationField, "")
      , (commitmentField, "")
      , (ciphertextDigestField, "")
      ]

validateSchemaPayload
  :: SRetainedMaterialSchema schema
  -> TargetSecretPayload
  -> Either RetainedCustodyWorkerError ByteString
validateSchemaPayload schema payload = do
  unless
    (targetSecretPayloadId payload == schemaTarget schema)
    (Left RetainedCustodyPayloadSchemaMismatch)
  first (const RetainedCustodyPayloadInvalid) (validateTargetSecretPayload payload)
  Right (LazyByteString.toStrict (serialise payload))

decodeSchemaPayload
  :: SRetainedMaterialSchema schema
  -> ByteString
  -> Either RetainedCustodyWorkerError TargetSecretPayload
decodeSchemaPayload schema bytes = do
  payload <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Left _ -> Left RetainedCustodyPayloadInvalid
    Right value -> Right value
  unless
    (LazyByteString.toStrict (serialise payload) == bytes)
    (Left RetainedCustodyPayloadInvalid)
  _ <- validateSchemaPayload schema payload
  Right payload

schemaTarget :: SRetainedMaterialSchema schema -> TargetSecretId
schemaTarget schema = case schema of
  SRetainedSesSmtpMaterial -> TargetSesSmtp
  SRetainedAcmeEabMaterial -> TargetAcmeEab

commitmentInput
  :: SRetainedMaterialSchema schema
  -> RetainedSealIntent schema
  -> ByteString
  -> ByteString
commitmentInput schema intent plaintext =
  LazyByteString.toStrict
    ( serialise
        WireRetainedCommitment
          { wireCommitmentVersion = retainedCustodyWireVersion
          , wireCommitmentDomain = "custody-commitment"
          , wireCommitmentSchema = retainedMaterialSchemaToken schema
          , wireCommitmentOperationId = retainedMaterialRefText (retainedSealOperationId intent)
          , wireCommitmentGeneration = credentialGenerationValue (retainedSealGeneration intent)
          , wireCommitmentBindingDigest = targetValueDigestText (retainedSealBindingDigest intent)
          , wireCommitmentMaterial = plaintext
          }
    )

receiptInput
  :: SRetainedMaterialSchema schema
  -> RetainedSealIntent schema
  -> Text
  -> ByteString
receiptInput schema intent ciphertext =
  LazyByteString.toStrict
    ( serialise
        WireRetainedReceipt
          { wireReceiptVersion = retainedCustodyWireVersion
          , wireReceiptDomain = "custody-seal-receipt"
          , wireReceiptSchema = retainedMaterialSchemaToken schema
          , wireReceiptOperationId = retainedMaterialRefText (retainedSealOperationId intent)
          , wireReceiptGeneration = credentialGenerationValue (retainedSealGeneration intent)
          , wireReceiptCiphertextDigest =
              targetValueDigestText
                (sha256TargetValueDigest (TextEncoding.encodeUtf8 ciphertext))
          }
    )

rewrapReceiptInput
  :: SRetainedMaterialSchema schema
  -> RetainedMaterialSource schema
  -> RetainedDeliveryIntent schema
  -> ByteString
  -> ByteString
rewrapReceiptInput schema source intent envelope =
  LazyByteString.toStrict
    ( serialise
        ( retainedCustodyWireVersion
        , ("custody-rewrap-receipt" :: Text)
        , retainedMaterialSchemaToken schema
        , retainedMaterialRefText (retainedDeliveryOperationId intent)
        , retainedMaterialRefText (retainedSourceReceiptRef source)
        , targetValueDigestText (sha256TargetValueDigest envelope)
        )
    )

validateTransitCiphertext :: Text -> Either RetainedCustodyWorkerError ()
validateTransitCiphertext value
  | Text.null value || Text.length value > 256 * 1024 =
      Left RetainedCustodyTransitCiphertextInvalid
  | not ("vault:v" `Text.isPrefixOf` value) =
      Left RetainedCustodyTransitCiphertextInvalid
  | otherwise = Right ()

hmacRef :: Text -> Either RetainedCustodyWorkerError RetainedMaterialRef
hmacRef value
  | Text.null value || Text.length value > 512 = Left RetainedCustodyHmacInvalid
  | not ("vault:v" `Text.isPrefixOf` value) = Left RetainedCustodyHmacInvalid
  | otherwise = first (const RetainedCustodyHmacInvalid) (mkRetainedMaterialRef value)

fieldNatural
  :: Text -> Map Text Text -> Either RetainedCustodyWorkerError Natural
fieldNatural name fields = case Map.lookup name fields >>= readNatural of
  Nothing -> Left RetainedCustodyMetadataInvalid
  Just value -> Right value

fieldRef
  :: Text -> Map Text Text -> Either RetainedCustodyWorkerError RetainedMaterialRef
fieldRef name fields =
  maybe (Left RetainedCustodyMetadataInvalid) hmacOrOpaque (Map.lookup name fields)
 where
  hmacOrOpaque = first (const RetainedCustodyMetadataInvalid) . mkRetainedMaterialRef

fieldDigest
  :: Text -> Map Text Text -> Either RetainedCustodyWorkerError TargetValueDigest
fieldDigest name fields =
  maybe
    (Left RetainedCustodyMetadataInvalid)
    (first (const RetainedCustodyMetadataInvalid) . mkTargetValueDigest)
    (Map.lookup name fields)

generationValue
  :: Natural -> Either RetainedCustodyWorkerError CredentialGeneration
generationValue =
  first (const RetainedCustodyMetadataInvalid) . mkCredentialGeneration

required :: Text -> Map Text Text -> Either Text Text
required name fields =
  maybe (Left ("missing retained custody field " <> name)) Right (Map.lookup name fields)

readNatural :: Text -> Maybe Natural
readNatural value = case reads (Text.unpack value) of
  [(number, "")] -> Just number
  _ -> Nothing

naturalText :: Natural -> Text
naturalText = Text.pack . show

bounded :: Text -> Text
bounded = Text.take 256

renderWorkerError :: RetainedCustodyWorkerError -> Text
renderWorkerError = Text.pack . show

mapTextLeft
  :: Either RetainedCustodyWorkerError value
  -> Either Text value
mapTextLeft = first renderWorkerError

ciphertextField, schemaField, operationField, generationField :: Text
receiptField, commitmentField, ciphertextDigestField, vaultVersionField :: Text
ciphertextField = "ciphertext"
schemaField = "schema"
operationField = "operation_id"
generationField = "generation"
receiptField = "receipt"
commitmentField = "commitment"
ciphertextDigestField = "ciphertext_digest"
vaultVersionField = "vault_version"
