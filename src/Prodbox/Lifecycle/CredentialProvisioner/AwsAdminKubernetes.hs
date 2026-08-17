{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Native Kubernetes interpreter for the permit-bound AWS-admin Credential
-- Provisioner Job. The renderer consumes only the canonical Authority intent;
-- credentials enter later through the coordinator's bounded stdin attach.
module Prodbox.Lifecycle.CredentialProvisioner.AwsAdminKubernetes
  ( AwsAdminJobResources
  , mkAwsAdminJobResources
  , AwsAdminKubernetesError (..)
  , renderAwsAdminJob
  , productionAwsAdminKubernetesBoundary
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
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AwsAdminProvisionerClient
  ( AwsAdminPreparedProvisioning (..)
  )
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( AwsAdminPodObservation (..)
  , AwsAdminProvisionerChallenge (..)
  )
import Prodbox.Error (AppError, errorMsg)
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminCoordinator
  ( AwsAdminCleanupBinding (..)
  , AwsAdminKubernetesBoundary (..)
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminPermitIntent
  , AwsAdminPermitKind (..)
  , SignedAwsAdminPermit
  , awsAdminJobNameForPermit
  , awsAdminJobPodName
  , awsAdminJobPodUid
  , awsAdminJobUid
  , awsAdminPermitIntentAuthorityEndpoint
  , awsAdminPermitIntentAuthorityScope
  , awsAdminPermitIntentDeadline
  , awsAdminPermitIntentImageDigest
  , awsAdminPermitIntentKind
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentPermitId
  , awsAdminPermitIntentPlanBinding
  , awsAdminPermitIntentRequestDigest
  , awsAdminWorkerServiceAccount
  , signedAwsAdminPermitBinding
  )
import Prodbox.Lifecycle.CredentialProvisioner.KubernetesJob
  ( CredentialProvisionerJobConnection (..)
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( firstReconcilePermitMemberIndex
  , firstReconcilePermitPlanDigest
  , firstReconcilePermitPriorReceiptDigest
  , operatorMaterialOperationIdText
  , operatorMaterialPermitIdText
  )
import Prodbox.Lifecycle.Lease (authorityTimeMicros)
import Prodbox.Lifecycle.TargetCommitIntent (targetValueDigestText)
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

data AwsAdminJobResources = AwsAdminJobResources
  { awsAdminJobCpu :: !Text
  , awsAdminJobMemory :: !Text
  }
  deriving stock (Eq, Show)

mkAwsAdminJobResources :: Text -> Text -> Either AwsAdminKubernetesError AwsAdminJobResources
mkAwsAdminJobResources cpu memory = do
  validCpu <- boundedField "cpu" 32 cpu
  validMemory <- boundedField "memory" 32 memory
  pure (AwsAdminJobResources validCpu validMemory)

data AwsAdminKubernetesError
  = AwsAdminKubernetesRenderInvalid !Text
  | AwsAdminKubernetesCreateFailed !Text
  | AwsAdminKubernetesObservationFailed !Text
  | AwsAdminKubernetesAttachFailed !Text
  | AwsAdminKubernetesDeleteFailed !Text
  | AwsAdminKubernetesAbsenceUnobservable !Text
  | AwsAdminKubernetesStillPresent
  deriving stock (Eq, Show)

credentialProvisionerNamespace :: Text
credentialProvisionerNamespace = "credential-provisioner"

workerContainerName :: Text
workerContainerName = "credential-provisioner"

renderAwsAdminJob
  :: Text
  -> AwsAdminJobResources
  -> Natural
  -> AwsAdminPreparedProvisioning
  -> Either AwsAdminKubernetesError Value
renderAwsAdminJob imageRepository resources heartbeat prepared = do
  repository <- boundedField "image repository" 512 imageRepository
  unless
    (heartbeat > 0 && heartbeat < deadline)
    (Left (AwsAdminKubernetesRenderInvalid "heartbeat/deadline binding is invalid"))
  let activeSeconds = max 1 ((deadline - heartbeat + 999999) `div` 1000000)
  pure
    ( object
        [ "apiVersion" .= ("batch/v1" :: Text)
        , "kind" .= ("Job" :: Text)
        , "metadata"
            .= object
              [ "name" .= jobName
              , "namespace" .= credentialProvisionerNamespace
              , "labels" .= labels
              , "annotations" .= annotations
              ]
        , "spec"
            .= object
              [ "backoffLimit" .= (0 :: Int)
              , "completions" .= (1 :: Int)
              , "parallelism" .= (1 :: Int)
              , "activeDeadlineSeconds" .= activeSeconds
              , "template"
                  .= object
                    [ "metadata" .= object ["labels" .= labels, "annotations" .= annotations]
                    , "spec"
                        .= object
                          [ "serviceAccountName" .= awsAdminWorkerServiceAccount
                          , "automountServiceAccountToken" .= False
                          , "restartPolicy" .= ("Never" :: Text)
                          , "securityContext"
                              .= object
                                [ "runAsNonRoot" .= True
                                , "seccompProfile" .= object ["type" .= ("RuntimeDefault" :: Text)]
                                ]
                          , "containers"
                              .= [ object
                                     [ "name" .= workerContainerName
                                     , "image" .= repository
                                     , "imagePullPolicy" .= ("Always" :: Text)
                                     , "stdin" .= True
                                     , "stdinOnce" .= True
                                     , "tty" .= False
                                     , "args" .= workerArguments intent
                                     , "securityContext"
                                         .= object
                                           [ "allowPrivilegeEscalation" .= False
                                           , "capabilities" .= object ["drop" .= ["ALL" :: Text]]
                                           , "readOnlyRootFilesystem" .= True
                                           ]
                                     , "resources"
                                         .= object
                                           [ "requests" .= resourceValues
                                           , "limits" .= resourceValues
                                           ]
                                     , "volumeMounts"
                                         .= [ object ["name" .= ("runtime" :: Text), "mountPath" .= ("/run/prodbox" :: Text)]
                                            , object
                                                [ "name" .= ("identity-token" :: Text)
                                                , "mountPath" .= ("/var/run/secrets/prodbox" :: Text)
                                                , "readOnly" .= True
                                                ]
                                            ]
                                     ]
                                 ]
                          , "volumes"
                              .= [ object
                                     [ "name" .= ("runtime" :: Text)
                                     , "emptyDir"
                                         .= object
                                           [ "medium" .= ("Memory" :: Text)
                                           , "sizeLimit" .= ("16Mi" :: Text)
                                           ]
                                     ]
                                 , object
                                     [ "name" .= ("identity-token" :: Text)
                                     , "projected"
                                         .= object
                                           [ "sources"
                                               .= [ object
                                                      [ "serviceAccountToken"
                                                          .= object
                                                            [ "path" .= ("token" :: Text)
                                                            , "audience" .= ("prodbox-control-plane" :: Text)
                                                            , "expirationSeconds" .= (600 :: Natural)
                                                            ]
                                                      ]
                                                  , object
                                                      [ "downwardAPI"
                                                          .= object
                                                            [ "items"
                                                                .= [ downwardItem "pod-name" "metadata.name"
                                                                   , downwardItem "pod-uid" "metadata.uid"
                                                                   ]
                                                            ]
                                                      ]
                                                  ]
                                           ]
                                     ]
                                 ]
                          ]
                    ]
              ]
        ]
    )
 where
  intent = awsAdminPreparedCanonicalIntent prepared
  challenge = awsAdminPreparedChallenge prepared
  jobName = awsAdminChallengeJobName challenge
  deadline = authorityTimeMicros (awsAdminPermitIntentDeadline intent)
  labels :: Map Text Text
  labels =
    Map.fromList
      [ ("app.kubernetes.io/name", "prodbox-credential-provisioner")
      , ("app.kubernetes.io/component", "one-shot-worker")
      , ("app.kubernetes.io/managed-by", "prodbox")
      , ("prodbox.io/chart-root", "credential-provisioner")
      ]
  annotations = awsAdminAnnotations heartbeat intent
  resourceValues =
    object
      [ "cpu" .= awsAdminJobCpu resources
      , "memory" .= awsAdminJobMemory resources
      ]

downwardItem :: Text -> Text -> Value
downwardItem path fieldPath =
  object ["path" .= path, "fieldRef" .= object ["fieldPath" .= fieldPath]]

workerArguments :: AwsAdminPermitIntent -> [Text]
workerArguments intent =
  [ "credential-provisioner"
  , "run"
  , "--ingress-schema"
  , "aws-admin"
  , "--mode"
  , mode
  , "--operation-id"
  , operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent)
  , "--permit-id"
  , operatorMaterialPermitIdText (awsAdminPermitIntentPermitId intent)
  , "--request-digest"
  , targetValueDigestText (awsAdminPermitIntentRequestDigest intent)
  , "--deadline-micros"
  , Text.pack (show (authorityTimeMicros (awsAdminPermitIntentDeadline intent)))
  , "--image-digest"
  , awsAdminPermitIntentImageDigest intent
  , "--authority-scope"
  , awsAdminPermitIntentAuthorityScope intent
  , "--authority-endpoint"
  , awsAdminPermitIntentAuthorityEndpoint intent
  , "--pod-name-file"
  , "/var/run/secrets/prodbox/pod-name"
  , "--pod-uid-file"
  , "/var/run/secrets/prodbox/pod-uid"
  , "--service-account-token-file"
  , "/var/run/secrets/prodbox/token"
  ]
 where
  mode = case awsAdminPermitIntentKind intent of
    NormalOperatorMaterialKind -> "normal"
    GenesisBackupKind _ -> "genesis-backup"
    BackupRepairFrozenKind _ -> "backup-repair"

awsAdminAnnotations :: Natural -> AwsAdminPermitIntent -> Map Text Text
awsAdminAnnotations heartbeat intent =
  Map.fromList
    ( [
        ( "prodbox.io/operation-id"
        , operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent)
        )
      , ("prodbox.io/permit-id", operatorMaterialPermitIdText (awsAdminPermitIntentPermitId intent))
      , ("prodbox.io/request-digest", targetValueDigestText (awsAdminPermitIntentRequestDigest intent))
      ,
        ( "prodbox.io/deadline-micros"
        , Text.pack (show (authorityTimeMicros (awsAdminPermitIntentDeadline intent)))
        )
      , ("prodbox.io/host-heartbeat-micros", Text.pack (show heartbeat))
      , ("prodbox.io/image-digest", awsAdminPermitIntentImageDigest intent)
      , ("prodbox.io/aws-admin-mode", mode)
      , ("prodbox.io/authority-scope", awsAdminPermitIntentAuthorityScope intent)
      , ("prodbox.io/authority-endpoint", awsAdminPermitIntentAuthorityEndpoint intent)
      ]
        <> planAnnotations
    )
 where
  mode = case awsAdminPermitIntentKind intent of
    NormalOperatorMaterialKind -> "normal"
    GenesisBackupKind _ -> "genesis-backup"
    BackupRepairFrozenKind _ -> "backup-repair"
  planAnnotations = case awsAdminPermitIntentPlanBinding intent of
    Nothing -> []
    Just binding ->
      [ ("prodbox.io/plan-digest", targetValueDigestText (firstReconcilePermitPlanDigest binding))
      , ("prodbox.io/plan-member-index", Text.pack (show (firstReconcilePermitMemberIndex binding)))
      ,
        ( "prodbox.io/prior-receipt-digest"
        , maybe "" targetValueDigestText (firstReconcilePermitPriorReceiptDigest binding)
        )
      ]

productionAwsAdminKubernetesBoundary
  :: CredentialProvisionerJobConnection
  -> Text
  -> AwsAdminJobResources
  -> Natural
  -> AwsAdminKubernetesBoundary IO
productionAwsAdminKubernetesBoundary connection imageRepository resources heartbeat =
  AwsAdminKubernetesBoundary
    { createAwsAdminJob = createJob
    , observeAwsAdminJob = observeJobPod
    , attachAwsAdminWorker = attachWorker
    , deleteAwsAdminJob = deleteJob
    , observeAwsAdminJobAbsent = observeAbsent
    }
 where
  createJob prepared = do
    case renderAwsAdminJob imageRepository resources heartbeat prepared of
      Left err -> pure (Left (renderError err))
      Right manifest -> do
        result <-
          runWithInput
            createLimits
            (LazyByteString.toStrict (encode manifest))
            ["create", "--filename=-", "--output=json"]
        case result of
          Right output | processExitCode output == ExitSuccess -> pure (Right ())
          _ -> do
            recovered <- observeExactJob connection imageRepository heartbeat prepared
            pure $ case recovered of
              Right (Just _) -> Right ()
              Right Nothing -> Left "Job create failed and exact Job is absent"
              Left err -> Left (renderError err)

  observeJobPod prepared =
    fmap
      (either (Left . renderError) Right)
      (observeExactPod connection imageRepository heartbeat prepared)

  attachWorker permit frame = do
    let podName = awsAdminCleanupPodName (bindingForPermit permit)
    attempted <-
      runWithInput
        attachLimits
        frame
        [ "attach"
        , "--pod-running-timeout=10s"
        , "-i"
        , "pod/" <> Text.unpack podName
        , "--container"
        , Text.unpack workerContainerName
        ]
    pure $ case attempted of
      Left err -> Left (errorMsg err)
      Right output -> case processExitCode output of
        ExitSuccess -> Right (ByteString8.pack (processStdout output))
        ExitFailure _ -> Left (Text.pack (processStderr output))

  deleteJob prepared supplied = do
    observed <- observeExactJob connection imageRepository heartbeat prepared
    case observed of
      Left err -> pure (Left (renderError err))
      Right Nothing -> pure (Right ())
      Right (Just job)
        | maybe True ((== jobDtoUid job) . awsAdminCleanupJobUid) supplied -> do
            attempted <-
              runWithInput
                deleteLimits
                (LazyByteString.toStrict (encode (deleteOptions (jobDtoUid job))))
                ["delete", "--raw=" <> jobRawPath prepared, "--filename=-"]
            pure $ case attempted of
              Left err -> Left (errorMsg err)
              Right output
                | processExitCode output == ExitSuccess || isNotFound output -> Right ()
                | otherwise -> Left (Text.pack (processStderr output))
        | otherwise -> pure (Left "Job UID changed before deletion")

  observeAbsent prepared supplied = do
    result <- stableAbsence connection 12 prepared supplied
    pure (either (Left . renderError) Right result)

  runWithInput limits input args =
    captureSubprocessWithInputBounded limits input (kubectl connection args)

bindingForPermit :: SignedAwsAdminPermit -> AwsAdminCleanupBinding
bindingForPermit permit =
  let binding = signedAwsAdminPermitBinding permit
   in AwsAdminCleanupBinding
        { awsAdminCleanupJobUid = awsAdminJobUid binding
        , awsAdminCleanupPodName = awsAdminJobPodName binding
        , awsAdminCleanupPodUid = awsAdminJobPodUid binding
        }

data JobDto = JobDto
  { jobDtoName :: !Text
  , jobDtoUid :: !Text
  , jobDtoLabels :: !(Map Text Text)
  , jobDtoAnnotations :: !(Map Text Text)
  , jobDtoDeletionTimestamp :: !(Maybe Text)
  , jobDtoServiceAccount :: !Text
  , jobDtoContainers :: ![ContainerDto]
  }

instance FromJSON JobDto where
  parseJSON = withObject "AwsAdminJob" $ \value -> do
    metadata <- value .: "metadata"
    spec <- value .: "spec"
    template <- spec .: "template"
    templateSpec <- template .: "spec"
    JobDto
      <$> metadata .: "name"
      <*> metadata .: "uid"
      <*> metadata .:? "labels" .!= Map.empty
      <*> metadata .:? "annotations" .!= Map.empty
      <*> metadata .:? "deletionTimestamp"
      <*> templateSpec .: "serviceAccountName"
      <*> templateSpec .: "containers"

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
  , podDtoStatuses :: ![ContainerStatusDto]
  }

