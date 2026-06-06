module Prodbox.ContainerImage
  ( ImageRef (..)
  , canonicalImagePlatforms
  , harborMirrorSourceCandidates
  , harborCertManagerAcmesolverImage
  , harborCertManagerCainjectorImage
  , harborCertManagerControllerImage
  , harborCertManagerStartupApiCheckImage
  , harborCertManagerWebhookImage
  , harborCodeServerImage
  , harborCurlImage
  , harborEnvoyGatewayImage
  , harborEnvoyProxyImage
  , harborFrrImage
  , harborGatewayImageRepository
  , harborGatewayRepository
  , harborImageRefFromSource
  , harborKubeRbacProxyImage
  , harborKeycloakImage
  , publicMinioImage
  , publicMinioMcImage
  , harborMetallbControllerImage
  , harborMetallbSpeakerImage
  , harborMinioImage
  , harborMinioMcImage
  , harborMirrorProject
  , harborMirrorTargetForSource
  , harborPostgresOperatorImage
  , harborRegistryEndpoint
  , harborPostgresDatabaseImage
  , harborPostgresPgbackrestImage
  , harborPostgresPgbouncerImage
  , harborPublicEdgeWorkloadImageRepository
  , harborRedisImage
  , normalizeImageRefText
  , parseImageRef
  , publicCurlImage
  , publicRedisImage
  , renderImageRef
  , requiredPublicImageCandidatePairs
  , requiredPublicImagePairs
  )
where

import Data.Char (isSpace)
import Data.List (find, nub)

data ImageRef = ImageRef
  { imageRegistry :: String
  , imageRepository :: String
  , imageTag :: String
  }
  deriving (Eq, Show)

harborRegistryEndpoint :: String
harborRegistryEndpoint = "127.0.0.1:30080"

harborMirrorProject :: String
harborMirrorProject = "prodbox"

harborGatewayRepository :: String
harborGatewayRepository = harborMirrorProject ++ "/prodbox-gateway"

harborGatewayImageRepository :: String
harborGatewayImageRepository = harborRegistryEndpoint ++ "/" ++ harborGatewayRepository

harborPublicEdgeWorkloadRepository :: String
harborPublicEdgeWorkloadRepository = harborMirrorProject ++ "/prodbox-public-edge-workload"

harborPublicEdgeWorkloadImageRepository :: String
harborPublicEdgeWorkloadImageRepository = harborRegistryEndpoint ++ "/" ++ harborPublicEdgeWorkloadRepository

harborEnvoyGatewayImage :: ImageRef
harborEnvoyGatewayImage = harborImageRefFromRepository "envoy-gateway-mirror" "v1.7.2"

harborEnvoyProxyImage :: ImageRef
harborEnvoyProxyImage = harborImageRefFromRepository "envoy-proxy-mirror" "distroless-v1.37.0"

harborPostgresOperatorImage :: ImageRef
harborPostgresOperatorImage =
  harborImageRefFromRepository "percona-postgresql-operator-mirror" "2.9.0"

harborPostgresDatabaseImage :: ImageRef
harborPostgresDatabaseImage =
  harborImageRefFromRepository "percona-distribution-postgresql-mirror" "17.9-1"

harborPostgresPgbackrestImage :: ImageRef
harborPostgresPgbackrestImage =
  harborImageRefFromRepository "percona-pgbackrest-mirror" "2.58.0-1"

harborPostgresPgbouncerImage :: ImageRef
harborPostgresPgbouncerImage =
  harborImageRefFromRepository "percona-pgbouncer-mirror" "1.25.1-1"

harborCodeServerImage :: ImageRef
harborCodeServerImage = harborImageRefFromRepository "code-server-mirror" "4.98.2"

harborKeycloakImage :: ImageRef
harborKeycloakImage = harborImageRefFromRepository "keycloak-mirror" "26.0.0"

publicCurlImage :: ImageRef
publicCurlImage = ImageRef "docker.io" "curlimages/curl" "8.11.0"

