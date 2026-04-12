"""Chart platform registry, planning helpers, and interpreter-boundary execution."""

from __future__ import annotations

import json
import re
import secrets as secrets_module
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from tempfile import NamedTemporaryFile

from prodbox.cli.types import Failure, Result, Success
from prodbox.lib.prodbox_k8s import prodbox_gateway_image_ref
from prodbox.lib.subprocess import run_command
from prodbox.settings import RenderedSettingValue

CHARTS_ROOT: Path = Path(__file__).resolve().parents[3] / "charts"
CHART_DATA_ROOT: Path = Path(__file__).resolve().parents[3] / ".data"
CHART_STORAGE_CLASS_NAME: str = "manual"
CHART_CLUSTER_ISSUER: str = "letsencrypt-http01"
KEYCLOAK_REALM_NAME: str = "prodbox"
KEYCLOAK_NGINX_CLIENT_ID: str = "vscode-nginx"
GATEWAY_NODE_IDS: tuple[str, ...] = ("node-a", "node-b", "node-c")

_CHART_SECRET_KEYS: tuple[str, ...] = (
    "keycloak_admin_password",
    "keycloak_postgres_password",
    "keycloak_nginx_client_secret",
)
_MACHINE_ID_PATH: Path = Path("/etc/machine-id")


def resolve_chart_secrets(namespace: str) -> dict[str, str]:
    """Resolve or auto-generate chart secrets from retained .data/ storage.

    On first deploy, generates random secrets and persists them under
    `.data/<namespace>/.secrets.json`. On subsequent deploys, reads the
    persisted secrets so credentials remain stable across teardown/rebuild.
    """
    secrets_path = CHART_DATA_ROOT / namespace / ".secrets.json"
    if secrets_path.exists():
        raw: object = json.loads(secrets_path.read_text(encoding="utf-8"))
        if isinstance(raw, dict):
            result: dict[str, str] = {}
            for key in _CHART_SECRET_KEYS:
                value = raw.get(key)
                if isinstance(value, str) and value.strip():
                    result[key] = value
            if len(result) == len(_CHART_SECRET_KEYS):
                return result
    generated = {key: secrets_module.token_urlsafe(24) for key in _CHART_SECRET_KEYS}
    secrets_path.parent.mkdir(parents=True, exist_ok=True)
    secrets_path.write_text(json.dumps(generated, indent=2) + "\n", encoding="utf-8")
    return generated


def resolve_gateway_event_keys(namespace: str) -> dict[str, str]:
    """Resolve or auto-generate per-node event signing keys for the gateway chart.

    Persisted under `.data/<namespace>/.gateway-event-keys.json` so the mesh
    keeps signing material stable across teardown/rebuild cycles. The file is
    independent of the keycloak secrets file because the gateway chart deploys
    into its own namespace and must not require keycloak fixtures.
    """
    secrets_path = CHART_DATA_ROOT / namespace / ".gateway-event-keys.json"
    if secrets_path.exists():
        raw: object = json.loads(secrets_path.read_text(encoding="utf-8"))
        if isinstance(raw, dict):
            existing: dict[str, str] = {}
            for node_id in GATEWAY_NODE_IDS:
                value = raw.get(node_id)
                if isinstance(value, str) and value.strip():
                    existing[node_id] = value
            if len(existing) == len(GATEWAY_NODE_IDS):
                return existing
    generated = {node_id: secrets_module.token_hex(32) for node_id in GATEWAY_NODE_IDS}
    secrets_path.parent.mkdir(parents=True, exist_ok=True)
    secrets_path.write_text(json.dumps(generated, indent=2) + "\n", encoding="utf-8")
    return generated


@dataclass(frozen=True)
class ChartStorageSpec:
    """One deterministic retained-storage requirement for a chart release."""

    statefulset_name: str
    persistent_volume_claim_name: str
    storage_size: str
    ordinal: int = 0
    claim_suffix: str = "data"


@dataclass(frozen=True)
class ChartStorageBinding:
    """Resolved retained-storage binding for one namespace-local StatefulSet ordinal."""

    statefulset_name: str
    release_name: str
    persistent_volume_name: str
    persistent_volume_claim_name: str
    storage_size: str
    host_path: Path
    ordinal: int
    claim_suffix: str


@dataclass(frozen=True)
class ChartDefinition:
    """Static registry definition for one supported bespoke chart."""

    name: str
    chart_dir: Path
    dependencies: tuple[str, ...]
    storage: tuple[ChartStorageSpec, ...] = ()
    requires_public_host: bool = False


@dataclass(frozen=True)
class ChartReleasePlan:
    """Resolved Helm release plan for one chart within a namespace-local stack."""

    chart_name: str
    release_name: str
    namespace: str
    chart_dir: Path
    values_json: str
    storage_bindings: tuple[ChartStorageBinding, ...]


@dataclass(frozen=True)
class ChartDeploymentPlan:
    """Resolved deployment/delete plan for one root chart stack."""

    root_chart: str
    namespace: str
    releases: tuple[ChartReleasePlan, ...]
    public_fqdn: str | None


