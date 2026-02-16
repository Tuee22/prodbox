"""Kubernetes health check and utility commands."""

from __future__ import annotations

import click

from prodbox.cli.main import SettingsContext, pass_settings
from prodbox.lib.async_runner import async_command
from prodbox.lib.concurrency import gather_with_limit
from prodbox.lib.logging import print_error, print_info, print_success, print_warning
from prodbox.lib.subprocess import run_command


@click.group()
def k8s() -> None:
    """Kubernetes health and utility commands."""
    pass


@k8s.command()
@pass_settings
@async_command
async def health(ctx: SettingsContext) -> None:
    """Check health of Kubernetes cluster and components.

    Verifies connectivity and checks the status of key
    infrastructure components (MetalLB, Traefik, cert-manager).
    """
    if ctx is None:
        print_error("Configuration not loaded. Run 'prodbox env validate' first.")
        raise SystemExit(1)

    settings = ctx.settings
    kubeconfig = str(settings.kubeconfig)
    env = {"KUBECONFIG": kubeconfig}

    print_info("Checking Kubernetes cluster health...")
    click.echo()

    # Check cluster connectivity
    print_info("Cluster connectivity:")
    try:
        result = await run_command(
            ["kubectl", "cluster-info"],
            env=env,
            capture=True,
            timeout=30,
        )
        for line in result.stdout.strip().split("\n")[:2]:
            click.echo(f"  {line}")
        print_success("  Cluster is reachable")
    except Exception as e:
        print_error(f"  Cluster unreachable: {e}")
        raise SystemExit(1)

    click.echo()

    # Check nodes
    print_info("Nodes:")
    try:
        result = await run_command(
            ["kubectl", "get", "nodes", "-o", "wide", "--no-headers"],
            env=env,
            capture=True,
            timeout=30,
        )
        for line in result.stdout.strip().split("\n"):
            parts = line.split()
            if len(parts) >= 2:
                name, status = parts[0], parts[1]
                if "Ready" in status:
                    click.echo(f"  {name}: [green]Ready[/green]")
                else:
                    click.echo(f"  {name}: [red]{status}[/red]")
    except Exception as e:
        print_error(f"  Failed to get nodes: {e}")

    click.echo()

    # Check namespaces and deployments
    checks = [
        ("metallb-system", "MetalLB"),
        ("traefik-system", "Traefik"),
        ("cert-manager", "cert-manager"),
    ]

    for namespace, name in checks:
        print_info(f"{name} ({namespace}):")
        try:
            # Check if namespace exists
            result = await run_command(
                ["kubectl", "get", "namespace", namespace],
                env=env,
                capture=True,
                timeout=30,
                check=False,
            )
            if not result.success:
                print_warning(f"  Namespace not found")
                click.echo()
                continue

            # Get pods in namespace
            result = await run_command(
                ["kubectl", "get", "pods", "-n", namespace, "--no-headers"],
                env=env,
                capture=True,
                timeout=30,
            )
            pods = result.stdout.strip().split("\n") if result.stdout.strip() else []

            ready = 0
            total = len(pods)
            for pod_line in pods:
                if "Running" in pod_line or "Completed" in pod_line:
                    ready += 1

            if total == 0:
                print_warning(f"  No pods found")
            elif ready == total:
                print_success(f"  All pods ready ({ready}/{total})")
            else:
                print_warning(f"  Some pods not ready ({ready}/{total})")

        except Exception as e:
            print_error(f"  Failed to check: {e}")

        click.echo()

    # Check ingress
    print_info("Ingress LoadBalancer:")
    try:
        result = await run_command(
            [
                "kubectl",
                "get",
                "svc",
                "-n",
                "traefik-system",
                "-l",
                "app.kubernetes.io/name=traefik",
                "-o",
                "jsonpath={.items[0].status.loadBalancer.ingress[0].ip}",
            ],
            env=env,
            capture=True,
            timeout=30,
            check=False,
        )
        if result.stdout.strip():
            ip = result.stdout.strip()
            expected = settings.ingress_lb_ip
            if ip == expected:
                print_success(f"  LoadBalancer IP: {ip} (matches config)")
            else:
                print_warning(f"  LoadBalancer IP: {ip} (expected: {expected})")
        else:
            print_warning("  No LoadBalancer IP assigned")
    except Exception as e:
        print_error(f"  Failed to check LoadBalancer: {e}")

    click.echo()

    # Check ClusterIssuer
    print_info("ClusterIssuer:")
    try:
        result = await run_command(
            [
                "kubectl",
                "get",
                "clusterissuer",
                "letsencrypt-dns01",
                "-o",
                "jsonpath={.status.conditions[0].status}",
            ],
            env=env,
            capture=True,
            timeout=30,
            check=False,
        )
        if result.stdout.strip() == "True":
            print_success("  letsencrypt-dns01: Ready")
        elif result.stdout.strip():
            print_warning(f"  letsencrypt-dns01: {result.stdout.strip()}")
        else:
            print_warning("  letsencrypt-dns01: Not found")
    except Exception as e:
        print_error(f"  Failed to check ClusterIssuer: {e}")