harborCurlImage :: ImageRef
harborCurlImage = harborImageRefFromRepository "curl-mirror" "8.11.0"

publicRedisImage :: ImageRef
publicRedisImage = ImageRef "docker.io" "library/redis" "7.4.2"

harborRedisImage :: ImageRef
harborRedisImage = harborImageRefFromRepository "redis-mirror" "7.4.2"

publicMinioImage :: ImageRef
publicMinioImage = ImageRef "quay.io" "minio/minio" "RELEASE.2024-12-18T13-15-44Z"

publicMinioMcImage :: ImageRef
publicMinioMcImage = ImageRef "quay.io" "minio/mc" "RELEASE.2024-11-21T17-21-54Z"

harborMinioImage :: ImageRef
harborMinioImage = harborImageRefFromRepository "minio-mirror" "RELEASE.2024-12-18T13-15-44Z"

harborMinioMcImage :: ImageRef
harborMinioMcImage = harborImageRefFromRepository "minio-mc-mirror" "RELEASE.2024-11-21T17-21-54Z"

harborMetallbControllerImage :: ImageRef
harborMetallbControllerImage = harborImageRefFromRepository "metallb-controller-mirror" "v0.14.9"

harborMetallbSpeakerImage :: ImageRef
harborMetallbSpeakerImage = harborImageRefFromRepository "metallb-speaker-mirror" "v0.14.9"

harborFrrImage :: ImageRef
harborFrrImage = harborImageRefFromRepository "frr-mirror" "9.1.0"

harborKubeRbacProxyImage :: ImageRef
harborKubeRbacProxyImage = harborImageRefFromRepository "kube-rbac-proxy-mirror" "v0.12.0"

harborCertManagerControllerImage :: ImageRef
harborCertManagerControllerImage = harborImageRefFromRepository "cert-manager-controller-mirror" "v1.16.2"

harborCertManagerWebhookImage :: ImageRef
harborCertManagerWebhookImage = harborImageRefFromRepository "cert-manager-webhook-mirror" "v1.16.2"

harborCertManagerCainjectorImage :: ImageRef
harborCertManagerCainjectorImage = harborImageRefFromRepository "cert-manager-cainjector-mirror" "v1.16.2"

harborCertManagerAcmesolverImage :: ImageRef
harborCertManagerAcmesolverImage = harborImageRefFromRepository "cert-manager-acmesolver-mirror" "v1.16.2"

harborCertManagerStartupApiCheckImage :: ImageRef
harborCertManagerStartupApiCheckImage = harborImageRefFromRepository "cert-manager-startupapicheck-mirror" "v1.16.2"

canonicalImagePlatforms :: [(String, String)]
canonicalImagePlatforms =
  [ ("linux", "amd64")
  , ("linux", "arm64")
  ]

data PublicImageMirror = PublicImageMirror
  { publicImagePrimarySource :: ImageRef
  , publicImageSourceAliases :: [ImageRef]
  , publicImageTarget :: ImageRef
  }

requiredPublicImagePairs :: [(String, String)]
requiredPublicImagePairs =
  [ renderedPair mirror
  | mirror <- requiredPublicImageMirrors
  ]
 where
  renderedPair mirror =
    (renderImageRef (publicImagePrimarySource mirror), renderImageRef (publicImageTarget mirror))

requiredPublicImageCandidatePairs :: [([String], String)]
requiredPublicImageCandidatePairs =
  [ (renderedSources mirror, renderImageRef (publicImageTarget mirror))
  | mirror <- requiredPublicImageMirrors
  ]
 where
  renderedSources mirror =
    map renderImageRef (publicImagePrimarySource mirror : publicImageSourceAliases mirror)

