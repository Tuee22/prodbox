"""Gateway daemon management commands."""

from __future__ import annotations

import sys
from pathlib import Path

import click

from prodbox.cli.command_adt import (
    gateway_config_gen_command,
    gateway_start_command,
    gateway_status_command,
)
from prodbox.cli.command_executor import execute_command, render_error_and_return_exit_code
from prodbox.cli.types import Failure, Success


@click.group(no_args_is_help=True)
def gateway() -> None:
    """Gateway daemon management."""


@gateway.command()
@click.argument("config_path", type=click.Path(exists=True))
def start(config_path: str) -> None:
    """Start gateway daemon from config file.

    Loads the daemon configuration and runs the gateway event loop
    until interrupted.
    """
    match gateway_start_command(config_path=Path(config_path)):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="gateway_start"))


@gateway.command()
@click.argument("config_path", type=click.Path(exists=True))
def status(config_path: str) -> None:
    """Query running gateway daemon status.

    Connects to the daemon's REST API and displays current state
    including gateway owner, event count, and mesh peers.
    """
    match gateway_status_command(config_path=Path(config_path)):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="gateway_status"))


@gateway.command("config-gen")
@click.argument("output_path")
@click.option("--node-id", required=True, help="Node ID for the generated config")
def config_gen(output_path: str, node_id: str) -> None:
    """Generate template gateway config file.

    Creates a JSON config template at OUTPUT_PATH with placeholder
    values that should be filled in before use.
    """
    match gateway_config_gen_command(output_path=Path(output_path), node_id=node_id):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="gateway_config_gen"))
