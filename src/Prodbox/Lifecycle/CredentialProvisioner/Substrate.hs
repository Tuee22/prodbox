{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The non-secret Kubernetes substrate required before a permit-created
-- Credential Provisioner Job can exist.  The substrate contains no workload
-- and no credential material; Jobs remain separate, short-lived effects.
module Prodbox.Lifecycle.CredentialProvisioner.Substrate
  ( CredentialProvisionerSubstrateBoundary (..)
  , CredentialProvisionerSubstrateError (..)
  , credentialProvisionerSubstrateManifest
  , credentialProvisionerSubstrateMatches
  , credentialProvisionerSubstrateObjectCount
  , productionCredentialProvisionerSubstrateBoundary
  , reconcileCredentialProvisionerSubstrate
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.ControlPlane.ListenPort (controlPlaneListenPort)
import Prodbox.Lib.ChartPlatform
  ( KubernetesApiEgressCoordinate (..)
  )
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import System.Exit (ExitCode (..))

data CredentialProvisionerSubstrateBoundary m = CredentialProvisionerSubstrateBoundary
  { applyCredentialProvisionerSubstrate :: Value -> m (Either Text ())
  , observeCredentialProvisionerSubstrate :: Value -> m (Either Text Bool)
  }

data CredentialProvisionerSubstrateError
  = CredentialProvisionerSubstrateObservationUnavailable !Text
  | CredentialProvisionerSubstrateDrifted
  deriving stock (Eq, Show)

credentialProvisionerSubstrateObjectCount :: Int
credentialProvisionerSubstrateObjectCount = 9

credentialProvisionerSubstrateManifest :: KubernetesApiEgressCoordinate -> Value
credentialProvisionerSubstrateManifest apiCoordinate =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("List" :: Text)
    , "items"
        .= [ namespaceObject
           , serviceAccountObject awsAdminServiceAccount
           , serviceAccountObject externalMaterialServiceAccount
           , controllerRoleObject
           , controllerRoleBindingObject
           , authorityObserverRoleObject
           , authorityObserverRoleBindingObject
           , awsAdminNetworkPolicyObject apiCoordinate
           , externalMaterialNetworkPolicyObject
           ]
    ]

reconcileCredentialProvisionerSubstrate
  :: (Monad m)
  => KubernetesApiEgressCoordinate
  -> CredentialProvisionerSubstrateBoundary m
  -> m (Either CredentialProvisionerSubstrateError ())
reconcileCredentialProvisionerSubstrate apiCoordinate boundary = do
  let desired = credentialProvisionerSubstrateManifest apiCoordinate
  -- An apply response is provisional.  A lost response that landed is a
  -- success only when the independent observation sees the exact manifest.
  _ <- applyCredentialProvisionerSubstrate boundary desired
  observed <-
    observeCredentialProvisionerSubstrate boundary desired
  pure $ case observed of
    Left detail -> Left (CredentialProvisionerSubstrateObservationUnavailable detail)
    Right False -> Left CredentialProvisionerSubstrateDrifted
    Right True -> Right ()

productionCredentialProvisionerSubstrateBoundary
  :: FilePath -> CredentialProvisionerSubstrateBoundary IO
productionCredentialProvisionerSubstrateBoundary repoRoot =
  CredentialProvisionerSubstrateBoundary
    { applyCredentialProvisionerSubstrate = runApply
    , observeCredentialProvisionerSubstrate = runObservation
    }
 where
  runApply manifest = do
    attempted <- runKubectl manifest ["apply", "--filename=-"]
    pure $ case attempted of
      Left detail -> Left detail
      Right output -> case processExitCode output of
        ExitSuccess -> Right ()
        ExitFailure _ -> Left (processDetail output)

  -- Read back the exact object keys independently of the apply response.
  -- The pure comparison includes every desired field while excluding only
  -- server-owned metadata and status that are absent from the desired value.
  runObservation manifest = do
    attempted <-
      runKubectl
        manifest
        [ "get"
        , "--filename=-"
        , "--output=json"
        , "--ignore-not-found=true"
        ]
    pure $ case attempted of
      Left detail -> Left detail
      Right output -> case processExitCode output of
        ExitSuccess ->
          case eitherDecodeStrict' (ByteString.pack (processStdout output)) of
            Left detail -> Left ("invalid Kubernetes observation: " <> Text.pack detail)
            Right observed -> Right (credentialProvisionerSubstrateMatches manifest observed)
        ExitFailure _ -> Left (processDetail output)

  runKubectl manifest arguments = do
    attempted <-
      captureSubprocessWithInputBounded
        substrateLimits
        (LazyByteString.toStrict (encode manifest))
        Subprocess
          { subprocessPath = "kubectl"
          , subprocessArguments = arguments
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just repoRoot
          }
    pure (either (Left . fromString . show) Right attempted)

fromString :: String -> Text
fromString = Text.pack

processDetail :: ProcessOutput -> Text
processDetail output =
  Text.pack
    ( if null (processStderr output)
        then processStdout output
        else processStderr output
    )

substrateLimits :: BoundedSubprocessLimits
substrateLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 256 * 1024
    , boundedSubprocessMaximumStdoutBytes = 256 * 1024
    , boundedSubprocessMaximumStderrBytes = 256 * 1024
    , boundedSubprocessTimeoutMicros = 60 * 1000000
    }

