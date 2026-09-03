{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Native Kubernetes interpreter for the permit-bound AWS-admin Credential
-- Provisioner Job. The renderer consumes only the canonical Authority intent;
-- credentials enter later through the coordinator's bounded stdin attach.
module Prodbox.Lifecycle.CredentialProvisioner.AwsAdminKubernetes
  ( AwsAdminJobResources
  , mkAwsAdminJobResources
  , oneShotAwsAdminJobResources
  , AwsAdminKubernetesError (..)
  , AwsAdminPodConvergence (..)
  , AwsAdminWorkerReceiptCaptureSource (..)
  , awaitAwsAdminPodObservationWith
  , decodeAwsAdminWorkerReceiptCapture
  , recoverEmptyAwsAdminWorkerReceiptCaptureWith
  , renderAwsAdminWorkerReceiptCaptureSource
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
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.CLI.Output (writeDiagnosticLine)
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.Render qualified as CapacityRender
import Prodbox.ContainerImage qualified as ContainerImage
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
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( classifyAwsAdminWorkerReceiptTransport
  , decodeAwsAdminWorkerReceipt
  , decodeAwsAdminWorkerReceiptTextEnvelope
  , renderAwsAdminWorkerReceiptTransportObservation
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminCleanupRecoveryProgram (..)
  , AwsAdminPermitIntent
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
import Prodbox.Lifecycle.CredentialProvisioner.ImageIdentity
  ( credentialProvisionerRuntimeManifestDigest
  )
import Prodbox.Lifecycle.CredentialProvisioner.KubernetesJob
  ( CredentialProvisionerJobConnection (..)
  , credentialProvisionerKubectlArguments
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( firstReconcilePermitMemberIndex
  , firstReconcilePermitPlanDigest
  , firstReconcilePermitPriorReceiptDigest
  , operatorMaterialOperationIdText
  , operatorMaterialPermitIdText
  )
import Prodbox.Lifecycle.CredentialProvisioner.RuntimeSecurity
  ( credentialProvisionerKubernetesApiVolume
  , credentialProvisionerKubernetesApiVolumeMount
  , credentialProvisionerPodSecurityContext
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
  , awsAdminJobEphemeralStorage :: !Text
  }
  deriving stock (Eq, Show)

mkAwsAdminJobResources :: Text -> Text -> Either AwsAdminKubernetesError AwsAdminJobResources
mkAwsAdminJobResources cpu memory = do
  validCpu <- boundedField "cpu" 32 cpu
  validMemory <- boundedField "memory" 32 memory
  pure
    ( AwsAdminJobResources
        validCpu
        validMemory
        ( Text.pack
            ( CapacityRender.memoryQuantity
                (Capacity.ephemeral_storage_mib workerVector)
            )
        )
    )
 where
  workerVector = Capacity.limit Capacity.oneShotSecretWorkerEnvelope

oneShotAwsAdminJobResources :: AwsAdminJobResources
oneShotAwsAdminJobResources =
  AwsAdminJobResources
    { awsAdminJobCpu = Text.pack (CapacityRender.cpuQuantity (Capacity.milli_cpu workerVector))
    , awsAdminJobMemory = Text.pack (CapacityRender.memoryQuantity (Capacity.memory_mib workerVector))
    , awsAdminJobEphemeralStorage =
        Text.pack (CapacityRender.memoryQuantity (Capacity.ephemeral_storage_mib workerVector))
    }
 where
  workerVector = Capacity.limit Capacity.oneShotSecretWorkerEnvelope

data AwsAdminKubernetesError
  = AwsAdminKubernetesRenderInvalid !Text
  | AwsAdminKubernetesCreateFailed !Text
  | AwsAdminKubernetesObservationFailed !Text
  | AwsAdminKubernetesAttachFailed !Text
  | AwsAdminKubernetesDeleteFailed !Text
  | AwsAdminKubernetesAbsenceUnobservable !Text
  | AwsAdminKubernetesStillPresent
  deriving stock (Eq, Show)

data AwsAdminPodConvergence
  = AwsAdminPodAbsent
  | AwsAdminPodTransitional
  | AwsAdminPodReady !AwsAdminPodObservation
  deriving stock (Eq, Show)

data AwsAdminWorkerReceiptCaptureSource
  = AwsAdminWorkerReceiptFromAttach
  | AwsAdminWorkerReceiptFromPodLog
  deriving stock (Eq, Show, Enum, Bounded)

renderAwsAdminWorkerReceiptCaptureSource
  :: AwsAdminWorkerReceiptCaptureSource -> Text
renderAwsAdminWorkerReceiptCaptureSource source = case source of
  AwsAdminWorkerReceiptFromAttach -> "attach"
  AwsAdminWorkerReceiptFromPodLog -> "pod-log"

-- | Recover only the live-observed successful-but-empty attach shape.  The
-- fallback cannot replace non-empty attach bytes, and failure preserves the
-- original empty capture so the existing canonical decoder refusal survives.
recoverEmptyAwsAdminWorkerReceiptCaptureWith
  :: (Monad m)
  => ByteString
  -> m (Maybe ByteString)
  -> m (AwsAdminWorkerReceiptCaptureSource, ByteString)
recoverEmptyAwsAdminWorkerReceiptCaptureWith attached fallback
  | not (ByteString.null attached) =
      pure (AwsAdminWorkerReceiptFromAttach, attached)
  | otherwise = do
      recovered <- fallback
      pure $ case recovered of
        Just bytes -> (AwsAdminWorkerReceiptFromPodLog, bytes)
        Nothing -> (AwsAdminWorkerReceiptFromAttach, attached)

-- | Admit only the fixed-version canonical ASCII envelope introduced for the
-- live-observed line-oriented transport. Attach must be exactly one leading
-- record separator plus the envelope. Pod logs must have the observed final LF
-- and exactly one canonical envelope line; no match or ambiguity fails closed.
decodeAwsAdminWorkerReceiptCapture
  :: AwsAdminWorkerReceiptCaptureSource -> ByteString -> Maybe ByteString
decodeAwsAdminWorkerReceiptCapture source captured = case source of
  AwsAdminWorkerReceiptFromAttach -> do
    envelope <- ByteString.stripPrefix "\n" captured
    if ByteString.elem 10 envelope
      then Nothing
      else decodeCanonicalEnvelopeLine envelope
  AwsAdminWorkerReceiptFromPodLog
    | ByteString.isSuffixOf "\r\n" captured -> Nothing
    | ByteString.isSuffixOf "\n" captured ->
        let payload = ByteString.dropEnd 1 captured
         in if ByteString.isSuffixOf "\n" payload
              then Nothing
              else case mapMaybe decodeCanonicalEnvelopeLine (ByteString.split 10 payload) of
                [receiptBytes] -> Just receiptBytes
                _ -> Nothing
    | otherwise -> Nothing

decodeCanonicalEnvelopeLine :: ByteString -> Maybe ByteString
decodeCanonicalEnvelopeLine line = do
  receiptBytes <-
    either (const Nothing) Just (decodeAwsAdminWorkerReceiptTextEnvelope line)
  either (const Nothing) (const (Just receiptBytes)) (decodeAwsAdminWorkerReceipt receiptBytes)

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
renderAwsAdminJob executionImageReference resources heartbeat prepared = do
  imageReference <- boundedField "execution image reference" 512 executionImageReference
  targetWorkerRepository <- imageRepositoryWithoutTag imageReference
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
                          , "securityContext" .= credentialProvisionerPodSecurityContext
                          , "containers"
                              .= [ object
                                     [ "name" .= workerContainerName
                                     , "image" .= imageReference
                                     , "imagePullPolicy" .= ("Always" :: Text)
                                     , "stdin" .= True
                                     , "stdinOnce" .= True
                                     , "tty" .= False
                                     , "args" .= workerArguments targetWorkerRepository intent
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
                                            , credentialProvisionerKubernetesApiVolumeMount
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
                                 , credentialProvisionerKubernetesApiVolume
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
      , ("prodbox.io/ingress-schema", "aws-admin")
      ]
  annotations = awsAdminAnnotations heartbeat intent
  resourceValues =
    object
      [ "cpu" .= awsAdminJobCpu resources
      , "memory" .= awsAdminJobMemory resources
      , "ephemeral-storage" .= awsAdminJobEphemeralStorage resources
      ]

downwardItem :: Text -> Text -> Value
downwardItem path fieldPath =
  object ["path" .= path, "fieldRef" .= object ["fieldPath" .= fieldPath]]

workerArguments :: Text -> AwsAdminPermitIntent -> [Text]
workerArguments targetWorkerRepository intent =
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
  , "--target-worker-image-repository"
  , targetWorkerRepository
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
    CleanupRecoveryKind NormalOperatorMaterialCleanupProgram _ -> "normal"
    CleanupRecoveryKind (GenesisBackupCleanupProgram _) _ -> "genesis-backup"

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
    CleanupRecoveryKind NormalOperatorMaterialCleanupProgram _ -> "normal"
    CleanupRecoveryKind (GenesisBackupCleanupProgram _) _ -> "genesis-backup"
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
  -> IO (Either Text Natural)
  -> AwsAdminKubernetesBoundary IO
productionAwsAdminKubernetesBoundary connection imageRepository resources acquireHeartbeat =
  AwsAdminKubernetesBoundary
    { acquireAwsAdminJobHeartbeat = acquireHeartbeat
    , createAwsAdminJob = createJob
    , observeAwsAdminJob = observeJobPod
    , attachAwsAdminWorker = attachWorker
    , deleteAwsAdminJob = deleteJob
    , observeAwsAdminJobAbsent = observeAbsent
    }
 where
  createJob heartbeat prepared = do
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

  observeJobPod heartbeat prepared =
    fmap
      (either (Left . renderError) Right)
      ( awaitAwsAdminPodObservationWith
          podObservationAttempts
          (threadDelay observationDelayMicros)
          (observeExactPodOnce connection imageRepository heartbeat prepared)
      )

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
    case attempted of
      Left err -> pure (Left (errorMsg err))
      Right output -> case processExitCode output of
        ExitSuccess -> do
          let attachedBytes = ByteString8.pack (processStdout output)
          writeReceiptTransportDiagnostic AwsAdminWorkerReceiptFromAttach attachedBytes
          (source, receiptBytes) <-
            recoverEmptyAwsAdminWorkerReceiptCaptureWith
              attachedBytes
              (readWorkerReceiptLog podName)
          case source of
            AwsAdminWorkerReceiptFromAttach -> pure ()
            AwsAdminWorkerReceiptFromPodLog ->
              writeReceiptTransportDiagnostic source receiptBytes
          pure
            ( Right
                ( fromMaybe
                    ByteString.empty
                    (decodeAwsAdminWorkerReceiptCapture source receiptBytes)
                )
            )
        ExitFailure _ -> pure (Left (Text.pack (processStderr output)))

  readWorkerReceiptLog podName = do
    attempted <-
      runBounded
        receiptLogLimits
        connection
        [ "logs"
        , "pod/" <> Text.unpack podName
        , "--container"
        , Text.unpack workerContainerName
        ]
    pure $ case attempted of
      Right output
        | processExitCode output == ExitSuccess ->
            Just (ByteString8.pack (processStdout output))
      _ -> Nothing

  deleteJob heartbeat prepared supplied = do
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

awaitAwsAdminPodObservationWith
  :: Int
  -> IO ()
  -> IO (Either AwsAdminKubernetesError AwsAdminPodConvergence)
  -> IO (Either AwsAdminKubernetesError (Maybe AwsAdminPodObservation))
awaitAwsAdminPodObservationWith attempts waitForNext observe = seek attempts
 where
  seek remaining
    | remaining <= 0 = pure observationBudgetExhausted
    | otherwise = do
        observed <- observe
        case observed of
          Left err -> pure (Left err)
          Right AwsAdminPodAbsent -> pure (Right Nothing)
          Right (AwsAdminPodReady pod) -> pure (Right (Just pod))
          Right AwsAdminPodTransitional
            | remaining == 1 -> pure observationBudgetExhausted
            | otherwise -> waitForNext >> seek (remaining - 1)

  observationBudgetExhausted =
    Left
      ( AwsAdminKubernetesObservationFailed
          "exact Pod did not become ready before the observation budget expired"
      )

observeExactPodOnce
  :: CredentialProvisionerJobConnection
  -> Text
  -> Natural
  -> AwsAdminPreparedProvisioning
  -> IO (Either AwsAdminKubernetesError AwsAdminPodConvergence)
observeExactPodOnce connection imageRepository heartbeat prepared = do
  jobResult <- observeExactJob connection imageRepository heartbeat prepared
  case jobResult of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right AwsAdminPodAbsent)
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
        validatePod imageRepository heartbeat prepared job saName saUid pod

validatePod
  :: Text
  -> Natural
  -> AwsAdminPreparedProvisioning
  -> JobDto
  -> Text
  -> Text
  -> PodDto
  -> Either AwsAdminKubernetesError AwsAdminPodConvergence
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
    )
    (Left (AwsAdminKubernetesObservationFailed "Pod identity or ownership drifted"))
  case findContainer workerContainerName (podDtoContainers pod) of
    Just (ContainerDto _ image)
      | image == imageRepository -> classifyRuntime intent
    _ -> Left (AwsAdminKubernetesObservationFailed "worker container image specification drifted")
 where
  classifyRuntime intent = case podDtoPhase pod of
    "" -> transitionalIfExact intent
    "Pending" -> transitionalIfExact intent
    "Running" -> case findStatus workerContainerName (podDtoStatuses pod) of
      Just (ContainerStatusDto _ True 0 runtimeImageId)
        | credentialProvisionerRuntimeManifestDigest runtimeImageId
            == Just (awsAdminPermitIntentImageDigest intent) ->
            Right (AwsAdminPodReady (readyObservation intent))
      _ -> transitionalIfExact intent
    _ -> Left (AwsAdminKubernetesObservationFailed "worker Pod entered a terminal or unknown phase")

  transitionalIfExact intent =
    case findStatus workerContainerName (podDtoStatuses pod) of
      Nothing -> Right AwsAdminPodTransitional
      Just (ContainerStatusDto _ False 0 runtimeImageId)
        | Text.null runtimeImageId
            || credentialProvisionerRuntimeManifestDigest runtimeImageId
              == Just (awsAdminPermitIntentImageDigest intent) ->
            Right AwsAdminPodTransitional
      _ -> Left (AwsAdminKubernetesObservationFailed "worker container runtime identity drifted")

  readyObservation intent =
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
    , subprocessArguments = credentialProvisionerKubectlArguments connection arguments
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

imageRepositoryWithoutTag :: Text -> Either AwsAdminKubernetesError Text
imageRepositoryWithoutTag imageReference = do
  image <-
    firstText
      (const (AwsAdminKubernetesRenderInvalid "execution image reference is invalid"))
      (ContainerImage.parseImageRef (Text.unpack imageReference))
  boundedField
    "target worker image repository"
    512
    ( Text.pack
        (ContainerImage.imageRegistry image ++ "/" ++ ContainerImage.imageRepository image)
    )

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

writeReceiptTransportDiagnostic
  :: AwsAdminWorkerReceiptCaptureSource -> ByteString -> IO ()
writeReceiptTransportDiagnostic source bytes =
  writeDiagnosticLine
    ( "aws-admin/worker-receipt-transport source="
        <> Text.unpack (renderAwsAdminWorkerReceiptCaptureSource source)
        <> "/"
        <> Text.unpack
          ( renderAwsAdminWorkerReceiptTransportObservation
              (classifyAwsAdminWorkerReceiptTransport bytes)
          )
    )

createLimits
  , observeLimits
  , attachLimits
  , receiptLogLimits
  , deleteLimits
    :: BoundedSubprocessLimits
createLimits = BoundedSubprocessLimits (256 * 1024) (64 * 1024) (16 * 1024) (30 * 1000 * 1000)
observeLimits = BoundedSubprocessLimits 1 (256 * 1024) (16 * 1024) (10 * 1000 * 1000)
attachLimits = BoundedSubprocessLimits (64 * 1024) (16 * 1024) (16 * 1024) (10 * 60 * 1000 * 1000)
receiptLogLimits = BoundedSubprocessLimits 1 (64 * 1024) (16 * 1024) (10 * 1000 * 1000)
deleteLimits = BoundedSubprocessLimits (16 * 1024) (64 * 1024) (16 * 1024) (30 * 1000 * 1000)

observationDelayMicros, visibilityGraceMicros :: Int
observationDelayMicros = 250000
visibilityGraceMicros = 1000000

podObservationAttempts :: Int
podObservationAttempts = 60
