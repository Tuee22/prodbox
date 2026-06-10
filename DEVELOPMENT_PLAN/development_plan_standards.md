# File: DEVELOPMENT_PLAN/development_plan_standards.md
# Development Plan Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [README.md](README.md),
[00-overview.md](00-overview.md), [system-components.md](system-components.md),
[substrates.md](substrates.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md),
[phase-0-planning-documentation.md](phase-0-planning-documentation.md),
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md),
[phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md),
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md),
[../documents/documentation_standards.md](../documents/documentation_standards.md),
[../documents/engineering/aws_integration_environment_doctrine.md](../documents/engineering/aws_integration_environment_doctrine.md),
[../documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md),
[../documents/engineering/integration_fixture_doctrine.md](../documents/engineering/integration_fixture_doctrine.md),
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
- If a previously closed phase reopens because the repository end state expands later, the top
  level docs must say exactly which earlier phase reopened, which later phases remain closed on
  their owned surfaces, and why the overall handoff is still incomplete.

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
| ⏸️ | Blocked by an unmet prerequisite |

- `Done` requires passing validation, aligned docs, and no remaining sprint-owned work.
- `Active` requires a `Remaining Work` section.
- `Blocked` requires a `Blocked by` line.
- `Planned` means dependencies are already satisfied; it must not list unmet blockers.
- Status is always scoped to the sprint or phase-owned surface. A later phase may remain `Done`
  when an earlier phase reopens, but the reopened dependency must be called out explicitly in
  `README.md` and `00-overview.md`.

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
**Blocked by**: sprint id(s) or external prerequisite (required for Blocked)
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
4. Running `prodbox check-code` after the documentation change.

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

| Substrate | Inventory | Suite parity |
|-----------|-----------|--------------|
| Home local | Local RKE2 on the operator host | ✅ Full suite |
| AWS | Disposable Pulumi stacks `aws-eks`, `aws-eks-subzone`, and `aws-test` | 🔄 Phase 7 substrate parity, targeted Phase 8 invite capture/link-follow, and local Sprint 8.5 POST/OIDC unit proof are green; AWS aggregate plus live POST/OIDC parity remain tracked in [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) |

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
5. Run `prodbox check-code` before closing the work.
6. If the change touched Mermaid, render every Mermaid block in `DEVELOPMENT_PLAN/` and verify the
   edited diagram in the target viewer before closing the work.
