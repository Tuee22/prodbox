"""Pure functions generating K8s manifest dicts for gateway daemon pod tests."""

from __future__ import annotations

import re
from pathlib import Path

from prodbox.lib.prodbox_k8s import (
    PRODBOX_ANNOTATION_KEY,
    PRODBOX_LABEL_KEY,
    prodbox_id_to_label_value,
)

GATEWAY_HEARTBEAT_INTERVAL_SECONDS = 0.5
GATEWAY_RECONNECT_INTERVAL_SECONDS = 0.5
GATEWAY_SYNC_INTERVAL_SECONDS = 1.0


def _prodbox_id() -> str:
    """Resolve prodbox-id for integration test manifests."""
    machine_id_path = Path("/etc/machine-id")
    if machine_id_path.exists():
        raw_machine_id = machine_id_path.read_text(encoding="utf-8").strip().lower()
        if re.fullmatch(r"[0-9a-f]{32}", raw_machine_id):
            return f"prodbox-{raw_machine_id}"
    return "prodbox-test"


def _prodbox_annotations() -> dict[str, str]:
    """Return canonical prodbox annotations for test manifests."""
    return {PRODBOX_ANNOTATION_KEY: _prodbox_id()}


def _prodbox_labels() -> dict[str, str]:
    """Return canonical prodbox labels for test manifests."""
    value = prodbox_id_to_label_value(_prodbox_id())
    return {PRODBOX_LABEL_KEY: value}


def gateway_namespace(name: str) -> dict[str, object]:
    """Generate a Namespace manifest."""
    labels = _prodbox_labels()
    return {
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {
            "name": name,
            "annotations": _prodbox_annotations(),
            "labels": labels,
        },
    }


def gateway_orders_configmap(
    namespace: str,
    orders: dict[str, object],
) -> dict[str, object]:
    """Generate a ConfigMap with serialized orders JSON."""
    import json

    return {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": "gateway-orders",
            "namespace": namespace,
            "annotations": _prodbox_annotations(),
            "labels": {**_prodbox_labels(), "app": "prodbox-gateway"},
        },
        "data": {
            "orders.json": json.dumps(orders, sort_keys=True, indent=2),
        },
    }


def gateway_daemon_pod(
    *,
    node_id: str,
    namespace: str,
    image: str,
    rest_port: int,
    socket_port: int,
    cert_secret: str,
    ca_secret: str,
    orders_configmap: str,
) -> dict[str, object]:
    """Generate a Pod manifest for a gateway daemon instance."""
    env_vars: list[dict[str, str]] = [
        {"name": "GATEWAY_NODE_ID", "value": node_id},
    ]

    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": f"gateway-{node_id}",
            "namespace": namespace,
            "annotations": _prodbox_annotations(),
            "labels": {
                **_prodbox_labels(),
                "app": "prodbox-gateway",
                "gateway-node": node_id,
            },
        },
        "spec": {
            "restartPolicy": "Always",
            "containers": [
                {
                    "name": "gateway",
                    "image": image,
                    "args": ["--config", "/etc/gateway/config.json"],
                    "ports": [
                        {"containerPort": rest_port, "name": "rest", "protocol": "TCP"},
                        {"containerPort": socket_port, "name": "events", "protocol": "TCP"},
                    ],
                    "env": env_vars,
                    "volumeMounts": [
                        {"name": "tls", "mountPath": "/tls", "readOnly": True},
                        {"name": "ca", "mountPath": "/ca", "readOnly": True},
                        {
                            "name": "orders",
                            "mountPath": "/etc/gateway/orders.json",
                            "subPath": "orders.json",
                            "readOnly": True,
                        },
                        {
                            "name": "config",
                            "mountPath": "/etc/gateway/config.json",
                            "subPath": "config.json",
                            "readOnly": True,
                        },
                    ],
                    "livenessProbe": {
                        "httpGet": {
                            "path": "/v1/state",
                            "port": rest_port,
                            "scheme": "HTTPS",
                        },
                        "initialDelaySeconds": 5,
                        "periodSeconds": 10,
                    },
                }
            ],
            "volumes": [
                {
                    "name": "tls",
                    "secret": {"secretName": cert_secret},
                },
                {
                    "name": "ca",
                    "secret": {"secretName": ca_secret},
                },
                {
                    "name": "orders",
                    "configMap": {"name": orders_configmap},
                },
                {
                    "name": "config",
                    "configMap": {
                        "name": f"gateway-config-{node_id}",
                        "items": [{"key": "config.json", "path": "config.json"}],
                    },
                },
            ],
        },
    }


