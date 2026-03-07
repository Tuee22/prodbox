# BBY Alignment Plan

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, CLAUDE.md, AGENTS.md

> **Purpose**: Define a systematic, enforceable roadmap to align prodbox's effectful DAG architecture with the BBY doctrine for features, rules, functional purity, output contracts, streaming, and quality guardrails.

---

## 1. Scope

This plan covers prodbox CLI architecture and enforcement in:

- `src/prodbox/cli/`
- `src/prodbox/lib/lint/`
- `tests/`
- `documents/engineering/`
- `README.md`, `CLAUDE.md`, `AGENTS.md`

### In-Scope Alignment Targets

- Effectful DAG modeling and execution semantics
- Prerequisite doctrine (pure checks vs idempotent lifecycle effects)
- Output contract (summary + routing + failure reporting)
- Stream control object model for subprocess output
- Functional purity boundaries and enforcement guards
- Test doctrine (no skip/xfail, prerequisite gates, timeout policy)
- Check-code policy enforcement as the canonical CI/local entrypoint

### Out of Scope

- Non-CLI application layers
- Pulumi resource redesign unrelated to DAG contracts
- Feature work not required for doctrinal alignment

---

## 2. BBY Baseline Reviewed

### Documentation (BBY)

- `documents/engineering/effectful_dag_architecture.md`
- `documents/engineering/prerequisite_doctrine.md`
- `documents/engineering/prerequisite_dag_system.md`
- `documents/engineering/effect_interpreter.md`
- `documents/engineering/streaming_doctrine.md`
- `documents/engineering/testing.md`
- `documents/engineering/code_quality.md`
- `documents/engineering/purity_enforcement.md`
- `documents/engineering/cli_command_patterns.md`

### Implementation (BBY)

- `tools/cli/command_executor.py`
- `tools/cli/interpreter.py`
- `tools/cli/effect_dag.py`
- `tools/cli/effects.py`
- `tools/cli/types.py`
- `tools/cli/summary.py`
- `tools/cli/stream_control.py`
- `tools/cli/prerequisite_registry.py`
- `tools/cli/dag_builders.py`
- `tools/lint/*.py` (purity/no-statements/timeout/shell/threading/collision guards)

---

## 3. Current prodbox Gap Snapshot

| Domain | BBY Baseline | prodbox Current | Gap |
|---|---|---|---|
| Output contract | Explicit SSoT section with stdout/stderr routing and templates | No dedicated output-contract SSoT; executor returns exit code only | High |
| Command summary rendering | `execute_command` always renders summary | No summary render path for command DAG results | High |
| Summary model | `ExecutionSummary`/`DAGExecutionSummary` + conversion and effect outcomes | Basic summaries exist but no rich outcome ADT and no presentation layer module | Medium |
| Stream control | Explicit `StreamControl` state machine and queue model | No stream-control object; streaming is ad-hoc via subprocess behavior | High |
| Prerequisite reduction | Multi-caller reduction monad used in runtime + registry | Reduction types exist; not fully elevated to doctrinal/runtime parity | Medium |
| Prereq failure semantics | Root-cause vs skipped modeled explicitly to avoid duplicate failure noise | Skips are message-based in interpreter; weaker semantics | Medium |
| Purity enforcement | Dedicated guard suite (purity, no statements, shell/threading/type escape, timeout, command collisions) | Minimal guard suite (entrypoint + no-skip + direct invocation guards) | High |
| Testing doctrine | Two-phase test execution and strict prerequisite gate behavior in docs/code | No two-phase test command architecture; mostly raw pytest passthrough | Medium |
| Output docs topology | Clear SSoT with cross-linked reference docs | Architecture docs are simpler, missing output/streaming interpreter SSoTs | High |
| Lifecycle doctrine | Explicit lifecycle symmetry and cleanup orchestration doctrine | Partial (RKE2 ensure/cleanup exists), not generalized | Medium |

---

## 4. Alignment Workstreams

## WS0: Effect Interpreter Parity

**Objective**: Align `src/prodbox/cli/interpreter.py` and the command-execution boundary with BBY's interpreter runtime contract.

### Tasks

1. Define and freeze an interpreter parity matrix covering:
   - DAG execution loop semantics
   - prerequisite reduction semantics
   - per-effect outcome semantics
   - summary rendering semantics
2. Replace level-only DAG scheduling with BBY-style pending/ready execution:
   - explicit `pending`, `completed`, `unexecuted` state
   - deadlock/unresolvable prerequisite handling in summary
