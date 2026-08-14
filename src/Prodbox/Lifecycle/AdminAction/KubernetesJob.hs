{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Host-side Kubernetes boundary for one Admin Action Job.  The manifest is
-- secret-free.  The bounded credential frame is attached only after the
-- Authority has signed the exact observed Job UID, Pod UID/name, image,
-- ServiceAccount, operation and deadline.  Cleanup uses Kubernetes UID
-- preconditions and finishes only after positive Job and Pod absence.
module Prodbox.Lifecycle.AdminAction.KubernetesJob
  ( AdminActionJobConnection (..)
  , adminActionCreateSubprocess
  , adminActionObserveSubprocess
  , adminActionAttachSubprocess
  , adminActionKubernetesBoundary
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
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.Error (errorMsg)
import Prodbox.Lifecycle.AdminAction.Coordinator
  ( AdminActionCleanupBinding (..)
  , AdminActionKubernetesBoundary (..)
  )
import Prodbox.Lifecycle.AdminAction.Kubernetes
  ( AdminActionJobIntent
  , RawAdminActionPodObservation (..)
  , adminActionIntentCore
  , adminActionIntentHeartbeat
  , adminActionIntentJobName
  , attestAdminActionPod
  , renderAdminActionJob
  )
import Prodbox.Lifecycle.AdminAction.Protocol
  ( SignedAdminActionPermit
  , adminActionJobPodName
  , adminActionPermitAction
  , adminActionPermitDeadline
  , adminActionPermitImageDigest
  , adminActionPermitOperationId
  , adminActionRunnerServiceAccount
  , signedAdminActionPermitBinding
  )
import Prodbox.Lifecycle.Authority.AdminAction (AdminAction (..))
import Prodbox.Lifecycle.Lease (authorityTimeMicros)
import Prodbox.Observation.AbsenceMarker
  ( AbsenceProbe (..)
  , reportsAbsence
  )
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  , captureSubprocessWithInputBounded
  )
import System.Exit (ExitCode (..))
import Text.Read (readMaybe)

data AdminActionJobConnection = AdminActionJobConnection
  { adminActionJobEnvironment :: !(Maybe [(String, String)])
  , adminActionJobWorkingDirectory :: !FilePath
  }
  deriving stock (Eq, Show)

adminActionCreateSubprocess :: AdminActionJobConnection -> Subprocess
adminActionCreateSubprocess connection =
  kubectl connection ["create", "--filename=-"]

adminActionObserveSubprocess
  :: AdminActionJobConnection -> AdminActionJobIntent -> Subprocess
adminActionObserveSubprocess connection intent =
  kubectl
    connection
    [ "get"
    , "pods"
    , "--selector=job-name=" <> Text.unpack (adminActionIntentJobName intent)
    , "--output=json"
    ]

adminActionAttachSubprocess
  :: AdminActionJobConnection -> SignedAdminActionPermit -> Subprocess
adminActionAttachSubprocess connection permit =
  kubectl
    connection
    [ "attach"
    , "--pod-running-timeout=10s"
    , "-i"
    , "pod/" <> Text.unpack (adminActionJobPodName (signedAdminActionPermitBinding permit))
    , "--container"
    , Text.unpack adminActionContainerName
    ]

adminActionKubernetesBoundary
  :: AdminActionJobConnection -> AdminActionKubernetesBoundary IO
adminActionKubernetesBoundary connection =
  AdminActionKubernetesBoundary
    { createAdminActionJob = createJob
    , observeAdminActionJob = observeJob
    , attestAdminActionJob = \now intent raw ->
        pure (attestAdminActionPod now intent raw)
    , attachAdminActionIngress = attachIngress
    , deleteAdminActionJob = deleteJob
    , observeAdminActionJobAbsent = observeAbsent
    }
 where
  createJob intent = do
    attempted <-
      captureSubprocessWithInputBounded
        createLimits
        (TextEncoding.encodeUtf8 (renderAdminActionJob intent))
        (adminActionCreateSubprocess connection)
    pure $ case attempted of
      Left err -> Left (bounded (errorMsg err))
      -- Exit failure may be an exact AlreadyExists after a lost response.  A
      -- fresh Pod observation and all signed attestation fields decide it.
      Right _ -> Right ()

  observeJob intent = waitForObservation observationAttempts
   where
    waitForObservation remaining = do
      attempted <-
        captureSubprocessBounded
          observeLimits
          (adminActionObserveSubprocess connection intent)
      let result = case attempted of
            Left err -> Left (bounded (errorMsg err))
            Right output -> case processExitCode output of
              ExitFailure _ -> Left "Admin Action Job Pod is not observable"
              ExitSuccess -> parsePodListForIntent intent (ByteString8.pack (processStdout output))
      case result of
        Right (Just observed) -> do
          serviceAccountUid <- observeServiceAccountUid connection
          pure $ do
            uid <- serviceAccountUid
            Right
              ( Just
                  observed
                    { observedAdminActionServiceAccountUid = uid
                    }
              )
        Right Nothing
          | remaining <= 1 -> pure (Right Nothing)
          | otherwise -> threadDelay observationDelayMicros >> waitForObservation (remaining - 1)
        Left detail
          | remaining <= 1 -> pure (Left detail)
          | otherwise -> threadDelay observationDelayMicros >> waitForObservation (remaining - 1)

  attachIngress permit frame = do
    attempted <-
      captureSubprocessWithInputBounded
        attachLimits
        frame
        (adminActionAttachSubprocess connection permit)
    pure $ case attempted of
      Left _ -> Left "Admin Action attach transport failed"
      Right output -> case processExitCode output of
        ExitFailure _ -> Left "Admin Action worker refused"
        ExitSuccess -> Right (ByteString8.pack (processStdout output))

  deleteJob intent maybeBinding = do
    resolved <- case maybeBinding of
      Just binding -> pure (Right (Just binding))
      Nothing -> resolveJobOnlyBinding connection intent
    case resolved of
      Left detail -> pure (Left detail)
      Right Nothing -> pure (Right ())
      Right (Just binding) -> deleteExactBinding connection intent binding

  observeAbsent intent maybeBinding =
    waitForAbsence absenceAttempts
   where
    waitForAbsence remaining = do
      job <- observeJobByName connection intent
      pods <- observePodsOnce connection intent
      let result = case (job, pods) of
            (Left detail, _) -> Left detail
            (_, Left detail) -> Left detail
            (Right maybeJobUid, Right observations) ->
              Right
                ( jobBindingAbsent maybeBinding maybeJobUid
                    && podBindingAbsent maybeBinding observations
                )
      case result of
        Right True -> pure (Right True)
        Right False
          | remaining <= 1 -> pure (Right False)
          | otherwise -> threadDelay observationDelayMicros >> waitForAbsence (remaining - 1)
        Left detail
          | remaining <= 1 -> pure (Left detail)
          | otherwise -> threadDelay observationDelayMicros >> waitForAbsence (remaining - 1)

data PodListDto = PodListDto ![PodDto]

instance FromJSON PodListDto where
  parseJSON = withObject "AdminActionPodList" $ \value ->
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
  parseJSON = withObject "AdminActionPod" $ \value -> do
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
  parseJSON = withObject "AdminActionOwner" $ \value ->
    OwnerDto
      <$> value .: "kind"
      <*> value .: "name"
      <*> value .: "uid"
      <*> value .:? "controller" .!= False

data ContainerDto = ContainerDto !Text !Text

instance FromJSON ContainerDto where
  parseJSON = withObject "AdminActionContainer" $ \value ->
    ContainerDto <$> value .: "name" <*> value .: "image"

data ContainerStatusDto = ContainerStatusDto !Text !Bool !Natural

instance FromJSON ContainerStatusDto where
  parseJSON = withObject "AdminActionContainerStatus" $ \value ->
    ContainerStatusDto
      <$> value .: "name"
      <*> value .:? "ready" .!= False
      <*> value .:? "restartCount" .!= 0

data JobDto = JobDto !Text !(Map Text Text) !(Map Text Text)

instance FromJSON JobDto where
  parseJSON = withObject "AdminActionJob" $ \value -> do
    metadata <- value .: "metadata"
    JobDto
      <$> metadata .: "uid"
      <*> metadata .:? "labels" .!= Map.empty
      <*> metadata .:? "annotations" .!= Map.empty

data ObjectUidDto = ObjectUidDto !Text

instance FromJSON ObjectUidDto where
  parseJSON = withObject "AdminActionObject" $ \value -> do
    metadata <- value .: "metadata"
    ObjectUidDto <$> metadata .: "uid"

parsePodListForIntent
  :: AdminActionJobIntent
  -> ByteString
  -> Either Text (Maybe RawAdminActionPodObservation)
parsePodListForIntent intent bytes = do
  pods <- decodePodList bytes
  case pods of
    [] -> Right Nothing
    [pod] -> Just <$> podObservation intent pod
    _ -> Left "Admin Action Job has multiple Pods"

decodePodList :: ByteString -> Either Text [PodDto]
decodePodList bytes = case eitherDecodeStrict' bytes of
  Left _ -> Left "Kubernetes Pod-list response is invalid"
  Right (PodListDto pods) -> Right pods

podObservation
  :: AdminActionJobIntent -> PodDto -> Either Text RawAdminActionPodObservation
podObservation intent pod = do
  let jobName = adminActionIntentJobName intent
  unless
    (Map.lookup "job-name" (podDtoLabels pod) == Just jobName)
    (Left "Admin Action Pod Job label mismatch")
  jobUid <- case filter controllingJob (podDtoOwners pod) of
    [OwnerDto _ _ uid _] -> Right uid
    _ -> Left "Admin Action Pod has no unique controlling Job UID"
  imageReference <- case findContainer adminActionContainerName (podDtoContainers pod) of
    Nothing -> Left "Admin Action container is missing"
    Just (ContainerDto _ reference) -> Right reference
  imageDigest <-
    maybe (Left "Admin Action container image is not immutable") Right (imageSuffix imageReference)
  operationId <- annotation "prodbox.dev/operation-id"
  action <- annotation "admin.prodbox.dev/action"
  deadline <- naturalAnnotation "admin.prodbox.dev/deadline-micros"
  heartbeat <- naturalAnnotation "admin.prodbox.dev/host-heartbeat-micros"
  annotatedDigest <- annotation "admin.prodbox.dev/image-digest"
  unless (annotatedDigest == imageDigest) (Left "Admin Action image annotation mismatch")
  let (ready, restarts) = case findStatus adminActionContainerName (podDtoContainerStatuses pod) of
        Nothing -> (False, 0)
        Just (ContainerStatusDto _ isReady count) -> (isReady, count)
  pure
    RawAdminActionPodObservation
      { observedAdminActionJobName = jobName
      , observedAdminActionJobUid = jobUid
      , observedAdminActionPodName = podDtoName pod
      , observedAdminActionPodUid = podDtoUid pod
      , observedAdminActionImageDigest = imageDigest
      , observedAdminActionServiceAccount = podDtoServiceAccount pod
      , observedAdminActionServiceAccountUid = ""
      , observedAdminActionOperationId = operationId
      , observedAdminActionAction = action
      , observedAdminActionDeadlineMicros = deadline
      , observedAdminActionHeartbeatMicros = heartbeat
      , observedAdminActionPhase = podDtoPhase pod
      , observedAdminActionContainerReady = ready
      , observedAdminActionRestartCount = restarts
      , observedAdminActionDeletionTimestamp = podDtoDeletionTimestamp pod
      }
 where
  controllingJob (OwnerDto kind name _ controller) =
    kind == "Job" && name == adminActionIntentJobName intent && controller
  annotation name =
    maybe
      (Left ("Admin Action Pod annotation is missing: " <> name))
      Right
      (Map.lookup name (podDtoAnnotations pod))
  naturalAnnotation name = do
    raw <- annotation name
    maybe
      (Left ("Admin Action Pod annotation is not a natural: " <> name))
      Right
      (readMaybe (Text.unpack raw))

findContainer :: Text -> [ContainerDto] -> Maybe ContainerDto
findContainer name = find (\(ContainerDto actual _) -> actual == name)

findStatus :: Text -> [ContainerStatusDto] -> Maybe ContainerStatusDto
findStatus name = find (\(ContainerStatusDto actual _ _) -> actual == name)

imageSuffix :: Text -> Maybe Text
imageSuffix reference = case Text.breakOnEnd "@" reference of
  (prefix, digest)
    | not (Text.null prefix) && Text.isPrefixOf "sha256:" digest -> Just digest
  _ -> Nothing

resolveJobOnlyBinding
  :: AdminActionJobConnection
  -> AdminActionJobIntent
  -> IO (Either Text (Maybe AdminActionCleanupBinding))
resolveJobOnlyBinding connection intent = do
  observed <- observeJobDto connection intent
  pure $ do
    maybeJob <- observed
    case maybeJob of
      Nothing -> Right Nothing
      Just (JobDto uid labels annotations) -> do
        unless (not (Text.null (Text.strip uid))) (Left "Admin Action Job UID is empty")
        validateJobMetadata intent labels annotations
        Right
          ( Just
              AdminActionCleanupBinding
                { adminActionCleanupJobUid = uid
                , adminActionCleanupPodName = ""
                , adminActionCleanupPodUid = ""
                }
          )

validateJobMetadata
  :: AdminActionJobIntent -> Map Text Text -> Map Text Text -> Either Text ()
validateJobMetadata intent labels annotations = do
  let expectedLabels =
        Map.fromList
          [ ("app.kubernetes.io/name", "prodbox-admin-action-runner")
          , ("prodbox.dev/operation-id", adminActionPermitOperationId core)
          ]
      expectedAnnotations = annotationsForIntent intent
  unless
    ( all
        (\(name, value) -> Map.lookup name labels == Just value)
        (Map.toList expectedLabels)
        && all
          (\(name, value) -> Map.lookup name annotations == Just value)
          (Map.toList expectedAnnotations)
    )
    (Left "Admin Action Job metadata does not match the exact intent")
 where
  core = adminActionIntentCore intent

annotationsForIntent :: AdminActionJobIntent -> Map Text Text
annotationsForIntent intent =
  Map.fromList
    [ ("admin.prodbox.dev/action", actionToken (adminActionPermitAction core))
    ,
      ( "admin.prodbox.dev/deadline-micros"
      , Text.pack (show (authorityTimeMicros (adminActionPermitDeadline core)))
      )
    ,
      ( "admin.prodbox.dev/host-heartbeat-micros"
      , Text.pack (show (authorityTimeMicros (adminActionIntentHeartbeat intent)))
      )
    , ("admin.prodbox.dev/image-digest", adminActionPermitImageDigest core)
    ]
 where
  core = adminActionIntentCore intent

actionToken :: AdminAction -> Text
actionToken action = case action of
  DestroyAwsSes -> "destroy-aws-ses"
  MigrateLegacyBackend -> "migrate-legacy-backend"
  ReconcileQuota -> "reconcile-quota"

deleteExactBinding
  :: AdminActionJobConnection
  -> AdminActionJobIntent
  -> AdminActionCleanupBinding
  -> IO (Either Text ())
deleteExactBinding connection intent binding = do
  jobResult <-
    deleteRaw
      connection
      (jobRawPath intent)
      (adminActionCleanupJobUid binding)
  podResult <-
    if Text.null (adminActionCleanupPodName binding)
      then pure (Right ())
      else
        deleteRaw
          connection
          (podRawPath (adminActionCleanupPodName binding))
          (adminActionCleanupPodUid binding)
  pure $ case (jobResult, podResult) of
    (Right (), Right ()) -> Right ()
    (Left firstError, Right ()) -> Left firstError
    (Right (), Left secondError) -> Left secondError
    (Left firstError, Left secondError) -> Left (bounded (firstError <> "; " <> secondError))

deleteRaw
  :: AdminActionJobConnection -> String -> Text -> IO (Either Text ())
deleteRaw connection rawPath uid = do
  attempted <-
    captureSubprocessWithInputBounded
      deleteLimits
      (LazyByteString.toStrict (encode (uidDeleteOptions uid)))
      (kubectl connection ["delete", "--raw=" <> rawPath, "--filename=-"])
  pure $ case attempted of
    Left err -> Left (bounded (errorMsg err))
    Right output -> case processExitCode output of
      ExitSuccess -> Right ()
      ExitFailure _
        | isNotFound output -> Right ()
        | otherwise -> Left "UID-preconditioned Kubernetes deletion failed"

uidDeleteOptions :: Text -> Value
uidDeleteOptions uid =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("DeleteOptions" :: Text)
    , "gracePeriodSeconds" .= (0 :: Natural)
    , "propagationPolicy" .= ("Background" :: Text)
    , "preconditions" .= object ["uid" .= uid]
    ]

