"""DAG builders for converting Command ADTs to Effect DAGs.

This module provides functions that convert Command ADTs into Effect DAGs
using exhaustive pattern matching. This separation enables:

1. Pure transformation: Command -> Effect DAG (no side effects)
2. Single source of truth for command->DAG mapping
3. Testable: DAG structure can be verified without execution
4. Type-safe: Pattern matching ensures all commands handled

Architecture:
    Command (ADT) -> command_to_dag() -> EffectDAG -> Interpreter

Usage:
    from prodbox.cli.dag_builders import command_to_dag

    match command_to_dag(my_command):
        case Success(dag):
            result = interpreter.execute_dag(dag)
        case Failure(error):
            return error  # Propagate error up to command entry point
"""

from __future__ import annotations

import json
from pathlib import Path

from prodbox.cli.command_adt import (
    ChartDeleteCommand,
    ChartDeployCommand,
    ChartListCommand,
    ChartStatusCommand,
    Command,
    ConfigCompileCommand,
    ConfigInitCommand,
    ConfigShowCommand,
    ConfigValidateCommand,
    DNSCheckCommand,
    GatewayConfigGenCommand,
    GatewayStartCommand,
    GatewayStatusCommand,
    HostCheckPortsCommand,
    HostEnsureToolsCommand,
    HostFirewallCommand,
    HostInfoCommand,
    HostPublicEdgeCommand,
    K8sHealthCommand,
    K8sLogsCommand,
    K8sWaitCommand,
    PulumiDestroyCommand,
    PulumiPreviewCommand,
    PulumiRefreshCommand,
    PulumiStackInitCommand,
    PulumiUpCommand,
    RKE2CleanupCommand,
    RKE2EnsureCommand,
    RKE2LogsCommand,
    RKE2RestartCommand,
    RKE2StartCommand,
    RKE2StatusCommand,
    RKE2StopCommand,
)
from prodbox.cli.effect_dag import EffectDAG, EffectNode, PrerequisiteFailurePolicy
from prodbox.cli.effects import (
    AnnotateProdboxManagedResources,
    CaptureKubectlOutput,
    CaptureSubprocessOutput,
    ChartDeleteEffect,
    ChartDeployEffect,
    ChartListEffect,
    ChartStatusEffect,
    CheckPortAvailability,
    CheckServiceStatus,
    CleanupProdboxAnnotatedResources,
    Custom,
    EnsureHarborRegistry,
    EnsureMinio,
    EnsureProdboxIdentityConfigMap,
    EnsureRetainedLocalStorage,
    EnsureRke2IngressController,
    FetchPublicIP,
    GenerateGatewayConfig,
    GetJournalLogs,
    KubectlWait,
    MachineIdentity,
    Parallel,
    PortAvailability,
    PulumiDestroy,
    PulumiPreview,
    PulumiRefresh,
    PulumiStackSelect,
    PulumiUp,
    QueryGatewayState,
    QueryRoute53Record,
    RunDhallCompile,
    RunKubectlCommand,
    RunPulumiCommand,
    RunSystemdCommand,
    Sequence,
    StartGatewayDaemon,
    ValidateConfigJson,
    ValidateSettings,
    ValidateTool,
    WriteFile,
    WriteStdout,
)
from prodbox.cli.prerequisite_registry import PREREQUISITE_REGISTRY
from prodbox.cli.types import Failure, PrereqResults, Result, Success
from prodbox.lib.prodbox_k8s import (
    HARBOR_GATEWAY_REPOSITORY,
    HARBOR_HELM_RELEASE,
    HARBOR_HELM_REPOSITORY_NAME,
    HARBOR_HELM_REPOSITORY_URL,
    HARBOR_MIRROR_PROJECT,
    HARBOR_NAMESPACE,
    HARBOR_REGISTRY_ENDPOINT,
    MINIO_HELM_CHART_REF,
    MINIO_HELM_CHART_VERSION,
    MINIO_HELM_RELEASE,
    MINIO_HELM_REPOSITORY_NAME,
    MINIO_HELM_REPOSITORY_URL,
    MINIO_NAMESPACE,
    MINIO_PERSISTENT_CLAIM,
    MINIO_PERSISTENT_VOLUME,
    MINIO_STORAGE_SIZE,
    PRODBOX_ANNOTATION_KEY,
    PRODBOX_HELM_INSTANCES,
    PRODBOX_IDENTITY_CONFIGMAP,
    PRODBOX_LABEL_KEY,
    PRODBOX_MANAGED_NAMESPACES,
    PRODBOX_NAMESPACE,
    PRODBOX_STORAGE_BASE_PATH,
    PRODBOX_STORAGE_CLASS,
    PRODBOX_STORAGE_RETAINED_RESOURCES,
    RKE2_DATA_PATHS,
    RKE2_REGISTRIES_PATH,
    prodbox_id_to_label_value,
)
from prodbox.settings import (
    REPOSITORY_ROOT,
    RenderedSettingValue,
    discover_lan_addressing,
    render_settings_display,
)

# =============================================================================
# Shared Helpers
# =============================================================================


def _discovered_metallb_pool() -> str:
    """Return the auto-discovered MetalLB pool from the active LAN."""
    return discover_lan_addressing().metallb_pool


def _discovered_ingress_lb_ip() -> str:
    """Return the auto-discovered ingress LB IP from the active LAN."""
    return discover_lan_addressing().ingress_lb_ip


def _require_machine_identity(prereq_results: PrereqResults) -> MachineIdentity:
    """Extract machine identity prerequisite result or raise ValueError."""
    result = prereq_results.get("machine_identity")
    match result:
        case Success(value=value):
            match value:
                case MachineIdentity() as machine_identity:
                    return machine_identity
                case _:
                    raise ValueError("machine_identity prerequisite returned unexpected value type")
        case Failure(error=error):
            raise ValueError(f"machine_identity prerequisite failed: {error}")
        case _:
            raise ValueError("machine_identity prerequisite missing")


def _require_settings(prereq_results: PrereqResults) -> dict[str, RenderedSettingValue]:
    """Extract loaded settings prerequisite result or raise ValueError."""
    result = prereq_results.get("settings_object")
    match result:
        case Success(value=dict() as settings):
            return settings
        case Success(value=_):
            raise ValueError("settings_object prerequisite returned unexpected value type")
        case Failure(error=error):
            raise ValueError(f"settings_object prerequisite failed: {error}")
        case _:
            raise ValueError("settings_object prerequisite missing")


def _require_setting_string(settings: dict[str, RenderedSettingValue], field_name: str) -> str:
    """Extract one required string field from loaded settings."""
    match settings.get(field_name):
        case str() as value:
            return value
        case _:
            raise ValueError(f"settings field {field_name} missing or not a string")


def _optional_setting_string(
    settings: dict[str, RenderedSettingValue], field_name: str
) -> str | None:
    """Extract one optional string field from loaded settings."""
    match settings.get(field_name):
        case str() as value if value != "":
            return value
        case "" | None:
            return None
        case _:
            raise ValueError(f"settings field {field_name} missing or not a string")


def _require_setting_bool(settings: dict[str, RenderedSettingValue], field_name: str) -> bool:
    """Extract one required boolean field from loaded settings."""
    match settings.get(field_name):
        case bool() as value:
            return value
        case _:
            raise ValueError(f"settings field {field_name} missing or not a bool")


def _require_string_result(prereq_results: PrereqResults, effect_id: str) -> str:
    """Extract one string-valued prerequisite result or raise ValueError."""
    result = prereq_results.get(effect_id)
    match result:
        case Success(value=str() as value):
            return value
        case Success(value=_):
            raise ValueError(f"{effect_id} prerequisite returned unexpected value type")
        case Failure(error=error):
            raise ValueError(f"{effect_id} prerequisite failed: {error}")
        case _:
            raise ValueError(f"{effect_id} prerequisite missing")


def _require_port_results(
    prereq_results: PrereqResults, effect_id: str
) -> tuple[PortAvailability, ...]:
    """Extract one port-availability result tuple or raise ValueError."""
    result = prereq_results.get(effect_id)
    match result:
        case Success(value=tuple() as values):
            match all(isinstance(value, PortAvailability) for value in values):
                case True:
                    return values
                case False:
                    raise ValueError(f"{effect_id} prerequisite returned unexpected value type")
        case Success(value=_):
            raise ValueError(f"{effect_id} prerequisite returned unexpected value type")
        case Failure(error=error):
            raise ValueError(f"{effect_id} prerequisite failed: {error}")
        case _:
            raise ValueError(f"{effect_id} prerequisite missing")


def _optional_string_result(prereq_results: PrereqResults, effect_id: str) -> str | None:
    """Extract one optional string-valued prerequisite result or raise ValueError."""
    result = prereq_results.get(effect_id)
    match result:
        case Success(value=value):
            match value:
                case None:
                    return None
                case str() as string_value:
                    return string_value
                case _:
                    raise ValueError(f"{effect_id} prerequisite returned unexpected value type")
        case Failure(error=error):
            raise ValueError(f"{effect_id} prerequisite failed: {error}")
        case _:
            raise ValueError(f"{effect_id} prerequisite missing")


