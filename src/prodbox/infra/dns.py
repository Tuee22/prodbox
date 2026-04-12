"""Route 53 DNS infrastructure module."""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

import pulumi
import pulumi_aws as aws

if TYPE_CHECKING:
    from prodbox.settings import Settings


@dataclass(frozen=True)
class DNSResources:
    """Container for DNS resources."""

    a_record: aws.route53.Record


def get_public_ip(*, bootstrap_override: str | None = None) -> str:
    """Get current public IP address.

    Used to set an initial value for the A record.
    The gateway DNS-write path keeps it current after bootstrap.

    Returns:
        Current public IP address or explicit bootstrap override
    """
    if bootstrap_override is not None and bootstrap_override.strip():
        return bootstrap_override.strip()

    import httpx

    try:
        response = httpx.get("https://api.ipify.org", timeout=10)
        response.raise_for_status()
        return response.text.strip()
    except Exception as error:
        raise RuntimeError(
            "Failed to resolve bootstrap public IP. "
            "Set BOOTSTRAP_PUBLIC_IP_OVERRIDE for bootstrap-only deployments."
        ) from error


def deploy_dns(
    settings: Settings,
    aws_provider: aws.Provider,
) -> DNSResources:
    """Deploy Route 53 DNS A record.

    Creates an A record pointing to the current public IP.
    The gateway owner DNS-write path keeps the IP current as it changes.

    Pulumi owns the record's existence (so destroy cleans up),
    but ignores changes to the actual IP value (gateway DNS writes manage it).

    Args:
        settings: Application settings with DNS configuration
        aws_provider: AWS provider

    Returns:
        DNSResources containing all created resources
    """
    # Get current public IP for initial value
    current_ip = get_public_ip(bootstrap_override=settings.bootstrap_public_ip_override)

    # Create A record
    # ignore_changes on records ensures gateway DNS writes aren't reverted
    a_record = aws.route53.Record(
        "demo-a-record",
        zone_id=settings.route53_zone_id,
        name=settings.demo_fqdn,
        type="A",
        ttl=settings.demo_ttl,
        records=[current_ip],
        allow_overwrite=True,
        opts=pulumi.ResourceOptions(
            provider=aws_provider,
            ignore_changes=["records"],
        ),
    )

    # Export DNS info
    pulumi.export("demo_fqdn", settings.demo_fqdn)
    pulumi.export("demo_ttl", settings.demo_ttl)

    return DNSResources(
        a_record=a_record,
    )
