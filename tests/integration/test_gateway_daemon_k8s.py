"""Kubernetes-backed integration tests for gateway daemon."""

from __future__ import annotations

import asyncio
import base64
import json
import os
import shutil
import socket
import uuid
from contextlib import suppress
from pathlib import Path

import pytest

from prodbox.cli.command_adt import rke2_ensure_command
from prodbox.cli.dag_builders import command_to_dag
from prodbox.cli.effect_dag import EffectDAG, EffectNode
from prodbox.cli.effects import CaptureKubectlOutput, ValidateTool
from prodbox.cli.interpreter import create_interpreter
from prodbox.cli.types import Failure, Success
from prodbox.gateway_daemon import ConnectionKey, DaemonConfig, GatewayDaemon


def _resolve_kubeconfig() -> Path:
    raw_kubeconfig = os.environ.get("KUBECONFIG")
    if raw_kubeconfig:
        return Path(raw_kubeconfig).expanduser()
    return Path.home() / ".kube" / "config"


async def _run_kubectl_capture_via_dag(
    *args: str,
    kubeconfig: Path,
    namespace: str | None = None,
    timeout: float | None = None,
) -> tuple[int, str, str]:
    validate_effect_id = f"validate_kubectl_{uuid.uuid4().hex}"
    command_effect_id = f"kubectl_capture_{uuid.uuid4().hex}"

    validate_node = EffectNode(
        effect=ValidateTool(
            effect_id=validate_effect_id,
            description="Validate kubectl is installed",
            tool_name="kubectl",
        )
    )
    command_node = EffectNode(
        effect=CaptureKubectlOutput(
            effect_id=command_effect_id,
            description=f"kubectl {' '.join(args)}",
            args=list(args),
            kubeconfig=kubeconfig,
            namespace=namespace,
            timeout=timeout,
        ),
        prerequisites=frozenset([validate_effect_id]),
    )
    dag = EffectDAG(
        nodes=frozenset([validate_node, command_node]),
        roots=frozenset([command_effect_id]),
    )

    interpreter = create_interpreter()
    _, node_values = await interpreter.interpret_dag_with_values(dag)

    node_result = node_values.get(command_effect_id)
    if node_result is None:
        return (1, "", "missing kubectl result from DAG")
    match node_result:
        case Success(value):
            if not isinstance(value, tuple) or len(value) != 3:
                return (1, "", "invalid kubectl output tuple")
            returncode, stdout, stderr = value
            if not isinstance(returncode, int):
                return (1, "", "invalid kubectl returncode type")
            if not isinstance(stdout, str):
                return (1, "", "invalid kubectl stdout type")
            if not isinstance(stderr, str):
                return (1, "", "invalid kubectl stderr type")
            return (returncode, stdout, stderr)
        case Failure(error):
            return (1, "", str(error))


async def _require_k8s_and_cert_manager(kubeconfig: Path) -> None:
    if shutil.which("kubectl") is None:
        pytest.skip("kubectl not installed")
    if not kubeconfig.exists():
        pytest.skip(f"kubeconfig not found: {kubeconfig}")
    await _ensure_rke2_via_dag()

    cluster_rc, _, _ = await _run_kubectl_capture_via_dag(
        "cluster-info",
        kubeconfig=kubeconfig,
        timeout=30.0,
    )
    if cluster_rc != 0:
        pytest.skip("kubectl cluster-info failed")

    cert_manager_rc, _, _ = await _run_kubectl_capture_via_dag(
        "get",
        "crd",
        "certificates.cert-manager.io",
        kubeconfig=kubeconfig,
        timeout=30.0,
    )
    if cert_manager_rc != 0:
        pytest.skip("cert-manager CRD not available")


async def _ensure_rke2_via_dag() -> None:
    match rke2_ensure_command():
        case Failure(error):
            pytest.skip(f"rke2 ensure command unavailable: {error}")
        case Success(command):
            match command_to_dag(command):
                case Failure(error):
                    raise AssertionError(f"failed to build rke2 ensure DAG: {error}")
                case Success(dag):
                    interpreter = create_interpreter()
                    summary = await interpreter.interpret_dag(dag)
                    if summary.exit_code != 0:
                        pytest.skip("rke2 ensure DAG failed")


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        return int(s.getsockname()[1])


