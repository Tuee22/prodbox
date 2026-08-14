# Phase 5: Canonical Test Suite

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Own the substrate-agnostic canonical test suite — the named-validation set in
> `src/Prodbox/TestValidation.hs` — as suite content with declared prerequisites. Substrate
> provision and teardown belong elsewhere (see [substrates.md](substrates.md) and the
> substrate-owning phase docs); this phase owns what the suite proves and how.

## Phase Status

✅ **Reclosed 2026-08-09 on Sprint `5.31`.** Integration went **20 of 55 failing → 8 → 4 →
0**, and the installed `cli`/`env` suite now passes **55/55**. The canonical `prodbox test unit`
command exits 0 with the main Hspec inventory at **3255/3255**. Clean-room home and AWS
deployment qualification remains pending on the separate Standards O/P axis.

`5.30` landed the fixture half: four hand-written Tier-0 Dhall encoders reduced to the one canonical
`renderProjectConfigDhall` (a record with one decoder and four encoders is three hand-maintained
restatements that a type tightening makes wrong rather than updates —
[chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md)), the
fixture decode failure kept as a typed value instead of an `ioError` escaping before any byte is
written, and `--enable-tests` on the canonical build so its region covers this phase's evidence
surface.

`5.31` closed the chain underneath, whose links were invisible until the one above each was fixed. A
discarded `AdmissionRefusal` (`refuse _ = ExitFailure 1`) made eight cases exit 1 in silence; the
refusal now leaves as itself, which is § 23 at the step boundary. Making it speak named a Phase-`4`
production defect in one run — admissions reset at every phase boundary, closed as Sprint `4.61`.
Three fixture drifts sat under that, ending in the capacity drift this phase had registered as
"currently silent": the fake LimitRange declared the gateway at 250m where the plan projects 750m.
The fixture's observed cluster state now renders from the same projection the validator compares
against. The final four failures were corrected against their actual source-level causes: exact
gateway replica cardinality, primary-image retry semantics, the derived Dhall union shape, and a
valid prerequisite fixture for the named Credential-Provisioner refusal. The own-surface reopen is
closed (Standard A), and prior reclosures stand.

