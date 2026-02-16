"""RKE2 management commands."""

from __future__ import annotations

from pathlib import Path

import click

from prodbox.lib.async_runner import async_command
from prodbox.lib.logging import print_error, print_info, print_success, print_warning
from prodbox.lib.subprocess import run_command


RKE2_CONFIG_PATH = Path("/etc/rancher/rke2")
RKE2_DATA_PATH = Path("/var/lib/rancher/rke2")
RKE2_BIN = "/usr/local/bin/rke2"
RKE2_SERVICE = "rke2-server.service"


@click.group()
def rke2() -> None:
    """RKE2 Kubernetes management commands."""
    pass


@rke2.command()
@async_command
async def status() -> None:
    """Check RKE2 installation and service status.

    Shows whether RKE2 is installed, running, and provides
    basic cluster health information.
    """
    print_info("RKE2 Status")
    click.echo()

    # Check if RKE2 is installed
    rke2_installed = Path(RKE2_BIN).exists()
    if rke2_installed:
        print_success(f"RKE2 binary: {RKE2_BIN}")
        try:
            result = await run_command(
                [RKE2_BIN, "--version"],
                capture=True,
                timeout=10,
            )
            click.echo(f"  Version: {result.stdout.strip()}")
        except Exception as e:
            print_warning(f"  Could not get version: {e}")
    else:
        print_error("RKE2 binary: Not found")

    click.echo()

    # Check service status
    print_info("Service Status:")
    try:
        result = await run_command(
            ["systemctl", "is-active", RKE2_SERVICE],
            capture=True,
            timeout=10,
            check=False,
        )
        status = result.stdout.strip()
        if status == "active":
            print_success(f"  {RKE2_SERVICE}: Running")
        elif status == "inactive":
            print_warning(f"  {RKE2_SERVICE}: Stopped")
        else:
            print_warning(f"  {RKE2_SERVICE}: {status}")
    except Exception as e:
        print_error(f"  Could not check service: {e}")

    # Check if enabled
    try:
        result = await run_command(
            ["systemctl", "is-enabled", RKE2_SERVICE],
            capture=True,
            timeout=10,
            check=False,
        )
        enabled = result.stdout.strip()
        click.echo(f"  Enabled: {enabled}")
    except Exception:
        pass

    click.echo()

    # Check config
    config_file = RKE2_CONFIG_PATH / "config.yaml"
    print_info("Configuration:")
    if config_file.exists():
        print_success(f"  Config file: {config_file}")
    else:
        print_warning(f"  Config file: Not found ({config_file})")

    kubeconfig = RKE2_CONFIG_PATH / "rke2.yaml"
    if kubeconfig.exists():
        print_success(f"  Kubeconfig: {kubeconfig}")
    else:
        print_warning(f"  Kubeconfig: Not found ({kubeconfig})")

    click.echo()

    # Check data directory
    print_info("Data Directory:")
    if RKE2_DATA_PATH.exists():
        print_success(f"  Data path: {RKE2_DATA_PATH}")
    else:
        print_warning(f"  Data path: Not found ({RKE2_DATA_PATH})")


@rke2.command()
@async_command
async def start() -> None:
    """Start RKE2 server service.

    Starts the RKE2 server systemd service if not running.
    """
    print_info("Starting RKE2 server...")

    # Check current status
    try:
        result = await run_command(
            ["systemctl", "is-active", RKE2_SERVICE],
            capture=True,
            timeout=10,
            check=False,
        )
        if result.stdout.strip() == "active":
            print_info("RKE2 server is already running.")
            return
    except Exception:
        pass

    # Start service
    try:
        await run_command(
            ["sudo", "systemctl", "start", RKE2_SERVICE],
            capture=True,
            timeout=60,
        )
        print_success("RKE2 server started successfully!")
    except Exception as e:
        print_error(f"Failed to start RKE2 server: {e}")
        raise SystemExit(1)

    # Wait a moment and check status
    import asyncio

    await asyncio.sleep(5)

    try:
        result = await run_command(
            ["systemctl", "is-active", RKE2_SERVICE],
            capture=True,
            timeout=10,
            check=False,
        )
        if result.stdout.strip() == "active":
            print_success("RKE2 server is running.")
        else:
            print_warning(f"RKE2 status: {result.stdout.strip()}")
    except Exception:
        pass


