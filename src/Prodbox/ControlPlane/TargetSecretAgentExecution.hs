{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Signed, two-stage Target Secret Agent execution.
--
-- This is the production Agent boundary.  It has no Model-B adapter, Authority
-- checkpoint, lease repository, or global-CAS capability.  Stage one decodes a
-- bounded canonical secret-free envelope, authenticates its Ed25519 signature
-- against the Agent-local 'AcceptedTargetAuthority', and checks the current
-- epoch, fence floor, exact target binding, action digest, and deadline.  Stage
-- two re-reads that trusted record, re-checks time, and resolves plaintext only
-- through the exact signed receipt in an Agent-local trusted material source.
-- It then performs at most one exact local Vault CAS followed by mandatory
-- read-back.
--
-- The digest stored with the target record is the signed action digest, which
-- includes the operation/action/receipt/idempotency identity as well as the
-- target generation.  A same-generation request with a different operation
-- identity is therefore a collision, not an idempotent success.
-- Applied-but-response-lost mutations converge through observation; replay of
-- the exact intent performs no second mutation.
module Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetIntentSigningKey
  , TargetIntentSigningKeyError (..)
  , mkTargetIntentSigningKey
  , TargetIntentPublicKey
  , mkTargetIntentPublicKey
  , targetIntentPublicKeyBytes
  , targetIntentSigningPublicKey
  , TargetIssuerKeyGeneration
  , mkTargetIssuerKeyGeneration
  , targetIssuerKeyGenerationValue
  , TargetAgentIdentity
  , mkTargetAgentIdentity
  , mkTargetAgentRolloutIdentity
  , targetAgentIdentityText
  , targetAgentClusterIdentity
  , targetAgentRolloutDigest
  , TargetAgentRolloutObservationCause (..)
  , allTargetAgentRolloutObservationCauses
  , renderTargetAgentRolloutObservationCause
  , TargetAgentRolloutEvidence
  , mkTargetAgentRolloutEvidence
  , targetAgentRolloutEvidenceIdentity
  , targetAgentRolloutDeploymentUid
  , targetAgentRolloutDeploymentGeneration
  , targetAgentRolloutObservedGeneration
  , targetAgentRolloutObservedDigest
  , AcceptedTargetAuthority
  , AcceptedTargetAuthorityError (..)
  , mkAcceptedTargetAuthority
  , acceptedTargetIssuerGeneration
  , acceptedTargetIssuerIdentity
  , acceptedTargetIssuerPublicKey
  , acceptedTargetAuthorityEpoch
  , acceptedTargetFenceFloor
  , acceptedTargetAgentIdentity
  , acceptedTargetId
  , AcceptedTargetAuthorityCodecError (..)
  , acceptedTargetAuthorityMaximumEncodedBytes
  , encodeAcceptedTargetAuthority
  , decodeAcceptedTargetAuthority
  , TargetCommittedIntentSpec (..)
  , TargetCommittedIntentValueError (..)
  , targetCommitActionDigest
  , UnsignedTargetCommittedIntent
  , mkUnsignedTargetCommittedIntent
  , targetCommittedIntentSigningPayload
  , SignedTargetCommittedIntent
  , signedTargetCommittedIntentSpec
  , signedTargetCommittedIntentTarget
  , signedTargetCommittedIntentActionDigest
  , signTargetCommittedIntent
  , attachTargetCommittedIntentSignature
  , TargetCommittedIntentCodecError (..)
  , targetCommittedIntentMaximumEncodedBytes
  , encodeSignedTargetCommittedIntent
  , decodeSignedTargetCommittedIntent
  , VerifiedTargetCommittedIntent
  , verifiedTargetIntentSpec
  , verifiedTargetIntentTarget
  , verifiedTargetIntentActionDigest
  , TargetIntentVerificationError (..)
  , verifySignedTargetCommittedIntent
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.Bifunctor (first)
import Data.ByteArray qualified as ByteArray
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isControl, isDigit, isHexDigit, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId
  , compiledTargetSecretSink
  , targetSecretIdForSink
  , targetSecretIdToken
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( TargetClusterSecretSink
  , targetSecretSinkIdentity
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , FencingToken
  , OwnerNonce
  , authorityTimeFromMicros
  , authorityTimeMicros
  , fencingTokenValue
  , mkFencingToken
  , mkOwnerNonce
  , ownerNonceText
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

newtype TargetIntentSigningKey = TargetIntentSigningKey Ed25519.SecretKey

data TargetIntentSigningKeyError
  = TargetIntentSigningKeyInvalid
  deriving stock (Eq, Show)

mkTargetIntentSigningKey
  :: ByteString
  -> Either TargetIntentSigningKeyError TargetIntentSigningKey
mkTargetIntentSigningKey bytes = case Ed25519.secretKey bytes of
  CryptoFailed _ -> Left TargetIntentSigningKeyInvalid
  CryptoPassed key -> Right (TargetIntentSigningKey key)

newtype TargetIntentPublicKey = TargetIntentPublicKey ByteString
  deriving stock (Eq, Show)

mkTargetIntentPublicKey
  :: ByteString
  -> Either TargetIntentSigningKeyError TargetIntentPublicKey
mkTargetIntentPublicKey bytes = case Ed25519.publicKey bytes of
  CryptoFailed _ -> Left TargetIntentSigningKeyInvalid
  CryptoPassed _ -> Right (TargetIntentPublicKey bytes)

targetIntentPublicKeyBytes :: TargetIntentPublicKey -> ByteString
targetIntentPublicKeyBytes (TargetIntentPublicKey bytes) = bytes

targetIntentSigningPublicKey :: TargetIntentSigningKey -> TargetIntentPublicKey
targetIntentSigningPublicKey (TargetIntentSigningKey privateKey) =
  TargetIntentPublicKey (ByteArray.convert (Ed25519.toPublic privateKey))

newtype TargetIssuerKeyGeneration = TargetIssuerKeyGeneration Natural
  deriving stock (Eq, Ord, Show)

mkTargetIssuerKeyGeneration
  :: Natural
  -> Either TargetCommittedIntentValueError TargetIssuerKeyGeneration
mkTargetIssuerKeyGeneration value
  | value == 0 = Left TargetIntentIssuerKeyGenerationMustBePositive
  | otherwise = Right (TargetIssuerKeyGeneration value)

targetIssuerKeyGenerationValue :: TargetIssuerKeyGeneration -> Natural
targetIssuerKeyGenerationValue (TargetIssuerKeyGeneration value) = value

newtype TargetAgentIdentity = TargetAgentIdentity Text
  deriving stock (Eq, Ord, Show)

mkTargetAgentIdentity :: Text -> Either Text TargetAgentIdentity
mkTargetAgentIdentity raw = do
  let value = Text.strip raw
      (clusterWithSeparator, digest) = Text.breakOnEnd "@" value
      cluster = Text.dropEnd 1 clusterWithSeparator
  if validClusterIdentity cluster && validSha256Digest digest
    then Right (TargetAgentIdentity (cluster <> "@" <> digest))
    else Left "selected Target Agent identity must bind an exact cluster and sha256 rollout"

mkTargetAgentRolloutIdentity
  :: Text -> Text -> Either Text TargetAgentIdentity
mkTargetAgentRolloutIdentity cluster rolloutDigest =
  mkTargetAgentIdentity (Text.strip cluster <> "@" <> Text.strip rolloutDigest)

targetAgentIdentityText :: TargetAgentIdentity -> Text
targetAgentIdentityText (TargetAgentIdentity value) = value

targetAgentClusterIdentity :: TargetAgentIdentity -> Text
targetAgentClusterIdentity (TargetAgentIdentity value) =
  Text.dropEnd 1 (fst (Text.breakOnEnd "@" value))

targetAgentRolloutDigest :: TargetAgentIdentity -> Text
targetAgentRolloutDigest (TargetAgentIdentity value) = snd (Text.breakOnEnd "@" value)

-- | Closed, value-free reasons why the selected Target Agent rollout could
-- not be observed. Kubernetes response bodies, annotation values, and
-- subprocess detail never cross the recovery diagnostic boundary.
data TargetAgentRolloutObservationCause
  = TargetAgentRolloutSubprocessUnavailable
  | TargetAgentRolloutKubeconfigUnavailable
  | TargetAgentRolloutAuthorizationRefused
  | TargetAgentRolloutDeploymentAbsent
  | TargetAgentRolloutKubernetesExitOther
  | TargetAgentRolloutResponseInvalid
  | TargetAgentRolloutDeploymentNameInvalid
  | TargetAgentRolloutDeploymentIdentityAbsent
  | TargetAgentRolloutPodTemplateIdentityAbsent
  | TargetAgentRolloutIdentityInconsistent
  | TargetAgentRolloutDeploymentDigestAbsent
  | TargetAgentRolloutPodTemplateDigestAbsent
  | TargetAgentRolloutDigestInconsistent
  | TargetAgentRolloutIdentityInvalid
  | TargetAgentRolloutDeploymentUidInvalid
  | TargetAgentRolloutGenerationNotFullyObserved
  | TargetAgentRolloutRegisteredDigestMismatch
  | TargetAgentRolloutObservationOther
  deriving stock (Bounded, Enum, Eq, Show)

allTargetAgentRolloutObservationCauses :: [TargetAgentRolloutObservationCause]
allTargetAgentRolloutObservationCauses = [minBound .. maxBound]

renderTargetAgentRolloutObservationCause :: TargetAgentRolloutObservationCause -> Text
renderTargetAgentRolloutObservationCause cause = case cause of
  TargetAgentRolloutSubprocessUnavailable -> "subprocess-unavailable"
  TargetAgentRolloutKubeconfigUnavailable -> "kubeconfig-unavailable"
  TargetAgentRolloutAuthorizationRefused -> "authorization-refused"
  TargetAgentRolloutDeploymentAbsent -> "deployment-absent"
  TargetAgentRolloutKubernetesExitOther -> "kubernetes-exit-other"
  TargetAgentRolloutResponseInvalid -> "response-invalid"
  TargetAgentRolloutDeploymentNameInvalid -> "deployment-name-invalid"
  TargetAgentRolloutDeploymentIdentityAbsent -> "deployment-identity-absent"
  TargetAgentRolloutPodTemplateIdentityAbsent -> "pod-template-identity-absent"
  TargetAgentRolloutIdentityInconsistent -> "identity-inconsistent"
  TargetAgentRolloutDeploymentDigestAbsent -> "deployment-digest-absent"
  TargetAgentRolloutPodTemplateDigestAbsent -> "pod-template-digest-absent"
  TargetAgentRolloutDigestInconsistent -> "digest-inconsistent"
  TargetAgentRolloutIdentityInvalid -> "identity-invalid"
  TargetAgentRolloutDeploymentUidInvalid -> "deployment-uid-invalid"
  TargetAgentRolloutGenerationNotFullyObserved -> "generation-not-fully-observed"
  TargetAgentRolloutRegisteredDigestMismatch -> "registered-digest-mismatch"
  TargetAgentRolloutObservationOther -> "other"

-- | Exact observed Deployment incarnation. The rollout digest is already part
-- of the registered identity; API-assigned UID and observed generation prevent
-- a same-cluster replacement from borrowing an earlier execution permit.
data TargetAgentRolloutEvidence = TargetAgentRolloutEvidence
  { internalTargetAgentRolloutEvidenceIdentity :: !TargetAgentIdentity
  , internalTargetAgentRolloutDeploymentUid :: !Text
  , internalTargetAgentRolloutDeploymentGeneration :: !Natural
  , internalTargetAgentRolloutObservedGeneration :: !Natural
  , internalTargetAgentRolloutObservedDigest :: !Text
  }
  deriving stock (Eq, Show)

mkTargetAgentRolloutEvidence
  :: TargetAgentIdentity
  -> Text
  -> Natural
  -> Natural
  -> Text
  -> Either Text TargetAgentRolloutEvidence
mkTargetAgentRolloutEvidence identity rawUid generation observedGeneration observedRollout
  | not (validKubernetesUid uid) = Left "Target Agent Deployment UID is invalid"
  | generation == 0 || observedGeneration /= generation =
      Left "Target Agent Deployment generation is not fully observed"
  | Text.strip observedRollout /= targetAgentRolloutDigest identity =
      Left "Target Agent Deployment rollout digest does not match its registered identity"
  | otherwise =
      Right
        TargetAgentRolloutEvidence
          { internalTargetAgentRolloutEvidenceIdentity = identity
          , internalTargetAgentRolloutDeploymentUid = uid
          , internalTargetAgentRolloutDeploymentGeneration = generation
          , internalTargetAgentRolloutObservedGeneration = observedGeneration
          , internalTargetAgentRolloutObservedDigest = Text.strip observedRollout
          }
 where
  uid = Text.strip rawUid

targetAgentRolloutEvidenceIdentity
  :: TargetAgentRolloutEvidence -> TargetAgentIdentity
targetAgentRolloutEvidenceIdentity = internalTargetAgentRolloutEvidenceIdentity

targetAgentRolloutDeploymentUid :: TargetAgentRolloutEvidence -> Text
targetAgentRolloutDeploymentUid = internalTargetAgentRolloutDeploymentUid

targetAgentRolloutDeploymentGeneration
  :: TargetAgentRolloutEvidence -> Natural
targetAgentRolloutDeploymentGeneration = internalTargetAgentRolloutDeploymentGeneration

targetAgentRolloutObservedGeneration :: TargetAgentRolloutEvidence -> Natural
targetAgentRolloutObservedGeneration = internalTargetAgentRolloutObservedGeneration

targetAgentRolloutObservedDigest :: TargetAgentRolloutEvidence -> Text
targetAgentRolloutObservedDigest = internalTargetAgentRolloutObservedDigest

-- | Agent-local trust state.  It is separately persisted by the Agent and is
-- read-only to ordinary target execution.  In particular, this value contains
-- no Authority object coordinate or global store handle.
data AcceptedTargetAuthority = AcceptedTargetAuthority
  { acceptedTargetIssuerGeneration :: !TargetIssuerKeyGeneration
  , acceptedTargetIssuerIdentity :: !Text
  , acceptedTargetIssuerPublicKey :: !TargetIntentPublicKey
  , acceptedTargetAuthorityEpoch :: !AuthorityEpoch
  , acceptedTargetFenceFloor :: !FencingToken
  , acceptedTargetAgentIdentity :: !TargetAgentIdentity
  , acceptedTargetId :: !TargetSecretId
  }
  deriving stock (Eq, Show)

data AcceptedTargetAuthorityError
  = AcceptedTargetAuthorityIssuerIdentityInvalid
  | AcceptedTargetAuthorityEpochMustBePositive
  | AcceptedTargetAuthorityIdentityInvalid
  | AcceptedTargetAuthorityTargetUnregistered
  deriving stock (Eq, Show)

mkAcceptedTargetAuthority
  :: TargetIssuerKeyGeneration
  -> Text
  -> TargetIntentPublicKey
  -> AuthorityEpoch
  -> FencingToken
  -> TargetAgentIdentity
  -> TargetClusterSecretSink
  -> Either AcceptedTargetAuthorityError AcceptedTargetAuthority
mkAcceptedTargetAuthority issuerGeneration issuerIdentity publicKey epoch fenceFloor agentIdentity sink = do
  validateAcceptedIssuerIdentity issuerIdentity
  validateAcceptedEpoch epoch
  validateAcceptedIdentity (targetSecretSinkIdentity sink)
  target <- maybe (Left AcceptedTargetAuthorityTargetUnregistered) Right (targetSecretIdForSink sink)
  pure
    AcceptedTargetAuthority
      { acceptedTargetIssuerGeneration = issuerGeneration
      , acceptedTargetIssuerIdentity = issuerIdentity
      , acceptedTargetIssuerPublicKey = publicKey
      , acceptedTargetAuthorityEpoch = epoch
      , acceptedTargetFenceFloor = fenceFloor
      , acceptedTargetAgentIdentity = agentIdentity
      , acceptedTargetId = target
      }

data WireAcceptedTargetAuthority = WireAcceptedTargetAuthority
  { wireAcceptedVersion :: !Word16
  , wireAcceptedIssuerGeneration :: !Natural
  , wireAcceptedIssuerIdentity :: !Text
  , wireAcceptedPublicKey :: !ByteString
  , wireAcceptedEpoch :: !Natural
  , wireAcceptedFenceFloor :: !Natural
  , wireAcceptedAgentIdentity :: !Text
  , wireAcceptedTarget :: !TargetSecretId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AcceptedTargetAuthorityCodecError
  = AcceptedTargetAuthorityTooLarge !Int !Int
  | AcceptedTargetAuthorityInvalid
  | AcceptedTargetAuthorityUnsupportedVersion !Word16
  | AcceptedTargetAuthorityNonCanonical
  | AcceptedTargetAuthorityValueInvalid !Text
  deriving stock (Eq, Show)

acceptedTargetAuthorityMaximumEncodedBytes :: Int
acceptedTargetAuthorityMaximumEncodedBytes = 8 * 1024

acceptedTargetAuthorityCodecVersion :: Word16
acceptedTargetAuthorityCodecVersion = 3

encodeAcceptedTargetAuthority :: AcceptedTargetAuthority -> ByteString
encodeAcceptedTargetAuthority =
  LazyByteString.toStrict . serialise . wireAcceptedTargetAuthority

decodeAcceptedTargetAuthority
  :: Int
  -> ByteString
  -> Either AcceptedTargetAuthorityCodecError AcceptedTargetAuthority
decodeAcceptedTargetAuthority maximumBytes bytes
  | maximumBytes < 0 || ByteString.length bytes > effectiveMaximum =
      Left (AcceptedTargetAuthorityTooLarge (ByteString.length bytes) effectiveMaximum)
  | otherwise = do
      wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left AcceptedTargetAuthorityInvalid
        Right decoded -> Right decoded
      if wireAcceptedVersion wire == acceptedTargetAuthorityCodecVersion
        then Right ()
        else Left (AcceptedTargetAuthorityUnsupportedVersion (wireAcceptedVersion wire))
      accepted <- acceptedTargetAuthorityFromWire wire
      if encodeAcceptedTargetAuthority accepted == bytes
        then Right accepted
        else Left AcceptedTargetAuthorityNonCanonical
 where
  effectiveMaximum = min maximumBytes acceptedTargetAuthorityMaximumEncodedBytes

wireAcceptedTargetAuthority :: AcceptedTargetAuthority -> WireAcceptedTargetAuthority
wireAcceptedTargetAuthority accepted =
  WireAcceptedTargetAuthority
    { wireAcceptedVersion = acceptedTargetAuthorityCodecVersion
    , wireAcceptedIssuerGeneration =
        targetIssuerKeyGenerationValue (acceptedTargetIssuerGeneration accepted)
    , wireAcceptedIssuerIdentity = acceptedTargetIssuerIdentity accepted
    , wireAcceptedPublicKey =
        targetIntentPublicKeyBytes (acceptedTargetIssuerPublicKey accepted)
    , wireAcceptedEpoch = authorityEpochValue (acceptedTargetAuthorityEpoch accepted)
    , wireAcceptedFenceFloor = fencingTokenValue (acceptedTargetFenceFloor accepted)
    , wireAcceptedAgentIdentity =
        targetAgentIdentityText (acceptedTargetAgentIdentity accepted)
    , wireAcceptedTarget = acceptedTargetId accepted
    }

acceptedTargetAuthorityFromWire
  :: WireAcceptedTargetAuthority
  -> Either AcceptedTargetAuthorityCodecError AcceptedTargetAuthority
acceptedTargetAuthorityFromWire wire = do
  issuer <-
    mapAcceptedValue
      (mkTargetIssuerKeyGeneration (wireAcceptedIssuerGeneration wire))
  mapAcceptedError
    (validateAcceptedIssuerIdentity (wireAcceptedIssuerIdentity wire))
  public <-
    mapAcceptedSigning
      (mkTargetIntentPublicKey (wireAcceptedPublicKey wire))
  let epoch = AuthorityEpoch (wireAcceptedEpoch wire)
  mapAcceptedError (validateAcceptedEpoch epoch)
  fence <-
    mapAcceptedLease
      (mkFencingToken (wireAcceptedFenceFloor wire))
  agentIdentity <-
    mapAcceptedText
      (mkTargetAgentIdentity (wireAcceptedAgentIdentity wire))
  pure
    AcceptedTargetAuthority
      { acceptedTargetIssuerGeneration = issuer
      , acceptedTargetIssuerIdentity = wireAcceptedIssuerIdentity wire
      , acceptedTargetIssuerPublicKey = public
      , acceptedTargetAuthorityEpoch = epoch
      , acceptedTargetFenceFloor = fence
      , acceptedTargetAgentIdentity = agentIdentity
      , acceptedTargetId = wireAcceptedTarget wire
      }

data TargetCommittedIntentSpec = TargetCommittedIntentSpec
  { targetIntentIssuerGeneration :: !TargetIssuerKeyGeneration
  , targetIntentIssuerIdentity :: !Text
  , targetIntentAuthorityEpoch :: !AuthorityEpoch
  , targetIntentOperationId :: !Text
  , targetIntentActionIndex :: !Natural
  , targetIntentCommitReceiptDigest :: !TargetValueDigest
  , targetIntentOwnerNonce :: !OwnerNonce
  , targetIntentFencingToken :: !FencingToken
  , targetIntentAgentIdentity :: !TargetAgentIdentity
  , targetIntentSink :: !TargetClusterSecretSink
  , targetIntentGeneration :: !CredentialGeneration
  , targetIntentDeadline :: !AuthorityTime
  , targetIntentIdempotencyKey :: !Text
  }
  deriving stock (Eq, Show)

data TargetCommittedIntentValueError
  = TargetIntentIssuerKeyGenerationMustBePositive
  | TargetIntentIssuerIdentityInvalid
  | TargetIntentAuthorityEpochMustBePositive
  | TargetIntentOperationIdInvalid
  | TargetIntentActionIndexOverBound !Natural !Natural
  | TargetIntentIdempotencyKeyInvalid
  | TargetIntentTargetUnregistered
  deriving stock (Eq, Show)

data UnsignedTargetCommittedIntent = UnsignedTargetCommittedIntent
  { internalTargetCommittedIntentSpec :: !TargetCommittedIntentSpec
  , internalTargetCommittedTarget :: !TargetSecretId
  , internalTargetCommittedActionDigest :: !TargetValueDigest
  }
  deriving stock (Eq, Show)

mkUnsignedTargetCommittedIntent
  :: TargetCommittedIntentSpec
  -> Either TargetCommittedIntentValueError UnsignedTargetCommittedIntent
mkUnsignedTargetCommittedIntent spec = do
  validateTargetCommittedIntentSpec spec
  target <-
    maybe
      (Left TargetIntentTargetUnregistered)
      Right
      (targetSecretIdForSink (targetIntentSink spec))
  actionDigest <- targetCommitActionDigest spec
  pure
    UnsignedTargetCommittedIntent
      { internalTargetCommittedIntentSpec = spec
      , internalTargetCommittedTarget = target
      , internalTargetCommittedActionDigest = actionDigest
      }

targetCommitActionDigest
  :: TargetCommittedIntentSpec
  -> Either TargetCommittedIntentValueError TargetValueDigest
targetCommitActionDigest spec = do
  validateTargetCommittedIntentSpec spec
  target <-
    maybe
      (Left TargetIntentTargetUnregistered)
      Right
      (targetSecretIdForSink (targetIntentSink spec))
  pure
    ( sha256TargetValueDigest
        ( LazyByteString.toStrict
            (serialise (wireTargetActionBinding target spec))
        )
    )

data WireTargetActionBinding = WireTargetActionBinding
  { wireActionDomainVersion :: !Word16
  , wireActionOperationId :: !Text
  , wireActionIndex :: !Natural
  , wireActionCommitReceiptDigest :: !Text
  , wireActionTarget :: !TargetSecretId
  , wireActionAgentIdentity :: !Text
  , wireActionGeneration :: !Natural
  , wireActionIdempotencyKey :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

wireTargetActionBinding :: TargetSecretId -> TargetCommittedIntentSpec -> WireTargetActionBinding
wireTargetActionBinding target spec =
  WireTargetActionBinding
    { wireActionDomainVersion = targetCommittedIntentCodecVersion
    , wireActionOperationId = targetIntentOperationId spec
    , wireActionIndex = targetIntentActionIndex spec
    , wireActionCommitReceiptDigest =
        targetValueDigestText (targetIntentCommitReceiptDigest spec)
    , wireActionTarget = target
    , wireActionAgentIdentity =
        targetAgentIdentityText (targetIntentAgentIdentity spec)
    , wireActionGeneration =
        credentialGenerationValue (targetIntentGeneration spec)
    , wireActionIdempotencyKey = targetIntentIdempotencyKey spec
    }

validateTargetCommittedIntentSpec
  :: TargetCommittedIntentSpec
  -> Either TargetCommittedIntentValueError ()
validateTargetCommittedIntentSpec spec = do
  case targetIntentIssuerGeneration spec of
    TargetIssuerKeyGeneration 0 -> Left TargetIntentIssuerKeyGenerationMustBePositive
    TargetIssuerKeyGeneration _ -> Right ()
  if validBoundedIdentifier (targetIntentIssuerIdentity spec)
    then Right ()
    else Left TargetIntentIssuerIdentityInvalid
  case targetIntentAuthorityEpoch spec of
    AuthorityEpoch 0 -> Left TargetIntentAuthorityEpochMustBePositive
    AuthorityEpoch _ -> Right ()
  if validBoundedIdentifier (targetIntentOperationId spec)
    then Right ()
    else Left TargetIntentOperationIdInvalid
  if targetIntentActionIndex spec <= maximumTargetActionIndex
    then Right ()
    else
      Left
        ( TargetIntentActionIndexOverBound
            (targetIntentActionIndex spec)
            maximumTargetActionIndex
        )
  if validBoundedIdentifier (targetIntentIdempotencyKey spec)
    then Right ()
    else Left TargetIntentIdempotencyKeyInvalid

maximumTargetActionIndex :: Natural
maximumTargetActionIndex = 65535

data WireUnsignedTargetCommittedIntent = WireUnsignedTargetCommittedIntent
  { wireTargetIntentVersion :: !Word16
  , wireTargetIssuerGeneration :: !Natural
  , wireTargetIssuerIdentity :: !Text
  , wireTargetAuthorityEpoch :: !Natural
  , wireTargetOperationId :: !Text
  , wireTargetActionIndex :: !Natural
  , wireTargetCommitReceiptDigest :: !Text
  , wireTargetOwnerNonce :: !Text
  , wireTargetFencingToken :: !Natural
  , wireTargetAgentIdentity :: !Text
  , wireTarget :: !TargetSecretId
  , wireTargetGeneration :: !Natural
  , wireTargetActionDigest :: !Text
  , wireTargetDeadlineMicros :: !Natural
  , wireTargetIdempotencyKey :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireSignedTargetCommittedIntent = WireSignedTargetCommittedIntent
  { wireSignedTargetUnsigned :: !WireUnsignedTargetCommittedIntent
  , wireSignedTargetSignature :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data SignedTargetCommittedIntent = SignedTargetCommittedIntent
  { internalSignedTargetUnsigned :: !UnsignedTargetCommittedIntent
  , internalSignedTargetSignature :: !ByteString
  }
  deriving stock (Eq, Show)

-- | Secret-free projections used when the Authority revalidates an initial
-- intent before issuing a post-observation execution permit.  Construction of
-- the signed value remains codec- and signature-gated at the call site.
signedTargetCommittedIntentSpec
  :: SignedTargetCommittedIntent -> TargetCommittedIntentSpec
signedTargetCommittedIntentSpec =
  internalTargetCommittedIntentSpec . internalSignedTargetUnsigned

signedTargetCommittedIntentTarget
  :: SignedTargetCommittedIntent -> TargetSecretId
signedTargetCommittedIntentTarget =
  internalTargetCommittedTarget . internalSignedTargetUnsigned

signedTargetCommittedIntentActionDigest
  :: SignedTargetCommittedIntent -> TargetValueDigest
signedTargetCommittedIntentActionDigest =
  internalTargetCommittedActionDigest . internalSignedTargetUnsigned

signTargetCommittedIntent
  :: TargetIntentSigningKey
  -> UnsignedTargetCommittedIntent
  -> SignedTargetCommittedIntent
signTargetCommittedIntent (TargetIntentSigningKey privateKey) unsigned =
  let publicKey = Ed25519.toPublic privateKey
      signature = Ed25519.sign privateKey publicKey (canonicalUnsignedIntentBytes unsigned)
   in SignedTargetCommittedIntent
        { internalSignedTargetUnsigned = unsigned
        , internalSignedTargetSignature = ByteArray.convert signature
        }

-- | Canonical bytes signed by either an in-memory test key or the production
-- non-exportable Lifecycle Authority Transit key.  Exporting this projection
-- does not make a signed intent forgeable: 'UnsignedTargetCommittedIntent'
-- remains constructor-hidden and can be obtained only through the validated
-- smart constructor above.
targetCommittedIntentSigningPayload
  :: UnsignedTargetCommittedIntent -> ByteString
targetCommittedIntentSigningPayload = canonicalUnsignedIntentBytes

-- | Attach an externally produced Ed25519 signature.  Production uses this
-- after Vault Transit signs 'targetCommittedIntentSigningPayload'; tests may
-- continue to use 'signTargetCommittedIntent'.
attachTargetCommittedIntentSignature
  :: UnsignedTargetCommittedIntent
  -> ByteString
  -> Either TargetCommittedIntentCodecError SignedTargetCommittedIntent
attachTargetCommittedIntentSignature unsigned signature
  | ByteString.length signature /= 64 =
      Left (TargetCommittedIntentSignatureWidthInvalid (ByteString.length signature))
  | otherwise =
      Right
        SignedTargetCommittedIntent
          { internalSignedTargetUnsigned = unsigned
          , internalSignedTargetSignature = signature
          }

data TargetCommittedIntentCodecError
  = TargetCommittedIntentTooLarge !Int !Int
  | TargetCommittedIntentInvalid
  | TargetCommittedIntentUnsupportedVersion !Word16
  | TargetCommittedIntentSignatureWidthInvalid !Int
  | TargetCommittedIntentValueInvalid !Text
  | TargetCommittedIntentActionDigestInvalid
  | TargetCommittedIntentNonCanonical
  deriving stock (Eq, Show)

targetCommittedIntentMaximumEncodedBytes :: Int
targetCommittedIntentMaximumEncodedBytes = 64 * 1024

targetCommittedIntentCodecVersion :: Word16
targetCommittedIntentCodecVersion = 3

encodeSignedTargetCommittedIntent :: SignedTargetCommittedIntent -> ByteString
encodeSignedTargetCommittedIntent =
  LazyByteString.toStrict . serialise . wireSignedTargetCommittedIntent

decodeSignedTargetCommittedIntent
  :: Int
  -> ByteString
  -> Either TargetCommittedIntentCodecError SignedTargetCommittedIntent
decodeSignedTargetCommittedIntent maximumBytes bytes
  | maximumBytes < 0 || ByteString.length bytes > effectiveMaximum =
      Left (TargetCommittedIntentTooLarge (ByteString.length bytes) effectiveMaximum)
  | otherwise = do
      wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left TargetCommittedIntentInvalid
        Right decoded -> Right decoded
      let unsignedWire = wireSignedTargetUnsigned wire
      if wireTargetIntentVersion unsignedWire == targetCommittedIntentCodecVersion
        then Right ()
        else
          Left
            ( TargetCommittedIntentUnsupportedVersion
                (wireTargetIntentVersion unsignedWire)
            )
      if ByteString.length (wireSignedTargetSignature wire) == 64
        then Right ()
        else
          Left
            ( TargetCommittedIntentSignatureWidthInvalid
                (ByteString.length (wireSignedTargetSignature wire))
            )
      unsigned <- unsignedTargetIntentFromWire unsignedWire
      if targetValueDigestText (internalTargetCommittedActionDigest unsigned)
        == wireTargetActionDigest unsignedWire
        then Right ()
        else Left TargetCommittedIntentActionDigestInvalid
      let signed =
            SignedTargetCommittedIntent
              { internalSignedTargetUnsigned = unsigned
              , internalSignedTargetSignature = wireSignedTargetSignature wire
              }
      if encodeSignedTargetCommittedIntent signed == bytes
        then Right signed
        else Left TargetCommittedIntentNonCanonical
 where
  effectiveMaximum = min maximumBytes targetCommittedIntentMaximumEncodedBytes

wireSignedTargetCommittedIntent
  :: SignedTargetCommittedIntent
  -> WireSignedTargetCommittedIntent
wireSignedTargetCommittedIntent signed =
  WireSignedTargetCommittedIntent
    { wireSignedTargetUnsigned =
        wireUnsignedTargetCommittedIntent
          (internalSignedTargetUnsigned signed)
    , wireSignedTargetSignature = internalSignedTargetSignature signed
    }

wireUnsignedTargetCommittedIntent
  :: UnsignedTargetCommittedIntent
  -> WireUnsignedTargetCommittedIntent
wireUnsignedTargetCommittedIntent unsigned =
  let spec = internalTargetCommittedIntentSpec unsigned
   in WireUnsignedTargetCommittedIntent
        { wireTargetIntentVersion = targetCommittedIntentCodecVersion
        , wireTargetIssuerGeneration =
            targetIssuerKeyGenerationValue (targetIntentIssuerGeneration spec)
        , wireTargetIssuerIdentity = targetIntentIssuerIdentity spec
        , wireTargetAuthorityEpoch = authorityEpochValue (targetIntentAuthorityEpoch spec)
        , wireTargetOperationId = targetIntentOperationId spec
        , wireTargetActionIndex = targetIntentActionIndex spec
        , wireTargetCommitReceiptDigest =
            targetValueDigestText (targetIntentCommitReceiptDigest spec)
        , wireTargetOwnerNonce = ownerNonceText (targetIntentOwnerNonce spec)
        , wireTargetFencingToken = fencingTokenValue (targetIntentFencingToken spec)
        , wireTargetAgentIdentity =
            targetAgentIdentityText (targetIntentAgentIdentity spec)
        , wireTarget = internalTargetCommittedTarget unsigned
        , wireTargetGeneration = credentialGenerationValue (targetIntentGeneration spec)
        , wireTargetActionDigest =
            targetValueDigestText (internalTargetCommittedActionDigest unsigned)
        , wireTargetDeadlineMicros = authorityTimeMicros (targetIntentDeadline spec)
        , wireTargetIdempotencyKey = targetIntentIdempotencyKey spec
        }

unsignedTargetIntentFromWire
  :: WireUnsignedTargetCommittedIntent
  -> Either TargetCommittedIntentCodecError UnsignedTargetCommittedIntent
unsignedTargetIntentFromWire wire = do
  issuer <- mapIntentValue (mkTargetIssuerKeyGeneration (wireTargetIssuerGeneration wire))
  let epoch = AuthorityEpoch (wireTargetAuthorityEpoch wire)
  receipt <- mapIntentValue (mkTargetValueDigest (wireTargetCommitReceiptDigest wire))
  owner <- mapIntentLease (mkOwnerNonce (wireTargetOwnerNonce wire))
  fence <- mapIntentLease (mkFencingToken (wireTargetFencingToken wire))
  agentIdentity <-
    mapIntentText (mkTargetAgentIdentity (wireTargetAgentIdentity wire))
  sink <-
    first
      (TargetCommittedIntentValueInvalid . ("target:" <>))
      (compiledTargetSecretSink (wireTarget wire))
  generation <- mapIntentValue (mkCredentialGeneration (wireTargetGeneration wire))
  let spec =
        TargetCommittedIntentSpec
          { targetIntentIssuerGeneration = issuer
          , targetIntentIssuerIdentity = wireTargetIssuerIdentity wire
          , targetIntentAuthorityEpoch = epoch
          , targetIntentOperationId = wireTargetOperationId wire
          , targetIntentActionIndex = wireTargetActionIndex wire
          , targetIntentCommitReceiptDigest = receipt
          , targetIntentOwnerNonce = owner
          , targetIntentFencingToken = fence
          , targetIntentAgentIdentity = agentIdentity
          , targetIntentSink = sink
          , targetIntentGeneration = generation
          , targetIntentDeadline = authorityTimeFromMicros (wireTargetDeadlineMicros wire)
          , targetIntentIdempotencyKey = wireTargetIdempotencyKey wire
          }
  mapIntentValue (mkUnsignedTargetCommittedIntent spec)

canonicalUnsignedIntentBytes :: UnsignedTargetCommittedIntent -> ByteString
canonicalUnsignedIntentBytes =
  LazyByteString.toStrict . serialise . wireUnsignedTargetCommittedIntent

data VerifiedTargetCommittedIntent = VerifiedTargetCommittedIntent
  { internalVerifiedTargetUnsigned :: !UnsignedTargetCommittedIntent
  , internalVerifiedAcceptedAuthority :: !AcceptedTargetAuthority
  }

-- | Secret-free projections used by the attested one-shot worker.  The
-- verified value itself remains opaque so callers cannot construct one without
-- passing the signature/epoch/fence/deadline checks above.
verifiedTargetIntentSpec
  :: VerifiedTargetCommittedIntent -> TargetCommittedIntentSpec
verifiedTargetIntentSpec =
  internalTargetCommittedIntentSpec . internalVerifiedTargetUnsigned

verifiedTargetIntentTarget :: VerifiedTargetCommittedIntent -> TargetSecretId
verifiedTargetIntentTarget =
  internalTargetCommittedTarget . internalVerifiedTargetUnsigned

verifiedTargetIntentActionDigest
  :: VerifiedTargetCommittedIntent -> TargetValueDigest
verifiedTargetIntentActionDigest =
  internalTargetCommittedActionDigest . internalVerifiedTargetUnsigned

data TargetIntentVerificationError
  = TargetIntentPublicKeyInvalid
  | TargetIntentSignatureInvalid
  | TargetIntentAuthenticationFailed
  | TargetIntentIssuerGenerationMismatch
      !TargetIssuerKeyGeneration
      !TargetIssuerKeyGeneration
  | TargetIntentIssuerIdentityMismatch !Text !Text
  | TargetIntentAuthorityEpochMismatch !AuthorityEpoch !AuthorityEpoch
  | TargetIntentFenceBelowFloor !FencingToken !FencingToken
  | TargetIntentTargetIdentityMismatch !Text !Text
  | TargetIntentAgentIdentityMismatch !Text !Text
  | TargetIntentTargetBindingMismatch
  | TargetIntentActionDigestMismatch
  | TargetIntentDeadlineReached !AuthorityTime !AuthorityTime
  deriving stock (Eq, Show)

verifySignedTargetCommittedIntent
  :: AcceptedTargetAuthority
  -> AuthorityTime
  -> TargetAgentIdentity
  -> TargetClusterSecretSink
  -> SignedTargetCommittedIntent
  -> Either TargetIntentVerificationError VerifiedTargetCommittedIntent
verifySignedTargetCommittedIntent accepted now expectedAgentIdentity expectedSink signed = do
  public <- parseTargetIntentPublicKey (acceptedTargetIssuerPublicKey accepted)
  signature <- parseTargetIntentSignature (internalSignedTargetSignature signed)
  if Ed25519.verify
    public
    (canonicalUnsignedIntentBytes unsigned)
    signature
    then Right ()
    else Left TargetIntentAuthenticationFailed
  let spec = internalTargetCommittedIntentSpec unsigned
  if targetIntentIssuerGeneration spec == acceptedTargetIssuerGeneration accepted
    then Right ()
    else
      Left
        ( TargetIntentIssuerGenerationMismatch
            (acceptedTargetIssuerGeneration accepted)
            (targetIntentIssuerGeneration spec)
        )
  if targetIntentIssuerIdentity spec == acceptedTargetIssuerIdentity accepted
    then Right ()
    else
      Left
        ( TargetIntentIssuerIdentityMismatch
            (acceptedTargetIssuerIdentity accepted)
            (targetIntentIssuerIdentity spec)
        )
  if targetIntentAuthorityEpoch spec == acceptedTargetAuthorityEpoch accepted
    then Right ()
    else
      Left
        ( TargetIntentAuthorityEpochMismatch
            (acceptedTargetAuthorityEpoch accepted)
            (targetIntentAuthorityEpoch spec)
        )
  if targetIntentFencingToken spec >= acceptedTargetFenceFloor accepted
    then Right ()
    else
      Left
        ( TargetIntentFenceBelowFloor
            (acceptedTargetFenceFloor accepted)
            (targetIntentFencingToken spec)
        )
  if targetIntentAgentIdentity spec == acceptedTargetAgentIdentity accepted
    && expectedAgentIdentity == acceptedTargetAgentIdentity accepted
    then Right ()
    else
      Left
        ( TargetIntentAgentIdentityMismatch
            (targetAgentIdentityText expectedAgentIdentity)
            (targetAgentIdentityText (targetIntentAgentIdentity spec))
        )
  expectedTarget <-
    maybe
      (Left TargetIntentTargetBindingMismatch)
      Right
      (targetSecretIdForSink expectedSink)
  intentTarget <-
    maybe
      (Left TargetIntentTargetBindingMismatch)
      Right
      (targetSecretIdForSink (targetIntentSink spec))
  if expectedTarget == acceptedTargetId accepted
    && intentTarget == acceptedTargetId accepted
    then Right ()
    else
      Left
        ( TargetIntentTargetIdentityMismatch
            (targetSecretIdToken (acceptedTargetId accepted))
            (targetSecretIdToken intentTarget)
        )
  expectedAction <-
    either (const (Left TargetIntentActionDigestMismatch)) Right (targetCommitActionDigest spec)
  if expectedAction == internalTargetCommittedActionDigest unsigned
    then Right ()
    else Left TargetIntentActionDigestMismatch
  if authorityTimeMicros now < authorityTimeMicros (targetIntentDeadline spec)
    then
      Right
        VerifiedTargetCommittedIntent
          { internalVerifiedTargetUnsigned = unsigned
          , internalVerifiedAcceptedAuthority = accepted
          }
    else Left (TargetIntentDeadlineReached now (targetIntentDeadline spec))
 where
  unsigned = internalSignedTargetUnsigned signed

authorityEpochValue :: AuthorityEpoch -> Natural
authorityEpochValue (AuthorityEpoch value) = value

validateAcceptedEpoch
  :: AuthorityEpoch
  -> Either AcceptedTargetAuthorityError ()
validateAcceptedEpoch (AuthorityEpoch value)
  | value == 0 = Left AcceptedTargetAuthorityEpochMustBePositive
  | otherwise = Right ()

validateAcceptedIssuerIdentity :: Text -> Either AcceptedTargetAuthorityError ()
validateAcceptedIssuerIdentity value
  | validBoundedIdentifier value = Right ()
  | otherwise = Left AcceptedTargetAuthorityIssuerIdentityInvalid

validateAcceptedIdentity :: Text -> Either AcceptedTargetAuthorityError ()
validateAcceptedIdentity value
  | validBoundedIdentifier value = Right ()
  | otherwise = Left AcceptedTargetAuthorityIdentityInvalid

validBoundedIdentifier :: Text -> Bool
validBoundedIdentifier value =
  not (Text.null value)
    && Text.length value <= 128
    && not (Text.any (\character -> isControl character || isSpace character) value)

validClusterIdentity :: Text -> Bool
validClusterIdentity value =
  validBoundedIdentifier value
    && Text.length value <= 96
    && Text.all
      (\character -> isAsciiLower character || isDigit character || character `elem` (".-_" :: String))
      value

validSha256Digest :: Text -> Bool
validSha256Digest value =
  Text.length value == 71
    && "sha256:" `Text.isPrefixOf` value
    && Text.all validHex (Text.drop 7 value)
 where
  validHex character = isDigit character || (isAsciiLower character && isHexDigit character)

validKubernetesUid :: Text -> Bool
validKubernetesUid value =
  not (Text.null value)
    && Text.length value <= 128
    && not (Text.any (\character -> isControl character || isSpace character) value)

parseTargetIntentPublicKey
  :: TargetIntentPublicKey
  -> Either TargetIntentVerificationError Ed25519.PublicKey
parseTargetIntentPublicKey (TargetIntentPublicKey bytes) = case Ed25519.publicKey bytes of
  CryptoFailed _ -> Left TargetIntentPublicKeyInvalid
  CryptoPassed key -> Right key

parseTargetIntentSignature
  :: ByteString
  -> Either TargetIntentVerificationError Ed25519.Signature
parseTargetIntentSignature bytes = case Ed25519.signature bytes of
  CryptoFailed _ -> Left TargetIntentSignatureInvalid
  CryptoPassed signature -> Right signature

mapAcceptedValue
  :: (Show errorValue)
  => Either errorValue value
  -> Either AcceptedTargetAuthorityCodecError value
mapAcceptedValue = either (Left . AcceptedTargetAuthorityValueInvalid . Text.pack . show) Right

mapAcceptedSigning
  :: Either TargetIntentSigningKeyError value
  -> Either AcceptedTargetAuthorityCodecError value
mapAcceptedSigning = either (Left . AcceptedTargetAuthorityValueInvalid . Text.pack . show) Right

mapAcceptedLease
  :: (Show errorValue)
  => Either errorValue value
  -> Either AcceptedTargetAuthorityCodecError value
mapAcceptedLease = either (Left . AcceptedTargetAuthorityValueInvalid . Text.pack . show) Right

mapAcceptedError
  :: Either AcceptedTargetAuthorityError value
  -> Either AcceptedTargetAuthorityCodecError value
mapAcceptedError = either (Left . AcceptedTargetAuthorityValueInvalid . Text.pack . show) Right

mapAcceptedText
  :: Either Text value
  -> Either AcceptedTargetAuthorityCodecError value
mapAcceptedText = either (Left . AcceptedTargetAuthorityValueInvalid) Right

mapIntentValue
  :: (Show errorValue)
  => Either errorValue value
  -> Either TargetCommittedIntentCodecError value
mapIntentValue = either (Left . TargetCommittedIntentValueInvalid . Text.pack . show) Right

mapIntentLease
  :: (Show errorValue)
  => Either errorValue value
  -> Either TargetCommittedIntentCodecError value
mapIntentLease = either (Left . TargetCommittedIntentValueInvalid . Text.pack . show) Right

mapIntentText
  :: Either Text value
  -> Either TargetCommittedIntentCodecError value
mapIntentText = either (Left . TargetCommittedIntentValueInvalid) Right
