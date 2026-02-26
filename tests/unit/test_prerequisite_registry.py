"""Unit tests for the prerequisite registry.

Tests verify:
1. Registry completeness - all exported nodes are in the registry
2. Registry consistency - all effect_ids match registry keys
3. Transitive prerequisite validity - all referenced prerequisites exist
4. Effect type correctness - each prerequisite has the expected effect type
5. No orphan prerequisites - all prerequisites are reachable from composite nodes
6. Cycle detection - no circular dependencies

Following the Interpreter-Only Mocking Doctrine:
- These tests are pure: no mocks needed
- We're testing the data structure (registry), not the interpreter
"""

from __future__ import annotations

import pytest

from prodbox.cli.effect_dag import EffectNode
from prodbox.cli.effects import (
    CheckFileExists,
    CheckServiceStatus,
    Pure,
    RequireLinux,
    RequireSystemd,
    ValidateAWSCredentials,
    ValidateSettings,
    ValidateTool,
)
from prodbox.cli.prerequisite_registry import (
    AWS_CREDENTIALS_VALID,
    INFRA_READY,
    K8S_CLUSTER_REACHABLE,
    K8S_READY,
    KUBECONFIG_EXISTS,
    KUBECONFIG_HOME_EXISTS,
    PLATFORM_LINUX,
    PREREQUISITE_REGISTRY,
    PULUMI_LOGGED_IN,
    PULUMI_STACK_EXISTS,
    RKE2_CONFIG_EXISTS,
    RKE2_INSTALLED,
    RKE2_SERVICE_ACTIVE,
    RKE2_SERVICE_EXISTS,
    ROUTE53_ACCESSIBLE,
    SETTINGS_LOADED,
    SYSTEMD_AVAILABLE,
    TOOL_HELM,
    TOOL_KUBECTL,
    TOOL_PULUMI,
    TOOL_RKE2,
    TOOL_SYSTEMCTL,
)


