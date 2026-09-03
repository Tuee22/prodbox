{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production SES SMTP branch of the AWS-admin delivery boundary. The raw
-- AWS secret is first converted to the region-bound SMTP password and then
-- sealed into the retained-home schema lane; it never enters a direct Target
-- materialization request.
module Prodbox.Lifecycle.CredentialProvisioner.AwsAdminRetainedCustody
  ( productionRetainedCustodyAwsAdminDelivery
  , sesSmtpPayloadForIdentity
  )
where

import Data.Bifunctor (first)
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
  , retainedSourceCiphertextDigest
  , retainedSourceGeneration
  , retainedSourceVaultVersion
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminDeliveryBoundary (..)
  , AwsAdminTargetDeliveryCause (AwsAdminTargetDeliveryRetainedCustody)
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
  ( targetValueDigestText
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
      case observation of
        RetainedCustodyPresent source
          | retainedSourceGeneration source
              == awsAdminPermitIntentGeneration (signedAwsAdminPermitIntent permit) ->
              do
                delivered <- deliverSource permit source
                pure
                  ( first
                      (const AwsAdminTargetObservationRetainedDeliveryFailed)
                      (Just <$> delivered)
                  )
        RetainedCustodyPositivelyAbsent _ -> pure (Right Nothing)
        RetainedCustodyPresent _ ->
          pure (Left AwsAdminTargetObservationRetainedGenerationMismatch)
        RetainedCustodyCorrupt _ -> pure (Left AwsAdminTargetObservationRetainedCorrupt)
        RetainedCustodyDigestMismatch _ _ ->
          pure (Left AwsAdminTargetObservationRetainedDigestMismatch)
        RetainedCustodyUnobservable _ ->
          pure (Left AwsAdminTargetObservationRetainedUnobservable)

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
          Right result -> deliverSource permit (sealedSource result)

  deliverSource permit source = do
    delivered <- deliverRetained source permit
    pure $ do
      _ <- first (const AwsAdminTargetDeliveryRetainedCustody) delivered
      first
        (const AwsAdminTargetDeliveryRetainedCustody)
        (receiptForSource permit source)

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
receiptForSource permit source = do
  let intent = signedAwsAdminPermitIntent permit
      binding = signedAwsAdminPermitBinding permit
      requestDigest = awsAdminPermitIntentRequestDigest intent
  either
    (Left . showText)
    Right
    ( mkTargetWorkerReceiptProjection
        TargetSesSmtp
        (retainedSourceGeneration source)
        (retainedSourceVaultVersion source)
        (targetValueDigestText (retainedSourceCiphertextDigest source))
        requestDigest
        requestDigest
        (awsAdminJobPodUid binding)
        (awsAdminPermitIntentImageDigest intent)
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
