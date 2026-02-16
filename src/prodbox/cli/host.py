"""Host prerequisite management commands."""

from __future__ import annotations

import shutil
from dataclasses import dataclass

import click

from prodbox.lib.async_runner import async_command
from prodbox.lib.logging import print_error, print_info, print_success, print_warning
from prodbox.lib.subprocess import run_command


@dataclass
class Tool:
    """A required CLI tool."""

    name: str
    check_cmd: list[str]
    version_flag: str = "--version"
    install_url: str = ""


REQUIRED_TOOLS = [
    Tool(
        name="kubectl",
        check_cmd=["kubectl", "version", "--client", "--short"],
        install_url="https://kubernetes.io/docs/tasks/tools/",
    ),
    Tool(
        name="helm",
        check_cmd=["helm", "version", "--short"],
        install_url="https://helm.sh/docs/intro/install/",
    ),
    Tool(
        name="pulumi",
        check_cmd=["pulumi", "version"],
        install_url="https://www.pulumi.com/docs/install/",
    ),
]


@click.group()
def host() -> None:
    """Host prerequisite management commands."""
    pass


@host.command("ensure-tools")
@async_command
async def ensure_tools() -> None:
    """Check that required CLI tools are installed.

    Verifies that kubectl, helm, and pulumi are available
    in the system PATH.
    """
    print_info("Checking required tools...")
    click.echo()

    all_ok = True

    for tool in REQUIRED_TOOLS:
        # Check if command exists
        path = shutil.which(tool.name)
        if not path:
            print_error(f"{tool.name}: NOT FOUND")
            if tool.install_url:
                click.echo(f"  Install: {tool.install_url}")
            all_ok = False
            continue

        # Get version
        try:
            result = await run_command(
                tool.check_cmd,
                capture=True,
                timeout=10,
                check=False,
            )
            version = result.stdout.strip().split("\n")[0]
            print_success(f"{tool.name}: {version}")
            click.echo(f"  Path: {path}")
        except Exception as e:
            print_warning(f"{tool.name}: Found but version check failed")
            click.echo(f"  Path: {path}")
            click.echo(f"  Error: {e}")

    click.echo()

    if all_ok:
        print_success("All required tools are installed!")
    else:
        print_error("Some required tools are missing.")
        raise SystemExit(1)


@host.command("check-ports")
@async_command
async def check_ports() -> None:
    """Check if ports 80/443 are in use.

    Verifies that no other services are binding to ports
    80 and 443, which are required for ingress.
    """
    print_info("Checking port availability...")
    click.echo()

    ports = [80, 443]
    conflicts = []

    for port in ports:
        try:
            result = await run_command(
                ["ss", "-tlnp", f"sport = :{port}"],
                capture=True,
                timeout=10,
                check=False,
            )
            if result.stdout.strip() and "LISTEN" in result.stdout:
                lines = result.stdout.strip().split("\n")
                for line in lines[1:]:  # Skip header
                    print_warning(f"Port {port} is in use:")
                    click.echo(f"  {line.strip()}")
                    conflicts.append(port)
            else:
                print_success(f"Port {port}: Available")
        except Exception as e:
            print_warning(f"Port {port}: Could not check ({e})")

    click.echo()

    if conflicts:
        print_warning(
            "Some ports are in use. This may conflict with ingress."
        )
        print_info(
            "MetalLB will assign a separate IP for ingress, "
            "so this may not be an issue."
        )
    else:
        print_success("All required ports are available!")


@host.command("info")
@async_command
async def info() -> None:
    """Display host system information.

    Shows OS, kernel, and resource information useful
    for troubleshooting.
    """
    print_info("Host Information")
    click.echo()

    # OS info
    try:
        result = await run_command(
            ["uname", "-a"],
            capture=True,
            timeout=10,
        )
        click.echo(f"System: {result.stdout.strip()}")
    except Exception:
        pass

    # Distribution info
    try:
        result = await run_command(
            ["cat", "/etc/os-release"],
            capture=True,
            timeout=10,
            check=False,
        )
        if result.success:
            for line in result.stdout.split("\n"):
                if line.startswith("PRETTY_NAME="):
                    name = line.split("=", 1)[1].strip('"')
                    click.echo(f"Distribution: {name}")
                    break
    except Exception:
        pass

    click.echo()

    # Memory
    try:
        result = await run_command(
            ["free", "-h"],
            capture=True,
            timeout=10,
            check=False,
        )
        if result.success:
            print_info("Memory:")
            click.echo(result.stdout)
    except Exception:
        pass

    # Disk
    try:
        result = await run_command(
            ["df", "-h", "/"],
            capture=True,
            timeout=10,
            check=False,
        )
        if result.success:
            print_info("Disk:")
            click.echo(result.stdout)
    except Exception:
        pass


@host.command("firewall")
@async_command
async def firewall() -> None:
    """Check and display firewall status.

    Shows current firewall rules relevant to Kubernetes
    and ingress traffic.
    """
    print_info("Firewall Status")
    click.echo()

    # Check ufw
    try:
        result = await run_command(
            ["ufw", "status"],
            capture=True,
            timeout=10,
            check=False,
        )
        if result.success:
            print_info("UFW Status:")
            click.echo(result.stdout)
        elif "not found" in result.stderr.lower():
            click.echo("UFW: Not installed")
    except Exception as e:
        click.echo(f"UFW: Could not check ({e})")

    click.echo()

    # Check iptables (basic)
    try:
        result = await run_command(
            ["iptables", "-L", "-n", "--line-numbers"],
            capture=True,
            timeout=10,
            check=False,
        )
        if result.success:
            print_info("iptables INPUT chain:")
            # Just show first few rules
            lines = result.stdout.split("\n")[:15]
            click.echo("\n".join(lines))
        elif "permission denied" in result.stderr.lower():
            print_warning("iptables: Requires sudo to view")
    except Exception as e:
        click.echo(f"iptables: Could not check ({e})")
