"""Unit tests for the AWS EKS test-stack helpers."""

from __future__ import annotations

from contextlib import nullcontext
from pathlib import Path

import pytest

import prodbox.lib.aws_eks_test_stack as aws_eks_test_stack_module
from prodbox.lib.aws_eks_test_stack import AwsEksTestStackSnapshot


def _snapshot() -> AwsEksTestStackSnapshot:
    return AwsEksTestStackSnapshot(
        stack_name="aws-eks-test",
        backend_bucket="prodbox-test-pulumi-backends",
        cluster_name="aws-eks-test-cluster",
        cluster_role_name="aws-eks-test-cluster-role",
        node_group_name="aws-eks-test-node-group",
        node_role_name="aws-eks-test-node-role",
        vpc_id="vpc-123",
        subnet_ids=("subnet-1", "subnet-2"),
        cluster_security_group_id="sg-123",
    )


def test_snapshot_from_outputs_round_trips_through_json_payload() -> None:
    """Snapshot parsing should preserve the exported EKS stack identifiers."""
    outputs = {
        "backend_bucket": "prodbox-test-pulumi-backends",
        "cluster_name": "aws-eks-test-cluster",
        "cluster_role_name": "aws-eks-test-cluster-role",
        "node_group_name": "aws-eks-test-node-group",
        "node_role_name": "aws-eks-test-node-role",
        "vpc_id": "vpc-123",
        "subnet_ids": ["subnet-1", "subnet-2"],
        "cluster_security_group_id": "sg-123",
    }

    snapshot = aws_eks_test_stack_module._snapshot_from_outputs(outputs)

    assert snapshot == _snapshot()
    assert aws_eks_test_stack_module._snapshot_json_payload(snapshot) == {
        "stack_name": "aws-eks-test",
        "backend_bucket": "prodbox-test-pulumi-backends",
        "cluster_name": "aws-eks-test-cluster",
        "cluster_role_name": "aws-eks-test-cluster-role",
        "node_group_name": "aws-eks-test-node-group",
        "node_role_name": "aws-eks-test-node-role",
        "vpc_id": "vpc-123",
        "subnet_ids": ["subnet-1", "subnet-2"],
        "cluster_security_group_id": "sg-123",
    }


def test_node_names_from_json_parses_kubectl_payload() -> None:
    """kubectl node JSON should be reduced to deterministic node-name tuples."""
    stdout = (
        '{"items": ['
        '{"metadata": {"name": "ip-10-0-0-1"}}, '
        '{"metadata": {"name": "ip-10-0-1-1"}}'
        "]}"
    )

    assert aws_eks_test_stack_module._node_names_from_json(stdout) == (
        "ip-10-0-0-1",
        "ip-10-0-1-1",
    )


def test_kubectl_env_includes_settings_backed_aws_credentials(tmp_path: Path) -> None:
    """kubectl env should preserve AWS auth for the kubeconfig exec token plugin."""
    kubeconfig_path = tmp_path / "config"
    with pytest.MonkeyPatch.context() as monkeypatch:
        monkeypatch.setattr(
            aws_eks_test_stack_module,
            "_settings_aws_env",
            lambda: {
                "PATH": "/usr/bin",
                "HOME": "/tmp/home",
                "AWS_ACCESS_KEY_ID": "AKIAEXAMPLE",
                "AWS_SECRET_ACCESS_KEY": "secret",
                "AWS_REGION": "us-west-2",
                "AWS_DEFAULT_REGION": "us-west-2",
            },
        )
        env = aws_eks_test_stack_module._kubectl_env(kubeconfig_path=kubeconfig_path)

    assert env["KUBECONFIG"] == str(kubeconfig_path)
    assert env["AWS_ACCESS_KEY_ID"] == "AKIAEXAMPLE"
    assert env["AWS_SECRET_ACCESS_KEY"] == "secret"
    assert env["AWS_REGION"] == "us-west-2"
    assert env["AWS_DEFAULT_REGION"] == "us-west-2"


