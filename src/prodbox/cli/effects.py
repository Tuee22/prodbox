"""
Effect ADT hierarchy for declarative CLI command orchestration.

This module implements the Effect Interpreter Architecture for prodbox.
Commands return Effect specifications rather than executing side effects directly.

Core Pattern:
    Command builds Effect DAG -> Interpreter executes effects -> Returns ExecutionSummary

Example:
    >>> def dns_update(settings: Settings) -> Effect[CommandSuccess]:
    ...     return Sequence([
    ...         FetchPublicIP(),
    ...         QueryRoute53Record(zone_id, fqdn),
    ...         UpdateRoute53Record(zone_id, fqdn, ip),
    ...         WriteStdout("DNS updated successfully")
    ...     ])

Architecture:
    - Effect[T]: Base type for all effects (declarative specification)
    - Interpreter: Executes effects and manages execution
    - ExecutionSummary: Pure data structure with exit code, metrics
    - Railway-Oriented: Sequence short-circuits on first error
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path
from typing import (
    TYPE_CHECKING,
    Generic,
    Literal,
    TypeVar,
)

if TYPE_CHECKING:
    pass

# Generic type variable for Effect return types
# Covariant because Effect[T] is immutable (frozen=True) and T only appears in return positions
T = TypeVar("T", covariant=True)


@dataclass(frozen=True)
class MachineIdentity:
    """Machine identity derived from /etc/machine-id."""

    machine_id: str
    prodbox_id: str


@dataclass(frozen=True)
class HarborRuntime:
    """Resolved Harbor runtime outputs for downstream eDAG nodes."""

    registry_endpoint: str
    gateway_image: str


@dataclass(frozen=True)
class StorageRuntime:
    """Resolved retained local storage runtime for downstream eDAG nodes."""

    storage_class_name: str
    persistent_volume_name: str
    persistent_volume_claim_name: str
    host_path: Path


@dataclass(frozen=True)
class MinioRuntime:
    """Resolved MinIO runtime outputs for downstream eDAG nodes."""

    namespace: str
    release_name: str
    persistent_volume_claim_name: str


@dataclass(frozen=True)
class Effect(Generic[T]):
    """
    Base effect type - declarative specification of a side effect.

    All effects are frozen (immutable) data structures that DESCRIBE
    what should happen, without executing anything. The interpreter
    pattern-matches on effect types and executes them.

    Attributes:
        effect_id: Unique identifier for this effect (auto-generated)
        description: Human-readable description for summary/logging
    """

    effect_id: str
    description: str


# =============================================================================
# Platform Detection Effects
# =============================================================================


@dataclass(frozen=True)
class RequireLinux(Effect[None]):
    """
    Require Linux platform, fail if not met.

    Returns: None if platform is Linux
    Raises: PlatformUnsupportedError if not Linux

    Example:
        >>> RequireLinux(
        ...     effect_id="require_linux",
        ...     description="Require Linux for systemd operations"
        ... )
    """


@dataclass(frozen=True)
class RequireSystemd(Effect[None]):
    """
    Require systemd availability, fail if not available.

    Returns: None if systemd is available
    Raises: PlatformUnsupportedError if systemd not found

    Example:
        >>> RequireSystemd(
        ...     effect_id="require_systemd",
        ...     description="Require systemd for service management"
        ... )
    """


@dataclass(frozen=True)
class ResolveMachineIdentity(Effect[MachineIdentity]):
    """
    Resolve Linux machine identity and derived prodbox-id.

    Returns: MachineIdentity with machine_id and prodbox_id
    """

    file_path: Path = Path("/etc/machine-id")


# =============================================================================
# Tool Validation Effects
# =============================================================================


@dataclass(frozen=True)
class ValidateTool(Effect[bool]):
    """
    Validate that an external tool is available.

    Returns: True if tool is valid, False otherwise

    Example:
        >>> ValidateTool(
        ...     effect_id="validate_kubectl",
        ...     description="Validate kubectl is available",
        ...     tool_name="kubectl",
        ...     version_flag="version --client"
        ... )
    """

    tool_name: str
    version_flag: str = "--version"
    min_version: str | None = None


@dataclass(frozen=True)
class ValidateEnvironment(Effect[bool]):
    """
    Validate multiple external tools are available.

    Returns: True if all tools are valid, False if any are missing

    Example:
        >>> ValidateEnvironment(
        ...     effect_id="validate_k8s_tools",
        ...     description="Validate Kubernetes tools",
        ...     tools=["kubectl", "helm", "pulumi"]
        ... )
    """

    tools: list[str]


# =============================================================================
# File System Effects
# =============================================================================


@dataclass(frozen=True)
class CheckFileExists(Effect[bool]):
    """
    Check if a file exists.

    Returns: True if file exists, False otherwise

    Example:
        >>> CheckFileExists(
        ...     effect_id="check_kubeconfig",
        ...     description="Check kubeconfig exists",
        ...     file_path=Path("~/.kube/config")
        ... )
    """

    file_path: Path


@dataclass(frozen=True)
class ReadFile(Effect[str]):
    """
    Read file contents.

    Returns: File contents as string

    Example:
        >>> ReadFile(
        ...     effect_id="read_config",
        ...     description="Read RKE2 config",
        ...     file_path=Path("/etc/rancher/rke2/config.yaml")
        ... )
    """

    file_path: Path


@dataclass(frozen=True)
class WriteFile(Effect[None]):
    """
    Write file contents.

    Returns: None

    Example:
        >>> WriteFile(
        ...     effect_id="write_service",
        ...     description="Write systemd service file",
        ...     file_path=Path("/etc/systemd/system/ddns.service"),
        ...     content="[Unit]\\nDescription=DDNS"
        ... )
    """

    file_path: Path
    content: str
    sudo: bool = False


# =============================================================================
# Subprocess Execution Effects
# =============================================================================


@dataclass(frozen=True)
class RunSubprocess(Effect[int]):
    """
    Execute subprocess command.

    Returns: Exit code (0 = success, non-zero = failure)

    Attributes:
        command: Command to execute as list (exec mode, NOT shell mode)
        cwd: Working directory (None = current directory)
        env: Environment variables (None = inherit from parent)
        timeout: Timeout in seconds (None = no timeout)
        stream_stdout: Whether to stream stdout to terminal in real-time
        capture_output: Whether to capture stdout/stderr (default True)

    Example:
        >>> RunSubprocess(
        ...     effect_id="run_kubectl_apply",
        ...     description="Apply Kubernetes manifest",
        ...     command=["kubectl", "apply", "-f", "manifest.yaml"],
        ...     stream_stdout=True,
        ...     timeout=60
        ... )
    """

    command: list[str]
    cwd: Path | None = None
    env: dict[str, str] | None = None
    timeout: float | None = None
    stream_stdout: bool = False
    capture_output: bool = True
    input_data: bytes | None = None


@dataclass(frozen=True)
class CaptureSubprocessOutput(Effect[tuple[int, str, str]]):
    """
    Execute subprocess command and capture stdout/stderr.

    Returns: (returncode, stdout, stderr)

    Attributes:
        command: Command to execute as list (exec mode, NOT shell mode)
        cwd: Working directory (None = current directory)
        env: Environment variables (None = inherit from parent)
        timeout: Timeout in seconds (None = no timeout)

    Example:
        >>> CaptureSubprocessOutput(
        ...     effect_id="get_kubectl_version",
        ...     description="Get kubectl version",
        ...     command=["kubectl", "version", "--client", "-o", "json"]
        ... )
    """

    command: list[str]
    cwd: Path | None = None
    env: dict[str, str] | None = None
    timeout: float | None = None


# =============================================================================
# Systemd Service Effects
# =============================================================================


@dataclass(frozen=True)
class RunSystemdCommand(Effect[int]):
    """
    Execute systemctl command.

    Returns: Exit code (0 = success, non-zero = failure)

    Example:
        >>> RunSystemdCommand(
        ...     effect_id="start_rke2",
        ...     description="Start RKE2 service",
        ...     action="start",
        ...     service="rke2-server.service",
        ...     sudo=True
        ... )
    """

    action: Literal[
        "start",
        "stop",
        "restart",
        "enable",
        "disable",
        "status",
        "is-active",
        "is-enabled",
        "daemon-reload",
    ]
    service: str | None = None
    sudo: bool = False
    timeout: float | None = None


@dataclass(frozen=True)
class CheckServiceStatus(Effect[str]):
    """
    Check systemd service status.

    Returns: Service status string ("active", "inactive", "failed", etc.)

    Example:
        >>> CheckServiceStatus(
        ...     effect_id="check_rke2_status",
        ...     description="Check RKE2 service status",
        ...     service="rke2-server.service"
        ... )
    """

    service: str


@dataclass(frozen=True)
class GetJournalLogs(Effect[str]):
    """
    Get journalctl logs for a service.

    Returns: Log contents as string

    Example:
        >>> GetJournalLogs(
        ...     effect_id="get_rke2_logs",
        ...     description="Get RKE2 logs",
        ...     service="rke2-server.service",
        ...     lines=50
        ... )
    """

    service: str
    lines: int = 50


# =============================================================================
# Kubernetes Effects
# =============================================================================


@dataclass(frozen=True)
class RunKubectlCommand(Effect[int]):
    """
    Execute kubectl command.

    Returns: Exit code (0 = success, non-zero = failure)

    Example:
        >>> RunKubectlCommand(
        ...     effect_id="kubectl_apply",
        ...     description="Apply manifest",
        ...     args=["apply", "-f", "manifest.yaml"],
        ...     kubeconfig=Path("~/.kube/config")
        ... )
    """

    args: list[str]
    kubeconfig: Path | None = None
    namespace: str | None = None
    timeout: float | None = None
    stream_stdout: bool = False


@dataclass(frozen=True)
class CaptureKubectlOutput(Effect[tuple[int, str, str]]):
    """
    Execute kubectl command and capture output.

    Returns: (returncode, stdout, stderr)

    Example:
        >>> CaptureKubectlOutput(
        ...     effect_id="get_nodes",
        ...     description="Get cluster nodes",
        ...     args=["get", "nodes", "-o", "json"],
        ...     kubeconfig=Path("~/.kube/config")
        ... )
    """

    args: list[str]
    kubeconfig: Path | None = None
    namespace: str | None = None
    timeout: float | None = None


@dataclass(frozen=True)
class KubectlWait(Effect[bool]):
    """
    Wait for Kubernetes resources to meet condition.

    Returns: True if condition met, False if timeout

    Example:
        >>> KubectlWait(
        ...     effect_id="wait_deployments",
        ...     description="Wait for deployments",
        ...     resource="deployment",
        ...     condition="available",
        ...     namespace="default",
        ...     timeout=300
        ... )
    """

    resource: str
    condition: str
    kubeconfig: Path | None = None
    namespace: str | None = None
    selector: str | None = None
    all_resources: bool = False
    timeout: int = 300


@dataclass(frozen=True)
class EnsureHarborRegistry(Effect[HarborRuntime]):
    """
    Install and reconcile local Harbor registry + prodbox gateway image pipeline.

    Returns: HarborRuntime with resolved registry endpoint and gateway image ref
    """

    machine_identity: MachineIdentity
    namespace: str
    release_name: str
    repository_name: str
    repository_url: str
    registry_endpoint: str
    mirror_project: str
    gateway_image_repository: str
    gateway_dockerfile: Path
    gateway_build_context: Path
    registries_file_path: Path
    admin_user: str = "admin"
    admin_password: str = "Harbor12345"
    wait_timeout_seconds: int = 300
    install_timeout_seconds: float = 600.0
    mirror_cluster_images: bool = True


@dataclass(frozen=True)
class EnsureRetainedLocalStorage(Effect[StorageRuntime]):
    """
    Reconcile static retained local storage resources for deterministic rebinding.

    Returns: StorageRuntime with resolved StorageClass/PV/PVC values
    """

    machine_identity: MachineIdentity
    namespace: str
    storage_class_name: str
    persistent_volume_name: str
    persistent_volume_claim_name: str
    storage_size: str
    host_storage_base_path: Path
    annotation_key: str
    label_key: str
    label_value: str


@dataclass(frozen=True)
class EnsureMinio(Effect[MinioRuntime]):
    """
    Install and reconcile MinIO via official Helm chart.

    Returns: MinioRuntime with resolved namespace/release/PVC values
    """

    machine_identity: MachineIdentity
    namespace: str
    release_name: str
    repository_name: str
    repository_url: str
    chart_ref: str
    chart_version: str
    existing_claim: str
    annotation_key: str
    label_key: str
    label_value: str
    storage_size: str
    install_timeout_seconds: float = 600.0
    wait_timeout_seconds: int = 300


@dataclass(frozen=True)
class EnsureProdboxIdentityConfigMap(Effect[None]):
    """
    Ensure prodbox namespace and identity ConfigMap exist.

    Returns: None
    """

    machine_identity: MachineIdentity
    namespace: str
    configmap_name: str
    annotation_key: str
    label_key: str
    label_value: str


@dataclass(frozen=True)
class AnnotateProdboxManagedResources(Effect[None]):
    """
    Reconcile prodbox annotation/label onto managed Kubernetes resources.

    Returns: None
    """

    prodbox_id: str
    annotation_key: str
    label_key: str
    label_value: str
    managed_namespaces: tuple[str, ...]
    helm_instances: tuple[str, ...]


@dataclass(frozen=True)
class CleanupProdboxAnnotatedResources(Effect[int]):
    """
    Delete Kubernetes resources annotated with the current prodbox-id.

    Returns: Number of deleted objects
    """

    prodbox_id: str
    annotation_key: str
    cleanup_passes: int = 2
    retained_resource_kinds: tuple[str, ...] = ()
    retained_namespaces: tuple[str, ...] = ()


# =============================================================================
# DNS / Route 53 Effects
# =============================================================================


@dataclass(frozen=True)
class FetchPublicIP(Effect[str]):
    """
    Fetch current public IP address.

    Returns: Public IP address as string

    Example:
        >>> FetchPublicIP(
        ...     effect_id="fetch_public_ip",
        ...     description="Get current public IP"
        ... )
    """


@dataclass(frozen=True)
class QueryRoute53Record(Effect[str | None]):
    """
    Query Route 53 for current A record IP.

    Returns: Current IP address or None if not found

    Example:
        >>> QueryRoute53Record(
        ...     effect_id="query_dns",
        ...     description="Query current DNS record",
        ...     zone_id="Z1234567890",
        ...     fqdn="home.example.com"
        ... )
    """

    zone_id: str
    fqdn: str
    aws_region: str = "us-east-1"
    aws_access_key_id: str | None = None
    aws_secret_access_key: str | None = None


@dataclass(frozen=True)
class UpdateRoute53Record(Effect[None]):
    """
    Update or create Route 53 A record.

    Returns: None

    Example:
        >>> UpdateRoute53Record(
        ...     effect_id="update_dns",
        ...     description="Update DNS A record",
        ...     zone_id="Z1234567890",
        ...     fqdn="home.example.com",
        ...     ip="1.2.3.4",
        ...     ttl=300
        ... )
    """

    zone_id: str
    fqdn: str
    ip: str
    ttl: int = 300
    aws_region: str = "us-east-1"
    aws_access_key_id: str | None = None
    aws_secret_access_key: str | None = None


@dataclass(frozen=True)
class ValidateAWSCredentials(Effect[bool]):
    """
    Validate AWS credentials are configured and working.

    Returns: True if credentials valid, False otherwise

    Example:
        >>> ValidateAWSCredentials(
        ...     effect_id="validate_aws",
        ...     description="Validate AWS credentials",
        ...     aws_region="us-east-1"
        ... )
    """

    aws_region: str = "us-east-1"
    aws_access_key_id: str | None = None
    aws_secret_access_key: str | None = None


# =============================================================================
# Pulumi Effects
# =============================================================================


@dataclass(frozen=True)
class RunPulumiCommand(Effect[int]):
    """
    Execute Pulumi CLI command.

    Returns: Exit code (0 = success, non-zero = failure)

    Example:
        >>> RunPulumiCommand(
        ...     effect_id="pulumi_up",
        ...     description="Apply Pulumi stack",
        ...     args=["up", "--yes"],
        ...     cwd=Path("./infra"),
        ...     stream_stdout=True
        ... )
    """

    args: list[str]
    cwd: Path | None = None
    env: dict[str, str] | None = None
    timeout: float | None = None
    stream_stdout: bool = True


@dataclass(frozen=True)
class PulumiStackSelect(Effect[bool]):
    """
    Select Pulumi stack.

    Returns: True if stack selected, False if failed

    Example:
        >>> PulumiStackSelect(
        ...     effect_id="select_stack",
        ...     description="Select dev stack",
        ...     stack="dev",
        ...     cwd=Path("./infra")
        ... )
    """

    stack: str
    cwd: Path | None = None
    create_if_missing: bool = False


@dataclass(frozen=True)
class PulumiPreview(Effect[int]):
    """
    Run Pulumi preview.

    Returns: Exit code (0 = no changes needed, non-zero = changes or error)

    Example:
        >>> PulumiPreview(
        ...     effect_id="pulumi_preview",
        ...     description="Preview infrastructure changes",
        ...     cwd=Path("./infra"),
        ...     stream_stdout=True
        ... )
    """

    cwd: Path | None = None
    stack: str | None = None
    env: dict[str, str] | None = None
    stream_stdout: bool = True


@dataclass(frozen=True)
class PulumiUp(Effect[int]):
    """
    Run Pulumi up (apply changes).

    Returns: Exit code (0 = success, non-zero = failure)

    Example:
        >>> PulumiUp(
        ...     effect_id="pulumi_up",
        ...     description="Apply infrastructure changes",
        ...     cwd=Path("./infra"),
        ...     yes=True
        ... )
    """

    cwd: Path | None = None
    stack: str | None = None
    env: dict[str, str] | None = None
    yes: bool = True
    stream_stdout: bool = True


@dataclass(frozen=True)
class PulumiDestroy(Effect[int]):
    """
    Run Pulumi destroy.

    Returns: Exit code (0 = success, non-zero = failure)

    Example:
        >>> PulumiDestroy(
        ...     effect_id="pulumi_destroy",
        ...     description="Destroy infrastructure",
        ...     cwd=Path("./infra"),
        ...     yes=True
        ... )
    """

    cwd: Path | None = None
    stack: str | None = None
    env: dict[str, str] | None = None
    yes: bool = True
    stream_stdout: bool = True


@dataclass(frozen=True)
class PulumiRefresh(Effect[int]):
    """
    Run Pulumi refresh.

    Returns: Exit code (0 = success, non-zero = failure)

    Example:
        >>> PulumiRefresh(
        ...     effect_id="pulumi_refresh",
        ...     description="Refresh infrastructure state",
        ...     cwd=Path("./infra")
        ... )
    """

    cwd: Path | None = None
    stack: str | None = None
    env: dict[str, str] | None = None
    yes: bool = True
    stream_stdout: bool = True


# =============================================================================
# Settings / Configuration Effects
# =============================================================================


@dataclass(frozen=True)
class LoadSettings(Effect[object]):
    """
    Load prodbox settings from environment.

    Returns: Settings object

    Example:
        >>> LoadSettings(
        ...     effect_id="load_settings",
        ...     description="Load prodbox configuration"
        ... )
    """


@dataclass(frozen=True)
class ValidateSettings(Effect[bool]):
    """
    Validate settings are complete and valid.

    Returns: True if valid, False otherwise

    Example:
        >>> ValidateSettings(
        ...     effect_id="validate_settings",
        ...     description="Validate prodbox configuration"
        ... )
    """


# =============================================================================
# Output Effects (Stdout/Stderr)
# =============================================================================


@dataclass(frozen=True)
class WriteStdout(Effect[None]):
    """
    Write a standalone terminal record to stdout.

    The interpreter appends a trailing newline when one is omitted so
    phase banners, headers, and summaries do not share a terminal line.

    Returns: None

    Example:
        >>> WriteStdout(
        ...     effect_id="print_success",
        ...     description="Print success message",
        ...     text="DNS updated successfully!"
        ... )
    """

    text: str


@dataclass(frozen=True)
class WriteStderr(Effect[None]):
    """
    Write a standalone terminal record to stderr.

    The interpreter appends a trailing newline when one is omitted so
    failure reports remain line-delimited in the terminal.

    Returns: None

    Example:
        >>> WriteStderr(
        ...     effect_id="print_error",
        ...     description="Print error message",
        ...     text="Failed to connect to cluster"
        ... )
    """

    text: str


@dataclass(frozen=True)
class PrintInfo(Effect[None]):
    """
    Print info message with Rich formatting.

    Returns: None

    Example:
        >>> PrintInfo(
        ...     effect_id="print_info",
        ...     description="Print status info",
        ...     message="Checking cluster health..."
        ... )
    """

    message: str
    style: str = "blue"


@dataclass(frozen=True)
class PrintSuccess(Effect[None]):
    """
    Print success message with Rich formatting.

    Returns: None

    Example:
        >>> PrintSuccess(
        ...     effect_id="print_success",
        ...     description="Print success",
        ...     message="All pods are ready"
        ... )
    """

    message: str
    style: str = "green"


@dataclass(frozen=True)
class PrintWarning(Effect[None]):
    """
    Print warning message with Rich formatting.

    Returns: None

    Example:
        >>> PrintWarning(
        ...     effect_id="print_warning",
        ...     description="Print warning",
        ...     message="Some pods are not ready"
        ... )
    """

    message: str
    style: str = "yellow"


@dataclass(frozen=True)
class PrintError(Effect[None]):
    """
    Print error message with Rich formatting.

    Returns: None

    Example:
        >>> PrintError(
        ...     effect_id="print_error",
        ...     description="Print error",
        ...     message="Cluster unreachable"
        ... )
    """

    message: str
    style: str = "red"


@dataclass(frozen=True)
class PrintTable(Effect[None]):
    """
    Print a formatted table with Rich.

    Returns: None

    Example:
        >>> PrintTable(
        ...     effect_id="print_config_table",
        ...     description="Print configuration table",
        ...     title="Prodbox Configuration",
        ...     columns=(("Setting", "cyan"), ("Value", "green")),
        ...     rows=(("KUBECONFIG", "/home/user/.kube/config"),)
        ... )
    """

    title: str
    columns: tuple[tuple[str, str], ...]  # (column_name, style)
    rows: tuple[tuple[str, ...], ...]


@dataclass(frozen=True)
class PrintSection(Effect[None]):
    """
    Print a section header with optional blank lines.

    Returns: None

    Example:
        >>> PrintSection(
        ...     effect_id="print_section",
        ...     description="Print section header",
        ...     title="Cluster Connectivity",
        ...     blank_before=True,
        ...     blank_after=True
        ... )
    """

    title: str
    style: str = "blue bold"
    blank_before: bool = False
    blank_after: bool = True


@dataclass(frozen=True)
class PrintIndented(Effect[None]):
    """
    Print indented text, optionally with Rich markup.

    Returns: None

    Example:
        >>> PrintIndented(
        ...     effect_id="print_pod_status",
        ...     description="Print pod status indented",
        ...     text="pod-abc123: [green]Running[/green]",
        ...     indent=2
        ... )
    """

    text: str
    indent: int = 2


@dataclass(frozen=True)
class PrintBlankLine(Effect[None]):
    """
    Print a blank line.

    Returns: None

    Example:
        >>> PrintBlankLine(
        ...     effect_id="print_blank",
        ...     description="Print blank line separator"
        ... )
    """


@dataclass(frozen=True)
class ConfirmAction(Effect[bool]):
    """
    Request user confirmation for an action.

    Returns: True if confirmed, False if declined

    When yes=True in command, this effect should be skipped by the DAG builder
    or the interpreter should auto-approve.

    Example:
        >>> ConfirmAction(
        ...     effect_id="confirm_destroy",
        ...     description="Confirm infrastructure destruction",
        ...     message="Destroy all infrastructure?",
        ...     default=False,
        ...     abort_on_decline=True
        ... )
    """

    message: str
    default: bool = False
    abort_on_decline: bool = True


# =============================================================================
# Composite Effects (Sequencing and Parallelism)
# =============================================================================


@dataclass(frozen=True)
class Sequence(Effect[list[object]]):
    """
    Execute effects sequentially (Railway-Oriented Programming).

    Short-circuits on first error - if any effect fails, remaining effects
    are not executed.

    Returns: List of results from all effects (if all succeed)

    Example:
        >>> Sequence(
        ...     effect_id="dns_update_workflow",
        ...     description="Update DNS workflow",
        ...     effects=[
        ...         FetchPublicIP(...),
        ...         QueryRoute53Record(...),
        ...         UpdateRoute53Record(...)
        ...     ]
        ... )
    """

    effects: list[Effect[object]]


@dataclass(frozen=True)
class Parallel(Effect[list[object]]):
    """
    Execute effects concurrently (asyncio.gather).

    All effects execute concurrently. If any effect fails, all effects
    complete but the Parallel effect itself fails.

    Returns: List of results from all effects

    Example:
        >>> Parallel(
        ...     effect_id="check_all_namespaces",
        ...     description="Check all infrastructure namespaces",
        ...     effects=[
        ...         CheckNamespacePods("metallb-system"),
        ...         CheckNamespacePods("traefik-system"),
        ...         CheckNamespacePods("cert-manager")
        ...     ]
        ... )
    """

    effects: list[Effect[object]]
    max_concurrent: int | None = None


@dataclass(frozen=True)
class Try(Effect[object]):
    """
    Execute effect with fallback on failure.

    If primary effect fails, execute fallback effect instead.

    Returns: Result from primary effect (if success) or fallback effect

    Example:
        >>> Try(
        ...     effect_id="try_kubectl",
        ...     description="Try kubectl with fallback",
        ...     primary=RunKubectlCommand(args=["get", "nodes"]),
        ...     fallback=PrintError(message="Cluster not accessible")
        ... )
    """

    primary: Effect[object]
    fallback: Effect[object]


# =============================================================================
# Gateway Daemon Effects
# =============================================================================


@dataclass(frozen=True)
class StartGatewayDaemon(Effect[None]):
    """
    Load gateway config and run daemon event loop.

    Returns: None (runs until interrupted)

    Example:
        >>> StartGatewayDaemon(
        ...     effect_id="start_gateway",
        ...     description="Start gateway daemon",
        ...     config_path=Path("/etc/gateway/config.json")
        ... )
    """

    config_path: Path


@dataclass(frozen=True)
class QueryGatewayState(Effect[str]):
    """
    Query running gateway daemon REST API for current state.

    Returns: JSON state string

    Example:
        >>> QueryGatewayState(
        ...     effect_id="query_gateway",
        ...     description="Query gateway daemon state",
        ...     config_path=Path("/etc/gateway/config.json")
        ... )
    """

    config_path: Path


@dataclass(frozen=True)
class GenerateGatewayConfig(Effect[None]):
    """
    Generate a template gateway daemon config file.

    Returns: None

    Example:
        >>> GenerateGatewayConfig(
        ...     effect_id="gen_config",
        ...     description="Generate gateway config template",
        ...     output_path=Path("gateway-config.json"),
        ...     node_id="node-a"
        ... )
    """

    output_path: Path
    node_id: str


# =============================================================================
# Pure Effect (No-Op for Testing)
# =============================================================================


@dataclass(frozen=True)
class Pure(Effect[T]):
    """
    Pure effect that returns a value without side effects.

    Useful for testing and composing effects with pure computations.

    Returns: The provided value

    Example:
        >>> Pure(
        ...     effect_id="return_ip",
        ...     description="Return constant IP",
        ...     value="192.168.1.1"
        ... )
    """

    value: T


# =============================================================================
# Custom Effect (User-Defined Logic)
# =============================================================================


@dataclass(frozen=True)
class Custom(Effect[T]):
    """
    Custom effect that executes user-defined logic (sync or async).

    Allows extending the effect system without modifying the interpreter.
    The function should be async and return Result[T, str].

    Returns: Result from executing the function

    Example:
        >>> async def my_logic() -> Result[str, str]:
        ...     return Success("done")
        ...
        >>> Custom(
        ...     effect_id="custom_check",
        ...     description="Run custom validation",
        ...     fn=my_logic
        ... )
    """

    fn: Callable[[], Awaitable[object] | object]


# =============================================================================
# Effect Builder Helpers
# =============================================================================


def sequence(*effects: Effect[object]) -> Sequence:
    """
    Builder function for Sequence effects.

    Example:
        >>> sequence(
        ...     ValidateEnvironment(tools=["kubectl"]),
        ...     RunKubectlCommand(args=["get", "nodes"]),
        ...     PrintSuccess(message="Cluster healthy")
        ... )
    """
    return Sequence(
        effect_id=f"sequence_{len(effects)}_effects",
        description=f"Execute {len(effects)} effects sequentially",
        effects=list(effects),
    )


def parallel(*effects: Effect[object]) -> Parallel:
    """
    Builder function for Parallel effects.

    Example:
        >>> parallel(
        ...     CheckServiceStatus(service="metallb"),
        ...     CheckServiceStatus(service="traefik"),
        ...     CheckServiceStatus(service="cert-manager")
        ... )
    """
    return Parallel(
        effect_id=f"parallel_{len(effects)}_effects",
        description=f"Execute {len(effects)} effects concurrently",
        effects=list(effects),
    )


# =============================================================================
# Exports
# =============================================================================

__all__ = [
    # Base type
    "Effect",
    "MachineIdentity",
    "HarborRuntime",
    "StorageRuntime",
    "MinioRuntime",
    # Platform
    "RequireLinux",
    "RequireSystemd",
    "ResolveMachineIdentity",
    # Tool validation
    "ValidateTool",
    "ValidateEnvironment",
    # File system
    "CheckFileExists",
    "ReadFile",
    "WriteFile",
    # Subprocess
    "RunSubprocess",
    "CaptureSubprocessOutput",
    # Systemd
    "RunSystemdCommand",
    "CheckServiceStatus",
    "GetJournalLogs",
    # Kubernetes
    "RunKubectlCommand",
    "CaptureKubectlOutput",
    "KubectlWait",
    "EnsureHarborRegistry",
    "EnsureRetainedLocalStorage",
    "EnsureMinio",
    "EnsureProdboxIdentityConfigMap",
    "AnnotateProdboxManagedResources",
    "CleanupProdboxAnnotatedResources",
    # DNS / Route 53
    "FetchPublicIP",
    "QueryRoute53Record",
    "UpdateRoute53Record",
    "ValidateAWSCredentials",
    # Pulumi
    "RunPulumiCommand",
    "PulumiStackSelect",
    "PulumiPreview",
    "PulumiUp",
    "PulumiDestroy",
    "PulumiRefresh",
    # Gateway
    "StartGatewayDaemon",
    "QueryGatewayState",
    "GenerateGatewayConfig",
    # Settings
    "LoadSettings",
    "ValidateSettings",
    # Output
    "WriteStdout",
    "WriteStderr",
    "PrintInfo",
    "PrintSuccess",
    "PrintWarning",
    "PrintError",
    "PrintTable",
    "PrintSection",
    "PrintIndented",
    "PrintBlankLine",
    "ConfirmAction",
    # Composite
    "Sequence",
    "Parallel",
    "Try",
    # Pure / Custom
    "Pure",
    "Custom",
    # Builders
    "sequence",
    "parallel",
]
