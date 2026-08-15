{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Native, bounded Kubernetes observation and cleanup for the Bootstrap
-- Broker's sole one-shot secret worker.
--
-- Creation implements the durable two-stage protocol: a UID-free intent is
-- already journaled before this boundary receives it; POST success or a lost
-- response recovered through fixed-name GET is then bound to the API-assigned
-- UID. Observation, terminated-process receipt binding, UID-preconditioned
-- deletion, and positive 404 absence read-back all use the Broker's rotating
-- projected ServiceAccount token.
module Prodbox.Bootstrap.Broker.KubernetesWorker
  ( KubernetesWorkerBoundary (..)
  , ControllerImageIdentity (..)
  , ControllerImageObservation (..)
  , ControllerSelfObservationScope (..)
  , WorkerImagePullReference
  , mkWorkerImagePullReference
  , renderWorkerImagePullReference
  , controllerImageFromResponse
  , controllerImageObservationDetail
  , VaultStorageIdentity
  , renderVaultStorageIdentity
  , productionKubernetesWorkerBoundary
  , readProjectedServiceAccountToken
  , workerContainerName
  , workerPodAnnotationsForIntent
  , workerPodAnnotationsForRequest
  , workerPodManifestForIntent
  , workerRequestFromCreateResponse
  , workerRequestFromRunningResponse
  , workerRequestFromSelfResponse
  , WorkerPodDecodeReason (..)
  , decodeWorkerPod
  , renderWorkerPodDecodeReason
  , imageDigestFromRuntimeId
  , bootstrapLeaseAnnotationsForFence
  , bootstrapLeaseManifestForFence
  , workerPodDeleteOptions
  , workerRequestDeleteOptions
  , workerAttestationFromResponse
  , workerExitFromResponse
  , workerDeletionFromResponse
  , workerAbsenceFromResponse
  , fenceOwnerWorkerFromResponse
  , bootstrapLeaseFromResponse
  , kubernetesTransportFailureLabel
  , unobservableReason
  , imageReferenceRepository
  , brokerPodsUrl
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( IOException
  , SomeAsyncException
  , SomeException
  , fromException
  , try
  , tryJust
  )
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
  ( FromJSON (..)
  , Value
  , eitherDecodeStrict'
  , encode
  , object
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Char (isAscii, isAsciiLower, isControl, isDigit, isSpace)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Read qualified as TextRead
import Data.Time.Clock
  ( UTCTime
  , addUTCTime
  , diffUTCTime
  , getCurrentTime
  )
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.X509.CertificateStore (readCertificateStore)
import Network.Connection (TLSSettings (..))
import Network.HTTP.Client
  ( BodyReader
  , HttpException (..)
  , HttpExceptionContent (..)
  , Manager
  , Request (..)
  , RequestBody (RequestBodyLBS)
  , brRead
  , newManager
  , parseRequest
  , responseBody
  , responseStatus
  , responseTimeoutMicro
  , withResponse
  )
import Network.HTTP.Client.TLS (mkManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Network.TLS
  ( ClientParams (..)
  , Shared (..)
  , defaultParamsClient
  )
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.ChartStatics qualified as ChartStatics
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapFenceGeneration
  , BootstrapFenceOwnerWorkerObservation (..)
  , BootstrapLeaseObservation (..)
  , BootstrapSessionFence
  , bootstrapFenceActionDigest
  , bootstrapFenceGeneration
  , bootstrapFenceGenerationValue
  , bootstrapFenceOperationDeadline
  , bootstrapFenceOwnerNonce
  , bootstrapFenceRequestDigest
  , bootstrapFenceStorageGeneration
  )
import Prodbox.Bootstrap.Broker.KubernetesAttestation
  ( RawBootstrapLeaseObservation (..)
  , RawWorkerPodObservation (..)
  , attestWorkerPodObservation
  , bindWorkerPodObservation
  , bootstrapFenceLeaseName
  , bootstrapSecretWorkerPodName
  , observeBootstrapLease
  , parseSecretWorkerOperation
  , rawWorkerAttestation
  , renderSecretWorkerOperation
  , workerPodNameForCleanupBinding
  )
import Prodbox.Bootstrap.Broker.Request
  ( RequestDigest
  , renderRequestDigest
  )
import Prodbox.Bootstrap.Broker.SecretWorker
  ( RawSecretWorkerAttestation (..)
  , SecretFreeWorkerRequest
  , SecretWorkerAttestationObservation (..)
  , SecretWorkerCleanupBinding (..)
  , SecretWorkerIntent
  , SecretWorkerLifecycleObservation (..)
  , SecretWorkerOperation
  , WorkerImageDigest
  , mkWorkerImageDigest
  , projectObservedSecretFreeWorkerRequest
  , renderWorkerImageDigest
  , renderWorkerPodUid
  , renderWorkerServiceAccount
  , renderWorkerSessionAccessor
  , renderWorkerSessionId
  , secretWorkerIntentActionDigest
  , secretWorkerIntentFenceGeneration
  , secretWorkerIntentImageDigest
  , secretWorkerIntentOperation
  , secretWorkerIntentOperationDeadline
  , secretWorkerIntentOwnerNonce
  , secretWorkerIntentRequestDigest
  , secretWorkerIntentServiceAccount
  , secretWorkerIntentSessionAccessor
  , secretWorkerIntentSessionId
  , secretWorkerIntentStorageGeneration
  , secretWorkerRequestActionDigest
  , secretWorkerRequestDigest
  , secretWorkerRequestIntent
  , secretWorkerRequestOperation
  , secretWorkerRequestPodUid
  , secretWorkerRequestStorageGeneration
  )
import Prodbox.Bootstrap.Broker.Settings (bootstrapFenceLeaseDurationSeconds)
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , PristineResetProof
  , VaultStorageGeneration
  , mkArtifactDigest
  , pristineStorageBinding
  , renderArtifactDigest
  , renderVaultStorageGeneration
  , resetAmbiguousBinding
  , resetReplacementPristine
  , rootInitStorageGeneration
  )
import Prodbox.ControlPlane.AuthorityClock (operationDeadlineMicros)
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , DeadlineObservation (..)
  , MonotonicInstant
  , RemainingDuration (..)
  , deadlineAtOffset
  , deadlineExpired
  , deadlineFromInstant
  , deadlineObservation
  )
import Prodbox.ControlPlane.Interpreter (realMonotonicNow)
import Prodbox.K8s.InCluster
  ( inClusterCaCertPath
  , inClusterNamespacePath
  , inClusterTokenPath
  , secretApiBaseUrl
  )
import Prodbox.Lifecycle.Lease (ownerNonceText)
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Timeout (timeout)

-- | Closed production operations that are sound before a creator exists.
-- Transport failures become the corresponding typed unobservable observation;
-- callers cannot mistake them for absence or successful cleanup.
data KubernetesWorkerBoundary = KubernetesWorkerBoundary
  { kubernetesCreateWorkerWorkload
      :: Deadline
      -> SecretWorkerIntent
      -> IO (Either Text SecretFreeWorkerRequest)
  , kubernetesObserveWorkerAttestation
      :: Deadline
      -> SecretFreeWorkerRequest
      -> IO SecretWorkerAttestationObservation
  , kubernetesDiscardUnreceiptedWorker
      :: Deadline
      -> SecretFreeWorkerRequest
      -> IO (Either Text ())
  , kubernetesObserveWorkerExit
      :: Deadline
      -> SecretWorkerCleanupBinding
      -> IO SecretWorkerLifecycleObservation
  , kubernetesDeleteWorkerPod
      :: Deadline
      -> SecretWorkerCleanupBinding
      -> IO SecretWorkerLifecycleObservation
  , kubernetesObserveWorkerAbsence
      :: Deadline
      -> SecretWorkerCleanupBinding
      -> IO SecretWorkerLifecycleObservation
  , kubernetesObserveFenceOwnerWorker
      :: Deadline
      -> BootstrapFenceGeneration
      -> IO BootstrapFenceOwnerWorkerObservation
  -- ^ Sprint 2.47.  Keyed by fence generation rather than by
  -- 'SecretWorkerCleanupBinding', because a successor holding only a stale
  -- durable fence cannot construct one of those.  This is the sole production
  -- producer of 'BootstrapFenceOwnerWorkerObservation'.
  , kubernetesObserveBootstrapLease
      :: Deadline
      -> IO BootstrapLeaseObservation
  , kubernetesEnsureBootstrapLease
      :: Deadline
      -> BootstrapSessionFence
      -> IO BootstrapLeaseObservation
  , kubernetesObserveControllerImage
      :: ControllerSelfObservationScope
      -> Deadline
      -> IO ControllerImageObservation
  -- ^ The scope argument is mandatory rather than defaulted so a caller must
  -- state whether it may require the controller Pod's own Ready condition.
  , kubernetesObserveSelfWorkerRequest
      :: Deadline
      -> SecretWorkerOperation
      -> IO (Either Text SecretFreeWorkerRequest)
  , kubernetesObserveVaultStorageIdentity
      :: Deadline
      -> IO (Either Text VaultStorageIdentity)
  , kubernetesResetVaultStorage
      :: Deadline
      -> PristineResetProof
      -> IO (Either Text VaultStorageIdentity)
  }

-- | API-owned identity of the exact Vault PVC.  The constructor remains
-- private so a reset proof can only be associated with an observed PVC.
newtype VaultStorageIdentity = VaultStorageIdentity Text
  deriving stock (Eq, Ord, Show)

renderVaultStorageIdentity :: VaultStorageIdentity -> Text
renderVaultStorageIdentity (VaultStorageIdentity identity) = identity

workerContainerName :: Text
workerContainerName = "bootstrap-secret-worker"

maximumProjectedTokenBytes :: Int
maximumProjectedTokenBytes = 16 * 1024

maximumKubernetesResponseBytes :: Int
maximumKubernetesResponseBytes = 128 * 1024

maximumKubernetesRequestMicros :: Natural
maximumKubernetesRequestMicros = 5 * 1000 * 1000

productionKubernetesWorkerBoundary
  :: IO (Either String KubernetesWorkerBoundary)
productionKubernetesWorkerBoundary = do
  namespaceResult <- readProjectedNamespace
  managerResult <- inClusterManager
  pure $ do
    namespace <- namespaceResult
    manager <- managerResult
    Right
      KubernetesWorkerBoundary
        { -- Sprint 2.51: the worker Pod's @image@ is the controller's own
          -- __declared__ reference, observed here rather than carried in the
          -- durable intent. The intent's 'WorkerImageDigest' is the runtime
          -- identity the worker must be attested against; a pull reference is
          -- where the kubelet looks, not part of what the intent proves, so
          -- recording it durably would be the same layer confusion one level up
          -- (and would change the generic-'Serialise' arity of every
          -- already-written checkpoint — see the sprint block).
          --
          -- Observing it here also buys a check that did not exist: the freshly
          -- observed controller runtime digest must still equal the one the
          -- intent pinned, so a controller redeployed between intent allocation
          -- and Pod creation is refused at the boundary with its own reason
          -- instead of failing attestation four stages later.
          --
          -- __The deadline composition changes and is stated rather than
          -- absorbed.__ This path shares one @workerApiBudgetMicros@ deadline
          -- across every request it makes, and that count goes from at most two
          -- (POST, plus a GET only on 409) to at most three. The budget is not
          -- widened: these are in-cluster API round trips against the local
          -- API server, and the added one is the same PodList read
          -- 'allocateIntent' already performs under the same budget. Exhausting
          -- it is a fail-closed refusal that the outer reconcile retries, not a
          -- wrong result.
          kubernetesCreateWorkerWorkload = \deadline intent -> do
            observation <-
              observeControllerImage ControllerObservedForWorkerLaunch manager namespace deadline
            case observation of
              ControllerImageUnobservable detail ->
                pure (Left (unobservableReason "controller image unobservable" detail))
              ControllerImageIdentityRejected detail ->
                pure (Left (unobservableReason "controller image identity rejected" detail))
              ControllerImageObserved identity
                | controllerImageRuntimeDigest identity /= secretWorkerIntentImageDigest intent ->
                    pure
                      ( Left
                          "the controller image changed after the worker intent was allocated"
                      )
                | otherwise -> do
                    let pullReference = controllerImagePullReference identity
                    created <-
                      requestKubernetes
                        manager
                        deadline
                        "POST"
                        (workerPodsUrl namespace)
                        (Just (workerPodManifestForIntent namespace pullReference intent))
                    case created of
                      Left detail -> pure (Left detail)
                      Right (201, body) ->
                        pure
                          (workerRequestFromCreateResponse namespace pullReference intent 201 body)
                      Right (409, _) -> do
                        observed <-
                          requestKubernetes manager deadline "GET" (workerPodUrl namespace) Nothing
                        pure $ case observed of
                          Left detail -> Left detail
                          Right (code, body) ->
                            workerRequestFromCreateResponse namespace pullReference intent code body
                      Right _ -> pure (Left "Kubernetes refused secret-worker Pod creation")
        , kubernetesObserveWorkerAttestation = \deadline request -> do
            response <- requestKubernetes manager deadline "GET" (workerPodUrl namespace) Nothing
            pure $ case response of
              Left detail ->
                SecretWorkerAttestationUnobservable
                  (unobservableReason "Kubernetes Pod observation unavailable" detail)
              Right (code, body) -> workerAttestationFromResponse namespace request code body
        , kubernetesDiscardUnreceiptedWorker =
            discardUnreceiptedWorker manager namespace
        , kubernetesObserveWorkerExit = \deadline binding -> do
            response <- requestKubernetes manager deadline "GET" (workerPodUrl namespace) Nothing
            pure $ case response of
              Left detail ->
                SecretWorkerLifecycleUnobservable
                  (unobservableReason "Kubernetes Pod exit observation unavailable" detail)
              Right (code, body) -> workerExitFromResponse namespace binding code body
        , kubernetesDeleteWorkerPod = \deadline binding -> do
            response <-
              requestKubernetes
                manager
                deadline
                "DELETE"
                (workerPodUrl namespace)
                (Just (workerPodDeleteOptions binding))
            pure $ case response of
              Left detail ->
                SecretWorkerLifecycleUnobservable
                  (unobservableReason "Kubernetes Pod deletion unavailable" detail)
              Right (code, body) -> workerDeletionFromResponse binding code body
        , kubernetesObserveWorkerAbsence = \deadline binding -> do
            response <- requestKubernetes manager deadline "GET" (workerPodUrl namespace) Nothing
            pure $ case response of
              Left detail ->
                SecretWorkerLifecycleUnobservable
                  (unobservableReason "Kubernetes Pod absence observation unavailable" detail)
              Right (code, body) -> workerAbsenceFromResponse namespace binding code body
        , kubernetesObserveFenceOwnerWorker = \deadline fenceGeneration -> do
            response <- requestKubernetes manager deadline "GET" (workerPodUrl namespace) Nothing
            pure $ case response of
              Left detail ->
                BootstrapFenceOwnerWorkerUnobservable
                  ( unobservableReason
                      "Kubernetes worker Pod observation unavailable"
                      detail
                  )
              Right (code, body) ->
                fenceOwnerWorkerFromResponse namespace fenceGeneration code body
        , kubernetesObserveBootstrapLease = \deadline -> do
            response <- requestKubernetes manager deadline "GET" (bootstrapLeaseUrl namespace) Nothing
            case response of
              Left detail ->
                pure
                  ( BootstrapLeaseUnobservable
                      (unobservableReason "Kubernetes Lease observation unavailable" detail)
                  )
              Right (code, body) -> do
                monotonicBeforeWall <- realMonotonicNow
                wallNow <- getCurrentTime
                monotonicAfterWall <- realMonotonicNow
                pure
                  ( bootstrapLeaseFromResponse
                      namespace
                      monotonicBeforeWall
                      wallNow
                      monotonicAfterWall
                      code
                      body
                  )
        , kubernetesEnsureBootstrapLease = \deadline fence -> do
            now <- getCurrentTime
            created <-
              requestKubernetes
                manager
                deadline
                "POST"
                (bootstrapLeasesUrl namespace)
                (Just (bootstrapLeaseManifestForFence namespace now Nothing fence))
            response <- case created of
              Right (409, _) -> do
                current <-
                  requestKubernetes
                    manager
                    deadline
                    "GET"
                    (bootstrapLeaseUrl namespace)
                    Nothing
                case current of
                  Right (200, body) ->
                    case eitherDecodeStrict' body of
                      Right wire ->
                        requestKubernetes
                          manager
                          deadline
                          "PUT"
                          (bootstrapLeaseUrl namespace)
                          ( Just
                              ( bootstrapLeaseManifestForFence
                                  namespace
                                  now
                                  (Just (leaseWireResourceVersion wire))
                                  fence
                              )
                          )
                      _ -> pure (Left "Kubernetes Lease read-back is invalid")
                  Left detail -> pure (Left detail)
                  Right _ -> pure (Left "Kubernetes Lease read-back was refused")
              other -> pure other
            case response of
              Left detail ->
                pure
                  ( BootstrapLeaseUnobservable
                      (unobservableReason "Kubernetes Lease write unavailable" detail)
                  )
              Right (code, body) -> do
                monotonicBeforeWall <- realMonotonicNow
                wallNow <- getCurrentTime
                monotonicAfterWall <- realMonotonicNow
                pure
                  ( bootstrapLeaseFromResponse
                      namespace
                      monotonicBeforeWall
                      wallNow
                      monotonicAfterWall
                      (if code == 201 then 200 else code)
                      body
                  )
        , kubernetesObserveControllerImage = \scope deadline -> do
            response <-
              requestKubernetes
                manager
                deadline
                "GET"
                (brokerPodsUrl namespace)
                Nothing
            pure $ case response of
              Left detail -> ControllerImageUnobservable detail
              Right (code, body) -> controllerImageFromResponse scope namespace code body
        , kubernetesObserveSelfWorkerRequest = \deadline operation -> do
            response <- requestKubernetes manager deadline "GET" (workerPodUrl namespace) Nothing
            pure $ case response of
              Left detail -> Left detail
              Right (code, body) -> workerRequestFromSelfResponse namespace operation code body
        , kubernetesObserveVaultStorageIdentity =
            observeVaultStorageIdentity manager
        , kubernetesResetVaultStorage =
            resetVaultStorage manager namespace
        }

vaultWorkloadNamespace :: Text
vaultWorkloadNamespace = "vault"

vaultStatefulSetName :: Text
vaultStatefulSetName = "vault"

vaultPodName :: Text
vaultPodName = "vault-0"

vaultDataPvcName :: Text
vaultDataPvcName = "data-vault-0"

vaultResetPodName :: Text
vaultResetPodName = "bootstrap-vault-pristine-reset"

vaultResetContainerName :: Text
vaultResetContainerName = "vault-storage-reset"

vaultResetOldGenerationAnnotation :: Text
vaultResetOldGenerationAnnotation = "bootstrap.prodbox.dev/reset-old-generation"

vaultResetNewGenerationAnnotation :: Text
vaultResetNewGenerationAnnotation = "bootstrap.prodbox.dev/reset-new-generation"

vaultResetPvcUidAnnotation :: Text
vaultResetPvcUidAnnotation = "bootstrap.prodbox.dev/reset-pvc-uid"

observeVaultStorageIdentity
  :: Manager
  -> Deadline
  -> IO (Either Text VaultStorageIdentity)
observeVaultStorageIdentity manager deadline = do
  observed <-
    requestKubernetes
      manager
      deadline
      "GET"
      vaultPvcUrl
      Nothing
  pure $ case observed of
    Left detail -> Left detail
    Right (200, body) -> vaultStorageIdentityFromResponse body
    Right _ -> Left "Vault data PVC identity observation was refused"

resetVaultStorage
  :: Manager
  -> Text
  -> Deadline
  -> PristineResetProof
  -> IO (Either Text VaultStorageIdentity)
resetVaultStorage manager brokerNamespace deadline proof = do
  identityResult <- observeVaultStorageIdentity manager deadline
  digestObservation <-
    observeControllerImage
      ControllerObservedForWorkerLaunch
      manager
      brokerNamespace
      deadline
  -- Sprint 2.51: the reset Pod is the second registry pull the Broker issues,
  -- and it carried the identical defect. It now takes the controller's declared
  -- reference for the same reason the worker Pod does; the runtime digest has no
  -- role here, because nothing attests the reset Pod against the controller.
  let pullResult = case digestObservation of
        ControllerImageObserved observed -> Right (controllerImagePullReference observed)
        ControllerImageUnobservable detail -> Left detail
        ControllerImageIdentityRejected detail -> Left detail
  case (identityResult, pullResult) of
    (Left detail, _) -> pure (Left detail)
    (_, Left detail) -> pure (Left detail)
    (Right identity, Right pullReference) -> do
      scaledDown <- setVaultScale manager deadline 0
      case scaledDown of
        Left detail -> pure (Left detail)
        Right () -> do
          absent <- awaitNamedPodAbsence manager deadline vaultPodUrl
          case absent of
            Left detail -> pure (Left detail)
            Right () -> do
              resetPod <-
                ensureVaultResetPod
                  manager
                  deadline
                  identity
                  pullReference
                  proof
              case resetPod of
                Left detail -> pure (Left detail)
                Right resetPodUid -> do
                  deleted <-
                    deleteNamedPod
                      manager
                      deadline
                      vaultResetPodUrl
                      resetPodUid
                  case deleted of
                    Left detail -> pure (Left detail)
                    Right () -> do
                      resetAbsent <-
                        awaitNamedPodAbsence
                          manager
                          deadline
                          vaultResetPodUrl
                      case resetAbsent of
                        Left detail -> pure (Left detail)
                        Right () -> do
                          identityReadBack <-
                            observeVaultStorageIdentity manager deadline
                          case identityReadBack of
                            Right observedIdentity
                              | observedIdentity == identity -> do
                                  scaledUp <- setVaultScale manager deadline 1
                                  pure (identity <$ scaledUp)
                            Right _ ->
                              pure
                                (Left "Vault data PVC identity changed during pristine reset")
                            Left detail -> pure (Left detail)

observeControllerImage
  :: ControllerSelfObservationScope
  -> Manager
  -> Text
  -> Deadline
  -> IO ControllerImageObservation
observeControllerImage scope manager namespace deadline = do
  response <-
    requestKubernetes
      manager
      deadline
      "GET"
      (brokerPodsUrl namespace)
      Nothing
  pure $ case response of
    Left detail -> ControllerImageUnobservable detail
    Right (code, body) -> controllerImageFromResponse scope namespace code body

-- | The API server's status for a credential it will not authenticate. It is
-- deliberately not grouped with 403, which a cold cluster answers while the
-- broker's RoleBinding is still being applied.
kubernetesUnauthorizedStatus :: Int
kubernetesUnauthorizedStatus = 401

identityRejectionDetail :: Text
identityRejectionDetail =
  "Kubernetes refused the Bootstrap Broker projected ServiceAccount token"

setVaultScale :: Manager -> Deadline -> Natural -> IO (Either Text ())
setVaultScale manager deadline replicas = do
  observed <-
    requestKubernetes manager deadline "GET" vaultScaleUrl Nothing
  case observed of
    Left detail -> pure (Left detail)
    Right (200, body) -> case decodeScale body of
      Left detail -> pure (Left detail)
      Right wire -> do
        updated <-
          requestKubernetes
            manager
            deadline
            "PUT"
            vaultScaleUrl
            (Just (vaultScaleManifest (scaleWireResourceVersion wire) replicas))
        pure $ case updated of
          Left detail -> Left detail
          Right (200, responseBody) -> do
            readBack <- decodeScale responseBody
            if scaleWireReplicas readBack == replicas
              then Right ()
              else Left "Vault StatefulSet scale read-back differed"
          Right _ -> Left "Vault StatefulSet scale update was refused"
    Right _ -> pure (Left "Vault StatefulSet scale observation was refused")

ensureVaultResetPod
  :: Manager
  -> Deadline
  -> VaultStorageIdentity
  -> WorkerImagePullReference
  -> PristineResetProof
  -> IO (Either Text Text)
ensureVaultResetPod manager deadline identity pullReference proof = do
  created <-
    requestKubernetes
      manager
      deadline
      "POST"
      vaultPodsUrl
      (Just (vaultResetPodManifest identity pullReference proof))
  case created of
    Left detail -> pure (Left detail)
    Right (201, body) -> awaitResetPod body
    Right (409, _) -> do
      observed <-
        requestKubernetes manager deadline "GET" vaultResetPodUrl Nothing
      case observed of
        Left detail -> pure (Left detail)
        Right (200, body) -> awaitResetPod body
        Right _ -> pure (Left "Vault reset Pod recovery observation was refused")
    Right _ -> pure (Left "Vault reset Pod creation was refused")
 where
  awaitResetPod initialBody =
    case validateResetPod identity pullReference proof initialBody of
      Left detail -> pure (Left detail)
      Right (uid, "Succeeded", Just 0) -> pure (Right uid)
      Right (_, "Failed", _) -> pure (Left "Vault reset Pod failed")
      Right _ -> poll

  poll = do
    now <- realMonotonicNow
    if deadlineExpired now deadline
      then pure (Left "Vault reset Pod deadline elapsed")
      else do
        threadDelay 100000
        observed <-
          requestKubernetes manager deadline "GET" vaultResetPodUrl Nothing
        case observed of
          Left detail -> pure (Left detail)
          Right (200, body) -> awaitResetPod body
          Right _ -> pure (Left "Vault reset Pod observation was refused")

awaitNamedPodAbsence
  :: Manager
  -> Deadline
  -> String
  -> IO (Either Text ())
awaitNamedPodAbsence manager deadline url = do
  observed <- requestKubernetes manager deadline "GET" url Nothing
  case observed of
    Left detail -> pure (Left detail)
    Right (404, _) -> pure (Right ())
    Right (200, _) -> retry
    Right _ -> pure (Left "Kubernetes Pod absence observation was refused")
 where
  retry = do
    now <- realMonotonicNow
    if deadlineExpired now deadline
      then pure (Left "Kubernetes Pod absence deadline elapsed")
      else do
        threadDelay 100000
        awaitNamedPodAbsence manager deadline url

deleteNamedPod
  :: Manager
  -> Deadline
  -> String
  -> Text
  -> IO (Either Text ())
deleteNamedPod manager deadline url uid = do
  deleted <-
    requestKubernetes
      manager
      deadline
      "DELETE"
      url
      (Just (uidPreconditionDeleteOptions uid))
  pure $ case deleted of
    Left detail -> Left detail
    Right (code, _)
      | code == 200 || code == 202 || code == 404 -> Right ()
    Right _ -> Left "UID-preconditioned Kubernetes Pod deletion was refused"

vaultScaleManifest :: Text -> Natural -> Value
vaultScaleManifest resourceVersion replicas =
  object
    [ "apiVersion" .= ("autoscaling/v1" :: Text)
    , "kind" .= ("Scale" :: Text)
    , "metadata"
        .= object
          [ "name" .= vaultStatefulSetName
          , "namespace" .= vaultWorkloadNamespace
          , "resourceVersion" .= resourceVersion
          ]
    , "spec" .= object ["replicas" .= replicas]
    ]

vaultResetPodManifest
  :: VaultStorageIdentity
  -> WorkerImagePullReference
  -> PristineResetProof
  -> Value
vaultResetPodManifest identity pullReference proof =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("Pod" :: Text)
    , "metadata"
        .= object
          [ "name" .= vaultResetPodName
          , "namespace" .= vaultWorkloadNamespace
          , "annotations" .= vaultResetAnnotations identity proof
          ]
    , "spec"
        .= object
          [ "automountServiceAccountToken" .= False
          , "restartPolicy" .= ("Never" :: Text)
          , "terminationGracePeriodSeconds" .= (0 :: Natural)
          , "containers"
              .= [ object
                     [ "name" .= vaultResetContainerName
                     , "image" .= renderWorkerImagePullReference pullReference
                     , "imagePullPolicy" .= ("IfNotPresent" :: Text)
                     , "command" .= (["/bin/sh", "-ec"] :: [Text])
                     , "args"
                         .= ( [ "find /vault/data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"
                              ]
                                :: [Text]
                            )
                     , "resources"
                         .= object
                           [ "requests"
                               .= object
                                 [ "cpu" .= ("100m" :: Text)
                                 , "memory" .= ("64Mi" :: Text)
                                 ]
                           , "limits"
                               .= object
                                 [ "cpu" .= ("100m" :: Text)
                                 , "memory" .= ("64Mi" :: Text)
                                 ]
                           ]
                     , "volumeMounts"
                         .= [ object
                                [ "name" .= ("vault-data" :: Text)
                                , "mountPath" .= ("/vault/data" :: Text)
                                ]
                            ]
                     ]
                 ]
          , "volumes"
              .= [ object
                     [ "name" .= ("vault-data" :: Text)
                     , "persistentVolumeClaim"
                         .= object ["claimName" .= vaultDataPvcName]
                     ]
                 ]
          ]
    ]

