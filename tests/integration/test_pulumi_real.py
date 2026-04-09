"""Real Pulumi integration tests using an isolated local backend."""

from __future__ import annotations

import os
import shutil
import subprocess
from collections.abc import Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Never

import pytest
from click.testing import CliRunner

from prodbox.cli.main import cli
from prodbox.settings import get_settings

from .aws_helpers import (
    Route53HostedZoneContext,
    build_dns_suite_env,
    create_ephemeral_hosted_zone,
    delete_ephemeral_hosted_zone,
    wait_for_route53_record_values,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
pytestmark = [pytest.mark.integration, pytest.mark.timeout(300)]


@dataclass(frozen=True)
class PulumiRealProject:
    """Temporary Pulumi project rooted in a throwaway local backend."""

    project_dir: Path
    stack_name: str
    env_overrides: dict[str, str]
    txt_record_fqdn: str
    txt_record_value: str


def _run_subprocess(
    command: tuple[str, ...],
    *,
    cwd: Path,
    env: Mapping[str, str],
) -> None:
    """Run one subprocess command and require success."""
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        cwd=cwd,
        env=dict(env),
    )
    if completed.returncode != 0:
        stderr_text = completed.stderr.strip() or completed.stdout.strip()
        raise AssertionError(f"{' '.join(command)} failed: {stderr_text}")


def _render_pulumi_project_yaml(virtualenv_path: Path) -> str:
    """Render an isolated Pulumi project file for the test workspace."""
    return "\n".join(
        [
            "name: prodbox-pulumi-real-suite",
            "runtime:",
            "  name: python",
            "  options:",
            f"    virtualenv: {virtualenv_path}",
            "main: .",
            "description: Fixture-owned Pulumi lifecycle validation",
            "",
        ]
    )


def _render_stack_yaml(aws_region: str) -> str:
    """Render the minimal stack config needed for preview."""
    return "\n".join(
        [
            "config:",
            f"  aws:region: {aws_region}",
            "",
        ]
    )


def _render_pulumi_program() -> str:
    """Render a minimal Pulumi program with a fixture-owned Route 53 TXT record."""
    return "\n".join(
        [
            "from __future__ import annotations",
            "",
            "import os",
            "",
            "import pulumi",
            "import pulumi_aws as aws",
            "",
            'zone_id = os.environ["ROUTE53_ZONE_ID"]',
            'record_name = os.environ["PULUMI_TEST_RECORD_FQDN"]',
            'record_value = os.environ["PULUMI_TEST_RECORD_VALUE"]',
            "",
            "record = aws.route53.Record(",
            '    "pulumi-real-suite-record",',
            "    zone_id=zone_id,",
            "    name=record_name,",
            '    type="TXT",',
            "    ttl=60,",
            "    records=[record_value],",
            ")",
            "",
            'pulumi.export("record_name", record_name)',
            'pulumi.export("record_value", record_value)',
            "",
        ]
    )


def _abort_session_on_teardown_failure(*, target: str, error: BaseException) -> Never:
    """Abort the pytest session immediately for teardown cleanup failure."""
    pytest.exit(
        f"teardown cleanup failed for {target}: {type(error).__name__}: {error}",
        returncode=1,
    )


@pytest.fixture
def ephemeral_route53_zone() -> Iterator[Route53HostedZoneContext]:
    """Create and always clean up a fresh Route 53 hosted zone for Pulumi tests."""
    context = create_ephemeral_hosted_zone(test_scope="pulumi-real")
    try:
        yield context
    finally:
        try:
            delete_ephemeral_hosted_zone(context)
        except Exception as error:
            _abort_session_on_teardown_failure(target=context.zone_name, error=error)


@pytest.fixture
def pulumi_real_project(
    tmp_path: Path,
    ephemeral_route53_zone: Route53HostedZoneContext,
) -> PulumiRealProject:
    """Create a temp Pulumi project wired to fixture-owned Route 53 state."""
    if shutil.which("pulumi") is None:
        raise AssertionError("pulumi not installed")

    project_dir = tmp_path / "pulumi-project"
    backend_dir = tmp_path / "pulumi-backend"
    pulumi_home = tmp_path / "pulumi-home"
    project_dir.mkdir()
    backend_dir.mkdir()
    pulumi_home.mkdir()

    settings = get_settings()
    stack_name = "home"
    aws_region = settings.aws_region
    dns_env = build_dns_suite_env(ephemeral_route53_zone)
    txt_record_fqdn = f"pulumi.{ephemeral_route53_zone.zone_name}"
    txt_record_value = f"pulumi-real-{stack_name}"

    env_overrides = {
        "PULUMI_HOME": str(pulumi_home),
        "PULUMI_BACKEND_URL": f"file://{backend_dir}",
        "PULUMI_CONFIG_PASSPHRASE": "",
        "AWS_REGION": aws_region,
        "PULUMI_TEST_RECORD_FQDN": txt_record_fqdn,
        "PULUMI_TEST_RECORD_VALUE": txt_record_value,
        **dns_env,
    }

    (project_dir / "Pulumi.yaml").write_text(
        _render_pulumi_project_yaml(REPO_ROOT / ".venv"),
        encoding="utf-8",
    )
    (project_dir / f"Pulumi.{stack_name}.yaml").write_text(
        _render_stack_yaml(aws_region),
        encoding="utf-8",
    )
    (project_dir / "__main__.py").write_text(
        _render_pulumi_program(),
        encoding="utf-8",
    )

    pulumi_env = dict(os.environ)
    pulumi_env.update(env_overrides)
    _run_subprocess(
        ("pulumi", "login", f"file://{backend_dir}"),
        cwd=project_dir,
        env=pulumi_env,
    )

    return PulumiRealProject(
        project_dir=project_dir,
        stack_name=stack_name,
        env_overrides=env_overrides,
        txt_record_fqdn=txt_record_fqdn,
        txt_record_value=txt_record_value,
    )


def test_pulumi_stack_preview_up_and_destroy_against_local_backend(
    cli_runner: CliRunner,
    pulumi_real_project: PulumiRealProject,
    ephemeral_route53_zone: Route53HostedZoneContext,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Pulumi commands should exercise a real stack lifecycle against fixture-owned state."""
    monkeypatch.chdir(pulumi_real_project.project_dir)
    for key, value in pulumi_real_project.env_overrides.items():
        monkeypatch.setenv(key, value)

    stack_init = cli_runner.invoke(
        cli,
        ["pulumi", "stack-init", pulumi_real_project.stack_name],
        catch_exceptions=False,
    )
    assert stack_init.exit_code == 0

    preview = cli_runner.invoke(cli, ["pulumi", "preview"], catch_exceptions=False)
    assert preview.exit_code == 0

    up = cli_runner.invoke(cli, ["pulumi", "up", "--yes"], catch_exceptions=False)
    assert up.exit_code == 0
    wait_for_route53_record_values(
        ephemeral_route53_zone,
        record_name=pulumi_real_project.txt_record_fqdn,
        record_type="TXT",
        expected_values=(f'"{pulumi_real_project.txt_record_value}"',),
    )

    destroy = cli_runner.invoke(cli, ["pulumi", "destroy", "--yes"], catch_exceptions=False)
    assert destroy.exit_code == 0
    wait_for_route53_record_values(
        ephemeral_route53_zone,
        record_name=pulumi_real_project.txt_record_fqdn,
        record_type="TXT",
        expected_values=None,
    )
