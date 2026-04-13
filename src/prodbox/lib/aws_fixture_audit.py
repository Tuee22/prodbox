"""Audit fixture-owned AWS resources after supported test runs."""

from __future__ import annotations

import os
import subprocess
from collections.abc import Mapping
from dataclasses import dataclass

from prodbox.settings import get_settings

FIXTURE_OWNER_TAG: str = "managed_by"
FIXTURE_OWNER_VALUE: str = "prodbox-integration"


@dataclass(frozen=True)
class AwsFixtureInventory:
    """Counts of fixture-owned AWS resources still visible after one run."""

    remaining_hosted_zones: int
    remaining_buckets: int
    remaining_vpcs: int
    remaining_eks_clusters: int
    remaining_iam_roles: int


def _aws_env(extra_env: Mapping[str, str] | None = None) -> dict[str, str]:
    """Return an explicit AWS CLI environment rebuilt from canonical settings."""
    settings = get_settings()
    env: dict[str, str] = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", ""),
        "AWS_ACCESS_KEY_ID": settings.aws_access_key_id,
        "AWS_SECRET_ACCESS_KEY": settings.aws_secret_access_key,
        "AWS_PAGER": "",
        "AWS_REGION": settings.aws_region,
        "AWS_DEFAULT_REGION": settings.aws_region,
    }
    match settings.aws_session_token:
        case str() as token:
            env["AWS_SESSION_TOKEN"] = token
        case None:
            pass
    match extra_env:
        case None:
            pass
        case _:
            env.update(dict(extra_env))
    return env


def _run_aws_cli_completed(*args: str) -> subprocess.CompletedProcess[str]:
    """Run one AWS CLI command with canonical credentials and capture output."""
    return subprocess.run(
        ["aws", *args],
        check=False,
        capture_output=True,
        text=True,
        env=_aws_env(),
    )


def _run_aws_cli(*args: str) -> str:
    """Run one AWS CLI command and return stripped stdout on success."""
    completed = _run_aws_cli_completed(*args)
    if completed.returncode != 0:
        stderr_text = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"aws {' '.join(args)} failed: {stderr_text}")
    return completed.stdout.strip()


def _split_text_items(output: str) -> tuple[str, ...]:
    """Split AWS text output into normalized items."""
    stripped = output.strip()
    if stripped in ("", "None"):
        return ()
    return tuple(item for item in stripped.split() if item not in ("", "None"))


def _parse_count(output: str) -> int:
    """Parse one integer count returned by the AWS CLI text formatter."""
    stripped = output.strip()
    if not stripped.isdigit():
        raise RuntimeError(f"expected integer AWS CLI count, got: {stripped}")
    return int(stripped)


def _route53_zone_owner_value(zone_id: str) -> str | None:
    """Return the fixture-owner tag value for one hosted zone when present."""
    output = _run_aws_cli(
        "route53",
        "list-tags-for-resource",
        "--resource-type",
        "hostedzone",
        "--resource-id",
        zone_id,
        "--query",
        f"ResourceTagSet.Tags[?Key==`{FIXTURE_OWNER_TAG}`].Value | [0]",
        "--output",
        "text",
    )
    match output.strip():
        case "" | "None":
            return None
        case value:
            return value


def _bucket_owner_value(bucket_name: str) -> str | None:
    """Return the fixture-owner tag value for one S3 bucket when present."""
    completed = _run_aws_cli_completed(
        "s3api",
        "get-bucket-tagging",
        "--bucket",
        bucket_name,
        "--query",
        f"TagSet[?Key==`{FIXTURE_OWNER_TAG}`].Value | [0]",
        "--output",
        "text",
    )
    if completed.returncode != 0:
        stderr_text = completed.stderr.strip() or completed.stdout.strip()
        if any(
            marker in stderr_text
            for marker in ("NoSuchTagSet", "The TagSet does not exist", "NoSuchBucket")
        ):
            return None
        raise RuntimeError(
            f"aws s3api get-bucket-tagging --bucket {bucket_name} failed: {stderr_text}"
        )
    match completed.stdout.strip():
        case "" | "None":
            return None
        case value:
            return value


