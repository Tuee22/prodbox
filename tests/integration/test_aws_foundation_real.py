"""Real AWS shared-account foundation tests for tagging, isolation, and janitor cleanup."""

from __future__ import annotations

from collections.abc import Iterator, Mapping
from typing import Never

import pytest

from . import aws_helpers as aws_helpers_module
from .aws_helpers import (
    FIXTURE_PROJECT_TAG,
    AwsFixtureScope,
    DelegatedRoute53ZoneContext,
    Ec2NetworkContext,
    EksClusterContext,
    Route53HostedZoneContext,
    S3BucketContext,
    bucket_tag_map,
    create_clean_fixture_scope,
    create_delegated_hosted_zone,
    create_ephemeral_ec2_network,
    create_ephemeral_s3_bucket,
    create_parent_hosted_zone,
    delete_fixture_resource,
    ec2_network_tag_map,
    ec2_vpc_exists,
    get_s3_text_object,
    has_required_fixture_tags,
    put_s3_text_object,
    query_route53_record_values,
    route53_hosted_zone_exists,
    route53_zone_tag_map,
    s3_bucket_exists,
    sweep_expired_fixture_resources,
)

pytestmark = [pytest.mark.integration, pytest.mark.timeout(900)]

AwsFixtureResource = (
    Route53HostedZoneContext
    | DelegatedRoute53ZoneContext
    | S3BucketContext
    | Ec2NetworkContext
    | EksClusterContext
)


def _abort_session_on_teardown_failure(*, target: str, error: BaseException) -> Never:
    """Abort the pytest session immediately for teardown cleanup failure."""
    pytest.exit(
        f"teardown cleanup failed for {target}: {type(error).__name__}: {error}",
        returncode=1,
    )


def _sorted(values: tuple[str, ...] | None) -> tuple[str, ...] | None:
    """Return a deterministically sorted tuple for Route 53 value assertions."""
    if values is None:
        return None
    return tuple(sorted(values))


def _assert_network_tags(scope: AwsFixtureScope, context: Ec2NetworkContext) -> None:
    """Require the full canonical tag set across the fixture-owned EC2 network."""
    network_tag_maps = ec2_network_tag_map(context)
    assert has_required_fixture_tags(scope, network_tag_maps["vpc"])
    assert has_required_fixture_tags(scope, network_tag_maps["subnet"])
    assert has_required_fixture_tags(scope, network_tag_maps["security_group"])
    if context.network_interface_id is not None:
        assert has_required_fixture_tags(scope, network_tag_maps["network_interface"])


@pytest.fixture
def aws_resource_stack() -> Iterator[list[AwsFixtureResource]]:
    """Track AWS fixture resources and always delete the ones still pending."""
    resources: list[AwsFixtureResource] = []
    try:
        yield resources
    finally:
        for resource in reversed(resources):
            try:
                delete_fixture_resource(resource)
            except Exception as error:
                resource_target = getattr(resource, "bucket_name", None)
                if resource_target is None:
                    resource_target = getattr(resource, "cluster_name", None)
                if resource_target is None:
                    resource_target = getattr(resource, "vpc_id", None)
                if resource_target is None:
                    resource_target = getattr(resource, "zone_name", None)
                if resource_target is None and isinstance(resource, DelegatedRoute53ZoneContext):
                    resource_target = resource.child_zone.zone_name
                _abort_session_on_teardown_failure(target=str(resource_target), error=error)