@dataclass(frozen=True)
class ChartInstallSnapshot:
    """Observed Helm release installation state."""

    release_name: str
    namespace: str
    status: str


CHART_REGISTRY: Mapping[str, ChartDefinition] = {
    "keycloak-postgres": ChartDefinition(
        name="keycloak-postgres",
        chart_dir=CHARTS_ROOT / "keycloak-postgres",
        dependencies=(),
        storage=(
            ChartStorageSpec(
                statefulset_name="keycloak-postgres",
                persistent_volume_claim_name="keycloak-postgres-data-0",
                storage_size="20Gi",
            ),
        ),
    ),
    "keycloak": ChartDefinition(
        name="keycloak",
        chart_dir=CHARTS_ROOT / "keycloak",
        dependencies=("keycloak-postgres",),
        requires_public_host=True,
    ),
    "vscode": ChartDefinition(
        name="vscode",
        chart_dir=CHARTS_ROOT / "vscode",
        dependencies=("keycloak",),
        storage=(
            ChartStorageSpec(
                statefulset_name="vscode",
                persistent_volume_claim_name="vscode-data-0",
                storage_size="50Gi",
            ),
        ),
        requires_public_host=True,
    ),
    "gateway": ChartDefinition(
        name="gateway",
        chart_dir=CHARTS_ROOT / "gateway",
        dependencies=(),
        requires_public_host=True,
    ),
}


def supported_chart_names() -> tuple[str, ...]:
    """Return the canonical supported chart name list."""
    return tuple(CHART_REGISTRY.keys())


def resolve_chart(chart_name: str) -> Result[ChartDefinition, str]:
    """Resolve one supported chart definition."""
    definition = CHART_REGISTRY.get(chart_name)
    if definition is None:
        supported = ", ".join(supported_chart_names())
        return Failure(f"Unsupported chart '{chart_name}'. Supported charts: {supported}")
    return Success(definition)


def _resolve_dependency_order(chart_name: str) -> Result[tuple[str, ...], str]:
    """Resolve one chart's dependency closure in deploy order."""
    match resolve_chart(chart_name):
        case Failure(error):
            return Failure(error)
        case Success():
            pass

    ordered: list[str] = []
    visiting: set[str] = set()
    visited: set[str] = set()

    def _visit(name: str) -> Result[tuple[str, ...], str]:
        if name in visited:
            return Success(tuple(ordered))
        if name in visiting:
            return Failure(f"Chart dependency cycle detected at '{name}'")
        visiting.add(name)
        match resolve_chart(name):
            case Failure(error):
                return Failure(error)
            case Success(value=definition):
                for dependency in definition.dependencies:
                    match _visit(dependency):
                        case Failure(error):
                            return Failure(error)
                        case Success():
                            pass
        visiting.remove(name)
        visited.add(name)
        ordered.append(name)
        return Success(tuple(ordered))

    return _visit(chart_name)


def _require_string_setting(
    settings: Mapping[str, RenderedSettingValue],
    attribute: str,
    description: str,
) -> Result[str, str]:
    """Require one string setting from the rendered settings mapping."""
    match settings.get(attribute):
        case str() as value if value.strip():
            return Success(value)
        case _:
            return Failure(f"{description} is required for the chart platform")


def _resolve_public_fqdn(settings: Mapping[str, RenderedSettingValue]) -> Result[str, str]:
    """Resolve the canonical public host for the first externally exposed chart."""
    match settings.get("vscode_fqdn"):
        case str() as value if value.strip():
            return Success(value)
        case _:
            return _require_string_setting(settings, "demo_fqdn", "public FQDN")


def _storage_binding(
    namespace: str, release_name: str, spec: ChartStorageSpec
) -> ChartStorageBinding:
    """Resolve deterministic PV/PVC names and host paths for one chart storage spec.

    Uses the 5-segment path scheme: .data/<namespace>/<release>/<workload>/<ordinal>/<claim>
    """
    host_path = (
        CHART_DATA_ROOT
        / namespace
        / release_name
        / spec.statefulset_name
        / str(spec.ordinal)
        / spec.claim_suffix
    )
    persistent_volume_name = (
        f"prodbox-chart-{namespace}-{release_name}-"
        f"{spec.statefulset_name}-{spec.ordinal}-{spec.claim_suffix}"
    )
    return ChartStorageBinding(
        statefulset_name=spec.statefulset_name,
        release_name=release_name,
        persistent_volume_name=persistent_volume_name,
        persistent_volume_claim_name=spec.persistent_volume_claim_name,
        storage_size=spec.storage_size,
        host_path=host_path,
        ordinal=spec.ordinal,
        claim_suffix=spec.claim_suffix,
    )


def _replica_values(
    settings: Mapping[str, RenderedSettingValue], replica_count: int
) -> dict[str, object]:
    """Build chart replica values plus pod anti-affinity control."""
    dev_mode = settings.get("prodbox_dev_mode", True)
    anti_affinity_enabled = not dev_mode
    return {
        "replicaCount": replica_count,
        "podAntiAffinity": {"enabled": anti_affinity_enabled},
    }


