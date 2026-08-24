# Integration Fixture Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Define capability-derived integration preparation, cleanup-obligation registration,
> validation-specific use of the lifecycle cleanup core, and failure aggregation for real-system
> validation.

The cleanup-client and fault-injection contracts below are target doctrine. Current implementation,
migration, and deployment-qualification status remain exclusively in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md); dated implementation records are provenance,
not a claim that target cleanup has cut over.

## 0. Canonical Doctrine Statements

- Real-system validation must own its setup and cleanup behavior explicitly.
- Cleanup obligations must be visible in the validation flow, not hidden behind ambient machine
  state.
- A cleanup obligation is receipt-committed in the durable `CleanupRun` journal before its
  corresponding mutation can obtain a committed-intent proof. Cleanup is a resumable dependency
  graph, not a success-only tail action or one process-local `finally` block.
- The lifecycle doctrine owns that graph, its exact observations, and its completion proof. This
  doctrine owns only validation registration, the originating test result, and assertions over the
  generic report.
- Named `prodbox test integration ...` commands may depend on real infrastructure, but their setup
  and cleanup ownership must remain explicit and auditable.
- Long-lived lifecycle class governs cleanup, not desired-presence preparation. A selected
  validation that requires a registered retained resource derives a visible idempotent reconcile
  action and retains that resource during ordinary postflight.
- An interrupted or response-lost lifecycle preparation is recovered through its durable operation
  ID. The fixture never infers rollback from a timeout or submits a second mutation under a fresh
  ID.
- **A fixture stands in for an observation; it never stands in for the *fact* that an observation
  happened** (Sprint `5.33`, 2026-08-11). Two rules follow, and both were violated by the shipped
  `daemon-bootstrap` node:
  1. **The unset arm is not a fixture arm.** A named validation selected by a `PRODBOX_TEST_*`
     fixture variable must, when that variable is unset, either observe or refuse. It may not fall
     through to the passing fixture, because the unset arm is the one CI and a bare invocation take
     and is therefore the arm whose behaviour the plan's evidence actually records.
  2. **The output names the source.** Where a node can run from either an observation or a fixture,
     its emitted evidence states which. Otherwise the two are distinguishable only by reading the
     source — which is exactly where the equivalence went unnoticed for the lifetime of the node.
- **A boundary fake must answer every observation the production path makes** (Sprint `4.76`,
  2026-08-11). The fake-`kubectl` boundaries in `test/integration/CliSuite.hs` served no
  `get endpoints kubernetes` after Sprint `3.34` made that a live observation on the chart-reconcile
  path, and one of the two had a silent catch-all arm that answered empty stdout with exit 0 — so
  the production observer read `""` and refused on a shape rather than on an absence. A fake's
  catch-all arm is a fail-open default; prefer an explicit refusal naming the unhandled request.

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
6. A retained managed resource required by the selected validations is reconciled through the same
   registered desired-present program consumed by the operator CLI after its backend is ready. The
   suite is a peer lifecycle client: it does not shell or wrap the public command, hide the mutation
   in a prerequisite, or add the retained resource to per-run cleanup.

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

The target `ManagedResource resource life kind` in
[Lifecycle Reconciliation Doctrine §3.1](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-and-exact-observation-boundary)
is a hypothetical doctrinal type, not a claim about the current callback-bearing
`Prodbox.Lifecycle.ResourceRegistry.ManagedResource`. Its private target constructor binds exact
observation and desired-presence/desired-absence program tags independently. The pure
desired-presence interpreter consumes flat presence/checkpoint observations and submits the
registered operation; fixture code does not create a second SES registry, inline provider
mutations, or reproduce lifecycle transitions. Retirement of the current callback-bearing type is
tracked in the
[legacy deletion ledger](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).

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

## 4. Validation as a Cleanup Client

