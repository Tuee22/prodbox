"""AWS CLI helpers for real integration tests."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
import uuid
from collections.abc import Callable, Iterator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

from prodbox.settings import get_settings

FIXTURE_OWNER_TAG: str = "managed_by"
FIXTURE_OWNER_VALUE: str = "prodbox-integration"
FIXTURE_ENVIRONMENT_TAG: str = "environment"
FIXTURE_ENVIRONMENT_VALUE: str = "aws-test"
FIXTURE_EPHEMERAL_TAG: str = "prodbox_ephemeral"
FIXTURE_SAFE_TO_DELETE_TAG: str = "prodbox_safe_to_delete"
FIXTURE_TEST_ONLY_TAG: str = "prodbox_test_only"
FIXTURE_PROJECT_TAG: str = "prodbox_project"
FIXTURE_SCOPE_TAG: str = "prodbox_test_scope"
FIXTURE_RUN_ID_TAG: str = "prodbox_run_id"
FIXTURE_SCOPE_ID_TAG: str = "prodbox_scope_id"
FIXTURE_EXPIRES_AT_TAG: str = "prodbox_expires_at"
FIXTURE_PARENT_ZONE_ID_TAG: str = "prodbox_parent_zone_id"
DEFAULT_FIXTURE_TTL_HOURS: int = 6
DEFAULT_ROUTE53_RECORD_LABEL: str = "app"
ROUTE53_RECORD_TTL_SECONDS: int = 60
ROLE_POLICY_ARN_EKS_CLUSTER: str = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"


@dataclass(frozen=True)
class AwsTag:
    """One AWS tag key/value pair."""

    key: str
    value: str


@dataclass(frozen=True)
class AwsFixtureScope:
    """Resource-ownership scope for one fixture or janitor selection."""

    project_slug: str
    test_scope: str
    run_id: str
    scope_id: str
    resource_prefix: str
    account_id: str
    region: str
    expires_at: str


@dataclass(frozen=True)
class AwsFixtureScopeSelector:
    """Normalized project/test-scope selector for fixture preflight cleanup."""

    project_slug: str
    test_scope: str


@dataclass(frozen=True)
class Route53HostedZoneContext:
    """Ephemeral Route 53 hosted zone owned by one integration fixture."""

    scope: AwsFixtureScope
    zone_name: str
    zone_id: str
    zone_resource_id: str
    record_fqdn: str


@dataclass(frozen=True)
class DelegatedRoute53ZoneContext:
    """Fixture-owned delegated child hosted zone under a parent hosted zone."""

    parent_zone: Route53HostedZoneContext
    child_zone: Route53HostedZoneContext
    name_servers: tuple[str, ...]


@dataclass(frozen=True)
class S3BucketContext:
    """Ephemeral S3 bucket owned by one integration fixture."""

    scope: AwsFixtureScope
    bucket_name: str


@dataclass(frozen=True)
class Ec2NetworkContext:
    """Fixture-owned EC2/VPC network boundary."""

    scope: AwsFixtureScope
    vpc_id: str
    subnet_ids: tuple[str, ...]
    security_group_id: str
    network_interface_id: str | None


@dataclass(frozen=True)
class EksClusterContext:
    """Fixture-owned EKS control plane plus supporting IAM/network resources."""

    scope: AwsFixtureScope
    cluster_name: str
    cluster_arn: str
    role_name: str
    role_arn: str
    network: Ec2NetworkContext


@dataclass(frozen=True)
class JanitorSweepResult:
    """Counts of deleted resources from one janitor sweep."""

    deleted_hosted_zones: int
    deleted_buckets: int
    deleted_vpcs: int
    deleted_eks_clusters: int
    deleted_iam_roles: int


@dataclass(frozen=True)
class JanitorInventoryResult:
    """Counts of fixture-owned resources still visible after one janitor sweep."""

    remaining_hosted_zones: int
    remaining_buckets: int
    remaining_vpcs: int
    remaining_eks_clusters: int
    remaining_iam_roles: int


FixtureTagMatcher = Callable[[Mapping[str, str]], bool]


def _required_env_var(name: str) -> str:
    """Return one required environment variable or raise AssertionError."""
    value = os.environ.get(name)
    if value in (None, ""):
        raise AssertionError(f"missing required environment variable: {name}")
    return value


def _aws_env(extra_env: Mapping[str, str] | None = None) -> dict[str, str]:
    """Return AWS CLI environment with credentials from Settings."""
    settings = get_settings()
    env: dict[str, str] = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", ""),
    }
    env["AWS_ACCESS_KEY_ID"] = settings.aws_access_key_id
    env["AWS_SECRET_ACCESS_KEY"] = settings.aws_secret_access_key
    match settings.aws_session_token:
        case str() as token:
            env["AWS_SESSION_TOKEN"] = token
        case None:
            pass
    env["AWS_PAGER"] = ""
    region = settings.aws_region
    env["AWS_REGION"] = region
    env["AWS_DEFAULT_REGION"] = region
    match extra_env:
        case dict() as extras:
            env.update(dict(extras))
        case None:
            pass
    return env


def _run_aws_cli_completed(
    *args: str,
    env: Mapping[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run one AWS CLI command and return the completed process."""
    return subprocess.run(
        ["aws", *args],
        check=False,
        capture_output=True,
        text=True,
        env=_aws_env(env),
    )


def _run_aws_cli(*args: str, env: Mapping[str, str] | None = None) -> str:
    """Run one AWS CLI command and return stripped stdout."""
    completed = _run_aws_cli_completed(*args, env=env)
    if completed.returncode != 0:
        stderr_text = completed.stderr.strip() or completed.stdout.strip()
        raise AssertionError(f"aws {' '.join(args)} failed: {stderr_text}")
    return completed.stdout.strip()


def _configured_aws_region() -> str:
    """Return the effective AWS region from validated prodbox settings."""
    from prodbox.settings import get_settings

    return get_settings().aws_region


def require_aws_cli_identity() -> str:
    """Validate that the AWS CLI is installed and credentials are usable."""
    if shutil.which("aws") is None:
        raise AssertionError("aws CLI not installed")
    return _run_aws_cli("sts", "get-caller-identity", "--query", "Account", "--output", "text")


def _normalize_name_fragment(value: str, *, max_length: int) -> str:
    """Return a lowercase ASCII-safe resource-name fragment."""
    lowered = value.lower()
    allowed = [character if character.isalnum() else "-" for character in lowered]
    collapsed = "".join(allowed).strip("-")
    while "--" in collapsed:
        collapsed = collapsed.replace("--", "-")
    fallback = collapsed or "fixture"
    return fallback[:max_length].strip("-") or "fixture"


def create_fixture_scope(
    *,
    project_slug: str,
    test_scope: str,
    ttl_hours: int = DEFAULT_FIXTURE_TTL_HOURS,
) -> AwsFixtureScope:
    """Create one fixture ownership scope with deterministic tags."""
    selector = fixture_scope_selector(project_slug=project_slug, test_scope=test_scope)
    account_id = require_aws_cli_identity()
    run_id = uuid.uuid4().hex[:10]
    scope_id = f"{selector.project_slug}-{selector.test_scope}-{run_id}"
    resource_prefix = _normalize_name_fragment(scope_id, max_length=48)
    expires_at = datetime.now(UTC) + timedelta(hours=ttl_hours)
    return AwsFixtureScope(
        project_slug=selector.project_slug,
        test_scope=selector.test_scope,
        run_id=run_id,
        scope_id=scope_id,
        resource_prefix=resource_prefix,
        account_id=account_id,
        region=_configured_aws_region(),
        expires_at=expires_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
    )


def fixture_scope_selector(
    *,
    project_slug: str,
    test_scope: str,
) -> AwsFixtureScopeSelector:
    """Return the normalized selector used by preflight cleanup."""
    return AwsFixtureScopeSelector(
        project_slug=_normalize_name_fragment(project_slug, max_length=18),
        test_scope=_normalize_name_fragment(test_scope, max_length=18),
    )


def create_clean_fixture_scope(
    *,
    project_slug: str,
    test_scope: str,
    ttl_hours: int = DEFAULT_FIXTURE_TTL_HOURS,
) -> AwsFixtureScope:
    """Delete stale resources for one suite scope before minting a fresh fixture scope."""
    sweep_fixture_resources_for_scope(project_slug=project_slug, test_scope=test_scope)
    return create_fixture_scope(
        project_slug=project_slug,
        test_scope=test_scope,
        ttl_hours=ttl_hours,
    )


def _janitor_scope() -> AwsFixtureScope:
    """Return a placeholder scope used only for janitor-owned cleanup contexts."""
    return AwsFixtureScope(
        project_slug="janitor",
        test_scope="janitor",
        run_id="janitor",
        scope_id="janitor",
        resource_prefix="janitor",
        account_id="janitor",
        region=_configured_aws_region(),
        expires_at="1970-01-01T00:00:00Z",
    )


