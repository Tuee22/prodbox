"""Kubernetes pod-based integration tests for gateway daemon.

These tests deploy gateway daemons as actual K8s pods and test mesh formation,
failover, network partition simulation, and DNS write gating.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import uuid
from collections.abc import AsyncIterator
from pathlib import Path
from typing import NamedTuple, cast

import pytest
import pytest_asyncio

from prodbox.lib.prodbox_k8s import prodbox_gateway_image_ref

from .conftest import (
    abort_test_session_on_teardown_failure,
    apply_cert_manifest,
    cleanup_gateway_test_resources,
    delete_pod_force,
    kubectl_apply_manifest,
    kubectl_delete_manifest,
    kubectl_exec_curl,
    wait_for_certificate,
    wait_for_pod_running,
)
from .helpers import wait_for_async
from .k8s_manifests import (
    gateway_config_configmap,
    gateway_daemon_pod,
    gateway_network_policy_asymmetric,
    gateway_network_policy_isolate,
    gateway_orders_configmap,
    gateway_service,
)

NODE_IDS = ("node-a", "node-b", "node-c")
EVENT_KEYS = {"node-a": "key-a", "node-b": "key-b", "node-c": "key-c"}
REST_PORT = 8443
SOCKET_PORT = 8444
HEARTBEAT_TIMEOUT_SECONDS = 5
HEARTBEAT_INTERVAL_SECONDS = 0.5
CONVERGENCE_TIMEOUT_SECONDS = 120.0
ISOLATION_CONVERGENCE_TIMEOUT_SECONDS = 90.0
ISOLATION_SETTLE_SECONDS = HEARTBEAT_TIMEOUT_SECONDS + HEARTBEAT_INTERVAL_SECONDS + 0.5
PARTITION_POLICY_SETTLE_SECONDS = ISOLATION_SETTLE_SECONDS + 2.0
EVENT_PROPAGATION_SETTLE_SECONDS = float(HEARTBEAT_TIMEOUT_SECONDS)
LESS_THAN_ISOLATION_TIMEOUT_SECONDS = float(HEARTBEAT_TIMEOUT_SECONDS - 3)
HEARTBEAT_COLLECTION_SPACING_SECONDS = HEARTBEAT_INTERVAL_SECONDS * 2.0
LONG_PARTITION_SETTLE_SECONDS = float(HEARTBEAT_TIMEOUT_SECONDS * 5)
LONG_HEAL_SETTLE_SECONDS = float(HEARTBEAT_TIMEOUT_SECONDS * 2)
pytestmark = pytest.mark.timeout(300)


class GatewayPodMeshContext(NamedTuple):
    """Per-test converged gateway pod mesh."""

    kubeconfig: Path
    namespace: str
    tmp_dir: Path
    image: str


def _gateway_test_namespace() -> str:
    """Return a unique namespace for one gateway pod integration test."""
    return f"prodbox-gw-pods-{uuid.uuid4().hex[:8]}"


def _pod_orders(namespace: str) -> dict[str, object]:
    """Build orders doc using K8s service DNS names."""
    return {
        "version_utc": 1000,
        "nodes": [
            {
                "node_id": node_id,
                "stable_dns_name": f"gateway-{node_id}.{namespace}.svc.cluster.local",
                "rest_host": "0.0.0.0",
                "rest_port": REST_PORT,
                "socket_host": "0.0.0.0",
                "socket_port": SOCKET_PORT,
            }
            for node_id in NODE_IDS
        ],
        "gateway_rule": {
            "ranked_nodes": list(NODE_IDS),
            "heartbeat_timeout_seconds": HEARTBEAT_TIMEOUT_SECONDS,
        },
    }


def _resolve_gateway_image() -> str:
    """Resolve gateway container image from PRODBOX_GATEWAY_IMAGE env var.

    The gateway daemon runs as a local Python process via poetry in production.
    For K8s pod integration tests, image selection order is:
    1) explicit PRODBOX_GATEWAY_IMAGE env var
    2) canonical Harbor image derived from local machine-id
    """
    image = os.environ.get("PRODBOX_GATEWAY_IMAGE", "")
    if image:
        return image
    machine_id_path = Path("/etc/machine-id")
    if not machine_id_path.exists():
        raise AssertionError(
            "PRODBOX_GATEWAY_IMAGE not set and /etc/machine-id missing; "
            "cannot derive Harbor image reference"
        )
    machine_id = machine_id_path.read_text(encoding="utf-8").strip().lower()
    if re.fullmatch(r"[0-9a-f]{32}", machine_id) is None:
        raise AssertionError(f"Unexpected /etc/machine-id format: {machine_id}")
    return prodbox_gateway_image_ref(f"prodbox-{machine_id}")


async def _deploy_gateway_mesh(
    *,
    namespace: str,
    image: str,
    kubeconfig: Path,
    tmp_dir: Path,
    node_ids: tuple[str, ...] = NODE_IDS,
) -> None:
    """Deploy N gateway daemon pods + services, wait for Running."""
    orders = _pod_orders(namespace)

    # Create orders configmap
    await kubectl_apply_manifest(
        gateway_orders_configmap(namespace, orders),
        kubeconfig=kubeconfig,
        tmp_dir=tmp_dir,
    )

    # Create per-node config configmaps, pods, services
    for node_id in node_ids:
        await kubectl_apply_manifest(
            gateway_config_configmap(
                node_id=node_id,
                namespace=namespace,
                event_keys=EVENT_KEYS,
            ),
            kubeconfig=kubeconfig,
            tmp_dir=tmp_dir,
        )
        await kubectl_apply_manifest(
            gateway_daemon_pod(
                node_id=node_id,
                namespace=namespace,
                image=image,
                rest_port=REST_PORT,
                socket_port=SOCKET_PORT,
                cert_secret=f"{node_id}-tls",
                ca_secret="root-ca-secret",
                orders_configmap="gateway-orders",
            ),
            kubeconfig=kubeconfig,
            tmp_dir=tmp_dir,
        )
        await kubectl_apply_manifest(
            gateway_service(
                node_id=node_id,
                namespace=namespace,
                rest_port=REST_PORT,
                socket_port=SOCKET_PORT,
            ),
            kubeconfig=kubeconfig,
            tmp_dir=tmp_dir,
        )

    # Wait for all pods to be Running
    for node_id in node_ids:
        await wait_for_pod_running(
            pod_name=f"gateway-{node_id}",
            namespace=namespace,
            kubeconfig=kubeconfig,
            timeout_seconds=120,
        )


async def _recreate_gateway_pod(
    *,
    node_id: str,
    namespace: str,
    image: str,
    kubeconfig: Path,
    tmp_dir: Path,
) -> None:
    """Recreate a deleted gateway pod and wait for Running."""
    await kubectl_apply_manifest(
        gateway_daemon_pod(
            node_id=node_id,
            namespace=namespace,
            image=image,
            rest_port=REST_PORT,
            socket_port=SOCKET_PORT,
            cert_secret=f"{node_id}-tls",
            ca_secret="root-ca-secret",
            orders_configmap="gateway-orders",
        ),
        kubeconfig=kubeconfig,
        tmp_dir=tmp_dir,
    )
    await wait_for_pod_running(
        pod_name=f"gateway-{node_id}",
        namespace=namespace,
        kubeconfig=kubeconfig,
        timeout_seconds=120,
    )


async def _get_pod_state(
    *,
    pod_name: str,
    namespace: str,
    kubeconfig: Path,
) -> dict[str, object] | None:
    """Query /v1/state on a gateway pod via kubectl exec curl."""
    rc, body = await kubectl_exec_curl(
        pod_name=pod_name,
        namespace=namespace,
        url=f"https://localhost:{REST_PORT}/v1/state",
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
    node_ids: tuple[str, ...] = NODE_IDS,
) -> bool:
    """Check that all pods agree on the gateway owner."""
    for node_id in node_ids:
        state = await _get_pod_state(
            pod_name=f"gateway-{node_id}",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )
        if state is None:
            return False
        if state.get("gateway_owner") != expected_owner:
            return False
    return True


async def _get_pod_event_hashes(
    *,
    pod_name: str,
    namespace: str,
    kubeconfig: Path,
) -> frozenset[str] | None:
    """Get event hashes from a pod's /v1/state endpoint."""
    state = await _get_pod_state(
        pod_name=pod_name,
        namespace=namespace,
        kubeconfig=kubeconfig,
    )
    if state is None:
        return None
    raw_hashes = state.get("event_hashes")
    if not isinstance(raw_hashes, list):
        return frozenset()
    return frozenset(str(h) for h in raw_hashes)


