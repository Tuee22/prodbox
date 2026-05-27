{-# LANGUAGE OverloadedStrings #-}

-- | Substrate-aware platform install paths for the AWS substrate.
--
-- The home substrate's chart-platform install (MetalLB, Envoy Gateway,
-- cert-manager, ACME ClusterIssuer, Percona operator) lives in
-- `src/Prodbox/CLI/Rke2.hs::ensureClusterPlatformRuntime` and is
-- specialized to the operator's home cluster — including Harbor-mirrored
-- image references and MetalLB-based LoadBalancer IPs. The AWS substrate
-- (EKS) needs a different install path: AWS Load Balancer Controller
-- (replacing MetalLB), upstream-registry images (Harbor is not present on
-- the EKS substrate), and cert-manager scoped to the per-substrate
-- Route 53 subzone (rendered by
-- `acmeClusterIssuerSpec SubstrateAws` in `Prodbox.CLI.Rke2`).
--
-- Sprint 7.5.b.ii.d.II lands the AWS Load Balancer Controller install
-- function `ensureAwsLoadBalancerControllerRuntime`. The corresponding
-- Envoy Gateway + cert-manager install paths land in follow-up
-- sub-sprints; see the deliverable inventory in
-- `DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`.
module Prodbox.Lib.AwsSubstratePlatform
  ( ensureAwsLoadBalancerControllerRuntime
  , awsLoadBalancerControllerChartRef
  , awsLoadBalancerControllerChartVersion
  , awsLoadBalancerControllerReleaseName
  , awsLoadBalancerControllerNamespace
  , awsLoadBalancerControllerServiceAccountName
  , ensureAwsSubstrateEnvoyGatewayRuntime
  , awsSubstrateEnvoyGatewayChartRef
  , awsSubstrateEnvoyGatewayChartVersion
  , awsSubstrateEnvoyGatewayReleaseName
  , awsSubstrateEnvoyGatewayNamespace
  , ensureAwsSubstrateCertManagerRuntime
  , awsSubstrateCertManagerChartRef
  , awsSubstrateCertManagerChartVersion
  , awsSubstrateCertManagerReleaseName
  , awsSubstrateCertManagerNamespace
  , ensureAwsSubstrateAcmeRuntime
  , ensureAwsSubstratePlatformRuntime
  , applyEksContainerdMirrorDaemonSet
  , applyEksImageMirrorJob
  , awsSubstratePlatformRuntimeStepDescriptions
  )
where

import Data.Aeson
  ( Value
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAsciiUpper)
import Data.Text qualified as Text
import Prodbox.CLI.Output
  ( writeError
  , writeOutputLine
  )
import Prodbox.CLI.Rke2
  ( MinioImageSource (..)
  , acmeRuntimeManifestWith
  , ensureGatewayImagesForSubstrate
  , ensureHarborRegistryRuntime
  , ensureHarborRegistryStorageBackend
  , ensureMinioRuntime
  , ensurePostgresOperatorRuntime
  , ensurePublicEdgeWorkloadImageForSubstrate
  )
import Prodbox.ContainerImage (requiredPublicImagePairs)
import Prodbox.Error (fatalError)
import Prodbox.Infra.AwsEksTestStack
  ( AwsEksTestStackSnapshot (..)
  , loadAwsEksTestStackSnapshot
  )
import Prodbox.Lib.EksContainerdMirror
  ( defaultProdboxMirrorConfig
  , eksContainerdMirrorDaemonSetManifest
  )
import Prodbox.Lib.EksImageMirror
  ( defaultEksImageMirrorConfig
  , eksImageMirrorJobManifest
  , mirrorJobName
  , mirrorJobNamespace
  )
import Prodbox.PublicEdge (resolveSubstrateHostedZoneId)
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( ConfigFile (..)
  , Credentials (..)
  , ValidatedSettings (..)
  , aws
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , runSubprocessStreaming
  )
import Prodbox.Substrate (Substrate (..))
import System.Directory (createDirectoryIfMissing, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)

awsLoadBalancerControllerRepoName :: String
awsLoadBalancerControllerRepoName = "eks"

awsLoadBalancerControllerRepoUrl :: String
awsLoadBalancerControllerRepoUrl = "https://aws.github.io/eks-charts"

awsLoadBalancerControllerChartRef :: String
awsLoadBalancerControllerChartRef =
  awsLoadBalancerControllerRepoName ++ "/aws-load-balancer-controller"

