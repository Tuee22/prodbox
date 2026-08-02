{-# LANGUAGE DerivingStrategies #-}

-- | Reusable Authority-to-Agent selected-target workflow.
--
-- The durable Authority issues the secret-free signed intent first.  Its
-- public trust record is CAS-installed and read back by the Authority as part
-- of issuance before Kubernetes is allowed to create the one-shot worker.
-- Plaintext (direct AWS material) or destination-sealed ciphertext
-- (retained SES/EAB) is attached only after the exact Job/Pod has been
-- attested; cleanup and positive absence are owned by the coordinator.
module Prodbox.ControlPlane.TargetMaterializationWorkflow
  ( TargetMaterializationRequest (..)
  , TargetMaterializationWorkflowError (..)
  , runDirectTargetMaterializationWorkflow
  , runRewrappedTargetMaterializationWorkflow
  )
where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.TargetIntentAuthorityClient
  ( TargetIntentAuthorityClient
  , TargetIntentAuthorityClientError
  , requestTargetCommittedIntent
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId
  , TargetSecretPayload
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( AcceptedTargetAuthority
  , TargetAgentIdentity
  , encodeSignedTargetCommittedIntent
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerImageDigest
  , TargetWorkerIngressSchema
  , TargetWorkerReceipt
  )
import Prodbox.ControlPlane.TargetSecretWorkerCoordinator
  ( TargetWorkerCoordinatorError
  , TargetWorkerExecutionBoundary
  , TargetWorkerKubernetesBoundary
  , coordinateDirectTargetMaterialization
  , coordinateRewrappedTargetMaterialization
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  )

data TargetMaterializationRequest = TargetMaterializationRequest
  { targetMaterializationTarget :: !TargetSecretId
  , targetMaterializationAgentIdentity :: !TargetAgentIdentity
  , targetMaterializationGeneration :: !CredentialGeneration
  , targetMaterializationReceiptDigest :: !TargetValueDigest
  , targetMaterializationOperationId :: !Text
  , targetMaterializationActionIndex :: !Natural
  , targetMaterializationIdempotencyKey :: !Text
  , targetMaterializationIngressSchema :: !TargetWorkerIngressSchema
  , targetMaterializationWorkerImage :: !TargetWorkerImageDigest
  , targetMaterializationNow :: !AuthorityTime
  }
  deriving stock (Eq, Show)

data TargetMaterializationWorkflowError
  = TargetMaterializationIntentIssueFailed !TargetIntentAuthorityClientError
  | TargetMaterializationWorkerFailed !TargetWorkerCoordinatorError
  deriving stock (Eq, Show)

runDirectTargetMaterializationWorkflow
  :: TargetIntentAuthorityClient IO
  -> TargetWorkerKubernetesBoundary IO
  -> TargetWorkerExecutionBoundary IO
  -> TargetMaterializationRequest
  -> TargetSecretPayload
  -> IO (Either TargetMaterializationWorkflowError TargetWorkerReceipt)
runDirectTargetMaterializationWorkflow issuer worker execution request payload =
  runWorkflow
    issuer
    worker
    execution
    request
    ( \accepted signed ->
        coordinateDirectTargetMaterialization
          worker
          execution
          accepted
          (targetMaterializationNow request)
          (targetMaterializationAgentIdentity request)
          (targetMaterializationTarget request)
          (targetMaterializationIngressSchema request)
          (targetMaterializationWorkerImage request)
          signed
          payload
    )

runRewrappedTargetMaterializationWorkflow
  :: TargetIntentAuthorityClient IO
  -> TargetWorkerKubernetesBoundary IO
  -> TargetWorkerExecutionBoundary IO
  -> TargetMaterializationRequest
  -> ByteString
  -> IO (Either TargetMaterializationWorkflowError TargetWorkerReceipt)
runRewrappedTargetMaterializationWorkflow issuer worker execution request destinationEnvelope =
  runWorkflow
    issuer
    worker
    execution
    request
    ( \accepted signed ->
        coordinateRewrappedTargetMaterialization
          worker
          execution
          accepted
          (targetMaterializationNow request)
          (targetMaterializationAgentIdentity request)
          (targetMaterializationTarget request)
          (targetMaterializationIngressSchema request)
          (targetMaterializationWorkerImage request)
          signed
          destinationEnvelope
    )

runWorkflow
  :: TargetIntentAuthorityClient IO
  -> TargetWorkerKubernetesBoundary IO
  -> TargetWorkerExecutionBoundary IO
  -> TargetMaterializationRequest
  -> ( AcceptedTargetAuthority
       -> ByteString
       -> IO (Either TargetWorkerCoordinatorError TargetWorkerReceipt)
     )
  -> IO (Either TargetMaterializationWorkflowError TargetWorkerReceipt)
runWorkflow issuer _ _ request runWorker = do
  issued <-
    requestTargetCommittedIntent
      issuer
      (targetMaterializationTarget request)
      (targetMaterializationAgentIdentity request)
      (targetMaterializationGeneration request)
      (targetMaterializationReceiptDigest request)
      (targetMaterializationOperationId request)
      (targetMaterializationActionIndex request)
      (targetMaterializationIdempotencyKey request)
  case issued of
    Left err -> pure (Left (TargetMaterializationIntentIssueFailed err))
    Right (signed, accepted) -> do
      result <- runWorker accepted (encodeSignedTargetCommittedIntent signed)
      pure (either (Left . TargetMaterializationWorkerFailed) Right result)
