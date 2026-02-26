"""DNS and DDNS management commands."""

from __future__ import annotations

import sys

import click

from prodbox.cli.command_adt import (
    dns_check_command,
    dns_ensure_timer_command,
    dns_update_command,
)
from prodbox.cli.command_executor import execute_command, render_error_and_return_exit_code
from prodbox.cli.types import Failure, Success


@click.group()
def dns() -> None:
    """DNS and DDNS management commands."""


@dns.command()
@click.option("--force", "-f", is_flag=True, help="Force update even if IP unchanged")
def update(force: bool) -> None:
    """Update Route 53 DNS with current public IP.

    Checks if the public IP has changed and updates the A record
    if necessary. Use --force to update regardless of current value.
    """
    match dns_update_command(force=force):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="dns_update"))


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


@dns.command("ensure-timer")
@click.option(
    "--interval",
    default=5,
    type=int,
    help="Update interval in minutes (default: 5)",
)
def ensure_timer(interval: int) -> None:
    """Install systemd timer for automatic DDNS updates.

    Creates and enables a systemd timer that runs 'prodbox dns update'
    at the specified interval.
    """
    match dns_ensure_timer_command(interval=interval):
        case Success(cmd):
            sys.exit(execute_command(cmd))
        case Failure(error):
            sys.exit(render_error_and_return_exit_code(error, effect_id="dns_ensure_timer"))
