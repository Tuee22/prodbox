"""SSH-driven HA RKE2 bootstrap helpers for the AWS test stack."""

from __future__ import annotations

import json
import secrets
import shutil
import subprocess
import tempfile
import time
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from prodbox.lib.aws_test_stack import (
    AWS_TEST_PRIVATE_KEY_PATH,
    AwsTestNode,
    AwsTestStackSnapshot,
    ensure_aws_test_stack_resources,
)

_SSH_COMMON_ARGS: tuple[str, ...] = (
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    "UserKnownHostsFile=/dev/null",
    "-o",
    "ConnectTimeout=10",
)
_SSH_TIMEOUT_SECONDS: float = 900.0
_SSH_READY_TIMEOUT_SECONDS: float = 300.0
_REMOTE_RKE2_READY_TIMEOUT_SECONDS: float = 900.0
_REMOTE_RKE2_POLL_SECONDS: float = 10.0
_REMOTE_RKE2_NODE_USER: str = "ubuntu"


@dataclass(frozen=True)
class HaRke2ValidationResult:
    """Summary of one successful HA-RKE2 validation run."""

    leader_name: str
    leader_public_ip: str
    node_names: tuple[str, ...]
    availability_zones: tuple[str, ...]

    def render(self) -> str:
        """Render a deterministic validation report."""
        return (
            "\n".join(
                [
                    f"LEADER_NAME={self.leader_name}",
                    f"LEADER_PUBLIC_IP={self.leader_public_ip}",
                    f"NODE_COUNT={len(self.node_names)}",
                    f"NODE_NAMES={','.join(self.node_names)}",
                    f"AVAILABILITY_ZONES={','.join(self.availability_zones)}",
                    "RKE2_HA_STATUS=ready",
                ]
            )
            + "\n"
        )


def _mapping_from_json_object(value: object, *, context: str) -> Mapping[str, object]:
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


def _require_ssh_tools() -> None:
    """Fail fast when SSH tooling is unavailable."""
    if shutil.which("ssh") is None:
        raise AssertionError("ssh not installed")
    if not AWS_TEST_PRIVATE_KEY_PATH.exists():
        raise AssertionError(f"AWS test SSH key not found: {AWS_TEST_PRIVATE_KEY_PATH}")


