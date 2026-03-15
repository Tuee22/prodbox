"""Unit tests for effects module."""

from __future__ import annotations

from pathlib import Path

import pytest

from prodbox.cli.effects import (
    AnnotateProdboxManagedResources,
    CaptureKubectlOutput,
    CaptureSubprocessOutput,
    # File system
    CheckFileExists,
    CheckServiceStatus,
    CleanupProdboxAnnotatedResources,
    ConfirmAction,
    Custom,
    # DNS / Route 53
    EnsureHarborRegistry,
    EnsureMinio,
    EnsureProdboxIdentityConfigMap,
    EnsureRetainedLocalStorage,
    FetchPublicIP,
    GetJournalLogs,
    HarborRuntime,
    KubectlWait,
    # Settings
    LoadSettings,
    MachineIdentity,
    MinioRuntime,
    Parallel,
    PrintBlankLine,
    PrintError,
    PrintIndented,
    PrintInfo,
    PrintSection,
    PrintSuccess,
    PrintTable,
    PrintWarning,
    PulumiDestroy,
    PulumiPreview,
    PulumiRefresh,
    PulumiStackSelect,
    PulumiUp,
    # Pure / Custom
    Pure,
    QueryRoute53Record,
    ReadFile,
    # Platform effects
    RequireLinux,
    RequireSystemd,
    ResolveMachineIdentity,
    # Kubernetes
    RunKubectlCommand,
    # Pulumi
    RunPulumiCommand,
    # Subprocess
    RunSubprocess,
    # Systemd
    RunSystemdCommand,
    # Composite
    Sequence,
    StorageRuntime,
    Try,
    UpdateRoute53Record,
    ValidateAWSCredentials,
    ValidateEnvironment,
    ValidateSettings,
    # Tool validation
    ValidateTool,
    WriteFile,
    WriteStderr,
    # Output
    WriteStdout,
)


class TestPlatformEffects:
    """Tests for platform detection effects."""

    def test_require_linux(self) -> None:
        """RequireLinux should have correct fields."""
        effect = RequireLinux(
            effect_id="platform_linux",
            description="Require Linux platform",
        )
        assert effect.effect_id == "platform_linux"
        assert effect.description == "Require Linux platform"

    def test_require_systemd(self) -> None:
        """RequireSystemd should have correct fields."""
        effect = RequireSystemd(
            effect_id="systemd_available",
            description="Require systemd",
        )
        assert effect.effect_id == "systemd_available"

    def test_resolve_machine_identity(self) -> None:
        """ResolveMachineIdentity should default to /etc/machine-id."""
        effect = ResolveMachineIdentity(
            effect_id="machine_identity",
            description="Resolve machine identity",
        )
        assert str(effect.file_path) == "/etc/machine-id"


class TestToolValidationEffects:
    """Tests for tool validation effects."""

    def test_validate_tool(self) -> None:
        """ValidateTool should hold tool name."""
        effect = ValidateTool(
            effect_id="tool_kubectl",
            description="Validate kubectl",
            tool_name="kubectl",
        )
        assert effect.tool_name == "kubectl"

    def test_validate_environment(self) -> None:
        """ValidateEnvironment should hold tool list."""
        effect = ValidateEnvironment(
            effect_id="tools_check",
            description="Validate tools",
            tools=["kubectl", "helm", "pulumi"],
        )
        assert effect.tools == ["kubectl", "helm", "pulumi"]


class TestFileSystemEffects:
    """Tests for file system effects."""

    def test_check_file_exists(self) -> None:
        """CheckFileExists should hold file path."""
        effect = CheckFileExists(
            effect_id="kubeconfig_exists",
            description="Check kubeconfig",
            file_path=Path("/etc/rancher/rke2/rke2.yaml"),
        )
        assert effect.file_path == Path("/etc/rancher/rke2/rke2.yaml")

    def test_read_file(self) -> None:
        """ReadFile should hold file path."""
        effect = ReadFile(
            effect_id="read_config",
            description="Read config",
            file_path=Path("/etc/config.yaml"),
        )
        assert effect.file_path == Path("/etc/config.yaml")

    def test_write_file_defaults(self) -> None:
        """WriteFile should have correct defaults."""
        effect = WriteFile(
            effect_id="write_config",
            description="Write config",
            file_path=Path("/tmp/config.yaml"),
            content="key: value",
        )
        assert effect.file_path == Path("/tmp/config.yaml")
        assert effect.content == "key: value"
        assert effect.sudo is False

    def test_write_file_with_sudo(self) -> None:
        """WriteFile should support sudo option."""
        effect = WriteFile(
            effect_id="write_system_config",
            description="Write system config",
            file_path=Path("/etc/config.yaml"),
            content="key: value",
            sudo=True,
        )
        assert effect.sudo is True


class TestSubprocessEffects:
    """Tests for subprocess effects."""

    def test_run_subprocess_minimal(self) -> None:
        """RunSubprocess should work with minimal args."""
        effect = RunSubprocess(
            effect_id="echo",
            description="Echo test",
            command=["echo", "hello"],
        )
        assert effect.command == ["echo", "hello"]
        assert effect.cwd is None
        assert effect.env is None
        assert effect.timeout is None
        assert effect.capture_output is True

    def test_run_subprocess_full(self) -> None:
        """RunSubprocess should accept all options."""
        effect = RunSubprocess(
            effect_id="build",
            description="Build project",
            command=["make", "build"],
            cwd=Path("/project"),
            env={"CC": "clang"},
            timeout=60.0,
            capture_output=False,
            input_data=b"input",
        )
        assert effect.cwd == Path("/project")
        assert effect.env == {"CC": "clang"}
        assert effect.timeout == 60.0
        assert effect.capture_output is False
        assert effect.input_data == b"input"

    def test_capture_subprocess_output(self) -> None:
        """CaptureSubprocessOutput should hold command."""
        effect = CaptureSubprocessOutput(
            effect_id="capture_output",
            description="Capture output",
            command=["ls", "-la"],
        )
        assert effect.command == ["ls", "-la"]


