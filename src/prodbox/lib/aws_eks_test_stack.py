"""Helpers for the Pulumi-managed AWS EKS test stack."""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory

from prodbox.lib.aws_test_stack import (
    _AWS_CLI_TIMEOUT_SECONDS,
    _PULUMI_COMMAND_TIMEOUT_SECONDS,
    AWS_TEST_BACKEND_BUCKET,
    AWS_TEST_BACKEND_LOCAL_PORT,
    _base_env,
    _bucket_object_count,
    _ensure_minio_backend_bucket,
    _fetch_public_ipv4,
    _local_minio_backend_available,
    _mapping_from_json_object,
    _minio_credentials,
    _require_subprocess_success,
    _resource_missing,
    _run_subprocess,
    _settings_aws_env,
    minio_port_forward,
)
from prodbox.lib.lint.poetry_entrypoint_guard import ALLOW_NON_ENTRYPOINT_ENV
from prodbox.settings import REPOSITORY_ROOT, get_settings

AWS_EKS_TEST_STACK_NAME: str = "aws-eks-test"
AWS_EKS_TEST_PULUMI_PROJECT_DIR: Path = REPOSITORY_ROOT / "pulumi" / "aws-eks"
AWS_EKS_TEST_STATE_DIR: Path = REPOSITORY_ROOT / ".prodbox-state" / AWS_EKS_TEST_STACK_NAME
AWS_EKS_TEST_STACK_SNAPSHOT_PATH: Path = AWS_EKS_TEST_STATE_DIR / "stack-snapshot.json"
_EKS_READY_TIMEOUT_SECONDS: float = 900.0
_EKS_READY_POLL_SECONDS: float = 10.0


@dataclass(frozen=True)
class AwsEksTestStackSnapshot:
    """Materialized identifiers for one provisioned AWS EKS test stack."""

    stack_name: str
    backend_bucket: str
    cluster_name: str
    cluster_role_name: str
    node_group_name: str
    node_role_name: str
    vpc_id: str
    subnet_ids: tuple[str, ...]
    cluster_security_group_id: str


@dataclass(frozen=True)
class AwsEksValidationResult:
    """Summary of one successful EKS validation run."""

    cluster_name: str
    node_group_name: str
    node_names: tuple[str, ...]

    def render(self) -> str:
        """Render a deterministic validation report."""
        return (
            "\n".join(
                [
                    f"CLUSTER_NAME={self.cluster_name}",
                    f"NODE_GROUP_NAME={self.node_group_name}",
                    f"NODE_COUNT={len(self.node_names)}",
                    f"NODE_NAMES={','.join(self.node_names)}",
                    "EKS_STATUS=ready",
                ]
            )
            + "\n"
        )


def _subprocess_detail(stdout: str, stderr: str) -> str:
    """Render one deterministic subprocess detail string."""
    cleaned_stderr = stderr.strip()
    if cleaned_stderr != "":
        return cleaned_stderr
    cleaned_stdout = stdout.strip()
    if cleaned_stdout != "":
        return cleaned_stdout
    return "subprocess exited without output"


def _pulumi_eks_env(
    *,
    local_port: int,
    minio_access_key: str,
    minio_secret_key: str,
) -> dict[str, str]:
    """Build the environment used for the AWS EKS test-stack Pulumi project."""
    env = _base_env()
    env["AWS_ACCESS_KEY_ID"] = minio_access_key
    env["AWS_SECRET_ACCESS_KEY"] = minio_secret_key
    env["AWS_REGION"] = "us-east-1"
    env["AWS_DEFAULT_REGION"] = "us-east-1"
    env["AWS_EC2_METADATA_DISABLED"] = "true"
    env[ALLOW_NON_ENTRYPOINT_ENV] = "1"
    env["PULUMI_BACKEND_URL"] = (
        f"s3://{AWS_TEST_BACKEND_BUCKET}"
        f"?region=us-east-1"
        f"&endpoint=127.0.0.1:{local_port}"
        "&disableSSL=true"
        "&s3ForcePathStyle=true"
    )
    env["PULUMI_CONFIG_PASSPHRASE"] = ""
    env["PRODBOX_AWS_EKS_TEST_OPERATOR_CIDR"] = f"{_fetch_public_ipv4()}/32"
    return env


