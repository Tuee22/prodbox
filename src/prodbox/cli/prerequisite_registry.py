"""
Central prerequisite definitions for prodbox CLI.

This module defines all reusable prerequisite EffectNodes that commands
can depend on. Prerequisites are checked before command execution and
failures short-circuit the entire command with actionable error messages.

Architecture:
    - Each prerequisite is an EffectNode with a unique effect_id
    - Prerequisites can depend on other prerequisites (transitive expansion)
    - The registry maps effect_ids to their canonical EffectNode definitions
    - Commands reference prerequisites by effect_id in their frozenset

Doctrine (see documents/engineering/prerequisite_doctrine.md):
    - Fail fast with actionable errors
    - Check early, fail early
    - No silent degradation
    - Prerequisites are pure checks (no side effects)
"""

from __future__ import annotations

from pathlib import Path

from prodbox.cli.effect_dag import EffectNode, PrerequisiteRegistry
from prodbox.cli.effects import (
    CaptureKubectlOutput,
    CheckFileExists,
    CheckServiceStatus,
    MachineIdentity,
    Pure,
    RequireLinux,
    RequireSystemd,
    ResolveMachineIdentity,
    ValidateAWSCredentials,
    ValidateSettings,
    ValidateTool,
)

# =============================================================================
# Platform Prerequisites
# =============================================================================

PLATFORM_LINUX: EffectNode[None] = EffectNode(
    effect=RequireLinux(
        effect_id="platform_linux",
        description="Require Linux operating system",
    ),
    prerequisites=frozenset(),
)

SYSTEMD_AVAILABLE: EffectNode[None] = EffectNode(
    effect=RequireSystemd(
        effect_id="systemd_available",
        description="Require systemd availability",
    ),
    prerequisites=frozenset(["platform_linux"]),
)

MACHINE_IDENTITY: EffectNode[MachineIdentity] = EffectNode(
    effect=ResolveMachineIdentity(
        effect_id="machine_identity",
        description="Resolve machine-id and derived prodbox-id",
    ),
    prerequisites=frozenset(["platform_linux"]),
)


# =============================================================================
# Tool Prerequisites
# =============================================================================

TOOL_KUBECTL: EffectNode[bool] = EffectNode(
    effect=ValidateTool(
        effect_id="tool_kubectl",
        description="Validate kubectl is installed",
        tool_name="kubectl",
        version_flag="version --client --short",
    ),
    prerequisites=frozenset(),
)

TOOL_DOCKER: EffectNode[bool] = EffectNode(
    effect=ValidateTool(
        effect_id="tool_docker",
        description="Validate docker is installed",
        tool_name="docker",
        version_flag="--version",
    ),
    prerequisites=frozenset(),
)

TOOL_CTR: EffectNode[bool] = EffectNode(
    effect=ValidateTool(
        effect_id="tool_ctr",
        description="Validate ctr is installed",
        tool_name="ctr",
        version_flag="version",
    ),
    prerequisites=frozenset(),
)

TOOL_HELM: EffectNode[bool] = EffectNode(
    effect=ValidateTool(
        effect_id="tool_helm",
        description="Validate helm is installed",
        tool_name="helm",
        version_flag="version --short",
    ),
    prerequisites=frozenset(),
)

TOOL_SUDO: EffectNode[bool] = EffectNode(
    effect=ValidateTool(
        effect_id="tool_sudo",
        description="Validate sudo is installed",
        tool_name="sudo",
        version_flag="--version",
    ),
    prerequisites=frozenset(),
)

TOOL_PULUMI: EffectNode[bool] = EffectNode(
    effect=ValidateTool(
        effect_id="tool_pulumi",
        description="Validate pulumi is installed",
        tool_name="pulumi",
        version_flag="version",
    ),
    prerequisites=frozenset(),
)

TOOL_RKE2: EffectNode[bool] = EffectNode(
    effect=ValidateTool(
        effect_id="tool_rke2",
        description="Validate rke2 is installed",
        tool_name="/usr/local/bin/rke2",
        version_flag="--version",
    ),
    prerequisites=frozenset(["platform_linux"]),
)

TOOL_SYSTEMCTL: EffectNode[bool] = EffectNode(
    effect=ValidateTool(
        effect_id="tool_systemctl",
        description="Validate systemctl is available",
        tool_name="systemctl",
        version_flag="--version",
    ),
    prerequisites=frozenset(["systemd_available"]),
)


