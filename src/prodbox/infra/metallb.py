"""MetalLB infrastructure module."""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

import pulumi
import pulumi_kubernetes as k8s

from prodbox.infra.metadata import chart_values_with_prodbox, object_meta

if TYPE_CHECKING:
    from prodbox.settings import Settings

# Pinned chart version for reproducibility
METALLB_CHART_VERSION = "0.14.9"
METALLB_REPO = "https://metallb.github.io/metallb"


@dataclass(frozen=True)
class MetalLBResources:
    """Container for MetalLB resources."""

    namespace: k8s.core.v1.Namespace
    release: k8s.helm.v3.Release
    ip_pool: k8s.apiextensions.CustomResource
    l2_advertisement: k8s.apiextensions.CustomResource


def deploy_metallb(
    settings: Settings,
    k8s_provider: k8s.Provider,
    *,
    prodbox_id: str,
) -> MetalLBResources:
    """Deploy MetalLB for LoadBalancer IP assignment.

    MetalLB provides LoadBalancer service functionality for bare-metal
    Kubernetes clusters using Layer 2 mode (ARP).

    Args:
        settings: Application settings with MetalLB pool configuration
        k8s_provider: Kubernetes provider
        prodbox_id: Canonical prodbox-id annotation value

    Returns:
        MetalLBResources containing all created resources
    """
    # Create namespace
    namespace = k8s.core.v1.Namespace(
        "metallb-namespace",
        metadata=object_meta(name="metallb-system", prodbox_id=prodbox_id),
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
        namespace=namespace.metadata.name,  # type: ignore[attr-defined, misc]  # Pulumi resource .name attr
        values=chart_values_with_prodbox(values={}, prodbox_id=prodbox_id),
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
        metadata=object_meta(
            name="default-pool",
            namespace="metallb-system",
            prodbox_id=prodbox_id,
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
        metadata=object_meta(
            name="default-advertisement",
            namespace="metallb-system",
            prodbox_id=prodbox_id,
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
