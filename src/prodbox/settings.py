"""Pydantic settings for prodbox configuration."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Annotated

from pydantic import Field, field_validator
from pydantic.functional_validators import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from prodbox.lib.aws_auth import assert_ambient_aws_auth_only, assert_no_aws_auth_in_dotenv

RenderedSettingValue = str | int | Path | None


class Settings(BaseSettings):  # type: ignore[explicit-any]  # Pydantic BaseSettings uses Any internally
    """Central configuration for all prodbox operations.

    All non-auth configuration comes from environment variables.
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
    vscode_fqdn: Annotated[
        str | None,
        Field(
            default=None,
            description="Public FQDN for the VS Code ingress endpoint",
        ),
    ]
    keycloak_admin_password: Annotated[
        str | None,
        Field(
            default=None,
            description="Admin password for the namespace-local Keycloak instance",
        ),
    ]
    keycloak_postgres_password: Annotated[
        str | None,
        Field(
            default=None,
            description="Password for the namespace-local Keycloak Postgres database",
        ),
    ]
    keycloak_nginx_client_secret: Annotated[
        str | None,
        Field(
            default=None,
            description="OIDC client secret shared between Keycloak and the nginx OIDC proxy",
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
    bootstrap_public_ip_override: Annotated[
        str | None,
        Field(
            default=None,
            description="Bootstrap-only public IP override for initial DNS record creation",
        ),
    ]

    @field_validator("kubeconfig", mode="before")
    @classmethod
    def expand_kubeconfig_path(cls, v: str | Path) -> Path:
        """Expand ~ in kubeconfig path."""
        if isinstance(v, str):
            return Path(v).expanduser()
        return v.expanduser()

    @model_validator(mode="before")
    @classmethod
    def reject_aws_auth_env_vars(cls, data: object) -> object:
        """Reject AWS auth env vars so all AWS calls use ambient host auth only."""
        assert_ambient_aws_auth_only()
        assert_no_aws_auth_in_dotenv(Path(".env"))
        return data

    def display_dict(self, *, show_secrets: bool = False) -> dict[str, RenderedSettingValue]:
        """Return settings keyed by attribute name for deterministic display/tests."""
        data = self.to_mapping()
        return {
            spec.attribute: _format_rendered_value(
                data.get(spec.attribute),
                sensitive=spec.sensitive,
                show_secrets=show_secrets,
            )
            for spec in SETTING_SPECS
        }

    def to_mapping(self) -> dict[str, RenderedSettingValue]:
        """Return unmasked settings keyed by attribute name."""
        return {spec.attribute: spec.getter(self) for spec in SETTING_SPECS}

    def render_display(self, *, show_secrets: bool = False) -> str:
        """Render effective configuration as deterministic KEY=value lines."""
        return render_settings_display(self.to_mapping(), show_secrets=show_secrets)

    @staticmethod
    def render_template() -> str:
        """Render a deterministic .env template for all supported settings."""
        return render_settings_template()


def _render_template_from_specs() -> str:
    """Render the deterministic template body from static setting metadata."""
    lines = [
        "# prodbox environment template",
        "# Required values are blank and must be filled in.",
        "# Optional values are pre-populated with defaults where available.",
        "",
    ]
    for spec in SETTING_SPECS:
        requirement = "required" if spec.required else "optional"
        default_hint = (
            f", default: {spec.template_default}" if spec.template_default is not None else ""
        )
        lines.append(f"# {spec.description} ({requirement}{default_hint})")
        lines.append(f"{spec.env_var}={spec.template_default or ''}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


SettingsGetter = Callable[[Settings], RenderedSettingValue]


@dataclass(frozen=True)
class SettingSpec:
    """Declarative metadata for deterministic display/template rendering."""

    attribute: str
    env_var: str
    description: str
    getter: SettingsGetter
    required: bool
    sensitive: bool = False
    template_default: str | None = None


def _mask_secret(value: str) -> str:
    """Return a stable masked secret representation."""
    return "****" + value[-4:] if len(value) > 4 else "****"


def _format_rendered_value(
    value: RenderedSettingValue,
    *,
    sensitive: bool,
    show_secrets: bool,
) -> RenderedSettingValue:
    """Format one setting value for display."""
    if value is None:
        return ""
    if sensitive and not show_secrets:
        return _mask_secret(str(value))
    return value


def render_settings_display(
    settings_values: dict[str, RenderedSettingValue],
    *,
    show_secrets: bool = False,
) -> str:
    """Render plain settings data as deterministic KEY=value lines."""
    lines = [
        f"{spec.env_var}="
        f"{_format_rendered_value(settings_values.get(spec.attribute), sensitive=spec.sensitive, show_secrets=show_secrets)}"
        for spec in SETTING_SPECS
    ]
    return "\n".join(lines) + "\n"


SETTING_SPECS: tuple[SettingSpec, ...] = (
    SettingSpec(
        attribute="kubeconfig",
        env_var="KUBECONFIG",
        description="Path to kubeconfig file",
        getter=lambda settings: settings.kubeconfig,
        required=False,
        template_default="~/.kube/config",
    ),
    SettingSpec(
        attribute="aws_region",
        env_var="AWS_REGION",
        description="AWS region for Route 53",
        getter=lambda settings: settings.aws_region,
        required=False,
        template_default="us-east-1",
    ),
    SettingSpec(
        attribute="route53_zone_id",
        env_var="ROUTE53_ZONE_ID",
        description="Route 53 hosted zone ID",
        getter=lambda settings: settings.route53_zone_id,
        required=True,
    ),
    SettingSpec(
        attribute="demo_fqdn",
        env_var="DEMO_FQDN",
        description="Fully qualified demo domain name",
        getter=lambda settings: settings.demo_fqdn,
        required=False,
        template_default="demo.example.com",
    ),
    SettingSpec(
        attribute="demo_ttl",
        env_var="DEMO_TTL",
        description="DNS record TTL in seconds",
        getter=lambda settings: settings.demo_ttl,
        required=False,
        template_default="60",
    ),
    SettingSpec(
        attribute="vscode_fqdn",
        env_var="VSCODE_FQDN",
        description="Public VS Code ingress host",
        getter=lambda settings: settings.vscode_fqdn,
        required=False,
        template_default="vscode.resolvefintech.com",
    ),
    SettingSpec(
        attribute="keycloak_admin_password",
        env_var="KEYCLOAK_ADMIN_PASSWORD",
        description="Admin password for namespace-local Keycloak",
        getter=lambda settings: settings.keycloak_admin_password,
        required=False,
        sensitive=True,
    ),
    SettingSpec(
        attribute="keycloak_postgres_password",
        env_var="KEYCLOAK_POSTGRES_PASSWORD",
        description="Password for namespace-local Keycloak Postgres",
        getter=lambda settings: settings.keycloak_postgres_password,
        required=False,
        sensitive=True,
    ),
    SettingSpec(
        attribute="keycloak_nginx_client_secret",
        env_var="KEYCLOAK_NGINX_CLIENT_SECRET",
        description="Shared OIDC client secret for nginx OIDC proxy and Keycloak",
        getter=lambda settings: settings.keycloak_nginx_client_secret,
        required=False,
        sensitive=True,
    ),
    SettingSpec(
        attribute="metallb_pool",
        env_var="METALLB_POOL",
        description="MetalLB IP address pool range",
        getter=lambda settings: settings.metallb_pool,
        required=False,
        template_default="192.168.1.240-192.168.1.250",
    ),
    SettingSpec(
        attribute="ingress_lb_ip",
        env_var="INGRESS_LB_IP",
        description="Reserved ingress LoadBalancer IP",
        getter=lambda settings: settings.ingress_lb_ip,
        required=False,
        template_default="192.168.1.240",
    ),
    SettingSpec(
        attribute="acme_email",
        env_var="ACME_EMAIL",
        description="Email for Let's Encrypt registration",
        getter=lambda settings: settings.acme_email,
        required=True,
        sensitive=True,
    ),
    SettingSpec(
        attribute="acme_server",
        env_var="ACME_SERVER",
        description="ACME server URL",
        getter=lambda settings: settings.acme_server,
        required=False,
        template_default="https://acme-v02.api.letsencrypt.org/directory",
    ),
    SettingSpec(
        attribute="pulumi_stack",
        env_var="PULUMI_STACK",
        description="Pulumi stack name",
        getter=lambda settings: settings.pulumi_stack,
        required=False,
        template_default="home",
    ),
    SettingSpec(
        attribute="bootstrap_public_ip_override",
        env_var="BOOTSTRAP_PUBLIC_IP_OVERRIDE",
        description="Bootstrap-only public IP override for DNS creation",
        getter=lambda settings: settings.bootstrap_public_ip_override,
        required=False,
    ),
)


def render_settings_template() -> str:
    """Render the deterministic `.env` template without instantiating settings."""
    return _render_template_from_specs()


def load_settings_mapping() -> dict[str, RenderedSettingValue]:
    """Load validated settings and return a plain typed mapping."""
    return Settings().to_mapping()


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
