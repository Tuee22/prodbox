# Development Plan Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [README.md](README.md),
[00-overview.md](00-overview.md), [system-components.md](system-components.md),
[substrates.md](substrates.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md),
[phase-0-planning-documentation.md](phase-0-planning-documentation.md),
[phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md),
[phase-2-gateway-dns.md](phase-2-gateway-dns.md),
[phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md),
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md),
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md),
[phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md),
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md),
[phase-8-email-invite-auth.md](phase-8-email-invite-auth.md),
[../documents/documentation_standards.md](../documents/documentation_standards.md),
[../documents/engineering/aws_integration_environment_doctrine.md](../documents/engineering/aws_integration_environment_doctrine.md),
[../documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md),
[../documents/engineering/integration_fixture_doctrine.md](../documents/engineering/integration_fixture_doctrine.md),
[../documents/engineering/lifecycle_control_plane_architecture.md](../documents/engineering/lifecycle_control_plane_architecture.md),
[../documents/engineering/prerequisite_doctrine.md](../documents/engineering/prerequisite_doctrine.md),
[../documents/engineering/unit_testing_policy.md](../documents/engineering/unit_testing_policy.md),
[the engineering doctrine docs](../documents/engineering/README.md)
**Generated sections**: none

> **Purpose**: Define the maintenance rules for the prodbox development plan so the repository
> keeps one coherent, execution-ordered plan and one explicit ledger of cleanup/removal work.

## Core Principles

### A. Continuous Clean-Room Narrative

The plan must read as one sequential buildout from an empty checkout to the intended repository
end state.

- Every phase assumes the previous phase has already closed.
- The plan should flow from plan ownership to CLI/runtime foundations to gateway and chart
  delivery, then to cleanup, public-host proof, and final rerun.
- A reader unfamiliar with the repository should be able to follow the plan from top to bottom
  without reconstructing hidden dependencies from multiple documents.
- The "previous phase has already closed" relationship is a *build* dependency (later phases
  compose earlier deliverables), **not a validation gate** (Standard N): every phase stays
  independently validatable on its owned surface while later phases are incomplete.
- Reopening a closed phase is permitted only to expand that phase's **own** owned surface — never
  to attach a later phase's dependency to an earlier phase (Standard N). When a phase reopens to
  expand its own surface, the top-level docs say which phase reopened and why.

### B. Detailed, Implementation-Oriented Content

The plan is intentionally specific. It should not collapse into vague milestones or project
management summaries.

- Include concrete deliverables, canonical commands, validation gates, and exact blocked
  prerequisites when they materially clarify closure.
- Examples do not need to be verbatim copies of implementation files, but they must not contradict
  the supported architecture or command surface.
- Command examples must use the canonical binary name `prodbox`.
- Deprecated aliases or legacy operator paths belong only in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### C. Honest Completion Tracking

Status must describe reality, not intent.

| Indicator | Meaning |
|-----------|---------|
| ✅ | Completed and validated |
| 🔄 | Active and partially complete |
| 📋 | Planned and ready to start |
| ⏸️ | Blocked by an unmet **earlier-phase or external** prerequisite (never a later phase, never a pending live-infra proof — Standards N/O) |
| 🧪 Live-proof pending | Code-owned surface `Done` and locally validated; a live-infra proof (live AWS / deployed cluster / unsealed Vault / operator credential) is outstanding. **Non-blocking** (Standard O) |

- `Done` requires passing validation on the code-owned surface, aligned docs, and no remaining
  sprint-owned code work; a pending live-infra proof does not prevent `Done` (track it as
  Live-proof pending — Standard O).
- `Active` requires a `Remaining Work` section.
- `Blocked` requires a `Blocked by` line naming an earlier-or-same-phase sprint or an external
  prerequisite — never a later phase (Standard N) and never a pending live-infra proof (Standard O).
- `Planned` means dependencies are already satisfied; it must not list unmet blockers.
- Status is always scoped to the sprint or phase-owned surface. A later phase may remain `Done`
  when an earlier phase reopens, but the reopened dependency must be called out explicitly in
  `README.md` and `00-overview.md`. An earlier phase stays `Done` and independently validatable
  while later phases are incomplete (Standard N); a later phase's incompleteness never reopens or
  blocks it.
- `Done` is not a synonym for deployment-qualified. Any claim that the current revision is
  deployment-ready, supports a seamless aggregate suite, or has completed an operational cutover
  is governed separately by Standard P.

