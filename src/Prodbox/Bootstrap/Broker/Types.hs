{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}

-- | Secret-safe values shared by the pure Bootstrap Broker custody models.
--
-- Cryptographic operations are deliberately outside this module.  Values such
-- as a PGP-encrypted share or password-AEAD ciphertext are opaque results from
-- an attested boundary interpreter; none of the constructors below pretends to
-- implement OpenPGP.  Secret-bearing values have private constructors and
-- custom redacted 'Show' instances.
module Prodbox.Bootstrap.Broker.Types
  ( -- * Validated identifiers
    BootstrapValueError (..)
  , BootstrapTransactionId
  , mkBootstrapTransactionId
  , renderBootstrapTransactionId
  , VaultStorageGeneration
  , mkVaultStorageGeneration
  , renderVaultStorageGeneration
  , StoreVersion (..)
  , BootstrapSchemaVersion
  , mkBootstrapSchemaVersion
  , bootstrapSchemaVersionValue
  , ArtifactDigest
  , mkArtifactDigest
  , renderArtifactDigest
  , RecoveryRecipientFingerprint
  , mkRecoveryRecipientFingerprint
  , renderRecoveryRecipientFingerprint
  , BurnRecipientFingerprint
  , mkBurnRecipientFingerprint
  , renderBurnRecipientFingerprint
  , RootSessionId
  , mkRootSessionId
  , renderRootSessionId
  , RootPolicyAccessor
  , mkRootPolicyAccessor
  , renderRootPolicyAccessor
  , ProvisionerAccessor
  , mkProvisionerAccessor
  , renderProvisionerAccessor
  , ChildId
  , mkChildId
  , renderChildId
  , CustodyGeneration
  , mkCustodyGeneration
  , custodyGenerationValue
  , DeliveryNonce
  , mkDeliveryNonce
  , renderDeliveryNonce
  , ChildAttestation
  , mkChildAttestation
  , childAttestationDigest

    -- * Opaque boundary values
  , maximumOpaqueBoundaryBytes
  , SealedRecoveryRecipientPrivateKey
  , mkSealedRecoveryRecipientPrivateKey
  , sealedRecoveryRecipientPrivateKeyBytes
  , PgpEncryptedShare
  , mkPgpEncryptedShare
  , pgpEncryptedShareBytes
  , BurnTokenCiphertext
  , mkBurnTokenCiphertext
  , burnTokenCiphertextBytes
  , RecoveredUnsealShare
  , mkRecoveredUnsealShare
  , recoveredUnsealShareBytes
  , PasswordAeadCiphertext
  , mkPasswordAeadCiphertext
  , passwordAeadCiphertextBytes
  , EncryptedChildRecoveryPayload
  , mkEncryptedChildRecoveryPayload
  , encryptedChildRecoveryPayloadBytes

    -- * Root initialization artifacts
  , RootInitBinding (..)
  , PristineStorageProof
  , mkPristineStorageProof
  , pristineStorageBinding
  , pristineStorageObservationDigest
  , InitRecipientCommitment
  , mkInitRecipientCommitment
  , initRecipientShareCount
  , initRecipientThreshold
  , initRecipientRecoveryPublicKeysBase64
  , initRecipientRecoveryPublicKeysDigest
  , initRecipientRecoveryFingerprint
  , initRecipientBurnFingerprint
  , initRecipientBurnPublicKeyDigest
  , PreparedInitEnvelope
  , mkPreparedInitEnvelope
  , preparedInitBinding
  , preparedInitPristineObservationDigest
  , preparedInitSchemaVersion
  , preparedInitSealedRecoveryPrivateKey
  , preparedInitRecipientCommitment
  , preparedInitRecoveryFingerprint
  , preparedInitBurnFingerprint
  , preparedInitEnvelopeDigest
  , EncryptedInitResponseReceipt
  , mkEncryptedInitResponseReceipt
  , encryptedResponseBinding
  , encryptedResponseSchemaVersion
  , encryptedResponseRecipientCommitment
  , encryptedResponseRecoveryFingerprint
  , encryptedResponseBurnFingerprint
  , encryptedResponseShares
  , encryptedResponseBurnToken
  , encryptedResponseReceiptDigest
  , FinalUnlockBundlePayload
  , mkFinalUnlockBundlePayload
  , finalPayloadBinding
  , finalPayloadSchemaVersion
  , finalPayloadShareCount
  , finalPayloadThreshold
  , finalPayloadShares
  , FinalUnlockBundle
  , mkFinalUnlockBundle
  , finalUnlockBundleBinding
  , finalUnlockBundleSchemaVersion
  , finalUnlockBundleCiphertext
  , finalUnlockBundleShareCount
  , finalUnlockBundleThreshold
  , finalUnlockBundleDigest
  , RecoveryCustodyReceipt
  , mkRecoveryCustodyReceipt
  , recoveryCustodyBinding
  , recoveryCustodyFinalBundleDigest
  , recoveryCustodyAcknowledgementDigest
  , InitAmbiguity
  , mkInitAmbiguity
  , ambiguousInitBinding
  , ambiguousPreparedEnvelopeDigest
  , EstablishedStateAbsence
  , mkEstablishedStateAbsence
  , DurableInitResponseAbsence
  , mkDurableInitResponseAbsence
  , BaselineStateAbsence
  , mkBaselineStateAbsence
  , PristineResetProof
  , mkPristineResetProof
  , resetAmbiguousBinding
  , resetReplacementPristine

    -- * Baseline and handoff evidence
  , BaselineTarget (..)
  , requiredRootBaselineTargets
  , RootAccessorInventory
  , mkRootAccessorInventory
  , rootAccessorInventoryGeneration
  , rootAccessorInventoryAccessors
  , AccessorAbsenceAttestation
  , mkAccessorAbsenceAttestation
  , accessorAbsenceInventory
  , accessorAbsenceObservationDigest
  , BaselineReadBackReceipt
  , mkBaselineReadBackReceipt
  , baselineReadBackSessionId
  , baselineReadBackStorageGeneration
  , baselineReadBackTargets
  , baselineReadBackDigest
  , ProvisionerLoginReceipt
  , mkProvisionerLoginReceipt
  , provisionerLoginStorageGeneration
  , provisionerLoginAccessor
  , provisionerLoginLeaseSeconds
  , PostUnsealConsumer (..)
  , PostUnsealHandoffReceipt
  , mkPostUnsealHandoffReceipt
  , postUnsealHandoffGeneration
  , postUnsealHandoffConsumer
  , postUnsealHandoffObservationDigest

    -- * Child custody evidence
  , ChildCustodyBinding (..)
  , ChildEncryptedReceipt (..)
  , mkChildEncryptedReceipt
  , ParentCustodyAcknowledgement (..)
  , mkParentCustodyAcknowledgement
  , ChildRecoveryDelivery (..)
  , mkChildRecoveryDelivery
  , ChildRecoveryConsumptionStatus (..)
  , ChildRecoveryConsumptionObservation
  , mkChildRecoveryConsumptionObservation
  , childRecoveryConsumptionBinding
  , childRecoveryConsumptionNonce
  , childRecoveryConsumptionAttestation
  , childRecoveryConsumptionDeliveryDigest
  , childRecoveryConsumptionStatus
  , childRecoveryConsumptionObservationDigest
  , childRecoveryConsumptionObservationMatches
  , ChildRecoveryRepairReceipt (..)
  , mkChildRecoveryRepairReceipt
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric (showHex)
import Numeric.Natural (Natural)

data BootstrapValueError
  = BootstrapValueEmpty !String
  | BootstrapValueTooLong !String !Int !Int
  | BootstrapValueForbiddenCharacter !String
  | BootstrapValueMustBeLowerHexSha256 !String
  | BootstrapValueMustBeLowerHexOpenPgpV4Fingerprint !String
  | BootstrapSchemaVersionMustBePositive
  | BootstrapOpaqueValueEmpty !String
  | BootstrapOpaqueValueTooLarge !String !Natural !Natural
  | BootstrapEncryptedSharesEmpty
  | BootstrapInitShareCountMustBePositive
  | BootstrapInitShareCountTooLarge !Natural !Natural
  | BootstrapInitThresholdMustBePositive
  | BootstrapInitThresholdExceedsShareCount !Natural !Natural
  | BootstrapInitRecipientCountMismatch !Natural !Natural
  | BootstrapInitRecipientPublicKeyInvalid !Natural
  | BootstrapInitRecipientPublicKeyTooLarge !Natural !Natural !Natural
  | BootstrapInitRecipientPayloadTooLarge !Natural !Natural
  | BootstrapInitRecoveryRecipientsDiffer
  | BootstrapEncryptedShareCountMismatch !Natural !Natural
  | BootstrapRecoveredShareCountMismatch !Natural !Natural
  | BootstrapResetAbsenceBindingMismatch !String
  | BootstrapResetReplacementMustAdvance
  | BootstrapCustodyGenerationMustBePositive
  | BootstrapAccessorInventoryTooLarge !Natural !Natural
  | BootstrapAccessorInventoryDuplicate !RootPolicyAccessor
  | BootstrapBaselineTargetsIncomplete ![BaselineTarget]
  | BootstrapProvisionerLeaseMustBePositive
  | BootstrapProvisionerLeaseTooLong !Natural !Natural
  deriving stock (Eq, Show)

newtype BootstrapTransactionId = BootstrapTransactionId Text
  deriving stock (Eq, Ord, Show)

mkBootstrapTransactionId
  :: Text -> Either BootstrapValueError BootstrapTransactionId
mkBootstrapTransactionId raw =
  BootstrapTransactionId <$> boundedIdentifier "bootstrap transaction id" 128 raw

renderBootstrapTransactionId :: BootstrapTransactionId -> Text
renderBootstrapTransactionId (BootstrapTransactionId value) = value

newtype VaultStorageGeneration = VaultStorageGeneration Text
  deriving stock (Eq, Ord, Show)

mkVaultStorageGeneration
  :: Text -> Either BootstrapValueError VaultStorageGeneration
mkVaultStorageGeneration raw =
  VaultStorageGeneration <$> boundedIdentifier "Vault storage generation" 256 raw

renderVaultStorageGeneration :: VaultStorageGeneration -> Text
renderVaultStorageGeneration (VaultStorageGeneration value) = value

-- | Monotonic CAS version shared by the closed broker store algebra and
-- request-journal recovery targets.  It lives in this dependency-neutral
-- value module so the store boundary can persist request journals without a
-- module cycle.
newtype StoreVersion = StoreVersion Natural
  deriving stock (Eq, Ord, Show)

newtype BootstrapSchemaVersion = BootstrapSchemaVersion Natural
  deriving stock (Eq, Ord, Show)

mkBootstrapSchemaVersion
  :: Natural -> Either BootstrapValueError BootstrapSchemaVersion
mkBootstrapSchemaVersion value
  | value == 0 = Left BootstrapSchemaVersionMustBePositive
  | otherwise = Right (BootstrapSchemaVersion value)

bootstrapSchemaVersionValue :: BootstrapSchemaVersion -> Natural
bootstrapSchemaVersionValue (BootstrapSchemaVersion value) = value

newtype ArtifactDigest = ArtifactDigest Text
  deriving stock (Eq, Ord, Show)

mkArtifactDigest :: Text -> Either BootstrapValueError ArtifactDigest
mkArtifactDigest raw = ArtifactDigest <$> lowerHexSha256 "artifact digest" raw

renderArtifactDigest :: ArtifactDigest -> Text
renderArtifactDigest (ArtifactDigest value) = value

newtype RecoveryRecipientFingerprint = RecoveryRecipientFingerprint Text
  deriving stock (Eq, Ord, Show)

mkRecoveryRecipientFingerprint
  :: Text -> Either BootstrapValueError RecoveryRecipientFingerprint
mkRecoveryRecipientFingerprint raw =
  RecoveryRecipientFingerprint <$> lowerHexSha256 "recovery-recipient fingerprint" raw

renderRecoveryRecipientFingerprint :: RecoveryRecipientFingerprint -> Text
renderRecoveryRecipientFingerprint (RecoveryRecipientFingerprint value) = value

newtype BurnRecipientFingerprint = BurnRecipientFingerprint Text
  deriving stock (Eq, Ord, Show)

mkBurnRecipientFingerprint
  :: Text -> Either BootstrapValueError BurnRecipientFingerprint
mkBurnRecipientFingerprint raw =
  BurnRecipientFingerprint
    <$> lowerHexOpenPgpV4Fingerprint "burn-recipient fingerprint" raw

renderBurnRecipientFingerprint :: BurnRecipientFingerprint -> Text
renderBurnRecipientFingerprint (BurnRecipientFingerprint value) = value

newtype RootSessionId = RootSessionId Text
  deriving stock (Eq, Ord, Show)

mkRootSessionId :: Text -> Either BootstrapValueError RootSessionId
mkRootSessionId raw = RootSessionId <$> boundedIdentifier "root session id" 128 raw

renderRootSessionId :: RootSessionId -> Text
renderRootSessionId (RootSessionId value) = value

newtype RootPolicyAccessor = RootPolicyAccessor Text
  deriving stock (Eq, Ord, Show)

mkRootPolicyAccessor :: Text -> Either BootstrapValueError RootPolicyAccessor
mkRootPolicyAccessor raw =
  RootPolicyAccessor <$> boundedIdentifier "root-policy accessor" 256 raw

renderRootPolicyAccessor :: RootPolicyAccessor -> Text
renderRootPolicyAccessor (RootPolicyAccessor value) = value

newtype ProvisionerAccessor = ProvisionerAccessor Text
  deriving stock (Eq, Ord, Show)

mkProvisionerAccessor :: Text -> Either BootstrapValueError ProvisionerAccessor
mkProvisionerAccessor raw =
  ProvisionerAccessor <$> boundedIdentifier "provisioner accessor" 256 raw

renderProvisionerAccessor :: ProvisionerAccessor -> Text
renderProvisionerAccessor (ProvisionerAccessor value) = value

newtype ChildId = ChildId Text
  deriving stock (Eq, Ord, Show)

mkChildId :: Text -> Either BootstrapValueError ChildId
mkChildId raw = ChildId <$> boundedIdentifier "child id" 128 raw

renderChildId :: ChildId -> Text
renderChildId (ChildId value) = value

newtype CustodyGeneration = CustodyGeneration Natural
  deriving stock (Eq, Ord, Show)

mkCustodyGeneration :: Natural -> Either BootstrapValueError CustodyGeneration
mkCustodyGeneration value
  | value == 0 = Left BootstrapCustodyGenerationMustBePositive
  | otherwise = Right (CustodyGeneration value)

custodyGenerationValue :: CustodyGeneration -> Natural
custodyGenerationValue (CustodyGeneration value) = value

newtype DeliveryNonce = DeliveryNonce Text
  deriving stock (Eq, Ord, Show)

mkDeliveryNonce :: Text -> Either BootstrapValueError DeliveryNonce
mkDeliveryNonce raw = DeliveryNonce <$> boundedIdentifier "delivery nonce" 128 raw

renderDeliveryNonce :: DeliveryNonce -> Text
renderDeliveryNonce (DeliveryNonce value) = value

newtype ChildAttestation = ChildAttestation ArtifactDigest
  deriving stock (Eq, Ord, Show)

mkChildAttestation :: ArtifactDigest -> ChildAttestation
mkChildAttestation = ChildAttestation

childAttestationDigest :: ChildAttestation -> ArtifactDigest
childAttestationDigest (ChildAttestation digest) = digest

-- | A single hard cap for secret values entering this pure model.  Individual
-- HTTP/request limits may be tighter; this cap prevents an interpreter from
-- manufacturing an unbounded durable artifact.
maximumOpaqueBoundaryBytes :: Natural
maximumOpaqueBoundaryBytes = 4 * 1024 * 1024

newtype OpaqueSecret = OpaqueSecret ByteString
  deriving stock (Eq)

opaqueSecretLength :: OpaqueSecret -> Natural
opaqueSecretLength (OpaqueSecret bytes) = fromIntegral (BS.length bytes)

mkOpaqueSecret
  :: String -> ByteString -> Either BootstrapValueError OpaqueSecret
mkOpaqueSecret label bytes
  | BS.null bytes = Left (BootstrapOpaqueValueEmpty label)
  | byteCount > maximumOpaqueBoundaryBytes =
      Left
        ( BootstrapOpaqueValueTooLarge
            label
            byteCount
            maximumOpaqueBoundaryBytes
        )
  | otherwise = Right (OpaqueSecret bytes)
 where
  byteCount = fromIntegral (BS.length bytes)

redactedOpaque :: String -> OpaqueSecret -> String
redactedOpaque label secret =
  label ++ " <redacted:" ++ show (opaqueSecretLength secret) ++ " bytes>"

newtype SealedRecoveryRecipientPrivateKey
  = SealedRecoveryRecipientPrivateKey OpaqueSecret
  deriving stock (Eq)

instance Show SealedRecoveryRecipientPrivateKey where
  show (SealedRecoveryRecipientPrivateKey secret) =
    redactedOpaque "SealedRecoveryRecipientPrivateKey" secret

mkSealedRecoveryRecipientPrivateKey
  :: ByteString -> Either BootstrapValueError SealedRecoveryRecipientPrivateKey
mkSealedRecoveryRecipientPrivateKey bytes =
  SealedRecoveryRecipientPrivateKey
    <$> mkOpaqueSecret "sealed recovery-recipient private key" bytes

sealedRecoveryRecipientPrivateKeyBytes
  :: SealedRecoveryRecipientPrivateKey -> Natural
sealedRecoveryRecipientPrivateKeyBytes (SealedRecoveryRecipientPrivateKey secret) =
  opaqueSecretLength secret

newtype PgpEncryptedShare = PgpEncryptedShare OpaqueSecret
  deriving stock (Eq)

instance Show PgpEncryptedShare where
  show (PgpEncryptedShare secret) =
    redactedOpaque "PgpEncryptedShare" secret

mkPgpEncryptedShare :: ByteString -> Either BootstrapValueError PgpEncryptedShare
mkPgpEncryptedShare bytes =
  PgpEncryptedShare <$> mkOpaqueSecret "PGP-encrypted share" bytes

pgpEncryptedShareBytes :: PgpEncryptedShare -> Natural
pgpEncryptedShareBytes (PgpEncryptedShare secret) = opaqueSecretLength secret

newtype BurnTokenCiphertext = BurnTokenCiphertext OpaqueSecret
  deriving stock (Eq)

instance Show BurnTokenCiphertext where
  show (BurnTokenCiphertext secret) =
    redactedOpaque "BurnTokenCiphertext" secret

mkBurnTokenCiphertext
  :: ByteString -> Either BootstrapValueError BurnTokenCiphertext
mkBurnTokenCiphertext bytes =
  BurnTokenCiphertext <$> mkOpaqueSecret "burn-recipient token ciphertext" bytes

burnTokenCiphertextBytes :: BurnTokenCiphertext -> Natural
burnTokenCiphertextBytes (BurnTokenCiphertext secret) = opaqueSecretLength secret

newtype RecoveredUnsealShare = RecoveredUnsealShare OpaqueSecret
  deriving stock (Eq)

instance Show RecoveredUnsealShare where
  show (RecoveredUnsealShare secret) =
    redactedOpaque "RecoveredUnsealShare" secret

mkRecoveredUnsealShare
  :: ByteString -> Either BootstrapValueError RecoveredUnsealShare
mkRecoveredUnsealShare bytes =
  RecoveredUnsealShare <$> mkOpaqueSecret "recovered unseal share" bytes

recoveredUnsealShareBytes :: RecoveredUnsealShare -> Natural
recoveredUnsealShareBytes (RecoveredUnsealShare secret) = opaqueSecretLength secret

newtype PasswordAeadCiphertext = PasswordAeadCiphertext OpaqueSecret
  deriving stock (Eq)

instance Show PasswordAeadCiphertext where
  show (PasswordAeadCiphertext secret) =
    redactedOpaque "PasswordAeadCiphertext" secret

mkPasswordAeadCiphertext
  :: ByteString -> Either BootstrapValueError PasswordAeadCiphertext
mkPasswordAeadCiphertext bytes =
  PasswordAeadCiphertext <$> mkOpaqueSecret "password-AEAD ciphertext" bytes

passwordAeadCiphertextBytes :: PasswordAeadCiphertext -> Natural
passwordAeadCiphertextBytes (PasswordAeadCiphertext secret) = opaqueSecretLength secret

newtype EncryptedChildRecoveryPayload
  = EncryptedChildRecoveryPayload OpaqueSecret
  deriving stock (Eq)

instance Show EncryptedChildRecoveryPayload where
  show (EncryptedChildRecoveryPayload secret) =
    redactedOpaque "EncryptedChildRecoveryPayload" secret

mkEncryptedChildRecoveryPayload
  :: ByteString -> Either BootstrapValueError EncryptedChildRecoveryPayload
mkEncryptedChildRecoveryPayload bytes =
  EncryptedChildRecoveryPayload
    <$> mkOpaqueSecret "encrypted child recovery payload" bytes

encryptedChildRecoveryPayloadBytes
  :: EncryptedChildRecoveryPayload -> Natural
encryptedChildRecoveryPayloadBytes (EncryptedChildRecoveryPayload secret) =
  opaqueSecretLength secret

data RootInitBinding = RootInitBinding
  { rootInitTransactionId :: !BootstrapTransactionId
  , rootInitStorageGeneration :: !VaultStorageGeneration
  }
  deriving stock (Eq, Ord, Show)

-- | Boundary evidence that the exact storage generation was observed empty.
-- The digest binds the observation used to authorize preparation.
data PristineStorageProof
  = PristineStorageProof !RootInitBinding !ArtifactDigest
  deriving stock (Eq, Show)

mkPristineStorageProof
  :: RootInitBinding -> ArtifactDigest -> PristineStorageProof
mkPristineStorageProof = PristineStorageProof

pristineStorageBinding :: PristineStorageProof -> RootInitBinding
pristineStorageBinding (PristineStorageProof binding _) = binding

pristineStorageObservationDigest :: PristineStorageProof -> ArtifactDigest
pristineStorageObservationDigest (PristineStorageProof _ digest) = digest

-- | The complete recipient commitment persisted before @/sys/init@.  The
-- ordered array is retained verbatim as well as under an unambiguous digest;
-- a restart therefore cannot change the recipient, count, threshold, or
-- ordering while reusing the prepared private-key envelope.
data InitRecipientCommitment
  = InitRecipientCommitment
      !Natural
      !Natural
      ![Text]
      !ArtifactDigest
      !RecoveryRecipientFingerprint
      !BurnRecipientFingerprint
      !ArtifactDigest
  deriving stock (Eq, Show)

mkInitRecipientCommitment
  :: Natural
  -> Natural
  -> [Text]
  -> RecoveryRecipientFingerprint
  -> BurnRecipientFingerprint
  -> ArtifactDigest
  -> Either BootstrapValueError InitRecipientCommitment
mkInitRecipientCommitment shareCount threshold recoveryPublicKeys recoveryFingerprint burnFingerprint burnPublicKeyDigest
  | shareCount == 0 = Left BootstrapInitShareCountMustBePositive
  | shareCount > maximumInitShareCount =
      Left (BootstrapInitShareCountTooLarge shareCount maximumInitShareCount)
  | threshold == 0 = Left BootstrapInitThresholdMustBePositive
  | threshold > shareCount =
      Left (BootstrapInitThresholdExceedsShareCount threshold shareCount)
  | actualRecipientCount /= shareCount =
      Left (BootstrapInitRecipientCountMismatch shareCount actualRecipientCount)
  | otherwise = do
      canonicalPublicKeys <-
        traverse (uncurry validateInitRecipientPublicKey) (zip [0 ..] recoveryPublicKeys)
      if fromIntegral (BS.length encodedRecipientArray) > maximumInitRecipientPayloadBytes
        then
          Left
            ( BootstrapInitRecipientPayloadTooLarge
                (fromIntegral (BS.length encodedRecipientArray))
                maximumInitRecipientPayloadBytes
            )
        else case canonicalPublicKeys of
          [] -> Left BootstrapInitShareCountMustBePositive
          firstPublicKey : remainingPublicKeys
            | any (/= firstPublicKey) remainingPublicKeys ->
                Left BootstrapInitRecoveryRecipientsDiffer
            | otherwise ->
                Right
                  ( InitRecipientCommitment
                      shareCount
                      threshold
                      canonicalPublicKeys
                      (digestOrderedPublicKeys canonicalPublicKeys)
                      recoveryFingerprint
                      burnFingerprint
                      burnPublicKeyDigest
                  )
 where
  actualRecipientCount = fromIntegral (length recoveryPublicKeys)
  encodedRecipientArray = encodeOrderedPublicKeys recoveryPublicKeys

initRecipientShareCount :: InitRecipientCommitment -> Natural
initRecipientShareCount (InitRecipientCommitment shareCount _ _ _ _ _ _) = shareCount

initRecipientThreshold :: InitRecipientCommitment -> Natural
initRecipientThreshold (InitRecipientCommitment _ threshold _ _ _ _ _) = threshold

initRecipientRecoveryPublicKeysBase64 :: InitRecipientCommitment -> [Text]
initRecipientRecoveryPublicKeysBase64 (InitRecipientCommitment _ _ publicKeys _ _ _ _) = publicKeys

initRecipientRecoveryPublicKeysDigest :: InitRecipientCommitment -> ArtifactDigest
initRecipientRecoveryPublicKeysDigest (InitRecipientCommitment _ _ _ digest _ _ _) = digest

initRecipientRecoveryFingerprint :: InitRecipientCommitment -> RecoveryRecipientFingerprint
initRecipientRecoveryFingerprint (InitRecipientCommitment _ _ _ _ fingerprint _ _) = fingerprint

initRecipientBurnFingerprint :: InitRecipientCommitment -> BurnRecipientFingerprint
initRecipientBurnFingerprint (InitRecipientCommitment _ _ _ _ _ fingerprint _) = fingerprint

initRecipientBurnPublicKeyDigest :: InitRecipientCommitment -> ArtifactDigest
initRecipientBurnPublicKeyDigest (InitRecipientCommitment _ _ _ _ _ _ digest) = digest

data PreparedInitEnvelope
  = PreparedInitEnvelope
      !RootInitBinding
      !ArtifactDigest
      !BootstrapSchemaVersion
      !SealedRecoveryRecipientPrivateKey
      !InitRecipientCommitment
      !ArtifactDigest
  deriving stock (Eq)

instance Show PreparedInitEnvelope where
  show
    prepared =
      "PreparedInitEnvelope {binding = "
        ++ show (preparedInitBinding prepared)
        ++ ", pristineObservationDigest = "
        ++ show (preparedInitPristineObservationDigest prepared)
        ++ ", schemaVersion = "
        ++ show (preparedInitSchemaVersion prepared)
        ++ ", sealedRecoveryPrivateKey = <redacted>, recoveryFingerprint = "
        ++ show (preparedInitRecoveryFingerprint prepared)
        ++ ", burnFingerprint = "
        ++ show (preparedInitBurnFingerprint prepared)
        ++ ", shareCount = "
        ++ show (initRecipientShareCount (preparedInitRecipientCommitment prepared))
        ++ ", threshold = "
        ++ show (initRecipientThreshold (preparedInitRecipientCommitment prepared))
        ++ ", digest = "
        ++ show (preparedInitEnvelopeDigest prepared)
        ++ "}"

mkPreparedInitEnvelope
  :: PristineStorageProof
  -> BootstrapSchemaVersion
  -> SealedRecoveryRecipientPrivateKey
  -> InitRecipientCommitment
  -> ArtifactDigest
  -> PreparedInitEnvelope
mkPreparedInitEnvelope proof schemaVersion sealedPrivateKey commitment digest =
  PreparedInitEnvelope
    (pristineStorageBinding proof)
    (pristineStorageObservationDigest proof)
    schemaVersion
    sealedPrivateKey
    commitment
    digest

preparedInitBinding :: PreparedInitEnvelope -> RootInitBinding
preparedInitBinding (PreparedInitEnvelope binding _ _ _ _ _) = binding

preparedInitPristineObservationDigest :: PreparedInitEnvelope -> ArtifactDigest
preparedInitPristineObservationDigest (PreparedInitEnvelope _ digest _ _ _ _) = digest

preparedInitSchemaVersion :: PreparedInitEnvelope -> BootstrapSchemaVersion
preparedInitSchemaVersion (PreparedInitEnvelope _ _ schemaVersion _ _ _) = schemaVersion

preparedInitSealedRecoveryPrivateKey
  :: PreparedInitEnvelope -> SealedRecoveryRecipientPrivateKey
preparedInitSealedRecoveryPrivateKey (PreparedInitEnvelope _ _ _ privateKey _ _) = privateKey

preparedInitRecipientCommitment :: PreparedInitEnvelope -> InitRecipientCommitment
preparedInitRecipientCommitment (PreparedInitEnvelope _ _ _ _ commitment _) = commitment

preparedInitRecoveryFingerprint :: PreparedInitEnvelope -> RecoveryRecipientFingerprint
preparedInitRecoveryFingerprint =
  initRecipientRecoveryFingerprint . preparedInitRecipientCommitment

preparedInitBurnFingerprint :: PreparedInitEnvelope -> BurnRecipientFingerprint
preparedInitBurnFingerprint =
  initRecipientBurnFingerprint . preparedInitRecipientCommitment

preparedInitEnvelopeDigest :: PreparedInitEnvelope -> ArtifactDigest
preparedInitEnvelopeDigest (PreparedInitEnvelope _ _ _ _ _ digest) = digest

-- | Vault's response after PGP targeting.  The root-token value appears only
-- as burn-recipient ciphertext.  This module intentionally provides no type or
-- function that can decrypt or use that ciphertext.
data EncryptedInitResponseReceipt
  = EncryptedInitResponseReceipt
      !RootInitBinding
      !BootstrapSchemaVersion
      !InitRecipientCommitment
      ![PgpEncryptedShare]
      !BurnTokenCiphertext
      !ArtifactDigest
  deriving stock (Eq)

instance Show EncryptedInitResponseReceipt where
  show receipt =
    "EncryptedInitResponseReceipt {binding = "
      ++ show (encryptedResponseBinding receipt)
      ++ ", schemaVersion = "
      ++ show (encryptedResponseSchemaVersion receipt)
      ++ ", recoveryFingerprint = "
      ++ show (encryptedResponseRecoveryFingerprint receipt)
      ++ ", burnFingerprint = "
      ++ show (encryptedResponseBurnFingerprint receipt)
      ++ ", encryptedShareCount = "
      ++ show (length (encryptedResponseShares receipt))
      ++ ", threshold = "
      ++ show (initRecipientThreshold (encryptedResponseRecipientCommitment receipt))
      ++ ", burnToken = <redacted>, digest = "
      ++ show (encryptedResponseReceiptDigest receipt)
      ++ "}"

mkEncryptedInitResponseReceipt
  :: PreparedInitEnvelope
  -> [PgpEncryptedShare]
  -> BurnTokenCiphertext
  -> ArtifactDigest
  -> Either BootstrapValueError EncryptedInitResponseReceipt
mkEncryptedInitResponseReceipt prepared shares burnToken digest
  | actualShareCount /= expectedShareCount =
      Left (BootstrapEncryptedShareCountMismatch expectedShareCount actualShareCount)
  | otherwise =
      Right
        ( EncryptedInitResponseReceipt
            (preparedInitBinding prepared)
            (preparedInitSchemaVersion prepared)
            commitment
            shares
            burnToken
            digest
        )
 where
  commitment = preparedInitRecipientCommitment prepared
  expectedShareCount = initRecipientShareCount commitment
  actualShareCount = fromIntegral (length shares)

encryptedResponseBinding :: EncryptedInitResponseReceipt -> RootInitBinding
encryptedResponseBinding (EncryptedInitResponseReceipt binding _ _ _ _ _) = binding

encryptedResponseSchemaVersion :: EncryptedInitResponseReceipt -> BootstrapSchemaVersion
encryptedResponseSchemaVersion (EncryptedInitResponseReceipt _ schemaVersion _ _ _ _) = schemaVersion

encryptedResponseRecipientCommitment
  :: EncryptedInitResponseReceipt -> InitRecipientCommitment
encryptedResponseRecipientCommitment (EncryptedInitResponseReceipt _ _ commitment _ _ _) = commitment

encryptedResponseRecoveryFingerprint
  :: EncryptedInitResponseReceipt -> RecoveryRecipientFingerprint
encryptedResponseRecoveryFingerprint =
  initRecipientRecoveryFingerprint . encryptedResponseRecipientCommitment

encryptedResponseBurnFingerprint
  :: EncryptedInitResponseReceipt -> BurnRecipientFingerprint
encryptedResponseBurnFingerprint =
  initRecipientBurnFingerprint . encryptedResponseRecipientCommitment

encryptedResponseShares :: EncryptedInitResponseReceipt -> [PgpEncryptedShare]
encryptedResponseShares (EncryptedInitResponseReceipt _ _ _ shares _ _) = shares

encryptedResponseBurnToken :: EncryptedInitResponseReceipt -> BurnTokenCiphertext
encryptedResponseBurnToken (EncryptedInitResponseReceipt _ _ _ _ burnToken _) = burnToken

encryptedResponseReceiptDigest :: EncryptedInitResponseReceipt -> ArtifactDigest
encryptedResponseReceiptDigest (EncryptedInitResponseReceipt _ _ _ _ _ digest) = digest

-- | The only plaintext shape admitted to final-bundle sealing.  It contains
-- recovery shares and binding metadata; there is structurally no initial-token
-- field.  Its 'Show' instance reveals only the share count.
data FinalUnlockBundlePayload
  = FinalUnlockBundlePayload
      !RootInitBinding
      !BootstrapSchemaVersion
      !Natural
      !Natural
      ![RecoveredUnsealShare]
  deriving stock (Eq)

instance Show FinalUnlockBundlePayload where
  show payload =
    "FinalUnlockBundlePayload {binding = "
      ++ show (finalPayloadBinding payload)
      ++ ", schemaVersion = "
      ++ show (finalPayloadSchemaVersion payload)
      ++ ", shares = <redacted:"
      ++ show (finalPayloadShareCount payload)
      ++ ">, threshold = "
      ++ show (finalPayloadThreshold payload)
      ++ "}"

mkFinalUnlockBundlePayload
  :: EncryptedInitResponseReceipt
  -> [RecoveredUnsealShare]
  -> Either BootstrapValueError FinalUnlockBundlePayload
mkFinalUnlockBundlePayload receipt shares
  | null shares = Left BootstrapEncryptedSharesEmpty
  | recoveredCount /= encryptedCount =
      Left (BootstrapRecoveredShareCountMismatch encryptedCount recoveredCount)
  | otherwise =
      Right
        ( FinalUnlockBundlePayload
            (encryptedResponseBinding receipt)
            (encryptedResponseSchemaVersion receipt)
            encryptedCount
            committedThreshold
            shares
        )
 where
  commitment = encryptedResponseRecipientCommitment receipt
  encryptedCount = initRecipientShareCount commitment
  committedThreshold = initRecipientThreshold commitment
  recoveredCount = fromIntegral (length shares)

finalPayloadBinding :: FinalUnlockBundlePayload -> RootInitBinding
finalPayloadBinding (FinalUnlockBundlePayload binding _ _ _ _) = binding

finalPayloadSchemaVersion :: FinalUnlockBundlePayload -> BootstrapSchemaVersion
finalPayloadSchemaVersion (FinalUnlockBundlePayload _ schemaVersion _ _ _) = schemaVersion

finalPayloadShareCount :: FinalUnlockBundlePayload -> Natural
finalPayloadShareCount (FinalUnlockBundlePayload _ _ shareCount _ _) = shareCount

finalPayloadThreshold :: FinalUnlockBundlePayload -> Natural
finalPayloadThreshold (FinalUnlockBundlePayload _ _ _ threshold _) = threshold

finalPayloadShares :: FinalUnlockBundlePayload -> [RecoveredUnsealShare]
finalPayloadShares (FinalUnlockBundlePayload _ _ _ _ shares) = shares

-- | Durable password-AEAD final custody.  Only sealed bytes and the verified
-- share count are retained by the model; no usable initial root token exists in
-- this type or its construction path.
data FinalUnlockBundle
  = FinalUnlockBundle
      !RootInitBinding
      !BootstrapSchemaVersion
      !PasswordAeadCiphertext
      !Natural
      !Natural
      !ArtifactDigest
  deriving stock (Eq)

instance Show FinalUnlockBundle where
  show bundle =
    "FinalUnlockBundle {binding = "
      ++ show (finalUnlockBundleBinding bundle)
      ++ ", schemaVersion = "
      ++ show (finalUnlockBundleSchemaVersion bundle)
      ++ ", ciphertext = <redacted>, shareCount = "
      ++ show (finalUnlockBundleShareCount bundle)
      ++ ", threshold = "
      ++ show (finalUnlockBundleThreshold bundle)
      ++ ", digest = "
      ++ show (finalUnlockBundleDigest bundle)
      ++ "}"

mkFinalUnlockBundle
  :: FinalUnlockBundlePayload
  -> PasswordAeadCiphertext
  -> ArtifactDigest
  -> FinalUnlockBundle
mkFinalUnlockBundle payload ciphertext digest =
  FinalUnlockBundle
    (finalPayloadBinding payload)
    (finalPayloadSchemaVersion payload)
    ciphertext
    (finalPayloadShareCount payload)
    (finalPayloadThreshold payload)
    digest

finalUnlockBundleBinding :: FinalUnlockBundle -> RootInitBinding
finalUnlockBundleBinding (FinalUnlockBundle binding _ _ _ _ _) = binding

finalUnlockBundleSchemaVersion :: FinalUnlockBundle -> BootstrapSchemaVersion
finalUnlockBundleSchemaVersion (FinalUnlockBundle _ schemaVersion _ _ _ _) = schemaVersion

finalUnlockBundleCiphertext :: FinalUnlockBundle -> PasswordAeadCiphertext
finalUnlockBundleCiphertext (FinalUnlockBundle _ _ ciphertext _ _ _) = ciphertext

finalUnlockBundleShareCount :: FinalUnlockBundle -> Natural
finalUnlockBundleShareCount (FinalUnlockBundle _ _ _ shareCount _ _) = shareCount

finalUnlockBundleThreshold :: FinalUnlockBundle -> Natural
finalUnlockBundleThreshold (FinalUnlockBundle _ _ _ _ threshold _) = threshold

finalUnlockBundleDigest :: FinalUnlockBundle -> ArtifactDigest
finalUnlockBundleDigest (FinalUnlockBundle _ _ _ _ _ digest) = digest

data RecoveryCustodyReceipt
  = RecoveryCustodyReceipt
      !RootInitBinding
      !ArtifactDigest
      !ArtifactDigest
  deriving stock (Eq, Show)

mkRecoveryCustodyReceipt
  :: FinalUnlockBundle -> ArtifactDigest -> RecoveryCustodyReceipt
mkRecoveryCustodyReceipt bundle acknowledgementDigest =
  RecoveryCustodyReceipt
    (finalUnlockBundleBinding bundle)
    (finalUnlockBundleDigest bundle)
    acknowledgementDigest

recoveryCustodyBinding :: RecoveryCustodyReceipt -> RootInitBinding
recoveryCustodyBinding (RecoveryCustodyReceipt binding _ _) = binding

recoveryCustodyFinalBundleDigest :: RecoveryCustodyReceipt -> ArtifactDigest
recoveryCustodyFinalBundleDigest (RecoveryCustodyReceipt _ digest _) = digest

recoveryCustodyAcknowledgementDigest :: RecoveryCustodyReceipt -> ArtifactDigest
recoveryCustodyAcknowledgementDigest (RecoveryCustodyReceipt _ _ digest) = digest

data InitAmbiguity = InitAmbiguity !RootInitBinding !ArtifactDigest
  deriving stock (Eq, Show)

mkInitAmbiguity :: PreparedInitEnvelope -> InitAmbiguity
mkInitAmbiguity prepared =
  InitAmbiguity
    (preparedInitBinding prepared)
    (preparedInitEnvelopeDigest prepared)

ambiguousInitBinding :: InitAmbiguity -> RootInitBinding
ambiguousInitBinding (InitAmbiguity binding _) = binding

ambiguousPreparedEnvelopeDigest :: InitAmbiguity -> ArtifactDigest
ambiguousPreparedEnvelopeDigest (InitAmbiguity _ digest) = digest

data EstablishedStateAbsence = EstablishedStateAbsence !RootInitBinding !ArtifactDigest
  deriving stock (Eq, Show)

mkEstablishedStateAbsence
  :: RootInitBinding -> ArtifactDigest -> EstablishedStateAbsence
mkEstablishedStateAbsence = EstablishedStateAbsence

data DurableInitResponseAbsence = DurableInitResponseAbsence !RootInitBinding !ArtifactDigest
  deriving stock (Eq, Show)

mkDurableInitResponseAbsence
  :: RootInitBinding -> ArtifactDigest -> DurableInitResponseAbsence
mkDurableInitResponseAbsence = DurableInitResponseAbsence

data BaselineStateAbsence = BaselineStateAbsence !RootInitBinding !ArtifactDigest
  deriving stock (Eq, Show)

mkBaselineStateAbsence
  :: RootInitBinding -> ArtifactDigest -> BaselineStateAbsence
mkBaselineStateAbsence = BaselineStateAbsence

-- | A reset proof binds both the ambiguity it discharges and the replacement
-- exact-pristine generation.  The three absence witnesses are produced only by
-- the boundary auditor; their presence prevents a generic "reset anyway"
-- command from being represented.
data PristineResetProof
  = PristineResetProof
      !RootInitBinding
      !PristineStorageProof
      !EstablishedStateAbsence
      !DurableInitResponseAbsence
      !BaselineStateAbsence
  deriving stock (Eq, Show)

mkPristineResetProof
  :: InitAmbiguity
  -> PristineStorageProof
  -> EstablishedStateAbsence
  -> DurableInitResponseAbsence
  -> BaselineStateAbsence
  -> Either BootstrapValueError PristineResetProof
mkPristineResetProof ambiguity replacement establishedAbsence responseAbsence baselineAbsence =
  if rootInitStorageGeneration (pristineStorageBinding replacement)
    == rootInitStorageGeneration ambiguousBinding
    then Left BootstrapResetReplacementMustAdvance
    else do
      requireResetAbsenceBinding "established state" ambiguousBinding establishedBinding
      requireResetAbsenceBinding "durable init response" ambiguousBinding responseBinding
      requireResetAbsenceBinding "baseline state" ambiguousBinding baselineBinding
      Right
        ( PristineResetProof
            ambiguousBinding
            replacement
            establishedAbsence
            responseAbsence
            baselineAbsence
        )
 where
  ambiguousBinding = ambiguousInitBinding ambiguity
  EstablishedStateAbsence establishedBinding _ = establishedAbsence
  DurableInitResponseAbsence responseBinding _ = responseAbsence
  BaselineStateAbsence baselineBinding _ = baselineAbsence

resetAmbiguousBinding :: PristineResetProof -> RootInitBinding
resetAmbiguousBinding (PristineResetProof binding _ _ _ _) = binding

resetReplacementPristine :: PristineResetProof -> PristineStorageProof
resetReplacementPristine (PristineResetProof _ replacement _ _ _) = replacement

-- | The complete root baseline allowlist.  There is deliberately no generic
-- path, policy name, mount name, or KV operation constructor.
data BaselineTarget
  = BaselineKvV2Mount
  | BaselineTransitMount
  | BaselinePkiMount
  | BaselineKubernetesAuthMethod
  | BaselineBootstrapProvisionerPolicy
  | BaselineBootstrapProvisionerRole
  | BaselineTokenAccessorAuditorPolicy
  | BaselineTokenAccessorAuditorRole
  | BaselineAuthorityGenesisSigningKey
  | BaselinePkiTestRole
  deriving stock (Eq, Ord, Show, Enum, Bounded)

requiredRootBaselineTargets :: [BaselineTarget]
requiredRootBaselineTargets = [minBound .. maxBound]

data RootAccessorInventory
  = RootAccessorInventory
      !VaultStorageGeneration
      ![RootPolicyAccessor]
  deriving stock (Eq, Show)

mkRootAccessorInventory
  :: VaultStorageGeneration
  -> [RootPolicyAccessor]
  -> Either BootstrapValueError RootAccessorInventory
mkRootAccessorInventory generation accessors
  | actual > maximumAccessors =
      Left (BootstrapAccessorInventoryTooLarge actual maximumAccessors)
  | otherwise =
      case firstDuplicate accessors of
        Just duplicate -> Left (BootstrapAccessorInventoryDuplicate duplicate)
        Nothing ->
          Right
            (RootAccessorInventory generation (sort accessors))
 where
  actual = fromIntegral (length accessors)
  maximumAccessors = 64

rootAccessorInventoryGeneration :: RootAccessorInventory -> VaultStorageGeneration
rootAccessorInventoryGeneration (RootAccessorInventory generation _) = generation

rootAccessorInventoryAccessors :: RootAccessorInventory -> [RootPolicyAccessor]
rootAccessorInventoryAccessors (RootAccessorInventory _ accessors) = accessors

-- | Auditor evidence that every accessor named by the canonical inventory was
-- observed absent.  In this context the embedded list is the proof target,
-- not a list of accessors that were observed present.
data AccessorAbsenceAttestation
  = AccessorAbsenceAttestation
      !RootAccessorInventory
      !ArtifactDigest
  deriving stock (Eq, Show)

mkAccessorAbsenceAttestation
  :: RootAccessorInventory -> ArtifactDigest -> AccessorAbsenceAttestation
mkAccessorAbsenceAttestation inventory digest =
  AccessorAbsenceAttestation inventory digest

accessorAbsenceInventory :: AccessorAbsenceAttestation -> RootAccessorInventory
accessorAbsenceInventory (AccessorAbsenceAttestation inventory _) = inventory

accessorAbsenceObservationDigest :: AccessorAbsenceAttestation -> ArtifactDigest
accessorAbsenceObservationDigest (AccessorAbsenceAttestation _ digest) = digest

data BaselineReadBackReceipt
  = BaselineReadBackReceipt
      !RootSessionId
      !VaultStorageGeneration
      ![BaselineTarget]
      !ArtifactDigest
  deriving stock (Eq, Show)

mkBaselineReadBackReceipt
  :: RootSessionId
  -> VaultStorageGeneration
  -> [BaselineTarget]
  -> ArtifactDigest
  -> Either BootstrapValueError BaselineReadBackReceipt
mkBaselineReadBackReceipt sessionId generation targets digest
  | sort (nub targets) /= requiredRootBaselineTargets =
      Left (BootstrapBaselineTargetsIncomplete (sort (nub targets)))
  | otherwise =
      Right
        ( BaselineReadBackReceipt
            sessionId
            generation
            requiredRootBaselineTargets
            digest
        )

baselineReadBackSessionId :: BaselineReadBackReceipt -> RootSessionId
baselineReadBackSessionId (BaselineReadBackReceipt sessionId _ _ _) = sessionId

baselineReadBackStorageGeneration :: BaselineReadBackReceipt -> VaultStorageGeneration
baselineReadBackStorageGeneration (BaselineReadBackReceipt _ generation _ _) = generation

baselineReadBackTargets :: BaselineReadBackReceipt -> [BaselineTarget]
baselineReadBackTargets (BaselineReadBackReceipt _ _ targets _) = targets

baselineReadBackDigest :: BaselineReadBackReceipt -> ArtifactDigest
baselineReadBackDigest (BaselineReadBackReceipt _ _ _ digest) = digest

data ProvisionerLoginReceipt
  = ProvisionerLoginReceipt
      !VaultStorageGeneration
      !ProvisionerAccessor
      !Natural
  deriving stock (Eq, Show)

mkProvisionerLoginReceipt
  :: VaultStorageGeneration
  -> ProvisionerAccessor
  -> Natural
  -> Either BootstrapValueError ProvisionerLoginReceipt
mkProvisionerLoginReceipt generation accessor leaseSeconds
  | leaseSeconds == 0 = Left BootstrapProvisionerLeaseMustBePositive
  | leaseSeconds > maximumProvisionerLeaseSeconds =
      Left
        ( BootstrapProvisionerLeaseTooLong
            maximumProvisionerLeaseSeconds
            leaseSeconds
        )
  | otherwise =
      Right
        (ProvisionerLoginReceipt generation accessor leaseSeconds)
 where
  maximumProvisionerLeaseSeconds = 3600

provisionerLoginStorageGeneration :: ProvisionerLoginReceipt -> VaultStorageGeneration
provisionerLoginStorageGeneration (ProvisionerLoginReceipt generation _ _) = generation

provisionerLoginAccessor :: ProvisionerLoginReceipt -> ProvisionerAccessor
provisionerLoginAccessor (ProvisionerLoginReceipt _ accessor _) = accessor

provisionerLoginLeaseSeconds :: ProvisionerLoginReceipt -> Natural
provisionerLoginLeaseSeconds (ProvisionerLoginReceipt _ _ leaseSeconds) = leaseSeconds

-- | The broker may observe this consumer accepting the handoff; it never
-- receives an authority-writer constructor or permit.
data PostUnsealConsumer
  = PostUnsealLifecycleAuthority
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data PostUnsealHandoffReceipt
  = PostUnsealHandoffReceipt
      !VaultStorageGeneration
      !PostUnsealConsumer
      !ArtifactDigest
  deriving stock (Eq, Show)

mkPostUnsealHandoffReceipt
  :: VaultStorageGeneration
  -> PostUnsealConsumer
  -> ArtifactDigest
  -> PostUnsealHandoffReceipt
mkPostUnsealHandoffReceipt = PostUnsealHandoffReceipt

postUnsealHandoffGeneration :: PostUnsealHandoffReceipt -> VaultStorageGeneration
postUnsealHandoffGeneration (PostUnsealHandoffReceipt generation _ _) = generation

postUnsealHandoffConsumer :: PostUnsealHandoffReceipt -> PostUnsealConsumer
postUnsealHandoffConsumer (PostUnsealHandoffReceipt _ consumer _) = consumer

postUnsealHandoffObservationDigest :: PostUnsealHandoffReceipt -> ArtifactDigest
postUnsealHandoffObservationDigest (PostUnsealHandoffReceipt _ _ digest) = digest

data ChildCustodyBinding = ChildCustodyBinding
  { childCustodyChildId :: !ChildId
  , childCustodyStorageGeneration :: !VaultStorageGeneration
  , childCustodyGeneration :: !CustodyGeneration
  , childCustodyTransactionId :: !BootstrapTransactionId
  }
  deriving stock (Eq, Ord, Show)

data ChildEncryptedReceipt = ChildEncryptedReceipt
  { childEncryptedReceiptBinding :: !ChildCustodyBinding
  , childEncryptedReceiptShares :: ![PgpEncryptedShare]
  , childEncryptedReceiptBurnToken :: !BurnTokenCiphertext
  , childEncryptedReceiptDigest :: !ArtifactDigest
  }
  deriving stock (Eq)

instance Show ChildEncryptedReceipt where
  show
    ChildEncryptedReceipt
      { childEncryptedReceiptBinding
      , childEncryptedReceiptShares
      , childEncryptedReceiptDigest
      } =
      "ChildEncryptedReceipt {binding = "
        ++ show childEncryptedReceiptBinding
        ++ ", encryptedShares = <redacted:"
        ++ show (length childEncryptedReceiptShares)
        ++ ">, burnToken = <redacted>, digest = "
        ++ show childEncryptedReceiptDigest
        ++ "}"

mkChildEncryptedReceipt
  :: ChildCustodyBinding
  -> [PgpEncryptedShare]
  -> BurnTokenCiphertext
  -> ArtifactDigest
  -> Either BootstrapValueError ChildEncryptedReceipt
mkChildEncryptedReceipt binding shares burnToken digest
  | null shares = Left BootstrapEncryptedSharesEmpty
  | otherwise =
      Right
        ChildEncryptedReceipt
          { childEncryptedReceiptBinding = binding
          , childEncryptedReceiptShares = shares
          , childEncryptedReceiptBurnToken = burnToken
          , childEncryptedReceiptDigest = digest
          }

data ParentCustodyAcknowledgement = ParentCustodyAcknowledgement
  { parentCustodyAcknowledgedBinding :: !ChildCustodyBinding
  , parentCustodyAcknowledgedReceiptDigest :: !ArtifactDigest
  , parentCustodyAcknowledgementDigest :: !ArtifactDigest
  }
  deriving stock (Eq, Show)

mkParentCustodyAcknowledgement
  :: ChildEncryptedReceipt -> ArtifactDigest -> ParentCustodyAcknowledgement
mkParentCustodyAcknowledgement receipt acknowledgementDigest =
  ParentCustodyAcknowledgement
    { parentCustodyAcknowledgedBinding = childEncryptedReceiptBinding receipt
    , parentCustodyAcknowledgedReceiptDigest = childEncryptedReceiptDigest receipt
    , parentCustodyAcknowledgementDigest = acknowledgementDigest
    }

-- | One-time parent-to-child recovery delivery.  The payload is already
-- encrypted to the attested child; the model has no plaintext-share field.
data ChildRecoveryDelivery = ChildRecoveryDelivery
  { childRecoveryDeliveryBinding :: !ChildCustodyBinding
  , childRecoveryDeliveryNonce :: !DeliveryNonce
  , childRecoveryDeliveryAttestation :: !ChildAttestation
  , childRecoveryDeliveryPayload :: !EncryptedChildRecoveryPayload
  , childRecoveryDeliveryDigest :: !ArtifactDigest
  }
  deriving stock (Eq)

instance Show ChildRecoveryDelivery where
  show
    ChildRecoveryDelivery
      { childRecoveryDeliveryBinding
      , childRecoveryDeliveryNonce
      , childRecoveryDeliveryAttestation
      , childRecoveryDeliveryDigest
      } =
      "ChildRecoveryDelivery {binding = "
        ++ show childRecoveryDeliveryBinding
        ++ ", nonce = "
        ++ show childRecoveryDeliveryNonce
        ++ ", attestation = "
        ++ show childRecoveryDeliveryAttestation
        ++ ", payload = <redacted>, digest = "
        ++ show childRecoveryDeliveryDigest
        ++ "}"

mkChildRecoveryDelivery
  :: ChildCustodyBinding
  -> DeliveryNonce
  -> ChildAttestation
  -> EncryptedChildRecoveryPayload
  -> ArtifactDigest
  -> ChildRecoveryDelivery
mkChildRecoveryDelivery binding nonce attestation payload digest =
  ChildRecoveryDelivery
    { childRecoveryDeliveryBinding = binding
    , childRecoveryDeliveryNonce = nonce
    , childRecoveryDeliveryAttestation = attestation
    , childRecoveryDeliveryPayload = payload
    , childRecoveryDeliveryDigest = digest
    }

-- | Authoritative keyed observation of the one-time child-recovery consume
-- effect.  It deliberately carries only the delivery identity, never the
-- encrypted payload itself.  A negative observation is therefore just as
-- tightly bound as a positive one before the engine may issue the effect.
data ChildRecoveryConsumptionStatus
  = ChildRecoveryConsumptionNotApplied
  | ChildRecoveryConsumptionApplied
  deriving stock (Eq, Ord, Show)

data ChildRecoveryConsumptionObservation
  = ChildRecoveryConsumptionObservation
      !ChildCustodyBinding
      !DeliveryNonce
      !ChildAttestation
      !ArtifactDigest
      !ChildRecoveryConsumptionStatus
      !ArtifactDigest
  deriving stock (Eq, Show)

mkChildRecoveryConsumptionObservation
  :: ChildRecoveryDelivery
  -> ChildRecoveryConsumptionStatus
  -> ArtifactDigest
  -> ChildRecoveryConsumptionObservation
mkChildRecoveryConsumptionObservation delivery status observationDigest =
  ChildRecoveryConsumptionObservation
    (childRecoveryDeliveryBinding delivery)
    (childRecoveryDeliveryNonce delivery)
    (childRecoveryDeliveryAttestation delivery)
    (childRecoveryDeliveryDigest delivery)
    status
    observationDigest

childRecoveryConsumptionBinding
  :: ChildRecoveryConsumptionObservation -> ChildCustodyBinding
childRecoveryConsumptionBinding
  (ChildRecoveryConsumptionObservation binding _ _ _ _ _) = binding

childRecoveryConsumptionNonce
  :: ChildRecoveryConsumptionObservation -> DeliveryNonce
childRecoveryConsumptionNonce
  (ChildRecoveryConsumptionObservation _ nonce _ _ _ _) = nonce

childRecoveryConsumptionAttestation
  :: ChildRecoveryConsumptionObservation -> ChildAttestation
childRecoveryConsumptionAttestation
  (ChildRecoveryConsumptionObservation _ _ attestation _ _ _) = attestation

childRecoveryConsumptionDeliveryDigest
  :: ChildRecoveryConsumptionObservation -> ArtifactDigest
childRecoveryConsumptionDeliveryDigest
  (ChildRecoveryConsumptionObservation _ _ _ digest _ _) = digest

childRecoveryConsumptionStatus
  :: ChildRecoveryConsumptionObservation -> ChildRecoveryConsumptionStatus
childRecoveryConsumptionStatus
  (ChildRecoveryConsumptionObservation _ _ _ _ status _) = status

childRecoveryConsumptionObservationDigest
  :: ChildRecoveryConsumptionObservation -> ArtifactDigest
childRecoveryConsumptionObservationDigest
  (ChildRecoveryConsumptionObservation _ _ _ _ _ digest) = digest

childRecoveryConsumptionObservationMatches
  :: ChildRecoveryDelivery
  -> ChildRecoveryConsumptionStatus
  -> ChildRecoveryConsumptionObservation
  -> Bool
childRecoveryConsumptionObservationMatches delivery expectedStatus observation =
  childRecoveryConsumptionBinding observation
    == childRecoveryDeliveryBinding delivery
    && childRecoveryConsumptionNonce observation
      == childRecoveryDeliveryNonce delivery
    && childRecoveryConsumptionAttestation observation
      == childRecoveryDeliveryAttestation delivery
    && childRecoveryConsumptionDeliveryDigest observation
      == childRecoveryDeliveryDigest delivery
    && childRecoveryConsumptionStatus observation == expectedStatus

-- | Exact read-back of the allowlisted repair performed with a one-time child
-- recovery delivery.  It binds the repair to the consumed delivery without
-- carrying a token, recovery share, or plaintext-derived value.
data ChildRecoveryRepairReceipt = ChildRecoveryRepairReceipt
  { childRecoveryRepairBinding :: !ChildCustodyBinding
  , childRecoveryRepairNonce :: !DeliveryNonce
  , childRecoveryRepairAttestation :: !ChildAttestation
  , childRecoveryRepairDeliveryDigest :: !ArtifactDigest
  , childRecoveryRepairReadBackDigest :: !ArtifactDigest
  }
  deriving stock (Eq, Show)

mkChildRecoveryRepairReceipt
  :: ChildRecoveryDelivery
  -> ArtifactDigest
  -> ChildRecoveryRepairReceipt
mkChildRecoveryRepairReceipt delivery readBackDigest =
  ChildRecoveryRepairReceipt
    { childRecoveryRepairBinding = childRecoveryDeliveryBinding delivery
    , childRecoveryRepairNonce = childRecoveryDeliveryNonce delivery
    , childRecoveryRepairAttestation = childRecoveryDeliveryAttestation delivery
    , childRecoveryRepairDeliveryDigest = childRecoveryDeliveryDigest delivery
    , childRecoveryRepairReadBackDigest = readBackDigest
    }

maximumInitShareCount :: Natural
maximumInitShareCount = 255

maximumInitRecipientPublicKeyBytes :: Natural
maximumInitRecipientPublicKeyBytes = 64 * 1024

maximumInitRecipientPayloadBytes :: Natural
maximumInitRecipientPayloadBytes = maximumOpaqueBoundaryBytes

validateInitRecipientPublicKey
  :: Natural -> Text -> Either BootstrapValueError Text
validateInitRecipientPublicKey index encoded
  | Text.null encoded || encoded /= Text.strip encoded =
      Left (BootstrapInitRecipientPublicKeyInvalid index)
  | encodedByteCount > maximumInitRecipientPublicKeyBytes =
      Left
        ( BootstrapInitRecipientPublicKeyTooLarge
            index
            encodedByteCount
            maximumInitRecipientPublicKeyBytes
        )
  | otherwise =
      case Base64.decode encodedBytes of
        Left _ -> Left (BootstrapInitRecipientPublicKeyInvalid index)
        Right decoded
          | BS.null decoded || Base64.encode decoded /= encodedBytes ->
              Left (BootstrapInitRecipientPublicKeyInvalid index)
          | otherwise -> Right encoded
 where
  encodedBytes = TextEncoding.encodeUtf8 encoded
  encodedByteCount = fromIntegral (BS.length encodedBytes)

encodeOrderedPublicKeys :: [Text] -> ByteString
encodeOrderedPublicKeys publicKeys =
  TextEncoding.encodeUtf8
    ( Text.pack (show (length publicKeys))
        <> Text.singleton ':'
        <> Text.concat (fmap encodeOne publicKeys)
    )
 where
  encodeOne publicKey =
    Text.pack (show (Text.length publicKey)) <> Text.singleton ':' <> publicKey

digestOrderedPublicKeys :: [Text] -> ArtifactDigest
digestOrderedPublicKeys =
  ArtifactDigest . lowerHexBytes . SHA256.hash . encodeOrderedPublicKeys

lowerHexBytes :: ByteString -> Text
lowerHexBytes = Text.pack . concatMap renderHexByte . BS.unpack
 where
  renderHexByte byte =
    case showHex byte "" of
      [digit] -> ['0', digit]
      digits -> digits

requireResetAbsenceBinding
  :: String
  -> RootInitBinding
  -> RootInitBinding
  -> Either BootstrapValueError ()
requireResetAbsenceBinding label expected actual
  | expected == actual = Right ()
  | otherwise = Left (BootstrapResetAbsenceBindingMismatch label)

boundedIdentifier
  :: String -> Int -> Text -> Either BootstrapValueError Text
boundedIdentifier label maximumLength raw
  | Text.null value = Left (BootstrapValueEmpty label)
  | Text.length value > maximumLength =
      Left (BootstrapValueTooLong label (Text.length value) maximumLength)
  | Text.all allowed value = Right value
  | otherwise = Left (BootstrapValueForbiddenCharacter label)
 where
  value = Text.strip raw
  allowed character =
    isAsciiLower character
      || isAsciiUpper character
      || isDigit character
      || character `elem` ("-._:/@" :: String)

lowerHexSha256
  :: String -> Text -> Either BootstrapValueError Text
lowerHexSha256 label raw
  | Text.length raw == 64 && Text.all isLowerHex raw = Right raw
  | otherwise = Left (BootstrapValueMustBeLowerHexSha256 label)
 where
  isLowerHex character = isDigit character || character >= 'a' && character <= 'f'

lowerHexOpenPgpV4Fingerprint
  :: String -> Text -> Either BootstrapValueError Text
lowerHexOpenPgpV4Fingerprint label raw
  | Text.length raw == 40 && Text.all isLowerHex raw = Right raw
  | otherwise =
      Left (BootstrapValueMustBeLowerHexOpenPgpV4Fingerprint label)
 where
  isLowerHex character = isDigit character || character >= 'a' && character <= 'f'

firstDuplicate :: (Eq value) => [value] -> Maybe value
firstDuplicate values = go [] values
 where
  go _ [] = Nothing
  go seen (value : rest)
    | value `elem` seen = Just value
    | otherwise = go (value : seen) rest
