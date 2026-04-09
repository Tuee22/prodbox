"""ClusterIssuer infrastructure module for Let's Encrypt DNS-01 via Route 53."""

from __future__ import annotations

from collections.abc import Sequence
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
    depends_on: Sequence[object] = (),
) -> ClusterIssuerResources:
    """Deploy ClusterIssuer for Let's Encrypt DNS-01 validation via Route 53.

    Uses DNS-01 instead of HTTP-01 because the ISP blocks ports 80/443.
    cert-manager creates Route 53 TXT records to prove domain ownership.

    Args:
        settings: Application settings with ACME and AWS configuration
        k8s_provider: Kubernetes provider
        prodbox_id: Canonical prodbox-id annotation value
        depends_on: Resources that must exist before the issuer

    Returns:
        ClusterIssuerResources containing all created resources
    """
    # Create a Secret with AWS credentials for cert-manager to use for DNS-01
    aws_secret = k8s.core.v1.Secret(
        "cert-manager-route53-credentials",
        metadata=object_meta(
            name="route53-credentials",
            namespace="cert-manager",
            prodbox_id=prodbox_id,
        ),
        string_data={
            "access-key-id": settings.aws_access_key_id,
            "secret-access-key": settings.aws_secret_access_key,
        },
        opts=pulumi.ResourceOptions(
            provider=k8s_provider,
            depends_on=list(depends_on),
        ),
    )

    cluster_issuer = k8s.apiextensions.CustomResource(
        "letsencrypt-http01",
        api_version="cert-manager.io/v1",
        kind="ClusterIssuer",
        metadata=object_meta(name="letsencrypt-http01", prodbox_id=prodbox_id),
        spec={
            "acme": {
                "server": settings.acme_server,
                "email": settings.acme_email,
                "privateKeySecretRef": {
                    "name": "letsencrypt-account-key",
                },
                "solvers": [
                    {
                        "dns01": {
                            "route53": {
                                "region": settings.aws_region,
                                "hostedZoneID": settings.route53_zone_id,
                                "accessKeyIDSecretRef": {
                                    "name": "route53-credentials",
                                    "key": "access-key-id",
                                },
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
            depends_on=[aws_secret, *depends_on],
        ),
    )

    # Export ClusterIssuer info
    pulumi.export("cluster_issuer_name", "letsencrypt-http01")
    pulumi.export("acme_server", settings.acme_server)

    return ClusterIssuerResources(
        cluster_issuer=cluster_issuer,
    )