### D. Declarative Plan Language

Phase documents should describe the intended architecture in present-tense declarative language.

- Say what the repository uses, owns, validates, and removes.
- Do not turn phase docs into migration diaries.
- Cleanup history and compatibility residue belong in the explicit legacy-removal ledger, not as
  the main narrative of a phase.

### E. One Canonical Phase Model

The development plan uses exactly this document structure:

```text
DEVELOPMENT_PLAN/
├── development_plan_standards.md
├── README.md
├── 00-overview.md
├── phase-0-planning-documentation.md
├── phase-1-runtime-cli-aws-foundations.md
├── phase-2-gateway-dns.md
├── phase-3-chart-platform-vscode.md
├── phase-4-lifecycle-canonical-paths.md
├── phase-5-canonical-test-suite.md
├── phase-6-clean-room-handoff.md
├── phase-7-aws-substrate-foundations.md
├── phase-8-email-invite-auth.md
├── legacy-tracking-for-deletion.md
├── substrates.md
└── system-components.md
```

No phase may be skipped. No sprint may exist in two phases. Runtime ownership, gateway/DNS
ownership, chart-delivery ownership, canonical test suite ownership, and substrate
provision/teardown ownership must each live in one place only.

### F. System Component Inventory

[system-components.md](system-components.md) is the authoritative component inventory for:

- infrastructure services and platform components
- CLI and runtime control surfaces
- validation and proof surfaces
- authority boundaries and state locations

When a phase changes the supported architecture, update the inventory in the same change.

### G. Phase Documentation Requirements

Every phase document must contain a `Documentation Requirements` section that lists which governed
documents need creation or update under
[documents/documentation_standards.md](../documents/documentation_standards.md).

Use this format:

```markdown
## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/X.md` - [description]

**Product docs to create/update:**
- None.

**Cross-references to add:**
- Add backlink from Z.md
```

Rules:

- Architecture, operator workflow, validation, and boundary changes require engineering-document
  updates.
- The plan must not claim a sprint is done if the listed docs are stale.
- If the repository has no product-doc ownership for a phase, say `None.` explicitly.

### H. Sprint Status Format

Every sprint should use the same basic structure:

```markdown
## Sprint X.Y: Name [STATUS]

**Status**: Done | Active | Planned | Blocked
**Implementation**: `path/to/file` (required for Done, recommended otherwise)
**Blocked by**: earlier-or-same-phase sprint id(s) or external prerequisite (required for Blocked); never a later phase or higher-numbered sprint (Standard N)
**Live-proof**: pending | proven (optional; the non-blocking live-infra axis — Standard O)
**Deployment qualification**: pending | proven (required when the sprint changes a Standard-P
production-composition surface)
**Independent Validation**: how this sprint/phase is validated on its owned surface with no dependency on a later phase (Standard N)
**Docs to update**: `file.md`, `other.md`

### Objective

### Deliverables

### Validation

