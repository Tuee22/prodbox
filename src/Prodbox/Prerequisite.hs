module Prodbox.Prerequisite
  ( prerequisiteRegistry
  )
where

import Data.Map.Strict
  ( Map
  )
import Data.Map.Strict qualified as Map
import Prodbox.Effect
  ( Effect (..)
  , Validation (..)
  )
import Prodbox.EffectDAG
  ( EffectNode (..)
  )
import Prodbox.PrerequisiteId
  ( PrerequisiteId (..)
  )

-- | Sprint 5.6: the prerequisite registry is keyed by the typed
-- 'PrerequisiteId' rather than a raw @String@, so identifiers are
-- exhaustively matched. Each registered constructor decorates its
-- 'PrerequisiteId' with the 'EffectNode' that validates it; the ad-hoc
-- lifecycle nodes ('K8sWait') are NOT registry members (they are built
-- inline by their command runners and inserted into a per-command
-- registry view).
prerequisiteRegistry :: Map PrerequisiteId EffectNode
prerequisiteRegistry =
  Map.fromList (map keyed allPrerequisites)
 where
  keyed node = (effectNodeId node, node)

allPrerequisites :: [EffectNode]
allPrerequisites =
  [ platformLinux
  , hostSubstrateSupported
  , systemdAvailable
  , supportedUbuntu2404
  , machineIdentity
  , toolCurl
  , toolDig
  , toolKubectl
  , toolDocker
  , toolCtr
  , toolHelm
  , toolSudo
  , toolPulumi
  , toolAws
  , toolSsh
  , toolRke2
  , toolSystemctl
  , settingsObject
  , awsIamHarnessReady
  , kubeconfigExists
  , kubeconfigHomeExists
  , rke2ConfigExists
  , awsCredentialsValid
  , route53Accessible
  , route53LifecycleCapable
  , rke2Installed
  , rke2ServiceExists
  , rke2ServiceActive
  , k8sClusterReachable
  , pulumiLoggedIn
  , k8sReady
  , infraReady
  , publicEdgeReady
  , gatewayDaemonAcquire
  , sesSendingIdentityVerified
  , sesReceiveRuleSetActive
  , sesReceiveBucketAccessible
  ]

platformLinux :: EffectNode
platformLinux =
  EffectNode
    { effectNodeId = PlatformLinux
    , effectNodeDescription = "Require Linux operating system"
    , effectNodeRemedyHint = "Run the supported command surface on a Linux host."
    , effectNodePrerequisites = []
    , effectNodeEffect = Validate RequireLinux
    }

hostSubstrateSupported :: EffectNode
hostSubstrateSupported =
  EffectNode
    { effectNodeId = HostSubstrateSupported
    , effectNodeDescription = "Detect a supported host substrate"
    , effectNodeRemedyHint =
        "Run prodbox on native Linux, Apple Silicon, or Windows with the corresponding Linux lift provider available."
    , effectNodePrerequisites = []
    , effectNodeEffect = Validate RequireHostSubstrateSupported
    }

systemdAvailable :: EffectNode
systemdAvailable =
  EffectNode
    { effectNodeId = SystemdAvailable
    , effectNodeDescription = "Require systemd availability"
    , effectNodeRemedyHint = "Use a systemd-managed host or container with `/run/systemd/system` present."
    , effectNodePrerequisites = [PlatformLinux]
    , effectNodeEffect = Validate RequireSystemd
    }

supportedUbuntu2404 :: EffectNode
supportedUbuntu2404 =
  EffectNode
    { effectNodeId = SupportedUbuntu2404
    , effectNodeDescription = "Require Ubuntu 24.04 LTS"
    , effectNodeRemedyHint = "Run the supported workflow on Ubuntu 24.04 LTS."
    , effectNodePrerequisites = [PlatformLinux]
    , effectNodeEffect = Validate RequireUbuntu2404
    }

machineIdentity :: EffectNode
machineIdentity =
  EffectNode
    { effectNodeId = MachineIdentity
    , effectNodeDescription = "Resolve machine-id and derived prodbox-id"
    , effectNodeRemedyHint = "Ensure `/etc/machine-id` exists and contains the host identity."
    , effectNodePrerequisites = [PlatformLinux]
    , effectNodeEffect = Validate RequireMachineIdentity
    }

toolKubectl :: EffectNode
toolKubectl = toolNode ToolKubectl "Validate kubectl is installed" "kubectl" ["version", "--client=true"] []

toolCurl :: EffectNode
toolCurl = toolNode ToolCurl "Validate curl is installed" "curl" ["--version"] []

