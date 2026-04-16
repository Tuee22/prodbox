"""Real AWS IAM lifecycle integration tests for the Phase 7 onboarding flow."""

from __future__ import annotations

import shutil
import subprocess
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch

import pytest
from click.testing import CliRunner

import prodbox.lib.aws_admin as aws_admin_module
from prodbox.cli.command_adt import AWSSetupCommand, AWSTeardownCommand
from prodbox.cli.main import cli
from prodbox.cli.types import Success
from prodbox.lib.aws_admin import AdminAWSCredentials, run_aws_setup, run_aws_teardown
from prodbox.settings import REPOSITORY_ROOT, Settings


def _require_admin_credentials() -> tuple[Settings, AdminAWSCredentials]:
    """Load the real configured elevated credentials or fail fast with guidance."""
    if shutil.which("aws") is None:
        raise AssertionError("aws CLI is required for tests/integration/test_aws_iam_lifecycle.py")
    if shutil.which("dhall-to-json") is None:
        raise AssertionError(
            "dhall-to-json is required for tests/integration/test_aws_iam_lifecycle.py"
        )

    try:
        settings = Settings.from_config_json()
    except Exception as error:
        raise AssertionError(
            "load a valid repository-root prodbox-config.dhall/json before running "
            "`poetry run prodbox test integration aws-iam`"
        ) from error

    if (
        settings.aws_admin_access_key_id is None
        or settings.aws_admin_secret_access_key is None
        or settings.aws_admin_region is None
    ):
        raise AssertionError(
            "populate aws_admin.access_key_id, aws_admin.secret_access_key, and aws_admin.region "
            "in prodbox-config.dhall before running `poetry run prodbox test integration aws-iam`"
        )

    return (
        settings,
        AdminAWSCredentials(
            access_key_id=settings.aws_admin_access_key_id,
            secret_access_key=settings.aws_admin_secret_access_key,
            session_token=settings.aws_admin_session_token,
            region=settings.aws_admin_region,
        ),
    )


def _seed_temp_repo_root(
    temp_root: Path,
    *,
    base_config: dict[str, object],
) -> None:
    """Copy the Dhall schema and write the initial temporary config."""
    shutil.copy2(
        REPOSITORY_ROOT / "prodbox-config-types.dhall", temp_root / "prodbox-config-types.dhall"
    )
    with patch.object(aws_admin_module, "REPOSITORY_ROOT", temp_root):
        aws_admin_module._write_dhall_config_mapping(base_config)  # noqa: SLF001


def _operational_aws_env(settings: Settings) -> dict[str, str]:
    """Build an AWS CLI environment from operational credentials in a temp config."""
    env = aws_admin_module._subprocess_base_env()  # noqa: SLF001
    env["AWS_ACCESS_KEY_ID"] = settings.aws_access_key_id
    env["AWS_SECRET_ACCESS_KEY"] = settings.aws_secret_access_key
    env["AWS_REGION"] = settings.aws_region
    env["AWS_DEFAULT_REGION"] = settings.aws_region
    if settings.aws_session_token is not None:
        env["AWS_SESSION_TOKEN"] = settings.aws_session_token
    return env


def _teardown_command(credentials: AdminAWSCredentials) -> AWSTeardownCommand:
    """Return the canonical teardown command for one elevated credential set."""
    return AWSTeardownCommand(
        admin_access_key_id=credentials.access_key_id,
        admin_secret_access_key=credentials.secret_access_key,
        admin_session_token=credentials.session_token,
        admin_region=credentials.region,
    )


@pytest.mark.integration
def test_aws_setup_and_teardown_round_trip_with_real_admin_credentials(tmp_path: Path) -> None:
    """aws setup should create a usable operational IAM user and teardown should remove it."""
    _settings, admin_credentials = _require_admin_credentials()
    base_config = deepcopy(aws_admin_module._load_current_config_mapping())  # noqa: SLF001
    base_config["aws"] = {
        "access_key_id": "",
        "secret_access_key": "",
        "session_token": None,
        "region": admin_credentials.region,
    }
    _seed_temp_repo_root(tmp_path, base_config=base_config)

    main_error: BaseException | None = None
    cleanup_error: BaseException | None = None
    with patch.object(aws_admin_module, "REPOSITORY_ROOT", tmp_path):
        try:
            result = run_aws_setup(
                AWSSetupCommand(
                    admin_access_key_id=admin_credentials.access_key_id,
                    admin_secret_access_key=admin_credentials.secret_access_key,
                    admin_session_token=admin_credentials.session_token,
                    admin_region=admin_credentials.region,
                    tier="core",
                )
            )
            temp_settings = Settings.from_config_json(tmp_path / "prodbox-config.json")
            assert temp_settings.aws_access_key_id == result.access_key_id
            assert temp_settings.aws_secret_access_key != ""
            verify = subprocess.run(
                ["aws", "sts", "get-caller-identity", "--output", "json"],
                check=False,
                capture_output=True,
                text=True,
                cwd=tmp_path,
                env=_operational_aws_env(temp_settings),
            )
            assert verify.returncode == 0, verify.stderr.strip() or verify.stdout.strip()
        except BaseException as error:
            main_error = error
        finally:
            try:
                run_aws_teardown(_teardown_command(admin_credentials))
                cleared_config = aws_admin_module._load_current_config_mapping()  # noqa: SLF001
                aws_config = cleared_config["aws"]
                assert isinstance(aws_config, dict)
                assert aws_config["access_key_id"] == ""
                assert aws_config["secret_access_key"] == ""
            except BaseException as error:
                cleanup_error = error

    if cleanup_error is not None and main_error is not None:
        raise AssertionError(
            f"{type(main_error).__name__}: {main_error}\ncleanup failed: {cleanup_error}"
        ) from cleanup_error
    if cleanup_error is not None:
        raise cleanup_error
    if main_error is not None:
        raise main_error


