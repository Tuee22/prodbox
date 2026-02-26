"""Type stubs for Pulumi core module.

Provides typed interfaces for Pulumi primitives: Output, Input, ResourceOptions, export.
Zero any types - uses 'object' for dynamic values.
"""

from typing import TypeVar, Generic, Callable, Sequence
from pathlib import Path

T = TypeVar("T")

class Output(Generic[T]):
    """Represents an asynchronous output value from a Pulumi resource."""

    def apply(self, func: Callable[[T], object]) -> "Output[object]": ...
    def __getitem__(self, key: str | int) -> "Output[object]": ...

class Input(Generic[T]):
    """Represents a value that may be an Output or literal."""

    ...

class ResourceOptions:
    """Options for configuring a resource."""

    def __init__(
        self,
        provider: object | None = None,
        depends_on: list[object] | Sequence[object] | None = None,
        ignore_changes: list[str] | None = None,
        parent: object | None = None,
        protect: bool = False,
        delete_before_replace: bool = False,
        version: str | None = None,
        aliases: list[str] | None = None,
        custom_timeouts: object | None = None,
    ) -> None: ...

class CustomResource:
    """Base class for custom resources."""

    def __init__(
        self,
        t: str,
        name: str,
        props: dict[str, object] | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

class ComponentResource:
    """Base class for component resources."""

    def __init__(
        self,
        t: str,
        name: str,
        props: dict[str, object] | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

class ProviderResource:
    """Base class for provider resources."""

    def __init__(
        self,
        pkg: str,
        name: str,
        props: dict[str, object] | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

def export(name: str, value: object) -> None:
    """Export a stack output."""
    ...

def get_stack() -> str:
    """Get the current stack name."""
    ...

def get_project() -> str:
    """Get the current project name."""
    ...

class Config:
    """Pulumi configuration."""

    def __init__(self, name: str | None = None) -> None: ...
    def get(self, key: str, default: str | None = None) -> str | None: ...
    def require(self, key: str) -> str: ...
    def get_bool(self, key: str, default: bool | None = None) -> bool | None: ...
    def require_bool(self, key: str) -> bool: ...
    def get_int(self, key: str, default: int | None = None) -> int | None: ...
    def require_int(self, key: str) -> int: ...
    def get_float(self, key: str, default: float | None = None) -> float | None: ...
    def require_float(self, key: str) -> float: ...
    def get_secret(self, key: str) -> Output[str] | None: ...
    def require_secret(self, key: str) -> Output[str]: ...

__all__ = [
    "Output",
    "Input",
    "ResourceOptions",
    "CustomResource",
    "ComponentResource",
    "ProviderResource",
    "Config",
    "export",
    "get_stack",
    "get_project",
]
