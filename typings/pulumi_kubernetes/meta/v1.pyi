"""Type stubs for pulumi_kubernetes.meta.v1 module."""

from typing import Mapping, Sequence

class ObjectMetaArgs:
    """Kubernetes object metadata."""

    def __init__(
        self,
        name: str | None = None,
        namespace: str | None = None,
        labels: Mapping[str, str] | None = None,
        annotations: Mapping[str, str] | None = None,
        generate_name: str | None = None,
        finalizers: Sequence[str] | None = None,
    ) -> None: ...

__all__ = ["ObjectMetaArgs"]
