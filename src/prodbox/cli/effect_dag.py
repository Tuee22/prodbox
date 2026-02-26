"""
Effect DAG for prerequisite resolution and execution ordering.

This module defines the core DAG data structures for effects. It is
separate from effects.py to avoid circular imports with prerequisite_registry.py.

Architecture:
    effect_dag.py (this file) - EffectNode, EffectDAG
        |
    effects.py - imports from effect_dag, defines Effect classes
        |
    prerequisite_registry.py - imports from both, defines PREREQUISITE_REGISTRY

Key Concepts:
    - EffectNode wraps an Effect and declares prerequisites by effect_id
    - EffectDAG is an immutable set of nodes with transitive prerequisite expansion
    - PrerequisiteRegistry maps effect_ids to their canonical EffectNode definitions
    - The interpreter executes nodes with maximum concurrency based on dependencies
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import TYPE_CHECKING, Generic, Self, TypeVar

from prodbox.cli.types import PrereqResults

if TYPE_CHECKING:
    from prodbox.cli.effects import Effect

# Covariant type variable for EffectNode (effect is in output position only)
T_node = TypeVar("T_node", covariant=True)
T_reduce = TypeVar("T_reduce")


# =============================================================================
# Reduction Monad for Multi-Caller Prerequisites
# =============================================================================


@dataclass(frozen=True)
class ReductionError:
    """Deterministic reduction failure for multi-caller prerequisites."""

    message: str


@dataclass(frozen=True)
class ReductionMonad(Generic[T_reduce]):
    """
    Pure reduction monad for multi-caller prerequisite inputs.

    When multiple callers depend on the same prerequisite with different
    input values, the reduction monad determines how to combine them.

    Attributes:
        unit: Returns the identity value for the reduction
        bind: Combines two values, returning combined value or ReductionError
        description: Human-readable description of the reduction strategy
    """

    unit: Callable[[], T_reduce]
    bind: Callable[[T_reduce, T_reduce], T_reduce | ReductionError]
    description: str | None = None


@dataclass(frozen=True)
class PrerequisiteValue(Generic[T_reduce]):
    """
    Caller-supplied value for a prerequisite node.

    When a caller depends on a prerequisite, it may supply a value
    that the prerequisite can use. Multiple callers with different
    values are combined using the prerequisite's reduction monad.

    Attributes:
        effect_id: ID of the prerequisite this value is for
        value: The value supplied by the caller
    """

    effect_id: str
    value: T_reduce


def _trivial_unit() -> object:
    """Trivial unit returns None."""
    return None


def _trivial_bind(acc: object, value: object) -> object | ReductionError:
    """Trivial bind ignores all values."""
    _ = value
    return acc


DEFAULT_REDUCTION_MONAD: ReductionMonad[object] = ReductionMonad(
    unit=_trivial_unit,
    bind=_trivial_bind,
    description="Trivial reduction (ignore caller values)",
)


# =============================================================================
# EffectNode - DAG Node with Prerequisites
# =============================================================================


@dataclass(frozen=True)
class EffectNode(Generic[T_node]):
    """
    A node in the effect DAG with explicit prerequisites.

    EffectNode wraps an Effect and declares its prerequisites by effect_id.
    The DAG builder expands prerequisites transitively and deduplicates them.

    Attributes:
        effect: The Effect to execute
        effect_id: Unique identifier (defaults to effect.effect_id)
        prerequisites: Set of effect_ids that must complete first
        prerequisite_values: Values to pass to prerequisites
        reduction: How to combine values from multiple callers
        effect_builder: Optional function to build effect from reduced value

    Example:
        >>> node = EffectNode(
        ...     effect=RunKubectlCommand(
        ...         effect_id="get_pods",
        ...         description="Get pods",
        ...         args=["get", "pods"]
        ...     ),
        ...     prerequisites=frozenset(["kubeconfig_exists", "cluster_reachable"])
        ... )
    """

    effect: Effect[T_node]
    effect_id: str = ""
    prerequisites: frozenset[str] = frozenset()
    prerequisite_values: tuple[PrerequisiteValue[object], ...] = ()
    reduction: ReductionMonad[object] = DEFAULT_REDUCTION_MONAD
    effect_builder: Callable[[object, PrereqResults], Effect[T_node]] | None = None

    def __post_init__(self: Self) -> None:
        """Validate and normalize effect_id."""
        effect_id = self.effect.effect_id
        if not self.effect_id:
            if not effect_id:
                raise ValueError("EffectNode requires effect_id or effect.effect_id")
            object.__setattr__(self, "effect_id", effect_id)
        else:
            if effect_id and effect_id != self.effect_id:
                raise ValueError(
                    f"EffectNode effect_id '{self.effect_id}' does not match "
                    f"effect.effect_id '{effect_id}'"
                )

    def build_effect(
        self: Self, reduced_value: object, prereq_results: PrereqResults
    ) -> Effect[T_node]:
        """
        Return effect for execution, optionally using reduced prerequisite value.

        If effect_builder is set, uses it to construct a new Effect.
        Otherwise returns the original effect unchanged.

        Args:
            reduced_value: Combined value from all callers of this node
            prereq_results: Results from all completed prerequisites

        Returns:
            Effect to execute
        """
        if self.effect_builder is None:
            return self.effect
        return self.effect_builder(reduced_value, prereq_results)

    def __hash__(self: Self) -> int:
        """Hash based on effect_id for set operations."""
        return hash(self.effect_id)

    def __eq__(self: Self, other: object) -> bool:
        """Equality based on effect_id."""
        if not isinstance(other, EffectNode):
            return NotImplemented
        return self.effect_id == other.effect_id


# Type alias for prerequisite registries
PrerequisiteRegistry = dict[str, EffectNode[object]]


# =============================================================================
# EffectDAG - Immutable DAG of Effects
# =============================================================================


@dataclass(frozen=True)
class EffectDAG:
    """
    Immutable DAG of effects with prerequisite relationships.

    Built from root nodes by expanding all prerequisites transitively.
    Uses frozenset for immutability and automatic deduplication.

    The interpreter executes the DAG with maximum concurrency - any node
    whose prerequisites are completed runs immediately via asyncio.gather().

    Attributes:
        nodes: Immutable set of all effect nodes (roots + expanded prerequisites)
        roots: Effect IDs for command roots (used for exit code rollup)

    Example:
        >>> # Build DAG from root - prerequisites auto-expand
        >>> dag = EffectDAG.from_roots(
        ...     dns_update_node,
        ...     registry=PREREQUISITE_REGISTRY
        ... )
        >>> # Result includes: aws_credentials_valid, route53_accessible, dns_update
    """

    nodes: frozenset[EffectNode[object]]
    roots: frozenset[str] = frozenset()

    def __post_init__(self: Self) -> None:
        """Validate DAG structure and set default roots."""
        if not self.roots:
            root_ids = frozenset(node.effect_id for node in self.nodes)
            object.__setattr__(self, "roots", root_ids)

        # Validate all roots exist in nodes
        node_ids = {n.effect_id for n in self.nodes}
        invalid = {root_id for root_id in self.roots if root_id not in node_ids}
        if invalid:
            raise ValueError(f"EffectDAG roots missing from nodes: {sorted(invalid)}")

    @staticmethod
    def from_roots(
        *roots: EffectNode[object],
        registry: PrerequisiteRegistry,
    ) -> EffectDAG:
        """
        Build DAG by expanding all prerequisites transitively.

        Algorithm:
        1. Start with root nodes
        2. For each node, recursively expand prerequisites from registry
        3. Use set for automatic deduplication
        4. Return immutable EffectDAG

        Args:
            *roots: Root effect nodes to build DAG from
            registry: Prerequisite registry mapping effect_ids to EffectNodes

        Returns:
            EffectDAG with all nodes (roots + transitive prerequisites)

        Raises:
            KeyError: If a prerequisite effect_id is not in the registry
            ValueError: If duplicate effect_ids are detected
        """
        visited: set[str] = set()
        nodes: set[EffectNode[object]] = set()
        node_by_id: dict[str, EffectNode[object]] = {}

        def validate_prerequisite_values(node: EffectNode[object]) -> None:
            """Ensure prerequisite_values only reference actual prerequisites."""
            if not node.prerequisite_values:
                return
            prereq_ids = node.prerequisites
            value_ids = [value.effect_id for value in node.prerequisite_values]

            # Check for values referencing non-prerequisites
            invalid = {vid for vid in value_ids if vid not in prereq_ids}
            if invalid:
                msg = (
                    f"EffectNode '{node.effect_id}' defines values for "
                    f"non-prerequisites: {sorted(invalid)}"
                )
                raise ValueError(msg)

            # Check for duplicate values
            if len(set(value_ids)) != len(value_ids):
                msg = f"EffectNode '{node.effect_id}' defines duplicate prerequisite values"
                raise ValueError(msg)

        def expand(node: EffectNode[object]) -> None:
            """Recursively expand node and its prerequisites."""
            # Check for duplicate effect_ids
            registry_node = registry.get(node.effect_id)
            if registry_node is not None and registry_node is not node:
                raise ValueError(f"Duplicate effect_id detected: '{node.effect_id}'")

            existing = node_by_id.get(node.effect_id)
            if existing is not None and existing is not node:
                raise ValueError(f"Duplicate effect_id detected: '{node.effect_id}'")

            node_by_id.setdefault(node.effect_id, node)

            # Skip if already visited
            if node.effect_id in visited:
                return
            visited.add(node.effect_id)

            validate_prerequisite_values(node)

            # Recursively expand prerequisites first (depth-first)
            for prereq_id in node.prerequisites:
                if prereq_id not in registry:
                    raise KeyError(
                        f"Prerequisite '{prereq_id}' not found in registry "
                        f"(required by '{node.effect_id}')"
                    )
                prereq_node = registry[prereq_id]
                expand(prereq_node)

            nodes.add(node)

        # Expand all root nodes
        for root in roots:
            expand(root)

        root_ids = frozenset(root.effect_id for root in roots)
        return EffectDAG(nodes=frozenset(nodes), roots=root_ids)

    def get_node(self: Self, effect_id: str) -> EffectNode[object] | None:
        """
        Get node by effect_id, or None if not found.

        Args:
            effect_id: The effect_id to look up

        Returns:
            The EffectNode if found, None otherwise
        """
        for node in self.nodes:
            if node.effect_id == effect_id:
                return node
        return None

    def get_execution_order(self: Self) -> list[set[str]]:
        """
        Get execution order as levels of parallelizable nodes.

        Returns a list of sets, where each set contains effect_ids
        that can execute in parallel. Sets must be executed in order.

        Returns:
            List of sets of effect_ids in topological order
        """
        completed: set[str] = set()
        levels: list[set[str]] = []

        remaining = {node.effect_id for node in self.nodes}

        while remaining:
            # Find all nodes whose prerequisites are satisfied
            ready: set[str] = set()
            for effect_id in remaining:
                node = self.get_node(effect_id)
                if node is None:
                    continue
                if node.prerequisites.issubset(completed):
                    ready.add(effect_id)

            if not ready:
                # Circular dependency detected
                raise ValueError(
                    f"Circular dependency detected. Remaining nodes: {sorted(remaining)}"
                )

            levels.append(ready)
            completed.update(ready)
            remaining -= ready

        return levels

    def __len__(self: Self) -> int:
        """Number of nodes in the DAG."""
        return len(self.nodes)

    def __contains__(self: Self, effect_id: str) -> bool:
        """Check if effect_id is in the DAG."""
        return any(node.effect_id == effect_id for node in self.nodes)


# =============================================================================
# Exports
# =============================================================================

__all__ = [
    # Reduction types
    "ReductionError",
    "ReductionMonad",
    "PrerequisiteValue",
    "DEFAULT_REDUCTION_MONAD",
    # Node types
    "EffectNode",
    "PrerequisiteRegistry",
    # DAG type
    "EffectDAG",
]
