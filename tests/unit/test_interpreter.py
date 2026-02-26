"""Unit tests for the effect interpreter."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch
import tempfile

import pytest

from prodbox.cli.interpreter import (
    DAGExecutionSummary,
    EffectInterpreter,
    EnvironmentError,
    ExecutionSummary,
    ProcessOutput,
    _assert_never,
    _run_subprocess,
    create_interpreter,
)
from prodbox.cli.effect_dag import EffectDAG, EffectNode
from prodbox.cli.effects import (
    CaptureSubprocessOutput,
    CheckFileExists,
    CheckServiceStatus,
    Custom,
    FetchPublicIP,
    LoadSettings,
    Parallel,
    PrintBlankLine,
    PrintError,
    PrintIndented,
    PrintInfo,
    PrintSection,
    PrintSuccess,
    PrintTable,
    PrintWarning,
    Pure,
    ReadFile,
    RequireLinux,
    RequireSystemd,
    RunSubprocess,
    Sequence,
    Try,
    ValidateEnvironment,
    ValidateSettings,
    ValidateTool,
    WriteFile,
    WriteStderr,
    WriteStdout,
)


class TestExecutionSummary:
    """Tests for ExecutionSummary type."""

    def test_execution_summary_success(self) -> None:
        """ExecutionSummary with exit_code 0 is success."""
        summary = ExecutionSummary(exit_code=0, message="Done")
        assert summary.success is True
        assert summary.exit_code == 0
        assert summary.message == "Done"

    def test_execution_summary_failure(self) -> None:
        """ExecutionSummary with non-zero exit_code is failure."""
        summary = ExecutionSummary(exit_code=1, message="Failed")
        assert summary.success is False
        assert summary.exit_code == 1

    def test_execution_summary_defaults(self) -> None:
        """ExecutionSummary should have correct defaults."""
        summary = ExecutionSummary(exit_code=0, message="Done")
        assert summary.total_effects == 0
        assert summary.successful_effects == 0
        assert summary.failed_effects == 0
        assert summary.skipped_effects == 0
        assert summary.elapsed_seconds == 0.0
        assert summary.artifacts == ()
        assert summary.environment_errors == ()


class TestEnvironmentError:
    """Tests for EnvironmentError type."""

    def test_environment_error_fields(self) -> None:
        """EnvironmentError should hold all fields."""
        error = EnvironmentError(
            tool="kubectl",
            message="Tool not found: kubectl",
            fix_hint="Install kubectl",
            source_effect_id="validate_kubectl",
        )
        assert error.tool == "kubectl"
        assert error.message == "Tool not found: kubectl"
        assert error.fix_hint == "Install kubectl"
        assert error.source_effect_id == "validate_kubectl"


class TestAssertNever:
    """Tests for _assert_never helper."""

    def test_assert_never_raises(self) -> None:
        """_assert_never should raise AssertionError."""

        class UnhandledType:
            pass

        with pytest.raises(AssertionError, match="Unhandled effect type"):
            _assert_never(UnhandledType())


class TestCreateInterpreter:
    """Tests for interpreter factory."""

    def test_create_interpreter_returns_interpreter(self) -> None:
        """create_interpreter should return EffectInterpreter."""
        interpreter = create_interpreter()
        assert isinstance(interpreter, EffectInterpreter)

    def test_create_interpreter_fresh_state(self) -> None:
        """create_interpreter should return fresh interpreter."""
        interpreter = create_interpreter()
        assert interpreter.total_effects == 0
        assert interpreter.successful_effects == 0
        assert interpreter.failed_effects == 0


class TestEffectInterpreterPure:
    """Tests for interpreter with Pure effects."""

    @pytest.mark.asyncio
    async def test_interpret_pure(self) -> None:
        """Interpreter should handle Pure effects."""
        interpreter = EffectInterpreter()
        effect: Pure[str] = Pure(
            effect_id="test_pure",
            description="Test pure",
            value="hello",
        )

        summary = await interpreter.interpret(effect)

        assert summary.success
        assert interpreter.successful_effects == 1

    @pytest.mark.asyncio
    async def test_interpret_with_value_pure(self) -> None:
        """interpret_with_value should return value for Pure."""
        interpreter = EffectInterpreter()
        effect: Pure[int] = Pure(
            effect_id="test_pure",
            description="Test pure",
            value=42,
        )

        summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == 42


class TestEffectInterpreterPlatform:
    """Tests for platform detection effects."""

    @pytest.mark.asyncio
    async def test_require_linux_on_linux(self) -> None:
        """RequireLinux should succeed on Linux."""
        interpreter = EffectInterpreter()
        effect = RequireLinux(
            effect_id="platform_linux",
            description="Require Linux",
        )

        with patch("prodbox.cli.interpreter.platform_module.system", return_value="Linux"):
            summary = await interpreter.interpret(effect)

        assert summary.success

    @pytest.mark.asyncio
    async def test_require_linux_on_non_linux(self) -> None:
        """RequireLinux should fail on non-Linux."""
        interpreter = EffectInterpreter()
        effect = RequireLinux(
            effect_id="platform_linux",
            description="Require Linux",
        )

        with patch("prodbox.cli.interpreter.platform_module.system", return_value="Darwin"):
            summary = await interpreter.interpret(effect)

        assert not summary.success
        # Message uses lowercase platform name
        assert "darwin" in summary.message.lower()

    @pytest.mark.asyncio
    async def test_require_systemd_available(self) -> None:
        """RequireSystemd should succeed when systemctl available."""
        interpreter = EffectInterpreter()
        effect = RequireSystemd(
            effect_id="systemd_available",
            description="Require systemd",
        )

        with patch("prodbox.cli.interpreter.shutil.which", return_value="/usr/bin/systemctl"):
            summary = await interpreter.interpret(effect)

        assert summary.success

    @pytest.mark.asyncio
    async def test_require_systemd_unavailable(self) -> None:
        """RequireSystemd should fail when systemctl unavailable."""
        interpreter = EffectInterpreter()
        effect = RequireSystemd(
            effect_id="systemd_available",
            description="Require systemd",
        )

        with patch("prodbox.cli.interpreter.shutil.which", return_value=None):
            summary = await interpreter.interpret(effect)

        assert not summary.success


class TestEffectInterpreterToolValidation:
    """Tests for tool validation effects."""

    @pytest.mark.asyncio
    async def test_validate_tool_found(self) -> None:
        """ValidateTool should succeed when tool found."""
        interpreter = EffectInterpreter()
        effect = ValidateTool(
            effect_id="tool_kubectl",
            description="Validate kubectl",
            tool_name="kubectl",
        )

        with patch("prodbox.cli.interpreter.shutil.which", return_value="/usr/local/bin/kubectl"):
            summary = await interpreter.interpret(effect)

        assert summary.success

    @pytest.mark.asyncio
    async def test_validate_tool_not_found(self) -> None:
        """ValidateTool should fail when tool not found."""
        interpreter = EffectInterpreter()
        effect = ValidateTool(
            effect_id="tool_kubectl",
            description="Validate kubectl",
            tool_name="kubectl",
        )

        with patch("prodbox.cli.interpreter.shutil.which", return_value=None):
            summary = await interpreter.interpret(effect)

        assert not summary.success
        assert len(interpreter.environment_errors) == 1
        assert interpreter.environment_errors[0].tool == "kubectl"

    @pytest.mark.asyncio
    async def test_validate_environment_all_found(self) -> None:
        """ValidateEnvironment should succeed when all tools found."""
        interpreter = EffectInterpreter()
        effect = ValidateEnvironment(
            effect_id="validate_tools",
            description="Validate tools",
            tools=["kubectl", "helm"],
        )

        with patch("prodbox.cli.interpreter.shutil.which", return_value="/usr/local/bin/tool"):
            summary = await interpreter.interpret(effect)

        assert summary.success

    @pytest.mark.asyncio
    async def test_validate_environment_some_missing(self) -> None:
        """ValidateEnvironment should fail when some tools missing."""
        interpreter = EffectInterpreter()
        effect = ValidateEnvironment(
            effect_id="validate_tools",
            description="Validate tools",
            tools=["kubectl", "missing_tool"],
        )

        def mock_which(tool: str) -> str | None:
            return "/usr/local/bin/kubectl" if tool == "kubectl" else None

        with patch("prodbox.cli.interpreter.shutil.which", side_effect=mock_which):
            summary = await interpreter.interpret(effect)

        assert not summary.success
        assert "missing_tool" in summary.message


class TestEffectInterpreterFileSystem:
    """Tests for file system effects."""

    @pytest.mark.asyncio
    async def test_check_file_exists_found(self) -> None:
        """CheckFileExists should succeed when file exists."""
        interpreter = EffectInterpreter()

        with tempfile.NamedTemporaryFile() as f:
            effect = CheckFileExists(
                effect_id="check_file",
                description="Check file",
                file_path=Path(f.name),
            )
            summary = await interpreter.interpret(effect)

        assert summary.success

    @pytest.mark.asyncio
    async def test_check_file_exists_not_found(self) -> None:
        """CheckFileExists should fail when file doesn't exist."""
        interpreter = EffectInterpreter()
        effect = CheckFileExists(
            effect_id="check_file",
            description="Check file",
            file_path=Path("/nonexistent/file.txt"),
        )

        summary = await interpreter.interpret(effect)

        assert not summary.success

    @pytest.mark.asyncio
    async def test_read_file_success(self) -> None:
        """ReadFile should return file contents."""
        interpreter = EffectInterpreter()

        with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".txt") as f:
            f.write("test content")
            f.flush()
            path = Path(f.name)

        try:
            effect = ReadFile(
                effect_id="read_file",
                description="Read file",
                file_path=path,
            )
            summary, value = await interpreter.interpret_with_value(effect)

            assert summary.success
            assert value == "test content"
        finally:
            path.unlink()

    @pytest.mark.asyncio
    async def test_read_file_not_found(self) -> None:
        """ReadFile should fail when file doesn't exist."""
        interpreter = EffectInterpreter()
        effect = ReadFile(
            effect_id="read_file",
            description="Read file",
            file_path=Path("/nonexistent/file.txt"),
        )

        summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None

    @pytest.mark.asyncio
    async def test_write_file_success(self) -> None:
        """WriteFile should write content to file."""
        interpreter = EffectInterpreter()

        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "test.txt"
            effect = WriteFile(
                effect_id="write_file",
                description="Write file",
                file_path=path,
                content="test content",
            )

            summary = await interpreter.interpret(effect)

            assert summary.success
            assert path.read_text() == "test content"
            assert path in interpreter.artifacts


class TestEffectInterpreterOutput:
    """Tests for output effects."""

    @pytest.mark.asyncio
    async def test_write_stdout(self) -> None:
        """WriteStdout should write to stdout."""
        interpreter = EffectInterpreter()
        effect = WriteStdout(
            effect_id="write_stdout",
            description="Write stdout",
            text="Hello\n",
        )

        with patch("sys.stdout") as mock_stdout:
            summary = await interpreter.interpret(effect)

        assert summary.success
        mock_stdout.write.assert_called_once_with("Hello\n")

    @pytest.mark.asyncio
    async def test_write_stderr(self) -> None:
        """WriteStderr should write to stderr."""
        interpreter = EffectInterpreter()
        effect = WriteStderr(
            effect_id="write_stderr",
            description="Write stderr",
            text="Error\n",
        )

        with patch("sys.stderr") as mock_stderr:
            summary = await interpreter.interpret(effect)

        assert summary.success
        mock_stderr.write.assert_called_once_with("Error\n")

    @pytest.mark.asyncio
    async def test_print_info(self) -> None:
        """PrintInfo should print info message."""
        interpreter = EffectInterpreter()
        effect = PrintInfo(
            effect_id="print_info",
            description="Print info",
            message="Info message",
        )

        summary = await interpreter.interpret(effect)
        assert summary.success

    @pytest.mark.asyncio
    async def test_print_success(self) -> None:
        """PrintSuccess should print success message."""
        interpreter = EffectInterpreter()
        effect = PrintSuccess(
            effect_id="print_success",
            description="Print success",
            message="Success message",
        )

        summary = await interpreter.interpret(effect)
        assert summary.success

    @pytest.mark.asyncio
    async def test_print_warning(self) -> None:
        """PrintWarning should print warning message."""
        interpreter = EffectInterpreter()
        effect = PrintWarning(
            effect_id="print_warning",
            description="Print warning",
            message="Warning message",
        )

        summary = await interpreter.interpret(effect)
        assert summary.success

    @pytest.mark.asyncio
    async def test_print_error(self) -> None:
        """PrintError should print error message."""
        interpreter = EffectInterpreter()
        effect = PrintError(
            effect_id="print_error",
            description="Print error",
            message="Error message",
        )

        summary = await interpreter.interpret(effect)
        assert summary.success

    @pytest.mark.asyncio
    async def test_print_table(self) -> None:
        """PrintTable should print table."""
        interpreter = EffectInterpreter()
        effect = PrintTable(
            effect_id="print_table",
            description="Print table",
            title="Test Table",
            columns=(("Col1", "cyan"), ("Col2", "green")),
            rows=(("a", "b"), ("c", "d")),
        )

        summary = await interpreter.interpret(effect)
        assert summary.success

    @pytest.mark.asyncio
    async def test_print_section(self) -> None:
        """PrintSection should print section header."""
        interpreter = EffectInterpreter()
        effect = PrintSection(
            effect_id="print_section",
            description="Print section",
            title="Section",
            blank_before=True,
            blank_after=True,
        )

        summary = await interpreter.interpret(effect)
        assert summary.success

    @pytest.mark.asyncio
    async def test_print_indented(self) -> None:
        """PrintIndented should print indented text."""
        interpreter = EffectInterpreter()
        effect = PrintIndented(
            effect_id="print_indented",
            description="Print indented",
            text="Indented text",
            indent=4,
        )

        summary = await interpreter.interpret(effect)
        assert summary.success

    @pytest.mark.asyncio
    async def test_print_blank_line(self) -> None:
        """PrintBlankLine should print blank line."""
        interpreter = EffectInterpreter()
        effect = PrintBlankLine(
            effect_id="print_blank",
            description="Print blank line",
        )

        summary = await interpreter.interpret(effect)
        assert summary.success