def _pulumi_login(*, env: dict[str, str]) -> None:
    """Log Pulumi into the shared local MinIO backend."""
    _require_subprocess_success(
        ("pulumi", "login", env["PULUMI_BACKEND_URL"]),
        cwd=AWS_EKS_TEST_PULUMI_PROJECT_DIR,
        env=env,
        timeout_seconds=_PULUMI_COMMAND_TIMEOUT_SECONDS,
    )


def _pulumi_stack_select(*, env: dict[str, str], create_if_missing: bool) -> bool:
    """Select the AWS EKS test stack, optionally creating it when absent."""
    command = ["pulumi", "stack", "select", AWS_EKS_TEST_STACK_NAME]
    if create_if_missing:
        command.append("--create")
    completed = _run_subprocess(
        tuple(command),
        cwd=AWS_EKS_TEST_PULUMI_PROJECT_DIR,
        env=env,
        timeout_seconds=_PULUMI_COMMAND_TIMEOUT_SECONDS,
    )
    if completed.returncode == 0:
        return True
    if not create_if_missing:
        return False
    detail = _subprocess_detail(completed.stdout, completed.stderr)
    raise AssertionError(f"failed to select Pulumi stack {AWS_EKS_TEST_STACK_NAME}: {detail}")


def _pulumi_up(*, env: dict[str, str]) -> None:
    """Run `pulumi up` for the AWS EKS test stack."""
    _require_subprocess_success(
        ("pulumi", "up", "--yes", "--stack", AWS_EKS_TEST_STACK_NAME),
        cwd=AWS_EKS_TEST_PULUMI_PROJECT_DIR,
        env=env,
        timeout_seconds=_PULUMI_COMMAND_TIMEOUT_SECONDS,
    )


def _pulumi_destroy(*, env: dict[str, str]) -> None:
    """Run `pulumi destroy` for the AWS EKS test stack."""
    _require_subprocess_success(
        ("pulumi", "destroy", "--yes", "--stack", AWS_EKS_TEST_STACK_NAME),
        cwd=AWS_EKS_TEST_PULUMI_PROJECT_DIR,
        env=env,
        timeout_seconds=_PULUMI_COMMAND_TIMEOUT_SECONDS,
    )


def _pulumi_refresh(*, env: dict[str, str]) -> None:
    """Refresh the AWS EKS test stack to recover interrupted pending operations."""
    _require_subprocess_success(
        ("pulumi", "refresh", "--yes", "--stack", AWS_EKS_TEST_STACK_NAME),
        cwd=AWS_EKS_TEST_PULUMI_PROJECT_DIR,
        env=env,
        timeout_seconds=_PULUMI_COMMAND_TIMEOUT_SECONDS,
    )


def _pulumi_cancel(*, env: dict[str, str]) -> None:
    """Cancel any in-progress Pulumi operation for the AWS EKS test stack."""
    _require_subprocess_success(
        ("pulumi", "cancel", "--yes", "--stack", AWS_EKS_TEST_STACK_NAME),
        cwd=AWS_EKS_TEST_PULUMI_PROJECT_DIR,
        env=env,
        timeout_seconds=_PULUMI_COMMAND_TIMEOUT_SECONDS,
    )


def _pulumi_stack_remove(*, env: dict[str, str], force: bool = False) -> None:
    """Remove the EKS Pulumi stack after all resources have been destroyed or abandoned."""
    command = ["pulumi", "stack", "rm", "--yes", "--remove-backups"]
    if force:
        command.append("--force")
    command.append(AWS_EKS_TEST_STACK_NAME)
    _require_subprocess_success(
        tuple(command),
        cwd=AWS_EKS_TEST_PULUMI_PROJECT_DIR,
        env=env,
        timeout_seconds=_PULUMI_COMMAND_TIMEOUT_SECONDS,
    )


def _pulumi_stack_outputs(*, env: dict[str, str]) -> dict[str, object]:
    """Load the EKS Pulumi stack outputs as JSON."""
    stdout = _require_subprocess_success(
        ("pulumi", "stack", "output", "--json", "--stack", AWS_EKS_TEST_STACK_NAME),
        cwd=AWS_EKS_TEST_PULUMI_PROJECT_DIR,
        env=env,
        timeout_seconds=_PULUMI_COMMAND_TIMEOUT_SECONDS,
    )
    payload_raw: object = json.loads(stdout)
    return _mapping_from_json_object(payload_raw, context="pulumi stack output --json")


