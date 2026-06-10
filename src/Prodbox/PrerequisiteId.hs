-- | Sprint 5.6: the typed identifier for every prerequisite node and the
-- few ad-hoc effect nodes the lifecycle surface builds outside the
-- registry. Replaces the raw-@String@ @effectNodeId@ keys that
-- 'Prodbox.Prerequisite', 'Prodbox.EffectDAG', and
-- 'Prodbox.EffectInterpreter' used to compare by string equality, so
-- prerequisite identifiers are exhaustively matched rather than
-- string-compared (CLAUDE.md "ADTs over strings"; the canonical-suite-side
-- counterpart to the typed sources of Sprints 1.30/1.31/4.26/4.27).
--
-- This module is deliberately dependency-light (no IO, no registry
-- imports) so it can sit below 'Prodbox.EffectDAG' and
-- 'Prodbox.Prerequisite' without an import cycle; the registry decorates
-- each 'PrerequisiteId' with its 'Prodbox.EffectDAG.EffectNode'.
module Prodbox.PrerequisiteId
  ( PrerequisiteId (..)
  , prerequisiteIdText
  , prerequisiteIdEngagesIamHarness
  )
where

-- | Every typed prerequisite / effect-node identifier. The registry
-- ('Prodbox.Prerequisite.prerequisiteRegistry') keys exactly the
-- declared-prerequisite constructors; the ad-hoc lifecycle nodes
-- ('K8sWaitNode') are built inline by their command runners and inserted
-- into a per-command registry view, never as registry members.
data PrerequisiteId
  = -- Platform / host
    PlatformLinux
  | SystemdAvailable
  | SupportedUbuntu2404
  | MachineIdentity
  | SettingsObject
  | -- Tools
    ToolCurl
  | ToolDig
  | ToolKubectl
  | ToolDocker
  | ToolCtr
  | ToolHelm
  | ToolSudo
  | ToolPulumi
  | ToolAws
  | ToolSsh
  | ToolRke2
  | ToolSystemctl
  | -- AWS access
    AwsIamHarnessReady
  | AwsCredentialsValid
  | Route53Accessible
  | Route53LifecycleCapable
  | -- SES (cross-substrate shared infrastructure)
    SesSendingIdentityVerified
  | SesReceiveRuleSetActive
  | SesReceiveBucketAccessible
  | -- Filesystem / RKE2 / cluster
    KubeconfigExists
  | KubeconfigHomeExists
  | Rke2ConfigExists
  | Rke2Installed
  | Rke2ServiceExists
  | Rke2ServiceActive
  | K8sClusterReachable
  | PulumiLoggedIn
  | K8sReady
  | InfraReady
  | PublicEdgeReady
  | GatewayDaemonAcquire
  | -- Ad-hoc lifecycle nodes (built inline, not registry members)
    K8sWaitNode
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The stable wire/display string for a 'PrerequisiteId'. Used for
-- operator-facing rendering, the @effectNodeId@ surfaced in interpreter
-- failure messages, and the few doc/test assertions that pin the
-- prerequisite surface. The mapping is the SSoT for the historical
-- snake_case identifiers (e.g. @aws_credentials_valid@) so renaming a
-- constructor cannot silently change the surfaced id.
prerequisiteIdText :: PrerequisiteId -> String
prerequisiteIdText prerequisiteId =
  case prerequisiteId of
    PlatformLinux -> "platform_linux"
    SystemdAvailable -> "systemd_available"
    SupportedUbuntu2404 -> "supported_ubuntu_2404"
    MachineIdentity -> "machine_identity"
    SettingsObject -> "settings_object"
    ToolCurl -> "tool_curl"
    ToolDig -> "tool_dig"
    ToolKubectl -> "tool_kubectl"
    ToolDocker -> "tool_docker"
    ToolCtr -> "tool_ctr"
    ToolHelm -> "tool_helm"
    ToolSudo -> "tool_sudo"
    ToolPulumi -> "tool_pulumi"
    ToolAws -> "tool_aws"
    ToolSsh -> "tool_ssh"
    ToolRke2 -> "tool_rke2"
    ToolSystemctl -> "tool_systemctl"
    AwsIamHarnessReady -> "aws_iam_harness_ready"
    AwsCredentialsValid -> "aws_credentials_valid"
    Route53Accessible -> "route53_accessible"
    Route53LifecycleCapable -> "route53_lifecycle_capable"
    SesSendingIdentityVerified -> "ses_sending_identity_verified"
    SesReceiveRuleSetActive -> "ses_receive_rule_set_active"
    SesReceiveBucketAccessible -> "ses_receive_bucket_accessible"
    KubeconfigExists -> "kubeconfig_exists"
    KubeconfigHomeExists -> "kubeconfig_home_exists"
    Rke2ConfigExists -> "rke2_config_exists"
    Rke2Installed -> "rke2_installed"
    Rke2ServiceExists -> "rke2_service_exists"
    Rke2ServiceActive -> "rke2_service_active"
    K8sClusterReachable -> "k8s_cluster_reachable"
    PulumiLoggedIn -> "pulumi_logged_in"
    K8sReady -> "k8s_ready"
    InfraReady -> "infra_ready"
    PublicEdgeReady -> "public_edge_ready"
    GatewayDaemonAcquire -> "gateway_daemon_acquire"
    K8sWaitNode -> "k8s_wait"