def gateway_config_configmap(
    *,
    node_id: str,
    namespace: str,
    event_keys: dict[str, str],
) -> dict[str, object]:
    """Generate a ConfigMap with the daemon JSON config for a specific node."""
    import json

    config = {
        "node_id": node_id,
        "cert_file": "/tls/tls.crt",
        "key_file": "/tls/tls.key",
        "ca_file": "/ca/ca.crt",
        "orders_file": "/etc/gateway/orders.json",
        "event_keys": event_keys,
        "heartbeat_interval_seconds": GATEWAY_HEARTBEAT_INTERVAL_SECONDS,
        "reconnect_interval_seconds": GATEWAY_RECONNECT_INTERVAL_SECONDS,
        "sync_interval_seconds": GATEWAY_SYNC_INTERVAL_SECONDS,
    }
    return {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": f"gateway-config-{node_id}",
            "namespace": namespace,
            "annotations": _prodbox_annotations(),
            "labels": {**_prodbox_labels(), "app": "prodbox-gateway"},
        },
        "data": {
            "config.json": json.dumps(config, sort_keys=True, indent=2),
        },
    }


def gateway_service(
    *,
    node_id: str,
    namespace: str,
    rest_port: int,
    socket_port: int,
) -> dict[str, object]:
    """Generate a Service manifest for a gateway daemon pod."""
    return {
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": {
            "name": f"gateway-{node_id}",
            "namespace": namespace,
            "annotations": _prodbox_annotations(),
            "labels": {**_prodbox_labels(), "app": "prodbox-gateway"},
        },
        "spec": {
            "selector": {
                "app": "prodbox-gateway",
                "gateway-node": node_id,
            },
            "ports": [
                {"port": rest_port, "targetPort": rest_port, "name": "rest", "protocol": "TCP"},
                {
                    "port": socket_port,
                    "targetPort": socket_port,
                    "name": "events",
                    "protocol": "TCP",
                },
            ],
            "type": "ClusterIP",
        },
    }


def gateway_network_policy_isolate(
    *,
    target_node: str,
    namespace: str,
) -> dict[str, object]:
    """Generate a NetworkPolicy that blocks all ingress/egress for a labeled pod."""
    return {
        "apiVersion": "networking.k8s.io/v1",
        "kind": "NetworkPolicy",
        "metadata": {
            "name": f"isolate-{target_node}",
            "namespace": namespace,
            "annotations": _prodbox_annotations(),
            "labels": {**_prodbox_labels(), "app": "prodbox-gateway"},
        },
        "spec": {
            "podSelector": {
                "matchLabels": {
                    "gateway-node": target_node,
                },
            },
            "policyTypes": ["Ingress", "Egress"],
            "ingress": [],
            "egress": [],
        },
    }


def gateway_network_policy_asymmetric(
    *,
    blocked_from: str,
    blocked_to: str,
    namespace: str,
) -> tuple[dict[str, object], dict[str, object]]:
    """Block traffic between two specific pods while allowing all other traffic.

    Returns two NetworkPolicy objects:
    - One on ``blocked_from`` denying egress to ``blocked_to``
    - One on ``blocked_to`` denying ingress from ``blocked_from``

    This creates an asymmetric partition where a third node can still communicate
    with both blocked nodes, but the two blocked nodes cannot reach each other.
    """
    egress_policy: dict[str, object] = {
        "apiVersion": "networking.k8s.io/v1",
        "kind": "NetworkPolicy",
        "metadata": {
            "name": f"block-{blocked_from}-to-{blocked_to}-egress",
            "namespace": namespace,
            "annotations": _prodbox_annotations(),
            "labels": {**_prodbox_labels(), "app": "prodbox-gateway"},
        },
        "spec": {
            "podSelector": {
                "matchLabels": {
                    "gateway-node": blocked_from,
                },
            },
            "policyTypes": ["Egress"],
            "egress": [
                {
                    "to": [
                        {
                            "podSelector": {
                                "matchExpressions": [
                                    {
                                        "key": "gateway-node",
                                        "operator": "NotIn",
                                        "values": [blocked_to],
                                    },
                                ],
                            },
                        },
                    ],
                },
            ],
        },
    }
    ingress_policy: dict[str, object] = {
        "apiVersion": "networking.k8s.io/v1",
        "kind": "NetworkPolicy",
        "metadata": {
            "name": f"block-{blocked_from}-to-{blocked_to}-ingress",
            "namespace": namespace,
            "annotations": _prodbox_annotations(),
            "labels": {**_prodbox_labels(), "app": "prodbox-gateway"},
        },
        "spec": {
            "podSelector": {
                "matchLabels": {
                    "gateway-node": blocked_to,
                },
            },
            "policyTypes": ["Ingress"],
            "ingress": [
                {
                    "from": [
                        {
                            "podSelector": {
                                "matchExpressions": [
                                    {
                                        "key": "gateway-node",
                                        "operator": "NotIn",
                                        "values": [blocked_from],
                                    },
                                ],
                            },
                        },
                    ],
                },
            ],
        },
    }
    return (egress_policy, ingress_policy)


def gateway_network_policy_allow_all(namespace: str) -> dict[str, object]:
    """Generate a NetworkPolicy that allows all traffic in the namespace."""
    return {
        "apiVersion": "networking.k8s.io/v1",
        "kind": "NetworkPolicy",
        "metadata": {
            "name": "allow-all",
            "namespace": namespace,
            "annotations": _prodbox_annotations(),
            "labels": _prodbox_labels(),
        },
        "spec": {
            "podSelector": {},
            "policyTypes": ["Ingress", "Egress"],
            "ingress": [{}],
            "egress": [{}],
        },
    }
