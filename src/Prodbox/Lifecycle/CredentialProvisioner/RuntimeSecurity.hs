{-# LANGUAGE OverloadedStrings #-}

-- | Shared Kubernetes runtime identity for permit-bound Credential Provisioner
-- Jobs. The union image remains role-neutral; each Job owns its non-root
-- identity explicitly.
module Prodbox.Lifecycle.CredentialProvisioner.RuntimeSecurity
  ( credentialProvisionerKubernetesApiVolume
  , credentialProvisionerKubernetesApiVolumeMount
  , credentialProvisionerPodSecurityContext
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Int (Int64)
import Data.Text (Text)

runtimeIdentity :: Int64
runtimeIdentity = 65532

credentialProvisionerPodSecurityContext :: Value
credentialProvisionerPodSecurityContext =
  object
    [ "runAsNonRoot" .= True
    , "runAsUser" .= runtimeIdentity
    , "runAsGroup" .= runtimeIdentity
    , "fsGroup" .= runtimeIdentity
    , "fsGroupChangePolicy" .= ("OnRootMismatch" :: Text)
    , "seccompProfile" .= object ["type" .= ("RuntimeDefault" :: Text)]
    ]

-- | Explicit in-cluster Kubernetes client identity for the AWS-admin worker.
-- The distinct @prodbox-control-plane@ token remains mounted at its own path
-- for Vault login.  Keeping automount disabled and projecting only these
-- standard client files prevents either token from being reused for the other
-- trust boundary.
credentialProvisionerKubernetesApiVolumeMount :: Value
credentialProvisionerKubernetesApiVolumeMount =
  object
    [ "name" .= ("kubernetes-api-identity" :: Text)
    , "mountPath" .= ("/var/run/secrets/kubernetes.io/serviceaccount" :: Text)
    , "readOnly" .= True
    ]

credentialProvisionerKubernetesApiVolume :: Value
credentialProvisionerKubernetesApiVolume =
  object
    [ "name" .= ("kubernetes-api-identity" :: Text)
    , "projected"
        .= object
          [ "sources"
              .= [ object
                     [ "serviceAccountToken"
                         .= object
                           [ "path" .= ("token" :: Text)
                           , "expirationSeconds" .= (600 :: Int)
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
                               .= [ object
                                      [ "path" .= ("namespace" :: Text)
                                      , "fieldRef"
                                          .= object
                                            [ "fieldPath" .= ("metadata.namespace" :: Text)
                                            ]
                                      ]
                                  ]
                           ]
                     ]
                 ]
          ]
    ]
