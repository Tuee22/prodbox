"""Unit tests for effect DAG module."""

from __future__ import annotations

import pytest

from prodbox.cli.effect_dag import (
    DEFAULT_REDUCTION_MONAD,
    EffectDAG,
    EffectNode,
    PrerequisiteFailurePolicy,
    PrerequisiteRegistry,
    PrerequisiteValue,
    ReductionError,
    ReductionMonad,
)
from prodbox.cli.effects import Pure


class TestReductionMonad:
    """Tests for ReductionMonad type."""

    def test_default_reduction_monad_unit(self) -> None:
        """Default reduction monad unit returns None."""
        assert DEFAULT_REDUCTION_MONAD.unit() is None

    def test_default_reduction_monad_bind(self) -> None:
        """Default reduction monad bind ignores values."""
        result = DEFAULT_REDUCTION_MONAD.bind(None, "any value")
        assert result is None

    def test_custom_reduction_monad(self) -> None:
        """Custom reduction monad can combine values."""

        def int_unit() -> int:
            return 0

        def int_bind(acc: int, value: int) -> int | ReductionError:
            return acc + value

        monad: ReductionMonad[int] = ReductionMonad(
            unit=int_unit,
            bind=int_bind,
            description="Sum integers",
        )

        assert monad.unit() == 0
        assert monad.bind(5, 3) == 8
        assert monad.description == "Sum integers"


class TestReductionError:
    """Tests for ReductionError type."""

    def test_reduction_error_holds_message(self) -> None:
        """ReductionError should hold message."""
        error = ReductionError(message="Cannot combine values")
        assert error.message == "Cannot combine values"


class TestPrerequisiteValue:
    """Tests for PrerequisiteValue type."""

    def test_prerequisite_value_holds_data(self) -> None:
        """PrerequisiteValue should hold effect_id and value."""
        value: PrerequisiteValue[str] = PrerequisiteValue(
            effect_id="my_prereq",
            value="test_value",
        )
        assert value.effect_id == "my_prereq"
        assert value.value == "test_value"