class TestEffectInterpreterComposite:
    """Tests for composite effects."""

    @pytest.mark.asyncio
    async def test_sequence_success(self) -> None:
        """Sequence should execute effects in order."""
        interpreter = EffectInterpreter()
        effect = Sequence(
            effect_id="sequence",
            description="Sequence",
            effects=[
                Pure(effect_id="first", description="First", value=1),
                Pure(effect_id="second", description="Second", value=2),
            ],
        )

        summary = await interpreter.interpret(effect)

        assert summary.success
        # 2 Pure effects (Sequence itself doesn't count as separate)
        assert interpreter.successful_effects >= 2

    @pytest.mark.asyncio
    async def test_sequence_short_circuits_on_failure(self) -> None:
        """Sequence should stop on first failure."""
        interpreter = EffectInterpreter()
        effect = Sequence(
            effect_id="sequence",
            description="Sequence",
            effects=[
                RequireLinux(effect_id="fail", description="Will fail"),
                Pure(effect_id="not_run", description="Not run", value=1),
            ],
        )

        with patch("prodbox.cli.interpreter.platform_module.system", return_value="Darwin"):
            summary = await interpreter.interpret(effect)

        assert not summary.success
        # Only the failing effect was run, second was skipped
        assert interpreter.failed_effects == 1

    @pytest.mark.asyncio
    async def test_parallel_success(self) -> None:
        """Parallel should execute effects concurrently."""
        interpreter = EffectInterpreter()
        effect = Parallel(
            effect_id="parallel",
            description="Parallel",
            effects=[
                Pure(effect_id="first", description="First", value=1),
                Pure(effect_id="second", description="Second", value=2),
            ],
        )

        summary = await interpreter.interpret(effect)

        assert summary.success
        assert interpreter.successful_effects == 2

    @pytest.mark.asyncio
    async def test_parallel_with_max_concurrent(self) -> None:
        """Parallel should respect max_concurrent."""
        interpreter = EffectInterpreter()
        effect = Parallel(
            effect_id="parallel",
            description="Parallel",
            effects=[
                Pure(effect_id="first", description="First", value=1),
                Pure(effect_id="second", description="Second", value=2),
                Pure(effect_id="third", description="Third", value=3),
            ],
            max_concurrent=2,
        )

        summary = await interpreter.interpret(effect)

        assert summary.success
        assert interpreter.successful_effects == 3

    @pytest.mark.asyncio
    async def test_parallel_failure(self) -> None:
        """Parallel should fail if any effect fails."""
        interpreter = EffectInterpreter()
        effect = Parallel(
            effect_id="parallel",
            description="Parallel",
            effects=[
                Pure(effect_id="success", description="Success", value=1),
                RequireLinux(effect_id="fail", description="Will fail"),
            ],
        )

        with patch("prodbox.cli.interpreter.platform_module.system", return_value="Darwin"):
            summary = await interpreter.interpret(effect)

        assert not summary.success

    @pytest.mark.asyncio
    async def test_try_primary_succeeds(self) -> None:
        """Try should use primary when it succeeds."""
        interpreter = EffectInterpreter()
        effect = Try(
            effect_id="try",
            description="Try",
            primary=Pure(effect_id="primary", description="Primary", value="primary"),
            fallback=Pure(effect_id="fallback", description="Fallback", value="fallback"),
        )

        summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == "primary"

    @pytest.mark.asyncio
    async def test_try_fallback_on_failure(self) -> None:
        """Try should use fallback when primary fails."""
        interpreter = EffectInterpreter()
        effect = Try(
            effect_id="try",
            description="Try",
            primary=RequireLinux(effect_id="primary", description="Will fail"),
            fallback=Pure(effect_id="fallback", description="Fallback", value="fallback"),
        )

        with patch("prodbox.cli.interpreter.platform_module.system", return_value="Darwin"):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == "fallback"

    @pytest.mark.asyncio
    async def test_try_both_fail(self) -> None:
        """Try should fail if both primary and fallback fail."""
        interpreter = EffectInterpreter()
        effect = Try(
            effect_id="try_both_fail",
            description="Try both fail",
            primary=RequireLinux(effect_id="primary_fail", description="Will fail"),
            fallback=RequireLinux(effect_id="fallback_fail", description="Also fails"),
        )

        with patch("prodbox.cli.interpreter.platform_module.system", return_value="Darwin"):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None

    @pytest.mark.asyncio
    async def test_sequence_empty(self) -> None:
        """Empty Sequence should succeed immediately."""
        interpreter = EffectInterpreter()
        effect = Sequence(
            effect_id="empty_seq",
            description="Empty sequence",
            effects=[],
        )

        summary = await interpreter.interpret(effect)
        assert summary.success

    @pytest.mark.asyncio
    async def test_sequence_single_element(self) -> None:
        """Single-element Sequence should execute and succeed."""
        interpreter = EffectInterpreter()
        effect = Sequence(
            effect_id="single_seq",
            description="Single sequence",
            effects=[
                Pure(effect_id="only", description="Only effect", value="only_value"),
            ],
        )

        summary = await interpreter.interpret(effect)

        assert summary.success
        assert interpreter.successful_effects == 1

    @pytest.mark.asyncio
    async def test_parallel_empty(self) -> None:
        """Empty Parallel should succeed immediately."""
        interpreter = EffectInterpreter()
        effect = Parallel(
            effect_id="empty_par",
            description="Empty parallel",
            effects=[],
        )

        summary = await interpreter.interpret(effect)
        assert summary.success

    @pytest.mark.asyncio
    async def test_parallel_single_element(self) -> None:
        """Single-element Parallel should behave like the element."""
        interpreter = EffectInterpreter()
        effect = Parallel(
            effect_id="single_par",
            description="Single parallel",
            effects=[
                Pure(effect_id="only", description="Only effect", value=42),
            ],
        )

        summary = await interpreter.interpret(effect)

        assert summary.success
        assert interpreter.successful_effects == 1

    @pytest.mark.asyncio
    async def test_sequence_of_parallels(self) -> None:
        """Sequence containing Parallel effects should execute correctly."""
        interpreter = EffectInterpreter()
        effect = Sequence(
            effect_id="seq_of_par",
            description="Sequence of parallels",
            effects=[
                Parallel(
                    effect_id="par1",
                    description="First parallel",
                    effects=[
                        Pure(effect_id="p1_a", description="P1 A", value=1),
                        Pure(effect_id="p1_b", description="P1 B", value=2),
                    ],
                ),
                Parallel(
                    effect_id="par2",
                    description="Second parallel",
                    effects=[
                        Pure(effect_id="p2_a", description="P2 A", value=3),
                        Pure(effect_id="p2_b", description="P2 B", value=4),
                    ],
                ),
            ],
        )

        summary = await interpreter.interpret(effect)

        assert summary.success
        # 4 Pure effects total
        assert interpreter.successful_effects == 4

    @pytest.mark.asyncio
    async def test_parallel_of_sequences(self) -> None:
        """Parallel containing Sequence effects should execute correctly."""
        interpreter = EffectInterpreter()
        effect = Parallel(
            effect_id="par_of_seq",
            description="Parallel of sequences",
            effects=[
                Sequence(
                    effect_id="seq1",
                    description="First sequence",
                    effects=[
                        Pure(effect_id="s1_a", description="S1 A", value=1),
                        Pure(effect_id="s1_b", description="S1 B", value=2),
                    ],
                ),
                Sequence(
                    effect_id="seq2",
                    description="Second sequence",
                    effects=[
                        Pure(effect_id="s2_a", description="S2 A", value=3),
                        Pure(effect_id="s2_b", description="S2 B", value=4),
                    ],
                ),
            ],
        )

        summary = await interpreter.interpret(effect)

        assert summary.success
        assert interpreter.successful_effects == 4

    @pytest.mark.asyncio
    async def test_sequence_with_try(self) -> None:
        """Sequence containing Try should continue after Try succeeds."""
        interpreter = EffectInterpreter()
        effect = Sequence(
            effect_id="seq_with_try",
            description="Sequence with try",
            effects=[
                Try(
                    effect_id="try_inner",
                    description="Try in sequence",
                    primary=RequireLinux(effect_id="linux", description="Require Linux"),
                    fallback=Pure(effect_id="fallback", description="Fallback", value="ok"),
                ),
                Pure(effect_id="after_try", description="After try", value="continued"),
            ],
        )

        with patch("prodbox.cli.interpreter.platform_module.system", return_value="Darwin"):
            summary = await interpreter.interpret(effect)

        # Both effects (Try with fallback, and Pure) should succeed
        assert summary.success
        assert interpreter.successful_effects >= 2

    @pytest.mark.asyncio
    async def test_parallel_with_try(self) -> None:
        """Parallel containing Try effects should handle failures gracefully."""
        interpreter = EffectInterpreter()
        effect = Parallel(
            effect_id="par_with_try",
            description="Parallel with try",
            effects=[
                Try(
                    effect_id="try1",
                    description="First try",
                    primary=RequireLinux(effect_id="linux1", description="Require Linux 1"),
                    fallback=Pure(effect_id="fb1", description="Fallback 1", value="fb1"),
                ),
                Try(
                    effect_id="try2",
                    description="Second try",
                    primary=Pure(effect_id="pure2", description="Pure 2", value="p2"),
                    fallback=Pure(effect_id="fb2", description="Fallback 2", value="fb2"),
                ),
            ],
        )

        with patch("prodbox.cli.interpreter.platform_module.system", return_value="Darwin"):
            summary = await interpreter.interpret(effect)

        # Both should succeed (one via fallback, one via primary)
        assert summary.success

    @pytest.mark.asyncio
    async def test_deeply_nested_composites(self) -> None:
        """Deeply nested composite effects (5 levels) should work correctly."""
        interpreter = EffectInterpreter()

        # Level 5 (deepest): Pure effect
        level5 = Pure(effect_id="deepest", description="Deepest", value="deep_value")

        # Level 4: Sequence containing the Pure
        level4 = Sequence(
            effect_id="level4_seq",
            description="Level 4",
            effects=[level5],
        )

        # Level 3: Parallel containing the Sequence
        level3 = Parallel(
            effect_id="level3_par",
            description="Level 3",
            effects=[level4],
        )

        # Level 2: Try with the Parallel as primary
        level2 = Try(
            effect_id="level2_try",
            description="Level 2",
            primary=level3,
            fallback=Pure(effect_id="l2_fallback", description="L2 FB", value="fallback"),
        )

        # Level 1 (top): Sequence containing the Try
        level1 = Sequence(
            effect_id="level1_seq",
            description="Level 1",
            effects=[level2],
        )

        summary = await interpreter.interpret(level1)

        # The deepest Pure effect should be executed
        assert summary.success
        assert interpreter.successful_effects >= 1

    @pytest.mark.asyncio
    async def test_sequence_stops_on_nested_failure(self) -> None:
        """Sequence should stop when a nested Parallel fails."""
        interpreter = EffectInterpreter()
        effect = Sequence(
            effect_id="seq_nested_fail",
            description="Sequence with nested failure",
            effects=[
                Parallel(
                    effect_id="par_fail",
                    description="Parallel that fails",
                    effects=[
                        Pure(effect_id="good", description="Good", value=1),
                        RequireLinux(effect_id="bad", description="Bad"),
                    ],
                ),
                Pure(effect_id="never_run", description="Never run", value="skip"),
            ],
        )

        with patch("prodbox.cli.interpreter.platform_module.system", return_value="Darwin"):
            summary = await interpreter.interpret(effect)

        assert not summary.success
        # The "never_run" Pure should not be executed

    @pytest.mark.asyncio
    async def test_parallel_all_fail(self) -> None:
        """Parallel where all effects fail should fail."""
        interpreter = EffectInterpreter()
        effect = Parallel(
            effect_id="par_all_fail",
            description="Parallel all fail",
            effects=[
                RequireLinux(effect_id="fail1", description="Fail 1"),
                RequireLinux(effect_id="fail2", description="Fail 2"),
                RequireLinux(effect_id="fail3", description="Fail 3"),
            ],
        )

        with patch("prodbox.cli.interpreter.platform_module.system", return_value="Darwin"):
            summary = await interpreter.interpret(effect)

        assert not summary.success
        assert interpreter.failed_effects >= 3

    @pytest.mark.asyncio
    async def test_sequence_executes_all(self) -> None:
        """Sequence should execute all effects in order."""
        interpreter = EffectInterpreter()
        effect = Sequence(
            effect_id="seq_all",
            description="Sequence all",
            effects=[
                Pure(effect_id="first", description="First", value="first"),
                Pure(effect_id="second", description="Second", value="second"),
                Pure(effect_id="third", description="Third", value="third"),
            ],
        )

        summary = await interpreter.interpret(effect)

        assert summary.success
        # All 3 Pure effects should be executed
        assert interpreter.successful_effects == 3