✅ **Reclosed 2026-08-08 on Sprint `5.29`** — the last Sprint-`5.18` deliverable that had been
recorded as complete and never built is now built. The DNS01 challenge coordinate is a registered
managed resource with a production consumer, its deletion is an always-run cleanup node
(`CleanupRequiresAttempt`, because the failure case is the one that leaves residue), and absence is
proven by an exact `_acme-challenge` TXT read-back in which "cannot observe" is a distinct
constructor that keeps the gate closed. Two of the sprint's own premises were corrected against
source in the same pass: prodbox never writes the record (cert-manager's Route 53 solver does), and
the Challenge UID cannot exist at registration time, so the coordinate is registered pre-issuance
and the UIDs attach afterwards as evidence. Wiring the registry entry's two injected boundaries to
the live issuance flow is a 🧪 Standard-O step, not a code-owned gap. Phase `5` has no open sprints.

✅ **Reclosed 2026-08-04 on Sprint `5.27`** — own-surface reopen (Standard A/N) implementing the two
Sprint `5.23` fixture deliverables that were never built: cleanup now acquires the broker's terminal
shutdown witness or fails with typed residue instead of discarding a second timeout, and the
run-final residue oracle has a real consumer. It also corrects their Standard-O misclassification —
an in-process STM runtime over a loopback port is not live infrastructure, and labelling it so parked
implementable work behind a gate that does not exist. Implementing it immediately surfaced a real
broker shutdown deadlock, fixed on Phase 2's surface by Sprint `2.38`.

✅ **Reclosed 2026-08-03 on Sprint `5.26`** — own-surface reopen (Standard A/N) replacing canonical
suite fixture values that imitated real-world data: really routable IPv4 record values, RFC
4122-shaped Kubernetes UIDs, and a plausible delegation-set nameserver, now reserved-range and
descriptive-slug equivalents
([vault_doctrine.md §20.4](../documents/engineering/vault_doctrine.md#204-fixtures-are-synthetic-not-shaped)).
The suite passes unchanged, which is the proof the values were behaviourally inert.

✅ **Sprint `5.25` closed 2026-08-01 on its independently validated typed-readiness surface** (own-surface,
Standard A): the gateway runtime-stability observation type is split so a healthy not-yet-scraped Pod is
a distinct non-terminal observation, never latched fatal — **superseding Sprint `5.24`** (its
observability-wait band-aid is deleted). Code-owned and `dev check`-green (18/18). See
[Sprint 5.25](#sprint-525-typed-three-valued-gateway-readiness-observation-).

✅ **Sprint `5.23` expansion completed after Sprint `2.36`.** The
canonical validation must reproduce forced shutdown under deterministic finalizer stalls and
full-suite scheduler contention, and must fail on any leaked worker, waiter, queue entry, or
idempotency record. One hundred isolated focused passes do not close a source-reachable illegal
transition.

✅ **Foundation Epoch expansion completed.** Counterexample `LCPC-2026-07-11` froze four
aggregate-suite failure mechanisms; this phase gains the two suite-side structural owners, adopted
by governance Sprint `0.17` ([phase-0-planning-documentation.md](phase-0-planning-documentation.md)).
Sprint `5.20` closes the `F-RESTORE` class: restore/cleanup becomes a graph whose
`RequiresSuccess`/`RequiresAttempt` edges are derived from chart-dependency and storage-lifetime
fact tables, executed by a total executor that aggregates every failure and never silently discards
an independent restoration. Sprint `5.21` closes the measurement
loop: a `--record-profile` mode of the gateway-runtime-stability suite writes the committed
`MeasuredResourceProfile` artifact from a healthy run, and the first committed gateway profile
activates the Sprint `1.65` certification check. The Foundation Epoch (Sprints `1.63`–`1.66`,
`2.34`, `4.51`, `5.20`, `5.21`, and `7.34`) completed before Sprints `1.61` and `1.62` as an
execution-priority decision and introduced no `Blocked by` edge onto the existing `1.61` →
`8.12` chain. Sprints `5.18`, `5.19`, `5.21`, and `5.22` are Done.

✅ **Certificate-scope serving validation completed in Sprint `5.22`.** The named integration
validation proves serving rather than assertion: a
real TLS handshake against every explicit substrate-bound served hostname, inspection that the
presented real ZeroSSL DNS-01 certificate carries the exact configured canonical SAN set, and an
exact-scope retained restore-vs-reissue proof. An unchanged canonical set restores without an
order; each new SAN set receives a distinct retention coordinate and one issuance. `impliedBy`
remains a coverage/admission proof and never substitutes a merely covering certificate. It is the canonical-suite
consumer of the configurable-certificate-scope policy adopted by governance Sprint `0.18`
([phase-0-planning-documentation.md](phase-0-planning-documentation.md)) and the scope algebra owned
by Sprint `2.35` ([phase-2-gateway-dns.md](phase-2-gateway-dns.md)); it is not part of the Foundation
Epoch and introduces no `Blocked by` edge onto the existing `1.61` → `8.12` chain.

✅ **Reclosed 2026-08-02 on Sprint `5.22`.** Sprint `5.18` makes restore and retained
preparation consume the same exact capability references that execution uses and lowers cleanup to an
always-run DAG, so an unrelated selected-target probe cannot authorize retained-authority work and
one failure cannot skip independent restoration. Sprint `5.19` adds temporal
load/fault evidence for CPU throttling, admission queues, deadlines, cancellation, and cleanup.
Earlier point-readiness and restart/OOM evidence remains useful but is not the expanded temporal
qualification.
Sprint `5.21` adds the live, fail-closed calibration recorder and secret-free empirical artifact;
the first real 30-minute capture remains the non-blocking live-proof axis. Sprint `5.22` supplies
the exact certificate-scope serving validation on the code-owned surface; its live serving proof
remains a non-blocking Standards O/P axis.

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
| `charts-platform` | cluster | supported chart registry/status and platform behavior |
| `resource-guardrails` | cluster | declared pod resources, quotas/limits, and pre-mutation over-budget refusal |
| `daemon-bootstrap` | live Bootstrap Broker route surface, or a named repository fixture | supported daemon-mediated bootstrap/object-store transport and redaction. Sprint `5.33`: the unset arm probes the broker read-only and refuses when no daemon answers; it no longer emits a canned audit. The emitted block declares `AUDIT_PROVENANCE=`. |
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

**Independent Validation** (Standard N — see
[development_plan_standards.md](development_plan_standards.md) Standards N/O): this phase is
validatable in full on its owned surface — the named-validation set in
`src/Prodbox/TestValidation.hs`, its plan in `src/Prodbox/TestPlan.hs`, the runner in
`src/Prodbox/TestRunner.hs`, and the prerequisite DAG in `src/Prodbox/Prerequisite.hs` — with no
dependency on any later phase. Closure is `prodbox dev check`, `prodbox test unit`, and the installed
`prodbox test integration cli` / `env` suites; where a validation would touch Route 53, a deployed
cluster, an unsealed Vault, or live AWS, it runs on the home/local substrate or against a fake, and
the live exercise is a non-blocking `Live-proof: pending` axis rather than `⏸️ Blocked`. Per-substrate
AWS coverage of a suite-content validation is tracked in [substrates.md](substrates.md) and never
marks this phase or its sprints `Blocked` (Standard M, "suite-content closure is
home-substrate-scoped").

*Added 2026-08-11:* this document was the only phase file without a document-level
`**Independent Validation**` line, which Standard N requires of every phase document; the first
occurrence had been inside Sprint `5.8`'s block.

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
`3.22`, and `4.41`. Once the resource-governance sprints land, the namespace oracle asserts the
observed cluster `ResourceQuota`/`LimitRange` JSON against the **same** shared `Prodbox.Capacity.Render`
functions the chart platform renders from (Sprint `3.28`) — one renderer, byte-identical on both sides
— rather than a validation-local expected-value oracle, so this validation confirms
observed-equals-rendered instead of re-deriving the ceiling. The "namespace quota below its workloads'
draw" case is then no longer a runtime string comparison here: it is a **compile-time** refusal in the
derived-quota proof (Sprint `3.27`), which makes an under-provisioned quota unrepresentable before any
render or mutation. This sprint stays code-owned and home-substrate-scoped (Standard M); AWS parity of
the same validation is tracked in [substrates.md](substrates.md), never as a blocker.

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
6. 📋 Once the resource-governance sprints land, the namespace oracle asserts the observed cluster
   `ResourceQuota`/`LimitRange` JSON against the **same** shared `Prodbox.Capacity.Render` functions the
   chart platform renders from (Sprint `3.28`) — byte-identical on both sides — instead of a
   validation-local expected-value oracle, and the "namespace quota below its workloads' draw" fixture
   becomes a **compile-time** refusal in the derived-quota proof (Sprint `3.27`) rather than a runtime
   string comparison. This validation then confirms observed-equals-rendered on the home substrate
   (Standard M); AWS parity in [substrates.md](substrates.md).

### Remaining Work

- 🧪 Live-proof (non-blocking, Standard O): run the optional real over-limit pod stress proof on a
  disposable home substrate and the AWS `--substrate aws` parity row once the AWS substrate is
  provisioned. The code-owned command/planner/body/oracle surface is complete.
- 📋 Sprints `1.68`/`3.27`/`4.52` strengthen this validation's contract: over-reserved host, namespace
  quota overcommit, and observed-host over-commit move from a runtime `Either` refusal to a compile-time
  `AllocatedResourcePlan` impossibility, and the namespace `ResourceQuota` becomes a derived projection
  of workload draws. When they land, the negative-config fixtures here are retargeted to prove the
  compile-time rejection; no new Phase-5 sprint is required unless the oracle fixtures change materially.

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

### Correction To This Sprint's Own Validation (Standard C)

**Recorded 2026-08-11.** This sprint's Validation section rests entirely on
`prodbox test integration daemon-bootstrap`, and that node observes nothing on the path it actually
takes:

```haskell
-- File: src/Prodbox/TestValidation.hs
  fixture <- lookupEnv "PRODBOX_TEST_DAEMON_BOOTSTRAP_AUDIT"
  case fixture of
    Nothing     -> emitDaemonBootstrapAudit defaultDaemonBootstrapAuditInput
    Just "pass" -> emitDaemonBootstrapAudit defaultDaemonBootstrapAuditInput
```

The unset arm — the one CI and a bare invocation take — is byte-identical to the `"pass"` fixture
arm, and `DAEMON_AVAILABLE=true` is a literal inside `defaultDaemonBootstrapAuditInput`. The
deliverables claim "a transport-use oracle that fails on observed `kubectl port-forward` invocation"
and "negative proof that an unavailable daemon fails with a daemon-actionable error"; both negative
behaviours exist only as separate string-keyed fixture branches that nothing on the default path
selects. The validation's `-> []` prerequisite registration and its in-plan description as "a
code-owned transport oracle" are honest — what is over-claimed is that running it establishes the
transport property.

**Resolved by Sprint `5.33` ✅ (2026-08-11).** The unset arm now probes the Bootstrap Broker's own
route surface — read-only `GET`s against every required route, where a served route answers
something other than `404` — and builds the audit from what answered. Where no daemon answers it is
a typed refusal naming the absent daemon and the address probed, per
[bootstrap_readiness_doctrine.md § 0.5](../documents/engineering/bootstrap_readiness_doctrine.md).
The emitted block gained `AUDIT_PROVENANCE=`, so an `observed-daemon` claim and a `fixture:` claim
are distinguishable in the evidence rather than only in the source, and `DAEMON_AVAILABLE`,
`LEGACY_TRANSPORTS`, `HOST_ROOT_TOKEN_FALLBACKS`, and `REDACTION` are rendered from the computed
values.

**What this changes about step 2 above.** It does not restore the claim; it narrows it correctly.
Steps 2–4 were run against the `"pass"` fixture arm, which is unchanged and still real: it proves
the *oracle* — that a trace containing a legacy transport, an unredacted secret, or an unavailable
daemon is refused. They never proved that a live daemon-bootstrap run took only broker transports,
and after `5.33` no run of this node makes that claim implicitly, because a run that measured
nothing refuses instead of passing. The live substrate-parity proof (step 7) remains the Standard-O
axis it always was.

The sprint's structural deliverable is not withdrawn: the daemon-mediated boundary exists and the
audit vocabulary is real. Sprint `5.33` 📋 owns making the unset arm observe or refuse.

**Downstream citations inherit this scope** and are not separately corrected (§ 1 — a fact derivable
from one place is not copied): Sprint `7.30` in
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md), the 2026-07-05
four-phase reclosure row in [README.md](README.md), and the historical entry in
[substrates.md](substrates.md).

### Remaining Work

- 🧪 Live-proof pending (non-blocking, Standard O): AWS/Pulumi object-store parity composes with
  Sprint `7.30`'s code-owned landing and is tracked through [substrates.md](substrates.md), not as
  a backward block.
- The unset-arm observation gap recorded above is owned by Sprint `5.33` 📋.

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

## Sprint 5.18: Capability-Bound Preparation and Always-Run Cleanup DAG [✅ Done]

**Status**: Done — validated 2026-08-02.
**Deployment qualification**: pending
**Implementation**: planned revisions to `src/Prodbox/TestRestore.hs`, `TestPlan.hs`,
`TestRunner.hs`, `Prerequisite.hs`, a retained `CleanupRun` journal/client, the EffectDAG cleanup
projection, installed-binary fixtures, and focused pure plan tests
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

### Closure Evidence

- Validated checkpoint (2026-08-01): `Prodbox.Test.CleanupRun` now supplies the pure retained
  aggregate and bounded canonical codec. Every node plan receives its coordinate digest only from
  an opaque indexed `CapabilityRef`; graph validation refuses empty, duplicate, dangling, self, and
  cyclic plans. The aggregate commits graph/digest/stable operation IDs before work, uses a fenced
  owner lease, records `RunnerLost` and resets only ambiguous in-flight nodes after expiry, preserves
  `RequiresSuccess` versus `RequiresAttempt`, aggregates primary and cleanup failures, makes exact
  begin/complete/primary replay idempotent, and compacts only terminal runs. Its exact-revision
  Model-B repository re-observes an ambiguous CAS response. The authenticated route/client and
  bounded-shield durable executor now commit before the primary action, retain synchronous primary
  failure, run every eligible `RequiresAttempt` successor, aggregate node failures, and rethrow
  cancellation only after cleanup; expired in-flight ownership is reacquired under a greater fence
  before its stable operation is retried. The primary-plus-backup namespace receipt-registers each
  complete immutable plan, repairs an indexed-but-missing primary before recovery, scans every
  uncompacted run, refuses identifier reuse, and accumulates recovery failures. After the retention
  boundary, authenticated compaction copies and re-observes the exact canonical report before CAS-
  publishing digest-only non-reusable tombstones to both the per-run primary and namespace. Scan
  repairs response loss between those two commits, and a repeated compact request re-observes and
  decodes the immutable report instead of treating the tombstone as an error. The managed cleanup
  compiler now binds each interpreter to the same typed capability reference whose digest is
  committed in its node. Command-style non-zero primary exits are now recorded as failures rather
  than successful values. `TestRunner` now places AWS harness setup inside the create-before-primary
  boundary and lowers drain, Vault unseal, the three registry-owned per-run stacks, the EBS reaper,
  and operational teardown into one capability-bound DAG. Every provider cleanup has
  `RequiresAttempt` progress; teardown has `RequiresSuccess` edges from every credential consumer,
  preserving recovery credentials after cleanup failure. Authority-scope recovery uses the
  universal action interpreter before compiling the selected run, so a narrower successor suite
  can still resume an older broader graph. Focused validation passes 20/20 and the TestRunner plan
  suite passes 59/59; the unit
  executable builds warning-clean; and `./.build/prodbox dev check` exits 0 with the namespace,
  endpoint, client, recovery, compaction, tests, and governed documentation included.
- Installed-binary CLI/env fixtures exposed by the Phase-4 closure audit now provide
  the retained Authority/config/capability topology instead of assuming filesystem-authoritative
  runtime config or removed transports. Current checkpoint (2026-08-02): the unmodified
  installed-binary audit reproduced the recorded 28/52 failure baseline. The shared capacity
  fixture now includes all six control-plane roles, the fake Docker boundary returns an immutable
  runtime-image digest, and Haskell fixture servers provide the Broker, Vault, Lifecycle Authority,
  and Authority Backup transports over the real port-forward-selected loopback coordinates. The
  fixture projects an in-force Authority config, healthy retained backup, completed provider
  readiness, absent first-reconcile continuation, Kubernetes TokenRequest/RBAC identity, readable
  kubeconfig, retained backend, and materializer absence/metadata read-backs. The installed-binary
  native RKE2 reconcile/delete proof is green 1/1 (49.49s). The complete CLI audit has improved
  from 28/52 failures to 52/52 passing after these shared repairs; config-only cases reuse the retained
  Authority environment across CLI and env suites. The integration executable runs threaded but
  serially, avoiding the non-threaded descriptor ceiling without racing shared Cabal/build fixtures.
  Closure evidence is the complete installed-binary integration gate 52/52 (383.31s), unit gate
  2992/2992 (35.58s), and `prodbox dev check` exit 0 with no HLint hints and a warning-clean build.

### Remaining Work

**Correction (2026-08-04).** Two of this sprint's deliverables were recorded as closed but were never
built, and the Closure Evidence above does not mention either. Both are now tracked honestly rather
than left implied-complete:

- ✅ **Hosted-zone canary registration.** "Before create, register account/region/caller-reference/
  name/operation … read back deletion, and remove the `awsCreateProbeVerbs` lint carve-out" did not
  land: the carve-out survived, no hosted-zone resource was registered, and the zone was deleted only
  along the validation's own return path with no absence read-back. **Closed by Sprint `5.28`.**
- 📋 **DNS01 Challenge/TXT registration.** "Register the deterministic account/zone/FQDN/type intent
  for every cert-manager DNS01 Challenge before issuance … then observes every registered TXT
  coordinate absent" did not land either. Sprint `4.50` built the descriptor half
  (`mkDns01ChallengeRegistration`, `dnsRecordLifecycleClass`), but it has **no production consumer** —
  its only references are in `test/unit/DnsRecord.hs`. The compiled cleanup DAG emits no
  Certificate/Challenge/TXT node, and no `_acme-challenge` coordinate is ever observed absent. Phase
  `4` explicitly assigns this to Phase 5: "Sprint `5.18` alone owns run-time pre-issuance
  registration, always-run Challenge deletion, and exact TXT absence observation"
  ([phase-4](phase-4-lifecycle-canonical-paths.md)). **Open; split out as Sprint `5.29` on
  2026-08-05 (Sprint `0.21`), which now owns it.** This sprint's remaining deliverables stay closed;
  only this bullet moved. Its original validation items used *"every plan node"* and *"every
  eligible cleanup operation"* with no enumeration and no named test, which is how a deliverable
  that was never built survived a closure — Sprint `5.29` restates them as falsifiable criteria
  over the rendered plan.
  This is code-owned work (a registry entry, a cleanup node, and a TXT read-back over the existing
  descriptor), not a live-infrastructure axis.

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

## Sprint 5.19: Temporal Load, Fault, and Cleanup Qualification Oracle [✅ Done]

**Status**: Done — validated 2026-08-02
**Deployment qualification**: pending
**Implementation**: planned `src/Prodbox/Test/TemporalQualification.hs`, extensions to
`GatewayRuntimeStability.hs`, TestRunner structured observers, fake cgroup/metrics fixtures, and
installed-binary fault scenarios, including named regression `LCPC-2026-07-11`
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

### Closure Evidence

- Active checkpoint (2026-08-02): `Prodbox.Test.TemporalQualification` now provides the pure
  three-valued temporal classifier and absorbing run-wide fold for CPU throttle, queue occupancy and
  wait, service time, p95/p99 latency, deadline misses, admission rejection, cancellation lag,
  session refresh failure, restart, OOM, and missing telemetry. Recovery windows and Pod UID
  replacement reset only the healthy sample window; they retain every incomplete/failed observation.
  The exhaustive deterministic fault schedule requires one queryable operation and attempted
  cleanup for each Authority-before/after-CAS, Provider-after-accept, Target-after-CAS,
  MinIO-read-back, Vault-session-refresh, client-response-loss, and cleanup-failure point; it
  classifies resume, exact read-back success, fail-closed refusal, and successor-blocking ambiguity.
  Authority revision, Target generation, and durable progress are monotonic even while the gateway
  is unavailable. `Prodbox.Test.Qualification.Evidence` constructs only complete, distinct
  superseded/replacement source/config/image/topology/envelope/load identities plus opaque custody
  bindings, exact counterexample/fault results, aggregate/cleanup outcomes, and ordered timestamps.
  The named `prodbox test integration control-plane-counterexample` command validates the frozen
  historical source, equal normalized envelope, five expected superseded failures, five replacement
  closures, the eight-point fault matrix, replacement temporal profile, and emits the public evidence
  digest through an installed binary. Focused validation passes 13/13 plus the named command.
- Complete closure gates pass: installed-binary CLI/env 53/53 (394.70s), unit 3007/3007
  (136.81s, serial shared-fixture runner), and `prodbox dev check` exit 0 with no HLint hints and a
  warning-clean build. Live home/AWS load campaigns remain the separate, non-closing Standard-P
  deployment-qualification axis (`pending`); no deployment-ready or operational-cutover claim is made.
- Live home/AWS campaigns remain a separate deployment-qualification axis after code closure.

### Correction To This Sprint's Own Closure Evidence (Standard C)

**Recorded 2026-08-11.** The Closure Evidence above states that the named
`control-plane-counterexample` command "validates … five expected superseded failures, five
replacement closures." It does not. `simulateFrozenCounterexample`
(`src/Prodbox/Test/Qualification/FrozenCounterexample.hs`) discards its `FrozenCounterexampleTrace`
argument to a `_` wildcard and returns both halves from its own `simulateComposition`;
`Prodbox.Test.CounterexampleValidation` then asserts the dispositions that constant already carries.
Both the five failures and the five closures are produced by the module that checks them, so the
verdict is a compile-time constant and no input can make the command fail.

What the sprint did land is real and is not withdrawn: the oracle's shape, the identity/evidence
plumbing, the fault-matrix enumeration, and the installed-binary emission path all exist. What was
over-claimed is the word *validates* — the command **emits** those dimensions rather than **testing**
them. This is the same correction shape as Sprint `5.30`'s: the claim as registered was stronger
than the mechanism delivers.

The falsifying half was owned by Sprint `5.32`, and it is ✅ **Done (2026-08-11)**: its acceptance
criterion — that a mutated frozen trace makes the command exit non-zero — now holds, against a
committed mutation fixture. The dependency this correction recorded is therefore **discharged**;
this sprint's evidence may be cited for the Counterexample column of a Deployment Qualification row
once a qualification run fills it ([README.md](README.md#deployment-qualification)). No `proven` row
rested on it, so nothing was retracted and nothing is now restored — what changed is that the
reproducer can fail.

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

## Sprint 5.20: Derived Restore Graph and Total Executor [✅ Done]

**Status**: Done — the pure `RestoreGraph.hs` module (derived edges + total executor + the three
totality proofs) landed 2026-07-15, and the `TestRunner.hs` live wiring that replaces the fail-fast
fold with this executor landed 2026-07-18. The end-to-end aggregate-report exercise through
`prodbox test all` is the non-blocking Standard-O live axis.
**Live-proof**: pending — the total executor keeping an independent app-chart restoration alive
across a retained-SES failure is exercised end-to-end only by `prodbox test all`.
**Deployment qualification**: pending
**Implementation**: ✅ **pure core + live wiring landed** — new `src/Prodbox/Lifecycle/RestoreGraph.hs`: a
`RestoreNodeId`/`RestoreNode` graph whose `RequiresSuccess`/`RequiresAttempt` edges are DERIVED by a
rule set over chart-dependency and storage-lifetime facts (each node tagged with a 4.51-A
`StoreLifetime` transport + reads lifetime), `buildRestoreGraph`, and a total `runRestoreGraphWith`
that runs every satisfiable node, records `NodeBlocked` with the offending ids, aggregates every
outcome into a `RestoreReport`, and never stops early. The independence fix is structural: each
app-chart restoration `RequiresSuccess` only the gateway restoration, never the retained-SES node
(`ClusterRetained`), so a retained-SES failure cannot discard an independent chart. `RestoreChart`
gained `Ord` (natural for its `Enum`). ✅ **Live wiring landed (2026-07-18)**: `restoreCycleActions`
in `src/Prodbox/TestRunner.hs` now returns one `runDerivedRestoreGraph` action that drives the restore
from `runRestoreGraphWith` over `buildRestoreGraphForPlan` (replacing the `map … restoreCycleSteps`
fed to the fail-fast `runSequentially`); each node dispatches through the unchanged
`restoreCycleStepActionWithGatewayStability` (preserving the runtime-stability recorder bracketing),
and `projectRestoreReport` writes the full per-node outcome table and returns the first node failure's
exit code. The whole cycle is one action so the surrounding suite fold still fails fast AFTER a failed
restore while the restore INTERNALLY runs to completion. New pure bridges
`restoreCycleStepNodeId` / `restoreCyclePlanRequirement` / `buildRestoreGraphForPlan` keep the
graph derivation and the live dispatch on one bijection.
**Independent Validation**: ✅ pure suites landed in `test/unit/RestoreGraphSuite.hs`: coverage
(node set == derived expectation; a dropped node fails), independence (no chart-lifetime node
`RequiresSuccess`-depends on the retained-SES node, and the negative fixture proving the check catches
a wrongly-gated chart), orphan scan (no node reads retained state through a chart-lifetime transport),
the total-executor property with a fake `Identity` interpreter — proving every satisfiable node
runs, the independent app charts survive a retained-SES failure (the `F-RESTORE` proof), and every
outcome lands in the aggregate report — and the **plan-wiring bijection** (every plan step maps to a
distinct graph node id for both requirements, and `restoreCyclePlanRequirement` recovers the
requirement from the plan) that proves the live executor's per-node dispatch is total. `prodbox dev
check` exit 0, unit 1797/1797 (2026-07-18).
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

- ✅ The pure code-owned closure (`RestoreGraph.hs` + `RestoreGraphSuite.hs`) landed + validated
  2026-07-15; it needs no live cluster (Standard O).
- ✅ The `TestRunner.hs` wiring (`runDerivedRestoreGraph` + `projectRestoreReport`, replacing the
  fail-fast fold) landed 2026-07-18 with the plan-wiring bijection proof; it typechecks warning-clean
  and its dispatch totality is unit-proven pre-cluster.
- 🧪 The end-to-end exercise — a real `prodbox test all` in which the total executor keeps an
  independent app-chart restoration alive across a retained-SES failure and surfaces the aggregate
  `RestoreReport` — is the non-blocking Standard-O live axis.
- Active Sprint `5.18` composes its capability-bound cleanup DAG over this same restore surface;
  Sprint `4.50` has closed and the Foundation Epoch introduces no additional blocker between them.

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

## Sprint 5.21: Resource Calibration Recorder [✅ Done]

**Status**: Done (validated 2026-08-02) — the pure and live recorder surfaces are complete.
**Deployment qualification**: pending
**Live-proof**: pending — the first healthy ≥30-minute home capture is the non-blocking Standard-O
axis; no unmeasured gateway profile is committed in its place.
**Implementation**: `src/Prodbox/Capacity/MeasuredProfile.hs` owns the pure recorder, cumulative
counter reducer, refusal taxonomy, and Dhall renderer; `src/Prodbox/TestValidation.hs` and
`src/Prodbox/TestRunner.hs` own the live `gateway-pods --record-profile` mode and atomic artifact
write; `src/Prodbox/Gateway/Daemon.hs` and `src/Prodbox/Gateway/ContinuityStore.hs` expose real GHC
heap and encrypted object-store latency telemetry. CPU/CFS observations are interval-derived, and
Pod replacement/counter regression, incomplete telemetry, an unhealthy absorbing fold, a short
window, or fewer than 300 samples refuses the write.
**Independent Validation**: recorder refusal/aggregation tables and the committed artifact golden
pass in `test/unit/MeasuredProfile.hs`; parser tests prove the flag is accepted only by
`gateway-pods`; the rendered artifact round-trips through the same `Dhall.FromDhall` reader used by
Sprint `1.65` and certifies the deterministic derived envelope.
**Docs to update**: `documents/engineering/resource_scaling_doctrine.md`

### Objective

Close the empirical-input loop without creating a second resource-authoring surface. Healthy runs
record service cost at a named reference CPU, runtime overhead/high-water evidence, throttle
observations, workload identity, and provenance. Phase 1 consumes those calibrated inputs and derives
the envelope deterministically.

### Deliverables

- A `--record-profile` mode writes a committed calibration artifact only from a healthy run with at
  least a thirty-minute steady window.
- The artifact records derivation inputs and provenance, never request/limit envelope values.
- A pure round trip proves the Phase-1 derivation consumes the artifact and deterministically
  reproduces the expected CPU/runtime-overhead terms.

### Validation

1. Recorder refusal tables with fixture payloads prove an unhealthy run or a short window cannot
   write a profile artifact.
2. An artifact golden pins the committed profile shape.
3. All proofs run pre-cluster; unit/CLI/env integration suites and `prodbox dev check` pass.

### Remaining Work

- None on the code-owned surface. The first healthy live capture is tracked by `Live-proof` and
  does not block `Done` under Standard O.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/resource_scaling_doctrine.md` - recorder gate (healthy run, thirty-minute
  steady window) and the bootstrap rule for the first committed profile.

**Product docs to create/update:**

- `README.md` - note when the first committed gateway profile activates capacity certification.

**Cross-references to add:**

- Link the recorder to Sprint `1.65`'s certification check and the `dhall/capacity/measured/`
  artifact home ([phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md)).

## Sprint 5.22: Certificate Scope Serving Validation [✅ Done]

**Status**: Done (validated 2026-08-02). The named validation, exact presented-SAN oracle,
restore-vs-reissue proof, typed OpenSSL prerequisite, installed-binary surface, and canonical-suite
registration are complete.
**Deployment qualification**: pending
**Live-proof**: pending — the real TLS handshake against harness-owned home infrastructure with a
real ZeroSSL DNS-01 certificate is the non-blocking Standard-O serving axis; a cert-manager Ready
condition is not accepted as proof.
**Implementation**: `Prodbox.Test.CertificateScopeServing` parses and compares the peer DNS SANs
as an exact canonical set; `Prodbox.TestValidation` drives verified `curl` and bounded OpenSSL
handshakes against the substrate's explicit served host; `certificate-scope` is a named canonical
validation with typed `ToolOpenSsl`/public-edge prerequisites. The production retention-coordinate
tests prove substrate isolation, distinct-set reissue, and order-independent exact-set restore.
**Independent Validation**: seven focused Sprint-`5.22` tests, the installed-binary command test,
updated generated CLI goldens/registry tables, and the full `3018/3018` unit suite passed on
2026-08-02. The `/metrics` gateway golden also passes after adding the recorder telemetry. The live
home/AWS serving runs remain the separate non-blocking Standard-O deployment axis.
**Docs updated**: `documents/engineering/acme_provider_guide.md`, `README.md`, generated CLI docs,
and the Phase-5/overview ledgers

### Objective

Prove serving, not assertion. A named validation opens a real TLS handshake against every explicit
served hostname bound for the tested substrate, against harness-owned infrastructure with a real
ZeroSSL DNS-01 certificate, and inspects the presented certificate's SANs against the exact
canonical `CertScopeSet` projection. It adds an exact retained restore-vs-reissue proof: an unchanged
set restores without ordering, a new SAN set gets a distinct coordinate and exactly one fresh order,
and returning to a still-valid previously retained exact set may restore it. A cert-manager Ready
condition alone is not accepted as proof.

### Deliverables

- A named integration validation that curls every explicit hostname bound by the tested substrate
  over TLS and fails if any bound host does not serve the configured scope certificate. For a
  wildcard scope, bind a deterministic covered child and inspect the peer SANs; do not pretend to
  enumerate the wildcard's infinite coverage or invent listeners/routes/DNS records from SANs.
- A retained restore-vs-reissue proof keyed by exact canonical scope-set serialization: an unchanged
  set restores, every distinct SAN set gets a distinct coordinate and one first issuance, and a
  previously retained exact set can be selected again. `impliedBy` is checked separately as the
  coverage/admission relation.
- Home-substrate serving proof against harness-owned infrastructure with a real ZeroSSL DNS-01
  certificate; AWS-substrate parity tracked as the non-blocking axis in
  [substrates.md](substrates.md).

### Validation

1. The named validation performs a real TLS handshake against every explicit substrate-bound served
   hostname, inspects the presented SAN set, and fails if the binding or exact certificate scope is
   wrong — the cert-manager Ready condition alone is not accepted.
2. The restore-vs-reissue proof shows exact-set reuse, one issuance for each new SAN set, distinct
   canonical coordinates for narrower/wider unequal sets, and optional reuse when selecting a
   still-valid previously retained exact set again.
3. The home-substrate run uses harness-owned infrastructure and a real ZeroSSL DNS-01 certificate;
   AWS-substrate coverage is the non-blocking parity axis in [substrates.md](substrates.md)
   (Standards N/O).

### Closure Evidence

- The pure restore-vs-reissue retention-coordinate proof landed (`test/unit/Main.hs`, three
  "Sprint 5.22" cases): per-substrate coordinate isolation of the same SAN set,
  `impliedBy`-covered-but-distinct sets reissuing under distinct production `publicEdgeTlsRetentionKey`
  coordinates, and an order-independent unchanged set restoring under one coordinate. This proves the
  algebra half of deliverable 2 at the production retention key; `impliedBy` is checked separately as
  the coverage/admission relation.
- `prodbox test integration certificate-scope --substrate <home-local|aws>` now verifies the real
  chain/hostname and exact presented SAN set rather than accepting a readiness condition.
- The live home and AWS serving proofs are non-blocking deployment/substrate-parity axes tracked in
  [substrates.md](substrates.md); it is not a `5.22` blocker (Standards N/O).

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/acme_provider_guide.md` - the certificate-scope serving validation and its
  exact retained restore-vs-reissue proof as the canonical-suite consumer of the configured
  `CertScopeSet`.

**Product docs to create/update:**

- `README.md` - note that the canonical suite proves serving on every explicit bound hostname and
  inspects the exact configured certificate SAN set.

**Cross-references to add:**

- Link the serving validation to the `CertScope` algebra owned by Sprint `2.35`
  ([phase-2-gateway-dns.md](phase-2-gateway-dns.md)) and the AWS-substrate parity axis in
  [substrates.md](substrates.md).

## Sprint 5.23: Deterministic Shutdown-Race and Residue Oracle [✅ Done]

**Status**: Done — the deterministic shutdown model, exhaustive scheduler, and residue oracle
landed and are fixture-proven on the code-owned surface. The live full-suite-contention exercise is
the non-blocking Standard-O axis.
**Implementation**: ✅ `src/Prodbox/Bootstrap/Broker/ShutdownModel.hs` — a pure, exhaustively
schedulable model of the Bootstrap Broker forced-drain shutdown. It reproduces the Sprint-2.36
proof-carrying boundary as two variants over one step relation (drain / finalize-worker /
resolve-waiter / prove-shutdown): `FrozenPreFix` proves completion on `queued == 0 && active == 0`
alone, while `ProofCarrying` additionally requires every replay waiter resolved (the `Map.null
entries` term of `Prodbox.Bootstrap.Broker.Server.proveShutdownComplete`). `reachableStates`
enumerates every interleaving of the finite, monotone state space; `stoppedWithLiveWaiter` is the
counterexample predicate; and `shutdownResidue` / `residueClean` are the run-final residue oracle
over queued connections, unfinalized workers, and live replay-waiter cells. Evidence:
`test/unit/BootstrapBrokerShutdownModel.hs` — the frozen model reaches `Stopped + live replay
waiter`, the proof-carrying model cannot under exhaustive bounded scheduling, every proof-carrying
terminal state is a clean stop, and a frozen terminal leaks typed residue rather than passing
silently (shutdown suite 6/6, broker regression 132/132, `prodbox dev check` exit 0, warning- and
lint-clean).
**Live-proof**: pending — wiring the residue oracle into the real broker daemon-lifecycle fixture
teardown and exercising full-suite contention (not just isolated green repetition) over the live
STM/`Async` runtime is the non-blocking Standard-O axis.
**Deployment qualification**: pending
**Independent Validation**: ✅ after Sprint `2.36` exposes the proof-carrying shutdown boundary, the
pure model's fake cancellation/finalizer/waiter scheduling validates every interleaving locally with
no live substrate or later phase — `reachableStates` is an exhaustive closure over the finite
monotone state space, so the counterexample and its absence are proofs, not sampled observations.
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/chaos_hardening_doctrine.md`

### Objective

Turn the full-suite-only Bootstrap Broker shutdown failure into a stable repository-owned
counterexample and prevent a test fixture from returning while its structured child tree survives.

### Deliverables

- Deterministically pause cancellation delivery and worker finalization around forced drain.
- Assert `ForceDraining`/`ShutdownIncomplete` while any child or waiter remains and assert
  `ShutdownComplete` only after the exact empty postcondition.
- Make fixture cleanup acquire the terminal witness or fail with typed residue; never discard a
  second timeout.
- Add a run-final residue check for broker worker/manager threads and unresolved completion cells.
- Exercise focused repetition and full-suite contention without treating isolated green repetition
  as sufficient proof.

### Validation

1. The frozen pre-fix simulator reaches `Stopped + live replay waiter`.
2. The replacement simulator cannot reach that state under exhaustive bounded scheduling.
3. A deliberately stalled finalizer makes cleanup fail visibly rather than leak into later tests.
4. The focused shutdown suite, complete unit suite, and `prodbox dev check` pass consecutively.

### Remaining Work

- ✅ The pure code-owned closure — the frozen/proof-carrying shutdown model, the exhaustive bounded
  scheduler, the counterexample (`stoppedWithLiveWaiter`), and the run-final residue oracle
  (`shutdownResidue` / `residueClean`) — landed and is fixture-proven against Sprint `2.36`'s
  proof-carrying postcondition and explicit incomplete state.
- ✅ **Corrected 2026-08-04 (Sprint `5.27`).** Two deliverables above — "make fixture cleanup acquire
  the terminal witness or fail with typed residue; never discard a second timeout" and "add a
  run-final residue check for broker worker/manager threads and unresolved completion cells" — were
  not implemented, and the remaining-work entry classified them as a **Standard-O live axis**. That
  classification was wrong.
  [Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof) enumerates
  the live axis as live AWS spend, a deployed cluster, an unsealed Vault, or an operator-supplied
  credential. `BootstrapBrokerServerSafety` is a unit-suite module whose only external resource is a
  loopback ephemeral port; it runs entirely under `prodbox test unit`. An in-process STM/`Async`
  runtime is not live infrastructure, and labelling it so parked implementable work behind an
  environmental gate that does not exist. Sprint `5.27` implements both deliverables.
- 🧪 Exercising full-suite contention over the live runtime — as opposed to focused repetition —
  remains a genuine non-blocking observation axis.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/unit_testing_policy.md` - deterministic shutdown scheduling and residue.
- `documents/engineering/chaos_hardening_doctrine.md` - forced-drain/finalizer fault point.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Link the Sprint `2.36` runtime owner and the timeout-discarding test-fixture ledger row.

## Sprint 5.24: Restore-Time Gateway Observability Wait [✅ Done]

**Status**: Done — an own-surface Phase-5 reopen (Standard A) of the Sprint `5.16` gateway
runtime-stability gate. A live home `prodbox test all` surfaced a deterministic restore-cycle failure
that was **not** the heap-leak: the post-reconcile stability sample failed closed on a
freshly-(re)started but healthy gateway Pod whose working-set was not yet observable, because
metrics-server had not performed its first scrape when the sample was taken. This blocked
`RestoreNodeReconcileChart RestoreChartGateway` before Phase 2 on every run. The fix waits out the
scrape gap without weakening the fail-closed contract.
**Implementation**: ✅ `recordGatewayRuntimeStabilitySample` (`src/Prodbox/TestValidation.hs`) now runs
`awaitGatewayRuntimeObservable` before recording a sample: `observeGatewayRuntimeScratch` performs a
read-only observation folded into a throwaway `initialGatewayStabilityState` (never the run recorder,
so nothing is latched), and the wait polls until the runtime is observable or a bounded ~60 s budget
elapses. The new pure classifier `gatewayStabilityUnreachableIsTransient`
(`src/Prodbox/Test/GatewayRuntimeStability.hs`, exported alongside `stabilityStatePolicy`)
distinguishes a transient `GatewayPodObservationUnreachable` / `GatewayPayloadUnreachable` (waited
out) from a static `GatewaySnapshotPolicyMismatch` (fatal). The absorbing classifier is unchanged, so
a genuinely unhealthy / over-threshold / OOM / restart runtime is observable immediately and still
fails closed with no delay, and a runtime that stays unobservable past the budget still falls through
to the recorded sample and fails closed.
**Live-proof**: ✅ proven for the fix's owned surface. A clean cold home `prodbox test all` (fresh
cluster, fresh gateway Pod) drove the restore cycle to `RestoreNodeReconcileChart RestoreChartGateway ->
**succeeded**` — the exact node that failed with `StabilityUnreachable (GatewayMemoryReadingUnobservable)`
in the pre-fix runs — and its success **unblocked the entire downstream restore graph**
(`RestoreNodeReconcileChart RestoreChartVscode/Api/Websocket` and `RestoreNodeWaitForPublicEdge` all
`succeeded`, where the pre-fix runs left them `BLOCKED`). The whole run recorded **zero**
`StabilityUnreachable` / `RuntimeUnhealthy` observations and the gateway Pods held `0 restarts`
throughout. The one restore node that failed, `RestoreNodePrepareRetainedSes`, failed on an unrelated
transient MinIO NodePort blip (`LeaseAuthorityUnobservable … could not connect to 127.0.0.1:39000` — the
documented "transient MinIO-unreachable" class, recoverable via idempotent retry), **not** the gateway
stability gate this sprint owns. A full green home run through Phase 2 additionally depends on that
transient object-store class and the genuine heap-leak holding off (Standard-O / cutover); neither is
this sprint's surface.
**Deployment qualification**: pending — a test-harness restore-gate fix; it changes no production
process-topology, capability-wiring, envelope, persistence, or lifecycle surface, so it neither
advances nor invalidates Standard-P qualification, which remains pending on the cutover.
**Independent Validation**: ✅ `test/unit/GatewayRuntimeStability.hs` ("treats a fresh-Pod
observability gap as transient while a static policy mismatch stays fatal") proves the classifier over
a folded fresh-Pod memory-unobservable report plus the payload/policy cases; the existing fail-closed
tests ("fails closed when required metrics are unobservable", "fails closed for each unobservable
Pod-status field") are unchanged and still pass, proving the pure fail-closed contract is preserved
(Sprint 5.16 suite 18/18). Pre-cluster; `prodbox dev check` exit 0.
**Docs to update**: `documents/engineering/unit_testing_policy.md` (§ 6.2)

### Objective

Prevent the restore-time gateway runtime-stability sample from failing closed on a transient
metrics-server scrape gap for a freshly-(re)started but healthy gateway Pod, while preserving the
fail-closed contract for a genuinely unobservable or unhealthy runtime.

### Deliverables

- A read-only, non-latching observability wait before each recorded stability sample, bounded so a
  runtime that stays unobservable past the budget is still recorded and fails closed.
- A pure transient-vs-fatal classifier over `GatewayStabilityUnreachableReason`, exercised by unit
  fixtures alongside the preserved fail-closed cases.

### Validation

1. The classifier treats a fresh-Pod `GatewayMemoryReadingUnobservable` and a transient kubectl/API
   read failure as transient, and a static policy mismatch as fatal.
2. The existing fail-closed observations (unobservable metrics, each unobservable Pod-status field)
   are unchanged and still fail closed.
3. `prodbox dev check` and the Sprint `5.16` suite (18/18) pass.
4. A live home run confirms the false `MemoryReadingUnobservable` restore failure is eliminated (the
   working-set is observed) while a genuine restart still fails closed.

### Remaining Work

- ✅ The code-owned fix (observability wait + classifier + unit proof) landed and is `dev check`-green.
- ✅ Proven live on a clean cold home `prodbox test all`: `RestoreNodeReconcileChart RestoreChartGateway
  -> succeeded` with zero stability failures across the run, unblocking every downstream restore node.
- 🧪 A full green home run **through Phase 2** additionally depends on the unrelated transient
  MinIO-NodePort object-store class (`RestoreNodePrepareRetainedSes`, recoverable via idempotent retry)
  and the genuine heap-leak holding off — neither is this sprint's owned surface (Standard-O / cutover).

## Documentation Requirements

**Engineering docs to create/update:**

- ✅ `documents/engineering/unit_testing_policy.md` - the transient-vs-fatal unreachable
  classification and the restore-time observability-wait-before-fold boundary (§ 6.2 absorbing
  evidence). Updated: a not-yet-scraped fresh Pod is waited out, not latched as fatal, while a
  persistent unobservable still fails closed.
- `documents/engineering/chaos_hardening_doctrine.md` - none required; it carries only the general
  fail-closed rules (R4) and does not own the gateway runtime-stability gate, which this sprint's
  behavior does not contradict.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Link to Sprint `5.16` (the gateway runtime-stability oracle this reopens) and note the distinction
  from the [gateway heap-leak](legacy-tracking-for-deletion.md): the restore-gate scrape race is a
  harness-observability defect, whereas the RTS heap-overflow restart it now correctly surfaces is the
  cutover-gated leak.

## Sprint 5.25: Typed Three-Valued Gateway Readiness Observation [✅ Done]

**Status**: Done — own-surface Phase-5 reopen (Standard A) adopting the typed three-valued readiness
doctrine ([bootstrap_readiness_doctrine.md §0.9/§2.4](../documents/engineering/bootstrap_readiness_doctrine.md)).
It **supersedes Sprint `5.24`**: the observability-wait band-aid and its `gatewayStabilityUnreachableIsTransient`
`Bool` are deleted, and the not-yet-ready state is made a distinct non-terminal constructor so the
illegal "latch a healthy not-yet-scraped Pod as fatal" state is unrepresentable by construction.
**Implementation**: ✅ `src/Prodbox/Test/GatewayRuntimeStability.hs` splits `GatewayUnobservableReason`
into a terminal-only reason (`GatewayRestartCountRegressed`) and a new
`GatewayObservationIncompleteReason` (phase / readiness / restart-count / container-limit / memory-reading),
and adds a non-absorbing `GatewayObservationIncomplete` constructor routed like `GatewayPodPending`
(`firstAbsorbingOutcome` matches only `GatewayPodUnobservable`, so an incomplete observation can never be
absorbed). A warming-up snapshot folds to the already-retried `NotStableYet`. The Sprint `5.24`
`awaitGatewayRuntimeObservable` / `observeGatewayRuntimeScratch` / constants are removed from
`src/Prodbox/TestValidation.hs`. The invariant is build-enforced by
`readinessObservationViolations` in `runConformanceTierChecks` (`src/Prodbox/CheckCode.hs`).
**Live-proof**: 🧪 the removed-band-aid live restore proof carries over from Sprint `5.24` (the
`RestoreChartGateway` restore node's fresh-Pod case); a full home run through Phase 2 remains
Standard-O.
**Deployment qualification**: pending — a test-harness readiness-type fix; no production-composition
surface changes.
**Independent Validation**: ✅ `test/unit/GatewayRuntimeStability.hs` (18/18) — the metrics- and
per-field-unobservable cases now assert a non-absorbing `NotStableYet` that a subsequent green sample
advances (proving no poisoning), the terminal regressed-restart stays absorbing, and the fail-closed
policy-mismatch is preserved; `prodbox dev check` exit 0 including the new conformance gate.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/unit_testing_policy.md`

### Objective

Make "gate a gateway-stability decision on a not-yet-complete observation" unrepresentable: a healthy
but not-yet-scraped Pod is a distinct non-terminal observation, never latched as fatal, while genuine
unhealth / regressed-restart / policy mismatch still fails closed.

### Deliverables

- Split the unobservable reason type into terminal-only and incomplete/retryable sets; add the
  non-absorbing `GatewayObservationIncomplete` observation constructor.
- Delete the Sprint `5.24` observability-wait band-aid and its transient `Bool`.
- A build-enforced conformance gate that fails if the non-terminal constructor is removed (collapse
  regression).

### Validation

1. A not-yet-scraped Ready Pod folds to a non-absorbing `NotStableYet`; a green sample then advances it.
2. Each incomplete Pod-status field classifies as `GatewayObservationIncomplete <reason>`.
3. A regressed restart stays terminal (`GatewayPodUnobservable`); a policy mismatch stays fatal.
4. `prodbox dev check` (incl. the three-valued readiness gate) and the Sprint `5.16` suite pass.

### Remaining Work

None. The type split, band-aid removal, conformance gate, and unit proof are landed (`dev check`
exit 0, 18/18); live aggregate exercise remains the non-blocking Standard-O axis recorded above.

## Documentation Requirements

**Engineering docs to create/update:**

- ✅ `documents/engineering/bootstrap_readiness_doctrine.md` - §0.9 typed three-valued gate, §1
  bring-up-dual defect, §2.4 transient-vs-persistent split (SSoT).
- ✅ `documents/engineering/unit_testing_policy.md` - §6.2 the non-terminal-observation model,
  superseding the Sprint 5.24 wait prose.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Link to Sprint `5.24` (superseded) and the doctrine SSoT §2.4.

## Sprint 5.26: Fixture Values Stop Imitating Real-World Data [✅ Done]

**Status**: Done (2026-08-03) — Phase `5` own-surface reopen (Standard A/N) on the canonical suite's
fixture values, adopting
[vault_doctrine.md §20.4](../documents/engineering/vault_doctrine.md#204-fixtures-are-synthetic-not-shaped)
(Sprint `0.20`). Value substitution only; no assertion, prerequisite, or validation membership changes.
**Implementation**: `test/unit/AwsNativeClients.hs`, `test/unit/CredentialProvisioner.hs`,
`test/unit/ExternalMaterialIngressLifecycle.hs`,
`test/unit/CredentialProvisionerAwsAdminAuthority.hs`, `test/unit/Main.hs`,
`test/integration/CliSuite.hs`
**Blocked by**: none (own-surface reopen; validated without a later phase or live infrastructure).
**Deployment qualification**: pending — test-fixture data only; no Standard-P production-composition
surface is touched, so this neither advances nor invalidates the already-pending qualification.
**Independent Validation**: pure fixture-value surface exercised by the existing unit suite on the
home substrate, with no cluster, live AWS, or later-phase dependency. The suite passing **unchanged**
at 3066/3066 is itself the proof the substituted values were behaviourally inert.
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/vault_doctrine.md`

`test/` is co-owned by Phases 1, 4, and 5 (`00-overview.md`). A change that alters only fixture
*values*, with no assertion, prerequisite, or validation-membership change, is taken by Phase 5 as
the canonical suite's custodian; a change to what a test *proves* would belong to the phase owning
that behaviour.

### Objective

Three fixture families imitated real-world data closely enough that a reader could not classify them,
which is the property § 20.1 exists to remove. None of the three was required to be realistic: the
Kubernetes UID validator accepts any bounded non-control string, and the Route 53 record values are
opaque to every assertion over them.

### Deliverables

- `test/unit/AwsNativeClients.hs` — record values that were **really routable** addresses are replaced
  with RFC 5737 documentation addresses, the range the repository already uses in 38 other places
  including a live Route 53 call in production code. A test value that escapes into a real record or
  firewall rule must not point at a stranger's host.
- `test/unit/CredentialProvisioner.hs` and `test/unit/ExternalMaterialIngressLifecycle.hs` — three
  RFC 4122-shaped v4 UUIDs standing in for Kubernetes Job, Pod, and ServiceAccount UIDs are replaced
  with descriptive slugs, matching the ~35 fixtures that already use that form.
- `test/integration/CliSuite.hs` — a delegation-set nameserver shaped like a real Route 53 one, but
  which is not, is replaced with an RFC 2606 reserved name.

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox test unit` at 3066/3066 with the fd-flaky real-`ssh` case excluded — **unchanged** from
   before the substitution, which is the proof these values were behaviourally inert.
3. Defect sweep: the replaced values no longer appear and their synthetic equivalents do.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- Sprint `5.30`: `documents/engineering/integration_fixture_doctrine.md` - a fixture that
  hand-authors a serialized production type is a second encoder of that type, and a fixture server
  answers or refuses rather than closing silently (authored by governance Sprint `0.25`).
- Sprint `5.30`: `documents/engineering/unit_testing_policy.md` and `code_quality.md` - what the
  canonical gate does and does not compile, and the consequence for a sprint's Validation section.
- `documents/engineering/unit_testing_policy.md` - the forbidden/allowed pattern lists carry the
  fixture rule these substitutions satisfy.
- `documents/engineering/vault_doctrine.md` - § 20.4 is the governing statement; authored by Sprint
  `0.20`.
- Sprint `5.33`: `documents/engineering/unit_testing_policy.md` - canonical statement 10, *a test
  must be able to fail, and its evidence must be able to disagree with it*: the default path
  measures, emitted evidence is rendered rather than written, and evidence declares its provenance;
  plus statement 11, that an absence assertion is an assertion and must name the doctrine licensing
  the absence.
- Sprint `5.33`: `documents/engineering/integration_fixture_doctrine.md` - a fixture stands in for
  an observation, never for the fact that an observation happened: the unset arm is not a fixture
  arm, and the output names the source. Sprint `4.76` adds the companion rule that a boundary fake
  must answer every observation the production path makes, and that a fake's catch-all arm is a
  fail-open default.
- Sprint `5.32`: `DEVELOPMENT_PLAN/README.md` § Deployment Qualification - the note recording the
  reproducer as non-falsifying is replaced by the record that it became falsifying, and the
  Standard-C corrections on Sprints `5.19` and `8.12` are updated to say the dependency is
  discharged.
- Sprint `5.33`: `DEVELOPMENT_PLAN/system-components.md` - the gateway-runtime proof-surface row
  drops `gateway-partition`, and `DEVELOPMENT_PLAN/phase-2-gateway-dns.md`'s head-of-document note —
  the single place the scope is stated for all eight citing sprints — records that the command no
  longer exists.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Record the Phase `5` own-surface reopen in [README.md](README.md) and
  [00-overview.md](00-overview.md), and add the replaced-value rows to
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Sprint 5.27: Fixture Cleanup Acquires the Terminal Witness [✅ Done]

**Status**: Done (2026-08-04) — Phase `5` own-surface reopen (Standard A/N) implementing the two
Sprint `5.23` deliverables that were never built, and correcting their Standard-O misclassification.
**Implementation**: `test/unit/BootstrapBrokerServerSafety.hs` (`stopTestServer`,
`runtimeShutdownResidue`, `assertNoRuntimeResidue`, `failWithRuntimeResidue`)
**Blocked by**: none (own-surface reopen; validated without a later phase or live infrastructure).
**Deployment qualification**: pending — a test-fixture change touches no Standard-P
production-composition surface. (The production defect it exposed is fixed by Sprint `2.38`, which
carries its own Standard-P note.)
**Independent Validation**: unit-suite fixture over a loopback ephemeral port, no live substrate or
later phase — `prodbox test unit -p "Sprint 2.33 Bootstrap Broker server"` 7/7, full
`prodbox test unit` 3093/3093, `prodbox dev check` exit 0.
**Docs to update**: none

### Objective

Sprint `5.23` promised that fixture cleanup would "acquire the terminal witness or fail with typed
residue; never discard a second timeout", and that a run-final residue check would cover broker
worker/manager threads and unresolved completion cells. Neither landed. `stopTestServer` — the sole
bracket release for the suite — still ended in `void (timeout 2_000_000 (waitBrokerServer ...))`,
discarding both the timeout and a `Just (Left BrokerShutdownIncomplete)`: precisely the terminal
witness Sprint `2.36` had exposed in order to be checked. The residue oracle
(`shutdownResidue` / `residueClean`) had no consumer outside its own model test.

The remaining-work entry classified this as a Standard-O live axis. It is not; see the correction
recorded under Sprint `5.23`.

The cost was not hypothetical. A fixture that discards the incomplete witness cannot distinguish
"shut down cleanly" from "returned while the broker was wedged", which is the exact confusion Sprint
`5.23` exists to prevent — and a wedged broker was in fact present. Implementing the deliverable
surfaced it immediately (Sprint `2.38`).

### Deliverables

- `stopTestServer` acquires the terminal witness. `BrokerShutdownIncomplete` is not terminal, so it
  escalates to a forced drain; a second timeout or a second incomplete witness fails the fixture with
  typed residue instead of being discarded.
- `runtimeShutdownResidue` projects the real runtime snapshot into the model's `ShutdownResidue`
  triple, and cleanup accepts a stop only when `ShutdownModel.residueClean` holds and the phase is
  `BrokerStopped`. The fixture reuses the model's acceptance rule rather than restating it, which is
  what makes the two agree by construction.
- Failure messages carry the phase and the residue triple, so a leak names what leaked.

### Validation

1. `prodbox test unit -p "Sprint 2.33 Bootstrap Broker server"` 7/7.
2. The strengthened cleanup demonstrably fails closed: against the pre-`2.38` server it reports
   `phase=BrokerForceDraining` with a typed residue triple rather than passing silently.
3. Full `prodbox test unit` 3093/3093 and `prodbox dev check` exit 0.

### Remaining Work

None on this sprint's surface. Full-suite contention over the live runtime remains the observation
axis recorded under Sprint `5.23`.

## Sprint 5.28: Register the dns-aws Validation Hosted Zone [✅ Done]

**Status**: Done (2026-08-04) — Phase `5` own-surface reopen (Standard A/N) landing the Sprint `5.18`
deliverable that was recorded as closed but never built.
**Implementation**: `src/Prodbox/Infra/Route53ValidationZone.hs` (new), `src/Prodbox/TestValidation.hs`,
`src/Prodbox/TestRunner.hs`, `src/Prodbox/Lifecycle/ResourceClass.hs`, `src/Prodbox/CheckCode.hs`,
`prodbox.cabal`, `test/unit/Main.hs`, and the regenerated `substrates.md`
`resource-lifecycle-classes` section (`prodbox dev docs generate` — the registry and the published
inventory move in lockstep, which the gate enforces)
**Blocked by**: none (own-surface reopen; the code-owned surface needs no live infrastructure).
**Deployment qualification**: pending — this **does** touch a Standard-P surface (destructive cleanup:
a new always-run postflight node). Both substrate rows are already `pending`, so nothing is
invalidated, but the next AWS qualification run must exercise the post-`5.28` cleanup DAG.
**Live-proof**: 🧪 the sweep's live behaviour against real Route 53 — discovery by prefix, record
pruning, delete, and absence read-back — is exercised by the next `prodbox test all --substrate aws`.
The pure projection, the registration, and the lint closure are validated locally.
**Independent Validation**: pure + registry surface, no live AWS —
`prodbox test unit -p "Sprint 5.28"` 5/5 for the listing projection, prefix derivation, and
lifecycle-class registration; `-p "create-call-site"` 12/12 including the real-repo scan with the
carve-out removed; `prodbox dev check` exit 0.
**Docs to update**: `documents/engineering/code_quality.md`, `DEVELOPMENT_PLAN/substrates.md`

### Objective

Sprint `5.18` promised to "register account/region/caller-reference/name/operation … read back
deletion, and remove the `awsCreateProbeVerbs` lint carve-out". Its Closure Evidence never mentions
either, and neither landed: `awsCreateProbeVerbs = ["create-hosted-zone"]` survived, no hosted-zone
resource was ever registered, and no `callerReference` appeared in any Haskell source.

So `runDnsAwsValidation` created a real Route 53 hosted zone inline, deleted it only along its own
return path, and never observed it absent. The carve-out that permitted this justified itself by
citing a `bracketOnError`-wrapped capability probe in `EffectInterpreter` — which HEAD `83c7e97`
removed. The carve-out was therefore protecting an unbracketed create against a justification that no
longer existed.

### Deliverables

- `Prodbox.Infra.Route53ValidationZone` is the sole owner of the zone: it holds the create verb, the
  delete verb, the absence read-back, and the sweep. `TestValidation` calls into it and no longer
  spells any Route 53 create verb.
- Deletion is proved, not assumed. `deleteValidationHostedZone` follows `delete-hosted-zone` with a
  `get-hosted-zone` read-back and fails when the zone still resolves.
- Discovery is by identity, not memory. The zone's name and caller reference share the
  `prodbox-dns-aws-` prefix, so `discoverValidationHostedZones` finds a zone leaked by an exception
  or a cancelled run — the cases that defeated the old return-path cleanup.
- `aws-dns-validation-zones` is a registered node in the always-run AWS cleanup DAG, sequenced after
  `aws-test-ebs` and before `aws-operational-teardown` (it needs credentials the teardown removes).
  It prunes non-SOA/NS record sets first, since Route 53 refuses to delete a non-empty zone, and
  aggregates across zones so one stuck zone cannot hide the others.
- A failed discovery returns failure rather than "nothing to sweep": cannot-observe is never treated
  as absent ([lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md)).
- `dns-aws-validation-hosted-zone` is registered `PerRun` in the `ResourceClass` SSoT.
- `awsCreateProbeVerbs` is deleted. `create-hosted-zone` is now an owned entry of `awsCreateVerbs`,
  so the coverage lint flags it anywhere outside its owner. The lint has no carve-outs left.

### Validation

1. `prodbox test unit -p "Sprint 5.28"` 5/5.
2. `prodbox test unit -p "create-call-site"` 12/12, including
   `checkCreateCallSiteCoverage` over the real tree with the carve-out gone.
3. `prodbox dev check` exit 0.
4. 🧪 Live: the next `prodbox test all --substrate aws` exercises discovery, pruning, deletion, and
   absence read-back against real Route 53.

### Remaining Work

None on this sprint's surface. The companion Sprint `5.18` bullet — run-time DNS01 pre-issuance
registration, always-run Challenge deletion, and exact `_acme-challenge` TXT absence observation — is
**not** owned here and remains open; it is now Sprint `5.29` below.

## Sprint 5.29: DNS01 Challenge/TXT Pre-Issuance Registration and Absence Observation ✅

**Status**: Done (2026-08-08) — split out of Sprint `5.18` on 2026-08-05 (Sprint `0.21`). It was the
sole remaining reason Phase `5` was `🔄 Active`; closing it closes the phase.
**Implementation**: `src/Prodbox/Lifecycle/Dns01Challenge.hs` (new — the pre-issuance intent, the
three-valued absence classifier, the managed-resource entry, and the always-run cleanup edge),
`src/Prodbox/Lifecycle/DnsRecord.hs` (`mkDns01ChallengeCoordinate` and the single
`dns01ChallengeRecordName` derivation), `test/unit/Dns01ChallengeSuite.hs` (new),
`test/unit/Main.hs`, and `prodbox.cabal`.
**Blocked by**: none. Sprint `4.50` built the descriptor half; this is the run-time half, and Phase
`4` assigns it here explicitly.
**Deployment qualification**: pending — destructive cleanup and substrate routing are Standard-P
surfaces; both rows are already `pending`.
**Independent Validation**: fake-driven cleanup-DAG fixtures on the home substrate, no live AWS —
a registered Challenge/TXT node is present in the plan **before** the mutation that creates it, and
absence is observed by exact record read-back rather than inferred from a delete exit code.
**Docs to update**: `documents/engineering/acme_provider_guide.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`

### Objective

Sprint `5.18` recorded this deliverable as closed; it was never built. `mkDns01ChallengeRegistration`
and `dnsRecordLifecycleClass` exist in `src/Prodbox/Lifecycle/DnsRecord.hs` and have **no production
consumer** — their only references are `test/unit/DnsRecord.hs`, and `_acme-challenge` appears
exactly once in `src/`, inside the unconsumed constructor. The cleanup DAG emits no Challenge or TXT
node, so a run that creates a DNS01 challenge record and then fails leaves it behind with nothing
registered to remove it.

Splitting rather than reopening `5.18` keeps that sprint's genuinely-landed deliverables closed and
gives this one its own falsifiable criteria — the vagueness of `5.18`'s original items is what let
the gap survive a closure in the first place.

### Deliverables

- The existing descriptor gains a production consumer: the challenge record is registered as a
  managed resource **before** the mutation that creates it, per
  [lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md).
- An always-run Challenge deletion node in the cleanup DAG, independent of run outcome.
- Absence proven by an exact `_acme-challenge` TXT read-back; "cannot observe" stays distinct from
  "absent" and keeps the gate closed.

### Scope corrected against source (2026-08-08, Standard C)

The deliverable "register the challenge record as a managed resource **before** the mutation that
creates it" is not satisfiable as literally written, and two facts say why:

- **prodbox does not perform the mutation.** cert-manager's Route 53 DNS01 solver writes the
  `_acme-challenge` TXT; prodbox configures the solver (`src/Prodbox/CLI/Rke2.hs`) and never writes
  the record. "Before the mutation" therefore means before *issuance begins*.
- **The UIDs do not exist at registration time.** `Dns01ChallengeRegistration` demands two
  `KubernetesUid`s, and cert-manager mints the Challenge object only after the ACME Order — i.e.
  after the thing the registration is supposed to precede. Requiring them at registration is
  circular, and that circularity is a large part of why Sprint `5.18`'s version was recorded as
  built and never was.

Resolved by splitting the two halves: `mkDns01ChallengeCoordinate` registers the **coordinate**
pre-issuance with no UIDs, and `dns01ChallengeObservedRegistration` attaches the UIDs afterwards as
post-hoc evidence about a coordinate already registered.

**Deletion is by Kubernetes owner, and that is a contract rather than a workaround.** Sprint `3.32`
(landed the same day) puts both cert-manager owners outside the range of
`dnsOwnerAuthorityForProcess`, so no prodbox process can mint an authority naming one — a typed DNS
destroy against a cert-manager coordinate is unconstructible by design. The challenge node
therefore deletes the Kubernetes object that owns the record and proves absence by read-back, which
is exactly the shape [lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md)
prescribes.

### Validation (as run)

1. `prodbox-unit -p "Sprint 5.29"` — 9/9. (Written in the sprint as `prodbox test unit -p ...`;
   that flag does not exist on the `prodbox` surface. Pattern selection is a flag on the built test
   binary.)
2. **The rendered cleanup plan contains the Challenge/TXT node, and its dependency is present in
   the plan before the issuance node runs** — asserted on `cleanupGraphNodes` and
   `cleanupNodeDependencies` of the compiled plan, not on a live run.
3. **The deletion node follows issuance on `CleanupRequiresAttempt`, not `CleanupRequiresSuccess`.**
   That is the deliverable, not a detail: the failure case is the one that leaves a challenge record
   behind, so a success-gated edge would skip cleanup exactly when it is needed. A deletion node
   whose own read-back fails returns `CleanupNodeFailed` and accumulates rather than being
   swallowed.
4. **Cannot-observe stays distinct from absent.** `DnsRecordUnobservable` and
   `DnsRecordEndpointUnready` both map to `Dns01ChallengeUnobservable`, and only
   `Dns01ChallengeAbsent` satisfies `dns01ChallengeAbsenceIsProven`. The destroy succeeds on an
   observed absence even when the delete reported failure — absence is the postcondition, not the
   delete's exit code — and fails on an unobservable read-back even when the delete reported
   success.
5. **Mutation exercise.** Collapsing both unobservable arms into `Dns01ChallengeAbsent` — the exact
   defect — makes three cases fail, including a destroy that reports `ExitSuccess` while the record
   is unobservable. The source restored byte-exactly (`cmp` clean) and 9/9 returned.
6. `prodbox dev check` exit 0, `prodbox dev docs check` exit 0, and `prodbox test unit` exit 0 —
   3233/3233 plus the dedicated 27/27, 33/33, and 27/27 suites.

### Remaining Work

None on this sprint's surface. The registry entry and cleanup edge are constructed from an intent
and two injected boundaries, so binding them to the live issuance flow — the actual `kubectl delete`
of the Certificate/Order/Challenge and the real Route 53 TXT read-back — is a 🧪 Standard-O wiring
step for the next `prodbox test all` on each substrate, not a code-owned gap. **Operator note:** once
wired, any pre-existing leaked `_acme-challenge` TXT in the operator-owned parent zone will turn the
postflight red, which is the point.

## Sprint 5.30: One Tier-0 Encoder, and a Gate Region That Covers the Evidence ✅

**Status**: Done (landed 2026-08-08) — Phase `5` own-surface reopen (Standard A) on the canonical
test suite this phase owns. Registered by the investigation that found
`prodbox test integration cli` and `env` failing 20 of 55 cases; the doctrine it implements is
Sprint `0.25`.
**Implementation**: `src/Prodbox/CheckCode.hs` (the `--enable-tests` build flag and
`tier0EncoderViolations`), `src/Prodbox/TestRunner.hs`, `test/support/TestSupport.hs`,
`test/integration/CliSuite.hs`, and `test/integration/EnvSuite.hs`.
**Blocked by**: none.
**Deployment qualification**: pending (not invalidated) — this sprint touches test fixtures, a
developer-tooling build flag, a `dev check` rule, and one operator-facing diagnostic line in the
test runner. No production-composition surface changed; both rows stay `pending`.
**Independent Validation**: `prodbox dev check` exit 0 with `--enable-tests` in force;
`prodbox test unit` 3253/3253; the two-region mutation exercise below, run and restored
byte-exactly.
**Docs to update**: `documents/engineering/integration_fixture_doctrine.md`,
`documents/engineering/unit_testing_policy.md`, `documents/engineering/code_quality.md` — all three
carry the doctrine from Sprint `0.25`; this sprint records the landed mechanism against it.

### Objective

Four hand-written Tier-0 Dhall encoders existed in the test tree. Sprint `1.80` tightened one config
field and updated one of them; the other three still emitted the old shape, so every Tier-0 fixture
in the integration suite failed to decode. This is
[chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md) exactly: a
record with one decoder and four encoders, three of which were hand-maintained restatements that the
tightening made wrong rather than updated.

### What Landed

- **One encoder.** `test/support/Tier0Fixture.hs` is the only module in the test tree that produces
  Tier-0 document text. `Tier0Fixture` is opaque (constructor unexported), and every valid fixture is
  a `ProdboxProjectConfig` or `Settings.ConfigFile` value rendered through the existing canonical
  `renderProjectConfigDhall`. `wrapTier0`, `wrapTier0WithComponents`,
  `wrapTier0WithDefaultComponentGraph` and `writeRootBasics` are deleted, along with ~33 Dhall
  fragment helpers across `test/integration/CliSuite.hs`, `test/integration/EnvSuite.hs` and
  `test/unit/Main.hs` — `EnvSuite.hs` alone lost 282 lines against 70 added. The deliverable is
  *fewer* encoders, not a new abstraction.
- **The envelope is derived even around raw text.** The hand-written wrapper spelled out the whole
  `context` record as text — seal mode, capabilities, the parent-reference `Optional`'s full type
  annotation — so a change to `ProdboxContext` would have broken it the same way. `rawTier0Parameters`
  now renders that envelope through `renderProdboxContextDhall`, newly exported from
  `src/Prodbox/Config/Tier0.hs`, so only the caller's own `parameters` expression is text. The test
  tree gained no encoder of its own.
- **The raw-text escape carries a checked reason.** `RawTier0Reason` is closed with two arms, each
  naming a property no well-typed value can have: `ExercisesGeneratedSchemaImport` (verified to
  actually import the generated schema) and `MustNotTypeCheckAgainst` (verified to name the field it
  violates). There is deliberately no "not yet migrated" arm — that state is the defect this sprint
  removes, and it is left unnameable.
- **The gate region covers the evidence.** `src/Prodbox/CheckCode.hs` and
  `src/Prodbox/TestRunner.hs` add `--enable-tests` to the canonical build. Neither half alone would
  have caught Sprint `1.80`: derived fixtures make drift a compile error, and `--enable-tests` makes
  something compile it. Turning it on immediately produced 33 `-Werror` findings in `test/` that the
  old region had never seen — dead Dhall-fragment helpers left by the migration, now deleted.
- **A `dev check` rule holding "one encoder"** — `tier0EncoderViolations`, in the negative-space
  idiom of `supervisedWorkerViolations`, plus two positive anchors so deleting the fix is a finding
  rather than a silent pass. Its bound is stated in the rule itself rather than implied: it is
  line-local, so binding the path first and writing to the binding on a later line escapes it. The
  structural guarantee carries the weight; the rule only keeps the shortest road back from being
  taken by accident.
- **A runbook step that fails now says which step.** `runRunbookCommand` in
  `src/Prodbox/TestRunner.hs` used to return the child's exit code bare, so a failing
  `cluster reconcile` ended a run with no line of its own. That is the § 23 response-obligation
  defect in the runbook rather than on a socket, and it is what made Sprint `5.31` diagnosable.
- **The fake Docker rate limit models a transient failure, not a permanent one.**
  `pushDockerImageWithRetry` classifies the upstream code-server registry's `429` as retryable and
  gives up after three attempts. The fake returned `429` forever, which refuted the very retry the
  two tests asserting "Retrying Harbor publication …" *plus* `ExitSuccess` exist to exercise, and
  took down every other case that merely passed through the runbook on its way elsewhere.

### Validation

1. `prodbox dev check` exit 0, with `--enable-tests` now in the build — so the eight test suites
   are formatter-gated, linted **and type-checked** in one run for the first time.
2. `prodbox test unit` 3253/3253 (excluding the known fd-flaky AWS-SSH case), including the new
   `Sprint 5.30 derived Tier-0 fixtures` suite 9/9.
3. `prodbox test integration cli` + `env`: **8 of 55 failing, down from 20**. Not zero. All eight
   remaining failures share one root cause, registered as Sprint `5.31`; see Remaining Work.
4. **Two-region mutation exercise**, restored byte-exactly afterwards. A field was added to
   `Settings.DeploymentSection` and *every production construction site was updated* — modelling
   what a developer actually does, which is what Sprint `1.80` did:
   - Old region (`cabal build --builddir=.build all`): **exit 0**. The schema change ships green.
   - New region (`… all --enable-tests`): **exit 1**, at `test/unit/Main.hs:17103`, naming
     `DeploymentSection` and the uninitialised field.
   - With that one fixture updated, the derived fixtures round-tripped unchanged: 9/9, because
     `Dhall.inject` rendered the new field automatically instead of omitting it.
5. Hand-writing a Tier-0 record in a test fails the encoder gate, naming file and line. Exercised
   both as a pure function (9 cases) and live — the gate's first run found four real sites.
6. A fixture rendered from a value and read back through `loadConfigFileAtPath` equals that value;
   an over-reserved plan renders with no Ring-1 `assert`, still loads, and still falls to the
   Haskell refusal.

### Correction To This Sprint's Own Registration (Standard C)

The registered text claimed "adding a field to `DeploymentSection` must fail **the build**, not a
test" without qualification. The mutation showed that is true but for a narrower reason than stated,
and the sprint's own Haddock said so imprecisely before being corrected. A schema change reaches a
derived fixture two ways, and only one of them is a compile error:

- A field **retyped or removed** is a compile error at every fixture. This is the Sprint `1.80` case.
- A field **added** is *rendered automatically*, because the encoder is derived from the record
  rather than restating it. It is additionally a compile error at any fixture that constructs the
  record explicitly rather than updating a default — which is how the mutation surfaced.

Neither path is a runtime decode failure, which is the property that matters. The claim as
registered was stronger than the mechanism delivers; the mechanism is sufficient regardless.

### Remaining Work

Eight of 55 integration cases still fail, and they are **one** defect, not eight: every one of them
exits at `prodbox cluster reconcile --with-edge (exit 1)` inside the Phase 1.5 runbook, and that
command emits no diagnostic of its own — no stdout line, no stderr line, `ExitFailure 1`. Three
distinct fixture drifts were peeled off on the way to it (the `429` transient model above, plus the
four recorded under the investigation that opened this sprint), and this is what was underneath.

Registered as Sprint `5.31`. It is deliberately **not** absorbed into this sprint: the failure is in
the reconcile step chain, not in a fixture, and this sprint's surface is fixtures and gate region.

## Sprint 5.31: A Reconcile Step's Failure Reaches the Operator ✅

**Status**: Done (2026-08-09) — Phase `5` own-surface reopen and reclosure (Standard A), continuing
from Sprint `5.30`. The typed refusal crossing, its direct regression, and the four remaining
fixture/expectation corrections are implemented; installed integration passes 55/55.
**Implementation**: `src/Prodbox/Lifecycle/AnchoredReconcile.hs`, `src/Prodbox/CLI/Rke2.hs`,
`src/Prodbox/Lib/AwsSubstratePlatform.hs`, `src/Prodbox/TestRunner.hs`,
`src/Prodbox/TestValidation.hs`, `test/integration/CliSuite.hs`, `test/integration/Main.hs`, and
`test/unit/DependencyAdmissionSuite.hs`.
**Deployment qualification**: pending — a diagnostic that was previously absent cannot have been
relied on, so adding it invalidates nothing. The admission-threading change in Sprint `4.61` is the
one with a qualification consequence, and it is recorded there.
**Independent Validation**: installed `prodbox test integration cli` + `env` — **55/55**;
`prodbox test unit` exit 0 with main Hspec **3255/3255**; `prodbox dev check`, `prodbox dev docs
check`, and `prodbox dev lint docs` exit 0.
**Docs updated**: `documents/engineering/chaos_hardening_doctrine.md` § 23 (an `ExitCode` crossing
out of a step is the same conversion as an exception crossing out of a handler) and
`documents/engineering/integration_fixture_doctrine.md` (production-projected positive
observations and boundary-valid prerequisites).

### Objective

Eight of 55 integration cases failed at the same place, and the run said nothing about why:

```text
Phase 1.5/2: enforcing integration runbook
```

…then an exit status. No stdout line, no stderr line.

This is [chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md) at
a different boundary from Sprint `4.60`'s. There the conversion was *exception → closed socket*;
here it was *typed refusal → bare `ExitCode`*. `ExitCode` carries one bit and has no room for a
reason, so lowering into it can only destroy one.

### What Landed

- **The runbook step names itself on the diagnostic stream.** `runRunbookCommand`
  (`src/Prodbox/TestRunner.hs`, landed under Sprint `5.30`) reports to stderr which command failed
  and with what code. That turned "the phase banner and then nothing" into `Integration runbook
  step failed: prodbox cluster reconcile --with-edge (exit 1)` without mixing the diagnostic into
  command stdout.
- **The refusal leaves as itself.** `runAnchoredStepOrder`
  (`src/Prodbox/Lifecycle/AnchoredReconcile.hs`) ended in `refuse _ = ExitFailure 1` — the typed
  `AdmissionRefusal` discarded with a wildcard. `renderAdmissionRefusal` already existed and was
  already exported; the crossing simply did not use it. The function now returns
  `Either AdmissionRefusal (ExitCode, AdmissionSet)`, so there is no `ExitCode` to return in a
  refusal's place and the silent version is **unrepresentable rather than merely absent**. Both
  callers — `runAnchoredReconcileSteps` in `src/Prodbox/CLI/Rke2.hs` and `runSlice` in
  `src/Prodbox/Lib/AwsSubstratePlatform.hs` — render it at the boundary where a reason belongs.
  `test/unit/DependencyAdmissionSuite.hs` calls the executor itself and proves that an unavailable
  admission returns the exact typed `AdmissionMissing` refusal without starting the mutation. The
  installed integration executable then exercises the real RKE2 caller in an isolated helper
  process and proves the rendered refusal is on stderr with empty stdout; a second isolated process
  gives `runRunbookCommand` a silent exit-23 child and proves the command identity is likewise on
  stderr, not stdout.

  Making it speak produced the real defect in one run:

  ```text
  mutating `chart_authority_backup` requires an admission for its declared
  dependency `registry`, which was never observed ready in this run
  ```

  That is Sprint `4.61`, on Phase `4`'s surface: admissions were reset at every phase boundary, so
  every cross-phase graph dependency was refused unconditionally.
- **Three further fixture drifts, each surfaced only once the layer above it was fixed.** The
  fixture never served `/v1/state`, the route Sprint `1.76` moved the round-trip evidence to, so
  `ProbeBackendRoundTrip ComponentMinio` observed a `404`; its receipt then had to be *fresh*, since
  `readinessFreshnessWindow` is 300s and a literal `1` is not; and the fake cluster's ResourceQuota
  and LimitRange objects were hand-written JSON restating the capacity plan's numbers.
- **The capacity drift Sprint `5.30` predicted, found and closed.** The fake LimitRange declared the
  gateway at `250m` where the plan projects `750m` — the 250m × 3 versus 750m × 2 drift this phase
  registered as "currently silent". It is no longer possible: `namespaceResourceQuotaHardFields` and
  `namespaceLimitRangeContainerFields` are exported from `src/Prodbox/TestValidation.hs`, the
  validator compares against them, and the fixture's *observed* state is rendered from them. A fake
  that restates a production value is an encoder of it, and this one had already drifted — the same
  § 23 finding as the Tier-0 encoders, at the observed-state boundary instead of the config one.
- **The final four cases close against their named behavior (Standard C correction, 2026-08-09).**
  The gateway stability sampler never needed a daemon route: it reads fake `kubectl` Pods, events,
  and metrics, and the fake exposed three gateway Pods while the capacity projection requires
  exactly two. The fake Pod and metric observations now derive their cardinality from
  `gatewayRuntimeExpectedReplicas`; the positive Pod limit also derives from the validated gateway
  runtime-memory plan rather than restating `512Mi`. The RKE2 case did not assert an exact Docker
  sequence; its stale substring expected the fallback image even though the transient `429` is
  followed by a successful second push of the primary image, so it now proves exactly two primary
  pushes and no fallback tag.
  Config setup now checks the derived `.AdvertiseLayer2` Dhall union and structurally decodes the
  generated file. The AWS-IAM teardown case was never an undecided empty-subzone test: its name and
  assertions target an unavailable authenticated Credential Provisioner, so its unrelated AWS
  subzone prerequisite is now a valid fixture value and execution reaches that intended refusal.

### Validation

1. `./.build/prodbox test integration cli` + `env` — **55/55**, including the gateway stability,
   RKE2 reconcile/delete, config-setup, and AWS-IAM teardown cases that were previously failing;
   the RKE2 case also proves the typed refusal and generic runbook identity reach stderr while
   stdout remains empty.
2. `./.build/prodbox test unit` — exit 0; the main Hspec inventory is **3255/3255**, including the
   direct typed-refusal executor regression.
3. `./.build/prodbox dev check`, `./.build/prodbox dev docs check`, and
   `./.build/prodbox dev lint docs` — exit 0; `git diff --check` reports no whitespace errors.
4. `runs native resource-guardrails validation through fake Kubernetes resource JSON` — the case
   that drove the diagnosis — passes end to end, through the runbook, the deep readiness probe, and
   the derived quota/limit-range comparison.

### Remaining Work

None on Sprint `5.31`'s code-owned surface. Clean-room home and AWS deployment qualification remains
pending in the global Standards O/P ledger and does not reopen this phase.

## Sprint 5.32: The Frozen Counterexample Consumes Its Trace ✅

**Status**: ✅ **Done (2026-08-11)** — Phase `5` own-surface reopen (Standard A) on the canonical
test suite this phase owns. Registered 2026-08-11 by the MISU audit that read the reproducer against
Standard P.
**Implementation**: `src/Prodbox/Test/Qualification/FrozenCounterexample.hs`,
`src/Prodbox/Test/CounterexampleValidation.hs`,
`test/qualification/LCPC-2026-07-11.dispositions`,
`test/qualification/LCPC-2026-07-11.mutated.dispositions`.
**Blocked by**: none.
**Deployment qualification**: pending — and this sprint is a *precondition* for filling the
Counterexample column of either row in the [Deployment Qualification ledger](README.md#deployment-qualification).
It changes no production-composition surface; it changes whether a qualification input can fail.
**Independent Validation**: the mutation exercise below, run on the home substrate with no live
infrastructure; `prodbox dev check`, `prodbox test unit`, and
`prodbox test integration control-plane-counterexample` exit 0.
**Docs to update**: `DEVELOPMENT_PLAN/README.md` (§ Deployment Qualification note), and the
Standard-C corrections on Sprints `5.19` and `8.12`.

### Objective

Standard P's counterexample rule requires a repository-owned reproducer recording an "expected
failure against the frozen superseded implementation." The reproducer does not read the frozen
implementation:

```haskell
-- File: src/Prodbox/Test/Qualification/FrozenCounterexample.hs
simulateFrozenCounterexample
  :: FrozenCounterexampleTrace
  -> ([CounterexampleResult], [CounterexampleResult])
simulateFrozenCounterexample _ =
  ( simulateComposition SupersededGatewayComposition
  , simulateComposition ReplacementSeparatedComposition
  )
```

The `FrozenCounterexampleTrace` — which `loadFrozenCounterexampleTrace` genuinely reads from the
repository — is discarded to a `_` wildcard, and both halves of the result are regenerated from the
same in-module `simulateComposition`. `Prodbox.Test.CounterexampleValidation` then checks that the
two halves agree with the dispositions `simulateComposition` just wrote, so `complete` is `True` for
every input and `NORMALIZED_ENVELOPE_EQUAL=true` / `TEMPORAL_REPLACEMENT_QUALIFIED=true` are string
literals rather than rendered verdicts.

This is [chaos_hardening_doctrine.md § 12](../documents/engineering/chaos_hardening_doctrine.md)'s
cardinal rule — *never report a tested, assumed, or merely argued result as proven* — reached
through the mechanism written to enforce it. It is the same shape as Sprint `5.30`'s finding at a
different layer: there a gate's *region* excluded the evidence surface; here a gate's *input* is
excluded from its own verdict.

### Deliverables

All three are landed.

- **`simulateFrozenCounterexample` binds and consumes its `FrozenCounterexampleTrace`.** The trace
  gains `frozenTraceDispositions`, read from a repository-owned file
  (`test/qualification/LCPC-2026-07-11.dispositions`) by `parseFrozenDispositions`, which is total
  over `CounterexampleMechanism`: a missing, duplicated, misspelled, or malformed row refuses the
  load rather than silently shrinking the counterexample's coverage. The rows participate in the
  trace digest, so `frozenExpectedTraceDigest` pins the canonical file and an undeclared edit
  refuses at load.
- **No emitted evidence line is a literal.** `NORMALIZED_ENVELOPE_EQUAL` renders from the trace's
  carried envelope totals and `TEMPORAL_REPLACEMENT_QUALIFIED` from `temporalReportQualified`;
  `SUPERSEDED_FAILURES` and `REPLACEMENT_CLOSURES` count the dispositions that actually hold rather
  than the list lengths. The bound is stated rather than implied: both flags are structurally true
  wherever the line is reached, because the trace constructor refuses diverged totals and the
  temporal profile is a fixed sample. What changed is provenance — the line can no longer keep
  asserting `true` if the computation changes, because it *is* the computation.
- **A committed mutation fixture** (`test/qualification/LCPC-2026-07-11.mutated.dispositions`)
  records `GatewayDeadlineUnderThrottle` as having been *closed* by the superseded implementation
  rather than failed on — i.e. that there was no counterexample to reproduce. Every other row is
  identical, so the exercise isolates the disposition the simulator must consume. It is selected by
  `PRODBOX_TEST_FROZEN_COUNTEREXAMPLE_FIXTURE=mutated`; an unrecognised value refuses rather than
  falling back to the canonical (passing) fixture.

### Two design decisions the sprint had to make, and why

**The mutation fixture is deliberately not trace-digest-pinned.** Pinning it would make the digest
gate fire first, and the disposition consumption — the thing the exercise exists to falsify — would
never run; the test would then prove the digest works, not that the simulator reads its argument.
`FrozenTraceFixture` makes the exemption explicit and scoped: the other four captured digests are
still checked for both fixtures, so the two differ in exactly the dispositions and nothing else.

**The closure check now runs before the evidence artifact, and that ordering is load-bearing.**
`mkQualificationEvidence` already refuses the same class through `validateCounterexamples` — it was
a real gate all along, with nothing falsifiable feeding it. Built first, it would have refused the
mutated fixture *before* the validation's own fold could, leaving that fold in exactly the
cannot-fail shape this sprint exists to remove, one layer up. `counterexampleClosureRefusal` is
therefore the first gate and names the offending mechanism; the artifact builder remains an
independent second gate over the same fact.

### Validation

The acceptance criterion **is** the deliverable, and it now passes in both directions:

1. `prodbox test integration control-plane-counterexample` exits **0** against the canonical frozen
   trace, emitting `SUPERSEDED_FAILURES=5`, `REPLACEMENT_CLOSURES=5`,
   `NORMALIZED_ENVELOPE_EQUAL=true`, `TEMPORAL_REPLACEMENT_QUALIFIED=true`. ✅
2. The same command exits **1** against the mutation fixture, with
   `the frozen superseded implementation is not recorded as failing on:
   GatewayDeadlineUnderThrottle=ReplacementMechanismClosed`. A reproducer that passes both is not a
   reproducer. ✅ An unrecognised fixture selector also exits 1. ✅
3. Unit cases: the two fixtures produce different superseded dispositions and different trace
   digests; the parser refuses a missing / duplicated / unknown-mechanism / unknown-disposition /
   malformed row; comments, blank lines, and row order do not change the canonical rendering. ✅
4. An integration case pins the mutation exercise and the unrecognised-selector refusal through the
   installed binary. ✅
5. `prodbox dev check` exit 0 with `--enable-tests` in force ✅; `prodbox test unit` exit 0 ✅.

### Remaining Work

None on the code-owned surface. The Counterexample/fault-matrix column of both Deployment
Qualification rows may now be filled by a qualification run: the reproducer is falsifiable, which
was the precondition the [README note](README.md#deployment-qualification) recorded. The column
stays `pending` because no such run has happened — that is the Standard-P campaign, not this sprint.
The Standard-C corrections on Sprints `5.19` and `8.12` are updated to say the dependency is
discharged.

## Sprint 5.33: Two Named Validations Observe Nothing ✅

**Status**: ✅ **Done (2026-08-11)** — Phase `5` own-surface reopen (Standard A) on the canonical
test suite this phase owns, alongside Sprint `5.32`. Registered 2026-08-11 by the same audit.
**Implementation**: `src/Prodbox/TestValidation.hs`, `src/Prodbox/TestPlan.hs`,
`src/Prodbox/TestRunner.hs`, `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Spec.hs`,
`test/unit/Main.hs`, `test/integration/CliSuite.hs`.
**Blocked by**: none.
**Deployment qualification**: pending; unchanged. This sprint moves no production-composition
surface — it changes what two suite nodes assert about themselves.
**Independent Validation**: both nodes are in-process today and stay validatable with no live
infrastructure; the unset-fixture exercise below needs only an environment with no `PRODBOX_TEST_*`
set. `prodbox dev check`, `prodbox test unit`, `prodbox test integration cli` / `env` exit 0.
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/integration_fixture_doctrine.md`, `DEVELOPMENT_PLAN/system-components.md`
(the `gateway-partition` proof-surface row).

### Objective

Two named validations emit evidence they did not measure. They are different defects and need
different fixes.

**`daemon-bootstrap` — the default path *is* the pass fixture.**

```haskell
-- File: src/Prodbox/TestValidation.hs
  fixture <- lookupEnv "PRODBOX_TEST_DAEMON_BOOTSTRAP_AUDIT"
  case fixture of
    Nothing     -> emitDaemonBootstrapAudit defaultDaemonBootstrapAuditInput
    Just "pass" -> emitDaemonBootstrapAudit defaultDaemonBootstrapAuditInput
```

The unset arm — the one CI and a bare `prodbox test integration daemon-bootstrap` take — is
byte-identical to the `"pass"` fixture arm. There is no observation path in the function at all, and
`DAEMON_AVAILABLE=true` is a literal in `defaultDaemonBootstrapAuditInput`. Sprint `5.14`'s
`Validation` section rests entirely on this node, and Sprint `7.30`, the 2026-07-05 four-phase
reclosure in [README.md](README.md), and [substrates.md](substrates.md) inherit it downstream.

**`gateway-partition` — a sound test making an unsound claim.** `runGatewayPartitionValidation` is a
pure in-process composition over the real `GatewayState` folds. That is a *legitimate property test*
and its `-> []` prerequisite entry ("fully in-process") is honest. The defect is that it emits
`INITIAL_OWNER_ACTIVE=true`, `PARTITION_TAKEOVER_ACCEPTED=1`, `SINGLE_WRITER_AFTER_TAKEOVER=true`
and similar as **string literals**, and is cited as a numbered `Validation` step in eight `Done`
Phase-`2` sprints for properties — commit-before-peer-response, restart, partition takeover — that
no peer, restart, or partition was present to exercise. The plan already contradicts itself about
this: `phase-2-gateway-dns.md` records the validation as "live-proven on 2026-06-26", while
[this document](phase-5-canonical-test-suite.md) states `gateway-partition` "engages NO harness —
unit-pinned". The second is correct.

### Deliverables

All four are landed.

- **`runDaemonBootstrapValidation`'s unset arm observes or refuses.** It probes the Bootstrap
  Broker's own route surface with **read-only `GET`s**, including against the mutating routes: a
  daemon that serves a route answers a `GET` with something other than `404` (405 for a POST-only
  route, 401/403 for an unauthenticated one), while a route it does not serve answers `404`. That is
  enough to observe the required-route set without issuing a single mutation — a validation may not
  initialise Vault to prove it could. Where no daemon answers it is a typed refusal naming the
  absent daemon and the exact address probed, per
  [bootstrap_readiness_doctrine.md § 0.5](../documents/engineering/bootstrap_readiness_doctrine.md).
  A transport failure is a `Left` and never a status, so "nothing answered" cannot be read as "the
  route is absent".
- **The audit block declares its own provenance.** `AUDIT_PROVENANCE=observed-daemon` or
  `AUDIT_PROVENANCE=fixture:<name>`, so the distinction that was invisible in the output — the unset
  arm was *byte-identical* to the `"pass"` arm one line below it — is now stated in the evidence
  rather than only in the source. `DAEMON_AVAILABLE`, `LEGACY_TRANSPORTS`,
  `HOST_ROOT_TOKEN_FALLBACKS`, and `REDACTION` render from the computed values.
- **`gateway-partition` renders its emitted values and left the integration surface.** Every line
  derives from the composition; `PARTITION_TAKEOVER_ACCEPTED` is counted from the delta frames the
  state machine actually produced rather than written as `1`. The node is gone from
  `IntegrationSuite`, `TestPlan`'s `NativeValidation` and `canonicalNativeValidations`, the CLI
  parser and command registry, and `system-components.md`'s proof-surface row; it runs in
  `prodbox test unit`.
- **Standard-C corrections landed** on the head-of-document note in `phase-2-gateway-dns.md` (which
  is the single place the scope is stated for all eight citing sprints, per § 1 of
  `documentation_standards.md`), on Sprint `2.25`'s "live-proven" line, and on Sprint `5.14`'s
  Validation section. No code deliverable is withdrawn.

### What removing the node actually changed, stated rather than glossed

`prodbox test all` no longer runs `gateway-partition`, because `canonicalNativeValidations` no longer
lists it. That is a **reduction in the canonical suite's node count and no reduction in coverage**:
the composition it ran is executed by `prodbox test unit` on every `dev check`, which is a stricter
gate than an integration node that declared `-> []` prerequisites and could not fail on any input.
The unit suite additionally pins a property the integration node could not have: that the emitted
lines change when the composition changes.

Sprint `5.14`'s correction is narrowed rather than withdrawn. Its steps 2–4 ran against the `"pass"`
fixture arm, which is unchanged and still real — it proves the *oracle* refuses a trace containing a
legacy transport, an unredacted secret, or an unavailable daemon. They never proved that a live
daemon-bootstrap run took only broker transports, and after this sprint no run makes that claim
implicitly, because a run that measured nothing refuses instead of passing.

### Validation

1. **Unset-fixture exercise, and it is the acceptance criterion.** With every `PRODBOX_TEST_*`
   unset, `prodbox test integration daemon-bootstrap` exits **1** with
   `daemon-bootstrap validation measured nothing and refuses: … no Bootstrap Broker daemon answered
   at http://127.0.0.1:8600/healthz`. It passed before this sprint, which was the defect. ✅
2. `gateway-partition`'s rendered output changes with its composition — a four-member Orders renders
   `PARTITION_MEMBERS=4` and a different block; a single-member Orders refuses naming `node-b`
   rather than emitting the same eight lines. ✅
3. `prodbox test unit` covers the relocated `gateway-partition` cases and the daemon-bootstrap
   provenance/refusal cases, at main Hspec **3374/3374** ✅. `prodbox test integration cli`
   **57/57** exit 0 with the integration registration removed (a case asserts the verb is refused
   and absent from `test integration --help`) ✅; `prodbox test integration env` exit 0 ✅.
4. `prodbox dev check` exit 0 ✅, after regenerating the three CLI golden files and
   `documents/cli/commands.md`, which the removed verb changed.

### Remaining Work

None on the code-owned surface. A third node of the same family — `gatewayRuntimeSampleExit` mapping
`NotStableYet` to `ExitSuccess` while its sibling gate ten lines away retries and then fails — stays
recorded in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) rather than folded in
here, because it is a fold defect on the Phase-`2` gateway surface rather than suite content, and
[Standard M](development_plan_standards.md#m-test-suite-substrates) keeps those ownerships apart.

🧪 **Live-proof: pending** (Standard O) — the daemon-bootstrap unset arm's *observing* branch has
been exercised only against an absent daemon on this host. A run against a cluster whose Bootstrap
Broker is serving is the outstanding non-blocking evidence that the route-surface probe classifies a
live broker correctly; the refusal branch, which is the one this sprint exists to create, is proven.

## Sprint 5.34: Two Fixture Surfaces Whose Gates Did Not Reach Their Own Defects ✅

**Status**: ✅ **Done (2026-08-13)** — Phase `5` own-surface reopen (Standard A) on the canonical
suite's fixture surfaces this phase owns through Sprint `5.30`.
**Implementation**: `src/Prodbox/CheckCode.hs` (`tier0WriteSiteLines`),
`test/support/Tier0Fixture.hs` (`ExistenceIsWhatIsUnderTest`, plus a Standard-C correction),
`src/Prodbox/Vault/Host.hs` (validating `FromDhall TestSecretsAdminCredentials`),
`test/unit/Main.hs`.
**Blocked by**: none.
**Deployment qualification**: pending (not invalidated). No production-composition surface moves:
`test-secrets.dhall` is a test-harness-only fixture never read by a production binary, and the
Tier-0 write gate is developer tooling.
**Independent Validation**: a `dev check` text rule and a pure decoder, validated by the compiler
and the suites — no cluster, no AWS. `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main
Hspec **3420/3420**; `prodbox test integration cli` **57/57**.
**Docs updated**: none under `documents/` — both corrections land in the source that made the claim.

### Objective

Close two `Pending Removal` rows on this phase's fixture surfaces: the line-local `Tier0Fixture`
encoder gate, and `test-secrets-types.dhall`'s bare-`Text` fields.

### Half one: the gate found a real escape on its first run, and two false ones

Sprint `5.30` matched a `writeFile` and the sibling filename **on one source line**, and registered
the escape in its own words — bind the path first, write to the binding later. The row declined to
widen the text rule, on the ground that it would "trade a stated bound for an unstated one". That
judgement was right about the danger and this sprint walked straight into it twice before getting it
right:

| Draft | What it reported | Why it was wrong |
|---|---|---|
| collect every name bound to a sibling path in the module | an unrelated `let path = tmpDir </> "config.dhall"` | a *different* case bound `path` to the sibling |
| nearest-preceding binding, file-wide | a helper whose `tier0Path` is a **parameter** | it reached across definitions into a shadowed name |
| nearest-preceding binding, **same top-level definition** | one site | correct |

A third report was a *true* write-site but not a *defect*: it wrote
`renderProjectConfigDhall …` output, which is the canonical encoder the rule's own message points
the author at. The rule now says what it means — a write whose line names the canonical encoder is
not hand-authored text.

**The one true positive is the escape the row named.** `withBinarySiblingTier0` bound
`takeDirectory exePath </> "prodbox.dhall"` and wrote to it two lines later. All three callers
already passed `renderProjectConfigDhall` output, so nothing on disk changes; the helper now takes a
`Tier0Fixture`, so its **type** says so and a caller cannot hand it hand-authored text without
`rawTier0Fixture` and a named reason.

`RawTier0Reason` gains `ExistenceIsWhatIsUnderTest` — the test-mode preflight refuses on the
config's *presence* and never decodes it, so rendering a complete config there would assert more
than the gate reads. The arm is checked, not recorded: it refuses an empty payload.

**A Standard-C correction lands with it.** `tier0FixturePath`'s Haddock said the binary-sibling
filename "appears exactly once in the test tree, here, so a `dev check` rule can hold *one encoder*
by refusing the literal anywhere else". Measured: **six files, 109 occurrences**, 90 of them in
`test/unit/Main.hs`. No such rule was ever possible; the sentence described an intention.

### Half two: the prescribed check is not available, and the reason is the finding

The row names three defects, of which one is closable and one is not, for a reason worth recording:

- **`TestSecrets::{=}` type-checks to an entirely empty fixture.** Not closable at decode:
  `defaultTestSecrets` **is** all-empty, it is what the generated schema's `default` record carries,
  and a unit case round-trips it back through this decoder. A decoder refusing empty would refuse
  the schema's own default.
- **`access_key_id` / `secret_access_key` are both `Text`, so transposing them type-checks.**
  Closable — the two are distinguishable by shape — and now a decode refusal, in the shape Sprint
  `1.86` established.
- **Emptiness is silently tolerated by the harness's prefer-non-empty fallback.** Downstream of the
  decoder; not addressed here, and not claimed to be.

**The transposition check had to become one-sided, and that is the sprint's real finding.** The
symmetric rule — also require `access_key_id` to *have* the id shape — was written first, and it
refuses this repository's own integration fixtures. Those fixtures **cannot** be given a
structurally-valid id, because `scannedCredentialViolations` (Sprint `1.75`, the
[vault_doctrine.md](../documents/engineering/vault_doctrine.md) § 20.5 mechanical outer ring) fails
the build for any **tracked** file carrying that shape. The two rules are in direct opposition and
the credential scanner is the one that must win.

What survives is the more valuable half: a transposition of *placeholder* values goes unremarked,
and a transposition of *real* operator credentials — the case that costs an afternoon, because AWS
answers `InvalidClientTokenId` and that reads like a revoked credential — puts a real access-key id
into `secret_access_key` and is refused.

### Validation

1. The widened Tier-0 gate reported **four** sites on its first run: one true escape, two false
   positives that drove the bound to its final form, and one canonical-encoder write. All four are
   recorded above rather than silently patched away. ✅
2. Three decoder cases: a correct pair decodes, the same two values swapped are refused, and a
   placeholder pair still decodes — the third pins the one-sidedness and *why*, so the conflict with
   the credential scanner cannot be quietly "fixed" later by making the rule symmetric. The
   synthetic key id is assembled from fragments at run time, per § 20.4, so this tracked file does
   not itself carry the scanned shape. ✅
3. `prodbox dev check` exit 0; `prodbox test unit` exit 0 at **3420/3420**;
   `prodbox test integration cli` **57/57** — the last of which is load-bearing here, because the
   symmetric draft broke **two** integration cases and that is how the conflict was found. ✅

### Remaining Work

None on either row. **Two bounds are stated.** The Tier-0 gate reaches one hop within one top-level
definition: a path assembled across two bindings, threaded through a function parameter, or built
from a list still escapes, and widening further would trade a stated bound for an unstated one —
which is Sprint `5.30`'s own reasoning, now with three worked examples behind it. And the
`TestSecrets` decoder refuses a present-and-malformed secret, never an absent one, so the all-empty
fixture the row objects to still decodes; that half of the row is closed by **argument** — it is the
schema's own default and cannot be refused — rather than by code.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [substrates.md](substrates.md)
- [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md)
- [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md)
- [Integration Fixture Doctrine](../documents/engineering/integration_fixture_doctrine.md)
- [Prerequisite Doctrine](../documents/engineering/prerequisite_doctrine.md)
