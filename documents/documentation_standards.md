# Documentation Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Adopted documentation contract; checker migration remains Phase 0 work.

> **Purpose**: Define documentation ownership, target-versus-implementation scope, and evidence discipline for the prodbox refactor.

## Ownership and precedence

The user's instructions define the requested scope. [AGENTS.md](../AGENTS.md) defines agent operating rules. The accepted product architecture is indexed by [engineering/README.md](engineering/README.md). The sole implementation queue is [DEVELOPMENT_PLAN/README.md](../DEVELOPMENT_PLAN/README.md#resume-here), maintained under the [Development Plan Standards](../DEVELOPMENT_PLAN/development_plan_standards.md).

Every decision has one canonical owner. Architecture documents own accepted behavior and its rationale; phase documents own implementation tasks and closure evidence; the removal ledger owns obsolete paths and their remover. References link to those owners instead of copying their status. Short examples may exercise a contract without becoming a second source of truth.

The documentation refactor adopts the target design without claiming the existing executable implements it. Never use target commands as evidence of installed support. The current binary's help, command registry and generated reference establish current availability until their owning implementation phase changes them.

## Document classes and metadata

Every governed Markdown document starts with a title and these fields:

```markdown
# Document Title

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target contract; see the implementation queue for availability.

> **Purpose**: One sentence identifying the document's responsibility.
```

Use `Authoritative source`, `Reference only`, `Generated reference`, or `Deprecated` for status. `Supersedes` names replaced documents or says `N/A`. `Generated sections` lists every actual generated marker key or says `none`. `Applicability` distinguishes accepted target, current implementation reference, historical evidence, and temporary compatibility forwarding. Historical prose cannot establish current behavior or phase completion.

Generated references remain generated. Never hand-edit generated command tables, manpages, completions or goldens to pretend a parser change occurred. A Markdown-only adoption may annotate a generated reference's current-binary scope while leaving its generated body intact; Phase 0 owns migration of its registry/checker expectations.

## Structure and naming

Use `snake_case.md` for new document names. `README.md`, `AGENTS.md`, `CLAUDE.md`, and the user-requested `REFACTOR_PLAN.md` are root/index exceptions. Numbered phase filenames follow the [plan structure](../DEVELOPMENT_PLAN/development_plan_standards.md#canonical-plan-structure). Existing stable names may remain when renaming adds no value.

The canonical structural manifests are Markdown tables: objective dispositions, command dispositions, acceptance cases, mutation cases and removal ownership. Do not add parallel YAML/JSON copies with separately maintained truth. Later tools parse those tables or generate projections from them.

Use relative links; use an actual heading anchor for section links. Keep source paths accurate. A planned source path must be explicitly labelled proposed and must not substantiate current evidence. Derive reverse references with `rg`; do not maintain backlink inventories.

## Stable architecture and operator material

Architecture documents describe responsibilities, invariants, interfaces, failure handling, and deliberate tradeoffs. They do not accumulate dated probe diaries, fractional sprint history, transcript hashes, or competing open-work lists.

Operator guides teach complete workflows and the minimum necessary choices. Every refusal explains the observed cause, any state changed, and one supported remedy. Development phase identifiers, internal proof terminology and protocol plumbing stay out of ordinary runtime output unless they directly help recovery.

Examples state their applicability. Commands labelled target remain target until implemented. Use fenced code blocks with language identifiers. Source examples identify an existing file or say they are illustrative. Do not copy secrets, invent provider results, or present rendered manifests as deployed behavior.

Keep diagrams small and consistent with their owning contract. Mermaid diagrams must render in the intended viewer; prefer ordinary text or tables when they communicate the same facts more clearly.

## Evidence and history

A current claim must resolve to an actual test, source/build identity, observation and retained evidence. A test count, a successful command exit, or a constructed witness alone does not prove external behavior. Link to the phase's acceptance and mutation evidence rather than embedding copies in engineering prose.

Record source, binary/image and non-secret configuration identities as appropriate. Exclude `test-secrets.dhall`, data roots, generated secrets and plaintext secret hashes. Bind secret-dependent work through opaque receipt/generation identifiers rather than revealing values.

Historical evidence keeps its original source and runtime scope. It is regression input, not automatic qualification of a replacement. Needed non-versioned artifacts have an availability manifest and a retention/removal owner. Never delete evidence merely because an old scratch path looks obsolete.

[History navigation](history/README.md) points to superseded material and preserved adoption inputs. Historical material is excluded from active doctrine/status ownership. Do not reactivate old requirements by quoting them without a new accepted decision.

## Adoption and removal workflow

1. Adopt or amend the owning contract and identify affected acceptance cases.
2. Update numerical implementation ownership and the removal ledger.
3. Implement only the authorized scope; a Markdown-only request does not authorize code or infrastructure changes.
4. Run the appropriate structural, real-behavior and mutation checks for the work actually performed.
5. Close a phase only when its full obligations pass.

A replaced document names its canonical successor and removal phase while compatibility references remain. A temporary forwarding file is not a second authoritative ledger. Remove it when the code-side references and checker migrate.

The pre-refactor checker hardcodes old paths and grammar. Documentation adoption intentionally leaves that executable unchanged. Phase 0 must migrate it and its negative/mutation tests before claiming the canonical quality gate passes under these standards. Do not disable checks or claim implementation merely to reconcile documentation with old code.
