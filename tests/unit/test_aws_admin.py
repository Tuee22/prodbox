"""Unit tests for Phase 7 AWS onboarding and IAM helpers."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

from prodbox.cli.command_adt import (
    AWSCheckQuotasCommand,
    AWSRequestQuotasCommand,
    AWSSetupCommand,
    AWSTeardownCommand,
    ConfigSetupCommand,
)
from prodbox.cli.types import Failure, Success
from prodbox.lib import aws_admin
from prodbox.lib.aws_admin import (
    AdminAWSCredentials,
    ConfigSetupResult,
    HostedZoneChoice,
    IAMSetupResult,
    IAMTeardownResult,
    QuotaStatus,
    RegionChoice,
    build_iam_policy_document,
    build_iam_policy_json,
    ensure_operational_aws_credentials_from_admin_harness,
    interactive_aws_check_quotas_command,
    interactive_aws_request_quotas_command,
    interactive_aws_setup_command,
    interactive_aws_teardown_command,
    interactive_config_setup_command,
    operational_aws_credentials_are_valid,
    operational_aws_policy_is_current,
    quota_status_rows,
    render_aws_setup_result,
    render_aws_teardown_result,
    render_config_setup_result,
    restore_operational_aws_identity_from_admin_harness,
    run_aws_check_quotas,
    run_aws_request_quotas,
    run_aws_setup,
    run_aws_teardown,
    run_config_setup,
)


def _admin_credentials(*, region: str = "us-east-1") -> AdminAWSCredentials:
    """Return deterministic elevated AWS credentials for tests."""
    return AdminAWSCredentials(
        access_key_id="ADMINKEY",
        secret_access_key="admin-secret",
        session_token="admin-token",
        region=region,
    )


def _quota_status(name: str, *, request_status: str | None = None) -> QuotaStatus:
    """Return one deterministic quota-status row."""
    return QuotaStatus(
        display_name=name,
        service_code="ec2",
        quota_code="Q-1234",
        current_value=1.0,
        target_value=2.0,
        source="current",
        meets_target=False,
        request_status=request_status,
    )


def _aws_setup_command() -> AWSSetupCommand:
    """Return one deterministic AWS setup command."""
    return AWSSetupCommand(
        admin_access_key_id="ADMINKEY",
        admin_secret_access_key="admin-secret",
        admin_session_token="admin-token",
        admin_region="us-east-1",
        tier="full",
    )


def _aws_teardown_command() -> AWSTeardownCommand:
    """Return one deterministic AWS teardown command."""
    return AWSTeardownCommand(
        admin_access_key_id="ADMINKEY",
        admin_secret_access_key="admin-secret",
        admin_session_token="admin-token",
        admin_region="us-east-1",
    )


def _config_setup_command() -> ConfigSetupCommand:
    """Return one deterministic config-setup command."""
    return ConfigSetupCommand(
        admin_access_key_id="ADMINKEY",
        admin_secret_access_key="admin-secret",
        admin_session_token="admin-token",
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
    )


class TestPolicyRendering:
    """Tests for IAM policy helpers."""

    def test_build_iam_policy_document_contains_expected_sids(self) -> None:
        """Core and full policy documents should expose the supported statement groups."""
        core = build_iam_policy_document(tier="core")
        full = build_iam_policy_document(tier="full")

        assert core["Version"] == "2012-10-17"
        core_sids = tuple(statement["Sid"] for statement in core["Statement"])
        full_sids = tuple(statement["Sid"] for statement in full["Statement"])
        assert core_sids == (
            "StsIdentity",
            "Route53RecordManagement",
            "Route53ChangePolling",
        )
        assert "Route53HostedZoneLifecycle" in full_sids
        assert "Ec2HaTestStackLifecycle" in full_sids
        assert "IamEksRoleLifecycle" in full_sids
        assert "EksTestStackLifecycle" in full_sids
        ec2_statement = next(
            statement
            for statement in full["Statement"]
            if statement["Sid"] == "Ec2HaTestStackLifecycle"
        )
        assert "ec2:Describe*" in ec2_statement["Action"]
        assert "ec2:ModifySubnetAttribute" in ec2_statement["Action"]
        assert "ec2:ModifyVpcAttribute" in ec2_statement["Action"]
        iam_statement = next(
            statement
            for statement in full["Statement"]
            if statement["Sid"] == "IamEksRoleLifecycle"
        )
        assert "iam:CreateRole" in iam_statement["Action"]
        assert "iam:ListRolePolicies" in iam_statement["Action"]
        assert "iam:PassRole" in iam_statement["Action"]
        eks_statement = next(
            statement
            for statement in full["Statement"]
            if statement["Sid"] == "EksTestStackLifecycle"
        )
        assert "eks:CreateCluster" in eks_statement["Action"]
        assert "eks:Describe*" in eks_statement["Action"]

    def test_build_iam_policy_json_is_parseable(self) -> None:
        """Rendered IAM policy JSON should stay parseable."""
        parsed = json.loads(build_iam_policy_json(tier="full"))

        assert parsed["Version"] == "2012-10-17"


class TestQuotaParsing:
    """Tests for quota inspection helpers."""

    def test_quota_status_rows_renders_expected_columns(self) -> None:
        """Quota rows should render deterministic string columns for PrintTable."""
        rows = quota_status_rows(
            (_quota_status("Running On-Demand Standard vCPU", request_status="CASE_OPEN"),)
        )

        assert rows == (("Running On-Demand Standard vCPU", "1", "2", "no", "CASE_OPEN", ""),)

    def test_list_regions_parses_cli_payload(self) -> None:
        """Live region parsing should normalize the JSON response into typed options."""
        payload: dict[str, object] = {
            "Regions": [
                {"RegionName": "us-east-1", "OptInStatus": "opt-in-not-required"},
                {"RegionName": "us-west-2", "OptInStatus": "opt-in-not-required"},
            ]
        }
        with patch("prodbox.lib.aws_admin._run_aws_cli_json", return_value=payload):
            regions = aws_admin._list_aws_regions(_admin_credentials())

        assert regions == (
            RegionChoice(region_name="us-east-1", opt_in_status="opt-in-not-required"),
            RegionChoice(region_name="us-west-2", opt_in_status="opt-in-not-required"),
        )

    def test_list_hosted_zones_parses_cli_payload(self) -> None:
        """Live hosted-zone parsing should strip the Route 53 resource prefix and trailing dot."""
        payload: dict[str, object] = {
            "HostedZones": [
                {"Id": "/hostedzone/Z1234567890ABC", "Name": "example.com."},
            ]
        }
        with patch("prodbox.lib.aws_admin._run_aws_cli_json", return_value=payload):
            zones = aws_admin._list_hosted_zones(_admin_credentials())

        assert zones == (HostedZoneChoice(zone_id="Z1234567890ABC", zone_name="example.com"),)

    def test_ensure_service_quota_requests_increase_when_below_target(self) -> None:
        """Quota inspection should request an increase when the current value is too low."""
        first = subprocess.CompletedProcess(
            args=("aws",),
            returncode=0,
            stdout=json.dumps({"Quota": {"Value": 8.0}}),
            stderr="",
        )
        second = subprocess.CompletedProcess(
            args=("aws",),
            returncode=0,
            stdout=json.dumps({"RequestedQuota": {"Status": "PENDING"}}),
            stderr="",
        )
        spec = aws_admin.BASELINE_QUOTA_SPECS[0]
        with patch(
            "prodbox.lib.aws_admin._run_aws_cli_json_completed",
            side_effect=(first, second),
        ):
            status = aws_admin._ensure_service_quota(  # noqa: SLF001
                _admin_credentials(),
                spec,
                request_if_needed=True,
            )

        assert status.current_value == 8.0
        assert status.request_status == "PENDING"


class TestPhase7Operations:
    """Tests for Phase 7 non-interactive operation helpers."""

    def test_operational_aws_credentials_are_valid_returns_false_when_settings_do_not_load(
        self,
    ) -> None:
        """Operational credential validation should fail closed when settings are invalid."""
        with patch(
            "prodbox.settings.Settings.from_config_json",
            side_effect=ValueError("invalid config"),
        ):
            assert operational_aws_credentials_are_valid() is False

    def test_restore_operational_aws_identity_from_admin_harness_uses_raw_config_mapping(
        self,
    ) -> None:
        """Operational AWS restore should read `aws_admin` from raw config, not validated settings."""
        config = {
            "aws_admin": {
                "access_key_id": "ADMINKEY",
                "secret_access_key": "admin-secret",
                "session_token": "admin-token",
                "region": "us-east-1",
            }
        }
        fake_result = IAMSetupResult(
            user_name="prodbox",
            policy_tier="full",
            access_key_id="AKIARESTORED",
            quota_statuses=(),
            dhall_path=Path("prodbox-config.dhall"),
        )

        with (
            patch("prodbox.settings.clear_settings_cache") as clear_cache,
            patch("prodbox.lib.aws_admin._load_current_config_mapping", return_value=config),
            patch(
                "prodbox.lib.aws_admin.aws_setup_command",
                return_value=Success(_aws_setup_command()),
            ) as setup_command,
            patch("prodbox.lib.aws_admin.run_aws_setup", return_value=fake_result),
            patch("prodbox.settings.Settings.from_config_json", return_value=object()),
        ):
            result = restore_operational_aws_identity_from_admin_harness()

        assert clear_cache.call_count == 2
        assert setup_command.call_args.kwargs["tier"] == "full"
        assert "Restored operational AWS IAM user prodbox" in result

    def test_operational_aws_policy_is_current_decodes_encoded_policy_document(self) -> None:
        """Policy freshness should accept the URL-encoded AWS IAM policy document payload."""
        config = {
            "aws_admin": {
                "access_key_id": "ADMINKEY",
                "secret_access_key": "admin-secret",
                "session_token": "admin-token",
                "region": "us-east-1",
            }
        }
        encoded_policy = (
            "%7B%22Version%22%3A%20%222012-10-17%22%2C%20%22Statement%22%3A%20"
            "%5B%7B%22Sid%22%3A%20%22StsIdentity%22%2C%20%22Effect%22%3A%20%22Allow%22%2C%20"
            "%22Action%22%3A%20%5B%22sts%3AGetCallerIdentity%22%5D%2C%20%22Resource%22%3A%20"
            "%22%2A%22%7D%5D%7D"
        )
        full_policy = build_iam_policy_document(tier="full")

        with (
            patch("prodbox.lib.aws_admin._load_current_config_mapping", return_value=config),
            patch(
                "prodbox.lib.aws_admin._run_aws_cli_json_completed",
                return_value=subprocess.CompletedProcess(
                    args=("aws",),
                    returncode=0,
                    stdout=json.dumps({"PolicyDocument": json.dumps(full_policy)}),
                    stderr="",
                ),
            ),
        ):
            assert operational_aws_policy_is_current() is True

        with (
            patch("prodbox.lib.aws_admin._load_current_config_mapping", return_value=config),
            patch(
                "prodbox.lib.aws_admin._run_aws_cli_json_completed",
                return_value=subprocess.CompletedProcess(
                    args=("aws",),
                    returncode=0,
                    stdout=json.dumps({"PolicyDocument": encoded_policy}),
                    stderr="",
                ),
            ),
        ):
            assert operational_aws_policy_is_current() is False

    def test_ensure_operational_aws_credentials_from_admin_harness_noops_when_valid(
        self,
    ) -> None:
        """Operational credential repair should no-op when creds and policy are current."""
        with (
            patch(
                "prodbox.lib.aws_admin.operational_aws_credentials_are_valid",
                return_value=True,
            ),
            patch(
                "prodbox.lib.aws_admin.operational_aws_policy_is_current",
                return_value=True,
            ),
            patch(
                "prodbox.lib.aws_admin.restore_operational_aws_identity_from_admin_harness"
            ) as restore,
        ):
            result = ensure_operational_aws_credentials_from_admin_harness()

        restore.assert_not_called()
        assert result == "Operational AWS credentials and IAM policy already valid"

    def test_ensure_operational_aws_credentials_from_admin_harness_restores_when_invalid(
        self,
    ) -> None:
        """Operational credential repair should recreate the IAM user when STS fails."""
        with (
            patch(
                "prodbox.lib.aws_admin.operational_aws_credentials_are_valid",
                return_value=False,
            ),
            patch(
                "prodbox.lib.aws_admin.restore_operational_aws_identity_from_admin_harness",
                return_value="restored",
            ) as restore,
        ):
            result = ensure_operational_aws_credentials_from_admin_harness()

        restore.assert_called_once_with()
        assert result == "restored"

    def test_ensure_operational_aws_credentials_from_admin_harness_restores_when_policy_is_stale(
        self,
    ) -> None:
        """Operational credential repair should recreate the IAM user when policy is stale."""
        with (
            patch(
                "prodbox.lib.aws_admin.operational_aws_credentials_are_valid",
                return_value=True,
            ),
            patch(
                "prodbox.lib.aws_admin.operational_aws_policy_is_current",
                return_value=False,
            ),
            patch(
                "prodbox.lib.aws_admin.restore_operational_aws_identity_from_admin_harness",
                return_value="restored",
            ) as restore,
        ):
            result = ensure_operational_aws_credentials_from_admin_harness()

        restore.assert_called_once_with()
        assert result == "restored"

    def test_run_aws_setup_updates_config_and_validates(self, tmp_path: Path) -> None:
        """AWS setup should write credentials into Dhall config and return the new access key."""
        with (
            patch(
                "prodbox.lib.aws_admin._ensure_operational_iam_user",
                return_value=("NEWKEY", "NEWSECRET", (_quota_status("quota"),)),
            ),
            patch("prodbox.lib.aws_admin._wait_for_operational_credentials_ready"),
            patch(
                "prodbox.lib.aws_admin._load_current_config_mapping",
                return_value=aws_admin._default_config_mapping(),  # noqa: SLF001
            ),
            patch(
                "prodbox.lib.aws_admin._write_dhall_config_mapping",
                return_value=tmp_path / "prodbox-config.dhall",
            ) as write_mock,
            patch("prodbox.lib.aws_admin._compile_and_validate_config"),
        ):
            result = run_aws_setup(_aws_setup_command())

        written_config = write_mock.call_args.args[0]
        assert written_config["aws"]["access_key_id"] == "NEWKEY"
        assert written_config["aws"]["secret_access_key"] == "NEWSECRET"
        assert isinstance(result, IAMSetupResult)
        assert result.access_key_id == "NEWKEY"

    def test_run_aws_setup_surfaces_post_write_validation_failures(self, tmp_path: Path) -> None:
        """AWS setup should explain when the injected credentials land in an otherwise invalid config."""
        with (
            patch(
                "prodbox.lib.aws_admin._ensure_operational_iam_user",
                return_value=("NEWKEY", "NEWSECRET", (_quota_status("quota"),)),
            ),
            patch("prodbox.lib.aws_admin._wait_for_operational_credentials_ready"),
            patch(
                "prodbox.lib.aws_admin._load_current_config_mapping",
                return_value=aws_admin._default_config_mapping(),  # noqa: SLF001
            ),
            patch(
                "prodbox.lib.aws_admin._write_dhall_config_mapping",
                return_value=tmp_path / "prodbox-config.dhall",
            ),
            patch(
                "prodbox.lib.aws_admin._compile_and_validate_config",
                side_effect=RuntimeError("config invalid"),
            ),
            pytest.raises(RuntimeError, match="prodbox config setup"),
        ):
            run_aws_setup(_aws_setup_command())

    def test_run_aws_setup_surfaces_operational_credential_validation_failures(self) -> None:
        """AWS setup should fail when the generated operational key never becomes usable."""
        with (
            patch(
                "prodbox.lib.aws_admin._ensure_operational_iam_user",
                return_value=("NEWKEY", "NEWSECRET", (_quota_status("quota"),)),
            ),
            patch(
                "prodbox.lib.aws_admin._wait_for_operational_credentials_ready",
                side_effect=RuntimeError("sts failed"),
            ),
            pytest.raises(RuntimeError, match="sts failed"),
        ):
            run_aws_setup(_aws_setup_command())

    def test_run_config_setup_writes_full_mapping_and_preserves_admin_section(
        self,
        tmp_path: Path,
    ) -> None:
        """Config setup should populate all supported sections while leaving `aws_admin` intact."""
        existing = aws_admin._default_config_mapping()  # noqa: SLF001
        existing["aws_admin"] = {
            "access_key_id": "admin-existing",
            "secret_access_key": "admin-secret-existing",
            "session_token": None,
            "region": "us-east-1",
        }

        with (
            patch(
                "prodbox.lib.aws_admin._ensure_operational_iam_user",
                return_value=("NEWKEY", "NEWSECRET", (_quota_status("quota"),)),
            ),
            patch("prodbox.lib.aws_admin._wait_for_operational_credentials_ready"),
            patch("prodbox.lib.aws_admin._load_current_config_mapping", return_value=existing),
            patch(
                "prodbox.lib.aws_admin._write_dhall_config_mapping",
                return_value=tmp_path / "prodbox-config.dhall",
            ) as write_mock,
            patch("prodbox.lib.aws_admin._compile_and_validate_config"),
        ):
            result = run_config_setup(_config_setup_command())

        written_config = write_mock.call_args.args[0]
        assert written_config["route53"]["zone_id"] == "Z1234567890ABC"
        assert written_config["domain"]["demo_fqdn"] == "demo.example.com"
        assert written_config["acme"]["email"] == "ops@example.com"
        assert written_config["deployment"]["dev_mode"] is True
        assert written_config["storage"]["manual_pv_host_root"] == ".data"
        assert written_config["aws_admin"]["access_key_id"] == "admin-existing"
        assert isinstance(result, ConfigSetupResult)
        assert result.access_key_id == "NEWKEY"

    def test_run_aws_teardown_clears_credentials_and_handles_missing_user(
        self, tmp_path: Path
    ) -> None:
        """AWS teardown should clear operational credentials even when the IAM user is already gone."""
        no_such_entity = subprocess.CompletedProcess(
            args=("aws",),
            returncode=254,
            stdout="",
            stderr="An error occurred (NoSuchEntity) when calling the ListAccessKeys operation: gone",
        )
        delete_policy = subprocess.CompletedProcess(
            args=("aws",),
            returncode=254,
            stdout="",
            stderr="An error occurred (NoSuchEntity) when calling the DeleteUserPolicy operation: gone",
        )
        delete_user = subprocess.CompletedProcess(
            args=("aws",),
            returncode=254,
            stdout="",
            stderr="An error occurred (NoSuchEntity) when calling the DeleteUser operation: gone",
        )
        existing = aws_admin._default_config_mapping()  # noqa: SLF001
        existing["aws"] = {
            "access_key_id": "OLDKEY",
            "secret_access_key": "OLDSECRET",
            "session_token": None,
            "region": "us-west-2",
        }

        with (
            patch(
                "prodbox.lib.aws_admin._run_aws_cli_json_completed",
                side_effect=(no_such_entity, delete_policy, delete_user),
            ),
            patch("prodbox.lib.aws_admin._load_current_config_mapping", return_value=existing),
            patch(
                "prodbox.lib.aws_admin._write_dhall_config_mapping",
                return_value=tmp_path / "prodbox-config.dhall",
            ) as write_mock,
            patch("prodbox.lib.aws_admin._compile_dhall_to_json"),
        ):
            result = run_aws_teardown(_aws_teardown_command())

        written_config = write_mock.call_args.args[0]
        assert written_config["aws"]["access_key_id"] == ""
        assert written_config["aws"]["secret_access_key"] == ""
        assert written_config["aws"]["region"] == "us-west-2"
        assert isinstance(result, IAMTeardownResult)
        assert result.user_deleted is False

    def test_run_aws_check_and_request_quotas_delegate_to_spec_helpers(self) -> None:
        """Quota commands should iterate over the supported spec sets."""
        with patch(
            "prodbox.lib.aws_admin._ensure_service_quota",
            side_effect=lambda _credentials, spec, request_if_needed: _quota_status(
                spec.display_name,
                request_status="PENDING" if request_if_needed else None,
            ),
        ):
            checked = run_aws_check_quotas(
                AWSCheckQuotasCommand(
                    admin_access_key_id="ADMINKEY",
                    admin_secret_access_key="admin-secret",
                    admin_session_token="admin-token",
                    admin_region="us-east-1",
                )
            )
            requested = run_aws_request_quotas(
                AWSRequestQuotasCommand(
                    admin_access_key_id="ADMINKEY",
                    admin_secret_access_key="admin-secret",
                    admin_session_token="admin-token",
                    admin_region="us-east-1",
                    tier="core",
                )
            )

        assert len(checked) == len(aws_admin.FULL_QUOTA_SPECS)
        assert len(requested) == len(aws_admin.BASELINE_QUOTA_SPECS)
        assert all(status.request_status == "PENDING" for status in requested)


class TestInteractiveCommandCollection:
    """Tests for interactive input collection helpers."""

    def test_prompt_admin_credentials_prints_console_navigation_guidance(self) -> None:
        """Admin credential prompts should explain where to create the temporary key."""
        prompt_answers = iter(("ADMINKEY", "admin-secret", "", "us-east-1"))
        echoed_messages: list[str] = []

        def _capture_echo(message: object = "", **_kwargs: object) -> None:
            echoed_messages.append(str(message))

        with (
            patch("shutil.which", return_value="/usr/bin/aws"),
            patch("click.echo", side_effect=_capture_echo),
            patch("click.prompt", side_effect=lambda *_args, **_kwargs: next(prompt_answers)),
        ):
            match aws_admin._prompt_admin_credentials(default_region="us-east-1"):  # noqa: SLF001
                case Success(value=credentials):
                    assert credentials.access_key_id == "ADMINKEY"
                    assert credentials.secret_access_key == "admin-secret"
                    assert credentials.session_token is None
                    assert credentials.region == "us-east-1"
                case Failure(error):
                    pytest.fail(error)

        assert any("IAM -> Users" in message for message in echoed_messages)
        assert any("Access keys -> Create access key" in message for message in echoed_messages)
        assert any("session token" in message.lower() for message in echoed_messages)

    def test_interactive_aws_setup_command_uses_region_picker(self) -> None:
        """Interactive AWS setup should prompt for admin creds then region selection."""
        with (
            patch(
                "prodbox.lib.aws_admin._prompt_admin_credentials",
                return_value=Success(_admin_credentials(region="us-east-1")),
            ),
            patch(
                "prodbox.lib.aws_admin._prompt_region_choice",
                return_value=Success("us-west-2"),
            ),
        ):
            match interactive_aws_setup_command(tier="full"):
                case Success(value=command):
                    assert command.admin_region == "us-west-2"
                    assert command.tier == "full"
                case Failure(error):
                    pytest.fail(error)

    def test_interactive_config_setup_command_prints_acme_and_policy_guidance(self) -> None:
        """Config setup should explain the ACME and IAM policy choices before prompting."""
        text_answers = iter(
            (
                "demo.example.com",
                "",
                "ops@example.com",
                "",
                ".data",
            )
        )
        confirm_answers = iter((True, True, True))
        choice_answers = iter((1, 0))
        echoed_messages: list[str] = []

        def _capture_echo(message: object = "", **_kwargs: object) -> None:
            echoed_messages.append(str(message))

        with (
            patch(
                "prodbox.lib.aws_admin._prompt_admin_credentials",
                return_value=Success(_admin_credentials(region="us-east-1")),
            ),
            patch(
                "prodbox.lib.aws_admin._prompt_region_choice",
                return_value=Success("us-east-1"),
            ),
            patch(
                "prodbox.lib.aws_admin._prompt_hosted_zone_choice",
                return_value=Success(
                    HostedZoneChoice(zone_id="Z1234567890ABC", zone_name="example.com")
                ),
            ),
            patch(
                "prodbox.lib.aws_admin._prompt_text",
                side_effect=lambda *_args, **_kwargs: next(text_answers),
            ),
            patch("prodbox.lib.aws_admin._prompt_int", return_value=60),
            patch(
                "prodbox.lib.aws_admin._confirm",
                side_effect=lambda *_args, **_kwargs: next(confirm_answers),
            ),
            patch(
                "prodbox.lib.aws_admin._prompt_numbered_choice",
                side_effect=lambda *_args, **_kwargs: next(choice_answers),
            ),
            patch("click.echo", side_effect=_capture_echo),
        ):
            match interactive_config_setup_command():
                case Success(value=command):
                    assert command.acme_server == aws_admin.LETS_ENCRYPT_ACME_SERVER
                    assert command.policy_tier == "full"
                case Failure(error):
                    pytest.fail(error)

        assert any("ZeroSSL (recommended)" in message for message in echoed_messages)
        assert any("Let's Encrypt" in message for message in echoed_messages)
        assert any("full (recommended)" in message for message in echoed_messages)
        assert any("Route 53, EC2 HA validation" in message for message in echoed_messages)

    def test_interactive_config_setup_command_collects_letsencrypt_flow(self) -> None:
        """Config setup should convert prompt answers into one validated command object."""
        text_answers = iter(
            (
                "demo.example.com",
                "",
                "ops@example.com",
                "",
                ".data",
            )
        )
        confirm_answers = iter((True, True, True))
        choice_answers = iter((1, 0))
        with (
            patch(
                "prodbox.lib.aws_admin._prompt_admin_credentials",
                return_value=Success(_admin_credentials(region="us-east-1")),
            ),
            patch(
                "prodbox.lib.aws_admin._prompt_region_choice",
                return_value=Success("us-east-1"),
            ),
            patch(
                "prodbox.lib.aws_admin._prompt_hosted_zone_choice",
                return_value=Success(
                    HostedZoneChoice(zone_id="Z1234567890ABC", zone_name="example.com")
                ),
            ),
            patch(
                "prodbox.lib.aws_admin._prompt_text",
                side_effect=lambda *_args, **_kwargs: next(text_answers),
            ),
            patch("prodbox.lib.aws_admin._prompt_int", return_value=60),
            patch(
                "prodbox.lib.aws_admin._confirm",
                side_effect=lambda *_args, **_kwargs: next(confirm_answers),
            ),
            patch(
                "prodbox.lib.aws_admin._prompt_numbered_choice",
                side_effect=lambda *_args, **_kwargs: next(choice_answers),
            ),
        ):
            match interactive_config_setup_command():
                case Success(value=command):
                    assert command.demo_fqdn == "demo.example.com"
                    assert command.vscode_fqdn is None
                    assert command.acme_server == aws_admin.LETS_ENCRYPT_ACME_SERVER
                    assert command.policy_tier == "full"
                case Failure(error):
                    pytest.fail(error)

    def test_interactive_quota_helpers_return_commands(self) -> None:
        """Interactive quota helpers should wrap prompted credentials into command ADTs."""
        with (
            patch(
                "prodbox.lib.aws_admin._prompt_admin_credentials",
                return_value=Success(_admin_credentials(region="us-east-1")),
            ),
            patch(
                "prodbox.lib.aws_admin._prompt_region_choice",
                return_value=Success("us-east-1"),
            ),
        ):
            match interactive_aws_check_quotas_command():
                case Success(value=check_command):
                    assert isinstance(check_command, AWSCheckQuotasCommand)
                case Failure(error):
                    pytest.fail(error)

            match interactive_aws_request_quotas_command(tier="core"):
                case Success(value=request_command):
                    assert isinstance(request_command, AWSRequestQuotasCommand)
                    assert request_command.tier == "core"
                case Failure(error):
                    pytest.fail(error)

            match interactive_aws_teardown_command():
                case Success(value=teardown_command):
                    assert isinstance(teardown_command, AWSTeardownCommand)
                case Failure(error):
                    pytest.fail(error)


class TestSummaryRenderers:
    """Tests for user-facing result renderers."""

    def test_renderers_include_expected_fields(self, tmp_path: Path) -> None:
        """Summary renderers should emit stable key-value lines."""
        setup_text = render_aws_setup_result(
            IAMSetupResult(
                user_name="prodbox",
                policy_tier="full",
                access_key_id="NEWKEY",
                quota_statuses=(_quota_status("quota", request_status="PENDING"),),
                dhall_path=tmp_path / "prodbox-config.dhall",
            )
        )
        teardown_text = render_aws_teardown_result(
            IAMTeardownResult(
                user_name="prodbox",
                deleted_access_keys=("OLDKEY",),
                user_deleted=True,
                dhall_path=tmp_path / "prodbox-config.dhall",
            )
        )
        config_text = render_config_setup_result(
            ConfigSetupResult(
                region="us-east-1",
                route53_zone_id="Z1234567890ABC",
                demo_fqdn="demo.example.com",
                vscode_fqdn="vscode.example.com",
                policy_tier="full",
                access_key_id="NEWKEY",
                quota_statuses=(_quota_status("quota", request_status="PENDING"),),
                dhall_path=tmp_path / "prodbox-config.dhall",
            )
        )

        assert "IAM_USER=prodbox" in setup_text
        assert "DELETED_ACCESS_KEYS=1" in teardown_text
        assert "DEMO_FQDN=demo.example.com" in config_text
