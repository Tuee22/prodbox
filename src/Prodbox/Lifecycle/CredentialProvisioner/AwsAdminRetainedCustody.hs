{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production SES SMTP branch of the AWS-admin delivery boundary. The raw
-- AWS secret is first converted to the region-bound SMTP password and then
-- sealed into the retained-home schema lane; it never enters a direct Target
-- materialization request.
module Prodbox.Lifecycle.CredentialProvisioner.AwsAdminRetainedCustody
  ( RetainedCustodyDisposition (..)
  , classifyRetainedCustodyForGeneration
  , productionRetainedCustodyAwsAdminDelivery
  , retainedSourceTargetReceipt
  , sesSmtpPayloadForIdentity
  )
where

import Data.Bifunctor (bimap, first)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.RetainedMaterialWorker
  ( RetainedCustodySealResult (..)
  , observeRetainedCustody
  , sealRetainedCustody
  )
import Prodbox.ControlPlane.RetainedMaterialWorkerVault
  ( retainedCustodyVaultBoundary
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId (TargetSesSmtp)
  , TargetSecretPayload (SesSmtpMaterial)
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerReceipt
  , mkTargetWorkerReceiptProjection
  )
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( RetainedCustodyObservation (..)
  , RetainedMaterialSchema (RetainedSesSmtpMaterial)
  , RetainedMaterialSource
  , RetainedSealIntent
  , SRetainedMaterialSchema (SRetainedSesSmtpMaterial)
  , mkRetainedMaterialRef
  , mkRetainedSealIntent
  , retainedMaterialRefText
  , retainedSourceCommitmentRef
  , retainedSourceGeneration
  , retainedSourceVaultVersion
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminDeliveryBoundary (..)
  , AwsAdminTargetDeliveryCause
    ( AwsAdminTargetDeliveryRetainedCustody
    , AwsAdminTargetDeliveryRetainedDelivery
    , AwsAdminTargetDeliveryRetainedReceipt
    )
  , AwsAdminTargetObservationCause (..)
  , mkAwsAdminDeliveryBoundary
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( SignedAwsAdminPermit
  , awsAdminJobPodUid
  , awsAdminPermitIntentDeadline
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentIamParameters
  , awsAdminPermitIntentImageDigest
  , awsAdminPermitIntentPermitId
  , awsAdminPermitIntentRequestDigest
  , credentialIamParametersSesIdentity
  , signedAwsAdminPermitBinding
  , signedAwsAdminPermitIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( operatorMaterialPermitIdText
  )
import Prodbox.Lifecycle.CredentialProvisioner.TargetMaterial
  ( withProvisionedTargetMaterial
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  )
import Prodbox.Vault.Session (VaultSession)

productionRetainedCustodyAwsAdminDelivery
  :: VaultSession
  -> AuthorityTime
  -> ( RetainedMaterialSource 'RetainedSesSmtpMaterial
       -> SignedAwsAdminPermit
       -> IO (Either Text ())
     )
  -> AwsAdminDeliveryBoundary IO
  -> AwsAdminDeliveryBoundary IO
productionRetainedCustodyAwsAdminDelivery session observedAt deliverRetained fallback =
  mkAwsAdminDeliveryBoundary deliver revoke observe
 where
  deliver prepared permit material = case smtpIdentity permit of
    Nothing -> deliverFallback prepared permit material
    Just identity ->
      withProvisionedTargetMaterial
        material
        (\_ _ _ _ _ -> pure (Left AwsAdminTargetDeliveryRetainedCustody))
        (sealSmtp permit identity)
        (\_ _ _ -> pure (Left AwsAdminTargetDeliveryRetainedCustody))
  revoke = revokeFallback
  observe prepared permit = case smtpIdentity permit of
    Nothing -> observeFallback prepared permit
    Just _ -> do
      observation <-
        observeRetainedCustody
          SRetainedSesSmtpMaterial
          observedAt
          (retainedCustodyVaultBoundary session SRetainedSesSmtpMaterial)
      case classifyRetainedCustodyForGeneration
        (awsAdminPermitIntentGeneration (signedAwsAdminPermitIntent permit))
        observation of
        RetainedCustodyDeliverSource source -> do
          delivered <- deliverSource permit source
          pure
            ( bimap
                observationCauseFor
                Just
                delivered
            )
        RetainedCustodyNotYetSealed -> pure (Right Nothing)
        RetainedCustodyRefused cause -> pure (Left cause)

  deliverFallback = internalDeliverCredentialTarget fallback
  revokeFallback = internalRevokeCredentialTarget fallback
  observeFallback = internalObserveCredentialTarget fallback

  sealSmtp permit identity username password region _generation = do
    case retainedIntent permit of
      Left _ -> pure (Left AwsAdminTargetDeliveryRetainedCustody)
      Right intent -> do
        sealed <-
          sealRetainedCustody
            SRetainedSesSmtpMaterial
            observedAt
            (retainedCustodyVaultBoundary session SRetainedSesSmtpMaterial)
            intent
            (sesSmtpPayloadForIdentity identity region username password)
        case sealed of
          Left _ -> pure (Left AwsAdminTargetDeliveryRetainedCustody)
          Right result ->
            first deliveryCauseFor <$> deliverSource permit (sealedSource result)

  -- The Authority's delivery call and the receipt of the delivered source fail
  -- for different reasons and are different closed causes: the worker's
  -- terminal line is the only record of which one it was.
  deliverSource permit source = do
    delivered <- deliverRetained source permit
    pure $ do
      _ <- first (const RetainedSourceDeliveryFailed) delivered
      first (const RetainedSourceReceiptInvalid) (receiptForSource permit source)

  observationCauseFor failure = case failure of
    RetainedSourceDeliveryFailed -> AwsAdminTargetObservationRetainedDeliveryFailed
    RetainedSourceReceiptInvalid -> AwsAdminTargetObservationRetainedReceiptInvalid

  deliveryCauseFor failure = case failure of
    RetainedSourceDeliveryFailed -> AwsAdminTargetDeliveryRetainedDelivery
    RetainedSourceReceiptInvalid -> AwsAdminTargetDeliveryRetainedReceipt

-- | What an observation of retained custody means for the generation one permit
-- installs. Custody at the permit's own generation is delivered. Custody at an
-- earlier generation is the previous generation of a rotation: the permit's
-- generation has not been sealed, which is the same answer as no custody, and
-- the seal advances it. Custody at a later generation belongs to a newer
-- operation and refuses, as does custody that cannot be read. The rotation case
-- used to refuse as a generation mismatch, so no rotation of the SMTP family
-- could ever get past its first observation.
data RetainedCustodyDisposition
  = RetainedCustodyDeliverSource !(RetainedMaterialSource 'RetainedSesSmtpMaterial)
  | RetainedCustodyNotYetSealed
  | RetainedCustodyRefused !AwsAdminTargetObservationCause
  deriving stock (Eq, Show)

classifyRetainedCustodyForGeneration
  :: CredentialGeneration
  -> RetainedCustodyObservation 'RetainedSesSmtpMaterial
  -> RetainedCustodyDisposition
classifyRetainedCustodyForGeneration permitGeneration observation = case observation of
  RetainedCustodyPresent source
    | retainedSourceGeneration source == permitGeneration ->
        RetainedCustodyDeliverSource source
    | credentialGenerationValue (retainedSourceGeneration source)
        < credentialGenerationValue permitGeneration ->
        RetainedCustodyNotYetSealed
    | otherwise ->
        RetainedCustodyRefused AwsAdminTargetObservationRetainedGenerationMismatch
  RetainedCustodyPositivelyAbsent _ -> RetainedCustodyNotYetSealed
  RetainedCustodyCorrupt _ ->
    RetainedCustodyRefused AwsAdminTargetObservationRetainedCorrupt
  RetainedCustodyDigestMismatch _ _ ->
    RetainedCustodyRefused AwsAdminTargetObservationRetainedDigestMismatch
  RetainedCustodyUnobservable _ ->
    RetainedCustodyRefused AwsAdminTargetObservationRetainedUnobservable

-- | What failed once a sealed source was to be delivered.
data RetainedSourceFailure
  = RetainedSourceDeliveryFailed
  | RetainedSourceReceiptInvalid

sesSmtpPayloadForIdentity :: Text -> Text -> Text -> Text -> TargetSecretPayload
sesSmtpPayloadForIdentity identity region username password =
  SesSmtpMaterial
    ("email-smtp." <> region <> ".amazonaws.com")
    "587"
    sender
    "prodbox"
    sender
    username
    password
 where
  sender = "noreply@" <> identity

retainedIntent
  :: SignedAwsAdminPermit
  -> Either Text (RetainedSealIntent 'RetainedSesSmtpMaterial)
retainedIntent permit = do
  let intent = signedAwsAdminPermitIntent permit
  reference <-
    mkRetainedMaterialRef (operatorMaterialPermitIdText (awsAdminPermitIntentPermitId intent))
  mkRetainedSealIntent
    reference
    (awsAdminPermitIntentGeneration intent)
    reference
    (awsAdminPermitIntentRequestDigest intent)
    (awsAdminPermitIntentDeadline intent)
    (awsAdminPermitIntentDeadline intent)

receiptForSource
  :: SignedAwsAdminPermit
  -> RetainedMaterialSource 'RetainedSesSmtpMaterial
  -> Either Text TargetWorkerReceipt
receiptForSource permit =
  retainedSourceTargetReceipt
    (awsAdminPermitIntentRequestDigest intent)
    (awsAdminJobPodUid (signedAwsAdminPermitBinding permit))
    (awsAdminPermitIntentImageDigest intent)
 where
  intent = signedAwsAdminPermitIntent permit

-- | The worker receipt for a sealed and delivered SMTP source: the request
-- digest the permit carries (as its request and its action), the Pod and image
-- it ran as, and the source's generation, Vault version and commitment. The
-- commitment is the Vault HMAC the custody sealed the source with, which is
-- what the receipt codec requires of a worker receipt; the ciphertext digest
-- is a different value and the codec refuses it.
retainedSourceTargetReceipt
  :: TargetValueDigest
  -> Text
  -> Text
  -> RetainedMaterialSource 'RetainedSesSmtpMaterial
  -> Either Text TargetWorkerReceipt
retainedSourceTargetReceipt requestDigest podUid imageDigest source =
  either
    (Left . showText)
    Right
    ( mkTargetWorkerReceiptProjection
        TargetSesSmtp
        (retainedSourceGeneration source)
        (retainedSourceVaultVersion source)
        (retainedMaterialRefText (retainedSourceCommitmentRef source))
        requestDigest
        requestDigest
        podUid
        imageDigest
    )

sealedSource
  :: RetainedCustodySealResult schema -> RetainedMaterialSource schema
sealedSource result = case result of
  RetainedCustodySealed source -> source
  RetainedCustodyAlreadySealed source -> source
  RetainedCustodySealRecovered source -> source

smtpIdentity :: SignedAwsAdminPermit -> Maybe Text
smtpIdentity =
  credentialIamParametersSesIdentity
    . awsAdminPermitIntentIamParameters
    . signedAwsAdminPermitIntent

showText :: (Show value) => value -> Text
showText = Text.pack . show
