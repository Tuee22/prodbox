# Streaming Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/effect_interpreter.md, documents/engineering/unit_testing_policy.md

> **Purpose**: Define streaming and terminal-record invariants for supported `prodbox` command
> flows.

## 1. Streaming Contract Statement

Operator-facing progress output is part of the supported command contract.

- phase banners must appear in a stable order
- command output must be line-oriented and readable in a normal terminal
- prerequisite and validation phases must not hide major control-flow transitions

## 2. Invariant

Streaming output should preserve the causal story of what the command is doing.

- emit phase boundaries before the work they describe
- do not collapse multiple major phases into one ambiguous line
- preserve stderr for underlying tool failures when that context is operator-relevant

## 3. Scope and Orthogonality

This doctrine applies to user-facing command output. It does not replace:

- prerequisite doctrine
- DAG construction doctrine
- validation ownership doctrine

## 4. Runtime Expectations

`src/Prodbox/TestRunner.hs` is the most visible implementation of this doctrine.

It emits:

- `Phase 1/2` prerequisite banners
- optional `Phase 1.5/2` runbook banners
- `Phase 1.6/2` or post-test runtime restoration banners when the selected suite requires them
- `Phase 2/2` before Haskell suites or named validation payloads run

## 5. Terminal Record Contract

Terminal records must remain legible and attributable.

- each phase banner is its own stdout line
- user-facing summaries should be emitted before a command exits successfully
- hard failures should preserve the underlying error context where possible

## 6. Intent Ownership

This SSoT co-owns streaming doctrine intention.

- Owned statement: operator-facing phase and validation output is part of the supported command
  contract.
- Linked dependents: `src/Prodbox/TestRunner.hs`, `src/Prodbox/Subprocess.hs`,
  `src/Prodbox/EffectInterpreter.hs`, `test/unit/Main.hs`.

## Cross-References

- [Unit Testing Policy](./unit_testing_policy.md)
- [Effect Interpreter Runtime Contract](./effect_interpreter.md)
