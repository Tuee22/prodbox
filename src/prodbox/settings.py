"""Pydantic settings for prodbox configuration."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Annotated

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):  # type: ignore[explicit-any]  # Pydantic BaseSettings uses Any internally
    """Central configuration for all prodbox operations.

    All configuration comes from environment variables.
    Use `prodbox env show` to display effective configuration.
    """

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    # === Kubernetes ===
    kubeconfig: Annotated[
        Path,
        Field(
            default=Path.home() / ".kube" / "config",
            description="Path to kubeconfig file",
        ),
    ]

    # === AWS / Route 53 ===
    aws_region: Annotated[
        str,
        Field(
            default="us-east-1",
            description="AWS region for Route 53",
        ),
    ]
    aws_access_key_id: Annotated[
        str,
        Field(
            description="AWS access key ID",
        ),
    ]
    aws_secret_access_key: Annotated[
        str,
        Field(
            description="AWS secret access key (sensitive)",
        ),
    ]
    route53_zone_id: Annotated[
        str,
        Field(
            description="Route 53 hosted zone ID",
        ),
    ]

    # === Domain ===
    demo_fqdn: Annotated[
        str,
        Field(
            default="demo.example.com",
            description="Fully qualified domain name for the demo",
        ),
    ]
    demo_ttl: Annotated[
        int,
        Field(
            default=60,
            ge=30,
            le=86400,
            description="DNS record TTL in seconds",
        ),
    ]

    # === MetalLB / Ingress ===
    metallb_pool: Annotated[
        str,
        Field(
            default="192.168.1.240-192.168.1.250",
            description="MetalLB IP address pool range",
        ),
    ]
    ingress_lb_ip: Annotated[
        str,
        Field(
            default="192.168.1.240",
            description="Reserved IP for ingress LoadBalancer",
        ),
    ]

    # === ACME / cert-manager ===
    acme_email: Annotated[
        str,
        Field(
            description="Email for Let's Encrypt registration",
        ),
    ]
    acme_server: Annotated[
        str,
        Field(
            default="https://acme-v02.api.letsencrypt.org/directory",
            description="ACME server URL",
        ),
    ]

    # === Pulumi ===
    pulumi_stack: Annotated[
        str,
        Field(
            default="home",
            description="Pulumi stack name",
        ),
    ]

    @field_validator("kubeconfig", mode="before")
    @classmethod
    def expand_kubeconfig_path(cls, v: str | Path) -> Path:
        """Expand ~ in kubeconfig path."""
        if isinstance(v, str):
            return Path(v).expanduser()
        return v.expanduser()

    def display_dict(self) -> dict[str, str | int | Path]:
        """Return settings as dict with sensitive values masked."""
        data: dict[str, str | int | Path] = self.model_dump()
        # Mask sensitive fields
        sensitive_fields = {"aws_secret_access_key"}
        for field in sensitive_fields:
            if field in data and data[field]:
                value = str(data[field])
                data[field] = "****" + value[-4:] if len(value) > 4 else "****"
        return data


@lru_cache(maxsize=1)  # type: ignore[misc]  # lru_cache signature contains Callable[..., T]
def get_settings() -> Settings:
    """Get cached settings instance.

    Settings are parsed once and cached. Use clear_settings_cache()
    if you need to reload (e.g., in tests).

    Returns:
        Validated Settings instance
    """
    return Settings()


def clear_settings_cache() -> None:
    """Clear the settings cache. Useful for testing."""
    get_settings.cache_clear()