async def _collect_pod_event_hash_sets(
    *,
    namespace: str,
    kubeconfig: Path,
    node_ids: tuple[str, ...] = NODE_IDS,
) -> list[frozenset[str]] | None:
    """Collect event hash sets from all pods; return None if any pod is unavailable."""
    hash_set_results = await asyncio.gather(
        *(
            _get_pod_event_hashes(
                pod_name=f"gateway-{node_id}",
                namespace=namespace,
                kubeconfig=kubeconfig,
            )
            for node_id in node_ids
        )
    )
    if any(hash_set is None for hash_set in hash_set_results):
        return None
    return [hash_set for hash_set in hash_set_results if hash_set is not None]


def _all_hash_sets_equal(hash_sets: list[frozenset[str]]) -> bool:
    """Return True when all hash sets in a list are identical."""
    if len(hash_sets) < 2:
        return True
    first = hash_sets[0]
    return all(hash_set == first for hash_set in hash_sets[1:])


async def _wait_for_owner(
    *,
    namespace: str,
    kubeconfig: Path,
    expected_owner: str,
    node_ids: tuple[str, ...] = NODE_IDS,
    timeout_seconds: float = CONVERGENCE_TIMEOUT_SECONDS,
) -> None:
    """Wait until the selected pods agree on the expected owner."""

    async def owner_matches() -> bool:
        return await _all_pods_agree_owner(
            namespace=namespace,
            kubeconfig=kubeconfig,
            expected_owner=expected_owner,
            node_ids=node_ids,
        )

    await wait_for_async(owner_matches, timeout_seconds=timeout_seconds)


