"""Environment and configuration commands."""

from __future__ import annotations

import click
from pydantic import ValidationError
from rich.console import Console
from rich.table import Table

from prodbox.lib.logging import print_error, print_success
from prodbox.settings import Settings, clear_settings_cache

console = Console()


@click.group()
def env() -> None:
    """Environment and configuration commands."""
    pass


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
    clear_settings_cache()

    try:
        settings = Settings()
    except ValidationError as e:
        print_error("Configuration validation failed:")
        for error in e.errors():
            field = ".".join(str(loc) for loc in error["loc"])
            msg = error["msg"]
            click.echo(f"  {field}: {msg}")
        raise SystemExit(1)

    table = Table(title="Prodbox Configuration", show_header=True)
    table.add_column("Setting", style="cyan")
    table.add_column("Value", style="green")
    table.add_column("Source", style="dim")

    if show_secrets:
        data = settings.model_dump()
    else:
        data = settings.display_dict()

    for key, value in data.items():
        # Determine source (env var or default)
        import os

        env_key = key.upper()
        source = "env" if env_key in os.environ else "default"
        table.add_row(key, str(value), source)

    console.print(table)


@env.command()
def validate() -> None:
    """Validate configuration without showing values.

    Checks that all required environment variables are set
    and values are valid according to the schema.
    """
    clear_settings_cache()

    try:
        settings = Settings()
        print_success("Configuration is valid!")

        # Show summary
        click.echo(f"\nKubeconfig: {settings.kubeconfig}")
        click.echo(f"AWS Region: {settings.aws_region}")
        click.echo(f"Demo FQDN: {settings.demo_fqdn}")
        click.echo(f"MetalLB Pool: {settings.metallb_pool}")
        click.echo(f"Ingress LB IP: {settings.ingress_lb_ip}")
        click.echo(f"Pulumi Stack: {settings.pulumi_stack}")

    except ValidationError as e:
        print_error("Configuration validation failed:")
        for error in e.errors():
            field = ".".join(str(loc) for loc in error["loc"])
            msg = error["msg"]
            input_val = error.get("input", "")
            if input_val:
                click.echo(f"  {field}: {msg} (got: {input_val!r})")
            else:
                click.echo(f"  {field}: {msg}")
        raise SystemExit(1)


@env.command()
def template() -> None:
    """Print a template .env file with all settings.

    Useful for creating a new .env file with all available options.
    """
    template_content = """\
# Prodbox Configuration
# Copy this file to .env and fill in the required values

# AWS Credentials (Required)
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_REGION=us-east-1

# Route 53 (Required)
ROUTE53_ZONE_ID=

# ACME / Let's Encrypt (Required)
ACME_EMAIL=

# Domain Configuration
DEMO_FQDN=demo.example.com
DEMO_TTL=60

# MetalLB / Ingress Configuration
METALLB_POOL=192.168.1.240-192.168.1.250
INGRESS_LB_IP=192.168.1.240

# Kubernetes
KUBECONFIG=~/.kube/config

# ACME Server
# Production: https://acme-v02.api.letsencrypt.org/directory
# Staging:    https://acme-staging-v02.api.letsencrypt.org/directory
ACME_SERVER=https://acme-v02.api.letsencrypt.org/directory

# Pulumi
PULUMI_STACK=home
"""
    click.echo(template_content)
