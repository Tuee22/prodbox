"""Shared fixtures for gateway daemon integration tests.

Fixture Contract
----------------
Each integration test must:

1. **Declaratively establish initial conditions** for the test in the K8s cluster
   using a unique testing namespace (generated via ``uuid.uuid4().hex[:8]``).
2. **Clean up** all resources in the ``finally`` block, including namespace deletion
   via ``kubectl delete namespace <ns> --ignore-not-found=true``.

This ensures test isolation: each test gets a fresh namespace with its own certs,
pods, services, and network policies. Namespace deletion cascades to all contained
resources, providing reliable cleanup even when tests fail.

The pattern used throughout:

.. code-block:: python

    namespace = f"prodbox-gw-e2e-{uuid.uuid4().hex[:8]}"
    try:
        # Provision certs, deploy pods, run assertions
        ...
    finally:
        with suppress(Exception):
            await run_kubectl_capture_via_dag(
                "delete", "namespace", namespace,
                "--ignore-not-found=true",
                kubeconfig=kubeconfig, timeout=60.0,
            )
"""

from __future__ import annotations

import base64
import json
import os
import shutil
import uuid
from contextlib import suppress
from pathlib import Path
from typing import NamedTuple, cast

from prodbox.cli.command_adt import rke2_ensure_command
from prodbox.cli.dag_builders import command_to_dag
from prodbox.cli.interpreter import create_interpreter
from prodbox.cli.types import Failure, Success

from .helpers import run_kubectl_capture_via_dag


class TlsMaterial(NamedTuple):
    """TLS certificate paths for a node."""

    cert_file: Path
    key_file: Path
    ca_file: Path


def resolve_kubeconfig() -> Path:
    """Resolve kubeconfig path from env or default."""
    raw_kubeconfig = os.environ.get("KUBECONFIG")
    if raw_kubeconfig:
        return Path(raw_kubeconfig).expanduser()
    return Path.home() / ".kube" / "config"


async def _ensure_rke2_via_dag() -> None:
    match rke2_ensure_command():
        case Failure(error):
            raise AssertionError(f"rke2 ensure command unavailable: {error}")
        case Success(command):
            match command_to_dag(command):
                case Failure(error):
                    raise AssertionError(f"failed to build rke2 ensure DAG: {error}")
                case Success(dag):
                    interpreter = create_interpreter()
                    summary = await interpreter.interpret_dag(dag)
                    if summary.exit_code != 0:
                        raise AssertionError("rke2 ensure DAG failed")


async def require_rke2_and_cert_manager(kubeconfig: Path) -> None:
    """Validate cluster reachable + cert-manager CRDs, failing fast on missing prerequisites."""
    if shutil.which("kubectl") is None:
        raise AssertionError("kubectl not installed")
    if not kubeconfig.exists():
        raise AssertionError(f"kubeconfig not found: {kubeconfig}")
    await _ensure_rke2_via_dag()

    cluster_rc, _, cluster_stderr = await run_kubectl_capture_via_dag(
        "cluster-info",
        kubeconfig=kubeconfig,
        timeout=30.0,
    )
    if cluster_rc != 0:
        raise AssertionError(f"kubectl cluster-info failed: {cluster_stderr}")

    cert_manager_rc, _, cert_manager_stderr = await run_kubectl_capture_via_dag(
        "get",
        "crd",
        "certificates.cert-manager.io",
        kubeconfig=kubeconfig,
        timeout=30.0,
    )
    if cert_manager_rc != 0:
        raise AssertionError(f"cert-manager CRD not available: {cert_manager_stderr}")


async def apply_cert_manifest(
    *,
    namespace: str,
    kubeconfig: Path,
    manifests_dir: Path,
    node_ids: tuple[str, ...] = ("node-a", "node-b", "node-c"),
) -> None:
    """Create namespace, selfsigned CA, and per-node certs via cert-manager."""
    cert_blocks = ""
    for node_id in node_ids:
        cert_blocks += f"""---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {node_id}-cert
  namespace: {namespace}
spec:
  secretName: {node_id}-tls
  commonName: {node_id}
  dnsNames:
  - {node_id}
  - gateway-{node_id}
  - gateway-{node_id}.{namespace}.svc.cluster.local
  - localhost
  issuerRef:
    name: root-ca-issuer
    kind: Issuer
"""

    manifest = f"""apiVersion: v1
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
{cert_blocks}"""

    manifest_path = manifests_dir / f"{namespace}-certs.yaml"
    manifest_path.write_text(manifest, encoding="utf-8")
    returncode, _, stderr = await run_kubectl_capture_via_dag(
        "apply",
        "-f",
        str(manifest_path),
        kubeconfig=kubeconfig,
        timeout=60.0,
    )
    if returncode != 0:
        raise AssertionError(f"kubectl apply failed: {stderr}")


