module Prodbox.Prerequisite
    ( prerequisiteRegistry,
    )
where

import qualified Data.Map.Strict as Map
import Data.Map.Strict
    ( Map,
    )
import Prodbox.Effect
    ( Effect (..),
      Validation (..),
    )
import Prodbox.EffectDAG
    ( EffectNode (..),
    )

prerequisiteRegistry :: Map String EffectNode
prerequisiteRegistry =
    Map.fromList (map keyed allPrerequisites)
  where
    keyed node = (effectNodeId node, node)

allPrerequisites :: [EffectNode]
allPrerequisites =
    [ platformLinux,
      systemdAvailable,
      supportedUbuntu2404,
      machineIdentity,
      toolCurl,
      toolDig,
      toolKubectl,
      toolDocker,
      toolCtr,
      toolHelm,
      toolSudo,
      toolPulumi,
      toolAws,
      toolSsh,
      toolRke2,
      toolSystemctl,
      toolDhall,
      settingsLoaded,
      settingsObject,
      kubeconfigExists,
      kubeconfigHomeExists,
      rke2ConfigExists,
      awsCredentialsValid,
      route53Accessible,
      rke2Installed,
      rke2ServiceExists,
      rke2ServiceActive,
      k8sClusterReachable,
      pulumiLoggedIn,
      k8sReady,
      infraReady
    ]

platformLinux :: EffectNode
platformLinux =
    EffectNode
        { effectNodeId = "platform_linux",
          effectNodeDescription = "Require Linux operating system",
          effectNodePrerequisites = [],
          effectNodeEffect = Validate RequireLinux
        }

systemdAvailable :: EffectNode
systemdAvailable =
    EffectNode
        { effectNodeId = "systemd_available",
          effectNodeDescription = "Require systemd availability",
          effectNodePrerequisites = ["platform_linux"],
          effectNodeEffect = Validate RequireSystemd
        }

supportedUbuntu2404 :: EffectNode
supportedUbuntu2404 =
    EffectNode
        { effectNodeId = "supported_ubuntu_2404",
          effectNodeDescription = "Require Ubuntu 24.04 LTS",
          effectNodePrerequisites = ["platform_linux"],
          effectNodeEffect = Validate RequireUbuntu2404
        }

