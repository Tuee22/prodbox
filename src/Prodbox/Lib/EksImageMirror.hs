{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.5.c.iv — EKS-side in-cluster image-mirror Job.
--
-- The home substrate mirrors required public images into the
-- in-cluster Harbor via host-Docker + host-`ctr`
-- (`Prodbox.CLI.Rke2.mirrorClusterImagesOnce`). On EKS the operator
-- host has no network path into the EKS-side Harbor NodePort, so the
-- equivalent step must run from inside the cluster.
--
-- This module renders a Kubernetes Job that runs
-- @gcr.io/go-containerregistry/crane@ and, for each (upstream-source,
-- harbor-target) pair in
-- 'Prodbox.ContainerImage.requiredPublicImagePairs', invokes
-- @crane copy@ to push the upstream image into Harbor via the
-- in-cluster service DNS @harbor.harbor.svc.cluster.local@. The
-- chart-image refs that downstream Helm releases consume continue
-- to use @127.0.0.1:30080/prodbox/...@; the Sprint 7.5.c.ii
-- containerd registry-mirror DaemonSet routes those refs through
-- the same Harbor on read.
--
-- This module is renderer-only. The effectful @kubectl apply@
-- wrapper plus the @kubectl wait --for=condition=complete@ readiness
-- step lands in
-- 'Prodbox.Lib.AwsSubstratePlatform.applyEksImageMirrorJob'.
module Prodbox.Lib.EksImageMirror
  ( EksImageMirrorConfig (..)
  , defaultEksImageMirrorConfig
  , eksImageMirrorJobManifest
  , eksImageMirrorCopyScript
  , isRetryableEksImageMirrorFailure
  )
where

import Data.Aeson
  ( Value
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Char (toLower)
import Data.List (intercalate, isInfixOf)

-- | Configuration for the in-cluster image-mirror Job.
data EksImageMirrorConfig = EksImageMirrorConfig
  { mirrorJobNamespace :: String
  -- ^ Kubernetes namespace the Job lands in. Defaults to
  -- @harbor@ so the Job sits alongside the Harbor release it
  -- pushes into.
  , mirrorJobName :: String
  -- ^ @metadata.name@ for the Job.
  , mirrorJobImage :: String
  -- ^ Container image for the crane-based copy worker. Defaults to
  -- the upstream go-containerregistry image; the home substrate
  -- already uses crane via its image-mirror flow.
  , mirrorHarborInternalEndpoint :: String
  -- ^ In-cluster DNS endpoint the Job pushes to, e.g.
  -- @harbor.harbor.svc.cluster.local@. Chart pods pull via the
  -- @127.0.0.1:30080@ endpoint by way of the Sprint 7.5.c.ii
  -- containerd registry-mirror DaemonSet, but the Job needs an
  -- in-pod-network address because @127.0.0.1@ in a non-host-network
  -- pod is the pod itself, not the EKS node.
  , mirrorChartRegistryEndpoint :: String
  -- ^ The chart-image-ref endpoint that downstream Helm releases
  -- consume, e.g. @127.0.0.1:30080@. The Job rewrites each
  -- @publicImageTarget@ rendered as
  -- @<mirrorChartRegistryEndpoint>/<repo>:<tag>@ into
  -- @<mirrorHarborInternalEndpoint>/<repo>:<tag>@ before invoking
  -- @crane copy@.
  , mirrorHarborAdminUser :: String
  -- ^ Harbor admin user the Job authenticates as. Default
  -- @admin@; matches the home-substrate bootstrap contract.
  , mirrorHarborAdminPassword :: String
  -- ^ Harbor admin password. The home substrate's bootstrap
  -- contract uses the static @Harbor12345@ value
  -- ('Prodbox.CLI.Rke2.ensureHarborDockerLogin') — both substrates
  -- start from that bootstrap credential.
  }
  deriving (Eq, Show)

-- | Default mirror Job config matching the home substrate's Harbor
-- bootstrap contract: pushes to @harbor.harbor.svc.cluster.local@,
-- rewrites target refs from @127.0.0.1:30080/...@, authenticates as
-- the bootstrap admin user.
defaultEksImageMirrorConfig :: EksImageMirrorConfig
defaultEksImageMirrorConfig =
  EksImageMirrorConfig
    { mirrorJobNamespace = "harbor"
    , mirrorJobName = "prodbox-image-mirror"
    , mirrorJobImage = "gcr.io/go-containerregistry/crane:debug"
    , mirrorHarborInternalEndpoint = "harbor.harbor.svc.cluster.local"
    , mirrorChartRegistryEndpoint = "127.0.0.1:30080"
    , mirrorHarborAdminUser = "admin"
    , mirrorHarborAdminPassword = "Harbor12345"
    }

-- | Render the copy script that the Job's container runs. Iterates
-- over each @(upstream-source, chart-target)@ pair, rewrites the
-- @chart-target@ to the in-cluster endpoint, and invokes
-- @crane copy@. Idempotent — @crane copy@ skips already-pushed
-- digests.
--
-- Exposed for unit-test inspection alongside
-- 'eksImageMirrorJobManifest'.
eksImageMirrorCopyScript :: EksImageMirrorConfig -> [(String, String)] -> String
eksImageMirrorCopyScript config pairs =
  intercalate
    "\n"
    ( [ "#!/busybox/sh"
      , "set -eu"
      , ""
      , "echo \"prodbox-image-mirror: authenticating to ${HARBOR_INTERNAL}\""
      , "crane auth login \"${HARBOR_INTERNAL}\" --username \"${HARBOR_USER}\" --password \"${HARBOR_PASSWORD}\""
      , ""
      , "echo \"prodbox-image-mirror: copying " ++ show (length pairs) ++ " required public images\""
      , ""
      ]
        ++ concatMap (\(src, target) -> renderCopyCommand config src target) pairs
        ++ [ ""
           , "echo \"prodbox-image-mirror: complete\""
           , ""
           ]
    )

-- | Sprint 7.31: the EKS-side counterpart of
-- 'Prodbox.CLI.Rke2.isRetryableHarborPublicationFailure'
-- (bootstrap_readiness_doctrine.md §4). The EKS crane push exercises the same
-- registry→MinIO S3 write edge as the home mirror, so its characteristic
-- transient failure is a name-resolution error against
-- @minio.prodbox.svc.cluster.local@ (or the internal Harbor Service) while
-- endpoint programming settles. Classifying @no such host@ / @dial tcp@ /
-- @lookup@ / @name resolution@ as retryable — plus the usual transient HTTP /
-- connection errors — bounds residual jitter with a host-side Job re-apply
-- rather than failing the AWS-substrate bootstrap on first contact. The deep
-- gate ('ensureRegistryStorageBackendEdgeReady') is what removes the race; this
-- classifier only bounds the residual.
isRetryableEksImageMirrorFailure :: String -> Bool
isRetryableEksImageMirrorFailure detail =
  let lowered = map toLower detail
   in any
        (`isInfixOf` lowered)
        [ "no such host"
        , "dial tcp"
        , "lookup"
        , "name resolution"
        , "connection reset by peer"
        , "connection refused"
        , "tls handshake timeout"
        , "i/o timeout"
        , "temporary failure"
        , "502 bad gateway"
        , "503 service unavailable"
        , "504 gateway timeout"
        , "429 too many requests"
        ]

renderCopyCommand :: EksImageMirrorConfig -> String -> String -> [String]
renderCopyCommand config src chartTarget =
  let rewritten = rewriteChartTargetForInClusterPush config chartTarget
   in [ "echo \"prodbox-image-mirror: " ++ src ++ " -> " ++ rewritten ++ "\""
      , "crane copy \"" ++ src ++ "\" \"" ++ rewritten ++ "\" --insecure"
      ]

-- | Rewrite a chart-target image reference (e.g.
-- @127.0.0.1:30080/prodbox/keycloak-mirror:26.0.0@) to use the
-- in-cluster Harbor endpoint (e.g.
-- @harbor.harbor.svc.cluster.local/prodbox/keycloak-mirror:26.0.0@)
-- for the Job's in-cluster @crane copy@ push. Falls through
-- unchanged if the prefix doesn't match — defensive against
-- future image-ref shape changes.
rewriteChartTargetForInClusterPush :: EksImageMirrorConfig -> String -> String
rewriteChartTargetForInClusterPush config chartTarget =
  let prefix = mirrorChartRegistryEndpoint config ++ "/"
      replacement = mirrorHarborInternalEndpoint config ++ "/"
   in case stripPrefix' prefix chartTarget of
        Just rest -> replacement ++ rest
        Nothing -> chartTarget

stripPrefix' :: String -> String -> Maybe String
stripPrefix' [] s = Just s
stripPrefix' _ [] = Nothing
stripPrefix' (p : ps) (c : cs)
  | p == c = stripPrefix' ps cs
  | otherwise = Nothing

-- | Render the @batch/v1@ Job manifest the Sprint 7.5.c.iv
-- orchestrator applies via @kubectl apply -f@. The pod runs the
-- crane-based copy script as its sole container; on success the Job
-- transitions to @Complete@ and the orchestrator's @kubectl wait
-- --for=condition=complete@ step unblocks.
eksImageMirrorJobManifest :: EksImageMirrorConfig -> [(String, String)] -> Value
eksImageMirrorJobManifest config pairs =
  object
    [ "apiVersion" .= ("batch/v1" :: String)
    , "kind" .= ("Job" :: String)
    , "metadata"
        .= object
          [ "name" .= mirrorJobName config
          , "namespace" .= mirrorJobNamespace config
          , "labels"
              .= object
                [ Key.fromString "app.kubernetes.io/name" .= mirrorJobName config
                , Key.fromString "app.kubernetes.io/managed-by" .= ("prodbox" :: String)
                , Key.fromString "prodbox.io/sprint" .= ("7.5.c.iv" :: String)
                ]
          ]
    , "spec"
        .= object
          [ "backoffLimit" .= (2 :: Int)
          , "template"
              .= object
                [ "metadata"
                    .= object
                      [ "labels"
                          .= object
                            [ Key.fromString "app.kubernetes.io/name" .= mirrorJobName config
                            ]
                      ]
                , "spec"
                    .= object
                      [ "restartPolicy" .= ("OnFailure" :: String)
                      , "containers"
                          .= [ object
                                 [ "name" .= ("crane" :: String)
                                 , "image" .= mirrorJobImage config
                                 , -- gcr.io/go-containerregistry/crane:debug uses distroless static-debian12:debug as base, which ships busybox at /busybox/sh (no /bin/sh symlink).
                                   "command" .= (["/busybox/sh", "-c"] :: [String])
                                 , "args" .= [eksImageMirrorCopyScript config pairs]
                                 , "env"
                                     .= [ object
                                            [ "name" .= ("HARBOR_INTERNAL" :: String)
                                            , "value" .= mirrorHarborInternalEndpoint config
                                            ]
                                        , object
                                            [ "name" .= ("HARBOR_USER" :: String)
                                            , "value" .= mirrorHarborAdminUser config
                                            ]
                                        , object
                                            [ "name" .= ("HARBOR_PASSWORD" :: String)
                                            , "value" .= mirrorHarborAdminPassword config
                                            ]
                                        ]
                                 , "resources"
                                     .= object
                                       [ "requests"
                                           .= object
                                             [ "cpu" .= ("100m" :: String)
                                             , "memory" .= ("128Mi" :: String)
                                             ]
                                       , "limits"
                                           .= object
                                             [ "memory" .= ("512Mi" :: String)
                                             ]
                                       ]
                                 ]
                             ]
                      ]
                ]
          ]
    ]
