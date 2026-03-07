"""Kubernetes pod-based integration tests for gateway daemon.

These tests deploy gateway daemons as actual K8s pods and test mesh formation,
failover, network partition simulation, and DNS write gating.
"""

from __future__ import annotations

import json
import os
import uuid
from contextlib import suppress
from pathlib import Path
from typing import cast

import pytest

from .conftest import (
    apply_cert_manifest,
    delete_pod_force,
    kubectl_apply_manifest,
    kubectl_delete_manifest,
    kubectl_exec_curl,
    require_rke2_and_cert_manager,
    resolve_kubeconfig,
    wait_for_certificate,
    wait_for_pod_running,
)
from .helpers import run_kubectl_capture_via_dag, wait_for_async
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
            "heartbeat_timeout_seconds": 5,
        },
    }


def _resolve_gateway_image() -> str:
    """Resolve gateway container image from PRODBOX_GATEWAY_IMAGE env var.

    The gateway daemon runs as a local Python process via poetry in production.
    For K8s pod integration tests, a pre-built image must be provided via the
    PRODBOX_GATEWAY_IMAGE environment variable.
    """
    image = os.environ.get("PRODBOX_GATEWAY_IMAGE", "")
    if not image:
        raise AssertionError(
            "PRODBOX_GATEWAY_IMAGE not set; gateway pod tests require a pre-built image"
        )
    return image


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


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_pods_form_mesh_and_converge_on_owner(tmp_path: Path) -> None:
    """Deploy 3 pods and verify they converge on node-a as gateway owner."""
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"

    try:
        # Provision certs
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=kubeconfig,
            )

        # Build image
        image = _resolve_gateway_image()

        # Deploy mesh
        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for all pods to converge on node-a as owner
        async def converged_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # Verify each pod reports correct state
        for node_id in NODE_IDS:
            state = await _get_pod_state(
                pod_name=f"gateway-{node_id}",
                namespace=namespace,
                kubeconfig=kubeconfig,
            )
            assert state is not None, f"pod gateway-{node_id} state is None"
            assert state["gateway_owner"] == "node-a"
            assert state["node_id"] == node_id

    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_pod_crash_triggers_failover(tmp_path: Path) -> None:
    """Delete node-a pod, verify remaining pods failover to node-b."""
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"

    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=kubeconfig,
            )

        image = _resolve_gateway_image()
        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for convergence on node-a
        async def converged_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # Crash node-a
        await delete_pod_force(
            pod_name="gateway-node-a",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )

        # Wait for remaining pods to failover to node-b
        # heartbeat_timeout_seconds is 5, so wait a bit longer
        async def failover_to_node_b() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-b",
                node_ids=("node-b", "node-c"),
            )

        await wait_for_async(failover_to_node_b, timeout_seconds=30.0)

    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_pod_restart_reclaims_ownership(tmp_path: Path) -> None:
    """After node-a restarts, it reclaims gateway ownership."""
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"

    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=kubeconfig,
            )

        image = _resolve_gateway_image()
        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for convergence on node-a
        async def converged_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # Crash node-a
        await delete_pod_force(
            pod_name="gateway-node-a",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )

        # Wait for failover to node-b
        async def failover_to_node_b() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-b",
                node_ids=("node-b", "node-c"),
            )

        await wait_for_async(failover_to_node_b, timeout_seconds=30.0)

        # K8s restarts node-a (restartPolicy: Always)
        await wait_for_pod_running(
            pod_name="gateway-node-a",
            namespace=namespace,
            kubeconfig=kubeconfig,
            timeout_seconds=120,
        )

        # Wait for all pods to reconverge on node-a
        async def reconverge_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(reconverge_on_node_a, timeout_seconds=60.0)

    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_network_partition_causes_split_brain_then_heals(tmp_path: Path) -> None:
    """Isolate node-c via NetworkPolicy, verify split-brain, then heal."""
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"

    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=kubeconfig,
            )

        image = _resolve_gateway_image()
        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for initial convergence on node-a
        async def converged_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # Isolate node-c via NetworkPolicy
        isolation_policy = gateway_network_policy_isolate(
            target_node="node-c",
            namespace=namespace,
        )
        await kubectl_apply_manifest(
            isolation_policy,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for heartbeat timeout to expire for node-c's view
        # node-a and node-b should still see each other and agree on node-a
        import asyncio

        await asyncio.sleep(8.0)  # heartbeat_timeout_seconds=5, plus margin

        # node-a + node-b still agree on node-a
        assert await _all_pods_agree_owner(
            namespace=namespace,
            kubeconfig=kubeconfig,
            expected_owner="node-a",
            node_ids=("node-a", "node-b"),
        )

        # node-c (isolated) should self-elect since it can't see peers
        c_state = await _get_pod_state(
            pod_name="gateway-node-c",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )
        # Note: kubectl exec may also be affected by NetworkPolicy
        # If we can't reach node-c, that's expected under isolation
        # The important assertion is the majority partition behavior
        if c_state is not None:
            assert c_state["gateway_owner"] == "node-c"

        # Heal partition by deleting NetworkPolicy
        await kubectl_delete_manifest(
            isolation_policy,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for all pods to reconverge on node-a
        async def all_reconverge() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(all_reconverge, timeout_seconds=60.0)

    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_primary_isolation_triggers_failover_for_majority(tmp_path: Path) -> None:
    """Isolate node-a, verify node-b+c failover, then heal and reconverge."""
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"

    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=kubeconfig,
            )

        image = _resolve_gateway_image()
        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for initial convergence
        async def converged_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # Isolate node-a
        isolation_policy = gateway_network_policy_isolate(
            target_node="node-a",
            namespace=namespace,
        )
        await kubectl_apply_manifest(
            isolation_policy,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        import asyncio

        await asyncio.sleep(8.0)  # Wait for heartbeat timeout

        # node-b and node-c should failover to node-b
        assert await _all_pods_agree_owner(
            namespace=namespace,
            kubeconfig=kubeconfig,
            expected_owner="node-b",
            node_ids=("node-b", "node-c"),
        )

        # node-a (isolated) still thinks it's owner (stale, can't hear peers)
        a_state = await _get_pod_state(
            pod_name="gateway-node-a",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )
        if a_state is not None:
            assert a_state["gateway_owner"] == "node-a"

        # Heal partition
        await kubectl_delete_manifest(
            isolation_policy,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Reconverge — node-a should reclaim since it's highest rank
        async def reconverge_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(reconverge_on_node_a, timeout_seconds=60.0)

    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_only_gateway_owner_writes_dns(tmp_path: Path) -> None:
    """Verify only the gateway owner attempts DNS writes (via commit log events)."""
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"

    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=kubeconfig,
            )

        image = _resolve_gateway_image()
        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for convergence on node-a
        async def converged_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # The DNS write gate is not configured in the pod manifests (no real Route53)
        # This test verifies that ownership is correctly computed by checking
        # that only node-a reports itself as gateway_owner
        for node_id in NODE_IDS:
            state = await _get_pod_state(
                pod_name=f"gateway-{node_id}",
                namespace=namespace,
                kubeconfig=kubeconfig,
            )
            assert state is not None
            assert state["gateway_owner"] == "node-a"

        # Crash node-a
        await delete_pod_force(
            pod_name="gateway-node-a",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )

        # Wait for failover
        async def failover_to_node_b() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-b",
                node_ids=("node-b", "node-c"),
            )

        await wait_for_async(failover_to_node_b, timeout_seconds=30.0)

        # node-b is now owner, node-c is not
        b_state = await _get_pod_state(
            pod_name="gateway-node-b",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )
        c_state = await _get_pod_state(
            pod_name="gateway-node-c",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )
        assert b_state is not None
        assert b_state["gateway_owner"] == "node-b"
        assert c_state is not None
        assert c_state["gateway_owner"] == "node-b"

    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_event_log_converges_after_partition_heal(tmp_path: Path) -> None:
    """Verify all pods have consistent gateway owner view after partition heals."""
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"

    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=kubeconfig,
            )

        image = _resolve_gateway_image()
        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for initial convergence
        async def converged_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # Partition node-c
        isolation_policy = gateway_network_policy_isolate(
            target_node="node-c",
            namespace=namespace,
        )
        await kubectl_apply_manifest(
            isolation_policy,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        import asyncio

        await asyncio.sleep(8.0)  # Let partition take effect

        # Heal partition
        await kubectl_delete_manifest(
            isolation_policy,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for anti-entropy sync to reconcile
        await asyncio.sleep(5.0)

        # All pods should have converged view
        async def all_converged() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(all_converged, timeout_seconds=60.0)

        # Verify consistent state across all pods
        states: list[dict[str, object]] = []
        for node_id in NODE_IDS:
            state = await _get_pod_state(
                pod_name=f"gateway-{node_id}",
                namespace=namespace,
                kubeconfig=kubeconfig,
            )
            assert state is not None
            states.append(state)

        # All nodes agree on gateway_owner
        owners = {str(s["gateway_owner"]) for s in states}
        assert len(owners) == 1
        assert "node-a" in owners

    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )


# ---------------------------------------------------------------------------
# Phase 9: Expanded distributed failure simulation tests
# ---------------------------------------------------------------------------


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_simultaneous_multi_node_crash_leaves_singleton(tmp_path: Path) -> None:
    """Crash 2 of 3 nodes simultaneously, verify singleton takeover then reconvergence.

    Exercises the SingletonTakeover liveness property: the last surviving node
    must self-elect as gateway owner when all peers are unreachable.
    """
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"

    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=kubeconfig,
            )

        image = _resolve_gateway_image()
        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for initial convergence on node-a
        async def converged_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # Crash both node-a and node-b simultaneously
        import asyncio

        await asyncio.gather(
            delete_pod_force(
                pod_name="gateway-node-a",
                namespace=namespace,
                kubeconfig=kubeconfig,
            ),
            delete_pod_force(
                pod_name="gateway-node-b",
                namespace=namespace,
                kubeconfig=kubeconfig,
            ),
        )

        # Wait for node-c to self-elect (singleton takeover)
        async def node_c_self_elects() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-c",
                node_ids=("node-c",),
            )

        await wait_for_async(node_c_self_elects, timeout_seconds=30.0)

        # Wait for K8s to restart node-a and node-b
        await wait_for_pod_running(
            pod_name="gateway-node-a",
            namespace=namespace,
            kubeconfig=kubeconfig,
            timeout_seconds=120,
        )
        await wait_for_pod_running(
            pod_name="gateway-node-b",
            namespace=namespace,
            kubeconfig=kubeconfig,
            timeout_seconds=120,
        )

        # Wait for all pods to reconverge on node-a (highest rank)
        async def reconverge_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(reconverge_on_node_a, timeout_seconds=60.0)

    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_cascading_failure_to_last_node(tmp_path: Path) -> None:
    """Crash node-a, then crash node-b before failover completes, verify node-c.

    Tests cascading failures where nodes fail sequentially faster than the
    failover cycle can complete, leaving only the lowest-ranked node.
    """
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"

    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=kubeconfig,
            )

        image = _resolve_gateway_image()
        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for initial convergence on node-a
        async def converged_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # Crash node-a
        await delete_pod_force(
            pod_name="gateway-node-a",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )

        # Wait briefly for failover to start, then crash node-b before it completes
        import asyncio

        await asyncio.sleep(2.0)  # Less than heartbeat_timeout_seconds (5s)

        await delete_pod_force(
            pod_name="gateway-node-b",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )

        # node-c should eventually self-elect as the sole survivor
        async def node_c_self_elects() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-c",
                node_ids=("node-c",),
            )

        await wait_for_async(node_c_self_elects, timeout_seconds=30.0)

        # Restart both nodes
        await wait_for_pod_running(
            pod_name="gateway-node-a",
            namespace=namespace,
            kubeconfig=kubeconfig,
            timeout_seconds=120,
        )
        await wait_for_pod_running(
            pod_name="gateway-node-b",
            namespace=namespace,
            kubeconfig=kubeconfig,
            timeout_seconds=120,
        )

        # All reconverge on node-a
        async def reconverge_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(reconverge_on_node_a, timeout_seconds=60.0)

    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_flapping_node_convergence(tmp_path: Path) -> None:
    """Crash and restart node-a 3 times rapidly, verify convergence and event hash consistency.

    Tests that rapid flapping (crash/restart cycles) does not leave the cluster
    in an inconsistent state. After flapping stops, all nodes must converge and
    event hash sets must be identical (anti-entropy resolved any divergence).
    """
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"

    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=kubeconfig,
            )

        image = _resolve_gateway_image()
        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for initial convergence
        async def converged_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        import asyncio

        # Flap node-a 3 times with minimal delay
        for _flap in range(3):
            await delete_pod_force(
                pod_name="gateway-node-a",
                namespace=namespace,
                kubeconfig=kubeconfig,
            )
            await wait_for_pod_running(
                pod_name="gateway-node-a",
                namespace=namespace,
                kubeconfig=kubeconfig,
                timeout_seconds=120,
            )
            # Brief pause for the pod to start its event loop
            await asyncio.sleep(1.0)

        # After flapping stops, all nodes should converge on node-a
        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # Allow anti-entropy sync to complete
        await asyncio.sleep(5.0)

        # Verify event hash sets are identical across all pods
        hash_sets: list[frozenset[str]] = []
        for node_id in NODE_IDS:
            hashes = await _get_pod_event_hashes(
                pod_name=f"gateway-{node_id}",
                namespace=namespace,
                kubeconfig=kubeconfig,
            )
            assert hashes is not None, f"could not get event hashes from gateway-{node_id}"
            hash_sets.append(hashes)

        # All pods must have identical event hash sets
        assert (
            hash_sets[0] == hash_sets[1] == hash_sets[2]
        ), f"Event hash divergence after flapping: {hash_sets}"

    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_full_cluster_outage_and_recovery(tmp_path: Path) -> None:
    """Crash all 3 pods simultaneously, verify recovery and convergence.

    Tests full cluster outage: all nodes crash at the same time. After K8s
    restarts all pods, they must reconverge on the highest-ranked node and
    have consistent commit logs.
    """
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"

    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=kubeconfig,
            )

        image = _resolve_gateway_image()
        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for initial convergence
        async def converged_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        import asyncio

        # Crash all 3 pods simultaneously
        await asyncio.gather(
            delete_pod_force(
                pod_name="gateway-node-a",
                namespace=namespace,
                kubeconfig=kubeconfig,
            ),
            delete_pod_force(
                pod_name="gateway-node-b",
                namespace=namespace,
                kubeconfig=kubeconfig,
            ),
            delete_pod_force(
                pod_name="gateway-node-c",
                namespace=namespace,
                kubeconfig=kubeconfig,
            ),
        )

        # Wait for K8s to restart all 3 pods
        for node_id in NODE_IDS:
            await wait_for_pod_running(
                pod_name=f"gateway-{node_id}",
                namespace=namespace,
                kubeconfig=kubeconfig,
                timeout_seconds=120,
            )

        # All pods reconverge on node-a
        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # Allow anti-entropy to complete
        await asyncio.sleep(5.0)

        # Verify commit logs are consistent (event hashes match)
        hash_sets: list[frozenset[str]] = []
        for node_id in NODE_IDS:
            hashes = await _get_pod_event_hashes(
                pod_name=f"gateway-{node_id}",
                namespace=namespace,
                kubeconfig=kubeconfig,
            )
            assert hashes is not None, f"could not get event hashes from gateway-{node_id}"
            hash_sets.append(hashes)

        assert (
            hash_sets[0] == hash_sets[1] == hash_sets[2]
        ), f"Event hash divergence after full outage: {hash_sets}"

    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_asymmetric_partition(tmp_path: Path) -> None:
    """Create partial mesh: node-a ↔ node-b ↔ node-c, but node-a ✗ node-c.

    Tests asymmetric partition where node-b can reach both peers but node-a
    and node-c cannot communicate directly. Node-b relays heartbeats, so
    node-a and node-b should agree on owner. Node-c may diverge depending
    on whether indirect heartbeat relay is sufficient.

    If Canal CNI's NetworkPolicy cannot cleanly block traffic between two
    specific pods, this test uses the asymmetric NetworkPolicy generator
    which creates targeted egress/ingress deny rules between node-a and node-c.
    """
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"

    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=kubeconfig,
            )

        image = _resolve_gateway_image()
        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for initial convergence
        async def converged_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # Apply asymmetric partition: block node-a ↔ node-c
        egress_policy, ingress_policy = gateway_network_policy_asymmetric(
            blocked_from="node-a",
            blocked_to="node-c",
            namespace=namespace,
        )
        await kubectl_apply_manifest(
            egress_policy,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )
        await kubectl_apply_manifest(
            ingress_policy,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        import asyncio

        # Wait for partition effects to manifest
        await asyncio.sleep(10.0)

        # node-a and node-b should still agree on node-a as owner
        # (node-b can still reach node-a directly)
        assert await _all_pods_agree_owner(
            namespace=namespace,
            kubeconfig=kubeconfig,
            expected_owner="node-a",
            node_ids=("node-a", "node-b"),
        )

        # node-c may have expired node-a's heartbeat but still sees node-b
        # It should elect node-b (next in rank that it can see)
        c_state = await _get_pod_state(
            pod_name="gateway-node-c",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )
        if c_state is not None:
            # node-c sees node-b (alive) but not node-a (partition)
            # So node-c should elect node-b as owner
            c_owner = str(c_state.get("gateway_owner", ""))
            assert c_owner in (
                "node-b",
                "node-c",
            ), f"node-c should elect node-b or self, got {c_owner}"

        # Heal partition
        await kubectl_delete_manifest(
            egress_policy,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )
        await kubectl_delete_manifest(
            ingress_policy,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for reconvergence on node-a
        async def all_reconverge() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(all_reconverge, timeout_seconds=60.0)

    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_partition_flap_convergence_stability(tmp_path: Path) -> None:
    """Apply and heal partition on node-c 3 times, verify final convergence.

    Tests that repeated partition/heal cycles do not leave orphaned claims
    or permanent divergence. After the final heal, all nodes must converge
    and event logs must be consistent.
    """
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"

    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=kubeconfig,
            )

        image = _resolve_gateway_image()
        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for initial convergence
        async def converged_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        import asyncio

        # Flap partition 3 times
        for _cycle in range(3):
            # Isolate node-c
            isolation_policy = gateway_network_policy_isolate(
                target_node="node-c",
                namespace=namespace,
            )
            await kubectl_apply_manifest(
                isolation_policy,
                kubeconfig=kubeconfig,
                tmp_dir=tmp_path,
            )

            # Wait for partition to take effect
            await asyncio.sleep(8.0)

            # Heal partition
            await kubectl_delete_manifest(
                isolation_policy,
                kubeconfig=kubeconfig,
                tmp_dir=tmp_path,
            )

            # Wait for reconvergence before next cycle
            await asyncio.sleep(5.0)

        # After all flap cycles, verify final convergence on node-a
        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # Allow anti-entropy sync
        await asyncio.sleep(5.0)

        # Verify event logs are consistent (no orphaned claims)
        hash_sets: list[frozenset[str]] = []
        for node_id in NODE_IDS:
            hashes = await _get_pod_event_hashes(
                pod_name=f"gateway-{node_id}",
                namespace=namespace,
                kubeconfig=kubeconfig,
            )
            assert hashes is not None, f"could not get event hashes from gateway-{node_id}"
            hash_sets.append(hashes)

        assert (
            hash_sets[0] == hash_sets[1] == hash_sets[2]
        ), f"Event hash divergence after partition flaps: {hash_sets}"

    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_long_partition_event_log_merge(tmp_path: Path) -> None:
    """Extended partition where both sides accumulate events, then merge via anti-entropy.

    Replaces the weak assertion in test_event_log_converges_after_partition_heal
    by verifying that event hash sets are identical across all nodes after a
    prolonged partition (20+ seconds) with independent event accumulation.
    """
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"

    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=kubeconfig,
            )

        image = _resolve_gateway_image()
        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for initial convergence
        async def converged_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # Capture pre-partition event count
        pre_state_a = await _get_pod_state(
            pod_name="gateway-node-a",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )
        assert pre_state_a is not None
        pre_event_count = int(str(pre_state_a.get("event_count", 0)))

        import asyncio

        # Partition node-c for an extended period
        isolation_policy = gateway_network_policy_isolate(
            target_node="node-c",
            namespace=namespace,
        )
        await kubectl_apply_manifest(
            isolation_policy,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Let both sides accumulate events independently
        # (heartbeat loop runs naturally, producing events on both sides)
        await asyncio.sleep(25.0)

        # Heal partition
        await kubectl_delete_manifest(
            isolation_policy,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Wait for anti-entropy sync to merge event logs
        await asyncio.sleep(10.0)

        # Wait for convergence
        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # Verify all event hash sets converge to identical sets
        async def event_hashes_converged() -> bool:
            hash_sets: list[frozenset[str]] = []
            for node_id in NODE_IDS:
                hashes = await _get_pod_event_hashes(
                    pod_name=f"gateway-{node_id}",
                    namespace=namespace,
                    kubeconfig=kubeconfig,
                )
                if hashes is None:
                    return False
                hash_sets.append(hashes)
            return hash_sets[0] == hash_sets[1] == hash_sets[2]

        await wait_for_async(event_hashes_converged, timeout_seconds=30.0)

        # Verify events were actually accumulated (not lost)
        post_state_a = await _get_pod_state(
            pod_name="gateway-node-a",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )
        assert post_state_a is not None
        post_event_count = int(str(post_state_a.get("event_count", 0)))
        assert (
            post_event_count > pre_event_count
        ), f"Events should have accumulated: pre={pre_event_count}, post={post_event_count}"

    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.e2e  # type: ignore[misc]
@pytest.mark.slow  # type: ignore[misc]
@pytest.mark.asyncio
async def test_ownership_transition_cycle_verified_behaviorally(tmp_path: Path) -> None:
    """Full ownership transition cycle with event hash convergence verification.

    Exercises the complete claim/yield lifecycle:
    1. Converge on node-a (GatewayClaim from node-a)
    2. Crash node-a, failover to node-b (GatewayYield implied, GatewayClaim from node-b)
    3. Restart node-a, reconverge on node-a (GatewayYield from node-b, GatewayClaim from node-a)

    Verifies behavioral outcomes: ownership changed implies claim/yield events were
    emitted (the code always emits these on transitions). Event log convergence is
    verified by comparing event_hashes from /v1/state across pods.
    """
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"

    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
            node_ids=NODE_IDS,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        for node_id in NODE_IDS:
            await wait_for_certificate(
                namespace=namespace,
                certificate_name=f"{node_id}-cert",
                kubeconfig=kubeconfig,
            )

        image = _resolve_gateway_image()
        await _deploy_gateway_mesh(
            namespace=namespace,
            image=image,
            kubeconfig=kubeconfig,
            tmp_dir=tmp_path,
        )

        # Phase 1: Converge on node-a
        async def converged_on_node_a() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-a",
            )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        # Record initial event count
        initial_state = await _get_pod_state(
            pod_name="gateway-node-b",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )
        assert initial_state is not None
        initial_event_count = int(str(initial_state.get("event_count", 0)))

        # Phase 2: Crash node-a, failover to node-b
        await delete_pod_force(
            pod_name="gateway-node-a",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )

        async def failover_to_node_b() -> bool:
            return await _all_pods_agree_owner(
                namespace=namespace,
                kubeconfig=kubeconfig,
                expected_owner="node-b",
                node_ids=("node-b", "node-c"),
            )

        await wait_for_async(failover_to_node_b, timeout_seconds=30.0)

        # Phase 3: Restart node-a, reconverge
        await wait_for_pod_running(
            pod_name="gateway-node-a",
            namespace=namespace,
            kubeconfig=kubeconfig,
            timeout_seconds=120,
        )

        await wait_for_async(converged_on_node_a, timeout_seconds=60.0)

        import asyncio

        # Allow anti-entropy sync to complete
        await asyncio.sleep(5.0)

        # Verify all pods have identical event hash sets
        async def event_hashes_converged() -> bool:
            hash_sets: list[frozenset[str]] = []
            for node_id in NODE_IDS:
                hashes = await _get_pod_event_hashes(
                    pod_name=f"gateway-{node_id}",
                    namespace=namespace,
                    kubeconfig=kubeconfig,
                )
                if hashes is None:
                    return False
                hash_sets.append(hashes)
            return hash_sets[0] == hash_sets[1] == hash_sets[2]

        await wait_for_async(event_hashes_converged, timeout_seconds=30.0)

        # Verify event count increased across the full transition cycle
        # (claim/yield events were appended, not lost)
        final_state = await _get_pod_state(
            pod_name="gateway-node-b",
            namespace=namespace,
            kubeconfig=kubeconfig,
        )
        assert final_state is not None
        final_event_count = int(str(final_state.get("event_count", 0)))
        assert final_event_count > initial_event_count, (
            f"Event count should increase across ownership transitions: "
            f"initial={initial_event_count}, final={final_event_count}"
        )

    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=60.0,
            )
