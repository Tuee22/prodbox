"""Pulumi infrastructure commands."""

from __future__ import annotations

import sys

import click

from prodbox.cli.command_adt import (
    pulumi_destroy_command,
    pulumi_preview_command,
    pulumi_refresh_command,
    pulumi_stack_init_command,
    pulumi_up_command,
)
from prodbox.cli.command_executor import execute_command, render_error_and_return_exit_code
from prodbox.cli.types import Failure, Success


@click.group(no_args_is_help=True)
def pulumi() -> None:
    """Pulumi infrastructure commands."""


@pulumi.command()
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation prompts")
def up(yes: bool) -> None:
    """Apply infrastructure changes.

    Deploys MetalLB, Traefik, cert-manager, and Route 53 DNS.
    """
    match pulumi_up_command(yes=yes):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="pulumi_up"))


@pulumi.command()
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation prompts")
def destroy(yes: bool) -> None:
    """Destroy infrastructure.

    Removes all managed resources including MetalLB, Traefik,
    cert-manager, and Route 53 DNS records.
    """
    match pulumi_destroy_command(yes=yes):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="pulumi_destroy"))


@pulumi.command()
def preview() -> None:
    """Preview infrastructure changes.

    Shows what changes would be made without applying them.
    """
    match pulumi_preview_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="pulumi_preview"))


@pulumi.command()
def refresh() -> None:
    """Refresh Pulumi state.

    Synchronizes state with the actual cloud resources.
    """
    match pulumi_refresh_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="pulumi_refresh"))


@pulumi.command("stack-init")
@click.argument("stack")
def stack_init(stack: str) -> None:
    """Initialize a new Pulumi stack.

    Creates the stack if it doesn't exist.
    """
    match pulumi_stack_init_command(stack):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="pulumi_stack_init"))
