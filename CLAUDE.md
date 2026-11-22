# Claude Code Navigation for Prodbox

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Agent navigation for the adopted documentation and numerical implementation plan.

> **Purpose**: Direct Claude Code to the canonical agent rules, contracts and evidence without duplicating them.

[AGENTS.md](AGENTS.md) owns all agent operating rules, authorization boundaries, Git restrictions and current-command guidance. Read it first. Then start at [DEVELOPMENT_PLAN/README.md → Resume Here](DEVELOPMENT_PLAN/README.md#resume-here) and implement the first incomplete phase in numerical order.

The target is retained local kind management with the same service set locally and on optional EKS. The target ordinary delete removes deployment-owned AWS resources while retaining management. Documentation adoption has not changed the existing binary, RKE2-era behavior or old checker grammar. Current executable help and generated command reference establish availability; the phase evidence establishes completion.

Before you stop or ask a question, follow [AGENTS.md → Blockers](AGENTS.md#blockers-resolve-from-the-documents-before-stopping): search the documents first, and ask only what that section reserves to the user.

| Need | Canonical owner |
|---|---|
| Agent rules, live validation, security and Git restrictions | [AGENTS.md](AGENTS.md) |
| Current next action | [Development queue](DEVELOPMENT_PLAN/README.md#resume-here) |
| Numerical order and rigorous closure | [Plan standards](DEVELOPMENT_PLAN/development_plan_standards.md) |
| Accepted architecture and responsibility map | [Engineering index](documents/engineering/README.md) |
| Target command contract | [CLI surface](documents/engineering/cli_command_surface.md) |
| Real assertions and negative controls | [Acceptance cases](DEVELOPMENT_PLAN/acceptance_cases.md) |
| Critical source defects and intended failing assertions | [Mutation cases](DEVELOPMENT_PLAN/mutation_cases.md) |
| Obsolete path's remover and replacement proof | [Legacy ledger](DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md) |
| Documentation/evidence scope | [Documentation standards](documents/documentation_standards.md) |
| Historical material | [History navigation](documents/history/README.md) |
| What the journal is, what counts as NeverAdmitted, reading history with Vault sealed | [Lifecycle](documents/engineering/lifecycle.md), [Control plane](documents/engineering/control_plane.md), [Storage](documents/engineering/storage.md) |
| The declarative specification and who records its digest | [Configuration](documents/engineering/configuration.md) |
| Unlock policies and who may unseal what | [Security and credentials](documents/engineering/security_and_credentials.md), [AGENTS.md](AGENTS.md) (test self-unseal only) |
| Whether live AWS, Vault or cluster work is authorized | [AGENTS.md → Live Infrastructure Deployment Is Authorized](AGENTS.md#live-infrastructure-deployment-is-authorized) |
| Which command exists today versus the target | [CLI surface](documents/engineering/cli_command_surface.md) and the installed binary's help |

Preserve the difference between source behavior, accepted target behavior and actually observed execution. A failure is attributed only to a boundary the command reached. Do not infer AWS absence from a missing checkpoint or blank Vault, or treat a fabricated witness, timeout, test count or old receipt as current external evidence.

A Markdown-only instruction forbids code and infrastructure edits for that task. Phase 0 stays open for executable checker adoption; do not bypass it by restoring the old queue. Later implementation requests proceed under the accepted numerical plan and activate each completed public slice rather than waiting for a final private-to-public cutover.
