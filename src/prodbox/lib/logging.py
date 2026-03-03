"""Rich console logging setup for prodbox."""

from __future__ import annotations

import logging

from rich.console import Console
from rich.logging import RichHandler

console = Console()
error_console = Console(stderr=True)


def setup_logging(level: str = "INFO") -> None:
    """Configure Rich-based logging.

    Args:
        level: Logging level string (DEBUG, INFO, WARNING, ERROR).
    """
    logging.basicConfig(
        level=level,
        format="%(message)s",
        datefmt="[%X]",
        handlers=[RichHandler(console=console, rich_tracebacks=True)],
        force=True,
    )


def print_success(message: str) -> None:
    """Print a success message in green."""
    console.print(f"[bold green]{message}[/bold green]")


def print_error(message: str) -> None:
    """Print an error message in red to stderr."""
    error_console.print(f"[bold red]{message}[/bold red]")


def print_warning(message: str) -> None:
    """Print a warning message in yellow."""
    console.print(f"[bold yellow]{message}[/bold yellow]")


def print_info(message: str) -> None:
    """Print an info message in blue."""
    console.print(f"[bold blue]{message}[/bold blue]")