def _require_string(payload: dict[str, object], key: str) -> str:
    """Extract one required string value from a JSON-style mapping."""
    value = payload.get(key)
    if not isinstance(value, str) or value == "":
        raise AssertionError(f"missing string output {key}")
    return value


def _require_string_tuple(payload: dict[str, object], key: str) -> tuple[str, ...]:
    """Extract one required list-of-strings value from a JSON-style mapping."""
    value = payload.get(key)
    if not isinstance(value, list):
        raise AssertionError(f"output {key} must be a JSON list")
    items: list[str] = []
    for item in value:
        if not isinstance(item, str) or item == "":
            raise AssertionError(f"output {key} must contain non-empty strings only")
        items.append(item)
    return tuple(items)


def _snapshot_from_outputs(outputs: dict[str, object]) -> AwsEksTestStackSnapshot:
    """Build a persisted stack snapshot from Pulumi outputs."""
    return AwsEksTestStackSnapshot(
        stack_name=AWS_EKS_TEST_STACK_NAME,
        backend_bucket=_require_string(outputs, "backend_bucket"),
        cluster_name=_require_string(outputs, "cluster_name"),
        cluster_role_name=_require_string(outputs, "cluster_role_name"),
        node_group_name=_require_string(outputs, "node_group_name"),
        node_role_name=_require_string(outputs, "node_role_name"),
        vpc_id=_require_string(outputs, "vpc_id"),
        subnet_ids=_require_string_tuple(outputs, "subnet_ids"),
        cluster_security_group_id=_require_string(outputs, "cluster_security_group_id"),
    )


def _snapshot_json_payload(snapshot: AwsEksTestStackSnapshot) -> dict[str, object]:
    """Render one stack snapshot to a JSON-serializable mapping."""
    return {
        "stack_name": snapshot.stack_name,
        "backend_bucket": snapshot.backend_bucket,
        "cluster_name": snapshot.cluster_name,
        "cluster_role_name": snapshot.cluster_role_name,
        "node_group_name": snapshot.node_group_name,
        "node_role_name": snapshot.node_role_name,
        "vpc_id": snapshot.vpc_id,
        "subnet_ids": list(snapshot.subnet_ids),
        "cluster_security_group_id": snapshot.cluster_security_group_id,
    }


def save_aws_eks_test_stack_snapshot(snapshot: AwsEksTestStackSnapshot) -> None:
    """Persist the latest AWS EKS test-stack identifiers under `.prodbox-state/`."""
    AWS_EKS_TEST_STATE_DIR.mkdir(parents=True, exist_ok=True)
    payload = _snapshot_json_payload(snapshot)
    AWS_EKS_TEST_STACK_SNAPSHOT_PATH.write_text(
        json.dumps(payload, indent=2, sort_keys=True),
        encoding="utf-8",
    )


def load_aws_eks_test_stack_snapshot() -> AwsEksTestStackSnapshot | None:
    """Load the last saved AWS EKS test-stack snapshot when present."""
    if not AWS_EKS_TEST_STACK_SNAPSHOT_PATH.exists():
        return None
    payload_raw: object = json.loads(AWS_EKS_TEST_STACK_SNAPSHOT_PATH.read_text(encoding="utf-8"))
    payload = _mapping_from_json_object(payload_raw, context="saved AWS EKS test stack snapshot")
    return AwsEksTestStackSnapshot(
        stack_name=_require_string(payload, "stack_name"),
        backend_bucket=_require_string(payload, "backend_bucket"),
        cluster_name=_require_string(payload, "cluster_name"),
        cluster_role_name=_require_string(payload, "cluster_role_name"),
        node_group_name=_require_string(payload, "node_group_name"),
        node_role_name=_require_string(payload, "node_role_name"),
        vpc_id=_require_string(payload, "vpc_id"),
        subnet_ids=_require_string_tuple(payload, "subnet_ids"),
        cluster_security_group_id=_require_string(payload, "cluster_security_group_id"),
    )


