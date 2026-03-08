"""Main CLI entry point for prodbox."""

from __future__ import annotations

import click

from prodbox.cli import check_code, dns, env, gateway, host, k8s, pulumi_cmd, rke2, test_cmd, tla
from prodbox.lib.logging import setup_logging


@click.group()
@click.option(
    "--verbose",
    "-v",
    is_flag=True,
    help="Enable verbose output",
)
@click.version_option(package_name="prodbox")
def cli(verbose: bool) -> None:
    """prodbox - Home Kubernetes cluster management.

    Manage RKE2 + MetalLB + Traefik + cert-manager + Route 53
    with declarative, idempotent commands.

    \b
    Configuration is loaded from environment variables.
    See 'prodbox env show' for current configuration.
    """
    # Configure logging based on verbosity
    setup_logging(level="DEBUG" if verbose else "INFO")


# Register command groups
cli.add_command(env.env)
cli.add_command(host.host)
cli.add_command(rke2.rke2)
cli.add_command(pulumi_cmd.pulumi)
cli.add_command(dns.dns)
cli.add_command(k8s.k8s)
cli.add_command(gateway.gateway)
cli.add_command(check_code.check_code)
cli.add_command(tla.tla_check_cmd)
cli.add_command(test_cmd.run_tests_cmd)


def main() -> None:
    """Entry point for the CLI."""
    cli()


if __name__ == "__main__":
    main()
