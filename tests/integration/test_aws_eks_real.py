"""Real EKS integration test using fixture-owned tagged AWS resources."""

from __future__ import annotations

from collections.abc import Iterator
from typing import Never

import pytest

from .aws_helpers import (
    EksClusterContext,
    create_ephemeral_eks_cluster,
    create_fixture_scope,
    delete_ephemeral_eks_cluster,
    ec2_network_tag_map,
    eks_cluster_exists,
    eks_cluster_status,
    eks_cluster_tag_map,
    has_required_fixture_tags,
    iam_role_tag_map,
)

pytestmark = [pytest.mark.integration, pytest.mark.timeout(3600)]


def _abort_session_on_teardown_failure(*, target: str, error: BaseException) -> Never:
    """Abort the pytest session immediately for teardown cleanup failure."""
    pytest.exit(
        f"teardown cleanup failed for {target}: {type(error).__name__}: {error}",
        returncode=1,
    )


@pytest.fixture
def ephemeral_eks_cluster() -> Iterator[EksClusterContext]:
    """Create and always clean up a tagged EKS control plane and its dependencies."""
    scope = create_fixture_scope(project_slug="prodbox", test_scope="aws-eks", ttl_hours=1)
    context = create_ephemeral_eks_cluster(scope)
    try:
        yield context
    finally:
        try:
            delete_ephemeral_eks_cluster(context)
        except Exception as error:
            _abort_session_on_teardown_failure(target=context.cluster_name, error=error)


def test_eks_control_plane_lifecycle_against_fixture_owned_resources(
    ephemeral_eks_cluster: EksClusterContext,
) -> None:
    """The EKS suite should create an active tagged cluster and tagged support resources."""
    assert eks_cluster_exists(ephemeral_eks_cluster.cluster_name)
    assert eks_cluster_status(ephemeral_eks_cluster) == "ACTIVE"
    assert has_required_fixture_tags(
        ephemeral_eks_cluster.scope,
        eks_cluster_tag_map(ephemeral_eks_cluster),
    )
    assert has_required_fixture_tags(
        ephemeral_eks_cluster.scope,
        iam_role_tag_map(ephemeral_eks_cluster.role_name),
    )

    network_tag_maps = ec2_network_tag_map(ephemeral_eks_cluster.network)
    assert has_required_fixture_tags(ephemeral_eks_cluster.scope, network_tag_maps["vpc"])
    assert has_required_fixture_tags(ephemeral_eks_cluster.scope, network_tag_maps["subnet"])
    assert has_required_fixture_tags(
        ephemeral_eks_cluster.scope,
        network_tag_maps["security_group"],
    )
    assert len(ephemeral_eks_cluster.network.subnet_ids) == 2