-- | Compare the desired fields of the exact requested object keys.  Kubernetes
-- may add metadata such as resourceVersion, uid, generation, and status; those
-- fields do not belong to this desired-state projection.  Arrays within a
-- desired object remain ordered and exact.
credentialProvisionerSubstrateMatches :: Value -> Value -> Bool
credentialProvisionerSubstrateMatches desired observed =
  case (keyedManifestItems desired, keyedManifestItems observed) of
    (Just desiredItems, Just observedItems) ->
      Map.keysSet desiredItems == Map.keysSet observedItems
        && all
          ( \(key, desiredItem) ->
              maybe
                False
                (desiredProjectionMatches desiredItem)
                (Map.lookup key observedItems)
          )
          (Map.toList desiredItems)
    _ -> False

type SubstrateObjectKey = (Text, Text, Text)

keyedManifestItems :: Value -> Maybe (Map SubstrateObjectKey Value)
keyedManifestItems manifest = do
  items <- manifestItems manifest
  pairs <-
    traverse
      ( \item -> do
          key <- substrateObjectKey item
          pure (key, item)
      )
      items
  let keyed = Map.fromList pairs
  if Map.size keyed == length pairs then Just keyed else Nothing

manifestItems :: Value -> Maybe [Value]
manifestItems (Object manifest) = case KeyMap.lookup "items" manifest of
  Just (Array items) -> Just (Vector.toList items)
  _ -> Nothing
manifestItems _ = Nothing

substrateObjectKey :: Value -> Maybe SubstrateObjectKey
substrateObjectKey (Object item) = do
  String kind <- KeyMap.lookup "kind" item
  Object metadata <- KeyMap.lookup "metadata" item
  String name <- KeyMap.lookup "name" metadata
  namespace <- case KeyMap.lookup "namespace" metadata of
    Nothing -> Just ""
    Just (String value) -> Just value
    Just _ -> Nothing
  pure (kind, namespace, name)
substrateObjectKey _ = Nothing

desiredProjectionMatches :: Value -> Value -> Bool
desiredProjectionMatches (Object desired) (Object observed) =
  all (desiredFieldMatches observed) (KeyMap.toList desired)
desiredProjectionMatches (Array desired) (Array observed) =
  Vector.length desired == Vector.length observed
    && and (Vector.zipWith desiredProjectionMatches desired observed)
desiredProjectionMatches desired observed = desired == observed

desiredFieldMatches :: KeyMap.KeyMap Value -> (Key, Value) -> Bool
desiredFieldMatches observed (key, desiredValue) =
  case KeyMap.lookup key observed of
    Nothing -> desiredValue == Array Vector.empty
    Just observedValue -> desiredProjectionMatches desiredValue observedValue

