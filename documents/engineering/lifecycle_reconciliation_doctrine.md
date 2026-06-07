# Lifecycle Reconciliation Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../../CLAUDE.md](../../CLAUDE.md),
[../../README.md](../../README.md), [the engineering doctrine docs](../../documents/engineering/README.md),
[acme_provider_guide.md](acme_provider_guide.md),
[../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md),
[../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md),
[../../DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md),
[../../DEVELOPMENT_PLAN/system-components.md](../../DEVELOPMENT_PLAN/system-components.md),
[README.md](README.md),
[aws_integration_environment_doctrine.md](aws_integration_environment_doctrine.md),
[cli_command_surface.md](cli_command_surface.md),
[pure_fp_standards.md](pure_fp_standards.md),
[secret_derivation_doctrine.md](secret_derivation_doctrine.md),
[storage_lifecycle_doctrine.md](storage_lifecycle_doctrine.md),
[unit_testing_policy.md](unit_testing_policy.md)
**Generated sections**: none

> **Purpose**: Single Source of Truth for how prodbox lifecycle commands
> prevent AWS resource leaks. Names the resource leak classes, sets the
> rule that Pulumi state lifetime must match resource lifetime per class,
> and defines the reconciler-with-predicates pattern every destructive
> lifecycle command composes.

## 1. Leak Classes

Every AWS resource any prodbox flow may create or destroy belongs to
exactly one of these classes. Cleanup ownership is defined per class.

| Class | Examples | Tracked by | Cluster-tag signature | Cleanup owner |
|---|---|---|---|---|
| 1. Pulumi-tracked stack resources | `aws-eks` VPC, EKS cluster, node group; `aws-test` EC2 nodes; `aws-eks-subzone` Route 53 records; `aws-ses` SES identity, DKIM, S3 capture bucket, SMTP IAM user | The Pulumi stack file (MinIO backend for per-run, S3 backend for long-lived; see §2) | Stack-name tag and `pulumi:project` tag | `prodbox pulumi <stack>-destroy --yes` (canonical per stack) |
| 2. CSI-driver-created EBS volumes | The MinIO PVC EBS volume in EKS; any future StatefulSet PVC | None — created via the Kubernetes API by `ebs.csi.aws.com` | `kubernetes.io/cluster/<cluster-name>: owned`, `ebs.csi.aws.com/cluster-name: <cluster-name>` | K8s drain phase (Sprint 4.12); fallback postflight tag sweep |
| 3. AWS Load Balancer Controller resources | ALBs, NLBs, target groups, and security groups created in response to `Service type=LoadBalancer` and `Ingress` resources | None — created via the AWS API by the LBC pod | `kubernetes.io/cluster/<cluster-name>: owned`, `elbv2.k8s.aws/cluster`, `ingress.k8s.aws/stack` | K8s drain phase (Sprint 4.12); fallback postflight tag sweep |
| 4. cert-manager DNS01 records | `_acme-challenge.<host>` TXT records in Route 53 during ACME issuance | None — created via the Route 53 API by the cert-manager solver | Record name pattern `_acme-challenge.*` | K8s drain phase (Sprint 4.12) handles graceful clean-up by deleting `Certificate` resources first; fallback is the postflight tag sweep |
| 5. Direct `aws` CLI shell-out records | DNS bootstrap A records created by `src/Prodbox/CLI/Rke2.hs:2484` and `src/Prodbox/TestValidation.hs:1547` | None — written directly via `aws route53` subprocess | None reliably; identified by content (configured public FQDN) | Best-effort cleanup paths in the same modules; fallback is the postflight tag sweep |

The K8s drain phase plus the postflight tag sweep together make
classes 2–5 leak-safe. The drain runs **before** any Pulumi destroy so
the controllers are still alive to unwind their AWS-side state (see
§5b for the canonical cascade order); the sweep runs **after** the
destroys and fails the command with the leak list when anything
cluster-tagged survives. On the AWS substrate the drain must target
the EKS API server, not the local RKE2 cluster — see §5b
"Substrate-aware drain". A drain that runs against the wrong cluster
silently skips the in-cluster controller cleanup, and the subsequent
Pulumi destroy fails with `DependencyViolation` on subnet deletion as
ENIs / ALBs / EBS volumes block the underlying network teardown.

## 2. State-Lifetime Rule

**Pulumi state lifetime must match resource lifetime per class.**

| Class | Backend | URL shape | Lifetime |
|---|---|---|---|
| Per-run stacks (`aws-eks`, `aws-eks-subzone`, `aws-test`) | MinIO in-cluster | `s3://prodbox-test-pulumi-backends?endpoint=127.0.0.1:39000&disableSSL=true&s3ForcePathStyle=true` | Dies with the cluster, by design |
| Long-lived shared stacks (`aws-ses`, and any future cross-substrate long-lived stack) | Dedicated AWS S3 bucket configured via `pulumi_state_backend` in `prodbox-config.dhall` | `s3://<bucket_name>/<key_prefix>?region=<region>` | Independent of any cluster; durable across operator-machine churn |

