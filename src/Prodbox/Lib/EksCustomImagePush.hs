{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.5.c.v.b — push custom-built prodbox images into EKS-side
-- Harbor via an in-cluster crane pod.
--
-- The home substrate's 'Prodbox.CLI.Rke2.ensureCustomImageVariants'
-- builds the single union @prodbox-runtime@ image via host Docker,
-- then @docker push@'s to the home RKE2's
-- in-cluster Harbor via the @127.0.0.1:30080@ NodePort. On the AWS
-- substrate the operator host has no network path into the EKS Harbor
-- NodePort, so the @docker push@ flow does not apply.
--
-- This module renders + drives an in-cluster crane pod that receives
-- the docker-saved image tarball via @kubectl cp@ and pushes it to
-- Harbor's in-cluster DNS endpoint
-- @harbor.harbor.svc.cluster.local@. The pushed manifest path matches
-- the chart-rendered @127.0.0.1:30080\/prodbox\/prodbox-runtime:...@ refs that
-- downstream Helm releases consume; the Sprint @7.5.c.ii@ containerd
-- registry-mirror DaemonSet routes those refs through Harbor on each
-- EKS node so chart pods can pull.
--
-- The home substrate is unchanged: 'ensureCustomImageVariantsForSubstrate
-- SubstrateHomeLocal' keeps the existing host-Docker login + push +
-- @ctr@ import path.
module Prodbox.Lib.EksCustomImagePush
  ( EksCustomImagePushConfig (..)
  , defaultEksCustomImagePushConfig
  , eksCustomImagePushPodManifest
  , rewriteChartRefForInClusterPush
  )
where

import Data.Aeson
  ( Value
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key

-- | Configuration for the in-cluster crane push pod.
data EksCustomImagePushConfig = EksCustomImagePushConfig
  { customPushPodNamespace :: String
  -- ^ Kubernetes namespace the pod lands in. Defaults to @harbor@
  -- so the pod sits alongside the Harbor release it pushes into.
  , customPushPodName :: String
  -- ^ @metadata.name@ for the pod.
  , customPushImage :: String
  -- ^ Container image for the crane-based push worker.
  , customPushHarborInternalEndpoint :: String
  -- ^ In-cluster DNS endpoint the pod pushes to, e.g.
  -- @harbor.harbor.svc.cluster.local@.
  , customPushChartRegistryEndpoint :: String
  -- ^ The chart-image-ref endpoint that downstream Helm releases
  -- consume, e.g. @127.0.0.1:30080@. Chart-image refs of the form
  -- @<endpoint>\/prodbox\/prodbox-runtime:...@ get rewritten to the
  -- in-cluster endpoint for the @crane push@ destination URL
  -- because crane resolves the host:port to a network target.
  , customPushHarborAdminUser :: String
  , customPushHarborAdminPassword :: String
  }
  deriving (Eq, Show)

-- | Default push pod config matching the bootstrap Harbor admin
-- contract: pushes into @harbor.harbor.svc.cluster.local@, rewrites
-- @127.0.0.1:30080@ chart refs to the in-cluster endpoint, uses the
-- @Harbor12345@ bootstrap admin credential.
defaultEksCustomImagePushConfig :: EksCustomImagePushConfig
defaultEksCustomImagePushConfig =
  EksCustomImagePushConfig
    { customPushPodNamespace = "harbor"
    , customPushPodName = "prodbox-custom-image-push"
    , customPushImage = "gcr.io/go-containerregistry/crane:debug"
    , customPushHarborInternalEndpoint = "harbor.harbor.svc.cluster.local"
    , customPushChartRegistryEndpoint = "127.0.0.1:30080"
    , customPushHarborAdminUser = "admin"
    , customPushHarborAdminPassword = "Harbor12345"
    }

-- | Rewrite a chart-image reference (e.g.
-- @127.0.0.1:30080\/prodbox\/prodbox-runtime:tag@) to use the in-cluster
-- Harbor DNS endpoint for the in-pod @crane push@ destination.
-- Falls through unchanged when the prefix does not match — defensive
-- against image-ref shape changes.
rewriteChartRefForInClusterPush :: EksCustomImagePushConfig -> String -> String
rewriteChartRefForInClusterPush config chartRef =
  let prefix = customPushChartRegistryEndpoint config ++ "/"
      replacement = customPushHarborInternalEndpoint config ++ "/"
   in case stripPrefix' prefix chartRef of
        Just rest -> replacement ++ rest
        Nothing -> chartRef

stripPrefix' :: String -> String -> Maybe String
stripPrefix' [] s = Just s
stripPrefix' _ [] = Nothing
stripPrefix' (p : ps) (c : cs)
  | p == c = stripPrefix' ps cs
  | otherwise = Nothing

-- | Render the long-running crane pod manifest that receives the
-- docker-saved image tarball via @kubectl cp@. The pod uses
-- @sleep infinity@ so the orchestrator can @kubectl cp@ in the
-- tarball, @kubectl exec@ a Harbor auth login, and @kubectl exec@
-- multiple @crane push@ invocations before deleting the pod.
--
-- The pod runs with a single emptyDir at @\/data@ as the cp target.
-- The crane binary is on @PATH@ in the @:debug@ variant via
-- @\/ko-app\/crane@; the @\/busybox\/sh@ interpreter handles the
-- @sleep infinity@ entrypoint.
eksCustomImagePushPodManifest :: EksCustomImagePushConfig -> Value
eksCustomImagePushPodManifest config =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("Pod" :: String)
    , "metadata"
        .= object
          [ "name" .= customPushPodName config
          , "namespace" .= customPushPodNamespace config
          , "labels"
              .= object
                [ Key.fromString "app.kubernetes.io/name" .= customPushPodName config
                , Key.fromString "app.kubernetes.io/managed-by" .= ("prodbox" :: String)
                , Key.fromString "prodbox.io/sprint" .= ("7.5.c.v.b" :: String)
                ]
          ]
    , "spec"
        .= object
          [ "restartPolicy" .= ("Never" :: String)
          , "containers"
              .= [ object
                     [ "name" .= ("crane" :: String)
                     , "image" .= customPushImage config
                     , "command" .= (["/busybox/sh", "-c", "sleep infinity"] :: [String])
                     , "env"
                         .= [ object
                                [ "name" .= ("HARBOR_INTERNAL" :: String)
                                , "value" .= customPushHarborInternalEndpoint config
                                ]
                            , object
                                [ "name" .= ("HARBOR_USER" :: String)
                                , "value" .= customPushHarborAdminUser config
                                ]
                            , object
                                [ "name" .= ("HARBOR_PASSWORD" :: String)
                                , "value" .= customPushHarborAdminPassword config
                                ]
                            ]
                     , "volumeMounts"
                         .= [ object
                                [ "name" .= ("scratch" :: String)
                                , "mountPath" .= ("/data" :: String)
                                ]
                            ]
                     , "resources"
                         .= object
                           [ "requests"
                               .= object
                                 [ "cpu" .= ("250m" :: String)
                                 , "memory" .= ("1Gi" :: String)
                                 , "ephemeral-storage" .= ("6Gi" :: String)
                                 ]
                           , "limits"
                               .= object
                                 [ "memory" .= ("4Gi" :: String)
                                 , "ephemeral-storage" .= ("12Gi" :: String)
                                 ]
                           ]
                     ]
                 ]
          , "volumes"
              .= [ object
                     [ "name" .= ("scratch" :: String)
                     , "emptyDir" .= object ["sizeLimit" .= ("12Gi" :: String)]
                     ]
                 ]
          ]
    ]