class TestSystemdEffects:
    """Tests for systemd effects."""

    def test_run_systemd_command(self) -> None:
        """RunSystemdCommand should hold action and service."""
        effect = RunSystemdCommand(
            effect_id="start_rke2",
            description="Start RKE2",
            action="start",
            service="rke2-server.service",
            sudo=True,
        )
        assert effect.action == "start"
        assert effect.service == "rke2-server.service"
        assert effect.sudo is True

    def test_check_service_status(self) -> None:
        """CheckServiceStatus should hold service name."""
        effect = CheckServiceStatus(
            effect_id="check_rke2",
            description="Check RKE2",
            service="rke2-server.service",
        )
        assert effect.service == "rke2-server.service"

    def test_get_journal_logs(self) -> None:
        """GetJournalLogs should hold service and lines."""
        effect = GetJournalLogs(
            effect_id="rke2_logs",
            description="Get RKE2 logs",
            service="rke2-server.service",
            lines=100,
        )
        assert effect.service == "rke2-server.service"
        assert effect.lines == 100


class TestKubernetesEffects:
    """Tests for Kubernetes effects."""

    def test_run_kubectl_command_minimal(self) -> None:
        """RunKubectlCommand should work with minimal args."""
        effect = RunKubectlCommand(
            effect_id="get_pods",
            description="Get pods",
            args=["get", "pods"],
        )
        assert effect.args == ["get", "pods"]
        assert effect.kubeconfig is None
        assert effect.namespace is None

    def test_run_kubectl_command_full(self) -> None:
        """RunKubectlCommand should accept all options."""
        effect = RunKubectlCommand(
            effect_id="get_pods",
            description="Get pods",
            args=["get", "pods"],
            kubeconfig=Path("/etc/rancher/rke2/rke2.yaml"),
            namespace="kube-system",
            timeout=30.0,
            stream_stdout=True,
        )
        assert effect.kubeconfig == Path("/etc/rancher/rke2/rke2.yaml")
        assert effect.namespace == "kube-system"
        assert effect.timeout == 30.0
        assert effect.stream_stdout is True

    def test_capture_kubectl_output(self) -> None:
        """CaptureKubectlOutput should capture output."""
        effect = CaptureKubectlOutput(
            effect_id="get_nodes",
            description="Get nodes",
            args=["get", "nodes", "-o", "json"],
        )
        assert effect.args == ["get", "nodes", "-o", "json"]

    def test_kubectl_wait(self) -> None:
        """KubectlWait should hold wait conditions."""
        effect = KubectlWait(
            effect_id="wait_deploy",
            description="Wait for deployment",
            resource="deployment/nginx",
            condition="available",
            timeout=300,
        )
        assert effect.resource == "deployment/nginx"
        assert effect.condition == "available"
        assert effect.timeout == 300

    def test_ensure_prodbox_identity_configmap(self) -> None:
        """EnsureProdboxIdentityConfigMap should hold identity and metadata settings."""
        identity = MachineIdentity(
            machine_id="0123456789abcdef0123456789abcdef",
            prodbox_id="prodbox-0123456789abcdef0123456789abcdef",
        )
        effect = EnsureProdboxIdentityConfigMap(
            effect_id="ensure_prodbox_identity",
            description="Ensure prodbox identity configmap",
            machine_identity=identity,
            namespace="prodbox",
            configmap_name="prodbox-identity",
            annotation_key="prodbox.io/id",
            label_key="prodbox.io/id",
            label_value="prodbox-0123456789abcdef0123456789abcdef",
        )
        assert effect.machine_identity.prodbox_id.startswith("prodbox-")
        assert effect.namespace == "prodbox"

    def test_ensure_harbor_registry(self) -> None:
        """EnsureHarborRegistry should hold registry/mirror/build settings."""
        identity = MachineIdentity(
            machine_id="0123456789abcdef0123456789abcdef",
            prodbox_id="prodbox-0123456789abcdef0123456789abcdef",
        )
        effect = EnsureHarborRegistry(
            effect_id="ensure_harbor_registry",
            description="Ensure Harbor runtime",
            machine_identity=identity,
            namespace="harbor",
            release_name="harbor",
            repository_name="harbor",
            repository_url="https://helm.goharbor.io",
            registry_endpoint="127.0.0.1:30080",
            mirror_project="prodbox",
            gateway_image_repository="prodbox/prodbox-gateway",
            gateway_dockerfile=Path("docker/gateway.Dockerfile"),
            gateway_build_context=Path("."),
            registries_file_path=Path("/etc/rancher/rke2/registries.yaml"),
        )
        assert effect.registry_endpoint == "127.0.0.1:30080"
        assert effect.gateway_image_repository == "prodbox/prodbox-gateway"
        assert effect.mirror_cluster_images is True

    def test_harbor_runtime(self) -> None:
        """HarborRuntime should expose endpoint and gateway image references."""
        runtime = HarborRuntime(
            registry_endpoint="127.0.0.1:30080",
            gateway_image="127.0.0.1:30080/prodbox/prodbox-gateway:abc",
        )
        assert runtime.registry_endpoint == "127.0.0.1:30080"
        assert runtime.gateway_image.endswith(":abc")

    def test_ensure_retained_local_storage(self) -> None:
        """EnsureRetainedLocalStorage should hold deterministic storage binding settings."""
        identity = MachineIdentity(
            machine_id="0123456789abcdef0123456789abcdef",
            prodbox_id="prodbox-0123456789abcdef0123456789abcdef",
        )
        effect = EnsureRetainedLocalStorage(
            effect_id="ensure_retained_storage",
            description="Ensure retained storage",
            machine_identity=identity,
            namespace="prodbox",
            storage_class_name="prodbox-local-retain",
            persistent_volume_name="prodbox-minio-pv-0",
            persistent_volume_claim_name="minio",
            storage_size="200Gi",
            host_storage_base_path=Path("/var/lib/prodbox/storage"),
            annotation_key="prodbox.io/id",
            label_key="prodbox.io/id",
            label_value="prodbox-0123456789abcdef0123456789abcdef",
        )
        assert effect.storage_class_name == "prodbox-local-retain"
        assert effect.persistent_volume_name == "prodbox-minio-pv-0"
        assert effect.persistent_volume_claim_name == "minio"

    def test_ensure_minio(self) -> None:
        """EnsureMinio should hold chart and PVC settings."""
        identity = MachineIdentity(
            machine_id="0123456789abcdef0123456789abcdef",
            prodbox_id="prodbox-0123456789abcdef0123456789abcdef",
        )
        effect = EnsureMinio(
            effect_id="ensure_minio",
            description="Ensure MinIO runtime",
            machine_identity=identity,
            namespace="prodbox",
            release_name="minio",
            repository_name="minio",
            repository_url="https://charts.min.io/",
            chart_ref="minio/minio",
            chart_version="5.4.0",
            existing_claim="minio",
            annotation_key="prodbox.io/id",
            label_key="prodbox.io/id",
            label_value="prodbox-0123456789abcdef0123456789abcdef",
            storage_size="200Gi",
        )
        assert effect.chart_ref == "minio/minio"
        assert effect.existing_claim == "minio"

    def test_storage_runtime(self) -> None:
        """StorageRuntime should expose reconciled storage coordinates."""
        runtime = StorageRuntime(
            storage_class_name="prodbox-local-retain",
            persistent_volume_name="prodbox-minio-pv-0",
            persistent_volume_claim_name="minio",
            host_path=Path("/var/lib/prodbox/storage/prodbox-id/prodbox-minio-pv-0"),
        )
        assert runtime.storage_class_name == "prodbox-local-retain"
        assert runtime.persistent_volume_claim_name == "minio"

    def test_minio_runtime(self) -> None:
        """MinioRuntime should expose release namespace and PVC."""
        runtime = MinioRuntime(
            namespace="prodbox",
            release_name="minio",
            persistent_volume_claim_name="minio",
        )
        assert runtime.namespace == "prodbox"
        assert runtime.release_name == "minio"

    def test_annotate_prodbox_managed_resources(self) -> None:
        """AnnotateProdboxManagedResources should hold selector and target info."""
        effect = AnnotateProdboxManagedResources(
            effect_id="annotate_prodbox",
            description="Annotate managed resources",
            prodbox_id="prodbox-0123456789abcdef0123456789abcdef",
            annotation_key="prodbox.io/id",
            label_key="prodbox.io/id",
            label_value="prodbox-0123456789abcdef0123456789abcdef",
            managed_namespaces=("prodbox", "metallb-system"),
            helm_instances=("metallb",),
        )
        assert effect.managed_namespaces == ("prodbox", "metallb-system")
        assert effect.helm_instances == ("metallb",)

    def test_cleanup_prodbox_annotated_resources(self) -> None:
        """CleanupProdboxAnnotatedResources should hold cleanup selectors."""
        effect = CleanupProdboxAnnotatedResources(
            effect_id="cleanup_prodbox",
            description="Cleanup annotated resources",
            prodbox_id="prodbox-0123456789abcdef0123456789abcdef",
            annotation_key="prodbox.io/id",
            cleanup_passes=3,
            retained_resource_kinds=("persistentvolumeclaims", "persistentvolumes"),
            retained_namespaces=("prodbox",),
        )
        assert effect.cleanup_passes == 3
        assert "persistentvolumes" in effect.retained_resource_kinds
        assert effect.retained_namespaces == ("prodbox",)