def clear_aws_eks_test_stack_snapshot() -> None:
    """Delete the local EKS stack snapshot artifact when present."""
    if AWS_EKS_TEST_STACK_SNAPSHOT_PATH.exists():
        AWS_EKS_TEST_STACK_SNAPSHOT_PATH.unlink()


def _aws_resource_still_exists(command: tuple[str, ...]) -> bool:
    """Return whether one AWS resource is still visible."""
    completed = _run_subprocess(
        command,
        env=_settings_aws_env(),
        timeout_seconds=_AWS_CLI_TIMEOUT_SECONDS,
    )
    if completed.returncode == 0:
        return True
    detail = _subprocess_detail(completed.stdout, completed.stderr)
    if _resource_missing(detail):
        return False
    raise AssertionError(f"{' '.join(command)} failed: {detail}")


def assert_no_aws_eks_test_stack_residue(snapshot: AwsEksTestStackSnapshot | None = None) -> None:
    """Require the last-known AWS EKS test-stack resources to be fully destroyed."""
    current = snapshot if snapshot is not None else load_aws_eks_test_stack_snapshot()
    if current is None:
        return

    remaining: list[str] = []
    if _aws_resource_still_exists(
        ("aws", "eks", "describe-cluster", "--name", current.cluster_name)
    ):
        remaining.append(f"cluster={current.cluster_name}")
    if _aws_resource_still_exists(
        (
            "aws",
            "eks",
            "describe-nodegroup",
            "--cluster-name",
            current.cluster_name,
            "--nodegroup-name",
            current.node_group_name,
        )
    ):
        remaining.append(f"node-group={current.node_group_name}")
    if _aws_resource_still_exists(
        ("aws", "iam", "get-role", "--role-name", current.cluster_role_name)
    ):
        remaining.append(f"cluster-role={current.cluster_role_name}")
    if _aws_resource_still_exists(
        ("aws", "iam", "get-role", "--role-name", current.node_role_name)
    ):
        remaining.append(f"node-role={current.node_role_name}")
    if _aws_resource_still_exists(("aws", "ec2", "describe-vpcs", "--vpc-ids", current.vpc_id)):
        remaining.append(f"vpc={current.vpc_id}")
    for subnet_id in current.subnet_ids:
        if _aws_resource_still_exists(
            ("aws", "ec2", "describe-subnets", "--subnet-ids", subnet_id)
        ):
            remaining.append(f"subnet={subnet_id}")
    if _aws_resource_still_exists(
        ("aws", "ec2", "describe-security-groups", "--group-ids", current.cluster_security_group_id)
    ):
        remaining.append(f"security-group={current.cluster_security_group_id}")
    if remaining:
        raise AssertionError("AWS EKS test stack residue remains: " + ", ".join(remaining))


def render_aws_eks_test_stack_report(
    *,
    snapshot: AwsEksTestStackSnapshot,
    backend_object_count: int,
) -> str:
    """Render a deterministic human-readable report for the AWS EKS test stack."""
    return (
        "\n".join(
            [
                f"STACK={snapshot.stack_name}",
                f"BACKEND_BUCKET={snapshot.backend_bucket}",
                f"BACKEND_OBJECT_COUNT={backend_object_count}",
                f"CLUSTER_NAME={snapshot.cluster_name}",
                f"NODE_GROUP_NAME={snapshot.node_group_name}",
                f"CLUSTER_ROLE_NAME={snapshot.cluster_role_name}",
                f"NODE_ROLE_NAME={snapshot.node_role_name}",
                f"VPC_ID={snapshot.vpc_id}",
                f"SUBNET_IDS={','.join(snapshot.subnet_ids)}",
                f"CLUSTER_SECURITY_GROUP_ID={snapshot.cluster_security_group_id}",
            ]
        )
        + "\n"
    )


