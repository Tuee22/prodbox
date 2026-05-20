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

prerequisiteRegistry :: Map String EffectNode
prerequisiteRegistry =
  Map.fromList (map keyed allPrerequisites)
 where
  keyed node = (effectNodeId node, node)

allPrerequisites :: [EffectNode]
allPrerequisites =
  [ platformLinux
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
  , settingsLoaded
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
  , gatewayDaemonAcquire
  , sesSendingIdentityVerified
  , sesReceiveRuleSetActive
  , sesReceiveBucketAccessible
  ]

platformLinux :: EffectNode
platformLinux =
  EffectNode
    { effectNodeId = "platform_linux"
    , effectNodeDescription = "Require Linux operating system"
    , effectNodeRemedyHint = "Run the supported command surface on a Linux host."
    , effectNodePrerequisites = []
    , effectNodeEffect = Validate RequireLinux
    }

systemdAvailable :: EffectNode
systemdAvailable =
  EffectNode
    { effectNodeId = "systemd_available"
    , effectNodeDescription = "Require systemd availability"
    , effectNodeRemedyHint = "Use a systemd-managed host or container with `/run/systemd/system` present."
    , effectNodePrerequisites = ["platform_linux"]
    , effectNodeEffect = Validate RequireSystemd
    }

supportedUbuntu2404 :: EffectNode
supportedUbuntu2404 =
  EffectNode
    { effectNodeId = "supported_ubuntu_2404"
    , effectNodeDescription = "Require Ubuntu 24.04 LTS"
    , effectNodeRemedyHint = "Run the supported workflow on Ubuntu 24.04 LTS."
    , effectNodePrerequisites = ["platform_linux"]
    , effectNodeEffect = Validate RequireUbuntu2404
    }

machineIdentity :: EffectNode
machineIdentity =
  EffectNode
    { effectNodeId = "machine_identity"
    , effectNodeDescription = "Resolve machine-id and derived prodbox-id"
    , effectNodeRemedyHint = "Ensure `/etc/machine-id` exists and contains the host identity."
    , effectNodePrerequisites = ["platform_linux"]
    , effectNodeEffect = Validate RequireMachineIdentity
    }

toolKubectl :: EffectNode
toolKubectl = toolNode "tool_kubectl" "Validate kubectl is installed" "kubectl" ["version", "--client=true"] []

toolCurl :: EffectNode
toolCurl = toolNode "tool_curl" "Validate curl is installed" "curl" ["--version"] []

toolDig :: EffectNode
toolDig = toolNode "tool_dig" "Validate dig is installed" "dig" ["-v"] []

toolDocker :: EffectNode
toolDocker = toolNode "tool_docker" "Validate docker is installed" "docker" ["--version"] []

toolCtr :: EffectNode
toolCtr = toolNode "tool_ctr" "Validate ctr is installed" "ctr" ["--help"] []

toolHelm :: EffectNode
toolHelm = toolNode "tool_helm" "Validate helm is installed" "helm" ["version", "--short"] []

toolSudo :: EffectNode
toolSudo = toolNode "tool_sudo" "Validate sudo is installed" "sudo" ["--version"] []

toolPulumi :: EffectNode
toolPulumi = toolNode "tool_pulumi" "Validate pulumi is installed" "pulumi" ["version"] []

toolAws :: EffectNode
toolAws = toolNode "tool_aws" "Validate aws CLI is installed" "aws" ["--version"] []

toolSsh :: EffectNode
toolSsh = toolNode "tool_ssh" "Validate OpenSSH client is installed" "ssh" ["-V"] []

toolRke2 :: EffectNode
toolRke2 =
  toolNode
    "tool_rke2"
    "Validate rke2 is installed"
    "/usr/local/bin/rke2"
    ["--version"]
    ["platform_linux"]

toolSystemctl :: EffectNode
toolSystemctl =
  toolNode
    "tool_systemctl"
    "Validate systemctl is available"
    "systemctl"
    ["--version"]
    ["systemd_available"]

settingsLoaded :: EffectNode
settingsLoaded =
  EffectNode
    { effectNodeId = "settings_loaded"
    , effectNodeDescription = "Validate prodbox settings are loaded"
    , effectNodeRemedyHint = "Run `prodbox config setup` or repair `prodbox-config.dhall`."
    , effectNodePrerequisites = []
    , effectNodeEffect = Validate RequireSettings
    }

settingsObject :: EffectNode
settingsObject =
  EffectNode
    { effectNodeId = "settings_object"
    , effectNodeDescription = "Load validated prodbox settings"
    , effectNodeRemedyHint = "Run `prodbox config validate` until the repository config loads cleanly."
    , effectNodePrerequisites = []
    , effectNodeEffect = Validate RequireSettings
    }

