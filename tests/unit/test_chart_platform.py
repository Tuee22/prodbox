"""Unit tests for the chart platform pure plan builders.

These are pure function tests – no mocks, no I/O, no side effects.
"""

from __future__ import annotations

import dataclasses
import json
import os
import subprocess
from pathlib import Path

import pytest

import prodbox.lib.chart_platform as chart_platform_module
from prodbox.cli.types import Failure, Success
from prodbox.lib.chart_platform import (
    CHART_DATA_ROOT,
    ChartDeploymentPlan,
    ChartReleasePlan,
    ChartStorageBinding,
    ChartStorageSpec,
    _storage_binding,
    build_chart_delete_plan,
    build_chart_deployment_plan,
    supported_chart_names,
)

# =============================================================================
# _storage_binding – deterministic PV name and host path
# =============================================================================


class TestStorageBinding:
    def test_deterministic_pv_name(self) -> None:
        spec = ChartStorageSpec(
            statefulset_name="keycloak-postgres",
            persistent_volume_claim_name="keycloak-postgres-data-0",
            storage_size="20Gi",
            ordinal=0,
        )
        binding = _storage_binding("vscode", "keycloak-postgres", spec)
        assert (
            binding.persistent_volume_name
            == "prodbox-chart-vscode-keycloak-postgres-keycloak-postgres-0-data"
        )

    def test_deterministic_host_path(self) -> None:
        spec = ChartStorageSpec(
            statefulset_name="keycloak-postgres",
            persistent_volume_claim_name="keycloak-postgres-data-0",
            storage_size="20Gi",
            ordinal=0,
        )
        binding = _storage_binding("vscode", "keycloak-postgres", spec)
        expected = (
            CHART_DATA_ROOT / "vscode" / "keycloak-postgres" / "keycloak-postgres" / "0" / "data"
        )
        assert binding.host_path == expected

    def test_pvc_name_preserved(self) -> None:
        spec = ChartStorageSpec(
            statefulset_name="vscode",
            persistent_volume_claim_name="vscode-data-0",
            storage_size="50Gi",
            ordinal=0,
        )
        binding = _storage_binding("vscode", "vscode", spec)
        assert binding.persistent_volume_claim_name == "vscode-data-0"
        assert binding.storage_size == "50Gi"

    def test_ordinal_in_pv_name(self) -> None:
        spec = ChartStorageSpec(
            statefulset_name="mydb",
            persistent_volume_claim_name="mydb-data-1",
            storage_size="10Gi",
            ordinal=1,
        )
        binding = _storage_binding("myns", "myrelease", spec)
        assert binding.persistent_volume_name == "prodbox-chart-myns-myrelease-mydb-1-data"

    def test_five_segment_host_path(self) -> None:
        spec = ChartStorageSpec(
            statefulset_name="mydb",
            persistent_volume_claim_name="mydb-data-0",
            storage_size="10Gi",
            ordinal=0,
            claim_suffix="data",
        )
        binding = _storage_binding("myns", "myrelease", spec)
        expected = CHART_DATA_ROOT / "myns" / "myrelease" / "mydb" / "0" / "data"
        assert binding.host_path == expected

    def test_release_name_and_claim_suffix_on_binding(self) -> None:
        spec = ChartStorageSpec(
            statefulset_name="pg",
            persistent_volume_claim_name="pg-data-0",
            storage_size="20Gi",
            claim_suffix="data",
        )
        binding = _storage_binding("ns", "rel", spec)
        assert binding.release_name == "rel"
        assert binding.claim_suffix == "data"

    def test_storage_binding_is_frozen(self) -> None:
        spec = ChartStorageSpec(
            statefulset_name="keycloak-postgres",
            persistent_volume_claim_name="keycloak-postgres-data-0",
            storage_size="20Gi",
        )
        binding = _storage_binding("vscode", "keycloak-postgres", spec)
        assert isinstance(binding, ChartStorageBinding)
        with pytest.raises(dataclasses.FrozenInstanceError):
            binding.storage_size = "100Gi"  # type: ignore[misc]


# =============================================================================
# supported_chart_names
# =============================================================================


class TestSupportedChartNames:
    def test_returns_tuple(self) -> None:
        names = supported_chart_names()
        assert isinstance(names, tuple)

    def test_contains_expected_charts(self) -> None:
        names = supported_chart_names()
        assert "keycloak-postgres" in names
        assert "keycloak" in names
        assert "vscode" in names


# =============================================================================
# build_chart_delete_plan – pure, no settings needed
# =============================================================================