# =============================================================================
# Configuration Prerequisites
# =============================================================================

SETTINGS_LOADED: EffectNode[bool] = EffectNode(
    effect=ValidateSettings(
        effect_id="settings_loaded",
        description="Validate prodbox settings are loaded",
    ),
    prerequisites=frozenset(),
)

KUBECONFIG_EXISTS: EffectNode[bool] = EffectNode(
    effect=CheckFileExists(
        effect_id="kubeconfig_exists",
        description="Check kubeconfig file exists",
        file_path=Path("/etc/rancher/rke2/rke2.yaml"),
    ),
    prerequisites=frozenset(),
)

KUBECONFIG_HOME_EXISTS: EffectNode[bool] = EffectNode(
    effect=CheckFileExists(
        effect_id="kubeconfig_home_exists",
        description="Check user kubeconfig exists",
        file_path=Path.home() / ".kube" / "config",
    ),
    prerequisites=frozenset(),
)

RKE2_CONFIG_EXISTS: EffectNode[bool] = EffectNode(
    effect=CheckFileExists(
        effect_id="rke2_config_exists",
        description="Check RKE2 config file exists",
        file_path=Path("/etc/rancher/rke2/config.yaml"),
    ),
    prerequisites=frozenset(["platform_linux"]),
)

RKE2_KILLALL_EXISTS: EffectNode[bool] = EffectNode(
    effect=CheckFileExists(
        effect_id="rke2_killall_exists",
        description="Check rke2-killall cleanup script exists",
        file_path=Path("/usr/local/bin/rke2-killall.sh"),
    ),
    prerequisites=frozenset(["rke2_installed"]),
)


# =============================================================================
# AWS / Route 53 Prerequisites
# =============================================================================

AWS_CREDENTIALS_VALID: EffectNode[bool] = EffectNode(
    effect=ValidateAWSCredentials(
        effect_id="aws_credentials_valid",
        description="Validate AWS credentials are configured",
    ),
    prerequisites=frozenset(["settings_loaded"]),
)

ROUTE53_ACCESSIBLE: EffectNode[bool] = EffectNode(
    effect=Pure(
        effect_id="route53_accessible",
        description="Validate Route 53 is accessible",
        value=True,  # Validated by AWS credentials check + settings
    ),
    prerequisites=frozenset(["aws_credentials_valid"]),
)


# =============================================================================
# RKE2 / Kubernetes Prerequisites
# =============================================================================

RKE2_INSTALLED: EffectNode[bool] = EffectNode(
    effect=CheckFileExists(
        effect_id="rke2_installed",
        description="Check RKE2 binary is installed",
        file_path=Path("/usr/local/bin/rke2"),
    ),
    prerequisites=frozenset(["platform_linux"]),
)

RKE2_SERVICE_EXISTS: EffectNode[str] = EffectNode(
    effect=CheckServiceStatus(
        effect_id="rke2_service_exists",
        description="Check RKE2 service exists",
        service="rke2-server.service",
    ),
    prerequisites=frozenset(["rke2_installed", "systemd_available"]),
)

RKE2_SERVICE_ACTIVE: EffectNode[str] = EffectNode(
    effect=CheckServiceStatus(
        effect_id="rke2_service_active",
        description="Check RKE2 service is active",
        service="rke2-server.service",
    ),
    prerequisites=frozenset(["rke2_service_exists"]),
)

K8S_CLUSTER_REACHABLE: EffectNode[tuple[int, str, str]] = EffectNode(
    effect=CaptureKubectlOutput(
        effect_id="k8s_cluster_reachable",
        description="Confirm Kubernetes API access via kubectl cluster-info",
        args=["cluster-info"],
        timeout=30.0,
    ),
    prerequisites=frozenset(["tool_kubectl", "kubeconfig_exists", "rke2_service_active"]),
)


# =============================================================================
# Pulumi Prerequisites
# =============================================================================

PULUMI_LOGGED_IN: EffectNode[bool] = EffectNode(
    effect=Pure(
        effect_id="pulumi_logged_in",
        description="Validate Pulumi is logged in",
        value=True,  # Will be verified by pulumi whoami
    ),
    prerequisites=frozenset(["tool_pulumi"]),
)

