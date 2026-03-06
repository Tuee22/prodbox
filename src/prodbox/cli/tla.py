"""TLA+ proof check command for the prodbox CLI."""

from __future__ import annotations

import click

from prodbox import tla_check


@click.command("tla-check")
def tla_check_cmd() -> None:
    """Run the TLA+ model checker via Docker."""
    config = tla_check.default_config()
    raise SystemExit(tla_check.run_tla_proof_check(config))
