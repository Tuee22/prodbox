"""Integration tests for the in-cluster gateway chart's partition tolerance.

gateway-partition suite — deploys ``charts/gateway`` via ``deploy_chart_plan``,
exercises pod-loss and network-partition scenarios against the elected leader,
and asserts that:

  * the chart deploys all per-node Deployments and reaches a converged owner,
  * killing the elected leader pod triggers failover to the next-ranked node,
  * a NetworkPolicy partition isolating one node creates a split-brain that
    re-converges to the canonical leader after the partition heals,
  * Route 53 write quiescence holds because only the elected leader's
    ``has_active_claim`` becomes true.

These tests assume a live RKE2 cluster with cert-manager installed and the
gateway image already imported into the local containerd cache (the standard
``prodbox rke2 ensure`` flow).  Settings come from ``prodbox-config.json`` so
the chart's prodbox-config secret carries the operator's real AWS region and
zone id; the gateway's Route 53 writes are best-effort and silently no-op
when DNS write attempts fail, so the partition coverage does not depend on
authoritative AWS access.
"""

from __future__ import annotations

import asyncio
import json
import shutil
from collections.abc import AsyncIterator
from pathlib import Path
from typing import NamedTuple, cast

import pytest
import pytest_asyncio

from prodbox.cli.types import Success
from prodbox.lib.chart_platform import (
    GATEWAY_NODE_IDS,
    ChartDeploymentPlan,
    build_chart_delete_plan,
    build_chart_deployment_plan,
    delete_chart_plan,
    deploy_chart_plan,
    resolve_gateway_event_keys,
)
from prodbox.settings import load_settings_mapping

from .conftest import (
    abort_test_session_on_teardown_failure,
    kubectl_apply_manifest,
    kubectl_delete_manifest,
    kubectl_exec_curl,
    resolve_kubeconfig,
    wait_for_pod_running,
)
from .helpers import run_kubectl_capture_via_dag, wait_for_async
from .k8s_manifests import gateway_network_policy_isolate

pytestmark = [pytest.mark.integration, pytest.mark.timeout(900)]

_ROOT_CHART = "gateway"
_REST_PORT = 8443
_CONVERGENCE_TIMEOUT_SECONDS = 240.0
_FAILOVER_TIMEOUT_SECONDS = 180.0
_PARTITION_HEAL_TIMEOUT_SECONDS = 300.0
_PARTITION_HEAL_SETTLE_SECONDS = 5.0


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


async def _require_tools_and_cluster(kubeconfig: Path) -> None:
    """Fail hard if kubectl/helm are absent or cluster is unreachable."""
    for tool in ("kubectl", "helm"):
        if shutil.which(tool) is None:
            raise AssertionError(f"{tool} not installed (required for gateway-partition suite)")
    if not kubeconfig.exists():
        raise AssertionError(f"kubeconfig not found: {kubeconfig}")
    rc, _, stderr = await run_kubectl_capture_via_dag(
        "cluster-info",
        kubeconfig=kubeconfig,
        timeout=30.0,
    )
    if rc != 0:
        raise AssertionError(f"kubectl cluster-info failed: {stderr}")


async def _resolve_pod_name(*, node_id: str, namespace: str, kubeconfig: Path) -> str | None:
    """Look up the single Deployment pod name for one gateway node id."""
    rc, stdout, stderr = await run_kubectl_capture_via_dag(
        "get",
        "pods",
        "-l",
        f"gateway-node={node_id}",
        "-n",
        namespace,
        "-o",
        "jsonpath={.items[*].metadata.name}",
        kubeconfig=kubeconfig,
        timeout=30.0,
    )
    if rc != 0:
        raise AssertionError(f"kubectl get pods failed: {stderr}")
    name = stdout.strip()
    if not name:
        return None
    # jsonpath produces a space-separated list when there is more than one match
    candidates = [token for token in name.split() if token]
    return candidates[0] if candidates else None