class TestBuildChartDeletePlan:
    def test_vscode_delete_plan_succeeds(self) -> None:
        result = build_chart_delete_plan("vscode")
        assert isinstance(result, Success)

    def test_invalid_chart_returns_failure(self) -> None:
        result = build_chart_delete_plan("nonexistent-chart")
        assert isinstance(result, Failure)

    def test_delete_plan_reverses_dependency_order(self) -> None:
        result = build_chart_delete_plan("vscode")
        assert isinstance(result, Success)
        plan = result.value
        release_names = tuple(r.release_name for r in plan.releases)
        # vscode depends on keycloak depends on keycloak-postgres
        # delete order must be reverse: vscode, keycloak, keycloak-postgres
        assert release_names[0] == "vscode"
        assert release_names[1] == "keycloak"
        assert release_names[2] == "keycloak-postgres"

    def test_delete_plan_namespace_equals_root_chart(self) -> None:
        result = build_chart_delete_plan("vscode")
        assert isinstance(result, Success)
        plan = result.value
        assert plan.namespace == "vscode"
        assert plan.root_chart == "vscode"
        for release in plan.releases:
            assert release.namespace == "vscode"

    def test_delete_plan_preserves_storage_bindings(self) -> None:
        result = build_chart_delete_plan("vscode")
        assert isinstance(result, Success)
        plan = result.value
        # Storage bindings should exist for keycloak-postgres and vscode
        storage_releases = [r for r in plan.releases if r.storage_bindings]
        storage_names = {r.release_name for r in storage_releases}
        assert "keycloak-postgres" in storage_names
        assert "vscode" in storage_names

    def test_delete_plan_no_filesystem_ops(self) -> None:
        # build_chart_delete_plan is pure – calling it must not create any files
        import os

        cwd_before = set(os.listdir("."))
        build_chart_delete_plan("vscode")
        cwd_after = set(os.listdir("."))
        assert cwd_before == cwd_after


# =============================================================================
# build_chart_deployment_plan – requires settings
# =============================================================================

_MINIMAL_VSCODE_SETTINGS: dict[str, str | bool] = {
    "vscode_fqdn": "vscode.example.com",
    "prodbox_dev_mode": True,
}

_TEST_CHART_SECRETS: dict[str, str] = {
    "keycloak_admin_password": "adminpass",
    "keycloak_postgres_password": "pgpass",
    "keycloak_nginx_client_secret": "nginxsecret",
}

_MINIMAL_GATEWAY_SETTINGS: dict[str, str | bool] = {
    "vscode_fqdn": "vscode.example.com",
    "aws_access_key_id": "test-access-key",
    "aws_secret_access_key": "test-secret-key",
    "aws_region": "us-east-1",
    "route53_zone_id": "Z123456789",
    "prodbox_dev_mode": True,
}

_TEST_GATEWAY_EVENT_KEYS: dict[str, str] = {
    "node-a": "a" * 64,
    "node-b": "b" * 64,
    "node-c": "c" * 64,
}