class TestEffectInterpreterSettings:
    """Tests for settings effects."""

    @pytest.mark.asyncio
    async def test_validate_settings_success(self, mock_env: dict[str, str]) -> None:
        """ValidateSettings should succeed with valid settings."""
        import os
        from unittest.mock import patch

        interpreter = EffectInterpreter()
        effect = ValidateSettings(
            effect_id="validate_settings",
            description="Validate settings",
        )

        with patch.dict(os.environ, mock_env, clear=True):
            summary = await interpreter.interpret(effect)

        assert summary.success

    @pytest.mark.asyncio
    async def test_validate_settings_failure(self) -> None:
        """ValidateSettings should fail with invalid settings."""
        import os
        from unittest.mock import patch

        interpreter = EffectInterpreter()
        effect = ValidateSettings(
            effect_id="validate_settings",
            description="Validate settings",
        )

        with patch.dict(os.environ, {}, clear=True):
            summary = await interpreter.interpret(effect)

        assert not summary.success


class TestEffectInterpreterDAG:
    """Tests for DAG interpretation."""

    @pytest.mark.asyncio
    async def test_interpret_dag_single_node(self) -> None:
        """interpret_dag should handle single node DAG."""
        interpreter = EffectInterpreter()

        node = EffectNode(
            effect=Pure(effect_id="root", description="Root", value="test"),
        )
        dag = EffectDAG(nodes=frozenset([node]), roots=frozenset(["root"]))

        summary = await interpreter.interpret_dag(dag)

        assert isinstance(summary, DAGExecutionSummary)
        assert summary.exit_code == 0
        assert summary.successful_nodes == 1
        assert summary.failed_nodes == 0

    @pytest.mark.asyncio
    async def test_interpret_dag_with_prerequisites(self) -> None:
        """interpret_dag should handle DAG with prerequisites."""
        interpreter = EffectInterpreter()

        prereq = EffectNode(
            effect=Pure(effect_id="prereq", description="Prereq", value="prereq_val"),
        )
        root = EffectNode(
            effect=Pure(effect_id="root", description="Root", value="root_val"),
            prerequisites=frozenset(["prereq"]),
        )

        dag = EffectDAG(nodes=frozenset([prereq, root]), roots=frozenset(["root"]))

        summary = await interpreter.interpret_dag(dag)

        assert summary.exit_code == 0
        assert summary.total_nodes == 2
        assert summary.successful_nodes == 2


class TestProcessOutput:
    """Tests for ProcessOutput type."""

    def test_process_output_fields(self) -> None:
        """ProcessOutput should hold all fields."""
        output = ProcessOutput(
            returncode=0,
            stdout=b"hello",
            stderr=b"",
        )
        assert output.returncode == 0
        assert output.stdout == b"hello"
        assert output.stderr == b""


class TestRunSubprocessHelper:
    """Tests for _run_subprocess helper."""

    @pytest.mark.asyncio
    async def test_run_subprocess_success(self) -> None:
        """_run_subprocess should run command successfully."""
        result = await _run_subprocess(("echo", "hello"))

        assert result.returncode == 0
        assert b"hello" in result.stdout

    @pytest.mark.asyncio
    async def test_run_subprocess_with_cwd(self) -> None:
        """_run_subprocess should use cwd."""
        result = await _run_subprocess(("pwd",), cwd=Path("/tmp"))

        assert result.returncode == 0
        # On macOS, /tmp is a symlink to /private/tmp
        assert b"tmp" in result.stdout

    @pytest.mark.asyncio
    async def test_run_subprocess_timeout(self) -> None:
        """_run_subprocess should handle timeout."""
        result = await _run_subprocess(
            ("sleep", "10"),
            timeout=0.1,
        )

        assert result.returncode == -1
        assert b"Timeout" in result.stderr


class TestEffectInterpreterSubprocess:
    """Tests for subprocess effects."""

    @pytest.mark.asyncio
    async def test_run_subprocess_effect(self) -> None:
        """RunSubprocess should execute command."""
        interpreter = EffectInterpreter()
        effect = RunSubprocess(
            effect_id="echo",
            description="Echo test",
            command=["echo", "hello"],
        )

        summary = await interpreter.interpret(effect)

        assert summary.success

    @pytest.mark.asyncio
    async def test_run_subprocess_failure(self) -> None:
        """RunSubprocess should fail on non-zero exit."""
        interpreter = EffectInterpreter()
        effect = RunSubprocess(
            effect_id="false",
            description="False command",
            command=["false"],
        )

        summary = await interpreter.interpret(effect)

        assert not summary.success

    @pytest.mark.asyncio
    async def test_capture_subprocess_output(self) -> None:
        """CaptureSubprocessOutput should capture output."""
        interpreter = EffectInterpreter()
        effect = CaptureSubprocessOutput(
            effect_id="capture",
            description="Capture output",
            command=["echo", "captured"],
        )

        summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert "captured" in str(value)


class TestEffectInterpreterCustom:
    """Tests for Custom effects."""

    @pytest.mark.asyncio
    async def test_custom_effect_sync(self) -> None:
        """Custom should run sync function."""
        interpreter = EffectInterpreter()

        def my_fn() -> str:
            return "sync result"

        effect: Custom[str] = Custom(
            effect_id="custom",
            description="Custom effect",
            fn=my_fn,
        )

        summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == "sync result"

    @pytest.mark.asyncio
    async def test_custom_effect_async(self) -> None:
        """Custom should run async function."""
        interpreter = EffectInterpreter()

        async def async_fn() -> int:
            return 42

        effect: Custom[int] = Custom(
            effect_id="async_custom",
            description="Async custom",
            fn=async_fn,
        )

        summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == 42


class TestEffectInterpreterLoadSettings:
    """Tests for LoadSettings effect."""

    @pytest.mark.asyncio
    async def test_load_settings_success(self, mock_env: dict[str, str]) -> None:
        """LoadSettings should succeed with valid env."""
        import os
        from unittest.mock import patch

        interpreter = EffectInterpreter()
        effect = LoadSettings(
            effect_id="load_settings",
            description="Load settings",
        )

        with patch.dict(os.environ, mock_env, clear=True):
            summary = await interpreter.interpret(effect)

        assert summary.success

    @pytest.mark.asyncio
    async def test_load_settings_failure(self) -> None:
        """LoadSettings should fail with missing env."""
        import os
        from unittest.mock import patch

        interpreter = EffectInterpreter()
        effect = LoadSettings(
            effect_id="load_settings",
            description="Load settings",
        )

        with patch.dict(os.environ, {}, clear=True):
            summary = await interpreter.interpret(effect)

        assert not summary.success


class TestEffectInterpreterSystemd:
    """Tests for systemd effects with mocked subprocess."""

    @pytest.mark.asyncio
    async def test_run_systemd_command_start(self) -> None:
        """RunSystemdCommand start should call systemctl start."""
        from prodbox.cli.effects import RunSystemdCommand

        interpreter = EffectInterpreter()
        effect = RunSystemdCommand(
            effect_id="start_service",
            description="Start service",
            action="start",
            service="rke2-server.service",
            sudo=True,
        )

        # Mock the subprocess call
        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.return_value = ProcessOutput(returncode=0, stdout=b"", stderr=b"")
            summary = await interpreter.interpret(effect)

        assert summary.success
        mock_run.assert_called_once()
        call = mock_run.call_args
        assert call is not None
        args: tuple[str, ...] = call[0][0]
        assert "sudo" in args
        assert "systemctl" in args
        assert "start" in args
        assert "rke2-server.service" in args

    @pytest.mark.asyncio
    async def test_run_systemd_command_status_failed(self) -> None:
        """RunSystemdCommand should handle non-zero exit."""
        from prodbox.cli.effects import RunSystemdCommand

        interpreter = EffectInterpreter()
        effect = RunSystemdCommand(
            effect_id="status_service",
            description="Check service status",
            action="status",
            service="rke2-server.service",
        )

        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.return_value = ProcessOutput(
                returncode=3, stdout=b"", stderr=b"inactive"
            )
            summary = await interpreter.interpret(effect)

        assert not summary.success
        assert interpreter.failed_effects == 1


class TestEffectInterpreterKubectl:
    """Tests for kubectl effects with mocked subprocess."""

    @pytest.mark.asyncio
    async def test_run_kubectl_get_pods(self) -> None:
        """RunKubectlCommand should execute kubectl get pods."""
        from prodbox.cli.effects import RunKubectlCommand
        from pathlib import Path

        interpreter = EffectInterpreter()
        effect = RunKubectlCommand(
            effect_id="get_pods",
            description="Get pods",
            args=["get", "pods", "-n", "default"],
            kubeconfig=Path("/etc/rancher/rke2/rke2.yaml"),
        )

        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.return_value = ProcessOutput(
                returncode=0,
                stdout=b"NAME      READY   STATUS\npod-1     1/1     Running",
                stderr=b"",
            )
            summary = await interpreter.interpret(effect)

        assert summary.success
        # Verify command was called with expected arguments
        mock_run.assert_called_once()
        call = mock_run.call_args
        assert call is not None
        args: tuple[str, ...] = call[0][0]
        assert "kubectl" in args
        assert "--kubeconfig" in args
        assert "get" in args
        assert "pods" in args

    @pytest.mark.asyncio
    async def test_capture_kubectl_output_json(self) -> None:
        """CaptureKubectlOutput should capture JSON output."""
        from prodbox.cli.effects import CaptureKubectlOutput

        interpreter = EffectInterpreter()
        effect = CaptureKubectlOutput(
            effect_id="get_nodes_json",
            description="Get nodes as JSON",
            args=["get", "nodes", "-o", "json"],
        )

        json_output = b'{"items": [{"metadata": {"name": "node1"}}]}'
        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.return_value = ProcessOutput(
                returncode=0, stdout=json_output, stderr=b""
            )
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value is not None
        assert value[1] == json_output.decode()  # stdout

    @pytest.mark.asyncio
    async def test_kubectl_timeout(self) -> None:
        """Kubectl command should handle timeout."""
        from prodbox.cli.effects import RunKubectlCommand

        interpreter = EffectInterpreter()
        effect = RunKubectlCommand(
            effect_id="kubectl_timeout",
            description="Kubectl with timeout",
            args=["get", "pods"],
            timeout=30.0,
        )

        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.return_value = ProcessOutput(
                returncode=-1, stdout=b"", stderr=b"Timeout"
            )
            summary = await interpreter.interpret(effect)

        assert not summary.success
        assert "timed out" in summary.message.lower()


