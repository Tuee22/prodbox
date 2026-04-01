"""Integration tests for chart platform deterministic retained storage.

charts-storage suite – verifies the .data/ host-path contract across a
full deploy → delete → redeploy cycle using the keycloak-postgres chart,
which is the only root chart that does not require an external FQDN.

Test sequence:
  1. Deploy keycloak-postgres → verify PV/PVC exist with canonical names
  2. Delete stack → verify PV/PVC gone, .data host dir still present
  3. Redeploy → verify same PV/PVC names rebound (determinism guarantee)
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
    ChartStorageBinding,
    build_chart_delete_plan,
    build_chart_deployment_plan,
    delete_chart_plan,
    deploy_chart_plan,
)

from .conftest import abort_test_session_on_teardown_failure, resolve_kubeconfig
from .helpers import run_kubectl_capture_via_dag

pytestmark = [pytest.mark.integration, pytest.mark.timeout(600)]

# ---------------------------------------------------------------------------
# Minimal settings for keycloak-postgres (no public FQDN required)
# ---------------------------------------------------------------------------

_KP_SETTINGS: dict[str, str] = {
    "keycloak_postgres_password": "integrationtestpass",
    "keycloak_admin_password": "integrationadminpass",
    "keycloak_oauth2_client_secret": "integrationoauthsecret",
    "google_oauth_client_id": "integrationgoogleclientid",
    "google_oauth_client_secret": "integrationgoogleclientsecret",
    "vscode_fqdn": "vscode.example.internal",
    "vscode_oauth2_proxy_cookie_secret": "integrationcookiesecret1",
}

_ROOT_CHART = "keycloak-postgres"


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
    """Return True if a kubectl-addressable resource currently exists."""
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
    # --ignore-not-found exits 0 regardless; non-empty stdout means found.
    return rc == 0 and bool(stdout.strip())


async def _pv_exists(pv_name: str, *, kubeconfig: Path) -> bool:
    return await _kubectl_resource_exists("pv", pv_name, kubeconfig=kubeconfig)


async def _pvc_exists(pvc_name: str, *, namespace: str, kubeconfig: Path) -> bool:
    return await _kubectl_resource_exists(
        "pvc", pvc_name, namespace=namespace, kubeconfig=kubeconfig
    )


async def _namespace_exists(namespace: str, *, kubeconfig: Path) -> bool:
    return await _kubectl_resource_exists("namespace", namespace, kubeconfig=kubeconfig)


def _all_storage_bindings(plan: ChartDeploymentPlan) -> tuple[ChartStorageBinding, ...]:
    return tuple(b for release in plan.releases for b in release.storage_bindings)


async def _require_tools_and_cluster(kubeconfig: Path) -> None:
    """Fail hard if kubectl/helm are absent or cluster is unreachable."""
    for tool in ("kubectl", "helm"):
        if shutil.which(tool) is None:
            raise AssertionError(f"{tool} not installed (required for charts-storage suite)")
    if not kubeconfig.exists():
        raise AssertionError(f"kubeconfig not found: {kubeconfig}")
    rc, _, stderr = await run_kubectl_capture_via_dag(
        "cluster-info",
        kubeconfig=kubeconfig,
        timeout=30.0,
    )
    if rc != 0:
        raise AssertionError(f"kubectl cluster-info failed: {stderr}")


async def _best_effort_cleanup(
    delete_plan: ChartDeploymentPlan,
    *,
    kubeconfig: Path,
) -> None:
    """Idempotent pre- and post-test cleanup; errors are suppressed."""
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
    for binding in _all_storage_bindings(delete_plan):
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


class StorageTestContext(NamedTuple):
    """Resolved context for one charts-storage integration test instance."""

    kubeconfig: Path
    deploy_plan: ChartDeploymentPlan
    delete_plan: ChartDeploymentPlan
    bindings: tuple[ChartStorageBinding, ...]


@pytest_asyncio.fixture
async def storage_context() -> AsyncIterator[StorageTestContext]:
    """Deploy keycloak-postgres, yield context, then clean up."""
    kubeconfig = resolve_kubeconfig()
    await _require_tools_and_cluster(kubeconfig)

    deploy_plan_result = build_chart_deployment_plan(_ROOT_CHART, _KP_SETTINGS)
    delete_plan_result = build_chart_delete_plan(_ROOT_CHART)
    assert isinstance(
        deploy_plan_result, Success
    ), f"deploy plan build failed: {deploy_plan_result}"
    assert isinstance(
        delete_plan_result, Success
    ), f"delete plan build failed: {delete_plan_result}"

    deploy_plan = deploy_plan_result.value
    delete_plan = delete_plan_result.value
    bindings = _all_storage_bindings(deploy_plan)

    # Pre-test cleanup ensures a clean slate regardless of prior runs.
    await _best_effort_cleanup(delete_plan, kubeconfig=kubeconfig)

    try:
        await deploy_chart_plan(deploy_plan)
    except Exception as error:
        await _best_effort_cleanup(delete_plan, kubeconfig=kubeconfig)
        raise AssertionError(f"deploy_chart_plan failed during fixture setup: {error}") from error

    ctx = StorageTestContext(
        kubeconfig=kubeconfig,
        deploy_plan=deploy_plan,
        delete_plan=delete_plan,
        bindings=bindings,
    )
    yield ctx

    try:
        await _best_effort_cleanup(delete_plan, kubeconfig=kubeconfig)
        data_root = CHART_DATA_ROOT / _ROOT_CHART
        if data_root.exists():
            subprocess.run(["sudo", "rm", "-rf", str(data_root)], check=False)
    except Exception as error:
        abort_test_session_on_teardown_failure(target=_ROOT_CHART, error=error)


# ---------------------------------------------------------------------------
# Tests: PV/PVC exist after deploy
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_storage_bindings_present_after_deploy(
    storage_context: StorageTestContext,
) -> None:
    """At least one storage binding must exist for the keycloak-postgres stack."""
    assert len(storage_context.bindings) > 0, "expected at least one storage binding"


@pytest.mark.asyncio
async def test_pv_names_are_deterministic(
    storage_context: StorageTestContext,
) -> None:
    """PV names must follow the prodbox-chart-<namespace>-<statefulset>-<ordinal> pattern."""
    for binding in storage_context.bindings:
        assert binding.persistent_volume_name.startswith(
            f"prodbox-chart-{_ROOT_CHART}-"
        ), f"unexpected PV name: {binding.persistent_volume_name}"


@pytest.mark.asyncio
async def test_host_paths_are_deterministic(
    storage_context: StorageTestContext,
) -> None:
    """Host paths must be nested under CHART_DATA_ROOT/<namespace>/."""
    for binding in storage_context.bindings:
        expected_prefix = str(CHART_DATA_ROOT / _ROOT_CHART)
        assert str(binding.host_path).startswith(
            expected_prefix
        ), f"unexpected host path: {binding.host_path}"


@pytest.mark.asyncio
async def test_pvs_exist_in_cluster_after_deploy(
    storage_context: StorageTestContext,
) -> None:
    """Each PV from the storage bindings must be present in the cluster after deploy."""
    for binding in storage_context.bindings:
        exists = await _pv_exists(
            binding.persistent_volume_name,
            kubeconfig=storage_context.kubeconfig,
        )
        assert exists, f"PV {binding.persistent_volume_name} not found after deploy"


@pytest.mark.asyncio
async def test_pvcs_exist_in_namespace_after_deploy(
    storage_context: StorageTestContext,
) -> None:
    """Each PVC from the storage bindings must be present in the chart namespace after deploy."""
    for binding in storage_context.bindings:
        exists = await _pvc_exists(
            binding.persistent_volume_claim_name,
            namespace=storage_context.deploy_plan.namespace,
            kubeconfig=storage_context.kubeconfig,
        )
        assert exists, (
            f"PVC {binding.persistent_volume_claim_name} not found in namespace "
            f"{storage_context.deploy_plan.namespace} after deploy"
        )


@pytest.mark.asyncio
async def test_host_dirs_exist_after_deploy(
    storage_context: StorageTestContext,
) -> None:
    """Each .data host directory must exist on the filesystem after deploy."""
    for binding in storage_context.bindings:
        assert (
            binding.host_path.exists()
        ), f".data host directory {binding.host_path} does not exist after deploy"


# ---------------------------------------------------------------------------
# Tests: PV/PVC removed; .data preserved after delete
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_pvs_gone_after_delete(
    storage_context: StorageTestContext,
) -> None:
    """PVs must not exist in the cluster after delete_chart_plan."""
    await delete_chart_plan(storage_context.delete_plan)
    for binding in storage_context.bindings:
        exists = await _pv_exists(
            binding.persistent_volume_name,
            kubeconfig=storage_context.kubeconfig,
        )
        assert not exists, f"PV {binding.persistent_volume_name} still present after delete"


@pytest.mark.asyncio
async def test_pvcs_gone_after_delete(
    storage_context: StorageTestContext,
) -> None:
    """PVCs must not exist in the namespace after delete_chart_plan."""
    await delete_chart_plan(storage_context.delete_plan)
    for binding in storage_context.bindings:
        exists = await _pvc_exists(
            binding.persistent_volume_claim_name,
            namespace=storage_context.deploy_plan.namespace,
            kubeconfig=storage_context.kubeconfig,
        )
        assert not exists, f"PVC {binding.persistent_volume_claim_name} still present after delete"


@pytest.mark.asyncio
async def test_namespace_gone_after_delete(
    storage_context: StorageTestContext,
) -> None:
    """The chart namespace must be removed by delete_chart_plan."""
    await delete_chart_plan(storage_context.delete_plan)
    exists = await _namespace_exists(
        storage_context.deploy_plan.namespace,
        kubeconfig=storage_context.kubeconfig,
    )
    assert (
        not exists
    ), f"namespace {storage_context.deploy_plan.namespace} still present after delete"


@pytest.mark.asyncio
async def test_host_dirs_preserved_after_delete(
    storage_context: StorageTestContext,
) -> None:
    """.data host directories must NOT be removed by delete_chart_plan."""
    await delete_chart_plan(storage_context.delete_plan)
    for binding in storage_context.bindings:
        assert binding.host_path.exists(), (
            f".data host directory {binding.host_path} was removed by delete_chart_plan "
            "(delete must preserve host storage)"
        )


# ---------------------------------------------------------------------------
# Tests: same PV/PVC names rebound on redeploy
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_same_pv_names_after_redeploy(
    storage_context: StorageTestContext,
) -> None:
    """PV names must be identical after a delete → redeploy cycle."""
    original_pv_names = {b.persistent_volume_name for b in storage_context.bindings}

    await delete_chart_plan(storage_context.delete_plan)

    redeploy_result = build_chart_deployment_plan(_ROOT_CHART, _KP_SETTINGS)
    assert isinstance(redeploy_result, Success)
    redeploy_plan = redeploy_result.value
    await deploy_chart_plan(redeploy_plan)

    redeploy_pv_names = {
        b.persistent_volume_name
        for release in redeploy_plan.releases
        for b in release.storage_bindings
    }
    assert original_pv_names == redeploy_pv_names, (
        f"PV name set changed after redeploy: "
        f"original={original_pv_names}, redeployed={redeploy_pv_names}"
    )


@pytest.mark.asyncio
async def test_same_pvc_names_after_redeploy(
    storage_context: StorageTestContext,
) -> None:
    """PVC names must be identical after a delete → redeploy cycle."""
    original_pvc_names = {b.persistent_volume_claim_name for b in storage_context.bindings}

    await delete_chart_plan(storage_context.delete_plan)

    redeploy_result = build_chart_deployment_plan(_ROOT_CHART, _KP_SETTINGS)
    assert isinstance(redeploy_result, Success)
    redeploy_plan = redeploy_result.value
    await deploy_chart_plan(redeploy_plan)

    redeploy_pvc_names = {
        b.persistent_volume_claim_name
        for release in redeploy_plan.releases
        for b in release.storage_bindings
    }
    assert original_pvc_names == redeploy_pvc_names, (
        f"PVC name set changed after redeploy: "
        f"original={original_pvc_names}, redeployed={redeploy_pvc_names}"
    )


@pytest.mark.asyncio
async def test_same_host_paths_after_redeploy(
    storage_context: StorageTestContext,
) -> None:
    """Host paths must be identical after a delete → redeploy cycle."""
    original_host_paths = {str(b.host_path) for b in storage_context.bindings}

    await delete_chart_plan(storage_context.delete_plan)

    redeploy_result = build_chart_deployment_plan(_ROOT_CHART, _KP_SETTINGS)
    assert isinstance(redeploy_result, Success)
    redeploy_plan = redeploy_result.value
    await deploy_chart_plan(redeploy_plan)

    redeploy_host_paths = {
        str(b.host_path) for release in redeploy_plan.releases for b in release.storage_bindings
    }
    assert original_host_paths == redeploy_host_paths, (
        f"host path set changed after redeploy: "
        f"original={original_host_paths}, redeployed={redeploy_host_paths}"
    )
