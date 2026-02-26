"""Complete type stubs for unittest.mock module.

Provides comprehensive type definitions for Mock, AsyncMock, patch, and related utilities.
Designed to satisfy ultra-strict mypy configuration (disallow_any_expr, disallow_any_decorated).
Zero any types - fully type-safe.
"""

from typing import (
    Literal,
    TypeVar,
    Callable,
    overload,
    MutableMapping,
    Mapping,
)
from typing_extensions import ParamSpec

_T = TypeVar("_T")
_P = ParamSpec("_P")
_R = TypeVar("_R")

# Mock call tracking
class _Call:
    """Represents a single call to a mock."""

    args: tuple[object, ...]
    kwargs: dict[str, object]

    def __init__(
        self,
        value: tuple[tuple[object, ...], dict[str, object]] | None = None,
        name: str | None = None,
        parent: object = None,
        two: bool = False,
    ) -> None: ...
    def __eq__(self, other: object) -> bool: ...
    def __ne__(self, other: object) -> bool: ...
    def __repr__(self) -> str: ...
    @overload
    def __getitem__(self, key: Literal[0]) -> tuple[object, ...]: ...
    @overload
    def __getitem__(self, key: Literal[1]) -> dict[str, object]: ...
    @overload
    def __getitem__(self, key: int) -> tuple[object, ...] | dict[str, object]: ...
    @overload
    def __getitem__(self, key: slice) -> tuple[tuple[object, ...] | dict[str, object], ...]: ...
    def __len__(self) -> int: ...

class _CallList(list[_Call]):
    """List of calls to a mock."""

    def __contains__(self, item: object) -> bool: ...

# Base Mock class
class Mock:
    """Mock object for testing."""

    return_value: object
    side_effect: BaseException | object | None
    call_count: int
    called: bool
    call_args: _Call | None
    call_args_list: _CallList
    method_calls: _CallList
    mock_calls: _CallList

    def __init__(
        self,
        spec: object = None,
        side_effect: BaseException | list[object] | object | None = None,
        return_value: object = None,
        wraps: object = None,
        name: str | None = None,
        spec_set: object = None,
        unsafe: bool = False,
        **kwargs: object,
    ) -> None: ...
    def __call__(self, *args: object, **kwargs: object) -> object: ...
    def assert_called(self) -> None: ...
    def assert_called_once(self) -> None: ...
    def assert_called_with(self, *args: object, **kwargs: object) -> None: ...
    def assert_called_once_with(self, *args: object, **kwargs: object) -> None: ...
    def assert_any_call(self, *args: object, **kwargs: object) -> None: ...
    def assert_has_calls(self, calls: list[_Call], any_order: bool = False) -> None: ...
    def assert_not_called(self) -> None: ...
    def reset_mock(self, return_value: bool = False, side_effect: bool = False) -> None: ...
    def configure_mock(self, **kwargs: object) -> None: ...
    __str__: Mock
    __repr__: Mock
    def attach_mock(self, mock: Mock, attribute: str) -> None: ...
    def __getattr__(self, name: str) -> Mock: ...
    def __setattr__(self, name: str, value: object) -> None: ...

class AsyncMock(Mock):
    """Async version of Mock."""

    def __call__(self, *args: object, **kwargs: object) -> object: ...

class MagicMock(Mock):
    """Mock with magic methods pre-configured."""

    ...

class NonCallableMock:
    """A non-callable version of Mock."""

    return_value: object
    side_effect: BaseException | Callable[..., object] | object | None
    call_count: int
    called: bool
    call_args: _Call | None
    call_args_list: _CallList
    method_calls: _CallList
    mock_calls: _CallList

    def __init__(
        self,
        spec: object = None,
        wraps: object = None,
        name: str | None = None,
        spec_set: object = None,
        **kwargs: object,
    ) -> None: ...
    def __getattr__(self, name: str) -> Mock: ...
    def __setattr__(self, name: str, value: object) -> None: ...

class PropertyMock(Mock):
    """Mock for property access."""

    ...

class _Sentinel:
    """Sentinel object for creating unique values."""

    def __repr__(self) -> str: ...

def sentinel() -> _Sentinel: ...

def call(*args: object, **kwargs: object) -> _Call: ...

