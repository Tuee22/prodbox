"""Pulumi infrastructure commands."""

from __future__ import annotations

import os
from pathlib import Path

import click

from prodbox.cli.main import SettingsContext, pass_settings
from prodbox.lib.async_runner import async_command
from prodbox.lib.logging import print_error, print_info, print_success
from prodbox.lib.subprocess import run_command


def get_project_root() -> Path:
    """Get the prodbox project root directory."""
    # Look for pyproject.toml or Pulumi.yaml
    current = Path(__file__).resolve()
    for parent in current.parents:
        if (parent / "Pulumi.yaml").exists() or (parent / "pyproject.toml").exists():
            return parent
    # Fall back to cwd
    return Path.cwd()


def get_pulumi_env(ctx: SettingsContext) -> dict[str, str]:
    """Build environment variables for Pulumi."""
    settings = ctx.settings
    return {
        "AWS_ACCESS_KEY_ID": settings.aws_access_key_id,
        "AWS_SECRET_ACCESS_KEY": settings.aws_secret_access_key,
        "AWS_REGION": settings.aws_region,
        "KUBECONFIG": str(settings.kubeconfig),
        "ROUTE53_ZONE_ID": settings.route53_zone_id,
        "ACME_EMAIL": settings.acme_email,
        "DEMO_FQDN": settings.demo_fqdn,
        "METALLB_POOL": settings.metallb_pool,
        "INGRESS_LB_IP": settings.ingress_lb_ip,
        "ACME_SERVER": settings.acme_server,
    }


@click.group()
def pulumi() -> None:
    """Pulumi infrastructure commands."""
    pass


@pulumi.command()
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation prompts")
@click.option("--refresh", is_flag=True, help="Refresh state before applying")
@pass_settings
@async_command
async def up(ctx: SettingsContext, yes: bool, refresh: bool) -> None:
    """Apply infrastructure changes.

    Deploys MetalLB, Traefik, cert-manager, and Route 53 DNS.
    """
    if ctx is None:
        print_error("Configuration not loaded. Run 'prodbox env validate' first.")
        raise SystemExit(1)

    project_root = get_project_root()
    stack = ctx.settings.pulumi_stack

    print_info(f"Running pulumi up for stack '{stack}'...")

    cmd = ["pulumi", "up", "--stack", stack]
    if yes:
        cmd.append("--yes")
    if refresh:
        cmd.append("--refresh")

    try:
        result = await run_command(
            cmd,
            env=get_pulumi_env(ctx),
            cwd=str(project_root),
            capture=False,  # Stream output to terminal
            check=True,
        )
        print_success("Infrastructure deployed successfully!")
    except Exception as e:
        print_error(f"Pulumi up failed: {e}")
        raise SystemExit(1)


@pulumi.command()
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation prompts")
@click.option("--refresh", is_flag=True, help="Refresh state before destroying")
@pass_settings
@async_command
async def destroy(ctx: SettingsContext, yes: bool, refresh: bool) -> None:
    """Destroy infrastructure.

    Removes all managed resources including MetalLB, Traefik,
    cert-manager, and Route 53 DNS records.
    """
    if ctx is None:
        print_error("Configuration not loaded. Run 'prodbox env validate' first.")
        raise SystemExit(1)

    project_root = get_project_root()
    stack = ctx.settings.pulumi_stack

    if not yes:
        click.confirm(
            f"This will destroy all infrastructure in stack '{stack}'. Continue?",
            abort=True,
        )

    print_info(f"Running pulumi destroy for stack '{stack}'...")

    cmd = ["pulumi", "destroy", "--stack", stack]
    if yes:
        cmd.append("--yes")
    if refresh:
        cmd.append("--refresh")

    try:
        result = await run_command(
            cmd,
            env=get_pulumi_env(ctx),
            cwd=str(project_root),
            capture=False,
            check=True,
        )
        print_success("Infrastructure destroyed successfully!")
    except Exception as e:
        print_error(f"Pulumi destroy failed: {e}")
        raise SystemExit(1)


@pulumi.command()
@click.option("--refresh", is_flag=True, help="Refresh state before preview")
@pass_settings
@async_command
async def preview(ctx: SettingsContext, refresh: bool) -> None:
    """Preview infrastructure changes.

    Shows what changes would be made without applying them.
    """
    if ctx is None:
        print_error("Configuration not loaded. Run 'prodbox env validate' first.")
        raise SystemExit(1)

    project_root = get_project_root()
    stack = ctx.settings.pulumi_stack

    print_info(f"Running pulumi preview for stack '{stack}'...")

    cmd = ["pulumi", "preview", "--stack", stack]
    if refresh:
        cmd.append("--refresh")

    try:
        result = await run_command(
            cmd,
            env=get_pulumi_env(ctx),
            cwd=str(project_root),
            capture=False,
            check=True,
        )
    except Exception as e:
        print_error(f"Pulumi preview failed: {e}")
        raise SystemExit(1)


@pulumi.command()
@pass_settings
@async_command
async def refresh(ctx: SettingsContext) -> None:
    """Refresh Pulumi state.

    Synchronizes state with the actual cloud resources.
    """
    if ctx is None:
        print_error("Configuration not loaded. Run 'prodbox env validate' first.")
        raise SystemExit(1)

    project_root = get_project_root()
    stack = ctx.settings.pulumi_stack

    print_info(f"Refreshing pulumi state for stack '{stack}'...")

    cmd = ["pulumi", "refresh", "--stack", stack, "--yes"]

    try:
        result = await run_command(
            cmd,
            env=get_pulumi_env(ctx),
            cwd=str(project_root),
            capture=False,
            check=True,
        )
        print_success("State refreshed successfully!")
    except Exception as e:
        print_error(f"Pulumi refresh failed: {e}")
        raise SystemExit(1)


@pulumi.command()
@pass_settings
@async_command
async def stack_init(ctx: SettingsContext) -> None:
    """Initialize the Pulumi stack.

    Creates the stack if it doesn't exist.
    """
    if ctx is None:
        print_error("Configuration not loaded. Run 'prodbox env validate' first.")
        raise SystemExit(1)

    project_root = get_project_root()
    stack = ctx.settings.pulumi_stack

    print_info(f"Initializing pulumi stack '{stack}'...")

    cmd = ["pulumi", "stack", "init", stack]

    try:
        result = await run_command(
            cmd,
            env=get_pulumi_env(ctx),
            cwd=str(project_root),
            capture=True,
            check=False,  # Don't fail if stack exists
        )
        if result.success:
            print_success(f"Stack '{stack}' created successfully!")
        elif "already exists" in result.stderr:
            print_info(f"Stack '{stack}' already exists.")
        else:
            print_error(f"Failed to create stack: {result.stderr}")
            raise SystemExit(1)
    except Exception as e:
        print_error(f"Pulumi stack init failed: {e}")
        raise SystemExit(1)
