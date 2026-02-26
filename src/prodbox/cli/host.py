"""Host prerequisite management commands."""

from __future__ import annotations

import sys

import click

from prodbox.cli.command_adt import (
    host_check_ports_command,
    host_ensure_tools_command,
    host_firewall_command,
    host_info_command,
)
from prodbox.cli.command_executor import execute_command, render_error_and_return_exit_code
from prodbox.cli.types import Failure, Success


@click.group()
def host() -> None:
    """Host prerequisite management commands."""


@host.command("ensure-tools")
def ensure_tools() -> None:
    """Check that required CLI tools are installed.

    Verifies that kubectl, helm, and pulumi are available
    in the system PATH.
    """
    match host_ensure_tools_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="host_ensure_tools"))


@host.command("check-ports")
def check_ports() -> None:
    """Check if ports 80/443 are in use.

    Verifies that no other services are binding to ports
    80 and 443, which are required for ingress.
    """
    match host_check_ports_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="host_check_ports"))


@host.command("info")
def info() -> None:
    """Display host system information.

    Shows OS, kernel, and resource information useful
    for troubleshooting.
    """
    match host_info_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="host_info"))


@host.command("firewall")
def firewall() -> None:
    """Check and display firewall status.

    Shows current firewall rules relevant to Kubernetes
    and ingress traffic.
    """
    match host_firewall_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="host_firewall"))
