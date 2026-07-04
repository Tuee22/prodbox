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
[unit_testing_policy.md](unit_testing_policy.md),
[vault_doctrine.md](vault_doctrine.md),
[resource_scaling_doctrine.md](resource_scaling_doctrine.md),
[pulsar_topic_lifecycle_doctrine.md](pulsar_topic_lifecycle_doctrine.md),
[host_platform_doctrine.md](host_platform_doctrine.md),
[cluster_topology_doctrine.md](cluster_topology_doctrine.md),
[test_topology_doctrine.md](test_topology_doctrine.md)
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
| 1. Pulumi-tracked stack resources | `aws-eks` VPC, EKS cluster, node group; `aws-test` EC2 nodes; `aws-eks-subzone` Route 53 records; `aws-ses` SES identity, DKIM, S3 capture bucket, SMTP IAM user | The encrypted Pulumi checkpoint object (Sprint `7.14`; see §2) | Stack-name tag and `pulumi:project` tag | `prodbox aws stack <stack> destroy --yes` (canonical per stack) |
| 2. Pre-created retained EBS volumes (static `Retain` PVs) | The durable EBS volumes lifted in as static `Retain` PVs on EKS (MinIO, Vault, `keycloak-postgres`/Patroni, `vscode`); **no dynamic provisioning** | Registered managed-resource with typed `discover`/`destroy` (Sprint `4.39`); the retained set is the EBS analog of `.data/` | `prodbox.io/managed-by: prodbox` plus a retain-vs-test-scoped role marker; test volumes additionally carry `kubernetes.io/cluster/<cluster-name>: owned` | Retained by **all** cluster/stack teardown (they are `Retain` and not Pulumi-owned); test-scoped volumes deleted only by the suite postflight reaper, `cluster delete --cascade` reaper hook, or `prodbox aws ebs reap-test --yes` (Sprint `4.40`). See [storage_lifecycle_doctrine.md](storage_lifecycle_doctrine.md) § 1, § 5 |
| 3. AWS Load Balancer Controller resources | ALBs, NLBs, target groups, and security groups created in response to `Service type=LoadBalancer` and `Ingress` resources | None — created via the AWS API by the LBC pod | `kubernetes.io/cluster/<cluster-name>: owned`, `elbv2.k8s.aws/cluster`, `ingress.k8s.aws/stack` | K8s drain phase (Sprint 4.12); fallback postflight tag sweep |
| 4. cert-manager DNS01 records | `_acme-challenge.<host>` TXT records in Route 53 during ACME issuance | None — created via the Route 53 API by the cert-manager solver | Record name pattern `_acme-challenge.*` | K8s drain phase (Sprint 4.12) handles graceful clean-up by deleting `Certificate` resources first; fallback is the postflight tag sweep |
| 5. Direct `aws` CLI shell-out records | DNS bootstrap A records created by `src/Prodbox/CLI/Rke2.hs:2484` and `src/Prodbox/TestValidation.hs:1547` | None — written directly via `aws route53` subprocess | None reliably; identified by content (configured public FQDN) | Best-effort cleanup paths in the same modules; fallback is the postflight tag sweep |

The K8s drain phase plus the postflight tag sweep together make
classes 3–5 leak-safe; class 2 is made leak-safe instead by the
retained-EBS managed-resource contract. The drain runs **before** any
Pulumi destroy so the controllers are still alive to unwind their
AWS-side state (see §5b for the canonical cascade order); the sweep
runs **after** the destroys and fails the command with the leak list
when anything cluster-tagged survives. Class 2 EBS volumes are
deliberately **not** unwound by the drain: they are static `Retain`
PVs, preserved across teardown exactly like `.data/`, and are deleted
only by the test-suite postflight reaper, cascade reaper hook, or
`prodbox aws ebs reap-test --yes` for test-scoped volumes
(Sprints `4.39`, `4.40`; the legacy dynamic `gp2` path that this
supersedes is tracked in
[../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)).
On the AWS substrate the drain must target the EKS API server, not the
local RKE2 cluster — see §5b "Substrate-aware drain". A drain that runs
against the wrong cluster silently skips the in-cluster controller
cleanup, and the subsequent Pulumi destroy fails with
`DependencyViolation` on subnet deletion as ENIs / ALBs block the
underlying network teardown.

## 2. State-Lifetime Rule

**Pulumi state lifetime must match resource lifetime per class.**

| Class | Checkpoint store | Runtime backend URL shape | Lifetime |
|---|---|---|---|
| Per-run stacks (`aws-eks`, `aws-eks-subzone`, `aws-test`) | Opaque Model-B object in MinIO `prodbox-state` | Scratch `file://<tmp>` backend hydrated by `Prodbox.Pulumi.EncryptedBackend` | Auto-managed by the harness; persistent checkpoint survives while `.data/` is preserved |
| Long-lived shared stacks (`aws-ses`, and any future cross-substrate long-lived stack) | Opaque Model-B object in MinIO `prodbox-state` for main paths | Scratch `file://<tmp>` backend hydrated by `Prodbox.Pulumi.EncryptedBackend` | Long-lived resource class; destroyed only by explicit long-lived teardown |

