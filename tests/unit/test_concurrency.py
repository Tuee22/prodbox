"""Unit tests for concurrency utilities."""

from __future__ import annotations

import asyncio

import pytest

from prodbox.lib.concurrency import (
    ConcurrencyLimiter,
    first_success,
    gather_with_limit,
    wait_all,
)
from prodbox.lib.exceptions import TimeoutError


class TestConcurrencyLimiter:
    """Tests for ConcurrencyLimiter class."""

    @pytest.mark.asyncio
    async def test_limits_concurrent_tasks(self) -> None:
        """ConcurrencyLimiter should limit concurrent executions."""
        limiter = ConcurrencyLimiter(max_concurrent=2)
        active_count = 0
        max_active = 0

        async def task() -> None:
            nonlocal active_count, max_active
            active_count += 1
            max_active = max(max_active, active_count)
            await asyncio.sleep(0.1)
            active_count -= 1

        # Run 5 tasks with limit of 2
        tasks = [limiter.run(task()) for _ in range(5)]
        await asyncio.gather(*tasks)

        assert max_active == 2


class TestGatherWithLimit:
    """Tests for gather_with_limit function."""

    @pytest.mark.asyncio
    async def test_returns_results_in_order(self) -> None:
        """gather_with_limit should return results in input order."""

        async def task(n: int) -> int:
            await asyncio.sleep(0.01 * (5 - n))  # Reverse sleep times
            return n

        results = await gather_with_limit(
            [task(1), task(2), task(3), task(4), task(5)],
            max_concurrent=2,
        )

        assert results == [1, 2, 3, 4, 5]

    @pytest.mark.asyncio
    async def test_limits_concurrency(self) -> None:
        """gather_with_limit should respect max_concurrent."""
        active_count = 0
        max_active = 0

        async def task() -> int:
            nonlocal active_count, max_active
            active_count += 1
            max_active = max(max_active, active_count)
            await asyncio.sleep(0.05)
            active_count -= 1
            return 1

        await gather_with_limit(
            [task() for _ in range(10)],
            max_concurrent=3,
        )

        assert max_active == 3

    @pytest.mark.asyncio
    async def test_return_exceptions_false_raises(self) -> None:
        """gather_with_limit should raise on exception by default."""

        async def failing_task() -> None:
            raise ValueError("test error")

        with pytest.raises(ValueError):
            await gather_with_limit(
                [failing_task()],
                return_exceptions=False,
            )

    @pytest.mark.asyncio
    async def test_return_exceptions_true_returns_exception(self) -> None:
        """gather_with_limit should return exceptions when return_exceptions=True."""

        async def failing_task() -> int:
            raise ValueError("test error")

        async def success_task() -> int:
            return 42

        results = await gather_with_limit(
            [success_task(), failing_task()],
            return_exceptions=True,
        )

        assert results[0] == 42
        assert isinstance(results[1], ValueError)


class TestFirstSuccess:
    """Tests for first_success function."""

    @pytest.mark.asyncio
    async def test_returns_first_success(self) -> None:
        """first_success should return the first successful result."""

        async def slow_task() -> str:
            await asyncio.sleep(0.5)
            return "slow"

        async def fast_task() -> str:
            await asyncio.sleep(0.01)
            return "fast"

        result = await first_success([slow_task(), fast_task()])

        assert result == "fast"

    @pytest.mark.asyncio
    async def test_cancels_remaining_tasks(self) -> None:
        """first_success should cancel remaining tasks after success."""
        cancelled = []

        async def task(name: str, delay: float) -> str:
            try:
                await asyncio.sleep(delay)
                return name
            except asyncio.CancelledError:
                cancelled.append(name)
                raise

        await first_success(
            [
                task("slow", 1.0),
                task("fast", 0.01),
            ]
        )

        # Give a moment for cancellation to propagate
        await asyncio.sleep(0.05)

        assert "slow" in cancelled

    @pytest.mark.asyncio
    async def test_raises_if_all_fail(self) -> None:
        """first_success should raise if all tasks fail."""

        async def failing_task() -> str:
            raise ValueError("test")

        with pytest.raises(ValueError):
            await first_success([failing_task(), failing_task()])


class TestWaitAll:
    """Tests for wait_all function."""

    @pytest.mark.asyncio
    async def test_returns_all_results(self) -> None:
        """wait_all should return all results in order."""

        async def task(n: int) -> int:
            await asyncio.sleep(0.01)
            return n * 2

        results = await wait_all([task(1), task(2), task(3)])

        assert results == [2, 4, 6]

    @pytest.mark.asyncio
    async def test_raises_on_first_failure(self) -> None:
        """wait_all should raise the first exception encountered."""

        async def success_task() -> int:
            await asyncio.sleep(0.1)
            return 42

        async def failing_task() -> int:
            raise ValueError("test error")

        with pytest.raises(ValueError):
            await wait_all([success_task(), failing_task()])

    @pytest.mark.asyncio
    async def test_timeout_raises_error(self) -> None:
        """wait_all should raise TimeoutError on timeout."""

        async def slow_task() -> int:
            await asyncio.sleep(10)
            return 42

        with pytest.raises(TimeoutError):
            await wait_all([slow_task()], timeout=0.1)