machineIdentity :: EffectNode
machineIdentity =
    EffectNode
        { effectNodeId = "machine_identity",
          effectNodeDescription = "Resolve machine-id and derived prodbox-id",
          effectNodePrerequisites = ["platform_linux"],
          effectNodeEffect = Validate RequireMachineIdentity
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
toolRke2 = toolNode "tool_rke2" "Validate rke2 is installed" "/usr/local/bin/rke2" ["--version"] ["platform_linux"]

toolSystemctl :: EffectNode
toolSystemctl = toolNode "tool_systemctl" "Validate systemctl is available" "systemctl" ["--version"] ["systemd_available"]

toolDhall :: EffectNode
toolDhall = toolNode "tool_dhall" "Validate dhall is installed" "dhall" ["version"] []

settingsLoaded :: EffectNode
settingsLoaded =
    EffectNode
        { effectNodeId = "settings_loaded",
          effectNodeDescription = "Validate prodbox settings are loaded",
          effectNodePrerequisites = [],
          effectNodeEffect = Validate RequireSettings
        }

settingsObject :: EffectNode
settingsObject =
    EffectNode
        { effectNodeId = "settings_object",
          effectNodeDescription = "Load validated prodbox settings",
          effectNodePrerequisites = [],
          effectNodeEffect = Validate RequireSettings
        }

kubeconfigExists :: EffectNode
kubeconfigExists =
    EffectNode
        { effectNodeId = "kubeconfig_exists",
          effectNodeDescription = "Check kubeconfig file exists",
          effectNodePrerequisites = [],
          effectNodeEffect = Validate (RequireFileExists "/etc/rancher/rke2/rke2.yaml")
        }

kubeconfigHomeExists :: EffectNode
kubeconfigHomeExists =
    EffectNode
        { effectNodeId = "kubeconfig_home_exists",
          effectNodeDescription = "Check user kubeconfig exists",
          effectNodePrerequisites = [],
          effectNodeEffect = Validate RequireHomeKubeconfig
        }

rke2ConfigExists :: EffectNode
rke2ConfigExists =
    EffectNode
        { effectNodeId = "rke2_config_exists",
          effectNodeDescription = "Check RKE2 config file exists",
          effectNodePrerequisites = ["platform_linux"],
          effectNodeEffect = Validate (RequireFileExists "/etc/rancher/rke2/config.yaml")
        }

awsCredentialsValid :: EffectNode
awsCredentialsValid =
    EffectNode
        { effectNodeId = "aws_credentials_valid",
          effectNodeDescription = "Validate AWS credentials are configured",
          effectNodePrerequisites = ["settings_loaded"],
          effectNodeEffect = Validate RequireAwsCredentials
        }

route53Accessible :: EffectNode
route53Accessible =
    EffectNode
        { effectNodeId = "route53_accessible",
          effectNodeDescription = "Validate Route 53 is accessible",
          effectNodePrerequisites = ["aws_credentials_valid"],
          effectNodeEffect = Validate RequireRoute53Access
        }

rke2Installed :: EffectNode
rke2Installed =
    EffectNode
        { effectNodeId = "rke2_installed",
          effectNodeDescription = "Check RKE2 binary is installed",
          effectNodePrerequisites = ["supported_ubuntu_2404"],
          effectNodeEffect = Validate (RequireFileExists "/usr/local/bin/rke2")
        }

rke2ServiceExists :: EffectNode
rke2ServiceExists =
    EffectNode
        { effectNodeId = "rke2_service_exists",
          effectNodeDescription = "Check RKE2 service exists",
          effectNodePrerequisites = ["rke2_installed", "systemd_available", "supported_ubuntu_2404"],
          effectNodeEffect = Validate (RequireServiceExists "rke2-server.service")
        }

rke2ServiceActive :: EffectNode
rke2ServiceActive =
    EffectNode
        { effectNodeId = "rke2_service_active",
          effectNodeDescription = "Check RKE2 service is active",
          effectNodePrerequisites = ["rke2_service_exists"],
          effectNodeEffect = Validate (RequireServiceActive "rke2-server.service")
        }

k8sClusterReachable :: EffectNode
k8sClusterReachable =
    EffectNode
        { effectNodeId = "k8s_cluster_reachable",
          effectNodeDescription = "Confirm Kubernetes API access via kubectl cluster-info",
          effectNodePrerequisites = ["tool_kubectl", "kubeconfig_exists", "rke2_service_active"],
          effectNodeEffect = Validate RequireKubectlClusterReachable
        }

pulumiLoggedIn :: EffectNode
pulumiLoggedIn =
    EffectNode
        { effectNodeId = "pulumi_logged_in",
          effectNodeDescription = "Validate Pulumi is logged in",
          effectNodePrerequisites = ["tool_pulumi"],
          effectNodeEffect = Validate RequirePulumiLogin
        }

k8sReady :: EffectNode
k8sReady =
    EffectNode
        { effectNodeId = "k8s_ready",
          effectNodeDescription = "Validate Kubernetes cluster is fully ready",
          effectNodePrerequisites = ["k8s_cluster_reachable", "rke2_service_active"],
          effectNodeEffect = Noop
        }

infraReady :: EffectNode
infraReady =
    EffectNode
        { effectNodeId = "infra_ready",
          effectNodeDescription = "Validate all infrastructure prerequisites",
          effectNodePrerequisites = ["k8s_ready", "aws_credentials_valid"],
          effectNodeEffect = Noop
        }

toolNode :: String -> String -> FilePath -> [String] -> [String] -> EffectNode
toolNode effectId description toolName versionArgs prerequisites =
    EffectNode
        { effectNodeId = effectId,
          effectNodeDescription = description,
          effectNodePrerequisites = prerequisites,
          effectNodeEffect = Validate (RequireTool toolName versionArgs)
        }
