"""
Command Executor - Single entry point for command execution.

This module provides the execute_command() function, which is the ONLY
place where EffectInterpreter is created. All commands flow through here.

Separated from main.py to avoid circular imports (main imports commands,
commands import execute_command).

Architecture:
    Command ADT -> execute_command() -> command_to_dag() -> DAG -> Interpreter
"""

from __future__ import annotations

import asyncio
from typing import TYPE_CHECKING

from rich.console import Console

from prodbox.cli.command_adt import Command
from prodbox.cli.dag_builders import command_to_dag
from prodbox.cli.interpreter import create_interpreter
from prodbox.cli.types import Failure, Success

if TYPE_CHECKING:
    from prodbox.cli.effect_dag import EffectDAG
    from prodbox.cli.effects import Effect


def render_error_and_return_exit_code(message: str, *, effect_id: str) -> int:
    """Render an error message to stderr and return exit code 1.

    Args:
        message: Error message to display
        effect_id: Identifier for tracking the error source

    Returns:
        Exit code 1 (failure)
    """
    console = Console(stderr=True)
    console.print(f"[red]✗ Error [{effect_id}]: {message}[/red]")
    return 1


def execute_command(cmd: Command) -> int:
    """Execute a Command ADT and return exit code.

    This is the SINGLE entry point for command execution.
    EffectInterpreter is created here ONLY.

    Args:
        cmd: The Command ADT to execute

    Returns:
        Exit code (0 for success, non-zero for failure)

    Usage:
        from prodbox.cli.command_executor import execute_command
        from prodbox.cli.command_adt import dns_update_command

        match dns_update_command(force=True):
            case Success(cmd):
                sys.exit(execute_command(cmd))
            case Failure(error):
                sys.exit(
                    render_error_and_return_exit_code(
                        error, effect_id="dns_update_validation_failure"
                    )
                )
    """

    async def _run() -> int:
        match command_to_dag(cmd):
            case Success(dag):
                interpreter = create_interpreter()
                dag_summary = await interpreter.interpret_dag(dag)
                return dag_summary.exit_code
            case Failure(error):
                return render_error_and_return_exit_code(
                    f"Error building DAG: {error}",
                    effect_id="command_executor_dag_build_failure",
                )

    return asyncio.run(_run())


def execute_effect(effect: Effect[object]) -> int:
    """Execute a single Effect via the centralized interpreter boundary.

    This keeps interpreter construction in one place while allowing utility
    scripts to reuse the effect system without duplicating interpreter logic.

    Args:
        effect: The Effect to execute

    Returns:
        Exit code (0 for success, non-zero for failure)
    """

    async def _run() -> int:
        interpreter = create_interpreter()
        result = await interpreter.interpret(effect)
        return result.exit_code

    return asyncio.run(_run())


def execute_dag(dag: EffectDAG) -> int:
    """Execute an EffectDAG via the centralized interpreter boundary.

    This keeps interpreter construction in one place while allowing
    pre-built DAGs to be executed without going through command_to_dag.

    Args:
        dag: The EffectDAG to execute

    Returns:
        Exit code (0 for success, non-zero for failure)
    """

    async def _run() -> int:
        interpreter = create_interpreter()
        dag_summary = await interpreter.interpret_dag(dag)
        return dag_summary.exit_code

    return asyncio.run(_run())


# =============================================================================
# Exports
# =============================================================================

__all__ = [
    "execute_command",
    "execute_effect",
    "execute_dag",
    "render_error_and_return_exit_code",
]