def _require_object_result(prereq_results: PrereqResults, effect_id: str) -> object:
    """Extract one arbitrary prerequisite value or raise ValueError."""
    result = prereq_results.get(effect_id)
    match result:
        case Success(value=value):
            return value
        case Failure(error=error):
            raise ValueError(f"{effect_id} prerequisite failed: {error}")
        case _:
            raise ValueError(f"{effect_id} prerequisite missing")


def _merge_registry(*nodes: EffectNode[object]) -> dict[str, EffectNode[object]]:
    """Merge local command-specific nodes into the canonical prerequisite registry."""
    return dict(PREREQUISITE_REGISTRY) | {node.effect_id: node for node in nodes}


def _parse_json_mapping(text: str) -> dict[str, object]:
    """Parse a JSON object string into a typed mapping."""
    parsed: object = json.loads(text)
    match parsed:
        case dict() as parsed_mapping:
            typed_mapping: dict[object, object] = parsed_mapping
            return {str(key): value for key, value in typed_mapping.items()}
        case _:
            raise ValueError("expected kubectl JSON object output")


def _render_dns_check_report(
    *,
    settings: dict[str, RenderedSettingValue],
    public_ip: str,
    current_record_ip: str | None,
) -> str:
    """Render deterministic DNS status output."""
    fqdn = _require_setting_string(settings, "demo_fqdn")
    status = (
        "in-sync"
        if current_record_ip == public_ip
        else "record-missing"
        if current_record_ip is None
        else "mismatch"
    )
    current_value = current_record_ip if current_record_ip is not None else "<missing>"
    return "\n".join(
        [
            "DNS status",
            f"FQDN={fqdn}",
            f"PUBLIC_IP={public_ip}",
            f"ROUTE53_A_RECORD={current_value}",
            f"STATUS={status}",
        ]
    )


def _render_host_check_ports_report(results: tuple[PortAvailability, ...]) -> str:
    """Render deterministic host port availability output."""
    unavailable = tuple(str(result.port) for result in results if not result.available)
    summary_line = (
        f"Ports unavailable: {', '.join(unavailable)}"
        if unavailable
        else "Ports available: " + ", ".join(str(result.port) for result in results)
    )
    lines = ["Host port check"]
    lines.extend(
        [
            (
                f"PORT={result.port} "
                f"AVAILABLE={'true' if result.available else 'false'} "
                f"DETAIL={result.detail}"
            )
            for result in results
        ]
    )
    lines.append(summary_line)
    lines.append(f"STATUS={'busy' if unavailable else 'available'}")
    return "\n".join(lines)


def _as_json_mapping(value: object) -> dict[str, object] | None:
    """Return a JSON-like mapping when the input is compatible."""
    match value:
        case dict() as mapping:
            return {str(key): item for key, item in mapping.items()}
        case _:
            return None


def _mapping_at(value: dict[str, object], key: str) -> dict[str, object] | None:
    """Read one nested mapping from a JSON-like object."""
    nested = value.get(key)
    return _as_json_mapping(nested)


def _sequence_at(value: dict[str, object], key: str) -> tuple[object, ...]:
    """Read one nested JSON sequence from a mapping."""
    match value.get(key):
        case list() as nested:
            return tuple(nested)
        case _:
            return ()


def _string_at(value: dict[str, object], key: str) -> str | None:
    """Read one optional string field from a mapping."""
    match value.get(key):
        case str() as nested if nested != "":
            return nested
        case _:
            return None


def _bool_condition_status(conditions: tuple[dict[str, object], ...], condition_type: str) -> str:
    """Read one Kubernetes condition value by type."""
    return next(
        (
            _string_at(condition, "status") or "Unknown"
            for condition in conditions
            if _string_at(condition, "type") == condition_type
        ),
        "Unknown",
    )


def _render_gateway_status_report(state: dict[str, object]) -> str:
    """Render deterministic gateway status output."""
    mesh_peers_obj = state.get("mesh_peers")
    mesh_peers = (
        ",".join(str(peer) for peer in mesh_peers_obj)
        if isinstance(mesh_peers_obj, list) and len(mesh_peers_obj) > 0
        else "<none>"
    )
    heartbeat_mapping = _as_json_mapping(state.get("heartbeat_age_seconds")) or {}
    heartbeat_lines = [
        f"HEARTBEAT_{node_id.upper().replace('-', '_')}=" f"{heartbeat_mapping[node_id]}"
        for node_id in sorted(heartbeat_mapping)
    ]
    dns_gate = _mapping_at(state, "dns_write_gate")
    return "\n".join(
        [
            "Gateway status",
            f"NODE_ID={state.get('node_id', '<unknown>')}",
            f"GATEWAY_OWNER={state.get('gateway_owner', '<unknown>')}",
            f"ACTIVE_CLAIM={'true' if bool(state.get('has_active_claim')) else 'false'}",
            f"MESH_PEERS={mesh_peers}",
            f"EVENT_COUNT={state.get('event_count', 0)}",
            f"LAST_PUBLIC_IP={state.get('last_public_ip_observed') or '<unknown>'}",
            f"LAST_DNS_WRITE_IP={state.get('last_dns_write_ip') or '<none>'}",
            f"LAST_DNS_WRITE_AT={state.get('last_dns_write_at_utc') or '<none>'}",
            "DNS_WRITE_GATE="
            + (
                "<disabled>"
                if dns_gate is None
                else (
                    f"{dns_gate.get('fqdn')}@{dns_gate.get('zone_id')}"
                    f" ttl={dns_gate.get('ttl')}"
                )
            ),
            *heartbeat_lines,
        ]
    )


def _ingress_class_presence(ingress_class_doc: dict[str, object], class_name: str) -> bool:
    """Check whether an IngressClass with one name is present."""
    items = _sequence_at(ingress_class_doc, "items")
    return any(
        _string_at(_mapping_at(item_mapping, "metadata") or {}, "name") == class_name
        for item in items
        for item_mapping in (_as_json_mapping(item),)
        if item_mapping is not None
    )


def _load_balancer_ips(service_doc: dict[str, object]) -> tuple[str, ...]:
    """Extract service load-balancer IPs from Kubernetes Service JSON."""
    status = _mapping_at(service_doc, "status") or {}
    load_balancer = _mapping_at(status, "loadBalancer") or {}
    ingress_items = _sequence_at(load_balancer, "ingress")
    return tuple(
        candidate
        for item in ingress_items
        for mapping in (_as_json_mapping(item),)
        if mapping is not None
        for candidate in ((_string_at(mapping, "ip") or _string_at(mapping, "hostname")),)
        if candidate is not None
    )


def _service_count(service_list_doc: dict[str, object]) -> int:
    """Count Service items in a Kubernetes list response."""
    return len(_sequence_at(service_list_doc, "items"))


def _certificate_ready_state(certificate_doc: dict[str, object] | None) -> str:
    """Extract cert-manager ready state from a Certificate document."""
    match certificate_doc:
        case None:
            return "missing"
        case dict() as certificate_mapping:
            status = _mapping_at(certificate_mapping, "status") or {}
            conditions_raw = _sequence_at(status, "conditions")
            conditions = tuple(
                mapping
                for item in conditions_raw
                if (mapping := _as_json_mapping(item)) is not None
            )
            match _bool_condition_status(conditions, "Ready"):
                case "True":
                    return "true"
                case "False":
                    return "false"
                case _:
                    return "unknown"


