"""AWS IAM policy, user-lifecycle, and quota management commands."""

from __future__ import annotations

import sys

import click

from prodbox.cli.command_adt import aws_policy_command
from prodbox.cli.command_executor import execute_command, render_error_and_return_exit_code
from prodbox.cli.types import Failure, Success
from prodbox.lib.aws_admin import (
    interactive_aws_check_quotas_command,
    interactive_aws_request_quotas_command,
    interactive_aws_setup_command,
    interactive_aws_teardown_command,
)


@click.group(no_args_is_help=True)
def aws() -> None:
    """AWS IAM policy, user lifecycle, and quota management commands."""


@aws.command("policy")
@click.option(
    "--tier",
    type=click.Choice(["core", "full"], case_sensitive=False),
    default="core",
    show_default=True,
    help="Operational IAM policy tier to render",
)
def policy(tier: str) -> None:
    """Render the supported operational IAM inline policy JSON."""
    match aws_policy_command(tier=tier):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="aws_policy"))


@aws.command("setup")
@click.option(
    "--tier",
    type=click.Choice(["core", "full"], case_sensitive=False),
    default="full",
    show_default=True,
    help="Operational IAM policy tier to provision",
)
def setup(tier: str) -> None:
    """Create or refresh the supported operational IAM user and baseline quotas."""
    match interactive_aws_setup_command(tier=tier):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="aws_setup"))


@aws.command("teardown")
def teardown() -> None:
    """Delete the supported operational IAM user and clear Dhall credentials."""
    match interactive_aws_teardown_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="aws_teardown"))


@aws.command("check-quotas")
def check_quotas() -> None:
    """Inspect the supported AWS service quotas."""
    match interactive_aws_check_quotas_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="aws_check_quotas"))


@aws.command("request-quotas")
@click.option(
    "--tier",
    type=click.Choice(["core", "full"], case_sensitive=False),
    default="full",
    show_default=True,
    help="Quota target tier to request",
)
def request_quotas(tier: str) -> None:
    """Request supported AWS service quota increases."""
    match interactive_aws_request_quotas_command(tier=tier):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="aws_request_quotas"))
