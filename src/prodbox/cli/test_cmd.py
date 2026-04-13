"""Explicit test suite commands for running pytest through the prodbox CLI."""

from __future__ import annotations

import asyncio
import os
import subprocess
import sys
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Final

import click

from prodbox.cli.command_executor import _execute_dag_with_values_async, execute_dag
from prodbox.cli.effect_dag import EffectDAG, EffectNode
from prodbox.cli.effects import Custom, Effect, RunSubprocess, Sequence, WriteStdout
from prodbox.cli.prerequisite_registry import PREREQUISITE_REGISTRY
from prodbox.lib.lint.poetry_entrypoint_guard import ALLOW_NON_ENTRYPOINT_ENV

TEST_TIMEOUT_SECONDS: float = 14400.0
INTEGRATION_RUNBOOK_TIMEOUT_SECONDS: float = 3600.0
AGGREGATE_COVERAGE_ERASE_TIMEOUT_SECONDS: float = 60.0
SUPPORTED_RUNTIME_RESTORE_TIMEOUT_SECONDS: float = 3600.0
PUBLIC_HOST_POSTFLIGHT_TIMEOUT_SECONDS: float = 900.0
PUBLIC_HOST_POSTFLIGHT_RETRY_INTERVAL_SECONDS: float = 10.0
AGGREGATE_COVERAGE_FILE: Final[str] = ".coverage.prodbox.aggregate"

