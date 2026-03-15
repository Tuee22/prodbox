# Prerequisite DAG System

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/unit_testing_policy.md

> **Purpose**: Implementation reference for prerequisite-driven DAG expansion and scheduling in prodbox CLI.
> **📖 Authoritative Reference**: [Effectful DAG Architecture](./effectful_dag_architecture.md) for canonical architecture and output contract statements.

---

## 1. Core Model

prodbox command execution uses prerequisite-declared DAG nodes:

1. `EffectNode` declares prerequisites by `effect_id`.
2. `EffectDAG.from_roots(...)` expands prerequisites transitively from the registry.
3. Interpreter runtime executes ready nodes concurrently once prerequisites are completed.

---

## 2. Prerequisite Result Propagation

Prerequisite outcomes propagate as `Result` values to dependent nodes.

- Default node policy is `PrerequisiteFailurePolicy.PROPAGATE`.
- `PROPAGATE` returns a deterministic propagated prerequisite failure.
- `IGNORE` executes the node and allows explicit aggregate/recover behavior in effect builders.

Machine identity is propagated as typed prerequisite data:
- prerequisite `machine_identity` returns `MachineIdentity(machine_id, prodbox_id)`.
- downstream lifecycle nodes must derive prodbox annotation selectors from this value only.

Registry runtime also returns typed effect outputs for downstream consumers:
- `EnsureHarborRegistry` returns `HarborRuntime(registry_endpoint, gateway_image)`.
- `EnsureRetainedLocalStorage` returns `StorageRuntime(storage_class_name, pv, pvc, host_path)`.
- `EnsureMinio` returns `MinioRuntime(namespace, release_name, persistent_volume_claim_name)`.
- gateway integration tests can consume the canonical Harbor image path when explicit overrides are absent.

This preserves Railway semantics while keeping node behavior explicit.

---

## 3. Reduction and Determinism

For multi-caller prerequisites:

1. Caller-provided values are collected by prerequisite ID.
2. Reduction runs in deterministic caller-ID order.
3. Reduction/effect-factory errors are surfaced as root-cause failures.

---

## 4. Two-Phase Test Commands

`prodbox test` composes a two-phase DAG:

1. Phase 1: prerequisite gate (integration scopes only).
2. Phase 2: pytest execution.

Phase 2 does not execute if Phase 1 fails.

---

## Cross-References

- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [Effect Interpreter Runtime](./effect_interpreter.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Unit Testing Policy](./unit_testing_policy.md)