class TestEffectInterpreterPulumi:
    """Tests for Pulumi effects with mocked subprocess."""

    @pytest.mark.asyncio
    async def test_pulumi_preview_success(self) -> None:
        """PulumiPreview should run pulumi preview."""
        from prodbox.cli.effects import PulumiPreview
        from pathlib import Path

        interpreter = EffectInterpreter()
        effect = PulumiPreview(
            effect_id="preview",
            description="Preview changes",
            cwd=Path("/path/to/infra"),
            stack="dev",
        )

        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.return_value = ProcessOutput(
                returncode=0, stdout=b"Resources: 5 unchanged", stderr=b""
            )
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == 0
        # Verify pulumi preview was called with correct args
        mock_run.assert_called_once()
        call = mock_run.call_args
        assert call is not None
        args: tuple[str, ...] = call[0][0]
        assert "pulumi" in args
        assert "preview" in args
        assert "--stack" in args
        assert "dev" in args

    @pytest.mark.asyncio
    async def test_pulumi_up_with_yes(self) -> None:
        """PulumiUp should pass --yes flag."""
        from prodbox.cli.effects import PulumiUp

        interpreter = EffectInterpreter()
        effect = PulumiUp(
            effect_id="up",
            description="Apply changes",
            yes=True,
        )

        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.return_value = ProcessOutput(
                returncode=0, stdout=b"Resources: 5 created", stderr=b""
            )
            summary = await interpreter.interpret(effect)

        assert summary.success
        mock_run.assert_called_once()
        call = mock_run.call_args
        assert call is not None
        args: tuple[str, ...] = call[0][0]
        assert "--yes" in args

    @pytest.mark.asyncio
    async def test_pulumi_stack_select_create(self) -> None:
        """PulumiStackSelect should pass --create flag."""
        from prodbox.cli.effects import PulumiStackSelect

        interpreter = EffectInterpreter()
        effect = PulumiStackSelect(
            effect_id="select",
            description="Select stack",
            stack="new-stack",
            create_if_missing=True,
        )

        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.return_value = ProcessOutput(returncode=0, stdout=b"", stderr=b"")
            summary = await interpreter.interpret(effect)

        assert summary.success
        mock_run.assert_called_once()
        call = mock_run.call_args
        assert call is not None
        args: tuple[str, ...] = call[0][0]
        assert "--create" in args

    @pytest.mark.asyncio
    async def test_pulumi_destroy(self) -> None:
        """PulumiDestroy should run pulumi destroy."""
        from prodbox.cli.effects import PulumiDestroy

        interpreter = EffectInterpreter()
        effect = PulumiDestroy(
            effect_id="destroy",
            description="Destroy infrastructure",
            yes=True,
        )

        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.return_value = ProcessOutput(
                returncode=0, stdout=b"Resources: 5 deleted", stderr=b""
            )
            summary = await interpreter.interpret(effect)

        assert summary.success
        mock_run.assert_called_once()
        call = mock_run.call_args
        assert call is not None
        args: tuple[str, ...] = call[0][0]
        assert "pulumi" in args
        assert "destroy" in args


class TestEffectInterpreterAWS:
    """Tests for AWS effects with mocked boto3."""

    @pytest.mark.asyncio
    async def test_validate_aws_credentials_success(self) -> None:
        """ValidateAWSCredentials should succeed with valid credentials."""
        import sys
        from prodbox.cli.effects import ValidateAWSCredentials

        interpreter = EffectInterpreter()
        effect = ValidateAWSCredentials(
            effect_id="validate_aws",
            description="Validate AWS credentials",
            aws_access_key_id="AKIAIOSFODNN7EXAMPLE",
            aws_secret_access_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            aws_region="us-east-1",
        )

        mock_boto3 = MagicMock()
        mock_session = MagicMock()
        mock_sts = MagicMock()
        mock_boto3.Session.return_value = mock_session
        mock_session.client.return_value = mock_sts
        mock_sts.get_caller_identity.return_value = {"Account": "123456789012"}

        with patch.dict(sys.modules, {"boto3": mock_boto3}):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value is True

    @pytest.mark.asyncio
    async def test_validate_aws_credentials_failure(self) -> None:
        """ValidateAWSCredentials should fail with invalid credentials."""
        import sys
        from prodbox.cli.effects import ValidateAWSCredentials

        interpreter = EffectInterpreter()
        effect = ValidateAWSCredentials(
            effect_id="validate_aws",
            description="Validate AWS credentials",
            aws_access_key_id="invalid",
            aws_secret_access_key="invalid",
            aws_region="us-east-1",
        )

        mock_boto3 = MagicMock()
        mock_session = MagicMock()
        mock_sts = MagicMock()
        mock_boto3.Session.return_value = mock_session
        mock_session.client.return_value = mock_sts
        mock_sts.get_caller_identity.side_effect = Exception("Invalid credentials")

        with patch.dict(sys.modules, {"boto3": mock_boto3}):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is False
        assert len(interpreter.environment_errors) == 1
        assert interpreter.environment_errors[0].tool == "aws"

    @pytest.mark.asyncio
    async def test_query_route53_record_found(self) -> None:
        """QueryRoute53Record should return IP when found."""
        import sys
        from prodbox.cli.effects import QueryRoute53Record

        interpreter = EffectInterpreter()
        effect = QueryRoute53Record(
            effect_id="query_dns",
            description="Query DNS",
            zone_id="Z1234567890ABC",
            fqdn="test.example.com",
            aws_access_key_id="AKIAIOSFODNN7EXAMPLE",
            aws_secret_access_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            aws_region="us-east-1",
        )

        mock_boto3 = MagicMock()
        mock_session = MagicMock()
        mock_route53 = MagicMock()
        mock_boto3.Session.return_value = mock_session
        mock_session.client.return_value = mock_route53
        mock_route53.list_resource_record_sets.return_value = {
            "ResourceRecordSets": [
                {
                    "Name": "test.example.com.",
                    "Type": "A",
                    "TTL": 300,
                    "ResourceRecords": [{"Value": "1.2.3.4"}],
                }
            ]
        }

        with patch.dict(sys.modules, {"boto3": mock_boto3}):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == "1.2.3.4"

    @pytest.mark.asyncio
    async def test_query_route53_record_not_found(self) -> None:
        """QueryRoute53Record should return None when not found."""
        import sys
        from prodbox.cli.effects import QueryRoute53Record

        interpreter = EffectInterpreter()
        effect = QueryRoute53Record(
            effect_id="query_dns",
            description="Query DNS",
            zone_id="Z1234567890ABC",
            fqdn="nonexistent.example.com",
            aws_access_key_id="AKIAIOSFODNN7EXAMPLE",
            aws_secret_access_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            aws_region="us-east-1",
        )

        mock_boto3 = MagicMock()
        mock_session = MagicMock()
        mock_route53 = MagicMock()
        mock_boto3.Session.return_value = mock_session
        mock_session.client.return_value = mock_route53
        mock_route53.list_resource_record_sets.return_value = {
            "ResourceRecordSets": []
        }

        with patch.dict(sys.modules, {"boto3": mock_boto3}):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value is None

    @pytest.mark.asyncio
    async def test_update_route53_record_success(self) -> None:
        """UpdateRoute53Record should update DNS record."""
        import sys
        from prodbox.cli.effects import UpdateRoute53Record

        interpreter = EffectInterpreter()
        effect = UpdateRoute53Record(
            effect_id="update_dns",
            description="Update DNS",
            zone_id="Z1234567890ABC",
            fqdn="test.example.com",
            ip="5.6.7.8",
            ttl=300,
            aws_access_key_id="AKIAIOSFODNN7EXAMPLE",
            aws_secret_access_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            aws_region="us-east-1",
        )

        mock_boto3 = MagicMock()
        mock_session = MagicMock()
        mock_route53 = MagicMock()
        mock_boto3.Session.return_value = mock_session
        mock_session.client.return_value = mock_route53
        mock_route53.change_resource_record_sets.return_value = {
            "ChangeInfo": {"Status": "PENDING"}
        }

        with patch.dict(sys.modules, {"boto3": mock_boto3}):
            summary = await interpreter.interpret(effect)

        assert summary.success
        mock_route53.change_resource_record_sets.assert_called_once()


class TestEffectInterpreterFetchPublicIP:
    """Tests for FetchPublicIP with mocked httpx."""

    @pytest.mark.asyncio
    async def test_fetch_public_ip_success(self) -> None:
        """FetchPublicIP should return IP address."""
        import sys
        from prodbox.cli.effects import FetchPublicIP

        interpreter = EffectInterpreter()
        effect = FetchPublicIP(
            effect_id="fetch_ip",
            description="Fetch public IP",
        )

        mock_response = MagicMock()
        mock_response.text = "203.0.113.42"
        mock_response.raise_for_status = MagicMock()

        mock_client = MagicMock()
        mock_client.get = AsyncMock(return_value=mock_response)

        mock_async_client = MagicMock()
        mock_async_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_async_client.__aexit__ = AsyncMock()

        mock_httpx = MagicMock()
        mock_httpx.AsyncClient.return_value = mock_async_client

        with patch.dict(sys.modules, {"httpx": mock_httpx}):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == "203.0.113.42"

    @pytest.mark.asyncio
    async def test_fetch_public_ip_network_error(self) -> None:
        """FetchPublicIP should handle network errors."""
        import sys
        from prodbox.cli.effects import FetchPublicIP

        interpreter = EffectInterpreter()
        effect = FetchPublicIP(
            effect_id="fetch_ip",
            description="Fetch public IP",
        )

        mock_client = MagicMock()
        mock_client.get = AsyncMock(side_effect=Exception("Network error"))

        mock_async_client = MagicMock()
        mock_async_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_async_client.__aexit__ = AsyncMock()

        mock_httpx = MagicMock()
        mock_httpx.AsyncClient.return_value = mock_async_client

        with patch.dict(sys.modules, {"httpx": mock_httpx}):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None


class TestEffectInterpreterDAGExecution:
    """Tests for DAG execution with prerequisites."""

    @pytest.mark.asyncio
    async def test_dag_with_failed_prerequisite_skips_dependent(self) -> None:
        """DAG execution should skip nodes when prerequisites fail."""
        interpreter = EffectInterpreter()

        # Prerequisite that will fail
        prereq = EffectNode(
            effect=RequireLinux(effect_id="prereq_linux", description="Require Linux"),
        )

        # Dependent node
        dependent = EffectNode(
            effect=Pure(effect_id="dependent", description="Dependent", value="ok"),
            prerequisites=frozenset(["prereq_linux"]),
        )

        dag = EffectDAG(
            nodes=frozenset([prereq, dependent]),
            roots=frozenset(["dependent"]),
        )

        with patch("prodbox.cli.interpreter.platform_module.system", return_value="Darwin"):
            summary = await interpreter.interpret_dag(dag)

        # Should fail because prerequisite failed
        assert summary.exit_code != 0
        assert summary.failed_nodes >= 1

    @pytest.mark.asyncio
    async def test_dag_parallel_execution(self) -> None:
        """DAG should execute independent nodes in parallel."""
        interpreter = EffectInterpreter()

        # Two independent nodes (no prerequisites)
        node1 = EffectNode(
            effect=Pure(effect_id="node1", description="Node 1", value=1),
        )
        node2 = EffectNode(
            effect=Pure(effect_id="node2", description="Node 2", value=2),
        )

        dag = EffectDAG(
            nodes=frozenset([node1, node2]),
            roots=frozenset(["node1", "node2"]),
        )

        summary = await interpreter.interpret_dag(dag)

        assert summary.exit_code == 0
        assert summary.successful_nodes == 2
        assert summary.total_nodes == 2


# =============================================================================
# Error Path Tests for 100% Coverage
# =============================================================================


class TestRunSubprocessTimeout:
    """Tests for subprocess timeout handling."""

    @pytest.mark.asyncio
    async def test_run_subprocess_timeout(self) -> None:
        """_run_subprocess should return timeout ProcessOutput."""
        # Create a slow command that will timeout
        with patch("prodbox.cli.interpreter.asyncio.create_subprocess_exec") as mock_exec:
            # Mock process that times out
            mock_proc = AsyncMock()
            mock_proc.communicate = AsyncMock(side_effect=TimeoutError())
            mock_proc.kill = MagicMock()
            mock_proc.wait = AsyncMock()
            mock_exec.return_value = mock_proc

            result = await _run_subprocess(("sleep", "100"), timeout=0.1)

        assert result.returncode == -1
        assert result.stderr == b"Timeout"

    @pytest.mark.asyncio
    async def test_run_subprocess_timeout_with_none_streams(self) -> None:
        """_run_subprocess should handle None stdout/stderr on timeout."""
        with patch("prodbox.cli.interpreter.asyncio.create_subprocess_exec") as mock_exec:
            mock_proc = AsyncMock()
            # communicate returns (None, None) on timeout
            mock_proc.communicate = AsyncMock(return_value=(None, None))
            mock_proc.returncode = 0
            mock_exec.return_value = mock_proc

            result = await _run_subprocess(("true",), timeout=5.0)

        # Should handle None gracefully
        assert result.stdout == b""
        assert result.stderr == b""