def _values_for_keycloak_postgres(
    *,
    namespace: str,
    root_chart: str,
    settings: Mapping[str, RenderedSettingValue],
    chart_secrets: Mapping[str, str],
    binding: ChartStorageBinding,
) -> Result[dict[str, object], str]:
    """Build local values payload for the bespoke keycloak-postgres chart."""
    postgres_password = chart_secrets.get("keycloak_postgres_password", "")
    if not postgres_password:
        return Failure("keycloak_postgres_password is required in chart secrets")
    return Success(
        {
            # Plain Postgres with one retained PVC is a single-writer service.
            **_replica_values(settings, replica_count=1),
            "global": {
                "namespace": namespace,
                "rootChart": root_chart,
            },
            "postgres": {
                "database": "keycloak",
                "username": "keycloak",
                "password": postgres_password,
            },
            "persistence": {
                "existingClaim": binding.persistent_volume_claim_name,
                "size": binding.storage_size,
            },
        }
    )


def _values_for_keycloak(
    *,
    namespace: str,
    root_chart: str,
    settings: Mapping[str, RenderedSettingValue],
    chart_secrets: Mapping[str, str],
    public_fqdn: str,
) -> Result[dict[str, object], str]:
    """Build local values payload for the bespoke keycloak chart."""
    required_keys = (
        "keycloak_admin_password",
        "keycloak_postgres_password",
        "keycloak_nginx_client_secret",
    )
    for key in required_keys:
        if not chart_secrets.get(key, ""):
            return Failure(f"{key} is required in chart secrets")
    return Success(
        {
            **_replica_values(settings, replica_count=2),
            "global": {
                "namespace": namespace,
                "rootChart": root_chart,
            },
            "keycloak": {
                "adminUser": "admin",
                "adminPassword": chart_secrets["keycloak_admin_password"],
                "publicHost": public_fqdn,
                "relativePath": "/auth",
                "realmName": KEYCLOAK_REALM_NAME,
            },
            "postgres": {
                "host": "keycloak-postgres",
                "database": "keycloak",
                "username": "keycloak",
                "password": chart_secrets["keycloak_postgres_password"],
            },
            "nginx": {
                "clientId": KEYCLOAK_NGINX_CLIENT_ID,
                "clientSecret": chart_secrets["keycloak_nginx_client_secret"],
            },
        }
    )


def _values_for_gateway(
    *,
    namespace: str,
    root_chart: str,
    settings: Mapping[str, RenderedSettingValue],
    gateway_event_keys: Mapping[str, str],
    public_fqdn: str,
) -> Result[dict[str, object], str]:
    """Build local values payload for the in-cluster gateway chart."""
    if len(gateway_event_keys) == 0:
        return Failure("gateway chart requires non-empty event_keys")
    for node_id in GATEWAY_NODE_IDS:
        if node_id not in gateway_event_keys:
            return Failure(f"gateway chart event_keys missing entry for '{node_id}'")
    aws_access_key_id = settings.get("aws_access_key_id")
    aws_secret_access_key = settings.get("aws_secret_access_key")
    aws_session_token = settings.get("aws_session_token")
    aws_region = settings.get("aws_region")
    zone_id = settings.get("route53_zone_id")
    if not isinstance(aws_access_key_id, str) or aws_access_key_id == "":
        return Failure("gateway chart requires aws_access_key_id in settings")
    if not isinstance(aws_secret_access_key, str) or aws_secret_access_key == "":
        return Failure("gateway chart requires aws_secret_access_key in settings")
    if not isinstance(aws_region, str) or aws_region == "":
        return Failure("gateway chart requires aws_region in settings")
    if not isinstance(zone_id, str) or zone_id == "":
        return Failure("gateway chart requires route53_zone_id in settings")
    match _resolve_gateway_chart_image():
        case Failure(error):
            return Failure(error)
        case Success(value=(gateway_repository, gateway_tag)):
            pass
    session_token_value = aws_session_token if isinstance(aws_session_token, str) else ""
    return Success(
        {
            **_replica_values(settings, replica_count=len(GATEWAY_NODE_IDS)),
            "global": {
                "namespace": namespace,
                "rootChart": root_chart,
            },
            "image": {
                "repository": gateway_repository,
                "tag": gateway_tag,
                # `rke2 ensure` imports the machine-identity-tagged image into
                # local RKE2 containerd, so the chart should consume that
                # cached artifact instead of forcing a registry round-trip.
                "pullPolicy": "IfNotPresent",
            },
            "ports": {
                "rest": 8443,
                "events": 8444,
            },
            "timing": {
                "heartbeatIntervalSeconds": 0.5,
                "reconnectIntervalSeconds": 0.5,
                "syncIntervalSeconds": 1.0,
                "heartbeatTimeoutSeconds": 5,
            },
            "nodes": {
                "rankedIds": list(GATEWAY_NODE_IDS),
            },
            "eventKeys": {node_id: gateway_event_keys[node_id] for node_id in GATEWAY_NODE_IDS},
            "dnsWriteGate": {
                "enabled": True,
                "zoneId": zone_id,
                "fqdn": public_fqdn,
                "ttl": 60,
                "awsRegion": aws_region,
            },
            "aws": {
                "accessKeyId": aws_access_key_id,
                "secretAccessKey": aws_secret_access_key,
                "sessionToken": session_token_value,
            },
            "certManager": {
                "enabled": True,
                "caIssuerName": "gateway-ca-issuer",
                "caCertificateName": "gateway-ca",
                "caSecretName": "gateway-ca-tls",
                "caCommonName": "gateway-mesh-ca",
            },
        }
    )


