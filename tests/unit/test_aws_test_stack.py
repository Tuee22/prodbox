"""Unit tests for AWS test-stack residue helpers."""

from __future__ import annotations

import subprocess

import pytest

import prodbox.lib.aws_test_stack as aws_test_stack_module
from prodbox.lib.aws_test_stack import AwsTestNode, AwsTestStackSnapshot


class TestAwsInstanceResidue:
    """Verify EC2 instance residue detection semantics."""

    def test_aws_instance_still_exists_returns_false_for_terminated_instance(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Recently terminated instances should not count as AWS residue."""

        def fake_run_subprocess(
            command: tuple[str, ...],
            *,
            env: dict[str, str] | None = None,
            cwd: object = None,
            timeout_seconds: float,
            input_text: str | None = None,
        ) -> subprocess.CompletedProcess[str]:
            assert env == {"AWS_ACCESS_KEY_ID": "test"}
            assert cwd is None
            assert timeout_seconds == aws_test_stack_module._AWS_CLI_TIMEOUT_SECONDS
            assert input_text is None
            assert command == (
                "aws",
                "ec2",
                "describe-instances",
                "--instance-ids",
                "i-test",
                "--query",
                "Reservations[].Instances[].State.Name",
                "--output",
                "text",
            )
            return subprocess.CompletedProcess(command, 0, stdout="terminated\n", stderr="")

        monkeypatch.setattr(aws_test_stack_module, "_run_subprocess", fake_run_subprocess)
        monkeypatch.setattr(
            aws_test_stack_module, "_settings_aws_env", lambda: {"AWS_ACCESS_KEY_ID": "test"}
        )

        assert aws_test_stack_module._aws_instance_still_exists("i-test") is False

    def test_assert_no_aws_test_stack_residue_ignores_terminated_instances(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Residue assertion should pass when only terminated instances remain visible."""
        snapshot = AwsTestStackSnapshot(
            stack_name="aws-test",
            backend_bucket="bucket",
            vpc_id="vpc-123",
            subnet_ids=("subnet-1", "subnet-2", "subnet-3"),
            security_group_id="sg-123",
            nodes=(
                AwsTestNode(
                    name="node-0",
                    availability_zone="us-east-1a",
                    instance_id="i-0",
                    private_ip="10.0.0.1",
                    public_ip="1.2.3.4",
                ),
                AwsTestNode(
                    name="node-1",
                    availability_zone="us-east-1b",
                    instance_id="i-1",
                    private_ip="10.0.1.1",
                    public_ip="1.2.3.5",
                ),
                AwsTestNode(
                    name="node-2",
                    availability_zone="us-east-1c",
                    instance_id="i-2",
                    private_ip="10.0.2.1",
                    public_ip="1.2.3.6",
                ),
            ),
        )

        monkeypatch.setattr(
            aws_test_stack_module, "_aws_resource_still_exists", lambda _command: False
        )
        monkeypatch.setattr(
            aws_test_stack_module, "_aws_instance_still_exists", lambda _instance_id: False
        )

        aws_test_stack_module.assert_no_aws_test_stack_residue(snapshot)
