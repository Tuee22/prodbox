"""Unit tests for the AWS integration harness helpers."""

from __future__ import annotations

from datetime import UTC, datetime
from subprocess import CompletedProcess
from unittest.mock import patch

from tests.integration.aws_helpers import (
    FIXTURE_SCOPE_ID_TAG,
    AwsFixtureScope,
    Ec2NetworkContext,
    EksClusterContext,
    _iam_role_exists,
    _is_expired_fixture_tag_map,
    _matches_fixture_selector,
    _normalize_name_fragment,
    _sweep_matching_eks_clusters,
    create_clean_fixture_scope,
    create_fixture_scope,
    fixture_scope_selector,
    has_required_fixture_tags,
    scope_tag_map,
)


def test_normalize_name_fragment_restricts_to_lowercase_ascii_and_hyphens() -> None:
    """Resource-name fragments should be lowercase, ASCII-safe, and collapsed."""
    assert _normalize_name_fragment("Project Alpha / DNS", max_length=32) == "project-alpha-dns"


def test_fixture_scope_selector_normalizes_project_and_scope_names() -> None:
    """Scope selectors should use the same normalization rules as real fixture scopes."""
    selector = fixture_scope_selector(project_slug="Project Alpha", test_scope="AWS Foundation")

    assert selector.project_slug == "project-alpha"
    assert selector.test_scope == "aws-foundation"


def test_matches_fixture_selector_requires_same_project_and_suite_scope() -> None:
    """Scope selection should ignore other projects and other suite names."""
    selector = fixture_scope_selector(project_slug="Project Alpha", test_scope="AWS Foundation")
    matching_tags = {
        "managed_by": "prodbox-integration",
        "prodbox_project": "project-alpha",
        "prodbox_test_scope": "aws-foundation",
    }
    wrong_project = dict(matching_tags)
    wrong_project["prodbox_project"] = "project-beta"
    wrong_scope = dict(matching_tags)
    wrong_scope["prodbox_test_scope"] = "dns-aws"

    assert _matches_fixture_selector(matching_tags, selector)
    assert not _matches_fixture_selector(wrong_project, selector)
    assert not _matches_fixture_selector(wrong_scope, selector)


def test_create_fixture_scope_derives_region_account_and_expiry_deterministically() -> None:
    """Fixture scope creation should use ambient account + region data and formatted expiry."""
    frozen_now = datetime(2026, 3, 26, 18, 0, 0, tzinfo=UTC)
    with (
        patch(
            "tests.integration.aws_helpers.require_aws_cli_identity", return_value="903936255925"
        ),
        patch("tests.integration.aws_helpers._configured_aws_region", return_value="us-west-2"),
        patch("tests.integration.aws_helpers.datetime") as mock_datetime,
    ):
        mock_datetime.now.return_value = frozen_now
        mock_datetime.strptime = datetime.strptime
        scope = create_fixture_scope(
            project_slug="Project Alpha",
            test_scope="AWS Foundation",
            ttl_hours=2,
        )

    assert scope.account_id == "903936255925"
    assert scope.region == "us-west-2"
    assert scope.project_slug == "project-alpha"
    assert scope.test_scope == "aws-foundation"
    assert scope.expires_at == "2026-03-26T20:00:00Z"


def test_create_clean_fixture_scope_runs_preflight_before_scope_creation() -> None:
    """Preflight cleanup should run before minting a fresh fixture scope."""
    expected_scope = AwsFixtureScope(
        project_slug="project-alpha",
        test_scope="aws-foundation",
        run_id="abc123def4",
        scope_id="project-alpha-aws-foundation-abc123def4",
        resource_prefix="project-alpha-aws-foundation-abc123def4",
        account_id="903936255925",
        region="us-west-2",
        expires_at="2026-03-26T20:00:00Z",
    )
    call_order: list[str] = []

    def fake_sweep(*, project_slug: str, test_scope: str) -> object:
        assert project_slug == "project-alpha"
        assert test_scope == "aws-foundation"
        call_order.append("sweep")
        return object()

    def fake_create(*, project_slug: str, test_scope: str, ttl_hours: int) -> AwsFixtureScope:
        assert project_slug == "project-alpha"
        assert test_scope == "aws-foundation"
        assert ttl_hours == 4
        call_order.append("create")
        return expected_scope

    with (
        patch(
            "tests.integration.aws_helpers.sweep_fixture_resources_for_scope",
            side_effect=fake_sweep,
        ),
        patch("tests.integration.aws_helpers.create_fixture_scope", side_effect=fake_create),
    ):
        scope = create_clean_fixture_scope(
            project_slug="project-alpha",
            test_scope="aws-foundation",
            ttl_hours=4,
        )

    assert call_order == ["sweep", "create"]
    assert scope == expected_scope


def test_scope_tag_map_contains_required_fixture_ownership_keys() -> None:
    """Canonical fixture tags should encode ownership, expiry, and safe-delete intent."""
    scope = AwsFixtureScope(
        project_slug="project-alpha",
        test_scope="aws-foundation",
        run_id="abc123def4",
        scope_id="project-alpha-aws-foundation-abc123def4",
        resource_prefix="project-alpha-aws-foundation-abc123def4",
        account_id="903936255925",
        region="us-west-2",
        expires_at="2026-03-26T20:00:00Z",
    )
    tag_map = scope_tag_map(scope, name="alpha-bucket")
    assert tag_map["Name"] == "alpha-bucket"
    assert tag_map["managed_by"] == "prodbox-integration"
    assert tag_map["environment"] == "aws-test"
    assert tag_map["prodbox_project"] == "project-alpha"
    assert tag_map["prodbox_test_scope"] == "aws-foundation"
    assert tag_map["prodbox_safe_to_delete"] == "true"
    assert tag_map["prodbox_expires_at"] == "2026-03-26T20:00:00Z"


