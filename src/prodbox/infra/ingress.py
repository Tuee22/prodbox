"""Traefik ingress controller infrastructure module."""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

import pulumi
import pulumi_kubernetes as k8s

if TYPE_CHECKING:
    from prodbox.infra.metallb import MetalLBResources
    from prodbox.settings import Settings

# Pinned chart version for reproducibility
TRAEFIK_CHART_VERSION = "32.0.0"
TRAEFIK_REPO = "https://traefik.github.io/charts"


@dataclass
class IngressResources:
    """Container for Ingress resources."""

    namespace: k8s.core.v1.Namespace
    release: k8s.helm.v3.Release


def deploy_ingress(
    settings: Settings,
    k8s_provider: k8s.Provider,
    metallb_resources: MetalLBResources,
) -> IngressResources:
    """Deploy Traefik ingress controller.

    Traefik handles HTTP/HTTPS traffic routing into the cluster.
    It gets a LoadBalancer IP from MetalLB.

    Args:
        settings: Application settings with ingress configuration
        k8s_provider: Kubernetes provider
        metallb_resources: MetalLB resources (for dependency ordering)

    Returns:
        IngressResources containing all created resources
    """
    # Create namespace
    namespace = k8s.core.v1.Namespace(
        "traefik-namespace",
        metadata=k8s.meta.v1.ObjectMetaArgs(
            name="traefik-system",
        ),
        opts=pulumi.ResourceOptions(provider=k8s_provider),
    )

    # Deploy Traefik Helm chart
    release = k8s.helm.v3.Release(
        "traefik",
        chart="traefik",
        version=TRAEFIK_CHART_VERSION,
        repository_opts=k8s.helm.v3.RepositoryOptsArgs(
            repo=TRAEFIK_REPO,
        ),
        namespace=namespace.metadata.name,  # type: ignore[attr-defined, misc]  # Pulumi resource .name attr
        values={
            # Service configuration
            "service": {
                "type": "LoadBalancer",
                "spec": {
                    # Request specific IP from MetalLB
                    "loadBalancerIP": settings.ingress_lb_ip,
                },
            },
            # Expose HTTP and HTTPS
            "ports": {
                "web": {
                    "expose": {
                        "default": True,
                    },
                },
                "websecure": {
                    "expose": {
                        "default": True,
                    },
                },
            },
            # Enable access logs for debugging
            "logs": {
                "access": {
                    "enabled": True,
                },
            },
            # Prometheus metrics (optional)
            "metrics": {
                "prometheus": {
                    "entryPoint": "metrics",
                },
            },
        },
        skip_await=False,
        opts=pulumi.ResourceOptions(
            provider=k8s_provider,
            depends_on=[
                namespace,
                metallb_resources.l2_advertisement,
            ],
        ),
    )

    # Export ingress info
    pulumi.export("traefik_chart_version", TRAEFIK_CHART_VERSION)
    pulumi.export("traefik_lb_ip", settings.ingress_lb_ip)

    return IngressResources(
        namespace=namespace,
        release=release,
    )
