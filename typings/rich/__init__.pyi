"""Type stubs for rich library.

Provides typed interfaces for Console, Table, and logging.
"""

from rich.console import Console as Console
from rich.table import Table as Table
from rich.logging import RichHandler as RichHandler

__all__ = ["Console", "Table", "RichHandler"]
