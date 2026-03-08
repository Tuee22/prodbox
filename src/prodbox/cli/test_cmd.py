"""Test command for running pytest through the prodbox CLI."""

from __future__ import annotations

import os
import re
import sys

import click

from prodbox.cli.command_executor import execute_dag
from prodbox.cli.effect_dag import EffectDAG, EffectNode
from prodbox.cli.effects import RunSubprocess, Sequence, WriteStdout
from prodbox.cli.prerequisite_registry import PREREQUISITE_REGISTRY
from prodbox.lib.lint.poetry_entrypoint_guard import ALLOW_NON_ENTRYPOINT_ENV

TEST_TIMEOUT_SECONDS: float = 1800.0
INTEGRATION_TEST_PREREQUISITES: frozenset[str] = frozenset(
    {
        "tool_kubectl",
        "kubeconfig_home_exists",
        "rke2_service_active",
    }
)


@click.command(
    "test",
    context_settings={"ignore_unknown_options": True, "allow_extra_args": True},
)
@click.pass_context
def run_tests_cmd(ctx: click.Context) -> None:
    """Run pytest through the prodbox CLI."""
    sys.exit(_run_tests(tuple(ctx.args)))


def _run_tests(args: tuple[str, ...]) -> int:
    """Build and execute two-phase pytest workflow with prerequisite gate."""
    dag = _build_test_dag(args)
    return execute_dag(dag)


def _build_test_dag(args: tuple[str, ...]) -> EffectDAG:
    """Build two-phase test DAG (prerequisite gate + pytest execution)."""
    env = dict(os.environ)
    env[ALLOW_NON_ENTRYPOINT_ENV] = "1"
    phase_two = Sequence(
        effect_id="pytest_phase_two",
        description="Phase 2: Execute pytest suites",
        effects=[
            WriteStdout(
                effect_id="pytest_phase_two_header",
                description="Phase 2 header",
                text="Phase 2/2: running pytest suites",
            ),
            RunSubprocess(
                effect_id="pytest_run",
                description="Execute pytest",
                command=[sys.executable, "-m", "pytest", *args],
                stream_stdout=True,
                timeout=TEST_TIMEOUT_SECONDS,
                env=env,
            ),
        ],
    )
    requires_integration_gate = _requires_integration_prerequisites(args)
    gate_message = (
        "Phase 1/2: validating integration prerequisites"
        if requires_integration_gate
        else "Phase 1/2: no integration prerequisites required"
    )
    phase_one_node = EffectNode(
        effect=WriteStdout(
            effect_id="pytest_phase_one_header",
            description="Phase 1 header",
            text=gate_message,
        ),
        prerequisites=frozenset(),
    )
    phase_two_node = EffectNode(
        effect=phase_two,
        prerequisites=(
            INTEGRATION_TEST_PREREQUISITES if requires_integration_gate else frozenset()
        ),
    )
    return EffectDAG.from_roots(phase_one_node, phase_two_node, registry=PREREQUISITE_REGISTRY)


def _requires_integration_prerequisites(args: tuple[str, ...]) -> bool:
    """Return True when selected test scope can execute integration tests."""
    marker_expressions = _extract_marker_expressions(args)
    if marker_expressions and all(
        _is_unit_only_marker_expression(expression) for expression in marker_expressions
    ):
        return False
    if _is_unit_path_selection(args):
        return False
    return True


def _extract_marker_expressions(args: tuple[str, ...]) -> tuple[str, ...]:
    """Extract pytest marker expressions from argv-style args."""
    expressions: list[str] = []
    index = 0
    while index < len(args):
        token = args[index]
        if token in ("-m", "--markexpr"):
            if index + 1 < len(args):
                expressions.append(args[index + 1])
                index += 2
                continue
            index += 1
            continue
        if token.startswith("-m="):
            expressions.append(token.split("=", maxsplit=1)[1])
        if token.startswith("--markexpr="):
            expressions.append(token.split("=", maxsplit=1)[1])
        index += 1
    return tuple(expressions)


def _is_unit_only_marker_expression(expression: str) -> bool:
    """Return True if marker expression explicitly excludes integration tests."""
    lowered = expression.lower()
    if "not integration" not in lowered:
        return False
    without_not_integration = re.sub(r"\bnot\s+integration\b", " ", lowered)
    return "integration" not in without_not_integration


def _is_unit_path_selection(args: tuple[str, ...]) -> bool:
    """Return True if all explicit test-path arguments target tests/unit."""
    path_args = tuple(arg for arg in args if _looks_like_test_path(arg))
    if not path_args:
        return False
    return all(_is_unit_test_path(path_arg) for path_arg in path_args)


def _looks_like_test_path(arg: str) -> bool:
    """Heuristic check for pytest file/directory path selectors."""
    return "/" in arg or "\\" in arg or arg.endswith(".py")


def _is_unit_test_path(path_arg: str) -> bool:
    """Return True if path selector points to tests/unit subtree."""
    normalized = path_arg.split("::", maxsplit=1)[0].replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    if normalized == "tests/unit":
        return True
    return normalized.startswith("tests/unit/")
