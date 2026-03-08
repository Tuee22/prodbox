# Streaming Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/effect_interpreter.md

> **Purpose**: Define streaming behavior and serialization guarantees for CLI subprocess effects.

---

## 1. Streaming Contract Statement

Streaming is observational only and must follow at-most-one-stream output serialization invariants.

---

## 2. Invariant

The interpreter enforces an at-most-one-stream invariant:

1. Only one stream-capable effect may actively broadcast at a time.
2. Additional stream requests are queued FIFO.
3. Releasing the active stream wakes exactly one queued request.

This behavior is implemented by `StreamControl` and consumed in interpreter subprocess handlers.

---

## 3. Scope and Orthogonality

Stream control is an output-layer concern only. It does not replace DAG prerequisites or resource locking.

- Use DAG prerequisites to constrain execution ordering or exclusivity.
- Use stream control to keep user-visible output coherent.

---

## 4. Runtime Expectations

1. `RunSubprocess(..., stream_stdout=True)` participates in stream control.
2. Non-streaming subprocess effects remain independent of stream queue state.
3. Stream control state is inspectable for deterministic tests.

---

## 5. Intent Ownership

This SSoT owns streaming behavior contract intention.

- Owned statement: Streaming is observational only and must follow at-most-one-stream output serialization invariants.
- Linked dependents: `src/prodbox/cli/stream_control.py`, `src/prodbox/cli/interpreter.py`, `tests/unit/test_stream_control.py`.

---

## Cross-References

- [Effect Interpreter Runtime](./effect_interpreter.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md#53-output-contract-ssot)