def test_assert_no_aws_eks_test_stack_residue_passes_when_everything_is_gone(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Residue checks should succeed once every exported resource has disappeared."""
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "_aws_resource_still_exists",
        lambda _command: False,
    )

    aws_eks_test_stack_module.assert_no_aws_eks_test_stack_residue(_snapshot())


def test_assert_no_aws_eks_test_stack_residue_reports_remaining_cluster(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Residue checks should surface any surviving EKS cluster identifier."""

    def fake_exists(command: tuple[str, ...]) -> bool:
        return command[:3] == ("aws", "eks", "describe-cluster")

    monkeypatch.setattr(aws_eks_test_stack_module, "_aws_resource_still_exists", fake_exists)

    with pytest.raises(AssertionError, match="cluster=aws-eks-test-cluster"):
        aws_eks_test_stack_module.assert_no_aws_eks_test_stack_residue(_snapshot())


def test_render_aws_eks_test_stack_report_lists_canonical_fields() -> None:
    """Human-readable reports should include the exported EKS identifiers."""
    report = aws_eks_test_stack_module.render_aws_eks_test_stack_report(
        snapshot=_snapshot(),
        backend_object_count=7,
    )

    assert "STACK=aws-eks-test" in report
    assert "BACKEND_OBJECT_COUNT=7" in report
    assert "CLUSTER_NAME=aws-eks-test-cluster" in report
    assert "NODE_GROUP_NAME=aws-eks-test-node-group" in report
    assert "SUBNET_IDS=subnet-1,subnet-2" in report


def test_destroy_aws_eks_test_stack_skips_without_backend_and_without_snapshot(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Destroy should degrade cleanly when no backend or saved snapshot exists."""
    monkeypatch.setattr(aws_eks_test_stack_module, "_local_minio_backend_available", lambda: False)
    monkeypatch.setattr(aws_eks_test_stack_module, "load_aws_eks_test_stack_snapshot", lambda: None)

    message = aws_eks_test_stack_module.destroy_aws_eks_test_stack()

    assert "Skipped AWS EKS test stack destroy" in message


def test_destroy_aws_eks_test_stack_tolerates_partial_stack_without_outputs(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Destroy should still remove the Pulumi stack when partial state lacks full outputs."""
    monkeypatch.setattr(aws_eks_test_stack_module, "_local_minio_backend_available", lambda: True)
    monkeypatch.setattr(aws_eks_test_stack_module, "load_aws_eks_test_stack_snapshot", lambda: None)
    monkeypatch.setattr(aws_eks_test_stack_module, "minio_port_forward", lambda: nullcontext())
    monkeypatch.setattr(
        aws_eks_test_stack_module, "_minio_credentials", lambda: ("minio", "secret")
    )
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "_ensure_minio_backend_bucket",
        lambda **_kwargs: None,
    )
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "_pulumi_eks_env",
        lambda **_kwargs: {},
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_login", lambda **_kwargs: None)
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "_pulumi_stack_select",
        lambda **_kwargs: True,
    )
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "_pulumi_stack_outputs",
        lambda **_kwargs: {},
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_destroy", lambda **_kwargs: None)
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_stack_remove", lambda **_kwargs: None)
    monkeypatch.setattr(aws_eks_test_stack_module, "_bucket_object_count", lambda **_kwargs: 0)
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "clear_aws_eks_test_stack_snapshot",
        lambda: None,
    )

    message = aws_eks_test_stack_module.destroy_aws_eks_test_stack()

    assert "removed the Pulumi stack without exported residue identifiers" in message