toolDig :: EffectNode
toolDig = toolNode ToolDig "Validate dig is installed" "dig" ["-v"] []

toolDocker :: EffectNode
toolDocker = toolNode ToolDocker "Validate docker is installed" "docker" ["--version"] []

toolCtr :: EffectNode
toolCtr = toolNode ToolCtr "Validate ctr is installed" "ctr" ["--help"] []

toolHelm :: EffectNode
toolHelm = toolNode ToolHelm "Validate helm is installed" "helm" ["version", "--short"] []

toolSudo :: EffectNode
toolSudo = toolNode ToolSudo "Validate sudo is installed" "sudo" ["--version"] []

toolPulumi :: EffectNode
toolPulumi = toolNode ToolPulumi "Validate pulumi is installed" "pulumi" ["version"] []

toolAws :: EffectNode
toolAws = toolNode ToolAws "Validate aws CLI is installed" "aws" ["--version"] []

toolSsh :: EffectNode
toolSsh = toolNode ToolSsh "Validate OpenSSH client is installed" "ssh" ["-V"] []

toolRke2 :: EffectNode
toolRke2 =
  toolNode
    ToolRke2
    "Validate rke2 is installed"
    "/usr/local/bin/rke2"
    ["--version"]
    [PlatformLinux]

toolSystemctl :: EffectNode
toolSystemctl =
  toolNode
    ToolSystemctl
    "Validate systemctl is available"
    "systemctl"
    ["--version"]
    [SystemdAvailable]

-- | The single prodbox-settings prerequisite. Sprint 1.31 collapsed the former
-- `settings_loaded` / `settings_object` pair into this one node: both modelled the same
-- `Validate RequireSettings` satisfied condition (the repository config decodes cleanly), so
-- the split carried no extra information. Every former dependent edge now points here.
settingsObject :: EffectNode
settingsObject =
  EffectNode
    { effectNodeId = SettingsObject
    , effectNodeDescription = "Load validated prodbox settings"
    , effectNodeRemedyHint =
        "Run `prodbox config setup`/`prodbox config validate` until `prodbox.dhall` loads cleanly."
    , effectNodePrerequisites = []
    , effectNodeEffect = Validate RequireSettings
    }

awsIamHarnessReady :: EffectNode
awsIamHarnessReady =
  EffectNode
    { effectNodeId = AwsIamHarnessReady
    , effectNodeDescription = "Validate native IAM harness config and test-simulation admin credentials"
    , effectNodeRemedyHint =
        "Configure the AWS IAM harness inputs in `prodbox.dhall` before rerunning."
    , effectNodePrerequisites = []
    , effectNodeEffect = Validate RequireAwsIamHarnessReady
    }

kubeconfigExists :: EffectNode
kubeconfigExists =
  EffectNode
    { effectNodeId = KubeconfigExists
    , effectNodeDescription = "Check kubeconfig file exists"
    , effectNodeRemedyHint =
        "Run `prodbox cluster reconcile` to bring up the local cluster (creates `/etc/rancher/rke2/rke2.yaml`)."
    , effectNodePrerequisites = []
    , effectNodeEffect = Validate (RequireFileExists "/etc/rancher/rke2/rke2.yaml")
    }

kubeconfigHomeExists :: EffectNode
kubeconfigHomeExists =
  EffectNode
    { effectNodeId = KubeconfigHomeExists
    , effectNodeDescription = "Check user kubeconfig exists"
    , effectNodeRemedyHint = "Copy or export a kubeconfig into `$HOME/.kube/config`."
    , effectNodePrerequisites = []
    , effectNodeEffect = Validate RequireHomeKubeconfig
    }

rke2ConfigExists :: EffectNode
rke2ConfigExists =
  EffectNode
    { effectNodeId = Rke2ConfigExists
    , effectNodeDescription = "Check RKE2 config file exists"
    , effectNodeRemedyHint =
        "Create `/etc/rancher/rke2/config.yaml` through the supported lifecycle path."
    , effectNodePrerequisites = [PlatformLinux]
    , effectNodeEffect = Validate (RequireFileExists "/etc/rancher/rke2/config.yaml")
    }

awsCredentialsValid :: EffectNode
awsCredentialsValid =
  EffectNode
    { effectNodeId = AwsCredentialsValid
    , effectNodeDescription = "Validate AWS credentials are configured"
    , effectNodeRemedyHint = "Run `prodbox aws setup` or refresh the repo-owned AWS credentials in Dhall."
    , effectNodePrerequisites = [SettingsObject, ToolAws]
    , effectNodeEffect = Validate RequireAwsCredentials
    }

