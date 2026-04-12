"""Unit tests for the `prodbox aws` CLI group."""

from __future__ import annotations

import subprocess
from unittest.mock import patch

from click.testing import CliRunner

from prodbox.cli.aws_cmd import (
    _parse_sweep_output,
    _run_sweep,
    _sweep_subprocess_env,
    _SweepResult,
)
from prodbox.cli.main import cli
from prodbox.lib.lint.poetry_entrypoint_guard import ALLOW_NON_ENTRYPOINT_ENV


def test_sweep_subprocess_env_allows_internal_non_entrypoint_python(monkeypatch) -> None:
    """Sweep subprocess env should carry only the required passthrough vars."""
    monkeypatch.setenv("PATH", "/tmp/bin")
    monkeypatch.setenv("HOME", "/tmp/home")
    monkeypatch.setenv("VIRTUAL_ENV", "/tmp/venv")

    env = _sweep_subprocess_env()

    assert env == {
        "PATH": "/tmp/bin",
        "HOME": "/tmp/home",
        "VIRTUAL_ENV": "/tmp/venv",
        ALLOW_NON_ENTRYPOINT_ENV: "1",
    }


def test_parse_sweep_output_reads_line_oriented_counts() -> None:
    """Line-oriented janitor output should map to the typed result structure."""
    result = _parse_sweep_output(
        "\n".join(
            (
                "deleted_hosted_zones=1",
                "deleted_buckets=2",
                "deleted_vpcs=3",
                "deleted_eks_clusters=4",
                "deleted_iam_roles=5",
                "remaining_hosted_zones=0",
                "remaining_buckets=0",
                "remaining_vpcs=0",
                "remaining_eks_clusters=0",
                "remaining_iam_roles=0",
            )
        )
    )

    assert result == _SweepResult(
        deleted_hosted_zones=1,
        deleted_buckets=2,
        deleted_vpcs=3,
        deleted_eks_clusters=4,
        deleted_iam_roles=5,
        remaining_hosted_zones=0,
        remaining_buckets=0,
        remaining_vpcs=0,
        remaining_eks_clusters=0,
        remaining_iam_roles=0,
    )


def test_run_sweep_parses_subprocess_output() -> None:
    """_run_sweep should parse the helper output and return typed counts."""
    with patch(
        "prodbox.cli.aws_cmd.subprocess.run",
        return_value=subprocess.CompletedProcess(
            args=["python", "-m", "tests.integration.sweep_runner"],
            returncode=0,
            stdout=(
                "deleted_hosted_zones=1\n"
                "deleted_buckets=2\n"
                "deleted_vpcs=3\n"
                "deleted_eks_clusters=4\n"
                "deleted_iam_roles=5\n"
                "remaining_hosted_zones=0\n"
                "remaining_buckets=0\n"
                "remaining_vpcs=0\n"
                "remaining_eks_clusters=0\n"
                "remaining_iam_roles=0\n"
            ),
            stderr="",
        ),
    ) as mock_run:
        result = _run_sweep()

    assert result == _SweepResult(
        deleted_hosted_zones=1,
        deleted_buckets=2,
        deleted_vpcs=3,
        deleted_eks_clusters=4,
        deleted_iam_roles=5,
        remaining_hosted_zones=0,
        remaining_buckets=0,
        remaining_vpcs=0,
        remaining_eks_clusters=0,
        remaining_iam_roles=0,
    )
    mock_run.assert_called_once()
    assert mock_run.call_args.kwargs["env"][ALLOW_NON_ENTRYPOINT_ENV] == "1"


def test_aws_sweep_fixtures_reports_empty_janitor_result() -> None:
    """CLI should report when the janitor has nothing to delete."""
    runner = CliRunner()

    with patch(
        "prodbox.cli.aws_cmd._run_sweep",
        return_value=_SweepResult(
            deleted_hosted_zones=0,
            deleted_buckets=0,
            deleted_vpcs=0,
            deleted_eks_clusters=0,
            deleted_iam_roles=0,
            remaining_hosted_zones=0,
            remaining_buckets=0,
            remaining_vpcs=0,
            remaining_eks_clusters=0,
            remaining_iam_roles=0,
        ),
    ) as mock_sweep:
        result = runner.invoke(cli, ["aws", "sweep-fixtures"])

    assert result.exit_code == 0
    assert "Running AWS fixture sweep..." in result.output
    assert "No expired fixture resources found." in result.output
    assert "No fixture-owned AWS resources remain." in result.output
    mock_sweep.assert_called_once_with()


def test_aws_sweep_fixtures_reports_deleted_resources() -> None:
    """CLI should print one line per deleted resource category."""
    runner = CliRunner()

    with patch(
        "prodbox.cli.aws_cmd._run_sweep",
        return_value=_SweepResult(
            deleted_hosted_zones=1,
            deleted_buckets=2,
            deleted_vpcs=3,
            deleted_eks_clusters=4,
            deleted_iam_roles=5,
            remaining_hosted_zones=0,
            remaining_buckets=0,
            remaining_vpcs=0,
            remaining_eks_clusters=0,
            remaining_iam_roles=0,
        ),
    ) as mock_sweep:
        result = runner.invoke(cli, ["aws", "sweep-fixtures"])

    assert result.exit_code == 0
    assert "Deleted 15 expired fixture resource(s):" in result.output
    assert "EKS clusters: 4" in result.output
    assert "IAM roles: 5" in result.output
    assert "Route 53 hosted zones: 1" in result.output
    assert "S3 buckets: 2" in result.output
    assert "VPCs: 3" in result.output
    assert "No fixture-owned AWS resources remain." in result.output
    mock_sweep.assert_called_once_with()


def test_aws_sweep_fixtures_fails_when_fixture_resources_remain() -> None:
    """CLI should fail when fixture-owned resources remain after the sweep."""
    runner = CliRunner()

    with patch(
        "prodbox.cli.aws_cmd._run_sweep",
        return_value=_SweepResult(
            deleted_hosted_zones=0,
            deleted_buckets=0,
            deleted_vpcs=0,
            deleted_eks_clusters=0,
            deleted_iam_roles=0,
            remaining_hosted_zones=1,
            remaining_buckets=0,
            remaining_vpcs=0,
            remaining_eks_clusters=0,
            remaining_iam_roles=0,
        ),
    ):
        result = runner.invoke(cli, ["aws", "sweep-fixtures"])

    assert result.exit_code != 0
    assert "Fixture-owned AWS resources still remain: 1" in result.output
    assert "Remaining Route 53 hosted zones: 1" in result.output
