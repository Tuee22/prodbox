"""Integration lifecycle tests for prodbox storage + cleanup doctrine."""

from __future__ import annotations

import asyncio
import json
import os
import re
import uuid
from collections.abc import AsyncIterator
from pathlib import Path
from typing import NamedTuple

import pytest
import pytest_asyncio

from prodbox.cli.command_adt import Command, rke2_cleanup_command, rke2_ensure_command
from prodbox.cli.dag_builders import command_to_dag
from prodbox.cli.interpreter import create_interpreter
from prodbox.cli.types import Failure, Result, Success
from prodbox.lib.prodbox_k8s import (
    MINIO_NAMESPACE,
    MINIO_PERSISTENT_CLAIM,
    MINIO_PERSISTENT_VOLUME,
    PRODBOX_ANNOTATION_KEY,
    PRODBOX_LABEL_KEY,
    PRODBOX_NAMESPACE,
    PRODBOX_STORAGE_BASE_PATH,
    PRODBOX_STORAGE_CLASS,
    prodbox_id_to_label_value,
)

from .conftest import (
    abort_test_session_on_teardown_failure,
    kubectl_apply_manifest,
    remove_fixture_storage_artifact,
    resolve_kubeconfig,
)
from .helpers import run_kubectl_capture_via_dag

pytestmark = pytest.mark.timeout(600)


class LifecycleRebindContext(NamedTuple):
    """Temporary retained-storage rebinding scenario for one integration test."""

    kubeconfig: Path
    namespace: str
    storage_class: str
    statefulset_name: str
    pvc_prefix: str
    pv_names: tuple[str, ...]
    host_paths: tuple[Path, ...]
    manifests: tuple[dict[str, object], ...]
    tmp_dir: Path


async def _execute_command_via_dag(command_result: Result[Command, str]) -> None:
    """Build and execute a command DAG, raising AssertionError on failure."""
    match command_result:
        case Failure(error):
            raise AssertionError(f"command creation failed: {error}")
        case Success(command):
            match command_to_dag(command):
                case Failure(error):
                    raise AssertionError(f"DAG build failed: {error}")
                case Success(dag):
                    interpreter = create_interpreter()
                    summary = await interpreter.interpret_dag(dag)
                    if summary.exit_code != 0:
                        raise AssertionError(
                            "DAG execution failed: "
                            f"{summary.message}\n{summary.execution_report}"
                        )


async def _ensure_rke2_runtime(*, attempts: int = 2, delay_seconds: float = 5.0) -> None:
    """Run `rke2 ensure` with retry for transient post-cleanup reconciliation windows."""
    last_error: AssertionError | None = None
    for attempt in range(1, attempts + 1):
        try:
            await _execute_command_via_dag(rke2_ensure_command())
            return
        except AssertionError as error:
            last_error = error
            if attempt == attempts:
                raise
            await asyncio.sleep(delay_seconds)
    if last_error is not None:
        raise last_error


def _current_prodbox_id() -> str:
    """Resolve prodbox-id from local Linux machine-id."""
    machine_id = Path("/etc/machine-id").read_text(encoding="utf-8").strip().lower()
    if re.fullmatch(r"[0-9a-f]{32}", machine_id) is None:
        raise AssertionError(f"unexpected /etc/machine-id format: {machine_id}")
    return f"prodbox-{machine_id}"


def _rebind_host_paths(*, prodbox_id: str, pv_names: tuple[str, ...]) -> tuple[Path, ...]:
    """Build deterministic host-path artifacts owned by one rebind test."""
    rebind_root = Path(PRODBOX_STORAGE_BASE_PATH) / prodbox_id / "rebind"
    return tuple(rebind_root / pv_name for pv_name in pv_names)


async def _kubectl_expect_success(
    *args: str,
    kubeconfig: Path,
    namespace: str | None = None,
    timeout: float = 60.0,
) -> tuple[str, str]:
    """Run kubectl and return stdout/stderr or raise on non-zero rc."""
    rc, stdout, stderr = await run_kubectl_capture_via_dag(
        *args,
        kubeconfig=kubeconfig,
        namespace=namespace,
        timeout=timeout,
    )
    if rc != 0:
        joined = " ".join(args)
        raise AssertionError(f"kubectl {joined} failed: {stderr}")
    return stdout, stderr


