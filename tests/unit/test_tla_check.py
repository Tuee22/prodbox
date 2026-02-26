"""Unit tests for Dockerized TLA+ proof checks."""

from __future__ import annotations

from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch

from prodbox.tla_check import (
    DEFAULT_IMAGE,
    TLAProofCheckConfig,
    build_docker_command,
    run_tla_proof_check,
)


class TestBuildDockerCommand:
    """Tests for docker command generation."""

    def test_uses_self_deleting_container_and_expected_image(self, tmp_path: Path) -> None:
        """Docker command should include --rm and tlaplatform image."""
        config = TLAProofCheckConfig(
            tla_dir=tmp_path,
            model_file="model.tla",
            config_file="model.cfg",
            result_file=tmp_path / "result.txt",
            image=DEFAULT_IMAGE,
        )

        command = build_docker_command(config)

        assert command[:3] == ("docker", "run", "--rm")
        assert DEFAULT_IMAGE in command
        assert command[-3:] == ("-config", "model.cfg", "model.tla")


class TestRunTLAProofCheck:
    """Tests for proof-check execution and result persistence."""

    def test_writes_result_on_success(self, tmp_path: Path) -> None:
        """run_tla_proof_check should save TLC output on success."""
        model_file = "model.tla"
        config_file = "model.cfg"
        result_file = tmp_path / "proof_result.txt"
        (tmp_path / model_file).write_text("---- MODULE model ----", encoding="utf-8")
        (tmp_path / config_file).write_text("SPECIFICATION Spec", encoding="utf-8")

        config = TLAProofCheckConfig(
            tla_dir=tmp_path,
            model_file=model_file,
            config_file=config_file,
            result_file=result_file,
            image=DEFAULT_IMAGE,
        )

        completed = CompletedProcess(
            args=("docker", "run"),
            returncode=0,
            stdout="TLC finished",
            stderr="",
        )

        with patch("subprocess.run", return_value=completed) as mock_run:
            exit_code = run_tla_proof_check(config)

        assert exit_code == 0
        assert result_file.exists()
        content = result_file.read_text(encoding="utf-8")
        assert "returncode: 0" in content
        assert "TLC finished" in content
        mock_run.assert_called_once()
        _, kwargs = mock_run.call_args
        assert kwargs["check"] is False
        assert kwargs["capture_output"] is True
        assert kwargs["text"] is True

    def test_writes_result_when_model_missing(self, tmp_path: Path) -> None:
        """run_tla_proof_check should fail clearly when model is missing."""
        result_file = tmp_path / "proof_result.txt"
        (tmp_path / "model.cfg").write_text("SPECIFICATION Spec", encoding="utf-8")

        config = TLAProofCheckConfig(
            tla_dir=tmp_path,
            model_file="missing.tla",
            config_file="model.cfg",
            result_file=result_file,
        )

        exit_code = run_tla_proof_check(config)

        assert exit_code == 1
        content = result_file.read_text(encoding="utf-8")
        assert "Model file not found" in content

    def test_writes_result_when_docker_missing(self, tmp_path: Path) -> None:
        """run_tla_proof_check should persist failure when docker is unavailable."""
        result_file = tmp_path / "proof_result.txt"
        (tmp_path / "model.tla").write_text("---- MODULE model ----", encoding="utf-8")
        (tmp_path / "model.cfg").write_text("SPECIFICATION Spec", encoding="utf-8")

        config = TLAProofCheckConfig(
            tla_dir=tmp_path,
            model_file="model.tla",
            config_file="model.cfg",
            result_file=result_file,
        )

        with patch("subprocess.run", side_effect=FileNotFoundError()):
            exit_code = run_tla_proof_check(config)

        assert exit_code == 1
        content = result_file.read_text(encoding="utf-8")
        assert "Docker not found on PATH" in content