# Subprocess environment allowlist — only these vars pass through to the pytest process.
# Includes Pulumi/test vars because integration tests use the interpreter, which reads
# these from os.environ when constructing subprocess environments for Pulumi operations.
_TEST_PASSTHROUGH_VARS: Final[tuple[str, ...]] = (
    "PATH",
    "HOME",
    "LANG",
    "TERM",
    "USER",
    "PULUMI_CONFIG_PASSPHRASE",
    "PULUMI_CONFIG_PASSPHRASE_FILE",
    "PULUMI_HOME",
    "PULUMI_BACKEND_URL",
    "ROUTE53_ZONE_ID",
    "PULUMI_TEST_RECORD_FQDN",
    "PULUMI_TEST_RECORD_VALUE",
)
# Aggregate suites use an explicit order so the external public-host proof runs
# before cluster-backed suites that intentionally tear down the shared vscode
# stack, the full-stack chart suite clears the singleton release names before
# the storage-only suite runs, and the cleanup-heavy lifecycle suite runs last.
_CANONICAL_INTEGRATION_ALL_PYTEST_ARGS: Final[tuple[str, ...]] = (
    "tests/integration/test_charts_vscode.py",
    "tests/integration/test_public_dns_delegation.py",
    "tests/integration/test_cli_commands.py",
    "tests/integration/test_cli_env.py",
    "tests/integration/test_dns_route53_aws.py",
    "tests/integration/test_aws_foundation_real.py",
    "tests/integration/test_aws_eks_real.py",
    "tests/integration/test_pulumi_real.py",
    "tests/integration/test_gateway_daemon_k8s.py",
    "tests/integration/test_gateway_k8s_pods.py",
    "tests/integration/test_gateway_partition.py",
    "tests/integration/test_charts_platform.py",
    "tests/integration/test_charts_storage.py",
    "tests/integration/test_prodbox_lifecycle.py",
)
INTEGRATION_RUNBOOK_EFFECT_ID: str = "pytest_integration_runbook_install"
AGGREGATE_COVERAGE_ERASE_EFFECT_ID: Final[str] = "pytest_aggregate_coverage_erase"
PHASE_ONE_HEADER_EFFECT_ID: Final[str] = "pytest_phase_one_header"
PHASE_ONE_GATE_MESSAGE: Final[str] = "Phase 1/2: validating integration prerequisites"
PHASE_ONE_NO_PREREQ_MESSAGE: Final[str] = "Phase 1/2: no integration prerequisites required"
PHASE_ONE_POINT_FIVE_HEADER_TEXT: Final[str] = "Phase 1.5/2: enforcing integration runbook"
PHASE_ONE_POINT_SIX_HEADER_TEXT: Final[str] = "Phase 1.6/2: restoring supported runtime"
PHASE_TWO_HEADER_TEXT: Final[str] = "Phase 2/2: running pytest suites"
PUBLIC_HOST_READINESS_EFFECT_ID: Final[str] = "pytest_public_host_readiness"
PUBLIC_HOST_HOSTS_OVERRIDE_EFFECT_ID: Final[str] = "pytest_public_host_hosts_override_cleanup"
PUBLIC_EDGE_CONNECT_HOST_ENV_VAR: Final[str] = "PRODBOX_PUBLIC_EDGE_CONNECT_HOST"
PRE_PYTEST_RESTORE_HEADER_EFFECT_ID: Final[str] = "pytest_supported_runtime_bootstrap_header"
PRE_PYTEST_PULUMI_REFRESH_EFFECT_ID: Final[
    str
] = "pytest_supported_runtime_bootstrap_pulumi_refresh"
PRE_PYTEST_PULUMI_UP_EFFECT_ID: Final[str] = "pytest_supported_runtime_bootstrap_pulumi_up"
PRE_PYTEST_GATEWAY_DEPLOY_EFFECT_ID: Final[str] = "pytest_supported_runtime_bootstrap_gateway"
PRE_PYTEST_VSCODE_DEPLOY_EFFECT_ID: Final[str] = "pytest_supported_runtime_bootstrap_vscode"
POST_PYTEST_RESTORE_HEADER_EFFECT_ID: Final[str] = "pytest_supported_runtime_restore_header"
POST_PYTEST_RKE2_INSTALL_EFFECT_ID: Final[str] = "pytest_supported_runtime_restore_rke2_install"
POST_PYTEST_PULUMI_REFRESH_EFFECT_ID: Final[str] = "pytest_supported_runtime_restore_pulumi_refresh"
POST_PYTEST_PULUMI_UP_EFFECT_ID: Final[str] = "pytest_supported_runtime_restore_pulumi_up"
POST_PYTEST_GATEWAY_DEPLOY_EFFECT_ID: Final[str] = "pytest_supported_runtime_restore_gateway"
POST_PYTEST_VSCODE_DEPLOY_EFFECT_ID: Final[str] = "pytest_supported_runtime_restore_vscode"
POST_PYTEST_PUBLIC_EDGE_EFFECT_ID: Final[str] = "pytest_supported_runtime_restore_public_edge"
POST_PYTEST_AWS_AUDIT_EFFECT_ID: Final[str] = "pytest_supported_runtime_restore_aws_audit"
_PUBLIC_HOST_STACK_PREP_SUITE_IDS: Final[frozenset[str]] = frozenset({"all", "integration-all"})
_SUPPORTED_RUNTIME_POSTFLIGHT_SUITE_IDS: Final[frozenset[str]] = frozenset(
    {"all", "integration-all"}
)
CLUSTER_INTEGRATION_TEST_PREREQUISITES: frozenset[str] = frozenset(
    {
        "supported_ubuntu_2404",
        "tool_docker",
        "tool_ctr",
        "tool_helm",
        "tool_kubectl",
        "tool_sudo",
        "tool_systemctl",
        "settings_object",
    }
)
DNS_AWS_TEST_PREREQUISITES: frozenset[str] = frozenset(
    {
        "tool_aws",
    }
)
PULUMI_TEST_PREREQUISITES: frozenset[str] = CLUSTER_INTEGRATION_TEST_PREREQUISITES | frozenset(
    {
        "tool_pulumi",
    }
)
ALL_INTEGRATION_TEST_PREREQUISITES: frozenset[str] = (
    CLUSTER_INTEGRATION_TEST_PREREQUISITES | DNS_AWS_TEST_PREREQUISITES | PULUMI_TEST_PREREQUISITES
)


@dataclass(frozen=True)
class CoverageSettings:
    """Explicit coverage configuration for one test invocation."""

    enabled: bool
    fail_under: int | None


@dataclass(frozen=True)
class PytestInvocation:
    """One isolated pytest process to run as part of a named suite."""

    invocation_id: str
    pytest_args: tuple[str, ...]


@dataclass(frozen=True)
class TestSuiteSelection:
    """Explicitly named pytest suite exposed by the Click surface."""

    suite_id: str
    pytest_args: tuple[str, ...]
    integration_gate_prerequisites: frozenset[str]
    requires_integration_runbook: bool
    aggregate_pytest_invocations: tuple[PytestInvocation, ...] = ()


_CANONICAL_INTEGRATION_ALL_PYTEST_INVOCATIONS: Final[tuple[PytestInvocation, ...]] = tuple(
    PytestInvocation(
        invocation_id=path.removeprefix("tests/integration/test_").removesuffix(".py"),
        pytest_args=(path,),
    )
    for path in _CANONICAL_INTEGRATION_ALL_PYTEST_ARGS
)


