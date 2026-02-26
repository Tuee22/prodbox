"""Type stubs for rich.logging module."""

import logging
from typing import Sequence
from rich.console import Console

class RichHandler(logging.Handler):
    """Rich logging handler."""

    def __init__(
        self,
        level: int = logging.NOTSET,
        console: Console | None = None,
        show_time: bool = True,
        omit_repeated_times: bool = True,
        show_level: bool = True,
        show_path: bool = True,
        enable_link_path: bool = True,
        highlighter: object | None = None,
        markup: bool = False,
        rich_tracebacks: bool = False,
        tracebacks_width: int | None = None,
        tracebacks_extra_lines: int = 3,
        tracebacks_theme: str | None = None,
        tracebacks_word_wrap: bool = True,
        tracebacks_show_locals: bool = False,
        tracebacks_suppress: Sequence[str] = (),
        locals_max_length: int = 10,
        locals_max_string: int = 80,
        log_time_format: str | object = "[%x %X]",
        keywords: list[str] | None = None,
    ) -> None: ...

__all__ = ["RichHandler"]