-- Pinned to a known-good upstream release. Update in lockstep with the
-- vendored IAM policy at pulumi/aws-eks/aws-lb-controller-iam-policy.json.
awsLoadBalancerControllerChartVersion :: String
awsLoadBalancerControllerChartVersion = "1.8.4"

awsLoadBalancerControllerReleaseName :: String
awsLoadBalancerControllerReleaseName = "aws-load-balancer-controller"

awsLoadBalancerControllerNamespace :: String
awsLoadBalancerControllerNamespace = "kube-system"

awsLoadBalancerControllerServiceAccountName :: String
awsLoadBalancerControllerServiceAccountName = "aws-load-balancer-controller"

-- | Install (or upgrade) the AWS Load Balancer Controller on the
-- AWS-substrate EKS cluster. The caller must have `KUBECONFIG` pointed at
-- the EKS cluster (see
-- `Prodbox.CLI.Charts.withSubstrateEnvironment`).
--
-- The function:
--   1. Validates that the snapshot carries the IRSA role ARN and cluster
--      name fields populated by Sprint 7.5.b.ii.b.
--   2. Applies a service account manifest into kube-system annotated
--      with the IRSA role ARN.
--   3. Adds the eks-charts Helm repo and installs the controller chart
--      with `serviceAccount.create=false` (we own the service account).
--   4. Waits for the controller deployment to become ready.
ensureAwsLoadBalancerControllerRuntime
  :: FilePath -> String -> AwsEksTestStackSnapshot -> IO ExitCode
ensureAwsLoadBalancerControllerRuntime repoRoot defaultRegion snapshot
  | null (eksSnapshotAwsLbControllerRoleArn snapshot) =
      failWith
        "AWS LB Controller role ARN is empty; the AWS EKS Pulumi stack must be re-provisioned at or after Sprint 7.5.b.ii.b before installing the controller."
  | null (eksSnapshotClusterName snapshot) =
      failWith "AWS EKS cluster name is empty in the captured snapshot."
  | otherwise = do
      writeOutputLine
        ( "Installing AWS Load Balancer Controller on EKS cluster "
            ++ eksSnapshotClusterName snapshot
        )
      saExit <- applyServiceAccountManifest repoRoot snapshot
      case saExit of
        ExitFailure _ -> pure saExit
        ExitSuccess -> do
          repoExit <-
            ensureHelmRepoAdded
              awsLoadBalancerControllerRepoName
              awsLoadBalancerControllerRepoUrl
          case repoExit of
            ExitFailure _ -> pure repoExit
            ExitSuccess -> do
              installExit <- helmUpgradeInstall defaultRegion snapshot
              case installExit of
                ExitFailure _ -> pure installExit
                ExitSuccess -> waitForDeployment awsLoadBalancerControllerNamespace awsLoadBalancerControllerReleaseName

applyServiceAccountManifest :: FilePath -> AwsEksTestStackSnapshot -> IO ExitCode
applyServiceAccountManifest repoRoot snapshot =
  withTempJsonFile
    repoRoot
    "aws-lb-controller-sa"
    (encode (serviceAccountManifest snapshot))
    ( \manifestPath ->
        runStreaming
          Subprocess
            { subprocessPath = "kubectl"
            , subprocessArguments = ["apply", "-f", manifestPath]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
    )

serviceAccountManifest :: AwsEksTestStackSnapshot -> Value
serviceAccountManifest snapshot =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("ServiceAccount" :: String)
    , "metadata"
        .= object
          [ "name" .= awsLoadBalancerControllerServiceAccountName
          , "namespace" .= awsLoadBalancerControllerNamespace
          , "annotations"
              .= object
                [ Key.fromString "eks.amazonaws.com/role-arn"
                    .= eksSnapshotAwsLbControllerRoleArn snapshot
                ]
          , "labels"
              .= object
                [ Key.fromString "app.kubernetes.io/name"
                    .= ("aws-load-balancer-controller" :: String)
                , Key.fromString "app.kubernetes.io/managed-by"
                    .= ("prodbox" :: String)
                ]
          ]
    ]

