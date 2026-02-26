"""Environment and configuration commands."""

from __future__ import annotations

import sys

import click

from prodbox.cli.command_adt import (
    env_show_command,
    env_template_command,
    env_validate_command,
)
from prodbox.cli.command_executor import execute_command, render_error_and_return_exit_code
from prodbox.cli.types import Failure, Success


@click.group()
def env() -> None:
    """Environment and configuration commands."""


@env.command()
@click.option(
    "--show-secrets",
    is_flag=True,
    help="Show full secret values (use with caution)",
)
def show(show_secrets: bool) -> None:
    """Display current configuration.

    Shows all settings loaded from environment variables
    with sensitive values masked by default.
    """
    match env_show_command(show_secrets=show_secrets):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="env_show"))


@env.command()
def validate() -> None:
    """Validate configuration without showing values.

    Checks that all required environment variables are set
    and values are valid according to the schema.
    """
    match env_validate_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="env_validate"))


@env.command()
def template() -> None:
    """Print a template .env file with all settings.

    Useful for creating a new .env file with all available options.
    """
    match env_template_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="env_template"))