def test_has_required_fixture_tags_rejects_wrong_scope_values() -> None:
    """Fixture tag validation should fail when one required ownership tag is wrong."""
    scope = AwsFixtureScope(
        project_slug="project-alpha",
        test_scope="aws-foundation",
        run_id="abc123def4",
        scope_id="project-alpha-aws-foundation-abc123def4",
        resource_prefix="project-alpha-aws-foundation-abc123def4",
        account_id="903936255925",
        region="us-west-2",
        expires_at="2026-03-26T20:00:00Z",
    )
    tag_map = scope_tag_map(scope, name="alpha-bucket")
    assert has_required_fixture_tags(scope, tag_map)
    wrong_tags = dict(tag_map)
    wrong_tags["prodbox_project"] = "project-beta"
    assert not has_required_fixture_tags(scope, wrong_tags)


def test_is_expired_fixture_tag_map_uses_expiry_timestamp_and_owner_tag() -> None:
    """Janitor expiry checks should require the harness owner tag and past expiry time."""
    current_time = datetime(2026, 3, 26, 18, 0, 0, tzinfo=UTC)
    expired_tags = {
        "managed_by": "prodbox-integration",
        "prodbox_expires_at": "2026-03-26T17:59:59Z",
    }
    future_tags = {
        "managed_by": "prodbox-integration",
        "prodbox_expires_at": "2026-03-26T18:00:01Z",
    }
    foreign_tags = {
        "managed_by": "someone-else",
        "prodbox_expires_at": "2026-03-26T17:59:59Z",
    }
    assert _is_expired_fixture_tag_map(expired_tags, current_time)
    assert not _is_expired_fixture_tag_map(future_tags, current_time)
    assert not _is_expired_fixture_tag_map(foreign_tags, current_time)


def test_sweep_matching_eks_clusters_captures_scope_id_before_delete() -> None:
    """EKS cleanup should record scope ids before delete removes cluster metadata."""
    context = EksClusterContext(
        scope=AwsFixtureScope(
            project_slug="janitor",
            test_scope="janitor",
            run_id="janitor",
            scope_id="janitor",
            resource_prefix="janitor",
            account_id="janitor",
            region="us-west-2",
            expires_at="1970-01-01T00:00:00Z",
        ),
        cluster_name="fixture-cluster",
        cluster_arn="arn:aws:eks:us-west-2:123456789012:cluster/fixture-cluster",
        role_name="fixture-role",
        role_arn="arn:aws:iam::123456789012:role/fixture-role",
        network=Ec2NetworkContext(
            scope=AwsFixtureScope(
                project_slug="janitor",
                test_scope="janitor",
                run_id="janitor",
                scope_id="janitor",
                resource_prefix="janitor",
                account_id="janitor",
                region="us-west-2",
                expires_at="1970-01-01T00:00:00Z",
            ),
            vpc_id="vpc-12345",
            subnet_ids=("subnet-a", "subnet-b"),
            security_group_id="sg-12345",
            network_interface_id=None,
        ),
    )
    call_order: list[str] = []

    def fake_tag_map(cluster_name: str) -> dict[str, str]:
        assert cluster_name == "fixture-cluster"
        call_order.append("tags")
        return {FIXTURE_SCOPE_ID_TAG: "scope-123"}

    def fake_delete(cluster_context: EksClusterContext) -> None:
        assert cluster_context == context
        call_order.append("delete")

    with (
        patch(
            "tests.integration.aws_helpers._list_matching_eks_clusters",
            return_value=(context,),
        ),
        patch("tests.integration.aws_helpers._eks_cluster_tag_map", side_effect=fake_tag_map),
        patch(
            "tests.integration.aws_helpers.delete_ephemeral_eks_cluster", side_effect=fake_delete
        ),
    ):
        deleted, scope_ids = _sweep_matching_eks_clusters(lambda _: True)

    assert deleted == 1
    assert scope_ids == ("scope-123",)
    assert call_order == ["tags", "delete"]


def test_iam_role_exists_falls_back_to_list_roles_when_get_role_is_denied() -> None:
    """IAM cleanup should tolerate missing iam:GetRole by falling back to list-roles."""
    with (
        patch(
            "tests.integration.aws_helpers._run_aws_cli_completed",
            return_value=CompletedProcess(
                args=("aws", "iam", "get-role"),
                returncode=254,
                stdout="",
                stderr=(
                    "An error occurred (AccessDenied) when calling the GetRole operation: "
                    "not authorized to perform: iam:GetRole"
                ),
            ),
        ),
        patch(
            "tests.integration.aws_helpers._run_aws_cli",
            return_value='{"Roles": [{"RoleName": "fixture-role"}]}',
        ),
    ):
        assert _iam_role_exists("fixture-role")


def test_iam_role_exists_returns_false_when_fallback_list_roles_omits_role() -> None:
    """IAM cleanup should treat a missing role as absent even when GetRole is denied."""
    with (
        patch(
            "tests.integration.aws_helpers._run_aws_cli_completed",
            return_value=CompletedProcess(
                args=("aws", "iam", "get-role"),
                returncode=254,
                stdout="",
                stderr=(
                    "An error occurred (AccessDenied) when calling the GetRole operation: "
                    "not authorized to perform: iam:GetRole"
                ),
            ),
        ),
        patch(
            "tests.integration.aws_helpers._run_aws_cli",
            return_value='{"Roles": [{"RoleName": "other-role"}]}',
        ),
    ):
        assert not _iam_role_exists("fixture-role")
