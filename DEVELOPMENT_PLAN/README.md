# prodbox Development Plan

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../AGENTS.md](../AGENTS.md),
[../documents/engineering/README.md](../documents/engineering/README.md),
[the engineering doctrine docs](../documents/engineering/README.md),
[development_plan_standards.md](development_plan_standards.md),
[00-overview.md](00-overview.md), [system-components.md](system-components.md),
[substrates.md](substrates.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md),
[phase-0-planning-documentation.md](phase-0-planning-documentation.md),
[phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md),
[phase-2-gateway-dns.md](phase-2-gateway-dns.md),
[phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md),
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md),
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md),
[phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md),
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md),
[phase-8-email-invite-auth.md](phase-8-email-invite-auth.md)

> **Purpose**: Provide the single execution-ordered development plan for the Haskell rewrite of
> `prodbox`, including phase status, validation gates, and cleanup ownership.

## Standards

See [development_plan_standards.md](development_plan_standards.md) for the maintenance rules that
govern this plan suite.

## Closure Status

**2026-05-29 — Two leak-critical lifecycle fixes landed for the May 28/29
`DependencyViolation` incidents (Sprint 4.23 + Sprint 7.10).** A live `prodbox test all` run
twice leaked AWS resources when the per-run `aws-eks-test` Pulumi destroy hit
`DependencyViolation: subnet … has dependencies and cannot be deleted` (orphan ENIs from the
EKS cluster lagging async cleanup) after a 20-minute wait. Two independent gaps caused the leak,
each now closed:

- **Sprint 4.23 (root cause, 🔄 Active — code-owned surface landed):** the per-run EKS destroy
  path did not drain the EKS cluster's AWS-affecting K8s resources before `pulumi destroy`, so it
  raced AWS's ENI cleanup. `src/Prodbox/Infra/AwsEksTestStack.hs::destroyAwsEksTestStackStatus`
  now calls the new best-effort helper `drainAwsEksClusterBeforeDestroy` (deleting LoadBalancer
  Services, ALB Ingresses, and Delete-reclaim PVCs via the per-run EKS cluster's own kubeconfig)
  immediately before the `pulumi destroy`, reusing
  `Prodbox.Lifecycle.K8sDrain.drainAwsAffectingK8sResources` and a new `buildAwsEksDrainEnv`
  helper mirroring `Rke2.buildDrainEnvironment`. Both the harness postflight
  (`prodbox pulumi eks-destroy --yes`) and the cascade
  (`ResourceRegistry.reconcileAbsent` → `PulumiEksDestroy`) route through this destroy, so the
  injection covers both. Best-effort + safe-on-unreachable: an absent kubeconfig or unreachable
  cluster skips the drain with a diagnostic and proceeds; a drain failure/timeout never hard-fails
  the destroy. Extends Sprint 4.17.b's cascade drain to the per-run destroy path. The live
  closure gate (a `prodbox test all` whose per-run `aws-eks-test` destroy succeeds without
  `DependencyViolation`) is deferred (flaky live-AWS ENI-cleanup timing, not fast-gate-validatable).
- **Sprint 7.10 (amplifier, ✅ Done):** the harness postflight cleared operational `aws.*` +
  deleted the operational `prodbox` IAM user **even when the per-run auto-destroy failed**,
  stranding the orphaned stacks without the operational creds needed to destroy them on retry.
  `src/Prodbox/TestRunner.hs::runWithAwsHarnessCleanup` now runs the operational-credential
  teardown only when the per-run destroy succeeded, gated by the new pure helper
  `clearOperationalCredsAfterPostflight :: ExitCode -> Bool` (`True` iff `ExitSuccess`). On a
  per-run destroy failure the teardown is held, operational `aws.*` + the operational user are
  preserved, and a diagnostic names the recovery path (`prodbox pulumi <stack>-destroy --yes`
  after resolving the destroy failure, then `prodbox aws teardown`). Applies on both the normal
  and async-exception (Ctrl-C) paths; the per-run destroy failure is still surfaced as a non-zero
  exit. This is the per-run analog of Sprint 7.9: 7.9 stopped the teardown from *refusing* on
  admin-managed `aws-ses`; 7.10 *holds* the teardown when the per-run auto-destroy (which needs
  operational creds) failed. New `Sprint 7.10` unit-test describe block (2 tests).

Both validated on the fast gates: `check-code` 0; `test unit` all pass (+2, the `Sprint 7.10`
group); `test integration cli`/`env` exit 0; `docs check`/`lint docs` 0.

**2026-05-29 — Sprint 7.9 landed on the code-owned surface: harness postflight teardown
no longer gates on admin-managed `aws-ses`.** A one-line policy swap in
`src/Prodbox/Aws.hs::runAwsIamHarnessTeardown` (`BypassPerRunResidueOnly` →
`BypassAllResidueForHarnessRefresh`) closes an operational-user stranding bug: every
`prodbox test all` run with the long-lived `aws-ses` stack alive (its retained-by-design
steady state) previously ended with the postflight **refusing** to clear operational
`aws.*`, stranding the freshly-created operational `prodbox` IAM user. The Sprint 7.7
refusal was correct only pre-Sprint-4.10, when `aws-ses` was operationally credentialed;
Sprint 4.10 moved `aws-ses` to admin creds (`aws_admin_for_test_simulation.*`), and Sprint
7.5.c.v.c fixed the *preflight* the same way but deliberately left the postflight stale.
Sprint 7.9 finishes the reconciliation; the postflight now matches the preflight and clears
`aws.*` + deletes the operational IAM user unconditionally with respect to Pulumi residue
(per-run stacks are destroyed separately by `awsPostflightDestroyActions`; `aws-ses` is
admin-managed so it cannot be stranded). The `BypassPerRunResidueOnly` constructor is
retained as a valid ADT member (still refuses on long-lived residue) but has no production
caller — tracked in `legacy-tracking-for-deletion.md` `Pending Removal`. New pure SSoT
helper `harnessPostflightResiduePolicy` + a `Sprint 7.9` unit-test describe block.
Validated: `check-code` 0; `test unit` all pass; `test integration cli`/`env` exit 0;
`docs check`/`lint docs` 0. Separate deferred follow-on (NOT addressed here): the lost
`aws-ses` Pulumi state (long-lived S3 backend bucket missing) leaving `aws-ses`
Pulumi-unmanageable until re-imported/re-provisioned. Live `prodbox test all --substrate
aws` roll-up remains the closure gate.

**2026-05-28 — Sprint 4.22 follow-on landed: create-call-site coverage lint.** The
second half of the § 3.1 totality enforcement is now in `check-code`: a new
`checkCreateCallSiteCoverage` scan (in `src/Prodbox/CheckCode.hs`, wired into
`haskellStyleViolations`) complements the already-landed registry ↔ doc parity. It is
**deliberately narrow** to avoid the false-positive risk that originally deferred it,
covering only the two surfaces where `prodbox` actually originates a new AWS/cluster
resource: (1) every `Pulumi<Word>Resources` constructor in `src/Prodbox/CLI/Command.hs`
must map (via the explicit `pulumiCreateSiteOwners` table) to a registered
`PerRun`/`LongLived` stack name (pure `pulumiCreateSiteViolations`); (2) the
operational-IAM creation verbs `create-user` / `create-access-key` / `put-user-policy`
(`iamCreateVerbs`) may appear only in the `operational-iam-user` owner module
`src/Prodbox/Aws.hs` (pure `iamCreateSiteViolations`). Broader generic-`create*` /
`change-resource-record-sets` / `create-bucket` scanning is **explicitly excluded** (those
resources are Pulumi-managed or specially-handled bootstrap operations). Together with the
registry ↔ doc parity this **completes** the § 3.1 totality enforcement (registry ↔ doc
parity + create-site coverage). Validation: `prodbox check-code` exit 0 (zero new
violations on the current tree); `prodbox test unit` 600/600 (+6, new `Sprint 4.22
create-call-site coverage lint` group); `prodbox test integration cli` 30/30; `prodbox
test integration env` 30/30.

**2026-05-28 — Phase 4 managed-resource-registry sprints (4.20–4.22) landed +
validated.** Sprint 4.21 added the IO `Prodbox.Lifecycle.ResourceRegistry`
(`ManagedResource` + `perRunManagedResources` + the pure `pairPerRunResidue` /
`resourcesToDestroy` helpers + the `reconcileAbsent` reconciler) and routed
`runNativeDeleteCascade`'s per-run destroy phase through it as a behavior-preserving
refactor (same `PulumiCommand`s, same canonical order, same narration; the old
`perRunCascadeInventory` removed). The default `rke2 delete` / `aws teardown` stay
refuse-gates (4.19/4.20); `reconcileAbsent` is the active-destroy engine, adopted in the
cascade here and in `aws teardown --destroy-pulumi-residue` / `nuke` in Sprint 7.8. Sprint
4.22 made the `substrates.md` Resource Lifecycle Classes inventory a generated section
rendered from `resourceLifecycleClasses`, so `prodbox docs check` fails the build on
registry↔doc drift (the create-call-site coverage lint follow-on landed the same day — see
the dated note above). Validation across 4.20–4.22: `prodbox check-code` exit 0; `prodbox test unit`
585/585; `prodbox test integration cli` 30/30; `prodbox test integration env` 30/30;
`prodbox docs check` / `lint docs` exit 0; plus a live `prodbox rke2 delete --cascade --yes`
smoke on this host (clean exit 0, the rewired cascade's `reconcileAbsent` skip-path
confirmed). The present→destroy cascade path's full live exercise and the Sprint 7.8
operational-credential adoption roll up with the next operator-driven AWS-substrate cascade
run. **Phase 4 is now Done on its code-owned surfaces** (Sprints 4.1–4.22), with the
residual live operator gates (AWS-substrate cascade, `nuke`, AwsSesStack migrate-backend)
tracked per-sprint.

**2026-05-28 — Sprint 4.20 landed (registry foundation).** The first code chunk of the
managed-resource-registry doctrine: new low-level `Prodbox.Lifecycle.ResourceClass` holds
the SSoT facts (`LifecycleClass = PerRun | LongLived | Operational` + the
`resourceLifecycleClasses` list, including the two now-registered operational classes);
`Prodbox.Aws.perRunStackNames`/`longLivedStackNames` are **derived** from it (a unit test
asserts they equal the prior literals); and a single soundness combinator
`Prodbox.Lifecycle.ResidueStatus.residueBlocksTeardownGate` ("present OR unreachable →
block") replaces the per-class `isResiduePresentOrUnknown{PerRun,LongLived}` booleans
(removed), with `categorizePulumiResidue` and `noLiveLongLivedPulumiStacks` migrated to it.
Behavior-preserving (no teardown-behavior change — the registry is not yet wired into a
reconciler; that is Sprint 4.21), so it closes on static gates: `prodbox check-code` exit 0,
`prodbox test unit` 583/583, `prodbox test integration cli` 30/30, `prodbox test integration
env` 30/30. The IO `ManagedResource` record + `reconcileAbsent` reconciler move to Sprint
4.21 (so the discover/destroy closures land with their first consumer rather than as dead
code, and the per-run port-forward batching is preserved); the legacy-ledger rows for the
retired booleans + hand-maintained stack lists moved to `Completed`.

**2026-05-28 — Managed-resource-registry doctrine adopted; Phase 4 extended,
Phase 7 reopened.** The recurring leak/edge-case failures (orphan IAM, silent-pass
teardown, stale operational `aws.*`, the operational `prodbox` user surviving an
interrupted run) were diagnosed not as a missing global state machine but as two
structural gaps in the existing reconciler-with-predicates doctrine: **fail-open
predicates** (an `Unreachable` discover silently treated as "clean") and **incomplete
coverage** (resources prodbox can create with no registered discover/destroy). A
global state machine was deliberately rejected (it would still rely on the same
unsound discovers and go stale against external authoritative state; the existing
doctrine's reasoning holds). The chosen fix is a **typed managed-resource registry** —
the SSoT for "everything prodbox can create, and how to observe and destroy it" — over
which teardown is one idempotent `reconcileAbsent` reconciler, with `Unreachable`
never silently passing and `check-code` making "a creatable-but-undiscoverable
resource" structurally unrepresentable. The doctrine SSoT is
[lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md).
It is scheduled — code not yet landed — as **Phase 4 Sprints 4.20** (registry
foundation + soundness), **4.21** (`reconcileAbsent` + `rke2 delete`), **4.22**
(`check-code` totality + the `substrates.md` Resource Lifecycle Classes table as a
generated section), and **Phase 7 Sprint 7.8** (operational IAM user + `aws.*` config
creds registered; `aws setup`/`teardown` re-expressed as registry reconciliations).
**Sprint 7.8's operational-coverage core landed 2026-05-28**: the registry now covers
the operational IAM user and the operational `aws.*` config block, and
`prodbox aws teardown` reconciles them through `reconcileAbsent` with operational
`Unreachable` failing closed (a dedicated gate refuses rather than letting the cascade
graceful-degradation skip an unobservable operational resource). The broader
`PerRun` ∪ `Operational` merge of the teardown path and the live `test all` roll-up
remain tracked follow-ons — status Active, not Done, on the code-owned surface.
**Phase 7 reopened** for Sprint 7.8 because the registry changes its owned
`aws setup`/`teardown` command surface; **Phase 1 stays Done** (the registry is built
on its `Plan`/Apply, Effect DAG, and capability-class foundations, not a change to
them); Phases 5 and 6 and the rest of Phase 7 remain closed on their owned surfaces.
The registry **generalizes** the existing Phase 4 reconciler work — Sprint 4.11
(predicate library), 4.16 (ResidueStatus source-of-truth), and 4.19 (fail-closed
gate) become instances of one pattern and stay `Done`; nothing earlier is
contradicted. No global state machine, no per-run state migration to S3, no
AWS-name-scanning detector, no auto-sweep (all explicitly out of scope — the registry
surfaces and reconciles leaks, it does not hide them).

**2026-05-28 — Live IAM-orphan sweep + operator cleanup (Sprint 4.19 follow-up).**
After a `prodbox rke2 delete --yes`, a manual read-only AWS sweep (admin creds,
`us-west-2` + `us-east-1` + global) found the per-run leak confined entirely to
**IAM** — no orphan EKS clusters, EC2 instances, VPCs, ELBs, NAT gateways, EIPs,
EBS volumes, or OIDC providers in either region. The IAM orphans, accumulated
across several runs (dated 2026-04-25 → 2026-05-28): managed policy
`aws-eks-test-aws-lb-controller` (0 attachments); roles `clusterRole-6a4fdb3`,
`nodeRole-05d81e0`, `nodeRole-f28de65`; and the operational `prodbox` IAM user with
an active access key + `prodbox-inline` policy. All were removed via the bounded
operator escape hatch (targeted `aws iam` deletes); a re-sweep confirmed only the
intentionally-retained `prodbox-admin-temp`, `prodbox-ses-smtp`, and the
operator-owned `resolvefintech.com` Route 53 zone remain. **Why it was IAM-only and
undetected:** the postflight tag sweep queries the AWS Resource Groups Tagging API,
which does not return IAM resources, so IAM residue has no automated detection
backstop; combined with the (now-fixed) silent-pass-on-unreachable delete gate, IAM
orphans from partial/diverged runs accumulated unnoticed. The doctrine now records
this explicitly as a residual, operator-cleaned class —
[lifecycle_reconciliation_doctrine.md § 6a](../documents/engineering/lifecycle_reconciliation_doctrine.md)
and [substrates.md → Orphaned IAM residue](substrates.md#resource-lifecycle-classes)
— handled by **prevention** (Sprint 4.19's fail-closed gate stops new silent
leaks), deliberately **not** by an AWS-name-scanning detector (anti-pattern) or an
auto-sweep (would mask genuine leaks).

**2026-05-28 — Sprint 4.19: `rke2 delete` fails closed when per-run Pulumi
state is unreachable.** Root-caused from a live incident: `prodbox rke2 delete
--yes` reported a clean per-run AWS teardown and let the operator proceed to the
documented `rm .data`, even though live `aws-eks` resources still existed. The
defect was in the per-run delete **gate** (`noLivePerRunPulumiStacks`): it
treated `ResidueUnreachable` (in-cluster MinIO state backend unreachable — e.g.
MinIO pod down on a degraded cluster, while the per-run state sat intact on
`.data/`) the same as `ResidueAbsent` and passed silently. The fix realigns
`isResiduePresentOrUnknownPerRun` to fail closed on unreachable and branches the
gate on the `ResidueStatus` constructor so the unreachable case gets a distinct,
actionable refusal ("cannot read the per-run Pulumi state backend … do NOT delete
`.data/` until confirmed destroyed … or re-run with `--allow-pulumi-residue` to
accept the orphan risk"). `aws teardown`'s residue check gets the same fail-closed
treatment. The `--cascade` path is unchanged — its own `perRunCascadeInventory`
deliberately keeps graceful degradation (cluster torn down regardless; postflight
tag sweep backstop); the gate-vs-cascade asymmetry is now documented in
`lifecycle_reconciliation_doctrine.md` §3. No live-AWS scanning, no orphan sweep,
no per-run state migration to S3 (all explicitly out of scope). Validation:
`prodbox check-code` exit 0; `prodbox test unit` 578/578; `prodbox test
integration cli` 30/30 (two new tests: unreachable per-run backend → `rke2 delete
--yes` exits non-zero with the refusal and does not claim clean; `--allow-pulumi-residue`
still proceeds); `prodbox test integration env` 30/30. Live operator verification on
this host is the residual gate. See
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) Sprint 4.19.

**2026-05-27 (later session) — Sprint 4.18 third chunk lands; live
validation running.** The two per-run stacks the home `prodbox test all`
exercises (`aws-eks-test`, `aws-test`) drop their on-disk snapshot cache
entirely. New `fetchAwsEksTestSnapshotFromBackend` /
`fetchAwsTestSnapshotFromBackend` read the stack snapshot live from the
in-cluster MinIO Pulumi backend (via `fetchPerRunStackOutputs` + the pure
parsers, including a new full-snapshot `parseAwsTestStackFromOutputs`),
returning the same `Maybe <Snapshot>` the file cache used to so the
destroy and residue-assertion logic is behavior-preserving (precise
per-resource check pre-destroy; tag-scan fallback on absent/unreachable).
Every internal `loadXxxStackSnapshot` consumer is migrated; all
`saveXxxStackSnapshot` / `clearXxxStackSnapshot` callsites and the file-IO
helpers (`save`/`load`/`clear`, `<stack>SnapshotPath`, `snapshotToJson` /
`snapshotFromJson` / `nodeToJson`, EKS `optionalString`) are removed. The
unit round-trip test that exercised `save`/`load` is replaced by two
`parse*FromOutputs` round-trips over the flat `Map Text Text` backend
shape. Static gates green: `prodbox check-code` exit 0; `prodbox test
unit` 575/575; `prodbox test integration cli` 28/28; `prodbox test
integration env` 28/28. The live closure gate — `prodbox test all` on the
home substrate, which provisions/destroys the `aws-eks-test` and
`aws-test` stacks through the migrated code — is in progress on this host.
Remaining Sprint 4.18 work: the same migration for `aws-eks-subzone` /
`aws-ses` (validated by the AWS-substrate run / explicit `aws-ses-destroy`),
the `withEksKubeconfig` bracket, the Pulumi-stored SSH private key, and the
`forbidDotProdboxState` lint (after Sprint 3.13).

**2026-05-27 (later session) — Sprint 4.18 second chunk lands.** Three more
code-owned consumers move off the file-based `loadXxxStackSnapshot` adapter
onto the live `fetchPerRunStackOutputs` read introduced by the first
2026-05-27 chunk: `verifyAwsTestSnapshot`, `verifyAwsTestSshReachability`
(sharing a new `fetchAwsTestNodes` helper), and
`ensureAwsSubstratePlatformRuntime` in
`src/Prodbox/Lib/AwsSubstratePlatform.hs`. Two new pure parsers
(`Prodbox.Infra.AwsTestStack.parseAwsTestNodesFromOutputs` and
`Prodbox.Infra.AwsEksTestStack.parseAwsEksTestStackFromOutputs`) decode the
flat `Map Text Text` returned by `fetchPerRunStackOutputs` into structured
records. `fetchPerRunStackOutputs` gains a test-only
`PRODBOX_TEST_PER_RUN_OUTPUTS_DIR` override so the unit suite can exercise
the migrated consumers without a live MinIO port-forward; the existing
`native validation helpers` SSH-retry test is rewritten to inject the
`nodes` output through that override instead of writing
`.prodbox-state/aws-test/stack-snapshot.json`. 7 new unit tests pin the
parsers' happy paths plus missing-field / non-JSON / wrong-shape failure
modes. Validation: `prodbox check-code` exit 0; `prodbox test unit`
574/574 (up from 567); `prodbox test integration cli` 28/28;
`prodbox test integration env` 28/28. Remaining Sprint 4.18 work
(removing the surviving `saveXxxStackSnapshot` / `clearXxxStackSnapshot`
callsites, replacing `awsEksTestKubeconfigPath` with a `withEksKubeconfig`
bracket, replacing the local SSH-keygen surface with a Pulumi-stored
private-key output, and landing the `forbidDotProdboxState` lint) is
unchanged and remains tracked in
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
Sprint 4.18.

**May 28, 2026 — AWS-substrate cascade `DependencyViolation` failure exposes
doctrine-vs-code inversion in `prodbox rke2 delete --cascade --yes`.**
A live cleanup attempt on Bathurst (Phase 7's AWS-substrate residue from
killed `prodbox test all --substrate aws` runs) failed mid-way through the
per-run Pulumi destroy phase with:

```
aws:ec2:Subnet publicSubnet1 deleting (1200s) error:
DependencyViolation: The subnet 'subnet-00db2adeb400ca61f' has dependencies
and cannot be deleted
```

Root-cause analysis identified two independent issues that share the same
fix shape, both originating in the original Sprint 4.17 cascade-order
landing (May 23, 2026):

1. **Cascade phase order inverted vs. doctrine canonical order.** The
   doctrine §1 prose at
   [`lifecycle_reconciliation_doctrine.md`](../documents/engineering/lifecycle_reconciliation_doctrine.md)
   states "the drain runs **before** any Pulumi destroy so the controllers
   are still alive to unwind their AWS-side state." However the doctrine
   §5b table that Sprint 4.17 added (and that the code implements)
   inverted the order to `destroys → drain`. On the home substrate the
   inversion is harmless because no in-cluster controllers create AWS
   resources; on the AWS substrate the inversion is fatal because AWS Load
   Balancer Controller + EBS CSI driver are alive on the EKS cluster when
   per-run destroys begin, leaving orphan ENIs that block subnet deletion.
   The doctrine §5b table and §1 prose are updated May 28, 2026 to require
   the canonical `drain → destroys` order; the code correction is
   scheduled as **Sprint 4.17.a** in
   [`phase-4-lifecycle-canonical-paths.md`](phase-4-lifecycle-canonical-paths.md).

2. **K8s drain phase hardcodes the local-cluster kubeconfig.**
   `src/Prodbox/CLI/Rke2.hs::runCascadeDrainPhase` (lines 840–855) sets
   `KUBECONFIG=/etc/rancher/rke2/rke2.yaml` unconditionally. On the AWS
   substrate the drain consequently walks the local cluster's namespaces
   (which contain no AWS LoadBalancer Services / ALB Ingresses /
   Delete-reclaim PVCs), reports nothing to drain, and lets the per-run
   destroys hit the same `DependencyViolation` because the EKS-side
   controllers' ENIs are never released. The fix wraps the drain call in
   `Prodbox.PublicEdge.withSubstrateKubectlEnvironment` (already exported
   from `src/Prodbox/PublicEdge.hs` from earlier Sprint 7.5.c.v follow-up
   work) for `SubstrateAws`. Scheduled as **Sprint 4.17.b** blocked on
   Sprint 4.17.a so the substrate-aware drain runs in the doctrine-
   canonical position. The
   [`aws_integration_environment_doctrine.md` §5.5](../documents/engineering/aws_integration_environment_doctrine.md)
   section is added May 28, 2026 to document the substrate-aware drain
   requirement.

Both Sprints 4.17.a and 4.17.b landed code-side May 28, 2026 and are now
`Done` on their owned surfaces. `runNativeDeleteCascade` reorders to the
doctrine-canonical `confirm-MinIO → drain → per-run destroys → uninstall
→ sweep` with `cascadeOrderNarration` exposed as a stable test pin (5 new
unit tests pin the order). `runCascadeDrainPhase` now takes a `Substrate`
argument and builds a substrate-aware env-var list via new helper
`buildDrainEnvironment`; the cascade infers substrate from per-run
residue via new pure helper `inferCascadeSubstrate` (6 new unit tests
cover every substrate-inference combination). `DrainSkipped` on the AWS
substrate is now a hard failure with an explanatory message. Test count:
554/554 (up from 543). The corresponding rows in
[`legacy-tracking-for-deletion.md`](legacy-tracking-for-deletion.md) are
moved from `Pending Removal` to `Completed`. The
[`cli_command_surface.md`](../documents/engineering/cli_command_surface.md)
`prodbox rke2 delete --cascade` section is updated to document the
corrected phase order.

**Live verification on the home substrate closed May 28, 2026** with a
clean `prodbox rke2 delete --cascade --yes` run on the Bathurst host
after operator cleanup. The cascade narration emitted the canonical
`confirm-MinIO → drain → per-run destroys → uninstall → sweep` order
verbatim; `inferCascadeSubstrate` correctly returned `SubstrateHomeLocal`
because no AWS per-run residue was present
(`aws-eks=absent, aws-eks-subzone=absent, aws-test=absent`); the local
RKE2 substrate was uninstalled cleanly with `.data/` preserved; the
postflight tag sweep reported `clean (no cluster-tagged or
prodbox-owned AWS residue)`. The orphan AWS resources from the May
27/28 in-flight runs (3 `aws-test-node-*` EC2 instances,
`aws-eks-test-vpc`, `aws-test-vpc`, the one orphan ENI in
`subnet-00db2adeb400ca61f`) were cleaned up by the operator-driven
procedure documented in the approved plan file, in dependency order:
terminate instances → delete orphan ENI → delete subnets → detach +
delete IGW → delete non-main route tables and non-default security
groups → delete VPCs. EBS volumes auto-deleted with the root-volume
flag on instance termination. Final AWS state: zero non-default VPCs,
zero EC2 instances, zero ENIs, zero ELBs, zero EKS clusters.

Live re-verification on the AWS substrate (full
`prodbox test all --substrate aws` cycle completes cleanly including
the cascade) remains the operator-driven closure gate for both Sprint
4.17.a and 4.17.b on the AWS path. The home-substrate gate is satisfied.

This is a distinct leak class from the May 27 "Pulumi state lost across
`rke2 delete + rke2 reconcile`" failure documented below — that produced
silent residue; this one produces a hard AWS API error mid-destroy. Both
share the structural root cause that the cascade had no path to drain
EKS-side K8s resources before destroying the EKS cluster.

The orphan AWS resources from the May 27/28 runs (3 `aws-test-node-*` EC2
instances, `aws-eks-test-vpc` + `aws-test-vpc` plus their orphan ENIs)
are tracked as operator-driven cleanup. The cleanup procedure is
operator-driven (`aws ec2 describe-network-interfaces` to identify ENI
holders, then targeted `aws elbv2 delete-load-balancer` /
`aws ec2 terminate-instances` / `aws ec2 delete-network-interface` /
`aws ec2 delete-subnet` / `aws ec2 delete-vpc` in dependency order). This
one-time deviation from CLAUDE.md's "harness is the exclusive AWS owner"
rule is the bounded escape hatch the doctrine doesn't currently provide
for cases where Pulumi state has diverged from live AWS state.

**May 27, 2026 — Phase 2/3 live-exercise progress (`prodbox test all` home substrate).**
Three latent code bugs surfaced by the live `prodbox test all` cycle on Bathurst and were
fixed in-session, restoring the canonical-suite path past the previous closure gates:

1. **`BS.readFile "/dev/urandom"` hang in
   `src/Prodbox/CLI/Rke2.hs::resolveGatewayMinioCredentials`** (Sprint 2.19 follow-up):
   `BS.readFile` reads until EOF, which never comes from the infinite character device, so
   `prodbox rke2 reconcile` blocked indefinitely on the gateway-minio credential bootstrap
   when the `gateway-minio-creds` Secret was absent. Fix: open the handle with
   `openBinaryFile` and `BS.hGet handle 34` to read exactly the 34 bytes the suffix +
   password derivation needs. Restored 28/28 integration cli/env passing (was 25/28 due to
   ZeroSSL, Percona-mirror, and `rke2 reconcile + delete` tests timing out at ~70s on the
   hung urandom read).
2. **UTF-8 decode failure in the gateway daemon Pod** (Sprint 2.20/2.22 follow-up):
   chart-rendered `config.dhall` contains `§` (`0xC2 0xA7`) in the Sprint 2.22 comment
   block, which fails Dhall decoding under the container's default C/POSIX locale.
   Fix: `setLocaleEncoding utf8` at the top of `src/Prodbox/App.hs::main`
   (defense-in-depth at the binary boundary), plus `ENV LANG=C.UTF-8` and
   `ENV LC_ALL=C.UTF-8` in `docker/gateway.Dockerfile` and `docker/prodbox.Dockerfile`
   (defense-in-depth at the container boundary). With this fix the three gateway daemon
   Pods (`gateway-node-a/b/c`) reach `Running 1/1` with 0 restarts and successfully emit
   `gateway_starting`, `orders_loaded`, `rest_server_listening`,
   `gateway_ownership_event_emitted`, `peer_listener_listening`, and
   `dns_write_succeeded` against the live Route 53 zone.
3. **`gateway-daemon` validation rendered JSON-format config** (Sprint 2.20 follow-up):
   `src/Prodbox/TestValidation.hs::renderGatewayValidationConfig` /
   `renderGatewayValidationOrders` still emitted JSON, which the post-Sprint-2.20 Dhall-
   only daemon decoder rejects with `Invalid input: unexpected '"'`. Fix: replace both
   renderers with `renderGatewayValidationConfigDhall` / `renderGatewayValidationOrdersDhall`
   emitting the canonical `{ schemaVersion = 1, boot = {…}, live = {…} }` shape that
   matches `Prodbox.Gateway.Settings.DaemonConfigDhall`; rename temp file extensions from
   `.json` to `.dhall`; drop unused `encode`/`object`/`.=` imports from `Data.Aeson`. New
   `dhallText` helper escapes string literals safely. The live re-run gate for the
   gateway-daemon validation remains.

The `prodbox test all` run-3 cycle (~1h32m) closed the Phase 2/3 live gates for every
non-gateway-daemon canonical validation on the home substrate. Validations recorded
`body exit=ExitSuccess` for `charts-vscode`, `charts-api`, `charts-websocket`,
`admin-routes`, `public-dns`, `dns-aws`, `aws-iam`, `aws-eks`, `pulumi`, and
`ha-rke2-aws`. Only `gateway-daemon` failed, due to the JSON-config bug above.

**Run-4 (~1h35m) closed the gateway-daemon validation live too**, after the
JSON→Dhall fix landed. Final run-4 validation roll-up: every named canonical
validation on the home substrate recorded `body exit=ExitSuccess` —
`charts-vscode`, `charts-api`, `charts-websocket`, `admin-routes`, `public-dns`,
`dns-aws`, `aws-iam`, `aws-eks`, `pulumi`, `ha-rke2-aws`, `gateway-daemon`,
`gateway-pods`, `gateway-partition`, `charts-platform`, `charts-storage`, and
`lifecycle` (the destructive `rke2 delete + rke2 reconcile` cycle inside one
run). The only failing validation was `keycloak-invite`, which is the documented
Sprint 8.5 follow-up that requires live Keycloak credential-setup form-structure
capture (operator-driven). Postflight cleared the operational `aws.*` block and
deleted the dedicated IAM user.

With run-4 closed, the home-substrate row in the Substrate Parity table below is
✅ full canonical suite less keycloak-invite. The remaining live closure work
narrows to: (a) Sprint 7.5.c.v's AWS-substrate canonical-suite re-run; (b)
Sprint 8.5/8.6's live OIDC form-structure capture; (c) Sprint 4.10's live
AwsSesStack admin-credential migrate-backend exercise; (d) Sprint 4.13's
operator-driven `prodbox nuke` total-teardown exercise; (e) Sprint 4.16's
live source-of-truth swap regression against MinIO/S3 backends. The home-
substrate Sprints 2.19/2.21/2.22/3.14/4.11/4.12/4.15/4.17 live gates are
satisfied on this host.

The master-seed acquisition on the live gateway daemon emits
`master_seed_unavailable` with a 403 from MinIO (the `prodbox-gateway-…` user can
authenticate but the master-seed object HEAD returns Forbidden). Per
[secret_derivation_doctrine.md §8](../documents/engineering/secret_derivation_doctrine.md),
the daemon falls back to structured-503 responses on `/v1/secret/derive` rather than
crashing — the contract is preserved. Full closure of Sprint 2.19 requires diagnosing
why the dedicated `prodbox-gateway` MinIO user does not have the HeadObject grant the
master-seed read needs and is tracked as a Sprint 2.19 follow-up.

**Run-5 (AWS substrate, ~50m) revealed an operator-driven config gap on the
Sprint 7.5.c.v live path.** `prodbox test all --substrate aws` provisioned the
EKS cluster + Harbor + MinIO + Percona + Envoy Gateway + cert-manager + AWS LBC
+ workload charts and reached `CLASSIFICATION=ready-for-external-proof`, but the
first AWS-substrate canonical validation (`charts-vscode --substrate aws`) failed
immediately with `substrateHostedZoneId: aws_substrate.hosted_zone_id is empty;
--substrate aws runs require aws_substrate.hosted_zone_id per
development_plan_standards.md § M (no fallback)`. This is by design — the
no-fallback contract requires the operator to supply the AWS subzone's hosted
zone ID in `prodbox-config.dhall` before AWS-substrate validations can run.

The operator-driven workflow to close this gap on a fresh AWS substrate run is:
(1) provision the subzone once via `prodbox pulumi aws-subzone-resources --yes`;
(2) extract the hosted zone ID from `pulumi stack output --show-secrets
hosted_zone_id` on the `aws-eks-subzone` stack; (3) set
`aws_substrate.hosted_zone_id = "Z…"` in `prodbox-config.dhall` and refreeze; (4)
re-run `prodbox test all --substrate aws`. The harness postflight destroys the
subzone with the rest of the per-run stacks, so the ID changes between runs —
this manual step is required each time. (A code follow-up to read the subzone
hosted zone ID from a stack-output cache when config is empty is out of scope
for run-5 and would need explicit doctrine approval to override the no-fallback
contract in [development_plan_standards.md § M](development_plan_standards.md#substrate-coverage-and-independence-no-fallback).)

The postflight cleanup left residual AWS resources (`aws-eks-test-vpc`,
`aws-test-vpc`, and 3 `aws-test-node-*` EC2 instances) on the operator AWS account
after `prodbox pulumi eks-destroy --yes` and `prodbox pulumi aws-test-destroy --yes`
ran in the postflight sweep. This matches the file-existence residue-predicate
failure class that Sprint 4.16's source-of-truth swap is meant to close — when the
in-cluster MinIO backend's stack snapshot was lost across the rke2 wipe between
runs, the per-stack destroy reported "nothing to destroy" while the underlying AWS
resources persisted. The residue is recorded here as a known follow-up for Sprint
4.16's live closure rather than a regression in the destroy code.

**May 24, 2026 — Phase 0/1/2/3 reopened for the pure-Dhall config doctrine.** A new SSoT
[config_doctrine.md](../documents/engineering/config_doctrine.md) consolidates every
`prodbox` binary's configuration sourcing to a single Dhall file at `--config <path>`,
decoded in-process via the native Haskell `dhall` library. The reopen affects:
Phase 0 (Sprints 0.3, 0.4 revised in place + new Sprint 0.8 adopting the doctrine and
updating governed docs); Phase 1 (Sprint 1.2 revision note + new Sprint 1.28 covering
the `allow-newer` clauses for `dhall`'s transitive deps under GHC 9.14.1 plus the
env-var-read lint rule); Phase 2 (Sprints 2.9, 2.11, 2.12, 2.13, 2.15, 2.19 revised in
place + new Sprints 2.20/2.21/2.22 covering the daemon Dhall settings module,
file-watch reload trigger with drain-and-exit on boot-field changes, and chart-side
Dhall ConfigMap + Secret-mounted credentials); Phase 3 (new Sprint 3.14 covering the
`PRODBOX_WORKLOAD_MODE` env-var migration to Dhall). Phase 4's lifecycle-reconciliation
scope is unchanged by this reopen; a cross-reference line in phase-4 notes that daemon
Pods auto-restart on boot-field config changes. The superseded doctrine — SIGHUP-only
reload trigger, `PRODBOX_*` env-var precedence ladder, JSON daemon config rendering,
chart-side env-var-sourced daemon credentials, the `MINIO_ENDPOINT_URL` env-var
addition rolled back the same day — is moved to
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) per
`development_plan_standards.md §A` and §I. The closure gate for these reopen sprints is
the live exercise of file-watch reload on this host (Phase 2) plus the canonical-suite
re-run.

Phase `0` reopened through Sprints `0.2`–`0.7` (see
[phase-0-planning-documentation.md](phase-0-planning-documentation.md)) to adopt
[the engineering doctrine docs](../documents/engineering/README.md) as the canonical CLI doctrine, align the
governed docs and plan suite to that doctrine, schedule every currently known code-level
adoption gap onto explicit downstream sprints, and (Sprint `0.7`, May 20, 2026) add the
LLM/automation guardrails so every operator-interactive entry point refuses to run on a
non-TTY stdin and points the caller at the automation equivalent. That Phase-0
doctrine-governance work is now `Done`. Phases `1` through `4` were **reopened** for the
scheduled implementation work named below and are now reclosed. Sprint 0.3 extended the
doctrine-adoption scope with the residual items surfaced by the May 2026 doctrine-vs-plan
audit, scheduling them through new Phase `1` sprints (1.24–1.26) and through deliverable
extensions to existing planned Phase `1` and Phase `2` sprints. Sprint 0.4 extended the
doctrine-adoption scope again with the residual items surfaced by the May 12, 2026 round-3
doctrine-vs-plan audit, scheduling them through one new Phase `1` sprint (1.27) and through
deliverable extensions to existing planned Phase `1`, Phase `2`, Phase `3`, and Phase `4`
sprints. Sprint 0.5 reopened Phase `4` through Sprint `4.8` to harden the
`prodbox rke2 delete --yes` success-summary contract; Sprint
`4.8` is now `Done`, the lifecycle-local quiet path captures the upstream uninstall output, the
expanded `isIgnorableRke2DeleteNoiseLine` filter classifies inotify warnings such as
`Failed to allocate directory watch: Too many open files` as benign noise, and the integration
suite proves both the hermetic success contract and the summarized failure path. Sprint 1.2
was revised May 20, 2026 to replace the external `dhall-to-json` subprocess decode bridge
with in-process decoding through the native Haskell `dhall` library
(`Dhall.inputFile auto`); the `toolDhall` / `tool_dhall` external-tool prerequisite, the
matching prerequisite-registry assertion, and the `FromJSON` / `ToJSON` derivations on the
settings record types are removed from the supported path.
Phase `5` briefly reopened
through Sprint `5.5` to add the missing public HTTP listener that redirects port `80` to the
canonical HTTPS edge, and that redirect follow-up is now `Done` after the May 13, 2026
aggregate validation. Phases `5` and `6` are `Done` on their owned surfaces (public-edge
proof, clean-room rerun contract). Phase `7` is `Done` on its **legacy** owned scope
(Sprints `7.1`–`7.4`: interactive onboarding, AWS IAM management, quota automation, and the
temporary-admin-credential validation harness) **and** has reopened for AWS-substrate parity:
Sprint `7.5` is `Active` (sub-sprints `7.5.a`/`7.5.b.*`/`7.5.b.iii`/`7.5.c.i`–`7.5.c.iv`/
`7.5.c.v.b`/`7.5.c.v.c`/`7.5.c.v.d`/`7.5.c.v.e` are `Done` on their code-owned surfaces;
Sprint `7.5.c.v.f` is `Done` on its code-owned surface (May 21, 2026: substrate-aware
`prodbox host public-edge --substrate {home-local,aws}` plus stderr breadcrumbs in
`runNativeValidation` that make silent exit structurally impossible); the live
`--substrate aws` re-run rolls up into Sprint `7.5.c.v`); Sprints `7.6` (orphan-safety
refuse-path + auto-destroy postflight) and `7.7` (generalized `aws teardown` +
`PulumiResiduePolicy` ADT + harness teardown bug closure + admin-credential prompt UX)
are both `Done` (May 19, 2026). Phase `4` reopened May 21, 2026 to schedule Sprints
`4.10`–`4.15`: code frameworks for Sprints `4.10`–`4.13` landed the same day
(long-lived Pulumi backend decouple, lifecycle predicate library + `--cascade`,
K8s drain phase, `prodbox nuke` scaffold), Sprint `4.14`
(operator vocabulary contract enforcement) closed the same day —
every `Sprint <digit>` leak in operator-facing surfaces is removed
and a new `checkOperatorVocabulary` scan refuses regressions — and
Sprint `4.15` (cascade tolerates absent cluster) closed the same
day with a live verification on this host: `prodbox rke2 delete
--cascade --yes` now skips the K8s drain phase cleanly when the
cluster is already gone and proceeds to the per-run Pulumi destroys.
The live AwsSesStack admin-credential switch / live cascade
exercise against a running cluster / live `nuke` exercise are
scheduled as remaining work for Sprints `4.10`–`4.13`. Phase `8` is `Active` on Sprints
`8.5`–`8.6`. **Phase `2`, Phase `3`, and Phase `4` reopened May 23, 2026** to schedule
the `.prodbox-state/` elimination work surfaced by the May 22 cascade-credentials
failure on this host: Phase `2` adds Sprints `2.17` (native Haskell HTTP client replaces
`curl` shell-outs) **— ✅ Done on the host-side host-CLI surface (5 callers migrated;
`Prodbox.Http.Client` + `Prodbox.Gateway.Client` modules; 10 unit tests; the
TestValidation-suite callers and the RKE2 installer download remain on the cleanup
ledger as Sprint 4.18 follow-up)**; `2.18` (127.0.0.1-only NodePort enforcement via
`host firewall`) **— ✅ Done on the foundational host-side surface (pure
`gatewayNodePortFirewallRuleArgs` + `runHostFirewallGatewayRestrict` + new `host
firewall gateway-restrict --port PORT` subcommand; 7 unit tests; chart-side NodePort
Service + reconcile/delete wiring land with Sprint 2.19)**; and `2.19` (gateway daemon
becomes secret-derivation service) **— 🔄 Active: pure `Prodbox.Secret.Derive` module
landed (HMAC-SHA-256 + per-secret context-string table + 13 unit tests, including the
five canonical context strings from the doctrine table); the wire-contract layer also
landed May 23, 2026 — new `Prodbox.Secret.Wire` with typed `DeriveResponse` /
`EnsureNamespaceRequest` / `EnsureNamespaceResponse` / `SecretSha256Entry` shapes, typed
`Prodbox.Gateway.Client.derive` / `ensureNamespace` client functions, and daemon route
stubs at `/v1/secret/derive` and `/v1/secret/ensure-namespace` returning structured 503
"master-seed unavailable" per doctrine §8 until the live handlers land (8 new unit
tests; total 495). Chart-side scaffolding also landed May 23, 2026: new
`charts/gateway/templates/secret-minio-creds.yaml` (Opaque Secret using `lookup` +
`randAlphaNum`, persists across helm upgrades), new
`charts/gateway/templates/service-nodeport.yaml` (NodePort `30443` exposing the gateway
REST port for host-CLI loopback access; matches the Sprint 2.18 iptables-rule default),
and `charts/gateway/templates/deployments.yaml` wires `MINIO_ACCESS_KEY_ID` /
`MINIO_SECRET_ACCESS_KEY` env vars from the new Secret into the gateway pod. Symmetric
firewall-rule removal landed alongside: new
`Prodbox.Host.runHostFirewallGatewayUnrestrict :: Int -> IO ExitCode` plus
`prodbox host firewall gateway-unrestrict --port PORT` operator-facing subcommand
(idempotent — treats absent-rule as success-with-reason). **`Prodbox.Secret.MasterSeed`
foundation also landed May 23, 2026 (later session)**: new
`src/Prodbox/Secret/MasterSeed.hs` shells out to `aws s3api` via
`Prodbox.Service.runMinIOWithEnv` (no `amazonka-s3` / `minio-hs` dependency required
today); exposes `MinioMasterSeedConfig`, the six-constructor `MasterSeedError` ADT,
`ensureMasterSeed` (read-or-create with `If-None-Match: *` concurrent-creation guard +
post-PUT GET re-read), `generateFreshSeedBytes` (32 bytes from `/dev/urandom`), and the
pure `awsS3Api{Head,Get,Put}Args` helpers + AWS-CLI error-blob recognizers; 14 new unit
tests pin the wire shape (test count 533/533, up from 519). MinIO IAM bootstrap + live
daemon endpoint bodies (replacing the structured 503 stubs with `ensureMasterSeed` ∘
`derive` and the per-context `ensure-namespace` inventory) + the chart-side
`MINIO_ENDPOINT_URL` env-var addition + automatic reconcile/delete firewall-rule wiring
remain as coupled deliverables for a dedicated live session**. Phase `3` adds Sprint `3.13` (chart secrets derived by the gateway
service; eliminates the host-side `.prodbox-state/<ns>/.secrets.json` cache) **— 📋
Planned (blocked on Sprint 2.19's full closure)**. Phase `4` adds Sprints `4.16`
(`ResidueStatus` source-of-truth swap) **— ✅ Done on the code-owned surface
(2026-05-27). The 4.16 closing change introduces
`src/Prodbox/Lifecycle/LiveResidue.hs` (one shared MinIO port-forward
across the three per-run stacks; admin-credentialled long-lived S3 query
for `aws-ses`); per-stack `<stack>ResidueStatus` delegates to LiveResidue
and the four `<stack>HasLiveResources` boolean predicates are removed.
`Prodbox.Aws.checkPulumiResidueBeforeTeardown` splits into the pure
`categorizePulumiResidue` + an IO wrapper that batches one MinIO and one S3
query; the three downstream callers (`Aws.checkPulumiResidueBeforeTeardown`,
`Preconditions.noLive{PerRun,LongLived}PulumiStacks`,
`Rke2.runNativeDeleteCascade`) all share the batch. New test-only env var
`PRODBOX_TEST_RESIDUE_ABSENT=1` short-circuits both queries to
`ResidueAbsent` for the fake-AWS-CLI integration suite. 17 unit tests
rewritten to inject synthetic `PerRunResidueStatuses` via
`categorizePulumiResidue` (replacing the `writeFakeStackSnapshot` +
file-existence pattern); 13 new tests cover the LiveResidue pure helpers
and the doctrine asymmetry (per-run unreachable → absent; long-lived
unreachable → still-present). Validated with `prodbox check-code` exit
0, `prodbox test unit` 567/567, `prodbox test integration cli` 28/28,
`prodbox test integration env` 28/28, `prodbox-daemon-lifecycle` 14/14.
Snapshot file-IO removal moves to Sprint 4.18; the live AWS-substrate
regression (`prodbox test all --substrate aws` produces zero
`.prodbox-state/aws-*/` writes during cascade refusal paths) rolls up
with Sprint 7.5.c.v**, `4.17`
(cascade canonical order + self-materialize operational creds) **— 🔄 Active: the
credential-fallback half landed May 23, 2026 a.m. and **structurally closes the May 22
cascade-credentials failure class** by making each per-run
`loadOperationalAwsCredentials` fall back to `aws_admin_for_test_simulation.*` when
operational `aws.*` is empty (4 unit tests); the cascade-order rewrite landed
May 23, 2026 p.m. — `runNativeDeleteCascade` now executes confirm-MinIO → per-run
destroys → drain → uninstall → postflight sweep, with new pure helper
`perRunCascadeInventory` exposed for test coverage (7 new unit tests). **The postflight
tag sweep wiring also landed May 23, 2026 (later session)**: `runCascadePostflightTagSweep`
now loads admin credentials via `loadAdminAwsCredentials`, builds the admin AWS env via
`adminAwsEnvironment`, and calls `Prodbox.Lifecycle.TagSweep.discoverClusterTaggedAwsResources`
with `awsEksCanonicalClusterName` as the cluster filter; an empty result reports "clean",
a non-empty result emits the full `renderTagSweepRefusal` block, and the cascade returns
`ExitSuccess` either way per doctrine §6 (4 new unit tests; test count 519/519, up from
515). All code-owned halves of Sprint 4.17 are now shipped; only the live cascade exercise
against a host with a live `aws-eks` stack remains as the closure gate**, and `4.18`
(removes remaining `.prodbox-state/` artifacts) **— 🔄 Active. First
chunk of code-owned work landed 2026-05-27 on top of Sprint 4.16's
source-of-truth swap: tarball scratch directories moved from
`.prodbox-state/tmp/` to the system temp directory in
`Lib/AwsSubstratePlatform.hs::withTempJsonFile` and
`CLI/Rke2.hs::pushCustomImageVariantsViaInClusterCrane`; new
`Prodbox.Lifecycle.LiveResidue.fetchPerRunStackOutputs` /
`fetchAwsSesStackOutputs` foundation reads from live Pulumi backend;
two consumers migrated off `loadXxxStackSnapshot`
(`PublicEdge.hs::resolveSubstrateHostedZoneId` reads `subzone_id`;
`TestValidation.hs::verifyAwsEksSnapshot` reads `cluster_name` +
`subnet_ids`). Remaining: migrate the two `AwsTestStack`-node
readers + the `AwsSubstratePlatform` snapshot consumer; remove
save/load/clear + state-dir helpers + JSON serialization in the four
per-stack modules; replace the `awsEksTestKubeconfigPath` and SSH-key
paths with mktemp brackets; add the `forbidDotProdboxState` lint
once Sprint 3.13 closes the chart-secret cache references.** New doctrine SSoT
[secret_derivation_doctrine.md](../documents/engineering/secret_derivation_doctrine.md)
governs the master seed and the host↔cluster boundary. The doctrine-adoption handoff
is closed; remaining open work is substrate-parity live validation (Sprint `7.5.c.v`),
the residual Phase `4` live closures for Sprints `4.10`–`4.13`, live Keycloak invite
OIDC closure (Sprint `8.5`), and the Phase `2`/`3`/`4` reopened sprints above.

Reopened sprints by phase:

- Phase 0 — **Sprints 0.2, 0.3, 0.4, 0.5, 0.6**: Sprint 0.2 adopts the engineering doctrine docs as governed CLI
  doctrine. Updates `documents/documentation_standards.md` with the six Generated Sections
  requirements, retags governed engineering docs as doctrine pointers, and threads doctrine
  cross-references through the plan suite and root guidance. Sprint 0.3 schedules the
  residual doctrine items surfaced by the May 2026 audit: durable CLI documentation
  artifacts (Markdown command reference, manpages, shell completions), the `execParserPure`
  parser-test category, the `renderError` error-rendering boundary discipline, per-command
  `CommandSpec` `Example` entries, the `cabal format` temp-file round-trip byte-equality
  compare, the default 30 s drain deadline plus explicit `bracketOnError`, the
  `envMetrics :: MetricsRegistry` typed daemon `Env` field, the STM broadcast channel for
  `LiveConfig` subscribers, the prescribed on-disk Dhall file shape, and the daemon
  log-level refresh from `LiveConfig` on every hot reload. Sprint 0.4 schedules the
  residual doctrine items surfaced by the May 12, 2026 round-3 audit: cabal-manifest
  toolchain pin declarations (`tested-with: ghc ==9.14.1`, `with-compiler: ghc-9.14.1`,
  the `Cabal 3.16.1.0` reference), library-first / thin-`Main.hs` layout, the
  `CommandSpec` / `OptionSpec` record-field bindings plus daemon-as-typed-`Command`
  dispatch, forbidden subprocess primitives (`callProcess`, `readCreateProcess`,
  direct `System.Process` constructors), the thirteen minimum `fourmolu.yaml` settings,
  the canonical property-test invariants (`decode . encode == id`,
  `render is deterministic`, `parser roundtrips`), the service-error newtype inventory
  (`MinIOError`, `RedisError`, `PgError` wrapping `ServiceError`), the daemon
  `AppError` record shape (`errorKind`, `errorMsg`, `errorCause :: Maybe SomeException`),
  the naming-helper signatures with DNS-1123 / 63-character constraints, the enumerated
  forbidden renderer inputs, the structured-concurrency primitive set
  (`withAsync` / `race` / `concurrently` / `replicateConcurrently`), the forbidden
  reload triggers (`fsnotify`, `inotify`, `mtime` polling) plus typed
  `schemaVersion : Natural` Dhall field and eight-step reload procedure, typed
  logging field helpers (`field`, `logStructured`, `logDebug`, `logInfo`,
  `logWarn`, `logError`), the production-no-op / test-injected hook contract,
  the health-endpoint response shapes captured as golden tests, and the forbidden
  reconciler flags and sister commands (`--force`, `--reinstall`, `install`,
  `upgrade`, `repair`, `force-install`). Sprint 0.5 schedules the remaining
  `prodbox rke2 delete --yes` success-path output residue: a new Phase `4` sprint
  hardens hermetic success summaries, tracks the leak in the cleanup ledger, and names the
  governed documentation updates required by `documents/documentation_standards.md`. Sprint
  0.6 introduces the substrate doctrine into the canonical phase model, renames
  `phase-5-public-host-validation.md` → `phase-5-canonical-test-suite.md` and
  `phase-7-aws-iam-quota-automation.md` → `phase-7-aws-substrate-foundations.md`, adds
  [substrates.md](substrates.md), and makes substrate provision/teardown a per-substrate
  concern separate from suite content.
- Phase 1 — **Sprints 1.6–1.27**: `CommandSpec` source-of-truth split; `Plan` / `apply`
  discipline with `--dry-run`; `Subprocess` ADT formalization; prerequisite registry
  remedy-hint contract; lint, generated-section, and forbidden-path stack alignment;
  `hspec` → `tasty` test-stanza migration; capability classes plus `AsServiceError`;
  `RetryPolicy` as first-class values; `Recoverable` / `Fatal` `ErrorKind`; naming helpers
  and smart-constructor module; GADT-indexed state machines for multi-state workflows;
  toolchain pin reaffirmation on GHC `9.14.1` / Cabal `3.16.1.0`; one-shot CLI output
  discipline with `--format` / `--color` / `--no-color` and stdout/stderr split; one-shot
  `Env` record and `ReaderT App` adoption; pinned style-tools sandbox under
  `.build/prodbox-style-tools/` plus custom nesting warnings and negative-space
  symbol rules refusing `forkIO`, `unsafePerformIO`, and module-level `IORef` in daemon paths;
  aggregate `prodbox test lint` dispatch with lint-first ordering of `prodbox test all`;
  `trackingGeneratedPaths` registry plus renderer determinism contract; standardized library
  audit of `prodbox.cabal`; `dhall freeze` discipline on the committed repo-root config path
  plus the `lint docs` ↔ `docs check`/`docs generate` naming-consolidation decision and the
  parser `--foreground` default plus self-daemonization-forbidden rule; and — added by Sprint
  0.3 — durable CLI documentation artifacts under `documents/cli/`, `share/man/`, and
  `share/completion/` registered in `trackingGeneratedPaths`; the `execParserPure`
  parser-test category in the `prodbox-unit` stanza; and the `renderError` error-rendering
  boundary discipline with hlint rules refusing `print`, `exitFailure`, and direct terminal
  formatting outside the dedicated output layer. Sprint 0.4 adds Sprint 1.27 (cabal-manifest
  `tested-with: ghc ==9.14.1` and `with-compiler: ghc-9.14.1` declarations, the literal
  `Cabal 3.16.1.0` reference, and the library-first / thin-`Main.hs` audit through
  `src/Prodbox/CheckCode.hs`) and threads the round-3 extensions through Sprint 1.6
  (`CommandSpec` / `OptionSpec` record-field bindings plus daemon-as-typed-`Command`
  dispatch), Sprint 1.8 (typed `Subprocess` record plus removal of the pre-doctrine
  `CommandSpec`, `runStreamingCommand`, and `captureCommand` compatibility names), Sprint 1.10
  (thirteen minimum `fourmolu.yaml` settings bound), Sprint 1.11 (canonical
  property-test invariants `decode . encode == id`, `render is deterministic`,
  `parser roundtrips`), Sprint 1.12 (service-error newtype inventory `MinIOError`,
  `RedisError`, `PgError`), Sprint 1.14 (`AppError` record shape `errorKind`,
  `errorMsg`, `errorCause :: Maybe SomeException`), Sprint 1.15 (naming-helper
  signatures with DNS-1123 / 63-character constraints), and Sprint 1.21 (enumerated
  forbidden renderer inputs).
- Phase 2 — **Sprints 2.9–2.16**: Explicit daemon lifecycle
  (`load→prereq→acquire→ready→serve→drain→exit`) with worker loops wrapped in `try`/`catch`
  + bounded retry-with-backoff; `/healthz`, `/readyz`, `/metrics` endpoints with response
  shapes captured as golden tests; `BootConfig` / `LiveConfig` split with `SIGHUP` hot
  reload and atomic-swap discipline on `envLiveConfig`; structured JSON logging via `co-log`;
  test hooks in `Env`; `prodbox-daemon-lifecycle` test stanza asserting that single SIGTERM
  begins drain and second SIGTERM (or drain deadline) forces exit; daemon CLI plumbing
  (`--config`, `--log-level`, `--port`, `--foreground`) plus `PRODBOX_*` env-var precedence
  rule; formal at-least-once event-processing module
  (`src/Prodbox/Daemon/Events.hs`) with `StoredEvent` / `recordEvent` /
  `markEventProcessed` / `fetchUnprocessedEvents` and idempotent `EventHandler`; and — added
  by Sprint 0.3 — the default 30 s drain deadline plus explicit `bracketOnError` on
  external-side-effect resources (2.9); the `envMetrics :: MetricsRegistry` typed daemon
  `Env` field consumed by `/metrics` (2.10); the STM broadcast channel for `LiveConfig`
  subscribers plus the prescribed on-disk Dhall file shape (2.11); and the daemon log
  level refreshed from `LiveConfig` on every hot reload (2.12). Sprint 0.4 threads the
  round-3 extensions through Sprint 2.9 (enumerated structured-concurrency primitive set
  `withAsync` / `race` / `concurrently` / `replicateConcurrently`), Sprint 2.11 (forbidden
  reload triggers `fsnotify`, `inotify`, `mtime` polling; typed `schemaVersion : Natural`
  Dhall field with mismatch-as-parse-failure; eight-step reload procedure step-by-step),
  Sprint 2.12 (typed `field :: (Aeson.ToJSON a) => Text -> a -> (Text, Aeson.Value)` helper
  plus `logStructured` / `logDebug` / `logInfo` / `logWarn` / `logError` wrappers),
  Sprint 2.13 (production-no-op / test-injected hook contract bound), and Sprint 2.14
  (health-endpoint response shapes captured as golden tests inside the lifecycle stanza).
- Phase 3 — **Sprints 3.8–3.12**: Smart constructors for paired chart resources; capability
  classes applied to Redis and Postgres chart call sites; reconciler discipline on
  `prodbox charts deploy` / `delete`; `--dry-run` on chart operations; `prodbox lint chart`
  Helm-chart structural-invariants linter; and marker-delimited route-inventory generation
  from `src/Prodbox/PublicEdge.hs` into chart artifacts via the `GeneratedSectionRule`
  registry. Sprint 0.4 extends Sprint 3.10 with the named forbidden reconciler flags
  (`--force`, `--reinstall`) and forbidden sister commands (`install`, `upgrade`,
  `repair`, `force-install`) on the chart surface.
- Phase 4 — **Sprints 4.5–4.8**: Rename the legacy lifecycle command to
  `prodbox rke2 reconcile`, retire the one-cycle `install` alias after its compatibility
  window, apply lifecycle Plan / Apply + `--dry-run`, and add the `prodbox-pulumi` test
  stanza. Sprint 0.4 extends Sprint 4.5 with the same forbidden-flag and sister-command
  discipline on the lifecycle reconciler, so `install`, `upgrade`, `repair`, and
  `force-install` are rejected at parse time. Sprint `4.8` makes successful
  `prodbox rke2 delete --yes` runs hermetic and summary-owned by `prodbox`, while preserving
  actionable upstream context on failure.
- Phase 4 — **Sprints 4.10–4.13** (added May 21, 2026 to bind the lifecycle reconciliation
  doctrine into code): Sprint `4.10` decouples long-lived Pulumi state onto a dedicated
  operator-account S3 bucket so the `aws-ses` stack survives `rke2 delete + rke2 reconcile`
  cycles. Sprint `4.11` introduces the composable `Precondition` algebra and the
  `prodbox rke2 delete --cascade` / `--allow-pulumi-residue` flag matrix (mutually exclusive
  at parse time) so orphaning per-run Pulumi-managed AWS resources is structurally
  impossible. Sprint `4.12` adds the K8s drain phase that deletes LoadBalancer Services, ALB
  Ingresses, and Delete-reclaim PVCs before per-run Pulumi destroys, so AWS-side controllers
  can unwind cleanly. Sprint `4.13` introduces `prodbox nuke`, the operator-only total-
  teardown command that refuses non-TTY contexts and requires the typed-confirmation
  literal `NUKE EVERYTHING`. Code frameworks for all four sprints landed May 21, 2026; the
  live operator validations (AwsSesStack admin-credential switch + live migration body,
  live cascade exercise against a running cluster, live `nuke` exercise) are tracked as
  remaining work in the respective sprint blocks.
- Phase 4 — **Sprints 4.14 + 4.15** (added May 21, 2026 from the live
  `prodbox rke2 delete --help` and `--cascade --yes` review):
  Sprint `4.14` enforces the operator vocabulary contract introduced
  in
  [cli_command_surface.md § 2A](../documents/engineering/cli_command_surface.md#2a-operator-vocabulary-contract)
  — `Sprint <number>` labels and other dev-plan tracking vocabulary
  must not appear in any operator-facing CLI surface
  (`prodbox <command> --help`, manpages under `share/man/`, shell
  completions under `share/completion/`, the generated
  `documents/cli/commands.md`, or stdout/stderr emitted by the
  binary at runtime). Implementation rewrites the sprint-tagged
  strings in `src/Prodbox/CLI/Spec.hs` and the cascade narration in
  `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade`, then adds a
  `Sprint [0-9]` regex scan to `prodbox check-code`. Sprint `4.15`
  closes the symptom surfaced when an operator runs
  `prodbox rke2 delete --cascade --yes` on a host without a cluster:
  the drain phase currently calls `kubectl delete services` against
  `localhost:8080` and fails noisily. Implementation adds a
  `DrainSkipped <reason>` constructor to the `DrainResult` ADT in
  `src/Prodbox/Lifecycle/K8sDrain.hs`, a quick
  `kubectl cluster-info --request-timeout=5s` reachability probe,
  and a cascade caller arm that treats `DrainSkipped` as
  success-with-reason — matching the
  [reconciler-with-predicates doctrine](../documents/engineering/lifecycle_reconciliation_doctrine.md#3-the-reconciler-with-predicates-pattern)
  rule that source-of-truth queries tolerate the case where the
  authoritative source is already gone.
- Phase 5 — **Sprint 5.5**: Add a Gateway API HTTP listener on port `80` that never routes
  plaintext backend traffic and only returns a permanent redirect to the canonical
  `https://test.resolvefintech.com/<service-path>` URL. Extend `prodbox host public-edge` and
  the external public-host validation surface to prove the redirect alongside the existing
  HTTPS-only application traffic contract. This follow-up is `Done` and was validated by the
  May 13, 2026 `./.build/prodbox test all` run.

The earlier alignment follow-up on native `gateway-partition` validation, peer trust-material
runtime closure, root-chart-only public chart commands, the Harbor-plus-storage-backend
bootstrap contract, and the later Phase `2` cleanup follow-up that removed the retained legacy
`NTP synchronized` `timedatectl` parser branch in `src/Prodbox/Host.hs` is complete in both
governed docs and code; those closures sit inside the Sprint 1.1–1.5, 2.1–2.8, 3.1–3.7,
4.1–4.4, 5.1–5.4, 6.1–6.3, and 7.1–7.N surfaces and are unchanged by the doctrine reopen.

The authoritative target still closes on:

- one Haskell-owned CLI, lifecycle, Pulumi, gateway-daemon, public-workload, chart, onboarding,
  AWS, and test surface
- one leak-proof, idempotent command topology: every AWS or cluster resource prodbox can create
  is a registered entry in the managed-resource registry (typed `discover` + `destroy`), teardown
  is one idempotent `reconcileAbsent` reconciler with `Unreachable` never silently passing, and
  `check-code` makes a creatable-but-undiscoverable resource unrepresentable (per
  [lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md);
  scheduled as Phase 4 Sprints 4.20–4.22 and Phase 7 Sprint 7.8)
- one direct `Dhall -> Haskell types` config contract rooted at operator-authored
  `prodbox-config.dhall`
- one Harbor-first local lifecycle that reconciles MetalLB, Envoy Gateway, cert-manager, Harbor,
  MinIO, and the Percona PostgreSQL operator on the supported self-managed cluster path
- one supported public-edge doctrine where every externally reachable application or dashboard sits
  behind Envoy Gateway on `test.resolvefintech.com`, distinguished only by explicit path prefixes
  such as `/auth`, `/vscode`, `/api`, `/ws`, `/harbor`, and `/minio`, protected by Keycloak-
  backed JWT auth or RBAC, covered by one Route 53 record plus one listener certificate, and
  fronted by a port `80` HTTP listener that only redirects to HTTPS
- one native-host-architecture lifecycle image-publication doctrine where `amd64` hosts build and
  publish only `amd64` images, `arm64` hosts build and publish only `arm64` images, and no
  supported path uses `docker buildx` or cross-arch emulation
- one explicit steady-state JWT boundary where Envoy validates Keycloak-issued tokens locally and
  does not require per-request Keycloak or Redis calls on the hot path
- one explicit Keycloak availability boundary where new logins, refresh flows, and later JWKS
  refresh depend on Keycloak, while the steady-state JWT hot path at Envoy does not require
  per-request Keycloak or Redis access
- one explicit distinction between the Envoy Gateway public edge and the separate Haskell
  distributed gateway daemon shipped through `prodbox gateway ...` and
  `prodbox charts deploy gateway`
- one explicit current transport boundary where public TLS terminates at Envoy and backend TLS or
  mTLS stays outside the supported chart-workload contract unless a later doctrine revision
  expands that path
- one Redis surface that currently backs WebSocket shared state and may later back an explicit
  external rate-limit service, but does not yet ship a standalone rate-limit-service workload or
  validation surface
- one cleanup ledger that preserves completed removal history; after the May 23, 2026 reopen of
  Phases `2`, `3`, and `4` the only open rows are the cluster-as-source-of-truth and
  native-HTTP-client cleanups owned by Sprints `2.17`, `3.13`, `4.16`, and `4.18`

The implemented clean-room rerun proof remains the Phase `6` command contract expressed through
`prodbox test all`, `prodbox config show`, `prodbox config validate`, and
`prodbox host public-edge`. Separate repository review gates still verify that `example.com` and
zero-Python residue stay out of supported-path sources, but those checks are not a dedicated
`prodbox` command. The canonical automated validation contract otherwise remains the `prodbox`
command surface documented by this plan: `prodbox check-code`,
`prodbox test unit`, `prodbox test integration cli`, `prodbox test integration env`, and the
canonical test suite behind `prodbox test integration ...` (planned by
`src/Prodbox/TestPlan.hs`, dispatched by `src/Prodbox/TestValidation.hs`, orchestrated by
`src/Prodbox/TestRunner.hs`). Per
[development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates),
that canonical suite runs against substrates — today the home local substrate and the AWS
substrate (see [substrates.md](substrates.md)) — and substrate-specific provision and
teardown belong to the substrate-owning phase docs, not to suite content. Substrate parity is
tracked in [substrates.md](substrates.md) and in the Substrate Parity table below.

The rewrite remains on the canonical phase model required by
[development_plan_standards.md](development_plan_standards.md).

## Document Index

| Document | Purpose |
|----------|---------|
| [development_plan_standards.md](development_plan_standards.md) | Conventions for maintaining the development plan |
| [system-components.md](system-components.md) | Authoritative target component inventory for the Haskell rewrite |
| [substrates.md](substrates.md) | Authoritative inventory of substrates the canonical test suite runs against |
| [00-overview.md](00-overview.md) | Target architecture, current baseline, and hard constraints |
| [phase-0-planning-documentation.md](phase-0-planning-documentation.md) | Phase 0: Planning and documentation topology for the rewrite |
| [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) | Phase 1: Haskell runtime, CLI, config, and Pulumi foundations |
| [phase-2-gateway-dns.md](phase-2-gateway-dns.md) | Phase 2: Haskell gateway runtime and DNS ownership |
| [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) | Phase 3: Haskell chart platform and public workload delivery |
| [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) | Phase 4: Lifecycle hardening, Pulumi decoupling, and Python removal |
| [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) | Phase 5: Canonical test suite — substrate-agnostic named validations |
| [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) | Phase 6: Final clean-room rerun and zero-Python handoff |
| [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) | Phase 7: AWS substrate foundations — onboarding, IAM, quota, and AWS substrate parity with the canonical suite |
| [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) | Phase 8: Operator-invited email authentication via Keycloak + AWS SES |
| [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) | Comprehensive ledger of cleanup/removal history and ownership |

## Sprint Status

### Status Vocabulary

| Status | Meaning | Emoji |
|--------|---------|-------|
| **Done** | Deliverables implemented for the sprint-owned surface, validated, and aligned in docs | ✅ |
| **Active** | Work has started and remaining implementation or documentation work is explicitly listed | 🔄 |
| **Blocked** | Closure depends on an unmet prerequisite or prior sprint closure | ⏸️ |
| **Planned** | Ready to start once execution reaches the sprint in sequence | 📋 |

### Definition of Done

A sprint can move to `Done` only when all of the following are true:

1. Its deliverables are implemented in the worktree.
2. Its validation commands pass through the canonical `prodbox` surface.
3. The docs listed in `Docs to update` are aligned with the implemented behavior.
4. Sprint-owned cleanup is reflected in
   [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
5. No sprint-owned blocker or remaining work survives.

## Phase Overview

| Phase | Name | Status | Document |
|-------|------|--------|----------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | ✅ Done (Sprints 0.1–0.8). Sprint 0.8 (May 24, 2026 — pure-Dhall config doctrine adoption) closed on its owned doc-revision surface: `documents/engineering/config_doctrine.md` SSoT created, governed engineering and root docs revised to defer to it, plan suite updated, and the four validation gates exit 0 (`prodbox lint docs`, `prodbox docs check`, `prodbox check-code`, `prodbox test unit` 533/533). The code-implementation work lands in Phase 1 Sprint 1.28, Phase 2 Sprints 2.20/2.21/2.22, and Phase 3 Sprint 3.14. | [phase-0-planning-documentation.md](phase-0-planning-documentation.md) |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | ✅ Done (Sprints 1.1–1.28). Sprint 1.28 (May 24, 2026) closed the `dhall` allow-newer + env-var-read lint rule contract: existing `allow-newer: *:base, *:template-haskell` continues to satisfy the `dhall ^>=1.42` transitive deps under GHC 9.14.1; `src/Prodbox/CheckCode.hs::checkEnvVarConfigReads` wired into the doctrine-alignment check; `PRODBOX_LOG_LEVEL` / `PRODBOX_CONFIG_PATH` / `PRODBOX_PORT` env-var reads removed from `src/Prodbox/Gateway.hs`; daemon-lifecycle tests updated to the new sole-CLI-source contract. | [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) |
| 2 | Haskell Gateway Runtime and DNS Ownership | ✅ Done (Sprints 2.1–2.16); ✅ Sprint 2.17 (native Haskell HTTP client replaces curl on the host-side CLI surface, May 23, 2026; TestValidation + RKE2-installer curl callers remain on the ledger as Sprint 4.18 follow-up); ✅ Sprint 2.18 (foundational host-side `host firewall gateway-restrict --port PORT` subcommand + pure rule helpers, May 23, 2026; chart-side NodePort + reconcile wiring land with Sprint 2.19); ✅ Sprint 2.20 (May 24, 2026 — full closure: `Prodbox.Gateway.Types.parseDaemonConfig` removed from the codebase; `Prodbox.Gateway.Settings.loadDaemonConfig` decodes Dhall exclusively via `Dhall.inputFile auto`; `renderGatewayConfigTemplate` emits Dhall (operator `gateway config-gen` produces `.dhall`); all JSON fixtures across `test/unit/Main.hs`, `test/integration/CliSuite.hs`, `test/daemon-lifecycle/Main.hs` migrate to Dhall; goldens updated; 543/543 unit tests, 28/28 integration cli, 28/28 integration env, 14/14 daemon-lifecycle); 🔄 Sprint 2.21 (May 24, 2026 — `fsnotify ^>=0.4` added; `configFileWatchLoop` worker watches the daemon's `--config` parent directory and feeds `envReloadSignals`; SIGHUP handler removed; BootConfig changes drain-and-exit per doctrine §8; `forbidFsnotify`/`forbidInotify`/forbid-mtime lint rules and matching markers removed; daemon-lifecycle stanza 14/14, live operator exercise gates closure); 🔄 Sprint 2.22 (May 24, 2026 — full code-owned chart-side closure: `configmap-config.yaml` + `configmap-orders.yaml` render Dhall; `secret-aws-credentials.yaml` + `secret-minio-creds.yaml` ship Dhall fragments at `/etc/gateway/secrets/{aws,minio}.dhall` (MinIO credentials persist across upgrades via `lookup` + `randAlphaNum`); `deployments.yaml` removes all `AWS_*` / `MINIO_*` / `GATEWAY_NODE_ID` env vars and mounts the new Dhall Secrets at the canonical paths. `DaemonConfigDhall` extended with `aws_creds` / `minio_creds` sub-records; `DaemonConfig` carries `daemonAwsCreds` / `daemonMinioCreds`; `writeDnsRecord` projects credentials into the aws CLI subprocess env instead of inheriting Pod env. Standalone live decode verified: `prodbox gateway start --config <rendered>.dhall --foreground` follows Dhall imports for aws/minio/orders and starts the daemon. Live RKE2 reconcile remains as the closure gate.); 🔄 Sprint 2.19 (master-seed wiring landed May 24, 2026: `Prodbox.Gateway.Daemon.acquireInitialMasterSeed` retrieves the seed at startup via `daemonMinioCreds`; `envMasterSeed` caches it on `DaemonEnv`; `/v1/secret/derive?context=<ctx>` is live-wired and returns a typed `DeriveResponse` (or structured 503 if seed unavailable); live verified on this host that the 503 fallback path fires correctly when MinIO is absent. **May 24, 2026 later session — reconcile/delete firewall wiring landed**: new `defaultGatewayNodePort = 30443` constant + `runHostFirewallGatewayRestrictOptional` (treats absent iptables and unprivileged caller as success-with-reason) in `Prodbox.Host`; `applyChartDeployWithPostHook` / `applyChartDeleteWithPostHook` chain restrict/unrestrict after gateway chart deploy/delete; safety-net unrestrict added to `runNativeDelete` and `runNativeDeleteCascade` step 4. **May 24, 2026 still-later session — MinIO endpoint plumbing + bucket bootstrap landed**: new `boot.minio_endpoint_url :: Maybe Text` sibling field on `DaemonBootDhall`; matching `daemonMinioEndpointUrl :: Maybe String` on `DaemonConfig`; new `Prodbox.Secret.MasterSeed.minioMasterSeedConfigFromUrl` that accepts a full endpoint URL; `acquireInitialMasterSeed` prefers the Dhall-bound endpoint and falls back to `127.0.0.1:9000` only for non-chart smoke runs. `charts/gateway/templates/configmap-config.yaml` renders the endpoint via `{{ .Values.minio.endpointUrl }}` (default `http://minio.prodbox.svc.cluster.local:9000` in `values.yaml`). New reconcile step `ensureGatewayMinioBucket` deploys a one-shot Job in the `minio` namespace that runs `mc mb --ignore-existing local/prodbox`. Transitional credential sourcing: `charts/gateway/templates/secret-minio-creds.yaml` resolves MinIO root credentials via cross-namespace Helm `lookup "v1" "Secret" "prodbox" "minio"` so the daemon authenticates as root until the dedicated `prodbox-gateway` IAM user + scoped policy land. Sprint 2.20 closure also cleared seven unused legacy JSON-parser helpers from `Prodbox.Gateway.Types` (`validateIntervals` / `validateMaxSkew` / `validateDrainDeadline` / `parseDnsWriteGate` / `rejectForbiddenCredKeys` / `readOptionalFloat` / `requireObject` / `readOptionalInt` / `readOptionalString` / `parseEventKeys` / `hasSuffix`). Validation: `prodbox check-code` exit 0; `prodbox test unit` 543/543; `prodbox test integration cli` 28/28; `prodbox test integration env` 28/28; `prodbox-daemon-lifecycle` 14/14. Live RKE2 reconcile + gateway chart deploy + end-to-end master-seed exercise + dedicated `prodbox-gateway` IAM user/policy remain as the closure gate) — replaces ⏳ Sprint 2.19 (pure `Prodbox.Secret.Derive` landed May 23, 2026 + wire-contract layer `Prodbox.Secret.Wire` / typed `Prodbox.Gateway.Client.derive` / `ensureNamespace` / structured-503 daemon route stubs landed May 23, 2026 + chart-side scaffolding `charts/gateway/templates/secret-minio-creds.yaml` + `service-nodeport.yaml` + gateway pod `MINIO_*` env wiring landed May 23, 2026 + symmetric `runHostFirewallGatewayUnrestrict` helper + `prodbox host firewall gateway-unrestrict` subcommand landed May 23, 2026. **`Prodbox.Secret.MasterSeed` foundation landed May 23, 2026 later session** — new module shells out to `aws s3api` via `Prodbox.Service.runMinIOWithEnv` (no new `amazonka-s3` / `minio-hs` dep needed today); exposes `MinioMasterSeedConfig`, `MasterSeedError` ADT (6 constructors), `ensureMasterSeed` with `If-None-Match: *` concurrent-creation guard + post-PUT GET re-read, `generateFreshSeedBytes` (reads 32 bytes from `/dev/urandom`), pure `awsS3Api{Head,Get,Put}Args` helpers + AWS-CLI error-blob recognizers; 14 new unit tests pin the wire shape (test count 533/533, up from 519). MinIO IAM bootstrap + live daemon endpoint bodies (replacing the structured 503 stubs with `ensureMasterSeed` ∘ `derive` and the per-context `ensure-namespace` inventory) + automatic reconcile/delete firewall-rule wiring remain as coupled deliverables, **re-scoped May 24, 2026 to source MinIO endpoint + creds via the new pure-Dhall config doctrine** ([config_doctrine.md](../documents/engineering/config_doctrine.md)); the `MINIO_ENDPOINT_URL` env-var addition attempted earlier was rolled back the same day, and the remaining Sprint 2.19 deliverables block on Sprints 2.20/2.21/2.22 (daemon Dhall settings module, file-watch reload, chart-side Dhall ConfigMap + Secret-mounted credentials)); 📋 Sprint 2.20 (daemon Dhall settings module — new `src/Prodbox/Gateway/Settings.hs` mirroring the host `Settings.hs` pattern, replacing `parseDaemonConfig`'s JSON path; blocked on Sprint 0.8); 📋 Sprint 2.21 (file-watch reload trigger with drain-and-exit on boot-field changes — adds the file-watch library, replaces the SIGHUP handler, implements the BootConfig drain path; blocked on Sprint 2.20); 📋 Sprint 2.22 (chart-side Dhall ConfigMap + Secret-mounted credentials — rewrites `charts/gateway/templates/configmap-{config,orders}.yaml` to render Dhall content, adds the `gateway-secrets-*` Secrets mounted at `/etc/gateway/secrets/`, removes `AWS_*` / `MINIO_*` / `GATEWAY_NODE_ID` env vars from `deployments.yaml`; blocked on Sprints 2.20/2.21) | [phase-2-gateway-dns.md](phase-2-gateway-dns.md) |
| 3 | Haskell Chart Platform and Public Workload Delivery | ✅ Done (Sprints 3.1–3.12); 🔄 Sprint 3.14 (May 24, 2026 — code-owned surface landed: new `Prodbox.Workload.Settings` Dhall decoder + `--config` flag on `workload start` + `WorkloadConfigDhall` covering `< Api | Websocket >` mode + optional log_level/port/redis/oidc; `runWorkloadServer` dispatches through `resolveWorkloadModeFromConfig` with env-var fallback; new `charts/api/templates/configmap-config.yaml` + `charts/websocket/templates/configmap-config.yaml` render Dhall content; `deployment.yaml` templates wire `--config /etc/workload/config.dhall` + matching ConfigMap volume mount; 3 new unit tests cover happy-path Api/Websocket decode + schemaVersion mismatch. **May 24, 2026 later session — full Dhall read-through landed**: `runWorkloadServer` now loads the Dhall config once via `resolveWorkloadDhallConfig` and threads `Maybe WorkloadConfigDhall` through every resolver; new `resolveWorkloadModeFromDhall` / `resolveHttpPortWithDhall` / `resolveWorkloadLogLevelWithDhall` plus refactored `resolveWebsocketRuntime`/`resolveRedisConfig`/`resolveOidcConfig` use the Dhall sub-records when `--config` is set; `PRODBOX_WORKLOAD_MODE` / `PRODBOX_HTTP_PORT` / `PRODBOX_REDIS_HOST` / `PRODBOX_REDIS_PORT` / `PRODBOX_OIDC_*` env vars removed from `charts/api/templates/deployment.yaml` and `charts/websocket/templates/deployment.yaml` — the Dhall ConfigMap is now the sole source on the chart-side surface. Validation: `prodbox check-code` exit 0; `prodbox test unit` 543/543; `prodbox test integration cli` 28/28; `prodbox test integration env` 28/28; `prodbox-daemon-lifecycle` 14/14. Live operator exercise (`prodbox rke2 reconcile` + `prodbox charts deploy api` / `prodbox charts deploy websocket`) is the closure gate.) | [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | ✅ Done (Sprints 4.1–4.8); 🔄 Active Sprints 4.10–4.13 (code frameworks landed May 21, 2026: 4.10 Dhall types + Settings.hs decoder + `LongLivedPulumiBackend` module + `aws-ses-migrate-backend` CLI scaffold; 4.11 `Lifecycle/Preconditions` + `Lifecycle/TagSweep` + `rke2 delete --cascade` / `--allow-pulumi-residue` flags with mutual exclusion; 4.12 `Lifecycle/K8sDrain` module wired into cascade; 4.13 `prodbox nuke` CLI scaffold with TTY guard + typed-confirmation literal + dry-run plan renderer. ✅ Sprint 4.17.a (May 28, 2026 — reorder cascade to doctrine-canonical `confirm-MinIO → drain → per-run destroys → uninstall → sweep`; new `cascadeOrderNarration` constant + 5 unit tests pin the order; live AWS-substrate verification rolls up with Sprint 4.17.b). ✅ Sprint 4.17.b (May 28, 2026 — `runCascadeDrainPhase` substrate-aware via new `buildDrainEnvironment` helper; cascade infers substrate from per-run residue via new pure `inferCascadeSubstrate`; `DrainSkipped` on AWS substrate is now a hard failure; 6 unit tests cover the inference; live AWS-substrate verification is the remaining closure gate). Sprint 4.13's five-step nuke orchestration body landed May 21, 2026 (composes cascade arm → `aws-ses` destroy → operational IAM teardown → postflight tag sweep → long-lived state-bucket destroy in-process, prompting once for admin AWS credentials at the start); Sprint 4.10's `pulumi/aws-ses/Pulumi.yaml` long-lived S3 backend URL declaration landed the same day. AwsSesStack admin-credential switch + migrate-backend body + `aws teardown` predicate library reimplementation + every live operator validation remain pending.); ✅ Sprint 4.14 (operator vocabulary contract enforcement: `Sprint <digit>` leaks removed from CLI help / manpages / completions / generated CLI docs / test goldens; new `checkOperatorVocabulary` scan in `src/Prodbox/CheckCode.hs` refuses regressions; May 21, 2026); ✅ Sprint 4.15 (cascade tolerates absent cluster: new `DrainSkipped String` constructor on `DrainResult`; new `clusterReachable` probe; `runNativeDeleteCascade` treats `DrainSkipped` as success-with-reason and continues to per-run Pulumi destroys; verified live on a host without an rke2 cluster; May 21, 2026); ✅ Sprint 4.16 (`ResidueStatus` source-of-truth swap closed 2026-05-27 on the code-owned surface: new `src/Prodbox/Lifecycle/LiveResidue.hs` exposes `PerRunResidueStatuses` plus `queryPerRunResidueStatuses` / `queryAwsSesResidueStatus` — one shared MinIO port-forward bracket for the three per-run stacks, admin-credentialled S3 query for `aws-ses`; per-stack `<stack>ResidueStatus` now delegates to the live module and the four `<stack>HasLiveResources` boolean predicates are removed; `Prodbox.Aws.checkPulumiResidueBeforeTeardown` splits into the pure `categorizePulumiResidue :: PerRunResidueStatuses -> ResidueStatus -> [(String,String)]` plus an IO wrapper that batches one MinIO + one S3 query; `Prodbox.Lifecycle.Preconditions.noLive{PerRun,LongLived}PulumiStacks` and `Prodbox.CLI.Rke2.runNativeDeleteCascade` use the batch; new test-only env var `PRODBOX_TEST_RESIDUE_ABSENT=1` (documented at the test-fixture boundary, set by `fakeAwsEnvironment` / `fakeAwsHarnessEnvironment`) short-circuits both queries to `ResidueAbsent` for the fake-AWS-CLI integration paths; 17 unit tests rewritten from `writeFakeStackSnapshot tmpDir "<stack>"` + `checkPulumiResidueBeforeTeardown` to synthetic `PerRunResidueStatuses` + `categorizePulumiResidue`; 13 new tests cover the LiveResidue pure helpers and the per-lifecycle-class doctrine asymmetry (per-run unreachable → absent; long-lived unreachable → still-present); validated with `prodbox check-code` exit 0, `prodbox test unit` 567/567 (up from 554), `prodbox test integration cli` 28/28, `prodbox test integration env` 28/28, `prodbox-daemon-lifecycle` 14/14; snapshot file-IO removal is Sprint 4.18 scope; live AWS-substrate regression rolls up with Sprint 7.5.c.v); 🔄 Sprint 4.17 (cascade canonical order rewrite landed May 23, 2026 p.m. — `runNativeDeleteCascade` reordered to confirm-MinIO → per-run destroys → drain → uninstall → postflight sweep; new pure helper `perRunCascadeInventory` drives 7 new unit tests; **the postflight tag sweep wiring landed May 23, 2026 later session** — `runCascadePostflightTagSweep` now loads admin credentials via `loadAdminAwsCredentials`, builds the admin AWS env via `adminAwsEnvironment`, and calls `Prodbox.Lifecycle.TagSweep.discoverClusterTaggedAwsResources` with `awsEksCanonicalClusterName` as the cluster filter; empty result reports "clean", non-empty result emits the full `renderTagSweepRefusal` block, cascade returns `ExitSuccess` either way per doctrine §6; 4 new tests cover refusal-block ARN/tag rendering, multi-resource bullet output, empty-list rendering, and `TagSweepInput` shape; live cascade exercise on this host remains as the closure gate); 🔄 Sprint 4.18 (inventory audit landed May 23, 2026; first chunk landed 2026-05-27 a.m.: tarball scratch moved to system tmp dir; `Prodbox.Lifecycle.LiveResidue.fetchPerRunStackOutputs` + `fetchAwsSesStackOutputs` foundation; `resolveSubstrateHostedZoneId` + `verifyAwsEksSnapshot` migrated to live reads. Second chunk landed 2026-05-27 later session: new pure parsers `parseAwsTestNodesFromOutputs` + `parseAwsEksTestStackFromOutputs` decode the live `Map Text Text` outputs into structured `[AwsTestNode]` and `AwsEksTestStackSnapshot` records; `verifyAwsTestSnapshot`, `verifyAwsTestSshReachability` (sharing a new `fetchAwsTestNodes` helper), and `ensureAwsSubstratePlatformRuntime` migrated to live reads; new `PRODBOX_TEST_PER_RUN_OUTPUTS_DIR` test override on `fetchPerRunStackOutputs` lets the unit suite exercise the migrated consumers without a MinIO port-forward; 7 new unit tests pin the parsers (test count 574/574, up from 567); the existing SSH-retry test is rewritten to inject the `nodes` output through the override. Remaining: removing the surviving `saveXxxStackSnapshot`/`clearXxxStackSnapshot` callsites in the four per-stack modules, replacing `awsEksTestKubeconfigPath` with a `withEksKubeconfig` bracket, replacing the local SSH-keygen surface with a Pulumi-stored private-key output, and landing the `forbidDotProdboxState` lint after Sprint 3.13's chart-secret cache closes); ✅ Sprint 4.19 (2026-05-28 — `rke2 delete` / `aws teardown` per-run residue gate fails closed on `ResidueUnreachable`: `isResiduePresentOrUnknownPerRun` realigned to its name, `noLivePerRunPulumiStacks` branches on the `ResidueStatus` constructor with a distinct "cannot read per-run Pulumi state backend; do NOT delete `.data/`; or `--allow-pulumi-residue`" refusal; `categorizePulumiResidue` matches; new test-only `PRODBOX_TEST_RESIDUE_UNREACHABLE` override; `--cascade`'s `perRunCascadeInventory` unchanged (graceful degradation + tag-sweep backstop). Closes the silent-pass-on-unreachable defect that let a clean-teardown signal precede a `.data` wipe and orphan live AWS resources. `prodbox check-code` exit 0; `test unit` 578/578; `test integration cli` 30/30; `test integration env` 30/30; live operator verification residual); ✅ Sprint 4.20 (2026-05-28 — managed-resource registry foundation: new `Prodbox.Lifecycle.ResourceClass` SSoT facts (`LifecycleClass` + `resourceLifecycleClasses`); `perRunStackNames`/`longLivedStackNames` derived from it; single `residueBlocksTeardownGate` soundness combinator replacing the per-class `isResiduePresentOrUnknown*` booleans; generalizes 4.11/4.16/4.19 into one pattern per [lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md). Behavior-preserving; `check-code` 0, `test unit` 583/583, `test integration cli` 30/30, `test integration env` 30/30. The IO `ManagedResource` record + `reconcileAbsent` move to 4.21 with their consumer); ✅ Sprint 4.21 (2026-05-28 — new `Prodbox.Lifecycle.ResourceRegistry`: `ManagedResource` + `perRunManagedResources` + pure `pairPerRunResidue`/`resourcesToDestroy` + `reconcileAbsent`; `runNativeDeleteCascade` per-run destroy phase routed through `reconcileAbsent` behavior-preservingly; `perRunCascadeInventory` removed. Validated `check-code` 0, `test unit` 584/584, `test integration cli`/`env` 30/30, plus a live `rke2 delete --cascade --yes` smoke on this host (clean exit 0, reconcileAbsent skip-path confirmed). Present→destroy live exercise rolls up with the next AWS-substrate cascade run); ✅ Sprint 4.22 (2026-05-28 — `substrates.md` Resource Lifecycle Classes inventory is a generated section rendered from `resourceLifecycleClasses` via a new `GeneratedSectionRule`, so `docs check` fails on registry↔doc drift; `renderRegisteredResourcesMarkdown` + renderer unit test; `test unit` 585/585. The create-call-site coverage lint follow-on **also landed 2026-05-28**: `checkCreateCallSiteCoverage` scans the two narrow create surfaces — the `Pulumi<Word>Resources` constructors in `CLI/Command.hs` (pure `pulumiCreateSiteViolations` against the `pulumiCreateSiteOwners` map) and the operational-IAM verbs confined to `src/Prodbox/Aws.hs` (pure `iamCreateSiteViolations`); broader generic-`create*`/DNS-record scanning deliberately excluded to avoid false positives; `check-code` 0, `test unit` 600/600 (+6). Together with registry↔doc parity this completes the § 3.1 totality enforcement) | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| 5 | Canonical Test Suite | ✅ Done on owned surfaces (Sprints 5.1–5.5) | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | ✅ Done on owned surfaces | [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) |
| 7 | AWS Substrate Foundations | ✅ Done on legacy surfaces (Sprints 7.1–7.4); 🔄 Active Sprint 7.5 (✅ 7.5.a–7.5.c.iv on their code-owned surfaces, May 17–19, 2026; ✅ 7.5.c.v.b in-cluster custom-image push, May 19, 2026; ✅ 7.5.c.v.c harness preflight residue policy `BypassAllResidueForHarnessRefresh`, May 20, 2026; ✅ 7.5.c.v.d operational IAM policy compaction + S3 grants on SES capture bucket, May 20, 2026; ✅ 7.5.c.v.e read-only SES grants for Sprint 8.4 prereqs, May 20, 2026; ✅ 7.5.c.v.f silent-exit closure on code-owned surface (substrate-aware `prodbox host public-edge --substrate {home-local,aws}` + stderr breadcrumbs on `runNativeValidation`), May 21, 2026; 🔄 Sprint 7.5.c.v live AWS-substrate canonical-suite re-run remains as the residual live operator step); ✅ Sprint 7.6 (orphan-safety refuse-path + auto-destroy postflight, May 19, 2026); ✅ Sprint 7.7 (generalized `aws teardown` + `PulumiResiduePolicy` ADT + admin-credential prompt UX, May 19, 2026); 🔄 Sprint 7.8 (Phase 7 reopened 2026-05-28; unblocked by 4.20/4.21 — operational-coverage core landed 2026-05-28: the operational IAM user + `aws.*` config block are registered `Operational` `ManagedResource`s defined in `Prodbox.Aws` (`operationalManagedResources`, reusing the existing key/policy/user delete paths + a factored-out `clearOperationalAwsConfig`), discovered via the pure `operationalIamUserResidueFromExists` / `operationalAwsConfigResidueFromKey` mappers, and reconciled by `prodbox aws teardown` through `reconcileAbsent`; a dedicated operational gate **fails closed** on `ResidueUnreachable` (AWS IAM unobservable) instead of cascade-skipping, while `listOperationalAccessKeyIds` preserves the `DELETED_ACCESS_KEYS`/`USER_DELETED` result fields. Per [lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md); closes the coverage half of the IAM blind spot. `check-code` 0; `test unit` 594/594 (+9, new `Sprint 7.8 operational-resource registry` group); `test integration cli`/`env` 30/30 (fake AWS CLI learned `iam get-user`). Deferred follow-ons: the `PerRun` ∪ `Operational` teardown merge (per-run residue gating unchanged) and the live `prodbox test all --substrate aws` roll-up — status Active, not Done) | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) |
| 8 | Operator-Invited Email Authentication via Keycloak + AWS SES | 🔄 Active (✅ Sprint 8.1 code + doctrine + live SES provisioning + verification May 18, 2026; ✅ Sprint 8.2 Keycloak realm chart + live deploy proof on home substrate May 18, 2026; ✅ Sprint 8.3 CLI surface + live Keycloak admin API HTTP integration; ✅ Sprint 8.4 SES prerequisites; 🔄 Sprint 8.5 suite content + dispatch arm + live invite/capture/link-follow steps + SES SMTP IAM-to-SMTP-password derivation + chart-secrets persistence landed (credential-setup form POST + fresh OIDC login + claim assertions remain operator-driven sub-sprint, blocked on live Keycloak form-structure capture); 🔄 Sprint 8.6 doc parity landed (live cross-substrate proof pending 7.5.c + 8.5 OIDC follow-up closure). Sprints 8.1–8.4 ✅ Done; 8.5–8.6 carry the only remaining live OIDC closure work) | [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) |

**Status interpretation**: Phase `0` reopened through Sprints `0.2`–`0.7` to adopt
[the engineering doctrine docs](../documents/engineering/README.md) and to add the LLM/automation guardrails on
the interactive command surface; Phase `0` is now `Done` on that planning, documentation, and
non-TTY-guardrail surface. Phases `1`–`4` were reopened on the downstream doctrine-driven
implementation work and are now reclosed. Phase `5` is re-closed after Sprint `5.5` added and
proved the port `80`
HTTP-to-HTTPS redirect on the existing single-host public edge. The pre-reopen Haskell rewrite
baseline, clean-room rerun, public-edge proof, and AWS-administration surfaces remain validated
on the supported Haskell command surface; Phases `5`, `6`, and `7` remain `Done` on their owned
legacy scope per standards rule E. Phase `7` is **Active** on Sprint `7.5`, which the May 17,
2026 scoping review split into three sequentially-validatable sub-sprints (`7.5.a`, `7.5.b`,
`7.5.c`) to bring the AWS substrate to canonical-suite parity with the home substrate. Sprint
`7.5.b.iii` (substrate-independence doctrine refactor) was added between `7.5.b` and `7.5.c`
to make the no-fallback contract explicit across the governed doc set and is now `Done`.
Sprint `7.5.c`'s code follow-up landed May 18, 2026 — `substratePublicFqdn` /
`substrateHostedZoneId` are fail-fast on empty AWS-substrate config,
`resolveAwsEksSubzoneStackConfig`'s pre-provision gate requires only `subzone_name`,
`isAwsSubstrateConfigured` is removed, and the matching legacy-ledger row is moved to
`Completed`. The May 20 round of code-side closures (Sprints `7.5.c.v.c`, `7.5.c.v.d`,
`7.5.c.v.e`) unblocked the harness preflight against the long-lived `aws-ses` stack,
compacted the operational IAM policy under AWS's 2048-byte inline-user-policy cap, and added
the read-only SES grants the Sprint 8.4 prereqs need. The May 20 live re-run cleared every
prior gate and entered Phase 2/2 of the suite, but every named `--substrate aws` validation
body returned silently before producing output. Sprint `7.5.c.v.f` closed that diagnosis
on May 21, 2026 on its code-owned surface: `prodbox host public-edge --substrate
{home-local,aws}` threads `Substrate` end-to-end through `runHostPublicEdge`,
`queryRoute53RecordInZone`, `waitForPublicEdgeReady`, and the four substrate-aware
public-edge validation bodies, while `runNativeValidation` emits stderr breadcrumbs around
every body so silent exit is structurally impossible at the runner level. The live
AWS-substrate canonical-suite re-run (`prodbox test all --substrate aws`) closes Sprint
`7.5.c.v` and the parent Sprint `7.5.c`; the documented operator workflow lives in
[phase-7-aws-substrate-foundations.md → Sprint 7.5.c Operator Workflow](phase-7-aws-substrate-foundations.md).

Phase `8` was opened May 18, 2026 with the full code + doctrine layer of Sprints
`8.1`–`8.6` landed in a single session: `pulumi/aws-ses/` (Pulumi program for the
SES sending identity, receive subdomain MX, receive rule set, S3 capture bucket, and
SMTP IAM user); `src/Prodbox/Infra/AwsSesStack.hs` orchestration plus
`prodbox pulumi aws-ses-resources` / `aws-ses-destroy` CLI surface; the
`ses : { sender_domain, receive_subdomain, capture_bucket }` block in
`prodbox-config-types.dhall` and `prodbox-config.dhall`; Keycloak realm chart updates
(`verifyEmail: true`, `smtpServer`, new `keycloak-smtp` `Opaque` Secret) under
`charts/keycloak/`; the operator-facing `prodbox users invite|list|revoke` surface in
`src/Prodbox/CLI/Users.hs` and `src/Prodbox/UsersAdmin.hs`; three new
prerequisite nodes (`ses_sending_identity_verified`, `ses_receive_rule_set_active`,
`ses_receive_bucket_accessible`) wired through `src/Prodbox/Effect.hs`,
`src/Prodbox/Prerequisite.hs`, and `src/Prodbox/EffectInterpreter.hs` with AWS CLI
validators; the `ValidationKeycloakInvite` / `IntegrationKeycloakInvite` canonical-suite
variants planned by `src/Prodbox/TestPlan.hs` and dispatched through
`src/Prodbox/TestValidation.hs`; and the cross-substrate shared-SES doctrine in
[substrates.md](substrates.md) and
[documents/engineering/aws_integration_environment_doctrine.md](../documents/engineering/aws_integration_environment_doctrine.md).
Validated with `prodbox check-code`, `prodbox lint docs`, `prodbox docs check`, and
`prodbox test unit` (312/312). The residual live operator workflows for Phase `8` are
parallel to Sprint `7.5.c`'s live workflow: `prodbox aws setup` →
`prodbox pulumi aws-ses-resources` (Sprint `8.1` live), the Sprint `8.5` Keycloak admin
API HTTP integration in `src/Prodbox/UsersAdmin.hs` plus the SES capture-bucket polling
helper in `src/Prodbox/TestValidation.hs::runKeycloakInviteValidation`, and the Sprint
`8.6` cross-substrate `keycloak-invite` parity flip in [substrates.md](substrates.md).

## Substrate Parity

Per [development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates),
the canonical test suite is composed of per-substrate runs against both supported substrates,
with no fallback between them (see
[Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback)).
A complete canonical-suite proof requires both the home local and AWS substrate rows below to
land independently against their own real infrastructure. The authoritative substrate
inventory is [substrates.md](substrates.md); this section is the live tracker for substrate
parity. The authoritative AWS resource inventory and per-resource lifecycle class (auto-managed
per-run stacks vs long-lived cross-substrate shared infrastructure) live in
[substrates.md → Resource Lifecycle Classes](substrates.md#resource-lifecycle-classes).

| Substrate | Provision | Teardown | Suite parity | Phase ownership |
|-----------|-----------|----------|--------------|-----------------|
| Home local | `prodbox rke2 reconcile` + `prodbox charts deploy ...` | `prodbox rke2 delete --yes` | ✅ Full canonical suite, including real Let's Encrypt, OIDC, WebSocket, and public-edge proofs on `test.resolvefintech.com`. Re-verified May 27, 2026 via `prodbox test all` run-4 (~1h35m, all 16 named canonical validations `ExitSuccess` except `keycloak-invite` which is the documented Sprint 8.5 follow-up requiring live Keycloak credential-setup form-structure capture) | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| AWS | `prodbox pulumi eks-resources` + `prodbox pulumi aws-subzone-resources` + `prodbox pulumi test-resources` | `prodbox pulumi aws-subzone-destroy --yes` + `prodbox pulumi eks-destroy --yes` + `prodbox pulumi test-destroy --yes` | 🔄 Substrate-platform install (13 steps) lands on EKS; harness preflight and IAM policy compaction landed May 20, 2026; substrate-aware validation bodies + stderr-breadcrumb runner landed May 21, 2026 (Sprint `7.5.c.v.f`); live `prodbox test all --substrate aws` re-run rolls up into Sprint `7.5.c.v` | [phase-7-aws-substrate-foundations.md → Sprint 7.5](phase-7-aws-substrate-foundations.md) |

## Current Plan Status

The development plan remains authoritative. The repository worktree is fully closed against the
pre-reopen scope (Sprints 1.1–1.5, 2.1–2.8, 3.1–3.7, 4.1–4.4, 5.1–5.4, 6.1–6.3, 7.1–7.4), and
the doctrine-adoption reopen is now closed as well. Current worktree evidence puts Sprints
`0.7`, `1.6`–`1.27`, `2.9`–`2.16`, `3.8`–`3.12`, `4.5`–`4.8`, `4.14`, `4.15`, `5.5`,
`7.5.a`/`7.5.b.*`/`7.5.b.iii`/`7.5.c.i`–`7.5.c.iv`/`7.5.c.v.b`/`7.5.c.v.c`/`7.5.c.v.d`/
`7.5.c.v.e`/`7.5.c.v.f`, `7.6`, `7.7`, and `8.1`–`8.4` in `Done` state on their owned surfaces.
Sprints `4.10`–`4.13` have their full code bodies landed on their code-owned surfaces (May 21,
2026: Sprint 4.10's admin-credential switch + in-process migrate-backend body + Pulumi.yaml
backend URL; Sprint 4.11's full predicate inventory `noLivePerRunPulumiStacks`,
`noLiveLongLivedPulumiStacks`, `noLiveClusterTaggedAws`, `noUndrainedK8sAwsResources`,
`noLiveOperationalIamUser`, `noLeftoverDnsBootstrapRecords`; Sprint 4.13's
five-step nuke orchestration body + `destroyLongLivedPulumiStateBucket` helper); each was
exercised against the home substrate through `prodbox test all` runs that reached
`ready-for-external-proof` classification and ran every named canonical validation through to
the per-run Pulumi destroys. The live destructive `nuke` exercise and the live cascade exercise
against a running AWS-side cluster remain operator-driven follow-ups. A Sprint `7.5.c.v.d`
follow-up landed the same day to extend the operational IAM policy with the
`iam:CreatePolicy` / `CreateOpenIDConnectProvider` lifecycle actions the EKS Pulumi program
needs (run 3 / run 4 surfaced both gaps via live AWS AccessDenied); after the grants landed the
`aws-eks` validation provisioned EKS + LB controller IRSA + EBS CSI IRSA + OIDC provider and
destroyed cleanly. The remaining `Active` work outside Phase `4`
is: Sprint `7.5.c.v` (live AWS-substrate canonical-suite re-run, operator-driven against live
AWS) and Sprints `8.5`–`8.6` (live Keycloak credential-setup form-structure capture +
parser wire-in into `runKeycloakInviteValidation` + cross-substrate parity flip; the
form-parser scaffold lives in `src/Prodbox/Keycloak/CredentialSetupForm.hs` with synthetic
fixture). The following implemented baseline surfaces remain current on
the supported path:

- `src/Prodbox/Settings.hs` preserves the supported direct `Dhall -> Haskell types` contract by
  decoding repo-root `prodbox-config.dhall` in-process through the native `dhall` library, without
  materializing `prodbox-config.json`.
- `src/Prodbox/BuildSupport.hs`, `src/Prodbox/Repo.hs`, and `test/integration/EnvSuite.hs`
  preserve the operator-facing `.build/prodbox` artifact contract, repository-root config-path
  resolution, and the built-frontend env proof for the direct-Dhall settings surface.
- `src/Prodbox/CheckCode.hs` now enforces the governed doctrine-alignment contract described by
  `documents/engineering/code_quality.md`: it fails on repository-owned workflow or git-hook
  surfaces before it runs Fourmolu, HLint, warning-clean Cabal builds, and the operator-binary
  sync step, while excluding generated or retained runtime roots such as `.build/`,
  `dist-newstyle/`, `.prodbox-state/`, and `.data/` from the repo-owned policy scan.
- The supported public surface is Haskell-only. Python source, Python packaging, Python tests,
  Python Pulumi programs, Python type stubs, and Python bridge modules are removed.
- The supported config contract is direct `Dhall -> Haskell types`; `prodbox-config.json` and
  `prodbox config compile` are not part of the supported path.
- The public `config setup` and public `aws ...` surfaces use prompt-driven temporary admin AWS
  credentials (historically called "elevated credentials"), while stored
  `aws_admin_for_test_simulation.*` remains reserved for test-suite simulation of that prompt
  input, with the native IAM validation harness as the only supported runtime consumer.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and `src/Prodbox/TestValidation.hs`
  now route `prodbox test integration aws-iam`, `prodbox test integration all`, and
  `prodbox test all` through one shared suite-level IAM harness that provisions temporary
  operational `aws.*` before prerequisite-driven AWS validation begins and clears those
  credentials again before the suite returns.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/Prerequisite.hs`, and
  `src/Prodbox/EffectInterpreter.hs` now split the aggregate prerequisite model into an initial
  fail-fast gate plus a deferred cluster-backed backend proof, so `prodbox test integration all`
  and `prodbox test all` no longer fail at `pulumi_logged_in` before the visible `rke2 reconcile`
  phase has created or repaired the supported MinIO-backed Pulumi backend.
- The shared IAM harness deletes any pre-existing dedicated `prodbox` IAM user and that user's
  access keys, uses any pre-existing `aws.*` only to discover and delete the IAM user associated
  with those credentials, proves STS-federated operational credentials with a compact
  AWS-validation session policy, waits for the dedicated IAM-user credentials to pass STS and
  repeated Route 53 hosted-zone probes, materializes IAM-user operational `aws.*` only from
  `aws_admin_for_test_simulation.*` because cert-manager Route 53 DNS01 credentials do not
  support an STS session-token field, and clears `aws.*` from `prodbox-config.dhall` before
  returning even on later prerequisite failure.
- Supported AWS subprocesses now strip ambient AWS auth and profile variables before projecting
  repository-root credentials into the subprocess environment, so supported paths cannot fall back
  to host AWS auth state.
- The supported container topology lives entirely under `docker/`. Every repository-owned
  Haskell-build Dockerfile stays single-stage `ubuntu:24.04`, installs `ghcup` in-image, pins GHC
  `9.14.1`, and does not create symlinked Haskell tool shims.
- The authoritative local lifecycle target remains Haskell-owned and Harbor-first: Harbor plus
  Harbor's storage backend bootstrap from public registries, after which required public images
  and custom images are present in Harbor before later Helm deployments proceed.
- The Harbor mirror path retries transient Harbor publication failures on the same candidate and
  then falls through to alternate configured upstreams when publication still fails after manifest
  inspection, with `mirror.gcr.io` fallbacks now covering the Docker Hub-hosted Percona and Envoy
  images used by the supported lifecycle.
- The Haskell-owned lifecycle now retries transient upstream Helm fetch failures during
  `helm repo update` and `helm upgrade --install`, so clean-room restore does not fail terminally
  on intermittent upstream `5xx` or timeout errors.
- `src/Prodbox/CLI/Rke2.hs` now closes the supported lifecycle on native-host-architecture image
  publication only: `amd64` hosts publish `amd64`, `arm64` hosts publish `arm64`, and no
  supported lifecycle path uses `docker buildx` or cross-arch emulation.
- The chart-platform end state is Haskell-owned and renders namespace-local
  Percona-operator-backed Patroni PostgreSQL HA through `src/Prodbox/PostgresPlatform.hs` and
  `src/Prodbox/Lib/ChartPlatform.hs`, with exactly three replicas, synchronous replication,
  deterministic retained PV bindings, retained secret state, and no embedded chart-local
  PostgreSQL subcharts.
- The public `prodbox charts ...` runtime now rejects internal `keycloak-postgres` and `redis`
  dependency releases directly and keeps those names reachable only through their owning root-
  chart orchestration.
- The public `prodbox pulumi ...` surface is limited to the AWS substrate stacks under
  `pulumi/aws-eks/` and `pulumi/aws-test/`. Non-secret validation inputs are synchronized through
  stack config, while AWS provider credentials stay only in `prodbox-config.dhall` and the
  Haskell-owned subprocess environment.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` generate and
  retain AWS substrate stack snapshots under `.prodbox-state/aws-test/` and
  `.prodbox-state/aws-eks-test/`, with the HA-RKE2 validation SSH key stored under
  `.prodbox-state/aws-test/`; the HA-RKE2 validation destroys and recreates the retained
  `aws-test` stack once when Pulumi reconcile succeeds but SSH validation fails, repairing stale
  EC2 instances left by interrupted runs or operator network moves.
- The current gateway runtime surface is Haskell-owned and code-backed in `src/Prodbox/Gateway.hs`,
  `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Peer.hs`, and
  `src/Prodbox/Gateway/Types.hs`: config generation, heartbeat recording, in-memory ownership
  projection, DNS-write gating, the bounded HTTP `/v1/state` observability payload, HMAC event
  signing, Orders-backed gateway-interval validation, peer-transport gossip with commit-log
  replication through `peerListenerLoop` and `peerDialerLoop`, runtime claim/yield emission under
  the `canWriteDns` predicate, bounded-clock-skew enforcement keyed off
  `daemonMaxClockSkewSeconds`, and monotonic Orders-version coordination across the mesh are all
  implemented there today.
- `prodbox test integration gateway-partition` now runs as a distinct native validation path,
  while the retained peer trust-material fields are validated and bound as authoritative runtime
  transport inputs.
- `src/Prodbox/Tla.hs` still owns `prodbox tla-check`, while
  `documents/engineering/tla_modelling_assumptions.md` records the current runtime-to-model
  correspondence and compression points for the Phase `2` surface.
- `src/Prodbox/CLI/Rke2.hs` retains lifecycle-owned bootstrap DNS reconcile and ACME
  `ClusterIssuer` projection; those helpers do not expand the public `prodbox pulumi ...` command
  family.
- `src/Prodbox/CLI/Rke2.hs` now closes the supported lifecycle on the clean-room Harbor, Envoy
  Gateway, cert-manager, and Percona reconcile path with no retained cluster-migration cleanup
  shims for Traefik or the pre-Percona operator surface.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` now sync only
  the supported retained AWS-validation stack inputs and no longer remove older Pulumi
  provider-key layouts on the supported path.
- The self-managed public edge now installs Envoy Gateway, renders Gateway API resources, and
  protects shared-host browser, API, WebSocket, and admin routes through Envoy auth policy.
- `src/Prodbox/CLI/Rke2.hs` now renders config-selected MetalLB L2 or BGP resources, lifts the
  Envoy Gateway controller and data-plane replica counts into settings, and builds or imports both
  the gateway image and the shared public-edge workload image during `rke2 reconcile`.
- The supported public-edge auth doctrine now makes the carrier and key-discovery boundary
  explicit: JWT-only API routes validate request-carried bearer tokens locally at Envoy from
  Keycloak issuer metadata plus JWKS-backed signing keys, Envoy-managed browser auth returns
  through the edge redirect and cookie or session path, and direct-OIDC workloads keep their
  carrier or session state workload-owned.
- Keycloak availability now stays explicit in the plan: it is required for new logins, refresh
  flows, and later JWKS refresh, but the steady-state JWT request path does not synchronously call
  Keycloak or Redis while Envoy still has cached signing keys and the presented tokens remain
  valid.
- The current supported transport boundary now stays explicit in the plan: public TLS terminates at
  Envoy for the shipped `/vscode`, `/api`, and `/ws` routes on
  `test.resolvefintech.com`, while backend TLS or mTLS is outside the supported
  chart-workload contract unless a later doctrine revision expands that path.
- `src/Prodbox/PublicEdge.hs` now centralizes the shared-host route catalog and issuer derivation
  consumed by lifecycle, DNS, chart, host-diagnostic, and native validation surfaces, keeping
  `/auth`, `/vscode`, `/api`, `/ws`, `/harbor`, and `/minio` aligned on one Haskell-owned
  public-edge contract.
- Root `README.md` plus the governed public-edge, gateway, chart-platform, registry, and testing
  doctrine docs now describe that same supported route catalog and command surface, and the
  earlier Phase `2`, `3`, and `4` implementation gaps are closed in the same code-backed paths.
- `charts/keycloak/`, `charts/api/`, `charts/redis/`, `charts/websocket/`, `charts/vscode/`,
  `src/Prodbox/Lib/ChartPlatform.hs`, and `src/Prodbox/Workload.hs` now own the shared-host
  workload contract, including the internal `workload.mode = Api \| Websocket` runtime selector
  (sourced today from the `PRODBOX_WORKLOAD_MODE` env var; Sprint 3.14 migrates this to the
  mounted Dhall config per [config_doctrine.md](../documents/engineering/config_doctrine.md)),
  JWT-only API delivery, Redis-backed shared-state continuity on the WebSocket route, workload-
  managed OIDC bootstrap, real `/ws` upgrade handling, and settings-backed workload scaling.
- The current WebSocket doctrine now states that one upgraded connection remains pinned to one
  selected backend pod until disconnect, reconnect-safe state must live outside the pod, and the
  implemented runtime now closes on readiness-based drain plus revocation-driven reconnect
  behavior on the real `/ws` path.
- Redis now stays explicit as shared application state for the current WebSocket surface and any
  later explicit external rate-limit service, but the current supported worktree still does not
  ship a standalone rate-limit-service workload or validation path.
- `src/Prodbox/Host.hs` and `src/Prodbox/TestValidation.hs` now classify and validate the
  current Keycloak identity, `vscode`, `api`, `websocket`, Harbor, and MinIO routes through named
  external validations on one shared hostname.
- `src/Prodbox/Host.hs` now recognizes only the supported
  `System clock synchronized` timedatectl field in `parseTimedatectlNtpDisposition`, so the
  Phase `2` host-info path closes on the Ubuntu 24.04 field format described by the current
  doctrine.
- `charts/gateway/` and `prodbox gateway start|status|config-gen` remain the separate Haskell
  distributed gateway daemon surface; they are not the Envoy Gateway public edge.
- The canonical validation surfaces are `prodbox check-code`, `prodbox test unit`,
  `prodbox test integration cli`, `prodbox test integration env`, the named Haskell-owned
  validation
  flows in `src/Prodbox/TestValidation.hs`, and the aggregate reruns
  `prodbox test integration all` plus `prodbox test all`.
- The aggregate rerun contract is owned by the shared suite plan behind
  `prodbox test integration all` and `prodbox test all`, including AWS IAM,
  Route 53, public-edge, EKS, HA-RKE2, destructive lifecycle, and post-test restore.
- The final Phase `6` destructive rerun and handoff validation are closed on that aggregate rerun
  contract and the supported postflight restore path.
- The legacy ledger preserves completed cleanup history. After the doctrine-adoption reopen
  closure the `Pending Removal` section was empty; the May 23, 2026 reopen of Phases `2`, `3`,
  and `4` (Sprints `2.17`, `2.18`, `2.19`, `3.13`, `4.16`, `4.17`, `4.18`) reintroduced
  doctrine-aligned residue rows (file-existence stack predicates, the `.prodbox-state/` host-side
  cache, the host-side chart-secret cache plus `.patroni-anchor-volume` marker, and the remaining
  `curl` shell-outs in `src/Prodbox/TestValidation.hs`, `Workload.hs`, and `CLI/Rke2.hs`), each
  scoped to its owning sprint.

## Exit Definition

This plan is complete only when all of the following are true:

1. `DEVELOPMENT_PLAN/` and governed doctrine describe the Haskell architecture and the Envoy
   Gateway target rather than the retired Python architecture or a Traefik end state.
2. The supported operator flow is `prodbox`, implemented in Haskell, across config, lifecycle,
   Pulumi orchestration, gateway, chart delivery, validation, and AWS administration.
3. The supported config contract is direct `Dhall -> Haskell types` from operator-authored
   repository-root `prodbox-config.dhall`, with `prodbox-config-types.dhall` aligned to the
   decoder and no generated `prodbox-config.json` artifact or supported `prodbox config compile`
   path.
4. Public `prodbox config setup` and public `prodbox aws ...` paths can bootstrap all required AWS
   credentials from scratch using temporary admin credentials entered interactively by the
   operator.
5. `aws_admin_for_test_simulation.*` may be stored in `prodbox-config.dhall` only as the
   test-suite simulation of the ephemeral temporary-admin credential prompt. The native IAM
   validation harness is the only supported runtime consumer of that section, and no supported
   non-test command or runtime helper may read or use it.
6. `prodbox test integration aws-iam`, `prodbox test integration all`, and `prodbox test all`
   share one joint idempotent IAM validation harness that deletes any pre-existing dedicated
   `prodbox` IAM user and all of that user's access keys before provisioning, uses any
   pre-existing `aws.*` credentials only to discover and delete the IAM user associated with those
   credentials, proves STS-federated operational credentials with a compact AWS-validation
   session policy, waits for the dedicated IAM-user credentials to pass STS and repeated Route 53
   hosted-zone probes, materializes IAM-user operational `aws.*` only from
   `aws_admin_for_test_simulation.*` to simulate the interactive public CLI workflow because
   cert-manager Route 53 DNS01 credentials do not support an STS session-token field, and clears
   operational `aws.*` from `prodbox-config.dhall` before returning so no test-created dedicated
   IAM user or key survives.
7. The operator-facing binary lives at `.build/prodbox`, produced by the canonical
   `cabal build --builddir=.build exe:prodbox` invocation plus a copy step.
8. Container-side build artifacts live under `/opt/build`, and every repository-owned Dockerfile
   lives under `docker/`.
9. Every repository-owned Haskell-build Dockerfile is single-stage from `ubuntu:24.04`, installs
   `ghcup` in-image, pins GHC `9.14.1`, and does not create symlinked Haskell tool shims; no
   supported browser-facing auth path depends on a repository-owned nginx auth-proxy image.
10. `prodbox.cabal`, `cabal.project`, and the canonical build-and-test surfaces are explicitly
    upgraded for GHC `9.14.1`, including any required cabal-bound changes and full canonical
    validation reruns on that toolchain.
11. `prodbox check-code` enforces the governed doctrine-alignment contract described by
    `documents/engineering/code_quality.md`, not only formatter, linter, build, and binary-sync
    checks.
12. The Haskell distributed gateway runtime, `gateway status` client path, and daemon config
    validation close on the implemented bounded HTTP `/v1/state` observability payload, the
    Orders-backed gateway-interval relationships enforced by `src/Prodbox/Gateway/Types.hs`, and the current
    correspondence notes in `documents/engineering/tla_modelling_assumptions.md`.
13. The self-managed public edge uses MetalLB, Envoy Gateway, Kubernetes Gateway API, and
    cert-manager rather than Traefik plus `Ingress`.
14. Every externally reachable application or operational dashboard routes through Envoy on the
    single canonical hostname `test.resolvefintech.com`, using explicit path prefixes such as
    `/vscode`, `/api`, `/ws`, `/auth`, and later supported admin paths.
15. The supported public-edge doctrine uses exactly one public DNS entry, one listener
    certificate, and no dedicated identity, browser, API, or WebSocket hostnames. Wildcard
    public DNS is unsupported.
16. `prodbox host public-edge`, `prodbox test integration charts-vscode`,
    `prodbox test integration charts-api`, `prodbox test integration charts-websocket`, and the
    named admin-route validations close on Gateway, `HTTPRoute`, auth policy, certificate, and
    one Route 53 record rather than `IngressClass`, `Ingress`, or per-FQDN state.
17. Supported config, onboarding, lifecycle, and validation surfaces remove `example.com`
    entirely and do not accept or emit placeholder public domains.
18. MetalLB supports both the L2 implementation path and a config-selected BGP implementation path
    on the supported self-managed cluster surface.
19. Envoy validates Keycloak-issued JWTs locally and applies route-level RBAC for application and
    admin routes. Issuer, audience, path-claim requirements, bearer-token carriers, browser
    return paths, and JWKS discovery or refresh ownership remain explicit.
20. Redis appears only as repo-owned app-level shared state for supported realtime or rate-limit
    workloads; it is never part of Envoy JWT validation, and the current supported worktree does
    not yet ship a standalone external rate-limit-service surface.
21. Supported WebSocket workloads authenticate at connection setup on the shared-host `/ws`
    route, keep reconnect-safe state outside the pod, keep each live upgraded connection pinned
    to one backend pod until disconnect, define token-expiry and authorization-change behavior
    explicitly, leave per-message authorization to the workload when messages need finer-grained
    permissions than the edge can enforce, scale horizontally behind Envoy, use readiness-based
    drain before pod exit, and add named validations for reconnect, connection-pinning,
    token-expiry handling, authorization-change assumptions, readiness-based drain,
    per-message authorization ownership, and shared-state assumptions.
22. Keycloak-backed public workloads stay proxy-aware behind Envoy on the shared hostname rather
    than on a dedicated identity host. Keycloak availability gates login, refresh, and later
    JWKS refresh, while cached signing keys and unexpired tokens keep the steady-state JWT hot
    path local to Envoy.
23. Public TLS terminates at Envoy on the supported path, and one certificate covers
    `test.resolvefintech.com`. Backend TLS or mTLS is not part of the current supported workload
    contract unless a later doctrine revision makes that backend transport explicit.
24. Direct public-registry pulls are permitted on the supported path only for Harbor and Harbor's
    storage backend during bootstrap.
25. Every later supported Helm deployment obtains its images from Harbor.
26. `prodbox` idempotently ensures required public images and all custom images are present in
    Harbor after Harbor bootstrap and before those later deployments.
27. Supported custom-image builds and Harbor publication use only the native architecture of the
    machine running `prodbox`: `amd64` hosts build and publish `amd64` images, and `arm64` hosts
    build and publish `arm64` images.
28. Native `arm64` publication works on native `arm64` Docker daemons. `docker buildx`,
    cross-arch emulation, and mixed-arch cluster closure are not part of the supported lifecycle
    or chart-delivery path.
29. Every supported Helm-managed PostgreSQL deployment is external, reconciled only through the
    cluster-wide Percona operator, and runs Patroni HA with exactly three PostgreSQL replicas,
    synchronous replication, and no embedded chart-local PostgreSQL subchart.
30. Pulumi remains part of the supported architecture for true IaC and AWS substrate resources.
    The public `prodbox pulumi ...` surface stays limited to those stacks, while local-cluster
    lifecycle, bootstrap DNS reconcile, and ACME `ClusterIssuer` projection remain owned by
    `src/Prodbox/CLI/Rke2.hs` rather than by a public Pulumi operator flow.
31. No supported Pulumi program depends on Python.
32. The strongest clean-room rerun passes from full local delete through final AWS teardown using
    the Haskell stack.
33. [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) contains no unresolved
    cleanup.
34. The repository has no supported-path Python implementation or Python toolchain ownership
    artifacts left.
35. The Haskell gateway daemon materializes peer transport from the certificate, key, CA, and
    socket fields already retained in `DaemonConfig` and `Orders`: every node updates
    `stateLastHeartbeatTimes` from inbound peer events rather than from the local heartbeat loop
    only, the append-only commit log replicates between nodes as the canonical heartbeat-and-event
    transport, and `/v1/state` exposes per-peer transport health for operator inspection.
36. The gateway daemon emits signed `Claim` and `Yield` events on owner transitions and gates
    Route 53 writes on the runtime equivalent of the modelled `CanWriteDns` predicate, so
    `ClaimPrecedesWrite` and `YieldPrecedesReclaim` hold on the runtime event log rather than only
    on the model, and a stale owner cannot reclaim DNS write authority without first observing its
    own yield being superseded by a fresh claim.
37. The supported-host gate fails fast when the host's NTP synchronization state is unhealthy, the
    gateway daemon records the maximum observed inter-node clock skew on `/v1/state` and refuses
    inbound heartbeats whose timestamps exceed the documented bound, and the architecture and TLA+
    correspondence docs name that bound, the operator response, and how the model's bounded-delay
    assumption maps to a runtime-enforced skew limit.
38. Orders documents carry a monotonic version field, daemons reject inbound peer events from a
    peer presenting an older Orders version, a new Orders version propagates through commit-log
    gossip and is adopted by every live daemon before the next election tick, and a daemon
    rebooting against a stale Orders version refuses to claim ownership until its Orders view
    catches up.