route53Accessible :: EffectNode
route53Accessible =
  EffectNode
    { effectNodeId = Route53Accessible
    , effectNodeDescription = "Validate Route 53 is accessible"
    , effectNodeRemedyHint = "Verify the configured AWS credentials can read the target hosted zone."
    , effectNodePrerequisites = [AwsCredentialsValid]
    , effectNodeEffect = Validate RequireRoute53Access
    }

route53LifecycleCapable :: EffectNode
route53LifecycleCapable =
  EffectNode
    { effectNodeId = Route53LifecycleCapable
    , effectNodeDescription = "Validate Route 53 hosted-zone lifecycle capability"
    , effectNodeRemedyHint =
        "Grant the configured IAM principal the Route 53 record-write permissions required by the lifecycle surface."
    , effectNodePrerequisites = [Route53Accessible]
    , effectNodeEffect = Validate RequireRoute53LifecycleCapability
    }

rke2Installed :: EffectNode
rke2Installed =
  EffectNode
    { effectNodeId = Rke2Installed
    , effectNodeDescription = "Check RKE2 binary is installed"
    , effectNodeRemedyHint = "Install RKE2 on the supported host or rerun `prodbox cluster reconcile`."
    , effectNodePrerequisites = [HostSubstrateSupported]
    , effectNodeEffect = Validate (RequireFileExists "/usr/local/bin/rke2")
    }

rke2ServiceExists :: EffectNode
rke2ServiceExists =
  EffectNode
    { effectNodeId = Rke2ServiceExists
    , effectNodeDescription = "Check RKE2 service exists"
    , effectNodeRemedyHint =
        "Install the `rke2-server.service` unit through the supported lifecycle path."
    , effectNodePrerequisites = [Rke2Installed, SystemdAvailable, HostSubstrateSupported]
    , effectNodeEffect = Validate (RequireServiceExists "rke2-server.service")
    }

rke2ServiceActive :: EffectNode
rke2ServiceActive =
  EffectNode
    { effectNodeId = Rke2ServiceActive
    , effectNodeDescription = "Check RKE2 service is active"
    , effectNodeRemedyHint = "Start the RKE2 service and confirm it reaches the active state."
    , effectNodePrerequisites = [Rke2ServiceExists]
    , effectNodeEffect = Validate (RequireServiceActive "rke2-server.service")
    }

k8sClusterReachable :: EffectNode
k8sClusterReachable =
  EffectNode
    { effectNodeId = K8sClusterReachable
    , effectNodeDescription = "Confirm Kubernetes API access via kubectl cluster-info"
    , effectNodeRemedyHint =
        "Run `prodbox cluster reconcile` to bring up the local cluster, then confirm `kubectl cluster-info` succeeds."
    , effectNodePrerequisites = [ToolKubectl, KubeconfigExists, Rke2ServiceActive]
    , effectNodeEffect = Validate RequireKubectlClusterReachable
    }

pulumiLoggedIn :: EffectNode
pulumiLoggedIn =
  EffectNode
    { effectNodeId = PulumiLoggedIn
    , effectNodeDescription = "Validate Pulumi is logged in"
    , effectNodeRemedyHint = "Log Pulumi into the supported backend before rerunning."
    , effectNodePrerequisites = [ToolPulumi, K8sClusterReachable]
    , effectNodeEffect = Validate RequirePulumiLogin
    }

k8sReady :: EffectNode
k8sReady =
  EffectNode
    { effectNodeId = K8sReady
    , effectNodeDescription = "Validate Kubernetes cluster is fully ready"
    , effectNodeRemedyHint =
        "Run `prodbox cluster reconcile`, then wait for the cluster control plane and core workloads to become ready."
    , effectNodePrerequisites = [K8sClusterReachable, Rke2ServiceActive]
    , effectNodeEffect = Noop
    }

-- | Sprint 5.6: 'infra_ready' keeps the full infrastructure-readiness
-- bundle — cluster readiness AND validated AWS credentials — for the
-- AWS-credential-consuming validations that genuinely need both. The
-- AWS-credential-free public-edge readiness gate split out into
-- 'publicEdgeReady'.
infraReady :: EffectNode
infraReady =
  EffectNode
    { effectNodeId = InfraReady
    , effectNodeDescription = "Validate all infrastructure prerequisites"
    , effectNodeRemedyHint =
        "Resolve the upstream Kubernetes or AWS prerequisite failures first, then rerun the validation."
    , effectNodePrerequisites = [K8sReady, AwsCredentialsValid]
    , effectNodeEffect = Noop
    }