The dedicated S3 bucket is itself a long-lived shared resource owned
by the operator AWS account. It lives in the same lifecycle class as
the `aws-ses` capture bucket and the operator-owned parent Route 53
zone.

**Per-run state survives cluster wipes via `.data/` preservation.** MinIO runs from a
host-pathed PV under `.data/minio/...`
([storage_lifecycle_doctrine.md](storage_lifecycle_doctrine.md) §1, §7). Whenever
`.data/` is preserved (the default for both `prodbox rke2 delete --yes` and
`prodbox rke2 delete --cascade --yes`), MinIO's bucket contents — the per-run Pulumi
state, and the gateway-owned master seed at `prodbox/master-seed` — persist across the
cluster cycle. This is what makes `prodbox rke2 delete --allow-pulumi-residue` a
leak-free recovery shape: abandon the cluster with state intact in MinIO; rebuild RKE2
on the same `.data/`; MinIO returns with the same bucket data; `prodbox pulumi
<stack>-destroy --yes` releases the AWS resources cleanly. No permanent leak even
under abnormal teardown sequences.

**Configuration.** The bucket and region are declared in
`prodbox-config.dhall` under the `pulumi_state_backend` block. The
schema lives in `prodbox-config-types.dhall` (record type
`PulumiStateBackend` with `bucket_name : Text`, `region : Text`,
`key_prefix : Text`). Empty defaults force the operator to set
`bucket_name` and `region` before any long-lived stack operation can
succeed; the `ensureLongLivedPulumiStateBucket` precondition returns
a structured error pointing at the config keys when either is empty.

**Bootstrapping the bucket.** Pulumi cannot manage its own backend
bucket. The bucket is created by an idempotent admin-credentialed
operation — implemented as `ensureLongLivedPulumiStateBucket` in
`src/Prodbox/Infra/LongLivedPulumiBackend.hs`, invoked as a precondition
by every command that touches a long-lived stack
(`prodbox pulumi aws-ses-resources`, `prodbox pulumi aws-ses-destroy`,
`prodbox nuke`). Required bucket properties: versioning enabled,
server-side encryption with AES256 (S3-managed keys; KMS is overkill
and entangles key lifecycle), block-all-public-access on, lifecycle
rule to expire non-current versions after 90 days. Tagged
`prodbox.io/purpose=pulumi-state`, `prodbox.io/substrate=shared`.

**Credentials per class.**

| Class | Credential block | Source field in `prodbox-config.dhall` |
|---|---|---|
| Per-run stacks | Operational `aws.*` | `aws.access_key_id`, `aws.secret_access_key` (populated by `prodbox aws setup`, cleared by `prodbox aws teardown`) |
| Long-lived stacks + bucket bootstrap | Admin `aws_admin_for_test_simulation.*` | `aws_admin_for_test_simulation.access_key_id`, `aws_admin_for_test_simulation.secret_access_key` (long-lived; never cleared by any teardown command) |

Long-lived stack management uses admin credentials because admin creds
outlive any single cluster cycle, matching the state lifetime. The
operational `prodbox` IAM user does not need `s3:GetObject`/`PutObject`
permission on the state bucket.

**Migration recipe** (one-time, per long-lived stack):

1. Bring up the MinIO backend (`prodbox rke2 reconcile`).
2. `pulumi stack export --stack <name>` against the current MinIO backend.
3. `pulumi login s3://<bucket>/<prefix>?region=<region>` (after
   `ensureLongLivedPulumiStateBucket` has run).
4. `pulumi stack import --file <export>.json` into the new backend.

The operator command `prodbox pulumi aws-ses-migrate-backend` wraps
this recipe and is idempotent: if `aws-ses` state is already on S3,
the command is a no-op.

**Rule.** No new Pulumi stack may be added to any prodbox code path
without first deciding its lifetime class, selecting the matching
backend, and matching the credential class. The class assignment must
appear in
[../../DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)
and the code-side list (`Prodbox.Aws.perRunStackNames` /
`longLivedStackNames`) in the same change.

## 3. The Reconciler-with-Predicates Pattern

Five layered patterns. No global state machine — every destructive
lifecycle command in prodbox composes these layers, in this order, with
no shared in-memory state.