-- | Sprint 5.6 capability-tier derivation: 'True' when a validation that
-- declares this prerequisite engages the managed AWS IAM harness. The
-- harness materializes operational @aws.*@ credentials from
-- @aws_admin_for_test_simulation.*@, so a validation engages it exactly
-- when one of its declared prerequisites needs live AWS credentials
-- (direct credential checks, Route 53, SES, or the IAM-harness check
-- itself). A credential-free prerequisite (tools, cluster readiness, the
-- public-edge readiness gate) returns 'False'. This replaces the deleted
-- @normalizeManagedAwsHarness@ @substrate=aws@ blanket override: the tier
-- now follows declared capabilities, not the active substrate, so a
-- credential-free validation (e.g. @gateway-partition@) never acquires the
-- IAM harness merely because the substrate is AWS.
prerequisiteIdEngagesIamHarness :: PrerequisiteId -> Bool
prerequisiteIdEngagesIamHarness prerequisiteId =
  case prerequisiteId of
    AwsIamHarnessReady -> True
    AwsCredentialsValid -> True
    Route53Accessible -> True
    Route53LifecycleCapable -> True
    SesSendingIdentityVerified -> True
    SesReceiveRuleSetActive -> True
    SesReceiveBucketAccessible -> True
    -- Credential-free prerequisites: platform, tools, filesystem, RKE2,
    -- cluster + chart-platform readiness, the public-edge readiness gate,
    -- Pulumi login (login is a backend session, not an AWS-credential
    -- materialization), and the ad-hoc lifecycle nodes.
    PlatformLinux -> False
    SystemdAvailable -> False
    SupportedUbuntu2404 -> False
    MachineIdentity -> False
    SettingsObject -> False
    ToolCurl -> False
    ToolDig -> False
    ToolKubectl -> False
    ToolDocker -> False
    ToolCtr -> False
    ToolHelm -> False
    ToolSudo -> False
    ToolPulumi -> False
    ToolAws -> False
    ToolSsh -> False
    ToolRke2 -> False
    ToolSystemctl -> False
    KubeconfigExists -> False
    KubeconfigHomeExists -> False
    Rke2ConfigExists -> False
    Rke2Installed -> False
    Rke2ServiceExists -> False
    Rke2ServiceActive -> False
    K8sClusterReachable -> False
    PulumiLoggedIn -> False
    K8sReady -> False
    InfraReady -> False
    PublicEdgeReady -> False
    GatewayDaemonAcquire -> False
    K8sWaitNode -> False