def ensure_aws_eks_test_stack_resources() -> AwsEksTestStackSnapshot:
    """Provision or reconcile the Pulumi-managed AWS EKS test stack."""
    if not AWS_EKS_TEST_PULUMI_PROJECT_DIR.exists():
        raise AssertionError(
            f"Pulumi AWS EKS test project missing: {AWS_EKS_TEST_PULUMI_PROJECT_DIR}"
        )

    with minio_port_forward():
        access_key, secret_key = _minio_credentials()
        _ensure_minio_backend_bucket(
            local_port=AWS_TEST_BACKEND_LOCAL_PORT,
            access_key=access_key,
            secret_key=secret_key,
        )
        env = _pulumi_eks_env(
            local_port=AWS_TEST_BACKEND_LOCAL_PORT,
            minio_access_key=access_key,
            minio_secret_key=secret_key,
        )
        _pulumi_login(env=env)
        _pulumi_stack_select(env=env, create_if_missing=True)
        _pulumi_up(env=env)
        snapshot = _snapshot_from_outputs(_pulumi_stack_outputs(env=env))
        save_aws_eks_test_stack_snapshot(snapshot)
        backend_object_count = _bucket_object_count(
            local_port=AWS_TEST_BACKEND_LOCAL_PORT,
            access_key=access_key,
            secret_key=secret_key,
        )
        print(
            render_aws_eks_test_stack_report(
                snapshot=snapshot,
                backend_object_count=backend_object_count,
            ),
            end="",
        )
        return snapshot


def destroy_aws_eks_test_stack() -> str:
    """Destroy the Pulumi-managed AWS EKS test stack and verify zero residue."""
    current_snapshot = load_aws_eks_test_stack_snapshot()

    if not _local_minio_backend_available():
        if current_snapshot is not None:
            raise AssertionError(
                "local MinIO backend unavailable while an AWS EKS test stack snapshot still exists; "
                "cannot verify or destroy AWS residue automatically"
            )
        message = (
            "Skipped AWS EKS test stack destroy because the local MinIO backend is not present "
            "and no saved AWS residue snapshot exists"
        )
        print(message)
        return message

    with minio_port_forward():
        access_key, secret_key = _minio_credentials()
        _ensure_minio_backend_bucket(
            local_port=AWS_TEST_BACKEND_LOCAL_PORT,
            access_key=access_key,
            secret_key=secret_key,
        )
        env = _pulumi_eks_env(
            local_port=AWS_TEST_BACKEND_LOCAL_PORT,
            minio_access_key=access_key,
            minio_secret_key=secret_key,
        )
        _pulumi_login(env=env)
        stack_exists = _pulumi_stack_select(env=env, create_if_missing=False)
        if stack_exists:
            if current_snapshot is None:
                try:
                    current_snapshot = _snapshot_from_outputs(_pulumi_stack_outputs(env=env))
                except AssertionError:
                    current_snapshot = None
            if current_snapshot is not None:
                save_aws_eks_test_stack_snapshot(current_snapshot)
            try:
                _pulumi_destroy(env=env)
            except AssertionError as error:
                detail = str(error)
                if "currently locked" in detail:
                    _pulumi_cancel(env=env)
                    _pulumi_destroy(env=env)
                elif "pending operations" in detail or "Cluster has nodegroups attached" in detail:
                    _pulumi_refresh(env=env)
                    _pulumi_destroy(env=env)
                else:
                    raise
            try:
                _pulumi_stack_remove(env=env)
            except AssertionError as error:
                if "currently locked" in str(error):
                    _pulumi_cancel(env=env)
                    _pulumi_stack_remove(env=env, force=True)
                else:
                    _pulumi_stack_remove(env=env, force=True)
                    raise
        if current_snapshot is not None:
            assert_no_aws_eks_test_stack_residue(current_snapshot)
        backend_object_count = _bucket_object_count(
            local_port=AWS_TEST_BACKEND_LOCAL_PORT,
            access_key=access_key,
            secret_key=secret_key,
        )
    clear_aws_eks_test_stack_snapshot()
    residue_text = (
        "verified no AWS residue"
        if current_snapshot is not None
        else "removed the Pulumi stack without exported residue identifiers"
    )
    message = (
        f"Destroyed stack {AWS_EKS_TEST_STACK_NAME}; "
        f"{residue_text}; backend bucket {AWS_TEST_BACKEND_BUCKET} now has "
        f"{backend_object_count} object(s)"
    )
    print(message)
    return message


