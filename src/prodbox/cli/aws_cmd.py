"""AWS fixture management commands for the prodbox CLI."""

from __future__ import annotations

import os
import subprocess
import sys
from dataclasses import dataclass

import click
from rich.console import Console

from prodbox.lib.lint.poetry_entrypoint_guard import ALLOW_NON_ENTRYPOINT_ENV


@dataclass(frozen=True)
class _SweepResult:
    """Typed representation of janitor sweep output."""

    deleted_hosted_zones: int
    deleted_buckets: int
    deleted_vpcs: int
    deleted_eks_clusters: int
    deleted_iam_roles: int


def _sweep_subprocess_env() -> dict[str, str]:
    """Build the minimal env needed for the sweep helper subprocess."""
    env: dict[str, str] = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", ""),
        ALLOW_NON_ENTRYPOINT_ENV: "1",
    }
    match os.environ.get("VIRTUAL_ENV"):
        case str() as virtual_env:
            env["VIRTUAL_ENV"] = virtual_env
        case _:
            pass
    return env


def _run_sweep() -> _SweepResult:
    """Run the fixture sweep subprocess and parse the structured output."""
    completed = subprocess.run(
        [sys.executable, "-m", "tests.integration.sweep_runner"],
        capture_output=True,
        text=True,
        check=False,
        env=_sweep_subprocess_env(),
    )
    match completed.returncode:
        case 0:
            return _parse_sweep_output(completed.stdout)
        case _:
            stderr_text = completed.stderr.strip() or completed.stdout.strip()
            raise RuntimeError(f"sweep subprocess failed: {stderr_text}")


def _parse_sweep_output(stdout: str) -> _SweepResult:
    """Parse line-oriented janitor output into typed counts."""
    payload = {
        key: value
        for key, value in (_parse_output_line(raw_line) for raw_line in stdout.splitlines())
        if key != ""
    }
    return _SweepResult(
        deleted_hosted_zones=_require_int_field(payload, "deleted_hosted_zones"),
        deleted_buckets=_require_int_field(payload, "deleted_buckets"),
        deleted_vpcs=_require_int_field(payload, "deleted_vpcs"),
        deleted_eks_clusters=_require_int_field(payload, "deleted_eks_clusters"),
        deleted_iam_roles=_require_int_field(payload, "deleted_iam_roles"),
    )


def _parse_output_line(raw_line: str) -> tuple[str, int]:
    """Parse one line from janitor subprocess output."""
    line = raw_line.strip()
    match line:
        case "":
            return ("", 0)
        case _:
            key, separator, value_text = line.partition("=")
            match separator:
                case "=":
                    return (key, _parse_output_int(value_text=value_text, field_name=key))
                case _:
                    raise RuntimeError(f"sweep subprocess returned invalid line: {line}")


def _parse_output_int(*, value_text: str, field_name: str) -> int:
    """Parse one integer field from janitor subprocess output."""
    stripped = value_text.strip()
    match stripped.isdigit():
        case True:
            return int(stripped)
        case False:
            raise RuntimeError(f"sweep subprocess returned invalid integer for {field_name}")


def _require_int_field(payload: dict[str, int], key: str) -> int:
    """Return one integer field from the parsed sweep payload."""
    match payload.get(key):
        case int() as int_value:
            return int_value
        case _:
            raise RuntimeError(f"sweep subprocess omitted required field: {key}")


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
    return None