1. **Source-of-truth queries.** Each resource class has a `discover` IO
   action that asks the authoritative source. No in-memory shadow
   state. The canonical example for Pulumi residue is the
   `<stack>ResidueStatus :: ... -> IO ResidueStatus` family in
   `src/Prodbox/Infra/Aws*Stack.hs` (introduced in Sprint 4.16): each
   per-run stack queries its MinIO Pulumi backend; the long-lived
   `aws-ses` stack queries the S3 backend. The result ADT is

   ```haskell
   data ResidueStatus
     = ResidueAbsent
     | ResiduePresent ResidueDetails
     | ResidueUnreachable ResidueUnreachableReason
   ```

   `Unreachable` is the credential-free "we cannot tell" signal that
   the pre-Sprint-4.16 file-existence predicate
   (`<stack>HasLiveResources = doesFileExist .prodbox-state/<stack>/
   stack-snapshot.json`) used to approximate. How callers interpret
   `Unreachable` depends on whether they are a **gate** or the
   **cascade orchestration**, and this is deliberate:

   - **Gate callers fail closed** (Sprint 4.19). The refuse-path
     preconditions for `prodbox rke2 delete` (default) and
     `prodbox aws teardown` treat per-run `Unreachable` as a refusal:
     "I could not read the per-run Pulumi state" is **not** the same
     as "the resources are gone." Treating it as absent previously let
     `rke2 delete --yes` silently pass on a degraded cluster (MinIO pod
     down, per-run state still intact on `.data/`); the subsequent
     operator `rm .data` then destroyed the only record of live AWS
     resources. Long-lived `Unreachable` (S3) has always failed closed
     for the same reason.
   - **The cascade degrades gracefully.** `prodbox rke2 delete
     --cascade`'s own `perRunCascadeInventory` treats per-run
     `Unreachable` as absent — the cascade is tearing the cluster down
     regardless, and the postflight tag sweep (§6) is its backstop for
     any AWS-side residue. The cascade does not route through the gate
     preconditions.

   Other discoverers added by Sprints
   4.11–4.12: `discoverClusterTaggedAwsResources` (AWS Resource
   Tagging API), `discoverK8sAwsAffectingResources` (kubectl).

   **Source-of-truth queries must tolerate the case where the source
   is already gone.** Destructive lifecycle commands run against
   partially- or fully-torn-down infrastructure routinely (operator
   reruns, partial-teardown recovery, first-time provisioning). A
   `discover` whose authoritative source is unreachable returns a
   distinct "not present" / "skipped" outcome that the caller treats
   as success-with-reason, not failure. The Kubernetes-side drain
   discoverer makes this explicit through the `DrainResult` ADT in
   `src/Prodbox/Lifecycle/K8sDrain.hs`:

   - **`DrainSucceeded`** — the cluster was reachable, the targeted
     K8s resources were deleted, and the bounded poll loop observed
     them gone before the deadline. No surviving K8s objects.
   - **`DrainSkipped <reason>`** — the cluster was unreachable on the
     quick probe `kubectl cluster-info --request-timeout=5s`. No
     delete was attempted; the cascade caller treats this as a
     success-with-reason and proceeds to the next phase (per-run
     Pulumi destroys talk to AWS, not kubectl). The probe classifies
     **any** non-zero exit or subprocess `Failure` as unreachable —
     it does not parse stderr. Pre-flight reachability checks are
     deliberately cheap and stateless; they exist only to gate the
     subsequent destructive subprocess invocations.
   - **`DrainFailed <error>`** — the cluster was reachable AND a
     delete-or-poll step errored. This is the only outcome that
     fails the cascade.

   The same skip-on-unreachable rule applies to any future
   `discover` whose source can be absent during a destructive run
   (the operator's parent Route 53 zone if the operator account is
   torn down, future EKS-side discoverers, etc.). Each such
   `discover` exposes the three-outcome ADT pattern (succeeded /
   skipped-with-reason / failed) rather than collapsing
   skipped+succeeded into a single boolean.
2. **Composable precondition algebra.** Each named `Precondition`
   wraps one `discover` and returns `IO (Either StructuredError ())`.
   Predicates are composed with `checkAll [...]`. Existing example:
   `checkPulumiResidueBeforeTeardown` at `src/Prodbox/Aws.hs:1572`,
   generalized into `src/Prodbox/Lifecycle/Preconditions.hs` in
   Sprint 4.11.
3. **Reconciler loop**, not strict sequence. `discover → diff → enact
   → re-observe` until stable or timeout. Idempotent by construction.
   Matches the `prodbox rke2 reconcile` doctrine for the install path.
4. **Bracket-style ownership** for transient handles. Already used at
   `src/Prodbox/Infra/MinioBackend.hs:144` (`withMinioPortForward`).
   Reused for the kubectl drain session (Sprint 4.12) and the S3
   backend env-var session (Sprint 4.10).
5. **Phase ADT for narration**, not state. A flat ADT names the
   sequential phases for dry-run output and structured error
   reporting. Example shape:
   ```haskell
   data DeletePhase
     = DrainK8s
     | DestroyPulumiPerRun
     | UninstallRke2
     | PostflightTagSweep
     deriving (Eq, Show)
   ```
   This is the `LifecycleAction` pattern from
   [pure_fp_standards.md §2.1](pure_fp_standards.md). The ADT is a
   list of named transitions, not a stateful machine.

### Why not a global state machine