ensureHelmRepoAdded :: String -> String -> IO ExitCode
ensureHelmRepoAdded repoName repoUrl = do
  repoAddResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "helm"
        , subprocessArguments = ["repo", "add", repoName, repoUrl]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Nothing
        }
  case repoAddResult of
    Failure err -> failWith ("failed to start helm repo add: " ++ err)
    Success output ->
      case processExitCode output of
        ExitSuccess -> updateRepo
        ExitFailure _
          | isAlreadyExistsError output -> updateRepo
          | otherwise ->
              failWith
                ("Failed to add Helm repo " ++ repoName ++ ": " ++ outputDetail output)
 where
  updateRepo =
    runStreaming
      Subprocess
        { subprocessPath = "helm"
        , subprocessArguments = ["repo", "update", repoName]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Nothing
        }

helmUpgradeInstall :: String -> AwsEksTestStackSnapshot -> IO ExitCode
helmUpgradeInstall defaultRegion snapshot =
  runStreaming
    Subprocess
      { subprocessPath = "helm"
      , subprocessArguments =
          [ "upgrade"
          , "--install"
          , awsLoadBalancerControllerReleaseName
          , awsLoadBalancerControllerChartRef
          , "--version"
          , awsLoadBalancerControllerChartVersion
          , "--namespace"
          , awsLoadBalancerControllerNamespace
          , "--create-namespace"
          , "--wait"
          , "--atomic"
          , "--timeout"
          , "10m0s"
          , "--set-string"
          , "clusterName=" ++ eksSnapshotClusterName snapshot
          , "--set"
          , "serviceAccount.create=false"
          , "--set-string"
          , "serviceAccount.name=" ++ awsLoadBalancerControllerServiceAccountName
          , "--set-string"
          , "region=" ++ extractRegionFromArn defaultRegion (eksSnapshotAwsLbControllerRoleArn snapshot)
          , "--set-string"
          , "vpcId=" ++ eksSnapshotVpcId snapshot
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Nothing
      }

waitForDeployment :: String -> String -> IO ExitCode
waitForDeployment namespace deploymentName =
  runStreaming
    Subprocess
      { subprocessPath = "kubectl"
      , subprocessArguments =
          [ "-n"
          , namespace
          , "rollout"
          , "status"
          , "deployment/" ++ deploymentName
          , "--timeout=10m"
          ]
      , subprocessEnvironment = Nothing
      , subprocessWorkingDirectory = Nothing
      }

-- Envoy Gateway upstream OCI chart. The home substrate consumes a
-- Harbor-mirrored variant; on the AWS substrate (no Harbor) we install
-- directly from the upstream OCI registry so the EKS cluster can pull the
-- controller and data-plane images without operator-side Harbor wiring.
awsSubstrateEnvoyGatewayChartRef :: String
awsSubstrateEnvoyGatewayChartRef = "oci://docker.io/envoyproxy/gateway-helm"

awsSubstrateEnvoyGatewayChartVersion :: String
awsSubstrateEnvoyGatewayChartVersion = "v1.4.4"

awsSubstrateEnvoyGatewayReleaseName :: String
awsSubstrateEnvoyGatewayReleaseName = "envoy-gateway"

awsSubstrateEnvoyGatewayNamespace :: String
awsSubstrateEnvoyGatewayNamespace = "envoy-gateway-system"

-- | Install (or upgrade) Envoy Gateway on the AWS-substrate EKS cluster.
-- The caller must have `KUBECONFIG` pointed at the EKS cluster (see
-- `Prodbox.CLI.Charts.withSubstrateEnvironment`).
--
-- Unlike the AWS Load Balancer Controller install, Envoy Gateway is
-- installed from an OCI chart reference rather than a classic Helm
-- repository, so this function does not call `helm repo add` first. The
-- chart provisions the Envoy Gateway controller deployment plus its
-- supporting CRDs; the controller picks up `Gateway`/`HTTPRoute` resources
-- created later by the chart-platform layer.
ensureAwsSubstrateEnvoyGatewayRuntime :: IO ExitCode
ensureAwsSubstrateEnvoyGatewayRuntime = do
  writeOutputLine
    ( "Installing Envoy Gateway "
        ++ awsSubstrateEnvoyGatewayChartVersion
        ++ " on the AWS-substrate EKS cluster"
    )
  installExit <-
    runStreaming
      Subprocess
        { subprocessPath = "helm"
        , subprocessArguments =
            [ "upgrade"
            , "--install"
            , awsSubstrateEnvoyGatewayReleaseName
            , awsSubstrateEnvoyGatewayChartRef
            , "--version"
            , awsSubstrateEnvoyGatewayChartVersion
            , "--namespace"
            , awsSubstrateEnvoyGatewayNamespace
            , "--create-namespace"
            , "--wait"
            , "--atomic"
            , "--timeout"
            , "10m0s"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Nothing
        }
  case installExit of
    ExitFailure _ -> pure installExit
    ExitSuccess ->
      waitForDeployment awsSubstrateEnvoyGatewayNamespace awsSubstrateEnvoyGatewayReleaseName

-- cert-manager upstream chart. The home substrate consumes Harbor-mirrored
-- cert-manager controller, webhook, cainjector, acmesolver, and
-- startupapicheck images via `Prodbox.ContainerImage`; on the AWS
-- substrate (no Harbor) we install the upstream Jetstack chart directly so
-- the EKS cluster pulls images from quay.io. The substrate-aware ACME
-- `ClusterIssuer` rendering (with `substrateHostedZoneId settings
-- SubstrateAws` resolving to the per-substrate subzone) is already in
-- place from Sprint `7.5.b.ii.a`; this install lays down the cert-manager
-- runtime that the ClusterIssuer needs.
awsSubstrateCertManagerRepoName :: String
awsSubstrateCertManagerRepoName = "jetstack"

awsSubstrateCertManagerRepoUrl :: String
awsSubstrateCertManagerRepoUrl = "https://charts.jetstack.io"

awsSubstrateCertManagerChartRef :: String
awsSubstrateCertManagerChartRef = awsSubstrateCertManagerRepoName ++ "/cert-manager"

-- Pinned to the same release the home substrate uses so the runtime
-- behavior is consistent across substrates. Keep aligned with
-- `certManagerChartVersion` in `Prodbox.CLI.Rke2` when bumping versions.
awsSubstrateCertManagerChartVersion :: String
awsSubstrateCertManagerChartVersion = "v1.16.2"

awsSubstrateCertManagerReleaseName :: String
awsSubstrateCertManagerReleaseName = "cert-manager"

awsSubstrateCertManagerNamespace :: String
awsSubstrateCertManagerNamespace = "cert-manager"

-- | Install (or upgrade) cert-manager on the AWS-substrate EKS cluster.
-- The caller must have `KUBECONFIG` pointed at the EKS cluster.
--
-- The chart provisions the cert-manager controller, webhook, and
-- cainjector deployments plus the cert-manager CRDs (`crds.enabled=true`).
-- After the install, the function waits for the three deployments to
-- become ready. The downstream substrate-aware `ClusterIssuer` (rendered
-- with `SubstrateAws` to target the per-substrate Route 53 subzone) is
-- applied separately by the orchestrator in Sprint `7.5.b.ii.d.II.δ`.
ensureAwsSubstrateCertManagerRuntime :: IO ExitCode
ensureAwsSubstrateCertManagerRuntime = do
  writeOutputLine
    ( "Installing cert-manager "
        ++ awsSubstrateCertManagerChartVersion
        ++ " on the AWS-substrate EKS cluster"
    )
  repoExit <-
    ensureHelmRepoAdded awsSubstrateCertManagerRepoName awsSubstrateCertManagerRepoUrl
  case repoExit of
    ExitFailure _ -> pure repoExit
    ExitSuccess -> do
      installExit <-
        runStreaming
          Subprocess
            { subprocessPath = "helm"
            , subprocessArguments =
                [ "upgrade"
                , "--install"
                , awsSubstrateCertManagerReleaseName
                , awsSubstrateCertManagerChartRef
                , "--version"
                , awsSubstrateCertManagerChartVersion
                , "--namespace"
                , awsSubstrateCertManagerNamespace
                , "--create-namespace"
                , "--wait"
                , "--atomic"
                , "--timeout"
                , "10m0s"
                , "--set"
                , "crds.enabled=true"
                ]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Nothing
            }
      case installExit of
        ExitFailure _ -> pure installExit
        ExitSuccess ->
          waitForCertManagerDeployments

waitForCertManagerDeployments :: IO ExitCode
waitForCertManagerDeployments = go deployments
 where
  deployments =
    [ awsSubstrateCertManagerReleaseName
    , awsSubstrateCertManagerReleaseName ++ "-webhook"
    , awsSubstrateCertManagerReleaseName ++ "-cainjector"
    ]
  go [] = pure ExitSuccess
  go (deployment : rest) = do
    exitCode <- waitForDeployment awsSubstrateCertManagerNamespace deployment
    case exitCode of
      ExitFailure _ -> pure exitCode
      ExitSuccess -> go rest

-- | Apply the substrate-aware ACME `ClusterIssuer` and its supporting
-- Route 53 credentials secret on the AWS-substrate EKS cluster. The
-- `acmeClusterIssuerSpec` invocation here passes `SubstrateAws`, so the
-- ClusterIssuer's DNS01 `hostedZoneID` resolves to
-- `aws_substrate.hosted_zone_id` (the per-substrate subzone provisioned
-- by `pulumi aws-subzone-resources`).
ensureAwsSubstrateAcmeRuntime :: FilePath -> ValidatedSettings -> String -> String -> IO ExitCode
ensureAwsSubstrateAcmeRuntime repoRoot settings prodboxId labelValue = do
  writeOutputLine "Applying AWS-substrate ACME ClusterIssuer + Route 53 DNS01 credentials"
  hostedZoneResult <- resolveSubstrateHostedZoneId repoRoot settings SubstrateAws
  case hostedZoneResult of
    Left err -> failWith err
    Right hostedZoneId -> do
      let manifest =
            acmeRuntimeManifestWith SubstrateAws settings hostedZoneId prodboxId labelValue
          -- Wrap the manifest list in a `v1/List` so `kubectl apply -f` accepts
          -- the file (kubectl does not accept bare JSON arrays at the top level).
          -- Matches the home-substrate pattern in
          -- `Prodbox.CLI.Rke2::withTemporaryJsonManifest`.
          manifestList =
            object
              [ "apiVersion" .= ("v1" :: String)
              , "kind" .= ("List" :: String)
              , "items" .= manifest
              ]
      withTempJsonFile
        repoRoot
        "aws-substrate-acme-runtime"
        (encode manifestList)
        ( \manifestPath -> do
            applyExit <-
              runStreaming
                Subprocess
                  { subprocessPath = "kubectl"
                  , subprocessArguments = ["apply", "-f", manifestPath]
                  , subprocessEnvironment = Nothing
                  , subprocessWorkingDirectory = Just repoRoot
                  }
            case applyExit of
              ExitFailure _ -> pure applyExit
              ExitSuccess ->
                runStreaming
                  Subprocess
                    { subprocessPath = "kubectl"
                    , subprocessArguments =
                        [ "wait"
                        , "--for=condition=Ready"
                        , "clusterissuer/letsencrypt-http01"
                        , "--timeout=300s"
                        ]
                    , subprocessEnvironment = Nothing
                    , subprocessWorkingDirectory = Just repoRoot
                    }
        )

-- | Orchestrate the full AWS-substrate platform install: AWS Load
-- Balancer Controller, Envoy Gateway, cert-manager, and the
-- substrate-aware ACME `ClusterIssuer`. Idempotent: each underlying step
-- uses `helm upgrade --install` and `kubectl apply`, so repeated runs
-- converge to the desired state.
--
-- Preconditions:
--   * `prodbox pulumi eks-resources` has been run, populating
--     `.prodbox-state/aws-eks-test/stack-snapshot.json` with the IAM/IRSA
--     output fields added in Sprint `7.5.b.ii.b`.
--   * `prodbox pulumi aws-subzone-resources` has been run, so
--     `aws_substrate.hosted_zone_id` and `aws_substrate.subzone_name` in
--     `prodbox-config.dhall` point at a live Route 53 subzone.
--   * The caller has `KUBECONFIG` pointed at the EKS cluster (see
--     `Prodbox.CLI.Charts.withSubstrateEnvironment`).
ensureAwsSubstratePlatformRuntime
  :: FilePath -> ValidatedSettings -> String -> String -> IO ExitCode
ensureAwsSubstratePlatformRuntime repoRoot settings prodboxId labelValue = do
  writeOutputLine
    ( "Reconciling AWS-substrate platform (LB Controller + Envoy Gateway "
        ++ "+ cert-manager + ACME + containerd registry mirror + MinIO + Harbor)"
    )
  snapshotMaybe <- loadAwsEksTestStackSnapshot repoRoot
  case snapshotMaybe of
    Nothing ->
      failWith
        ( "AWS-substrate platform install requires an existing AWS EKS Pulumi snapshot at "
            ++ ".prodbox-state/aws-eks-test/stack-snapshot.json. Run `prodbox pulumi eks-resources` first."
        )
    Just snapshot -> runSequentially (steps snapshot)
 where
  defaultRegion :: String
  defaultRegion =
    let configured =
          Text.unpack
            (Text.strip (region (aws (validatedConfig settings))))
     in if null configured then "us-east-1" else configured
  steps snapshot =
    [ ensureAwsLoadBalancerControllerRuntime repoRoot defaultRegion snapshot
    , ensureAwsSubstrateEnvoyGatewayRuntime
    , ensureAwsSubstrateCertManagerRuntime
    , ensureAwsSubstrateAcmeRuntime repoRoot settings prodboxId labelValue
    , applyEksContainerdMirrorDaemonSet repoRoot
    , ensureMinioRuntime repoRoot SubstrateAws MinioBootstrapPublic
    , ensureHarborRegistryStorageBackend repoRoot
    , ensureHarborRegistryRuntime repoRoot SubstrateAws
    , applyEksImageMirrorJob repoRoot
    , ensureGatewayImagesForSubstrate SubstrateAws repoRoot prodboxId
    , ensurePublicEdgeWorkloadImageForSubstrate SubstrateAws repoRoot prodboxId
    , ensurePostgresOperatorRuntime repoRoot prodboxId labelValue
    , ensureMinioRuntime repoRoot SubstrateAws MinioSteadyStateHarbor
    ]

-- | Pure listing of the orchestration steps
-- 'ensureAwsSubstratePlatformRuntime' sequences, in execution order.
-- Used by unit tests to verify the ordering contract without driving
-- live subprocesses; also useful for operator-facing documentation.
-- Keep in lockstep with the @steps@ binding above.
awsSubstratePlatformRuntimeStepDescriptions :: [String]
awsSubstratePlatformRuntimeStepDescriptions =
  [ "ensureAwsLoadBalancerControllerRuntime"
  , "ensureAwsSubstrateEnvoyGatewayRuntime"
  , "ensureAwsSubstrateCertManagerRuntime"
  , "ensureAwsSubstrateAcmeRuntime"
  , "applyEksContainerdMirrorDaemonSet"
  , "ensureMinioRuntime SubstrateAws MinioBootstrapPublic"
  , "ensureHarborRegistryStorageBackend"
  , "ensureHarborRegistryRuntime SubstrateAws"
  , "applyEksImageMirrorJob"
  , "ensureGatewayImagesForSubstrate SubstrateAws"
  , "ensurePublicEdgeWorkloadImageForSubstrate SubstrateAws"
  , "ensurePostgresOperatorRuntime"
  , "ensureMinioRuntime SubstrateAws MinioSteadyStateHarbor"
  ]

-- | Sprint 7.5.c.iv: apply the in-cluster image-mirror Job rendered
-- by 'Prodbox.Lib.EksImageMirror' so every public image required by
-- the canonical chart set lands in the EKS-side Harbor before the
-- Percona operator + steady-state MinIO reconcile steps (which both
-- pull from Harbor) execute. After applying the Job manifest, blocks
-- until @kubectl wait --for=condition=complete@ on the Job returns
-- success; the @backoffLimit=2@ on the Job means transient pull
-- failures (e.g. upstream registry rate-limit) retry within the
-- single Job rather than failing the orchestrator immediately.
applyEksImageMirrorJob :: FilePath -> IO ExitCode
applyEksImageMirrorJob repoRoot = do
  let cfg = defaultEksImageMirrorConfig
      jobNs = mirrorJobNamespace cfg
      jobNm = mirrorJobName cfg
  writeOutputLine
    ( "Applying in-cluster image-mirror Job ("
        ++ jobNs
        ++ "/"
        ++ jobNm
        ++ ")"
    )
  let manifestList =
        object
          [ "apiVersion" .= ("v1" :: String)
          , "kind" .= ("List" :: String)
          , "items" .= [eksImageMirrorJobManifest cfg requiredPublicImagePairs]
          ]
  applyExit <-
    withTempJsonFile
      repoRoot
      "eks-image-mirror-job"
      (encode manifestList)
      ( \manifestPath ->
          runStreaming
            Subprocess
              { subprocessPath = "kubectl"
              , subprocessArguments = ["apply", "-f", manifestPath]
              , subprocessEnvironment = Nothing
              , subprocessWorkingDirectory = Just repoRoot
              }
      )
  case applyExit of
    ExitFailure _ -> pure applyExit
    ExitSuccess ->
      runStreaming
        Subprocess
          { subprocessPath = "kubectl"
          , subprocessArguments =
              [ "wait"
              , "--for=condition=complete"
              , "job/" ++ jobNm
              , "-n"
              , jobNs
              , "--timeout=20m"
              ]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just repoRoot
          }

-- | Sprint 7.5.c.iii: apply the EKS containerd registry-mirror
-- DaemonSet rendered by 'Prodbox.Lib.EksContainerdMirror' so EKS nodes
-- route @127.0.0.1:30080@ chart-image pulls into the in-cluster Harbor
-- NodePort installed two steps later in this orchestrator. Idempotent:
-- the bootstrap script only restarts containerd when its on-disk
-- config actually changed.
applyEksContainerdMirrorDaemonSet :: FilePath -> IO ExitCode
applyEksContainerdMirrorDaemonSet repoRoot = do
  writeOutputLine
    "Applying EKS containerd registry-mirror DaemonSet (kube-system/prodbox-containerd-mirror)"
  let manifestList =
        object
          [ "apiVersion" .= ("v1" :: String)
          , "kind" .= ("List" :: String)
          , "items" .= [eksContainerdMirrorDaemonSetManifest defaultProdboxMirrorConfig]
          ]
  withTempJsonFile
    repoRoot
    "eks-containerd-mirror"
    (encode manifestList)
    ( \manifestPath ->
        runStreaming
          Subprocess
            { subprocessPath = "kubectl"
            , subprocessArguments = ["apply", "-f", manifestPath]
            , subprocessEnvironment = Nothing
            , subprocessWorkingDirectory = Just repoRoot
            }
    )

runSequentially :: [IO ExitCode] -> IO ExitCode
runSequentially [] = pure ExitSuccess
runSequentially (step : rest) = do
  exitCode <- step
  case exitCode of
    ExitFailure _ -> pure exitCode
    ExitSuccess -> runSequentially rest

-- | Extract the region segment from an IAM role ARN. IAM roles use the
-- form `arn:aws:iam::<account>:role/<name>` and do not embed a region,
-- so the empty fourth segment is the expected case for IRSA role ARNs.
-- We preserve empty segments during parsing (unlike `words`-style helpers
-- that collapse adjacent delimiters) so the account number isn't
-- mistakenly returned as the region; when the region segment is empty
-- the caller's `defaultRegion` is used.
extractRegionFromArn :: String -> String -> String
extractRegionFromArn defaultRegion arn =
  case splitKeepingEmpty ':' arn of
    _ : _ : _ : regionField : _
      | not (null regionField) -> regionField
    _ -> defaultRegion
 where
  splitKeepingEmpty :: Char -> String -> [String]
  splitKeepingEmpty delim s =
    let (chunk, rest) = break (== delim) s
     in case rest of
          [] -> [chunk]
          _ : remainder -> chunk : splitKeepingEmpty delim remainder

isAlreadyExistsError :: ProcessOutput -> Bool
isAlreadyExistsError output =
  let combined = outputDetail output
   in "already exists" `containsCI` combined

containsCI :: String -> String -> Bool
containsCI needle haystack =
  let lc = map toAsciiLower
   in lc needle `isInfixOf'` lc haystack
 where
  isInfixOf' n h = case h of
    [] -> null n
    _ : rest -> startsWith n h || isInfixOf' n rest
  startsWith [] _ = True
  startsWith _ [] = False
  startsWith (x : xs) (y : ys) = x == y && startsWith xs ys
  toAsciiLower c
    | isAsciiUpper c = toEnum (fromEnum c + 32)
    | otherwise = c

outputDetail :: ProcessOutput -> String
outputDetail output = processStderr output ++ processStdout output

runStreaming :: Subprocess -> IO ExitCode
runStreaming spec = do
  result <- runSubprocessStreaming spec
  case result of
    Failure err -> failWith err
    Success exitCode -> pure exitCode

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)

withTempJsonFile :: FilePath -> String -> BL.ByteString -> (FilePath -> IO ExitCode) -> IO ExitCode
withTempJsonFile repoRoot prefix payload action = do
  let tempDir = repoRoot </> ".prodbox-state" </> "tmp"
  createDirectoryIfMissing True tempDir
  (path, handle) <- openTempFile tempDir (prefix ++ "-")
  BL.hPut handle payload
  hClose handle
  exitCode <- action path
  removeFile path
  pure exitCode