async def _single_node_name(kubeconfig: Path) -> str:
    """Resolve single node name; retained storage doctrine requires one node."""
    stdout, _ = await _kubectl_expect_success(
        "get",
        "nodes",
        "-o",
        "jsonpath={.items[*].metadata.name}",
        kubeconfig=kubeconfig,
        timeout=30.0,
    )
    names = tuple(token.strip() for token in stdout.split() if token.strip() != "")
    if len(names) != 1:
        raise AssertionError(f"expected single-node cluster, got nodes={names}")
    return names[0]


async def _wait_deployment_available(
    *,
    kubeconfig: Path,
    namespace: str,
    name: str,
    timeout_seconds: int = 300,
) -> None:
    """Wait for one deployment to become Available."""
    await _kubectl_expect_success(
        "wait",
        "--for=condition=Available",
        f"deployment/{name}",
        f"--timeout={timeout_seconds}s",
        kubeconfig=kubeconfig,
        namespace=namespace,
        timeout=float(timeout_seconds) + 15.0,
    )


async def _ensure_post_deploy_baseline(kubeconfig: Path) -> None:
    """Reconcile and verify the canonical post-deploy prodbox runtime baseline."""
    await _ensure_rke2_runtime(attempts=4, delay_seconds=15.0)
    await _kubectl_expect_success(
        "get",
        "configmap",
        "prodbox-identity",
        kubeconfig=kubeconfig,
        namespace=PRODBOX_NAMESPACE,
        timeout=30.0,
    )
    await _wait_deployment_available(
        kubeconfig=kubeconfig,
        namespace=MINIO_NAMESPACE,
        name="minio",
        timeout_seconds=300,
    )
    await _kubectl_expect_success(
        "get",
        "storageclass",
        PRODBOX_STORAGE_CLASS,
        kubeconfig=kubeconfig,
        timeout=20.0,
    )
    await _kubectl_expect_success(
        "get",
        "pv",
        MINIO_PERSISTENT_VOLUME,
        kubeconfig=kubeconfig,
        timeout=20.0,
    )
    pvc_name, pv_name = await _resolve_pvc_binding(
        kubeconfig=kubeconfig,
        namespace=MINIO_NAMESPACE,
        pvc_name=MINIO_PERSISTENT_CLAIM,
    )
    if pvc_name != MINIO_PERSISTENT_CLAIM or pv_name != MINIO_PERSISTENT_VOLUME:
        raise AssertionError(
            "post-deploy baseline binding mismatch: " f"pvc={pvc_name} pv={pv_name}"
        )


async def _resolve_pvc_binding(
    *, kubeconfig: Path, namespace: str, pvc_name: str
) -> tuple[str, str]:
    """Return (pvc_name, volume_name) for one PVC."""
    stdout, _ = await _kubectl_expect_success(
        "get",
        "pvc",
        pvc_name,
        "-o",
        "json",
        kubeconfig=kubeconfig,
        namespace=namespace,
        timeout=30.0,
    )
    obj = json.loads(stdout)
    metadata = obj.get("metadata", {})
    spec = obj.get("spec", {})
    resolved_pvc = str(metadata.get("name", ""))
    volume_name = str(spec.get("volumeName", ""))
    if resolved_pvc == "" or volume_name == "":
        raise AssertionError(f"PVC {namespace}/{pvc_name} has no bound volumeName")
    return resolved_pvc, volume_name


async def _collect_statefulset_bindings(
    *,
    kubeconfig: Path,
    namespace: str,
    prefix: str,
) -> dict[str, str]:
    """Return PVC->PV map for all PVCs in namespace that match a prefix."""
    stdout, _ = await _kubectl_expect_success(
        "get",
        "pvc",
        "-o",
        "json",
        kubeconfig=kubeconfig,
        namespace=namespace,
        timeout=30.0,
    )
    obj = json.loads(stdout)
    items = obj.get("items", [])
    if not isinstance(items, list):
        raise AssertionError("unexpected pvc json shape")

    mapping: dict[str, str] = {}
    for item in items:
        if not isinstance(item, dict):
            continue
        metadata = item.get("metadata", {})
        spec = item.get("spec", {})
        if not isinstance(metadata, dict) or not isinstance(spec, dict):
            continue
        name = metadata.get("name")
        if not isinstance(name, str) or not name.startswith(prefix):
            continue
        volume_name = spec.get("volumeName")
        if not isinstance(volume_name, str) or volume_name == "":
            raise AssertionError(f"PVC {name} is not bound")
        mapping[name] = volume_name
    return mapping


