"""Unit tests for command executor module."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

from prodbox.cli.command_adt import EnvTemplateCommand
from prodbox.cli.command_executor import (
    execute_command,
    execute_dag,
    execute_effect,
    render_error_and_return_exit_code,
)
from prodbox.cli.effect_dag import EffectDAG, EffectNode
from prodbox.cli.effects import Pure
from prodbox.cli.interpreter import DAGExecutionSummary, ExecutionSummary


class TestRenderErrorAndReturnExitCode:
    """Tests for render_error_and_return_exit_code function."""

    def test_returns_exit_code_1(self) -> None:
        """Should always return exit code 1."""
        result = render_error_and_return_exit_code(
            "Test error",
            effect_id="test_effect",
        )
        assert result == 1

    def test_prints_error_with_effect_id(self) -> None:
        """Should print error message with effect_id."""
        # Just verify it returns 1 (the printing goes to stderr)
        result = render_error_and_return_exit_code(
            "Something went wrong",
            effect_id="my_effect",
        )
        assert result == 1


class TestExecuteCommand:
    """Tests for execute_command function."""

    def test_execute_command_success(self) -> None:
        """execute_command should return 0 on success."""
        cmd = EnvTemplateCommand()

        # Mock the interpreter to return success
        mock_summary = DAGExecutionSummary(
            exit_code=0,
            message="Success",
            node_results=(),
            total_nodes=1,
            successful_nodes=1,
            failed_nodes=0,
        )

        with patch("prodbox.cli.command_executor.create_interpreter") as mock_create:
            mock_interpreter = MagicMock()
            mock_interpreter.interpret_dag = AsyncMock(return_value=mock_summary)
            mock_create.return_value = mock_interpreter

            result = execute_command(cmd)

        assert result == 0

    def test_execute_command_failure(self) -> None:
        """execute_command should return non-zero on failure."""
        cmd = EnvTemplateCommand()

        mock_summary = DAGExecutionSummary(
            exit_code=1,
            message="Failed",
            node_results=(),
            total_nodes=1,
            successful_nodes=0,
            failed_nodes=1,
        )

        with patch("prodbox.cli.command_executor.create_interpreter") as mock_create:
            mock_interpreter = MagicMock()
            mock_interpreter.interpret_dag = AsyncMock(return_value=mock_summary)
            mock_create.return_value = mock_interpreter

            result = execute_command(cmd)

        assert result == 1

    def test_execute_command_dag_build_failure(self) -> None:
        """execute_command should return 1 when DAG build fails."""
        from prodbox.cli.types import Failure

        cmd = EnvTemplateCommand()

        # Mock command_to_dag to return Failure
        with patch(
            "prodbox.cli.command_executor.command_to_dag",
            return_value=Failure("Missing prerequisite: test_prereq"),
        ):
            result = execute_command(cmd)

        assert result == 1


class TestExecuteEffect:
    """Tests for execute_effect function."""

    def test_execute_effect_success(self) -> None:
        """execute_effect should return 0 on success."""
        effect = Pure(effect_id="test", description="Test", value="hello")

        mock_summary = ExecutionSummary(exit_code=0, message="Success")

        with patch("prodbox.cli.command_executor.create_interpreter") as mock_create:
            mock_interpreter = MagicMock()
            mock_interpreter.interpret = AsyncMock(return_value=mock_summary)
            mock_create.return_value = mock_interpreter

            result = execute_effect(effect)

        assert result == 0

    def test_execute_effect_failure(self) -> None:
        """execute_effect should return non-zero on failure."""
        effect = Pure(effect_id="test", description="Test", value="hello")

        mock_summary = ExecutionSummary(exit_code=1, message="Failed")

        with patch("prodbox.cli.command_executor.create_interpreter") as mock_create:
            mock_interpreter = MagicMock()
            mock_interpreter.interpret = AsyncMock(return_value=mock_summary)
            mock_create.return_value = mock_interpreter

            result = execute_effect(effect)

        assert result == 1


class TestExecuteDAG:
    """Tests for execute_dag function."""

    def test_execute_dag_success(self) -> None:
        """execute_dag should return 0 on success."""
        node = EffectNode(
            effect=Pure(effect_id="test", description="Test", value="hello"),
        )
        dag = EffectDAG(nodes=frozenset([node]), roots=frozenset(["test"]))

        mock_summary = DAGExecutionSummary(
            exit_code=0,
            message="Success",
            node_results=(),
            total_nodes=1,
            successful_nodes=1,
            failed_nodes=0,
        )

        with patch("prodbox.cli.command_executor.create_interpreter") as mock_create:
            mock_interpreter = MagicMock()
            mock_interpreter.interpret_dag = AsyncMock(return_value=mock_summary)
            mock_create.return_value = mock_interpreter

            result = execute_dag(dag)

        assert result == 0

    def test_execute_dag_failure(self) -> None:
        """execute_dag should return non-zero on failure."""
        node = EffectNode(
            effect=Pure(effect_id="test", description="Test", value="hello"),
        )
        dag = EffectDAG(nodes=frozenset([node]), roots=frozenset(["test"]))

        mock_summary = DAGExecutionSummary(
            exit_code=1,
            message="Failed",
            node_results=(),
            total_nodes=1,
            successful_nodes=0,
            failed_nodes=1,
        )

        with patch("prodbox.cli.command_executor.create_interpreter") as mock_create:
            mock_interpreter = MagicMock()
            mock_interpreter.interpret_dag = AsyncMock(return_value=mock_summary)
            mock_create.return_value = mock_interpreter

            result = execute_dag(dag)

        assert result == 1