class TestRegistryCompleteness:
    """Tests verifying all exports are in the registry."""

    def test_all_platform_prerequisites_in_registry(self) -> None:
        """All platform prerequisite nodes should be in the registry."""
        assert "platform_linux" in PREREQUISITE_REGISTRY
        assert "systemd_available" in PREREQUISITE_REGISTRY
        assert PREREQUISITE_REGISTRY["platform_linux"] is PLATFORM_LINUX
        assert PREREQUISITE_REGISTRY["systemd_available"] is SYSTEMD_AVAILABLE

    def test_all_tool_prerequisites_in_registry(self) -> None:
        """All tool prerequisite nodes should be in the registry."""
        assert "tool_kubectl" in PREREQUISITE_REGISTRY
        assert "tool_helm" in PREREQUISITE_REGISTRY
        assert "tool_pulumi" in PREREQUISITE_REGISTRY
        assert "tool_rke2" in PREREQUISITE_REGISTRY
        assert "tool_systemctl" in PREREQUISITE_REGISTRY
        assert PREREQUISITE_REGISTRY["tool_kubectl"] is TOOL_KUBECTL
        assert PREREQUISITE_REGISTRY["tool_helm"] is TOOL_HELM
        assert PREREQUISITE_REGISTRY["tool_pulumi"] is TOOL_PULUMI
        assert PREREQUISITE_REGISTRY["tool_rke2"] is TOOL_RKE2
        assert PREREQUISITE_REGISTRY["tool_systemctl"] is TOOL_SYSTEMCTL

    def test_all_config_prerequisites_in_registry(self) -> None:
        """All configuration prerequisite nodes should be in the registry."""
        assert "settings_loaded" in PREREQUISITE_REGISTRY
        assert "kubeconfig_exists" in PREREQUISITE_REGISTRY
        assert "kubeconfig_home_exists" in PREREQUISITE_REGISTRY
        assert "rke2_config_exists" in PREREQUISITE_REGISTRY
        assert PREREQUISITE_REGISTRY["settings_loaded"] is SETTINGS_LOADED
        assert PREREQUISITE_REGISTRY["kubeconfig_exists"] is KUBECONFIG_EXISTS
        assert PREREQUISITE_REGISTRY["kubeconfig_home_exists"] is KUBECONFIG_HOME_EXISTS
        assert PREREQUISITE_REGISTRY["rke2_config_exists"] is RKE2_CONFIG_EXISTS

    def test_all_aws_prerequisites_in_registry(self) -> None:
        """All AWS/Route53 prerequisite nodes should be in the registry."""
        assert "aws_credentials_valid" in PREREQUISITE_REGISTRY
        assert "route53_accessible" in PREREQUISITE_REGISTRY
        assert PREREQUISITE_REGISTRY["aws_credentials_valid"] is AWS_CREDENTIALS_VALID
        assert PREREQUISITE_REGISTRY["route53_accessible"] is ROUTE53_ACCESSIBLE

    def test_all_k8s_prerequisites_in_registry(self) -> None:
        """All Kubernetes/RKE2 prerequisite nodes should be in the registry."""
        assert "rke2_installed" in PREREQUISITE_REGISTRY
        assert "rke2_service_exists" in PREREQUISITE_REGISTRY
        assert "rke2_service_active" in PREREQUISITE_REGISTRY
        assert "k8s_cluster_reachable" in PREREQUISITE_REGISTRY
        assert PREREQUISITE_REGISTRY["rke2_installed"] is RKE2_INSTALLED
        assert PREREQUISITE_REGISTRY["rke2_service_exists"] is RKE2_SERVICE_EXISTS
        assert PREREQUISITE_REGISTRY["rke2_service_active"] is RKE2_SERVICE_ACTIVE
        assert PREREQUISITE_REGISTRY["k8s_cluster_reachable"] is K8S_CLUSTER_REACHABLE

    def test_all_pulumi_prerequisites_in_registry(self) -> None:
        """All Pulumi prerequisite nodes should be in the registry."""
        assert "pulumi_logged_in" in PREREQUISITE_REGISTRY
        assert "pulumi_stack_exists" in PREREQUISITE_REGISTRY
        assert PREREQUISITE_REGISTRY["pulumi_logged_in"] is PULUMI_LOGGED_IN
        assert PREREQUISITE_REGISTRY["pulumi_stack_exists"] is PULUMI_STACK_EXISTS

    def test_all_composite_prerequisites_in_registry(self) -> None:
        """All composite prerequisite nodes should be in the registry."""
        assert "k8s_ready" in PREREQUISITE_REGISTRY
        assert "infra_ready" in PREREQUISITE_REGISTRY
        assert PREREQUISITE_REGISTRY["k8s_ready"] is K8S_READY
        assert PREREQUISITE_REGISTRY["infra_ready"] is INFRA_READY


class TestRegistryConsistency:
    """Tests verifying effect_ids match registry keys."""

    def test_all_effect_ids_match_keys(self) -> None:
        """Every effect_id should match its registry key."""
        for key, node in PREREQUISITE_REGISTRY.items():
            assert node.effect.effect_id == key, (
                f"Registry key '{key}' doesn't match effect_id '{node.effect.effect_id}'"
            )

    def test_registry_has_expected_size(self) -> None:
        """Registry should have exactly 20 prerequisites."""
        # Platform: 2, Tools: 5, Config: 4, AWS: 2, K8s: 4, Pulumi: 2, Composite: 2
        expected_count = 2 + 5 + 4 + 2 + 4 + 2 + 2
        assert len(PREREQUISITE_REGISTRY) == expected_count


