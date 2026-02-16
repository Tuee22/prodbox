"""Pulumi program entry point for prodbox infrastructure.

This module orchestrates the deployment of all infrastructure components
with proper dependency ordering:

1. DNS Record (Route 53) - can be created independently
2. MetalLB - LoadBalancer IP assignment
3. Ingress (Traefik) - requires MetalLB
4. cert-manager - can be created independently
5. ClusterIssuer - requires cert-manager
"""

from __future__ import annotations

import pulumi

from prodbox.settings import Settings
from prodbox.infra.providers import create_k8s_provider, create_aws_provider
from prodbox.infra.metallb import deploy_metallb
from prodbox.infra.ingress import deploy_ingress
from prodbox.infra.cert_manager import deploy_cert_manager
from prodbox.infra.cluster_issuer import deploy_cluster_issuer
from prodbox.infra.dns import deploy_dns


def main() -> None:
    """Main Pulumi program."""
    # Load settings from environment
    settings = Settings()

    # Create providers
    k8s_provider = create_k8s_provider(settings)
    aws_provider = create_aws_provider(settings)

    # Phase 1: DNS Record (independent)
    # Pulumi owns existence, DDNS timer updates the IP value
    dns_resources = deploy_dns(settings, aws_provider)

    # Phase 2: MetalLB (networking layer)
    # Provides LoadBalancer IPs for services
    metallb_resources = deploy_metallb(settings, k8s_provider)

    # Phase 3: Ingress Controller (requires MetalLB)
    # Traefik handles HTTP/HTTPS traffic routing
    ingress_resources = deploy_ingress(
        settings,
        k8s_provider,
        metallb_resources,
    )

    # Phase 4: cert-manager (TLS layer - independent of ingress)
    # Manages TLS certificates
    cert_manager_resources = deploy_cert_manager(settings, k8s_provider)

    # Phase 5: ClusterIssuer (requires cert-manager)
    # Let's Encrypt issuer with DNS-01 validation
    cluster_issuer_resources = deploy_cluster_issuer(
        settings,
        k8s_provider,
        cert_manager_resources,
    )

    # Summary exports
    pulumi.export("summary", {
        "fqdn": settings.demo_fqdn,
        "ingress_ip": settings.ingress_lb_ip,
        "metallb_pool": settings.metallb_pool,
        "cluster_issuer": "letsencrypt-dns01",
    })


# Run the main function
main()
