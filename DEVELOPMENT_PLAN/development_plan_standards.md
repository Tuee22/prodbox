# File: DEVELOPMENT_PLAN/development_plan_standards.md
# Development Plan Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md)

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
├── phase-5-public-host-validation.md
├── phase-6-clean-room-handoff.md
├── legacy-tracking-for-deletion.md
└── system-components.md
```

No phase may be skipped. No sprint may exist in two phases. Runtime ownership, gateway/DNS
ownership, chart-delivery ownership, and public-host validation ownership must each live in one
place only.

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
4. Running `poetry run prodbox check-code` after the documentation change.

This standards document describes Mermaid rules with prose, inline code, or `markdown` examples
only. Do not add live Mermaid blocks here.

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
5. Run `poetry run prodbox check-code` before closing the work.
6. If the change touched Mermaid, render every Mermaid block in `DEVELOPMENT_PLAN/` and verify the
   edited diagram in the target viewer before closing the work.