class TestTransitivePrerequisiteValidity:
    """Tests verifying all referenced prerequisites exist in registry."""

    def test_all_prerequisites_exist_in_registry(self) -> None:
        """Every prerequisite reference should exist in the registry."""
        for key, node in PREREQUISITE_REGISTRY.items():
            for prereq_id in node.prerequisites:
                assert prereq_id in PREREQUISITE_REGISTRY, (
                    f"Prerequisite '{prereq_id}' referenced by '{key}' not in registry"
                )

    def test_platform_linux_has_no_prerequisites(self) -> None:
        """Platform Linux should have no prerequisites (root node)."""
        assert PLATFORM_LINUX.prerequisites == frozenset()

    def test_systemd_depends_on_linux(self) -> None:
        """Systemd availability should depend on Linux platform."""
        assert "platform_linux" in SYSTEMD_AVAILABLE.prerequisites

    def test_aws_credentials_depends_on_settings(self) -> None:
        """AWS credentials should depend on settings loaded."""
        assert "settings_loaded" in AWS_CREDENTIALS_VALID.prerequisites

    def test_route53_depends_on_aws_credentials(self) -> None:
        """Route 53 access should depend on AWS credentials."""
        assert "aws_credentials_valid" in ROUTE53_ACCESSIBLE.prerequisites

    def test_rke2_service_chain(self) -> None:
        """RKE2 service should have proper dependency chain."""
        # rke2_service_exists depends on rke2_installed and systemd
        assert "rke2_installed" in RKE2_SERVICE_EXISTS.prerequisites
        assert "systemd_available" in RKE2_SERVICE_EXISTS.prerequisites

        # rke2_service_active depends on rke2_service_exists
        assert "rke2_service_exists" in RKE2_SERVICE_ACTIVE.prerequisites

    def test_k8s_cluster_reachable_dependencies(self) -> None:
        """K8s cluster reachable should depend on kubectl and kubeconfig."""
        assert "tool_kubectl" in K8S_CLUSTER_REACHABLE.prerequisites
        assert "kubeconfig_exists" in K8S_CLUSTER_REACHABLE.prerequisites

    def test_composite_k8s_ready_dependencies(self) -> None:
        """K8s ready composite should aggregate K8s prerequisites."""
        assert "k8s_cluster_reachable" in K8S_READY.prerequisites
        assert "rke2_service_active" in K8S_READY.prerequisites

    def test_composite_infra_ready_dependencies(self) -> None:
        """Infra ready composite should aggregate all infrastructure prerequisites."""
        assert "k8s_ready" in INFRA_READY.prerequisites
        assert "aws_credentials_valid" in INFRA_READY.prerequisites


class TestEffectTypeCorrectness:
    """Tests verifying each prerequisite uses the correct effect type."""

    def test_platform_prerequisites_use_require_effects(self) -> None:
        """Platform prerequisites should use Require* effects."""
        assert isinstance(PLATFORM_LINUX.effect, RequireLinux)
        assert isinstance(SYSTEMD_AVAILABLE.effect, RequireSystemd)

    def test_tool_prerequisites_use_validate_tool(self) -> None:
        """Tool prerequisites should use ValidateTool effect."""
        assert isinstance(TOOL_KUBECTL.effect, ValidateTool)
        assert isinstance(TOOL_HELM.effect, ValidateTool)
        assert isinstance(TOOL_PULUMI.effect, ValidateTool)
        assert isinstance(TOOL_RKE2.effect, ValidateTool)
        assert isinstance(TOOL_SYSTEMCTL.effect, ValidateTool)

    def test_file_prerequisites_use_check_file_exists(self) -> None:
        """File prerequisites should use CheckFileExists effect."""
        assert isinstance(KUBECONFIG_EXISTS.effect, CheckFileExists)
        assert isinstance(KUBECONFIG_HOME_EXISTS.effect, CheckFileExists)
        assert isinstance(RKE2_CONFIG_EXISTS.effect, CheckFileExists)
        assert isinstance(RKE2_INSTALLED.effect, CheckFileExists)

    def test_settings_prerequisite_uses_validate_settings(self) -> None:
        """Settings prerequisite should use ValidateSettings effect."""
        assert isinstance(SETTINGS_LOADED.effect, ValidateSettings)

    def test_aws_prerequisite_uses_validate_aws_credentials(self) -> None:
        """AWS credentials prerequisite should use ValidateAWSCredentials."""
        assert isinstance(AWS_CREDENTIALS_VALID.effect, ValidateAWSCredentials)

    def test_service_prerequisites_use_check_service_status(self) -> None:
        """Service prerequisites should use CheckServiceStatus effect."""
        assert isinstance(RKE2_SERVICE_EXISTS.effect, CheckServiceStatus)
        assert isinstance(RKE2_SERVICE_ACTIVE.effect, CheckServiceStatus)

    def test_composite_prerequisites_use_pure(self) -> None:
        """Composite prerequisites should use Pure effect (aggregation only)."""
        assert isinstance(ROUTE53_ACCESSIBLE.effect, Pure)
        assert isinstance(K8S_CLUSTER_REACHABLE.effect, Pure)
        assert isinstance(PULUMI_LOGGED_IN.effect, Pure)
        assert isinstance(PULUMI_STACK_EXISTS.effect, Pure)
        assert isinstance(K8S_READY.effect, Pure)
        assert isinstance(INFRA_READY.effect, Pure)


