"""MetalLB infrastructure module."""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

import pulumi
import pulumi_kubernetes as k8s

if TYPE_CHECKING:
    from prodbox.settings import Settings

# Pinned chart version for reproducibility
METALLB_CHART_VERSION = "0.14.9"
METALLB_REPO = "https://metallb.github.io/metallb"


@dataclass
class MetalLBResources:
    """Container for MetalLB resources."""

    namespace: k8s.core.v1.Namespace
    release: k8s.helm.v3.Release
    ip_pool: k8s.apiextensions.CustomResource
    l2_advertisement: k8s.apiextensions.CustomResource


def deploy_metallb(
    settings: Settings,
    k8s_provider: k8s.Provider,
) -> MetalLBResources:
    """Deploy MetalLB for LoadBalancer IP assignment.

    MetalLB provides LoadBalancer service functionality for bare-metal
    Kubernetes clusters using Layer 2 mode (ARP).

    Args:
        settings: Application settings with MetalLB pool configuration
        k8s_provider: Kubernetes provider

    Returns:
        MetalLBResources containing all created resources
    """
    # Create namespace
    namespace = k8s.core.v1.Namespace(
        "metallb-namespace",
        metadata=k8s.meta.v1.ObjectMetaArgs(
            name="metallb-system",
        ),
        opts=pulumi.ResourceOptions(provider=k8s_provider),
    )

    # Deploy MetalLB Helm chart
    release = k8s.helm.v3.Release(
        "metallb",
        chart="metallb",
        version=METALLB_CHART_VERSION,
        repository_opts=k8s.helm.v3.RepositoryOptsArgs(
            repo=METALLB_REPO,
        ),
        namespace=namespace.metadata.name,
        # Wait for the release to be deployed before continuing
        # This ensures CRDs are available for the next resources
        skip_await=False,
        opts=pulumi.ResourceOptions(
            provider=k8s_provider,
            depends_on=[namespace],
        ),
    )

    # Create IPAddressPool
    # This defines the range of IPs MetalLB can assign
    ip_pool = k8s.apiextensions.CustomResource(
        "metallb-ip-pool",
        api_version="metallb.io/v1beta1",
        kind="IPAddressPool",
        metadata=k8s.meta.v1.ObjectMetaArgs(
            name="default-pool",
            namespace="metallb-system",
        ),
        spec={
            "addresses": [settings.metallb_pool],
        },
        opts=pulumi.ResourceOptions(
            provider=k8s_provider,
            depends_on=[release],
        ),
    )

    # Create L2Advertisement
    # This advertises the IPs via ARP on the local network
    l2_advertisement = k8s.apiextensions.CustomResource(
        "metallb-l2-advertisement",
        api_version="metallb.io/v1beta1",
        kind="L2Advertisement",
        metadata=k8s.meta.v1.ObjectMetaArgs(
            name="default-advertisement",
            namespace="metallb-system",
        ),
        spec={
            "ipAddressPools": ["default-pool"],
        },
        opts=pulumi.ResourceOptions(
            provider=k8s_provider,
            depends_on=[ip_pool],
        ),
    )

    # Export MetalLB info
    pulumi.export("metallb_chart_version", METALLB_CHART_VERSION)
    pulumi.export("metallb_ip_pool", settings.metallb_pool)

    return MetalLBResources(
        namespace=namespace,
        release=release,
        ip_pool=ip_pool,
        l2_advertisement=l2_advertisement,
    )