def _resolve_gateway_chart_image() -> Result[tuple[str, str], str]:
    """Resolve the canonical Harbor image ref for the local machine identity."""
    if not _MACHINE_ID_PATH.exists():
        return Failure(f"gateway chart requires machine identity file {_MACHINE_ID_PATH}")
    machine_id = _MACHINE_ID_PATH.read_text(encoding="utf-8").strip().lower()
    if re.fullmatch(r"[0-9a-f]{32}", machine_id) is None:
        return Failure(f"Unexpected machine-id format in {_MACHINE_ID_PATH}: {machine_id!r}")
    image_ref = prodbox_gateway_image_ref(f"prodbox-{machine_id}")
    repository, tag = image_ref.rsplit(":", maxsplit=1)
    return Success((repository, tag))


def _values_for_vscode(
    *,
    namespace: str,
    root_chart: str,
    settings: Mapping[str, RenderedSettingValue],
    chart_secrets: Mapping[str, str],
    binding: ChartStorageBinding,
    public_fqdn: str,
) -> Result[dict[str, object], str]:
    """Build local values payload for the bespoke vscode chart."""
    nginx_secret = chart_secrets.get("keycloak_nginx_client_secret", "")
    if not nginx_secret:
        return Failure("keycloak_nginx_client_secret is required in chart secrets")
    return Success(
        {
            **_replica_values(settings, replica_count=1),
            "global": {
                "namespace": namespace,
                "rootChart": root_chart,
            },
            "ingress": {
                "host": public_fqdn,
                "clusterIssuer": CHART_CLUSTER_ISSUER,
            },
            "nginx": {
                "clientId": KEYCLOAK_NGINX_CLIENT_ID,
                "clientSecret": nginx_secret,
                "realm": KEYCLOAK_REALM_NAME,
                # Internal K8s service URL — reachable from within the cluster
                # regardless of whether the public FQDN resolves.
                "keycloakInternalUrl": "http://keycloak:8080",
                "image": "127.0.0.1:30080/prodbox/prodbox-nginx-oidc:latest",
            },
            "vscode": {
                "existingClaim": binding.persistent_volume_claim_name,
                "image": "codercom/code-server:4.98.2",
            },
        }
    )


def _render_release_values_json(
    *,
    definition: ChartDefinition,
    namespace: str,
    root_chart: str,
    settings: Mapping[str, RenderedSettingValue],
    chart_secrets: Mapping[str, str],
    gateway_event_keys: Mapping[str, str],
    storage_bindings: tuple[ChartStorageBinding, ...],
    public_fqdn: str | None,
) -> Result[str, str]:
    """Render stable JSON-as-YAML values for a local chart release."""
    match definition.name:
        case "keycloak-postgres":
            if len(storage_bindings) != 1:
                return Failure("keycloak-postgres requires exactly one storage binding")
            values_result = _values_for_keycloak_postgres(
                namespace=namespace,
                root_chart=root_chart,
                settings=settings,
                chart_secrets=chart_secrets,
                binding=storage_bindings[0],
            )
        case "keycloak":
            if public_fqdn is None:
                return Failure("keycloak requires a public host")
            values_result = _values_for_keycloak(
                namespace=namespace,
                root_chart=root_chart,
                settings=settings,
                chart_secrets=chart_secrets,
                public_fqdn=public_fqdn,
            )
        case "vscode":
            if public_fqdn is None:
                return Failure("vscode requires a public host")
            if len(storage_bindings) != 1:
                return Failure("vscode requires exactly one storage binding")
            values_result = _values_for_vscode(
                namespace=namespace,
                root_chart=root_chart,
                settings=settings,
                chart_secrets=chart_secrets,
                binding=storage_bindings[0],
                public_fqdn=public_fqdn,
            )
        case "gateway":
            if public_fqdn is None:
                return Failure("gateway requires a public host")
            values_result = _values_for_gateway(
                namespace=namespace,
                root_chart=root_chart,
                settings=settings,
                gateway_event_keys=gateway_event_keys,
                public_fqdn=public_fqdn,
            )
        case _:
            return Failure(f"Unsupported chart definition '{definition.name}'")

    match values_result:
        case Failure(error):
            return Failure(error)
        case Success(value=values):
            return Success(json.dumps(values, indent=2, sort_keys=True))