async def _wait_for_pod_for_node(
    *, node_id: str, namespace: str, kubeconfig: Path, timeout_seconds: float = 180.0
) -> str:
    """Wait until exactly one Running pod exists for a node id and return its name."""

    async def pod_is_running() -> bool:
        pod_name = await _resolve_pod_name(
            node_id=node_id, namespace=namespace, kubeconfig=kubeconfig
        )
        if pod_name is None:
            return False
        try:
            await wait_for_pod_running(
                pod_name=pod_name,
                namespace=namespace,
                kubeconfig=kubeconfig,
                timeout_seconds=10,
            )
            return True
        except AssertionError:
            return False

    await wait_for_async(pod_is_running, timeout_seconds=timeout_seconds)
    pod_name = await _resolve_pod_name(node_id=node_id, namespace=namespace, kubeconfig=kubeconfig)
    assert pod_name is not None
    return pod_name


async def _get_pod_state(
    *, pod_name: str, namespace: str, kubeconfig: Path
) -> dict[str, object] | None:
    """Query /v1/state on a gateway pod via kubectl exec curl."""
    rc, body = await kubectl_exec_curl(
        pod_name=pod_name,
        namespace=namespace,
        url=f"https://localhost:{_REST_PORT}/v1/state",
        kubeconfig=kubeconfig,
    )
    if rc != 0:
        return None
    try:
        raw = cast(object, json.loads(body))
        if isinstance(raw, dict):
            return cast(dict[str, object], raw)
    except (json.JSONDecodeError, ValueError):
        pass
    return None


async def _all_pods_agree_owner(
    *,
    namespace: str,
    kubeconfig: Path,
    expected_owner: str,
    node_ids: tuple[str, ...] = GATEWAY_NODE_IDS,
) -> bool:
    """Return True iff every named node id reports the expected gateway owner."""
    for node_id in node_ids:
        pod_name = await _resolve_pod_name(
            node_id=node_id, namespace=namespace, kubeconfig=kubeconfig
        )
        if pod_name is None:
            return False
        state = await _get_pod_state(pod_name=pod_name, namespace=namespace, kubeconfig=kubeconfig)
        if state is None:
            return False
        if state.get("gateway_owner") != expected_owner:
            return False
    return True


async def _wait_for_owner(
    *,
    namespace: str,
    kubeconfig: Path,
    expected_owner: str,
    node_ids: tuple[str, ...] = GATEWAY_NODE_IDS,
    timeout_seconds: float = _CONVERGENCE_TIMEOUT_SECONDS,
) -> None:
    """Wait until the named pods agree on the expected owner."""

    async def owner_matches() -> bool:
        return await _all_pods_agree_owner(
            namespace=namespace,
            kubeconfig=kubeconfig,
            expected_owner=expected_owner,
            node_ids=node_ids,
        )

    await wait_for_async(owner_matches, timeout_seconds=timeout_seconds)


async def _wait_for_active_claim(
    *,
    namespace: str,
    kubeconfig: Path,
    node_id: str,
    timeout_seconds: float = _CONVERGENCE_TIMEOUT_SECONDS,
) -> None:
    """Wait until the daemon on ``node_id`` reports has_active_claim = True."""

    async def claim_active() -> bool:
        pod_name = await _resolve_pod_name(
            node_id=node_id, namespace=namespace, kubeconfig=kubeconfig
        )
        if pod_name is None:
            return False
        state = await _get_pod_state(pod_name=pod_name, namespace=namespace, kubeconfig=kubeconfig)
        if state is None:
            return False
        return bool(state.get("has_active_claim", False))

    await wait_for_async(claim_active, timeout_seconds=timeout_seconds)


async def _all_other_pods_have_no_active_claim(
    *,
    namespace: str,
    kubeconfig: Path,
    leader_node_id: str,
) -> bool:
    """Verify that no non-leader pod is currently writing DNS."""
    for node_id in GATEWAY_NODE_IDS:
        if node_id == leader_node_id:
            continue
        pod_name = await _resolve_pod_name(
            node_id=node_id, namespace=namespace, kubeconfig=kubeconfig
        )
        if pod_name is None:
            continue
        state = await _get_pod_state(pod_name=pod_name, namespace=namespace, kubeconfig=kubeconfig)
        if state is None:
            continue
        if state.get("has_active_claim") is True:
            return False
    return True


async def _best_effort_cleanup(*, kubeconfig: Path) -> None:
    """Idempotent pre/post-test cleanup of the gateway chart stack."""
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


