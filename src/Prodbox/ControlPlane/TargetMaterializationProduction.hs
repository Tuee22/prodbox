{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production composition for a Credential Provisioner's direct handoff to
-- one selected Target.  Plaintext is carried only by the caller's continuation
-- and the attested Pod attach frame; the Authority client receives the
-- secret-free prepared-outbox binding only.
module Prodbox.ControlPlane.TargetMaterializationProduction
  ( ProductionTargetMaterializationBoundary
  , productionTargetMaterializationBoundary
  , productionAwsAdminPreparedTargetMaterializer
  , productionAwsAdminDeliveryBoundary
  , productionRewrappedTargetMaterializer
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.TargetIntentAuthorityClient
  ( TargetIntentAuthorityClient
  )
import Prodbox.ControlPlane.TargetMaterialClient
  ( TargetMaterialClient (observeRegisteredTargetMaterial)
  , targetWorkerReceiptFromMaterialObservation
  )
import Prodbox.ControlPlane.TargetMaterialEndpoint
  ( targetMaterialObservedGeneration
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (..)
  , TargetSecretId (TargetSesSmtp)
  , TargetSecretPayload (AwsCredentialMaterial)
  , targetSecretPayloadId
  , validateTargetSecretPayload
  )
import Prodbox.ControlPlane.TargetMaterializationWorkflow
  ( TargetMaterializationRequest (..)
  , runDirectTargetMaterializationWorkflow
  , runRewrappedTargetMaterializationWorkflow
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerIngressSchema (TargetWorkerDirectAws)
  , TargetWorkerReceipt
  , mkTargetWorkerImageDigest
  , targetWorkerSchemaForTarget
  )
import Prodbox.ControlPlane.TargetSecretWorkerProduction
  ( TargetWorkerJobConnection
  , targetWorkerControllerAuditOps
  , targetWorkerKubernetesBoundary
  , vaultTargetWorkerRetainedExecutionBoundary
  )
import Prodbox.ControlPlane.VaultAccessorAudit
  ( isBoundedBatchAuditorLogin
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminDeliveryBoundary
  , mkAwsAdminDeliveryBoundary
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( SignedAwsAdminPermit
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentCredentialClass
  , awsAdminPermitIntentImageDigest
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentPermitId
  , awsAdminPermitIntentPreparedTarget
  , signedAwsAdminPermitIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , OperatorMaterialAction (RevokeOperatorMaterial)
  , firstReconcilePermitMemberIndex
  , operatorMaterialOperationIdText
  , operatorMaterialPermitIdText
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( PreparedCredentialTargetObservation
  , preparedCredentialTargetGeneration
  , preparedCredentialTargetId
  , preparedCredentialTargetPlanBinding
  , preparedCredentialTargetReceiptDigest
  , preparedCredentialTargetSelectedAgent
  )
import Prodbox.Lifecycle.CredentialProvisioner.TargetMaterial
  ( ProvisionedTargetMaterial
  , withProvisionedTargetMaterial
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Lifecycle.TargetCommitIntent (credentialGenerationValue)
import Prodbox.Vault.Client
  ( VaultAddress
  , vaultKubernetesLoginWithLease
  , vaultLoginToken
  )

-- | Closed production dependencies.  The controller login is an
-- accessor-free batch identity with Target-worker journal/audit policy only;
-- it cannot read or write Target material.
data ProductionTargetMaterializationBoundary
  = ProductionTargetMaterializationBoundary
  { productionTargetVaultAddress :: !VaultAddress
  , productionTargetVaultAuthPath :: !Text
  , productionTargetControllerAuditorRole :: !Text
  , productionTargetReadControllerToken :: !(IO (Either Text Text))
  , productionTargetJobConnection :: !TargetWorkerJobConnection
  , productionTargetIntentClient :: !(TargetIntentAuthorityClient IO)
  , productionTargetReadTime :: !(IO (Either Text AuthorityTime))
  }

productionTargetMaterializationBoundary
  :: VaultAddress
  -> Text
  -> Text
  -> IO (Either Text Text)
  -> TargetWorkerJobConnection
  -> TargetIntentAuthorityClient IO
  -> IO (Either Text AuthorityTime)
  -> ProductionTargetMaterializationBoundary
productionTargetMaterializationBoundary =
  ProductionTargetMaterializationBoundary

-- | Bind one already-verified AWS-admin permit.  The returned continuation is
-- exactly the capability consumed by 'AwsAdminDeliveryBoundary': it accepts
-- the retained prepared observation and one closed payload, and returns only
-- the opaque Target receipt.
productionAwsAdminPreparedTargetMaterializer
  :: ProductionTargetMaterializationBoundary
  -> SignedAwsAdminPermit
  -> PreparedCredentialTargetObservation
  -> TargetSecretPayload
  -> IO (Either Text TargetWorkerReceipt)
productionAwsAdminPreparedTargetMaterializer boundary permit prepared payload =
  case buildRequest permit prepared payload of
    Left detail -> pure (Left detail)
    Right buildAtTime -> do
      timeResult <- productionTargetReadTime boundary
      tokenResult <- productionTargetReadControllerToken boundary
      case (timeResult, tokenResult) of
        (Left detail, _) -> pure (Left detail)
        (_, Left detail) -> pure (Left detail)
        (Right now, Right jwt) -> do
          loginResult <-
            vaultKubernetesLoginWithLease
              (productionTargetVaultAddress boundary)
              (productionTargetVaultAuthPath boundary)
              (productionTargetControllerAuditorRole boundary)
              jwt
          case loginResult of
            Left _ -> pure (Left "Target worker controller auditor login unavailable")
            Right login
              | not (isBoundedBatchAuditorLogin controllerMaximumLeaseSeconds login) ->
                  pure (Left "Target worker controller auditor login was not bounded batch")
              | otherwise -> do
                  let intentClient = productionTargetIntentClient boundary
                      execution =
                        vaultTargetWorkerRetainedExecutionBoundary
                          (productionTargetVaultAddress boundary)
                          (vaultLoginToken login)
                          ( targetWorkerControllerAuditOps
                              (productionTargetVaultAddress boundary)
                              (vaultLoginToken login)
                          )
                          intentClient
                  result <-
                    runDirectTargetMaterializationWorkflow
                      intentClient
                      ( targetWorkerKubernetesBoundary
                          (productionTargetJobConnection boundary)
                      )
                      execution
                      (buildAtTime now)
                      payload
                  pure (first (Text.take 256 . Text.pack . show) result)

productionRewrappedTargetMaterializer
  :: ProductionTargetMaterializationBoundary
  -> TargetMaterializationRequest
  -> ByteString
  -> IO (Either Text TargetWorkerReceipt)
productionRewrappedTargetMaterializer boundary request opening = do
  tokenResult <- productionTargetReadControllerToken boundary
  case tokenResult of
    Left detail -> pure (Left detail)
    Right jwt -> do
      loginResult <-
        vaultKubernetesLoginWithLease
          (productionTargetVaultAddress boundary)
          (productionTargetVaultAuthPath boundary)
          (productionTargetControllerAuditorRole boundary)
          jwt
      case loginResult of
        Left _ -> pure (Left "Target worker controller auditor login unavailable")
        Right login
          | not (isBoundedBatchAuditorLogin controllerMaximumLeaseSeconds login) ->
              pure (Left "Target worker controller auditor login was not bounded batch")
          | otherwise -> do
              let intentClient = productionTargetIntentClient boundary
                  execution =
                    vaultTargetWorkerRetainedExecutionBoundary
                      (productionTargetVaultAddress boundary)
                      (vaultLoginToken login)
                      ( targetWorkerControllerAuditOps
                          (productionTargetVaultAddress boundary)
                          (vaultLoginToken login)
                      )
                      intentClient
              result <-
                runRewrappedTargetMaterializationWorkflow
                  intentClient
                  ( targetWorkerKubernetesBoundary
                      (productionTargetJobConnection boundary)
                  )
                  execution
                  request
                  opening
              pure (first (Text.take 256 . Text.pack . show) result)

productionAwsAdminDeliveryBoundary
  :: ProductionTargetMaterializationBoundary
  -> TargetMaterialClient IO
  -> SignedAwsAdminPermit
  -> AwsAdminDeliveryBoundary IO
productionAwsAdminDeliveryBoundary boundary observer expectedPermit =
  mkAwsAdminDeliveryBoundary deliver revoke observe
 where
  deliver prepared permit material
    | permit /= expectedPermit = pure (Left "AWS-admin delivery permit substitution")
    | otherwise = case directPayload material of
        Left detail -> pure (Left detail)
        Right payload ->
          productionAwsAdminPreparedTargetMaterializer boundary permit prepared payload
  revoke _ _ = pure (Left "ordinary AWS-admin delivery cannot revoke a Target generation")
  observe prepared permit
    | permit /= expectedPermit = pure (Left "AWS-admin observation permit substitution")
    | otherwise = do
        observed <- observeRegisteredTargetMaterial observer (preparedCredentialTargetId prepared)
        pure $ case observed of
          Left err -> Left (Text.take 256 (Text.pack (show err)))
          Right Nothing -> Right Nothing
          Right (Just metadata)
            | targetMaterialObservedGeneration metadata
                < credentialGenerationValue (preparedCredentialTargetGeneration prepared) ->
                Right Nothing
            | targetMaterialObservedGeneration metadata
                > credentialGenerationValue (preparedCredentialTargetGeneration prepared) ->
                Left "Target generation advanced beyond prepared generation"
            | otherwise ->
                Just
                  <$> targetWorkerReceiptFromMaterialObservation
                    (preparedCredentialTargetId prepared)
                    metadata

directPayload
  :: ProvisionedTargetMaterial schema -> Either Text TargetSecretPayload
directPayload material =
  withProvisionedTargetMaterial
    material
    awsPayload
    (\_ _ _ _ -> Left "SES SMTP requires retained custody")
    (\_ _ _ -> Left "ACME EAB cannot enter AWS-admin delivery")
 where
  awsPayload credentialClass keyId secret region _ = do
    identity <- awsCredentialIdentity credentialClass
    pure (AwsCredentialMaterial identity keyId secret "" region)

awsCredentialIdentity :: AwsCredentialClass -> Either Text AwsCredentialIdentity
awsCredentialIdentity credentialClass = case credentialClass of
  LifecycleProviderCredential -> Right AwsLifecycleProvider
  AuthorityBackupStoreCredential -> Right AwsAuthorityBackupStore
  TlsRetentionStoreCredential -> Right AwsTlsRetentionStore
  GatewayDnsCredential -> Right AwsGatewayDns
  HomeCertManagerDns01Credential -> Right AwsHomeCertManagerDns01
  AwsRunCertManagerDns01Credential -> Right AwsRunCertManagerDns01
  SesSmtpRetainedCustodyCredential -> Left "SES SMTP has no direct AWS target identity"

buildRequest
  :: SignedAwsAdminPermit
  -> PreparedCredentialTargetObservation
  -> TargetSecretPayload
  -> Either Text (AuthorityTime -> TargetMaterializationRequest)
buildRequest permit prepared payload = do
  let intent = signedAwsAdminPermitIntent permit
      target = preparedCredentialTargetId prepared
  if awsAdminPermitIntentPreparedTarget intent == prepared
    then Right ()
    else Left "AWS-admin permit prepared-target binding mismatch"
  if targetSecretPayloadId payload == target
    then Right ()
    else Left "AWS-admin payload target differs from prepared outbox"
  if target == TargetSesSmtp
    then Left "SES SMTP must enter retained-home custody, not direct materialization"
    else Right ()
  if awsAdminPermitIntentAction intent == RevokeOperatorMaterial
    then Left "AWS-admin revoke cannot carry direct Target material"
    else Right ()
  validateTargetSecretPayload payload
  schema <- first (Text.take 256 . Text.pack . show) (targetWorkerSchemaForTarget target)
  if schema == TargetWorkerDirectAws
    then Right ()
    else Left "AWS-admin target is not in the direct materialization schema"
  image <- mkTargetWorkerImageDigest (awsAdminPermitIntentImageDigest intent)
  pure $ \now ->
    TargetMaterializationRequest
      { targetMaterializationTarget = target
      , targetMaterializationAgentIdentity =
          preparedCredentialTargetSelectedAgent prepared
      , targetMaterializationGeneration =
          preparedCredentialTargetGeneration prepared
      , targetMaterializationReceiptDigest =
          preparedCredentialTargetReceiptDigest prepared
      , targetMaterializationOperationId =
          operatorMaterialOperationIdText
            (awsAdminPermitIntentOperationId intent)
      , targetMaterializationActionIndex = actionIndexForPermit permit prepared
      , targetMaterializationIdempotencyKey =
          "aws-admin-target-"
            <> operatorMaterialPermitIdText
              (awsAdminPermitIntentPermitId intent)
      , targetMaterializationIngressSchema = schema
      , targetMaterializationWorkerImage = image
      , targetMaterializationNow = now
      }

actionIndex
  :: (Enum credentialClass, Enum action)
  => credentialClass
  -> action
  -> Natural
actionIndex credentialClass action =
  1 + fromIntegral (fromEnum credentialClass * 3 + fromEnum action)

actionIndexForPermit
  :: SignedAwsAdminPermit
  -> PreparedCredentialTargetObservation
  -> Natural
actionIndexForPermit permit prepared =
  case preparedCredentialTargetPlanBinding prepared of
    Just binding -> firstReconcilePermitMemberIndex binding
    Nothing ->
      actionIndex
        (awsAdminPermitIntentCredentialClass intent)
        (awsAdminPermitIntentAction intent)
 where
  intent = signedAwsAdminPermitIntent permit

controllerMaximumLeaseSeconds :: Int
controllerMaximumLeaseSeconds = 300
