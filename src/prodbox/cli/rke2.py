"""RKE2 management commands."""

from __future__ import annotations

import sys

import click

from prodbox.cli.command_adt import (
    rke2_ensure_command,
    rke2_logs_command,
    rke2_restart_command,
    rke2_start_command,
    rke2_status_command,
    rke2_stop_command,
)
from prodbox.cli.command_executor import execute_command, render_error_and_return_exit_code
from prodbox.cli.types import Failure, Success


@click.group()
def rke2() -> None:
    """RKE2 Kubernetes management commands."""


@rke2.command()
def status() -> None:
    """Check RKE2 installation and service status.

    Shows whether RKE2 is installed, running, and provides
    basic cluster health information.
    """
    match rke2_status_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="rke2_status"))


@rke2.command()
def start() -> None:
    """Start RKE2 server service.

    Starts the RKE2 server systemd service if not running.
    """
    match rke2_start_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="rke2_start"))


@rke2.command()
def stop() -> None:
    """Stop RKE2 server service.

    Stops the RKE2 server systemd service.
    """
    match rke2_stop_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="rke2_stop"))


@rke2.command()
def restart() -> None:
    """Restart RKE2 server service.

    Restarts the RKE2 server systemd service.
    """
    match rke2_restart_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="rke2_restart"))


@rke2.command()
def ensure() -> None:
    """Ensure RKE2 is installed and configured.

    Checks if RKE2 is installed. If not, provides instructions
    for installation. Does not automatically install RKE2.
    """
    match rke2_ensure_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="rke2_ensure"))


@rke2.command()
@click.option(
    "--lines",
    "-n",
    default=50,
    type=int,
    help="Number of log lines to show (default: 50)",
)
def logs(lines: int) -> None:
    """Show recent RKE2 server logs.

    Displays the last N lines of the RKE2 server journal logs.
    """
    match rke2_logs_command(lines=lines):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="rke2_logs"))
