"""Concurrency utilities for parallel async operations."""

from __future__ import annotations

import asyncio
from collections.abc import Coroutine
from typing import TypeVar

from prodbox.lib.exceptions import TimeoutError

T = TypeVar("T")


class ConcurrencyLimiter:
    """Semaphore-based concurrency limiter for async tasks.

    Attributes:
        _semaphore: Asyncio semaphore controlling concurrent access.
    """

    def __init__(self, max_concurrent: int) -> None:
        self._semaphore = asyncio.Semaphore(max_concurrent)

    async def run(self, coro: Coroutine[object, object, T]) -> T:
        """Run a coroutine with concurrency limiting.

        Args:
            coro: Coroutine to execute under the semaphore.

        Returns:
            The coroutine's result.
        """
        async with self._semaphore:
            return await coro


async def gather_with_limit(
    coros: list[Coroutine[object, object, T]],
    max_concurrent: int = 10,
    *,
    return_exceptions: bool = False,
) -> list[T | BaseException]:
    """Gather coroutines with a concurrency limit, preserving input order.

    Args:
        coros: List of coroutines to execute.
        max_concurrent: Maximum number of concurrent executions.
        return_exceptions: If True, return exceptions as results instead of raising.

    Returns:
        Results in the same order as the input coroutines.
    """
    limiter = ConcurrencyLimiter(max_concurrent)
    tasks: list[asyncio.Task[T]] = [asyncio.create_task(limiter.run(coro)) for coro in coros]

    results: list[T | BaseException] = []
    for task in tasks:
        try:
            result = await task
            results.append(result)
        except BaseException as exc:
            match return_exceptions:
                case True:
                    results.append(exc)
                case False:
                    # Cancel remaining tasks before raising
                    for remaining in tasks:
                        remaining.cancel()
                    raise

    return results


async def first_success(
    coros: list[Coroutine[object, object, T]],
    *,
    timeout: float | None = None,
) -> T:
    """Return the result of the first coroutine to succeed.

    Cancels all remaining coroutines after the first success.

    Args:
        coros: List of coroutines to race.
        timeout: Maximum time to wait for any result.

    Returns:
        The first successful result.

    Raises:
        ValueError: If the coroutine list is empty.
        TimeoutError: If timeout is exceeded before any success.
        Exception: The last exception if all coroutines fail.
    """
    match coros:
        case []:
            raise ValueError("first_success requires a non-empty sequence")
        case _:
            pass

    tasks: set[asyncio.Task[T]] = {asyncio.create_task(coro) for coro in coros}
    last_exception: BaseException | None = None

    try:
        remaining = set(tasks)
        deadline = asyncio.get_event_loop().time() + timeout if timeout is not None else None

        while remaining:
            wait_timeout: float | None = None
            match deadline:
                case None:
                    wait_timeout = None
                case dl:
                    wait_timeout = dl - asyncio.get_event_loop().time()
                    match wait_timeout <= 0:
                        case True:
                            raise TimeoutError("Timeout waiting for first success")
                        case False:
                            pass

            done, remaining = await asyncio.wait(
                remaining,
                timeout=wait_timeout,
                return_when=asyncio.FIRST_COMPLETED,
            )

            match len(done):
                case 0:
                    raise TimeoutError("Timeout waiting for first success")
                case _:
                    pass

            for task in done:
                match task.cancelled():
                    case True:
                        continue
                    case False:
                        pass

                exc = task.exception()
                match exc:
                    case None:
                        return task.result()
                    case _:
                        last_exception = exc

        match last_exception:
            case None:
                raise RuntimeError("No tasks completed")
            case exc:
                raise exc

    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


async def wait_all(
    coros: list[Coroutine[object, object, T]],
    *,
    timeout: float | None = None,
) -> list[T]:
    """Wait for all coroutines to complete, returning results in order.

    Args:
        coros: List of coroutines to execute.
        timeout: Maximum time to wait for all results.

    Returns:
        Results in the same order as the input coroutines.

    Raises:
        TimeoutError: If timeout is exceeded.
        Exception: The first exception encountered.
    """
    tasks: list[asyncio.Task[T]] = [asyncio.create_task(coro) for coro in coros]

    try:
        results: list[T] = []
        done, _ = await asyncio.wait(tasks, timeout=timeout)

        match len(done) == len(tasks):
            case False:
                raise TimeoutError(f"Timed out waiting for {len(tasks) - len(done)} tasks")
            case True:
                pass

        for task in tasks:
            exc = task.exception()
            match exc:
                case None:
                    results.append(task.result())
                case _:
                    raise exc

        return results

    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
