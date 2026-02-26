"""Type stubs for pulumi-aws.

Provides typed interfaces for AWS provider and Route 53 resources.
"""

from pulumi import ResourceOptions

class Provider:
    """AWS provider."""

    def __init__(
        self,
        resource_name: str,
        region: str | None = None,
        access_key: str | None = None,
        secret_key: str | None = None,
        profile: str | None = None,
        shared_credentials_file: str | None = None,
        skip_credentials_validation: bool = False,
        skip_metadata_api_check: bool = False,
        skip_region_validation: bool = False,
    ) -> None: ...

# Re-export submodules
from pulumi_aws import route53 as route53

__all__ = ["Provider", "route53"]
