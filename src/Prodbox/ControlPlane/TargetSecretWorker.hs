{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Secret-free intent, Pod attestation, opaque receipt, and exact KV-v2
-- generation-CAS semantics for the one-shot Target Secret Agent worker.
--
-- This module is deliberately usable without a Kubernetes or Vault runtime:
-- the standing controller handles only 'TargetWorkerIntent', attestation, and
-- receipt values, while the secret-bearing worker supplies the closed payload
-- directly to 'executeTargetWorkerMaterialization'.
module Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerIngressSchema (..)
  , allTargetWorkerIngressSchemas
  , targetWorkerSchemaToken
  , parseTargetWorkerIngressSchema
  , targetWorkerSchemaForTarget
  , targetWorkerSchemaAcceptsTarget
  , TargetWorkerImageDigest
  , mkTargetWorkerImageDigest
  , targetWorkerImageDigestText
  , TargetWorkerJobUid
  , mkTargetWorkerJobUid
  , targetWorkerJobUidText
  , TargetWorkerPodUid
  , mkTargetWorkerPodUid
  , targetWorkerPodUidText
  , TargetWorkerServiceAccountUid
  , mkTargetWorkerServiceAccountUid
  , targetWorkerServiceAccountUidText
  , targetWorkerServiceAccount
  , TargetWorkerIntent
  , TargetWorkerIntentError (..)
  , prepareTargetWorkerIntent
  , targetWorkerIntentTarget
  , targetWorkerIntentAgentIdentity
  , targetWorkerIntentSchema
  , targetWorkerIntentGeneration
  , targetWorkerIntentDeadline
  , targetWorkerIntentFencingToken
  , targetWorkerIntentRequestDigest
  , targetWorkerIntentActionDigest
  , targetWorkerIntentAuthorizedOperationDigest
  , targetWorkerIntentImageDigest
  , targetWorkerIntentSignedBytes
  , targetWorkerIntentJobName
  , targetWorkerIntentServiceAccount
  , RawTargetWorkerPodObservation (..)
  , TargetWorkerAttestation
  , TargetWorkerAttestationError (..)
  , allTargetWorkerAttestationErrors
  , renderTargetWorkerAttestationError
  , attestTargetWorkerPod
  , targetWorkerAttestedJobUid
  , targetWorkerAttestedPodUid
  , targetWorkerAttestedPodName
  , targetWorkerAttestedServiceAccountUid
  , targetWorkerAttestedIntent
  , TargetWorkerReceipt
  , TargetWorkerReceiptError (..)
  , mkTargetWorkerReceiptProjection
  , targetWorkerReceiptMaximumBytes
  , encodeTargetWorkerReceipt
  , decodeTargetWorkerReceipt
  , targetWorkerReceiptTarget
  , targetWorkerReceiptGeneration
  , targetWorkerReceiptVaultVersion
  , targetWorkerReceiptCommitment
  , targetWorkerReceiptRequestDigest
  , targetWorkerReceiptPodUid
  , targetWorkerReceiptMatchesAttestation
  , TargetWorkerOperationResult (..)
  , targetWorkerOperationResultMatchesSchema
  , TargetWorkerProvisionalCompletion
  , TargetWorkerProvisionalCompletionError (..)
  , targetWorkerProvisionalCompletionMaximumBytes
  , successfulTargetWorkerProvisionalCompletion
  , successfulTargetWorkerOperationProvisionalCompletion
  , refusedTargetWorkerProvisionalCompletion
  , encodeTargetWorkerProvisionalCompletion
  , decodeTargetWorkerProvisionalCompletion
  , targetWorkerProvisionalReceipt
  , targetWorkerProvisionalResult
  , targetWorkerProvisionalAccessor
  , targetWorkerProvisionalRefusal
  , targetWorkerCleanupAuthorization
  , targetWorkerCleanupCompletion
  , TargetWorkerDataObservation (..)
  , TargetWorkerMetadataObservation (..)
  , TargetWorkerVaultBoundary (..)
  , TargetWorkerMaterializationResult (..)
  , TargetWorkerExecutionError (..)
  , executeTargetWorkerMaterialization
  , finishTargetWorkerSession
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isControl, isDigit, isHexDigit, isSpace)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Types
  ( ChildRecoveryConsumptionObservation
  , ChildRecoveryDelivery
  , ParentCustodyAcknowledgement
  )
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch)
import Prodbox.ControlPlane.TargetMaterialEndpoint
  ( targetMaterialMetadataActionDigestField
  , targetMaterialMetadataCommitmentField
  , targetMaterialMetadataFencingTokenField
  , targetMaterialMetadataGenerationField
  , targetMaterialMetadataImageDigestField
  , targetMaterialMetadataOwnerNonceField
  , targetMaterialMetadataPodUidField
  , targetMaterialMetadataRequestDigestField
  , targetMaterialMetadataVaultVersionField
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId (..)
  , TargetSecretPayload
  , compiledTargetSecretSink
  , targetSecretIdToken
  , targetSecretPayloadId
  , targetSecretPayloadToVaultFields
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( AcceptedTargetAuthority
  , SignedTargetCommittedIntent
  , TargetAgentIdentity
  , TargetCommittedIntentCodecError
  , TargetCommittedIntentSpec (..)
  , TargetIntentVerificationError
  , VerifiedTargetCommittedIntent
  , decodeSignedTargetCommittedIntent
  , encodeSignedTargetCommittedIntent
  , targetAgentIdentityText
  , targetCommittedIntentMaximumEncodedBytes
  , verifiedTargetIntentActionDigest
  , verifiedTargetIntentSpec
  , verifiedTargetIntentTarget
  , verifySignedTargetCommittedIntent
  )
import Prodbox.ControlPlane.TlsDekExchange
  ( TlsDekEnvelope
  , TlsDekPrepared
  , TlsWrappedDek
  )
import Prodbox.ControlPlane.TlsTargetAgentEndpoint
  ( TlsTargetRestoreReceipt
  , TlsTargetRetainReceipt
  , TlsTargetVerifyReceipt
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , FencingToken
  , authorityTimeMicros
  , fencingTokenValue
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
import Text.Read (readMaybe)

-- | Exact material lanes.  Direct materialization is intentionally limited to
-- ordinary, long-lived AWS target credentials.  SES SMTP and ACME EAB enter
-- only through their exact rewrap seams; the retained-custody aggregate and
-- unwrap protocol live outside this module.
data TargetWorkerIngressSchema
  = TargetWorkerDirectAws
  | TargetWorkerRewrappedSesSmtp
  | TargetWorkerRewrappedAcmeEab
  | TargetWorkerTlsPrepare
  | TargetWorkerTlsRetain
  | TargetWorkerTlsHomeWrap
  | TargetWorkerTlsHomeRewrap
  | TargetWorkerTlsRestore
  | TargetWorkerTlsVerify
  | TargetWorkerFederationCustodyCommit
  | TargetWorkerFederationRecoveryPrepare
  | TargetWorkerFederationRecoveryObserve
  | TargetWorkerFederationRecoveryCommit
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

allTargetWorkerIngressSchemas :: [TargetWorkerIngressSchema]
allTargetWorkerIngressSchemas = [minBound .. maxBound]

targetWorkerSchemaToken :: TargetWorkerIngressSchema -> Text
targetWorkerSchemaToken schema = case schema of
  TargetWorkerDirectAws -> "direct-aws"
  TargetWorkerRewrappedSesSmtp -> "rewrapped-ses-smtp"
  TargetWorkerRewrappedAcmeEab -> "rewrapped-acme-eab"
  TargetWorkerTlsPrepare -> "tls-prepare"
  TargetWorkerTlsRetain -> "tls-retain"
  TargetWorkerTlsHomeWrap -> "tls-home-wrap"
  TargetWorkerTlsHomeRewrap -> "tls-home-rewrap"
  TargetWorkerTlsRestore -> "tls-restore"
  TargetWorkerTlsVerify -> "tls-verify"
  TargetWorkerFederationCustodyCommit -> "federation-custody-commit"
  TargetWorkerFederationRecoveryPrepare -> "federation-recovery-prepare"
  TargetWorkerFederationRecoveryObserve -> "federation-recovery-observe"
  TargetWorkerFederationRecoveryCommit -> "federation-recovery-commit"

parseTargetWorkerIngressSchema :: Text -> Either Text TargetWorkerIngressSchema
parseTargetWorkerIngressSchema raw =
  case filter ((== raw) . targetWorkerSchemaToken) allTargetWorkerIngressSchemas of
    [schema] -> Right schema
    _ ->
      Left
        ( "Target worker schema must be exactly one of: "
            <> Text.intercalate ", " (map targetWorkerSchemaToken allTargetWorkerIngressSchemas)
        )

targetWorkerSchemaForTarget
  :: TargetSecretId -> Either TargetWorkerIntentError TargetWorkerIngressSchema
targetWorkerSchemaForTarget target = case target of
  TargetAwsCredential _ -> Right TargetWorkerDirectAws
  TargetSesSmtp -> Right TargetWorkerRewrappedSesSmtp
  TargetAcmeEab -> Right TargetWorkerRewrappedAcmeEab
  TargetPublicEdgeTls -> Left TargetWorkerTargetNotMaterializable
  TargetFederationCustody -> Left TargetWorkerTargetNotMaterializable
  _ -> Left TargetWorkerTargetNotMaterializable

targetWorkerSchemaAcceptsTarget
  :: TargetWorkerIngressSchema -> TargetSecretId -> Bool
targetWorkerSchemaAcceptsTarget schema target = case (schema, target) of
  (TargetWorkerDirectAws, TargetAwsCredential _) -> True
  (TargetWorkerRewrappedSesSmtp, TargetSesSmtp) -> True
  (TargetWorkerRewrappedAcmeEab, TargetAcmeEab) -> True
  (TargetWorkerTlsPrepare, TargetPublicEdgeTls) -> True
  (TargetWorkerTlsRetain, TargetPublicEdgeTls) -> True
  (TargetWorkerTlsHomeWrap, TargetPublicEdgeTls) -> True
  (TargetWorkerTlsHomeRewrap, TargetPublicEdgeTls) -> True
  (TargetWorkerTlsRestore, TargetPublicEdgeTls) -> True
  (TargetWorkerTlsVerify, TargetPublicEdgeTls) -> True
  (TargetWorkerFederationCustodyCommit, TargetFederationCustody) -> True
  (TargetWorkerFederationRecoveryPrepare, TargetFederationCustody) -> True
  (TargetWorkerFederationRecoveryObserve, TargetFederationCustody) -> True
  (TargetWorkerFederationRecoveryCommit, TargetFederationCustody) -> True
  _ -> False

newtype TargetWorkerImageDigest = TargetWorkerImageDigest Text
  deriving stock (Eq, Ord, Show)

mkTargetWorkerImageDigest :: Text -> Either Text TargetWorkerImageDigest
mkTargetWorkerImageDigest raw
  | Text.length value == 71
      && "sha256:" `Text.isPrefixOf` value
      && Text.all validHex (Text.drop 7 value) =
      Right (TargetWorkerImageDigest value)
  | otherwise = Left "target worker image must be an immutable sha256 digest"
 where
  value = Text.strip raw
  validHex character = isDigit character || (isAsciiLower character && isHexDigit character)

targetWorkerImageDigestText :: TargetWorkerImageDigest -> Text
targetWorkerImageDigestText (TargetWorkerImageDigest value) = value

newtype TargetWorkerPodUid = TargetWorkerPodUid Text
  deriving stock (Eq, Ord, Show)

newtype TargetWorkerJobUid = TargetWorkerJobUid Text
  deriving stock (Eq, Ord, Show)

newtype TargetWorkerServiceAccountUid = TargetWorkerServiceAccountUid Text
  deriving stock (Eq, Ord, Show)

mkTargetWorkerJobUid :: Text -> Either Text TargetWorkerJobUid
mkTargetWorkerJobUid raw =
  TargetWorkerJobUid <$> validatedKubernetesUid "target worker Job UID" raw

targetWorkerJobUidText :: TargetWorkerJobUid -> Text
targetWorkerJobUidText (TargetWorkerJobUid value) = value

mkTargetWorkerPodUid :: Text -> Either Text TargetWorkerPodUid
mkTargetWorkerPodUid raw =
  TargetWorkerPodUid <$> validatedKubernetesUid "target worker Pod UID" raw

targetWorkerPodUidText :: TargetWorkerPodUid -> Text
targetWorkerPodUidText (TargetWorkerPodUid value) = value

mkTargetWorkerServiceAccountUid
  :: Text -> Either Text TargetWorkerServiceAccountUid
mkTargetWorkerServiceAccountUid raw =
  TargetWorkerServiceAccountUid
    <$> validatedKubernetesUid "target worker ServiceAccount UID" raw

targetWorkerServiceAccountUidText :: TargetWorkerServiceAccountUid -> Text
targetWorkerServiceAccountUidText (TargetWorkerServiceAccountUid value) = value

validatedKubernetesUid :: Text -> Text -> Either Text Text
validatedKubernetesUid label raw
  | Text.null value = Left (label <> " is empty")
  | Text.length value > 128 = Left (label <> " is over bound")
  | Text.any (\character -> isControl character || isSpace character) value =
      Left (label <> " is invalid")
  | otherwise = Right value
 where
  value = Text.strip raw

targetWorkerServiceAccount :: Text
targetWorkerServiceAccount = "prodbox-target-secret-worker"

data TargetWorkerIntent = TargetWorkerIntent
  { internalWorkerIntentTarget :: !TargetSecretId
  , internalWorkerIntentAgentIdentity :: !TargetAgentIdentity
  , internalWorkerIntentSchema :: !TargetWorkerIngressSchema
  , internalWorkerIntentGeneration :: !CredentialGeneration
  , internalWorkerIntentDeadline :: !AuthorityTime
  , internalWorkerIntentRequestDigest :: !TargetValueDigest
  , internalWorkerIntentActionDigest :: !TargetValueDigest
  , internalWorkerIntentImageDigest :: !TargetWorkerImageDigest
  , internalWorkerIntentSignedBytes :: !ByteString
  , internalWorkerIntentVerified :: !VerifiedTargetCommittedIntent
  , internalWorkerIntentJobName :: !Text
  , internalWorkerIntentServiceAccount :: !Text
  }

data TargetWorkerIntentError
  = TargetWorkerIntentCodecRejected !TargetCommittedIntentCodecError
  | TargetWorkerIntentSignatureRejected !TargetIntentVerificationError
  | TargetWorkerIntentTargetUnregistered !Text
  | TargetWorkerIntentSchemaMismatch
  | TargetWorkerTargetNotMaterializable
  | TargetWorkerAwsRunIssuanceNotImplemented
  | TargetWorkerIntentNonCanonical
  deriving stock (Eq, Show)

data WireTargetWorkerRequestBinding = WireTargetWorkerRequestBinding
  { wireWorkerBindingVersion :: !Word16
  , wireWorkerBindingTarget :: !TargetSecretId
  , wireWorkerBindingAgentIdentity :: !Text
  , wireWorkerBindingSchema :: !TargetWorkerIngressSchema
  , wireWorkerBindingImageDigest :: !Text
  , wireWorkerBindingServiceAccount :: !Text
  , wireWorkerBindingSignedIntent :: !ByteString
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

targetWorkerBindingVersion :: Word16
targetWorkerBindingVersion = 3

prepareTargetWorkerIntent
  :: AcceptedTargetAuthority
  -> AuthorityTime
  -> TargetAgentIdentity
  -> TargetSecretId
  -> TargetWorkerIngressSchema
  -> TargetWorkerImageDigest
  -> ByteString
  -> Either TargetWorkerIntentError TargetWorkerIntent
prepareTargetWorkerIntent accepted now agentIdentity target schema imageDigest signedBytes = do
  unless
    (targetWorkerSchemaAcceptsTarget schema target)
    (Left TargetWorkerIntentSchemaMismatch)
  signed <-
    first
      TargetWorkerIntentCodecRejected
      (decodeSignedTargetCommittedIntent targetCommittedIntentMaximumEncodedBytes signedBytes)
  unless
    (encodeSignedTargetCommittedIntent signed == signedBytes)
    (Left TargetWorkerIntentNonCanonical)
  sink <- first TargetWorkerIntentTargetUnregistered (compiledTargetSecretSink target)
  verified <-
    first
      TargetWorkerIntentSignatureRejected
      (verifySignedTargetCommittedIntent accepted now agentIdentity sink signed)
  unless (verifiedTargetIntentTarget verified == target) (Left TargetWorkerIntentSchemaMismatch)
  let spec = verifiedTargetIntentSpec verified
      actionDigest = verifiedTargetIntentActionDigest verified
      serviceAccount = targetWorkerServiceAccount
      requestDigest =
        sha256TargetValueDigest
          ( LazyByteString.toStrict
              ( serialise
                  ( workerRequestBinding
                      agentIdentity
                      serviceAccount
                      target
                      schema
                      imageDigest
                      signed
                  )
              )
          )
  pure
    TargetWorkerIntent
      { internalWorkerIntentTarget = target
      , internalWorkerIntentAgentIdentity = agentIdentity
      , internalWorkerIntentSchema = schema
      , internalWorkerIntentGeneration = targetIntentGeneration spec
      , internalWorkerIntentDeadline = targetIntentDeadline spec
      , internalWorkerIntentRequestDigest = requestDigest
      , internalWorkerIntentActionDigest = actionDigest
      , internalWorkerIntentImageDigest = imageDigest
      , internalWorkerIntentSignedBytes = signedBytes
      , internalWorkerIntentVerified = verified
      , internalWorkerIntentJobName = workerJobName requestDigest
      , internalWorkerIntentServiceAccount = serviceAccount
      }

workerRequestBinding
  :: TargetAgentIdentity
  -> Text
  -> TargetSecretId
  -> TargetWorkerIngressSchema
  -> TargetWorkerImageDigest
  -> SignedTargetCommittedIntent
  -> WireTargetWorkerRequestBinding
workerRequestBinding agentIdentity serviceAccount target schema image signed =
  WireTargetWorkerRequestBinding
    { wireWorkerBindingVersion = targetWorkerBindingVersion
    , wireWorkerBindingTarget = target
    , wireWorkerBindingAgentIdentity = targetAgentIdentityText agentIdentity
    , wireWorkerBindingSchema = schema
    , wireWorkerBindingImageDigest = targetWorkerImageDigestText image
    , wireWorkerBindingServiceAccount = serviceAccount
    , wireWorkerBindingSignedIntent = encodeSignedTargetCommittedIntent signed
    }

workerJobName :: TargetValueDigest -> Text
workerJobName digest =
  "target-secret-" <> Text.take 40 (Text.dropWhile (== ':') suffix)
 where
  token = targetValueDigestText digest
  suffix = maybe token id (Text.stripPrefix "sha256:" token)

targetWorkerIntentTarget :: TargetWorkerIntent -> TargetSecretId
targetWorkerIntentTarget = internalWorkerIntentTarget

targetWorkerIntentAgentIdentity :: TargetWorkerIntent -> TargetAgentIdentity
targetWorkerIntentAgentIdentity = internalWorkerIntentAgentIdentity

targetWorkerIntentSchema :: TargetWorkerIntent -> TargetWorkerIngressSchema
targetWorkerIntentSchema = internalWorkerIntentSchema

targetWorkerIntentGeneration :: TargetWorkerIntent -> CredentialGeneration
targetWorkerIntentGeneration = internalWorkerIntentGeneration

targetWorkerIntentDeadline :: TargetWorkerIntent -> AuthorityTime
targetWorkerIntentDeadline = internalWorkerIntentDeadline

targetWorkerIntentFencingToken :: TargetWorkerIntent -> FencingToken
targetWorkerIntentFencingToken =
  targetIntentFencingToken . verifiedTargetIntentSpec . internalWorkerIntentVerified

targetWorkerIntentRequestDigest :: TargetWorkerIntent -> TargetValueDigest
targetWorkerIntentRequestDigest = internalWorkerIntentRequestDigest

targetWorkerIntentActionDigest :: TargetWorkerIntent -> TargetValueDigest
targetWorkerIntentActionDigest = internalWorkerIntentActionDigest

-- | The exact request commitment carried by the Authority signature.  The
-- synthetic TLS and federation targets interpret this as the digest of one
-- closed operation constructor and payload.
targetWorkerIntentAuthorizedOperationDigest
  :: TargetWorkerIntent -> TargetValueDigest
targetWorkerIntentAuthorizedOperationDigest =
  targetIntentCommitReceiptDigest . verifiedTargetIntentSpec . internalWorkerIntentVerified

targetWorkerIntentImageDigest :: TargetWorkerIntent -> TargetWorkerImageDigest
targetWorkerIntentImageDigest = internalWorkerIntentImageDigest

targetWorkerIntentSignedBytes :: TargetWorkerIntent -> ByteString
targetWorkerIntentSignedBytes = internalWorkerIntentSignedBytes

targetWorkerIntentJobName :: TargetWorkerIntent -> Text
targetWorkerIntentJobName = internalWorkerIntentJobName

targetWorkerIntentServiceAccount :: TargetWorkerIntent -> Text
targetWorkerIntentServiceAccount = internalWorkerIntentServiceAccount

data RawTargetWorkerPodObservation = RawTargetWorkerPodObservation
  { observedTargetWorkerJobName :: !Text
  , observedTargetWorkerJobUid :: !Text
  , observedTargetWorkerPodName :: !Text
  , observedTargetWorkerPodUid :: !Text
  , observedTargetWorkerImageDigest :: !Text
  , observedTargetWorkerServiceAccount :: !Text
  , observedTargetWorkerServiceAccountUid :: !Text
  , observedTargetWorkerTarget :: !Text
  , observedTargetWorkerAgentIdentity :: !Text
  , observedTargetWorkerSchema :: !Text
  , observedTargetWorkerRequestDigest :: !Text
  , observedTargetWorkerDeadlineMicros :: !Natural
  , observedTargetWorkerPhase :: !Text
  , observedTargetWorkerReady :: !Bool
  , observedTargetWorkerRestartCount :: !Natural
  , observedTargetWorkerDeletionTimestamp :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetWorkerAttestation = TargetWorkerAttestation
  { internalWorkerAttestedIntent :: !TargetWorkerIntent
  , internalWorkerAttestedJobUid :: !TargetWorkerJobUid
  , internalWorkerAttestedPodName :: !Text
  , internalWorkerAttestedPodUid :: !TargetWorkerPodUid
  , internalWorkerAttestedServiceAccountUid :: !TargetWorkerServiceAccountUid
  }

data TargetWorkerAttestationError
  = TargetWorkerAttestationDeadlineReached
  | TargetWorkerAttestationJobMismatch
  | TargetWorkerAttestationJobUidInvalid
  | TargetWorkerAttestationPodNameInvalid
  | TargetWorkerAttestationPodUidInvalid
  | TargetWorkerAttestationImageMismatch
  | TargetWorkerAttestationServiceAccountMismatch
  | TargetWorkerAttestationServiceAccountUidInvalid
  | TargetWorkerAttestationTargetMismatch
  | TargetWorkerAttestationAgentIdentityMismatch
  | TargetWorkerAttestationSchemaMismatch
  | TargetWorkerAttestationRequestMismatch
  | TargetWorkerAttestationDeadlineMismatch
  | TargetWorkerAttestationNotRunning
  | TargetWorkerAttestationNotReady
  | TargetWorkerAttestationRestarted
  | TargetWorkerAttestationDeleting
  deriving stock (Eq, Show)

allTargetWorkerAttestationErrors :: [TargetWorkerAttestationError]
allTargetWorkerAttestationErrors =
  [ TargetWorkerAttestationDeadlineReached
  , TargetWorkerAttestationJobMismatch
  , TargetWorkerAttestationJobUidInvalid
  , TargetWorkerAttestationPodNameInvalid
  , TargetWorkerAttestationPodUidInvalid
  , TargetWorkerAttestationImageMismatch
  , TargetWorkerAttestationServiceAccountMismatch
  , TargetWorkerAttestationServiceAccountUidInvalid
  , TargetWorkerAttestationTargetMismatch
  , TargetWorkerAttestationAgentIdentityMismatch
  , TargetWorkerAttestationSchemaMismatch
  , TargetWorkerAttestationRequestMismatch
  , TargetWorkerAttestationDeadlineMismatch
  , TargetWorkerAttestationNotRunning
  , TargetWorkerAttestationNotReady
  , TargetWorkerAttestationRestarted
  , TargetWorkerAttestationDeleting
  ]

renderTargetWorkerAttestationError :: TargetWorkerAttestationError -> Text
renderTargetWorkerAttestationError err = case err of
  TargetWorkerAttestationDeadlineReached -> "deadline-reached"
  TargetWorkerAttestationJobMismatch -> "job-mismatch"
  TargetWorkerAttestationJobUidInvalid -> "job-uid-invalid"
  TargetWorkerAttestationPodNameInvalid -> "pod-name-invalid"
  TargetWorkerAttestationPodUidInvalid -> "pod-uid-invalid"
  TargetWorkerAttestationImageMismatch -> "image-mismatch"
  TargetWorkerAttestationServiceAccountMismatch -> "service-account-mismatch"
  TargetWorkerAttestationServiceAccountUidInvalid -> "service-account-uid-invalid"
  TargetWorkerAttestationTargetMismatch -> "target-mismatch"
  TargetWorkerAttestationAgentIdentityMismatch -> "agent-identity-mismatch"
  TargetWorkerAttestationSchemaMismatch -> "schema-mismatch"
  TargetWorkerAttestationRequestMismatch -> "request-mismatch"
  TargetWorkerAttestationDeadlineMismatch -> "deadline-mismatch"
  TargetWorkerAttestationNotRunning -> "not-running"
  TargetWorkerAttestationNotReady -> "not-ready"
  TargetWorkerAttestationRestarted -> "restarted"
  TargetWorkerAttestationDeleting -> "deleting"

attestTargetWorkerPod
  :: AuthorityTime
  -> TargetWorkerIntent
  -> RawTargetWorkerPodObservation
  -> Either TargetWorkerAttestationError TargetWorkerAttestation
attestTargetWorkerPod now intent observed = do
  unless
    (authorityTimeMicros now < authorityTimeMicros (targetWorkerIntentDeadline intent))
    (Left TargetWorkerAttestationDeadlineReached)
  unless
    (observedTargetWorkerJobName observed == targetWorkerIntentJobName intent)
    (Left TargetWorkerAttestationJobMismatch)
  jobUid <-
    first
      (const TargetWorkerAttestationJobUidInvalid)
      (mkTargetWorkerJobUid (observedTargetWorkerJobUid observed))
  unless
    (validPodName (observedTargetWorkerPodName observed))
    (Left TargetWorkerAttestationPodNameInvalid)
  podUid <-
    first
      (const TargetWorkerAttestationPodUidInvalid)
      (mkTargetWorkerPodUid (observedTargetWorkerPodUid observed))
  unless
    ( observedTargetWorkerImageDigest observed
        == targetWorkerImageDigestText (targetWorkerIntentImageDigest intent)
    )
    (Left TargetWorkerAttestationImageMismatch)
  unless
    ( observedTargetWorkerServiceAccount observed
        == targetWorkerIntentServiceAccount intent
    )
    (Left TargetWorkerAttestationServiceAccountMismatch)
  serviceAccountUid <-
    first
      (const TargetWorkerAttestationServiceAccountUidInvalid)
      (mkTargetWorkerServiceAccountUid (observedTargetWorkerServiceAccountUid observed))
  unless
    ( observedTargetWorkerTarget observed
        == targetSecretIdToken (targetWorkerIntentTarget intent)
    )
    (Left TargetWorkerAttestationTargetMismatch)
  unless
    ( observedTargetWorkerAgentIdentity observed
        == targetAgentIdentityText (targetWorkerIntentAgentIdentity intent)
    )
    (Left TargetWorkerAttestationAgentIdentityMismatch)
  unless
    ( observedTargetWorkerSchema observed
        == targetWorkerSchemaToken (targetWorkerIntentSchema intent)
    )
    (Left TargetWorkerAttestationSchemaMismatch)
  unless
    ( observedTargetWorkerRequestDigest observed
        == targetValueDigestText (targetWorkerIntentRequestDigest intent)
    )
    (Left TargetWorkerAttestationRequestMismatch)
  unless
    ( observedTargetWorkerDeadlineMicros observed
        == authorityTimeMicros (targetWorkerIntentDeadline intent)
    )
    (Left TargetWorkerAttestationDeadlineMismatch)
  unless
    (observedTargetWorkerPhase observed == "Running")
    (Left TargetWorkerAttestationNotRunning)
  unless (observedTargetWorkerReady observed) (Left TargetWorkerAttestationNotReady)
  unless
    (observedTargetWorkerRestartCount observed == 0)
    (Left TargetWorkerAttestationRestarted)
  case observedTargetWorkerDeletionTimestamp observed of
    Nothing -> Right ()
    Just _ -> Left TargetWorkerAttestationDeleting
  pure
    TargetWorkerAttestation
      { internalWorkerAttestedIntent = intent
      , internalWorkerAttestedJobUid = jobUid
      , internalWorkerAttestedPodName = observedTargetWorkerPodName observed
      , internalWorkerAttestedPodUid = podUid
      , internalWorkerAttestedServiceAccountUid = serviceAccountUid
      }

validPodName :: Text -> Bool
validPodName value =
  not (Text.null value)
    && Text.length value <= 253
    && Text.all valid value
 where
  valid character =
    isAsciiLower character || isDigit character || character == '-' || character == '.'

targetWorkerAttestedPodUid :: TargetWorkerAttestation -> TargetWorkerPodUid
targetWorkerAttestedPodUid = internalWorkerAttestedPodUid

targetWorkerAttestedJobUid :: TargetWorkerAttestation -> TargetWorkerJobUid
targetWorkerAttestedJobUid = internalWorkerAttestedJobUid

targetWorkerAttestedPodName :: TargetWorkerAttestation -> Text
targetWorkerAttestedPodName = internalWorkerAttestedPodName

targetWorkerAttestedServiceAccountUid
  :: TargetWorkerAttestation -> TargetWorkerServiceAccountUid
targetWorkerAttestedServiceAccountUid = internalWorkerAttestedServiceAccountUid

targetWorkerAttestedIntent :: TargetWorkerAttestation -> TargetWorkerIntent
targetWorkerAttestedIntent = internalWorkerAttestedIntent

data TargetWorkerReceipt = TargetWorkerReceipt
  { internalWorkerReceiptTarget :: !TargetSecretId
  , internalWorkerReceiptGeneration :: !CredentialGeneration
  , internalWorkerReceiptVaultVersion :: !Natural
  , internalWorkerReceiptCommitment :: !Text
  , internalWorkerReceiptRequestDigest :: !TargetValueDigest
  , internalWorkerReceiptActionDigest :: !TargetValueDigest
  , internalWorkerReceiptPodUid :: !TargetWorkerPodUid
  , internalWorkerReceiptImageDigest :: !TargetWorkerImageDigest
  }
  deriving stock (Eq, Show)

data WireTargetWorkerReceipt = WireTargetWorkerReceipt
  { wireWorkerReceiptVersion :: !Word16
  , wireWorkerReceiptTarget :: !TargetSecretId
  , wireWorkerReceiptGeneration :: !Natural
  , wireWorkerReceiptVaultVersion :: !Natural
  , wireWorkerReceiptCommitment :: !Text
  , wireWorkerReceiptRequestDigest :: !Text
  , wireWorkerReceiptActionDigest :: !Text
  , wireWorkerReceiptPodUid :: !Text
  , wireWorkerReceiptImageDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetWorkerReceiptError
  = TargetWorkerReceiptTooLarge !Int !Int
  | TargetWorkerReceiptDecodeFailed
  | TargetWorkerReceiptUnsupportedVersion !Word16
  | TargetWorkerReceiptValueInvalid !Text
  | TargetWorkerReceiptNonCanonical
  deriving stock (Eq, Show)

mkTargetWorkerReceiptProjection
  :: TargetSecretId
  -> CredentialGeneration
  -> Natural
  -> Text
  -> TargetValueDigest
  -> TargetValueDigest
  -> Text
  -> Text
  -> Either TargetWorkerReceiptError TargetWorkerReceipt
mkTargetWorkerReceiptProjection target generation vaultVersion commitment requestDigest actionDigest podUid imageDigest =
  receiptFromWire
    WireTargetWorkerReceipt
      { wireWorkerReceiptVersion = targetWorkerReceiptVersion
      , wireWorkerReceiptTarget = target
      , wireWorkerReceiptGeneration = credentialGenerationValue generation
      , wireWorkerReceiptVaultVersion = vaultVersion
      , wireWorkerReceiptCommitment = commitment
      , wireWorkerReceiptRequestDigest = targetValueDigestText requestDigest
      , wireWorkerReceiptActionDigest = targetValueDigestText actionDigest
      , wireWorkerReceiptPodUid = podUid
      , wireWorkerReceiptImageDigest = imageDigest
      }

targetWorkerReceiptMaximumBytes :: Int
targetWorkerReceiptMaximumBytes = 16 * 1024

targetWorkerReceiptVersion :: Word16
targetWorkerReceiptVersion = 1

encodeTargetWorkerReceipt :: TargetWorkerReceipt -> ByteString
encodeTargetWorkerReceipt = LazyByteString.toStrict . serialise . receiptWire

decodeTargetWorkerReceipt
  :: ByteString -> Either TargetWorkerReceiptError TargetWorkerReceipt
decodeTargetWorkerReceipt bytes
  | ByteString.length bytes > targetWorkerReceiptMaximumBytes =
      Left
        ( TargetWorkerReceiptTooLarge
            (ByteString.length bytes)
            targetWorkerReceiptMaximumBytes
        )
  | otherwise = do
      wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left TargetWorkerReceiptDecodeFailed
        Right decoded -> Right decoded
      unless
        (wireWorkerReceiptVersion wire == targetWorkerReceiptVersion)
        (Left (TargetWorkerReceiptUnsupportedVersion (wireWorkerReceiptVersion wire)))
      receipt <- receiptFromWire wire
      unless (encodeTargetWorkerReceipt receipt == bytes) (Left TargetWorkerReceiptNonCanonical)
      pure receipt

receiptWire :: TargetWorkerReceipt -> WireTargetWorkerReceipt
receiptWire receipt =
  WireTargetWorkerReceipt
    { wireWorkerReceiptVersion = targetWorkerReceiptVersion
    , wireWorkerReceiptTarget = internalWorkerReceiptTarget receipt
    , wireWorkerReceiptGeneration =
        credentialGenerationValue (internalWorkerReceiptGeneration receipt)
    , wireWorkerReceiptVaultVersion = internalWorkerReceiptVaultVersion receipt
    , wireWorkerReceiptCommitment = internalWorkerReceiptCommitment receipt
    , wireWorkerReceiptRequestDigest =
        targetValueDigestText (internalWorkerReceiptRequestDigest receipt)
    , wireWorkerReceiptActionDigest =
        targetValueDigestText (internalWorkerReceiptActionDigest receipt)
    , wireWorkerReceiptPodUid = targetWorkerPodUidText (internalWorkerReceiptPodUid receipt)
    , wireWorkerReceiptImageDigest =
        targetWorkerImageDigestText (internalWorkerReceiptImageDigest receipt)
    }

receiptFromWire
  :: WireTargetWorkerReceipt -> Either TargetWorkerReceiptError TargetWorkerReceipt
receiptFromWire wire = do
  generation <- value (mkCredentialGeneration (wireWorkerReceiptGeneration wire))
  unless
    (wireWorkerReceiptVaultVersion wire > 0)
    (Left (TargetWorkerReceiptValueInvalid "Vault version must be positive"))
  commitment <- validateCommitment (wireWorkerReceiptCommitment wire)
  requestDigest <- value (mkTargetValueDigest (wireWorkerReceiptRequestDigest wire))
  actionDigest <- value (mkTargetValueDigest (wireWorkerReceiptActionDigest wire))
  podUid <- valueText (mkTargetWorkerPodUid (wireWorkerReceiptPodUid wire))
  image <- valueText (mkTargetWorkerImageDigest (wireWorkerReceiptImageDigest wire))
  pure
    TargetWorkerReceipt
      { internalWorkerReceiptTarget = wireWorkerReceiptTarget wire
      , internalWorkerReceiptGeneration = generation
      , internalWorkerReceiptVaultVersion = wireWorkerReceiptVaultVersion wire
      , internalWorkerReceiptCommitment = commitment
      , internalWorkerReceiptRequestDigest = requestDigest
      , internalWorkerReceiptActionDigest = actionDigest
      , internalWorkerReceiptPodUid = podUid
      , internalWorkerReceiptImageDigest = image
      }
 where
  value = first (TargetWorkerReceiptValueInvalid . Text.pack . show)
  valueText = first TargetWorkerReceiptValueInvalid

validateCommitment :: Text -> Either TargetWorkerReceiptError Text
validateCommitment value
  | Text.null value = Left (TargetWorkerReceiptValueInvalid "commitment is empty")
  | Text.length value > 512 = Left (TargetWorkerReceiptValueInvalid "commitment is over bound")
  | not ("vault:v" `Text.isPrefixOf` value) =
      Left (TargetWorkerReceiptValueInvalid "commitment is not a Vault HMAC")
  | Text.any (\character -> isControl character || isSpace character) value =
      Left (TargetWorkerReceiptValueInvalid "commitment is invalid")
  | otherwise = Right value

targetWorkerReceiptTarget :: TargetWorkerReceipt -> TargetSecretId
targetWorkerReceiptTarget = internalWorkerReceiptTarget

targetWorkerReceiptGeneration :: TargetWorkerReceipt -> CredentialGeneration
targetWorkerReceiptGeneration = internalWorkerReceiptGeneration

targetWorkerReceiptVaultVersion :: TargetWorkerReceipt -> Natural
targetWorkerReceiptVaultVersion = internalWorkerReceiptVaultVersion

targetWorkerReceiptCommitment :: TargetWorkerReceipt -> Text
targetWorkerReceiptCommitment = internalWorkerReceiptCommitment

targetWorkerReceiptRequestDigest :: TargetWorkerReceipt -> TargetValueDigest
targetWorkerReceiptRequestDigest = internalWorkerReceiptRequestDigest

targetWorkerReceiptPodUid :: TargetWorkerReceipt -> TargetWorkerPodUid
targetWorkerReceiptPodUid = internalWorkerReceiptPodUid

-- | Exact secret-free receipt binding checked before a Provisioner may commit
-- its own durable handoff receipt or retire the source credential.
targetWorkerReceiptMatchesAttestation
  :: TargetWorkerAttestation -> TargetWorkerReceipt -> Bool
targetWorkerReceiptMatchesAttestation attestation receipt =
  internalWorkerReceiptTarget receipt == targetWorkerIntentTarget intent
    && internalWorkerReceiptGeneration receipt == targetWorkerIntentGeneration intent
    && internalWorkerReceiptRequestDigest receipt == targetWorkerIntentRequestDigest intent
    && internalWorkerReceiptActionDigest receipt == targetWorkerIntentActionDigest intent
    && internalWorkerReceiptPodUid receipt == targetWorkerAttestedPodUid attestation
    && internalWorkerReceiptImageDigest receipt == targetWorkerIntentImageDigest intent
    && internalWorkerReceiptVaultVersion receipt > 0
 where
  intent = targetWorkerAttestedIntent attestation

-- | Arm-indexed, secret-safe successful output.  The constructor proves which
-- request family produced the value; a TLS envelope or federation
-- acknowledgement cannot be mistaken for a KV materialization receipt.
data TargetWorkerOperationResult
  = TargetWorkerMaterializedResult !TargetWorkerReceipt
  | TargetWorkerTlsPreparedResult !TlsDekPrepared
  | TargetWorkerTlsRetainedResult !TlsTargetRetainReceipt
  | TargetWorkerTlsRetainMissingResult
  | TargetWorkerTlsHomeWrappedResult !TlsWrappedDek
  | TargetWorkerTlsHomeRewrappedResult !TlsDekEnvelope
  | TargetWorkerTlsRestoredResult !TlsTargetRestoreReceipt
  | TargetWorkerTlsVerifiedResult !TlsTargetVerifyReceipt
  | TargetWorkerTlsVerifyMissingResult
  | TargetWorkerTlsVerifyMismatchResult
  | TargetWorkerFederationCustodyCommittedResult !ParentCustodyAcknowledgement
  | TargetWorkerFederationRecoveryPreparedResult !ChildRecoveryDelivery
  | TargetWorkerFederationRecoveryObservedResult !ChildRecoveryConsumptionObservation
  | TargetWorkerFederationRecoveryCommittedResult !ChildRecoveryConsumptionObservation
  deriving stock (Eq)

instance Show TargetWorkerOperationResult where
  show result = case result of
    TargetWorkerMaterializedResult receipt ->
      "TargetWorkerMaterializedResult " <> show receipt
    TargetWorkerTlsPreparedResult {} -> "TargetWorkerTlsPreparedResult <redacted>"
    TargetWorkerTlsRetainedResult {} -> "TargetWorkerTlsRetainedResult <ciphertext>"
    TargetWorkerTlsRetainMissingResult -> "TargetWorkerTlsRetainMissingResult"
    TargetWorkerTlsHomeWrappedResult {} -> "TargetWorkerTlsHomeWrappedResult <ciphertext>"
    TargetWorkerTlsHomeRewrappedResult {} -> "TargetWorkerTlsHomeRewrappedResult <ciphertext>"
    TargetWorkerTlsRestoredResult {} -> "TargetWorkerTlsRestoredResult"
    TargetWorkerTlsVerifiedResult {} -> "TargetWorkerTlsVerifiedResult"
    TargetWorkerTlsVerifyMissingResult -> "TargetWorkerTlsVerifyMissingResult"
    TargetWorkerTlsVerifyMismatchResult -> "TargetWorkerTlsVerifyMismatchResult"
    TargetWorkerFederationCustodyCommittedResult {} ->
      "TargetWorkerFederationCustodyCommittedResult"
    TargetWorkerFederationRecoveryPreparedResult {} ->
      "TargetWorkerFederationRecoveryPreparedResult <ciphertext>"
    TargetWorkerFederationRecoveryObservedResult {} ->
      "TargetWorkerFederationRecoveryObservedResult"
    TargetWorkerFederationRecoveryCommittedResult {} ->
      "TargetWorkerFederationRecoveryCommittedResult"

targetWorkerOperationResultMatchesSchema
  :: TargetWorkerIngressSchema -> TargetWorkerOperationResult -> Bool
targetWorkerOperationResultMatchesSchema schema result = case (schema, result) of
  (TargetWorkerDirectAws, TargetWorkerMaterializedResult {}) -> True
  (TargetWorkerRewrappedSesSmtp, TargetWorkerMaterializedResult {}) -> True
  (TargetWorkerRewrappedAcmeEab, TargetWorkerMaterializedResult {}) -> True
  (TargetWorkerTlsPrepare, TargetWorkerTlsPreparedResult {}) -> True
  (TargetWorkerTlsRetain, TargetWorkerTlsRetainedResult {}) -> True
  (TargetWorkerTlsRetain, TargetWorkerTlsRetainMissingResult) -> True
  (TargetWorkerTlsHomeWrap, TargetWorkerTlsHomeWrappedResult {}) -> True
  (TargetWorkerTlsHomeRewrap, TargetWorkerTlsHomeRewrappedResult {}) -> True
  (TargetWorkerTlsRestore, TargetWorkerTlsRestoredResult {}) -> True
  (TargetWorkerTlsVerify, TargetWorkerTlsVerifiedResult {}) -> True
  (TargetWorkerTlsVerify, TargetWorkerTlsVerifyMissingResult) -> True
  (TargetWorkerTlsVerify, TargetWorkerTlsVerifyMismatchResult) -> True
  ( TargetWorkerFederationCustodyCommit
    , TargetWorkerFederationCustodyCommittedResult {}
    ) -> True
  ( TargetWorkerFederationRecoveryPrepare
    , TargetWorkerFederationRecoveryPreparedResult {}
    ) -> True
  ( TargetWorkerFederationRecoveryObserve
    , TargetWorkerFederationRecoveryObservedResult {}
    ) -> True
  ( TargetWorkerFederationRecoveryCommit
    , TargetWorkerFederationRecoveryCommittedResult {}
    ) -> True
  _ -> False

data WireTargetWorkerOperationResult
  = WireTargetWorkerMaterializedResult !ByteString
  | WireTargetWorkerTlsPreparedResult !TlsDekPrepared
  | WireTargetWorkerTlsRetainedResult !TlsTargetRetainReceipt
  | WireTargetWorkerTlsRetainMissingResult
  | WireTargetWorkerTlsHomeWrappedResult !TlsWrappedDek
  | WireTargetWorkerTlsHomeRewrappedResult !TlsDekEnvelope
  | WireTargetWorkerTlsRestoredResult !TlsTargetRestoreReceipt
  | WireTargetWorkerTlsVerifiedResult !TlsTargetVerifyReceipt
  | WireTargetWorkerTlsVerifyMissingResult
  | WireTargetWorkerTlsVerifyMismatchResult
  | WireTargetWorkerFederationCustodyCommittedResult !ParentCustodyAcknowledgement
  | WireTargetWorkerFederationRecoveryPreparedResult !ChildRecoveryDelivery
  | WireTargetWorkerFederationRecoveryObservedResult !ChildRecoveryConsumptionObservation
  | WireTargetWorkerFederationRecoveryCommittedResult !ChildRecoveryConsumptionObservation
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

data TargetWorkerProvisionalCompletion = TargetWorkerProvisionalCompletion
  { internalProvisionalResult :: !(Maybe TargetWorkerOperationResult)
  , internalProvisionalAccessor :: !Text
  , internalProvisionalRefusal :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data WireTargetWorkerProvisionalCompletion = WireTargetWorkerProvisionalCompletion
  { wireProvisionalVersion :: !Word16
  , wireProvisionalResult :: !(Maybe WireTargetWorkerOperationResult)
  , wireProvisionalAccessor :: !Text
  , wireProvisionalRefusal :: !(Maybe Text)
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

data TargetWorkerProvisionalCompletionError
  = TargetWorkerProvisionalTooLarge
  | TargetWorkerProvisionalDecodeFailed
  | TargetWorkerProvisionalUnsupportedVersion !Word16
  | TargetWorkerProvisionalAccessorInvalid
  | TargetWorkerProvisionalOutcomeInvalid
  | TargetWorkerProvisionalReceiptInvalid !TargetWorkerReceiptError
  | TargetWorkerProvisionalNonCanonical
  deriving stock (Eq, Show)

targetWorkerProvisionalCompletionMaximumBytes :: Int
targetWorkerProvisionalCompletionMaximumBytes = 8 * 1024 * 1024

successfulTargetWorkerProvisionalCompletion
  :: Text -> TargetWorkerReceipt -> Either Text TargetWorkerProvisionalCompletion
successfulTargetWorkerProvisionalCompletion accessor receipt = do
  validated <- validateSessionAccessor accessor
  Right
    TargetWorkerProvisionalCompletion
      { internalProvisionalResult = Just (TargetWorkerMaterializedResult receipt)
      , internalProvisionalAccessor = validated
      , internalProvisionalRefusal = Nothing
      }

successfulTargetWorkerOperationProvisionalCompletion
  :: Text
  -> TargetWorkerOperationResult
  -> Either Text TargetWorkerProvisionalCompletion
successfulTargetWorkerOperationProvisionalCompletion accessor result = do
  validated <- validateSessionAccessor accessor
  Right
    TargetWorkerProvisionalCompletion
      { internalProvisionalResult = Just result
      , internalProvisionalAccessor = validated
      , internalProvisionalRefusal = Nothing
      }

refusedTargetWorkerProvisionalCompletion
  :: Text -> Text -> Either Text TargetWorkerProvisionalCompletion
refusedTargetWorkerProvisionalCompletion accessor refusal = do
  validatedAccessor <- validateSessionAccessor accessor
  validatedRefusal <- validateRefusal refusal
  Right
    TargetWorkerProvisionalCompletion
      { internalProvisionalResult = Nothing
      , internalProvisionalAccessor = validatedAccessor
      , internalProvisionalRefusal = Just validatedRefusal
      }

operationResultWire
  :: TargetWorkerOperationResult -> WireTargetWorkerOperationResult
operationResultWire result = case result of
  TargetWorkerMaterializedResult receipt ->
    WireTargetWorkerMaterializedResult (encodeTargetWorkerReceipt receipt)
  TargetWorkerTlsPreparedResult prepared -> WireTargetWorkerTlsPreparedResult prepared
  TargetWorkerTlsRetainedResult receipt -> WireTargetWorkerTlsRetainedResult receipt
  TargetWorkerTlsRetainMissingResult -> WireTargetWorkerTlsRetainMissingResult
  TargetWorkerTlsHomeWrappedResult wrapped ->
    WireTargetWorkerTlsHomeWrappedResult wrapped
  TargetWorkerTlsHomeRewrappedResult envelope ->
    WireTargetWorkerTlsHomeRewrappedResult envelope
  TargetWorkerTlsRestoredResult receipt -> WireTargetWorkerTlsRestoredResult receipt
  TargetWorkerTlsVerifiedResult receipt -> WireTargetWorkerTlsVerifiedResult receipt
  TargetWorkerTlsVerifyMissingResult -> WireTargetWorkerTlsVerifyMissingResult
  TargetWorkerTlsVerifyMismatchResult -> WireTargetWorkerTlsVerifyMismatchResult
  TargetWorkerFederationCustodyCommittedResult acknowledgement ->
    WireTargetWorkerFederationCustodyCommittedResult acknowledgement
  TargetWorkerFederationRecoveryPreparedResult delivery ->
    WireTargetWorkerFederationRecoveryPreparedResult delivery
  TargetWorkerFederationRecoveryObservedResult observation ->
    WireTargetWorkerFederationRecoveryObservedResult observation
  TargetWorkerFederationRecoveryCommittedResult observation ->
    WireTargetWorkerFederationRecoveryCommittedResult observation

operationResultFromWire
  :: WireTargetWorkerOperationResult
  -> Either TargetWorkerProvisionalCompletionError TargetWorkerOperationResult
operationResultFromWire wire = case wire of
  WireTargetWorkerMaterializedResult bytes ->
    TargetWorkerMaterializedResult
      <$> first TargetWorkerProvisionalReceiptInvalid (decodeTargetWorkerReceipt bytes)
  WireTargetWorkerTlsPreparedResult prepared ->
    Right (TargetWorkerTlsPreparedResult prepared)
  WireTargetWorkerTlsRetainedResult receipt ->
    Right (TargetWorkerTlsRetainedResult receipt)
  WireTargetWorkerTlsRetainMissingResult ->
    Right TargetWorkerTlsRetainMissingResult
  WireTargetWorkerTlsHomeWrappedResult wrapped ->
    Right (TargetWorkerTlsHomeWrappedResult wrapped)
  WireTargetWorkerTlsHomeRewrappedResult envelope ->
    Right (TargetWorkerTlsHomeRewrappedResult envelope)
  WireTargetWorkerTlsRestoredResult receipt ->
    Right (TargetWorkerTlsRestoredResult receipt)
  WireTargetWorkerTlsVerifiedResult receipt ->
    Right (TargetWorkerTlsVerifiedResult receipt)
  WireTargetWorkerTlsVerifyMissingResult ->
    Right TargetWorkerTlsVerifyMissingResult
  WireTargetWorkerTlsVerifyMismatchResult ->
    Right TargetWorkerTlsVerifyMismatchResult
  WireTargetWorkerFederationCustodyCommittedResult acknowledgement ->
    Right (TargetWorkerFederationCustodyCommittedResult acknowledgement)
  WireTargetWorkerFederationRecoveryPreparedResult delivery ->
    Right (TargetWorkerFederationRecoveryPreparedResult delivery)
  WireTargetWorkerFederationRecoveryObservedResult observation ->
    Right (TargetWorkerFederationRecoveryObservedResult observation)
  WireTargetWorkerFederationRecoveryCommittedResult observation ->
    Right (TargetWorkerFederationRecoveryCommittedResult observation)

encodeTargetWorkerProvisionalCompletion
  :: TargetWorkerProvisionalCompletion -> ByteString
encodeTargetWorkerProvisionalCompletion completion =
  LazyByteString.toStrict
    ( serialise
        WireTargetWorkerProvisionalCompletion
          { wireProvisionalVersion = 2
          , wireProvisionalResult =
              operationResultWire <$> internalProvisionalResult completion
          , wireProvisionalAccessor = internalProvisionalAccessor completion
          , wireProvisionalRefusal = internalProvisionalRefusal completion
          }
    )

decodeTargetWorkerProvisionalCompletion
  :: ByteString
  -> Either TargetWorkerProvisionalCompletionError TargetWorkerProvisionalCompletion
decodeTargetWorkerProvisionalCompletion bytes
  | ByteString.length bytes > targetWorkerProvisionalCompletionMaximumBytes =
      Left TargetWorkerProvisionalTooLarge
  | otherwise = do
      wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left TargetWorkerProvisionalDecodeFailed
        Right value -> Right value
      unless
        (wireProvisionalVersion wire == 2)
        (Left (TargetWorkerProvisionalUnsupportedVersion (wireProvisionalVersion wire)))
      accessor <-
        first
          (const TargetWorkerProvisionalAccessorInvalid)
          (validateSessionAccessor (wireProvisionalAccessor wire))
      result <-
        traverse
          operationResultFromWire
          (wireProvisionalResult wire)
      refusal <-
        traverse
          (first (const TargetWorkerProvisionalOutcomeInvalid) . validateRefusal)
          (wireProvisionalRefusal wire)
      unless
        ( case (result, refusal) of
            (Just _, Nothing) -> True
            (Nothing, Just _) -> True
            _ -> False
        )
        (Left TargetWorkerProvisionalOutcomeInvalid)
      let completion =
            TargetWorkerProvisionalCompletion
              { internalProvisionalResult = result
              , internalProvisionalAccessor = accessor
              , internalProvisionalRefusal = refusal
              }
      unless
        (encodeTargetWorkerProvisionalCompletion completion == bytes)
        (Left TargetWorkerProvisionalNonCanonical)
      Right completion

targetWorkerProvisionalReceipt
  :: TargetWorkerProvisionalCompletion -> Maybe TargetWorkerReceipt
targetWorkerProvisionalReceipt completion = case internalProvisionalResult completion of
  Just (TargetWorkerMaterializedResult receipt) -> Just receipt
  _ -> Nothing

targetWorkerProvisionalResult
  :: TargetWorkerProvisionalCompletion -> Maybe TargetWorkerOperationResult
targetWorkerProvisionalResult = internalProvisionalResult

targetWorkerProvisionalAccessor :: TargetWorkerProvisionalCompletion -> Text
targetWorkerProvisionalAccessor = internalProvisionalAccessor

targetWorkerProvisionalRefusal :: TargetWorkerProvisionalCompletion -> Maybe Text
targetWorkerProvisionalRefusal = internalProvisionalRefusal

-- | Fixed non-secret second-stage acknowledgement.  The coordinator releases
-- it only after the server-issued accessor is classified against the exact
-- attested ServiceAccount UID and @Active@ is durable.
targetWorkerCleanupAuthorization :: ByteString
targetWorkerCleanupAuthorization = "prodbox-target-worker-cleanup-authorized-v1"

-- | Fixed non-secret worker acknowledgement emitted only after both session
-- revocation and stable accessor absence have completed.
targetWorkerCleanupCompletion :: ByteString
targetWorkerCleanupCompletion = "prodbox-target-worker-cleanup-complete-v1"

validateSessionAccessor :: Text -> Either Text Text
validateSessionAccessor raw
  | Text.null value = Left "worker session accessor is empty"
  | Text.length value > 512 = Left "worker session accessor is over bound"
  | Text.any (\character -> isControl character || isSpace character) value =
      Left "worker session accessor is invalid"
  | otherwise = Right value
 where
  value = Text.strip raw

validateRefusal :: Text -> Either Text Text
validateRefusal raw
  | Text.null value = Left "worker refusal is empty"
  | Text.length value > 128 = Left "worker refusal is over bound"
  | Text.any isControl value = Left "worker refusal is invalid"
  | otherwise = Right value
 where
  value = Text.strip raw

data TargetWorkerDataObservation
  = TargetWorkerDataMissing
  | TargetWorkerDataPresent !Natural !(Map Text Text)
  deriving stock (Eq, Show)

data TargetWorkerMetadataObservation
  = TargetWorkerMetadataMissing
  | TargetWorkerMetadataPresent !Natural !(Map Text Text)
  deriving stock (Eq, Show)

data TargetWorkerVaultBoundary m = TargetWorkerVaultBoundary
  { targetWorkerReadData
      :: TargetSecretId
      -> m (Either Text TargetWorkerDataObservation)
  , targetWorkerReadMetadata
      :: TargetSecretId
      -> m (Either Text TargetWorkerMetadataObservation)
  , targetWorkerCommitmentHmac
      :: ByteString
      -> m (Either Text Text)
  , targetWorkerCompareAndSwap
      :: TargetSecretId
      -> Natural
      -> Map Text Text
      -> m (Either Text Natural)
  , targetWorkerWriteMetadata
      :: TargetSecretId
      -> Map Text Text
      -> m (Either Text ())
  }

data TargetWorkerMaterializationResult
  = TargetWorkerMaterializationApplied !TargetWorkerReceipt
  | TargetWorkerMaterializationAlreadyApplied !TargetWorkerReceipt
  | TargetWorkerMaterializationRecovered !TargetWorkerReceipt
  deriving stock (Eq, Show)

data TargetWorkerExecutionError
  = TargetWorkerExecutionDeadlineReached
  | TargetWorkerExecutionPayloadInvalid !Text
  | TargetWorkerExecutionPayloadTargetMismatch
  | TargetWorkerExecutionCommitmentUnavailable !Text
  | TargetWorkerExecutionCommitmentInvalid
  | TargetWorkerExecutionDataUnavailable !Text
  | TargetWorkerExecutionMetadataUnavailable !Text
  | TargetWorkerExecutionMetadataInvalid
  | TargetWorkerExecutionGenerationNewer !Natural !Natural
  | TargetWorkerExecutionGenerationCollision !Natural
  | TargetWorkerExecutionUnownedExistingData
  | TargetWorkerExecutionCompareAndSwapFailed !Text
  | TargetWorkerExecutionDataReadBackMismatch
  | TargetWorkerExecutionMetadataWriteFailed !Text
  | TargetWorkerExecutionMetadataReadBackMismatch
  | TargetWorkerExecutionSessionRevocationFailed
  deriving stock (Eq, Show)

data WireTargetWorkerCommitment = WireTargetWorkerCommitment
  { wireCommitmentVersion :: !Word16
  , wireCommitmentTarget :: !TargetSecretId
  , wireCommitmentGeneration :: !Natural
  , wireCommitmentRequestDigest :: !Text
  , wireCommitmentActionDigest :: !Text
  , wireCommitmentFields :: !(Map Text Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

executeTargetWorkerMaterialization
  :: (Monad m)
  => AuthorityTime
  -> TargetWorkerVaultBoundary m
  -> TargetWorkerAttestation
  -> TargetSecretPayload
  -> m (Either TargetWorkerExecutionError TargetWorkerMaterializationResult)
executeTargetWorkerMaterialization now boundary attestation payload
  | authorityTimeMicros now
      >= authorityTimeMicros (targetWorkerIntentDeadline intent) =
      pure (Left TargetWorkerExecutionDeadlineReached)
  | targetSecretPayloadId payload /= targetWorkerIntentTarget intent =
      pure (Left TargetWorkerExecutionPayloadTargetMismatch)
  | otherwise = case targetSecretPayloadToVaultFields payload of
      Left detail -> pure (Left (TargetWorkerExecutionPayloadInvalid detail))
      Right fields -> executeFields fields
 where
  intent = targetWorkerAttestedIntent attestation
  target = targetWorkerIntentTarget intent
  expectedGeneration = credentialGenerationValue (targetWorkerIntentGeneration intent)
  spec = verifiedTargetIntentSpec (internalWorkerIntentVerified intent)

  executeFields fields = do
    commitmentResult <-
      targetWorkerCommitmentHmac boundary (commitmentInput intent fields)
    case commitmentResult of
      Left detail -> pure (Left (TargetWorkerExecutionCommitmentUnavailable detail))
      Right commitment -> case validateCommitment commitment of
        Left _ -> pure (Left TargetWorkerExecutionCommitmentInvalid)
        Right _ -> observeAndCommit fields commitment

  observeAndCommit fields commitment = do
    dataResult <- targetWorkerReadData boundary target
    metadataResult <- targetWorkerReadMetadata boundary target
    case (dataResult, metadataResult) of
      (Left detail, _) -> pure (Left (TargetWorkerExecutionDataUnavailable detail))
      (_, Left detail) -> pure (Left (TargetWorkerExecutionMetadataUnavailable detail))
      (Right dataObservation, Right metadataObservation) ->
        decide dataObservation metadataObservation fields commitment

  decide dataObservation metadataObservation fields commitment =
    case metadataGenerationCommitment metadataObservation of
      Left err -> pure (Left err)
      Right (Just (observedGeneration, observedCommitment))
        | observedGeneration > expectedGeneration ->
            pure
              ( Left
                  ( TargetWorkerExecutionGenerationNewer
                      observedGeneration
                      expectedGeneration
                  )
              )
        | observedGeneration == expectedGeneration
            && observedCommitment /= commitment ->
            pure (Left (TargetWorkerExecutionGenerationCollision expectedGeneration))
        | observedGeneration == expectedGeneration ->
            confirmAlready dataObservation metadataObservation fields commitment
        | otherwise -> advance dataObservation fields commitment
      Right Nothing -> case dataObservation of
        TargetWorkerDataMissing -> applyCas 0 fields commitment TargetWorkerMaterializationApplied
        TargetWorkerDataPresent _ observedFields
          | observedFields == fields ->
              repairMetadata dataObservation fields commitment
          | otherwise -> pure (Left TargetWorkerExecutionUnownedExistingData)

  advance dataObservation fields commitment = case dataObservation of
    TargetWorkerDataMissing -> applyCas 0 fields commitment TargetWorkerMaterializationApplied
    TargetWorkerDataPresent version observedFields
      | observedFields == fields -> repairMetadata dataObservation fields commitment
      | otherwise ->
          applyCas version fields commitment TargetWorkerMaterializationApplied

  confirmAlready dataObservation metadataObservation fields commitment =
    case (dataObservation, metadataObservation) of
      (TargetWorkerDataPresent version observedFields, TargetWorkerMetadataPresent metadataVersion custom)
        | observedFields == fields
            && metadataVersion == version
            && custom == expectedMetadata version commitment ->
            pure
              ( Right
                  ( TargetWorkerMaterializationAlreadyApplied
                      (receipt version commitment)
                  )
              )
        | observedFields == fields
            && metadataVersion == version
            && custom == legacyExpectedMetadata commitment ->
            repairMetadata dataObservation fields commitment
      _ -> pure (Left TargetWorkerExecutionDataReadBackMismatch)

  repairMetadata dataObservation fields commitment = case dataObservation of
    TargetWorkerDataMissing -> pure (Left TargetWorkerExecutionDataReadBackMismatch)
    TargetWorkerDataPresent version observedFields
      | observedFields /= fields -> pure (Left TargetWorkerExecutionDataReadBackMismatch)
      | otherwise -> do
          published <- publishAndReadBack version fields commitment
          pure (TargetWorkerMaterializationRecovered <$> published)

  applyCas expectedVersion fields commitment constructor = do
    attempted <-
      targetWorkerCompareAndSwap boundary target expectedVersion fields
    case attempted of
      Right writtenVersion -> do
        published <- publishAndReadBack writtenVersion fields commitment
        pure (constructor <$> published)
      Left detail -> do
        -- Response loss after a successful CAS is recovered only through an
        -- authoritative exact data read-back.  There is never a blind retry.
        readBack <- targetWorkerReadData boundary target
        case readBack of
          Right (TargetWorkerDataPresent version observedFields)
            | observedFields == fields && version > expectedVersion -> do
                published <- publishAndReadBack version fields commitment
                pure (TargetWorkerMaterializationRecovered <$> published)
          _ -> pure (Left (TargetWorkerExecutionCompareAndSwapFailed detail))

  publishAndReadBack version fields commitment = do
    dataReadBack <- targetWorkerReadData boundary target
    case dataReadBack of
      Right (TargetWorkerDataPresent observedVersion observedFields)
        | observedVersion == version && observedFields == fields -> do
            written <-
              targetWorkerWriteMetadata boundary target (expectedMetadata version commitment)
            case written of
              Left detail -> pure (Left (TargetWorkerExecutionMetadataWriteFailed detail))
              Right () -> do
                metadataReadBack <- targetWorkerReadMetadata boundary target
                pure $ case metadataReadBack of
                  Right (TargetWorkerMetadataPresent metadataVersion custom)
                    | metadataVersion == version
                        && custom == expectedMetadata version commitment ->
                        Right (receipt version commitment)
                  _ -> Left TargetWorkerExecutionMetadataReadBackMismatch
      _ -> pure (Left TargetWorkerExecutionDataReadBackMismatch)

  expectedMetadata version commitment =
    Map.fromList
      [ (targetMaterialMetadataGenerationField, naturalText expectedGeneration)
      , (targetMaterialMetadataVaultVersionField, naturalText version)
      , (targetMaterialMetadataCommitmentField, commitment)
      , (targetMaterialMetadataOwnerNonceField, ownerNonceText (targetIntentOwnerNonce spec))
      ,
        ( targetMaterialMetadataFencingTokenField
        , naturalText (fencingTokenValue (targetIntentFencingToken spec))
        )
      ,
        ( targetMaterialMetadataRequestDigestField
        , targetValueDigestText (targetWorkerIntentRequestDigest intent)
        )
      ,
        ( targetMaterialMetadataActionDigestField
        , targetValueDigestText (targetWorkerIntentActionDigest intent)
        )
      , (targetMaterialMetadataPodUidField, targetWorkerPodUidText (targetWorkerAttestedPodUid attestation))
      ,
        ( targetMaterialMetadataImageDigestField
        , targetWorkerImageDigestText (targetWorkerIntentImageDigest intent)
        )
      ]

  legacyExpectedMetadata commitment =
    Map.delete
      targetMaterialMetadataVaultVersionField
      (expectedMetadata 1 commitment)

  receipt version commitment =
    TargetWorkerReceipt
      { internalWorkerReceiptTarget = target
      , internalWorkerReceiptGeneration = targetWorkerIntentGeneration intent
      , internalWorkerReceiptVaultVersion = version
      , internalWorkerReceiptCommitment = commitment
      , internalWorkerReceiptRequestDigest = targetWorkerIntentRequestDigest intent
      , internalWorkerReceiptActionDigest = targetWorkerIntentActionDigest intent
      , internalWorkerReceiptPodUid = targetWorkerAttestedPodUid attestation
      , internalWorkerReceiptImageDigest = targetWorkerIntentImageDigest intent
      }

commitmentInput :: TargetWorkerIntent -> Map Text Text -> ByteString
commitmentInput intent fields =
  LazyByteString.toStrict
    ( serialise
        WireTargetWorkerCommitment
          { wireCommitmentVersion = 1
          , wireCommitmentTarget = targetWorkerIntentTarget intent
          , wireCommitmentGeneration =
              credentialGenerationValue (targetWorkerIntentGeneration intent)
          , wireCommitmentRequestDigest =
              targetValueDigestText (targetWorkerIntentRequestDigest intent)
          , wireCommitmentActionDigest =
              targetValueDigestText (targetWorkerIntentActionDigest intent)
          , wireCommitmentFields = fields
          }
    )

metadataGenerationCommitment
  :: TargetWorkerMetadataObservation
  -> Either TargetWorkerExecutionError (Maybe (Natural, Text))
metadataGenerationCommitment observation = case observation of
  TargetWorkerMetadataMissing -> Right Nothing
  TargetWorkerMetadataPresent _ custom -> case ( Map.lookup targetMaterialMetadataGenerationField custom
                                               , Map.lookup targetMaterialMetadataCommitmentField custom
                                               ) of
    (Nothing, Nothing) -> Right Nothing
    (Just generationText, Just commitment) -> do
      generation <-
        maybe
          (Left TargetWorkerExecutionMetadataInvalid)
          Right
          (readMaybe (Text.unpack generationText))
      unless (generation > 0) (Left TargetWorkerExecutionMetadataInvalid)
      _ <- first (const TargetWorkerExecutionMetadataInvalid) (validateCommitment commitment)
      Right (Just (generation, commitment))
    _ -> Left TargetWorkerExecutionMetadataInvalid

naturalText :: Natural -> Text
naturalText = Text.pack . show

-- | Run session revocation on success and every refusal.  The direct revoke
-- result is provisional because a successful revoke response can be lost; the
-- independent exact-absence observation is authoritative.
finishTargetWorkerSession
  :: (Monad m)
  => m (Either TargetWorkerExecutionError value)
  -> m (Either TargetWorkerExecutionError ())
  -> m (Either TargetWorkerExecutionError Bool)
  -> m (Either TargetWorkerExecutionError value)
finishTargetWorkerSession executeEffect revokeEffect observeAbsentEffect = do
  outcome <- executeEffect
  _revoked <- revokeEffect
  absent <- observeAbsentEffect
  pure $ case absent of
    Left _ -> Left TargetWorkerExecutionSessionRevocationFailed
    Right False -> Left TargetWorkerExecutionSessionRevocationFailed
    Right True -> outcome

-- Kept in the import list as a documentation-level assertion that Authority
-- epoch is part of the verified intent metadata, even though it is checked by
-- 'verifySignedTargetCommittedIntent' rather than reinterpreted here.
_verifiedEpochWitness :: TargetCommittedIntentSpec -> AuthorityEpoch
_verifiedEpochWitness = targetIntentAuthorityEpoch