-- | Sprint 5.6: the public-edge readiness gate as a DECLARED prerequisite
-- node, promoted out of the procedural 'runWaitForPublicEdgeReady' poll
-- and split out of 'infra_ready'. It encodes "the cluster + chart
-- platform are up so the public edge can become ready-for-external-proof"
-- and depends ONLY on cluster + chart-platform readiness (@k8s_ready@),
-- **not** on AWS credentials. The @charts-vscode@ / @charts-api@ /
-- @charts-websocket@ / @admin-routes@ validations gate on this node so
-- they require an AWS-credential-free readiness rather than re-acquiring
-- the full 'infra_ready' capability set (which still pulls in
-- @aws_credentials_valid@). See
-- @DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md@ → Canonical Suite
-- Inventory.
publicEdgeReady :: EffectNode
publicEdgeReady =
  EffectNode
    { effectNodeId = PublicEdgeReady
    , effectNodeDescription = "Validate public-edge readiness (cluster + chart platform up)"
    , effectNodeRemedyHint =
        "Bring the cluster and chart platform up (`prodbox charts reconcile ...`) and wait for `prodbox edge status` to report ready-for-external-proof."
    , effectNodePrerequisites = [K8sReady]
    , effectNodeEffect = Noop
    }

gatewayDaemonAcquire :: EffectNode
gatewayDaemonAcquire =
  EffectNode
    { effectNodeId = GatewayDaemonAcquire
    , effectNodeDescription = "Validate gateway daemon acquire prerequisites"
    , effectNodeRemedyHint = "Run gateway daemon entrypoints on the supported Linux runtime."
    , effectNodePrerequisites = [PlatformLinux]
    , effectNodeEffect = Noop
    }

-- Sprint 8.4 — Cross-substrate SES prerequisites. These nodes are deferred-prereqs of
-- `ValidationKeycloakInvite` (Sprint 8.5): substrate provisioning runs first, then the
-- canonical suite gates the invite validation on the shared SES infrastructure
-- (`pulumi/aws-ses/`) being live and reachable from the runner.

sesSendingIdentityVerified :: EffectNode
sesSendingIdentityVerified =
  EffectNode
    { effectNodeId = SesSendingIdentityVerified
    , effectNodeDescription =
        "Validate the SES domain identity for ses.sender_domain is in VerificationStatus=Success"
    , effectNodeRemedyHint =
        "Provision the shared SES infrastructure via `prodbox aws stack aws-ses reconcile` (Sprint 8.1); confirm DKIM CNAME records exist in the parent Route 53 zone and that SES has reported VerificationStatus=Success for ses.sender_domain."
    , effectNodePrerequisites = [AwsCredentialsValid, Route53Accessible]
    , effectNodeEffect = Validate RequireSesSendingIdentityVerified
    }

sesReceiveRuleSetActive :: EffectNode
sesReceiveRuleSetActive =
  EffectNode
    { effectNodeId = SesReceiveRuleSetActive
    , effectNodeDescription =
        "Validate the SES receive rule set is active and captures mail for ses.receive_subdomain"
    , effectNodeRemedyHint =
        "Re-run `prodbox aws stack aws-ses reconcile` and confirm `aws ses describe-active-receipt-rule-set` reports the prodbox-receive-rule-set as active with an S3 action targeting ses.capture_bucket."
    , effectNodePrerequisites = [AwsCredentialsValid, Route53Accessible]
    , effectNodeEffect = Validate RequireSesReceiveRuleSetActive
    }

sesReceiveBucketAccessible :: EffectNode
sesReceiveBucketAccessible =
  EffectNode
    { effectNodeId = SesReceiveBucketAccessible
    , effectNodeDescription =
        "Validate the SES capture S3 bucket is reachable for list and get operations"
    , effectNodeRemedyHint =
        "Confirm the SMTP IAM user from `prodbox aws stack aws-ses reconcile` retains `s3:ListBucket` and `s3:GetObject` on ses.capture_bucket; `aws s3api head-bucket --bucket <bucket>` must exit 0 from the runner."
    , effectNodePrerequisites = [AwsCredentialsValid]
    , effectNodeEffect = Validate RequireSesReceiveBucketAccessible
    }

toolNode :: PrerequisiteId -> String -> FilePath -> [String] -> [PrerequisiteId] -> EffectNode
toolNode effectId description toolName versionArgs prerequisites =
  EffectNode
    { effectNodeId = effectId
    , effectNodeDescription = description
    , effectNodeRemedyHint = "Install `" ++ toolName ++ "` on the host and confirm it is on `PATH`."
    , effectNodePrerequisites = prerequisites
    , effectNodeEffect = Validate (RequireTool toolName versionArgs)
    }