awsIamHarnessReady :: EffectNode
awsIamHarnessReady =
  EffectNode
    { effectNodeId = "aws_iam_harness_ready"
    , effectNodeDescription = "Validate native IAM harness config and test-simulation admin credentials"
    , effectNodeRemedyHint =
        "Configure the AWS IAM harness inputs in `prodbox-config.dhall` before rerunning."
    , effectNodePrerequisites = []
    , effectNodeEffect = Validate RequireAwsIamHarnessReady
    }

kubeconfigExists :: EffectNode
kubeconfigExists =
  EffectNode
    { effectNodeId = "kubeconfig_exists"
    , effectNodeDescription = "Check kubeconfig file exists"
    , effectNodeRemedyHint = "Create `/etc/rancher/rke2/rke2.yaml` by reconciling the local RKE2 runtime."
    , effectNodePrerequisites = []
    , effectNodeEffect = Validate (RequireFileExists "/etc/rancher/rke2/rke2.yaml")
    }

kubeconfigHomeExists :: EffectNode
kubeconfigHomeExists =
  EffectNode
    { effectNodeId = "kubeconfig_home_exists"
    , effectNodeDescription = "Check user kubeconfig exists"
    , effectNodeRemedyHint = "Copy or export a kubeconfig into `$HOME/.kube/config`."
    , effectNodePrerequisites = []
    , effectNodeEffect = Validate RequireHomeKubeconfig
    }

rke2ConfigExists :: EffectNode
rke2ConfigExists =
  EffectNode
    { effectNodeId = "rke2_config_exists"
    , effectNodeDescription = "Check RKE2 config file exists"
    , effectNodeRemedyHint =
        "Create `/etc/rancher/rke2/config.yaml` through the supported lifecycle path."
    , effectNodePrerequisites = ["platform_linux"]
    , effectNodeEffect = Validate (RequireFileExists "/etc/rancher/rke2/config.yaml")
    }

awsCredentialsValid :: EffectNode
awsCredentialsValid =
  EffectNode
    { effectNodeId = "aws_credentials_valid"
    , effectNodeDescription = "Validate AWS credentials are configured"
    , effectNodeRemedyHint = "Run `prodbox aws setup` or refresh the repo-owned AWS credentials in Dhall."
    , effectNodePrerequisites = ["settings_loaded", "tool_aws"]
    , effectNodeEffect = Validate RequireAwsCredentials
    }

route53Accessible :: EffectNode
route53Accessible =
  EffectNode
    { effectNodeId = "route53_accessible"
    , effectNodeDescription = "Validate Route 53 is accessible"
    , effectNodeRemedyHint = "Verify the configured AWS credentials can read the target hosted zone."
    , effectNodePrerequisites = ["aws_credentials_valid"]
    , effectNodeEffect = Validate RequireRoute53Access
    }

route53LifecycleCapable :: EffectNode
route53LifecycleCapable =
  EffectNode
    { effectNodeId = "route53_lifecycle_capable"
    , effectNodeDescription = "Validate Route 53 hosted-zone lifecycle capability"
    , effectNodeRemedyHint =
        "Grant the configured IAM principal the Route 53 record-write permissions required by the lifecycle surface."
    , effectNodePrerequisites = ["route53_accessible"]
    , effectNodeEffect = Validate RequireRoute53LifecycleCapability
    }

rke2Installed :: EffectNode
rke2Installed =
  EffectNode
    { effectNodeId = "rke2_installed"
    , effectNodeDescription = "Check RKE2 binary is installed"
    , effectNodeRemedyHint = "Install RKE2 on the supported host or rerun `prodbox rke2 reconcile`."
    , effectNodePrerequisites = ["supported_ubuntu_2404"]
    , effectNodeEffect = Validate (RequireFileExists "/usr/local/bin/rke2")
    }

rke2ServiceExists :: EffectNode
rke2ServiceExists =
  EffectNode
    { effectNodeId = "rke2_service_exists"
    , effectNodeDescription = "Check RKE2 service exists"
    , effectNodeRemedyHint =
        "Install the `rke2-server.service` unit through the supported lifecycle path."
    , effectNodePrerequisites = ["rke2_installed", "systemd_available", "supported_ubuntu_2404"]
    , effectNodeEffect = Validate (RequireServiceExists "rke2-server.service")
    }

rke2ServiceActive :: EffectNode
rke2ServiceActive =
  EffectNode
    { effectNodeId = "rke2_service_active"
    , effectNodeDescription = "Check RKE2 service is active"
    , effectNodeRemedyHint = "Start the RKE2 service and confirm it reaches the active state."
    , effectNodePrerequisites = ["rke2_service_exists"]
    , effectNodeEffect = Validate (RequireServiceActive "rke2-server.service")
    }

k8sClusterReachable :: EffectNode
k8sClusterReachable =
  EffectNode
    { effectNodeId = "k8s_cluster_reachable"
    , effectNodeDescription = "Confirm Kubernetes API access via kubectl cluster-info"
    , effectNodeRemedyHint = "Export a working kubeconfig and confirm `kubectl cluster-info` succeeds."
    , effectNodePrerequisites = ["tool_kubectl", "kubeconfig_exists", "rke2_service_active"]
    , effectNodeEffect = Validate RequireKubectlClusterReachable
    }

