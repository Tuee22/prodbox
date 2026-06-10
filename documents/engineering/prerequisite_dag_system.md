# Prerequisite DAG System

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/effect_interpreter.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/unit_testing_policy.md
**Generated sections**: none

> **Purpose**: Define the DAG construction and reduction model for prerequisite execution.

## 1. Core Model

The prerequisite DAG system is defined by:

- `EffectNode` values (`effectNodeId`, `effectNodeDescription`, `effectNodeRemedyHint`,
  `effectNodePrerequisites`, `effectNodeEffect`) keyed by stable IDs
- explicit dependency edges carried in `effectNodePrerequisites`
- a canonical registry `prerequisiteRegistry :: Map String EffectNode` in
  `src/Prodbox/Prerequisite.hs`
- graph construction in `src/Prodbox/EffectDAG.hs` (`fromRootIds`, `transitiveClosureIds`)
- graph execution in `src/Prodbox/EffectInterpreter.hs` (`runEffectDAG`)

Node IDs are presently raw `String`s. The intended target is a typed `PrerequisiteId` ADT so
that root selection and dependency edges are checked by the compiler rather than by string
equality (Sprint 5.6).

The supported command surface does not construct ad-hoc prerequisite orderings outside this model.

## 2. Prerequisite Result Propagation

Prerequisite failures propagate from the root cause upward.

- a failing prerequisite should emit one actionable error
- dependents should preserve that failure rather than replace it with generic noise
- command runners should stop before deeper runtime work begins

## 3. Reduction and Determinism

For a fixed root set and registry, prerequisite expansion must be deterministic.

- missing prerequisite IDs fail at expansion time rather than being discovered later at execution
- no missing prerequisite IDs (`transitiveClosureIds` returns `Left` naming the absent ID)
- no cycles
- no duplicate execution of the same satisfied node within one run
- stable transitive closure for the selected roots (`transitiveClosureIds` sorts its result)

Acyclicity is enforced at construction, not merely test-guarded: `transitiveClosureIds` /
`fromRootIds` return `Left` on a back-edge — a node that (transitively) depends on itself — so a
cyclic registry can never produce an `EffectDAG`. Cycle detection sits in the same `Either String`
expansion path that already rejects missing IDs, and the interpreter memoizes satisfied nodes so no
node executes twice within one run (Sprint 1.31).

`test/unit/Main.hs` retains coverage of these invariants as defense-in-depth, but the construction
path — not the test suite — is the authoritative gate: a back-edge is rejected by
`transitiveClosureIds`/`fromRootIds` before any `EffectDAG` reaches the interpreter.

## 4. Test Command Integration

`src/Prodbox/TestRunner.hs` uses the prerequisite DAG system for Phase `1/2` of the public
`prodbox test` workflow.

- selected named suites determine the root prerequisites
- cluster-backed suites may add a runbook step after the DAG gate
- named validation payloads execute only after the DAG succeeds

## Cross-References

- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Effect Interpreter Runtime Contract](./effect_interpreter.md)
