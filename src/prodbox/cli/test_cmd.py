"""Explicit test suite commands for running pytest through the prodbox CLI."""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass, replace
from typing import Final

import click

from prodbox.cli.command_executor import execute_dag
from prodbox.cli.effect_dag import EffectDAG, EffectNode
from prodbox.cli.effects import Effect, RunSubprocess, Sequence, WriteStdout
from prodbox.cli.prerequisite_registry import PREREQUISITE_REGISTRY
from prodbox.lib.lint.poetry_entrypoint_guard import ALLOW_NON_ENTRYPOINT_ENV

TEST_TIMEOUT_SECONDS: float = 14400.0
INTEGRATION_RUNBOOK_TIMEOUT_SECONDS: float = 3600.0
INTEGRATION_RUNBOOK_EFFECT_ID: str = "pytest_integration_runbook_ensure"
PHASE_ONE_HEADER_EFFECT_ID: Final[str] = "pytest_phase_one_header"
PHASE_ONE_GATE_MESSAGE: Final[str] = "Phase 1/2: validating integration prerequisites"
PHASE_ONE_NO_PREREQ_MESSAGE: Final[str] = "Phase 1/2: no integration prerequisites required"
PHASE_ONE_POINT_FIVE_HEADER_TEXT: Final[
    str
] = "Phase 1.5/2: enforcing integration runbook (poetry run prodbox rke2 ensure)"
PHASE_TWO_HEADER_TEXT: Final[str] = "Phase 2/2: running pytest suites"
INTEGRATION_TEST_PREREQUISITES: frozenset[str] = frozenset(
    {
        "tool_docker",
        "tool_ctr",
        "tool_helm",
        "tool_kubectl",
        "tool_sudo",
        "kubeconfig_home_exists",
        "rke2_service_active",
    }
)


@dataclass(frozen=True)
class CoverageSettings:
    """Explicit coverage configuration for one test invocation."""

    enabled: bool
    fail_under: int | None


@dataclass(frozen=True)
class TestSuiteSelection:
    """Explicitly named pytest suite exposed by the Click surface."""

    suite_id: str
    pytest_args: tuple[str, ...]
    requires_integration_gate: bool


ALL_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="all",
    pytest_args=("tests/unit", "tests/integration"),
    requires_integration_gate=True,
)
UNIT_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="unit",
    pytest_args=("tests/unit",),
    requires_integration_gate=False,
)
INTEGRATION_ALL_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-all",
    pytest_args=("tests/integration",),
    requires_integration_gate=True,
)
INTEGRATION_CLI_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-cli",
    pytest_args=("tests/integration/test_cli_commands.py",),
    requires_integration_gate=True,
)
INTEGRATION_ENV_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-env",
    pytest_args=("tests/integration/test_cli_env.py",),
    requires_integration_gate=True,
)
INTEGRATION_GATEWAY_DAEMON_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-gateway-daemon",
    pytest_args=("tests/integration/test_gateway_daemon_k8s.py",),
    requires_integration_gate=True,
)
INTEGRATION_GATEWAY_PODS_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-gateway-pods",
    pytest_args=("tests/integration/test_gateway_k8s_pods.py",),
    requires_integration_gate=True,
)
INTEGRATION_LIFECYCLE_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-lifecycle",
    pytest_args=("tests/integration/test_prodbox_lifecycle.py",),
    requires_integration_gate=True,
)


@click.group("test", no_args_is_help=True)
def test() -> None:
    """Run explicitly named prodbox test suites.

    \b
    Supported suites:
      prodbox test all
      prodbox test unit
      prodbox test integration all
      prodbox test integration cli
      prodbox test integration env
      prodbox test integration gateway-daemon
      prodbox test integration gateway-pods
      prodbox test integration lifecycle
    """


@test.command("all")
@click.option(
    "--coverage",
    is_flag=True,
    help="Enable pytest-cov for src/prodbox.",
)
@click.option(
    "--cov-fail-under",
    type=int,
    help="Minimum coverage percentage in [0, 100]; requires --coverage.",
)
def run_all_suite(coverage: bool, cov_fail_under: int | None) -> None:
    """Run the full unit + integration suite."""
    _exit_for_suite(
        suite=ALL_TEST_SUITE,
        coverage=coverage,
        cov_fail_under=cov_fail_under,
    )


@test.command("unit")
@click.option(
    "--coverage",
    is_flag=True,
    help="Enable pytest-cov for src/prodbox.",
)
@click.option(
    "--cov-fail-under",
    type=int,
    help="Minimum coverage percentage in [0, 100]; requires --coverage.",
)
def run_unit_suite(coverage: bool, cov_fail_under: int | None) -> None:
    """Run the unit test suite only."""
    _exit_for_suite(
        suite=UNIT_TEST_SUITE,
        coverage=coverage,
        cov_fail_under=cov_fail_under,
    )


