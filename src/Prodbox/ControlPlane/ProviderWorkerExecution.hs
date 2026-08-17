{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Signed, two-stage production Provider Worker execution.
--
-- The boundary has no Authority checkpoint, retained journal, or global-CAS
-- capability.  A bounded canonical Ed25519 envelope binds the authenticated
-- issuer/key generation, current Authority epoch, mutation fence, operation and
-- action identity, durable commit-receipt digest, exact provider revision,
-- closed resource/action, idempotency key, and absolute deadline.  Admission
-- verifies those bindings against one Agent-local trust record; execution
-- re-reads the same record and time before acquiring a rank-2 narrow session.
--
-- Mutation arms always observe first and authoritatively read back after the
-- single possible apply attempt, even when the apply response is lost.  Replay
-- therefore converges from observation without a second mutation.  The only
-- effect surface is the exhaustive closed 'ProviderIntentCapabilities'; no
-- credential/admin/SMTP-IAM, generic AWS/Vault/object-store, subprocess, or
-- Authority-state field exists in the signed wire or execution boundary.
module Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentSigningKey
  , ProviderIntentSigningKeyError (..)
  , mkProviderIntentSigningKey
  , ProviderIntentPublicKey
  , mkProviderIntentPublicKey
  , providerIntentPublicKeyBytes
  , providerIntentSigningPublicKey
  , ProviderIssuerKeyGeneration
  , mkProviderIssuerKeyGeneration
  , providerIssuerKeyGenerationValue
  , AcceptedProviderAuthority
  , AcceptedProviderAuthorityError (..)
  , mkAcceptedProviderAuthority
  , AcceptedProviderAuthorityCodecError (..)
  , acceptedProviderAuthorityMaximumEncodedBytes
  , encodeAcceptedProviderAuthority
  , decodeAcceptedProviderAuthority
  , ProviderCommittedIntentSpec (..)
  , ProviderCommittedIntentValueError (..)
  , providerCommitActionDigest
  , UnsignedProviderCommittedIntent
  , mkUnsignedProviderCommittedIntent
  , SignedProviderCommittedIntent
  , signProviderCommittedIntent
  , ProviderIntentCapabilitySigningError (..)
  , signProviderCommittedIntentWith
  , ProviderCommittedIntentCodecError (..)
  , providerCommittedIntentMaximumEncodedBytes
  , encodeSignedProviderCommittedIntent
  , decodeSignedProviderCommittedIntent
  , VerifiedProviderCommittedIntent
  , ProviderIntentVerificationError (..)
  , verifySignedProviderCommittedIntent
  , ProviderWorkerTrustRepository (..)
  , ProviderWorkerExecutionBoundary
  , mkProviderWorkerExecutionBoundary
  , ProviderIntentAdmissionError (..)
  , admitProviderCommittedIntent
  , ProviderIntentExecutionResult (..)
  , ExecutedProviderIntent
  , executedProviderIntentAction
  , executedProviderIntentCoordinate
  , executedProviderIntentOperationId
  , executedProviderIntentRevision
  , executedProviderIntentCredentialSessionBinding
  , executedProviderIntentAcceptedAuthorityDigest
  , executedProviderIntentResult
  , ProviderIntentExecutionError (..)
  , ProviderIntentCredentialBindingRegression
  , fixedProviderIntentCredentialBindingRegression
  , providerIntentCredentialBindingRegressionUnboundAccepted
  , providerIntentCredentialBindingRegressionExactAccepted
  , providerIntentCredentialBindingRegressionMissingRefused
  , providerIntentCredentialBindingRegressionMismatchRefused
  , executeVerifiedProviderIntentBound
  , executeVerifiedProviderIntent
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.Bifunctor (first)
import Data.ByteArray qualified as ByteArray
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.ProviderNarrowSession
  ( ProviderEffectObservation (..)
  , ProviderIntentCapabilities
  , ProviderIntentOperation (..)
  , ProviderMutation (..)
  , ProviderNarrowSessionRunner (..)
  , ProviderReadOnly (..)
  , operationForProviderIntent
  )
import Prodbox.ControlPlane.ProviderCredentialSession
  ( ProviderAcceptedAuthorityDigest
  , ProviderCredentialSessionBinding
  , providerAcceptedAuthorityDigestText
  , providerCredentialSessionGeneration
  , providerCredentialSessionReceiptDigest
  , providerCredentialSessionVaultVersion
  )
import Prodbox.ControlPlane.ProviderCredentialSession.Internal
  ( providerAcceptedAuthorityDigestFromCanonicalInternal
  , providerAcceptedAuthorityDigestFromTextInternal
  , providerCredentialSessionBindingFromWireInternal
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( CallerPrincipal (..)
  , RequestSigningCapability
  , RequestSigningCapabilityError
  , requestSigningCapabilityGeneration
  , requestSigningCapabilityPrincipal
  , signCanonicalBytesWithRequestCapability
  , signingKeyGenerationValue
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
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderIntentCoordinate
  , ProviderReadinessProbe (..)
  , ProviderRevision
  , ProviderStackConfig
  , RegisteredProviderResources
  , eksClientAuthRequestAccountId
  , eksClientAuthRequestClusterName
  , eksClientAuthRequestDestinationPublicKey
  , eksClientAuthRequestRegion
  , eksClusterIdentityRequestAccountId
  , eksClusterIdentityRequestClusterName
  , eksClusterIdentityRequestRegion
  , eksClusterIdentityRequestStackRef
  , isProviderResourceRegistered
  , mkEksClientAuthRequest
  , mkEksClusterIdentityRequest
  , mkProviderCheckpointRef
  , mkProviderRevision
  , mkProviderSpotPriceQuery
  , mkProviderStackRef
  , mkPublicARecordRef
  , mkRegisteredProviderResources
  , mkSesBucketRef
  , mkSesDnsRef
  , mkSesIdentityRef
  , mkSesRuleSetRef
  , providerCheckpointRefText
  , providerIntentCoordinate
  , providerIntentResourceKey
  , providerRevisionNatural
  , providerSpotPriceInstanceType
  , providerSpotPriceProductDescription
  , providerStackRefText
  , publicARecordFqdn
  , publicARecordHostedZoneId
  , publicARecordTtl
  , publicARecordValues
  , registeredProviderResourceKeys
  , sesBucketRefText
  , sesDnsHostedZoneId
  , sesDnsIdentityDomain
  , sesDnsReceiveSubdomain
  , sesIdentityRefText
  , sesRuleSetCaptureBucket
  , sesRuleSetRecipient
  , sesRuleSetRefText
  , validateProviderStackConfig
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( TargetValueDigest
  , credentialGenerationValue
  , mkTargetValueDigest
  , sha256TargetValueDigest
  , targetValueDigestText
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

newtype ProviderIntentSigningKey = ProviderIntentSigningKey Ed25519.SecretKey

data ProviderIntentSigningKeyError
  = ProviderIntentSigningKeyInvalid
  deriving stock (Eq, Show)

mkProviderIntentSigningKey
  :: ByteString
  -> Either ProviderIntentSigningKeyError ProviderIntentSigningKey
mkProviderIntentSigningKey bytes = case Ed25519.secretKey bytes of
  CryptoFailed _ -> Left ProviderIntentSigningKeyInvalid
  CryptoPassed key -> Right (ProviderIntentSigningKey key)

newtype ProviderIntentPublicKey = ProviderIntentPublicKey ByteString
  deriving stock (Eq, Show)

mkProviderIntentPublicKey
  :: ByteString
  -> Either ProviderIntentSigningKeyError ProviderIntentPublicKey
mkProviderIntentPublicKey bytes = case Ed25519.publicKey bytes of
  CryptoFailed _ -> Left ProviderIntentSigningKeyInvalid
  CryptoPassed _ -> Right (ProviderIntentPublicKey bytes)

providerIntentPublicKeyBytes :: ProviderIntentPublicKey -> ByteString
providerIntentPublicKeyBytes (ProviderIntentPublicKey bytes) = bytes

providerIntentSigningPublicKey :: ProviderIntentSigningKey -> ProviderIntentPublicKey
providerIntentSigningPublicKey (ProviderIntentSigningKey privateKey) =
  ProviderIntentPublicKey (ByteArray.convert (Ed25519.toPublic privateKey))

newtype ProviderIssuerKeyGeneration = ProviderIssuerKeyGeneration Natural
  deriving stock (Eq, Ord, Show)

mkProviderIssuerKeyGeneration
  :: Natural
  -> Either ProviderCommittedIntentValueError ProviderIssuerKeyGeneration
mkProviderIssuerKeyGeneration value
  | value == 0 = Left ProviderIntentIssuerKeyGenerationMustBePositive
  | otherwise = Right (ProviderIssuerKeyGeneration value)

providerIssuerKeyGenerationValue :: ProviderIssuerKeyGeneration -> Natural
providerIssuerKeyGenerationValue (ProviderIssuerKeyGeneration value) = value

-- | Provider-Worker-local trust.  Resource registration is copied into this
-- record so even a validly signed intent cannot address an unaccepted resource.
data AcceptedProviderAuthority = AcceptedProviderAuthority
  { acceptedProviderIssuerGeneration :: !ProviderIssuerKeyGeneration
  , acceptedProviderIssuerIdentity :: !Text
  , acceptedProviderIssuerPublicKey :: !ProviderIntentPublicKey
  , acceptedProviderAuthorityEpoch :: !AuthorityEpoch
  , acceptedProviderFenceFloor :: !FencingToken
  , acceptedProviderRevision :: !ProviderRevision
  , acceptedProviderResources :: !RegisteredProviderResources
  }
  deriving stock (Eq, Show)

data AcceptedProviderAuthorityError
  = AcceptedProviderIssuerIdentityInvalid
  | AcceptedProviderAuthorityEpochMustBePositive
  | AcceptedProviderResourceSetEmpty
  | AcceptedProviderResourceSetOverBound !Int !Int
  | AcceptedProviderResourceKeyInvalid !Text
  deriving stock (Eq, Show)

mkAcceptedProviderAuthority
  :: ProviderIssuerKeyGeneration
  -> Text
  -> ProviderIntentPublicKey
  -> AuthorityEpoch
  -> FencingToken
  -> ProviderRevision
  -> RegisteredProviderResources
  -> Either AcceptedProviderAuthorityError AcceptedProviderAuthority
mkAcceptedProviderAuthority issuerGeneration issuerIdentity publicKey epoch fenceFloor revision resources = do
  validateAcceptedIssuerIdentity issuerIdentity
  validateAcceptedEpoch epoch
  validateAcceptedResources resources
  pure
    AcceptedProviderAuthority
      { acceptedProviderIssuerGeneration = issuerGeneration
      , acceptedProviderIssuerIdentity = issuerIdentity
      , acceptedProviderIssuerPublicKey = publicKey
      , acceptedProviderAuthorityEpoch = epoch
      , acceptedProviderFenceFloor = fenceFloor
      , acceptedProviderRevision = revision
      , acceptedProviderResources = resources
      }

data WireAcceptedProviderAuthority = WireAcceptedProviderAuthority
  { wireAcceptedProviderVersion :: !Word16
  , wireAcceptedProviderIssuerGeneration :: !Natural
  , wireAcceptedProviderIssuerIdentity :: !Text
  , wireAcceptedProviderPublicKey :: !ByteString
  , wireAcceptedProviderEpoch :: !Natural
  , wireAcceptedProviderFenceFloor :: !Natural
  , wireAcceptedProviderRevision :: !Natural
  , wireAcceptedProviderResources :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AcceptedProviderAuthorityCodecError
  = AcceptedProviderAuthorityTooLarge !Int !Int
  | AcceptedProviderAuthorityInvalid
  | AcceptedProviderAuthorityUnsupportedVersion !Word16
  | AcceptedProviderAuthorityNonCanonical
  | AcceptedProviderAuthorityValueInvalid !Text
  deriving stock (Eq, Show)

acceptedProviderAuthorityMaximumEncodedBytes :: Int
acceptedProviderAuthorityMaximumEncodedBytes = 32 * 1024

acceptedProviderAuthorityCodecVersion :: Word16
acceptedProviderAuthorityCodecVersion = 1

encodeAcceptedProviderAuthority :: AcceptedProviderAuthority -> ByteString
encodeAcceptedProviderAuthority =
  LazyByteString.toStrict . serialise . wireAcceptedProviderAuthority

decodeAcceptedProviderAuthority
  :: Int
  -> ByteString
  -> Either AcceptedProviderAuthorityCodecError AcceptedProviderAuthority
decodeAcceptedProviderAuthority maximumBytes bytes
  | maximumBytes < 0 || ByteString.length bytes > effectiveMaximum =
      Left (AcceptedProviderAuthorityTooLarge (ByteString.length bytes) effectiveMaximum)
  | otherwise = do
      wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left AcceptedProviderAuthorityInvalid
        Right decoded -> Right decoded
      if wireAcceptedProviderVersion wire == acceptedProviderAuthorityCodecVersion
        then Right ()
        else
          Left
            ( AcceptedProviderAuthorityUnsupportedVersion
                (wireAcceptedProviderVersion wire)
            )
      accepted <- acceptedProviderAuthorityFromWire wire
      if encodeAcceptedProviderAuthority accepted == bytes
        then Right accepted
        else Left AcceptedProviderAuthorityNonCanonical
 where
  effectiveMaximum = min maximumBytes acceptedProviderAuthorityMaximumEncodedBytes

wireAcceptedProviderAuthority
  :: AcceptedProviderAuthority
  -> WireAcceptedProviderAuthority
wireAcceptedProviderAuthority accepted =
  WireAcceptedProviderAuthority
    { wireAcceptedProviderVersion = acceptedProviderAuthorityCodecVersion
    , wireAcceptedProviderIssuerGeneration =
        providerIssuerKeyGenerationValue (acceptedProviderIssuerGeneration accepted)
    , wireAcceptedProviderIssuerIdentity = acceptedProviderIssuerIdentity accepted
    , wireAcceptedProviderPublicKey =
        providerIntentPublicKeyBytes (acceptedProviderIssuerPublicKey accepted)
    , wireAcceptedProviderEpoch = authorityEpochValue (acceptedProviderAuthorityEpoch accepted)
    , wireAcceptedProviderFenceFloor = fencingTokenValue (acceptedProviderFenceFloor accepted)
    , wireAcceptedProviderRevision = providerRevisionNatural (acceptedProviderRevision accepted)
    , wireAcceptedProviderResources =
        Set.toAscList (registeredProviderResourceKeys (acceptedProviderResources accepted))
    }

acceptedProviderAuthorityFromWire
  :: WireAcceptedProviderAuthority
  -> Either AcceptedProviderAuthorityCodecError AcceptedProviderAuthority
acceptedProviderAuthorityFromWire wire = do
  issuer <-
    mapAcceptedValue
      (mkProviderIssuerKeyGeneration (wireAcceptedProviderIssuerGeneration wire))
  public <-
    mapAcceptedSigning
      (mkProviderIntentPublicKey (wireAcceptedProviderPublicKey wire))
  revision <-
    mapAcceptedValue
      (mkProviderRevision (wireAcceptedProviderRevision wire))
  fence <-
    mapAcceptedValue
      (mkFencingToken (wireAcceptedProviderFenceFloor wire))
  let resources = mkRegisteredProviderResources (wireAcceptedProviderResources wire)
  mapAcceptedError
    ( mkAcceptedProviderAuthority
        issuer
        (wireAcceptedProviderIssuerIdentity wire)
        public
        (AuthorityEpoch (wireAcceptedProviderEpoch wire))
        fence
        revision
        resources
    )

data ProviderCommittedIntentSpec = ProviderCommittedIntentSpec
  { providerIntentIssuerGeneration :: !ProviderIssuerKeyGeneration
  , providerIntentIssuerIdentity :: !Text
  , providerIntentAuthorityEpoch :: !AuthorityEpoch
  , providerIntentOperationId :: !Text
  , providerIntentActionIndex :: !Natural
  , providerIntentCommitReceiptDigest :: !TargetValueDigest
  , providerIntentOwnerNonce :: !OwnerNonce
  , providerIntentFencingToken :: !FencingToken
  , providerIntentRevision :: !ProviderRevision
  , providerIntentAction :: !ProviderIntent
  , providerIntentDeadline :: !AuthorityTime
  , providerIntentIdempotencyKey :: !Text
  , providerIntentExpectedCredentialSession
      :: !(Maybe ProviderCredentialSessionBinding)
  , providerIntentExpectedAcceptedAuthority
      :: !(Maybe ProviderAcceptedAuthorityDigest)
  }
  deriving stock (Eq, Show)

data ProviderCommittedIntentValueError
  = ProviderIntentIssuerKeyGenerationMustBePositive
  | ProviderIntentIssuerIdentityInvalid
  | ProviderIntentAuthorityEpochMustBePositive
  | ProviderIntentOperationIdInvalid
  | ProviderIntentActionIndexOverBound !Natural !Natural
  | ProviderIntentResourceInvalid !Text
  | ProviderIntentRevisionBindingMismatch !ProviderRevision !ProviderRevision
  | ProviderIntentIdempotencyKeyInvalid
  deriving stock (Eq, Show)

data UnsignedProviderCommittedIntent = UnsignedProviderCommittedIntent
  { internalProviderCommittedIntentSpec :: !ProviderCommittedIntentSpec
  , internalProviderCommittedActionDigest :: !TargetValueDigest
  }
  deriving stock (Eq, Show)

mkUnsignedProviderCommittedIntent
  :: ProviderCommittedIntentSpec
  -> Either ProviderCommittedIntentValueError UnsignedProviderCommittedIntent
mkUnsignedProviderCommittedIntent spec = do
  validateProviderCommittedIntentSpec spec
  actionDigest <- providerCommitActionDigest spec
  pure
    UnsignedProviderCommittedIntent
      { internalProviderCommittedIntentSpec = spec
      , internalProviderCommittedActionDigest = actionDigest
      }

providerCommitActionDigest
  :: ProviderCommittedIntentSpec
  -> Either ProviderCommittedIntentValueError TargetValueDigest
providerCommitActionDigest spec = do
  validateProviderCommittedIntentSpec spec
  pure
    ( sha256TargetValueDigest
        (LazyByteString.toStrict (serialise (wireProviderActionBinding spec)))
    )

data WireProviderActionBinding = WireProviderActionBinding
  { wireProviderActionDomainVersion :: !Word16
  , wireProviderActionOperationId :: !Text
  , wireProviderBindingActionIndex :: !Natural
  , wireProviderActionCommitReceiptDigest :: !Text
  , wireProviderActionRevision :: !Natural
  , wireProviderActionIntent :: !WireProviderIntent
  , wireProviderActionIdempotencyKey :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

wireProviderActionBinding :: ProviderCommittedIntentSpec -> WireProviderActionBinding
wireProviderActionBinding spec =
  WireProviderActionBinding
    { wireProviderActionDomainVersion = providerCommittedActionBindingVersion
    , wireProviderActionOperationId = providerIntentOperationId spec
    , wireProviderBindingActionIndex = providerIntentActionIndex spec
    , wireProviderActionCommitReceiptDigest =
        targetValueDigestText (providerIntentCommitReceiptDigest spec)
    , wireProviderActionRevision = providerRevisionNatural (providerIntentRevision spec)
    , wireProviderActionIntent = wireProviderIntent (providerIntentAction spec)
    , wireProviderActionIdempotencyKey = providerIntentIdempotencyKey spec
    }

validateProviderCommittedIntentSpec
  :: ProviderCommittedIntentSpec
  -> Either ProviderCommittedIntentValueError ()
validateProviderCommittedIntentSpec spec = do
  case providerIntentIssuerGeneration spec of
    ProviderIssuerKeyGeneration 0 -> Left ProviderIntentIssuerKeyGenerationMustBePositive
    ProviderIssuerKeyGeneration _ -> Right ()
  validateBoundedIdentifier
    ProviderIntentIssuerIdentityInvalid
    (providerIntentIssuerIdentity spec)
  case providerIntentAuthorityEpoch spec of
    AuthorityEpoch 0 -> Left ProviderIntentAuthorityEpochMustBePositive
    AuthorityEpoch _ -> Right ()
  validateBoundedIdentifier
    ProviderIntentOperationIdInvalid
    (providerIntentOperationId spec)
  if providerIntentActionIndex spec <= maximumProviderActionIndex
    then Right ()
    else
      Left
        ( ProviderIntentActionIndexOverBound
            (providerIntentActionIndex spec)
            maximumProviderActionIndex
        )
  validateProviderIntentValue (providerIntentRevision spec) (providerIntentAction spec)
  validateBoundedIdentifier
    ProviderIntentIdempotencyKeyInvalid
    (providerIntentIdempotencyKey spec)

maximumProviderActionIndex :: Natural
maximumProviderActionIndex = 65535

validateProviderIntentValue
  :: ProviderRevision
  -> ProviderIntent
  -> Either ProviderCommittedIntentValueError ()
validateProviderIntentValue bound intent = do
  if validProviderResourceKey (providerIntentResourceKey intent)
    then Right ()
    else Left (ProviderIntentResourceInvalid (providerIntentResourceKey intent))
  case intent of
    ReconcileRegisteredStack ref requested config
      | requested /= bound ->
          Left (ProviderIntentRevisionBindingMismatch bound requested)
      | Left _ <- validateProviderStackConfig ref config ->
          Left (ProviderIntentResourceInvalid (providerIntentResourceKey intent))
    DestroyRegisteredStack ref requested config
      | requested /= bound ->
          Left (ProviderIntentRevisionBindingMismatch bound requested)
      | Left _ <- validateProviderStackConfig ref config ->
          Left (ProviderIntentResourceInvalid (providerIntentResourceKey intent))
    _ -> Right ()

data WireProviderIntent = WireProviderIntent
  { wireProviderIntentTag :: !Word16
  , wireProviderIntentResource :: !Text
  , wireProviderIntentRequestedRevision :: !(Maybe Natural)
  , wireProviderIntentStackConfig :: !(Maybe ProviderStackConfig)
  , wireProviderIntentSecondary :: !(Maybe Text)
  , wireProviderIntentTertiary :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

wireProviderIntent :: ProviderIntent -> WireProviderIntent
wireProviderIntent intent = case intent of
  ReconcileRegisteredStack ref revision config ->
    configured 0 ref revision config
  ObserveRegisteredStack ref ->
    simple 1 (providerStackRefText ref)
  ReadBackRegisteredStack ref ->
    simple 2 (providerStackRefText ref)
  BoundedScratchCheckpoint ref ->
    simple 3 (providerCheckpointRefText ref)
  ReconcileSesSendingIdentity ref ->
    simple 4 (sesIdentityRefText ref)
  ReconcileSesDkim ref ->
    simple 5 (sesIdentityRefText ref)
  ReconcileSesReceiptRules ref ->
    WireProviderIntent
      6
      (sesRuleSetRefText ref)
      Nothing
      Nothing
      (Just (sesRuleSetRecipient ref))
      (Just (sesBucketRefText (sesRuleSetCaptureBucket ref)))
  ReconcileSesCaptureBucket ref ->
    simple 7 (sesBucketRefText ref)
  DestroyRegisteredStack ref revision config ->
    configured 8 ref revision config
  ReapTestEbsVolumes clusterName -> simple 9 clusterName
  ObserveSpotPrice query ->
    WireProviderIntent
      10
      (providerSpotPriceInstanceType query)
      Nothing
      Nothing
      (Just (providerSpotPriceProductDescription query))
      Nothing
  ObserveOperationalIdentity -> simple 11 "operational-identity"
  ObserveProviderReadiness ProviderReadinessStsIdentity -> simple 12 "sts"
  ObserveProviderReadiness (ProviderReadinessRoute53Zone zoneId) -> simple 13 zoneId
  ReconcileSesDns ref ->
    WireProviderIntent
      14
      (sesDnsHostedZoneId ref)
      Nothing
      Nothing
      (Just (sesDnsIdentityDomain ref))
      (Just (sesDnsReceiveSubdomain ref))
  IssueEksClientAuth request ->
    WireProviderIntent
      15
      ( eksClientAuthRequestAccountId request
          <> ":"
          <> TextEncoding.decodeUtf8
            (Base64.encode (eksClientAuthRequestDestinationPublicKey request))
      )
      Nothing
      Nothing
      (Just (eksClientAuthRequestRegion request))
      (Just (eksClientAuthRequestClusterName request))
  ObservePublicARecord ref -> publicARecordWire 16 ref
  ReconcilePublicARecord ref -> publicARecordWire 17 ref
  ObserveTestEbsVolumes clusterName -> simple 18 clusterName
  ObserveEksClusterIdentity request ->
    WireProviderIntent
      19
      (providerStackRefText (eksClusterIdentityRequestStackRef request))
      Nothing
      Nothing
      (Just (eksClusterIdentityRequestAccountId request))
      ( Just
          ( eksClusterIdentityRequestRegion request
              <> ":"
              <> eksClusterIdentityRequestClusterName request
          )
      )
  ObserveProviderAwsScope -> simple 20 "provider-aws-scope"
 where
  simple tag resource = WireProviderIntent tag resource Nothing Nothing Nothing Nothing
  publicARecordWire tag ref =
    WireProviderIntent
      tag
      (publicARecordHostedZoneId ref)
      (Just (publicARecordTtl ref))
      Nothing
      (Just (publicARecordFqdn ref))
      (Just (Text.intercalate "," (publicARecordValues ref)))
  configured tag ref revision config =
    WireProviderIntent
      tag
      (providerStackRefText ref)
      (Just (providerRevisionNatural revision))
      (Just config)
      Nothing
      Nothing

data WireUnsignedProviderCommittedIntentV2 = WireUnsignedProviderCommittedIntentV2
  { wireProviderIntentV2Version :: !Word16
  , wireProviderV2IssuerGeneration :: !Natural
  , wireProviderV2IssuerIdentity :: !Text
  , wireProviderV2AuthorityEpoch :: !Natural
  , wireProviderV2OperationId :: !Text
  , wireProviderV2ActionIndex :: !Natural
  , wireProviderV2CommitReceiptDigest :: !Text
  , wireProviderV2OwnerNonce :: !Text
  , wireProviderV2FencingToken :: !Natural
  , wireProviderV2Revision :: !Natural
  , wireProviderV2Action :: !WireProviderIntent
  , wireProviderV2ActionDigest :: !Text
  , wireProviderV2DeadlineMicros :: !Natural
  , wireProviderV2IdempotencyKey :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireSignedProviderCommittedIntentV2 = WireSignedProviderCommittedIntentV2
  { wireSignedProviderV2Unsigned :: !WireUnsignedProviderCommittedIntentV2
  , wireSignedProviderV2Signature :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireProviderCredentialSessionBinding = WireProviderCredentialSessionBinding
  { wireProviderCredentialGeneration :: !Natural
  , wireProviderCredentialVaultVersion :: !Natural
  , wireProviderCredentialReceiptDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireUnsignedProviderCommittedIntentV3 = WireUnsignedProviderCommittedIntentV3
  { wireProviderIntentV3Version :: !Word16
  , wireProviderV3IssuerGeneration :: !Natural
  , wireProviderV3IssuerIdentity :: !Text
  , wireProviderV3AuthorityEpoch :: !Natural
  , wireProviderV3OperationId :: !Text
  , wireProviderV3ActionIndex :: !Natural
  , wireProviderV3CommitReceiptDigest :: !Text
  , wireProviderV3OwnerNonce :: !Text
  , wireProviderV3FencingToken :: !Natural
  , wireProviderV3Revision :: !Natural
  , wireProviderV3Action :: !WireProviderIntent
  , wireProviderV3ActionDigest :: !Text
  , wireProviderV3DeadlineMicros :: !Natural
  , wireProviderV3IdempotencyKey :: !Text
  , wireProviderV3ExpectedCredentialSession
      :: !(Maybe WireProviderCredentialSessionBinding)
  , wireProviderV3ExpectedAcceptedAuthority :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireSignedProviderCommittedIntentV3 = WireSignedProviderCommittedIntentV3
  { wireSignedProviderV3Unsigned :: !WireUnsignedProviderCommittedIntentV3
  , wireSignedProviderV3Signature :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data SignedProviderCommittedIntent = SignedProviderCommittedIntent
  { internalSignedProviderUnsigned :: !UnsignedProviderCommittedIntent
  , internalSignedProviderSignature :: !ByteString
  }
  deriving stock (Eq, Show)

signProviderCommittedIntent
  :: ProviderIntentSigningKey
  -> UnsignedProviderCommittedIntent
  -> SignedProviderCommittedIntent
signProviderCommittedIntent (ProviderIntentSigningKey privateKey) unsigned =
  let publicKey = Ed25519.toPublic privateKey
      signature = Ed25519.sign privateKey publicKey (canonicalUnsignedProviderBytes unsigned)
   in SignedProviderCommittedIntent
        { internalSignedProviderUnsigned = unsigned
        , internalSignedProviderSignature = ByteArray.convert signature
        }

data ProviderIntentCapabilitySigningError
  = ProviderIntentCapabilityPrincipalMismatch !CallerPrincipal
  | ProviderIntentCapabilityGenerationMismatch !Natural !Natural
  | ProviderIntentCapabilitySigningFailed !RequestSigningCapabilityError
  deriving stock (Eq, Show)

-- | Sign an already durable committed intent through the Lifecycle
-- Authority's opaque request-signing capability.  The caller principal and
-- key generation are checked before Transit is invoked, binding the inner
-- Provider authorization to the same exact Authority identity trusted by the
-- worker's outer authenticated route.
signProviderCommittedIntentWith
  :: (Monad m)
  => RequestSigningCapability m
  -> UnsignedProviderCommittedIntent
  -> m
       ( Either
           ProviderIntentCapabilitySigningError
           SignedProviderCommittedIntent
       )
signProviderCommittedIntentWith capability unsigned
  | requestSigningCapabilityPrincipal capability
      /= CallerService LifecycleAuthorityRuntime =
      pure
        ( Left
            ( ProviderIntentCapabilityPrincipalMismatch
                (requestSigningCapabilityPrincipal capability)
            )
        )
  | actualGeneration /= expectedGeneration =
      pure
        ( Left
            ( ProviderIntentCapabilityGenerationMismatch
                expectedGeneration
                actualGeneration
            )
        )
  | otherwise = do
      signedBytes <-
        signCanonicalBytesWithRequestCapability
          capability
          (canonicalUnsignedProviderBytes unsigned)
      pure $ case signedBytes of
        Left err -> Left (ProviderIntentCapabilitySigningFailed err)
        Right signature ->
          Right
            SignedProviderCommittedIntent
              { internalSignedProviderUnsigned = unsigned
              , internalSignedProviderSignature = signature
              }
 where
  expectedGeneration =
    providerIssuerKeyGenerationValue
      ( providerIntentIssuerGeneration
          (internalProviderCommittedIntentSpec unsigned)
      )
  actualGeneration =
    signingKeyGenerationValue (requestSigningCapabilityGeneration capability)

data ProviderCommittedIntentCodecError
  = ProviderCommittedIntentTooLarge !Int !Int
  | ProviderCommittedIntentInvalid
  | ProviderCommittedIntentUnsupportedVersion !Word16
  | ProviderCommittedIntentUnsupportedAction !Word16
  | ProviderCommittedIntentSignatureWidthInvalid !Int
  | ProviderCommittedIntentValueInvalid !Text
  | ProviderCommittedIntentActionDigestInvalid
  | ProviderCommittedIntentNonCanonical
  deriving stock (Eq, Show)

providerCommittedIntentMaximumEncodedBytes :: Int
providerCommittedIntentMaximumEncodedBytes = 32 * 1024

providerCommittedActionBindingVersion :: Word16
providerCommittedActionBindingVersion = 2

providerCommittedIntentV2CodecVersion :: Word16
providerCommittedIntentV2CodecVersion = 2

providerCommittedIntentV3CodecVersion :: Word16
providerCommittedIntentV3CodecVersion = 3

encodeSignedProviderCommittedIntent :: SignedProviderCommittedIntent -> ByteString
encodeSignedProviderCommittedIntent signed =
  LazyByteString.toStrict $ case providerIntentEnvelopeVersion signed of
    ProviderIntentEnvelopeV2 -> serialise (wireSignedProviderCommittedIntentV2 signed)
    ProviderIntentEnvelopeV3 -> serialise (wireSignedProviderCommittedIntentV3 signed)

decodeSignedProviderCommittedIntent
  :: Int
  -> ByteString
  -> Either ProviderCommittedIntentCodecError SignedProviderCommittedIntent
decodeSignedProviderCommittedIntent maximumBytes bytes
  | maximumBytes < 0 || ByteString.length bytes > effectiveMaximum =
      Left (ProviderCommittedIntentTooLarge (ByteString.length bytes) effectiveMaximum)
  | otherwise = case decodeWireSignedProviderIntentV2 bytes of
      Just wire -> decodeSignedProviderCommittedIntentV2 bytes wire
      Nothing -> case decodeWireSignedProviderIntentV3 bytes of
        Just wire -> decodeSignedProviderCommittedIntentV3 bytes wire
        Nothing -> Left ProviderCommittedIntentInvalid
 where
  effectiveMaximum = min maximumBytes providerCommittedIntentMaximumEncodedBytes

data ProviderIntentEnvelopeVersion
  = ProviderIntentEnvelopeV2
  | ProviderIntentEnvelopeV3

providerIntentEnvelopeVersion
  :: SignedProviderCommittedIntent -> ProviderIntentEnvelopeVersion
providerIntentEnvelopeVersion signed =
  providerIntentUnsignedEnvelopeVersion (internalSignedProviderUnsigned signed)

providerIntentUnsignedEnvelopeVersion
  :: UnsignedProviderCommittedIntent -> ProviderIntentEnvelopeVersion
providerIntentUnsignedEnvelopeVersion unsigned =
  let spec = internalProviderCommittedIntentSpec unsigned
   in case
        ( providerIntentExpectedCredentialSession spec
        , providerIntentExpectedAcceptedAuthority spec
        )
        of
          (Nothing, Nothing) -> ProviderIntentEnvelopeV2
          _ -> ProviderIntentEnvelopeV3

decodeWireSignedProviderIntentV2
  :: ByteString -> Maybe WireSignedProviderCommittedIntentV2
decodeWireSignedProviderIntentV2 =
  either (const Nothing) Just
    . deserialiseOrFail
    . LazyByteString.fromStrict

decodeWireSignedProviderIntentV3
  :: ByteString -> Maybe WireSignedProviderCommittedIntentV3
decodeWireSignedProviderIntentV3 =
  either (const Nothing) Just
    . deserialiseOrFail
    . LazyByteString.fromStrict

decodeSignedProviderCommittedIntentV2
  :: ByteString
  -> WireSignedProviderCommittedIntentV2
  -> Either ProviderCommittedIntentCodecError SignedProviderCommittedIntent
decodeSignedProviderCommittedIntentV2 bytes wire = do
  let unsignedWire = wireSignedProviderV2Unsigned wire
  validateProviderIntentWireVersion
    providerCommittedIntentV2CodecVersion
    (wireProviderIntentV2Version unsignedWire)
  validateProviderIntentSignatureWidth (wireSignedProviderV2Signature wire)
  unsigned <- unsignedProviderIntentFromWireV2 unsignedWire
  validateProviderIntentActionDigest
    unsigned
    (wireProviderV2ActionDigest unsignedWire)
  validateCanonicalSignedProviderIntent
    bytes
    SignedProviderCommittedIntent
      { internalSignedProviderUnsigned = unsigned
      , internalSignedProviderSignature = wireSignedProviderV2Signature wire
      }

decodeSignedProviderCommittedIntentV3
  :: ByteString
  -> WireSignedProviderCommittedIntentV3
  -> Either ProviderCommittedIntentCodecError SignedProviderCommittedIntent
decodeSignedProviderCommittedIntentV3 bytes wire = do
  let unsignedWire = wireSignedProviderV3Unsigned wire
  validateProviderIntentWireVersion
    providerCommittedIntentV3CodecVersion
    (wireProviderIntentV3Version unsignedWire)
  validateProviderIntentSignatureWidth (wireSignedProviderV3Signature wire)
  unsigned <- unsignedProviderIntentFromWireV3 unsignedWire
  validateProviderIntentActionDigest
    unsigned
    (wireProviderV3ActionDigest unsignedWire)
  validateCanonicalSignedProviderIntent
    bytes
    SignedProviderCommittedIntent
      { internalSignedProviderUnsigned = unsigned
      , internalSignedProviderSignature = wireSignedProviderV3Signature wire
      }

validateProviderIntentWireVersion
  :: Word16 -> Word16 -> Either ProviderCommittedIntentCodecError ()
validateProviderIntentWireVersion expected actual
  | actual == expected = Right ()
  | otherwise = Left (ProviderCommittedIntentUnsupportedVersion actual)

validateProviderIntentSignatureWidth
  :: ByteString -> Either ProviderCommittedIntentCodecError ()
validateProviderIntentSignatureWidth signature
  | ByteString.length signature == 64 = Right ()
  | otherwise =
      Left
        (ProviderCommittedIntentSignatureWidthInvalid (ByteString.length signature))

validateProviderIntentActionDigest
  :: UnsignedProviderCommittedIntent
  -> Text
  -> Either ProviderCommittedIntentCodecError ()
validateProviderIntentActionDigest unsigned wireDigest
  | targetValueDigestText (internalProviderCommittedActionDigest unsigned)
      == wireDigest = Right ()
  | otherwise = Left ProviderCommittedIntentActionDigestInvalid

validateCanonicalSignedProviderIntent
  :: ByteString
  -> SignedProviderCommittedIntent
  -> Either ProviderCommittedIntentCodecError SignedProviderCommittedIntent
validateCanonicalSignedProviderIntent bytes signed
  | encodeSignedProviderCommittedIntent signed == bytes = Right signed
  | otherwise = Left ProviderCommittedIntentNonCanonical

wireSignedProviderCommittedIntentV2
  :: SignedProviderCommittedIntent
  -> WireSignedProviderCommittedIntentV2
wireSignedProviderCommittedIntentV2 signed =
  WireSignedProviderCommittedIntentV2
    { wireSignedProviderV2Unsigned =
        wireUnsignedProviderCommittedIntentV2
          (internalSignedProviderUnsigned signed)
    , wireSignedProviderV2Signature = internalSignedProviderSignature signed
    }

wireSignedProviderCommittedIntentV3
  :: SignedProviderCommittedIntent
  -> WireSignedProviderCommittedIntentV3
wireSignedProviderCommittedIntentV3 signed =
  WireSignedProviderCommittedIntentV3
    { wireSignedProviderV3Unsigned =
        wireUnsignedProviderCommittedIntentV3
          (internalSignedProviderUnsigned signed)
    , wireSignedProviderV3Signature = internalSignedProviderSignature signed
    }

wireUnsignedProviderCommittedIntentV2
  :: UnsignedProviderCommittedIntent
  -> WireUnsignedProviderCommittedIntentV2
wireUnsignedProviderCommittedIntentV2 unsigned =
  let spec = internalProviderCommittedIntentSpec unsigned
   in WireUnsignedProviderCommittedIntentV2
        { wireProviderIntentV2Version = providerCommittedIntentV2CodecVersion
        , wireProviderV2IssuerGeneration =
            providerIssuerKeyGenerationValue (providerIntentIssuerGeneration spec)
        , wireProviderV2IssuerIdentity = providerIntentIssuerIdentity spec
        , wireProviderV2AuthorityEpoch = authorityEpochValue (providerIntentAuthorityEpoch spec)
        , wireProviderV2OperationId = providerIntentOperationId spec
        , wireProviderV2ActionIndex = providerIntentActionIndex spec
        , wireProviderV2CommitReceiptDigest =
            targetValueDigestText (providerIntentCommitReceiptDigest spec)
        , wireProviderV2OwnerNonce = ownerNonceText (providerIntentOwnerNonce spec)
        , wireProviderV2FencingToken = fencingTokenValue (providerIntentFencingToken spec)
        , wireProviderV2Revision = providerRevisionNatural (providerIntentRevision spec)
        , wireProviderV2Action = wireProviderIntent (providerIntentAction spec)
        , wireProviderV2ActionDigest =
            targetValueDigestText (internalProviderCommittedActionDigest unsigned)
        , wireProviderV2DeadlineMicros = authorityTimeMicros (providerIntentDeadline spec)
        , wireProviderV2IdempotencyKey = providerIntentIdempotencyKey spec
        }

wireUnsignedProviderCommittedIntentV3
  :: UnsignedProviderCommittedIntent
  -> WireUnsignedProviderCommittedIntentV3
wireUnsignedProviderCommittedIntentV3 unsigned =
  let spec = internalProviderCommittedIntentSpec unsigned
   in WireUnsignedProviderCommittedIntentV3
        { wireProviderIntentV3Version = providerCommittedIntentV3CodecVersion
        , wireProviderV3IssuerGeneration =
            providerIssuerKeyGenerationValue (providerIntentIssuerGeneration spec)
        , wireProviderV3IssuerIdentity = providerIntentIssuerIdentity spec
        , wireProviderV3AuthorityEpoch = authorityEpochValue (providerIntentAuthorityEpoch spec)
        , wireProviderV3OperationId = providerIntentOperationId spec
        , wireProviderV3ActionIndex = providerIntentActionIndex spec
        , wireProviderV3CommitReceiptDigest =
            targetValueDigestText (providerIntentCommitReceiptDigest spec)
        , wireProviderV3OwnerNonce = ownerNonceText (providerIntentOwnerNonce spec)
        , wireProviderV3FencingToken = fencingTokenValue (providerIntentFencingToken spec)
        , wireProviderV3Revision = providerRevisionNatural (providerIntentRevision spec)
        , wireProviderV3Action = wireProviderIntent (providerIntentAction spec)
        , wireProviderV3ActionDigest =
            targetValueDigestText (internalProviderCommittedActionDigest unsigned)
        , wireProviderV3DeadlineMicros = authorityTimeMicros (providerIntentDeadline spec)
        , wireProviderV3IdempotencyKey = providerIntentIdempotencyKey spec
        , wireProviderV3ExpectedCredentialSession =
            wireProviderCredentialSessionBinding
              <$> providerIntentExpectedCredentialSession spec
        , wireProviderV3ExpectedAcceptedAuthority =
            providerAcceptedAuthorityDigestText
              <$> providerIntentExpectedAcceptedAuthority spec
        }

wireProviderCredentialSessionBinding
  :: ProviderCredentialSessionBinding -> WireProviderCredentialSessionBinding
wireProviderCredentialSessionBinding binding =
  WireProviderCredentialSessionBinding
    { wireProviderCredentialGeneration =
        credentialGenerationValue (providerCredentialSessionGeneration binding)
    , wireProviderCredentialVaultVersion =
        providerCredentialSessionVaultVersion binding
    , wireProviderCredentialReceiptDigest =
        targetValueDigestText (providerCredentialSessionReceiptDigest binding)
    }

unsignedProviderIntentFromWireV2
  :: WireUnsignedProviderCommittedIntentV2
  -> Either ProviderCommittedIntentCodecError UnsignedProviderCommittedIntent
unsignedProviderIntentFromWireV2 wire = do
  issuer <-
    mapIntentValue
      (mkProviderIssuerKeyGeneration (wireProviderV2IssuerGeneration wire))
  receipt <-
    mapIntentValue
      (mkTargetValueDigest (wireProviderV2CommitReceiptDigest wire))
  owner <- mapIntentValue (mkOwnerNonce (wireProviderV2OwnerNonce wire))
  fence <- mapIntentValue (mkFencingToken (wireProviderV2FencingToken wire))
  revision <- mapIntentValue (mkProviderRevision (wireProviderV2Revision wire))
  action <- providerIntentFromWire (wireProviderV2Action wire)
  mapIntentValue
    ( mkUnsignedProviderCommittedIntent
        ProviderCommittedIntentSpec
          { providerIntentIssuerGeneration = issuer
          , providerIntentIssuerIdentity = wireProviderV2IssuerIdentity wire
          , providerIntentAuthorityEpoch = AuthorityEpoch (wireProviderV2AuthorityEpoch wire)
          , providerIntentOperationId = wireProviderV2OperationId wire
          , providerIntentActionIndex = wireProviderV2ActionIndex wire
          , providerIntentCommitReceiptDigest = receipt
          , providerIntentOwnerNonce = owner
          , providerIntentFencingToken = fence
          , providerIntentRevision = revision
          , providerIntentAction = action
          , providerIntentDeadline = authorityTimeFromMicros (wireProviderV2DeadlineMicros wire)
          , providerIntentIdempotencyKey = wireProviderV2IdempotencyKey wire
          , providerIntentExpectedCredentialSession = Nothing
          , providerIntentExpectedAcceptedAuthority = Nothing
          }
    )

unsignedProviderIntentFromWireV3
  :: WireUnsignedProviderCommittedIntentV3
  -> Either ProviderCommittedIntentCodecError UnsignedProviderCommittedIntent
unsignedProviderIntentFromWireV3 wire = do
  issuer <-
    mapIntentValue
      (mkProviderIssuerKeyGeneration (wireProviderV3IssuerGeneration wire))
  receipt <-
    mapIntentValue
      (mkTargetValueDigest (wireProviderV3CommitReceiptDigest wire))
  owner <- mapIntentValue (mkOwnerNonce (wireProviderV3OwnerNonce wire))
  fence <- mapIntentValue (mkFencingToken (wireProviderV3FencingToken wire))
  revision <- mapIntentValue (mkProviderRevision (wireProviderV3Revision wire))
  action <- providerIntentFromWire (wireProviderV3Action wire)
  expectedCredential <-
    traverse providerCredentialSessionBindingFromWire
      (wireProviderV3ExpectedCredentialSession wire)
  expectedAuthority <-
    traverse
      ( mapIntentValue
          . providerAcceptedAuthorityDigestFromTextInternal
      )
      (wireProviderV3ExpectedAcceptedAuthority wire)
  mapIntentValue
    ( mkUnsignedProviderCommittedIntent
        ProviderCommittedIntentSpec
          { providerIntentIssuerGeneration = issuer
          , providerIntentIssuerIdentity = wireProviderV3IssuerIdentity wire
          , providerIntentAuthorityEpoch = AuthorityEpoch (wireProviderV3AuthorityEpoch wire)
          , providerIntentOperationId = wireProviderV3OperationId wire
          , providerIntentActionIndex = wireProviderV3ActionIndex wire
          , providerIntentCommitReceiptDigest = receipt
          , providerIntentOwnerNonce = owner
          , providerIntentFencingToken = fence
          , providerIntentRevision = revision
          , providerIntentAction = action
          , providerIntentDeadline = authorityTimeFromMicros (wireProviderV3DeadlineMicros wire)
          , providerIntentIdempotencyKey = wireProviderV3IdempotencyKey wire
          , providerIntentExpectedCredentialSession = expectedCredential
          , providerIntentExpectedAcceptedAuthority = expectedAuthority
          }
    )

providerCredentialSessionBindingFromWire
  :: WireProviderCredentialSessionBinding
  -> Either ProviderCommittedIntentCodecError ProviderCredentialSessionBinding
providerCredentialSessionBindingFromWire wire =
  mapIntentValue
    ( providerCredentialSessionBindingFromWireInternal
        (wireProviderCredentialGeneration wire)
        (wireProviderCredentialVaultVersion wire)
        (wireProviderCredentialReceiptDigest wire)
    )

providerIntentFromWire
  :: WireProviderIntent
  -> Either ProviderCommittedIntentCodecError ProviderIntent
providerIntentFromWire wire = case wireProviderIntentTag wire of
  0 -> do
    ref <- mapIntentValue (mkProviderStackRef resource)
    revisionNumber <- requireRequestedRevision wire
    revision <- mapIntentValue (mkProviderRevision revisionNumber)
    config <- requireStackConfig wire
    mapIntentValue (validateProviderStackConfig ref config)
    noSecondary wire
    noTertiary wire
    pure (ReconcileRegisteredStack ref revision config)
  1 -> ObserveRegisteredStack <$> simpleRef (mkProviderStackRef resource)
  2 -> ReadBackRegisteredStack <$> simpleRef (mkProviderStackRef resource)
  3 -> BoundedScratchCheckpoint <$> simpleRef (mkProviderCheckpointRef resource)
  4 -> ReconcileSesSendingIdentity <$> simpleRef (mkSesIdentityRef resource)
  5 -> ReconcileSesDkim <$> simpleRef (mkSesIdentityRef resource)
  6 -> do
    noRevision wire
    noStackConfig wire
    recipient <- requireSecondary "missing SES receipt recipient" wire
    bucket <- requireTertiary "missing SES receipt capture bucket" wire
    ReconcileSesReceiptRules <$> mapIntentValue (mkSesRuleSetRef resource recipient bucket)
  7 -> ReconcileSesCaptureBucket <$> simpleRef (mkSesBucketRef resource)
  8 -> do
    ref <- mapIntentValue (mkProviderStackRef resource)
    revisionNumber <- requireRequestedRevision wire
    revision <- mapIntentValue (mkProviderRevision revisionNumber)
    config <- requireStackConfig wire
    mapIntentValue (validateProviderStackConfig ref config)
    noSecondary wire
    noTertiary wire
    pure (DestroyRegisteredStack ref revision config)
  9 -> ReapTestEbsVolumes <$> simpleText wire
  10 -> do
    noRevision wire
    noStackConfig wire
    productDescription <-
      maybe
        (Left (ProviderCommittedIntentValueInvalid "missing spot product description"))
        Right
        (wireProviderIntentSecondary wire)
    noTertiary wire
    ObserveSpotPrice <$> mapIntentValue (mkProviderSpotPriceQuery resource productDescription)
  11 -> do
    selector <- simpleText wire
    if selector == "operational-identity"
      then Right ObserveOperationalIdentity
      else Left (ProviderCommittedIntentValueInvalid "invalid operational identity selector")
  12 -> do
    selector <- simpleText wire
    if selector == "sts"
      then Right (ObserveProviderReadiness ProviderReadinessStsIdentity)
      else Left (ProviderCommittedIntentValueInvalid "invalid STS readiness selector")
  13 -> do
    zoneId <- simpleText wire
    pure (ObserveProviderReadiness (ProviderReadinessRoute53Zone zoneId))
  14 -> do
    noRevision wire
    noStackConfig wire
    identity <- requireSecondary "missing SES DNS identity" wire
    receiveSubdomain <- requireTertiary "missing SES DNS receive subdomain" wire
    ReconcileSesDns
      <$> mapIntentValue (mkSesDnsRef resource identity receiveSubdomain)
  15 -> do
    noRevision wire
    noStackConfig wire
    region <- requireSecondary "missing EKS client-auth region" wire
    cluster <- requireTertiary "missing EKS client-auth cluster" wire
    let (account, encodedKeyWithSeparator) = Text.breakOn ":" resource
    encodedKey <- case Text.stripPrefix ":" encodedKeyWithSeparator of
      Nothing -> Left (ProviderCommittedIntentValueInvalid "missing EKS client-auth public key")
      Just value -> Right value
    publicKey <-
      first
        (const (ProviderCommittedIntentValueInvalid "invalid EKS client-auth public key"))
        (Base64.decode (TextEncoding.encodeUtf8 encodedKey))
    IssueEksClientAuth
      <$> mapIntentValue (mkEksClientAuthRequest account region cluster publicKey)
  16 -> publicARecordIntent ObservePublicARecord
  17 -> publicARecordIntent ReconcilePublicARecord
  18 -> ObserveTestEbsVolumes <$> simpleText wire
  19 -> do
    noRevision wire
    noStackConfig wire
    stackRef <- mapIntentValue (mkProviderStackRef resource)
    account <- requireSecondary "missing EKS identity account" wire
    regionAndCluster <- requireTertiary "missing EKS identity region/cluster" wire
    let (region, clusterWithSeparator) = Text.breakOn ":" regionAndCluster
    cluster <- case Text.stripPrefix ":" clusterWithSeparator of
      Nothing -> Left (ProviderCommittedIntentValueInvalid "missing EKS identity cluster")
      Just value -> Right value
    ObserveEksClusterIdentity
      <$> mapIntentValue (mkEksClusterIdentityRequest stackRef account region cluster)
  20 -> do
    selector <- simpleText wire
    if selector == "provider-aws-scope"
      then Right ObserveProviderAwsScope
      else Left (ProviderCommittedIntentValueInvalid "invalid Provider AWS-scope selector")
  tag -> Left (ProviderCommittedIntentUnsupportedAction tag)
 where
  resource = wireProviderIntentResource wire
  simpleRef rebuilt = do
    noRevision wire
    noStackConfig wire
    noSecondary wire
    noTertiary wire
    mapIntentValue rebuilt
  simpleText value = do
    noRevision value
    noStackConfig value
    noSecondary value
    noTertiary value
    if Text.null resource || Text.length resource > 253 || Text.any isControl resource
      then Left (ProviderCommittedIntentValueInvalid "invalid provider selector")
      else Right resource
  publicARecordIntent constructor = do
    noStackConfig wire
    ttl <- requireRequestedRevision wire
    fqdn <- requireSecondary "missing public A-record FQDN" wire
    rawValues <- requireTertiary "missing public A-record values" wire
    constructor
      <$> mapIntentValue
        (mkPublicARecordRef resource fqdn ttl (Text.splitOn "," rawValues))
  noRevision value = do
    case wireProviderIntentRequestedRevision value of
      Nothing -> Right ()
      Just _ -> Left (ProviderCommittedIntentValueInvalid "unexpected action revision")
  noStackConfig value = case wireProviderIntentStackConfig value of
    Nothing -> Right ()
    Just _ -> Left (ProviderCommittedIntentValueInvalid "unexpected stack config")
  noSecondary value = case wireProviderIntentSecondary value of
    Nothing -> Right ()
    Just _ -> Left (ProviderCommittedIntentValueInvalid "unexpected secondary field")
  noTertiary value = case wireProviderIntentTertiary value of
    Nothing -> Right ()
    Just _ -> Left (ProviderCommittedIntentValueInvalid "unexpected tertiary field")

requireStackConfig
  :: WireProviderIntent
  -> Either ProviderCommittedIntentCodecError ProviderStackConfig
requireStackConfig wire = case wireProviderIntentStackConfig wire of
  Nothing -> Left (ProviderCommittedIntentValueInvalid "missing stack config")
  Just config -> Right config

requireRequestedRevision
  :: WireProviderIntent
  -> Either ProviderCommittedIntentCodecError Natural
requireRequestedRevision wire = case wireProviderIntentRequestedRevision wire of
  Nothing -> Left (ProviderCommittedIntentValueInvalid "missing stack reconcile revision")
  Just revision -> Right revision

requireSecondary
  :: Text
  -> WireProviderIntent
  -> Either ProviderCommittedIntentCodecError Text
requireSecondary detail wire =
  maybe
    (Left (ProviderCommittedIntentValueInvalid detail))
    Right
    (wireProviderIntentSecondary wire)

requireTertiary
  :: Text
  -> WireProviderIntent
  -> Either ProviderCommittedIntentCodecError Text
requireTertiary detail wire =
  maybe
    (Left (ProviderCommittedIntentValueInvalid detail))
    Right
    (wireProviderIntentTertiary wire)

canonicalUnsignedProviderBytes :: UnsignedProviderCommittedIntent -> ByteString
canonicalUnsignedProviderBytes unsigned =
  LazyByteString.toStrict $ case providerIntentUnsignedEnvelopeVersion unsigned of
    ProviderIntentEnvelopeV2 -> serialise (wireUnsignedProviderCommittedIntentV2 unsigned)
    ProviderIntentEnvelopeV3 -> serialise (wireUnsignedProviderCommittedIntentV3 unsigned)

data VerifiedProviderCommittedIntent = VerifiedProviderCommittedIntent
  { internalVerifiedProviderUnsigned :: !UnsignedProviderCommittedIntent
  , internalVerifiedProviderAuthority :: !AcceptedProviderAuthority
  }

data ProviderIntentVerificationError
  = ProviderIntentPublicKeyInvalid
  | ProviderIntentSignatureInvalid
  | ProviderIntentAuthenticationFailed
  | ProviderIntentIssuerGenerationMismatch
      !ProviderIssuerKeyGeneration
      !ProviderIssuerKeyGeneration
  | ProviderIntentIssuerIdentityMismatch !Text !Text
  | ProviderIntentAuthorityEpochMismatch !AuthorityEpoch !AuthorityEpoch
  | ProviderIntentFenceBelowFloor !FencingToken !FencingToken
  | ProviderIntentRevisionMismatch !ProviderRevision !ProviderRevision
  | ProviderIntentUnregisteredResource !Text
  | ProviderIntentActionDigestMismatch
  | ProviderIntentDeadlineReached !AuthorityTime !AuthorityTime
  deriving stock (Eq, Show)

verifySignedProviderCommittedIntent
  :: AcceptedProviderAuthority
  -> AuthorityTime
  -> SignedProviderCommittedIntent
  -> Either ProviderIntentVerificationError VerifiedProviderCommittedIntent
verifySignedProviderCommittedIntent accepted now signed = do
  public <- parseProviderIntentPublicKey (acceptedProviderIssuerPublicKey accepted)
  signature <- parseProviderIntentSignature (internalSignedProviderSignature signed)
  if Ed25519.verify public (canonicalUnsignedProviderBytes unsigned) signature
    then Right ()
    else Left ProviderIntentAuthenticationFailed
  let spec = internalProviderCommittedIntentSpec unsigned
  if providerIntentIssuerGeneration spec == acceptedProviderIssuerGeneration accepted
    then Right ()
    else
      Left
        ( ProviderIntentIssuerGenerationMismatch
            (acceptedProviderIssuerGeneration accepted)
            (providerIntentIssuerGeneration spec)
        )
  if providerIntentIssuerIdentity spec == acceptedProviderIssuerIdentity accepted
    then Right ()
    else
      Left
        ( ProviderIntentIssuerIdentityMismatch
            (acceptedProviderIssuerIdentity accepted)
            (providerIntentIssuerIdentity spec)
        )
  if providerIntentAuthorityEpoch spec == acceptedProviderAuthorityEpoch accepted
    then Right ()
    else
      Left
        ( ProviderIntentAuthorityEpochMismatch
            (acceptedProviderAuthorityEpoch accepted)
            (providerIntentAuthorityEpoch spec)
        )
  if providerIntentFencingToken spec >= acceptedProviderFenceFloor accepted
    then Right ()
    else
      Left
        ( ProviderIntentFenceBelowFloor
            (acceptedProviderFenceFloor accepted)
            (providerIntentFencingToken spec)
        )
  if providerIntentRevision spec == acceptedProviderRevision accepted
    then Right ()
    else
      Left
        ( ProviderIntentRevisionMismatch
            (acceptedProviderRevision accepted)
            (providerIntentRevision spec)
        )
  let resource = providerIntentResourceKey (providerIntentAction spec)
  if isProviderResourceRegistered resource (acceptedProviderResources accepted)
    then Right ()
    else Left (ProviderIntentUnregisteredResource resource)
  expectedAction <-
    either
      (const (Left ProviderIntentActionDigestMismatch))
      Right
      (providerCommitActionDigest spec)
  if expectedAction == internalProviderCommittedActionDigest unsigned
    then Right ()
    else Left ProviderIntentActionDigestMismatch
  if authorityTimeMicros now < authorityTimeMicros (providerIntentDeadline spec)
    then
      Right
        VerifiedProviderCommittedIntent
          { internalVerifiedProviderUnsigned = unsigned
          , internalVerifiedProviderAuthority = accepted
          }
    else Left (ProviderIntentDeadlineReached now (providerIntentDeadline spec))
 where
  unsigned = internalSignedProviderUnsigned signed

newtype ProviderWorkerTrustRepository m = ProviderWorkerTrustRepository
  { readAcceptedProviderAuthority :: m (Either Text AcceptedProviderAuthority)
  }

data ProviderWorkerExecutionBoundary m session = ProviderWorkerExecutionBoundary
  { providerExecutionTrustRepository :: !(ProviderWorkerTrustRepository m)
  , providerExecutionAuthorityNow :: m (Either Text AuthorityTime)
  , providerExecutionNarrowSession :: !(ProviderNarrowSessionRunner m session)
  , providerExecutionCapabilities :: !(ProviderIntentCapabilities m session)
  }

mkProviderWorkerExecutionBoundary
  :: ProviderWorkerTrustRepository m
  -> m (Either Text AuthorityTime)
  -> ProviderNarrowSessionRunner m session
  -> ProviderIntentCapabilities m session
  -> ProviderWorkerExecutionBoundary m session
mkProviderWorkerExecutionBoundary trust now session capabilities =
  ProviderWorkerExecutionBoundary
    { providerExecutionTrustRepository = trust
    , providerExecutionAuthorityNow = now
    , providerExecutionNarrowSession = session
    , providerExecutionCapabilities = capabilities
    }

data ProviderIntentAdmissionError
  = ProviderIntentAdmissionCodecFailed !ProviderCommittedIntentCodecError
  | ProviderIntentAdmissionTrustUnavailable !Text
  | ProviderIntentAdmissionClockUnavailable !Text
  | ProviderIntentAdmissionRefused !ProviderIntentVerificationError
  deriving stock (Eq, Show)

-- | Stage one.  Malformed or non-canonical bytes are rejected before either
-- local trust or Authority time is consulted.
admitProviderCommittedIntent
  :: (Monad m)
  => Int
  -> ProviderWorkerExecutionBoundary m session
  -> ByteString
  -> m (Either ProviderIntentAdmissionError VerifiedProviderCommittedIntent)
admitProviderCommittedIntent maximumBytes boundary bytes =
  case decodeSignedProviderCommittedIntent maximumBytes bytes of
    Left err -> pure (Left (ProviderIntentAdmissionCodecFailed err))
    Right signed -> do
      acceptedResult <-
        readAcceptedProviderAuthority
          (providerExecutionTrustRepository boundary)
      case acceptedResult of
        Left detail -> pure (Left (ProviderIntentAdmissionTrustUnavailable detail))
        Right accepted -> do
          nowResult <- providerExecutionAuthorityNow boundary
          pure $ case nowResult of
            Left detail -> Left (ProviderIntentAdmissionClockUnavailable detail)
            Right now ->
              either
                (Left . ProviderIntentAdmissionRefused)
                Right
                (verifySignedProviderCommittedIntent accepted now signed)

data ProviderIntentExecutionResult
  = ProviderIntentExecutionApplied !ProviderIntentCoordinate !Text
  | ProviderIntentExecutionAlreadySatisfied !ProviderIntentCoordinate !Text
  | ProviderIntentExecutionObserved !ProviderIntentCoordinate !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | One terminal Provider result bound to the exact admitted signed intent
-- that produced it.  The constructor is deliberately private: a raw wire
-- result, even one with syntactically valid evidence, cannot be promoted into
-- lifecycle authority without passing admission and execution under the
-- Provider Worker's current trust record.
data ExecutedProviderIntent = ExecutedProviderIntent
  { internalExecutedProviderVerified :: !VerifiedProviderCommittedIntent
  , internalExecutedProviderResult :: !ProviderIntentExecutionResult
  , internalExecutedProviderCredentialSession
      :: !(Maybe ProviderCredentialSessionBinding)
  , internalExecutedProviderAcceptedAuthority
      :: !ProviderAcceptedAuthorityDigest
  }

executedProviderIntentAction :: ExecutedProviderIntent -> ProviderIntent
executedProviderIntentAction executed =
  providerIntentAction (executedProviderIntentSpec executed)

executedProviderIntentCoordinate
  :: ExecutedProviderIntent -> ProviderIntentCoordinate
executedProviderIntentCoordinate executed =
  executionResultCoordinate (internalExecutedProviderResult executed)

executedProviderIntentOperationId :: ExecutedProviderIntent -> Text
executedProviderIntentOperationId executed =
  providerIntentOperationId (executedProviderIntentSpec executed)

executedProviderIntentRevision :: ExecutedProviderIntent -> ProviderRevision
executedProviderIntentRevision executed =
  providerIntentRevision (executedProviderIntentSpec executed)

executedProviderIntentCredentialSessionBinding
  :: ExecutedProviderIntent -> Maybe ProviderCredentialSessionBinding
executedProviderIntentCredentialSessionBinding =
  internalExecutedProviderCredentialSession

executedProviderIntentAcceptedAuthorityDigest
  :: ExecutedProviderIntent -> ProviderAcceptedAuthorityDigest
executedProviderIntentAcceptedAuthorityDigest =
  internalExecutedProviderAcceptedAuthority

executedProviderIntentResult
  :: ExecutedProviderIntent -> ProviderIntentExecutionResult
executedProviderIntentResult = internalExecutedProviderResult

executedProviderIntentSpec
  :: ExecutedProviderIntent -> ProviderCommittedIntentSpec
executedProviderIntentSpec =
  internalProviderCommittedIntentSpec
    . internalVerifiedProviderUnsigned
    . internalExecutedProviderVerified

executionResultCoordinate
  :: ProviderIntentExecutionResult -> ProviderIntentCoordinate
executionResultCoordinate result = case result of
  ProviderIntentExecutionApplied coordinate _ -> coordinate
  ProviderIntentExecutionAlreadySatisfied coordinate _ -> coordinate
  ProviderIntentExecutionObserved coordinate _ -> coordinate

data ProviderIntentExecutionError
  = ProviderIntentExecutionTrustUnavailable !Text
  | ProviderIntentExecutionTrustChanged
  | ProviderIntentExecutionAcceptedAuthorityBindingMismatch
  | ProviderIntentExecutionClockUnavailable !Text
  | ProviderIntentExecutionDeadlineReached !AuthorityTime !AuthorityTime
  | ProviderIntentExecutionSessionUnavailable !Text
  | ProviderIntentExecutionCredentialSessionBindingMissing
  | ProviderIntentExecutionCredentialSessionBindingMismatch
  | ProviderIntentExecutionObservationUnavailable !Text
  | ProviderIntentExecutionReadOnlyUnavailable !Text
  | ProviderIntentExecutionMutationNotConfirmed !Text
  | ProviderIntentExecutionReadBackUnavailable !Text
  | ProviderIntentExecutionEvidenceInvalid !Text
  deriving stock (Eq, Show)

-- | Fixed, non-authorizing diagnostics for the opaque credential-binding
-- join.  No binding or constructor escapes through this value.
data ProviderIntentCredentialBindingRegression =
  ProviderIntentCredentialBindingRegression
  { providerIntentCredentialBindingRegressionUnboundAccepted :: !Bool
  , providerIntentCredentialBindingRegressionExactAccepted :: !Bool
  , providerIntentCredentialBindingRegressionMissingRefused :: !Bool
  , providerIntentCredentialBindingRegressionMismatchRefused :: !Bool
  }

fixedProviderIntentCredentialBindingRegression
  :: ProviderIntentCredentialBindingRegression
fixedProviderIntentCredentialBindingRegression =
  case (fixedCredentialBinding 11 "a", fixedCredentialBinding 12 "b") of
    (Right exact, Right other) ->
      ProviderIntentCredentialBindingRegression
        { providerIntentCredentialBindingRegressionUnboundAccepted =
            credentialSessionExpectation Nothing Nothing == Right ()
        , providerIntentCredentialBindingRegressionExactAccepted =
            credentialSessionExpectation (Just exact) (Just exact) == Right ()
        , providerIntentCredentialBindingRegressionMissingRefused =
            credentialSessionExpectation (Just exact) Nothing
              == Left ProviderIntentExecutionCredentialSessionBindingMissing
        , providerIntentCredentialBindingRegressionMismatchRefused =
            credentialSessionExpectation (Just exact) (Just other)
              == Left ProviderIntentExecutionCredentialSessionBindingMismatch
        }
    _ ->
      ProviderIntentCredentialBindingRegression False False False False
 where
  fixedCredentialBinding version digit =
    providerCredentialSessionBindingFromWireInternal
      7
      version
      (Text.replicate 64 digit)

credentialSessionExpectation
  :: Maybe ProviderCredentialSessionBinding
  -> Maybe ProviderCredentialSessionBinding
  -> Either ProviderIntentExecutionError ()
credentialSessionExpectation expected actual = case expected of
  Nothing -> Right ()
  Just exact -> case actual of
    Nothing -> Left ProviderIntentExecutionCredentialSessionBindingMissing
    Just observed
      | observed == exact -> Right ()
      | otherwise -> Left ProviderIntentExecutionCredentialSessionBindingMismatch

-- | Compatibility projection for callers that consume only the terminal wire
-- result.  It cannot be fed to capability-sensitive adapters; those require
-- the opaque value returned by 'executeVerifiedProviderIntentBound'.
executeVerifiedProviderIntent
  :: (Monad m)
  => ProviderWorkerExecutionBoundary m session
  -> VerifiedProviderCommittedIntent
  -> m (Either ProviderIntentExecutionError ProviderIntentExecutionResult)
executeVerifiedProviderIntent boundary verified =
  fmap
    (fmap executedProviderIntentResult)
    (executeVerifiedProviderIntentBound boundary verified)

-- | Stage two.  Local trust and time are revalidated before the rank-2 session
-- opens.  A successful terminal result is sealed together with the exact
-- admitted intent. Mutation executes zero or one apply and always uses
-- authoritative observation, never an apply return value, to decide success.
executeVerifiedProviderIntentBound
  :: (Monad m)
  => ProviderWorkerExecutionBoundary m session
  -> VerifiedProviderCommittedIntent
  -> m (Either ProviderIntentExecutionError ExecutedProviderIntent)
executeVerifiedProviderIntentBound boundary verified = do
  acceptedResult <-
    readAcceptedProviderAuthority
      (providerExecutionTrustRepository boundary)
  case acceptedResult of
    Left detail -> pure (Left (ProviderIntentExecutionTrustUnavailable detail))
    Right currentAccepted
      | currentAccepted /= internalVerifiedProviderAuthority verified ->
          pure (Left ProviderIntentExecutionTrustChanged)
      | not (expectedAcceptedAuthorityMatches currentAccepted) ->
          pure (Left ProviderIntentExecutionAcceptedAuthorityBindingMismatch)
      | otherwise -> do
          nowResult <- providerExecutionAuthorityNow boundary
          case nowResult of
            Left detail -> pure (Left (ProviderIntentExecutionClockUnavailable detail))
            Right now
              | authorityTimeMicros now >= authorityTimeMicros deadline ->
                  pure (Left (ProviderIntentExecutionDeadlineReached now deadline))
              | otherwise -> runNarrowSession
 where
  unsigned = internalVerifiedProviderUnsigned verified
  spec = internalProviderCommittedIntentSpec unsigned
  intent = providerIntentAction spec
  coordinate = providerIntentCoordinate intent
  deadline = providerIntentDeadline spec

  acceptedAuthorityDigest accepted =
    providerAcceptedAuthorityDigestFromCanonicalInternal
      (encodeAcceptedProviderAuthority accepted)

  expectedAcceptedAuthorityMatches accepted =
    case providerIntentExpectedAcceptedAuthority spec of
      Nothing -> True
      Just expected -> expected == acceptedAuthorityDigest accepted

  runNarrowSession = do
    sessionResult <-
      withProviderNarrowSession
        (providerExecutionNarrowSession boundary)
        intent
        deadline
        executeWithCredentialBinding
    pure $ case sessionResult of
      Left detail -> Left (ProviderIntentExecutionSessionUnavailable detail)
      Right (Left err) -> Left err
      Right (Right (result, actualCredentialBinding)) ->
        Right
          ExecutedProviderIntent
            { internalExecutedProviderVerified = verified
            , internalExecutedProviderResult = result
            , internalExecutedProviderCredentialSession = actualCredentialBinding
            , internalExecutedProviderAcceptedAuthority =
                acceptedAuthorityDigest (internalVerifiedProviderAuthority verified)
            }

  executeWithCredentialBinding actualBinding session =
    case
        credentialSessionExpectation
          (providerIntentExpectedCredentialSession spec)
          actualBinding
      of
      Left err -> pure (Right (Left err))
      Right () -> do
        result <- executeUnderSession session
        pure (Right (fmap (\terminal -> (terminal, actualBinding)) result))

  executeUnderSession session =
    case operationForProviderIntent (providerExecutionCapabilities boundary) intent of
      ProviderIntentReadOnly operation -> executeReadOnly session operation
      ProviderIntentMutation operation -> executeMutation session operation

  executeReadOnly session operation = do
    result <- runProviderReadOnly operation session coordinate
    pure $ case result of
      Left detail -> Left (ProviderIntentExecutionReadOnlyUnavailable detail)
      Right evidence ->
        ProviderIntentExecutionObserved coordinate
          <$> validateExecutionEvidence evidence

  executeMutation session operation = do
    before <- observeProviderMutation operation session coordinate
    case before of
      ProviderEffectSatisfied evidence ->
        pure
          ( ProviderIntentExecutionAlreadySatisfied coordinate
              <$> validateExecutionEvidence evidence
          )
      ProviderEffectUnobservable detail ->
        pure (Left (ProviderIntentExecutionObservationUnavailable detail))
      ProviderEffectNeedsApply _ -> do
        attempted <- applyProviderMutation operation session coordinate
        after <- observeProviderMutation operation session coordinate
        pure $ case after of
          ProviderEffectSatisfied evidence ->
            ProviderIntentExecutionApplied coordinate
              <$> validateExecutionEvidence evidence
          ProviderEffectNeedsApply detail ->
            Left
              ( ProviderIntentExecutionMutationNotConfirmed
                  (attemptDetail attempted <> detail)
              )
          ProviderEffectUnobservable detail ->
            Left
              ( ProviderIntentExecutionReadBackUnavailable
                  (attemptDetail attempted <> detail)
              )

validateExecutionEvidence
  :: Text
  -> Either ProviderIntentExecutionError Text
validateExecutionEvidence evidence
  | Text.null evidence = invalid
  | Text.length evidence > 4096 = invalid
  | Text.any isControl evidence = invalid
  | otherwise = Right evidence
 where
  invalid = Left (ProviderIntentExecutionEvidenceInvalid "provider evidence is invalid")

attemptDetail :: Either Text () -> Text
attemptDetail result = case result of
  Right () -> ""
  Left detail -> "provider apply response unavailable: " <> detail <> "; "

parseProviderIntentPublicKey
  :: ProviderIntentPublicKey
  -> Either ProviderIntentVerificationError Ed25519.PublicKey
parseProviderIntentPublicKey (ProviderIntentPublicKey bytes) = case Ed25519.publicKey bytes of
  CryptoFailed _ -> Left ProviderIntentPublicKeyInvalid
  CryptoPassed key -> Right key

parseProviderIntentSignature
  :: ByteString
  -> Either ProviderIntentVerificationError Ed25519.Signature
parseProviderIntentSignature bytes = case Ed25519.signature bytes of
  CryptoFailed _ -> Left ProviderIntentSignatureInvalid
  CryptoPassed signature -> Right signature

validateAcceptedIssuerIdentity :: Text -> Either AcceptedProviderAuthorityError ()
validateAcceptedIssuerIdentity value
  | validBoundedIdentifier value = Right ()
  | otherwise = Left AcceptedProviderIssuerIdentityInvalid

validateAcceptedEpoch :: AuthorityEpoch -> Either AcceptedProviderAuthorityError ()
validateAcceptedEpoch (AuthorityEpoch value)
  | value == 0 = Left AcceptedProviderAuthorityEpochMustBePositive
  | otherwise = Right ()

validateAcceptedResources
  :: RegisteredProviderResources
  -> Either AcceptedProviderAuthorityError ()
validateAcceptedResources resources
  | Set.null keys = Left AcceptedProviderResourceSetEmpty
  | Set.size keys > maximumAcceptedProviderResources =
      Left
        ( AcceptedProviderResourceSetOverBound
            (Set.size keys)
            maximumAcceptedProviderResources
        )
  | Just invalid <- Set.lookupMin (Set.filter (not . validProviderResourceKey) keys) =
      Left (AcceptedProviderResourceKeyInvalid invalid)
  | otherwise = Right ()
 where
  keys = registeredProviderResourceKeys resources

maximumAcceptedProviderResources :: Int
maximumAcceptedProviderResources = 256

validProviderResourceKey :: Text -> Bool
validProviderResourceKey value =
  not (Text.null value)
    && Text.length value <= 256
    && not (Text.any isControl value)

validBoundedIdentifier :: Text -> Bool
validBoundedIdentifier value =
  not (Text.null value)
    && Text.length value <= 128
    && not (Text.any (\character -> isControl character || isSpace character) value)

validateBoundedIdentifier
  :: ProviderCommittedIntentValueError
  -> Text
  -> Either ProviderCommittedIntentValueError ()
validateBoundedIdentifier failure value
  | validBoundedIdentifier value = Right ()
  | otherwise = Left failure

authorityEpochValue :: AuthorityEpoch -> Natural
authorityEpochValue (AuthorityEpoch value) = value

mapAcceptedValue
  :: (Show errorValue)
  => Either errorValue value
  -> Either AcceptedProviderAuthorityCodecError value
mapAcceptedValue =
  either (Left . AcceptedProviderAuthorityValueInvalid . Text.pack . show) Right

mapAcceptedSigning
  :: Either ProviderIntentSigningKeyError value
  -> Either AcceptedProviderAuthorityCodecError value
mapAcceptedSigning =
  either (Left . AcceptedProviderAuthorityValueInvalid . Text.pack . show) Right

mapAcceptedError
  :: Either AcceptedProviderAuthorityError value
  -> Either AcceptedProviderAuthorityCodecError value
mapAcceptedError =
  either (Left . AcceptedProviderAuthorityValueInvalid . Text.pack . show) Right

mapIntentValue
  :: (Show errorValue)
  => Either errorValue value
  -> Either ProviderCommittedIntentCodecError value
mapIntentValue =
  either (Left . ProviderCommittedIntentValueInvalid . Text.pack . show) Right