@k8s.command()
@click.option(
    "--timeout",
    "-t",
    default=300,
    type=int,
    help="Timeout in seconds (default: 300)",
)
@click.option(
    "--namespace",
    "-n",
    multiple=True,
    default=["metallb-system", "traefik-system", "cert-manager"],
    help="Namespaces to wait for (can specify multiple)",
)
@pass_settings
@async_command
async def wait(ctx: SettingsContext, timeout: int, namespace: tuple[str, ...]) -> None:
    """Wait for deployments to be ready.

    Blocks until all deployments in the specified namespaces
    are ready or timeout is reached.
    """
    if ctx is None:
        print_error("Configuration not loaded. Run 'prodbox env validate' first.")
        raise SystemExit(1)

    settings = ctx.settings
    kubeconfig = str(settings.kubeconfig)
    env = {"KUBECONFIG": kubeconfig}

    print_info(f"Waiting for deployments (timeout: {timeout}s)...")

    async def wait_for_namespace(ns: str) -> bool:
        """Wait for all deployments in a namespace."""
        print_info(f"  Waiting for {ns}...")
        try:
            result = await run_command(
                [
                    "kubectl",
                    "wait",
                    "--for=condition=available",
                    "deployment",
                    "--all",
                    "-n",
                    ns,
                    f"--timeout={timeout}s",
                ],
                env=env,
                capture=True,
                timeout=timeout + 10,
                check=False,
            )
            if result.success:
                print_success(f"  {ns}: Ready")
                return True
            else:
                print_error(f"  {ns}: {result.stderr.strip()}")
                return False
        except Exception as e:
            print_error(f"  {ns}: {e}")
            return False

    # Wait for all namespaces concurrently
    results = await gather_with_limit(
        [wait_for_namespace(ns) for ns in namespace],
        max_concurrent=3,
    )

    click.echo()
    if all(results):
        print_success("All deployments are ready!")
    else:
        print_error("Some deployments failed to become ready")
        raise SystemExit(1)


@k8s.command()
@pass_settings
@async_command
async def logs(ctx: SettingsContext) -> None:
    """Show recent logs from infrastructure pods.

    Displays the last few log lines from key infrastructure
    components for debugging.
    """
    if ctx is None:
        print_error("Configuration not loaded. Run 'prodbox env validate' first.")
        raise SystemExit(1)

    settings = ctx.settings
    kubeconfig = str(settings.kubeconfig)
    env = {"KUBECONFIG": kubeconfig}

    namespaces = ["metallb-system", "traefik-system", "cert-manager"]

    for namespace in namespaces:
        print_info(f"\n=== {namespace} ===")
        try:
            result = await run_command(
                [
                    "kubectl",
                    "logs",
                    "-n",
                    namespace,
                    "--all-containers=true",
                    "--tail=10",
                    "-l",
                    "app.kubernetes.io/name",
                ],
                env=env,
                capture=True,
                timeout=30,
                check=False,
            )
            if result.stdout.strip():
                click.echo(result.stdout)
            else:
                click.echo("  No logs found")
        except Exception as e:
            print_error(f"  Failed to get logs: {e}")
