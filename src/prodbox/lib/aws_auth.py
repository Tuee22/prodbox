"""AWS `.env` auth helpers shared by host-side code and tests."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

DOTENV_REQUIRED_AWS_AUTH_ENV_VARS: tuple[str, ...] = (
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
)

DOTENV_OPTIONAL_AWS_AUTH_ENV_VARS: tuple[str, ...] = ("AWS_SESSION_TOKEN",)

DOTENV_SUPPORTED_AWS_AUTH_ENV_VARS: tuple[str, ...] = (
    *DOTENV_REQUIRED_AWS_AUTH_ENV_VARS,
    *DOTENV_OPTIONAL_AWS_AUTH_ENV_VARS,
)

DISALLOWED_AWS_AUTH_ENV_VARS: tuple[str, ...] = (
    *DOTENV_SUPPORTED_AWS_AUTH_ENV_VARS,
    "AWS_SECURITY_TOKEN",
    "AWS_PROFILE",
    "AWS_DEFAULT_PROFILE",
    "AWS_SHARED_CREDENTIALS_FILE",
    "AWS_CONFIG_FILE",
    "AWS_WEB_IDENTITY_TOKEN_FILE",
    "AWS_ROLE_ARN",
    "AWS_ROLE_SESSION_NAME",
)


@dataclass(frozen=True)
class DotenvAwsAuth:
    """Explicit AWS credentials loaded from the repository `.env` file."""

    access_key_id: str
    secret_access_key: str
    session_token: str | None


def find_disallowed_aws_auth_env_vars(
    env: Mapping[str, str] | None = None,
) -> tuple[str, ...]:
    """Return forbidden ambient AWS auth env vars that are set and non-empty."""
    resolved_env = os.environ if env is None else env
    return tuple(
        name for name in DISALLOWED_AWS_AUTH_ENV_VARS if resolved_env.get(name) not in (None, "")
    )


def assert_no_ambient_aws_auth_env_vars(env: Mapping[str, str] | None = None) -> None:
    """Fail when ambient AWS auth env vars are present outside `.env`."""
    present = find_disallowed_aws_auth_env_vars(env)
    match present:
        case ():
            return
        case _:
            joined = ", ".join(present)
            raise ValueError(
                "Ambient AWS auth env vars are forbidden for prodbox. "
                "Define AWS credentials only in the repository .env file and remove: "
                f"{joined}"
            )


def _parse_dotenv_mapping(path: Path) -> dict[str, str]:
    """Parse a dotenv-style file into a plain mapping."""
    if not path.is_file():
        return {}

    parsed: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line in ("",) or line.startswith("#"):
            continue
        normalized = line.removeprefix("export ").strip()
        if "=" not in normalized:
            continue
        name, value = normalized.split("=", 1)
        key = name.strip()
        stripped_value = value.strip()
        if stripped_value == "":
            continue
        parsed[key] = stripped_value
    return parsed


def find_disallowed_aws_auth_in_dotenv(path: Path) -> tuple[str, ...]:
    """Return unsupported AWS auth keys present in a dotenv-style file."""
    parsed = _parse_dotenv_mapping(path)
    present: list[str] = []
    for key in DISALLOWED_AWS_AUTH_ENV_VARS:
        if key not in DOTENV_SUPPORTED_AWS_AUTH_ENV_VARS and key in parsed:
            present.append(key)
    return tuple(present)


def load_dotenv_aws_auth(path: Path) -> DotenvAwsAuth:
    """Load explicit AWS credentials from the repository `.env` file."""
    parsed = _parse_dotenv_mapping(path)
    match path.is_file():
        case False:
            raise ValueError(f"{path} must define AWS auth for prodbox")
        case True:
            pass

    present = find_disallowed_aws_auth_in_dotenv(path)
    match present:
        case ():
            pass
        case _:
            joined = ", ".join(present)
            raise ValueError(
                f"{path} must not define unsupported AWS auth vars. "
                "Use only explicit .env credentials and remove: "
                f"{joined}"
            )

    missing = tuple(
        key for key in DOTENV_REQUIRED_AWS_AUTH_ENV_VARS if parsed.get(key) in (None, "")
    )
    match missing:
        case ():
            return DotenvAwsAuth(
                access_key_id=parsed["AWS_ACCESS_KEY_ID"],
                secret_access_key=parsed["AWS_SECRET_ACCESS_KEY"],
                session_token=parsed.get("AWS_SESSION_TOKEN"),
            )
        case _:
            joined = ", ".join(missing)
            raise ValueError(f"{path} must define AWS auth for prodbox. Missing: {joined}")


def build_dotenv_aws_env(
    path: Path,
    *,
    extra_env: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Return subprocess env with AWS credentials sourced only from `.env`."""
    auth = load_dotenv_aws_auth(path)
    present_in_extra_env = find_disallowed_aws_auth_env_vars(extra_env)
    match present_in_extra_env:
        case ():
            pass
        case _:
            joined = ", ".join(present_in_extra_env)
            raise ValueError(
                "extra_env must not override AWS auth loaded from .env. " f"Remove: {joined}"
            )
    env = dict(os.environ)
    for key in DISALLOWED_AWS_AUTH_ENV_VARS:
        env.pop(key, None)
    env["AWS_ACCESS_KEY_ID"] = auth.access_key_id
    env["AWS_SECRET_ACCESS_KEY"] = auth.secret_access_key
    match auth.session_token:
        case str() as token:
            env["AWS_SESSION_TOKEN"] = token
        case None:
            env.pop("AWS_SESSION_TOKEN", None)
    if extra_env is not None:
        env.update(extra_env)
    return env
