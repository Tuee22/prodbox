"""Async-to-sync bridge utilities for Click commands."""

from __future__ import annotations

import asyncio
import builtins
from collections.abc import Callable, Coroutine
from typing import TypeVar

from prodbox.lib.exceptions import TimeoutError

T = TypeVar("T")


def async_command(fn: Callable[..., Coroutine[object, object, T]]) -> Callable[..., T]:  # type: ignore[explicit-any]  # Callable[...] requires Any for arbitrary args
    """Decorator that bridges async functions to synchronous Click commands.

    Runs the async function in a new event loop, making it callable
    as a regular synchronous function.

    Note: Callable[...] triggers unavoidable Any propagation under
    disallow_any_expr (same stdlib limitation as disallow_any_decorated).

    Args:
        fn: An async function to wrap.

    Returns:
        A synchronous wrapper that runs the async function.
    """

    def wrapper(*args: object, **kwargs: object) -> T:
        return asyncio.run(fn(*args, **kwargs))

    wrapper.__name__ = getattr(fn, "__name__", "async_command")  # type: ignore[misc]  # Callable[...] propagates Any
    wrapper.__doc__ = getattr(fn, "__doc__", None)  # type: ignore[misc]  # Callable[...] propagates Any

    return wrapper


async def run_with_timeout(
    coro: Coroutine[object, object, T],
    *,
    timeout: float,
    message: str = "Operation timed out",
) -> T:
    """Run a coroutine with a timeout.

    Args:
        coro: Coroutine to execute.
        timeout: Maximum execution time in seconds.
        message: Error message if timeout is exceeded.

    Returns:
        The coroutine's result.

    Raises:
        TimeoutError: If the coroutine exceeds the timeout.
    """
    try:
        return await asyncio.wait_for(coro, timeout=timeout)
    except builtins.TimeoutError:
        raise TimeoutError(message) from None
