"""Pulumi program entry point for prodbox infrastructure.

This module orchestrates the deployment of all infrastructure components
with proper dependency ordering:

1. DNS Record (Route 53) - can be created independently
2. MetalLB - LoadBalancer IP assignment
3. Ingress (Traefik) - requires MetalLB
4. cert-manager - can be created independently
5. ClusterIssuer - requires cert-manager and ingress
"""

from __future__ import annotations

import pulumi

from prodbox.infra.cert_manager import deploy_cert_manager
from prodbox.infra.cluster_issuer import deploy_cluster_issuer
from prodbox.infra.dns import deploy_dns
from prodbox.infra.ingress import deploy_ingress
from prodbox.infra.metadata import resolve_prodbox_id
from prodbox.infra.metallb import deploy_metallb
from prodbox.infra.providers import create_aws_provider, create_k8s_provider
from prodbox.settings import Settings, discover_lan_addressing


def main() -> None:
    """Main Pulumi program."""
    # Load settings from environment
    settings = Settings()
    prodbox_id = resolve_prodbox_id()
    lan = discover_lan_addressing()

    # Create providers
    k8s_provider = create_k8s_provider(settings)

    # Phase 1: Optional DNS bootstrap
    # Pulumi owns record existence when enabled; gateway DNS writes update the IP value.
    if settings.pulumi_enable_dns_bootstrap:
        aws_provider = create_aws_provider(settings)
        _dns_resources = deploy_dns(settings, aws_provider)
    else:
        pulumi.export("dns_bootstrap", "disabled")

    # Phase 2: MetalLB (networking layer)
    # Provides LoadBalancer IPs for services
    metallb_resources = deploy_metallb(settings, k8s_provider, prodbox_id=prodbox_id)

    # Phase 3: Ingress Controller (requires MetalLB)
    # Traefik handles HTTP/HTTPS traffic routing
    _ingress_resources = deploy_ingress(
        settings,
        k8s_provider,
        metallb_resources,
        prodbox_id=prodbox_id,
    )

    # Phase 4: cert-manager (TLS controller bootstrap)
    cert_manager_resources = deploy_cert_manager(
        settings,
        k8s_provider,
        prodbox_id=prodbox_id,
    )

    # Phase 5: ClusterIssuer (cert-manager CRDs already present)
    # Let's Encrypt issuer with HTTP-01 validation through Traefik
    _cluster_issuer_resources = deploy_cluster_issuer(
        settings,
        k8s_provider,
        prodbox_id=prodbox_id,
        depends_on=(cert_manager_resources.release, _ingress_resources.release),
    )

    # Summary exports
    pulumi.export(
        "summary",
        {
            "fqdn": settings.demo_fqdn,
            "ingress_ip": lan.ingress_lb_ip,
            "metallb_pool": lan.metallb_pool,
            "cluster_issuer": "letsencrypt-http01",
            "dns_bootstrap_enabled": settings.pulumi_enable_dns_bootstrap,
            "prodbox_id": prodbox_id,
        },
    )


# Run the main function
main()