async def _apply_manifest_with_details(
    manifest: dict[str, object], *, kubeconfig: Path, tmp_dir: Path
) -> None:
    """Apply one manifest and preserve kubectl stderr details on failure."""
    manifest_path = tmp_dir / f"manifest-debug-{manifest.get('kind', 'obj')}.json"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    env = dict(os.environ)
    env["KUBECONFIG"] = str(kubeconfig)
    process = await asyncio.create_subprocess_exec(
        "kubectl",
        "apply",
        "-f",
        str(manifest_path),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=env,
    )
    stdout_bytes, stderr_bytes = await process.communicate()
    rc = process.returncode or 0
    stdout = stdout_bytes.decode("utf-8", errors="replace")
    stderr = stderr_bytes.decode("utf-8", errors="replace")
    if rc != 0:
        kind = manifest.get("kind", "<unknown-kind>")
        metadata = manifest.get("metadata", {})
        name = "<unknown-name>"
        if isinstance(metadata, dict):
            raw_name = metadata.get("name")
            if isinstance(raw_name, str):
                name = raw_name
        raise AssertionError(
            f"kubectl apply failed for {kind}/{name}: stderr={stderr} stdout={stdout}"
        )


async def _cleanup_lifecycle_rebind_resources(context: LifecycleRebindContext) -> None:
    """Delete all temporary retained-storage rebinding resources created by the fixture."""
    await _kubectl_expect_success(
        "delete",
        "namespace",
        context.namespace,
        "--ignore-not-found=true",
        "--wait=true",
        kubeconfig=context.kubeconfig,
        timeout=120.0,
    )

    for pv_name in context.pv_names:
        await _kubectl_expect_success(
            "delete",
            "pv",
            pv_name,
            "--ignore-not-found=true",
            "--wait=true",
            kubeconfig=context.kubeconfig,
            timeout=60.0,
        )

    await _kubectl_expect_success(
        "delete",
        "storageclass",
        context.storage_class,
        "--ignore-not-found=true",
        kubeconfig=context.kubeconfig,
        timeout=60.0,
    )
    for host_path in context.host_paths:
        await remove_fixture_storage_artifact(host_path)


async def _apply_rebind_manifests(context: LifecycleRebindContext) -> None:
    """Apply all temporary retained-storage rebinding manifests."""
    for manifest in context.manifests:
        await _apply_manifest_with_details(
            manifest,
            kubeconfig=context.kubeconfig,
            tmp_dir=context.tmp_dir,
        )


@pytest_asyncio.fixture
async def lifecycle_runtime_baseline() -> AsyncIterator[Path]:
    """Ensure the canonical post-deploy runtime exists before and after the test."""
    kubeconfig = resolve_kubeconfig()
    await _ensure_post_deploy_baseline(kubeconfig)

    yield kubeconfig

    try:
        await _execute_command_via_dag(rke2_cleanup_command(yes=True))
        await _ensure_post_deploy_baseline(kubeconfig)
    except AssertionError as error:
        abort_test_session_on_teardown_failure(target="shared runtime baseline", error=error)