ALL_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="all",
    pytest_args=("tests/unit", *_CANONICAL_INTEGRATION_ALL_PYTEST_ARGS),
    integration_gate_prerequisites=ALL_INTEGRATION_TEST_PREREQUISITES,
    requires_integration_runbook=True,
    aggregate_pytest_invocations=(
        PytestInvocation(invocation_id="unit", pytest_args=("tests/unit",)),
        *_CANONICAL_INTEGRATION_ALL_PYTEST_INVOCATIONS,
    ),
)
UNIT_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="unit",
    pytest_args=("tests/unit",),
    integration_gate_prerequisites=frozenset(),
    requires_integration_runbook=False,
)
INTEGRATION_ALL_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-all",
    pytest_args=_CANONICAL_INTEGRATION_ALL_PYTEST_ARGS,
    integration_gate_prerequisites=ALL_INTEGRATION_TEST_PREREQUISITES,
    requires_integration_runbook=True,
    aggregate_pytest_invocations=_CANONICAL_INTEGRATION_ALL_PYTEST_INVOCATIONS,
)
INTEGRATION_CLI_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-cli",
    pytest_args=("tests/integration/test_cli_commands.py",),
    integration_gate_prerequisites=frozenset(),
    requires_integration_runbook=False,
)
INTEGRATION_ENV_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-env",
    pytest_args=("tests/integration/test_cli_env.py",),
    integration_gate_prerequisites=frozenset(),
    requires_integration_runbook=False,
)
INTEGRATION_DNS_AWS_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-dns-aws",
    pytest_args=("tests/integration/test_dns_route53_aws.py",),
    integration_gate_prerequisites=DNS_AWS_TEST_PREREQUISITES,
    requires_integration_runbook=False,
)
INTEGRATION_AWS_FOUNDATION_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-aws-foundation",
    pytest_args=("tests/integration/test_aws_foundation_real.py",),
    integration_gate_prerequisites=DNS_AWS_TEST_PREREQUISITES,
    requires_integration_runbook=False,
)
INTEGRATION_AWS_EKS_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-aws-eks",
    pytest_args=("tests/integration/test_aws_eks_real.py",),
    integration_gate_prerequisites=DNS_AWS_TEST_PREREQUISITES,
    requires_integration_runbook=False,
)
INTEGRATION_PULUMI_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-pulumi",
    pytest_args=("tests/integration/test_pulumi_real.py",),
    integration_gate_prerequisites=PULUMI_TEST_PREREQUISITES,
    requires_integration_runbook=True,
)
INTEGRATION_GATEWAY_DAEMON_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-gateway-daemon",
    pytest_args=("tests/integration/test_gateway_daemon_k8s.py",),
    integration_gate_prerequisites=CLUSTER_INTEGRATION_TEST_PREREQUISITES,
    requires_integration_runbook=True,
)
INTEGRATION_GATEWAY_PODS_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-gateway-pods",
    pytest_args=("tests/integration/test_gateway_k8s_pods.py",),
    integration_gate_prerequisites=CLUSTER_INTEGRATION_TEST_PREREQUISITES,
    requires_integration_runbook=True,
)
INTEGRATION_GATEWAY_PARTITION_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-gateway-partition",
    pytest_args=("tests/integration/test_gateway_partition.py",),
    integration_gate_prerequisites=CLUSTER_INTEGRATION_TEST_PREREQUISITES,
    requires_integration_runbook=True,
)
INTEGRATION_LIFECYCLE_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-lifecycle",
    pytest_args=("tests/integration/test_prodbox_lifecycle.py",),
    integration_gate_prerequisites=CLUSTER_INTEGRATION_TEST_PREREQUISITES,
    requires_integration_runbook=True,
)
INTEGRATION_CHARTS_STORAGE_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-charts-storage",
    pytest_args=("tests/integration/test_charts_storage.py",),
    integration_gate_prerequisites=CLUSTER_INTEGRATION_TEST_PREREQUISITES,
    requires_integration_runbook=True,
)
INTEGRATION_CHARTS_PLATFORM_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-charts-platform",
    pytest_args=("tests/integration/test_charts_platform.py",),
    integration_gate_prerequisites=CLUSTER_INTEGRATION_TEST_PREREQUISITES,
    requires_integration_runbook=True,
)
INTEGRATION_CHARTS_VSCODE_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-charts-vscode",
    pytest_args=("tests/integration/test_charts_vscode.py",),
    integration_gate_prerequisites=frozenset(),
    requires_integration_runbook=False,
)
INTEGRATION_PUBLIC_DNS_TEST_SUITE: Final[TestSuiteSelection] = TestSuiteSelection(
    suite_id="integration-public-dns",
    pytest_args=("tests/integration/test_public_dns_delegation.py",),
    integration_gate_prerequisites=frozenset(),
    requires_integration_runbook=False,
)