observeJobDto
  :: AdminActionJobConnection
  -> AdminActionJobIntent
  -> IO (Either Text (Maybe JobDto))
observeJobDto connection intent = do
  attempted <-
    captureSubprocessBounded
      observeLimits
      ( kubectl
          connection
          [ "get"
          , "job/" <> Text.unpack (adminActionIntentJobName intent)
          , "--output=json"
          ]
      )
  pure $ case attempted of
    Left err -> Left (bounded (errorMsg err))
    Right output -> case processExitCode output of
      ExitFailure _
        | isNotFound output -> Right Nothing
        | otherwise -> Left "Admin Action Job is unobservable"
      ExitSuccess -> case eitherDecodeStrict' (ByteString8.pack (processStdout output)) of
        Left _ -> Left "Kubernetes Job response is invalid"
        Right job -> Right (Just job)

observeJobByName
  :: AdminActionJobConnection
  -> AdminActionJobIntent
  -> IO (Either Text (Maybe Text))
observeJobByName connection intent =
  fmap (fmap (fmap (\(JobDto uid _ _) -> uid))) (observeJobDto connection intent)

observePodsOnce
  :: AdminActionJobConnection
  -> AdminActionJobIntent
  -> IO (Either Text [RawAdminActionPodObservation])
observePodsOnce connection intent = do
  attempted <-
    captureSubprocessBounded
      observeLimits
      (adminActionObserveSubprocess connection intent)
  pure $ case attempted of
    Left err -> Left (bounded (errorMsg err))
    Right output -> case processExitCode output of
      ExitFailure _ -> Left "Admin Action Pod absence is unobservable"
      ExitSuccess -> do
        pods <- decodePodList (ByteString8.pack (processStdout output))
        traverse (podObservation intent) pods