@pytest_asyncio.fixture
async def lifecycle_rebind_context(
    lifecycle_runtime_baseline: Path,
    tmp_path: Path,
) -> AsyncIterator[LifecycleRebindContext]:
    """Create a temporary three-replica retained-storage rebinding scenario."""
    prodbox_id = _current_prodbox_id()
    label_value = prodbox_id_to_label_value(prodbox_id)
    node_name = await _single_node_name(lifecycle_runtime_baseline)
    unique = uuid.uuid4().hex[:8]
    namespace = f"prodbox-minio-rebind-{unique}"
    storage_class = f"prodbox-minio-rebind-retain-{unique}"
    statefulset_name = f"minio-rebind-{unique}"
    service_name = f"minio-rebind-{unique}"
    pvc_prefix = f"data-{statefulset_name}-"
    pv_names = tuple(f"prodbox-minio-rebind-{unique}-pv-{index}" for index in range(3))
    host_paths = _rebind_host_paths(prodbox_id=prodbox_id, pv_names=pv_names)

    namespace_manifest: dict[str, object] = {
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {
            "name": namespace,
            "annotations": {PRODBOX_ANNOTATION_KEY: prodbox_id},
            "labels": {PRODBOX_LABEL_KEY: label_value},
        },
    }
    storage_class_manifest: dict[str, object] = {
        "apiVersion": "storage.k8s.io/v1",
        "kind": "StorageClass",
        "metadata": {
            "name": storage_class,
            "annotations": {PRODBOX_ANNOTATION_KEY: prodbox_id},
            "labels": {PRODBOX_LABEL_KEY: label_value},
        },
        "provisioner": "kubernetes.io/no-provisioner",
        "volumeBindingMode": "WaitForFirstConsumer",
        "reclaimPolicy": "Retain",
        "allowVolumeExpansion": True,
    }
    persistent_volumes: tuple[dict[str, object], ...] = tuple(
        {
            "apiVersion": "v1",
            "kind": "PersistentVolume",
            "metadata": {
                "name": pv_name,
                "annotations": {PRODBOX_ANNOTATION_KEY: prodbox_id},
                "labels": {PRODBOX_LABEL_KEY: label_value},
            },
            "spec": {
                "capacity": {"storage": "1Gi"},
                "volumeMode": "Filesystem",
                "accessModes": ["ReadWriteOnce"],
                "persistentVolumeReclaimPolicy": "Retain",
                "storageClassName": storage_class,
                "claimRef": {
                    "namespace": namespace,
                    "name": f"{pvc_prefix}{index}",
                },
                "hostPath": {"path": str(host_paths[index]), "type": "DirectoryOrCreate"},
                "nodeAffinity": {
                    "required": {
                        "nodeSelectorTerms": [
                            {
                                "matchExpressions": [
                                    {
                                        "key": "kubernetes.io/hostname",
                                        "operator": "In",
                                        "values": [node_name],
                                    }
                                ]
                            }
                        ]
                    }
                },
            },
        }
        for index, pv_name in enumerate(pv_names)
    )
    service_manifest: dict[str, object] = {
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": {
            "name": service_name,
            "namespace": namespace,
            "annotations": {PRODBOX_ANNOTATION_KEY: prodbox_id},
            "labels": {PRODBOX_LABEL_KEY: label_value, "app": statefulset_name},
        },
        "spec": {
            "clusterIP": "None",
            "selector": {"app": statefulset_name},
            "ports": [
                {"name": "api", "port": 9000, "targetPort": 9000},
                {"name": "console", "port": 9001, "targetPort": 9001},
            ],
        },
    }
    statefulset_manifest: dict[str, object] = {
        "apiVersion": "apps/v1",
        "kind": "StatefulSet",
        "metadata": {
            "name": statefulset_name,
            "namespace": namespace,
            "annotations": {PRODBOX_ANNOTATION_KEY: prodbox_id},
            "labels": {PRODBOX_LABEL_KEY: label_value, "app": statefulset_name},
        },
        "spec": {
            "serviceName": service_name,
            "replicas": 3,
            "selector": {"matchLabels": {"app": statefulset_name}},
            "template": {
                "metadata": {
                    "annotations": {PRODBOX_ANNOTATION_KEY: prodbox_id},
                    "labels": {PRODBOX_LABEL_KEY: label_value, "app": statefulset_name},
                },
                "spec": {
                    "containers": [
                        {
                            "name": "minio",
                            "image": "quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z",
                            "args": ["server", "/data", "--console-address", ":9001"],
                            "env": [
                                {"name": "MINIO_ROOT_USER", "value": "minioadmin"},
                                {"name": "MINIO_ROOT_PASSWORD", "value": "minioadmin"},
                            ],
                            "ports": [
                                {"containerPort": 9000, "name": "api"},
                                {"containerPort": 9001, "name": "console"},
                            ],
                            "volumeMounts": [{"name": "data", "mountPath": "/data"}],
                        }
                    ]
                },
            },
            "volumeClaimTemplates": [
                {
                    "metadata": {
                        "name": "data",
                        "annotations": {PRODBOX_ANNOTATION_KEY: prodbox_id},
                        "labels": {PRODBOX_LABEL_KEY: label_value},
                    },
                    "spec": {
                        "accessModes": ["ReadWriteOnce"],
                        "volumeMode": "Filesystem",
                        "storageClassName": storage_class,
                        "resources": {"requests": {"storage": "1Gi"}},
                    },
                }
            ],
        },
    }

    context = LifecycleRebindContext(
        kubeconfig=lifecycle_runtime_baseline,
        namespace=namespace,
        storage_class=storage_class,
        statefulset_name=statefulset_name,
        pvc_prefix=pvc_prefix,
        pv_names=pv_names,
        host_paths=host_paths,
        manifests=(
            namespace_manifest,
            storage_class_manifest,
            *persistent_volumes,
            service_manifest,
            statefulset_manifest,
        ),
        tmp_dir=tmp_path,
    )

    try:
        await _apply_rebind_manifests(context)
        await _kubectl_expect_success(
            "rollout",
            "status",
            f"statefulset/{context.statefulset_name}",
            "--timeout=240s",
            kubeconfig=context.kubeconfig,
            namespace=context.namespace,
            timeout=250.0,
        )
    except AssertionError:
        try:
            await _cleanup_lifecycle_rebind_resources(context)
        except AssertionError as cleanup_error:
            abort_test_session_on_teardown_failure(
                target=f"lifecycle rebind setup {context.namespace}",
                error=cleanup_error,
            )
        raise

    yield context

    try:
        await _cleanup_lifecycle_rebind_resources(context)
    except AssertionError as error:
        abort_test_session_on_teardown_failure(
            target=f"lifecycle rebind {context.namespace}",
            error=error,
        )


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.asyncio
async def test_prodbox_cleanup_lifecycle_preserves_storage_and_rebinds(
    lifecycle_runtime_baseline: Path,
    tmp_path: Path,
) -> None:
    """Cleanup removes runtime objects but preserves retained storage for deterministic rebinding."""
    kubeconfig = lifecycle_runtime_baseline
    prodbox_id = _current_prodbox_id()

    await _kubectl_expect_success("cluster-info", kubeconfig=kubeconfig, timeout=30.0)

    configmap_stdout, _ = await _kubectl_expect_success(
        "get",
        "configmap",
        "prodbox-identity",
        "-o",
        "json",
        kubeconfig=kubeconfig,
        namespace=PRODBOX_NAMESPACE,
        timeout=30.0,
    )
    configmap = json.loads(configmap_stdout)
    metadata = configmap.get("metadata", {})
    annotations = metadata.get("annotations", {})
    data = configmap.get("data", {})
    assert isinstance(annotations, dict)
    assert isinstance(data, dict)
    assert annotations.get(PRODBOX_ANNOTATION_KEY) == prodbox_id
    assert data.get("prodbox_id") == prodbox_id

    await _wait_deployment_available(
        kubeconfig=kubeconfig,
        namespace=MINIO_NAMESPACE,
        name="minio",
        timeout_seconds=300,
    )
    pre_cleanup_binding = await _resolve_pvc_binding(
        kubeconfig=kubeconfig,
        namespace=MINIO_NAMESPACE,
        pvc_name=MINIO_PERSISTENT_CLAIM,
    )
    assert pre_cleanup_binding[1] == MINIO_PERSISTENT_VOLUME

    cleanup_marker: dict[str, object] = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": "prodbox-cleanup-marker",
            "namespace": PRODBOX_NAMESPACE,
            "annotations": {PRODBOX_ANNOTATION_KEY: prodbox_id},
            "labels": {PRODBOX_LABEL_KEY: prodbox_id_to_label_value(prodbox_id)},
        },
        "data": {"marker": "true"},
    }
    await kubectl_apply_manifest(cleanup_marker, kubeconfig=kubeconfig, tmp_dir=tmp_path)

    await _execute_command_via_dag(rke2_cleanup_command(yes=True))

    marker_rc, _, _ = await run_kubectl_capture_via_dag(
        "get",
        "configmap",
        "prodbox-cleanup-marker",
        kubeconfig=kubeconfig,
        namespace=PRODBOX_NAMESPACE,
        timeout=20.0,
    )
    assert marker_rc != 0

    minio_deploy_rc, _, _ = await run_kubectl_capture_via_dag(
        "get",
        "deployment",
        "minio",
        kubeconfig=kubeconfig,
        namespace=MINIO_NAMESPACE,
        timeout=20.0,
    )
    assert minio_deploy_rc != 0

    await _kubectl_expect_success(
        "get",
        "storageclass",
        PRODBOX_STORAGE_CLASS,
        kubeconfig=kubeconfig,
        timeout=20.0,
    )
    await _kubectl_expect_success(
        "get",
        "pv",
        MINIO_PERSISTENT_VOLUME,
        kubeconfig=kubeconfig,
        timeout=20.0,
    )

    post_cleanup_binding = await _resolve_pvc_binding(
        kubeconfig=kubeconfig,
        namespace=MINIO_NAMESPACE,
        pvc_name=MINIO_PERSISTENT_CLAIM,
    )
    assert post_cleanup_binding == pre_cleanup_binding

    await _ensure_post_deploy_baseline(kubeconfig)

    post_reensure_binding = await _resolve_pvc_binding(
        kubeconfig=kubeconfig,
        namespace=MINIO_NAMESPACE,
        pvc_name=MINIO_PERSISTENT_CLAIM,
    )
    assert post_reensure_binding == pre_cleanup_binding


