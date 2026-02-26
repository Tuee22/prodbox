"""Type stubs for rich.console module."""

from typing import IO, TextIO

class Console:
    """Rich console for styled output."""

    def __init__(
        self,
        color_system: str | None = "auto",
        force_terminal: bool | None = None,
        force_jupyter: bool | None = None,
        force_interactive: bool | None = None,
        soft_wrap: bool = False,
        theme: object | None = None,
        stderr: bool = False,
        file: TextIO | None = None,
        quiet: bool = False,
        width: int | None = None,
        height: int | None = None,
        style: str | None = None,
        no_color: bool | None = None,
        tab_size: int = 8,
        record: bool = False,
        markup: bool = True,
        emoji: bool = True,
        highlight: bool = True,
        log_time: bool = True,
        log_path: bool = True,
        log_time_format: str = "[%X]",
        legacy_windows: bool | None = None,
    ) -> None: ...

    def print(
        self,
        *objects: object,
        sep: str = " ",
        end: str = "\n",
        style: str | None = None,
        justify: str | None = None,
        overflow: str | None = None,
        no_wrap: bool | None = None,
        emoji: bool | None = None,
        markup: bool | None = None,
        highlight: bool | None = None,
        width: int | None = None,
        height: int | None = None,
        crop: bool = True,
        soft_wrap: bool | None = None,
        new_line_start: bool = False,
    ) -> None: ...

    def log(
        self,
        *objects: object,
        sep: str = " ",
        end: str = "\n",
        style: str | None = None,
        justify: str | None = None,
        emoji: bool | None = None,
        markup: bool | None = None,
        highlight: bool | None = None,
        log_locals: bool = False,
    ) -> None: ...

    def rule(
        self,
        title: str = "",
        characters: str = "-",
        style: str = "rule.line",
        align: str = "center",
    ) -> None: ...

__all__ = ["Console"]