@rke2.command()
@async_command
async def stop() -> None:
    """Stop RKE2 server service.

    Stops the RKE2 server systemd service.
    """
    print_info("Stopping RKE2 server...")

    # Check current status
    try:
        result = await run_command(
            ["systemctl", "is-active", RKE2_SERVICE],
            capture=True,
            timeout=10,
            check=False,
        )
        if result.stdout.strip() != "active":
            print_info("RKE2 server is not running.")
            return
    except Exception:
        pass

    # Stop service
    try:
        await run_command(
            ["sudo", "systemctl", "stop", RKE2_SERVICE],
            capture=True,
            timeout=60,
        )
        print_success("RKE2 server stopped successfully!")
    except Exception as e:
        print_error(f"Failed to stop RKE2 server: {e}")
        raise SystemExit(1)


@rke2.command()
@async_command
async def restart() -> None:
    """Restart RKE2 server service.

    Restarts the RKE2 server systemd service.
    """
    print_info("Restarting RKE2 server...")

    try:
        await run_command(
            ["sudo", "systemctl", "restart", RKE2_SERVICE],
            capture=True,
            timeout=120,
        )
        print_success("RKE2 server restarted successfully!")
    except Exception as e:
        print_error(f"Failed to restart RKE2 server: {e}")
        raise SystemExit(1)

    # Wait and check status
    import asyncio

    await asyncio.sleep(5)

    try:
        result = await run_command(
            ["systemctl", "is-active", RKE2_SERVICE],
            capture=True,
            timeout=10,
            check=False,
        )
        if result.stdout.strip() == "active":
            print_success("RKE2 server is running.")
        else:
            print_warning(f"RKE2 status: {result.stdout.strip()}")
    except Exception:
        pass


@rke2.command()
@async_command
async def ensure() -> None:
    """Ensure RKE2 is installed and configured.

    Checks if RKE2 is installed. If not, provides instructions
    for installation. Does not automatically install RKE2.
    """
    print_info("Checking RKE2 installation...")
    click.echo()

    # Check if RKE2 is installed
    rke2_installed = Path(RKE2_BIN).exists()

    if rke2_installed:
        print_success("RKE2 is installed.")

        # Check if service exists and is enabled
        try:
            result = await run_command(
                ["systemctl", "is-enabled", RKE2_SERVICE],
                capture=True,
                timeout=10,
                check=False,
            )
            if result.stdout.strip() == "enabled":
                print_success("RKE2 service is enabled.")
            else:
                print_warning("RKE2 service is not enabled.")
                click.echo("  Run: sudo systemctl enable rke2-server.service")
        except Exception:
            pass

        # Check if kubeconfig is accessible
        kubeconfig = RKE2_CONFIG_PATH / "rke2.yaml"
        if kubeconfig.exists():
            print_success("RKE2 kubeconfig exists.")

            # Check if it's readable
            try:
                kubeconfig.read_text()
                print_success("Kubeconfig is readable.")
            except PermissionError:
                print_warning("Kubeconfig exists but is not readable.")
                click.echo("  You may need to copy it to ~/.kube/config:")
                click.echo(f"    sudo cp {kubeconfig} ~/.kube/config")
                click.echo("    sudo chown $USER:$USER ~/.kube/config")
        else:
            print_warning("RKE2 kubeconfig not found.")
            click.echo("  RKE2 may not have been started yet.")

    else:
        print_error("RKE2 is not installed.")
        click.echo()
        click.echo("To install RKE2, run:")
        click.echo("  curl -sfL https://get.rke2.io | sudo sh -")
        click.echo()
        click.echo("Then enable and start the service:")
        click.echo("  sudo systemctl enable rke2-server.service")
        click.echo("  sudo systemctl start rke2-server.service")
        click.echo()
        click.echo("After starting, copy the kubeconfig:")
        click.echo("  sudo mkdir -p ~/.kube")
        click.echo("  sudo cp /etc/rancher/rke2/rke2.yaml ~/.kube/config")
        click.echo("  sudo chown $USER:$USER ~/.kube/config")
        raise SystemExit(1)


@rke2.command()
@async_command
async def logs() -> None:
    """Show recent RKE2 server logs.

    Displays the last 50 lines of the RKE2 server journal logs.
    """
    print_info("RKE2 Server Logs (last 50 lines)")
    click.echo()

    try:
        result = await run_command(
            ["journalctl", "-u", RKE2_SERVICE, "-n", "50", "--no-pager"],
            capture=True,
            timeout=30,
            check=False,
        )
        if result.stdout.strip():
            click.echo(result.stdout)
        else:
            print_warning("No logs found")
    except Exception as e:
        print_error(f"Failed to get logs: {e}")
        raise SystemExit(1)
