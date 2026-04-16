"""Unit tests for explicit prodbox test suite orchestration."""

from __future__ import annotations

import sys
from types import SimpleNamespace
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
    AWS_EKS_TEST_PREREQUISITES,
    AWS_HA_RKE2_TEST_PREREQUISITES,
    AWS_IAM_TEST_PREREQUISITES,
    INTEGRATION_ALL_TEST_SUITE,
    INTEGRATION_AWS_EKS_TEST_SUITE,
    INTEGRATION_AWS_IAM_TEST_SUITE,
    INTEGRATION_CHARTS_VSCODE_TEST_SUITE,
    INTEGRATION_DNS_AWS_TEST_SUITE,
    INTEGRATION_ENV_TEST_SUITE,
    INTEGRATION_HA_RKE2_AWS_TEST_SUITE,
    INTEGRATION_PUBLIC_DNS_TEST_SUITE,
    INTEGRATION_PULUMI_TEST_SUITE,
    INTEGRATION_RUNBOOK_EFFECT_ID,
    PHASE_ONE_HEADER_EFFECT_ID,
    POST_PYTEST_AWS_DESTROY_EFFECT_ID,
    POST_PYTEST_AWS_EKS_DESTROY_EFFECT_ID,
    POST_PYTEST_AWS_SETUP_EFFECT_ID,
    POST_PYTEST_GATEWAY_DELETE_EFFECT_ID,
    POST_PYTEST_GATEWAY_DEPLOY_EFFECT_ID,
    POST_PYTEST_PUBLIC_EDGE_EFFECT_ID,
    POST_PYTEST_PULUMI_REFRESH_EFFECT_ID,
    POST_PYTEST_PULUMI_UP_EFFECT_ID,
    POST_PYTEST_RESTORE_HEADER_EFFECT_ID,
    POST_PYTEST_RKE2_INSTALL_EFFECT_ID,
    POST_PYTEST_VSCODE_DELETE_EFFECT_ID,
    POST_PYTEST_VSCODE_DEPLOY_EFFECT_ID,
    PRE_PYTEST_AWS_SETUP_EFFECT_ID,
    PRE_PYTEST_GATEWAY_DELETE_EFFECT_ID,
    PRE_PYTEST_GATEWAY_DEPLOY_EFFECT_ID,
    PRE_PYTEST_PULUMI_REFRESH_EFFECT_ID,
    PRE_PYTEST_PULUMI_UP_EFFECT_ID,
    PRE_PYTEST_RESTORE_HEADER_EFFECT_ID,
    PRE_PYTEST_VSCODE_DELETE_EFFECT_ID,
    PRE_PYTEST_VSCODE_DEPLOY_EFFECT_ID,
    PUBLIC_EDGE_CONNECT_HOST_ENV_VAR,
    PUBLIC_HOST_HOSTS_OVERRIDE_EFFECT_ID,
    PUBLIC_HOST_READINESS_EFFECT_ID,
    PULUMI_TEST_PREREQUISITES,
    TEST_TIMEOUT_SECONDS,
    UNIT_TEST_SUITE,
    CoverageSettings,
    _build_test_dag,
    _coverage_settings,
    _ensure_operational_aws_identity_for_supported_runtime,
    _exit_for_suite,
    _extract_public_edge_classification,
    _pytest_args,
    _remove_fqdn_from_hosts_text,
    _restore_operational_aws_identity_from_admin_harness,
    _run_suite,
)
from prodbox.cli.types import Success
from prodbox.settings import LanAddressing


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
    assert phase_two_effect_ids[:13] == [
        "pytest_integration_runbook_header",
        INTEGRATION_RUNBOOK_EFFECT_ID,
        PRE_PYTEST_RESTORE_HEADER_EFFECT_ID,
        PUBLIC_HOST_HOSTS_OVERRIDE_EFFECT_ID,
        PRE_PYTEST_AWS_SETUP_EFFECT_ID,
        PRE_PYTEST_PULUMI_REFRESH_EFFECT_ID,
        PRE_PYTEST_PULUMI_UP_EFFECT_ID,
        PRE_PYTEST_VSCODE_DELETE_EFFECT_ID,
        PRE_PYTEST_GATEWAY_DELETE_EFFECT_ID,
        PRE_PYTEST_GATEWAY_DEPLOY_EFFECT_ID,
        PRE_PYTEST_VSCODE_DEPLOY_EFFECT_ID,
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
        "install",
    ]
    aws_bootstrap = cast(
        Custom[object],
        next(
            effect
            for effect in phase_two_effect.effects
            if effect.effect_id == PRE_PYTEST_AWS_SETUP_EFFECT_ID
        ),
    )
    assert callable(aws_bootstrap.fn)
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
        "tests/integration/test_aws_iam_lifecycle.py",
    ]
    assert phase_two_effect_ids[-12:] == [
        POST_PYTEST_RESTORE_HEADER_EFFECT_ID,
        POST_PYTEST_RKE2_INSTALL_EFFECT_ID,
        POST_PYTEST_AWS_SETUP_EFFECT_ID,
        POST_PYTEST_PULUMI_REFRESH_EFFECT_ID,
        POST_PYTEST_PULUMI_UP_EFFECT_ID,
        POST_PYTEST_VSCODE_DELETE_EFFECT_ID,
        POST_PYTEST_GATEWAY_DELETE_EFFECT_ID,
        POST_PYTEST_GATEWAY_DEPLOY_EFFECT_ID,
        POST_PYTEST_VSCODE_DEPLOY_EFFECT_ID,
        POST_PYTEST_PUBLIC_EDGE_EFFECT_ID,
        POST_PYTEST_AWS_EKS_DESTROY_EFFECT_ID,
        POST_PYTEST_AWS_DESTROY_EFFECT_ID,
    ]
    rke2_restore = cast(
        RunSubprocess,
        next(
            effect
            for effect in phase_two_effect.effects
            if effect.effect_id == POST_PYTEST_RKE2_INSTALL_EFFECT_ID
        ),
    )
    assert rke2_restore.command == [
        sys.executable,
        "-m",
        "prodbox.cli.main",
        "rke2",
        "install",
    ]
    aws_restore = cast(
        Custom[object],
        next(
            effect
            for effect in phase_two_effect.effects
            if effect.effect_id == POST_PYTEST_AWS_SETUP_EFFECT_ID
        ),
    )
    assert callable(aws_restore.fn)
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
    vscode_delete = cast(
        RunSubprocess,
        next(
            effect
            for effect in phase_two_effect.effects
            if effect.effect_id == POST_PYTEST_VSCODE_DELETE_EFFECT_ID
        ),
    )
    assert vscode_delete.command == [
        sys.executable,
        "-m",
        "prodbox.cli.main",
        "charts",
        "delete",
        "vscode",
        "--yes",
    ]
    gateway_delete = cast(
        RunSubprocess,
        next(
            effect
            for effect in phase_two_effect.effects
            if effect.effect_id == POST_PYTEST_GATEWAY_DELETE_EFFECT_ID
        ),
    )
    assert gateway_delete.command == [
        sys.executable,
        "-m",
        "prodbox.cli.main",
        "charts",
        "delete",
        "gateway",
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
    aws_eks_destroy = cast(
        RunSubprocess,
        next(
            effect
            for effect in phase_two_effect.effects
            if effect.effect_id == POST_PYTEST_AWS_EKS_DESTROY_EFFECT_ID
        ),
    )
    assert aws_eks_destroy.command == [
        sys.executable,
        "-m",
        "prodbox.cli.main",
        "pulumi",
        "eks-destroy",
        "--yes",
    ]
    aws_destroy = cast(
        RunSubprocess,
        next(
            effect
            for effect in phase_two_effect.effects
            if effect.effect_id == POST_PYTEST_AWS_DESTROY_EFFECT_ID
        ),
    )
    assert aws_destroy.command == [
        sys.executable,
        "-m",
        "prodbox.cli.main",
        "pulumi",
        "test-destroy",
        "--yes",
    ]
    assert "supported_ubuntu_2404" in phase_two.prerequisites
    assert "tool_helm" in phase_two.prerequisites
    assert "tool_docker" in phase_two.prerequisites
    assert "tool_ctr" in phase_two.prerequisites
    assert "tool_sudo" in phase_two.prerequisites
    assert "tool_systemctl" in phase_two.prerequisites
    assert "tool_ssh" in phase_two.prerequisites
    assert "settings_object" in phase_two.prerequisites
    assert phase_two.prerequisite_failure_policy == PrerequisiteFailurePolicy.PROPAGATE
    phase_one_header = dag.get_node(PHASE_ONE_HEADER_EFFECT_ID)
    assert phase_one_header is not None
    for prereq_id in ALL_INTEGRATION_TEST_PREREQUISITES:
        prereq_node = dag.get_node(prereq_id)
        assert prereq_node is not None
        assert PHASE_ONE_HEADER_EFFECT_ID in prereq_node.prerequisites


def test_build_test_dag_injects_public_edge_connect_host_into_pytest_env() -> None:
    """Pytest subprocesses should receive the deterministic local edge IP for public-host probes."""
    with patch(
        "prodbox.settings.discover_lan_addressing",
        return_value=LanAddressing(
            interface_name="enp0s0",
            interface_ipv4="192.168.2.79",
            network_cidr="192.168.2.0/24",
            metallb_pool="192.168.2.240-192.168.2.250",
            ingress_lb_ip="192.168.2.240",
        ),
    ):
        dag = _build_test_dag(
            suite=INTEGRATION_CHARTS_VSCODE_TEST_SUITE,
            coverage_settings=CoverageSettings(enabled=False, fail_under=None),
        )

    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    phase_two_effect = cast(Sequence, phase_two.effect)
    pytest_effect = cast(RunSubprocess, phase_two_effect.effects[1])
    assert pytest_effect.env is not None
    assert pytest_effect.env[PUBLIC_EDGE_CONNECT_HOST_ENV_VAR] == "192.168.2.240"


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
    """AWS DNS suite should gate on AWS prerequisites but not run rke2 install."""
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


def test_build_test_dag_uses_aws_iam_gate_without_runbook() -> None:
    """AWS IAM suite should gate on AWS + Dhall + settings without the cluster runbook."""
    dag = _build_test_dag(
        suite=INTEGRATION_AWS_IAM_TEST_SUITE,
        coverage_settings=CoverageSettings(enabled=False, fail_under=None),
    )
    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    assert phase_two.prerequisites == AWS_IAM_TEST_PREREQUISITES
    phase_two_effect = cast(Sequence, phase_two.effect)
    assert [effect.effect_id for effect in phase_two_effect.effects] == [
        "pytest_phase_two_header",
        "pytest_run",
    ]


def test_build_test_dag_uses_cluster_and_pulumi_gate_for_aws_eks_suite() -> None:
    """AWS EKS suite should require the Pulumi-backed cluster runbook."""
    dag = _build_test_dag(
        suite=INTEGRATION_AWS_EKS_TEST_SUITE,
        coverage_settings=CoverageSettings(enabled=False, fail_under=None),
    )
    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    assert phase_two.prerequisites == AWS_EKS_TEST_PREREQUISITES
    phase_two_effect = cast(Sequence, phase_two.effect)
    assert [effect.effect_id for effect in phase_two_effect.effects[:3]] == [
        "pytest_integration_runbook_header",
        INTEGRATION_RUNBOOK_EFFECT_ID,
        "pytest_phase_two_header",
    ]


@pytest.mark.parametrize(
    "suite",
    [
        INTEGRATION_CHARTS_VSCODE_TEST_SUITE,
        INTEGRATION_PUBLIC_DNS_TEST_SUITE,
    ],
)
def test_build_test_dag_keeps_public_host_suite_off_cluster_runbook(suite: object) -> None:
    """External public-host suites should not require cluster gates or rke2 install."""
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


def test_build_test_dag_uses_cluster_aws_ssh_gate_for_ha_rke2_suite() -> None:
    """HA RKE2 AWS suite should use the SSH-capable AWS gate and runbook."""
    dag = _build_test_dag(
        suite=INTEGRATION_HA_RKE2_AWS_TEST_SUITE,
        coverage_settings=CoverageSettings(enabled=False, fail_under=None),
    )
    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    assert phase_two.prerequisites == AWS_HA_RKE2_TEST_PREREQUISITES
    phase_two_effect = cast(Sequence, phase_two.effect)
    assert [effect.effect_id for effect in phase_two_effect.effects[:3]] == [
        "pytest_integration_runbook_header",
        INTEGRATION_RUNBOOK_EFFECT_ID,
        "pytest_phase_two_header",
    ]


def test_build_test_dag_uses_cluster_and_pulumi_gate_for_pulumi_suite() -> None:
    """Pulumi suite should require cluster + AWS + Pulumi prerequisites and runbook."""
    dag = _build_test_dag(
        suite=INTEGRATION_PULUMI_TEST_SUITE,
        coverage_settings=CoverageSettings(enabled=False, fail_under=None),
    )
    phase_two = dag.get_node("pytest_phase_two")
    assert phase_two is not None
    assert phase_two.prerequisites == PULUMI_TEST_PREREQUISITES


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
    assert [effect.effect_id for effect in phase_two_effect.effects][-12:] == [
        POST_PYTEST_RESTORE_HEADER_EFFECT_ID,
        POST_PYTEST_RKE2_INSTALL_EFFECT_ID,
        POST_PYTEST_AWS_SETUP_EFFECT_ID,
        POST_PYTEST_PULUMI_REFRESH_EFFECT_ID,
        POST_PYTEST_PULUMI_UP_EFFECT_ID,
        POST_PYTEST_VSCODE_DELETE_EFFECT_ID,
        POST_PYTEST_GATEWAY_DELETE_EFFECT_ID,
        POST_PYTEST_GATEWAY_DEPLOY_EFFECT_ID,
        POST_PYTEST_VSCODE_DEPLOY_EFFECT_ID,
        POST_PYTEST_PUBLIC_EDGE_EFFECT_ID,
        POST_PYTEST_AWS_EKS_DESTROY_EFFECT_ID,
        POST_PYTEST_AWS_DESTROY_EFFECT_ID,
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
        "tests/integration/test_dns_route53_aws.py"
    ) < INTEGRATION_ALL_TEST_SUITE.pytest_args.index("tests/integration/test_aws_eks.py")
    assert INTEGRATION_ALL_TEST_SUITE.pytest_args.index(
        "tests/integration/test_aws_eks.py"
    ) < INTEGRATION_ALL_TEST_SUITE.pytest_args.index("tests/integration/test_pulumi_real.py")
    assert INTEGRATION_ALL_TEST_SUITE.pytest_args.index(
        "tests/integration/test_pulumi_real.py"
    ) < INTEGRATION_ALL_TEST_SUITE.pytest_args.index("tests/integration/test_aws_iam_lifecycle.py")
    assert INTEGRATION_ALL_TEST_SUITE.pytest_args.index(
        "tests/integration/test_charts_platform.py"
    ) < INTEGRATION_ALL_TEST_SUITE.pytest_args.index("tests/integration/test_charts_storage.py")
    assert (
        INTEGRATION_ALL_TEST_SUITE.pytest_args[-1] == "tests/integration/test_aws_iam_lifecycle.py"
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
        "tests/integration/test_aws_iam_lifecycle.py",
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


def test_restore_operational_aws_identity_from_admin_harness_refreshes_cached_settings() -> None:
    """Aggregate AWS restore should clear the settings cache before and after rewriting creds."""
    config = {
        "aws_admin": {
            "access_key_id": "ADMINKEY",
            "secret_access_key": "admin-secret",
            "session_token": "admin-token",
            "region": "us-east-1",
        }
    }
    fake_result = SimpleNamespace(user_name="prodbox", policy_tier="full")

    with (
        patch("prodbox.settings.clear_settings_cache") as clear_cache,
        patch("prodbox.lib.aws_admin._load_current_config_mapping", return_value=config),
        patch(
            "prodbox.lib.aws_admin.aws_setup_command",
            return_value=Success(
                SimpleNamespace(
                    admin_access_key_id="ADMINKEY",
                    admin_secret_access_key="admin-secret",
                    admin_session_token="admin-token",
                    admin_region="us-east-1",
                    tier="full",
                )
            ),
        ) as setup_command,
        patch("prodbox.lib.aws_admin.run_aws_setup", return_value=fake_result),
        patch("prodbox.settings.Settings.from_config_json", return_value=SimpleNamespace()),
    ):
        result = _restore_operational_aws_identity_from_admin_harness()

    assert clear_cache.call_count == 2
    assert setup_command.call_args.kwargs["tier"] == "full"
    assert "Restored operational AWS IAM user prodbox" in result


def test_exit_for_suite_repairs_loadable_settings_when_required() -> None:
    """Suites gated by validated settings should pre-repair operational credentials."""
    with (
        patch(
            "prodbox.cli.test_cmd.ensure_operational_aws_credentials_from_admin_harness",
            return_value="restored",
        ) as ensure,
        patch("prodbox.cli.test_cmd._repair_pulumi_stack_after_operational_aws_rotation") as repair,
        patch("prodbox.cli.test_cmd._run_suite", return_value=0),
        patch("prodbox.cli.test_cmd.sys.exit", side_effect=SystemExit(0)),
        pytest.raises(SystemExit),
    ):
        _exit_for_suite(suite=ALL_TEST_SUITE, coverage=False, cov_fail_under=None)

    ensure.assert_called_once_with()
    repair.assert_not_called()


def test_exit_for_suite_skips_settings_repair_for_unit_only_suite() -> None:
    """Suites without validated-settings prerequisites should not mutate AWS credentials."""
    with (
        patch(
            "prodbox.cli.test_cmd.ensure_operational_aws_credentials_from_admin_harness"
        ) as ensure,
        patch("prodbox.cli.test_cmd._repair_pulumi_stack_after_operational_aws_rotation") as repair,
        patch("prodbox.cli.test_cmd._run_suite", return_value=0),
        patch("prodbox.cli.test_cmd.sys.exit", side_effect=SystemExit(0)),
        pytest.raises(SystemExit),
    ):
        _exit_for_suite(suite=UNIT_TEST_SUITE, coverage=False, cov_fail_under=None)

    ensure.assert_not_called()
    repair.assert_not_called()


def test_ensure_operational_aws_identity_for_supported_runtime_repairs_pulumi_when_current_creds_work() -> (
    None
):
    """Supported-runtime repair should still advance Pulumi state when STS already succeeds."""
    with (
        patch(
            "prodbox.cli.test_cmd._current_operational_aws_credentials_are_valid",
            return_value=True,
        ),
        patch(
            "prodbox.cli.test_cmd._supported_runtime_operational_policy_is_current",
            return_value=True,
        ),
        patch(
            "prodbox.cli.test_cmd._restore_operational_aws_identity_from_admin_harness"
        ) as restore,
        patch(
            "prodbox.cli.test_cmd._repair_pulumi_stack_after_operational_aws_rotation",
            return_value="repaired",
        ) as repair,
    ):
        result = _ensure_operational_aws_identity_for_supported_runtime()

    restore.assert_not_called()
    repair.assert_called_once_with()
    assert result == "Operational AWS credentials and IAM policy already valid; repaired"


def test_ensure_operational_aws_identity_for_supported_runtime_repairs_when_current_creds_fail() -> (
    None
):
    """Supported-runtime repair should restore AWS identity and Pulumi state when STS fails."""
    with (
        patch(
            "prodbox.cli.test_cmd._current_operational_aws_credentials_are_valid",
            return_value=False,
        ),
        patch(
            "prodbox.cli.test_cmd._supported_runtime_operational_policy_is_current"
        ) as policy_check,
        patch(
            "prodbox.cli.test_cmd._restore_operational_aws_identity_from_admin_harness",
            return_value="restored",
        ) as restore,
        patch(
            "prodbox.cli.test_cmd._repair_pulumi_stack_after_operational_aws_rotation",
            return_value="repaired",
        ) as repair,
    ):
        result = _ensure_operational_aws_identity_for_supported_runtime()

    policy_check.assert_not_called()
    restore.assert_called_once_with()
    repair.assert_called_once_with()
    assert result == "restored; repaired"


def test_ensure_operational_aws_identity_for_supported_runtime_repairs_when_policy_is_stale() -> (
    None
):
    """Supported-runtime repair should refresh the IAM user when the inline policy is stale."""
    with (
        patch(
            "prodbox.cli.test_cmd._current_operational_aws_credentials_are_valid",
            return_value=True,
        ),
        patch(
            "prodbox.cli.test_cmd._supported_runtime_operational_policy_is_current",
            return_value=False,
        ),
        patch(
            "prodbox.cli.test_cmd._restore_operational_aws_identity_from_admin_harness",
            return_value="restored",
        ) as restore,
        patch(
            "prodbox.cli.test_cmd._repair_pulumi_stack_after_operational_aws_rotation",
            return_value="repaired",
        ) as repair,
    ):
        result = _ensure_operational_aws_identity_for_supported_runtime()

    restore.assert_called_once_with()
    repair.assert_called_once_with()
    assert result == "restored; repaired"


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

    async def fail_settings_load(*_args: object, **_kwargs: object) -> tuple[object, bool]:
        return interpreter._create_error_summary("Failed to load settings: forced"), False

    with (
        patch.object(
            interpreter,
            "_interpret_load_settings",
            side_effect=fail_settings_load,
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


def test_remove_fqdn_from_hosts_text_removes_only_target_host() -> None:
    """Hosts cleanup should remove only the unsupported public-host override token."""
    original = "127.0.0.1 localhost\n192.168.2.240 vscode.resolvefintech.com other.local  # local override\n"

    updated, removed = _remove_fqdn_from_hosts_text(
        hosts_text=original,
        fqdn="vscode.resolvefintech.com",
    )

    assert removed == 1
    assert "vscode.resolvefintech.com" not in updated
    assert "other.local" in updated
    assert "127.0.0.1 localhost" in updated


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
