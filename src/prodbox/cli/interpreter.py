"""
Effect Interpreter for executing declarative Effect specifications.

The interpreter pattern-matches on Effect types and executes them, managing:
- Execution metrics (total/successful/failed effects)
- Error accumulation (for ExecutionSummary)
- Result propagation (prerequisite Results flow to dependents)

Architecture:
    Command → Effect DAG → Interpreter → ExecutionSummary

This is the ONLY place where side effects are executed. All other code
must be pure (see documents/pure_fp_standards.md).

Example:
    >>> interpreter = EffectInterpreter()
    >>> effect = Sequence(
    ...     effect_id="workflow",
    ...     description="DNS update workflow",
    ...     effects=[
    ...         ValidateEnvironment(tools=["kubectl"]),
    ...         RunSubprocess(command=["kubectl", "get", "nodes"])
    ...     ]
    ... )
    >>> summary = await interpreter.interpret(effect)
    >>> assert summary.exit_code == 0  # Success
"""

from __future__ import annotations

import asyncio
import os
import platform as platform_module
import shutil
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Never, TypeVar

if TYPE_CHECKING:
    from collections.abc import Mapping


# =============================================================================
# Subprocess Helper - Isolates asyncio Any types
# =============================================================================


@dataclass(frozen=True)
class ProcessOutput:
    """Typed subprocess output - isolates asyncio.subprocess Any types."""

    returncode: int
    stdout: bytes
    stderr: bytes


async def _run_subprocess(
    command: tuple[str, ...],
    *,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    timeout: float | None = None,
    input_data: bytes | None = None,
    capture_output: bool = True,
) -> ProcessOutput:
    """Run subprocess with typed output.

    This function isolates the asyncio.subprocess Any types behind a typed interface.
    The interpreter uses this instead of raw asyncio.create_subprocess_exec.
    """
    proc = await asyncio.create_subprocess_exec(
        *command,
        cwd=cwd,
        env=dict(env) if env else None,
        stdin=asyncio.subprocess.PIPE if input_data else None,
        stdout=asyncio.subprocess.PIPE if capture_output else None,
        stderr=asyncio.subprocess.PIPE if capture_output else None,
    )

    if timeout:
        try:
            # asyncio.wait_for returns Coroutine[Any, Any, T] which triggers disallow_any_expr
            # This is an unavoidable Python stdlib limitation (similar to async decorators)
            result = await asyncio.wait_for(
                proc.communicate(input=input_data),
                timeout=timeout,
            )
            stdout_bytes: bytes = result[0] if result[0] is not None else b""
            stderr_bytes: bytes = result[1] if result[1] is not None else b""
        except TimeoutError:
            proc.kill()
            await proc.wait()
            return ProcessOutput(returncode=-1, stdout=b"", stderr=b"Timeout")
    else:
        comm_result = await proc.communicate(input=input_data)
        stdout_bytes = comm_result[0] if comm_result[0] is not None else b""
        stderr_bytes = comm_result[1] if comm_result[1] is not None else b""

    return ProcessOutput(
        returncode=proc.returncode or 0,
        stdout=stdout_bytes or b"",
        stderr=stderr_bytes or b"",
    )


from rich.console import Console  # noqa: E402
from rich.table import Table  # noqa: E402

from prodbox.cli.effect_dag import EffectDAG, EffectNode, ReductionError  # noqa: E402
from prodbox.cli.effects import (  # noqa: E402
    CaptureKubectlOutput,
    CaptureSubprocessOutput,
    CheckFileExists,
    CheckServiceStatus,
    ConfirmAction,
    Custom,
    Effect,
    FetchPublicIP,
    GenerateGatewayConfig,
    GetJournalLogs,
    KubectlWait,
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
    PulumiDestroy,
    PulumiPreview,
    PulumiRefresh,
    PulumiStackSelect,
    PulumiUp,
    Pure,
    QueryGatewayState,
    QueryRoute53Record,
    ReadFile,
    RequireLinux,
    RequireSystemd,
    RunKubectlCommand,
    RunPulumiCommand,
    RunSubprocess,
    RunSystemdCommand,
    Sequence,
    StartGatewayDaemon,
    Try,
    UpdateRoute53Record,
    ValidateAWSCredentials,
    ValidateEnvironment,
    ValidateSettings,
    ValidateTool,
    WriteFile,
    WriteStderr,
    WriteStdout,
)
from prodbox.cli.stream_control import StreamControl, create_stream_handle  # noqa: E402
from prodbox.cli.types import (  # noqa: E402
    Failure,
    PrereqResults,
    Result,
    Success,
)

# Type variable for effect return types
T = TypeVar("T")
_NO_CALLER_VALUE: object = object()


def _assert_never(value: object) -> Never:
    """Type-safe assertion that code path is unreachable.

    Use at the end of exhaustive match statements to ensure
    all cases are handled. If a new variant is added to the ADT,
    mypy will error until the new case is handled.
    """
    raise AssertionError(f"Unhandled effect type: {type(value).__name__}")


# =============================================================================
# Execution Summary - Pure Data Structure
# =============================================================================


@dataclass(frozen=True)
class EnvironmentError:
    """Environment error with fix hint."""

    tool: str
    message: str
    fix_hint: str
    source_effect_id: str


@dataclass(frozen=True)
class ExecutionSummary:
    """
    Immutable summary of effect execution.

    Contains exit code, metrics, artifacts, and any errors encountered.
    This is the output contract between the interpreter and callers.
    """

    exit_code: int
    message: str
    total_effects: int = 0
    successful_effects: int = 0
    failed_effects: int = 0
    skipped_effects: int = 0
    elapsed_seconds: float = 0.0
    artifacts: tuple[Path, ...] = ()
    environment_errors: tuple[EnvironmentError, ...] = ()

    @property
    def success(self) -> bool:
        """Check if execution succeeded."""
        return self.exit_code == 0


@dataclass(frozen=True)
class EffectSuccess:
    """Effect completed successfully with a propagated value."""

    value: object | None


@dataclass(frozen=True)
class EffectRootCauseFailure:
    """Effect failed because of its own execution logic."""

    error_message: str
    fix_hint: str | None = None


@dataclass(frozen=True)
class EffectPrerequisiteSkipped:
    """Effect skipped because an upstream prerequisite failed."""

    upstream_effect_id: str


@dataclass(frozen=True)
class EffectResult:
    """Outcome of a single effect execution in the DAG."""

    effect_id: str
    outcome: EffectSuccess | EffectRootCauseFailure | EffectPrerequisiteSkipped
    elapsed_seconds: float

    @property
    def success(self) -> bool:
        """Return True when outcome is a success."""
        return isinstance(self.outcome, EffectSuccess)

    @property
    def value(self) -> object | None:
        """Backward-compatible value extraction."""
        match self.outcome:
            case EffectSuccess(value=v):
                return v
            case _:
                return None

    @property
    def error(self) -> str | None:
        """Backward-compatible error extraction."""
        match self.outcome:
            case EffectRootCauseFailure(error_message=msg):
                return msg
            case _:
                return None

    @property
    def is_skipped(self) -> bool:
        """Return True when outcome is prerequisite-skipped."""
        return isinstance(self.outcome, EffectPrerequisiteSkipped)


@dataclass(frozen=True)
class DAGExecutionSummary:
    """Summary of DAG execution with per-node results."""

    exit_code: int
    message: str
    node_results: tuple[tuple[str, ExecutionSummary], ...]
    total_nodes: int
    successful_nodes: int
    failed_nodes: int
    skipped_nodes: int = 0
    unexecuted_nodes: int = 0
    elapsed_seconds: float = 0.0
    execution_report: str = ""
    effect_results: tuple[tuple[str, EffectResult], ...] = ()
    unexecuted_ids: frozenset[str] = frozenset()

    def to_execution_summary(self) -> ExecutionSummary:
        """Convert DAG summary to command-level execution summary."""
        return ExecutionSummary(
            exit_code=self.exit_code,
            message=self.message,
            total_effects=self.total_nodes,
            successful_effects=self.successful_nodes,
            failed_effects=self.failed_nodes + self.unexecuted_nodes,
            skipped_effects=self.skipped_nodes,
            elapsed_seconds=self.elapsed_seconds,
        )


