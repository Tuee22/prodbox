"""Custom type stubs for Pydantic v2.

Eliminates any types from ErrorDetails to satisfy ultra-strict mypy configuration.
Uses 'object' as top type instead of 'any' for dynamically-typed fields.
Zero any types - fully type-safe for ultra-strict mypy.
"""

from typing import Callable, TypeVar, TypedDict
from typing_extensions import NotRequired, ParamSpec, Self, TypeAlias

from pydantic_core import ErrorDetails as ErrorDetails

_ModelT = TypeVar("_ModelT", bound="BaseModel")
_T = TypeVar("_T")
_P = ParamSpec("_P")
_FieldT = TypeVar("_FieldT")

ConfigDict: TypeAlias = dict[str, object]

def Field(
    default: _FieldT = ...,
    *,
    default_factory: Callable[[], _FieldT] | None = None,
    alias: str | None = None,
    title: str | None = None,
    description: str | None = None,
    exclude: bool | None = None,
    **extra: object,
) -> _FieldT: ...

def field_validator(
    *fields: str, mode: str = "after"
) -> Callable[[Callable[_P, _T]], Callable[_P, _T]]: ...

class BaseModel:
    """Pydantic base model."""

    def __init__(self, **data: object) -> None: ...
    def model_copy(
        self: _ModelT,
        *,
        update: dict[str, object] | None = None,
        deep: bool = False,
    ) -> _ModelT: ...
    @classmethod
    def model_validate(
        cls: type[_ModelT],
        obj: object,
        *,
        strict: bool | None = None,
        from_attributes: bool | None = None,
        context: dict[str, object] | None = None,
    ) -> _ModelT: ...
    def model_dump(
        self,
        *,
        mode: str = "python",
        include: set[str] | None = None,
        exclude: set[str] | None = None,
        by_alias: bool = False,
        exclude_unset: bool = False,
        exclude_defaults: bool = False,
        exclude_none: bool = False,
        round_trip: bool = False,
        warnings: bool = True,
    ) -> dict[str, object]: ...
    def model_dump_json(
        self,
        *,
        indent: int | None = None,
        include: set[str] | None = None,
        exclude: set[str] | None = None,
        by_alias: bool = False,
        exclude_unset: bool = False,
        exclude_defaults: bool = False,
        exclude_none: bool = False,
        round_trip: bool = False,
        warnings: bool = True,
    ) -> str: ...

class ValidationError(Exception):
    """Pydantic validation error."""

    def __init__(
        self,
        errors: list[ErrorDetails] | None = None,
        model: type[object] | None = None,
    ) -> None: ...
    def errors(
        self,
        *,
        include_url: bool = True,
        include_context: bool = True,
        include_input: bool = True,
    ) -> list[ErrorDetails]: ...
    def error_count(self) -> int: ...
    def __str__(self) -> str: ...

__all__ = [
    "BaseModel",
    "ConfigDict",
    "ErrorDetails",
    "Field",
    "ValidationError",
    "field_validator",
]
