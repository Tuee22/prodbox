# Phase 5: Canonical Test Suite

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[substrates.md](substrates.md),
[the engineering doctrine docs](../documents/engineering/README.md),
[vault_doctrine.md](../documents/engineering/vault_doctrine.md),
[test_topology_doctrine.md](../documents/engineering/test_topology_doctrine.md),
[resource_scaling_doctrine.md](../documents/engineering/resource_scaling_doctrine.md),
[bootstrap_readiness_doctrine.md](../documents/engineering/bootstrap_readiness_doctrine.md),
[distributed_gateway_architecture.md](../documents/engineering/distributed_gateway_architecture.md),
[lifecycle_control_plane_architecture.md](../documents/engineering/lifecycle_control_plane_architecture.md),
[unit_testing_policy.md](../documents/engineering/unit_testing_policy.md)
**Generated sections**: none

> **Purpose**: Own the substrate-agnostic canonical test suite — the named-validation set in
> `src/Prodbox/TestValidation.hs` — as suite content with declared prerequisites. Substrate
> provision and teardown belong elsewhere (see [substrates.md](substrates.md) and the
> substrate-owning phase docs); this phase owns what the suite proves and how.

## Phase Status

📋 **Expanded 2026-07-12 for the Foundation Epoch.** Counterexample `LCPC-2026-07-11` froze four
aggregate-suite failure mechanisms; this phase gains the two suite-side structural owners, adopted
by governance Sprint `0.17` ([phase-0-planning-documentation.md](phase-0-planning-documentation.md)).
Sprint `5.20` (📋 Planned) closes the `F-RESTORE` class: restore/cleanup becomes a graph whose
`RequiresSuccess`/`RequiresAttempt` edges are derived from chart-dependency and storage-lifetime
fact tables, executed by a total executor that aggregates every failure and never silently discards
an independent restoration. Sprint `5.21` (⏸️ Blocked by Sprint `1.65`) closes the measurement
loop: a `--record-profile` mode of the gateway-runtime-stability suite writes the committed
`MeasuredResourceProfile` artifact from a healthy run, and the first committed gateway profile
activates the Sprint `1.65` certification check. The Foundation Epoch (Sprints `1.63`–`1.66`,
`2.34`, `4.51`, `5.20`, `5.21`, and `7.34`) is the active work front and is executed before Sprints
`1.61` and `1.62` as an execution-priority decision; it introduces no `Blocked by` edge onto the
existing `1.61` → `8.12` chain, which resumes unchanged once the epoch closes. Sprints
`5.18`/`5.19` remain blocked exactly as recorded below.

⏸️ **Certificate-scope serving validation added 2026-07-12.** Sprint `5.22` (⏸️ Blocked by
Sprint `2.35`) adds a named integration validation that proves serving rather than assertion — a real
TLS handshake against every hostname the configured `CertScopeSet` covers (each exact scope and, when
a wildcard scope is configured, a wildcard-covered sibling plus the apex through its explicit exact
scope), against harness-owned infrastructure with a real ZeroSSL DNS-01 certificate, plus a retained
restore-vs-reissue proof (widening orders once; narrower-or-equal reuses). It is the canonical-suite
consumer of the configurable-certificate-scope policy adopted by governance Sprint `0.18`
([phase-0-planning-documentation.md](phase-0-planning-documentation.md)) and the scope algebra owned
by Sprint `2.35` ([phase-2-gateway-dns.md](phase-2-gateway-dns.md)); it is not part of the Foundation
Epoch and introduces no `Blocked by` edge onto the existing `1.61` → `8.12` chain.

⏸️ **Reopened and blocked by Sprint `4.50`.** Sprint `5.18` makes restore and retained
preparation consume the same exact capability references that execution uses and lowers cleanup to an
always-run DAG, so an unrelated selected-target probe cannot authorize retained-authority work and
one failure cannot skip independent restoration. Sprint `5.19`, blocked by `5.18`, adds temporal
load/fault evidence for CPU throttling, admission queues, deadlines, cancellation, and cleanup.
Earlier point-readiness and restart/OOM evidence remains useful but is not the expanded temporal
qualification.

✅ **Reclosed 2026-07-10 after retained-resource preparation.** Sprint `5.16` supplies the typed
restart/OOM/high-water stability oracle and run-scoped restore recorder. Sprint `5.17` now derives
one opaque nested retained-SES plan solely from invite capability, carries the selected target's
typed gateway object-store precondition and exact transaction trace, and invokes Sprint `4.47`'s
registered ensure exactly once against separate retained authority and target-sink coordinates.
Home and AWS projections select only their own target, non-invite and postflight plans contain no
SES mutation, deferred prerequisites stay read-only, and ordinary cleanup never destroys
`aws-ses`. Sprint `8.10` has since landed the complete semantic classifier in its Phase-`8` owner;
that later strengthening does not retroactively block this phase under Standards N/O. Previous
named-validation, restore-DRY, and prerequisite closures remain valid.

