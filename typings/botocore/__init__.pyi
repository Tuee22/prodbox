"""Type stubs for botocore.

Minimal stubs for botocore types used by boto3.
"""

class Config:
    """botocore Config."""

    def __init__(
        self,
        region_name: str | None = None,
        signature_version: str | None = None,
        user_agent: str | None = None,
        user_agent_extra: str | None = None,
        connect_timeout: float | None = None,
        read_timeout: float | None = None,
        parameter_validation: bool = True,
        max_pool_connections: int = 10,
        proxies: dict[str, str] | None = None,
        s3: dict[str, object] | None = None,
        retries: dict[str, object] | None = None,
    ) -> None: ...

__all__ = ["Config"]
