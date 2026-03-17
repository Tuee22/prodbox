"""Kubernetes-backed integration tests for gateway daemon (local process mode)."""

from __future__ import annotations

import json
import uuid
from collections.abc import AsyncIterator
from pathlib import Path
from typing import NamedTuple

import pytest
import pytest_asyncio

from prodbox.gateway_daemon import ConnectionKey, DaemonConfig, GatewayDaemon

from .conftest import (
    TlsMaterial,
    abort_test_session_on_teardown_failure,
    apply_cert_manifest,
    wait_for_certificate,
    write_tls_material,
)
from .helpers import free_port, run_kubectl_capture_via_dag, wait_for_async

pytestmark = pytest.mark.timeout(300)
HEARTBEAT_TIMEOUT_SECONDS = 3


class GatewayDaemonTlsContext(NamedTuple):
    """Cluster TLS material for one gateway-daemon integration test."""

    kubeconfig: Path
    namespace: str
    a_tls: TlsMaterial
    b_tls: TlsMaterial
    c_tls: TlsMaterial


class GatewayDaemonMeshContext(NamedTuple):
    """Running daemon mesh plus configs for restart scenarios."""

    daemons: dict[str, GatewayDaemon]
    configs: dict[str, DaemonConfig]


def _orders_with_ports(ports: dict[str, tuple[int, int]]) -> dict[str, object]:
    return {
        "version_utc": 1000,
        "nodes": [
            {
                "node_id": "node-a",
                "stable_dns_name": "node-a.prodbox.resolvefintech.com",
                "rest_host": "127.0.0.1",
                "rest_port": ports["node-a"][0],
                "socket_host": "127.0.0.1",
                "socket_port": ports["node-a"][1],
            },
            {
                "node_id": "node-b",
                "stable_dns_name": "node-b.prodbox.resolvefintech.com",
                "rest_host": "127.0.0.1",
                "rest_port": ports["node-b"][0],
                "socket_host": "127.0.0.1",
                "socket_port": ports["node-b"][1],
            },
            {
                "node_id": "node-c",
                "stable_dns_name": "node-c.prodbox.resolvefintech.com",
                "rest_host": "127.0.0.1",
                "rest_port": ports["node-c"][0],
                "socket_host": "127.0.0.1",
                "socket_port": ports["node-c"][1],
            },
        ],
        "gateway_rule": {
            "ranked_nodes": ["node-a", "node-b", "node-c"],
            "heartbeat_timeout_seconds": HEARTBEAT_TIMEOUT_SECONDS,
        },
    }


async def _wait_for_full_mesh(daemons: dict[str, GatewayDaemon]) -> None:
    """Wait until every daemon has mesh connections to both peers."""

    async def all_mesh_connected() -> bool:
        expected = {
            "node-a": {
                ConnectionKey(peer_node_id="node-b", channel="mesh"),
                ConnectionKey(peer_node_id="node-c", channel="mesh"),
            },
            "node-b": {
                ConnectionKey(peer_node_id="node-a", channel="mesh"),
                ConnectionKey(peer_node_id="node-c", channel="mesh"),
            },
            "node-c": {
                ConnectionKey(peer_node_id="node-a", channel="mesh"),
                ConnectionKey(peer_node_id="node-b", channel="mesh"),
            },
        }
        for node_id, daemon in daemons.items():
            keys = set(await daemon.active_connection_keys())
            if not expected[node_id].issubset(keys):
                return False
        return True

    await wait_for_async(all_mesh_connected, timeout_seconds=30.0)


@pytest_asyncio.fixture
async def gateway_daemon_tls_context(
    cluster_kubeconfig: Path,
    tmp_path: Path,
) -> AsyncIterator[GatewayDaemonTlsContext]:
    """Provision per-test TLS material in a unique namespace."""
    namespace = f"prodbox-gw-it-{uuid.uuid4().hex[:8]}"
    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=cluster_kubeconfig,
            manifests_dir=tmp_path,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=cluster_kubeconfig,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="node-a-cert",
            kubeconfig=cluster_kubeconfig,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="node-b-cert",
            kubeconfig=cluster_kubeconfig,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="node-c-cert",
            kubeconfig=cluster_kubeconfig,
        )

        certs_dir = tmp_path / "certs"
        certs_dir.mkdir(parents=True, exist_ok=True)
        a_tls = await write_tls_material(
            namespace=namespace,
            secret_name="node-a-tls",
            root_secret_name="root-ca-secret",
            kubeconfig=cluster_kubeconfig,
            output_dir=certs_dir,
            file_prefix="node-a",
        )
        b_tls = await write_tls_material(
            namespace=namespace,
            secret_name="node-b-tls",
            root_secret_name="root-ca-secret",
            kubeconfig=cluster_kubeconfig,
            output_dir=certs_dir,
            file_prefix="node-b",
        )
        c_tls = await write_tls_material(
            namespace=namespace,
            secret_name="node-c-tls",
            root_secret_name="root-ca-secret",
            kubeconfig=cluster_kubeconfig,
            output_dir=certs_dir,
            file_prefix="node-c",
        )
    except Exception:
        rc, _, stderr = await run_kubectl_capture_via_dag(
            "delete",
            "namespace",
            namespace,
            "--ignore-not-found=true",
            "--wait=true",
            kubeconfig=cluster_kubeconfig,
            timeout=120.0,
        )
        if rc != 0:
            abort_test_session_on_teardown_failure(
                target=f"gateway daemon setup namespace {namespace}",
                error=AssertionError(stderr),
            )
        raise

    yield GatewayDaemonTlsContext(
        kubeconfig=cluster_kubeconfig,
        namespace=namespace,
        a_tls=a_tls,
        b_tls=b_tls,
        c_tls=c_tls,
    )

    try:
        rc, _, stderr = await run_kubectl_capture_via_dag(
            "delete",
            "namespace",
            namespace,
            "--ignore-not-found=true",
            "--wait=true",
            kubeconfig=cluster_kubeconfig,
            timeout=120.0,
        )
        if rc != 0:
            raise AssertionError(stderr)
    except Exception as error:
        abort_test_session_on_teardown_failure(
            target=f"gateway daemon namespace {namespace}",
            error=error,
        )