def _render_public_edge_report(
    *,
    settings: dict[str, RenderedSettingValue],
    public_ip: str,
    route53_record_ip: str | None,
    ingress_classes_doc: dict[str, object],
    traefik_service_doc: dict[str, object] | None,
    ingress_nginx_services_doc: dict[str, object],
    vscode_ingress_doc: dict[str, object] | None,
    vscode_certificate_doc: dict[str, object] | None,
) -> str:
    """Render deterministic public-edge diagnostics."""
    detected_interface = _optional_setting_string(settings, "active_lan_interface") or "<unknown>"
    detected_ipv4 = _optional_setting_string(settings, "active_lan_ipv4") or "<unknown>"
    detected_cidr = _optional_setting_string(settings, "active_lan_network_cidr") or "<unknown>"
    configured_fqdn = _optional_setting_string(settings, "vscode_fqdn") or _require_setting_string(
        settings, "demo_fqdn"
    )
    traefik_service_items = (
        _sequence_at(traefik_service_doc, "items") if traefik_service_doc is not None else ()
    )
    traefik_first_service = (
        _as_json_mapping(traefik_service_items[0]) if traefik_service_items else None
    )
    traefik_ips = _load_balancer_ips(traefik_first_service) if traefik_first_service else ()
    traefik_ip = traefik_ips[0] if len(traefik_ips) > 0 else "<missing>"
    has_traefik_class = _ingress_class_presence(ingress_classes_doc, "traefik")
    has_nginx_class = _ingress_class_presence(ingress_classes_doc, "nginx")
    competing_nginx_services = _service_count(ingress_nginx_services_doc)
    match vscode_ingress_doc:
        case dict() as ingress_doc:
            spec = _mapping_at(ingress_doc, "spec") or {}
            vscode_ingress_class = _string_at(spec, "ingressClassName") or "<missing>"
            match _sequence_at(spec, "rules"):
                case (first_rule_obj, *_):
                    first_rule = _as_json_mapping(first_rule_obj) or {}
                    vscode_ingress_host = _string_at(first_rule, "host") or "<missing>"
                case _:
                    vscode_ingress_host = "<missing>"
        case None:
            vscode_ingress_class = "<missing>"
            vscode_ingress_host = "<missing>"
    certificate_ready = _certificate_ready_state(vscode_certificate_doc)

    private_edge_ready = (
        has_traefik_class
        and not has_nginx_class
        and competing_nginx_services == 0
        and vscode_ingress_class == "traefik"
        and certificate_ready == "true"
        and traefik_ip != "<missing>"
    )
    route53_status = (
        "in-sync"
        if route53_record_ip == public_ip
        else "missing"
        if route53_record_ip is None
        else "mismatch"
    )
    classification = (
        "private-edge-ready-public-dns-stale"
        if private_edge_ready and route53_status != "in-sync"
        else "competing-ingress-controller"
        if has_nginx_class or competing_nginx_services > 0
        else "certificate-not-ready"
        if certificate_ready != "true"
        else "vscode-ingress-class-drift"
        if vscode_ingress_class != "traefik"
        else "cluster-edge-not-ready"
        if not private_edge_ready
        else "ready-for-external-proof"
    )

    return "\n".join(
        [
            "Public edge diagnostic",
            f"FQDN={configured_fqdn}",
            f"PUBLIC_IP={public_ip}",
            f"ROUTE53_A_RECORD={route53_record_ip or '<missing>'}",
            f"ROUTE53_STATUS={route53_status}",
            f"ACTIVE_LAN_INTERFACE={detected_interface}",
            f"ACTIVE_LAN_IPV4={detected_ipv4}",
            f"ACTIVE_LAN_CIDR={detected_cidr}",
            f"METALLB_POOL={_discovered_metallb_pool()}",
            f"INGRESS_LB_IP={_discovered_ingress_lb_ip()}",
            f"TRAEFIK_SERVICE_IP={traefik_ip}",
            f"INGRESSCLASS_TRAEFIK={'present' if has_traefik_class else 'missing'}",
            f"INGRESSCLASS_NGINX={'present' if has_nginx_class else 'missing'}",
            f"INGRESS_NGINX_SERVICES={competing_nginx_services}",
            f"VSCODE_INGRESS_CLASS={vscode_ingress_class}",
            f"VSCODE_INGRESS_HOST={vscode_ingress_host}",
            f"CERTIFICATE_READY={certificate_ready}",
            f"PRIVATE_EDGE_READY={'true' if private_edge_ready else 'false'}",
            f"CLASSIFICATION={classification}",
        ]
    )


def _raise_effect_error(message: str) -> object:
    """Raise a deterministic failure from an effect-builder helper."""
    raise ValueError(message)


_DEFAULT_PULUMI_STACK: str = "home"


def _resolve_pulumi_stack(cmd_stack: str | None) -> str:
    """Resolve Pulumi stack from explicit command input or hardcoded default."""
    match cmd_stack:
        case str() as explicit_stack:
            return explicit_stack
        case None:
            return _DEFAULT_PULUMI_STACK


def _build_dns_query_effect(effect_id: str, prereq_results: PrereqResults) -> QueryRoute53Record:
    """Build a Route 53 query effect from validated settings."""
    settings = _require_settings(prereq_results)
    return QueryRoute53Record(
        effect_id=effect_id,
        description=f"Query Route 53 A record for {_require_setting_string(settings, 'demo_fqdn')}",
        zone_id=_require_setting_string(settings, "route53_zone_id"),
        fqdn=_require_setting_string(settings, "demo_fqdn"),
        aws_region=_require_setting_string(settings, "aws_region"),
    )


def _build_host_check_ports_effect(prereq_results: PrereqResults) -> Sequence | WriteStdout:
    """Build the host port check root effect from probe results."""
    results = _require_port_results(prereq_results, "host_check_ports_probe")
    report = _render_host_check_ports_report(results)
    unavailable = tuple(str(result.port) for result in results if not result.available)
    match unavailable:
        case ():
            return WriteStdout(
                effect_id="host_check_ports",
                description="Render host port availability report",
                text=report,
            )
        case _:
            return Sequence(
                effect_id="host_check_ports",
                description="Render busy port report and fail command",
                effects=[
                    WriteStdout(
                        effect_id="host_check_ports_report",
                        description="Render host port availability report",
                        text=report,
                    ),
                    Custom(
                        effect_id="host_check_ports_fail",
                        description="Fail host port availability command",
                        fn=lambda: _raise_effect_error(
                            f"Ports unavailable: {', '.join(unavailable)}"
                        ),
                    ),
                ],
            )


def _parse_kubectl_pod_names(stdout: str) -> tuple[str, ...]:
    """Parse `kubectl get pods -o name` output into a deterministic tuple."""
    return tuple(filter(None, (line.strip() for line in stdout.splitlines())))


def _require_kubectl_capture_result(
    prereq_results: PrereqResults, effect_id: str
) -> tuple[int, str, str]:
    """Extract one kubectl capture result or raise ValueError."""
    result = prereq_results.get(effect_id)
    match result:
        case Success(value=(int() as returncode, str() as stdout, str() as stderr)):
            return (returncode, stdout, stderr)
        case Success(value=_):
            raise ValueError(f"{effect_id} prerequisite returned unexpected value type")
        case Failure(error=error):
            raise ValueError(f"{effect_id} prerequisite failed: {error}")
        case _:
            raise ValueError(f"{effect_id} prerequisite missing")


def _require_successful_kubectl_stdout(prereq_results: PrereqResults, effect_id: str) -> str:
    """Extract stdout from a successful kubectl capture result or raise ValueError."""
    returncode, stdout, stderr = _require_kubectl_capture_result(prereq_results, effect_id)
    match returncode:
        case 0:
            return stdout
        case _:
            raise ValueError(f"{effect_id} prerequisite failed: {stderr}")


def _is_optional_kubectl_capture_absence(error_text: str) -> bool:
    """Return True when one kubectl capture failure means the object or API is absent."""
    lowered = error_text.lower()
    return (
        "notfound" in lowered
        or "not found" in lowered
        or "the server doesn't have a resource type" in lowered
        or "could not find the requested resource" in lowered
        or "no matches for kind" in lowered
    )


def _optional_json_doc_from_capture(
    prereq_results: PrereqResults, effect_id: str
) -> dict[str, object] | None:
    """Parse one optional kubectl JSON capture result."""
    result = prereq_results.get(effect_id)
    match result:
        case Success(value=(int() as returncode, str() as stdout, str() as stderr)):
            match returncode:
                case 0:
                    stripped_stdout = stdout.strip()
                    match stripped_stdout:
                        case "":
                            return None
                        case _:
                            return _parse_json_mapping(stripped_stdout)
                case _ if _is_optional_kubectl_capture_absence(stderr):
                    return None
                case _:
                    raise ValueError(f"{effect_id} prerequisite failed: {stderr}")
        case Success(value=_):
            raise ValueError(f"{effect_id} prerequisite returned unexpected value type")
        case Failure(error=str() as error) if _is_optional_kubectl_capture_absence(error):
            return None
        case Failure(error=error):
            raise ValueError(f"{effect_id} prerequisite failed: {error}")
        case _:
            raise ValueError(f"{effect_id} prerequisite missing")


def _k8s_logs_effect_id(namespace: str, pod_name: str) -> str:
    """Build deterministic effect id for streaming one pod's logs."""
    return (
        f"k8s_logs_{namespace.replace('-', '_')}_" f"{pod_name.replace('/', '_').replace('-', '_')}"
    )


def _build_k8s_logs_effect(
    cmd: K8sLogsCommand, prereq_results: PrereqResults
) -> Sequence | WriteStdout:
    """Build namespace-aware kubectl logs effect from listed pods."""
    pod_refs = tuple(
        (namespace, pod_name)
        for namespace in cmd.namespaces
        for pod_name in _parse_kubectl_pod_names(
            _require_successful_kubectl_stdout(
                prereq_results,
                f"k8s_logs_pod_list_{namespace.replace('-', '_')}",
            )
        )
    )
    match pod_refs:
        case ():
            return WriteStdout(
                effect_id="k8s_logs",
                description="Render empty log result",
                text="No pods found in requested namespaces.",
            )
        case _:
            return Sequence(
                effect_id="k8s_logs",
                description="Stream infrastructure pod logs",
                effects=[
                    RunKubectlCommand(
                        effect_id=_k8s_logs_effect_id(namespace, pod_name),
                        description=f"Stream logs for {pod_name} in namespace {namespace}",
                        args=[
                            "logs",
                            pod_name,
                            "--all-containers=true",
                            f"--tail={cmd.tail}",
                        ],
                        namespace=namespace,
                        stream_stdout=True,
                    )
                    for namespace, pod_name in pod_refs
                ],
            )


def _pulumi_env(machine_identity: MachineIdentity) -> dict[str, str]:
    """Build Pulumi subprocess env overrides from machine identity."""
    return {"PRODBOX_ID": machine_identity.prodbox_id}