@dataclass(frozen=True)
class _CallerInput:
    """Caller-supplied prerequisite input bundled with caller effect id."""

    caller_id: str
    value: object


# =============================================================================
# Effect Interpreter
# =============================================================================


class EffectInterpreter:
    """
    Interprets and executes Effect specifications.

    This is the IMPURITY BOUNDARY - all side effects happen here.
    Mutable state (counters, error lists) is allowed in this class.

    Attributes:
        total_effects: Count of effects executed
        successful_effects: Count of effects that succeeded
        failed_effects: Count of effects that failed
        skipped_effects: Count of effects that were skipped
        environment_errors: Accumulated environment errors
        artifacts: List of generated files/directories
        start_time: When interpretation started (for elapsed time)
    """

    def __init__(self) -> None:
        """Initialize interpreter with clean state."""
        # Mutable state is OK here - interpreter is impurity boundary
        self.total_effects: int = 0
        self.successful_effects: int = 0
        self.failed_effects: int = 0
        self.skipped_effects: int = 0
        self.environment_errors: list[EnvironmentError] = []
        self.artifacts: list[Path] = []
        self.start_time: float = time.time()
        self.stream_control: StreamControl = StreamControl()
        # Rich consoles for formatted output
        self._console: Console = Console()
        self._error_console: Console = Console(stderr=True)

    def _create_success_summary(self, message: str) -> ExecutionSummary:
        """Create success execution summary."""
        return ExecutionSummary(
            exit_code=0,
            message=message,
            total_effects=self.total_effects,
            successful_effects=self.successful_effects,
            failed_effects=self.failed_effects,
            skipped_effects=self.skipped_effects,
            elapsed_seconds=time.time() - self.start_time,
            artifacts=tuple(self.artifacts),
            environment_errors=tuple(self.environment_errors),
        )

    def _create_error_summary(self, message: str, exit_code: int = 1) -> ExecutionSummary:
        """Create error execution summary."""
        return ExecutionSummary(
            exit_code=exit_code,
            message=message,
            total_effects=self.total_effects,
            successful_effects=self.successful_effects,
            failed_effects=self.failed_effects,
            skipped_effects=self.skipped_effects,
            elapsed_seconds=time.time() - self.start_time,
            artifacts=tuple(self.artifacts),
            environment_errors=tuple(self.environment_errors),
        )

    async def interpret(self, effect: Effect[T]) -> ExecutionSummary:
        """
        Interpret and execute an effect specification.

        Pattern matches on effect type and executes accordingly. Updates
        execution metrics and returns ExecutionSummary.

        Args:
            effect: Effect to execute (any Effect[T] subtype)

        Returns:
            ExecutionSummary with exit code, metrics, artifacts, errors

        Example:
            >>> effect = RunSubprocess(
            ...     effect_id="echo",
            ...     description="Echo hello",
            ...     command=["echo", "hello"]
            ... )
            >>> summary = await interpreter.interpret(effect)
            >>> assert summary.exit_code == 0
        """
        summary, _ = await self._dispatch_effect(effect)
        return summary

    async def interpret_with_value(
        self, effect: Effect[T]
    ) -> tuple[ExecutionSummary, object | None]:
        """
        Interpret an effect and return both the execution summary and value.

        This API propagates subprocess outputs while keeping ExecutionSummary
        as the primary result.

        Args:
            effect: Effect to execute

        Returns:
            Tuple of (ExecutionSummary, effect_value or None)
        """
        return await self._dispatch_effect(effect)

    async def interpret_dag(self, dag: EffectDAG) -> DAGExecutionSummary:
        """
        Execute an EffectDAG with maximum concurrency.

        Executes nodes level by level, where each level contains nodes
        whose prerequisites are satisfied. Uses asyncio.gather for
        concurrent execution within levels.

        Args:
            dag: The EffectDAG to execute

        Returns:
            DAGExecutionSummary with per-node results
        """
        summary, _ = await self.interpret_dag_with_values(dag)
        return summary

    async def interpret_dag_with_values(
        self,
        dag: EffectDAG,
    ) -> tuple[DAGExecutionSummary, dict[str, Result[object, object]]]:
        """
        Execute an EffectDAG and return node values.

        Args:
            dag: The EffectDAG to execute

        Returns:
            Tuple of DAG summary and per-node Result values keyed by effect_id
        """
        start = time.time()
        # Reset interpreter aggregate metrics for fresh DAG execution.
        self.start_time = start
        self.total_effects = 0
        self.successful_effects = 0
        self.failed_effects = 0
        self.skipped_effects = 0
        self.environment_errors = []
        self.artifacts = []

        node_map: dict[str, EffectNode[object]] = {node.effect_id: node for node in dag.nodes}
        pending: set[str] = set(node_map.keys())
        completed: dict[str, EffectResult] = {}
        unexecuted: set[str] = set()
        caller_inputs = self._collect_prerequisite_inputs(dag)

        while pending - unexecuted:
            ready_ids = sorted(
                [
                    effect_id
                    for effect_id in (pending - unexecuted)
                    if node_map[effect_id].prerequisites <= completed.keys()
                ]
            )
            if not ready_ids:
                unexecuted.update(pending - completed.keys())
                break

            reduction_failures: list[tuple[str, str]] = []
            ready_nodes: list[tuple[str, EffectNode[object], object, PrereqResults]] = []
            for effect_id in ready_ids:
                node = node_map[effect_id]
                reduced_value, reduction_error = self._reduce_prerequisite_inputs(
                    node,
                    caller_inputs.get(effect_id, ()),
                )
                if reduction_error is not None:
                    reduction_failures.append((effect_id, reduction_error.message))
                    continue
                prereq_results = self._build_prereq_results(node, completed)
                effect, effect_error = self._build_effect_for_node(
                    node,
                    reduced_value,
                    prereq_results,
                )
                if effect_error is not None:
                    reduction_failures.append((effect_id, effect_error.message))
                    continue
                ready_nodes.append((effect_id, node, reduced_value, prereq_results))

            for effect_id, message in reduction_failures:
                failure_message = f"Prerequisite reduction failed for '{effect_id}': {message}"
                self.failed_effects += 1
                self.environment_errors.append(
                    EnvironmentError(
                        tool="prerequisite_reduction",
                        message=failure_message,
                        fix_hint="Fix prerequisite reduction/effect builder for this node",
                        source_effect_id=effect_id,
                    )
                )
                completed[effect_id] = EffectResult(
                    effect_id=effect_id,
                    outcome=EffectRootCauseFailure(error_message=failure_message),
                    elapsed_seconds=0.0,
                )
                pending.discard(effect_id)

            if not ready_nodes:
                continue

            start_times: dict[str, float] = {
                ready_node[0]: time.time() for ready_node in ready_nodes
            }
            results = await asyncio.gather(
                *[
                    self._execute_node(
                        node,
                        prereq_results,
                        reduced_value=reduced_value,
                    )
                    for _, node, reduced_value, prereq_results in ready_nodes
                ],
                return_exceptions=True,
            )

            for (effect_id, _, _, _), raw_result in zip(ready_nodes, results, strict=True):
                elapsed = time.time() - start_times[effect_id]
                if isinstance(raw_result, BaseException):
                    summary = self._create_error_summary(f"Exception: {raw_result}")
                    value: object | None = None
                else:
                    summary = raw_result[0]
                    value = raw_result[1]
                completed[effect_id] = self._summary_to_effect_result(
                    effect_id=effect_id,
                    summary=summary,
                    value=value,
                    elapsed_seconds=elapsed,
                )
                pending.discard(effect_id)

        # Construct deterministic compatibility node summaries.
        node_results_list: list[tuple[str, ExecutionSummary]] = [
            (effect_id, self._effect_result_to_summary(result))
            for effect_id, result in sorted(completed.items())
        ]
        for effect_id in sorted(unexecuted):
            node_results_list.append(
                (
                    effect_id,
                    ExecutionSummary(
                        exit_code=1,
                        message="Unexecuted due to unresolved prerequisites",
                    ),
                )
            )

        successful_nodes = sum(1 for result in completed.values() if result.success)
        failed_nodes = sum(
            1 for result in completed.values() if isinstance(result.outcome, EffectRootCauseFailure)
        )
        skipped_nodes = sum(1 for result in completed.values() if result.is_skipped)
        unexecuted_nodes = len(unexecuted)
        exit_code = self._root_exit_code(
            roots=dag.roots, completed=completed, unexecuted=unexecuted
        )
        execution_report = self._build_execution_report(completed=completed, unexecuted=unexecuted)

        dag_summary = DAGExecutionSummary(
            exit_code=exit_code,
            message="DAG execution complete",
            node_results=tuple(node_results_list),
            total_nodes=len(dag.nodes),
            successful_nodes=successful_nodes,
            failed_nodes=failed_nodes,
            skipped_nodes=skipped_nodes,
            unexecuted_nodes=unexecuted_nodes,
            elapsed_seconds=time.time() - start,
            execution_report=execution_report,
            effect_results=tuple(sorted(completed.items())),
            unexecuted_ids=frozenset(unexecuted),
        )
        return dag_summary, self._effect_results_to_prereq_results(completed)

    async def _execute_node(
        self,
        node: EffectNode[object],
        prereq_results: PrereqResults,
        reduced_value: object | None = None,
    ) -> tuple[ExecutionSummary, object | None]:
        """Execute a single DAG node with prerequisite results."""
        # Check if any prerequisite failed
        for prereq_id in node.prerequisites:
            prereq_result = prereq_results.get(prereq_id)
            match prereq_result:
                case Failure(_):
                    self.skipped_effects += 1
                    return (
                        self._create_error_summary(
                            f"Skipped due to failed prerequisite: {prereq_id}"
                        ),
                        None,
                    )
                case Success(_):
                    pass
                case None:
                    self.skipped_effects += 1
                    return (
                        self._create_error_summary(
                            f"Skipped due to missing prerequisite: {prereq_id}"
                        ),
                        None,
                    )

        # Build effect with reduced values if applicable
        effect = node.build_effect(reduced_value, prereq_results)
        return await self._dispatch_effect(effect)

    def _collect_prerequisite_inputs(
        self,
        dag: EffectDAG,
    ) -> dict[str, tuple[_CallerInput, ...]]:
        """Collect caller inputs for each prerequisite effect id."""
        caller_inputs: dict[str, list[_CallerInput]] = {}
        for node in dag.nodes:
            value_map = {item.effect_id: item.value for item in node.prerequisite_values}
            for prereq_id in node.prerequisites:
                entry = _CallerInput(
                    caller_id=node.effect_id,
                    value=value_map.get(prereq_id, _NO_CALLER_VALUE),
                )
                caller_inputs.setdefault(prereq_id, []).append(entry)
        return {effect_id: tuple(values) for effect_id, values in caller_inputs.items()}

    def _reduce_prerequisite_inputs(
        self,
        node: EffectNode[object],
        caller_inputs: tuple[_CallerInput, ...],
    ) -> tuple[object, ReductionError | None]:
        """Apply node reduction monad to caller-supplied prerequisite values."""
        acc = node.reduction.unit()
        ordered = sorted(caller_inputs, key=self._caller_sort_key)
        for caller_input in ordered:
            value = (
                node.reduction.unit()
                if caller_input.value is _NO_CALLER_VALUE
                else caller_input.value
            )
            try:
                reduced = node.reduction.bind(acc, value)
            except Exception as exc:
                return acc, ReductionError(message=f"Reduction bind failed: {exc}")
            if isinstance(reduced, ReductionError):
                return acc, reduced
            acc = reduced
        return acc, None

    @staticmethod
    def _caller_sort_key(item: _CallerInput) -> str:
        """Deterministic caller order for reduction."""
        return item.caller_id

    def _build_effect_for_node(
        self,
        node: EffectNode[object],
        reduced_value: object,
        prereq_results: PrereqResults,
    ) -> tuple[Effect[object] | None, ReductionError | None]:
        """Build effect for node and validate effect_id consistency."""
        try:
            effect = node.build_effect(reduced_value, prereq_results)
        except Exception as exc:
            return None, ReductionError(message=f"Effect factory failed: {exc}")
        if effect.effect_id != node.effect_id:
            return (
                None,
                ReductionError(
                    message=(
                        "Effect factory returned mismatched effect_id "
                        f"'{effect.effect_id}' (expected '{node.effect_id}')"
                    )
                ),
            )
        return effect, None

    def _build_prereq_results(
        self,
        node: EffectNode[object],
        completed: dict[str, EffectResult],
    ) -> PrereqResults:
        """Build prerequisite result map for a node from completed outcomes."""
        results: dict[str, Result[object, object]] = {}
        for prereq_id in node.prerequisites:
            effect_result = completed[prereq_id]
            if effect_result.success:
                results[prereq_id] = Success(effect_result.value)
            else:
                results[prereq_id] = Failure(effect_result.error or "Effect failed")
        return results

    def _summary_to_effect_result(
        self,
        *,
        effect_id: str,
        summary: ExecutionSummary,
        value: object | None,
        elapsed_seconds: float,
    ) -> EffectResult:
        """Convert ExecutionSummary to structured effect outcome."""
        if summary.message.startswith("Skipped due to"):
            return EffectResult(
                effect_id=effect_id,
                outcome=EffectPrerequisiteSkipped(
                    upstream_effect_id=self._extract_upstream_effect_id(summary.message),
                ),
                elapsed_seconds=elapsed_seconds,
            )
        if summary.success:
            return EffectResult(
                effect_id=effect_id,
                outcome=EffectSuccess(value=value),
                elapsed_seconds=elapsed_seconds,
            )
        return EffectResult(
            effect_id=effect_id,
            outcome=EffectRootCauseFailure(error_message=summary.message),
            elapsed_seconds=elapsed_seconds,
        )

    @staticmethod
    def _extract_upstream_effect_id(message: str) -> str:
        """Extract upstream effect id from skip message."""
        failed_prefix = "Skipped due to failed prerequisite: "
        missing_prefix = "Skipped due to missing prerequisite: "
        if message.startswith(failed_prefix):
            return message.removeprefix(failed_prefix)
        if message.startswith(missing_prefix):
            return message.removeprefix(missing_prefix)
        return "unknown"

    @staticmethod
    def _effect_result_to_summary(effect_result: EffectResult) -> ExecutionSummary:
        """Convert structured effect result to compatibility ExecutionSummary."""
        match effect_result.outcome:
            case EffectSuccess():
                return ExecutionSummary(exit_code=0, message="Success")
            case EffectPrerequisiteSkipped(upstream_effect_id=upstream):
                return ExecutionSummary(
                    exit_code=1,
                    message=f"Skipped due to failed prerequisite: {upstream}",
                )
            case EffectRootCauseFailure(error_message=message):
                return ExecutionSummary(exit_code=1, message=message)

    @staticmethod
    def _effect_results_to_prereq_results(
        completed: dict[str, EffectResult],
    ) -> dict[str, Result[object, object]]:
        """Convert structured effect results to Result map for callers/tests."""
        results: dict[str, Result[object, object]] = {}
        for effect_id, result in completed.items():
            if result.success:
                results[effect_id] = Success(result.value)
            else:
                results[effect_id] = Failure(result.error or "Effect failed")
        return results

    @staticmethod
    def _build_execution_report(
        *,
        completed: dict[str, EffectResult],
        unexecuted: set[str],
    ) -> str:
        """Build deterministic execution report text for DAG summary."""
        root_failures = [
            (effect_id, result.error or "Effect failed")
            for effect_id, result in completed.items()
            if isinstance(result.outcome, EffectRootCauseFailure)
        ]
        skipped = [
            (effect_id, result.outcome.upstream_effect_id)
            for effect_id, result in completed.items()
            if isinstance(result.outcome, EffectPrerequisiteSkipped)
        ]
        lines: list[str] = ["DAG execution complete"]
        if root_failures:
            lines.append("Root-cause failures:")
            lines.extend(
                [f"  - {effect_id}: {message}" for effect_id, message in sorted(root_failures)]
            )
        if skipped:
            lines.append("Skipped effects:")
            lines.extend(
                [
                    f"  - {effect_id}: skipped due to {upstream}"
                    for effect_id, upstream in sorted(skipped)
                ]
            )
        if unexecuted:
            lines.append("Unexecuted effects:")
            lines.extend([f"  - {effect_id}" for effect_id in sorted(unexecuted)])
        return "\n".join(lines)

    @staticmethod
    def _root_exit_code(
        *,
        roots: frozenset[str],
        completed: dict[str, EffectResult],
        unexecuted: set[str],
    ) -> int:
        """Compute command exit code from root outcomes."""
        for root_id in roots:
            if root_id in unexecuted:
                return 1
            result = completed.get(root_id)
            if result is None or not result.success:
                return 1
        return 0

    async def _dispatch_effect(self, effect: Effect[T]) -> tuple[ExecutionSummary, object | None]:
        """
        Dispatch effect to appropriate handler.

        Pattern matches on effect type and calls the corresponding
        _interpret_* method. This is where all side effects happen.
        """
        self.total_effects += 1

        # Handle generic effects with isinstance (avoids Any in pattern matching)
        if isinstance(effect, Pure):
            return await self._interpret_pure(effect), effect.value
        if isinstance(effect, Custom):
            return await self._interpret_custom(effect)

        # Pattern match on effect type for non-generic effects
        match effect:
            # Platform detection
            case RequireLinux():
                return await self._interpret_require_linux(effect), None
            case RequireSystemd():
                return await self._interpret_require_systemd(effect), None

            # Tool validation
            case ValidateTool():
                return await self._interpret_validate_tool(effect)
            case ValidateEnvironment():
                return await self._interpret_validate_environment(effect)

            # File system
            case CheckFileExists():
                return await self._interpret_check_file_exists(effect)
            case ReadFile():
                return await self._interpret_read_file(effect)
            case WriteFile():
                return await self._interpret_write_file(effect), None

            # Subprocess
            case RunSubprocess():
                return await self._interpret_run_subprocess(effect)
            case CaptureSubprocessOutput():
                return await self._interpret_capture_subprocess_output(effect)

            # Systemd
            case RunSystemdCommand():
                return await self._interpret_run_systemd_command(effect)
            case CheckServiceStatus():
                return await self._interpret_check_service_status(effect)
            case GetJournalLogs():
                return await self._interpret_get_journal_logs(effect)

            # Kubernetes
            case RunKubectlCommand():
                return await self._interpret_run_kubectl_command(effect)
            case CaptureKubectlOutput():
                return await self._interpret_capture_kubectl_output(effect)

            # DNS / Route 53
            case FetchPublicIP():
                return await self._interpret_fetch_public_ip(effect)
            case QueryRoute53Record():
                return await self._interpret_query_route53_record(effect)
            case UpdateRoute53Record():
                return await self._interpret_update_route53_record(effect), None
            case ValidateAWSCredentials():
                return await self._interpret_validate_aws_credentials(effect)

            # Pulumi
            case RunPulumiCommand():
                return await self._interpret_run_pulumi_command(effect)
            case PulumiStackSelect():
                return await self._interpret_pulumi_stack_select(effect)
            case PulumiPreview():
                return await self._interpret_pulumi_preview(effect)
            case PulumiUp():
                return await self._interpret_pulumi_up(effect)
            case PulumiDestroy():
                return await self._interpret_pulumi_destroy(effect)
            case PulumiRefresh():
                return await self._interpret_pulumi_refresh(effect)

            # Settings
            case LoadSettings():
                return await self._interpret_load_settings(effect)
            case ValidateSettings():
                return await self._interpret_validate_settings(effect)

            # Output
            case WriteStdout():
                return await self._interpret_write_stdout(effect), None
            case WriteStderr():
                return await self._interpret_write_stderr(effect), None
            case PrintInfo():
                return await self._interpret_print_info(effect), None
            case PrintSuccess():
                return await self._interpret_print_success(effect), None
            case PrintWarning():
                return await self._interpret_print_warning(effect), None
            case PrintError():
                return await self._interpret_print_error(effect), None
            case PrintTable():
                return await self._interpret_print_table(effect), None
            case PrintSection():
                return await self._interpret_print_section(effect), None
            case PrintIndented():
                return await self._interpret_print_indented(effect), None
            case PrintBlankLine():
                return await self._interpret_print_blank_line(effect), None
            case ConfirmAction():
                return await self._interpret_confirm_action(effect)
            case KubectlWait():
                return await self._interpret_kubectl_wait(effect)

            # Composite
            case Sequence():
                return await self._interpret_sequence(effect), None
            case Parallel():
                return await self._interpret_parallel(effect), None
            case Try():
                return await self._interpret_try(effect)

            # Gateway daemon
            case StartGatewayDaemon():
                return await self._interpret_start_gateway_daemon(effect), None
            case QueryGatewayState():
                return await self._interpret_query_gateway_state(effect)
            case GenerateGatewayConfig():
                return await self._interpret_generate_gateway_config(effect), None

            case _:
                # Type-safe unreachable check
                _assert_never(effect)

    # =========================================================================
    # Platform Detection Effects
    # =========================================================================

    async def _interpret_require_linux(self, _effect: RequireLinux) -> ExecutionSummary:
        """Require Linux platform."""
        current_platform = platform_module.system().lower()
        if current_platform == "linux":
            self.successful_effects += 1
            return self._create_success_summary("Platform is Linux")
        else:
            self.failed_effects += 1
            return self._create_error_summary(f"Linux required but running on {current_platform}")

    async def _interpret_require_systemd(self, _effect: RequireSystemd) -> ExecutionSummary:
        """Require systemd availability."""
        # Check if systemctl is available
        systemctl_path = shutil.which("systemctl")
        if systemctl_path:
            self.successful_effects += 1
            return self._create_success_summary("systemd is available")
        else:
            self.failed_effects += 1
            return self._create_error_summary("systemd is not available")

    # =========================================================================
    # Tool Validation Effects
    # =========================================================================

    async def _interpret_validate_tool(
        self, effect: ValidateTool
    ) -> tuple[ExecutionSummary, bool | None]:
        """Validate external tool availability."""
        tool_path = shutil.which(effect.tool_name)
        if tool_path:
            self.successful_effects += 1
            return self._create_success_summary(f"Tool found: {effect.tool_name}"), True
        else:
            self.failed_effects += 1
            self.environment_errors.append(
                EnvironmentError(
                    tool=effect.tool_name,
                    message=f"Tool not found: {effect.tool_name}",
                    fix_hint=f"Install {effect.tool_name}",
                    source_effect_id=effect.effect_id,
                )
            )
            return self._create_error_summary(f"Tool not found: {effect.tool_name}"), False

    async def _interpret_validate_environment(
        self, effect: ValidateEnvironment
    ) -> tuple[ExecutionSummary, bool | None]:
        """Validate multiple tools are available."""
        missing: list[str] = []
        for tool in effect.tools:
            if not shutil.which(tool):
                missing.append(tool)
                self.environment_errors.append(
                    EnvironmentError(
                        tool=tool,
                        message=f"Tool not found: {tool}",
                        fix_hint=f"Install {tool}",
                        source_effect_id=effect.effect_id,
                    )
                )

        if missing:
            self.failed_effects += 1
            return (
                self._create_error_summary(f"Missing tools: {', '.join(missing)}"),
                False,
            )
        else:
            self.successful_effects += 1
            return self._create_success_summary("All tools available"), True

    # =========================================================================
    # File System Effects
    # =========================================================================

    async def _interpret_check_file_exists(
        self, effect: CheckFileExists
    ) -> tuple[ExecutionSummary, bool | None]:
        """Check if file exists."""
        exists = effect.file_path.exists()
        if exists:
            self.successful_effects += 1
            return self._create_success_summary(f"File exists: {effect.file_path}"), True
        else:
            self.failed_effects += 1
            return (
                self._create_error_summary(f"File not found: {effect.file_path}"),
                False,
            )

    async def _interpret_read_file(self, effect: ReadFile) -> tuple[ExecutionSummary, str | None]:
        """Read file contents."""
        try:
            content = effect.file_path.read_text()
            self.successful_effects += 1
            return self._create_success_summary(f"Read file: {effect.file_path}"), content
        except OSError as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to read file: {e}"), None

    async def _interpret_write_file(self, effect: WriteFile) -> ExecutionSummary:
        """Write file contents."""
        try:
            # Handle sudo case
            if effect.sudo:
                # Use subprocess to write with sudo
                output = await _run_subprocess(
                    ("sudo", "tee", str(effect.file_path)),
                    input_data=effect.content.encode(),
                    capture_output=False,
                )
                if output.returncode != 0:
                    self.failed_effects += 1
                    return self._create_error_summary(
                        f"Failed to write file with sudo: {effect.file_path}"
                    )
            else:
                effect.file_path.write_text(effect.content)

            self.successful_effects += 1
            self.artifacts.append(effect.file_path)
            return self._create_success_summary(f"Wrote file: {effect.file_path}")
        except OSError as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to write file: {e}")

    # =========================================================================
    # Subprocess Effects
    # =========================================================================

    async def _interpret_run_subprocess(
        self, effect: RunSubprocess
    ) -> tuple[ExecutionSummary, int | None]:
        """Execute subprocess command."""
        capture_output = effect.capture_output and not effect.stream_stdout
        stream_handle = (
            create_stream_handle(effect.effect_id, " ".join(effect.command))
            if effect.stream_stdout
            else None
        )
        try:
            if stream_handle is not None:
                await self.stream_control.acquire_stream(stream_handle)
            output = await _run_subprocess(
                tuple(effect.command),
                cwd=effect.cwd,
                env=effect.env,
                timeout=effect.timeout,
                input_data=effect.input_data,
                capture_output=capture_output,
            )

            if output.returncode == -1 and output.stderr == b"Timeout":
                self.failed_effects += 1
                return self._create_error_summary("Subprocess timed out"), None

            if output.returncode == 0:
                self.successful_effects += 1
                return (
                    self._create_success_summary(f"Command succeeded: {effect.command[0]}"),
                    output.returncode,
                )
            else:
                self.failed_effects += 1
                error_msg = (
                    output.stderr.decode() if output.stderr else f"Exit code {output.returncode}"
                )
                return (
                    self._create_error_summary(f"Command failed: {error_msg}"),
                    output.returncode,
                )

        except OSError as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to run command: {e}"), None
        finally:
            if stream_handle is not None:
                self.stream_control.release_stream(stream_handle)

    async def _interpret_capture_subprocess_output(
        self, effect: CaptureSubprocessOutput
    ) -> tuple[ExecutionSummary, tuple[int, str, str] | None]:
        """Execute subprocess and capture output."""
        try:
            output = await _run_subprocess(
                tuple(effect.command),
                cwd=effect.cwd,
                env=effect.env,
                timeout=effect.timeout,
                capture_output=True,
            )

            if output.returncode == -1 and output.stderr == b"Timeout":
                self.failed_effects += 1
                return self._create_error_summary("Subprocess timed out"), None

            result = (
                output.returncode,
                output.stdout.decode(),
                output.stderr.decode(),
            )

            if output.returncode == 0:
                self.successful_effects += 1
                return (
                    self._create_success_summary(f"Captured output: {effect.command[0]}"),
                    result,
                )
            else:
                self.failed_effects += 1
                return (
                    self._create_error_summary(f"Command failed: {effect.command[0]}"),
                    result,
                )

        except OSError as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to run command: {e}"), None

    # =========================================================================
    # Systemd Effects
    # =========================================================================

    async def _interpret_run_systemd_command(
        self, effect: RunSystemdCommand
    ) -> tuple[ExecutionSummary, int | None]:
        """Execute systemctl command."""
        command = ["sudo", "systemctl"] if effect.sudo else ["systemctl"]
        command.append(effect.action)
        if effect.service:
            command.append(effect.service)

        try:
            output = await _run_subprocess(
                tuple(command),
                timeout=effect.timeout,
            )

            if output.returncode == -1 and output.stderr == b"Timeout":
                self.failed_effects += 1
                return self._create_error_summary("systemctl timed out"), None

            if output.returncode == 0:
                self.successful_effects += 1
                return (
                    self._create_success_summary(f"systemctl {effect.action} succeeded"),
                    output.returncode,
                )
            else:
                self.failed_effects += 1
                return (
                    self._create_error_summary(
                        f"systemctl {effect.action} failed: {output.stderr.decode()}"
                    ),
                    output.returncode,
                )

        except OSError as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to run systemctl: {e}"), None

    async def _interpret_check_service_status(
        self, effect: CheckServiceStatus
    ) -> tuple[ExecutionSummary, str | None]:
        """Check systemd service status."""
        try:
            output = await _run_subprocess(
                ("systemctl", "is-active", effect.service),
            )
            status = output.stdout.decode().strip()

            self.successful_effects += 1
            return (
                self._create_success_summary(f"Service {effect.service}: {status}"),
                status,
            )
        except OSError as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to check service: {e}"), None

    async def _interpret_get_journal_logs(
        self, effect: GetJournalLogs
    ) -> tuple[ExecutionSummary, str | None]:
        """Get journalctl logs."""
        try:
            output = await _run_subprocess(
                ("journalctl", "-u", effect.service, "-n", str(effect.lines), "--no-pager"),
            )
            logs = output.stdout.decode()

            self.successful_effects += 1
            return self._create_success_summary(f"Got logs for {effect.service}"), logs
        except OSError as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to get logs: {e}"), None

    # =========================================================================
    # Kubernetes Effects
    # =========================================================================

    async def _interpret_run_kubectl_command(
        self, effect: RunKubectlCommand
    ) -> tuple[ExecutionSummary, int | None]:
        """Execute kubectl command."""
        command: list[str] = ["kubectl"]
        if effect.kubeconfig:
            command.extend(["--kubeconfig", str(effect.kubeconfig)])
        if effect.namespace:
            command.extend(["--namespace", effect.namespace])
        command.extend(effect.args)
        env = self._kubectl_env(effect.kubeconfig)

        try:
            output = await _run_subprocess(
                tuple(command),
                timeout=effect.timeout,
                env=env,
                capture_output=not effect.stream_stdout,
            )

            if output.returncode == -1 and output.stderr == b"Timeout":
                self.failed_effects += 1
                return self._create_error_summary("kubectl timed out"), None

            if output.returncode == 0:
                self.successful_effects += 1
                return self._create_success_summary("kubectl succeeded"), output.returncode
            else:
                self.failed_effects += 1
                error = (
                    output.stderr.decode() if output.stderr else f"Exit code {output.returncode}"
                )
                return self._create_error_summary(f"kubectl failed: {error}"), output.returncode

        except OSError as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to run kubectl: {e}"), None

    async def _interpret_capture_kubectl_output(
        self, effect: CaptureKubectlOutput
    ) -> tuple[ExecutionSummary, tuple[int, str, str] | None]:
        """Execute kubectl and capture output."""
        command: list[str] = ["kubectl"]
        if effect.kubeconfig:
            command.extend(["--kubeconfig", str(effect.kubeconfig)])
        if effect.namespace:
            command.extend(["--namespace", effect.namespace])
        command.extend(effect.args)
        env = self._kubectl_env(effect.kubeconfig)

        try:
            output = await _run_subprocess(
                tuple(command),
                timeout=effect.timeout,
                env=env,
            )

            if output.returncode == -1 and output.stderr == b"Timeout":
                self.failed_effects += 1
                return self._create_error_summary("kubectl timed out"), None

            result = (
                output.returncode,
                output.stdout.decode(),
                output.stderr.decode(),
            )

            if output.returncode == 0:
                self.successful_effects += 1
                return self._create_success_summary("kubectl succeeded"), result
            else:
                self.failed_effects += 1
                return self._create_error_summary("kubectl failed"), result

        except OSError as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to run kubectl: {e}"), None

    # =========================================================================
    # DNS / Route 53 Effects
    # =========================================================================

    async def _interpret_fetch_public_ip(
        self, _effect: FetchPublicIP
    ) -> tuple[ExecutionSummary, str | None]:
        """Fetch current public IP address."""
        try:
            import httpx

            async with httpx.AsyncClient() as client:
                response = await client.get("https://api.ipify.org", timeout=10.0)
                response.raise_for_status()
                ip = response.text.strip()

            self.successful_effects += 1
            return self._create_success_summary(f"Public IP: {ip}"), ip
        except Exception as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to fetch public IP: {e}"), None

    async def _interpret_query_route53_record(
        self, effect: QueryRoute53Record
    ) -> tuple[ExecutionSummary, str | None]:
        """Query Route 53 for current A record."""
        try:
            import boto3

            session = boto3.Session(
                aws_access_key_id=effect.aws_access_key_id,
                aws_secret_access_key=effect.aws_secret_access_key,
                region_name=effect.aws_region,
            )
            client = session.client("route53")

            response = client.list_resource_record_sets(
                HostedZoneId=effect.zone_id,
                StartRecordName=effect.fqdn,
                StartRecordType="A",
                MaxItems="1",
            )

            records = response.get("ResourceRecordSets")
            if isinstance(records, list):
                for record in records:
                    if isinstance(record, dict):
                        name = record.get("Name")
                        record_type = record.get("Type")
                        name_str = str(name) if name is not None else ""
                        type_str = str(record_type) if record_type is not None else ""
                        if name_str.rstrip(".") == effect.fqdn.rstrip(".") and type_str == "A":
                            resource_records = record.get("ResourceRecords")
                            if isinstance(resource_records, list) and resource_records:
                                first_record = resource_records[0]
                                if isinstance(first_record, dict):
                                    ip = first_record.get("Value")
                                    if isinstance(ip, str):
                                        self.successful_effects += 1
                                        return (
                                            self._create_success_summary(f"Current DNS: {ip}"),
                                            ip,
                                        )

            self.successful_effects += 1
            return self._create_success_summary("No A record found"), None

        except Exception as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to query Route 53: {e}"), None

    async def _interpret_update_route53_record(
        self, effect: UpdateRoute53Record
    ) -> ExecutionSummary:
        """Update Route 53 A record."""
        try:
            import boto3

            session = boto3.Session(
                aws_access_key_id=effect.aws_access_key_id,
                aws_secret_access_key=effect.aws_secret_access_key,
                region_name=effect.aws_region,
            )
            client = session.client("route53")

            client.change_resource_record_sets(
                HostedZoneId=effect.zone_id,
                ChangeBatch={
                    "Changes": [
                        {
                            "Action": "UPSERT",
                            "ResourceRecordSet": {
                                "Name": effect.fqdn,
                                "Type": "A",
                                "TTL": effect.ttl,
                                "ResourceRecords": [{"Value": effect.ip}],
                            },
                        }
                    ]
                },
            )

            self.successful_effects += 1
            return self._create_success_summary(f"Updated DNS: {effect.fqdn} -> {effect.ip}")

        except Exception as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to update Route 53: {e}")

    async def _interpret_validate_aws_credentials(
        self, effect: ValidateAWSCredentials
    ) -> tuple[ExecutionSummary, bool | None]:
        """Validate AWS credentials."""
        try:
            import boto3

            session = boto3.Session(
                aws_access_key_id=effect.aws_access_key_id,
                aws_secret_access_key=effect.aws_secret_access_key,
                region_name=effect.aws_region,
            )
            sts = session.client("sts")
            sts.get_caller_identity()

            self.successful_effects += 1
            return self._create_success_summary("AWS credentials valid"), True

        except Exception as e:
            self.failed_effects += 1
            self.environment_errors.append(
                EnvironmentError(
                    tool="aws",
                    message=f"Invalid AWS credentials: {e}",
                    fix_hint="Configure AWS credentials via environment variables",
                    source_effect_id=effect.effect_id,
                )
            )
            return self._create_error_summary(f"Invalid AWS credentials: {e}"), False

    # =========================================================================
    # Pulumi Effects
    # =========================================================================

    async def _interpret_run_pulumi_command(
        self, effect: RunPulumiCommand
    ) -> tuple[ExecutionSummary, int | None]:
        """Execute Pulumi CLI command."""
        command = ("pulumi", *effect.args)

        try:
            output = await _run_subprocess(
                command,
                cwd=effect.cwd,
                env=effect.env,
                timeout=effect.timeout,
                capture_output=not effect.stream_stdout,
            )

            if output.returncode == -1 and output.stderr == b"Timeout":
                self.failed_effects += 1
                return self._create_error_summary("Pulumi timed out"), None

            if output.returncode == 0:
                self.successful_effects += 1
                return self._create_success_summary("Pulumi command succeeded"), output.returncode
            else:
                self.failed_effects += 1
                error = (
                    output.stderr.decode() if output.stderr else f"Exit code {output.returncode}"
                )
                return self._create_error_summary(f"Pulumi failed: {error}"), output.returncode

        except OSError as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to run Pulumi: {e}"), None

    async def _interpret_pulumi_stack_select(
        self, effect: PulumiStackSelect
    ) -> tuple[ExecutionSummary, bool | None]:
        """Select Pulumi stack."""
        command: list[str] = ["pulumi", "stack", "select", effect.stack]
        if effect.create_if_missing:
            command.append("--create")

        try:
            output = await _run_subprocess(
                tuple(command),
                cwd=effect.cwd,
            )

            if output.returncode == 0:
                self.successful_effects += 1
                return (
                    self._create_success_summary(f"Selected stack: {effect.stack}"),
                    True,
                )
            else:
                self.failed_effects += 1
                return (
                    self._create_error_summary(f"Failed to select stack: {output.stderr.decode()}"),
                    False,
                )

        except OSError as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to run pulumi stack select: {e}"), False

    async def _interpret_pulumi_preview(
        self, effect: PulumiPreview
    ) -> tuple[ExecutionSummary, int | None]:
        """Run Pulumi preview."""
        command: list[str] = ["pulumi", "preview"]
        if effect.stack:
            command.extend(["--stack", effect.stack])

        try:
            output = await _run_subprocess(
                tuple(command),
                cwd=effect.cwd,
                capture_output=not effect.stream_stdout,
            )

            if output.returncode == 0:
                self.successful_effects += 1
                return self._create_success_summary("Pulumi preview complete"), output.returncode
            else:
                self.failed_effects += 1
                return (
                    self._create_error_summary(f"Pulumi preview failed: {output.stderr.decode()}"),
                    output.returncode,
                )

        except OSError as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to run pulumi preview: {e}"), None

    async def _interpret_pulumi_up(self, effect: PulumiUp) -> tuple[ExecutionSummary, int | None]:
        """Run Pulumi up."""
        command: list[str] = ["pulumi", "up"]
        if effect.yes:
            command.append("--yes")
        if effect.stack:
            command.extend(["--stack", effect.stack])

        try:
            output = await _run_subprocess(
                tuple(command),
                cwd=effect.cwd,
                capture_output=not effect.stream_stdout,
            )

            if output.returncode == 0:
                self.successful_effects += 1
                return self._create_success_summary("Pulumi up complete"), output.returncode
            else:
                self.failed_effects += 1
                return (
                    self._create_error_summary(f"Pulumi up failed: {output.stderr.decode()}"),
                    output.returncode,
                )

        except OSError as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to run pulumi up: {e}"), None

    async def _interpret_pulumi_destroy(
        self, effect: PulumiDestroy
    ) -> tuple[ExecutionSummary, int | None]:
        """Run Pulumi destroy."""
        command: list[str] = ["pulumi", "destroy"]
        if effect.yes:
            command.append("--yes")
        if effect.stack:
            command.extend(["--stack", effect.stack])

        try:
            output = await _run_subprocess(
                tuple(command),
                cwd=effect.cwd,
                capture_output=not effect.stream_stdout,
            )

            if output.returncode == 0:
                self.successful_effects += 1
                return self._create_success_summary("Pulumi destroy complete"), output.returncode
            else:
                self.failed_effects += 1
                return (
                    self._create_error_summary(f"Pulumi destroy failed: {output.stderr.decode()}"),
                    output.returncode,
                )

        except OSError as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to run pulumi destroy: {e}"), None

    async def _interpret_pulumi_refresh(
        self, effect: PulumiRefresh
    ) -> tuple[ExecutionSummary, int | None]:
        """Run Pulumi refresh."""
        command: list[str] = ["pulumi", "refresh"]
        if effect.yes:
            command.append("--yes")
        if effect.stack:
            command.extend(["--stack", effect.stack])

        try:
            output = await _run_subprocess(
                tuple(command),
                cwd=effect.cwd,
                capture_output=not effect.stream_stdout,
            )

            if output.returncode == 0:
                self.successful_effects += 1
                return self._create_success_summary("Pulumi refresh complete"), output.returncode
            else:
                self.failed_effects += 1
                return (
                    self._create_error_summary(f"Pulumi refresh failed: {output.stderr.decode()}"),
                    output.returncode,
                )

        except OSError as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to run pulumi refresh: {e}"), None

    # =========================================================================
    # Settings Effects
    # =========================================================================

    async def _interpret_load_settings(
        self, _effect: LoadSettings
    ) -> tuple[ExecutionSummary, object | None]:
        """Load prodbox settings."""
        try:
            from prodbox.settings import Settings

            settings = Settings()
            self.successful_effects += 1
            return self._create_success_summary("Settings loaded"), settings
        except Exception as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to load settings: {e}"), None

    async def _interpret_validate_settings(
        self, _effect: ValidateSettings
    ) -> tuple[ExecutionSummary, bool | None]:
        """Validate prodbox settings."""
        try:
            from prodbox.settings import Settings

            Settings()  # Validation happens on construction
            self.successful_effects += 1
            return self._create_success_summary("Settings valid"), True
        except Exception as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Invalid settings: {e}"), False

    # =========================================================================
    # Output Effects
    # =========================================================================

    async def _interpret_write_stdout(self, effect: WriteStdout) -> ExecutionSummary:
        """Write to stdout."""
        sys.stdout.write(effect.text)
        sys.stdout.flush()
        self.successful_effects += 1
        return self._create_success_summary("Wrote to stdout")

    async def _interpret_write_stderr(self, effect: WriteStderr) -> ExecutionSummary:
        """Write to stderr."""
        sys.stderr.write(effect.text)
        sys.stderr.flush()
        self.successful_effects += 1
        return self._create_success_summary("Wrote to stderr")

    async def _interpret_print_info(self, effect: PrintInfo) -> ExecutionSummary:
        """Print info message with Rich formatting."""
        self._console.print(f"[{effect.style}]{effect.message}[/{effect.style}]")
        self.successful_effects += 1
        return self._create_success_summary("Printed info")

    async def _interpret_print_success(self, effect: PrintSuccess) -> ExecutionSummary:
        """Print success message with Rich formatting."""
        self._console.print(f"[{effect.style}]✓ {effect.message}[/{effect.style}]")
        self.successful_effects += 1
        return self._create_success_summary("Printed success")

    async def _interpret_print_warning(self, effect: PrintWarning) -> ExecutionSummary:
        """Print warning message with Rich formatting."""
        self._console.print(f"[{effect.style}]⚠ {effect.message}[/{effect.style}]")
        self.successful_effects += 1
        return self._create_success_summary("Printed warning")

    async def _interpret_print_error(self, effect: PrintError) -> ExecutionSummary:
        """Print error message with Rich formatting."""
        self._error_console.print(f"[{effect.style}]✗ {effect.message}[/{effect.style}]")
        self.successful_effects += 1
        return self._create_success_summary("Printed error")

    async def _interpret_print_table(self, effect: PrintTable) -> ExecutionSummary:
        """Print a Rich table."""
        table = Table(title=effect.title, show_header=True)
        for col_name, col_style in effect.columns:
            table.add_column(col_name, style=col_style)
        for row in effect.rows:
            table.add_row(*row)
        self._console.print(table)
        self.successful_effects += 1
        return self._create_success_summary("Printed table")

    async def _interpret_print_section(self, effect: PrintSection) -> ExecutionSummary:
        """Print a section header."""
        if effect.blank_before:
            self._console.print()
        self._console.print(f"[{effect.style}]{effect.title}[/{effect.style}]")
        if effect.blank_after:
            self._console.print()
        self.successful_effects += 1
        return self._create_success_summary("Printed section")

    async def _interpret_print_indented(self, effect: PrintIndented) -> ExecutionSummary:
        """Print indented text."""
        indent_str = " " * effect.indent
        self._console.print(f"{indent_str}{effect.text}")
        self.successful_effects += 1
        return self._create_success_summary("Printed indented text")

    async def _interpret_print_blank_line(self, _effect: PrintBlankLine) -> ExecutionSummary:
        """Print a blank line."""
        self._console.print()
        self.successful_effects += 1
        return self._create_success_summary("Printed blank line")

    async def _interpret_confirm_action(
        self, effect: ConfirmAction
    ) -> tuple[ExecutionSummary, bool | None]:
        """Handle user confirmation."""
        import click

        try:
            confirmed: bool = click.confirm(effect.message, default=effect.default)
            if not confirmed and effect.abort_on_decline:
                self.failed_effects += 1
                return self._create_error_summary("User declined confirmation"), False
            self.successful_effects += 1
            return self._create_success_summary("User confirmed"), confirmed
        except click.Abort:
            self.failed_effects += 1
            return self._create_error_summary("User aborted"), False

    async def _interpret_kubectl_wait(
        self, effect: KubectlWait
    ) -> tuple[ExecutionSummary, bool | None]:
        """Wait for Kubernetes resources to meet condition."""
        cmd = ["kubectl", "wait"]

        if effect.kubeconfig:
            cmd.extend(["--kubeconfig", str(effect.kubeconfig)])
        if effect.namespace:
            cmd.extend(["--namespace", effect.namespace])
        if effect.all_resources:
            cmd.append("--all")
        if effect.selector:
            cmd.extend(["--selector", effect.selector])

        cmd.extend(
            [
                f"--for=condition={effect.condition}",
                effect.resource,
                f"--timeout={effect.timeout}s",
            ]
        )
        env = self._kubectl_env(effect.kubeconfig)

        output = await _run_subprocess(
            tuple(cmd),
            env=env,
            timeout=float(effect.timeout) + 5.0,  # Add buffer for kubectl timeout
        )

        if output.returncode == 0:
            self.successful_effects += 1
            return self._create_success_summary("Wait condition met"), True
        else:
            self.failed_effects += 1
            stderr = output.stderr.decode("utf-8", errors="replace")
            return self._create_error_summary(f"Wait timed out: {stderr}"), False

    @staticmethod
    def _kubectl_env(kubeconfig: Path | None) -> dict[str, str] | None:
        """Build kubectl subprocess environment with explicit KUBECONFIG override."""
        if kubeconfig is None:
            return None
        env = dict(os.environ)
        env["KUBECONFIG"] = str(kubeconfig)
        return env

    # =========================================================================
    # Composite Effects
    # =========================================================================

    async def _interpret_sequence(self, effect: Sequence) -> ExecutionSummary:
        """Execute effects sequentially (short-circuits on failure)."""
        for sub_effect in effect.effects:
            summary = await self.interpret(sub_effect)
            if not summary.success:
                return summary
        return self._create_success_summary("Sequence completed")

    async def _interpret_parallel(self, effect: Parallel) -> ExecutionSummary:
        """Execute effects concurrently."""
        if effect.max_concurrent:
            semaphore = asyncio.Semaphore(effect.max_concurrent)

            async def limited_interpret(eff: Effect[object]) -> ExecutionSummary:
                async with semaphore:
                    return await self.interpret(eff)

            results = await asyncio.gather(*(limited_interpret(e) for e in effect.effects))
        else:
            results = await asyncio.gather(*(self.interpret(e) for e in effect.effects))

        # Check if any failed
        failed = tuple(r for r in results if not r.success)
        if failed:
            return self._create_error_summary(f"Parallel execution: {len(failed)} effects failed")
        return self._create_success_summary("Parallel execution complete")

    async def _interpret_try(self, effect: Try) -> tuple[ExecutionSummary, object | None]:
        """Execute effect with fallback on failure."""
        summary, value = await self._dispatch_effect(effect.primary)
        if summary.success:
            return summary, value
        else:
            return await self._dispatch_effect(effect.fallback)

    # =========================================================================
    # Gateway Daemon Effects
    # =========================================================================

    async def _interpret_start_gateway_daemon(
        self,
        effect: StartGatewayDaemon,
    ) -> ExecutionSummary:
        """Start gateway daemon from config file."""
        try:
            from prodbox.gateway_daemon import DaemonConfig, GatewayDaemon

            config = DaemonConfig.from_json_file(effect.config_path)
            daemon = GatewayDaemon(config)
            await daemon.start()
            stop_event = asyncio.Event()
            try:
                await stop_event.wait()
            except asyncio.CancelledError:
                pass
            finally:
                await daemon.stop()
            self.successful_effects += 1
            return self._create_success_summary("Gateway daemon stopped")
        except Exception as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Gateway daemon failed: {e}")

    async def _interpret_query_gateway_state(
        self,
        effect: QueryGatewayState,
    ) -> tuple[ExecutionSummary, object | None]:
        """Query running gateway daemon state via REST API."""
        try:
            import json as json_mod

            import httpx

            from prodbox.gateway_daemon import DaemonConfig

            config = DaemonConfig.from_json_file(effect.config_path)
            local = config.node_id
            # Load orders to find our own endpoint
            from prodbox.gateway_daemon import Orders
            from prodbox.gateway_daemon import _parse_json_object as _parse_json

            raw = _parse_json(
                effect.config_path.parent.joinpath(
                    str(config.orders_file),
                ).read_text(encoding="utf-8")
            )
            if raw is None:
                self.failed_effects += 1
                return self._create_error_summary("Could not parse orders"), None

            orders = Orders.from_dict(raw)
            endpoint = orders.peer_by_id(local)
            if endpoint is None:
                self.failed_effects += 1
                return self._create_error_summary(f"Node {local} not in orders"), None

            url = f"https://{endpoint.rest_host}:{endpoint.rest_port}/v1/state"
            cert_tuple = (str(config.cert_file), str(config.key_file))
            async with httpx.AsyncClient(
                verify=str(config.ca_file),
                cert=cert_tuple,
                timeout=5.0,
            ) as client:
                response = await client.get(url)
                state_text = response.text

            self.successful_effects += 1
            state_obj: object = json_mod.loads(state_text)
            return self._create_success_summary("Gateway state retrieved"), state_obj

        except Exception as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Gateway state query failed: {e}"), None

    async def _interpret_generate_gateway_config(
        self,
        effect: GenerateGatewayConfig,
    ) -> ExecutionSummary:
        """Generate a template gateway config file."""
        try:
            import json as json_mod

            template: dict[str, object] = {
                "node_id": effect.node_id,
                "cert_file": f"/path/to/{effect.node_id}.crt",
                "key_file": f"/path/to/{effect.node_id}.key",
                "ca_file": "/path/to/ca.crt",
                "orders_file": "/path/to/orders.json",
                "event_keys": {
                    effect.node_id: "REPLACE_WITH_SECRET_KEY",
                },
                "heartbeat_interval_seconds": 1.0,
                "reconnect_interval_seconds": 1.0,
                "sync_interval_seconds": 5.0,
            }
            content = json_mod.dumps(template, indent=2, sort_keys=True) + "\n"
            effect.output_path.write_text(content, encoding="utf-8")

            self.successful_effects += 1
            return self._create_success_summary(
                f"Gateway config template written to {effect.output_path}",
            )
        except Exception as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Config generation failed: {e}")

    # =========================================================================
    # Pure and Custom Effects
    # =========================================================================

    async def _interpret_pure(self, effect: Pure[T]) -> ExecutionSummary:
        """Execute Pure effect (returns value without side effects)."""
        self.successful_effects += 1
        return self._create_success_summary(f"Pure effect: {effect.description}")

    async def _interpret_custom(self, effect: Custom[T]) -> tuple[ExecutionSummary, object | None]:
        """Execute Custom effect with user-defined function."""
        try:
            result = effect.fn()
            # Handle async functions
            if hasattr(result, "__await__"):
                result = await result

            self.successful_effects += 1
            return self._create_success_summary(f"Custom effect: {effect.description}"), result
        except Exception as e:
            self.failed_effects += 1
            return self._create_error_summary(f"Custom effect failed: {e}"), None


# =============================================================================
# Factory Function
# =============================================================================


def create_interpreter() -> EffectInterpreter:
    """Create a new EffectInterpreter instance."""
    return EffectInterpreter()


# =============================================================================
# Exports
# =============================================================================

__all__ = [
    # Summary types
    "EnvironmentError",
    "ExecutionSummary",
    "DAGExecutionSummary",
    "EffectSuccess",
    "EffectRootCauseFailure",
    "EffectPrerequisiteSkipped",
    "EffectResult",
    # Interpreter
    "EffectInterpreter",
    "create_interpreter",
    # Helper
    "_assert_never",
]