class TestDNSEffects:
    """Tests for DNS / Route 53 effects."""

    def test_fetch_public_ip(self) -> None:
        """FetchPublicIP should have correct id."""
        effect = FetchPublicIP(
            effect_id="fetch_ip",
            description="Fetch public IP",
        )
        assert effect.effect_id == "fetch_ip"

    def test_query_route53_record(self) -> None:
        """QueryRoute53Record should hold AWS credentials."""
        effect = QueryRoute53Record(
            effect_id="query_dns",
            description="Query DNS",
            zone_id="Z123456",
            fqdn="test.example.com",
            aws_access_key_id="AKIA...",
            aws_secret_access_key="secret",
            aws_region="us-east-1",
        )
        assert effect.zone_id == "Z123456"
        assert effect.fqdn == "test.example.com"
        assert effect.aws_region == "us-east-1"

    def test_update_route53_record(self) -> None:
        """UpdateRoute53Record should hold all fields."""
        effect = UpdateRoute53Record(
            effect_id="update_dns",
            description="Update DNS",
            zone_id="Z123456",
            fqdn="test.example.com",
            ip="1.2.3.4",
            ttl=60,
            aws_access_key_id="AKIA...",
            aws_secret_access_key="secret",
            aws_region="us-east-1",
        )
        assert effect.ip == "1.2.3.4"
        assert effect.ttl == 60

    def test_validate_aws_credentials(self) -> None:
        """ValidateAWSCredentials should hold credentials."""
        effect = ValidateAWSCredentials(
            effect_id="validate_aws",
            description="Validate AWS",
            aws_access_key_id="AKIA...",
            aws_secret_access_key="secret",
            aws_region="us-east-1",
        )
        assert effect.aws_access_key_id == "AKIA..."


