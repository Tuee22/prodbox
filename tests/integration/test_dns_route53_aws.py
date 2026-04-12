"""Real Route 53 integration tests using ephemeral AWS resources."""

from __future__ import annotations

import asyncio
from collections.abc import Iterator
from typing import Never

import pytest
from click.testing import CliRunner

from prodbox.cli.main import cli
from prodbox.gateway_daemon import DnsWriteGate, Route53DnsWriteClient

from .aws_helpers import (
    ROUTE53_RECORD_TTL_SECONDS,
    Route53HostedZoneContext,
    build_dns_suite_env,
    create_ephemeral_hosted_zone,
    delete_ephemeral_hosted_zone,
    has_required_fixture_tags,
    override_config_json,
    query_route53_a_record,
    route53_zone_tag_map,
    wait_for_route53_a_record,
)


def _abort_session_on_teardown_failure(*, target: str, error: BaseException) -> Never:
    """Abort the pytest session immediately for teardown cleanup failure."""
    pytest.exit(
        f"teardown cleanup failed for {target}: {type(error).__name__}: {error}",
        returncode=1,
    )


def _extract_report_value(output: str, key: str) -> str:
    """Extract one KEY=value line from deterministic command output."""
    prefix = f"{key}="
    for line in output.splitlines():
        if line.startswith(prefix):
            return line.removeprefix(prefix)
    raise AssertionError(f"missing {key}=... line in output:\n{output}")


@pytest.fixture
def ephemeral_route53_zone() -> Iterator[Route53HostedZoneContext]:
    """Create and always clean up a fresh Route 53 hosted zone."""
    context = create_ephemeral_hosted_zone(test_scope="dns-aws")
    try:
        yield context
    finally:
        try:
            delete_ephemeral_hosted_zone(context)
        except Exception as error:
            _abort_session_on_teardown_failure(target=context.zone_name, error=error)


@pytest.mark.integration
def test_dns_check_reports_ephemeral_route53_zone_state(
    cli_runner: CliRunner,
    ephemeral_route53_zone: Route53HostedZoneContext,
) -> None:
    """dns check should read only the fixture-owned hosted zone."""
    suite_env = build_dns_suite_env(ephemeral_route53_zone)
    assert has_required_fixture_tags(
        ephemeral_route53_zone.scope,
        route53_zone_tag_map(ephemeral_route53_zone),
    )
    config_overrides: dict[str, object] = {
        "route53": {"zone_id": suite_env["ROUTE53_ZONE_ID"]},
        "domain": {
            "demo_fqdn": suite_env["DEMO_FQDN"],
            "demo_ttl": int(suite_env["DEMO_TTL"]),
        },
    }
    with override_config_json(config_overrides):
        initial_check = cli_runner.invoke(cli, ["dns", "check"], catch_exceptions=False)
    assert initial_check.exit_code == 0
    assert f"FQDN={ephemeral_route53_zone.record_fqdn}" in initial_check.output
    assert "ROUTE53_A_RECORD=<missing>" in initial_check.output
    assert "STATUS=record-missing" in initial_check.output

    target_public_ip = _extract_report_value(initial_check.output, "PUBLIC_IP")
    assert target_public_ip


@pytest.mark.integration
def test_gateway_route53_dns_write_client_upserts_fixture_owned_record(
    ephemeral_route53_zone: Route53HostedZoneContext,
) -> None:
    """Gateway Route 53 write client should own the canonical DNS mutation path."""
    suite_env = build_dns_suite_env(ephemeral_route53_zone)
    gate = DnsWriteGate(
        zone_id=ephemeral_route53_zone.zone_resource_id,
        fqdn=ephemeral_route53_zone.record_fqdn,
        ttl=ROUTE53_RECORD_TTL_SECONDS,
        aws_region=suite_env["AWS_REGION"],
    )
    client = Route53DnsWriteClient.from_gate(gate)

    first_ip = "198.51.100.10"
    second_ip = "198.51.100.11"

    assert (
        asyncio.run(
            client.update_route53_record(
                zone_id=gate.zone_id,
                fqdn=gate.fqdn,
                ip_address=first_ip,
                ttl=gate.ttl,
            )
        )
        is True
    )
    wait_for_route53_a_record(ephemeral_route53_zone, expected_value=first_ip)
    assert query_route53_a_record(ephemeral_route53_zone) == first_ip

    assert (
        asyncio.run(
            client.update_route53_record(
                zone_id=gate.zone_id,
                fqdn=gate.fqdn,
                ip_address=second_ip,
                ttl=gate.ttl,
            )
        )
        is True
    )
    wait_for_route53_a_record(ephemeral_route53_zone, expected_value=second_ip)
    assert query_route53_a_record(ephemeral_route53_zone) == second_ip
