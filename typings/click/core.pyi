"""Complete type stubs for click.core module.

Defines core Click classes: Context, Command, Group, Parameter, Option, Argument.
Zero any types - fully type-safe.
"""

from typing import Callable, TypeVar, IO
from typing_extensions import ParamSpec

_P = ParamSpec("_P")
_R = TypeVar("_R")

class Context:
    """The Click context object."""

    parent: Context | None
    command: Command
    obj: object
    params: dict[str, object]
    invoked_subcommand: str | None
    args: list[str]  # Extra arguments when allow_extra_args=True

    def __init__(
        self,
        command: Command,
        parent: Context | None = None,
        info_name: str | None = None,
        obj: object = None,
        **extra: object,
    ) -> None: ...
    def find_object(self, object_type: type[_R]) -> _R | None:
        """Find an object of a given type in the context."""
        ...
    def ensure_object(self, object_type: type[_R]) -> _R:
        """Like find_object but raises if not found."""
        ...
    def exit(self, code: int = 0) -> None:
        """Exit the context with a specific exit code."""
        ...
    def abort(self) -> None:
        """Abort the current execution."""
        ...
    def fail(self, message: str) -> None:
        """Fail the context with a message."""
        ...

class Parameter:
    """Base class for all parameters."""

    name: str
    opts: list[str]
    secondary_opts: list[str]
    type: object
    required: bool
    default: object
    callback: Callable[[Context, Parameter, object], object] | None
    nargs: int
    multiple: bool
    expose_value: bool
    is_eager: bool
    metavar: str | None
    envvar: str | list[str] | None

    def __init__(
        self,
        param_decls: list[str] | None = None,
        type: object = None,
        required: bool = False,
        default: object = None,
        callback: Callable[[Context, Parameter, object], object] | None = None,
        nargs: int | None = None,
        metavar: str | None = None,
        expose_value: bool = True,
        is_eager: bool = False,
        envvar: str | list[str] | None = None,
        **extra: object,
    ) -> None: ...
    def get_default(self, ctx: Context) -> object:
        """Get the default value for this parameter."""
        ...
    def add_to_parser(self, parser: object, ctx: Context) -> None:
        """Add this parameter to the parser."""
        ...

class Option(Parameter):
    """Represents a command line option."""

    is_flag: bool
    flag_value: object
    prompt: bool | str
    confirmation_prompt: bool | str
    hide_input: bool
    is_bool_flag: bool
    count: bool
    allow_from_autoenv: bool
    help: str | None
    hidden: bool
    show_default: bool | str

    def __init__(
        self,
        param_decls: list[str] | None = None,
        show_default: bool | str = False,
        prompt: bool | str = False,
        confirmation_prompt: bool | str = False,
        hide_input: bool = False,
        is_flag: bool = False,
        flag_value: object = None,
        multiple: bool = False,
        count: bool = False,
        allow_from_autoenv: bool = True,
        type: object = None,
        help: str | None = None,
        hidden: bool = False,
        **attrs: object,
    ) -> None: ...

class Argument(Parameter):
    """Represents a positional argument."""

    def __init__(
        self,
        param_decls: list[str] | None = None,
        required: bool | None = None,
        **attrs: object,
    ) -> None: ...

class Command:
    """Represents a command to be executed."""

    name: str | None
    callback: Callable[[Context], object] | None
    params: list[Parameter]
    help: str | None
    epilog: str | None
    short_help: str | None
    add_help_option: bool
    hidden: bool
    deprecated: bool

    def __init__(
        self,
        name: str | None = None,
        callback: Callable[[Context], object] | None = None,
        params: list[Parameter] | None = None,
        help: str | None = None,
        epilog: str | None = None,
        short_help: str | None = None,
        add_help_option: bool = True,
        hidden: bool = False,
        deprecated: bool = False,
        **attrs: object,
    ) -> None: ...
    def __call__(self, *args: object, **kwargs: object) -> object:
        """Invoke the command."""
        ...
    def main(
        self,
        args: list[str] | None = None,
        prog_name: str | None = None,
        complete_var: str | None = None,
        standalone_mode: bool = True,
        **extra: object,
    ) -> object:
        """Main entry point for the command."""
        ...
    def invoke(self, ctx: Context) -> object:
        """Invoke the command with the given context."""
        ...
    def make_context(
        self,
        info_name: str | None,
        args: list[str],
        parent: Context | None = None,
        **extra: object,
    ) -> Context:
        """Create a context for this command."""
        ...

class Group(Command):
    """A command that can have subcommands."""

    commands: dict[str, Command]
    invoke_without_command: bool
    no_args_is_help: bool
    subcommand_metavar: str | None
    chain: bool
    result_callback: Callable[[Context, object], object] | None

    def __init__(
        self,
        name: str | None = None,
        commands: dict[str, Command] | None = None,
        invoke_without_command: bool = False,
        no_args_is_help: bool = False,
        subcommand_metavar: str | None = None,
        chain: bool = False,
        result_callback: Callable[[Context, object], object] | None = None,
        **attrs: object,
    ) -> None: ...
    def command(
        self,
        name: str | None = None,
        cls: type[Command] | None = None,
        **attrs: object,
    ) -> Callable[[Callable[_P, _R]], Command]:
        """Decorator to add a command to this group."""
        ...
    def group(
        self,
        name: str | None = None,
        cls: type[Group] | None = None,
        **attrs: object,
    ) -> Callable[[Callable[_P, _R]], Group]:
        """Decorator to add a subgroup to this group."""
        ...
    def add_command(self, cmd: Command, name: str | None = None) -> None:
        """Add a command to this group."""
        ...
    def get_command(self, ctx: Context, cmd_name: str) -> Command | None:
        """Get a command by name."""
        ...
    def list_commands(self, ctx: Context) -> list[str]:
        """List all command names."""
        ...
