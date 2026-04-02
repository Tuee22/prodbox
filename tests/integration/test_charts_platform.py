"""Integration tests for the chart platform deploy/delete lifecycle.

charts-platform suite – verifies end-to-end deploy and delete of the full
three-chart vscode stack (keycloak-postgres → keycloak → vscode), singleton
enforcement, and same-namespace-only isolation.

Tests in this suite deploy to the live cluster and clean up after themselves.
"""

from __future__ import annotations

import asyncio
import shutil
import subprocess
from collections.abc import AsyncIterator
from pathlib import Path
from typing import NamedTuple

import pytest
import pytest_asyncio

from prodbox.cli.types import Success
from prodbox.lib.chart_platform import (
    CHART_DATA_ROOT,
    ChartDeploymentPlan,
    build_chart_delete_plan,
    build_chart_deployment_plan,
    delete_chart_plan,
    deploy_chart_plan,
)

from .conftest import abort_test_session_on_teardown_failure, resolve_kubeconfig
from .helpers import run_kubectl_capture_via_dag

pytestmark = [pytest.mark.integration, pytest.mark.timeout(1200)]

# ---------------------------------------------------------------------------
# Settings – full vscode stack requires all chart settings
# ---------------------------------------------------------------------------

_VSCODE_SETTINGS: dict[str, str] = {
    "keycloak_postgres_password": "integrationtestpass",
    "keycloak_admin_password": "integrationadminpass",
    "keycloak_nginx_client_secret": "integrationnginxsecret",
    "vscode_fqdn": "vscode.example.internal",
}

_ROOT_CHART = "vscode"
_EXPECTED_RELEASES = ("keycloak-postgres", "keycloak", "vscode")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


async def _kubectl_resource_exists(
    resource_type: str,
    name: str,
    *,
    namespace: str | None = None,
    kubeconfig: Path,
) -> bool:
    """Return True if a kubectl-addressable resource exists (--ignore-not-found)."""
    extra = ("-n", namespace) if namespace else ()
    rc, stdout, _ = await run_kubectl_capture_via_dag(
        "get",
        resource_type,
        name,
        *extra,
        "--ignore-not-found=true",
        "-o",
        "name",
        kubeconfig=kubeconfig,
        timeout=30.0,
    )
    return rc == 0 and bool(stdout.strip())


async def _namespace_exists(namespace: str, *, kubeconfig: Path) -> bool:
    return await _kubectl_resource_exists("namespace", namespace, kubeconfig=kubeconfig)


async def _helm_release_exists(release_name: str, *, namespace: str, kubeconfig: Path) -> bool:
    """Return True if a Helm release exists in the given namespace."""
    rc, stdout, _ = await run_kubectl_capture_via_dag(
        "get",
        "secret",
        "-l",
        f"name={release_name},owner=helm",
        "-n",
        namespace,
        "--ignore-not-found=true",
        "-o",
        "name",
        kubeconfig=kubeconfig,
        timeout=30.0,
    )
    return rc == 0 and bool(stdout.strip())


async def _require_tools_and_cluster(kubeconfig: Path) -> None:
    """Fail hard if kubectl/helm are absent or cluster is unreachable."""
    for tool in ("kubectl", "helm"):
        if shutil.which(tool) is None:
            raise AssertionError(f"{tool} not installed (required for charts-platform suite)")
    if not kubeconfig.exists():
        raise AssertionError(f"kubeconfig not found: {kubeconfig}")
    rc, _, stderr = await run_kubectl_capture_via_dag(
        "cluster-info",
        kubeconfig=kubeconfig,
        timeout=30.0,
    )
    if rc != 0:
        raise AssertionError(f"kubectl cluster-info failed: {stderr}")