A global state machine would have to model the cross-product of every
sub-resource's status: rke2 up/down × MinIO up/down × four Pulumi
stacks × three classes of K8s-created AWS resource × operational IAM
user × DNS-bootstrap records. The authoritative state lives in
external systems (AWS, the local filesystem, the kube API) that this
program cannot refresh transactionally. Any in-memory model would go
stale the moment AWS returned eventually-consistent results; crash
recovery would force a rediscover anyway, at which point the machine
adds coupling without adding safety.

The reconciler is "data in, data out": each `discover` is
independently testable, each `Precondition` composes, and the doctrine
generalizes to any new resource class by adding one `discover` and one
`Precondition`. No existing command needs to know about new commands.

The data-oriented strengthening of this — chosen deliberately *instead
of* a state machine — is the managed-resource registry below: it keeps
"data in, data out," adds no shared in-memory state, and makes the
"add one `discover` + one destroy per resource" rule **total and
machine-enforced** rather than a convention.

### 3.1 The managed-resource registry (the reconciler substrate)

Every leak we have hit was one of two failures, neither of which a
state machine fixes: (a) a **fail-open predicate** — a `discover` whose
"cannot observe" outcome silently collapsed to "absent/clean" (e.g. the
pre-Sprint-4.19 per-run gate, and the file-existence proxy before
Sprint 4.16); or (b) **incomplete coverage** — a resource the system can
create that has no registered `discover`/destroy at all (the operational
`prodbox` IAM user, the operational `aws.*` config block, fixed-name IAM
left by a partial `pulumi up`; see §6a). The registry closes both
structurally.

**The registry is a single, pure list of typed managed resources** — the
SSoT for "everything prodbox can create, and how to observe and destroy
it." Conceptual shape (canonical names land with the implementation
sprint):

```haskell
-- Example: the registry entry shape
data LifecycleClass = PerRun | LongLived | Operational
data ManagedResource = ManagedResource
  { resourceName     :: String
  , resourceClass    :: LifecycleClass
  , resourceDiscover :: IO ResidueStatus   -- Present | Absent | Unreachable (§3 layer 1)
  , resourceDestroy  :: IO (Either StructuredError ())
  }
managedResources :: [ManagedResource]      -- the single source of truth
```

It reuses, not replaces, the existing pieces: the three-valued
`ResidueStatus` (§3 layer 1), the composable `Precondition`/`checkAll`
algebra (§3 layer 2), the `Plan`/`Apply` discipline, and the
declare-and-interpret shape of the Effect DAG. The per-class stack-name
lists (`Prodbox.Aws.perRunStackNames` / `longLivedStackNames`, §2) are
**derived from** the registry by class so they cannot drift from it.

Three invariants make the topology leak-proof and idempotent:

1. **Totality.** No prodbox code path may create an AWS or cluster
   resource that is not in the registry with a `discover` and a
   `destroy`. This is enforced in `check-code` (registry ↔
   [`substrates.md` Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)
   parity, plus a create-call-site coverage scan), the same mechanism
   that already enforces the generated-section registry and the
   subprocess boundary. "A creatable-but-undiscoverable resource" is
   made unrepresentable.
2. **Soundness.** `Unreachable` ("cannot observe") is never silently a
   passing decision. A single combinator maps a `discover` result to a
   gate decision with `Unreachable → refuse` (the Sprint 4.19 rule,
   generalized to every gate). The cascade keeps its documented
   graceful-degradation exception (`perRunCascadeInventory`, §5b).
3. **Idempotent reconciliation.** Teardown is one reconciler,
   `reconcileAbsent`, over a class subset of the registry: for each
   resource `Present → destroy → re-observe`, `Absent → skip`,
   `Unreachable → refuse`. `prodbox rke2 delete` reconciles `PerRun`;
   `prodbox aws teardown` reconciles `PerRun` ∪ `Operational`;
   `prodbox nuke` reconciles all classes. Re-running converges instead
   of erroring; built on `Plan`/`runPlanWithOptions` so `--dry-run`
   works uniformly.

This is the data-oriented "make illegal states unrepresentable"
answer, not a global state machine: the registry is pure data, every
`discover` queries the appropriate external authority at the moment of
use, and crash recovery is just "re-run the reconciler."

The public-edge **production** certificate is a worked example of this
registration (Sprint 4.24). Its S3-retained material — written to the
substrate-scoped key `public-edge-tls/<substrate>/<fqdn>` in the
long-lived `pulumi_state_backend` S3 bucket and restored before every
issuance — is a registered `LongLived` managed resource with a typed
`discover` (read the retained object) and `destroy`, and
`Unreachable → refuse` gate semantics. That soundness rule (§3.1
invariant 2) is exactly the guarantee restored by closing the
`ChartPlatform.hs` `preservePublicEdgeTlsSecretBeforeDelete`
silent-success gap: an unobservable owned certificate must refuse, never
collapse to "absent/clean." Classified `LongLived` like `aws-ses`, it is
never auto-destroyed by `prodbox rke2 delete` or `prodbox aws teardown`
and is removed only by `prodbox nuke`. The certificate lifecycle and the
production-vs-staging two-issuer model live in
[acme_provider_guide.md](./acme_provider_guide.md); its lifecycle-class
row is in
[../../DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).

