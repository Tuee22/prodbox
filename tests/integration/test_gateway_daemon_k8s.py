"""Kubernetes-backed integration tests for gateway daemon (local process mode)."""

from __future__ import annotations

import json
import uuid
from contextlib import suppress
from pathlib import Path

import pytest

from prodbox.gateway_daemon import ConnectionKey, DaemonConfig, GatewayDaemon

from .conftest import (
    apply_cert_manifest,
    require_rke2_and_cert_manager,
    resolve_kubeconfig,
    wait_for_certificate,
    write_tls_material,
)
from .helpers import free_port, run_kubectl_capture_via_dag, wait_for_async


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
            "heartbeat_timeout_seconds": 3,
        },
    }


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.asyncio
async def test_gateway_daemon_mesh_rejoin_and_sync(tmp_path: Path) -> None:
    kubeconfig = resolve_kubeconfig()
    await require_rke2_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-it-{uuid.uuid4().hex[:8]}"
    daemons: dict[str, GatewayDaemon] = {}
    try:
        await apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="node-a-cert",
            kubeconfig=kubeconfig,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="node-b-cert",
            kubeconfig=kubeconfig,
        )
        await wait_for_certificate(
            namespace=namespace,
            certificate_name="node-c-cert",
            kubeconfig=kubeconfig,
        )

        certs_dir = tmp_path / "certs"
        certs_dir.mkdir(parents=True, exist_ok=True)
        a_tls = await write_tls_material(
            namespace=namespace,
            secret_name="node-a-tls",
            root_secret_name="root-ca-secret",
            kubeconfig=kubeconfig,
            output_dir=certs_dir,
            file_prefix="node-a",
        )
        b_tls = await write_tls_material(
            namespace=namespace,
            secret_name="node-b-tls",
            root_secret_name="root-ca-secret",
            kubeconfig=kubeconfig,
            output_dir=certs_dir,
            file_prefix="node-b",
        )
        c_tls = await write_tls_material(
            namespace=namespace,
            secret_name="node-c-tls",
            root_secret_name="root-ca-secret",
            kubeconfig=kubeconfig,
            output_dir=certs_dir,
            file_prefix="node-c",
        )

        ports = {
            "node-a": (free_port(), free_port()),
            "node-b": (free_port(), free_port()),
            "node-c": (free_port(), free_port()),
        }
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_with_ports(ports)), encoding="utf-8")

        event_keys = {"node-a": "key-a", "node-b": "key-b", "node-c": "key-c"}

        config_a = DaemonConfig(
            node_id="node-a",
            cert_file=a_tls.cert_file,
            key_file=a_tls.key_file,
            ca_file=a_tls.ca_file,
            orders_file=orders_path,
            event_keys=event_keys,
            heartbeat_interval_seconds=0.2,
            reconnect_interval_seconds=0.2,
            sync_interval_seconds=0.5,
        )
        config_b = DaemonConfig(
            node_id="node-b",
            cert_file=b_tls.cert_file,
            key_file=b_tls.key_file,
            ca_file=b_tls.ca_file,
            orders_file=orders_path,
            event_keys=event_keys,
            heartbeat_interval_seconds=0.2,
            reconnect_interval_seconds=0.2,
            sync_interval_seconds=0.5,
        )
        config_c = DaemonConfig(
            node_id="node-c",
            cert_file=c_tls.cert_file,
            key_file=c_tls.key_file,
            ca_file=c_tls.ca_file,
            orders_file=orders_path,
            event_keys=event_keys,
            heartbeat_interval_seconds=0.2,
            reconnect_interval_seconds=0.2,
            sync_interval_seconds=0.5,
        )

        daemons["node-a"] = GatewayDaemon(config_a)
        daemons["node-b"] = GatewayDaemon(config_b)
        daemons["node-c"] = GatewayDaemon(config_c)

        await daemons["node-a"].start()
        await daemons["node-b"].start()
        await daemons["node-c"].start()

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

        daemons["node-b"] = GatewayDaemon(config_b)
        await daemons["node-b"].start()

        async def b_caught_up() -> bool:
            hashes = await daemons["node-b"].log_event_hashes()
            return event1.event_hash in hashes and event2.event_hash in hashes

        await wait_for_async(b_caught_up, timeout_seconds=30.0)

        for daemon in daemons.values():
            keys = await daemon.active_connection_keys()
            assert len(keys) == len(set(keys))

    finally:
        for daemon in tuple(daemons.values()):
            await daemon.stop()
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=30.0,
            )
