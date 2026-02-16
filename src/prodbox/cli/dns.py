"""DNS and DDNS management commands."""

from __future__ import annotations

from pathlib import Path

import click

from prodbox.cli.main import SettingsContext, pass_settings
from prodbox.lib.async_runner import async_command
from prodbox.lib.logging import print_error, print_info, print_success, print_warning
from prodbox.lib.subprocess import run_command


async def get_public_ip() -> str:
    """Get current public IP address."""
    import httpx

    async with httpx.AsyncClient() as client:
        response = await client.get("https://api.ipify.org", timeout=10)
        response.raise_for_status()
        return response.text.strip()


async def get_current_dns_ip(settings: "Settings") -> str | None:  # type: ignore[name-defined]
    """Get current IP from Route 53 DNS record."""
    import boto3

    client = boto3.client(
        "route53",
        region_name=settings.aws_region,
        aws_access_key_id=settings.aws_access_key_id,
        aws_secret_access_key=settings.aws_secret_access_key,
    )

    fqdn = settings.demo_fqdn
    zone_id = settings.route53_zone_id

    response = client.list_resource_record_sets(
        HostedZoneId=zone_id,
        StartRecordName=fqdn,
        StartRecordType="A",
        MaxItems="1",
    )

    rrsets = response.get("ResourceRecordSets", [])
    if not rrsets:
        return None

    record = rrsets[0]
    # Check if this is actually our record
    if record.get("Name", "").rstrip(".") != fqdn.rstrip(".") or record.get("Type") != "A":
        return None

    records = record.get("ResourceRecords", [])
    return records[0]["Value"] if records else None


async def upsert_dns_record(settings: "Settings", ip: str) -> None:  # type: ignore[name-defined]
    """Update or create Route 53 A record."""
    import boto3

    client = boto3.client(
        "route53",
        region_name=settings.aws_region,
        aws_access_key_id=settings.aws_access_key_id,
        aws_secret_access_key=settings.aws_secret_access_key,
    )

    client.change_resource_record_sets(
        HostedZoneId=settings.route53_zone_id,
        ChangeBatch={
            "Changes": [
                {
                    "Action": "UPSERT",
                    "ResourceRecordSet": {
                        "Name": settings.demo_fqdn,
                        "Type": "A",
                        "TTL": settings.demo_ttl,
                        "ResourceRecords": [{"Value": ip}],
                    },
                }
            ]
        },
    )


@click.group()
def dns() -> None:
    """DNS and DDNS management commands."""
    pass


@dns.command()
@click.option("--force", "-f", is_flag=True, help="Force update even if IP unchanged")
@pass_settings
@async_command
async def update(ctx: SettingsContext, force: bool) -> None:
    """Update Route 53 DNS with current public IP.

    Checks if the public IP has changed and updates the A record
    if necessary. Use --force to update regardless of current value.
    """
    if ctx is None:
        print_error("Configuration not loaded. Run 'prodbox env validate' first.")
        raise SystemExit(1)

    settings = ctx.settings
    fqdn = settings.demo_fqdn

    print_info(f"Checking DNS for {fqdn}...")

    try:
        public_ip = await get_public_ip()
        print_info(f"Current public IP: {public_ip}")
    except Exception as e:
        print_error(f"Failed to get public IP: {e}")
        raise SystemExit(1)

    try:
        current_ip = await get_current_dns_ip(settings)
        if current_ip:
            print_info(f"Current DNS A record: {current_ip}")
        else:
            print_warning(f"No A record found for {fqdn}")
    except Exception as e:
        print_error(f"Failed to query DNS: {e}")
        raise SystemExit(1)

    if current_ip == public_ip and not force:
        print_success("DNS is already up to date.")
        return

    print_info(f"Updating DNS: {current_ip or 'none'} -> {public_ip}")

    try:
        await upsert_dns_record(settings, public_ip)
        print_success(f"DNS updated successfully: {fqdn} -> {public_ip}")
    except Exception as e:
        print_error(f"Failed to update DNS: {e}")
        raise SystemExit(1)


