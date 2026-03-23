"""Real Pulumi integration tests using an isolated local backend."""

from __future__ import annotations

import os
import shutil
import subprocess
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

import pytest
from click.testing import CliRunner

from prodbox.cli.main import cli

REPO_ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class PulumiRealProject:
    """Temporary Pulumi project rooted in a throwaway local backend."""

    project_dir: Path
    stack_name: str
    env_overrides: dict[str, str]


def _required_env_var(name: str) -> str:
    """Return a required environment variable or raise AssertionError."""
    value = os.environ.get(name)
    if value in (None, ""):
        raise AssertionError(f"missing required environment variable: {name}")
    return value


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
            "name: prodbox",
            "runtime:",
            "  name: python",
            "  options:",
            f"    virtualenv: {virtualenv_path}",
            "main: src/prodbox/infra/",
            "description: Home Kubernetes infrastructure with Pulumi",
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


@pytest.fixture
def pulumi_real_project(tmp_path: Path) -> PulumiRealProject:
    """Create a temp Pulumi project wired to the repo sources and a local backend."""
    if shutil.which("pulumi") is None:
        raise AssertionError("pulumi not installed")

    project_dir = tmp_path / "pulumi-project"
    backend_dir = tmp_path / "pulumi-backend"
    pulumi_home = tmp_path / "pulumi-home"
    project_dir.mkdir()
    backend_dir.mkdir()
    pulumi_home.mkdir()

    stack_name = os.environ.get("PULUMI_STACK", "home")
    aws_region = os.environ.get("AWS_REGION", "us-east-1")

    env_overrides = {
        "PULUMI_HOME": str(pulumi_home),
        "PULUMI_BACKEND_URL": f"file://{backend_dir}",
        "PULUMI_CONFIG_PASSPHRASE": "",
        "PULUMI_STACK": stack_name,
        "AWS_ACCESS_KEY_ID": _required_env_var("AWS_ACCESS_KEY_ID"),
        "AWS_SECRET_ACCESS_KEY": _required_env_var("AWS_SECRET_ACCESS_KEY"),
        "AWS_REGION": aws_region,
        "ROUTE53_ZONE_ID": _required_env_var("ROUTE53_ZONE_ID"),
        "ACME_EMAIL": os.environ.get("ACME_EMAIL", "integration@example.com"),
        "DEMO_FQDN": os.environ.get("DEMO_FQDN", "demo.example.com"),
    }

    (project_dir / "Pulumi.yaml").write_text(
        _render_pulumi_project_yaml(REPO_ROOT / ".venv"),
        encoding="utf-8",
    )
    (project_dir / f"Pulumi.{stack_name}.yaml").write_text(
        _render_stack_yaml(aws_region),
        encoding="utf-8",
    )
    (project_dir / "src").symlink_to(REPO_ROOT / "src", target_is_directory=True)

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
    )


@pytest.mark.integration
def test_pulumi_stack_init_and_preview_against_local_backend(
    cli_runner: CliRunner,
    pulumi_real_project: PulumiRealProject,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Pulumi commands should work against a temp project and local backend."""
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