def build_chart_deployment_plan(
    chart_name: str,
    settings: Mapping[str, RenderedSettingValue],
    chart_secrets: Mapping[str, str] | None = None,
    *,
    gateway_event_keys: Mapping[str, str] | None = None,
) -> Result[ChartDeploymentPlan, str]:
    """Build a deterministic deployment plan for one supported root chart."""
    if CHART_STORAGE_CLASS_NAME != "manual":
        return Failure(
            f"Chart platform requires StorageClass 'manual' but found "
            f"'{CHART_STORAGE_CLASS_NAME}'; dynamic provisioners are not permitted"
        )
    namespace = chart_name
    match _resolve_dependency_order(chart_name):
        case Failure(error):
            return Failure(error)
        case Success(value=release_order):
            pass

    public_fqdn: str | None = None
    if any(CHART_REGISTRY[release_name].requires_public_host for release_name in release_order):
        match _resolve_public_fqdn(settings):
            case Failure(error):
                return Failure(error)
            case Success(value=value):
                public_fqdn = value

    resolved_secrets: Mapping[str, str] = chart_secrets if chart_secrets is not None else {}
    resolved_event_keys: Mapping[str, str] = (
        gateway_event_keys if gateway_event_keys is not None else {}
    )
    releases: list[ChartReleasePlan] = []
    for release_name in release_order:
        definition = CHART_REGISTRY[release_name]
        storage_bindings = tuple(
            _storage_binding(namespace, release_name, spec) for spec in definition.storage
        )
        match _render_release_values_json(
            definition=definition,
            namespace=namespace,
            root_chart=chart_name,
            settings=settings,
            chart_secrets=resolved_secrets,
            gateway_event_keys=resolved_event_keys,
            storage_bindings=storage_bindings,
            public_fqdn=public_fqdn,
        ):
            case Failure(error):
                return Failure(error)
            case Success(value=values_json):
                releases.append(
                    ChartReleasePlan(
                        chart_name=definition.name,
                        release_name=definition.name,
                        namespace=namespace,
                        chart_dir=definition.chart_dir,
                        values_json=values_json,
                        storage_bindings=storage_bindings,
                    )
                )

    return Success(
        ChartDeploymentPlan(
            root_chart=chart_name,
            namespace=namespace,
            releases=tuple(releases),
            public_fqdn=public_fqdn,
        )
    )


def build_chart_delete_plan(chart_name: str) -> Result[ChartDeploymentPlan, str]:
    """Build a deterministic delete plan for one supported root chart."""
    match _resolve_dependency_order(chart_name):
        case Failure(error):
            return Failure(error)
        case Success(value=release_order):
            reversed_order = tuple(reversed(release_order))

    releases = tuple(
        ChartReleasePlan(
            chart_name=release_name,
            release_name=release_name,
            namespace=chart_name,
            chart_dir=CHART_REGISTRY[release_name].chart_dir,
            values_json="{}",
            storage_bindings=tuple(
                _storage_binding(chart_name, release_name, spec)
                for spec in CHART_REGISTRY[release_name].storage
            ),
        )
        for release_name in reversed_order
    )
    return Success(
        ChartDeploymentPlan(
            root_chart=chart_name,
            namespace=chart_name,
            releases=releases,
            public_fqdn=None,
        )
    )


def _string_from_mapping(mapping: Mapping[str, object], key: str) -> str | None:
    """Extract one string value from a JSON-derived mapping."""
    match mapping.get(key):
        case str() as value:
            return value
        case _:
            return None


def _mapping_from_object(value: object, *, context: str) -> Mapping[str, object]:
    """Require a JSON-derived object to be a string-keyed mapping."""
    if not isinstance(value, dict):
        raise RuntimeError(f"Expected mapping for {context}")
    converted: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise RuntimeError(f"Expected string keys for {context}")
        converted[key] = item
    return converted


async def _helm_release_snapshots() -> Mapping[str, ChartInstallSnapshot]:
    """Return the current Helm release index keyed by release name."""
    result = await run_command(
        ["helm", "list", "--all-namespaces", "--output", "json"],
        check=False,
        timeout=30.0,
    )
    if result.returncode != 0:
        raise RuntimeError(f"helm list failed: {result.stderr or result.stdout}")
    parsed: object = json.loads(result.stdout)
    if not isinstance(parsed, list):
        raise RuntimeError("helm list returned unexpected JSON payload")
    snapshots: dict[str, ChartInstallSnapshot] = {}
    for item in parsed:
        mapping = _mapping_from_object(item, context="helm list entry")
        release_name = _string_from_mapping(mapping, "name")
        namespace = _string_from_mapping(mapping, "namespace")
        status = _string_from_mapping(mapping, "status")
        if release_name is None or namespace is None or status is None:
            raise RuntimeError("helm list entry missing name, namespace, or status")
        snapshots[release_name] = ChartInstallSnapshot(
            release_name=release_name,
            namespace=namespace,
            status=status,
        )
    return snapshots


