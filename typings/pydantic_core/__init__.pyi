"""Type stubs for pydantic_core.

Provides ErrorDetails TypedDict without any types.
Uses 'object' instead of 'any' for dynamic fields (input, ctx values).
"""

from typing import TypedDict
from typing_extensions import NotRequired

class ErrorDetails(TypedDict):
    """Structured validation error details."""

    type: str
    loc: tuple[int | str, ...]
    msg: str
    input: object
    ctx: NotRequired[dict[str, object]]
    url: NotRequired[str]

__all__ = ["ErrorDetails"]
