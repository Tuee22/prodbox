"""
Stream state machine for subprocess stdout/stderr serialization.

Enforces at-most-one-stream invariant: only one stream-capable subprocess may
stream to terminal output at a time. Execution can still be concurrent; this
module only serializes presentation.
"""

from __future__ import annotations

import asyncio
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Self


@dataclass(frozen=True)
class StreamHandle:
    """Identity for a stream-capable effect execution."""

    effect_id: str
    command: str
    start_time: float


@dataclass(frozen=True)
class _StreamQueueItem:
    """Pending stream request and wake-up event."""

    handle: StreamHandle
    event: asyncio.Event


@dataclass(frozen=True)
class StreamState:
    """Current stream state (active + FIFO pending queue)."""

    current_stream: StreamHandle | None = None
    pending_count: int = 0


@dataclass
class StreamControl:
    """FIFO stream admission controller."""

    _current_stream: StreamHandle | None = None
    _pending: deque[_StreamQueueItem] = field(default_factory=deque)

    async def acquire_stream(self: Self, handle: StreamHandle) -> None:
        """Acquire active stream slot, waiting if another stream is active."""
        if self._current_stream is None:
            self._current_stream = handle
            return

        event = asyncio.Event()
        self._pending.append(_StreamQueueItem(handle=handle, event=event))
        await event.wait()

    def release_stream(self: Self, handle: StreamHandle) -> None:
        """Release active stream slot and wake the next pending stream."""
        if self._current_stream != handle:
            return
        if self._pending:
            next_item = self._pending.popleft()
            self._current_stream = next_item.handle
            next_item.event.set()
            return
        self._current_stream = None

    def get_state(self: Self) -> StreamState:
        """Expose current stream state for diagnostics/tests."""
        return StreamState(
            current_stream=self._current_stream,
            pending_count=len(self._pending),
        )

    def is_stream_active(self: Self) -> bool:
        """Return True when a stream slot is currently held."""
        return self._current_stream is not None


def create_stream_handle(effect_id: str, command: str) -> StreamHandle:
    """Create stream handle stamped with current wall-clock time."""
    return StreamHandle(effect_id=effect_id, command=command, start_time=time.time())


__all__ = [
    "StreamHandle",
    "StreamState",
    "StreamControl",
    "create_stream_handle",
]