class GatewayPartitionContext(NamedTuple):
    """Resolved context for one gateway-partition integration test."""

    kubeconfig: Path
    deploy_plan: ChartDeploymentPlan
    namespace: str


@pytest_asyncio.fixture
async def gateway_partition_context() -> AsyncIterator[GatewayPartitionContext]:
    """Deploy the gateway chart, wait for converged ownership, then clean up."""
    kubeconfig = resolve_kubeconfig()
    await _require_tools_and_cluster(kubeconfig)

    settings = load_settings_mapping()
    chart_secrets: dict[str, str] = {}
    gateway_event_keys = resolve_gateway_event_keys(_ROOT_CHART)
    deploy_plan_result = build_chart_deployment_plan(
        _ROOT_CHART,
        settings,
        chart_secrets,
        gateway_event_keys=gateway_event_keys,
    )
    assert isinstance(
        deploy_plan_result, Success
    ), f"build_chart_deployment_plan failed: {deploy_plan_result}"
    deploy_plan = deploy_plan_result.value

    await _best_effort_cleanup(kubeconfig=kubeconfig)

    try:
        await deploy_chart_plan(deploy_plan)
    except Exception as error:
        await _best_effort_cleanup(kubeconfig=kubeconfig)
        raise AssertionError(
            f"deploy_chart_plan failed during gateway-partition fixture setup: {error}"
        ) from error

    try:
        for node_id in GATEWAY_NODE_IDS:
            await _wait_for_pod_for_node(
                node_id=node_id,
                namespace=deploy_plan.namespace,
                kubeconfig=kubeconfig,
                timeout_seconds=240.0,
            )
        await _wait_for_owner(
            namespace=deploy_plan.namespace,
            kubeconfig=kubeconfig,
            expected_owner=GATEWAY_NODE_IDS[0],
        )
    except Exception:
        await _best_effort_cleanup(kubeconfig=kubeconfig)
        raise

    yield GatewayPartitionContext(
        kubeconfig=kubeconfig,
        deploy_plan=deploy_plan,
        namespace=deploy_plan.namespace,
    )

    try:
        await delete_chart_plan(deploy_plan)
    except Exception:
        try:
            await _best_effort_cleanup(kubeconfig=kubeconfig)
        except Exception as cleanup_error:
            abort_test_session_on_teardown_failure(
                target=f"gateway-partition cleanup {deploy_plan.namespace}",
                error=cleanup_error,
            )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_chart_deployment_converges_on_canonical_leader(
    gateway_partition_context: GatewayPartitionContext,
) -> None:
    """All chart-deployed pods must agree on the highest-ranked node as owner."""
    leader = GATEWAY_NODE_IDS[0]
    converged = await _all_pods_agree_owner(
        namespace=gateway_partition_context.namespace,
        kubeconfig=gateway_partition_context.kubeconfig,
        expected_owner=leader,
    )
    assert converged, f"gateway pods did not converge on {leader}"


@pytest.mark.asyncio
async def test_only_leader_holds_active_dns_write_claim(
    gateway_partition_context: GatewayPartitionContext,
) -> None:
    """has_active_claim must be true on the leader and false on every other pod."""
    leader = GATEWAY_NODE_IDS[0]
    await _wait_for_active_claim(
        namespace=gateway_partition_context.namespace,
        kubeconfig=gateway_partition_context.kubeconfig,
        node_id=leader,
    )
    quiet = await _all_other_pods_have_no_active_claim(
        namespace=gateway_partition_context.namespace,
        kubeconfig=gateway_partition_context.kubeconfig,
        leader_node_id=leader,
    )
    assert quiet, "non-leader pods unexpectedly hold an active DNS write claim"


