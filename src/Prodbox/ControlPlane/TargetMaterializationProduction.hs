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
  , classifyTargetIntentIssueError
  , classifyTargetWorkerError
  , renderTargetWorkerCoordinatorDiagnostic
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.TargetAuthorityTrust
  ( TargetAuthorityTrustBoundaryCause (TargetAuthorityTrustBoundaryOther)
  , parseTargetAuthorityTrustBoundaryCause
  )
import Prodbox.ControlPlane.TargetIntentAuthorityClient
  ( TargetIntentAuthorityClient
  , TargetIntentAuthorityClientError (..)
  )
import Prodbox.ControlPlane.TargetMaterialClient
  ( TargetMaterialClient (observeRegisteredTargetMaterial)
  , classifyTargetMaterialClientError
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
  , TargetMaterializationWorkflowError (..)
  , runDirectTargetMaterializationWorkflow
  , runRewrappedTargetMaterializationWorkflow
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerIngressSchema (TargetWorkerDirectAws)
  , TargetWorkerReceipt
  , mkTargetWorkerImageDigest
  , renderTargetWorkerAttestationError
  , targetWorkerSchemaForTarget
  )
import Prodbox.ControlPlane.TargetSecretWorkerCoordinator
  ( TargetWorkerCoordinatorError (..)
  )
import Prodbox.ControlPlane.TargetSecretWorkerProduction
  ( TargetWorkerJobConnection
  , targetWorkerControllerAuditOps
  , targetWorkerKubernetesBoundary
  , vaultTargetWorkerRetainedExecutionBoundary
  )
import Prodbox.ControlPlane.TargetSecretWorkerRuntime
  ( TargetSecretWorkerRuntimeError (..)
  , renderTargetSecretWorkerRuntimeRefusal
  )