def _build_rke2_ensure_effect(prereq_results: PrereqResults) -> Sequence:
    """Build dynamic rke2 ensure effect from prerequisite machine identity."""
    machine_identity = _require_machine_identity(prereq_results)
    label_value = prodbox_id_to_label_value(machine_identity.prodbox_id)
    storage_and_minio = Sequence(
        effect_id="rke2_ensure_storage_and_minio",
        description="Ensure retained local storage and MinIO runtime",
        effects=[
            EnsureRetainedLocalStorage(
                effect_id="rke2_ensure_retained_storage",
                description="Ensure retained local StorageClass/PV/PVC for MinIO",
                machine_identity=machine_identity,
                namespace=MINIO_NAMESPACE,
                storage_class_name=PRODBOX_STORAGE_CLASS,
                persistent_volume_name=MINIO_PERSISTENT_VOLUME,
                persistent_volume_claim_name=MINIO_PERSISTENT_CLAIM,
                storage_size=MINIO_STORAGE_SIZE,
                host_storage_base_path=Path(PRODBOX_STORAGE_BASE_PATH),
                annotation_key=PRODBOX_ANNOTATION_KEY,
                label_key=PRODBOX_LABEL_KEY,
                label_value=label_value,
            ),
            EnsureMinio(
                effect_id="rke2_ensure_minio_runtime",
                description="Ensure MinIO runtime via official Helm chart",
                machine_identity=machine_identity,
                namespace=MINIO_NAMESPACE,
                release_name=MINIO_HELM_RELEASE,
                repository_name=MINIO_HELM_REPOSITORY_NAME,
                repository_url=MINIO_HELM_REPOSITORY_URL,
                chart_ref=MINIO_HELM_CHART_REF,
                chart_version=MINIO_HELM_CHART_VERSION,
                existing_claim=MINIO_PERSISTENT_CLAIM,
                annotation_key=PRODBOX_ANNOTATION_KEY,
                label_key=PRODBOX_LABEL_KEY,
                label_value=label_value,
                storage_size=MINIO_STORAGE_SIZE,
            ),
        ],
    )
    return Sequence(
        effect_id="rke2_ensure",
        description="Idempotently provision RKE2 cluster runtime",
        effects=[
            EnsureRke2IngressController(
                effect_id="rke2_ensure_disable_builtin_ingress",
                description="Disable bundled RKE2 ingress-controller ownership",
                file_path=Path("/etc/rancher/rke2/config.yaml"),
                controller="none",
            ),
            RunSystemdCommand(
                effect_id="rke2_ensure_enable",
                description="Enable RKE2 service",
                action="enable",
                service="rke2-server.service",
                sudo=True,
            ),
            RunSystemdCommand(
                effect_id="rke2_ensure_restart",
                description="Restart RKE2 service with canonical ingress settings",
                action="restart",
                service="rke2-server.service",
                sudo=True,
            ),
            RunKubectlCommand(
                effect_id="rke2_ensure_verify_kubectl",
                description="Confirm kubectl access to cluster",
                args=["cluster-info"],
                timeout=30.0,
            ),
            EnsureProdboxIdentityConfigMap(
                effect_id="rke2_ensure_prodbox_identity_configmap",
                description="Ensure prodbox identity ConfigMap exists",
                machine_identity=machine_identity,
                namespace=PRODBOX_NAMESPACE,
                configmap_name=PRODBOX_IDENTITY_CONFIGMAP,
                annotation_key=PRODBOX_ANNOTATION_KEY,
                label_key=PRODBOX_LABEL_KEY,
                label_value=label_value,
            ),
            Parallel(
                effect_id="rke2_ensure_registry_and_storage",
                description="Ensure Harbor and MinIO/storage runtime in parallel",
                effects=[
                    EnsureHarborRegistry(
                        effect_id="rke2_ensure_harbor_registry",
                        description=(
                            "Ensure local Harbor registry and prodbox gateway image pipeline"
                        ),
                        machine_identity=machine_identity,
                        namespace=HARBOR_NAMESPACE,
                        release_name=HARBOR_HELM_RELEASE,
                        repository_name=HARBOR_HELM_REPOSITORY_NAME,
                        repository_url=HARBOR_HELM_REPOSITORY_URL,
                        registry_endpoint=HARBOR_REGISTRY_ENDPOINT,
                        mirror_project=HARBOR_MIRROR_PROJECT,
                        gateway_image_repository=HARBOR_GATEWAY_REPOSITORY,
                        gateway_dockerfile=Path("docker/gateway.Dockerfile"),
                        gateway_build_context=Path("."),
                        registries_file_path=Path(RKE2_REGISTRIES_PATH),
                    ),
                    storage_and_minio,
                ],
            ),
            AnnotateProdboxManagedResources(
                effect_id="rke2_ensure_reconcile_prodbox_annotations",
                description="Apply prodbox annotation doctrine to managed resources",
                prodbox_id=machine_identity.prodbox_id,
                annotation_key=PRODBOX_ANNOTATION_KEY,
                label_key=PRODBOX_LABEL_KEY,
                label_value=label_value,
                managed_namespaces=PRODBOX_MANAGED_NAMESPACES,
                helm_instances=PRODBOX_HELM_INSTANCES,
            ),
        ],
    )


def _build_rke2_cleanup_effect(
    prereq_results: PrereqResults, storage_instructions: str
) -> Sequence:
    """Build dynamic rke2 cleanup effect from prerequisite machine identity."""
    machine_identity = _require_machine_identity(prereq_results)
    label_value = prodbox_id_to_label_value(machine_identity.prodbox_id)
    return Sequence(
        effect_id="rke2_cleanup",
        description="Cleanup prodbox-annotated Kubernetes resources without touching host paths",
        effects=[
            AnnotateProdboxManagedResources(
                effect_id="rke2_cleanup_reconcile_prodbox_annotations",
                description="Apply prodbox annotation doctrine before cleanup",
                prodbox_id=machine_identity.prodbox_id,
                annotation_key=PRODBOX_ANNOTATION_KEY,
                label_key=PRODBOX_LABEL_KEY,
                label_value=label_value,
                managed_namespaces=PRODBOX_MANAGED_NAMESPACES,
                helm_instances=PRODBOX_HELM_INSTANCES,
            ),
            CleanupProdboxAnnotatedResources(
                effect_id="rke2_cleanup_delete_annotated_resources",
                description="Delete prodbox annotated resources except retained storage kinds",
                prodbox_id=machine_identity.prodbox_id,
                annotation_key=PRODBOX_ANNOTATION_KEY,
                retained_resource_kinds=PRODBOX_STORAGE_RETAINED_RESOURCES,
                retained_namespaces=(PRODBOX_NAMESPACE,),
            ),
            WriteStdout(
                effect_id="rke2_cleanup_storage_warning",
                description="Print manual host storage cleanup warning",
                text=storage_instructions + "\n",
            ),
        ],
    )


def _build_pulumi_up_effect(cmd: PulumiUpCommand, prereq_results: PrereqResults) -> Sequence:
    """Build pulumi up effect with post-apply prodbox identity/annotation reconciliation."""
    machine_identity = _require_machine_identity(prereq_results)
    stack = _resolve_pulumi_stack(cmd.stack)
    label_value = prodbox_id_to_label_value(machine_identity.prodbox_id)
    return Sequence(
        effect_id="pulumi_up",
        description="Apply infrastructure changes",
        effects=[
            PulumiUp(
                effect_id="pulumi_up_apply",
                description="Apply infrastructure changes via Pulumi",
                cwd=cmd.cwd,
                stack=stack,
                env=_pulumi_env(machine_identity),
                yes=cmd.yes,
            ),
            EnsureProdboxIdentityConfigMap(
                effect_id="pulumi_up_prodbox_identity_configmap",
                description="Ensure prodbox identity ConfigMap exists",
                machine_identity=machine_identity,
                namespace=PRODBOX_NAMESPACE,
                configmap_name=PRODBOX_IDENTITY_CONFIGMAP,
                annotation_key=PRODBOX_ANNOTATION_KEY,
                label_key=PRODBOX_LABEL_KEY,
                label_value=label_value,
            ),
            AnnotateProdboxManagedResources(
                effect_id="pulumi_up_reconcile_prodbox_annotations",
                description="Apply prodbox annotation doctrine to managed resources",
                prodbox_id=machine_identity.prodbox_id,
                annotation_key=PRODBOX_ANNOTATION_KEY,
                label_key=PRODBOX_LABEL_KEY,
                label_value=label_value,
                managed_namespaces=PRODBOX_MANAGED_NAMESPACES,
                helm_instances=PRODBOX_HELM_INSTANCES,
            ),
        ],
    )


# =============================================================================
# Config Command Builders
# =============================================================================


def _parse_dotenv_to_mapping(dotenv_path: Path) -> dict[str, str]:
    """Parse a ``.env`` file into a plain mapping, skipping blanks and comments."""
    match dotenv_path.is_file():
        case False:
            return {}
        case True:
            pass
    raw_lines = dotenv_path.read_text(encoding="utf-8").splitlines()
    stripped_lines = tuple(raw.strip() for raw in raw_lines)
    content_lines = tuple(
        line for line in stripped_lines if line != "" and not line.startswith("#")
    )
    normalized = tuple(line.removeprefix("export ").strip() for line in content_lines)
    pairs = tuple(line.split("=", 1) for line in normalized if "=" in line)
    return {name.strip(): value.strip() for name, value in pairs if value.strip() != ""}


