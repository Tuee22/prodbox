"""Command ADTs for type-safe CLI commands.

This module defines commands as immutable ADTs (frozen dataclasses) with
smart constructors that validate at construction time. This pattern enables:

1. Type-safe command representation
2. Validation at construction (fail-fast)
3. Platform-aware smart constructors (Linux-only commands fail on other platforms)
4. Exhaustive pattern matching on command variants
5. Single entry point for command execution

Architecture:
    Command (ADT) -> validate via smart constructor -> execute_command()

Usage:
    from prodbox.cli.command_adt import (
        DNSUpdateCommand,
        dns_update_command,
        execute_command,
        Command,
    )

    # Smart constructor validates and returns Result
    match dns_update_command(force=True):
        case Success(cmd):
            await execute_command(cmd)
        case Failure(error):
            return error  # Propagate error up to command entry point
"""

from __future__ import annotations

import platform
from dataclasses import dataclass
from pathlib import Path

from prodbox.cli.types import Failure, Result, Success

# =============================================================================
# Environment / Settings Commands
# =============================================================================


@dataclass(frozen=True)
class EnvShowCommand:
    """Show current environment configuration.

    Attributes:
        show_secrets: Whether to show secret values (default: masked)
    """

    show_secrets: bool = False


@dataclass(frozen=True)
class EnvValidateCommand:
    """Validate environment configuration is complete."""


@dataclass(frozen=True)
class EnvTemplateCommand:
    """Generate environment template file.

    Attributes:
        output_path: Path to write template (default: .env.template)
    """

    output_path: Path = Path(".env.template")


# =============================================================================
# Host Commands
# =============================================================================


@dataclass(frozen=True)
class HostInfoCommand:
    """Show host system information."""


@dataclass(frozen=True)
class HostCheckPortsCommand:
    """Check if required ports are available.

    Attributes:
        ports: Ports to check
    """

    ports: tuple[int, ...] = (80, 443, 6443, 9345)


@dataclass(frozen=True)
class HostEnsureToolsCommand:
    """Check that required CLI tools are installed."""


@dataclass(frozen=True)
class HostFirewallCommand:
    """Check and display firewall status."""


# =============================================================================
# RKE2 Commands
# =============================================================================


@dataclass(frozen=True)
class RKE2StatusCommand:
    """Check RKE2 installation and service status."""


@dataclass(frozen=True)
class RKE2StartCommand:
    """Start RKE2 server service."""


@dataclass(frozen=True)
class RKE2StopCommand:
    """Stop RKE2 server service."""


@dataclass(frozen=True)
class RKE2RestartCommand:
    """Restart RKE2 server service."""


@dataclass(frozen=True)
class RKE2EnsureCommand:
    """Idempotently provision RKE2 cluster runtime from existing installation."""


@dataclass(frozen=True)
class RKE2CleanupCommand:
    """Tear down RKE2 cluster runtime without removing host storage paths."""


@dataclass(frozen=True)
class RKE2LogsCommand:
    """Show recent RKE2 server logs.

    Attributes:
        lines: Number of log lines to show
    """

    lines: int = 50


# =============================================================================
# DNS Commands
# =============================================================================


@dataclass(frozen=True)
class DNSCheckCommand:
    """Check current DNS record and public IP."""


@dataclass(frozen=True)
class DNSUpdateCommand:
    """Update Route 53 DNS with current public IP.

    Attributes:
        force: Force update even if IP unchanged
    """

    force: bool = False


@dataclass(frozen=True)
class DNSEnsureTimerCommand:
    """Install systemd timer for automatic DDNS updates.

    Attributes:
        interval: Update interval in minutes
    """

    interval: int = 5


# =============================================================================
# Kubernetes Commands
# =============================================================================


@dataclass(frozen=True)
class K8sHealthCommand:
    """Check health of Kubernetes cluster and components."""


