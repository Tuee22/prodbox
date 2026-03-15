"""Helpers for applying prodbox annotation doctrine in Pulumi resources."""

from __future__ import annotations

import os
from collections.abc import Mapping

import pulumi_kubernetes as k8s

from prodbox.lib.prodbox_k8s import (
    PRODBOX_ANNOTATION_KEY,
    PRODBOX_LABEL_KEY,
    prodbox_id_to_label_value,
)


def resolve_prodbox_id() -> str:
    """Resolve prodbox-id from environment for Pulumi runs."""
    value = os.environ.get("PRODBOX_ID", "").strip().lower()
    if value:
        return value
    return "prodbox-unknown"


def prodbox_annotations(prodbox_id: str) -> dict[str, str]:
    """Return canonical prodbox annotation mapping."""
    return {PRODBOX_ANNOTATION_KEY: prodbox_id}


def prodbox_labels(prodbox_id: str) -> dict[str, str]:
    """Return canonical prodbox label mapping."""
    return {PRODBOX_LABEL_KEY: prodbox_id_to_label_value(prodbox_id)}


def object_meta(
    *,
    name: str,
    prodbox_id: str,
    namespace: str | None = None,
    labels: Mapping[str, str] | None = None,
    annotations: Mapping[str, str] | None = None,
) -> k8s.meta.v1.ObjectMetaArgs:
    """Build ObjectMetaArgs with mandatory prodbox annotation+label."""
    merged_labels = dict(prodbox_labels(prodbox_id))
    if labels:
        merged_labels.update(labels)
    merged_annotations = dict(prodbox_annotations(prodbox_id))
    if annotations:
        merged_annotations.update(annotations)
    return k8s.meta.v1.ObjectMetaArgs(
        name=name,
        namespace=namespace,
        labels=merged_labels,
        annotations=merged_annotations,
    )


def chart_values_with_prodbox(
    *,
    values: Mapping[str, object],
    prodbox_id: str,
) -> dict[str, object]:
    """Inject common labels/annotations for Helm charts where supported."""
    merged: dict[str, object] = dict(values)
    common_labels = _dict_str_str(merged.get("commonLabels"))
    common_labels.update(prodbox_labels(prodbox_id))
    common_annotations = _dict_str_str(merged.get("commonAnnotations"))
    common_annotations.update(prodbox_annotations(prodbox_id))
    merged["commonLabels"] = common_labels
    merged["commonAnnotations"] = common_annotations
    return merged


def _dict_str_str(value: object) -> dict[str, str]:
    """Convert object to dict[str, str] when possible."""
    if not isinstance(value, dict):
        return {}
    out: dict[str, str] = {}
    for key, item in value.items():
        if isinstance(key, str) and isinstance(item, str):
            out[key] = item
    return out
