# Effect Interpreter Runtime

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/streaming_doctrine.md

> **Purpose**: Define the runtime execution contract for the prodbox effect interpreter.

---

## 1. Runtime Parity Statement

DAG execution semantics must match BBY parity matrix: pending/ready loop, reduction handling, root-cause/skip outcomes, unexecuted reporting.

This document is the canonical owner of interpreter-runtime semantics.

---

## 2. Execution Loop Contract

Interpreter DAG execution must:

1. Maintain explicit `pending`, `completed`, and `unexecuted` sets.
2. Execute only nodes whose prerequisites are fully completed.
3. Emit deterministic execution order (sorted node IDs for ready groups).
4. Mark remaining `pending` nodes as `unexecuted` if no further progress is possible.

---

## 3. Prerequisite Reduction Contract

For prerequisites with multiple callers:

1. Inputs are collected by prerequisite ID.
2. Inputs are reduced in deterministic caller-ID order.
3. Reduction and effect-builder failures are recorded as root-cause failures.
4. Downstream nodes are marked as prerequisite-skipped, not duplicate root failures.

---

## 4. Effect Outcome ADT Contract

Per-effect outcomes are represented as:

- `EffectSuccess`
- `EffectRootCauseFailure`
- `EffectPrerequisiteSkipped`

`DAGExecutionSummary` must carry outcome maps, skipped counts, unexecuted counts, and a deterministic execution report.

---

## 5. Command Boundary Contract

Interpreter results flow through command execution boundaries that:

1. Render summary output for all commands.
2. Route failure detail reports to stderr only on failure.
3. Preserve root-cause-only failure reporting to avoid repeated downstream noise.

See [Effectful DAG Architecture](./effectful_dag_architecture.md#53-output-contract-ssot).

---

## 6. Intent Ownership

This SSoT owns interpreter-runtime parity intention.

- Owned statement: DAG execution semantics must match BBY parity matrix: pending/ready loop, reduction handling, root-cause/skip outcomes, unexecuted reporting.
- Linked dependents: `src/prodbox/cli/interpreter.py`, `tests/unit/test_interpreter.py`.

---

## Cross-References

- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Streaming Doctrine](./streaming_doctrine.md)
- [Pure FP Standards](./pure_fp_standards.md)