class TestDAGExecutionEdgeCases:
    """Tests for DAG execution error paths."""

    @pytest.mark.asyncio
    async def test_dag_exception_in_effect(self) -> None:
        """DAG should handle exceptions during effect execution."""
        interpreter = EffectInterpreter()

        # Use a custom effect that raises an exception
        async def failing_fn() -> object:
            raise ZeroDivisionError("division by zero")

        failing_effect = Custom(
            effect_id="failing_custom",
            description="Failing custom effect",
            fn=failing_fn,
        )

        node = EffectNode(effect=failing_effect)
        dag = EffectDAG(nodes=frozenset([node]), roots=frozenset(["failing_custom"]))

        summary = await interpreter.interpret_dag(dag)

        # Custom effect handles exceptions and returns failure
        assert summary.exit_code != 0 or summary.failed_nodes >= 1

    @pytest.mark.asyncio
    async def test_dag_with_prerequisite_failure_cascades(self) -> None:
        """DAG should cascade failures from prerequisites."""
        interpreter = EffectInterpreter()

        # Root prerequisite that will fail
        root_prereq = EffectNode(
            effect=RequireLinux(effect_id="platform_linux", description="Require Linux"),
        )

        # Dependent node
        dependent = EffectNode(
            effect=Pure(effect_id="dependent", description="Dependent", value="ok"),
            prerequisites=frozenset(["platform_linux"]),
        )

        dag = EffectDAG(
            nodes=frozenset([root_prereq, dependent]),
            roots=frozenset(["dependent"]),
        )

        with patch("prodbox.cli.interpreter.platform_module.system", return_value="Darwin"):
            summary = await interpreter.interpret_dag(dag)

        # Root prerequisite fails, dependent should be skipped
        assert summary.exit_code != 0


class TestWriteFileEdgeCases:
    """Tests for WriteFile effect error paths."""

    @pytest.mark.asyncio
    async def test_write_file_sudo_success(self) -> None:
        """WriteFile with sudo should succeed when subprocess succeeds."""
        interpreter = EffectInterpreter()

        effect = WriteFile(
            effect_id="write_sudo",
            description="Write with sudo",
            file_path=Path("/etc/test.conf"),
            content="test content",
            sudo=True,
        )

        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.return_value = ProcessOutput(returncode=0, stdout=b"", stderr=b"")
            summary = await interpreter.interpret(effect)

        assert summary.success

    @pytest.mark.asyncio
    async def test_write_file_sudo_failure(self) -> None:
        """WriteFile with sudo should fail when subprocess fails."""
        interpreter = EffectInterpreter()

        effect = WriteFile(
            effect_id="write_sudo",
            description="Write with sudo",
            file_path=Path("/etc/test.conf"),
            content="test content",
            sudo=True,
        )

        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.return_value = ProcessOutput(returncode=1, stdout=b"", stderr=b"Permission denied")
            summary = await interpreter.interpret(effect)

        assert not summary.success
        assert "sudo" in summary.message.lower()

    @pytest.mark.asyncio
    async def test_write_file_os_error(self) -> None:
        """WriteFile should handle OSError gracefully."""
        interpreter = EffectInterpreter()

        effect = WriteFile(
            effect_id="write_error",
            description="Write error",
            file_path=Path("/nonexistent/dir/file.txt"),
            content="test",
            sudo=False,
        )

        # Mock write_text to raise OSError
        with patch.object(Path, "write_text", side_effect=OSError("No such directory")):
            summary = await interpreter.interpret(effect)

        assert not summary.success
        assert "failed to write" in summary.message.lower()


class TestRunSubprocessEdgeCases:
    """Tests for RunSubprocess effect error paths."""

    @pytest.mark.asyncio
    async def test_run_subprocess_timeout_effect(self) -> None:
        """RunSubprocess should handle timeout from subprocess."""
        interpreter = EffectInterpreter()

        effect = RunSubprocess(
            effect_id="timeout_cmd",
            description="Timeout command",
            command=["sleep", "100"],
            timeout=0.1,
        )

        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.return_value = ProcessOutput(returncode=-1, stdout=b"", stderr=b"Timeout")
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert "timed out" in summary.message.lower()

    @pytest.mark.asyncio
    async def test_run_subprocess_os_error(self) -> None:
        """RunSubprocess should handle OSError from subprocess."""
        interpreter = EffectInterpreter()

        effect = RunSubprocess(
            effect_id="os_error_cmd",
            description="OS error command",
            command=["nonexistent_command"],
        )

        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.side_effect = OSError("Command not found")
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert "failed to run" in summary.message.lower()


class TestCaptureSubprocessOutputEdgeCases:
    """Tests for CaptureSubprocessOutput error paths."""

    @pytest.mark.asyncio
    async def test_capture_subprocess_timeout(self) -> None:
        """CaptureSubprocessOutput should handle timeout."""
        interpreter = EffectInterpreter()

        effect = CaptureSubprocessOutput(
            effect_id="capture_timeout",
            description="Capture timeout",
            command=["sleep", "100"],
            timeout=0.1,
        )

        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.return_value = ProcessOutput(returncode=-1, stdout=b"", stderr=b"Timeout")
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success

    @pytest.mark.asyncio
    async def test_capture_subprocess_os_error(self) -> None:
        """CaptureSubprocessOutput should handle OSError."""
        interpreter = EffectInterpreter()

        effect = CaptureSubprocessOutput(
            effect_id="capture_error",
            description="Capture error",
            command=["nonexistent"],
        )

        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.side_effect = OSError("Command not found")
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success


class TestKubectlWaitEdgeCases:
    """Tests for KubectlWait effect edge cases."""

    @pytest.mark.asyncio
    async def test_kubectl_wait_failure(self) -> None:
        """KubectlWait should handle wait timeout/failure."""
        from prodbox.cli.effects import KubectlWait

        interpreter = EffectInterpreter()

        effect = KubectlWait(
            effect_id="kubectl_wait",
            description="Wait for pods",
            resource="pods",
            condition="Ready",
            timeout=30,
        )

        with patch("prodbox.cli.interpreter._run_subprocess") as mock_run:
            mock_run.return_value = ProcessOutput(
                returncode=1,
                stdout=b"",
                stderr=b"timed out waiting for condition",
            )
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is False


class TestConfirmActionEdgeCases:
    """Tests for ConfirmAction effect edge cases."""

    @pytest.mark.asyncio
    async def test_confirm_action_declined_with_abort(self) -> None:
        """ConfirmAction should fail when user declines with abort_on_decline."""
        import click as click_module
        from prodbox.cli.effects import ConfirmAction

        interpreter = EffectInterpreter()

        effect = ConfirmAction(
            effect_id="confirm_abort",
            description="Confirm abort",
            message="Continue?",
            abort_on_decline=True,
        )

        with patch.object(click_module, "confirm", return_value=False):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is False

    @pytest.mark.asyncio
    async def test_confirm_action_abort_exception(self) -> None:
        """ConfirmAction should handle click.Abort exception."""
        import click as click_module
        from prodbox.cli.effects import ConfirmAction

        interpreter = EffectInterpreter()

        effect = ConfirmAction(
            effect_id="confirm_exception",
            description="Confirm exception",
            message="Continue?",
        )

        with patch.object(click_module, "confirm", side_effect=click_module.Abort()):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is False


class TestSequenceAndParallelEdgeCases:
    """Tests for composite effect edge cases."""

    @pytest.mark.asyncio
    async def test_sequence_short_circuits_on_failure(self) -> None:
        """Sequence should stop on first failure."""
        interpreter = EffectInterpreter()

        effect = Sequence(
            effect_id="seq_fail",
            description="Sequence with failure",
            effects=[
                Pure(effect_id="first", description="First", value=1),
                RequireLinux(effect_id="will_fail", description="Will fail"),
                Pure(effect_id="never", description="Never reached", value=2),
            ],
        )

        with patch("prodbox.cli.interpreter.platform_module.system", return_value="Darwin"):
            summary = await interpreter.interpret(effect)

        assert not summary.success
        # Sequence short-circuits on failure, so total effects includes sequence + executed sub-effects
        # The third Pure effect should not be executed

    @pytest.mark.asyncio
    async def test_parallel_with_max_concurrent(self) -> None:
        """Parallel should respect max_concurrent limit."""
        interpreter = EffectInterpreter()

        effect = Parallel(
            effect_id="parallel_limited",
            description="Limited parallel",
            effects=[
                Pure(effect_id=f"p{i}", description=f"Pure {i}", value=i)
                for i in range(5)
            ],
            max_concurrent=2,
        )

        summary = await interpreter.interpret(effect)

        assert summary.success
        assert interpreter.successful_effects == 5


