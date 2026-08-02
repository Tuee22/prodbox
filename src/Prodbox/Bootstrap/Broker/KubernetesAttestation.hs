{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Fail-closed projection of Kubernetes Pod and Lease observations into the
-- Bootstrap Broker's proof types. A durable worker intent deliberately omits
-- the API-server-owned Pod UID; an exact Pod observation is the only operation
-- that can bind that UID into a worker request.
module Prodbox.Bootstrap.Broker.KubernetesAttestation
  ( RawWorkerPodObservation (..)
  , bootstrapSecretWorkerPodName
  , workerPodNameForRequest
  , workerPodNameForCleanupBinding
  , renderSecretWorkerOperation
  , parseSecretWorkerOperation
  , bindWorkerPodObservation
  , attestWorkerPodObservation
  , rawWorkerAttestation
  , bootstrapFenceLeaseName
  , RawBootstrapLeaseObservation (..)
  , observeBootstrapLease
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapLeaseObservation (..)
  , mkBootstrapFenceGeneration
  , reloadBootstrapLeaseBinding
  )
import Prodbox.Bootstrap.Broker.Request
  ( mkRequestDigest
  )
import Prodbox.Bootstrap.Broker.SecretWorker
  ( RawSecretWorkerAttestation (..)
  , SecretFreeWorkerRequest
  , SecretWorkerAttestationObservation (..)
  , SecretWorkerCleanupBinding
  , SecretWorkerIntent
  , SecretWorkerOperation (..)
  , attestSecretWorker
  , bindSecretWorkerIntent
  , mkWorkerImageDigest
  , mkWorkerPodUid
  , mkWorkerServiceAccount
  , mkWorkerSessionAccessor
  , mkWorkerSessionId
  , workerSessionNotIssued
  )
import Prodbox.Bootstrap.Broker.Types
  ( mkArtifactDigest
  , mkVaultStorageGeneration
  )
import Prodbox.ControlPlane.AuthorityClock
  ( operationDeadlineFromMicros
  )
import Prodbox.ControlPlane.Deadline (Deadline)
import Prodbox.Lifecycle.Lease (mkOwnerNonce)

-- | Raw fields from one freshly fetched Pod. Missing/deleting/not-ready state
-- is explicit and cannot be confused with a valid attestation.
data RawWorkerPodObservation = RawWorkerPodObservation
  { observedWorkerPodName :: !Text
  , observedWorkerPodUid :: !Text
  , observedWorkerImageDigest :: !Text
  , observedWorkerServiceAccount :: !Text
  , observedWorkerSessionId :: !Text
  , observedWorkerSessionAccessor :: !Text
  , observedWorkerOperation :: !SecretWorkerOperation
  , observedWorkerFenceGeneration :: !Natural
  , observedWorkerOwnerNonce :: !Text
  , observedWorkerActionDigest :: !Text
  , observedWorkerRequestDigest :: !Text
  , observedWorkerStorageGeneration :: !Text
  , observedWorkerOperationDeadlineMicros :: !Natural
  , observedWorkerPhase :: !Text
  , observedWorkerContainerReady :: !Bool
  , observedWorkerDeletionTimestamp :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | Fixed resource name for the sole one-shot worker. The Broker is a
-- single-writer singleton, so a fixed name lets Kubernetes RBAC constrain
-- get/delete to this exact Pod. Generations are distinguished by the
-- API-server-assigned UID and the complete attestation binding, never by name.
bootstrapSecretWorkerPodName :: Text
bootstrapSecretWorkerPodName = "bootstrap-secret-worker"

-- | Reconstruct the sole exact Pod coordinate from a request. This does not
-- claim to pre-allocate the API-server-assigned UID.
workerPodNameForRequest :: SecretFreeWorkerRequest -> Text
workerPodNameForRequest _request = bootstrapSecretWorkerPodName

workerPodNameForCleanupBinding :: SecretWorkerCleanupBinding -> Text
workerPodNameForCleanupBinding _binding = bootstrapSecretWorkerPodName

-- | Bind the API-assigned UID only after every secret-free field read from the
-- fixed Pod coordinate matches the durable intent. Pod readiness is not part
-- of UID ownership: the controller checkpoints this binding before waiting for
-- the container to become ready, so a crash while the Pod is Pending resumes
-- from an exact UID rather than issuing a second logical worker intent.
bindWorkerPodObservation
  :: SecretWorkerIntent
  -> RawWorkerPodObservation
  -> Either Text SecretFreeWorkerRequest
bindWorkerPodObservation intent observed = do
  if observedWorkerPodName observed == bootstrapSecretWorkerPodName
    then Right ()
    else Left "Pod name mismatch"
  case observedWorkerDeletionTimestamp observed of
    Nothing -> Right ()
    Just _ -> Left "worker Pod is deleting"
  podUid <- firstShow (mkWorkerPodUid (observedWorkerPodUid observed))
  let request = bindSecretWorkerIntent podUid intent
  raw <- rawWorkerAttestation observed
  case attestSecretWorker request (SecretWorkerAttestationObserved raw) of
    Left refusal -> Left (Text.pack (show refusal))
    Right _ -> Right request

-- | Stable text used in Pod/Lease annotations. Keep this exhaustive rather
-- than relying on constructor rendering, which is not a wire contract.
renderSecretWorkerOperation :: SecretWorkerOperation -> Text
renderSecretWorkerOperation operation = case operation of
  SecretWorkerPrepareInitialization -> "prepare-initialization"
  SecretWorkerResumeInitialization -> "resume-initialization"
  SecretWorkerInitialize -> "initialize"
  SecretWorkerFinalizeInitialization -> "finalize-initialization"
  SecretWorkerUnseal -> "unseal"
  SecretWorkerRotateUnlockBundle -> "rotate-unlock"
  SecretWorkerRotateTransitKey -> "rotate-transit"
  SecretWorkerCompleteGeneratedRoot -> "complete-generated-root"

parseSecretWorkerOperation :: Text -> Either Text SecretWorkerOperation
parseSecretWorkerOperation value = case value of
  "prepare-initialization" -> Right SecretWorkerPrepareInitialization
  "resume-initialization" -> Right SecretWorkerResumeInitialization
  "initialize" -> Right SecretWorkerInitialize
  "finalize-initialization" -> Right SecretWorkerFinalizeInitialization
  "unseal" -> Right SecretWorkerUnseal
  "rotate-unlock" -> Right SecretWorkerRotateUnlockBundle
  "rotate-transit" -> Right SecretWorkerRotateTransitKey
  "complete-generated-root" -> Right SecretWorkerCompleteGeneratedRoot
  _ -> Left "worker operation annotation is invalid"

attestWorkerPodObservation
  :: SecretFreeWorkerRequest
  -> RawWorkerPodObservation
  -> SecretWorkerAttestationObservation
attestWorkerPodObservation request observed
  | observedWorkerPodName observed /= workerPodNameForRequest request = refused "Pod name mismatch"
  | observedWorkerPhase observed /= "Running" = refused "Pod is not Running"
  | not (observedWorkerContainerReady observed) = refused "worker container is not ready"
  | maybe False (const True) (observedWorkerDeletionTimestamp observed) =
      refused "worker Pod is deleting"
  | otherwise =
      case rawWorkerAttestation observed of
        Left detail -> refused detail
        Right attestation -> SecretWorkerAttestationObserved attestation
 where
  refused = SecretWorkerAttestationUnobservable

rawWorkerAttestation
  :: RawWorkerPodObservation -> Either Text RawSecretWorkerAttestation
rawWorkerAttestation observed = do
  podUid <- firstShow (mkWorkerPodUid (observedWorkerPodUid observed))
  imageDigest <- firstShow (mkWorkerImageDigest (observedWorkerImageDigest observed))
  serviceAccount <- firstShow (mkWorkerServiceAccount (observedWorkerServiceAccount observed))
  sessionId <- firstShow (mkWorkerSessionId (observedWorkerSessionId observed))
  sessionAccessor <-
    if observedWorkerSessionAccessor observed == "not-issued"
      then Right workerSessionNotIssued
      else firstShow (mkWorkerSessionAccessor (observedWorkerSessionAccessor observed))
  fenceGeneration <-
    firstShow
      (mkBootstrapFenceGeneration (observedWorkerFenceGeneration observed))
  owner <- firstShow (mkOwnerNonce (observedWorkerOwnerNonce observed))
  actionDigest <- firstShow (mkArtifactDigest (observedWorkerActionDigest observed))
  requestDigest <- firstText (mkRequestDigest (observedWorkerRequestDigest observed))
  storageGeneration <-
    firstShow (mkVaultStorageGeneration (observedWorkerStorageGeneration observed))
  pure
    RawSecretWorkerAttestation
      { rawWorkerPodUid = podUid
      , rawWorkerImageDigest = imageDigest
      , rawWorkerServiceAccount = serviceAccount
      , rawWorkerSessionId = sessionId
      , rawWorkerSessionAccessor = sessionAccessor
      , rawWorkerOperation = observedWorkerOperation observed
      , rawWorkerFenceGeneration = fenceGeneration
      , rawWorkerOwnerNonce = owner
      , rawWorkerActionDigest = actionDigest
      , rawWorkerRequestDigest = requestDigest
      , rawWorkerStorageGeneration = storageGeneration
      , rawWorkerOperationDeadline =
          operationDeadlineFromMicros (observedWorkerOperationDeadlineMicros observed)
      }

data RawBootstrapLeaseObservation
  = RawBootstrapLeaseMissing
  | RawBootstrapLeaseUnobservable !Text
  | RawBootstrapLeaseObserved
      { observedLeaseFenceGeneration :: !Natural
      , observedLeaseOwnerNonce :: !Text
      , observedLeaseActionDigest :: !Text
      , observedLeaseRequestDigest :: !Text
      , observedLeaseStorageGeneration :: !Text
      , observedLeaseOperationDeadlineMicros :: !Natural
      , observedLeaseLocalDeadline :: !Deadline
      , observedLeaseResourceVersion :: !Text
      }
  deriving stock (Eq, Show)

-- | Fixed Lease coordinate used by the Broker's single mutation fence. The
-- namespaced Role can therefore constrain observation to this exact object.
bootstrapFenceLeaseName :: Text
bootstrapFenceLeaseName = "bootstrap-broker-fence"

observeBootstrapLease
  :: RawBootstrapLeaseObservation -> BootstrapLeaseObservation
observeBootstrapLease observation = case observation of
  RawBootstrapLeaseMissing -> BootstrapLeaseMissing
  RawBootstrapLeaseUnobservable detail -> BootstrapLeaseUnobservable detail
  RawBootstrapLeaseObserved
    { observedLeaseFenceGeneration
    , observedLeaseOwnerNonce
    , observedLeaseActionDigest
    , observedLeaseRequestDigest
    , observedLeaseStorageGeneration
    , observedLeaseOperationDeadlineMicros
    , observedLeaseLocalDeadline
    , observedLeaseResourceVersion
    } ->
      case do
        owner <- firstShow (mkOwnerNonce observedLeaseOwnerNonce)
        actionDigest <- firstShow (mkArtifactDigest observedLeaseActionDigest)
        requestDigest <- firstText (mkRequestDigest observedLeaseRequestDigest)
        storageGeneration <- firstShow (mkVaultStorageGeneration observedLeaseStorageGeneration)
        firstShow
          ( reloadBootstrapLeaseBinding
              observedLeaseFenceGeneration
              owner
              actionDigest
              requestDigest
              storageGeneration
              (operationDeadlineFromMicros observedLeaseOperationDeadlineMicros)
          ) of
        Left detail -> BootstrapLeaseUnobservable detail
        Right binding ->
          BootstrapLeaseObserved
            binding
            observedLeaseLocalDeadline
            observedLeaseResourceVersion

firstShow :: (Show error) => Either error value -> Either Text value
firstShow = either (Left . Text.pack . show) Right

firstText :: Either String value -> Either Text value
firstText = either (Left . Text.pack) Right