@dataclass(frozen=True)
class K8sWaitCommand:
    """Wait for deployments to be ready.

    Attributes:
        timeout: Timeout in seconds
        namespaces: Namespaces to wait for
    """

    timeout: int = 300
    namespaces: tuple[str, ...] = ("metallb-system", "traefik-system", "cert-manager")


@dataclass(frozen=True)
class K8sLogsCommand:
    """Show recent logs from infrastructure pods.

    Attributes:
        namespaces: Namespaces to get logs from
        tail: Number of log lines per container
    """

    namespaces: tuple[str, ...] = ("metallb-system", "traefik-system", "cert-manager")
    tail: int = 10


# =============================================================================
# Pulumi Commands
# =============================================================================


@dataclass(frozen=True)
class PulumiPreviewCommand:
    """Preview infrastructure changes.

    Attributes:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi
    """

    stack: str | None = None
    cwd: Path | None = None


@dataclass(frozen=True)
class PulumiUpCommand:
    """Apply infrastructure changes.

    Attributes:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi
        yes: Skip confirmation prompt
    """

    stack: str | None = None
    cwd: Path | None = None
    yes: bool = True


@dataclass(frozen=True)
class PulumiDestroyCommand:
    """Destroy infrastructure.

    Attributes:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi
        yes: Skip confirmation prompt
    """

    stack: str | None = None
    cwd: Path | None = None
    yes: bool = False


@dataclass(frozen=True)
class PulumiRefreshCommand:
    """Refresh infrastructure state.

    Attributes:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi
    """

    stack: str | None = None
    cwd: Path | None = None


@dataclass(frozen=True)
class PulumiStackInitCommand:
    """Initialize a new Pulumi stack.

    Attributes:
        stack: Stack name to create
        cwd: Working directory for Pulumi
    """

    stack: str
    cwd: Path | None = None


# =============================================================================
# Gateway Commands
# =============================================================================


@dataclass(frozen=True)
class GatewayStartCommand:
    """Start gateway daemon from config file.

    Attributes:
        config_path: Path to gateway daemon JSON config file
    """

    config_path: Path


@dataclass(frozen=True)
class GatewayStatusCommand:
    """Query running gateway daemon status.

    Attributes:
        config_path: Path to gateway daemon JSON config file (for endpoint info)
    """

    config_path: Path


@dataclass(frozen=True)
class GatewayConfigGenCommand:
    """Generate template gateway config file.

    Attributes:
        output_path: Path to write template config
        node_id: Node ID for the generated config
    """

    output_path: Path
    node_id: str


# =============================================================================
# Command Union Type
# =============================================================================

Command = (
    # Environment
    EnvShowCommand
    | EnvValidateCommand
    | EnvTemplateCommand
    # Host
    | HostInfoCommand
    | HostCheckPortsCommand
    | HostEnsureToolsCommand
    | HostFirewallCommand
    # RKE2
    | RKE2StatusCommand
    | RKE2StartCommand
    | RKE2StopCommand
    | RKE2RestartCommand
    | RKE2EnsureCommand
    | RKE2CleanupCommand
    | RKE2LogsCommand
    # DNS
    | DNSCheckCommand
    | DNSUpdateCommand
    | DNSEnsureTimerCommand
    # Kubernetes
    | K8sHealthCommand
    | K8sWaitCommand
    | K8sLogsCommand
    # Pulumi
    | PulumiPreviewCommand
    | PulumiUpCommand
    | PulumiDestroyCommand
    | PulumiRefreshCommand
    | PulumiStackInitCommand
    # Gateway
    | GatewayStartCommand
    | GatewayStatusCommand
    | GatewayConfigGenCommand
)


# =============================================================================
# Smart Constructors
# =============================================================================


def env_show_command(
    *,
    show_secrets: bool = False,
) -> Result[EnvShowCommand, str]:
    """Create an EnvShowCommand.

    Args:
        show_secrets: Whether to show secret values

    Returns:
        Success with EnvShowCommand
    """
    return Success(EnvShowCommand(show_secrets=show_secrets))


def env_validate_command() -> Result[EnvValidateCommand, str]:
    """Create an EnvValidateCommand.

    Returns:
        Success with EnvValidateCommand
    """
    return Success(EnvValidateCommand())