import Prodbox.ControlPlane.VaultAccessorAudit
  ( isBoundedBatchAuditorLogin
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminDeliveryBoundary
  , AwsAdminTargetDeliveryCause (..)
  , AwsAdminTargetIntentIssueCause (..)
  , AwsAdminTargetObservationCause (..)
  , AwsAdminTargetWorkerCause (..)
  , classifyAwsAdminTargetWorkerObservationFailure
  , mkAwsAdminDeliveryBoundary
  , renderAwsAdminTargetWorkerCause
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
  -> IO (Either AwsAdminTargetDeliveryCause TargetWorkerReceipt)
productionAwsAdminPreparedTargetMaterializer boundary permit prepared payload =
  case buildRequest permit prepared payload of
    Left cause -> pure (Left cause)
    Right buildAtTime -> do
      timeResult <- productionTargetReadTime boundary
      tokenResult <- productionTargetReadControllerToken boundary
      case (timeResult, tokenResult) of
        (Left _, _) -> pure (Left AwsAdminTargetDeliveryTimeUnavailable)
        (_, Left _) -> pure (Left AwsAdminTargetDeliveryControllerTokenUnavailable)
        (Right now, Right jwt) -> do
          loginResult <-
            vaultKubernetesLoginWithLease
              (productionTargetVaultAddress boundary)
              (productionTargetVaultAuthPath boundary)
              (productionTargetControllerAuditorRole boundary)
              jwt
          case loginResult of
            Left _ -> pure (Left AwsAdminTargetDeliveryAuditorLoginUnavailable)
            Right login
              | not (isBoundedBatchAuditorLogin controllerMaximumLeaseSeconds login) ->
                  pure (Left AwsAdminTargetDeliveryAuditorLoginInvalid)
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
                  pure (first classifyTargetMaterializationWorkflowError result)

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
    | permit /= expectedPermit = pure (Left AwsAdminTargetDeliveryPermitSubstitution)
    | otherwise = case directPayload material of
        Left cause -> pure (Left cause)
        Right payload ->
          productionAwsAdminPreparedTargetMaterializer boundary permit prepared payload
  revoke _ _ = pure (Left "ordinary AWS-admin delivery cannot revoke a Target generation")
  observe prepared permit
    | permit /= expectedPermit = pure (Left AwsAdminTargetObservationPermitSubstitution)
    | otherwise = do
        observed <- observeRegisteredTargetMaterial observer (preparedCredentialTargetId prepared)
        pure $ case observed of
          Left err -> Left (AwsAdminTargetObservationClient (classifyTargetMaterialClientError err))
          Right Nothing -> Right Nothing
          Right (Just metadata)
            | targetMaterialObservedGeneration metadata
                < credentialGenerationValue (preparedCredentialTargetGeneration prepared) ->
                Right Nothing
            | targetMaterialObservedGeneration metadata
                > credentialGenerationValue (preparedCredentialTargetGeneration prepared) ->
                Left AwsAdminTargetObservationGenerationAdvanced
            | otherwise ->
                first
                  (const AwsAdminTargetObservationReceiptInvalid)
                  ( Just
                      <$> targetWorkerReceiptFromMaterialObservation
                        (preparedCredentialTargetId prepared)
                        metadata
                  )

directPayload
  :: ProvisionedTargetMaterial schema -> Either AwsAdminTargetDeliveryCause TargetSecretPayload
directPayload material =
  withProvisionedTargetMaterial
    material
    awsPayload
    (\_ _ _ _ -> Left AwsAdminTargetDeliveryRetainedTargetRequired)
    (\_ _ _ -> Left AwsAdminTargetDeliveryPayloadInvalid)
 where
  awsPayload credentialClass keyId secret region _ = do
    identity <-
      first (const AwsAdminTargetDeliveryPayloadInvalid) (awsCredentialIdentity credentialClass)
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
  -> Either AwsAdminTargetDeliveryCause (AuthorityTime -> TargetMaterializationRequest)
buildRequest permit prepared payload = do
  let intent = signedAwsAdminPermitIntent permit
      target = preparedCredentialTargetId prepared
  if awsAdminPermitIntentPreparedTarget intent == prepared
    then Right ()
    else Left AwsAdminTargetDeliveryPreparedTargetMismatch
  if targetSecretPayloadId payload == target
    then Right ()
    else Left AwsAdminTargetDeliveryPayloadTargetMismatch
  if target == TargetSesSmtp
    then Left AwsAdminTargetDeliveryRetainedTargetRequired
    else Right ()
  if awsAdminPermitIntentAction intent == RevokeOperatorMaterial
    then Left AwsAdminTargetDeliveryRevokeRejected
    else Right ()
  first (const AwsAdminTargetDeliveryPayloadInvalid) (validateTargetSecretPayload payload)
  schema <- first (const AwsAdminTargetDeliverySchemaUnavailable) (targetWorkerSchemaForTarget target)
  if schema == TargetWorkerDirectAws
    then Right ()
    else Left AwsAdminTargetDeliverySchemaMismatch
  image <-
    first
      (const AwsAdminTargetDeliveryImageInvalid)
      (mkTargetWorkerImageDigest (awsAdminPermitIntentImageDigest intent))
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

classifyTargetMaterializationWorkflowError
  :: TargetMaterializationWorkflowError -> AwsAdminTargetDeliveryCause
classifyTargetMaterializationWorkflowError err = case err of
  TargetMaterializationIntentIssueFailed issueError ->
    AwsAdminTargetDeliveryIntentIssue (classifyTargetIntentIssueError issueError)
  TargetMaterializationWorkerFailed workerError ->
    AwsAdminTargetDeliveryWorker (classifyTargetWorkerError workerError)

classifyTargetIntentIssueError
  :: TargetIntentAuthorityClientError -> AwsAdminTargetIntentIssueCause
classifyTargetIntentIssueError err = case err of
  TargetIntentAuthorityTransportFailed _ -> AwsAdminTargetIntentTransportFailed
  TargetIntentAuthorityResponseInvalid _ -> AwsAdminTargetIntentResponseInvalid
  TargetIntentAuthorityAuthenticatedResponseInvalid observation _ ->
    AwsAdminTargetIntentAuthenticatedResponseInvalid observation
  TargetIntentAuthorityHttpStatus status -> classifyTargetIntentHttpStatus status
  TargetIntentAuthorityRefused detail -> classifyTargetIntentRefusal detail
  TargetIntentAuthorityUnavailable detail -> classifyTargetIntentUnavailable detail
  TargetIntentAuthoritySignedIntentInvalid -> AwsAdminTargetIntentSignedIntentInvalid
  TargetIntentAuthorityTrustRecordInvalid -> AwsAdminTargetIntentTrustRecordInvalid
  TargetIntentAuthorityExecutionPermitInvalid -> AwsAdminTargetIntentExecutionPermitInvalid

classifyTargetIntentHttpStatus :: Int -> AwsAdminTargetIntentIssueCause
classifyTargetIntentHttpStatus status = case status of
  400 -> AwsAdminTargetIntentHttpBadRequest
  401 -> AwsAdminTargetIntentHttpUnauthorized
  403 -> AwsAdminTargetIntentHttpForbidden
  404 -> AwsAdminTargetIntentHttpNotFound
  409 -> AwsAdminTargetIntentHttpConflict
  429 -> AwsAdminTargetIntentHttpTooManyRequests
  _
    | status >= 500 && status <= 599 -> AwsAdminTargetIntentHttpServerError
    | otherwise -> AwsAdminTargetIntentHttpOther

classifyTargetIntentRefusal :: Text -> AwsAdminTargetIntentIssueCause
classifyTargetIntentRefusal detail = case detail of
  "target-agent-identity-invalid" -> AwsAdminTargetIntentRefusedAgentIdentityInvalid
  "generation-invalid" -> AwsAdminTargetIntentRefusedGenerationInvalid
  "receipt-digest-invalid" -> AwsAdminTargetIntentRefusedReceiptDigestInvalid
  "target-agent-material-intent-forbidden" -> AwsAdminTargetIntentRefusedCallerForbidden
  "operation-intent-requires-target-agent" -> AwsAdminTargetIntentRefusedCallerForbidden
  "authority-signer-rotated" -> AwsAdminTargetIntentRefusedSignerRotated
  "target-unregistered" -> AwsAdminTargetIntentRefusedTargetUnregistered
  "target-mismatch" -> AwsAdminTargetIntentRefusedTargetMismatch
  "target-agent-identity-mismatch" -> AwsAdminTargetIntentRefusedAgentIdentityMismatch
  "intent-not-prepared" -> AwsAdminTargetIntentRefusedNotPrepared
  "generation-mismatch" -> AwsAdminTargetIntentRefusedGenerationMismatch
  "receipt-digest-mismatch" -> AwsAdminTargetIntentRefusedReceiptDigestMismatch
  "intent-deadline-reached" -> AwsAdminTargetIntentRefusedDeadlineReached
  "intent-value-invalid" -> AwsAdminTargetIntentRefusedValueInvalid
  "intent-signature-invalid" -> AwsAdminTargetIntentRefusedSignatureInvalid
  "target-trust-read-back-mismatch" -> AwsAdminTargetIntentRefusedTrustReadBackMismatch
  _ -> AwsAdminTargetIntentRefusedOther

classifyTargetIntentUnavailable :: Text -> AwsAdminTargetIntentIssueCause
classifyTargetIntentUnavailable detail =
  case Text.stripPrefix "target-trust-install-unavailable/" detail
    >>= parseTargetAuthorityTrustBoundaryCause of
    Just cause -> AwsAdminTargetIntentUnavailableTrustInstall cause
    Nothing -> case detail of
      "prepared-intent-unavailable" -> AwsAdminTargetIntentUnavailablePreparedIntent
      "authority-clock-unavailable" -> AwsAdminTargetIntentUnavailableClock
      "authority-epoch-unavailable" -> AwsAdminTargetIntentUnavailableEpoch
      "authority-signer-unavailable" -> AwsAdminTargetIntentUnavailableSigner
      "target-trust-install-unavailable" ->
        AwsAdminTargetIntentUnavailableTrustInstall TargetAuthorityTrustBoundaryOther
      _ -> AwsAdminTargetIntentUnavailableOther

classifyTargetWorkerError :: TargetWorkerCoordinatorError -> AwsAdminTargetWorkerCause
classifyTargetWorkerError err = case err of
  TargetWorkerCoordinatorAgentIdentityUnavailable cause ->
    AwsAdminTargetWorkerAgentIdentityUnavailable cause
  TargetWorkerCoordinatorAgentIdentityMismatch -> AwsAdminTargetWorkerAgentIdentityMismatch
  TargetWorkerCoordinatorIntentRejected _ -> AwsAdminTargetWorkerIntentRejected
  TargetWorkerCoordinatorCreateFailed _ -> AwsAdminTargetWorkerCreateFailed
  TargetWorkerCoordinatorObservationFailed detail ->
    AwsAdminTargetWorkerObservationFailed
      (classifyAwsAdminTargetWorkerObservationFailure detail)
  TargetWorkerCoordinatorWorkloadAbsent -> AwsAdminTargetWorkerWorkloadAbsent
  TargetWorkerCoordinatorCleanupBindingInvalid -> AwsAdminTargetWorkerCleanupBindingInvalid
  TargetWorkerCoordinatorAttestationFailed _ -> AwsAdminTargetWorkerAttestationFailed
  TargetWorkerCoordinatorSessionPrepareFailed _ -> AwsAdminTargetWorkerSessionPrepareFailed
  TargetWorkerCoordinatorPermitUnavailable _ -> AwsAdminTargetWorkerPermitUnavailable
  TargetWorkerCoordinatorPermitRejected _ -> AwsAdminTargetWorkerPermitRejected
  TargetWorkerCoordinatorPermitBindingMismatch -> AwsAdminTargetWorkerPermitBindingMismatch
  TargetWorkerCoordinatorFrameRejected _ -> AwsAdminTargetWorkerFrameRejected
  TargetWorkerCoordinatorAttachFailed _ -> AwsAdminTargetWorkerAttachFailed
  TargetWorkerCoordinatorProvisionalRejected _ -> AwsAdminTargetWorkerProvisionalRejected
  TargetWorkerCoordinatorReceiptBindingMismatch -> AwsAdminTargetWorkerReceiptBindingMismatch
  TargetWorkerCoordinatorSessionActivateFailed _ -> AwsAdminTargetWorkerSessionActivateFailed
  TargetWorkerCoordinatorMaterializationRefused _ -> AwsAdminTargetWorkerMaterializationRefused
  TargetWorkerCoordinatorSessionCleanupFailed _ -> AwsAdminTargetWorkerSessionCleanupFailed
  TargetWorkerCoordinatorDeleteFailed _ -> AwsAdminTargetWorkerDeleteFailed
  TargetWorkerCoordinatorAbsenceUnobservable _ -> AwsAdminTargetWorkerAbsenceUnobservable
  TargetWorkerCoordinatorStillPresent -> AwsAdminTargetWorkerStillPresent
  TargetWorkerCoordinatorUnhandledException -> AwsAdminTargetWorkerUnhandledException

renderTargetWorkerCoordinatorDiagnostic :: TargetWorkerCoordinatorError -> Text
renderTargetWorkerCoordinatorDiagnostic err = case err of
  TargetWorkerCoordinatorAttestationFailed attestationError ->
    "attestation-failed/" <> renderTargetWorkerAttestationError attestationError
  TargetWorkerCoordinatorAttachFailed detail ->
    "attach-failed/" <> classifyTargetWorkerAttachFailure detail
  TargetWorkerCoordinatorMaterializationRefused detail ->
    classifyTargetWorkerMaterializationRefusal detail
  _ -> renderAwsAdminTargetWorkerCause (classifyTargetWorkerError err)

-- | Refine only the three closed production attach failures. Arbitrary
-- injected detail collapses before it reaches the protected diagnostic.
classifyTargetWorkerAttachFailure :: Text -> Text
classifyTargetWorkerAttachFailure detail = case detail of
  "Target worker attach transport failed" -> "transport-unavailable"
  "Target worker cleanup acknowledgement is invalid" -> "cleanup-ack-invalid"
  "Target worker terminal status is inconsistent" -> "terminal-status-inconsistent"
  _ -> "other"

-- | Admit only runtime-owned closed TLS-retain refusal tokens. The existing
-- generic rollout token retains its prior diagnostic, and arbitrary text is
-- collapsed before it reaches the protected Target log.
classifyTargetWorkerMaterializationRefusal :: Text -> Text
classifyTargetWorkerMaterializationRefusal detail
  | detail == genericRefusal = "materialization-refused"
  | detail `elem` tlsRetainRefusals = "materialization-refused/" <> detail
  | otherwise = "materialization-refused/other"
 where
  genericRefusal =
    renderTargetSecretWorkerRuntimeRefusal TargetSecretWorkerOperationRefused
  tlsRetainRefusals =
    [ renderTargetSecretWorkerRuntimeRefusal
        TargetSecretWorkerTlsRetainProductionBoundaryUnavailable
    , renderTargetSecretWorkerRuntimeRefusal TargetSecretWorkerTlsRetainBadRequest
    , "tls-retain/secret-unavailable"
    , "tls-retain/secret-invalid"
    , "tls-retain/secret-readback-mismatch"
    , "tls-retain/secret-apply-failed"
    , "tls-retain/dek-exchange-failed"
    , "tls-retain/cipher-failed"
    , "tls-retain/certificate-ciphertext-invalid"
    , "tls-retain/certificate-ciphertext-too-large"
    , "tls-retain/reference-mismatch"
    ]
