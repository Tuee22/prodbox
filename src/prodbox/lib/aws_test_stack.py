"""Helpers for the Pulumi-managed AWS HA-RKE2 test stack."""

from __future__ import annotations

import base64
import http.client
import json
import os
import shutil
import socket
import subprocess
import time
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

from prodbox.lib.lint.poetry_entrypoint_guard import ALLOW_NON_ENTRYPOINT_ENV
from prodbox.settings import REPOSITORY_ROOT

AWS_TEST_STACK_NAME: str = "aws-test"
AWS_TEST_PULUMI_PROJECT_DIR: Path = REPOSITORY_ROOT / "pulumi" / "aws-test"
AWS_TEST_BACKEND_BUCKET: str = "prodbox-test-pulumi-backends"
AWS_TEST_BACKEND_REGION: str = "us-east-1"
AWS_TEST_BACKEND_LOCAL_PORT: int = 39000
AWS_TEST_STATE_DIR: Path = REPOSITORY_ROOT / ".prodbox-state" / "aws-test"
AWS_TEST_STACK_SNAPSHOT_PATH: Path = AWS_TEST_STATE_DIR / "stack-snapshot.json"
AWS_TEST_PRIVATE_KEY_PATH: Path = AWS_TEST_STATE_DIR / "id_ed25519"
AWS_TEST_PUBLIC_KEY_PATH: Path = AWS_TEST_STATE_DIR / "id_ed25519.pub"
MINIO_NAMESPACE: str = "prodbox"
MINIO_SECRET_NAME: str = "minio"
MINIO_SERVICE_NAME: str = "minio"
MINIO_SECRET_USER_KEY: str = "rootUser"
MINIO_SECRET_PASSWORD_KEY: str = "rootPassword"
_MINIO_PORT_FORWARD_WAIT_SECONDS: float = 15.0
_MINIO_PORT_FORWARD_POLL_SECONDS: float = 0.25
_PULUMI_COMMAND_TIMEOUT_SECONDS: float = 3600.0
_AWS_CLI_TIMEOUT_SECONDS: float = 300.0
_PUBLIC_IP_HOST: str = "api.ipify.org"


@dataclass(frozen=True)
class AwsTestNode:
    """One Pulumi-managed EC2 node used for HA-RKE2 validation."""

    name: str
    availability_zone: str
    instance_id: str
    private_ip: str
    public_ip: str


@dataclass(frozen=True)
class AwsTestStackSnapshot:
    """Materialized identifiers for one provisioned AWS test stack."""

    stack_name: str
    backend_bucket: str
    vpc_id: str
    subnet_ids: tuple[str, ...]
    security_group_id: str
    nodes: tuple[AwsTestNode, ...]


def _base_env() -> dict[str, str]:
    """Build a minimal subprocess environment."""
    env: dict[str, str] = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", ""),
        "LANG": os.environ.get("LANG", "C.UTF-8"),
    }
    term = os.environ.get("TERM")
    if term is not None:
        env["TERM"] = term
    return env


