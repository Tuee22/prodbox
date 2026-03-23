"""Real Route 53 integration tests using ephemeral AWS resources."""

from __future__ import annotations

from collections.abc import Iterator
from typing import Never

import pytest
from click.testing import CliRunner

from prodbox.cli.main import cli

from .aws_helpers import (
    Route53HostedZoneContext,
    build_dns_suite_env,
    create_ephemeral_hosted_zone,
    delete_ephemeral_hosted_zone,
    query_route53_a_record,
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
def test_dns_check_and_update_round_trip_against_ephemeral_route53_zone(
    cli_runner: CliRunner,
    ephemeral_route53_zone: Route53HostedZoneContext,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """dns check/update should read and mutate only the fixture-owned hosted zone."""
    for key, value in build_dns_suite_env(ephemeral_route53_zone).items():
        monkeypatch.setenv(key, value)

    initial_check = cli_runner.invoke(cli, ["dns", "check"], catch_exceptions=False)
    assert initial_check.exit_code == 0
    assert f"FQDN={ephemeral_route53_zone.record_fqdn}" in initial_check.output
    assert "ROUTE53_A_RECORD=<missing>" in initial_check.output
    assert "STATUS=record-missing" in initial_check.output

    update_result = cli_runner.invoke(cli, ["dns", "update"], catch_exceptions=False)
    assert update_result.exit_code == 0
    assert "ACTION=updated" in update_result.output
    target_public_ip = _extract_report_value(update_result.output, "TARGET_PUBLIC_IP")
    wait_for_route53_a_record(ephemeral_route53_zone, expected_value=target_public_ip)
    assert query_route53_a_record(ephemeral_route53_zone) == target_public_ip

    synced_check = cli_runner.invoke(cli, ["dns", "check"], catch_exceptions=False)
    assert synced_check.exit_code == 0
    assert f"PUBLIC_IP={target_public_ip}" in synced_check.output
    assert f"ROUTE53_A_RECORD={target_public_ip}" in synced_check.output
    assert "STATUS=in-sync" in synced_check.output

    second_update = cli_runner.invoke(cli, ["dns", "update"], catch_exceptions=False)
    assert second_update.exit_code == 0
    assert "ACTION=no-op" in second_update.output
