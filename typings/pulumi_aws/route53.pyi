"""Type stubs for pulumi_aws.route53 module."""

from typing import Sequence
from pulumi import ResourceOptions, Output

class RecordArgs:
    """Arguments for a Route 53 record."""

    def __init__(
        self,
        zone_id: str | None = None,
        name: str | None = None,
        type: str | None = None,
        ttl: int | None = None,
        records: Sequence[str] | None = None,
        allow_overwrite: bool = False,
    ) -> None: ...

class Record:
    """Route 53 DNS record resource."""

    def __init__(
        self,
        resource_name: str,
        zone_id: str | None = None,
        name: str | None = None,
        type: str | None = None,
        ttl: int | None = None,
        records: Sequence[str] | None = None,
        allow_overwrite: bool = False,
        args: RecordArgs | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

    @property
    def fqdn(self) -> Output[str]: ...

class Zone:
    """Route 53 hosted zone resource."""

    def __init__(
        self,
        resource_name: str,
        name: str | None = None,
        comment: str | None = None,
        force_destroy: bool = False,
        opts: ResourceOptions | None = None,
    ) -> None: ...

    @property
    def zone_id(self) -> Output[str]: ...

__all__ = ["Record", "RecordArgs", "Zone"]
