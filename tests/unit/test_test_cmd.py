"""Unit tests for explicit prodbox test suite orchestration."""

from __future__ import annotations

import sys
from typing import cast
from unittest.mock import AsyncMock, patch

import click
import pytest

from prodbox.cli.effect_dag import PrerequisiteFailurePolicy
from prodbox.cli.effects import RunSubprocess, Sequence
from prodbox.cli.interpreter import EffectInterpreter
from prodbox.cli.test_cmd import (
    ALL_TEST_SUITE,
    INTEGRATION_RUNBOOK_EFFECT_ID,
    INTEGRATION_TEST_PREREQUISITES,
    PHASE_ONE_HEADER_EFFECT_ID,
    TEST_TIMEOUT_SECONDS,
    UNIT_TEST_SUITE,
    CoverageSettings,
    _build_test_dag,
    _coverage_settings,
    _pytest_args,
    _run_suite,
)


def test_coverage_settings_rejects_threshold_without_coverage() -> None:
    """Coverage thresholds require the explicit coverage flag."""
    with pytest.raises(click.UsageError, match="--cov-fail-under requires --coverage"):
        _coverage_settings(coverage=False, cov_fail_under=100)


def test_coverage_settings_rejects_threshold_outside_percentage_range() -> None:
    """Coverage thresholds must stay inside the explicit percentage range."""
    with pytest.raises(click.UsageError, match="between 0 and 100"):
        _coverage_settings(coverage=True, cov_fail_under=101)


def test_pytest_args_include_explicit_coverage_flags_before_suite_paths() -> None:
    """Coverage options should be translated into explicit pytest argv."""
    args = _pytest_args(
        suite=UNIT_TEST_SUITE,
        coverage_settings=CoverageSettings(enabled=True, fail_under=100),
    )
    assert args == ("--cov=src/prodbox", "--cov-fail-under=100", "tests/unit")


def test_build_test_dag_adds_integration_gate_prerequisites() -> None:
    """Full-suite DAG should gate pytest execution with integration prerequisites."""
    dag = _build_test_dag(
        suite=ALL_TEST_SUITE,
        coverage_settings=CoverageSettings(enabled=False, fail_under=None),
    )

    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    assert phase_two.prerequisites == INTEGRATION_TEST_PREREQUISITES
    phase_two_effect = cast(Sequence, phase_two.effect)
    phase_two_effect_ids = [effect.effect_id for effect in phase_two_effect.effects]
    assert phase_two_effect_ids == [
        "pytest_integration_runbook_header",
        INTEGRATION_RUNBOOK_EFFECT_ID,
        "pytest_phase_two_header",
        "pytest_run",
    ]
    runbook_effect = next(
        effect
        for effect in phase_two_effect.effects
        if effect.effect_id == INTEGRATION_RUNBOOK_EFFECT_ID
    )
    runbook_subprocess = cast(RunSubprocess, runbook_effect)
    assert runbook_subprocess.command == [
        sys.executable,
        "-m",
        "prodbox.cli.main",
        "rke2",
        "ensure",
    ]
    pytest_subprocess = cast(RunSubprocess, phase_two_effect.effects[-1])
    assert pytest_subprocess.command == [
        sys.executable,
        "-m",
        "pytest",
        "tests/unit",
        "tests/integration",
    ]
    assert "tool_helm" in phase_two.prerequisites
    assert "tool_docker" in phase_two.prerequisites
    assert "tool_ctr" in phase_two.prerequisites
    assert "tool_sudo" in phase_two.prerequisites
    assert phase_two.prerequisite_failure_policy == PrerequisiteFailurePolicy.PROPAGATE
    phase_one_header = dag.get_node(PHASE_ONE_HEADER_EFFECT_ID)
    assert phase_one_header is not None
    for prereq_id in INTEGRATION_TEST_PREREQUISITES:
        prereq_node = dag.get_node(prereq_id)
        assert prereq_node is not None
        assert PHASE_ONE_HEADER_EFFECT_ID in prereq_node.prerequisites


def test_build_test_dag_skips_integration_gate_for_unit_suite() -> None:
    """Unit suite should omit integration prerequisites and runbook gate."""
    dag = _build_test_dag(
        suite=UNIT_TEST_SUITE,
        coverage_settings=CoverageSettings(enabled=False, fail_under=None),
    )
    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    assert phase_two.prerequisites == frozenset({PHASE_ONE_HEADER_EFFECT_ID})
    phase_two_effect = cast(Sequence, phase_two.effect)
    phase_two_effect_ids = [effect.effect_id for effect in phase_two_effect.effects]
    assert phase_two_effect_ids == ["pytest_phase_two_header", "pytest_run"]


def test_build_test_dag_sets_phase_two_timeout_to_240_minutes() -> None:
    """Pytest execution timeout is 240 minutes as required by doctrine."""
    dag = _build_test_dag(
        suite=UNIT_TEST_SUITE,
        coverage_settings=CoverageSettings(enabled=False, fail_under=None),
    )
    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    phase_two_effect = cast(Sequence, phase_two.effect)
    run_pytest = cast(RunSubprocess, phase_two_effect.effects[1])
    assert run_pytest.timeout == TEST_TIMEOUT_SECONDS
    assert run_pytest.timeout == 14400.0


def test_run_suite_executes_built_dag_via_execute_dag() -> None:
    """_run_suite should dispatch DAG execution through the centralized boundary."""
    with patch("prodbox.cli.test_cmd.execute_dag", return_value=0) as mock_execute_dag:
        exit_code = _run_suite(
            suite=UNIT_TEST_SUITE,
            coverage_settings=CoverageSettings(enabled=False, fail_under=None),
        )
    assert exit_code == 0
    mock_execute_dag.assert_called_once()
    dag = mock_execute_dag.call_args.args[0]
    assert dag.get_node("pytest_phase_two") is not None


async def test_phase_two_pytest_does_not_run_when_phase_one_gate_fails() -> None:
    """Phase 2 pytest subprocess must not execute when prerequisite gate fails."""
    dag = _build_test_dag(
        suite=ALL_TEST_SUITE,
        coverage_settings=CoverageSettings(enabled=False, fail_under=None),
    )
    interpreter = EffectInterpreter()

    async def fail_file_checks(*_args: object, **_kwargs: object) -> tuple[object, bool]:
        return interpreter._create_error_summary("File not found: forced"), False

    with (
        patch.object(
            interpreter,
            "_interpret_check_file_exists",
            side_effect=fail_file_checks,
        ),
        patch.object(
            interpreter,
            "_interpret_run_subprocess",
            new_callable=AsyncMock,
        ) as mock_run_subprocess,
    ):
        summary = await interpreter.interpret_dag(dag)

    assert summary.exit_code == 1
    mock_run_subprocess.assert_not_awaited()