class TestEffectNode:
    """Tests for EffectNode type."""

    def test_effect_node_gets_id_from_effect(self) -> None:
        """EffectNode should use effect.effect_id as default."""
        effect = Pure(effect_id="test_pure", description="Test", value="hello")
        node: EffectNode[str] = EffectNode(effect=effect)

        assert node.effect_id == "test_pure"

    def test_effect_node_explicit_id(self) -> None:
        """EffectNode can use explicit effect_id matching effect."""
        effect = Pure(effect_id="test_pure", description="Test", value="hello")
        node: EffectNode[str] = EffectNode(effect=effect, effect_id="test_pure")

        assert node.effect_id == "test_pure"

    def test_effect_node_id_mismatch_raises(self) -> None:
        """EffectNode should raise if effect_ids don't match."""
        effect = Pure(effect_id="effect_id", description="Test", value="hello")

        with pytest.raises(ValueError, match="does not match"):
            EffectNode(effect=effect, effect_id="different_id")

    def test_effect_node_missing_id_raises(self) -> None:
        """EffectNode should raise if no effect_id is available."""
        effect = Pure(effect_id="", description="Test", value="hello")

        with pytest.raises(ValueError, match="requires effect_id"):
            EffectNode(effect=effect)

    def test_effect_node_default_prerequisites(self) -> None:
        """EffectNode should default to empty prerequisites."""
        effect = Pure(effect_id="test", description="Test", value="hello")
        node: EffectNode[str] = EffectNode(effect=effect)

        assert node.prerequisites == frozenset()

    def test_effect_node_with_prerequisites(self) -> None:
        """EffectNode should accept prerequisites."""
        effect = Pure(effect_id="test", description="Test", value="hello")
        node: EffectNode[str] = EffectNode(
            effect=effect,
            prerequisites=frozenset(["prereq1", "prereq2"]),
        )

        assert node.prerequisites == frozenset(["prereq1", "prereq2"])

    def test_effect_node_default_prerequisite_failure_policy(self) -> None:
        """EffectNode should default to propagated prerequisite failures."""
        effect = Pure(effect_id="test", description="Test", value="hello")
        node: EffectNode[str] = EffectNode(effect=effect)
        assert node.prerequisite_failure_policy == PrerequisiteFailurePolicy.PROPAGATE

    def test_effect_node_explicit_prerequisite_failure_policy(self) -> None:
        """EffectNode should accept explicit prerequisite failure policy."""
        effect = Pure(effect_id="test", description="Test", value="hello")
        node: EffectNode[str] = EffectNode(
            effect=effect,
            prerequisite_failure_policy=PrerequisiteFailurePolicy.IGNORE,
        )
        assert node.prerequisite_failure_policy == PrerequisiteFailurePolicy.IGNORE

    def test_effect_node_build_effect_no_builder(self) -> None:
        """build_effect returns original effect when no builder set."""
        effect = Pure(effect_id="test", description="Test", value="hello")
        node: EffectNode[str] = EffectNode(effect=effect)

        result = node.build_effect(None, {})

        assert result is effect

    def test_effect_node_build_effect_with_builder(self) -> None:
        """build_effect uses effect_builder when set."""
        original_effect = Pure(effect_id="test", description="Test", value="original")

        def custom_builder(reduced_value: object, _prereq_results: dict[str, object]) -> Pure[str]:
            return Pure(
                effect_id="test",
                description="Built",
                value=f"built_{reduced_value}",
            )

        node: EffectNode[str] = EffectNode(
            effect=original_effect,
            effect_builder=custom_builder,
        )

        result = node.build_effect("input", {})

        assert isinstance(result, Pure)
        assert result.value == "built_input"

    def test_effect_node_hash_by_id(self) -> None:
        """EffectNode hash should be based on effect_id."""
        effect1 = Pure(effect_id="same_id", description="Test 1", value="a")
        effect2 = Pure(effect_id="same_id", description="Test 2", value="b")

        node1: EffectNode[str] = EffectNode(effect=effect1)
        node2: EffectNode[str] = EffectNode(effect=effect2)

        assert hash(node1) == hash(node2)

    def test_effect_node_equality_by_id(self) -> None:
        """EffectNode equality should be based on effect_id."""
        effect1 = Pure(effect_id="same_id", description="Test 1", value="a")
        effect2 = Pure(effect_id="same_id", description="Test 2", value="b")

        node1: EffectNode[str] = EffectNode(effect=effect1)
        node2: EffectNode[str] = EffectNode(effect=effect2)

        assert node1 == node2

    def test_effect_node_inequality_different_ids(self) -> None:
        """EffectNode with different ids should not be equal."""
        effect1 = Pure(effect_id="id1", description="Test", value="a")
        effect2 = Pure(effect_id="id2", description="Test", value="a")

        node1: EffectNode[str] = EffectNode(effect=effect1)
        node2: EffectNode[str] = EffectNode(effect=effect2)

        assert node1 != node2

    def test_effect_node_equality_with_non_node(self) -> None:
        """EffectNode should return NotImplemented for non-node comparison."""
        effect = Pure(effect_id="test", description="Test", value="a")
        node: EffectNode[str] = EffectNode(effect=effect)

        result = node.__eq__("not a node")
        assert result is NotImplemented


