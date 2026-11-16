# Configuration and Deployment Context

**Status**: Authoritative source
**Supersedes**: Pre-refactor configuration doctrine and duplicated prerequisite configuration rules
**Generated sections**: none
**Applicability**: Adopted target contract; current configuration loaders are not yet replaced

> **Purpose**: Define one authored Dhall specification, explicit contexts, and capability-specific validation.

## Sources

Keep Dhall and its versioned schemas. The binary-sibling `prodbox.dhall` remains the production default; a global `--config PATH` selects another explicit specification. Resolve relative storage paths from the specification's validated project/context anchor, never incidental working directory or ambient configuration.

The selected Dhall file is the authored desired specification. The Authority records accepted request/specification digest, applied generation and actual observations. It is not a second hidden configuration source with different values. Retaining the specification after cloud deletion permits an intentional future reconcile; it does not imply resources still exist.

| Input class | Source |
|---|---|
| Product constants and protocol vocabulary | Typed compiled catalogs; no operator copy of the same fact |
| Deployment identity and non-secret operator choices | Selected `prodbox.dhall` and validated bootstrap identity |
| Operational secrets | Typed Vault references resolved only by the authorized role |
| Elevated creation/retirement input | Ephemeral prompt, or test-only prompt simulation |
| Test topology and budgets | Separately authored `prodbox.test.dhall` |
| Test external/secret inputs | Owner-safe `test-secrets.dhall`; never copied into production config |
| Per-run identities/endpoints/paths | Derived from the validated test plan and stable run ID |

Do not use `AWS_*`, `PRODBOX_*`, shared AWS profiles or daemon environment fallback as supported auth/config sources. Daemon launch takes an explicitly mounted role-scoped configuration. Secrets cannot appear in argv, logs, compiled artifacts or generated non-secret projections.

## Minimal bootstrap projection

Status, never-admitted delete and control bootstrap require only installation/root identity, local endpoints, kind topology, artifact identity and unlock policy as applicable. They do not require application FQDN, ACME, SES or AWS settings. Validate a feature's configuration only when that requested capability needs it.

Separate decoding, semantic validation, context narrowing and effect execution. Structured failures name the field/capability and remedy without leaking values. No malformed optional projection may become an invented default region, account, domain or address.

## Environment and target selection

A context binds production/test environment, installation/run ID, root generation, control endpoints and selected application targets. AWS additionally binds the independently verified account and explicit regions. Local and AWS are explicit target constructors; checkpoint presence does not select a substrate or EKS drain target.

Production uses `.data`; tests use isolated `.test-data` contexts with unique kind names, mounts, kubeconfigs, ports, object namespaces, credentials and ownership. Test generation calls the production builder with its own inputs and output path. It never rewrites or borrows the operator's production sibling.

## Publication and component changes

`config setup/generate` authors non-secret specifications; `show` redacts handles/value classes appropriately; `validate/schema` remain read-only tools. Publish changes atomically with durable read-back and exact source identity. Register the intended change before any effect and recover interrupted publication without silently overwriting a competing specification.

Component desired-state deletion updates the selected specification and Authority request before removing resources. A temporary stop/restart is explicitly named as such. A normal reconcile must not unexpectedly recreate an intentionally removed component. [CLI](cli_command_surface.md#operator-commands)

## Prerequisites

Prerequisites are typed capabilities derived from the selected operation, not a global all-services gate. Observe and classify unavailable, needs-input and unobservable separately. Acquire only required tools, caller identities, unlock material and provider credentials. Read-only status never repairs state implicitly; mutation commands own their visible recovery steps.

Phase 1 proves source partition/path selection. Later phases extend projections and the same shared builder, not replace the context contract. [Acceptance cases](../../DEVELOPMENT_PLAN/acceptance_cases.md)
