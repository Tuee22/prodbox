"""AWS CLI helpers for real integration tests."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Route53HostedZoneContext:
    """Ephemeral Route 53 hosted zone owned by one integration fixture."""

    zone_name: str
    zone_id: str
    zone_resource_id: str
    record_fqdn: str


def _required_env_var(name: str) -> str:
    """Return one required environment variable or raise AssertionError."""
    value = os.environ.get(name)
    if value in (None, ""):
        raise AssertionError(f"missing required environment variable: {name}")
    return value


def _aws_env(extra_env: Mapping[str, str] | None = None) -> dict[str, str]:
    """Return AWS CLI environment with paging disabled."""
    env = dict(os.environ)
    env["AWS_PAGER"] = ""
    if extra_env is not None:
        env.update(extra_env)
    return env


def _run_aws_cli(*args: str, env: Mapping[str, str] | None = None) -> str:
    """Run one AWS CLI command and return stripped stdout."""
    completed = subprocess.run(
        ["aws", *args],
        check=False,
        capture_output=True,
        text=True,
        env=_aws_env(env),
    )
    if completed.returncode != 0:
        stderr_text = completed.stderr.strip() or completed.stdout.strip()
        raise AssertionError(f"aws {' '.join(args)} failed: {stderr_text}")
    return completed.stdout.strip()


def require_aws_cli_identity() -> str:
    """Validate that the AWS CLI is installed and credentials are usable."""
    if shutil.which("aws") is None:
        raise AssertionError("aws CLI not installed")
    return _run_aws_cli("sts", "get-caller-identity", "--query", "Account", "--output", "text")


def create_ephemeral_hosted_zone(*, test_scope: str) -> Route53HostedZoneContext:
    """Create a brand-new ephemeral Route 53 hosted zone for one test."""
    require_aws_cli_identity()
    suffix = uuid.uuid4().hex[:12]
    zone_name = f"prodbox-int-{suffix}.example.com"
    zone_id = _run_aws_cli(
        "route53",
        "create-hosted-zone",
        "--name",
        zone_name,
        "--caller-reference",
        f"{test_scope}-{uuid.uuid4().hex}",
        "--hosted-zone-config",
        "Comment=prodbox-ephemeral-integration-zone,PrivateZone=false",
        "--query",
        "HostedZone.Id",
        "--output",
        "text",
    )
    zone_resource_id = zone_id.removeprefix("/hostedzone/")
    _run_aws_cli(
        "route53",
        "change-tags-for-resource",
        "--resource-type",
        "hostedzone",
        "--resource-id",
        zone_resource_id,
        "--add-tags",
        "Key=Name,Value=prodbox-ephemeral-integration-zone",
        "Key=prodbox_ephemeral,Value=true",
        "Key=prodbox_safe_to_delete,Value=true",
        f"Key=prodbox_test_scope,Value={test_scope}",
    )
    return Route53HostedZoneContext(
        zone_name=zone_name,
        zone_id=zone_id,
        zone_resource_id=zone_resource_id,
        record_fqdn=f"app.{zone_name}",
    )


def query_route53_a_record(context: Route53HostedZoneContext) -> str | None:
    """Return the current A record value for the fixture-owned FQDN, if any."""
    result = _run_aws_cli(
        "route53",
        "list-resource-record-sets",
        "--hosted-zone-id",
        context.zone_resource_id,
        "--query",
        (
            "ResourceRecordSets[?Name == '"
            f"{context.record_fqdn}.'"
            "' && Type == 'A'].ResourceRecords[0].Value"
        ),
        "--output",
        "text",
    )
    normalized = result.strip()
    if normalized in ("", "None"):
        return None
    return normalized


def wait_for_route53_a_record(
    context: Route53HostedZoneContext,
    *,
    expected_value: str | None,
    timeout_seconds: float = 30.0,
) -> None:
    """Poll Route 53 until the fixture-owned A record matches the expected value."""
    deadline = time.time() + timeout_seconds
    while True:
        current_value = query_route53_a_record(context)
        if current_value == expected_value:
            return
        if time.time() >= deadline:
            raise AssertionError(
                "timed out waiting for Route 53 record "
                f"{context.record_fqdn} to become {expected_value!r}; current={current_value!r}"
            )
        time.sleep(1.0)


def build_dns_suite_env(context: Route53HostedZoneContext) -> dict[str, str]:
    """Return environment overrides for real DNS integration tests."""
    return {
        "AWS_ACCESS_KEY_ID": _required_env_var("AWS_ACCESS_KEY_ID"),
        "AWS_SECRET_ACCESS_KEY": _required_env_var("AWS_SECRET_ACCESS_KEY"),
        "AWS_REGION": os.environ.get("AWS_REGION", "us-east-1"),
        "ROUTE53_ZONE_ID": context.zone_resource_id,
        "DEMO_FQDN": context.record_fqdn,
        "ACME_EMAIL": os.environ.get("ACME_EMAIL", "integration@example.com"),
    }


def delete_ephemeral_hosted_zone(context: Route53HostedZoneContext) -> None:
    """Delete the fixture-owned record and hosted zone."""
    record_value = query_route53_a_record(context)
    if record_value is not None:
        change_batch: dict[str, object] = {
            "Changes": [
                {
                    "Action": "DELETE",
                    "ResourceRecordSet": {
                        "Name": context.record_fqdn,
                        "Type": "A",
                        "TTL": 60,
                        "ResourceRecords": [{"Value": record_value}],
                    },
                }
            ]
        }
        with tempfile.TemporaryDirectory(prefix="prodbox-route53-cleanup-") as temp_dir:
            batch_path = Path(temp_dir) / "delete-record-batch.json"
            batch_path.write_text(json.dumps(change_batch), encoding="utf-8")
            _run_aws_cli(
                "route53",
                "change-resource-record-sets",
                "--hosted-zone-id",
                context.zone_resource_id,
                "--change-batch",
                f"file://{batch_path}",
            )
        wait_for_route53_a_record(context, expected_value=None)

    _run_aws_cli(
        "route53",
        "delete-hosted-zone",
        "--id",
        context.zone_resource_id,
    )
