# prodbox Development Plan

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../AGENTS.md](../AGENTS.md),
[../documents/engineering/README.md](../documents/engineering/README.md),
[../documents/engineering/lifecycle_control_plane_architecture.md](../documents/engineering/lifecycle_control_plane_architecture.md),
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

**Current head state (2026-07-11 — lifecycle-control-plane redesign opened).** The
current revision is not deployment-qualified. Two full-suite attempts supplied a production
counterexample to the July 11 closure narrative:

- the nominal gateway-to-MinIO readiness request exceeded its 30-second client deadline even
  though MinIO itself was healthy;
- all three gateway replicas were pinned at their 250m CPU limits with 96–99% cgroup throttle
  periods while the continuity/heartbeat path repeatedly launched object-store subprocesses;
- a later run passed that point observation but lost the retained SES authority and release through
  the same gateway failure domain;
- the AWS selected-target precondition observed the EKS gateway while execution used the retained
  home authority;
- the fail-fast restore sequence skipped independent local chart restoration after the SES failure.

The earlier sprints remain historical completed work on their stated, narrower code-local surfaces.
They do not prove the expanded architecture. Sprint `0.16` recloses Phase `0` on the governance
and design correction. Phases `1`–`8` are reopened on their own surfaces: Sprint `1.61` is
Planned; `1.62`, `2.32`–`2.33`, `3.26`, `4.48`–`4.50`, `5.18`–`5.19`, `6.4`,
`7.33`, and `8.11`–`8.12` are blocked only by the earlier sprint chain recorded in their phase
documents.

**Foundation Epoch (2026-07-12).** Governance Sprint `0.17` recloses Phase `0` a second time on
the `LCPC-2026-07-11` structural correction: cross-boundary contracts become compiled values with
generated projections, retained custody becomes durability-indexed, restoration becomes a derived
total graph, and authored capacity becomes measured-certified. The Foundation Epoch (Sprints
`1.63`–`1.66`, `2.34`, `4.51`, `5.20`, `5.21`, and `7.34`) is the active work front and is
executed before Sprints `1.61` and `1.62` as an execution-priority decision; it introduces no
`Blocked by` edge onto the existing `1.61` → `8.12` chain, which resumes unchanged once the epoch
closes. Sprints `1.61`/`1.62` are shrink-rescoped with titles and anchors unchanged (readiness
evidence to Sprint `2.34`; the cached Vault session to Sprint `1.64` and the native S3
object-store client to Sprint `1.66`).

The target replacement is the pure-functional
[Lifecycle Control-Plane Architecture](../documents/engineering/lifecycle_control_plane_architecture.md):
a minimal Bootstrap Broker, a retained Lifecycle Authority, substrate-local Target Secret Agents,
and a mesh/DNS-only Gateway Runtime with an identity-bound emitter journal (the EKS DNS mutation
capability is disabled). Capability observation,
admission, and execution use one operation-indexed `CapabilityRef` and one absolute deadline. Lifecycle
work is a durable operation journal/outbox rather than a synchronous lease bracket, and suite
postflight is an always-run cleanup DAG.