3. Implement runtime prerequisite reduction parity:
   - collect caller inputs by prerequisite ID
   - deterministic reduce ordering by caller ID
   - treat reduction/effect-factory failures as first-class execution failures
4. Promote per-effect outcome ADT parity in prodbox:
   - `EffectSuccess`
   - `EffectRootCauseFailure`
   - `EffectPrerequisiteSkipped`
   - `EffectResult`
5. Upgrade `DAGExecutionSummary` to include:
   - effect-level outcomes keyed by `effect_id`
   - `skipped` and `unexecuted` counts
   - deterministic `execution_report` text
6. Update command boundary parity:
   - `execute_command()` renders summary effects (not silent exit-code return)
   - failure and skip narratives follow root-cause-only doctrine (no duplicate downstream root-cause text)
7. Add regression tests for interpreter parity fixtures:
   - multi-caller reduction scenarios
   - root-cause vs skipped propagation
   - deadlock/unexecuted reporting
   - deterministic report text for the same DAG input

### Enforcement

- Unit tests that validate outcome ADT exhaustiveness and conversion semantics.
- Interpreter fixture tests that compare expected effect outcome maps and reports.
- CLI integration tests asserting non-empty summary output and stable failure routing.

### Done When

- prodbox interpreter runtime behavior is equivalent to BBY for the parity matrix scenarios.
- `rke2 ensure/status/cleanup` flows emit deterministic summaries and correct root-cause propagation.

---

## WS1: Output Contract SSoT + Runtime Rendering

**Objective**: Make CLI output deterministic, structured, and visible for both success and failure.

### Tasks

1. Add `documents/engineering/effectful_dag_architecture.md` section `Output Contract (SSoT)`.
2. Define canonical output structures and templates:
   - `ExecutionSummary`
   - `DAGExecutionSummary`
   - `EnvironmentError`
   - per-effect result model
3. Add `src/prodbox/cli/summary.py` with pure formatters:
   - `format_summary()`
   - `format_summary_json()`
   - `display_summary()` -> `WriteStdout`
4. Update `src/prodbox/cli/command_executor.py`:
   - always render execution summary to stdout
   - route detailed DAG failure report to stderr on failure
5. Replace direct terminal error rendering in executor with effect-based output where feasible.

### Enforcement

- Snapshot-style unit tests for summary formatting and routing.
- CLI integration tests asserting non-empty user-facing output for command success/failure paths.

### Done When

- `prodbox rke2 status` and `prodbox rke2 ensure` provide deterministic summaries.
- Summary output contract documented and tested.

---

## WS2: Stream Control Object Model

**Objective**: Align subprocess streaming with an explicit at-most-one-stream invariant.

### Tasks

1. Add stream ADTs to `src/prodbox/cli/types.py` or dedicated module:
   - `StreamHandle`
   - `StreamQueueItem`
   - `StreamState`
   - immutable queue helper
2. Add `src/prodbox/cli/stream_control.py` with FIFO queue semantics.
3. Integrate `StreamControl` into interpreter `RunSubprocess` paths.
4. Preserve orthogonality:
   - stream control = output serialization
   - resource lock/order = DAG prerequisite design
5. Document doctrine in `documents/engineering/streaming_doctrine.md`.

### Enforcement

- Unit tests for queue ordering and wake-up correctness.
- Concurrency tests validating non-garbled output behavior.

### Done When

- Multiple stream-capable effects can execute concurrently while output remains serialized.
- Streaming behavior follows documented doctrine.

---

## WS3: Prerequisite Doctrine Parity

**Objective**: Bring prerequisite modeling and lifecycle rules to BBY-level rigor.

### Tasks

1. Expand `documents/engineering/prerequisite_doctrine.md` to include:
   - pure checks vs idempotent lifecycle effects decision matrix
   - fix-hint contract
   - zero tolerance for silent/automatic installs in checks
   - lifecycle symmetry doctrine
2. Ensure all long-lived runtime commands have explicit lifecycle pairs and cleanup semantics.
3. Formalize and test static registry doctrine and prerequisite completeness pattern.
4. Harden reduction-monad usage where multi-caller prerequisite values exist.
5. Ensure prerequisite failures are surfaced once, with actionable fixes and no duplicate noise.

### Enforcement

- Unit tests for prerequisite completeness by command type.
- Registry tests for ID uniqueness and effect ID consistency.

### Done When

- Prerequisite documentation is prescriptive and enforced by tests.
- Lifecycle behaviors are explicit and non-ambiguous.

