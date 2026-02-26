"""Type stubs for boto3.

Provides typed client() function for Route 53 service.
"""

from typing import overload, Literal

class Route53Client:
    """Typed Route 53 client interface."""

    def list_resource_record_sets(
        self,
        HostedZoneId: str,
        StartRecordName: str | None = None,
        StartRecordType: str | None = None,
        StartRecordIdentifier: str | None = None,
        MaxItems: str | None = None,
    ) -> dict[str, object]: ...

    def change_resource_record_sets(
        self,
        HostedZoneId: str,
        ChangeBatch: dict[str, object],
    ) -> dict[str, object]: ...

    def get_hosted_zone(
        self,
        Id: str,
    ) -> dict[str, object]: ...

class STSClient:
    """Typed STS client interface."""

    def get_caller_identity(self) -> dict[str, object]: ...

@overload
def client(
    service_name: Literal["route53"],
    region_name: str | None = None,
    aws_access_key_id: str | None = None,
    aws_secret_access_key: str | None = None,
    aws_session_token: str | None = None,
    config: object | None = None,
) -> Route53Client: ...

@overload
def client(
    service_name: Literal["sts"],
    region_name: str | None = None,
    aws_access_key_id: str | None = None,
    aws_secret_access_key: str | None = None,
    aws_session_token: str | None = None,
    config: object | None = None,
) -> STSClient: ...

@overload
def client(
    service_name: str,
    region_name: str | None = None,
    aws_access_key_id: str | None = None,
    aws_secret_access_key: str | None = None,
    aws_session_token: str | None = None,
    config: object | None = None,
) -> object: ...

def resource(
    service_name: str,
    region_name: str | None = None,
    aws_access_key_id: str | None = None,
    aws_secret_access_key: str | None = None,
    aws_session_token: str | None = None,
) -> object: ...

class Session:
    """boto3 Session."""

    def __init__(
        self,
        aws_access_key_id: str | None = None,
        aws_secret_access_key: str | None = None,
        aws_session_token: str | None = None,
        region_name: str | None = None,
        botocore_session: object | None = None,
        profile_name: str | None = None,
    ) -> None: ...

    @overload
    def client(
        self,
        service_name: Literal["route53"],
        region_name: str | None = None,
        aws_access_key_id: str | None = None,
        aws_secret_access_key: str | None = None,
        aws_session_token: str | None = None,
    ) -> Route53Client: ...

    @overload
    def client(
        self,
        service_name: Literal["sts"],
        region_name: str | None = None,
        aws_access_key_id: str | None = None,
        aws_secret_access_key: str | None = None,
        aws_session_token: str | None = None,
    ) -> STSClient: ...

    @overload
    def client(
        self,
        service_name: str,
        region_name: str | None = None,
        aws_access_key_id: str | None = None,
        aws_secret_access_key: str | None = None,
        aws_session_token: str | None = None,
    ) -> object: ...

    def resource(
        self,
        service_name: str,
        region_name: str | None = None,
    ) -> object: ...

__all__ = ["client", "resource", "Session", "Route53Client", "STSClient"]
