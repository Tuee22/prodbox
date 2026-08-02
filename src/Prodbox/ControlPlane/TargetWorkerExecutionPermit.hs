{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authority-signed, post-Kubernetes-observation permission for one exact
-- Target materializer incarnation.  The initial Target intent authorizes the
-- durable action; this second signature authorizes only the observed rollout,
-- Job, Pod, static ServiceAccount incarnation, immutable worker image, and
-- retained session-attempt fence named here.
module Prodbox.ControlPlane.TargetWorkerExecutionPermit
  ( SignedTargetWorkerExecutionPermit
  , VerifiedTargetWorkerExecutionPermit
  , TargetWorkerExecutionPermitError (..)
  , targetWorkerExecutionPermitMaximumBytes
  , issueTargetWorkerExecutionPermit
  , encodeTargetWorkerExecutionPermit
  , decodeTargetWorkerExecutionPermit
  , encodeVerifiedTargetWorkerExecutionPermit
  , verifyTargetWorkerExecutionPermit
  , targetWorkerExecutionPermitMatchesObservation
  , targetWorkerSessionOperationId
  , targetWorkerSessionAttemptId
  , verifiedPermitAgentRollout
  , verifiedPermitJobName
  , verifiedPermitJobUid
  , verifiedPermitPodName
  , verifiedPermitPodUid
  , verifiedPermitServiceAccount
  , verifiedPermitServiceAccountUid
  , verifiedPermitImageDigest
  , verifiedPermitRequestDigest
  , verifiedPermitActionDigest
  , verifiedPermitIntentDigest
  , verifiedPermitDeadline
  , verifiedPermitSessionBinding
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticationRegistry (targetSecretWorkerVaultRole)
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.ServiceSessionJournal
  ( ServiceSessionBinding
  , mkServiceSessionBinding
  , serviceSessionBindingAttemptId
  , serviceSessionBindingFence
  , serviceSessionBindingOperationId
  , serviceSessionBindingRole
  )
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretId)
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( AcceptedTargetAuthority
  , TargetAgentRolloutEvidence
  , acceptedTargetAgentIdentity
  , acceptedTargetAuthorityEpoch
  , acceptedTargetId
  , acceptedTargetIssuerGeneration
  , acceptedTargetIssuerIdentity
  , acceptedTargetIssuerPublicKey
  , mkTargetAgentIdentity
  , mkTargetAgentRolloutEvidence
  , targetAgentIdentityText
  , targetAgentRolloutDeploymentGeneration
  , targetAgentRolloutDeploymentUid
  , targetAgentRolloutEvidenceIdentity
  , targetAgentRolloutObservedDigest
  , targetAgentRolloutObservedGeneration
  , targetIntentPublicKeyBytes
  , targetIssuerKeyGenerationValue
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerAttestation
  , TargetWorkerImageDigest
  , TargetWorkerIngressSchema
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
  , targetWorkerIntentActionDigest
  , targetWorkerIntentAgentIdentity
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
  , targetWorkerServiceAccountUidText
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (signAuthorityManifestPayload)
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

data TargetWorkerExecutionPermitClaims = TargetWorkerExecutionPermitClaims
  { permitIssuerGeneration :: !Natural
  , permitIssuerIdentity :: !Text
  , permitAuthorityEpoch :: !Natural
  , permitAgentRollout :: !TargetAgentRolloutEvidence
  , permitTarget :: !TargetSecretId
  , permitGeneration :: !CredentialGeneration
  , permitSchema :: !TargetWorkerIngressSchema
  , permitImageDigest :: !TargetWorkerImageDigest
  , permitJobName :: !Text
  , permitJobUid :: !TargetWorkerJobUid
  , permitPodName :: !Text
  , permitPodUid :: !TargetWorkerPodUid
  , permitServiceAccount :: !Text
  , permitServiceAccountUid :: !TargetWorkerServiceAccountUid
  , permitRequestDigest :: !TargetValueDigest
  , permitActionDigest :: !TargetValueDigest
  , permitIntentDigest :: !TargetValueDigest
  , permitDeadline :: !AuthorityTime
  , permitSessionBinding :: !ServiceSessionBinding
  }
  deriving stock (Eq, Show)

data WireTargetWorkerExecutionPermitClaims = WireTargetWorkerExecutionPermitClaims
  { wirePermitVersion :: !Word16
  , wirePermitIssuerGeneration :: !Natural
  , wirePermitIssuerIdentity :: !Text
  , wirePermitAuthorityEpoch :: !Natural
  , wirePermitAgentIdentity :: !Text
  , wirePermitDeploymentUid :: !Text
  , wirePermitDeploymentGeneration :: !Natural
  , wirePermitObservedDeploymentGeneration :: !Natural
  , wirePermitObservedRolloutDigest :: !Text
  , wirePermitTarget :: !TargetSecretId
  , wirePermitGeneration :: !Natural
  , wirePermitSchema :: !TargetWorkerIngressSchema
  , wirePermitImageDigest :: !Text
  , wirePermitJobName :: !Text
  , wirePermitJobUid :: !Text
  , wirePermitPodName :: !Text
  , wirePermitPodUid :: !Text
  , wirePermitServiceAccount :: !Text
  , wirePermitServiceAccountUid :: !Text
  , wirePermitRequestDigest :: !Text
  , wirePermitActionDigest :: !Text
  , wirePermitIntentDigest :: !Text
  , wirePermitDeadlineMicros :: !Natural
  , wirePermitSessionRole :: !Text
  , wirePermitSessionOperationId :: !Text
  , wirePermitSessionAttemptId :: !Text
  , wirePermitSessionFence :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireSignedTargetWorkerExecutionPermit = WireSignedTargetWorkerExecutionPermit
  { wireSignedPermitClaims :: !WireTargetWorkerExecutionPermitClaims
  , wireSignedPermitSignature :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireTargetWorkerAttemptBinding = WireTargetWorkerAttemptBinding
  { wireAttemptVersion :: !Word16
  , wireAttemptAgentIdentity :: !Text
  , wireAttemptDeploymentUid :: !Text
  , wireAttemptDeploymentGeneration :: !Natural
  , wireAttemptObservedDeploymentGeneration :: !Natural
  , wireAttemptObservedRolloutDigest :: !Text
  , wireAttemptJobName :: !Text
  , wireAttemptJobUid :: !Text
  , wireAttemptPodName :: !Text
  , wireAttemptPodUid :: !Text
  , wireAttemptServiceAccount :: !Text
  , wireAttemptServiceAccountUid :: !Text
  , wireAttemptImageDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data SignedTargetWorkerExecutionPermit = SignedTargetWorkerExecutionPermit
  { signedPermitClaims :: !TargetWorkerExecutionPermitClaims
  , signedPermitSignature :: !ByteString
  }
  deriving stock (Eq, Show)

newtype VerifiedTargetWorkerExecutionPermit
  = VerifiedTargetWorkerExecutionPermit SignedTargetWorkerExecutionPermit

data TargetWorkerExecutionPermitError
  = TargetWorkerExecutionPermitTooLarge !Int !Int
  | TargetWorkerExecutionPermitDecodeFailed
  | TargetWorkerExecutionPermitUnsupportedVersion !Word16
  | TargetWorkerExecutionPermitNonCanonical
  | TargetWorkerExecutionPermitValueInvalid !Text
  | TargetWorkerExecutionPermitSignatureInvalid
  | TargetWorkerExecutionPermitSignerUnavailable !Text
  | TargetWorkerExecutionPermitSignerGenerationMismatch !Natural !Natural
  | TargetWorkerExecutionPermitTrustMismatch
  | TargetWorkerExecutionPermitIntentMismatch
  | TargetWorkerExecutionPermitObservationMismatch
  | TargetWorkerExecutionPermitSessionMismatch
  | TargetWorkerExecutionPermitDeadlineReached
  deriving stock (Eq, Show)

targetWorkerExecutionPermitMaximumBytes :: Int
targetWorkerExecutionPermitMaximumBytes = 32 * 1024

targetWorkerExecutionPermitVersion :: Word16
targetWorkerExecutionPermitVersion = 1

-- | The journal operation lane is the canonical secret-free request digest,
-- not the initial action fence.
targetWorkerSessionOperationId :: TargetWorkerIntent -> Text
targetWorkerSessionOperationId =
  targetValueDigestText . targetWorkerIntentRequestDigest

-- | A recreated Job/Pod incarnation receives a different attempt identity
-- even when the durable Target action and deterministic Job name are unchanged.
targetWorkerSessionAttemptId
  :: TargetAgentRolloutEvidence -> TargetWorkerAttestation -> Text
targetWorkerSessionAttemptId rollout attestation =
  targetValueDigestText
    ( sha256TargetValueDigest
        ( LazyByteString.toStrict
            ( serialise
                WireTargetWorkerAttemptBinding
                  { wireAttemptVersion = targetWorkerExecutionPermitVersion
                  , wireAttemptAgentIdentity =
                      targetAgentIdentityText (targetAgentRolloutEvidenceIdentity rollout)
                  , wireAttemptDeploymentUid = targetAgentRolloutDeploymentUid rollout
                  , wireAttemptDeploymentGeneration =
                      targetAgentRolloutDeploymentGeneration rollout
                  , wireAttemptObservedDeploymentGeneration =
                      targetAgentRolloutObservedGeneration rollout
                  , wireAttemptObservedRolloutDigest =
                      targetAgentRolloutObservedDigest rollout
                  , wireAttemptJobName = targetWorkerIntentJobName intent
                  , wireAttemptJobUid =
                      targetWorkerJobUidText (targetWorkerAttestedJobUid attestation)
                  , wireAttemptPodName = targetWorkerAttestedPodName attestation
                  , wireAttemptPodUid =
                      targetWorkerPodUidText (targetWorkerAttestedPodUid attestation)
                  , wireAttemptServiceAccount = targetWorkerIntentServiceAccount intent
                  , wireAttemptServiceAccountUid =
                      targetWorkerServiceAccountUidText
                        (targetWorkerAttestedServiceAccountUid attestation)
                  , wireAttemptImageDigest =
                      targetWorkerImageDigestText (targetWorkerIntentImageDigest intent)
                  }
            )
        )
    )
 where
  intent = targetWorkerAttestedIntent attestation

issueTargetWorkerExecutionPermit
  :: (Monad m)
  => AuthorityManifestSigner m
  -> AcceptedTargetAuthority
  -> TargetAgentRolloutEvidence
  -> TargetWorkerAttestation
  -> ServiceSessionBinding
  -> m (Either TargetWorkerExecutionPermitError SignedTargetWorkerExecutionPermit)
issueTargetWorkerExecutionPermit signer accepted rollout attestation sessionBinding =
  case claimsFromObservation accepted rollout attestation sessionBinding of
    Left err -> pure (Left err)
    Right claims -> do
      signed <- signAuthorityManifestPayload signer (canonicalClaimsBytes claims)
      pure $ case signed of
        Left detail -> Left (TargetWorkerExecutionPermitSignerUnavailable (Text.take 256 detail))
        Right (generation, signature)
          | generation /= permitIssuerGeneration claims ->
              Left
                ( TargetWorkerExecutionPermitSignerGenerationMismatch
                    (permitIssuerGeneration claims)
                    generation
                )
          | ByteString.length signature /= 64 ->
              Left TargetWorkerExecutionPermitSignatureInvalid
          | otherwise ->
              Right
                SignedTargetWorkerExecutionPermit
                  { signedPermitClaims = claims
                  , signedPermitSignature = signature
                  }

claimsFromObservation
  :: AcceptedTargetAuthority
  -> TargetAgentRolloutEvidence
  -> TargetWorkerAttestation
  -> ServiceSessionBinding
  -> Either TargetWorkerExecutionPermitError TargetWorkerExecutionPermitClaims
claimsFromObservation accepted rollout attestation sessionBinding = do
  let intent = targetWorkerAttestedIntent attestation
      expectedOperation = targetWorkerSessionOperationId intent
      expectedAttempt = targetWorkerSessionAttemptId rollout attestation
  unless
    ( acceptedTargetAgentIdentity accepted == targetWorkerIntentAgentIdentity intent
        && targetAgentRolloutEvidenceIdentity rollout == targetWorkerIntentAgentIdentity intent
        && acceptedTargetId accepted == targetWorkerIntentTarget intent
    )
    (Left TargetWorkerExecutionPermitTrustMismatch)
  unless
    ( serviceSessionBindingRole sessionBinding == targetSecretWorkerVaultRole
        && serviceSessionBindingOperationId sessionBinding == expectedOperation
        && serviceSessionBindingAttemptId sessionBinding == expectedAttempt
        && serviceSessionBindingFence sessionBinding > 0
    )
    (Left TargetWorkerExecutionPermitSessionMismatch)
  pure
    TargetWorkerExecutionPermitClaims
      { permitIssuerGeneration =
          targetIssuerKeyGenerationValue (acceptedTargetIssuerGeneration accepted)
      , permitIssuerIdentity = acceptedTargetIssuerIdentity accepted
      , permitAuthorityEpoch =
          case acceptedTargetAuthorityEpoch accepted of
            AuthorityEpoch value -> value
      , permitAgentRollout = rollout
      , permitTarget = targetWorkerIntentTarget intent
      , permitGeneration = targetWorkerIntentGeneration intent
      , permitSchema = targetWorkerIntentSchema intent
      , permitImageDigest = targetWorkerIntentImageDigest intent
      , permitJobName = targetWorkerIntentJobName intent
      , permitJobUid = targetWorkerAttestedJobUid attestation
      , permitPodName = targetWorkerAttestedPodName attestation
      , permitPodUid = targetWorkerAttestedPodUid attestation
      , permitServiceAccount = targetWorkerIntentServiceAccount intent
      , permitServiceAccountUid = targetWorkerAttestedServiceAccountUid attestation
      , permitRequestDigest = targetWorkerIntentRequestDigest intent
      , permitActionDigest = targetWorkerIntentActionDigest intent
      , permitIntentDigest = sha256TargetValueDigest (targetWorkerIntentSignedBytes intent)
      , permitDeadline = targetWorkerIntentDeadline intent
      , permitSessionBinding = sessionBinding
      }

encodeTargetWorkerExecutionPermit :: SignedTargetWorkerExecutionPermit -> ByteString
encodeTargetWorkerExecutionPermit signed =
  LazyByteString.toStrict
    ( serialise
        WireSignedTargetWorkerExecutionPermit
          { wireSignedPermitClaims = claimsWire (signedPermitClaims signed)
          , wireSignedPermitSignature = signedPermitSignature signed
          }
    )

decodeTargetWorkerExecutionPermit
  :: ByteString
  -> Either TargetWorkerExecutionPermitError SignedTargetWorkerExecutionPermit
decodeTargetWorkerExecutionPermit bytes
  | ByteString.length bytes > targetWorkerExecutionPermitMaximumBytes =
      Left
        ( TargetWorkerExecutionPermitTooLarge
            (ByteString.length bytes)
            targetWorkerExecutionPermitMaximumBytes
        )
  | otherwise = do
      wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left TargetWorkerExecutionPermitDecodeFailed
        Right value -> Right value
      unless
        (wirePermitVersion (wireSignedPermitClaims wire) == targetWorkerExecutionPermitVersion)
        ( Left
            ( TargetWorkerExecutionPermitUnsupportedVersion
                (wirePermitVersion (wireSignedPermitClaims wire))
            )
        )
      claims <- claimsFromWire (wireSignedPermitClaims wire)
      unless
        (ByteString.length (wireSignedPermitSignature wire) == 64)
        (Left TargetWorkerExecutionPermitSignatureInvalid)
      let signed =
            SignedTargetWorkerExecutionPermit
              { signedPermitClaims = claims
              , signedPermitSignature = wireSignedPermitSignature wire
              }
      unless
        (encodeTargetWorkerExecutionPermit signed == bytes)
        (Left TargetWorkerExecutionPermitNonCanonical)
      pure signed

verifyTargetWorkerExecutionPermit
  :: AcceptedTargetAuthority
  -> AuthorityTime
  -> TargetWorkerIntent
  -> SignedTargetWorkerExecutionPermit
  -> Either TargetWorkerExecutionPermitError VerifiedTargetWorkerExecutionPermit
verifyTargetWorkerExecutionPermit accepted now intent signed = do
  let claims = signedPermitClaims signed
      acceptedEpoch = case acceptedTargetAuthorityEpoch accepted of
        AuthorityEpoch value -> value
  unless
    ( permitIssuerGeneration claims
        == targetIssuerKeyGenerationValue (acceptedTargetIssuerGeneration accepted)
        && permitIssuerIdentity claims == acceptedTargetIssuerIdentity accepted
        && permitAuthorityEpoch claims == acceptedEpoch
        && targetAgentRolloutEvidenceIdentity (permitAgentRollout claims)
          == acceptedTargetAgentIdentity accepted
        && permitTarget claims == acceptedTargetId accepted
    )
    (Left TargetWorkerExecutionPermitTrustMismatch)
  unless
    ( permitTarget claims == targetWorkerIntentTarget intent
        && permitGeneration claims == targetWorkerIntentGeneration intent
        && permitSchema claims == targetWorkerIntentSchema intent
        && permitImageDigest claims == targetWorkerIntentImageDigest intent
        && permitJobName claims == targetWorkerIntentJobName intent
        && permitServiceAccount claims == targetWorkerIntentServiceAccount intent
        && permitRequestDigest claims == targetWorkerIntentRequestDigest intent
        && permitActionDigest claims == targetWorkerIntentActionDigest intent
        && permitIntentDigest claims
          == sha256TargetValueDigest (targetWorkerIntentSignedBytes intent)
        && authorityTimeMicros (permitDeadline claims)
          == authorityTimeMicros (targetWorkerIntentDeadline intent)
    )
    (Left TargetWorkerExecutionPermitIntentMismatch)
  unless
    ( serviceSessionBindingRole (permitSessionBinding claims) == targetSecretWorkerVaultRole
        && serviceSessionBindingOperationId (permitSessionBinding claims)
          == targetWorkerSessionOperationId intent
        && serviceSessionBindingAttemptId (permitSessionBinding claims)
          == sessionAttemptIdFromClaims claims
        && serviceSessionBindingFence (permitSessionBinding claims) > 0
    )
    (Left TargetWorkerExecutionPermitSessionMismatch)
  unless
    (authorityTimeMicros now < authorityTimeMicros (permitDeadline claims))
    (Left TargetWorkerExecutionPermitDeadlineReached)
  public <- case Ed25519.publicKey (targetIntentPublicKeyBytes (acceptedTargetIssuerPublicKey accepted)) of
    CryptoFailed _ -> Left TargetWorkerExecutionPermitSignatureInvalid
    CryptoPassed key -> Right key
  signature <- case Ed25519.signature (signedPermitSignature signed) of
    CryptoFailed _ -> Left TargetWorkerExecutionPermitSignatureInvalid
    CryptoPassed value -> Right value
  unless
    (Ed25519.verify public (canonicalClaimsBytes claims) signature)
    (Left TargetWorkerExecutionPermitSignatureInvalid)
  pure (VerifiedTargetWorkerExecutionPermit signed)

targetWorkerExecutionPermitMatchesObservation
  :: TargetAgentRolloutEvidence
  -> TargetWorkerAttestation
  -> ServiceSessionBinding
  -> VerifiedTargetWorkerExecutionPermit
  -> Bool
targetWorkerExecutionPermitMatchesObservation rollout attestation sessionBinding verified =
  permitAgentRollout claims == rollout
    && permitJobName claims == targetWorkerIntentJobName intent
    && permitJobUid claims == targetWorkerAttestedJobUid attestation
    && permitPodName claims == targetWorkerAttestedPodName attestation
    && permitPodUid claims == targetWorkerAttestedPodUid attestation
    && permitServiceAccount claims == targetWorkerIntentServiceAccount intent
    && permitServiceAccountUid claims == targetWorkerAttestedServiceAccountUid attestation
    && permitImageDigest claims == targetWorkerIntentImageDigest intent
    && permitSessionBinding claims == sessionBinding
 where
  claims = verifiedClaims verified
  intent = targetWorkerAttestedIntent attestation

verifiedClaims :: VerifiedTargetWorkerExecutionPermit -> TargetWorkerExecutionPermitClaims
verifiedClaims (VerifiedTargetWorkerExecutionPermit signed) = signedPermitClaims signed

encodeVerifiedTargetWorkerExecutionPermit
  :: VerifiedTargetWorkerExecutionPermit -> ByteString
encodeVerifiedTargetWorkerExecutionPermit
  (VerifiedTargetWorkerExecutionPermit signed) =
    encodeTargetWorkerExecutionPermit signed

verifiedPermitAgentRollout :: VerifiedTargetWorkerExecutionPermit -> TargetAgentRolloutEvidence
verifiedPermitAgentRollout = permitAgentRollout . verifiedClaims

verifiedPermitJobName :: VerifiedTargetWorkerExecutionPermit -> Text
verifiedPermitJobName = permitJobName . verifiedClaims

verifiedPermitJobUid :: VerifiedTargetWorkerExecutionPermit -> TargetWorkerJobUid
verifiedPermitJobUid = permitJobUid . verifiedClaims

verifiedPermitPodName :: VerifiedTargetWorkerExecutionPermit -> Text
verifiedPermitPodName = permitPodName . verifiedClaims

verifiedPermitPodUid :: VerifiedTargetWorkerExecutionPermit -> TargetWorkerPodUid
verifiedPermitPodUid = permitPodUid . verifiedClaims

verifiedPermitServiceAccount :: VerifiedTargetWorkerExecutionPermit -> Text
verifiedPermitServiceAccount = permitServiceAccount . verifiedClaims

verifiedPermitServiceAccountUid
  :: VerifiedTargetWorkerExecutionPermit -> TargetWorkerServiceAccountUid
verifiedPermitServiceAccountUid = permitServiceAccountUid . verifiedClaims

verifiedPermitImageDigest :: VerifiedTargetWorkerExecutionPermit -> TargetWorkerImageDigest
verifiedPermitImageDigest = permitImageDigest . verifiedClaims

verifiedPermitRequestDigest :: VerifiedTargetWorkerExecutionPermit -> TargetValueDigest
verifiedPermitRequestDigest = permitRequestDigest . verifiedClaims

verifiedPermitActionDigest :: VerifiedTargetWorkerExecutionPermit -> TargetValueDigest
verifiedPermitActionDigest = permitActionDigest . verifiedClaims

verifiedPermitIntentDigest :: VerifiedTargetWorkerExecutionPermit -> TargetValueDigest
verifiedPermitIntentDigest = permitIntentDigest . verifiedClaims

verifiedPermitDeadline :: VerifiedTargetWorkerExecutionPermit -> AuthorityTime
verifiedPermitDeadline = permitDeadline . verifiedClaims

verifiedPermitSessionBinding :: VerifiedTargetWorkerExecutionPermit -> ServiceSessionBinding
verifiedPermitSessionBinding = permitSessionBinding . verifiedClaims

sessionAttemptIdFromClaims :: TargetWorkerExecutionPermitClaims -> Text
sessionAttemptIdFromClaims claims =
  targetValueDigestText
    ( sha256TargetValueDigest
        ( LazyByteString.toStrict
            ( serialise
                WireTargetWorkerAttemptBinding
                  { wireAttemptVersion = targetWorkerExecutionPermitVersion
                  , wireAttemptAgentIdentity =
                      targetAgentIdentityText
                        (targetAgentRolloutEvidenceIdentity (permitAgentRollout claims))
                  , wireAttemptDeploymentUid =
                      targetAgentRolloutDeploymentUid (permitAgentRollout claims)
                  , wireAttemptDeploymentGeneration =
                      targetAgentRolloutDeploymentGeneration (permitAgentRollout claims)
                  , wireAttemptObservedDeploymentGeneration =
                      targetAgentRolloutObservedGeneration (permitAgentRollout claims)
                  , wireAttemptObservedRolloutDigest =
                      targetAgentRolloutObservedDigest (permitAgentRollout claims)
                  , wireAttemptJobName = permitJobName claims
                  , wireAttemptJobUid = targetWorkerJobUidText (permitJobUid claims)
                  , wireAttemptPodName = permitPodName claims
                  , wireAttemptPodUid = targetWorkerPodUidText (permitPodUid claims)
                  , wireAttemptServiceAccount = permitServiceAccount claims
                  , wireAttemptServiceAccountUid =
                      targetWorkerServiceAccountUidText (permitServiceAccountUid claims)
                  , wireAttemptImageDigest =
                      targetWorkerImageDigestText (permitImageDigest claims)
                  }
            )
        )
    )

canonicalClaimsBytes :: TargetWorkerExecutionPermitClaims -> ByteString
canonicalClaimsBytes = LazyByteString.toStrict . serialise . claimsWire

claimsWire :: TargetWorkerExecutionPermitClaims -> WireTargetWorkerExecutionPermitClaims
claimsWire claims =
  WireTargetWorkerExecutionPermitClaims
    { wirePermitVersion = targetWorkerExecutionPermitVersion
    , wirePermitIssuerGeneration = permitIssuerGeneration claims
    , wirePermitIssuerIdentity = permitIssuerIdentity claims
    , wirePermitAuthorityEpoch = permitAuthorityEpoch claims
    , wirePermitAgentIdentity =
        targetAgentIdentityText (targetAgentRolloutEvidenceIdentity (permitAgentRollout claims))
    , wirePermitDeploymentUid = targetAgentRolloutDeploymentUid (permitAgentRollout claims)
    , wirePermitDeploymentGeneration =
        targetAgentRolloutDeploymentGeneration (permitAgentRollout claims)
    , wirePermitObservedDeploymentGeneration =
        targetAgentRolloutObservedGeneration (permitAgentRollout claims)
    , wirePermitObservedRolloutDigest =
        targetAgentRolloutObservedDigest (permitAgentRollout claims)
    , wirePermitTarget = permitTarget claims
    , wirePermitGeneration = credentialGenerationValue (permitGeneration claims)
    , wirePermitSchema = permitSchema claims
    , wirePermitImageDigest = targetWorkerImageDigestText (permitImageDigest claims)
    , wirePermitJobName = permitJobName claims
    , wirePermitJobUid = targetWorkerJobUidText (permitJobUid claims)
    , wirePermitPodName = permitPodName claims
    , wirePermitPodUid = targetWorkerPodUidText (permitPodUid claims)
    , wirePermitServiceAccount = permitServiceAccount claims
    , wirePermitServiceAccountUid =
        targetWorkerServiceAccountUidText (permitServiceAccountUid claims)
    , wirePermitRequestDigest = targetValueDigestText (permitRequestDigest claims)
    , wirePermitActionDigest = targetValueDigestText (permitActionDigest claims)
    , wirePermitIntentDigest = targetValueDigestText (permitIntentDigest claims)
    , wirePermitDeadlineMicros = authorityTimeMicros (permitDeadline claims)
    , wirePermitSessionRole = serviceSessionBindingRole (permitSessionBinding claims)
    , wirePermitSessionOperationId =
        serviceSessionBindingOperationId (permitSessionBinding claims)
    , wirePermitSessionAttemptId =
        serviceSessionBindingAttemptId (permitSessionBinding claims)
    , wirePermitSessionFence = serviceSessionBindingFence (permitSessionBinding claims)
    }

claimsFromWire
  :: WireTargetWorkerExecutionPermitClaims
  -> Either TargetWorkerExecutionPermitError TargetWorkerExecutionPermitClaims
claimsFromWire wire = do
  agent <- valueText (mkTargetAgentIdentity (wirePermitAgentIdentity wire))
  rollout <-
    valueText
      ( mkTargetAgentRolloutEvidence
          agent
          (wirePermitDeploymentUid wire)
          (wirePermitDeploymentGeneration wire)
          (wirePermitObservedDeploymentGeneration wire)
          (wirePermitObservedRolloutDigest wire)
      )
  generation <- valueShow (mkCredentialGeneration (wirePermitGeneration wire))
  image <- valueText (mkTargetWorkerImageDigest (wirePermitImageDigest wire))
  jobUid <- valueText (mkTargetWorkerJobUid (wirePermitJobUid wire))
  podUid <- valueText (mkTargetWorkerPodUid (wirePermitPodUid wire))
  serviceAccountUid <-
    valueText (mkTargetWorkerServiceAccountUid (wirePermitServiceAccountUid wire))
  requestDigest <- valueShow (mkTargetValueDigest (wirePermitRequestDigest wire))
  actionDigest <- valueShow (mkTargetValueDigest (wirePermitActionDigest wire))
  intentDigest <- valueShow (mkTargetValueDigest (wirePermitIntentDigest wire))
  sessionBinding <-
    valueShow
      ( mkServiceSessionBinding
          (wirePermitSessionRole wire)
          (wirePermitSessionOperationId wire)
          (wirePermitSessionAttemptId wire)
          (wirePermitSessionFence wire)
      )
  unless
    ( wirePermitIssuerGeneration wire > 0
        && wirePermitAuthorityEpoch wire > 0
        && validIdentity (wirePermitIssuerIdentity wire)
        && validName (wirePermitJobName wire)
        && validName (wirePermitPodName wire)
        && wirePermitServiceAccount wire == targetSecretWorkerVaultRole
        && wirePermitDeadlineMicros wire > 0
    )
    (Left (TargetWorkerExecutionPermitValueInvalid "permit claim is invalid"))
  pure
    TargetWorkerExecutionPermitClaims
      { permitIssuerGeneration = wirePermitIssuerGeneration wire
      , permitIssuerIdentity = wirePermitIssuerIdentity wire
      , permitAuthorityEpoch = wirePermitAuthorityEpoch wire
      , permitAgentRollout = rollout
      , permitTarget = wirePermitTarget wire
      , permitGeneration = generation
      , permitSchema = wirePermitSchema wire
      , permitImageDigest = image
      , permitJobName = wirePermitJobName wire
      , permitJobUid = jobUid
      , permitPodName = wirePermitPodName wire
      , permitPodUid = podUid
      , permitServiceAccount = wirePermitServiceAccount wire
      , permitServiceAccountUid = serviceAccountUid
      , permitRequestDigest = requestDigest
      , permitActionDigest = actionDigest
      , permitIntentDigest = intentDigest
      , permitDeadline = authorityTimeFromMicros (wirePermitDeadlineMicros wire)
      , permitSessionBinding = sessionBinding
      }
 where
  valueText
    :: Either Text value
    -> Either TargetWorkerExecutionPermitError value
  valueText = first TargetWorkerExecutionPermitValueInvalid
  valueShow
    :: (Show errorValue)
    => Either errorValue value
    -> Either TargetWorkerExecutionPermitError value
  valueShow = first (TargetWorkerExecutionPermitValueInvalid . Text.pack . show)

validIdentity :: Text -> Bool
validIdentity value =
  not (Text.null value)
    && Text.length value <= 256
    && Text.strip value == value
    && not (Text.any (`elem` ['\n', '\r', '\t', ' ']) value)

validName :: Text -> Bool
validName value =
  not (Text.null value)
    && Text.length value <= 253
    && Text.strip value == value