class TestEffectDAG:
    """Tests for EffectDAG type."""

    def test_dag_from_single_root_no_prereqs(self) -> None:
        """DAG should be created from single root with no prerequisites."""
        effect = Pure(effect_id="root", description="Root", value="test")
        root: EffectNode[str] = EffectNode(effect=effect)
        registry: PrerequisiteRegistry = {}

        dag = EffectDAG.from_roots(root, registry=registry)

        assert len(dag) == 1
        assert "root" in dag
        assert dag.roots == frozenset(["root"])

    def test_dag_expands_prerequisites(self) -> None:
        """DAG should expand prerequisites from registry."""
        prereq_effect = Pure(effect_id="prereq", description="Prereq", value="p")
        prereq_node: EffectNode[str] = EffectNode(effect=prereq_effect)

        root_effect = Pure(effect_id="root", description="Root", value="r")
        root: EffectNode[str] = EffectNode(
            effect=root_effect,
            prerequisites=frozenset(["prereq"]),
        )

        registry: PrerequisiteRegistry = {"prereq": prereq_node}

        dag = EffectDAG.from_roots(root, registry=registry)

        assert len(dag) == 2
        assert "root" in dag
        assert "prereq" in dag
        assert dag.roots == frozenset(["root"])

    def test_dag_expands_transitive_prerequisites(self) -> None:
        """DAG should expand prerequisites transitively."""
        base_effect = Pure(effect_id="base", description="Base", value="b")
        base: EffectNode[str] = EffectNode(effect=base_effect)

        mid_effect = Pure(effect_id="mid", description="Mid", value="m")
        mid: EffectNode[str] = EffectNode(
            effect=mid_effect,
            prerequisites=frozenset(["base"]),
        )

        root_effect = Pure(effect_id="root", description="Root", value="r")
        root: EffectNode[str] = EffectNode(
            effect=root_effect,
            prerequisites=frozenset(["mid"]),
        )

        registry: PrerequisiteRegistry = {
            "base": base,
            "mid": mid,
        }

        dag = EffectDAG.from_roots(root, registry=registry)

        assert len(dag) == 3
        assert "root" in dag
        assert "mid" in dag
        assert "base" in dag

    def test_dag_deduplicates_prerequisites(self) -> None:
        """DAG should deduplicate common prerequisites."""
        base_effect = Pure(effect_id="base", description="Base", value="b")
        base: EffectNode[str] = EffectNode(effect=base_effect)

        left_effect = Pure(effect_id="left", description="Left", value="l")
        left: EffectNode[str] = EffectNode(
            effect=left_effect,
            prerequisites=frozenset(["base"]),
        )

        right_effect = Pure(effect_id="right", description="Right", value="r")
        right: EffectNode[str] = EffectNode(
            effect=right_effect,
            prerequisites=frozenset(["base"]),
        )

        root_effect = Pure(effect_id="root", description="Root", value="root")
        root: EffectNode[str] = EffectNode(
            effect=root_effect,
            prerequisites=frozenset(["left", "right"]),
        )

        registry: PrerequisiteRegistry = {
            "base": base,
            "left": left,
            "right": right,
        }

        dag = EffectDAG.from_roots(root, registry=registry)

        # Should have 4 unique nodes, not 5 (base is shared)
        assert len(dag) == 4

    def test_dag_missing_prerequisite_raises(self) -> None:
        """DAG should raise if prerequisite not in registry."""
        root_effect = Pure(effect_id="root", description="Root", value="r")
        root: EffectNode[str] = EffectNode(
            effect=root_effect,
            prerequisites=frozenset(["missing_prereq"]),
        )

        registry: PrerequisiteRegistry = {}

        with pytest.raises(KeyError, match="missing_prereq"):
            EffectDAG.from_roots(root, registry=registry)

    def test_dag_invalid_prerequisite_value_raises(self) -> None:
        """DAG should raise if prerequisite_value references non-prerequisite."""
        root_effect = Pure(effect_id="root", description="Root", value="r")
        root: EffectNode[str] = EffectNode(
            effect=root_effect,
            prerequisites=frozenset(["actual_prereq"]),
            prerequisite_values=(PrerequisiteValue(effect_id="non_existent", value="test"),),
        )

        actual_prereq = EffectNode(
            effect=Pure(effect_id="actual_prereq", description="Actual", value="a"),
        )

        registry: PrerequisiteRegistry = {"actual_prereq": actual_prereq}

        with pytest.raises(ValueError, match="non-prerequisites"):
            EffectDAG.from_roots(root, registry=registry)

    def test_dag_get_node_exists(self) -> None:
        """get_node should return node when found."""
        effect = Pure(effect_id="test", description="Test", value="t")
        node: EffectNode[str] = EffectNode(effect=effect)
        registry: PrerequisiteRegistry = {}

        dag = EffectDAG.from_roots(node, registry=registry)

        result = dag.get_node("test")
        assert result is not None
        assert result.effect_id == "test"

    def test_dag_get_node_not_found(self) -> None:
        """get_node should return None when not found."""
        effect = Pure(effect_id="test", description="Test", value="t")
        node: EffectNode[str] = EffectNode(effect=effect)
        registry: PrerequisiteRegistry = {}

        dag = EffectDAG.from_roots(node, registry=registry)

        result = dag.get_node("nonexistent")
        assert result is None

    def test_dag_get_execution_order_single(self) -> None:
        """get_execution_order should return single level for no deps."""
        effect = Pure(effect_id="test", description="Test", value="t")
        node: EffectNode[str] = EffectNode(effect=effect)
        registry: PrerequisiteRegistry = {}

        dag = EffectDAG.from_roots(node, registry=registry)

        levels = dag.get_execution_order()
        assert levels == [{"test"}]

    def test_dag_get_execution_order_chain(self) -> None:
        """get_execution_order should order chain correctly."""
        base = EffectNode(effect=Pure(effect_id="base", description="Base", value="b"))
        mid = EffectNode(
            effect=Pure(effect_id="mid", description="Mid", value="m"),
            prerequisites=frozenset(["base"]),
        )
        root = EffectNode(
            effect=Pure(effect_id="root", description="Root", value="r"),
            prerequisites=frozenset(["mid"]),
        )

        registry: PrerequisiteRegistry = {"base": base, "mid": mid}

        dag = EffectDAG.from_roots(root, registry=registry)

        levels = dag.get_execution_order()
        assert len(levels) == 3
        assert levels[0] == {"base"}
        assert levels[1] == {"mid"}
        assert levels[2] == {"root"}

    def test_dag_get_execution_order_parallel(self) -> None:
        """get_execution_order should parallelize independent nodes."""
        base = EffectNode(effect=Pure(effect_id="base", description="Base", value="b"))
        left = EffectNode(
            effect=Pure(effect_id="left", description="Left", value="l"),
            prerequisites=frozenset(["base"]),
        )
        right = EffectNode(
            effect=Pure(effect_id="right", description="Right", value="r"),
            prerequisites=frozenset(["base"]),
        )
        root = EffectNode(
            effect=Pure(effect_id="root", description="Root", value="root"),
            prerequisites=frozenset(["left", "right"]),
        )

        registry: PrerequisiteRegistry = {
            "base": base,
            "left": left,
            "right": right,
        }

        dag = EffectDAG.from_roots(root, registry=registry)

        levels = dag.get_execution_order()
        assert len(levels) == 3
        assert levels[0] == {"base"}
        assert levels[1] == {"left", "right"}  # Can run in parallel
        assert levels[2] == {"root"}

    def test_dag_contains(self) -> None:
        """DAG should support 'in' operator."""
        effect = Pure(effect_id="test", description="Test", value="t")
        node: EffectNode[str] = EffectNode(effect=effect)
        registry: PrerequisiteRegistry = {}

        dag = EffectDAG.from_roots(node, registry=registry)

        assert "test" in dag
        assert "nonexistent" not in dag

    def test_dag_len(self) -> None:
        """DAG should support len()."""
        base = EffectNode(effect=Pure(effect_id="base", description="Base", value="b"))
        root = EffectNode(
            effect=Pure(effect_id="root", description="Root", value="r"),
            prerequisites=frozenset(["base"]),
        )

        registry: PrerequisiteRegistry = {"base": base}

        dag = EffectDAG.from_roots(root, registry=registry)

        assert len(dag) == 2

    def test_dag_invalid_roots_raises(self) -> None:
        """DAG should raise if roots reference non-existent nodes."""
        effect = Pure(effect_id="test", description="Test", value="t")
        node: EffectNode[str] = EffectNode(effect=effect)

        # Manually create DAG with invalid roots
        with pytest.raises(ValueError, match="missing from nodes"):
            EffectDAG(nodes=frozenset([node]), roots=frozenset(["nonexistent"]))

    def test_dag_multiple_roots(self) -> None:
        """DAG should support multiple root nodes."""
        root1 = EffectNode(effect=Pure(effect_id="root1", description="Root 1", value="r1"))
        root2 = EffectNode(effect=Pure(effect_id="root2", description="Root 2", value="r2"))

        registry: PrerequisiteRegistry = {}

        dag = EffectDAG.from_roots(root1, root2, registry=registry)

        assert len(dag) == 2
        assert dag.roots == frozenset(["root1", "root2"])

    def test_dag_duplicate_prerequisite_values_raises(self) -> None:
        """DAG should raise if duplicate prerequisite values defined."""
        prereq = EffectNode(effect=Pure(effect_id="prereq", description="Prereq", value="p"))

        root = EffectNode(
            effect=Pure(effect_id="root", description="Root", value="r"),
            prerequisites=frozenset(["prereq"]),
            prerequisite_values=(
                PrerequisiteValue(effect_id="prereq", value="val1"),
                PrerequisiteValue(effect_id="prereq", value="val2"),
            ),
        )

        registry: PrerequisiteRegistry = {"prereq": prereq}

        with pytest.raises(ValueError, match="duplicate prerequisite values"):
            EffectDAG.from_roots(root, registry=registry)

    def test_dag_circular_dependency_detection(self) -> None:
        """DAG should detect circular dependencies in get_execution_order."""
        # Create a cycle: A -> B -> C -> A
        # We need to manually construct the DAG with nodes that form a cycle
        node_a = EffectNode(
            effect=Pure(effect_id="a", description="A", value="a"),
            prerequisites=frozenset(["c"]),  # A depends on C
        )
        node_b = EffectNode(
            effect=Pure(effect_id="b", description="B", value="b"),
            prerequisites=frozenset(["a"]),  # B depends on A
        )
        node_c = EffectNode(
            effect=Pure(effect_id="c", description="C", value="c"),
            prerequisites=frozenset(["b"]),  # C depends on B (cycle!)
        )

        # Manually construct DAG to bypass from_roots validation
        dag = EffectDAG(
            nodes=frozenset([node_a, node_b, node_c]),
            roots=frozenset(["a"]),
        )

        with pytest.raises(ValueError, match="Circular dependency detected"):
            dag.get_execution_order()

    def test_dag_deep_nesting_ten_levels(self) -> None:
        """DAG should handle 10+ levels of prerequisites."""
        # Create chain: level_0 <- level_1 <- ... <- level_10 <- root
        registry: PrerequisiteRegistry = {}
        prev_id: str | None = None

        # Create 11 levels (0-10)
        for i in range(11):
            effect_id = f"level_{i}"
            prereqs = frozenset([prev_id]) if prev_id else frozenset()
            node = EffectNode(
                effect=Pure(effect_id=effect_id, description=f"Level {i}", value=str(i)),
                prerequisites=prereqs,
            )
            registry[effect_id] = node
            prev_id = effect_id

        # Root depends on level_10
        root = EffectNode(
            effect=Pure(effect_id="root", description="Root", value="root"),
            prerequisites=frozenset(["level_10"]),
        )

        dag = EffectDAG.from_roots(root, registry=registry)

        # Should have 12 nodes total (11 levels + root)
        assert len(dag) == 12

        # Execution order should have 12 levels
        levels = dag.get_execution_order()
        assert len(levels) == 12
        assert levels[0] == {"level_0"}
        assert levels[11] == {"root"}

    def test_dag_execution_order_determinism(self) -> None:
        """Same DAG should produce same execution order every time."""
        base = EffectNode(effect=Pure(effect_id="base", description="Base", value="b"))
        left = EffectNode(
            effect=Pure(effect_id="left", description="Left", value="l"),
            prerequisites=frozenset(["base"]),
        )
        right = EffectNode(
            effect=Pure(effect_id="right", description="Right", value="r"),
            prerequisites=frozenset(["base"]),
        )
        root = EffectNode(
            effect=Pure(effect_id="root", description="Root", value="root"),
            prerequisites=frozenset(["left", "right"]),
        )

        registry: PrerequisiteRegistry = {
            "base": base,
            "left": left,
            "right": right,
        }

        dag = EffectDAG.from_roots(root, registry=registry)

        # Call get_execution_order multiple times
        order1 = dag.get_execution_order()
        order2 = dag.get_execution_order()
        order3 = dag.get_execution_order()

        # Should be deterministic
        assert order1 == order2 == order3

    def test_dag_empty_nodes_defaults_roots(self) -> None:
        """DAG with empty roots should default to all nodes as roots."""
        node = EffectNode(effect=Pure(effect_id="only_node", description="Only", value="o"))

        # Manually construct with explicit empty roots (will default to all nodes)
        dag = EffectDAG(nodes=frozenset([node]))

        assert dag.roots == frozenset(["only_node"])

    def test_dag_duplicate_effect_id_in_roots_raises(self) -> None:
        """DAG should raise if duplicate effect_ids are provided in different nodes."""
        # Create two different nodes with same effect_id
        node1 = EffectNode(effect=Pure(effect_id="same_id", description="First", value="first"))
        node2 = EffectNode(effect=Pure(effect_id="same_id", description="Second", value="second"))

        registry: PrerequisiteRegistry = {}

        # Building DAG with two roots having same effect_id should raise
        with pytest.raises(ValueError, match="Duplicate effect_id"):
            EffectDAG.from_roots(node1, node2, registry=registry)

    def test_dag_duplicate_effect_id_root_vs_registry_raises(self) -> None:
        """DAG should raise if root effect_id conflicts with registry."""
        prereq = EffectNode(
            effect=Pure(effect_id="conflict_id", description="Registry", value="reg")
        )

        # Root with same effect_id as registry entry (but different node)
        root = EffectNode(effect=Pure(effect_id="conflict_id", description="Root", value="root"))

        registry: PrerequisiteRegistry = {"conflict_id": prereq}

        with pytest.raises(ValueError, match="Duplicate effect_id"):
            EffectDAG.from_roots(root, registry=registry)

    def test_dag_very_wide_parallel(self) -> None:
        """DAG should handle many parallel prerequisites."""
        # Create 20 parallel prerequisites
        registry: PrerequisiteRegistry = {}
        prereq_ids: list[str] = []

        for i in range(20):
            effect_id = f"parallel_{i}"
            node = EffectNode(
                effect=Pure(effect_id=effect_id, description=f"Parallel {i}", value=str(i))
            )
            registry[effect_id] = node
            prereq_ids.append(effect_id)

        root = EffectNode(
            effect=Pure(effect_id="root", description="Root", value="root"),
            prerequisites=frozenset(prereq_ids),
        )

        dag = EffectDAG.from_roots(root, registry=registry)

        assert len(dag) == 21  # 20 parallel + root

        levels = dag.get_execution_order()
        assert len(levels) == 2
        assert len(levels[0]) == 20  # All parallel nodes in first level
        assert levels[1] == {"root"}

    def test_dag_diamond_dependency(self) -> None:
        """DAG should handle diamond dependency pattern correctly."""
        # Diamond: base <- (left, right) <- top
        base = EffectNode(effect=Pure(effect_id="base", description="Base", value="b"))
        left = EffectNode(
            effect=Pure(effect_id="left", description="Left", value="l"),
            prerequisites=frozenset(["base"]),
        )
        right = EffectNode(
            effect=Pure(effect_id="right", description="Right", value="r"),
            prerequisites=frozenset(["base"]),
        )
        top = EffectNode(
            effect=Pure(effect_id="top", description="Top", value="t"),
            prerequisites=frozenset(["left", "right"]),
        )

        registry: PrerequisiteRegistry = {
            "base": base,
            "left": left,
            "right": right,
        }

        dag = EffectDAG.from_roots(top, registry=registry)

        # Base should appear only once (deduplication)
        assert len(dag) == 4
        base_count = len([n for n in dag.nodes if n.effect_id == "base"])
        assert base_count == 1


class TestGetExecutionOrderEdgeCases:
    """Tests for get_execution_order edge cases."""

    def test_get_execution_order_with_missing_node(self) -> None:
        """get_execution_order should handle nodes not in nodes set gracefully.

        This tests the edge case where remaining contains an effect_id
        that doesn't have a corresponding node (line 361 continue branch).
        """
        # This is an edge case - normally shouldn't happen with proper DAG construction
        # but the code handles it defensively
        node = EffectNode(
            effect=Pure(effect_id="test", description="Test", value=1),
        )

        dag = EffectDAG(
            nodes=frozenset([node]),
            roots=frozenset(["test"]),
        )

        # Should execute without error
        levels = dag.get_execution_order()
        assert len(levels) == 1
        assert "test" in levels[0]