vaultResetAnnotations
  :: VaultStorageIdentity -> PristineResetProof -> Map Text Text
vaultResetAnnotations identity proof =
  Map.fromList
    [
      ( vaultResetOldGenerationAnnotation
      , renderVaultStorageGeneration
          (rootInitStorageGeneration (resetAmbiguousBinding proof))
      )
    ,
      ( vaultResetNewGenerationAnnotation
      , renderVaultStorageGeneration
          ( rootInitStorageGeneration
              (pristineStorageBinding (resetReplacementPristine proof))
          )
      )
    , (vaultResetPvcUidAnnotation, renderVaultStorageIdentity identity)
    ]

uidPreconditionDeleteOptions :: Text -> Value
uidPreconditionDeleteOptions uid =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("DeleteOptions" :: Text)
    , "gracePeriodSeconds" .= (0 :: Natural)
    , "propagationPolicy" .= ("Background" :: Text)
    , "preconditions" .= object ["uid" .= uid]
    ]

workerPodUrl :: Text -> String
workerPodUrl namespace =
  secretApiBaseUrl
    ++ "/api/v1/namespaces/"
    ++ Text.unpack namespace
    ++ "/pods/"
    ++ Text.unpack bootstrapSecretWorkerPodName

workerPodsUrl :: Text -> String
workerPodsUrl namespace =
  secretApiBaseUrl
    ++ "/api/v1/namespaces/"
    ++ Text.unpack namespace
    ++ "/pods"