def _run_ssh(
    node: AwsTestNode,
    *,
    remote_command: str,
    timeout_seconds: float,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run one remote command via OpenSSH."""
    command = (
        "ssh",
        *_SSH_COMMON_ARGS,
        "-i",
        str(AWS_TEST_PRIVATE_KEY_PATH),
        f"{_REMOTE_RKE2_NODE_USER}@{node.public_ip}",
        remote_command,
    )
    return subprocess.run(
        command,
        capture_output=True,
        check=False,
        text=True,
        timeout=timeout_seconds,
        input=input_text,
    )


def _require_ssh_success(
    node: AwsTestNode,
    *,
    remote_command: str,
    timeout_seconds: float,
    input_text: str | None = None,
) -> str:
    """Run one remote SSH command and return stdout on success."""
    completed = _run_ssh(
        node,
        remote_command=remote_command,
        timeout_seconds=timeout_seconds,
        input_text=input_text,
    )
    if completed.returncode != 0:
        stderr_text = completed.stderr.strip() or completed.stdout.strip()
        raise AssertionError(f"ssh command failed on {node.name} ({node.public_ip}): {stderr_text}")
    return completed.stdout


def _wait_for_ssh_ready(node: AwsTestNode) -> None:
    """Poll until SSH is reachable on the given node."""
    deadline = time.monotonic() + _SSH_READY_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        completed = _run_ssh(
            node,
            remote_command="true",
            timeout_seconds=20.0,
        )
        if completed.returncode == 0:
            return
        time.sleep(5.0)
    raise AssertionError(f"timed out waiting for SSH on {node.name} ({node.public_ip})")


def _wait_for_cloud_init(node: AwsTestNode) -> None:
    """Wait for cloud-init completion on one remote node."""
    _require_ssh_success(
        node,
        remote_command="sudo cloud-init status --wait",
        timeout_seconds=_SSH_TIMEOUT_SECONDS,
    )


def _reset_rke2_host(node: AwsTestNode) -> None:
    """Remove any pre-existing RKE2 install from the ephemeral test node."""
    _require_ssh_success(
        node,
        remote_command=(
            "set -euo pipefail; "
            "if [ -x /usr/local/bin/rke2-killall.sh ]; then sudo /usr/local/bin/rke2-killall.sh || true; fi; "
            "if [ -x /usr/local/bin/rke2-uninstall.sh ]; then sudo /usr/local/bin/rke2-uninstall.sh || true; fi; "
            "sudo rm -rf /etc/rancher/rke2 /var/lib/rancher /var/lib/rke2 || true"
        ),
        timeout_seconds=_SSH_TIMEOUT_SECONDS,
    )


def _leader_config_yaml(*, token: str, leader: AwsTestNode) -> str:
    """Render the RKE2 config for the cluster-init node."""
    return "\n".join(
        [
            'write-kubeconfig-mode: "0644"',
            f"node-name: {leader.name}",
            f"token: {token}",
            "cluster-init: true",
            "tls-san:",
            f"  - {leader.public_ip}",
            f"  - {leader.private_ip}",
            "",
        ]
    )


def _joiner_config_yaml(*, token: str, node: AwsTestNode, leader: AwsTestNode) -> str:
    """Render the RKE2 config for one joining server node."""
    return "\n".join(
        [
            'write-kubeconfig-mode: "0644"',
            f"node-name: {node.name}",
            f"token: {token}",
            f"server: https://{leader.private_ip}:9345",
            "",
        ]
    )


def _install_rke2_server(node: AwsTestNode, *, config_yaml: str) -> None:
    """Install and start the RKE2 server service on one remote node."""
    script = "\n".join(
        [
            "set -euo pipefail",
            "sudo apt-get update",
            "sudo apt-get install -y curl jq",
            "curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE=server sh -",
            "sudo mkdir -p /etc/rancher/rke2",
            "cat <<'EOF' | sudo tee /etc/rancher/rke2/config.yaml >/dev/null",
            config_yaml.rstrip(),
            "EOF",
            "sudo systemctl enable rke2-server.service",
            "sudo systemctl restart rke2-server.service || sudo systemctl start rke2-server.service",
        ]
    )
    _require_ssh_success(
        node,
        remote_command="bash -s",
        timeout_seconds=_SSH_TIMEOUT_SECONDS,
        input_text=script,
    )


def _wait_for_leader_server_ready(leader: AwsTestNode) -> None:
    """Wait until the leader server has finished bootstrapping its local control plane."""
    deadline = time.monotonic() + _REMOTE_RKE2_READY_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        completed = _run_ssh(
            leader,
            remote_command=(
                "test -f /etc/rancher/rke2/rke2.yaml && "
                "sudo systemctl is-active rke2-server.service"
            ),
            timeout_seconds=60.0,
        )
        if completed.returncode == 0 and completed.stdout.strip() == "active":
            return
        time.sleep(_REMOTE_RKE2_POLL_SECONDS)
    raise AssertionError("timed out waiting for the leader RKE2 server to become active")


def _wait_for_remote_cluster_ready(leader: AwsTestNode) -> None:
    """Wait until the remote HA-RKE2 cluster reports three Ready nodes."""
    deadline = time.monotonic() + _REMOTE_RKE2_READY_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        completed = _run_ssh(
            leader,
            remote_command=(
                "sudo /var/lib/rancher/rke2/bin/kubectl "
                "--kubeconfig /etc/rancher/rke2/rke2.yaml "
                "get nodes -o json"
            ),
            timeout_seconds=60.0,
        )
        if completed.returncode == 0:
            payload_raw: object = json.loads(completed.stdout)
            payload = _mapping_from_json_object(payload_raw, context="remote kubectl get nodes")
            items = _list_from_json_value(payload.get("items"), context="remote kubectl items")
            if len(items) == 3:
                ready_count = 0
                for raw_item in items:
                    if not isinstance(raw_item, dict):
                        continue
                    item = _mapping_from_json_object(raw_item, context="remote node entry")
                    status_raw = item.get("status")
                    if not isinstance(status_raw, dict):
                        continue
                    status = _mapping_from_json_object(status_raw, context="remote node status")
                    conditions_raw = status.get("conditions")
                    if not isinstance(conditions_raw, list):
                        continue
                    conditions = _list_from_json_value(
                        conditions_raw,
                        context="remote node conditions",
                    )
                    is_ready = False
                    for condition in conditions:
                        if not isinstance(condition, dict):
                            continue
                        condition_mapping = _mapping_from_json_object(
                            condition,
                            context="remote node condition",
                        )
                        if (
                            condition_mapping.get("type") == "Ready"
                            and condition_mapping.get("status") == "True"
                        ):
                            is_ready = True
                            break
                    if is_ready:
                        ready_count += 1
                if ready_count == 3:
                    return
        time.sleep(_REMOTE_RKE2_POLL_SECONDS)
    raise AssertionError("timed out waiting for the remote HA-RKE2 cluster to report 3 Ready nodes")


def _fetch_remote_kubeconfig(leader: AwsTestNode) -> str:
    """Fetch the leader kubeconfig and rewrite it for host-side access."""
    kubeconfig = _require_ssh_success(
        leader,
        remote_command="sudo cat /etc/rancher/rke2/rke2.yaml",
        timeout_seconds=60.0,
    )
    return kubeconfig.replace("127.0.0.1", leader.public_ip, 1)


def _validate_remote_kubeconfig(leader: AwsTestNode) -> None:
    """Use the local kubectl binary to confirm 3 Ready nodes via the exported kubeconfig."""
    kubeconfig = _fetch_remote_kubeconfig(leader)
    with tempfile.TemporaryDirectory(prefix="prodbox-ha-rke2-aws-") as temp_dir:
        kubeconfig_path = Path(temp_dir) / "kubeconfig"
        kubeconfig_path.write_text(kubeconfig, encoding="utf-8")
        completed = subprocess.run(
            (
                "kubectl",
                "--kubeconfig",
                str(kubeconfig_path),
                "get",
                "nodes",
                "-o",
                "json",
            ),
            capture_output=True,
            check=False,
            text=True,
            timeout=120.0,
        )
        if completed.returncode != 0:
            stderr_text = completed.stderr.strip() or completed.stdout.strip()
            raise AssertionError(
                f"local kubectl failed against the HA-RKE2 kubeconfig: {stderr_text}"
            )
        payload_raw: object = json.loads(completed.stdout)
        payload = _mapping_from_json_object(payload_raw, context="local kubectl get nodes")
        items = _list_from_json_value(payload.get("items"), context="local kubectl items")
        if len(items) != 3:
            raise AssertionError("the remote HA-RKE2 cluster did not return exactly 3 nodes")


def _bootstrap_remote_cluster(snapshot: AwsTestStackSnapshot) -> HaRke2ValidationResult:
    """Install HA-RKE2 across the three Pulumi-managed EC2 nodes."""
    _require_ssh_tools()
    nodes = snapshot.nodes
    leader = nodes[0]
    joiners = nodes[1:]

    for node in nodes:
        _wait_for_ssh_ready(node)
        _wait_for_cloud_init(node)
        _reset_rke2_host(node)

    token = secrets.token_urlsafe(32)
    _install_rke2_server(leader, config_yaml=_leader_config_yaml(token=token, leader=leader))
    _wait_for_leader_server_ready(leader)
    for node in joiners:
        _install_rke2_server(
            node,
            config_yaml=_joiner_config_yaml(token=token, node=node, leader=leader),
        )
    _wait_for_remote_cluster_ready(leader)
    _validate_remote_kubeconfig(leader)
    return HaRke2ValidationResult(
        leader_name=leader.name,
        leader_public_ip=leader.public_ip,
        node_names=tuple(node.name for node in nodes),
        availability_zones=tuple(node.availability_zone for node in nodes),
    )


def bootstrap_and_validate_ha_rke2_cluster() -> HaRke2ValidationResult:
    """Provision the AWS test stack and prove HA-RKE2 over SSH."""
    snapshot = ensure_aws_test_stack_resources()
    result = _bootstrap_remote_cluster(snapshot)
    print(result.render(), end="")
    return result


__all__ = [
    "HaRke2ValidationResult",
    "bootstrap_and_validate_ha_rke2_cluster",
]