async def _single_node_hostname() -> str:
    """Resolve the only supported node hostname for retained hostPath bindings."""
    result = await run_command(
        ["kubectl", "get", "nodes", "-o", "json"],
        check=False,
        timeout=30.0,
    )
    if result.returncode != 0:
        raise RuntimeError(f"kubectl get nodes failed: {result.stderr or result.stdout}")
    parsed: object = json.loads(result.stdout)
    mapping = _mapping_from_object(parsed, context="kubectl get nodes")
    items = mapping.get("items")
    if not isinstance(items, list) or len(items) != 1:
        raise RuntimeError("chart storage requires exactly one Kubernetes node")
    node_mapping = _mapping_from_object(items[0], context="node entry")
    metadata = _mapping_from_object(node_mapping.get("metadata"), context="node metadata")
    name = _string_from_mapping(metadata, "name")
    if name is None or name == "":
        raise RuntimeError("node metadata.name missing from kubectl get nodes")
    return name


async def _persistent_volume_phase(persistent_volume_name: str) -> str | None:
    """Read one PersistentVolume phase, or None when it does not yet exist."""
    result = await run_command(
        ["kubectl", "get", "pv", persistent_volume_name, "-o", "json"],
        check=False,
        timeout=30.0,
    )
    if result.returncode != 0:
        stderr = (result.stderr or result.stdout).lower()
        if "notfound" in stderr or "not found" in stderr:
            return None
        raise RuntimeError(
            "Failed to query PersistentVolume "
            f"{persistent_volume_name}: {result.stderr or result.stdout}"
        )
    parsed: object = json.loads(result.stdout)
    mapping = _mapping_from_object(parsed, context="persistent volume")
    status = _mapping_from_object(mapping.get("status"), context="persistent volume status")
    return _string_from_mapping(status, "phase")


async def _apply_manifest(manifest: Mapping[str, object]) -> None:
    """Apply one JSON-as-YAML manifest via kubectl."""
    result = await run_command(
        ["kubectl", "apply", "-f", "-"],
        check=False,
        timeout=60.0,
        input_data=json.dumps(manifest).encode("utf-8"),
    )
    if result.returncode != 0:
        raise RuntimeError(f"kubectl apply failed: {result.stderr or result.stdout}")


async def _delete_kubectl_object(*args: str) -> None:
    """Delete one Kubernetes object idempotently."""
    result = await run_command(
        ["kubectl", *args],
        check=False,
        timeout=120.0,
    )
    if result.returncode != 0:
        stderr = (result.stderr or result.stdout).lower()
        if "notfound" in stderr or "not found" in stderr:
            return
        raise RuntimeError(f"kubectl {' '.join(args)} failed: {result.stderr or result.stdout}")


def _chart_storage_manifest(
    *,
    namespace: str,
    root_chart: str,
    bindings: tuple[ChartStorageBinding, ...],
    node_hostname: str,
) -> Mapping[str, object]:
    """Build one applyable storage manifest for a namespace-local chart stack."""
    items: list[object] = [
        {
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": {
                "name": namespace,
                "labels": {
                    "prodbox.io/chart-root": root_chart,
                },
            },
        },
        {
            "apiVersion": "storage.k8s.io/v1",
            "kind": "StorageClass",
            "metadata": {
                "name": CHART_STORAGE_CLASS_NAME,
                "labels": {
                    "prodbox.io/chart-platform": "true",
                },
            },
            "provisioner": "kubernetes.io/no-provisioner",
            "reclaimPolicy": "Retain",
            "volumeBindingMode": "WaitForFirstConsumer",
            "allowVolumeExpansion": True,
        },
    ]
    for binding in bindings:
        items.extend(
            [
                {
                    "apiVersion": "v1",
                    "kind": "PersistentVolume",
                    "metadata": {
                        "name": binding.persistent_volume_name,
                        "labels": {
                            "prodbox.io/chart-root": root_chart,
                            "prodbox.io/chart-namespace": namespace,
                            "prodbox.io/statefulset": binding.statefulset_name,
                        },
                    },
                    "spec": {
                        "capacity": {"storage": binding.storage_size},
                        "volumeMode": "Filesystem",
                        "accessModes": ["ReadWriteOnce"],
                        "persistentVolumeReclaimPolicy": "Retain",
                        "storageClassName": CHART_STORAGE_CLASS_NAME,
                        "claimRef": {
                            "namespace": namespace,
                            "name": binding.persistent_volume_claim_name,
                        },
                        "hostPath": {
                            "path": str(binding.host_path),
                            "type": "DirectoryOrCreate",
                        },
                        "nodeAffinity": {
                            "required": {
                                "nodeSelectorTerms": [
                                    {
                                        "matchExpressions": [
                                            {
                                                "key": "kubernetes.io/hostname",
                                                "operator": "In",
                                                "values": [node_hostname],
                                            }
                                        ]
                                    }
                                ]
                            }
                        },
                    },
                },
                {
                    "apiVersion": "v1",
                    "kind": "PersistentVolumeClaim",
                    "metadata": {
                        "name": binding.persistent_volume_claim_name,
                        "namespace": namespace,
                        "labels": {
                            "prodbox.io/chart-root": root_chart,
                            "prodbox.io/statefulset": binding.statefulset_name,
                        },
                    },
                    "spec": {
                        "accessModes": ["ReadWriteOnce"],
                        "volumeMode": "Filesystem",
                        "storageClassName": CHART_STORAGE_CLASS_NAME,
                        "volumeName": binding.persistent_volume_name,
                        "resources": {"requests": {"storage": binding.storage_size}},
                    },
                },
            ]
        )
    return {
        "apiVersion": "v1",
        "kind": "List",
        "items": items,
    }