def _run_subprocess(
    command: tuple[str, ...],
    *,
    env: Mapping[str, str] | None = None,
    cwd: Path | None = None,
    timeout_seconds: float,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run one subprocess command with explicit environment."""
    return subprocess.run(
        command,
        capture_output=True,
        check=False,
        cwd=cwd,
        env=dict(env) if env is not None else _base_env(),
        input=input_text,
        text=True,
        timeout=timeout_seconds,
    )


def _require_subprocess_success(
    command: tuple[str, ...],
    *,
    env: Mapping[str, str] | None = None,
    cwd: Path | None = None,
    timeout_seconds: float,
    input_text: str | None = None,
) -> str:
    """Run one subprocess command and return stdout on success."""
    completed = _run_subprocess(
        command,
        env=env,
        cwd=cwd,
        timeout_seconds=timeout_seconds,
        input_text=input_text,
    )
    if completed.returncode != 0:
        stderr_text = completed.stderr.strip() or completed.stdout.strip()
        raise AssertionError(f"{' '.join(command)} failed: {stderr_text}")
    return completed.stdout


def _resolve_local_kubeconfig() -> Path:
    """Resolve the canonical kubeconfig path for the local RKE2 cluster."""
    candidates: tuple[Path, ...] = tuple(
        path
        for path in (
            Path(os.environ["KUBECONFIG"]).expanduser() if "KUBECONFIG" in os.environ else None,
            Path.home() / ".kube" / "config",
            Path("/etc/rancher/rke2/rke2.yaml"),
        )
        if path is not None
    )
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise AssertionError("no kubeconfig found for the local RKE2 cluster")


def _kubectl_env() -> dict[str, str]:
    """Build kubectl subprocess environment."""
    env = _base_env()
    env["KUBECONFIG"] = str(_resolve_local_kubeconfig())
    return env


def _mapping_from_json_object(value: object, *, context: str) -> dict[str, object]:
    """Require a JSON-derived value to be a string-keyed mapping."""
    if not isinstance(value, dict):
        raise AssertionError(f"{context} must be a JSON object")
    converted: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise AssertionError(f"{context} must use string keys")
        converted[key] = item
    return converted


def _list_from_json_value(value: object, *, context: str) -> list[object]:
    """Require a JSON-derived value to be a list."""
    if not isinstance(value, list):
        raise AssertionError(f"{context} must be a JSON list")
    return list(value)


def _kubectl_resource_exists(*args: str) -> bool:
    """Return whether one kubectl get-style probe resolves successfully."""
    try:
        env = _kubectl_env()
    except AssertionError:
        return False
    completed = _run_subprocess(
        ("kubectl", *args),
        env=env,
        timeout_seconds=60.0,
    )
    return completed.returncode == 0


def _local_minio_backend_available() -> bool:
    """Return whether the local cluster currently exposes the MinIO backend inputs."""
    return all(
        _kubectl_resource_exists(*probe)
        for probe in (
            ("get", "namespace", MINIO_NAMESPACE),
            ("get", "service", MINIO_SERVICE_NAME, "-n", MINIO_NAMESPACE),
            ("get", "secret", MINIO_SECRET_NAME, "-n", MINIO_NAMESPACE),
        )
    )


def _kubectl_json(*args: str) -> dict[str, object]:
    """Run kubectl and parse the JSON response."""
    stdout = _require_subprocess_success(
        ("kubectl", *args, "-o", "json"),
        env=_kubectl_env(),
        timeout_seconds=60.0,
    )
    parsed: object = json.loads(stdout)
    return _mapping_from_json_object(parsed, context=f"kubectl {' '.join(args)}")


def _decode_secret_field(secret: dict[str, object], key: str) -> str:
    """Decode one base64-encoded secret field."""
    data = secret.get("data")
    if not isinstance(data, dict):
        raise AssertionError(f"Kubernetes secret {MINIO_SECRET_NAME} is missing a data mapping")
    encoded = data.get(key)
    if not isinstance(encoded, str) or encoded == "":
        raise AssertionError(
            f"Kubernetes secret {MINIO_SECRET_NAME} is missing required data key {key}"
        )
    return base64.b64decode(encoded).decode("utf-8")


def _minio_credentials() -> tuple[str, str]:
    """Read the current MinIO root credentials from the cluster secret."""
    secret = _kubectl_json("get", "secret", MINIO_SECRET_NAME, "-n", MINIO_NAMESPACE)
    return (
        _decode_secret_field(secret, MINIO_SECRET_USER_KEY),
        _decode_secret_field(secret, MINIO_SECRET_PASSWORD_KEY),
    )


def _port_open(*, port: int) -> bool:
    """Return whether a local TCP port is currently accepting connections."""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            return True
    except OSError:
        return False


@contextmanager
def minio_port_forward(*, local_port: int = AWS_TEST_BACKEND_LOCAL_PORT) -> Iterator[None]:
    """Expose the in-cluster MinIO service on the local host."""
    command = (
        "kubectl",
        "port-forward",
        "-n",
        MINIO_NAMESPACE,
        f"svc/{MINIO_SERVICE_NAME}",
        f"{local_port}:9000",
    )
    process = subprocess.Popen(
        command,
        cwd=REPOSITORY_ROOT,
        env=_kubectl_env(),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        deadline = time.monotonic() + _MINIO_PORT_FORWARD_WAIT_SECONDS
        while time.monotonic() < deadline:
            if _port_open(port=local_port):
                yield
                return
            if process.poll() is not None:
                log_text = ""
                if process.stdout is not None:
                    log_text = process.stdout.read().strip()
                raise AssertionError(f"kubectl port-forward exited early: {log_text}")
            time.sleep(_MINIO_PORT_FORWARD_POLL_SECONDS)
        raise AssertionError("timed out waiting for MinIO port-forward readiness")
    finally:
        process.terminate()
        try:
            process.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5.0)
        if process.stdout is not None:
            process.stdout.close()


def _minio_aws_env(*, access_key: str, secret_key: str) -> dict[str, str]:
    """Build explicit AWS-style credentials for the local MinIO endpoint."""
    env = _base_env()
    env["AWS_ACCESS_KEY_ID"] = access_key
    env["AWS_SECRET_ACCESS_KEY"] = secret_key
    env["AWS_REGION"] = AWS_TEST_BACKEND_REGION
    env["AWS_DEFAULT_REGION"] = AWS_TEST_BACKEND_REGION
    env["AWS_EC2_METADATA_DISABLED"] = "true"
    return env


def _minio_endpoint_url(*, local_port: int) -> str:
    """Return the local MinIO endpoint URL."""
    return f"http://127.0.0.1:{local_port}"


def _pulumi_backend_url(*, local_port: int) -> str:
    """Return the canonical Pulumi S3 backend URL for the local MinIO bucket."""
    return (
        f"s3://{AWS_TEST_BACKEND_BUCKET}"
        f"?region={AWS_TEST_BACKEND_REGION}"
        f"&endpoint=127.0.0.1:{local_port}"
        "&disableSSL=true"
        "&s3ForcePathStyle=true"
    )


def _fetch_public_ipv4() -> str:
    """Resolve the current host public IPv4 address."""
    connection = http.client.HTTPSConnection(_PUBLIC_IP_HOST, timeout=10.0)
    try:
        connection.request("GET", "/")
        response = connection.getresponse()
        response_body = response.read()
    finally:
        connection.close()
    raw = response_body.decode("utf-8").strip()
    octets = raw.split(".")
    if len(octets) != 4:
        raise AssertionError(f"unexpected public IP response: {raw}")
    return raw


def ensure_aws_test_ssh_key() -> Path:
    """Create the dedicated SSH key pair for AWS test nodes when missing."""
    AWS_TEST_STATE_DIR.mkdir(parents=True, exist_ok=True)
    if AWS_TEST_PRIVATE_KEY_PATH.exists() and AWS_TEST_PUBLIC_KEY_PATH.exists():
        return AWS_TEST_PRIVATE_KEY_PATH
    if shutil.which("ssh-keygen") is None:
        raise AssertionError("ssh-keygen not installed")
    _require_subprocess_success(
        (
            "ssh-keygen",
            "-q",
            "-t",
            "ed25519",
            "-N",
            "",
            "-f",
            str(AWS_TEST_PRIVATE_KEY_PATH),
        ),
        timeout_seconds=30.0,
    )
    return AWS_TEST_PRIVATE_KEY_PATH


def _ssh_public_key_text() -> str:
    """Read the local public key used for EC2 instance access."""
    ensure_aws_test_ssh_key()
    return AWS_TEST_PUBLIC_KEY_PATH.read_text(encoding="utf-8").strip()


def _pulumi_test_env(
    *,
    local_port: int,
    minio_access_key: str,
    minio_secret_key: str,
) -> dict[str, str]:
    """Build the environment used for the AWS test-stack Pulumi project."""
    env = _minio_aws_env(access_key=minio_access_key, secret_key=minio_secret_key)
    env[ALLOW_NON_ENTRYPOINT_ENV] = "1"
    env["PULUMI_BACKEND_URL"] = _pulumi_backend_url(local_port=local_port)
    env["PULUMI_CONFIG_PASSPHRASE"] = ""
    env["PRODBOX_AWS_TEST_PUBLIC_KEY"] = _ssh_public_key_text()
    env["PRODBOX_AWS_TEST_OPERATOR_CIDR"] = f"{_fetch_public_ipv4()}/32"
    return env


def _ensure_minio_backend_bucket(
    *,
    local_port: int,
    access_key: str,
    secret_key: str,
) -> None:
    """Create the dedicated Pulumi backend bucket when missing."""
    env = _minio_aws_env(access_key=access_key, secret_key=secret_key)
    completed = _run_subprocess(
        (
            "aws",
            "--endpoint-url",
            _minio_endpoint_url(local_port=local_port),
            "s3api",
            "head-bucket",
            "--bucket",
            AWS_TEST_BACKEND_BUCKET,
        ),
        env=env,
        timeout_seconds=_AWS_CLI_TIMEOUT_SECONDS,
    )
    if completed.returncode == 0:
        return
    _require_subprocess_success(
        (
            "aws",
            "--endpoint-url",
            _minio_endpoint_url(local_port=local_port),
            "s3api",
            "create-bucket",
            "--bucket",
            AWS_TEST_BACKEND_BUCKET,
        ),
        env=env,
        timeout_seconds=_AWS_CLI_TIMEOUT_SECONDS,
    )


def _bucket_object_count(
    *,
    local_port: int,
    access_key: str,
    secret_key: str,
) -> int:
    """Return the number of visible objects in the backend bucket."""
    env = _minio_aws_env(access_key=access_key, secret_key=secret_key)
    stdout = _require_subprocess_success(
        (
            "aws",
            "--endpoint-url",
            _minio_endpoint_url(local_port=local_port),
            "s3api",
            "list-objects-v2",
            "--bucket",
            AWS_TEST_BACKEND_BUCKET,
        ),
        env=env,
        timeout_seconds=_AWS_CLI_TIMEOUT_SECONDS,
    )
    payload_raw: object = json.loads(stdout)
    payload = _mapping_from_json_object(payload_raw, context="MinIO list-objects-v2 payload")
    key_count = payload.get("KeyCount", 0)
    if not isinstance(key_count, int):
        raise AssertionError("MinIO list-objects-v2 payload contained a non-integer KeyCount")
    return key_count


def _pulumi_login(*, env: Mapping[str, str]) -> None:
    """Log Pulumi into the local MinIO backend."""
    _require_subprocess_success(
        ("pulumi", "login", env["PULUMI_BACKEND_URL"]),
        cwd=AWS_TEST_PULUMI_PROJECT_DIR,
        env=env,
        timeout_seconds=_PULUMI_COMMAND_TIMEOUT_SECONDS,
    )


def _pulumi_stack_select(*, env: Mapping[str, str], create_if_missing: bool) -> bool:
    """Select the AWS test stack, optionally creating it when absent."""
    command = ["pulumi", "stack", "select", AWS_TEST_STACK_NAME]
    if create_if_missing:
        command.append("--create")
    completed = _run_subprocess(
        tuple(command),
        cwd=AWS_TEST_PULUMI_PROJECT_DIR,
        env=env,
        timeout_seconds=_PULUMI_COMMAND_TIMEOUT_SECONDS,
    )
    if completed.returncode == 0:
        return True
    if not create_if_missing:
        return False
    stderr_text = completed.stderr.strip() or completed.stdout.strip()
    raise AssertionError(f"failed to select Pulumi stack {AWS_TEST_STACK_NAME}: {stderr_text}")


def _pulumi_up(*, env: Mapping[str, str]) -> None:
    """Run `pulumi up` for the AWS test stack."""
    _require_subprocess_success(
        ("pulumi", "up", "--yes", "--stack", AWS_TEST_STACK_NAME),
        cwd=AWS_TEST_PULUMI_PROJECT_DIR,
        env=env,
        timeout_seconds=_PULUMI_COMMAND_TIMEOUT_SECONDS,
    )


def _pulumi_destroy(*, env: Mapping[str, str]) -> None:
    """Run `pulumi destroy` for the AWS test stack."""
    _require_subprocess_success(
        ("pulumi", "destroy", "--yes", "--stack", AWS_TEST_STACK_NAME),
        cwd=AWS_TEST_PULUMI_PROJECT_DIR,
        env=env,
        timeout_seconds=_PULUMI_COMMAND_TIMEOUT_SECONDS,
    )


def _pulumi_stack_remove(*, env: Mapping[str, str], force: bool = False) -> None:
    """Remove the Pulumi stack after all resources have been destroyed or abandoned."""
    command = ["pulumi", "stack", "rm", "--yes", "--remove-backups"]
    if force:
        command.append("--force")
    command.append(AWS_TEST_STACK_NAME)
    _require_subprocess_success(
        tuple(command),
        cwd=AWS_TEST_PULUMI_PROJECT_DIR,
        env=env,
        timeout_seconds=_PULUMI_COMMAND_TIMEOUT_SECONDS,
    )


def _pulumi_stack_outputs(*, env: Mapping[str, str]) -> dict[str, object]:
    """Load the Pulumi stack outputs as JSON."""
    stdout = _require_subprocess_success(
        ("pulumi", "stack", "output", "--json", "--stack", AWS_TEST_STACK_NAME),
        cwd=AWS_TEST_PULUMI_PROJECT_DIR,
        env=env,
        timeout_seconds=_PULUMI_COMMAND_TIMEOUT_SECONDS,
    )
    payload_raw: object = json.loads(stdout)
    return _mapping_from_json_object(payload_raw, context="pulumi stack output --json")


def _require_string(payload: Mapping[str, object], key: str) -> str:
    """Extract one required string value from a JSON-style mapping."""
    value = payload.get(key)
    if not isinstance(value, str) or value == "":
        raise AssertionError(f"missing string output {key}")
    return value


def _require_string_tuple(payload: Mapping[str, object], key: str) -> tuple[str, ...]:
    """Extract one required list-of-strings value from a JSON-style mapping."""
    items_raw = _list_from_json_value(payload.get(key), context=f"output {key}")
    items: list[str] = []
    for item in items_raw:
        if not isinstance(item, str) or item == "":
            raise AssertionError(f"output {key} must contain non-empty strings only")
        items.append(item)
    return tuple(items)


def _node_from_mapping(mapping: Mapping[str, object]) -> AwsTestNode:
    """Build one AWS test node from a JSON-derived mapping."""
    return AwsTestNode(
        name=_require_string(mapping, "name"),
        availability_zone=_require_string(mapping, "availability_zone"),
        instance_id=_require_string(mapping, "instance_id"),
        private_ip=_require_string(mapping, "private_ip"),
        public_ip=_require_string(mapping, "public_ip"),
    )


def _parse_nodes(payload: Mapping[str, object]) -> tuple[AwsTestNode, ...]:
    """Parse the exported node inventory from the AWS test Pulumi stack."""
    raw_nodes = _list_from_json_value(payload.get("nodes"), context="AWS test stack nodes")
    nodes = tuple(
        _node_from_mapping(_mapping_from_json_object(raw_node, context="AWS test stack node"))
        for raw_node in raw_nodes
    )
    if len(nodes) != 3:
        raise AssertionError(f"expected exactly 3 Pulumi-managed nodes, found {len(nodes)}")
    return nodes


def _snapshot_from_outputs(outputs: Mapping[str, object]) -> AwsTestStackSnapshot:
    """Build a persisted stack snapshot from Pulumi outputs."""
    return AwsTestStackSnapshot(
        stack_name=AWS_TEST_STACK_NAME,
        backend_bucket=_require_string(outputs, "backend_bucket"),
        vpc_id=_require_string(outputs, "vpc_id"),
        subnet_ids=_require_string_tuple(outputs, "subnet_ids"),
        security_group_id=_require_string(outputs, "security_group_id"),
        nodes=_parse_nodes(outputs),
    )


def _snapshot_json_payload(snapshot: AwsTestStackSnapshot) -> dict[str, object]:
    """Render one stack snapshot to a JSON-serializable mapping."""
    nodes_payload: list[dict[str, object]] = []
    for node in snapshot.nodes:
        nodes_payload.append(
            {
                "name": node.name,
                "availability_zone": node.availability_zone,
                "instance_id": node.instance_id,
                "private_ip": node.private_ip,
                "public_ip": node.public_ip,
            }
        )
    return {
        "stack_name": snapshot.stack_name,
        "backend_bucket": snapshot.backend_bucket,
        "vpc_id": snapshot.vpc_id,
        "subnet_ids": list(snapshot.subnet_ids),
        "security_group_id": snapshot.security_group_id,
        "nodes": nodes_payload,
    }


def save_aws_test_stack_snapshot(snapshot: AwsTestStackSnapshot) -> None:
    """Persist the latest AWS test stack identifiers under `.prodbox-state/`."""
    AWS_TEST_STATE_DIR.mkdir(parents=True, exist_ok=True)
    payload = _snapshot_json_payload(snapshot)
    AWS_TEST_STACK_SNAPSHOT_PATH.write_text(
        json.dumps(payload, indent=2, sort_keys=True),
        encoding="utf-8",
    )


def _load_stack_snapshot_from_outputs(*, env: Mapping[str, str]) -> AwsTestStackSnapshot | None:
    """Load stack outputs when available, returning None for partial stacks without exports."""
    try:
        return _snapshot_from_outputs(_pulumi_stack_outputs(env=env))
    except AssertionError:
        return None


def load_aws_test_stack_snapshot() -> AwsTestStackSnapshot | None:
    """Load the last saved AWS test stack snapshot when present."""
    if not AWS_TEST_STACK_SNAPSHOT_PATH.exists():
        return None
    payload_raw: object = json.loads(AWS_TEST_STACK_SNAPSHOT_PATH.read_text(encoding="utf-8"))
    payload = _mapping_from_json_object(
        payload_raw,
        context="saved AWS test stack snapshot",
    )
    raw_nodes = _list_from_json_value(payload.get("nodes"), context="saved AWS test stack nodes")
    nodes = tuple(
        _node_from_mapping(_mapping_from_json_object(raw_node, context="saved AWS test stack node"))
        for raw_node in raw_nodes
    )
    return AwsTestStackSnapshot(
        stack_name=_require_string(payload, "stack_name"),
        backend_bucket=_require_string(payload, "backend_bucket"),
        vpc_id=_require_string(payload, "vpc_id"),
        subnet_ids=_require_string_tuple(payload, "subnet_ids"),
        security_group_id=_require_string(payload, "security_group_id"),
        nodes=nodes,
    )


def clear_aws_test_stack_snapshot() -> None:
    """Delete the local stack snapshot artifact when present."""
    if AWS_TEST_STACK_SNAPSHOT_PATH.exists():
        AWS_TEST_STACK_SNAPSHOT_PATH.unlink()


def _settings_aws_env() -> dict[str, str]:
    """Build AWS CLI credentials from the canonical prodbox settings."""
    from prodbox.settings import get_settings

    settings = get_settings()
    env = _base_env()
    env["AWS_ACCESS_KEY_ID"] = settings.aws_access_key_id
    env["AWS_SECRET_ACCESS_KEY"] = settings.aws_secret_access_key
    env["AWS_REGION"] = settings.aws_region
    env["AWS_DEFAULT_REGION"] = settings.aws_region
    match settings.aws_session_token:
        case str() as token:
            env["AWS_SESSION_TOKEN"] = token
        case None:
            pass
    return env


def _resource_missing(stderr_text: str) -> bool:
    """Return whether an AWS CLI failure only reports a missing resource."""
    lowered = stderr_text.lower()
    return (
        "notfound" in lowered
        or "not found" in lowered
        or "does not exist" in lowered
        or "invalidgroup.notfound" in lowered
        or "invalidsubnetid.notfound" in lowered
        or "invalidvpcid.notfound" in lowered
        or "invalidinstanceid.notfound" in lowered
        or "nokeypair" in lowered
        or "nosuchentity" in lowered
    )


def _aws_resource_still_exists(command: tuple[str, ...]) -> bool:
    """Return whether one AWS resource is still visible."""
    completed = _run_subprocess(
        command,
        env=_settings_aws_env(),
        timeout_seconds=_AWS_CLI_TIMEOUT_SECONDS,
    )
    if completed.returncode == 0:
        return True
    stderr_text = completed.stderr.strip() or completed.stdout.strip()
    if _resource_missing(stderr_text):
        return False
    raise AssertionError(f"{' '.join(command)} failed: {stderr_text}")


def _aws_instance_still_exists(instance_id: str) -> bool:
    """Return whether one EC2 instance still exists beyond the terminated state."""
    command = (
        "aws",
        "ec2",
        "describe-instances",
        "--instance-ids",
        instance_id,
        "--query",
        "Reservations[].Instances[].State.Name",
        "--output",
        "text",
    )
    completed = _run_subprocess(
        command,
        env=_settings_aws_env(),
        timeout_seconds=_AWS_CLI_TIMEOUT_SECONDS,
    )
    if completed.returncode == 0:
        state = completed.stdout.strip().lower()
        return state not in ("", "none", "terminated")
    stderr_text = completed.stderr.strip() or completed.stdout.strip()
    if _resource_missing(stderr_text):
        return False
    raise AssertionError(f"{' '.join(command)} failed: {stderr_text}")


def assert_no_aws_test_stack_residue(snapshot: AwsTestStackSnapshot | None = None) -> None:
    """Require the last-known AWS test stack resources to be fully destroyed."""
    current = snapshot if snapshot is not None else load_aws_test_stack_snapshot()
    if current is None:
        return

    remaining: list[str] = []
    if _aws_resource_still_exists(("aws", "ec2", "describe-vpcs", "--vpc-ids", current.vpc_id)):
        remaining.append(f"vpc={current.vpc_id}")
    for subnet_id in current.subnet_ids:
        if _aws_resource_still_exists(
            ("aws", "ec2", "describe-subnets", "--subnet-ids", subnet_id)
        ):
            remaining.append(f"subnet={subnet_id}")
    if _aws_resource_still_exists(
        ("aws", "ec2", "describe-security-groups", "--group-ids", current.security_group_id)
    ):
        remaining.append(f"security-group={current.security_group_id}")
    for node in current.nodes:
        if _aws_instance_still_exists(node.instance_id):
            remaining.append(f"instance={node.instance_id}")
    if remaining:
        raise AssertionError("AWS test stack residue remains: " + ", ".join(remaining))


def render_aws_test_stack_report(
    *,
    snapshot: AwsTestStackSnapshot,
    backend_object_count: int,
) -> str:
    """Render a deterministic human-readable report for the AWS test stack."""
    lines = [
        f"STACK={snapshot.stack_name}",
        f"BACKEND_BUCKET={snapshot.backend_bucket}",
        f"BACKEND_OBJECT_COUNT={backend_object_count}",
        f"VPC_ID={snapshot.vpc_id}",
        f"SUBNET_IDS={','.join(snapshot.subnet_ids)}",
        f"SECURITY_GROUP_ID={snapshot.security_group_id}",
        f"NODE_COUNT={len(snapshot.nodes)}",
    ]
    for index, node in enumerate(snapshot.nodes):
        lines.extend(
            [
                f"NODE_{index}_NAME={node.name}",
                f"NODE_{index}_AZ={node.availability_zone}",
                f"NODE_{index}_INSTANCE_ID={node.instance_id}",
                f"NODE_{index}_PRIVATE_IP={node.private_ip}",
                f"NODE_{index}_PUBLIC_IP={node.public_ip}",
            ]
        )
    return "\n".join(lines) + "\n"


def ensure_aws_test_stack_resources() -> AwsTestStackSnapshot:
    """Provision or reconcile the Pulumi-managed AWS test stack."""
    if not AWS_TEST_PULUMI_PROJECT_DIR.exists():
        raise AssertionError(f"Pulumi AWS test project missing: {AWS_TEST_PULUMI_PROJECT_DIR}")

    with minio_port_forward():
        access_key, secret_key = _minio_credentials()
        _ensure_minio_backend_bucket(
            local_port=AWS_TEST_BACKEND_LOCAL_PORT,
            access_key=access_key,
            secret_key=secret_key,
        )
        env = _pulumi_test_env(
            local_port=AWS_TEST_BACKEND_LOCAL_PORT,
            minio_access_key=access_key,
            minio_secret_key=secret_key,
        )
        _pulumi_login(env=env)
        _pulumi_stack_select(env=env, create_if_missing=True)
        _pulumi_up(env=env)
        snapshot = _snapshot_from_outputs(_pulumi_stack_outputs(env=env))
        save_aws_test_stack_snapshot(snapshot)
        backend_object_count = _bucket_object_count(
            local_port=AWS_TEST_BACKEND_LOCAL_PORT,
            access_key=access_key,
            secret_key=secret_key,
        )
        print(
            render_aws_test_stack_report(
                snapshot=snapshot,
                backend_object_count=backend_object_count,
            ),
            end="",
        )
        return snapshot


def destroy_aws_test_stack() -> str:
    """Destroy the Pulumi-managed AWS test stack and verify zero residue."""
    current_snapshot = load_aws_test_stack_snapshot()

    if not _local_minio_backend_available():
        if current_snapshot is not None:
            raise AssertionError(
                "local MinIO backend unavailable while an AWS test stack snapshot still exists; "
                "cannot verify or destroy AWS residue automatically"
            )
        message = (
            "Skipped AWS test stack destroy because the local MinIO backend is not present "
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
        env = _pulumi_test_env(
            local_port=AWS_TEST_BACKEND_LOCAL_PORT,
            minio_access_key=access_key,
            minio_secret_key=secret_key,
        )
        _pulumi_login(env=env)
        stack_exists = _pulumi_stack_select(env=env, create_if_missing=False)
        if stack_exists:
            if current_snapshot is None:
                current_snapshot = _load_stack_snapshot_from_outputs(env=env)
            if current_snapshot is not None:
                save_aws_test_stack_snapshot(current_snapshot)
            try:
                _pulumi_destroy(env=env)
                _pulumi_stack_remove(env=env)
            except AssertionError:
                if current_snapshot is not None:
                    raise
                _pulumi_stack_remove(env=env, force=True)
        if current_snapshot is not None:
            assert_no_aws_test_stack_residue(current_snapshot)
        backend_object_count = _bucket_object_count(
            local_port=AWS_TEST_BACKEND_LOCAL_PORT,
            access_key=access_key,
            secret_key=secret_key,
        )
        if backend_object_count != 0:
            raise AssertionError(
                f"backend bucket {AWS_TEST_BACKEND_BUCKET} still contains {backend_object_count} object(s)"
            )
    clear_aws_test_stack_snapshot()
    residue_text = (
        "verified no AWS residue"
        if current_snapshot is not None
        else "removed the Pulumi stack without exported residue identifiers"
    )
    message = (
        f"Destroyed stack {AWS_TEST_STACK_NAME}; "
        f"{residue_text} and an empty backend bucket {AWS_TEST_BACKEND_BUCKET}"
    )
    print(message)
    return message


__all__ = [
    "AWS_TEST_BACKEND_BUCKET",
    "AWS_TEST_PRIVATE_KEY_PATH",
    "AWS_TEST_STACK_NAME",
    "AwsTestNode",
    "AwsTestStackSnapshot",
    "assert_no_aws_test_stack_residue",
    "destroy_aws_test_stack",
    "ensure_aws_test_ssh_key",
    "ensure_aws_test_stack_resources",
    "load_aws_test_stack_snapshot",
    "render_aws_test_stack_report",
]
