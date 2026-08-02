{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Sprint 4.50: the deterministic decommission inventory that the receipt is
-- bound to.
--
-- A 'DecommissionManifest' is the signed plan a total-teardown run commits to
-- before the point of no return: the ordered set of typed nodes it will destroy,
-- read back, and prove absent, tagged with the cluster identity it decommissions.
-- Its canonical digest ('decommissionManifestDigest') is the exact
-- 'Prodbox.Lifecycle.Decommission.Frame.FrameDigest' every receipt frame carries,
-- so a receipt can never be replayed against a different plan — reopening a
-- receipt under a manifest whose digest differs is a chain refusal, not a resume.
--
-- The manifest is opaque: it is only reachable through 'mkDecommissionManifest',
-- which rejects an empty or duplicated inventory, an invalid cluster identity, and
-- an invalid target reference, so a malformed plan cannot be digested or committed.
-- The typed-graph ordering over these nodes (TLS objects before the shared bucket,
-- SES IAM destroy/read-back before target/custody tombstones, backup and shared
-- bucket last) and the retained-Model-B receipt-commit are separate increments.
module Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionTargetGeneration
  , DecommissionTargetGenerationError (..)
  , mkDecommissionTargetGeneration
  , decommissionTargetGenerationValue
  , DecommissionNode (..)
  , DecommissionManifest
  , ManifestError (..)
  , currentManifestVersion
  , mkDecommissionManifest
  , manifestVersion
  , manifestClusterId
  , manifestNodes
  , decommissionNodeFrameId
  , decommissionManifestDigest
  , ManifestCodecError (..)
  , encodeDecommissionManifest
  , decodeDecommissionManifest
  , ManifestSigningKey
  , ManifestSigningKeyError (..)
  , mkManifestSigningKey
  , ManifestPublicKey
  , mkManifestPublicKey
  , manifestPublicKeyBytes
  , manifestPublicKeyDigest
  , manifestSigningPublicKey
  , ManifestSignature
  , manifestSignatureBytes
  , SignedDecommissionManifest
  , signDecommissionManifest
  , manifestSigningPayload
  , verifyExternallySignedDecommissionManifest
  , signedManifestPlan
  , signedManifestVerifierBinding
  , signedManifestPublicKey
  , signedManifestSignature
  , signedDecommissionManifestDigest
  , signedManifestSignatureDigest
  , SignedManifestVerificationError (..)
  , VerifiedDecommissionManifest
  , verifySignedDecommissionManifest
  , verifiedSignedManifest
  , verifiedManifestPlan
  , verifiedVerifierBinding
  , verifiedManifestDigest
  , SignedManifestCodecError (..)
  , encodeSignedDecommissionManifest
  , decodeSignedDecommissionManifest
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.ByteArray qualified as ByteArray
import Data.ByteString qualified as StrictByteString
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.Decommission.Frame
  ( FrameDigest
  , FrameNodeId
  , contentDigest
  , frameNodeIdForContent
  )
import Prodbox.Lifecycle.Decommission.Verifier
  ( VerifierBinding
  , VerifierBindingError
  , validateVerifierBinding
  )

-- | A positive credential generation authenticated by the signed manifest.
-- Opaque construction prevents a caller from adding an unversioned or zero
-- generation target node to a production plan.
newtype DecommissionTargetGeneration = DecommissionTargetGeneration Natural
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data DecommissionTargetGenerationError
  = DecommissionTargetGenerationMustBePositive
  deriving stock (Eq, Show)

mkDecommissionTargetGeneration
  :: Natural
  -> Either DecommissionTargetGenerationError DecommissionTargetGeneration
mkDecommissionTargetGeneration generation
  | generation == 0 = Left DecommissionTargetGenerationMustBePositive
  | otherwise = Right (DecommissionTargetGeneration generation)

decommissionTargetGenerationValue :: DecommissionTargetGeneration -> Natural
decommissionTargetGenerationValue (DecommissionTargetGeneration generation) = generation

-- | A typed unit of decommission work. Singleton nodes name a unique resource
-- class; 'TargetGeneration' authenticates both the registered target reference
-- and its exact positive credential generation. A run may name several Agents,
-- but it cannot authorize two competing generations for one Agent reference.
data DecommissionNode
  = -- | Prove every SES consumer quiescent before destroying the provider.
    SesConsumerQuiescence
  | -- | Destroy and read back the SES provider stack.
    SesProviderStack
  | -- | Destroy and read back the external SMTP IAM family.
    SesSmtpIam
  | -- | Tombstone and read back one exact Target Secret Agent generation.
    TargetGeneration !Text !DecommissionTargetGeneration
  | -- | Tombstone and read back retained-home custody.
    RetainedCustody
  | -- | Delete the retained TLS objects and versions (never the shared bucket).
    TlsRetainedObjects
  | -- | Delete the TLS retention identity.
    TlsRetentionIdentity
  | -- | Prove every registered backup prefix absent before deleting backup state.
    BackupPrefixAbsenceProof
  | -- | Delete the backup objects and identity.
    BackupObjects
  | -- | Delete the shared object bucket — always last.
    SharedObjectBucket
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | The deterministic signed inventory. Opaque: build it through
-- 'mkDecommissionManifest'.
data DecommissionManifest = DecommissionManifest
  { manifestVersion :: !Word
  , manifestClusterId :: !Text
  , manifestNodes :: ![DecommissionNode]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ManifestError
  = ManifestClusterIdInvalid
  | ManifestNodesEmpty
  | ManifestNodesDuplicated
  | ManifestTargetRefInvalid
  | ManifestTargetRefDuplicated
  | ManifestTargetGenerationInvalid
  deriving stock (Eq, Show)

currentManifestVersion :: Word
currentManifestVersion = 1

-- | Build a validated manifest: a non-empty, duplicate-free node inventory under a
-- well-formed cluster identity, with every target reference well-formed.
mkDecommissionManifest
  :: Text
  -> [DecommissionNode]
  -> Either ManifestError DecommissionManifest
mkDecommissionManifest clusterId nodes
  | not (validIdentifier clusterId) = Left ManifestClusterIdInvalid
  | null nodes = Left ManifestNodesEmpty
  | any invalidTargetReference nodes = Left ManifestTargetRefInvalid
  | any invalidTargetGeneration nodes = Left ManifestTargetGenerationInvalid
  | targetReferences /= nub targetReferences = Left ManifestTargetRefDuplicated
  | nub nodes /= nodes = Left ManifestNodesDuplicated
  | otherwise =
      Right
        DecommissionManifest
          { manifestVersion = currentManifestVersion
          , manifestClusterId = Text.strip clusterId
          , manifestNodes = nodes
          }
 where
  targetReferences = [reference | TargetGeneration reference _ <- nodes]
  invalidTargetReference node = case node of
    TargetGeneration reference _ -> not (validIdentifier reference)
    _ -> False
  invalidTargetGeneration node = case node of
    TargetGeneration _ generation -> decommissionTargetGenerationValue generation == 0
    _ -> False

-- | The canonical digest that binds a receipt to this exact plan.
decommissionManifestDigest :: DecommissionManifest -> FrameDigest
decommissionManifestDigest =
  contentDigest . LazyByteString.toStrict . serialise

-- | The receipt identity of a manifest node.  It is derived from the node's
-- canonical typed representation rather than supplied as unrelated text, so all
-- attempts for one exact coordinate share an ID and two different coordinates
-- cannot be accidentally journaled under one human-selected label.
decommissionNodeFrameId :: DecommissionNode -> FrameNodeId
decommissionNodeFrameId =
  frameNodeIdForContent . LazyByteString.toStrict . serialise

data ManifestCodecError
  = ManifestEnvelopeTooLarge
  | ManifestEnvelopeInvalid
  | ManifestEnvelopeUnsupportedVersion
  | ManifestEnvelopeNonCanonical
  | ManifestEnvelopeSemanticInvalid !ManifestError
  deriving stock (Eq, Show)

-- | Canonical manifest bytes. The manifest is its own versioned envelope (it
-- carries 'manifestVersion'), so a separate wrapper is unnecessary.
encodeDecommissionManifest :: DecommissionManifest -> ByteString
encodeDecommissionManifest = serialise

-- | Decode a manifest from @maximumBytes@-bounded canonical bytes, refusing
-- oversize, non-canonical, and unsupported-version input before it can be
-- committed or resumed.
decodeDecommissionManifest
  :: Int -> ByteString -> Either ManifestCodecError DecommissionManifest
decodeDecommissionManifest maximumBytes bytes
  | maximumBytes < 0 = Left ManifestEnvelopeTooLarge
  | LazyByteString.length bytes > fromIntegral maximumBytes = Left ManifestEnvelopeTooLarge
  | otherwise =
      case deserialiseOrFail bytes of
        Left _ -> Left ManifestEnvelopeInvalid
        Right manifest
          | manifestVersion manifest /= currentManifestVersion ->
              Left ManifestEnvelopeUnsupportedVersion
          | serialise manifest /= bytes -> Left ManifestEnvelopeNonCanonical
          | otherwise ->
              case mkDecommissionManifest (manifestClusterId manifest) (manifestNodes manifest) of
                Left err -> Left (ManifestEnvelopeSemanticInvalid err)
                Right validated
                  | validated == manifest -> Right validated
                  | otherwise -> Left ManifestEnvelopeNonCanonical

validIdentifier :: Text -> Bool
validIdentifier value =
  not (Text.null trimmed)
    && Text.length trimmed <= 128
    && not (Text.any isControl trimmed)
 where
  trimmed = Text.strip value

-- | Authority signing material.  It is intentionally neither serialisable nor
-- showable, so no manifest, receipt, or diagnostic can accidentally contain the
-- private key.
newtype ManifestSigningKey = ManifestSigningKey Ed25519.SecretKey

data ManifestSigningKeyError
  = ManifestSigningKeyInvalid
  deriving stock (Eq, Show)

mkManifestSigningKey
  :: StrictByteString.ByteString
  -> Either ManifestSigningKeyError ManifestSigningKey
mkManifestSigningKey bytes = case Ed25519.secretKey bytes of
  CryptoFailed _ -> Left ManifestSigningKeyInvalid
  CryptoPassed key -> Right (ManifestSigningKey key)

newtype ManifestPublicKey = ManifestPublicKey StrictByteString.ByteString
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

manifestPublicKeyBytes :: ManifestPublicKey -> StrictByteString.ByteString
manifestPublicKeyBytes (ManifestPublicKey bytes) = bytes

-- | Validate public Authority signing material obtained from a non-exportable
-- signing service (for example Vault Transit).  The private key never crosses
-- this boundary.
mkManifestPublicKey
  :: StrictByteString.ByteString
  -> Either SignedManifestVerificationError ManifestPublicKey
mkManifestPublicKey bytes = do
  _ <- parsePublicKey (ManifestPublicKey bytes)
  Right (ManifestPublicKey bytes)

manifestPublicKeyDigest :: ManifestPublicKey -> FrameDigest
manifestPublicKeyDigest = contentDigest . manifestPublicKeyBytes

manifestSigningPublicKey :: ManifestSigningKey -> ManifestPublicKey
manifestSigningPublicKey (ManifestSigningKey key) =
  ManifestPublicKey (ByteArray.convert (Ed25519.toPublic key))

newtype ManifestSignature = ManifestSignature StrictByteString.ByteString
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

manifestSignatureBytes :: ManifestSignature -> StrictByteString.ByteString
manifestSignatureBytes (ManifestSignature bytes) = bytes

data UnsignedCompleteManifest = UnsignedCompleteManifest
  { unsignedCompleteVersion :: !Word
  , unsignedCompletePlan :: !DecommissionManifest
  , unsignedCompleteVerifier :: !VerifierBinding
  , unsignedCompleteSigner :: !ManifestPublicKey
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The complete, authenticated teardown authority.  Its canonical signed bytes
-- bind the plan, exact exported runner path/build/dependencies, schema and
-- interpreter registry, plus the public signer identity.
data SignedDecommissionManifest = SignedDecommissionManifest
  { signedManifestUnsigned :: !UnsignedCompleteManifest
  , signedManifestSignature :: !ManifestSignature
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

currentSignedManifestVersion :: Word
currentSignedManifestVersion = 1

signDecommissionManifest
  :: ManifestSigningKey
  -> DecommissionManifest
  -> VerifierBinding
  -> SignedDecommissionManifest
signDecommissionManifest signingKey@(ManifestSigningKey privateKey) plan verifier =
  let public = Ed25519.toPublic privateKey
      publicKey = manifestSigningPublicKey signingKey
      unsigned =
        UnsignedCompleteManifest
          { unsignedCompleteVersion = currentSignedManifestVersion
          , unsignedCompletePlan = plan
          , unsignedCompleteVerifier = verifier
          , unsignedCompleteSigner = publicKey
          }
      signature = Ed25519.sign privateKey public (canonicalUnsignedBytes unsigned)
   in SignedDecommissionManifest
        { signedManifestUnsigned = unsigned
        , signedManifestSignature = ManifestSignature (ByteArray.convert signature)
        }

-- | Canonical bytes an external Authority signer must sign.  Keeping this
-- function beside 'signDecommissionManifest' guarantees the in-process test
-- signer and the production non-exportable signer use exactly one framing.
manifestSigningPayload
  :: DecommissionManifest
  -> VerifierBinding
  -> ManifestPublicKey
  -> StrictByteString.ByteString
manifestSigningPayload plan verifier publicKey =
  canonicalUnsignedBytes
    UnsignedCompleteManifest
      { unsignedCompleteVersion = currentSignedManifestVersion
      , unsignedCompletePlan = plan
      , unsignedCompleteVerifier = verifier
      , unsignedCompleteSigner = publicKey
      }

-- | Authenticate a signature returned by a non-exportable Authority signing
-- service.  Success returns the same opaque verified value used by every
-- retained commit, receipt, and runner gate; malformed key/signature bytes or a
-- signature over any other plan/binding are refused here.
verifyExternallySignedDecommissionManifest
  :: DecommissionManifest
  -> VerifierBinding
  -> ManifestPublicKey
  -> StrictByteString.ByteString
  -> Either SignedManifestVerificationError VerifiedDecommissionManifest
verifyExternallySignedDecommissionManifest plan verifier publicKey signatureBytes =
  verifySignedDecommissionManifest
    (manifestPublicKeyDigest publicKey)
    SignedDecommissionManifest
      { signedManifestUnsigned =
          UnsignedCompleteManifest
            { unsignedCompleteVersion = currentSignedManifestVersion
            , unsignedCompletePlan = plan
            , unsignedCompleteVerifier = verifier
            , unsignedCompleteSigner = publicKey
            }
      , signedManifestSignature = ManifestSignature signatureBytes
      }

signedManifestPlan :: SignedDecommissionManifest -> DecommissionManifest
signedManifestPlan = unsignedCompletePlan . signedManifestUnsigned

signedManifestVerifierBinding :: SignedDecommissionManifest -> VerifierBinding
signedManifestVerifierBinding = unsignedCompleteVerifier . signedManifestUnsigned

signedManifestPublicKey :: SignedDecommissionManifest -> ManifestPublicKey
signedManifestPublicKey = unsignedCompleteSigner . signedManifestUnsigned

signedDecommissionManifestDigest :: SignedDecommissionManifest -> FrameDigest
signedDecommissionManifestDigest =
  contentDigest . LazyByteString.toStrict . serialise

signedManifestSignatureDigest :: SignedDecommissionManifest -> FrameDigest
signedManifestSignatureDigest = contentDigest . manifestSignatureBytes . signedManifestSignature

data SignedManifestVerificationError
  = SignedManifestUnsupportedVersion
  | SignedManifestPlanInvalid !ManifestError
  | SignedManifestVerifierBindingInvalid !VerifierBindingError
  | SignedManifestPublicKeyInvalid
  | SignedManifestSignatureInvalid
  | SignedManifestSignerDigestMismatch
  | SignedManifestAuthenticationFailed
  deriving stock (Eq, Show)

newtype VerifiedDecommissionManifest = VerifiedDecommissionManifest SignedDecommissionManifest
  deriving stock (Eq, Show)

verifySignedDecommissionManifest
  :: FrameDigest
  -> SignedDecommissionManifest
  -> Either SignedManifestVerificationError VerifiedDecommissionManifest
verifySignedDecommissionManifest expectedSignerDigest signed = do
  let unsigned = signedManifestUnsigned signed
      plan = unsignedCompletePlan unsigned
  if unsignedCompleteVersion unsigned == currentSignedManifestVersion
    then pure ()
    else Left SignedManifestUnsupportedVersion
  validatedPlan <-
    either
      (Left . SignedManifestPlanInvalid)
      Right
      (mkDecommissionManifest (manifestClusterId plan) (manifestNodes plan))
  if validatedPlan == plan
    then pure ()
    else Left SignedManifestAuthenticationFailed
  _ <-
    either
      (Left . SignedManifestVerifierBindingInvalid)
      Right
      (validateVerifierBinding (unsignedCompleteVerifier unsigned))
  public <- parsePublicKey (unsignedCompleteSigner unsigned)
  signature <- parseSignature (signedManifestSignature signed)
  if manifestPublicKeyDigest (unsignedCompleteSigner unsigned) == expectedSignerDigest
    then pure ()
    else Left SignedManifestSignerDigestMismatch
  if Ed25519.verify public (canonicalUnsignedBytes unsigned) signature
    then Right (VerifiedDecommissionManifest signed)
    else Left SignedManifestAuthenticationFailed

verifiedSignedManifest :: VerifiedDecommissionManifest -> SignedDecommissionManifest
verifiedSignedManifest (VerifiedDecommissionManifest signed) = signed

verifiedManifestPlan :: VerifiedDecommissionManifest -> DecommissionManifest
verifiedManifestPlan = signedManifestPlan . verifiedSignedManifest

verifiedVerifierBinding :: VerifiedDecommissionManifest -> VerifierBinding
verifiedVerifierBinding = signedManifestVerifierBinding . verifiedSignedManifest

verifiedManifestDigest :: VerifiedDecommissionManifest -> FrameDigest
verifiedManifestDigest = signedDecommissionManifestDigest . verifiedSignedManifest

data SignedManifestCodecError
  = SignedManifestEnvelopeTooLarge
  | SignedManifestEnvelopeInvalid
  | SignedManifestEnvelopeNonCanonical
  | SignedManifestEnvelopeVerificationFailed !SignedManifestVerificationError
  deriving stock (Eq, Show)

encodeSignedDecommissionManifest :: SignedDecommissionManifest -> ByteString
encodeSignedDecommissionManifest = serialise

decodeSignedDecommissionManifest
  :: Int
  -> FrameDigest
  -> ByteString
  -> Either SignedManifestCodecError SignedDecommissionManifest
decodeSignedDecommissionManifest maximumBytes expectedSigner bytes
  | maximumBytes < 0 = Left SignedManifestEnvelopeTooLarge
  | LazyByteString.length bytes > fromIntegral maximumBytes = Left SignedManifestEnvelopeTooLarge
  | otherwise = case deserialiseOrFail bytes of
      Left _ -> Left SignedManifestEnvelopeInvalid
      Right signed
        | serialise signed /= bytes -> Left SignedManifestEnvelopeNonCanonical
        | otherwise ->
            case verifySignedDecommissionManifest expectedSigner signed of
              Left err -> Left (SignedManifestEnvelopeVerificationFailed err)
              Right verified -> Right (verifiedSignedManifest verified)

canonicalUnsignedBytes :: UnsignedCompleteManifest -> StrictByteString.ByteString
canonicalUnsignedBytes = LazyByteString.toStrict . serialise

parsePublicKey
  :: ManifestPublicKey
  -> Either SignedManifestVerificationError Ed25519.PublicKey
parsePublicKey (ManifestPublicKey bytes) = case Ed25519.publicKey bytes of
  CryptoFailed _ -> Left SignedManifestPublicKeyInvalid
  CryptoPassed key -> Right key

parseSignature
  :: ManifestSignature
  -> Either SignedManifestVerificationError Ed25519.Signature
parseSignature (ManifestSignature bytes) = case Ed25519.signature bytes of
  CryptoFailed _ -> Left SignedManifestSignatureInvalid
  CryptoPassed signature -> Right signature
