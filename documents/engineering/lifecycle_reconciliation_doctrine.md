# Lifecycle Reconciliation Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../../CLAUDE.md](../../CLAUDE.md),
[../../README.md](../../README.md), [the engineering doctrine docs](../../documents/engineering/README.md),
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
the controllers are still alive to unwind their AWS-side state; the
sweep runs **after** the destroys and fails the command with the leak
list when anything cluster-tagged survives.

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
   stack-snapshot.json`) used to approximate. The new ADT exposes the
   distinction explicitly: per-run callers treat `Unreachable` as
   absent (per-run state dies with the cluster); long-lived callers
   treat `Unreachable` as a refusal (S3 unreachable is a real failure
   that needs operator attention). Other discoverers added by Sprints
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

## 4. Predicate Library Inventory

Named `Precondition` values every destructive lifecycle command may
compose. The library lives at `src/Prodbox/Lifecycle/Preconditions.hs`
(introduced in Sprint 4.11).

| Predicate | Returns `Left` when | Used by |
|---|---|---|
| `noLivePerRunPulumiStacks` | Any of `aws-eks`, `aws-eks-subzone`, `aws-test` returns `ResiduePresent` against its MinIO backend. `ResidueUnreachable` is treated as absent for per-run stacks because their state lives with the cluster. | `prodbox rke2 delete` (default), `prodbox aws teardown` (default; see also `noLiveLongLivedPulumiStacks`) |
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
| `prodbox rke2 delete` | `noLivePerRunPulumiStacks` | Refuse with list and per-stack destroy command (or run `--cascade` for "orchestrate the full teardown") |
| `prodbox rke2 delete --cascade` | none at entry — the command **is** the orchestration | Confirm-MinIO → per-run destroys → drain → uninstall → sweep (see §5b) |
| `prodbox aws teardown` | `noLivePerRunPulumiStacks`, `noLiveLongLivedPulumiStacks` (Sprint 7.6) | Refuse with list and per-stack destroy command |
| `prodbox pulumi <stack>-destroy` | (none beyond Pulumi's own dependency check) | n/a |
| `prodbox nuke` | TTY refusal; typed-confirmation literal `NUKE EVERYTHING`; otherwise no residue refusal — the command **is** the total-teardown orchestration | Drain + destroy all stacks + IAM teardown + uninstall + sweep |

### 5b. Canonical Cascade Order

`prodbox rke2 delete --cascade --yes` orchestrates these phases in order. The order is
deliberate: MinIO-tracked AWS resources are released **before** the local cluster is
uninstalled, so the cascade always reaches AWS through a still-reachable Pulumi
backend.

| # | Phase | What it does | Failure mode |
|---|---|---|---|
| 1 | Confirm MinIO reachable | `<stack>ResidueStatus` queries the MinIO backend for each per-run stack. If MinIO is reachable, the result is `ResidueAbsent` or `ResiduePresent`; if unreachable, the result is `ResidueUnreachable` and the cascade treats per-run residue as absent (the per-run state died with the cluster, per the per-run lifetime class). | Misclassification is impossible because `ResidueUnreachable` for a per-run stack is by definition the same outcome as "the state is gone". |
| 2 | Per-run Pulumi destroys | For each per-run stack reporting `ResiduePresent`, run `pulumi destroy` against MinIO inside `withMaterializedOperationalCreds` (Sprint 4.17). The bracket fills `aws.*` from `aws_admin_for_test_simulation.*` when `aws.*` is empty and restores-to-empty on exit (success or exception). | Empty `aws.*` no longer refuses the destroy; the bracket fills it transparently. |
| 3 | K8s drain | Delete LoadBalancer Services, ALB Ingresses, and Delete-reclaim PVCs so the in-cluster controllers unwind their AWS-side state (Sprint 4.12). If the K8s API is unreachable, this phase emits `DrainSkipped` and the cascade proceeds to phase 4 — the controllers can't have created new AWS resources after the cluster died. | `DrainFailed` is the only failure path; `DrainSkipped` is success-with-reason. |
| 4 | RKE2 uninstall | `/usr/local/bin/rke2-uninstall.sh` under the lifecycle-local quiet path. Removes substrate + managed kubeconfig. `.data/` is preserved. | Non-zero uninstall exit is reported through `summarizeRke2DeleteFailure`. |
| 5 | Postflight cluster-tag sweep | `discoverClusterTaggedAwsResources` against the AWS Resource Tagging API. Any surviving cluster-tagged resource fails the command with a structured leak list and the per-class remedy command. | Non-empty leak list is the hard-failure case. |

The cascade order replaces the pre-Sprint-4.17 sequence (drain → destroys → uninstall),
which had drain before destroys. The new order trades a small amount of "destroys may
race the in-cluster LB controller's last cleanup" for the explicit guarantee that the
operator-named cascade phrase "releases AWS resources before deleting the cluster"
matches what actually happens. The postflight tag sweep is the backstop for any
controller-created AWS resources that fail to drain in time.

## 6. Mandatory Postflight Tag Sweep

Every destructive lifecycle command must end with a call to
`discoverClusterTaggedAwsResources` (and, for the long-lived classes,
the equivalent long-lived-tag query). A non-empty result is a hard
failure: the command reports the leak list, the canonical remedy
command per leaked class, and exits non-zero. This is the only layer
that catches K8s-operator-created AWS resources that escape the drain.

The tag sweep lives at `src/Prodbox/Lifecycle/TagSweep.hs` (introduced
in Sprint 4.11; extended for the full cluster-tag scan in Sprint 4.12).

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