class _patch:
    """Base class for patch."""

    attribute_name: str | None
    new: object
    spec: object
    create: bool
    has_local: bool
    spec_set: object
    autospec: object
    new_callable: Callable[[], object] | None
    kwargs: dict[str, object]

    def __init__(
        self,
        target: str,
        new: object = None,
        spec: object = None,
        create: bool = False,
        spec_set: object = None,
        autospec: object = None,
        new_callable: Callable[[], object] | None = None,
        **kwargs: object,
    ) -> None: ...
    def __enter__(self) -> Mock: ...
    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_val: BaseException | None,
        exc_tb: object,
    ) -> None: ...
    def __call__(self, func: Callable[_P, _R]) -> Callable[_P, _R]: ...
    def start(self) -> Mock: ...
    def stop(self) -> None: ...

class _patch_dict:
    """Context manager for patching dictionaries."""

    def __init__(
        self,
        in_dict: dict[str, object] | str,
        values: dict[str, object] = ...,
        clear: bool = False,
        **kwargs: object,
    ) -> None: ...
    def __enter__(self) -> dict[str, object]: ...
    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_val: BaseException | None,
        exc_tb: object,
    ) -> None: ...
    def __call__(self, func: Callable[_P, _R]) -> Callable[_P, _R]: ...
    def start(self) -> dict[str, object]: ...
    def stop(self) -> None: ...

class _Patch:
    """Patch class with dict attribute."""

    @staticmethod
    @overload
    def __call__(
        target: str,
        new: object = None,
        spec: object = None,
        create: bool = False,
        spec_set: object = None,
        autospec: object = None,
        new_callable: Callable[[], object] | None = None,
        **kwargs: object,
    ) -> _patch: ...
    @staticmethod
    @overload
    def __call__(
        target: str,
        new: object = None,
        spec: object = None,
        create: bool = False,
        spec_set: object = None,
        autospec: object = None,
        new_callable: Callable[[], object] | None = None,
        **kwargs: object,
    ) -> Callable[[Callable[_P, _R]], Callable[_P, _R]]: ...
    @staticmethod
    def dict(
        in_dict: MutableMapping[str, str] | Mapping[str, object] | str,
        values: Mapping[str, object] = ...,
        clear: bool = False,
        **kwargs: object,
    ) -> _patch_dict: ...
    @staticmethod
    def object(
        target: object,
        attribute: str,
        new: object = None,
        spec: object = None,
        create: bool = False,
        spec_set: object = None,
        autospec: object = None,
        new_callable: Callable[[], object] | None = None,
        **kwargs: object,
    ) -> _patch: ...

patch: _Patch

@overload
def patch(
    target: str,
    new: object = None,
    spec: object = None,
    create: bool = False,
    spec_set: object = None,
    autospec: object = None,
    new_callable: Callable[[], object] | None = None,
    **kwargs: object,
) -> _patch: ...
@overload
def patch(
    target: str,
    new: object = None,
    spec: object = None,
    create: bool = False,
    spec_set: object = None,
    autospec: object = None,
    new_callable: Callable[[], object] | None = None,
    **kwargs: object,
) -> Callable[[Callable[_P, _R]], Callable[_P, _R]]: ...
def patch_object(
    target: object,
    attribute: str,
    new: object = None,
    spec: object = None,
    create: bool = False,
    spec_set: object = None,
    autospec: object = None,
    new_callable: Callable[[], object] | None = None,
    **kwargs: object,
) -> _patch: ...
def patch_dict(
    in_dict: dict[object, object],
    values: dict[object, object] | list[tuple[object, object]] = ...,
    clear: bool = False,
    **kwargs: object,
) -> _patch: ...
def mock_open(
    mock: Mock | None = None,
    read_data: str | None = None,
) -> Mock: ...
def create_autospec(
    spec: object,
    spec_set: bool = False,
    instance: bool = False,
    _parent: object = None,
    _name: str | None = None,
    **kwargs: object,
) -> Mock: ...
def seal(mock: Mock) -> None: ...

DEFAULT: object

class _ANY:
    """Sentinel for matching any value in mock assertions."""

    def __eq__(self, other: object) -> bool: ...
    def __ne__(self, other: object) -> bool: ...
    def __repr__(self) -> str: ...

ANY: _ANY
