"""Real Pulumi integration tests for the canonical AWS test stack lifecycle."""

from __future__ import annotations

import pytest
from click.testing import CliRunner

from prodbox.cli.main import cli
from prodbox.lib.aws_test_stack import (
    AWS_TEST_BACKEND_BUCKET,
    AWS_TEST_STACK_NAME,
    load_aws_test_stack_snapshot,
)

pytestmark = [pytest.mark.integration, pytest.mark.timeout(5400)]


@pytest.mark.integration
def test_pulumi_test_stack_resources_and_destroy_are_idempotent(
    cli_runner: CliRunner,
) -> None:
    """Pulumi test-stack commands should provision, inspect, and destroy the canonical AWS stack."""
    initial_destroy = cli_runner.invoke(
        cli,
        ["pulumi", "test-destroy", "--yes"],
        catch_exceptions=False,
    )
    assert initial_destroy.exit_code == 0

    try:
        resources = cli_runner.invoke(
            cli,
            ["pulumi", "test-resources"],
            catch_exceptions=False,
        )
        assert resources.exit_code == 0
        assert f"STACK={AWS_TEST_STACK_NAME}" in resources.output
        assert f"BACKEND_BUCKET={AWS_TEST_BACKEND_BUCKET}" in resources.output
        assert "NODE_COUNT=3" in resources.output

        snapshot = load_aws_test_stack_snapshot()
        assert snapshot is not None
        assert snapshot.stack_name == AWS_TEST_STACK_NAME
        assert snapshot.backend_bucket == AWS_TEST_BACKEND_BUCKET
        assert len(snapshot.nodes) == 3
        assert len({node.availability_zone for node in snapshot.nodes}) == 3
        assert all(node.public_ip != "" for node in snapshot.nodes)
    finally:
        destroy = cli_runner.invoke(
            cli,
            ["pulumi", "test-destroy", "--yes"],
            catch_exceptions=False,
        )
        assert destroy.exit_code == 0
        assert f"Destroyed stack {AWS_TEST_STACK_NAME}" in destroy.output
        assert AWS_TEST_BACKEND_BUCKET in destroy.output
        assert load_aws_test_stack_snapshot() is None
