# Integration Fixture Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/unit_testing_policy.md, documents/engineering/aws_test_environment.md, documents/engineering/aws_admin_credentials.md, documents/engineering/aws_integration_environment_doctrine.md, documents/engineering/lifecycle_reconciliation_doctrine.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/test_topology_doctrine.md, DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md, DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md
**Generated sections**: none

> **Purpose**: Define integration setup, teardown, and cleanup ownership for real-system
> validation.

## 0. Canonical Doctrine Statements

- Real-system validation must own its setup and cleanup behavior explicitly.
- Cleanup obligations must be visible in the validation flow, not hidden behind ambient machine
  state.
- Named `prodbox test integration ...` commands may depend on real infrastructure, but their setup
  and cleanup ownership must remain explicit and auditable.
- Long-lived lifecycle class governs cleanup, not desired-presence preparation. A selected
  validation that requires a registered retained resource derives a visible idempotent reconcile
  action and retains that resource during ordinary postflight.

## 1. Scope

This doctrine applies to:

- built-frontend integration suites under `test/integration/`
- native real-world validation flows in `src/Prodbox/TestValidation.hs`
- AWS- and Route-53-backed lifecycle checks
- cluster-backed validation flows that modify shared runtime state

## 2. Fixture Ownership Rules

Ownership rules:

1. The code that allocates real resources owns the primary cleanup path.
2. Command-level postflight repair in `src/Prodbox/TestRunner.hs` owns aggregate supported-runtime
   restoration for destructive suites.
3. AWS-mutating validation flows must clean up resources they create before reporting success.
4. The suite-level IAM harness in `src/Prodbox/TestRunner.hs` owns setup and teardown of
   temporary operational `aws.*` for `prodbox test integration aws-iam`, targeted
   `prodbox test integration <name> --substrate aws` validations,
   `prodbox test integration all`, and `prodbox test all`. **The IAM-harness tier is
   capability-derived (Sprint `5.6`):** `derivedManagedAwsHarnessPolicyTier` in
   `src/Prodbox/TestPlan.hs` engages the harness exactly when a validation declares an
   AWS-credential-consuming prerequisite on the AWS substrate, or is `aws-iam` /
   `keycloak-invite` (which materialize operational credentials on every substrate). The
   former `normalizeManagedAwsHarness` `substrate=aws` blanket override is **deleted**: a
   credential-free validation (e.g. `gateway-partition`) no longer acquires the IAM harness
   merely because the active substrate is AWS.
5. Cleanup failures must be surfaced explicitly to the operator.
6. A retained managed resource required by the selected validations is reconciled through its
   canonical command after its backend is ready; the suite does not hide this mutation in a
   prerequisite and does not add it to per-run cleanup.

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

Sprint `5.17` derives a pure projection from the selected validation set to retained preparation
requirements. `ValidationKeycloakInvite` contributes the registered `aws-ses` capability on both
substrates; validations without invite capability contribute no SES requirement. Reduction removes
duplicates, so aggregate suites still narrate and execute one retained-SES preparation action.

Preparation and cleanup are independent projections over the same managed-resource registry:

- `PerRun` resources may appear in both preparation and finally-guaranteed cleanup.
- `LongLived` resources may appear in preparation when required, but never in ordinary suite
  cleanup.
- Explicit `prodbox aws stack aws-ses destroy --yes` and `prodbox nuke` remain the only supported
  destroy owners for retained SES infrastructure.

The registry side of that split is already concrete:
`Prodbox.Lifecycle.ResourceRegistry.ManagedResource` carries optional `resourceEnsureCommand` and
`resourceEnsurePresent` fields independently from discovery/destruction, and
`desiredPresentManagedResources` contains the registered `awsSesPulumiResource`. The pure
`Prodbox.Lifecycle.DesiredPresence` interpreter consumes the flat presence/checkpoint observations,
enacts one explicit action, and mandates post-enactment re-observation. Sprint `5.17` consumes this
projection through capability-derived suite preparation; it does not recreate a second SES registry
or inline a different ensure path.

Sprint `4.47` also completes the command that projection names. Canonical `aws-ses reconcile`
loads operational `aws.*` only to assume the exact fixed `prodbox-ses-lease-session` role,
acquires/releases the retained-authority lease, recovers global target intents, and mints a bounded
role session for each reconcile, provider/semantic-readiness, and SMTP-repair/materialization
stage. Its fenced encrypted-checkpoint, typed IAM repair, and selected target-sink writes therefore
share one production transaction. The admin simulation fixture remains setup/teardown and destructive-flow
input; it is not a second credential source for reconcile. Sprint `5.17` places this
already-composed command into selected-suite preparation. Sprint `8.10` completes the await through
`Prodbox.Ses.Readiness`: control-plane observations use a lease-scoped role session, while capture
list/get observations use the operational credential consumed by invite polling.

