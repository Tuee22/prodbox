"""Utilities to install the entrypoint guard into the active virtualenv."""

from __future__ import annotations

import sysconfig
from pathlib import Path


def guard_install_path() -> Path:
    """Return the target .pth path for the active interpreter."""
    purelib = sysconfig.get_paths()["purelib"]
    return Path(purelib) / "prodbox_entrypoint_guard.pth"


def guard_script_content() -> str:
    """Return the .pth content for the entrypoint guard shim."""
    return "\n".join(
        [
            "import prodbox.lib.lint.poetry_entrypoint_guard as _guard; "
            "_guard.enforce_entrypoint_policy()",
            "",
        ]
    )