@pytest.mark.integration
def test_config_setup_cli_flow_uses_real_admin_credentials_and_preserves_aws_admin(
    cli_runner: CliRunner,
    tmp_path: Path,
) -> None:
    """config setup should build a complete temp config and preserve aws_admin credentials."""
    settings, admin_credentials = _require_admin_credentials()
    regions = aws_admin_module._list_aws_regions(admin_credentials)  # noqa: SLF001
    if regions == ():
        raise AssertionError(
            "aws ec2 describe-regions returned no regions for aws-iam integration test"
        )
    zones = aws_admin_module._list_hosted_zones(admin_credentials)  # noqa: SLF001
    if zones == ():
        raise AssertionError(
            "create at least one Route 53 hosted zone before running `prodbox test integration aws-iam`"
        )

    selected_region_index = next(
        (
            index
            for index, region in enumerate(regions)
            if region.region_name == settings.aws_region
        ),
        0,
    )
    selected_zone_index = next(
        (index for index, zone in enumerate(zones) if zone.zone_id == settings.route53_zone_id),
        0,
    )
    selected_zone = zones[selected_zone_index]

    base_config = aws_admin_module._default_config_mapping()  # noqa: SLF001
    base_config["aws_admin"] = {
        "access_key_id": admin_credentials.access_key_id,
        "secret_access_key": admin_credentials.secret_access_key,
        "session_token": admin_credentials.session_token,
        "region": admin_credentials.region,
    }
    _seed_temp_repo_root(tmp_path, base_config=base_config)

    prompt_text_values = iter(
        (
            f"demo.{selected_zone.zone_name}",
            "",
            settings.acme_email,
            "",
            ".data",
        )
    )
    prompt_choice_values = iter(
        (
            selected_region_index,
            selected_zone_index,
            1,
            1,
        )
    )
    confirm_values = iter((True, True, True))

    main_error: BaseException | None = None
    cleanup_error: BaseException | None = None
    with (
        patch.object(aws_admin_module, "REPOSITORY_ROOT", tmp_path),
        patch(
            "prodbox.lib.aws_admin._prompt_admin_credentials",
            return_value=Success(admin_credentials),
        ),
        patch(
            "prodbox.lib.aws_admin._prompt_text",
            side_effect=lambda *_args, **_kwargs: next(prompt_text_values),
        ),
        patch("prodbox.lib.aws_admin._prompt_int", return_value=60),
        patch(
            "prodbox.lib.aws_admin._prompt_numbered_choice",
            side_effect=lambda *_args, **_kwargs: next(prompt_choice_values),
        ),
        patch(
            "prodbox.lib.aws_admin._confirm",
            side_effect=lambda *_args, **_kwargs: next(confirm_values),
        ),
    ):
        try:
            result = cli_runner.invoke(cli, ["config", "setup"], catch_exceptions=False)
            assert result.exit_code == 0
            assert f"ROUTE53_ZONE_ID={selected_zone.zone_id}" in result.output
            temp_settings = Settings.from_config_json(tmp_path / "prodbox-config.json")
            assert temp_settings.route53_zone_id == selected_zone.zone_id
            assert temp_settings.demo_fqdn == f"demo.{selected_zone.zone_name}"
            assert temp_settings.aws_access_key_id != ""
            assert temp_settings.aws_admin_access_key_id == admin_credentials.access_key_id
            assert temp_settings.aws_admin_region == admin_credentials.region
        except BaseException as error:
            main_error = error
        finally:
            try:
                run_aws_teardown(_teardown_command(admin_credentials))
            except BaseException as error:
                cleanup_error = error

    if cleanup_error is not None and main_error is not None:
        raise AssertionError(
            f"{type(main_error).__name__}: {main_error}\ncleanup failed: {cleanup_error}"
        ) from cleanup_error
    if cleanup_error is not None:
        raise cleanup_error
    if main_error is not None:
        raise main_error
