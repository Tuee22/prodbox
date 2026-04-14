"""Minimal AWS CLI helpers for Route 53-backed integration tests."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
import uuid
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

from prodbox.settings import get_settings

DEFAULT_ROUTE53_RECORD_LABEL: str = "app"
ROUTE53_RECORD_TTL_SECONDS: int = 60


@dataclass(frozen=True)
class Route53HostedZoneContext:
    """Ephemeral Route 53 hosted zone owned by one integration test."""

    zone_name: str
    zone_id: str
    zone_resource_id: str
    record_fqdn: str


def _aws_env(extra_env: Mapping[str, str] | None = None) -> dict[str, str]:
    """Return AWS CLI environment with credentials from Settings."""
    settings = get_settings()
    env: dict[str, str] = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", ""),
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "AWS_ACCESS_KEY_ID": settings.aws_access_key_id,
        "AWS_SECRET_ACCESS_KEY": settings.aws_secret_access_key,
        "AWS_REGION": settings.aws_region,
        "AWS_DEFAULT_REGION": settings.aws_region,
        "AWS_PAGER": "",
    }
    match settings.aws_session_token:
        case str() as token:
            env["AWS_SESSION_TOKEN"] = token
        case None:
            pass
    match os.environ.get("TERM"):
        case str() as term:
            env["TERM"] = term
        case _:
            pass
    match extra_env:
        case Mapping() as extras:
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


@contextmanager
def _temporary_json_file(prefix: str, payload: dict[str, object]) -> Iterator[Path]:
    """Write one temporary JSON payload to disk for AWS CLI file:// arguments."""
    with tempfile.NamedTemporaryFile(
        mode="w",
        suffix=".json",
        prefix=prefix,
        delete=False,
        encoding="utf-8",
    ) as handle:
        json.dump(payload, handle)
        temp_path = Path(handle.name)
    try:
        yield temp_path
    finally:
        temp_path.unlink(missing_ok=True)


def _normalize_name_fragment(value: str, *, max_length: int) -> str:
    """Return a lowercase ASCII-safe resource-name fragment."""
    lowered = value.lower()
    allowed = [character if character.isalnum() else "-" for character in lowered]
    collapsed = "".join(allowed).strip("-")
    while "--" in collapsed:
        collapsed = collapsed.replace("--", "-")
    fallback = collapsed or "fixture"
    return fallback[:max_length].strip("-") or "fixture"


def create_ephemeral_hosted_zone(*, test_scope: str) -> Route53HostedZoneContext:
    """Create a brand-new ephemeral Route 53 hosted zone for one test."""
    normalized_scope = _normalize_name_fragment(test_scope, max_length=20)
    unique_suffix = uuid.uuid4().hex[:10]
    zone_name = f"prodbox-{normalized_scope}-{unique_suffix}.dev"
    zone_id = _run_aws_cli(
        "route53",
        "create-hosted-zone",
        "--name",
        zone_name,
        "--caller-reference",
        f"{normalized_scope}-{unique_suffix}",
        "--hosted-zone-config",
        "Comment=prodbox-ephemeral-integration-zone,PrivateZone=false",
        "--query",
        "HostedZone.Id",
        "--output",
        "text",
    )
    zone_resource_id = zone_id.removeprefix("/hostedzone/")
    return Route53HostedZoneContext(
        zone_name=zone_name,
        zone_id=zone_id,
        zone_resource_id=zone_resource_id,
        record_fqdn=f"{DEFAULT_ROUTE53_RECORD_LABEL}.{zone_name}",
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
    """Write a temporary ``prodbox-config.json`` with field overrides."""
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
                case (dict() as existing_dict, dict() as value_dict):
                    merged[key] = _deep_merge(
                        {str(k): v for k, v in existing_dict.items()},
                        {str(k): v for k, v in value_dict.items()},
                    )
                case _:
                    merged[key] = value
        return merged

    merged = _deep_merge(base_config, overrides)
    temp_dir = Path(tempfile.mkdtemp(prefix="prodbox-config-"))
    temp_config = temp_dir / "prodbox-config.json"
    temp_config.write_text(json.dumps(merged, indent=2), encoding="utf-8")

    settings_module.REPOSITORY_ROOT = temp_dir
    clear_settings_cache()
    try:
        yield temp_dir
    finally:
        settings_module.REPOSITORY_ROOT = original_root
        clear_settings_cache()
        shutil.rmtree(temp_dir, ignore_errors=True)


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


def _wait_for_route53_mutable_records_absent(
    context: Route53HostedZoneContext,
    *,
    timeout_seconds: float = 30.0,
) -> None:
    """Poll until the hosted zone contains no mutable record sets."""
    deadline = time.time() + timeout_seconds
    while True:
        if _route53_mutable_record_sets(context) == []:
            return
        if time.time() >= deadline:
            raise AssertionError(f"timed out waiting for hosted zone cleanup: {context.zone_name}")
        time.sleep(1.0)


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


__all__ = [
    "ROUTE53_RECORD_TTL_SECONDS",
    "Route53HostedZoneContext",
    "build_dns_suite_env",
    "create_ephemeral_hosted_zone",
    "delete_ephemeral_hosted_zone",
    "override_config_json",
    "query_route53_a_record",
    "query_route53_record_values",
    "wait_for_route53_a_record",
    "wait_for_route53_record_values",
]
