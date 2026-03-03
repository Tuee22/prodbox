"""Shared utility functions for integration tests."""

from __future__ import annotations

import asyncio
import socket
import uuid
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import cast

from prodbox.cli.effect_dag import EffectDAG, EffectNode
from prodbox.cli.effects import CaptureKubectlOutput, ValidateTool
from prodbox.cli.interpreter import create_interpreter
from prodbox.cli.types import Failure, Success


async def wait_for_async(
    check: Callable[[], bool] | Callable[[], Awaitable[bool]],
    timeout_seconds: float = 20.0,
) -> None:
    """Poll an async or sync callable until it returns truthy or timeout."""
    deadline = asyncio.get_event_loop().time() + timeout_seconds
    while True:
        result = check()
        if asyncio.iscoroutine(result):
            ok = bool(await cast(Awaitable[bool], result))
        else:
            ok = bool(result)
        if ok:
            return
        if asyncio.get_event_loop().time() >= deadline:
            raise AssertionError("condition not met before timeout")
        await asyncio.sleep(0.1)


def free_port() -> int:
    """Get a free TCP port on localhost."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        addr = s.getsockname()
        return int(cast(tuple[str, int], addr)[1])


async def run_kubectl_capture_via_dag(
    *args: str,
    kubeconfig: Path,
    namespace: str | None = None,
    timeout: float | None = None,
) -> tuple[int, str, str]:
    """Run kubectl command through effect DAG, returning (returncode, stdout, stderr)."""
    validate_effect_id = f"validate_kubectl_{uuid.uuid4().hex}"
    command_effect_id = f"kubectl_capture_{uuid.uuid4().hex}"

    validate_node = EffectNode(
        effect=ValidateTool(
            effect_id=validate_effect_id,
            description="Validate kubectl is installed",
            tool_name="kubectl",
        )
    )
    command_node = EffectNode(
        effect=CaptureKubectlOutput(
            effect_id=command_effect_id,
            description=f"kubectl {' '.join(args)}",
            args=list(args),
            kubeconfig=kubeconfig,
            namespace=namespace,
            timeout=timeout,
        ),
        prerequisites=frozenset([validate_effect_id]),
    )
    dag = EffectDAG(
        nodes=frozenset([validate_node, command_node]),
        roots=frozenset([command_effect_id]),
    )

    interpreter = create_interpreter()
    _, node_values = await interpreter.interpret_dag_with_values(dag)

    node_result = node_values.get(command_effect_id)
    if node_result is None:
        return (1, "", "missing kubectl result from DAG")
    match node_result:
        case Success(value):
            if not isinstance(value, tuple) or len(value) != 3:
                return (1, "", "invalid kubectl output tuple")
            returncode, stdout, stderr = value
            if not isinstance(returncode, int):
                return (1, "", "invalid kubectl returncode type")
            if not isinstance(stdout, str):
                return (1, "", "invalid kubectl stdout type")
            if not isinstance(stderr, str):
                return (1, "", "invalid kubectl stderr type")
            return (returncode, stdout, stderr)
        case Failure(error):
            return (1, "", str(error))