class TestBuildChartDeploymentPlan:
    def test_vscode_deployment_plan_succeeds(self) -> None:
        result = build_chart_deployment_plan(
            "vscode", _MINIMAL_VSCODE_SETTINGS, _TEST_CHART_SECRETS
        )
        assert isinstance(result, Success)

    def test_invalid_chart_returns_failure(self) -> None:
        result = build_chart_deployment_plan(
            "nonexistent", _MINIMAL_VSCODE_SETTINGS, _TEST_CHART_SECRETS
        )
        assert isinstance(result, Failure)

    def test_deployment_plan_correct_release_order(self) -> None:
        result = build_chart_deployment_plan(
            "vscode", _MINIMAL_VSCODE_SETTINGS, _TEST_CHART_SECRETS
        )
        assert isinstance(result, Success)
        plan = result.value
        release_names = tuple(r.release_name for r in plan.releases)
        # deploy order: keycloak-postgres, keycloak, vscode
        assert release_names == ("keycloak-postgres", "keycloak", "vscode")

    def test_all_releases_in_root_namespace(self) -> None:
        result = build_chart_deployment_plan(
            "vscode", _MINIMAL_VSCODE_SETTINGS, _TEST_CHART_SECRETS
        )
        assert isinstance(result, Success)
        plan = result.value
        assert plan.namespace == "vscode"
        for release in plan.releases:
            assert release.namespace == "vscode"

    def test_singleton_violation_not_detected_at_plan_time(self) -> None:
        # The singleton check is at deploy_chart_plan runtime (helm list), not plan time
        result = build_chart_deployment_plan(
            "vscode", _MINIMAL_VSCODE_SETTINGS, _TEST_CHART_SECRETS
        )
        assert isinstance(result, Success)
        plan = result.value
        # No duplicate release names in the plan
        release_names = [r.release_name for r in plan.releases]
        assert len(release_names) == len(set(release_names))

    def test_public_fqdn_propagated(self) -> None:
        result = build_chart_deployment_plan(
            "vscode", _MINIMAL_VSCODE_SETTINGS, _TEST_CHART_SECRETS
        )
        assert isinstance(result, Success)
        plan = result.value
        assert plan.public_fqdn == "vscode.example.com"

    def test_vscode_stack_replica_counts_match_supported_chart_roles(self) -> None:
        result = build_chart_deployment_plan(
            "vscode", _MINIMAL_VSCODE_SETTINGS, _TEST_CHART_SECRETS
        )
        assert isinstance(result, Success)
        plan = result.value
        release_values = {
            release.release_name: json.loads(release.values_json) for release in plan.releases
        }
        assert release_values["keycloak-postgres"]["replicaCount"] == 1
        assert release_values["keycloak"]["replicaCount"] == 2
        assert release_values["vscode"]["replicaCount"] == 1

    def test_missing_required_setting_returns_failure(self) -> None:
        settings_without_fqdn = {
            k: v for k, v in _MINIMAL_VSCODE_SETTINGS.items() if k != "vscode_fqdn"
        }
        result = build_chart_deployment_plan("vscode", settings_without_fqdn, _TEST_CHART_SECRETS)
        assert isinstance(result, Failure)

    def test_storage_bindings_deterministic(self) -> None:
        result1 = build_chart_deployment_plan(
            "vscode", _MINIMAL_VSCODE_SETTINGS, _TEST_CHART_SECRETS
        )
        result2 = build_chart_deployment_plan(
            "vscode", _MINIMAL_VSCODE_SETTINGS, _TEST_CHART_SECRETS
        )
        assert isinstance(result1, Success)
        assert isinstance(result2, Success)
        plan1_releases = {r.release_name: r for r in result1.value.releases}
        plan2_releases = {r.release_name: r for r in result2.value.releases}
        for name, release1 in plan1_releases.items():
            release2 = plan2_releases[name]
            assert release1.storage_bindings == release2.storage_bindings

    def test_plan_is_frozen_dataclass(self) -> None:
        result = build_chart_deployment_plan(
            "vscode", _MINIMAL_VSCODE_SETTINGS, _TEST_CHART_SECRETS
        )
        assert isinstance(result, Success)
        plan = result.value
        assert isinstance(plan, ChartDeploymentPlan)
        with pytest.raises(dataclasses.FrozenInstanceError):
            plan.namespace = "other"  # type: ignore[misc]

    def test_gateway_plan_uses_machine_identity_tagged_image(self) -> None:
        result = build_chart_deployment_plan(
            "gateway",
            _MINIMAL_GATEWAY_SETTINGS,
            gateway_event_keys=_TEST_GATEWAY_EVENT_KEYS,
        )
        assert isinstance(result, Success)
        plan = result.value
        assert len(plan.releases) == 1
        values = json.loads(plan.releases[0].values_json)
        image = values["image"]
        assert image["repository"] == "127.0.0.1:30080/prodbox/prodbox-gateway"
        assert image["tag"] != "latest"
        assert image["tag"].startswith("prodbox-")
        assert image["pullPolicy"] == "IfNotPresent"


# =============================================================================
# Retained state repair coverage
# =============================================================================