instance FromJSON PodDto where
  parseJSON = withObject "AwsAdminPod" $ \value -> do
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

newtype PodListDto = PodListDto [PodDto]

instance FromJSON PodListDto where
  parseJSON = withObject "AwsAdminPodList" $ \value -> PodListDto <$> value .: "items"

data OwnerDto = OwnerDto !Text !Text !Text !Bool

instance FromJSON OwnerDto where
  parseJSON = withObject "AwsAdminOwner" $ \value ->
    OwnerDto
      <$> value .: "kind"
      <*> value .: "name"
      <*> value .: "uid"
      <*> value .:? "controller" .!= False

data ContainerDto = ContainerDto !Text !Text

instance FromJSON ContainerDto where
  parseJSON = withObject "AwsAdminContainer" $ \value ->
    ContainerDto <$> value .: "name" <*> value .: "image"

data ContainerStatusDto = ContainerStatusDto !Text !Bool !Natural !Text

instance FromJSON ContainerStatusDto where
  parseJSON = withObject "AwsAdminContainerStatus" $ \value ->
    ContainerStatusDto
      <$> value .: "name"
      <*> value .:? "ready" .!= False
      <*> value .:? "restartCount" .!= 0
      <*> value .:? "imageID" .!= ""

data ServiceAccountDto = ServiceAccountDto !Text !Text

