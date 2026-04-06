"""DNS inspection commands."""

from __future__ import annotations

import sys

import click

from prodbox.cli.command_adt import dns_check_command
from prodbox.cli.command_executor import execute_command, render_error_and_return_exit_code
from prodbox.cli.types import Failure, Success


@click.group(no_args_is_help=True)
def dns() -> None:
    """DNS inspection commands."""


@dns.command()
def check() -> None:
    """Check current DNS record and public IP.

    Displays the current public IP and Route 53 A record
    without making any changes.
    """
    match dns_check_command():
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="dns_check"))