---

## WS4: Functional Purity Guardrails

**Objective**: Enforce interpreter-bound impurity with static policy guards.

### Tasks

1. Add guards modeled after BBY (adapted for prodbox):
   - `purity_guard` (ban side effects in pure builders/helpers)
   - `no_shell_guard`
   - `no_threading_guard`
   - `type_escape_guard`
   - `command_name_collision_guard`
   - `timeout_guard`
2. Evaluate `no_statements_guard` in phased mode:
   - informational rollout first
   - then enforced with explicit allowlist for boundary files
3. Add interpreter-boundary checks (no interpreter construction outside executor boundary except approved paths).
4. Wire all approved guards into `prodbox check-code` with stable ordering.

### Enforcement

- Guard tests using synthetic fixture files.
- `poetry run prodbox check-code` fails on doctrine violations.

### Done When

- Purity and policy rules are mechanically enforced, not convention-only.

---

## WS5: Test Doctrine Alignment

**Objective**: Align test execution behavior and anti-pattern prohibition with BBY doctrine.

### Tasks

1. Keep and extend no-skip/xfail doctrine (already introduced) with additional checks where needed.
2. Add two-phase test doctrine documentation in `documents/engineering/unit_testing_policy.md` (or dedicated testing architecture doc):
   - Phase 1 prerequisites gate
   - Phase 2 test execution
3. Refactor `prodbox test` command toward prerequisite-aware test orchestration where applicable.
4. Ensure integration tests validate CLI behavior at command boundaries for critical flows.
5. Add timeout doctrine checks consistent with test policy.

### Enforcement

- Unit tests for test-command DAG composition.
- Integration tests for prerequisite gate behavior.
- Timeout guard in check-code.

### Done When

- Missing environment prerequisites fail fast before test execution.
- Test command behavior is deterministic and doctrine-compliant.

---

## WS6: Documentation Topology and SSoT Hygiene

**Objective**: Make docs enforceable, non-duplicated, and cross-linked like BBY.

### Tasks

1. Add missing reference docs:
   - `documents/engineering/effect_interpreter.md`
   - `documents/engineering/streaming_doctrine.md`
   - optional `documents/engineering/cli_architecture.md` and/or `prerequisite_dag_system.md`
2. Keep `effectful_dag_architecture.md` as output-contract SSoT and remove duplicate templates from other docs.
3. Add doc lint checks for stale anchors and duplicated SSoT content where practical.
4. Update cross-links in `README.md`, `CLAUDE.md`, `AGENTS.md`, and engineering index.
5. Add a documentation-intent coverage checklist to each affected SSoT that declares which
   doctrine statements it owns and which docs must link to it.

### Enforcement

- Doc lint in check-code.
- Link/anchor validation in CI.

### Done When

- Output and prerequisite doctrine are each represented once as canonical SSoTs.
- Reference docs point to SSoTs without duplicating policy payloads.

---

## 4A. Documentation Intent Matrix

**Objective**: Explicitly encode all alignment intentions in the documentation suite with one
canonical owner per intention.

| Intention | Canonical Doc (SSoT) | Explicit Doctrine Statement Required |
|---|---|---|
| Command output contract | `documents/engineering/effectful_dag_architecture.md` | Every CLI command must emit a deterministic execution summary; exit code alone is insufficient user output. |
| Interpreter runtime parity | `documents/engineering/effect_interpreter.md` | DAG execution semantics must match BBY parity matrix: pending/ready loop, reduction handling, root-cause/skip outcomes, unexecuted reporting. |
| RKE2 lifecycle orchestration | `documents/engineering/prerequisite_doctrine.md` | RKE2 cluster provisioning is idempotently performed via eDAG lifecycle effects, not assumed pre-existing. |
| RKE2 fail-fast prerequisites | `documents/engineering/prerequisite_doctrine.md` | Prerequisite nodes validate existence/readiness and fail fast with actionable fix hints; no silent auto-install in checks. |
| RKE2 teardown safety | `documents/engineering/prerequisite_doctrine.md` | Cleanup must tear down RKE2-managed runtime state without deleting host storage paths used for persistent data. |
| Streaming behavior contract | `documents/engineering/streaming_doctrine.md` | Streaming is observational only and must follow at-most-one-stream output serialization invariants. |
| Test skip policy | `documents/engineering/unit_testing_policy.md` | Skip/xfail is prohibited by default; any allowed exception requires explicit doctrinal criteria and automated enforcement. |
| Purity and guardrails | `documents/engineering/pure_fp_standards.md` + `documents/engineering/code_quality.md` | Side effects are interpreter-boundary only; policy guards in `check-code` are mandatory and blocking. |
| check-code as canonical gate | `README.md` + `AGENTS.md` + `CLAUDE.md` | `poetry run prodbox check-code` is the required single entrypoint for doctrine enforcement locally and in CI. |
| Documentation topology | `documents/documentation_standards.md` + `documents/engineering/README.md` | SSoT ownership, bidirectional links, and non-duplication rules are mandatory for all new doctrinal content. |