instance FromJSON ServiceAccountDto where
  parseJSON = withObject "AwsAdminServiceAccount" $ \value -> do
    metadata <- value .: "metadata"
    ServiceAccountDto <$> metadata .: "name" <*> metadata .: "uid"

observeExactJob
  :: CredentialProvisionerJobConnection
  -> Text
  -> Natural
  -> AwsAdminPreparedProvisioning
  -> IO (Either AwsAdminKubernetesError (Maybe JobDto))
observeExactJob connection imageRepository heartbeat prepared = do
  attempted <- runBounded observeLimits connection ["get", "--raw=" <> jobRawPath prepared]
  pure $ case attempted of
    Left err -> Left (AwsAdminKubernetesObservationFailed (errorMsg err))
    Right output -> case processExitCode output of
      ExitFailure _ | isNotFound output -> Right Nothing
      ExitFailure _ -> Left (AwsAdminKubernetesObservationFailed "exact Job is unobservable")
      ExitSuccess ->
        Just
          <$> decodeAndValidateJob
            imageRepository
            heartbeat
            prepared
            (ByteString8.pack (processStdout output))

decodeAndValidateJob
  :: Text
  -> Natural
  -> AwsAdminPreparedProvisioning
  -> ByteString
  -> Either AwsAdminKubernetesError JobDto