@dns.command()
@pass_settings
@async_command
async def check(ctx: SettingsContext) -> None:
    """Check current DNS record and public IP.

    Displays the current public IP and Route 53 A record
    without making any changes.
    """
    if ctx is None:
        print_error("Configuration not loaded. Run 'prodbox env validate' first.")
        raise SystemExit(1)

    settings = ctx.settings
    fqdn = settings.demo_fqdn

    click.echo(f"Domain: {fqdn}")
    click.echo(f"Zone ID: {settings.route53_zone_id}")
    click.echo(f"TTL: {settings.demo_ttl}s")
    click.echo()

    try:
        public_ip = await get_public_ip()
        click.echo(f"Public IP: {public_ip}")
    except Exception as e:
        print_error(f"Failed to get public IP: {e}")
        public_ip = None

    try:
        current_ip = await get_current_dns_ip(settings)
        if current_ip:
            click.echo(f"DNS A Record: {current_ip}")
            if public_ip and current_ip != public_ip:
                print_warning("DNS record does not match public IP!")
            elif public_ip:
                print_success("DNS record matches public IP.")
        else:
            print_warning(f"No A record found for {fqdn}")
    except Exception as e:
        print_error(f"Failed to query DNS: {e}")


@dns.command("ensure-timer")
@click.option(
    "--interval",
    default=5,
    type=int,
    help="Update interval in minutes (default: 5)",
)
@pass_settings
@async_command
async def ensure_timer(ctx: SettingsContext, interval: int) -> None:
    """Install systemd timer for automatic DDNS updates.

    Creates and enables a systemd timer that runs 'prodbox dns update'
    at the specified interval.
    """
    if ctx is None:
        print_error("Configuration not loaded. Run 'prodbox env validate' first.")
        raise SystemExit(1)

    service_content = f"""\
[Unit]
Description=Route 53 DDNS updater for {ctx.settings.demo_fqdn}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/prodbox dns update
Environment=AWS_ACCESS_KEY_ID={ctx.settings.aws_access_key_id}
Environment=AWS_SECRET_ACCESS_KEY={ctx.settings.aws_secret_access_key}
Environment=AWS_REGION={ctx.settings.aws_region}
Environment=ROUTE53_ZONE_ID={ctx.settings.route53_zone_id}
Environment=DEMO_FQDN={ctx.settings.demo_fqdn}
Environment=DEMO_TTL={ctx.settings.demo_ttl}
"""

    timer_content = f"""\
[Unit]
Description=Run Route 53 DDNS updater every {interval} minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec={interval}min
Persistent=true

[Install]
WantedBy=timers.target
"""

    service_path = Path("/etc/systemd/system/route53-ddns.service")
    timer_path = Path("/etc/systemd/system/route53-ddns.timer")

    print_info("Installing systemd units (requires sudo)...")

    # Write service file
    try:
        result = await run_command(
            ["sudo", "tee", str(service_path)],
            input_data=service_content.encode(),
            capture=True,
        )
        print_info(f"Created {service_path}")
    except Exception as e:
        print_error(f"Failed to create service file: {e}")
        raise SystemExit(1)

    # Write timer file
    try:
        result = await run_command(
            ["sudo", "tee", str(timer_path)],
            input_data=timer_content.encode(),
            capture=True,
        )
        print_info(f"Created {timer_path}")
    except Exception as e:
        print_error(f"Failed to create timer file: {e}")
        raise SystemExit(1)

    # Reload systemd
    try:
        await run_command(["sudo", "systemctl", "daemon-reload"], capture=True)
        print_info("Reloaded systemd daemon")
    except Exception as e:
        print_error(f"Failed to reload systemd: {e}")
        raise SystemExit(1)

    # Enable and start timer
    try:
        await run_command(
            ["sudo", "systemctl", "enable", "--now", "route53-ddns.timer"],
            capture=True,
        )
        print_success(f"Timer enabled and started (interval: {interval} minutes)")
    except Exception as e:
        print_error(f"Failed to enable timer: {e}")
        raise SystemExit(1)

    # Show status
    try:
        result = await run_command(
            ["systemctl", "status", "route53-ddns.timer", "--no-pager"],
            capture=True,
            check=False,
        )
        click.echo()
        click.echo(result.stdout)
    except Exception:
        pass
