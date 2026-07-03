module Prodbox.ContainerImage
  ( ImageRef (..)
  , EnvoyGatewayRelease (..)
  , PlatformComponent (..)
  , envoyGatewayRelease
  , envoyGatewayChartVersion
  , certManagerChartVersion
  , postgresOperatorChartVersion
  , minioChartVersion
  , sharedPlatformComponents
  , platformComponentLabel
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
  , harborPulsarImage
  , harborRedisImage
  , harborRuntimeImageRepository
  , harborRuntimeRepository
  , normalizeImageRefText
  , parseImageRef
  , publicCurlImage
  , publicRedisImage
  , publicPulsarImage
  , publicVaultImage
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

-- | The single union runtime image repository. One image serves every
-- in-cluster role (gateway daemon + api / websocket workloads); the role is
-- selected by each chart's container @args:@, not by separate images.
harborRuntimeRepository :: String
harborRuntimeRepository = harborMirrorProject ++ "/prodbox-runtime"

harborRuntimeImageRepository :: String
harborRuntimeImageRepository = harborRegistryEndpoint ++ "/" ++ harborRuntimeRepository

-- | Sprint 7.12: the single Envoy Gateway release SSoT. The Envoy Gateway
-- Helm chart version, the control-plane (gateway controller) image, and the
-- data-plane (Envoy proxy) image are pinned together as one coherent
-- release so the EG-chart / Envoy-data-plane pairing can only ever be
-- changed in one place. Both substrate installers (home: MetalLB + the
-- in-cluster Harbor NodePort; AWS: AWS Load Balancer Controller + the
-- EKS-side Harbor + node-local registry proxy) consume this value for all
-- three pinning sites; there is no second place to set a version
-- independently, so the EG-@1.4.4@ / Envoy-@1.37@ skew (audit C79) is
-- eliminated by construction.
--
-- The pinned release is the proven home pairing: EG chart @v1.7.2@ /
-- control plane @v1.7.2@ / data plane @distroless-v1.37.0@.
data EnvoyGatewayRelease = EnvoyGatewayRelease
  { envoyGatewayReleaseChartVersion :: String
  , envoyGatewayReleaseControlPlaneImage :: ImageRef
  , envoyGatewayReleaseDataPlaneImage :: ImageRef
  }
  deriving (Eq, Show)

envoyGatewayRelease :: EnvoyGatewayRelease
envoyGatewayRelease =
  EnvoyGatewayRelease
    { envoyGatewayReleaseChartVersion = "v1.7.2"
    , envoyGatewayReleaseControlPlaneImage =
        harborImageRefFromRepository "envoy-gateway-mirror" "v1.7.2"
    , envoyGatewayReleaseDataPlaneImage =
        harborImageRefFromRepository "envoy-proxy-mirror" "distroless-v1.37.0"
    }

-- | The Envoy Gateway Helm chart version, sourced from the single
-- 'envoyGatewayRelease' SSoT. Consumed by both substrate installers'
-- @helm upgrade --install@ @--version@ argument.
envoyGatewayChartVersion :: String
envoyGatewayChartVersion = envoyGatewayReleaseChartVersion envoyGatewayRelease

harborEnvoyGatewayImage :: ImageRef
harborEnvoyGatewayImage = envoyGatewayReleaseControlPlaneImage envoyGatewayRelease

harborEnvoyProxyImage :: ImageRef
harborEnvoyProxyImage = envoyGatewayReleaseDataPlaneImage envoyGatewayRelease

-- | Upstream control-plane image tag, derived from the single
-- 'envoyGatewayRelease' SSoT so the Harbor mirror-source entry cannot drift
-- from the pinned release.
envoyGatewayControlPlaneTag :: String
envoyGatewayControlPlaneTag = imageTag (envoyGatewayReleaseControlPlaneImage envoyGatewayRelease)

-- | Upstream data-plane image tag, derived from the single
-- 'envoyGatewayRelease' SSoT.
envoyGatewayDataPlaneTag :: String
envoyGatewayDataPlaneTag = imageTag (envoyGatewayReleaseDataPlaneImage envoyGatewayRelease)

-- | Sprint 7.12: the shared platform-component inventory. Substrate
-- equivalence ("the home local substrate and the AWS substrate stand up the
-- same set of services") is enforced structurally by declaring the shared
-- component set once here and requiring both installers
-- ('Prodbox.CLI.Rke2' / 'Prodbox.Lib.ChartPlatform' for home,
-- 'Prodbox.Lib.AwsSubstratePlatform' for AWS) to cover every entry. The
-- genuinely substrate-specific LOWER layer (MetalLB vs the AWS Load Balancer
-- Controller, the parent zone vs the delegated subzone, the node-local
-- registry proxy) is intentionally NOT in this inventory: those differences
-- are correct, so they are not asserted equal.
data PlatformComponent
  = ComponentGateway
  | ComponentKeycloak
  | ComponentKeycloakPostgres
  | ComponentVscode
  | ComponentApi
  | ComponentRedis
  | ComponentWebsocket
  | ComponentMinio
  | ComponentHarbor
  | ComponentPerconaPostgresOperator
  | ComponentEnvoyGateway
  | ComponentCertManager
  | ComponentZeroSslDns01
  | ComponentVault
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | Every shared platform component both substrate installers must cover.
-- Enumerated via 'Bounded'/'Enum' so adding a constructor automatically
-- extends the coverage contract (the unit test then forces both installers
-- to declare coverage of the new entry).
sharedPlatformComponents :: [PlatformComponent]
sharedPlatformComponents = [minBound .. maxBound]

-- | Human-readable label for a shared platform component (operator-facing
-- diagnostics and the coverage test's failure message).
platformComponentLabel :: PlatformComponent -> String
platformComponentLabel component =
  case component of
    ComponentGateway -> "gateway"
    ComponentKeycloak -> "keycloak"
    ComponentKeycloakPostgres -> "keycloak-postgres"
    ComponentVscode -> "vscode"
    ComponentApi -> "api"
    ComponentRedis -> "redis"
    ComponentWebsocket -> "websocket"
    ComponentMinio -> "minio"
    ComponentHarbor -> "harbor"
    ComponentPerconaPostgresOperator -> "percona-postgres-operator"
    ComponentEnvoyGateway -> "envoy-gateway"
    ComponentCertManager -> "cert-manager"
    ComponentZeroSslDns01 -> "zerossl-dns01"
    ComponentVault -> "vault"

harborPostgresOperatorImage :: ImageRef
harborPostgresOperatorImage =
  harborImageRefFromRepository "percona-postgresql-operator-mirror" "2.9.0"

-- | Sprint 7.12: the Percona PostgreSQL operator Helm chart version, sourced
-- from the single operator image tag so chart + image stay in lockstep. The
-- Percona operator is a SHARED platform component, installed once by
-- 'Prodbox.CLI.Rke2.ensurePostgresOperatorRuntime' for both substrates.
postgresOperatorChartVersion :: String
postgresOperatorChartVersion = imageTag harborPostgresOperatorImage

-- | Sprint 7.12: the MinIO Helm chart version. MinIO is a SHARED platform
-- component installed once by 'Prodbox.CLI.Rke2.ensureMinioRuntime' for both
-- substrates; the chart version is its own pin (it does not track the MinIO
-- image RELEASE tag), but it lives here as the single sanctioned source so it
-- can never be re-pinned per substrate.
minioChartVersion :: String
minioChartVersion = "5.4.0"

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

-- | Sprint 7.15: the HashiCorp Vault CLI image used by the in-cluster
-- Vault-login init container that materializes the ACME EAB HMAC secret
-- (and matching the @vault.image@ the Sprint 3.18 chart materializers use,
-- e.g. @charts/vscode/templates/securitypolicy-client-secret-job.yaml@).
publicVaultImage :: ImageRef
publicVaultImage = ImageRef "docker.io" "hashicorp/vault" "1.18.3"

publicRedisImage :: ImageRef
publicRedisImage = ImageRef "docker.io" "library/redis" "7.4.2"

harborRedisImage :: ImageRef
harborRedisImage = harborImageRefFromRepository "redis-mirror" "7.4.2"

publicPulsarImage :: ImageRef
publicPulsarImage = ImageRef "docker.io" "apachepulsar/pulsar" "4.0.2"

harborPulsarImage :: ImageRef
harborPulsarImage = harborImageRefFromRepository "pulsar-mirror" "4.0.2"

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

-- | Sprint 7.12: the cert-manager Helm chart version, sourced from the
-- single cert-manager controller image tag so chart + image stay in
-- lockstep. cert-manager is a SHARED platform component, so both substrate
-- installers consume this value rather than re-pinning the chart version on
-- a per-substrate branch.
certManagerChartVersion :: String
certManagerChartVersion = imageTag harborCertManagerControllerImage

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
      publicPulsarImage
      []
      harborPulsarImage
  , mirroredPublicImage
      (ImageRef "docker.io" "envoyproxy/gateway" envoyGatewayControlPlaneTag)
      [ImageRef "mirror.gcr.io" "envoyproxy/gateway" envoyGatewayControlPlaneTag]
      harborEnvoyGatewayImage
  , mirroredPublicImage
      (ImageRef "docker.io" "envoyproxy/envoy" envoyGatewayDataPlaneTag)
      [ImageRef "mirror.gcr.io" "envoyproxy/envoy" envoyGatewayDataPlaneTag]
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
