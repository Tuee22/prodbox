"""AWS ambient-auth helpers shared by host-side code and tests."""

from __future__ import annotations

import os
from collections.abc import Mapping
from pathlib import Path

DISALLOWED_AWS_AUTH_ENV_VARS: tuple[str, ...] = (
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_SECURITY_TOKEN",
    "AWS_PROFILE",
    "AWS_DEFAULT_PROFILE",
    "AWS_SHARED_CREDENTIALS_FILE",
    "AWS_CONFIG_FILE",
    "AWS_WEB_IDENTITY_TOKEN_FILE",
    "AWS_ROLE_ARN",
    "AWS_ROLE_SESSION_NAME",
)


def find_disallowed_aws_auth_env_vars(
    env: Mapping[str, str] | None = None,
) -> tuple[str, ...]:
    """Return forbidden AWS auth env vars that are set and non-empty."""
    resolved_env = os.environ if env is None else env
    return tuple(
        name for name in DISALLOWED_AWS_AUTH_ENV_VARS if resolved_env.get(name) not in (None, "")
    )


def assert_ambient_aws_auth_only(env: Mapping[str, str] | None = None) -> None:
    """Fail when repo code is asked to use env-var-based AWS authentication."""
    present = find_disallowed_aws_auth_env_vars(env)
    match present:
        case ():
            return
        case _:
            joined = ", ".join(present)
            raise ValueError(
                "AWS auth env vars are forbidden for prodbox. "
                "Authenticate the host-level aws CLI outside the repo and rely on ambient "
                f"shared config/cache state only. Remove: {joined}"
            )


def find_disallowed_aws_auth_in_dotenv(path: Path) -> tuple[str, ...]:
    """Return forbidden AWS auth keys present in a dotenv-style file."""
    if not path.is_file():
        return ()

    present: list[str] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line in ("",) or line.startswith("#"):
            continue
        normalized = line.removeprefix("export ").strip()
        if "=" not in normalized:
            continue
        name, value = normalized.split("=", 1)
        key = name.strip()
        if key in DISALLOWED_AWS_AUTH_ENV_VARS and value.strip() != "" and key not in present:
            present.append(key)
    return tuple(present)


def assert_no_aws_auth_in_dotenv(path: Path) -> None:
    """Fail when a dotenv file under repo control contains AWS auth vars."""
    present = find_disallowed_aws_auth_in_dotenv(path)
    match present:
        case ():
            return
        case _:
            joined = ", ".join(present)
            raise ValueError(
                f"{path} must not define AWS auth env vars. "
                "Authenticate the host-level aws CLI outside the repo and remove: "
                f"{joined}"
            )
