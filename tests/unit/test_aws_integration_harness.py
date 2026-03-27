"""Unit tests for the AWS integration harness helpers."""

from __future__ import annotations

from datetime import UTC, datetime
from unittest.mock import patch

from tests.integration.aws_helpers import (
    AwsFixtureScope,
    _is_expired_fixture_tag_map,
    _normalize_name_fragment,
    create_fixture_scope,
    has_required_fixture_tags,
    scope_tag_map,
)


def test_normalize_name_fragment_restricts_to_lowercase_ascii_and_hyphens() -> None:
    """Resource-name fragments should be lowercase, ASCII-safe, and collapsed."""
    assert _normalize_name_fragment("Project Alpha / DNS", max_length=32) == "project-alpha-dns"


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
