"""ClusterIssuer infrastructure module for Let's Encrypt HTTP-01."""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

import pulumi
import pulumi_kubernetes as k8s

from prodbox.infra.metadata import object_meta

if TYPE_CHECKING:
    from prodbox.settings import Settings


@dataclass(frozen=True)
class ClusterIssuerResources:
    """Container for ClusterIssuer resources."""

    cluster_issuer: k8s.apiextensions.CustomResource


def deploy_cluster_issuer(
    settings: Settings,
    k8s_provider: k8s.Provider,
    *,
    prodbox_id: str,
) -> ClusterIssuerResources:
    """Deploy ClusterIssuer for Let's Encrypt HTTP-01 validation.

    Creates:
    - A ClusterIssuer configured for HTTP-01 validation through Traefik

    Args:
        settings: Application settings with ACME configuration
        k8s_provider: Kubernetes provider
        prodbox_id: Canonical prodbox-id annotation value

    Returns:
        ClusterIssuerResources containing all created resources
    """
    cluster_issuer = k8s.apiextensions.CustomResource(
        "letsencrypt-http01",
        api_version="cert-manager.io/v1",
        kind="ClusterIssuer",
        metadata=object_meta(name="letsencrypt-http01", prodbox_id=prodbox_id),
        spec={
            "acme": {
                # ACME server URL (production or staging)
                "server": settings.acme_server,
                # Email for Let's Encrypt registration
                "email": settings.acme_email,
                # Secret to store the ACME account private key
                "privateKeySecretRef": {
                    "name": "letsencrypt-account-key",
                },
                # HTTP-01 solver configuration
                "solvers": [
                    {
                        "http01": {
                            "ingress": {
                                "class": "traefik",
                            },
                        },
                    },
                ],
            },
        },
        opts=pulumi.ResourceOptions(provider=k8s_provider),
    )

    # Export ClusterIssuer info
    pulumi.export("cluster_issuer_name", "letsencrypt-http01")
    pulumi.export("acme_server", settings.acme_server)

    return ClusterIssuerResources(
        cluster_issuer=cluster_issuer,
    )