The dedicated S3 bucket configured by `pulumi_state_backend` is still a long-lived shared resource
owned by the operator AWS account, but it is no longer the main Pulumi checkpoint backend. It stores
retained public-edge TLS material and remains available as the optional first-touch import source
for old `aws-ses` checkpoints when encrypted state is absent.

**Per-run state survives cluster wipes via `.data/` preservation.** MinIO runs from a
host-pathed PV under `.data/prodbox/minio/0`
([storage_lifecycle_doctrine.md](storage_lifecycle_doctrine.md) §1, §7). Whenever
`.data/` is preserved (the default for both `prodbox cluster delete --yes` and
`prodbox cluster delete --cascade --yes`), MinIO's bucket contents — including encrypted Pulumi
checkpoint objects and gateway-owned object-store data — persist across the cluster cycle. This
is exactly why the **default `prodbox cluster delete` is a pure local
uninstall** that never touches the per-run AWS backend: abandoning the cluster leaves the
state intact in MinIO; rebuild RKE2 on the same `.data/`; MinIO returns with the same
bucket data; `prodbox aws stack <stack> destroy --yes` (or `prodbox cluster delete
--cascade`) releases the AWS resources cleanly. No permanent leak even under abnormal
teardown sequences.

**Retained S3 compatibility store.** The `pulumi_state_backend` block in
`prodbox-config.dhall` declares the long-lived S3 bucket still used for public-edge TLS retention
and as the optional first-touch source for old `aws-ses` Pulumi checkpoints. The schema lives in
`prodbox-config-types.dhall` (record type `PulumiStateBackend` with `bucket_name : Text`,
`region : Text`, `key_prefix : Text`). Empty defaults force the operator to set `bucket_name` and
`region` before a command that still touches that retained S3 store can succeed; the
`ensureLongLivedPulumiStateBucket` precondition returns a structured error pointing at the config
keys when either is empty.

**Bootstrapping the retained bucket.** The retained bucket is created by an idempotent
admin-credentialed operation — implemented as `ensureLongLivedPulumiStateBucket` in
`src/Prodbox/Infra/LongLivedPulumiBackend.hs`. Required bucket properties: versioning enabled,
server-side encryption with AES256 (S3-managed keys; KMS is overkill and entangles key lifecycle),
block-all-public-access on, lifecycle rule to expire non-current versions after 90 days. Tagged
`prodbox.io/purpose=pulumi-state`, `prodbox.io/substrate=shared`.

**Credentials per class.** This table is the per-stack credential-class SSoT; the SecretRef
model, the two-file config split, and the test-fixture classification are owned by
[vault_doctrine.md §3, §4, §13](vault_doctrine.md) and the
`aws_admin_for_test_simulation` block specifics by
[aws_admin_credentials.md](aws_admin_credentials.md) — this section only assigns each stack a
class.

| Class | Credential class | How the credential is obtained |
|---|---|---|
| Per-run stacks | Generated operational `prodbox` IAM credential | The least-privilege `aws.*` identity, minted into Vault KV (`secret/gateway/gateway/aws`); `prodbox-config.dhall` carries only a `SecretRef.Vault` reference, never the plaintext key. Materialized for the run by `prodbox aws setup`, cleared by `prodbox aws teardown`. |
| Long-lived stacks + retained-bucket compatibility | Ephemeral elevated/admin credential | Supplied at runtime through the one interactive `SecretRef.Prompt` arm — held in memory for one command, used once, then discarded. It is never written to `prodbox-config.dhall`, never stored in Vault. In tests the harness simulates that prompt by feeding `aws_admin_for_test_simulation.*` from `test-secrets.dhall` (a `TestPlaintext` fixture, not a production-config section). |

Long-lived stack management uses the elevated/admin credential because that level of power
outlives any single cluster cycle, matching the resource lifetime; there is no stored admin
block in `prodbox-config.dhall` — real ops prompt for the ephemeral elevated credential and the
harness simulates that prompt from `test-secrets.dhall`. The generated operational `prodbox` IAM
user does not need `s3:GetObject`/`PutObject` permission on the retained S3 bucket. Migrating any
code path off the stored-admin model is scheduled as Sprint `7.16`.

**Legacy checkpoint migration.** First-touch migration is owned by
`Prodbox.Pulumi.EncryptedBackend`. When the encrypted `LogicalPulumiStack <stack-id>` object is
absent, the wrapper can log into a configured legacy backend, export the old checkpoint into a
temporary file, hydrate scratch from those bytes, and remove the legacy stack only after the
supported Pulumi action and encrypted store/delete succeed.