vaultScaleUrl :: String
vaultScaleUrl =
  secretApiBaseUrl
    ++ "/apis/apps/v1/namespaces/"
    ++ Text.unpack vaultWorkloadNamespace
    ++ "/statefulsets/"
    ++ Text.unpack vaultStatefulSetName
    ++ "/scale"

vaultPvcUrl :: String
vaultPvcUrl =
  secretApiBaseUrl
    ++ "/api/v1/namespaces/"
    ++ Text.unpack vaultWorkloadNamespace
    ++ "/persistentvolumeclaims/"
    ++ Text.unpack vaultDataPvcName

vaultPodsUrl :: String
vaultPodsUrl =
  secretApiBaseUrl
    ++ "/api/v1/namespaces/"
    ++ Text.unpack vaultWorkloadNamespace
    ++ "/pods"

vaultPodUrl :: String
vaultPodUrl = vaultPodsUrl ++ "/" ++ Text.unpack vaultPodName

vaultResetPodUrl :: String
vaultResetPodUrl = vaultPodsUrl ++ "/" ++ Text.unpack vaultResetPodName

bootstrapLeaseUrl :: Text -> String
bootstrapLeaseUrl namespace =
  secretApiBaseUrl
    ++ "/apis/coordination.k8s.io/v1/namespaces/"
    ++ Text.unpack namespace
    ++ "/leases/"
    ++ Text.unpack bootstrapFenceLeaseName

bootstrapLeasesUrl :: Text -> String
bootstrapLeasesUrl namespace =
  secretApiBaseUrl
    ++ "/apis/coordination.k8s.io/v1/namespaces/"
    ++ Text.unpack namespace
    ++ "/leases"

brokerPodsUrl :: Text -> String
brokerPodsUrl namespace =
  secretApiBaseUrl
    ++ "/api/v1/namespaces/"
    ++ Text.unpack namespace
    -- The chart labels every Broker object `prodbox-bootstrap-broker`
    -- (charts/bootstrap-broker/templates/_helpers.tpl), matching the
    -- repo-wide `prodbox-<component>` convention that the Broker's own
    -- NetworkPolicy peers (`prodbox-vault`, `prodbox-minio`) also use.
    -- Selecting the unprefixed name matched no Pod, so the controller-image
    -- self-observation read an empty PodList and readiness never cleared.
    ++ "/pods?labelSelector=app.kubernetes.io%2Fname%3Dprodbox-bootstrap-broker"

workerPodAnnotationsForRequest :: SecretFreeWorkerRequest -> Map Text Text
workerPodAnnotationsForRequest =
  workerPodAnnotationsForIntent . secretWorkerRequestIntent

workerPodAnnotationsForIntent :: SecretWorkerIntent -> Map Text Text
workerPodAnnotationsForIntent intent =
  Map.fromList
    [ (workerOperationAnnotation, renderSecretWorkerOperation (secretWorkerIntentOperation intent))
    , (workerSessionIdAnnotation, renderWorkerSessionId (secretWorkerIntentSessionId intent))
    ,
      ( workerSessionAccessorAnnotation
      , renderWorkerSessionAccessor (secretWorkerIntentSessionAccessor intent)
      )
    ,
      ( workerFenceGenerationAnnotation
      , naturalText
          ( bootstrapFenceGenerationValue
              (secretWorkerIntentFenceGeneration intent)
          )
      )
    , (workerOwnerNonceAnnotation, ownerNonceText (secretWorkerIntentOwnerNonce intent))
    , (workerActionDigestAnnotation, renderArtifactDigest (secretWorkerIntentActionDigest intent))
    , (workerRequestDigestAnnotation, renderRequestDigest (secretWorkerIntentRequestDigest intent))
    ,
      ( workerStorageGenerationAnnotation
      , renderVaultStorageGeneration (secretWorkerIntentStorageGeneration intent)
      )
    ,
      ( workerOperationDeadlineAnnotation
      , naturalText
          (operationDeadlineMicros (secretWorkerIntentOperationDeadline intent))
      )
    ]

-- | Exact one-container worker Pod. There is no generic command, environment
-- secret, Secret volume, writable host path, or caller-selected executable.
-- The worker reads one canonical framed payload from its attached stdin and
-- selects behavior only from the closed operation argument.
workerPodManifestForIntent
  :: Text -> WorkerImagePullReference -> SecretWorkerIntent -> Value
workerPodManifestForIntent namespace pullReference intent =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("Pod" :: Text)
    , "metadata"
        .= object
          [ "name" .= bootstrapSecretWorkerPodName
          , "namespace" .= namespace
          , "labels"
              .= object
                [ "app.kubernetes.io/name"
                    .= ("prodbox-bootstrap-broker" :: Text)
                ]
          , "annotations" .= workerPodAnnotationsForIntent intent
          ]
    , "spec"
        .= object
          [ "serviceAccountName"
              .= renderWorkerServiceAccount (secretWorkerIntentServiceAccount intent)
          , "automountServiceAccountToken" .= True
          , "restartPolicy" .= ("Never" :: Text)
          , "terminationGracePeriodSeconds" .= (0 :: Natural)
          , "containers"
              .= [ object
                     [ "name" .= workerContainerName
                     , "image" .= renderWorkerImagePullReference pullReference
                     , "imagePullPolicy" .= ("IfNotPresent" :: Text)
                     , "args" .= workerContainerArguments intent
                     , "stdin" .= True
                     , "stdinOnce" .= True
                     , "tty" .= False
                     , "resources"
                         .= object
                           [ "requests"
                               .= object
                                 [ "cpu" .= ("250m" :: Text)
                                 , "memory" .= ("256Mi" :: Text)
                                 ]
                           , "limits"
                               .= object
                                 [ "cpu" .= ("250m" :: Text)
                                 , "memory" .= ("256Mi" :: Text)
                                 ]
                           ]
                     , "volumeMounts"
                         .= [ object
                                [ "name" .= ("config" :: Text)
                                , "mountPath" .= ("/etc/bootstrap-broker/config" :: Text)
                                , "readOnly" .= True
                                ]
                            ]
                     ]
                 ]
          , "volumes"
              .= [ object
                     [ "name" .= ("config" :: Text)
                     , "configMap"
                         .= object
                           [ "name" .= ("bootstrap-broker-config" :: Text)
                           ]
                     ]
                 ]
          ]
    ]

-- | Bind the API-owned UID from either a successful POST response or the GET
-- used after a 409/lost create response. A pre-existing fixed-name Pod must
-- match the complete durable intent and the closed container program.
workerRequestFromCreateResponse
  :: Text
  -> WorkerImagePullReference
  -> SecretWorkerIntent
  -> Int
  -> ByteString
  -> Either Text SecretFreeWorkerRequest
workerRequestFromCreateResponse namespace pullReference intent code body
  | code /= 200 && code /= 201 = Left "worker Pod create/read-back returned a non-success status"
  | otherwise = do
      wire <-
        either
          (const (Left "worker Pod create/read-back response is invalid"))
          Right
          (eitherDecodeStrict' body)
      requireCreateEqual "apiVersion" "v1" (podCreateApiVersion wire)
      requireCreateEqual "kind" "Pod" (podCreateKind wire)
      requireCreateEqual "metadata.name" bootstrapSecretWorkerPodName (podCreateName wire)
      requireCreateEqual "metadata.namespace" namespace (podCreateNamespace wire)
      firstCreateString (requireBoundedText "metadata.uid" 128 (podCreateUid wire))
      requireCreateEqual
        "bootstrap annotations"
        (workerPodAnnotationsForIntent intent)
        (bootstrapWorkerAnnotations (podCreateAnnotations wire))
      requireCreateEqual
        "worker ServiceAccount"
        (renderWorkerServiceAccount (secretWorkerIntentServiceAccount intent))
        (podCreateServiceAccount wire)
      container <- firstCreateString (requireSoleNamedContainer (podCreateContainers wire))
      requireCreateEqual
        "worker image"
        (renderWorkerImagePullReference pullReference)
        (containerWireImage container)
      requireCreateEqual "worker args" (workerContainerArguments intent) (containerWireArgs container)
      requireCreateEqual "worker stdin" True (containerWireStdin container)
      requireCreateEqual "worker stdinOnce" True (containerWireStdinOnce container)
      requireCreateEqual "worker tty" False (containerWireTty container)
      bindWorkerPodObservation intent (rawCreateObservation wire intent)

workerContainerArguments :: SecretWorkerIntent -> [Text]
workerContainerArguments intent =
  [ "bootstrap-broker"
  , "secret-worker"
  , "--operation"
  , renderSecretWorkerOperation (secretWorkerIntentOperation intent)
  , "--config"
  , "/etc/bootstrap-broker/config/config.dhall"
  ]

bootstrapWorkerAnnotations :: Map Text Text -> Map Text Text
bootstrapWorkerAnnotations =
  Map.filterWithKey (\key _ -> "bootstrap.prodbox.dev/" `Text.isPrefixOf` key)

rawCreateObservation :: PodCreateWire -> SecretWorkerIntent -> RawWorkerPodObservation
rawCreateObservation wire intent =
  RawWorkerPodObservation
    { observedWorkerPodName = podCreateName wire
    , observedWorkerPodUid = podCreateUid wire
    , observedWorkerImageDigest =
        renderWorkerImageDigest (secretWorkerIntentImageDigest intent)
    , observedWorkerServiceAccount = podCreateServiceAccount wire
    , observedWorkerSessionId =
        requiredAnnotation workerSessionIdAnnotation annotations
    , observedWorkerSessionAccessor =
        requiredAnnotation workerSessionAccessorAnnotation annotations
    , observedWorkerOperation = secretWorkerIntentOperation intent
    , observedWorkerFenceGeneration =
        annotationNatural workerFenceGenerationAnnotation annotations
    , observedWorkerOwnerNonce =
        requiredAnnotation workerOwnerNonceAnnotation annotations
    , observedWorkerActionDigest =
        requiredAnnotation workerActionDigestAnnotation annotations
    , observedWorkerRequestDigest =
        requiredAnnotation workerRequestDigestAnnotation annotations
    , observedWorkerStorageGeneration =
        requiredAnnotation workerStorageGenerationAnnotation annotations
    , observedWorkerOperationDeadlineMicros =
        annotationNatural workerOperationDeadlineAnnotation annotations
    , observedWorkerPhase = "Pending"
    , observedWorkerContainerReady = False
    , observedWorkerDeletionTimestamp = podCreateDeletionTimestamp wire
    }
 where
  annotations = podCreateAnnotations wire

requireCreateEqual :: (Eq value) => Text -> value -> value -> Either Text ()
requireCreateEqual label expected observed
  | expected == observed = Right ()
  | otherwise = Left (label <> " mismatch")

firstCreateString :: Either String value -> Either Text value
firstCreateString = either (Left . Text.pack) Right

-- | Host-side projection for authenticated attach. The Pod must be Running,
-- ready, non-deleting, runtime-digest pinned, on the compiled worker
-- ServiceAccount, and bound to the exact controller request. Session/fence
-- identifiers remain broker-generated but are syntax-validated by
-- 'rawWorkerAttestation' and copied into the canonical stdin frame.
workerRequestFromRunningResponse
  :: Text
  -> SecretWorkerOperation
  -> ArtifactDigest
  -> RequestDigest
  -> VaultStorageGeneration
  -> Int
  -> ByteString
  -> Either Text SecretFreeWorkerRequest
workerRequestFromRunningResponse namespace operation actionDigest requestDigest storageGeneration code body
  | code /= 200 = Left "worker Pod observation returned a non-success status"
  | otherwise = do
      snapshot <-
        either
          (Left . unobservableReason "worker Pod response is invalid" . renderWorkerPodDecodeReason)
          Right
          (decodeWorkerPod namespace body)
      let observed = podSnapshotObservation snapshot
      requireCreateEqual "worker phase" "Running" (observedWorkerPhase observed)
      requireCreateEqual "worker readiness" True (observedWorkerContainerReady observed)
      case observedWorkerDeletionTimestamp observed of
        Nothing -> Right ()
        Just _ -> Left "worker Pod is deleting"
      raw <- rawWorkerAttestation observed
      requireCreateEqual
        "worker ServiceAccount"
        (ChartStatics.brokerStaticWorkerServiceAccount ChartStatics.brokerChartStatics)
        (renderWorkerServiceAccount (rawWorkerServiceAccount raw))
      let request = projectObservedSecretFreeWorkerRequest raw
      requireCreateEqual "worker operation" operation (secretWorkerRequestOperation request)
      requireCreateEqual "action digest" actionDigest (secretWorkerRequestActionDigest request)
      requireCreateEqual "request digest" requestDigest (secretWorkerRequestDigest request)
      requireCreateEqual
        "storage generation"
        storageGeneration
        (secretWorkerRequestStorageGeneration request)
      Right request

-- | Worker-side reconstruction of its own exact secret-free binding.  The
-- operation is fixed by argv and every remaining value comes from the API
-- server's immutable Pod UID/runtime image and controller-authored bounded
-- annotations; no environment/config fallback exists.
workerRequestFromSelfResponse
  :: Text
  -> SecretWorkerOperation
  -> Int
  -> ByteString
  -> Either Text SecretFreeWorkerRequest
workerRequestFromSelfResponse namespace expectedOperation code body
  | code /= 200 = Left "worker self-observation returned a non-success status"
  | otherwise = do
      snapshot <-
        either
          ( Left
              . unobservableReason "worker self-observation response is invalid"
              . renderWorkerPodDecodeReason
          )
          Right
          (decodeWorkerPod namespace body)
      let observed = podSnapshotObservation snapshot
      requireCreateEqual "worker phase" "Running" (observedWorkerPhase observed)
      case observedWorkerDeletionTimestamp observed of
        Nothing -> Right ()
        Just _ -> Left "worker Pod is deleting"
      raw <- rawWorkerAttestation observed
      requireCreateEqual
        "worker ServiceAccount"
        (ChartStatics.brokerStaticWorkerServiceAccount ChartStatics.brokerChartStatics)
        (renderWorkerServiceAccount (rawWorkerServiceAccount raw))
      let request = projectObservedSecretFreeWorkerRequest raw
      requireCreateEqual "worker operation" expectedOperation (secretWorkerRequestOperation request)
      Right request

bootstrapLeaseAnnotationsForFence :: BootstrapSessionFence -> Map Text Text
bootstrapLeaseAnnotationsForFence fence =
  Map.fromList
    [
      ( workerFenceGenerationAnnotation
      , naturalText (bootstrapFenceGenerationValue (bootstrapFenceGeneration fence))
      )
    , (workerOwnerNonceAnnotation, ownerNonceText (bootstrapFenceOwnerNonce fence))
    , (workerActionDigestAnnotation, renderArtifactDigest (bootstrapFenceActionDigest fence))
    , (workerRequestDigestAnnotation, renderRequestDigest (bootstrapFenceRequestDigest fence))
    ,
      ( workerStorageGenerationAnnotation
      , renderVaultStorageGeneration (bootstrapFenceStorageGeneration fence)
      )
    ,
      ( workerOperationDeadlineAnnotation
      , naturalText (operationDeadlineMicros (bootstrapFenceOperationDeadline fence))
      )
    ]

-- | Exact fixed-name Lease body.  The durable operation deadline remains in
-- annotations and is checked independently; the Kubernetes TTL is only the
-- short liveness witness and is renewed on an idempotent resume.
--
-- Sprint 2.48: @leaseDurationSeconds@ was the literal @300@, matching
-- 'maximumBrokerRequestDeadlineMilliseconds' by coincidence across two modules
-- with no stated relationship.  It is now
-- 'bootstrapFenceLeaseDurationSeconds', which derives from that budget — see
-- there for the invariant and for why renewing the Lease was refused.
bootstrapLeaseManifestForFence
  :: Text
  -> UTCTime
  -> Maybe Text
  -> BootstrapSessionFence
  -> Value
bootstrapLeaseManifestForFence namespace renewTime resourceVersion fence =
  object
    [ "apiVersion" .= ("coordination.k8s.io/v1" :: Text)
    , "kind" .= ("Lease" :: Text)
    , "metadata"
        .= object
          ( [ "name" .= bootstrapFenceLeaseName
            , "namespace" .= namespace
            , "annotations" .= bootstrapLeaseAnnotationsForFence fence
            ]
              ++ maybe [] (\version -> ["resourceVersion" .= version]) resourceVersion
          )
    , "spec"
        .= object
          [ "holderIdentity" .= ownerNonceText (bootstrapFenceOwnerNonce fence)
          , "leaseDurationSeconds" .= bootstrapFenceLeaseDurationSeconds
          , "renewTime" .= kubernetesMicroTime renewTime
          ]
    ]

-- | Sprint 2.48: render a @metav1.MicroTime@ exactly as Kubernetes parses it.
--
-- @Lease.spec.renewTime@ is a @MicroTime@, and the API server unmarshals it with
-- the Go layout @2006-01-02T15:04:05.000000Z07:00@ — __exactly six fractional
-- digits, mandatory__. Aeson's @ToJSON UTCTime@ renders a /variable/ number of
-- fractional digits: it trims trailing zeros and can emit up to twelve from
-- picosecond resolution. Encoding the 'UTCTime' directly therefore produced a
-- body the API server rejected with @400 Bad Request@, deterministically,
-- because @getCurrentTime@ essentially never lands on exactly six significant
-- digits.
--
-- Proven server-side rather than argued, with @kubectl create --dry-run=server@
-- against this exact resource:
--
-- * @…37.123456789012Z@ (12 digits) — @BadRequest@, @cannot parse "789012Z" as "Z07:00"@
-- * @…37.123456789Z@ (9 digits) — @BadRequest@, @cannot parse "789Z" as "Z07:00"@
-- * @…37.123456Z@ (6 digits) — __accepted__
-- * @…37Z@ (0 digits) — @BadRequest@, @cannot parse "Z" as ".000000"@
--
-- Truncating toward the past is also the safe direction here: the rendered
-- instant is never later than the 'UTCTime' it came from, so the
-- @renewTime > wallNow@ guard in 'bootstrapLeaseFromResponse' cannot be tripped
-- by this encoding.
kubernetesMicroTime :: UTCTime -> Text
kubernetesMicroTime =
  Text.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S.%6qZ"

-- | Kubernetes rejects a delete if the deterministic name has been reused by
-- a different API-assigned UID. No unconditional delete request exists here.
workerPodDeleteOptions :: SecretWorkerCleanupBinding -> Value
workerPodDeleteOptions binding =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("DeleteOptions" :: Text)
    , "gracePeriodSeconds" .= (0 :: Natural)
    , "propagationPolicy" .= ("Background" :: Text)
    , "preconditions"
        .= object
          [ "uid" .= renderWorkerPodUid (cleanupWorkerPodUid binding)
          ]
    ]

