"""Pydantic settings for prodbox configuration.

Configuration is loaded from ``prodbox-config.json`` (compiled from Dhall).
LAN addressing is always auto-discovered at runtime.
"""

from __future__ import annotations

import fcntl
import ipaddress
import json
import socket
import struct
import subprocess
from collections.abc import Callable
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field
from pydantic.functional_validators import model_validator

RenderedSettingValue = str | int | bool | Path | None

REPOSITORY_ROOT: Path = Path(__file__).resolve().parents[2]
_PROC_ROUTE_PATH: Path = Path("/proc/net/route")
_DEFAULT_METALLB_POOL_SIZE: int = 11
_DEFAULT_METALLB_POOL_OFFSET: int = 240
_IFREQ_SIZE: int = 256
_IFREQ_NAME_BYTES: int = 15
_SIOCGIFADDR: int = 0x8915
_SIOCGIFNETMASK: int = 0x891B
_REPO_DHALL_CONFIG_NAME: str = "prodbox-config.dhall"
_REPO_DHALL_SCHEMA_NAME: str = "prodbox-config-types.dhall"
_REPO_JSON_CONFIG_NAME: str = "prodbox-config.json"


@dataclass(frozen=True)
class LanAddressing:
    """Detected host LAN facts plus deterministic MetalLB defaults."""

    interface_name: str
    interface_ipv4: str
    network_cidr: str
    metallb_pool: str
    ingress_lb_ip: str


def _build_ifreq(interface_name: str) -> bytes:
    """Build a fixed-size ifreq buffer for ioctl lookups."""
    return struct.pack("256s", interface_name.encode("utf-8")[:_IFREQ_NAME_BYTES])