class TestRetainedStateRepair:
    def test_resolve_chart_secrets_ensures_namespace_dir(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        target_root = tmp_path / "chart-data"
        ensured_paths: list[Path] = []

        def fake_ensure(path: Path) -> None:
            ensured_paths.append(path)
            path.mkdir(parents=True, exist_ok=True)

        monkeypatch.setattr(chart_platform_module, "CHART_DATA_ROOT", target_root)
        monkeypatch.setattr(chart_platform_module, "_ensure_chart_state_dir", fake_ensure)

        secrets = chart_platform_module.resolve_chart_secrets("vscode")

        assert ensured_paths == [target_root / "vscode"]
        assert sorted(secrets.keys()) == sorted(
            [
                "keycloak_admin_password",
                "keycloak_nginx_client_secret",
                "keycloak_postgres_password",
            ]
        )
        assert (target_root / "vscode" / ".secrets.json").exists()

    def test_resolve_gateway_event_keys_ensures_namespace_dir(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        target_root = tmp_path / "chart-data"
        ensured_paths: list[Path] = []

        def fake_ensure(path: Path) -> None:
            ensured_paths.append(path)
            path.mkdir(parents=True, exist_ok=True)

        monkeypatch.setattr(chart_platform_module, "CHART_DATA_ROOT", target_root)
        monkeypatch.setattr(chart_platform_module, "_ensure_chart_state_dir", fake_ensure)

        keys = chart_platform_module.resolve_gateway_event_keys("gateway")

        assert ensured_paths == [target_root / "gateway"]
        assert sorted(keys.keys()) == ["node-a", "node-b", "node-c"]
        assert (target_root / "gateway" / ".gateway-event-keys.json").exists()

    def test_ensure_chart_state_dir_repairs_unwritable_directory(
        self,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        target_dir = tmp_path / "gateway"
        target_dir.mkdir(parents=True, exist_ok=True)
        repair_commands: list[tuple[str, ...]] = []
        real_access = os.access

        def fake_access(path_like: object, mode: int) -> bool:
            match path_like:
                case Path() as value:
                    if value == target_dir:
                        return False
                    return real_access(value, mode)
                case str() as value:
                    if Path(value) == target_dir:
                        return False
                    return real_access(value, mode)
                case _:
                    return True

        def fake_run(
            command: tuple[str, ...],
            *,
            capture_output: bool,
            text: bool,
            check: bool,
        ) -> subprocess.CompletedProcess[str]:
            assert capture_output is True
            assert text is True
            assert check is False
            repair_commands.append(command)
            return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

        monkeypatch.setattr(chart_platform_module.os, "access", fake_access)
        monkeypatch.setattr(chart_platform_module.subprocess, "run", fake_run)

        chart_platform_module._ensure_chart_state_dir(target_dir)

        expected_owner = f"{os.getuid()}:{os.getgid()}"
        assert repair_commands == [
            ("sudo", "mkdir", "-p", str(target_dir)),
            ("sudo", "chown", "-R", expected_owner, str(target_dir)),
            ("sudo", "chmod", "0770", str(target_dir)),
        ]

    @pytest.mark.asyncio
    async def test_ensure_chart_storage_repairs_each_binding_host_path(
        self,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        binding = _storage_binding(
            "vscode",
            "vscode",
            ChartStorageSpec(
                statefulset_name="vscode",
                persistent_volume_claim_name="vscode-data-0",
                storage_size="50Gi",
            ),
        )
        plan = ChartDeploymentPlan(
            root_chart="vscode",
            namespace="vscode",
            releases=(
                ChartReleasePlan(
                    chart_name="vscode",
                    release_name="vscode",
                    namespace="vscode",
                    chart_dir=Path("charts/vscode"),
                    values_json="{}",
                    storage_bindings=(binding,),
                ),
            ),
            public_fqdn="vscode.example.com",
        )
        ensured_paths: list[Path] = []
        applied_manifests: list[dict[str, object]] = []

        def fake_ensure(path: Path) -> None:
            ensured_paths.append(path)

        async def fake_single_node_hostname() -> str:
            return "bathurst"

        async def fake_persistent_volume_phase(_name: str) -> str | None:
            return None

        async def fake_apply_manifest(manifest: dict[str, object]) -> None:
            applied_manifests.append(manifest)

        monkeypatch.setattr(chart_platform_module, "_ensure_chart_state_dir", fake_ensure)
        monkeypatch.setattr(
            chart_platform_module, "_single_node_hostname", fake_single_node_hostname
        )
        monkeypatch.setattr(
            chart_platform_module,
            "_persistent_volume_phase",
            fake_persistent_volume_phase,
        )
        monkeypatch.setattr(chart_platform_module, "_apply_manifest", fake_apply_manifest)

        await chart_platform_module._ensure_chart_storage(plan)

        assert ensured_paths == [binding.host_path]
        assert len(applied_manifests) == 1


# =============================================================================
# Additional prerequisite ordering and namespace validation coverage
# =============================================================================


class TestPrerequisiteOrdering:
    def test_vscode_plan_includes_all_three_releases(self) -> None:
        result = build_chart_deployment_plan(
            "vscode", _MINIMAL_VSCODE_SETTINGS, _TEST_CHART_SECRETS
        )
        assert isinstance(result, Success)
        release_names = {r.release_name for r in result.value.releases}
        assert release_names == {"keycloak-postgres", "keycloak", "vscode"}

    def test_keycloak_postgres_deployed_before_keycloak(self) -> None:
        result = build_chart_deployment_plan(
            "vscode", _MINIMAL_VSCODE_SETTINGS, _TEST_CHART_SECRETS
        )
        assert isinstance(result, Success)
        names = [r.release_name for r in result.value.releases]
        pg_idx = names.index("keycloak-postgres")
        kc_idx = names.index("keycloak")
        vs_idx = names.index("vscode")
        assert pg_idx < kc_idx < vs_idx


class TestSameNamespaceOnly:
    def test_all_releases_share_root_chart_namespace(self) -> None:
        result = build_chart_deployment_plan(
            "vscode", _MINIMAL_VSCODE_SETTINGS, _TEST_CHART_SECRETS
        )
        assert isinstance(result, Success)
        plan = result.value
        for release in plan.releases:
            assert release.namespace == plan.root_chart