workerRequestDeleteOptions :: SecretFreeWorkerRequest -> Value
workerRequestDeleteOptions request =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("DeleteOptions" :: Text)
    , "gracePeriodSeconds" .= (0 :: Natural)
    , "propagationPolicy" .= ("Background" :: Text)
    , "preconditions"
        .= object
          [ "uid" .= renderWorkerPodUid (secretWorkerRequestPodUid request)
          ]
    ]

discardUnreceiptedWorker
  :: Manager
  -> Text
  -> Deadline
  -> SecretFreeWorkerRequest
  -> IO (Either Text ())
discardUnreceiptedWorker manager namespace deadline request = do
  deleted <-
    requestKubernetes
      manager
      deadline
      "DELETE"
      (workerPodUrl namespace)
      (Just (workerRequestDeleteOptions request))
  case deleted of
    Left detail -> pure (Left detail)
    Right (code, _)
      | code == 200 || code == 202 || code == 404 -> awaitAbsence
      | otherwise ->
          pure (Left "UID-preconditioned unreceipted worker deletion was refused")
 where
  expectedUid = renderWorkerPodUid (secretWorkerRequestPodUid request)

  awaitAbsence = do
    observed <-
      requestKubernetes manager deadline "GET" (workerPodUrl namespace) Nothing
    case observed of
      Left detail -> pure (Left detail)
      Right (404, _) -> pure (Right ())
      Right (200, body) ->
        case decodePodIdentity namespace body of
          Left _ ->
            pure (Left "Unreceipted worker absence response was invalid")
          Right observedUid
            | observedUid /= expectedUid ->
                pure (Left "A replacement worker occupies the fixed coordinate")
            | otherwise -> retry
      Right _ ->
        pure (Left "Unreceipted worker absence observation was refused")

  retry = do
    now <- realMonotonicNow
    if deadlineExpired now deadline
      then pure (Left "Unreceipted worker deletion deadline elapsed")
      else do
        threadDelay 100000
        awaitAbsence

workerAttestationFromResponse
  :: Text
  -> SecretFreeWorkerRequest
  -> Int
  -> ByteString
  -> SecretWorkerAttestationObservation
workerAttestationFromResponse namespace request code body
  | code == 404 = SecretWorkerAttestationUnobservable "worker Pod is absent"
  | code /= 200 = SecretWorkerAttestationUnobservable "worker Pod GET returned a non-success status"
  | otherwise = case decodeWorkerPod namespace body of
      Left reason ->
        SecretWorkerAttestationUnobservable
          ( unobservableReason
              "worker Pod response is invalid"
              (renderWorkerPodDecodeReason reason)
          )
      Right snapshot -> attestWorkerPodObservation request (podSnapshotObservation snapshot)

workerExitFromResponse
  :: Text
  -> SecretWorkerCleanupBinding
  -> Int
  -> ByteString
  -> SecretWorkerLifecycleObservation
workerExitFromResponse namespace binding code body
  | code == 404 = SecretWorkerLifecycleUnobservable "worker Pod disappeared before exit read-back"
  | code /= 200 =
      SecretWorkerLifecycleUnobservable "worker Pod exit GET returned a non-success status"
  | otherwise = case decodeWorkerPod namespace body of
      Left reason ->
        SecretWorkerLifecycleUnobservable
          ( unobservableReason
              "worker Pod exit response is invalid"
              (renderWorkerPodDecodeReason reason)
          )
      Right snapshot -> case validateExitedPod binding snapshot of
        -- 'validateExitedPod' compares controller-authored expectations against
        -- the observation; its reasons name fields, never observed values.
        Left detail ->
          SecretWorkerLifecycleUnobservable
            (unobservableReason "worker Pod exit binding is invalid" (Text.pack detail))
        Right exitCode -> SecretWorkerProcessExited binding exitCode

workerDeletionFromResponse
  :: SecretWorkerCleanupBinding
  -> Int
  -> ByteString
  -> SecretWorkerLifecycleObservation
workerDeletionFromResponse binding code _body
  | code == 200 || code == 202 || code == 404 = SecretWorkerPodDeleted binding
  | otherwise = SecretWorkerLifecycleUnobservable "UID-preconditioned worker Pod deletion was refused"

workerAbsenceFromResponse
  :: Text
  -> SecretWorkerCleanupBinding
  -> Int
  -> ByteString
  -> SecretWorkerLifecycleObservation
workerAbsenceFromResponse namespace binding code body
  | code == 404 = SecretWorkerPodAbsent binding
  | code /= 200 =
      SecretWorkerLifecycleUnobservable "worker Pod absence GET returned a non-success status"
  | otherwise = case decodePodIdentity namespace body of
      Left _ -> SecretWorkerLifecycleUnobservable "worker Pod absence response is invalid"
      Right observedUid
        | observedUid == renderWorkerPodUid (cleanupWorkerPodUid binding) ->
            SecretWorkerLifecycleUnobservable "worker Pod is still present"
        | otherwise ->
            SecretWorkerLifecycleUnobservable "a replacement worker Pod occupies the fixed coordinate"

-- | Sprint 2.47: decide whether a secret worker exists for exactly one fence
-- generation, from one GET of the sole worker Pod coordinate.
--
-- Three outcomes, and the middle one is the whole reason this producer can
-- exist at all:
--
-- * @404@ — the coordinate is empty, so no worker exists for any generation.
-- * @200@ carrying a /different/ fence generation — the sole coordinate is
--   occupied by another generation's worker, which is itself proof that this
--   generation's worker is gone.  The Pod name is fixed and the Broker's Role
--   grants @get@\/@delete@ on that exact name, so at most one can exist.
-- * @200@ carrying /this/ fence generation — present.  A Pod that is
--   terminating still counts as present; a deletion in flight is not a
--   completed absence.
--
-- Everything else — an unparseable body, a missing or non-canonical
-- fence-generation annotation, a rejected identity, any other status, or a
-- transport failure — is unobservable, never absence.  Absence is the only
-- outcome that can authorize a fence takeover, so it is the only one that must
-- be positively proven.
--
-- This deliberately does not reuse 'decodeWorkerPod'.  That decoder requires a
-- sole named container status and a runtime image digest, which a @Pending@
-- Pod does not yet have — it would report /unobservable/ for a Pod that is
-- plainly present.  Fail-closed either way, but a presence question deserves a
-- decoder that can answer it.
fenceOwnerWorkerFromResponse
  :: Text
  -> BootstrapFenceGeneration
  -> Int
  -> ByteString
  -> BootstrapFenceOwnerWorkerObservation
fenceOwnerWorkerFromResponse namespace fenceGeneration code body
  | code == 404 = absent "absent" "none" "none"
  -- Keep this guard above the generic non-success guard or it is unreachable.
  | code == kubernetesUnauthorizedStatus =
      BootstrapFenceOwnerWorkerUnobservable identityRejectionDetail
  | code /= 200 =
      BootstrapFenceOwnerWorkerUnobservable
        "worker Pod fence-owner GET returned a non-success status"
  | otherwise = case decodePodFenceOwner namespace body of
      Left _ ->
        BootstrapFenceOwnerWorkerUnobservable
          "worker Pod fence-owner response is invalid"
      Right (observedUid, observedGeneration)
        | observedGeneration == queriedGeneration ->
            BootstrapFenceOwnerWorkerPresent fenceGeneration
        | otherwise ->
            absent "occupied" observedUid (naturalText observedGeneration)
 where
  queriedGeneration = bootstrapFenceGenerationValue fenceGeneration
  absent outcome occupantUid occupantGeneration =
    case fenceOwnerWorkerAbsenceReceipt
      namespace
      queriedGeneration
      code
      outcome
      occupantUid
      occupantGeneration of
      Left detail -> BootstrapFenceOwnerWorkerUnobservable detail
      Right receipt -> BootstrapFenceOwnerWorkerAbsent fenceGeneration receipt

-- | Receipt of the exact read-back that justified an absence claim.
--
-- It binds only API-assigned, non-secret coordinates.  The owner nonce is a
-- 32-byte ownership token and is deliberately absent, in line with the rule
-- Sprints 2.46 and 2.47 applied to the refusal narration one level up.
fenceOwnerWorkerAbsenceReceipt
  :: Text -> Natural -> Int -> Text -> Text -> Text -> Either Text ArtifactDigest
fenceOwnerWorkerAbsenceReceipt namespace queriedGeneration code outcome occupantUid occupantGeneration =
  case mkArtifactDigest (lowerHexBytes (SHA256.hash (TextEncoding.encodeUtf8 evidence))) of
    Left _ ->
      Left "worker Pod absence receipt could not be digested"
    Right digest -> Right digest
 where
  evidence =
    Text.intercalate
      "\n"
      [ "prodbox.bootstrap-fence-owner-worker-absence.v1"
      , "namespace=" <> namespace
      , "pod=" <> bootstrapSecretWorkerPodName
      , "queried-fence-generation=" <> naturalText queriedGeneration
      , "status=" <> Text.pack (show code)
      , "outcome=" <> outcome
      , "occupant-uid=" <> occupantUid
      , "occupant-fence-generation=" <> occupantGeneration
      ]

bootstrapLeaseFromResponse
  :: Text
  -> MonotonicInstant
  -> UTCTime
  -> MonotonicInstant
  -> Int
  -> ByteString
  -> BootstrapLeaseObservation