### Remaining Work
```

Additional sections such as `Current Validation State`, `Current Blockers`, or `Architecture` are
encouraged when they clarify design or closure.

### I. Explicit Cleanup and Removal Ledger

[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is mandatory and comprehensive.
It is the authoritative list of all known compatibility helpers, deprecated paths, duplicate
surfaces, and stale tooling residue that still need removal.

- If a deprecated or compatibility feature still exists anywhere in the repository, it must appear
  in the ledger.
- Each ledger item must name its location, why it is slated for removal, and the sprint that owns
  the cleanup.
- If the supported replacement is done but the old helper still survives as a migration shim, the
  replacement may stay in `Completed` while the surviving helper remains in `Pending Removal`.
- When the cleanup lands, move the item from `Pending Removal` to `Completed`.
- Phase docs should reference the owning sprint, not duplicate the full cleanup ledger.

### J. Documentation Harmony

The plan and governed documents must agree.

- [README.md](README.md), [00-overview.md](00-overview.md), all phase files, and
  [system-components.md](system-components.md) must use the same phase names, sprint statuses, and
  dependency model.
- Governed docs under `documents/engineering/` must match the current architecture described by
  the plan.
- Root guidance docs such as `README.md`, `AGENTS.md`, and `CLAUDE.md` must point to the canonical
  development-plan entrypoint.

### K. Mermaid Rendering Contract

Mermaid diagrams in `DEVELOPMENT_PLAN/` must follow the repository-safe subset and authoring rules
defined in
[documents/documentation_standards.md](../documents/documentation_standards.md#8-mermaid-diagram-standards).

If a change adds or edits a Mermaid block in this directory, closure requires:

1. Rendering every Mermaid block in `DEVELOPMENT_PLAN/` through a standalone renderer.
2. Failing the change on any render error.
3. Verifying the edited diagram in the repository's target Markdown viewer.
4. Running `prodbox dev check` after the documentation change.

This standards document describes Mermaid rules with prose, inline code, or `markdown` examples
only. Do not add live Mermaid blocks here.

### L. CLI Doctrine Alignment

[the engineering doctrine docs](../documents/engineering/README.md) is the authoritative CLI doctrine. Phase
documents and sprint blocks that schedule adoption work must cite the doctrine sections they
implement by name (for example, `CommandSpec`, `Plan / Apply`, `Long-Running Daemons in the Same
Binary → Lifecycle`, `Lint, Format, and Code-Quality Stack → Forbidden Surfaces`,
`Generated Artifacts → The generated-section registry`).

- Governed engineering docs under `documents/engineering/` referenced from the doctrine's
  `Supersedes` line must defer to the doctrine for the patterns it owns and retain only
  project-specific elaborations such as exact file paths, retained-state roots, or named
  validation flows.
- When the doctrine prescribes a behavior that the implemented worktree does not yet honor, the
  gap is scheduled through a new sprint in the appropriate phase. Closing the gap silently
  without a sprint block is forbidden.
- Doctrine-driven removals — superseded helpers, deprecated command aliases, parallel workflow
  surfaces — flow through [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
  like any other cleanup.
- If a doctrine section changes, the same change updates every governed doc that references it.

### M. Test Suite Substrates

The plan describes one canonical test suite that runs against substrates rather than separate
home-cluster and AWS validation surfaces. The substrate (planner, runner, prerequisite DAG, named
validations) is substrate-agnostic in `src/`; the canonical phase model reflects that.

#### Canonical test suite

The canonical test suite is the named-validation set in `src/Prodbox/TestValidation.hs`, planned
by `src/Prodbox/TestPlan.hs`, orchestrated by `src/Prodbox/TestRunner.hs`, and gated by the
prerequisite DAG in `src/Prodbox/Prerequisite.hs`. The suite is substrate-agnostic; every
validation is a member of this single suite and is described as suite content, not as a
substrate-specific concern.

#### Substrate coverage and independence (no fallback)

The canonical test suite is composed of per-substrate runs against **both** supported
substrates: the home local substrate and the AWS substrate. A canonical-suite proof is
complete only when both per-substrate runs have been exercised against their own real
infrastructure (DNS, TLS via cert-manager, ingress, charts, public-edge proofs). A run that
exercises only one substrate is not a complete canonical-suite proof; the missing substrate
stays suite-incomplete until its run lands.

Each per-substrate run is independent. It targets exactly one substrate, consumes only that
substrate's operator-supplied config and provisioned infrastructure, and fails fast if any of
its required substrate config (FQDN, hosted zone, kubeconfig, credentials, prerequisites) is
missing. There is no silent substitution of home-substrate values for missing AWS-substrate
config, and no silent substitution of AWS values for missing home config. The substrate-aware
helpers (`substratePublicFqdn`, `substrateHostedZoneId` in `src/Prodbox/PublicEdge.hs`,
alongside `Prodbox.Infra.AwsEksTestStack.withEksKubeconfig` for substrate-aware kubeconfig
materialization), the prerequisite DAG, and the lifecycle gates all enforce this
contract.

"Substrate-agnostic suite content" means validation logic does not branch on substrate
identity. It does **not** mean substrates share defaults, and it does **not** reduce the
suite to a single substrate's coverage. The aggregate command surface (`prodbox test all`) is
the canonical entrypoint for exercising both substrates; running it on a single substrate
covers only that substrate's row in the parity table in [substrates.md](substrates.md).

#### Substrates

A substrate is an environment that, for the lifetime of a suite run, stands up the same set of
DNS records, TLS certificates (real ZeroSSL via cert-manager), ingress (Envoy Gateway plus
MetalLB or the substrate-equivalent), services, and workload charts; provides the prerequisites
declared in `src/Prodbox/Prerequisite.hs`; and is torn down on suite exit.

The authoritative substrate inventory is [substrates.md](substrates.md). Today's substrates are:

| Substrate | Inventory | Suite-parity authority |
|-----------|-----------|------------------------|
| Home local | Local RKE2 on the operator host | Current status is tracked only in [README.md → Substrate Parity](README.md#substrate-parity) and the per-validation table in [substrates.md](substrates.md). |
| AWS | Disposable Pulumi stacks `aws-eks`, `aws-eks-subzone`, and `aws-test` | Current status is tracked only in [README.md → Substrate Parity](README.md#substrate-parity) and the per-validation table in [substrates.md](substrates.md). |

#### Substrate lifecycle

The lifecycle for every substrate is provision → run canonical suite → teardown. Provision and
teardown belong to the substrate. Suite content does not.

#### Vocabulary

`substrate` is the canonical term. The plan must not introduce `target`, `environment`, or
`tier` as synonyms for substrate. The existing `fixture` term in
[../documents/engineering/integration_fixture_doctrine.md](../documents/engineering/integration_fixture_doctrine.md)
remains scoped to its existing meaning — fake-tool boundary fixtures and ephemeral resource
ownership rules — and is cross-referenced from the substrate doctrine, not merged into it.

#### Phase ownership rules

A phase may own (a) canonical test suite content, (b) a substrate's provision and teardown, or
(c) a substrate's foundations (such as AWS IAM and quota for the AWS substrate, or shared SES
infrastructure for the email-invite auth path). A phase may not own a substrate-specific
validation, because validations are suite content.

#### Suite-content closure is home-substrate-scoped

A suite-content sprint is `Done` when its validation exists and passes on the home local
substrate; AWS-substrate coverage of that same validation is tracked only in the
[substrates.md](substrates.md) parity table and never marks the suite-content sprint or its phase
`Blocked` (Standards N/O).

### N. Phase Independence (No Backward Blocking)

A phase's validation never depends on another phase being complete. Forward build-order (Standard A — later phases compose earlier deliverables) remains the narrative spine, but it is **not a validation gate**.

- **Independent validation.** Each phase is validatable on its owned surface even when any other phase is incomplete. Where a validation would touch a dependency owned by another phase, it is exercised against the home/local substrate, a fake, or a stub. Every phase document must carry an **Independent Validation** line stating how the phase is validated on its owned surface with no dependency on a later phase.
- **Forward-only blocking.** A `**Blocked by**` entry may name only an **earlier-or-same-phase** sprint or an **external** prerequisite. It must **never** name a later phase or a higher-numbered sprint. A backward `Blocked by` is a structural defect: re-scope the sprint so its owned surface is validatable now, and track any genuinely-later-dependent extension separately (Standard O / the [substrates.md](substrates.md) parity table) — do not record the backward block.
- **No backward reopen.** An incomplete later phase never reopens or blocks an earlier phase. Reopening a closed phase (Standard A) is permitted only to expand that phase's **own** owned surface.

### O. Code-Local Completion vs. Live-Infra Proof

A sprint has two independent completion axes; keep them distinct.

- **Code-owned surface.** A sprint is `✅ Done` on its code-owned surface once it builds and passes local validation (`prodbox dev check`, `prodbox test unit`, `prodbox test integration cli` / `env`). This axis determines phase closure.
- **Live-infra proof.** A proof that requires live infrastructure (live AWS spend, a deployed cluster, an unsealed Vault, an operator-supplied credential) is tracked as a distinct, **non-blocking** `Live-proof: pending` note on the sprint. A pending live-infra proof is **not** `⏸️ Blocked` and never gates an earlier phase or the sprint's code-owned closure.
- **`⏸️ Blocked` is reserved** strictly for a genuine unmet **earlier-phase or external** prerequisite — never for a pending live-infra proof, and never pointing at a later phase.

Standard O is deliberately narrow. It permits optional environmental evidence to remain pending;
it does not authorize a deployment-qualified claim, an operational cutover, or removal of the old
path when the missing proof could falsify process topology, capability binding, deadline algebra,
resource sufficiency, persistence safety, lifecycle recovery, or cleanup behavior. Those claims are
governed by Standard P.

### P. Deployment Qualification and Counterexample Closure

Deployment qualification is a separate, revision-specific axis over the composed running system.
It prevents locally green planners, fake interpreters, or isolated unit tests from being promoted
into an unexercised claim about the aggregate deployment.

- **Qualification states.** The only states are `pending` and `proven`. `pending` does not mark a
  phase `Blocked`, preserving Standards N/O, but the repository must not describe the current
  revision as deployment-ready, seamless, fully closed, or operationally cut over.
- **Surfaces that invalidate qualification.** A change to process topology, capability wiring,
  absolute-deadline composition, queueing/admission, resource envelopes, persistence protocol,
  lifecycle orchestration, destructive cleanup, or substrate routing invalidates prior
  qualification.
- **Required evidence.** `proven` records two complete identities: the frozen superseded identity
  and the replacement identity. Each independently binds a `SourceIdentity` (Git HEAD, clean/dirty
  flag, source-manifest policy identity, and deterministic source-manifest digest), secret-safe
  generated-config identity, component-image, resolved topology/wiring, resource-envelope, and
  authored-load digests. The record also names substrate, canonical commands, the normalized
  old→new envelope mapping, production resource envelopes/load, counterexample results, complete
  fault matrix, aggregate result, cleanup/residue result, start/completion timestamps, and evidence
  digest. Historical runs remain evidence only for the complete identity they exercised.
- **Source and evidence secrecy.** The source-manifest policy is an allowlist over repository code,
  governed documentation, and non-secret schema/template inputs. Each frozen and replacement
  `SourceIdentity` separately records the policy identifier, policy version, and digest of the
  canonical policy as well as the resulting manifest digest. The manifest unconditionally excludes
  `test-secrets.dhall`, all local or generated secret material, every configured secret root, and
  every runtime or build root; relevant untracked files participate only when the allowlist admits
  them. A generated-config identity digests only its canonical non-secret projection. Neither that
  digest, the source manifest, nor the enclosing evidence digest may ingest or hash plaintext secret
  bytes. A secret-dependent run is bound only by opaque Lifecycle Authority receipt/generation IDs
  or by a keyed HMAC commitment produced under a Vault-held key; a public raw hash of secret
  material is forbidden. A Git commit hash alone never identifies a dirty worktree.
- **Counterexample rule.** Work opened by a live counterexample includes a stable named,
  repository-owned reproducer. Its causal profile holds the background load, fault schedule, and
  topology-normalized total CPU/memory/ephemeral/persistence budget constant; a split topology may
  repartition but not increase that total. The artifact records the exact old→new envelope mapping,
  expected failure against the frozen superseded implementation, and replacement pass. A separate
  production profile then exercises the independently justified rendered envelopes. Both results
  remain auditable after legacy code deletion; without them the replacement cannot be called
  qualified.
- **Cutover rule.** Operational legacy rows remain in `Pending Removal` until the replacement is the
  sole supported writer/route, rollback is explicit, and current-revision deployment qualification
  passes. A shadow reader may coexist during migration; dual writers may not.
- **Interim escape-path guard.** While operational legacy rows remain in `Pending Removal`, every
  legacy escape call site — gateway-hosted authority routes, the shared operational AWS credential,
  host-direct Vault/MinIO seams, and the subprocess object-store and per-request login paths — must
  be enumerated in a machine-readable registry consumed by `prodbox dev check`; an unregistered new
  call site, or a registry entry with no surviving call site, fails the build. Qualification
  remains non-blocking; escape-path drift is not. The registry implementation is owned by
  Sprint `1.63`.
- **Aggregate rule.** A successful point probe or one successful aggregate run is insufficient for
  a temporal or cleanup claim. The owning plan names the consecutive-run, saturation, restart,
  cancellation, applied-but-response-lost, and residue checks appropriate to that surface.
- **Status ownership.** `DEVELOPMENT_PLAN/README.md` is the sole deployment-qualification ledger.
  Engineering docs describe invariants and proof boundaries but do not carry a competing status.

## Related Documents

- [README.md](README.md)
- [substrates.md](substrates.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [the engineering doctrine docs](../documents/engineering/README.md)

## Cross-Reference Conventions

- Links inside `DEVELOPMENT_PLAN/` use relative paths.
- Links to governed docs under `documents/` use repository-relative paths.
- File renames require same-change link updates everywhere the file is referenced.

## Maintenance Guidelines

1. Update the global control documents first: `README.md`, `00-overview.md`, and
   `system-components.md`.
2. Update the affected phase document next.
3. Update the governed engineering docs listed in `Docs to update`.
4. Update [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) whenever cleanup scope
   changes.
5. Run `prodbox dev check` before closing the work.
6. If the change touched Mermaid, render every Mermaid block in `DEVELOPMENT_PLAN/` and verify the
   edited diagram in the target viewer before closing the work.