The operator command `prodbox aws stack aws-ses migrate-backend` is kept as a TTY-only
compatibility entrypoint while old `aws-ses` checkpoints may still exist. It now opens the same
encrypted scratch backend as reconcile/destroy and triggers the first-touch import/delete path; it
does not run raw MinIO-to-S3 `pulumi stack export` / `pulumi stack import`.

**Rule.** No new Pulumi stack may be added to any prodbox code path
without first deciding its lifetime class, selecting the matching
backend, and matching the credential class. The class assignment must
appear in
[../../DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)
and the code-side SSoT in the same change: every Pulumi-managed stack is one
`Prodbox.Infra.StackDescriptor` record (`stackRegistryName` / `stackPulumiStackId` /
`stackProjectSubdir` / `stackCliVerb` / `stackLifecycleClass`, Sprint `4.27`), from which
`Prodbox.Aws.perRunStackNames` and the CLI verbs / project dirs derive; the long-lived
class (which spans more than stacks — it includes the non-stack `public-edge-tls` cert)
is `Prodbox.Aws.longLivedResourceNames`.

## 3. The Reconciler-with-Predicates Pattern

Five layered patterns. No global state machine — every destructive
lifecycle command in prodbox composes these layers, in this order, with
no shared in-memory state.

1. **Source-of-truth queries.** Each resource class has a `discover` IO
   action that asks the authoritative source. No in-memory shadow
   state. The canonical example for Pulumi residue is the
   `<stack>ResidueStatus :: ... -> IO ResidueStatus` family in
   `src/Prodbox/Infra/Aws*Stack.hs` (introduced in Sprint 4.16): each
   per-run stack and the long-lived `aws-ses` stack query their encrypted Pulumi checkpoints.
   The result ADT is

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

   - **Gate callers fail closed.** A residue refuse-path treats
     `Unreachable` as a refusal: "I could not read the Pulumi state" is
     **not** the same as "the resources are gone." This applies to
     `prodbox aws teardown`'s long-lived gate (`noLiveLongLivedPulumiStacks`)
     and is honored when the cascade queries per-run residue. Note a
     never-created backend bucket or missing encrypted checkpoint is **not**
     `Unreachable` — it is positive evidence of `Absent` (nothing to
     destroy), classified as such for both encrypted checkpoint and retained-bucket reads.
     (Default `prodbox cluster delete` no longer carries a per-run
     refuse-path at all — it is a pure local uninstall — so this
     fail-closed rule is moot there.)
   - **The cascade degrades gracefully.** `prodbox cluster delete
     --cascade`'s own `perRunCascadeInventory` treats per-run
     `Unreachable` as absent. This is a *documented exception* to the
     "`Unreachable` ('cannot observe') is never silently a passing
     decision" invariant above, scoped to per-run stacks only: the
     cascade is tearing the cluster down regardless, a per-run stack's
     `Unreachable` is by definition the same outcome as "the state died
     with the cluster" (§5b step 1), and the postflight tag sweep (§6)
     is the hard-fail backstop for any AWS-side residue. The cascade
     does not route through the gate preconditions.

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
   Matches the `prodbox cluster reconcile` doctrine for the install path.
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
`prodbox` IAM user, the generated operational `aws.*` Vault KV credential
and its `SecretRef.Vault` reference in `prodbox-config.dhall`, fixed-name
IAM left by a partial `pulumi up`; see §6a). The registry closes both
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
declare-and-interpret shape of the Effect DAG. The per-class name lists
(`Prodbox.Aws.perRunStackNames`, derived from the `StackDescriptor` SSoT;
`Prodbox.Aws.longLivedResourceNames`, derived from the registry by class so it can
include non-stack resources such as `aws-ebs-volumes` and the `public-edge-tls` cert)
cannot drift from their sources.

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

   **Dependent-resource refinement (Sprint 7.24).** The `operational-aws-config`
   resource is the Vault-stored credential *for* the `operational-iam-user`. Its
   `discover` resolves a `SecretRef.Vault`, so at harness *preflight* — before the
   cluster (hence Vault) is up — it can only return `Unreachable`. The fail-closed
   rule exists to avoid stranding the IAM **user**, and that user is observed
   authoritatively through the admin credential (`operationalIamUserExists`), which
   does not depend on Vault. So `refineAwsConfigResidueAgainstIamUser` downgrades a
   `Unreachable` aws-config to `Absent` **only when the IAM user is confirmed
   `Absent`** — a credential for a user that no longer exists cannot strand
   anything. This is **not** a relaxation of `Unreachable → refuse`: when the user
   is `Present` or itself `Unreachable`, the aws-config status is preserved and the
   gate still refuses. The refinement is keyed on the authoritative, Vault-independent
   observation of the safety-critical resource, never on presuming an unobservable
   resource is gone.
