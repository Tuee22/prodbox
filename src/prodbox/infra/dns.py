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


def get_public_ip() -> str:
    """Get current public IP address.

    Used to set an initial value for the A record.
    The DDNS updater will keep it current.

    Returns:
        Current public IP address or placeholder
    """
    import httpx

    try:
        response = httpx.get("https://api.ipify.org", timeout=10)
        response.raise_for_status()
        return response.text.strip()
    except Exception:
        # Return a placeholder - DDNS will update it
        return "0.0.0.0"


def deploy_dns(
    settings: Settings,
    aws_provider: aws.Provider,
) -> DNSResources:
    """Deploy Route 53 DNS A record.

    Creates an A record pointing to the current public IP.
    The DDNS updater will keep the IP current as it changes.

    Pulumi owns the record's existence (so destroy cleans up),
    but ignores changes to the actual IP value (DDNS manages it).

    Args:
        settings: Application settings with DNS configuration
        aws_provider: AWS provider

    Returns:
        DNSResources containing all created resources
    """
    # Get current public IP for initial value
    current_ip = get_public_ip()

    # Create A record
    # ignore_changes on records ensures DDNS updates aren't reverted
    a_record = aws.route53.Record(
        "demo-a-record",
        zone_id=settings.route53_zone_id,
        name=settings.demo_fqdn,
        type="A",
        ttl=settings.demo_ttl,
        records=[current_ip],
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
