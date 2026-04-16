"""Unit tests for Phase 7 command constructors and DAG builders."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from prodbox.cli.command_adt import (
    AWSCheckQuotasCommand,
    AWSPolicyCommand,
    AWSRequestQuotasCommand,
    AWSSetupCommand,
    AWSTeardownCommand,
    ConfigSetupCommand,
    aws_check_quotas_command,
    aws_policy_command,
    aws_request_quotas_command,
    aws_setup_command,
    aws_teardown_command,
    config_setup_command,
    renders_execution_summary,
    requires_linux,
    requires_settings,
)
from prodbox.cli.dag_builders import command_to_dag
from prodbox.cli.effects import Custom, PrintTable, WriteStdout
from prodbox.cli.types import Failure, Success


def _config_setup_result() -> ConfigSetupCommand:
    """Return one valid ConfigSetupCommand for builder and utility tests."""
    match config_setup_command(
        admin_access_key_id="ADMINKEY",
        admin_secret_access_key="admin-secret",
        admin_session_token=None,
        admin_region="us-east-1",
        route53_zone_id="Z1234567890ABC",
        demo_fqdn="demo.example.com",
        demo_ttl=60,
        vscode_fqdn="vscode.example.com",
        acme_email="ops@example.com",
        acme_server="https://acme-v02.api.letsencrypt.org/directory",
        acme_eab_key_id=None,
        acme_eab_hmac_key=None,
        prodbox_dev_mode=True,
        bootstrap_public_ip_override=None,
        pulumi_enable_dns_bootstrap=True,
        manual_pv_host_root=Path(".data"),
        policy_tier="full",
    ):
        case Success(value=command):
            return command
        case Failure(error):
            raise AssertionError(error)


class TestPhase7CommandConstructors:
    """Tests for Phase 7 smart constructors."""

    def test_aws_policy_command_accepts_supported_tiers(self) -> None:
        """IAM policy constructor should accept both supported tiers."""
        match aws_policy_command(tier="core"):
            case Success(value=command):
                assert command == AWSPolicyCommand(tier="core")
            case Failure(error):
                pytest.fail(error)

        match aws_policy_command(tier="full"):
            case Success(value=command):
                assert command == AWSPolicyCommand(tier="full")
            case Failure(error):
                pytest.fail(error)

    def test_aws_policy_command_rejects_unknown_tier(self) -> None:
        """IAM policy constructor should reject unsupported tiers."""
        match aws_policy_command(tier="admin"):
            case Success(_):
                pytest.fail("Expected Failure")
            case Failure(error):
                assert "core" in error
                assert "full" in error

    def test_config_setup_command_validates_fqdn_and_eab_pair(self) -> None:
        """Config setup constructor should reject invalid DNS and partial EAB config."""
        match config_setup_command(
            admin_access_key_id="ADMINKEY",
            admin_secret_access_key="admin-secret",
            admin_session_token=None,
            admin_region="us-east-1",
            route53_zone_id="Z1234567890ABC",
            demo_fqdn="not a fqdn",
            demo_ttl=60,
            vscode_fqdn=None,
            acme_email="ops@example.com",
            acme_server="https://acme-v02.api.letsencrypt.org/directory",
            acme_eab_key_id="kid",
            acme_eab_hmac_key=None,
            prodbox_dev_mode=True,
            bootstrap_public_ip_override=None,
            pulumi_enable_dns_bootstrap=True,
            manual_pv_host_root=Path(".data"),
            policy_tier="full",
        ):
            case Success(_):
                pytest.fail("Expected Failure")
            case Failure(error):
                assert "demo_fqdn" in error or "acme_eab_key_id" in error

    def test_aws_setup_command_requires_admin_credentials(self) -> None:
        """AWS setup constructor should reject blank admin credentials."""
        match aws_setup_command(
            admin_access_key_id="",
            admin_secret_access_key="secret",
            admin_session_token=None,
            admin_region="us-east-1",
            tier="full",
        ):
            case Success(_):
                pytest.fail("Expected Failure")
            case Failure(error):
                assert "access key" in error

    def test_aws_teardown_and_quota_commands_build_successfully(self) -> None:
        """Phase 7 non-policy AWS commands should validate and construct."""
        for constructor in (
            lambda: aws_teardown_command(
                admin_access_key_id="ADMINKEY",
                admin_secret_access_key="admin-secret",
                admin_session_token=None,
                admin_region="us-east-1",
            ),
            lambda: aws_check_quotas_command(
                admin_access_key_id="ADMINKEY",
                admin_secret_access_key="admin-secret",
                admin_session_token=None,
                admin_region="us-east-1",
            ),
            lambda: aws_request_quotas_command(
                admin_access_key_id="ADMINKEY",
                admin_secret_access_key="admin-secret",
                admin_session_token=None,
                admin_region="us-east-1",
                tier="core",
            ),
        ):
            match constructor():
                case Success(value=command):
                    assert isinstance(
                        command,
                        AWSTeardownCommand | AWSCheckQuotasCommand | AWSRequestQuotasCommand,
                    )
                case Failure(error):
                    pytest.fail(error)


class TestPhase7Utilities:
    """Tests for utility behavior added for Phase 7 commands."""

    def test_phase7_commands_do_not_require_settings_or_linux(self) -> None:
        """Phase 7 onboarding and AWS commands should be cross-platform and settings-free."""
        commands = (
            AWSPolicyCommand(),
            AWSSetupCommand(
                admin_access_key_id="ADMINKEY",
                admin_secret_access_key="admin-secret",
                admin_session_token=None,
                admin_region="us-east-1",
                tier="full",
            ),
            AWSTeardownCommand(
                admin_access_key_id="ADMINKEY",
                admin_secret_access_key="admin-secret",
                admin_session_token=None,
                admin_region="us-east-1",
            ),
            AWSCheckQuotasCommand(
                admin_access_key_id="ADMINKEY",
                admin_secret_access_key="admin-secret",
                admin_session_token=None,
                admin_region="us-east-1",
            ),
            AWSRequestQuotasCommand(
                admin_access_key_id="ADMINKEY",
                admin_secret_access_key="admin-secret",
                admin_session_token=None,
                admin_region="us-east-1",
                tier="full",
            ),
            _config_setup_result(),
        )
        for command in commands:
            assert requires_linux(command) is False
            assert requires_settings(command) is False

    def test_aws_policy_suppresses_success_summary(self) -> None:
        """Pure JSON policy output should suppress the success summary renderer."""
        assert renders_execution_summary(AWSPolicyCommand()) is False
        assert (
            renders_execution_summary(
                AWSSetupCommand(
                    admin_access_key_id="ADMINKEY",
                    admin_secret_access_key="admin-secret",
                    admin_session_token=None,
                    admin_region="us-east-1",
                    tier="full",
                )
            )
            is True
        )


class TestPhase7DAGBuilders:
    """Tests for Phase 7 command DAG builders."""

    def test_aws_policy_dag_renders_parseable_json(self) -> None:
        """`aws policy` DAG should emit pure JSON text from the root node."""
        match command_to_dag(AWSPolicyCommand(tier="full")):
            case Success(value=dag):
                root = dag.get_node("aws_policy")
                assert root is not None
                assert isinstance(root.effect, WriteStdout)
                payload = json.loads(root.effect.text)
                assert payload["Version"] == "2012-10-17"
                statements = payload["Statement"]
                assert isinstance(statements, list)
                assert any(
                    statement["Sid"] == "Ec2HaTestStackLifecycle" for statement in statements
                )
                assert any(statement["Sid"] == "IamEksRoleLifecycle" for statement in statements)
                assert any(statement["Sid"] == "EksTestStackLifecycle" for statement in statements)
            case Failure(error):
                pytest.fail(error)

    def test_config_setup_dag_requires_aws_and_dhall_tools(self) -> None:
        """Config setup DAG should depend on the AWS CLI and Dhall compiler."""
        match command_to_dag(_config_setup_result()):
            case Success(value=dag):
                apply_node = dag.get_node("config_setup_apply")
                render_node = dag.get_node("config_setup")
                assert apply_node is not None
                assert render_node is not None
                assert isinstance(apply_node.effect, Custom)
                assert apply_node.prerequisites == frozenset({"tool_aws", "tool_dhall_to_json"})
                assert render_node.prerequisites == frozenset({"config_setup_apply"})
            case Failure(error):
                pytest.fail(error)

    def test_aws_setup_teardown_and_quota_dags_have_expected_shapes(self) -> None:
        """Phase 7 AWS DAGs should expose their apply/query roots and rendering nodes."""
        commands_and_roots = (
            (
                AWSSetupCommand(
                    admin_access_key_id="ADMINKEY",
                    admin_secret_access_key="admin-secret",
                    admin_session_token=None,
                    admin_region="us-east-1",
                    tier="full",
                ),
                "aws_setup_apply",
                "aws_setup",
                frozenset({"tool_aws", "tool_dhall_to_json"}),
                WriteStdout,
            ),
            (
                AWSTeardownCommand(
                    admin_access_key_id="ADMINKEY",
                    admin_secret_access_key="admin-secret",
                    admin_session_token=None,
                    admin_region="us-east-1",
                ),
                "aws_teardown_apply",
                "aws_teardown",
                frozenset({"tool_aws", "tool_dhall_to_json"}),
                WriteStdout,
            ),
            (
                AWSCheckQuotasCommand(
                    admin_access_key_id="ADMINKEY",
                    admin_secret_access_key="admin-secret",
                    admin_session_token=None,
                    admin_region="us-east-1",
                ),
                "aws_check_quotas_query",
                "aws_check_quotas",
                frozenset({"tool_aws"}),
                PrintTable,
            ),
            (
                AWSRequestQuotasCommand(
                    admin_access_key_id="ADMINKEY",
                    admin_secret_access_key="admin-secret",
                    admin_session_token=None,
                    admin_region="us-east-1",
                    tier="core",
                ),
                "aws_request_quotas_query",
                "aws_request_quotas",
                frozenset({"tool_aws"}),
                PrintTable,
            ),
        )

        for command, apply_id, render_id, prerequisites, render_type in commands_and_roots:
            match command_to_dag(command):
                case Success(value=dag):
                    apply_node = dag.get_node(apply_id)
                    render_node = dag.get_node(render_id)
                    assert apply_node is not None
                    assert render_node is not None
                    assert isinstance(apply_node.effect, Custom)
                    assert apply_node.prerequisites == prerequisites
                    assert isinstance(render_node.effect, render_type)
                    assert render_node.prerequisites == frozenset({apply_id})
                case Failure(error):
                    pytest.fail(error)
