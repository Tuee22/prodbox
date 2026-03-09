"""Unit tests for summary formatting and output effects."""

from __future__ import annotations

from pathlib import Path

from prodbox.cli.interpreter import DAGExecutionSummary, EnvironmentError, ExecutionSummary
from prodbox.cli.summary import (
    dag_to_execution_summary,
    display_dag_failure_report,
    display_dag_summary,
    format_dag_failure_report,
    format_summary,
    format_summary_json,
)


def _env_error() -> EnvironmentError:
    return EnvironmentError(
        tool="kubectl",
        message="Tool not found",
        fix_hint="Install kubectl",
        source_effect_id="tool_kubectl",
    )


def test_format_summary_contains_header_and_metrics() -> None:
    """Human summary should include status, message, and metrics."""
    summary = ExecutionSummary(
        exit_code=0,
        message="All good",
        total_effects=3,
        successful_effects=3,
        failed_effects=0,
        skipped_effects=0,
        elapsed_seconds=1.5,
        artifacts=(Path("/tmp/artifact.txt"),),
        environment_errors=(_env_error(),),
    )

    text = format_summary(summary)

    assert "Command completed successfully" in text
    assert "Message: All good" in text
    assert "Total effects: 3" in text
    assert "/tmp/artifact.txt" in text
    assert "Tool: kubectl" in text
    assert "Manual env changes needed" in text
    assert "tool_kubectl: Install kubectl" in text
    assert "Fix:" not in text


def test_format_summary_json_contains_expected_fields() -> None:
    """JSON summary should expose deterministic machine-readable fields."""
    summary = ExecutionSummary(exit_code=1, message="Failed", total_effects=2, failed_effects=2)
    text = format_summary_json(summary)
    assert '"exit_code": 1' in text
    assert '"message": "Failed"' in text
    assert '"total_effects": 2' in text


def test_format_summary_deduplicates_manual_fix_hints() -> None:
    """Repeated fix hints should appear once in manual env section."""
    repeated_errors = (
        EnvironmentError(
            tool="kubectl",
            message="kubectl missing",
            fix_hint="Install kubectl",
            source_effect_id="tool_kubectl",
        ),
        EnvironmentError(
            tool="k8s",
            message="cluster check blocked",
            fix_hint="Install kubectl",
            source_effect_id="k8s_cluster_reachable",
        ),
    )
    summary = ExecutionSummary(
        exit_code=1,
        message="Failed",
        total_effects=2,
        failed_effects=2,
        environment_errors=repeated_errors,
    )

    text = format_summary(summary)
    assert text.count("Install kubectl") == 1
    assert "Manual env changes needed:" in text


def test_dag_to_execution_summary_rolls_up_node_results() -> None:
    """DAG summary conversion should aggregate node-level data."""
    success_node = ExecutionSummary(
        exit_code=0,
        message="ok",
        artifacts=(Path("/tmp/ok.txt"),),
    )
    skipped_node = ExecutionSummary(
        exit_code=1,
        message="Skipped due to failed prerequisite: check_a",
    )
    failed_node = ExecutionSummary(
        exit_code=1,
        message="Root cause failure",
        environment_errors=(_env_error(),),
    )
    dag_summary = DAGExecutionSummary(
        exit_code=1,
        message="DAG execution complete",
        node_results=(
            ("node_ok", success_node),
            ("node_skip", skipped_node),
            ("node_fail", failed_node),
        ),
        total_nodes=3,
        successful_nodes=1,
        failed_nodes=2,
        skipped_nodes=1,
        elapsed_seconds=2.0,
    )

    summary = dag_to_execution_summary(dag_summary)

    assert summary.total_effects == 3
    assert summary.successful_effects == 1
    assert summary.failed_effects == 2
    assert summary.skipped_effects == 1
    assert len(summary.artifacts) == 1
    assert len(summary.environment_errors) == 1


def test_dag_to_execution_summary_parses_environment_errors_from_failures() -> None:
    """Conversion should infer root-cause environment errors from failure messages."""
    root_tool_failure = ExecutionSummary(
        exit_code=1,
        message="Tool not found: kubectl",
    )
    propagated = ExecutionSummary(
        exit_code=1,
        message="Prerequisite failure propagated: failed prerequisites: tool_kubectl",
    )
    dag_summary = DAGExecutionSummary(
        exit_code=1,
        message="DAG execution complete",
        node_results=(
            ("tool_kubectl", root_tool_failure),
            ("k8s_cluster_reachable", propagated),
        ),
        total_nodes=2,
        successful_nodes=0,
        failed_nodes=2,
        skipped_nodes=0,
    )

    summary = dag_to_execution_summary(dag_summary)

    assert len(summary.environment_errors) == 1
    env_error = summary.environment_errors[0]
    assert env_error.source_effect_id == "tool_kubectl"
    assert env_error.tool == "kubectl"
    assert env_error.fix_hint == "Install kubectl"


def test_format_dag_failure_report_includes_root_and_skipped() -> None:
    """Failure report should separate root-cause from propagated prerequisite failures."""
    root_failure = ExecutionSummary(exit_code=1, message="kubectl failed")
    propagated = ExecutionSummary(
        exit_code=1,
        message=("Prerequisite failure propagated: " "failed prerequisites: tool_kubectl"),
    )
    dag_summary = DAGExecutionSummary(
        exit_code=1,
        message="DAG execution complete",
        node_results=(("run_kubectl", root_failure), ("wait_nodes", propagated)),
        total_nodes=2,
        successful_nodes=0,
        failed_nodes=2,
    )

    report = format_dag_failure_report(dag_summary)

    assert "Root-cause failures" in report
    assert "run_kubectl: kubectl failed" in report
    assert "Propagated prerequisite failures" in report
    assert (
        "wait_nodes: Prerequisite failure propagated: failed prerequisites: tool_kubectl" in report
    )


def test_display_dag_summary_and_failure_report_effects() -> None:
    """Display helpers should return expected output effects."""
    dag_summary = DAGExecutionSummary(
        exit_code=1,
        message="DAG execution complete",
        node_results=(),
        total_nodes=0,
        successful_nodes=0,
        failed_nodes=0,
    )

    summary_effect = display_dag_summary(dag_summary)
    failure_effect = display_dag_failure_report(dag_summary)

    assert summary_effect.effect_id == "display_summary"
    assert failure_effect is not None
    assert failure_effect.effect_id == "display_dag_failure_report"


def test_display_dag_failure_report_none_when_success() -> None:
    """No failure report should be emitted for successful DAG execution."""
    dag_summary = DAGExecutionSummary(
        exit_code=0,
        message="DAG execution complete",
        node_results=(),
        total_nodes=0,
        successful_nodes=0,
        failed_nodes=0,
    )
    assert display_dag_failure_report(dag_summary) is None
