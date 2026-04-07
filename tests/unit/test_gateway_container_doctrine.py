"""Unit tests for the canonical gateway container build path."""

from __future__ import annotations

from pathlib import Path


def _repo_root() -> Path:
    """Return the repository root from the test location."""
    return Path(__file__).resolve().parents[2]


def test_legacy_gateway_container_wrapper_is_absent() -> None:
    """The compatibility gateway container wrapper must stay removed."""
    assert not (_repo_root() / "Containerfile.gateway").exists()


def test_gateway_dockerfile_uses_canonical_cli_entrypoint() -> None:
    """Gateway image builds must start via the canonical CLI path."""
    dockerfile = (_repo_root() / "docker" / "gateway.Dockerfile").read_text(encoding="utf-8")

    assert (
        'ENTRYPOINT ["/usr/bin/tini", "--", "python", "-m", "prodbox.cli.main", '
        '"gateway", "start"]' in dockerfile
    )