requiredPublicImageMirrors :: [PublicImageMirror]
requiredPublicImageMirrors =
  [ mirroredPublicImage
      (ImageRef "docker.io" "percona/percona-postgresql-operator" "2.9.0")
      [ImageRef "mirror.gcr.io" "percona/percona-postgresql-operator" "2.9.0"]
      harborPostgresOperatorImage
  , mirroredPublicImage
      (ImageRef "docker.io" "percona/percona-distribution-postgresql" "17.9-1")
      [ImageRef "mirror.gcr.io" "percona/percona-distribution-postgresql" "17.9-1"]
      harborPostgresDatabaseImage
  , mirroredPublicImage
      (ImageRef "docker.io" "percona/percona-pgbackrest" "2.58.0-1")
      [ImageRef "mirror.gcr.io" "percona/percona-pgbackrest" "2.58.0-1"]
      harborPostgresPgbackrestImage
  , mirroredPublicImage
      (ImageRef "docker.io" "percona/percona-pgbouncer" "1.25.1-1")
      [ImageRef "mirror.gcr.io" "percona/percona-pgbouncer" "1.25.1-1"]
      harborPostgresPgbouncerImage
  , mirroredPublicImage
      (ImageRef "ghcr.io" "coder/code-server" "4.98.2")
      [ImageRef "docker.io" "codercom/code-server" "4.98.2"]
      harborCodeServerImage
  , mirroredPublicImage
      (ImageRef "quay.io" "keycloak/keycloak" "26.0.0")
      []
      harborKeycloakImage
  , mirroredPublicImage
      publicCurlImage
      []
      harborCurlImage
  , mirroredPublicImage
      publicRedisImage
      []
      harborRedisImage
  , mirroredPublicImage
      (ImageRef "docker.io" "envoyproxy/gateway" "v1.7.2")
      [ImageRef "mirror.gcr.io" "envoyproxy/gateway" "v1.7.2"]
      harborEnvoyGatewayImage
  , mirroredPublicImage
      (ImageRef "docker.io" "envoyproxy/envoy" "distroless-v1.37.0")
      [ImageRef "mirror.gcr.io" "envoyproxy/envoy" "distroless-v1.37.0"]
      harborEnvoyProxyImage
  , mirroredPublicImage
      publicMinioImage
      []
      harborMinioImage
  , mirroredPublicImage
      publicMinioMcImage
      []
      harborMinioMcImage
  , mirroredPublicImage
      (ImageRef "quay.io" "metallb/controller" "v0.14.9")
      []
      harborMetallbControllerImage
  , mirroredPublicImage
      (ImageRef "quay.io" "metallb/speaker" "v0.14.9")
      []
      harborMetallbSpeakerImage
  , mirroredPublicImage
      (ImageRef "quay.io" "frrouting/frr" "9.1.0")
      []
      harborFrrImage
  , mirroredPublicImage
      (ImageRef "quay.io" "brancz/kube-rbac-proxy" "v0.12.0")
      [ImageRef "gcr.io" "kubebuilder/kube-rbac-proxy" "v0.12.0"]
      harborKubeRbacProxyImage
  , mirroredPublicImage
      (ImageRef "quay.io" "jetstack/cert-manager-controller" "v1.16.2")
      []
      harborCertManagerControllerImage
  , mirroredPublicImage
      (ImageRef "quay.io" "jetstack/cert-manager-webhook" "v1.16.2")
      []
      harborCertManagerWebhookImage
  , mirroredPublicImage
      (ImageRef "quay.io" "jetstack/cert-manager-cainjector" "v1.16.2")
      []
      harborCertManagerCainjectorImage
  , mirroredPublicImage
      (ImageRef "quay.io" "jetstack/cert-manager-acmesolver" "v1.16.2")
      []
      harborCertManagerAcmesolverImage
  , mirroredPublicImage
      (ImageRef "quay.io" "jetstack/cert-manager-startupapicheck" "v1.16.2")
      []
      harborCertManagerStartupApiCheckImage
  ]

mirroredPublicImage :: ImageRef -> [ImageRef] -> ImageRef -> PublicImageMirror
mirroredPublicImage source aliases target =
  PublicImageMirror
    { publicImagePrimarySource = source
    , publicImageSourceAliases = aliases
    , publicImageTarget = target
    }

