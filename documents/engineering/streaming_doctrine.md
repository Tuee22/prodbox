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
- subprocess-driven output should construct commands as structured values in
  `src/Prodbox/Subprocess.hs`, execute them through `runStreaming` or `capture`, and render
  operator-facing command identity through `renderSubprocess` rather than by concatenating
  ad-hoc shell strings at each call site

## 6. Lifecycle Destructive Success-Versus-Failure Rule

`prodbox rke2 delete --yes` is the canonical case of a destructive lifecycle command that wraps a
noisy upstream uninstaller. Its operator-facing output rule splits cleanly along the exit code of
`/usr/local/bin/rke2-uninstall.sh`:

- Success path: `deleteRke2ClusterSubstrate` captures the uninstaller's stdout and stderr through
  the lifecycle-local quiet path (`captureToolOutput`) and emits only the doctrine-owned summary
  lines — `Deleting local RKE2 environment...`, AWS destroy dispositions,
  `Local RKE2 substrate: cleanup complete`, the kubeconfig disposition, and the retained-root
  notice. Benign upstream chatter such as `Cannot find device "cni0"`,
  `semodule: not found`, `Failed to allocate directory watch: Too many open files`, and
  `Cleanup completed successfully` does not reach the operator terminal.
- Failure path: when the uninstaller exits non-zero, `summarizeRke2DeleteFailure` keeps the last
  actionable lines from stdout and stderr (filtered through `isIgnorableRke2DeleteNoiseLine` so
  the benign classes above stay out of the summary) and renders them through the `writeError`
  boundary so the operator sees the failing command identity.

This rule is scoped to `prodbox rke2 delete --yes`. It does not extend to repo-wide stderr
suppression, and other lifecycle commands continue to follow the streaming contract above.

## 7. Intent Ownership

This SSoT co-owns streaming doctrine intention.

- Owned statement: operator-facing phase and validation output is part of the supported command
  contract.
- Linked dependents: `src/Prodbox/TestRunner.hs`, `src/Prodbox/Subprocess.hs`,
  `src/Prodbox/EffectInterpreter.hs`, `test/unit/Main.hs`.

## Cross-References

- [Unit Testing Policy](./unit_testing_policy.md)
- [Effect Interpreter Runtime Contract](./effect_interpreter.md)
