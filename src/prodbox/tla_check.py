"""Run TLA+ proof checks inside Docker.

This module is intentionally standalone from the CLI DAG system so the proof
check can run in development environments without requiring the full prodbox
runtime context.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

DEFAULT_IMAGE = "maxdiefenbach/tlaplus"
DEFAULT_MODEL_FILE = "gateway_orders_rule.tla"
DEFAULT_CONFIG_FILE = "gateway_orders_rule.cfg"
DEFAULT_RESULT_FILE = "tlc_last_run.txt"


@dataclass(frozen=True)
class TLAProofCheckConfig:
    """Runtime configuration for TLA+ proof checks.

    Attributes:
        tla_dir: Directory containing TLA+ model and config files
        model_file: TLA+ spec file name
        config_file: TLC config file name
        result_file: Output file for command result details
        image: Docker image that provides TLC
    """

    tla_dir: Path
    model_file: str
    config_file: str
    result_file: Path
    image: str = DEFAULT_IMAGE


def _repo_root() -> Path:
    """Get repository root path from this module location."""
    return Path(__file__).resolve().parents[2]


def default_config() -> TLAProofCheckConfig:
    """Build default proof-check configuration."""
    tla_dir = _repo_root() / "documents" / "engineering" / "tla"
    return TLAProofCheckConfig(
        tla_dir=tla_dir,
        model_file=DEFAULT_MODEL_FILE,
        config_file=DEFAULT_CONFIG_FILE,
        result_file=tla_dir / DEFAULT_RESULT_FILE,
    )


def build_docker_command(config: TLAProofCheckConfig) -> tuple[str, ...]:
    """Build the Docker command for TLC.

    Uses a self-deleting container (`--rm`) and mounts the model directory
    into `/workspace`.
    """
    mount_dir = str(config.tla_dir.resolve())
    return (
        "docker",
        "run",
        "--rm",
        "--entrypoint",
        "",
        "--volume",
        f"{mount_dir}:/workspace",
        "--workdir",
        "/workspace",
        config.image,
        "java",
        "-XX:+UseParallelGC",
        "-cp",
        "/opt/TLA+Toolbox/tla2tools.jar",
        "tlc2.TLC",
        "-workers",
        "8",
        "-config",
        config.config_file,
        config.model_file,
    )


def _render_result_content(
    *,
    command: tuple[str, ...],
    returncode: int,
    stdout: str,
    stderr: str,
) -> str:
    """Render proof result content for persistence."""
    timestamp = datetime.now(UTC).isoformat()
    command_str = " ".join(command)
    return (
        f"timestamp_utc: {timestamp}\n"
        f"command: {command_str}\n"
        f"returncode: {returncode}\n"
        "stdout:\n"
        f"{stdout}\n"
        "stderr:\n"
        f"{stderr}\n"
    )


def run_tla_proof_check(config: TLAProofCheckConfig) -> int:
    """Run TLC in Docker and persist result output.

    Args:
        config: Proof-check runtime configuration

    Returns:
        Process return code (0 for success, non-zero for failure)
    """
    model_path = config.tla_dir / config.model_file
    cfg_path = config.tla_dir / config.config_file

    if not model_path.exists():
        message = f"Model file not found: {model_path}"
        _write_result(
            result_file=config.result_file,
            content=_render_result_content(
                command=(),
                returncode=1,
                stdout="",
                stderr=message,
            ),
        )
        return 1

    if not cfg_path.exists():
        message = f"Config file not found: {cfg_path}"
        _write_result(
            result_file=config.result_file,
            content=_render_result_content(
                command=(),
                returncode=1,
                stdout="",
                stderr=message,
            ),
        )
        return 1

    command = build_docker_command(config)

    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        _write_result(
            result_file=config.result_file,
            content=_render_result_content(
                command=command,
                returncode=1,
                stdout="",
                stderr="Docker not found on PATH",
            ),
        )
        return 1

    _write_result(
        result_file=config.result_file,
        content=_render_result_content(
            command=command,
            returncode=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
        ),
    )
    return completed.returncode


def _write_result(*, result_file: Path, content: str) -> None:
    """Persist proof-check result text to disk."""
    result_file.parent.mkdir(parents=True, exist_ok=True)
    result_file.write_text(content, encoding="utf-8")


def main() -> None:
    """Poetry entrypoint for Dockerized TLA+ proof checks."""
    config = default_config()
    raise SystemExit(run_tla_proof_check(config))


if __name__ == "__main__":
    main()
