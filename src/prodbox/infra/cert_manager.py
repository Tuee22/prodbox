"""cert-manager infrastructure module."""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

import pulumi
import pulumi_kubernetes as k8s

if TYPE_CHECKING:
    from prodbox.settings import Settings

# Pinned chart version for reproducibility
CERT_MANAGER_CHART_VERSION = "v1.16.2"
CERT_MANAGER_REPO = "https://charts.jetstack.io"


@dataclass
class CertManagerResources:
    """Container for cert-manager resources."""

    namespace: k8s.core.v1.Namespace
    release: k8s.helm.v3.Release


def deploy_cert_manager(
    _settings: Settings,
    k8s_provider: k8s.Provider,
) -> CertManagerResources:
    """Deploy cert-manager for TLS certificate management.

    cert-manager automates certificate issuance and renewal
    using Let's Encrypt with DNS-01 validation via Route 53.

    Args:
        settings: Application settings
        k8s_provider: Kubernetes provider

    Returns:
        CertManagerResources containing all created resources
    """
    # Create namespace
    namespace = k8s.core.v1.Namespace(
        "cert-manager-namespace",
        metadata=k8s.meta.v1.ObjectMetaArgs(
            name="cert-manager",
        ),
        opts=pulumi.ResourceOptions(provider=k8s_provider),
    )

    # Deploy cert-manager Helm chart
    release = k8s.helm.v3.Release(
        "cert-manager",
        chart="cert-manager",
        version=CERT_MANAGER_CHART_VERSION,
        repository_opts=k8s.helm.v3.RepositoryOptsArgs(
            repo=CERT_MANAGER_REPO,
        ),
        namespace=namespace.metadata.name,  # type: ignore[attr-defined, misc]  # Pulumi resource .name attr
        values={
            # Install CRDs via Helm (cert-manager >= v1.15)
            "crds": {
                "enabled": True,
            },
            # Leader election namespace
            "global": {
                "leaderElection": {
                    "namespace": "cert-manager",
                },
            },
            # Resource requests for stability
            "resources": {
                "requests": {
                    "cpu": "50m",
                    "memory": "64Mi",
                },
            },
        },
        skip_await=False,
        opts=pulumi.ResourceOptions(
            provider=k8s_provider,
            depends_on=[namespace],
        ),
    )

    # Export cert-manager info
    pulumi.export("cert_manager_chart_version", CERT_MANAGER_CHART_VERSION)

    return CertManagerResources(
        namespace=namespace,
        release=release,
    )