bootstrapLeaseFromResponse namespace monotonicBeforeWall wallNow monotonicAfterWall code body
  | code == 404 = BootstrapLeaseMissing
  -- Keep this guard above the generic non-success guard or it is unreachable.
  -- 401 is the API server refusing the Pod's own projected ServiceAccount
  -- token, which retrying the same credential can never repair; 403 stays
  -- non-terminal because a cold cluster legitimately answers it while the
  -- broker's RoleBinding has not yet been applied.
  | code == kubernetesUnauthorizedStatus =
      BootstrapLeaseIdentityRejected identityRejectionDetail
  -- Sprint 2.48: this said "GET" on a decoder the ensure path reaches with a
  -- POST/PUT response, and dropped the status entirely -- so a 400 from a
  -- malformed body and a 500 from a broken API server read identically, and
  -- neither named the call that failed. The status is not secret and is the one
  -- fact that would have identified the MicroTime defect in a single run.
  | code /= 200 =
      BootstrapLeaseUnobservable
        (Text.pack ("Bootstrap Lease request returned HTTP " ++ show code))
  | otherwise = case eitherDecodeStrict' body >>= validateLeaseWire namespace of
      Left _ -> BootstrapLeaseUnobservable "Bootstrap Lease response is invalid"
      Right (wire, localDeadline) ->
        observeBootstrapLease
          RawBootstrapLeaseObserved
            { observedLeaseFenceGeneration = annotationNatural workerFenceGenerationAnnotation annotations
            , observedLeaseOwnerNonce = requiredAnnotation workerOwnerNonceAnnotation annotations
            , observedLeaseActionDigest = requiredAnnotation workerActionDigestAnnotation annotations
            , observedLeaseRequestDigest = requiredAnnotation workerRequestDigestAnnotation annotations
            , observedLeaseStorageGeneration = requiredAnnotation workerStorageGenerationAnnotation annotations
            , observedLeaseOperationDeadlineMicros =
                annotationNatural workerOperationDeadlineAnnotation annotations
            , observedLeaseLocalDeadline = localDeadline
            , observedLeaseResourceVersion = leaseWireResourceVersion wire
            }
       where
        annotations = leaseWireAnnotations wire
 where
  validateLeaseWire expectedNamespace wire = do
    requireEqual "apiVersion" "coordination.k8s.io/v1" (leaseWireApiVersion wire)
    requireEqual "kind" "Lease" (leaseWireKind wire)
    requireEqual "metadata.name" bootstrapFenceLeaseName (leaseWireName wire)
    requireEqual "metadata.namespace" expectedNamespace (leaseWireNamespace wire)
    requireBoundedText "resourceVersion" 1024 (leaseWireResourceVersion wire)
    let annotations = leaseWireAnnotations wire
        owner = requiredAnnotation workerOwnerNonceAnnotation annotations
    requireEqual "holderIdentity" owner (leaseWireHolderIdentity wire)
    _ <- requireNaturalAnnotation workerFenceGenerationAnnotation annotations
    _ <- requireNaturalAnnotation workerOperationDeadlineAnnotation annotations
    _ <- requireBoundedAnnotation workerOwnerNonceAnnotation 256 annotations
    _ <- requireBoundedAnnotation workerActionDigestAnnotation 128 annotations
    _ <- requireBoundedAnnotation workerRequestDigestAnnotation 128 annotations
    _ <- requireBoundedAnnotation workerStorageGenerationAnnotation 256 annotations
    if leaseWireDurationSeconds wire == 0
      || leaseWireDurationSeconds wire > fromIntegral (maxBound :: Int)
      then Left "Lease duration is invalid"
      else Right ()
    if leaseWireRenewTime wire > wallNow
      then Left "Lease renewTime is in the future"
      else Right ()
    let authorityExpiry =
          addUTCTime
            (fromIntegral (leaseWireDurationSeconds wire))
            (leaseWireRenewTime wire)
        remainingMicros :: Integer
        remainingMicros = floor (diffUTCTime authorityExpiry wallNow * 1000000)
        localDeadline
          | remainingMicros <= 0 = deadlineFromInstant monotonicBeforeWall
          | otherwise =
              deadlineAtOffset
                monotonicBeforeWall
                (RemainingDuration (fromIntegral remainingMicros))
        conservativeDeadline
          | deadlineExpired monotonicAfterWall localDeadline =
              deadlineFromInstant monotonicBeforeWall
          | otherwise = localDeadline
    Right (wire, conservativeDeadline)

data ScaleWire = ScaleWire
  { scaleWireApiVersion :: !Text
  , scaleWireKind :: !Text
  , scaleWireName :: !Text
  , scaleWireNamespace :: !Text
  , scaleWireResourceVersion :: !Text
  , scaleWireReplicas :: !Natural
  }

instance FromJSON ScaleWire where
  parseJSON = withObject "Kubernetes Scale" $ \root -> do
    metadata <- root .: "metadata"
    spec <- root .: "spec"
    ScaleWire
      <$> root .: "apiVersion"
      <*> root .: "kind"
      <*> metadata .: "name"
      <*> metadata .: "namespace"
      <*> metadata .: "resourceVersion"
      <*> spec .: "replicas"

