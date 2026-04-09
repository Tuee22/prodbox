"""AWS fixture management commands for the prodbox CLI."""

from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import dataclass

import click
from rich.console import Console


@dataclass(frozen=True)
class _SweepResult:
    """Typed representation of janitor sweep output."""

    deleted_hosted_zones: int
    deleted_buckets: int
    deleted_vpcs: int
    deleted_eks_clusters: int
    deleted_iam_roles: int


def _run_sweep() -> _SweepResult:
    """Run the fixture sweep subprocess and parse the JSON result."""
    completed = subprocess.run(
        [sys.executable, "-m", "tests.integration.sweep_runner"],
        capture_output=True,
        text=True,
        check=False,
    )
    match completed.returncode:
        case 0:
            pass
        case _:
            stderr_text = completed.stderr.strip() or completed.stdout.strip()
            raise RuntimeError(f"sweep subprocess failed: {stderr_text}")
    raw: dict[str, int] = json.loads(completed.stdout.strip())
    return _SweepResult(
        deleted_hosted_zones=raw["deleted_hosted_zones"],
        deleted_buckets=raw["deleted_buckets"],
        deleted_vpcs=raw["deleted_vpcs"],
        deleted_eks_clusters=raw["deleted_eks_clusters"],
        deleted_iam_roles=raw["deleted_iam_roles"],
    )


@click.group("aws", no_args_is_help=True)
def aws() -> None:
    """AWS fixture management."""


def _render_resource_line(console: Console, count: int, label: str) -> None:
    """Print one resource-count line when count is non-zero."""
    match count:
        case 0:
            pass
        case _:
            console.print(f"  {label}: {count}")


@aws.command("sweep-fixtures")
def sweep_fixtures() -> None:
    """Delete expired fixture-owned AWS resources from prior test crashes."""
    console = Console()
    console.print("[bold]Running AWS fixture sweep...[/bold]")
    result = _run_sweep()
    total = (
        result.deleted_hosted_zones
        + result.deleted_buckets
        + result.deleted_vpcs
        + result.deleted_eks_clusters
        + result.deleted_iam_roles
    )
    match total:
        case 0:
            console.print("[green]No expired fixture resources found.[/green]")
        case _:
            console.print(f"[yellow]Deleted {total} expired fixture resource(s):[/yellow]")
            _render_resource_line(console, result.deleted_eks_clusters, "EKS clusters")
            _render_resource_line(console, result.deleted_iam_roles, "IAM roles")
            _render_resource_line(console, result.deleted_hosted_zones, "Route 53 hosted zones")
            _render_resource_line(console, result.deleted_buckets, "S3 buckets")
            _render_resource_line(console, result.deleted_vpcs, "VPCs")
    sys.exit(0)
