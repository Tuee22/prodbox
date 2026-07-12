# Integration Fixture Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/unit_testing_policy.md, documents/engineering/aws_test_environment.md, documents/engineering/aws_admin_credentials.md, documents/engineering/aws_integration_environment_doctrine.md, documents/engineering/lifecycle_control_plane_architecture.md, documents/engineering/lifecycle_reconciliation_doctrine.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/test_topology_doctrine.md, DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md, DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md
**Generated sections**: none

> **Purpose**: Define capability-derived integration preparation, cleanup-obligation registration,
> always-run cleanup-DAG interpretation, and failure aggregation for real-system validation.

## 0. Canonical Doctrine Statements

- Real-system validation must own its setup and cleanup behavior explicitly.
- Cleanup obligations must be visible in the validation flow, not hidden behind ambient machine
  state.
- A cleanup obligation is receipt-committed in the durable `CleanupRun` journal before its
  corresponding mutation can obtain a committed-intent proof. Cleanup is a resumable dependency
  graph, not a success-only tail action or one process-local `finally` block.
- Named `prodbox test integration ...` commands may depend on real infrastructure, but their setup
  and cleanup ownership must remain explicit and auditable.
- Long-lived lifecycle class governs cleanup, not desired-presence preparation. A selected
  validation that requires a registered retained resource derives a visible idempotent reconcile
  action and retains that resource during ordinary postflight.
- An interrupted or response-lost lifecycle preparation is recovered through its durable operation
  ID. The fixture never infers rollback from a timeout or submits a second mutation under a fresh
  ID.

## 1. Scope

This doctrine applies to:

- built-frontend integration suites under `test/integration/`
- native real-world validation flows in `src/Prodbox/TestValidation.hs`
- AWS- and Route-53-backed lifecycle checks
- cluster-backed validation flows that modify shared runtime state

## 2. Fixture Ownership Rules

Ownership rules:

1. The code that allocates a real resource registers its typed cleanup obligation before mutation
   and owns the idempotent cleanup interpreter for that resource. Registration returns an opaque
   `CleanupObligationRef`; the mutation interpreter rejects an intent that does not bind it.
2. The retained Lifecycle Authority owns the backup-receipted cleanup journal, recovery worker, and
   aggregate report. `src/Prodbox/TestRunner.hs` builds/submits the plan and may drive postflight, but
   it is not the journal owner. Runner loss cannot delete or fence out the cleanup run.
3. AWS-mutating validation flows must durably request cleanup of every owned per-run resource before
   returning, whether validation succeeded, failed, timed out, or was interrupted. Client-lease
   expiry requests the same cleanup after SIGKILL or disconnection.
4. The suite-level IAM harness in `src/Prodbox/TestRunner.hs` owns setup and teardown of
   every temporary Lifecycle-provider generation and run-scoped AWS cert-manager-DNS01 generation
   for `prodbox test integration aws-iam`, targeted
   `prodbox test integration <name> --substrate aws` validations,
   `prodbox test integration all`, and `prodbox test all`. **The IAM-harness tier is
   capability-derived (Sprint `5.6`):** `derivedManagedAwsHarnessPolicyTier` in
   `src/Prodbox/TestPlan.hs` engages the harness exactly when a validation declares an
   AWS-credential-consuming prerequisite on the AWS substrate, or is `aws-iam` /
   `keycloak-invite` (which materialize operational credentials on every substrate). The
   former `normalizeManagedAwsHarness` `substrate=aws` blanket override is **deleted**: a
   credential-free validation (e.g. `gateway-partition`) no longer acquires the IAM harness
   merely because the active substrate is AWS. Home Gateway-DNS, home cert-manager-DNS01,
   TLS-retention-store, and Authority-backup-store generations are `LongLived` with restored home
   consumers and are never temporary IAM-harness teardown nodes.
5. Cleanup failures must be surfaced explicitly without replacing the original validation failure;
   failure of one cleanup node must not prevent an independent ready node from running.
6. A retained managed resource required by the selected validations is reconciled through its
   canonical command after its backend is ready; the suite does not hide this mutation in a
   prerequisite and does not add it to per-run cleanup.