async def _apply_cert_manifest(
    *,
    namespace: str,
    kubeconfig: Path,
    manifests_dir: Path,
) -> None:
    manifest = f"""
apiVersion: v1
kind: Namespace
metadata:
  name: {namespace}
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-root
  namespace: {namespace}
spec:
  selfSigned: {{}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: root-ca
  namespace: {namespace}
spec:
  isCA: true
  commonName: prodbox-root-ca
  secretName: root-ca-secret
  issuerRef:
    name: selfsigned-root
    kind: Issuer
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: root-ca-issuer
  namespace: {namespace}
spec:
  ca:
    secretName: root-ca-secret
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: node-a-cert
  namespace: {namespace}
spec:
  secretName: node-a-tls
  commonName: node-a
  dnsNames:
  - node-a
  - localhost
  issuerRef:
    name: root-ca-issuer
    kind: Issuer
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: node-b-cert
  namespace: {namespace}
spec:
  secretName: node-b-tls
  commonName: node-b
  dnsNames:
  - node-b
  - localhost
  issuerRef:
    name: root-ca-issuer
    kind: Issuer
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: node-c-cert
  namespace: {namespace}
spec:
  secretName: node-c-tls
  commonName: node-c
  dnsNames:
  - node-c
  - localhost
  issuerRef:
    name: root-ca-issuer
    kind: Issuer
"""
    manifest_path = manifests_dir / f"{namespace}-certs.yaml"
    manifest_path.write_text(manifest, encoding="utf-8")
    returncode, _, stderr = await _run_kubectl_capture_via_dag(
        "apply",
        "-f",
        str(manifest_path),
        kubeconfig=kubeconfig,
        timeout=60.0,
    )
    if returncode != 0:
        raise AssertionError(f"kubectl apply failed: {stderr}")


async def _wait_for_certificate(
    *,
    namespace: str,
    certificate_name: str,
    kubeconfig: Path,
    timeout_seconds: int = 180,
) -> None:
    returncode, _, stderr = await _run_kubectl_capture_via_dag(
        "wait",
        "--for=condition=Ready",
        f"certificate/{certificate_name}",
        f"--timeout={timeout_seconds}s",
        kubeconfig=kubeconfig,
        namespace=namespace,
        timeout=float(timeout_seconds) + 10.0,
    )
    if returncode != 0:
        raise AssertionError(f"certificate {certificate_name} not ready: {stderr}")


async def _write_tls_material(
    *,
    namespace: str,
    secret_name: str,
    root_secret_name: str,
    kubeconfig: Path,
    output_dir: Path,
    file_prefix: str,
) -> tuple[Path, Path, Path]:
    secret_rc, secret_stdout, secret_stderr = await _run_kubectl_capture_via_dag(
        "get",
        "secret",
        secret_name,
        "-o",
        "json",
        kubeconfig=kubeconfig,
        namespace=namespace,
        timeout=30.0,
    )
    if secret_rc != 0:
        raise AssertionError(f"failed to get secret {secret_name}: {secret_stderr}")
    root_rc, root_stdout, root_stderr = await _run_kubectl_capture_via_dag(
        "get",
        "secret",
        root_secret_name,
        "-o",
        "json",
        kubeconfig=kubeconfig,
        namespace=namespace,
        timeout=30.0,
    )
    if root_rc != 0:
        raise AssertionError(f"failed to get root secret {root_secret_name}: {root_stderr}")

    secret_obj = json.loads(secret_stdout)
    root_obj = json.loads(root_stdout)
    secret_data = secret_obj.get("data")
    root_data = root_obj.get("data")
    if not isinstance(secret_data, dict):
        raise AssertionError("leaf secret data missing")
    if not isinstance(root_data, dict):
        raise AssertionError("root secret data missing")

    tls_crt_b64 = secret_data.get("tls.crt")
    tls_key_b64 = secret_data.get("tls.key")
    ca_crt_b64 = secret_data.get("ca.crt")
    if ca_crt_b64 is None:
        ca_crt_b64 = root_data.get("tls.crt")
    if not isinstance(tls_crt_b64, str):
        raise AssertionError("tls.crt missing")
    if not isinstance(tls_key_b64, str):
        raise AssertionError("tls.key missing")
    if not isinstance(ca_crt_b64, str):
        raise AssertionError("ca.crt missing")

    cert_file = output_dir / f"{file_prefix}.crt"
    key_file = output_dir / f"{file_prefix}.key"
    ca_file = output_dir / "ca.crt"
    cert_file.write_bytes(base64.b64decode(tls_crt_b64))
    key_file.write_bytes(base64.b64decode(tls_key_b64))
    if not ca_file.exists():
        ca_file.write_bytes(base64.b64decode(ca_crt_b64))
    return cert_file, key_file, ca_file


async def _wait_for_async(check: object, timeout_seconds: float = 20.0) -> None:
    if not callable(check):
        raise AssertionError("check must be callable")
    deadline = asyncio.get_event_loop().time() + timeout_seconds
    while True:
        result = check()
        if asyncio.iscoroutine(result):
            ok = await result
        else:
            ok = bool(result)
        if ok:
            return
        if asyncio.get_event_loop().time() >= deadline:
            raise AssertionError("condition not met before timeout")
        await asyncio.sleep(0.1)


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


