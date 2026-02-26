"""Kubernetes health check and utility commands."""

from __future__ import annotations

import sys

import click

from prodbox.cli.command_adt import (
    k8s_health_command,
    k8s_logs_command,
    k8s_wait_command,
)
from prodbox.cli.command_executor import execute_command, render_error_and_return_exit_code
from prodbox.cli.types import Failure, Success


@click.group()
def k8s() -> None:
    """Kubernetes health and utility commands."""


@k8s.command()
def health() -> None:
    """Check health of Kubernetes cluster and components.

    Verifies connectivity and checks the status of key
    infrastructure components (MetalLB, Traefik, cert-manager).
    """
    match k8s_health_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="k8s_health"))


@k8s.command()
@click.option(
    "--timeout",
    "-t",
    default=300,
    type=int,
    help="Timeout in seconds (default: 300)",
)
@click.option(
    "--namespace",
    "-n",
    multiple=True,
    default=["metallb-system", "traefik-system", "cert-manager"],
    help="Namespaces to wait for (can specify multiple)",
)
def wait(timeout: int, namespace: tuple[str, ...]) -> None:
    """Wait for deployments to be ready.

    Blocks until all deployments in the specified namespaces
    are ready or timeout is reached.
    """
    match k8s_wait_command(timeout=timeout, namespaces=list(namespace)):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="k8s_wait"))


@k8s.command()
@click.option(
    "--namespace",
    "-n",
    multiple=True,
    default=["metallb-system", "traefik-system", "cert-manager"],
    help="Namespaces to get logs from (can specify multiple)",
)
@click.option(
    "--tail",
    default=10,
    type=int,
    help="Number of log lines per container (default: 10)",
)
def logs(namespace: tuple[str, ...], tail: int) -> None:
    """Show recent logs from infrastructure pods.

    Displays the last few log lines from key infrastructure
    components for debugging.
    """
    match k8s_logs_command(namespaces=list(namespace), tail=tail):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="k8s_logs"))
