"""Unit tests for explicit prodbox test suite orchestration."""

from __future__ import annotations

import sys
from typing import cast
from unittest.mock import AsyncMock, patch

import click
import pytest

from prodbox.cli.effect_dag import PrerequisiteFailurePolicy
from prodbox.cli.effects import Custom, RunSubprocess, Sequence
from prodbox.cli.interpreter import EffectInterpreter
from prodbox.cli.test_cmd import (
    AGGREGATE_COVERAGE_ERASE_EFFECT_ID,
    ALL_INTEGRATION_TEST_PREREQUISITES,
    ALL_TEST_SUITE,
    CLUSTER_INTEGRATION_TEST_PREREQUISITES,
    INTEGRATION_ALL_TEST_SUITE,
    INTEGRATION_AWS_EKS_TEST_SUITE,
    INTEGRATION_AWS_FOUNDATION_TEST_SUITE,
    INTEGRATION_CHARTS_VSCODE_TEST_SUITE,
    INTEGRATION_DNS_AWS_TEST_SUITE,
    INTEGRATION_ENV_TEST_SUITE,
    INTEGRATION_PUBLIC_DNS_TEST_SUITE,
    INTEGRATION_PULUMI_TEST_SUITE,
    INTEGRATION_RUNBOOK_EFFECT_ID,
    PHASE_ONE_HEADER_EFFECT_ID,
    POST_PYTEST_GATEWAY_DEPLOY_EFFECT_ID,
    POST_PYTEST_PUBLIC_EDGE_EFFECT_ID,
    POST_PYTEST_PULUMI_REFRESH_EFFECT_ID,
    POST_PYTEST_PULUMI_UP_EFFECT_ID,
    POST_PYTEST_RESTORE_HEADER_EFFECT_ID,
    POST_PYTEST_VSCODE_DEPLOY_EFFECT_ID,
    PUBLIC_HOST_READINESS_EFFECT_ID,
    TEST_TIMEOUT_SECONDS,
    UNIT_TEST_SUITE,
    CoverageSettings,
    _build_test_dag,
    _coverage_settings,
    _extract_public_edge_classification,
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
    assert phase_two.prerequisites == ALL_INTEGRATION_TEST_PREREQUISITES
    phase_two_effect = cast(Sequence, phase_two.effect)
    phase_two_effect_ids = [effect.effect_id for effect in phase_two_effect.effects]
    assert phase_two_effect_ids[:4] == [
        "pytest_integration_runbook_header",
        INTEGRATION_RUNBOOK_EFFECT_ID,
        PUBLIC_HOST_READINESS_EFFECT_ID,
        "pytest_phase_two_header",
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
    public_host_readiness = cast(
        Custom[object],
        next(
            effect
            for effect in phase_two_effect.effects
            if effect.effect_id == PUBLIC_HOST_READINESS_EFFECT_ID
        ),
    )
    assert callable(public_host_readiness.fn)
    pytest_subprocesses = [
        cast(RunSubprocess, effect)
        for effect in phase_two_effect.effects
        if effect.effect_id.startswith("pytest_run")
    ]
    assert len(pytest_subprocesses) == len(ALL_TEST_SUITE.aggregate_pytest_invocations)
    assert pytest_subprocesses[0].command == [
        sys.executable,
        "-m",
        "pytest",
        "tests/unit",
    ]
    assert pytest_subprocesses[1].command == [
        sys.executable,
        "-m",
        "pytest",
        "tests/integration/test_charts_vscode.py",
    ]
    assert pytest_subprocesses[-1].command == [
        sys.executable,
        "-m",
        "pytest",
        "tests/integration/test_prodbox_lifecycle.py",
    ]
    assert phase_two_effect_ids[-6:] == [
        POST_PYTEST_RESTORE_HEADER_EFFECT_ID,
        POST_PYTEST_PULUMI_REFRESH_EFFECT_ID,
        POST_PYTEST_PULUMI_UP_EFFECT_ID,
        POST_PYTEST_GATEWAY_DEPLOY_EFFECT_ID,
        POST_PYTEST_VSCODE_DEPLOY_EFFECT_ID,
        POST_PYTEST_PUBLIC_EDGE_EFFECT_ID,
    ]
    pulumi_refresh = cast(
        RunSubprocess,
        next(
            effect
            for effect in phase_two_effect.effects
            if effect.effect_id == POST_PYTEST_PULUMI_REFRESH_EFFECT_ID
        ),
    )
    assert pulumi_refresh.command == [
        sys.executable,
        "-m",
        "prodbox.cli.main",
        "pulumi",
        "refresh",
    ]
    pulumi_restore = cast(
        RunSubprocess,
        next(
            effect
            for effect in phase_two_effect.effects
            if effect.effect_id == POST_PYTEST_PULUMI_UP_EFFECT_ID
        ),
    )
    assert pulumi_restore.command == [
        sys.executable,
        "-m",
        "prodbox.cli.main",
        "pulumi",
        "up",
        "--yes",
    ]
    gateway_restore = cast(
        RunSubprocess,
        next(
            effect
            for effect in phase_two_effect.effects
            if effect.effect_id == POST_PYTEST_GATEWAY_DEPLOY_EFFECT_ID
        ),
    )
    assert gateway_restore.command == [
        sys.executable,
        "-m",
        "prodbox.cli.main",
        "charts",
        "deploy",
        "gateway",
    ]
    vscode_restore = cast(
        RunSubprocess,
        next(
            effect
            for effect in phase_two_effect.effects
            if effect.effect_id == POST_PYTEST_VSCODE_DEPLOY_EFFECT_ID
        ),
    )
    assert vscode_restore.command == [
        sys.executable,
        "-m",
        "prodbox.cli.main",
        "charts",
        "deploy",
        "vscode",
    ]
    postflight_public_edge = cast(
        Custom[object],
        next(
            effect
            for effect in phase_two_effect.effects
            if effect.effect_id == POST_PYTEST_PUBLIC_EDGE_EFFECT_ID
        ),
    )
    assert callable(postflight_public_edge.fn)
    assert "tool_helm" in phase_two.prerequisites
    assert "tool_docker" in phase_two.prerequisites
    assert "tool_ctr" in phase_two.prerequisites
    assert "tool_sudo" in phase_two.prerequisites
    assert phase_two.prerequisite_failure_policy == PrerequisiteFailurePolicy.PROPAGATE
    phase_one_header = dag.get_node(PHASE_ONE_HEADER_EFFECT_ID)
    assert phase_one_header is not None
    for prereq_id in ALL_INTEGRATION_TEST_PREREQUISITES:
        prereq_node = dag.get_node(prereq_id)
        assert prereq_node is not None
        assert PHASE_ONE_HEADER_EFFECT_ID in prereq_node.prerequisites


def test_build_test_dag_omits_phase_one_gate_for_mock_only_env_suite() -> None:
    """Mock-only integration suites should bypass cluster/AWS runbook gates."""
    dag = _build_test_dag(
        suite=INTEGRATION_ENV_TEST_SUITE,
        coverage_settings=CoverageSettings(enabled=False, fail_under=None),
    )
    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    assert phase_two.prerequisites == frozenset({PHASE_ONE_HEADER_EFFECT_ID})
    phase_two_effect = cast(Sequence, phase_two.effect)
    assert [effect.effect_id for effect in phase_two_effect.effects] == [
        "pytest_phase_two_header",
        "pytest_run",
    ]


def test_build_test_dag_uses_aws_specific_gate_without_runbook() -> None:
    """AWS DNS suite should gate on AWS prerequisites but not run rke2 ensure."""
    dag = _build_test_dag(
        suite=INTEGRATION_DNS_AWS_TEST_SUITE,
        coverage_settings=CoverageSettings(enabled=False, fail_under=None),
    )
    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    assert phase_two.prerequisites == frozenset({"tool_aws"})
    phase_two_effect = cast(Sequence, phase_two.effect)
    assert [effect.effect_id for effect in phase_two_effect.effects] == [
        "pytest_phase_two_header",
        "pytest_run",
    ]


@pytest.mark.parametrize(
    "suite",
    [
        INTEGRATION_CHARTS_VSCODE_TEST_SUITE,
        INTEGRATION_PUBLIC_DNS_TEST_SUITE,
    ],
)
def test_build_test_dag_keeps_public_host_suite_off_cluster_runbook(suite: object) -> None:
    """External public-host suites should not require cluster gates or rke2 ensure."""
    dag = _build_test_dag(
        suite=cast(object, suite),
        coverage_settings=CoverageSettings(enabled=False, fail_under=None),
    )
    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    assert phase_two.prerequisites == frozenset({PHASE_ONE_HEADER_EFFECT_ID})
    phase_two_effect = cast(Sequence, phase_two.effect)
    assert [effect.effect_id for effect in phase_two_effect.effects] == [
        "pytest_phase_two_header",
        "pytest_run",
    ]


@pytest.mark.parametrize(
    "suite",
    [
        INTEGRATION_AWS_FOUNDATION_TEST_SUITE,
        INTEGRATION_AWS_EKS_TEST_SUITE,
    ],
)
def test_build_test_dag_uses_aws_gate_for_new_real_aws_suites(suite: object) -> None:
    """New real AWS suites should use the AWS prerequisite gate without the cluster runbook."""
    dag = _build_test_dag(
        suite=cast(object, suite),
        coverage_settings=CoverageSettings(enabled=False, fail_under=None),
    )
    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    assert phase_two.prerequisites == frozenset({"tool_aws"})
    phase_two_effect = cast(Sequence, phase_two.effect)
    assert [effect.effect_id for effect in phase_two_effect.effects] == [
        "pytest_phase_two_header",
        "pytest_run",
    ]


def test_build_test_dag_uses_cluster_and_pulumi_gate_for_pulumi_suite() -> None:
    """Pulumi suite should require cluster + AWS + Pulumi prerequisites and runbook."""
    dag = _build_test_dag(
        suite=INTEGRATION_PULUMI_TEST_SUITE,
        coverage_settings=CoverageSettings(enabled=False, fail_under=None),
    )
    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    assert phase_two.prerequisites == CLUSTER_INTEGRATION_TEST_PREREQUISITES | frozenset(
        {"tool_pulumi"}
    )


@pytest.mark.parametrize("suite", [ALL_TEST_SUITE, INTEGRATION_ALL_TEST_SUITE])
def test_aggregate_suites_restore_supported_runtime_after_pytest(suite: object) -> None:
    """Aggregate suites should reconcile the supported public-edge runtime before exit."""
    dag = _build_test_dag(
        suite=cast(object, suite),
        coverage_settings=CoverageSettings(enabled=False, fail_under=None),
    )
    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    phase_two_effect = cast(Sequence, phase_two.effect)
    assert [effect.effect_id for effect in phase_two_effect.effects][-6:] == [
        POST_PYTEST_RESTORE_HEADER_EFFECT_ID,
        POST_PYTEST_PULUMI_REFRESH_EFFECT_ID,
        POST_PYTEST_PULUMI_UP_EFFECT_ID,
        POST_PYTEST_GATEWAY_DEPLOY_EFFECT_ID,
        POST_PYTEST_VSCODE_DEPLOY_EFFECT_ID,
        POST_PYTEST_PUBLIC_EDGE_EFFECT_ID,
    ]


def test_integration_all_uses_explicit_canonical_suite_order() -> None:
    """Integration-all should preserve the safe suite order needed for clean-room reruns."""
    assert INTEGRATION_ALL_TEST_SUITE.pytest_args[:2] == (
        "tests/integration/test_charts_vscode.py",
        "tests/integration/test_public_dns_delegation.py",
    )
    assert len(INTEGRATION_ALL_TEST_SUITE.aggregate_pytest_invocations) == len(
        INTEGRATION_ALL_TEST_SUITE.pytest_args
    )
    assert INTEGRATION_ALL_TEST_SUITE.pytest_args.index(
        "tests/integration/test_charts_platform.py"
    ) < INTEGRATION_ALL_TEST_SUITE.pytest_args.index("tests/integration/test_charts_storage.py")
    assert INTEGRATION_ALL_TEST_SUITE.pytest_args[-1] == (
        "tests/integration/test_prodbox_lifecycle.py"
    )


def test_aggregate_suite_coverage_runs_one_pytest_process_per_named_suite() -> None:
    """Aggregate coverage should isolate pytest runs while preserving one combined report."""
    dag = _build_test_dag(
        suite=ALL_TEST_SUITE,
        coverage_settings=CoverageSettings(enabled=True, fail_under=100),
    )
    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    phase_two_effect = cast(Sequence, phase_two.effect)
    phase_two_effect_ids = [effect.effect_id for effect in phase_two_effect.effects]
    assert AGGREGATE_COVERAGE_ERASE_EFFECT_ID in phase_two_effect_ids
    pytest_subprocesses = [
        cast(RunSubprocess, effect)
        for effect in phase_two_effect.effects
        if effect.effect_id.startswith("pytest_run")
    ]
    assert pytest_subprocesses[0].command == [
        sys.executable,
        "-m",
        "pytest",
        "--cov=src/prodbox",
        "--cov-append",
        "--cov-report=",
        "tests/unit",
    ]
    assert pytest_subprocesses[-1].command == [
        sys.executable,
        "-m",
        "pytest",
        "--cov=src/prodbox",
        "--cov-append",
        "--cov-fail-under=100",
        "tests/integration/test_prodbox_lifecycle.py",
    ]


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


def test_extract_public_edge_classification_returns_value() -> None:
    """Public-edge classification should be parsed from the rendered diagnostic report."""
    report = "\n".join(
        [
            "Public edge diagnostic",
            "FQDN=vscode.resolvefintech.com",
            "CLASSIFICATION=ready-for-external-proof",
        ]
    )

    assert _extract_public_edge_classification(report) == "ready-for-external-proof"


def test_extract_public_edge_classification_returns_none_when_missing() -> None:
    """Missing classification lines should not crash the parser."""
    assert _extract_public_edge_classification("Public edge diagnostic") is None