async def _best_effort_cleanup(*, kubeconfig: Path) -> None:
    """Idempotent pre/post-test cleanup of all vscode stack resources."""
    delete_plan_result = build_chart_delete_plan(_ROOT_CHART)
    if not isinstance(delete_plan_result, Success):
        return

    delete_plan = delete_plan_result.value
    for release in delete_plan.releases:
        proc = await asyncio.create_subprocess_exec(
            "helm",
            "uninstall",
            release.release_name,
            "--namespace",
            release.namespace,
            "--wait",
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()

    for release in delete_plan.releases:
        for binding in release.storage_bindings:
            await run_kubectl_capture_via_dag(
                "delete",
                "pvc",
                binding.persistent_volume_claim_name,
                "--namespace",
                delete_plan.namespace,
                "--ignore-not-found=true",
                "--wait=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )
            await run_kubectl_capture_via_dag(
                "delete",
                "pv",
                binding.persistent_volume_name,
                "--ignore-not-found=true",
                "--wait=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )

    await run_kubectl_capture_via_dag(
        "delete",
        "namespace",
        delete_plan.namespace,
        "--ignore-not-found=true",
        "--wait=true",
        kubeconfig=kubeconfig,
        timeout=120.0,
    )


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------


class PlatformTestContext(NamedTuple):
    """Resolved context for one charts-platform integration test."""

    kubeconfig: Path
    deploy_plan: ChartDeploymentPlan
    delete_plan: ChartDeploymentPlan


@pytest_asyncio.fixture
async def platform_context() -> AsyncIterator[PlatformTestContext]:
    """Deploy the full vscode stack, yield context, then clean up."""
    kubeconfig = resolve_kubeconfig()
    await _require_tools_and_cluster(kubeconfig)

    deploy_plan_result = build_chart_deployment_plan(_ROOT_CHART, _VSCODE_SETTINGS)
    delete_plan_result = build_chart_delete_plan(_ROOT_CHART)
    assert isinstance(
        deploy_plan_result, Success
    ), f"deploy plan build failed: {deploy_plan_result}"
    assert isinstance(
        delete_plan_result, Success
    ), f"delete plan build failed: {delete_plan_result}"

    deploy_plan = deploy_plan_result.value
    delete_plan = delete_plan_result.value

    await _best_effort_cleanup(kubeconfig=kubeconfig)

    try:
        await deploy_chart_plan(deploy_plan)
    except Exception as error:
        await _best_effort_cleanup(kubeconfig=kubeconfig)
        raise AssertionError(f"deploy_chart_plan failed during fixture setup: {error}") from error

    ctx = PlatformTestContext(
        kubeconfig=kubeconfig,
        deploy_plan=deploy_plan,
        delete_plan=delete_plan,
    )
    yield ctx

    try:
        await _best_effort_cleanup(kubeconfig=kubeconfig)
        data_root = CHART_DATA_ROOT / _ROOT_CHART
        if data_root.exists():
            subprocess.run(["sudo", "rm", "-rf", str(data_root)], check=False)
    except Exception as error:
        abort_test_session_on_teardown_failure(target=_ROOT_CHART, error=error)


# ---------------------------------------------------------------------------
# Tests: all three releases deploy into the vscode namespace
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_all_three_releases_deploy_into_vscode_namespace(
    platform_context: PlatformTestContext,
) -> None:
    """All three chart releases must exist as Helm releases in the vscode namespace."""
    for release_name in _EXPECTED_RELEASES:
        exists = await _helm_release_exists(
            release_name,
            namespace=platform_context.deploy_plan.namespace,
            kubeconfig=platform_context.kubeconfig,
        )
        assert exists, (
            f"Helm release {release_name!r} not found in namespace "
            f"{platform_context.deploy_plan.namespace!r} after deploy"
        )


@pytest.mark.asyncio
async def test_namespace_equals_root_chart_after_deploy(
    platform_context: PlatformTestContext,
) -> None:
    """The chart namespace must equal the root chart name."""
    assert platform_context.deploy_plan.namespace == _ROOT_CHART
    exists = await _namespace_exists(
        platform_context.deploy_plan.namespace,
        kubeconfig=platform_context.kubeconfig,
    )
    assert exists, f"Namespace {platform_context.deploy_plan.namespace!r} not found after deploy"


@pytest.mark.asyncio
async def test_all_releases_share_root_namespace(
    platform_context: PlatformTestContext,
) -> None:
    """Every release in the deploy plan must share the root chart namespace."""
    for release in platform_context.deploy_plan.releases:
        assert release.namespace == platform_context.deploy_plan.namespace, (
            f"Release {release.release_name!r} has namespace {release.namespace!r}, "
            f"expected {platform_context.deploy_plan.namespace!r}"
        )


@pytest.mark.asyncio
async def test_deploy_plan_contains_exactly_three_releases(
    platform_context: PlatformTestContext,
) -> None:
    """The vscode deploy plan must contain exactly the three expected releases."""
    release_names = tuple(r.release_name for r in platform_context.deploy_plan.releases)
    assert set(release_names) == set(
        _EXPECTED_RELEASES
    ), f"Unexpected releases in plan: {release_names!r}, expected {_EXPECTED_RELEASES!r}"


@pytest.mark.asyncio
async def test_deploy_order_is_keycloak_postgres_first(
    platform_context: PlatformTestContext,
) -> None:
    """keycloak-postgres must be deployed before keycloak, which before vscode."""
    names = [r.release_name for r in platform_context.deploy_plan.releases]
    pg_idx = names.index("keycloak-postgres")
    kc_idx = names.index("keycloak")
    vs_idx = names.index("vscode")
    assert pg_idx < kc_idx < vs_idx, (
        f"Unexpected deploy order: keycloak-postgres={pg_idx}, "
        f"keycloak={kc_idx}, vscode={vs_idx}"
    )


# ---------------------------------------------------------------------------
# Tests: singleton enforcement
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_second_deploy_fails_with_singleton_violation(
    platform_context: PlatformTestContext,  # noqa: ARG001
) -> None:
    """A second deploy attempt must raise RuntimeError (singleton violation)."""
    redeploy_plan_result = build_chart_deployment_plan(_ROOT_CHART, _VSCODE_SETTINGS)
    assert isinstance(redeploy_plan_result, Success)
    redeploy_plan = redeploy_plan_result.value

    try:
        await deploy_chart_plan(redeploy_plan)
        raise AssertionError(
            "Expected deploy_chart_plan to raise RuntimeError for singleton violation "
            "but it returned without error"
        )
    except RuntimeError as error:
        assert (
            "singleton violation" in str(error).lower() or "already installed" in str(error).lower()
        ), f"Expected singleton violation error, got: {error}"


# ---------------------------------------------------------------------------
# Tests: delete removes all three releases and namespace
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_delete_removes_all_releases(
    platform_context: PlatformTestContext,
) -> None:
    """All three Helm releases must be gone after delete_chart_plan."""
    await delete_chart_plan(platform_context.delete_plan)
    for release_name in _EXPECTED_RELEASES:
        exists = await _helm_release_exists(
            release_name,
            namespace=platform_context.deploy_plan.namespace,
            kubeconfig=platform_context.kubeconfig,
        )
        assert not exists, f"Helm release {release_name!r} still present after delete"


@pytest.mark.asyncio
async def test_delete_removes_namespace(
    platform_context: PlatformTestContext,
) -> None:
    """The chart namespace must be removed by delete_chart_plan."""
    await delete_chart_plan(platform_context.delete_plan)
    exists = await _namespace_exists(
        platform_context.deploy_plan.namespace,
        kubeconfig=platform_context.kubeconfig,
    )
    assert (
        not exists
    ), f"Namespace {platform_context.deploy_plan.namespace!r} still present after delete"
