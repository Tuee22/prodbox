{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The sole secret-bearing Target worker wire format.
--
-- Frames travel only over stdin attached directly to an already attested
-- one-shot Pod.  Neither this type nor its payload is a control-plane request;
-- decoding is continuation-scoped so plaintext cannot escape into the
-- standing controller's request/receipt state.
module Prodbox.ControlPlane.TargetSecretWorkerProtocol
  ( TargetWorkerFrameBinding
  , targetWorkerFrameJobName
  , targetWorkerFrameJobUid
  , targetWorkerFramePodName
  , targetWorkerFramePodUid
  , targetWorkerFrameServiceAccount
  , targetWorkerFrameServiceAccountUid
  , targetWorkerFrameTarget
  , targetWorkerFrameSchema
  , targetWorkerFrameImageDigest
  , targetWorkerFrameRequestDigest
  , targetWorkerFrameDeadline
  , targetWorkerFrameSessionFence
  , targetWorkerFrameSignedIntent
  , targetWorkerFrameExecutionPermit
  , TargetWorkerIngressError (..)
  , TargetWorkerOperationInput (..)
  , targetWorkerOperationInputSchema
  , targetWorkerOperationRequestDigest
  , targetWorkerIngressMaximumBytes
  , encodeDirectTargetWorkerIngress
  , encodeRewrappedTargetWorkerIngress
  , encodeTargetWorkerOperationIngress
  , withTargetWorkerOperationIngress
  , withTargetWorkerIngress
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless)
import Control.Monad qualified
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Types
  ( ChildAttestation
  , ChildCustodyBinding
  , ChildRecoveryDelivery
  , DeliveryNonce
  )
import Prodbox.Cluster.FederationRegistration
  ( FederationRegistrationIntent
  , validateFederationRegistrationIntent
  )
import Prodbox.ControlPlane.RetainedMaterialEnvelope
  ( validateRetainedDestinationOpening
  )
import Prodbox.ControlPlane.ServiceSessionJournal
  ( serviceSessionBindingFence
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId (..)
  , TargetSecretPayload
  , targetSecretPayloadId
  , validateTargetSecretPayload
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetCommittedIntentSpec (targetIntentCommitReceiptDigest)
  , decodeSignedTargetCommittedIntent
  , encodeSignedTargetCommittedIntent
  , signedTargetCommittedIntentSpec
  , targetCommittedIntentMaximumEncodedBytes
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerAttestation
  , TargetWorkerImageDigest
  , TargetWorkerIngressSchema (..)
  , TargetWorkerIntent
  , TargetWorkerJobUid
  , TargetWorkerPodUid
  , TargetWorkerServiceAccountUid
  , mkTargetWorkerImageDigest
  , mkTargetWorkerJobUid
  , mkTargetWorkerPodUid
  , mkTargetWorkerServiceAccountUid
  , targetWorkerAttestedIntent
  , targetWorkerAttestedJobUid
  , targetWorkerAttestedPodName
  , targetWorkerAttestedPodUid
  , targetWorkerAttestedServiceAccountUid
  , targetWorkerImageDigestText
  , targetWorkerIntentAuthorizedOperationDigest
  , targetWorkerIntentDeadline
  , targetWorkerIntentGeneration
  , targetWorkerIntentImageDigest
  , targetWorkerIntentJobName
  , targetWorkerIntentRequestDigest
  , targetWorkerIntentSchema
  , targetWorkerIntentServiceAccount
  , targetWorkerIntentSignedBytes
  , targetWorkerIntentTarget
  , targetWorkerJobUidText
  , targetWorkerPodUidText
  , targetWorkerSchemaAcceptsTarget
  , targetWorkerServiceAccountUidText
  )
import Prodbox.ControlPlane.TargetWorkerExecutionPermit
  ( SignedTargetWorkerExecutionPermit
  , VerifiedTargetWorkerExecutionPermit
  , decodeTargetWorkerExecutionPermit
  , encodeVerifiedTargetWorkerExecutionPermit
  , verifiedPermitImageDigest
  , verifiedPermitJobName
  , verifiedPermitJobUid
  , verifiedPermitPodName
  , verifiedPermitPodUid
  , verifiedPermitServiceAccount
  , verifiedPermitServiceAccountUid
  , verifiedPermitSessionBinding
  )
import Prodbox.ControlPlane.TlsTargetAgentEndpoint
  ( TlsHomeRewrapRequest
  , TlsHomeWrapRequest
  , TlsTargetRestoreRequest
  , TlsTargetRetainRequest
  , TlsTargetVerifyRequest
  )
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( SRetainedMaterialSchema (SRetainedAcmeEabMaterial, SRetainedSesSmtpMaterial)
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( TargetValueDigest
  , mkTargetValueDigest
  , sha256TargetValueDigest
  , targetValueDigestText
  )

-- | Closed stdin-only operation family.  Constructor choice fixes the input
-- type and the only legal result arm.  There is deliberately no generic
-- path, Vault operation, Kubernetes coordinate, or untyped bytes constructor.
-- The two retained-material constructors carry ciphertext in their exact
-- schema lane; the direct constructor is restricted to the existing closed
-- 'TargetSecretPayload' vocabulary.
data TargetWorkerOperationInput
  = TargetWorkerDirectMaterialInput !TargetSecretPayload
  | TargetWorkerRewrappedSesSmtpInput !ByteString
  | TargetWorkerRewrappedAcmeEabInput !ByteString
  | TargetWorkerTlsPrepareInput
  | TargetWorkerTlsRetainInput !TlsTargetRetainRequest
  | TargetWorkerTlsHomeWrapInput !TlsHomeWrapRequest
  | TargetWorkerTlsHomeRewrapInput !TlsHomeRewrapRequest
  | TargetWorkerTlsRestoreInput !TlsTargetRestoreRequest
  | TargetWorkerTlsVerifyInput !TlsTargetVerifyRequest
  | TargetWorkerFederationCustodyCommitInput !FederationRegistrationIntent
  | TargetWorkerFederationRecoveryPrepareInput
      !ChildCustodyBinding
      !DeliveryNonce
      !ChildAttestation
  | TargetWorkerFederationRecoveryObserveInput !ChildRecoveryDelivery
  | TargetWorkerFederationRecoveryCommitInput !ChildRecoveryDelivery
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show TargetWorkerOperationInput where
  show operation = case operation of
    TargetWorkerDirectMaterialInput {} -> "TargetWorkerDirectMaterialInput <redacted>"
    TargetWorkerRewrappedSesSmtpInput bytes ->
      "TargetWorkerRewrappedSesSmtpInput <" <> show (ByteString.length bytes) <> " bytes>"
    TargetWorkerRewrappedAcmeEabInput bytes ->
      "TargetWorkerRewrappedAcmeEabInput <" <> show (ByteString.length bytes) <> " bytes>"
    TargetWorkerTlsPrepareInput -> "TargetWorkerTlsPrepareInput"
    TargetWorkerTlsRetainInput {} -> "TargetWorkerTlsRetainInput <redacted>"
    TargetWorkerTlsHomeWrapInput {} -> "TargetWorkerTlsHomeWrapInput <redacted>"
    TargetWorkerTlsHomeRewrapInput {} -> "TargetWorkerTlsHomeRewrapInput <redacted>"
    TargetWorkerTlsRestoreInput {} -> "TargetWorkerTlsRestoreInput <redacted>"
    TargetWorkerTlsVerifyInput {} -> "TargetWorkerTlsVerifyInput"
    TargetWorkerFederationCustodyCommitInput {} ->
      "TargetWorkerFederationCustodyCommitInput <ciphertext>"
    TargetWorkerFederationRecoveryPrepareInput {} ->
      "TargetWorkerFederationRecoveryPrepareInput <ciphertext>"
    TargetWorkerFederationRecoveryObserveInput {} ->
      "TargetWorkerFederationRecoveryObserveInput <ciphertext>"
    TargetWorkerFederationRecoveryCommitInput {} ->
      "TargetWorkerFederationRecoveryCommitInput <ciphertext>"

targetWorkerOperationInputSchema
  :: TargetWorkerOperationInput -> TargetWorkerIngressSchema
targetWorkerOperationInputSchema operation = case operation of
  TargetWorkerDirectMaterialInput {} -> TargetWorkerDirectAws
  TargetWorkerRewrappedSesSmtpInput {} -> TargetWorkerRewrappedSesSmtp
  TargetWorkerRewrappedAcmeEabInput {} -> TargetWorkerRewrappedAcmeEab
  TargetWorkerTlsPrepareInput -> TargetWorkerTlsPrepare
  TargetWorkerTlsRetainInput {} -> TargetWorkerTlsRetain
  TargetWorkerTlsHomeWrapInput {} -> TargetWorkerTlsHomeWrap
  TargetWorkerTlsHomeRewrapInput {} -> TargetWorkerTlsHomeRewrap
  TargetWorkerTlsRestoreInput {} -> TargetWorkerTlsRestore
  TargetWorkerTlsVerifyInput {} -> TargetWorkerTlsVerify
  TargetWorkerFederationCustodyCommitInput {} ->
    TargetWorkerFederationCustodyCommit
  TargetWorkerFederationRecoveryPrepareInput {} ->
    TargetWorkerFederationRecoveryPrepare
  TargetWorkerFederationRecoveryObserveInput {} ->
    TargetWorkerFederationRecoveryObserve
  TargetWorkerFederationRecoveryCommitInput {} ->
    TargetWorkerFederationRecoveryCommit

-- | Domain-separated commitment used by Authority authorization for one
-- exact arm.  TLS and federation payloads are already ciphertext/public
-- values; the digest nevertheless stays an opaque binding and is never used
-- as a substitute for retained ciphertext custody.
targetWorkerOperationRequestDigest
  :: TargetWorkerOperationInput -> TargetValueDigest
targetWorkerOperationRequestDigest operation =
  sha256TargetValueDigest
    ( "prodbox-target-worker-operation-v1\NUL"
        <> LazyByteString.toStrict (serialise operation)
    )

data WireTargetWorkerIngress = WireTargetWorkerIngress
  { wireTargetWorkerVersion :: !Word16
  , wireTargetWorkerJobName :: !Text
  , wireTargetWorkerJobUid :: !Text
  , wireTargetWorkerPodName :: !Text
  , wireTargetWorkerPodUid :: !Text
  , wireTargetWorkerTarget :: !TargetSecretId
  , wireTargetWorkerSchema :: !TargetWorkerIngressSchema
  , wireTargetWorkerImageDigest :: !Text
  , wireTargetWorkerServiceAccount :: !Text
  , wireTargetWorkerServiceAccountUid :: !Text
  , wireTargetWorkerRequestDigest :: !Text
  , wireTargetWorkerDeadlineMicros :: !Natural
  , wireTargetWorkerSessionFence :: !Natural
  , wireTargetWorkerSignedIntent :: !ByteString
  , wireTargetWorkerExecutionPermit :: !ByteString
  , wireTargetWorkerOperation :: !TargetWorkerOperationInput
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetWorkerFrameBinding = TargetWorkerFrameBinding
  { internalFrameJobName :: !Text
  , internalFrameJobUid :: !TargetWorkerJobUid
  , internalFramePodName :: !Text
  , internalFramePodUid :: !TargetWorkerPodUid
  , internalFrameServiceAccount :: !Text
  , internalFrameServiceAccountUid :: !TargetWorkerServiceAccountUid
  , internalFrameTarget :: !TargetSecretId
  , internalFrameSchema :: !TargetWorkerIngressSchema
  , internalFrameImageDigest :: !TargetWorkerImageDigest
  , internalFrameRequestDigest :: !TargetValueDigest
  , internalFrameAuthorizedOperationDigest :: !TargetValueDigest
  , internalFrameDeadline :: !AuthorityTime
  , internalFrameSessionFence :: !Natural
  , internalFrameSignedIntent :: !ByteString
  , internalFrameExecutionPermit :: !SignedTargetWorkerExecutionPermit
  }

targetWorkerFrameJobName :: TargetWorkerFrameBinding -> Text
targetWorkerFrameJobName = internalFrameJobName

targetWorkerFrameJobUid :: TargetWorkerFrameBinding -> TargetWorkerJobUid
targetWorkerFrameJobUid = internalFrameJobUid

targetWorkerFramePodName :: TargetWorkerFrameBinding -> Text
targetWorkerFramePodName = internalFramePodName

targetWorkerFramePodUid :: TargetWorkerFrameBinding -> TargetWorkerPodUid
targetWorkerFramePodUid = internalFramePodUid

targetWorkerFrameServiceAccount :: TargetWorkerFrameBinding -> Text
targetWorkerFrameServiceAccount = internalFrameServiceAccount

targetWorkerFrameServiceAccountUid
  :: TargetWorkerFrameBinding -> TargetWorkerServiceAccountUid
targetWorkerFrameServiceAccountUid = internalFrameServiceAccountUid

targetWorkerFrameTarget :: TargetWorkerFrameBinding -> TargetSecretId
targetWorkerFrameTarget = internalFrameTarget

targetWorkerFrameSchema :: TargetWorkerFrameBinding -> TargetWorkerIngressSchema
targetWorkerFrameSchema = internalFrameSchema

targetWorkerFrameImageDigest :: TargetWorkerFrameBinding -> TargetWorkerImageDigest
targetWorkerFrameImageDigest = internalFrameImageDigest

targetWorkerFrameRequestDigest :: TargetWorkerFrameBinding -> TargetValueDigest
targetWorkerFrameRequestDigest = internalFrameRequestDigest

targetWorkerFrameDeadline :: TargetWorkerFrameBinding -> AuthorityTime
targetWorkerFrameDeadline = internalFrameDeadline

targetWorkerFrameSessionFence :: TargetWorkerFrameBinding -> Natural
targetWorkerFrameSessionFence = internalFrameSessionFence

targetWorkerFrameSignedIntent :: TargetWorkerFrameBinding -> ByteString
targetWorkerFrameSignedIntent = internalFrameSignedIntent

targetWorkerFrameExecutionPermit
  :: TargetWorkerFrameBinding -> SignedTargetWorkerExecutionPermit
targetWorkerFrameExecutionPermit = internalFrameExecutionPermit

data TargetWorkerIngressError
  = TargetWorkerIngressTooLarge !Int !Int
  | TargetWorkerIngressDecodeFailed
  | TargetWorkerIngressUnsupportedVersion !Word16
  | TargetWorkerIngressNonCanonical
  | TargetWorkerIngressJobBindingInvalid
  | TargetWorkerIngressPodNameInvalid
  | TargetWorkerIngressPodUidInvalid
  | TargetWorkerIngressImageDigestInvalid
  | TargetWorkerIngressServiceAccountMismatch
  | TargetWorkerIngressRequestDigestInvalid
  | TargetWorkerIngressDeadlineInvalid
  | TargetWorkerIngressIntentInvalid
  | TargetWorkerIngressExecutionPermitInvalid
  | TargetWorkerIngressExecutionPermitMismatch
  | TargetWorkerIngressSchemaMismatch
  | TargetWorkerIngressPayloadInvalid
  | TargetWorkerIngressEnvelopeInvalid
  deriving stock (Eq, Show)

targetWorkerIngressMaximumBytes :: Int
targetWorkerIngressMaximumBytes = 8 * 1024 * 1024

targetWorkerIngressVersion :: Word16
targetWorkerIngressVersion = 5

encodeDirectTargetWorkerIngress
  :: VerifiedTargetWorkerExecutionPermit
  -> TargetWorkerAttestation
  -> TargetSecretPayload
  -> Either TargetWorkerIngressError ByteString
encodeDirectTargetWorkerIngress permit attestation payload = do
  let intent = targetWorkerAttestedIntent attestation
  unless
    ( targetWorkerIntentSchema intent == TargetWorkerDirectAws
        && targetSecretPayloadId payload == targetWorkerIntentTarget intent
    )
    (Left TargetWorkerIngressSchemaMismatch)
  first (const TargetWorkerIngressPayloadInvalid) (validateTargetSecretPayload payload)
  encodeFrame permit attestation (TargetWorkerDirectMaterialInput payload)

encodeRewrappedTargetWorkerIngress
  :: VerifiedTargetWorkerExecutionPermit
  -> TargetWorkerAttestation
  -> ByteString
  -> Either TargetWorkerIngressError ByteString
encodeRewrappedTargetWorkerIngress permit attestation envelope = do
  let intent = targetWorkerAttestedIntent attestation
      schema = targetWorkerIntentSchema intent
  unless
    (schema == TargetWorkerRewrappedSesSmtp || schema == TargetWorkerRewrappedAcmeEab)
    (Left TargetWorkerIngressSchemaMismatch)
  unless
    (not (ByteString.null envelope) && ByteString.length envelope <= 64 * 1024)
    (Left TargetWorkerIngressEnvelopeInvalid)
  operation <- case schema of
    TargetWorkerRewrappedSesSmtp ->
      TargetWorkerRewrappedSesSmtpInput envelope
        <$ first
          (const TargetWorkerIngressEnvelopeInvalid)
          ( validateRetainedDestinationOpening
              SRetainedSesSmtpMaterial
              (targetWorkerIntentGeneration intent)
              envelope
          )
    TargetWorkerRewrappedAcmeEab ->
      TargetWorkerRewrappedAcmeEabInput envelope
        <$ first
          (const TargetWorkerIngressEnvelopeInvalid)
          ( validateRetainedDestinationOpening
              SRetainedAcmeEabMaterial
              (targetWorkerIntentGeneration intent)
              envelope
          )
    _ -> Left TargetWorkerIngressSchemaMismatch
  encodeFrame permit attestation operation

-- | Encode one non-material arm after exact Job/Pod/ServiceAccount
-- attestation and Authority execution-permit verification.  Supplying a
-- request for a different arm is rejected before any bytes reach stdin.
encodeTargetWorkerOperationIngress
  :: VerifiedTargetWorkerExecutionPermit
  -> TargetWorkerAttestation
  -> TargetWorkerOperationInput
  -> Either TargetWorkerIngressError ByteString
encodeTargetWorkerOperationIngress permit attestation operation = do
  validateOperationInput (targetWorkerAttestedIntent attestation) operation
  encodeFrame permit attestation operation

encodeFrame
  :: VerifiedTargetWorkerExecutionPermit
  -> TargetWorkerAttestation
  -> TargetWorkerOperationInput
  -> Either TargetWorkerIngressError ByteString
encodeFrame permit attestation operation = do
  let intent = targetWorkerAttestedIntent attestation
  unless
    ( verifiedPermitJobName permit == targetWorkerIntentJobName intent
        && verifiedPermitJobUid permit == targetWorkerAttestedJobUid attestation
        && verifiedPermitPodName permit == targetWorkerAttestedPodName attestation
        && verifiedPermitPodUid permit == targetWorkerAttestedPodUid attestation
        && verifiedPermitServiceAccount permit == targetWorkerIntentServiceAccount intent
        && verifiedPermitServiceAccountUid permit
          == targetWorkerAttestedServiceAccountUid attestation
        && verifiedPermitImageDigest permit == targetWorkerIntentImageDigest intent
    )
    (Left TargetWorkerIngressExecutionPermitMismatch)
  let
    encoded =
      LazyByteString.toStrict
        ( serialise
            WireTargetWorkerIngress
              { wireTargetWorkerVersion = targetWorkerIngressVersion
              , wireTargetWorkerJobName = verifiedPermitJobName permit
              , wireTargetWorkerJobUid =
                  targetWorkerJobUidText (verifiedPermitJobUid permit)
              , wireTargetWorkerPodName = verifiedPermitPodName permit
              , wireTargetWorkerPodUid =
                  targetWorkerPodUidText (targetWorkerAttestedPodUid attestation)
              , wireTargetWorkerTarget = targetWorkerIntentTarget intent
              , wireTargetWorkerSchema = targetWorkerIntentSchema intent
              , wireTargetWorkerImageDigest =
                  targetWorkerImageDigestText (targetWorkerIntentImageDigest intent)
              , wireTargetWorkerServiceAccount = targetWorkerIntentServiceAccount intent
              , wireTargetWorkerServiceAccountUid =
                  targetWorkerServiceAccountUidText
                    (targetWorkerAttestedServiceAccountUid attestation)
              , wireTargetWorkerRequestDigest =
                  targetValueDigestText (targetWorkerIntentRequestDigest intent)
              , wireTargetWorkerDeadlineMicros =
                  authorityTimeMicros (targetWorkerIntentDeadline intent)
              , wireTargetWorkerSessionFence =
                  serviceSessionBindingFence (verifiedPermitSessionBinding permit)
              , wireTargetWorkerSignedIntent = targetWorkerIntentSignedBytes intent
              , wireTargetWorkerExecutionPermit =
                  encodeVerifiedTargetWorkerExecutionPermit permit
              , wireTargetWorkerOperation = operation
              }
        )
  if ByteString.length encoded > targetWorkerIngressMaximumBytes
    then
      Left
        ( TargetWorkerIngressTooLarge
            (ByteString.length encoded)
            targetWorkerIngressMaximumBytes
        )
    else Right encoded

-- | Consume either an exact direct-AWS payload or an exact rewrapped
-- SES/EAB envelope.  Only the selected callback executes.
withTargetWorkerIngress
  :: ByteString
  -> (TargetWorkerFrameBinding -> TargetSecretPayload -> result)
  -> (TargetWorkerFrameBinding -> ByteString -> result)
  -> Either TargetWorkerIngressError result
withTargetWorkerIngress bytes consumeDirect consumeRewrapped =
  do
    selected <- withTargetWorkerOperationIngress bytes consume
    selected
 where
  consume binding operation = case operation of
    TargetWorkerDirectMaterialInput payload -> Right (consumeDirect binding payload)
    TargetWorkerRewrappedSesSmtpInput envelope -> Right (consumeRewrapped binding envelope)
    TargetWorkerRewrappedAcmeEabInput envelope -> Right (consumeRewrapped binding envelope)
    _ -> Left TargetWorkerIngressSchemaMismatch

-- | Decode the closed operation sum and invoke exactly one continuation.
-- Validation happens before the continuation, including target/schema
-- pairing and the retained-material envelope's exact schema/generation.
withTargetWorkerOperationIngress
  :: ByteString
  -> (TargetWorkerFrameBinding -> TargetWorkerOperationInput -> result)
  -> Either TargetWorkerIngressError result
withTargetWorkerOperationIngress bytes consume
  | ByteString.length bytes > targetWorkerIngressMaximumBytes =
      Left
        ( TargetWorkerIngressTooLarge
            (ByteString.length bytes)
            targetWorkerIngressMaximumBytes
        )
  | otherwise = do
      wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left TargetWorkerIngressDecodeFailed
        Right decoded -> Right decoded
      unless
        (wireTargetWorkerVersion wire == targetWorkerIngressVersion)
        (Left (TargetWorkerIngressUnsupportedVersion (wireTargetWorkerVersion wire)))
      unless
        (LazyByteString.toStrict (serialise wire) == bytes)
        (Left TargetWorkerIngressNonCanonical)
      binding <- bindingFromWire wire
      unless
        ( targetWorkerSchemaAcceptsTarget
            (targetWorkerFrameSchema binding)
            (targetWorkerFrameTarget binding)
        )
        (Left TargetWorkerIngressSchemaMismatch)
      let operation = wireTargetWorkerOperation wire
      validateOperationBinding binding operation
      pure (consume binding operation)

validateOperationInput
  :: TargetWorkerIntent
  -> TargetWorkerOperationInput
  -> Either TargetWorkerIngressError ()
validateOperationInput intent operation = do
  validateOperationPairing
    (targetWorkerIntentTarget intent)
    (targetWorkerIntentSchema intent)
    operation
  validateExactOperationAuthorization
    (targetWorkerIntentTarget intent)
    (targetWorkerIntentAuthorizedOperationDigest intent)
    operation
  case operation of
    TargetWorkerRewrappedSesSmtpInput envelope ->
      first
        (const TargetWorkerIngressEnvelopeInvalid)
        ( validateRetainedDestinationOpening
            SRetainedSesSmtpMaterial
            (targetWorkerIntentGeneration intent)
            envelope
        )
    TargetWorkerRewrappedAcmeEabInput envelope ->
      first
        (const TargetWorkerIngressEnvelopeInvalid)
        ( validateRetainedDestinationOpening
            SRetainedAcmeEabMaterial
            (targetWorkerIntentGeneration intent)
            envelope
        )
    _ -> Right ()

validateOperationBinding
  :: TargetWorkerFrameBinding
  -> TargetWorkerOperationInput
  -> Either TargetWorkerIngressError ()
validateOperationBinding binding operation = do
  validateOperationPairing
    (targetWorkerFrameTarget binding)
    (targetWorkerFrameSchema binding)
    operation
  validateExactOperationAuthorization
    (targetWorkerFrameTarget binding)
    (internalFrameAuthorizedOperationDigest binding)
    operation

-- | Ordinary material commits retain their historical receipt commitment.
-- Operation-only targets have no KV payload: their signed receipt-digest slot
-- is therefore reserved for the exact closed worker operation commitment.
validateExactOperationAuthorization
  :: TargetSecretId
  -> TargetValueDigest
  -> TargetWorkerOperationInput
  -> Either TargetWorkerIngressError ()
validateExactOperationAuthorization target authorizedDigest operation =
  case target of
    TargetPublicEdgeTls -> exact
    TargetFederationCustody -> exact
    _ -> Right ()
 where
  exact =
    unless
      (authorizedDigest == targetWorkerOperationRequestDigest operation)
      (Left TargetWorkerIngressIntentInvalid)

validateOperationPairing
  :: TargetSecretId
  -> TargetWorkerIngressSchema
  -> TargetWorkerOperationInput
  -> Either TargetWorkerIngressError ()
validateOperationPairing target schema operation = do
  unless
    (targetWorkerOperationInputSchema operation == schema)
    (Left TargetWorkerIngressSchemaMismatch)
  case operation of
    TargetWorkerDirectMaterialInput payload -> do
      unless
        (targetSecretPayloadId payload == target)
        (Left TargetWorkerIngressSchemaMismatch)
      first
        (const TargetWorkerIngressPayloadInvalid)
        (validateTargetSecretPayload payload)
    TargetWorkerRewrappedSesSmtpInput envelope -> validateEnvelope envelope
    TargetWorkerRewrappedAcmeEabInput envelope -> validateEnvelope envelope
    TargetWorkerFederationCustodyCommitInput intent ->
      first
        (const TargetWorkerIngressPayloadInvalid)
        (Control.Monad.void (validateFederationRegistrationIntent intent))
    _ -> Right ()
 where
  validateEnvelope envelope =
    unless
      (not (ByteString.null envelope) && ByteString.length envelope <= 64 * 1024)
      (Left TargetWorkerIngressEnvelopeInvalid)

bindingFromWire
  :: WireTargetWorkerIngress
  -> Either TargetWorkerIngressError TargetWorkerFrameBinding
bindingFromWire wire = do
  unless
    (wireTargetWorkerJobName wire /= "" && wireTargetWorkerPodName wire /= "")
    (Left TargetWorkerIngressPodNameInvalid)
  jobUid <-
    first
      (const TargetWorkerIngressJobBindingInvalid)
      (mkTargetWorkerJobUid (wireTargetWorkerJobUid wire))
  podUid <-
    first
      (const TargetWorkerIngressPodUidInvalid)
      (mkTargetWorkerPodUid (wireTargetWorkerPodUid wire))
  image <-
    first
      (const TargetWorkerIngressImageDigestInvalid)
      (mkTargetWorkerImageDigest (wireTargetWorkerImageDigest wire))
  unless
    ( validWorkerServiceAccount
        (wireTargetWorkerServiceAccount wire)
    )
    (Left TargetWorkerIngressServiceAccountMismatch)
  serviceAccountUid <-
    first
      (const TargetWorkerIngressServiceAccountMismatch)
      (mkTargetWorkerServiceAccountUid (wireTargetWorkerServiceAccountUid wire))
  requestDigest <-
    first
      (const TargetWorkerIngressRequestDigestInvalid)
      (mkTargetValueDigest (wireTargetWorkerRequestDigest wire))
  deadline <-
    if wireTargetWorkerDeadlineMicros wire > 0
      then Right (authorityTimeFromMicros (wireTargetWorkerDeadlineMicros wire))
      else Left TargetWorkerIngressDeadlineInvalid
  unless
    (wireTargetWorkerSessionFence wire > 0)
    (Left TargetWorkerIngressDeadlineInvalid)
  signed <-
    first
      (const TargetWorkerIngressIntentInvalid)
      ( decodeSignedTargetCommittedIntent
          targetCommittedIntentMaximumEncodedBytes
          (wireTargetWorkerSignedIntent wire)
      )
  unless
    (encodeSignedTargetCommittedIntent signed == wireTargetWorkerSignedIntent wire)
    (Left TargetWorkerIngressIntentInvalid)
  executionPermit <-
    first
      (const TargetWorkerIngressExecutionPermitInvalid)
      (decodeTargetWorkerExecutionPermit (wireTargetWorkerExecutionPermit wire))
  pure
    TargetWorkerFrameBinding
      { internalFrameJobName = wireTargetWorkerJobName wire
      , internalFrameJobUid = jobUid
      , internalFramePodName = wireTargetWorkerPodName wire
      , internalFramePodUid = podUid
      , internalFrameServiceAccount = wireTargetWorkerServiceAccount wire
      , internalFrameServiceAccountUid = serviceAccountUid
      , internalFrameTarget = wireTargetWorkerTarget wire
      , internalFrameSchema = wireTargetWorkerSchema wire
      , internalFrameImageDigest = image
      , internalFrameRequestDigest = requestDigest
      , internalFrameAuthorizedOperationDigest =
          targetIntentCommitReceiptDigest (signedTargetCommittedIntentSpec signed)
      , internalFrameDeadline = deadline
      , internalFrameSessionFence = wireTargetWorkerSessionFence wire
      , internalFrameSignedIntent = wireTargetWorkerSignedIntent wire
      , internalFrameExecutionPermit = executionPermit
      }

validWorkerServiceAccount :: Text -> Bool
validWorkerServiceAccount value = value == "prodbox-target-secret-worker"

-- Keep this helper local to make it explicit that frame construction receives
-- an already attested intent, never an arbitrary controller DTO.
_attestedIntentWitness :: TargetWorkerAttestation -> TargetWorkerIntent
_attestedIntentWitness = targetWorkerAttestedIntent