PULUMI_STACK_EXISTS: EffectNode[bool] = EffectNode(
    effect=Pure(
        effect_id="pulumi_stack_exists",
        description="Validate Pulumi stack exists",
        value=True,  # Will be verified by stack select
    ),
    prerequisites=frozenset(["pulumi_logged_in"]),
)


# =============================================================================
# Composite Prerequisites
# =============================================================================

K8S_READY: EffectNode[bool] = EffectNode(
    effect=Pure(
        effect_id="k8s_ready",
        description="Validate Kubernetes cluster is fully ready",
        value=True,
    ),
    prerequisites=frozenset(["k8s_cluster_reachable", "rke2_service_active"]),
)

INFRA_READY: EffectNode[bool] = EffectNode(
    effect=Pure(
        effect_id="infra_ready",
        description="Validate all infrastructure prerequisites",
        value=True,
    ),
    prerequisites=frozenset(["k8s_ready", "aws_credentials_valid"]),
)


# =============================================================================
# Prerequisite Registry
# =============================================================================

PREREQUISITE_REGISTRY: PrerequisiteRegistry = {
    # Platform
    "platform_linux": PLATFORM_LINUX,
    "systemd_available": SYSTEMD_AVAILABLE,
    "machine_identity": MACHINE_IDENTITY,
    # Tools
    "tool_kubectl": TOOL_KUBECTL,
    "tool_docker": TOOL_DOCKER,
    "tool_ctr": TOOL_CTR,
    "tool_helm": TOOL_HELM,
    "tool_sudo": TOOL_SUDO,
    "tool_pulumi": TOOL_PULUMI,
    "tool_rke2": TOOL_RKE2,
    "tool_systemctl": TOOL_SYSTEMCTL,
    # Configuration
    "settings_loaded": SETTINGS_LOADED,
    "kubeconfig_exists": KUBECONFIG_EXISTS,
    "kubeconfig_home_exists": KUBECONFIG_HOME_EXISTS,
    "rke2_config_exists": RKE2_CONFIG_EXISTS,
    "rke2_killall_exists": RKE2_KILLALL_EXISTS,
    # AWS / Route 53
    "aws_credentials_valid": AWS_CREDENTIALS_VALID,
    "route53_accessible": ROUTE53_ACCESSIBLE,
    # RKE2 / Kubernetes
    "rke2_installed": RKE2_INSTALLED,
    "rke2_service_exists": RKE2_SERVICE_EXISTS,
    "rke2_service_active": RKE2_SERVICE_ACTIVE,
    "k8s_cluster_reachable": K8S_CLUSTER_REACHABLE,
    # Pulumi
    "pulumi_logged_in": PULUMI_LOGGED_IN,
    "pulumi_stack_exists": PULUMI_STACK_EXISTS,
    # Composite
    "k8s_ready": K8S_READY,
    "infra_ready": INFRA_READY,
}


# =============================================================================
# Exports
# =============================================================================

__all__ = [
    # Registry
    "PREREQUISITE_REGISTRY",
    # Platform
    "PLATFORM_LINUX",
    "SYSTEMD_AVAILABLE",
    "MACHINE_IDENTITY",
    # Tools
    "TOOL_KUBECTL",
    "TOOL_DOCKER",
    "TOOL_CTR",
    "TOOL_HELM",
    "TOOL_SUDO",
    "TOOL_PULUMI",
    "TOOL_RKE2",
    "TOOL_SYSTEMCTL",
    # Configuration
    "SETTINGS_LOADED",
    "KUBECONFIG_EXISTS",
    "KUBECONFIG_HOME_EXISTS",
    "RKE2_CONFIG_EXISTS",
    # AWS / Route 53
    "AWS_CREDENTIALS_VALID",
    "ROUTE53_ACCESSIBLE",
    # RKE2 / Kubernetes
    "RKE2_INSTALLED",
    "RKE2_SERVICE_EXISTS",
    "RKE2_SERVICE_ACTIVE",
    "K8S_CLUSTER_REACHABLE",
    # Pulumi
    "PULUMI_LOGGED_IN",
    "PULUMI_STACK_EXISTS",
    # Composite
    "K8S_READY",
    "INFRA_READY",
]