3. **Idempotent reconciliation.** Teardown is one reconciler,
   `reconcileAbsent`, over a class subset of the registry: for each
   resource `Present → destroy → re-observe`, `Absent → skip`,
   `Unreachable → refuse`. `prodbox cluster delete --cascade` reconciles
   `PerRun` (default `cluster delete` is a pure local uninstall and
   reconciles nothing); `prodbox aws teardown` reconciles `Operational`
   (gating long-lived via `noLiveLongLivedPulumiStacks`);
   `prodbox nuke` reconciles all classes. Re-running converges instead
   of erroring; built on `Plan`/`runPlanWithOptions` so `--dry-run`
   works uniformly.
4. **Plan-option totality.** Every destructive command routes its work
   through `runPlanWithOptions`, so `--dry-run` and `--plan-file` are
   honored uniformly — `prodbox cluster delete` (the default local
   uninstall and `--cascade`), `prodbox aws teardown`, and `prodbox nuke`
   included. This is the intended Sprint 4.26 invariant: a `check-code`
   lint, `checkPlanOptionsHonored`, forbids any destructive dispatch arm
   from binding the `PlanOptions` argument to a `_` wildcard (which would
   silently drop `--dry-run` / `--plan-file`). The rule is total — "a
   destructive command that ignores its plan options" is made
   unrepresentable, the same way invariant 1 makes
   "a creatable-but-undiscoverable resource" unrepresentable. The
   cascade's per-run sweep is **derived from** `perRunManagedResources`
   (the registry SSoT for the `PerRun` class) rather than a hand-maintained
   stack list, so the rendered `--dry-run` plan and the executed sweep can
   never omit a per-run stack. The gate's `(stack, destroy-command)` list
   and the destroy actions share one registry-derived source
   (`pairPerRunResidue` / `pairAwsSesResidue` + `residueGateRefusalList`).

This is the data-oriented "make illegal states unrepresentable"
answer, not a global state machine: the registry is pure data, every
`discover` queries the appropriate external authority at the moment of
use, and crash recovery is just "re-run the reconciler."

