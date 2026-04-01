"""Bespoke Helm chart lifecycle commands."""

from __future__ import annotations

import sys

import click

from prodbox.cli.command_adt import (
    chart_delete_command,
    chart_deploy_command,
    chart_list_command,
    chart_status_command,
)
from prodbox.cli.command_executor import execute_command, render_error_and_return_exit_code
from prodbox.cli.types import Failure, Success


@click.group(no_args_is_help=True)
def charts() -> None:
    """Bespoke Helm chart lifecycle commands.

    Manage bespoke Helm charts through the prodbox chart platform.
    Charts are deployed namespace-local with deterministic retained storage.

    \b
    See 'prodbox charts list' for available charts.
    """


@charts.command("list")
def chart_list() -> None:
    """List all supported charts with install status.

    Displays the chart registry alongside observed Helm release state
    for each supported chart.
    """
    match chart_list_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="chart_list"))


@charts.command("status")
@click.argument("chart")
def chart_status(chart: str) -> None:
    """Show detailed status for one chart.

    CHART is the name of the chart to inspect (e.g. vscode).
    """
    match chart_status_command(chart):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="chart_status"))


@charts.command("deploy")
@click.argument("chart")
def chart_deploy(chart: str) -> None:
    """Deploy a root chart stack into its namespace.

    CHART is the root chart name (e.g. vscode). All prerequisite charts
    (e.g. keycloak, keycloak-postgres) are deployed into the same namespace
    in dependency order.

    Deployment is idempotent: if the chart is already installed, the
    command will fail with a singleton violation error.
    """
    match chart_deploy_command(chart):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="chart_deploy"))


@charts.command("delete")
@click.argument("chart")
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation prompt")
def chart_delete(chart: str, yes: bool) -> None:
    """Delete a root chart stack (preserves .data storage).

    CHART is the root chart name (e.g. vscode). All releases in the stack
    are deleted in reverse dependency order along with their PV/PVC objects
    and the namespace.

    Host-path data in .data/ is NEVER deleted.
    """
    match chart_delete_command(chart, yes=yes):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="chart_delete"))