@test.group("integration", no_args_is_help=True)
def integration() -> None:
    """Run explicitly named integration suites."""


@integration.command("all")
@click.option(
    "--coverage",
    is_flag=True,
    help="Enable pytest-cov for src/prodbox.",
)
@click.option(
    "--cov-fail-under",
    type=int,
    help="Minimum coverage percentage in [0, 100]; requires --coverage.",
)
def integration_all(coverage: bool, cov_fail_under: int | None) -> None:
    """Run every integration test suite."""
    _exit_for_suite(
        suite=INTEGRATION_ALL_TEST_SUITE,
        coverage=coverage,
        cov_fail_under=cov_fail_under,
    )


@integration.command("cli")
@click.option(
    "--coverage",
    is_flag=True,
    help="Enable pytest-cov for src/prodbox.",
)
@click.option(
    "--cov-fail-under",
    type=int,
    help="Minimum coverage percentage in [0, 100]; requires --coverage.",
)
def integration_cli(coverage: bool, cov_fail_under: int | None) -> None:
    """Run integration tests for CLI command execution behavior."""
    _exit_for_suite(
        suite=INTEGRATION_CLI_TEST_SUITE,
        coverage=coverage,
        cov_fail_under=cov_fail_under,
    )


@integration.command("env")
@click.option(
    "--coverage",
    is_flag=True,
    help="Enable pytest-cov for src/prodbox.",
)
@click.option(
    "--cov-fail-under",
    type=int,
    help="Minimum coverage percentage in [0, 100]; requires --coverage.",
)
def integration_env(coverage: bool, cov_fail_under: int | None) -> None:
    """Run integration tests for env subcommands."""
    _exit_for_suite(
        suite=INTEGRATION_ENV_TEST_SUITE,
        coverage=coverage,
        cov_fail_under=cov_fail_under,
    )


@integration.command("gateway-daemon")
@click.option(
    "--coverage",
    is_flag=True,
    help="Enable pytest-cov for src/prodbox.",
)
@click.option(
    "--cov-fail-under",
    type=int,
    help="Minimum coverage percentage in [0, 100]; requires --coverage.",
)
def integration_gateway_daemon(coverage: bool, cov_fail_under: int | None) -> None:
    """Run process-mode gateway daemon integration tests."""
    _exit_for_suite(
        suite=INTEGRATION_GATEWAY_DAEMON_TEST_SUITE,
        coverage=coverage,
        cov_fail_under=cov_fail_under,
    )


@integration.command("gateway-pods")
@click.option(
    "--coverage",
    is_flag=True,
    help="Enable pytest-cov for src/prodbox.",
)
@click.option(
    "--cov-fail-under",
    type=int,
    help="Minimum coverage percentage in [0, 100]; requires --coverage.",
)
def integration_gateway_pods(coverage: bool, cov_fail_under: int | None) -> None:
    """Run pod-backed gateway integration tests."""
    _exit_for_suite(
        suite=INTEGRATION_GATEWAY_PODS_TEST_SUITE,
        coverage=coverage,
        cov_fail_under=cov_fail_under,
    )


@integration.command("lifecycle")
@click.option(
    "--coverage",
    is_flag=True,
    help="Enable pytest-cov for src/prodbox.",
)
@click.option(
    "--cov-fail-under",
    type=int,
    help="Minimum coverage percentage in [0, 100]; requires --coverage.",
)
def integration_lifecycle(coverage: bool, cov_fail_under: int | None) -> None:
    """Run storage + cleanup lifecycle integration tests."""
    _exit_for_suite(
        suite=INTEGRATION_LIFECYCLE_TEST_SUITE,
        coverage=coverage,
        cov_fail_under=cov_fail_under,
    )


def _exit_for_suite(
    *,
    suite: TestSuiteSelection,
    coverage: bool,
    cov_fail_under: int | None,
) -> None:
    """Resolve explicit suite settings and exit via the DAG executor."""
    coverage_settings = _coverage_settings(
        coverage=coverage,
        cov_fail_under=cov_fail_under,
    )
    sys.exit(_run_suite(suite=suite, coverage_settings=coverage_settings))


def _coverage_settings(*, coverage: bool, cov_fail_under: int | None) -> CoverageSettings:
    """Build validated coverage settings from Click options."""
    if cov_fail_under is not None and not coverage:
        raise click.UsageError("--cov-fail-under requires --coverage.")
    if cov_fail_under is not None and not 0 <= cov_fail_under <= 100:
        raise click.UsageError("--cov-fail-under must be between 0 and 100.")
    return CoverageSettings(enabled=coverage, fail_under=cov_fail_under)


def _run_suite(*, suite: TestSuiteSelection, coverage_settings: CoverageSettings) -> int:
    """Build and execute two-phase pytest workflow for one explicit suite."""
    dag = _build_test_dag(suite=suite, coverage_settings=coverage_settings)
    return execute_dag(dag)