@pytest.mark.integration  # type: ignore[misc]
@pytest.mark.asyncio
async def test_three_replica_minio_statefulset_rebinds_deterministically(
    lifecycle_rebind_context: LifecycleRebindContext,
) -> None:
    """A temporary 3-replica MinIO StatefulSet should rebind to identical PVs after redeploy."""
    expected_mapping = {
        f"{lifecycle_rebind_context.pvc_prefix}{index}": pv_name
        for index, pv_name in enumerate(lifecycle_rebind_context.pv_names)
    }

    initial_mapping = await _collect_statefulset_bindings(
        kubeconfig=lifecycle_rebind_context.kubeconfig,
        namespace=lifecycle_rebind_context.namespace,
        prefix=lifecycle_rebind_context.pvc_prefix,
    )
    assert initial_mapping == expected_mapping

    await _kubectl_expect_success(
        "delete",
        "namespace",
        lifecycle_rebind_context.namespace,
        "--ignore-not-found=true",
        "--wait=true",
        kubeconfig=lifecycle_rebind_context.kubeconfig,
        timeout=120.0,
    )
    for pv_name in lifecycle_rebind_context.pv_names:
        await _kubectl_expect_success(
            "delete",
            "pv",
            pv_name,
            "--ignore-not-found=true",
            "--wait=true",
            kubeconfig=lifecycle_rebind_context.kubeconfig,
            timeout=60.0,
        )
    await _kubectl_expect_success(
        "delete",
        "storageclass",
        lifecycle_rebind_context.storage_class,
        "--ignore-not-found=true",
        kubeconfig=lifecycle_rebind_context.kubeconfig,
        timeout=60.0,
    )

    await _apply_rebind_manifests(lifecycle_rebind_context)
    await _kubectl_expect_success(
        "rollout",
        "status",
        f"statefulset/{lifecycle_rebind_context.statefulset_name}",
        "--timeout=240s",
        kubeconfig=lifecycle_rebind_context.kubeconfig,
        namespace=lifecycle_rebind_context.namespace,
        timeout=250.0,
    )
    rebound_mapping = await _collect_statefulset_bindings(
        kubeconfig=lifecycle_rebind_context.kubeconfig,
        namespace=lifecycle_rebind_context.namespace,
        prefix=lifecycle_rebind_context.pvc_prefix,
    )
    assert rebound_mapping == expected_mapping