**Deployment qualification: pending.** Standard P forbids calling the current revision seamless,
deployment-ready, fully closed, or operationally cut over until the exact revision/config digest
passes the required load, fault, consecutive aggregate, cancellation, and cleanup campaign on the
home and AWS substrate rows below.

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
| 2026-07-12 | Sprint `2.34` ✅ **Done — compiled service boundary + latched readiness + chart statics** — (1) `Prodbox.Gateway.Routes` is the closed `GatewayRoute` registry (`Enum`/`Bounded`; `routePattern`/`routeClass`/`routeForPath`; the `kubeletProbeRoute` smart constructor makes a probe on a non-probe route unbuildable), the single source of every gateway daemon path string; the daemon dispatcher is a total `case` over it, and the client, chart probe paths (`GatewayProbeEndpoint` deleted), and the `ObjectStore`/`TargetSecret` wire paths are all `routePattern` projections. (2) Readiness is one pure latched `computeReadiness` projection (`Prodbox.Gateway.Readiness`) over three monotone facts (drain phase / object-store proof / workers-started) with zero I/O; the unconditional serve-start `Ready` write is deleted, the proof latches once in `installRuntime`'s continuity-publish STM transaction on the first validated `StartupRecovery`, the lifecycle-restore gate gains a `/readyz` precheck (lifecycle-ready ⟹ kubelet-ready), and readiness `failureThreshold` is 3→6. (3) `Prodbox.Gateway.ChartStatics` is the one source for ports/NodePort/ServiceAccount/Vault-role, feeding `valuesForGateway` and the generated `gateway-chart-statics.values` section, with a `.Values.serviceAccount.name` template binding, a forbidden-raw-literal chart lint, and a deployed-values-equal-compiled conformance gate. Evidence: warning-clean `-Werror` build, fourmolu/hlint clean, unit 1610/1610 (incl. `GatewayRoutes`/`GatewayReadiness`/`GatewayChartStatics` suites), `prodbox-daemon-lifecycle` 13/13 (real daemon `/healthz`/`/readyz` ready + SIGTERM drain to 503 + pre-Vault invariant), CLI+env integration 49/49, `prodbox dev check` exit 0. Standard O: the live object-store round-trip that earns the latch is *seeded* in the no-Vault/no-MinIO harnesses (`PRODBOX_TEST_OBJECT_STORE_PROOF_LATCH`) and exercised for real only by the AWS/chaos integration validations. |
| 2026-07-12 | Sprint `1.66` ✅ **Done — native SigV4 object-store client landed; Phase-1 Foundation Epoch complete** — `Prodbox.Aws.SigV4` is the pure, byte-exact SigV4 algorithm (canonical request, string-to-sign, HMAC signing-key chain, authorization header), verified against published AWS vectors (empty-payload SHA-256, the AWS-documented signing-key derivation, and the get-vanilla canonical request/signature). `Prodbox.Minio.ObjectStoreNative` performs every Model-B object-store operation (get/put/conditional-put/list/head/create/delete) as an in-memory, SigV4-signed S3 request over the Sprint-`1.64` shared TLS manager — no `aws` CLI subprocess and no per-operation temp-file bodies (the third `LCPC-2026-07-11` gateway CPU driver). ETag `If-Match`/`If-None-Match` conditional semantics and the absence/conflict outcome taxonomy are preserved. Shared types were extracted to `Prodbox.Minio.ObjectStoreTypes`; the `ObjectStoreBackend` selector in `Prodbox.Minio.ObjectStore` keeps the subprocess path the default config-selectable rollback until live-MinIO parity (a Standard-O axis) is proven, then it is retired. Evidence: warning-clean `-Werror` build, unit green (new `SigV4` + `ObjectStoreNative` conformance suites), `prodbox dev check` exit 0. This completes the four Phase-1 Foundation Epoch sprints (`1.63`–`1.66`). |
| 2026-07-12 | Sprint `1.65` ✅ **Done — measured-capacity certification landed** — `Prodbox.Capacity.MeasuredProfile` is the committed-profile type + pure certification rules (authored CPU below measured `cpu_p99_milli` × 4/3, memory high-water × 4/3 above the authored limit, `throttled_periods_ppm` above 20000 under a CPU cap, or staleness by `hot_path_digest`/30-day age — all one-sided so a measured improvement never fails), field-for-field matching [resource_scaling_doctrine.md § 2F](../documents/engineering/resource_scaling_doctrine.md). `checkMeasuredCapacityProfiles` runs in `runConformanceTier` and is inert until Sprint `5.21` commits the first profile under `dhall/capacity/measured/`. The interim authored gateway envelope rises 250m → 750m (`request == limit`, Guaranteed QoS); to fit the single-node 6500m allocatable the gateway namespace quota rises to 2750m and the over-provisioned vscode ceiling drops to 1400m (pods still draw 800m — operator-approved). `prodbox-config-types.dhall` regenerated. Evidence: warning-clean `-Werror` build, unit 1566/1566 (incl. the new `MeasuredProfile` conformance suite), `prodbox dev check` exit 0. The recorder + first committed profile are the Sprint `5.21` axis. |
| 2026-07-12 | Sprint `1.64` ✅ **Done — shared TLS manager + cached Vault session landed** — two of counterexample `LCPC-2026-07-11`'s three gateway hot-path CPU drivers are removed: `Prodbox.Http.Client` now holds one process-wide `sharedTlsManager` (the per-call `newManager` is deleted), and `Prodbox.Vault.Session` serves the gateway daemon's own service-account token from a cached renewable session (monotonic expiry, single-flight renewal at two-thirds of the lease, sealed/forbidden/unavailable classification, and one `403` invalidate-and-relogin via `withSessionToken`, wired at the target-secret read). `resolveGatewayVaultTokenFor` consults the session; the escape registry's `per-request-vault-login` seam is retired and the per-call-TLS-manager + gateway-service-account-login ledger rows moved to Completed. The operator-secret operator-JWT exchange is inherently per-request and reclassified under Sprint `2.33`/`4.50`; the third driver (`aws` CLI object-store subprocess) is Sprint `1.66`. Evidence: warning-clean `-Werror` build, unit 1552/1552 (incl. the new `VaultSession` conformance suite with a deterministic single-flight test), `prodbox dev check` exit 0. The measured CPU reduction is the non-blocking Sprint `5.21` axis. |
| 2026-07-12 | Sprint `1.63` ✅ **Done — conformance tier + legacy escape registry landed** — `src/Prodbox/Legacy/EscapeRegistry.hs` is the compiled SSoT for the eight pre-cutover escape seams (gateway-hosted authority routes; shared operational AWS credential; host-direct object-store, Vault-KV, and Vault-root-token seams; the `aws` CLI object-store subprocess; and the two per-request gateway Vault logins), each bijectively bound to a `LEGACY-ESCAPE[…]` source marker. `runConformanceTier` in `CheckCode.hs` runs the registry↔source bijection in the fast pre-build phase of `prodbox dev check`, so an unregistered escape or a stale registry entry fails in seconds (the Standard P interim escape-path guard). Evidence: warning-clean `-Werror` build, unit 1541/1541 (incl. the new `EscapeRegistry` conformance suite), `prodbox dev check` exit 0. First Foundation Epoch implementation sprint; the epoch's `1.64`–`1.66`/`2.34`/`4.51`/`5.20`/`5.21`/`7.34` remain the active front. |
| 2026-07-12 | Sprint `0.17` ✅ **Done; Foundation Epoch adopted, Phase 0 reclosed** — the four `LCPC-2026-07-11` failure mechanisms receive structural owners: Sprint `2.34` (compiled service boundary and latched readiness), Sprints `4.51`/`5.20` (durability-indexed retained custody and the derived total restore graph), Sprints `1.64`/`1.65`/`1.66` (gateway hot-path session/native-client elimination and measured capacity certification), and Sprint `7.34` (per-run postflight residue narrowing). Standard P gains the interim escape-path guard, whose registry is owned by Sprint `1.63`; Sprints `1.61`/`1.62` are shrink-rescoped with titles and anchors unchanged. The epoch executes before Sprints `1.61`/`1.62` as an execution-priority decision and introduces no `Blocked by` edge onto the `1.61` → `8.12` chain; the Deployment Qualification rows remain pending. |
| 2026-07-12 | Sprint `0.18` ✅ **Done; certificate-scope policy adopted (governance surface)** — an operator-configurable certificate-scope policy makes an unmanaged or uncovered served hostname unrepresentable on the prodbox-managed side; the orphan dashboard-cert incident is dispositioned (serve `/vscode` on the shared host, operator revokes the orphan and unsubscribes — a manual ZeroSSL-console action); parent→child certificate-material handoff is rejected in favor of delivered `AcmeEabMaterial` self-issuance; implementation Sprints `2.35`/`5.22` are registered; and the root `ZEROSSL_POLICY.md` is retired into governed docs. Phase `0` gains an additional governance sprint on the Sprint `0.17` documentation surface (no further reclose event); the Deployment Qualification rows are unchanged. |
| 2026-07-11 | Sprint `0.16` ✅ **Done; Phases 1–8 reopened on expanded owned surfaces** — two current full-suite attempts disproved the nominal deep-readiness, gateway service-capacity, retained-authority isolation, endpoint-binding, and finally-restored-suite claims. The authoritative target now separates Bootstrap Broker, Lifecycle Authority, Target Secret Agent, and Gateway Runtime; capability operations are type-indexed and share observation/admission/execution identity; lifecycle work is durable and resumable; cleanup is an always-run DAG. Standard P makes deployment qualification revision-specific and prevents historical or point-probe evidence from authorizing a seamless/current-architecture claim. Implementation is scheduled in Sprints `1.61`–`8.12`; operational legacy rows remain Pending Removal until single-writer cutover and current-revision qualification. |
| 2026-07-11 | Sprint `8.10` ✅ **Done; Phase 8 reclosed** — `Prodbox.Ses.Readiness` classifies the exact configured sender identity, DKIM signing state, inbound MX, active/enabled receipt rule and S3 action, and Pulumi-owned capture canary list/get capability as `Ready`, retryable `Pending`, terminal `Failed`, or `Unobservable`. The registered `aws-ses` transaction runs provider reconciliation before the bounded semantic poll and cannot reach SMTP mutation after timeout or terminal evidence; `prodbox host check-ses-readiness` exposes the same read-only prerequisite surface. Evidence: warning-clean build, Fourmolu check, focused readiness 23/23, SES transaction 8/8, lease-role 9/9, built-frontend SES fixtures 2/2, full unit 1535/1535, and CLI/env integration 49/49 each. Fresh AWS identity/DKIM/MX/rule propagation and deployed home/AWS invite aggregates remain a non-blocking Standard-O `Live-proof: pending` axis. |
| 2026-07-10 | Sprint `5.17` ✅ **Done; Phase 5 reclosed** — `ValidationKeycloakInvite` alone derives one opaque nested retained-SES preparation plan. Its typed selected-target gateway object-store precondition precedes the exact acquire/reconcile/bounded provider-presence await/target-sync/release trace, interpreted through one call to Sprint `4.47`'s registered ensure. Home and AWS project only their selected sink; non-invite and postflight plans contain no SES mutation. Explicit authority/target coordinates, scoped EKS transport, real different-sink predecessor recovery, read-only deferred prerequisites, and retained cleanup are pinned by focused plan/recovery 10/10, target API 6/6, global target-commit 12/12, full unit 1508/1508, CLI/env integration 47/47 each, and `dev check` 0. Clean-state deployed invite runs remain a non-blocking Standard-O axis; semantic SES readiness was still assigned to Sprint `8.10` at this checkpoint and closed on 2026-07-11. |
| 2026-07-10 | Sprint `5.16` ✅ **Done** — `gateway-pods` now feeds typed pod/status, termination, Event, and metrics JSON into one concurrency-safe recorder through a structured continuous observer. Restart/OOM/failure-high-water and unobservable evidence fail closed across UID replacement and the compiled Phase-1.6/lifecycle/postflight/volume-rebind boundaries; only the separate three-sample healthy window resets for a planned gateway rollout. AWS observation starts at the gateway bootstrap handoff, uses a monitor-private explicit environment, and refreshes its kubeconfig through a request/acknowledgement barrier after EKS recreation. Every Kubernetes read has API and process deadlines. Thresholds derive from Sprint `1.60`'s runtime-memory plan, and logs remain diagnostic-only. Evidence: focused tables 17/17, installed-binary fake-Kubernetes proofs 2/2, warning-clean build, unit 1494/1494, CLI integration 47/47, and `dev check` 0. The longer deployed soak is a non-blocking Standard-O axis. |
| 2026-07-10 | Sprint `4.47` ✅ **Done; Phase 4 reclosed** — separate flat AWS-presence/checkpoint observations feed the total `DesiredPresence` loop and registered `LongLived` `aws-ses` ensure. The supported reconcile now acquires the retained authority lease, recovers released/expired predecessor provider and target effects, mints only fixed-role STS sessions bounded by the grant, writes checkpoints through fresh fenced CAS, repairs the finite SMTP IAM-key inventory, and materializes through the global target-intent protocol. The exact same-account role is registered as an `Operational` resource and teardown re-observes its absence before clearing the trusted user. This row preserves pre-cutover evidence: its Pulumi-owned SMTP principal/policy boundary is explicitly superseded by Sprint `8.11`'s frozen single-writer migration to a Credential-Provisioner-owned `LongLived` identity and retained-home custody. Evidence: warning-clean build, focused lifecycle tables 78/78 plus role tables 9/9, full unit 1476/1476, and `dev check` 0. Live AWS exercise remains a non-blocking Standard-O axis. |
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