class TestSystemdEffects:
    """Tests for systemd-related effects."""

    @pytest.mark.asyncio
    async def test_run_systemd_command_success(self) -> None:
        """RunSystemdCommand should succeed on zero exit code."""
        from prodbox.cli.effects import RunSystemdCommand

        interpreter = EffectInterpreter()
        effect = RunSystemdCommand(
            effect_id="systemd_cmd",
            description="Systemd command",
            action="status",
            service="test.service",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"active", stderr=b""),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == 0

    @pytest.mark.asyncio
    async def test_run_systemd_command_failure(self) -> None:
        """RunSystemdCommand should fail on non-zero exit code."""
        from prodbox.cli.effects import RunSystemdCommand

        interpreter = EffectInterpreter()
        effect = RunSystemdCommand(
            effect_id="systemd_cmd_fail",
            description="Systemd command fail",
            action="restart",
            service="test.service",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=1, stdout=b"", stderr=b"failed"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value == 1

    @pytest.mark.asyncio
    async def test_run_systemd_command_timeout(self) -> None:
        """RunSystemdCommand should fail on timeout."""
        from prodbox.cli.effects import RunSystemdCommand

        interpreter = EffectInterpreter()
        effect = RunSystemdCommand(
            effect_id="systemd_timeout",
            description="Systemd timeout",
            action="start",
            service="test.service",
            timeout=1.0,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=-1, stdout=b"", stderr=b"Timeout"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert "timed out" in summary.message

    @pytest.mark.asyncio
    async def test_run_systemd_command_os_error(self) -> None:
        """RunSystemdCommand should fail on OSError."""
        from prodbox.cli.effects import RunSystemdCommand

        interpreter = EffectInterpreter()
        effect = RunSystemdCommand(
            effect_id="systemd_os_error",
            description="Systemd OSError",
            action="status",
            service="test.service",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            side_effect=OSError("systemctl not found"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None

    @pytest.mark.asyncio
    async def test_run_systemd_command_with_sudo(self) -> None:
        """RunSystemdCommand should use sudo when specified."""
        from prodbox.cli.effects import RunSystemdCommand

        interpreter = EffectInterpreter()
        effect = RunSystemdCommand(
            effect_id="systemd_sudo",
            description="Systemd with sudo",
            action="restart",
            service="test.service",
            sudo=True,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"", stderr=b""),
        ) as mock_subprocess:
            summary, _ = await interpreter.interpret_with_value(effect)

        assert summary.success
        # Verify sudo was included in command
        call_args = mock_subprocess.call_args[0][0]
        assert "sudo" in call_args

    @pytest.mark.asyncio
    async def test_check_service_status_success(self) -> None:
        """CheckServiceStatus should return service status."""
        from prodbox.cli.effects import CheckServiceStatus

        interpreter = EffectInterpreter()
        effect = CheckServiceStatus(
            effect_id="check_svc",
            description="Check service",
            service="test.service",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"active\n", stderr=b""),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == "active"

    @pytest.mark.asyncio
    async def test_check_service_status_os_error(self) -> None:
        """CheckServiceStatus should fail on OSError."""
        from prodbox.cli.effects import CheckServiceStatus

        interpreter = EffectInterpreter()
        effect = CheckServiceStatus(
            effect_id="check_svc_error",
            description="Check service error",
            service="test.service",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            side_effect=OSError("systemctl not found"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None

    @pytest.mark.asyncio
    async def test_get_journal_logs_success(self) -> None:
        """GetJournalLogs should return logs."""
        from prodbox.cli.effects import GetJournalLogs

        interpreter = EffectInterpreter()
        effect = GetJournalLogs(
            effect_id="get_logs",
            description="Get logs",
            service="test.service",
            lines=100,
        )

        log_content = b"Jan 01 12:00:00 host test[123]: Test log message"
        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=log_content, stderr=b""),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert "Test log message" in value

    @pytest.mark.asyncio
    async def test_get_journal_logs_os_error(self) -> None:
        """GetJournalLogs should fail on OSError."""
        from prodbox.cli.effects import GetJournalLogs

        interpreter = EffectInterpreter()
        effect = GetJournalLogs(
            effect_id="get_logs_error",
            description="Get logs error",
            service="test.service",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            side_effect=OSError("journalctl not found"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None


class TestKubectlEffects:
    """Tests for kubectl-related effects."""

    @pytest.mark.asyncio
    async def test_run_kubectl_command_success(self) -> None:
        """RunKubectlCommand should succeed on zero exit code."""
        from prodbox.cli.effects import RunKubectlCommand

        interpreter = EffectInterpreter()
        effect = RunKubectlCommand(
            effect_id="kubectl_cmd",
            description="Kubectl command",
            args=["get", "pods"],
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"pod/nginx", stderr=b""),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == 0

    @pytest.mark.asyncio
    async def test_run_kubectl_command_failure(self) -> None:
        """RunKubectlCommand should fail on non-zero exit code."""
        from prodbox.cli.effects import RunKubectlCommand

        interpreter = EffectInterpreter()
        effect = RunKubectlCommand(
            effect_id="kubectl_fail",
            description="Kubectl fail",
            args=["get", "pods"],
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=1, stdout=b"", stderr=b"error"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value == 1

    @pytest.mark.asyncio
    async def test_run_kubectl_command_timeout(self) -> None:
        """RunKubectlCommand should fail on timeout."""
        from prodbox.cli.effects import RunKubectlCommand

        interpreter = EffectInterpreter()
        effect = RunKubectlCommand(
            effect_id="kubectl_timeout",
            description="Kubectl timeout",
            args=["get", "pods"],
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=-1, stdout=b"", stderr=b"Timeout"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert "timed out" in summary.message

    @pytest.mark.asyncio
    async def test_run_kubectl_command_os_error(self) -> None:
        """RunKubectlCommand should fail on OSError."""
        from prodbox.cli.effects import RunKubectlCommand

        interpreter = EffectInterpreter()
        effect = RunKubectlCommand(
            effect_id="kubectl_os_error",
            description="Kubectl OSError",
            args=["get", "pods"],
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            side_effect=OSError("kubectl not found"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None

    @pytest.mark.asyncio
    async def test_run_kubectl_with_namespace(self) -> None:
        """RunKubectlCommand should include namespace flag."""
        from prodbox.cli.effects import RunKubectlCommand

        interpreter = EffectInterpreter()
        effect = RunKubectlCommand(
            effect_id="kubectl_ns",
            description="Kubectl with namespace",
            args=["get", "pods"],
            namespace="test-ns",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"", stderr=b""),
        ) as mock_subprocess:
            await interpreter.interpret_with_value(effect)

        call_args = mock_subprocess.call_args[0][0]
        assert "--namespace" in call_args
        assert "test-ns" in call_args

    @pytest.mark.asyncio
    async def test_run_kubectl_failure_empty_stderr(self) -> None:
        """RunKubectlCommand failure should show exit code when stderr empty."""
        from prodbox.cli.effects import RunKubectlCommand

        interpreter = EffectInterpreter()
        effect = RunKubectlCommand(
            effect_id="kubectl_empty_stderr",
            description="Kubectl empty stderr",
            args=["get", "pods"],
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=127, stdout=b"", stderr=b""),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert "127" in summary.message or "Exit code" in summary.message

    @pytest.mark.asyncio
    async def test_capture_kubectl_output_success(self) -> None:
        """CaptureKubectlOutput should return output tuple."""
        from prodbox.cli.effects import CaptureKubectlOutput

        interpreter = EffectInterpreter()
        effect = CaptureKubectlOutput(
            effect_id="capture_kubectl",
            description="Capture kubectl",
            args=["get", "pods", "-o", "json"],
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(
                returncode=0, stdout=b'{"items": []}', stderr=b""
            ),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == (0, '{"items": []}', "")

    @pytest.mark.asyncio
    async def test_capture_kubectl_output_failure(self) -> None:
        """CaptureKubectlOutput failure should still return output."""
        from prodbox.cli.effects import CaptureKubectlOutput

        interpreter = EffectInterpreter()
        effect = CaptureKubectlOutput(
            effect_id="capture_fail",
            description="Capture fail",
            args=["get", "nonexistent"],
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(
                returncode=1, stdout=b"", stderr=b"not found"
            ),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value == (1, "", "not found")

    @pytest.mark.asyncio
    async def test_capture_kubectl_output_timeout(self) -> None:
        """CaptureKubectlOutput should fail on timeout."""
        from prodbox.cli.effects import CaptureKubectlOutput

        interpreter = EffectInterpreter()
        effect = CaptureKubectlOutput(
            effect_id="capture_timeout",
            description="Capture timeout",
            args=["get", "pods"],
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=-1, stdout=b"", stderr=b"Timeout"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None

    @pytest.mark.asyncio
    async def test_capture_kubectl_output_os_error(self) -> None:
        """CaptureKubectlOutput should fail on OSError."""
        from prodbox.cli.effects import CaptureKubectlOutput

        interpreter = EffectInterpreter()
        effect = CaptureKubectlOutput(
            effect_id="capture_os_error",
            description="Capture OSError",
            args=["get", "pods"],
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            side_effect=OSError("kubectl not found"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None

    @pytest.mark.asyncio
    async def test_capture_kubectl_with_namespace(self) -> None:
        """CaptureKubectlOutput should include namespace flag."""
        from prodbox.cli.effects import CaptureKubectlOutput

        interpreter = EffectInterpreter()
        effect = CaptureKubectlOutput(
            effect_id="capture_ns",
            description="Capture with namespace",
            args=["get", "pods"],
            namespace="kube-system",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"", stderr=b""),
        ) as mock_subprocess:
            await interpreter.interpret_with_value(effect)

        call_args = mock_subprocess.call_args[0][0]
        assert "--namespace" in call_args
        assert "kube-system" in call_args

    @pytest.mark.asyncio
    async def test_kubectl_wait_success(self) -> None:
        """KubectlWait should succeed when condition met."""
        from prodbox.cli.effects import KubectlWait

        interpreter = EffectInterpreter()
        effect = KubectlWait(
            effect_id="kubectl_wait",
            description="Kubectl wait",
            resource="deployment/nginx",
            condition="available",
            timeout=60,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(
                returncode=0, stdout=b"condition met", stderr=b""
            ),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value is True

    @pytest.mark.asyncio
    async def test_kubectl_wait_failure(self) -> None:
        """KubectlWait should fail when timeout."""
        from prodbox.cli.effects import KubectlWait

        interpreter = EffectInterpreter()
        effect = KubectlWait(
            effect_id="kubectl_wait_fail",
            description="Kubectl wait fail",
            resource="deployment/nginx",
            condition="available",
            timeout=30,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(
                returncode=1, stdout=b"", stderr=b"timed out waiting"
            ),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is False

    @pytest.mark.asyncio
    async def test_kubectl_wait_with_options(self) -> None:
        """KubectlWait should include all options."""
        from prodbox.cli.effects import KubectlWait
        from pathlib import Path

        interpreter = EffectInterpreter()
        effect = KubectlWait(
            effect_id="kubectl_wait_opts",
            description="Kubectl wait with options",
            resource="pods",
            condition="ready",
            timeout=60,
            namespace="test-ns",
            kubeconfig=Path("/path/to/kubeconfig"),
            all_resources=True,
            selector="app=nginx",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"", stderr=b""),
        ) as mock_subprocess:
            await interpreter.interpret_with_value(effect)

        call_args = mock_subprocess.call_args[0][0]
        assert "--namespace" in call_args
        assert "--kubeconfig" in call_args
        assert "--all" in call_args
        assert "--selector" in call_args


class TestRoute53Effects:
    """Tests for Route53/DNS-related effects."""

    @pytest.mark.asyncio
    async def test_fetch_public_ip_success(self) -> None:
        """FetchPublicIP should return IP address."""
        from prodbox.cli.effects import FetchPublicIP

        interpreter = EffectInterpreter()
        effect = FetchPublicIP(
            effect_id="fetch_ip",
            description="Fetch public IP",
        )

        mock_response = MagicMock()
        mock_response.text = "1.2.3.4"
        mock_response.raise_for_status = MagicMock()

        mock_client = AsyncMock()
        mock_client.get = AsyncMock(return_value=mock_response)
        mock_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client.__aexit__ = AsyncMock(return_value=None)

        with patch("httpx.AsyncClient", return_value=mock_client):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == "1.2.3.4"

    @pytest.mark.asyncio
    async def test_fetch_public_ip_failure(self) -> None:
        """FetchPublicIP should fail on network error."""
        from prodbox.cli.effects import FetchPublicIP

        interpreter = EffectInterpreter()
        effect = FetchPublicIP(
            effect_id="fetch_ip_fail",
            description="Fetch public IP fail",
        )

        mock_client = AsyncMock()
        mock_client.get = AsyncMock(side_effect=Exception("Network error"))
        mock_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client.__aexit__ = AsyncMock(return_value=None)

        with patch("httpx.AsyncClient", return_value=mock_client):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None

    @pytest.mark.asyncio
    async def test_query_route53_record_found(self) -> None:
        """QueryRoute53Record should return IP when record found."""
        from prodbox.cli.effects import QueryRoute53Record

        interpreter = EffectInterpreter()
        effect = QueryRoute53Record(
            effect_id="query_r53",
            description="Query Route53",
            zone_id="Z123456789",
            fqdn="test.example.com",
            aws_access_key_id="AKIATEST",
            aws_secret_access_key="secret",
            aws_region="us-east-1",
        )

        mock_client = MagicMock()
        mock_client.list_resource_record_sets.return_value = {
            "ResourceRecordSets": [
                {
                    "Name": "test.example.com.",
                    "Type": "A",
                    "ResourceRecords": [{"Value": "1.2.3.4"}],
                }
            ]
        }

        mock_session = MagicMock()
        mock_session.client.return_value = mock_client

        with patch("boto3.Session", return_value=mock_session):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == "1.2.3.4"

    @pytest.mark.asyncio
    async def test_query_route53_record_not_found(self) -> None:
        """QueryRoute53Record should return None when no record."""
        from prodbox.cli.effects import QueryRoute53Record

        interpreter = EffectInterpreter()
        effect = QueryRoute53Record(
            effect_id="query_r53_empty",
            description="Query Route53 empty",
            zone_id="Z123456789",
            fqdn="nonexistent.example.com",
            aws_access_key_id="AKIATEST",
            aws_secret_access_key="secret",
            aws_region="us-east-1",
        )

        mock_client = MagicMock()
        mock_client.list_resource_record_sets.return_value = {
            "ResourceRecordSets": []
        }

        mock_session = MagicMock()
        mock_session.client.return_value = mock_client

        with patch("boto3.Session", return_value=mock_session):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value is None

    @pytest.mark.asyncio
    async def test_query_route53_record_failure(self) -> None:
        """QueryRoute53Record should fail on API error."""
        from prodbox.cli.effects import QueryRoute53Record

        interpreter = EffectInterpreter()
        effect = QueryRoute53Record(
            effect_id="query_r53_fail",
            description="Query Route53 fail",
            zone_id="Z123456789",
            fqdn="test.example.com",
            aws_access_key_id="AKIATEST",
            aws_secret_access_key="secret",
            aws_region="us-east-1",
        )

        mock_client = MagicMock()
        mock_client.list_resource_record_sets.side_effect = Exception("AWS error")

        mock_session = MagicMock()
        mock_session.client.return_value = mock_client

        with patch("boto3.Session", return_value=mock_session):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None

    @pytest.mark.asyncio
    async def test_update_route53_record_success(self) -> None:
        """UpdateRoute53Record should succeed on successful update."""
        from prodbox.cli.effects import UpdateRoute53Record

        interpreter = EffectInterpreter()
        effect = UpdateRoute53Record(
            effect_id="update_r53",
            description="Update Route53",
            zone_id="Z123456789",
            fqdn="test.example.com",
            ip="5.6.7.8",
            ttl=300,
            aws_access_key_id="AKIATEST",
            aws_secret_access_key="secret",
            aws_region="us-east-1",
        )

        mock_client = MagicMock()
        mock_client.change_resource_record_sets.return_value = {"ChangeInfo": {"Status": "PENDING"}}

        mock_session = MagicMock()
        mock_session.client.return_value = mock_client

        with patch("boto3.Session", return_value=mock_session):
            summary = await interpreter.interpret(effect)

        assert summary.success

    @pytest.mark.asyncio
    async def test_update_route53_record_failure(self) -> None:
        """UpdateRoute53Record should fail on API error."""
        from prodbox.cli.effects import UpdateRoute53Record

        interpreter = EffectInterpreter()
        effect = UpdateRoute53Record(
            effect_id="update_r53_fail",
            description="Update Route53 fail",
            zone_id="Z123456789",
            fqdn="test.example.com",
            ip="5.6.7.8",
            ttl=300,
            aws_access_key_id="AKIATEST",
            aws_secret_access_key="secret",
            aws_region="us-east-1",
        )

        mock_client = MagicMock()
        mock_client.change_resource_record_sets.side_effect = Exception("AWS error")

        mock_session = MagicMock()
        mock_session.client.return_value = mock_client

        with patch("boto3.Session", return_value=mock_session):
            summary = await interpreter.interpret(effect)

        assert not summary.success

    @pytest.mark.asyncio
    async def test_validate_aws_credentials_success(self) -> None:
        """ValidateAWSCredentials should succeed with valid creds."""
        from prodbox.cli.effects import ValidateAWSCredentials

        interpreter = EffectInterpreter()
        effect = ValidateAWSCredentials(
            effect_id="validate_aws",
            description="Validate AWS",
            aws_access_key_id="AKIATEST",
            aws_secret_access_key="secret",
            aws_region="us-east-1",
        )

        mock_sts = MagicMock()
        mock_sts.get_caller_identity.return_value = {
            "UserId": "AIDATEST",
            "Account": "123456789012",
            "Arn": "arn:aws:iam::123456789012:user/test",
        }

        mock_session = MagicMock()
        mock_session.client.return_value = mock_sts

        with patch("boto3.Session", return_value=mock_session):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value is True

    @pytest.mark.asyncio
    async def test_validate_aws_credentials_failure(self) -> None:
        """ValidateAWSCredentials should fail with invalid creds."""
        from prodbox.cli.effects import ValidateAWSCredentials

        interpreter = EffectInterpreter()
        effect = ValidateAWSCredentials(
            effect_id="validate_aws_fail",
            description="Validate AWS fail",
            aws_access_key_id="AKIAINVALID",
            aws_secret_access_key="invalid",
            aws_region="us-east-1",
        )

        mock_sts = MagicMock()
        mock_sts.get_caller_identity.side_effect = Exception("Invalid credentials")

        mock_session = MagicMock()
        mock_session.client.return_value = mock_sts

        with patch("boto3.Session", return_value=mock_session):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is False
        # Should add environment error
        assert len(interpreter.environment_errors) == 1


class TestPulumiEffects:
    """Tests for Pulumi-related effects."""

    @pytest.mark.asyncio
    async def test_run_pulumi_command_success(self) -> None:
        """RunPulumiCommand should succeed on zero exit code."""
        from prodbox.cli.effects import RunPulumiCommand

        interpreter = EffectInterpreter()
        effect = RunPulumiCommand(
            effect_id="pulumi_cmd",
            description="Pulumi command",
            args=["stack", "ls"],
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"dev", stderr=b""),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == 0

    @pytest.mark.asyncio
    async def test_run_pulumi_command_failure(self) -> None:
        """RunPulumiCommand should fail on non-zero exit code."""
        from prodbox.cli.effects import RunPulumiCommand

        interpreter = EffectInterpreter()
        effect = RunPulumiCommand(
            effect_id="pulumi_fail",
            description="Pulumi fail",
            args=["stack", "ls"],
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=1, stdout=b"", stderr=b"error"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value == 1

    @pytest.mark.asyncio
    async def test_run_pulumi_command_timeout(self) -> None:
        """RunPulumiCommand should fail on timeout."""
        from prodbox.cli.effects import RunPulumiCommand

        interpreter = EffectInterpreter()
        effect = RunPulumiCommand(
            effect_id="pulumi_timeout",
            description="Pulumi timeout",
            args=["up"],
            timeout=60.0,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=-1, stdout=b"", stderr=b"Timeout"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert "timed out" in summary.message

    @pytest.mark.asyncio
    async def test_run_pulumi_command_os_error(self) -> None:
        """RunPulumiCommand should fail on OSError."""
        from prodbox.cli.effects import RunPulumiCommand

        interpreter = EffectInterpreter()
        effect = RunPulumiCommand(
            effect_id="pulumi_os_error",
            description="Pulumi OSError",
            args=["stack", "ls"],
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            side_effect=OSError("pulumi not found"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None

    @pytest.mark.asyncio
    async def test_run_pulumi_command_empty_stderr(self) -> None:
        """RunPulumiCommand failure should show exit code when stderr empty."""
        from prodbox.cli.effects import RunPulumiCommand

        interpreter = EffectInterpreter()
        effect = RunPulumiCommand(
            effect_id="pulumi_empty_stderr",
            description="Pulumi empty stderr",
            args=["up"],
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=2, stdout=b"", stderr=b""),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert "2" in summary.message or "Exit code" in summary.message

    @pytest.mark.asyncio
    async def test_pulumi_stack_select_success(self) -> None:
        """PulumiStackSelect should succeed."""
        from prodbox.cli.effects import PulumiStackSelect

        interpreter = EffectInterpreter()
        effect = PulumiStackSelect(
            effect_id="stack_select",
            description="Stack select",
            stack="dev",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"", stderr=b""),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value is True

    @pytest.mark.asyncio
    async def test_pulumi_stack_select_failure(self) -> None:
        """PulumiStackSelect should fail on error."""
        from prodbox.cli.effects import PulumiStackSelect

        interpreter = EffectInterpreter()
        effect = PulumiStackSelect(
            effect_id="stack_select_fail",
            description="Stack select fail",
            stack="nonexistent",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(
                returncode=1, stdout=b"", stderr=b"stack not found"
            ),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is False

    @pytest.mark.asyncio
    async def test_pulumi_stack_select_with_create(self) -> None:
        """PulumiStackSelect should include --create flag."""
        from prodbox.cli.effects import PulumiStackSelect

        interpreter = EffectInterpreter()
        effect = PulumiStackSelect(
            effect_id="stack_select_create",
            description="Stack select with create",
            stack="new-stack",
            create_if_missing=True,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"", stderr=b""),
        ) as mock_subprocess:
            await interpreter.interpret_with_value(effect)

        call_args = mock_subprocess.call_args[0][0]
        assert "--create" in call_args

    @pytest.mark.asyncio
    async def test_pulumi_stack_select_os_error(self) -> None:
        """PulumiStackSelect should fail on OSError."""
        from prodbox.cli.effects import PulumiStackSelect

        interpreter = EffectInterpreter()
        effect = PulumiStackSelect(
            effect_id="stack_select_os_error",
            description="Stack select OSError",
            stack="dev",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            side_effect=OSError("pulumi not found"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is False

    @pytest.mark.asyncio
    async def test_pulumi_preview_success(self) -> None:
        """PulumiPreview should succeed."""
        from prodbox.cli.effects import PulumiPreview

        interpreter = EffectInterpreter()
        effect = PulumiPreview(
            effect_id="preview",
            description="Preview",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"preview output", stderr=b""),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == 0

    @pytest.mark.asyncio
    async def test_pulumi_preview_failure(self) -> None:
        """PulumiPreview should fail on error."""
        from prodbox.cli.effects import PulumiPreview

        interpreter = EffectInterpreter()
        effect = PulumiPreview(
            effect_id="preview_fail",
            description="Preview fail",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=1, stdout=b"", stderr=b"preview error"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value == 1

    @pytest.mark.asyncio
    async def test_pulumi_preview_with_stack(self) -> None:
        """PulumiPreview should include --stack flag."""
        from prodbox.cli.effects import PulumiPreview

        interpreter = EffectInterpreter()
        effect = PulumiPreview(
            effect_id="preview_stack",
            description="Preview with stack",
            stack="prod",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"", stderr=b""),
        ) as mock_subprocess:
            await interpreter.interpret_with_value(effect)

        call_args = mock_subprocess.call_args[0][0]
        assert "--stack" in call_args
        assert "prod" in call_args

    @pytest.mark.asyncio
    async def test_pulumi_preview_os_error(self) -> None:
        """PulumiPreview should fail on OSError."""
        from prodbox.cli.effects import PulumiPreview

        interpreter = EffectInterpreter()
        effect = PulumiPreview(
            effect_id="preview_os_error",
            description="Preview OSError",
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            side_effect=OSError("pulumi not found"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None

    @pytest.mark.asyncio
    async def test_pulumi_up_success(self) -> None:
        """PulumiUp should succeed."""
        from prodbox.cli.effects import PulumiUp

        interpreter = EffectInterpreter()
        effect = PulumiUp(
            effect_id="up",
            description="Up",
            yes=True,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"deployed", stderr=b""),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == 0

    @pytest.mark.asyncio
    async def test_pulumi_up_failure(self) -> None:
        """PulumiUp should fail on error."""
        from prodbox.cli.effects import PulumiUp

        interpreter = EffectInterpreter()
        effect = PulumiUp(
            effect_id="up_fail",
            description="Up fail",
            yes=True,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=1, stdout=b"", stderr=b"deploy failed"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value == 1

    @pytest.mark.asyncio
    async def test_pulumi_up_with_stack(self) -> None:
        """PulumiUp should include --stack flag."""
        from prodbox.cli.effects import PulumiUp

        interpreter = EffectInterpreter()
        effect = PulumiUp(
            effect_id="up_stack",
            description="Up with stack",
            stack="prod",
            yes=True,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"", stderr=b""),
        ) as mock_subprocess:
            await interpreter.interpret_with_value(effect)

        call_args = mock_subprocess.call_args[0][0]
        assert "--stack" in call_args
        assert "prod" in call_args

    @pytest.mark.asyncio
    async def test_pulumi_up_os_error(self) -> None:
        """PulumiUp should fail on OSError."""
        from prodbox.cli.effects import PulumiUp

        interpreter = EffectInterpreter()
        effect = PulumiUp(
            effect_id="up_os_error",
            description="Up OSError",
            yes=True,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            side_effect=OSError("pulumi not found"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None

    @pytest.mark.asyncio
    async def test_pulumi_destroy_success(self) -> None:
        """PulumiDestroy should succeed."""
        from prodbox.cli.effects import PulumiDestroy

        interpreter = EffectInterpreter()
        effect = PulumiDestroy(
            effect_id="destroy",
            description="Destroy",
            yes=True,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"destroyed", stderr=b""),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == 0

    @pytest.mark.asyncio
    async def test_pulumi_destroy_failure(self) -> None:
        """PulumiDestroy should fail on error."""
        from prodbox.cli.effects import PulumiDestroy

        interpreter = EffectInterpreter()
        effect = PulumiDestroy(
            effect_id="destroy_fail",
            description="Destroy fail",
            yes=True,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=1, stdout=b"", stderr=b"destroy failed"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value == 1

    @pytest.mark.asyncio
    async def test_pulumi_destroy_with_stack(self) -> None:
        """PulumiDestroy should include --stack flag."""
        from prodbox.cli.effects import PulumiDestroy

        interpreter = EffectInterpreter()
        effect = PulumiDestroy(
            effect_id="destroy_stack",
            description="Destroy with stack",
            stack="staging",
            yes=True,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"", stderr=b""),
        ) as mock_subprocess:
            await interpreter.interpret_with_value(effect)

        call_args = mock_subprocess.call_args[0][0]
        assert "--stack" in call_args
        assert "staging" in call_args

    @pytest.mark.asyncio
    async def test_pulumi_destroy_os_error(self) -> None:
        """PulumiDestroy should fail on OSError."""
        from prodbox.cli.effects import PulumiDestroy

        interpreter = EffectInterpreter()
        effect = PulumiDestroy(
            effect_id="destroy_os_error",
            description="Destroy OSError",
            yes=True,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            side_effect=OSError("pulumi not found"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None

    @pytest.mark.asyncio
    async def test_pulumi_refresh_success(self) -> None:
        """PulumiRefresh should succeed."""
        from prodbox.cli.effects import PulumiRefresh

        interpreter = EffectInterpreter()
        effect = PulumiRefresh(
            effect_id="refresh",
            description="Refresh",
            yes=True,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"refreshed", stderr=b""),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value == 0

    @pytest.mark.asyncio
    async def test_pulumi_refresh_failure(self) -> None:
        """PulumiRefresh should fail on error."""
        from prodbox.cli.effects import PulumiRefresh

        interpreter = EffectInterpreter()
        effect = PulumiRefresh(
            effect_id="refresh_fail",
            description="Refresh fail",
            yes=True,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=1, stdout=b"", stderr=b"refresh failed"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value == 1

    @pytest.mark.asyncio
    async def test_pulumi_refresh_with_stack(self) -> None:
        """PulumiRefresh should include --stack flag."""
        from prodbox.cli.effects import PulumiRefresh

        interpreter = EffectInterpreter()
        effect = PulumiRefresh(
            effect_id="refresh_stack",
            description="Refresh with stack",
            stack="dev",
            yes=True,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"", stderr=b""),
        ) as mock_subprocess:
            await interpreter.interpret_with_value(effect)

        call_args = mock_subprocess.call_args[0][0]
        assert "--stack" in call_args
        assert "dev" in call_args

    @pytest.mark.asyncio
    async def test_pulumi_refresh_os_error(self) -> None:
        """PulumiRefresh should fail on OSError."""
        from prodbox.cli.effects import PulumiRefresh

        interpreter = EffectInterpreter()
        effect = PulumiRefresh(
            effect_id="refresh_os_error",
            description="Refresh OSError",
            yes=True,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            side_effect=OSError("pulumi not found"),
        ):
            summary, value = await interpreter.interpret_with_value(effect)

        assert not summary.success
        assert value is None


class TestDAGExecutionEdgeCases:
    """Tests for DAG execution edge cases."""

    @pytest.mark.asyncio
    async def test_dag_node_execution_exception(self) -> None:
        """DAG execution should handle exceptions in node execution."""
        interpreter = EffectInterpreter()

        # Create a custom effect that raises an exception
        def raise_error() -> str:
            raise RuntimeError("Node execution failed")

        effect = Custom(
            effect_id="failing_custom",
            description="Failing custom effect",
            fn=raise_error,
        )

        node = EffectNode(effect=effect)
        dag = EffectDAG(nodes=frozenset([node]), roots=frozenset(["failing_custom"]))

        summary = await interpreter.interpret_dag(dag)

        # DAG should complete but with failure
        assert summary.exit_code == 1
        assert summary.failed_nodes == 1

    @pytest.mark.asyncio
    async def test_dag_node_with_unexecuted_prerequisite(self) -> None:
        """Test _execute_node when prerequisite hasn't been executed yet (None case)."""
        from prodbox.cli.types import Success, Failure

        interpreter = EffectInterpreter()

        # Test the _execute_node method directly with empty prereq_results
        effect = Pure(
            effect_id="test_node",
            description="Test node",
            value="test",
        )
        node = EffectNode(
            effect=effect,
            prerequisites=frozenset(["missing_prereq"]),
        )

        # Call _execute_node directly with prereq_results missing the prerequisite
        prereq_results: dict[str, Success[object] | Failure[str]] = {}
        summary, value = await interpreter._execute_node(node, prereq_results)

        # Node should be skipped due to missing prerequisite
        assert not summary.success
        assert "missing prerequisite" in summary.message.lower()
        assert interpreter.skipped_effects == 1

    @pytest.mark.asyncio
    async def test_dag_execution_with_failed_prerequisite(self) -> None:
        """DAG node should be skipped when prerequisite failed."""
        interpreter = EffectInterpreter()

        # Create failing prerequisite node
        prereq_effect = RequireLinux(
            effect_id="prereq_linux",
            description="Require Linux prereq",
        )
        prereq_node = EffectNode(effect=prereq_effect)

        # Create dependent node
        dependent_effect = Pure(
            effect_id="dependent",
            description="Dependent",
            value="test",
        )
        dependent_node = EffectNode(
            effect=dependent_effect,
            prerequisites=frozenset(["prereq_linux"]),
        )

        dag = EffectDAG(
            nodes=frozenset([prereq_node, dependent_node]),
            roots=frozenset(["dependent"]),
        )

        with patch("prodbox.cli.interpreter.platform_module.system", return_value="Darwin"):
            summary = await interpreter.interpret_dag(dag)

        # Dependent node should be skipped due to failed prerequisite
        assert interpreter.skipped_effects >= 1

    @pytest.mark.asyncio
    async def test_dag_execution_root_failure(self) -> None:
        """DAG execution should fail if root node fails."""
        interpreter = EffectInterpreter()

        effect = RequireLinux(
            effect_id="root_linux",
            description="Root Linux requirement",
        )
        node = EffectNode(effect=effect)
        dag = EffectDAG(nodes=frozenset([node]), roots=frozenset(["root_linux"]))

        with patch("prodbox.cli.interpreter.platform_module.system", return_value="Darwin"):
            summary = await interpreter.interpret_dag(dag)

        assert summary.exit_code == 1

    @pytest.mark.asyncio
    async def test_confirm_action_success_confirmed(self) -> None:
        """ConfirmAction should succeed when user confirms."""
        import click as click_module
        from prodbox.cli.effects import ConfirmAction

        interpreter = EffectInterpreter()
        effect = ConfirmAction(
            effect_id="confirm_success",
            description="Confirm success",
            message="Continue?",
        )

        with patch.object(click_module, "confirm", return_value=True):
            summary, value = await interpreter.interpret_with_value(effect)

        assert summary.success
        assert value is True

    @pytest.mark.asyncio
    async def test_confirm_action_declined_no_abort(self) -> None:
        """ConfirmAction should succeed but return False when declined without abort."""
        import click as click_module
        from prodbox.cli.effects import ConfirmAction

        interpreter = EffectInterpreter()
        effect = ConfirmAction(
            effect_id="confirm_no_abort",
            description="Confirm no abort",
            message="Continue?",
            abort_on_decline=False,
        )

        with patch.object(click_module, "confirm", return_value=False):
            summary, value = await interpreter.interpret_with_value(effect)

        # When abort_on_decline is False, declining should succeed
        assert summary.success
        assert value is False


class TestDAGExceptionHandling:
    """Tests for DAG exception handling during node execution."""

    @pytest.mark.asyncio
    async def test_dag_node_raises_exception(self) -> None:
        """DAG should handle exceptions from node execution gracefully."""
        import asyncio

        interpreter = EffectInterpreter()

        # Create a custom effect that raises an exception during execution
        async def raise_runtime_error() -> str:
            raise RuntimeError("Unexpected error during execution")

        effect = Custom(
            effect_id="exception_node",
            description="Exception throwing node",
            fn=raise_runtime_error,
        )

        node = EffectNode(effect=effect)
        dag = EffectDAG(nodes=frozenset([node]), roots=frozenset(["exception_node"]))

        summary = await interpreter.interpret_dag(dag)

        # DAG should complete with failure
        assert summary.exit_code == 1
        assert summary.failed_nodes == 1

    @pytest.mark.asyncio
    async def test_dag_node_unhandled_exception_in_execute_node(self) -> None:
        """DAG should handle BaseException from _execute_node via asyncio.gather."""
        interpreter = EffectInterpreter()

        effect = Pure(
            effect_id="test_node",
            description="Test node",
            value="test",
        )
        node = EffectNode(effect=effect)
        dag = EffectDAG(nodes=frozenset([node]), roots=frozenset(["test_node"]))

        # Mock _execute_node to raise an unhandled exception
        async def mock_execute_node_raises(*args: object, **kwargs: object) -> None:
            raise RuntimeError("Unhandled exception in _execute_node")

        with patch.object(
            interpreter, "_execute_node", side_effect=mock_execute_node_raises
        ):
            summary = await interpreter.interpret_dag(dag)

        # DAG should handle the exception gracefully
        assert summary.exit_code == 1
        # The exception should be recorded as a failure
        assert summary.failed_nodes == 1

    @pytest.mark.asyncio
    async def test_dag_multiple_nodes_one_exception(self) -> None:
        """DAG should handle exception in one node while others succeed."""
        import asyncio

        interpreter = EffectInterpreter()

        # Success node
        success_effect = Pure(
            effect_id="success_node",
            description="Success node",
            value="success",
        )
        success_node = EffectNode(effect=success_effect)

        # Exception-throwing node
        async def raise_error() -> str:
            raise ValueError("Node error")

        error_effect = Custom(
            effect_id="error_node",
            description="Error node",
            fn=raise_error,
        )
        error_node = EffectNode(effect=error_effect)

        dag = EffectDAG(
            nodes=frozenset([success_node, error_node]),
            roots=frozenset(["success_node", "error_node"]),
        )

        summary = await interpreter.interpret_dag(dag)

        # DAG should complete but exit code depends on root failures
        assert summary.total_nodes == 2
        assert summary.failed_nodes >= 1


class TestPrintSectionOptions:
    """Tests for PrintSection with blank line options."""

    @pytest.mark.asyncio
    async def test_print_section_no_blanks(self) -> None:
        """PrintSection should work without blank lines."""
        from prodbox.cli.effects import PrintSection

        interpreter = EffectInterpreter()
        effect = PrintSection(
            effect_id="section_no_blanks",
            description="Section no blanks",
            title="Test Section",
            blank_before=False,
            blank_after=False,
        )

        summary = await interpreter.interpret(effect)
        assert summary.success

    @pytest.mark.asyncio
    async def test_print_section_with_blank_before(self) -> None:
        """PrintSection should print blank line before when configured."""
        from prodbox.cli.effects import PrintSection

        interpreter = EffectInterpreter()
        effect = PrintSection(
            effect_id="section_blank_before",
            description="Section blank before",
            title="Test Section",
            blank_before=True,
            blank_after=False,
        )

        summary = await interpreter.interpret(effect)
        assert summary.success

    @pytest.mark.asyncio
    async def test_print_section_with_blank_after(self) -> None:
        """PrintSection should print blank line after when configured."""
        from prodbox.cli.effects import PrintSection

        interpreter = EffectInterpreter()
        effect = PrintSection(
            effect_id="section_blank_after",
            description="Section blank after",
            title="Test Section",
            blank_before=False,
            blank_after=True,
        )

        summary = await interpreter.interpret(effect)
        assert summary.success


class TestKubectlOptions:
    """Tests for kubectl effects with various options."""

    @pytest.mark.asyncio
    async def test_capture_kubectl_with_kubeconfig(self) -> None:
        """CaptureKubectlOutput should include kubeconfig flag."""
        from prodbox.cli.effects import CaptureKubectlOutput
        from pathlib import Path

        interpreter = EffectInterpreter()
        effect = CaptureKubectlOutput(
            effect_id="capture_kubeconfig",
            description="Capture with kubeconfig",
            args=["get", "pods"],
            kubeconfig=Path("/custom/kubeconfig"),
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"", stderr=b""),
        ) as mock_subprocess:
            await interpreter.interpret_with_value(effect)

        call_args = mock_subprocess.call_args[0][0]
        assert "--kubeconfig" in call_args

    @pytest.mark.asyncio
    async def test_run_kubectl_with_kubeconfig(self) -> None:
        """RunKubectlCommand should include kubeconfig flag."""
        from prodbox.cli.effects import RunKubectlCommand
        from pathlib import Path

        interpreter = EffectInterpreter()
        effect = RunKubectlCommand(
            effect_id="kubectl_kubeconfig",
            description="Kubectl with kubeconfig",
            args=["get", "pods"],
            kubeconfig=Path("/custom/kubeconfig"),
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"", stderr=b""),
        ) as mock_subprocess:
            await interpreter.interpret_with_value(effect)

        call_args = mock_subprocess.call_args[0][0]
        assert "--kubeconfig" in call_args


class TestPulumiOptions:
    """Tests for Pulumi effects with various options."""

    @pytest.mark.asyncio
    async def test_pulumi_up_without_yes(self) -> None:
        """PulumiUp without --yes should not include flag."""
        from prodbox.cli.effects import PulumiUp

        interpreter = EffectInterpreter()
        effect = PulumiUp(
            effect_id="up_no_yes",
            description="Up without yes",
            yes=False,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"", stderr=b""),
        ) as mock_subprocess:
            await interpreter.interpret_with_value(effect)

        call_args = mock_subprocess.call_args[0][0]
        assert "--yes" not in call_args

    @pytest.mark.asyncio
    async def test_pulumi_destroy_without_yes(self) -> None:
        """PulumiDestroy without --yes should not include flag."""
        from prodbox.cli.effects import PulumiDestroy

        interpreter = EffectInterpreter()
        effect = PulumiDestroy(
            effect_id="destroy_no_yes",
            description="Destroy without yes",
            yes=False,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"", stderr=b""),
        ) as mock_subprocess:
            await interpreter.interpret_with_value(effect)

        call_args = mock_subprocess.call_args[0][0]
        assert "--yes" not in call_args

    @pytest.mark.asyncio
    async def test_pulumi_refresh_without_yes(self) -> None:
        """PulumiRefresh without --yes should not include flag."""
        from prodbox.cli.effects import PulumiRefresh

        interpreter = EffectInterpreter()
        effect = PulumiRefresh(
            effect_id="refresh_no_yes",
            description="Refresh without yes",
            yes=False,
        )

        with patch(
            "prodbox.cli.interpreter._run_subprocess",
            new_callable=AsyncMock,
            return_value=ProcessOutput(returncode=0, stdout=b"", stderr=b""),
        ) as mock_subprocess:
            await interpreter.interpret_with_value(effect)

        call_args = mock_subprocess.call_args[0][0]
        assert "--yes" not in call_args