class TestPulumiEffects:
    """Tests for Pulumi effects."""

    def test_run_pulumi_command(self) -> None:
        """RunPulumiCommand should hold args."""
        effect = RunPulumiCommand(
            effect_id="pulumi_cmd",
            description="Run Pulumi",
            args=["stack", "ls"],
        )
        assert effect.args == ["stack", "ls"]

    def test_pulumi_stack_select(self) -> None:
        """PulumiStackSelect should hold stack name."""
        effect = PulumiStackSelect(
            effect_id="select_stack",
            description="Select stack",
            stack="dev",
            create_if_missing=True,
        )
        assert effect.stack == "dev"
        assert effect.create_if_missing is True

    def test_pulumi_preview(self) -> None:
        """PulumiPreview should hold options."""
        effect = PulumiPreview(
            effect_id="preview",
            description="Preview changes",
            cwd=Path("/infra"),
            stack="dev",
        )
        assert effect.cwd == Path("/infra")
        assert effect.stack == "dev"

    def test_pulumi_up(self) -> None:
        """PulumiUp should hold options."""
        effect = PulumiUp(
            effect_id="up",
            description="Apply changes",
            yes=True,
        )
        assert effect.yes is True

    def test_pulumi_destroy(self) -> None:
        """PulumiDestroy should hold options."""
        effect = PulumiDestroy(
            effect_id="destroy",
            description="Destroy infrastructure",
            yes=False,
        )
        assert effect.yes is False

    def test_pulumi_refresh(self) -> None:
        """PulumiRefresh should hold options."""
        effect = PulumiRefresh(
            effect_id="refresh",
            description="Refresh state",
            stack="prod",
        )
        assert effect.stack == "prod"


class TestSettingsEffects:
    """Tests for settings effects."""

    def test_load_settings(self) -> None:
        """LoadSettings should have correct id."""
        effect = LoadSettings(
            effect_id="load_settings",
            description="Load settings",
        )
        assert effect.effect_id == "load_settings"

    def test_validate_settings(self) -> None:
        """ValidateSettings should have correct id."""
        effect = ValidateSettings(
            effect_id="validate_settings",
            description="Validate settings",
        )
        assert effect.effect_id == "validate_settings"


class TestOutputEffects:
    """Tests for output effects."""

    def test_write_stdout(self) -> None:
        """WriteStdout should hold text."""
        effect = WriteStdout(
            effect_id="write_out",
            description="Write output",
            text="Hello, World!\n",
        )
        assert effect.text == "Hello, World!\n"

    def test_write_stderr(self) -> None:
        """WriteStderr should hold text."""
        effect = WriteStderr(
            effect_id="write_err",
            description="Write error",
            text="Error occurred\n",
        )
        assert effect.text == "Error occurred\n"

    def test_print_info(self) -> None:
        """PrintInfo should have correct defaults."""
        effect = PrintInfo(
            effect_id="print_info",
            description="Print info",
            message="Information",
        )
        assert effect.message == "Information"
        assert effect.style == "blue"

    def test_print_success(self) -> None:
        """PrintSuccess should have correct defaults."""
        effect = PrintSuccess(
            effect_id="print_success",
            description="Print success",
            message="Success!",
        )
        assert effect.message == "Success!"
        assert effect.style == "green"

    def test_print_warning(self) -> None:
        """PrintWarning should have correct defaults."""
        effect = PrintWarning(
            effect_id="print_warning",
            description="Print warning",
            message="Warning!",
        )
        assert effect.message == "Warning!"
        assert effect.style == "yellow"

    def test_print_error(self) -> None:
        """PrintError should have correct defaults."""
        effect = PrintError(
            effect_id="print_error",
            description="Print error",
            message="Error!",
        )
        assert effect.message == "Error!"
        assert effect.style == "red"

    def test_print_table(self) -> None:
        """PrintTable should hold table data."""
        effect = PrintTable(
            effect_id="print_table",
            description="Print table",
            title="Test Table",
            columns=(("Name", "cyan"), ("Value", "green")),
            rows=(("key1", "value1"), ("key2", "value2")),
        )
        assert effect.title == "Test Table"
        assert len(effect.columns) == 2
        assert len(effect.rows) == 2

    def test_print_section(self) -> None:
        """PrintSection should hold section data."""
        effect = PrintSection(
            effect_id="print_section",
            description="Print section",
            title="Section Title",
            blank_before=True,
            blank_after=True,
        )
        assert effect.title == "Section Title"
        assert effect.blank_before is True
        assert effect.blank_after is True

    def test_print_indented(self) -> None:
        """PrintIndented should hold indent and text."""
        effect = PrintIndented(
            effect_id="print_indented",
            description="Print indented",
            text="Indented text",
            indent=4,
        )
        assert effect.text == "Indented text"
        assert effect.indent == 4

    def test_print_blank_line(self) -> None:
        """PrintBlankLine should have correct id."""
        effect = PrintBlankLine(
            effect_id="blank",
            description="Print blank line",
        )
        assert effect.effect_id == "blank"

    def test_confirm_action(self) -> None:
        """ConfirmAction should hold confirmation options."""
        effect = ConfirmAction(
            effect_id="confirm",
            description="Confirm action",
            message="Are you sure?",
            default=False,
            abort_on_decline=True,
        )
        assert effect.message == "Are you sure?"
        assert effect.default is False
        assert effect.abort_on_decline is True