credentialProvisionerNamespace :: Text
credentialProvisionerNamespace = "credential-provisioner"

awsAdminServiceAccount :: Text
awsAdminServiceAccount = "prodbox-credential-provisioner"

externalMaterialServiceAccount :: Text
externalMaterialServiceAccount = "prodbox-external-material-ingress"

controllerRoleName :: Text
controllerRoleName = "prodbox-credential-provisioner-controller"

authorityObserverRoleName :: Text
authorityObserverRoleName = "prodbox-credential-provisioner-authority-observer"

commonLabels :: Value
commonLabels =
  object
    [ "app.kubernetes.io/name" .= ("prodbox-credential-provisioner-substrate" :: Text)
    , "app.kubernetes.io/managed-by" .= ("prodbox" :: Text)
    ]

namespaceObject :: Value
namespaceObject =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("Namespace" :: Text)
    , "metadata"
        .= object
          [ "name" .= credentialProvisionerNamespace
          , "labels" .= commonLabels
          ]
    ]

serviceAccountObject :: Text -> Value
serviceAccountObject name =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("ServiceAccount" :: Text)
    , "metadata" .= namespacedMetadata name
    , "automountServiceAccountToken" .= False
    ]

controllerRoleObject :: Value
controllerRoleObject =
  object
    [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
    , "kind" .= ("Role" :: Text)
    , "metadata" .= namespacedMetadata controllerRoleName
    , "rules"
        .= [ rule ["batch"] ["jobs"] ["create", "get", "list", "watch", "delete"]
           , rule [""] ["pods"] ["get", "list", "watch", "delete"]
           , object
               [ "apiGroups" .= ([""] :: [Text])
               , "resources" .= (["serviceaccounts"] :: [Text])
               , "resourceNames" .= [awsAdminServiceAccount, externalMaterialServiceAccount]
               , "verbs" .= (["get"] :: [Text])
               ]
           , rule [""] ["pods/attach"] ["create", "get"]
           , rule [""] ["pods/log"] ["get"]
           ]
    ]

controllerRoleBindingObject :: Value
controllerRoleBindingObject =
  object
    [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
    , "kind" .= ("RoleBinding" :: Text)
    , "metadata" .= namespacedMetadata controllerRoleName
    , "subjects"
        .= [ serviceAccountSubject "prodbox-control-plane-operator" "bootstrap-broker"
           , serviceAccountSubject "prodbox-control-plane-test-harness" "gateway"
           ]
    , "roleRef"
        .= object
          [ "apiGroup" .= ("rbac.authorization.k8s.io" :: Text)
          , "kind" .= ("Role" :: Text)
          , "name" .= controllerRoleName
          ]
    ]

-- Lifecycle Authority may only perform named GET requests for the two bound
-- workload kinds used by expired-attempt recovery. This role deliberately
-- omits create, update, patch, delete, list, watch, attach, and log access.
authorityObserverRoleObject :: Value
authorityObserverRoleObject =
  object
    [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
    , "kind" .= ("Role" :: Text)
    , "metadata" .= namespacedMetadata authorityObserverRoleName
    , "rules"
        .= [ rule ["batch"] ["jobs"] ["get"]
           , rule [""] ["pods"] ["get"]
           ]
    ]

authorityObserverRoleBindingObject :: Value
authorityObserverRoleBindingObject =
  object
    [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
    , "kind" .= ("RoleBinding" :: Text)
    , "metadata" .= namespacedMetadata (authorityObserverRoleName <> "-binding")
    , "subjects"
        .= [ serviceAccountSubject
               "prodbox-lifecycle-authority"
               "lifecycle-authority"
           ]
    , "roleRef"
        .= object
          [ "apiGroup" .= ("rbac.authorization.k8s.io" :: Text)
          , "kind" .= ("Role" :: Text)
          , "name" .= authorityObserverRoleName
          ]
    ]