def env_template_command(
    *,
    output_path: Path | None = None,
) -> Result[EnvTemplateCommand, str]:
    """Create an EnvTemplateCommand.

    Args:
        output_path: Path to write template

    Returns:
        Success with EnvTemplateCommand
    """
    path = output_path or Path(".env.template")
    return Success(EnvTemplateCommand(output_path=path))


def host_info_command() -> Result[HostInfoCommand, str]:
    """Create a HostInfoCommand.

    Returns:
        Success with HostInfoCommand
    """
    return Success(HostInfoCommand())


def host_check_ports_command(
    *,
    ports: list[int] | None = None,
) -> Result[HostCheckPortsCommand, str]:
    """Create a HostCheckPortsCommand.

    Args:
        ports: List of ports to check

    Returns:
        Success with HostCheckPortsCommand, Failure if invalid ports
    """
    port_list = ports or [80, 443, 6443, 9345]

    # Validate port numbers
    invalid = [p for p in port_list if p < 1 or p > 65535]
    if invalid:
        return Failure(f"Invalid port numbers: {invalid}. Must be 1-65535")

    return Success(HostCheckPortsCommand(ports=tuple(port_list)))


def host_ensure_tools_command() -> Result[HostEnsureToolsCommand, str]:
    """Create a HostEnsureToolsCommand.

    Returns:
        Success with HostEnsureToolsCommand
    """
    return Success(HostEnsureToolsCommand())


def host_firewall_command() -> Result[HostFirewallCommand, str]:
    """Create a HostFirewallCommand.

    Returns:
        Success with HostFirewallCommand
    """
    return Success(HostFirewallCommand())


def rke2_status_command() -> Result[RKE2StatusCommand, str]:
    """Create an RKE2StatusCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.

    Returns:
        Success with RKE2StatusCommand on Linux, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("RKE2 commands require Linux")

    return Success(RKE2StatusCommand())


def rke2_start_command() -> Result[RKE2StartCommand, str]:
    """Create an RKE2StartCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.

    Returns:
        Success with RKE2StartCommand on Linux, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("RKE2 commands require Linux")

    return Success(RKE2StartCommand())


def rke2_stop_command() -> Result[RKE2StopCommand, str]:
    """Create an RKE2StopCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.

    Returns:
        Success with RKE2StopCommand on Linux, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("RKE2 commands require Linux")

    return Success(RKE2StopCommand())


def rke2_restart_command() -> Result[RKE2RestartCommand, str]:
    """Create an RKE2RestartCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.

    Returns:
        Success with RKE2RestartCommand on Linux, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("RKE2 commands require Linux")

    return Success(RKE2RestartCommand())


def rke2_ensure_command() -> Result[RKE2EnsureCommand, str]:
    """Create an RKE2EnsureCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.

    Returns:
        Success with RKE2EnsureCommand on Linux, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("RKE2 commands require Linux")

    return Success(RKE2EnsureCommand())


def rke2_cleanup_command(*, yes: bool = False) -> Result[RKE2CleanupCommand, str]:
    """Create an RKE2CleanupCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.
    SAFETY: Requires explicit --yes acknowledgement because cleanup is destructive.

    Args:
        yes: Confirmation flag from CLI --yes option

    Returns:
        Success with RKE2CleanupCommand on Linux when yes=True, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("RKE2 commands require Linux")

    if not yes:
        return Failure("rke2 cleanup requires --yes confirmation")

    return Success(RKE2CleanupCommand())