class TestCompositeEffects:
    """Tests for composite effects."""

    def test_sequence(self) -> None:
        """Sequence should hold list of effects."""
        effect1 = PrintInfo(effect_id="info1", description="Info 1", message="First")
        effect2 = PrintInfo(effect_id="info2", description="Info 2", message="Second")

        seq = Sequence(
            effect_id="sequence",
            description="Sequence",
            effects=[effect1, effect2],
        )

        assert len(seq.effects) == 2

    def test_parallel(self) -> None:
        """Parallel should hold list of effects."""
        effect1 = FetchPublicIP(effect_id="ip1", description="Fetch IP 1")
        effect2 = FetchPublicIP(effect_id="ip2", description="Fetch IP 2")

        par = Parallel(
            effect_id="parallel",
            description="Parallel",
            effects=[effect1, effect2],
        )

        assert len(par.effects) == 2
        assert par.max_concurrent is None

    def test_parallel_with_limit(self) -> None:
        """Parallel should accept max_concurrent."""
        par = Parallel(
            effect_id="parallel",
            description="Parallel",
            effects=[],
            max_concurrent=5,
        )
        assert par.max_concurrent == 5

    def test_try_effect(self) -> None:
        """Try should hold primary and fallback."""
        primary = RunSubprocess(
            effect_id="primary",
            description="Primary",
            command=["kubectl", "get", "nodes"],
        )
        fallback = PrintError(
            effect_id="fallback",
            description="Fallback",
            message="Primary failed",
        )

        try_effect = Try(
            effect_id="try",
            description="Try with fallback",
            primary=primary,
            fallback=fallback,
        )

        assert try_effect.primary is primary
        assert try_effect.fallback is fallback


class TestPureAndCustomEffects:
    """Tests for Pure and Custom effects."""

    def test_pure_effect(self) -> None:
        """Pure should hold a value."""
        effect: Pure[int] = Pure(
            effect_id="pure_int",
            description="Pure integer",
            value=42,
        )
        assert effect.value == 42

    def test_pure_effect_with_complex_value(self) -> None:
        """Pure should accept complex values."""
        effect: Pure[dict[str, int]] = Pure(
            effect_id="pure_dict",
            description="Pure dict",
            value={"a": 1, "b": 2},
        )
        assert effect.value == {"a": 1, "b": 2}

    def test_custom_effect(self) -> None:
        """Custom should hold a callable."""

        def my_fn() -> str:
            return "custom result"

        effect: Custom[str] = Custom(
            effect_id="custom",
            description="Custom effect",
            fn=my_fn,
        )
        assert effect.fn() == "custom result"

    def test_custom_effect_async(self) -> None:
        """Custom should accept async callable."""

        async def async_fn() -> int:
            return 42

        effect: Custom[int] = Custom(
            effect_id="async_custom",
            description="Async custom",
            fn=async_fn,
        )
        # Just verify it stores the function
        assert effect.fn is async_fn


class TestEffectImmutability:
    """Tests for effect immutability."""

    def test_effects_are_frozen(self) -> None:
        """Effects should be immutable."""
        effect = Pure(effect_id="test", description="Test", value="hello")

        with pytest.raises(AttributeError):
            effect.value = "modified"  # type: ignore[misc]

    def test_run_subprocess_is_frozen(self) -> None:
        """RunSubprocess should be immutable."""
        effect = RunSubprocess(
            effect_id="test",
            description="Test",
            command=["echo"],
        )

        with pytest.raises(AttributeError):
            effect.command = ["modified"]  # type: ignore[misc]

    def test_sequence_is_frozen(self) -> None:
        """Sequence should be immutable."""
        effect = Sequence(
            effect_id="seq",
            description="Sequence",
            effects=[],
        )

        with pytest.raises(AttributeError):
            effect.effects = [Pure(effect_id="new", description="New", value=1)]  # type: ignore[misc]

    def test_parallel_is_frozen(self) -> None:
        """Parallel should be immutable."""
        effect = Parallel(
            effect_id="par",
            description="Parallel",
            effects=[],
        )

        with pytest.raises(AttributeError):
            effect.max_concurrent = 10  # type: ignore[misc]

    def test_try_is_frozen(self) -> None:
        """Try should be immutable."""
        primary = Pure(effect_id="p", description="P", value=1)
        fallback = Pure(effect_id="f", description="F", value=2)
        effect = Try(
            effect_id="try",
            description="Try",
            primary=primary,
            fallback=fallback,
        )

        with pytest.raises(AttributeError):
            effect.primary = fallback  # type: ignore[misc]


