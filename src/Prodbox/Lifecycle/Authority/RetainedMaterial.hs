{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | Ciphertext-only Authority state for retained SMTP and ACME EAB custody.
--
-- Plaintext is deliberately absent from this module.  A Credential
-- Provisioner hands a schema-indexed source directly to an attested home
-- custody worker; the Authority records only the worker's opaque receipt,
-- ciphertext digest, commitment reference, and metadata read-back.  Delivery
-- can start only from that receipt-committed current source and an exact flat
-- custody observation.  Rotation retains the predecessor until its grace
-- deadline and every dependent delivery are closed.
module Prodbox.Lifecycle.Authority.RetainedMaterial
  ( RetainedMaterialSchema (..)
  , SRetainedMaterialSchema (..)
  , retainedMaterialSchemaToken
  , RetainedMaterialCoordinate
  , retainedCustodyCoordinate
  , retainedDeliveryOutboxCoordinate
  , retainedMaterialCoordinateLogicalName
  , RetainedMaterialRef
  , mkRetainedMaterialRef
  , retainedMaterialRefText
  , RetainedMaterialTarget
  , mkRetainedMaterialTarget
  , retainedMaterialTargetText
  , retainedMaterialTargetSecretPath
  , RetainedMaterialSource
  , mkRetainedMaterialSource
  , retainedSourceGeneration
  , retainedSourceOperationId
  , retainedSourceReceiptRef
  , retainedSourceCiphertextDigest
  , retainedSourceCommitmentRef
  , retainedSourceVaultVersion
  , RetainedSealIntent
  , mkRetainedSealIntent
  , retainedSealOperationId
  , retainedSealGeneration
  , retainedSealPermitRef
  , retainedSealBindingDigest
  , retainedSealDeadline
  , retainedSealPredecessorGraceUntil
  , RetainedDeliveryIntent
  , mkRetainedDeliveryIntent
  , retainedDeliveryOperationId
  , retainedDeliverySourceReceipt
  , retainedDeliveryTarget
  , retainedDeliveryTargetGeneration
  , retainedDeliveryAttestationRef
  , retainedDeliveryEphemeralKeyDigest
  , retainedDeliveryDeadline
  , retainedDeliverySuccessorOperationId
  , RetainedDeliveryReceipt
  , mkRetainedDeliveryReceipt
  , retainedDeliveryReceiptOperationId
  , retainedDeliveryReceiptSource
  , retainedDeliveryReceiptTarget
  , retainedDeliveryReceiptGeneration
  , retainedDeliveryReceiptTargetVersion
  , retainedDeliveryReceiptCommitmentRef
  , RetainedCustodyObservation (..)
  , RetainedMaterialAggregate
  , initialRetainedMaterialAggregate
  , retainedMaterialCurrent
  , retainedMaterialSuperseded
  , retainedMaterialPendingSeal
  , retainedMaterialPendingDeliveries
  , retainedMaterialCompletedDeliveries
  , RetainedMaterialCodecError (..)
  , retainedMaterialMaximumEncodedBytes
  , encodeRetainedMaterialAggregate
  , decodeRetainedMaterialAggregate
  , RetainedMaterialCommand (..)
  , RetainedMaterialDecision (..)
  , RetainedMaterialRefusal (..)
  , decideRetainedMaterial
  , applyRetainedMaterialDecision
  , stepRetainedMaterial
  , retainedMaterialInvariantViolations
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (find, nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16, Word8)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBObjectCoordinate
  , StoreLifetime (ClusterRetained, CrossClusterDurable)
  , mkClusterRetainedCoordinate
  , mkCrossClusterDurableCoordinate
  , modelBObjectLogicalName
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
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

-- | The only operator-material families retained across substrates.  TLS is
-- intentionally absent; it has a separate envelope protocol.
data RetainedMaterialSchema
  = RetainedSesSmtpMaterial
  | RetainedAcmeEabMaterial
  deriving stock (Eq, Ord, Show, Generic)

data SRetainedMaterialSchema (schema :: RetainedMaterialSchema) where
  SRetainedSesSmtpMaterial
    :: SRetainedMaterialSchema 'RetainedSesSmtpMaterial
  SRetainedAcmeEabMaterial
    :: SRetainedMaterialSchema 'RetainedAcmeEabMaterial

deriving instance Eq (SRetainedMaterialSchema schema)
deriving instance Show (SRetainedMaterialSchema schema)

retainedMaterialSchemaToken :: SRetainedMaterialSchema schema -> Text
retainedMaterialSchemaToken schema = case schema of
  SRetainedSesSmtpMaterial -> "ses-smtp-source"
  SRetainedAcmeEabMaterial -> "acme-eab-source"

-- | A durability-indexed retained coordinate.  The constructors are private;
-- only the retained primary and cross-cluster outbox builders are exported, so
-- a chart-lifetime coordinate cannot be formed or coerced into this lane.
type role RetainedMaterialCoordinate nominal nominal

newtype
  RetainedMaterialCoordinate
    (lifetime :: StoreLifetime)
    (schema :: RetainedMaterialSchema)
  = RetainedMaterialCoordinate (ModelBObjectCoordinate lifetime)
  deriving stock (Eq, Show)

retainedCustodyCoordinate
  :: LongLivedCheckpointAuthority
  -> SRetainedMaterialSchema schema
  -> Either Text (RetainedMaterialCoordinate 'ClusterRetained schema)
retainedCustodyCoordinate authority schema =
  mapLeft (Text.pack . show) $
    RetainedMaterialCoordinate
      <$> mkClusterRetainedCoordinate
        authority
        ("retained-material/custody/" <> retainedMaterialSchemaToken schema)

retainedDeliveryOutboxCoordinate
  :: LongLivedCheckpointAuthority
  -> SRetainedMaterialSchema schema
  -> RetainedMaterialTarget schema
  -> Either Text (RetainedMaterialCoordinate 'CrossClusterDurable schema)
retainedDeliveryOutboxCoordinate authority schema target =
  mapLeft (Text.pack . show) $
    RetainedMaterialCoordinate
      <$> mkCrossClusterDurableCoordinate
        authority
        ( Text.intercalate
            "/"
            [ "retained-material/delivery"
            , retainedMaterialSchemaToken schema
            , retainedMaterialTargetText target
            ]
        )

retainedMaterialCoordinateLogicalName
  :: RetainedMaterialCoordinate lifetime schema -> Text
retainedMaterialCoordinateLogicalName (RetainedMaterialCoordinate coordinate) =
  modelBObjectLogicalName coordinate

-- | Opaque receipt, commitment, attestation, and absence references share the
-- same bounded identifier representation.  They are references to
-- authenticated evidence, never hashes of plaintext material.
newtype RetainedMaterialRef = RetainedMaterialRef Text
  deriving stock (Eq, Ord, Show, Generic)

mkRetainedMaterialRef :: Text -> Either Text RetainedMaterialRef
mkRetainedMaterialRef raw = RetainedMaterialRef <$> validateIdentifier "retained material reference" 512 raw

retainedMaterialRefText :: RetainedMaterialRef -> Text
retainedMaterialRefText (RetainedMaterialRef value) = value

-- | The Authority alone derives the next delivery operation. The fixed
-- domain separator and canonical predecessor text make retries converge on
-- one opaque successor without exposing an ordinal for callers to choose.
retainedDeliverySuccessorOperationId
  :: RetainedMaterialRef -> RetainedMaterialRef
retainedDeliverySuccessorOperationId predecessor =
  case mkRetainedMaterialRef ("delivery-successor-v1:" <> digest) of
    Left _ -> error "retained delivery successor reference invariant violated"
    Right successor -> successor
 where
  digest =
    targetValueDigestText
      ( sha256TargetValueDigest
          ( TextEncoding.encodeUtf8
              ("retained-delivery-successor-v1:" <> retainedMaterialRefText predecessor)
          )
      )

type role RetainedMaterialTarget nominal

data RetainedMaterialTarget (schema :: RetainedMaterialSchema) where
  RetainedSesSmtpTarget
    :: !Text -> RetainedMaterialTarget 'RetainedSesSmtpMaterial
  RetainedAcmeEabTarget
    :: !Text -> RetainedMaterialTarget 'RetainedAcmeEabMaterial

deriving instance Eq (RetainedMaterialTarget schema)
deriving instance Ord (RetainedMaterialTarget schema)
deriving instance Show (RetainedMaterialTarget schema)

mkRetainedMaterialTarget
  :: SRetainedMaterialSchema schema
  -> Text
  -> Either Text (RetainedMaterialTarget schema)
mkRetainedMaterialTarget schema raw = do
  identity <- validateIdentifier "retained material target identity" 160 raw
  pure $ case schema of
    SRetainedSesSmtpMaterial -> RetainedSesSmtpTarget identity
    SRetainedAcmeEabMaterial -> RetainedAcmeEabTarget identity

retainedMaterialTargetText :: RetainedMaterialTarget schema -> Text
retainedMaterialTargetText target = case target of
  RetainedSesSmtpTarget value -> value
  RetainedAcmeEabTarget value -> value

-- | Exact local Vault target selected solely by the schema index.  Callers
-- can choose a registered substrate identity, never a secret path.
retainedMaterialTargetSecretPath :: RetainedMaterialTarget schema -> Text
retainedMaterialTargetSecretPath target = case target of
  RetainedSesSmtpTarget _ -> "secret/keycloak/smtp"
  RetainedAcmeEabTarget _ -> "secret/acme/eab"

-- | Ciphertext-only custody read-back committed as the current source.
type role RetainedMaterialSource nominal

data RetainedMaterialSource (schema :: RetainedMaterialSchema) = RetainedMaterialSource
  { internalRetainedSourceGeneration :: !CredentialGeneration
  , internalRetainedSourceOperationId :: !RetainedMaterialRef
  , internalRetainedSourceReceiptRef :: !RetainedMaterialRef
  , internalRetainedSourceCiphertextDigest :: !TargetValueDigest
  , internalRetainedSourceCommitmentRef :: !RetainedMaterialRef
  , internalRetainedSourceVaultVersion :: !Natural
  , internalRetainedSourceReadBackAt :: !AuthorityTime
  }
  deriving stock (Eq, Show, Generic)

mkRetainedMaterialSource
  :: CredentialGeneration
  -> RetainedMaterialRef
  -> RetainedMaterialRef
  -> TargetValueDigest
  -> RetainedMaterialRef
  -> Natural
  -> AuthorityTime
  -> Either Text (RetainedMaterialSource schema)
mkRetainedMaterialSource generation operationId receiptRef ciphertextDigest commitmentRef vaultVersion readBackAt
  | vaultVersion == 0 = Left "retained material Vault version must be positive"
  | otherwise =
      Right
        RetainedMaterialSource
          { internalRetainedSourceGeneration = generation
          , internalRetainedSourceOperationId = operationId
          , internalRetainedSourceReceiptRef = receiptRef
          , internalRetainedSourceCiphertextDigest = ciphertextDigest
          , internalRetainedSourceCommitmentRef = commitmentRef
          , internalRetainedSourceVaultVersion = vaultVersion
          , internalRetainedSourceReadBackAt = readBackAt
          }

retainedSourceGeneration :: RetainedMaterialSource schema -> CredentialGeneration
retainedSourceGeneration = internalRetainedSourceGeneration

retainedSourceOperationId :: RetainedMaterialSource schema -> RetainedMaterialRef
retainedSourceOperationId = internalRetainedSourceOperationId

retainedSourceReceiptRef :: RetainedMaterialSource schema -> RetainedMaterialRef
retainedSourceReceiptRef = internalRetainedSourceReceiptRef

retainedSourceCiphertextDigest :: RetainedMaterialSource schema -> TargetValueDigest
retainedSourceCiphertextDigest = internalRetainedSourceCiphertextDigest

retainedSourceCommitmentRef :: RetainedMaterialSource schema -> RetainedMaterialRef
retainedSourceCommitmentRef = internalRetainedSourceCommitmentRef

retainedSourceVaultVersion :: RetainedMaterialSource schema -> Natural
retainedSourceVaultVersion = internalRetainedSourceVaultVersion

-- | Secret-free, receipt-committed custody intent.  On rotation the old source
-- is retained at least until the supplied absolute grace deadline.
type role RetainedSealIntent nominal

data RetainedSealIntent (schema :: RetainedMaterialSchema) = RetainedSealIntent
  { internalRetainedSealOperationId :: !RetainedMaterialRef
  , internalRetainedSealGeneration :: !CredentialGeneration
  , internalRetainedSealPermitRef :: !RetainedMaterialRef
  , internalRetainedSealBindingDigest :: !TargetValueDigest
  , internalRetainedSealDeadline :: !AuthorityTime
  , internalRetainedSealPredecessorGraceUntil :: !AuthorityTime
  }
  deriving stock (Eq, Show, Generic)

mkRetainedSealIntent
  :: RetainedMaterialRef
  -> CredentialGeneration
  -> RetainedMaterialRef
  -> TargetValueDigest
  -> AuthorityTime
  -> AuthorityTime
  -> Either Text (RetainedSealIntent schema)
mkRetainedSealIntent operationId generation permitRef bindingDigest deadline graceUntil
  | authorityTimeMicros graceUntil < authorityTimeMicros deadline =
      Left "retained predecessor grace cannot end before the seal deadline"
  | otherwise =
      Right
        RetainedSealIntent
          { internalRetainedSealOperationId = operationId
          , internalRetainedSealGeneration = generation
          , internalRetainedSealPermitRef = permitRef
          , internalRetainedSealBindingDigest = bindingDigest
          , internalRetainedSealDeadline = deadline
          , internalRetainedSealPredecessorGraceUntil = graceUntil
          }

retainedSealOperationId :: RetainedSealIntent schema -> RetainedMaterialRef
retainedSealOperationId = internalRetainedSealOperationId

retainedSealGeneration :: RetainedSealIntent schema -> CredentialGeneration
retainedSealGeneration = internalRetainedSealGeneration

retainedSealPermitRef :: RetainedSealIntent schema -> RetainedMaterialRef
retainedSealPermitRef = internalRetainedSealPermitRef

retainedSealBindingDigest :: RetainedSealIntent schema -> TargetValueDigest
retainedSealBindingDigest = internalRetainedSealBindingDigest

retainedSealDeadline :: RetainedSealIntent schema -> AuthorityTime
retainedSealDeadline = internalRetainedSealDeadline

retainedSealPredecessorGraceUntil :: RetainedSealIntent schema -> AuthorityTime
retainedSealPredecessorGraceUntil = internalRetainedSealPredecessorGraceUntil

type role RetainedDeliveryIntent nominal

data RetainedDeliveryIntent (schema :: RetainedMaterialSchema) = RetainedDeliveryIntent
  { internalRetainedDeliveryOperationId :: !RetainedMaterialRef
  , internalRetainedDeliverySourceReceipt :: !RetainedMaterialRef
  , internalRetainedDeliveryTarget :: !(RetainedMaterialTarget schema)
  , internalRetainedDeliveryTargetGeneration :: !CredentialGeneration
  , internalRetainedDeliveryAttestationRef :: !RetainedMaterialRef
  , internalRetainedDeliveryEphemeralKeyDigest :: !TargetValueDigest
  , internalRetainedDeliveryDeadline :: !AuthorityTime
  }
  deriving stock (Eq, Show, Generic)

mkRetainedDeliveryIntent
  :: RetainedMaterialRef
  -> RetainedMaterialRef
  -> RetainedMaterialTarget schema
  -> CredentialGeneration
  -> RetainedMaterialRef
  -> TargetValueDigest
  -> AuthorityTime
  -> RetainedDeliveryIntent schema
mkRetainedDeliveryIntent operationId sourceReceipt target generation attestationRef ephemeralKeyDigest deadline =
  RetainedDeliveryIntent
    { internalRetainedDeliveryOperationId = operationId
    , internalRetainedDeliverySourceReceipt = sourceReceipt
    , internalRetainedDeliveryTarget = target
    , internalRetainedDeliveryTargetGeneration = generation
    , internalRetainedDeliveryAttestationRef = attestationRef
    , internalRetainedDeliveryEphemeralKeyDigest = ephemeralKeyDigest
    , internalRetainedDeliveryDeadline = deadline
    }

retainedDeliveryOperationId
  :: RetainedDeliveryIntent schema -> RetainedMaterialRef
retainedDeliveryOperationId = internalRetainedDeliveryOperationId

retainedDeliverySourceReceipt
  :: RetainedDeliveryIntent schema -> RetainedMaterialRef
retainedDeliverySourceReceipt = internalRetainedDeliverySourceReceipt

retainedDeliveryTarget
  :: RetainedDeliveryIntent schema -> RetainedMaterialTarget schema
retainedDeliveryTarget = internalRetainedDeliveryTarget

retainedDeliveryTargetGeneration
  :: RetainedDeliveryIntent schema -> CredentialGeneration
retainedDeliveryTargetGeneration = internalRetainedDeliveryTargetGeneration

retainedDeliveryAttestationRef
  :: RetainedDeliveryIntent schema -> RetainedMaterialRef
retainedDeliveryAttestationRef = internalRetainedDeliveryAttestationRef

retainedDeliveryEphemeralKeyDigest
  :: RetainedDeliveryIntent schema -> TargetValueDigest
retainedDeliveryEphemeralKeyDigest = internalRetainedDeliveryEphemeralKeyDigest

retainedDeliveryDeadline :: RetainedDeliveryIntent schema -> AuthorityTime
retainedDeliveryDeadline = internalRetainedDeliveryDeadline

type role RetainedDeliveryReceipt nominal

data RetainedDeliveryReceipt (schema :: RetainedMaterialSchema) = RetainedDeliveryReceipt
  { internalRetainedDeliveryReceiptOperationId :: !RetainedMaterialRef
  , internalRetainedDeliveryReceiptSource :: !RetainedMaterialRef
  , internalRetainedDeliveryReceiptTarget :: !(RetainedMaterialTarget schema)
  , internalRetainedDeliveryReceiptGeneration :: !CredentialGeneration
  , internalRetainedDeliveryReceiptTargetVersion :: !Natural
  , internalRetainedDeliveryReceiptCommitmentRef :: !RetainedMaterialRef
  }
  deriving stock (Eq, Show, Generic)

mkRetainedDeliveryReceipt
  :: RetainedMaterialRef
  -> RetainedMaterialRef
  -> RetainedMaterialTarget schema
  -> CredentialGeneration
  -> Natural
  -> RetainedMaterialRef
  -> Either Text (RetainedDeliveryReceipt schema)
mkRetainedDeliveryReceipt operationId source target generation targetVersion commitmentRef
  | targetVersion == 0 = Left "retained material target version must be positive"
  | otherwise =
      Right
        RetainedDeliveryReceipt
          { internalRetainedDeliveryReceiptOperationId = operationId
          , internalRetainedDeliveryReceiptSource = source
          , internalRetainedDeliveryReceiptTarget = target
          , internalRetainedDeliveryReceiptGeneration = generation
          , internalRetainedDeliveryReceiptTargetVersion = targetVersion
          , internalRetainedDeliveryReceiptCommitmentRef = commitmentRef
          }

retainedDeliveryReceiptOperationId
  :: RetainedDeliveryReceipt schema -> RetainedMaterialRef
retainedDeliveryReceiptOperationId = internalRetainedDeliveryReceiptOperationId

retainedDeliveryReceiptSource
  :: RetainedDeliveryReceipt schema -> RetainedMaterialRef
retainedDeliveryReceiptSource = internalRetainedDeliveryReceiptSource

retainedDeliveryReceiptTarget
  :: RetainedDeliveryReceipt schema -> RetainedMaterialTarget schema
retainedDeliveryReceiptTarget = internalRetainedDeliveryReceiptTarget

retainedDeliveryReceiptGeneration
  :: RetainedDeliveryReceipt schema -> CredentialGeneration
retainedDeliveryReceiptGeneration = internalRetainedDeliveryReceiptGeneration

retainedDeliveryReceiptTargetVersion
  :: RetainedDeliveryReceipt schema -> Natural
retainedDeliveryReceiptTargetVersion = internalRetainedDeliveryReceiptTargetVersion

retainedDeliveryReceiptCommitmentRef
  :: RetainedDeliveryReceipt schema -> RetainedMaterialRef
retainedDeliveryReceiptCommitmentRef =
  internalRetainedDeliveryReceiptCommitmentRef

-- | Flat custody observation.  Missing, corrupt, digest mismatch, and
-- unobservable are never collapsed.  Only 'RetainedCustodyPresent' for the
-- exact current source can authorize rewrap.
type role RetainedCustodyObservation nominal

data RetainedCustodyObservation (schema :: RetainedMaterialSchema)
  = RetainedCustodyPresent !(RetainedMaterialSource schema)
  | RetainedCustodyPositivelyAbsent !RetainedMaterialRef
  | RetainedCustodyCorrupt !Text
  | RetainedCustodyDigestMismatch !TargetValueDigest !TargetValueDigest
  | RetainedCustodyUnobservable !Text
  deriving stock (Eq, Show, Generic)

type role SupersededSource nominal

data SupersededSource (schema :: RetainedMaterialSchema) = SupersededSource
  { supersededSourceValue :: !(RetainedMaterialSource schema)
  , supersededSourceGraceUntil :: !AuthorityTime
  }
  deriving stock (Eq, Show, Generic)

type role RetainedMaterialAggregate nominal

data RetainedMaterialAggregate (schema :: RetainedMaterialSchema) = RetainedMaterialAggregate
  { internalRetainedMaterialCurrent :: !(Maybe (RetainedMaterialSource schema))
  , internalRetainedMaterialPendingSeal :: !(Maybe (RetainedSealIntent schema))
  , internalRetainedMaterialSuperseded :: ![SupersededSource schema]
  , internalRetainedMaterialPendingDeliveries :: ![RetainedDeliveryIntent schema]
  , internalRetainedMaterialCompletedDeliveries :: ![RetainedDeliveryReceipt schema]
  , internalRetainedMaterialPendingRetirements :: ![RetainedMaterialRef]
  }
  deriving stock (Eq, Show, Generic)

initialRetainedMaterialAggregate :: RetainedMaterialAggregate schema
initialRetainedMaterialAggregate =
  RetainedMaterialAggregate
    { internalRetainedMaterialCurrent = Nothing
    , internalRetainedMaterialPendingSeal = Nothing
    , internalRetainedMaterialSuperseded = []
    , internalRetainedMaterialPendingDeliveries = []
    , internalRetainedMaterialCompletedDeliveries = []
    , internalRetainedMaterialPendingRetirements = []
    }

retainedMaterialCurrent
  :: RetainedMaterialAggregate schema -> Maybe (RetainedMaterialSource schema)
retainedMaterialCurrent = internalRetainedMaterialCurrent

retainedMaterialSuperseded
  :: RetainedMaterialAggregate schema -> [RetainedMaterialSource schema]
retainedMaterialSuperseded = map supersededSourceValue . internalRetainedMaterialSuperseded

retainedMaterialPendingSeal
  :: RetainedMaterialAggregate schema -> Maybe (RetainedSealIntent schema)
retainedMaterialPendingSeal = internalRetainedMaterialPendingSeal

retainedMaterialPendingDeliveries
  :: RetainedMaterialAggregate schema -> [RetainedDeliveryIntent schema]
retainedMaterialPendingDeliveries = internalRetainedMaterialPendingDeliveries

retainedMaterialCompletedDeliveries
  :: RetainedMaterialAggregate schema -> [RetainedDeliveryReceipt schema]
retainedMaterialCompletedDeliveries = internalRetainedMaterialCompletedDeliveries

-- | Durable wire state is deliberately separate from the domain ADTs.  This
-- keeps recovery on the same smart-constructor and invariant path as a new
-- command, and prevents a CBOR payload for one material family from being
-- decoded at the other family's type index.
data WireRetainedMaterialSource = WireRetainedMaterialSource
  { wireRetainedSourceGeneration :: !Natural
  , wireRetainedSourceOperationId :: !Text
  , wireRetainedSourceReceiptRef :: !Text
  , wireRetainedSourceCiphertextDigest :: !Text
  , wireRetainedSourceCommitmentRef :: !Text
  , wireRetainedSourceVaultVersion :: !Natural
  , wireRetainedSourceReadBackAt :: !Natural
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (Serialise)

data WireRetainedSealIntent = WireRetainedSealIntent
  { wireRetainedSealOperationId :: !Text
  , wireRetainedSealGeneration :: !Natural
  , wireRetainedSealPermitRef :: !Text
  , wireRetainedSealBindingDigest :: !Text
  , wireRetainedSealDeadline :: !Natural
  , wireRetainedSealPredecessorGraceUntil :: !Natural
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (Serialise)

data WireRetainedDeliveryIntent = WireRetainedDeliveryIntent
  { wireRetainedDeliveryOperationId :: !Text
  , wireRetainedDeliverySourceReceipt :: !Text
  , wireRetainedDeliveryTarget :: !Text
  , wireRetainedDeliveryTargetGeneration :: !Natural
  , wireRetainedDeliveryAttestationRef :: !Text
  , wireRetainedDeliveryEphemeralKeyDigest :: !Text
  , wireRetainedDeliveryDeadline :: !Natural
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (Serialise)

data WireRetainedDeliveryReceipt = WireRetainedDeliveryReceipt
  { wireRetainedDeliveryReceiptOperationId :: !Text
  , wireRetainedDeliveryReceiptSource :: !Text
  , wireRetainedDeliveryReceiptTarget :: !Text
  , wireRetainedDeliveryReceiptGeneration :: !Natural
  , wireRetainedDeliveryReceiptTargetVersion :: !Natural
  , wireRetainedDeliveryReceiptCommitmentRef :: !Text
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (Serialise)

data WireSupersededSource = WireSupersededSource
  { wireSupersededSourceValue :: !WireRetainedMaterialSource
  , wireSupersededSourceGraceUntil :: !Natural
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (Serialise)

data WireRetainedMaterialAggregate = WireRetainedMaterialAggregate
  { wireRetainedMaterialVersion :: !Word16
  , wireRetainedMaterialSchema :: !Word8
  , wireRetainedMaterialCurrent :: !(Maybe WireRetainedMaterialSource)
  , wireRetainedMaterialPendingSeal :: !(Maybe WireRetainedSealIntent)
  , wireRetainedMaterialSuperseded :: ![WireSupersededSource]
  , wireRetainedMaterialPendingDeliveries :: ![WireRetainedDeliveryIntent]
  , wireRetainedMaterialCompletedDeliveries :: ![WireRetainedDeliveryReceipt]
  , wireRetainedMaterialPendingRetirements :: ![Text]
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (Serialise)

data RetainedMaterialCodecError
  = RetainedMaterialCodecTooLarge !Int !Int
  | RetainedMaterialCodecDecodeFailed !Text
  | RetainedMaterialCodecUnsupportedVersion !Word16
  | RetainedMaterialCodecSchemaMismatch !Word8 !Word8
  | RetainedMaterialCodecEntryCountExceeded !Text !Int !Int
  | RetainedMaterialCodecInvalidField !Text
  | RetainedMaterialCodecInvalidAggregate ![Text]
  | RetainedMaterialCodecNonCanonical
  deriving stock (Eq, Show)

retainedMaterialMaximumEncodedBytes :: Int
retainedMaterialMaximumEncodedBytes = 4 * 1024 * 1024

retainedMaterialCodecVersion :: Word16
retainedMaterialCodecVersion = 1

encodeRetainedMaterialAggregate
  :: SRetainedMaterialSchema schema
  -> RetainedMaterialAggregate schema
  -> Either RetainedMaterialCodecError ByteString
encodeRetainedMaterialAggregate schema aggregate = do
  validateAggregateForCodec aggregate
  let bytes =
        LazyByteString.toStrict
          (serialise (wireRetainedMaterialAggregate schema aggregate))
  when
    (ByteString.length bytes > retainedMaterialMaximumEncodedBytes)
    ( Left
        ( RetainedMaterialCodecTooLarge
            (ByteString.length bytes)
            retainedMaterialMaximumEncodedBytes
        )
    )
  pure bytes

decodeRetainedMaterialAggregate
  :: SRetainedMaterialSchema schema
  -> ByteString
  -> Either RetainedMaterialCodecError (RetainedMaterialAggregate schema)
decodeRetainedMaterialAggregate schema bytes
  | ByteString.length bytes > retainedMaterialMaximumEncodedBytes =
      Left
        ( RetainedMaterialCodecTooLarge
            (ByteString.length bytes)
            retainedMaterialMaximumEncodedBytes
        )
  | otherwise = do
      wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left err ->
          Left (RetainedMaterialCodecDecodeFailed (Text.pack (show err)))
        Right value -> Right value
      unless
        (wireRetainedMaterialVersion wire == retainedMaterialCodecVersion)
        ( Left
            ( RetainedMaterialCodecUnsupportedVersion
                (wireRetainedMaterialVersion wire)
            )
        )
      let expectedSchema = retainedMaterialSchemaTag schema
      unless
        (wireRetainedMaterialSchema wire == expectedSchema)
        ( Left
            ( RetainedMaterialCodecSchemaMismatch
                expectedSchema
                (wireRetainedMaterialSchema wire)
            )
        )
      unless
        (LazyByteString.toStrict (serialise wire) == bytes)
        (Left RetainedMaterialCodecNonCanonical)
      validateWireEntryCounts wire
      aggregate <- decodeWireRetainedMaterialAggregate schema wire
      validateAggregateForCodec aggregate
      pure aggregate

wireRetainedMaterialAggregate
  :: SRetainedMaterialSchema schema
  -> RetainedMaterialAggregate schema
  -> WireRetainedMaterialAggregate
wireRetainedMaterialAggregate schema aggregate =
  WireRetainedMaterialAggregate
    { wireRetainedMaterialVersion = retainedMaterialCodecVersion
    , wireRetainedMaterialSchema = retainedMaterialSchemaTag schema
    , wireRetainedMaterialCurrent =
        wireRetainedMaterialSource <$> internalRetainedMaterialCurrent aggregate
    , wireRetainedMaterialPendingSeal =
        wireRetainedSealIntent <$> internalRetainedMaterialPendingSeal aggregate
    , wireRetainedMaterialSuperseded =
        map wireSupersededSource (internalRetainedMaterialSuperseded aggregate)
    , wireRetainedMaterialPendingDeliveries =
        map wireRetainedDeliveryIntent (internalRetainedMaterialPendingDeliveries aggregate)
    , wireRetainedMaterialCompletedDeliveries =
        map wireRetainedDeliveryReceipt (internalRetainedMaterialCompletedDeliveries aggregate)
    , wireRetainedMaterialPendingRetirements =
        map retainedMaterialRefText (internalRetainedMaterialPendingRetirements aggregate)
    }

retainedMaterialSchemaTag :: SRetainedMaterialSchema schema -> Word8
retainedMaterialSchemaTag schema = case schema of
  SRetainedSesSmtpMaterial -> 0
  SRetainedAcmeEabMaterial -> 1

wireRetainedMaterialSource
  :: RetainedMaterialSource schema -> WireRetainedMaterialSource
wireRetainedMaterialSource source =
  WireRetainedMaterialSource
    { wireRetainedSourceGeneration =
        credentialGenerationValue (internalRetainedSourceGeneration source)
    , wireRetainedSourceOperationId =
        retainedMaterialRefText (internalRetainedSourceOperationId source)
    , wireRetainedSourceReceiptRef =
        retainedMaterialRefText (internalRetainedSourceReceiptRef source)
    , wireRetainedSourceCiphertextDigest =
        targetValueDigestText (internalRetainedSourceCiphertextDigest source)
    , wireRetainedSourceCommitmentRef =
        retainedMaterialRefText (internalRetainedSourceCommitmentRef source)
    , wireRetainedSourceVaultVersion = internalRetainedSourceVaultVersion source
    , wireRetainedSourceReadBackAt =
        authorityTimeMicros (internalRetainedSourceReadBackAt source)
    }

wireRetainedSealIntent :: RetainedSealIntent schema -> WireRetainedSealIntent
wireRetainedSealIntent intent =
  WireRetainedSealIntent
    { wireRetainedSealOperationId =
        retainedMaterialRefText (internalRetainedSealOperationId intent)
    , wireRetainedSealGeneration =
        credentialGenerationValue (internalRetainedSealGeneration intent)
    , wireRetainedSealPermitRef =
        retainedMaterialRefText (internalRetainedSealPermitRef intent)
    , wireRetainedSealBindingDigest =
        targetValueDigestText (internalRetainedSealBindingDigest intent)
    , wireRetainedSealDeadline = authorityTimeMicros (internalRetainedSealDeadline intent)
    , wireRetainedSealPredecessorGraceUntil =
        authorityTimeMicros (internalRetainedSealPredecessorGraceUntil intent)
    }

wireRetainedDeliveryIntent
  :: RetainedDeliveryIntent schema -> WireRetainedDeliveryIntent
wireRetainedDeliveryIntent intent =
  WireRetainedDeliveryIntent
    { wireRetainedDeliveryOperationId =
        retainedMaterialRefText (internalRetainedDeliveryOperationId intent)
    , wireRetainedDeliverySourceReceipt =
        retainedMaterialRefText (internalRetainedDeliverySourceReceipt intent)
    , wireRetainedDeliveryTarget =
        retainedMaterialTargetText (internalRetainedDeliveryTarget intent)
    , wireRetainedDeliveryTargetGeneration =
        credentialGenerationValue (internalRetainedDeliveryTargetGeneration intent)
    , wireRetainedDeliveryAttestationRef =
        retainedMaterialRefText (internalRetainedDeliveryAttestationRef intent)
    , wireRetainedDeliveryEphemeralKeyDigest =
        targetValueDigestText (internalRetainedDeliveryEphemeralKeyDigest intent)
    , wireRetainedDeliveryDeadline =
        authorityTimeMicros (internalRetainedDeliveryDeadline intent)
    }

wireRetainedDeliveryReceipt
  :: RetainedDeliveryReceipt schema -> WireRetainedDeliveryReceipt
wireRetainedDeliveryReceipt receipt =
  WireRetainedDeliveryReceipt
    { wireRetainedDeliveryReceiptOperationId =
        retainedMaterialRefText (internalRetainedDeliveryReceiptOperationId receipt)
    , wireRetainedDeliveryReceiptSource =
        retainedMaterialRefText (internalRetainedDeliveryReceiptSource receipt)
    , wireRetainedDeliveryReceiptTarget =
        retainedMaterialTargetText (internalRetainedDeliveryReceiptTarget receipt)
    , wireRetainedDeliveryReceiptGeneration =
        credentialGenerationValue (internalRetainedDeliveryReceiptGeneration receipt)
    , wireRetainedDeliveryReceiptTargetVersion =
        internalRetainedDeliveryReceiptTargetVersion receipt
    , wireRetainedDeliveryReceiptCommitmentRef =
        retainedMaterialRefText (internalRetainedDeliveryReceiptCommitmentRef receipt)
    }

wireSupersededSource :: SupersededSource schema -> WireSupersededSource
wireSupersededSource superseded =
  WireSupersededSource
    { wireSupersededSourceValue =
        wireRetainedMaterialSource (supersededSourceValue superseded)
    , wireSupersededSourceGraceUntil =
        authorityTimeMicros (supersededSourceGraceUntil superseded)
    }

decodeWireRetainedMaterialAggregate
  :: SRetainedMaterialSchema schema
  -> WireRetainedMaterialAggregate
  -> Either RetainedMaterialCodecError (RetainedMaterialAggregate schema)
decodeWireRetainedMaterialAggregate schema wire = do
  current <- traverse decodeWireRetainedMaterialSource (wireRetainedMaterialCurrent wire)
  pendingSeal <- traverse decodeWireRetainedSealIntent (wireRetainedMaterialPendingSeal wire)
  superseded <- traverse decodeWireSupersededSource (wireRetainedMaterialSuperseded wire)
  pendingDeliveries <-
    traverse
      (decodeWireRetainedDeliveryIntent schema)
      (wireRetainedMaterialPendingDeliveries wire)
  completedDeliveries <-
    traverse
      (decodeWireRetainedDeliveryReceipt schema)
      (wireRetainedMaterialCompletedDeliveries wire)
  pendingRetirements <-
    traverse
      (decodeRetainedMaterialRef "pending retirement")
      (wireRetainedMaterialPendingRetirements wire)
  pure
    RetainedMaterialAggregate
      { internalRetainedMaterialCurrent = current
      , internalRetainedMaterialPendingSeal = pendingSeal
      , internalRetainedMaterialSuperseded = superseded
      , internalRetainedMaterialPendingDeliveries = pendingDeliveries
      , internalRetainedMaterialCompletedDeliveries = completedDeliveries
      , internalRetainedMaterialPendingRetirements = pendingRetirements
      }

decodeWireRetainedMaterialSource
  :: WireRetainedMaterialSource
  -> Either RetainedMaterialCodecError (RetainedMaterialSource schema)
decodeWireRetainedMaterialSource wire = do
  generation <- decodeCredentialGeneration "source generation" (wireRetainedSourceGeneration wire)
  operationId <- decodeRetainedMaterialRef "source operation" (wireRetainedSourceOperationId wire)
  receiptRef <- decodeRetainedMaterialRef "source receipt" (wireRetainedSourceReceiptRef wire)
  digest <-
    decodeTargetValueDigest "source ciphertext digest" (wireRetainedSourceCiphertextDigest wire)
  commitmentRef <-
    decodeRetainedMaterialRef "source commitment" (wireRetainedSourceCommitmentRef wire)
  mapCodecField
    "source"
    ( mkRetainedMaterialSource
        generation
        operationId
        receiptRef
        digest
        commitmentRef
        (wireRetainedSourceVaultVersion wire)
        (authorityTimeFromMicros (wireRetainedSourceReadBackAt wire))
    )

decodeWireRetainedSealIntent
  :: WireRetainedSealIntent
  -> Either RetainedMaterialCodecError (RetainedSealIntent schema)
decodeWireRetainedSealIntent wire = do
  operationId <- decodeRetainedMaterialRef "seal operation" (wireRetainedSealOperationId wire)
  generation <- decodeCredentialGeneration "seal generation" (wireRetainedSealGeneration wire)
  permitRef <- decodeRetainedMaterialRef "seal permit" (wireRetainedSealPermitRef wire)
  digest <- decodeTargetValueDigest "seal binding digest" (wireRetainedSealBindingDigest wire)
  mapCodecField
    "seal intent"
    ( mkRetainedSealIntent
        operationId
        generation
        permitRef
        digest
        (authorityTimeFromMicros (wireRetainedSealDeadline wire))
        (authorityTimeFromMicros (wireRetainedSealPredecessorGraceUntil wire))
    )

decodeWireRetainedDeliveryIntent
  :: SRetainedMaterialSchema schema
  -> WireRetainedDeliveryIntent
  -> Either RetainedMaterialCodecError (RetainedDeliveryIntent schema)
decodeWireRetainedDeliveryIntent schema wire = do
  operationId <- decodeRetainedMaterialRef "delivery operation" (wireRetainedDeliveryOperationId wire)
  sourceReceipt <-
    decodeRetainedMaterialRef "delivery source receipt" (wireRetainedDeliverySourceReceipt wire)
  target <- decodeRetainedMaterialTarget schema (wireRetainedDeliveryTarget wire)
  generation <-
    decodeCredentialGeneration "delivery generation" (wireRetainedDeliveryTargetGeneration wire)
  attestationRef <-
    decodeRetainedMaterialRef "delivery attestation" (wireRetainedDeliveryAttestationRef wire)
  ephemeralKeyDigest <-
    decodeTargetValueDigest
      "delivery ephemeral key digest"
      (wireRetainedDeliveryEphemeralKeyDigest wire)
  pure
    ( mkRetainedDeliveryIntent
        operationId
        sourceReceipt
        target
        generation
        attestationRef
        ephemeralKeyDigest
        (authorityTimeFromMicros (wireRetainedDeliveryDeadline wire))
    )

decodeWireRetainedDeliveryReceipt
  :: SRetainedMaterialSchema schema
  -> WireRetainedDeliveryReceipt
  -> Either RetainedMaterialCodecError (RetainedDeliveryReceipt schema)
decodeWireRetainedDeliveryReceipt schema wire = do
  operationId <-
    decodeRetainedMaterialRef
      "delivery receipt operation"
      (wireRetainedDeliveryReceiptOperationId wire)
  sourceReceipt <-
    decodeRetainedMaterialRef
      "delivery receipt source"
      (wireRetainedDeliveryReceiptSource wire)
  target <-
    decodeRetainedMaterialTarget schema (wireRetainedDeliveryReceiptTarget wire)
  generation <-
    decodeCredentialGeneration
      "delivery receipt generation"
      (wireRetainedDeliveryReceiptGeneration wire)
  commitmentRef <-
    decodeRetainedMaterialRef
      "delivery receipt commitment"
      (wireRetainedDeliveryReceiptCommitmentRef wire)
  mapCodecField
    "delivery receipt"
    ( mkRetainedDeliveryReceipt
        operationId
        sourceReceipt
        target
        generation
        (wireRetainedDeliveryReceiptTargetVersion wire)
        commitmentRef
    )

decodeWireSupersededSource
  :: WireSupersededSource
  -> Either RetainedMaterialCodecError (SupersededSource schema)
decodeWireSupersededSource wire =
  SupersededSource
    <$> decodeWireRetainedMaterialSource (wireSupersededSourceValue wire)
    <*> pure (authorityTimeFromMicros (wireSupersededSourceGraceUntil wire))

decodeRetainedMaterialRef
  :: Text -> Text -> Either RetainedMaterialCodecError RetainedMaterialRef
decodeRetainedMaterialRef label = mapCodecField label . mkRetainedMaterialRef

decodeRetainedMaterialTarget
  :: SRetainedMaterialSchema schema
  -> Text
  -> Either RetainedMaterialCodecError (RetainedMaterialTarget schema)
decodeRetainedMaterialTarget schema =
  mapCodecField "delivery target" . mkRetainedMaterialTarget schema

decodeCredentialGeneration
  :: Text -> Natural -> Either RetainedMaterialCodecError CredentialGeneration
decodeCredentialGeneration label =
  mapCodecField label . mapLeft (Text.pack . show) . mkCredentialGeneration

decodeTargetValueDigest
  :: Text -> Text -> Either RetainedMaterialCodecError TargetValueDigest
decodeTargetValueDigest label =
  mapCodecField label . mapLeft (Text.pack . show) . mkTargetValueDigest

mapCodecField
  :: Text -> Either Text value -> Either RetainedMaterialCodecError value
mapCodecField label =
  mapLeft (RetainedMaterialCodecInvalidField . ((label <> ": ") <>))

validateWireEntryCounts
  :: WireRetainedMaterialAggregate -> Either RetainedMaterialCodecError ()
validateWireEntryCounts wire =
  mapM_
    (uncurry validateWireEntryCount)
    [ ("superseded sources", length (wireRetainedMaterialSuperseded wire))
    , ("pending deliveries", length (wireRetainedMaterialPendingDeliveries wire))
    , ("completed deliveries", length (wireRetainedMaterialCompletedDeliveries wire))
    , ("pending retirements", length (wireRetainedMaterialPendingRetirements wire))
    ]

validateWireEntryCount
  :: Text -> Int -> Either RetainedMaterialCodecError ()
validateWireEntryCount label actual =
  when
    (actual > retainedMaterialEntryMaximum)
    ( Left
        ( RetainedMaterialCodecEntryCountExceeded
            label
            actual
            retainedMaterialEntryMaximum
        )
    )

validateAggregateForCodec
  :: RetainedMaterialAggregate schema -> Either RetainedMaterialCodecError ()
validateAggregateForCodec aggregate =
  case retainedMaterialInvariantViolations aggregate of
    [] -> Right ()
    violations -> Left (RetainedMaterialCodecInvalidAggregate violations)

type role RetainedMaterialCommand nominal

data RetainedMaterialCommand (schema :: RetainedMaterialSchema)
  = BeginRetainedMaterialSeal
      !AuthorityTime
      !(RetainedSealIntent schema)
  | ObserveRetainedMaterialSeal !(RetainedMaterialSource schema)
  | ObserveLegacyRetainedMaterialSourceReceiptCorrection !(RetainedMaterialSource schema)
  | BeginRetainedMaterialDelivery
      !(RetainedCustodyObservation schema)
      !AuthorityTime
      !(RetainedDeliveryIntent schema)
  | ObserveRetainedMaterialDelivery !(RetainedDeliveryReceipt schema)
  | ExpireRetainedMaterialDelivery !RetainedMaterialRef !AuthorityTime
  | ReplaceExpiredRetainedMaterialDelivery
      !RetainedMaterialRef
      !AuthorityTime
      !(RetainedDeliveryIntent schema)
  | BeginSupersededMaterialRetirement
      !RetainedMaterialRef
      !AuthorityTime
  | ObserveSupersededMaterialAbsence
      !RetainedMaterialRef
      !RetainedMaterialRef
  deriving stock (Eq, Show, Generic)

data RetainedMaterialRefusal
  = RetainedSealAlreadyPending
  | RetainedSealDeadlineExpired
  | RetainedSealGenerationNotNext
  | RetainedSealReceiptWithoutIntent
  | RetainedSealReceiptMismatch
  | RetainedLegacySourceReceiptCorrectionMismatch
  | RetainedLegacySourceReceiptCorrectionHasCompletedDelivery
  | RetainedDeliveryNoCurrentSource
  | RetainedDeliveryCustodyAbsent
  | RetainedDeliveryCustodyCorrupt
  | RetainedDeliveryCustodyDigestMismatch
  | RetainedDeliveryCustodyUnobservable
  | RetainedDeliveryDeadlineExpired
  | RetainedDeliverySourceMismatch
  | RetainedDeliveryAlreadyPending
  | RetainedDeliveryReceiptWithoutIntent
  | RetainedDeliveryReceiptMismatch
  | RetainedDeliveryExpiryActive
  | RetainedDeliveryExpiryNotPending
  | RetainedDeliverySuccessorMismatch
  | RetainedSupersededSourceMissing
  | RetainedSupersededGraceActive
  | RetainedSupersededHasDependants
  | RetainedSupersededRetirementNotPending
  | RetainedMaterialCapacityExceeded
  | RetainedMaterialAggregateInvalid ![Text]
  deriving stock (Eq, Show, Generic)

type role RetainedMaterialDecision nominal

data RetainedMaterialDecision (schema :: RetainedMaterialSchema)
  = RetainedSealBegun !(RetainedSealIntent schema)
  | RetainedSealAlreadyBegun !(RetainedSealIntent schema)
  | RetainedSealCommitted
      !(RetainedMaterialSource schema)
      !(Maybe (RetainedMaterialSource schema))
      !AuthorityTime
  | RetainedSealAlreadyCommitted !(RetainedMaterialSource schema)
  | RetainedLegacySourceReceiptCorrected
      !(RetainedMaterialSource schema)
      !(RetainedMaterialSource schema)
  | RetainedLegacySourceReceiptAlreadyCorrected !(RetainedMaterialSource schema)
  | RetainedDeliveryBegun !(RetainedDeliveryIntent schema)
  | RetainedDeliveryAlreadyCompleted !(RetainedDeliveryReceipt schema)
  | RetainedDeliveryCommitted !(RetainedDeliveryReceipt schema)
  | RetainedDeliveryExpired !RetainedMaterialRef
  | RetainedDeliveryReplaced
      !RetainedMaterialRef
      !(RetainedDeliveryIntent schema)
  | RetainedDeliveryAlreadyReplaced !(RetainedDeliveryIntent schema)
  | RetainedSupersededRetirementBegun !RetainedMaterialRef
  | RetainedSupersededRetired !RetainedMaterialRef !RetainedMaterialRef
  | RetainedMaterialRefused !RetainedMaterialRefusal
  deriving stock (Eq, Show, Generic)

decideRetainedMaterial
  :: RetainedMaterialAggregate schema
  -> RetainedMaterialCommand schema
  -> RetainedMaterialDecision schema
decideRetainedMaterial aggregate command =
  case retainedMaterialInvariantViolations aggregate of
    violations@(_ : _) ->
      RetainedMaterialRefused (RetainedMaterialAggregateInvalid violations)
    [] -> decideValid aggregate command

decideValid
  :: RetainedMaterialAggregate schema
  -> RetainedMaterialCommand schema
  -> RetainedMaterialDecision schema
decideValid aggregate command = case command of
  BeginRetainedMaterialSeal observedAt intent
    | authorityTimeMicros observedAt
        > authorityTimeMicros (internalRetainedSealDeadline intent) ->
        RetainedMaterialRefused RetainedSealDeadlineExpired
    | otherwise ->
        case internalRetainedMaterialPendingSeal aggregate of
          Just current
            | current == intent -> RetainedSealAlreadyBegun current
            | otherwise -> RetainedMaterialRefused RetainedSealAlreadyPending
          Nothing
            | aggregateAtCapacity aggregate ->
                RetainedMaterialRefused RetainedMaterialCapacityExceeded
            | sealGenerationIsNext aggregate intent -> RetainedSealBegun intent
            | maybe False (sourceMatchesSeal intent) (internalRetainedMaterialCurrent aggregate) ->
                maybe
                  (RetainedMaterialRefused RetainedSealGenerationNotNext)
                  RetainedSealAlreadyCommitted
                  (internalRetainedMaterialCurrent aggregate)
            | otherwise -> RetainedMaterialRefused RetainedSealGenerationNotNext
  ObserveRetainedMaterialSeal source ->
    case internalRetainedMaterialPendingSeal aggregate of
      Nothing
        | Just source == internalRetainedMaterialCurrent aggregate ->
            RetainedSealAlreadyCommitted source
        | otherwise -> RetainedMaterialRefused RetainedSealReceiptWithoutIntent
      Just intent
        | sourceMatchesSeal intent source ->
            RetainedSealCommitted
              source
              (internalRetainedMaterialCurrent aggregate)
              (internalRetainedSealPredecessorGraceUntil intent)
        | otherwise -> RetainedMaterialRefused RetainedSealReceiptMismatch
  ObserveLegacyRetainedMaterialSourceReceiptCorrection source ->
    decideLegacySourceReceiptCorrection aggregate source
  BeginRetainedMaterialDelivery observation observedAt intent
    | authorityTimeMicros observedAt
        > authorityTimeMicros (internalRetainedDeliveryDeadline intent) ->
        RetainedMaterialRefused RetainedDeliveryDeadlineExpired
    | aggregateAtCapacity aggregate ->
        RetainedMaterialRefused RetainedMaterialCapacityExceeded
    | otherwise -> decideDelivery aggregate observation intent
  ObserveRetainedMaterialDelivery receipt ->
    case find (deliveryReceiptMatchesIntent receipt) (internalRetainedMaterialPendingDeliveries aggregate) of
      Just _ -> RetainedDeliveryCommitted receipt
      Nothing ->
        case find (== receipt) (internalRetainedMaterialCompletedDeliveries aggregate) of
          Just existing -> RetainedDeliveryAlreadyCompleted existing
          Nothing
            | any
                ((== internalRetainedDeliveryReceiptOperationId receipt) . internalRetainedDeliveryOperationId)
                (internalRetainedMaterialPendingDeliveries aggregate) ->
                RetainedMaterialRefused RetainedDeliveryReceiptMismatch
            | otherwise -> RetainedMaterialRefused RetainedDeliveryReceiptWithoutIntent
  ExpireRetainedMaterialDelivery operationId observedAt ->
    case find
      ((== operationId) . internalRetainedDeliveryOperationId)
      (internalRetainedMaterialPendingDeliveries aggregate) of
      Nothing -> RetainedMaterialRefused RetainedDeliveryExpiryNotPending
      Just intent
        | authorityTimeMicros observedAt
            <= authorityTimeMicros (internalRetainedDeliveryDeadline intent) ->
            RetainedMaterialRefused RetainedDeliveryExpiryActive
        | otherwise -> RetainedDeliveryExpired operationId
  ReplaceExpiredRetainedMaterialDelivery predecessorId observedAt successor ->
    decideDeliveryReplacement aggregate predecessorId observedAt successor
  BeginSupersededMaterialRetirement receiptRef observedAt ->
    decideRetirement aggregate receiptRef observedAt
  ObserveSupersededMaterialAbsence receiptRef absenceRef
    | receiptRef `elem` internalRetainedMaterialPendingRetirements aggregate ->
        RetainedSupersededRetired receiptRef absenceRef
    | otherwise -> RetainedMaterialRefused RetainedSupersededRetirementNotPending

decideDelivery
  :: RetainedMaterialAggregate schema
  -> RetainedCustodyObservation schema
  -> RetainedDeliveryIntent schema
  -> RetainedMaterialDecision schema
decideDelivery aggregate observation intent =
  case observation of
    RetainedCustodyPositivelyAbsent _ ->
      RetainedMaterialRefused RetainedDeliveryCustodyAbsent
    RetainedCustodyCorrupt _ ->
      RetainedMaterialRefused RetainedDeliveryCustodyCorrupt
    RetainedCustodyDigestMismatch _ _ ->
      RetainedMaterialRefused RetainedDeliveryCustodyDigestMismatch
    RetainedCustodyUnobservable _ ->
      RetainedMaterialRefused RetainedDeliveryCustodyUnobservable
    RetainedCustodyPresent observed ->
      case internalRetainedMaterialCurrent aggregate of
        Nothing -> RetainedMaterialRefused RetainedDeliveryNoCurrentSource
        Just current
          | not (sameRetainedSourceIdentity observed current)
              || internalRetainedDeliverySourceReceipt intent
                /= retainedSourceReceiptRef current ->
              RetainedMaterialRefused RetainedDeliverySourceMismatch
          | otherwise ->
              case completedForIntent aggregate intent of
                Just receipt -> RetainedDeliveryAlreadyCompleted receipt
                Nothing
                  | intent `elem` internalRetainedMaterialPendingDeliveries aggregate ->
                      RetainedMaterialRefused RetainedDeliveryAlreadyPending
                  | targetHasPendingDelivery aggregate intent ->
                      RetainedMaterialRefused RetainedDeliveryAlreadyPending
                  | otherwise -> RetainedDeliveryBegun intent

decideLegacySourceReceiptCorrection
  :: RetainedMaterialAggregate schema
  -> RetainedMaterialSource schema
  -> RetainedMaterialDecision schema
decideLegacySourceReceiptCorrection aggregate source =
  case internalRetainedMaterialCurrent aggregate of
    Just current
      | current == source -> RetainedLegacySourceReceiptAlreadyCorrected source
      | not (legacySourceReceiptCorrection current source) ->
          RetainedMaterialRefused RetainedLegacySourceReceiptCorrectionMismatch
      | any
          ((== retainedSourceReceiptRef current) . internalRetainedDeliveryReceiptSource)
          (internalRetainedMaterialCompletedDeliveries aggregate) ->
          RetainedMaterialRefused RetainedLegacySourceReceiptCorrectionHasCompletedDelivery
      | otherwise -> RetainedLegacySourceReceiptCorrected current source
    Nothing -> RetainedMaterialRefused RetainedLegacySourceReceiptCorrectionMismatch

decideDeliveryReplacement
  :: RetainedMaterialAggregate schema
  -> RetainedMaterialRef
  -> AuthorityTime
  -> RetainedDeliveryIntent schema
  -> RetainedMaterialDecision schema
decideDeliveryReplacement aggregate predecessorId observedAt successor =
  case find
    ((== predecessorId) . internalRetainedDeliveryOperationId)
    (internalRetainedMaterialPendingDeliveries aggregate) of
    Nothing
      | successor `elem` internalRetainedMaterialPendingDeliveries aggregate ->
          RetainedDeliveryAlreadyReplaced successor
      | otherwise -> RetainedMaterialRefused RetainedDeliveryExpiryNotPending
    Just predecessor
      | authorityTimeMicros observedAt
          <= authorityTimeMicros (internalRetainedDeliveryDeadline predecessor) ->
          RetainedMaterialRefused RetainedDeliveryExpiryActive
      | not (validSuccessor predecessor) ->
          RetainedMaterialRefused RetainedDeliverySuccessorMismatch
      | operationExists (internalRetainedDeliveryOperationId successor) ->
          RetainedMaterialRefused RetainedDeliverySuccessorMismatch
      | otherwise -> RetainedDeliveryReplaced predecessorId successor
 where
  validSuccessor predecessor =
    internalRetainedDeliveryOperationId successor
      == retainedDeliverySuccessorOperationId predecessorId
      && validSuccessorSource predecessor
      && internalRetainedDeliveryTarget successor
        == internalRetainedDeliveryTarget predecessor
      && internalRetainedDeliveryTargetGeneration successor
        == internalRetainedDeliveryTargetGeneration predecessor
      && internalRetainedDeliveryAttestationRef successor
        == internalRetainedDeliveryAttestationRef predecessor
      && internalRetainedDeliveryEphemeralKeyDigest successor
        /= internalRetainedDeliveryEphemeralKeyDigest predecessor
      && authorityTimeMicros (internalRetainedDeliveryDeadline successor)
        > authorityTimeMicros observedAt
      && authorityTimeMicros (internalRetainedDeliveryDeadline successor)
        > authorityTimeMicros (internalRetainedDeliveryDeadline predecessor)

  validSuccessorSource predecessor =
    internalRetainedDeliverySourceReceipt successor
      == internalRetainedDeliverySourceReceipt predecessor
      || case internalRetainedMaterialCurrent aggregate of
        Just current ->
          internalRetainedDeliverySourceReceipt predecessor
            == retainedSourceOperationId current
            && retainedSourceReceiptRef current /= retainedSourceOperationId current
            && internalRetainedDeliverySourceReceipt successor
              == retainedSourceReceiptRef current
        Nothing -> False

  operationExists operationId =
    any
      ((== operationId) . internalRetainedDeliveryOperationId)
      (internalRetainedMaterialPendingDeliveries aggregate)
      || any
        ((== operationId) . internalRetainedDeliveryReceiptOperationId)
        (internalRetainedMaterialCompletedDeliveries aggregate)

decideRetirement
  :: RetainedMaterialAggregate schema
  -> RetainedMaterialRef
  -> AuthorityTime
  -> RetainedMaterialDecision schema
decideRetirement aggregate receiptRef observedAt =
  case find
    ((== receiptRef) . retainedSourceReceiptRef . supersededSourceValue)
    (internalRetainedMaterialSuperseded aggregate) of
    Nothing -> RetainedMaterialRefused RetainedSupersededSourceMissing
    Just superseded
      | authorityTimeMicros observedAt
          < authorityTimeMicros (supersededSourceGraceUntil superseded) ->
          RetainedMaterialRefused RetainedSupersededGraceActive
      | any
          ((== receiptRef) . internalRetainedDeliverySourceReceipt)
          (internalRetainedMaterialPendingDeliveries aggregate) ->
          RetainedMaterialRefused RetainedSupersededHasDependants
      | receiptRef `elem` internalRetainedMaterialPendingRetirements aggregate ->
          RetainedSupersededRetirementBegun receiptRef
      | otherwise -> RetainedSupersededRetirementBegun receiptRef

applyRetainedMaterialDecision
  :: RetainedMaterialDecision schema
  -> RetainedMaterialAggregate schema
  -> RetainedMaterialAggregate schema
applyRetainedMaterialDecision decision aggregate = case decision of
  RetainedSealBegun intent ->
    aggregate {internalRetainedMaterialPendingSeal = Just intent}
  RetainedSealAlreadyBegun _ -> aggregate
  RetainedSealCommitted source predecessor graceUntil ->
    aggregate
      { internalRetainedMaterialCurrent = Just source
      , internalRetainedMaterialPendingSeal = Nothing
      , internalRetainedMaterialSuperseded =
          maybe
            id
            (\old existing -> SupersededSource old graceUntil : existing)
            predecessor
            (internalRetainedMaterialSuperseded aggregate)
      }
  RetainedSealAlreadyCommitted _ -> aggregate
  RetainedLegacySourceReceiptCorrected _ source ->
    aggregate {internalRetainedMaterialCurrent = Just source}
  RetainedLegacySourceReceiptAlreadyCorrected _ -> aggregate
  RetainedDeliveryBegun intent ->
    aggregate
      { internalRetainedMaterialPendingDeliveries =
          intent : internalRetainedMaterialPendingDeliveries aggregate
      }
  RetainedDeliveryAlreadyCompleted _ -> aggregate
  RetainedDeliveryCommitted receipt ->
    aggregate
      { internalRetainedMaterialPendingDeliveries =
          filter
            (not . deliveryReceiptMatchesIntent receipt)
            (internalRetainedMaterialPendingDeliveries aggregate)
      , internalRetainedMaterialCompletedDeliveries =
          receipt : internalRetainedMaterialCompletedDeliveries aggregate
      }
  RetainedDeliveryExpired operationId ->
    aggregate
      { internalRetainedMaterialPendingDeliveries =
          filter
            ((/= operationId) . internalRetainedDeliveryOperationId)
            (internalRetainedMaterialPendingDeliveries aggregate)
      }
  RetainedDeliveryReplaced predecessorId successor ->
    aggregate
      { internalRetainedMaterialPendingDeliveries =
          successor
            : filter
              ((/= predecessorId) . internalRetainedDeliveryOperationId)
              (internalRetainedMaterialPendingDeliveries aggregate)
      }
  RetainedDeliveryAlreadyReplaced _ -> aggregate
  RetainedSupersededRetirementBegun receiptRef ->
    aggregate
      { internalRetainedMaterialPendingRetirements =
          if receiptRef `elem` internalRetainedMaterialPendingRetirements aggregate
            then internalRetainedMaterialPendingRetirements aggregate
            else receiptRef : internalRetainedMaterialPendingRetirements aggregate
      }
  RetainedSupersededRetired receiptRef _ ->
    aggregate
      { internalRetainedMaterialSuperseded =
          filter
            ((/= receiptRef) . retainedSourceReceiptRef . supersededSourceValue)
            (internalRetainedMaterialSuperseded aggregate)
      , internalRetainedMaterialPendingRetirements =
          filter (/= receiptRef) (internalRetainedMaterialPendingRetirements aggregate)
      }
  RetainedMaterialRefused _ -> aggregate

stepRetainedMaterial
  :: RetainedMaterialAggregate schema
  -> RetainedMaterialCommand schema
  -> (RetainedMaterialDecision schema, RetainedMaterialAggregate schema)
stepRetainedMaterial aggregate command =
  let decision = decideRetainedMaterial aggregate command
   in (decision, applyRetainedMaterialDecision decision aggregate)

retainedMaterialInvariantViolations
  :: RetainedMaterialAggregate schema -> [Text]
retainedMaterialInvariantViolations aggregate =
  concat
    [ ["current source also appears in superseded custody" | currentIsSuperseded]
    , ["duplicate superseded receipt reference" | hasDuplicates supersededRefs]
    , ["duplicate pending delivery operation" | hasDuplicates pendingOperations]
    , ["duplicate completed delivery operation" | hasDuplicates completedOperations]
    , [ "duplicate pending retirement"
      | hasDuplicates (internalRetainedMaterialPendingRetirements aggregate)
      ]
    , [ "pending retirement does not name a superseded source"
      | any (`notElem` supersededRefs) (internalRetainedMaterialPendingRetirements aggregate)
      ]
    , ["retained material aggregate exceeds the compiled bound" | aggregateOverBound aggregate]
    ]
 where
  supersededRefs =
    map
      (retainedSourceReceiptRef . supersededSourceValue)
      (internalRetainedMaterialSuperseded aggregate)
  currentIsSuperseded =
    maybe
      False
      ((`elem` supersededRefs) . retainedSourceReceiptRef)
      (internalRetainedMaterialCurrent aggregate)
  pendingOperations =
    map internalRetainedDeliveryOperationId (internalRetainedMaterialPendingDeliveries aggregate)
  completedOperations =
    map
      internalRetainedDeliveryReceiptOperationId
      (internalRetainedMaterialCompletedDeliveries aggregate)

sealGenerationIsNext
  :: RetainedMaterialAggregate schema -> RetainedSealIntent schema -> Bool
sealGenerationIsNext aggregate intent =
  credentialGenerationValue (internalRetainedSealGeneration intent)
    == maybe
      1
      ((+ 1) . credentialGenerationValue . retainedSourceGeneration)
      (internalRetainedMaterialCurrent aggregate)

sourceMatchesSeal
  :: RetainedSealIntent schema -> RetainedMaterialSource schema -> Bool
sourceMatchesSeal intent source =
  internalRetainedSealGeneration intent == retainedSourceGeneration source
    && internalRetainedSealOperationId intent == retainedSourceOperationId source

legacySourceReceiptCorrection
  :: RetainedMaterialSource schema -> RetainedMaterialSource schema -> Bool
legacySourceReceiptCorrection legacy corrected =
  retainedSourceReceiptRef legacy == retainedSourceOperationId legacy
    && retainedSourceReceiptRef corrected /= retainedSourceOperationId corrected
    && retainedSourceGeneration legacy == retainedSourceGeneration corrected
    && retainedSourceOperationId legacy == retainedSourceOperationId corrected
    && retainedSourceCiphertextDigest legacy == retainedSourceCiphertextDigest corrected
    && retainedSourceCommitmentRef legacy == retainedSourceCommitmentRef corrected
    && retainedSourceVaultVersion legacy == retainedSourceVaultVersion corrected
    && authorityTimeMicros (internalRetainedSourceReadBackAt corrected)
      >= authorityTimeMicros (internalRetainedSourceReadBackAt legacy)

sameRetainedSourceIdentity
  :: RetainedMaterialSource schema -> RetainedMaterialSource schema -> Bool
sameRetainedSourceIdentity left right =
  retainedSourceGeneration left == retainedSourceGeneration right
    && retainedSourceOperationId left == retainedSourceOperationId right
    && retainedSourceReceiptRef left == retainedSourceReceiptRef right
    && retainedSourceCiphertextDigest left == retainedSourceCiphertextDigest right
    && retainedSourceCommitmentRef left == retainedSourceCommitmentRef right
    && retainedSourceVaultVersion left == retainedSourceVaultVersion right

deliveryReceiptMatchesIntent
  :: RetainedDeliveryReceipt schema -> RetainedDeliveryIntent schema -> Bool
deliveryReceiptMatchesIntent receipt intent =
  internalRetainedDeliveryReceiptOperationId receipt
    == internalRetainedDeliveryOperationId intent
    && internalRetainedDeliveryReceiptSource receipt
      == internalRetainedDeliverySourceReceipt intent
    && internalRetainedDeliveryReceiptTarget receipt
      == internalRetainedDeliveryTarget intent
    && internalRetainedDeliveryReceiptGeneration receipt
      == internalRetainedDeliveryTargetGeneration intent

completedForIntent
  :: RetainedMaterialAggregate schema
  -> RetainedDeliveryIntent schema
  -> Maybe (RetainedDeliveryReceipt schema)
completedForIntent aggregate intent =
  find
    (`deliveryReceiptMatchesIntent` intent)
    (internalRetainedMaterialCompletedDeliveries aggregate)

targetHasPendingDelivery
  :: RetainedMaterialAggregate schema -> RetainedDeliveryIntent schema -> Bool
targetHasPendingDelivery aggregate intent =
  any
    (\pending -> internalRetainedDeliveryTarget pending == internalRetainedDeliveryTarget intent)
    (internalRetainedMaterialPendingDeliveries aggregate)

hasDuplicates :: (Eq value) => [value] -> Bool
hasDuplicates values = length values /= length (nub values)

aggregateAtCapacity :: RetainedMaterialAggregate schema -> Bool
aggregateAtCapacity aggregate =
  length (internalRetainedMaterialSuperseded aggregate) >= retainedMaterialEntryMaximum
    || length (internalRetainedMaterialPendingDeliveries aggregate) >= retainedMaterialEntryMaximum
    || length (internalRetainedMaterialCompletedDeliveries aggregate) >= retainedMaterialEntryMaximum
    || length (internalRetainedMaterialPendingRetirements aggregate) >= retainedMaterialEntryMaximum

aggregateOverBound :: RetainedMaterialAggregate schema -> Bool
aggregateOverBound aggregate =
  length (internalRetainedMaterialSuperseded aggregate) > retainedMaterialEntryMaximum
    || length (internalRetainedMaterialPendingDeliveries aggregate) > retainedMaterialEntryMaximum
    || length (internalRetainedMaterialCompletedDeliveries aggregate) > retainedMaterialEntryMaximum
    || length (internalRetainedMaterialPendingRetirements aggregate) > retainedMaterialEntryMaximum

retainedMaterialEntryMaximum :: Int
retainedMaterialEntryMaximum = 256

validateIdentifier :: Text -> Int -> Text -> Either Text Text
validateIdentifier label maximumLength raw
  | Text.null value = Left (label <> " must not be empty")
  | Text.length value > maximumLength = Left (label <> " exceeds the compiled bound")
  | Text.any invalid value = Left (label <> " contains whitespace or control characters")
  | otherwise = Right value
 where
  value = Text.strip raw
  invalid character = character <= '\x20' || character == '\x7f'

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft convert value = case value of
  Left err -> Left (convert err)
  Right result -> Right result
