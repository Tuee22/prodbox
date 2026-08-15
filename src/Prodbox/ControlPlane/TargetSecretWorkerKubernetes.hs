{-# LANGUAGE OverloadedStrings #-}

-- | Exact Kubernetes Job for a Target materializer.  The manifest contains
-- only signed-intent metadata; target material is attached later to the
-- attested Pod's stdin.
module Prodbox.ControlPlane.TargetSecretWorkerKubernetes
  ( targetWorkerContainerName
  , targetWorkerAnnotations
  , renderTargetSecretWorkerJob
  , targetWorkerPodDeleteOptions
  )
where

import Control.Monad (unless)
import Data.Aeson (Value, object, (.=))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( targetSecretIdToken
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( targetAgentIdentityText
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerIntent
  , TargetWorkerPodUid
  , targetWorkerImageDigestText
  , targetWorkerIntentAgentIdentity
  , targetWorkerIntentDeadline
  , targetWorkerIntentImageDigest
  , targetWorkerIntentJobName
  , targetWorkerIntentRequestDigest
  , targetWorkerIntentSchema
  , targetWorkerIntentServiceAccount
  , targetWorkerIntentTarget
  , targetWorkerPodUidText
  , targetWorkerSchemaToken
  )
import Prodbox.Lifecycle.Lease (authorityTimeMicros)
import Prodbox.Lifecycle.TargetCommitIntent (targetValueDigestText)

targetWorkerContainerName :: Text
targetWorkerContainerName = "target-secret-worker"

targetWorkerAnnotations :: TargetWorkerIntent -> Map Text Text
targetWorkerAnnotations intent =
  Map.fromList
    [ ("target.prodbox.dev/target", targetSecretIdToken (targetWorkerIntentTarget intent))
    ,
      ( "target.prodbox.dev/agent-identity"
      , targetAgentIdentityText (targetWorkerIntentAgentIdentity intent)
      )
    ,
      ( "target.prodbox.dev/material-schema"
      , targetWorkerSchemaToken (targetWorkerIntentSchema intent)
      )
    ,
      ( "target.prodbox.dev/request-digest"
      , targetValueDigestText (targetWorkerIntentRequestDigest intent)
      )
    ,
      ( "target.prodbox.dev/deadline-micros"
      , Text.pack (show (authorityTimeMicros (targetWorkerIntentDeadline intent)))
      )
    ]

renderTargetSecretWorkerJob
  :: Text
  -> Natural
  -> TargetWorkerIntent
  -> Either Text Value
renderTargetSecretWorkerJob imageRepository maximumRuntimeSeconds intent = do
  unless
    (not (Text.null (Text.strip imageRepository)))
    (Left "target worker image repository is empty")
  unless
    (maximumRuntimeSeconds > 0 && maximumRuntimeSeconds <= 600)
    (Left "target worker active deadline must be between 1 and 600 seconds")
  pure
    ( object
        [ "apiVersion" .= ("batch/v1" :: Text)
        , "kind" .= ("Job" :: Text)
        , "metadata"
            .= object
              [ "name" .= targetWorkerIntentJobName intent
              , "namespace" .= ("target-secret-agent" :: Text)
              , "labels" .= labels
              , "annotations" .= targetWorkerAnnotations intent
              ]
        , "spec"
            .= object
              [ "backoffLimit" .= (0 :: Natural)
              , "completions" .= (1 :: Natural)
              , "parallelism" .= (1 :: Natural)
              , "activeDeadlineSeconds" .= maximumRuntimeSeconds
              , "ttlSecondsAfterFinished" .= (30 :: Natural)
              , "template"
                  .= object
                    [ "metadata"
                        .= object
                          [ "labels" .= labels
                          , "annotations" .= targetWorkerAnnotations intent
                          ]
                    , "spec"
                        .= object
                          [ "serviceAccountName" .= targetWorkerIntentServiceAccount intent
                          , "automountServiceAccountToken" .= False
                          , "restartPolicy" .= ("Never" :: Text)
                          , "terminationGracePeriodSeconds" .= (0 :: Natural)
                          , "securityContext"
                              .= object
                                [ "runAsNonRoot" .= True
                                , "seccompProfile" .= object ["type" .= ("RuntimeDefault" :: Text)]
                                ]
                          , "containers"
                              .= [ object
                                     [ "name" .= targetWorkerContainerName
                                     , "image" .= workerImage
                                     , "imagePullPolicy" .= ("Always" :: Text)
                                     , "stdin" .= True
                                     , "stdinOnce" .= True
                                     , "tty" .= False
                                     , "args" .= workerArguments
                                     , "securityContext"
                                         .= object
                                           [ "allowPrivilegeEscalation" .= False
                                           , "readOnlyRootFilesystem" .= True
                                           , "capabilities" .= object ["drop" .= ["ALL" :: Text]]
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
                                            , object
                                                [ "name" .= ("kube-api-identity" :: Text)
                                                , "mountPath"
                                                    .= ( "/var/run/secrets/kubernetes.io/serviceaccount"
                                                           :: Text
                                                       )
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
                                     [ "name" .= ("identity" :: Text)
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
                                                                .= [ downwardItem "pod-uid" "metadata.uid"
                                                                   , downwardItem "pod-name" "metadata.name"
                                                                   ]
                                                            ]
                                                      ]
                                                  ]
                                           ]
                                     ]
                                 , object
                                     [ "name" .= ("kube-api-identity" :: Text)
                                     , "projected"
                                         .= object
                                           [ "sources"
                                               .= [ object
                                                      [ "serviceAccountToken"
                                                          .= object
                                                            [ "path" .= ("token" :: Text)
                                                            , "expirationSeconds" .= (600 :: Natural)
                                                            ]
                                                      ]
                                                  , object
                                                      [ "configMap"
                                                          .= object
                                                            [ "name" .= ("kube-root-ca.crt" :: Text)
                                                            , "items"
                                                                .= [ object
                                                                       [ "key" .= ("ca.crt" :: Text)
                                                                       , "path" .= ("ca.crt" :: Text)
                                                                       ]
                                                                   ]
                                                            ]
                                                      ]
                                                  , object
                                                      [ "downwardAPI"
                                                          .= object
                                                            [ "items"
                                                                .= [ downwardItem
                                                                       "namespace"
                                                                       "metadata.namespace"
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
  labels =
    object
      [ "app.kubernetes.io/name" .= ("prodbox-target-secret-worker" :: Text)
      , "prodbox.io/target-worker-job" .= targetWorkerIntentJobName intent
      ]
  workerImage = Text.strip imageRepository
  workerArguments =
    [ "credential-provisioner" :: Text
    , "target-worker"
    , "--target"
    , targetSecretIdToken (targetWorkerIntentTarget intent)
    , "--target-agent-identity"
    , targetAgentIdentityText (targetWorkerIntentAgentIdentity intent)
    , "--material-schema"
    , targetWorkerSchemaToken (targetWorkerIntentSchema intent)
    , "--image-digest"
    , targetWorkerImageDigestText (targetWorkerIntentImageDigest intent)
    , "--request-digest"
    , targetValueDigestText (targetWorkerIntentRequestDigest intent)
    , "--deadline-micros"
    , Text.pack (show (authorityTimeMicros (targetWorkerIntentDeadline intent)))
    , "--pod-uid-file"
    , "/var/run/secrets/prodbox/pod-uid"
    , "--pod-name-file"
    , "/var/run/secrets/prodbox/pod-name"
    , "--service-account-token-file"
    , "/var/run/secrets/prodbox/token"
    ]

downwardItem :: Text -> Text -> Value
downwardItem path fieldPath =
  object
    [ "path" .= path
    , "fieldRef" .= object ["fieldPath" .= fieldPath]
    ]

-- | UID-preconditioned Pod delete body.  A replacement occupying the same
-- deterministic name cannot be deleted by a stale cleanup attempt.
targetWorkerPodDeleteOptions :: TargetWorkerPodUid -> Value
targetWorkerPodDeleteOptions podUid =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("DeleteOptions" :: Text)
    , "gracePeriodSeconds" .= (0 :: Natural)
    , "propagationPolicy" .= ("Background" :: Text)
    , "preconditions"
        .= object ["uid" .= targetWorkerPodUidText podUid]
    ]
