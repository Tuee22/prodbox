"""Unit tests for AWS ambient-auth enforcement helpers."""

from __future__ import annotations

from pathlib import Path

import pytest

from prodbox.lib.aws_auth import (
    assert_ambient_aws_auth_only,
    assert_no_aws_auth_in_dotenv,
    find_disallowed_aws_auth_env_vars,
    find_disallowed_aws_auth_in_dotenv,
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
    """Tests for ambient-auth-only enforcement."""

    def test_accepts_env_without_auth_vars(self) -> None:
        """Non-auth env vars should be accepted."""
        env = {
            "AWS_REGION": "us-east-1",
            "ROUTE53_ZONE_ID": "Z1234567890ABC",
        }

        assert_ambient_aws_auth_only(env)

    def test_rejects_env_with_auth_vars(self) -> None:
        """Forbidden auth env vars should raise a clear error."""
        env = {
            "AWS_ACCESS_KEY_ID": "forbidden-key",
            "AWS_SESSION_TOKEN": "forbidden-token",
        }

        with pytest.raises(ValueError, match="AWS auth env vars are forbidden"):
            assert_ambient_aws_auth_only(env)


class TestDotenvEnforcement:
    """Tests for dotenv-file AWS auth rejection."""

    def test_find_disallowed_aws_auth_in_dotenv_reads_forbidden_keys(self, tmp_path: Path) -> None:
        """Forbidden keys in dotenv files should be detected."""
        dotenv_path = tmp_path / ".env"
        dotenv_path.write_text(
            "AWS_ACCESS_KEY_ID=forbidden-key\nAWS_SECRET_ACCESS_KEY=forbidden-secret\n",
            encoding="utf-8",
        )

        assert find_disallowed_aws_auth_in_dotenv(dotenv_path) == (
            "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY",
        )

    def test_assert_no_aws_auth_in_dotenv_rejects_forbidden_keys(self, tmp_path: Path) -> None:
        """Forbidden dotenv keys should raise a clear error."""
        dotenv_path = tmp_path / ".env"
        dotenv_path.write_text("AWS_PROFILE=forbidden-profile\n", encoding="utf-8")

        with pytest.raises(ValueError, match="must not define AWS auth env vars"):
            assert_no_aws_auth_in_dotenv(dotenv_path)
