"""Unit tests for AWS `.env` auth enforcement helpers."""

from __future__ import annotations

from pathlib import Path

import pytest

from prodbox.lib.aws_auth import (
    assert_no_ambient_aws_auth_env_vars,
    build_dotenv_aws_env,
    find_disallowed_aws_auth_env_vars,
    find_disallowed_aws_auth_in_dotenv,
    load_dotenv_aws_auth,
)


class TestFindDisallowedAwsAuthEnvVars:
    """Tests for discovery of forbidden AWS auth env vars."""

    def test_returns_empty_tuple_when_no_forbidden_vars_are_set(self) -> None:
        """No forbidden vars should produce an empty result."""
        env = {
            "AWS_REGION": "us-east-1",
            "ROUTE53_ZONE_ID": "Z1234567890ABC",
        }

        assert find_disallowed_aws_auth_env_vars(env) == ()

    def test_returns_forbidden_vars_in_stable_order(self) -> None:
        """Forbidden vars should be reported in canonical order."""
        env = {
            "AWS_SECRET_ACCESS_KEY": "forbidden-secret",
            "AWS_ACCESS_KEY_ID": "forbidden-key",
            "AWS_PROFILE": "forbidden-profile",
        }

        assert find_disallowed_aws_auth_env_vars(env) == (
            "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY",
            "AWS_PROFILE",
        )


class TestAssertAmbientAwsAuthOnly:
    """Tests for rejection of ambient AWS auth env vars."""

    def test_accepts_env_without_auth_vars(self) -> None:
        """Non-auth env vars should be accepted."""
        env = {
            "AWS_REGION": "us-east-1",
            "ROUTE53_ZONE_ID": "Z1234567890ABC",
        }

        assert_no_ambient_aws_auth_env_vars(env)

    def test_rejects_env_with_auth_vars(self) -> None:
        """Forbidden auth env vars should raise a clear error."""
        env = {
            "AWS_ACCESS_KEY_ID": "forbidden-key",
            "AWS_SESSION_TOKEN": "forbidden-token",
        }

        with pytest.raises(ValueError, match="Ambient AWS auth env vars are forbidden"):
            assert_no_ambient_aws_auth_env_vars(env)


class TestDotenvEnforcement:
    """Tests for dotenv-file AWS auth loading."""

    def test_find_disallowed_aws_auth_in_dotenv_reads_unsupported_keys(
        self,
        tmp_path: Path,
    ) -> None:
        """Unsupported auth keys in dotenv files should be detected."""
        dotenv_path = tmp_path / ".env"
        dotenv_path.write_text(
            "AWS_PROFILE=forbidden-profile\nAWS_ROLE_ARN=forbidden-role\n",
            encoding="utf-8",
        )

        assert find_disallowed_aws_auth_in_dotenv(dotenv_path) == (
            "AWS_PROFILE",
            "AWS_ROLE_ARN",
        )

    def test_load_dotenv_aws_auth_reads_required_and_optional_keys(self, tmp_path: Path) -> None:
        """Explicit `.env` AWS auth should load into the helper dataclass."""
        dotenv_path = tmp_path / ".env"
        dotenv_path.write_text(
            "\n".join(
                [
                    "AWS_ACCESS_KEY_ID=test-access-key",
                    "AWS_SECRET_ACCESS_KEY=test-secret-key",
                    "AWS_SESSION_TOKEN=test-session-token",
                    "",
                ]
            ),
            encoding="utf-8",
        )

        auth = load_dotenv_aws_auth(dotenv_path)

        assert auth.access_key_id == "test-access-key"
        assert auth.secret_access_key == "test-secret-key"
        assert auth.session_token == "test-session-token"

    def test_load_dotenv_aws_auth_rejects_unsupported_keys(self, tmp_path: Path) -> None:
        """Unsupported dotenv auth keys should raise a clear error."""
        dotenv_path = tmp_path / ".env"
        dotenv_path.write_text("AWS_PROFILE=forbidden-profile\n", encoding="utf-8")

        with pytest.raises(ValueError, match="must not define unsupported AWS auth vars"):
            load_dotenv_aws_auth(dotenv_path)

    def test_load_dotenv_aws_auth_requires_required_keys(self, tmp_path: Path) -> None:
        """Missing required dotenv auth keys should raise a clear error."""
        dotenv_path = tmp_path / ".env"
        dotenv_path.write_text("AWS_ACCESS_KEY_ID=test-access-key\n", encoding="utf-8")

        with pytest.raises(ValueError, match="must define AWS auth for prodbox"):
            load_dotenv_aws_auth(dotenv_path)

    def test_build_dotenv_aws_env_injects_dotenv_credentials(self, tmp_path: Path) -> None:
        """AWS subprocess env should be rebuilt from `.env` credentials only."""
        dotenv_path = tmp_path / ".env"
        dotenv_path.write_text(
            "\n".join(
                [
                    "AWS_ACCESS_KEY_ID=test-access-key",
                    "AWS_SECRET_ACCESS_KEY=test-secret-key",
                    "",
                ]
            ),
            encoding="utf-8",
        )

        env = build_dotenv_aws_env(
            dotenv_path,
            extra_env={"AWS_REGION": "us-east-1", "CUSTOM_FLAG": "1"},
        )

        assert env["AWS_ACCESS_KEY_ID"] == "test-access-key"
        assert env["AWS_SECRET_ACCESS_KEY"] == "test-secret-key"
        assert env["AWS_REGION"] == "us-east-1"
        assert env["CUSTOM_FLAG"] == "1"

    def test_build_dotenv_aws_env_rejects_auth_overrides_in_extra_env(self, tmp_path: Path) -> None:
        """Extra subprocess env must not override `.env` AWS credentials."""
        dotenv_path = tmp_path / ".env"
        dotenv_path.write_text(
            "\n".join(
                [
                    "AWS_ACCESS_KEY_ID=test-access-key",
                    "AWS_SECRET_ACCESS_KEY=test-secret-key",
                    "",
                ]
            ),
            encoding="utf-8",
        )

        with pytest.raises(ValueError, match="must not override AWS auth loaded from \\.env"):
            build_dotenv_aws_env(
                dotenv_path,
                extra_env={"AWS_ACCESS_KEY_ID": "forbidden-key"},
            )