This registry substrate is reused, not re-derived, by later doctrines:
[resource_scaling_doctrine.md § 7](./resource_scaling_doctrine.md#7-scaling-is-a-reconciled-managed-resource)
models a desired scaled shape as a reconciled managed resource with a three-valued `discover`,
[pulsar_topic_lifecycle_doctrine.md § 1](./pulsar_topic_lifecycle_doctrine.md#1-a-topic-is-a-managed-resource)
registers each Pulsar topic as a managed resource with a typed `discover`/`destroy` and a
`LifecycleClass`, and
[test_topology_doctrine.md § 5](./test_topology_doctrine.md#5-teardown-is-finally-guaranteed-and-reuses-the-lifecycle-classes)
reuses the `PerRun` / `LongLived` partition for finally-guaranteed test teardown.

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
never auto-destroyed by `prodbox cluster delete` or `prodbox aws teardown`
and is removed only by `prodbox nuke`. The certificate lifecycle and the
production-vs-staging two-issuer model live in
[acme_provider_guide.md](./acme_provider_guide.md); its lifecycle-class
row is in
[../../DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).

The scheduling of this doctrine into code is owned by
[DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md)
Sprints 4.20–4.22 and
[phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
Sprints 7.8, 7.21, and 7.22.

### 3.2 The destroy-invocation gate and corrupt-checkpoint prune

§3.1's soundness rule classifies a per-run stack's *residue* by observing its
encrypted checkpoint read-only (`observeStackCheckpoint` →
`classifyCheckpointBytes` → `Prodbox.Lifecycle.LiveResidue.queryOne`, Sprint
7.21). That funnel guards the *observation* — the cascade's `reconcileAbsent`,
the teardown gates, and the per-stack residue helpers. It does **not**, by
itself, guard the direct per-run **destroy-invocation** path (`prodbox aws
stack <stack> destroy --yes`, which the harness preflight/postflight also
issues): that path runs `destroy<Stack>Status`, which historically fetched
stack outputs (`pulumi stack output`) and read MinIO credentials before any
residue check, so a corrupt checkpoint crashed it with `unexpected end of JSON
input`, and a substrate without the in-cluster `minio` k8s secret crashed it
with `secrets "minio" not found`.

Sprint 7.22 closes that gap: each `destroy<Stack>Status` consults the same
read-only observation **first**, through the pure
`Prodbox.Lifecycle.LiveResidue.perRunDestroyDecisionFromStatus`:

- **Absent / empty** → skip (`PerRunDestroySkip`): nothing to destroy. This is
  the home-substrate steady state — the per-run AWS stacks were never
  provisioned — so the destroy returns success without touching `pulumi` or
  the in-cluster `minio` secret.
- **Present** → proceed (`PerRunDestroyProceed`) with the real destroy body.
- **Corrupt / unreadable** → refuse (`PerRunDestroyRefuse`), the §3.1
  soundness rule: a corrupt or unobservable checkpoint may hide live AWS
  resources, so it is fail-closed, never a silent skip. The refusal names the
  prune recovery.

The residue observation (and therefore this gate) resolves MinIO credentials
from Vault `secret/minio/root`, not the in-cluster `minio` k8s secret, so the
gate is reachable on any substrate whose Vault is unsealed — eliminating the
`secrets "minio" not found` failure mode on substrates that never provisioned
the per-run stacks.

**Corrupt-checkpoint prune.** A genuinely-corrupt (or empty) per-run checkpoint
— e.g. a truncated Model-B object left by an interrupted run — would otherwise
refuse forever. `prodbox aws stack <stack> prune-corrupt-checkpoint --yes`
(`Prodbox.Lifecycle.LiveResidue.pruneCorruptPerRunCheckpoint`) is the
doctrine-clean recovery: it observes the checkpoint and deletes the opaque
Model-B object **only** when it is corrupt or empty (idempotent no-op when
already absent), and **refuses** to prune a `Present` checkpoint (which may map
to live AWS resources — use `destroy` for that) or an unobservable backend
(fail-closed). Per-run stacks only; a corrupt long-lived `aws-ses` checkpoint
always refuses.

## 4. Predicate Library Inventory

Named `Precondition` values every destructive lifecycle command may
compose. The library lives at `src/Prodbox/Lifecycle/Preconditions.hs`
(introduced in Sprint 4.11). Sprints 4.20–4.21 (§3.1) generalize these
into the registry's `reconcileAbsent` reconciler — each predicate
becomes a class subset of the managed-resource registry — so this table
is the per-resource view of one uniform mechanism, not a parallel one.

| Predicate | Returns `Left` when | Used by |
|---|---|---|
| `noLiveLongLivedPulumiStacks` | `aws-ses` returns `ResiduePresent` against its encrypted checkpoint, **or** (Sprint 4.24) the `public-edge-tls` retained certificate returns `ResiduePresent` against the long-lived bucket, **or** either returns `ResidueUnreachable` (unreachable long-lived evidence is a real failure; failing closed is the correct behavior) | `prodbox aws teardown` (default); `prodbox nuke` (handled by destroying not refusing — the certificate transitively via the whole-bucket destroy) |
| `noLiveClusterTaggedAws` | The AWS Resource Tagging API returns any resource carrying `kubernetes.io/cluster/<cluster-name>` | Postflight of `prodbox cluster delete --cascade` and `prodbox nuke` |
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
| `noLeftoverDnsBootstrapRecords` | The configured public FQDN has stale prodbox-written Route 53 records | Postflight of `prodbox cluster delete --cascade` and `prodbox nuke` |

`aws-ses` is **explicitly excluded** from every `cluster delete` path:
its state lives outside the cluster (§2), so `aws-ses` may only be
destroyed by `prodbox aws stack aws-ses destroy --yes` or `prodbox nuke`.

Default `prodbox cluster delete` carries **no per-run residue preflight at
all** — it is a pure local cluster uninstall that preserves `.data/` (the
MinIO-backed per-run Pulumi state) and never queries, gates on, or
destroys the per-run AWS backend. Deleting the cluster does not affect the
ability to reason about that state (it survives on `.data/`), so there is
nothing to fail closed on. All per-run AWS destruction is `--cascade`'s
job (which reconciles `PerRun` via `reconcileAbsent`, degrading gracefully
on an unreachable backend) or the explicit
`prodbox aws stack <name> destroy --yes`.

## 5. Mandatory Preflight for Destructive Commands

Every command in
`{prodbox cluster delete, prodbox aws teardown, prodbox aws stack
<stack> destroy, prodbox nuke}` must open with `checkAll [...]` over
the appropriate `Precondition` set. Failure renders the structured
leak list and the canonical remedy command per offending class. The
preflight runs **before** any cluster-side or AWS-side work so the
operator-named remedy commands actually still work (the cluster /
backend / credentials are still up at the point of refusal).

| Command | Preflight predicates | Default on residue |
|---|---|---|
| `prodbox cluster delete` | §5a no-install short-circuit, then a pure local uninstall (no per-run residue preflight) | n/a — uninstalls the cluster, preserves `.data/`, leaves per-run AWS stacks untouched |
| `prodbox cluster delete --cascade` | §5a no-install short-circuit, then none at entry — the command **is** the orchestration | Confirm-MinIO → drain → per-run destroys → test-EBS reaper → uninstall → sweep (see §5b) |
| `prodbox aws teardown` | `noLiveLongLivedPulumiStacks` (Sprint 7.6) | Refuse with list and per-stack destroy command |
| `prodbox aws stack <stack> destroy` | (none beyond Pulumi's own dependency check) | n/a |
| `prodbox nuke` | TTY refusal; typed-confirmation literal `NUKE EVERYTHING`; otherwise no residue refusal — the command **is** the total-teardown orchestration | Drain + destroy all stacks (per-run **and** long-lived `aws-ses` + state bucket, per §7) + IAM teardown + uninstall + step-4 fail-closed tag sweep (§6) |

### 5a. No-Install Short-Circuit (Sprint 4.25)

`prodbox cluster delete` opens — in **both** the default and `--cascade` forms — by
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

### 5a.1. Inotify Host-Prep (first host-prep step)

Immediately after the §5a no-install short-circuit confirms an RKE2 install is
present — and **before** the preflight predicate (default form) or the confirm-MinIO
phase (`--cascade`) — both delete forms run `ensureHostInotifyLimits`. It is the same
idempotent host-prep step that opens `prodbox cluster reconcile`: it persists
`/etc/sysctl.d/99-prodbox-inotify.conf` (`fs.inotify.max_user_instances = 8192`,
`fs.inotify.max_user_watches = 1048576`) and applies it via `sysctl --system`, writing
only on drift. The `99-` prefix is deliberate: `sysctl --system` applies drop-ins in
lexicographic filename order (last wins), and `/usr/lib/sysctl.d/30-tracker.conf` pins
`max_user_watches = 65536`, so the drop-in must sort after it to take effect. The kernel
default `max_user_instances = 128` is too low for RKE2 +
containerd + kubelet (all uid 0), so when systemd (PID 1) unwinds the RKE2 units during
teardown it would otherwise log `Failed to allocate directory watch: Too many open files`
to the console. Raising the limit first eliminates that warning at its root rather than
filtering it after the fact (see
[streaming_doctrine.md § 6](./streaming_doctrine.md#6-lifecycle-destructive-success-versus-failure-rule)).
Placing it before the preflight mirrors §5a: it is local-host kernel config, not
cluster-side or AWS-side work, and it is non-destructive and idempotent, so running it
ahead of a possible residue refusal is harmless.

### 5a.2. RKE2 Resource Guardrails (install/reconcile host-prep)

`prodbox cluster reconcile` begins its install/reconcile path by applying the
resource guardrails derived from `capacity.resource_plan`, before installing or
restarting RKE2 and before any chart render can create workloads. The step is
owned by lifecycle because it writes host/RKE2 control-plane files, not chart
manifests:

- `/etc/rancher/rke2/config.yaml.d/90-prodbox-resource-guardrails.yaml` carries
  kubelet args for `system-reserved`, `kube-reserved`, `eviction-hard`,
  `eviction-soft`, image garbage-collection thresholds, and container log caps.
- `/etc/systemd/system/rke2-server.service.d/90-prodbox-resource-guardrails.conf`
  carries accounting plus `CPUQuota`, `MemoryHigh`, `MemoryMax`, and `TasksMax`
  for the RKE2 process tree.

The reconciler observes host cpu, memory, and filesystem capacity first. If the
observed host is smaller than the authored `host_capacity`, it refuses before
mutating these files. This is the runtime counterpart of the static
`rke2.reserved + eviction.floor <= host.physical` lemma in
[resource_scaling_doctrine.md](./resource_scaling_doctrine.md). It bounds
RKE2/kubelet/containerd; pod-level runaway behavior is separately bounded by
the chart-rendered Kubernetes `resources`, `ResourceQuota`, and `LimitRange`.

### 5b. Canonical Cascade Order

`prodbox cluster delete --cascade --yes` orchestrates these phases in order. The order is
deliberate and matches §1: the K8s drain runs **before** any per-run Pulumi destroy so
the in-cluster controllers (AWS Load Balancer Controller, cert-manager) are still
alive to unwind their AWS-side state. Only then does Pulumi delete the substrate (VPC,
subnets, EKS cluster), at which point the controller-owned ENIs / ALBs are already gone
and Pulumi's deletes have no dependencies to trip on. The pre-created retained EBS
volumes are `Retain` and are deliberately preserved (not drained); a detached `Retain`
volume is not a subnet dependency, so it never blocks teardown.

| # | Phase | What it does | Failure mode |
|---|---|---|---|
| 1 | Confirm encrypted checkpoint reachability | `<stack>ResidueStatus` queries the encrypted checkpoint object for each per-run stack. If MinIO and Vault are reachable, the result is `ResidueAbsent` or `ResiduePresent`; if unreachable, the result is `ResidueUnreachable` and the cascade treats per-run residue as absent (the per-run state died with the cluster, per the per-run lifetime class). | Misclassification is impossible because `ResidueUnreachable` for a per-run stack is by definition the same outcome as "the state is gone". |
| 2 | K8s drain | Delete LoadBalancer Services, ALB Ingresses, and any `Delete`-reclaim PVCs so the in-cluster controllers unwind their AWS-side state (Sprint 4.12). The pre-created retained EBS PVs are `Retain` and are intentionally **not** deleted here — deleting a PVC bound to a `Retain` PV never deletes the EBS volume, and the `Delete`-reclaim step is only a generic safety net for any stray dynamic claim. On the AWS substrate the drain MUST target the EKS API server, not the local RKE2 cluster — see "Substrate-aware drain" below. If the K8s API is unreachable, this phase emits `DrainSkipped` and the cascade proceeds to phase 3 only on the home substrate (where the absent cluster cannot have created new AWS resources). On the AWS substrate, `DrainSkipped` is a hard failure because the EKS cluster is the source of the resources Pulumi is about to fail to delete. | `DrainFailed` is the only failure path on the home substrate; `DrainSkipped` is success-with-reason there. On the AWS substrate, both `DrainSkipped` and `DrainFailed` are hard-failure paths. |
| 3 | Per-run Pulumi destroys | For each per-run stack reporting `ResiduePresent`, run `pulumi destroy` against MinIO inside `withMaterializedOperationalCreds` (Sprint 4.17). The bracket materializes operational creds for the run (in tests, via the harness-simulated admin prompt sourced from `test-secrets.dhall`) when `aws.*` is empty and restores-to-empty on exit (success or exception). Because phase 2 already drained the controller-owned resources, every per-run subnet / VPC / cluster delete now has no live ENI / ALB dependency (the retained EBS volumes are `Retain`, detach cleanly, and are not subnet dependencies). | Empty `aws.*` no longer refuses the destroy; the bracket materializes it transparently. `DependencyViolation` from AWS indicates phase 2 did not in fact drain (most often: drain ran against the wrong kubeconfig). |
| 4 | RKE2 uninstall | `/usr/local/bin/rke2-uninstall.sh` under the lifecycle-local quiet path. Removes substrate + managed kubeconfig. `.data/` is preserved. | Non-zero uninstall exit is reported through `summarizeRke2DeleteFailure`. |
| 5 | Postflight cluster-tag sweep | `discoverClusterTaggedAwsResources` against the AWS Resource Tagging API, then `partitionRetainedLongLived` carves out the intentionally-retained long-lived shared-infra classes (`prodbox.io/role=long-lived-pulumi-state` + `prodbox.io/substrate=shared` — the `pulumi_state_backend` bucket + `aws-ses`, which `cluster delete --cascade` keeps by design and only `prodbox nuke` destroys). The structured leak list + per-class remedy is emitted only for the genuine per-run/cluster **escapees** (Sprint `7.26`); `prodbox nuke`'s own step-4 sweep does NOT carve out, since it exists to destroy those resources. | A non-empty **escapee** list is the leak case (best-effort on `--cascade`: reported, does not change the exit code; fail-closed on `nuke`). |

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
(the LBC creates ENIs / ALBs; destroying the EKS cluster before draining them produces
orphan resources that block subnet deletion — the pre-created EBS volumes are `Retain`
and are preserved by design, not orphans).
The postflight tag sweep (phase 5) is the backstop for any controller-created AWS
resources that escape the drain, not a substitute for running the drain first.

### 5c. Per-Run EKS Destroy Drains the Cluster First (Sprint 4.23)

The drain-before-destroy invariant of §5b applies not only to the `--cascade`
orchestration but to the **per-run `aws-eks-test` Pulumi destroy itself**. As of
Sprint 4.23, `Prodbox.Infra.AwsEksTestStack.destroyAwsEksTestStackStatus` runs a
best-effort K8s drain (LoadBalancer Services, ALB Ingresses, Delete-reclaim PVCs)
against the per-run EKS cluster's own kubeconfig immediately **before** `pulumi
destroy`. Because both the harness postflight (`prodbox aws stack eks destroy --yes`
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
clean up the orphan ENIs), then `prodbox aws stack <stack> destroy --yes` for each
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

**The tag sweep is fail-closed.** A sweep that cannot reach the AWS
Resource Tagging API to confirm the absence of cluster-tagged residue is
a hard failure, never a silent pass — the same soundness rule as §3.1
invariant 2 (`Unreachable → refuse`). This applies in particular to
`prodbox nuke`'s step-4 tag sweep (§5, the nuke total-teardown
orchestration): the final tag sweep must fail closed, so an
unconfirmable sweep stops the command with a non-zero exit and a
diagnostic rather than reporting "clean." "Could not observe the
absence of residue" is treated as "residue may be present," never as
"residue is absent."

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
  `aws teardown` (not by `cluster delete`); an interrupted run can leave it.

How the doctrine handles this class without scanning AWS behind Pulumi
(an anti-pattern) and without an auto-sweep (which would mask genuine
leaks):

1. **Register the durable classes (§3.1).** The operational `prodbox`
   IAM user and the generated operational `aws.*` Vault KV credential
   (referenced from `prodbox-config.dhall` only by `SecretRef.Vault`)
   become registered `Operational` resources in the managed-resource
   registry, each with a `discover` (`aws iam get-user` / Vault-KV-present)
   and a `destroy` (the existing delete/clear paths) — so `aws teardown`'s
   `reconcileAbsent` pass observes and reconciles them like any other
   resource, and `check-code` totality refuses any future create without
   a registered counterpart. This closes the *coverage* half of the
   blind spot for everything except the irreducible residual below.
2. **Prevent new silent leaks.** The fail-closed soundness invariant
   (§3 layer 1, §4, §3.1) — `Unreachable → refuse` — applies to
   `aws teardown`'s long-lived gate and to the cascade's per-run query,
   so an interrupted-state teardown can no longer report "clean" and let
   `.data/` be wiped out from under live resources. (Default
   `cluster delete` is a pure local uninstall: it never reports on per-run
   state at all, and preserves `.data/` so nothing is wiped.) New
   divergence is surfaced, not hidden.
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
   exception: `prodbox aws stack aws-ses reconcile` can repair missing Pulumi
   state by importing the retained capture bucket / SMTP IAM user / SES receipt
   resources and rotating stale SMTP access keys, because those names are
   operator-configured or hard-coded by the long-lived stack contract. Generic
   per-run residue remains deliberately **not** closed with an AWS-name-scanning
   detector (an anti-pattern) or an auto-sweep (which would mask genuine leaks).

This residual is recorded as a class in
[DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).

## 7. What Is Out of Scope for `cluster delete`

`aws-ses`, the operator's parent Route 53 zone, the long-lived
`pulumi_state_backend` bucket, and any other long-lived shared
infrastructure never participate in `cluster delete`'s residue policy.
The only sanctioned paths to destroy them are:

- `prodbox aws stack aws-ses destroy --yes` for the `aws-ses` stack
  (operator-driven, explicit, never automatic).
- `prodbox nuke` for total teardown of every prodbox-owned AWS
  resource, including long-lived ones. TTY-only, no `--yes`
  shorthand, requires the typed confirmation literal `NUKE EVERYTHING`.
- Manual operator action against the parent Route 53 zone (it is
  operator-managed; the harness does not own it).

The retained long-lived bucket is created idempotently by `ensureLongLivedPulumiStateBucket` and
destroyed only by `prodbox nuke`'s final pass — never by `aws teardown`, never by `cluster delete`,
never as a side effect of any other command.

## Vault in the cluster lifecycle

Vault is the fail-closed secrets / encryption-as-a-service authority layered
*beneath* the existing reconciler model — it extends, and does not replace, the
managed-resource-registry teardown and the canonical cascade order above. The
in-cluster Vault is the single source of truth for the Vault secret model; this
section records only how the lifecycle commands integrate it. See
[vault_doctrine.md](./vault_doctrine.md) for the full model.

- **Reconcile deploys and unseals Vault first.** `prodbox cluster reconcile`
  deploys (or rebinds) Vault on its durable `.data/`-backed PV, runs `vault init`
  if the backend is empty, unseals from the encrypted unlock bundle (or prompts the
  operator), and runs `vault reconcile` **before** the MinIO and chart reconcile
  phases — so MinIO ciphertext and chart secrets have a live Transit/KV authority by
  the time they are needed. See
  [vault_doctrine.md §7](./vault_doctrine.md#7-vault-lifecycle-commands).
- **Teardown preserves the durable Vault PV.** `prodbox cluster delete --yes` and
  `prodbox cluster delete --cascade --yes` preserve the durable Vault PV exactly
  like the MinIO PV (§2); no `prodbox` command removes it. A wiped-and-rebuilt
  cluster reattaches the same Vault data, mirroring the per-run-state-survives-wipe
  guarantee for MinIO.
- **A sealed Vault is a first-class status line, never hidden.** A sealed or
  unreachable Vault surfaces as an explicit `cluster status` / `edge status` line;
  secret-dependent lifecycle work fails closed behind an explicit readiness gate
  rather than degrading silently. See
  [vault_doctrine.md §15](./vault_doctrine.md#15-sealed-state-behavior-matrix).
- **Pulumi/AWS operations gate on Vault readiness.** Every real `prodbox aws stack ...`
  apply/destroy/migrate action runs the Sprint `1.37` Vault gate before touching state and
  refuses with a redacted sealed-Vault error **before any AWS mutation** when Vault is
  unreachable, uninitialized, or sealed. Dry-runs render the plan without probing Vault. Sprint
  `7.14` extends the same gate with Transit-key and backend-decryptability checks for the encrypted
  Pulumi checkpoint wrapper. See
  [vault_doctrine.md §10](./vault_doctrine.md#10-pulumi-backend-under-vault).

## Related Documents

- [README.md](README.md)
- [aws_integration_environment_doctrine.md](aws_integration_environment_doctrine.md)
- [cli_command_surface.md](cli_command_surface.md)
- [pure_fp_standards.md](pure_fp_standards.md)
- [unit_testing_policy.md](unit_testing_policy.md)
- [Vault Secret-Management Doctrine](./vault_doctrine.md)
- [../documentation_standards.md](../documentation_standards.md)
- [../../DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md)
- [../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md)
- [../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
- [the engineering doctrine docs](../../documents/engineering/README.md)
- [../../CLAUDE.md](../../CLAUDE.md)