@click.group("test", no_args_is_help=True)
def test() -> None:
    """Run explicitly named prodbox test suites.

    \b
    Supported suites:
      prodbox test all
      prodbox test unit
      prodbox test integration all
      prodbox test integration aws-foundation
      prodbox test integration aws-eks
      prodbox test integration cli
      prodbox test integration dns-aws
      prodbox test integration env
      prodbox test integration pulumi
      prodbox test integration gateway-daemon
      prodbox test integration gateway-pods
      prodbox test integration gateway-partition
      prodbox test integration lifecycle
      prodbox test integration charts-storage
      prodbox test integration charts-platform
      prodbox test integration charts-vscode
      prodbox test integration public-dns
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


@integration.command("aws-foundation")
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
def integration_aws_foundation(coverage: bool, cov_fail_under: int | None) -> None:
    """Run real shared-account AWS foundation integration tests."""
    _exit_for_suite(
        suite=INTEGRATION_AWS_FOUNDATION_TEST_SUITE,
        coverage=coverage,
        cov_fail_under=cov_fail_under,
    )


@integration.command("aws-eks")
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
def integration_aws_eks(coverage: bool, cov_fail_under: int | None) -> None:
    """Run real EKS control-plane integration tests."""
    _exit_for_suite(
        suite=INTEGRATION_AWS_EKS_TEST_SUITE,
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


@integration.command("dns-aws")
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
def integration_dns_aws(coverage: bool, cov_fail_under: int | None) -> None:
    """Run real Route 53 integration tests against ephemeral AWS resources."""
    _exit_for_suite(
        suite=INTEGRATION_DNS_AWS_TEST_SUITE,
        coverage=coverage,
        cov_fail_under=cov_fail_under,
    )


@integration.command("pulumi")
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
def integration_pulumi(coverage: bool, cov_fail_under: int | None) -> None:
    """Run real Pulumi CLI integration tests."""
    _exit_for_suite(
        suite=INTEGRATION_PULUMI_TEST_SUITE,
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


@integration.command("gateway-partition")
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
def integration_gateway_partition(coverage: bool, cov_fail_under: int | None) -> None:
    """Run chart-deployed gateway partition tolerance integration tests."""
    _exit_for_suite(
        suite=INTEGRATION_GATEWAY_PARTITION_TEST_SUITE,
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
    """Run storage + delete/reinstall lifecycle integration tests."""
    _exit_for_suite(
        suite=INTEGRATION_LIFECYCLE_TEST_SUITE,
        coverage=coverage,
        cov_fail_under=cov_fail_under,
    )


@integration.command("charts-storage")
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
def integration_charts_storage(coverage: bool, cov_fail_under: int | None) -> None:
    """Run chart platform deterministic storage integration tests."""
    _exit_for_suite(
        suite=INTEGRATION_CHARTS_STORAGE_TEST_SUITE,
        coverage=coverage,
        cov_fail_under=cov_fail_under,
    )


@integration.command("charts-platform")
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
def integration_charts_platform(coverage: bool, cov_fail_under: int | None) -> None:
    """Run chart platform end-to-end stack integration tests."""
    _exit_for_suite(
        suite=INTEGRATION_CHARTS_PLATFORM_TEST_SUITE,
        coverage=coverage,
        cov_fail_under=cov_fail_under,
    )


@integration.command("charts-vscode")
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
def integration_charts_vscode(coverage: bool, cov_fail_under: int | None) -> None:
    """Run VS Code public-hostname + TLS + auth-wall integration tests."""
    _exit_for_suite(
        suite=INTEGRATION_CHARTS_VSCODE_TEST_SUITE,
        coverage=coverage,
        cov_fail_under=cov_fail_under,
    )


@integration.command("public-dns")
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
def integration_public_dns(coverage: bool, cov_fail_under: int | None) -> None:
    """Run public Route 53 delegation proof integration tests."""
    _exit_for_suite(
        suite=INTEGRATION_PUBLIC_DNS_TEST_SUITE,
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
    env = {key: os.environ[key] for key in _TEST_PASSTHROUGH_VARS if key in os.environ}
    env[ALLOW_NON_ENTRYPOINT_ENV] = "1"
    env.update(_public_edge_probe_env())
    pytest_invocations = _pytest_invocations_for_suite(suite=suite)
    multiple_pytest_invocations = len(pytest_invocations) > 1
    aggregate_pytest_env = (
        {**env, "COVERAGE_FILE": AGGREGATE_COVERAGE_FILE}
        if coverage_settings.enabled and multiple_pytest_invocations
        else env
    )
    integration_gate_prereqs = suite.integration_gate_prerequisites
    requires_integration_gate = bool(integration_gate_prereqs)
    runbook_required = suite.requires_integration_runbook
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
        phase_two_effects.extend(_runbook_effects_for_suite(suite=suite, env=env))
    phase_two_effects.append(
        WriteStdout(
            effect_id="pytest_phase_two_header",
            description="Phase 2 header",
            text=PHASE_TWO_HEADER_TEXT,
        )
    )
    if coverage_settings.enabled and multiple_pytest_invocations:
        phase_two_effects.append(
            RunSubprocess(
                effect_id=AGGREGATE_COVERAGE_ERASE_EFFECT_ID,
                description="Erase aggregate coverage data",
                command=[sys.executable, "-m", "coverage", "erase"],
                stream_stdout=True,
                timeout=AGGREGATE_COVERAGE_ERASE_TIMEOUT_SECONDS,
                env=aggregate_pytest_env,
            )
        )
    for index, invocation in enumerate(pytest_invocations):
        is_last_invocation = index == len(pytest_invocations) - 1
        phase_two_effects.append(
            RunSubprocess(
                effect_id=_pytest_effect_id(
                    invocation_id=invocation.invocation_id,
                    total_invocations=len(pytest_invocations),
                ),
                description=f"Execute pytest for {invocation.invocation_id}",
                command=[
                    sys.executable,
                    "-m",
                    "pytest",
                    *_pytest_args_for_invocation(
                        pytest_args=invocation.pytest_args,
                        coverage_settings=coverage_settings,
                        multiple_invocations=multiple_pytest_invocations,
                        is_last_invocation=is_last_invocation,
                    ),
                ],
                stream_stdout=True,
                timeout=TEST_TIMEOUT_SECONDS,
                env=aggregate_pytest_env,
            )
        )
    phase_two_effects.extend(_post_pytest_effects_for_suite(suite=suite, env=env))

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
    return _pytest_args_for_invocation(
        pytest_args=suite.pytest_args,
        coverage_settings=coverage_settings,
        multiple_invocations=False,
        is_last_invocation=True,
    )


def _pytest_args_for_invocation(
    *,
    pytest_args: tuple[str, ...],
    coverage_settings: CoverageSettings,
    multiple_invocations: bool,
    is_last_invocation: bool,
) -> tuple[str, ...]:
    """Build explicit pytest argv for one isolated pytest process."""
    coverage_args: tuple[str, ...]
    if coverage_settings.enabled:
        if multiple_invocations:
            coverage_report_args = () if is_last_invocation else ("--cov-report=",)
            coverage_threshold_args = (
                (f"--cov-fail-under={coverage_settings.fail_under}",)
                if coverage_settings.fail_under is not None and is_last_invocation
                else ()
            )
            coverage_args = (
                "--cov=src/prodbox",
                "--cov-append",
                *coverage_report_args,
                *coverage_threshold_args,
            )
        else:
            coverage_threshold_args = (
                (f"--cov-fail-under={coverage_settings.fail_under}",)
                if coverage_settings.fail_under is not None
                else ()
            )
            coverage_args = ("--cov=src/prodbox", *coverage_threshold_args)
    else:
        coverage_args = ()
    return (*coverage_args, *pytest_args)


def _pytest_invocations_for_suite(*, suite: TestSuiteSelection) -> tuple[PytestInvocation, ...]:
    """Return one or more isolated pytest subprocesses for a selected suite."""
    if suite.aggregate_pytest_invocations:
        return suite.aggregate_pytest_invocations
    return (PytestInvocation(invocation_id=suite.suite_id, pytest_args=suite.pytest_args),)


def _pytest_effect_id(*, invocation_id: str, total_invocations: int) -> str:
    """Build stable pytest effect ids for single-process and aggregate suites."""
    if total_invocations == 1:
        return "pytest_run"
    return f"pytest_run_{invocation_id}"


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


def _runbook_effects_for_suite(
    *,
    suite: TestSuiteSelection,
    env: dict[str, str],
) -> list[Effect[object]]:
    """Build Phase 1.5 runbook effects for one selected suite."""
    effects: list[Effect[object]] = [
        WriteStdout(
            effect_id="pytest_integration_runbook_header",
            description="Integration runbook header",
            text=PHASE_ONE_POINT_FIVE_HEADER_TEXT,
        ),
        RunSubprocess(
            effect_id=INTEGRATION_RUNBOOK_EFFECT_ID,
            description="Runbook: install or reconcile the host-owned RKE2 + Harbor + storage runtime",
            command=[sys.executable, "-m", "prodbox.cli.main", "rke2", "install"],
            stream_stdout=True,
            timeout=INTEGRATION_RUNBOOK_TIMEOUT_SECONDS,
            env=env,
        ),
    ]
    if suite.suite_id not in _PUBLIC_HOST_STACK_PREP_SUITE_IDS:
        return effects
    effects.extend(
        [
            WriteStdout(
                effect_id=PRE_PYTEST_RESTORE_HEADER_EFFECT_ID,
                description="Supported runtime bootstrap header",
                text=PHASE_ONE_POINT_SIX_HEADER_TEXT,
            ),
            Custom(
                effect_id=PUBLIC_HOST_HOSTS_OVERRIDE_EFFECT_ID,
                description="Remove unsupported /etc/hosts override for the public host",
                fn=_remove_public_host_hosts_override,
            ),
            RunSubprocess(
                effect_id=PRE_PYTEST_PULUMI_REFRESH_EFFECT_ID,
                description="Runbook: refresh Pulumi-managed infrastructure state",
                command=[sys.executable, "-m", "prodbox.cli.main", "pulumi", "refresh"],
                stream_stdout=True,
                timeout=SUPPORTED_RUNTIME_RESTORE_TIMEOUT_SECONDS,
                env=env,
            ),
            RunSubprocess(
                effect_id=PRE_PYTEST_PULUMI_UP_EFFECT_ID,
                description="Runbook: restore Pulumi-managed infrastructure",
                command=[sys.executable, "-m", "prodbox.cli.main", "pulumi", "up", "--yes"],
                stream_stdout=True,
                timeout=SUPPORTED_RUNTIME_RESTORE_TIMEOUT_SECONDS,
                env=env,
            ),
            RunSubprocess(
                effect_id=PRE_PYTEST_GATEWAY_DEPLOY_EFFECT_ID,
                description="Runbook: deploy gateway chart",
                command=[sys.executable, "-m", "prodbox.cli.main", "charts", "deploy", "gateway"],
                stream_stdout=True,
                timeout=SUPPORTED_RUNTIME_RESTORE_TIMEOUT_SECONDS,
                env=env,
            ),
            RunSubprocess(
                effect_id=PRE_PYTEST_VSCODE_DEPLOY_EFFECT_ID,
                description="Runbook: deploy vscode chart",
                command=[sys.executable, "-m", "prodbox.cli.main", "charts", "deploy", "vscode"],
                stream_stdout=True,
                timeout=SUPPORTED_RUNTIME_RESTORE_TIMEOUT_SECONDS,
                env=env,
            ),
            Custom(
                effect_id=PUBLIC_HOST_READINESS_EFFECT_ID,
                description="Runbook: require ready public-host proof surface",
                fn=_wait_for_public_host_ready_for_external_proof,
            ),
        ]
    )
    return effects


def _post_pytest_effects_for_suite(
    *,
    suite: TestSuiteSelection,
    env: dict[str, str],
) -> list[Effect[object]]:
    """Build aggregate-suite postflight effects that restore the supported runtime."""
    if suite.suite_id not in _SUPPORTED_RUNTIME_POSTFLIGHT_SUITE_IDS:
        return []
    return [
        WriteStdout(
            effect_id=POST_PYTEST_RESTORE_HEADER_EFFECT_ID,
            description="Supported runtime restore header",
            text="Post-pytest: restoring supported runtime",
        ),
        RunSubprocess(
            effect_id=POST_PYTEST_RKE2_INSTALL_EFFECT_ID,
            description="Postflight: reinstall or reconcile the host-owned RKE2 cluster",
            command=[sys.executable, "-m", "prodbox.cli.main", "rke2", "install"],
            stream_stdout=True,
            timeout=SUPPORTED_RUNTIME_RESTORE_TIMEOUT_SECONDS,
            env=env,
        ),
        RunSubprocess(
            effect_id=POST_PYTEST_PULUMI_REFRESH_EFFECT_ID,
            description="Postflight: refresh Pulumi-managed infrastructure state",
            command=[sys.executable, "-m", "prodbox.cli.main", "pulumi", "refresh"],
            stream_stdout=True,
            timeout=SUPPORTED_RUNTIME_RESTORE_TIMEOUT_SECONDS,
            env=env,
        ),
        RunSubprocess(
            effect_id=POST_PYTEST_PULUMI_UP_EFFECT_ID,
            description="Postflight: restore Pulumi-managed infrastructure",
            command=[sys.executable, "-m", "prodbox.cli.main", "pulumi", "up", "--yes"],
            stream_stdout=True,
            timeout=SUPPORTED_RUNTIME_RESTORE_TIMEOUT_SECONDS,
            env=env,
        ),
        RunSubprocess(
            effect_id=POST_PYTEST_GATEWAY_DEPLOY_EFFECT_ID,
            description="Postflight: deploy gateway chart",
            command=[sys.executable, "-m", "prodbox.cli.main", "charts", "deploy", "gateway"],
            stream_stdout=True,
            timeout=SUPPORTED_RUNTIME_RESTORE_TIMEOUT_SECONDS,
            env=env,
        ),
        RunSubprocess(
            effect_id=POST_PYTEST_VSCODE_DEPLOY_EFFECT_ID,
            description="Postflight: deploy vscode chart",
            command=[sys.executable, "-m", "prodbox.cli.main", "charts", "deploy", "vscode"],
            stream_stdout=True,
            timeout=SUPPORTED_RUNTIME_RESTORE_TIMEOUT_SECONDS,
            env=env,
        ),
        Custom(
            effect_id=POST_PYTEST_PUBLIC_EDGE_EFFECT_ID,
            description="Postflight: wait for ready public-host proof surface",
            fn=_wait_for_public_host_ready_for_external_proof,
        ),
        Custom(
            effect_id=POST_PYTEST_AWS_AUDIT_EFFECT_ID,
            description="Postflight: prove no fixture-owned AWS resources remain",
            fn=_assert_no_fixture_owned_aws_resources_remain,
        ),
    ]


def _remove_fqdn_from_hosts_text(*, hosts_text: str, fqdn: str) -> tuple[str, int]:
    """Remove one unsupported FQDN override from hosts-file text."""
    target = fqdn.strip().lower()
    if target == "":
        return hosts_text, 0

    updated_lines: list[str] = []
    removed_entries = 0
    for raw_line in hosts_text.splitlines():
        body, has_comment, comment = raw_line.partition("#")
        tokens = body.split()
        if len(tokens) < 2:
            updated_lines.append(raw_line)
            continue
        names = tokens[1:]
        kept_names = tuple(name for name in names if name.lower() != target)
        removed_entries += len(names) - len(kept_names)
        if len(kept_names) == len(names):
            updated_lines.append(raw_line)
            continue
        if kept_names:
            updated_line = f"{tokens[0]} {' '.join(kept_names)}"
            if has_comment:
                stripped_comment = comment.strip()
                if stripped_comment != "":
                    updated_line = f"{updated_line}  # {stripped_comment}"
            updated_lines.append(updated_line)
            continue
        if has_comment:
            stripped_comment = comment.strip()
            if stripped_comment != "":
                updated_lines.append(f"# {stripped_comment}")

    updated_text = "\n".join(updated_lines)
    if hosts_text.endswith("\n"):
        updated_text = f"{updated_text}\n"
    return updated_text, removed_entries


def _public_edge_probe_env() -> dict[str, str]:
    """Build optional pytest env that targets the deterministic local edge IP."""
    match os.environ.get(PUBLIC_EDGE_CONNECT_HOST_ENV_VAR):
        case str() as value if value.strip():
            return {PUBLIC_EDGE_CONNECT_HOST_ENV_VAR: value.strip()}
        case _:
            pass

    from prodbox.settings import discover_lan_addressing

    try:
        lan = discover_lan_addressing()
    except OSError:
        return {}
    except ValueError:
        return {}
    return {PUBLIC_EDGE_CONNECT_HOST_ENV_VAR: lan.ingress_lb_ip}


def _hosts_file_subprocess_env() -> dict[str, str]:
    """Build a minimal subprocess env for host-file maintenance helpers."""
    env: dict[str, str] = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", ""),
        "LANG": os.environ.get("LANG", "C.UTF-8"),
    }
    match os.environ.get("TERM"):
        case str() as term:
            env["TERM"] = term
        case _:
            pass
    return env


def _remove_public_host_hosts_override() -> str:
    """Remove unsupported /etc/hosts overrides for the canonical public host."""
    from prodbox.settings import Settings

    settings = Settings.from_config_json()
    fqdn = settings.vscode_fqdn or settings.demo_fqdn
    hosts_path = Path("/etc/hosts")
    original_text = hosts_path.read_text(encoding="utf-8")
    updated_text, removed_entries = _remove_fqdn_from_hosts_text(
        hosts_text=original_text,
        fqdn=fqdn,
    )
    if removed_entries == 0:
        return f"No /etc/hosts override found for {fqdn}"
    if os.access(hosts_path, os.W_OK):
        hosts_path.write_text(updated_text, encoding="utf-8")
    else:
        completed = subprocess.run(
            ["sudo", "tee", str(hosts_path)],
            input=updated_text,
            text=True,
            capture_output=True,
            check=False,
            timeout=30.0,
            env=_hosts_file_subprocess_env(),
        )
        if completed.returncode != 0:
            stderr_text = completed.stderr.strip() or completed.stdout.strip()
            raise RuntimeError(f"failed to rewrite {hosts_path}: {stderr_text}")
    post_write_text = hosts_path.read_text(encoding="utf-8")
    _, remaining_entries = _remove_fqdn_from_hosts_text(hosts_text=post_write_text, fqdn=fqdn)
    if remaining_entries != 0:
        raise RuntimeError(f"/etc/hosts still contains unsupported override for {fqdn}")
    return f"Removed {removed_entries} /etc/hosts override entrie(s) for {fqdn}"


def _extract_public_edge_classification(report: str) -> str | None:
    """Return the rendered public-edge classification when present."""
    for line in report.splitlines():
        if line.startswith("CLASSIFICATION="):
            _, _, classification = line.partition("=")
            return classification
    return None


async def _assert_public_host_ready_for_external_proof() -> str:
    """Require the live public host to be ready before aggregate suites run."""
    from prodbox.cli.command_adt import host_public_edge_command
    from prodbox.cli.dag_builders import (
        _optional_json_doc_from_capture,
        _optional_string_result,
        _parse_json_mapping,
        _render_public_edge_report,
        _require_settings,
        _require_string_result,
        _require_successful_kubectl_stdout,
        command_to_dag,
    )
    from prodbox.cli.types import Failure, Success

    match host_public_edge_command():
        case Failure(error):
            raise RuntimeError(f"failed to construct public-edge diagnostic: {error}")
        case Success(command):
            dag_result = command_to_dag(command)

    match dag_result:
        case Failure(error):
            raise RuntimeError(f"failed to build public-edge diagnostic DAG: {error}")
        case Success(dag):
            dag_summary, prereq_results = await _execute_dag_with_values_async(dag)

    if dag_summary.exit_code != 0:
        execution_report = dag_summary.execution_report.strip()
        details = execution_report if execution_report != "" else dag_summary.message
        raise RuntimeError(f"public-edge diagnostic failed:\n{details}")

    report = _render_public_edge_report(
        settings=_require_settings(prereq_results),
        public_ip=_require_string_result(prereq_results, "host_public_edge_public_ip"),
        route53_record_ip=_optional_string_result(
            prereq_results, "host_public_edge_route53_record"
        ),
        ingress_classes_doc=_parse_json_mapping(
            _require_successful_kubectl_stdout(prereq_results, "host_public_edge_ingress_classes")
        ),
        traefik_service_doc=_parse_json_mapping(
            _require_successful_kubectl_stdout(prereq_results, "host_public_edge_traefik_service")
        ),
        ingress_nginx_services_doc=_parse_json_mapping(
            _require_successful_kubectl_stdout(
                prereq_results, "host_public_edge_ingress_nginx_services"
            )
        ),
        vscode_ingress_doc=_optional_json_doc_from_capture(
            prereq_results, "host_public_edge_vscode_ingress"
        ),
        vscode_certificate_doc=_optional_json_doc_from_capture(
            prereq_results, "host_public_edge_vscode_certificate"
        ),
    )
    classification = _extract_public_edge_classification(report)
    if classification != "ready-for-external-proof":
        raise RuntimeError(
            "public-host readiness gate failed for aggregate suite; "
            "expected CLASSIFICATION=ready-for-external-proof.\n"
            f"{report}"
        )
    return report


def _assert_no_fixture_owned_aws_resources_remain() -> str:
    """Fail aggregate suites when fixture-owned AWS resources remain after teardown."""
    from prodbox.lib.aws_fixture_audit import assert_no_fixture_owned_resources_remain

    assert_no_fixture_owned_resources_remain()
    return "No fixture-owned AWS resources remain."


async def _wait_for_public_host_ready_for_external_proof() -> str:
    """Poll until the public host returns to ready-for-external-proof after aggregate suites."""
    deadline = asyncio.get_running_loop().time() + PUBLIC_HOST_POSTFLIGHT_TIMEOUT_SECONDS
    last_error: RuntimeError | None = None
    while True:
        try:
            return await _assert_public_host_ready_for_external_proof()
        except RuntimeError as error:
            last_error = error
        if asyncio.get_running_loop().time() >= deadline:
            message = (
                "public-host readiness gate failed after aggregate-suite restore; "
                "expected CLASSIFICATION=ready-for-external-proof."
            )
            if last_error is not None:
                raise RuntimeError(f"{message}\n{last_error}") from last_error
            raise RuntimeError(message)
        await asyncio.sleep(PUBLIC_HOST_POSTFLIGHT_RETRY_INTERVAL_SECONDS)
