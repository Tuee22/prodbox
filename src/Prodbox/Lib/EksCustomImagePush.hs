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
-- SubstrateHomeLocal' keeps the existing host-Docker build + push (no
-- @docker login@ — the registry is anonymous) + @ctr@ import path.
module Prodbox.Lib.EksCustomImagePush
  ( EksCustomImagePushConfig (..)
  , defaultEksCustomImagePushConfig
  , eksCustomImagePushPodManifest
  , rewriteChartRefForInClusterPush
  , eksRuntimeImageDigestRecordName
  , eksRuntimeImageDigestRecordKey
  , eksRuntimeImageDigestRecordManifest
  , eksRegistryDigestCommandArguments
  , parseRegistryManifestDigest
  , classifyEksRegistryDigestRecordRead
  )
where

import Data.Aeson
  ( Value
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Char (isSpace)
import System.Exit (ExitCode (ExitSuccess))

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
  }
  deriving (Eq, Show)

-- | Default push pod config: pushes into @harbor.harbor.svc.cluster.local@ and
-- rewrites @127.0.0.1:30080@ chart refs to the in-cluster endpoint.
--
-- The pod carries no registry credential. The endpoint is a single-binary
-- @registry:2@ whose rendered config has no @auth@ stanza, so it accepts
-- anonymous push — the same contract the home substrate relies on
-- (@ensureCustomImageVariantsHomeLocal@ pushes with no @docker login@). The
-- former hardcoded admin credential authenticated to nothing and was removed
-- under vault_doctrine.md §20.3.
defaultEksCustomImagePushConfig :: EksCustomImagePushConfig
defaultEksCustomImagePushConfig =
  EksCustomImagePushConfig
    { customPushPodNamespace = "harbor"
    , customPushPodName = "prodbox-custom-image-push"
    , customPushImage = "gcr.io/go-containerregistry/crane:debug"
    , customPushHarborInternalEndpoint = "harbor.harbor.svc.cluster.local"
    , customPushChartRegistryEndpoint = "127.0.0.1:30080"
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
-- tarball and @kubectl exec@ multiple @crane push@ invocations
-- before deleting the pod.
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

-- | The cluster-resident record of the manifest digest the EKS registry holds
-- for the runtime image the crane pod pushed.
--
-- The control-plane charts pin the image by manifest digest, and the digest has
-- to be the one the EKS registry assigned: the Target Secret Worker compares it
-- with the image identifier of each worker pod, which is the digest of the
-- manifest the node pulled. The AWS publication never pushes or pulls from the
-- host, so the host's @.RepoDigests@ is empty or is the digest of an earlier push
-- to the home registry, and a manifest the in-cluster loader writes need not
-- have the digest a host push of the same image produces. The record is written
-- once, after a successful push, from what the registry itself reports, and read
-- when the charts are planned.
eksRuntimeImageDigestRecordName :: String
eksRuntimeImageDigestRecordName = "prodbox-runtime-image-digest"

-- | The key inside the record that holds the digest.
eksRuntimeImageDigestRecordKey :: String
eksRuntimeImageDigestRecordKey = "manifest-digest"

-- | The @ConfigMap@ that records the digest, in the namespace the push pod and
-- the registry share.
eksRuntimeImageDigestRecordManifest :: EksCustomImagePushConfig -> String -> Value
eksRuntimeImageDigestRecordManifest config digest =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("ConfigMap" :: String)
    , "metadata"
        .= object
          [ "name" .= eksRuntimeImageDigestRecordName
          , "namespace" .= customPushPodNamespace config
          , "labels"
              .= object
                [ Key.fromString "app.kubernetes.io/managed-by" .= ("prodbox" :: String)
                ]
          ]
    , "data" .= object [Key.fromString eksRuntimeImageDigestRecordKey .= digest]
    ]

-- | The @kubectl@ arguments that ask the push pod's @crane@ for the manifest
-- digest the registry holds for a pushed reference.
--
-- A value rather than an inline list so the one fact the record depends on, that
-- the digest comes from the registry the pod just pushed to and not from the
-- host, has a case that can fail if the call is reshaped.
eksRegistryDigestCommandArguments :: EksCustomImagePushConfig -> String -> [String]
eksRegistryDigestCommandArguments config chartRef =
  [ "exec"
  , "-n"
  , customPushPodNamespace config
  , customPushPodName config
  , "--"
  , "/ko-app/crane"
  , "digest"
  , rewriteChartRefForInClusterPush config chartRef
  , "--insecure"
  ]

-- | Read the digest @crane digest@ prints, or nothing when the text is not
-- exactly one manifest digest. Surrounding whitespace is the trailing newline
-- the tool writes; anything else, a second line included, is not a digest.
parseRegistryManifestDigest :: String -> Maybe String
parseRegistryManifestDigest raw
  | isManifestDigest trimmed = Just trimmed
  | otherwise = Nothing
 where
  trimmed = trimEnds raw
  trimEnds = dropWhileEnd' isSpace . dropWhile isSpace
  dropWhileEnd' predicate = reverse . dropWhile predicate . reverse
  isManifestDigest candidate =
    length candidate == 71
      && take 7 candidate == "sha256:"
      && all isLowerHex (drop 7 candidate)
  isLowerHex character = character `elem` ['0' .. '9'] || character `elem` ['a' .. 'f']

-- | What reading the digest record said. @Right (Just _)@ is a recorded
-- digest, @Right Nothing@ is a cluster that answered and holds no record (the
-- publication has not run), and @Left@ is everything else: the cluster could not
-- be asked, or the record holds something that is not a manifest digest. The
-- last two used to read as an absent record, so the plan refused with "no
-- immutable repository manifest digest" and named the wrong cause.
classifyEksRegistryDigestRecordRead :: ExitCode -> String -> String -> Either String (Maybe String)
classifyEksRegistryDigestRecordRead exitCode standardOutput standardError
  | exitCode /= ExitSuccess =
      Left
        ( "kubectl could not read the record: "
            ++ firstNonEmpty [trimmed standardError, trimmed standardOutput, "no output"]
        )
  | null (trimmed standardOutput) = Right Nothing
  | otherwise =
      case parseRegistryManifestDigest standardOutput of
        Just digest -> Right (Just digest)
        Nothing ->
          Left
            ( "the record holds a value that is not a sha256 manifest digest: "
                ++ show (take 80 (trimmed standardOutput))
            )
 where
  trimmed = reverse . dropWhile isSpace . reverse . dropWhile isSpace
  firstNonEmpty candidates = case filter (not . null) candidates of
    candidate : _ -> candidate
    [] -> ""
