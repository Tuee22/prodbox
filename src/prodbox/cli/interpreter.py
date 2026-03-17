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
import json
import os
import platform as platform_module
import re
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


@dataclass(frozen=True)
class K8sObjectRef:
    """Typed Kubernetes object reference."""

    resource: str
    name: str
    namespace: str | None = None


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

from prodbox.cli.effect_dag import (  # noqa: E402
    EffectDAG,
    EffectNode,
    PrerequisiteFailurePolicy,
    ReductionError,
)
from prodbox.cli.effects import (  # noqa: E402
    AnnotateProdboxManagedResources,
    CaptureKubectlOutput,
    CaptureSubprocessOutput,
    CheckFileExists,
    CheckServiceStatus,
    CleanupProdboxAnnotatedResources,
    ConfirmAction,
    Custom,
    Effect,
    EnsureHarborRegistry,
    EnsureMinio,
    EnsureProdboxIdentityConfigMap,
    EnsureRetainedLocalStorage,
    FetchPublicIP,
    GenerateGatewayConfig,
    GetJournalLogs,
    HarborRuntime,
    KubectlWait,
    LoadSettings,
    MachineIdentity,
    MinioRuntime,
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
    ResolveMachineIdentity,
    RunKubectlCommand,
    RunPulumiCommand,
    RunSubprocess,
    RunSystemdCommand,
    Sequence,
    StartGatewayDaemon,
    StorageRuntime,
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
from prodbox.lib.prodbox_k8s import PRODBOX_EPHEMERAL_RESOURCE_KINDS  # noqa: E402

# Type variable for effect return types
T = TypeVar("T")
_NO_CALLER_VALUE: object = object()
_PREREQ_FAILURE_PREFIX: str = "Prerequisite failure propagated:"


def _assert_never(value: object) -> Never:
    """Type-safe assertion that code path is unreachable.

    Use at the end of exhaustive match statements to ensure
    all cases are handled. If a new variant is added to the ADT,
    mypy will error until the new case is handled.
    """
    raise AssertionError(f"Unhandled effect type: {type(value).__name__}")


def _terminal_record_text(text: str) -> str:
    """Return terminal output with a trailing newline when needed."""
    match text:
        case "":
            return text
        case _ if text.endswith("\n"):
            return text
        case _:
            return f"{text}\n"


# =============================================================================
# Execution Summary - Pure Data Structure
# =============================================================================


@dataclass(frozen=True)
class EnvironmentError:
    """Environment error with fix hint."""

    tool: str
    message: str
    fix_hint: str | None
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
                        fix_hint=None,
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
        failed_prereqs, missing_prereqs = self._partition_prerequisite_results(
            node=node,
            prereq_results=prereq_results,
        )
        match node.prerequisite_failure_policy:
            case PrerequisiteFailurePolicy.PROPAGATE:
                if failed_prereqs or missing_prereqs:
                    self.failed_effects += 1
                    return (
                        self._create_error_summary(
                            self._format_propagated_prerequisite_failure(
                                failed_prereqs=failed_prereqs,
                                missing_prereqs=missing_prereqs,
                            )
                        ),
                        None,
                    )
            case PrerequisiteFailurePolicy.IGNORE:
                pass

        # Build effect with reduced values if applicable
        effect = node.build_effect(reduced_value, prereq_results)
        return await self._dispatch_effect(effect)

    @staticmethod
    def _partition_prerequisite_results(
        *,
        node: EffectNode[object],
        prereq_results: PrereqResults,
    ) -> tuple[tuple[str, ...], tuple[str, ...]]:
        """Return failing and missing prerequisite IDs for one node."""
        failed = tuple(
            sorted(
                prereq_id
                for prereq_id in node.prerequisites
                if isinstance(prereq_results.get(prereq_id), Failure)
            )
        )
        missing = tuple(
            sorted(
                prereq_id
                for prereq_id in node.prerequisites
                if prereq_results.get(prereq_id) is None
            )
        )
        return failed, missing

    @staticmethod
    def _format_propagated_prerequisite_failure(
        *,
        failed_prereqs: tuple[str, ...],
        missing_prereqs: tuple[str, ...],
    ) -> str:
        """Build deterministic propagated-prerequisite failure message."""
        details: list[str] = []
        if failed_prereqs:
            details.append(f"failed prerequisites: {', '.join(failed_prereqs)}")
        if missing_prereqs:
            details.append(f"missing prerequisites: {', '.join(missing_prereqs)}")
        return f"{_PREREQ_FAILURE_PREFIX} {'; '.join(details)}"

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
        propagated_failures = [
            (effect_id, result.error or "Effect failed")
            for effect_id, result in completed.items()
            if isinstance(result.outcome, EffectRootCauseFailure)
            and (result.error or "Effect failed").startswith(_PREREQ_FAILURE_PREFIX)
        ]
        root_failures = [
            (effect_id, result.error or "Effect failed")
            for effect_id, result in completed.items()
            if isinstance(result.outcome, EffectRootCauseFailure)
            and not (result.error or "Effect failed").startswith(_PREREQ_FAILURE_PREFIX)
        ]
        lines: list[str] = ["DAG execution complete"]
        if root_failures:
            lines.append("Root-cause failures:")
            lines.extend(
                [f"  - {effect_id}: {message}" for effect_id, message in sorted(root_failures)]
            )
        if propagated_failures:
            lines.append("Propagated prerequisite failures:")
            lines.extend(
                [
                    f"  - {effect_id}: {message}"
                    for effect_id, message in sorted(propagated_failures)
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
            case ResolveMachineIdentity():
                return await self._interpret_resolve_machine_identity(effect)

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
            case EnsureHarborRegistry():
                return await self._interpret_ensure_harbor_registry(effect)
            case EnsureRetainedLocalStorage():
                return await self._interpret_ensure_retained_local_storage(effect)
            case EnsureMinio():
                return await self._interpret_ensure_minio(effect)
            case EnsureProdboxIdentityConfigMap():
                return await self._interpret_ensure_prodbox_identity_configmap(effect), None
            case AnnotateProdboxManagedResources():
                return await self._interpret_annotate_prodbox_managed_resources(effect), None
            case CleanupProdboxAnnotatedResources():
                return await self._interpret_cleanup_prodbox_annotated_resources(effect)

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

    async def _interpret_resolve_machine_identity(
        self, effect: ResolveMachineIdentity
    ) -> tuple[ExecutionSummary, MachineIdentity | None]:
        """Resolve machine identity from /etc/machine-id."""
        try:
            raw_machine_id = effect.file_path.read_text(encoding="utf-8").strip().lower()
        except OSError as exc:
            self.failed_effects += 1
            return self._create_error_summary(f"Failed to read machine-id: {exc}"), None

        if re.fullmatch(r"[0-9a-f]{32}", raw_machine_id) is None:
            self.failed_effects += 1
            return (
                self._create_error_summary(
                    f"Invalid machine-id format in {effect.file_path}: '{raw_machine_id}'"
                ),
                None,
            )

        identity = MachineIdentity(
            machine_id=raw_machine_id,
            prodbox_id=f"prodbox-{raw_machine_id}",
        )
        self.successful_effects += 1
        return self._create_success_summary(f"Resolved prodbox-id: {identity.prodbox_id}"), identity

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
        env = dict(os.environ)
        if effect.env:
            env.update(effect.env)

        try:
            output = await _run_subprocess(
                command,
                cwd=effect.cwd,
                env=env,
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
        env = dict(os.environ)
        if effect.env:
            env.update(effect.env)

        try:
            output = await _run_subprocess(
                tuple(command),
                cwd=effect.cwd,
                env=env,
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
        env = dict(os.environ)
        if effect.env:
            env.update(effect.env)

        try:
            output = await _run_subprocess(
                tuple(command),
                cwd=effect.cwd,
                env=env,
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
        env = dict(os.environ)
        if effect.env:
            env.update(effect.env)

        try:
            output = await _run_subprocess(
                tuple(command),
                cwd=effect.cwd,
                env=env,
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
        env = dict(os.environ)
        if effect.env:
            env.update(effect.env)

        try:
            output = await _run_subprocess(
                tuple(command),
                cwd=effect.cwd,
                env=env,
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
        sys.stdout.write(_terminal_record_text(effect.text))
        sys.stdout.flush()
        self.successful_effects += 1
        return self._create_success_summary("Wrote to stdout")

    async def _interpret_write_stderr(self, effect: WriteStderr) -> ExecutionSummary:
        """Write to stderr."""
        sys.stderr.write(_terminal_record_text(effect.text))
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

    @staticmethod
    def _is_not_found_message(stderr: str) -> bool:
        """Return True when kubectl stderr indicates resource/object does not exist."""
        lowered = stderr.lower()
        return "notfound" in lowered or "not found" in lowered

    @staticmethod
    def _is_ignorable_listing_error(stderr: str) -> bool:
        """Return True for kubectl get/list errors that should not fail reconciliation."""
        lowered = stderr.lower()
        return (
            "the server doesn't have a resource type" in lowered
            or "unable to list" in lowered
            or "forbidden" in lowered
        )

    @staticmethod
    def _is_ignorable_annotation_error(stderr: str) -> bool:
        """Return True for resources that are listable but not patchable/annotatable."""
        lowered = stderr.lower()
        return "does not allow this method" in lowered or "methodnotallowed" in lowered

    async def _run_kubectl(
        self,
        *args: str,
        input_data: bytes | None = None,
        timeout: float | None = None,
    ) -> ProcessOutput:
        """Run kubectl in exec mode with typed subprocess output."""
        return await _run_subprocess(
            ("kubectl", *args),
            input_data=input_data,
            timeout=timeout,
        )

    async def _list_api_resources(self, *, namespaced: bool) -> tuple[str, ...] | None:
        """List Kubernetes API resource names for listable resources."""
        output = await self._run_kubectl(
            "api-resources",
            "--verbs=list",
            f"--namespaced={str(namespaced).lower()}",
            "-o",
            "name",
            timeout=30.0,
        )
        if output.returncode != 0:
            return None
        lines = [
            line.strip()
            for line in output.stdout.decode("utf-8", errors="replace").splitlines()
            if line.strip()
        ]
        return tuple(lines)

    @staticmethod
    def _filter_doctrine_managed_resources(resources: tuple[str, ...]) -> tuple[str, ...]:
        """Drop observational resource kinds that must not drive lifecycle cleanup."""
        excluded_resources = frozenset(PRODBOX_EPHEMERAL_RESOURCE_KINDS)
        return tuple(resource for resource in resources if resource not in excluded_resources)

    @staticmethod
    def _parse_object_names(stdout: str) -> tuple[K8sObjectRef, ...]:
        """Parse `kubectl get <resource> -o name` output into typed object refs."""
        refs: list[K8sObjectRef] = []
        for raw_line in stdout.splitlines():
            line = raw_line.strip()
            if "/" not in line:
                continue
            resource, name = line.split("/", maxsplit=1)
            refs.append(K8sObjectRef(resource=resource, name=name))
        return tuple(refs)

    @staticmethod
    def _sort_refs(ref: K8sObjectRef) -> tuple[int, str, str, str]:
        """Deterministic delete/annotate order; delete namespaces last."""
        namespace_rank = 1 if ref.resource == "namespaces" else 0
        namespace_value = ref.namespace or ""
        return (namespace_rank, namespace_value, ref.resource, ref.name)

    @staticmethod
    def _stderr_or_stdout_text(output: ProcessOutput) -> str:
        """Decode stderr (or stdout fallback) from subprocess output."""
        stderr_text = output.stderr.decode("utf-8", errors="replace").strip()
        if stderr_text != "":
            return stderr_text
        return output.stdout.decode("utf-8", errors="replace").strip()

    @staticmethod
    def _render_rke2_registries_yaml(*, registry_endpoint: str, mirror_project: str) -> str:
        """Render deterministic RKE2 registries mirror configuration."""
        return "\n".join(
            [
                "mirrors:",
                "  docker.io:",
                "    endpoint:",
                f'      - "http://{registry_endpoint}"',
                "    rewrite:",
                f'      "^(.*)$": "{mirror_project}/$1"',
                "configs:",
                f'  "{registry_endpoint}":',
                "    tls:",
                "      insecure_skip_verify: true",
                "",
            ]
        )

    async def _write_root_file_if_changed(
        self,
        *,
        file_path: Path,
        content: str,
    ) -> tuple[bool, str | None]:
        """Write root-owned file via sudo tee only when contents differ."""
        try:
            existing_content = file_path.read_text(encoding="utf-8")
        except OSError:
            existing_content = ""
        if existing_content == content:
            return False, None

        mkdir_output = await _run_subprocess(
            ("sudo", "mkdir", "-p", str(file_path.parent)),
            timeout=20.0,
        )
        if mkdir_output.returncode != 0:
            return (
                False,
                f"Failed to create parent dir for {file_path}: {self._stderr_or_stdout_text(mkdir_output)}",
            )

        write_output = await _run_subprocess(
            ("sudo", "tee", str(file_path)),
            input_data=content.encode("utf-8"),
            timeout=30.0,
        )
        if write_output.returncode != 0:
            return (
                False,
                f"Failed to write {file_path}: {self._stderr_or_stdout_text(write_output)}",
            )
        return True, None

    async def _ensure_harbor_project(
        self,
        *,
        registry_endpoint: str,
        admin_user: str,
        admin_password: str,
        project_name: str,
    ) -> str | None:
        """Ensure Harbor project exists for prodbox mirror and custom image repositories."""
        try:
            import httpx
        except Exception as error:
            return f"Failed to import httpx for Harbor API calls: {error}"

        base_url = f"http://{registry_endpoint}/api/v2.0"
        try:
            async with httpx.AsyncClient(
                auth=(admin_user, admin_password),
                timeout=20.0,
            ) as client:
                project_payload = "{" f'"project_name":"{project_name}",' '"public":true' "}"
                create_response = await client.post(
                    f"{base_url}/projects",
                    content=project_payload,
                    headers={"Content-Type": "application/json"},
                )
                if create_response.status_code in (201, 409):
                    return None
                return (
                    f"Failed to create Harbor project '{project_name}': "
                    f"HTTP {create_response.status_code}: {create_response.text}"
                )
        except Exception as error:
            return f"Failed Harbor API call for project '{project_name}': {error}"

    @staticmethod
    def _normalize_dockerhub_image_ref(image: str) -> str | None:
        """Normalize container image ref to docker.io form for mirroring."""
        trimmed = image.strip()
        if trimmed == "":
            return None
        segments = trimmed.split("/", maxsplit=1)
        first = segments[0]
        has_registry_prefix = "." in first or ":" in first or first == "localhost"

        if has_registry_prefix:
            match first:
                case "docker.io" | "index.docker.io" | "registry-1.docker.io":
                    if len(segments) < 2:
                        return None
                    remainder = segments[1]
                case _:
                    return None
        else:
            remainder = trimmed

        if remainder == "" or "@" in remainder:
            return None
        if "/" not in remainder:
            remainder = f"library/{remainder}"
        return f"docker.io/{remainder}"

    @staticmethod
    def _mirror_target_for_source(
        *,
        source: str,
        registry_endpoint: str,
        mirror_project: str,
    ) -> str | None:
        """Build Harbor target image ref for one normalized docker.io source image."""
        docker_prefix = "docker.io/"
        if not source.startswith(docker_prefix):
            return None
        source_path = source[len(docker_prefix) :]
        if source_path == "":
            return None
        return f"{registry_endpoint}/{mirror_project}/{source_path}"

    async def _collect_cluster_container_images(self) -> tuple[tuple[str, ...], str | None]:
        """Collect all container image refs used by current cluster pods."""
        output = await self._run_kubectl(
            "get",
            "pods",
            "-A",
            "-o",
            'jsonpath={range .items[*]}{range .spec.containers[*]}{.image}{"\\n"}{end}{end}',
            timeout=45.0,
        )
        if output.returncode != 0:
            stderr = output.stderr.decode("utf-8", errors="replace")
            return (), f"Failed to list cluster container images: {stderr}"
        lines = [
            line.strip()
            for line in output.stdout.decode("utf-8", errors="replace").splitlines()
            if line.strip() != ""
        ]
        unique_images = tuple(sorted(set(lines)))
        return unique_images, None

    async def _mirror_cluster_images_once(
        self,
        *,
        registry_endpoint: str,
        mirror_project: str,
    ) -> tuple[str, ...]:
        """Mirror docker.io images currently referenced by cluster pods into Harbor."""
        images, images_error = await self._collect_cluster_container_images()
        if images_error is not None:
            return (images_error,)

        errors: list[str] = []
        for image in images:
            source = self._normalize_dockerhub_image_ref(image)
            if source is None:
                continue
            source_path = source.removeprefix("docker.io/")
            if source_path.startswith("goharbor/"):
                # Harbor's own chart images do not need local mirroring.
                continue
            target = self._mirror_target_for_source(
                source=source,
                registry_endpoint=registry_endpoint,
                mirror_project=mirror_project,
            )
            if target is None:
                continue

            inspect_output = await _run_subprocess(
                ("docker", "manifest", "inspect", target),
                timeout=30.0,
            )
            if inspect_output.returncode == 0:
                continue

            pull_output = await _run_subprocess(
                ("docker", "pull", source),
                timeout=300.0,
            )
            if pull_output.returncode != 0:
                errors.append(
                    f"docker pull {source} failed: {self._stderr_or_stdout_text(pull_output)}"
                )
                continue

            tag_output = await _run_subprocess(
                ("docker", "tag", source, target),
                timeout=30.0,
            )
            if tag_output.returncode != 0:
                errors.append(
                    f"docker tag {source} -> {target} failed: {self._stderr_or_stdout_text(tag_output)}"
                )
                continue

            push_output = await _run_subprocess(
                ("docker", "push", target),
                timeout=300.0,
            )
            if push_output.returncode != 0:
                errors.append(
                    f"docker push {target} failed: {self._stderr_or_stdout_text(push_output)}"
                )
        return tuple(errors)

    async def _ensure_gateway_image(
        self,
        *,
        effect: EnsureHarborRegistry,
        registry_endpoint: str,
    ) -> tuple[str | None, str | None]:
        """Ensure gateway image exists in Harbor by building/pushing if needed."""
        gateway_tag = effect.machine_identity.prodbox_id[:63]
        gateway_image = f"{registry_endpoint}/{effect.gateway_image_repository}:{gateway_tag}"
        inspect_output = await _run_subprocess(
            ("docker", "manifest", "inspect", gateway_image),
            timeout=30.0,
        )
        if inspect_output.returncode == 0:
            return gateway_image, None

        if not effect.gateway_dockerfile.exists():
            return None, f"Gateway Dockerfile not found: {effect.gateway_dockerfile}"

        build_output = await _run_subprocess(
            (
                "docker",
                "build",
                "-f",
                str(effect.gateway_dockerfile),
                "-t",
                gateway_image,
                str(effect.gateway_build_context),
            ),
            timeout=900.0,
        )
        if build_output.returncode != 0:
            return None, f"docker build failed: {self._stderr_or_stdout_text(build_output)}"

        push_output = await _run_subprocess(
            ("docker", "push", gateway_image),
            timeout=600.0,
        )
        if push_output.returncode != 0:
            return None, f"docker push failed: {self._stderr_or_stdout_text(push_output)}"
        return gateway_image, None

    async def _import_image_into_rke2_containerd(self, image_ref: str) -> str | None:
        """Import image into the local RKE2 containerd cache for fast local pulls."""
        containerd_socket_candidates = (
            Path("/run/k3s/containerd/containerd.sock"),
            Path("/run/rke2/containerd/containerd.sock"),
        )
        socket_path = next(
            (path for path in containerd_socket_candidates if path.exists()),
            None,
        )
        if socket_path is None:
            return (
                "RKE2 containerd socket not found at expected paths: "
                "/run/k3s/containerd/containerd.sock, /run/rke2/containerd/containerd.sock"
            )

        save_output = await _run_subprocess(
            ("docker", "save", image_ref),
            timeout=900.0,
        )
        if save_output.returncode != 0:
            return f"docker save failed: {self._stderr_or_stdout_text(save_output)}"

        import_output = await _run_subprocess(
            (
                "sudo",
                "ctr",
                "--address",
                str(socket_path),
                "-n",
                "k8s.io",
                "images",
                "import",
                "-",
            ),
            input_data=save_output.stdout,
            timeout=900.0,
        )
        if import_output.returncode != 0:
            return f"ctr image import failed: {self._stderr_or_stdout_text(import_output)}"
        return None

    async def _interpret_ensure_harbor_registry(
        self, effect: EnsureHarborRegistry
    ) -> tuple[ExecutionSummary, HarborRuntime | None]:
        """Install/reconcile Harbor and ensure local registry doctrine runtime."""
        registry_endpoint = effect.registry_endpoint

        helm_repo_add = await _run_subprocess(
            ("helm", "repo", "add", effect.repository_name, effect.repository_url),
            timeout=30.0,
        )
        if helm_repo_add.returncode != 0:
            repo_add_error = self._stderr_or_stdout_text(helm_repo_add).lower()
            if "already exists" not in repo_add_error:
                self.failed_effects += 1
                return (
                    self._create_error_summary(f"Failed to add Harbor helm repo: {repo_add_error}"),
                    None,
                )

        helm_repo_update = await _run_subprocess(
            ("helm", "repo", "update"),
            timeout=120.0,
        )
        if helm_repo_update.returncode != 0:
            self.failed_effects += 1
            return (
                self._create_error_summary(
                    f"Failed to update helm repos: {self._stderr_or_stdout_text(helm_repo_update)}"
                ),
                None,
            )

        registry_port = registry_endpoint.split(":")[-1]
        install_command = (
            "helm",
            "upgrade",
            "--install",
            effect.release_name,
            f"{effect.repository_name}/harbor",
            "--namespace",
            effect.namespace,
            "--create-namespace",
            "--set",
            "expose.type=nodePort",
            "--set",
            "expose.tls.enabled=false",
            "--set",
            f"expose.nodePort.ports.http.nodePort={registry_port}",
            "--set",
            f"externalURL=http://{registry_endpoint}",
            "--set",
            f"harborAdminPassword={effect.admin_password}",
            "--set",
            "persistence.enabled=false",
        )
        install_output = await _run_subprocess(
            install_command,
            timeout=effect.install_timeout_seconds,
        )
        if install_output.returncode != 0:
            self.failed_effects += 1
            return (
                self._create_error_summary(
                    f"Failed to install Harbor chart: {self._stderr_or_stdout_text(install_output)}"
                ),
                None,
            )

        # Harbor API and registry login flow traverse the nginx NodePort service,
        # so deploy-time readiness must include the external-serving ingress layer.
        for deployment in ("harbor-core", "harbor-registry", "harbor-nginx"):
            wait_output = await self._run_kubectl(
                "wait",
                "--for=condition=Available",
                f"deployment/{deployment}",
                "-n",
                effect.namespace,
                f"--timeout={effect.wait_timeout_seconds}s",
                timeout=float(effect.wait_timeout_seconds) + 10.0,
            )
            if wait_output.returncode != 0:
                self.failed_effects += 1
                return (
                    self._create_error_summary(
                        f"Harbor deployment {deployment} not ready: "
                        f"{wait_output.stderr.decode('utf-8', errors='replace')}"
                    ),
                    None,
                )

        login_output = await _run_subprocess(
            (
                "docker",
                "login",
                registry_endpoint,
                "--username",
                effect.admin_user,
                "--password",
                effect.admin_password,
            ),
            timeout=60.0,
        )
        if login_output.returncode != 0:
            self.failed_effects += 1
            return (
                self._create_error_summary(
                    f"Docker login to Harbor failed: {self._stderr_or_stdout_text(login_output)}"
                ),
                None,
            )

        gateway_project = effect.gateway_image_repository.split("/", maxsplit=1)[0]
        harbor_projects = (
            (effect.mirror_project,)
            if gateway_project == effect.mirror_project
            else (effect.mirror_project, gateway_project)
        )
        for project_name in harbor_projects:
            project_error = await self._ensure_harbor_project(
                registry_endpoint=registry_endpoint,
                admin_user=effect.admin_user,
                admin_password=effect.admin_password,
                project_name=project_name,
            )
            if project_error is not None:
                self.failed_effects += 1
                return self._create_error_summary(project_error), None

        mirror_errors: tuple[str, ...] = ()
        if effect.mirror_cluster_images:
            mirror_errors = await self._mirror_cluster_images_once(
                registry_endpoint=registry_endpoint,
                mirror_project=effect.mirror_project,
            )

        gateway_image, gateway_error = await self._ensure_gateway_image(
            effect=effect,
            registry_endpoint=registry_endpoint,
        )
        if gateway_error is not None or gateway_image is None:
            self.failed_effects += 1
            return (
                self._create_error_summary(
                    f"Failed to ensure Harbor gateway image: {gateway_error or 'unknown error'}"
                ),
                None,
            )

        containerd_import_error = await self._import_image_into_rke2_containerd(gateway_image)
        if containerd_import_error is not None:
            self.failed_effects += 1
            return (
                self._create_error_summary(
                    "Failed to import gateway image into RKE2 containerd: "
                    f"{containerd_import_error}"
                ),
                None,
            )

        registries_yaml = self._render_rke2_registries_yaml(
            registry_endpoint=registry_endpoint,
            mirror_project=effect.mirror_project,
        )
        registries_changed, registries_error = await self._write_root_file_if_changed(
            file_path=effect.registries_file_path,
            content=registries_yaml,
        )
        if registries_error is not None:
            self.failed_effects += 1
            return self._create_error_summary(registries_error), None

        if registries_changed:
            restart_output = await _run_subprocess(
                ("sudo", "systemctl", "restart", "rke2-server.service"),
                timeout=120.0,
            )
            if restart_output.returncode != 0:
                self.failed_effects += 1
                return (
                    self._create_error_summary(
                        f"Failed to restart RKE2 after registries update: "
                        f"{self._stderr_or_stdout_text(restart_output)}"
                    ),
                    None,
                )
            cluster_info_output = await self._run_kubectl("cluster-info", timeout=60.0)
            if cluster_info_output.returncode != 0:
                self.failed_effects += 1
                return (
                    self._create_error_summary(
                        "Cluster not reachable after RKE2 restart: "
                        + cluster_info_output.stderr.decode("utf-8", errors="replace")
                    ),
                    None,
                )

        self.successful_effects += 1
        mirror_warning_suffix = ""
        if mirror_errors:
            mirror_warning_suffix = (
                f"; Docker Hub mirror warnings ({len(mirror_errors)}): "
                + "; ".join(mirror_errors[:2])
            )
        return (
            self._create_success_summary(
                "Ensured Harbor registry runtime and gateway image "
                f"({gateway_image}){mirror_warning_suffix}"
            ),
            HarborRuntime(
                registry_endpoint=registry_endpoint,
                gateway_image=gateway_image,
            ),
        )

    async def _resolve_single_node_hostname(self) -> tuple[str | None, str | None]:
        """Resolve exactly one node hostname for deterministic single-node PV affinity."""
        output = await self._run_kubectl(
            "get",
            "nodes",
            "-o",
            "jsonpath={.items[*].metadata.name}",
            timeout=30.0,
        )
        if output.returncode != 0:
            return None, (
                "Failed to list cluster nodes for retained storage policy: "
                + output.stderr.decode("utf-8", errors="replace")
            )
        names = tuple(
            token.strip()
            for token in output.stdout.decode("utf-8", errors="replace").split()
            if token.strip() != ""
        )
        if len(names) != 1:
            return None, (
                "Retained storage policy requires a single-node cluster; "
                f"detected {len(names)} nodes"
            )
        return names[0], None

    async def _ensure_host_storage_path(self, host_path: Path) -> str | None:
        """Create retained host storage path before PV reconciliation."""
        mkdir_output = await _run_subprocess(
            ("sudo", "mkdir", "-p", str(host_path)),
            timeout=20.0,
        )
        if mkdir_output.returncode != 0:
            return (
                f"Failed to create retained host storage path {host_path}: "
                f"{self._stderr_or_stdout_text(mkdir_output)}"
            )
        chown_output = await _run_subprocess(
            ("sudo", "chown", "-R", "1000:1000", str(host_path)),
            timeout=20.0,
        )
        if chown_output.returncode != 0:
            return (
                f"Failed to set ownership on retained host storage path {host_path}: "
                f"{self._stderr_or_stdout_text(chown_output)}"
            )
        chmod_output = await _run_subprocess(
            ("sudo", "chmod", "0770", str(host_path)),
            timeout=20.0,
        )
        if chmod_output.returncode != 0:
            return (
                f"Failed to set permissions on retained host storage path {host_path}: "
                f"{self._stderr_or_stdout_text(chmod_output)}"
            )
        return None

    async def _persistent_volume_phase_by_name(
        self,
        persistent_volume_name: str,
    ) -> tuple[str | None, str | None]:
        """Read one PersistentVolume phase, or None when the volume does not exist."""
        output = await self._run_kubectl(
            "get",
            "pv",
            persistent_volume_name,
            "-o",
            "jsonpath={.status.phase}",
            "--ignore-not-found=true",
            timeout=25.0,
        )
        if output.returncode != 0:
            return (
                None,
                "Failed to query retained PersistentVolume "
                f"{persistent_volume_name}: " + output.stderr.decode("utf-8", errors="replace"),
            )
        phase = output.stdout.decode("utf-8", errors="replace").strip()
        if phase == "":
            return None, None
        return phase, None

    async def _interpret_ensure_retained_local_storage(
        self, effect: EnsureRetainedLocalStorage
    ) -> tuple[ExecutionSummary, StorageRuntime | None]:
        """Ensure static retained StorageClass/PV/PVC for deterministic rebinding."""
        node_hostname, node_error = await self._resolve_single_node_hostname()
        if node_error is not None or node_hostname is None:
            self.failed_effects += 1
            return (
                self._create_error_summary(node_error or "unknown node resolution error"),
                None,
            )

        host_path = (
            effect.host_storage_base_path
            / effect.machine_identity.prodbox_id
            / effect.persistent_volume_name
        )
        host_path_error = await self._ensure_host_storage_path(host_path)
        if host_path_error is not None:
            self.failed_effects += 1
            return self._create_error_summary(host_path_error), None

        existing_phase, existing_phase_error = await self._persistent_volume_phase_by_name(
            effect.persistent_volume_name
        )
        if existing_phase_error is not None:
            self.failed_effects += 1
            return self._create_error_summary(existing_phase_error), None

        if existing_phase in ("Released", "Failed"):
            delete_output = await self._run_kubectl(
                "delete",
                "pv",
                effect.persistent_volume_name,
                "--ignore-not-found=true",
                "--wait=true",
                timeout=60.0,
            )
            if delete_output.returncode != 0:
                self.failed_effects += 1
                return (
                    self._create_error_summary(
                        "Failed to reset stale retained PersistentVolume "
                        f"{effect.persistent_volume_name}: "
                        + delete_output.stderr.decode("utf-8", errors="replace")
                    ),
                    None,
                )

        manifest: dict[str, object] = {
            "apiVersion": "v1",
            "kind": "List",
            "items": [
                {
                    "apiVersion": "storage.k8s.io/v1",
                    "kind": "StorageClass",
                    "metadata": {
                        "name": effect.storage_class_name,
                        "annotations": {effect.annotation_key: effect.machine_identity.prodbox_id},
                        "labels": {effect.label_key: effect.label_value},
                    },
                    "provisioner": "kubernetes.io/no-provisioner",
                    "volumeBindingMode": "WaitForFirstConsumer",
                    "reclaimPolicy": "Retain",
                    "allowVolumeExpansion": True,
                },
                {
                    "apiVersion": "v1",
                    "kind": "PersistentVolume",
                    "metadata": {
                        "name": effect.persistent_volume_name,
                        "annotations": {effect.annotation_key: effect.machine_identity.prodbox_id},
                        "labels": {effect.label_key: effect.label_value},
                    },
                    "spec": {
                        "capacity": {"storage": effect.storage_size},
                        "volumeMode": "Filesystem",
                        "accessModes": ["ReadWriteOnce"],
                        "persistentVolumeReclaimPolicy": "Retain",
                        "storageClassName": effect.storage_class_name,
                        "claimRef": {
                            "namespace": effect.namespace,
                            "name": effect.persistent_volume_claim_name,
                        },
                        "hostPath": {
                            "path": str(host_path),
                            "type": "DirectoryOrCreate",
                        },
                        "nodeAffinity": {
                            "required": {
                                "nodeSelectorTerms": [
                                    {
                                        "matchExpressions": [
                                            {
                                                "key": "kubernetes.io/hostname",
                                                "operator": "In",
                                                "values": [node_hostname],
                                            }
                                        ]
                                    }
                                ]
                            }
                        },
                    },
                },
                {
                    "apiVersion": "v1",
                    "kind": "PersistentVolumeClaim",
                    "metadata": {
                        "name": effect.persistent_volume_claim_name,
                        "namespace": effect.namespace,
                        "annotations": {effect.annotation_key: effect.machine_identity.prodbox_id},
                        "labels": {effect.label_key: effect.label_value},
                    },
                    "spec": {
                        "accessModes": ["ReadWriteOnce"],
                        "volumeMode": "Filesystem",
                        "storageClassName": effect.storage_class_name,
                        "volumeName": effect.persistent_volume_name,
                        "resources": {"requests": {"storage": effect.storage_size}},
                    },
                },
            ],
        }
        output = await self._run_kubectl(
            "apply",
            "-f",
            "-",
            input_data=json.dumps(manifest).encode("utf-8"),
            timeout=45.0,
        )
        if output.returncode != 0:
            self.failed_effects += 1
            return (
                self._create_error_summary(
                    "Failed to ensure retained local storage resources: "
                    + output.stderr.decode("utf-8", errors="replace")
                ),
                None,
            )

        self.successful_effects += 1
        return (
            self._create_success_summary(
                "Ensured retained local storage resources "
                f"({effect.storage_class_name}, {effect.persistent_volume_name}, "
                f"{effect.persistent_volume_claim_name})"
            ),
            StorageRuntime(
                storage_class_name=effect.storage_class_name,
                persistent_volume_name=effect.persistent_volume_name,
                persistent_volume_claim_name=effect.persistent_volume_claim_name,
                host_path=host_path,
            ),
        )

    async def _interpret_ensure_minio(
        self,
        effect: EnsureMinio,
    ) -> tuple[ExecutionSummary, MinioRuntime | None]:
        """Install/reconcile MinIO runtime via official minio/minio Helm chart."""
        repo_add = await _run_subprocess(
            ("helm", "repo", "add", effect.repository_name, effect.repository_url),
            timeout=30.0,
        )
        if repo_add.returncode != 0:
            repo_add_error = self._stderr_or_stdout_text(repo_add).lower()
            if "already exists" not in repo_add_error:
                self.failed_effects += 1
                return (
                    self._create_error_summary(f"Failed to add MinIO helm repo: {repo_add_error}"),
                    None,
                )

        repo_update = await _run_subprocess(("helm", "repo", "update"), timeout=120.0)
        if repo_update.returncode != 0:
            self.failed_effects += 1
            return (
                self._create_error_summary(
                    "Failed to update helm repos for MinIO: "
                    + self._stderr_or_stdout_text(repo_update)
                ),
                None,
            )

        install_output = await _run_subprocess(
            (
                "helm",
                "upgrade",
                "--install",
                effect.release_name,
                effect.chart_ref,
                "--version",
                effect.chart_version,
                "--namespace",
                effect.namespace,
                "--create-namespace",
                "--set",
                "mode=standalone",
                "--set",
                "replicas=1",
                "--set",
                "persistence.enabled=true",
                "--set",
                f"persistence.existingClaim={effect.existing_claim}",
                "--set",
                f"persistence.size={effect.storage_size}",
                "--set",
                "service.type=ClusterIP",
                "--set",
                "consoleService.type=ClusterIP",
                "--set",
                "resources.requests.memory=256Mi",
                "--set",
                "resources.requests.cpu=100m",
                "--set",
                "resources.limits.memory=512Mi",
            ),
            timeout=effect.install_timeout_seconds,
        )
        if install_output.returncode != 0:
            self.failed_effects += 1
            return (
                self._create_error_summary(
                    "Failed to install MinIO chart: " + self._stderr_or_stdout_text(install_output)
                ),
                None,
            )

        wait_output = await self._run_kubectl(
            "wait",
            "--for=condition=Available",
            f"deployment/{effect.release_name}",
            "-n",
            effect.namespace,
            f"--timeout={effect.wait_timeout_seconds}s",
            timeout=float(effect.wait_timeout_seconds) + 10.0,
        )
        if wait_output.returncode != 0:
            self.failed_effects += 1
            return (
                self._create_error_summary(
                    f"MinIO deployment {effect.release_name} not ready: "
                    + wait_output.stderr.decode("utf-8", errors="replace")
                ),
                None,
            )

        self.successful_effects += 1
        return (
            self._create_success_summary(
                f"Ensured MinIO runtime in namespace '{effect.namespace}' "
                f"with PVC '{effect.existing_claim}'"
            ),
            MinioRuntime(
                namespace=effect.namespace,
                release_name=effect.release_name,
                persistent_volume_claim_name=effect.existing_claim,
            ),
        )

    async def _interpret_ensure_prodbox_identity_configmap(
        self, effect: EnsureProdboxIdentityConfigMap
    ) -> ExecutionSummary:
        """Create/update the prodbox namespace and identity ConfigMap."""
        manifest: dict[str, object] = {
            "apiVersion": "v1",
            "kind": "List",
            "items": [
                {
                    "apiVersion": "v1",
                    "kind": "Namespace",
                    "metadata": {
                        "name": effect.namespace,
                        "annotations": {effect.annotation_key: effect.machine_identity.prodbox_id},
                        "labels": {effect.label_key: effect.label_value},
                    },
                },
                {
                    "apiVersion": "v1",
                    "kind": "ConfigMap",
                    "metadata": {
                        "name": effect.configmap_name,
                        "namespace": effect.namespace,
                        "annotations": {effect.annotation_key: effect.machine_identity.prodbox_id},
                        "labels": {effect.label_key: effect.label_value},
                    },
                    "data": {
                        "machine_id": effect.machine_identity.machine_id,
                        "prodbox_id": effect.machine_identity.prodbox_id,
                    },
                },
            ],
        }
        output = await self._run_kubectl(
            "apply",
            "-f",
            "-",
            input_data=json.dumps(manifest).encode("utf-8"),
            timeout=30.0,
        )
        if output.returncode != 0:
            self.failed_effects += 1
            stderr = output.stderr.decode("utf-8", errors="replace")
            return self._create_error_summary(
                f"Failed to ensure prodbox identity ConfigMap: {stderr}"
            )

        self.successful_effects += 1
        return self._create_success_summary(
            f"Ensured prodbox identity ConfigMap in namespace '{effect.namespace}'"
        )

    async def _annotate_ref(
        self,
        *,
        ref: K8sObjectRef,
        annotation_key: str,
        prodbox_id: str,
        label_key: str,
        label_value: str,
    ) -> str | None:
        """Apply prodbox annotation+label to one Kubernetes object reference."""
        object_ref = f"{ref.resource}/{ref.name}"
        annotate_args: list[str] = [
            "annotate",
            object_ref,
            f"{annotation_key}={prodbox_id}",
            "--overwrite",
        ]
        label_args: list[str] = [
            "label",
            object_ref,
            f"{label_key}={label_value}",
            "--overwrite",
        ]
        if ref.namespace is not None:
            annotate_args.extend(["-n", ref.namespace])
            label_args.extend(["-n", ref.namespace])

        annotate_output = await self._run_kubectl(*annotate_args, timeout=20.0)
        if annotate_output.returncode != 0:
            annotate_stderr = annotate_output.stderr.decode("utf-8", errors="replace")
            if not (
                self._is_not_found_message(annotate_stderr)
                or self._is_ignorable_annotation_error(annotate_stderr)
            ):
                return f"annotate {object_ref} failed: {annotate_stderr}"

        label_output = await self._run_kubectl(*label_args, timeout=20.0)
        if label_output.returncode != 0:
            label_stderr = label_output.stderr.decode("utf-8", errors="replace")
            if not (
                self._is_not_found_message(label_stderr)
                or self._is_ignorable_annotation_error(label_stderr)
            ):
                return f"label {object_ref} failed: {label_stderr}"
        return None

    async def _annotate_namespaced_objects(
        self,
        *,
        namespace: str,
        resources: tuple[str, ...],
        annotation_key: str,
        prodbox_id: str,
        label_key: str,
        label_value: str,
    ) -> tuple[int, tuple[str, ...]]:
        """Annotate all namespaced objects in one namespace."""
        errors: list[str] = []
        annotated_count = 0
        for resource in resources:
            output = await self._run_kubectl(
                "get",
                resource,
                "-n",
                namespace,
                "-o",
                "name",
                "--ignore-not-found=true",
                timeout=20.0,
            )
            if output.returncode != 0:
                stderr = output.stderr.decode("utf-8", errors="replace")
                if not self._is_ignorable_listing_error(stderr):
                    errors.append(f"list {resource} in {namespace} failed: {stderr}")
                continue
            refs = self._parse_object_names(output.stdout.decode("utf-8", errors="replace"))
            if not refs:
                continue

            annotate_output = await self._run_kubectl(
                "annotate",
                resource,
                "--all",
                f"{annotation_key}={prodbox_id}",
                "--overwrite",
                "-n",
                namespace,
                timeout=20.0,
            )
            if annotate_output.returncode != 0:
                annotate_stderr = annotate_output.stderr.decode("utf-8", errors="replace")
                if not (
                    self._is_not_found_message(annotate_stderr)
                    or self._is_ignorable_annotation_error(annotate_stderr)
                ):
                    errors.append(f"annotate {resource} in {namespace} failed: {annotate_stderr}")
                continue

            label_output = await self._run_kubectl(
                "label",
                resource,
                "--all",
                f"{label_key}={label_value}",
                "--overwrite",
                "-n",
                namespace,
                timeout=20.0,
            )
            if label_output.returncode != 0:
                label_stderr = label_output.stderr.decode("utf-8", errors="replace")
                if not (
                    self._is_not_found_message(label_stderr)
                    or self._is_ignorable_annotation_error(label_stderr)
                ):
                    errors.append(f"label {resource} in {namespace} failed: {label_stderr}")
                continue

            annotated_count += len(refs)
        return annotated_count, tuple(errors)

    async def _annotate_cluster_objects_for_instance(
        self,
        *,
        instance: str,
        resources: tuple[str, ...],
        annotation_key: str,
        prodbox_id: str,
        label_key: str,
        label_value: str,
    ) -> tuple[int, tuple[str, ...]]:
        """Annotate cluster-scoped Helm objects by app.kubernetes.io/instance label."""
        errors: list[str] = []
        annotated_count = 0
        selector = f"app.kubernetes.io/instance={instance}"
        for resource in resources:
            output = await self._run_kubectl(
                "get",
                resource,
                "-l",
                selector,
                "-o",
                "name",
                "--ignore-not-found=true",
                timeout=20.0,
            )
            if output.returncode != 0:
                stderr = output.stderr.decode("utf-8", errors="replace")
                if not self._is_ignorable_listing_error(stderr):
                    errors.append(f"list cluster {resource} for {instance} failed: {stderr}")
                continue
            refs = self._parse_object_names(output.stdout.decode("utf-8", errors="replace"))
            if not refs:
                continue

            annotate_output = await self._run_kubectl(
                "annotate",
                resource,
                "-l",
                selector,
                f"{annotation_key}={prodbox_id}",
                "--overwrite",
                timeout=20.0,
            )
            if annotate_output.returncode != 0:
                annotate_stderr = annotate_output.stderr.decode("utf-8", errors="replace")
                if not (
                    self._is_not_found_message(annotate_stderr)
                    or self._is_ignorable_annotation_error(annotate_stderr)
                ):
                    errors.append(
                        f"annotate cluster {resource} for {instance} failed: {annotate_stderr}"
                    )
                continue

            label_output = await self._run_kubectl(
                "label",
                resource,
                "-l",
                selector,
                f"{label_key}={label_value}",
                "--overwrite",
                timeout=20.0,
            )
            if label_output.returncode != 0:
                label_stderr = label_output.stderr.decode("utf-8", errors="replace")
                if not (
                    self._is_not_found_message(label_stderr)
                    or self._is_ignorable_annotation_error(label_stderr)
                ):
                    errors.append(f"label cluster {resource} for {instance} failed: {label_stderr}")
                continue

            annotated_count += len(refs)
        return annotated_count, tuple(errors)

    async def _annotate_prodbox_crds(
        self,
        *,
        annotation_key: str,
        prodbox_id: str,
        label_key: str,
        label_value: str,
    ) -> tuple[int, tuple[str, ...]]:
        """Annotate known prodbox-installed CRDs by API group suffix."""
        output = await self._run_kubectl("get", "crd", "-o", "name", timeout=20.0)
        if output.returncode != 0:
            stderr = output.stderr.decode("utf-8", errors="replace")
            if self._is_ignorable_listing_error(stderr):
                return 0, ()
            return 0, (f"list CRDs failed: {stderr}",)

        suffixes = (".metallb.io", ".cert-manager.io", ".acme.cert-manager.io")
        errors: list[str] = []
        annotated_count = 0
        refs = self._parse_object_names(output.stdout.decode("utf-8", errors="replace"))
        for ref in refs:
            should_annotate = any(ref.name.endswith(suffix) for suffix in suffixes)
            if not should_annotate:
                continue
            error = await self._annotate_ref(
                ref=ref,
                annotation_key=annotation_key,
                prodbox_id=prodbox_id,
                label_key=label_key,
                label_value=label_value,
            )
            if error is None:
                annotated_count += 1
            else:
                errors.append(error)
        return annotated_count, tuple(errors)

    async def _interpret_annotate_prodbox_managed_resources(
        self, effect: AnnotateProdboxManagedResources
    ) -> ExecutionSummary:
        """Ensure prodbox annotation/label doctrine on managed Kubernetes resources."""
        namespaced_resources = await self._list_api_resources(namespaced=True)
        cluster_resources = await self._list_api_resources(namespaced=False)
        if namespaced_resources is None or cluster_resources is None:
            self.failed_effects += 1
            return self._create_error_summary("Failed to list Kubernetes API resources")
        namespaced_resources = self._filter_doctrine_managed_resources(namespaced_resources)
        cluster_resources = self._filter_doctrine_managed_resources(cluster_resources)

        total_annotated = 0
        errors: list[str] = []

        for namespace in effect.managed_namespaces:
            namespace_ref = K8sObjectRef(resource="namespace", name=namespace)
            namespace_error = await self._annotate_ref(
                ref=namespace_ref,
                annotation_key=effect.annotation_key,
                prodbox_id=effect.prodbox_id,
                label_key=effect.label_key,
                label_value=effect.label_value,
            )
            if namespace_error is None:
                total_annotated += 1
            else:
                if not self._is_not_found_message(namespace_error):
                    errors.append(namespace_error)

            ns_count, ns_errors = await self._annotate_namespaced_objects(
                namespace=namespace,
                resources=namespaced_resources,
                annotation_key=effect.annotation_key,
                prodbox_id=effect.prodbox_id,
                label_key=effect.label_key,
                label_value=effect.label_value,
            )
            total_annotated += ns_count
            errors.extend(ns_errors)

        for instance in effect.helm_instances:
            cluster_count, cluster_errors = await self._annotate_cluster_objects_for_instance(
                instance=instance,
                resources=cluster_resources,
                annotation_key=effect.annotation_key,
                prodbox_id=effect.prodbox_id,
                label_key=effect.label_key,
                label_value=effect.label_value,
            )
            total_annotated += cluster_count
            errors.extend(cluster_errors)

        crd_count, crd_errors = await self._annotate_prodbox_crds(
            annotation_key=effect.annotation_key,
            prodbox_id=effect.prodbox_id,
            label_key=effect.label_key,
            label_value=effect.label_value,
        )
        total_annotated += crd_count
        errors.extend(crd_errors)

        if errors:
            self.failed_effects += 1
            first_errors = "; ".join(errors[:3])
            return self._create_error_summary(
                f"Failed to reconcile prodbox annotations: {first_errors}"
            )

        self.successful_effects += 1
        return self._create_success_summary(
            f"Reconciled prodbox annotations across {total_annotated} Kubernetes objects"
        )

    @staticmethod
    def _annotated_ref_key(ref: K8sObjectRef) -> tuple[str, str, str]:
        """Build deterministic key for deduplicating Kubernetes refs."""
        return (ref.resource, ref.namespace or "", ref.name)

    @staticmethod
    def _extract_annotated_refs_from_tsv(
        *,
        resource: str,
        stdout: bytes,
        prodbox_id: str,
        namespaced: bool,
    ) -> tuple[K8sObjectRef, ...]:
        """Parse tab-separated kubectl output and extract refs with matching prodbox annotation."""
        text = stdout.decode("utf-8", errors="replace")
        refs: list[K8sObjectRef] = []
        for raw_line in text.splitlines():
            line = raw_line.strip()
            if line == "":
                continue
            if namespaced:
                parts = raw_line.split("\t")
                match parts:
                    case [namespace, name, annotation, *rest]:
                        if rest:
                            continue
                        if namespace == "" or name == "":
                            continue
                        if annotation != prodbox_id:
                            continue
                        refs.append(K8sObjectRef(resource=resource, name=name, namespace=namespace))
                    case _:
                        continue
            else:
                parts = raw_line.split("\t")
                match parts:
                    case [name, annotation, *rest]:
                        if rest:
                            continue
                        if name == "":
                            continue
                        if annotation != prodbox_id:
                            continue
                        refs.append(K8sObjectRef(resource=resource, name=name))
                    case _:
                        continue
        return tuple(refs)

    @staticmethod
    def _annotated_ref_template(*, annotation_key: str, namespaced: bool) -> str:
        """Build kubectl go-template for stable tab-separated ref output."""
        match namespaced:
            case True:
                return (
                    "{{range .items}}"
                    '{{.metadata.namespace}}{{"\\t"}}{{.metadata.name}}{{"\\t"}}'
                    "{{if .metadata.annotations}}"
                    f'{{{{index .metadata.annotations "{annotation_key}"}}}}'
                    "{{end}}"
                    '{{"\\n"}}'
                    "{{end}}"
                )
            case False:
                return (
                    "{{range .items}}"
                    '{{.metadata.name}}{{"\\t"}}'
                    "{{if .metadata.annotations}}"
                    f'{{{{index .metadata.annotations "{annotation_key}"}}}}'
                    "{{end}}"
                    '{{"\\n"}}'
                    "{{end}}"
                )

    async def _collect_annotated_refs(
        self,
        *,
        namespaced_resources: tuple[str, ...],
        cluster_resources: tuple[str, ...],
        annotation_key: str,
        prodbox_id: str,
        retained_resource_kinds: tuple[str, ...],
        retained_namespaces: tuple[str, ...],
    ) -> tuple[tuple[K8sObjectRef, ...], tuple[str, ...]]:
        """Collect all annotated resource refs across namespaced+cluster scopes."""
        refs: list[K8sObjectRef] = []
        errors: list[str] = []
        retained_kinds = frozenset(retained_resource_kinds)
        retained_namespace_set = frozenset(retained_namespaces)

        for resource in namespaced_resources:
            if resource in retained_kinds:
                continue
            template = self._annotated_ref_template(
                annotation_key=annotation_key,
                namespaced=True,
            )
            output = await self._run_kubectl(
                "get",
                resource,
                "-A",
                "-o",
                "go-template",
                "--template",
                template,
                "--ignore-not-found=true",
                timeout=25.0,
            )
            if output.returncode != 0:
                stderr = output.stderr.decode("utf-8", errors="replace")
                if not self._is_ignorable_listing_error(stderr):
                    errors.append(f"list namespaced {resource} failed: {stderr}")
                continue
            refs.extend(
                self._extract_annotated_refs_from_tsv(
                    resource=resource,
                    stdout=output.stdout,
                    prodbox_id=prodbox_id,
                    namespaced=True,
                )
            )

        for resource in cluster_resources:
            if resource in retained_kinds:
                continue
            template = self._annotated_ref_template(
                annotation_key=annotation_key,
                namespaced=False,
            )
            output = await self._run_kubectl(
                "get",
                resource,
                "-o",
                "go-template",
                "--template",
                template,
                "--ignore-not-found=true",
                timeout=25.0,
            )
            if output.returncode != 0:
                stderr = output.stderr.decode("utf-8", errors="replace")
                if not self._is_ignorable_listing_error(stderr):
                    errors.append(f"list cluster {resource} failed: {stderr}")
                continue
            refs.extend(
                self._extract_annotated_refs_from_tsv(
                    resource=resource,
                    stdout=output.stdout,
                    prodbox_id=prodbox_id,
                    namespaced=False,
                )
            )

        deduped: dict[tuple[str, str, str], K8sObjectRef] = {}
        for ref in refs:
            if ref.resource in ("namespace", "namespaces") and ref.name in retained_namespace_set:
                continue
            deduped[self._annotated_ref_key(ref)] = ref
        ordered_refs = tuple(sorted(deduped.values(), key=self._sort_refs))
        return ordered_refs, tuple(errors)

    async def _delete_ref(self, ref: K8sObjectRef) -> str | None:
        """Delete one Kubernetes object ref, returning error text when delete fails."""
        args: list[str] = [
            "delete",
            f"{ref.resource}/{ref.name}",
            "--ignore-not-found=true",
            "--wait=true",
        ]
        if ref.namespace is not None:
            args.extend(["-n", ref.namespace])
        output = await self._run_kubectl(*args, timeout=45.0)
        if output.returncode != 0:
            stderr = output.stderr.decode("utf-8", errors="replace")
            if not self._is_not_found_message(stderr):
                return f"delete {ref.resource}/{ref.name} failed: {stderr}"
        return None

    async def _interpret_cleanup_prodbox_annotated_resources(
        self, effect: CleanupProdboxAnnotatedResources
    ) -> tuple[ExecutionSummary, int | None]:
        """Delete all Kubernetes resources annotated with prodbox-id."""
        namespaced_resources = await self._list_api_resources(namespaced=True)
        cluster_resources = await self._list_api_resources(namespaced=False)
        if namespaced_resources is None or cluster_resources is None:
            self.failed_effects += 1
            return self._create_error_summary("Failed to list Kubernetes API resources"), None
        namespaced_resources = self._filter_doctrine_managed_resources(namespaced_resources)
        cluster_resources = self._filter_doctrine_managed_resources(cluster_resources)

        deleted_count = 0
        errors: list[str] = []

        for _ in range(effect.cleanup_passes):
            refs, listing_errors = await self._collect_annotated_refs(
                namespaced_resources=namespaced_resources,
                cluster_resources=cluster_resources,
                annotation_key=effect.annotation_key,
                prodbox_id=effect.prodbox_id,
                retained_resource_kinds=effect.retained_resource_kinds,
                retained_namespaces=effect.retained_namespaces,
            )
            errors.extend(listing_errors)
            if not refs:
                break
            for ref in refs:
                delete_error = await self._delete_ref(ref)
                if delete_error is None:
                    deleted_count += 1
                else:
                    errors.append(delete_error)

        if errors:
            self.failed_effects += 1
            preview = "; ".join(errors[:3])
            return (
                self._create_error_summary(
                    f"Failed to cleanup all prodbox annotated objects: {preview}"
                ),
                None,
            )

        self.successful_effects += 1
        preserved_parts: list[str] = []
        if effect.retained_resource_kinds:
            preserved_parts.append("retained kinds: " + ", ".join(effect.retained_resource_kinds))
        if effect.retained_namespaces:
            preserved_parts.append("retained namespaces: " + ", ".join(effect.retained_namespaces))
        preserved_suffix = f"; {'; '.join(preserved_parts)}" if preserved_parts else ""
        return (
            self._create_success_summary(
                f"Cleanup removed {deleted_count} prodbox annotated Kubernetes objects"
                f"{preserved_suffix}"
            ),
            deleted_count,
        )

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