The current reopen expands each phase's own authority surface while preserving completed historical
sprints. Forward-only blockers follow Standards A/N; deployment qualification is the distinct
Standard-P axis.

| Phase | Name | Current status | New owner |
|-------|------|----------------|-----------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | ✅ **Reclosed on Sprint `0.17`** after adopting the Foundation Epoch and the Standard P interim escape-path guard (previously reclosed on Sprint `0.16` for the physical control-plane SSoT and deployment-qualification governance). Governance Sprint `0.18` adds the certificate-scope policy adoption as an additional governance sprint on the same documentation surface (no further reclose event). | Documentation topology, certificate-scope governance, and Standard P |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | 📋 **Reopened; Foundation Epoch Phase-1 sprints `1.63`–`1.66` ✅ Done.** Sprint `1.61` remains Planned (shrink-rescoped); `1.62` is blocked by `1.61`. | Operation-indexed capabilities, exact graph requirements, absolute deadlines, service-capacity algebra, native object-store and managed Vault-session boundaries, conformance tier and legacy escape registry, measured capacity certification |
| 2 | Haskell Gateway Runtime and DNS Ownership | 📋 **Reopened; Foundation Epoch Sprint `2.34` ✅ Done** (compiled service boundary — route registry + total dispatch + client/probe/wire-path projections — plus latched readiness projection and `GatewayChartStatics` all landed and validated pre-cluster). Sprint `2.32` is blocked by `1.62`; `2.33` by `2.32`; `2.35` by `2.34`. | Single-writer emitter actor/journal, whole-transition ownership, Bootstrap Broker extraction, gateway scope reduction, compiled service boundary and latched readiness, configurable certificate-scope algebra and derived edge projections |
| 3 | Haskell Chart Platform and Public Workload Delivery | ⏸️ **Reopened; Sprint `3.26` blocked by `2.33`.** | Separate broker/authority/agent workloads, identities, policies, probes, retained journals, and resource envelopes |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | 🔄 **Reopened; Foundation Epoch Sprint `4.51` Active** (Increment A — `StoreLifetime` phantom-index foundation — landed + validated 2026-07-14; Increment B cutover deferred). Sprints `4.48`–`4.50` follow `3.26`. | Durable Lifecycle Authority, immutable checkpoints, operation journal/outbox, target delivery, authority-epoch cutover, removal of gateway/host-direct authority, durability-indexed retained authority storage |
| 5 | Canonical Test Suite | 📋 **Reopened; Foundation Epoch Sprint `5.20` Planned; `5.21` blocked by `1.65`.** Sprints `5.18`–`5.19` follow `4.50`; `5.22` is blocked by `2.35`. | Capability-bound preparation, always-run cleanup DAG, CPU/queue/deadline/fault oracle, derived restore graph and total executor, measured-profile recorder, certificate-scope serving validation |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | ⏸️ **Reopened; Sprint `6.4` blocked by `5.19`.** | Home clean-room cutover, rollback, consecutive aggregate, and zero-residue prerequisite evidence |
| 7 | AWS Substrate Foundations | 📋 **Reopened; Foundation Epoch Sprint `7.34` Planned.** Sprint `7.33` is blocked by `6.4`. | AWS Broker/Target-Agent/Gateway parity, exact client transport to the single retained home authority, resource isolation, prerequisite fault evidence, and per-run postflight residue narrowing |
| 8 | Operator-Invited Email Authentication via Keycloak + AWS SES | ⏸️ **Reopened; Sprints `8.11`–`8.12` follow `7.33`.** | Durable SES provider revision, narrow mutation fence, credential generation/outbox, and invite fault campaign |