def _eks_kubeconfig_text(*, cluster_name: str) -> str:
    """Generate a kubeconfig for the provisioned EKS cluster without mutating host state."""
    settings = get_settings()
    return _require_subprocess_success(
        (
            "aws",
            "eks",
            "update-kubeconfig",
            "--name",
            cluster_name,
            "--region",
            settings.aws_region,
            "--dry-run",
        ),
        env=_settings_aws_env(),
        timeout_seconds=_AWS_CLI_TIMEOUT_SECONDS,
    )


def _kubectl_env(*, kubeconfig_path: Path) -> dict[str, str]:
    """Build an explicit kubectl environment for one temporary kubeconfig."""
    env = _settings_aws_env()
    env["KUBECONFIG"] = str(kubeconfig_path)
    return env


def _node_names_from_json(stdout: str) -> tuple[str, ...]:
    """Parse node names from `kubectl get nodes -o json` output."""
    payload_raw: object = json.loads(stdout)
    payload = _mapping_from_json_object(payload_raw, context="kubectl nodes payload")
    items = payload.get("items")
    if not isinstance(items, list):
        raise AssertionError("kubectl nodes payload must contain an items list")
    node_names: list[str] = []
    for item in items:
        mapping = _mapping_from_json_object(item, context="kubectl node item")
        metadata = mapping.get("metadata")
        if not isinstance(metadata, dict):
            raise AssertionError("kubectl node item must contain metadata")
        name = metadata.get("name")
        if not isinstance(name, str) or name == "":
            raise AssertionError("kubectl node item must contain metadata.name")
        node_names.append(name)
    return tuple(node_names)


def validate_aws_eks_test_stack_cluster() -> AwsEksValidationResult:
    """Validate that the provisioned EKS cluster is reachable and nodes are Ready."""
    snapshot = ensure_aws_eks_test_stack_resources()
    with TemporaryDirectory(prefix="prodbox-aws-eks-kubeconfig-") as temp_dir:
        kubeconfig_path = Path(temp_dir) / "config"
        kubeconfig_path.write_text(
            _eks_kubeconfig_text(cluster_name=snapshot.cluster_name),
            encoding="utf-8",
        )
        kubectl_env = _kubectl_env(kubeconfig_path=kubeconfig_path)
        deadline = time.monotonic() + _EKS_READY_TIMEOUT_SECONDS
        last_detail = "cluster validation not started"
        while time.monotonic() < deadline:
            nodes_result = _run_subprocess(
                ("kubectl", "get", "nodes", "-o", "json"),
                env=kubectl_env,
                timeout_seconds=60.0,
            )
            if nodes_result.returncode == 0:
                node_names = _node_names_from_json(nodes_result.stdout)
                if len(node_names) >= 2:
                    remaining_seconds = max(1, int(deadline - time.monotonic()))
                    wait_result = _run_subprocess(
                        (
                            "kubectl",
                            "wait",
                            "--for=condition=Ready",
                            "node",
                            "--all",
                            f"--timeout={remaining_seconds}s",
                        ),
                        env=kubectl_env,
                        timeout_seconds=float(remaining_seconds + 30),
                    )
                    if wait_result.returncode == 0:
                        result = AwsEksValidationResult(
                            cluster_name=snapshot.cluster_name,
                            node_group_name=snapshot.node_group_name,
                            node_names=node_names,
                        )
                        print(result.render(), end="")
                        return result
                    last_detail = _subprocess_detail(wait_result.stdout, wait_result.stderr)
                else:
                    last_detail = f"observed {len(node_names)} node(s); waiting for 2"
            else:
                last_detail = _subprocess_detail(nodes_result.stdout, nodes_result.stderr)
            time.sleep(_EKS_READY_POLL_SECONDS)
    raise AssertionError(f"timed out waiting for Ready EKS nodes: {last_detail}")


__all__ = [
    "AWS_EKS_TEST_STACK_NAME",
    "AwsEksTestStackSnapshot",
    "AwsEksValidationResult",
    "assert_no_aws_eks_test_stack_residue",
    "destroy_aws_eks_test_stack",
    "ensure_aws_eks_test_stack_resources",
    "load_aws_eks_test_stack_snapshot",
    "render_aws_eks_test_stack_report",
    "save_aws_eks_test_stack_snapshot",
    "validate_aws_eks_test_stack_cluster",
    "_node_names_from_json",
    "_snapshot_from_outputs",
    "_snapshot_json_payload",
]
