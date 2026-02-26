"""Type stubs for pulumi_kubernetes.core.v1 module."""

from typing import Mapping, Sequence
from pulumi import ResourceOptions
from pulumi_kubernetes.meta.v1 import ObjectMetaArgs

class Namespace:
    """Kubernetes Namespace resource."""

    def __init__(
        self,
        resource_name: str,
        metadata: ObjectMetaArgs | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

    @property
    def metadata(self) -> object: ...

class Secret:
    """Kubernetes Secret resource."""

    def __init__(
        self,
        resource_name: str,
        metadata: ObjectMetaArgs | None = None,
        string_data: Mapping[str, str] | None = None,
        data: Mapping[str, str] | None = None,
        type: str | None = None,
        immutable: bool | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

class ConfigMap:
    """Kubernetes ConfigMap resource."""

    def __init__(
        self,
        resource_name: str,
        metadata: ObjectMetaArgs | None = None,
        data: Mapping[str, str] | None = None,
        binary_data: Mapping[str, str] | None = None,
        immutable: bool | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

__all__ = ["Namespace", "Secret", "ConfigMap"]