decodeAndValidateJob imageRepository heartbeat prepared bytes = do
  job <- firstText AwsAdminKubernetesObservationFailed (eitherDecodeStrict' bytes)
  let intent = awsAdminPreparedCanonicalIntent prepared
      expectedName = awsAdminJobNameForPermit (awsAdminPermitIntentPermitId intent)
      expectedAnnotations = awsAdminAnnotations heartbeat intent
  unless
    ( jobDtoName job == expectedName
        && jobDtoDeletionTimestamp job == Nothing
        && Map.lookup "app.kubernetes.io/name" (jobDtoLabels job)
          == Just "prodbox-credential-provisioner"
        && jobDtoServiceAccount job == awsAdminWorkerServiceAccount
        && mapContains expectedAnnotations (jobDtoAnnotations job)
    )
    (Left (AwsAdminKubernetesObservationFailed "Job identity or annotations drifted"))
  case findContainer workerContainerName (jobDtoContainers job) of
    Just (ContainerDto _ image)
      | image == imageRepository -> Right job
    _ -> Left (AwsAdminKubernetesObservationFailed "Job immutable worker image drifted")

observeExactPod
  :: CredentialProvisionerJobConnection
  -> Text
  -> Natural
  -> AwsAdminPreparedProvisioning
  -> IO (Either AwsAdminKubernetesError (Maybe AwsAdminPodObservation))
observeExactPod connection imageRepository heartbeat prepared = do
  jobResult <- observeExactJob connection imageRepository heartbeat prepared
  case jobResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right Nothing)
    Right (Just job) -> do
      podsResult <-
        runBounded
          observeLimits
          connection
          ["get", "pods", "--selector=job-name=" <> Text.unpack (jobDtoName job), "--output=json"]
      serviceAccountResult <-
        runBounded observeLimits connection ["get", "--raw=" <> serviceAccountRawPath]
      pure $ do
        podsOutput <- firstApp AwsAdminKubernetesObservationFailed podsResult
        unless
          (processExitCode podsOutput == ExitSuccess)
          (Left (AwsAdminKubernetesObservationFailed "Job Pods are unobservable"))
        PodListDto pods <-
          firstText
            AwsAdminKubernetesObservationFailed
            (eitherDecodeStrict' (ByteString8.pack (processStdout podsOutput)))
        pod <- case pods of
          [onlyPod] -> Right onlyPod
          [] -> Left (AwsAdminKubernetesObservationFailed "Job has no Pod")
          _ -> Left (AwsAdminKubernetesObservationFailed "Job has multiple Pods")
        saOutput <- firstApp AwsAdminKubernetesObservationFailed serviceAccountResult
        unless
          (processExitCode saOutput == ExitSuccess)
          (Left (AwsAdminKubernetesObservationFailed "ServiceAccount is unobservable"))
        ServiceAccountDto saName saUid <-
          firstText
            AwsAdminKubernetesObservationFailed
            (eitherDecodeStrict' (ByteString8.pack (processStdout saOutput)))
        Just <$> validatePod imageRepository heartbeat prepared job saName saUid pod

validatePod
  :: Text
  -> Natural
  -> AwsAdminPreparedProvisioning
  -> JobDto
  -> Text
  -> Text
  -> PodDto
  -> Either AwsAdminKubernetesError AwsAdminPodObservation
validatePod imageRepository heartbeat prepared job serviceAccountName serviceAccountUid pod = do
  let intent = awsAdminPreparedCanonicalIntent prepared
      expectedAnnotations = awsAdminAnnotations heartbeat intent
      exactOwner (OwnerDto kind name uid controller) =
        kind == "Job" && name == jobDtoName job && uid == jobDtoUid job && controller
  unless
    ( Map.lookup "job-name" (podDtoLabels pod) == Just (jobDtoName job)
        && length (filter exactOwner (podDtoOwners pod)) == 1
        && podDtoDeletionTimestamp pod == Nothing
        && podDtoServiceAccount pod == awsAdminWorkerServiceAccount
        && serviceAccountName == awsAdminWorkerServiceAccount
        && mapContains expectedAnnotations (podDtoAnnotations pod)
        && podDtoPhase pod == "Running"
    )
    (Left (AwsAdminKubernetesObservationFailed "Pod identity, ownership, or runtime phase drifted"))
  case ( findContainer workerContainerName (podDtoContainers pod)
       , findStatus workerContainerName (podDtoStatuses pod)
       ) of
    (Just (ContainerDto _ image), Just (ContainerStatusDto _ True 0 runtimeImageId))
      | image == imageRepository
          && runtimeImageDigest runtimeImageId == Just (awsAdminPermitIntentImageDigest intent) ->
          Right
            AwsAdminPodObservation
              { awsAdminObservedJobName = jobDtoName job
              , awsAdminObservedJobUid = jobDtoUid job
              , awsAdminObservedPodName = podDtoName pod
              , awsAdminObservedPodUid = podDtoUid pod
              , awsAdminObservedImageDigest = awsAdminPermitIntentImageDigest intent
              , awsAdminObservedServiceAccount = serviceAccountName
              , awsAdminObservedServiceAccountUid = serviceAccountUid
              , awsAdminObservedHeartbeatMicros = heartbeat
              }
    _ -> Left (AwsAdminKubernetesObservationFailed "worker container is not exact, immutable, and ready")

stableAbsence
  :: CredentialProvisionerJobConnection
  -> Int
  -> AwsAdminPreparedProvisioning
  -> Maybe AwsAdminCleanupBinding
  -> IO (Either AwsAdminKubernetesError Bool)
stableAbsence connection attempts prepared supplied = seek attempts False
 where
  seek remaining sawZero
    | remaining <= 0 = pure (Left AwsAdminKubernetesStillPresent)
    | otherwise = do
        observed <- observeAbsenceOnce connection prepared supplied
        case observed of
          Left err -> pure (Left err)
          Right True
            | sawZero -> pure (Right True)
            | otherwise -> threadDelay visibilityGraceMicros >> seek (remaining - 1) True
          Right False -> threadDelay observationDelayMicros >> seek (remaining - 1) False

observeAbsenceOnce
  :: CredentialProvisionerJobConnection
  -> AwsAdminPreparedProvisioning
  -> Maybe AwsAdminCleanupBinding
  -> IO (Either AwsAdminKubernetesError Bool)
observeAbsenceOnce connection prepared supplied = do
  -- During foreground observation Kubernetes may retain the exact Job with a
  -- deletion timestamp. Absence therefore uses a UID-only read, not the
  -- creation/attestation validator that correctly rejects deleting objects.
  jobResult <- observeNamedJob connection prepared
  podsResult <-
    runBounded
      observeLimits
      connection
      ["get", "pods", "--selector=job-name=" <> Text.unpack jobName, "--output=json"]
  pure $ do
    jobAbsent <- case jobResult of
      Left err -> Left err
      Right Nothing -> Right True
      Right (Just job) -> case supplied of
        Just binding
          | jobDtoUid job /= awsAdminCleanupJobUid binding ->
              Left (AwsAdminKubernetesAbsenceUnobservable "Job name was reused with a foreign UID")
        _ -> Right False
    output <- firstApp AwsAdminKubernetesAbsenceUnobservable podsResult
    unless
      (processExitCode output == ExitSuccess)
      (Left (AwsAdminKubernetesAbsenceUnobservable "owned Pods are unobservable"))
    PodListDto pods <-
      firstText
        AwsAdminKubernetesAbsenceUnobservable
        (eitherDecodeStrict' (ByteString8.pack (processStdout output)))
    let ownedByExpected (OwnerDto kind name uid controller) =
          kind == "Job"
            && name == jobName
            && controller
            && maybe True ((== uid) . awsAdminCleanupJobUid) supplied
        podsAbsent = not (any (any ownedByExpected . podDtoOwners) pods)
    pure (jobAbsent && podsAbsent)
 where
  jobName = awsAdminChallengeJobName (awsAdminPreparedChallenge prepared)

observeNamedJob
  :: CredentialProvisionerJobConnection
  -> AwsAdminPreparedProvisioning
  -> IO (Either AwsAdminKubernetesError (Maybe JobDto))
observeNamedJob connection prepared = do
  attempted <- runBounded observeLimits connection ["get", "--raw=" <> jobRawPath prepared]
  pure $ case attempted of
    Left err -> Left (AwsAdminKubernetesAbsenceUnobservable (errorMsg err))
    Right output -> case processExitCode output of
      ExitFailure _ | isNotFound output -> Right Nothing
      ExitFailure _ -> Left (AwsAdminKubernetesAbsenceUnobservable "named Job is unobservable")
      ExitSuccess ->
        Just
          <$> firstText
            AwsAdminKubernetesAbsenceUnobservable
            (eitherDecodeStrict' (ByteString8.pack (processStdout output)))

deleteOptions :: Text -> Value
deleteOptions uid =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("DeleteOptions" :: Text)
    , "gracePeriodSeconds" .= (0 :: Natural)
    , "propagationPolicy" .= ("Background" :: Text)
    , "preconditions" .= object ["uid" .= uid]
    ]

jobRawPath :: AwsAdminPreparedProvisioning -> String
jobRawPath prepared =
  "/apis/batch/v1/namespaces/credential-provisioner/jobs/"
    <> Text.unpack (awsAdminChallengeJobName (awsAdminPreparedChallenge prepared))

serviceAccountRawPath :: String
serviceAccountRawPath =
  "/api/v1/namespaces/credential-provisioner/serviceaccounts/"
    <> Text.unpack awsAdminWorkerServiceAccount

kubectl :: CredentialProvisionerJobConnection -> [String] -> Subprocess
kubectl connection arguments =
  Subprocess
    { subprocessPath = "kubectl"
    , subprocessArguments = ["--namespace", Text.unpack credentialProvisionerNamespace] <> arguments
    , subprocessEnvironment = credentialProvisionerJobEnvironment connection
    , subprocessWorkingDirectory = Just (credentialProvisionerJobWorkingDirectory connection)
    }

runBounded
  :: BoundedSubprocessLimits
  -> CredentialProvisionerJobConnection
  -> [String]
  -> IO (Either AppError ProcessOutput)
runBounded limits connection = captureSubprocessBounded limits . kubectl connection

findContainer :: Text -> [ContainerDto] -> Maybe ContainerDto
findContainer name = find (\(ContainerDto actual _) -> actual == name)

findStatus :: Text -> [ContainerStatusDto] -> Maybe ContainerStatusDto
findStatus name = find (\(ContainerStatusDto actual _ _ _) -> actual == name)

runtimeImageDigest :: Text -> Maybe Text
runtimeImageDigest value =
  let candidate = case Text.breakOnEnd "://" value of
        (prefix, suffix) | not (Text.null prefix) -> suffix
        _ -> value
   in if "sha256:" `Text.isPrefixOf` candidate && Text.length candidate == 71
        then Just candidate
        else Nothing

mapContains :: Map Text Text -> Map Text Text -> Bool
mapContains expected actual = all (\(key, value) -> Map.lookup key actual == Just value) (Map.toList expected)

-- | Sprint 4.78: keyed through the one owner, and scoped to __stderr__.
-- It used to match against @stdout <> stderr@, so a kubectl command that
-- succeeded and printed an object whose own content contained @not found@ —
-- a ConfigMap value, a container log line, a condition message — was read as
-- the object being absent.
isNotFound :: ProcessOutput -> Bool
isNotFound output = reportsAbsence KubernetesObjectProbe (processStderr output)

boundedField :: Text -> Int -> Text -> Either AwsAdminKubernetesError Text
boundedField name maximumLength raw =
  let value = Text.strip raw
   in if Text.null value || Text.length value > maximumLength || value /= raw
        then Left (AwsAdminKubernetesRenderInvalid (name <> " is invalid"))
        else Right value

renderError :: AwsAdminKubernetesError -> Text
renderError = Text.pack . show

firstText :: (Text -> errorValue) -> Either String value -> Either errorValue value
firstText wrap = either (Left . wrap . Text.pack) Right

firstApp
  :: (Show appError)
  => (Text -> errorValue)
  -> Either appError value
  -> Either errorValue value
firstApp wrap = either (Left . wrap . Text.pack . show) Right

createLimits, observeLimits, attachLimits, deleteLimits :: BoundedSubprocessLimits
createLimits = BoundedSubprocessLimits (256 * 1024) (64 * 1024) (16 * 1024) (30 * 1000 * 1000)
observeLimits = BoundedSubprocessLimits 1 (256 * 1024) (16 * 1024) (10 * 1000 * 1000)
attachLimits = BoundedSubprocessLimits (64 * 1024) (16 * 1024) (16 * 1024) (10 * 60 * 1000 * 1000)
deleteLimits = BoundedSubprocessLimits (16 * 1024) (64 * 1024) (16 * 1024) (30 * 1000 * 1000)

observationDelayMicros, visibilityGraceMicros :: Int
observationDelayMicros = 250000
visibilityGraceMicros = 1000000