def test_shared_account_resources_are_tagged_isolated_and_janitor_cleanup_is_selective(
    aws_resource_stack: list[AwsFixtureResource],
) -> None:
    """Expired resources should be janitor-deleted without touching live project resources."""
    parent_scope = create_clean_fixture_scope(
        project_slug="shared-dns", test_scope="aws-foundation"
    )
    expired_scope = create_clean_fixture_scope(
        project_slug="project-alpha",
        test_scope="aws-foundation",
        ttl_hours=-1,
    )
    live_scope = create_clean_fixture_scope(
        project_slug="project-beta", test_scope="aws-foundation"
    )

    parent_zone = create_parent_hosted_zone(parent_scope, zone_label="shared-root")
    aws_resource_stack.append(parent_zone)

    expired_child = create_delegated_hosted_zone(parent_zone, expired_scope, child_label="alpha")
    aws_resource_stack.append(expired_child)

    live_child = create_delegated_hosted_zone(parent_zone, live_scope, child_label="beta")
    aws_resource_stack.append(live_child)

    expired_bucket = create_ephemeral_s3_bucket(expired_scope, bucket_label="alpha")
    aws_resource_stack.append(expired_bucket)
    put_s3_text_object(expired_bucket, key="expired.txt", body="expired-scope")
    assert get_s3_text_object(expired_bucket, key="expired.txt") == "expired-scope"

    live_bucket = create_ephemeral_s3_bucket(live_scope, bucket_label="beta")
    aws_resource_stack.append(live_bucket)
    put_s3_text_object(live_bucket, key="live.txt", body="live-scope")
    assert get_s3_text_object(live_bucket, key="live.txt") == "live-scope"

    expired_network = create_ephemeral_ec2_network(expired_scope)
    aws_resource_stack.append(expired_network)

    live_network = create_ephemeral_ec2_network(live_scope)
    aws_resource_stack.append(live_network)

    assert has_required_fixture_tags(parent_scope, route53_zone_tag_map(parent_zone))
    assert has_required_fixture_tags(expired_scope, route53_zone_tag_map(expired_child.child_zone))
    assert has_required_fixture_tags(live_scope, route53_zone_tag_map(live_child.child_zone))
    assert has_required_fixture_tags(expired_scope, bucket_tag_map(expired_bucket))
    assert has_required_fixture_tags(live_scope, bucket_tag_map(live_bucket))
    assert bucket_tag_map(live_bucket)[FIXTURE_PROJECT_TAG] == live_scope.project_slug
    _assert_network_tags(expired_scope, expired_network)
    _assert_network_tags(live_scope, live_network)

    assert _sorted(
        query_route53_record_values(
            parent_zone,
            record_name=expired_child.child_zone.zone_name,
            record_type="NS",
        )
    ) == _sorted(expired_child.name_servers)
    assert _sorted(
        query_route53_record_values(
            parent_zone,
            record_name=live_child.child_zone.zone_name,
            record_type="NS",
        )
    ) == _sorted(live_child.name_servers)
    assert route53_hosted_zone_exists(expired_child.child_zone.zone_resource_id)
    assert route53_hosted_zone_exists(live_child.child_zone.zone_resource_id)
    assert s3_bucket_exists(expired_bucket.bucket_name)
    assert s3_bucket_exists(live_bucket.bucket_name)
    assert ec2_vpc_exists(expired_network.vpc_id)
    assert ec2_vpc_exists(live_network.vpc_id)

    janitor_result = sweep_expired_fixture_resources()
    assert janitor_result.deleted_hosted_zones == 1
    assert janitor_result.deleted_buckets == 1
    assert janitor_result.deleted_vpcs == 1
    assert janitor_result.deleted_eks_clusters == 0

    aws_resource_stack.remove(expired_network)
    aws_resource_stack.remove(expired_bucket)
    aws_resource_stack.remove(expired_child)

    assert not route53_hosted_zone_exists(expired_child.child_zone.zone_resource_id)
    assert (
        query_route53_record_values(
            parent_zone,
            record_name=expired_child.child_zone.zone_name,
            record_type="NS",
        )
        is None
    )
    assert route53_hosted_zone_exists(live_child.child_zone.zone_resource_id)
    assert _sorted(
        query_route53_record_values(
            parent_zone,
            record_name=live_child.child_zone.zone_name,
            record_type="NS",
        )
    ) == _sorted(live_child.name_servers)
    assert not s3_bucket_exists(expired_bucket.bucket_name)
    assert s3_bucket_exists(live_bucket.bucket_name)
    assert get_s3_text_object(live_bucket, key="live.txt") == "live-scope"
    assert not ec2_vpc_exists(expired_network.vpc_id)
    assert ec2_vpc_exists(live_network.vpc_id)


def test_scope_preflight_cleanup_removes_only_matching_scope_resources(
    aws_resource_stack: list[AwsFixtureResource],
) -> None:
    """Scope preflight should delete only prior resources for the same project/suite selector."""
    stale_scope = create_clean_fixture_scope(
        project_slug="project-alpha", test_scope="aws-preflight"
    )
    live_scope = create_clean_fixture_scope(project_slug="project-beta", test_scope="aws-preflight")

    stale_zone = create_parent_hosted_zone(stale_scope, zone_label="stale")
    aws_resource_stack.append(stale_zone)
    live_zone = create_parent_hosted_zone(live_scope, zone_label="live")
    aws_resource_stack.append(live_zone)

    stale_bucket = create_ephemeral_s3_bucket(stale_scope, bucket_label="stale")
    aws_resource_stack.append(stale_bucket)
    live_bucket = create_ephemeral_s3_bucket(live_scope, bucket_label="live")
    aws_resource_stack.append(live_bucket)

    stale_network = create_ephemeral_ec2_network(stale_scope)
    aws_resource_stack.append(stale_network)
    live_network = create_ephemeral_ec2_network(live_scope)
    aws_resource_stack.append(live_network)

    replacement_scope = create_clean_fixture_scope(
        project_slug="project-alpha",
        test_scope="aws-preflight",
    )
    assert replacement_scope.project_slug == stale_scope.project_slug
    assert replacement_scope.test_scope == stale_scope.test_scope

    aws_resource_stack.remove(stale_network)
    aws_resource_stack.remove(stale_bucket)
    aws_resource_stack.remove(stale_zone)

    assert not route53_hosted_zone_exists(stale_zone.zone_resource_id)
    assert route53_hosted_zone_exists(live_zone.zone_resource_id)
    assert not s3_bucket_exists(stale_bucket.bucket_name)
    assert s3_bucket_exists(live_bucket.bucket_name)
    assert not ec2_vpc_exists(stale_network.vpc_id)
    assert ec2_vpc_exists(live_network.vpc_id)


def test_route53_setup_failure_rolls_back_partial_hosted_zone_creation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Route 53 setup failures should delete any hosted zone created before the error."""
    scope = create_clean_fixture_scope(project_slug="rollback-project", test_scope="aws-rollback")
    created_zone_ids: list[str] = []
    original_run_aws_cli = aws_helpers_module._run_aws_cli

    def failing_run_aws_cli(*args: str, env: Mapping[str, str] | None = None) -> str:
        if args[:2] == ("route53", "change-tags-for-resource"):
            raise AssertionError("synthetic Route 53 tag failure")
        result = original_run_aws_cli(*args, env=env)
        if args[:2] == ("route53", "create-hosted-zone"):
            created_zone_ids.append(result.removeprefix("/hostedzone/"))
        return result

    monkeypatch.setattr(aws_helpers_module, "_run_aws_cli", failing_run_aws_cli)

    with pytest.raises(AssertionError, match="synthetic Route 53 tag failure"):
        create_parent_hosted_zone(scope, zone_label="rollback")

    assert len(created_zone_ids) == 1
    assert not route53_hosted_zone_exists(created_zone_ids[0])