def _dhall_text(mapping: dict[str, str], key: str, default: str = "") -> str:
    """Render a Dhall Text literal from a dotenv mapping."""
    return f'"{mapping.get(key, default)}"'


def _dhall_optional_text(mapping: dict[str, str], key: str) -> str:
    """Render a Dhall ``Optional Text`` from a dotenv mapping."""
    match mapping.get(key):
        case str() as v:
            return f'Some "{v}"'
        case _:
            return "None Text"


def _dhall_natural(mapping: dict[str, str], key: str, default: str = "60") -> str:
    """Render a Dhall Natural literal from a dotenv mapping."""
    return mapping.get(key, default)


def _dhall_bool(mapping: dict[str, str], key: str, default: str = "True") -> str:
    """Render a Dhall Bool literal from a dotenv mapping."""
    raw = mapping.get(key, default).lower()
    match raw:
        case "true" | "1" | "yes":
            return "True"
        case _:
            return "False"


def _generate_dhall_config_from_env(dotenv_path: Path) -> str:
    """Generate a ``prodbox-config.dhall`` body from an existing ``.env`` file."""
    m = _parse_dotenv_to_mapping(dotenv_path)
    lines = (
        "let Config = ./prodbox-config-types.dhall",
        "",
        f"in  Config::{'{'}",
        "    aws = {",
        f"        access_key_id = {_dhall_text(m, 'AWS_ACCESS_KEY_ID')}",
        f"      , secret_access_key = {_dhall_text(m, 'AWS_SECRET_ACCESS_KEY')}",
        f"      , session_token = {_dhall_optional_text(m, 'AWS_SESSION_TOKEN')}",
        f"      , region = {_dhall_text(m, 'AWS_REGION', 'us-east-1')}",
        "    }",
        f"  , route53 = {'{'} zone_id = {_dhall_text(m, 'ROUTE53_ZONE_ID')} {'}'}",
        "  , domain = {",
        f"        demo_fqdn = {_dhall_text(m, 'DEMO_FQDN', 'demo.example.com')}",
        f"      , demo_ttl = {_dhall_natural(m, 'DEMO_TTL', '60')}",
        f"      , vscode_fqdn = {_dhall_optional_text(m, 'VSCODE_FQDN')}",
        "    }",
        "  , acme = {",
        f"        email = {_dhall_text(m, 'ACME_EMAIL')}",
        f"      , server = {_dhall_text(m, 'ACME_SERVER', 'https://acme-v02.api.letsencrypt.org/directory')}",
        "    }",
        "  , deployment = {",
        f"        dev_mode = {_dhall_bool(m, 'PRODBOX_DEV_MODE', 'true')}",
        f"      , bootstrap_public_ip_override = {_dhall_optional_text(m, 'BOOTSTRAP_PUBLIC_IP_OVERRIDE')}",
        f"      , pulumi_enable_dns_bootstrap = {_dhall_bool(m, 'PULUMI_ENABLE_DNS_BOOTSTRAP', 'true')}",
        "    }",
        "}",
    )
    return "\n".join(lines) + "\n"


def _build_config_init_dag(_cmd: ConfigInitCommand) -> EffectDAG:
    """Build DAG for bootstrapping Dhall config from .env."""
    dotenv_path = REPOSITORY_ROOT / ".env"
    dhall_path = REPOSITORY_ROOT / "prodbox-config.dhall"
    json_path = REPOSITORY_ROOT / "prodbox-config.json"
    dhall_content = _generate_dhall_config_from_env(dotenv_path)

    write_dhall = EffectNode(
        effect=WriteFile(
            effect_id="config_init_write_dhall",
            description="Write prodbox-config.dhall from .env",
            file_path=dhall_path,
            content=dhall_content,
        ),
        prerequisites=frozenset(["tool_dhall_to_json"]),
    )
    compile_dhall = EffectNode(
        effect=RunDhallCompile(
            effect_id="config_init_compile",
            description="Compile prodbox-config.dhall to JSON",
            input_path=dhall_path,
            output_path=json_path,
        ),
        prerequisites=frozenset(["config_init_write_dhall"]),
    )
    validate_json = EffectNode(
        effect=ValidateConfigJson(
            effect_id="config_init_validate",
            description="Validate compiled config JSON",
            config_path=json_path,
        ),
        prerequisites=frozenset(["config_init_compile"]),
    )
    return EffectDAG.from_roots(
        validate_json,
        registry=_merge_registry(write_dhall, compile_dhall, validate_json),
    )