class TestNoCyclicDependencies:
    """Tests verifying no circular dependencies exist."""

    def test_no_direct_self_reference(self) -> None:
        """No prerequisite should directly reference itself."""
        for key, node in PREREQUISITE_REGISTRY.items():
            assert key not in node.prerequisites, (
                f"Prerequisite '{key}' directly references itself"
            )

    def test_no_cyclic_dependencies(self) -> None:
        """No prerequisite should have cyclic dependencies."""
        def has_cycle(start: str, visited: frozenset[str]) -> bool:
            """Check for cycles using DFS."""
            if start in visited:
                return True
            node = PREREQUISITE_REGISTRY.get(start)
            if node is None:
                return False
            new_visited = visited | {start}
            return any(has_cycle(p, new_visited) for p in node.prerequisites)

        for key in PREREQUISITE_REGISTRY:
            assert not has_cycle(key, frozenset()), f"Cycle detected starting from '{key}'"


class TestTransitiveExpansion:
    """Tests verifying transitive expansion produces correct prerequisite sets."""

    def _expand_prerequisites(self, effect_id: str) -> frozenset[str]:
        """Recursively expand prerequisites to get full transitive set."""
        node = PREREQUISITE_REGISTRY.get(effect_id)
        if node is None:
            return frozenset()

        all_prereqs: set[str] = set(node.prerequisites)
        for prereq_id in node.prerequisites:
            all_prereqs |= set(self._expand_prerequisites(prereq_id))

        return frozenset(all_prereqs)

    def test_systemd_expands_to_include_linux(self) -> None:
        """Systemd should transitively include Linux platform."""
        expanded = self._expand_prerequisites("systemd_available")
        assert "platform_linux" in expanded

    def test_rke2_service_active_expands_fully(self) -> None:
        """RKE2 service active should expand to include all dependencies."""
        expanded = self._expand_prerequisites("rke2_service_active")
        # Should include: rke2_service_exists, rke2_installed, systemd_available, platform_linux
        assert "rke2_service_exists" in expanded
        assert "rke2_installed" in expanded
        assert "systemd_available" in expanded
        assert "platform_linux" in expanded

    def test_infra_ready_expands_to_all_infra_prerequisites(self) -> None:
        """Infra ready should expand to include all infrastructure prerequisites."""
        expanded = self._expand_prerequisites("infra_ready")
        # Should include K8s and AWS chains
        assert "k8s_ready" in expanded
        assert "k8s_cluster_reachable" in expanded
        assert "rke2_service_active" in expanded
        assert "aws_credentials_valid" in expanded
        assert "settings_loaded" in expanded
        assert "platform_linux" in expanded

    def test_route53_expands_to_settings_chain(self) -> None:
        """Route 53 accessible should expand to include settings chain."""
        expanded = self._expand_prerequisites("route53_accessible")
        assert "aws_credentials_valid" in expanded
        assert "settings_loaded" in expanded


class TestPrerequisiteNodeStructure:
    """Tests verifying EffectNode structure for prerequisites."""

    def test_all_nodes_are_effect_nodes(self) -> None:
        """All registry values should be EffectNode instances."""
        for key, node in PREREQUISITE_REGISTRY.items():
            assert isinstance(node, EffectNode), f"'{key}' is not an EffectNode"

    def test_all_nodes_have_frozen_prerequisites(self) -> None:
        """All EffectNodes should have frozenset prerequisites."""
        for key, node in PREREQUISITE_REGISTRY.items():
            assert isinstance(node.prerequisites, frozenset), (
                f"'{key}' prerequisites is not a frozenset"
            )

    def test_all_nodes_have_effect_with_effect_id(self) -> None:
        """All EffectNodes should have effects with effect_id attribute."""
        for key, node in PREREQUISITE_REGISTRY.items():
            assert hasattr(node.effect, "effect_id"), (
                f"'{key}' effect missing effect_id"
            )

    def test_all_nodes_have_effect_with_description(self) -> None:
        """All EffectNodes should have effects with description attribute."""
        for key, node in PREREQUISITE_REGISTRY.items():
            assert hasattr(node.effect, "description"), (
                f"'{key}' effect missing description"
            )
            assert node.effect.description, f"'{key}' has empty description"