async def _ensure_chart_storage(plan: ChartDeploymentPlan) -> None:
    """Reconcile deterministic retained storage for one namespace-local chart stack."""
    all_bindings = tuple(
        binding for release in plan.releases for binding in release.storage_bindings
    )
    if not all_bindings:
        manifest = {
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": {
                "name": plan.namespace,
                "labels": {
                    "prodbox.io/chart-root": plan.root_chart,
                },
            },
        }
        await _apply_manifest(manifest)
        return

    node_hostname = await _single_node_hostname()
    for binding in all_bindings:
        binding.host_path.mkdir(parents=True, exist_ok=True)
        phase = await _persistent_volume_phase(binding.persistent_volume_name)
        if phase in ("Released", "Failed"):
            await _delete_kubectl_object(
                "delete",
                "pv",
                binding.persistent_volume_name,
                "--ignore-not-found=true",
                "--wait=true",
            )
    await _apply_manifest(
        _chart_storage_manifest(
            namespace=plan.namespace,
            root_chart=plan.root_chart,
            bindings=all_bindings,
            node_hostname=node_hostname,
        )
    )


async def _helm_upgrade_install(release: ChartReleasePlan) -> None:
    """Run one deterministic local-chart Helm upgrade/install."""
    with NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        prefix=f"{release.release_name}-",
        suffix=".json",
        delete=False,
    ) as values_file:
        values_file.write(release.values_json)
        values_path = Path(values_file.name)
    try:
        result = await run_command(
            [
                "helm",
                "upgrade",
                "--install",
                "--wait",
                "--atomic",
                "--timeout",
                "30m0s",
                release.release_name,
                str(release.chart_dir),
                "--namespace",
                release.namespace,
                "--create-namespace",
                "--values",
                str(values_path),
            ],
            check=False,
            timeout=1860.0,
        )
    finally:
        values_path.unlink(missing_ok=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"helm upgrade --install {release.release_name} failed: {result.stderr or result.stdout}"
        )


def _render_storage_report(bindings: tuple[ChartStorageBinding, ...]) -> tuple[str, ...]:
    """Render deterministic retained-storage report lines."""
    lines: list[str] = []
    for binding in bindings:
        lines.extend(
            [
                "STORAGE_BINDING",
                f"RELEASE={binding.release_name}",
                f"STATEFULSET={binding.statefulset_name}",
                f"ORDINAL={binding.ordinal}",
                f"CLAIM={binding.claim_suffix}",
                f"PV={binding.persistent_volume_name}",
                f"PVC={binding.persistent_volume_claim_name}",
                f"HOST_PATH={binding.host_path}",
            ]
        )
    return tuple(lines)


def _render_deploy_report(plan: ChartDeploymentPlan) -> str:
    """Render a deterministic deploy report."""
    lines = [
        "CHART_DEPLOYMENT",
        f"ROOT_CHART={plan.root_chart}",
        f"NAMESPACE={plan.namespace}",
    ]
    if plan.public_fqdn is not None:
        lines.append(f"PUBLIC_FQDN={plan.public_fqdn}")
    for release in plan.releases:
        lines.extend(
            [
                "RELEASE",
                f"NAME={release.release_name}",
                f"CHART={release.chart_name}",
                f"CHART_PATH={release.chart_dir}",
            ]
        )
        lines.extend(_render_storage_report(release.storage_bindings))
    return "\n".join(lines)


def _render_delete_report(plan: ChartDeploymentPlan) -> str:
    """Render a deterministic delete report."""
    lines = [
        "CHART_DELETION",
        f"ROOT_CHART={plan.root_chart}",
        f"NAMESPACE={plan.namespace}",
        "HOST_STORAGE_PRESERVED=true",
    ]
    for release in plan.releases:
        lines.extend(
            [
                "RELEASE",
                f"NAME={release.release_name}",
                f"CHART={release.chart_name}",
            ]
        )
        lines.extend(_render_storage_report(release.storage_bindings))
    return "\n".join(lines)


async def deploy_chart_plan(plan: ChartDeploymentPlan) -> str:
    """Deploy one namespace-local chart stack with deterministic retained storage."""
    snapshots = await _helm_release_snapshots()
    duplicates = sorted(
        release.release_name for release in plan.releases if release.release_name in snapshots
    )
    if duplicates:
        raise RuntimeError(
            "Chart singleton violation. Existing releases already installed: "
            + ", ".join(duplicates)
        )
    await _ensure_chart_storage(plan)
    for release in plan.releases:
        await _helm_upgrade_install(release)
    return _render_deploy_report(plan)