Per-sprint Independent Validation, blockers, deliverables, and Documentation Requirements are
authoritative in the linked phase documents.

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
| Home local | `prodbox cluster reconcile` + `prodbox charts reconcile ...` | `prodbox cluster delete --yes` (`--cascade` also destroys per-run AWS stacks) | **pending.** Historical runs remain evidence for their revisions. Sprint `6.4` produces prerequisite home migration/fault evidence; Sprint `8.12` is the sole final owner because Sprints `8.11`–`8.12` subsequently change the shared SES workflow and must rerun both substrates. | [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) |
| AWS | `prodbox aws stack eks reconcile` + `prodbox aws stack aws-subzone reconcile` + `prodbox aws stack test reconcile` | `prodbox aws stack aws-subzone destroy --yes` + `prodbox aws stack eks destroy --yes` + `prodbox aws stack test destroy --yes` | **pending.** Sprint `7.33` produces prerequisite AWS isolation/fault evidence; Sprint `8.12` is the sole final owner after durable SES specialization and reruns both substrates. | [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) |

## Deployment Qualification

Per [Standard P](development_plan_standards.md#p-deployment-qualification-and-counterexample-closure),
qualification is revision- and topology-specific. It is not inferred from phase `Done`, a point
readiness response, an older green run, or fake-interpreter evidence.

Both identity columns use Standard P's secret-safe `SourceIdentity`: a versioned, digest-bound
allowlist of code, governed documentation, and non-secret schemas/templates. Its recorded exclusion
policy omits `test-secrets.dhall`, local/generated secret material, secret roots, and runtime/build
roots. Generated-config evidence covers only a canonical non-secret projection. Secret-dependent
runs bind through opaque Authority receipt/generation IDs or Vault-keyed HMAC commitments, never a
public raw hash of plaintext secrets; the evidence digest covers only those public/redacted fields.

| Substrate | Frozen superseded identity (secret-safe source/config/images/topology/wiring/envelope/load identities) | Replacement identity (secret-safe source/config/images/topology/wiring/envelope/load identities) | Canonical commands | Normalized mapping and production profile | Counterexample/fault matrix | Aggregate result | Cleanup/residue result | Start/completion timestamps | Evidence artifact/digest | Status/final owner |
|-----------|------------------------------------------|------------------------------------------|--------------------|---------------------------|-----------------------------|------------------|------------------------|-----------------------------|--------------------------|--------------------|
| Home local | pending complete `LCPC-2026-07-11` frozen identity | pending complete current-revision identity | Two consecutive `prodbox test all --substrate home-local` | pending normalized old→new mapping plus rendered production cgroups/rates | `LCPC-2026-07-11` plus gateway/authority/target/config/DNS/cancellation/response-loss, backup refusal/primary-loss exact restore, and cleanup-owner death/takeover pending | pending | pending canonical restore, durable `RunnerLost` recovery, and exact absence/retention observations | pending | pending | **pending** (`8.12`; `6.4` prerequisite evidence) |
| AWS | pending complete `LCPC-2026-07-11` frozen identity | pending complete current-revision identity | Two consecutive `prodbox test all --substrate aws` | pending normalized old→new mapping plus rendered EKS production envelopes/rates | AWS `LCPC-2026-07-11` plus endpoint binding, gateway saturation, authority/target/EKS restart, cancellation/response loss, backup refusal/primary-loss exact restore, and cleanup-owner death/takeover pending | pending | pending per-run stack/EBS/DNS absence, durable cleanup takeover, retained-authority quiescence, and dependency-safe Operational IAM cleanup | pending | pending | **pending** (`8.12`; `7.33` prerequisite evidence) |

Any change to process topology, capability wiring, deadline algebra, resource envelopes,
persistence, lifecycle orchestration, or cleanup invalidates a prior `proven` row.

## Current Plan Status

Phase `0` is reclosed on Sprint `0.17` (previously on Sprint `0.16`); Phases `1`–`8` are reopened
on expanded owned surfaces. Foundation Epoch Sprints `1.63` (conformance tier + legacy escape
registry), `1.64` (shared TLS manager + cached Vault session), `1.65` (measured capacity
certification), and `1.66` (native SigV4 object-store client) are ✅ Done — the four Phase-1
Foundation Epoch sprints are complete. The remaining Planned implementation sprints are the
Foundation Epoch sprints (`2.34`, `4.51`, `5.20`, `7.34`) plus the shrink-rescoped Sprint `1.61`;
Sprint `5.21` is blocked by `1.65`. Every downstream sprint is honestly Blocked by
an earlier owner, never by a later phase. The exact chain is summarized in the Phase Overview and
defined in the phase files, and the epoch's execution ordering is stated in the
[Foundation Epoch](#foundation-epoch) subsection below. Sprints `2.35` and `5.22` — the
operator-configurable certificate-scope work — join the post-`2.34` tail (`2.35` blocked by `2.34`,
`5.22` by `2.35`) without altering the Foundation Epoch framing or the
[Deployment Qualification](#deployment-qualification) ledger.

The current gateway-backed lifecycle implementation remains available only as the pre-cutover
baseline. It is scheduled for removal, not extension. The target has one retained Lifecycle
Authority identity, independent substrate-local Target Secret Agents, a minimal Bootstrap Broker,
physically separate Authority Backup/TLS Retention Adapters and fenced Provider Worker, permit-
created Credential Provisioner/External Material Ingress/Admin Action Runner Jobs, a post-export Decommission Runner, and a
mesh/DNS-only Gateway Runtime (with EKS DNS mutation disabled). Vault-root secrets and Model-B
envelope encryption remain valid;
their service ownership and runtime transport change. All earlier completed sprints remain
preserved as historical evidence for their narrower surfaces.

The following baseline facts remain current while the reopened work proceeds; entries explicitly
marked affected are retained only to name their cutover owner:

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
- **Affected current implementation:** `config setup`, `aws setup`, the native IAM harness,
  long-lived `aws-ses` stack ops, and `prodbox nuke` still acquire the ephemeral elevated credential
  directly through the interactive `SecretRef.Prompt`. The target makes `config setup` Tier-0-only,
  confines prompt ingress to a permit-selected Credential Provisioner/Admin Action Runner or the
  post-export Decommission Runner, and keeps normal Provider work on sealed generations. The
  `aws_admin_for_test_simulation.*` fixture is a test-harness-only `TestPlaintext`
  fixture in `test-secrets.dhall` whose sole purpose is to simulate that operator prompt
  non-interactively; it is never read by a production binary and never stored in
  `prodbox.dhall` or Vault.
- The current suite-level IAM harness still mints one shared operational `aws.*` identity. That
  implementation is explicitly **affected**, not part of the unaffected baseline: Sprints `3.26`,
  `4.49`, `4.50`, `7.33`, and `8.11` replace it with separate Lifecycle-provider, Authority-backup,
  TLS-retention, Gateway-DNS, per-substrate cert-manager-DNS01, and `LongLived` SES-SMTP generations, each with its own
  IAM/Vault/cleanup resource and lifecycle class. The always-run cleanup DAG removes only
  Operational generations after their dependants; LongLived home/backup/TLS/SES-SMTP generations
  and closed non-recoverable-material custody remain.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/Prerequisite.hs`, and
  `src/Prodbox/EffectInterpreter.hs` now split the aggregate prerequisite model into an initial
  fail-fast gate plus a deferred cluster-backed backend proof, so `prodbox test integration all`
  and `prodbox test all` no longer fail at `pulumi_logged_in` before the visible `cluster reconcile`
  phase has created or repaired the supported MinIO-backed Pulumi backend.
- The test-only `aws_admin_for_test_simulation.*` fixture remains the sole automation source for
  simulating the admin prompt. In the target it drives one durable setup operation: role-specific
  IAM resources are reconciled, keys are target-sealed and generation-CAS delivered, each exact
  capability is proved, and dependency-ordered revoke/tombstone nodes run on every exit. No
  pre-existing shared credential is a discovery or authorization fallback.
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
- The pre-cutover gateway runtime surface is Haskell-owned and code-backed in
  `src/Prodbox/Gateway/{Bounds,State,Orders,Peer,Continuity,ContinuityStore,DnsAuthority,ChildSchedule,Daemon}.hs`.
  Bounded Orders admission feeds finite keyed heartbeat/ownership state, signed per-emitter
  cursor/delta/repair exchange, fixed replay/checkpoint/diagnostic retention, and bounded nested
  `/v1/state` cursors. The local-emitter Model-B authority stages and re-observes the exact signed
  assertion/next anchor before publication; its Vault admission marker prevents continuity reset.
  Its remote Model-B continuity and capacity-one child path are superseded by Sprint `2.32`'s
  single-writer identity-bound emitter journal. Lifecycle, target-secret, object-store, and
  bootstrap routes leave the gateway under Sprints `2.33`/`4.50`; DNS remains gated by validated
  credential/claim/continuity evidence.
- `prodbox test integration gateway-partition` now runs as a distinct native validation path,
  while the retained peer trust-material fields are validated and bound as authoritative runtime
  transport inputs.
- `src/Prodbox/Tla.hs` still owns `prodbox dev tla-check`, while
  `documents/engineering/tla_modelling_assumptions.md` records the current runtime-to-model
  correspondence and compression points for the Phase `2` surface. Sprint `2.32` must update the
  model/correspondence before changing the continuity protocol.
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
- Root `README.md` plus governed doctrine describe the public route catalog and the target
  lifecycle-control-plane split. Sprints `1.60`, `2.31`, `3.25`, `4.47`, `5.16`, `5.17`, and
  `8.10` remain completed historical corrections; the current production-composition
  counterexample expands their owning phases through Sprints `1.61`–`8.12`.
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
- Phase `6` is reopened on Sprint `6.4` because the current aggregate demonstrated that the
  postflight restore path can skip independent local restoration after a retained-resource
  failure. It recloses only on current-revision cutover and cleanup qualification.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is the sole cleanup ledger.
  The Sprint `2.31` log/transport, Sprint `3.25` probe, Sprint `4.47` retained-lifecycle, Sprint
  `5.16` stability, Sprint `5.17` assumed-pre-existing/manual-preparation, and Sprint `8.10`
  exit-code-only SES-readiness removals remain under `Completed` as historical work. New rows own
  the arbitrary readiness action, subprocess object store, shared child queue, gateway authority,
  synchronous SES bracket, selected-target-only SMTP/EAB materialization, Pulumi-owned SMTP
  identity, fail-fast restore, and memory-only stability residue. Sprints `7.33` and `8.11` are the
  single removal owners for the custody cutover and credential-ownership migration respectively;
  prior completed rows are not revived.

### Foundation Epoch

Counterexample `LCPC-2026-07-11` froze four failure mechanisms that live at cross-artifact seams
(Haskell ↔ chart YAML ↔ kubelet, authored numbers ↔ physics, chart-lifetime storage ↔ retained
state, list position ↔ dependency structure) rather than inside one compiled program. Governance
Sprint `0.17` adopts the corrective doctrine — one typed model, many generated projections — and
registers the structural owners:

- Sprint `2.34` makes hand-authored daemon route, probe, and chart-identity literals
  unrepresentable behind one compiled route registry and chart statics, and makes readiness one
  pure latched projection that admits only after the first proven object-store round trip. 🔄
  **Active**: the compiled service boundary is landed — the closed `GatewayRoute` registry
  (`Prodbox.Gateway.Routes`) is the single source of every daemon path string, the daemon dispatcher
  is a total `case` over it, and the client and chart probe paths are projections
  (`GatewayProbeEndpoint` deleted). The latched-readiness projection and the chart-statics generated
  sections + forbidden-literal lint remain.
- Sprint `4.51` makes retained SES authority state stored through a chart-lifetime transport a
  type error via durability-indexed coordinates and adapters, with a host-direct retained store
  and idempotent operation records.
- Sprint `5.20` derives restore/cleanup edges from registered chart-dependency and
  storage-lifetime facts and replaces the fail-fast fold with a total aggregate-report executor,
  so a sibling failure can never silently discard independent restoration.
- Sprints `1.65` and `5.21` make authored Guaranteed-QoS envelopes measured rather than asserted:
  committed measured-profile artifacts certify authored CPU headroom, throttle exposure, and
  staleness inside the canonical quality gate. Sprint `1.65` ✅ **Done**: the
  `MeasuredResourceProfile` type, the CPU-headroom / memory-high-water / throttle-ppm / staleness
  certification rules, and the conformance-tier wiring land (inert until `5.21` commits the first
  profile), plus the operator-approved interim gateway 750m envelope with a vscode-quota rebalance.
- Sprints `1.64` and `1.66` remove the gateway hot-path CPU drivers (per-call TLS manager,
  per-request Vault login, subprocess object store) behind a shared manager, a cached
  single-flight Vault session, and a native SigV4 client. Both ✅ **Done**: Sprint `1.64` landed the
  shared `sharedTlsManager` singleton and the cached renewable `Prodbox.Vault.Session`
  (single-flight renewal at two-thirds TTL, sealed/revoked classification, one `403`
  invalidate-and-relogin); Sprint `1.66` landed the byte-exact `Prodbox.Aws.SigV4` and the native
  in-memory `Prodbox.Minio.ObjectStoreNative` over the shared manager, with the subprocess path kept
  as the config-selectable rollback until live-MinIO parity is proven.
- Sprint `1.63` ✅ **Done** — derives the conformance tier (`runConformanceTier`) and the
  machine-readable legacy escape registry (`src/Prodbox/Legacy/EscapeRegistry.hs`) so cross-artifact
  drift and unregistered escape call sites fail `prodbox dev check` in seconds (the Standard P
  interim escape-path guard). Eight escape seams are registered and bijectively marked in source.
- Sprint `7.34` narrows the harness postflight residue bypass back to per-run, restoring the
  long-lived aws-ses/public-edge-tls protection of the lifecycle preconditions.

The Foundation Epoch (Sprints `1.63`–`1.66`, `2.34`, `4.51`, `5.20`, `5.21`, and `7.34`) is the
active work front and is executed before Sprints `1.61` and `1.62` as an execution-priority
decision; it introduces no `Blocked by` edge onto the existing `1.61` → `8.12` chain, which
resumes unchanged once the epoch closes. The
[Deployment Qualification](#deployment-qualification) ledger is unchanged by this adoption: both
substrate rows remain **pending**, and nothing in the epoch claims qualification.

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
4. Public `prodbox config setup` authors/validates Tier-0 coordinates only. Cluster genesis and
   public `prodbox aws ...` identity paths can bootstrap all required AWS credentials from scratch
   through a mode-indexed, attested Credential Provisioner, with separate Lifecycle-provider,
   Authority-backup, TLS-retention, Gateway-DNS, per-substrate cert-manager-DNS01, and deterministic
   `LongLived` SES-SMTP IAM/Vault generations and no shared runtime key. The SES SMTP identity is
   never a Pulumi/Provider-Worker resource; the Provisioner derives its region-bound SMTP payload
   before the retained-home Agent Transit-seals it. ACME EAB uses a distinct schema-indexed External
   Material Ingress/permit and cannot reuse the bounded first-reconcile AWS-admin identity session;
   both payload kinds use closed retained-home custody/attested rewrap, never generic export.
5. `aws_admin_for_test_simulation.*` lives only in the test-harness-only `test-secrets.dhall`
   (`TestPlaintext`), never in `prodbox.dhall` or Vault, and its sole purpose is to
   simulate the operator's interactive admin-credential prompt for suite-driven credential/admin
   validation and exported-manifest `prodbox nuke`. Prompt bytes enter only the attested
   permit-selected Credential Provisioner/Admin Action Runner or, after Authority permanent stop,
   the manifest-constrained Decommission Runner; `config setup`, normal provider work, and
   long-lived controllers never receive them. There is no production config-backed admin path.
6. `prodbox test integration aws-iam`, targeted
   `prodbox test integration <name> --substrate aws` validations,
   `prodbox test integration all`, and `prodbox test all` share one joint idempotent IAM
   validation harness that submits the same durable setup operation as the public flow, seals and
   generation-CAS delivers each role-specific key, proves every exact identity/capability pairing,
   registers cleanup before mutation, destroys validation-owned per-run/Operational resources, and
   deletes each such IAM/key resource before committing its Vault tombstone. No pre-existing shared
   credential is a discovery or authorization fallback; LongLived backup/TLS/home-DNS/SES-SMTP
   identities and closed custody receipts are instead proven retained and readable by only their
   exact consumer.
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
32. Two consecutive strongest clean-room reruns pass on each supported substrate from destructive
    setup through final cleanup using the Haskell stack and the exact authored resource envelopes.
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
36. The home-substrate gateway daemon emits signed `Claim` and `Yield` evidence on owner
    transitions and gates its registered home Route 53 A-record writes on a credential-ready
    runtime equivalent of the modelled `CanWriteDns`
    predicate, so `ClaimPrecedesWrite` and `YieldPrecedesReclaim` hold on the bounded semantic
    event projection rather than only on the model, ambient AWS authentication cannot create write
    authority, and a stale owner cannot reclaim without observing its yield superseded by a fresh
    claim. The EKS Gateway DNS mutation capability is disabled; the AWS A record is owned by the
    exact Lifecycle Authority provider intent required by item 51.
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
39. Invite-capable suite plans submit an idempotent durable operation to the retained Lifecycle
    Authority. Provider mutation, exact-revision semantic readiness, SMTP generation, and
    per-target delivery are journaled and resumable; only mutation stages hold narrow fences, and
    target delivery proceeds through the selected substrate's Target Secret Agent outbox. Pulumi
    owns only non-credential SES resources. The deterministic `LongLived` SMTP identity belongs to
    the `OperatorMaterialPermit`-selected Credential Provisioner, and retained-home schema-bound
    custody restores the same generation into a fresh AWS Vault without prompt or key rotation.
40. Runtime stability is proved by a run-wide temporal fold over restart/OOM/memory, CPU
    throttling, queue occupancy/wait, admission refusal, p95/p99 operation latency, cancellation,
    and deadline-miss evidence. Point readiness never erases an earlier unhealthy observation.
41. Bootstrap Broker, Lifecycle Authority, Target Secret Agent, Gateway Runtime, Authority Backup
    Adapter, TLS Retention Adapter, and fenced Provider Worker are physically separate workloads
    with distinct identities, policies, Services, resource envelopes, queues, and failure domains.
    Credential Provisioner/External Material Ingress/Admin Action Runner Jobs are mode/schema/permit
    isolated, the bounded first-reconcile AWS-admin session covers identity permits only, and the
    Decommission Runner exists only after Authority export and stop.
42. The component graph requires operation-indexed capabilities. Observation, admission, and
    execution use the same opaque reference; no arbitrary injected `IO` action or differently supplied
    endpoint can satisfy a dependency edge.
43. Every supported control-plane request carries one absolute deadline across queueing,
    credential refresh, external I/O, read-back, cancellation, and response. Saturation refuses
    immediately and retries never extend that deadline.
44. Each gateway emitter has one actor and one encrypted identity-bound retained journal. The actor
    owns the complete stage/fsync/publish/commit/fsync transition; no competing continuity loop or
    shared lifecycle queue can interleave it.
45. The suite registers cleanup before mutation and interprets an always-run cleanup DAG. Sibling
    failure cannot skip independent local restoration, per-run AWS/EBS cleanup, authority
    resolution, or residue observation; the report retains the primary and every cleanup failure.
46. Authority cutover uses a versioned epoch and exactly one logical writer. Old routes, adapters,
    and host-direct fallback stay Pending Removal until the replacement is the sole supported path
    and rollback is a forward migration to a greater epoch.
47. The Deployment Qualification table is `proven` for the exact current secret-safe
    `SourceIdentity` and generated-config identity on both substrates, including the recorded and
    hashed source-manifest exclusion-policy/version and the required load/fault/cancellation/
    response-loss and cleanup campaign. Historical runs or pending live evidence cannot satisfy
    this exit condition.
48. `LCPC-2026-07-11` retains the frozen expected superseded-composition failure and replacement
    pass under identical topology-normalized total budget/load, plus the replacement's separate
    production-envelope profile, with separate complete source/config/image/wiring identities and
    evidence digests. Public evidence contains only opaque Authority receipt/generation IDs or
    Vault-keyed HMAC commitments for secret-dependent inputs; it never hashes plaintext secrets.
49. Lifecycle Authority alone owns the in-force config generation/reference; every component uses a
    role-scoped projection, and no host/Gateway/direct-MinIO config path remains.
50. Lifecycle-provider, Authority-backup, TLS-retention, Gateway-DNS, per-substrate
    cert-manager-DNS01, and SES-SMTP identities are distinct IAM/Vault generations with no shared key
    or cross-role fallback. Operational Lifecycle-provider/AWS-run DNS01 identities follow dependency
    cleanup; LongLived SES-SMTP is retained by ordinary postflight and removed only by
    `DestroyAwsSes`/the equivalent nuke node after consumers quiesce and the Provider Worker reads
    back provider-stack absence. The Admin Action Runner deletes/reads back external IAM before live
    Agents tombstone target generations and retained-
    home custody, with all failures aggregated. LongLived backup is deleted only by external-receipt
    `nuke`; TLS-retention and home Gateway-DNS/home-DNS01 may also leave through explicit consumer
    decommission after their exact dependants are absent. In `nuke`, every consumer/prefix is absent
    and the shared bucket is last.
51. Every prodbox-created Route 53 record is registered by exact account/zone/name/type/owner epoch
    and has typed observe/ensure/delete/read-back through its sole owner.
52. Root and child Vault initialization encrypts the initial root token to a pinned/audited burn
    public key whose private key is never generated, stored, accepted, or available to prodbox and
    has no known holder; prodbox never decrypts or uses the initial token. Encrypted recovery-share receipts are durably acknowledged before
    baseline; separately generated short-lived root sessions are inventoried by non-secret
    accessor, revoked after read-back, and observed absent. No usable initial token or plaintext
    recovery share appears in unlock-bundle token fields, parent custody, config, authority state,
    logs, or fixtures.