def _build_config_compile_dag(_cmd: ConfigCompileCommand) -> EffectDAG:
    """Build DAG for compiling Dhall config to JSON."""
    dhall_path = REPOSITORY_ROOT / "prodbox-config.dhall"
    json_path = REPOSITORY_ROOT / "prodbox-config.json"

    root = EffectNode(
        effect=RunDhallCompile(
            effect_id="config_compile",
            description="Compile prodbox-config.dhall to JSON",
            input_path=dhall_path,
            output_path=json_path,
        ),
        prerequisites=frozenset(["tool_dhall_to_json"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_config_show_dag(cmd: ConfigShowCommand) -> EffectDAG:
    """Build DAG for showing configuration from compiled JSON."""
    root = EffectNode(
        effect=WriteStdout(
            effect_id="config_show",
            description="Show configuration",
            text="",
        ),
        prerequisites=frozenset(["settings_object"]),
        effect_builder=lambda _reduced, prereq_results: WriteStdout(
            effect_id="config_show",
            description="Show configuration",
            text=render_settings_display(
                _require_settings(prereq_results),
                show_secrets=cmd.show_secrets,
            ),
        ),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_config_validate_dag(_cmd: ConfigValidateCommand) -> EffectDAG:
    """Build DAG for validating configuration."""
    root = EffectNode(
        effect=ValidateSettings(
            effect_id="config_validate",
            description="Validate configuration",
        ),
        prerequisites=frozenset(["settings_loaded"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


# =============================================================================
# Host Command Builders
# =============================================================================


def _build_host_info_dag(_cmd: HostInfoCommand) -> EffectDAG:
    """Build DAG for showing host information."""
    root = EffectNode(
        effect=CaptureSubprocessOutput(
            effect_id="host_info",
            description="Get host system information",
            command=["uname", "-a"],
        ),
        prerequisites=frozenset(),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_host_check_ports_dag(cmd: HostCheckPortsCommand) -> EffectDAG:
    """Build DAG for checking port availability."""
    port_probe_node = EffectNode(
        effect=CheckPortAvailability(
            effect_id="host_check_ports_probe",
            description=f"Check ports: {cmd.ports}",
            ports=cmd.ports,
        ),
        prerequisites=frozenset(),
    )
    root = EffectNode(
        effect=WriteStdout(
            effect_id="host_check_ports",
            description="Render host port availability report",
            text="",
        ),
        prerequisites=frozenset(["host_check_ports_probe"]),
        effect_builder=lambda _reduced, prereq_results: _build_host_check_ports_effect(
            prereq_results
        ),
    )
    return EffectDAG.from_roots(root, registry=_merge_registry(port_probe_node))


def _build_host_ensure_tools_dag(_cmd: HostEnsureToolsCommand) -> EffectDAG:
    """Build DAG for checking required CLI tools."""
    root = EffectNode(
        effect=ValidateTool(
            effect_id="host_ensure_tools",
            description="Check required CLI tools",
            tool_name="kubectl",
        ),
        prerequisites=frozenset(
            [
                "tool_kubectl",
                "tool_helm",
                "tool_pulumi",
                "tool_docker",
                "tool_ctr",
                "tool_sudo",
                "tool_systemctl",
                "tool_rke2",
            ]
        ),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_host_firewall_dag(_cmd: HostFirewallCommand) -> EffectDAG:
    """Build DAG for checking firewall status."""
    root = EffectNode(
        effect=CaptureSubprocessOutput(
            effect_id="host_firewall",
            description="Check firewall status",
            command=["ufw", "status"],
        ),
        prerequisites=frozenset(),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_host_public_edge_dag(_cmd: HostPublicEdgeCommand) -> EffectDAG:
    """Build DAG for diagnosing the canonical public-edge path."""
    public_ip_node = EffectNode(
        effect=FetchPublicIP(
            effect_id="host_public_edge_public_ip",
            description="Fetch current public IP for edge diagnostics",
        ),
        prerequisites=frozenset(),
    )
    route53_node = EffectNode(
        effect=QueryRoute53Record(
            effect_id="host_public_edge_route53_record",
            description="Query Route 53 A record for the canonical public host",
            zone_id="",
            fqdn="",
        ),
        prerequisites=frozenset(["settings_object", "route53_accessible"]),
        effect_builder=lambda _reduced, prereq_results: QueryRoute53Record(
            effect_id="host_public_edge_route53_record",
            description="Query Route 53 A record for the canonical public host",
            zone_id=_require_setting_string(_require_settings(prereq_results), "route53_zone_id"),
            fqdn=(
                _optional_setting_string(_require_settings(prereq_results), "vscode_fqdn")
                or _require_setting_string(_require_settings(prereq_results), "demo_fqdn")
            ),
            aws_region=_require_setting_string(_require_settings(prereq_results), "aws_region"),
        ),
    )
    ingress_class_node = EffectNode(
        effect=CaptureKubectlOutput(
            effect_id="host_public_edge_ingress_classes",
            description="List cluster ingress classes",
            args=["get", "ingressclass", "-o", "json"],
        ),
        prerequisites=frozenset(["k8s_cluster_reachable"]),
    )
    traefik_service_node = EffectNode(
        effect=CaptureKubectlOutput(
            effect_id="host_public_edge_traefik_service",
            description="Inspect Traefik service load-balancer status",
            args=["get", "svc", "-l", "app.kubernetes.io/name=traefik", "-o", "json"],
            namespace="traefik-system",
        ),
        prerequisites=frozenset(["k8s_cluster_reachable"]),
    )
    ingress_nginx_services_node = EffectNode(
        effect=CaptureKubectlOutput(
            effect_id="host_public_edge_ingress_nginx_services",
            description="List competing ingress-nginx services",
            args=["get", "svc", "-A", "-l", "app.kubernetes.io/name=ingress-nginx", "-o", "json"],
        ),
        prerequisites=frozenset(["k8s_cluster_reachable"]),
    )
    vscode_ingress_node = EffectNode(
        effect=CaptureKubectlOutput(
            effect_id="host_public_edge_vscode_ingress",
            description="Inspect the vscode ingress object",
            args=["get", "ingress", "vscode", "-o", "json", "--ignore-not-found=true"],
            namespace="vscode",
        ),
        prerequisites=frozenset(["k8s_cluster_reachable"]),
    )
    vscode_certificate_node = EffectNode(
        effect=CaptureKubectlOutput(
            effect_id="host_public_edge_vscode_certificate",
            description="Inspect the vscode TLS certificate resource",
            args=["get", "certificate", "vscode-tls", "-o", "json", "--ignore-not-found=true"],
            namespace="vscode",
        ),
        prerequisites=frozenset(["k8s_cluster_reachable"]),
    )
    root = EffectNode(
        effect=WriteStdout(
            effect_id="host_public_edge",
            description="Render canonical public-edge diagnostics",
            text="",
        ),
        prerequisites=frozenset(
            [
                "settings_object",
                "host_public_edge_public_ip",
                "host_public_edge_route53_record",
                "host_public_edge_ingress_classes",
                "host_public_edge_traefik_service",
                "host_public_edge_ingress_nginx_services",
                "host_public_edge_vscode_ingress",
                "host_public_edge_vscode_certificate",
            ]
        ),
        prerequisite_failure_policy=PrerequisiteFailurePolicy.IGNORE,
        effect_builder=lambda _reduced, prereq_results: WriteStdout(
            effect_id="host_public_edge",
            description="Render canonical public-edge diagnostics",
            text=_render_public_edge_report(
                settings=_require_settings(prereq_results),
                public_ip=_require_string_result(prereq_results, "host_public_edge_public_ip"),
                route53_record_ip=_optional_string_result(
                    prereq_results, "host_public_edge_route53_record"
                ),
                ingress_classes_doc=_parse_json_mapping(
                    _require_successful_kubectl_stdout(
                        prereq_results, "host_public_edge_ingress_classes"
                    )
                ),
                traefik_service_doc=_optional_json_doc_from_capture(
                    prereq_results, "host_public_edge_traefik_service"
                ),
                ingress_nginx_services_doc=_parse_json_mapping(
                    _require_successful_kubectl_stdout(
                        prereq_results, "host_public_edge_ingress_nginx_services"
                    )
                ),
                vscode_ingress_doc=_optional_json_doc_from_capture(
                    prereq_results, "host_public_edge_vscode_ingress"
                ),
                vscode_certificate_doc=_optional_json_doc_from_capture(
                    prereq_results, "host_public_edge_vscode_certificate"
                ),
            ),
        ),
    )
    return EffectDAG.from_roots(
        root,
        registry=_merge_registry(
            public_ip_node,
            route53_node,
            ingress_class_node,
            traefik_service_node,
            ingress_nginx_services_node,
            vscode_ingress_node,
            vscode_certificate_node,
        ),
    )


# =============================================================================
# RKE2 Command Builders
# =============================================================================


def _build_rke2_status_dag(_cmd: RKE2StatusCommand) -> EffectDAG:
    """Build DAG for RKE2 status check."""
    root = EffectNode(
        effect=CheckServiceStatus(
            effect_id="rke2_status",
            description="Check RKE2 service status",
            service="rke2-server.service",
        ),
        prerequisites=frozenset(["platform_linux", "rke2_installed"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_rke2_start_dag(_cmd: RKE2StartCommand) -> EffectDAG:
    """Build DAG for starting RKE2."""
    root = EffectNode(
        effect=RunSystemdCommand(
            effect_id="rke2_start",
            description="Start RKE2 service",
            action="start",
            service="rke2-server.service",
            sudo=True,
        ),
        prerequisites=frozenset(["rke2_service_exists"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_rke2_stop_dag(_cmd: RKE2StopCommand) -> EffectDAG:
    """Build DAG for stopping RKE2."""
    root = EffectNode(
        effect=RunSystemdCommand(
            effect_id="rke2_stop",
            description="Stop RKE2 service",
            action="stop",
            service="rke2-server.service",
            sudo=True,
        ),
        prerequisites=frozenset(["rke2_service_exists"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_rke2_restart_dag(_cmd: RKE2RestartCommand) -> EffectDAG:
    """Build DAG for restarting RKE2."""
    root = EffectNode(
        effect=RunSystemdCommand(
            effect_id="rke2_restart",
            description="Restart RKE2 service",
            action="restart",
            service="rke2-server.service",
            sudo=True,
        ),
        prerequisites=frozenset(["rke2_service_exists"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_rke2_ensure_dag(_cmd: RKE2EnsureCommand) -> EffectDAG:
    """Build DAG for idempotent RKE2 runtime provisioning."""
    root = EffectNode(
        effect=Sequence(
            effect_id="rke2_ensure",
            description="Idempotently provision RKE2 cluster runtime",
            effects=[],
        ),
        prerequisites=frozenset(
            [
                "rke2_installed",
                "rke2_config_exists",
                "systemd_available",
                "tool_kubectl",
                "tool_helm",
                "tool_docker",
                "tool_ctr",
                "tool_sudo",
                "tool_systemctl",
                "kubeconfig_exists",
                "machine_identity",
            ]
        ),
        effect_builder=lambda _reduced, prereq_results: _build_rke2_ensure_effect(prereq_results),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_rke2_cleanup_dag(_cmd: RKE2CleanupCommand) -> EffectDAG:
    """Build DAG for idempotent cleanup of prodbox-annotated Kubernetes resources."""
    storage_instructions = "\n".join(
        [
            "Cleanup intentionally preserved local RKE2 storage paths:",
            *(f"  - {path}" for path in RKE2_DATA_PATHS),
            "Cleanup also preserved retained storage resource kinds:",
            *(f"  - {kind}" for kind in PRODBOX_STORAGE_RETAINED_RESOURCES),
            "Cleanup also preserved storage namespace:",
            f"  - {PRODBOX_NAMESPACE}",
            "To remove these manually, stop RKE2 first and then delete paths yourself.",
            "WARNING: deleting these paths can permanently destroy cluster state and data.",
        ]
    )
    root = EffectNode(
        effect=Sequence(
            effect_id="rke2_cleanup",
            description="Cleanup prodbox-annotated Kubernetes resources without touching host paths",
            effects=[],
        ),
        prerequisites=frozenset(["k8s_cluster_reachable", "machine_identity"]),
        effect_builder=lambda _reduced, prereq_results: _build_rke2_cleanup_effect(
            prereq_results,
            storage_instructions,
        ),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_rke2_logs_dag(cmd: RKE2LogsCommand) -> EffectDAG:
    """Build DAG for showing RKE2 logs."""
    root = EffectNode(
        effect=GetJournalLogs(
            effect_id="rke2_logs",
            description=f"Get RKE2 logs (last {cmd.lines} lines)",
            service="rke2-server.service",
            lines=cmd.lines,
        ),
        prerequisites=frozenset(["rke2_service_exists"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


# =============================================================================
# DNS Command Builders
# =============================================================================


def _build_dns_check_dag(_cmd: DNSCheckCommand) -> EffectDAG:
    """Build DAG for DNS status check."""
    public_ip_node = EffectNode(
        effect=FetchPublicIP(
            effect_id="dns_public_ip",
            description="Fetch current public IP",
        ),
        prerequisites=frozenset(),
    )
    current_record_node = EffectNode(
        effect=QueryRoute53Record(
            effect_id="dns_current_record",
            description="Query current Route 53 A record",
            zone_id="",
            fqdn="",
        ),
        prerequisites=frozenset(["settings_object", "route53_accessible"]),
        effect_builder=lambda _reduced, prereq_results: _build_dns_query_effect(
            "dns_current_record",
            prereq_results,
        ),
    )
    root = EffectNode(
        effect=WriteStdout(
            effect_id="dns_check",
            description="Render DNS status report",
            text="",
        ),
        prerequisites=frozenset(["settings_object", "dns_public_ip", "dns_current_record"]),
        effect_builder=lambda _reduced, prereq_results: WriteStdout(
            effect_id="dns_check",
            description="Render DNS status report",
            text=_render_dns_check_report(
                settings=_require_settings(prereq_results),
                public_ip=_require_string_result(prereq_results, "dns_public_ip"),
                current_record_ip=_optional_string_result(prereq_results, "dns_current_record"),
            ),
        ),
    )
    return EffectDAG.from_roots(
        root,
        registry=_merge_registry(public_ip_node, current_record_node),
    )


# =============================================================================
# Kubernetes Command Builders
# =============================================================================


def _build_k8s_health_dag(_cmd: K8sHealthCommand) -> EffectDAG:
    """Build DAG for Kubernetes health check."""
    root = EffectNode(
        effect=CaptureKubectlOutput(
            effect_id="k8s_health",
            description="Check Kubernetes cluster health",
            args=["cluster-info"],
        ),
        prerequisites=frozenset(["k8s_cluster_reachable"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_k8s_wait_dag(cmd: K8sWaitCommand) -> EffectDAG:
    """Build DAG for waiting on Kubernetes deployments."""
    root = EffectNode(
        effect=Sequence(
            effect_id="k8s_wait",
            description=f"Wait for deployments (timeout: {cmd.timeout}s)",
            effects=[
                KubectlWait(
                    effect_id=f"k8s_wait_{namespace.replace('-', '_')}",
                    description=f"Wait for deployments in namespace {namespace}",
                    resource="deployment",
                    condition="available",
                    all_resources=True,
                    namespace=namespace,
                    timeout=cmd.timeout,
                )
                for namespace in cmd.namespaces
            ],
        ),
        prerequisites=frozenset(["k8s_cluster_reachable"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_k8s_logs_dag(cmd: K8sLogsCommand) -> EffectDAG:
    """Build DAG for getting Kubernetes logs."""
    pod_list_nodes = tuple(
        EffectNode(
            effect=CaptureKubectlOutput(
                effect_id=f"k8s_logs_pod_list_{namespace.replace('-', '_')}",
                description=f"List pods in namespace {namespace}",
                args=["get", "pods", "-o", "name"],
                namespace=namespace,
            ),
            prerequisites=frozenset(["k8s_cluster_reachable"]),
        )
        for namespace in cmd.namespaces
    )
    root = EffectNode(
        effect=WriteStdout(
            effect_id="k8s_logs",
            description="Get infrastructure pod logs",
            text="",
        ),
        prerequisites=frozenset(node.effect_id for node in pod_list_nodes),
        effect_builder=lambda _reduced, prereq_results: _build_k8s_logs_effect(
            cmd,
            prereq_results,
        ),
    )
    return EffectDAG.from_roots(root, registry=_merge_registry(*pod_list_nodes))


# =============================================================================
# Pulumi Command Builders
# =============================================================================


def _build_pulumi_preview_dag(cmd: PulumiPreviewCommand) -> EffectDAG:
    """Build DAG for Pulumi preview."""
    stack_select_node = EffectNode(
        effect=PulumiStackSelect(
            effect_id="pulumi_preview_stack_select",
            description="Select Pulumi stack for preview",
            stack="",
            cwd=cmd.cwd,
            create_if_missing=False,
        ),
        prerequisites=frozenset(["pulumi_logged_in"]),
        effect_builder=lambda _reduced, _prereq_results: PulumiStackSelect(
            effect_id="pulumi_preview_stack_select",
            description="Select Pulumi stack for preview",
            stack=_resolve_pulumi_stack(cmd.stack),
            cwd=cmd.cwd,
            create_if_missing=False,
        ),
    )
    root = EffectNode(
        effect=PulumiPreview(
            effect_id="pulumi_preview",
            description="Preview infrastructure changes",
            cwd=cmd.cwd,
            stack=cmd.stack,
            env={},
        ),
        prerequisites=frozenset(
            ["pulumi_preview_stack_select", "machine_identity", "settings_object"]
        ),
        effect_builder=lambda _reduced, prereq_results: PulumiPreview(
            effect_id="pulumi_preview",
            description="Preview infrastructure changes",
            cwd=cmd.cwd,
            stack=_resolve_pulumi_stack(cmd.stack),
            env=_pulumi_env(_require_machine_identity(prereq_results)),
        ),
    )
    return EffectDAG.from_roots(root, registry=_merge_registry(stack_select_node))


def _build_pulumi_up_dag(cmd: PulumiUpCommand) -> EffectDAG:
    """Build DAG for Pulumi up."""
    stack_select_node = EffectNode(
        effect=PulumiStackSelect(
            effect_id="pulumi_up_stack_select",
            description="Select Pulumi stack for apply",
            stack="",
            cwd=cmd.cwd,
            create_if_missing=True,
        ),
        prerequisites=frozenset(["pulumi_logged_in"]),
        effect_builder=lambda _reduced, _prereq_results: PulumiStackSelect(
            effect_id="pulumi_up_stack_select",
            description="Select Pulumi stack for apply",
            stack=_resolve_pulumi_stack(cmd.stack),
            cwd=cmd.cwd,
            create_if_missing=True,
        ),
    )
    root = EffectNode(
        effect=Sequence(
            effect_id="pulumi_up",
            description="Apply infrastructure changes",
            effects=[],
        ),
        prerequisites=frozenset(
            [
                "pulumi_up_stack_select",
                "machine_identity",
                "k8s_cluster_reachable",
                "settings_object",
            ]
        ),
        effect_builder=lambda _reduced, prereq_results: _build_pulumi_up_effect(
            cmd,
            prereq_results,
        ),
    )
    return EffectDAG.from_roots(root, registry=_merge_registry(stack_select_node))


def _build_pulumi_destroy_dag(cmd: PulumiDestroyCommand) -> EffectDAG:
    """Build DAG for Pulumi destroy."""
    stack_select_node = EffectNode(
        effect=PulumiStackSelect(
            effect_id="pulumi_destroy_stack_select",
            description="Select Pulumi stack for destroy",
            stack="",
            cwd=cmd.cwd,
            create_if_missing=False,
        ),
        prerequisites=frozenset(["pulumi_logged_in"]),
        effect_builder=lambda _reduced, _prereq_results: PulumiStackSelect(
            effect_id="pulumi_destroy_stack_select",
            description="Select Pulumi stack for destroy",
            stack=_resolve_pulumi_stack(cmd.stack),
            cwd=cmd.cwd,
            create_if_missing=False,
        ),
    )
    root = EffectNode(
        effect=PulumiDestroy(
            effect_id="pulumi_destroy",
            description="Destroy infrastructure",
            cwd=cmd.cwd,
            stack=cmd.stack,
            env={},
            yes=cmd.yes,
        ),
        prerequisites=frozenset(
            ["pulumi_destroy_stack_select", "machine_identity", "settings_object"]
        ),
        effect_builder=lambda _reduced, prereq_results: PulumiDestroy(
            effect_id="pulumi_destroy",
            description="Destroy infrastructure",
            cwd=cmd.cwd,
            stack=_resolve_pulumi_stack(cmd.stack),
            env=_pulumi_env(_require_machine_identity(prereq_results)),
            yes=cmd.yes,
        ),
    )
    return EffectDAG.from_roots(root, registry=_merge_registry(stack_select_node))


def _build_pulumi_refresh_dag(cmd: PulumiRefreshCommand) -> EffectDAG:
    """Build DAG for Pulumi refresh."""
    stack_select_node = EffectNode(
        effect=PulumiStackSelect(
            effect_id="pulumi_refresh_stack_select",
            description="Select Pulumi stack for refresh",
            stack="",
            cwd=cmd.cwd,
            create_if_missing=True,
        ),
        prerequisites=frozenset(["pulumi_logged_in"]),
        effect_builder=lambda _reduced, _prereq_results: PulumiStackSelect(
            effect_id="pulumi_refresh_stack_select",
            description="Select Pulumi stack for refresh",
            stack=_resolve_pulumi_stack(cmd.stack),
            cwd=cmd.cwd,
            create_if_missing=True,
        ),
    )
    root = EffectNode(
        effect=PulumiRefresh(
            effect_id="pulumi_refresh",
            description="Refresh infrastructure state",
            cwd=cmd.cwd,
            stack=cmd.stack,
            env={},
        ),
        prerequisites=frozenset(
            ["pulumi_refresh_stack_select", "machine_identity", "settings_object"]
        ),
        effect_builder=lambda _reduced, prereq_results: PulumiRefresh(
            effect_id="pulumi_refresh",
            description="Refresh infrastructure state",
            cwd=cmd.cwd,
            stack=_resolve_pulumi_stack(cmd.stack),
            env=_pulumi_env(_require_machine_identity(prereq_results)),
        ),
    )
    return EffectDAG.from_roots(root, registry=_merge_registry(stack_select_node))


def _build_pulumi_stack_init_dag(cmd: PulumiStackInitCommand) -> EffectDAG:
    """Build DAG for Pulumi stack init."""
    root = EffectNode(
        effect=RunPulumiCommand(
            effect_id="pulumi_stack_init",
            description=f"Initialize Pulumi stack '{cmd.stack}'",
            args=["stack", "init", cmd.stack],
            cwd=cmd.cwd,
        ),
        prerequisites=frozenset(["tool_pulumi", "pulumi_logged_in"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


# =============================================================================
# Main Entry Point
# =============================================================================


def command_to_dag(command: Command) -> Result[EffectDAG, str]:
    """Convert a Command ADT to an Effect DAG.

    Uses exhaustive pattern matching to ensure all command types are handled.

    Args:
        command: The Command ADT to convert

    Returns:
        Success with EffectDAG if conversion succeeds, Failure otherwise
    """
    match command:
        # Config commands
        case ConfigInitCommand():
            return Success(_build_config_init_dag(command))
        case ConfigCompileCommand():
            return Success(_build_config_compile_dag(command))
        case ConfigShowCommand():
            return Success(_build_config_show_dag(command))
        case ConfigValidateCommand():
            return Success(_build_config_validate_dag(command))

        # Host commands
        case HostInfoCommand():
            return Success(_build_host_info_dag(command))
        case HostCheckPortsCommand():
            return Success(_build_host_check_ports_dag(command))
        case HostEnsureToolsCommand():
            return Success(_build_host_ensure_tools_dag(command))
        case HostFirewallCommand():
            return Success(_build_host_firewall_dag(command))
        case HostPublicEdgeCommand():
            return Success(_build_host_public_edge_dag(command))

        # RKE2 commands
        case RKE2StatusCommand():
            return Success(_build_rke2_status_dag(command))
        case RKE2StartCommand():
            return Success(_build_rke2_start_dag(command))
        case RKE2StopCommand():
            return Success(_build_rke2_stop_dag(command))
        case RKE2RestartCommand():
            return Success(_build_rke2_restart_dag(command))
        case RKE2EnsureCommand():
            return Success(_build_rke2_ensure_dag(command))
        case RKE2CleanupCommand():
            return Success(_build_rke2_cleanup_dag(command))
        case RKE2LogsCommand():
            return Success(_build_rke2_logs_dag(command))

        # DNS commands
        case DNSCheckCommand():
            return Success(_build_dns_check_dag(command))

        # Kubernetes commands
        case K8sHealthCommand():
            return Success(_build_k8s_health_dag(command))
        case K8sWaitCommand():
            return Success(_build_k8s_wait_dag(command))
        case K8sLogsCommand():
            return Success(_build_k8s_logs_dag(command))

        # Pulumi commands
        case PulumiPreviewCommand():
            return Success(_build_pulumi_preview_dag(command))
        case PulumiUpCommand():
            return Success(_build_pulumi_up_dag(command))
        case PulumiDestroyCommand():
            return Success(_build_pulumi_destroy_dag(command))
        case PulumiRefreshCommand():
            return Success(_build_pulumi_refresh_dag(command))
        case PulumiStackInitCommand():
            return Success(_build_pulumi_stack_init_dag(command))

        # Gateway commands
        case GatewayStartCommand():
            return Success(_build_gateway_start_dag(command))
        case GatewayStatusCommand():
            return Success(_build_gateway_status_dag(command))
        case GatewayConfigGenCommand():
            return Success(_build_gateway_config_gen_dag(command))

        # Chart platform commands
        case ChartListCommand():
            return Success(_build_chart_list_dag(command))
        case ChartStatusCommand():
            return Success(_build_chart_status_dag(command))
        case ChartDeployCommand():
            return Success(_build_chart_deploy_dag(command))
        case ChartDeleteCommand():
            return Success(_build_chart_delete_dag(command))

    # This should never be reached if all cases are handled
    # mypy will catch missing cases at type-check time


# =============================================================================
# Gateway Command Builders
# =============================================================================


def _build_gateway_start_dag(cmd: GatewayStartCommand) -> EffectDAG:
    """Build DAG for starting gateway daemon."""
    root = EffectNode(
        effect=StartGatewayDaemon(
            effect_id="start_gateway_daemon",
            description="Start gateway daemon",
            config_path=cmd.config_path,
        ),
        prerequisites=frozenset(),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_gateway_status_dag(cmd: GatewayStatusCommand) -> EffectDAG:
    """Build DAG for querying gateway daemon state."""
    query_node = EffectNode(
        effect=QueryGatewayState(
            effect_id="query_gateway_state",
            description="Query gateway daemon state",
            config_path=cmd.config_path,
        ),
        prerequisites=frozenset(),
    )
    root = EffectNode(
        effect=WriteStdout(
            effect_id="gateway_status",
            description="Render gateway daemon state",
            text="",
        ),
        prerequisites=frozenset(["query_gateway_state"]),
        effect_builder=lambda _reduced, prereq_results: WriteStdout(
            effect_id="gateway_status",
            description="Render gateway daemon state",
            text=_render_gateway_status_report(
                _as_json_mapping(_require_object_result(prereq_results, "query_gateway_state"))
                or {}
            ),
        ),
    )
    return EffectDAG.from_roots(root, registry=_merge_registry(query_node))


def _build_gateway_config_gen_dag(cmd: GatewayConfigGenCommand) -> EffectDAG:
    """Build DAG for generating gateway config template."""
    root = EffectNode(
        effect=GenerateGatewayConfig(
            effect_id="generate_gateway_config",
            description="Generate gateway config template",
            output_path=cmd.output_path,
            node_id=cmd.node_id,
        ),
        prerequisites=frozenset(),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


# =============================================================================
# Chart Platform Command Builders
# =============================================================================


def _build_chart_list_dag(_cmd: ChartListCommand) -> EffectDAG:
    """Build DAG for listing all supported charts."""
    root = EffectNode(
        effect=ChartListEffect(
            effect_id="chart_list",
            description="List all supported charts with install status",
        ),
        prerequisites=frozenset(["settings_object"]),
        effect_builder=lambda _reduced, _prereq_results: ChartListEffect(
            effect_id="chart_list",
            description="List all supported charts with install status",
        ),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_chart_status_dag(cmd: ChartStatusCommand) -> EffectDAG:
    """Build DAG for querying one chart's detailed status."""
    root = EffectNode(
        effect=ChartStatusEffect(
            effect_id="chart_status",
            description=f"Show status for chart {cmd.chart_name}",
            chart_name=cmd.chart_name,
        ),
        prerequisites=frozenset(["settings_object"]),
        effect_builder=lambda _reduced, _prereq_results: ChartStatusEffect(
            effect_id="chart_status",
            description=f"Show status for chart {cmd.chart_name}",
            chart_name=cmd.chart_name,
        ),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_chart_deploy_effect(
    cmd: ChartDeployCommand, prereq_results: PrereqResults
) -> ChartDeployEffect:
    """Build ChartDeployEffect from prerequisite settings and auto-generated secrets."""
    from prodbox.lib.chart_platform import (
        build_chart_deployment_plan,
        resolve_chart_secrets,
        resolve_gateway_event_keys,
    )

    settings = _require_settings(prereq_results)
    chart_secrets = resolve_chart_secrets(cmd.chart_name)
    gateway_event_keys = resolve_gateway_event_keys(cmd.chart_name)
    match build_chart_deployment_plan(
        cmd.chart_name, settings, chart_secrets, gateway_event_keys=gateway_event_keys
    ):
        case Failure(error=error):
            raise ValueError(error)
        case Success(value=plan):
            return ChartDeployEffect(
                effect_id="chart_deploy",
                description=f"Deploy chart stack {cmd.chart_name}",
                plan=plan,
            )


def _build_chart_deploy_dag(cmd: ChartDeployCommand) -> EffectDAG:
    """Build DAG for deploying a root chart stack."""
    root = EffectNode(
        effect=ChartDeployEffect(
            effect_id="chart_deploy",
            description=f"Deploy chart stack {cmd.chart_name}",
            plan=None,
        ),
        prerequisites=frozenset(["settings_object"]),
        effect_builder=lambda _reduced, prereq_results: _build_chart_deploy_effect(
            cmd,
            prereq_results,
        ),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_chart_delete_effect(cmd: ChartDeleteCommand) -> ChartDeleteEffect:
    """Build ChartDeleteEffect via pure plan resolution (no settings needed for delete)."""
    from prodbox.lib.chart_platform import build_chart_delete_plan

    match build_chart_delete_plan(cmd.chart_name):
        case Failure(error=error):
            raise ValueError(error)
        case Success(value=plan):
            return ChartDeleteEffect(
                effect_id="chart_delete",
                description=f"Delete chart stack {cmd.chart_name}",
                plan=plan,
            )


def _build_chart_delete_dag(cmd: ChartDeleteCommand) -> EffectDAG:
    """Build DAG for deleting a root chart stack."""
    root = EffectNode(
        effect=ChartDeleteEffect(
            effect_id="chart_delete",
            description=f"Delete chart stack {cmd.chart_name}",
            plan=None,
        ),
        prerequisites=frozenset(),
        effect_builder=lambda _reduced, _prereq_results: _build_chart_delete_effect(cmd),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


# =============================================================================
# Exports
# =============================================================================

__all__ = [
    "command_to_dag",
]
