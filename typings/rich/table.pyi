"""Type stubs for rich.table module."""

from typing import Sequence

class Table:
    """Rich table for tabular output."""

    def __init__(
        self,
        *headers: str,
        title: str | None = None,
        caption: str | None = None,
        width: int | None = None,
        min_width: int | None = None,
        box: object | None = None,
        safe_box: bool | None = None,
        padding: int | tuple[int, ...] = (0, 1),
        collapse_padding: bool = False,
        pad_edge: bool = True,
        expand: bool = False,
        show_header: bool = True,
        show_footer: bool = False,
        show_edge: bool = True,
        show_lines: bool = False,
        leading: int = 0,
        style: str | None = None,
        row_styles: Sequence[str] | None = None,
        header_style: str | None = None,
        footer_style: str | None = None,
        border_style: str | None = None,
        title_style: str | None = None,
        caption_style: str | None = None,
        title_justify: str = "center",
        caption_justify: str = "center",
        highlight: bool = False,
    ) -> None: ...

    def add_column(
        self,
        header: str = "",
        footer: str = "",
        header_style: str | None = None,
        footer_style: str | None = None,
        style: str | None = None,
        justify: str = "left",
        vertical: str = "top",
        overflow: str = "ellipsis",
        width: int | None = None,
        min_width: int | None = None,
        max_width: int | None = None,
        ratio: int | None = None,
        no_wrap: bool = False,
    ) -> None: ...

    def add_row(
        self,
        *renderables: object,
        style: str | None = None,
        end_section: bool = False,
    ) -> None: ...

__all__ = ["Table"]
