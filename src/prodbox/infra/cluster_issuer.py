"""ClusterIssuer infrastructure module for Let's Encrypt DNS-01."""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

import pulumi
import pulumi_kubernetes as k8s

from prodbox.infra.metadata import object_meta
from prodbox.lib.aws_auth import assert_ambient_aws_auth_only

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
    """Deploy ClusterIssuer for Let's Encrypt DNS-01 validation.

    Creates:
    - A ClusterIssuer configured for DNS-01 validation

    Args:
        settings: Application settings with Route 53 and ACME configuration
        k8s_provider: Kubernetes provider
        prodbox_id: Canonical prodbox-id annotation value

    Returns:
        ClusterIssuerResources containing all created resources
    """
    assert_ambient_aws_auth_only()

    # Create ClusterIssuer for Let's Encrypt with DNS-01 validation
    # cert-manager must receive ambient AWS auth from external cluster runtime setup.
    cluster_issuer = k8s.apiextensions.CustomResource(
        "letsencrypt-dns01",
        api_version="cert-manager.io/v1",
        kind="ClusterIssuer",
        metadata=object_meta(name="letsencrypt-dns01", prodbox_id=prodbox_id),
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
                # Credentials are provided via a K8s Secret (bare-metal cluster has no IMDS).
                "solvers": [
                    {
                        "dns01": {
                            "route53": {
                                "region": settings.aws_region,
                                "hostedZoneID": settings.route53_zone_id,
                                "accessKeyID": "AKIAEXAMPLEKEYID0000",
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
        ),
    )

    # Export ClusterIssuer info
    pulumi.export("cluster_issuer_name", "letsencrypt-dns01")
    pulumi.export("acme_server", settings.acme_server)

    return ClusterIssuerResources(
        cluster_issuer=cluster_issuer,
    )
