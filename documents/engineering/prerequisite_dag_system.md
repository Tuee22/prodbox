# Prerequisite DAG System

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/effect_interpreter.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/unit_testing_policy.md

> **Purpose**: Define the DAG construction and reduction model for prerequisite execution.

## 1. Core Model

The prerequisite DAG system is defined by:

- effect nodes with stable IDs
- explicit dependency edges
- a canonical registry in `src/Prodbox/Prerequisite.hs`
- graph construction in `src/Prodbox/EffectDAG.hs`
- graph execution in `src/Prodbox/EffectInterpreter.hs`

The supported command surface does not construct ad-hoc prerequisite orderings outside this model.

## 2. Prerequisite Result Propagation

Prerequisite failures propagate from the root cause upward.

- a failing prerequisite should emit one actionable error
- dependents should preserve that failure rather than replace it with generic noise
- command runners should stop before deeper runtime work begins

## 3. Reduction and Determinism

For a fixed root set and registry, prerequisite expansion must be deterministic.

- missing prerequisite IDs fail at expansion time rather than being discovered later at execution
- no missing prerequisite IDs
- no cycles
- no duplicate execution of the same satisfied node within one run
- stable transitive closure for the selected roots

`test/unit/Main.hs` is responsible for guarding these invariants.

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
