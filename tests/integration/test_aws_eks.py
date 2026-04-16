"""Real EKS integration tests against the canonical Pulumi-managed AWS test stack."""

from __future__ import annotations

import pytest
from click.testing import CliRunner

from prodbox.cli.main import cli
from prodbox.lib.aws_eks_test_stack import (
    AWS_EKS_TEST_STACK_NAME,
    AWS_EKS_TEST_STACK_SNAPSHOT_PATH,
    load_aws_eks_test_stack_snapshot,
    validate_aws_eks_test_stack_cluster,
)
from prodbox.lib.aws_test_stack import AWS_TEST_BACKEND_BUCKET

pytestmark = [pytest.mark.integration, pytest.mark.timeout(7200)]


@pytest.mark.integration
def test_aws_eks_stack_resources_validate_and_destroy_are_idempotent(
    cli_runner: CliRunner,
) -> None:
    """Pulumi EKS test-stack commands should provision, validate, inspect, and destroy cleanly."""
    initial_destroy = cli_runner.invoke(
        cli,
        ["pulumi", "eks-destroy", "--yes"],
        catch_exceptions=False,
    )
    assert initial_destroy.exit_code == 0

    try:
        resources = cli_runner.invoke(
            cli,
            ["pulumi", "eks-resources"],
            catch_exceptions=False,
        )
        assert resources.exit_code == 0
        assert f"STACK={AWS_EKS_TEST_STACK_NAME}" in resources.output
        assert f"BACKEND_BUCKET={AWS_TEST_BACKEND_BUCKET}" in resources.output
        assert "CLUSTER_NAME=" in resources.output
        assert "NODE_GROUP_NAME=" in resources.output

        snapshot = load_aws_eks_test_stack_snapshot()
        assert snapshot is not None
        assert snapshot.stack_name == AWS_EKS_TEST_STACK_NAME
        assert snapshot.backend_bucket == AWS_TEST_BACKEND_BUCKET
        assert len(snapshot.subnet_ids) == 2
        assert snapshot.cluster_name != ""
        assert snapshot.node_group_name != ""
        assert snapshot.cluster_role_name != ""
        assert snapshot.node_role_name != ""
        assert snapshot.cluster_security_group_id != ""
        assert AWS_EKS_TEST_STACK_SNAPSHOT_PATH.exists()

        result = validate_aws_eks_test_stack_cluster()
        assert result.cluster_name == snapshot.cluster_name
        assert result.node_group_name == snapshot.node_group_name
        assert len(result.node_names) >= 2
    finally:
        destroy = cli_runner.invoke(
            cli,
            ["pulumi", "eks-destroy", "--yes"],
            catch_exceptions=False,
        )
        assert destroy.exit_code == 0
        assert f"Destroyed stack {AWS_EKS_TEST_STACK_NAME}" in destroy.output
        assert load_aws_eks_test_stack_snapshot() is None