def rke2_logs_command(
    *,
    lines: int = 50,
) -> Result[RKE2LogsCommand, str]:
    """Create an RKE2LogsCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms.

    Args:
        lines: Number of log lines to show

    Returns:
        Success with RKE2LogsCommand on Linux, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("RKE2 commands require Linux")

    if lines < 1:
        return Failure("Lines must be at least 1")

    return Success(RKE2LogsCommand(lines=lines))


def dns_check_command() -> Result[DNSCheckCommand, str]:
    """Create a DNSCheckCommand.

    Returns:
        Success with DNSCheckCommand
    """
    return Success(DNSCheckCommand())


def dns_update_command(
    *,
    force: bool = False,
) -> Result[DNSUpdateCommand, str]:
    """Create a DNSUpdateCommand.

    Args:
        force: Force update even if IP unchanged

    Returns:
        Success with DNSUpdateCommand
    """
    return Success(DNSUpdateCommand(force=force))


def dns_ensure_timer_command(
    *,
    interval: int = 5,
) -> Result[DNSEnsureTimerCommand, str]:
    """Create a DNSEnsureTimerCommand.

    PLATFORM-AWARE: Returns Failure on non-Linux platforms (requires systemd).

    Args:
        interval: Update interval in minutes

    Returns:
        Success with DNSEnsureTimerCommand on Linux, Failure otherwise
    """
    if platform.system() != "Linux":
        return Failure("DDNS timer requires Linux (systemd)")

    if interval < 1:
        return Failure("Interval must be at least 1 minute")

    return Success(DNSEnsureTimerCommand(interval=interval))


def k8s_health_command() -> Result[K8sHealthCommand, str]:
    """Create a K8sHealthCommand.

    Returns:
        Success with K8sHealthCommand
    """
    return Success(K8sHealthCommand())


def k8s_wait_command(
    *,
    timeout: int = 300,
    namespaces: list[str] | None = None,
) -> Result[K8sWaitCommand, str]:
    """Create a K8sWaitCommand.

    Args:
        timeout: Timeout in seconds
        namespaces: Namespaces to wait for

    Returns:
        Success with K8sWaitCommand, Failure if invalid args
    """
    if timeout < 1:
        return Failure("Timeout must be at least 1 second")

    ns = tuple(namespaces) if namespaces else ("metallb-system", "traefik-system", "cert-manager")

    return Success(K8sWaitCommand(timeout=timeout, namespaces=ns))


def k8s_logs_command(
    *,
    namespaces: list[str] | None = None,
    tail: int = 10,
) -> Result[K8sLogsCommand, str]:
    """Create a K8sLogsCommand.

    Args:
        namespaces: Namespaces to get logs from
        tail: Number of log lines per container

    Returns:
        Success with K8sLogsCommand, Failure if invalid args
    """
    if tail < 1:
        return Failure("Tail must be at least 1")

    ns = tuple(namespaces) if namespaces else ("metallb-system", "traefik-system", "cert-manager")

    return Success(K8sLogsCommand(namespaces=ns, tail=tail))


def pulumi_preview_command(
    *,
    stack: str | None = None,
    cwd: Path | None = None,
) -> Result[PulumiPreviewCommand, str]:
    """Create a PulumiPreviewCommand.

    Args:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi

    Returns:
        Success with PulumiPreviewCommand
    """
    return Success(PulumiPreviewCommand(stack=stack, cwd=cwd))


def pulumi_up_command(
    *,
    stack: str | None = None,
    cwd: Path | None = None,
    yes: bool = True,
) -> Result[PulumiUpCommand, str]:
    """Create a PulumiUpCommand.

    Args:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi
        yes: Skip confirmation prompt

    Returns:
        Success with PulumiUpCommand
    """
    return Success(PulumiUpCommand(stack=stack, cwd=cwd, yes=yes))


def pulumi_destroy_command(
    *,
    stack: str | None = None,
    cwd: Path | None = None,
    yes: bool = False,
) -> Result[PulumiDestroyCommand, str]:
    """Create a PulumiDestroyCommand.

    Args:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi
        yes: Skip confirmation prompt

    Returns:
        Success with PulumiDestroyCommand
    """
    return Success(PulumiDestroyCommand(stack=stack, cwd=cwd, yes=yes))


def pulumi_refresh_command(
    *,
    stack: str | None = None,
    cwd: Path | None = None,
) -> Result[PulumiRefreshCommand, str]:
    """Create a PulumiRefreshCommand.

    Args:
        stack: Pulumi stack name
        cwd: Working directory for Pulumi

    Returns:
        Success with PulumiRefreshCommand
    """
    return Success(PulumiRefreshCommand(stack=stack, cwd=cwd))


def pulumi_stack_init_command(
    stack: str,
    *,
    cwd: Path | None = None,
) -> Result[PulumiStackInitCommand, str]:
    """Create a PulumiStackInitCommand.

    Args:
        stack: Stack name to create
        cwd: Working directory for Pulumi

    Returns:
        Success with PulumiStackInitCommand, Failure if invalid stack name
    """
    if not stack or not stack.strip():
        return Failure("Stack name is required")

    # Validate stack name format (alphanumeric, hyphens, underscores)
    import re

    if not re.match(r"^[a-zA-Z0-9_-]+$", stack):
        return Failure(
            f"Invalid stack name: {stack}. Must contain only alphanumeric characters, "
            "hyphens, and underscores"
        )

    return Success(PulumiStackInitCommand(stack=stack, cwd=cwd))


# =============================================================================
# Utility Functions
# =============================================================================


def gateway_start_command(
    *,
    config_path: Path,
) -> Result[GatewayStartCommand, str]:
    """Create a GatewayStartCommand.

    Args:
        config_path: Path to gateway daemon config file

    Returns:
        Success with GatewayStartCommand, Failure if config file missing
    """
    if not config_path.exists():
        return Failure(f"Gateway config file not found: {config_path}")

    return Success(GatewayStartCommand(config_path=config_path))


def gateway_status_command(
    *,
    config_path: Path,
) -> Result[GatewayStatusCommand, str]:
    """Create a GatewayStatusCommand.

    Args:
        config_path: Path to gateway daemon config file

    Returns:
        Success with GatewayStatusCommand, Failure if config file missing
    """
    if not config_path.exists():
        return Failure(f"Gateway config file not found: {config_path}")

    return Success(GatewayStatusCommand(config_path=config_path))


def gateway_config_gen_command(
    *,
    output_path: Path,
    node_id: str,
) -> Result[GatewayConfigGenCommand, str]:
    """Create a GatewayConfigGenCommand.

    Args:
        output_path: Path to write template config
        node_id: Node ID for the generated config

    Returns:
        Success with GatewayConfigGenCommand, Failure if invalid args
    """
    if not node_id or not node_id.strip():
        return Failure("Node ID is required")

    return Success(GatewayConfigGenCommand(output_path=output_path, node_id=node_id))


def is_linux() -> bool:
    """Check if running on Linux.

    Returns:
        True if on Linux, False otherwise
    """
    return platform.system() == "Linux"


def requires_linux(command: Command) -> bool:
    """Check if a command requires Linux.

    Args:
        command: Command to check

    Returns:
        True if the command can only run on Linux
    """
    match command:
        # RKE2 commands require Linux (systemd)
        case RKE2StatusCommand() | RKE2StartCommand() | RKE2StopCommand():
            return True
        case RKE2RestartCommand() | RKE2EnsureCommand() | RKE2CleanupCommand() | RKE2LogsCommand():
            return True
        # DNS timer requires Linux (systemd)
        case DNSEnsureTimerCommand():
            return True
        # Environment commands - cross-platform
        case EnvShowCommand() | EnvValidateCommand() | EnvTemplateCommand():
            return False
        # Host commands - cross-platform (will fail gracefully on non-Linux)
        case (
            HostInfoCommand()
            | HostCheckPortsCommand()
            | HostEnsureToolsCommand()
            | HostFirewallCommand()
        ):
            return False
        # DNS check/update - cross-platform (AWS API)
        case DNSCheckCommand() | DNSUpdateCommand():
            return False
        # Kubernetes commands - cross-platform
        case K8sHealthCommand() | K8sWaitCommand() | K8sLogsCommand():
            return False
        # Pulumi commands - cross-platform
        case PulumiPreviewCommand() | PulumiUpCommand() | PulumiDestroyCommand():
            return False
        case PulumiRefreshCommand() | PulumiStackInitCommand():
            return False
        # Gateway commands - cross-platform
        case GatewayStartCommand() | GatewayStatusCommand() | GatewayConfigGenCommand():
            return False


def requires_settings(command: Command) -> bool:
    """Check if a command requires settings to be loaded.

    Args:
        command: Command to check

    Returns:
        True if the command requires prodbox settings
    """
    match command:
        # DNS commands require AWS settings
        case DNSCheckCommand() | DNSUpdateCommand() | DNSEnsureTimerCommand():
            return True
        # Kubernetes commands require kubeconfig path
        case K8sHealthCommand() | K8sWaitCommand() | K8sLogsCommand():
            return True
        # Pulumi commands require stack and AWS settings
        case PulumiPreviewCommand() | PulumiUpCommand() | PulumiDestroyCommand():
            return True
        case PulumiRefreshCommand() | PulumiStackInitCommand():
            return True
        # Environment commands - env validate/show inspect settings, template doesn't
        case EnvShowCommand() | EnvValidateCommand():
            return True
        case EnvTemplateCommand():
            return False
        # Host commands don't require settings
        case (
            HostInfoCommand()
            | HostCheckPortsCommand()
            | HostEnsureToolsCommand()
            | HostFirewallCommand()
        ):
            return False
        # RKE2 commands don't require prodbox settings (use system paths)
        case RKE2StatusCommand() | RKE2StartCommand() | RKE2StopCommand():
            return False
        case RKE2RestartCommand() | RKE2EnsureCommand() | RKE2CleanupCommand() | RKE2LogsCommand():
            return False
        # Gateway commands don't require prodbox settings (use own config file)
        case GatewayStartCommand() | GatewayStatusCommand() | GatewayConfigGenCommand():
            return False


# =============================================================================
# Exports
# =============================================================================

__all__ = [
    # Command types
    "Command",
    # Environment
    "EnvShowCommand",
    "EnvValidateCommand",
    "EnvTemplateCommand",
    # Host
    "HostInfoCommand",
    "HostCheckPortsCommand",
    "HostEnsureToolsCommand",
    "HostFirewallCommand",
    # RKE2
    "RKE2StatusCommand",
    "RKE2StartCommand",
    "RKE2StopCommand",
    "RKE2RestartCommand",
    "RKE2EnsureCommand",
    "RKE2CleanupCommand",
    "RKE2LogsCommand",
    # DNS
    "DNSCheckCommand",
    "DNSUpdateCommand",
    "DNSEnsureTimerCommand",
    # Kubernetes
    "K8sHealthCommand",
    "K8sWaitCommand",
    "K8sLogsCommand",
    # Pulumi
    "PulumiPreviewCommand",
    "PulumiUpCommand",
    "PulumiDestroyCommand",
    "PulumiRefreshCommand",
    "PulumiStackInitCommand",
    # Gateway
    "GatewayStartCommand",
    "GatewayStatusCommand",
    "GatewayConfigGenCommand",
    # Smart constructors
    "env_show_command",
    "env_validate_command",
    "env_template_command",
    "host_info_command",
    "host_check_ports_command",
    "host_ensure_tools_command",
    "host_firewall_command",
    "rke2_status_command",
    "rke2_start_command",
    "rke2_stop_command",
    "rke2_restart_command",
    "rke2_ensure_command",
    "rke2_cleanup_command",
    "rke2_logs_command",
    "dns_check_command",
    "dns_update_command",
    "dns_ensure_timer_command",
    "k8s_health_command",
    "k8s_wait_command",
    "k8s_logs_command",
    "pulumi_preview_command",
    "pulumi_up_command",
    "pulumi_destroy_command",
    "pulumi_refresh_command",
    "pulumi_stack_init_command",
    "gateway_start_command",
    "gateway_status_command",
    "gateway_config_gen_command",
    # Utility functions
    "is_linux",
    "requires_linux",
    "requires_settings",
]
