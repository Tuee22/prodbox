{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production, read-only binding from retained Authority outboxes to the
-- signed one-shot Target-worker issuer.  The endpoint never accepts an
-- Authority coordinate from its caller: registration, projection codecs,
-- target identity, and physical store all come from fixed retained
-- configuration.
module Prodbox.ControlPlane.TargetIntentAuthorityProduction
  ( productionTargetIntentIssuerBoundary
  , selectRetainedAcmeEabDeliveryIntent
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Capacity.TargetWorkerBudget qualified as TargetWorkerBudget
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch)
import Prodbox.ControlPlane.InClusterAuthorityStore
  ( InClusterAuthorityStore
  , inClusterAuthorityModelBCasAdapter
  )
import Prodbox.ControlPlane.RetainedMaterialRepository
  ( retainedMaterialModelBCodec
  )
import Prodbox.ControlPlane.TargetAuthorityTrust
  ( renderTargetAuthorityTrustBoundaryCause
  )
import Prodbox.ControlPlane.TargetAuthorityTrustClient
  ( TargetAuthorityTrustClient
  , classifyTargetAuthorityTrustClientError
  , installAcceptedTargetAuthority
  )
import Prodbox.ControlPlane.TargetIntentAuthority
  ( AuthorizedPreparedTargetIntent
  , TargetIntentIssueRequest (..)
  , TargetIntentIssuerBoundary (..)
  , mkAuthorizedPreparedTargetIntent
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId (..)
  , targetSecretIdToken
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  , mkTargetAgentIdentity
  , targetAgentClusterIdentity
  , targetAgentIdentityText
  )
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( RetainedDeliveryIntent
  , RetainedMaterialAggregate
  , RetainedMaterialRef
  , RetainedMaterialSchema (RetainedAcmeEabMaterial)
  , SRetainedMaterialSchema (SRetainedAcmeEabMaterial)
  , mkRetainedMaterialRef
  , retainedDeliveryAttestationRef
  , retainedDeliveryDeadline
  , retainedDeliveryOperationId
  , retainedDeliverySourceReceipt
  , retainedDeliveryTarget
  , retainedDeliveryTargetGeneration
  , retainedMaterialPendingDeliveries
  , retainedMaterialRefText
  , retainedMaterialSchemaToken
  , retainedMaterialTargetText
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , mkCrossClusterDurableCoordinate
  )
import Prodbox.Lifecycle.CredentialProvisioner.ExternalIngress
  ( ExternalMaterialIngressState
  , externalMaterialIngressCurrentReceipt
  , externalMaterialIngressStateCodec
  , externalMaterialTargetReceiptDigest
  , externalMaterialTargetReceiptGeneration
  , externalMaterialTargetReceiptPermitId
  , externalMaterialTargetReceiptSourceReceipt
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( operatorMaterialPermitIdText
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( preparedCredentialTargetDeadline
  , preparedCredentialTargetFence
  , preparedCredentialTargetGeneration
  , preparedCredentialTargetId
  , preparedCredentialTargetOwnerNonce
  , preparedCredentialTargetReceiptDigest
  , preparedCredentialTargetSelectedAgent
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTargetOutbox
  ( PreparedCredentialTargetOutbox
  , preparedCredentialTargetOutboxCodec
  , preparedCredentialTargetOutboxObservation
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , addAuthorityDuration
  , authorityDurationFromMicros
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

-- | Bind the current compatibility SES target outbox to the new exact
-- @TargetSesSmtp@ worker lane.  The legacy projection identifies the selected
-- cluster, while the signed worker intent identifies the secret schema.  The
-- conversion is deliberately one-way and accepts only the registration's
-- canonical @secret/keycloak/smtp@ target (enforced by registration decoding).
-- Other selected-target schemas use their own retained aggregates and cannot
-- be smuggled through this compatibility binding.
productionTargetIntentIssuerBoundary
  :: InClusterAuthorityStore
  -> LongLivedCheckpointAuthority
  -> TargetAgentIdentity
  -> IO (Either Text AuthorityEpoch)
  -> IO (Either Text AuthorityTime)
  -> AuthorityManifestSigner IO
  -> Text
  -> TargetAuthorityTrustClient IO
  -> TargetIntentIssuerBoundary IO
productionTargetIntentIssuerBoundary store authority registeredAgentIdentity readEpoch readTime signer issuerIdentity trustClient =
  TargetIntentIssuerBoundary
    { readTargetIntentAuthorityEpoch = readEpoch
    , readTargetIntentAuthorityTime = readTime
    , readAuthorizedPreparedTargetIntent = readPreparedIntent
    , targetIntentAuthoritySigner = signer
    , targetIntentAuthorityIssuerIdentity = issuerIdentity
    , installIssuedTargetAuthority =
        \_ accepted ->
          fmap
            ( either
                ( Left
                    . renderTargetAuthorityTrustBoundaryCause
                    . classifyTargetAuthorityTrustClientError
                )
                Right
            )
            (installAcceptedTargetAuthority trustClient accepted)
    }
 where
  readPreparedIntent request = case targetIntentIssueTarget request of
    TargetSesSmtp -> observeAwsAdminPrepared request
    TargetAcmeEab -> observeExternalAcmeEab request
    TargetAwsCredential _ -> observeAwsAdminPrepared request
    TargetPublicEdgeTls -> observeOrCommitOperationAuthorization request
    TargetFederationCustody -> observeOrCommitOperationAuthorization request
    _ -> pure (Left "selected Target has no registered retained-material outbox")

  observeAwsAdminPrepared request =
    case awsAdminPreparedCoordinate authority request of
      Left detail -> pure (Left detail)
      Right coordinate -> do
        observed <-
          modelBObserve
            ( inClusterAuthorityModelBCasAdapter
                store
                authority
                preparedCredentialTargetOutboxCodec
            )
            coordinate
        pure (awsAdminPreparedFromObservation request observed)

  observeOrCommitOperationAuthorization request =
    if targetIntentIssueExpectedAgentIdentity request /= registeredAgentIdentity
      then pure (Left "target operation selected Agent differs from the registered rollout")
      else case operationAuthorizationCoordinate authority request of
        Left detail -> pure (Left detail)
        Right coordinate -> do
          let adapter =
                inClusterAuthorityModelBCasAdapter
                  store
                  authority
                  targetOperationAuthorizationCodec
          observed <- modelBObserve adapter coordinate
          case observed of
            ModelBMissing -> do
              nowResult <- readTime
              case nowResult of
                Left detail -> pure (Left detail)
                Right now -> case newOperationAuthorization now request of
                  Left detail -> pure (Left detail)
                  Right desired -> do
                    committed <-
                      modelBCompareAndSwap adapter (ModelBInitialize coordinate desired)
                    case committed of
                      ModelBCasApplied _ readBack ->
                        pure (authorizationMatchesRequest request readBack)
                      ModelBCasConflict _ -> reobserveOperation adapter coordinate request
                      ModelBCasRefusedCorrupt detail ->
                        pure (Left ("target operation authorization is corrupt: " <> detail))
                      ModelBCasEndpointUnready detail ->
                        pure (Left ("target operation authorization store is not ready: " <> detail))
                      ModelBCasUnobservable _ ->
                        -- A lost CAS response is resolved only by an exact
                        -- authoritative read-back; the effect is never retried.
                        reobserveOperation adapter coordinate request
            ModelBObserved _ authorization ->
              pure (authorizationMatchesRequest request authorization)
            ModelBCorrupt detail ->
              pure (Left ("target operation authorization is corrupt: " <> detail))
            ModelBEndpointUnready detail ->
              pure (Left ("target operation authorization store is not ready: " <> detail))
            ModelBUnobservable detail ->
              pure (Left ("target operation authorization is unobservable: " <> detail))

  reobserveOperation adapter coordinate request = do
    readBack <- modelBObserve adapter coordinate
    pure $ case readBack of
      ModelBObserved _ authorization ->
        authorizationMatchesRequest request authorization
      ModelBMissing -> Left "target operation authorization is absent after CAS"
      ModelBCorrupt detail ->
        Left ("target operation authorization is corrupt: " <> detail)
      ModelBEndpointUnready detail ->
        Left ("target operation authorization store is not ready: " <> detail)
      ModelBUnobservable detail ->
        Left ("target operation authorization is unobservable: " <> detail)

  observeExternalAcmeEab request =
    case mkClusterRetainedCoordinate authority "authority/external-material-ingress" of
      Left err ->
        pure (Left ("external EAB ingress coordinate invalid: " <> Text.pack (show err)))
      Right ingressCoordinate ->
        case mkCrossClusterDurableCoordinate
          authority
          ( "retained-material/delivery/"
              <> retainedMaterialSchemaToken SRetainedAcmeEabMaterial
              <> "/"
              <> targetAgentClusterIdentity registeredAgentIdentity
          ) of
          Left err ->
            pure (Left ("retained EAB delivery coordinate invalid: " <> Text.pack (show err)))
          Right deliveryCoordinate -> do
            ingressObserved <-
              modelBObserve
                ( inClusterAuthorityModelBCasAdapter
                    store
                    authority
                    (externalMaterialIngressStateCodec externalIngressMaximumBytes)
                )
                ingressCoordinate
            deliveryObserved <-
              modelBObserve
                ( inClusterAuthorityModelBCasAdapter
                    store
                    authority
                    (retainedMaterialModelBCodec SRetainedAcmeEabMaterial)
                )
                deliveryCoordinate
            pure
              ( externalAcmeEabPreparedFromObservations
                  registeredAgentIdentity
                  request
                  ingressObserved
                  deliveryObserved
              )

externalAcmeEabPreparedFromObservations
  :: TargetAgentIdentity
  -> TargetIntentIssueRequest
  -> ModelBObservation ExternalMaterialIngressState
  -> ModelBObservation (RetainedMaterialAggregate 'RetainedAcmeEabMaterial)
  -> Either Text AuthorizedPreparedTargetIntent
externalAcmeEabPreparedFromObservations registeredAgentIdentity request ingressObservation deliveryObservation = do
  state <- case ingressObservation of
    ModelBMissing -> Left "external EAB ingress outbox is absent"
    ModelBCorrupt detail -> Left ("external EAB ingress outbox is corrupt: " <> detail)
    ModelBEndpointUnready detail ->
      Left ("external EAB ingress outbox endpoint is not ready: " <> detail)
    ModelBUnobservable detail -> Left ("external EAB ingress outbox is unobservable: " <> detail)
    ModelBObserved _ value -> Right value
  receipt <-
    maybe
      (Left "external EAB custody receipt is not committed")
      Right
      (externalMaterialIngressCurrentReceipt state)
  aggregate <- case deliveryObservation of
    ModelBMissing -> Left "retained EAB delivery outbox is absent"
    ModelBCorrupt detail -> Left ("retained EAB delivery outbox is corrupt: " <> detail)
    ModelBEndpointUnready detail ->
      Left ("retained EAB delivery outbox endpoint is not ready: " <> detail)
    ModelBUnobservable detail -> Left ("retained EAB delivery outbox is unobservable: " <> detail)
    ModelBObserved _ value -> Right value
  unless
    ( externalMaterialTargetReceiptGeneration receipt
        == targetIntentIssueExpectedGeneration request
        && externalMaterialTargetReceiptDigest receipt
          == targetIntentIssueExpectedReceiptDigest request
    )
    (Left "external EAB Target-intent request differs from custody receipt")
  sourceReceipt <-
    mapLeftShow
      (mkRetainedMaterialRef (externalMaterialTargetReceiptSourceReceipt receipt))
  delivery <-
    selectRetainedAcmeEabDeliveryIntent
      registeredAgentIdentity
      request
      sourceReceipt
      (retainedMaterialPendingDeliveries aggregate)
  owner <-
    mapLeftShow
      ( mkOwnerNonce
          ( "external-"
              <> operatorMaterialPermitIdText
                (externalMaterialTargetReceiptPermitId receipt)
          )
      )
  fence <-
    mapLeftShow
      ( mkFencingToken
          ( credentialGenerationValue
              (externalMaterialTargetReceiptGeneration receipt)
          )
      )
  mkAuthorizedPreparedTargetIntent
    owner
    fence
    registeredAgentIdentity
    TargetAcmeEab
    (externalMaterialTargetReceiptGeneration receipt)
    (externalMaterialTargetReceiptDigest receipt)
    (retainedDeliveryDeadline delivery)

-- | Select the sole pending delivery that authorizes an ACME EAB Target
-- intent. The request names no deadline: the Authority recovers that value
-- from the exact durable retained-delivery outbox successor.
selectRetainedAcmeEabDeliveryIntent
  :: TargetAgentIdentity
  -> TargetIntentIssueRequest
  -> RetainedMaterialRef
  -> [RetainedDeliveryIntent 'RetainedAcmeEabMaterial]
  -> Either Text (RetainedDeliveryIntent 'RetainedAcmeEabMaterial)
selectRetainedAcmeEabDeliveryIntent registeredAgentIdentity request sourceReceipt pending = do
  unless
    ( targetIntentIssueTarget request == TargetAcmeEab
        && targetIntentIssueExpectedAgentIdentity request == registeredAgentIdentity
    )
    (Left "retained EAB Target-intent request differs from registered Target Agent")
  delivery <- case filter operationMatches pending of
    [] -> Left "retained EAB Target-intent delivery is not pending"
    [exact] -> Right exact
    _ -> Left "retained EAB Target-intent delivery operation is ambiguous"
  unless
    ( retainedDeliverySourceReceipt delivery == sourceReceipt
        && retainedMaterialTargetText (retainedDeliveryTarget delivery)
          == targetAgentClusterIdentity registeredAgentIdentity
        && retainedDeliveryTargetGeneration delivery
          == targetIntentIssueExpectedGeneration request
        && retainedMaterialRefText (retainedDeliveryAttestationRef delivery)
          == targetValueDigestText (targetIntentIssueExpectedReceiptDigest request)
    )
    (Left "retained EAB Target-intent request differs from delivery outbox")
  pure delivery
 where
  operationMatches delivery =
    retainedMaterialRefText (retainedDeliveryOperationId delivery)
      == targetIntentIssueOperationId request

awsAdminPreparedCoordinate
  :: LongLivedCheckpointAuthority
  -> TargetIntentIssueRequest
  -> Either Text (ModelBObjectCoordinate 'ClusterRetained)
awsAdminPreparedCoordinate authority request = do
  validateIdentifier "operation id" (targetIntentIssueOperationId request)
  first
    (Text.pack . show)
    ( mkClusterRetainedCoordinate
        authority
        ( "authority/aws-admin-prepared-targets/"
            <> targetIntentIssueOperationId request
        )
    )

awsAdminPreparedFromObservation
  :: TargetIntentIssueRequest
  -> ModelBObservation PreparedCredentialTargetOutbox
  -> Either Text AuthorizedPreparedTargetIntent
awsAdminPreparedFromObservation request observation = do
  prepared <- case observation of
    ModelBMissing -> Left "AWS-admin prepared-target outbox is absent"
    ModelBCorrupt detail -> Left ("AWS-admin prepared-target outbox is corrupt: " <> detail)
    ModelBEndpointUnready detail ->
      Left ("AWS-admin prepared-target outbox is not ready: " <> detail)
    ModelBUnobservable detail ->
      Left ("AWS-admin prepared-target outbox is unobservable: " <> detail)
    ModelBObserved _ value -> Right (preparedCredentialTargetOutboxObservation value)
  unless
    ( preparedCredentialTargetId prepared == targetIntentIssueTarget request
        && preparedCredentialTargetSelectedAgent prepared
          == targetIntentIssueExpectedAgentIdentity request
        && preparedCredentialTargetGeneration prepared
          == targetIntentIssueExpectedGeneration request
        && preparedCredentialTargetReceiptDigest prepared
          == targetIntentIssueExpectedReceiptDigest request
    )
    (Left "AWS-admin prepared-target request differs from retained outbox")
  owner <- mapLeftShow (mkOwnerNonce (preparedCredentialTargetOwnerNonce prepared))
  fence <- mapLeftShow (mkFencingToken (preparedCredentialTargetFence prepared))
  mkAuthorizedPreparedTargetIntent
    owner
    fence
    (preparedCredentialTargetSelectedAgent prepared)
    (preparedCredentialTargetId prepared)
    (preparedCredentialTargetGeneration prepared)
    (preparedCredentialTargetReceiptDigest prepared)
    (preparedCredentialTargetDeadline prepared)

externalIngressMaximumBytes :: Int
externalIngressMaximumBytes = 256 * 1024

mapLeftShow :: (Show err) => Either err value -> Either Text value
mapLeftShow = either (Left . Text.pack . show) Right

-- | Durable, secret-free authorization for one exact closed Target operation.
-- The caller chooses only its idempotency identity and exact request digest;
-- Authority assigns owner/fence/generation/deadline once and never extends
-- them on replay.
data TargetOperationAuthorization = TargetOperationAuthorization
  { operationAuthorizationTarget :: !TargetSecretId
  , operationAuthorizationAgent :: !TargetAgentIdentity
  , operationAuthorizationRequestDigest :: !TargetValueDigest
  , operationAuthorizationOperationId :: !Text
  , operationAuthorizationIdempotencyKey :: !Text
  , operationAuthorizationOwner :: !Text
  , operationAuthorizationFence :: !Natural
  , operationAuthorizationGeneration :: !CredentialGeneration
  , operationAuthorizationDeadline :: !AuthorityTime
  }
  deriving stock (Eq, Show)

data WireTargetOperationAuthorization = WireTargetOperationAuthorization
  { wireOperationAuthorizationVersion :: !Word16
  , wireOperationAuthorizationTarget :: !TargetSecretId
  , wireOperationAuthorizationAgent :: !Text
  , wireOperationAuthorizationRequestDigest :: !Text
  , wireOperationAuthorizationOperationId :: !Text
  , wireOperationAuthorizationIdempotencyKey :: !Text
  , wireOperationAuthorizationOwner :: !Text
  , wireOperationAuthorizationFence :: !Natural
  , wireOperationAuthorizationGeneration :: !Natural
  , wireOperationAuthorizationDeadlineMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

targetOperationAuthorizationVersion :: Word16
targetOperationAuthorizationVersion = 1

targetOperationAuthorizationMaximumBytes :: Int
targetOperationAuthorizationMaximumBytes = 64 * 1024

targetOperationAuthorizationLifetimeMicros :: Natural
targetOperationAuthorizationLifetimeMicros =
  TargetWorkerBudget.targetOneShotAuthorizationLifetimeMicros

targetOperationAuthorizationCodec :: ModelBCodec TargetOperationAuthorization
targetOperationAuthorizationCodec =
  ModelBCodec
    { encodeModelBValue = Right . encodeTargetOperationAuthorization
    , decodeModelBValue =
        either (Left . Text.unpack) Right . decodeTargetOperationAuthorization
    }

encodeTargetOperationAuthorization :: TargetOperationAuthorization -> ByteString
encodeTargetOperationAuthorization =
  LazyByteString.toStrict . serialise . operationAuthorizationToWire

decodeTargetOperationAuthorization
  :: ByteString -> Either Text TargetOperationAuthorization
decodeTargetOperationAuthorization bytes = do
  unless
    (ByteString.length bytes <= targetOperationAuthorizationMaximumBytes)
    (Left "target operation authorization exceeds its encoded bound")
  wire <-
    first
      (const "target operation authorization is not canonical CBOR")
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (wireOperationAuthorizationVersion wire == targetOperationAuthorizationVersion)
    (Left "target operation authorization version is unsupported")
  authorization <- operationAuthorizationFromWire wire
  unless
    (encodeTargetOperationAuthorization authorization == bytes)
    (Left "target operation authorization is non-canonical")
  pure authorization

newOperationAuthorization
  :: AuthorityTime
  -> TargetIntentIssueRequest
  -> Either Text TargetOperationAuthorization
newOperationAuthorization now request = do
  validateOperationTarget (targetIntentIssueTarget request)
  validateIdentifier "operation id" (targetIntentIssueOperationId request)
  validateIdentifier "idempotency key" (targetIntentIssueIdempotencyKey request)
  unless
    (credentialGenerationValue (targetIntentIssueExpectedGeneration request) == 1)
    (Left "target operation generation must begin at one")
  fence <- mapLeftShow (mkFencingToken (authorityTimeMicros now))
  owner <-
    mapLeftShow
      ( mkOwnerNonce
          ( "target-op-"
              <> operationAuthorizationDigestSuffix request
              <> "-"
              <> Text.pack (show (authorityTimeMicros now))
          )
      )
  lifetime <-
    mapLeftShow
      (authorityDurationFromMicros targetOperationAuthorizationLifetimeMicros)
  pure
    TargetOperationAuthorization
      { operationAuthorizationTarget = targetIntentIssueTarget request
      , operationAuthorizationAgent =
          targetIntentIssueExpectedAgentIdentity request
      , operationAuthorizationRequestDigest =
          targetIntentIssueExpectedReceiptDigest request
      , operationAuthorizationOperationId = targetIntentIssueOperationId request
      , operationAuthorizationIdempotencyKey =
          targetIntentIssueIdempotencyKey request
      , operationAuthorizationOwner = ownerNonceText owner
      , operationAuthorizationFence =
          fencingTokenValue fence
      , operationAuthorizationGeneration =
          targetIntentIssueExpectedGeneration request
      , operationAuthorizationDeadline = addAuthorityDuration now lifetime
      }

authorizationMatchesRequest
  :: TargetIntentIssueRequest
  -> TargetOperationAuthorization
  -> Either Text AuthorizedPreparedTargetIntent
authorizationMatchesRequest request authorization = do
  unless
    ( operationAuthorizationTarget authorization == targetIntentIssueTarget request
        && operationAuthorizationAgent authorization
          == targetIntentIssueExpectedAgentIdentity request
        && operationAuthorizationRequestDigest authorization
          == targetIntentIssueExpectedReceiptDigest request
        && operationAuthorizationGeneration authorization
          == targetIntentIssueExpectedGeneration request
        && operationAuthorizationOperationId authorization
          == targetIntentIssueOperationId request
        && operationAuthorizationIdempotencyKey authorization
          == targetIntentIssueIdempotencyKey request
    )
    (Left "target operation authorization replay binding differs")
  owner <- mapLeftShow (mkOwnerNonce (operationAuthorizationOwner authorization))
  fence <- mapLeftShow (mkFencingToken (operationAuthorizationFence authorization))
  mkAuthorizedPreparedTargetIntent
    owner
    fence
    (operationAuthorizationAgent authorization)
    (operationAuthorizationTarget authorization)
    (operationAuthorizationGeneration authorization)
    (operationAuthorizationRequestDigest authorization)
    (operationAuthorizationDeadline authorization)

operationAuthorizationCoordinate
  :: LongLivedCheckpointAuthority
  -> TargetIntentIssueRequest
  -> Either Text (ModelBObjectCoordinate 'ClusterRetained)
operationAuthorizationCoordinate authority request = do
  validateOperationTarget (targetIntentIssueTarget request)
  validateIdentifier "operation id" (targetIntentIssueOperationId request)
  validateIdentifier "idempotency key" (targetIntentIssueIdempotencyKey request)
  first
    (Text.pack . show)
    ( mkClusterRetainedCoordinate
        authority
        ( "authority/target-operation-authorization/"
            <> operationAuthorizationDigestSuffix request
        )
    )

operationAuthorizationDigestSuffix :: TargetIntentIssueRequest -> Text
operationAuthorizationDigestSuffix request =
  Text.drop
    7
    ( targetValueDigestText
        ( sha256TargetValueDigest
            ( LazyByteString.toStrict
                ( serialise
                    ( "prodbox-target-operation-authorization-v1" :: Text
                    , targetIntentIssueTarget request
                    , targetAgentIdentityText
                        (targetIntentIssueExpectedAgentIdentity request)
                    , targetValueDigestText
                        (targetIntentIssueExpectedReceiptDigest request)
                    , targetIntentIssueOperationId request
                    , targetIntentIssueIdempotencyKey request
                    )
                )
            )
        )
    )

operationAuthorizationToWire
  :: TargetOperationAuthorization -> WireTargetOperationAuthorization
operationAuthorizationToWire authorization =
  WireTargetOperationAuthorization
    { wireOperationAuthorizationVersion = targetOperationAuthorizationVersion
    , wireOperationAuthorizationTarget = operationAuthorizationTarget authorization
    , wireOperationAuthorizationAgent =
        targetAgentIdentityText (operationAuthorizationAgent authorization)
    , wireOperationAuthorizationRequestDigest =
        targetValueDigestText (operationAuthorizationRequestDigest authorization)
    , wireOperationAuthorizationOperationId =
        operationAuthorizationOperationId authorization
    , wireOperationAuthorizationIdempotencyKey =
        operationAuthorizationIdempotencyKey authorization
    , wireOperationAuthorizationOwner = operationAuthorizationOwner authorization
    , wireOperationAuthorizationFence = operationAuthorizationFence authorization
    , wireOperationAuthorizationGeneration =
        credentialGenerationValue (operationAuthorizationGeneration authorization)
    , wireOperationAuthorizationDeadlineMicros =
        authorityTimeMicros (operationAuthorizationDeadline authorization)
    }

operationAuthorizationFromWire
  :: WireTargetOperationAuthorization -> Either Text TargetOperationAuthorization
operationAuthorizationFromWire wire = do
  validateOperationTarget (wireOperationAuthorizationTarget wire)
  agent <- mapLeftShow (mkTargetAgentIdentity (wireOperationAuthorizationAgent wire))
  digest <-
    mapLeftShow
      (mkTargetValueDigest (wireOperationAuthorizationRequestDigest wire))
  generation <-
    mapLeftShow
      (mkCredentialGeneration (wireOperationAuthorizationGeneration wire))
  unless
    (credentialGenerationValue generation == 1)
    (Left "target operation authorization generation must be one")
  validateIdentifier "operation id" (wireOperationAuthorizationOperationId wire)
  validateIdentifier
    "idempotency key"
    (wireOperationAuthorizationIdempotencyKey wire)
  _ <- mapLeftShow (mkOwnerNonce (wireOperationAuthorizationOwner wire))
  _ <- mapLeftShow (mkFencingToken (wireOperationAuthorizationFence wire))
  unless
    (wireOperationAuthorizationDeadlineMicros wire > 0)
    (Left "target operation authorization deadline is invalid")
  pure
    TargetOperationAuthorization
      { operationAuthorizationTarget = wireOperationAuthorizationTarget wire
      , operationAuthorizationAgent = agent
      , operationAuthorizationRequestDigest = digest
      , operationAuthorizationOperationId =
          wireOperationAuthorizationOperationId wire
      , operationAuthorizationIdempotencyKey =
          wireOperationAuthorizationIdempotencyKey wire
      , operationAuthorizationOwner = wireOperationAuthorizationOwner wire
      , operationAuthorizationFence = wireOperationAuthorizationFence wire
      , operationAuthorizationGeneration = generation
      , operationAuthorizationDeadline =
          authorityTimeFromMicros
            (wireOperationAuthorizationDeadlineMicros wire)
      }

validateOperationTarget :: TargetSecretId -> Either Text ()
validateOperationTarget target = case target of
  TargetPublicEdgeTls -> Right ()
  TargetFederationCustody -> Right ()
  _ -> Left ("Target is not an operation-only coordinate: " <> targetSecretIdToken target)

validateIdentifier :: Text -> Text -> Either Text ()
validateIdentifier label value =
  unless
    ( not (Text.null value)
        && value == Text.strip value
        && Text.length value <= 192
        && not (Text.any (\character -> isControl character || isSpace character) value)
    )
    (Left ("target operation " <> label <> " is invalid"))