jobBindingAbsent
  :: Maybe AdminActionCleanupBinding -> Maybe Text -> Bool
jobBindingAbsent Nothing = maybe True (const False)
jobBindingAbsent (Just binding) =
  (Just (adminActionCleanupJobUid binding) /=)

podBindingAbsent
  :: Maybe AdminActionCleanupBinding -> [RawAdminActionPodObservation] -> Bool
podBindingAbsent Nothing = null
podBindingAbsent (Just binding)
  | Text.null (adminActionCleanupPodUid binding) = null
  | otherwise =
      all
        (\observed -> observedAdminActionPodUid observed /= adminActionCleanupPodUid binding)

jobRawPath :: AdminActionJobIntent -> String
jobRawPath intent =
  "/apis/batch/v1/namespaces/"
    <> adminActionNamespace
    <> "/jobs/"
    <> Text.unpack (adminActionIntentJobName intent)

podRawPath :: Text -> String
podRawPath podName =
  "/api/v1/namespaces/"
    <> adminActionNamespace
    <> "/pods/"
    <> Text.unpack podName

serviceAccountRawPath :: String
serviceAccountRawPath =
  "/api/v1/namespaces/"
    <> adminActionNamespace
    <> "/serviceaccounts/"
    <> Text.unpack adminActionRunnerServiceAccount