class TestEffectBaseClass:
    """Tests for Effect base class attributes."""

    def test_all_effects_have_effect_id(self) -> None:
        """All effect types should have effect_id attribute."""
        effect_instances = [
            RequireLinux(effect_id="e1", description="d1"),
            RequireSystemd(effect_id="e2", description="d2"),
            ValidateTool(effect_id="e3", description="d3", tool_name="kubectl"),
            ValidateEnvironment(effect_id="e4", description="d4", tools=["a"]),
            CheckFileExists(effect_id="e5", description="d5", file_path=Path("/tmp")),
            ReadFile(effect_id="e6", description="d6", file_path=Path("/tmp")),
            WriteFile(effect_id="e7", description="d7", file_path=Path("/tmp"), content="x"),
            RunSubprocess(effect_id="e8", description="d8", command=["echo"]),
            CaptureSubprocessOutput(effect_id="e9", description="d9", command=["ls"]),
            RunSystemdCommand(effect_id="e10", description="d10", action="start", service="svc"),
            CheckServiceStatus(effect_id="e11", description="d11", service="svc"),
            GetJournalLogs(effect_id="e12", description="d12", service="svc"),
            RunKubectlCommand(effect_id="e13", description="d13", args=["get", "pods"]),
            CaptureKubectlOutput(effect_id="e14", description="d14", args=["get", "nodes"]),
            KubectlWait(effect_id="e15", description="d15", resource="deploy/x", condition="avail"),
            EnsureHarborRegistry(
                effect_id="e15b",
                description="d15b",
                machine_identity=MachineIdentity(
                    machine_id="0123456789abcdef0123456789abcdef",
                    prodbox_id="prodbox-0123456789abcdef0123456789abcdef",
                ),
                namespace="harbor",
                release_name="harbor",
                repository_name="harbor",
                repository_url="https://helm.goharbor.io",
                registry_endpoint="127.0.0.1:30080",
                mirror_project="prodbox",
                gateway_image_repository="prodbox/prodbox-gateway",
                gateway_dockerfile=Path("docker/gateway.Dockerfile"),
                gateway_build_context=Path("."),
                registries_file_path=Path("/etc/rancher/rke2/registries.yaml"),
            ),
            EnsureRetainedLocalStorage(
                effect_id="e15c",
                description="d15c",
                machine_identity=MachineIdentity(
                    machine_id="0123456789abcdef0123456789abcdef",
                    prodbox_id="prodbox-0123456789abcdef0123456789abcdef",
                ),
                namespace="prodbox",
                storage_class_name="prodbox-local-retain",
                persistent_volume_name="prodbox-minio-pv-0",
                persistent_volume_claim_name="minio",
                storage_size="200Gi",
                host_storage_base_path=Path("/var/lib/prodbox/storage"),
                annotation_key="prodbox.io/id",
                label_key="prodbox.io/id",
                label_value="prodbox-0123456789abcdef0123456789abcdef",
            ),
            EnsureMinio(
                effect_id="e15d",
                description="d15d",
                machine_identity=MachineIdentity(
                    machine_id="0123456789abcdef0123456789abcdef",
                    prodbox_id="prodbox-0123456789abcdef0123456789abcdef",
                ),
                namespace="prodbox",
                release_name="minio",
                repository_name="minio",
                repository_url="https://charts.min.io/",
                chart_ref="minio/minio",
                chart_version="5.4.0",
                existing_claim="minio",
                annotation_key="prodbox.io/id",
                label_key="prodbox.io/id",
                label_value="prodbox-0123456789abcdef0123456789abcdef",
                storage_size="200Gi",
            ),
            FetchPublicIP(effect_id="e16", description="d16"),
            QueryRoute53Record(
                effect_id="e17",
                description="d17",
                zone_id="z",
                fqdn="f",
                aws_access_key_id="a",
                aws_secret_access_key="s",
                aws_region="r",
            ),
            UpdateRoute53Record(
                effect_id="e18",
                description="d18",
                zone_id="z",
                fqdn="f",
                ip="1.2.3.4",
                ttl=60,
                aws_access_key_id="a",
                aws_secret_access_key="s",
                aws_region="r",
            ),
            ValidateAWSCredentials(
                effect_id="e19",
                description="d19",
                aws_access_key_id="a",
                aws_secret_access_key="s",
                aws_region="r",
            ),
            RunPulumiCommand(effect_id="e20", description="d20", args=["up"]),
            PulumiStackSelect(effect_id="e21", description="d21", stack="dev"),
            PulumiPreview(effect_id="e22", description="d22"),
            PulumiUp(effect_id="e23", description="d23"),
            PulumiDestroy(effect_id="e24", description="d24"),
            PulumiRefresh(effect_id="e25", description="d25"),
            LoadSettings(effect_id="e26", description="d26"),
            ValidateSettings(effect_id="e27", description="d27"),
            WriteStdout(effect_id="e28", description="d28", text="x"),
            WriteStderr(effect_id="e29", description="d29", text="x"),
            PrintInfo(effect_id="e30", description="d30", message="m"),
            PrintSuccess(effect_id="e31", description="d31", message="m"),
            PrintWarning(effect_id="e32", description="d32", message="m"),
            PrintError(effect_id="e33", description="d33", message="m"),
            PrintTable(effect_id="e34", description="d34", title="t", columns=(), rows=()),
            PrintSection(effect_id="e35", description="d35", title="t"),
            PrintIndented(effect_id="e36", description="d36", text="t"),
            PrintBlankLine(effect_id="e37", description="d37"),
            ConfirmAction(effect_id="e38", description="d38", message="m"),
            Sequence(effect_id="e39", description="d39", effects=[]),
            Parallel(effect_id="e40", description="d40", effects=[]),
            Try(
                effect_id="e41",
                description="d41",
                primary=Pure(effect_id="p", description="P", value=1),
                fallback=Pure(effect_id="f", description="F", value=2),
            ),
            Pure(effect_id="e42", description="d42", value=42),
            Custom(effect_id="e43", description="d43", fn=lambda: 1),
        ]

        for effect in effect_instances:
            assert hasattr(effect, "effect_id")
            assert isinstance(effect.effect_id, str)
            assert effect.effect_id.startswith("e")

    def test_all_effects_have_description(self) -> None:
        """All effect types should have description attribute."""
        effects = [
            Pure(effect_id="e1", description="Description 1", value=1),
            RunSubprocess(effect_id="e2", description="Description 2", command=["ls"]),
            Sequence(effect_id="e3", description="Description 3", effects=[]),
        ]

        for effect in effects:
            assert hasattr(effect, "description")
            assert isinstance(effect.description, str)
            assert len(effect.description) > 0


