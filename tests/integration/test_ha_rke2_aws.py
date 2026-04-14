"""Real HA RKE2 integration tests against the canonical Pulumi-managed AWS stack."""

from __future__ import annotations

import pytest

from prodbox.lib.aws_test_stack import AWS_TEST_STACK_NAME, load_aws_test_stack_snapshot
from prodbox.lib.ha_rke2_aws import bootstrap_and_validate_ha_rke2_cluster

pytestmark = [pytest.mark.integration, pytest.mark.timeout(7200)]


@pytest.mark.integration
def test_ha_rke2_bootstrap_succeeds_on_three_pulumi_managed_nodes() -> None:
    """The canonical AWS HA validation path should converge to three Ready RKE2 servers."""
    result = bootstrap_and_validate_ha_rke2_cluster()

    assert result.leader_name != ""
    assert result.leader_public_ip != ""
    assert len(result.node_names) == 3
    assert len(result.availability_zones) == 3
    assert len(set(result.node_names)) == 3
    assert len(set(result.availability_zones)) == 3

    snapshot = load_aws_test_stack_snapshot()
    assert snapshot is not None
    assert snapshot.stack_name == AWS_TEST_STACK_NAME
    assert tuple(node.name for node in snapshot.nodes) == result.node_names