def test_destroy_aws_eks_test_stack_recovers_from_pulumi_destroy_lock(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Destroy should cancel a stale Pulumi lock and retry the stack destroy."""
    destroy_attempts: list[str] = []
    cancel_calls: list[str] = []

    def fake_destroy(**_kwargs: object) -> None:
        destroy_attempts.append("destroy")
        if len(destroy_attempts) == 1:
            raise AssertionError("the stack is currently locked")

    monkeypatch.setattr(aws_eks_test_stack_module, "_local_minio_backend_available", lambda: True)
    monkeypatch.setattr(
        aws_eks_test_stack_module, "load_aws_eks_test_stack_snapshot", lambda: _snapshot()
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "minio_port_forward", lambda: nullcontext())
    monkeypatch.setattr(
        aws_eks_test_stack_module, "_minio_credentials", lambda: ("minio", "secret")
    )
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "_ensure_minio_backend_bucket",
        lambda **_kwargs: None,
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_eks_env", lambda **_kwargs: {})
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_login", lambda **_kwargs: None)
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_stack_select", lambda **_kwargs: True)
    monkeypatch.setattr(
        aws_eks_test_stack_module, "save_aws_eks_test_stack_snapshot", lambda _v: None
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_destroy", fake_destroy)
    monkeypatch.setattr(
        aws_eks_test_stack_module, "_pulumi_cancel", lambda **_kwargs: cancel_calls.append("cancel")
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_stack_remove", lambda **_kwargs: None)
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "assert_no_aws_eks_test_stack_residue",
        lambda _snapshot_value: None,
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "_bucket_object_count", lambda **_kwargs: 0)
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "clear_aws_eks_test_stack_snapshot",
        lambda: None,
    )

    message = aws_eks_test_stack_module.destroy_aws_eks_test_stack()

    assert "verified no AWS residue" in message
    assert destroy_attempts == ["destroy", "destroy"]
    assert cancel_calls == ["cancel"]


def test_destroy_aws_eks_test_stack_recovers_from_pulumi_stack_remove_lock(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Destroy should cancel a stale Pulumi lock and force-remove the stack."""
    remove_calls: list[bool] = []
    cancel_calls: list[str] = []

    def fake_remove(**kwargs: object) -> None:
        force = bool(kwargs.get("force", False))
        remove_calls.append(force)
        if force is False:
            raise AssertionError("the stack is currently locked")

    monkeypatch.setattr(aws_eks_test_stack_module, "_local_minio_backend_available", lambda: True)
    monkeypatch.setattr(
        aws_eks_test_stack_module, "load_aws_eks_test_stack_snapshot", lambda: _snapshot()
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "minio_port_forward", lambda: nullcontext())
    monkeypatch.setattr(
        aws_eks_test_stack_module, "_minio_credentials", lambda: ("minio", "secret")
    )
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "_ensure_minio_backend_bucket",
        lambda **_kwargs: None,
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_eks_env", lambda **_kwargs: {})
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_login", lambda **_kwargs: None)
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_stack_select", lambda **_kwargs: True)
    monkeypatch.setattr(
        aws_eks_test_stack_module, "save_aws_eks_test_stack_snapshot", lambda _v: None
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_destroy", lambda **_kwargs: None)
    monkeypatch.setattr(
        aws_eks_test_stack_module, "_pulumi_cancel", lambda **_kwargs: cancel_calls.append("cancel")
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_stack_remove", fake_remove)
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "assert_no_aws_eks_test_stack_residue",
        lambda _snapshot_value: None,
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "_bucket_object_count", lambda **_kwargs: 0)
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "clear_aws_eks_test_stack_snapshot",
        lambda: None,
    )

    message = aws_eks_test_stack_module.destroy_aws_eks_test_stack()

    assert "verified no AWS residue" in message
    assert remove_calls == [False, True]
    assert cancel_calls == ["cancel"]


def test_destroy_aws_eks_test_stack_refreshes_after_interrupted_pending_operations(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Destroy should refresh the stack and retry when Pulumi reports pending EKS operations."""
    destroy_attempts: list[str] = []
    refresh_calls: list[str] = []

    def fake_destroy(**_kwargs: object) -> None:
        destroy_attempts.append("destroy")
        if len(destroy_attempts) == 1:
            raise AssertionError("pending operations remain and Cluster has nodegroups attached")

    monkeypatch.setattr(aws_eks_test_stack_module, "_local_minio_backend_available", lambda: True)
    monkeypatch.setattr(
        aws_eks_test_stack_module, "load_aws_eks_test_stack_snapshot", lambda: _snapshot()
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "minio_port_forward", lambda: nullcontext())
    monkeypatch.setattr(
        aws_eks_test_stack_module, "_minio_credentials", lambda: ("minio", "secret")
    )
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "_ensure_minio_backend_bucket",
        lambda **_kwargs: None,
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_eks_env", lambda **_kwargs: {})
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_login", lambda **_kwargs: None)
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_stack_select", lambda **_kwargs: True)
    monkeypatch.setattr(
        aws_eks_test_stack_module, "save_aws_eks_test_stack_snapshot", lambda _v: None
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_destroy", fake_destroy)
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "_pulumi_refresh",
        lambda **_kwargs: refresh_calls.append("refresh"),
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "_pulumi_stack_remove", lambda **_kwargs: None)
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "assert_no_aws_eks_test_stack_residue",
        lambda _snapshot_value: None,
    )
    monkeypatch.setattr(aws_eks_test_stack_module, "_bucket_object_count", lambda **_kwargs: 0)
    monkeypatch.setattr(
        aws_eks_test_stack_module,
        "clear_aws_eks_test_stack_snapshot",
        lambda: None,
    )

    message = aws_eks_test_stack_module.destroy_aws_eks_test_stack()

    assert "verified no AWS residue" in message
    assert destroy_attempts == ["destroy", "destroy"]
    assert refresh_calls == ["refresh"]