pulumiLoggedIn :: EffectNode
pulumiLoggedIn =
  EffectNode
    { effectNodeId = "pulumi_logged_in"
    , effectNodeDescription = "Validate Pulumi is logged in"
    , effectNodeRemedyHint = "Log Pulumi into the supported backend before rerunning."
    , effectNodePrerequisites = ["tool_pulumi", "k8s_cluster_reachable"]
    , effectNodeEffect = Validate RequirePulumiLogin
    }

k8sReady :: EffectNode
k8sReady =
  EffectNode
    { effectNodeId = "k8s_ready"
    , effectNodeDescription = "Validate Kubernetes cluster is fully ready"
    , effectNodeRemedyHint = "Wait for the cluster control plane and core workloads to become ready."
    , effectNodePrerequisites = ["k8s_cluster_reachable", "rke2_service_active"]
    , effectNodeEffect = Noop
    }

infraReady :: EffectNode
infraReady =
  EffectNode
    { effectNodeId = "infra_ready"
    , effectNodeDescription = "Validate all infrastructure prerequisites"
    , effectNodeRemedyHint =
        "Resolve the upstream Kubernetes or AWS prerequisite failures first, then rerun the validation."
    , effectNodePrerequisites = ["k8s_ready", "aws_credentials_valid"]
    , effectNodeEffect = Noop
    }

gatewayDaemonAcquire :: EffectNode
gatewayDaemonAcquire =
  EffectNode
    { effectNodeId = "gateway_daemon_acquire"
    , effectNodeDescription = "Validate gateway daemon acquire prerequisites"
    , effectNodeRemedyHint = "Run gateway daemon entrypoints on the supported Linux runtime."
    , effectNodePrerequisites = ["platform_linux"]
    , effectNodeEffect = Noop
    }

-- Sprint 8.4 — Cross-substrate SES prerequisites. These nodes are deferred-prereqs of
-- `ValidationKeycloakInvite` (Sprint 8.5): substrate provisioning runs first, then the
-- canonical suite gates the invite validation on the shared SES infrastructure
-- (`pulumi/aws-ses/`) being live and reachable from the runner.

sesSendingIdentityVerified :: EffectNode
sesSendingIdentityVerified =
  EffectNode
    { effectNodeId = "ses_sending_identity_verified"
    , effectNodeDescription =
        "Validate the SES domain identity for ses.sender_domain is in VerificationStatus=Success"
    , effectNodeRemedyHint =
        "Provision the shared SES infrastructure via `prodbox pulumi aws-ses-resources` (Sprint 8.1); confirm DKIM CNAME records exist in the parent Route 53 zone and that SES has reported VerificationStatus=Success for ses.sender_domain."
    , effectNodePrerequisites = ["aws_credentials_valid", "route53_accessible"]
    , effectNodeEffect = Validate RequireSesSendingIdentityVerified
    }

sesReceiveRuleSetActive :: EffectNode
sesReceiveRuleSetActive =
  EffectNode
    { effectNodeId = "ses_receive_rule_set_active"
    , effectNodeDescription =
        "Validate the SES receive rule set is active and captures mail for ses.receive_subdomain"
    , effectNodeRemedyHint =
        "Re-run `prodbox pulumi aws-ses-resources` and confirm `aws ses describe-active-receipt-rule-set` reports the prodbox-receive-rule-set as active with an S3 action targeting ses.capture_bucket."
    , effectNodePrerequisites = ["aws_credentials_valid", "route53_accessible"]
    , effectNodeEffect = Validate RequireSesReceiveRuleSetActive
    }

sesReceiveBucketAccessible :: EffectNode
sesReceiveBucketAccessible =
  EffectNode
    { effectNodeId = "ses_receive_bucket_accessible"
    , effectNodeDescription =
        "Validate the SES capture S3 bucket is reachable for list and get operations"
    , effectNodeRemedyHint =
        "Confirm the SMTP IAM user from `prodbox pulumi aws-ses-resources` retains `s3:ListBucket` and `s3:GetObject` on ses.capture_bucket; `aws s3api head-bucket --bucket <bucket>` must exit 0 from the runner."
    , effectNodePrerequisites = ["aws_credentials_valid"]
    , effectNodeEffect = Validate RequireSesReceiveBucketAccessible
    }

toolNode :: String -> String -> FilePath -> [String] -> [String] -> EffectNode
toolNode effectId description toolName versionArgs prerequisites =
  EffectNode
    { effectNodeId = effectId
    , effectNodeDescription = description
    , effectNodeRemedyHint = "Install `" ++ toolName ++ "` on the host and confirm it is on `PATH`."
    , effectNodePrerequisites = prerequisites
    , effectNodeEffect = Validate (RequireTool toolName versionArgs)
    }