The harness never interprets an admin prompt mutation in-process. Identity/store setup submits the
stable backup-receipted `OperatorMaterialPermit` (or the first-run `GenesisBackupPermit`) and sends
fixture prompt bytes over authenticated exec/attach stdin only after verifying the Credential
Provisioner Pod UID, image digest, ServiceAccount, permit binding, and—during first reconcile—the
AWS-only plan digest, exact next member, durable prior receipt, deadline, heartbeat, and attach
witness. The retained AWS-admin session cannot accept the separately framed ACME EAB fixture.
Disconnect/restart or any proof failure loses the linear session and requires re-prompt while the
same permit and finite inventory resume. The Job
revokes its session, exits, and is deletion-read-back; best-effort zeroization applies only to owned
mutable/mlocked buffers, not possible Haskell/SDK/TLS/GC copies. Explicit SES destroy, legacy
migration/retained compatibility, and quota requests instead use the distinct
backup-receipted `AdminActionPermit` and Admin Action Runner. `DestroyAwsSes` verifies consumer
quiescence, external SMTP IAM plus non-credential SES/S3 absence, target SMTP tombstones, and
retained-home SMTP-custody absence in dependency order. No host-direct prompt mutation or normal
Provider Worker fallback exists.

The per-run-vs-long-lived teardown split for test runs and the never-touch-`.data/` guard are
governed by [test_topology_doctrine.md](./test_topology_doctrine.md), which reuses the same
`LifecycleClass` split these fixture-ownership rules rely on. The topology runner's generated
variant config and `.test-data/<case>/` root are per-run fixtures; the authored
`prodbox.test.dhall`, production `.data/`, and long-lived resources remain outside fixture cleanup.
That cleanup exclusion does not make a required long-lived resource ambient: §2A defines the
separate desired-presence preparation obligation.

The destructive `--dry-run` golden fixtures under `test/golden/destructive/` (Sprint `5.6`:
`rke2-delete.txt`, `rke2-delete-cascade.txt`, `nuke.txt`) are **registry-generated** — their
per-run, `aws-ses`, and long-lived destroy lines derive from the managed-resource registry /
`StackDescriptor` SSoT, and a drift guard fails the suite if a registered resource is added
without regenerating the golden. They prove each destructive path's planned step list without
allocating or destroying any real resource.

## 2A. Retained Desired-Presence Preparation

A pure projection reduces the selected validation set to retained preparation requirements.
`ValidationKeycloakInvite` contributes the registered `aws-ses` capability on both substrates;
validations without invite capability contribute no SES requirement. Reduction removes duplicates,
so aggregate suites narrate and submit one retained-SES operation for each distinct authority,
request, and target set.

Preparation and cleanup are independent projections over the same managed-resource registry:

- `PerRun` resources may appear in both preparation and the always-run cleanup DAG.
- `LongLived` resources may appear in preparation when required, but never in ordinary suite
  cleanup.
- Explicit `prodbox aws stack aws-ses destroy --yes` and `prodbox nuke` remain the only supported
  destroy owners for retained SES infrastructure.
- Authority-backup-store resources are established/rotated only through their genesis/rotation
  protocol, retained by every ordinary suite and `aws teardown`, and destroyed only by the exported
  standalone `nuke` decommission protocol.
- TLS-retention-store objects/identity/generation, the home public A record/Gateway-DNS generation,
  and home Certificate/Challenge/DNS01 ownership/generation are visible `LongLived`
  desired-presence requirements when selected. Ordinary cleanup restores/observes them; explicit
  consumer decommission or `nuke` owns their absence. AWS A/Certificate/Challenge/DNS01 resources
  remain run-scoped.

`Prodbox.Lifecycle.ResourceRegistry.ManagedResource` carries desired-presence fields independently
from discovery and destruction. The pure desired-presence interpreter consumes flat
presence/checkpoint observations and submits the registered operation; fixture code does not create
a second SES registry, inline provider mutations, or reproduce lifecycle transitions.

