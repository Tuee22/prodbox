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

from pathlib import Path

from prodbox.cli.command_adt import (
    ChartDeleteCommand,
    ChartDeployCommand,
    ChartListCommand,
    ChartStatusCommand,
    Command,
    DNSCheckCommand,
    EnvShowCommand,
    EnvTemplateCommand,
    EnvValidateCommand,
    GatewayConfigGenCommand,
    GatewayStartCommand,
    GatewayStatusCommand,
    HostCheckPortsCommand,
    HostEnsureToolsCommand,
    HostFirewallCommand,
    HostInfoCommand,
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
from prodbox.cli.effect_dag import EffectDAG, EffectNode
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
    RunKubectlCommand,
    RunPulumiCommand,
    RunSystemdCommand,
    Sequence,
    StartGatewayDaemon,
    ValidateSettings,
    ValidateTool,
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
from prodbox.settings import RenderedSettingValue, render_settings_display

# =============================================================================
# Shared Helpers
# =============================================================================


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


def _merge_registry(*nodes: EffectNode[object]) -> dict[str, EffectNode[object]]:
    """Merge local command-specific nodes into the canonical prerequisite registry."""
    return dict(PREREQUISITE_REGISTRY) | {node.effect_id: node for node in nodes}


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


def _raise_effect_error(message: str) -> object:
    """Raise a deterministic failure from an effect-builder helper."""
    raise ValueError(message)


def _resolve_pulumi_stack(cmd_stack: str | None, prereq_results: PrereqResults) -> str:
    """Resolve Pulumi stack from explicit command input or settings default."""
    match cmd_stack:
        case str() as explicit_stack:
            return explicit_stack
        case None:
            return _require_setting_string(_require_settings(prereq_results), "pulumi_stack")


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
            RunSystemdCommand(
                effect_id="rke2_ensure_enable",
                description="Enable RKE2 service",
                action="enable",
                service="rke2-server.service",
                sudo=True,
            ),
            RunSystemdCommand(
                effect_id="rke2_ensure_start",
                description="Start RKE2 service",
                action="start",
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
    return Sequence(
        effect_id="rke2_cleanup",
        description="Cleanup prodbox-annotated Kubernetes resources without touching host paths",
        effects=[
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
    stack = _resolve_pulumi_stack(cmd.stack, prereq_results)
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
# Environment Command Builders
# =============================================================================


def _build_env_show_dag(_cmd: EnvShowCommand) -> EffectDAG:
    """Build DAG for showing environment configuration."""
    cmd = _cmd
    root = EffectNode(
        effect=WriteStdout(
            effect_id="env_show",
            description="Show environment configuration",
            text="",
        ),
        prerequisites=frozenset(["settings_object"]),
        effect_builder=lambda _reduced, prereq_results: WriteStdout(
            effect_id="env_show",
            description="Show environment configuration",
            text=render_settings_display(
                _require_settings(prereq_results),
                show_secrets=cmd.show_secrets,
            ),
        ),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_env_validate_dag(_cmd: EnvValidateCommand) -> EffectDAG:
    """Build DAG for validating environment configuration."""
    root = EffectNode(
        effect=ValidateSettings(
            effect_id="env_validate",
            description="Validate environment configuration",
        ),
        prerequisites=frozenset(["settings_loaded"]),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


def _build_env_template_dag(cmd: EnvTemplateCommand) -> EffectDAG:
    """Build DAG for generating environment template."""
    root = EffectNode(
        effect=WriteStdout(
            effect_id="env_template",
            description="Print environment template",
            text=cmd.template_text,
        ),
        prerequisites=frozenset(),
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
        prerequisites=frozenset(["pulumi_logged_in", "settings_object"]),
        effect_builder=lambda _reduced, prereq_results: PulumiStackSelect(
            effect_id="pulumi_preview_stack_select",
            description="Select Pulumi stack for preview",
            stack=_resolve_pulumi_stack(cmd.stack, prereq_results),
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
            stack=_resolve_pulumi_stack(cmd.stack, prereq_results),
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
            create_if_missing=False,
        ),
        prerequisites=frozenset(["pulumi_logged_in", "settings_object"]),
        effect_builder=lambda _reduced, prereq_results: PulumiStackSelect(
            effect_id="pulumi_up_stack_select",
            description="Select Pulumi stack for apply",
            stack=_resolve_pulumi_stack(cmd.stack, prereq_results),
            cwd=cmd.cwd,
            create_if_missing=False,
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
        prerequisites=frozenset(["pulumi_logged_in", "settings_object"]),
        effect_builder=lambda _reduced, prereq_results: PulumiStackSelect(
            effect_id="pulumi_destroy_stack_select",
            description="Select Pulumi stack for destroy",
            stack=_resolve_pulumi_stack(cmd.stack, prereq_results),
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
            stack=_resolve_pulumi_stack(cmd.stack, prereq_results),
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
            create_if_missing=False,
        ),
        prerequisites=frozenset(["pulumi_logged_in", "settings_object"]),
        effect_builder=lambda _reduced, prereq_results: PulumiStackSelect(
            effect_id="pulumi_refresh_stack_select",
            description="Select Pulumi stack for refresh",
            stack=_resolve_pulumi_stack(cmd.stack, prereq_results),
            cwd=cmd.cwd,
            create_if_missing=False,
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
            stack=_resolve_pulumi_stack(cmd.stack, prereq_results),
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
        # Environment commands
        case EnvShowCommand():
            return Success(_build_env_show_dag(command))
        case EnvValidateCommand():
            return Success(_build_env_validate_dag(command))
        case EnvTemplateCommand():
            return Success(_build_env_template_dag(command))

        # Host commands
        case HostInfoCommand():
            return Success(_build_host_info_dag(command))
        case HostCheckPortsCommand():
            return Success(_build_host_check_ports_dag(command))
        case HostEnsureToolsCommand():
            return Success(_build_host_ensure_tools_dag(command))
        case HostFirewallCommand():
            return Success(_build_host_firewall_dag(command))

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
    root = EffectNode(
        effect=QueryGatewayState(
            effect_id="query_gateway_state",
            description="Query gateway daemon state",
            config_path=cmd.config_path,
        ),
        prerequisites=frozenset(),
    )
    return EffectDAG.from_roots(root, registry=PREREQUISITE_REGISTRY)


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
    """Build ChartDeployEffect from prerequisite settings (pure plan resolution)."""
    from prodbox.lib.chart_platform import build_chart_deployment_plan

    settings = _require_settings(prereq_results)
    match build_chart_deployment_plan(cmd.chart_name, settings):
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