class TestEffectDefaults:
    """Tests for effect default values."""

    def test_validate_tool_defaults(self) -> None:
        """ValidateTool should have correct defaults."""
        effect = ValidateTool(
            effect_id="tool",
            description="Tool",
            tool_name="kubectl",
        )
        assert effect.version_flag == "--version"
        assert effect.min_version is None

    def test_run_subprocess_defaults(self) -> None:
        """RunSubprocess should have correct defaults."""
        effect = RunSubprocess(
            effect_id="sub",
            description="Subprocess",
            command=["echo"],
        )
        assert effect.cwd is None
        assert effect.env is None
        assert effect.timeout is None
        assert effect.capture_output is True
        assert effect.input_data is None

    def test_write_file_defaults(self) -> None:
        """WriteFile should have correct defaults."""
        effect = WriteFile(
            effect_id="write",
            description="Write",
            file_path=Path("/tmp/test"),
            content="content",
        )
        assert effect.sudo is False

    def test_run_kubectl_command_defaults(self) -> None:
        """RunKubectlCommand should have correct defaults."""
        effect = RunKubectlCommand(
            effect_id="kubectl",
            description="Kubectl",
            args=["get", "pods"],
        )
        assert effect.kubeconfig is None
        assert effect.namespace is None
        assert effect.timeout is None
        assert effect.stream_stdout is False

    def test_kubectl_wait_defaults(self) -> None:
        """KubectlWait should have correct defaults."""
        effect = KubectlWait(
            effect_id="wait",
            description="Wait",
            resource="deploy/nginx",
            condition="available",
        )
        assert effect.timeout == 300
        assert effect.kubeconfig is None
        assert effect.namespace is None

    def test_get_journal_logs_defaults(self) -> None:
        """GetJournalLogs should have correct defaults."""
        effect = GetJournalLogs(
            effect_id="logs",
            description="Logs",
            service="rke2-server",
        )
        assert effect.lines == 50

    def test_pulumi_stack_select_defaults(self) -> None:
        """PulumiStackSelect should have correct defaults."""
        effect = PulumiStackSelect(
            effect_id="select",
            description="Select",
            stack="dev",
        )
        assert effect.create_if_missing is False
        assert effect.cwd is None

    def test_pulumi_preview_defaults(self) -> None:
        """PulumiPreview should have correct defaults."""
        effect = PulumiPreview(
            effect_id="preview",
            description="Preview",
        )
        assert effect.cwd is None
        assert effect.stack is None

    def test_pulumi_up_defaults(self) -> None:
        """PulumiUp should have correct defaults."""
        effect = PulumiUp(
            effect_id="up",
            description="Up",
        )
        # Default is yes=True for safety (prompts user)
        assert effect.yes is True
        assert effect.cwd is None
        assert effect.stack is None

    def test_pulumi_destroy_defaults(self) -> None:
        """PulumiDestroy should have correct defaults."""
        effect = PulumiDestroy(
            effect_id="destroy",
            description="Destroy",
        )
        # Default is yes=True for safety (prompts user)
        assert effect.yes is True
        assert effect.cwd is None
        assert effect.stack is None

    def test_pulumi_refresh_defaults(self) -> None:
        """PulumiRefresh should have correct defaults."""
        effect = PulumiRefresh(
            effect_id="refresh",
            description="Refresh",
        )
        assert effect.cwd is None
        assert effect.stack is None

    def test_print_section_defaults(self) -> None:
        """PrintSection should have correct defaults."""
        effect = PrintSection(
            effect_id="section",
            description="Section",
            title="Title",
        )
        assert effect.blank_before is False
        assert effect.blank_after is True

    def test_print_indented_defaults(self) -> None:
        """PrintIndented should have correct defaults."""
        effect = PrintIndented(
            effect_id="indent",
            description="Indent",
            text="text",
        )
        assert effect.indent == 2

    def test_confirm_action_defaults(self) -> None:
        """ConfirmAction should have correct defaults."""
        effect = ConfirmAction(
            effect_id="confirm",
            description="Confirm",
            message="Continue?",
        )
        # Default is False (safer - requires explicit confirmation)
        assert effect.default is False
        # Default is True (aborts if user declines)
        assert effect.abort_on_decline is True

    def test_parallel_defaults(self) -> None:
        """Parallel should have correct defaults."""
        effect = Parallel(
            effect_id="par",
            description="Parallel",
            effects=[],
        )
        assert effect.max_concurrent is None