decodeScale :: ByteString -> Either Text ScaleWire
decodeScale body = do
  wire <-
    either
      (const (Left "Vault StatefulSet Scale response is invalid"))
      Right
      (eitherDecodeStrict' body)
  requireCreateEqual "apiVersion" "autoscaling/v1" (scaleWireApiVersion wire)
  requireCreateEqual "kind" "Scale" (scaleWireKind wire)
  requireCreateEqual "metadata.name" vaultStatefulSetName (scaleWireName wire)
  requireCreateEqual
    "metadata.namespace"
    vaultWorkloadNamespace
    (scaleWireNamespace wire)
  firstCreateString
    (requireBoundedText "metadata.resourceVersion" 1024 (scaleWireResourceVersion wire))
  Right wire

data VaultPvcIdentityWire = VaultPvcIdentityWire
  { vaultPvcApiVersion :: !Text
  , vaultPvcKind :: !Text
  , vaultPvcName :: !Text
  , vaultPvcNamespace :: !Text
  , vaultPvcUid :: !Text
  }

instance FromJSON VaultPvcIdentityWire where
  parseJSON = withObject "Vault PVC identity" $ \root -> do
    metadata <- root .: "metadata"
    VaultPvcIdentityWire
      <$> root .: "apiVersion"
      <*> root .: "kind"
      <*> metadata .: "name"
      <*> metadata .: "namespace"
      <*> metadata .: "uid"

vaultStorageIdentityFromResponse
  :: ByteString -> Either Text VaultStorageIdentity
vaultStorageIdentityFromResponse body = do
  wire <-
    either
      (const (Left "Vault data PVC response is invalid"))
      Right
      (eitherDecodeStrict' body)
  requireCreateEqual "apiVersion" "v1" (vaultPvcApiVersion wire)
  requireCreateEqual "kind" "PersistentVolumeClaim" (vaultPvcKind wire)
  requireCreateEqual "metadata.name" vaultDataPvcName (vaultPvcName wire)
  requireCreateEqual
    "metadata.namespace"
    vaultWorkloadNamespace
    (vaultPvcNamespace wire)
  firstCreateString (requireBoundedText "metadata.uid" 128 (vaultPvcUid wire))
  Right (VaultStorageIdentity (vaultPvcUid wire))

data ResetPodWire = ResetPodWire
  { resetPodApiVersion :: !Text
  , resetPodKind :: !Text
  , resetPodName :: !Text
  , resetPodNamespace :: !Text
  , resetPodUid :: !Text
  , resetPodAnnotations :: !(Map Text Text)
  , resetPodContainers :: ![ResetContainerWire]
  , resetPodVolumes :: ![ResetVolumeWire]
  , resetPodPhase :: !Text
  , resetPodContainerStatuses :: ![ContainerStatusWire]
  }

data ResetPodStatusWire = ResetPodStatusWire
  { resetPodStatusPhase :: !Text
  , resetPodStatusContainerStatuses :: ![ContainerStatusWire]
  }

data ResetContainerWire = ResetContainerWire
  { resetContainerName :: !Text
  , resetContainerImage :: !Text
  , resetContainerCommand :: ![Text]
  , resetContainerArgs :: ![Text]
  , resetContainerVolumeMounts :: ![ResetVolumeMountWire]
  }

data ResetVolumeMountWire = ResetVolumeMountWire
  { resetVolumeMountName :: !Text
  , resetVolumeMountPath :: !Text
  }
  deriving stock (Eq, Show)

data ResetVolumeWire = ResetVolumeWire
  { resetVolumeName :: !Text
  , resetVolumeClaimName :: !Text
  }
  deriving stock (Eq, Show)

instance FromJSON ResetPodWire where
  parseJSON = withObject "Vault reset Pod" $ \root -> do
    metadata <- root .: "metadata"
    spec <- root .: "spec"
    status <- root .:? "status" .!= ResetPodStatusWire "Pending" []
    ResetPodWire
      <$> root .: "apiVersion"
      <*> root .: "kind"
      <*> metadata .: "name"
      <*> metadata .: "namespace"
      <*> metadata .: "uid"
      <*> metadata .: "annotations"
      <*> spec .: "containers"
      <*> spec .: "volumes"
      <*> pure (resetPodStatusPhase status)
      <*> pure (resetPodStatusContainerStatuses status)

instance FromJSON ResetPodStatusWire where
  parseJSON = withObject "Vault reset Pod status" $ \value ->
    ResetPodStatusWire
      <$> value .:? "phase" .!= "Pending"
      <*> value .:? "containerStatuses" .!= []

instance FromJSON ResetContainerWire where
  parseJSON = withObject "Vault reset container" $ \value ->
    ResetContainerWire
      <$> value .: "name"
      <*> value .: "image"
      <*> value .:? "command" .!= []
      <*> value .:? "args" .!= []
      <*> value .:? "volumeMounts" .!= []

instance FromJSON ResetVolumeMountWire where
  parseJSON = withObject "Vault reset volume mount" $ \value ->
    ResetVolumeMountWire
      <$> value .: "name"
      <*> value .: "mountPath"

instance FromJSON ResetVolumeWire where
  parseJSON = withObject "Vault reset volume" $ \value -> do
    claim <- value .: "persistentVolumeClaim"
    ResetVolumeWire
      <$> value .: "name"
      <*> claim .: "claimName"

validateResetPod
  :: VaultStorageIdentity
  -> WorkerImagePullReference
  -> PristineResetProof
  -> ByteString
  -> Either Text (Text, Text, Maybe Int)
validateResetPod identity pullReference proof body = do
  wire <-
    either
      (const (Left "Vault reset Pod response is invalid"))
      Right
      (eitherDecodeStrict' body)
  requireCreateEqual "apiVersion" "v1" (resetPodApiVersion wire)
  requireCreateEqual "kind" "Pod" (resetPodKind wire)
  requireCreateEqual "metadata.name" vaultResetPodName (resetPodName wire)
  requireCreateEqual
    "metadata.namespace"
    vaultWorkloadNamespace
    (resetPodNamespace wire)
  firstCreateString (requireBoundedText "metadata.uid" 128 (resetPodUid wire))
  requireCreateEqual
    "reset annotations"
    (vaultResetAnnotations identity proof)
    ( Map.filterWithKey
        (\key _ -> "bootstrap.prodbox.dev/reset-" `Text.isPrefixOf` key)
        (resetPodAnnotations wire)
    )
  container <- case resetPodContainers wire of
    [sole] -> Right sole
    _ -> Left "Vault reset Pod must contain exactly one container"
  requireCreateEqual "reset container name" vaultResetContainerName (resetContainerName container)
  requireCreateEqual
    "reset container image"
    (renderWorkerImagePullReference pullReference)
    (resetContainerImage container)
  requireCreateEqual
    "reset container command"
    (["/bin/sh", "-ec"] :: [Text])
    (resetContainerCommand container)
  requireCreateEqual
    "reset container args"
    (["find /vault/data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"] :: [Text])
    (resetContainerArgs container)
  requireCreateEqual
    "reset container volume mount"
    [ResetVolumeMountWire "vault-data" "/vault/data"]
    (resetContainerVolumeMounts container)
  requireCreateEqual
    "reset PVC volume"
    [ResetVolumeWire "vault-data" vaultDataPvcName]
    (resetPodVolumes wire)
  termination <- case resetPodContainerStatuses wire of
    [] -> Right Nothing
    [sole]
      | containerStatusWireName sole == vaultResetContainerName ->
          Right (terminationWireExitCode <$> containerStatusWireTermination sole)
    _ -> Left "Vault reset Pod container status is invalid"
  Right (resetPodUid wire, resetPodPhase wire, termination)

data PodSnapshot = PodSnapshot
  { podSnapshotObservation :: !RawWorkerPodObservation
  , podSnapshotTermination :: !(Maybe ContainerTerminationWire)
  }

data PodListWire = PodListWire
  { podListApiVersion :: !Text
  , podListKind :: !Text
  , podListItems :: ![PodWire]
  }

instance FromJSON PodListWire where
  parseJSON = withObject "Kubernetes PodList" $ \root ->
    PodListWire
      <$> root .: "apiVersion"
      <*> root .: "kind"
      <*> root .: "items"

data PodCreateWire = PodCreateWire
  { podCreateApiVersion :: !Text
  , podCreateKind :: !Text
  , podCreateName :: !Text
  , podCreateNamespace :: !Text
  , podCreateUid :: !Text
  , podCreateDeletionTimestamp :: !(Maybe Text)
  , podCreateAnnotations :: !(Map Text Text)
  , podCreateServiceAccount :: !Text
  , podCreateContainers :: ![ContainerWire]
  }

instance FromJSON PodCreateWire where
  parseJSON = withObject "Kubernetes created Pod" $ \root -> do
    metadata <- root .: "metadata"
    spec <- root .: "spec"
    PodCreateWire
      <$> root .: "apiVersion"
      <*> root .: "kind"
      <*> metadata .: "name"
      <*> metadata .: "namespace"
      <*> metadata .: "uid"
      <*> metadata .:? "deletionTimestamp"
      <*> metadata .: "annotations"
      <*> spec .: "serviceAccountName"
      <*> spec .: "containers"

data PodWire = PodWire
  { podWireApiVersion :: !Text
  , podWireKind :: !Text
  , podWireName :: !Text
  , podWireNamespace :: !Text
  , podWireUid :: !Text
  , podWireDeletionTimestamp :: !(Maybe Text)
  , podWireAnnotations :: !(Map Text Text)
  , podWireServiceAccount :: !Text
  , podWireContainers :: ![ContainerWire]
  , podWirePhase :: !Text
  , podWireContainerStatuses :: ![ContainerStatusWire]
  }

data ContainerWire = ContainerWire
  { containerWireName :: !Text
  , containerWireImage :: !Text
  , containerWireArgs :: ![Text]
  , containerWireStdin :: !Bool
  , containerWireStdinOnce :: !Bool
  , containerWireTty :: !Bool
  }

data ContainerStatusWire = ContainerStatusWire
  { containerStatusWireName :: !Text
  , containerStatusWireImageId :: !Text
  , containerStatusWireReady :: !Bool
  , containerStatusWireTermination :: !(Maybe ContainerTerminationWire)
  }

data ContainerTerminationWire = ContainerTerminationWire
  { terminationWireExitCode :: !Int
  , terminationWireMessage :: !Text
  }

instance FromJSON PodWire where
  parseJSON = withObject "Kubernetes Pod" $ \root -> do
    metadata <- root .: "metadata"
    spec <- root .: "spec"
    status <- root .: "status"
    PodWire
      -- Sprint 2.43: Kubernetes sends `apiVersion` and `kind` on a Pod fetched
      -- directly, and omits both on a Pod that appears as an item inside a
      -- `PodList` — there they exist once, on the enclosing list. Requiring
      -- them here made every non-empty list decode fail. They are optional at
      -- parse time and default to what the enclosing list guarantees; the
      -- single-Pod path still validates the values it actually receives,
      -- because `.:?` falls back only when the key is absent.
      <$> root .:? "apiVersion" .!= "v1"
      <*> root .:? "kind" .!= "Pod"
      <*> metadata .: "name"
      <*> metadata .: "namespace"
      <*> metadata .: "uid"
      <*> metadata .:? "deletionTimestamp"
      <*> metadata .: "annotations"
      <*> spec .: "serviceAccountName"
      <*> spec .: "containers"
      <*> status .: "phase"
      -- Sprint 2.51: Kubernetes omits `containerStatuses` entirely on a Pod
      -- whose container has not been started yet. Requiring it here made that
      -- state an unparsable response, which is one of the four identical
      -- candidate reasons that hid the worker-image defect. It is now absent-as-
      -- empty, and 'decodeWorkerPod' reports the empty case as
      -- 'WorkerPodNotStarted'. Nothing is weakened: every consumer still
      -- requires exactly one named status and refuses the empty list.
      <*> status .:? "containerStatuses" .!= []

instance FromJSON ContainerWire where
  parseJSON = withObject "Kubernetes container" $ \value ->
    ContainerWire
      <$> value .: "name"
      <*> value .: "image"
      <*> value .:? "args" .!= []
      <*> value .:? "stdin" .!= False
      <*> value .:? "stdinOnce" .!= False
      <*> value .:? "tty" .!= False

instance FromJSON ContainerStatusWire where
  parseJSON = withObject "Kubernetes container status" $ \value -> do
    state <- value .: "state"
    ContainerStatusWire
      <$> value .: "name"
      <*> value .: "imageID"
      <*> value .: "ready"
      <*> state .:? "terminated"

instance FromJSON ContainerTerminationWire where
  parseJSON = withObject "Kubernetes terminated container" $ \value ->
    ContainerTerminationWire
      <$> value .: "exitCode"
      <*> value .: "message"

-- | Whether an observation of the broker's own controller Pod may require that
-- Pod to already be Ready.
--
-- The Ready condition of the broker Pod /is/ the verdict of its own readiness
-- endpoint. An observation made on behalf of that endpoint therefore must not
-- demand it: doing so is a self-reference that can never converge on a cold
-- start, because the Pod cannot become Ready until the endpoint reports ready
-- and the endpoint cannot report ready until the Pod is Ready. Naming the two
-- scopes here makes the circular one unselectable by accident.
data ControllerSelfObservationScope
  = -- | The broker is serving a request, so its own Pod is necessarily Ready
    -- already and requiring it adds a real safety check before a worker Pod
    -- inherits the controller's image digest.
    ControllerObservedForWorkerLaunch
  | -- | The observation feeds the broker's own readiness projection. Requiring
    -- self-readiness here is circular, so this scope never does.
    ControllerObservedForOwnReadiness
  deriving stock (Eq, Show)

-- | The controller Pod's image, in the two identities that are __not__
-- interchangeable and that Sprint 2.51 exists to stop confusing.
--
-- A container image carries two sha256 identities, and they are the same
-- sixty-four lower-hex characters:
--
--   * the __config digest__, which the container runtime reports as
--     @status.containerStatuses[].imageID@. It names the runtime's layer. It is
--     the identity two Pods must share to have run the same bytes, and it is
--     the one an OCI registry __cannot__ resolve — there is no reverse index
--     from a config digest to the manifest that references it, so
--     @GET \/v2\/\<name\>\/manifests\/\<config digest\>@ is an error, not a
--     lookup.
--   * the __declared reference__, @spec.containers[].image@, which names the
--     registry's layer. It is what the kubelet can actually pull, and it is
--     mutable (the harness renders a machine-id or substrate tag).
--
-- The Broker needs both and they answer different questions: the runtime digest
-- is __what is proven__, the declared reference is __where to look__. Carrying
-- only the first is what put every worker Pod in @ImagePullBackOff@; carrying
-- only the second would launch a worker that is not provably the controller's
-- own bytes.
data ControllerImageIdentity = ControllerImageIdentity
  { controllerImageRuntimeDigest :: !WorkerImageDigest
  -- ^ Observed @imageID@. The attestation identity: a worker Pod is the
  -- controller's own image exactly when its observed @imageID@ equals this.
  , controllerImagePullReference :: !WorkerImagePullReference
  -- ^ Declared @spec.containers[].image@. The kubelet's addressing hint, and
  -- the only value a worker Pod's @image@ field may carry.
  }
  deriving stock (Eq, Show)

-- | A controller-Pod observation, three-valued for the same reason the Lease
-- observation is: an identity rejection is absorbing and must not be read as a
-- dependency that is still coming up.
data ControllerImageObservation
  = ControllerImageObserved !ControllerImageIdentity
  | ControllerImageUnobservable !Text
  | ControllerImageIdentityRejected !Text
  deriving stock (Eq, Show)

-- | The detail carried by a failed controller-Pod observation, for callers
-- that only need a message.
controllerImageObservationDetail :: ControllerImageObservation -> Maybe Text
controllerImageObservationDetail observation = case observation of
  ControllerImageObserved _ -> Nothing
  ControllerImageUnobservable detail -> Just detail
  ControllerImageIdentityRejected detail -> Just detail

-- | A registry-resolvable image reference: the exact text a Pod spec's @image@
-- field is allowed to carry.
--
-- __Why this is a type rather than a 'Text'__ (Sprint 2.51). The two digests
-- described on 'ControllerImageIdentity' are indistinguishable by syntax — both
-- are @sha256:@ followed by sixty-four lower-hex characters — and
-- distinguishable only by which endpoint resolves them. No smart constructor
-- over the digest text can separate them, which is
-- [chaos_hardening_doctrine.md § 24](../../../../documents/engineering/chaos_hardening_doctrine.md)
-- exactly: an observation has a layer, and the runtime's @imageID@ names the
-- runtime's layer while a pull names the registry's.
--
-- The separation is therefore made at the boundary that __consumes__ the value
-- instead of inside the digest. This is the only type a Pod manifest accepts in
-- an @image@ field, and 'mkWorkerImagePullReference' admits only a value with a
-- repository component equal to the compiled worker image repository. A runtime
-- identity has no repository component at all, so it cannot be laundered into a
-- pull reference by any path.
--
-- It deliberately lives in this module rather than beside 'WorkerImageDigest' in
-- "Prodbox.Bootstrap.Broker.SecretWorker": the runtime digest is durable
-- attestation state, this is a Kubernetes addressing hint observed afresh each
-- time it is used, and keeping them in separate modules keeps that difference
-- visible.
newtype WorkerImagePullReference = WorkerImagePullReference Text
  deriving stock (Eq, Ord, Show)

-- | Admit only a declared image reference naming the compiled worker
-- repository. A bare runtime digest (@sha256:\<64 hex\>@) has no repository and
-- is refused here, which is the structural half of the Sprint 2.51 remedy.
mkWorkerImagePullReference :: Text -> Either String WorkerImagePullReference
mkWorkerImagePullReference value = do
  requireBoundedText "worker image reference" 512 value
  repository <-
    maybe
      (Left "worker image reference has no repository component")
      Right
      (imageReferenceRepository value)
  requireEqual
    "worker image repository"
    (ChartStatics.brokerStaticWorkerImageRepository ChartStatics.brokerChartStatics)
    repository
  Right (WorkerImagePullReference value)

-- | The sole producer of the text placed in a Pod spec @image@ field.
renderWorkerImagePullReference :: WorkerImagePullReference -> Text
renderWorkerImagePullReference (WorkerImagePullReference value) = value

controllerImageFromResponse
  :: ControllerSelfObservationScope
  -> Text
  -> Int
  -> ByteString
  -> ControllerImageObservation
controllerImageFromResponse scope namespace code body
  | code == kubernetesUnauthorizedStatus =
      ControllerImageIdentityRejected identityRejectionDetail
  | code /= 200 =
      ControllerImageUnobservable
        "Bootstrap Broker Pod observation returned a non-success status"
  | otherwise = case decodedIdentity of
      Left detail -> ControllerImageUnobservable detail
      Right identity -> ControllerImageObserved identity
 where
  decodedIdentity = do
    listing <-
      either
        (const (Left "Bootstrap Broker PodList response is invalid"))
        Right
        (eitherDecodeStrict' body)
    requireCreateEqual "apiVersion" "v1" (podListApiVersion listing)
    requireCreateEqual "kind" "PodList" (podListKind listing)
    wire <- case podListItems listing of
      [sole] -> Right sole
      _ -> Left "Bootstrap Broker PodList did not contain exactly one controller"
    requireCreateEqual "metadata.namespace" namespace (podWireNamespace wire)
    requireCreateEqual
      "controller ServiceAccount"
      (ChartStatics.brokerStaticServiceAccount ChartStatics.brokerChartStatics)
      (podWireServiceAccount wire)
    case podWireDeletionTimestamp wire of
      Nothing -> Right ()
      Just _ -> Left "Bootstrap Broker controller Pod is deleting"
    requireCreateEqual "controller phase" "Running" (podWirePhase wire)
    container <-
      case filter ((== "bootstrap-broker") . containerWireName) (podWireContainers wire) of
        [sole] -> Right sole
        _ -> Left "Bootstrap Broker controller container is missing or duplicated"
    status <-
      case filter ((== "bootstrap-broker") . containerStatusWireName) (podWireContainerStatuses wire) of
        [sole] -> Right sole
        _ -> Left "Bootstrap Broker controller status is missing or duplicated"
    case scope of
      ControllerObservedForWorkerLaunch ->
        requireCreateEqual "controller readiness" True (containerStatusWireReady status)
      ControllerObservedForOwnReadiness -> Right ()
    observedDigest <- firstCreateString (imageDigestFromRuntimeId (containerStatusWireImageId status))
    -- Sprint 2.51: the declared reference used to be read only to validate its
    -- repository and was then discarded, leaving the config digest — the one of
    -- the two that no registry can resolve — as the sole carried identity. It
    -- is now kept, because it is the only pullable one.
    pullReference <-
      firstCreateString (mkWorkerImagePullReference (containerWireImage container))
    runtimeDigest <-
      either (Left . Text.pack . show) Right (mkWorkerImageDigest observedDigest)
    Right
      ControllerImageIdentity
        { controllerImageRuntimeDigest = runtimeDigest
        , controllerImagePullReference = pullReference
        }

-- | Why a worker Pod observation could not be projected.
--
-- __Sprint 2.51: the sixth instance of the collapse Sprints @2.46@–@2.50@ each
-- closed one layer up.__ Both host-side decoders used to discard this reason
-- with @const@ and report @"worker Pod response is invalid"@, so a Pod that had
-- not started yet, a Pod whose image the kubelet could not resolve, a Pod with
-- the wrong ServiceAccount, and a malformed API response were one string. That
-- is what hid the @ImagePullBackOff@ this sprint exists to fix behind four
-- identical candidate reasons.
--
-- __The redaction question is answered by construction, not by audit.__ A worker
-- Pod's annotations carry a Vault session accessor, and an Aeson decode error
-- can quote the bytes it choked on, so this type carries no value read out of
-- the response body. Every payload here is a controller-authored constant — a
-- field label or an annotation key, both literals in this module — and the sole
-- reason that would need body text, 'WorkerPodResponseUnparsable', deliberately
-- drops the parser's message rather than forwarding it. Dropping exactly one
-- reason for a stated cause is not the collapse; collapsing eleven into it was.
data WorkerPodDecodeReason
  = -- | The body is not a Pod this decoder can read at all. The parser's own
    -- message is deliberately not carried: it is the one reason whose text can
    -- quote the response bytes.
    WorkerPodResponseUnparsable
  | -- | A fixed coordinate of the sole worker Pod disagreed. The payload is the
    -- field label, never the observed value.
    WorkerPodIdentityUnexpected !Text
  | -- | The Pod does not hold exactly the one named worker container.
    WorkerPodContainerNotSole
  | -- | The Pod carries no container status yet, so the container has not been
    -- started. Distinct from every malformed-response arm.
    WorkerPodNotStarted
  | -- | A container status exists but is not the sole named worker container.
    WorkerPodContainerStatusNotSole
  | -- | The container status exists with an empty @imageID@: the kubelet has
    -- not resolved the image. This is the arm an @ImagePullBackOff@ reaches.
    WorkerPodImageNotResolved
  | -- | @spec.containers[].image@ is not a reference into the compiled worker
    -- repository.
    WorkerPodDeclaredImageUnusable
  | -- | @status.containerStatuses[].imageID@ is present but is not a digest.
    WorkerPodRuntimeImageUnusable
  | -- | The Pod spec pinned a digest and the runtime ran a different one.
    WorkerPodImageDeclaredRuntimeDisagree
  | -- | A required bootstrap annotation is absent or out of bounds. The payload
    -- is the annotation key, never its value.
    WorkerPodAnnotationUnusable !Text
  deriving stock (Eq, Show)

-- | Total, value-free rendering of a decode reason.
renderWorkerPodDecodeReason :: WorkerPodDecodeReason -> Text
renderWorkerPodDecodeReason reason = case reason of
  WorkerPodResponseUnparsable ->
    "the response is not a readable Pod"
  WorkerPodIdentityUnexpected field ->
    "the Pod's " <> field <> " is not the sole worker coordinate"
  WorkerPodContainerNotSole ->
    "the Pod does not hold exactly the named worker container"
  WorkerPodNotStarted ->
    "the Pod has no container status yet, so the worker has not started"
  WorkerPodContainerStatusNotSole ->
    "the Pod does not hold exactly the named worker container status"
  WorkerPodImageNotResolved ->
    "the container has no runtime image identity yet, so the kubelet has not \
    \resolved the image (an image pull that is pending or backing off reaches \
    \this arm)"
  WorkerPodDeclaredImageUnusable ->
    "the Pod's declared image is not a reference into the compiled worker \
    \repository"
  WorkerPodRuntimeImageUnusable ->
    "the container's runtime image identity is not a digest"
  WorkerPodImageDeclaredRuntimeDisagree ->
    "the Pod spec pinned an image digest and the runtime ran a different one"
  WorkerPodAnnotationUnusable key ->
    "the Pod's " <> key <> " annotation is missing or out of bounds"

-- | Whether a declared @spec.containers[].image@ pins a digest.
--
-- Sprint 2.51: a declared reference is now allowed to be a tag, because a tag is
-- the only thing a registry can resolve for a locally built image. A tag carries
-- no digest to compare, which is the one check this sprint surrenders; see
-- 'decodeWorkerPod' for why the runtime comparison subsumes it.
data DeclaredImagePin
  = DeclaredPinnedByDigest !Text
  | DeclaredPinnedByTag
  deriving stock (Eq, Show)

declaredImagePin :: Text -> Either WorkerPodDecodeReason DeclaredImagePin
declaredImagePin value = case Text.breakOnEnd "@" value of
  (prefix, digest)
    | not (Text.null prefix) ->
        either
          (const (Left WorkerPodDeclaredImageUnusable))
          (Right . DeclaredPinnedByDigest)
          (validateSha256Digest digest)
  _ -> Right DeclaredPinnedByTag

-- | Project the sole worker Pod, or say precisely why it could not be projected.
--
-- __The surrendered check, and why it costs nothing__ (Sprint 2.51). This
-- decoder used to require @spec.containers[].image@ to be digest-pinned and to
-- equal the observed runtime digest. That is no longer required, because the
-- Pod's declared reference is now a pullable tag rather than an unpullable
-- config digest, and a tag carries no digest to compare.
--
-- Nothing is lost. The declared-versus-observed equality only ever proved "the
-- kubelet did not ignore the spec". What the pinning existed to prove — that the
-- worker ran the __same bytes as the controller that attests it__ — is proven
-- one layer down and independently: 'rawWorkerAttestation' carries the observed
-- runtime digest into the attestation, and @attestSecretWorker@ requires it to
-- equal the durable intent's digest, which is the controller's __own__ observed
-- runtime digest. An observation compared against an independently pinned
-- expectation subsumes a spec-conformance check against a value the same spec
-- supplied. Two checks are added rather than removed in exchange: the declared
-- reference must name the compiled worker repository, and a declared reference
-- that __does__ pin a digest must still agree with the runtime.
decodeWorkerPod :: Text -> ByteString -> Either WorkerPodDecodeReason PodSnapshot
decodeWorkerPod namespace body = do
  wire <-
    either (const (Left WorkerPodResponseUnparsable)) Right (eitherDecodeStrict' body)
  requireWorkerPodField "apiVersion" "v1" (podWireApiVersion wire)
  requireWorkerPodField "kind" "Pod" (podWireKind wire)
  requireWorkerPodField "metadata.name" bootstrapSecretWorkerPodName (podWireName wire)
  requireWorkerPodField "metadata.namespace" namespace (podWireNamespace wire)
  container <-
    either (const (Left WorkerPodContainerNotSole)) Right $
      requireSoleNamedContainer (podWireContainers wire)
  containerStatus <- case podWireContainerStatuses wire of
    [] -> Left WorkerPodNotStarted
    statuses ->
      either (const (Left WorkerPodContainerStatusNotSole)) Right $
        requireSoleNamedContainerStatus statuses
  -- Gained in exchange for the surrendered digest equality: the worker's
  -- declared reference must name the compiled worker repository, exactly as the
  -- controller's must.
  _ <-
    either
      (const (Left WorkerPodDeclaredImageUnusable))
      Right
      (mkWorkerImagePullReference (containerWireImage container))
  observedDigest <-
    let runtimeId = containerStatusWireImageId containerStatus
     in if Text.null runtimeId
          then Left WorkerPodImageNotResolved
          else
            either
              (const (Left WorkerPodRuntimeImageUnusable))
              Right
              (imageDigestFromRuntimeId runtimeId)
  declaredPin <- declaredImagePin (containerWireImage container)
  case declaredPin of
    DeclaredPinnedByTag -> Right ()
    DeclaredPinnedByDigest declaredDigest
      | declaredDigest == observedDigest -> Right ()
      | otherwise -> Left WorkerPodImageDeclaredRuntimeDisagree
  let annotations = podWireAnnotations wire
  operationText <- workerPodAnnotation workerOperationAnnotation 64 annotations
  operation <-
    either
      (const (Left (WorkerPodAnnotationUnusable workerOperationAnnotation)))
      Right
      (parseSecretWorkerOperation operationText)
  sessionId <- workerPodAnnotation workerSessionIdAnnotation 128 annotations
  sessionAccessor <- workerPodAnnotation workerSessionAccessorAnnotation 256 annotations
  fenceGeneration <- workerPodNaturalAnnotation workerFenceGenerationAnnotation annotations
  ownerNonce <- workerPodAnnotation workerOwnerNonceAnnotation 256 annotations
  actionDigest <- workerPodAnnotation workerActionDigestAnnotation 128 annotations
  requestDigest <- workerPodAnnotation workerRequestDigestAnnotation 128 annotations
  storageGeneration <- workerPodAnnotation workerStorageGenerationAnnotation 256 annotations
  operationDeadline <- workerPodNaturalAnnotation workerOperationDeadlineAnnotation annotations
  Right
    PodSnapshot
      { podSnapshotObservation =
          RawWorkerPodObservation
            { observedWorkerPodName = podWireName wire
            , observedWorkerPodUid = podWireUid wire
            , observedWorkerImageDigest = observedDigest
            , observedWorkerServiceAccount = podWireServiceAccount wire
            , observedWorkerSessionId = sessionId
            , observedWorkerSessionAccessor = sessionAccessor
            , observedWorkerOperation = operation
            , observedWorkerFenceGeneration = fenceGeneration
            , observedWorkerOwnerNonce = ownerNonce
            , observedWorkerActionDigest = actionDigest
            , observedWorkerRequestDigest = requestDigest
            , observedWorkerStorageGeneration = storageGeneration
            , observedWorkerOperationDeadlineMicros = operationDeadline
            , observedWorkerPhase = podWirePhase wire
            , observedWorkerContainerReady = containerStatusWireReady containerStatus
            , observedWorkerDeletionTimestamp = podWireDeletionTimestamp wire
            }
      , podSnapshotTermination = containerStatusWireTermination containerStatus
      }

validateExitedPod
  :: SecretWorkerCleanupBinding -> PodSnapshot -> Either String Int
validateExitedPod binding snapshot = do
  let observed = podSnapshotObservation snapshot
  requireEqual
    "Pod name"
    (workerPodNameForCleanupBinding binding)
    (observedWorkerPodName observed)
  requireEqual
    "Pod UID"
    (renderWorkerPodUid (cleanupWorkerPodUid binding))
    (observedWorkerPodUid observed)
  requireEqual
    "worker session ID"
    (renderWorkerSessionId (cleanupWorkerSessionId binding))
    (observedWorkerSessionId observed)
  let expectedAccessor =
        renderWorkerSessionAccessor (cleanupWorkerSessionAccessor binding)
      observedAccessor = observedWorkerSessionAccessor observed
  if observedAccessor == expectedAccessor || observedAccessor == "not-issued"
    then Right ()
    else Left "worker session accessor binding differs"
  requireEqual
    "request digest"
    (renderRequestDigest (cleanupWorkerRequestDigest binding))
    (observedWorkerRequestDigest observed)
  requireEqual
    "storage generation"
    (renderVaultStorageGeneration (cleanupWorkerStorageGeneration binding))
    (observedWorkerStorageGeneration observed)
  requireEqual
    "fence generation"
    (bootstrapFenceGenerationValue (cleanupWorkerFenceGeneration binding))
    (observedWorkerFenceGeneration observed)
  case observedWorkerDeletionTimestamp observed of
    Nothing -> Right ()
    Just _ -> Left "worker Pod is deleting before exit read-back"
  termination <-
    maybe (Left "worker container has not terminated") Right (podSnapshotTermination snapshot)
  let exitCode = terminationWireExitCode termination
      expectedPhase = if exitCode == 0 then "Succeeded" else "Failed"
  requireEqual "Pod phase" expectedPhase (observedWorkerPhase observed)
  requireEqual
    "termination receipt digest"
    (renderArtifactDigest (cleanupWorkerReceiptDigest binding))
    (terminationWireMessage termination)
  Right exitCode

data PodIdentityWire = PodIdentityWire
  { podIdentityApiVersion :: !Text
  , podIdentityKind :: !Text
  , podIdentityName :: !Text
  , podIdentityNamespace :: !Text
  , podIdentityUid :: !Text
  }

instance FromJSON PodIdentityWire where
  parseJSON = withObject "Kubernetes Pod identity" $ \root -> do
    metadata <- root .: "metadata"
    PodIdentityWire
      <$> root .: "apiVersion"
      <*> root .: "kind"
      <*> metadata .: "name"
      <*> metadata .: "namespace"
      <*> metadata .: "uid"

decodePodIdentity :: Text -> ByteString -> Either String Text
decodePodIdentity namespace body = do
  wire <- eitherDecodeStrict' body
  requireEqual "apiVersion" "v1" (podIdentityApiVersion wire)
  requireEqual "kind" "Pod" (podIdentityKind wire)
  requireEqual "metadata.name" bootstrapSecretWorkerPodName (podIdentityName wire)
  requireEqual "metadata.namespace" namespace (podIdentityNamespace wire)
  requireBoundedText "metadata.uid" 128 (podIdentityUid wire)
  Right (podIdentityUid wire)

-- | Sprint 2.47: identity plus the one annotation a fence-owner presence
-- question turns on.  Deliberately narrower than 'decodeWorkerPod' — see
-- 'fenceOwnerWorkerFromResponse'.
data PodFenceOwnerWire = PodFenceOwnerWire
  { podFenceOwnerApiVersion :: !Text
  , podFenceOwnerKind :: !Text
  , podFenceOwnerName :: !Text
  , podFenceOwnerNamespace :: !Text
  , podFenceOwnerUid :: !Text
  , podFenceOwnerAnnotations :: !(Map Text Text)
  }

instance FromJSON PodFenceOwnerWire where
  parseJSON = withObject "Kubernetes Pod fence owner" $ \root -> do
    metadata <- root .: "metadata"
    PodFenceOwnerWire
      <$> root .: "apiVersion"
      <*> root .: "kind"
      <*> metadata .: "name"
      <*> metadata .: "namespace"
      <*> metadata .: "uid"
      <*> metadata .:? "annotations" .!= Map.empty

decodePodFenceOwner :: Text -> ByteString -> Either String (Text, Natural)
decodePodFenceOwner namespace body = do
  wire <- eitherDecodeStrict' body
  requireEqual "apiVersion" "v1" (podFenceOwnerApiVersion wire)
  requireEqual "kind" "Pod" (podFenceOwnerKind wire)
  requireEqual "metadata.name" bootstrapSecretWorkerPodName (podFenceOwnerName wire)
  requireEqual "metadata.namespace" namespace (podFenceOwnerNamespace wire)
  requireBoundedText "metadata.uid" 128 (podFenceOwnerUid wire)
  observedGeneration <-
    requireNaturalAnnotation workerFenceGenerationAnnotation (podFenceOwnerAnnotations wire)
  Right (podFenceOwnerUid wire, observedGeneration)

data BootstrapLeaseWire = BootstrapLeaseWire
  { leaseWireApiVersion :: !Text
  , leaseWireKind :: !Text
  , leaseWireName :: !Text
  , leaseWireNamespace :: !Text
  , leaseWireResourceVersion :: !Text
  , leaseWireAnnotations :: !(Map Text Text)
  , leaseWireHolderIdentity :: !Text
  , leaseWireDurationSeconds :: !Natural
  , leaseWireRenewTime :: !UTCTime
  }

instance FromJSON BootstrapLeaseWire where
  parseJSON = withObject "Kubernetes Bootstrap Lease" $ \root -> do
    metadata <- root .: "metadata"
    spec <- root .: "spec"
    BootstrapLeaseWire
      <$> root .: "apiVersion"
      <*> root .: "kind"
      <*> metadata .: "name"
      <*> metadata .: "namespace"
      <*> metadata .: "resourceVersion"
      <*> metadata .: "annotations"
      <*> spec .: "holderIdentity"
      <*> spec .: "leaseDurationSeconds"
      <*> spec .: "renewTime"

requireSoleNamedContainer :: [ContainerWire] -> Either String ContainerWire
requireSoleNamedContainer containers = case containers of
  [container]
    | containerWireName container == workerContainerName -> Right container
  _ -> Left "Pod must contain exactly the named secret-worker container"

requireSoleNamedContainerStatus
  :: [ContainerStatusWire] -> Either String ContainerStatusWire
requireSoleNamedContainerStatus statuses = case statuses of
  [containerStatus]
    | containerStatusWireName containerStatus == workerContainerName -> Right containerStatus
  _ -> Left "Pod must contain exactly the named secret-worker status"

-- | Read a container runtime's reported image identity.
--
-- __Which layer this names__ (Sprint 2.51). @status.containerStatuses[].imageID@
-- is the container runtime's identity for an image. Under containerd it is the
-- image's __config__ digest, reported bare for an image that is present locally
-- rather than pulled; other runtimes prefix it (@docker-pullable:\/\/repo\@…@),
-- which the second arm accepts.
--
-- The result is therefore an attestation identity — two Pods sharing it ran the
-- same bytes — and __not__ a registry coordinate. It must never be concatenated
-- into an image reference; see 'WorkerImagePullReference', which is the only
-- type a Pod @image@ field accepts and which this value cannot be turned into.
imageDigestFromRuntimeId :: Text -> Either String Text
imageDigestFromRuntimeId value
  | Text.length value == 71 = validateSha256Digest value
  | otherwise =
      let candidate = Text.takeEnd 71 value
          prefix = Text.dropEnd 71 value
       in if Text.isSuffixOf "@" prefix || Text.isSuffixOf "://" prefix
            then validateSha256Digest candidate
            else Left "worker runtime image ID is not a digest"

validateSha256Digest :: Text -> Either String Text
validateSha256Digest value
  | Text.length value == 71
      && Text.take 7 value == "sha256:"
      && Text.all isLowerHex (Text.drop 7 value) =
      Right value
  | otherwise = Left "worker image digest is invalid"
 where
  isLowerHex character = isDigit character || character >= 'a' && character <= 'f'

workerOperationAnnotation :: Text
workerOperationAnnotation = "bootstrap.prodbox.dev/operation"

workerSessionIdAnnotation :: Text
workerSessionIdAnnotation = "bootstrap.prodbox.dev/session-id"

workerSessionAccessorAnnotation :: Text
workerSessionAccessorAnnotation = "bootstrap.prodbox.dev/session-accessor"

workerFenceGenerationAnnotation :: Text
workerFenceGenerationAnnotation = "bootstrap.prodbox.dev/fence-generation"

workerOwnerNonceAnnotation :: Text
workerOwnerNonceAnnotation = "bootstrap.prodbox.dev/owner-nonce"

workerActionDigestAnnotation :: Text
workerActionDigestAnnotation = "bootstrap.prodbox.dev/action-digest"

workerRequestDigestAnnotation :: Text
workerRequestDigestAnnotation = "bootstrap.prodbox.dev/request-digest"

workerStorageGenerationAnnotation :: Text
workerStorageGenerationAnnotation = "bootstrap.prodbox.dev/storage-generation"

workerOperationDeadlineAnnotation :: Text
workerOperationDeadlineAnnotation = "bootstrap.prodbox.dev/operation-deadline-micros"

requiredAnnotation :: Text -> Map Text Text -> Text
requiredAnnotation key annotations = Map.findWithDefault Text.empty key annotations

annotationNatural :: Text -> Map Text Text -> Natural
annotationNatural key annotations =
  either (const 0) id (parseNatural (requiredAnnotation key annotations))

requireBoundedAnnotation
  :: Text -> Int -> Map Text Text -> Either String Text
requireBoundedAnnotation key maximumLength annotations = do
  value <- maybe (Left "required annotation is missing") Right (Map.lookup key annotations)
  requireBoundedText "annotation" maximumLength value
  Right value

-- | 'requireBoundedAnnotation' in the closed worker-Pod reason space. The
-- reason names the annotation __key__, which is a literal in this module; the
-- offending value never appears, because one of these annotations is a Vault
-- session accessor.
workerPodAnnotation
  :: Text -> Int -> Map Text Text -> Either WorkerPodDecodeReason Text
workerPodAnnotation key maximumLength annotations =
  either
    (const (Left (WorkerPodAnnotationUnusable key)))
    Right
    (requireBoundedAnnotation key maximumLength annotations)

workerPodNaturalAnnotation
  :: Text -> Map Text Text -> Either WorkerPodDecodeReason Natural
workerPodNaturalAnnotation key annotations =
  either
    (const (Left (WorkerPodAnnotationUnusable key)))
    Right
    (requireNaturalAnnotation key annotations)

-- | 'requireEqual' in the closed worker-Pod reason space. The reason names the
-- field label only; neither the expected nor the observed value is carried.
requireWorkerPodField
  :: (Eq value) => Text -> value -> value -> Either WorkerPodDecodeReason ()
requireWorkerPodField label expected observed
  | expected == observed = Right ()
  | otherwise = Left (WorkerPodIdentityUnexpected label)

requireNaturalAnnotation
  :: Text -> Map Text Text -> Either String Natural
requireNaturalAnnotation key annotations = do
  value <- requireBoundedAnnotation key 32 annotations
  parseNatural value

parseNatural :: Text -> Either String Natural
parseNatural value = case TextRead.decimal value of
  Right (parsed, rest)
    | Text.null rest -> Right parsed
  _ -> Left "annotation is not a canonical natural number"

naturalText :: Natural -> Text
naturalText = Text.pack . show

lowerHexBytes :: ByteString -> Text
lowerHexBytes = Text.pack . concatMap renderHexByte . ByteString.unpack
 where
  renderHexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

requireBoundedText :: String -> Int -> Text -> Either String ()
requireBoundedText label maximumLength value
  | Text.null value = Left (label ++ " is empty")
  | Text.length value > maximumLength = Left (label ++ " exceeds its bound")
  | Text.any (\character -> character == '\NUL' || isControl character) value =
      Left (label ++ " contains a control character")
  | otherwise = Right ()

requireEqual :: (Eq value) => String -> value -> value -> Either String ()
requireEqual label expected observed
  | expected == observed = Right ()
  | otherwise = Left (label ++ " mismatch")

requestKubernetes
  :: Manager
  -> Deadline
  -> ByteString
  -> String
  -> Maybe Value
  -> IO (Either Text (Int, ByteString))
requestKubernetes manager deadline httpMethod url maybeBody = do
  tokenResult <- readProjectedToken
  case tokenResult of
    Left detail -> pure (Left detail)
    Right token -> do
      parsed <- tryJust catchSynchronousHttp (parseRequest url)
      case parsed of
        Left _ -> pure (Left "Kubernetes API URL is invalid")
        Right baseRequest -> do
          before <- realMonotonicNow
          case deadlineObservation before deadline of
            DeadlineExpired -> pure (Left "Kubernetes API deadline expired before dispatch")
            DeadlineOpen (RemainingDuration remainingMicros) -> do
              let requestMicros = min remainingMicros maximumKubernetesRequestMicros
                  lazyBody = encode <$> maybeBody
                  request =
                    baseRequest
                      { method = httpMethod
                      , requestHeaders =
                          [ ("Authorization", TextEncoding.encodeUtf8 ("Bearer " <> token))
                          , ("Accept", "application/json")
                          ]
                            ++ [("Content-Type", "application/json") | isJust maybeBody]
                      , requestBody = maybe (requestBody baseRequest) RequestBodyLBS lazyBody
                      , responseTimeout = responseTimeoutMicro (naturalToInt requestMicros)
                      }
              completed <-
                timeout
                  (naturalToInt requestMicros)
                  ( tryJust catchSynchronousHttp $
                      withResponse request manager $ \response -> do
                        boundedBody <- readBoundedBody (responseBody response)
                        pure
                          ( statusCode (responseStatus response)
                          , boundedBody
                          )
                  )
              after <- realMonotonicNow
              pure $ case completed of
                Nothing -> Left "Kubernetes API request timed out"
                -- Sprint 2.42: the caught exception is classified rather than
                -- discarded. Collapsing it here would leave every call site
                -- appending a prefix to a constant.
                Just (Left transportError) ->
                  Left
                    ( unobservableReason
                        "Kubernetes API request failed"
                        (kubernetesTransportFailureLabel transportError)
                    )
                Just (Right (_code, Left detail)) -> Left detail
                Just (Right (code, Right body))
                  | deadlineExpired after deadline ->
                      Left "Kubernetes API deadline expired before completion"
                  | otherwise -> Right (code, body)

readBoundedBody :: BodyReader -> IO (Either Text ByteString)
readBoundedBody = go maximumKubernetesResponseBytes []
 where
  go remaining chunks reader = do
    chunk <- brRead reader
    if ByteString.null chunk
      then pure (Right (ByteString.concat (reverse chunks)))
      else
        if ByteString.length chunk > remaining
          then pure (Left "Kubernetes API response exceeds the 128 KiB bound")
          else go (remaining - ByteString.length chunk) (chunk : chunks) reader

readProjectedToken :: IO (Either Text Text)
readProjectedToken = do
  result <-
    try
      ( withBinaryFile inClusterTokenPath ReadMode $ \handle ->
          ByteString.hGet handle (maximumProjectedTokenBytes + 1)
      )
      :: IO (Either IOException ByteString)
  pure $ case result of
    Left _ -> Left "failed to read projected ServiceAccount token"
    Right bytes
      | ByteString.length bytes > maximumProjectedTokenBytes ->
          Left "projected ServiceAccount token exceeds the 16 KiB bound"
      | otherwise -> case TextEncoding.decodeUtf8' bytes of
          Left _ -> Left "projected ServiceAccount token is not UTF-8"
          Right decoded ->
            let token = Text.strip decoded
             in if Text.null token
                  || Text.any
                    (\character -> not (isAscii character) || isSpace character || isControl character)
                    token
                  then Left "projected ServiceAccount token is invalid"
                  else Right token

-- | Exact bounded token projection for the isolated worker's one-shot Vault
-- Kubernetes login.  No environment or alternate token path is admitted.
readProjectedServiceAccountToken :: IO (Either Text Text)
readProjectedServiceAccountToken = readProjectedToken

readProjectedNamespace :: IO (Either String Text)
readProjectedNamespace = do
  result <-
    try
      ( withBinaryFile inClusterNamespacePath ReadMode $ \handle ->
          ByteString.hGet handle 64
      )
      :: IO (Either IOException ByteString)
  pure $ case result of
    Left _ -> Left "failed to read projected ServiceAccount namespace"
    Right bytes
      | ByteString.length bytes > 63 -> Left "projected ServiceAccount namespace exceeds 63 bytes"
      | otherwise -> case TextEncoding.decodeUtf8' bytes of
          Left _ -> Left "projected ServiceAccount namespace is not UTF-8"
          Right decoded -> validateNamespace (Text.strip decoded)

validateNamespace :: Text -> Either String Text
validateNamespace namespace
  | Text.null namespace = Left "projected ServiceAccount namespace is empty"
  | Text.length namespace > 63 = Left "projected ServiceAccount namespace exceeds 63 characters"
  | not (Text.all validCharacter namespace) = Left "projected ServiceAccount namespace is invalid"
  | not (alphaNumeric (Text.head namespace) && alphaNumeric (Text.last namespace)) =
      Left "projected ServiceAccount namespace is invalid"
  | otherwise = Right namespace
 where
  validCharacter character = alphaNumeric character || character == '-'
  alphaNumeric character = isAsciiLower character || isDigit character

inClusterManager :: IO (Either String Manager)
inClusterManager = do
  caStore <- readCertificateStore inClusterCaCertPath
  case caStore of
    Nothing -> pure (Left "failed to read in-pod Kubernetes CA certificate")
    Just store -> do
      let host = "kubernetes.default.svc.cluster.local"
          baseParams = defaultParamsClient host ""
          clientParams =
            baseParams {clientShared = (clientShared baseParams) {sharedCAStore = store}}
      Right <$> newManager (mkManagerSettings (TLSSettings clientParams) Nothing)

-- | Sprint 2.42: classify a synchronous 'HttpException' onto a closed set of
-- operator-facing labels.
--
-- Three rules govern this function, and the second is why @show@ is not used.
--
--   * __Classify, never @show@.__ @show@ on 'HttpExceptionRequest' prints the
--     'Request', and every request this module issues carries an
--     @Authorization: Bearer@ header (see 'requestKubernetes'). The rendered
--     reason reaches an operator through the @\/readyz@ body, so rendering the
--     exception would turn a readiness projection into a credential-disclosure
--     surface. The 'Request' is therefore matched as @_@ and never inspected.
--   * __No payload reaches the label.__ Several constructors carry attacker- or
--     credential-adjacent bytes — 'InvalidRequestHeader' can carry the
--     @Authorization@ header itself, and the proxy constructors can carry proxy
--     credentials — so every label is a fixed string and no argument is
--     interpolated.
--   * __Distinct labels.__ The cases imply different operator actions: a
--     dropped packet is a policy or routing defect, a refused connection is a
--     listener or address defect, a response timeout is a slow or wedged
--     server. Collapsing them is the § 23 corollary-2 defect this sprint
--     removes, so no two constructors share a label.
kubernetesTransportFailureLabel :: HttpException -> Text
kubernetesTransportFailureLabel err = case err of
  InvalidUrlException {} -> "the request URL is invalid"
  HttpExceptionRequest _ content -> case content of
    ConnectionTimeout ->
      "connecting to the Kubernetes API timed out (no route, or a network policy dropped the packet)"
    ConnectionFailure _ -> "connecting to the Kubernetes API failed"
    ResponseTimeout -> "the Kubernetes API accepted the connection and did not answer in time"
    NoResponseDataReceived -> "the Kubernetes API closed the connection without answering"
    ConnectionClosed -> "the connection to the Kubernetes API was closed mid-request"
    InternalException _ -> "an underlying socket or TLS layer failed"
    TlsNotSupported -> "the Kubernetes API endpoint does not support TLS"
    StatusCodeException {} -> "the Kubernetes API returned a non-2XX status"
    TooManyRedirects _ -> "the Kubernetes API redirected too many times"
    OverlongHeaders -> "the Kubernetes API returned overlong headers"
    TooManyHeaderFields -> "the Kubernetes API returned too many header fields"
    InvalidStatusLine _ -> "the Kubernetes API returned an unparseable status line"
    InvalidHeader _ -> "the Kubernetes API returned an unparseable header"
    InvalidRequestHeader _ -> "the request carried a non-compliant header"
    ProxyConnectException {} -> "the proxy refused the Kubernetes API connection"
    WrongRequestBodyStreamSize {} -> "the request body stream size did not match its declaration"
    ResponseBodyTooShort {} -> "the Kubernetes API response body was shorter than declared"
    InvalidChunkHeaders -> "the Kubernetes API returned invalid chunk headers"
    IncompleteHeaders -> "the Kubernetes API returned incomplete headers"
    InvalidDestinationHost _ -> "the Kubernetes API destination host is invalid"
    HttpZlibException _ -> "the Kubernetes API response failed to decompress"
    InvalidProxyEnvironmentVariable {} -> "the proxy environment variable is invalid"
    InvalidProxySettings _ -> "the proxy settings are invalid"

-- | Sprint 2.43: the repository half of a container image reference, with
-- whatever tag or digest is present removed.
--
-- The previous implementation required the suffix @:latest@, which the harness
-- never renders: 'Prodbox.Lib.ChartPlatform.resolveCustomImageTag' produces a
-- machine-id-derived tag on the home substrate and the fixed
-- @prodbox-aws-substrate@ tag on AWS, overriding the chart's @tag: latest@
-- default on both supported paths. The check therefore failed on every
-- substrate rather than comparing repositories.
--
-- The separator cannot simply be the first or last colon: a registry host may
-- carry a port, and @127.0.0.1:30080\/prodbox\/prodbox-runtime:tag@ contains
-- two. The tag colon is the one after the final @\/@.
imageReferenceRepository :: Text -> Maybe Text
imageReferenceRepository reference
  | Text.null reference = Nothing
  | otherwise =
      let withoutDigest = Text.takeWhile (/= '@') reference
          (beforeLastSlash, afterLastSlash) = Text.breakOnEnd "/" withoutDigest
          repository = beforeLastSlash <> Text.takeWhile (/= ':') afterLastSlash
       in if Text.null repository then Nothing else Just repository

-- | Sprint 2.42: compose an unobservable-dependency reason from the site that
-- could not be observed and the typed detail explaining why.
--
-- Every caller that turns a transport failure into a typed unobservable
-- observation routes through here, so a site phrase can never reach an operator
-- without the detail that distinguishes a dropped packet from an RBAC refusal.
unobservableReason :: Text -> Text -> Text
unobservableReason site detail = site <> ": " <> detail

catchSynchronousHttp :: HttpException -> Maybe HttpException
catchSynchronousHttp err
  | httpExceptionContainsAsync err = Nothing
  | otherwise = Just err

httpExceptionContainsAsync :: HttpException -> Bool
httpExceptionContainsAsync err = case err of
  InvalidUrlException {} -> False
  HttpExceptionRequest _ content -> case content of
    ConnectionFailure nested -> exceptionIsAsync nested
    InternalException nested -> exceptionIsAsync nested
    _ -> False

exceptionIsAsync :: SomeException -> Bool
exceptionIsAsync = isJust . (fromException :: SomeException -> Maybe SomeAsyncException)

naturalToInt :: Natural -> Int
naturalToInt value = fromIntegral (min value (fromIntegral (maxBound :: Int)))