renderImageRef :: ImageRef -> String
renderImageRef imageRef =
  imageRegistry imageRef ++ "/" ++ imageRepository imageRef ++ ":" ++ imageTag imageRef

normalizeImageRefText :: String -> Maybe String
normalizeImageRefText rawRef =
  either (const Nothing) (Just . renderImageRef) (parseImageRef rawRef)

parseImageRef :: String -> Either String ImageRef
parseImageRef rawRef =
  let trimmed = trimWhitespace rawRef
   in if trimmed == ""
        then Left "image reference is empty"
        else
          if '@' `elem` trimmed
            then Left ("digested image references are not supported: " ++ trimmed)
            else
              let (registry, remainder) = splitRegistry trimmed
                  normalizedRepository = normalizeRepository registry remainder
                  (repository, tag) = splitTag normalizedRepository
               in if repository == "" || tag == ""
                    then Left ("invalid image reference: " ++ trimmed)
                    else Right (ImageRef registry repository tag)

harborMirrorTargetForSource :: String -> Maybe String
harborMirrorTargetForSource sourceRef =
  either (const Nothing) resolveTarget (parseImageRef sourceRef)
 where
  resolveTarget source =
    renderImageRef . publicImageTarget <$> find (matchesSource source) requiredPublicImageMirrors

  matchesSource source mirror =
    any
      ((== renderImageRef source) . renderImageRef)
      (publicImagePrimarySource mirror : publicImageSourceAliases mirror)

harborMirrorSourceCandidates :: String -> Maybe [String]
harborMirrorSourceCandidates sourceRef =
  either (const Nothing) resolveCandidates (parseImageRef sourceRef)
 where
  resolveCandidates source =
    orderedCandidateSources source <$> find (matchesSource source) requiredPublicImageMirrors

  orderedCandidateSources source mirror =
    nub
      ( map
          renderImageRef
          (source : filter (/= source) (publicImagePrimarySource mirror : publicImageSourceAliases mirror))
      )

  matchesSource source mirror =
    any
      ((== renderImageRef source) . renderImageRef)
      (publicImagePrimarySource mirror : publicImageSourceAliases mirror)

harborImageRefFromSource :: ImageRef -> ImageRef
harborImageRefFromSource source =
  ImageRef
    harborRegistryEndpoint
    (harborMirrorProject ++ "/" ++ mirroredRepository source)
    (imageTag source)

harborImageRefFromRepository :: String -> String -> ImageRef
harborImageRefFromRepository repository tag =
  ImageRef harborRegistryEndpoint (harborMirrorProject ++ "/" ++ repository) tag

mirroredRepository :: ImageRef -> String
mirroredRepository source
  | imageRegistry source == "docker.io" = imageRepository source
  | otherwise = imageRegistry source ++ "/" ++ imageRepository source

splitRegistry :: String -> (String, String)
splitRegistry imageRef =
  let (firstSegment, remainderWithSlash) = break (== '/') imageRef
      hasPathSeparator = not (null remainderWithSlash)
      hasRegistryPrefix = '.' `elem` firstSegment || ':' `elem` firstSegment || firstSegment == "localhost"
   in if hasPathSeparator && hasRegistryPrefix
        then (firstSegment, drop 1 remainderWithSlash)
        else ("docker.io", imageRef)

normalizeRepository :: String -> String -> String
normalizeRepository registry remainder
  | registry == "docker.io" && '/' `notElem` remainder = "library/" ++ remainder
  | otherwise = remainder

splitTag :: String -> (String, String)
splitTag repositoryWithTag =
  case break (== ':') (reverse repositoryWithTag) of
    (reversedTag, ':' : reversedRepository)
      | '/' `notElem` reversedTag ->
          (reverse reversedRepository, reverse reversedTag)
    _ -> (repositoryWithTag, "latest")

trimWhitespace :: String -> String
trimWhitespace = reverse . dropWhile isSpace . reverse . dropWhile isSpace