For retained SES, the visible preparation action carries an explicit retained-home authority
coordinate and a separate selected-substrate target coordinate. The former is interpreted by the
Lifecycle Authority; the latter is interpreted only by the selected Target Secret Agent. Neither
coordinate is a gateway endpoint, kube context, port-forward, or ambient “active substrate” lookup.
Lifecycle state-machine semantics are canonical in
[Lifecycle Reconciliation Doctrine §3.1](./lifecycle_reconciliation_doctrine.md#desired-present-reconciliation-for-long-lived-resources),
while deployment and capability placement are canonical in
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

`TestRunner` projects each requirement exactly once and receipt-commits a stable
`ClientSubmissionKey` plus request digest in the durable `CleanupRun`. The Lifecycle Authority
CAS-allocates the registered TestRunner client sequence and returns the resulting `OperationId`,
which additionally binds the suite run, capability, authority epoch, request digest, and target set.
The preparation interpreter:

1. validates the exact Lifecycle Authority and Target Secret Agent capabilities;
2. reserves/submits the durable submission key and request digest;
3. on a lost reservation or submission response, resolves that key to the same operation ID rather
   than allocating another;
4. observes durable stage changes until the required provider revision is semantically ready and
   all required target generations are committed, or until the caller's absolute deadline expires;
5. records the operation ID and final observation in the suite report.

This is an asynchronous operation boundary, not a 70-minute synchronous
`acquire -> reconcile -> await-ready -> sync-target -> release` bracket. Provider and credential
mutations use narrow fences inside the Lifecycle Authority; propagation waiting holds no mutation
fence, STS session, gateway connection, or test-runner worker ownership. Target delivery starts
only from a durable bounded outbox and completes only after generation-checked Target Secret Agent
CAS plus read-back. A caller timeout does not imply that an accepted external effect was canceled.

Each readiness observation first proves the complete registered provider inventory and then the
semantic sender/DKIM, exact MX, active receipt-rule, and capture-canary conditions for the committed
provider revision. Only `AwsSesPending` is eligible for later observation;
`AwsSesFailed` and `AwsSesUnobservable` terminate the current wait immediately. Exhaustion reports
the operation ID and last structured observation, leaving durable recovery to the Lifecycle
Authority rather than an in-memory fixture bracket.

Prerequisite checks remain read-only. They may reject missing tools, invalid configuration,
unreachable typed capabilities, or unavailable AWS observation, but they may not create, import, or
update SES resources. The mutation is an explicit operation submission and every required
postcondition is re-observed before the dependent validation runs. See
[Prerequisite Doctrine §4A](./prerequisite_doctrine.md#4a-prerequisitepreparation-boundary).
`prodbox host check-ses-readiness` exposes the same semantic prerequisite scopes as a read-only
single-observation diagnostic; it never invokes retained-resource reconciliation.

If retained preparation fails after partial AWS mutation, the partial long-lived state and durable
operation remain retained and the suite reports the operation ID. Cleanup must bring any suite-owned
transient execution to a safe durable disposition, but it must not turn retained SES into a per-run
destroy target. A later run observes and resumes the recorded operation or submits a new operation
only after lifecycle recovery proves the prior one terminal and quiescent.

## 3. Isolation Modes

Supported isolation patterns include:

- fake-tool built-frontend proof in `test/integration/CliSuite.hs`
- fake-trace built-frontend proof for capability boundaries, including rejection of gateway-owned
  bootstrap, lifecycle-CAS, target-secret, and host-direct fallback routes
- repository-local config proof in `test/integration/EnvSuite.hs`
- ephemeral AWS hosted zones or stacks created and destroyed by the named validation flow
- aggregate runtime repair through the public `prodbox` surface after destructive integration work

## 4. Cleanup Failure Handling

Cleanup is a pure, validated DAG interpreted on success, failure, timeout, interruption, runner
death, and authority restart. Its durable model is flat and bounded:

```haskell
data CleanupDependency
  = RequiresSuccess CleanupNodeId
  | RequiresAttempt CleanupNodeId

data CleanupNodeState
  = CleanupRegistered CleanupObligationRef
  | CleanupRunning CleanupFence OperationId
  | CleanupSucceeded CleanupEvidence
  | CleanupSatisfiedWithReason CleanupReason
  | CleanupFailed CleanupFailure
  | CleanupBlocked CleanupNodeId CleanupFailure

data CleanupRunState
  = CleanupPreparing CleanupPlan
  | CleanupArmed CleanupPlanDigest
  | CleanupRequested CleanupTrigger
  | CleanupExecuting CleanupOwnerFence (BoundedMap CleanupNodeId CleanupNodeState)
  | CleanupClosed CleanupReportRef
```

The builder rejects duplicate ownership, an unregistered creatable resource, missing dependencies,
cycles, an unbounded node family, and a dependency whose credential lifetime is shorter than its
consumers. It CAS-commits the complete static plan to the Lifecycle Authority's independent backup
before the first suite-owned external mutation. A coordinate learned later—such as an LBC child
resource or cert-manager Challenge record—is appended and receipt-read-back before its owning
controller may create it. No create/ensure/provider program can be interpreted without the matching
opaque `CleanupObligationRef` in its `CommittedIntentRef`.

`CleanupRunId` and every cleanup-node `OperationId` bind the authority epoch, suite-run identity,
plan digest, node key, and attempt generation. The authority owns a monotonically increasing cleanup
fence and a bounded client heartbeat lease. Normal postflight, cancellation, the validation
deadline, client-lease expiry, or explicit operator recovery moves an armed run to
`CleanupRequested`. On restart the recovery worker scans every nonterminal run before admitting a
new run in the same scope, reacquires the fence, observes any running node by its existing operation
ID, and resumes it. A stale TestRunner or former recovery worker cannot complete a node under an old
fence. If the whole retained control plane is unavailable, the backup-receipted run resumes after
authority restoration; physical unavailability delays cleanup but does not erase its ownership or
credentials. Capacity is fixed; nonterminal runs are never evicted, and saturation refuses a new
suite before mutation.

The interpreter repeatedly runs every ready node. `RequiresSuccess` opens only after authoritative
postcondition evidence. `RequiresAttempt` opens after its predecessor reaches any terminal attempt
outcome and is used only where a last-resort backstop must run despite predecessor failure. Failure
of one node blocks only its `RequiresSuccess` descendants; independent and attempt-dependent nodes
continue. Absence is `CleanupSucceeded` with evidence, never an unrecorded skip.

The canonical dependency order is:

1. stop new suite submissions and close or observe suite-owned transient transports;
2. observe each recorded Lifecycle Authority operation and resolve an active mutation to clean
   quiescence or a durable explicit ambiguous/recovery disposition;
3. restore and read back the canonical retained home control plane and application charts needed by
   later cleanup interpreters;
4. drain the selected cluster while its controllers are live and reconcile every registered
   controller-created/DNS child family toward absence;
5. after a `RequiresAttempt` edge from drain, submit or resume every per-run provider destroy, then
   reap registered test-scoped EBS volumes;
6. delete each role-specific IAM/key resource only after `RequiresSuccess` evidence from every node
   that consumes that exact identity, then commit/read back its Vault tombstone; and
7. re-observe every owned lifecycle class, exact record, dynamic child family, cleanup operation,
   intended retained resource, and credential tombstone before closing the report.

`DrainSkipped` is interpreted by substrate, not as universal success. A positively observed absent
disposable home control plane may become `CleanupSatisfiedWithReason`. On AWS, an unreachable API,
missing kubeconfig, timeout, or any skipped drain is `CleanupFailed`; the provider-destroy node is
still eligible through `RequiresAttempt`, and neither its success nor the final tag observation can
erase the drain failure. `DrainFailed` is a failure on every substrate.

The `LongLived` Authority-backup-store, TLS-retention-store, home Gateway-DNS, and home
cert-manager-DNS01 credentials are not nodes in ordinary suite cleanup or `aws teardown`; those
flows observe and retain their generations with the restored home consumers. Rotation preserves a
readable predecessor until replacement read-back and receipt. AWS cert-manager-DNS01 is run-scoped
and becomes eligible only after its AWS Certificate/Challenge/TXT dependants are absent. A
provider-destroy failure preserves Lifecycle-provider credentials. Explicit consumer decommission
may remove the matching home credential; only `nuke` removes Authority backup and all retained
consumers under the exported external-receipt protocol.

For `nuke`, “cleanup run” ends at decommission export rather than pretending stopped Authority can
receipt deletion of its own backup. Authority backup-receipts the deterministic signed manifest;
the CLI `fsync`/read-backs it to a required operator/harness receipt sink outside every target;
Authority commits `DecommissionExported` and permanently stops. The standalone
`DecommissionRunner` first verifies the build/Tier-0/Broker-pinned Authority signer digest and
accepts only closed compiled program tags plus exact registered coordinates; tampered manifest,
key, receipt, tag, or widened coordinate refuses before prompt. It then journals every exact
destroy/read-back to that same receipt under a fresh admin prompt. Home Agent/Vault/Gateway/
cert-manager/control-plane Pods stay live through home record/Certificate/Challenge removal and all
retained-generation tombstone read-backs. The runner then stops/uninstalls home control plane and
optional `.data`, and deletes every TLS-retention prefix version plus TLS key/IAM without deleting
the shared bucket. The final Authority-backup node proves
every registered prefix absent, deletes its objects/key/IAM, and deletes the shared bucket last.
Runner crash resumes from the same receipt; ordinary suite cleanup never enters this mode. The
canonical exception is
[Lifecycle Control-Plane Architecture §11.1](./lifecycle_control_plane_architecture.md#111-total-decommission-and-the-final-backup-deletion).

Long-lived resources are not destroyed by this DAG. Resolving a long-lived operation means making
its durable state safe, quiescent, and queryable, not converting it into a per-run target.

The receipt-committed final report contains the original validation outcome plus every cleanup
failure, satisfied-with-reason result, and dependency-blocked node. The original failure renders
first, but cleanup success never erases it and cleanup failure never prevents independent cleanup.
The bounded report remains queryable by `CleanupRunId` after the TestRunner exits; terminal detail
may compact only to an immutable report blob plus digest, while the non-reusable run tombstone
remains for its configured idempotency window.

Integration failure injection covers Credential/Admin Job attestation and stdin disconnect,
same-permit response loss, permanent-backup key/bucket/policy loss versus temporary
unobservability, verified one-shot Broker init/unseal worker attestation and prompt disconnect,
controller-plaintext exclusion, repair crash/replay and greater-epoch open, opaque secret-commitment equality, TLS
out-of-order/response-lost immutable puts, corrupt/digest-mismatched/unobservable restore refusal,
positive absence/validated-expiry issuance, AWS Vault/EBS destroy-recreate restore, retained-home
credential survival, and tampered decommission signer/manifest/key/receipt/tag/coordinate
rejection, torn receipt-tail recovery, complete-frame checksum/hash-chain conflict,
corrupt/unobservable receipt refusal, stable-attempt effect re-observation, missing external runner
artifact, and cross-build/schema resume refusal. Each case asserts the final durable operation/cleanup state and authoritative read-back,
not only process exit.

The retained-material matrix additionally covers AWS-admin/EAB schema confusion, SMTP derivation
without raw-IAM-secret custody, home custody seal response loss, flat absent/corrupt/digest-
mismatch/unobservable observations, rewrap crash before/after target envelope read-back, target
worker/nonce/attestation/deadline loss forcing fresh rewrap, target materialization response loss,
supersession deadline without target/consumer retirement evidence, GC reference races, a target first introduced after
source creation, and fresh AWS Vault/EBS restore of both SMTP and ACME EAB from their current home
receipts without admin re-prompt, key remint, or EAB re-entry. Destroy/nuke injection proves external
credential/resource absence precedes every target tombstone, target absence precedes custody
absence, KV-v2 soft delete cannot satisfy physical version/metadata absence, and home Agent/Vault
remain live until both closed custody tags are read back. SES cutover injection also proves the
new non-credential checkpoint plus custody/targets commit before old secret-bearing checkpoint
outputs leave current state, and fenced primary/backup blob GC waits for rollback grace and complete
no-reference scans.

## 5. Relationship To Other Doctrine

This document works with:

- [Unit Testing Policy](./unit_testing_policy.md) for test-runner and phase-banner doctrine
- [AWS Integration Environment Doctrine](./aws_integration_environment_doctrine.md) for real AWS
  auth and isolation rules
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md) for desired-present
  and cleanup projections over the managed-resource registry
- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md) for the
  Bootstrap Broker, Lifecycle Authority, isolated Worker/Adapter/Job roles, Target Secret Agent,
  and capability-binding topology
- [Prerequisite Doctrine](./prerequisite_doctrine.md) for the read-only gate boundary
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md) for retained local data behavior