✅ **Reclosed 2026-07-10 after restore-cycle DRY and daemon-liveness closure.** Sprint `5.15`
expands Phase `5`'s **own** TestRunner restore-orchestration surface
([Standard A/N](development_plan_standards.md#n-phase-independence-no-backward-blocking)) and is Done.
`Prodbox.TestRestore` now owns the typed, substrate-aware `RestoreCyclePlan` and its one canonical
step sequence. `supportedRuntimeBootstrapActions` and `supportedRuntimePostflightActions` both
project that builder through one exhaustive TestRunner interpreter; their only permitted sequence
difference is the optional bootstrap SMTP step. Before SMTP mutation,
`syncKeycloakSmtpForSupportedRuntime` checks a `ComponentGatewayDaemonFull`/MinIO
backend-readiness precondition that polls the exported one-shot gateway object-store observer with
the bounded Sprint-`1.59` poller. Pending and unreachable observations fail closed as a
`StructuredError` naming the loopback NodePort, and no SMTP sync starts. Validation is green at
unit 1280/1280 and `prodbox dev check` exit 0. The targeted `resource-guardrails` built-frontend CLI
fixture also passes under fake gateway readiness as a general CLI regression check. That named plan
does not run either supported-runtime restore projection or select the optional SMTP step, so it is
not an end-to-end proof of either the shared restore interpreter or the SMTP gate. A live home
`prodbox test all` restore remains a non-blocking Standard-O proof. Sprint `7.32` subsequently
adopted the same builder for the explicit AWS projection. All earlier Phase `5` closures remain
valid.

✅ **Reclosed 2026-07-05 for daemon-mediated bootstrap validation.** Sprint `5.14` is Done on the
code-owned canonical-suite surface. The new `daemon-bootstrap` validation is wired through the
parser, command registry, native validation plan, topology mapping, and aggregate ordering; its pure
transport oracle requires the daemon bootstrap/lifecycle routes, rejects observed legacy MinIO
port-forwards, direct host Vault NodePort calls, and host root-token fallback traces, and proves
request/response/log redaction. Built-frontend integration covers both the passing trace and a
legacy-transport failure trace. AWS/Pulumi object-store parity remains a forward Phase `7` live-proof
axis tracked through Sprint `7.30`, never a backward block on this phase.

✅ **Reclosed 2026-07-04 for resource-guardrail validation** — Sprint `5.13` is Done on the
code-owned canonical-suite surface. The new `resource-guardrails` validation is wired through the
parser, command registry, native validation plan, topology mapping, and aggregate ordering; it loads
the validated `capacity.resource_plan`, checks live Kubernetes pod, `ResourceQuota`, and
`LimitRange` JSON, refuses `BestEffort` or uncapped containers, and proves guardrail objects match
the declared plan for the root chart namespaces. This is suite content and remains
substrate-agnostic; AWS coverage is tracked through the normal substrate parity table. The optional
real over-limit pod stress proof remains a non-blocking `Live-proof: pending` axis per Standard O.

✅ **Live-proven 2026-06-26 — the then-current canonical suite ran fully green on the home substrate.** A full home
`prodbox test all` (2026-06-26) passed 18/18 named validations end-to-end — including `sealed-vault`
(Sprint `5.8`) and the destructive `lifecycle` ordering — with `prodbox-unit` 1062/1062 and
`prodbox-integration` 39/39 (see [00-overview.md](00-overview.md) Alignment Status). Sprint `5.10`
(harness-generated run config from `test-secrets.dhall`) is exercised by the run: the harness
regenerates the binary-sibling `prodbox.dhall` through the shared `configFromSetupInput` builder,
populating `route53.zone_id` / `ses.*` / `pulumi_state_backend.*` from `test-secrets.dhall` and
force-syncing the in-force SSoT, so the suite reaches every downstream validation non-interactively.
The suite's home-substrate content is thereby live-proven (Standard O); the `--substrate aws` per-run
half of the canonical suite remains the distinct, non-blocking axis tracked in
[substrates.md](substrates.md).

✅ **Closed on its code-owned surface 2026-06-16** — reopened 2026-06-11, finalized 2026-06-14,
refined 2026-06-15 (Vault-root + cluster
federation; Model-B whole-system zero-child-info refinement), reopened 2026-06-16 to adopt the
phase-independence doctrine (Sprint `0.15`;
[development_plan_standards.md → N. Phase Independence / O. Code-Local vs Live-Infra Proof](development_plan_standards.md#n-phase-independence-no-backward-blocking)) —
Sprint `5.8`
reframes to the finalized end state: the `sealed-vault` canonical validation seals Vault and asserts
the whole stack fails closed (no secret resolves, no cert issues, no MinIO object decrypts, no
Pulumi op runs, gateway daemon and Keycloak fail their readiness gates) without leaking metadata.
It now **also** covers the retired master-seed derivation surface — there is no `master-seed` object
and no daemon `/v1/secret/*` RPC to fall back to, so the sealed stack cannot reconstruct a secret
from any non-Vault source — and the cluster-federation auto-unseal cascade, where a sealed or
unreachable parent Vault bricks its children (the fail-closed brick cascades down the transit-seal
trust tree from the root). The 2026-06-15 refinement (Model B + whole-system zero-child-info; see the
2026-06-15 Closure Status in [README.md](README.md) and
[vault_doctrine.md §9/§10](../documents/engineering/vault_doctrine.md)) adds the
**cross-surface sealed-Vault red-team** to `5.8`: with the parent Vault sealed, a combined
bucket-level `aws s3api ls` + `list-objects` against the one generically-named bucket, a host-disk
walk of `.data/prodbox/minio/0`, a Kubernetes ConfigMap/Secret dump, and a log/output audit together
reveal only opaque `objects/<hmac>.enc` at a constant decoy-padded count — no role-revealing bucket
name, no `aws-eks`/stack-name object key, no cleartext body, no child-named namespace, and no
exists-vs-absent (`NoSuchKey`) oracle. The SecretRef golden tests prove generated Dhall/config artifacts carry
only `SecretRef.Vault` / `SecretRef.TransitKey` values on the `FileSecret`-free union — there is no
`SecretRefFile` constructor to render — per
[vault_doctrine.md](../documents/engineering/vault_doctrine.md) and
[cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md). Sprint
`5.8` is ✅ Done on its code-owned/home-substrate surface: the named `sealed-vault` validation, planner
surface, parser/docs surface, pure sealed-state forbidden-pattern audit helper, generated
Dhall/config SecretRef sweep, and live home-substrate proof have landed and validate locally.
Existing validations are
unchanged and the new sealed-Vault suite content extends them. The live AWS-substrate cross-surface
red-team and the live parent/child federation auto-unseal cascade are tracked as a non-blocking
**Live-proof: pending** note on Sprint `5.8` (Standards N/O); the later Model-B raw-Pulumi-checkpoint
interposition that the AWS-substrate proof composes against is owned by Sprint `7.14` as a forward
build dependency, and AWS-substrate coverage of the same validation is tracked in
[substrates.md](substrates.md) (Standard M) — neither gates `5.8`'s code-owned closure or this phase.
See the 2026-06-14 and
2026-06-16 Closure Status entries in
[README.md](README.md).

✅ **Prior closure preserved — reclosed 2026-06-09** — Sprints `5.1`–`5.5` remain closed on the
canonical-suite content that proves public-host behavior (the public-edge diagnostic, named external
proofs, shared-host route classification, admin-route auth/RBAC proofs, and the port-80
HTTP-to-HTTPS redirect proof). The 2026-06-09 design-intention review reopened this phase for Sprint
`5.6`, which has now landed: the prerequisite surface that gates the canonical suite is typed
(`PrerequisiteId` ADT) and minimal-and-precise per validation; the IAM-harness tier is derived from
each validation's declared capabilities (the `normalizeManagedAwsHarness` `substrate=aws` blanket
override deleted; a credential-free validation on AWS engages no harness); `infra_ready` was split
from a new AWS-credential-free `public_edge_ready` node (re-pointing `charts-*`); `verifyAwsEksSnapshot`
was strengthened to a structured parse; and the three registry-generated destructive `--dry-run`
goldens (`rke2 delete`, `rke2 delete --cascade`, `nuke`) landed with drift-guard tests (closing
audit V80). Validation at reclosure: `check-code` 0, `test unit` 809, `integration cli` 35,
`integration env` 35, `lint docs` 0, `docs check` 0. The live AWS-substrate aggregate +
public-edge-readiness exercises are operator-driven.

Per [development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates),
these validations are **suite content**, not home-substrate-only validations. The home local
substrate runs them today on real `test.resolvefintech.com` infrastructure (real ZeroSSL,
real OIDC, real WebSocket fan-out). Bringing the AWS substrate to parity so it runs the same
validations is tracked in [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md).

Per [development_plan_standards.md](development_plan_standards.md) standards rule E, Phase `6` (the
clean-room handoff) stays ✅ Done on its owned surface, while the overall handoff still depends on
the separately reopened implementation phases `3`–`5`, `7`, and `8`. Phases `1` and `2` have
reclosed their finalized Vault-root + cluster-federation foundations.

✅ **Sprint `5.12` closed on its code-owned surface 2026-07-03** — the unified block-storage
rebinding validation is now canonical-suite content. `prodbox test integration eks-volume-rebind`
maps to `IntegrationEksVolumeRebind` / `ValidationEksVolumeRebind`, writes a sentinel through the
retained MinIO workload PV, drives a teardown/spinup cycle, and compares Kubernetes PV snapshots so
the same PV/PVC stays `Bound`, the sentinel survives, and any EBS `volumeHandle` remains identical
when present. The home-substrate run is cluster-only; the AWS-substrate run explicitly engages the
IAM harness and remains the non-blocking parity proof for the Sprint `7.28` static retained-EBS PV
path, tracked in [substrates.md](substrates.md). Earlier Phase 5 sprints remain `Done`/as-tracked.

✅ **Sprint `5.11` closed on its code-owned surface 2026-07-03** — the test-topology command
surface is now implemented: `prodbox test init` writes the executable-sibling
`prodbox.test.dhall` and refuses overwrite without `--force`; `prodbox test run <suite>|all`
loads that authored topology, writes one disposable binary-sibling `prodbox.dhall` per variant
through the shared Tier-0/config builder path, points `storage.manual_pv_host_root` at
`.test-data/<case>/`, passes that root to the native validation environment, runs the existing
deploy/assert path, and removes the generated config plus this run's `.test-data` root in
`finally`. `guardTestDelete` now admits only the generated config under `.build`, paths proven
under `.test-data`, and `LifecycleClass PerRun` residue; long-lived resources and production data
refuse. The sealed-Vault host-disk audit resolves the same test root through the topology-run
environment. Live multi-variant cluster proof remains a non-blocking live-infra axis.

## Phase Summary

This phase owns the canonical test suite as substrate-agnostic content. Each validation in
`src/Prodbox/TestValidation.hs` is a member of one suite, planned by `src/Prodbox/TestPlan.hs`
(as `NativeValidation` variants), gated by prerequisites declared in
`src/Prodbox/Prerequisite.hs`, and orchestrated by `src/Prodbox/TestRunner.hs`. The same
validation runs against every substrate that satisfies its declared prerequisites; what differs
between substrates is provision and teardown, not the validation itself.

The suite content owned by this phase covers public DNS delegation, real TLS issuance via
cert-manager and ZeroSSL, Envoy Gateway readiness, shared-host application routing
(`/auth`, `/vscode`, `/api`, `/ws`), shared-host admin routing (`/minio`), HTTP-to-HTTPS
redirect on port `80`, Keycloak issuer alignment behind Envoy, route-level RBAC, real WebSocket
upgrade behavior, one-connection-per-pod lifetime, revocation-driven reconnect, and
readiness-based drain.

Sprints `5.1`–`5.4` historically owned the diagnostic plus the shared-host application and admin
proofs. They are preserved below as historical records of when each validation entered the suite.

## Canonical Suite Inventory

`src/Prodbox/TestPlan.hs::canonicalNativeValidations` is the authoritative membership list. This
table describes that code-owned set; it does not maintain a separate substrate-status ledger.

| Validation | Prerequisites (excerpt) | What it proves |
|------------|-------------------------|----------------|
| `charts-vscode` | public edge, curl | HTTPS browser/OIDC route behavior for VS Code |
| `charts-api` | public edge, curl | bearer-token validation and the API 401/403 contract |
| `charts-websocket` | public edge, curl | WebSocket upgrade, broadcast, revocation reconnect, and readiness drain |
| `admin-routes` | public edge, curl | MinIO console auth and RBAC on the shared public edge; the registry has no web UI |
| `public-dns` | Route 53 lifecycle, dig | registrar delegation and configured-FQDN resolution |
| `dns-aws` | Route 53 lifecycle | ephemeral hosted-zone and record lifecycle correctness |
| `aws-iam` | IAM harness, AWS CLI | operational IAM credential provisioning and cleanup |
| `aws-eks` | AWS, cluster, Pulumi | the `aws-eks` substrate stack and typed outputs |
| `pulumi` | AWS, cluster, Pulumi | the `aws-test` stack and typed outputs |
| `ha-rke2-aws` | AWS, cluster, Pulumi, SSH | reachability and stale-instance repair for the three-node test stack |
| `gateway-daemon` | cluster, curl | local daemon health/readiness/metrics and bounded drain |
| `gateway-pods` | cluster | in-cluster gateway pod readiness and log sanity |
| `gateway-partition` | in process | ownership/claim/yield behavior and duplicate rejection on the current representation |
| `charts-platform` | cluster | supported chart registry/status and platform behavior |
| `resource-guardrails` | cluster | declared pod resources, quotas/limits, and pre-mutation over-budget refusal |
| `daemon-bootstrap` | in-process oracle | supported daemon-mediated bootstrap/object-store transport and redaction |
| `pulsar-broker` | cluster | native-protocol Pulsar produce/consume/ack behavior |
| `keycloak-invite` | public edge, curl, AWS, Route 53; capability-derived retained-SES preparation; deferred semantic SES observations | Invite, capture, link-follow, credential setup, and OIDC login. Sprint `5.17` supplies desired-present preparation; landed Sprint `8.10` supplies exact sender/DKIM, MX/rule, and operational capture-canary list/get readiness. |
| `charts-storage` | cluster | retained-storage pairing and chart storage behavior |
| `eks-volume-rebind` | cluster | identical retained-volume rebinding and sentinel continuity |
| `sealed-vault` | cluster | sealed-state fail-closed behavior and the cross-surface opacity audit |
| `lifecycle` | cluster | `cluster delete --yes` → `cluster reconcile` → `cluster health` round trip |

Prerequisites are the typed `PrerequisiteId` values in
`src/Prodbox/TestPlan.hs::validationInitialPrerequisites` and
`validationDeferredPrerequisites`. They are read-only gates. Sprint `5.17` has moved retained-SES
mutation into a visible capability-derived preparation action before deferred observation; it does
not hide creation inside a prerequisite. Sprint `8.10` now routes those observations through
`Prodbox.Ses.Readiness`: typed command results fold to `Ready`, bounded propagation `Pending`,
terminal `Failed`, or `Unobservable`, and only `Ready` opens the gate.

## Substrate Independence

Suite content does not name a substrate. It names prerequisites that any substrate must satisfy
to run the validation. When the AWS substrate stands up real DNS, cert-manager, ingress, and
the chart set (tracked in [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md)),
the same `charts-vscode`, `charts-api`, `charts-websocket`, `public-dns`, and `admin-routes`
validations run against it without modification, behind the same declared `public_edge_ready`
prerequisite node (see the inventory note above; Sprint `5.6` promoted this from a procedural gate
to a declared, AWS-credential-free node).

**"Substrate-agnostic" does not mean substrates share defaults.** Each per-substrate run is
locked to one substrate, consumes only that substrate's required config and provisioned
infrastructure, and fails fast when any required field is missing — there is no silent
fallback to the other substrate's values. A complete canonical-suite proof requires both
substrate runs to land independently; running on a single substrate covers only that
substrate's parity row. See
[development_plan_standards.md → M. Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback)
for the authoritative doctrine and
[substrates.md](substrates.md#substrate-independence-no-fallback) for the substrate-side
contract.

Current per-substrate live evidence and every open parity axis are tracked only in
[substrates.md](substrates.md). This suite-content phase does not duplicate that changing status.

## Current Baseline In Worktree

- `src/Prodbox/TestPlan.hs` owns the `NativeValidation` ADT, canonical membership, typed
  prerequisite projection, and aggregate/named plans; `src/Prodbox/TestValidation.hs` owns native
  validation execution.
- `src/Prodbox/TestRunner.hs` interprets phase-bannered prerequisite, preparation, bootstrap,
  validation, restore, and finally-guaranteed cleanup plans. `Prodbox.TestRestore` owns the shared
  substrate-aware restore-cycle plan.
- `prodbox edge status` is the public readiness diagnostic consumed by external-proof setup. The
  validation set remains substrate-agnostic; provisioning and current live parity are owned only by
  [substrates.md](substrates.md).
- `gateway-pods` feeds a structured, continuously sampled Pod/Event/metrics observer into one
  run-scoped absorbing restart/OOM/failure-high-water/unobservable fold. Planned rollouts pause and
  drain the observer while the gateway is intentionally absent and reset only the separate
  three-sample healthy window; they never clear absorbed evidence.
- Invite-capable setup derives exactly one nested retained-SES preparation plan from the selected
  validation set. Its explicit target gateway object-store precondition precedes one registered
  Phase-`4.47` ensure whose visible trace is acquire/reconcile/bounded provider-presence
  await/target sync/release; non-invite and ordinary postflight plans contain no SES mutation.
- The current public edge exposes HTTPS application routes on port `443`, redirect-only HTTP on
  port `80`, and the MinIO console administrative route. The in-cluster registry has no public UI
  route; backend TLS/mTLS remains outside this chart-workload contract.

## Sprint 5.1: Public Hostname Closure and External Proof on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the implemented public DNS and public-edge path on the Haskell runtime that owns it.

### Deliverables

- `prodbox edge status` is implemented in Haskell and preserves the supported diagnostic
  classification contract.
- Public DNS delegation, live HTTPS reachability, TLS issuance, and auth redirects are proven
  through Haskell-owned command surfaces.
- The external proof path remains cluster-external and does not depend on manual kubeconfig
  workflows.
- Wildcard public DNS remains unsupported.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox edge status`
4. `prodbox test integration charts-vscode`
5. `prodbox test integration public-dns`

### Current Validation State

- `src/Prodbox/Host.hs` now owns the public `prodbox edge status` surface and preserves the
  supported readiness-report fields and classification contract.
- `src/Prodbox/TestRunner.hs` now uses the native Haskell `edge status` command directly
  inside the supported-runtime bootstrap and postflight checks.
- `test/unit/Main.hs` proves parser routing for native `edge status`.
- The named validation commands `prodbox test integration charts-vscode` and
  `prodbox test integration public-dns` now run executable native Haskell validation flows via
  `src/Prodbox/TestValidation.hs`.
- Environment-dependent public-edge success remains owned by those commands rather than asserted
  here as a fresh run result.

### Remaining Work

None.

## Sprint 5.2: Gateway API Public-Edge Diagnostics and External Proof ✅

**Status**: Done
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep public-edge readiness on Gateway API and Envoy Gateway diagnostics with explicit Route 53
proof and external-only validation.

### Deliverables

- `prodbox edge status` classifies Route 53, `Gateway`, `HTTPRoute`, certificate, and
  external-proof readiness on the self-managed public edge.
- The public `charts-vscode` and `public-dns` proofs close on Envoy-authenticated browser delivery
  rather than the retired `vscode-nginx` path.
- Public-edge validation remains cluster-external and does not depend on `/etc/hosts` shortcuts or
  manual kubeconfig-only verification.
- Wildcard public DNS remains unsupported.
- Additional API and WebSocket shared-host proof surfaces close in Sprint `5.3`.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox edge status`
4. `prodbox test integration charts-vscode`
5. `prodbox test integration public-dns`
6. Classification proof: the ready state is derived from Gateway API and Envoy Gateway state rather
   than `IngressClass` or `Ingress`

### Current Validation State

- `src/Prodbox/Host.hs` now classifies the public edge through Route 53 record sync, Envoy Gateway
  deployment readiness, `GatewayClass` acceptance, `Gateway` readiness, `HTTPRoute` attachment,
  `SecurityPolicy` attachment, certificate readiness, and `LoadBalancer` IP agreement.
- `src/Prodbox/TestValidation.hs` now waits for `CLASSIFICATION=ready-for-external-proof`, proves
  the external `vscode` path through the Envoy-to-Keycloak redirect, and validates every
  configured public-edge hostname through Route 53 plus public DNS resolution.
- `test/unit/Main.hs` and the built-frontend suites now align the public-edge fixtures with the
  Gateway API baseline that later single-host work refines.
- The current named public-edge proof surface now extends beyond the current Keycloak identity
  route and `vscode` browser route to the API and WebSocket validations owned by Sprint `5.3`.

### Remaining Work

None.

## Sprint 5.3: API and WebSocket Public-Edge Proof ✅

**Status**: Done
**Superseded surface note**: This block records the historical Harbor-plus-MinIO proof. The July
2026 `registry:2` replacement removed Harbor's UI and public route; current `admin-routes` proves
the MinIO console only, as listed in the canonical inventory above.
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Extend the Haskell-owned diagnostic and external proof surface to the shared-host doctrine on
`test.resolvefintech.com`, covering browser, API,
WebSocket, and Keycloak paths on one public edge.

### Deliverables

- `prodbox edge status` classifies shared-host browser, API, WebSocket, and Keycloak paths on
  the supported Envoy Gateway edge.
- The public-edge diagnostic reports the active MetalLB advertisement mode and preserves the
  existing Route 53, certificate, and readiness classification contract on one public hostname.
- Named external validations prove the supported API route on the explicit request-token and
  local-JWKS doctrine, and prove the supported WebSocket route in addition to the existing
  `charts-vscode` and `public-dns` browser or DNS proof surfaces.
- Named external validations prove the supported Keycloak public-host contract, including
  issuer and redirect alignment on the shared hostname, forwarded-header compatibility, and no
  accidental public management or health route exposure.
- Named external validations prove the supported WebSocket connection-lifetime contract, including
  one upgraded connection per selected backend pod until disconnect and readiness-based drain
  before pod exit through the runtime surface owned by Sprint `3.6`.
- Public-edge validation remains cluster-external and does not depend on `/etc/hosts` shortcuts or
  manual kubeconfig-only verification.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox edge status`
4. `prodbox test integration charts-vscode`
5. `prodbox test integration charts-api`
6. `prodbox test integration charts-websocket`
7. `prodbox test integration public-dns`
8. Classification proof: the readiness payload covers the full shared-host route set and the
   configured advertisement mode without falling back to `Ingress` assumptions
9. Behavioral proof: the WebSocket validation uses the real upgrade path, proves the
   one-upgraded-connection-per-backend-pod lifetime until disconnect, and checks readiness-based
   drain rather than only HTTP helper endpoints on that route
10. Identity proof: Keycloak-backed public workloads use the shared hostname for issuer and
    redirect flows, the browser auth path stays on explicit redirect and cookie assumptions, and
    unsupported management or health paths are not publicly routed

### Current Validation State

- `src/Prodbox/Host.hs` now classifies the shared-host identity, browser, API, and WebSocket
  routes, reports the active MetalLB advertisement mode, and proves per-route `SecurityPolicy`
  attachment through the canonical route catalog.
- `src/Prodbox/TestValidation.hs` now proves the browser redirect path, JWT-protected API
  rejection and acceptance on the request-carried JWT path, the shared-host Keycloak redirect and
  issuer contract, workload-managed direct-OIDC session ownership on the WebSocket route, real
  WebSocket upgrade behavior, and Route 53 resolution for the canonical public hostname.
- `prodbox dev check`, `prodbox test unit`, `prodbox test integration cli`, and
  `prodbox test integration env` remain aligned with the expanded shared-host public-edge proof
  surface.
- The canonical proof surface for `charts-api`, `charts-websocket`, `public-dns`, and
  `edge status` now closes on the shared-host doctrine.

### Remaining Work

None.

## Sprint 5.4: Shared-Host Admin-Route Proof ✅

**Status**: Done
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Prove that the supported operational dashboards, Harbor and MinIO, are reachable only through
Envoy on `test.resolvefintech.com`, protected by Keycloak-backed auth and RBAC.

### Deliverables

- `prodbox edge status` classifies the supported Harbor and MinIO admin paths on the shared
  hostname.
- Named external validations prove auth and RBAC on the supported admin routes.
- The external proof surface preserves the one-DNS or one-cert doctrine as admin coverage grows.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox edge status`
4. `prodbox test integration public-dns`
5. `prodbox test integration admin-routes`

### Current Validation State

- `src/Prodbox/Host.hs` now classifies Harbor and MinIO as shared-host admin routes on the
  canonical public hostname.
- `src/Prodbox/TestValidation.hs` now proves Harbor and MinIO auth redirects and callback routing
  through the shared-host admin edge.
- `src/Prodbox/TestPlan.hs` exposes `admin-routes` as the named external validation surface for
  the supported admin catalog.

### Remaining Work

None.

## Sprint 5.5: Public HTTP Redirect to HTTPS ✅

**Status**: Done
**Implementation**: `charts/keycloak/templates/gateway.yaml`, `src/Prodbox/Host.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Make the public edge listen on port `80` only to redirect clients to the canonical HTTPS URL for
the same shared-host path.

### Deliverables

- The shared `public-edge` Gateway renders an HTTP listener on port `80` in addition to the
  existing HTTPS listener on port `443`.
- The port `80` listener attaches only to redirect routes and never forwards plaintext HTTP traffic
  to Keycloak, workloads, Harbor, or MinIO.
- HTTP requests for `test.resolvefintech.com/<service-path>` receive a permanent redirect to
  `https://test.resolvefintech.com/<service-path>`.
- `prodbox edge status` reports the HTTP redirect listener and distinguishes redirect
  readiness from HTTPS application-route readiness.
- The named public-host validations prove both the redirect behavior on port `80` and the existing
  HTTPS route, certificate, auth, and RBAC behavior on port `443`.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox edge status`
4. `prodbox test integration public-dns`
5. `prodbox test integration charts-vscode`
6. `prodbox test integration charts-api`
7. `prodbox test integration charts-websocket`
8. `prodbox test integration admin-routes`
9. External proof: `http://test.resolvefintech.com/<service-path>` returns a permanent redirect to
   `https://test.resolvefintech.com/<service-path>` without exposing any plaintext backend route.

### Current Validation State

- The Gateway API HTTP listener and redirect-only `HTTPRoute` now render from the Keycloak chart.
- `prodbox edge status` now reports Envoy service port readiness, HTTP redirect listener
  readiness, HTTPS listener readiness, and redirect `HTTPRoute` acceptance.
- `src/Prodbox/TestValidation.hs` now proves the port `80` redirect before the `charts-vscode`
  HTTPS proof and after the `public-dns` record proof.
- On May 13, 2026, `./.build/prodbox test all` deployed the chart changes into the supported
  runtime, proved `ENVOY_SERVICE_HTTP_PORT_READY=true`,
  `HTTP_REDIRECT_LISTENER_READY=true`, `HTTP_REDIRECT_HTTPROUTE_ACCEPTED=true`, and
  `CLASSIFICATION=ready-for-external-proof`, then completed the aggregate validation
  successfully.

### Remaining Work

None.

## Sprint 5.6: Typed Prerequisites, Capability-Derived IAM Tier, and Destructive Dry-Run Goldens ✅

**Status**: Done (2026-06-09). New `src/Prodbox/PrerequisiteId.hs` defines the typed `PrerequisiteId`
ADT (one constructor per registry node) with `prerequisiteIdText` as the stable-string SSoT; the
prerequisite registry, `EffectDAG`/`EffectInterpreter`, and `TestPlan` are parameterized on it (no
more `Set String`/`Map String`). Each validation declares minimal-and-precise typed prerequisites
(`validationInitialPrerequisites`/`validationDeferredPrerequisites`) — e.g. `charts-*` now require
only `[PublicEdgeReady, ToolCurl]`. `normalizeManagedAwsHarness`'s `substrate=aws` blanket override
was deleted; `derivedManagedAwsHarnessPolicyTier` derives the IAM tier from declared capabilities
(`gateway-partition` on AWS engages NO harness — unit-pinned). `infra_ready` split into `infra_ready`
+ the new AWS-credential-free `public_edge_ready` node, with `charts-vscode`/`api`/`websocket`/
`admin-routes` re-pointed to it. `verifyAwsEksSnapshot` now uses the structured
`parseAwsEksTestStackFromOutputs` parser (substrate-equivalence properties) instead of a `Text.null`
check. Three registry-generated destructive `--dry-run` goldens (`rke2 delete`, `rke2 delete
--cascade`, `nuke`) landed under `test/golden/destructive/` with drift-guard tests (a new registered
resource fails the golden) — closing the audit V80 gap and proving Sprint 4.26's dry-run-no-mutation
fix. Validation green: `check-code` 0, `test unit` 809/809, `integration cli` 35/35, `integration
env` 35/35, `lint docs` 0, `docs check` 0. The live AWS-substrate + public-edge-readiness exercises
are operator-driven.
**Implementation**: `src/Prodbox/Prerequisite.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/` (recommended)
**Docs to update**: `documents/engineering/unit_testing_policy.md`, `documents/engineering/integration_fixture_doctrine.md`

### Objective

Make the prerequisite surface that gates the canonical suite typed and minimal-and-precise per
validation, derive the IAM-harness tier from each validation's declared capabilities instead of a
blanket substrate override, split the public-edge readiness gate out of `infra_ready` so the
`charts-*` validations gate on an AWS-credential-free readiness, strengthen the AWS EKS snapshot
verification, and add destructive `--dry-run` golden coverage generated from the managed-resource
registry. This is the canonical-suite-side counterpart to the typed-source work in Sprints `1.31`
(prerequisite DAG acyclicity + node collapse), `4.26`/`4.27` (registry-derived destructive
dispatch and the `StackDescriptor` SSoT), and the typed-error reframe in Sprint `1.30`.

### Deliverables

- A typed `PrerequisiteId` ADT replaces the current raw-`String` `effectNodeId` keys in
  `src/Prodbox/Prerequisite.hs`, so prerequisite identifiers are exhaustively matched rather than
  string-compared.
- Each canonical validation declares a minimal-and-precise prerequisite set: a validation requires
  exactly the typed prerequisites it actually consumes, with no over-broad inherited bundle.
- The IAM-harness tier per validation is derived from that validation's declared capabilities. The
  `normalizeManagedAwsHarness` `substrate=aws` blanket override is deleted; a validation that needs
  no AWS credentials does not acquire the IAM harness merely because the active substrate is AWS.
- `infra_ready` is split into `infra_ready` and a new declared `public_edge_ready` prerequisite
  node. `public_edge_ready` encodes the public-edge readiness gate (today procedural in
  `runWaitForPublicEdgeReady`) as a declared node that depends only on cluster + chart-platform
  readiness, **not** on AWS credentials, so `charts-vscode`, `charts-api`, `charts-websocket`, and
  `admin-routes` gate on an AWS-credential-free readiness. The Canonical Suite Inventory table and
  the procedural-gate note above are updated to name `public_edge_ready` as a declared node once
  this lands.
- `verifyAwsEksSnapshot` is strengthened to assert the substrate-equivalence properties the AWS
  EKS run must hold (per [substrates.md](substrates.md) and
  [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md)) rather than a
  weaker existence check.
- Three destructive `--dry-run` goldens are added — for `prodbox cluster delete`,
  `prodbox cluster delete --cascade`, and `prodbox nuke` — proving the planned step list each
  destructive path emits without executing it. The golden coverage is generated from the
  managed-resource registry / `StackDescriptor` SSoT (Sprints `4.26`/`4.27`) so the goldens track
  the registry rather than drifting from it.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox test integration cli`
4. `prodbox test integration env`
5. Typed-prerequisite proof: the prerequisite registry keys are a typed `PrerequisiteId` ADT and
   no validation declares a prerequisite it does not consume.
6. Capability-tier proof: a credential-free validation run on the AWS substrate does not acquire
   the IAM harness; `normalizeManagedAwsHarness` no longer carries a `substrate=aws` blanket arm.
7. Readiness-split proof: `charts-*` validations gate on `public_edge_ready` and pass with no
   AWS credentials present.
8. Golden proof: the three destructive `--dry-run` goldens render from the managed-resource
   registry and fail if a registered resource is added without updating the generated golden.

### Remaining Work

None — closed 2026-06-09. All deliverables landed (typed `PrerequisiteId`, minimal per-validation
prerequisites, capability-derived IAM tier, the `public_edge_ready` split, the strengthened
`verifyAwsEksSnapshot`, and the three registry-generated destructive goldens). The live
AWS-substrate aggregate and the live public-edge-readiness exercise are operator-driven.

## Sprint 5.8: Sealed-Vault Canonical Validation and SecretRef Golden Tests ✅

**Status**: Done (2026-06-16) on its code-owned/home-substrate surface — the
`IntegrationSealedVault` / `ValidationSealedVault` named-suite entrypoint, the `sealedVaultAuditReport`
forbidden-pattern oracle, and the SecretRef golden tests have landed and validate locally
(`prodbox dev check`, `test unit`, `test integration cli`/`env`); reopened 2026-06-16 to adopt the
phase-independence doctrine (Sprint `0.15`), removing the former backward block on Sprint `7.14`.
**Implementation**: `src/Prodbox/TestValidation.hs`, `src/Prodbox/TestPlan.hs`, `test/`
**Independent Validation**: The sealed-Vault canonical validation and SecretRef golden tests are
validated on this phase's owned surface (the canonical-suite content in `src/Prodbox/TestValidation.hs`)
with no dependency on a later phase: `prodbox test integration sealed-vault` runs against the
home/local substrate, sealing the home-cluster Vault and asserting fail-closed behavior plus the
cross-surface zero-child-info audit, while the pure `sealedVaultAuditReport` oracle and the generated
Dhall/config SecretRef sweep run as local unit tests against fixtures and rendered artifacts. Where the
red-team would touch a later-phase-owned AWS substrate, it is exercised against the home substrate
today; the AWS-substrate variant is the orthogonal coverage row, not a gate.
**Live proof**: the home-substrate sealed-Vault validation passed on 2026-06-16 and again inside the
June 26 aggregate, including the host-disk/Kubernetes/log opacity audit. Remaining parent/child
federation-cascade and AWS-substrate variants are distinct non-blocking Standard-O axes tracked in
this sprint's Remaining Work and [substrates.md](substrates.md); they are not `5.8` blockers.
**Docs to update**: `documents/engineering/unit_testing_policy.md`, `documents/engineering/vault_doctrine.md`, `documents/engineering/cluster_federation_doctrine.md`

### Objective

Add suite content that proves the finalized fail-closed invariant end-to-end: Vault is the sole
secrets backend, so a sealed Vault bricks the cluster and there is no non-Vault source to
reconstruct a secret from. The validation asserts the sealed-state behavior matrix
([vault_doctrine.md §15](../documents/engineering/vault_doctrine.md#15-sealed-state-behavior-matrix))
and the red-team checklist
([vault_doctrine.md §19](../documents/engineering/vault_doctrine.md#19-red-team-checklist)) and that
generated artifacts carry only `SecretRef` values on the `FileSecret`-free union. It **also** covers
the two finalized surfaces this end state adds: the
retired master-seed derivation surface (no `master-seed` object, no daemon `/v1/secret/*` RPC to
fall back to) and the cluster-federation auto-unseal cascade (a sealed or unreachable parent Vault
bricks its children) per
[cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md). Under the
2026-06-15 Model-B + whole-system zero-child-info refinement it also owns the **cross-surface
sealed-Vault red-team** — a combined bucket/object/host-disk/Kubernetes/log probe proving the
whole-system zero-child-info invariant ([vault_doctrine.md §9/§10/§19](../documents/engineering/vault_doctrine.md)). This
extends the canonical suite; existing validations are unchanged.

### Deliverables

- A `ValidationSealedVault` / `prodbox test integration sealed-vault` flow: spin up, init+unseal,
  reconcile MinIO/in-force-Dhall/Pulumi/charts, seal Vault, then assert in-force-config read, Pulumi
  preview, gateway config load, Keycloak reconcile, MinIO object decrypt, and TLS reconcile all fail
  closed without leaking metadata — only the unencrypted basics (cluster id, Vault address, seal
  mode, parent reference for a child) remain legible while Vault is sealed.
- Derivation-retirement coverage: the suite asserts there is **no** `master-seed` object in MinIO
  and **no** gateway daemon `/v1/secret/derive` / `/v1/secret/ensure-namespace` RPC, so a sealed
  Vault has no HMAC-derivation path to reconstruct a previously-derived secret (Patroni/Postgres,
  Keycloak admin, OIDC client, gateway event keys); every such secret resolves only as a Vault KV
  object via Vault Kubernetes auth and fails closed when Vault is sealed (Sprint `3.19`).
- Federation auto-unseal cascade coverage: with a sealed (or unreachable) parent Vault, a child
  cluster's `seal "transit"`-backed Vault cannot auto-unseal, and the child's own fail-closed brick
  follows — proving the unseal cascade roots in the operator unsealing the root cluster
  (Sprint `3.20`, Sprint `4.32`).
- Cross-surface sealed-Vault red-team (Model-B whole-system zero-child-info; gated on the
  Sprint `3.17` deployed Vault): with the parent Vault sealed, the suite runs a combined probe across
  all four leak surfaces and asserts none carries child information —
  - a bucket-level `aws s3api ls` plus `list-objects` against the **one generically-named bucket**
    returns no role-revealing bucket name (`prodbox` / `prodbox-test-pulumi-backends` are retired)
    and only opaque `objects/<hmac>.enc` keys under one flat prefix — no `aws-eks`/stack-name object
    key — at a **constant** decoy-padded count, so the listing count carries no signal;
  - a host-disk walk of the `.data/prodbox/minio/0` hostPath PV reveals only opaque-named ciphertext,
    no cleartext object body and no legible logical name (the `prodbox-envelope-v2` stored AAD is
    `base64(SHA256(aad))`, not cleartext);
  - a Kubernetes ConfigMap/Secret dump reveals no child-cluster name and no child-named namespace —
    downstream identity is custodied in Vault KV, namespaces are opaque IDs;
  - a log/output audit across the residue-query, MinIO-backend, Pulumi-backend, and stack-output
    sites emits no bucket/key/stack/child name and exposes **no exists-vs-absent (`NoSuchKey`)
    oracle**, because residue queries are gated behind the Vault-readiness check (Sprint `4.33`);
  - the gateway daemon on its Kubernetes-auth path likewise cannot read the Vault-enveloped in-force
    config while the parent Vault is sealed.
- Golden tests that generated Dhall/config artifacts contain only `SecretRef.Vault` /
  `SecretRef.TransitKey` values — there is no `SecretRefFile` constructor to render — with no
  forbidden plaintext pattern (`AKIA`, `aws_secret_access_key`, `BEGIN PRIVATE KEY`,
  `client_secret = "…"`, `password = "…"`, Pulumi passphrase, kubeconfig user token, raw master
  seed).
- Unit proofs for plaintext-secret rejection (the `SecretRef.TestPlaintext` arm is accepted only by
  the test harness from `test-secrets.dhall`, never in production), Vault init/unseal/reconcile,
  fixture seeding from `test-secrets.dhall`, and teardown-preserves-Vault-PV. The plaintext-rejection
  proof also asserts `prodbox.dhall` carries no plaintext admin/operational AWS key — the
  `aws_admin_for_test_simulation.*` test-simulation block is a `TestPlaintext` fixture that lives
  only in `test-secrets.dhall` (never imported by `prodbox.dhall`, never in Vault), while the
  generated operational `aws.*` credential is minted into Vault KV and `prodbox.dhall` carries
  only a `SecretRef.Vault` reference to it (see
  [vault_doctrine.md §3/§4/§13](../documents/engineering/vault_doctrine.md) and
  [aws_admin_credentials.md](../documents/engineering/aws_admin_credentials.md)).

### Current State

- `IntegrationSealedVault` and `ValidationSealedVault` are wired into the native `prodbox test
  integration sealed-vault` surface, generated CLI docs, completions, and manpage.
- The aggregate native validation order now runs `sealed-vault` after `charts-storage` and before
  the destructive `lifecycle` validation.
- `runSealedVaultValidation` records the runtime shape: detect the current Vault seal state, seal if
  the runtime starts unsealed, assert `vault status` reports `sealed=True`, assert `aws stack eks
  reconcile` fails at the sealed-Vault gate before Pulumi work, audit the MinIO hostPath and
  Kubernetes ConfigMap/Secret names, and unseal again if the validation sealed Vault.
- The targeted `sealed-vault` runbook reconciles the local platform with plain `cluster reconcile`
  rather than `cluster reconcile --with-edge`, so a bare home cluster can prove sealed-Vault
  behavior without requiring operational Route 53 credentials for the gateway chart. Public-edge
  suites still use the edge runbook.
- `sealedVaultAuditReport` is the pure forbidden-pattern oracle for the cross-surface red-team. It
  accepts only the generic `prodbox-state` bucket, opaque `objects/<id>.enc` / `indexes/<id>.enc`
  keys, and redacted `vault_status=... result=unobservable` output; it rejects stack names,
  role-revealing buckets, child names, removed gateway `/v1/secret/*` RPCs, `SecretRefFile`, AWS
  key literals, private-key literals, plaintext client secrets, passwords, Pulumi passphrases, and
  kubeconfig user-token markers.
- The generated Dhall/config SecretRef sweep is now executable in the unit suite. It covers
  `renderConfigDhall`, `renderInForcePayload`, `gateway config-gen`, and the chart-side API,
  gateway, gateway-orders, and websocket Dhall templates, failing on any sealed-Vault forbidden
  pattern, rendered `SecretRefFile`, or plaintext/prompt `SecretRef` value constructor.

### Validation

- `prodbox test integration sealed-vault` asserts every sealed-state row fails closed, including the
  no-derivation-fallback rows and the federation auto-unseal-cascade rows.
- The cross-surface sealed-Vault red-team asserts the combined bucket-level `aws s3api ls` +
  `list-objects`, host-disk walk of `.data/prodbox/minio/0`, Kubernetes ConfigMap/Secret dump, and
  log/output audit reveal only opaque `objects/<hmac>.enc` at a constant count — no role-revealing
  bucket name, no `aws-eks`/stack-name key, no cleartext body, no child-named namespace, and no
  exists-vs-absent (`NoSuchKey`) oracle.
- The SecretRef golden tests fail on any forbidden plaintext pattern and on any rendered
  `SecretRefFile` constructor.
- Current code-owned validation: `cabal build --builddir=.build exe:prodbox` passes;
  `./.build/prodbox dev lint haskell --write` reports no hints; focused Sprint `5.8` unit tests pass
  2/2; the generated Dhall/config SecretRef sweep passes 1/1; the `test planning` unit filter
  passes 42/42; the parser filter passes 260/260; and the CLI generated-output goldens pass 3/3 for
  the new `sealed-vault` command. Full local gates also pass: full unit suite 950/950,
  `./.build/prodbox test integration cli` 38/38, `./.build/prodbox test integration env` 38/38,
  `./.build/prodbox dev docs check` 0, `./.build/prodbox dev lint docs` 0,
  `git diff --check` 0, and `./.build/prodbox dev check` 0.
- Live home-substrate validation (2026-06-16): `./.build/prodbox test integration sealed-vault`
  passes. The runbook reconciled the local platform, skipped the gateway chart because operational
  `aws.*` was absent from Vault, sealed Vault, proved `aws stack eks reconcile` stops at the
  sealed-Vault gate before Pulumi starts, emitted `SEALED_VAULT_AUDIT=pass`, and restored Vault to
  `sealed=False`. Follow-up inspection showed all cluster pods Running/Completed and no gateway Helm
  release.

### Remaining Work

- None on this sprint's code-owned surface — it is ✅ Done and validates locally.
- **Live-proof: pending** (non-blocking, Standards N/O). The AWS-substrate side of the sealed-Vault
  exercise, the live parent/child federation auto-unseal cascade exercise, and the live cross-surface
  sealed-Vault red-team are live-infrastructure proofs, not code-owned closure work: they need a live
  deployed Vault, and the AWS-substrate variant composes (forward build order) against Sprint `7.14`'s
  raw Pulumi checkpoint decrypt-to-scratch interposition. These are tracked here as a non-blocking
  Live-proof note and, for AWS-substrate parity, in [substrates.md](substrates.md)'s parity table;
  neither reopens this sprint or gates its phase.

## Sprint 5.9: Repair the daemon-lifecycle Suite Fixture (SecretRef Schema Drift) ✅

**Status**: ✅ Done (validated 2026-06-18). `test/daemon-lifecycle/Main.hs::renderConfig` was repaired to the current `DaemonConfigDhall` `SecretRef`-union schema (the top-level `vault = None {…}`, `aws_creds`/`minio_creds` as `None` of the current `SecretRef`-field records, `event_keys = []` with the current union element type) so `loadDaemonConfig` decodes the fixture again. The standalone `prodbox-daemon-lifecycle` suite is now **11/11 PASS** (was ~8/11 red); no assertion weakened (the launching tests exercise health/readiness/metrics/`/v1/state`/SIGTERM-drain, none sign a node-a event, and the daemon tolerates a missing event key). No production code changed; main gate unaffected (`dev check` 0, `test unit` 0, `integration cli`/`env` 0). Only `test/daemon-lifecycle/Main.hs` changed.
**Blocked by**: Sprint `1.35` (the landed typed `SecretRef` config contract — the `FileSecret`-free
union the fixture must render against).
**Implementation**: `test/daemon-lifecycle/Main.hs`
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/integration_fixture_doctrine.md`

### Objective

Repair the standalone `prodbox-daemon-lifecycle` cabal suite (the `test/daemon-lifecycle` source dir
declared in `prodbox.cabal`), which is currently 8/11 red because its fixture renderer emits the
pre-Vault-root config shape rather than the current `SecretRef` union. The drift predates the
Vault-root migration (Sprint `1.35`) and reproduces on pristine `HEAD`. This suite is **not** part of
the `prodbox test` frontend gate (`dev check`, `test unit`, `test integration cli`/`env`), so the
drift is invisible to the canonical-suite gates that gate this phase; this sprint brings the
standalone fixture back in line with the schema the gated surfaces already prove.

### Root Cause

`test/daemon-lifecycle/Main.hs::renderConfig` emits the pre-Vault-root plaintext `boot` shape — inline
`event_keys = [ { name, value } ]`, `aws_creds = None { access_key_id, secret_access_key, … }`, and
`minio_creds = None { minio_access_key, minio_secret_key }` — instead of the current
`DaemonConfigDhall` `SecretRef` union. The daemon decodes the current `FileSecret`-free `SecretRef`
contract (Sprint `1.35`), so the legacy plaintext field shapes no longer parse and the suite fails at
config decode.

### Deliverables

- `test/daemon-lifecycle/Main.hs::renderConfig` is repaired to the current `DaemonConfigDhall`
  `SecretRef` schema, so the rendered fixture decodes against the `FileSecret`-free `SecretRef` union
  (Sprint `1.35`). The fixture's test-only secret values use the `SecretRef.TestPlaintext` arm that the
  test harness accepts (never a production constructor), consistent with the canonical-suite
  plaintext-rejection contract in Sprint `5.8`.
- The standalone `prodbox-daemon-lifecycle` cabal suite returns to green (11/11) on pristine `HEAD`.
- A short note records that this suite is a standalone cabal `test-suite`, not part of the
  `prodbox test` frontend gate, so its repair does not change the frontend gate result; it closes a
  schema-drift gap that the frontend gates do not exercise.

### Validation

1. `cabal test prodbox-daemon-lifecycle --builddir=.build` passes 11/11.
2. `prodbox dev check`, `prodbox test unit`, `prodbox test integration cli`, and
   `prodbox test integration env` remain green and unchanged (the standalone suite is outside this
   gate; the repair does not touch frontend-gated surfaces).
3. Schema-drift proof: the repaired `renderConfig` emits only `SecretRef` union values on the
   `FileSecret`-free contract, with no inline plaintext `event_keys` / `aws_creds` / `minio_creds`
   field shape remaining.

### Remaining Work

- Pending — fixture repair not yet landed.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_integration_environment_doctrine.md` - external proof and AWS access
  doctrine after the Haskell rewrite.
- `documents/engineering/aws_test_environment.md` - shared AWS-substrate environment doctrine for
  the canonical-suite content owned here.
- `documents/engineering/cli_command_surface.md` - supported public-host validation commands.
- `documents/engineering/envoy_gateway_edge_doctrine.md` - target Gateway API and Envoy public-edge
  doctrine.
- `documents/engineering/helm_chart_platform_doctrine.md` - public-host behavior of the rewritten
  `vscode` stack.
- `documents/engineering/unit_testing_policy.md` - external-only public-host validation doctrine;
  for Sprint `5.6`, the typed `PrerequisiteId` surface, minimal-and-precise per-validation
  prerequisites, the `public_edge_ready` readiness split, and the three destructive `--dry-run`
  goldens generated from the managed-resource registry; for Sprint `5.13`, the
  `resource-guardrails` named validation and its pod/quota JSON oracle.
- `documents/engineering/resource_scaling_doctrine.md` - for Sprint `5.13`, the validation contract
  proving no `BestEffort` pods and over-budget config refusal before mutation.
- `documents/engineering/integration_fixture_doctrine.md` - for Sprint `5.6`, the
  capability-derived IAM-harness tier (replacing the `normalizeManagedAwsHarness` `substrate=aws`
  blanket override) and the registry-generated destructive-dry-run golden fixtures.
- [documents/engineering/vault_doctrine.md](../documents/engineering/vault_doctrine.md) - for
  Sprint `5.8`, the sealed-state behavior matrix
  ([vault_doctrine.md §15](../documents/engineering/vault_doctrine.md#15-sealed-state-behavior-matrix))
  and red-team checklist
  ([vault_doctrine.md §19](../documents/engineering/vault_doctrine.md#19-red-team-checklist)) the
  `sealed-vault` validation and the SecretRef golden tests prove against the canonical suite,
  including the retired master-seed derivation surface (no `master-seed` object, no daemon
  `/v1/secret/*` RPC) and the `FileSecret`-free `SecretRef` union, plus the Model-B object-store and
  whole-system zero-child-info surfaces (§9/§10) the cross-surface sealed-Vault red-team probes — the
  one generically-named bucket, opaque `objects/<hmac>.enc` naming at a constant decoy-padded count,
  the opaque-only `.data/prodbox/minio/0` hostPath, opaque Kubernetes namespaces, and the
  no-exists-vs-absent-oracle log/output rule.
- [documents/engineering/cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md) -
  for Sprint `5.8`, the Vault transit-seal trust tree and the fail-closed unseal cascade the
  `sealed-vault` validation proves when a parent Vault is sealed or unreachable.
- [documents/engineering/test_topology_doctrine.md](../documents/engineering/test_topology_doctrine.md) -
  for Sprint `5.11`, the `test init` / `test run` command surface, `.test-data/` isolation with the
  never-touch-`.data/` `guardTestDelete` guard, the two fail-fast preconditions, and the
  finally-guaranteed teardown that reuses `LifecycleClass` / `partitionResidueByLifecycle` to delete
  the per-run half while retaining the authored test Dhall and long-lived SES/S3 resources.
- `documents/engineering/unit_testing_policy.md` - for Sprint `5.11`, the `test run` per-variant
  deploy-path reuse and the finally-guaranteed teardown that runs on every exit (success, failure,
  Ctrl-C).
- `documents/engineering/integration_fixture_doctrine.md` - for Sprint `5.11`, the per-run vs
  long-lived teardown ownership across the `.test-data/` isolation boundary.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep public-host closure linked back to [README.md](README.md).

## Sprint 5.10: Harness-generated run config from `test-secrets.dhall` ✅

**Status**: Done (code-owned surface) — 2026-06-23
**Implementation**: `src/Prodbox/Vault/Host.hs` (`TestSecrets` + `defaultTestSecrets` gained
`route53_zone_id :: Text`), `test-secrets-types.dhall` (REGENERATED via `prodbox config schema` —
`route53_zone_id : Text`, default `""`), `src/Prodbox/Aws.hs` (`harnessConfigSetupInput` — the
no-prompt collector sourcing `route53.zone_id`/EAB from `test-secrets.dhall`, `acme.email` from the
baked `harnessAcmeEmail`, the rest carried from the current skeleton; `regenerateConfigFromTestSecrets`
preflight reusing the Sprint `1.50` `configFromSetupInput` builder, "fill only when empty"),
`src/Prodbox/TestRunner.hs` (`runConfigRegenFromTestSecrets` wired into `runNativeSuite` before the
pre-reconcile + `runManagedAwsHarnessSetup`), `test-secrets.dhall` (fixture gained the real
`route53_zone_id` for `resolvefintech.com`).
**Blocked by**: Sprint `1.48` + Sprint `1.50` (both now Done)
**Live-proof**: pending
**Independent Validation**: the `TestSecrets` round-trip drift guard now decodes `route53_zone_id`
against the generated schema; the shared builder's field-fill is covered by the Phase 1 Sprint `1.50`
test. The harness IO wiring (`loadTestSecrets` → `harnessConfigSetupInput` → `configFromSetupInput` →
`writeProjectConfigParameters`) is exercised live by `prodbox test all`. Phase 5's own surface; no
dependency on a later phase.
**Docs to update**: `documents/engineering/config_doctrine.md` (§0, "The test harness generates its
run config"), `documents/engineering/unit_testing_policy.md`.

### Objective

Let the test harness **generate** its run `prodbox.dhall` instead of requiring a hand-authored one,
mirroring hostbootstrap's `demoTestConfig`-reuses-`demoInit` idiom: the harness assembles a
`ConfigSetupInput` non-interactively and writes the binary-sibling config through the **same**
`configFromSetupInput` builder production's `config setup` uses (Sprint `1.50`). This unblocks
`prodbox test all` from a freshly-generated skeleton — today it fails the managed AWS IAM harness
preflight with `route53.zone_id must not be empty`. Implements [config_doctrine.md §0 ("The test
harness generates its run
config")](../documents/engineering/config_doctrine.md#0-three-tier-config-model); covered per
[unit_testing_policy.md](../documents/engineering/unit_testing_policy.md).

### Deliverables

- `route53_zone_id :: Text` added to the `TestSecrets` Haskell type; `test-secrets-types.dhall`
  regenerated via `prodbox config schema` (the one file where cleartext operator ids the harness
  injects are allowed).
- `harnessConfigSetupInput`: sources `route53.zone_id` from `test-secrets.dhall`, `acme.email` from
  a baked operator-email default, the EAB from `test-secrets.dhall`'s `acme_eab`, and the remaining
  knobs from the same defaults the generated skeleton already carries.
- `regenerateConfigFromTestSecrets` preflight wired into `runNativeSuite` before
  `runManagedAwsHarnessSetup`, regenerating the binary-sibling `prodbox.dhall` only when its operator
  fields are empty (never clobbering a populated real config).
- `aws_substrate.*` / `ses.*` / `pulumi_state_backend.*` remain deferred — extend the same way when a
  run requires them.

### Validation

`prodbox dev check` 0; `prodbox test unit` 1060/1060 (the `TestSecrets` GENERATED-schema round-trip
now decodes `route53_zone_id`; the `configFromSetupInput` field-fill is covered by Sprint `1.50`);
`prodbox config schema` regenerates `test-secrets-types.dhall` cleanly with the new field.

### Remaining Work

- 🧪 Live-proof (non-blocking, Standard O): `prodbox test all` (home-local) regenerates the
  binary-sibling config from `test-secrets.dhall` and proceeds **past** the `route53.zone_id`
  preflight (the original failure). The real `resolvefintech.com` zone id is now in the fixture.

## Sprint 5.11: Test-Topology Command Surface (`test init` / `test run`) ✅

**Status**: Done (code-owned surface) — 2026-07-03
**Implementation**: `src/Prodbox/CLI/Command.hs` (the `test init` / `test run` surface extending
`TestCommand` / `TestScope`), `src/Prodbox/TestRunner.hs` (per-variant generate → reconcile →
assert → `finally` teardown), `src/Prodbox/TestValidation.hs` (`.test-data/` repointing of the
sealed-Vault audit path), `src/Prodbox/Lib/Storage.hs` (the `.test-data/` `manual_pv_host_root`
override), `test/unit/Main.hs`
**Live-proof**: pending
**Independent Validation**: unit tests over the pure `guardTestDelete` never-touch-`.data/`
`TestDeleteTarget` ADT, generated per-variant run config storage-root override, the sealed-Vault
audit-root override, topology suite mapping, and the two fail-fast preconditions; warning-clean
build; `prodbox test integration cli`/`env` on the home/local substrate; no later-phase dependency.
**Docs to update**: `documents/engineering/test_topology_doctrine.md`,
`documents/engineering/unit_testing_policy.md`,
`documents/engineering/integration_fixture_doctrine.md`

### Objective

Land the `test init` / `test run` command surface per
[test_topology_doctrine.md](../documents/engineering/test_topology_doctrine.md): `prodbox test init`
generates the differently-shaped executable-sibling `prodbox.test.dhall` (the HA/failover variant
matrix), and `prodbox test run <suite>|all` drives each declared variant through the **real deploy
path**, isolating run state under `.test-data/` and always tearing down its per-run half.

### Deliverables

- `prodbox test init` writes `prodbox.test.dhall` at the executable-sibling path and refuses to
  overwrite an existing one without `--force`.
- `prodbox test run <suite>` runs one named suite; `prodbox test run all` runs every declared
  variant through the same reconcile/assert deploy path the canonical suite content already uses.
- `.test-data/` isolation: the run's `manual_pv_host_root` points at `.test-data/<case>/` instead of
  the production `.data/`, and `src/Prodbox/TestValidation.hs`'s hard-coded `.data/prodbox/minio/0`
  audit root is repointed under that override.
- A mechanical never-touch-`.data/` delete guard: the `guardTestDelete` closed `TestDeleteTarget`
  ADT can name only this-run generated config, `.test-data/`, and `LifecycleClass PerRun` residue —
  naming `.data/`, the authored `prodbox.test.dhall`, or a `LongLived` resource is unconstructible.
- Finally-guaranteed teardown reusing the managed-resource registry: `partitionResidueByLifecycle`
  (`src/Prodbox/Aws.hs`) reconciles the `PerRun` slice plus this run's `.test-data/` to absent and
  gates the `LongLived` slice (authored test Dhall, `aws-ses`, and the `pulumi_state_backend` bucket
  retained by design).
- The two hard fail-fast preconditions run before any work: refuse when a production `prodbox.dhall`
  exists beside the binary (the inverse of production's fail-if-absent rule) and refuse when a
  production cluster is running.

### Validation

1. `cabal build --builddir=.build all --ghc-options=-Werror`
2. `prodbox test unit` (1134/1134: `guardTestDelete`, generated per-variant run config,
   topology env propagation, sealed-Vault audit-root override, suite mapping, and preconditions)
3. `prodbox test integration cli`
4. `prodbox test integration env`
5. `prodbox dev docs check`
6. `git diff --check`
7. `prodbox dev check`

### Remaining Work

- 🧪 Live-proof (non-blocking, Standard O): a real topology-run over deployed cluster variants
  proves the end-to-end stand-up/assert/teardown loop against live infrastructure. The code-owned
  command surface, `.test-data` isolation, and finally-guaranteed cleanup are complete.

## Sprint 5.12: `eks-volume-rebind` — Identical Block-Storage Rebinding Validation [✅ Done]

**Status**: ✅ Done (code-owned surface) — 2026-07-03
**Implementation**: `src/Prodbox/TestPlan.hs` (`ValidationEksVolumeRebind`, `nativeValidationId`,
home cluster prerequisites, and AWS harness derivation), `src/Prodbox/CLI/Command.hs`
(`IntegrationEksVolumeRebind`), `src/Prodbox/CLI/Spec.hs` (parser + command-registry leaf),
`src/Prodbox/TestValidation.hs` (`runEksVolumeRebindValidation`, snapshot parser, and report
oracle), `src/Prodbox/TestRunner.hs` (`validationMayProvisionPerRunAwsStacks` + topology suite
mapping), `test/unit/Main.hs`, `test/unit/Parser.hs`.
**Blocked by**: none on the code-owned surface — the validation compiles and runs on the home
substrate independently. The AWS run exercises the Phase 7 Sprint `7.28` static-EBS renderer and the
Phase 4 Sprint `4.39`/`4.40` lifecycle, but per Standards M/N the AWS coverage is a non-blocking
parity axis, not a backward block.
**Live-proof**: pending
**Independent Validation**: the validation body is substrate-agnostic and validatable on the home
substrate (hostPath PV rebind) with no later-phase dependency; the `--substrate aws` run (EBS
`volumeHandle` rebind) is a parity row in [substrates.md](substrates.md), never a phase blocker
(Standards M/N/O).
**Docs to update**: `storage_lifecycle_doctrine.md` (§ 6 test expectations),
`substrates.md` (parity table), `unit_testing_policy.md`.

### Objective

Prove the unified-storage rebinding guarantee of
[storage_lifecycle_doctrine.md § 4](../documents/engineering/storage_lifecycle_doctrine.md)
end-to-end on both substrates: write a sentinel value to a retained workload's PV, tear the cluster
down, spin it back up, and assert the **same** PV rebinds to the same PVC and the sentinel data
persists — hostPath on home, the same EBS `volumeHandle` on EKS.

### Deliverables

- `eks-volume-rebind` is a `NativeValidation` wired through the canonical command surface and
  aggregate suite ordering after `charts-storage` and before `sealed-vault`.
- The validation selects the retained MinIO PV/PVC inventory row, writes a sentinel under the
  workload's `/export` mount, drives `cluster delete`/`reconcile --with-edge` on home or
  `aws stack eks destroy`/`reconcile` on AWS, then re-reads the sentinel and PV JSON.
- The pure report oracle asserts same PV name, same claim namespace/name, `Bound` before and after,
  identical `volumeHandle` when present, and sentinel preservation; unit tests cover success,
  sentinel mismatch, handle mismatch, JSON parsing, planner wiring, topology mapping, and parser
  coverage.
- The Canonical Suite Inventory and `substrates.md` parity table call out the AWS `--substrate aws`
  run as live-proof pending for the Sprint `7.28` static retained-EBS PV path.

### Validation

1. `cabal build --builddir=.build all --ghc-options=-Werror`
2. `prodbox test unit` (1139/1139: parser, planner, topology mapping, harness derivation,
   `VolumeRebindSnapshot` JSON parser, report oracle, and generated CLI goldens)
3. `prodbox test integration cli`
4. `prodbox test integration env`
5. `prodbox dev docs generate`
6. `prodbox dev docs check`
7. `git diff --check`
8. `prodbox dev check`
9. `prodbox test integration eks-volume-rebind` (home substrate; destructive live proof) — attempted
   2026-07-03 and failed fast before mutation because the binary-sibling
   `.build/prodbox.dhall` runtime config was absent (`settings_object` prerequisite); this remains
   the non-blocking live-proof axis per Standard O. The `--substrate aws` run remains the separate
   parity axis.

### Remaining Work

- 🧪 Live-proof (non-blocking, Standard O): provide a valid binary-sibling runtime config and run
  the destructive home `prodbox test integration eks-volume-rebind` against a disposable local
  substrate, then the AWS `--substrate aws` parity row against the Sprint `7.28` static retained-EBS
  PV path. The code-owned command/planner/parser/body/oracle surface is complete.

## Sprint 5.13: `resource-guardrails` Validation [✅ Done]

**Status**: ✅ Done (code-owned surface) — 2026-07-04
**Implementation**: `src/Prodbox/CLI/Command.hs` (`IntegrationResourceGuardrails`),
`src/Prodbox/CLI/Spec.hs` (parser + command-registry leaf), `src/Prodbox/TestPlan.hs`
(`ValidationResourceGuardrails`, ordering, prerequisites, and named-suite mapping),
`src/Prodbox/TestRunner.hs` (topology suite mapping), `src/Prodbox/TestValidation.hs`
(`runResourceGuardrailsValidation` and `resourceGuardrailReport`), `test/unit/Main.hs`,
`test/unit/Parser.hs`, `test/integration/CliSuite.hs`, and CLI goldens.
**Live-proof**: pending
**Independent Validation**: pure report-oracle tests over Kubernetes pod/quota JSON, invalid-config
fixtures that fail before mutation, and CLI/env integration against fake `kubectl`; the home live
run is the first real substrate proof, with AWS parity tracked normally in [substrates.md](substrates.md).
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/resource_scaling_doctrine.md`, `DEVELOPMENT_PLAN/substrates.md`

### Objective

Add canonical-suite coverage for the resource-governor contract introduced by Sprints `1.55`,
`3.22`, and `4.41`.

### Deliverables

- New named validation `resource-guardrails` in the canonical suite, ordered after chart platform
  readiness and before destructive lifecycle/rebind validations.
- Kubernetes JSON oracle proving every prodbox-owned pod has `resources.requests` and
  `resources.limits` for cpu, memory, and ephemeral storage, and that `.status.qosClass` is never
  `BestEffort`.
- Namespace oracle proving every root chart namespace has the expected `ResourceQuota` and
  `LimitRange`, and that rendered quota values match the declared resource plan.
- Negative config fixture proving over-reserved host capacity, namespace quota overcommit, and a
  missing resource profile fail before Helm/RKE2 mutation.
- Optional stress sub-proof for the live home substrate: a deliberately over-limit test pod is
  OOMKilled or evicted inside Kubernetes without dropping host SSH/network availability.

### Validation

1. ✅ `prodbox test unit` — 1172/1172, covering pod/quota/limit-range JSON parsing, report
   rendering, invalid resource config refusal, parser routing, planner ordering, and CLI goldens.
2. ✅ `cabal test --builddir=.build prodbox-integration --test-options='-p resource-guardrails'`
   — 1/1 with fake `kubectl` pod/quota/limit-range JSON.
3. ✅ `prodbox test integration cli` — 41/41.
4. ✅ `prodbox test integration env` — 41/41.
5. ✅ `prodbox dev check`

### Remaining Work

- 🧪 Live-proof (non-blocking, Standard O): run the optional real over-limit pod stress proof on a
  disposable home substrate and the AWS `--substrate aws` parity row once the AWS substrate is
  provisioned. The code-owned command/planner/body/oracle surface is complete.

## Sprint 5.14: Daemon-Mediated Bootstrap Validation [✅ Done]

**Status**: Done
**Implementation**: `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`,
`src/Prodbox/TestRunner.hs`, `src/Prodbox/CLI/Spec.hs`, `test/unit/Main.hs`,
`test/unit/Parser.hs`, `test/integration/CliSuite.hs`, generated CLI goldens/docs
**Independent Validation**: pure/fake-daemon tests over validation planning and transport-use
oracles; live home/AWS substrate runs are non-blocking proof axes.
**Live-proof**: pending for real deployed daemon/object-store parity on AWS; Sprint `7.30` is code-Done
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/vault_doctrine.md`,
`DEVELOPMENT_PLAN/substrates.md`

### Objective

Add canonical-suite coverage that the daemon-mediated post-bootstrap boundary is real: unseal and
object-store-backed operations must use the daemon service and must not fall back to host MinIO
port-forwarding or direct host Vault NodePort access on supported paths.

### Deliverables

- ✅ A named validation, `daemon-bootstrap`, wired through the parser, command registry, native
  validation plan, aggregate ordering, and topology suite mapping.
- ✅ A transport-use oracle that fails on observed `kubectl port-forward` invocation for MinIO,
  `127.0.0.1:39000` backend use, direct `127.0.0.1:31820` Vault bootstrap calls, or host root-token
  fallback writes after daemon readiness.
- ✅ Positive proof that the daemon endpoint handles sealed-root bootstrap from the MinIO-resident
  unlock bundle with the operator/test password while keeping request/response/log output redacted.
- ✅ Negative proof that an unavailable daemon fails with a daemon-actionable error rather than silently
  using the legacy direct transports.
- 🧪 AWS parity row in `substrates.md` for the live EKS/MinIO daemon object-store proof after Sprint
  `7.30`'s code-owned object-store API landing.

### Validation

1. ✅ `cabal test --builddir=.build prodbox-unit --test-options=--hide-successes` — 1188/1188.
2. ✅ `prodbox test integration daemon-bootstrap` — named validation passes with no live
   prerequisite gate.
3. ✅ `cabal test --builddir=.build prodbox-integration --test-options='-p daemon-bootstrap --hide-successes'`
   — 1/1 targeted built-frontend proof.
4. ✅ `prodbox test integration cli` — 44/44; fake daemon-bootstrap trace proves the
   validation fails on legacy transport attempts.
5. ✅ `prodbox test integration env` — 44/44; no ambient `MINIO_*`, `PRODBOX_*`, or `AWS_*`
   fallback is introduced.
6. ✅ `prodbox dev check` — 0 after the repo Haskell formatter pass.
7. Live-proof (Standard O): run the same `daemon-bootstrap` substrate parity row on AWS with Sprint
   `7.30`'s daemon object-store APIs for Pulumi backend/residue paths.

### Remaining Work

- 🧪 Live-proof pending (non-blocking, Standard O): AWS/Pulumi object-store parity composes with
  Sprint `7.30`'s code-owned landing and is tracked through [substrates.md](substrates.md), not as
  a backward block.

## Sprint 5.15: Restore-Cycle DRY Builder and Daemon-Liveness Precondition [✅ Done]

**Status**: Done (2026-07-10)
**Implementation**: `src/Prodbox/TestRestore.hs` owns `RestoreChart`, `RestoreCycleStep`,
`RestoreCyclePlan`, `RestoreKeycloakSmtp`, the substrate-aware `buildRestoreCyclePlan`, and
`gatewayDaemonLivenessPrecondition`; `src/Prodbox/TestRunner.hs` projects the bootstrap/postflight
plans, interprets every step, and checks the precondition before SMTP mutation;
`src/Prodbox/CLI/Rke2.hs` exports the existing one-shot gateway object-store adapter
**Live-proof**: pending (non-blocking, Standard O) — a live home `prodbox test all` destructive
restore cycle with the gateway daemon up
**Independent Validation**: `prodbox test unit` passes 1280/1280, including exact builder order,
bootstrap/postflight equality modulo the SMTP step, the SMTP anchor, ready-open, and bounded
pending/unreachable `Preconditions.StructuredError` cases. `prodbox test integration cli` passes
44/44 after aligning all graph-consuming fixtures and the Percona one-shot trace as general
built-frontend regression coverage; those named plans run neither supported-runtime restore
projection and therefore do not prove the shared interpreter or SMTP gate end to end. `prodbox dev
check` exits 0. No later phase or live infrastructure is required for this code-owned closure.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Retire the Phase-1.6 strand: one restore-cycle builder (no hand-kept duplicate) and a typed daemon-up precondition so `syncKeycloakSmtp` cannot run in the daemon-down window between `charts delete gateway` and `charts reconcile gateway`.

### Deliverables

- ✅ One typed, substrate-aware restore-cycle builder that both
  `supportedRuntimeBootstrapActions` and `supportedRuntimePostflightActions` project from, deleting
  the two hand-kept lists. `RestoreWithKeycloakSmtp` inserts exactly one SMTP step after gateway
  reconciliation and before the dependent charts; `RestoreWithoutKeycloakSmtp` omits only that step.
- ✅ `syncKeycloakSmtp` is gated behind a daemon-liveness precondition built from a **one-shot** gateway
  object-store observation adapted as the `ComponentGatewayDaemonFull` backend-round-trip target;
  `Unreachable`/`NotReadyYet` become a fail-closed `StructuredError` naming the loopback NodePort.
  The shared Sprint-`1.59` poller owns bounded retry, so this adapter does not nest the existing
  `pollGatewayObjectStore` loop. This replaces the position-plus-comment ordering invariant.

### Validation

1. ✅ `prodbox test unit` — 1280/1280; exact one-builder projections and fail-closed precondition
   decisions pass.
2. ✅ `prodbox test integration cli` — 44/44 general built-frontend regression checks. The named
   plans run neither supported-runtime restore projection and do not select
   `RestoreSyncKeycloakSmtp`, so this is intentionally not described as an end-to-end
   restore-interpreter or gate proof.
3. ✅ `prodbox dev check` — exit 0 closure gate.
4. 🧪 Live-proof pending (non-blocking, Standard O): a home `prodbox test all` restore cycle
   completes with the gateway daemon up.

### Remaining Work

- None on Sprint `5.15`'s code-owned surface.
- 🧪 The live home restore remains the non-blocking Standard-O proof above.
- AWS-substrate adoption of the shared builder landed in Sprint `7.32`.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/bootstrap_readiness_doctrine.md` - the daemon-liveness precondition as a typed prerequisite (§4 posture).

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Ledger row I (duplicated restore lists + precondition-less `syncKeycloakSmtp`) is moved to
  `Completed` in `legacy-tracking-for-deletion.md` under Sprint `5.15`.

## Sprint 5.16: Gateway Runtime-Stability Oracle [✅ Done]

**Status**: Done (2026-07-10)
**Live-proof**: pending — the live restart-free soak longer than the July 10 failure interval is a
non-blocking Standard-O axis.
**Implementation**: `src/Prodbox/Test/GatewayRuntimeStability.hs`,
`src/Prodbox/TestValidation.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestRestore.hs`,
`src/Prodbox/TestPlan.hs`, `test/unit/GatewayRuntimeStability.hs`, `test/unit/Main.hs`, and
`test/integration/CliSuite.hs`
**Independent Validation**: table-shaped fake Kubernetes payloads cover stable, restarted,
OOM-killed, pressured, and unobservable pods plus stability-window folding; no live cluster or
later phase is required. Focused oracle and boundary tables pass 17/17, the installed-binary
fake-Kubernetes `gateway-pods` fixtures pass 2/2 (healthy and background-only OOM), the
warning-clean full unit suite passes 1494/1494, the CLI integration suite passes 47/47, and
`prodbox dev check` passes as the closure gate.
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/resource_scaling_doctrine.md`

### Objective

Make a recovered OOM a durable failing observation rather than a transiently green Deployment.
Keep authored resource-envelope validation separate from runtime stability, and require explicit
evidence that gateway replicas remained healthy across a bounded observation window.

### Deliverables

- Add a flat exhaustive `GatewayPodHealthObservation`-style classifier for restart-free ready,
  restart delta, `OOMKilled` residue, memory pressure/high-water, pending, and unobservable states.
- Maintain a run-wide absorbing unhealthy-evidence fold over pod UIDs, watch/events, container
  status, and restart deltas across destructive restore boundaries. Deletion/recreation cannot
  erase an OOM or restart already observed during the run.
- Run the observer under structured concurrency after the home baseline or the AWS gateway
  bootstrap handoff. Serialize foreground/background folds; bound every Kubernetes read at the API,
  GNU-process, and Haskell wall-clock layers; and keep AWS credentials/kubeconfig in a private
  explicit subprocess environment.
- Pause and drain across compiled gateway rollouts and observed-cluster replacement. After EKS
  recreation, restore the canonical AWS gateway/platform and require a refresh acknowledgement
  proving the old kubeconfig bracket has exited and a fresh bracket is active before foreground
  sampling and resume.
- Keep a separate restartable healthy-window baseline for an explicitly planned rollout. A rollout
  may restart only the success window; it never clears the absorbing unhealthy evidence. Fail on
  any OOM/restart evidence and require a configured sequence of stable samples before opening the
  gateway stability gate.
- Keep `resource-guardrails` responsible for authored requests/limits, quotas, and QoS. Add or
  extend a named runtime validation for observed stability rather than conflating the two proofs.
- Report pod name, restart delta, termination reason/time, current limit, and sampled high-water in
  one actionable diagnostic without relying on logs as the classifier.

### Validation

1. Fake-payload tables prove a currently Ready/Available pod with prior `OOMKilled` fails.
2. The absorbing run-evidence fold and separate healthy-window fold prove restarts/OOMs cannot be
   hidden by a later green sample, pod deletion, UID replacement, or planned chart reconcile.
3. Unobservable metrics/status fail closed; memory high-water warning/failure thresholds are pure
   configured inputs rather than free-form string logic.
4. `prodbox test unit`, built-frontend integration fixtures, and `prodbox dev check` pass.
5. A live restart-free soak longer than the July 10 failure interval is the non-blocking live-proof
   axis over Sprint `2.31`'s landed bounded runtime.

### Remaining Work

- None on the code-owned surface. The live restart-free soak longer than the July 10 failure
  interval remains a non-blocking Standard-O proof axis.

## Sprint 5.17: Retained SES Test-Preparation Plan [✅ Done]

**Status**: Done (2026-07-10)
**Implementation**: `src/Prodbox/TestRestore.hs`, `src/Prodbox/TestPlan.hs`,
`src/Prodbox/TestRunner.hs`, `src/Prodbox/Infra/AwsSesStack.hs`,
`src/Prodbox/Prerequisite.hs`, `src/Prodbox/EffectInterpreter.hs`,
`test/unit/RetainedSesPreparation.hs`, `test/unit/RetainedSesTargetRecovery.hs`,
`test/unit/AwsSesLifecycle.hs`, and `test/unit/Main.hs`
**Live-proof**: pending (non-blocking, Standard O) — clean-state invite preparation on live home
and AWS targets; a fresh deployed run through Sprint `8.10`'s landed semantic readiness boundary
remains the Phase-`8` live-proof axis
**Independent Validation**: pure home/AWS/non-invite projections, an injected readiness plus
registered-ensure interpreter, the real Phase-`4.47` target-commit/recovery interpreters over two
fake observable sinks, and explicit target-selection tables prove the code-owned surface without
AWS or Phase `8` live infrastructure.
**Docs to update**: `documents/engineering/integration_fixture_doctrine.md`,
`documents/engineering/prerequisite_doctrine.md`,
`documents/engineering/aws_integration_environment_doctrine.md`,
`documents/engineering/unit_testing_policy.md`

### Objective

Derive long-lived SES preparation from suite capabilities. Every invite-capable suite visibly
reconciles the registered `aws-ses` resource after gateway/Vault/object-store readiness and before
SMTP sync; unrelated suites do not touch SES, and ordinary postflight never destroys it.

### Deliverables

- ✅ Derive `SesRequired` purely from the selected validation set (`ValidationKeycloakInvite`), not
  from substrate identity or ambient stack presence.
- ✅ Extend the typed preparation/restore plan with an opaque nested plan carrying the typed target
  gateway object-store precondition and visible acquire/reconcile/await-ready/sync/release trace.
  Its injected interpreter owns only the readiness observation and one registered atomic ensure;
  the Phase-`4.47` transaction retains the acquire/release bracket and canonical idempotent
  reconcile, so absence and drift converge through one path.
- ✅ Order the fragment after the gateway object-store round trip and before Keycloak SMTP sync and
  dependent chart reconciliation. A failed ensure/readiness step prevents SMTP/chart mutation.
- ✅ Carry the retained control-plane checkpoint authority and selected target-cluster secret sink as
  distinct typed inputs: reconcile/read `aws-ses` through the former, then materialize SMTP KV into
  the latter. Never infer long-lived checkpoint coordinates from the active substrate or ambient
  port-forward environment.
- ✅ Interpret target SMTP sync through Sprint `4.47`'s global commit-intent protocol; a fake plan for
  two concurrent invite runs targeting different sinks must resolve the older nonterminal intent
  before either a new credential generation or a successor sink write is admitted.
- ✅ Preserve `aws-ses` on success, failure, timeout, and interruption. The existing per-run stack
  cleanup remains unchanged.
- ✅ Keep prerequisite nodes read-only: they classify the post-reconcile external state and never hide
  the resource mutation inside a prerequisite effect.
- ✅ The landed Sprint-`8.10` integration preserves the plan shape while strengthening the existing
  await-ready stage: each bounded attempt first proves the complete registered provider inventory,
  including the Pulumi-owned S3 canary, then classifies exact sender/DKIM, MX/rule, and capture
  list/get semantics. Capture probes use the operational credential consumed by invite polling;
  `Failed` and `Unobservable` stop before SMTP sync, while only propagation `Pending` retries.

### Validation

1. ✅ Focused Sprint-`5.17` plan/recovery tests pass 10/10: home/AWS place one equal nested plan,
   non-invite sets place none, target readiness precedes exactly one registered ensure, failures
   block dependent charts, different-sink recovery resolves/read-backs before new generation/write,
   and unobservable recovery fails closed.
2. ✅ Explicit SES target-selection API tests pass 6/6; the real Phase-`4.47` global target-commit
   suite passes 12/12.
3. ✅ Full unit passes 1508/1508; installed-binary CLI and env integration commands each pass the
   complete 47/47 built-frontend suite.
4. ✅ `prodbox dev docs check`, `prodbox dev lint docs`, `git diff --check`, and the final
   `prodbox dev check` pass.

### Remaining Work

- None on Sprint `5.17`'s code-owned surface.
- 🧪 Live-proof pending (non-blocking, Standard O): clean-state invite preparation on deployed home
  and AWS targets through the landed Sprint-`8.10` classifier. This remains a Phase-`8` live-proof
  axis, not remaining Sprint-`5.17` work or a backward blocker.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/unit_testing_policy.md` - runtime-stability and retained-preparation proof
  categories.
- `documents/engineering/bootstrap_readiness_doctrine.md` - point readiness versus the run-scoped
  runtime observer and planned-rollout pause boundary.
- `documents/engineering/resource_scaling_doctrine.md` - plan-derived runtime warning/failure
  thresholds remain separate from authored resource-envelope validation.
- `documents/engineering/integration_fixture_doctrine.md` - retained ensure versus per-run destroy.
- `documents/engineering/prerequisite_doctrine.md` - SES checks remain read-only after visible
  preparation.
- `documents/engineering/aws_integration_environment_doctrine.md` - invite-capability selection and
  preparation order.

**Product docs to create/update:**

- `README.md` - Sprints `5.16`/`5.17` closure, the subsequently closed Phase-`8`
  semantic-readiness handoff, and its non-blocking live-proof axis.

**Cross-references to add:**

- Link Sprint `5.16` to Sprints `1.60`/`2.31` and Sprint `5.17` to Sprints `4.47`/`8.10` without
  creating backward blockers.

## Sprint 5.18: Capability-Bound Preparation and Always-Run Cleanup DAG [⏸️ Blocked]

**Status**: Blocked
**Deployment qualification**: pending
**Implementation**: planned revisions to `src/Prodbox/TestRestore.hs`, `TestPlan.hs`,
`TestRunner.hs`, `Prerequisite.hs`, a retained `CleanupRun` journal/client, the EffectDAG cleanup
projection, installed-binary fixtures, and focused pure plan tests
**Blocked by**: Sprint `4.50`
**Independent Validation**: pure plan/property tests and fake capability clients prove exact-handle
binding and always-run cleanup after every injected failure without a live cluster, AWS, or a later
phase.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/prerequisite_doctrine.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/integration_fixture_doctrine.md`,
`documents/engineering/unit_testing_policy.md`, and
`documents/engineering/effectful_dag_architecture.md`

### Objective

Make test preparation execute only through the exact capability references it observes and make every
registered cleanup obligation run even when preparation, validation, restoration, or another
cleanup node fails.

### Deliverables

- Replace separately supplied endpoint labels/probe actions with the canonical indexed references,
  such as `CapabilityRef 'LifecycleSubmit`, `CapabilityRef 'TargetSecretCasReadBack`, and
  `CapabilityRef 'GatewayPeerExchange`. Each requested program uses its one exact reference for
  admission and execution; no parallel handle family exists.
- Compile preparation from validation requirements into a typed DAG. Retained SES preparation
  depends on Lifecycle Authority admission and the selected Target Secret Agent; it never depends
  on the target gateway.
- Before the first mutation, commit the complete cleanup DAG, canonical digest, and stable per-node
  operation IDs to the Lifecycle Authority's primary-plus-backup-receipted `CleanupRun` namespace.
  It durably records the primary suite outcome; owner-lease expiry records `RunnerLost` if no result
  arrived. A fenced recovery worker scans/resumes every nonterminal run in the authority scope
  before any new run can mutate. Node outcomes are CAS/idempotent; terminal runs compact only to a
  primary+backup immutable report blob plus a non-reusable tombstone after the retention window,
  while nonterminals are never evicted. An in-memory finalizer alone is not cleanup ownership.
- Make EKS drain return its typed result to that DAG. AWS `DrainSkipped`/`DrainFailed` remains a
  cleanup failure, while a `RequiresAttempt` edge still runs last-resort provider destroy; neither
  outcome overwrites the other.
- Preserve the primary suite failure while accumulating every cleanup/restoration failure in a
  structured report. Cancellation begins cleanup under a bounded shield rather than skipping it.
- Restore the canonical platform and all selected charts independently of retained-resource
  operation outcome; destroy per-run AWS stacks/EBS and IAM in authority-safe order and re-observe
  every owned resource class.
- Model consumer lifetime in cleanup: home A record/Certificate plus home Gateway-DNS/DNS01 and TLS-
  retention identities remain LongLived with the restored home edge; AWS A/Certificate/Challenge/
  DNS01 are run-scoped. Exact TLS retention/restore read-back precedes any issuance, and ordinary
  postflight cannot delete credentials or records required by live restored consumers.
- Register the deterministic account/zone/FQDN/type intent for every cert-manager DNS01 Challenge
  before issuance. Cleanup deletes Certificate/Challenge resources while cert-manager is live,
  then observes every registered TXT coordinate absent; a tag/pattern sweep or unobservable record
  cannot close the node.
- Move the mutating Route 53 hosted-zone capability canary out of prerequisites into visible
  preparation. Before create, register account/region/caller-reference/name/operation; recover a
  lost response by caller reference, then CAS-enrich the AWS-assigned zone ID before dependent
  mutation. Cleanup uses that exact ID, aggregates failure/cancellation, reads back deletion, and
  removes the `awsCreateProbeVerbs` lint carve-out.

### Validation

1. Plan properties prove no execution coordinate exists outside its capability reference and an AWS
   target cannot authorize a retained-home operation.
2. Failure injection at every plan node plus runner SIGKILL/restart proves every eligible cleanup
   operation converges exactly once by stable operation ID and failures accumulate deterministically.
3. Cancellation/owner-expiry fixtures prove `RunnerLost`, preflight takeover before any successor
   mutation, durable primary/failure aggregation, terminal report compaction, and no new foreground
   work after cancellation.
4. Installed-binary fake home/AWS traces prove identical suite content with substrate-specific
   capability providers and no fallback.
5. Unit/CLI/env integration suites and `prodbox dev check` pass.

### Remaining Work

- Blocked until Sprint `4.50` makes the new authority and target clients the sole supported path.
- Sprint `5.19` adds temporal load and fault qualification over this plan.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_control_plane_architecture.md` - suite capability composition
  and cleanup topology.
- `documents/engineering/prerequisite_doctrine.md` - exact-handle prerequisites.
- `documents/engineering/bootstrap_readiness_doctrine.md` - capability admission versus component
  liveness.
- `documents/engineering/integration_fixture_doctrine.md` - failure-injection boundaries.
- `documents/engineering/unit_testing_policy.md` - plan and cleanup property requirements.
- `documents/engineering/effectful_dag_architecture.md` - always-run cleanup lowering.

**Product docs to create/update:**

- `README.md` - restoration and cleanup guarantee.

**Cross-references to add:**

- Link cleanup resource classes to the managed-resource registry and substrate inventory.

## Sprint 5.19: Temporal Load, Fault, and Cleanup Qualification Oracle [⏸️ Blocked]

**Status**: Blocked
**Deployment qualification**: pending
**Implementation**: planned `src/Prodbox/Test/TemporalQualification.hs`, extensions to
`GatewayRuntimeStability.hs`, TestRunner structured observers, fake cgroup/metrics fixtures, and
installed-binary fault scenarios, including named regression `LCPC-2026-07-11`
**Blocked by**: Sprint `5.18`
**Live-proof**: pending after code-local implementation; current-revision deployment
qualification is tracked separately from phase status
**Independent Validation**: deterministic metrics streams, fake Kubernetes/cgroup payloads,
virtual clocks, and installed-binary fault fixtures validate the oracle without live
infrastructure or a later phase.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/unit_testing_policy.md`,
`documents/engineering/chaos_hardening_doctrine.md`,
`documents/engineering/resource_scaling_doctrine.md`, and
`documents/engineering/integration_fixture_doctrine.md`

### Objective

Observe temporal service health, not only point readiness or memory containment, and produce
absorbing evidence for saturation, missed deadlines, authority loss, cancellation, and incomplete
cleanup across the whole suite run.

### Deliverables

- Classify per-service CPU throttling, runnable saturation, queue depth/wait, admission rejection,
  operation latency, p95/p99 budget, deadline miss, cancellation lag, session refresh failure,
  restart/OOM, and unobservable telemetry through exhaustive typed observations.
- Keep run-wide absorbing unhealthy evidence across Pod UID replacement and planned rollout;
  maintain separate restartable recovery windows without erasing prior failure.
- Record Lifecycle Authority operation/journal progress and Target Agent delivery convergence while
  gateways are killed or saturated.
- Add deterministic fault schedules for delayed MinIO/Vault, applied-but-response-lost CAS, client
  cancellation, gateway loss during retained work, authority restart, and cleanup failure.
- Add `prodbox test integration control-plane-counterexample` for counterexample
  `LCPC-2026-07-11`. It consumes Sprint `4.50`'s frozen, digest-bound pre-cutover trace/simulator;
  deleted production routes are never retained or re-enabled for the test. The causal profile
  keeps the same authored load/fault schedule and the same topology-normalized total CPU/memory/
  ephemeral/persistence budget: the superseded allocation includes the three 250m Gateway CPU
  limits, while the separated roles only repartition that total. It exercises the absent-GET/
  authority-CAS mismatch, CPU throttling/deadline overrun, AWS-target versus retained-home endpoint
  mismatch, response-lost retained operation, and sibling-restore skip. A separate production
  profile then validates the independently justified rendered envelopes. Both old/new results and
  their separate complete identities remain after legacy code deletion.
- Emit a typed qualification artifact containing distinct frozen-superseded and replacement
  identities. Each binds `SourceIdentity`: Git HEAD, clean/dirty flag, a source-manifest policy
  identifier/version/canonical-policy digest, and the resulting deterministic path/type/mode/content
  manifest digest. The policy allowlists code, governed documentation, and non-secret schema/
  template inputs, including relevant untracked inputs only when allowlisted; it unconditionally
  excludes `test-secrets.dhall`, local/generated secret material, secret roots, and runtime/build
  roots. Each identity also binds a canonical non-secret generated-config projection, component-image
  digests, resolved topology/wiring digest, resource-envelope digest, and authored-load/fault digest.
  Secret-dependent execution is represented only by opaque Authority receipt/generation IDs or
  keyed HMAC commitments produced under a Vault-held key. No manifest, config digest, or evidence
  digest ingests or publicly raw-hashes plaintext secrets. The artifact also contains substrate,
  canonical commands, normalized old→new envelope mapping, production resource envelopes/load,
  counterexample ID/results, complete fault matrix, aggregate results, cleanup/residue result,
  start/completion timestamps, and an evidence digest over only the public/redacted fields. The
  top-level deployment-qualification axis consumes it; phase `Done` never implies it.

### Validation

1. Table fixtures cover every observation and boundary threshold, including absent/unobservable
   telemetry.
2. Queue/latency streams prove transient recovery cannot erase an earlier temporal violation.
3. The named counterexample verifies the frozen superseded signature and closes every signature
   against the replacement under identical topology-normalized total budget/load, then passes the
   production-envelope profile without substituting that result for causal equivalence.
4. Installed-binary scenarios exercise each fault schedule and verify the exact operation outcome
   plus cleanup report.
5. The oracle refuses a missing/stale source manifest, exclusion-policy identifier/version/digest,
   or field in either complete identity; a policy/manifest mismatch; a Git-HEAD-only dirty identity;
   or an identity reused for both sides.
6. Negative fixtures prove `test-secrets.dhall`, local/generated secret material, secret roots, and
   runtime/build roots cannot enter either manifest or public evidence digest. They also reject a
   plaintext-secret digest or public raw hash where an opaque Authority receipt/generation ID or
   Vault-keyed HMAC commitment is required, plus missing old/new counterexample results or incomplete
   substrate/fault/aggregate/cleanup/timestamp fields.
7. Unit/CLI/env integration suites and `prodbox dev check` pass.

### Remaining Work

- Blocked until Sprint `5.18` supplies exact capability binding and always-run cleanup.
- Live home/AWS campaigns remain a separate deployment-qualification axis after code closure.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_control_plane_architecture.md` - qualification evidence model.
- `documents/engineering/unit_testing_policy.md` - temporal/fault fixture requirements.
- `documents/engineering/chaos_hardening_doctrine.md` - mandatory fault matrix.
- `documents/engineering/resource_scaling_doctrine.md` - CPU/queue/latency SLO evidence.
- `documents/engineering/integration_fixture_doctrine.md` - deterministic fault injection.

**Product docs to create/update:**

- `README.md` - deployment-qualification status and evidence command.

**Cross-references to add:**

- Link the qualification artifact to Standard O's scoped phase-completion rule and the separate
  deployment-qualification standard.

## Sprint 5.20: Derived Restore Graph and Total Executor [📋 Planned]

**Status**: Planned
**Deployment qualification**: pending
**Implementation**: planned `src/Prodbox/Lifecycle/RestoreGraph.hs`; revisions to
`src/Prodbox/TestRestore.hs` and `src/Prodbox/TestRunner.hs`
**Independent Validation**: pure coverage/independence/orphan-scan suites that fail against the
current flat-list wiring and pass against the derived graph; executor totality property with a fake
interpreter; all pre-cluster.
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/integration_fixture_doctrine.md`, and
`documents/engineering/unit_testing_policy.md`

### Objective

Close the `F-RESTORE` class of counterexample `LCPC-2026-07-11` structurally. The restore cycle is
today a flat ordered step list executed by a fail-fast fold: the first failure silently discards
every later step, including chart restorations wholly independent of the failed sibling, and
independence exists only as a comment. Dependency structure must be derived data, not list
position.

### Deliverables

- Represent restore/cleanup as a graph of nodes whose `RequiresSuccess`/`RequiresAttempt` edges are
  derived from chart-dependency and storage-lifetime fact tables rather than authored per-site.
- Replace the fail-fast fold with a total executor that runs every node whose dependencies are
  satisfiable, records `NodeBlocked` with the offending ids otherwise, aggregates all failures into
  one structured report, and never silently discards a step.
- Prove the totality obligations as pure checks: node-set coverage equals the derived expectation
  for every input; no `RequiresSuccess` path exists from the independent chart restorations to the
  retained-SES node; and an orphan scan proves no node reads retained-or-stronger state through a
  chart-lifetime transport that the same graph deletes.

### Validation

1. Pure coverage/independence/orphan-scan suites fail against the current flat-list wiring and pass
   against the derived graph.
2. An executor-totality property with a fake interpreter proves every satisfiable node runs and
   every failure lands in the aggregate report.
3. All proofs run pre-cluster; unit/CLI/env integration suites and `prodbox dev check` pass.

### Remaining Work

- Implementation is planned; the code-owned closure needs no live cluster (Standard O).
- Sprint `5.18` remains separately blocked by Sprint `4.50` and later composes its capability-bound
  cleanup DAG over the same restore surface; the Foundation Epoch introduces no `Blocked by` edge
  between them.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_reconciliation_doctrine.md` - derived restore/cleanup edges,
  total-executor doctrine, and lifecycle-class verb obligations.
- `documents/engineering/integration_fixture_doctrine.md` - fixtures for graph coverage,
  independence, and orphan scans.
- `documents/engineering/unit_testing_policy.md` - restore-graph totality suites in the
  conformance tier.

**Product docs to create/update:**

- `README.md` - restoration runs as a derived total graph with an aggregate failure report.

**Cross-references to add:**

- Link the derived fact tables to the managed-resource registry lifecycle classes and the
  storage-lifetime index owned by Sprint `4.51` (no `Blocked by` edge).

## Sprint 5.21: Measured Resource Profile Recorder [🔄 Active]

**Status**: Active (Sprint `1.65` unblocked; the pure recorder gate landed 2026-07-12, the live
metric sampling + first committed profile remain)
**Deployment qualification**: The pure recorder gate is landed and unit-proven pre-cluster.
Standard O: recording the first committed gateway profile requires a healthy live ≥30-minute run
(and extending the gateway-runtime-stability observer to sample CPU/throttle/heap/object-store
demand), so the live `--record-profile` wiring + the first artifact are the non-blocking live axis.
**Implementation**: ✅ **Recorder gate landed** — `recordMeasuredProfile` (the pure health +
30-minute-steady-window gate over a `MeasuredProfileRecorderInput`, refusing an unhealthy run or a
short window), `recorderMinimumWindowSeconds`, `renderMeasuredResourceProfileDhall` (the committed
`dhall/capacity/measured/` artifact literal that round-trips back through the generic
`Dhall.FromDhall` the Sprint 1.65 check reads), and the `MeasuredProfileRecorderRefusal` taxonomy,
all in `src/Prodbox/Capacity/MeasuredProfile.hs`. 🔄 **Remaining**: the live `--record-profile`
metric collection (extending `src/Prodbox/Test/GatewayRuntimeStability.hs` to sample the demand the
profile carries) and committing the first gateway profile from a healthy live run.
**Independent Validation**: ✅ recorder refusal tables (unhealthy run, short window) and a Dhall
round-trip proving the recorded artifact is exactly what the certification check consumes
(`test/unit/MeasuredProfile.hs`, "Sprint 5.21 measured profile recorder gate"); pre-cluster. The
first committed profile activates the Sprint 1.65 certification for `gateway`.
**Docs to update**: `documents/engineering/resource_scaling_doctrine.md`

### Objective

Close the measurement loop opened by Sprint `1.65`: authored Guaranteed-QoS envelopes are certified
against committed measured profiles, and this sprint produces those profile artifacts from real
healthy suite runs. The recorded profile also evidences the hot-path CPU reduction delivered by
Sprints `1.64` and `1.66`.

### Deliverables

- A `--record-profile` mode of the gateway-runtime-stability suite that writes the committed
  `MeasuredResourceProfile` artifact only from a healthy run with at least a thirty-minute steady
  window.
- The first committed gateway profile, which activates the Sprint `1.65` certification check.

### Validation

1. Recorder refusal tables with fixture payloads prove an unhealthy run or a short window cannot
   write a profile artifact.
2. An artifact golden pins the committed profile shape.
3. All proofs run pre-cluster; unit/CLI/env integration suites and `prodbox dev check` pass.

### Remaining Work

- Blocked until Sprint `1.65` lands the `MeasuredResourceProfile` type and certification check.
- Recording the first committed gateway profile requires a healthy live run; until it lands, the
  interim authored gateway envelope remains uncertified-until-first-profile.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/resource_scaling_doctrine.md` - recorder gate (healthy run, thirty-minute
  steady window) and the bootstrap rule for the first committed profile.

**Product docs to create/update:**

- `README.md` - note when the first committed gateway profile activates capacity certification.

**Cross-references to add:**

- Link the recorder to Sprint `1.65`'s certification check and the `dhall/capacity/measured/`
  artifact home ([phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md)).

## Sprint 5.22: Certificate Scope Serving Validation [⏸️ Blocked]

**Status**: Blocked
**Blocked by**: Sprint `2.35`
**Deployment qualification**: pending
**Implementation**: planned named integration validation exercising real TLS handshakes
against every scope-covered hostname
**Independent Validation**: the validation runs on the home substrate with harness-owned
infrastructure and a real ZeroSSL DNS-01 certificate; AWS-substrate coverage is tracked in
substrates.md parity (Standards N/O). Ready-condition alone is not accepted as proof.
**Docs to update**: `documents/engineering/acme_provider_guide.md`

### Objective

Prove serving, not assertion. A named validation opens a real TLS handshake against every hostname
the configured `CertScopeSet` covers — each exact scope and, when a wildcard scope is configured, a
wildcard-covered sibling plus the apex through its explicit exact scope — against harness-owned
infrastructure with a real ZeroSSL DNS-01 certificate, and adds a retained restore-vs-reissue proof
(widening triggers one fresh ACME order; a narrower-or-equal scope reuses the retained material). A
cert-manager Ready condition alone is not accepted as proof.

### Deliverables

- A named integration validation that curls every hostname the configured scope set covers over TLS
  (exact scopes always; wildcard-covered siblings and the apex when a wildcard scope is configured)
  and fails if any covered host does not serve the scope certificate.
- A retained restore-vs-reissue proof keyed by `impliedBy` and the canonical scope-set
  serialization: widening the configured scope orders once, and a narrower-or-equal scope reuses the
  retained material.
- Home-substrate serving proof against harness-owned infrastructure with a real ZeroSSL DNS-01
  certificate; AWS-substrate parity tracked as the non-blocking axis in
  [substrates.md](substrates.md).

### Validation

1. The named validation performs a real TLS handshake against every scope-covered hostname and fails
   if any covered host does not serve the scope certificate — the cert-manager Ready condition alone
   is not accepted.
2. The restore-vs-reissue proof shows a widening scope orders exactly once and a narrower-or-equal
   scope reuses retained material.
3. The home-substrate run uses harness-owned infrastructure and a real ZeroSSL DNS-01 certificate;
   AWS-substrate coverage is the non-blocking parity axis in [substrates.md](substrates.md)
   (Standards N/O).

### Remaining Work

- Blocked until Sprint `2.35` lands the `CertScope` algebra, the Tier-0 scope-set config, and the
  derived edge projections it validates.
- The live AWS-substrate serving proof is the non-blocking substrate-parity axis tracked in
  [substrates.md](substrates.md); it is not a `5.22` blocker (Standards N/O).

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/acme_provider_guide.md` - the certificate-scope serving validation and its
  retained restore-vs-reissue proof as the canonical-suite consumer of the configured `CertScopeSet`.

**Product docs to create/update:**

- `README.md` - note that the canonical suite proves serving on every hostname the configured
  certificate scope covers.

**Cross-references to add:**

- Link the serving validation to the `CertScope` algebra owned by Sprint `2.35`
  ([phase-2-gateway-dns.md](phase-2-gateway-dns.md)) and the AWS-substrate parity axis in
  [substrates.md](substrates.md).

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [substrates.md](substrates.md)
- [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md)
- [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md)
- [Integration Fixture Doctrine](../documents/engineering/integration_fixture_doctrine.md)
- [Prerequisite Doctrine](../documents/engineering/prerequisite_doctrine.md)
