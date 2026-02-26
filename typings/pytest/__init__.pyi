"""Complete type stubs for pytest.

Provides comprehensive type definitions for pytest fixtures, raises, and marks.
Designed to satisfy ultra-strict mypy configuration (disallow_any_expr, disallow_any_decorated).
Zero any types - fully type-safe.
"""

from typing import TypeVar, Callable, overload
from typing_extensions import ParamSpec

_T = TypeVar("_T")
_E = TypeVar("_E", bound=BaseException)
_P = ParamSpec("_P")
_R = TypeVar("_R")

# Parser - for pytest_addoption hook
class Parser:
    """Parser for pytest command line options."""

    def addoption(
        self,
        *opts: str,
        action: str | None = None,
        nargs: int | str | None = None,
        const: object = None,
        default: object = None,
        type: Callable[[str], object] | None = None,
        choices: list[object] | None = None,
        required: bool = False,
        help: str | None = None,
        metavar: str | None = None,
    ) -> None: ...

# Fixture decorator
@overload
def fixture(
    fixture_function: Callable[_P, _R],
    *,
    scope: str = "function",
    params: list[object] | None = None,
    autouse: bool = False,
    ids: list[str] | None = None,
    name: str | None = None,
) -> Callable[_P, _R]: ...
@overload
def fixture(
    *,
    scope: str = "function",
    params: list[object] | None = None,
    autouse: bool = False,
    ids: list[str] | None = None,
    name: str | None = None,
) -> Callable[[Callable[_P, _R]], Callable[_P, _R]]: ...

# ExceptionInfo
class ExceptionInfo[_E]:
    """Information about a captured exception."""

    @property
    def value(self) -> _E: ...
    @property
    def type(self) -> type[_E]: ...
    @property
    def typename(self) -> str: ...
    @property
    def traceback(self) -> object: ...
    def match(self, pattern: str) -> bool: ...

# RaisesContext
class RaisesContext[_E]:
    """Context manager returned by pytest.raises()."""

    @property
    def value(self) -> _E: ...
    @property
    def type(self) -> type[_E]: ...
    def __enter__(self) -> ExceptionInfo[_E]: ...
    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_val: BaseException | None,
        exc_tb: object,
    ) -> bool: ...

# raises()
@overload
def raises(
    expected_exception: type[_E],
    *,
    match: str | None = None,
) -> RaisesContext[_E]: ...
@overload
def raises(
    expected_exception: tuple[type[BaseException], ...],
    *,
    match: str | None = None,
) -> RaisesContext[BaseException]: ...
@overload
def raises(
    expected_exception: type[_E],
    func: Callable[_P, _R],
    *args: _P.args,
    **kwargs: _P.kwargs,
) -> ExceptionInfo[_E]: ...

# Mark decorator
class MarkDecorator:
    """Decorator for applying marks to test functions."""

    def __call__(self, func: Callable[_P, _R]) -> Callable[_P, _R]: ...

class Mark:
    """Generator for creating mark decorators."""

    def skip(self, reason: str = "") -> MarkDecorator: ...
    def skipif(self, condition: bool, *, reason: str = "") -> MarkDecorator: ...
    def xfail(
        self,
        condition: bool = True,
        *,
        reason: str = "",
        raises: type[BaseException] | tuple[type[BaseException], ...] | None = None,
        strict: bool = False,
    ) -> MarkDecorator: ...
    def parametrize(
        self,
        argnames: str | list[str],
        argvalues: list[object] | list[tuple[object, ...]],
        *,
        indirect: bool | list[str] = False,
        ids: list[str] | Callable[[object], str] | None = None,
        scope: str | None = None,
    ) -> MarkDecorator: ...
    def usefixtures(self, *fixture_names: str) -> MarkDecorator: ...
    def timeout(self, seconds: float | int) -> MarkDecorator: ...
    def __getattr__(self, name: str) -> MarkDecorator: ...

mark: Mark

# MonkeyPatch
class MonkeyPatch:
    """Helper to modify objects, dictionaries, environment variables."""

    def setattr(
        self,
        target: object,
        name: str,
        value: object,
        raising: bool = True,
    ) -> None: ...
    def delattr(
        self,
        target: object,
        name: str,
        raising: bool = True,
    ) -> None: ...
    def setitem(
        self,
        dic: dict[object, object],
        name: object,
        value: object,
    ) -> None: ...
    def delitem(
        self,
        dic: dict[object, object],
        name: object,
        raising: bool = True,
    ) -> None: ...
    def setenv(self, name: str, value: str, prepend: str | None = None) -> None: ...
    def delenv(self, name: str, raising: bool = True) -> None: ...
    def syspath_prepend(self, path: str) -> None: ...
    def chdir(self, path: str) -> None: ...
    def undo(self) -> None: ...

# warns()
class WarnsContext:
    """Context manager for checking warnings."""

    def __enter__(self) -> list[object]: ...
    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_val: BaseException | None,
        exc_tb: object,
    ) -> bool: ...

def warns(
    expected_warning: type[Warning] | tuple[type[Warning], ...],
    *,
    match: str | None = None,
) -> WarnsContext: ...

# approx()
class approx:
    """Approximate equality for floating point numbers."""

    def __init__(
        self,
        expected: float | complex | list[float] | dict[object, float],
        rel: float | None = None,
        abs: float | None = None,
        nan_ok: bool = False,
    ) -> None: ...
    def __eq__(self, other: object) -> bool: ...
    def __ne__(self, other: object) -> bool: ...

def fail(msg: str = "", pytrace: bool = True) -> None: ...
def skip(msg: str = "", *, allow_module_level: bool = False) -> None: ...
def xfail(reason: str = "") -> None: ...

# CaptureFixture
class CaptureResult[_T]:
    """Result of capturing output."""

    out: _T
    err: _T

class CaptureFixture[_T]:
    """Fixture for capturing stdout/stderr output."""

    def readouterr(self) -> CaptureResult[_T]: ...

def main(args: list[str] | None = None, plugins: list[object] | None = None) -> int: ...