def _matches_fixture_selector(
    tag_map: Mapping[str, str],
    selector: AwsFixtureScopeSelector,
) -> bool:
    """Return True when a tagged resource belongs to one declared suite scope."""
    return (
        tag_map.get(FIXTURE_OWNER_TAG) == FIXTURE_OWNER_VALUE
        and tag_map.get(FIXTURE_PROJECT_TAG) == selector.project_slug
        and tag_map.get(FIXTURE_SCOPE_TAG) == selector.test_scope
    )


def _rollback_failed_create(
    *,
    operation: str,
    rollback_actions: tuple[Callable[[], None], ...],
    cause: BaseException,
) -> None:
    """Attempt all rollback actions and raise only if rollback itself fails."""
    rollback_failures: list[str] = []
    for rollback_action in reversed(rollback_actions):
        try:
            rollback_action()
        except Exception as error:
            rollback_failures.append(f"{type(error).__name__}: {error}")
    if rollback_failures:
        raise AssertionError(
            f"{operation} failed: {cause}; rollback also failed: {'; '.join(rollback_failures)}"
        ) from cause


def scope_tag_map(
    scope: AwsFixtureScope,
    *,
    name: str,
    extra_tags: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Return the canonical fixture tag map for one resource."""
    tags = {
        "Name": name,
        FIXTURE_OWNER_TAG: FIXTURE_OWNER_VALUE,
        FIXTURE_ENVIRONMENT_TAG: FIXTURE_ENVIRONMENT_VALUE,
        FIXTURE_EPHEMERAL_TAG: "true",
        FIXTURE_SAFE_TO_DELETE_TAG: "true",
        FIXTURE_TEST_ONLY_TAG: "true",
        FIXTURE_PROJECT_TAG: scope.project_slug,
        FIXTURE_SCOPE_TAG: scope.test_scope,
        FIXTURE_RUN_ID_TAG: scope.run_id,
        FIXTURE_SCOPE_ID_TAG: scope.scope_id,
        FIXTURE_EXPIRES_AT_TAG: scope.expires_at,
    }
    if extra_tags is not None:
        tags.update(dict(extra_tags))
    return tags


def scope_tags(
    scope: AwsFixtureScope,
    *,
    name: str,
    extra_tags: Mapping[str, str] | None = None,
) -> tuple[AwsTag, ...]:
    """Return the canonical fixture tags as dataclass entries."""
    return tuple(
        AwsTag(key=key, value=value)
        for key, value in scope_tag_map(scope, name=name, extra_tags=extra_tags).items()
    )


def has_required_fixture_tags(
    scope: AwsFixtureScope,
    tag_map: Mapping[str, str],
) -> bool:
    """Return True when a resource carries the full required fixture tag set."""
    expected = scope_tag_map(scope, name=tag_map.get("Name", "fixture"))
    for key, value in expected.items():
        if key == "Name":
            continue
        if tag_map.get(key) != value:
            return False
    return True


def _route53_cli_tag_args(tags: tuple[AwsTag, ...]) -> tuple[str, ...]:
    """Render AWS CLI Route 53 tag arguments."""
    return tuple(f"Key={tag.key},Value={tag.value}" for tag in tags)


def _ec2_cli_tag_args(tags: tuple[AwsTag, ...]) -> tuple[str, ...]:
    """Render EC2 create-tags arguments."""
    return tuple(f"Key={tag.key},Value={tag.value}" for tag in tags)


def _eks_cli_tag_map(tags: tuple[AwsTag, ...]) -> str:
    """Render EKS create-cluster/create-nodegroup style tag map."""
    return ",".join(f"{tag.key}={tag.value}" for tag in tags)


@contextmanager
def _temporary_json_file(prefix: str, payload: object) -> Iterator[Path]:
    """Write one JSON payload to a temp file and yield the file path."""
    with tempfile.TemporaryDirectory(prefix=prefix) as temp_dir:
        payload_path = Path(temp_dir) / "payload.json"
        payload_path.write_text(json.dumps(payload), encoding="utf-8")
        yield payload_path


def _route53_tag_map(zone_resource_id: str) -> dict[str, str]:
    """Return one hosted zone tag map."""
    payload = json.loads(
        _run_aws_cli(
            "route53",
            "list-tags-for-resource",
            "--resource-type",
            "hostedzone",
            "--resource-id",
            zone_resource_id,
            "--output",
            "json",
        )
    )
    tags: dict[str, str] = {}
    resource_tag_set = payload.get("ResourceTagSet", {})
    for tag in resource_tag_set.get("Tags", []):
        key = tag.get("Key")
        value = tag.get("Value")
        if key in (None, "") or value in (None, ""):
            continue
        tags[str(key)] = str(value)
    return tags


def route53_zone_tag_map(context: Route53HostedZoneContext) -> dict[str, str]:
    """Return the tag map for a fixture-owned hosted zone."""
    return _route53_tag_map(context.zone_resource_id)


def route53_hosted_zone_exists(zone_resource_id: str) -> bool:
    """Return True when the hosted zone still exists."""
    completed = _run_aws_cli_completed(
        "route53",
        "get-hosted-zone",
        "--id",
        zone_resource_id,
        "--output",
        "json",
    )
    if completed.returncode == 0:
        return True
    stderr_text = completed.stderr.strip() or completed.stdout.strip()
    if "NoSuchHostedZone" in stderr_text:
        return False
    raise AssertionError(f"aws route53 get-hosted-zone failed: {stderr_text}")


def _s3_bucket_tag_map(bucket_name: str) -> dict[str, str]:
    """Return one S3 bucket tag map, or an empty mapping when no tags exist."""
    completed = _run_aws_cli_completed(
        "s3api",
        "get-bucket-tagging",
        "--bucket",
        bucket_name,
        "--output",
        "json",
    )
    stderr_text = completed.stderr.strip() or completed.stdout.strip()
    if completed.returncode != 0 and "NoSuchTagSet" in stderr_text:
        return {}
    if completed.returncode != 0:
        raise AssertionError(f"aws s3api get-bucket-tagging failed: {stderr_text}")
    payload = json.loads(completed.stdout)
    tags: dict[str, str] = {}
    for tag in payload.get("TagSet", []):
        key = tag.get("Key")
        value = tag.get("Value")
        if key in (None, "") or value in (None, ""):
            continue
        tags[str(key)] = str(value)
    return tags


def _ec2_resource_tag_map(resource_type: str, resource_id: str) -> dict[str, str]:
    """Return the tag map for one EC2 resource."""
    query_by_type = {
        "vpc": ("ec2", "describe-vpcs", "--vpc-ids", resource_id, "--output", "json"),
        "subnet": (
            "ec2",
            "describe-subnets",
            "--subnet-ids",
            resource_id,
            "--output",
            "json",
        ),
        "security-group": (
            "ec2",
            "describe-security-groups",
            "--group-ids",
            resource_id,
            "--output",
            "json",
        ),
        "network-interface": (
            "ec2",
            "describe-network-interfaces",
            "--network-interface-ids",
            resource_id,
            "--output",
            "json",
        ),
    }
    if resource_type not in query_by_type:
        raise AssertionError(f"unsupported EC2 resource type for tags: {resource_type}")
    payload = json.loads(_run_aws_cli(*query_by_type[resource_type]))
    collection_by_type = {
        "vpc": payload.get("Vpcs", []),
        "subnet": payload.get("Subnets", []),
        "security-group": payload.get("SecurityGroups", []),
        "network-interface": payload.get("NetworkInterfaces", []),
    }
    tags: dict[str, str] = {}
    resources = collection_by_type[resource_type]
    if not resources:
        return tags
    tag_entries = resources[0].get("Tags", [])
    if not tag_entries:
        tag_entries = resources[0].get("TagSet", [])
    for tag in tag_entries:
        key = tag.get("Key")
        value = tag.get("Value")
        if key in (None, "") or value in (None, ""):
            continue
        tags[str(key)] = str(value)
    return tags


def ec2_network_tag_map(context: Ec2NetworkContext) -> dict[str, dict[str, str]]:
    """Return tag maps for the tagged EC2 resources in one network context."""
    return {
        "vpc": _ec2_resource_tag_map("vpc", context.vpc_id),
        "subnet": _ec2_resource_tag_map("subnet", context.subnet_ids[0]),
        "security_group": _ec2_resource_tag_map("security-group", context.security_group_id),
        "network_interface": (
            _ec2_resource_tag_map("network-interface", context.network_interface_id)
            if context.network_interface_id is not None
            else {}
        ),
    }


def ec2_subnet_tag_maps(context: Ec2NetworkContext) -> tuple[dict[str, str], ...]:
    """Return tag maps for every tagged subnet in one network context."""
    return tuple(_ec2_resource_tag_map("subnet", subnet_id) for subnet_id in context.subnet_ids)


def ec2_vpc_exists(vpc_id: str) -> bool:
    """Return True when the VPC still exists."""
    completed = _run_aws_cli_completed(
        "ec2",
        "describe-vpcs",
        "--vpc-ids",
        vpc_id,
        "--output",
        "json",
    )
    if completed.returncode == 0:
        return True
    stderr_text = completed.stderr.strip() or completed.stdout.strip()
    if "InvalidVpcID.NotFound" in stderr_text:
        return False
    raise AssertionError(f"aws ec2 describe-vpcs failed: {stderr_text}")


def _iam_role_tag_map(role_name: str) -> dict[str, str]:
    """Return one IAM role tag map."""
    payload = json.loads(
        _run_aws_cli(
            "iam",
            "list-role-tags",
            "--role-name",
            role_name,
            "--output",
            "json",
        )
    )
    tags: dict[str, str] = {}
    for tag in payload.get("Tags", []):
        key = tag.get("Key")
        value = tag.get("Value")
        if key in (None, "") or value in (None, ""):
            continue
        tags[str(key)] = str(value)
    return tags


def iam_role_tag_map(role_name: str) -> dict[str, str]:
    """Return the tag map for one fixture-owned IAM role."""
    return _iam_role_tag_map(role_name)


def _iam_role_names() -> tuple[str, ...]:
    """Return every IAM role name visible to the fixture credentials."""
    payload = json.loads(_run_aws_cli("iam", "list-roles", "--output", "json"))
    return tuple(
        str(role.get("RoleName"))
        for role in payload.get("Roles", [])
        if role.get("RoleName") not in (None, "")
    )


def _iam_role_exists(role_name: str) -> bool:
    """Return True when the IAM role still exists."""
    completed = _run_aws_cli_completed(
        "iam",
        "get-role",
        "--role-name",
        role_name,
        "--output",
        "json",
    )
    if completed.returncode == 0:
        return True
    stderr_text = completed.stderr.strip() or completed.stdout.strip()
    if "NoSuchEntity" in stderr_text:
        return False
    if "AccessDenied" in stderr_text or "not authorized to perform: iam:GetRole" in stderr_text:
        return role_name in _iam_role_names()
    raise AssertionError(f"aws iam get-role failed: {stderr_text}")


def _attached_role_policy_arns(role_name: str) -> tuple[str, ...]:
    """Return every policy ARN currently attached to the IAM role."""
    payload = json.loads(
        _run_aws_cli(
            "iam",
            "list-attached-role-policies",
            "--role-name",
            role_name,
            "--output",
            "json",
        )
    )
    return tuple(
        str(attached_policy.get("PolicyArn"))
        for attached_policy in payload.get("AttachedPolicies", [])
        if attached_policy.get("PolicyArn") not in (None, "")
    )


def _delete_iam_role_by_name(role_name: str, *, allow_missing: bool = False) -> None:
    """Delete one IAM role after detaching every attached policy."""
    if not _iam_role_exists(role_name):
        if allow_missing:
            return
        raise AssertionError(f"IAM role not found for cleanup: {role_name}")
    for policy_arn in _attached_role_policy_arns(role_name):
        _run_aws_cli(
            "iam",
            "detach-role-policy",
            "--role-name",
            role_name,
            "--policy-arn",
            policy_arn,
        )
    _run_aws_cli("iam", "delete-role", "--role-name", role_name)


def _eks_cluster_description(cluster_name: str) -> dict[str, object]:
    """Return one EKS cluster description payload."""
    payload = json.loads(
        _run_aws_cli(
            "eks",
            "describe-cluster",
            "--name",
            cluster_name,
            "--output",
            "json",
        )
    )
    cluster = payload.get("cluster")
    if not isinstance(cluster, dict):
        raise AssertionError(f"missing cluster description for {cluster_name}")
    return dict(cluster)


def _eks_cluster_tag_map(cluster_name: str) -> dict[str, str]:
    """Return one EKS cluster tag map."""
    cluster = _eks_cluster_description(cluster_name)
    tag_map = cluster.get("tags", {})
    if not isinstance(tag_map, dict):
        return {}
    return {
        str(key): str(value)
        for key, value in tag_map.items()
        if key not in (None, "") and value not in (None, "")
    }


def eks_cluster_tag_map(context: EksClusterContext) -> dict[str, str]:
    """Return the tag map for a fixture-owned EKS cluster."""
    return _eks_cluster_tag_map(context.cluster_name)


def eks_cluster_status(context: EksClusterContext) -> str:
    """Return the current EKS cluster status string."""
    cluster = _eks_cluster_description(context.cluster_name)
    status = cluster.get("status")
    if status in (None, ""):
        raise AssertionError(f"missing EKS cluster status for {context.cluster_name}")
    return str(status)


def eks_cluster_exists(cluster_name: str) -> bool:
    """Return True when the EKS cluster still exists."""
    completed = _run_aws_cli_completed(
        "eks",
        "describe-cluster",
        "--name",
        cluster_name,
        "--output",
        "json",
    )
    if completed.returncode == 0:
        return True
    stderr_text = completed.stderr.strip() or completed.stdout.strip()
    if "ResourceNotFoundException" in stderr_text:
        return False
    raise AssertionError(f"aws eks describe-cluster failed: {stderr_text}")


def _assert_scope_tags(scope: AwsFixtureScope, tag_map: Mapping[str, str]) -> None:
    """Require that the tag map carries the full fixture tag set."""
    if not has_required_fixture_tags(scope, tag_map):
        raise AssertionError(
            f"resource tags missing required fixture ownership tags: expected scope {scope.scope_id}"
        )


def _wait_for_ec2_scope_tags(
    scope: AwsFixtureScope,
    *,
    resource_type: str,
    resource_id: str,
    timeout_seconds: float = 30.0,
) -> None:
    """Poll until an EC2 resource exposes the expected fixture tags."""
    deadline = time.time() + timeout_seconds
    while True:
        tag_map = _ec2_resource_tag_map(resource_type, resource_id)
        if has_required_fixture_tags(scope, tag_map):
            return
        if time.time() >= deadline:
            _assert_scope_tags(scope, tag_map)
        time.sleep(1.0)


def _create_route53_hosted_zone(
    scope: AwsFixtureScope,
    *,
    zone_name: str,
    record_label: str,
    extra_tags: Mapping[str, str] | None = None,
) -> Route53HostedZoneContext:
    """Create and tag one Route 53 hosted zone."""
    zone_context: Route53HostedZoneContext | None = None
    try:
        zone_id = _run_aws_cli(
            "route53",
            "create-hosted-zone",
            "--name",
            zone_name,
            "--caller-reference",
            f"{scope.scope_id}-{uuid.uuid4().hex}",
            "--hosted-zone-config",
            "Comment=prodbox-ephemeral-integration-zone,PrivateZone=false",
            "--query",
            "HostedZone.Id",
            "--output",
            "text",
        )
        zone_resource_id = zone_id.removeprefix("/hostedzone/")
        zone_context = Route53HostedZoneContext(
            scope=scope,
            zone_name=zone_name,
            zone_id=zone_id,
            zone_resource_id=zone_resource_id,
            record_fqdn=f"{record_label}.{zone_name}",
        )
        tags = scope_tags(
            scope,
            name=zone_name,
            extra_tags=extra_tags,
        )
        _run_aws_cli(
            "route53",
            "change-tags-for-resource",
            "--resource-type",
            "hostedzone",
            "--resource-id",
            zone_resource_id,
            "--add-tags",
            *_route53_cli_tag_args(tags),
        )
        _assert_scope_tags(scope, _route53_tag_map(zone_resource_id))
        return zone_context
    except Exception as error:
        if zone_context is not None:
            _rollback_failed_create(
                operation=f"create Route 53 hosted zone {zone_name}",
                rollback_actions=(
                    lambda context=zone_context: delete_ephemeral_hosted_zone(context),
                ),
                cause=error,
            )
        raise


def create_ephemeral_hosted_zone(*, test_scope: str) -> Route53HostedZoneContext:
    """Create a brand-new ephemeral Route 53 hosted zone for one test."""
    scope = create_clean_fixture_scope(project_slug="prodbox", test_scope=test_scope)
    zone_name = f"{scope.resource_prefix}.dev"
    return _create_route53_hosted_zone(
        scope,
        zone_name=zone_name,
        record_label=DEFAULT_ROUTE53_RECORD_LABEL,
    )


def create_parent_hosted_zone(
    scope: AwsFixtureScope,
    *,
    zone_label: str,
) -> Route53HostedZoneContext:
    """Create a parent hosted zone used for delegated child-zone tests."""
    normalized_label = _normalize_name_fragment(zone_label, max_length=20)
    zone_name = f"{normalized_label}-{scope.resource_prefix}.dev"
    return _create_route53_hosted_zone(
        scope,
        zone_name=zone_name,
        record_label=DEFAULT_ROUTE53_RECORD_LABEL,
        extra_tags={"prodbox_zone_role": "parent"},
    )


def create_delegated_hosted_zone(
    parent_zone: Route53HostedZoneContext,
    scope: AwsFixtureScope,
    *,
    child_label: str,
) -> DelegatedRoute53ZoneContext:
    """Create and delegate one child hosted zone under a parent hosted zone."""
    normalized_label = _normalize_name_fragment(child_label, max_length=20)
    child_zone_name = f"{normalized_label}.{parent_zone.zone_name}"
    child_zone = _create_route53_hosted_zone(
        scope,
        zone_name=child_zone_name,
        record_label=DEFAULT_ROUTE53_RECORD_LABEL,
        extra_tags={
            "prodbox_zone_role": "child",
            FIXTURE_PARENT_ZONE_ID_TAG: parent_zone.zone_resource_id,
        },
    )
    delegation_payload = json.loads(
        _run_aws_cli(
            "route53",
            "get-hosted-zone",
            "--id",
            child_zone.zone_resource_id,
            "--output",
            "json",
        )
    )
    delegation_set = delegation_payload.get("DelegationSet", {})
    name_servers = tuple(
        str(server) for server in delegation_set.get("NameServers", []) if server not in (None, "")
    )
    if not name_servers:
        raise AssertionError(f"delegated hosted zone {child_zone.zone_name} has no name servers")
    change_batch = {
        "Changes": [
            {
                "Action": "UPSERT",
                "ResourceRecordSet": {
                    "Name": child_zone.zone_name,
                    "Type": "NS",
                    "TTL": ROUTE53_RECORD_TTL_SECONDS,
                    "ResourceRecords": [{"Value": name_server} for name_server in name_servers],
                },
            }
        ]
    }
    with _temporary_json_file("prodbox-route53-parent-ns-", change_batch) as batch_path:
        _run_aws_cli(
            "route53",
            "change-resource-record-sets",
            "--hosted-zone-id",
            parent_zone.zone_resource_id,
            "--change-batch",
            f"file://{batch_path}",
        )
    wait_for_route53_record_values(
        parent_zone,
        record_name=child_zone.zone_name,
        record_type="NS",
        expected_values=name_servers,
    )
    return DelegatedRoute53ZoneContext(
        parent_zone=parent_zone,
        child_zone=child_zone,
        name_servers=name_servers,
    )


def query_route53_record_values(
    context: Route53HostedZoneContext,
    *,
    record_name: str,
    record_type: str,
) -> tuple[str, ...] | None:
    """Return one record-set value tuple or None when no matching record exists."""
    payload = json.loads(
        _run_aws_cli(
            "route53",
            "list-resource-record-sets",
            "--hosted-zone-id",
            context.zone_resource_id,
            "--output",
            "json",
        )
    )
    normalized_name = f"{record_name}."
    for record_set in payload.get("ResourceRecordSets", []):
        if record_set.get("Name") != normalized_name:
            continue
        if record_set.get("Type") != record_type:
            continue
        resource_records = record_set.get("ResourceRecords", [])
        values = tuple(
            str(record.get("Value"))
            for record in resource_records
            if record.get("Value") not in (None, "")
        )
        return values or None
    return None


def query_route53_a_record(context: Route53HostedZoneContext) -> str | None:
    """Return the current A record value for the fixture-owned FQDN, if any."""
    values = query_route53_record_values(
        context,
        record_name=context.record_fqdn,
        record_type="A",
    )
    if values is None:
        return None
    return values[0]


def wait_for_route53_record_values(
    context: Route53HostedZoneContext,
    *,
    record_name: str,
    record_type: str,
    expected_values: tuple[str, ...] | None,
    timeout_seconds: float = 30.0,
) -> None:
    """Poll Route 53 until one record set matches the expected values."""
    deadline = time.time() + timeout_seconds
    normalized_expected = tuple(sorted(expected_values)) if expected_values is not None else None
    while True:
        current_values = query_route53_record_values(
            context,
            record_name=record_name,
            record_type=record_type,
        )
        normalized_current = tuple(sorted(current_values)) if current_values is not None else None
        if normalized_current == normalized_expected:
            return
        if time.time() >= deadline:
            raise AssertionError(
                "timed out waiting for Route 53 record "
                f"{record_name} {record_type} to become {normalized_expected!r}; "
                f"current={normalized_current!r}"
            )
        time.sleep(1.0)


def wait_for_route53_a_record(
    context: Route53HostedZoneContext,
    *,
    expected_value: str | None,
    timeout_seconds: float = 30.0,
) -> None:
    """Poll Route 53 until the fixture-owned A record matches the expected value."""
    expected_values = (expected_value,) if expected_value is not None else None
    wait_for_route53_record_values(
        context,
        record_name=context.record_fqdn,
        record_type="A",
        expected_values=expected_values,
        timeout_seconds=timeout_seconds,
    )


def build_dns_suite_env(context: Route53HostedZoneContext) -> dict[str, str]:
    """Return environment overrides for real DNS integration tests."""
    from prodbox.settings import get_settings

    settings = get_settings()
    return {
        "AWS_REGION": settings.aws_region,
        "ROUTE53_ZONE_ID": context.zone_resource_id,
        "DEMO_FQDN": context.record_fqdn,
        "DEMO_TTL": str(ROUTE53_RECORD_TTL_SECONDS),
        "ACME_EMAIL": settings.acme_email,
    }


@contextmanager
def override_config_json(overrides: dict[str, object]) -> Iterator[Path]:
    """Write a temporary ``prodbox-config.json`` with field overrides.

    Patches ``REPOSITORY_ROOT`` and clears the settings cache so
    ``get_settings()`` / ``Settings.from_config_json()`` read the
    temporary file.  Restores the original root on exit.
    """
    import prodbox.settings as settings_module
    from prodbox.settings import REPOSITORY_ROOT, clear_settings_cache, load_config_json

    original_root = REPOSITORY_ROOT
    config_path = original_root / "prodbox-config.json"
    base_config = load_config_json(config_path)

    def _deep_merge(base: dict[str, object], patch: dict[str, object]) -> dict[str, object]:
        merged = dict(base)
        for key, value in patch.items():
            existing = merged.get(key)
            match (existing, value):
                case (dict() as edict, dict() as vdict):
                    merged[key] = _deep_merge(
                        {str(k): v for k, v in edict.items()},
                        {str(k): v for k, v in vdict.items()},
                    )
                case _:
                    merged[key] = value
        return merged

    merged = _deep_merge(base_config, overrides)
    tmp_dir = Path(tempfile.mkdtemp(prefix="prodbox-config-"))
    tmp_config = tmp_dir / "prodbox-config.json"
    tmp_config.write_text(json.dumps(merged, indent=2), encoding="utf-8")

    settings_module.REPOSITORY_ROOT = tmp_dir
    clear_settings_cache()
    try:
        yield tmp_dir
    finally:
        settings_module.REPOSITORY_ROOT = original_root
        clear_settings_cache()
        shutil.rmtree(tmp_dir, ignore_errors=True)


def _route53_mutable_record_sets(context: Route53HostedZoneContext) -> list[dict[str, object]]:
    """Return all non-default record sets in one hosted zone."""
    payload = json.loads(
        _run_aws_cli(
            "route53",
            "list-resource-record-sets",
            "--hosted-zone-id",
            context.zone_resource_id,
            "--output",
            "json",
        )
    )
    mutable_record_sets: list[dict[str, object]] = []
    for record_set in payload.get("ResourceRecordSets", []):
        name = str(record_set.get("Name", ""))
        record_type = str(record_set.get("Type", ""))
        is_default_apex_record = name == f"{context.zone_name}." and record_type in {"NS", "SOA"}
        if is_default_apex_record:
            continue
        mutable_record_sets.append(dict(record_set))
    return mutable_record_sets


def delete_ephemeral_hosted_zone(context: Route53HostedZoneContext) -> None:
    """Delete all mutable records then delete the hosted zone."""
    mutable_record_sets = _route53_mutable_record_sets(context)
    if mutable_record_sets:
        change_batch = {
            "Changes": [
                {
                    "Action": "DELETE",
                    "ResourceRecordSet": record_set,
                }
                for record_set in mutable_record_sets
            ]
        }
        with _temporary_json_file("prodbox-route53-zone-cleanup-", change_batch) as batch_path:
            _run_aws_cli(
                "route53",
                "change-resource-record-sets",
                "--hosted-zone-id",
                context.zone_resource_id,
                "--change-batch",
                f"file://{batch_path}",
            )
        _wait_for_route53_mutable_records_absent(context)
    _run_aws_cli(
        "route53",
        "delete-hosted-zone",
        "--id",
        context.zone_resource_id,
    )


def delete_delegated_hosted_zone(context: DelegatedRoute53ZoneContext) -> None:
    """Delete the parent NS delegation record and the child hosted zone."""
    change_batch = {
        "Changes": [
            {
                "Action": "DELETE",
                "ResourceRecordSet": {
                    "Name": context.child_zone.zone_name,
                    "Type": "NS",
                    "TTL": ROUTE53_RECORD_TTL_SECONDS,
                    "ResourceRecords": [
                        {"Value": name_server} for name_server in context.name_servers
                    ],
                },
            }
        ]
    }
    with _temporary_json_file("prodbox-route53-child-cleanup-", change_batch) as batch_path:
        _run_aws_cli(
            "route53",
            "change-resource-record-sets",
            "--hosted-zone-id",
            context.parent_zone.zone_resource_id,
            "--change-batch",
            f"file://{batch_path}",
        )
    wait_for_route53_record_values(
        context.parent_zone,
        record_name=context.child_zone.zone_name,
        record_type="NS",
        expected_values=None,
    )
    delete_ephemeral_hosted_zone(context.child_zone)


def _wait_for_route53_mutable_records_absent(
    context: Route53HostedZoneContext,
    *,
    timeout_seconds: float = 30.0,
) -> None:
    """Wait until a hosted zone contains only the default apex NS/SOA records."""
    deadline = time.time() + timeout_seconds
    while True:
        if not _route53_mutable_record_sets(context):
            return
        if time.time() >= deadline:
            raise AssertionError(
                f"timed out waiting for Route 53 hosted zone cleanup: {context.zone_name}"
            )
        time.sleep(1.0)


def _s3_bucket_name(scope: AwsFixtureScope, bucket_label: str) -> str:
    """Return one globally unique S3 bucket name."""
    normalized_label = _normalize_name_fragment(bucket_label, max_length=12)
    return f"{normalized_label}-{scope.resource_prefix}-{scope.account_id[-6:]}"


def create_ephemeral_s3_bucket(
    scope: AwsFixtureScope,
    *,
    bucket_label: str,
) -> S3BucketContext:
    """Create and tag one ephemeral S3 bucket."""
    bucket_name = _s3_bucket_name(scope, bucket_label)
    context = S3BucketContext(scope=scope, bucket_name=bucket_name)
    create_args = [
        "s3api",
        "create-bucket",
        "--bucket",
        bucket_name,
    ]
    if scope.region != "us-east-1":
        create_args.extend(
            [
                "--create-bucket-configuration",
                f"LocationConstraint={scope.region}",
            ]
        )
    try:
        _run_aws_cli(*create_args)
        tagging_payload = {
            "TagSet": [
                {"Key": tag.key, "Value": tag.value} for tag in scope_tags(scope, name=bucket_name)
            ]
        }
        with _temporary_json_file("prodbox-s3-tags-", tagging_payload) as tag_path:
            _run_aws_cli(
                "s3api",
                "put-bucket-tagging",
                "--bucket",
                bucket_name,
                "--tagging",
                f"file://{tag_path}",
            )
        _assert_scope_tags(scope, _s3_bucket_tag_map(bucket_name))
        return context
    except Exception as error:
        _rollback_failed_create(
            operation=f"create S3 bucket {bucket_name}",
            rollback_actions=(
                lambda bucket_context=context: delete_ephemeral_s3_bucket(bucket_context),
            ),
            cause=error,
        )
        raise


def put_s3_text_object(context: S3BucketContext, *, key: str, body: str) -> None:
    """Write one text object into the fixture-owned bucket."""
    with tempfile.TemporaryDirectory(prefix="prodbox-s3-object-") as temp_dir:
        payload_path = Path(temp_dir) / "payload.txt"
        payload_path.write_text(body, encoding="utf-8")
        _run_aws_cli(
            "s3api",
            "put-object",
            "--bucket",
            context.bucket_name,
            "--key",
            key,
            "--body",
            str(payload_path),
        )


def get_s3_text_object(context: S3BucketContext, *, key: str) -> str:
    """Fetch one text object from the fixture-owned bucket."""
    with tempfile.TemporaryDirectory(prefix="prodbox-s3-download-") as temp_dir:
        target_path = Path(temp_dir) / "object.txt"
        _run_aws_cli(
            "s3api",
            "get-object",
            "--bucket",
            context.bucket_name,
            "--key",
            key,
            str(target_path),
        )
        return target_path.read_text(encoding="utf-8")


def bucket_tag_map(context: S3BucketContext) -> dict[str, str]:
    """Return the tag map for a fixture-owned bucket."""
    return _s3_bucket_tag_map(context.bucket_name)


def s3_bucket_exists(bucket_name: str) -> bool:
    """Return True when the S3 bucket still exists."""
    completed = _run_aws_cli_completed(
        "s3api",
        "head-bucket",
        "--bucket",
        bucket_name,
    )
    if completed.returncode == 0:
        return True
    stderr_text = completed.stderr.strip() or completed.stdout.strip()
    if "Not Found" in stderr_text or "404" in stderr_text:
        return False
    raise AssertionError(f"aws s3api head-bucket failed: {stderr_text}")


def delete_ephemeral_s3_bucket(context: S3BucketContext) -> None:
    """Delete all objects from one bucket, then delete the bucket."""
    payload = json.loads(
        _run_aws_cli(
            "s3api",
            "list-objects-v2",
            "--bucket",
            context.bucket_name,
            "--output",
            "json",
        )
    )
    for item in payload.get("Contents", []):
        key = item.get("Key")
        if key in (None, ""):
            continue
        _run_aws_cli(
            "s3api",
            "delete-object",
            "--bucket",
            context.bucket_name,
            "--key",
            str(key),
        )
    _run_aws_cli("s3api", "delete-bucket", "--bucket", context.bucket_name)


def _available_availability_zones() -> tuple[str, ...]:
    """Return the available availability zones in the active region."""
    output = _run_aws_cli(
        "ec2",
        "describe-availability-zones",
        "--query",
        "AvailabilityZones[?State==`available`].ZoneName",
        "--output",
        "text",
    )
    zones = tuple(zone for zone in output.split() if zone)
    if not zones:
        raise AssertionError("no availability zones available in AWS account region")
    return zones


def _create_ec2_tags(*resource_ids: str, tags: tuple[AwsTag, ...]) -> None:
    """Apply EC2 tags to one or more resources."""
    _run_aws_cli(
        "ec2",
        "create-tags",
        "--resources",
        *resource_ids,
        "--tags",
        *_ec2_cli_tag_args(tags),
    )


def create_ephemeral_ec2_network(
    scope: AwsFixtureScope,
    *,
    subnet_count: int = 1,
    create_network_interface: bool = True,
) -> Ec2NetworkContext:
    """Create a tagged VPC, subnets, security group, and optional ENI."""
    if subnet_count < 1:
        raise AssertionError("subnet_count must be at least 1")
    availability_zones = _available_availability_zones()
    if len(availability_zones) < subnet_count:
        raise AssertionError(
            f"need {subnet_count} availability zones, found {len(availability_zones)}"
        )
    cidr_octet = 10 + int(scope.run_id[:2], 16) % 200
    vpc_id = _run_aws_cli(
        "ec2",
        "create-vpc",
        "--cidr-block",
        f"10.{cidr_octet}.0.0/16",
        "--query",
        "Vpc.VpcId",
        "--output",
        "text",
    )
    subnet_ids: list[str] = []
    security_group_id: str | None = None
    network_interface_id: str | None = None

    def _rollback_network() -> None:
        _delete_partial_ec2_network(
            vpc_id=vpc_id,
            subnet_ids=tuple(subnet_ids),
            security_group_id=security_group_id,
            network_interface_id=network_interface_id,
        )

    try:
        _create_ec2_tags(vpc_id, tags=scope_tags(scope, name=f"{scope.resource_prefix}-vpc"))
        _run_aws_cli(
            "ec2",
            "modify-vpc-attribute",
            "--vpc-id",
            vpc_id,
            "--enable-dns-support",
            '{"Value":true}',
        )
        _run_aws_cli(
            "ec2",
            "modify-vpc-attribute",
            "--vpc-id",
            vpc_id,
            "--enable-dns-hostnames",
            '{"Value":true}',
        )
        for subnet_index, availability_zone in enumerate(availability_zones[:subnet_count]):
            subnet_id = _run_aws_cli(
                "ec2",
                "create-subnet",
                "--vpc-id",
                vpc_id,
                "--cidr-block",
                f"10.{cidr_octet}.{subnet_index}.0/24",
                "--availability-zone",
                availability_zone,
                "--query",
                "Subnet.SubnetId",
                "--output",
                "text",
            )
            _create_ec2_tags(
                subnet_id,
                tags=scope_tags(scope, name=f"{scope.resource_prefix}-subnet-{subnet_index}"),
            )
            subnet_ids.append(subnet_id)
        security_group_id = _run_aws_cli(
            "ec2",
            "create-security-group",
            "--group-name",
            _normalize_name_fragment(f"{scope.resource_prefix}-sg", max_length=255),
            "--description",
            f"Fixture-owned security group for {scope.scope_id}",
            "--vpc-id",
            vpc_id,
            "--query",
            "GroupId",
            "--output",
            "text",
        )
        _create_ec2_tags(
            security_group_id,
            tags=scope_tags(scope, name=f"{scope.resource_prefix}-sg"),
        )
        if create_network_interface:
            network_interface_id = _run_aws_cli(
                "ec2",
                "create-network-interface",
                "--subnet-id",
                subnet_ids[0],
                "--groups",
                security_group_id,
                "--query",
                "NetworkInterface.NetworkInterfaceId",
                "--output",
                "text",
            )
            _create_ec2_tags(
                network_interface_id,
                tags=scope_tags(scope, name=f"{scope.resource_prefix}-eni"),
            )
        _wait_for_ec2_scope_tags(scope, resource_type="vpc", resource_id=vpc_id)
        for subnet_id in subnet_ids:
            _wait_for_ec2_scope_tags(scope, resource_type="subnet", resource_id=subnet_id)
        if security_group_id is None:
            raise AssertionError(f"missing security group id for scope {scope.scope_id}")
        _wait_for_ec2_scope_tags(
            scope,
            resource_type="security-group",
            resource_id=security_group_id,
        )
        if network_interface_id is not None:
            _wait_for_ec2_scope_tags(
                scope,
                resource_type="network-interface",
                resource_id=network_interface_id,
            )
        return Ec2NetworkContext(
            scope=scope,
            vpc_id=vpc_id,
            subnet_ids=tuple(subnet_ids),
            security_group_id=security_group_id,
            network_interface_id=network_interface_id,
        )
    except Exception as error:
        _rollback_failed_create(
            operation=f"create EC2 fixture network for {scope.scope_id}",
            rollback_actions=(_rollback_network,),
            cause=error,
        )
        raise


def delete_ephemeral_ec2_network(context: Ec2NetworkContext) -> None:
    """Delete ENI, security group, subnets, then VPC."""
    if context.network_interface_id is not None:
        _delete_ec2_with_retry(
            (
                "ec2",
                "delete-network-interface",
                "--network-interface-id",
                context.network_interface_id,
            ),
            "network interface",
            context.network_interface_id,
        )
    _delete_ec2_with_retry(
        ("ec2", "delete-security-group", "--group-id", context.security_group_id),
        "security group",
        context.security_group_id,
    )
    for subnet_id in context.subnet_ids:
        _delete_ec2_with_retry(
            ("ec2", "delete-subnet", "--subnet-id", subnet_id),
            "subnet",
            subnet_id,
        )
    _delete_ec2_with_retry(
        ("ec2", "delete-vpc", "--vpc-id", context.vpc_id),
        "vpc",
        context.vpc_id,
    )


def _ec2_delete_not_found(stderr_text: str) -> bool:
    """Return True when one EC2 delete failure only reports a missing resource."""
    return any(
        marker in stderr_text
        for marker in (
            "InvalidNetworkInterfaceID.NotFound",
            "InvalidGroup.NotFound",
            "InvalidSubnetID.NotFound",
            "InvalidVpcID.NotFound",
        )
    )


def _delete_partial_ec2_network(
    *,
    vpc_id: str,
    subnet_ids: tuple[str, ...],
    security_group_id: str | None,
    network_interface_id: str | None,
) -> None:
    """Delete the EC2 resources created so far during a failed network setup."""
    if network_interface_id is not None:
        _delete_ec2_with_retry(
            (
                "ec2",
                "delete-network-interface",
                "--network-interface-id",
                network_interface_id,
            ),
            "network interface",
            network_interface_id,
            allow_missing=True,
        )
    if security_group_id is not None:
        _delete_ec2_with_retry(
            ("ec2", "delete-security-group", "--group-id", security_group_id),
            "security group",
            security_group_id,
            allow_missing=True,
        )
    for subnet_id in subnet_ids:
        _delete_ec2_with_retry(
            ("ec2", "delete-subnet", "--subnet-id", subnet_id),
            "subnet",
            subnet_id,
            allow_missing=True,
        )
    _delete_ec2_with_retry(
        ("ec2", "delete-vpc", "--vpc-id", vpc_id),
        "vpc",
        vpc_id,
        allow_missing=True,
    )


def _delete_ec2_with_retry(
    command: tuple[str, ...],
    resource_kind: str,
    resource_id: str,
    *,
    timeout_seconds: float = 120.0,
    allow_missing: bool = False,
) -> None:
    """Delete one EC2 resource with dependency-violation retries."""
    deadline = time.time() + timeout_seconds
    while True:
        completed = _run_aws_cli_completed(*command)
        if completed.returncode == 0:
            return
        stderr_text = completed.stderr.strip() or completed.stdout.strip()
        if allow_missing and _ec2_delete_not_found(stderr_text):
            return
        if time.time() >= deadline:
            raise AssertionError(
                f"failed to delete EC2 {resource_kind} {resource_id}: {stderr_text}"
            )
        time.sleep(2.0)


def create_ephemeral_eks_cluster(scope: AwsFixtureScope) -> EksClusterContext:
    """Create a tagged EKS control plane plus tagged IAM and VPC dependencies."""
    network = create_ephemeral_ec2_network(
        scope,
        subnet_count=2,
        create_network_interface=False,
    )
    role_name = _normalize_name_fragment(f"{scope.resource_prefix}-eks-role", max_length=64)
    cluster_name = _normalize_name_fragment(f"{scope.resource_prefix}-eks", max_length=100)
    rollback_actions: list[Callable[[], None]] = [
        lambda network_context=network: delete_ephemeral_ec2_network(network_context),
    ]
    trust_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {"Service": "eks.amazonaws.com"},
                "Action": "sts:AssumeRole",
            }
        ],
    }
    try:
        with _temporary_json_file("prodbox-iam-role-", trust_policy) as trust_policy_path:
            role_arn = _run_aws_cli(
                "iam",
                "create-role",
                "--role-name",
                role_name,
                "--assume-role-policy-document",
                f"file://{trust_policy_path}",
                "--tags",
                *_route53_cli_tag_args(scope_tags(scope, name=role_name)),
                "--query",
                "Role.Arn",
                "--output",
                "text",
            )
        rollback_actions.append(
            lambda role_name_text=role_name: _delete_iam_role_by_name(
                role_name_text,
                allow_missing=True,
            )
        )
        _run_aws_cli(
            "iam",
            "attach-role-policy",
            "--role-name",
            role_name,
            "--policy-arn",
            ROLE_POLICY_ARN_EKS_CLUSTER,
        )
        _assert_scope_tags(scope, _iam_role_tag_map(role_name))
        create_output = _create_eks_cluster_with_retry(
            cluster_name=cluster_name,
            role_arn=role_arn,
            network=network,
            tags=scope_tags(scope, name=cluster_name),
        )
        rollback_actions.append(
            lambda cluster_name_text=cluster_name: _delete_eks_cluster_by_name(
                cluster_name_text,
                allow_missing=True,
            )
        )
        cluster = create_output.get("cluster", {})
        cluster_arn = str(cluster.get("arn", ""))
        if not cluster_arn:
            raise AssertionError(f"missing EKS cluster ARN for {cluster_name}")
        _run_aws_cli("eks", "wait", "cluster-active", "--name", cluster_name)
        _assert_scope_tags(scope, _eks_cluster_tag_map(cluster_name))
        return EksClusterContext(
            scope=scope,
            cluster_name=cluster_name,
            cluster_arn=cluster_arn,
            role_name=role_name,
            role_arn=role_arn,
            network=network,
        )
    except Exception as error:
        _rollback_failed_create(
            operation=f"create EKS fixture cluster {cluster_name}",
            rollback_actions=tuple(rollback_actions),
            cause=error,
        )
        raise


def _create_eks_cluster_with_retry(
    *,
    cluster_name: str,
    role_arn: str,
    network: Ec2NetworkContext,
    tags: tuple[AwsTag, ...],
    timeout_seconds: float = 180.0,
) -> dict[str, object]:
    """Retry EKS cluster creation while IAM role propagation settles."""
    deadline = time.time() + timeout_seconds
    while True:
        completed = _run_aws_cli_completed(
            "eks",
            "create-cluster",
            "--name",
            cluster_name,
            "--role-arn",
            role_arn,
            "--resources-vpc-config",
            (
                "subnetIds="
                f"{','.join(network.subnet_ids)},"
                f"securityGroupIds={network.security_group_id},"
                "endpointPublicAccess=true,"
                "endpointPrivateAccess=false"
            ),
            "--tags",
            _eks_cli_tag_map(tags),
            "--output",
            "json",
        )
        if completed.returncode == 0:
            return dict(json.loads(completed.stdout))
        stderr_text = completed.stderr.strip() or completed.stdout.strip()
        retryable = (
            "cannot be assumed" in stderr_text.lower()
            or "not authorized to perform sts:assumerole" in stderr_text.lower()
            or "role arn" in stderr_text.lower()
        )
        if not retryable or time.time() >= deadline:
            raise AssertionError(f"aws eks create-cluster failed: {stderr_text}")
        time.sleep(2.0)


def _delete_eks_cluster_by_name(cluster_name: str, *, allow_missing: bool = False) -> None:
    """Delete one EKS cluster by name and wait for full removal."""
    if not eks_cluster_exists(cluster_name):
        if allow_missing:
            return
        raise AssertionError(f"EKS cluster not found for cleanup: {cluster_name}")
    _run_aws_cli("eks", "delete-cluster", "--name", cluster_name)
    _run_aws_cli("eks", "wait", "cluster-deleted", "--name", cluster_name)


def delete_ephemeral_eks_cluster(context: EksClusterContext) -> None:
    """Delete EKS cluster first, then IAM role and network dependencies."""
    _delete_eks_cluster_by_name(context.cluster_name)
    _delete_iam_role_by_name(context.role_name)
    delete_ephemeral_ec2_network(context.network)


def delete_fixture_resource(context: object) -> None:
    """Delete one fixture-owned AWS resource context."""
    match context:
        case DelegatedRoute53ZoneContext():
            delete_delegated_hosted_zone(context)
        case Route53HostedZoneContext():
            delete_ephemeral_hosted_zone(context)
        case S3BucketContext():
            delete_ephemeral_s3_bucket(context)
        case Ec2NetworkContext():
            delete_ephemeral_ec2_network(context)
        case EksClusterContext():
            delete_ephemeral_eks_cluster(context)
        case _:
            raise AssertionError(f"unsupported fixture cleanup context: {type(context).__name__}")


def sweep_expired_fixture_resources(
    *,
    now: str | None = None,
) -> JanitorSweepResult:
    """Delete expired fixture-owned resources discovered by tags."""
    current_time = _parse_timestamp(now) if now is not None else datetime.now(UTC)
    return _sweep_fixture_resources(
        lambda tag_map: _is_expired_fixture_tag_map(tag_map, current_time)
    )


def sweep_fixture_resources_for_scope(
    *,
    project_slug: str,
    test_scope: str,
) -> JanitorSweepResult:
    """Delete prior fixture-owned resources for one declared suite scope."""
    selector = fixture_scope_selector(project_slug=project_slug, test_scope=test_scope)
    return _sweep_fixture_resources(lambda tag_map: _matches_fixture_selector(tag_map, selector))


def _sweep_fixture_resources(matcher: FixtureTagMatcher) -> JanitorSweepResult:
    """Delete matching fixture-owned resources using one shared cleanup contract."""
    deleted_eks_clusters, protected_scope_ids = _sweep_matching_eks_clusters(matcher)
    deleted_iam_roles = _sweep_matching_iam_roles(matcher)
    deleted_buckets = _sweep_matching_s3_buckets(matcher)
    deleted_vpcs = _sweep_matching_ec2_networks(
        matcher,
        protected_scope_ids=protected_scope_ids,
    )
    deleted_hosted_zones = _sweep_matching_route53_hosted_zones(matcher)
    return JanitorSweepResult(
        deleted_hosted_zones=deleted_hosted_zones,
        deleted_buckets=deleted_buckets,
        deleted_vpcs=deleted_vpcs,
        deleted_eks_clusters=deleted_eks_clusters,
        deleted_iam_roles=deleted_iam_roles,
    )


def _parse_timestamp(value: str) -> datetime:
    """Parse one canonical UTC timestamp tag."""
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


def _is_fixture_owned_tag_map(tag_map: Mapping[str, str]) -> bool:
    """Return True when one tag map belongs to the prodbox AWS fixture harness."""
    return tag_map.get(FIXTURE_OWNER_TAG) == FIXTURE_OWNER_VALUE


def _is_expired_fixture_tag_map(tag_map: Mapping[str, str], current_time: datetime) -> bool:
    """Return True when a tagged resource belongs to the fixture harness and is expired."""
    if not _is_fixture_owned_tag_map(tag_map):
        return False
    expires_at = tag_map.get(FIXTURE_EXPIRES_AT_TAG)
    if expires_at in (None, ""):
        return False
    return _parse_timestamp(expires_at) <= current_time


def _list_matching_s3_buckets(matcher: FixtureTagMatcher) -> tuple[str, ...]:
    """Return all fixture-owned S3 bucket names selected by the matcher."""
    payload = json.loads(_run_aws_cli("s3api", "list-buckets", "--output", "json"))
    bucket_names: list[str] = []
    for bucket in payload.get("Buckets", []):
        bucket_name = bucket.get("Name")
        if bucket_name in (None, ""):
            continue
        tag_map = _s3_bucket_tag_map(str(bucket_name))
        if matcher(tag_map):
            bucket_names.append(str(bucket_name))
    return tuple(bucket_names)


def _sweep_matching_s3_buckets(matcher: FixtureTagMatcher) -> int:
    """Delete all S3 buckets selected by the matcher."""
    deleted = 0
    for bucket_name in _list_matching_s3_buckets(matcher):
        delete_ephemeral_s3_bucket(
            S3BucketContext(
                scope=_janitor_scope(),
                bucket_name=bucket_name,
            )
        )
        deleted += 1
    return deleted


def _list_matching_vpcs(matcher: FixtureTagMatcher) -> tuple[Ec2NetworkContext, ...]:
    """Return minimal network contexts for fixture-owned VPCs selected by the matcher."""
    payload = json.loads(
        _run_aws_cli(
            "ec2",
            "describe-vpcs",
            "--filters",
            f"Name=tag:{FIXTURE_OWNER_TAG},Values={FIXTURE_OWNER_VALUE}",
            "--output",
            "json",
        )
    )
    contexts: list[Ec2NetworkContext] = []
    for vpc in payload.get("Vpcs", []):
        tags = {
            str(tag.get("Key")): str(tag.get("Value"))
            for tag in vpc.get("Tags", [])
            if tag.get("Key") not in (None, "") and tag.get("Value") not in (None, "")
        }
        if not matcher(tags):
            continue
        vpc_id = str(vpc.get("VpcId", ""))
        if not vpc_id:
            continue
        subnets_payload = json.loads(
            _run_aws_cli(
                "ec2",
                "describe-subnets",
                "--filters",
                f"Name=vpc-id,Values={vpc_id}",
                f"Name=tag:{FIXTURE_OWNER_TAG},Values={FIXTURE_OWNER_VALUE}",
                "--output",
                "json",
            )
        )
        subnet_ids = tuple(
            str(subnet.get("SubnetId"))
            for subnet in subnets_payload.get("Subnets", [])
            if subnet.get("SubnetId") not in (None, "")
        )
        security_groups_payload = json.loads(
            _run_aws_cli(
                "ec2",
                "describe-security-groups",
                "--filters",
                f"Name=vpc-id,Values={vpc_id}",
                f"Name=tag:{FIXTURE_OWNER_TAG},Values={FIXTURE_OWNER_VALUE}",
                "--output",
                "json",
            )
        )
        security_group_ids = [
            str(group.get("GroupId"))
            for group in security_groups_payload.get("SecurityGroups", [])
            if group.get("GroupId") not in (None, "")
        ]
        if len(security_group_ids) != 1:
            raise AssertionError(
                f"expected exactly one fixture-owned security group in matching VPC {vpc_id}"
            )
        network_interfaces_payload = json.loads(
            _run_aws_cli(
                "ec2",
                "describe-network-interfaces",
                "--filters",
                f"Name=vpc-id,Values={vpc_id}",
                f"Name=tag:{FIXTURE_OWNER_TAG},Values={FIXTURE_OWNER_VALUE}",
                "--output",
                "json",
            )
        )
        network_interface_ids = [
            str(interface.get("NetworkInterfaceId"))
            for interface in network_interfaces_payload.get("NetworkInterfaces", [])
            if interface.get("NetworkInterfaceId") not in (None, "")
        ]
        contexts.append(
            Ec2NetworkContext(
                scope=_janitor_scope(),
                vpc_id=vpc_id,
                subnet_ids=subnet_ids,
                security_group_id=security_group_ids[0],
                network_interface_id=network_interface_ids[0] if network_interface_ids else None,
            )
        )
    return tuple(contexts)


def _sweep_matching_ec2_networks(
    matcher: FixtureTagMatcher,
    *,
    protected_scope_ids: tuple[str, ...],
) -> int:
    """Delete matching VPC networks not still being removed through EKS teardown."""
    protected_scope_id_set = set(protected_scope_ids)
    deleted = 0
    for context in _list_matching_vpcs(matcher):
        tag_map = _ec2_resource_tag_map("vpc", context.vpc_id)
        scope_id = tag_map.get(FIXTURE_SCOPE_ID_TAG)
        if scope_id in protected_scope_id_set:
            continue
        delete_ephemeral_ec2_network(context)
        deleted += 1
    return deleted


def _route53_zone_context_from_id(zone_id: str) -> Route53HostedZoneContext:
    """Rebuild a minimal hosted zone context from AWS Route 53 metadata."""
    payload = json.loads(
        _run_aws_cli(
            "route53",
            "get-hosted-zone",
            "--id",
            zone_id,
            "--output",
            "json",
        )
    )
    hosted_zone = payload.get("HostedZone", {})
    zone_name = str(hosted_zone.get("Name", "")).rstrip(".")
    if not zone_name:
        raise AssertionError(f"missing hosted zone name for {zone_id}")
    tag_map = _route53_tag_map(zone_id)
    record_label = tag_map.get("prodbox_default_record_label", DEFAULT_ROUTE53_RECORD_LABEL)
    return Route53HostedZoneContext(
        scope=_janitor_scope(),
        zone_name=zone_name,
        zone_id=f"/hostedzone/{zone_id}",
        zone_resource_id=zone_id,
        record_fqdn=f"{record_label}.{zone_name}",
    )


def _matching_route53_zone_ids(matcher: FixtureTagMatcher) -> tuple[str, ...]:
    """Return all Route 53 hosted zone ids selected by the matcher."""
    payload = json.loads(_run_aws_cli("route53", "list-hosted-zones", "--output", "json"))
    zone_ids: list[str] = []
    for hosted_zone in payload.get("HostedZones", []):
        raw_id = str(hosted_zone.get("Id", ""))
        zone_id = raw_id.removeprefix("/hostedzone/")
        if not zone_id:
            continue
        if matcher(_route53_tag_map(zone_id)):
            zone_ids.append(zone_id)
    return tuple(zone_ids)


def _sweep_matching_route53_hosted_zones(matcher: FixtureTagMatcher) -> int:
    """Delete matching Route 53 hosted zones, removing delegated NS records first."""
    matching_zone_ids = _matching_route53_zone_ids(matcher)
    child_zone_ids: list[str] = []
    parent_zone_ids: list[str] = []
    for zone_id in matching_zone_ids:
        tag_map = _route53_tag_map(zone_id)
        if FIXTURE_PARENT_ZONE_ID_TAG in tag_map:
            child_zone_ids.append(zone_id)
        else:
            parent_zone_ids.append(zone_id)
    deleted = 0
    for child_zone_id in child_zone_ids:
        tag_map = _route53_tag_map(child_zone_id)
        parent_zone_id = tag_map.get(FIXTURE_PARENT_ZONE_ID_TAG)
        if parent_zone_id in (None, ""):
            continue
        child_context = _route53_zone_context_from_id(child_zone_id)
        child_payload = json.loads(
            _run_aws_cli(
                "route53",
                "get-hosted-zone",
                "--id",
                child_zone_id,
                "--output",
                "json",
            )
        )
        delegation_set = child_payload.get("DelegationSet", {})
        name_servers = tuple(
            str(server)
            for server in delegation_set.get("NameServers", [])
            if server not in (None, "")
        )
        if name_servers:
            parent_context = _route53_zone_context_from_id(str(parent_zone_id))
            delete_delegated_hosted_zone(
                DelegatedRoute53ZoneContext(
                    parent_zone=parent_context,
                    child_zone=child_context,
                    name_servers=name_servers,
                )
            )
        else:
            delete_ephemeral_hosted_zone(child_context)
        deleted += 1
    for parent_zone_id in parent_zone_ids:
        delete_ephemeral_hosted_zone(_route53_zone_context_from_id(parent_zone_id))
        deleted += 1
    return deleted


def _list_matching_iam_roles(matcher: FixtureTagMatcher) -> tuple[str, ...]:
    """Return all fixture-owned IAM role names selected by the matcher."""
    return tuple(
        role_name for role_name in _iam_role_names() if matcher(_iam_role_tag_map(role_name))
    )


def _list_matching_eks_clusters(matcher: FixtureTagMatcher) -> tuple[EksClusterContext, ...]:
    """Return all fixture-owned EKS clusters selected by the matcher."""
    payload = json.loads(_run_aws_cli("eks", "list-clusters", "--output", "json"))
    contexts: list[EksClusterContext] = []
    for cluster_name in payload.get("clusters", []):
        cluster_name_text = str(cluster_name)
        tag_map = _eks_cluster_tag_map(cluster_name_text)
        if not matcher(tag_map):
            continue
        cluster = _eks_cluster_description(cluster_name_text)
        role_arn = str(cluster.get("roleArn", ""))
        cluster_arn = str(cluster.get("arn", ""))
        if not role_arn or not cluster_arn:
            raise AssertionError(f"missing EKS cluster metadata for {cluster_name_text}")
        role_name = role_arn.rsplit("/", maxsplit=1)[-1]
        vpc_config = cluster.get("resourcesVpcConfig", {})
        if not isinstance(vpc_config, dict):
            raise AssertionError(f"missing EKS VPC config for {cluster_name_text}")
        subnet_ids = tuple(
            str(subnet_id)
            for subnet_id in vpc_config.get("subnetIds", [])
            if subnet_id not in (None, "")
        )
        security_group_ids = [
            str(group_id)
            for group_id in vpc_config.get("securityGroupIds", [])
            if group_id not in (None, "")
        ]
        if len(security_group_ids) != 1:
            raise AssertionError(
                f"expected exactly one fixture-owned EKS security group for {cluster_name_text}"
            )
        security_group_id = security_group_ids[0]
        security_group_payload = json.loads(
            _run_aws_cli(
                "ec2",
                "describe-security-groups",
                "--group-ids",
                security_group_id,
                "--output",
                "json",
            )
        )
        security_groups = security_group_payload.get("SecurityGroups", [])
        if not security_groups:
            raise AssertionError(f"missing EKS security group description for {cluster_name_text}")
        vpc_id = str(security_groups[0].get("VpcId", ""))
        contexts.append(
            EksClusterContext(
                scope=_janitor_scope(),
                cluster_name=cluster_name_text,
                cluster_arn=cluster_arn,
                role_name=role_name,
                role_arn=role_arn,
                network=Ec2NetworkContext(
                    scope=_janitor_scope(),
                    vpc_id=vpc_id,
                    subnet_ids=subnet_ids,
                    security_group_id=security_group_id,
                    network_interface_id=None,
                ),
            )
        )
    return tuple(contexts)


def _sweep_matching_eks_clusters(matcher: FixtureTagMatcher) -> tuple[int, tuple[str, ...]]:
    """Delete all fixture-owned EKS clusters selected by the matcher."""
    deleted = 0
    scope_ids: list[str] = []
    for context in _list_matching_eks_clusters(matcher):
        scope_id = _eks_cluster_tag_map(context.cluster_name).get(FIXTURE_SCOPE_ID_TAG)
        delete_ephemeral_eks_cluster(context)
        deleted += 1
        if scope_id not in (None, ""):
            scope_ids.append(scope_id)
    return deleted, tuple(scope_ids)


def _sweep_matching_iam_roles(matcher: FixtureTagMatcher) -> int:
    """Delete matching IAM roles that are not still attached to live resources."""
    deleted = 0
    for role_name in _list_matching_iam_roles(matcher):
        _delete_iam_role_by_name(role_name)
        deleted += 1
    return deleted


def fixture_owned_resource_inventory() -> JanitorInventoryResult:
    """Return counts for every fixture-owned AWS resource class still visible."""
    matcher = _is_fixture_owned_tag_map
    return JanitorInventoryResult(
        remaining_hosted_zones=len(_matching_route53_zone_ids(matcher)),
        remaining_buckets=len(_list_matching_s3_buckets(matcher)),
        remaining_vpcs=len(_list_matching_vpcs(matcher)),
        remaining_eks_clusters=len(_list_matching_eks_clusters(matcher)),
        remaining_iam_roles=len(_list_matching_iam_roles(matcher)),
    )