async def delete_chart_plan(plan: ChartDeploymentPlan) -> str:
    """Delete one namespace-local chart stack while preserving repo-local host storage."""
    for release in plan.releases:
        result = await run_command(
            ["helm", "uninstall", release.release_name, "--namespace", release.namespace],
            check=False,
            timeout=180.0,
        )
        if result.returncode != 0:
            stderr = (result.stderr or result.stdout).lower()
            if "not found" not in stderr and "release: not found" not in stderr:
                raise RuntimeError(
                    f"helm uninstall {release.release_name} failed: {result.stderr or result.stdout}"
                )
    for release in plan.releases:
        for binding in release.storage_bindings:
            await _delete_kubectl_object(
                "delete",
                "pvc",
                binding.persistent_volume_claim_name,
                "--namespace",
                plan.namespace,
                "--ignore-not-found=true",
                "--wait=true",
            )
            await _delete_kubectl_object(
                "delete",
                "pv",
                binding.persistent_volume_name,
                "--ignore-not-found=true",
                "--wait=true",
            )
    await _delete_kubectl_object(
        "delete",
        "namespace",
        plan.namespace,
        "--ignore-not-found=true",
        "--wait=true",
    )
    return _render_delete_report(plan)


async def render_chart_list(settings: Mapping[str, RenderedSettingValue]) -> str:
    """Render the supported-chart matrix plus observed Helm installation state."""
    snapshots = await _helm_release_snapshots()
    public_fqdn_result = _resolve_public_fqdn(settings)
    public_fqdn = public_fqdn_result.value if isinstance(public_fqdn_result, Success) else ""
    lines = ["CHART_LIST"]
    for chart_name in supported_chart_names():
        snapshot = snapshots.get(chart_name)
        definition = CHART_REGISTRY[chart_name]
        dependencies = ",".join(definition.dependencies) if definition.dependencies else "<none>"
        status = snapshot.status if snapshot is not None else "not-installed"
        namespace = snapshot.namespace if snapshot is not None else "<none>"
        lines.extend(
            [
                "CHART",
                f"NAME={chart_name}",
                f"STATUS={status}",
                f"NAMESPACE={namespace}",
                f"DEPENDENCIES={dependencies}",
            ]
        )
        if definition.requires_public_host and public_fqdn != "":
            lines.append(f"PUBLIC_FQDN={public_fqdn}")
    return "\n".join(lines)


async def render_chart_status(
    chart_name: str,
    settings: Mapping[str, RenderedSettingValue],
) -> str:
    """Render one supported chart status report."""
    snapshots = await _helm_release_snapshots()
    installed_snapshot = snapshots.get(chart_name)
    runtime_namespace = (
        installed_snapshot.namespace if installed_snapshot is not None else chart_name
    )
    runtime_root_chart = runtime_namespace
    chart_secrets = resolve_chart_secrets(runtime_root_chart)
    gateway_event_keys = resolve_gateway_event_keys(runtime_root_chart)
    match build_chart_deployment_plan(
        runtime_root_chart,
        settings,
        chart_secrets,
        gateway_event_keys=gateway_event_keys,
    ):
        case Failure(error):
            raise RuntimeError(error)
        case Success(value=root_plan):
            pass

    release_map = {release.release_name: release for release in root_plan.releases}
    if chart_name not in release_map:
        raise RuntimeError(f"Chart '{chart_name}' is not part of root plan '{runtime_root_chart}'")
    definition = CHART_REGISTRY[chart_name]
    chart_release = release_map[chart_name]
    lines = [
        "CHART_STATUS",
        f"NAME={chart_name}",
        f"STATUS={installed_snapshot.status if installed_snapshot is not None else 'not-installed'}",
        f"ROOT_CHART={runtime_root_chart}",
        f"NAMESPACE={runtime_namespace}",
        f"DEPENDENCIES={','.join(definition.dependencies) if definition.dependencies else '<none>'}",
    ]
    if root_plan.public_fqdn is not None and definition.requires_public_host:
        lines.append(f"PUBLIC_FQDN={root_plan.public_fqdn}")
    for release in root_plan.releases:
        if release.release_name == chart_name or release.release_name in definition.dependencies:
            snapshot = snapshots.get(release.release_name)
            lines.extend(
                [
                    "RELEASE",
                    f"NAME={release.release_name}",
                    f"CHART={release.chart_name}",
                    f"STATUS={snapshot.status if snapshot is not None else 'not-installed'}",
                    f"NAMESPACE={snapshot.namespace if snapshot is not None else runtime_namespace}",
                ]
            )
    lines.extend(_render_storage_report(chart_release.storage_bindings))
    return "\n".join(lines)


__all__ = [
    "CHARTS_ROOT",
    "CHART_DATA_ROOT",
    "CHART_STORAGE_CLASS_NAME",
    "ChartDefinition",
    "ChartDeploymentPlan",
    "ChartInstallSnapshot",
    "ChartReleasePlan",
    "ChartStorageBinding",
    "ChartStorageSpec",
    "GATEWAY_NODE_IDS",
    "KEYCLOAK_NGINX_CLIENT_ID",
    "KEYCLOAK_REALM_NAME",
    "build_chart_delete_plan",
    "build_chart_deployment_plan",
    "delete_chart_plan",
    "deploy_chart_plan",
    "render_chart_list",
    "render_chart_status",
    "resolve_chart",
    "resolve_chart_secrets",
    "resolve_gateway_event_keys",
    "supported_chart_names",
]