@pytest.mark.integration
@pytest.mark.asyncio
async def test_gateway_daemon_mesh_rejoin_and_sync(tmp_path: Path) -> None:
    kubeconfig = _resolve_kubeconfig()
    await _require_k8s_and_cert_manager(kubeconfig)
    namespace = f"prodbox-gw-it-{uuid.uuid4().hex[:8]}"
    daemons: dict[str, GatewayDaemon] = {}
    try:
        await _apply_cert_manifest(
            namespace=namespace,
            kubeconfig=kubeconfig,
            manifests_dir=tmp_path,
        )
        await _wait_for_certificate(
            namespace=namespace,
            certificate_name="root-ca",
            kubeconfig=kubeconfig,
        )
        await _wait_for_certificate(
            namespace=namespace,
            certificate_name="node-a-cert",
            kubeconfig=kubeconfig,
        )
        await _wait_for_certificate(
            namespace=namespace,
            certificate_name="node-b-cert",
            kubeconfig=kubeconfig,
        )
        await _wait_for_certificate(
            namespace=namespace,
            certificate_name="node-c-cert",
            kubeconfig=kubeconfig,
        )

        certs_dir = tmp_path / "certs"
        certs_dir.mkdir(parents=True, exist_ok=True)
        a_cert, a_key, ca_file = await _write_tls_material(
            namespace=namespace,
            secret_name="node-a-tls",
            root_secret_name="root-ca-secret",
            kubeconfig=kubeconfig,
            output_dir=certs_dir,
            file_prefix="node-a",
        )
        b_cert, b_key, _ = await _write_tls_material(
            namespace=namespace,
            secret_name="node-b-tls",
            root_secret_name="root-ca-secret",
            kubeconfig=kubeconfig,
            output_dir=certs_dir,
            file_prefix="node-b",
        )
        c_cert, c_key, _ = await _write_tls_material(
            namespace=namespace,
            secret_name="node-c-tls",
            root_secret_name="root-ca-secret",
            kubeconfig=kubeconfig,
            output_dir=certs_dir,
            file_prefix="node-c",
        )

        ports = {
            "node-a": (_free_port(), _free_port()),
            "node-b": (_free_port(), _free_port()),
            "node-c": (_free_port(), _free_port()),
        }
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_with_ports(ports)), encoding="utf-8")

        event_keys = {"node-a": "key-a", "node-b": "key-b", "node-c": "key-c"}

        config_a = DaemonConfig(
            node_id="node-a",
            cert_file=a_cert,
            key_file=a_key,
            ca_file=ca_file,
            orders_file=orders_path,
            event_keys=event_keys,
            heartbeat_interval_seconds=0.2,
            reconnect_interval_seconds=0.2,
            sync_interval_seconds=0.5,
        )
        config_b = DaemonConfig(
            node_id="node-b",
            cert_file=b_cert,
            key_file=b_key,
            ca_file=ca_file,
            orders_file=orders_path,
            event_keys=event_keys,
            heartbeat_interval_seconds=0.2,
            reconnect_interval_seconds=0.2,
            sync_interval_seconds=0.5,
        )
        config_c = DaemonConfig(
            node_id="node-c",
            cert_file=c_cert,
            key_file=c_key,
            ca_file=ca_file,
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

        await _wait_for_async(all_mesh_connected, timeout_seconds=30.0)

        event1 = await daemons["node-a"].emit_event("domain_event", {"step": 1})

        async def c_received_event1() -> bool:
            return event1.event_hash in await daemons["node-c"].log_event_hashes()

        await _wait_for_async(c_received_event1, timeout_seconds=20.0)

        await daemons["node-b"].stop()
        daemons.pop("node-b")

        event2 = await daemons["node-a"].emit_event("domain_event", {"step": 2})

        async def c_received_event2() -> bool:
            return event2.event_hash in await daemons["node-c"].log_event_hashes()

        await _wait_for_async(c_received_event2, timeout_seconds=20.0)

        daemons["node-b"] = GatewayDaemon(config_b)
        await daemons["node-b"].start()

        async def b_caught_up() -> bool:
            hashes = await daemons["node-b"].log_event_hashes()
            return event1.event_hash in hashes and event2.event_hash in hashes

        await _wait_for_async(b_caught_up, timeout_seconds=30.0)

        for daemon in daemons.values():
            keys = await daemon.active_connection_keys()
            assert len(keys) == len(set(keys))

    finally:
        for daemon in tuple(daemons.values()):
            await daemon.stop()
        with suppress(Exception):
            await _run_kubectl_capture_via_dag(
                "delete",
                "namespace",
                namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig,
                timeout=30.0,
            )
