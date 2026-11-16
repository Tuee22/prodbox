# CLI Command Surface

**Status**: Authoritative source
**Supersedes**: Pre-refactor operator/runtime command topology
**Generated sections**: none
**Applicability**: Adopted target contract; the installed command registry still describes the old binary

> **Purpose**: Define a small operator workflow, maintenance/internal visibility, and shared lifecycle semantics.

## Availability and registry

This document defines the accepted target. The [current generated reference](../cli/commands.md) and installed binary help remain evidence of commands actually available. Implement commands in their owning [numerical phase](../../DEVELOPMENT_PLAN/README.md#resume-here); do not install successful stubs or claim this documentation activates them.

One typed `CommandSpec` generates parser, visibility-aware help, manpages, completions, JSON/tree listings and generated reference. Separate `Operator`, `Maintenance` and `Internal` visibility; hidden launchers are still authenticated. Every old leaf/meaningful option has a [disposition](../../DEVELOPMENT_PLAN/command_dispositions.md).

Unknown arguments fail at the parser. A group without a leaf shows help. No downstream-tool passthrough or dynamic filename test selector exists. Common context/target/result options have one declaration, not per-command copies.

## Operator commands

```text
prodbox [--config PATH] [--json] <command>
  status
  plan reconcile|delete
  reconcile [--target local|aws]
  delete --yes
  control status|reconcile|delete
  services list|status|logs
  operations list|show|resume|cancel
  config setup|generate|show|validate|schema
  users invite|list|revoke
  test init|list|run|status|cleanup
  dev check|lint|docs|tla-check
  admin ...
  commands [--tree|--json|--include-internal]
  help <path>
  internal ...
```

| Surface | Contract |
|---|---|
| `status` | Read-only control/target facts, age/source of observations, active operation and next action; useful under degraded dependencies |
| `plan reconcile` / `plan delete` | Same scope/planner as execution; show unresolved inputs and required observations; no hidden repair effects |
| `reconcile` | Ensure configured targets or explicit `local`/`aws`, acquiring only required capabilities and resuming incomplete work |
| `delete --yes` | Delete all selected-deployment-owned AWS, retire obsolete cloud state/credentials, retain kind, trust/journal, local services/data |
| `control reconcile` | Create/repair kind and minimal management without implicitly provisioning cloud applications |
| `control delete --yes` | Require exact clean/NeverAdmitted cloud obligations, remove kind, retain host data and completion identity |
| `services list/status/logs` | Explicit target/component diagnostics; distinguish control and application instances |
| `operations resume ID` | Resume the same scoped operation through the same engine; no scope/permission escalation |
| `operations cancel ID` | Request cancellation, settle effects and eligible cleanup, preserve unresolved ownership; cancellation itself is not completion |
| `test run NAME` | One scenario registry/runner for unit, CLI, integration, mutation, fault and aggregate cases |
| `test cleanup RUN_ID` | Delete exact test-owned cloud resources, then retire disposable control/run state only after absence proof |

Cloud delete never accepts `--cascade` and never uninstalls its engine. It includes formerly long-lived SES, production EBS, backing buckets and generated IAM. An explicit future reconcile may recreate a deleted deployment from retained specification. [Exact scope](lifecycle.md#deletion-order-and-completion)

Component desired-state mutation is advanced: `admin services reconcile/delete` updates the selected specification and Authority request durably before effects. Reconcile honors that selection. Temporary stop/restart actions do not change desired selection and are named explicitly. Specify a target whenever ambiguous; do not infer it from checkpoints or ambient kubeconfig.

## Maintenance and internal commands

| Group | Retained capability |
|---|---|
| `admin aws stack <storage-canary|eks|subzone|ses>` | Status/diff/reconcile/delete as exact-scope clients of the common engine; the first real cloud canary is S3, not the old three-EC2 test stack |
| `admin aws credentials` | Status/reconcile/revoke/policy; ordinary workflows invoke the same handlers automatically |
| `admin aws audit`, `admin aws quotas` | Declared-field inventory and quota check/request |
| `admin aws recovery plan/apply` | Closed checkpoint recovery, legacy adoption, SES backend migration, network purge; exact identity and digest-bound confirmation |
| `admin vault` | Status/unseal/seal/reconcile, scoped ambiguous-init recovery, unlock/Transit rotations, PKI status/test issuance |
| `admin control` | Kind health/wait/start/stop/restart/log diagnostics and exact operator-only data purge |
| `admin services`, `admin edge`, `admin dns` | Component desired-state operations and detailed edge/DNS observations |
| `admin federation` | Explicit register/status and scoped child recovery |
| `admin host` | Tool/port/info/SES-readiness/firewall diagnostics and configured host prerequisites |
| `internal` | Same-binary Broker, Authority, Provider, Provisioner, backup/TLS/Agent, admin/secret workers, workload and RPC controller launchers |

Normal operation never requires finding and invoking internal launchers. Maintenance does not bypass ownership or credential policy. Recovery does not accept arbitrary resources or AWS CLI arguments. The temporary original-install migration lane is bounded to recorded old identities and removed by Phase 10; it is not an ordinary fallback.

Do not reuse the old `aws-test`/CLI `test` stack identity for the new storage canary. Old HA-RKE2 resources retain exact diff/delete/adoption support only in the fenced migration lane until their obligations are resolved. Gateway HA assertions move to kind/EKS in Phase 9.

## Results and recovery

Structured results are `NoChange`, `Completed`, `NeedsInput`, `Incomplete` and `Failed`. Phase 1 fixes one numeric exit-code mapping in the registry/evidence contract; zero is reserved for a satisfied goal. JSON carries outcome, context/operation IDs, observation scope and next action. Human output says what exists, what changed and what remains.

An AWS-never-admitted deployment can return “Nothing to delete” without cloud credentials or needless Vault initialization. An initialized/sealed Vault unlocks when required and configured material is usable; otherwise prompt in the same operation. Without a TTY/secure configured input, return `NeedsInput` with the canonical remedy. `--yes` authorizes the printed destructive plan; it does not provide a missing password or override ownership.

Report one root dependency failure with its downstream consequences rather than three apparent independent stack failures. Keep internal signer/CAS/codec details in verbose diagnostics unless they determine the operator's next action. Sprint identifiers and development-plan vocabulary never appear in runtime output.

Plans are reviewable observations, not universal future guarantees. Execution rechecks mutable preconditions. A mandatory plan-file ceremony is unnecessary for ordinary reconcile/delete; exceptional adoption/purge uses an exact digest and confirmation.

## Validation

The actual public binary, generated artifacts, phase manifests and old-to-new dispositions must agree. Test parser rejection of removed flags, useful degraded status, prompt/noninteractive results, exact deletion scope, no-op repetition and stable resume. Targeted source mutants must fail the intended unchanged assertions. [Testing contract](testing.md)
