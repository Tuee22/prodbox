"""Integration tests for public Route 53 delegation of the configured VS Code host."""

from __future__ import annotations

import json
import urllib.parse
import urllib.request
from functools import lru_cache
from typing import NamedTuple, cast
from urllib.error import URLError

import pytest

from prodbox.settings import Settings

pytestmark = [pytest.mark.integration, pytest.mark.timeout(120)]

_PUBLIC_DOH_RESOLVER = "https://dns.google/resolve"
_PUBLIC_DOH_TIMEOUT_SECONDS = 15.0


class HostedZoneDelegation(NamedTuple):
    """Canonical Route 53 hosted-zone delegation details."""

    zone_name: str
    name_servers: tuple[str, ...]


def _normalize_dns_name(name: str) -> str:
    """Normalize a DNS name for case-insensitive comparison."""
    return name.rstrip(".").lower()


@lru_cache(maxsize=1)
def _settings() -> Settings:
    """Load fixed-repository settings once for this suite."""
    return Settings.from_config_json()


@lru_cache(maxsize=1)
def _canonical_hosted_zone_delegation() -> HostedZoneDelegation:
    """Read the canonical hosted-zone delegation set from Route 53."""
    import boto3

    settings = _settings()
    route53 = boto3.Session(
        aws_access_key_id=settings.aws_access_key_id,
        aws_secret_access_key=settings.aws_secret_access_key,
        aws_session_token=settings.aws_session_token,
        region_name=settings.aws_region,
    ).client("route53")
    try:
        response = route53.get_hosted_zone(Id=settings.route53_zone_id)
    except Exception as error:
        raise AssertionError(
            "Route 53 hosted-zone lookup failed for "
            f"{settings.route53_zone_id}: {type(error).__name__}: {error}"
        ) from error

    hosted_zone = response.get("HostedZone")
    if not isinstance(hosted_zone, dict):
        raise AssertionError("Route 53 get_hosted_zone response missing HostedZone mapping")
    raw_zone_name = hosted_zone.get("Name")
    if not isinstance(raw_zone_name, str) or raw_zone_name == "":
        raise AssertionError("Route 53 get_hosted_zone response missing HostedZone.Name")

    delegation_set = response.get("DelegationSet")
    if not isinstance(delegation_set, dict):
        raise AssertionError("Route 53 get_hosted_zone response missing DelegationSet mapping")
    raw_name_servers = delegation_set.get("NameServers")
    if not isinstance(raw_name_servers, list):
        raise AssertionError("Route 53 get_hosted_zone response missing DelegationSet.NameServers")

    name_servers = tuple(
        sorted(
            _normalize_dns_name(name_server)
            for name_server in raw_name_servers
            if isinstance(name_server, str) and name_server != ""
        )
    )
    if not name_servers:
        raise AssertionError(
            f"Route 53 hosted zone {settings.route53_zone_id} has no delegation set"
        )

    return HostedZoneDelegation(
        zone_name=_normalize_dns_name(raw_zone_name),
        name_servers=name_servers,
    )


def _public_ns_records(name: str) -> tuple[str, ...]:
    """Query public recursive DNS for NS records via DNS-over-HTTPS."""
    query = urllib.parse.urlencode({"name": name, "type": "NS"})
    request = urllib.request.Request(
        f"{_PUBLIC_DOH_RESOLVER}?{query}",
        headers={"Accept": "application/dns-json"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=_PUBLIC_DOH_TIMEOUT_SECONDS) as response:
            payload = cast(dict[str, object], json.loads(response.read().decode("utf-8")))
    except URLError as error:
        raise AssertionError(f"public DNS query failed for {name}: {error}") from error

    status = payload.get("Status")
    if status != 0:
        raise AssertionError(f"public DNS query returned non-zero status for {name}: {status}")
    raw_answers = payload.get("Answer")
    if not isinstance(raw_answers, list):
        raise AssertionError(f"public DNS query returned no Answer section for {name}")

    name_servers = tuple(
        sorted(
            _normalize_dns_name(data)
            for answer in raw_answers
            if isinstance(answer, dict)
            for answer_type in (answer.get("type"),)
            for data in (answer.get("data"),)
            if answer_type == 2 and isinstance(data, str) and data != ""
        )
    )
    if not name_servers:
        raise AssertionError(f"public DNS query returned no NS answers for {name}")
    return name_servers


@pytest.mark.integration
def test_vscode_fqdn_is_owned_by_the_canonical_route53_zone() -> None:
    """Configured public VS Code host must live inside the canonical hosted zone."""
    delegation = _canonical_hosted_zone_delegation()
    fqdn = _normalize_dns_name(_settings().vscode_fqdn)
    assert fqdn == delegation.zone_name or fqdn.endswith(
        f".{delegation.zone_name}"
    ), f"configured VSCODE_FQDN {fqdn!r} is not inside hosted zone {delegation.zone_name!r}"


@pytest.mark.integration
def test_public_ns_records_delegate_to_the_canonical_route53_zone() -> None:
    """Public recursive DNS must return the hosted-zone delegation set for the zone apex."""
    delegation = _canonical_hosted_zone_delegation()
    assert _public_ns_records(delegation.zone_name) == delegation.name_servers
