"""Type stubs for pulumi_kubernetes.apiextensions module."""

from typing import Mapping
from pulumi import ResourceOptions
from pulumi_kubernetes.meta.v1 import ObjectMetaArgs

class CustomResource:
    """Kubernetes CustomResource."""

    def __init__(
        self,
        resource_name: str,
        api_version: str,
        kind: str,
        metadata: ObjectMetaArgs | None = None,
        spec: Mapping[str, object] | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

__all__ = ["CustomResource"]
