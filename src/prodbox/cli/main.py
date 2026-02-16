"""Main CLI entry point for prodbox."""

from __future__ import annotations

import click

from prodbox.lib.logging import setup_logging
from prodbox.settings import Settings, get_settings

from prodbox.cli import dns, env, host, k8s, pulumi_cmd, rke2


class SettingsContext:
    """Click context object holding settings."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings


pass_settings = click.make_pass_decorator(SettingsContext, ensure=True)


@click.group()
@click.option(
    "--verbose",
    "-v",
    is_flag=True,
    help="Enable verbose output",
)
@click.version_option(package_name="prodbox")
@click.pass_context
def cli(ctx: click.Context, verbose: bool) -> None:
    """prodbox - Home Kubernetes cluster management.

    Manage RKE2 + MetalLB + Traefik + cert-manager + Route 53
    with declarative, idempotent commands.

    \b
    Configuration is loaded from environment variables.
    See 'prodbox env show' for current configuration.
    """
    # Configure logging based on verbosity
    setup_logging(level="DEBUG" if verbose else "INFO")

    # Initialize settings on every invocation
    try:
        settings = get_settings()
        ctx.obj = SettingsContext(settings)
    except Exception as e:
        # Allow commands that don't need settings to still work
        if verbose:
            click.echo(f"Warning: Could not load settings: {e}", err=True)
        ctx.obj = None


# Register command groups
cli.add_command(env.env)
cli.add_command(host.host)
cli.add_command(rke2.rke2)
cli.add_command(pulumi_cmd.pulumi)
cli.add_command(dns.dns)
cli.add_command(k8s.k8s)


def main() -> None:
    """Entry point for the CLI."""
    cli()


if __name__ == "__main__":
    main()