async def wait_for_certificate(
    *,
    namespace: str,
    certificate_name: str,
    kubeconfig: Path,
    timeout_seconds: int = 180,
) -> None:
    """Wait for cert-manager Certificate to become Ready."""
    returncode, _, stderr = await run_kubectl_capture_via_dag(
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


async def write_tls_material(
    *,
    namespace: str,
    secret_name: str,
    root_secret_name: str,
    kubeconfig: Path,
    output_dir: Path,
    file_prefix: str,
) -> TlsMaterial:
    """Extract TLS material from K8s secrets to local files."""
    secret_rc, secret_stdout, secret_stderr = await run_kubectl_capture_via_dag(
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
    root_rc, root_stdout, root_stderr = await run_kubectl_capture_via_dag(
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

    secret_obj = cast(dict[str, object], json.loads(secret_stdout))
    root_obj = cast(dict[str, object], json.loads(root_stdout))
    secret_data_raw = secret_obj.get("data")
    root_data_raw = root_obj.get("data")
    if not isinstance(secret_data_raw, dict):
        raise AssertionError("leaf secret data missing")
    if not isinstance(root_data_raw, dict):
        raise AssertionError("root secret data missing")
    secret_data = cast(dict[str, object], secret_data_raw)
    root_data = cast(dict[str, object], root_data_raw)

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
    return TlsMaterial(cert_file=cert_file, key_file=key_file, ca_file=ca_file)


async def kubectl_apply_manifest(
    manifest: dict[str, object],
    *,
    kubeconfig: Path,
    tmp_dir: Path,
) -> None:
    """Apply a single K8s manifest dict via kubectl."""
    manifest_path = tmp_dir / f"manifest-{uuid.uuid4().hex[:8]}.json"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    returncode, _, stderr = await run_kubectl_capture_via_dag(
        "apply",
        "-f",
        str(manifest_path),
        kubeconfig=kubeconfig,
        timeout=30.0,
    )
    if returncode != 0:
        raise AssertionError(f"kubectl apply failed: {stderr}")


async def kubectl_delete_manifest(
    manifest: dict[str, object],
    *,
    kubeconfig: Path,
    tmp_dir: Path,
) -> None:
    """Delete a single K8s manifest dict via kubectl."""
    manifest_path = tmp_dir / f"manifest-del-{uuid.uuid4().hex[:8]}.json"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    with suppress(AssertionError):
        await run_kubectl_capture_via_dag(
            "delete",
            "-f",
            str(manifest_path),
            "--ignore-not-found=true",
            kubeconfig=kubeconfig,
            timeout=30.0,
        )


async def kubectl_exec_curl(
    *,
    pod_name: str,
    namespace: str,
    url: str,
    kubeconfig: Path,
    timeout: float = 15.0,
) -> tuple[int, str]:
    """Execute curl inside a pod and return (returncode, body)."""
    rc, stdout, stderr = await run_kubectl_capture_via_dag(
        "exec",
        pod_name,
        "-n",
        namespace,
        "--",
        "curl",
        "-sk",
        url,
        kubeconfig=kubeconfig,
        timeout=timeout,
    )
    return rc, stdout


async def wait_for_pod_running(
    *,
    pod_name: str,
    namespace: str,
    kubeconfig: Path,
    timeout_seconds: int = 120,
) -> None:
    """Wait for a pod to reach Running phase."""
    rc, _, stderr = await run_kubectl_capture_via_dag(
        "wait",
        "--for=condition=Ready",
        f"pod/{pod_name}",
        f"--timeout={timeout_seconds}s",
        kubeconfig=kubeconfig,
        namespace=namespace,
        timeout=float(timeout_seconds) + 10.0,
    )
    if rc != 0:
        raise AssertionError(f"pod {pod_name} not ready: {stderr}")


async def delete_pod_force(
    *,
    pod_name: str,
    namespace: str,
    kubeconfig: Path,
) -> None:
    """Force-delete a pod (simulate crash)."""
    await run_kubectl_capture_via_dag(
        "delete",
        "pod",
        pod_name,
        "--grace-period=0",
        "--force",
        kubeconfig=kubeconfig,
        namespace=namespace,
        timeout=30.0,
    )