### Documentation Deliverables

1. Create `documents/engineering/effect_interpreter.md` as interpreter-runtime SSoT.
2. Create `documents/engineering/streaming_doctrine.md` as streaming SSoT.
3. Create `documents/engineering/code_quality.md` as guardrail/`check-code` SSoT.
4. Update existing SSoTs to include the explicit doctrine statements listed above.
5. Update `documents/engineering/README.md` index and cross-links in `README.md`, `CLAUDE.md`,
   and `AGENTS.md`.

### Done When

- Every row in the matrix is implemented in exactly one canonical SSoT document.
- All non-canonical docs link to canonical sections instead of duplicating doctrine text.
- Documentation lint/link checks pass under `poetry run prodbox check-code`.

---

## 5. Delivery Sequence

## Phase 0: Baseline and Spec Lock

1. Freeze doctrinal decisions for interpreter parity, output contract, stream control, and guard scope.
2. Capture current behavior with baseline tests before refactors.

## Phase 1: Interpreter Core Parity (WS0)

1. Implement DAG runtime parity (`pending/ready`, reduction semantics, outcome ADT).
2. Add interpreter fixture tests for root-cause/skipped/unexecuted behavior.

## Phase 2: Output and Executor (WS1)

1. Implement summary module + command executor routing.
2. Add output contract docs and tests.

## Phase 3: Streaming and Prereq Semantics (WS2 + WS3)

1. Add stream control objects and interpreter integration.
2. Finalize prerequisite doctrine parity and lifecycle symmetry rules.

## Phase 4: Guardrail Expansion (WS4)

1. Add purity/policy guards.
2. Integrate into check-code.

## Phase 5: Test-Command Doctrine + Docs Finalization (WS5 + WS6)

1. Apply two-phase test doctrine where applicable.
2. Finalize docs topology and remove duplication.

## Phase 6: Documentation Intent Closure (Section 4A)

1. Implement every matrix row in canonical docs and add backlinks.
2. Run documentation lint/link validation through `check-code`.

---

## 6. Acceptance Gates

The alignment effort is complete only when all gates pass:

1. **Interpreter Gate**: prodbox interpreter runtime semantics match BBY parity matrix (reduction, outcomes, skipped/unexecuted behavior).
2. **Architecture Gate**: Effect DAG, prerequisite semantics, and executor routing match documented SSoTs.
3. **Output Gate**: All commands emit deterministic summary output; failure details route correctly.
4. **Streaming Gate**: At-most-one-stream invariant holds under concurrent stream-capable effects.
5. **Purity Gate**: New guard suite passes in `check-code`.
6. **Testing Gate**: No skip/xfail policy, prerequisite-gated behavior, and timeout policies are enforced by tests.
7. **Documentation Gate**: SSoT docs are complete, cross-linked, and lint-clean.
8. **Intent Coverage Gate**: Every intention in Section 4A is present in a canonical SSoT with
   no duplicate policy payload across non-canonical docs.

---

## 6A. Validation Sequence

Validation for this plan must run in this exact order:

1. Run `poetry run prodbox check-code`.
2. If and only if `check-code` passes, run the full test suite via `poetry run prodbox test`.

No alignment workstream is considered complete unless both commands pass in sequence.

---

## 7. Immediate Next Actions

1. Implement WS0 interpreter parity first, starting with reduction/outcome runtime and deterministic DAG reporting.
2. Implement WS1 (`summary.py`, executor routing, output contract docs) immediately after WS0 to close the silent-output gap.
3. Implement WS2 (`stream_control.py`) and WS3 prerequisite doctrine parity to match BBY runtime behavior.
4. Expand `check-code` with WS4 guards in incremental mode, then promote to strict enforcement.
5. Complete WS5/WS6 doctrine parity and supporting tests.
6. Close Section 4A matrix rows and verify intent coverage gate before declaring alignment complete.
7. Execute Section 6A validation sequence (`check-code` then full test suite) before final sign-off.