For retained SES, the visible preparation action receives an explicit retained-home
`LongLivedCheckpointAuthority` and a separate selected-substrate `TargetClusterSecretSink`. The
former owns Model-B checkpoint and lease operations; only the latter receives the derived SMTP KV.
No active-gateway or kube-context fallback may substitute one for the other. The authoritative
ordering and external-state ADTs are defined in
[AWS Integration Environment Doctrine §4.6](./aws_integration_environment_doctrine.md#46-retained-ses-desired-presence-preparation)
and
[Lifecycle Reconciliation Doctrine §3.1](./lifecycle_reconciliation_doctrine.md#desired-present-reconciliation-for-long-lived-resources).

`TestRunner` projects the requirement exactly once. A home-local invite suite places the nested
`RestorePrepareRetainedSes RetainedSesPreparationPlan` in the home restore after gateway reconcile.
An AWS invite suite suppresses that plan in the home/control-plane restore and places it in the EKS restore after the
AWS gateway reconcile, using a private EKS kubeconfig, explicit AWS subprocess environment, and a
scoped gateway port-forward for the selected `aws-eks` sink. Both paths prove the exact target
gateway object-store edge through the plan's typed precondition before entering the transaction and
place the plan before VS Code, API, and WebSocket reconcile.

The injected plan interpreter owns only the typed readiness check and one registered atomic ensure;
it does not reproduce the retained transaction. The nested plan exposes the observable stage trace
`acquire -> reconcile -> await-ready -> sync-target -> release`, while the Phase-`4.47` ensure keeps
that trace inside one bracket. Acquire failure prevents later
stages; every failure or interruption after acquisition attempts release; and release failure is
surfaced without erasing an earlier transaction failure. Each bounded await attempt first proves the
complete registered provider inventory and only then runs the semantic sender/DKIM, exact MX,
active receipt-rule, and capture-canary list/get observations. Only `AwsSesPending` repeats;
`AwsSesFailed` and `AwsSesUnobservable` terminate immediately, and exhaustion reports the final
structured Pending reason. Sprint `8.10` supplies this behavior through the existing stage rather
than adding another preparation action.

Prerequisite checks remain read-only. They may reject missing tools, invalid configuration,
unreachable gateway/Vault/object-store dependencies, or unavailable AWS observation, but they may
not create, import, or update SES resources. The mutation is an explicit plan step and its
postcondition is re-observed before SMTP sync. See
[Prerequisite Doctrine §4A](./prerequisite_doctrine.md#4a-prerequisitepreparation-boundary).
`prodbox host check-ses-readiness` exposes the same semantic prerequisite scopes as a read-only
single-observation diagnostic; it never invokes retained-resource reconciliation.

If retained preparation fails after partial AWS mutation, the partial long-lived state remains
retained and the suite reports the failure. A later run re-enters the same idempotent reconciler;
failure, timeout, or Ctrl-C never turns retained SES into a per-run cleanup target. Concurrent suites
serialize the full reconcile/readiness/SMTP-secret transaction through the shared lease rather than
racing account-scoped SES state.

Code-owned Sprint `5.17` closure evidence is 10/10 focused plan/recovery tests, 6/6 explicit
SES target-selection API tests, 12/12 Phase `4.47` global target-commit tests, and 1508/1508 full
unit tests. Sprint `8.10` adds captured-AWS-output classifier and bounded-poll tables plus a built
read-only `host check-ses-readiness` frontend fixture. Fresh-account propagation and a real AWS
invite run remain a distinct, non-blocking live-proof axis.

## 3. Isolation Modes

Supported isolation patterns include:

- fake-tool built-frontend proof in `test/integration/CliSuite.hs`
- fake-trace built-frontend proof for code-owned transport oracles such as `daemon-bootstrap`,
  where live daemon/AWS parity is tracked as a non-blocking substrate proof axis
- repository-local config proof in `test/integration/EnvSuite.hs`
- ephemeral AWS hosted zones or stacks created and destroyed by the named validation flow
- aggregate runtime repair through the public `prodbox` surface after destructive integration work

## 4. Cleanup Failure Handling

Cleanup failures are real failures.

- do not silently swallow cleanup errors
- prefer reporting the validation failure first if both validation and cleanup fail
- still attempt cleanup when safe to do so after a mid-validation failure

## 5. Relationship To Other Doctrine

This document works with:

- [Unit Testing Policy](./unit_testing_policy.md) for test-runner and phase-banner doctrine
- [AWS Integration Environment Doctrine](./aws_integration_environment_doctrine.md) for real AWS
  auth and isolation rules
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md) for desired-present
  and cleanup projections over the managed-resource registry
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
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
