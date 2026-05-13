# Effectful DAG Architecture

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/effect_interpreter.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/unit_testing_policy.md

> **Purpose**: Describe the Haskell effect DAG architecture used by prerequisite-aware command
> flows.

## 1. Overview

The repository uses an explicit effect DAG model for prerequisite-aware command execution.

- `src/Prodbox/Effect.hs` defines the effect vocabulary.
- `src/Prodbox/EffectDAG.hs` defines the node and graph model.
- `src/Prodbox/Prerequisite.hs` defines the canonical prerequisite registry.
- `src/Prodbox/EffectInterpreter.hs` executes the graph.
- `src/Prodbox/TestRunner.hs` uses this stack for the public `prodbox test` surface.

## 2. Architecture Layers

| Layer | Responsibility | Modules |
|-------|----------------|---------|
| Command selection | Choose the public command and test scope | `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/TestPlan.hs` |
| Pure effect planning | Describe prerequisite nodes and dependencies | `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, `src/Prodbox/Prerequisite.hs` |
| Effect execution | Run side effects and collect structured results | `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Subprocess.hs` |
| Command orchestration | Render banners, runbooks, and named validations | `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs` |

## 3. Effect Types

Effect types are explicit ADTs rather than free-form shell steps.

Typical effect categories include:

- emit a phase banner or informational line
- check for required tools
- validate supported-host properties
- validate settings availability or integrity
- validate cloud or cluster readiness

Effects describe what must happen. They do not encode ad-hoc execution order outside the DAG.

## 4. DAG Construction

DAG construction is data-driven:

1. choose the root prerequisite IDs for a command or test scope
2. resolve transitive prerequisites from the canonical registry
3. build a deterministic graph with no missing nodes and no cycles
4. hand the graph to the interpreter

The canonical registry is the only supported source of truth for prerequisite dependencies.

## 5. Interpreter Pattern

The interpreter is the impurity boundary.

- planning modules produce effect data only
- interpreter modules run subprocesses and I/O
- command runners translate interpreter results into CLI exit behavior

This separation keeps prerequisite logic reviewable and testable.

## 6. Railway-Oriented Programming

The Haskell runtime uses explicit success or failure values to move command execution forward.

- prerequisite planning returns structured success or error values
- interpreter execution returns structured success or error values
- command runners stop on the first failure and preserve the root-cause message

## 7. Testing

Testing splits along the architecture boundary:

- pure helpers and graph behavior are covered in `test/unit/Main.hs`
- built-frontend command behavior is covered in `test/integration/Main.hs` through
  `test/integration/CliSuite.hs` and `test/integration/EnvSuite.hs`
- real infrastructure-backed validations are covered through the named
  `prodbox test integration ...` commands implemented in `src/Prodbox/TestValidation.hs`

## 8. Intent Ownership

This SSoT co-owns the effect DAG architecture doctrine.

- Owned statement: prerequisite-aware command execution is modeled as explicit effect data plus a
  separate interpreter boundary.
- Linked dependents: `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`,
  `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/TestRunner.hs`.

## Cross-References

- [Effect Interpreter Runtime Contract](./effect_interpreter.md)
- [Prerequisite DAG System](./prerequisite_dag_system.md)
- [Pure FP Standards](./pure_fp_standards.md)
- [Unit Testing Policy](./unit_testing_policy.md)
