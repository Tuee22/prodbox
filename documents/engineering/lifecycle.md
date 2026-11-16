# Lifecycle and Resource Reconciliation

**Status**: Authoritative source
**Supersedes**: Pre-refactor lifecycle reconciliation and control-plane lifecycle doctrine
**Generated sections**: none
**Applicability**: Adopted target contract; the current binary is not yet migrated

> **Purpose**: Define one durable desired-state engine, honest observations, complete AWS deletion, and bounded recovery.

## One operation engine

CLI commands, test setup/cleanup, scoped maintenance and recovery submit to one retained kind Authority. Resource adapters do not own alternate command-specific planners. The host adapter can repair the minimal local control plane; it cannot mutate AWS directly as an authentication fallback.

A validated operation carries environment, installation/run ID, account/regions, desired goal, exact resource scope, specification digest and stable operation ID. The planner is pure; bounded interpreters execute its closed effects. Keep `Requested`, `Running`, `WaitingForInput`, `RecoveryRequired`, `Completed` and `Failed` as program-owned progress, not a claim that independent external systems form one atomic world state.

## Identity, intent and observations

Create a stable bootstrap identity before provider admission. The Authority owns the durable journal. A locally readable public projection carries provenance/age and is diagnostic only; a stale snapshot cannot authorize mutation or prove current absence.

The Authority's fresh non-secret metadata read authenticates through the established local/control identity, independently of Vault Kubernetes login or Transit signing. The same Authority can serve this narrow journal-read capability while secret-dependent effects remain unavailable; its startup/read path cannot require decrypting application configuration first. Bind the caller to the selected kind/deployment and grant no cloud mutation or secret-read capability. This is not a second host writer. A stale diagnostic projection alone cannot establish NeverAdmitted. Phase 3 must prove the real read works with Vault sealed and fails for a foreign caller.

Before every external mutation, including elevated IAM bootstrap and controller activation, durably register the exact intent and cleanup obligation. Use a stable idempotency/ownership identity and record the result. After an uncertain reply, independently observe that operation's actual postcondition before retrying or admitting a successor. A wrapper that promises cleanup later does not replace registration before effect.

| Fact | Required representation |
|---|---|
| Never admitted | Positive identity-bound admission history; no authorized provider intent has existed for this scope |
| Resource presence | Provider/Kubernetes/service observation: present, absent, partial, or unobservable with cause and scope |
| Checkpoint | Missing, readable, corrupt or unobservable; authoritative for resume input only |
| Capability | Available, needs input, unavailable or unobservable; never a resource-absence answer |
| Audit | Declared field, answered queries, controls and residue; never account-wide absence by implication |

A missing existing journal, blank Vault, missing checkpoint or empty tag sweep does not mean NeverAdmitted. A new identity cannot erase unresolved obligations of an older installation. Legacy uncertainty enters the bounded migration/recovery path under the original recorded scope.

## Capability acquisition

Observe relevant facts and determine outstanding work before acquiring execution capabilities. An empty goal succeeds without credentials or unnecessary Vault initialization. A needed initialized/sealed Vault unlocks automatically when its configured material is usable, otherwise requests input in the same operation. Repair only the minimal management dependencies, not the full application platform.

The same command resumes the same nonterminal operation after restart. Cancellation requests settlement and eligible cleanup. It cannot manufacture worker absence or provider completion. A terminal failure remains attributable; a new attempt observes and links it rather than rewriting historical failure as success.

## Deletion order and completion

Top-level `delete --yes` means absence of all AWS resources created/adopted by the selected deployment. It includes production EBS/data buckets and formerly retained SES/IAM/backup resources. Print that destructive scope and obtain the documented confirmation. There is no `--cascade` or alternate local-only meaning.

1. Commit the deletion goal and preserve local recovery material.
2. Quiesce consumers and controllers that could recreate owned cloud resources.
3. Observe exact resource/family identities; drain a positively identified EKS target while eligible controllers remain available.
4. Reconcile every owned family absent in dependency order. Independent work continues when a sibling fails; unavailable drain does not silently suppress eligible provider cleanup.
5. Independently reobserve every mutation's postcondition, including failed or lost-response attempts. Retain unresolved exact obligations.
6. Remove remote object versions/backing buckets while their authority remains available. The local journal/report must not require a final write to a bucket already deleted.
7. Revoke generated IAM and retire Vault generations after their dependants. Use the separately established ephemeral verifier where necessary.
8. Mark the AWS target absent, retire obsolete checkpoints/references and retain the bounded terminal report and management identity.

A zero provider exit or disappeared stack record is insufficient. Completion requires all required read-backs, credential retirement and exact state disposition. `NoChange`/`Completed` are successful goals; `NeedsInput`, `Incomplete` and `Failed` remain distinguishable structured results. [CLI results](cli_command_surface.md#results-and-recovery)

Local application services/data and kind are outside ordinary cloud deletion. Report their retained scope. Removing kind first requires proved-clean or NeverAdmitted cloud obligations and preserves host roots. Purging local data additionally requires no mounted consumers, exact root identity and explicit operator confirmation. [Storage](storage.md#retention-and-destruction)

## Resource catalog and shared ownership

Each adapter declares exact identity, ownership evidence, dependencies, desired-presence/absence actions, independent observation, partial-create recovery and completion. Declare controller-created families before enabling their owner. Never select what to destroy merely from discovery or an empty checkpoint.

Shared resources have a separately declared owner and consumer references before use. Delete releases a consumer; it deletes the resource only in its owner scope after consumers are gone. Do not invent shared ownership during cleanup to evade an obligation. A service-specific observer complements tag sweeps; unanswered queries and a failed positive control remain unobservable.

## Implementation and validation

Reuse correct existing types/adapters and extract orchestration from oversized command/test modules. Do not add another generic framework or private replacement that never reaches the public CLI. Real create/interruption/resume/delete/repeat cases and targeted source mutants belong to the phase introducing each resource family. [Acceptance](../../DEVELOPMENT_PLAN/acceptance_cases.md) and [mutation catalog](../../DEVELOPMENT_PLAN/mutation_cases.md)
