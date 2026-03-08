"""Unit tests for stream output serialization control."""

from __future__ import annotations

import asyncio

import pytest

from prodbox.cli.stream_control import StreamControl, create_stream_handle


@pytest.mark.asyncio
async def test_acquire_and_release_single_stream() -> None:
    """Single stream should acquire immediately and release cleanly."""
    control = StreamControl()
    handle = create_stream_handle("effect_a", "echo a")

    await control.acquire_stream(handle)
    state = control.get_state()
    assert state.current_stream == handle
    assert state.pending_count == 0

    control.release_stream(handle)
    state_after = control.get_state()
    assert state_after.current_stream is None
    assert state_after.pending_count == 0


@pytest.mark.asyncio
async def test_streams_are_admitted_fifo() -> None:
    """Pending streams should be admitted in FIFO order."""
    control = StreamControl()
    first = create_stream_handle("first", "cmd1")
    second = create_stream_handle("second", "cmd2")
    third = create_stream_handle("third", "cmd3")

    await control.acquire_stream(first)
    order: list[str] = []

    async def waiter(label: str, handle_effect: str, command: str) -> None:
        handle = create_stream_handle(handle_effect, command)
        await control.acquire_stream(handle)
        order.append(label)
        control.release_stream(handle)

    t2 = asyncio.create_task(waiter("second", second.effect_id, second.command))
    t3 = asyncio.create_task(waiter("third", third.effect_id, third.command))
    await asyncio.sleep(0.01)
    assert control.get_state().pending_count == 2

    control.release_stream(first)
    await asyncio.gather(t2, t3)

    assert order == ["second", "third"]
    assert control.get_state().current_stream is None


@pytest.mark.asyncio
async def test_release_non_owner_is_noop() -> None:
    """Releasing a non-current handle should not mutate active stream."""
    control = StreamControl()
    owner = create_stream_handle("owner", "cmd")
    other = create_stream_handle("other", "cmd")

    await control.acquire_stream(owner)
    control.release_stream(other)

    state = control.get_state()
    assert state.current_stream == owner
    assert state.pending_count == 0