## 6. Fixtures Versus Substrate Config

A fixture is a boundary-injected fake-tool harness or an ephemeral resource owned for the
lifetime of one validation. A substrate is the operator-provisioned real environment a
canonical-suite run targets (DNS, certs, ingress, charts) per the inventory in
[`DEVELOPMENT_PLAN/substrates.md`](../../DEVELOPMENT_PLAN/substrates.md). The two are not
interchangeable.

A retained desired-presence preparation action is neither an ephemeral fixture nor ambient
substrate state. It is a visible managed-resource reconcile derived from validation capability, with
cleanup governed independently by `LifecycleClass`. Specifically:

- Fixtures may be reused across substrates because they fake a boundary (`aws` CLI, `dig`,
  `kubectl`) rather than represent the substrate itself.
- Substrate config (e.g. `aws_substrate.hosted_zone_id`, `route53.zone_id`) is required and
  substrate-locked per
  [`DEVELOPMENT_PLAN/development_plan_standards.md` § M — Substrate coverage and independence (no fallback)](../../DEVELOPMENT_PLAN/development_plan_standards.md#substrate-coverage-and-independence-no-fallback).
  A validation that runs on the AWS substrate must consume only AWS-substrate config; a
  validation that runs on the home substrate must consume only home-substrate config.
  Fixtures do not silence missing-substrate-config errors, and a fake-tool harness does not
  satisfy a substrate prerequisite that requires real infrastructure.

## Cross-References

- [Unit Testing Policy](./unit_testing_policy.md)
- [AWS Integration Environment Doctrine](./aws_integration_environment_doctrine.md)
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md)
- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
