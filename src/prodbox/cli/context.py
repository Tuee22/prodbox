"""Click context utilities for settings injection."""

from __future__ import annotations

import click

from prodbox.settings import Settings


class SettingsContext:
    """Click context object holding settings."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings


pass_settings = click.make_pass_decorator(SettingsContext, ensure=True)