@pytest.mark.asyncio
async def test_leader_pod_kill_triggers_failover_to_next_rank(
    gateway_partition_context: GatewayPartitionContext,
) -> None:
    """Scaling the leader Deployment to 0 must promote the next-ranked node.

    The chart deploys each gateway replica as its own Deployment with
    ``replicas: 1``. A bare ``kubectl delete pod`` races with the Deployment
    controller, which immediately recreates a fresh pod and short-circuits
    the failover window. Scaling to 0 keeps the leader gone long enough to
    exercise the heartbeat-timeout / claim-yield path, and scaling back to 1
    proves reconvergence to the canonical leader.
    """
    leader = GATEWAY_NODE_IDS[0]
    successor = GATEWAY_NODE_IDS[1]
    deployment_name = f"gateway-{leader}"

    rc, _, scale_down_stderr = await run_kubectl_capture_via_dag(
        "scale",
        "deployment",
        deployment_name,
        "--replicas=0",
        "-n",
        gateway_partition_context.namespace,
        kubeconfig=gateway_partition_context.kubeconfig,
        timeout=60.0,
    )
    assert (
        rc == 0
    ), f"kubectl scale deployment {deployment_name} --replicas=0 failed: {scale_down_stderr}"

    await _wait_for_owner(
        namespace=gateway_partition_context.namespace,
        kubeconfig=gateway_partition_context.kubeconfig,
        expected_owner=successor,
        node_ids=(GATEWAY_NODE_IDS[1], GATEWAY_NODE_IDS[2]),
        timeout_seconds=_FAILOVER_TIMEOUT_SECONDS,
    )

    rc, _, scale_up_stderr = await run_kubectl_capture_via_dag(
        "scale",
        "deployment",
        deployment_name,
        "--replicas=1",
        "-n",
        gateway_partition_context.namespace,
        kubeconfig=gateway_partition_context.kubeconfig,
        timeout=60.0,
    )
    assert (
        rc == 0
    ), f"kubectl scale deployment {deployment_name} --replicas=1 failed: {scale_up_stderr}"

    await _wait_for_pod_for_node(
        node_id=leader,
        namespace=gateway_partition_context.namespace,
        kubeconfig=gateway_partition_context.kubeconfig,
        timeout_seconds=240.0,
    )
    await _wait_for_owner(
        namespace=gateway_partition_context.namespace,
        kubeconfig=gateway_partition_context.kubeconfig,
        expected_owner=leader,
    )


@pytest.mark.asyncio
async def test_partition_then_heal_reconverges_to_canonical_leader(
    gateway_partition_context: GatewayPartitionContext,
) -> None:
    """A NetworkPolicy partition then heal must restore canonical ownership."""
    leader = GATEWAY_NODE_IDS[0]
    isolated = GATEWAY_NODE_IDS[2]
    isolation_policy = gateway_network_policy_isolate(
        target_node=isolated,
        namespace=gateway_partition_context.namespace,
    )
    await kubectl_apply_manifest(
        isolation_policy,
        kubeconfig=gateway_partition_context.kubeconfig,
        tmp_dir=Path("/tmp"),
    )
    try:

        async def split_brain_observed() -> bool:
            majority_ok = await _all_pods_agree_owner(
                namespace=gateway_partition_context.namespace,
                kubeconfig=gateway_partition_context.kubeconfig,
                expected_owner=leader,
                node_ids=(GATEWAY_NODE_IDS[0], GATEWAY_NODE_IDS[1]),
            )
            if not majority_ok:
                return False
            isolated_pod_name = await _resolve_pod_name(
                node_id=isolated,
                namespace=gateway_partition_context.namespace,
                kubeconfig=gateway_partition_context.kubeconfig,
            )
            if isolated_pod_name is None:
                return True
            isolated_state = await _get_pod_state(
                pod_name=isolated_pod_name,
                namespace=gateway_partition_context.namespace,
                kubeconfig=gateway_partition_context.kubeconfig,
            )
            if isolated_state is None:
                return True
            return isolated_state.get("gateway_owner") == isolated

        await wait_for_async(split_brain_observed, timeout_seconds=_PARTITION_HEAL_TIMEOUT_SECONDS)
    finally:
        await kubectl_delete_manifest(
            isolation_policy,
            kubeconfig=gateway_partition_context.kubeconfig,
            tmp_dir=Path("/tmp"),
        )

    # Give Canal a brief grace period to reflect the policy delete in the
    # pod's effective ingress/egress rules before polling for reconvergence.
    await asyncio.sleep(_PARTITION_HEAL_SETTLE_SECONDS)
    await _wait_for_owner(
        namespace=gateway_partition_context.namespace,
        kubeconfig=gateway_partition_context.kubeconfig,
        expected_owner=leader,
        timeout_seconds=_PARTITION_HEAL_TIMEOUT_SECONDS,
    )