def _eks_cluster_owner_value(cluster_name: str) -> str | None:
    """Return the fixture-owner tag value for one EKS cluster when present."""
    output = _run_aws_cli(
        "eks",
        "describe-cluster",
        "--name",
        cluster_name,
        "--query",
        f"cluster.tags.{FIXTURE_OWNER_TAG}",
        "--output",
        "text",
    )
    match output.strip():
        case "" | "None":
            return None
        case value:
            return value


def _iam_role_owner_value(role_name: str) -> str | None:
    """Return the fixture-owner tag value for one IAM role when present."""
    output = _run_aws_cli(
        "iam",
        "list-role-tags",
        "--role-name",
        role_name,
        "--query",
        f"Tags[?Key==`{FIXTURE_OWNER_TAG}`].Value | [0]",
        "--output",
        "text",
    )
    match output.strip():
        case "" | "None":
            return None
        case value:
            return value


def _matching_hosted_zone_count() -> int:
    """Return the count of fixture-owned Route 53 hosted zones."""
    zone_ids = tuple(
        zone_id.removeprefix("/hostedzone/")
        for zone_id in _split_text_items(
            _run_aws_cli(
                "route53",
                "list-hosted-zones",
                "--query",
                "HostedZones[].Id",
                "--output",
                "text",
            )
        )
    )
    return sum(
        1 for zone_id in zone_ids if _route53_zone_owner_value(zone_id) == FIXTURE_OWNER_VALUE
    )


def _matching_bucket_count() -> int:
    """Return the count of fixture-owned S3 buckets."""
    bucket_names = _split_text_items(
        _run_aws_cli(
            "s3api",
            "list-buckets",
            "--query",
            "Buckets[].Name",
            "--output",
            "text",
        )
    )
    return sum(
        1 for bucket_name in bucket_names if _bucket_owner_value(bucket_name) == FIXTURE_OWNER_VALUE
    )


def _matching_vpc_count() -> int:
    """Return the count of fixture-owned VPCs."""
    output = _run_aws_cli(
        "ec2",
        "describe-vpcs",
        "--filters",
        f"Name=tag:{FIXTURE_OWNER_TAG},Values={FIXTURE_OWNER_VALUE}",
        "--query",
        "length(Vpcs)",
        "--output",
        "text",
    )
    return _parse_count(output)


def _matching_eks_cluster_count() -> int:
    """Return the count of fixture-owned EKS clusters."""
    cluster_names = _split_text_items(
        _run_aws_cli(
            "eks",
            "list-clusters",
            "--query",
            "clusters[]",
            "--output",
            "text",
        )
    )
    return sum(
        1
        for cluster_name in cluster_names
        if _eks_cluster_owner_value(cluster_name) == FIXTURE_OWNER_VALUE
    )


def _matching_iam_role_count() -> int:
    """Return the count of fixture-owned IAM roles."""
    role_names = _split_text_items(
        _run_aws_cli(
            "iam",
            "list-roles",
            "--query",
            "Roles[].RoleName",
            "--output",
            "text",
        )
    )
    return sum(
        1 for role_name in role_names if _iam_role_owner_value(role_name) == FIXTURE_OWNER_VALUE
    )


def fixture_owned_resource_inventory() -> AwsFixtureInventory:
    """Return counts for every fixture-owned AWS resource class still visible."""
    return AwsFixtureInventory(
        remaining_hosted_zones=_matching_hosted_zone_count(),
        remaining_buckets=_matching_bucket_count(),
        remaining_vpcs=_matching_vpc_count(),
        remaining_eks_clusters=_matching_eks_cluster_count(),
        remaining_iam_roles=_matching_iam_role_count(),
    )


def assert_no_fixture_owned_resources_remain() -> None:
    """Fail when any fixture-owned AWS resources remain visible after a supported run."""
    inventory = fixture_owned_resource_inventory()
    total_remaining = (
        inventory.remaining_hosted_zones
        + inventory.remaining_buckets
        + inventory.remaining_vpcs
        + inventory.remaining_eks_clusters
        + inventory.remaining_iam_roles
    )
    if total_remaining == 0:
        return
    details = ", ".join(
        (
            f"route53={inventory.remaining_hosted_zones}",
            f"s3={inventory.remaining_buckets}",
            f"vpc={inventory.remaining_vpcs}",
            f"eks={inventory.remaining_eks_clusters}",
            f"iam={inventory.remaining_iam_roles}",
        )
    )
    raise RuntimeError(
        f"fixture-owned AWS resources still remain after the supported run: {details}"
    )
