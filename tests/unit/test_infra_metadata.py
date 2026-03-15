"""Unit tests for infra metadata helper functions."""

from __future__ import annotations

import os
from unittest.mock import patch

from prodbox.infra.metadata import (
    chart_values_with_prodbox,
    prodbox_annotations,
    prodbox_labels,
    resolve_prodbox_id,
)


def test_resolve_prodbox_id_from_env() -> None:
    """resolve_prodbox_id should return normalized env value when provided."""
    with patch.dict(os.environ, {"PRODBOX_ID": "PRODBOX-ABC"}, clear=True):
        assert resolve_prodbox_id() == "prodbox-abc"


def test_resolve_prodbox_id_default_unknown() -> None:
    """resolve_prodbox_id should fall back to prodbox-unknown when env is missing."""
    with patch.dict(os.environ, {}, clear=True):
        assert resolve_prodbox_id() == "prodbox-unknown"


def test_prodbox_annotations_and_labels() -> None:
    """metadata helpers should expose doctrine key/value mappings."""
    prodbox_id = "prodbox-0123456789abcdef0123456789abcdef"
    annotations = prodbox_annotations(prodbox_id)
    labels = prodbox_labels(prodbox_id)
    assert annotations["prodbox.io/id"] == prodbox_id
    assert labels["prodbox.io/id"].startswith("prodbox-")


def test_chart_values_with_prodbox_merges_existing_values() -> None:
    """chart helper should preserve existing values while injecting doctrine metadata."""
    values = {
        "service": {"type": "LoadBalancer"},
        "commonLabels": {"existing": "label"},
        "commonAnnotations": {"existing": "annotation"},
    }
    merged = chart_values_with_prodbox(
        values=values,
        prodbox_id="prodbox-0123456789abcdef0123456789abcdef",
    )
    assert merged["service"] == {"type": "LoadBalancer"}
    common_labels = merged["commonLabels"]
    common_annotations = merged["commonAnnotations"]
    assert isinstance(common_labels, dict)
    assert isinstance(common_annotations, dict)
    assert common_labels["existing"] == "label"
    assert common_annotations["existing"] == "annotation"
    assert common_labels["prodbox.io/id"].startswith("prodbox-")
    assert common_annotations["prodbox.io/id"].startswith("prodbox-")
