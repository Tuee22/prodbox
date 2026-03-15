"""cert-manager infrastructure module."""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

import pulumi
import pulumi_kubernetes as k8s

from prodbox.infra.metadata import chart_values_with_prodbox, object_meta

if TYPE_CHECKING:
    from prodbox.settings import Settings

# Pinned chart version for reproducibility
CERT_MANAGER_CHART_VERSION = "v1.16.2"
CERT_MANAGER_REPO = "https://charts.jetstack.io"


@dataclass(frozen=True)
class CertManagerResources:
    """Container for cert-manager resources."""

    namespace: k8s.core.v1.Namespace
    release: k8s.helm.v3.Release


def deploy_cert_manager(
    _settings: Settings,
    k8s_provider: k8s.Provider,
    *,
    prodbox_id: str,
) -> CertManagerResources:
    """Deploy cert-manager for TLS certificate management.

    cert-manager automates certificate issuance and renewal
    using Let's Encrypt with DNS-01 validation via Route 53.

    Args:
        settings: Application settings
        k8s_provider: Kubernetes provider
        prodbox_id: Canonical prodbox-id annotation value

    Returns:
        CertManagerResources containing all created resources
    """
    # Create namespace
    namespace = k8s.core.v1.Namespace(
        "cert-manager-namespace",
        metadata=object_meta(name="cert-manager", prodbox_id=prodbox_id),
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
        values=chart_values_with_prodbox(
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
            prodbox_id=prodbox_id,
        ),
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
