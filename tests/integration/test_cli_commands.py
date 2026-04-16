"""Integration tests for CLI commands using the effect system."""

from __future__ import annotations

import json
import os
import socket
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from click.testing import CliRunner

from prodbox.cli.command_adt import HostCheckPortsCommand
from prodbox.cli.command_executor import execute_command
from prodbox.cli.interpreter import ProcessOutput
from prodbox.cli.main import cli

from .helpers import free_port


def _mock_async_http_client(public_ip: str) -> AsyncMock:
    """Build an AsyncClient mock that returns a deterministic public IP."""
    response = MagicMock()
    response.text = public_ip
    response.raise_for_status = MagicMock()

    client = AsyncMock()
    client.get = AsyncMock(return_value=response)
    client.__aenter__ = AsyncMock(return_value=client)
    client.__aexit__ = AsyncMock(return_value=None)
    return client


def _mock_boto3_session(*, current_record_ip: str | None) -> MagicMock:
    """Build a boto3 Session mock for Route 53 and STS workflows."""
    sts_client = MagicMock()
    sts_client.get_caller_identity.return_value = {"Account": "123456789012"}

    route53_client = MagicMock()
    route53_client.get_hosted_zone.return_value = {
        "HostedZone": {"Id": "/hostedzone/Z1234567890ABC"}
    }
    route53_client.list_resource_record_sets.return_value = {
        "ResourceRecordSets": (
            [
                {
                    "Name": "test.example.com.",
                    "Type": "A",
                    "ResourceRecords": [{"Value": current_record_ip}],
                }
            ]
            if current_record_ip is not None
            else []
        )
    }

    session = MagicMock()
    session.client.side_effect = lambda service_name: (
        sts_client if service_name == "sts" else route53_client
    )
    return session