awsAdminNetworkPolicyObject :: KubernetesApiEgressCoordinate -> Value
awsAdminNetworkPolicyObject apiCoordinate =
  networkPolicy
    "prodbox-credential-provisioner-aws-admin"
    "aws-admin"
    [ dnsEgress
    , namespacedEgress "vault" "prodbox-vault" 8200
    , namespacedEgress
        "lifecycle-authority"
        "prodbox-lifecycle-authority"
        controlPlaneListenPort
    , namespacedEgress
        "target-secret-agent"
        "prodbox-target-secret-agent"
        controlPlaneListenPort
    , object
        [ "to" .= [object ["ipBlock" .= object ["cidr" .= ("0.0.0.0/0" :: Text)]]]
        , "ports" .= [tcpPort 443]
        ]
    , kubernetesApiEgress apiCoordinate
    ]

kubernetesApiEgress :: KubernetesApiEgressCoordinate -> Value
kubernetesApiEgress coordinate =
  object
    [ "to"
        .= [ object
               [ "ipBlock" .= object ["cidr" .= (Text.pack address <> "/32")]
               ]
           | address <- kubernetesApiEgressAddresses coordinate
           ]
    , "ports" .= [tcpPort (kubernetesApiEgressPort coordinate)]
    ]

externalMaterialNetworkPolicyObject :: Value
externalMaterialNetworkPolicyObject =
  networkPolicy
    "prodbox-credential-provisioner-external-material"
    "external-acme-eab"
    [dnsEgress, namespacedEgress "vault" "prodbox-vault" 8200]

networkPolicy :: Text -> Text -> [Value] -> Value
networkPolicy name schema egress =
  object
    [ "apiVersion" .= ("networking.k8s.io/v1" :: Text)
    , "kind" .= ("NetworkPolicy" :: Text)
    , "metadata" .= namespacedMetadata name
    , "spec"
        .= object
          [ "podSelector"
              .= object
                [ "matchLabels"
                    .= object
                      [ "app.kubernetes.io/name" .= applicationName
                      , "prodbox.io/ingress-schema" .= schema
                      ]
                ]
          , "policyTypes" .= (["Ingress", "Egress"] :: [Text])
          , "ingress" .= ([] :: [Value])
          , "egress" .= egress
          ]
    ]
 where
  applicationName
    | schema == "aws-admin" = "prodbox-credential-provisioner" :: Text
    | otherwise = "prodbox-external-material-ingress"

dnsEgress :: Value
dnsEgress =
  object
    [ "to"
        .= [ object
               [ "namespaceSelector"
                   .= object
                     [ "matchLabels"
                         .= object ["kubernetes.io/metadata.name" .= ("kube-system" :: Text)]
                     ]
               ]
           ]
    , "ports" .= [udpPort 53, tcpPort 53]
    ]

namespacedEgress :: Text -> Text -> Int -> Value
namespacedEgress namespace podName port =
  object
    [ "to"
        .= [ object
               [ "namespaceSelector"
                   .= object
                     [ "matchLabels" .= object ["kubernetes.io/metadata.name" .= namespace]
                     ]
               , "podSelector"
                   .= object
                     [ "matchLabels" .= object ["app.kubernetes.io/name" .= podName]
                     ]
               ]
           ]
    , "ports" .= [tcpPort port]
    ]

tcpPort :: Int -> Value
tcpPort port = object ["protocol" .= ("TCP" :: Text), "port" .= port]

udpPort :: Int -> Value
udpPort port = object ["protocol" .= ("UDP" :: Text), "port" .= port]

rule :: [Text] -> [Text] -> [Text] -> Value
rule apiGroups resources verbs =
  object
    [ "apiGroups" .= apiGroups
    , "resources" .= resources
    , "verbs" .= verbs
    ]

serviceAccountSubject :: Text -> Text -> Value
serviceAccountSubject name namespace =
  object
    [ "kind" .= ("ServiceAccount" :: Text)
    , "name" .= name
    , "namespace" .= namespace
    ]

namespacedMetadata :: Text -> Value
namespacedMetadata name =
  object
    [ "name" .= name
    , "namespace" .= credentialProvisionerNamespace
    , "labels" .= commonLabels
    ]