The scheduling of this doctrine into code is owned by
[DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md)
Sprints 4.20–4.22 and
[phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
Sprint 7.8.

## 4. Predicate Library Inventory

Named `Precondition` values every destructive lifecycle command may
compose. The library lives at `src/Prodbox/Lifecycle/Preconditions.hs`
(introduced in Sprint 4.11). Sprints 4.20–4.21 (§3.1) generalize these
into the registry's `reconcileAbsent` reconciler — each predicate
becomes a class subset of the managed-resource registry — so this table
is the per-resource view of one uniform mechanism, not a parallel one.

| Predicate | Returns `Left` when | Used by |
|---|---|---|
| `noLivePerRunPulumiStacks` | Any of `aws-eks`, `aws-eks-subzone`, `aws-test` returns `ResiduePresent` (live resources — refuse with the per-stack destroy command) **or** `ResidueUnreachable` (the per-run MinIO state backend could not be read — refuse with a distinct "cannot confirm destroyed; do not delete `.data/`; re-run with `--allow-pulumi-residue` to accept the orphan risk" message). Sprint 4.19 made this gate **fail closed on `ResidueUnreachable`**: "cannot read the state" is not "the resources are gone." | `prodbox rke2 delete` (default), `prodbox aws teardown` (default; see also `noLiveLongLivedPulumiStacks`) |
| `noLiveLongLivedPulumiStacks` | `aws-ses` returns `ResiduePresent` against its S3 backend, **or** `ResidueUnreachable` (S3 unreachable is a real failure for long-lived stacks; failing closed is the correct behavior) | `prodbox aws teardown` (default); `prodbox nuke` (handled by destroying not refusing) |
| `noLiveClusterTaggedAws` | The AWS Resource Tagging API returns any resource carrying `kubernetes.io/cluster/<cluster-name>` | Postflight of `prodbox rke2 delete --cascade` and `prodbox nuke` |
| `noUndrainedK8sAwsResources` | `kubectl` reports any LoadBalancer Service, ALB Ingress, or Delete-reclaim PVC that hasn't been drained, **and** the cluster was reachable on the pre-drain `kubectl cluster-info --request-timeout=5s` probe | Postflight of K8s drain (Sprint 4.12); preflight of per-run Pulumi destroys when `--cascade` is set |

The `noUndrainedK8sAwsResources` predicate returns `Left` only on the
`DrainFailed` arm of the `DrainResult` ADT (see §3 layer 1).
`DrainSucceeded` and `DrainSkipped` are both preflight success: the
former because every targeted K8s resource is gone, the latter
because the cluster controllers that would have owned AWS resources
are already gone. The cascade is safe to continue after either
outcome — the postflight tag sweep (§6) is the backstop that catches
any AWS-side residue left by a `DrainSkipped` cascade.
| `noLiveOperationalIamUser` | The operational `prodbox` IAM user exists | Postflight of `prodbox aws teardown` and `prodbox nuke` |
| `noLeftoverDnsBootstrapRecords` | The configured public FQDN has stale prodbox-written Route 53 records | Postflight of `prodbox rke2 delete --cascade` and `prodbox nuke` |

`aws-ses` is **explicitly excluded** from `noLivePerRunPulumiStacks`.
`prodbox rke2 delete` ignores `aws-ses` residue because §2 places its
state outside the cluster; `aws-ses` may only be destroyed by
`prodbox pulumi aws-ses-destroy --yes` or `prodbox nuke`.

## 5. Mandatory Preflight for Destructive Commands

Every command in
`{prodbox rke2 delete, prodbox aws teardown, prodbox pulumi
<stack>-destroy, prodbox nuke}` must open with `checkAll [...]` over
the appropriate `Precondition` set. Failure renders the structured
leak list and the canonical remedy command per offending class. The
preflight runs **before** any cluster-side or AWS-side work so the
operator-named remedy commands actually still work (the cluster /
backend / credentials are still up at the point of refusal).

| Command | Preflight predicates | Default on residue |
|---|---|---|
| `prodbox rke2 delete` | §5a no-install short-circuit, then `noLivePerRunPulumiStacks` | Refuse with list and per-stack destroy command (or run `--cascade` for "orchestrate the full teardown") |
| `prodbox rke2 delete --cascade` | §5a no-install short-circuit, then none at entry — the command **is** the orchestration | Confirm-MinIO → per-run destroys → drain → uninstall → sweep (see §5b) |
| `prodbox aws teardown` | `noLivePerRunPulumiStacks`, `noLiveLongLivedPulumiStacks` (Sprint 7.6) | Refuse with list and per-stack destroy command |
| `prodbox pulumi <stack>-destroy` | (none beyond Pulumi's own dependency check) | n/a |
| `prodbox nuke` | TTY refusal; typed-confirmation literal `NUKE EVERYTHING`; otherwise no residue refusal — the command **is** the total-teardown orchestration | Drain + destroy all stacks + IAM teardown + uninstall + sweep |

### 5a. No-Install Short-Circuit (Sprint 4.25)

`prodbox rke2 delete` opens — in **both** the default and `--cascade` forms — by
probing whether an RKE2 install is present on the host *before* the preflight
predicate (or, for `--cascade`, the confirm-MinIO phase) runs. When no install is
found it prints `No RKE2 cluster to delete.` and exits `0`.

"Present" is the logical OR of the on-disk install markers (`/usr/local/bin/rke2`,
`/usr/local/bin/rke2-uninstall.sh`, `/var/lib/rancher/rke2`, `/etc/rancher/rke2`),
evaluated by `rke2InstallPresent` in `src/Prodbox/CLI/Rke2.hs`. The probe keys off
**install** state, not **service** state: an installed-but-stopped RKE2 still has a
cluster and per-run state on disk to delete and therefore still flows through the
full gate / cascade.

This is a **no-op short-circuit** ("there is nothing to delete, so I am done"),
categorically distinct from a `Precondition` ("I cannot proceed until X is
satisfied"). It is **not** a relaxation of the Sprint 4.19 fail-closed gate (§4):
the gate's `ResidueUnreachable → refuse` rule still applies in full whenever an
RKE2 install exists. The short-circuit only resolves the degenerate case where the
cluster — and with it the in-cluster MinIO state backend — is already entirely
gone, which the gate alone cannot distinguish from "MinIO is transiently
unreachable while a cluster still exists". Because the short-circuit takes no
destructive action, `.data/` (and any per-run Pulumi state it still holds) is left
untouched.

### 5b. Canonical Cascade Order

`prodbox rke2 delete --cascade --yes` orchestrates these phases in order. The order is
deliberate and matches §1: the K8s drain runs **before** any per-run Pulumi destroy so
the in-cluster controllers (AWS Load Balancer Controller, EBS CSI driver,
cert-manager) are still alive to unwind their AWS-side state. Only then does Pulumi
delete the substrate (VPC, subnets, EKS cluster), at which point the controller-owned
ENIs / ALBs / EBS volumes are already gone and Pulumi's deletes have no dependencies
to trip on.

| # | Phase | What it does | Failure mode |
|---|---|---|---|
| 1 | Confirm MinIO reachable | `<stack>ResidueStatus` queries the MinIO backend for each per-run stack. If MinIO is reachable, the result is `ResidueAbsent` or `ResiduePresent`; if unreachable, the result is `ResidueUnreachable` and the cascade treats per-run residue as absent (the per-run state died with the cluster, per the per-run lifetime class). | Misclassification is impossible because `ResidueUnreachable` for a per-run stack is by definition the same outcome as "the state is gone". |
| 2 | K8s drain | Delete LoadBalancer Services, ALB Ingresses, and Delete-reclaim PVCs so the in-cluster controllers unwind their AWS-side state (Sprint 4.12). On the AWS substrate the drain MUST target the EKS API server, not the local RKE2 cluster — see "Substrate-aware drain" below. If the K8s API is unreachable, this phase emits `DrainSkipped` and the cascade proceeds to phase 3 only on the home substrate (where the absent cluster cannot have created new AWS resources). On the AWS substrate, `DrainSkipped` is a hard failure because the EKS cluster is the source of the resources Pulumi is about to fail to delete. | `DrainFailed` is the only failure path on the home substrate; `DrainSkipped` is success-with-reason there. On the AWS substrate, both `DrainSkipped` and `DrainFailed` are hard-failure paths. |
| 3 | Per-run Pulumi destroys | For each per-run stack reporting `ResiduePresent`, run `pulumi destroy` against MinIO inside `withMaterializedOperationalCreds` (Sprint 4.17). The bracket fills `aws.*` from `aws_admin_for_test_simulation.*` when `aws.*` is empty and restores-to-empty on exit (success or exception). Because phase 2 already drained the controller-owned resources, every per-run subnet / VPC / cluster delete now has no live ENI / ALB / EBS dependency. | Empty `aws.*` no longer refuses the destroy; the bracket fills it transparently. `DependencyViolation` from AWS indicates phase 2 did not in fact drain (most often: drain ran against the wrong kubeconfig). |
| 4 | RKE2 uninstall | `/usr/local/bin/rke2-uninstall.sh` under the lifecycle-local quiet path. Removes substrate + managed kubeconfig. `.data/` is preserved. | Non-zero uninstall exit is reported through `summarizeRke2DeleteFailure`. |
| 5 | Postflight cluster-tag sweep | `discoverClusterTaggedAwsResources` against the AWS Resource Tagging API. Any surviving cluster-tagged resource fails the command with a structured leak list and the per-class remedy command. | Non-empty leak list is the hard-failure case. |

**Substrate-aware drain.** The drain phase (#2) MUST use the substrate's own
kubeconfig — `KUBECONFIG=/etc/rancher/rke2/rke2.yaml` for `SubstrateHomeLocal`,
`KUBECONFIG=<substrate-kubeconfig-path>` for `SubstrateAws`. The canonical bracket
is `Prodbox.PublicEdge.withSubstrateKubectlEnvironment` which also sets the
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_DEFAULT_REGION` /
`AWS_SESSION_TOKEN` env vars that `aws eks get-token` (the EKS kubeconfig's exec
provider) needs to authenticate. A drain phase that hard-codes the local-cluster
kubeconfig on the AWS substrate walks the wrong cluster, reports nothing to drain,
and lets phase 3 fail with `DependencyViolation` on subnet deletion.

This is the doctrine-canonical order. The pre-Sprint-4.17.a sequence
(destroys → drain) inverted phases 2 and 3 and was harmless on the home substrate
(no in-cluster controllers create AWS resources) but fatal on the AWS substrate
(LBC / EBS CSI controllers create ENIs / ALBs / EBS volumes; destroying the EKS
cluster before draining them produces orphan resources that block subnet deletion).
The postflight tag sweep (phase 5) is the backstop for any controller-created AWS
resources that escape the drain, not a substitute for running the drain first.

### 5c. Per-Run EKS Destroy Drains the Cluster First (Sprint 4.23)

The drain-before-destroy invariant of §5b applies not only to the `--cascade`
orchestration but to the **per-run `aws-eks-test` Pulumi destroy itself**. As of
Sprint 4.23, `Prodbox.Infra.AwsEksTestStack.destroyAwsEksTestStackStatus` runs a
best-effort K8s drain (LoadBalancer Services, ALB Ingresses, Delete-reclaim PVCs)
against the per-run EKS cluster's own kubeconfig immediately **before** `pulumi
destroy`. Because both the harness postflight (`prodbox pulumi eks-destroy --yes`
from `awsPostflightDestroyActions`) and the cascade
(`Prodbox.Lifecycle.ResourceRegistry.reconcileAbsent` → `PulumiEksDestroy`) route
through this destroy, the drain covers both paths — closing the gap where the
harness postflight's per-run EKS destroy raced AWS's async ENI cleanup and hit
`DependencyViolation: subnet … has dependencies and cannot be deleted` (the May
28/29 incidents). This extends Sprint 4.17.b's substrate-aware cascade drain to the
per-run destroy path, targeting the per-run EKS cluster rather than the host
substrate's cluster.

The per-run drain is **best-effort and safe when the cluster is unreachable**: an
absent EKS kubeconfig or an unreachable cluster skips the drain with a diagnostic
and proceeds to the destroy, and a drain failure / timeout never hard-fails the
destroy (the destroy is the goal). This differs from the cascade's AWS-substrate
`DrainSkipped`-is-hard-failure rule (§5b phase 2) because the per-run destroy is the
last line of defense and must always attempt to run; the worst case on a skipped
drain is the pre-4.23 `DependencyViolation`, which §5d's credential-preservation
then makes recoverable.

### 5d. Harness Postflight Preserves Operational Creds on Per-Run Destroy Failure (Sprint 7.10)

The `prodbox test ...` harness postflight (`Prodbox.TestRunner.runWithAwsHarnessCleanup`)
runs the per-run Pulumi destroys on every exit path (Sprint 7.6 orphan-safety) and
then, historically, always cleared operational `aws.*` and deleted the operational
`prodbox` IAM user via `runManagedAwsHarnessTeardown`. As of Sprint 7.10 the
operational-credential teardown runs **only when the per-run destroy succeeded**
(pure decision `clearOperationalCredsAfterPostflight :: ExitCode -> Bool`, `True`
iff `ExitSuccess`). When a per-run destroy fails (e.g. the §5c
`DependencyViolation` before Sprint 4.23 fully closes it), the orphaned per-run
stacks still hold live AWS resources whose destroy path requires operational creds;
clearing those creds would strand the orphans. The postflight therefore **holds**
the teardown, preserves operational `aws.*` + the operational user, and emits a
diagnostic naming the recovery path: resolve the destroy failure (e.g. wait out /
clean up the orphan ENIs), then `prodbox pulumi <stack>-destroy --yes` for each
remaining per-run stack, then `prodbox aws teardown`. The per-run destroy failure is
still surfaced as a non-zero exit.

This is the per-run analog of §5's Sprint 7.9 change: Sprint 7.9 stopped the
teardown from **refusing** on admin-managed `aws-ses` residue (clearing operational
creds cannot strand the admin-credential `aws-ses` stack); Sprint 7.10 **holds** the
teardown when the per-run auto-destroy — which *does* need operational creds —
failed. The two are complementary safety rules on the same teardown.

## 6. Mandatory Postflight Tag Sweep

Every destructive lifecycle command must end with a call to
`discoverClusterTaggedAwsResources` (and, for the long-lived classes,
the equivalent long-lived-tag query). A non-empty result is a hard
failure: the command reports the leak list, the canonical remedy
command per leaked class, and exits non-zero. This is the only layer
that catches K8s-operator-created AWS resources that escape the drain.

The tag sweep lives at `src/Prodbox/Lifecycle/TagSweep.hs` (introduced
in Sprint 4.11; extended for the full cluster-tag scan in Sprint 4.12).

### 6a. The Tag Sweep Does Not Cover IAM (known blind spot)

The postflight tag sweep queries the **AWS Resource Groups Tagging API**,
which does **not** return IAM resources (policies, roles, users) — and
even if it did, the per-run IAM resources are not cluster-tagged. So the
tag sweep is **not** a backstop for orphaned IAM residue. The IAM residue
class is:

- Fixed-name per-run IAM (`aws-eks-test-aws-lb-controller` policy/role,
  `aws-eks-test-ebs-csi-driver` role) and auto-named EKS cluster/node
  roles (`clusterRole-*`, `nodeRole-*`) left when a `pulumi up` partially
  succeeds and its state is then lost (the create-then-crash window, or a
  `.data/` wipe / cluster crash before the per-run `pulumi destroy`).
- The operational `prodbox` IAM user, owned by `prodbox aws setup` /
  `aws teardown` (not by `rke2 delete`); an interrupted run can leave it.

How the doctrine handles this class without scanning AWS behind Pulumi
(an anti-pattern) and without an auto-sweep (which would mask genuine
leaks):

1. **Register the durable classes (§3.1).** The operational `prodbox`
   IAM user and the operational `aws.*` config block become registered
   `Operational` resources in the managed-resource registry, each with
   a `discover` (`aws iam get-user` / config-non-empty) and a `destroy`
   (the existing delete/clear paths) — so `aws teardown`'s
   `reconcileAbsent` pass observes and reconciles them like any other
   resource, and `check-code` totality refuses any future create without
   a registered counterpart. This closes the *coverage* half of the
   blind spot for everything except the irreducible residual below.
2. **Prevent new silent leaks.** Sprint 4.19's fail-closed delete gate
   (§3 layer 1, §4) — generalized by §3.1's soundness invariant —
   refuses `rke2 delete` / `aws teardown` when the per-run Pulumi state
   backend is unreachable, so an interrupted-state teardown can no
   longer report "clean" and let `.data/` be wiped out from under live
   resources. New divergence is surfaced, not hidden.
3. **The irreducible residual is operator-cleaned.** The one case the
   registry cannot observe is a fixed-name resource created by a partial
   `pulumi up` whose state was then lost (create-then-crash; a Pulumi
   atomicity gap, not a prodbox one) — because its only intended
   `discover` is "query Pulumi state," which is gone. This is removed
   via the bounded escape hatch (targeted `aws iam delete-policy` /
   `delete-role` / `delete-user`), the documented exception to the
   "harness owns AWS" rule. A live operator cleanup of this class was
   performed 2026-05-28 (see
   [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md) Closure
   Status). The long-lived `aws-ses` stack is the bounded configured-name
   exception: `prodbox pulumi aws-ses-resources` can repair missing Pulumi
   state by importing the retained capture bucket / SMTP IAM user / SES receipt
   resources and rotating stale SMTP access keys, because those names are
   operator-configured or hard-coded by the long-lived stack contract. Generic
   per-run residue remains deliberately **not** closed with an AWS-name-scanning
   detector (an anti-pattern) or an auto-sweep (which would mask genuine leaks).

This residual is recorded as a class in
[DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).

## 7. What Is Out of Scope for `rke2 delete`

`aws-ses`, the operator's parent Route 53 zone, the long-lived
`pulumi_state_backend` bucket, and any other long-lived shared
infrastructure never participate in `rke2 delete`'s residue policy.
The only sanctioned paths to destroy them are:

- `prodbox pulumi aws-ses-destroy --yes` for the `aws-ses` stack
  (operator-driven, explicit, never automatic).
- `prodbox nuke` for total teardown of every prodbox-owned AWS
  resource, including long-lived ones. TTY-only, no `--yes`
  shorthand, requires the typed confirmation literal `NUKE EVERYTHING`.
- Manual operator action against the parent Route 53 zone (it is
  operator-managed; the harness does not own it).

The long-lived state bucket is created idempotently by
`ensureLongLivedPulumiStateBucket` and destroyed only by
`prodbox nuke`'s final pass — never by `aws teardown`, never by
`rke2 delete`, never as a side effect of any other command.

## Related Documents

- [README.md](README.md)
- [aws_integration_environment_doctrine.md](aws_integration_environment_doctrine.md)
- [cli_command_surface.md](cli_command_surface.md)
- [pure_fp_standards.md](pure_fp_standards.md)
- [unit_testing_policy.md](unit_testing_policy.md)
- [../documentation_standards.md](../documentation_standards.md)
- [../../DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md)
- [../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md)
- [../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
- [the engineering doctrine docs](../../documents/engineering/README.md)
- [../../CLAUDE.md](../../CLAUDE.md)
