"""Shared Kubernetes doctrine constants for prodbox lifecycle commands."""

from __future__ import annotations

PRODBOX_NAMESPACE: str = "prodbox"
PRODBOX_IDENTITY_CONFIGMAP: str = "prodbox-identity"
PRODBOX_ANNOTATION_KEY: str = "prodbox.io/id"
PRODBOX_LABEL_KEY: str = "prodbox.io/id"

PRODBOX_STORAGE_CLASS: str = "prodbox-local-retain"
PRODBOX_STORAGE_BASE_PATH: str = "/var/lib/prodbox/storage"
PRODBOX_STORAGE_RECLAIM_POLICY: str = "Retain"
PRODBOX_STORAGE_BINDING_MODE: str = "WaitForFirstConsumer"
PRODBOX_STORAGE_RETAINED_RESOURCES: tuple[str, ...] = (
    "persistentvolumeclaims",
    "persistentvolumes",
    "storageclasses",
    "storageclasses.storage.k8s.io",
)
PRODBOX_EPHEMERAL_RESOURCE_KINDS: tuple[str, ...] = (
    "events",
    "events.events.k8s.io",
)

HARBOR_NAMESPACE: str = "harbor"
HARBOR_HELM_RELEASE: str = "harbor"
HARBOR_HELM_REPOSITORY_NAME: str = "harbor"
HARBOR_HELM_REPOSITORY_URL: str = "https://helm.goharbor.io"
HARBOR_REGISTRY_HOST: str = "127.0.0.1"
HARBOR_REGISTRY_PORT: int = 30080
HARBOR_REGISTRY_ENDPOINT: str = f"{HARBOR_REGISTRY_HOST}:{HARBOR_REGISTRY_PORT}"
HARBOR_MIRROR_PROJECT: str = "prodbox"
HARBOR_GATEWAY_REPOSITORY: str = "prodbox/prodbox-gateway"
RKE2_REGISTRIES_PATH: str = "/etc/rancher/rke2/registries.yaml"

MINIO_NAMESPACE: str = PRODBOX_NAMESPACE
MINIO_HELM_RELEASE: str = "minio"
MINIO_HELM_REPOSITORY_NAME: str = "minio"
MINIO_HELM_REPOSITORY_URL: str = "https://charts.min.io/"
MINIO_HELM_CHART_REF: str = "minio/minio"
MINIO_HELM_CHART_VERSION: str = "5.4.0"
MINIO_PERSISTENT_VOLUME: str = "prodbox-minio-pv-0"
MINIO_PERSISTENT_CLAIM: str = "minio"
MINIO_STORAGE_SIZE: str = "200Gi"

PRODBOX_MANAGED_NAMESPACES: tuple[str, ...] = (
    PRODBOX_NAMESPACE,
    HARBOR_NAMESPACE,
    "metallb-system",
    "traefik-system",
    "cert-manager",
)

PRODBOX_HELM_INSTANCES: tuple[str, ...] = (
    HARBOR_HELM_RELEASE,
    MINIO_HELM_RELEASE,
    "metallb",
    "traefik",
    "cert-manager",
)

RKE2_DATA_PATHS: tuple[str, ...] = (
    "/var/lib/rancher/rke2",
    "/var/lib/rancher",
    "/etc/rancher/rke2",
)


def prodbox_id_to_label_value(prodbox_id: str) -> str:
    """Convert prodbox-id into a Kubernetes label-safe value."""
    return prodbox_id[:63]


def prodbox_gateway_image_ref(prodbox_id: str) -> str:
    """Build the canonical Harbor gateway image reference for one prodbox-id."""
    tag = prodbox_id_to_label_value(prodbox_id)
    return f"{HARBOR_REGISTRY_ENDPOINT}/{HARBOR_GATEWAY_REPOSITORY}:{tag}"


__all__ = [
    "PRODBOX_NAMESPACE",
    "PRODBOX_IDENTITY_CONFIGMAP",
    "PRODBOX_ANNOTATION_KEY",
    "PRODBOX_LABEL_KEY",
    "PRODBOX_STORAGE_CLASS",
    "PRODBOX_STORAGE_BASE_PATH",
    "PRODBOX_STORAGE_RECLAIM_POLICY",
    "PRODBOX_STORAGE_BINDING_MODE",
    "PRODBOX_STORAGE_RETAINED_RESOURCES",
    "PRODBOX_EPHEMERAL_RESOURCE_KINDS",
    "HARBOR_NAMESPACE",
    "HARBOR_HELM_RELEASE",
    "HARBOR_HELM_REPOSITORY_NAME",
    "HARBOR_HELM_REPOSITORY_URL",
    "HARBOR_REGISTRY_HOST",
    "HARBOR_REGISTRY_PORT",
    "HARBOR_REGISTRY_ENDPOINT",
    "HARBOR_MIRROR_PROJECT",
    "HARBOR_GATEWAY_REPOSITORY",
    "RKE2_REGISTRIES_PATH",
    "MINIO_NAMESPACE",
    "MINIO_HELM_RELEASE",
    "MINIO_HELM_REPOSITORY_NAME",
    "MINIO_HELM_REPOSITORY_URL",
    "MINIO_HELM_CHART_REF",
    "MINIO_HELM_CHART_VERSION",
    "MINIO_PERSISTENT_VOLUME",
    "MINIO_PERSISTENT_CLAIM",
    "MINIO_STORAGE_SIZE",
    "PRODBOX_MANAGED_NAMESPACES",
    "PRODBOX_HELM_INSTANCES",
    "RKE2_DATA_PATHS",
    "prodbox_id_to_label_value",
    "prodbox_gateway_image_ref",
]