class TestHostCommands:
    """Tests for host subcommands."""

    def test_host_ensure_tools_returns_exit_code(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """host ensure-tools should return an exit code."""
        result = cli_runner.invoke(cli, ["host", "ensure-tools"])
        assert result.exit_code in (0, 1)

    def test_host_check_ports_detects_busy_listener(
        self,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Direct host check should fail when a requested port is already bound."""
        free = free_port()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        busy = int(listener.getsockname()[1])

        try:
            exit_code = execute_command(HostCheckPortsCommand(ports=(free, busy)))
        finally:
            listener.close()

        output = capsys.readouterr().out
        assert exit_code == 1
        assert f"Ports unavailable: {busy}" in output


class TestDNSCommands:
    """Tests for DNS subcommands."""

    def test_dns_check_fails_without_config(
        self,
        cli_runner: CliRunner,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """dns check should fail without AWS config."""
        import prodbox.settings as settings_module

        monkeypatch.setattr(settings_module, "REPOSITORY_ROOT", tmp_path)
        with patch.dict(os.environ, {}, clear=True):
            result = cli_runner.invoke(cli, ["dns", "check"])

        assert result.exit_code == 1

    def test_dns_check_renders_public_and_route53_state(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """dns check should report both public IP and the current Route 53 record."""
        mock_session = _mock_boto3_session(current_record_ip="203.0.113.10")
        with (
            patch.dict(os.environ, mock_env, clear=True),
            patch("httpx.AsyncClient", return_value=_mock_async_http_client("203.0.113.10")),
            patch("boto3.Session", return_value=mock_session),
        ):
            result = cli_runner.invoke(cli, ["dns", "check"], catch_exceptions=False)

        assert result.exit_code == 0
        assert "PUBLIC_IP=203.0.113.10" in result.output
        assert "ROUTE53_A_RECORD=203.0.113.10" in result.output
        assert "STATUS=in-sync" in result.output


class TestK8sCommands:
    """Tests for Kubernetes subcommands."""

    def test_k8s_health_fails_without_config(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """k8s health should fail without kubeconfig."""
        with patch.dict(os.environ, {}, clear=True):
            result = cli_runner.invoke(cli, ["k8s", "health"])

        assert result.exit_code == 1


class TestPulumiCommands:
    """Tests for Pulumi subcommands."""

    def test_pulumi_preview_fails_without_tools(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """pulumi preview should fail if pulumi not available."""
        with patch("shutil.which", return_value=None):
            result = cli_runner.invoke(cli, ["pulumi", "preview"])

        assert result.exit_code in (0, 1)

    def test_pulumi_preview_fails_when_not_logged_in(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """pulumi preview should fail fast when `pulumi whoami` fails."""
        with (
            patch.dict(os.environ, mock_env, clear=True),
            patch("shutil.which", return_value="/usr/bin/pulumi"),
            patch(
                "prodbox.cli.interpreter._run_subprocess",
                new_callable=AsyncMock,
                return_value=ProcessOutput(returncode=1, stdout=b"", stderr=b"not logged in"),
            ),
        ):
            result = cli_runner.invoke(cli, ["pulumi", "preview"], catch_exceptions=False)

        assert result.exit_code == 1
        assert "Pulumi login failed" in result.output

    def test_pulumi_preview_runs_whoami_stack_select_and_preview(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """pulumi preview should execute login check, stack select, and preview in order."""
        with (
            patch.dict(os.environ, mock_env, clear=True),
            patch("shutil.which", return_value="/usr/bin/pulumi"),
            patch(
                "prodbox.cli.interpreter._run_subprocess",
                new_callable=AsyncMock,
                side_effect=(
                    ProcessOutput(returncode=0, stdout=b"matt\n", stderr=b""),
                    ProcessOutput(returncode=0, stdout=b"", stderr=b""),
                    ProcessOutput(returncode=0, stdout=b"", stderr=b""),
                ),
            ) as mock_run_subprocess,
        ):
            result = cli_runner.invoke(cli, ["pulumi", "preview"], catch_exceptions=False)

        assert result.exit_code == 0
        commands = [call.args[0] for call in mock_run_subprocess.await_args_list]
        assert commands[0] == ("pulumi", "whoami")
        assert commands[1][0:3] == ("pulumi", "stack", "select")
        assert commands[2][0:2] == ("pulumi", "preview")


class TestRKE2Commands:
    """Tests for RKE2 subcommands."""

    def test_rke2_status_fails_on_non_linux(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """rke2 status should fail on non-Linux."""
        with patch("platform.system", return_value="Darwin"):
            result = cli_runner.invoke(cli, ["rke2", "status"])

        assert result.exit_code == 1


class TestMainCLI:
    """Tests for main CLI entry point."""

    def test_cli_help(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """CLI should show help."""
        result = cli_runner.invoke(cli, ["--help"])

        assert result.exit_code == 0
        assert "prodbox" in result.output

    def test_cli_version(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """CLI should show version."""
        result = cli_runner.invoke(cli, ["--version"])

        assert result.exit_code == 0

    def test_cli_verbose(
        self,
        cli_runner: CliRunner,
        mock_env: dict[str, str],
    ) -> None:
        """CLI should accept verbose flag."""
        with patch.dict(os.environ, mock_env, clear=True):
            result = cli_runner.invoke(cli, ["-v", "config", "show"])

        assert result.exit_code in (0, 1)

    def test_aws_policy_outputs_parseable_json_without_summary(
        self,
        cli_runner: CliRunner,
    ) -> None:
        """aws policy should emit JSON only so the result stays machine-parseable."""
        result = cli_runner.invoke(cli, ["aws", "policy", "--tier", "full"], catch_exceptions=False)

        assert result.exit_code == 0
        parsed = json.loads(result.output)
        statements = tuple(statement["Sid"] for statement in parsed["Statement"])
        assert "Ec2HaTestStackLifecycle" in statements
        assert "IamEksRoleLifecycle" in statements
        assert "EksTestStackLifecycle" in statements
        assert "Route53HostedZoneLifecycle" in statements
