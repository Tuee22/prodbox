"""Unit tests for prodbox test command DAG orchestration."""

from __future__ import annotations

from unittest.mock import patch

from prodbox.cli.test_cmd import (
    INTEGRATION_TEST_PREREQUISITES,
    _build_test_dag,
    _extract_marker_expressions,
    _requires_integration_prerequisites,
    _run_tests,
)


def test_extract_marker_expressions_supports_short_and_long_forms() -> None:
    """Marker parsing should support `-m` and `--markexpr=` forms."""
    expressions = _extract_marker_expressions(
        (
            "-m",
            "not integration",
            "--markexpr=slow and not integration",
        )
    )
    assert expressions == ("not integration", "slow and not integration")


def test_requires_integration_prerequisites_by_default() -> None:
    """No marker/path selection means integration tests may run."""
    assert _requires_integration_prerequisites(()) is True


def test_requires_integration_prerequisites_false_for_not_integration_marker() -> None:
    """`-m not integration` should disable integration prerequisite gate."""
    assert _requires_integration_prerequisites(("-m", "not integration")) is False


def test_requires_integration_prerequisites_false_for_unit_paths() -> None:
    """Explicit unit test path selection should bypass integration prerequisites."""
    assert _requires_integration_prerequisites(("tests/unit/test_env.py",)) is False


def test_build_test_dag_adds_integration_gate_prerequisites() -> None:
    """Default DAG should gate pytest execution with integration prerequisites."""
    dag = _build_test_dag(())
    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    assert phase_two.prerequisites == INTEGRATION_TEST_PREREQUISITES


def test_build_test_dag_skips_integration_gate_for_unit_scope() -> None:
    """Unit-only marker scope should omit integration prerequisite gate."""
    dag = _build_test_dag(("-m", "not integration"))
    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    assert phase_two.prerequisites == frozenset()


def test_run_tests_executes_built_dag_via_execute_dag() -> None:
    """_run_tests should dispatch DAG execution through centralized boundary."""
    with patch("prodbox.cli.test_cmd.execute_dag", return_value=0) as mock_execute_dag:
        exit_code = _run_tests(("-m", "not integration"))
    assert exit_code == 0
    mock_execute_dag.assert_called_once()
    dag = mock_execute_dag.call_args.args[0]
    assert dag.get_node("pytest_phase_two") is not None