class TestCompositeEffectNesting:
    """Tests for nested composite effects."""

    def test_sequence_can_contain_sequence(self) -> None:
        """Sequence should allow nesting."""
        inner = Sequence(
            effect_id="inner",
            description="Inner",
            effects=[Pure(effect_id="p1", description="P1", value=1)],
        )
        outer = Sequence(
            effect_id="outer",
            description="Outer",
            effects=[inner],
        )
        assert len(outer.effects) == 1
        assert isinstance(outer.effects[0], Sequence)

    def test_parallel_can_contain_parallel(self) -> None:
        """Parallel should allow nesting."""
        inner = Parallel(
            effect_id="inner",
            description="Inner",
            effects=[Pure(effect_id="p1", description="P1", value=1)],
        )
        outer = Parallel(
            effect_id="outer",
            description="Outer",
            effects=[inner],
        )
        assert len(outer.effects) == 1
        assert isinstance(outer.effects[0], Parallel)

    def test_try_can_contain_sequence(self) -> None:
        """Try primary/fallback can be Sequence."""
        primary = Sequence(
            effect_id="seq_primary",
            description="Primary seq",
            effects=[Pure(effect_id="p", description="P", value=1)],
        )
        fallback = Sequence(
            effect_id="seq_fallback",
            description="Fallback seq",
            effects=[Pure(effect_id="f", description="F", value=2)],
        )
        try_effect = Try(
            effect_id="try",
            description="Try",
            primary=primary,
            fallback=fallback,
        )
        assert isinstance(try_effect.primary, Sequence)
        assert isinstance(try_effect.fallback, Sequence)

    def test_deeply_nested_composites(self) -> None:
        """Deeply nested composites should work."""
        # Sequence -> Parallel -> Try -> Pure
        pure = Pure(effect_id="pure", description="Pure", value=42)
        try_effect = Try(
            effect_id="try",
            description="Try",
            primary=pure,
            fallback=Pure(effect_id="fb", description="FB", value=0),
        )
        parallel = Parallel(
            effect_id="par",
            description="Parallel",
            effects=[try_effect],
        )
        sequence = Sequence(
            effect_id="seq",
            description="Sequence",
            effects=[parallel],
        )

        # Verify structure
        assert len(sequence.effects) == 1
        par = sequence.effects[0]
        assert isinstance(par, Parallel)
        assert len(par.effects) == 1
        tr = par.effects[0]
        assert isinstance(tr, Try)
        assert isinstance(tr.primary, Pure)


class TestEffectEquality:
    """Tests for effect equality and hashing."""

    def test_pure_effects_equal_with_same_values(self) -> None:
        """Pure effects with same values should be equal."""
        e1 = Pure(effect_id="e", description="d", value=42)
        e2 = Pure(effect_id="e", description="d", value=42)
        assert e1 == e2

    def test_pure_effects_not_equal_with_different_values(self) -> None:
        """Pure effects with different values should not be equal."""
        e1 = Pure(effect_id="e", description="d", value=42)
        e2 = Pure(effect_id="e", description="d", value=43)
        assert e1 != e2

    def test_pure_effects_not_equal_with_different_ids(self) -> None:
        """Pure effects with different ids should not be equal."""
        e1 = Pure(effect_id="e1", description="d", value=42)
        e2 = Pure(effect_id="e2", description="d", value=42)
        assert e1 != e2

    def test_different_effect_types_not_equal(self) -> None:
        """Different effect types should not be equal."""
        e1 = Pure(effect_id="e", description="d", value=None)
        e2 = RequireLinux(effect_id="e", description="d")
        assert e1 != e2

    def test_effects_are_hashable(self) -> None:
        """Effects should be hashable for use in sets."""
        e1 = Pure(effect_id="e1", description="d1", value=1)
        e2 = Pure(effect_id="e2", description="d2", value=2)
        e3 = RequireLinux(effect_id="e3", description="d3")

        effect_set = {e1, e2, e3}
        assert len(effect_set) == 3
        assert e1 in effect_set


class TestSequenceHelper:
    """Tests for sequence() builder function."""

    def test_sequence_creates_sequence_effect(self) -> None:
        """sequence() should create a Sequence effect."""
        from prodbox.cli.effects import Sequence, sequence

        effect = sequence(
            Pure(effect_id="p1", description="d1", value=1),
            Pure(effect_id="p2", description="d2", value=2),
        )

        assert isinstance(effect, Sequence)
        assert len(effect.effects) == 2

    def test_sequence_generates_effect_id(self) -> None:
        """sequence() should generate an effect_id based on count."""
        from prodbox.cli.effects import sequence

        effect = sequence(
            Pure(effect_id="p1", description="d1", value=1),
            Pure(effect_id="p2", description="d2", value=2),
            Pure(effect_id="p3", description="d3", value=3),
        )

        assert "3" in effect.effect_id


class TestParallelHelper:
    """Tests for parallel() builder function."""

    def test_parallel_creates_parallel_effect(self) -> None:
        """parallel() should create a Parallel effect."""
        from prodbox.cli.effects import Parallel, parallel

        effect = parallel(
            Pure(effect_id="p1", description="d1", value=1),
            Pure(effect_id="p2", description="d2", value=2),
        )

        assert isinstance(effect, Parallel)
        assert len(effect.effects) == 2

    def test_parallel_generates_effect_id(self) -> None:
        """parallel() should generate an effect_id based on count."""
        from prodbox.cli.effects import parallel

        effect = parallel(
            Pure(effect_id="p1", description="d1", value=1),
            Pure(effect_id="p2", description="d2", value=2),
        )

        assert "2" in effect.effect_id