observeServiceAccountUid :: AdminActionJobConnection -> IO (Either Text Text)
observeServiceAccountUid connection = do
  attempted <-
    captureSubprocessBounded
      observeLimits
      (kubectl connection ["get", "--raw=" <> serviceAccountRawPath])
  pure $ case attempted of
    Left err -> Left (bounded (errorMsg err))
    Right output -> case processExitCode output of
      ExitFailure _ -> Left "Admin Action ServiceAccount is not observable"
      ExitSuccess -> case eitherDecodeStrict' (ByteString8.pack (processStdout output)) of
        Left _ -> Left "Kubernetes Admin Action ServiceAccount response is invalid"
        Right (ObjectUidDto uid)
          | Text.null (Text.strip uid) -> Left "Admin Action ServiceAccount UID is empty"
          | otherwise -> Right uid

-- | Sprint 4.78: keyed through the one owner, and scoped to __stderr__.
-- It used to match against @stdout <> stderr@, so a kubectl command that
-- succeeded and printed an object whose own content contained @not found@ —
-- a ConfigMap value, a container log line, a condition message — was read as
-- the object being absent.
isNotFound :: ProcessOutput -> Bool
isNotFound output = reportsAbsence KubernetesObjectProbe (processStderr output)

kubectl :: AdminActionJobConnection -> [String] -> Subprocess
kubectl connection arguments =
  Subprocess
    { subprocessPath = "kubectl"
    , subprocessArguments = ["--namespace", adminActionNamespace] <> arguments
    , subprocessEnvironment = adminActionJobEnvironment connection
    , subprocessWorkingDirectory = Just (adminActionJobWorkingDirectory connection)
    }

bounded :: Text -> Text
bounded = Text.take 256

adminActionNamespace :: String
adminActionNamespace = "admin-action-runner"

adminActionContainerName :: Text
adminActionContainerName = "admin-action-runner"

observationAttempts :: Int
observationAttempts = 240

absenceAttempts :: Int
absenceAttempts = 240

observationDelayMicros :: Int
observationDelayMicros = 250000

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
    { boundedSubprocessMaximumInputBytes = 64 * 1024
    , boundedSubprocessMaximumStdoutBytes = 256 * 1024
    , boundedSubprocessMaximumStderrBytes = 16 * 1024
    , boundedSubprocessTimeoutMicros = 30 * 60 * 1000 * 1000
    }

deleteLimits :: BoundedSubprocessLimits
deleteLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 16 * 1024
    , boundedSubprocessMaximumStdoutBytes = 64 * 1024
    , boundedSubprocessMaximumStderrBytes = 16 * 1024
    , boundedSubprocessTimeoutMicros = 30 * 1000 * 1000
    }