def _build_test_dag(
    *,
    suite: TestSuiteSelection,
    coverage_settings: CoverageSettings,
) -> EffectDAG:
    """Build two-phase test DAG for one explicit suite."""
    env = dict(os.environ)
    env[ALLOW_NON_ENTRYPOINT_ENV] = "1"
    requires_integration_gate = suite.requires_integration_gate
    runbook_required = requires_integration_gate
    integration_gate_prereqs = (
        INTEGRATION_TEST_PREREQUISITES if requires_integration_gate else frozenset()
    )
    gate_message = (
        PHASE_ONE_GATE_MESSAGE if requires_integration_gate else PHASE_ONE_NO_PREREQ_MESSAGE
    )
    phase_one_node = EffectNode(
        effect=WriteStdout(
            effect_id=PHASE_ONE_HEADER_EFFECT_ID,
            description="Phase 1 header",
            text=gate_message,
        ),
        prerequisites=frozenset(),
    )
    phase_two_effects: list[Effect[object]] = []
    if runbook_required:
        phase_two_effects.extend(
            [
                WriteStdout(
                    effect_id="pytest_integration_runbook_header",
                    description="Integration runbook header",
                    text=PHASE_ONE_POINT_FIVE_HEADER_TEXT,
                ),
                RunSubprocess(
                    effect_id=INTEGRATION_RUNBOOK_EFFECT_ID,
                    description="Runbook: ensure RKE2 + Harbor + storage runtime",
                    command=[sys.executable, "-m", "prodbox.cli.main", "rke2", "ensure"],
                    stream_stdout=True,
                    timeout=INTEGRATION_RUNBOOK_TIMEOUT_SECONDS,
                    env=env,
                ),
            ]
        )
    phase_two_effects.append(
        WriteStdout(
            effect_id="pytest_phase_two_header",
            description="Phase 2 header",
            text=PHASE_TWO_HEADER_TEXT,
        )
    )
    phase_two_effects.append(
        RunSubprocess(
            effect_id="pytest_run",
            description="Execute pytest",
            command=[
                sys.executable,
                "-m",
                "pytest",
                *_pytest_args(suite=suite, coverage_settings=coverage_settings),
            ],
            stream_stdout=True,
            timeout=TEST_TIMEOUT_SECONDS,
            env=env,
        )
    )

    phase_two = Sequence(
        effect_id="pytest_phase_two",
        description="Execute post-gate test phases",
        effects=phase_two_effects,
    )
    phase_two_node = EffectNode(
        effect=phase_two,
        prerequisites=(
            integration_gate_prereqs
            if requires_integration_gate
            else frozenset({PHASE_ONE_HEADER_EFFECT_ID})
        ),
    )
    registry = _build_test_prerequisite_registry(
        phase_one_node=phase_one_node,
        integration_gate_prereqs=integration_gate_prereqs,
    )
    return EffectDAG.from_roots(phase_two_node, registry=registry)


def _pytest_args(
    *,
    suite: TestSuiteSelection,
    coverage_settings: CoverageSettings,
) -> tuple[str, ...]:
    """Build explicit pytest argv from suite + coverage selections."""
    coverage_args: tuple[str, ...]
    if coverage_settings.enabled:
        coverage_threshold_args = (
            (f"--cov-fail-under={coverage_settings.fail_under}",)
            if coverage_settings.fail_under is not None
            else ()
        )
        coverage_args = ("--cov=src/prodbox", *coverage_threshold_args)
    else:
        coverage_args = ()
    return (*coverage_args, *suite.pytest_args)


def _build_test_prerequisite_registry(
    *,
    phase_one_node: EffectNode[None],
    integration_gate_prereqs: frozenset[str],
) -> dict[str, EffectNode[object]]:
    """Return local registry with the Phase 1 banner ahead of gate checks."""
    registry: dict[str, EffectNode[object]] = dict(PREREQUISITE_REGISTRY)
    registry[phase_one_node.effect_id] = phase_one_node
    phase_one_prereq = frozenset({phase_one_node.effect_id})
    for effect_id in _transitive_prerequisite_ids(
        effect_ids=integration_gate_prereqs,
        registry=registry,
    ):
        node = registry[effect_id]
        registry[effect_id] = replace(
            node,
            prerequisites=node.prerequisites | phase_one_prereq,
        )
    return registry


def _transitive_prerequisite_ids(
    *,
    effect_ids: frozenset[str],
    registry: dict[str, EffectNode[object]],
) -> frozenset[str]:
    """Return the full prerequisite closure for selected integration checks."""
    visited: set[str] = set()

    def visit(effect_id: str) -> None:
        if effect_id in visited:
            return
        visited.add(effect_id)
        for prereq_id in registry[effect_id].prerequisites:
            visit(prereq_id)

    for effect_id in effect_ids:
        visit(effect_id)

    return frozenset(visited)
