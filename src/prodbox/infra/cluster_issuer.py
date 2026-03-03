"""ClusterIssuer infrastructure module for Let's Encrypt DNS-01."""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

import pulumi
import pulumi_kubernetes as k8s

if TYPE_CHECKING:
    from prodbox.infra.cert_manager import CertManagerResources
    from prodbox.settings import Settings


@dataclass
class ClusterIssuerResources:
    """Container for ClusterIssuer resources."""

    aws_secret: k8s.core.v1.Secret
    cluster_issuer: k8s.apiextensions.CustomResource


def deploy_cluster_issuer(
    settings: Settings,
    k8s_provider: k8s.Provider,
    cert_manager_resources: CertManagerResources,
) -> ClusterIssuerResources:
    """Deploy ClusterIssuer for Let's Encrypt DNS-01 validation.

    Creates:
    - A Secret containing AWS credentials for Route 53 access
    - A ClusterIssuer configured for DNS-01 validation

    Args:
        settings: Application settings with AWS and ACME configuration
        k8s_provider: Kubernetes provider
        cert_manager_resources: cert-manager resources (for dependency)

    Returns:
        ClusterIssuerResources containing all created resources
    """
    # Create secret with AWS credentials for Route 53 access
    # The secret must be in the cert-manager namespace
    aws_secret = k8s.core.v1.Secret(
        "route53-credentials",
        metadata=k8s.meta.v1.ObjectMetaArgs(
            name="route53-credentials",
            namespace="cert-manager",
        ),
        string_data={
            "secret-access-key": settings.aws_secret_access_key,
        },
        opts=pulumi.ResourceOptions(
            provider=k8s_provider,
            depends_on=[cert_manager_resources.namespace],
        ),
    )

    # Create ClusterIssuer for Let's Encrypt with DNS-01 validation
    cluster_issuer = k8s.apiextensions.CustomResource(
        "letsencrypt-dns01",
        api_version="cert-manager.io/v1",
        kind="ClusterIssuer",
        metadata=k8s.meta.v1.ObjectMetaArgs(
            name="letsencrypt-dns01",
        ),
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
                # DNS-01 solver configuration
                "solvers": [
                    {
                        "dns01": {
                            "route53": {
                                "region": settings.aws_region,
                                "hostedZoneID": settings.route53_zone_id,
                                # AWS credentials
                                "accessKeyID": settings.aws_access_key_id,
                                "secretAccessKeySecretRef": {
                                    "name": "route53-credentials",
                                    "key": "secret-access-key",
                                },
                            },
                        },
                    },
                ],
            },
        },
        opts=pulumi.ResourceOptions(
            provider=k8s_provider,
            depends_on=[
                cert_manager_resources.release,
                aws_secret,
            ],
        ),
    )

    # Export ClusterIssuer info
    pulumi.export("cluster_issuer_name", "letsencrypt-dns01")
    pulumi.export("acme_server", settings.acme_server)

    return ClusterIssuerResources(
        aws_secret=aws_secret,
        cluster_issuer=cluster_issuer,
    )
