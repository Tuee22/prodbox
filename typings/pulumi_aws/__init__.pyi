"""Type stubs for pulumi-aws.

Provides typed interfaces for AWS provider and the EC2/IAM/EKS/Route 53 surfaces used in repo
code.
"""

from pulumi import InvokeOptions

class Provider:
    """AWS provider."""

    def __init__(
        self,
        resource_name: str,
        region: str | None = None,
        access_key: str | None = None,
        secret_key: str | None = None,
        token: str | None = None,
        profile: str | None = None,
        shared_credentials_file: str | None = None,
        skip_credentials_validation: bool = False,
        skip_metadata_api_check: bool = False,
        skip_region_validation: bool = False,
    ) -> None: ...

class GetAvailabilityZonesResult:
    names: tuple[str, ...]

def get_availability_zones(
    *,
    state: str | None = None,
    opts: InvokeOptions | None = None,
) -> GetAvailabilityZonesResult: ...

from pulumi_aws import ec2 as ec2
from pulumi_aws import eks as eks
from pulumi_aws import iam as iam
from pulumi_aws import route53 as route53

__all__ = [
    "GetAvailabilityZonesResult",
    "Provider",
    "ec2",
    "eks",
    "get_availability_zones",
    "iam",
    "route53",
]
