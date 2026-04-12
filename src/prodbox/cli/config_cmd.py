"""Configuration management commands."""

from __future__ import annotations

import sys

import click

from prodbox.cli.command_adt import (
    config_compile_command,
    config_init_command,
    config_show_command,
    config_validate_command,
)
from prodbox.cli.command_executor import execute_command, render_error_and_return_exit_code
from prodbox.cli.types import Failure, Success


@click.group(no_args_is_help=True)
def config() -> None:
    """Configuration management commands.

    Manage the Dhall-sourced prodbox configuration file.
    """


@config.command(name="init")
def init_config() -> None:
    """Bootstrap prodbox-config.dhall from existing .env and system state.

    Generates a Dhall config file, compiles it to JSON, and validates the result.
    This is the last time .env values are used.
    """
    match config_init_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="config_init"))


@config.command(name="compile")
def compile_config() -> None:
    """Compile prodbox-config.dhall to prodbox-config.json.

    Requires dhall-to-json to be installed on the system.
    """
    match config_compile_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="config_compile"))


@config.command()
@click.option(
    "--show-secrets",
    is_flag=True,
    help="Show full secret values (use with caution)",
)
def show(show_secrets: bool) -> None:
    """Display current configuration from the canonical Dhall-backed config.

    Auto-compiles ``prodbox-config.dhall`` to ``prodbox-config.json`` when the
    compiled artifact is missing or stale, then shows effective settings with
    sensitive values masked by default.
    """
    match config_show_command(show_secrets=show_secrets):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="config_show"))


@config.command()
def validate() -> None:
    """Validate the canonical Dhall-backed configuration.

    Auto-compiles ``prodbox-config.dhall`` to ``prodbox-config.json`` when the
    compiled artifact is missing or stale, then validates the effective
    configuration against the schema.
    """
    match config_validate_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="config_validate"))
