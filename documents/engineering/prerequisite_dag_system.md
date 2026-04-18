# Prerequisite DAG System

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: README.md, documents/engineering/README.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/unit_testing_policy.md

> **Purpose**: Implementation reference for prerequisite-driven DAG expansion and scheduling in prodbox CLI.
> **📖 Authoritative Reference**: [Effectful DAG Architecture](./effectful_dag_architecture.md) for canonical architecture and output contract statements.

---

## 1. Core Model

prodbox command execution uses prerequisite-declared DAG nodes:

1. `EffectNode` declares prerequisites by `effect_id`.
2. `EffectDAG.from_roots(...)` expands prerequisites transitively from the registry.
3. Interpreter runtime executes ready nodes in deterministic sorted order once prerequisites are completed.

Current mixed baseline:
- Public `prodbox test` suites plus native `prodbox host` and `prodbox k8s` command ownership use
  `src/Prodbox/EffectDAG.hs` plus `src/Prodbox/Prerequisite.hs`.
- The Haskell registry now mirrors the full shared 30-node prerequisite inventory.
- Broader delegated command families still use the retained Python DAG builders and interpreter
  until their phase-owned ports land.

---

## 2. Prerequisite Result Propagation

Current mixed baseline:
- The Phase 1 Haskell runtime propagates prerequisite success or failure deterministically across
  public `test`, `host`, and `k8s` surfaces.
- Retained Python DAG builders and interpreters still carry typed prerequisite payloads such as
  `MachineIdentity`, `HarborRuntime`, `StorageRuntime`, and `MinioRuntime` for later lifecycle,
  storage, and chart command families.

That split preserves Railway semantics while keeping the current command boundary honest: public
Haskell-owned Phase 1 surfaces use prerequisite pass or fail gates today, and later phases still
own the typed downstream consumers that remain on the Python DAG runtime.

---

## 3. Reduction and Determinism

For multi-caller prerequisites:

1. Caller-provided values are collected by prerequisite ID.
2. Reduction runs in deterministic caller-ID order.
3. Reduction/effect-factory errors are surfaced as root-cause failures.

---

## 4. Test Command Integration

`prodbox test` uses prerequisite expansion to realize the phase sequence defined in [Unit Testing Policy](./unit_testing_policy.md#two-phase-test-command-doctrine).

This reference intentionally does not restate phase labels or banner rendering rules. For the operator-facing contract, use [Phase Banner Rendering Contract](./unit_testing_policy.md#phase-banner-rendering-contract).

---

## Cross-References

- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [Effect Interpreter Runtime](./effect_interpreter.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Unit Testing Policy](./unit_testing_policy.md)