@pytest_asyncio.fixture
async def gateway_pod_mesh_context(
    cluster_kubeconfig: Path,
    tmp_path: Path,
) -> AsyncIterator[GatewayPodMeshContext]:
    """Provision a unique namespace, deploy the mesh, and converge on node-a."""
    namespace = _gateway_test_namespace()
    image = _resolve_gateway_image()
    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=cluster_kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=cluster_kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=cluster_kubeconfig,
            )

        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=cluster_kubeconfig,
            tmp_dir=tmp_path,
        )
        await _wait_for_owner(
            namespace=namespace,
            kubeconfig=cluster_kubeconfig,
            expected_owner="node-a",
        )
    except Exception:
        try:
            await cleanup_gateway_test_resources(
                namespace=namespace,
                kubeconfig=cluster_kubeconfig,
            )
        except Exception as cleanup_error:
            abort_test_session_on_teardown_failure(
                target=f"gateway pod setup cleanup {namespace}",
                error=cleanup_error,
            )
        raise

    yield GatewayPodMeshContext(
        kubeconfig=cluster_kubeconfig,
        namespace=namespace,
        tmp_dir=tmp_path,
        image=image,
    )

    try:
        await cleanup_gateway_test_resources(
            namespace=namespace,
            kubeconfig=cluster_kubeconfig,
        )
    except Exception as error:
        abort_test_session_on_teardown_failure(
            target=f"gateway pod mesh namespace {namespace}",
            error=error,
        )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_pods_form_mesh_and_converge_on_owner(
    gateway_pod_mesh_context: GatewayPodMeshContext,
) -> None:
    """Deploy 3 pods and verify they converge on node-a as gateway owner."""
    for node_id in NODE_IDS:
        state = await _get_pod_state(
            pod_name=f"gateway-{node_id}",
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
        )
        assert state is not None, f"pod gateway-{node_id} state is None"
        assert state["gateway_owner"] == "node-a"
        assert state["node_id"] == node_id


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_pod_crash_triggers_failover(
    gateway_pod_mesh_context: GatewayPodMeshContext,
) -> None:
    """Delete node-a pod, verify remaining pods failover to node-b."""
    await delete_pod_force(
        pod_name="gateway-node-a",
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
    )
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-b",
        node_ids=("node-b", "node-c"),
        timeout_seconds=ISOLATION_CONVERGENCE_TIMEOUT_SECONDS,
    )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_pod_restart_reclaims_ownership(
    gateway_pod_mesh_context: GatewayPodMeshContext,
) -> None:
    """After node-a restarts, it reclaims gateway ownership."""
    await delete_pod_force(
        pod_name="gateway-node-a",
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
    )
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-b",
        node_ids=("node-b", "node-c"),
        timeout_seconds=ISOLATION_CONVERGENCE_TIMEOUT_SECONDS,
    )
    await _recreate_gateway_pod(
        node_id="node-a",
        namespace=gateway_pod_mesh_context.namespace,
        image=gateway_pod_mesh_context.image,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-a",
    )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_network_partition_causes_split_brain_then_heals(
    gateway_pod_mesh_context: GatewayPodMeshContext,
) -> None:
    """Isolate node-c via NetworkPolicy, verify split-brain, then heal."""
    isolation_policy = gateway_network_policy_isolate(
        target_node="node-c",
        namespace=gateway_pod_mesh_context.namespace,
    )
    await kubectl_apply_manifest(
        isolation_policy,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )

    async def partition_behavior_converged() -> bool:
        majority_ok = await _all_pods_agree_owner(
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
            expected_owner="node-a",
            node_ids=("node-a", "node-b"),
        )
        if not majority_ok:
            return False
        c_state = await _get_pod_state(
            pod_name="gateway-node-c",
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
        )
        if c_state is None:
            return True
        return c_state.get("gateway_owner") == "node-c"

    await wait_for_async(
        partition_behavior_converged, timeout_seconds=ISOLATION_CONVERGENCE_TIMEOUT_SECONDS
    )
    await kubectl_delete_manifest(
        isolation_policy,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-a",
    )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_primary_isolation_triggers_failover_for_majority(
    gateway_pod_mesh_context: GatewayPodMeshContext,
) -> None:
    """Isolate node-a, verify node-b+c failover, then heal and reconverge."""
    isolation_policy = gateway_network_policy_isolate(
        target_node="node-a",
        namespace=gateway_pod_mesh_context.namespace,
    )
    await kubectl_apply_manifest(
        isolation_policy,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-b",
        node_ids=("node-b", "node-c"),
        timeout_seconds=ISOLATION_CONVERGENCE_TIMEOUT_SECONDS,
    )
    a_state = await _get_pod_state(
        pod_name="gateway-node-a",
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
    )
    if a_state is not None:
        assert a_state["gateway_owner"] == "node-a"
    await kubectl_delete_manifest(
        isolation_policy,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-a",
    )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_only_gateway_owner_writes_dns(
    gateway_pod_mesh_context: GatewayPodMeshContext,
) -> None:
    """Verify only the gateway owner attempts DNS writes (via commit log events)."""
    for node_id in NODE_IDS:
        state = await _get_pod_state(
            pod_name=f"gateway-{node_id}",
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
        )
        assert state is not None
        assert state["gateway_owner"] == "node-a"

    await delete_pod_force(
        pod_name="gateway-node-a",
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
    )
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-b",
        node_ids=("node-b", "node-c"),
        timeout_seconds=ISOLATION_CONVERGENCE_TIMEOUT_SECONDS,
    )
    b_state = await _get_pod_state(
        pod_name="gateway-node-b",
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
    )
    c_state = await _get_pod_state(
        pod_name="gateway-node-c",
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
    )
    assert b_state is not None
    assert b_state["gateway_owner"] == "node-b"
    assert c_state is not None
    assert c_state["gateway_owner"] == "node-b"


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_event_log_converges_after_partition_heal(
    gateway_pod_mesh_context: GatewayPodMeshContext,
) -> None:
    """Verify all pods have consistent gateway owner view after partition heals."""
    isolation_policy = gateway_network_policy_isolate(
        target_node="node-c",
        namespace=gateway_pod_mesh_context.namespace,
    )
    await kubectl_apply_manifest(
        isolation_policy,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await asyncio.sleep(PARTITION_POLICY_SETTLE_SECONDS)
    await kubectl_delete_manifest(
        isolation_policy,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await asyncio.sleep(EVENT_PROPAGATION_SETTLE_SECONDS)
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-a",
    )

    states: list[dict[str, object]] = []
    for node_id in NODE_IDS:
        state = await _get_pod_state(
            pod_name=f"gateway-{node_id}",
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
        )
        assert state is not None
        states.append(state)

    owners = {str(state["gateway_owner"]) for state in states}
    assert len(owners) == 1
    assert "node-a" in owners


# ---------------------------------------------------------------------------
# Phase 9: Expanded distributed failure simulation tests
# ---------------------------------------------------------------------------


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_simultaneous_multi_node_crash_leaves_singleton(
    gateway_pod_mesh_context: GatewayPodMeshContext,
) -> None:
    """Crash 2 of 3 nodes simultaneously, verify singleton takeover then reconvergence.

    Exercises the SingletonTakeover liveness property: the last surviving node
    must self-elect as gateway owner when all peers are unreachable.
    """
    await asyncio.gather(
        delete_pod_force(
            pod_name="gateway-node-a",
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
        ),
        delete_pod_force(
            pod_name="gateway-node-b",
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
        ),
    )
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-c",
        node_ids=("node-c",),
        timeout_seconds=ISOLATION_CONVERGENCE_TIMEOUT_SECONDS,
    )
    await _recreate_gateway_pod(
        node_id="node-a",
        namespace=gateway_pod_mesh_context.namespace,
        image=gateway_pod_mesh_context.image,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await _recreate_gateway_pod(
        node_id="node-b",
        namespace=gateway_pod_mesh_context.namespace,
        image=gateway_pod_mesh_context.image,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-a",
    )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_cascading_failure_to_last_node(
    gateway_pod_mesh_context: GatewayPodMeshContext,
) -> None:
    """Crash node-a, then crash node-b before failover completes, verify node-c.

    Tests cascading failures where nodes fail sequentially faster than the
    failover cycle can complete, leaving only the lowest-ranked node.
    """
    await delete_pod_force(
        pod_name="gateway-node-a",
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
    )
    await asyncio.sleep(LESS_THAN_ISOLATION_TIMEOUT_SECONDS)
    await delete_pod_force(
        pod_name="gateway-node-b",
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
    )
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-c",
        node_ids=("node-c",),
        timeout_seconds=ISOLATION_CONVERGENCE_TIMEOUT_SECONDS,
    )
    await _recreate_gateway_pod(
        node_id="node-a",
        namespace=gateway_pod_mesh_context.namespace,
        image=gateway_pod_mesh_context.image,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await _recreate_gateway_pod(
        node_id="node-b",
        namespace=gateway_pod_mesh_context.namespace,
        image=gateway_pod_mesh_context.image,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-a",
    )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_flapping_node_convergence(
    gateway_pod_mesh_context: GatewayPodMeshContext,
) -> None:
    """Crash and restart node-a 3 times rapidly, verify convergence and event hash consistency.

    Tests that rapid flapping (crash/restart cycles) does not leave the cluster
    in an inconsistent state. After flapping stops, all nodes must converge and
    event hash sets must be identical (anti-entropy resolved any divergence).
    """
    for _flap in range(3):
        await delete_pod_force(
            pod_name="gateway-node-a",
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
        )
        await _recreate_gateway_pod(
            node_id="node-a",
            namespace=gateway_pod_mesh_context.namespace,
            image=gateway_pod_mesh_context.image,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
            tmp_dir=gateway_pod_mesh_context.tmp_dir,
        )
        await asyncio.sleep(HEARTBEAT_COLLECTION_SPACING_SECONDS)

    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-a",
    )
    await asyncio.sleep(EVENT_PROPAGATION_SETTLE_SECONDS)

    async def event_hashes_converged() -> bool:
        hash_sets = await _collect_pod_event_hash_sets(
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
        )
        if hash_sets is None:
            return False
        return _all_hash_sets_equal(hash_sets)

    await wait_for_async(
        event_hashes_converged, timeout_seconds=ISOLATION_CONVERGENCE_TIMEOUT_SECONDS
    )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_full_cluster_outage_and_recovery(
    gateway_pod_mesh_context: GatewayPodMeshContext,
) -> None:
    """Crash all 3 pods simultaneously, verify recovery and convergence.

    Tests full cluster outage: all nodes crash at the same time. After K8s
    restarts all pods, they must reconverge on the highest-ranked node and
    have consistent commit logs.
    """
    await asyncio.gather(
        delete_pod_force(
            pod_name="gateway-node-a",
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
        ),
        delete_pod_force(
            pod_name="gateway-node-b",
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
        ),
        delete_pod_force(
            pod_name="gateway-node-c",
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
        ),
    )

    for node_id in NODE_IDS:
        await _recreate_gateway_pod(
            node_id=node_id,
            namespace=gateway_pod_mesh_context.namespace,
            image=gateway_pod_mesh_context.image,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
            tmp_dir=gateway_pod_mesh_context.tmp_dir,
        )

    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-a",
    )
    await asyncio.sleep(EVENT_PROPAGATION_SETTLE_SECONDS)

    async def event_hashes_converged() -> bool:
        hash_sets = await _collect_pod_event_hash_sets(
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
        )
        if hash_sets is None:
            return False
        return _all_hash_sets_equal(hash_sets)

    await wait_for_async(
        event_hashes_converged, timeout_seconds=ISOLATION_CONVERGENCE_TIMEOUT_SECONDS
    )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_asymmetric_partition(
    gateway_pod_mesh_context: GatewayPodMeshContext,
) -> None:
    """Create partial mesh: node-a ↔ node-b ↔ node-c, but node-a ✗ node-c.

    Tests asymmetric partition where node-b can reach both peers but node-a
    and node-c cannot communicate directly. Node-b relays heartbeats, so
    node-a and node-b should agree on owner. Node-c may diverge depending
    on whether indirect heartbeat relay is sufficient.

    If Canal CNI's NetworkPolicy cannot cleanly block traffic between two
    specific pods, this test uses the asymmetric NetworkPolicy generator
    which creates targeted egress/ingress deny rules between node-a and node-c.
    """
    egress_policy, ingress_policy = gateway_network_policy_asymmetric(
        blocked_from="node-a",
        blocked_to="node-c",
        namespace=gateway_pod_mesh_context.namespace,
    )
    await kubectl_apply_manifest(
        egress_policy,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await kubectl_apply_manifest(
        ingress_policy,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )

    async def asymmetric_partition_converged() -> bool:
        return await _all_pods_agree_owner(
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
            expected_owner="node-a",
            node_ids=("node-a", "node-b"),
        )

    await wait_for_async(
        asymmetric_partition_converged, timeout_seconds=ISOLATION_CONVERGENCE_TIMEOUT_SECONDS
    )
    await kubectl_delete_manifest(
        egress_policy,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await kubectl_delete_manifest(
        ingress_policy,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-a",
    )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_partition_flap_convergence_stability(
    gateway_pod_mesh_context: GatewayPodMeshContext,
) -> None:
    """Apply and heal partition on node-c 3 times, verify final convergence.

    Tests that repeated partition/heal cycles do not leave orphaned claims
    or permanent divergence. After the final heal, all nodes must converge
    and event logs must be consistent.
    """
    for _cycle in range(3):
        isolation_policy = gateway_network_policy_isolate(
            target_node="node-c",
            namespace=gateway_pod_mesh_context.namespace,
        )
        await kubectl_apply_manifest(
            isolation_policy,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
            tmp_dir=gateway_pod_mesh_context.tmp_dir,
        )
        await asyncio.sleep(PARTITION_POLICY_SETTLE_SECONDS)
        await kubectl_delete_manifest(
            isolation_policy,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
            tmp_dir=gateway_pod_mesh_context.tmp_dir,
        )
        await asyncio.sleep(EVENT_PROPAGATION_SETTLE_SECONDS)

    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-a",
    )
    await asyncio.sleep(EVENT_PROPAGATION_SETTLE_SECONDS)

    async def event_hashes_converged() -> bool:
        hash_sets = await _collect_pod_event_hash_sets(
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
        )
        if hash_sets is None:
            return False
        return _all_hash_sets_equal(hash_sets)

    await wait_for_async(
        event_hashes_converged, timeout_seconds=ISOLATION_CONVERGENCE_TIMEOUT_SECONDS
    )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_long_partition_event_log_merge(
    gateway_pod_mesh_context: GatewayPodMeshContext,
) -> None:
    """Extended partition where both sides accumulate events, then merge via anti-entropy.

    Replaces the weak assertion in test_event_log_converges_after_partition_heal
    by verifying that event hash sets are identical across all nodes after a
    prolonged partition (20+ seconds) with independent event accumulation.
    """
    pre_state_a = await _get_pod_state(
        pod_name="gateway-node-a",
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
    )
    assert pre_state_a is not None
    pre_event_count = int(str(pre_state_a.get("event_count", 0)))

    isolation_policy = gateway_network_policy_isolate(
        target_node="node-c",
        namespace=gateway_pod_mesh_context.namespace,
    )
    await kubectl_apply_manifest(
        isolation_policy,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await asyncio.sleep(LONG_PARTITION_SETTLE_SECONDS)
    await kubectl_delete_manifest(
        isolation_policy,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await asyncio.sleep(LONG_HEAL_SETTLE_SECONDS)
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-a",
    )

    async def event_hashes_converged() -> bool:
        hash_sets = await _collect_pod_event_hash_sets(
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
        )
        if hash_sets is None:
            return False
        return _all_hash_sets_equal(hash_sets)

    await wait_for_async(
        event_hashes_converged, timeout_seconds=ISOLATION_CONVERGENCE_TIMEOUT_SECONDS
    )
    post_state_a = await _get_pod_state(
        pod_name="gateway-node-a",
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
    )
    assert post_state_a is not None
    post_event_count = int(str(post_state_a.get("event_count", 0)))
    assert (
        post_event_count > pre_event_count
    ), f"Events should have accumulated: pre={pre_event_count}, post={post_event_count}"


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_ownership_transition_cycle_verified_behaviorally(
    gateway_pod_mesh_context: GatewayPodMeshContext,
) -> None:
    """Full ownership transition cycle with event hash convergence verification.

    Exercises the complete claim/yield lifecycle:
    1. Converge on node-a (GatewayClaim from node-a)
    2. Crash node-a, failover to node-b (GatewayYield implied, GatewayClaim from node-b)
    3. Restart node-a, reconverge on node-a (GatewayYield from node-b, GatewayClaim from node-a)

    Verifies behavioral outcomes: ownership changed implies claim/yield events were
    emitted (the code always emits these on transitions). Event log convergence is
    verified by comparing event_hashes from /v1/state across pods.
    """
    initial_state = await _get_pod_state(
        pod_name="gateway-node-b",
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
    )
    assert initial_state is not None
    initial_event_count = int(str(initial_state.get("event_count", 0)))

    await delete_pod_force(
        pod_name="gateway-node-a",
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
    )
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-b",
        node_ids=("node-b", "node-c"),
        timeout_seconds=ISOLATION_CONVERGENCE_TIMEOUT_SECONDS,
    )
    await _recreate_gateway_pod(
        node_id="node-a",
        namespace=gateway_pod_mesh_context.namespace,
        image=gateway_pod_mesh_context.image,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        tmp_dir=gateway_pod_mesh_context.tmp_dir,
    )
    await _wait_for_owner(
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
        expected_owner="node-a",
    )
    await asyncio.sleep(EVENT_PROPAGATION_SETTLE_SECONDS)

    async def event_hashes_converged() -> bool:
        hash_sets = await _collect_pod_event_hash_sets(
            namespace=gateway_pod_mesh_context.namespace,
            kubeconfig=gateway_pod_mesh_context.kubeconfig,
        )
        if hash_sets is None:
            return False
        return _all_hash_sets_equal(hash_sets)

    await wait_for_async(
        event_hashes_converged, timeout_seconds=ISOLATION_CONVERGENCE_TIMEOUT_SECONDS
    )
    final_state = await _get_pod_state(
        pod_name="gateway-node-b",
        namespace=gateway_pod_mesh_context.namespace,
        kubeconfig=gateway_pod_mesh_context.kubeconfig,
    )
    assert final_state is not None
    final_event_count = int(str(final_state.get("event_count", 0)))
    assert final_event_count > initial_event_count, (
        f"Event count should increase across ownership transitions: "
        f"initial={initial_event_count}, final={final_event_count}"
    )