def _ioctl_ipv4_value(interface_name: str, request_code: int) -> str:
    """Read one IPv4 value from an interface via ioctl."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        packed = fcntl.ioctl(sock.fileno(), request_code, _build_ifreq(interface_name))
    return socket.inet_ntoa(packed[20:24])


def _default_route_interface_name() -> str:
    """Resolve the Linux default-route interface from `/proc/net/route`."""
    route_lines = _PROC_ROUTE_PATH.read_text(encoding="utf-8").splitlines()[1:]
    for line in route_lines:
        columns = line.split()
        if len(columns) < 4:
            continue
        interface_name = columns[0]
        destination = columns[1]
        flags = int(columns[3], 16)
        if destination == "00000000" and (flags & 0x2) != 0:
            return interface_name
    raise ValueError("could not determine the default-route interface from /proc/net/route")


def _select_metallb_range(
    *,
    network: ipaddress.IPv4Network,
    interface_ip: ipaddress.IPv4Address,
) -> tuple[str, str]:
    """Choose a deterministic MetalLB pool and ingress IP on the active subnet."""
    min_host = int(network.network_address) + 1
    max_host = int(network.broadcast_address) - 1
    if (max_host - min_host + 1) < _DEFAULT_METALLB_POOL_SIZE:
        raise ValueError(
            f"active subnet {network.with_prefixlen} is too small for the default MetalLB pool"
        )

    preferred_start = int(network.network_address) + _DEFAULT_METALLB_POOL_OFFSET
    preferred_end = preferred_start + _DEFAULT_METALLB_POOL_SIZE - 1
    interface_ip_int = int(interface_ip)
    if (
        preferred_start >= min_host
        and preferred_end <= max_host
        and not (preferred_start <= interface_ip_int <= preferred_end)
    ):
        start = preferred_start
        end = preferred_end
    else:
        end = max_host
        start = end - _DEFAULT_METALLB_POOL_SIZE + 1
        if start <= interface_ip_int <= end:
            end = interface_ip_int - 1
            start = end - _DEFAULT_METALLB_POOL_SIZE + 1
        if start < min_host:
            raise ValueError(
                "could not allocate a deterministic MetalLB range on the active subnet "
                f"{network.with_prefixlen}"
            )

    ingress_ip = str(ipaddress.IPv4Address(start))
    metallb_pool = f"{ipaddress.IPv4Address(start)}-{ipaddress.IPv4Address(end)}"
    return metallb_pool, ingress_ip


@lru_cache(maxsize=1)  # type: ignore[misc]  # lru_cache signature contains Callable[..., T]
def discover_lan_addressing() -> LanAddressing:
    """Detect the active LAN subnet and derive canonical MetalLB defaults."""
    interface_name = _default_route_interface_name()
    interface_ipv4 = _ioctl_ipv4_value(interface_name, _SIOCGIFADDR)
    interface_netmask = _ioctl_ipv4_value(interface_name, _SIOCGIFNETMASK)
    interface = ipaddress.IPv4Interface(f"{interface_ipv4}/{interface_netmask}")
    network = interface.network
    metallb_pool, ingress_lb_ip = _select_metallb_range(
        network=network,
        interface_ip=interface.ip,
    )
    return LanAddressing(
        interface_name=interface_name,
        interface_ipv4=str(interface.ip),
        network_cidr=network.with_prefixlen,
        metallb_pool=metallb_pool,
        ingress_lb_ip=ingress_lb_ip,
    )


def _discover_lan_addressing_or_none() -> LanAddressing | None:
    """Return LAN discovery results when available."""
    try:
        return discover_lan_addressing()
    except OSError:
        return None
    except ValueError:
        return None


def _canonical_repo_config_paths() -> tuple[Path, Path, Path]:
    """Return canonical repository-root Dhall, schema, and JSON config paths."""
    return (
        REPOSITORY_ROOT / _REPO_DHALL_CONFIG_NAME,
        REPOSITORY_ROOT / _REPO_DHALL_SCHEMA_NAME,
        REPOSITORY_ROOT / _REPO_JSON_CONFIG_NAME,
    )


def _normalized_path(path: Path) -> Path:
    """Resolve a path for stable repository-root equality checks."""
    return path.expanduser().resolve(strict=False)


def _is_canonical_repo_config_json(path: Path) -> bool:
    """Return whether *path* is the canonical repository-root JSON config."""
    _, _, canonical_json = _canonical_repo_config_paths()
    return _normalized_path(path) == _normalized_path(canonical_json)


def _canonical_compile_input_paths() -> tuple[Path, ...]:
    """Return existing Dhall inputs that define the canonical repository config."""
    dhall_path, schema_path, _ = _canonical_repo_config_paths()
    if not dhall_path.exists():
        return ()
    if schema_path.exists():
        return (dhall_path, schema_path)
    return (dhall_path,)


def _compile_repo_config_json(*, dhall_path: Path, json_path: Path) -> None:
    """Compile the canonical Dhall config to JSON in the repository root."""
    try:
        output = subprocess.run(
            ("dhall-to-json",),
            input=dhall_path.read_bytes(),
            capture_output=True,
            check=False,
            cwd=dhall_path.parent,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("dhall-to-json is required to compile prodbox-config.dhall") from exc

    if output.returncode != 0:
        stderr = output.stderr.decode("utf-8", errors="replace").strip()
        detail = stderr if stderr != "" else "dhall-to-json exited without stderr"
        raise ValueError(f"dhall-to-json failed while compiling {dhall_path.name}: {detail}")

    json_path.write_bytes(output.stdout)


def _ensure_repo_config_json_current(path: Path) -> None:
    """Compile the canonical JSON config when the repository Dhall inputs changed."""
    if not _is_canonical_repo_config_json(path):
        return

    compile_inputs = _canonical_compile_input_paths()
    if compile_inputs == ():
        return

    json_missing = not path.exists()
    json_mtime_ns = -1 if json_missing else path.stat().st_mtime_ns
    latest_input_mtime_ns = max(input_path.stat().st_mtime_ns for input_path in compile_inputs)
    if not json_missing and latest_input_mtime_ns <= json_mtime_ns:
        return

    dhall_path, _, json_path = _canonical_repo_config_paths()
    _compile_repo_config_json(dhall_path=dhall_path, json_path=json_path)


def _is_zerossl_acme_server(server: str) -> bool:
    """Return whether the ACME directory URL points at ZeroSSL."""
    return server.lower().startswith("https://acme.zerossl.com")


class Settings(BaseModel):
    """Central configuration for all prodbox operations.

    Configuration is loaded from ``prodbox-config.json`` (compiled from Dhall).
    Use ``prodbox config show`` to display effective configuration.
    """

    model_config = ConfigDict(extra="ignore")

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
            min_length=1,
            description="AWS access key ID from config",
        ),
    ]
    aws_secret_access_key: Annotated[
        str,
        Field(
            min_length=1,
            description="AWS secret access key from config",
        ),
    ]
    aws_session_token: Annotated[
        str | None,
        Field(
            default=None,
            description="Optional AWS session token from config",
        ),
    ]
    route53_zone_id: Annotated[
        str,
        Field(
            min_length=1,
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
    # === MetalLB / Ingress (auto-discovered) ===
    active_lan_interface: Annotated[
        str,
        Field(
            default="",
            description="Detected active LAN interface for auto-derived local edge defaults",
        ),
    ]
    active_lan_ipv4: Annotated[
        str,
        Field(
            default="",
            description="Detected active LAN IPv4 for auto-derived local edge defaults",
        ),
    ]
    active_lan_network_cidr: Annotated[
        str,
        Field(
            default="",
            description="Detected active LAN subnet for auto-derived local edge defaults",
        ),
    ]

    # === ACME / cert-manager ===
    acme_email: Annotated[
        str,
        Field(
            min_length=1,
            description="Email for public ACME registration",
        ),
    ]
    acme_server: Annotated[
        str,
        Field(
            default="https://acme-v02.api.letsencrypt.org/directory",
            description="ACME server URL",
        ),
    ]
    acme_eab_key_id: Annotated[
        str | None,
        Field(
            default=None,
            description="Optional ACME external account binding key ID",
        ),
    ]
    acme_eab_hmac_key: Annotated[
        str | None,
        Field(
            default=None,
            description="Optional ACME external account binding HMAC key",
        ),
    ]

    # === Deployment Mode ===
    prodbox_dev_mode: Annotated[
        bool,
        Field(
            default=True,
            description="Dev mode suppresses pod anti-affinity while retaining HA replica counts",
        ),
    ]

    # === Pulumi ===
    bootstrap_public_ip_override: Annotated[
        str | None,
        Field(
            default=None,
            description="Bootstrap-only public IP override for initial DNS record creation",
        ),
    ]
    pulumi_enable_dns_bootstrap: Annotated[
        bool,
        Field(
            default=True,
            description="Whether `prodbox pulumi up` manages Route 53 bootstrap records",
        ),
    ]

    @model_validator(mode="after")
    def derive_local_edge_defaults(self) -> Settings:
        """Populate adaptive LAN-derived defaults for the supported local-edge path."""
        discovered = _discover_lan_addressing_or_none()
        if discovered is not None:
            if self.active_lan_interface == "":
                self.active_lan_interface = discovered.interface_name
            if self.active_lan_ipv4 == "":
                self.active_lan_ipv4 = discovered.interface_ipv4
            if self.active_lan_network_cidr == "":
                self.active_lan_network_cidr = discovered.network_cidr
        return self

    @model_validator(mode="after")
    def validate_acme_eab_requirements(self) -> Settings:
        """Validate that ACME EAB configuration is internally consistent."""
        if _is_zerossl_acme_server(self.acme_server) and (
            self.acme_eab_key_id is None or self.acme_eab_hmac_key is None
        ):
            raise ValueError("acme.eab_key_id and acme.eab_hmac_key are required for ZeroSSL ACME")
        if (self.acme_eab_key_id is None) != (self.acme_eab_hmac_key is None):
            raise ValueError(
                "acme.eab_key_id and acme.eab_hmac_key must either both be set or both be empty"
            )
        return self

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
        """Render a deterministic config template for all supported settings."""
        return render_settings_template()

    @classmethod
    def from_config_json(cls, path: Path | None = None) -> Settings:
        """Construct Settings from canonical JSON, auto-compiling Dhall when needed."""
        resolved = path or (REPOSITORY_ROOT / "prodbox-config.json")
        config = load_config_json(resolved)
        flat = _flatten_config_json(config)
        return cls(**flat)


def _render_template_from_specs() -> str:
    """Render the deterministic template body from static setting metadata."""
    lines = [
        "# prodbox configuration template",
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
        lines.append(f"{spec.config_path}={spec.template_default or ''}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


SettingsGetter = Callable[[Settings], RenderedSettingValue]


@dataclass(frozen=True)
class SettingSpec:
    """Declarative metadata for deterministic display/template rendering."""

    attribute: str
    config_path: str
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
    if isinstance(value, bool):
        return "true" if value else "false"
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
        f"{spec.config_path}="
        f"{_format_rendered_value(settings_values.get(spec.attribute), sensitive=spec.sensitive, show_secrets=show_secrets)}"
        for spec in SETTING_SPECS
    ]
    return "\n".join(lines) + "\n"


SETTING_SPECS: tuple[SettingSpec, ...] = (
    SettingSpec(
        attribute="aws_region",
        config_path="aws.region",
        description="AWS region for Route 53",
        getter=lambda settings: settings.aws_region,
        required=False,
        template_default="us-east-1",
    ),
    SettingSpec(
        attribute="aws_access_key_id",
        config_path="aws.access_key_id",
        description="AWS access key ID",
        getter=lambda settings: settings.aws_access_key_id,
        required=True,
        sensitive=True,
    ),
    SettingSpec(
        attribute="aws_secret_access_key",
        config_path="aws.secret_access_key",
        description="AWS secret access key",
        getter=lambda settings: settings.aws_secret_access_key,
        required=True,
        sensitive=True,
    ),
    SettingSpec(
        attribute="aws_session_token",
        config_path="aws.session_token",
        description="Optional AWS session token",
        getter=lambda settings: settings.aws_session_token,
        required=False,
        sensitive=True,
    ),
    SettingSpec(
        attribute="route53_zone_id",
        config_path="route53.zone_id",
        description="Route 53 hosted zone ID",
        getter=lambda settings: settings.route53_zone_id,
        required=True,
    ),
    SettingSpec(
        attribute="demo_fqdn",
        config_path="domain.demo_fqdn",
        description="Fully qualified demo domain name",
        getter=lambda settings: settings.demo_fqdn,
        required=False,
        template_default="demo.example.com",
    ),
    SettingSpec(
        attribute="demo_ttl",
        config_path="domain.demo_ttl",
        description="DNS record TTL in seconds",
        getter=lambda settings: settings.demo_ttl,
        required=False,
        template_default="60",
    ),
    SettingSpec(
        attribute="vscode_fqdn",
        config_path="domain.vscode_fqdn",
        description="Public VS Code ingress host",
        getter=lambda settings: settings.vscode_fqdn,
        required=False,
        template_default="vscode.resolvefintech.com",
    ),
    SettingSpec(
        attribute="acme_email",
        config_path="acme.email",
        description="Email for public ACME registration",
        getter=lambda settings: settings.acme_email,
        required=True,
        sensitive=True,
    ),
    SettingSpec(
        attribute="acme_server",
        config_path="acme.server",
        description="ACME server URL",
        getter=lambda settings: settings.acme_server,
        required=False,
        template_default="https://acme-v02.api.letsencrypt.org/directory",
    ),
    SettingSpec(
        attribute="acme_eab_key_id",
        config_path="acme.eab_key_id",
        description="Optional ACME external account binding key ID",
        getter=lambda settings: settings.acme_eab_key_id,
        required=False,
    ),
    SettingSpec(
        attribute="acme_eab_hmac_key",
        config_path="acme.eab_hmac_key",
        description="Optional ACME external account binding HMAC key",
        getter=lambda settings: settings.acme_eab_hmac_key,
        required=False,
        sensitive=True,
    ),
    SettingSpec(
        attribute="prodbox_dev_mode",
        config_path="deployment.dev_mode",
        description="Dev mode suppresses pod anti-affinity while retaining HA replica counts",
        getter=lambda settings: settings.prodbox_dev_mode,
        required=False,
        template_default="true",
    ),
    SettingSpec(
        attribute="bootstrap_public_ip_override",
        config_path="deployment.bootstrap_public_ip_override",
        description="Bootstrap-only public IP override for DNS creation",
        getter=lambda settings: settings.bootstrap_public_ip_override,
        required=False,
    ),
    SettingSpec(
        attribute="pulumi_enable_dns_bootstrap",
        config_path="deployment.pulumi_enable_dns_bootstrap",
        description="Whether `prodbox pulumi up` should manage Route 53 bootstrap records",
        getter=lambda settings: settings.pulumi_enable_dns_bootstrap,
        required=False,
        template_default="true",
    ),
)


def render_settings_template() -> str:
    """Render the deterministic config template without instantiating settings."""
    return _render_template_from_specs()


def load_config_json(path: Path) -> dict[str, object]:
    """Load and parse ``prodbox-config.json`` into a typed mapping."""
    _ensure_repo_config_json_current(path)
    raw = path.read_text(encoding="utf-8")
    parsed: object = json.loads(raw)
    match parsed:
        case dict() as mapping:
            return {str(k): v for k, v in mapping.items()}
        case _:
            raise ValueError(f"{path} must contain a JSON object")


def _extract_dict(config: dict[str, object], key: str) -> dict[str, object]:
    """Extract a nested dict from *config* or raise ``ValueError``."""
    value = config.get(key)
    match value:
        case dict() as section:
            return {str(k): v for k, v in section.items()}
        case None:
            raise ValueError(f"config.{key} is missing")
        case _:
            raise ValueError(f"config.{key} must be a mapping")


def _flatten_config_json(config: dict[str, object]) -> dict[str, object]:
    """Map nested Dhall JSON structure to flat Settings field names."""
    aws = _extract_dict(config, "aws")
    route53 = _extract_dict(config, "route53")
    domain = _extract_dict(config, "domain")
    acme = _extract_dict(config, "acme")
    deployment = _extract_dict(config, "deployment")

    flat: dict[str, object] = {
        "aws_region": aws.get("region", "us-east-1"),
        "aws_access_key_id": aws.get("access_key_id", ""),
        "aws_secret_access_key": aws.get("secret_access_key", ""),
        "aws_session_token": aws.get("session_token"),
        "route53_zone_id": route53.get("zone_id", ""),
        "demo_fqdn": domain.get("demo_fqdn", "demo.example.com"),
        "demo_ttl": domain.get("demo_ttl", 60),
        "vscode_fqdn": domain.get("vscode_fqdn"),
        "acme_email": acme.get("email", ""),
        "acme_server": acme.get("server", "https://acme-v02.api.letsencrypt.org/directory"),
        "acme_eab_key_id": acme.get("eab_key_id"),
        "acme_eab_hmac_key": acme.get("eab_hmac_key"),
        "prodbox_dev_mode": deployment.get("dev_mode", True),
        "bootstrap_public_ip_override": deployment.get("bootstrap_public_ip_override"),
        "pulumi_enable_dns_bootstrap": deployment.get("pulumi_enable_dns_bootstrap", True),
    }
    return flat


def validate_config_json(path: Path) -> None:
    """Validate ``prodbox-config.json`` by loading it as a ``Settings`` instance.

    Raises ``ValueError`` or ``pydantic.ValidationError`` on failure.
    """
    Settings.from_config_json(path)


def load_settings_mapping() -> dict[str, RenderedSettingValue]:
    """Load validated settings from config JSON and return a plain typed mapping."""
    return Settings.from_config_json().to_mapping()


@lru_cache(maxsize=1)  # type: ignore[misc]  # lru_cache signature contains Callable[..., T]
def get_settings() -> Settings:
    """Get cached settings instance from compiled config JSON.

    Settings are parsed once and cached. Use clear_settings_cache()
    if you need to reload (e.g., in tests).

    Returns:
        Validated Settings instance
    """
    return Settings.from_config_json()


def clear_settings_cache() -> None:
    """Clear the settings cache. Useful for testing."""
    get_settings.cache_clear()
