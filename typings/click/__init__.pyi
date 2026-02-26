"""Complete type stubs for click library.

Provides comprehensive type definitions for Click decorators and classes.
Designed to satisfy ultra-strict mypy configuration (disallow_any_expr, disallow_any_decorated).
Zero any types - fully type-safe.
"""

from typing import Callable, TypeVar, IO, overload
from typing_extensions import ParamSpec

_T = TypeVar("_T")
_P = ParamSpec("_P")
_R = TypeVar("_R")

# Re-export core classes
from click.core import (
    Context as Context,
    Parameter as Parameter,
    Option as Option,
    Argument as Argument,
    Command as Command,
    Group as Group,
)

# Re-export testing classes
class Result:
    """Result of a CLI test invocation."""

    exit_code: int
    output: str
    exception: BaseException | None
    exc_info: tuple[type[BaseException], BaseException, object] | None

    @property
    def stdout(self) -> str: ...
    @property
    def stderr(self) -> str: ...

class CliRunner:
    """Test runner for Click applications."""

    def __init__(
        self,
        charset: str = "utf-8",
        env: dict[str, str] | None = None,
        echo_stdin: bool = False,
        mix_stderr: bool = True,
    ) -> None: ...
    def invoke(
        self,
        cli: Command,
        args: str | list[str] | None = None,
        input: str | bytes | IO[str] | None = None,
        env: dict[str, str] | None = None,
        catch_exceptions: bool = True,
        color: bool = False,
        **extra: object,
    ) -> Result: ...

# Re-export parameter types
class Choice:
    """Parameter type for choices."""

    def __init__(self, choices: list[str], case_sensitive: bool = True) -> None: ...

class Path:
    """Parameter type for file paths."""

    def __init__(
        self,
        exists: bool = False,
        file_okay: bool = True,
        dir_okay: bool = True,
        writable: bool = False,
        readable: bool = True,
        resolve_path: bool = False,
        allow_dash: bool = False,
        path_type: type[str] | None = None,
    ) -> None: ...

# Decorator functions - these preserve the decorated function signature
@overload
def command(
    name: Callable[_P, _R],
) -> Command: ...
@overload
def command(
    name: str | None = None,
    cls: type[Command] | None = None,
    **attrs: object,
) -> Callable[[Callable[_P, _R]], Command]: ...
@overload
def group(
    name: Callable[_P, _R],
) -> Group: ...
@overload
def group(
    name: str | None = None,
    cls: type[Group] | None = None,
    **attrs: object,
) -> Callable[[Callable[_P, _R]], Group]: ...
def argument(
    param: str,
    *,
    type: object = None,
    required: bool = True,
    default: object = None,
    callback: Callable[[Context, Parameter, object], object] | None = None,
    nargs: int | None = None,
    metavar: str | None = None,
    expose_value: bool = True,
    is_eager: bool = False,
    envvar: str | list[str] | None = None,
    shell_complete: Callable[[Context, Parameter, str], list[str]] | None = None,
) -> Callable[[Callable[_P, _R]], Callable[_P, _R]]: ...
def option(
    *param_decls: str,
    type: object = None,
    default: object = None,
    required: bool = False,
    callback: Callable[[Context, Parameter, object], object] | None = None,
    nargs: int | None = None,
    metavar: str | None = None,
    expose_value: bool = True,
    is_eager: bool = False,
    is_flag: bool = False,
    flag_value: object = None,
    multiple: bool = False,
    count: bool = False,
    allow_from_autoenv: bool = True,
    help: str | None = None,
    hidden: bool = False,
    show_default: bool | str = False,
    prompt: bool | str = False,
    confirmation_prompt: bool | str = False,
    hide_input: bool = False,
    envvar: str | list[str] | None = None,
    shell_complete: Callable[[Context, Parameter, str], list[str]] | None = None,
) -> Callable[[Callable[_P, _R]], Callable[_P, _R]]: ...
def version_option(
    version: str | None = None,
    *param_decls: str,
    package_name: str | None = None,
    prog_name: str | None = None,
    message: str = "%(prog)s, version %(version)s",
    **attrs: object,
) -> Callable[[Callable[_P, _R]], Callable[_P, _R]]: ...
def pass_context(f: Callable[_P, _R]) -> Callable[_P, _R]:
    """Decorator that passes the context as the first argument."""
    ...

def pass_obj(f: Callable[_P, _R]) -> Callable[_P, _R]:
    """Decorator that passes the context object as the first argument."""
    ...

def make_pass_decorator(
    object_type: type[_T],
    ensure: bool = False,
) -> Callable[[Callable[_P, _R]], Callable[_P, _R]]:
    """Create a decorator that passes a context object."""
    ...

# Utility functions
def echo(
    message: object = None,
    file: IO[str] | None = None,
    nl: bool = True,
    err: bool = False,
    color: bool | None = None,
) -> None:
    """Print a message to stdout or stderr."""
    ...

def get_current_context(silent: bool = False) -> Context:
    """Get the current click context."""
    ...

def confirm(
    text: str,
    default: bool = False,
    abort: bool = False,
    prompt_suffix: str = ": ",
    show_default: bool = True,
    err: bool = False,
) -> bool:
    """Prompt for confirmation."""
    ...

def prompt(
    text: str,
    default: object = None,
    hide_input: bool = False,
    confirmation_prompt: bool = False,
    type: object = None,
    value_proc: Callable[[object], object] | None = None,
    prompt_suffix: str = ": ",
    show_default: bool = True,
    err: bool = False,
) -> object:
    """Prompt the user for input."""
    ...

# Exception classes
class ClickException(Exception):
    """Base exception for Click."""

    exit_code: int

    def __init__(self, message: str) -> None: ...
    def format_message(self) -> str: ...
    def show(self, file: IO[str] | None = None) -> None: ...

class UsageError(ClickException):
    """Exception for usage errors."""

    def __init__(self, message: str, ctx: Context | None = None) -> None: ...

class BadParameter(UsageError):
    """Exception for bad parameter values."""

    def __init__(
        self,
        message: str,
        ctx: Context | None = None,
        param: Parameter | None = None,
        param_hint: str | None = None,
    ) -> None: ...

class Abort(RuntimeError):
    """Exception raised by abort()."""

    ...

def abort() -> None:
    """Abort the current CLI execution."""
    ...
