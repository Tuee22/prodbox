# Effect Interpreter Runtime Contract

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/unit_testing_policy.md
**Generated sections**: none

> **Purpose**: Define the runtime execution contract for the Haskell effect interpreter.

## 1. Runtime Parity Statement

`src/Prodbox/EffectInterpreter.hs` is the supported interpreter boundary for prerequisite DAG
execution in the Haskell repository. It is responsible for executing effect nodes produced by the
native prerequisite registry and for returning structured success or failure to command runners such
as `src/Prodbox/TestRunner.hs`.

## 2. Execution Loop Contract

The interpreter executes effect DAGs in dependency order:

1. resolve the dependency closure for the selected root IDs
2. execute each ready node once
3. stop on the first hard failure
4. return a structured success or error result to the caller

The interpreter is allowed to perform subprocesses, environment reads, and user-facing output. Pure
planning logic is not. Subprocess effects construct `Prodbox.Subprocess.Subprocess` values and
run them through the shared `runStreaming` / `capture` boundary; direct `System.Process` /
`typed-process` construction stays inside `src/Prodbox/Subprocess.hs`.

State-changing one-shot command families follow the same split on their own surface:

1. pure `buildPlan`-style plan construction
2. shared `runPlanWithOptions` handling for `--dry-run` and `--plan-file`
3. effectful apply functions that consume the typed plan payload only after the plan boundary

## 3. Prerequisite Reduction Contract

Prerequisite execution must be deterministic for a fixed registry and selected root set.

- Nodes are keyed by stable IDs.
- Dependency expansion is owned by the DAG layer, not by ad-hoc command logic.
- A satisfied prerequisite should not be re-run within the same DAG execution.

## 3A. Prerequisite Result Propagation Contract

Failures propagate from the root-cause prerequisite upward without inventing duplicate remediation
text at each dependent node.

- The root-cause prerequisite owns the actionable error.
- Dependent nodes may add context, but should not overwrite the root-cause signal.
- Command runners decide how to render interpreter failures to the operator.
- The interpreter preserves the node description and remedy hint owned by the failing prerequisite
  so the CLI boundary can surface one consistent node-id / description / remedy triple.

## 4. Effect Outcome ADT Contract

The interpreter works in terms of explicit result values rather than implicit shell exceptions.

- success carries no additional error payload
- failure carries a human-readable explanation
- callers such as `src/Prodbox/TestRunner.hs` translate those results into CLI exit behavior

## 5. Command Boundary Contract

Command modules do not inline prerequisite traversal.

- `src/Prodbox/TestRunner.hs` builds the phase-one DAG and delegates execution to the interpreter.
- Host, k8s, and related command families share the same effect/runtime doctrine.
- Named validation payloads in `src/Prodbox/TestValidation.hs` run after prerequisite closure, not
  instead of it.

## 6. Intent Ownership

This SSoT co-owns interpreter-boundary execution doctrine.

- Owned statement: `src/Prodbox/EffectInterpreter.hs` is the supported runtime boundary for native
  effect execution.
- Linked dependents: `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/TestRunner.hs`,
  `src/Prodbox/Prerequisite.hs`, `test/unit/Main.hs`.

## Cross-References

- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Prerequisite DAG System](./prerequisite_dag_system.md)
- [Unit Testing Policy](./unit_testing_policy.md)
