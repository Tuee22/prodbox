{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | Host-side production boundary for the Target Secret Agent's one-shot
-- materializer.  Kubernetes receives only a secret-free Job manifest.  The
-- bounded material frame is written to the exact attested Pod over
-- @kubectl attach -i@, and cleanup is bound to both API-assigned UIDs before
-- positive absence read-back.
module Prodbox.ControlPlane.TargetSecretWorkerProduction
  ( TargetWorkerJobConnection (..)
  , targetWorkerObserveAgentSubprocess
  , targetWorkerCreateSubprocess
  , targetWorkerObserveSubprocess
  , targetWorkerAttachSubprocess
  , targetWorkerKubernetesBoundary
  , recoverTargetWorkerCreateWith
  , parseTargetAgentRolloutObservation
  , parseTargetWorkerServiceAccountObservation
  , classifyTargetWorkerServiceAccountObservation
  , targetWorkerRetainedExecutionBoundary
  , vaultTargetWorkerRetainedExecutionBoundary
  , targetWorkerControllerAuditOps
  , targetWorkerRoleWideAccessorSubject
  , targetWorkerActiveAccessorSubject
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
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
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticationRegistry
  ( targetSecretWorkerVaultRole
  )
import Prodbox.ControlPlane.ServiceSessionJournal
  ( ServiceSessionJournalRepository
  )
import Prodbox.ControlPlane.ServiceSessionLifecycle
  ( activateFencedServiceSessionDispatch
  , allocateNextServiceSessionBinding
  , closeFencedServiceSessionDispatch
  , prepareFencedServiceSessionDispatch
  )
import Prodbox.ControlPlane.TargetIntentAuthorityClient
  ( TargetIntentAuthorityClient
  , requestTargetWorkerExecutionPermit
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentRolloutEvidence
  , mkTargetAgentIdentity
  , mkTargetAgentRolloutEvidence
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( RawTargetWorkerPodObservation (..)
  , TargetWorkerAttestation
  , TargetWorkerIntent
  , TargetWorkerJobUid
  , TargetWorkerServiceAccountUid
  , mkTargetWorkerJobUid
  , mkTargetWorkerServiceAccountUid
  , targetWorkerAttestedIntent
  , targetWorkerAttestedPodName
  , targetWorkerAttestedServiceAccountUid
  , targetWorkerCleanupAuthorization
  , targetWorkerCleanupCompletion
  , targetWorkerImageDigestText
  , targetWorkerIntentImageDigest
  , targetWorkerIntentJobName
  , targetWorkerIntentServiceAccount
  , targetWorkerJobUidText
  , targetWorkerPodUidText
  , targetWorkerProvisionalCompletionMaximumBytes
  , targetWorkerServiceAccountUidText
  )
import Prodbox.ControlPlane.TargetSecretWorkerCoordinator
  ( TargetWorkerCoordinatorError (..)
  , TargetWorkerCreateRecovery (..)
  , TargetWorkerExecutionBoundary (..)
  , TargetWorkerKubernetesBoundary (..)
  , TargetWorkerProvisionalOutcome (..)
  )
import Prodbox.ControlPlane.TargetSecretWorkerKubernetes
  ( renderTargetSecretWorkerJob
  , targetWorkerAnnotations
  , targetWorkerContainerName
  , targetWorkerPodDeleteOptions
  )
import Prodbox.ControlPlane.TargetSecretWorkerProtocol
  ( targetWorkerIngressMaximumBytes
  )
import Prodbox.ControlPlane.TargetWorkerExecutionPermit
  ( targetWorkerSessionAttemptId
  , targetWorkerSessionOperationId
  )
import Prodbox.ControlPlane.VaultAccessorAudit
  ( VaultAccessorAuditOps (..)
  , VaultAccessorSubject (..)
  )
import Prodbox.ControlPlane.VaultServiceSessionJournal
  ( vaultServiceSessionJournalRepository
  )
import Prodbox.Error (errorMsg)
import Prodbox.Observation.AbsenceMarker
  ( AbsenceProbe (..)
  , reportsAbsence
  )
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , FramedSubprocessExchangeError (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  , captureSubprocessFramedExchangeBounded
  , captureSubprocessWithInputBounded
  )
import Prodbox.Vault.Client
  ( VaultAddress
  , VaultToken
  , tokenAccessorKeys
  , vaultListTokenAccessors
  , vaultLookupTokenAccessorInfo
  , vaultRevokeTokenAccessor
  , vaultTokenAccessorAbsent
  )
import System.Exit (ExitCode (..))
import Text.Read (readMaybe)

data TargetWorkerJobConnection = TargetWorkerJobConnection
  { targetWorkerJobEnvironment :: !(Maybe [(String, String)])
  , targetWorkerJobWorkingDirectory :: !FilePath
  , targetWorkerJobImageRepository :: !Text
  , targetWorkerJobMaximumRuntimeSeconds :: !Natural
  }
  deriving stock (Eq, Show)

targetWorkerCreateSubprocess :: TargetWorkerJobConnection -> Subprocess
targetWorkerCreateSubprocess connection =
  kubectl connection ["create", "--filename=-", "--output=json"]

targetWorkerObserveSubprocess
  :: TargetWorkerJobConnection -> TargetWorkerIntent -> Subprocess
targetWorkerObserveSubprocess connection intent =
  kubectl
    connection
    [ "get"
    , "pods"
    , "--selector=job-name=" <> Text.unpack (targetWorkerIntentJobName intent)
    , "--output=json"
    ]

targetWorkerObserveAgentSubprocess :: TargetWorkerJobConnection -> Subprocess
targetWorkerObserveAgentSubprocess connection =
  kubectl connection ["get", "deployment/target-secret-agent", "--output=json"]

targetWorkerAttachSubprocess
  :: TargetWorkerJobConnection -> TargetWorkerAttestation -> Subprocess
targetWorkerAttachSubprocess connection attestation =
  kubectl
    connection
    [ "attach"
    , "--pod-running-timeout=10s"
    , "-i"
    , "pod/" <> Text.unpack (targetWorkerAttestedPodName attestation)
    , "--container"
    , Text.unpack targetWorkerContainerName
    ]

targetWorkerKubernetesBoundary
  :: TargetWorkerJobConnection -> TargetWorkerKubernetesBoundary IO
targetWorkerKubernetesBoundary connection =
  TargetWorkerKubernetesBoundary
    { observeSelectedTargetAgentRollout = observeAgentIdentity
    , createTargetWorkerIntent = createIntent
    , recoverTargetWorkerIntent = recoverIntent
    , observeTargetWorkerIntent = observeIntent
    , attachTargetWorkerIngress = attachIngress
    , deleteTargetWorkerIntent = deleteIntent
    , observeTargetWorkerIntentAbsent = observeAbsent
    }
 where
  observeAgentIdentity = do
    attempted <-
      captureSubprocessBounded
        observeLimits
        (targetWorkerObserveAgentSubprocess connection)
    pure $ case attempted of
      Left err -> Left (bounded (errorMsg err))
      Right output -> case processExitCode output of
        ExitFailure _ -> Left "selected Target Agent Deployment is not observable"
        ExitSuccess ->
          parseTargetAgentRolloutObservation
            (ByteString8.pack (processStdout output))

  createIntent intent = case renderTargetSecretWorkerJob
    (targetWorkerJobImageRepository connection)
    (targetWorkerJobMaximumRuntimeSeconds connection)
    intent of
    Left detail -> pure (Left detail)
    Right jobManifest -> createManifest intent jobManifest

  createManifest intent manifest = do
    attempted <-
      captureSubprocessWithInputBounded
        createLimits
        (LazyByteString.toStrict (encode manifest))
        (targetWorkerCreateSubprocess connection)
    case attempted of
      Left _ -> pure (Left "Target worker Job create response is unavailable")
      Right output -> case processExitCode output of
        ExitSuccess ->
          pure
            (parseJobBinding intent (ByteString8.pack (processStdout output)))
        ExitFailure _
          | isAlreadyExists output -> do
              observed <- observeJob intent
              pure $ case observed of
                Right (Just jobUid) -> Right jobUid
                Right Nothing -> Left "Target worker Job already exists but is not yet visible"
                Left detail -> Left detail
          | otherwise -> pure (Left "Target worker Job creation failed")

  recoverIntent intent =
    recoverTargetWorkerCreateWith
      createRecoveryAttempts
      (threadDelay createVisibilityGraceMicros)
      (threadDelay observationDelayMicros)
      (observeJob intent)

  observeJob intent = do
    attempted <-
      captureSubprocessBounded
        observeLimits
        (kubectl connection ["get", "--raw=" <> jobRawPath intent])
    pure $ case attempted of
      Left err -> Left (bounded (errorMsg err))
      Right output -> case processExitCode output of
        ExitFailure _
          | isNotFound output -> Right Nothing
          | otherwise -> Left "Target worker Job is not observable"
        ExitSuccess ->
          Just <$> parseJobBinding intent (ByteString8.pack (processStdout output))

  observeIntent intent = waitForObservation observationAttempts
   where
    waitForObservation remaining = do
      result <- observePodsOnce connection intent
      case result of
        Right (Just observed) -> pure (Right (Just observed))
        Right Nothing
          | remaining <= 1 -> pure (Right Nothing)
          | otherwise -> threadDelay observationDelayMicros >> waitForObservation (remaining - 1)
        Left detail
          | remaining <= 1 -> pure (Left detail)
          | otherwise -> threadDelay observationDelayMicros >> waitForObservation (remaining - 1)

  attachIngress attestation frame decide = do
    attempted <-
      captureSubprocessFramedExchangeBounded
        attachLimits
        frame
        ( \provisional ->
            fmap
              (fmap (targetWorkerCleanupAuthorization,))
              (decide provisional)
        )
        (targetWorkerAttachSubprocess connection attestation)
    pure $ case attempted of
      Left (FramedSubprocessExchangeTransportError _) ->
        Left (TargetWorkerCoordinatorAttachFailed "Target worker attach transport failed")
      Left (FramedSubprocessExchangeDecisionError err output)
        | cleanupCompletionObserved output && processFailed output -> Left err
        | otherwise ->
            Left
              ( TargetWorkerCoordinatorAttachFailed
                  "Target worker cleanup acknowledgement is invalid"
              )
      Right (outcome, output)
        | not (cleanupCompletionObserved output) ->
            Left
              ( TargetWorkerCoordinatorAttachFailed
                  "Target worker cleanup acknowledgement is invalid"
              )
        | targetWorkerOutcomeExitMatches outcome (processExitCode output) -> Right outcome
        | otherwise ->
            Left
              ( TargetWorkerCoordinatorAttachFailed
                  "Target worker terminal status is inconsistent"
              )

  deleteIntent intent jobUid maybePod = do
    jobResult <-
      deleteRaw
        connection
        (jobRawPath intent)
        (targetWorkerJobUidText jobUid)
        (jobDeleteOptions jobUid)
    podResult <- case maybePod of
      Nothing -> pure (Right ())
      Just (podName, podUid) ->
        deleteRaw
          connection
          (podRawPath podName)
          (targetWorkerPodUidText podUid)
          (targetWorkerPodDeleteOptions podUid)
    pure $ case (jobResult, podResult) of
      (Right (), Right ()) -> Right ()
      (Left firstError, Right ()) -> Left firstError
      (Right (), Left secondError) -> Left secondError
      (Left firstError, Left secondError) ->
        Left (bounded (firstError <> "; " <> secondError))

  observeAbsent intent jobUid maybePod =
    waitForAbsence absenceAttempts
   where
    waitForAbsence remaining = do
      job <- observeExactUid connection (jobRawPath intent) (targetWorkerJobUidText jobUid)
      pod <- case maybePod of
        Nothing -> pure (Right True)
        Just (podName, podUid) ->
          observeExactUid connection (podRawPath podName) (targetWorkerPodUidText podUid)
      let result = (&&) <$> job <*> pod
      case result of
        Right True -> pure (Right True)
        Right False
          | remaining <= 1 -> pure (Right False)
          | otherwise -> threadDelay observationDelayMicros >> waitForAbsence (remaining - 1)
        Left detail
          | remaining <= 1 -> pure (Left detail)
          | otherwise -> threadDelay observationDelayMicros >> waitForAbsence (remaining - 1)

data JobDto = JobDto
  { jobDtoName :: !Text
  , jobDtoUid :: !Text
  , jobDtoAnnotations :: !(Map Text Text)
  , jobDtoTemplateAnnotations :: !(Map Text Text)
  , jobDtoServiceAccount :: !Text
  , jobDtoContainers :: ![ContainerDto]
  }

instance FromJSON JobDto where
  parseJSON = withObject "TargetWorkerJob" $ \value -> do
    metadata <- value .: "metadata"
    spec <- value .: "spec"
    template <- spec .: "template"
    templateMetadata <- template .: "metadata"
    templateSpec <- template .: "spec"
    JobDto
      <$> metadata .: "name"
      <*> metadata .: "uid"
      <*> metadata .:? "annotations" .!= Map.empty
      <*> templateMetadata .:? "annotations" .!= Map.empty
      <*> templateSpec .: "serviceAccountName"
      <*> templateSpec .: "containers"

parseJobBinding
  :: TargetWorkerIntent -> ByteString -> Either Text TargetWorkerJobUid
parseJobBinding intent bytes = do
  job <- case eitherDecodeStrict' bytes of
    Left _ -> Left "Kubernetes Target worker Job response is invalid"
    Right value -> Right value
  unless
    (jobDtoName job == targetWorkerIntentJobName intent)
    (Left "Target worker Job name mismatch")
  let expectedAnnotations = targetWorkerAnnotations intent
  unless
    ( annotationsContain expectedAnnotations (jobDtoAnnotations job)
        && annotationsContain expectedAnnotations (jobDtoTemplateAnnotations job)
    )
    (Left "Target worker Job intent annotations mismatch")
  unless
    (jobDtoServiceAccount job == targetWorkerIntentServiceAccount intent)
    (Left "Target worker Job ServiceAccount mismatch")
  imageReference <- case findContainer targetWorkerContainerName (jobDtoContainers job) of
    Nothing -> Left "Target worker Job container is missing"
    Just (ContainerDto _ reference) -> Right reference
  unless
    ( imageSuffix imageReference
        == Just (targetWorkerImageDigestText (targetWorkerIntentImageDigest intent))
    )
    (Left "Target worker Job immutable image mismatch")
  firstText "Target worker Job UID is invalid" (mkTargetWorkerJobUid (jobDtoUid job))
 where
  annotationsContain expected actual =
    all (\(name, value) -> Map.lookup name actual == Just value) (Map.toList expected)

data PodListDto = PodListDto ![PodDto]

instance FromJSON PodListDto where
  parseJSON = withObject "TargetWorkerPodList" $ \value ->
    PodListDto <$> value .: "items"

data PodDto = PodDto
  { podDtoName :: !Text
  , podDtoUid :: !Text
  , podDtoLabels :: !(Map Text Text)
  , podDtoAnnotations :: !(Map Text Text)
  , podDtoOwners :: ![OwnerDto]
  , podDtoDeletionTimestamp :: !(Maybe Text)
  , podDtoServiceAccount :: !Text
  , podDtoContainers :: ![ContainerDto]
  , podDtoPhase :: !Text
  , podDtoContainerStatuses :: ![ContainerStatusDto]
  }

instance FromJSON PodDto where
  parseJSON = withObject "TargetWorkerPod" $ \value -> do
    metadata <- value .: "metadata"
    spec <- value .: "spec"
    status <- value .: "status"
    PodDto
      <$> metadata .: "name"
      <*> metadata .: "uid"
      <*> metadata .:? "labels" .!= Map.empty
      <*> metadata .:? "annotations" .!= Map.empty
      <*> metadata .:? "ownerReferences" .!= []
      <*> metadata .:? "deletionTimestamp"
      <*> spec .: "serviceAccountName"
      <*> spec .: "containers"
      <*> status .:? "phase" .!= ""
      <*> status .:? "containerStatuses" .!= []

data OwnerDto = OwnerDto !Text !Text !Text !Bool

instance FromJSON OwnerDto where
  parseJSON = withObject "TargetWorkerOwner" $ \value ->
    OwnerDto
      <$> value .: "kind"
      <*> value .: "name"
      <*> value .: "uid"
      <*> value .:? "controller" .!= False

data ContainerDto = ContainerDto !Text !Text

instance FromJSON ContainerDto where
  parseJSON = withObject "TargetWorkerContainer" $ \value ->
    ContainerDto <$> value .: "name" <*> value .: "image"

data ContainerStatusDto = ContainerStatusDto !Text !Bool !Natural

instance FromJSON ContainerStatusDto where
  parseJSON = withObject "TargetWorkerContainerStatus" $ \value ->
    ContainerStatusDto
      <$> value .: "name"
      <*> value .:? "ready" .!= False
      <*> value .:? "restartCount" .!= 0

data ObjectUidDto = ObjectUidDto !Text

instance FromJSON ObjectUidDto where
  parseJSON = withObject "TargetWorkerObject" $ \value -> do
    metadata <- value .: "metadata"
    ObjectUidDto <$> metadata .: "uid"

data ServiceAccountDto = ServiceAccountDto !Text !Text !Text

instance FromJSON ServiceAccountDto where
  parseJSON = withObject "TargetWorkerServiceAccount" $ \value -> do
    metadata <- value .: "metadata"
    ServiceAccountDto
      <$> metadata .: "name"
      <*> metadata .: "namespace"
      <*> metadata .: "uid"

data DeploymentIdentityDto
  = DeploymentIdentityDto
      !Text
      !Text
      !Natural
      !Natural
      !(Map Text Text)
      !(Map Text Text)

instance FromJSON DeploymentIdentityDto where
  parseJSON = withObject "TargetAgentDeployment" $ \value -> do
    metadata <- value .: "metadata"
    spec <- value .: "spec"
    template <- spec .: "template"
    templateMetadata <- template .: "metadata"
    status <- value .: "status"
    DeploymentIdentityDto
      <$> metadata .: "name"
      <*> metadata .: "uid"
      <*> metadata .: "generation"
      <*> status .:? "observedGeneration" .!= 0
      <*> metadata .:? "annotations" .!= Map.empty
      <*> templateMetadata .:? "annotations" .!= Map.empty

-- | Decode one independently read Kubernetes Deployment observation into the
-- exact Authority-registered rollout incarnation.  Both the Deployment and
-- Pod-template annotations must agree, and status must have observed the
-- current desired generation; a selected-cluster name alone is insufficient.
parseTargetAgentRolloutObservation
  :: ByteString -> Either Text TargetAgentRolloutEvidence
parseTargetAgentRolloutObservation bytes = do
  DeploymentIdentityDto name uid generation observedGeneration annotations templateAnnotations <-
    firstText
      "Kubernetes Target Agent Deployment response is invalid"
      (eitherDecodeStrict' bytes)
  unless
    (name == "target-secret-agent")
    (Left "selected Target Agent Deployment name is invalid")
  identity <-
    maybe
      (Left "selected Target Agent Deployment identity is absent")
      Right
      (Map.lookup targetAgentIdentityAnnotation annotations)
  templateIdentity <-
    maybe
      (Left "selected Target Agent Pod-template identity is absent")
      Right
      (Map.lookup targetAgentIdentityAnnotation templateAnnotations)
  unless
    (templateIdentity == identity)
    (Left "selected Target Agent Deployment identity is inconsistent")
  rollout <-
    maybe
      (Left "selected Target Agent Deployment rollout digest is absent")
      Right
      (Map.lookup targetAgentRolloutAnnotation annotations)
  templateRollout <-
    maybe
      (Left "selected Target Agent Pod-template rollout digest is absent")
      Right
      (Map.lookup targetAgentRolloutAnnotation templateAnnotations)
  unless
    (templateRollout == rollout)
    (Left "selected Target Agent Deployment rollout digest is inconsistent")
  parsedIdentity <- mkTargetAgentIdentity identity
  mkTargetAgentRolloutEvidence
    parsedIdentity
    uid
    generation
    observedGeneration
    rollout

observePodsOnce
  :: TargetWorkerJobConnection
  -> TargetWorkerIntent
  -> IO (Either Text (Maybe RawTargetWorkerPodObservation))
observePodsOnce connection intent = do
  attempted <-
    captureSubprocessBounded
      observeLimits
      (targetWorkerObserveSubprocess connection intent)
  case attempted of
    Left err -> pure (Left (bounded (errorMsg err)))
    Right output -> case processExitCode output of
      ExitFailure _ -> pure (Left "Target worker Job Pod is not observable")
      ExitSuccess -> case parsePodListForIntent (ByteString8.pack (processStdout output)) of
        Left detail -> pure (Left detail)
        Right Nothing -> pure (Right Nothing)
        Right (Just pod) -> do
          serviceAccountUid <- observeServiceAccountUid connection intent
          pure $ Just <$> (serviceAccountUid >>= \uid -> podObservation intent uid pod)

parsePodListForIntent
  :: ByteString
  -> Either Text (Maybe PodDto)
parsePodListForIntent bytes = do
  pods <- case eitherDecodeStrict' bytes of
    Left _ -> Left "Kubernetes Target worker Pod-list response is invalid"
    Right (PodListDto decoded) -> Right decoded
  case pods of
    [] -> Right Nothing
    [pod] -> Right (Just pod)
    _ -> Left "Target worker Job has multiple Pods"

podObservation
  :: TargetWorkerIntent
  -> TargetWorkerServiceAccountUid
  -> PodDto
  -> Either Text RawTargetWorkerPodObservation
podObservation intent serviceAccountUid pod = do
  let jobName = targetWorkerIntentJobName intent
  unless
    (Map.lookup "job-name" (podDtoLabels pod) == Just jobName)
    (Left "Target worker Pod Job label mismatch")
  jobUid <- case filter controllingJob (podDtoOwners pod) of
    [OwnerDto _ _ uid _] -> Right uid
    _ -> Left "Target worker Pod has no unique controlling Job UID"
  imageReference <- case findContainer targetWorkerContainerName (podDtoContainers pod) of
    Nothing -> Left "Target worker container is missing"
    Just (ContainerDto _ reference) -> Right reference
  imageDigest <-
    maybe
      (Left "Target worker container image is not immutable")
      Right
      (imageSuffix imageReference)
  let expectedDigest = targetWorkerImageDigestText (targetWorkerIntentImageDigest intent)
  unless (imageDigest == expectedDigest) (Left "Target worker image digest mismatch")
  traverse_ (requireAnnotation pod) (Map.toList (targetWorkerAnnotations intent))
  let (ready, restarts) = case findStatus targetWorkerContainerName (podDtoContainerStatuses pod) of
        Nothing -> (False, 0)
        Just (ContainerStatusDto _ isReady count) -> (isReady, count)
  pure
    RawTargetWorkerPodObservation
      { observedTargetWorkerJobName = jobName
      , observedTargetWorkerJobUid = jobUid
      , observedTargetWorkerPodName = podDtoName pod
      , observedTargetWorkerPodUid = podDtoUid pod
      , observedTargetWorkerImageDigest = imageDigest
      , observedTargetWorkerServiceAccount = podDtoServiceAccount pod
      , observedTargetWorkerServiceAccountUid =
          targetWorkerServiceAccountUidText serviceAccountUid
      , observedTargetWorkerTarget = annotationValue "target.prodbox.dev/target"
      , observedTargetWorkerAgentIdentity =
          annotationValue "target.prodbox.dev/agent-identity"
      , observedTargetWorkerSchema = annotationValue "target.prodbox.dev/material-schema"
      , observedTargetWorkerRequestDigest = annotationValue "target.prodbox.dev/request-digest"
      , observedTargetWorkerDeadlineMicros = deadlineMicros
      , observedTargetWorkerPhase = podDtoPhase pod
      , observedTargetWorkerReady = ready
      , observedTargetWorkerRestartCount = restarts
      , observedTargetWorkerDeletionTimestamp = podDtoDeletionTimestamp pod
      }
 where
  controllingJob (OwnerDto kind name _ controller) =
    kind == "Job" && name == targetWorkerIntentJobName intent && controller
  annotationValue name = Map.findWithDefault "" name (podDtoAnnotations pod)
  deadlineMicros =
    maybe
      0
      id
      (readMaybe (Text.unpack (annotationValue "target.prodbox.dev/deadline-micros")))

-- | Exact retained session-attempt interpreter used by the standing Target
-- Agent after it has independently observed and attested a one-shot Job/Pod.
-- Allocation and preparation durably advance the role lane through
-- @LoginAttemptCommitted@ before the Authority permit can be requested and
-- before stdin can be attached.  The terminal callback performs role-wide
-- cleanup (deliberately omitting a ServiceAccount UID so a replaced static
-- ServiceAccount cannot strand its predecessor) and releases the same fence.
targetWorkerRetainedExecutionBoundary
  :: ServiceSessionJournalRepository IO revision
  -> VaultAccessorAuditOps IO
  -> TargetIntentAuthorityClient IO
  -> TargetWorkerExecutionBoundary IO
targetWorkerRetainedExecutionBoundary repository auditOps authorityClient =
  TargetWorkerExecutionBoundary
    { prepareTargetWorkerSessionAttempt = \rollout attestation -> do
        allocated <-
          allocateNextServiceSessionBinding
            repository
            targetSecretWorkerVaultRole
            ( targetWorkerSessionOperationId
                (targetWorkerAttestedIntent attestation)
            )
            (targetWorkerSessionAttemptId rollout attestation)
        case allocated of
          Left err -> pure (Left (boundedShow err))
          Right binding -> do
            prepared <-
              prepareFencedServiceSessionDispatch
                repository
                auditOps
                targetWorkerRoleWideAccessorSubject
                binding
            pure $ case prepared of
              Left err -> Left (boundedShow err)
              Right () -> Right binding
    , authorizeTargetWorkerExecution = \_ rollout attestation binding ->
        fmap
          (either (Left . boundedShow) Right)
          ( requestTargetWorkerExecutionPermit
              authorityClient
              rollout
              attestation
              binding
          )
    , activateTargetWorkerSessionAttempt = \attestation binding accessor ->
        fmap
          (either (Left . boundedShow) Right)
          ( activateFencedServiceSessionDispatch
              repository
              auditOps
              (targetWorkerActiveAccessorSubject attestation)
              binding
              accessor
          )
    , closeTargetWorkerSessionAttempt = \binding ->
        fmap
          (either (Left . boundedShow) Right)
          ( closeFencedServiceSessionDispatch
              repository
              auditOps
              targetWorkerRoleWideAccessorSubject
              binding
          )
    }

-- | Production retained-Vault specialization.  The repository key is fixed
-- to the one Target-worker role lane; callers cannot substitute an arbitrary
-- journal path while preserving this boundary type.
vaultTargetWorkerRetainedExecutionBoundary
  :: VaultAddress
  -> VaultToken
  -> VaultAccessorAuditOps IO
  -> TargetIntentAuthorityClient IO
  -> TargetWorkerExecutionBoundary IO
vaultTargetWorkerRetainedExecutionBoundary address token =
  targetWorkerRetainedExecutionBoundary
    ( vaultServiceSessionJournalRepository
        address
        token
        targetSecretWorkerVaultRole
    )

-- | Accessor administration backed by one validated, accessor-free batch
-- token acquired by the standing Target coordinator. The token can inspect
-- and revoke worker service-token accessors but has no Target material policy.
targetWorkerControllerAuditOps
  :: VaultAddress
  -> VaultToken
  -> VaultAccessorAuditOps IO
targetWorkerControllerAuditOps address token =
  VaultAccessorAuditOps
    { auditListAccessors =
        first (const "accessor inventory unavailable") . fmap tokenAccessorKeys
          <$> vaultListTokenAccessors address token
    , auditLookupAccessor = \accessor ->
        first (const "accessor classification unavailable")
          <$> vaultLookupTokenAccessorInfo address token accessor
    , auditRevokeAccessor = \accessor ->
        first (const "accessor revocation unavailable")
          <$> vaultRevokeTokenAccessor address token accessor
    , auditObserveAccessorAbsent = \accessor ->
        first (const "accessor absence unavailable")
          <$> vaultTokenAccessorAbsent address token accessor
    , auditWaitVisibilityGrace =
        threadDelay controllerAccessorVisibilityGraceMicros >> pure (Right ())
    }

controllerAccessorVisibilityGraceMicros :: Int
controllerAccessorVisibilityGraceMicros = 250000

-- | Recovery classification intentionally spans every incarnation of the
-- static Target worker ServiceAccount.  The per-incarnation UID remains bound
-- in the signed execution permit and worker-side active-session proof; it is
-- excluded only from predecessor cleanup so UID rollover converges.
targetWorkerRoleWideAccessorSubject :: VaultAccessorSubject
targetWorkerRoleWideAccessorSubject =
  VaultAccessorSubject
    { vaultAccessorSubjectPolicies = ["default", targetSecretWorkerVaultRole]
    , vaultAccessorSubjectMetadata =
        Map.fromList
          [ ("role", targetSecretWorkerVaultRole)
          , ("service_account_name", targetSecretWorkerVaultRole)
          , ("service_account_namespace", Text.pack targetWorkerNamespace)
          ]
    , vaultAccessorSubjectCreationPath = "auth/kubernetes/login"
    }

-- | Exact active-session classifier.  Unlike role-wide predecessor cleanup,
-- the login that unlocks a worker cleanup acknowledgement must belong to the
-- API-observed ServiceAccount incarnation bound into the Authority permit.
targetWorkerActiveAccessorSubject
  :: TargetWorkerAttestation -> VaultAccessorSubject
targetWorkerActiveAccessorSubject attestation =
  targetWorkerRoleWideAccessorSubject
    { vaultAccessorSubjectMetadata =
        Map.insert
          "service_account_uid"
          ( targetWorkerServiceAccountUidText
              (targetWorkerAttestedServiceAccountUid attestation)
          )
          (vaultAccessorSubjectMetadata targetWorkerRoleWideAccessorSubject)
    }

requireAnnotation :: PodDto -> (Text, Text) -> Either Text ()
requireAnnotation pod (name, expected) =
  unless
    (Map.lookup name (podDtoAnnotations pod) == Just expected)
    (Left ("Target worker Pod annotation mismatch: " <> name))

targetAgentIdentityAnnotation :: Text
targetAgentIdentityAnnotation = "prodbox.io/target-agent-identity"

targetAgentRolloutAnnotation :: Text
targetAgentRolloutAnnotation = "prodbox.io/target-agent-rollout-digest"

firstText :: Text -> Either errorValue value -> Either Text value
firstText detail = either (const (Left detail)) Right

findContainer :: Text -> [ContainerDto] -> Maybe ContainerDto
findContainer name = find (\(ContainerDto actual _) -> actual == name)

findStatus :: Text -> [ContainerStatusDto] -> Maybe ContainerStatusDto
findStatus name = find (\(ContainerStatusDto actual _ _) -> actual == name)

imageSuffix :: Text -> Maybe Text
imageSuffix reference = case Text.breakOnEnd "@" reference of
  (prefix, digest)
    | not (Text.null prefix) && Text.isPrefixOf "sha256:" digest -> Just digest
  _ -> Nothing

deleteRaw
  :: TargetWorkerJobConnection
  -> String
  -> Text
  -> Value
  -> IO (Either Text ())
deleteRaw connection rawPath uid deleteOptions
  | Text.null uid = pure (Left "Target worker cleanup UID is empty")
  | otherwise = do
      attempted <-
        captureSubprocessWithInputBounded
          deleteLimits
          (LazyByteString.toStrict (encode deleteOptions))
          (kubectl connection ["delete", "--raw=" <> rawPath, "--filename=-"])
      pure $ case attempted of
        Left err -> Left (bounded (errorMsg err))
        Right output -> case processExitCode output of
          ExitSuccess -> Right ()
          ExitFailure _
            | isNotFound output -> Right ()
            | otherwise -> Left "UID-preconditioned Target worker deletion failed"

observeExactUid
  :: TargetWorkerJobConnection -> String -> Text -> IO (Either Text Bool)
observeExactUid connection rawPath expectedUid = do
  attempted <-
    captureSubprocessBounded
      observeLimits
      (kubectl connection ["get", "--raw=" <> rawPath])
  pure $ case attempted of
    Left err -> Left (bounded (errorMsg err))
    Right output -> case processExitCode output of
      ExitFailure _
        | isNotFound output -> Right True
        | otherwise -> Left "Target worker absence is unobservable"
      ExitSuccess -> case eitherDecodeStrict' (ByteString8.pack (processStdout output)) of
        Left _ -> Left "Kubernetes Target worker object response is invalid"
        Right (ObjectUidDto currentUid) -> Right (currentUid /= expectedUid)

jobDeleteOptions :: TargetWorkerJobUid -> Value
jobDeleteOptions jobUid =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("DeleteOptions" :: Text)
    , "gracePeriodSeconds" .= (0 :: Natural)
    , "propagationPolicy" .= ("Background" :: Text)
    , "preconditions" .= object ["uid" .= targetWorkerJobUidText jobUid]
    ]

jobRawPath :: TargetWorkerIntent -> String
jobRawPath intent =
  "/apis/batch/v1/namespaces/"
    <> targetWorkerNamespace
    <> "/jobs/"
    <> Text.unpack (targetWorkerIntentJobName intent)

podRawPath :: Text -> String
podRawPath podName =
  "/api/v1/namespaces/"
    <> targetWorkerNamespace
    <> "/pods/"
    <> Text.unpack podName

serviceAccountRawPath :: TargetWorkerIntent -> String
serviceAccountRawPath intent =
  "/api/v1/namespaces/"
    <> targetWorkerNamespace
    <> "/serviceaccounts/"
    <> Text.unpack (targetWorkerIntentServiceAccount intent)

observeServiceAccountUid
  :: TargetWorkerJobConnection
  -> TargetWorkerIntent
  -> IO (Either Text TargetWorkerServiceAccountUid)
observeServiceAccountUid connection intent = do
  attempted <-
    captureSubprocessBounded
      observeLimits
      (kubectl connection ["get", "--raw=" <> serviceAccountRawPath intent])
  pure
    ( classifyTargetWorkerServiceAccountObservation
        intent
        (either (Left . bounded . errorMsg) Right attempted)
    )

-- | Classify the exact GET response before any attestation can be built.
-- Transport/process failure is never collapsed into an absent or placeholder
-- UID, and a list response cannot stand in for the named object read-back.
classifyTargetWorkerServiceAccountObservation
  :: TargetWorkerIntent
  -> Either Text ProcessOutput
  -> Either Text TargetWorkerServiceAccountUid
classifyTargetWorkerServiceAccountObservation intent attempted = case attempted of
  Left detail -> Left (bounded detail)
  Right output -> case processExitCode output of
    ExitFailure _ -> Left "Target worker ServiceAccount is not observable"
    ExitSuccess ->
      parseTargetWorkerServiceAccountObservation
        intent
        (ByteString8.pack (processStdout output))

-- | Parse one authoritative named ServiceAccount GET.  Name and namespace are
-- checked alongside the API-assigned UID, so a foreign object, list response,
-- missing field, or invalid UID cannot reach the Authority permit request.
parseTargetWorkerServiceAccountObservation
  :: TargetWorkerIntent
  -> ByteString
  -> Either Text TargetWorkerServiceAccountUid
parseTargetWorkerServiceAccountObservation intent bytes = do
  ServiceAccountDto name namespace uid <-
    firstText
      "Kubernetes Target worker ServiceAccount response is invalid"
      (eitherDecodeStrict' bytes)
  unless
    (name == targetWorkerIntentServiceAccount intent)
    (Left "Target worker ServiceAccount name mismatch")
  unless
    (namespace == Text.pack targetWorkerNamespace)
    (Left "Target worker ServiceAccount namespace mismatch")
  firstText
    "Target worker ServiceAccount UID is invalid"
    (mkTargetWorkerServiceAccountUid uid)

cleanupCompletionObserved :: ProcessOutput -> Bool
cleanupCompletionObserved output =
  ByteString8.pack (processStdout output) == targetWorkerCleanupCompletion

processFailed :: ProcessOutput -> Bool
processFailed output = case processExitCode output of
  ExitFailure _ -> True
  ExitSuccess -> False

targetWorkerOutcomeExitMatches
  :: TargetWorkerProvisionalOutcome -> ExitCode -> Bool
targetWorkerOutcomeExitMatches outcome exitCode = case (outcome, exitCode) of
  (TargetWorkerProvisionalSucceeded _, ExitSuccess) -> True
  (TargetWorkerProvisionalRefused _, ExitFailure _) -> True
  _ -> False

-- | Resolve an ambiguous create without treating the first @NotFound@ as
-- absence.  The two absence observations straddle the caller-supplied API
-- visibility grace.  Transient observation failures consume the separately
-- bounded retry budget; they can never manufacture stable absence.
recoverTargetWorkerCreateWith
  :: (Monad m)
  => Int
  -> m ()
  -> m ()
  -> m (Either Text (Maybe TargetWorkerJobUid))
  -> m (Either Text TargetWorkerCreateRecovery)
recoverTargetWorkerCreateWith maximumAttempts waitVisibilityGrace waitRetry observe =
  seekCreate maximumAttempts
 where
  seekCreate remaining
    | remaining <= 0 =
        pure (Left "Target worker Job absence could not be proven stable")
    | otherwise = do
        observed <- observe
        case observed of
          Right (Just jobUid) ->
            pure (Right (TargetWorkerCreateRecovered jobUid))
          Right Nothing
            | remaining <= 1 ->
                pure (Left "Target worker Job absence could not be proven stable")
            | otherwise -> do
                waitVisibilityGrace
                confirmAbsent (remaining - 1)
          Left detail
            | remaining <= 1 -> pure (Left detail)
            | otherwise -> waitRetry >> seekCreate (remaining - 1)

  confirmAbsent remaining = do
    observed <- observe
    case observed of
      Right (Just jobUid) ->
        pure (Right (TargetWorkerCreateRecovered jobUid))
      Right Nothing -> pure (Right TargetWorkerCreateStablyAbsent)
      Left detail
        | remaining <= 1 -> pure (Left detail)
        | otherwise -> waitRetry >> seekCreate (remaining - 1)

kubectl :: TargetWorkerJobConnection -> [String] -> Subprocess
kubectl connection arguments =
  Subprocess
    { subprocessPath = "kubectl"
    , subprocessArguments = ["--namespace", targetWorkerNamespace] <> arguments
    , subprocessEnvironment = targetWorkerJobEnvironment connection
    , subprocessWorkingDirectory = Just (targetWorkerJobWorkingDirectory connection)
    }

isAlreadyExists :: ProcessOutput -> Bool
isAlreadyExists output =
  let combined = Text.pack (processStdout output <> processStderr output)
   in "AlreadyExists" `Text.isInfixOf` combined
        || "already exists" `Text.isInfixOf` Text.toLower combined

-- | Sprint 4.78: keyed through the one owner, and scoped to __stderr__.
-- It used to match against @stdout <> stderr@, so a kubectl command that
-- succeeded and printed an object whose own content contained @not found@ —
-- a ConfigMap value, a container log line, a condition message — was read as
-- the object being absent.
isNotFound :: ProcessOutput -> Bool
isNotFound output = reportsAbsence KubernetesObjectProbe (processStderr output)

bounded :: Text -> Text
bounded = Text.take 256

boundedShow :: (Show value) => value -> Text
boundedShow = bounded . Text.pack . show

targetWorkerNamespace :: String
targetWorkerNamespace = "target-secret-agent"

observationAttempts :: Int
observationAttempts = 240

createRecoveryAttempts :: Int
createRecoveryAttempts = 8

absenceAttempts :: Int
absenceAttempts = 240

observationDelayMicros :: Int
observationDelayMicros = 250000

createVisibilityGraceMicros :: Int
createVisibilityGraceMicros = 1000000

createLimits :: BoundedSubprocessLimits
createLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 256 * 1024
    , boundedSubprocessMaximumStdoutBytes = 64 * 1024
    , boundedSubprocessMaximumStderrBytes = 16 * 1024
    , boundedSubprocessTimeoutMicros = 30 * 1000 * 1000
    }

observeLimits :: BoundedSubprocessLimits
observeLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = 256 * 1024
    , boundedSubprocessMaximumStderrBytes = 16 * 1024
    , boundedSubprocessTimeoutMicros = 10 * 1000 * 1000
    }

attachLimits :: BoundedSubprocessLimits
attachLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = targetWorkerIngressMaximumBytes + 4096
    , boundedSubprocessMaximumStdoutBytes =
        targetWorkerProvisionalCompletionMaximumBytes + 4096
    , boundedSubprocessMaximumStderrBytes = 16 * 1024
    , boundedSubprocessTimeoutMicros = 10 * 60 * 1000 * 1000
    }

deleteLimits :: BoundedSubprocessLimits
deleteLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 16 * 1024
    , boundedSubprocessMaximumStdoutBytes = 64 * 1024
    , boundedSubprocessMaximumStderrBytes = 16 * 1024
    , boundedSubprocessTimeoutMicros = 30 * 1000 * 1000
    }
