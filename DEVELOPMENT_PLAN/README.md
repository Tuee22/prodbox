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
**Generated sections**: none

> **Purpose**: Provide the single execution-ordered development plan for the Haskell rewrite of
> `prodbox`, including phase status, validation gates, and cleanup ownership.

## Standards

See [development_plan_standards.md](development_plan_standards.md) for the maintenance rules that
govern this plan suite.

## Closure Status

> **Declarative-plan note (Standard D).** This section is a condensed milestone ledger, not a
> per-sprint changelog. The authoritative per-sprint closure detail lives in the phase documents
> ([phase-0](phase-0-planning-documentation.md) … [phase-8](phase-8-email-invite-auth.md)) and the
> cleanup history lives in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md); the
> live status is the [Phase Overview](#phase-overview) and [Current Plan Status](#current-plan-status)
> tables below. The dated blow-by-blow was consolidated here on review to keep the plan declarative.

**Current head state (2026-07-11 — all declared phase-owned code surfaces are closed).** A July 10
live home canonical-suite run produced a counterexample to two closure claims. All
three gateway containers repeatedly reached their exact `512Mi` cgroup limit and were OOM-killed,
while Deployment-only readiness later sampled them as available; the capacity plan had proved
authored admission, not bounded runtime demand. The invite-capable restore plan also assumed an
already-present long-lived `aws-ses` stack and its SES readiness probes accepted exit success
without classifying the returned state. Sprint `1.60` reclosed Phase `1` with the validated
runtime-memory plan and generated gateway RTS policy; Sprint `2.31` reclosed Phase `2` with bounded
state/delta repair, retained continuity, and credential-gated DNS; Sprint `3.25` reclosed Phase `3`
with typed constant-time chart probes and a negative lint guard. Sprint `4.47` has now reclosed
Phase `4` with the registered desired-present reconcile, bounded lease-role session, fenced
checkpoint/SMTP commits, and global target-intent recovery. Sprints `5.16`/`5.17` have now reclosed
Phase `5` with the run-wide gateway runtime-stability oracle and capability-derived retained-SES
preparation. Sprint `8.10` has now reclosed Phase `8` with exact sender/DKIM/MX/rule/action and
capture list/get-capability observations, bounded propagation polling, and a read-only built-frontend
diagnostic. There is no remaining `Active`, `Planned`, or `Blocked` phase-owned sprint. Fresh AWS
identity/DKIM/MX/rule propagation and deployed home/AWS invite aggregates remain an explicit,
non-blocking `Live-proof: pending` axis under
[Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof). Phases `6`
and `7` remained closed under
[Standard N](development_plan_standards.md#n-phase-independence-no-backward-blocking): neither
newly identified gap belonged to their owned surface.

**Preserved previous closure record.** Phase `7` reclosed after completing its own AWS bootstrap-readiness surface
([Standard A/N](development_plan_standards.md#n-phase-independence-no-backward-blocking)). Sprints
`1.56`/`3.23`/`4.43`/`7.31` landed the typed component/readiness graph, graph-sourced chart edges,
Percona `Available` gate, single step narration, and the deep registry→MinIO S3 gate on both
substrates. Sprint `4.45` now makes the home RKE2 readiness-race ordering class unrepresentable:
the validated graph determines component order, `nativeInstallStepOrder` concatenates each
component's anchored steps in that order, and edge reconciliation is an explicit separate tail.
Sprint `4.46` is ✅ Done and Phase `4` is reclosed: the Route 53, Helm, and Harbor publication retry
classifiers delegate to the shared transient-failure base, Helm now inherits the common DNS and
transport cases, and the three transitional RKE2 lint allowances are gone. Code-local evidence is
unit 1276/1276; `prodbox dev check` exits 0. Sprints
`1.57`–`1.59` are
✅ Done and Phase `1` is reclosed. Sprint `1.59`
landed the flat `ReadinessObservation` / `ReadinessProbeResult` seam, typed targets carrying
caller-injected one-shot actions, exhaustive probe dispatch, immediate mismatch refusal, and bounded
pending/unreachable waits. Its graph audit records `ProbeServiceActive` for cluster base,
daemon-mediated Vault-unseal ordering, and the gateway-full `BackendWriteEdge` to MinIO
(`config generate`/`config validate` exit 0, unit 1259/1259, `prodbox dev check` 0). It wraps no
production primitive and owns no coordinates; the Phase-3, Phase-4, Phase-5, and AWS bindings have
landed in `3.24`, `4.45`, `5.15`, and `7.32`. Sprint `2.30` is ✅ Done and Phase `2` is
reclosed:
`VaultRoleGatewayDaemon` is the one typed
authority for the supported `ChartPlatform`-generated gateway `vault.role` and the
`defaultVaultReconcilePlan` Kubernetes-auth role name (`prodbox-gateway-daemon`), whose policy set is
exactly `prodbox-gateway` plus `gateway-gateway` (unit 1260/1260, `prodbox dev check` 0). Static chart
defaults and other gateway configuration surfaces are not claimed by this SSoT. Sprint `3.24` is ✅
Done and Phase `3` is reclosed: the exhaustive `operatorAvailableTarget` registry routes the Percona
operator through a one-shot `Available=True` observation and `ReadinessObservation`; only
`ReadyObserved` opens the chart mutation gate. A new `ComponentId` constructor requires an explicit
registry decision in the warning-clean build, while an existing config-driven ID without a target
fails closed at runtime (unit 1266/1266, chart lint 0, `prodbox dev check` 0). Sprint `4.44` is ✅
Done: `RegistryStorageBackend` now carries the rendered non-secret registry S3 settings plus a required
`RedirectPolicy`; the canonical MinIO-backed value selects `RedirectDisabled`. `registryConfigYaml`
remains an `unlines` renderer but consumes that typed input. The golden output is preserved, and
resource ownership is unchanged (registry-config golden, unit 1268/1268, `prodbox dev check` 0).
Sprint `4.45` is ✅ Done: `buildNativeInstallExecutionPlan` validates the component DAG, derives
`concatMap stepsForComponent (componentReconcileOrder dag)`, verifies dependency and phase
monotonicity, and carries the validated DAG/order in its compiled `NativeInstallPayload`; any
invalid projection returns a structured error before apply. Graph declarations now include the
registry and post-Vault dependencies actually consumed by cert-manager, the pre-Vault gateway,
MetalLB, Envoy Gateway, and Percona. Every native step has a total anchor and both phase executors
match explicitly; MetalLB, Envoy Gateway, and Percona are first-class steps. Production readiness
targets invoke their caller-injected one-shot observations through bounded fail-closed polling,
with each component's final anchored barrier required before its dependants run. The plan goldens
intentionally expose those three platform steps and
remove the redundant home MinIO steady-state narration (config schema regeneration and validation
exit 0, unit 1273/1273, real `prodbox cluster reconcile --dry-run` exit 0, `prodbox dev check` 0).
Phase `4` is reclosed after Sprint `4.46`. Sprint `5.15` is ✅ Done and Phase `5` is reclosed:
`Prodbox.TestRestore` owns one substrate-aware typed restore-cycle plan consumed by both TestRunner
restore paths, and the optional SMTP step opens only after a bounded, fail-closed gateway object-store
precondition. Code-local evidence is unit 1280/1280; `prodbox dev check` exits 0. The home
`prodbox test all` restore-cycle proof remains a non-blocking Standard O axis. Sprint `7.32` is ✅
Done and Phase `7` is reclosed: the configured DAG compiles to a closed AWS anchored-step order
before mutation, every AWS-owned component has a production one-shot target, the gateway Service
port-forward spans daemon-mediated Vault bootstrap/full-mode convergence, the EKS classifier uses
the shared base with no lint allowance, and AWS bootstrap projects the shared restore builder.
Code-local evidence is unit 1286/1286 and `prodbox dev check` exit 0. The live
`prodbox test all --substrate aws` past the EKS image-mirror step is the
non-blocking Standard O live-proof axis (see [Substrate Parity](#substrate-parity) and
[substrates.md](substrates.md)).

### Milestone ledger

Each row is one dated reopen/closure milestone; the owning phase doc carries the per-sprint detail.

| Date | Milestone |
|------|-----------|
| 2026-07-11 | Sprint `8.10` ✅ **Done; Phase 8 reclosed** — `Prodbox.Ses.Readiness` classifies the exact configured sender identity, DKIM signing state, inbound MX, active/enabled receipt rule and S3 action, and Pulumi-owned capture canary list/get capability as `Ready`, retryable `Pending`, terminal `Failed`, or `Unobservable`. The registered `aws-ses` transaction runs provider reconciliation before the bounded semantic poll and cannot reach SMTP mutation after timeout or terminal evidence; `prodbox host check-ses-readiness` exposes the same read-only prerequisite surface. Evidence: warning-clean build, Fourmolu check, focused readiness 23/23, SES transaction 8/8, lease-role 9/9, built-frontend SES fixtures 2/2, full unit 1535/1535, and CLI/env integration 49/49 each. Fresh AWS identity/DKIM/MX/rule propagation and deployed home/AWS invite aggregates remain a non-blocking Standard-O `Live-proof: pending` axis. |
| 2026-07-10 | Sprint `5.17` ✅ **Done; Phase 5 reclosed** — `ValidationKeycloakInvite` alone derives one opaque nested retained-SES preparation plan. Its typed selected-target gateway object-store precondition precedes the exact acquire/reconcile/bounded provider-presence await/target-sync/release trace, interpreted through one call to Sprint `4.47`'s registered ensure. Home and AWS project only their selected sink; non-invite and postflight plans contain no SES mutation. Explicit authority/target coordinates, scoped EKS transport, real different-sink predecessor recovery, read-only deferred prerequisites, and retained cleanup are pinned by focused plan/recovery 10/10, target API 6/6, global target-commit 12/12, full unit 1508/1508, CLI/env integration 47/47 each, and `dev check` 0. Clean-state deployed invite runs remain a non-blocking Standard-O axis; semantic SES readiness was still assigned to Sprint `8.10` at this checkpoint and closed on 2026-07-11. |
| 2026-07-10 | Sprint `5.16` ✅ **Done** — `gateway-pods` now feeds typed pod/status, termination, Event, and metrics JSON into one concurrency-safe recorder through a structured continuous observer. Restart/OOM/failure-high-water and unobservable evidence fail closed across UID replacement and the compiled Phase-1.6/lifecycle/postflight/volume-rebind boundaries; only the separate three-sample healthy window resets for a planned gateway rollout. AWS observation starts at the gateway bootstrap handoff, uses a monitor-private explicit environment, and refreshes its kubeconfig through a request/acknowledgement barrier after EKS recreation. Every Kubernetes read has API and process deadlines. Thresholds derive from Sprint `1.60`'s runtime-memory plan, and logs remain diagnostic-only. Evidence: focused tables 17/17, installed-binary fake-Kubernetes proofs 2/2, warning-clean build, unit 1494/1494, CLI integration 47/47, and `dev check` 0. The longer deployed soak is a non-blocking Standard-O axis. |
| 2026-07-10 | Sprint `4.47` ✅ **Done; Phase 4 reclosed** — separate flat AWS-presence/checkpoint observations feed the total `DesiredPresence` loop and registered `LongLived` `aws-ses` ensure. The supported reconcile now acquires the retained authority lease, recovers released/expired predecessor provider and target effects, mints only fixed-role STS sessions bounded by the grant, writes checkpoints through fresh fenced CAS, repairs the finite SMTP IAM-key inventory, and materializes through the global target-intent protocol. The exact same-account role is registered as an `Operational` resource and teardown re-observes its absence before clearing the trusted user. Evidence: warning-clean build, focused lifecycle tables 78/78 plus role tables 9/9, full unit 1476/1476, and `dev check` 0. Live AWS exercise remains a non-blocking Standard-O axis. |
| 2026-07-10 | Sprint `3.25` ✅ **Done; Phase 3 reclosed** — `GatewayProbeEndpoint` makes the lifecycle paths a closed typed choice (`/healthz` liveness, `/readyz` readiness), `GatewayProbeSpec` owns every timing/threshold value, `ChartPlatform` emits the same value used by the generated `gateway-probes.values` defaults, and the Deployment consumes the complete values-backed shape. `prodbox dev lint chart` rejects `/v1/state` in either lifecycle probe. Evidence: warning-clean build, unit 1386/1386, focused probe suite 4/4, chart/Haskell lint and generated drift checks 0, `dev check` 0, independent liveness/readiness negative fixtures, and Helm rendering of three Deployments with six dedicated paths and zero `/v1/state` probes. Runtime stability subsequently landed in Sprint `5.16`. |
| 2026-07-10 | Sprint `2.31` ✅ **Done; Phase 2 reclosed** — the gateway now retains bounded keyed semantic state, signed per-emitter cursor/delta/checkpoint-repair frames, exact staged Model-B continuity, validated Orders, process-wide frame permits, capacity-one child scheduling, and credential/claim/continuity-gated DNS effects. The append-log/full-log compatibility path is removed. Evidence: unit 1382/1382, daemon lifecycle 13/13, CLI/env integration 45/45, the native partition validation, `dev check` 0, a local profiled request burst with 570,320-byte peak live heap under the generated 268,435,456-byte RTS ceiling, and exhaustive TLC exploration of 606,637,449 generated / 51,491,308 distinct states to depth 44 with nine invariants and no violation. The deployed restart-free stability soak remains the non-blocking Standard-O axis owned by Sprint `5.16`. |
| 2026-07-10 | Sprint `1.60` ✅ **Done; Phase 1 reclosed** — `RuntimeMemoryPlan` proves positive nested heap/container budgets, derives the cgroup limit from the matching workload `ResourceEnvelope`, validates finite child concurrency/peak/deadline evidence, exposes typed scratch/high-water projections, and generates the gateway `+RTS -M268435456 -RTS` argv through ChartPlatform. Cabal enables only `-rtsopts`; no heap cap is authored in Cabal, Docker, or Helm. Evidence: config generation/validation 0, unit 1299/1299, CLI/env integration 45/45, `dev check` 0. Sprint `2.31` subsequently consumed the plan and Sprint `5.16` consumed its high-water projection. |
| 2026-07-10 | **Gateway-memory and retained-SES refactor reopened Phases 1/2/3/4/5/8** — live evidence showed repeated cgroup-local gateway OOM kills hidden by Deployment-only readiness, and source audit showed invite-capable suite preparation syncs from but never ensures the long-lived `aws-ses` stack. Planned ownership: `1.60`, `2.31`, `3.25`, `4.47`, `5.16`, `5.17`, `8.10`. Existing completed work remains preserved; the new [legacy ledger](legacy-tracking-for-deletion.md#pending-removal) rows own removal of the superseded unbounded/exit-code-only/manual-precondition paths. |
| 2026-07-10 | Sprint `7.32` ✅ **Done; Phase 7 reclosed** — `AwsSubstratePlatform` compiles the configured component DAG through the shared anchored-order engine before stack-output reads or platform mutation, with total AWS step anchors, final substrate-owned readiness barriers, an explicit AWS-inapplicable MetalLB mapping, and a separate ACME/admin-route tail. A positively established gateway Service port-forward remains alive across daemon-mediated Vault bootstrap and post-Vault full-mode convergence. The EKS mirror classifier delegates to the shared transient base and its last lint allowance is removed. AWS TestRunner bootstrap projects Gateway → SMTP → VS Code → API → WebSocket from the shared restore builder after all three stack reconciles. Evidence: unit 1286/1286; `dev check` exit 0. Live `test all --substrate aws` remains a non-blocking Standard-O proof. |
| 2026-07-10 | Sprint `5.15` ✅ **Done; Phase 5 reclosed** — new `Prodbox.TestRestore` owns one pure, substrate-aware `RestoreCyclePlan`; `supportedRuntimeBootstrapActions` and `supportedRuntimePostflightActions` both interpret it and differ only by the typed optional SMTP step. Before SMTP sync, `gatewayDaemonLivenessPrecondition` adapts the caller-supplied one-shot gateway object-store observation to `BackendRoundTripTarget ComponentGatewayDaemonFull ComponentMinio`, polls it within the shared bounded policy, and returns a loopback-endpoint-naming `StructuredError` without starting SMTP when pending or unreachable. Code-local evidence: unit 1280/1280; CLI integration 44/44; `dev check` exit 0. The home restore-cycle live proof remains non-blocking. |
| 2026-07-10 | Sprint `4.46` ✅ **Done; Phase 4 reclosed** — `isRetryableRoute53CredentialFailure`, `isRetryableHelmFailure`, and `isRetryableHarborPublicationFailure` now delegate to `isRetryableTransientFailure` while retaining only their path-specific extensions. Helm inherits the shared DNS/transport cases, and all three transitional RKE2 entries were removed; Sprint `7.32` subsequently removed the final EKS allowance. Code-local evidence: unit 1276/1276; `dev check` exit 0. |
| 2026-07-10 | Sprint `4.45` ✅ **Done; Phase 4 remains open only for `4.46`** — the validated component DAG now compiles the home RKE2 plan as `concatMap stepsForComponent (componentReconcileOrder dag)` plus an explicit edge tail. The builder validates dependency/phase order and carries the validated DAG/order in `NativeInstallPayload`, all step anchors and phase matches are total, MetalLB/Envoy Gateway/Percona are first-class steps, corrected graph dependencies match production consumption, and readiness targets poll caller-injected one-shot observations within bounds and enforce each component's final barrier before dependants. The plan-golden changes are intentional (three visible platform steps; redundant home MinIO steady-state step removed). Evidence: config schema regeneration and validation exit 0, unit 1273/1273, real `cluster reconcile --dry-run` exit 0, `dev check` 0. |
| 2026-07-10 | Sprint `4.44` ✅ **Done** — `RegistryStorageBackend` holds the registry S3 configuration and requires an explicit `RedirectPolicy`; the canonical MinIO-backed record uses `RedirectDisabled`. `registryConfigYaml` remains an `unlines` renderer but consumes the typed record. The golden output is preserved and resource ownership is unchanged (registry-config golden, unit 1268/1268, `dev check` 0). Sprint `4.45` closes in the row above; Phase 4 is now open only for `4.46`. |
| 2026-07-10 | Sprint `3.24` ✅ **Done; Phase 3 reclosed** — the exhaustive `operatorAvailableTarget` registry binds the graph-projected Percona gate to a one-shot `Available=True` observation through `ReadinessObservation`; pending and unreachable observations fail closed. New `ComponentId` constructors require an explicit compile-time registry decision, while an existing config-driven ID with no target fails closed at runtime (unit 1266/1266, chart lint 0, `dev check` 0). |
| 2026-07-10 | Sprint `2.30` ✅ **Done; Phase 2 reclosed** — `Prodbox.Vault.RoleId` supplies `VaultRoleGatewayDaemon` to both the supported `ChartPlatform`-generated gateway `vault.role` and `defaultVaultReconcilePlan`; the shared name is `prodbox-gateway-daemon`, bound to exactly `prodbox-gateway` + `gateway-gateway`. The closure does not claim static chart defaults or other gateway configuration surfaces (unit 1260/1260, `dev check` 0). |
| 2026-07-10 | Sprint `1.59` ✅ **Done; Phase 1 reclosed** — `ReadinessObservation`, `ReadinessProbeResult`, and typed `ComponentReadinessTarget` values carry caller-injected one-shot actions; dispatch is exhaustive, target/probe mismatch refuses before polling, and pending/unreachable observations remain bounded and fail closed. The graph records `ProbeServiceActive` for cluster base, daemon-mediated Vault-unseal ordering, and gateway-full's `BackendWriteEdge` to MinIO (`config generate`/`config validate` exit 0, unit 1259/1259, `dev check` 0). Its production bindings subsequently landed in `3.24`/`4.45`/`5.15`/`7.32`. |
| 2026-07-10 | Sprint `1.58` ✅ **Done** — split `ComponentVaultWorkload`/`ComponentVaultUnsealed` (`ProbeRolloutComplete`/`ProbeVaultUnsealed`) and `ComponentGatewayDaemonPreVault`/`ComponentGatewayDaemonFull` (`ProbeRolloutComplete`/`ProbeBackendRoundTrip ComponentMinio`); `EffectDAG.acyclicTopologicalOrder` now accepts a caller tie-break and `ComponentGraph` supplies `fromEnum`; the git-ignored schema was regenerated (`config generate`/`config validate` exit 0, unit 1250/1250, `dev check` 0). Its derived-order consumer subsequently landed in Sprint `4.45`. |
| 2026-07-10 | Sprint `1.57` ✅ **Done** — `TransientFailureClass` + `isRetryableTransientFailure` form the shared constructor-owned retry base in `Prodbox.Service`, the Phase-1 AWS-validation caller delegates to it, and `CheckCode` rejects new standalone inline retry tables (unit 1248/1248, `prodbox dev check` 0). Phase `1` remains reopened for `1.58`/`1.59`; downstream RKE2/EKS delegation remains `4.46`/`7.32`. |
| 2026-07-10 | **Bootstrap-readiness refactor reopened** Phases 1/2/3/4/5/7 to complete graph-derived reconcile ordering, total readiness observation, the retry-classifier SSoT, typed registry/Vault-role records, and restore-cycle DRY — Sprints `1.57`/`1.58`/`1.59`/`2.30`/`3.24`/`4.44`/`4.45`/`4.46`/`5.15`/`7.32` (Standard A/N own-surface reopen). Sprint `4.45` subsequently closed the identified home-RKE2 order-projection gap ([Standard C](development_plan_standards.md#c-honest-completion-tracking)). |
| 2026-07-06 | Bootstrap readiness-race **foundation** landed — Sprints `1.56` (typed component dependency/readiness graph + `EffectDAG` lowering), `3.23` (graph-sourced chart edges, Percona `Available` gate), `4.43` (single `ReconcileStepId` narration table + deep registry→MinIO edge gate + Harbor retry-classifier fix), `7.31` (same deep gate on the AWS substrate). The graph/deep-gate foundation is real; full order-derivation, total readiness observation, and the config SSoTs remain scheduled (reopened 2026-07-10 above). |
| 2026-07-05 | Daemon-mediated post-bootstrap control-plane boundary — Sprints `2.29` (pre-Vault daemon loader + `POST /v1/bootstrap/vault/ensure`), `4.42` (root Vault lifecycle via the daemon, no host fallback), `5.14` (`daemon-bootstrap` validation), `7.30` (per-run Pulumi object-store via the daemon API). Phases 2/4/5/7 reclosed. |
| 2026-07-04 | Explicit resource guardrails — Sprints `1.55` (`capacity.resource_plan` schema), `3.22` (chart resource envelopes + namespace quotas), `4.41` (RKE2/kubelet reservation + systemd drop-in), `5.13` (`resource-guardrails` validation). Phases 1/3/4/5 reclosed. |
| 2026-07-03 | Pulsar broker transport + topic lifecycle (`3.21`/`4.35`), fail-closed spot-price gate (`7.27`), EKS VPC ownership hardening (`7.29`), static retained EBS PVs on EKS (`7.28`), `eks-volume-rebind` validation (`5.12`). |
| 2026-07-02 | Gateway/Orders + durable-event CBOR migration (`2.27`/`2.28`), substrate-typed placement + host-provider frame + test-EBS reaper (`4.37`/`4.38`/`4.40`), tiered-storage capacity + AWS quota preflight (`4.36`), test-topology command surface + `.test-data` isolation (`5.11`). |
| 2026-06-26 | **Home-substrate aggregate `prodbox test all` GREEN** — 18/18 named validations + both cabal suites, EKS cleanly destroyed. This is the live-infra proof satisfying the home-substrate `🧪 Live-proof: pending` axes across Phases 1–8. |
| 2026-06-16 | Vault-root + cluster-federation foundations closed on their code-owned surfaces — Sprints `1.35`–`1.38`, `2.26`, `3.19`/`3.20`, `4.29`–`4.33`. The master-seed HMAC derivation machinery is **removed** from the supported path (Sprint `3.19`). |
| 2026-06-15 | MinIO/Pulumi encryption finalized to **Model B** — prodbox object-level Vault-Transit envelope with whole-system zero-child-info framing (one generically-named bucket of opaque `objects/<hmac>.enc`, `prodbox-envelope-v2` hashed AAD, decrypt-to-scratch Pulumi interposition, Pulumi's own secrets provider dropped). Refines, does not reverse, the 2026-06-14 model; reopens no new phase. |
| 2026-06-14 | Secrets model **finalized to Vault-root + cluster federation** — Vault is the sole secrets/KMS/PKI root, a sealed Vault bricks the cluster (fail-closed), the master-seed HMAC derivation model is **retired** (not extended), and `FileSecret`/Secret-mounted plaintext Dhall is **removed**. Sprint `0.13` deleted `VAULT_REFACTOR.md` and added [cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md). |
| 2026-06-11 | Vault refactor Sprint `0.12` closed — [vault_doctrine.md](../documents/engineering/vault_doctrine.md) SSoT + documentation harmony. |
| 2026-06-09 | Design-intention review reopen — Sprints `0.9`/`0.10`, `1.29`–`1.32`, `2.24`/`2.25`, `3.15`/`3.16`, `4.26`/`4.27`, `5.6`, `7.12`/`7.13`; all landed. |
| 2026-06-07 | Single ZeroSSL ACME issuer (`zerossl-dns01`) + S3 cert retain-and-restore finalized — Sprints `7.11`/`4.24`/`8.7`. The earlier two-issuer/`IssuerClass` staging+production model was reverted to one ZeroSSL issuer. |
| 2026-06-05..09 | Live AWS-substrate parity proven for the then-canonical slice — Sprints `7.5`, `8.5`/`8.6`/`8.8` (NLB-target Route 53, delegated-subzone cleanup, per-run postflight teardown, OIDC redirect, `keycloak-invite` capture/link-follow on `aws.test.resolvefintech.com`, destructive lifecycle, `prodbox nuke` proof). |

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
| **Done** | Deliverables implemented for the sprint-owned surface, validated on the code-owned surface, and aligned in docs (a pending live-infra proof does not prevent `Done` — [Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)) | ✅ |
| **Active** | Work has started and remaining implementation or documentation work is explicitly listed | 🔄 |
| **Blocked** | Closure depends on an unmet **earlier-or-same-phase** sprint or **external** prerequisite — never a later phase and never a pending live-infra proof ([Standards N/O](development_plan_standards.md#n-phase-independence-no-backward-blocking)) | ⏸️ |
| **Planned** | Ready to start once execution reaches the sprint in sequence | 📋 |
| **Live-proof pending** | Code-owned surface `Done` and locally validated; a live-infra proof (live AWS / deployed cluster / unsealed Vault / operator credential) is outstanding. **Non-blocking** ([Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)) | 🧪 |

### Definition of Done

A sprint can move to `Done` only when all of the following are true:

1. Its deliverables are implemented in the worktree.
2. Its validation commands pass on the **code-owned surface** through the canonical `prodbox`
   surface (`prodbox dev check`, `prodbox test unit`, `prodbox test integration cli` / `env`).
3. The docs listed in `Docs to update` are aligned with the implemented behavior.
4. Sprint-owned cleanup is reflected in
   [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
5. No sprint-owned blocker or remaining work survives.

Per [Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof), a
proof that requires live infrastructure (live AWS spend, a deployed cluster, an unsealed Vault, an
operator-supplied credential) does **not** prevent `Done`; it is tracked as a distinct, non-blocking
`🧪 Live-proof: pending` note on the sprint. Per
[Standard N](development_plan_standards.md#n-phase-independence-no-backward-blocking), a `Blocked by`
entry may name only an earlier-or-same-phase sprint or an external prerequisite — never a later phase
or a higher-numbered sprint — and an incomplete later phase never reopens or blocks an earlier phase.

## Phase Overview

> **2026-06-26 live-proof update:** the home-substrate aggregate `prodbox test all` is **green**
> (18/18 validations + both cabal suites; see the Closure Status above and
> [00-overview.md](00-overview.md) Alignment Status). That run is the live-infra proof that satisfies
> the **home-substrate** `🧪 Live-proof: pending` axes referenced in the rows below across Phases
> 1–8 (config/secrets, gateway/DNS, charts, lifecycle, the canonical suite incl. `sealed-vault`, the
> AWS per-run resource cycles the home suite exercises, and `keycloak-invite`). Per
> [Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof) these were
> already non-blocking; they are now proven. The `--substrate aws` aggregate stays a distinct axis
> ([substrates.md](substrates.md)).

> **2026-07-10 correction:** the June 26 run remains historical proof for the then-implemented
> paths, but it does not close the newly identified clean-state SES-preparation requirements.
> Sprints `5.16`/`5.17` have closed the code-owned runtime-stability and retained-preparation
> requirements. Sprint `8.10` subsequently closed semantic SES readiness on 2026-07-11. Fresh AWS
> propagation and deployed home/AWS invite aggregates remain non-blocking live-proof axes rather
> than open code-owned work.

| Phase | Name | Status | Document |
|-------|------|--------|----------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | ✅ **Done on owned surfaces** — planning + documentation topology; secrets model finalized to Vault-root + cluster federation (2026-06-14, Sprint `0.13`), documentation harmony machine-checked. Independent Validation + per-sprint detail: [phase-0-planning-documentation.md](phase-0-planning-documentation.md). | [phase-0-planning-documentation.md](phase-0-planning-documentation.md) |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | ✅ **Reclosed 2026-07-10** — Sprint `1.60` lands the opaque nested runtime-memory plan, profile-derived cgroup authority, finite child-schedule witness, typed scratch/high-water projections, and generated gateway RTS argv (unit 1299/1299; CLI/env integration 45/45; `dev check` 0). Sprint `2.31` consumes the plan and completed Sprint `5.16` consumes the high-water projection. Independent Validation + detail: [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md). | [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) |
| 2 | Haskell Gateway Runtime and DNS Ownership | ✅ **Reclosed 2026-07-10** — Sprint `2.31` replaces the unbounded hot peer log/full-log retransmission path with bounded semantic state and signed cursor/delta/repair gossip, bounds Orders/frame/process-wide allocation, retains safe per-emitter continuity, serializes child work, and gates DNS effects on explicit credential/claim/continuity authority. The restart-free live soak remains a non-blocking Standard-O axis. Independent Validation + detail: [phase-2-gateway-dns.md](phase-2-gateway-dns.md). | [phase-2-gateway-dns.md](phase-2-gateway-dns.md) |
| 3 | Haskell Chart Platform and Public Workload Delivery | ✅ **Reclosed 2026-07-10** — Sprint `3.25` binds gateway liveness/readiness through the typed/generated `/healthz` and `/readyz` values surface and chart lint forbids `/v1/state` as a kubelet probe (unit 1386/1386; focused 4/4; chart/Haskell lint/generated drift/`dev check` 0). Prior chart/operator closures are preserved. Independent Validation + detail: [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md). | [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | ✅ **Reclosed 2026-07-10** — Sprint `4.47` composes the registered `aws-ses` ensure through the retained-authority lease, bounded fixed-role STS sessions, fenced encrypted checkpoint, finite SMTP repair, and global target-intent protocol. The operational role is registered and leak-proof. Evidence: focused 87/87, warning-clean build, unit 1476/1476, `dev check` 0. Independent Validation + detail: [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md). | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| 5 | Canonical Test Suite | ✅ **Reclosed 2026-07-10** — Sprint `5.16` supplies the continuous run-wide restart/OOM/high-water oracle. Sprint `5.17` derives one nested retained-SES plan from invite capability, proves the selected target gateway edge, invokes the registered bracketed ensure once, keeps retained authority and target sink distinct, blocks dependants on failure, and excludes SES from ordinary cleanup (focused plan/recovery 10/10, target API 6/6, target-commit 12/12, unit 1508/1508, CLI/env integration 47/47 each, `dev check` 0). Independent Validation + detail: [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md). | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | ✅ **Done on owned surfaces** — clean-room rerun + zero-Python handoff contract; an incomplete later phase never reopens or blocks it ([Standard N](development_plan_standards.md#n-phase-independence-no-backward-blocking)). Independent Validation: [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md). | [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) |
| 7 | AWS Substrate Foundations | ✅ **Reclosed 2026-07-10** — Sprint `7.32` compiles the configured DAG through the shared anchored-order engine before mutation, supplies final EKS-owned one-shot readiness targets, holds a positively established gateway Service port-forward across the Vault transition, removes the redundant steady-state MinIO reinstall, delegates the EKS classifier to the shared base with no lint allowance, and projects AWS bootstrap from the shared restore builder after all three stack reconciles (unit 1286/1286; `dev check` exit 0). Prior closures remain preserved. 🧪 the live `prodbox test all --substrate aws` aggregate is the non-blocking Standard-O axis ([substrates.md](substrates.md)). Independent Validation + per-sprint detail: [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md). | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) |
| 8 | Operator-Invited Email Authentication via Keycloak + AWS SES | ✅ **Reclosed 2026-07-11** — Sprint `8.10` replaces exit-code-only SES checks with exhaustive exact identity, DKIM, MX, receipt-rule/action, and capture list/get-capability observations, a bounded 20-minute semantic poll inside the 30-minute retained-resource lease, and `prodbox host check-ses-readiness`. Evidence: focused readiness 23/23, SES transaction 8/8, lease-role 9/9, built-frontend fixtures 2/2, unit 1535/1535, CLI/env integration 49/49 each, warning-clean build, and Fourmolu check. 🧪 Fresh AWS propagation and deployed home/AWS invite aggregates remain non-blocking `Live-proof: pending`. Independent Validation + per-sprint detail: [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md). | [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) |

**Status interpretation.** The finalized architecture: secrets are **Vault-root + cluster
federation** (2026-06-14 — the master-seed HMAC derivation model is retired, `FileSecret` /
Secret-mounted plaintext Dhall removed), and MinIO/Pulumi state uses the **Model-B** object-level
Vault-Transit envelope with whole-system zero-child-info framing (2026-06-15). Both *refined* rather
than reversed prior models and reopened no new phase. The dated reopen/closure history is
consolidated in the [Closure Status](#closure-status) milestone ledger above; per-sprint detail is in
the phase documents.

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
| Home local | `prodbox cluster reconcile` + `prodbox charts reconcile ...` | `prodbox cluster delete --yes` (`--cascade` also destroys per-run AWS stacks) | 🧪 **Current code-owned membership closed; live proof pending.** Sprints `1.60`/`2.31`/`3.25`/`4.47`/`5.16`/`5.17`/`8.10` have landed the bounded runtime, constant-time probes, safe registered retained-resource transaction, absorbing gateway-stability oracle, capability-derived retained preparation, and exact semantic SES readiness. Earlier ZeroSSL/OIDC/WebSocket/public-edge proofs remain valid; a fresh deployed home invite aggregate through the new readiness gate is the non-blocking Standard-O axis. Current membership remains `src/Prodbox/TestPlan.hs`. | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) |
| AWS | `prodbox aws stack eks reconcile` + `prodbox aws stack aws-subzone reconcile` + `prodbox aws stack test reconcile` | `prodbox aws stack aws-subzone destroy --yes` + `prodbox aws stack eks destroy --yes` + `prodbox aws stack test destroy --yes` | 🧪 **Code-owned parity closed; aggregate live proof pending.** Phase 7-owned AWS substrate parity and the then-canonical June slice remain proven. Sprint `8.10` now supplies the identical exact semantic SES gate on AWS; fresh identity/DKIM/MX/rule propagation plus the full deployed `prodbox test all --substrate aws` invite path remain non-blocking Standard-O axes. Current canonical-suite membership is defined in `src/Prodbox/TestPlan.hs`; live coverage is tracked only in [substrates.md](substrates.md)'s per-validation table. | [phase-7-aws-substrate-foundations.md → Sprint 7.5](phase-7-aws-substrate-foundations.md) |

## Current Plan Status

All declared phase-owned code surfaces are closed. Phases `1` and `2` reclosed on the generic
runtime-memory plan (`1.60`) and bounded gateway state/transport/credentialed DNS (`2.31`); Phase `3`
landed constant-time chart probes in `3.25`; Phase `4` reclosed on desired-present retained
reconciliation, fail-closed AWS/checkpoint observations, explicit long-lived checkpoint authority,
and the shared SES lease (`4.47`); Phase `5` reclosed on the gateway stability oracle (`5.16`) and
capability-derived SES preparation (`5.17`); and Phase `8` reclosed on exact semantic SES readiness
(`8.10`). No phase-owned sprint is `Active`, `Planned`, or `Blocked`. Fresh AWS
identity/DKIM/MX/rule propagation and deployed home/AWS invite aggregates remain non-blocking
Standard-O live-proof axes.

Phases `6` and `7` remain closed because the new work does not expand their owned surfaces
([Standard N](development_plan_standards.md#n-phase-independence-no-backward-blocking)). All earlier
completed sprints remain preserved. Vault-root secrets and Model-B object encryption remain the
finalized architecture; the retained home/control-plane `prodbox-state` plus Vault keyspace is the
long-lived SES checkpoint authority, while SMTP KV materialization into a selected substrate is a
separate target-cluster effect. The following implemented baseline surfaces remain current on the supported path:

- `src/Prodbox/Settings.hs` preserves the supported direct `Dhall -> Haskell types` contract by
  decoding the executable-sibling Tier-0 `prodbox.dhall` in-process through the native `dhall`
  library, without
  materializing `prodbox-config.json`.
- `src/Prodbox/BuildSupport.hs`, `src/Prodbox/Repo.hs`, and `test/integration/EnvSuite.hs`
  preserve the operator-facing `.build/prodbox` artifact contract, executable-sibling config-path
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
- Every runtime path by which elevated/admin AWS power enters prodbox — `config setup`, `aws setup`,
  the native IAM harness, the long-lived `aws-ses` stack ops, and `prodbox nuke` — acquires the
  ephemeral elevated credential through the interactive `SecretRef.Prompt`, uses it once, and
  discards it. The `aws_admin_for_test_simulation.*` fixture is a test-harness-only `TestPlaintext`
  fixture in `test-secrets.dhall` whose sole purpose is to simulate that operator prompt
  non-interactively; it is never read by a production binary and never stored in
  `prodbox.dhall` or Vault.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and `src/Prodbox/TestValidation.hs`
  now route `prodbox test integration aws-iam`, targeted
  `prodbox test integration <name> --substrate aws` validations, `prodbox test integration all`,
  and `prodbox test all` through one shared suite-level IAM harness that provisions temporary
  operational `aws.*` before prerequisite-driven AWS validation begins, destroys validation-owned
  per-run stacks when the targeted suite may provision them, and clears those credentials again
  before the suite returns.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/Prerequisite.hs`, and
  `src/Prodbox/EffectInterpreter.hs` now split the aggregate prerequisite model into an initial
  fail-fast gate plus a deferred cluster-backed backend proof, so `prodbox test integration all`
  and `prodbox test all` no longer fail at `pulumi_logged_in` before the visible `cluster reconcile`
  phase has created or repaired the supported MinIO-backed Pulumi backend.
- The shared IAM harness deletes any pre-existing dedicated `prodbox` IAM user and that user's
  access keys, uses any pre-existing `aws.*` only to discover and delete the IAM user associated
  with those credentials, proves STS-federated operational credentials with a compact
  AWS-validation session policy, waits for the dedicated IAM-user credentials to pass STS and
  repeated Route 53 hosted-zone probes, materializes IAM-user operational `aws.*` only from the
  `test-secrets.dhall` `aws_admin_for_test_simulation.*` fixture (simulating the operator's
  interactive admin-credential prompt) because cert-manager Route 53 DNS01 credentials do not
  support an STS session-token field, and clears `aws.*` from Vault KV before
  returning even on later prerequisite failure.
- Supported AWS subprocesses now strip ambient AWS auth and profile variables before projecting
  Vault/Tier-0 credentials into the subprocess environment, so supported paths cannot fall back
  to host AWS auth state.
- The supported container topology lives entirely under `docker/`. Every repository-owned
  Haskell-build Dockerfile stays single-stage `ubuntu:24.04`, installs `ghcup` in-image, pins GHC
  `9.12.4`, and does not create symlinked Haskell tool shims.
- The authoritative local lifecycle target is Haskell-owned and uses a single in-cluster
  `registry:2` backed by MinIO; required public and custom images are present there before later
  Helm deployments proceed.
- The registry publication path retries transient failures on the same candidate and
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
- The public `prodbox aws stack ...` surface covers the AWS substrate stacks under
  `pulumi/aws-eks/`, `pulumi/aws-eks-subzone/`, `pulumi/aws-test/`, and `pulumi/aws-ses/`.
  Non-secret validation inputs are synchronized through stack config, while AWS provider
  credentials resolve through Vault/Tier-0 references and the Haskell-owned subprocess environment.
- AWS stack checkpoints use the encrypted Model-B object-store wrapper and are observed through
  authoritative backend outputs. EKS kubeconfig and HA-RKE2 SSH material are bracketed in scoped
  temporary files; no supported stack snapshot, kubeconfig, or SSH-key path persists under
  `.prodbox-state/`. The HA-RKE2 validation may destroy and recreate `aws-test` once when reconcile
  succeeds but SSH validation proves stale instances.
- The current gateway runtime surface is Haskell-owned and code-backed in
  `src/Prodbox/Gateway/{Bounds,State,Orders,Peer,Continuity,ContinuityStore,DnsAuthority,ChildSchedule,Daemon}.hs`.
  Bounded Orders admission feeds finite keyed heartbeat/ownership state, signed per-emitter
  cursor/delta/repair exchange, fixed replay/checkpoint/diagnostic retention, and bounded nested
  `/v1/state` cursors. The local-emitter Model-B authority stages and re-observes the exact signed
  assertion/next anchor before publication; its Vault admission marker prevents continuity reset.
  All object-store/Vault/public-IP/Route 53 children consume one capacity-one permit, and only a
  validated credential/claim/continuity-bound `DnsWriteAction` can reach Route 53.
- `prodbox test integration gateway-partition` now runs as a distinct native validation path,
  while the retained peer trust-material fields are validated and bound as authoritative runtime
  transport inputs.
- `src/Prodbox/Tla.hs` still owns `prodbox dev tla-check`, while
  `documents/engineering/tla_modelling_assumptions.md` records the current runtime-to-model
  correspondence and compression points for the Phase `2` surface.
- `src/Prodbox/CLI/Rke2.hs` retains lifecycle-owned bootstrap DNS reconcile and ACME
  `ClusterIssuer` projection; those helpers do not expand the public `prodbox aws stack ...` command
  family.
- `src/Prodbox/CLI/Rke2.hs` now closes the supported lifecycle on the single-binary in-cluster
  `registry:2`, Envoy
  Gateway, cert-manager, and Percona reconcile path with no retained cluster-migration cleanup
  shims for Traefik or the pre-Percona operator surface.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` now sync only
  the supported retained AWS-validation stack inputs and no longer remove older Pulumi
  provider-key layouts on the supported path.
- The self-managed public edge now installs Envoy Gateway, renders Gateway API resources, and
  protects shared-host browser, API, WebSocket, and admin routes through Envoy auth policy.
- `src/Prodbox/CLI/Rke2.hs` now renders config-selected MetalLB L2 or BGP resources, lifts the
  Envoy Gateway controller and data-plane replica counts into settings, and builds or imports the
  single union runtime image (`prodbox-runtime`, shared by the gateway daemon and the api/websocket
  workloads) during `cluster reconcile`.
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
  `/auth`, `/vscode`, `/api`, `/ws`, and `/minio` aligned on one Haskell-owned
  public-edge contract.
- Root `README.md` plus the governed public-edge, gateway, chart-platform, registry, and testing
  doctrine docs now describe that same supported route catalog and command surface, and the
  previously scheduled route/catalog gaps are closed in the same code-backed paths. The distinct
  July 10 gateway-memory, probe-binding, and long-lived-resource gaps are also closed by Sprints
  `1.60`, `2.31`, `3.25`, `4.47`, `5.16`, `5.17`, and `8.10`.
- `charts/keycloak/`, `charts/api/`, `charts/redis/`, `charts/websocket/`, `charts/vscode/`,
  `src/Prodbox/Lib/ChartPlatform.hs`, and `src/Prodbox/Workload.hs` now own the shared-host
  workload contract, including the internal `workload.mode = Api \| Websocket` runtime selector
  sourced only from the mounted Dhall config per
  [config_doctrine.md](../documents/engineering/config_doctrine.md) (Sprint `3.14` removed the
  legacy environment selector),
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
  current Keycloak identity, `vscode`, `api`, `websocket`, and MinIO routes through named
  external validations on one shared hostname.
- `src/Prodbox/Host.hs` now recognizes only the supported
  `System clock synchronized` timedatectl field in `parseTimedatectlNtpDisposition`, so the
  Phase `2` host-info path closes on the Ubuntu 24.04 field format described by the current
  doctrine.
- `charts/gateway/` and `prodbox gateway start|status|config-gen` remain the separate Haskell
  distributed gateway daemon surface; they are not the Envoy Gateway public edge.
- The canonical validation surfaces are `prodbox dev check`, `prodbox test unit`,
  `prodbox test integration cli`, `prodbox test integration env`, the named Haskell-owned
  validation
  flows in `src/Prodbox/TestValidation.hs`, and the aggregate reruns
  `prodbox test integration all` plus `prodbox test all`.
- The aggregate rerun contract is owned by the shared suite plan behind
  `prodbox test integration all` and `prodbox test all`, including AWS IAM,
  Route 53, public-edge, EKS, HA-RKE2, destructive lifecycle, and post-test restore.
- The final Phase `6` destructive rerun and handoff validation are closed on that aggregate rerun
  contract and the supported postflight restore path.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is the sole cleanup ledger.
  The Sprint `2.31` log/transport, Sprint `3.25` probe, Sprint `4.47` retained-lifecycle, Sprint
  `5.16` stability, Sprint `5.17` assumed-pre-existing/manual-preparation, and Sprint `8.10`
  exit-code-only SES-readiness removals are recorded under `Completed`. Unrelated compatibility
  and cleanup rows remain under `Pending Removal`; prior cleanup history stays under `Completed`
  and is not duplicated here.

## Exit Definition

This plan is complete only when all of the following are true:

1. `DEVELOPMENT_PLAN/` and governed doctrine describe the Haskell architecture and the Envoy
   Gateway target rather than the retired Python architecture or a Traefik end state.
2. The supported operator flow is `prodbox`, implemented in Haskell, across config, lifecycle,
   AWS stack orchestration, gateway, chart delivery, validation, and AWS administration.
3. The supported config contract is direct `Dhall -> Haskell types` from the executable-sibling
   Tier-0 `prodbox.dhall`, with `prodbox-config-types.dhall` aligned to the
   decoder and no generated `prodbox-config.json` artifact or supported `prodbox config compile`
   path.
4. Public `prodbox config setup` and public `prodbox aws ...` paths can bootstrap all required AWS
   credentials from scratch using temporary admin credentials entered interactively by the
   operator.
5. `aws_admin_for_test_simulation.*` lives only in the test-harness-only `test-secrets.dhall`
   (`TestPlaintext`), never in `prodbox.dhall` or Vault, and its sole purpose is to
   simulate the operator's interactive admin-credential prompt for suite-driven destructive
   validation and long-lived stack / `prodbox nuke` flows. Public `config setup`, public
   `aws ...`, the long-lived `aws-ses` stack ops, and `prodbox nuke` all acquire the ephemeral
   elevated credential through the interactive `SecretRef.Prompt` — there is no production
   config-backed admin path.
6. `prodbox test integration aws-iam`, targeted
   `prodbox test integration <name> --substrate aws` validations,
   `prodbox test integration all`, and `prodbox test all` share one joint idempotent IAM
   validation harness that deletes any pre-existing dedicated `prodbox` IAM user and all of that
   user's access keys before provisioning, uses any pre-existing `aws.*` credentials only to
   discover and delete the IAM user associated with those credentials, proves STS-federated
   operational credentials with a compact AWS-validation session policy, waits for the dedicated
   IAM-user credentials to pass STS and repeated Route 53 hosted-zone probes, materializes
   IAM-user operational `aws.*` only from the `test-secrets.dhall` `aws_admin_for_test_simulation.*`
   fixture to simulate the interactive admin-credential prompt of the public CLI workflow because
   cert-manager Route 53 DNS01 credentials do not support
   an STS session-token field, destroys validation-owned per-run stacks when the targeted suite may
   provision them, and clears operational `aws.*` from Vault KV before returning so
   no test-created dedicated IAM user or key survives.
7. The operator-facing binary lives at `.build/prodbox`, produced by the canonical
   `cabal build --builddir=.build exe:prodbox` invocation plus a copy step.
8. Container-side build artifacts live under `/opt/build`, and every repository-owned Dockerfile
   lives under `docker/`.
9. Every repository-owned Haskell-build Dockerfile is single-stage from `ubuntu:24.04`, installs
   `ghcup` in-image, pins GHC `9.12.4`, and does not create symlinked Haskell tool shims; no
   supported browser-facing auth path depends on a repository-owned nginx auth-proxy image.
10. `prodbox.cabal`, `cabal.project`, and the canonical build-and-test surfaces are explicitly
    upgraded for GHC `9.12.4`, including any required cabal-bound changes and full canonical
    validation reruns on that toolchain.
11. `prodbox dev check` enforces the governed doctrine-alignment contract described by
    `documents/engineering/code_quality.md`, not only formatter, linter, build, and binary-sync
    checks.
12. The Haskell distributed gateway runtime, `gateway status` client path, and daemon config
    validation close only when `/v1/state` is bounded independently of uptime, the dedicated
    `/healthz` and `/readyz` projections remain constant-time, the Orders-backed interval
    relationships are preserved, and the runtime/model correspondence records the finite semantic
    projection and delta protocol.
13. The self-managed public edge uses MetalLB, Envoy Gateway, Kubernetes Gateway API, and
    cert-manager rather than Traefik plus `Ingress`.
14. Every externally reachable application or operational dashboard routes through Envoy on the
    single canonical hostname `test.resolvefintech.com`, using explicit path prefixes such as
    `/vscode`, `/api`, `/ws`, `/auth`, and later supported admin paths.
15. The supported public-edge doctrine uses exactly one public DNS entry, one listener
    certificate, and no dedicated identity, browser, API, or WebSocket hostnames. Wildcard
    public DNS is unsupported.
16. `prodbox edge status`, `prodbox test integration charts-vscode`,
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
24. Direct public-registry pulls are permitted only for the bounded MinIO/storage dependencies
    needed to bootstrap the in-cluster `registry:2` service.
25. Every later supported Helm deployment obtains its images from that in-cluster registry.
26. `prodbox` idempotently ensures required public images and all custom images are present in
    the registry before those later deployments.
27. Supported custom-image builds and registry publication use only the native architecture of the
    machine running `prodbox`: `amd64` hosts build and publish `amd64` images, and `arm64` hosts
    build and publish `arm64` images.
28. Native `arm64` publication works on native `arm64` Docker daemons. `docker buildx`,
    cross-arch emulation, and mixed-arch cluster closure are not part of the supported lifecycle
    or chart-delivery path.
29. Every supported Helm-managed PostgreSQL deployment is external, reconciled only through the
    cluster-wide Percona operator, and runs Patroni HA with exactly three PostgreSQL replicas,
    synchronous replication, and no embedded chart-local PostgreSQL subchart.
30. Pulumi remains part of the supported architecture for true IaC and AWS substrate resources.
    The public `prodbox aws stack ...` surface stays limited to those stacks, while local-cluster
    lifecycle, bootstrap DNS reconcile, and ACME `ClusterIssuer` projection remain owned by
    `src/Prodbox/CLI/Rke2.hs` rather than by a public Pulumi operator flow.
31. No supported Pulumi program depends on Python.
32. The strongest clean-room rerun passes from full local delete through final AWS teardown using
    the Haskell stack.
33. Every `Pending Removal` row in
    [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is either removed with its
    replacement verified or moved to `Completed`; no unsupported compatibility surface remains at
    plan exit.
34. The repository has no supported-path Python implementation or Python toolchain ownership
    artifacts left.
35. The Haskell gateway daemon materializes peer transport from the certificate, key, CA, and
    socket fields already retained in `DaemonConfig` and `Orders`: every node updates
    `stateLastHeartbeatTimes` from inbound peer events rather than from the local heartbeat loop
    only; finite latest-heartbeat/ownership state converges through signed per-emitter monotonic
    sequences, per-emitter previous hashes, vector-cursor deltas, and bounded signed compaction
    checkpoints; and `/v1/state` exposes bounded per-peer transport health for operator inspection.
36. The gateway daemon emits signed `Claim` and `Yield` evidence on owner transitions and gates
    Route 53 writes on a credential-ready runtime equivalent of the modelled `CanWriteDns`
    predicate, so `ClaimPrecedesWrite` and `YieldPrecedesReclaim` hold on the bounded semantic
    event projection rather than only on the model, ambient AWS authentication cannot create write
    authority, and a stale owner cannot reclaim without observing its yield superseded by a fresh
    claim.
37. The supported-host gate fails fast when the host's NTP synchronization state is unhealthy, the
    gateway daemon records the maximum observed inter-node clock skew on `/v1/state` and refuses
    inbound heartbeats whose timestamps exceed the documented bound, and the architecture and TLA+
    correspondence docs name that bound, the operator response, and how the model's bounded-delay
    assumption maps to a runtime-enforced skew limit.
38. Orders documents carry a monotonic version field, daemons reject inbound peer evidence from a
    peer presenting an older Orders version, a new Orders version propagates through bounded delta
    gossip and is adopted by every live daemon before the next election tick, and a daemon
    rebooting against a stale Orders version refuses to claim ownership until its Orders view
    catches up.
39. Invite-capable suite plans unconditionally invoke the registered idempotent `aws-ses`
    desired-present reconciler through the explicit retained control-plane checkpoint authority,
    await semantic identity/DKIM/rule-set/S3 readiness, then write SMTP material only to the
    selected target-cluster sink; ordinary postflight retains the stack and concurrent runs share
    one bounded lease.
40. Gateway runtime stability is proved by a run-wide absorbing restart/OOM/high-water evidence
    fold plus a separate restartable healthy window. An instantaneous Deployment
    `Available=True` sample remains a dependency-readiness fact and never erases earlier unhealthy
    evidence.