The generic `CleanupRun` model, exact observation types, desired-absence decisions, graph edges,
resume rules, and proof-carrying completion are owned by
[Lifecycle Reconciliation Doctrine §3](./lifecycle_reconciliation_doctrine.md#3-exact-keyed-desired-absence-reconciliation).
A validation does not define another cleanup engine and does not inject `IO` callbacks into that
engine. It is a client with three additional responsibilities:

1. build and receipt-commit every cleanup obligation before the corresponding fixture mutation;
2. attach the originating validation identity and final validation outcome to the generic run; and
3. assert the durable report, including every cleanup failure, as part of the validation result.

**Current revision.** `Prodbox.Test.LifecycleCleanupClient` is the validation-specific composition
over that protocol. `TestRunner` supplies the suite identity, exact registered-resource selection,
kubectl environment, and primary body. The canonical selected-key compiler owns graph shape and
operation IDs; the authenticated Lifecycle Authority owns registration and restart; the closed
ordinary dispatcher owns effects; and lifecycle core owns the terminal node-state decision. A
later invocation adopts the one nonterminal run under the stable suite prefix and does not rerun the
primary body. The deleted `ManagedCleanupPlan` / `DurableCleanupComposition` modules, direct Route
53 sweep, ambient absence fixture, and validation-owned success fold have no supported caller.

The retained local config/RKE2/Vault preparation that establishes the Lifecycle Authority may
precede an ordinary descriptor because the Authority is physically unavailable before that work.
It creates no selected per-run AWS resource. Registration and claim must be independently
re-observable before IAM setup or any later mutation that can create one; this is the enforceable
pre-mutation boundary for `ExplicitPerRun`, not a cascade-only host-uninstall record.

The fixture-side request is pure data:

```haskell
-- Example: hypothetical validation cleanup-client values
data ValidationCleanupOrigin = ValidationCleanupOrigin
  { validationRunId :: ValidationRunId
  , validationName :: ValidationName
  , topologyDigest :: TestTopologyDigest
  , sourceIdentity :: SourceIdentity
  }

data ValidationCleanupOutcome
  = ValidationAndCleanupSucceeded CleanupReportReceipt
  | ValidationFailed ValidationFailure CleanupReportReceipt
  | CleanupIncomplete ValidationOutcome CleanupRunId (NonEmpty CleanupFailure)
```

A fixture planner selects registered resources through the lifecycle registry, supplies exact
synthetic coordinates to fake observers or exact live coordinates to production observers, and
submits the resulting plan to the Lifecycle Authority. It cannot forge absence with an environment
variable, substitute an escape sweep for an exact observation, widen a coordinate after
registration, or mint a `CleanupObligationRef` locally.

Long-lived desired-presence preparation remains explicit. If a selected validation needs a
registered `LongLived` resource, its setup plan reconciles that resource present and ordinary
postflight observes and retains it. Lifecycle class does not imply ambient presence and cleanup does
not reclassify a retained resource as per-run.

On success, failure, timeout, cancellation, client disconnect, or TestRunner death, the client
requests cleanup for the same durable run. The lifecycle recovery worker owns execution and
resumption. The client may wait for the report within its deadline, but loss of that wait does not
cancel ownership or create a second run. A later invocation scans and resumes the same
`CleanupRunId` before new mutation in the scope.

The final validation rendering preserves causality:

- the original validation outcome renders first;
- every cleanup failure and dependency-blocked node renders with its exact resource key and
  confirming authority;
- a complete cleanup report never erases a failed validation;
- an incomplete cleanup never becomes a warning, and renders the stable `CleanupRunId`; and
- expected retained resources are distinguished from escapees by typed lifecycle class, not prose.

### Fixture use of the canonical fault matrix

The generic recover-to-clean fault matrix is owned once by
[Unit Testing Policy §10](./unit_testing_policy.md#10-always-run-cleanup-validation). Every
lifecycle-changing validation supplies deterministic interpreter-boundary coverage for the rows it
can reach and proves that its client registration cannot mint observations, absence evidence, or a
second cleanup identity.

The frozen 2026-08-15 counterexample requires the preliminary caller-ServiceAccount observation to
remain `Unobservable`; discarded stderr leaves both its cause and whether it reached the Kubernetes
API unknown. Separately, the AWS Tagging API returned one `ResourceTagMapping` for the intentionally
retained long-lived state-bucket ARN with its full two-tag set; the pre-cutover decoder emitted two
rows from that one mapping. The global audit returned no per-run mapping, but every exact stack
observation remained unobservable, not an empty inventory. The frozen historical arm reproduces
the old composition's false three-stack presence classification by copying those two unkeyed
decoded rows to `aws-eks`, `aws-eks-subzone`, and `aws-test`.

The current replacement reports the bucket once as retained, preserves every exact stack
observation and the caller observation as independently unobservable, selects no EKS drain or
per-run destroy from the global audit, and returns the same cleanup run on retry.

Live home and AWS campaigns use the same assertions but remain deployment-qualification evidence
under Standards O/P in the Development Plan. A fake fixture proves decision structure and
composition; it never claims that AWS or Kubernetes returned a live fact.

## 5. Relationship To Other Doctrine

**Fixture code is compiled by the canonical gate, and still not run by it.** `prodbox dev check`
runs `fourmolu` and `hlint` over `app src test`, and then a type-checking build scoped
`all --enable-tests` — which since Sprint `5.30` resolves to `lib`, `exe:prodbox` and the eight test
suites ([code_quality.md](./code_quality.md); the general rule is "The region of Ring 2" in
[resource_scaling_doctrine.md § 2C](./resource_scaling_doctrine.md)). Before that flag a fixture was
type-checked only when `prodbox test integration cli` / `env` compiled it, and nothing routine ran
those. What remains outside the gate is fixture *behaviour*: a fixture that compiles against a
changed type and asserts the wrong thing still needs the suite to run.

Four consequences bind this doctrine:

- **A fixture that hand-authors a serialized form of a production type is a second encoder of that
  type**, and it drifts silently when the type is tightened — the defect class in
  [chaos_hardening_doctrine.md § 23](./chaos_hardening_doctrine.md). Derive the fixture from the
  production value through the one canonical renderer instead, so a schema change is a compile error
  rather than a runtime decode failure. On 2026-08-08 four hand-written Tier-0 encoders existed and
  a one-field tightening broke twenty cases. Sprint `5.30` landed the subtractive fix:
  `test/support/Tier0Fixture.hs` is the only module in the test tree that produces Tier-0 document
  text, its type is opaque, and the escape hatch for text that genuinely cannot be a value carries a
  *checked* reason — with no "not yet migrated" arm, because that state is the defect. The pairing
  matters: a derived fixture makes drift a compile error, and `--enable-tests` makes something
  compile it; neither half alone would have caught the tightening.
- **A fixture server answers or refuses; it never closes silently.** Converting a typed failure into
  an exception that escapes before any byte is written replaces a diagnosable answer with a network
  error, and — if the accept loop does not guard it — takes every later request in the test with it.
  Keep the failure a value and render it as a response carrying its reason.
- **Positive fake observations derive from the production projection they are compared against.**
  A fake `ResourceQuota`, `LimitRange`, replica set, or other observed object must not restate the
  production projection as hand-maintained literals. Render the positive fixture from that
  projection. A scenario that deliberately violates the projection remains explicit: construct a
  named invalid value or perturbation so the test states which invariant it breaks instead of
  disguising the invalid value as ordinary fixture state.
- **A fixture reaches the boundary named by its test.** Every unrelated prerequisite fixture must
  be valid enough for execution to reach that boundary. A test of a Credential Provisioner refusal,
  for example, must not stop first on an empty substrate coordinate. Deliberately invalid
  prerequisite values belong only in a case that names and asserts that prerequisite refusal.
- **A generated deployment fixture names where every value came from.** Externally chosen
  test-deployment values enter through the harness-only `test-secrets.dhall`; ephemeral identities,
  endpoints, and roots derive from the validated `prodbox.test.dhall` variant/run id; fixed protocol
  or product identities import their single production declaration. A Haskell literal is not a
  fourth source. Pure negative tests use reserved/synthetic constructors from `TestSupport`, while
  live values are injected through the fixture schema. The complete partition is owned by
  [test_topology_doctrine.md §3](./test_topology_doctrine.md#3-test-run-drives-the-real-deploy-path-across-every-variant).

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

## 7. Clean-Room Migration Fixtures

The Sprint 6.4 fixture is a versioned exact-prefix trace, not a mutable snapshot script. Each
interruption fixture records only the completed action prefix; replay must derive the identical
first missing action. Skips, reordering, duplicate boundaries, post-completion suffixes, and
post-cutover legacy rollback are refusal cases. The installed-binary validation also runs the
repository doctrine scan and checks that every retired gateway/host-direct transport source path is
absent. Real cluster deletion and consecutive aggregates remain deployment-qualification evidence,
not substitutes for these deterministic fixtures.

## Cross-References

- [Unit Testing Policy](./unit_testing_policy.md)
- [AWS Integration Environment Doctrine](./aws_integration_environment_doctrine.md)
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md)
- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)

## Current-Revision Invite Fixture

`control-plane-counterexample` emits the frozen and replacement identities plus the complete
invite schema dimensions. Its installed-binary output records 23 mandatory invite fault points,
eight invite assertions, and `QualificationPendingLiveEvidence`. This fixture validates schema,
command registration, and fail-closed status only; it is never accepted as a live aggregate or
deployment-qualified artifact.
