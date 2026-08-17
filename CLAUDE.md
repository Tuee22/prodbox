# Claude Code Patterns for Prodbox

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Give Claude Code a concise repository-navigation and evidence-discipline guide while
> deferring all agent operational rules to [AGENTS.md](./AGENTS.md).

## Authority and Scope

[AGENTS.md](./AGENTS.md) is the authoritative source for every agent operational rule, including
live-infrastructure authorization, AWS mutation ownership, command selection, substrate behavior,
teardown handling, testing, security, development tooling, and Git restrictions. Claude Code follows
those rules directly; this reference does not restate or modify them.

Sprint status, blockers, validation closure, and cleanup/removal ownership live only in
[DEVELOPMENT_PLAN/README.md](./DEVELOPMENT_PLAN/README.md). Stable target architecture and doctrine
are indexed by [documents/engineering/README.md](./documents/engineering/README.md).

## Claude-Specific Working Posture

- Resolve an operational question from the authoritative section in `AGENTS.md`, not from a copied
  command list or remembered lifecycle summary.
- Separate three evidence classes in every diagnosis: what the current source implements, what the
  target doctrine requires, and what the Development Plan says is cut over. Do not promote one into
  another.
- Preserve exact command output and typed failure details before assigning a cause. A Kubernetes,
  AWS, Pulumi, Vault, or MinIO attribution needs evidence that the named boundary was reached.
- When live validation is in scope, consult
  [Live Infrastructure Deployment Is Authorized](./AGENTS.md#live-infrastructure-deployment-is-authorized)
  before treating infrastructure access as a blocker.
- Keep repository changes uncommitted and follow the authoritative
  [Commit Guidelines](./AGENTS.md#commit-guidelines).

## Operational Navigation

| Need | Authoritative source |
|---|---|
| Repository layout and supported toolchain | [AGENTS.md → Current Worktree Structure](./AGENTS.md#current-worktree-structure) |
| Canonical build, quality, and test commands | [AGENTS.md → Current Worktree Commands](./AGENTS.md#current-worktree-commands) |
| AWS mutation ownership and diagnostic guardrails | [AGENTS.md → AWS Mutation Is Prodbox-Surface-Owned](./AGENTS.md#aws-mutation-is-prodbox-surface-owned) |
| Automation versus operator-interactive commands | [AGENTS.md → Command Selection](./AGENTS.md#command-selection-automation-vs-operator-interactive) |
| Substrate-equivalence operational rule | [AGENTS.md → Substrate Equivalence](./AGENTS.md#substrate-equivalence) |
| Local and cascade teardown behavior | [AGENTS.md → Live Infrastructure Deployment Is Authorized](./AGENTS.md#live-infrastructure-deployment-is-authorized) and [Lifecycle Reconciliation Doctrine](./documents/engineering/lifecycle_reconciliation_doctrine.md) |
| Current lifecycle rollout status | [Development Plan → Resume Here](./DEVELOPMENT_PLAN/README.md#resume-here) |
| Pure-functional implementation rules | [Pure FP Standards](./documents/engineering/pure_fp_standards.md) and [AGENTS.md → Coding Style](./AGENTS.md#coding-style) |
| Test design and prerequisite behavior | [Unit Testing Policy](./documents/engineering/unit_testing_policy.md) and [AGENTS.md → Testing Guidelines](./AGENTS.md#testing-guidelines) |
| Documentation ownership and generated sections | [Documentation Standards](./documents/documentation_standards.md) |

## Architecture Navigation

- CLI topology and public command behavior:
  [CLI Command Surface](./documents/engineering/cli_command_surface.md)
- Exact-keyed desired absence, recovery, and proof-carrying completion:
  [Lifecycle Reconciliation Doctrine](./documents/engineering/lifecycle_reconciliation_doctrine.md)
- Lifecycle roles and physical recovery topology:
  [Lifecycle Control-Plane Architecture](./documents/engineering/lifecycle_control_plane_architecture.md)
- Tiered configuration and authority:
  [Config Doctrine](./documents/engineering/config_doctrine.md)
- Vault authentication, durability, and sealed-state behavior:
  [Vault Doctrine](./documents/engineering/vault_doctrine.md)
- AWS-specific lifecycle adapters:
  [AWS Integration Environment Doctrine](./documents/engineering/aws_integration_environment_doctrine.md)
- Concurrency and fault-analysis method:
  [Chaos Hardening Doctrine](./documents/engineering/chaos_hardening_doctrine.md)

## Documentation Handoff

When changing architecture or lifecycle behavior, update the owning doctrine and the Development
Plan surfaces required by
[Development Plan Standards](./DEVELOPMENT_PLAN/development_plan_standards.md). Use
[legacy-tracking-for-deletion.md](./DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md) for surviving
compatibility or removal work. Do not create a status ledger or operational-rule copy in this file.
