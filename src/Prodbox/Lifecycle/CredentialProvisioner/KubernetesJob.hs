{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Host-side physical boundary for one immutable, permit-bound external EAB
-- Job.  Kubernetes receives only secret-free intent metadata.  Plaintext is
-- written once to the exact freshly observed/attested Pod through @kubectl
-- attach -i@, never through argv, environment, a Secret, ConfigMap, or file.
module Prodbox.Lifecycle.CredentialProvisioner.KubernetesJob
  ( CredentialProvisionerJobConnection (..)
  , ExternalMaterialJobAttestation
  , CredentialProvisionerJobCreateRecovery (..)
  , externalMaterialJobPodObservation
  , externalMaterialJobPodName
  , externalMaterialJobAttestedJobUid
  , externalMaterialJobAttestedPodUid
  , externalMaterialJobAttestedServiceAccountUid
  , CredentialProvisionerJobError (..)
  , renderCredentialProvisionerExternalJob
  , credentialProvisionerCreateSubprocess
  , credentialProvisionerObserveJobSubprocess
  , credentialProvisionerObserveSubprocess
  , credentialProvisionerAttachSubprocess
  , credentialProvisionerLogsSubprocess
  , credentialProvisionerDeleteSubprocess
  , credentialProvisionerJobDeleteOptions
  , createCredentialProvisionerExternalJob
  , recoverCredentialProvisionerExternalJob
  , recoverCredentialProvisionerExternalJobCreateWith
  , attestExternalMaterialJobObservation
  , observeCredentialProvisionerExternalJob
  , attachCredentialProvisionerExternalIngress
  , recoverCredentialProvisionerExternalIngress
  , deleteCredentialProvisionerExternalJob
  , observeCredentialProvisionerExternalJobAbsent
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
import Data.Aeson.Key qualified as AesonKey
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
import Prodbox.Error (errorMsg)
import Prodbox.Lifecycle.CredentialProvisioner.ExternalIngress
  ( ExternalMaterialIngressIntent
  , ExternalMaterialTargetReceipt
  , decodeExternalMaterialTargetReceipt
  , externalMaterialIngressIntentDeadline
  , externalMaterialIngressIntentImageDigest
  , externalMaterialIngressIntentPermitId
  , externalMaterialIngressIntentRequest
  , externalMaterialIngressJobIntent
  , externalMaterialTargetReceiptGeneration
  , externalMaterialTargetReceiptPermitId
  , externalMaterialTargetReceiptRequestDigest
  )
import Prodbox.Lifecycle.CredentialProvisioner.ExternalMaterialWorkerProtocol
  ( encodeExternalMaterialWorkerIngress
  )
import Prodbox.Lifecycle.CredentialProvisioner.Kubernetes
  ( CredentialProvisionerJobAttestation
  , CredentialProvisionerJobIntent
  , CredentialProvisionerJobUid
  , CredentialProvisionerPodUid
  , CredentialProvisionerServiceAccountUid
  , RawCredentialProvisionerPodObservation (..)
  , attestCredentialProvisionerPod
  , credentialProvisionerAttestedJobUid
  , credentialProvisionerAttestedPodUid
  , credentialProvisionerAttestedServiceAccountUid
  , credentialProvisionerImageDigestText
  , credentialProvisionerIntentServiceAccount
  , credentialProvisionerJobName
  , credentialProvisionerJobUidText
  , credentialProvisionerServiceAccountText
  , credentialProvisionerServiceAccountUidText
  , mkCredentialProvisionerJobUid
  , mkCredentialProvisionerServiceAccountUid
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( OperatorMaterialIngressSchema (ExternalAcmeEabIngress)
  , operatorMaterialPermitIdText
  , operatorMaterialRequestDigest
  , operatorMaterialRequestGeneration
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( mkTargetValueDigest
  , targetValueDigestText
  )
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

data CredentialProvisionerJobConnection = CredentialProvisionerJobConnection
  { credentialProvisionerJobEnvironment :: !(Maybe [(String, String)])
  , credentialProvisionerJobWorkingDirectory :: !FilePath
  }
  deriving stock (Eq, Show)

data ExternalMaterialJobAttestation = ExternalMaterialJobAttestation
  { internalExternalMaterialJobPodName :: !Text
  , internalExternalMaterialIngressIntent :: !ExternalMaterialIngressIntent
  , internalExternalMaterialJobPodObservation
      :: !RawCredentialProvisionerPodObservation
  , internalExternalMaterialJobAttestation
      :: !(CredentialProvisionerJobAttestation 'ExternalAcmeEabIngress)
  }
  deriving stock (Eq, Show)

externalMaterialJobPodObservation
  :: ExternalMaterialJobAttestation -> RawCredentialProvisionerPodObservation
externalMaterialJobPodObservation = internalExternalMaterialJobPodObservation

externalMaterialJobPodName :: ExternalMaterialJobAttestation -> Text
externalMaterialJobPodName = internalExternalMaterialJobPodName

externalMaterialJobAttestedJobUid
  :: ExternalMaterialJobAttestation -> CredentialProvisionerJobUid
externalMaterialJobAttestedJobUid =
  credentialProvisionerAttestedJobUid . internalExternalMaterialJobAttestation

externalMaterialJobAttestedPodUid
  :: ExternalMaterialJobAttestation -> CredentialProvisionerPodUid
externalMaterialJobAttestedPodUid =
  credentialProvisionerAttestedPodUid . internalExternalMaterialJobAttestation

externalMaterialJobAttestedServiceAccountUid
  :: ExternalMaterialJobAttestation -> CredentialProvisionerServiceAccountUid
externalMaterialJobAttestedServiceAccountUid =
  credentialProvisionerAttestedServiceAccountUid
    . internalExternalMaterialJobAttestation

data CredentialProvisionerJobCreateRecovery
  = CredentialProvisionerJobCreateStablyAbsent
  | CredentialProvisionerJobCreateRecovered !CredentialProvisionerJobUid
  deriving stock (Eq, Show)

data CredentialProvisionerJobError
  = CredentialProvisionerJobRenderInvalid !Text
  | CredentialProvisionerJobCreateFailed !Text
  | CredentialProvisionerJobObservationFailed !Text
  | CredentialProvisionerJobAttestationFailed !Text
  | CredentialProvisionerJobAttachFailed !Text
  | CredentialProvisionerJobWorkerRefused !Text
  | CredentialProvisionerJobIngressInvalid !Text
  | CredentialProvisionerJobReceiptInvalid !Text
  | CredentialProvisionerJobRecoveryFailed !Text
  | CredentialProvisionerJobDeleteFailed !Text
  | CredentialProvisionerJobAbsenceUnobservable !Text
  | CredentialProvisionerJobStillPresent
  deriving stock (Eq, Show)

credentialProvisionerNamespace :: String
credentialProvisionerNamespace = "credential-provisioner"

externalWorkerContainerName :: Text
externalWorkerContainerName = "external-material-ingress"

renderCredentialProvisionerExternalJob
  :: Text
  -> Natural
  -> ExternalMaterialIngressIntent
  -> Either CredentialProvisionerJobError Value
renderCredentialProvisionerExternalJob imageRepository heartbeat intent = do
  unless
    (not (Text.null (Text.strip imageRepository)))
    (Left (CredentialProvisionerJobRenderInvalid "image repository is empty"))
  unless
    ( heartbeat > 0
        && heartbeat < authorityTimeMicros (externalMaterialIngressIntentDeadline intent)
    )
    (Left (CredentialProvisionerJobRenderInvalid "heartbeat/deadline binding is invalid"))
  pure
    ( object
        [ "apiVersion" .= ("batch/v1" :: Text)
        , "kind" .= ("Job" :: Text)
        , "metadata"
            .= object
              [ "name" .= jobName
              , "namespace" .= (Text.pack credentialProvisionerNamespace)
              , "labels" .= labels
              , "annotations" .= annotations
              ]
        , "spec"
            .= object
              [ "backoffLimit" .= (0 :: Int)
              , "completions" .= (1 :: Int)
              , "parallelism" .= (1 :: Int)
              , "activeDeadlineSeconds" .= activeDeadlineSeconds
              , "template"
                  .= object
                    [ "metadata"
                        .= object
                          [ "labels" .= labels
                          , "annotations" .= annotations
                          ]
                    , "spec"
                        .= object
                          [ "serviceAccountName" .= serviceAccount
                          , "automountServiceAccountToken" .= False
                          , "restartPolicy" .= ("Never" :: Text)
                          , "securityContext"
                              .= object
                                [ "runAsNonRoot" .= True
                                , "seccompProfile"
                                    .= object ["type" .= ("RuntimeDefault" :: Text)]
                                ]
                          , "containers"
                              .= [ object
                                     [ "name" .= externalWorkerContainerName
                                     , "image" .= imageRepository
                                     , "imagePullPolicy" .= ("Always" :: Text)
                                     , "stdin" .= True
                                     , "tty" .= False
                                     , "args"
                                         .= [ "credential-provisioner" :: Text
                                            , "run"
                                            , "--ingress-schema"
                                            , "external-acme-eab"
                                            , "--permit-id"
                                            , permitId
                                            , "--request-digest"
                                            , requestDigest
                                            , "--deadline-micros"
                                            , Text.pack (show deadlineMicros)
                                            , "--pod-uid-file"
                                            , "/var/run/secrets/prodbox/pod-uid"
                                            , "--service-account-token-file"
                                            , "/var/run/secrets/prodbox/token"
                                            ]
                                     , "securityContext"
                                         .= object
                                           [ "allowPrivilegeEscalation" .= False
                                           , "capabilities"
                                               .= object ["drop" .= ["ALL" :: Text]]
                                           , "readOnlyRootFilesystem" .= True
                                           ]
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
                                                [ "name" .= ("identity" :: Text)
                                                , "mountPath" .= ("/var/run/secrets/prodbox" :: Text)
                                                , "readOnly" .= True
                                                ]
                                            , object
                                                [ "name" .= ("runtime" :: Text)
                                                , "mountPath" .= ("/run/prodbox" :: Text)
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
                                     [ "name" .= ("identity" :: Text)
                                     , "projected"
                                         .= object
                                           [ "sources"
                                               .= [ object
                                                      [ "serviceAccountToken"
                                                          .= object
                                                            [ "path" .= ("token" :: Text)
                                                            , "audience" .= ("prodbox-control-plane" :: Text)
                                                            , "expirationSeconds" .= (600 :: Int)
                                                            ]
                                                      ]
                                                  , object
                                                      [ "downwardAPI"
                                                          .= object
                                                            [ "items"
                                                                .= [ object
                                                                       [ "path" .= ("pod-uid" :: Text)
                                                                       , "fieldRef"
                                                                           .= object
                                                                             [ "fieldPath" .= ("metadata.uid" :: Text)
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
              ]
        ]
    )
 where
  jobIntent = externalMaterialIngressJobIntent intent
  jobName = credentialProvisionerJobName jobIntent
  permitId =
    operatorMaterialPermitIdText (externalMaterialIngressIntentPermitId intent)
  requestDigest =
    targetValueDigestText
      (operatorMaterialRequestDigest (externalMaterialIngressIntentRequest intent))
  serviceAccount =
    credentialProvisionerServiceAccountText
      (credentialProvisionerIntentServiceAccount jobIntent)
  deadlineMicros = authorityTimeMicros (externalMaterialIngressIntentDeadline intent)
  activeDeadlineSeconds =
    max 1 (min 900 ((deadlineMicros - heartbeat + 999999) `div` 1000000))
  labels =
    object
      [ AesonKey.fromText name .= value
      | (name, value) <- Map.toList (externalJobLabels intent)
      ]
  annotations =
    object
      [ AesonKey.fromText name .= value
      | (name, value) <- Map.toList (externalJobAnnotations heartbeat intent)
      ]

externalJobLabels :: ExternalMaterialIngressIntent -> Map Text Text
externalJobLabels intent =
  Map.fromList
    [ ("app.kubernetes.io/name", "prodbox-external-material-ingress")
    , ("app.kubernetes.io/managed-by", "prodbox")
    , ("prodbox.io/ingress-schema", "external-acme-eab")
    ,
      ( "prodbox.io/permit-id"
      , operatorMaterialPermitIdText (externalMaterialIngressIntentPermitId intent)
      )
    ]

externalJobAnnotations
  :: Natural -> ExternalMaterialIngressIntent -> Map Text Text
externalJobAnnotations heartbeat intent =
  Map.fromList
    [
      ( "prodbox.io/request-digest"
      , targetValueDigestText
          (operatorMaterialRequestDigest (externalMaterialIngressIntentRequest intent))
      )
    ,
      ( "prodbox.io/deadline-micros"
      , Text.pack (show (authorityTimeMicros (externalMaterialIngressIntentDeadline intent)))
      )
    , ("prodbox.io/host-heartbeat-micros", Text.pack (show heartbeat))
    ]

credentialProvisionerCreateSubprocess
  :: CredentialProvisionerJobConnection -> Subprocess
credentialProvisionerCreateSubprocess connection =
  kubectl connection ["create", "--filename=-", "--output=json"]

credentialProvisionerObserveJobSubprocess
  :: CredentialProvisionerJobConnection
  -> CredentialProvisionerJobIntent 'ExternalAcmeEabIngress
  -> Subprocess
credentialProvisionerObserveJobSubprocess connection intent =
  kubectl connection ["get", "--raw=" ++ jobRawPath intent]

credentialProvisionerObserveSubprocess
  :: CredentialProvisionerJobConnection
  -> CredentialProvisionerJobIntent 'ExternalAcmeEabIngress
  -> Subprocess
credentialProvisionerObserveSubprocess connection intent =
  kubectl
    connection
    [ "get"
    , "pods"
    , "--selector=job-name=" ++ Text.unpack (credentialProvisionerJobName intent)
    , "--output=json"
    ]

credentialProvisionerAttachSubprocess
  :: CredentialProvisionerJobConnection
  -> ExternalMaterialJobAttestation
  -> Subprocess
credentialProvisionerAttachSubprocess connection attestation =
  kubectl
    connection
    [ "attach"
    , "--pod-running-timeout=10s"
    , "-i"
    , "pod/" ++ Text.unpack (externalMaterialJobPodName attestation)
    , "--container"
    , Text.unpack externalWorkerContainerName
    ]

credentialProvisionerLogsSubprocess
  :: CredentialProvisionerJobConnection
  -> ExternalMaterialJobAttestation
  -> Subprocess
credentialProvisionerLogsSubprocess connection attestation =
  kubectl
    connection
    [ "logs"
    , "pod/" ++ Text.unpack (externalMaterialJobPodName attestation)
    , "--container"
    , Text.unpack externalWorkerContainerName
    ]

credentialProvisionerDeleteSubprocess
  :: CredentialProvisionerJobConnection
  -> CredentialProvisionerJobIntent 'ExternalAcmeEabIngress
  -> CredentialProvisionerJobUid
  -> Subprocess
credentialProvisionerDeleteSubprocess connection intent _jobUid =
  kubectl
    connection
    [ "delete"
    , "--raw=" ++ jobRawPath intent
    , "--filename=-"
    ]

credentialProvisionerJobDeleteOptions :: CredentialProvisionerJobUid -> Value
credentialProvisionerJobDeleteOptions jobUid =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("DeleteOptions" :: Text)
    , "gracePeriodSeconds" .= (0 :: Natural)
    , "propagationPolicy" .= ("Background" :: Text)
    , "preconditions"
        .= object ["uid" .= credentialProvisionerJobUidText jobUid]
    ]

createCredentialProvisionerExternalJob
  :: CredentialProvisionerJobConnection
  -> Text
  -> Natural
  -> ExternalMaterialIngressIntent
  -> IO (Either CredentialProvisionerJobError CredentialProvisionerJobUid)
createCredentialProvisionerExternalJob connection imageRepository heartbeat intent =
  case renderCredentialProvisionerExternalJob imageRepository heartbeat intent of
    Left err -> pure (Left err)
    Right manifest -> do
      created <-
        captureSubprocessWithInputBounded
          createLimits
          (LazyByteString.toStrict (encode manifest))
          (credentialProvisionerCreateSubprocess connection)
      case created of
        Right output
          | processExitCode output == ExitSuccess ->
              case parseJobBinding intent (ByteString8.pack (processStdout output)) of
                Right jobUid -> pure (Right jobUid)
                Left _ -> recoverCreated
        _ -> recoverCreated
 where
  recoverCreated = do
    recovered <- recoverCredentialProvisionerExternalJob connection intent
    pure $ case recovered of
      Left err -> Left err
      Right CredentialProvisionerJobCreateStablyAbsent ->
        Left
          ( CredentialProvisionerJobCreateFailed
              "Job create was not recovered and stable absence was proven"
          )
      Right (CredentialProvisionerJobCreateRecovered jobUid) -> Right jobUid

recoverCredentialProvisionerExternalJob
  :: CredentialProvisionerJobConnection
  -> ExternalMaterialIngressIntent
  -> IO (Either CredentialProvisionerJobError CredentialProvisionerJobCreateRecovery)
recoverCredentialProvisionerExternalJob connection intent =
  recoverCredentialProvisionerExternalJobCreateWith
    createRecoveryAttempts
    (threadDelay createVisibilityGraceMicros)
    (threadDelay observationDelayMicros)
    (observeExactJob connection intent)

recoverCredentialProvisionerExternalJobCreateWith
  :: (Monad m)
  => Int
  -> m ()
  -> m ()
  -> m (Either CredentialProvisionerJobError (Maybe CredentialProvisionerJobUid))
  -> m (Either CredentialProvisionerJobError CredentialProvisionerJobCreateRecovery)
recoverCredentialProvisionerExternalJobCreateWith maximumAttempts waitVisibilityGrace waitRetry observe =
  seekCreate maximumAttempts
 where
  seekCreate remaining
    | remaining <= 0 =
        pure
          ( Left
              ( CredentialProvisionerJobRecoveryFailed
                  "Job absence could not be proven stable"
              )
          )
    | otherwise = do
        observed <- observe
        case observed of
          Right (Just jobUid) ->
            pure (Right (CredentialProvisionerJobCreateRecovered jobUid))
          Right Nothing
            | remaining <= 1 ->
                pure
                  ( Left
                      ( CredentialProvisionerJobRecoveryFailed
                          "Job absence could not be proven stable"
                      )
                  )
            | otherwise -> waitVisibilityGrace >> confirmAbsent (remaining - 1)
          Left err
            | remaining <= 1 -> pure (Left err)
            | otherwise -> waitRetry >> seekCreate (remaining - 1)

  confirmAbsent remaining = do
    observed <- observe
    case observed of
      Right (Just jobUid) ->
        pure (Right (CredentialProvisionerJobCreateRecovered jobUid))
      Right Nothing -> pure (Right CredentialProvisionerJobCreateStablyAbsent)
      Left err
        | remaining <= 1 -> pure (Left err)
        | otherwise -> waitRetry >> seekCreate (remaining - 1)

observeCredentialProvisionerExternalJob
  :: CredentialProvisionerJobConnection
  -> AuthorityTime
  -> ExternalMaterialIngressIntent
  -> CredentialProvisionerJobUid
  -> IO (Either CredentialProvisionerJobError ExternalMaterialJobAttestation)
observeCredentialProvisionerExternalJob connection now intent expectedJobUid =
  waitForAttestation observationAttempts
 where
  waitForAttestation remaining = do
    result <- observeAndAttestOnce connection now intent expectedJobUid
    case result of
      Right attested -> pure (Right attested)
      Left err
        | remaining <= 1 -> pure (Left err)
        | otherwise -> do
            threadDelay observationDelayMicros
            waitForAttestation (remaining - 1)

-- | Close a raw physical observation into the same opaque attestation used by
-- the production Kubernetes boundary.  The helper is intentionally pure and
-- repeats every intent/UID/image/ServiceAccount/deadline/heartbeat check; it
-- does not provide a constructor that can bypass attestation.
attestExternalMaterialJobObservation
  :: AuthorityTime
  -> ExternalMaterialIngressIntent
  -> Text
  -> RawCredentialProvisionerPodObservation
  -> Either CredentialProvisionerJobError ExternalMaterialJobAttestation
attestExternalMaterialJobObservation now externalIntent podName raw = do
  unless
    (not (Text.null (Text.strip podName)))
    (Left (CredentialProvisionerJobObservationFailed "Pod name is empty"))
  attested <-
    firstShow
      CredentialProvisionerJobAttestationFailed
      ( attestCredentialProvisionerPod
          now
          maximumHeartbeatAge
          (externalMaterialIngressJobIntent externalIntent)
          raw
      )
  pure
    ExternalMaterialJobAttestation
      { internalExternalMaterialJobPodName = Text.strip podName
      , internalExternalMaterialIngressIntent = externalIntent
      , internalExternalMaterialJobPodObservation = raw
      , internalExternalMaterialJobAttestation = attested
      }

attachCredentialProvisionerExternalIngress
  :: CredentialProvisionerJobConnection
  -> ExternalMaterialJobAttestation
  -> ByteString
  -> ByteString
  -> IO
       ( Either
           CredentialProvisionerJobError
           ExternalMaterialTargetReceipt
       )
attachCredentialProvisionerExternalIngress connection attestation encodedPermit ingressFrame = do
  case encodeExternalMaterialWorkerIngress
    ( credentialProvisionerAttestedPodUid
        (internalExternalMaterialJobAttestation attestation)
    )
    encodedPermit
    ingressFrame of
    Left err ->
      pure (Left (CredentialProvisionerJobIngressInvalid (Text.pack (show err))))
    Right frame -> do
      attached <-
        captureSubprocessWithInputBounded
          attachLimits
          frame
          (credentialProvisionerAttachSubprocess connection attestation)
      pure $ case attached of
        Left err -> Left (CredentialProvisionerJobAttachFailed (errorMsg err))
        Right output -> case processExitCode output of
          ExitFailure _ ->
            Left (CredentialProvisionerJobWorkerRefused (Text.pack (processStderr output)))
          ExitSuccess ->
            decodeReceiptForAttestation
              attestation
              (ByteString8.pack (processStdout output))

-- | Recover a secret-free receipt from the exact attested Pod's stdout after
-- an attach transport/response loss.  The worker emits the receipt only after
-- retained-custody read-back and terminal Vault-session cleanup, so logs are a
-- recovery channel for committed evidence, never for plaintext ingress.
recoverCredentialProvisionerExternalIngress
  :: CredentialProvisionerJobConnection
  -> ExternalMaterialJobAttestation
  -> IO (Either CredentialProvisionerJobError ExternalMaterialTargetReceipt)
recoverCredentialProvisionerExternalIngress connection attestation =
  waitForReceipt receiptRecoveryAttempts
 where
  waitForReceipt remaining = do
    attempted <-
      captureSubprocessBounded
        receiptRecoveryLimits
        (credentialProvisionerLogsSubprocess connection attestation)
    let result = case attempted of
          Left err -> Left (CredentialProvisionerJobAttachFailed (errorMsg err))
          Right output -> case processExitCode output of
            ExitFailure _ ->
              Left
                ( CredentialProvisionerJobAttachFailed
                    "exact Job Pod receipt log is not yet observable"
                )
            ExitSuccess ->
              decodeReceiptForAttestation
                attestation
                (ByteString8.pack (processStdout output))
    case result of
      Right receipt -> pure (Right receipt)
      Left err
        | remaining <= 1 -> pure (Left err)
        | otherwise -> threadDelay observationDelayMicros >> waitForReceipt (remaining - 1)

decodeReceiptForAttestation
  :: ExternalMaterialJobAttestation
  -> ByteString
  -> Either CredentialProvisionerJobError ExternalMaterialTargetReceipt
decodeReceiptForAttestation attestation bytes = do
  receipt <-
    firstShow
      CredentialProvisionerJobReceiptInvalid
      (decodeExternalMaterialTargetReceipt bytes)
  let intent = internalExternalMaterialIngressIntent attestation
      request = externalMaterialIngressIntentRequest intent
  unless
    ( externalMaterialTargetReceiptPermitId receipt
        == externalMaterialIngressIntentPermitId intent
        && externalMaterialTargetReceiptRequestDigest receipt
          == operatorMaterialRequestDigest request
        && externalMaterialTargetReceiptGeneration receipt
          == operatorMaterialRequestGeneration request
    )
    (Left (CredentialProvisionerJobReceiptInvalid "receipt does not match exact ingress intent"))
  pure receipt

deleteCredentialProvisionerExternalJob
  :: CredentialProvisionerJobConnection
  -> ExternalMaterialIngressIntent
  -> CredentialProvisionerJobUid
  -> IO (Either CredentialProvisionerJobError ())
deleteCredentialProvisionerExternalJob connection intent jobUid = do
  deleted <-
    captureSubprocessWithInputBounded
      deleteLimits
      (LazyByteString.toStrict (encode (credentialProvisionerJobDeleteOptions jobUid)))
      ( credentialProvisionerDeleteSubprocess
          connection
          (externalMaterialIngressJobIntent intent)
          jobUid
      )
  pure $ case deleted of
    Left err -> Left (CredentialProvisionerJobDeleteFailed (errorMsg err))
    Right output -> case processExitCode output of
      ExitSuccess -> Right ()
      ExitFailure _
        | isNotFound output -> Right ()
      ExitFailure _ ->
        Left (CredentialProvisionerJobDeleteFailed (Text.pack (processStderr output)))

observeCredentialProvisionerExternalJobAbsent
  :: CredentialProvisionerJobConnection
  -> ExternalMaterialIngressIntent
  -> CredentialProvisionerJobUid
  -> IO (Either CredentialProvisionerJobError ())
observeCredentialProvisionerExternalJobAbsent connection intent jobUid =
  seekFirstZero absenceAttempts
 where
  seekFirstZero remaining = do
    result <- observeExactJobAndPodsAbsent connection intent jobUid
    case result of
      Right True
        | remaining <= 1 -> pure (Left CredentialProvisionerJobStillPresent)
        | otherwise -> do
            threadDelay createVisibilityGraceMicros
            confirmZero (remaining - 1)
      Right False
        | remaining <= 1 -> pure (Left CredentialProvisionerJobStillPresent)
        | otherwise -> threadDelay observationDelayMicros >> seekFirstZero (remaining - 1)
      Left err
        | remaining <= 1 -> pure (Left err)
        | otherwise -> threadDelay observationDelayMicros >> seekFirstZero (remaining - 1)

  confirmZero remaining = do
    result <- observeExactJobAndPodsAbsent connection intent jobUid
    case result of
      Right True -> pure (Right ())
      Right False
        | remaining <= 1 -> pure (Left CredentialProvisionerJobStillPresent)
        | otherwise -> threadDelay observationDelayMicros >> seekFirstZero (remaining - 1)
      Left err
        | remaining <= 1 -> pure (Left err)
        | otherwise -> threadDelay observationDelayMicros >> seekFirstZero (remaining - 1)

data JobDto = JobDto
  { jobDtoName :: !Text
  , jobDtoNamespace :: !Text
  , jobDtoUid :: !Text
  , jobDtoLabels :: !(Map Text Text)
  , jobDtoAnnotations :: !(Map Text Text)
  , jobDtoDeletionTimestamp :: !(Maybe Text)
  , jobDtoTemplateLabels :: !(Map Text Text)
  , jobDtoTemplateAnnotations :: !(Map Text Text)
  , jobDtoServiceAccount :: !Text
  , jobDtoContainers :: ![ContainerDto]
  }

instance FromJSON JobDto where
  parseJSON = withObject "CredentialProvisionerJob" $ \value -> do
    metadata <- value .: "metadata"
    spec <- value .: "spec"
    template <- spec .: "template"
    templateMetadata <- template .: "metadata"
    templateSpec <- template .: "spec"
    JobDto
      <$> metadata .: "name"
      <*> metadata .: "namespace"
      <*> metadata .: "uid"
      <*> metadata .:? "labels" .!= Map.empty
      <*> metadata .:? "annotations" .!= Map.empty
      <*> metadata .:? "deletionTimestamp"
      <*> templateMetadata .:? "labels" .!= Map.empty
      <*> templateMetadata .:? "annotations" .!= Map.empty
      <*> templateSpec .: "serviceAccountName"
      <*> templateSpec .: "containers"

data PodListDto = PodListDto ![PodDto]

instance FromJSON PodListDto where
  parseJSON = withObject "CredentialProvisionerPodList" $ \value ->
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
  parseJSON = withObject "CredentialProvisionerPod" $ \value -> do
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
  parseJSON = withObject "CredentialProvisionerOwner" $ \value ->
    OwnerDto
      <$> value .: "kind"
      <*> value .: "name"
      <*> value .: "uid"
      <*> value .:? "controller" .!= False

data ServiceAccountDto = ServiceAccountDto !Text !Text !Text

instance FromJSON ServiceAccountDto where
  parseJSON = withObject "CredentialProvisionerServiceAccount" $ \value -> do
    metadata <- value .: "metadata"
    ServiceAccountDto
      <$> metadata .: "name"
      <*> metadata .: "namespace"
      <*> metadata .: "uid"

newtype ObjectUidDto = ObjectUidDto Text

instance FromJSON ObjectUidDto where
  parseJSON = withObject "CredentialProvisionerObject" $ \value -> do
    metadata <- value .: "metadata"
    ObjectUidDto <$> metadata .: "uid"

data ContainerDto = ContainerDto !Text !Text

instance FromJSON ContainerDto where
  parseJSON = withObject "CredentialProvisionerContainer" $ \value ->
    ContainerDto <$> value .: "name" <*> value .: "image"

data ContainerStatusDto = ContainerStatusDto !Text !Bool !Natural !Text

instance FromJSON ContainerStatusDto where
  parseJSON = withObject "CredentialProvisionerContainerStatus" $ \value ->
    ContainerStatusDto
      <$> value .: "name"
      <*> value .:? "ready" .!= False
      <*> value .:? "restartCount" .!= 0
      <*> value .:? "imageID" .!= ""

observeExactJob
  :: CredentialProvisionerJobConnection
  -> ExternalMaterialIngressIntent
  -> IO
       ( Either
           CredentialProvisionerJobError
           (Maybe CredentialProvisionerJobUid)
       )
observeExactJob connection intent = do
  attempted <-
    captureSubprocessBounded
      observeLimits
      ( credentialProvisionerObserveJobSubprocess
          connection
          (externalMaterialIngressJobIntent intent)
      )
  pure $ case attempted of
    Left err -> Left (CredentialProvisionerJobObservationFailed (errorMsg err))
    Right output -> case processExitCode output of
      ExitFailure _
        | isNotFound output -> Right Nothing
      ExitFailure _ ->
        Left (CredentialProvisionerJobObservationFailed "Job is not observable")
      ExitSuccess ->
        Just <$> parseJobBinding intent (ByteString8.pack (processStdout output))

parseJobBinding
  :: ExternalMaterialIngressIntent
  -> ByteString
  -> Either CredentialProvisionerJobError CredentialProvisionerJobUid
parseJobBinding intent bytes = do
  job <-
    firstShow
      CredentialProvisionerJobObservationFailed
      (eitherDecodeStrict' bytes :: Either String JobDto)
  let jobIntent = externalMaterialIngressJobIntent intent
      expectedLabels = externalJobLabels intent
  unless
    ( jobDtoName job == credentialProvisionerJobName jobIntent
        && jobDtoNamespace job == Text.pack credentialProvisionerNamespace
        && jobDtoDeletionTimestamp job == Nothing
    )
    (Left (CredentialProvisionerJobObservationFailed "Job identity is inconsistent"))
  heartbeat <-
    firstShow
      CredentialProvisionerJobObservationFailed
      (annotationNatural "prodbox.io/host-heartbeat-micros" (jobDtoAnnotations job))
  let expectedAnnotations = externalJobAnnotations heartbeat intent
  unless
    ( mapContains expectedLabels (jobDtoLabels job)
        && mapContains expectedLabels (jobDtoTemplateLabels job)
        && mapContains expectedAnnotations (jobDtoAnnotations job)
        && mapContains expectedAnnotations (jobDtoTemplateAnnotations job)
        && heartbeat > 0
        && heartbeat < authorityTimeMicros (externalMaterialIngressIntentDeadline intent)
    )
    (Left (CredentialProvisionerJobObservationFailed "Job intent metadata is inconsistent"))
  unless
    ( jobDtoServiceAccount job
        == credentialProvisionerServiceAccountText
          (credentialProvisionerIntentServiceAccount jobIntent)
    )
    (Left (CredentialProvisionerJobObservationFailed "Job ServiceAccount mismatch"))
  imageReference <- case findContainer externalWorkerContainerName (jobDtoContainers job) of
    Nothing -> Left (CredentialProvisionerJobObservationFailed "Job worker container is missing")
    Just (ContainerDto _ reference) -> Right reference
  unless
    (not (Text.null (Text.strip imageReference)))
    (Left (CredentialProvisionerJobObservationFailed "Job image reference is empty"))
  firstShow
    CredentialProvisionerJobObservationFailed
    (mkCredentialProvisionerJobUid (jobDtoUid job))

observeAndAttestOnce
  :: CredentialProvisionerJobConnection
  -> AuthorityTime
  -> ExternalMaterialIngressIntent
  -> CredentialProvisionerJobUid
  -> IO (Either CredentialProvisionerJobError ExternalMaterialJobAttestation)
observeAndAttestOnce connection now externalIntent expectedJobUid = do
  observedJob <- observeExactJob connection externalIntent
  case observedJob of
    Left err -> pure (Left err)
    Right Nothing ->
      pure (Left (CredentialProvisionerJobObservationFailed "exact Job is absent"))
    Right (Just actualJobUid)
      | actualJobUid /= expectedJobUid ->
          pure (Left (CredentialProvisionerJobObservationFailed "Job UID was replaced"))
      | otherwise -> do
          observedPods <-
            captureSubprocessBounded
              observeLimits
              ( credentialProvisionerObserveSubprocess
                  connection
                  (externalMaterialIngressJobIntent externalIntent)
              )
          case observedPods of
            Left err ->
              pure (Left (CredentialProvisionerJobObservationFailed (errorMsg err)))
            Right output -> case processExitCode output of
              ExitFailure _ ->
                pure
                  ( Left
                      ( CredentialProvisionerJobObservationFailed
                          "Job Pod is not observable"
                      )
                  )
              ExitSuccess -> case decodePodList (ByteString8.pack (processStdout output)) of
                Left detail -> pure (Left (CredentialProvisionerJobObservationFailed detail))
                Right [pod] -> do
                  serviceAccountUid <- observeServiceAccountUid connection externalIntent
                  pure $ do
                    exactServiceAccountUid <- serviceAccountUid
                    raw <-
                      firstShow
                        CredentialProvisionerJobObservationFailed
                        ( podObservation
                            externalIntent
                            expectedJobUid
                            exactServiceAccountUid
                            pod
                        )
                    attestExternalMaterialJobObservation
                      now
                      externalIntent
                      (podDtoName pod)
                      raw
                Right [] ->
                  pure (Left (CredentialProvisionerJobObservationFailed "Job has no Pod"))
                Right _ ->
                  pure (Left (CredentialProvisionerJobObservationFailed "Job has multiple Pods"))

observeServiceAccountUid
  :: CredentialProvisionerJobConnection
  -> ExternalMaterialIngressIntent
  -> IO (Either CredentialProvisionerJobError CredentialProvisionerServiceAccountUid)
observeServiceAccountUid connection intent = do
  attempted <-
    captureSubprocessBounded
      observeLimits
      (kubectl connection ["get", "--raw=" ++ serviceAccountRawPath jobIntent])
  pure $ case attempted of
    Left err -> Left (CredentialProvisionerJobObservationFailed (errorMsg err))
    Right output -> case processExitCode output of
      ExitFailure _ ->
        Left (CredentialProvisionerJobObservationFailed "ServiceAccount is not observable")
      ExitSuccess -> do
        ServiceAccountDto name namespace uid <-
          firstShow
            CredentialProvisionerJobObservationFailed
            (eitherDecodeStrict' (ByteString8.pack (processStdout output)))
        unless
          ( name
              == credentialProvisionerServiceAccountText
                (credentialProvisionerIntentServiceAccount jobIntent)
              && namespace == Text.pack credentialProvisionerNamespace
          )
          (Left (CredentialProvisionerJobObservationFailed "ServiceAccount identity mismatch"))
        firstShow
          CredentialProvisionerJobObservationFailed
          (mkCredentialProvisionerServiceAccountUid uid)
 where
  jobIntent = externalMaterialIngressJobIntent intent

decodePodList :: ByteString -> Either Text [PodDto]
decodePodList bytes = case eitherDecodeStrict' bytes of
  Left _ -> Left "Kubernetes Pod-list response is invalid"
  Right (PodListDto pods) -> Right pods

podObservation
  :: ExternalMaterialIngressIntent
  -> CredentialProvisionerJobUid
  -> CredentialProvisionerServiceAccountUid
  -> PodDto
  -> Either Text RawCredentialProvisionerPodObservation
podObservation externalIntent expectedJobUid serviceAccountUid pod = do
  unless
    ( Map.lookup "job-name" (podDtoLabels pod)
        == Just (credentialProvisionerJobName jobIntent)
    )
    (Left "Pod Job ownership label mismatch")
  ownerUid <- case filter controllingJob (podDtoOwners pod) of
    [OwnerDto _ _ uid _] -> Right uid
    _ -> Left "Pod has no unique controlling Job owner"
  unless
    (ownerUid == credentialProvisionerJobUidText expectedJobUid)
    (Left "Pod controlling Job UID mismatch")
  imageReference <- case findContainer externalWorkerContainerName (podDtoContainers pod) of
    Nothing -> Left "external-material container is missing"
    Just (ContainerDto _ reference) -> Right reference
  unless (not (Text.null (Text.strip imageReference))) (Left "container image reference is empty")
  runtimeImageId <- case findStatus externalWorkerContainerName (podDtoContainerStatuses pod) of
    Nothing -> Left "external-material container status is missing"
    Just (ContainerStatusDto _ _ _ observedImageId) -> Right observedImageId
  digest <-
    maybe (Left "container runtime image identity is invalid") Right (runtimeImageDigest runtimeImageId)
  unless
    ( digest
        == credentialProvisionerImageDigestText
          (externalMaterialIngressIntentImageDigest externalIntent)
    )
    (Left "container image digest mismatch")
  permitId <- annotation "prodbox.io/permit-id"
  requestDigestText <- annotation "prodbox.io/request-digest"
  requestDigest <-
    either
      (const (Left "request digest annotation is invalid"))
      Right
      (mkTargetValueDigest requestDigestText)
  deadline <- naturalAnnotation "prodbox.io/deadline-micros"
  heartbeat <- naturalAnnotation "prodbox.io/host-heartbeat-micros"
  traverse_ requireLabel (Map.toList (externalJobLabels externalIntent))
  traverse_ requireAnnotation (Map.toList (externalJobAnnotations heartbeat externalIntent))
  let (ready, restarts) = case findStatus externalWorkerContainerName (podDtoContainerStatuses pod) of
        Nothing -> (False, 0)
        Just (ContainerStatusDto _ isReady count _) -> (isReady, count)
  pure
    RawCredentialProvisionerPodObservation
      { rawCredentialProvisionerJobName = credentialProvisionerJobName jobIntent
      , rawCredentialProvisionerJobUid = credentialProvisionerJobUidText expectedJobUid
      , rawCredentialProvisionerPodUid = podDtoUid pod
      , rawCredentialProvisionerImageDigest = digest
      , rawCredentialProvisionerServiceAccount = podDtoServiceAccount pod
      , rawCredentialProvisionerServiceAccountUid =
          credentialProvisionerServiceAccountUidText serviceAccountUid
      , rawCredentialProvisionerSchema = ExternalAcmeEabIngress
      , rawCredentialProvisionerPermitId = permitId
      , rawCredentialProvisionerRequestDigest = requestDigest
      , rawCredentialProvisionerPlanBinding = Nothing
      , rawCredentialProvisionerDeadline =
          authorityTimeFromMicros deadline
      , rawCredentialProvisionerHeartbeat =
          authorityTimeFromMicros heartbeat
      , rawCredentialProvisionerPhase = podDtoPhase pod
      , rawCredentialProvisionerContainerReady = ready
      , rawCredentialProvisionerRestartCount = restarts
      , rawCredentialProvisionerDeletionTimestamp = podDtoDeletionTimestamp pod
      }
 where
  jobIntent = externalMaterialIngressJobIntent externalIntent
  controllingJob (OwnerDto kind name _ controller) =
    kind == "Job" && name == credentialProvisionerJobName jobIntent && controller
  annotation name =
    maybe (Left ("Pod annotation is missing: " <> name)) Right (Map.lookup name (podDtoAnnotations pod))
  naturalAnnotation name = do
    value <- annotation name
    maybe (Left ("Pod annotation is not a natural: " <> name)) Right (readMaybe (Text.unpack value))
  requireLabel (name, expected) =
    unless (Map.lookup name (podDtoLabels pod) == Just expected) (Left ("Pod label mismatch: " <> name))
  requireAnnotation (name, expected) =
    unless
      (Map.lookup name (podDtoAnnotations pod) == Just expected)
      (Left ("Pod annotation mismatch: " <> name))

observeExactJobAndPodsAbsent
  :: CredentialProvisionerJobConnection
  -> ExternalMaterialIngressIntent
  -> CredentialProvisionerJobUid
  -> IO (Either CredentialProvisionerJobError Bool)
observeExactJobAndPodsAbsent connection intent jobUid = do
  jobAbsent <- observeExactUidAbsent connection (jobRawPath jobIntent) expectedUid
  podsAbsent <- observeOwnedPodsAbsent connection jobIntent expectedUid
  pure ((&&) <$> jobAbsent <*> podsAbsent)
 where
  jobIntent = externalMaterialIngressJobIntent intent
  expectedUid = credentialProvisionerJobUidText jobUid

observeExactUidAbsent
  :: CredentialProvisionerJobConnection
  -> String
  -> Text
  -> IO (Either CredentialProvisionerJobError Bool)
observeExactUidAbsent connection rawPath expectedUid = do
  attempted <-
    captureSubprocessBounded
      observeLimits
      (kubectl connection ["get", "--raw=" ++ rawPath])
  pure $ case attempted of
    Left err -> Left (CredentialProvisionerJobAbsenceUnobservable (errorMsg err))
    Right output -> case processExitCode output of
      ExitFailure _
        | isNotFound output -> Right True
      ExitFailure _ ->
        Left (CredentialProvisionerJobAbsenceUnobservable "exact Job is unobservable")
      ExitSuccess -> do
        ObjectUidDto currentUid <-
          firstShow
            CredentialProvisionerJobAbsenceUnobservable
            (eitherDecodeStrict' (ByteString8.pack (processStdout output)))
        pure (currentUid /= expectedUid)

observeOwnedPodsAbsent
  :: CredentialProvisionerJobConnection
  -> CredentialProvisionerJobIntent 'ExternalAcmeEabIngress
  -> Text
  -> IO (Either CredentialProvisionerJobError Bool)
observeOwnedPodsAbsent connection intent expectedJobUid = do
  attempted <-
    captureSubprocessBounded
      observeLimits
      (credentialProvisionerObserveSubprocess connection intent)
  pure $ case attempted of
    Left err -> Left (CredentialProvisionerJobAbsenceUnobservable (errorMsg err))
    Right output -> case processExitCode output of
      ExitFailure _ ->
        Left (CredentialProvisionerJobAbsenceUnobservable "Job Pods are unobservable")
      ExitSuccess -> do
        pods <-
          firstShow
            CredentialProvisionerJobAbsenceUnobservable
            (decodePodList (ByteString8.pack (processStdout output)))
        pure (not (any (ownedByExactJob expectedJobUid) pods))

ownedByExactJob :: Text -> PodDto -> Bool
ownedByExactJob expectedJobUid pod =
  any exactOwner (podDtoOwners pod)
 where
  exactOwner (OwnerDto kind _ uid controller) =
    kind == "Job" && uid == expectedJobUid && controller

mapContains :: Map Text Text -> Map Text Text -> Bool
mapContains expected actual =
  all (\(name, value) -> Map.lookup name actual == Just value) (Map.toList expected)

annotationNatural :: Text -> Map Text Text -> Either Text Natural
annotationNatural name annotations = do
  value <-
    maybe
      (Left ("annotation is missing: " <> name))
      Right
      (Map.lookup name annotations)
  maybe
    (Left ("annotation is not a natural: " <> name))
    Right
    (readMaybe (Text.unpack value))

jobRawPath :: CredentialProvisionerJobIntent 'ExternalAcmeEabIngress -> String
jobRawPath intent =
  "/apis/batch/v1/namespaces/"
    ++ credentialProvisionerNamespace
    ++ "/jobs/"
    ++ Text.unpack (credentialProvisionerJobName intent)

serviceAccountRawPath
  :: CredentialProvisionerJobIntent 'ExternalAcmeEabIngress -> String
serviceAccountRawPath intent =
  "/api/v1/namespaces/"
    ++ credentialProvisionerNamespace
    ++ "/serviceaccounts/"
    ++ Text.unpack
      ( credentialProvisionerServiceAccountText
          (credentialProvisionerIntentServiceAccount intent)
      )

-- | Sprint 4.78: keyed through the one owner, and scoped to __stderr__.
-- It used to match against @stdout <> stderr@, so a kubectl command that
-- succeeded and printed an object whose own content contained @not found@ —
-- a ConfigMap value, a container log line, a condition message — was read as
-- the object being absent.
isNotFound :: ProcessOutput -> Bool
isNotFound output = reportsAbsence KubernetesObjectProbe (processStderr output)

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

kubectl :: CredentialProvisionerJobConnection -> [String] -> Subprocess
kubectl connection arguments =
  Subprocess
    { subprocessPath = "kubectl"
    , subprocessArguments =
        ["--namespace", credentialProvisionerNamespace] <> arguments
    , subprocessEnvironment = credentialProvisionerJobEnvironment connection
    , subprocessWorkingDirectory =
        Just (credentialProvisionerJobWorkingDirectory connection)
    }

firstShow
  :: (Show errorValue)
  => (Text -> CredentialProvisionerJobError)
  -> Either errorValue value
  -> Either CredentialProvisionerJobError value
firstShow wrap = either (Left . wrap . Text.pack . show) Right

maximumHeartbeatAge :: Natural
maximumHeartbeatAge = 30 * 1000000

observationAttempts :: Int
observationAttempts = 240

absenceAttempts :: Int
absenceAttempts = 240

createRecoveryAttempts :: Int
createRecoveryAttempts = 12

receiptRecoveryAttempts :: Int
receiptRecoveryAttempts = 40

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
    { boundedSubprocessMaximumInputBytes = 64 * 1024
    , boundedSubprocessMaximumStdoutBytes = 16 * 1024
    , boundedSubprocessMaximumStderrBytes = 16 * 1024
    , boundedSubprocessTimeoutMicros = 10 * 60 * 1000 * 1000
    }

receiptRecoveryLimits :: BoundedSubprocessLimits
receiptRecoveryLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = 16 * 1024
    , boundedSubprocessMaximumStderrBytes = 16 * 1024
    , boundedSubprocessTimeoutMicros = 10 * 1000 * 1000
    }

deleteLimits :: BoundedSubprocessLimits
deleteLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = 64 * 1024
    , boundedSubprocessMaximumStderrBytes = 16 * 1024
    , boundedSubprocessTimeoutMicros = 30 * 1000 * 1000
    }
