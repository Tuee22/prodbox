"""RKE2 management commands."""

from __future__ import annotations

import sys

import click

from prodbox.cli.command_adt import (
    rke2_cleanup_command,
    rke2_ensure_command,
    rke2_logs_command,
    rke2_restart_command,
    rke2_start_command,
    rke2_status_command,
    rke2_stop_command,
)
from prodbox.cli.command_executor import execute_command, render_error_and_return_exit_code
from prodbox.cli.types import Failure, Success


@click.group(no_args_is_help=True)
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
    """Idempotently provision RKE2 runtime + Harbor + retained-storage MinIO.

    Ensures RKE2 is enabled/started, Harbor is installed in-cluster,
    local registry mirrors are configured, retained local storage is reconciled,
    and MinIO is installed from the official Helm chart.
    """
    match rke2_ensure_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="rke2_ensure"))


@rke2.command()
@click.option(
    "--yes",
    is_flag=True,
    help="Confirm cleanup of prodbox-annotated Kubernetes resources",
)
def cleanup(yes: bool) -> None:
    """Cleanup prodbox resources from Kubernetes without touching host storage.

    Idempotently deletes all Kubernetes objects annotated with the current
    prodbox-id except retained storage kinds (StorageClass/PV/PVC).
    Prints manual instructions for optional host-path deletion.
    """
    match rke2_cleanup_command(yes=yes):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="rke2_cleanup"))


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