@pytest_asyncio.fixture
async def gateway_daemon_mesh_context(
    gateway_daemon_tls_context: GatewayDaemonTlsContext,
    tmp_path: Path,
) -> AsyncIterator[GatewayDaemonMeshContext]:
    """Start a three-node daemon mesh and stop it during fixture teardown."""
    ports = {
        "node-a": (free_port(), free_port()),
        "node-b": (free_port(), free_port()),
        "node-c": (free_port(), free_port()),
    }
    orders_path = tmp_path / "orders.json"
    orders_path.write_text(json.dumps(_orders_with_ports(ports)), encoding="utf-8")

    event_keys = {"node-a": "key-a", "node-b": "key-b", "node-c": "key-c"}
    configs = {
        "node-a": DaemonConfig(
            node_id="node-a",
            cert_file=gateway_daemon_tls_context.a_tls.cert_file,
            key_file=gateway_daemon_tls_context.a_tls.key_file,
            ca_file=gateway_daemon_tls_context.a_tls.ca_file,
            orders_file=orders_path,
            event_keys=event_keys,
            heartbeat_interval_seconds=0.2,
            reconnect_interval_seconds=0.2,
            sync_interval_seconds=0.5,
        ),
        "node-b": DaemonConfig(
            node_id="node-b",
            cert_file=gateway_daemon_tls_context.b_tls.cert_file,
            key_file=gateway_daemon_tls_context.b_tls.key_file,
            ca_file=gateway_daemon_tls_context.b_tls.ca_file,
            orders_file=orders_path,
            event_keys=event_keys,
            heartbeat_interval_seconds=0.2,
            reconnect_interval_seconds=0.2,
            sync_interval_seconds=0.5,
        ),
        "node-c": DaemonConfig(
            node_id="node-c",
            cert_file=gateway_daemon_tls_context.c_tls.cert_file,
            key_file=gateway_daemon_tls_context.c_tls.key_file,
            ca_file=gateway_daemon_tls_context.c_tls.ca_file,
            orders_file=orders_path,
            event_keys=event_keys,
            heartbeat_interval_seconds=0.2,
            reconnect_interval_seconds=0.2,
            sync_interval_seconds=0.5,
        ),
    }
    daemons = {
        "node-a": GatewayDaemon(configs["node-a"]),
        "node-b": GatewayDaemon(configs["node-b"]),
        "node-c": GatewayDaemon(configs["node-c"]),
    }

    try:
        await daemons["node-a"].start()
        await daemons["node-b"].start()
        await daemons["node-c"].start()
        await _wait_for_full_mesh(daemons)
    except Exception:
        for node_id, daemon in tuple(daemons.items()):
            try:
                await daemon.stop()
            except Exception as cleanup_error:
                abort_test_session_on_teardown_failure(
                    target=f"gateway daemon setup cleanup {node_id}",
                    error=cleanup_error,
                )
        raise

    yield GatewayDaemonMeshContext(daemons=daemons, configs=configs)

    for node_id, daemon in tuple(daemons.items()):
        try:
            await daemon.stop()
        except Exception as error:
            abort_test_session_on_teardown_failure(
                target=f"gateway daemon {node_id}",
                error=error,
            )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.asyncio
async def test_gateway_daemon_mesh_rejoin_and_sync(
    gateway_daemon_mesh_context: GatewayDaemonMeshContext,
) -> None:
    daemons = gateway_daemon_mesh_context.daemons

    event1 = await daemons["node-a"].emit_event("domain_event", {"step": 1})

    async def c_received_event1() -> bool:
        return event1.event_hash in await daemons["node-c"].log_event_hashes()

    await wait_for_async(c_received_event1, timeout_seconds=20.0)

    await daemons["node-b"].stop()
    daemons.pop("node-b")

    event2 = await daemons["node-a"].emit_event("domain_event", {"step": 2})

    async def c_received_event2() -> bool:
        return event2.event_hash in await daemons["node-c"].log_event_hashes()

    await wait_for_async(c_received_event2, timeout_seconds=20.0)

    daemons["node-b"] = GatewayDaemon(gateway_daemon_mesh_context.configs["node-b"])
    await daemons["node-b"].start()
    await _wait_for_full_mesh(daemons)

    async def b_caught_up() -> bool:
        hashes = await daemons["node-b"].log_event_hashes()
        return event1.event_hash in hashes and event2.event_hash in hashes

    await wait_for_async(b_caught_up, timeout_seconds=30.0)

    for daemon in daemons.values():
        keys = await daemon.active_connection_keys()
        assert len(keys) == len(set(keys))
