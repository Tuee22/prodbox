"""Unit tests for shared prodbox Kubernetes doctrine constants."""

from __future__ import annotations

from prodbox.lib.prodbox_k8s import (
    HARBOR_GATEWAY_REPOSITORY,
    HARBOR_NAMESPACE,
    HARBOR_REGISTRY_ENDPOINT,
    HARBOR_REGISTRY_PORT,
    MINIO_HELM_CHART_REF,
    MINIO_HELM_RELEASE,
    MINIO_NAMESPACE,
    MINIO_PERSISTENT_CLAIM,
    MINIO_PERSISTENT_VOLUME,
    PRODBOX_ANNOTATION_KEY,
    PRODBOX_EPHEMERAL_RESOURCE_KINDS,
    PRODBOX_IDENTITY_CONFIGMAP,
    PRODBOX_LABEL_KEY,
    PRODBOX_NAMESPACE,
    PRODBOX_STORAGE_CLASS,
    PRODBOX_STORAGE_RETAINED_RESOURCES,
    prodbox_gateway_image_ref,
    prodbox_id_to_label_value,
)


def test_prodbox_k8s_constants_are_stable() -> None:
    """Core doctrine constants should expose expected canonical names."""
    assert PRODBOX_NAMESPACE == "prodbox"
    assert PRODBOX_IDENTITY_CONFIGMAP == "prodbox-identity"
    assert PRODBOX_ANNOTATION_KEY == "prodbox.io/id"
    assert PRODBOX_LABEL_KEY == "prodbox.io/id"
    assert HARBOR_NAMESPACE == "harbor"
    assert HARBOR_REGISTRY_PORT == 30080
    assert HARBOR_REGISTRY_ENDPOINT == "127.0.0.1:30080"
    assert HARBOR_GATEWAY_REPOSITORY == "prodbox/prodbox-gateway"
    assert PRODBOX_STORAGE_CLASS == "prodbox-local-retain"
    assert "persistentvolumes" in PRODBOX_STORAGE_RETAINED_RESOURCES
    assert "events" in PRODBOX_EPHEMERAL_RESOURCE_KINDS
    assert "events.events.k8s.io" in PRODBOX_EPHEMERAL_RESOURCE_KINDS
    assert MINIO_NAMESPACE == "prodbox"
    assert MINIO_HELM_RELEASE == "minio"
    assert MINIO_HELM_CHART_REF == "minio/minio"
    assert MINIO_PERSISTENT_CLAIM == "minio"
    assert MINIO_PERSISTENT_VOLUME == "prodbox-minio-pv-0"


def test_prodbox_id_to_label_value_truncates_to_k8s_limit() -> None:
    """Label value helper should cap output at 63 chars."""
    long_id = "prodbox-" + ("a" * 80)
    assert len(prodbox_id_to_label_value(long_id)) == 63


def test_prodbox_gateway_image_ref_uses_harbor_endpoint() -> None:
    """Gateway image ref helper should derive Harbor-tagged image path."""
    image = prodbox_gateway_image_ref("prodbox-0123456789abcdef0123456789abcdef")
    assert image.startswith("127.0.0.1:30080/prodbox/prodbox-gateway:")
