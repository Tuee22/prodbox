"""
Pure summary formatting and output effects for command execution.

This module converts execution summaries to deterministic text/JSON formats
and provides output effects used by the command executor.
"""

from __future__ import annotations

import json

from prodbox.cli.effects import WriteStderr, WriteStdout
from prodbox.cli.interpreter import DAGExecutionSummary, EnvironmentError, ExecutionSummary


def _format_duration(seconds: float) -> str:
    """Format duration in human-readable form."""
    match True:
        case _ if seconds < 60:
            return f"{seconds:.2f}s"
        case _ if seconds < 3600:
            minutes = int(seconds // 60)
            secs = int(seconds % 60)
            return f"{minutes}m {secs}s"
        case _:
            hours = int(seconds // 3600)
            minutes = int((seconds % 3600) // 60)
            secs = int(seconds % 60)
            return f"{hours}h {minutes}m {secs}s"


def _is_skipped_message(message: str) -> bool:
    """Check whether a message represents a prerequisite skip."""
    return message.startswith("Skipped due to")


def dag_to_execution_summary(dag_summary: DAGExecutionSummary) -> ExecutionSummary:
    """
    Convert DAGExecutionSummary to a command-level ExecutionSummary.

    This rolls up artifacts/errors from node summaries and computes skipped
    node count based on deterministic skip messages.
    """
    skipped_nodes = sum(
        1
        for _, node_summary in dag_summary.node_results
        if _is_skipped_message(node_summary.message)
    )
    artifacts = tuple(
        artifact
        for _, node_summary in dag_summary.node_results
        for artifact in node_summary.artifacts
    )
    environment_errors = tuple(
        error
        for _, node_summary in dag_summary.node_results
        for error in node_summary.environment_errors
    )
    return ExecutionSummary(
        exit_code=dag_summary.exit_code,
        message=dag_summary.message,
        total_effects=dag_summary.total_nodes,
        successful_effects=dag_summary.successful_nodes,
        failed_effects=dag_summary.failed_nodes,
        skipped_effects=skipped_nodes,
        elapsed_seconds=dag_summary.elapsed_seconds,
        artifacts=artifacts,
        environment_errors=environment_errors,
    )


def format_summary(summary: ExecutionSummary) -> str:
    """Format execution summary for human-readable stdout output."""
    header = "✅ Command completed successfully" if summary.exit_code == 0 else "❌ Command failed"
    lines: list[str] = [
        header,
        f"Message: {summary.message}",
        "",
        "Metrics:",
        f"  Total effects: {summary.total_effects}",
        f"  Successful:    {summary.successful_effects}",
        f"  Failed:        {summary.failed_effects}",
        f"  Skipped:       {summary.skipped_effects}",
        f"  Elapsed:       {_format_duration(summary.elapsed_seconds)}",
    ]

    if summary.artifacts:
        artifact_lines = [f"  - {artifact}" for artifact in summary.artifacts]
        lines.extend(["", "Artifacts:", *artifact_lines])

    if summary.environment_errors:
        lines.extend(["", "Environment Errors:"])
        for error in summary.environment_errors:
            lines.extend(
                [
                    f"  - Tool: {error.tool}",
                    f"    Effect: {error.source_effect_id}",
                    f"    Message: {error.message}",
                    f"    Fix: {error.fix_hint}",
                ]
            )

    return "\n".join(lines) + "\n"


def format_summary_json(summary: ExecutionSummary) -> str:
    """Format execution summary as deterministic JSON."""
    data = {
        "exit_code": summary.exit_code,
        "message": summary.message,
        "total_effects": summary.total_effects,
        "successful_effects": summary.successful_effects,
        "failed_effects": summary.failed_effects,
        "skipped_effects": summary.skipped_effects,
        "elapsed_seconds": round(summary.elapsed_seconds, 3),
        "artifacts": [str(path) for path in summary.artifacts],
        "environment_errors": [_error_to_json(error) for error in summary.environment_errors],
    }
    return json.dumps(data, indent=2)


def _error_to_json(error: EnvironmentError) -> dict[str, str]:
    """Convert EnvironmentError to JSON-safe mapping."""
    return {
        "tool": error.tool,
        "message": error.message,
        "fix_hint": error.fix_hint,
        "source_effect_id": error.source_effect_id,
    }


def format_dag_failure_report(dag_summary: DAGExecutionSummary) -> str:
    """Format failed/skipped DAG nodes for stderr when command execution fails."""
    root_failures: list[tuple[str, str]] = []
    skipped: list[tuple[str, str]] = []

    for effect_id, node_summary in dag_summary.node_results:
        if node_summary.success:
            continue
        if _is_skipped_message(node_summary.message):
            skipped.append((effect_id, node_summary.message))
            continue
        root_failures.append((effect_id, node_summary.message))

    lines: list[str] = ["Failure Details:"]
    if root_failures:
        lines.append("  Root-cause failures:")
        lines.extend([f"    - {effect_id}: {message}" for effect_id, message in root_failures])
    if skipped:
        lines.append("  Skipped due to failed prerequisites:")
        lines.extend([f"    - {effect_id}: {message}" for effect_id, message in skipped])

    if not root_failures and not skipped:
        lines.append("  No failed nodes were recorded.")

    return "\n".join(lines) + "\n"


def display_summary(summary: ExecutionSummary) -> WriteStdout:
    """Create stdout effect for formatted execution summary."""
    return WriteStdout(
        effect_id="display_summary",
        description="Display execution summary",
        text=format_summary(summary),
    )


def display_dag_summary(dag_summary: DAGExecutionSummary) -> WriteStdout:
    """Create stdout effect for formatted DAG summary."""
    return display_summary(dag_to_execution_summary(dag_summary))


def display_dag_failure_report(dag_summary: DAGExecutionSummary) -> WriteStderr | None:
    """Create stderr effect with DAG failure details when exit code is non-zero."""
    if dag_summary.exit_code == 0:
        return None
    return WriteStderr(
        effect_id="display_dag_failure_report",
        description="Display DAG failure details",
        text=format_dag_failure_report(dag_summary),
    )


__all__ = [
    "dag_to_execution_summary",
    "format_summary",
    "format_summary_json",
    "format_dag_failure_report",
    "display_summary",
    "display_dag_summary",
    "display_dag_failure_report",
]
